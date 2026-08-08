# Tema 1.3 — Optimizing Multi-Tenancy Resource Usage

**Certificación:** Certified Cloud Native Platform Engineer (CNPE) · **Dominio 1** · **Peso: 5**

> Nota de encuadre: el objetivo de este tema no es *aislar* tenants (eso es gobernanza y seguridad, tema aparte) sino **exprimir la utilización del hardware compartido sin romper las garantías que cada tenant negoció**. La tensión central del platform engineer es que utilización alta y aislamiento fuerte tiran en direcciones opuestas, y la plataforma vive en el punto medio que el negocio pueda tolerar.

---

## 1. Motivación y problema arquitectónico de producción

### 1.1 La economía del cluster compartido

Un cluster dedicado por equipo es trivial de razonar y catastrófico de pagar. En un cluster de 100 nodos `m6i.8xlarge` (32 vCPU / 128 GiB c/u = 3200 vCPU / 12.8 TiB), la diferencia entre operar al 35 % de utilización (típico de multi-tenancy ingenua) y al 65 % (multi-tenancy optimizada) es **la mitad de la flota**. A precio on-demand de AWS (~USD 1.54/h por `m6i.8xlarge`), esos 50 nodos que sobran son **≈ USD 675.000/año** quemados en capacidad reservada-pero-ociosa.

El platform engineer no compra utilización con un botón. La compra desactivando, una por una, las causas de que la capacidad quede *stranded* (varada):

| Causa de capacidad varada | Mecánica | Síntoma observable |
|---|---|---|
| **Slack de requests** | El tenant pide `requests: 2000m` "por las dudas" y usa 300m. El scheduler reserva 2000m; nadie más puede usar los 1700m. | `kubectl top` muestra nodos al 20 % de CPU real, pero el scheduler dice "insufficient cpu". |
| **Fragmentación / bin-packing** | Quedan 500m libres en 40 nodos (20 vCPU en total) pero ningún pod de 1000m entra en ningún nodo individual. | Pods `Pending` con capacidad agregada de sobra. |
| **Quota sobre-asignada e infrautilizada** | El `ResourceQuota` del tenant reserva 500 vCPU; usa 120. Los 380 restantes están "comprometidos" contablemente aunque no scheduleados. | Quotas al 24 % `Used/Hard`. |
| **QoS conservador global** | Todos corren `Guaranteed` (requests == limits): cero overcommit, cero burst compartido. | Nodos con `Allocatable` agotado y CPU real al 30 %. |
| **Noisy neighbor mal contenido** | Un tenant satura CPU/IO/PIDs de un nodo y degrada a los vecinos, forzando a subir requests defensivamente en todos. | Throttling generalizado; latencias p99 correlacionadas entre tenants distintos. |

### 1.2 El problema del *noisy neighbor* y por qué requests no alcanzan

`requests` protege el **scheduling** (garantiza que hay capacidad reservada) pero no el **runtime**. En el kernel, el reparto real de CPU lo hace el **CFS (Completely Fair Scheduler)** de Linux vía `cpu.shares` (derivado del request) y `cpu.cfs_quota_us` (derivado del `limit`). Un pod sin `limit` de CPU puede consumir todo el tiempo de CPU ocioso del nodo; cuando un vecino Guaranteed despierta, el CFS le da su parte proporcional, pero el *tail latency* del vecino ya sufrió la latencia de scheduling. En memoria es peor: la memoria no es *compressible* — cuando el nodo entra en `MemoryPressure`, el kubelet **desaloja** pods `BestEffort` y `Burstable` por orden de QoS, y el kernel puede disparar el **OOM killer** con `oom_score_adj` calculado a partir del request. Un noisy neighbor de memoria no degrada: mata.

De ahí la regla operativa: **el overcommit se hace en CPU (compressible), casi nunca en memoria (incompressible).**

### 1.3 El problema de fairness inter-tenant con cargas bursty

`ResourceQuota` es un techo estático. No sabe repartir: si el tenant A reservó 500 vCPU y no los usa, el tenant B —que se quedó sin quota— no puede pedirlos prestados. Para cargas batch/ML esto es letal: los picos son desalineados en el tiempo y el reparto óptimo es dinámico. Éste es exactamente el hueco que llena **Kueue** (proyecto CNCF), con quotas jerárquicas, *cohorts*, *borrowing/lending* y *fair sharing* — lo veremos en §3.4.

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Modelos de tenancy y su impacto en utilización

