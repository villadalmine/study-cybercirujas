# Ejercicios guiados — CNPE 1.2: Using Cost Management Solutions for Right-Sizing and Scaling

> **Objetivo del laboratorio.** Recorrer el ciclo FinOps completo sobre Kubernetes: **medir** el costo real de las cargas (OpenCost), **dimensionar** los `requests`/`limits` con datos observados (VPA en modo recomendación + Goldilocks), **escalar** de forma reactiva y event-driven (HPA y KEDA con scale-to-zero) y **optimizar la capa de nodos** (bin-packing y Karpenter/Cluster Autoscaler). No se trata de "poner autoscaling", sino de entender la mecánica interna, los trade-offs y cómo verificar el ahorro con números.
>
> **Prerrequisitos.** Un cluster de trabajo (`kind`, `minikube`, o uno gestionado), `kubectl` ≥ 1.28, `helm` ≥ 3.12, y permisos de cluster-admin. Algunos módulos (Karpenter, spot) asumen un cluster gestionado en un cloud; se indican como *conceptuales* si estás en `kind`.
>
> **Advertencia de disciplina FinOps.** Todo cambio de `requests` o de política de escalado se valida contra **métricas reales de al menos 24–48 h** antes de aplicarse a producción. Un right-sizing basado en 5 minutos de tráfico sintético es una fuente de incidentes, no un ahorro.

---

## Ejercicio 1 — Instrumentar el cluster: sin métricas no hay FinOps

La primera regla de la gestión de costos es que **no se puede optimizar lo que no se mide**. Antes de tocar un solo `request`, necesitamos el pipeline de métricas (`metrics-server` para el plano de utilización instantánea) y una carga deliberadamente mal dimensionada que servirá de "paciente" en los ejercicios siguientes.

### Pasos

1. Instalá `metrics-server`, que expone `metrics.k8s.io` y alimenta a `kubectl top`, HPA y VPA:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

2. En clusters locales (`kind`/`minikube`) los kubelets suelen usar certificados self-signed y `metrics-server` no confía en ellos. Parcheá el flag (**solo en laboratorio, nunca en producción**):

   ```bash
   kubectl -n kube-system patch deployment metrics-server --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   ```

3. Verificá que el API de métricas responde (puede tardar ~30 s en poblar):

   ```bash
   kubectl top nodes
   ```

   Salida esperada:

   ```
   NAME                 CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
   kind-control-plane   142m         3%     1180Mi          15%
   ```

4. Creá un namespace y desplegá una carga **deliberadamente sobredimensionada** (pide 1 CPU y 1Gi pero consume una fracción). Es el antipatrón más caro y frecuente:

   ```yaml
   # workload-oversized.yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: finops-lab
   ---
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: finops-lab
   spec:
     replicas: 3
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: registry.k8s.io/e2e-test-images/agnhost:2.47
             args: ["serve-hostname", "--http", "--port", "8080"]
             ports:
               - containerPort: 8080
             resources:
               requests:
                 cpu: "1000m"      # <-- pide 1 vCPU entero
                 memory: "1Gi"     # <-- pide 1Gi
               limits:
                 cpu: "1000m"
                 memory: "1Gi"
   ```

   ```bash
   kubectl apply -f workload-oversized.yaml
   kubectl -n finops-lab rollout status deploy/web
   ```

5. Contrastá lo que **pide** contra lo que **usa** (esperá ~1 min tras el arranque):

   ```bash
   kubectl -n finops-lab top pods
   ```

   Salida esperada (uso ínfimo frente a un request de 1000m/1Gi):

   ```
   NAME                   CPU(cores)   MEMORY(bytes)
   web-7c9f8b6d4f-2xk9p   1m           6Mi
   web-7c9f8b6d4f-8vq2r   1m           6Mi
   web-7c9f8b6d4f-l4n7t   1m           7Mi
   ```

6. Calculá el **slack** (capacidad reservada y desperdiciada) del Deployment: 3 réplicas × 1000m reservados = **3000m de CPU** y **3Gi de memoria** apartados del scheduler, contra ~3m y ~19Mi realmente en uso.

### Preguntas de comprensión

1. El scheduler de Kubernetes decide en qué nodo cabe un Pod usando `requests` o `limits`. ¿Cuál de los dos? ¿Qué implicación de costo tiene esa elección con el Deployment `web`?
2. `kubectl top pods` marca uso ≈ 1m mientras el `request` es 1000m. ¿Por qué facturamos igual esos 999m "ociosos" en un cluster con nodos on-demand?
3. Definí *slack* y explicá por qué el ratio `usage/request` (no el uso absoluto) es la métrica central del right-sizing.

---

## Ejercicio 2 — Medir el costo real con OpenCost

