# Ejercicios guiados — Tema 2.2: Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

> **Objetivo de la práctica.** Vas a instrumentar un cluster, extraer las cuatro *DORA metrics*, medir la eficiencia de asignación de recursos (*allocation efficiency*), calcular costo por workload y traducir *golden signals* en un *error budget* accionable. Cada bloque termina con preguntas de verificación; las respuestas están al final en la sección colapsable.
>
> **Requisitos previos.** Un cluster Kubernetes ≥ 1.28 (kind, k3d o gestionado), `kubectl`, `helm` v3, y permisos de `cluster-admin`. Los ejercicios usan namespaces desechables; se limpian al final.

---

## Ejercicio 1 — Instrumentar el cluster: `metrics-server`, `kube-state-metrics` y Prometheus

Antes de medir eficiencia hace falta la fuente de verdad. Distinguí dos capas: `metrics-server` sirve el **uso instantáneo** para `kubectl top` y el HPA; `kube-state-metrics` (KSM) expone el **estado declarado** del API (requests, limits, réplicas, generaciones), y Prometheus **retiene la serie temporal** que permite calcular ratios y tendencias.

1. Instalá `metrics-server` (si tu distro no lo trae) y verificá que responde:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   # En kind/k3d agregá --kubelet-insecure-tls al deployment:
   kubectl -n kube-system patch deployment metrics-server --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   kubectl -n kube-system rollout status deploy/metrics-server
   ```

2. Confirmá que el API de métricas está registrado y devuelve datos:

   ```bash
   kubectl top nodes
   ```

   Salida esperada (valores ilustrativos):

   ```
   NAME                 CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
   kind-control-plane   241m         3%     1284Mi          16%
   kind-worker          118m         1%     742Mi           9%
   ```

3. Instalá el stack de Prometheus con KSM y node-exporter incluidos:

   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install kps prometheus-community/kube-prometheus-stack \
     --namespace monitoring --create-namespace \
     --set grafana.enabled=true
   kubectl -n monitoring rollout status deploy/kps-kube-state-metrics
   ```

4. Abrí un port-forward a Prometheus y dejalo corriendo en otra terminal:

   ```bash
   kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
   ```

5. Desplegá una carga de prueba deliberadamente **sobre-aprovisionada** (pide mucho más de lo que consume), que es el caso que vas a medir en el Ejercicio 3:

   ```yaml
   # demo-app.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: demo
     namespace: efficiency-lab
     labels: { app: demo }
   spec:
     replicas: 3
     selector: { matchLabels: { app: demo } }
     template:
       metadata: { labels: { app: demo } }
       spec:
         containers:
           - name: web
             image: registry.k8s.io/e2e-test-images/agnhost:2.47
             args: ["serve-hostname", "--http", "--port=8080"]
             ports: [{ containerPort: 8080 }]
             resources:
               requests: { cpu: "500m", memory: "512Mi" }
               limits:   { cpu: "1",    memory: "1Gi" }
   ```

   ```bash
   kubectl create namespace efficiency-lab
   kubectl apply -f demo-app.yaml
   kubectl -n efficiency-lab rollout status deploy/demo
   ```

6. Verificá en la UI de Prometheus (`http://localhost:9090`) que KSM está exponiendo los *requests* declarados. Ejecutá esta consulta PromQL:

   ```promql
   sum(kube_pod_container_resource_requests{namespace="efficiency-lab", resource="cpu"})
   ```

   Debería devolver `1.5` (3 réplicas × 500m).

**Preguntas de comprensión — Bloque 1**

- **1a.** `metrics-server` y `kube-state-metrics` exponen métricas distintas y no son intercambiables. ¿Qué mide cada uno y por qué el HPA depende del primero pero no del segundo?
- **1b.** La consulta del paso 6 usa `kube_pod_container_resource_requests`, no `container_memory_working_set_bytes`. Para medir "cuánto está pidiendo la plataforma" vs "cuánto usa realmente", ¿cuál corresponde a cada lado del ratio?
- **1c.** ¿Por qué `kubectl top` **no** sirve para calcular tendencias históricas de eficiencia, y qué componente resuelve esa limitación?

---

## Ejercicio 2 — Las cuatro DORA metrics: deployment frequency y lead time for changes