| Modelo | Aislamiento | Utilización posible | Blast radius | Overhead control-plane | Cuándo elegirlo |
|---|---|---|---|---|---|
| **Namespace soft** (RBAC + Quota + NetworkPolicy) | Bajo (kernel compartido) | **Alta** — un solo scheduler bin-packea todo | Nodo/cluster | Nulo | Tenants internos con confianza mutua |
| **Hierarchical Namespaces (HNC)** | Bajo-medio | Alta | Cluster | Bajo (1 controller) | Jerarquía org (equipo→squad→app) con quota heredada |
| **Capsule / Kamaji tenants** | Medio | Alta | Cluster | Bajo | Self-service de namespaces con guard-rails |
| **vcluster** (virtual cluster) | Medio-alto (API server propio, kernel compartido) | **Alta** — pods reales schedulean en el host | Nodo del host | Medio (1 API server + syncer por tenant) | Tenant necesita CRDs/webhooks propios sin darle el cluster real |
| **Cluster-per-tenant (hard)** | **Alto** | **Baja** — cada cluster con su propio slack | Solo ese cluster | Alto (N control-planes) | Multi-tenancy hostil / compliance / soberanía |

**Trade-off nuclear:** cuanto más fuerte el aislamiento, más *pools de slack independientes* creás, y el slack no se comparte entre pools. Cluster-per-tenant maximiza aislamiento y minimiza utilización — es el modelo *más caro por definición*.

### 2.2 Controles de resource: qué resuelve cada uno

| Control | Alcance | Qué garantiza | Qué NO hace |
|---|---|---|---|
| **`ResourceQuota`** | Namespace (agregado) | Techo de `requests`/`limits`/objetos por tenant | No reparte sobrantes; no aplica a pods individuales |
| **`LimitRange`** | Namespace (por pod/contenedor) | Defaults + min/max + ratio limit/request | No agrega; no evita que la suma exceda (eso es la Quota) |
| **`PriorityClass` + preemption** | Cluster | Orden de desalojo bajo presión | No crea capacidad |
| **QoS class** (derivada) | Pod | Orden de eviction y `oom_score_adj` | No se setea directo; emerge de requests/limits |
| **Kueue (`ClusterQueue`)** | Cohort (multi-namespace) | Admisión con quota nominal + borrowing + fairness | No para pods long-running de servicio (es para Jobs/workloads gestionados) |
| **VPA** | Pod (recomendación/mutación) | Right-sizing de requests | Choca con HPA sobre la misma métrica |

### 2.3 Clases de QoS y su efecto en optimización

| QoS | Condición | `oom_score_adj` | Orden de eviction | Overcommit habilitado |
|---|---|---|---|---|
| **Guaranteed** | `requests == limits` en CPU **y** memoria, todos los contenedores | −997 | Último | No (reserva = uso máximo) |
| **Burstable** | Al menos un request definido, pero no Guaranteed | 2…999 (según request) | Segundo | **Sí** — el vehículo de la utilización alta |
| **BestEffort** | Sin requests ni limits | 1000 | Primero (víctima) | Sí (pero sin garantía) |

**Regla de diseño:** cargas latency-sensitive → `Guaranteed`. Cargas batch/tolerantes → `Burstable` con `requests` honestos (percentil real de uso) y `limits` generosos en CPU. `BestEffort` solo para trabajo verdaderamente descartable.

### 2.4 Autoscaling: los cuatro ejes, no compiten

| Herramienta | Escala | Señal | Latencia | Riesgo en multi-tenant |
|---|---|---|---|---|
| **HPA** | Réplicas (horizontal) | CPU/mem/custom | Segundos–minutos | Amplifica requests si están inflados |
| **VPA** | Requests del pod (vertical) | Uso histórico | Minutos (recrea pod) | Conflicto con HPA en misma métrica; disrupción por recreate |
| **Cluster Autoscaler** | Nodos (por node group) | Pods `Pending` | 1–10 min | Lento reaccionando a fragmentación |
| **Karpenter** | Nodos (just-in-time, sin node groups) | Pods `Pending` + bin-packing | 30–60 s | Consolidación puede desalojar pods sin PDB |
| **In-place Pod Resize** (`resize` subresource, GA-track) | Requests/limits sin recrear | Manual/operator | Inmediato (sin restart, según runtime) | Requiere `InPlacePodVerticalScaling` |

