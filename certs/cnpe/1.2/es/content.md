# 1.2 Uso de soluciones de gestión de costos para right-sizing y scaling

> **Peso en el examen: 5** — Dominio 1 (Platform Engineering / Financial Operations). Nivel: Platform Architect / SRE Senior.

---

## 1. El problema arquitectónico: el costo como propiedad de la plataforma

En una plataforma cloud native el costo no es una línea de la factura al final del mes: es una **propiedad emergente de miles de decisiones de scheduling** que ocurren cada segundo. El platform engineer no controla directamente el gasto; controla los *inputs* que el scheduler y los autoscalers usan para decidir cuánto cómputo aprovisionar. Si esos inputs están mal calibrados, la plataforma paga por capacidad que nadie consume.

El fenómeno central es el **slack** (holgura): la diferencia entre lo que un workload **reserva** (`requests`) y lo que **realmente consume**.

```
slack_cpu = Σ(requests.cpu) − Σ(usage.cpu real p95)
```

El `kube-scheduler` reserva capacidad basándose en `requests`, no en uso real. Un Deployment que pide `2` CPU pero usa `200m` mantiene 1.8 CPU **inutilizables por el resto del cluster** pero **facturables**. A escala de flota esto produce dos patologías simultáneas y contradictorias:

| Patología | Síntoma técnico | Consecuencia económica |
|---|---|---|
| **Over-provisioning** | `requests ≫ usage`, nodos al 30% de allocation real | Se pagan nodos vacíos; bin packing ineficiente |
| **Under-provisioning** | `limits` bajos → OOMKill / CPU throttling | SLO violado; escalado reactivo caro (nodos on-demand de emergencia) |
| **Idle cost** | Nodos aprovisionados sin pods (scale-up sin scale-down) | Capacidad huérfana tras picos |
| **Fragmentación** | Pods pequeños dispersos, ningún nodo drenable | Cluster Autoscaler no puede consolidar |

El objetivo del tema es cerrar el lazo de control **observar costo → recomendar tamaño → escalar dinámicamente**, apoyándose en el ciclo FinOps de la **FinOps Foundation** (*Inform → Optimize → Operate*). El platform engineer es dueño de la mecánica; el equipo de aplicación es dueño de la decisión de trade-off entre costo y resiliencia.

---

## 2. Anatomía del costo en Kubernetes: el cost model

Ninguna herramienta "conoce" el precio de un pod. Todas construyen un **cost model** que reparte el precio conocido de un nodo entre los workloads que corren en él. La fórmula canónica (la que implementa OpenCost) es una asignación proporcional por recurso:

```
costo_pod = Σ_recurso ( max(request_r, usage_r) / capacidad_nodo_r ) × precio_nodo_r × horas
```

Dos decisiones de diseño gobiernan todo:

1. **Base de asignación**: `requests` (lo reservado, "lo que pagás por acaparar") vs `usage` (lo consumido). OpenCost usa `max(request, usage)` para no premiar a quien no pide pero satura el nodo.
2. **Idle allocation**: el costo del nodo que **ningún** pod reservó. Se puede dejar como línea `__idle__` (visibilidad honesta) o redistribuir proporcionalmente (showback "limpio" pero que esconde el desperdicio).

| Dimensión de costo | Fuente del dato | Notas de producción |
|---|---|---|
| CPU / RAM | Precio de la instancia (billing API o pricing sheet) | Spot vs on-demand cambia 60–90% |
| GPU | Precio del acelerador, no fraccionable salvo MIG/time-slicing | Rara vez compartible; asignación 1:1 |
| Almacenamiento | Precio del PV/EBS por GiB-mes | PVs `Released` sin borrar = costo fantasma |
| Red | Egress inter-AZ / inter-región | El punto ciego más caro y menos instrumentado |
| Load Balancers | Costo fijo por LB + LCU/hora | Un `Service type=LoadBalancer` por microservicio escala mal |

**Regla de oro:** cualquier plan de right-sizing que ignore red y almacenamiento optimiza la mitad barata del problema.

---

## 3. Observabilidad del costo: OpenCost / Kubecost

**OpenCost** es el proyecto CNCF (Sandbox) que estandariza el cost model de Kubernetes; **Kubecost** es el producto comercial de Stackwatch construido sobre él. OpenCost persiste series en Prometheus y expone una API de *allocation*.