Las *DORA metrics* (dora.dev) son el estándar de facto para medir el rendimiento de entrega de software. Dos miden **throughput** (deployment frequency, lead time for changes) y dos miden **estabilidad** (change failure rate, time to restore service). En este bloque calculás las dos de throughput a partir de datos observables del cluster y de la metadata de los deployments.

1. Simulá una historia de despliegues cambiando la imagen del deployment varias veces. Cada `set image` que produce un rollout es un "deployment" en términos DORA:

   ```bash
   for tag in 2.45 2.46 2.47; do
     kubectl -n efficiency-lab set image deploy/demo \
       web=registry.k8s.io/e2e-test-images/agnhost:$tag
     kubectl -n efficiency-lab rollout status deploy/demo --timeout=120s
     sleep 5
   done
   ```

2. Inspeccioná el historial de rollouts, que es la evidencia cruda de la **deployment frequency**:

   ```bash
   kubectl -n efficiency-lab rollout history deploy/demo
   ```

   Salida esperada:

   ```
   deployment.apps/demo
   REVISION  CHANGE-CAUSE
   1         <none>
   2         <none>
   3         <none>
   4         <none>
   ```

3. En un pipeline real, la deployment frequency se emite como evento a un backend de métricas. Aproximala en Prometheus contando cambios de generación del deployment en una ventana de tiempo. En la UI de Prometheus:

   ```promql
   changes(kube_deployment_status_observed_generation{namespace="efficiency-lab", deployment="demo"}[1h])
   ```

   > **Nota de precisión.** Esta consulta es una *aproximación* válida en el lab: cuenta reconciliaciones de generación, no despliegues de negocio. La medición canónica de DORA se hace en el sistema de CD (Argo CD, Flux, GitHub Actions) emitiendo un evento por release. Prometheus solo la reconstruye si el metadato existe.

4. Calculá **lead time for changes** = tiempo entre el commit y su llegada a producción. Extraé los dos timestamps que lo delimitan:

   ```bash
   # Momento en que el pod entró en Running (proxy del "deploy terminado")
   kubectl -n efficiency-lab get pods -l app=demo \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.startTime}{"\n"}{end}'
   ```

   Salida esperada:

   ```
   demo-7c9f8b6d55-abcde   2026-08-07T14:32:11Z
   demo-7c9f8b6d55-fghij   2026-08-07T14:32:13Z
   demo-7c9f8b6d55-klmno   2026-08-07T14:32:12Z
   ```

   Si el commit correspondiente fue a las `14:07:44Z`, el lead time de ese cambio ≈ **24 min 27 s**. En una plataforma se automatiza propagando el `git commit SHA` como label/annotation hasta el pod y restando `pod.startTime − commit.time`.

5. Ubicá tus números en las bandas de rendimiento de DORA (2023 *Accelerate State of DevOps Report*):

   | Métrica | Elite | High | Medium | Low |
   |---|---|---|---|---|
   | Deployment frequency | On-demand (varios/día) | 1/día – 1/semana | 1/semana – 1/mes | < 1/mes |
   | Lead time for changes | < 1 día | 1 día – 1 semana | 1 semana – 1 mes | > 1 mes |
   | Change failure rate | 0–15 % | 16–30 % | 16–30 % | 16–30 % |
   | Failed deployment recovery time (MTTR) | < 1 hora | < 1 día | 1 día – 1 semana | > 1 semana |

**Preguntas de comprensión — Bloque 2**

- **2a.** Deployment frequency y lead time for changes miden ambas "velocidad", pero responden preguntas distintas. ¿Cuál es la diferencia conceptual y por qué una plataforma puede tener alta frecuencia y a la vez mal lead time?
- **2b.** La consulta `changes(kube_deployment_status_observed_generation[...])` se marcó explícitamente como aproximación. ¿Qué tipo de "despliegue" cuenta de más o de menos frente a la definición DORA, y dónde debería medirse realmente?
- **2c.** Las cuatro DORA metrics se agrupan en dos ejes. Nombrá el eje de cada métrica y explicá por qué optimizar throughput sin mirar el eje opuesto es una trampa clásica.

---

## Ejercicio 3 — Eficiencia de asignación: el *slack* entre requests y uso real

El desperdicio de plataforma más grande y silencioso es el **slack**: la diferencia entre lo que los pods *reservan* (requests, que consumen capacidad de scheduling) y lo que *usan*. Un cluster con 30 % de utilización real pero 90 % de requests reservados no puede programar más pods aunque esté casi vacío.