Combinación canónica de plataforma optimizada: **HPA** (réplicas) + **VPA en modo `Off`/recommender** (right-sizing offline) + **Karpenter** (nodos + consolidación) + **Descheduler** (rebalanceo). VPA en modo `Auto` y HPA sobre CPU **no** deben coexistir sobre el mismo Deployment.

---

## 3. Manifiestos completos (producción, sin recortar)

### 3.1 `ResourceQuota` con scopes por prioridad + conteo de objetos

Separar quota por `PriorityClass` evita que trabajo batch de baja prioridad consuma la reserva destinada a servicios críticos.

```yaml
# quota-tenant-payments.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq-compute-critical
  namespace: tenant-payments
spec:
  hard:
    requests.cpu: "200"
    requests.memory: 400Gi
    limits.cpu: "400"
    limits.memory: 800Gi
    requests.nvidia.com/gpu: "8"
    requests.ephemeral-storage: 200Gi
  scopeSelector:
    matchExpressions:
      - scopeName: PriorityClass
        operator: In
        values: ["platform-critical"]
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq-compute-batch
  namespace: tenant-payments
spec:
  hard:
    requests.cpu: "100"
    requests.memory: 200Gi
    limits.cpu: "300"       # overcommit 3x en CPU para batch
    limits.memory: 200Gi    # sin overcommit de memoria
  scopeSelector:
    matchExpressions:
      - scopeName: PriorityClass
        operator: In
        values: ["batch-besteffort"]
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: rq-objects
  namespace: tenant-payments
spec:
  hard:
    pods: "500"
    services: "50"
    services.loadbalancers: "5"     # LBs cuestan dinero real; capalos
    persistentvolumeclaims: "100"
    count/deployments.apps: "80"
    count/jobs.batch: "200"
    secrets: "150"
    configmaps: "150"
```

### 3.2 `LimitRange`: defaults sensatos + ratio para frenar el slack

Sin un `LimitRange`, un pod sin `requests` es `BestEffort` (víctima de eviction) y un pod con `limits` enorme y `request` diminuto rompe el bin-packing. El `maxLimitRequestRatio` fuerza requests honestos.

```yaml
# limitrange-tenant-payments.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: lr-defaults
  namespace: tenant-payments
spec:
  limits:
    - type: Container
      default:                # limits por defecto si no se especifican
        cpu: "1"
        memory: 512Mi
        ephemeral-storage: 1Gi
      defaultRequest:         # requests por defecto
        cpu: 100m
        memory: 128Mi
        ephemeral-storage: 256Mi
      min:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "8"
        memory: 16Gi
      maxLimitRequestRatio:   # limit no puede ser >4x el request en CPU...
        cpu: "4"
        memory: "2"           # ...ni >2x en memoria (limita overcommit de mem)
    - type: PersistentVolumeClaim
      min:
        storage: 1Gi
      max:
        storage: 500Gi
    - type: Pod
      max:
        cpu: "16"
        memory: 32Gi
```

### 3.3 `PriorityClass` + preemption

```yaml
# priorityclasses.yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-critical
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "Servicios de plataforma y control-plane de tenants; desalojan batch."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: tenant-service
value: 100000
globalDefault: true
preemptionPolicy: PreemptLowerPriority
description: "Workloads de servicio de tenants (default)."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-besteffort
value: 1000
globalDefault: false
preemptionPolicy: Never      # batch NUNCA desaloja a nadie; solo llena huecos
description: "Batch relleno; corre en capacidad ociosa, jamás preempta."
```

### 3.4 Kueue: fair-sharing real entre tenants con borrowing

Este es el núcleo de "optimizar" multi-tenancy para batch. Un `ClusterQueue` por tenant, todos en un `cohort` compartido: cuando un tenant no usa su quota nominal, otro la **toma prestada**; al volver la demanda, Kueue la **recupera** (preempta el préstamo). `fairSharing` reparte el excedente equitativamente.