### Arquitectura

```
         ┌──────────────┐   scrape    ┌──────────────┐
         │ kube-state-   │◀───────────│              │
         │ metrics       │            │  Prometheus  │
         ├──────────────┤   scrape    │              │
         │ node-exporter │◀───────────│              │
         └──────────────┘            └──────┬───────┘
                                            │ PromQL
                                     ┌──────▼───────┐   Cloud Billing API
                                     │  OpenCost    │◀──── (AWS CUR / GCP /
                                     │  (cost model)│      Azure) o pricing CM
                                     └──────┬───────┘
                                            │ /allocation, /assets
                                     ┌──────▼───────┐
                                     │  UI / API /  │
                                     │  Grafana     │
                                     └──────────────┘
```

### Instalación mínima (con Prometheus existente)

```yaml
# opencost.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: opencost
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opencost
  namespace: opencost
  labels:
    app: opencost
spec:
  replicas: 1
  selector:
    matchLabels:
      app: opencost
  template:
    metadata:
      labels:
        app: opencost
    spec:
      serviceAccountName: opencost
      containers:
        - name: opencost
          image: ghcr.io/opencost/opencost:1.113.0
          ports:
            - containerPort: 9003   # API
            - containerPort: 9090   # UI
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          env:
            - name: PROMETHEUS_SERVER_ENDPOINT
              value: "http://prometheus-server.monitoring.svc:80"
            - name: CLOUD_PROVIDER_API_KEY
              value: ""                 # AWS usa IAM del pod (IRSA)
            - name: CLUSTER_ID
              value: "prod-eu-west-1"
          # Pricing on-prem (sin cloud billing): montar configmap con precios/hora
          volumeMounts:
            - name: custom-pricing
              mountPath: /models
      volumes:
        - name: custom-pricing
          configMap:
            name: opencost-custom-pricing
            optional: true
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-custom-pricing
  namespace: opencost
data:
  # Usado sólo si no hay integración de billing (bare-metal / on-prem)
  default.json: |
    {
      "provider": "custom",
      "description": "On-prem blended pricing",
      "CPU": "0.031611",
      "RAM": "0.004237",
      "GPU": "0.95",
      "storage": "0.00005",
      "zoneNetworkEgress": "0.01",
      "regionNetworkEgress": "0.01",
      "internetNetworkEgress": "0.12"
    }
```

### Consulta de allocation por namespace

```console
$ kubectl port-forward -n opencost deployment/opencost 9003:9003 &
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace&accumulate=true" \
    | jq '.data[0] | to_entries | map({ns:.key, cpuCost:.value.cpuCost, ramCost:.value.ramCost, efficiency:.value.totalEfficiency}) | sort_by(-.cpuCost)'
[
  {
    "ns": "checkout",
    "cpuCost": 412.83,
    "ramCost": 188.51,
    "efficiency": 0.19          # ← 19% de lo reservado se usa: candidato #1 a right-sizing
  },
  {
    "ns": "search",
    "cpuCost": 233.10,
    "ramCost": 402.77,
    "efficiency": 0.71
  },
  {
    "ns": "__idle__",
    "cpuCost": 190.44,          # ← capacidad pagada sin reservar por nadie
    "ramCost": 96.22,
    "efficiency": 0
  }
]
```

El campo `efficiency` (uso ÷ reserva) es la señal accionable: `checkout` paga $600/semana con **19% de eficiencia** → aquí empieza el right-sizing.

### Comparativa de herramientas de visibilidad

| Herramienta | Modelo | Multi-cloud | Scale-to-zero de datos | Licencia | Cuándo elegirla |
|---|---|---|---|---|---|
| **OpenCost** | Prometheus + cost model | Sí (AWS/GCP/Azure/on-prem) | No (retención Prom) | Apache-2.0 | Base FinOps CNCF neutral |
| **Kubecost** | OpenCost + ETL + alertas | Sí | Sí (durable storage) | Comercial (free tier limitado) | Chargeback formal, savings recs |
| **AWS Cost Explorer / CUR** | Billing nativo | No | N/A | Incluido | Fuente de verdad de la factura, no del pod |
| **Cloud custom (GCP/Azure cost)** | Billing nativo | No | N/A | Incluido | Correlación factura↔cluster |

