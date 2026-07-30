# Tema 1.2: Using Cost Management Solutions for Right-Sizing and Scaling

Este tema cubre cómo usar herramientas de cost management en entornos cloud native para identificar desperdicio de recursos (waste), aplicar right-sizing a workloads y configurar scaling automático (horizontal y vertical) para optimizar el gasto sin sacrificar performance.

---

## Ejercicio 1: Visibilidad de costos con OpenCost

**Objetivo:** instalar una herramienta de cost visibility y entender cómo se calcula el costo de un namespace/workload.

1. Instalá `OpenCost` en tu cluster (puede ser minikube, kind o un cluster gestionado) usando <PERSON>:

```bash
helm repo add opencost https://opencost.github.io/opencost-helm-chart
helm repo update
helm install opencost opencost/opencost -n opencost --create-namespace
```

2. <PERSON> pods estén corriendo y expongan el endpoint de métricas:

```bash
kubectl get pods -n opencost
kubectl port-forward -n opencost svc/opencost 9003:9003
```

3. Consultá el endpoint de `allocation` para ver el costo por namespace en las últimas 24 horas:

```bash
curl "http://localhost:9003/allocation/compute?window=24h&aggregate=namespace"
```

4. Identificá en la respuesta JSON los campos `cpuCost`, `ramCost` y `pvCost` para al menos dos namespaces distintos.

> **Pregunta de verificación:**
> ¿Qué diferencia hay entre `cpuCost`/`ramCost` calculados sobre **requests** vs. <PERSON>*uso real (usage)**, y por qué esa diferencia es clave para detectar over-provisioning?

---

## Ejercicio 2: <PERSON> over-provisioning y aplicar right-sizing con VPA

**Objetivo:** usar el Vertical Pod Autoscaler en modo `Off`/recommendation para obtener sugerencias de right-sizing sin afectar producción.

1. Instalá los componentes de VPA (recommender, updater, admission-controller) en tu cluster:

```bash
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh
```

2. Desplegá un workload de prueba con requests <PERSON>

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
      - name: demo-app
        image: nginx
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
```

3. <PERSON> objeto `VerticalPodAutoscaler` en modo `Off` para solo obtener recomendaciones:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: demo-app-vpa
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: demo-app
  updatePolicy:
    updateMode: "Off"
```

4. Después de unos minutos de tráfico simulado, <PERSON>

```bash
kubectl describe vpa demo-app-vpa
```

5. Compará <PERSON>target` en la recomendación contra los `requests` originales del Deployment.

> **Pregunta de verificación:**
> ¿Por qué se recomienda usar `updateMode: "Off"` antes de pasar a `"Auto"` en un entorno productivo, y qué relación tiene esto con evitar cost regressions inesperadas?

---

## Ejercicio 3: Scaling horizontal basado en métricas de costo/uso real

**Objetivo:** configurar un HPA que escale en base a utilización real de CPU, evitando el patrón común de "requests altos, uso bajo" que infla el costo.

1. Asegurate de tener `metrics-server` instalado:

```bash
kubectl get deployment metrics-server -n kube-system
```

2. Ajustá los `requests` del Deployment `demo-app` a valores más realistas según la recomendación del VPA del ejercicio anterior (por ejemplo, `cpu: 100m`, `memory: 128Mi`).

3. <PERSON> HPA basado en utilización de CPU:

```bash
kubectl autoscale deployment demo-app --cpu-percent=60 --min=2 --max=10
```

4. <PERSON> carga sobre el servicio (por ejemplo con `hey` o `kubectl run load-generator`) y observá el escalado:

```bash
kubectl get hpa demo-app --watch
```

5. Con OpenCost (Ejercicio 1), volvé a consultar el costo del namespace y compará contra el costo <PERSON> right-sizing.

> **Pregunta de verificación:**
> Si hubieras dejado los `requests` originales (sobredimensionados) del Ejercicio 2 y solo agregaras el HPA, ¿el costo total del namespace bajaría significativamente? <PERSON> calcula `cpuCost` a partir de requests.

---

## Ejercicio 4: Scaling a nivel de cluster (nodos) con Cluster Autoscaler / Karpenter

**Objetivo:** entender cómo el scaling de nodos impacta <PERSON>, complementando el scaling a nivel de pod.

1. Revisá la configuración actual del node pool/group (cloud provider) y anotá el número mínimo y máximo de nodos configurado.

2. Si usás un cluster en un cloud provider compatible, instalá Karpenter (o Cluster Autoscaler según el proveedor):

```bash
helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter --create-namespace \
  --set settings.clusterName=<CLUSTER_NAME>
```

3. Definí un `NodePool` (Karpenter) que priorice instancias spot/preemptible y limite el tamaño máximo de recursos disponibles:

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
  limits:
    cpu: "100"
```