```yaml
# kueue-resourceflavors.yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
spec:
  nodeLabels:
    node.kubernetes.io/instance-type: m6i.8xlarge
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-a100
spec:
  nodeLabels:
    nvidia.com/gpu.product: A100-SXM4-40GB
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
---
# ClusterQueue del tenant A — nominalQuota es lo "propio"; puede pedir prestado
# al cohort hasta borrowingLimit.
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cq-tenant-a
spec:
  namespaceSelector: {}        # todos los LocalQueue que lo referencien
  cohort: shared-batch-pool    # el pool donde se presta/pide
  preemption:
    reclaimWithinCohort: Any   # recupera lo prestado cuando A vuelve a necesitarlo
    borrowWithinCohort:
      policy: LowerPriority
    withinClusterQueue: LowerPriority
  fairSharing:
    weight: 1                  # peso relativo en el reparto del excedente
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: default-flavor
          resources:
            - name: cpu
              nominalQuota: "200"
              borrowingLimit: "200"   # puede llegar a 400 tomando del cohort
            - name: memory
              nominalQuota: 400Gi
              borrowingLimit: 400Gi
        - name: gpu-a100
          resources:
            - name: nvidia.com/gpu
              nominalQuota: "4"
              borrowingLimit: "4"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cq-tenant-b
spec:
  namespaceSelector: {}
  cohort: shared-batch-pool
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  fairSharing:
    weight: 1
  resourceGroups:
    - coveredResources: ["cpu", "memory"]
      flavors:
        - name: default-flavor
          resources:
            - name: cpu
              nominalQuota: "200"
              borrowingLimit: "200"
            - name: memory
              nominalQuota: 400Gi
              borrowingLimit: 400Gi
---
# LocalQueue: el punto de entrada namespaced que los Jobs referencian
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: lq-batch
  namespace: tenant-a
spec:
  clusterQueue: cq-tenant-a
---
# Un Job suspendido que Kueue admite cuando hay quota (nota: suspend: true)
apiVersion: batch/v1
kind: Job
metadata:
  name: etl-nightly-2026-08-07
  namespace: tenant-a
  labels:
    kueue.x-k8s.io/queue-name: lq-batch     # <- lo enruta a Kueue
spec:
  parallelism: 20
  completions: 20
  suspend: true                              # <- Kueue lo desuspende al admitir
  template:
    spec:
      priorityClassName: batch-besteffort
      restartPolicy: Never
      containers:
        - name: etl
          image: registry.internal/etl:1.9.3
          resources:
            requests:
              cpu: "4"
              memory: 8Gi
            limits:
              cpu: "8"
              memory: 8Gi
```

### 3.5 VPA en modo recommender (right-sizing sin disrupción)

`updateMode: "Off"` genera recomendaciones sin tocar los pods: la plataforma las expone en dashboards y el tenant ajusta requests con datos, no con miedo.

```yaml
# vpa-api-payments.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: vpa-api
  namespace: tenant-payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  updatePolicy:
    updateMode: "Off"          # solo recomienda; no muta (seguro con HPA)
  resourcePolicy:
    containerPolicies:
      - containerName: api
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: "4"
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
        controlledValues: RequestsAndLimits
```

### 3.6 Descheduler: recuperar capacidad varada por fragmentación

El scheduler es *point-in-time*: nunca reordena. Con el tiempo, los nodos quedan desbalanceados. El descheduler (como `CronJob`) desaloja pods de nodos sobrecargados y sub-utilizados para que el scheduler los recoloque mejor.

```yaml
# descheduler-policy.yaml
apiVersion: descheduler/v1alpha2
kind: DeschedulerPolicy
metadata:
  name: cluster-rebalance
profiles:
  - name: rebalance
    pluginConfig:
      - name: DefaultEvictor
        args:
          evictSystemCriticalPods: false
          ignorePvcPods: true
          nodeFit: true                  # solo desaloja si el pod cabe en otro nodo
      - name: LowNodeUtilization
        args:
          thresholds:                    # nodos por debajo => "sub-utilizados"
            cpu: 25
            memory: 25
            pods: 25
          targetThresholds:              # nodos por encima => "sobre-utilizados"
            cpu: 70
            memory: 70
            pods: 70
      - name: RemoveDuplicates
      - name: RemovePodsViolatingInterPodAntiAffinity
    plugins:
      balance:
        enabled: [LowNodeUtilization, RemoveDuplicates]
      deschedule:
        enabled: [RemovePodsViolatingInterPodAntiAffinity]
```