> La factura del proveedor es la **verdad legal**; OpenCost es la **verdad operativa por workload**. Se reconcilian, no se sustituyen. La spec **FOCUS** (FinOps Open Cost & Usage Specification) busca unificar el formato del billing entre nubes.

---

## 4. Right-sizing vertical: VPA y Goldilocks

Right-sizing = ajustar `requests`/`limits` al consumo real. La herramienta canónica es el **Vertical Pod Autoscaler (VPA)**.

### 4.1 QoS: por qué `requests` y `limits` deciden el destino del pod

La clase de QoS —derivada de cómo se setean requests/limits— determina el orden de desalojo bajo presión de memoria:

| QoS class | Condición | Comportamiento bajo presión |
|---|---|---|
| **Guaranteed** | `requests == limits` en **todos** los containers (cpu y memoria) | Último en ser desalojado; sin CPU throttling por sobre-suscripción del nodo |
| **Burstable** | Al menos un container con requests o limits, pero no Guaranteed | Desalojo intermedio; puede burst-ear |
| **BestEffort** | Sin requests ni limits | Primero en morir en OOM del nodo |

Trade-off central: **Guaranteed** da predecibilidad (ideal para stateful/latency-sensitive) pero **maximiza el slack** (pagás el pico como base). **Burstable** con `requests` ajustados a p95 y `limits` altos maximiza densidad, a riesgo de throttling en contención.

### 4.2 Arquitectura del VPA

VPA no es un componente único; son tres controllers:

```
┌───────────────┐   history (Prometheus / checkpoints)
│  Recommender  │──▶ calcula target/lowerBound/upperBound (percentiles con decay)
└───────┬───────┘
        │ escribe status.recommendation
┌───────▼───────┐
│    Updater    │──▶ en modo Auto/Recreate: desaloja pods fuera de rango
└───────┬───────┘
        │ (el pod se recrea)
┌───────▼───────────────┐
│ Admission Controller  │──▶ mutating webhook: inyecta los nuevos requests al recrear
└───────────────────────┘
```

El Recommender usa un **modelo de decaimiento exponencial** sobre el histograma de uso (half-life ~24h): el pasado reciente pesa más. `target` ≈ p90 de CPU, con memoria dimensionada para no OOM-ear.

### 4.3 Modos del VPA (`updatePolicy.updateMode`)

| Modo | Qué hace | Uso en producción |
|---|---|---|
| `Off` | Sólo calcula recomendaciones, no toca pods | **Modo seguro**: alimenta Goldilocks/dashboards, decisión manual |
| `Initial` | Aplica requests sólo al **crear** el pod, nunca lo desaloja | Batch/jobs; sin disrupción in-flight |
| `Recreate` | Desaloja y recrea si el pod sale de rango | Legacy; disruptivo |
| `Auto` | Hoy == `Recreate` (in-place resize llega con `InPlacePodVerticalScaling`, KEP-1287, beta) | Requiere PDB; **incompatible con HPA sobre el mismo recurso** |

### 4.4 Manifiesto VPA completo

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-vpa
  namespace: checkout
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  updatePolicy:
    updateMode: "Off"          # empezar SIEMPRE en Off y observar antes de automatizar
    minReplicas: 2             # no desalojar si bajaría de 2 réplicas disponibles
  resourcePolicy:
    containerPolicies:
      - containerName: "checkout-api"
        mode: Auto
        controlledResources: ["cpu", "memory"]
        controlledValues: RequestsAndLimits   # escala limits manteniendo ratio request:limit
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: "2"
          memory: 2Gi
      - containerName: "istio-proxy"           # el sidecar tiene su propia política
        mode: "Off"                            # no dejar que VPA toque el sidecar