1. Medí la **allocation efficiency de CPU** del namespace de prueba — cuánto del CPU reservado se está usando de verdad:

   ```promql
   sum(rate(container_cpu_usage_seconds_total{namespace="efficiency-lab", container!=""}[5m]))
   /
   sum(kube_pod_container_resource_requests{namespace="efficiency-lab", resource="cpu"})
   ```

   Salida esperada (la app está casi ociosa): `~0.004` → **0.4 %**. Reservaste 1.5 cores y usás ~6 milicores.

2. Hacé lo mismo para memoria, usando `working_set` (la métrica que el OOM-killer observa, no `container_memory_usage_bytes`):

   ```promql
   sum(container_memory_working_set_bytes{namespace="efficiency-lab", container!=""})
   /
   sum(kube_pod_container_resource_requests{namespace="efficiency-lab", resource="memory"})
   ```

   Salida esperada: `~0.03` → **3 %**. Reservaste 1.5 GiB, usás ~45 MiB.

3. Pedí una recomendación de *right-sizing* automática. Instalá el Vertical Pod Autoscaler en modo **recommender** (sin aplicar cambios):

   ```bash
   git clone https://github.com/kubernetes/autoscaler.git
   ./autoscaler/vertical-pod-autoscaler/hack/vpa-up.sh
   ```

   ```yaml
   # vpa-demo.yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata:
     name: demo-vpa
     namespace: efficiency-lab
   spec:
     targetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: demo
     updatePolicy:
       updateMode: "Off"   # solo recomienda, no reinicia pods
   ```

   ```bash
   kubectl apply -f vpa-demo.yaml
   sleep 120  # el recommender necesita muestras
   kubectl -n efficiency-lab describe vpa demo-vpa
   ```

   Salida esperada (fragmento):

   ```
   Recommendation:
     Container Recommendations:
       Container Name:  web
       Lower Bound:
         Cpu:     11m
         Memory:  52428800
       Target:
         Cpu:     15m
         Memory:  62914560
       Upper Bound:
         Cpu:     84m
         Memory:  104857600
   ```

4. Comparcommunica el `Target` recomendado (15m CPU / 60Mi) contra tus requests declarados (500m / 512Mi). El ratio de sobre-aprovisionamiento es ~33× en CPU y ~8× en memoria. Aplicá el right-sizing:

   ```bash
   kubectl -n efficiency-lab set resources deploy/demo \
     --requests=cpu=20m,memory=64Mi --limits=cpu=100m,memory=128Mi
   kubectl -n efficiency-lab rollout status deploy/demo
   ```

5. Re-ejecutá la consulta del paso 1. La allocation efficiency de CPU debería subir de ~0.4 % a un rango sano (**> 30 %**), sin haber tocado el uso real: solo bajaste la reserva.

**Preguntas de comprensión — Bloque 3**

- **3a.** ¿Por qué usar `container_memory_working_set_bytes` y no `container_memory_usage_bytes` al comparar contra el request de memoria? ¿Qué error de decisión introduciría la segunda?
- **3b.** El VPA se aplicó con `updateMode: "Off"`. ¿Qué garantiza ese modo, y por qué en una plataforma multi-tenant conviene empezar así antes de `"Auto"`?
- **3c.** Bajar los requests subió la *allocation efficiency* sin cambiar el uso real. Explicá qué ganó concretamente el cluster con ese cambio (pista: pensá en el scheduler y en el *bin-packing*, no en el consumo).
- **3d.** El request quedó en 20m pero el `Target` del VPA era 15m, con `Upper Bound` de 84m. ¿Por qué no fijar el request exactamente en el `Target`? ¿Qué rol juega el `Upper Bound`?

---

## Ejercicio 4 — Eficiencia de costo: costo por namespace con OpenCost

La eficiencia técnica (utilización) se traduce a dinero mediante *cost allocation*. OpenCost (proyecto CNCF, opencost.io) mapea el consumo de recursos a las tarifas del proveedor y lo reparte por namespace, deployment o label.

1. Instalá OpenCost apuntando a tu Prometheus existente:

   ```bash
   helm install opencost --repo https://opencost.github.io/opencost-helm-chart opencost \
     --namespace opencost --create-namespace \
     --set opencost.prometheus.internal.enabled=false \
     --set opencost.prometheus.external.url="http://kps-kube-prometheus-stack-prometheus.monitoring:9090"
   kubectl -n opencost rollout status deploy/opencost
   ```