### 3.7 Aislamiento por nodo para el tenant hostil (taint + toleration + affinity)

Cuando un tenant no puede compartir kernel (compliance), se le dedica un node pool con taint; el resto del cluster nunca schedulea ahí, y sus pods toleran el taint.

```yaml
# Node pool dedicado (etiquetado + taint aplicado por el node group / Karpenter)
#   kubectl taint nodes -l pool=payments dedicated=payments:NoSchedule
#   kubectl label nodes -l pool=payments tenant=payments
---
# Deployment del tenant que tolera el taint y se ancla al pool
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: tenant-payments
spec:
  replicas: 6
  selector:
    matchLabels: { app: ledger }
  template:
    metadata:
      labels: { app: ledger }
    spec:
      priorityClassName: platform-critical
      tolerations:
        - key: dedicated
          operator: Equal
          value: payments
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: tenant
                    operator: In
                    values: ["payments"]
        podAntiAffinity:      # esparce réplicas entre nodos (resiliencia)
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: { app: ledger }
      containers:
        - name: ledger
          image: registry.internal/ledger:4.2.0
          resources:
            requests: { cpu: "2", memory: 4Gi }
            limits:   { cpu: "2", memory: 4Gi }   # Guaranteed
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Estado de una quota y su consumo

```console
$ kubectl describe resourcequota rq-compute-critical -n tenant-payments
Name:            rq-compute-critical
Namespace:       tenant-payments
Resource         Used   Hard
--------         ----   ----
limits.cpu       220    400
limits.memory    440Gi  800Gi
requests.cpu     168    200
requests.memory  372Gi  400Gi
```

`requests.cpu 168/200` (84 %) es sano. Si estuviera en `40/200`, es slack: la quota está sobre-asignada y hay que recortarla o moverla a otro tenant.

```console
$ kubectl get resourcequota -n tenant-payments -o custom-columns=\
NAME:.metadata.name,\
CPU_REQ_USED:.status.used.requests\\.cpu,\
CPU_REQ_HARD:.status.hard.requests\\.cpu
NAME                  CPU_REQ_USED   CPU_REQ_HARD
rq-compute-batch      64             100
rq-compute-critical   168            200
rq-objects            <none>         <none>
```

### 4.2 Utilización real vs reservada — donde vive el slack

```console
$ kubectl describe node ip-10-0-3-14.ec2.internal | sed -n '/Allocated resources/,/Events/p'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests       Limits
  --------           --------       ------
  cpu                27400m (85%)   58 (181%)
  memory             104Gi (81%)    116Gi (90%)
  ephemeral-storage  40Gi           0 (0%)
  nvidia.com/gpu     0              0
```

Reservado (`Requests`) 85 %, pero mirá el uso real:

```console
$ kubectl top node ip-10-0-3-14.ec2.internal
NAME                        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-3-14.ec2.internal   9840m        30%    71Gi            55%
```

**Diagnóstico:** 85 % reservado, 30 % usado → **55 puntos de slack de CPU**. Los `Limits` a 181 % confirman que hay overcommit configurado (bien), pero los `requests` están inflados: aquí es donde el recommender de VPA paga su costo.

### 4.3 QoS y throttling por pod

```console
$ kubectl get pod api-6f8c9d-abcde -n tenant-payments \
    -o jsonpath='{.status.qosClass}{"\n"}'
Burstable

$ kubectl top pod -n tenant-payments --sort-by=cpu | head -4
NAME                 CPU(cores)   MEMORY(bytes)
etl-nightly-xk2p9    7980m        7100Mi
api-6f8c9d-abcde     1850m        980Mi
api-6f8c9d-fghij     1790m        910Mi
```

Verificar throttling del kernel (CFS) desde dentro del contenedor:

```console
$ kubectl exec -n tenant-payments api-6f8c9d-abcde -- \
    cat /sys/fs/cgroup/cpu.stat