```

### 4.5 Leer la recomendación (lo que realmente importa)

```console
$ kubectl get vpa checkout-vpa -n checkout -o jsonpath='{.status.recommendation.containerRecommendations[0]}' | jq
{
  "containerName": "checkout-api",
  "lowerBound": { "cpu": "125m",  "memory": "262144k" },   # mínimo para no degradar
  "target":     { "cpu": "587m",  "memory": "393216k" },   # ← lo que deberías poner en requests
  "uncappedTarget": { "cpu": "587m", "memory": "393216k" },# target si no hubiera maxAllowed
  "upperBound": { "cpu": "1250m", "memory": "1Gi" }         # techo antes de sobre-provisionar
}
```

Interpretación de producción:
- **`target`** → nuevo `requests`. Aquí, de `2` CPU reservados a `587m` real: **~70% de reducción de slack**.
- **`lowerBound`** → si tus requests actuales están por encima, es seguro bajar.
- **`upperBound`** → si tus requests están por debajo, estás en riesgo de throttling/OOM.
- **`uncappedTarget` == `maxAllowed`** → el `maxAllowed` te está limitando; revisar si el workload necesita más.

### 4.6 Goldilocks: right-sizing a escala de flota

**Goldilocks** (Fairwinds) despliega VPAs en modo `Off` automáticamente por namespace y renderiza un dashboard con las recomendaciones "Guaranteed" y "Burstable" lado a lado.

```console
$ helm repo add fairwinds-stable https://charts.fairwinds.com/stable
$ helm install goldilocks fairwinds-stable/goldilocks --namespace goldilocks --create-namespace
$ kubectl label namespace checkout goldilocks.fairwinds.com/enabled=true
namespace/checkout labeled
$ kubectl -n goldilocks port-forward svc/goldilocks-dashboard 8080:80
# El dashboard emite YAML listo para copiar: requests=target, limits=upperBound
```

---

## 5. Scaling horizontal: HPA y KEDA

Right-sizing ajusta el **tamaño** del pod; el scaling horizontal ajusta la **cantidad**. Son ortogonales y complementarios.

### 5.1 Algoritmo del HPA

```
desiredReplicas = ceil[ currentReplicas × ( currentMetricValue / desiredMetricValue ) ]
```

Con una **banda de tolerancia** por defecto de `0.1` (10%): si el ratio cae en `[0.9, 1.1]` **no escala**, para evitar oscilación. El control-plane muestrea cada `--horizontal-pod-autoscaler-sync-period` (15s por defecto).

### 5.2 Manifiesto HPA v2 completo con `behavior`

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-hpa
  namespace: checkout
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 3
  maxReplicas: 50
  metrics:
    - type: Resource                    # métrica de recurso (requiere metrics-server)
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70        # % sobre requests.cpu, NO sobre capacidad del nodo
    - type: Pods                        # métrica custom por pod (requiere Prometheus Adapter)
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0     # subir sin demora ante picos
      selectPolicy: Max
      policies:
        - type: Percent
          value: 100                    # puede duplicar réplicas...
          periodSeconds: 15
        - type: Pods
          value: 4                      # ...o sumar 4 pods, lo que sea mayor
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300   # esperar 5 min de calma antes de bajar (anti-flapping)
      selectPolicy: Max
      policies:
        - type: Percent
          value: 50                     # bajar como mucho 50% cada minuto
          periodSeconds: 60
```

**Nota crítica:** `averageUtilization` es un porcentaje de `requests.cpu`, **no** de la capacidad del nodo. Si `requests.cpu` está mal dimensionado (demasiado bajo por un right-sizing agresivo), el HPA escala demasiado pronto. **Right-sizing y HPA se calibran juntos, no por separado.**

### 5.3 KEDA: event-driven autoscaling y scale-to-zero

El HPA nativo no baja de `minReplicas ≥ 1` y sólo entiende métricas de recurso/custom. **KEDA** (CNCF, graduado) extiende esto: escala **a cero** y reacciona a **fuentes de eventos** (colas, streams, cron, bases). KEDA crea y gestiona un HPA por debajo.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: image-worker
  namespace: media
spec:
  scaleTargetRef:
    name: image-worker            # Deployment objetivo
  minReplicaCount: 0              # ← scale-to-zero: cero costo cuando la cola está vacía
  maxReplicaCount: 40
  pollingInterval: 15            # cada cuántos s consulta el scaler
  cooldownPeriod: 120           # s en 0 antes de dormir el deployment
  idleReplicaCount: 0
  triggers:
    - type: rabbitmq
      metadata:
        protocol: amqp
        queueName: image-resize
        mode: QueueLength
        value: "20"             # 1 réplica por cada 20 mensajes encolados
      authenticationRef:
        name: rabbitmq-trigger-auth