`kubectl top` da utilización, no **dinero**. [OpenCost](https://www.opencost.io/docs/) (proyecto CNCF, la especificación de referencia sobre la que también se construye Kubecost) traduce `requests`, uso y precios de nodo en costo por namespace, Deployment y Pod, distinguiendo lo *reservado* (facturado) de lo *usado* (eficiencia).

### Pasos

1. OpenCost necesita un backend Prometheus. Instalá uno mínimo y luego OpenCost apuntándolo a él (Helm chart oficial):

   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install prometheus prometheus-community/prometheus \
     --namespace prometheus --create-namespace \
     --set alertmanager.enabled=false \
     --set pushgateway.enabled=false

   helm install opencost --repo https://opencost.github.io/opencost-helm-chart opencost \
     --namespace opencost --create-namespace \
     --set opencost.prometheus.internal.serviceName=prometheus-server \
     --set opencost.prometheus.internal.namespaceName=prometheus \
     --set opencost.prometheus.internal.port=80
   ```

2. Esperá a que el Pod de OpenCost esté `Running` y abrí el API/UI vía port-forward:

   ```bash
   kubectl -n opencost rollout status deploy/opencost
   kubectl -n opencost port-forward service/opencost 9003 9090
   ```

3. Consultá la **allocation** del namespace del laboratorio para la última hora. El endpoint `/allocation/compute` es la API canónica de OpenCost:

   ```bash
   curl -sG 'http://localhost:9003/allocation/compute' \
     --data-urlencode 'window=1h' \
     --data-urlencode 'aggregate=namespace' \
     --data-urlencode 'accumulate=true' | jq '.data[0]."finops-lab"'
   ```

   Salida esperada (recortada): fijate en que `cpuCoreHours` refleja lo **reservado** (≈3 cores) y `*Efficiency` es bajísimo:

   ```json
   {
     "name": "finops-lab",
     "cpuCores": 3.0,
     "cpuCoreRequestAverage": 3.0,
     "cpuCoreUsageAverage": 0.003,
     "cpuEfficiency": 0.001,
     "ramByteRequestAverage": 3221225472,
     "ramByteUsageAverage": 19922944,
     "ramEfficiency": 0.006,
     "totalEfficiency": 0.003,
     "cpuCost": 0.0912,
     "ramCost": 0.0121,
     "totalCost": 0.1074
   }
   ```

4. Distinguí **costo por request vs. costo por uso**. OpenCost factura el `request` (lo que el scheduler apartó), por eso `cpuEfficiency` = `usage / request` ≈ 0.001. Ese número es tu "cuánto podrías recortar".

5. (Opcional, si el nodo no tiene precio real) Verificá qué precios está usando. Sin integración de billing del cloud, OpenCost aplica el `default` configurable; en un cluster gestionado toma los precios reales del proveedor vía el adaptador de cloud-billing.

   ```bash
   curl -s 'http://localhost:9003/allocation/compute?window=1h&aggregate=cluster' | jq '.data[0]'
   ```

### Preguntas de comprensión

1. OpenCost reporta `cpuEfficiency: 0.001`. Traducí ese número a una frase de negocio y a una acción concreta sobre el Deployment `web`.
2. ¿Por qué el costo se calcula sobre `cpuCoreRequestAverage` y no sobre `cpuCoreUsageAverage`? ¿En qué situación el **uso** puede superar al **request** y qué campo lo capturaría?
3. OpenCost separa costo en `cpuCost`, `ramCost`, y agrega `networkCost`, `pvCost`, `loadBalancerCost`. ¿Por qué para el right-sizing de *compute* nos concentramos en CPU/RAM y no en los demás?
4. En un cluster gestionado, ¿de dónde saca OpenCost el precio por core-hora, y por qué es imprescindible conectar el billing del proveedor antes de tomar decisiones de dólares?

---

## Ejercicio 3 — Right-sizing con VPA en modo recomendación + Goldilocks

Ya sabemos que `web` desperdicia. Ahora hay que **cuánto** exactamente. El [Vertical Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) observa el histórico de uso y recomienda `requests`. Lo corremos en `updateMode: "Off"` (**solo recomienda, no toca los Pods**), que es el modo correcto para right-sizing gobernado por humanos. [Goldilocks](https://goldilocks.docs.fairwinds.com/) (Fairwinds) es un dashboard sobre VPA que presenta esas recomendaciones por namespace.

### Pasos

1. Instalá el VPA desde el repo de autoscaler (crea el CRD `verticalpodautoscalers` y los componentes recommender/updater/admission-controller):

   ```bash
   git clone https://github.com/kubernetes/autoscaler.git
   cd autoscaler/vertical-pod-autoscaler
   ./hack/vpa-up.sh
   ```

2. Creá un VPA **en modo `Off`** apuntando al Deployment `web`. Este modo es la diferencia entre "consejo" y "acción automática":

   ```yaml
   # vpa-web.yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata:
     name: web
     namespace: finops-lab
   spec:
     targetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: web
     updatePolicy:
       updateMode: "Off"          # <-- recomienda, NO reinicia Pods
     resourcePolicy:
       containerPolicies:
         - containerName: web
           controlledResources: ["cpu", "memory"]
           minAllowed: { cpu: "10m",  memory: "16Mi" }
           maxAllowed: { cpu: "500m", memory: "256Mi" }
   ```

   ```bash
   kubectl apply -f vpa-web.yaml
   ```

3. Generá algo de carga real para que el recommender tenga señal (dejalo correr unos minutos; en producción se esperan días):

   ```bash
   kubectl -n finops-lab run load --rm -it --restart=Never --image=busybox:1.36 -- \
     /bin/sh -c 'i=0; while [ $i -lt 5000 ]; do wget -q -O- http://web.finops-lab:8080/ >/dev/null; i=$((i+1)); done'
   ```

4. Leé la recomendación del VPA:

   ```bash
   kubectl -n finops-lab describe vpa web
   ```

   Salida esperada (sección clave):

   ```
   Recommendation:
     Container Recommendations:
       Container Name:  web
       Lower Bound:
         Cpu:     11m
         Memory:  20Mi
       Target:
         Cpu:     15m
         Memory:  24Mi
       Uncapped Target:
         Cpu:     15m
         Memory:  24Mi
       Upper Bound:
         Cpu:     40m
         Memory:  52Mi
   ```

5. Interpretá los cuatro valores. **`Target`** es el `request` sugerido; **`Lower/Upper Bound`** son el intervalo de confianza (evita perseguir picos transitorios); **`Uncapped Target`** sería la recomendación sin tu `maxAllowed`. El salto de negocio: de `1000m/1Gi` a `~15m/24Mi`.

6. Instalá Goldilocks para ver esto como dashboard por namespace (requiere el VPA ya instalado):

   ```bash
   helm repo add fairwinds-stable https://charts.fairwinds.com/stable
   helm install goldilocks fairwinds-stable/goldilocks --namespace goldilocks --create-namespace
   kubectl label ns finops-lab goldilocks.fairwinds.com/enabled=true
   kubectl -n goldilocks port-forward svc/goldilocks-dashboard 8080:80
   ```

   Goldilocks mostrará, por container, la columna **Guaranteed** (request=limit, para cargas sensibles a latencia) y **Burstable** (request<limit, para cargas tolerantes) — las dos QoS classes que definen el trade-off costo/estabilidad.

7. Aplicá la recomendación **manualmente** (right-sizing gobernado). Bajá `web` a lo sugerido con un pequeño colchón:

   ```bash
   kubectl -n finops-lab set resources deploy/web \
     --requests=cpu=20m,memory=32Mi --limits=cpu=100m,memory=64Mi
   ```

8. Volvé a medir en OpenCost (Ejercicio 2, paso 3) y compará `totalCost` antes/después. El `cpuCoreRequestAverage` debería caer de ~3.0 a ~0.06.

### Preguntas de comprensión

1. ¿Por qué el right-sizing de producción usa `updateMode: "Off"` en vez de `"Auto"`? Nombrá el efecto colateral disruptivo del modo `Auto` en la versión estable del VPA.
2. VPA reporta `Target`, `Lower Bound` y `Upper Bound`. Si fijaras el `request` en `Lower Bound` en vez de en `Target`, ¿qué ahorrás y qué riesgo introducís?
3. Explicá el trade-off entre QoS **Guaranteed** (request = limit) y **Burstable** (request < limit) desde la óptica de costo *y* de estabilidad. ¿Cuál favorece el bin-packing denso?
4. **VPA y HPA basados en la misma métrica (CPU) no deben apuntar al mismo Deployment.** ¿Por qué entran en conflicto, y qué combinación sí es segura?
5. Fijaste `maxAllowed` en el VPA. Si `Uncapped Target` fuera mayor que tu `maxAllowed`, ¿qué te está diciendo el sistema y por qué no conviene ignorarlo?

---

## Ejercicio 4 — Escalado horizontal reactivo con HPA

El right-sizing ajusta el **tamaño** de cada réplica; el escalado ajusta el **número** de réplicas para no pagar capacidad ociosa en valle ni sufrir saturación en pico. El [Horizontal Pod Autoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) (`autoscaling/v2`) es la pieza reactiva base.

### Pasos

1. Requisito ineludible del HPA por CPU: el Deployment debe tener `requests.cpu` definido (el HPA razona en **porcentaje del request**). Ya lo tenemos tras el Ejercicio 3.

2. Creá un HPA v2 que apunte al 50 % de utilización de CPU, con `behavior` explícito para controlar la velocidad de scale-down (clave para no oscilar ni pagar de más):

   ```yaml
   # hpa-web.yaml
   apiVersion: autoscaling/v2
   kind: HorizontalPodAutoscaler
   metadata:
     name: web
     namespace: finops-lab
   spec:
     scaleTargetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: web
     minReplicas: 1
     maxReplicas: 10
     metrics:
       - type: Resource
         resource:
           name: cpu
           target:
             type: Utilization
             averageUtilization: 50
     behavior:
       scaleDown:
         stabilizationWindowSeconds: 300   # espera 5 min antes de bajar: evita flapping
         policies:
           - type: Percent
             value: 50
             periodSeconds: 60
       scaleUp:
         stabilizationWindowSeconds: 0     # sube de inmediato ante un pico
         policies:
           - type: Percent
             value: 100
             periodSeconds: 30
   ```

   ```bash
   kubectl apply -f hpa-web.yaml
   ```

3. Observá el estado inicial. Con carga en valle, el HPA converge a `minReplicas`:

   ```bash
   kubectl -n finops-lab get hpa web -w
   ```

   Salida esperada (en reposo baja a 1 réplica → ahorro inmediato):

   ```
   NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
   web    Deployment/web   cpu: 2%/50%   1         10        1          90s
   ```

4. Inyectá carga sostenida para forzar scale-up:

   ```bash
   kubectl -n finops-lab run flood --image=busybox:1.36 --restart=Never -- \
     /bin/sh -c 'while true; do wget -q -O- http://web.finops-lab:8080/ >/dev/null; done'
   ```

5. Mirá cómo el HPA sube réplicas y luego, al matar la carga, respeta la `stabilizationWindow` antes de bajar:

   ```
   NAME   REFERENCE        TARGETS         REPLICAS
   web    Deployment/web   cpu: 210%/50%   1
   web    Deployment/web   cpu: 210%/50%   4
   web    Deployment/web   cpu: 74%/50%    6
   web    Deployment/web   cpu: 41%/50%    6
   ```

   La fórmula que aplica internamente el controlador es:
   `desiredReplicas = ceil(currentReplicas × (currentMetric / targetMetric))`.

6. Matá la carga y observá el scale-down diferido:

   ```bash
   kubectl -n finops-lab delete pod flood
   ```

   Confirmá que NO baja hasta pasada la ventana de 300 s — esto es intencional, no un bug.

### Preguntas de comprensión

1. Con 6 réplicas y `cpu: 210%/50%`, aplicá la fórmula `ceil(replicas × current/target)`. ¿A cuántas réplicas escalaría el HPA en la siguiente iteración?
2. ¿Por qué un HPA por CPU **exige** `requests.cpu` en el Pod? ¿Qué pasa (literalmente) si el request falta?
3. La `scaleDown.stabilizationWindowSeconds` está en 300 y `scaleUp` en 0. Justificá esa asimetría en términos de **costo** vs. **riesgo de SLO**.
4. El HPA por CPU es reactivo: escala *después* de que la carga ya subió. Nombrá dos escenarios de negocio donde eso llega tarde y qué tipo de métrica lo resolvería.

---

## Ejercicio 5 — Escalado event-driven y scale-to-zero con KEDA

El HPA por CPU no baja de `minReplicas: 1`: siempre pagás al menos una réplica encendida, aunque no haya trabajo. Para cargas dirigidas por eventos (colas, cron, mensajes) el mayor ahorro es **scale-to-zero**. [KEDA](https://keda.sh/docs/) (proyecto graduado CNCF) extiende el HPA con *scalers* de fuentes externas y permite `minReplicaCount: 0`.

### Pasos

1. Instalá KEDA vía Helm:

   ```bash
   helm repo add kedacore https://kedacore.github.io/charts
   helm repo update
   helm install keda kedacore/keda --namespace keda --create-namespace
   kubectl -n keda rollout status deploy/keda-operator
   ```

2. Desplegá un consumidor que solo tiene sentido cuando hay mensajes. Usamos un `ScaledObject` con **scale-to-zero** y un trigger de tipo `cron` para ilustrar la mecánica sin montar un broker (KEDA soporte 60+ scalers: Kafka, RabbitMQ, SQS, Prometheus, etc.):

   ```yaml
   # scaledobject-worker.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: worker
     namespace: finops-lab
   spec:
     replicas: 0
     selector:
       matchLabels: { app: worker }
     template:
       metadata:
         labels: { app: worker }
       spec:
         containers:
           - name: worker
             image: busybox:1.36
             command: ["/bin/sh","-c","while true; do echo working; sleep 10; done"]
             resources:
               requests: { cpu: "50m", memory: "32Mi" }
               limits:   { cpu: "100m", memory: "64Mi" }
   ---
   apiVersion: keda.sh/v1alpha1
   kind: ScaledObject
   metadata:
     name: worker
     namespace: finops-lab
   spec:
     scaleTargetRef:
       name: worker
     minReplicaCount: 0          # <-- scale-to-zero: cero costo en reposo
     maxReplicaCount: 5
     cooldownPeriod: 60          # espera tras el último evento antes de volver a 0
     triggers:
       - type: cron
         metadata:
           timezone: America/Argentina/Buenos_Aires
           start: "0 8 * * *"     # activa a las 08:00
           end:   "0 20 * * *"    # apaga a las 20:00
           desiredReplicas: "3"
   ```

   ```bash
   kubectl apply -f scaledobject-worker.yaml
   ```

3. Verificá que KEDA creó un HPA gestionado por él y que fuera de la ventana el Deployment está en **0 réplicas**:

   ```bash
   kubectl -n finops-lab get scaledobject,hpa,deploy worker
   ```

   Salida esperada (fuera de la franja 08–20):

   ```
   NAME                            SCALETARGET   MIN   MAX   READY   ACTIVE   AGE
   scaledobject.keda.sh/worker     worker        0     5     True    False    30s

   NAME                                              REFERENCE          MINPODS   MAXPODS   REPLICAS
   horizontalpodautoscaler.../keda-hpa-worker        Deployment/worker  1         5         0

   NAME                     READY   UP-TO-DATE   AVAILABLE
   deployment.apps/worker   0/0     0            0
   ```

   El campo `ACTIVE: False` es la señal de scale-to-zero: KEDA quitó la carga del scheduler por completo → **$0 de compute** en reposo.

4. Entendé la arquitectura: KEDA **no** reemplaza al HPA, lo *alimenta*. Para `minReplicaCount > 0` delega en un HPA estándar; para el tramo `0 ↔ 1` actúa el propio `keda-operator` (el HPA no sabe escalar desde/hacia cero). Ese es exactamente el hueco que KEDA cubre.

5. (Producción) Cambiá el trigger `cron` por uno real orientado a backlog, p. ej. profundidad de cola. Con `queueLength` como umbral, el número de réplicas persigue el backlog en vez del reloj:

   ```yaml
   triggers:
     - type: prometheus
       metadata:
         serverAddress: http://prometheus-server.prometheus.svc:80
         query: sum(rate(http_requests_total{app="worker"}[2m]))
         threshold: "100"        # 1 réplica por cada 100 req/s
   ```

### Preguntas de comprensión

1. Un HPA "puro" tiene `minReplicas: 1` como piso duro. ¿Por qué no puede escalar a cero por sí solo, y qué componente de KEDA cubre la transición `0 ↔ 1`?
2. Enunciá el trade-off principal de scale-to-zero para un servicio síncrono de cara al usuario (pista: cold start). ¿Por qué es aceptable para un `worker` de cola y peligroso para una API de checkout?
3. El `ScaledObject` usa `cooldownPeriod: 60`. ¿Qué problema de costo aparecería si lo pusieras en `1`, con un trigger de cola intermitente?
4. Comparado con el HPA por CPU del Ejercicio 4, ¿por qué un trigger sobre *profundidad de cola* escala "antes" y evita el sobrecosto de reaccionar tarde?

---

## Ejercicio 6 — Optimizar la capa de nodos: bin-packing, Cluster Autoscaler y Karpenter

Right-sizing y HPA/KEDA optimizan lo que corre **dentro** de los nodos. Pero la factura la determinan los **nodos** encendidos. Un cluster puede tener Pods perfectamente dimensionados y aun así desperdiciar la mitad de la capacidad por mala consolidación. Aquí entran el bin-packing del scheduler, el [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) y [Karpenter](https://karpenter.sh/docs/) (proyecto CNCF).

> **Nota:** los pasos de aprovisionamiento real de nodos requieren un cluster gestionado en un cloud (p. ej. EKS). En `kind` tratá los manifiestos de Karpenter como *lectura conceptual*: la mecánica y los trade-offs se evalúan igual en las preguntas.

### Pasos

1. Medí la **densidad actual**: cuánto de cada nodo está reservado por `requests` frente a su capacidad. Este ratio es la eficiencia de bin-packing:

   ```bash
   kubectl describe nodes | grep -A5 "Allocated resources"
   ```

   Salida esperada (un nodo con mucho margen libre = candidato a consolidación):

   ```
   Allocated resources:
     Resource           Requests      Limits
     cpu                420m (10%)    600m (15%)
     memory             480Mi (6%)    900Mi (12%)
   ```

2. Entendé el círculo virtuoso: al haber bajado los `requests` en el Ejercicio 3, más Pods entran por nodo → el mismo trabajo cabe en **menos nodos** → el autoscaler de nodos puede apagar los sobrantes. **El right-sizing es el prerrequisito del ahorro a nivel nodo, no una optimización independiente.**

3. **Cluster Autoscaler (modelo clásico):** trabaja sobre *node groups* preexistentes (ASGs). Agrega nodos cuando hay Pods `Pending` por falta de recursos y elimina nodos infrautilizados si sus Pods reubican. Flags de consolidación típicos:

   ```
   --scale-down-utilization-threshold=0.5     # marca "infrautilizado" bajo 50%
   --scale-down-unneeded-time=10m             # cuánto espera antes de apagar
   ```

4. **Karpenter (modelo just-in-time):** en vez de node groups fijos, aprovisiona la **instancia exacta** que hace falta para los Pods `Pending`, y **consolida** activamente. Definí un `NodePool` que prioriza spot y deja consolidar:

   ```yaml
   # nodepool.yaml (conceptual salvo en EKS con Karpenter instalado)
   apiVersion: karpenter.sh/v1
   kind: NodePool
   metadata:
     name: default
   spec:
     template:
       spec:
         requirements:
           - key: karpenter.sh/capacity-type
             operator: In
             values: ["spot", "on-demand"]     # prefiere spot (hasta ~70–90% más barato)
           - key: kubernetes.io/arch
             operator: In
             values: ["amd64", "arm64"]         # habilita Graviton/ARM, más barato por core
         nodeClassRef:
           group: karpenter.k8s.aws
           kind: EC2NodeClass
           name: default
     disruption:
       consolidationPolicy: WhenEmptyOrUnderutilized
       consolidateAfter: 30s                     # reempaqueta agresivamente para bajar costo
     limits:
       cpu: "1000"                               # techo de gasto: no aprovisiona sin fin
   ```

5. Observá la consolidación en acción (en un cluster con Karpenter). Al bajar la carga, Karpenter reprograma Pods y termina nodos vacíos:

   ```bash
   kubectl get nodeclaims
   kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter | grep -i consolidat
   ```

   Salida esperada (log):

   ```
   consolidating via Delete, terminating 1 candidate node ip-10-0-3-14 ...
   ```

6. Protegé la disponibilidad del ahorro. La consolidación **desaloja** Pods; sin un `PodDisruptionBudget` podría cortar tu servicio al reempaquetar:

   ```yaml
   # pdb-web.yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: web
     namespace: finops-lab
   spec:
     minAvailable: 2
     selector:
       matchLabels: { app: web }
   ```

   ```bash
   kubectl apply -f pdb-web.yaml
   ```

### Preguntas de comprensión

1. Explicá con tus palabras por qué el right-sizing del Ejercicio 3 es un **prerrequisito** para que el autoscaler de nodos genere ahorro, y no una optimización aparte.
2. Diferencia central: Cluster Autoscaler escala *node groups* preexistentes; Karpenter aprovisiona *instancias just-in-time*. Dá un caso donde el modelo de Karpenter reduce costo que el Cluster Autoscaler no puede tocar.
3. `consolidationPolicy: WhenEmptyOrUnderutilized` con `consolidateAfter: 30s` es agresivo. ¿Qué ahorra y qué riesgo de estabilidad introduce en cargas con arranque lento?
4. Instancias **spot** cuestan mucho menos pero pueden ser reclamadas con ~2 min de aviso. ¿Qué combinación de `PodDisruptionBudget`, `terminationGracePeriod` y diseño de la app hace que spot sea seguro? ¿Qué carga **nunca** pondrías en spot?
5. ¿Por qué el `limits.cpu` del `NodePool` es un control FinOps imprescindible y no un mero detalle?

---

## Síntesis — el ciclo FinOps sobre Kubernetes

Recorriste las cuatro palancas y su orden correcto de aplicación:

1. **Medir** (OpenCost) — sin costo atribuido no hay decisión, solo opinión.
2. **Right-size** (VPA `Off` + Goldilocks) — ajustar `requests` al uso real observado.
3. **Escalar** (HPA reactivo / KEDA event-driven + scale-to-zero) — pagar por réplicas solo cuando hay trabajo.
4. **Consolidar** (bin-packing + Cluster Autoscaler / Karpenter + spot) — que la capacidad de nodos siga a la demanda real.

La regla que las une: **cada palanca depende de la anterior.** Escalar bien sobre `requests` inflados solo multiplica el desperdicio; consolidar nodos sin right-sizing previo no encuentra qué apagar.

### Fuentes oficiales

- CNCF — CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenCost (CNCF) — documentación y API: https://www.opencost.io/docs/
- Kubernetes — Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes Autoscaler — Vertical Pod Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Kubernetes Autoscaler — Cluster Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- KEDA (CNCF) — Scaling Deployments & scalers: https://keda.sh/docs/latest/
- Karpenter (CNCF) — NodePools y consolidación: https://karpenter.sh/docs/
- Goldilocks (Fairwinds): https://goldilocks.docs.fairwinds.com/
- metrics-server (SIG): https://github.com/kubernetes-sigs/metrics-server
- FinOps Foundation — principios y framework: https://www.finops.org/framework/

---

<details>
<summary><strong>Respuestas — verificá tu comprensión</strong></summary>

### Ejercicio 1

1. El scheduler usa **`requests`** (no `limits`) para el filtrado/priorización de nodos: reserva capacidad por request. Con `web` pidiendo 1000m/1Gi por réplica, el scheduler aparta 3 CPU y 3Gi aunque el uso real sea ~3m/19Mi; esa capacidad reservada queda facturable e indisponible para otros Pods, aunque nunca se use.
2. Porque en Kubernetes **se factura la reserva, no el consumo instantáneo**: los 1000m del request retiran capacidad del pool asignable del nodo; ese "hueco" no puede ser usado por otro Pod, así que el core-hora del nodo on-demand se paga completo esté ocioso o no. La eficiencia = uso/request; a menor eficiencia, más dinero quemado.
3. **Slack** = capacidad reservada por `requests` que no se usa (`request − usage`, agregada). Se mira el ratio `usage/request` y no el uso absoluto porque un uso de 3m puede ser perfectamente correcto (request de 5m, eficiencia 60 %) o un desastre (request de 1000m, eficiencia 0.3 %); solo el ratio revela cuánto se puede recortar sin afectar la carga.

### Ejercicio 2

1. `cpuEfficiency: 0.001` = "se usa el 0.1 % de la CPU que se paga" → estás facturando ~1000× la CPU necesaria. Acción: bajar `requests.cpu` de `web` de 1000m a un valor cercano al uso observado (con colchón), tarea del Ejercicio 3.
2. Porque el `request` es lo que el scheduler **apartó y facturó**; el uso puede fluctuar pero la reserva es fija y es la que cuesta. El **uso puede superar al request** en cargas Burstable bajo pico (el container consume por encima de su request hasta el `limit`); ese exceso lo captura `cpuCoreUsageAverage` y hace que `cpuEfficiency` supere 1.0, señal de **under-provisioning** (riesgo de throttling/OOM), el problema inverso.
3. Porque el right-sizing de *compute* (Ejercicios 3–4) actúa sobre `requests.cpu`/`memory`; `networkCost`, `pvCost` y `loadBalancerCost` responden a otras palancas (tráfico, almacenamiento, balanceadores) y no se corrigen tocando `requests`. Se optimizan en flujos FinOps distintos.
4. En un cluster gestionado, OpenCost obtiene el precio por core-hora del **adaptador de cloud-billing** del proveedor (p. ej. la API de precios / Cost and Usage Report). Sin conectarlo aplica un precio `default` genérico, así que las eficiencias/ratios son correctas pero los **dólares** no; tomar decisiones de negocio exige el precio real, incluyendo diferencias spot vs. on-demand y por tipo de instancia.

### Ejercicio 3

1. `updateMode: "Off"` recomienda pero **no modifica** los Pods; mantiene al humano/GitOps en control. `updateMode: "Auto"` (en la versión estable) aplica cambios **recreando el Pod** —el VPA no puede cambiar recursos in-place en un Pod ya corriendo—, lo que causa reinicios disruptivos y potencial pérdida de disponibilidad. Por eso producción usa `Off` + aplicación gobernada.
2. En `Lower Bound` ahorrás más (request más chico ⇒ más densidad) pero introducís riesgo: el Lower Bound es el borde inferior del intervalo de confianza; ante variabilidad normal la carga superará el request, degradando el bin-packing garantizado y arriesgando throttling de CPU o eviction por memoria. `Target` es el balance recomendado.
3. **Guaranteed** (request = limit): máxima estabilidad y última prioridad de eviction, pero reservás el pico como base ⇒ más caro y peor densidad. **Burstable** (request < limit): reservás poco (barato, denso) y permitís picos hasta el limit, a cambio de menor prioridad y posible throttling/OOM bajo presión de nodo. El bin-packing denso lo favorece **Burstable** (requests bajos dejan caber más Pods).
4. VPA y HPA sobre la **misma métrica** (CPU) chocan porque compiten por la misma señal: el HPA quiere agregar réplicas cuando la CPU/request sube, mientras el VPA cambia el request bajo los pies del HPA, produciendo oscilaciones y decisiones contradictorias. Seguro: **VPA para memoria + HPA para CPU**, o VPA en `Off` (solo recomienda) mientras el HPA gestiona réplicas.
5. Que la carga "querría" más CPU/memoria que tu tope: la recomendación real (`Uncapped Target`) excede `maxAllowed`. Ignorarlo significa fijar un request artificialmente bajo que puede provocar throttling/OOM; conviene revisar por qué el tope es tan bajo o si la carga necesita otra clase de instancia.

### Ejercicio 4

1. `ceil(6 × 210/50) = ceil(6 × 4.2) = ceil(25.2) = 26`, recortado a `maxReplicas: 10`. El HPA saltaría al tope de 10.
2. Porque el HPA por CPU calcula utilización como **porcentaje del request** (`uso/request`); sin `requests.cpu` no hay denominador y la métrica de utilización es indefinida: el HPA **no puede escalar** ese Deployment (queda en estado sin métricas, `<unknown>/50%`).
3. Bajar réplicas es barato de equivocarse a la larga pero caro en riesgo inmediato: si bajás rápido y el pico vuelve, sufrís latencia/errores de SLO y un nuevo scale-up con cold starts. Subir tarde cuesta SLO. Por eso: **scale-up inmediato** (proteger el SLO ante picos) y **scale-down conservador** (300 s de estabilización para no apagar capacidad que enseguida vas a necesitar, evitando flapping). El costo del scale-down lento es marginal; el del flapping o la saturación es alto.
4. Escenarios: (a) picos de tráfico anticipables por evento externo (flash sale, campaña) donde la CPU sube recién cuando ya llegó la avalancha; (b) colas/backlog donde el trabajo se acumula antes de reflejarse en CPU. Se resuelven con **métricas predictivas o de leading-indicator** (profundidad de cola, RPS, métricas custom/externas) en vez de CPU reactiva — dominio del Ejercicio 5.

### Ejercicio 5

1. El HPA está diseñado con `minReplicas ≥ 1` porque razona sobre *utilización de réplicas existentes*: con cero réplicas no hay métrica que promediar (división indefinida) y no sabe "desde qué" escalar. La transición `0 ↔ 1` la maneja el **`keda-operator`** (activando/desactivando el ScaledObject); para `≥ 1` KEDA delega en un HPA estándar que crea y alimenta.
2. Trade-off: **cold start**. A cero réplicas, la primera petición espera el arranque del Pod (pull de imagen, boot, warm-up) → latencia alta en la primera request. Aceptable para un `worker` de cola (el mensaje espera unos segundos, nadie mira) pero peligroso en una API de checkout síncrona, donde ese arranque se traduce en timeouts o abandono del usuario.
3. Con `cooldownPeriod: 1`, ante un trigger intermitente el Deployment haría *thrashing*: baja a 0 apenas se vacía la cola y vuelve a arrancar al siguiente mensaje, pagando cold starts constantes y desgastando el scheduler. El costo de arrancar/parar repetido puede superar el de mantener una réplica. `cooldownPeriod` amortigua eso esperando antes de volver a cero.
4. La profundidad de cola es un **leading indicator**: crece en el instante en que llegan mensajes, antes de que se traduzca en CPU del consumidor. Escalar sobre ella permite provisionar capacidad *mientras* el backlog aparece, en vez de esperar a que la CPU suba (lagging indicator) — se evita el tramo de saturación y el sobrecosto de reaccionar tarde con capacidad de emergencia.

### Ejercicio 6

1. El autoscaler de nodos apaga máquinas cuando los Pods que las ocupan pueden reprogramarse en otras — y esa decisión se basa en **`requests`**, no en uso real. Si los `requests` están inflados (como `web` antes del Ejercicio 3), cada nodo "parece lleno" aunque esté ocioso, y no hay nada que consolidar. Al right-sizear, los requests reflejan el uso, más Pods entran por nodo, y recién ahí el autoscaler encuentra nodos infrautilizados que puede terminar. Sin el paso previo, no hay ahorro a nivel nodo.
2. Cluster Autoscaler solo puede crecer/encoger *node groups* con tipos de instancia predefinidos; Karpenter elige la instancia óptima just-in-time. Caso: una carga que pide `4 vCPU / 32Gi` en un cluster cuyos node groups son de `8 vCPU / 16Gi` — el Cluster Autoscaler enciende una instancia grande y desperdicia CPU, mientras Karpenter aprovisiona un tipo memoria-optimizado ajustado (o ARM/Graviton, o spot) que el CA ni contempla. Karpenter también consolida hacia tipos más baratos que un node group fijo no ofrece.
3. Ahorra al reempaquetar Pods agresivamente y terminar nodos apenas quedan subutilizados (menos capacidad ociosa facturada). Riesgo: en cargas con arranque lento o estado, la consolidación desaloja y re-crea Pods con frecuencia, provocando latencia de arranque, churn y posible impacto de SLO; hay que balancearla con PDBs, `do-not-disrupt` y ventanas de arranque razonables.
4. Spot es seguro cuando: (a) hay un **PDB** que impide desalojar demasiadas réplicas a la vez; (b) el `terminationGracePeriodSeconds` cabe dentro de la ventana de aviso (~2 min) para drenar limpio; (c) la app tolera la interrupción — es stateless o su estado está fuera del Pod, maneja `SIGTERM` para terminar en curso, y hay réplicas repartidas en varios tipos/AZ para no perder todo de golpe. **Nunca** en spot: cargas stateful de instancia única sin réplica (una DB primaria single-node), trabajos batch largos sin checkpointing, o control-plane/componentes sin los que el cluster no opera.
5. Porque Karpenter aprovisiona **just-in-time y sin node groups fijos**: ante Pods `Pending` seguiría creando nodos indefinidamente. El `limits.cpu` del `NodePool` es el **techo de gasto** que evita que un bug, un bucle de creación de Pods o un ataque de scheduling escalen la factura sin control; es el equivalente FinOps de un budget cap a nivel de aprovisionamiento.

</details>