usage_usec 4821330000
user_usec 3110210000
system_usec 1711120000
nr_periods 1287344
nr_throttled 412208
throttled_usec 88213440000
```

`nr_throttled / nr_periods = 412208 / 1287344 ≈ 32 %`: casi un tercio de los períodos CFS el contenedor fue throttled contra su `limit`. La app tiene el CPU que pidió pero el `limit` la ahoga → subir el `limit` de CPU (barato: CPU es compressible) o quitarlo.

### 4.4 Kueue: admisión, préstamos y fairness

```console
$ kubectl get clusterqueue
NAME          COHORT              PENDING   ADMITTED   RESERVING
cq-tenant-a   shared-batch-pool   3         18         320
cq-tenant-b   shared-batch-pool   0         5          80

$ kubectl get clusterqueue cq-tenant-a -o jsonpath=\
'{range .status.flavorsUsage[*].resources[*]}{.name}={.total}{"\n"}{end}'
cpu=320
memory=640Gi
nvidia.com/gpu=2
```

`RESERVING 320` con `nominalQuota 200` → el tenant A está **tomando prestados 120 vCPU** del cohort (de la quota ociosa de B). Cuando B vuelva a encolar trabajo, `reclaimWithinCohort: Any` preempta esos préstamos.

```console
$ kubectl get workloads -n tenant-a
NAME                       QUEUE      RESERVED   ADMITTED   AGE
job-etl-nightly-a1b2c3     lq-batch   True       True       12m
job-etl-nightly-d4e5f6     lq-batch              False      3m

$ kubectl describe workload job-etl-nightly-d4e5f6 -n tenant-a | grep -A4 Conditions:
Conditions:
  Type          Status   Reason              Message
  QuotaReserved False    Pending             couldn't assign flavors: insufficient
                                             quota for cpu in flavor default-flavor,
                                             8 more needed, borrowing limit reached
```

El mensaje `borrowing limit reached` es el diagnóstico exacto: A ya pidió prestado todo lo que `borrowingLimit` permite; el job espera a que se libere quota del cohort.

### 4.5 Recomendaciones de VPA (right-sizing)

```console
$ kubectl describe vpa vpa-api -n tenant-payments | sed -n '/Recommendation/,/Events/p'
  Recommendation:
    Container Recommendations:
      Container Name:  api
      Lower Bound:
        Cpu:     240m
        Memory:  420Mi
      Target:
        Cpu:     380m
        Memory:  610Mi
      Uncapped Target:
        Cpu:     380m
        Memory:  610Mi
      Upper Bound:
        Cpu:     820m
        Memory:  1180Mi
```

Si el Deployment corre con `requests.cpu: 2000m` y el `Target` es `380m`, hay **1620m de slack por réplica**. Con 40 réplicas son **64.8 vCPU recuperables** solo en este Deployment.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Runbook: "pods `Pending` pero hay capacidad de sobra"

```console
$ kubectl get events -n tenant-payments --field-selector reason=FailedScheduling \
    --sort-by=.lastTimestamp | tail -2
2m  Warning  FailedScheduling  pod/worker-9  0/100 nodes are available: 100 Insufficient cpu.
```

1. **¿Es la quota?**
   ```console
   $ kubectl get events -n tenant-payments --field-selector reason=FailedCreate | tail -1
   1m  Warning  FailedCreate  replicaset/worker  Error creating: pods "worker-9" is forbidden:
       exceeded quota: rq-compute-critical, requested: requests.cpu=4, used: requests.cpu=198,
       limited: requests.cpu=200
   ```
   → Quota agotada. Recortá slack de otros deployments (VPA) o subí/reasigná quota.

2. **¿Es fragmentación?** Capacidad agregada libre pero ningún nodo individual con hueco:
   ```console
   $ kubectl get nodes -o json | jq -r '.items[] |
       "\(.metadata.name) alloc_cpu=\(.status.allocatable.cpu)"' | head -3
   ```
   Sumá `allocatable − requests` por nodo; si el máximo hueco individual < request del pod → fragmentación. Solución: **descheduler** (§3.6) o consolidación de **Karpenter**.

3. **¿Es slack de requests?** Confirmá con §4.2: si `top node` << `Allocated requests`, el problema es requests inflados, no capacidad. Solución: VPA recommender + apretar `maxLimitRequestRatio`.

### 5.2 Runbook: `OOMKilled` recurrente

```console
$ kubectl get pod worker-3 -n tenant-a -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
OOMKilled