```

### 5.4 Comparativa de autoscalers de workload

| Autoscaler | Dimensión | Señal | Scale-to-zero | Reinicia pods | Conflicto |
|---|---|---|---|---|---|
| **HPA** | Horizontal (réplicas) | CPU/mem, custom, external | No (min 1) | No | Choca con VPA en el mismo recurso |
| **VPA** | Vertical (requests) | Uso histórico | N/A | Sí (modo Auto) | Choca con HPA en CPU/mem |
| **KEDA** | Horizontal + a cero | Eventos (colas, streams, cron) | **Sí** | No | Gestiona su propio HPA |
| **MPA (GKE)** | Ambas a la vez | CPU + custom | No | Sí | Sólo GKE; evita el conflicto HPA/VPA |

---

## 6. Scaling de nodos: Cluster Autoscaler vs Karpenter

Escalar pods no sirve si no hay nodos donde ubicarlos. Dos enfoques dominan.

### 6.1 Cluster Autoscaler (CA)

Opera sobre **node groups** preexistentes (ASG/MIG/node pool). Ve pods `Pending` por falta de recursos → aumenta el `desiredCapacity` del grupo. Baja nodos cuya utilización cae bajo `--scale-down-utilization-threshold` (0.5) durante `--scale-down-unneeded-time` (10m).

**Expanders** (cómo elige qué grupo crecer):

| Expander | Estrategia | Cuándo |
|---|---|---|
| `random` | Aleatorio | Default, no óptimo |
| `most-pods` | El grupo que acomode más pods pending | Bursts grandes |
| `least-waste` | Minimiza CPU/mem ociosa tras el scale-up | Eficiencia de bin packing |
| `price` | Grupo más barato que sirva | Optimización de costo directa |
| `priority` | Orden definido por ConfigMap | Spot primero, on-demand como fallback |

### 6.2 Karpenter: node provisioning sin node groups

**Karpenter** elimina la rigidez de los node groups: dado un pod `Pending`, elige **en el momento** el tipo de instancia óptimo del universo permitido (bin packing directo → instancia justa), la lanza en ~40s, y luego **consolida** agresivamente.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]        # Karpenter prioriza spot si cabe
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]                         # sólo gen ≥ 6 (mejor $/perf)
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h                          # rotar nodos cada 30 días (parches)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized  # consolidar aun con nodos usados
    consolidateAfter: 1m
    budgets:
      - nodes: "10%"                              # nunca romper más del 10% de la flota a la vez
      - nodes: "0"                                # congelar disrupción en horario pico
        schedule: "0 9 * * mon-fri"
        duration: 8h
  limits:
    cpu: "1000"
    memory: 1000Gi                               # techo duro de gasto del pool
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "KarpenterNodeRole-prod"
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "prod"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "prod"
```

### 6.3 Comparativa CA vs Karpenter

| Criterio | Cluster Autoscaler | Karpenter |
|---|---|---|
| Modelo | Node groups fijos (ASG/MIG) | Provisioning just-in-time por pod |
| Selección de instancia | Predefinida por el grupo | Óptima del universo permitido (bin packing) |
| Latencia de scale-up | 1–4 min (ASG) | ~40 s (RunInstances directo) |
| Consolidación | Scale-down por umbral de utilización | Consolidación multi-nodo (reemplaza N por M más baratos) |
| Spot | Vía grupos spot separados | Nativo, con fallback a on-demand y manejo de interrupción (SQS) |
| Diversidad de instancias | Manual (un grupo por familia) | Automática |
| Portabilidad | Multi-cloud maduro | AWS maduro; Azure/GCP emergentes |
| Cuándo | Clusters estables, node groups ya gestionados por IaC | Flotas heterogéneas, spot agresivo, minimizar slack de nodo |

> **Ahorro real de Karpenter** viene de dos lados: elegir la instancia *justa* (no la del grupo más cercano) y **consolidar** — reemplazar 3 nodos al 40% por 1 al 90%, o un on-demand por spot equivalente.

### 6.4 Barreras al scale-down (aplica a CA y Karpenter)