2. Consultá la asignación de costo por namespace de la última hora vía su API:

   ```bash
   kubectl -n opencost port-forward svc/opencost 9003:9003 &
   curl -sG 'http://localhost:9003/allocation/compute' \
     --data-urlencode 'window=1h' \
     --data-urlencode 'aggregate=namespace' \
     --data-urlencode 'accumulate=true' | jq '.data[] | {name, cpuCost, ramCost, totalCost, totalEfficiency}'
   ```

   Salida esperada (fragmento):

   ```json
   {
     "name": "efficiency-lab",
     "cpuCost": 0.00042,
     "ramCost": 0.00019,
     "totalCost": 0.00061,
     "totalEfficiency": 0.34
   }
   ```

3. Fijate en `totalEfficiency`: es el mismo concepto del Ejercicio 3 (uso/request) pero **ponderado por costo**. Un namespace puede tener buena eficiencia de CPU y pésima de RAM; el costo pondera cuál importa más según las tarifas.

4. Calculá el **costo unitario de plataforma** — una métrica clave de FinOps para reportar a negocio. Por ejemplo, costo por 1000 requests servidos: dividí `totalCost` por el conteo de requests del mismo período (obtenido de tu métrica de tráfico del Ejercicio 5).

**Preguntas de comprensión — Bloque 4**

- **4a.** OpenCost expone `cpuCost` y `ramCost` por separado antes de sumarlos. ¿Por qué esa separación cambia la decisión de right-sizing frente a mirar solo `totalCost`?
- **4b.** La `totalEfficiency` de costo puede ser alta aunque la utilización de CPU sea baja. ¿En qué escenario de tarifas pasa eso y qué recurso deberías atacar primero?
- **4c.** ¿Por qué un "costo por 1000 requests" es una métrica de eficiencia más honesta para reportar a negocio que el "costo total del cluster"?

---

## Ejercicio 5 — De golden signals a SLO y error budget

Las *golden signals* (latency, traffic, errors, saturation — Google SRE Book) son los cuatro indicadores mínimos de salud. El paso de "medir" a "mejorar" es convertirlas en un **SLO** con su **error budget**: el presupuesto de fallo que autoriza —o congela— nuevos despliegues, cerrando el círculo con las DORA metrics del Ejercicio 2.

1. Generá tráfico sostenido contra la demo para tener *traffic* y *latency* reales:

   ```bash
   kubectl -n efficiency-lab run load --image=williamyeh/hey --restart=Never -- \
     -z 5m -q 20 http://demo.efficiency-lab.svc:8080/
   ```

2. Definí las cuatro señales en PromQL (asumiendo que la app expone `http_request_duration_seconds` y `http_requests_total`; si no, usá las métricas del ingress-controller):

   ```promql
   # Latency — p99 en segundos
   histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

   # Traffic — requests por segundo
   sum(rate(http_requests_total[5m]))

   # Errors — proporción de 5xx
   sum(rate(http_requests_total{status=~"5.."}[5m]))
   /
   sum(rate(http_requests_total[5m]))

   # Saturation — CPU del namespace vs su límite
   sum(rate(container_cpu_usage_seconds_total{namespace="efficiency-lab"}[5m]))
   /
   sum(kube_pod_container_resource_limits{namespace="efficiency-lab", resource="cpu"})
   ```

3. Definí un **SLO de disponibilidad** del 99.9 % sobre una ventana de 30 días. El SLI es la proporción de requests "buenos" (no-5xx):

   ```promql
   1 - (
     sum(increase(http_requests_total{status=~"5.."}[30d]))
     /
     sum(increase(http_requests_total[30d]))
   )
   ```

4. Calculá el **error budget** consumido. Con un SLO de 99.9 %, el budget es 0.1 % de los requests. La fracción de budget gastada:

   ```promql
   (
     sum(increase(http_requests_total{status=~"5.."}[30d]))
     /
     sum(increase(http_requests_total[30d]))
   ) / 0.001
   ```

   - Resultado `< 1` → hay budget → **los despliegues siguen habilitados**.
   - Resultado `≥ 1` → budget agotado → **freeze de features**, el equipo prioriza estabilidad.