$ kubectl get pod worker-3 -n tenant-a -o jsonpath=\
'{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
137
```

- `exitCode 137` = 128 + SIGKILL(9) → OOM killer.
- **Nunca** overcommitees memoria para arreglarlo: subí `requests.memory` **y** `limits.memory` a un valor por encima del working set real (miralo con `kubectl top pod`).
- Si el nodo entero entra en presión (no solo el contenedor), revisá evictions:
  ```console
  $ kubectl get events -A --field-selector reason=Evicted | tail -3
  tenant-a  worker-7  The node was low on resource: memory. Threshold quantity: 100Mi
  ```
  Esto indica overcommit de memoria a nivel de nodo → recalcular requests o bajar el ratio.

### 5.3 Checklist de optimización (auditoría periódica)

| Verificación | Comando | Umbral sano |
|---|---|---|
| Slack de CPU por nodo | `kubectl top node` vs `Allocated requests` | Δ < 20 pts |
| Quotas infrautilizadas | `describe resourcequota` (`Used/Hard`) | Used > 60 % |
| Throttling CFS | `cat /sys/fs/cgroup/cpu.stat` (`nr_throttled/nr_periods`) | < 5 % |
| Utilización real del cluster | `kubectl top nodes` promedio | 55–70 % |
| Préstamos de Kueue activos | `get clusterqueue` (`RESERVING > nominal`) | Sano si hay reclaim |
| Pods `BestEffort` en prod | `kubectl get pods -A -o json \| jq '...qosClass'` | 0 en tenants críticos |
| Recomendaciones VPA vs actual | `describe vpa` `Target` vs `requests` | Δ < 25 % |

### 5.4 Fórmula operativa de utilización objetivo

```
utilización_objetivo = 1 − (headroom_burst + headroom_falla_nodo + headroom_scheduling)

  headroom_burst        ≈ 0.10–0.15  (picos entre scrapes del autoscaler)
  headroom_falla_nodo   ≈ 1/N        (N = nodos; capacidad para perder 1 y reprogramar)
  headroom_scheduling   ≈ 0.05–0.10  (fragmentación residual)
```

Para 100 nodos: `1 − (0.12 + 0.01 + 0.07) ≈ 0.80` → apuntar a ~70 % deja margen sano. Superar el 80 % sostenido convierte cualquier pico o falla de nodo en cascada de evictions.

---

## 6. Referencias

- **CNPE Curriculum (fuente del examen):** https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- **Resource Quotas:** https://kubernetes.io/docs/concepts/policy/resource-quotas/
- **Limit Ranges:** https://kubernetes.io/docs/concepts/policy/limit-range/
- **Managing Resources for Containers (requests/limits):** https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- **Pod Quality of Service Classes:** https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- **Pod Priority and Preemption:** https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- **Node-pressure Eviction:** https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- **Resize CPU and Memory Resources assigned to Containers (in-place):** https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/
- **Kueue (CNCF) — Concepts, Cluster Queue, Fair Sharing:** https://kueue.sigs.k8s.io/docs/concepts/
- **Kueue — Preemption & Borrowing:** https://kueue.sigs.k8s.io/docs/concepts/preemption/
- **Vertical Pod Autoscaler:** https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- **Horizontal Pod Autoscaler:** https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- **Kubernetes Descheduler (SIG):** https://github.com/kubernetes-sigs/descheduler
- **Karpenter — Consolidation & Provisioning:** https://karpenter.sh/docs/concepts/
- **Hierarchical Namespace Controller (HNC):** https://github.com/kubernetes-sigs/hierarchical-namespaces
- **CNCF Multi-Tenancy Benchmarks / SIG Multitenancy:** https://github.com/kubernetes-sigs/multi-tenancy
- **vcluster (multi-tenancy virtual):** https://www.vcluster.com/docs/
- **CFS Bandwidth Control (kernel):** https://www.kernel.org/doc/html/latest/scheduler/sched-bwc.html