4. <PERSON> el Deployment `demo-app` a un número de réplicas que fuerce la creación de nodos nuevos (`kubectl scale deployment demo-app --replicas=50`) y observá:

```bash
kubectl get nodes --watch
kubectl get events -n karpenter
```

5. Reducí las réplicas de nuevo y verificá que Karpenter/Cluster Autoscaler haga *scale-down* (consolidation) de los nodos sobrantes.

> **Pregunta de verificación:**
> ¿Qué diferencia práctica existe, en términos de costo, entre configurar bien el **pod-level scaling** (HPA/VPA) sin tocar el **node-level scaling**, versus hacer ambos en conjunto?

---

## Ejercicio 5: Cerrando el ciclo — políticas de right-sizing continuo

**Objetivo:** integrar cost visibility con automatización <PERSON> right-sizing no sea una tarea manual única.

1. Usando la data de OpenCost del Ejercicio 1, identificá el namespace con mayor `cpuCost` pero menor eficiencia (`cpuCost` alto y utilización real baja — podés cruzar esto con `kubectl top pods`).

2. Aplicá un VPA en modo `Auto` (o `Recreate`) solo a ese namespace específico, y documentá el cambio esperado en requests:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: target-namespace-vpa
  namespace: <namespace-detectado>
spec:
  targetRef:
    apiVersion: "apps/v1"
    kind: Deployment
    name: <deployment-name>
  updatePolicy:
    updateMode: "Auto"
```

3. Definí un `ResourceQuota` a nivel de namespace para poner un techo de gasto/consumo, evitando regresiones futuras:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: cost-guardrail
  namespace: <namespace-detectado>
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
```

4. Volvé a correr la consulta de `allocation` de OpenCost 24 horas después y compará el costo del namespace antes/después.

> **Pregunta de verificación:**
> ¿Por qué combinar `VPA` + `ResourceQuota` es una estrategia más sostenible de cost management que aplicar right-sizing manual una sola vez?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1:**
El costo calculado sobre **requests** refleja lo que el workload "reserva" y por lo tanto lo que el cluster factura/aprovisiona como capacidad, <PERSON> no. El costo calculado sobre **usage** refleja el consumo real. Cuando `cpuCost`/`ramCost` basado en requests es mucho mayor que el basado en usage, eso es la señal directa de **over-provisioning**: <PERSON> capacidad reservada que no se utiliza, y es el primer indicador para iniciar un proceso de right-sizing.

**Ejercicio 2:**
`updateMode: "Off"` permite que el VPA calcule y muestre recomendaciones sin aplicar cambios automáticos a los pods (no hay restart ni eviction). Esto es clave porque `"Auto"` puede recrear pods para aplicar los nuevos valores de requests, lo que puede causar disrupciones (downtime parcial, pérdida de estado en memoria, etc.). Validar primero las recomendaciones en modo `Off` evita aplicar cambios de recursos que podrían, por ejemplo, subdimensionar un workload y generar throttling o OOMKills, <PERSON> (por incidentes, reintentos, <PERSON>) que el que se pretendía ahorrar.

**Ejercicio 3:**
No bajaría significativamente. El HPA cambia el **número de réplicas**, pero cada réplica sigue reservando el mismo `request` sobredimensionado por pod. Como OpenCost (y la mayoría de herramientas de cost allocation) calculan `cpuCost` en base a los requests reservados y no solo <PERSON>, tener más réplicas con requests altos puede incluso **aumentar** el costo total, aunque el uso real por pod sea bajo. El right-sizing de requests (VPA) y el scaling de réplicas (HPA) deben aplicarse juntos para obtener el ahorro real.

**Ejercicio 4:**
Hacer solo pod-level scaling optimiza cómo <PERSON> los pods dentro de los nodos existentes, <PERSON> tiene nodos fijos o mal dimensionados, <PERSON> por capacidad de nodo ociosa cuando hay pocos pods, o se sufre falta de capacidad cuando hay muchos. Combinar node-level scaling (Cluster Autoscaler/Karpenter) con pod-level scaling permite que <PERSON> y decrezca en función de la demanda real agregada, evitando pagar por nodos "vacíos" y permitiendo aprovechar estrategias de menor costo (spot instances, consolidation, bin-packing eficiente).

**Ejercicio 5:**
El right-sizing manual es una foto puntual: los patrones de tráfico, versiones de la app y dependencias cambian con el tiempo, por lo que las necesidades de recursos también cambian, y sin un mecanismo continuo el sistema vuelve a estar mal dimensionado con el tiempo (drift). `VPA` en modo `Auto` mantiene los requests ajustados de forma continua según el uso real observado, mientras que `ResourceQuota` actúa como guardrail para evitar que, por error humano o mala configuración, un namespace vuelva a sobredimensionarse sin control. Juntos forman un ciclo de cost management continuo en lugar de una intervención única.

</details>