5. Calculá la **burn rate** para alertas rápidas — cuántas veces más rápido de lo sostenible estás quemando el budget en la última hora:

   ```promql
   (
     sum(rate(http_requests_total{status=~"5.."}[1h]))
     /
     sum(rate(http_requests_total[1h]))
   ) / 0.001
   ```

   Una burn rate de `14.4` significa que a ese ritmo agotás el budget de 30 días en ~2 días: umbral típico de alerta *page* (Google SRE, *Alerting on SLOs*).

**Preguntas de comprensión — Bloque 5**

- **5a.** El error budget conecta directamente con las DORA metrics del Ejercicio 2. Explicá el mecanismo: ¿cómo un budget agotado frena la *deployment frequency*, y por qué eso es una feature y no un bug?
- **5b.** El SLI del paso 3 mide latency con `histogram_quantile(0.99, ...)` en lugar del promedio (`avg`). ¿Qué esconde el promedio que el p99 revela, y por qué importa para la experiencia real del usuario?
- **5c.** La *saturation* del paso 2 se calcula contra `limits`, no contra `requests`. ¿Por qué es la referencia correcta para saturación, mientras que en el Ejercicio 3 la eficiencia se medía contra `requests`?
- **5d.** Una burn rate de 14.4 dispara un *page*, pero una de 1.5 sostenida durante días también agota el budget. ¿Por qué se configuran *múltiples* ventanas de burn rate (corta y larga) en lugar de una sola?

---

## Ejercicio 6 — Utilización de nodos y eficiencia de bin-packing

La eficiencia de asignación por pod (Ejercicio 3) sube al nivel de cluster como **bin-packing**: cuán compactamente el scheduler empaqueta pods en nodos. Nodos medio vacíos que no se pueden consolidar son gasto puro.

1. Medí la utilización real de CPU por nodo:

   ```promql
   1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
   ```

2. Medí la **presión de scheduling** — cuánto de la capacidad *asignable* de cada nodo ya está reservada por requests (esto, no el uso real, es lo que limita programar pods nuevos):

   ```promql
   sum by (node) (kube_pod_container_resource_requests{resource="cpu"})
   /
   sum by (node) (kube_node_status_allocatable{resource="cpu"})
   ```

3. Detectá el patrón de desperdicio: nodos con **requests altos pero uso real bajo**. Si el paso 2 da 0.85 y el paso 1 da 0.10, tenés nodos "llenos de reservas, vacíos de trabajo" — exactamente el slack del Ejercicio 3 pero facturado como hardware.

4. Verificá si el Cluster Autoscaler podría consolidar. Contá cuántos nodos podrían drenarse si los requests estuvieran bien dimensionados:

   ```bash
   kubectl get nodes -o custom-columns=\
   'NODE:.metadata.name,ALLOC_CPU:.status.allocatable.cpu,ALLOC_MEM:.status.allocatable.memory'
   ```

   ```bash
   # Requests totales reservados por nodo (suma de pods programados en él)
   kubectl describe nodes | grep -A5 'Allocated resources'
   ```

   Salida esperada (fragmento por nodo):

   ```
   Allocated resources:
     Resource           Requests     Limits
     cpu                220m (2%)    100m (1%)
     memory             190Mi (2%)   328Mi (4%)
   ```

5. Con los requests ya corregidos en el Ejercicio 3, el porcentaje reservado cae a un dígito y el autoscaler (o vos manualmente con `kubectl drain` + `cordon`) puede consolidar workloads en menos nodos. Esa consolidación es la mejora de eficiencia que cierra el ciclo medición → acción.

**Preguntas de comprensión — Bloque 6**

- **6a.** ¿Por qué el *bin-packing* se evalúa contra `kube_node_status_allocatable` y no contra `capacity`? ¿Qué diferencia hay entre ambos?
- **6b.** Un nodo con 85 % de CPU *reservado* (requests) pero 10 % *usado* no puede programar más pods. ¿Por qué el scheduler bloquea aunque haya CPU física libre, y qué campo del pod lo causa?
- **6c.** El Cluster Autoscaler consolida nodos infrautilizados, pero no lo hará si un solo pod sin réplica lo impide. ¿Qué mecanismos (PDB, requests correctos, `safe-to-evict`) hay que alinear para que la consolidación efectivamente ocurra?

---

## Limpieza

```bash
kubectl delete namespace efficiency-lab opencost
helm -n monitoring uninstall kps
./autoscaler/vertical-pod-autoscaler/hack/vpa-down.sh
```

---

## Fuentes