Un nodo **no** puede drenarse si tiene pods que:
- No los cubre un controller (pods "naked", sin ReplicaSet/Job dueño).
- Usan `emptyDir`/local storage y no toleran reinicio.
- Tienen la anotación `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`.
- Están bloqueados por un **PodDisruptionBudget** demasiado estricto (`minAvailable` = réplicas totales).
- Son de `kube-system` sin PDB (kube-dns clásico).

**LimitRange + ResourceQuota** cierran el lazo de gobernanza: obligan a que ningún pod entre sin requests (evita BestEffort que rompe el cost model) y ponen techo de gasto por namespace:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: checkout
spec:
  limits:
    - type: Container
      default:            # limits por defecto
        cpu: 500m
        memory: 512Mi
      defaultRequest:     # requests por defecto (nada entra como BestEffort)
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "2"
        memory: 2Gi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: checkout-quota
  namespace: checkout
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.cpu: "80"
    limits.memory: 160Gi
```

---

## 7. Composición: combinar autoscalers sin que se peleen

El error de producción más caro es apilar autoscalers que se contradicen.

**Conflicto HPA ↔ VPA:** ambos sobre CPU/memoria entran en un lazo destructivo — VPA sube `requests`, lo que baja el % de utilización visto por HPA, que reduce réplicas, lo que sube la carga por pod, lo que hace subir a VPA otra vez. Soluciones válidas:

1. **VPA en `Off` (recomendación) + HPA en CPU.** El humano/GitOps aplica los requests; el HPA escala. Patrón más seguro y auditable.
2. **HPA en métrica custom/externa (RPS, profundidad de cola) + VPA en CPU/memoria.** No comparten dimensión → no chocan.
3. **MPA** en GKE, que coordina ambas internamente.

Lazo de control completo, de arriba hacia abajo:

```
   Evento/carga
        │
        ▼
   [KEDA/HPA]  ── ajusta nº de réplicas ──▶  pods Pending
        │                                          │
   [VPA off→recs] ── ajusta requests/pod           ▼
        │                                   [Karpenter/CA]
        ▼                                   ── aprovisiona/consolida nodos
   [OpenCost] ◀── mide costo por workload y cierra el lazo FinOps
```

Regla de composición segura:

| Capa | Herramienta | Restricción |
|---|---|---|
| Réplicas | HPA / KEDA | Métrica ≠ la del VPA |
| Tamaño de pod | VPA (`Off` en prod crítico) | No sobre el recurso del HPA |
| Nodos | Karpenter / CA | PDBs correctos para permitir consolidación |
| Visibilidad | OpenCost | Cierra el lazo, alimenta las decisiones |

---

## 8. Verificación y diagnóstico de fallas

### 8.1 Checklist de verificación

```console
# 1. metrics-server vivo (sin él HPA y `top` no funcionan)
$ kubectl top nodes
NAME                          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-1-33.ec2.internal     1840m        46%    6120Mi          78%
ip-10-0-2-90.ec2.internal     920m         23%    3050Mi          39%

# 2. HPA está leyendo métricas (no <unknown>)
$ kubectl get hpa -n checkout
NAME           REFERENCE                 TARGETS              MINPODS  MAXPODS  REPLICAS
checkout-hpa   Deployment/checkout-api   61%/70%, 430/500     3        50       7

# 3. VPA está emitiendo recomendación
$ kubectl get vpa -n checkout
NAME           MODE   CPU    MEM       PROVIDED   AGE
checkout-vpa   Off    587m   393216k   True       6d

# 4. Karpenter registra decisiones de provisioning
$ kubectl logs -n kube-system deploy/karpenter -c controller | grep -i "launched\|consolidat" | tail -3
{"level":"INFO","message":"launched nodeclaim","nodeclaim":"default-x8k2p","instance-type":"c6a.xlarge","capacity-type":"spot"}
{"level":"INFO","message":"disrupting via consolidation replace","reason":"underutilized","nodes":3,"replacements":1}
```

### 8.2 Diagnóstico dirigido del HPA

```console
$ kubectl describe hpa checkout-hpa -n checkout
Conditions:
  Type            Status  Reason               Message
  ----            ------  ------               -------
  AbleToScale     True    ReadyForNewScale     recommended size matches current
  ScalingActive   False   FailedGetResourceMetric  unable to get metrics for resource cpu:
                          no metrics returned from resource metrics API
Events:
  Warning  FailedGetResourceMetric  ... missing request for cpu in container checkout-api
```

→ Causa: el container **no declara `requests.cpu`**, así que el HPA no tiene denominador para calcular el %. **Utilization-based HPA exige requests.** Sin ellos, `TARGETS` muestra `<unknown>/70%`.

### 8.3 Tabla de fallas frecuentes

| Síntoma | Causa raíz | Diagnóstico | Remediación |
|---|---|---|---|
| HPA `TARGETS: <unknown>/70%` | Falta `requests.cpu` o metrics-server caído | `kubectl top pods`; `describe hpa` | Setear requests; instalar/reparar metrics-server |
| Réplicas oscilan (flapping) | Sin `stabilizationWindowSeconds` en scaleDown | `kubectl get hpa -w` | `behavior.scaleDown.stabilizationWindowSeconds: 300` |
| VPA no aplica cambios | Modo `Off`, o `minReplicas` bloquea desalojo | `get vpa -o yaml` | Cambiar a `Auto` con PDB, o aplicar recs por GitOps |
| Nodos vacíos no bajan | Pod con `safe-to-evict:false` o PDB estricto | `kubectl describe node`; buscar la anotación | Ajustar PDB; quitar anotación; mover local storage |
| OpenCost reporta `$0` | Sin integración de billing ni pricing CM | `curl /allocation` → costos nulos | Configurar CUR/IRSA o montar `custom-pricing` CM |
| OOMKilled tras right-sizing | `limits.memory` = target sin margen | `kubectl get pod -o jsonpath` `reason=OOMKilled` | `limits` = `upperBound` del VPA, no `target` |
| CPU throttling con VPA aplicado | `limits.cpu` recortado por debajo del pico | `container_cpu_cfs_throttled_periods_total` en Prom | Subir `limits.cpu`; QoS Guaranteed si es latency-sensitive |
| Karpenter no lanza nodos | Requirements no matchean ninguna instancia, o límite del NodePool alcanzado | logs del controller; `kubectl get nodeclaim` | Ampliar `requirements`; subir `spec.limits` |
| Spot interrumpe sin drenar | Falta interruption queue (SQS) en la config del controller | logs sin evento de interrupción | Configurar `settings.interruptionQueue` |

### 8.4 Confirmar el ahorro (cierre del lazo)

```console
# Antes: requests hinchados
$ kubectl get deploy checkout-api -n checkout \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'
{"cpu":"2","memory":"2Gi"}

# Aplicar target del VPA (587m / 384Mi) por GitOps y comparar allocation 7 días después
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace" \
    | jq '.data[0].checkout.cpuCost'
124.61          # antes: 412.83 → ~70% menos, coherente con el slack eliminado
```

> El right-sizing no está "hecho" cuando cambiás el YAML; está hecho cuando **OpenCost confirma la caída del costo sin que suba la tasa de OOM/throttling ni se viole el SLO**. Ese es el criterio de aceptación.

---

## 9. Referencias

- **CNPE Curriculum (CNCF):** https://github.com/cncf/curriculum
- **OpenCost — documentación oficial:** https://www.opencost.io/docs/
- **OpenCost — repositorio y spec del cost model:** https://github.com/opencost/opencost
- **Kubecost — docs:** https://docs.kubecost.com/
- **FinOps Foundation:** https://www.finops.org/
- **FOCUS (FinOps Open Cost & Usage Specification):** https://focus.finops.org/
- **Horizontal Pod Autoscaler:** https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- **HPA walkthrough:** https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/
- **Vertical Pod Autoscaler:** https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- **In-place resource resize (KEP-1287):** https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/
- **Cluster Autoscaler:** https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- **Cluster Autoscaler FAQ (scale-down):** https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md
- **Karpenter:** https://karpenter.sh/docs/
- **KEDA:** https://keda.sh/docs/
- **Goldilocks (Fairwinds):** https://goldilocks.docs.fairwinds.com/
- **Descheduler (rebalanceo/bin packing):** https://github.com/kubernetes-sigs/descheduler
- **Managing Resources for Containers:** https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- **Pod Quality of Service (QoS):** https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- **LimitRange:** https://kubernetes.io/docs/concepts/policy/limit-range/
- **Resource Quotas:** https://kubernetes.io/docs/concepts/policy/resource-quotas/