- **DORA / Accelerate State of DevOps Report** — definiciones y bandas de las cuatro métricas: https://dora.dev/guides/dora-metrics-four-keys/
- **Google SRE Book — Monitoring Distributed Systems (golden signals)**: https://sre.google/sre-book/monitoring-distributed-systems/
- **Google SRE Workbook — Alerting on SLOs (burn rate)**: https://sre.google/workbook/alerting-on-slos/
- **Prometheus — querying / `histogram_quantile`**: https://prometheus.io/docs/prometheus/latest/querying/functions/
- **kube-state-metrics — métricas expuestas**: https://github.com/kubernetes/kube-state-metrics/tree/main/docs
- **Kubernetes — Vertical Pod Autoscaler**: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- **OpenCost (CNCF) — cost allocation API**: https://www.opencost.io/docs/integrations/api
- **Kubernetes — Managing Resources for Containers (requests/limits)**: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/

---

<details>
<summary><strong>Respuestas — verificación de comprensión</strong></summary>

### Bloque 1

**1a.** `metrics-server` agrega el **uso instantáneo** (CPU/memoria en vivo) que reportan los kubelets vía la Summary API, y lo sirve a través de la Metrics API (`metrics.k8s.io`); no retiene historia. El HPA lo consulta porque necesita el uso *actual* para decidir escalar. `kube-state-metrics` no mide uso: transforma el **estado declarado del API server** (requests, limits, réplicas, generaciones, fases) en métricas. El HPA no lo usa para escalar por CPU porque KSM no sabe cuánto CPU se está consumiendo, solo cuánto se reservó.

**1b.** El **uso real** es `container_memory_working_set_bytes` / `rate(container_cpu_usage_seconds_total[...])` (numerador del ratio de eficiencia). Lo **pedido/reservado** es `kube_pod_container_resource_requests` (denominador). Eficiencia de asignación = uso ÷ request.

**1c.** `kubectl top` es una foto instantánea sin retención: no podés calcular tendencias, percentiles ni promedios de ventana. Prometheus resuelve esto guardando la serie temporal, lo que permite `rate()`, `avg_over_time`, percentiles y comparaciones históricas.

### Bloque 2

**2a.** **Deployment frequency** mide *con qué cadencia* llegás a producción (throughput de releases). **Lead time for changes** mide *cuánto tarda un cambio concreto* desde el commit hasta producción. Podés desplegar muchas veces por día (alta frecuencia) pero que cada cambio arrastre semanas de revisión/QA antes de entrar en la cola (mal lead time): son ejes independientes. Frecuencia = ritmo del pipeline; lead time = latencia de un cambio a través de él.

**2b.** Cuenta de más las reconciliaciones que no son releases de negocio (un `kubectl scale`, un cambio de label, un rollback también incrementan la generación observada) y de menos los despliegues que no pasan por ese deployment (jobs, cambios de config vía otro recurso). La medición canónica se hace en el **sistema de CD**, emitiendo un evento explícito por cada release a producción.

**2c.** Throughput: *deployment frequency* y *lead time for changes*. Estabilidad: *change failure rate* y *time to restore service (MTTR)*. Optimizar solo throughput (desplegar más rápido y más seguido) sin mirar estabilidad lleva a inundar producción de cambios que fallan: el *change failure rate* y el MTTR se disparan y el rendimiento neto empeora. Las cuatro se leen juntas.

### Bloque 3

**3a.** `working_set` es la memoria que el kernel **no puede recuperar** bajo presión: es exactamente lo que el OOM-killer compara contra el limit. `container_memory_usage_bytes` incluye caché de página recuperable, así que **sobreestima** el uso; si dimensionás el request contra ella, reservás de más y arrastrás el mismo desperdicio que querías eliminar.

**3b.** `updateMode: "Off"` garantiza que el VPA **solo calcula recomendaciones y nunca reinicia ni muta pods**. En multi-tenant conviene así primero porque el modo `"Auto"` desaloja pods para aplicar los nuevos requests, causando reinicios inesperados a otros equipos; primero observás las recomendaciones, validás y recién después automatizás.

**3c.** El cluster no ganó "menos consumo" (el uso real no cambió), ganó **capacidad de scheduling**. El scheduler programa según *requests*, no según uso; al liberar reservas fantasma, el mismo hardware ahora acepta más pods (mejor *bin-packing*) o permite consolidar en menos nodos. La ganancia es densidad, no ahorro de CPU consumido.

**3d.** El `Target` (15m) es la mediana esperada; fijar el request exacto ahí deja el pod sin margen para picos normales y provoca throttling/evicciones. Se deja un colchón (20m) por encima del target. El `Upper Bound` (84m) informa el pico observado y sirve para dimensionar el **limit**, no el request: request cerca del uso típico, limit cerca del pico.

### Bloque 4

**4a.** Porque el right-sizing es por-recurso: un namespace puede estar bien en CPU y desperdiciar RAM (o al revés). Mirar solo `totalCost` esconde cuál de los dos recursos arrastra el gasto; con `cpuCost` y `ramCost` separados sabés si ajustar el request de CPU o el de memoria.

**4b.** Cuando la RAM domina la tarifa (instancias *memory-optimized* o precios donde el GiB pesa más que el core) y tu RAM está bien aprovechada, la eficiencia *ponderada por costo* sale alta aunque la CPU esté ociosa. Ahí atacás primero la **CPU** sobre-aprovisionada, porque es donde hay slack barato de recuperar sin mover la aguja del costo.

**4c.** Porque el costo total del cluster crece con el negocio y no dice nada sobre eficiencia: un cluster caro puede ser eficientísimo si sirve enorme volumen. El **costo por 1000 requests** normaliza por trabajo útil entregado, así que baja cuando mejorás densidad/right-sizing y sube cuando desperdiciás — es una métrica de *eficiencia*, no de tamaño.

### Bloque 5

**5a.** El error budget es el complemento del SLO (SLO 99.9 % → budget 0.1 %). Mientras queda budget, el riesgo de desplegar está "pagado" y los releases siguen. Cuando se agota, la política dispara un *freeze*: se frena la deployment frequency y el equipo invierte en estabilidad hasta recuperar budget. Es una feature porque convierte la tensión velocidad-vs-estabilidad en una regla objetiva y automática en lugar de una discusión política.

**5b.** El promedio esconde la **cola de la distribución**: unos pocos requests lentísimos quedan diluidos por la masa de rápidos, así que `avg` puede verse sano mientras el p99 es horrible. Como cada usuario experimenta *su* request, no el promedio, el p99 refleja la peor experiencia del 1 % — que suele ser la que genera abandono y tickets.

**5c.** La *saturation* pregunta "¿cuán cerca del techo duro estás?", y el techo duro es el `limit` (donde llega el throttling de CPU o el OOM-kill). Por eso se mide contra `limits`. La *eficiencia de asignación* del Ejercicio 3 pregunta "¿cuánto del recurso que reservé para scheduling estoy usando?", y ese recurso reservado es el `request`. Dos preguntas distintas, dos denominadores distintos.

**5d.** Con una sola ventana tenés que elegir entre alertar rápido (ventana corta → muchos falsos positivos por picos transitorios) o alertar confiable (ventana larga → te enterás tarde). Las **múltiples ventanas** combinan una corta y una larga: solo se dispara el *page* si ambas confirman la quema, lo que da baja latencia de detección y baja tasa de falsos positivos a la vez. Una burn rate de 1.5 sostenida la captura la ventana larga; el spike de 14.4, la corta.

### Bloque 6

**6a.** `capacity` es el hardware total del nodo; `allocatable` es lo que queda **después de restar** las reservas del sistema (`kube-reserved`, `system-reserved`, `eviction-threshold`). El scheduler solo programa contra `allocatable`, así que medir bin-packing contra `capacity` sobreestima el espacio disponible y da una falsa sensación de holgura.

**6b.** El scheduler ubica pods comparando la suma de **requests** de los pods ya asignados contra el `allocatable` del nodo, no el uso real. Si los requests suman 85 % del allocatable, no entra un pod nuevo aunque la CPU física esté al 10 %: el campo `resources.requests` reserva capacidad de scheduling independientemente de si se consume. Requests inflados = nodo "lleno" para el scheduler y vacío en la práctica.

**6c.** (1) **Requests correctos** para que los pods quepan compactos y queden nodos realmente vacíos. (2) **PodDisruptionBudgets** que permitan drenar (un PDB con `minAvailable` igual a las réplicas bloquea toda evicción). (3) La annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "true"` en pods que de otro modo el autoscaler considera no-evictables (los que usan almacenamiento local, los de kube-system sin controller, o pods sueltos sin ReplicaSet). Si alguno no está alineado, un único pod ancla el nodo y la consolidación no ocurre.

</details>