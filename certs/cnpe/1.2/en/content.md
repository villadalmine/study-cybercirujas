# Tema 1.2 — Using Cost Management Solutions for Right-Sizing and Scaling

> **Certificación:** Cloud Native Platform Engineer (CNPE) · **Dominio 1 — Platform Engineering Fundamentals** · **Peso:** 5
> **Perfil:** Platform Architect / SRE Senior · **Nivel:** producción

---

## 1. Motivación y problema arquitectónico de producción

El costo en Kubernetes no es una línea del cloud bill: es una **propiedad emergente de decisiones de scheduling** que la plataforma toma miles de veces por hora. El scheduler de Kubernetes empaqueta Pods en nodos según sus `requests`, no según su consumo real. Esto crea dos brechas de dinero que el equipo de plataforma debe medir y cerrar:

- **Slack (holgura):** `requests − usage`. Capacidad reservada que nadie usa. El scheduler la trata como ocupada, así que un cluster puede estar al 90 % de CPU *reservada* y al 15 % de CPU *usada*. Pagás la reserva.
- **Stranded capacity (capacidad varada):** recursos de un nodo que no pueden asignarse porque falta la *otra* dimensión. Un nodo con 30 % de CPU libre pero 0 memoria libre no admite más Pods; ese CPU está varado y facturado.

El problema arquitectónico central es que **tres bucles de control operan sobre la misma señal (`requests`) con objetivos en tensión**:

| Bucle | Actúa sobre | Objetivo | Señal |
|---|---|---|---|
| **HPA** (Horizontal Pod Autoscaler) | nº de réplicas | mantener utilización/latencia objetivo | métricas de uso |
| **VPA** (Vertical Pod Autoscaler) | `requests`/`limits` por Pod | ajustar la reserva al consumo real | histórico de uso |
| **Cluster Autoscaler / Karpenter** | nº y forma de nodos | que haya lugar para los Pods pending | Pods `Unschedulable` |

Si HPA y VPA gobiernan **la misma métrica** (CPU) sobre el mismo workload, se realimentan destructivamente: VPA sube el `request`, la utilización relativa baja, HPA escala réplicas hacia abajo, el uso por Pod sube, VPA vuelve a subir el `request`… oscilación. La regla de producción: **HPA por una métrica (RPS/latencia/custom), VPA por otra (memoria), nunca ambos sobre CPU a la vez** — o VPA en modo `Off` (solo recommender) mientras HPA maneja la escala.

El **right-sizing** ataca el slack (dimensiona el Pod). El **scaling** ataca la demanda variable (dimensiona la flota). El **cost management** (OpenCost/Kubecost) es el plano de observabilidad que **atribuye** el gasto a namespace, deployment, label y team, cerrando el bucle FinOps: *inform → optimize → operate*. Sin atribución, right-sizing y autoscaling son optimizaciones a ciegas: no sabés qué tenant paga el slack ni qué cambio ahorró dinero.

**Anti-patrón de producción #1 — `requests` copiados del ejemplo.** Un Pod con `cpu: 1` y `memory: 1Gi` porque "así venía el chart", consumiendo 40 mCPU y 90 MiB. Multiplicado por 200 réplicas en 12 servicios: decenas de nodos comprados para reservar aire.

**Anti-patrón #2 — `limits == requests` por dogma.** Correcto para memoria (evita OOM impredecibles del vecino); costoso y a menudo dañino para CPU, donde el `limit` produce *CPU throttling* aunque el nodo tenga CPU ociosa. Se paga latencia p99 por una restricción artificial.

---

## 2. Comparativas técnicas (trade-offs)

### 2.1 Autoscaling: qué eje escala cada control

| Dimensión | HPA | VPA | KEDA | Cluster Autoscaler | Karpenter |
|---|---|---|---|---|---|
| Escala | réplicas (horizontal) | requests/limits (vertical) | réplicas, **incl. a 0** | nodos por node-group | nodos *just-in-time*, sin node-group |
| Disparador | métricas de uso / custom / external | histórico de uso | eventos (colas, Kafka, cron, Prometheus) | Pods `Unschedulable` | Pods `Unschedulable` + consolidación |
| Latencia de reacción | ~15–30 s | minutos (Recreate) / segundos (in-place) | segundos | 1–3 min (espera al node-group) | 30–60 s (llama a la API del cloud directo) |
| Scale-to-zero | no (mín. 1) | no | **sí** | no | drena nodos vacíos |
| Riesgo de interrupción | bajo | **alto** en modo Recreate (reinicia Pods) | bajo | drain de nodos | drain + consolidación agresiva |
| API | `autoscaling/v2` | `autoscaling.k8s.io/v1` | `keda.sh/v1alpha1` | flags del deployment | `karpenter.sh/v1` |

### 2.2 Node scaling: Cluster Autoscaler vs. Karpenter

| Criterio | Cluster Autoscaler | Karpenter |
|---|---|---|
| Modelo | escala grupos **homogéneos** preexistentes (ASG/MIG) | provisiona la instancia que *mejor encaja* el Pod pending |
| Bin-packing | limitado a las shapes del node-group | elige tipo/tamaño/AZ óptimo por batch de Pods |
| Consolidación | `scale-down` de nodos infrautilizados | consolidación continua (reemplaza N nodos por 1 más barato) |
| Spot/on-demand | por node-group separado | mezcla spot+on-demand en una sola `NodePool`, price-capacity-optimized |
| Cloud | multi-cloud | AWS (GA); soporte de otros clouds en evolución |
| Trade-off | predecible, maduro, config estática | menos nodos/menos costo, **pero** más churn → cuidado con PDBs y workloads stateful |

### 2.3 Estrategia de `requests`/`limits`

| Estrategia | CPU request | CPU limit | Mem request | Mem limit | QoS | Cuándo |
|---|---|---|---|---|---|---|
| Guaranteed | = uso p95 | = request | = uso p95 | = request | `Guaranteed` | tier crítico, latencia estricta |
| Burstable (recomendada) | ≈ uso p50–p95 | **sin limit** o alto | ≈ uso p95 + margen | = request | `Burstable` | mayoría de servicios web |
| BestEffort | — | — | — | — | `BestEffort` | batch interrumpible, dev |

Regla operativa: **memoria** `request == limit` (sin límite = riesgo de OOM del nodo por un vecino); **CPU** `request` ajustado y **sin limit** salvo aislamiento estricto de tenants (evita throttling con CPU ociosa disponible).

### 2.4 Plano de cost management

| Herramienta | Licencia | Qué da | Límite |
|---|---|---|---|
| **OpenCost** (CNCF incubating) | Apache-2.0 | modelo de costo por request/uso, allocation API, métricas Prometheus | UI básica; sin retención larga ni RBAC multi-tenant |
| **Kubecost** | freemium (core = OpenCost) | UI, alertas, savings, multi-cluster | features avanzadas de pago |
| **Goldilocks** (Fairwinds) | Apache-2.0 | dashboard de recomendaciones VPA por namespace | recomienda, no aplica |
| **KRR** (Robusta) | MIT | right-sizing CLI leyendo Prometheus, sin instalar VPA | one-shot, no continuo |

---

## 3. Manifiestos completos (sin recortar)

### 3.1 Guardarraíles del namespace: `ResourceQuota` + `LimitRange`

Primera línea de defensa de costo: sin defaults, un Pod sin `requests` es `BestEffort` e invisible para right-sizing y para OpenCost (cuesta $0 en el modelo por-request).

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-payments-quota
  namespace: payments
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.cpu: "80"
    limits.memory: 160Gi
    pods: "200"
    count/deployments.apps: "50"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: team-payments-defaults
  namespace: payments
spec:
  limits:
    - type: Container
      # Aplicado si el contenedor NO declara requests/limits.
      default:            # -> se vuelve el limit
        cpu: "500m"
        memory: 512Mi
      defaultRequest:     # -> se vuelve el request
        cpu: "100m"
        memory: 256Mi
      # Cotas duras: rechaza Pods absurdos en admission.
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: "10m"
        memory: 32Mi
      # Evita el anti-patrón limit=10x request (burst incontrolable).
      maxLimitRequestRatio:
        cpu: "4"
```

### 3.2 VPA en modo recomendación (`Off`) — right-sizing sin riesgo

Producción: se arranca VPA en `updateMode: "Off"`. El **recommender** publica `target`/`lowerBound`/`upperBound`; ningún Pod se reinicia. El equipo revisa y aplica vía GitOps.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-api-vpa
  namespace: payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  updatePolicy:
    updateMode: "Off"          # solo recomienda; NO muta Pods
  resourcePolicy:
    containerPolicies:
      - containerName: checkout-api
        controlledResources: ["cpu", "memory"]
        controlledValues: RequestsAndLimits
        minAllowed:
          cpu: 50m
          memory: 128Mi
        maxAllowed:
          cpu: "2"
          memory: 2Gi
      - containerName: istio-proxy   # el sidecar se dimensiona aparte
        mode: "Off"
```

Modo `Auto`/`InPlaceOrRecreate` (VPA ≥ 1.4, requiere el feature de in-place resize del cluster) evita el churn de reinicios aplicando el resize en caliente vía el subresource `resize` — sólo cuando estás listo para que VPA actúe:

```yaml
  updatePolicy:
    updateMode: "InPlaceOrRecreate"   # intenta resize in-place; recrea si no puede
    minReplicas: 2                      # nunca deja el Deployment por debajo de 2 durante el resize
```

### 3.3 HPA v2 con `behavior` (anti-flapping) sobre métrica desacoplada de VPA

VPA gobierna memoria; HPA escala por RPS (métrica external de Prometheus Adapter), evitando el conflicto de CPU.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api-hpa
  namespace: payments
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 3
  maxReplicas: 40
  metrics:
    - type: External
      external:
        metric:
          name: http_requests_per_second
          selector:
            matchLabels:
              service: checkout-api
        target:
          type: AverageValue
          averageValue: "50"      # 50 rps por Pod
    - type: Resource              # red de seguridad por memoria
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0        # sube rápido ante picos
      policies:
        - type: Percent
          value: 100                       # como mucho duplica
          periodSeconds: 30
        - type: Pods
          value: 4
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300      # baja despacio (5 min) -> anti-flap
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
      selectPolicy: Max
```

### 3.4 KEDA — scale-to-zero por profundidad de cola

Worker batch que sólo debe existir cuando hay trabajo: KEDA lo lleva a **0 réplicas** cuando la cola está vacía (HPA no puede).

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: invoice-worker-scaler
  namespace: payments
spec:
  scaleTargetRef:
    name: invoice-worker
  minReplicaCount: 0            # scale-to-zero: costo cero en reposo
  maxReplicaCount: 30
  cooldownPeriod: 120           # espera 120s de cola vacía antes de ir a 0
  pollingInterval: 15
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 60
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/1234567890/invoices
        queueLength: "20"       # ~20 mensajes pendientes por réplica
        awsRegion: us-east-1
      authenticationRef:
        name: keda-aws-credentials
```

### 3.5 Karpenter — `NodePool` + `EC2NodeClass` (API `v1`)

Provisiona spot barato, consolida continuamente y expira nodos para forzar rotación de AMIs. Diversidad de instancias → mejor precio spot y menos interrupciones.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-spot
spec:
  template:
    metadata:
      labels:
        team: platform
        capacity: spot
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]     # mezcla; prioriza spot por precio
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]        # Graviton = más barato
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 336h                       # rota nodos cada 14 días
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m                      # consolida agresivo -> menos nodos
    budgets:
      - nodes: "10%"                          # no interrumpe >10% de la flota a la vez
      - nodes: "0"                            # congela disrupción en horario pico
        schedule: "0 13 * * mon-fri"
        duration: 4h
  limits:
    cpu: "1000"
    memory: 1000Gi
  weight: 50
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest
  role: "KarpenterNodeRole-prod-cluster"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "prod-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "prod-cluster"
  tags:
    team: platform
    costcenter: "cc-4471"                     # etiqueta de atribución para el cost report
```

### 3.6 OpenCost — despliegue con precios de cloud reales

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opencost
  namespace: opencost
  labels: { app: opencost }
spec:
  replicas: 1
  selector:
    matchLabels: { app: opencost }
  template:
    metadata:
      labels: { app: opencost }
    spec:
      serviceAccountName: opencost
      containers:
        - name: opencost
          image: ghcr.io/opencost/opencost:1.115.0
          ports:
            - name: http
              containerPort: 9003
          env:
            - name: PROMETHEUS_SERVER_ENDPOINT
              value: "http://prometheus-server.monitoring.svc:80"
            - name: CLOUD_PROVIDER_API_KEY
              valueFrom:
                secretKeyRef: { name: opencost-cloud, key: apiKey }
            - name: CLUSTER_ID
              value: "prod-us-east-1"
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Medir el slack: reserva vs. uso real

```console
$ kubectl -n payments top pods --sort-by=cpu
NAME                            CPU(cores)   MEMORY(bytes)
checkout-api-6c9f8b7d4-2xk9p    41m          92Mi
checkout-api-6c9f8b7d4-7bqzt    38m          88Mi
invoice-worker-58d7c4f9-abcde   3m           64Mi
```

```console
$ kubectl -n payments describe deploy checkout-api | grep -A4 "Requests"
    Requests:
      cpu:     1
      memory:  1Gi
```

Diagnóstico: pide `1000m` CPU / `1Gi`, usa `~40m` / `~90Mi`. **Slack ≈ 96 % CPU, 91 % memoria.** Con 12 réplicas se reservan 12 CPU y 12 GiB para consumir <0.5 CPU y ~1 GiB.

Vista de cluster — reservado vs. capacidad:

```console
$ kubectl describe node ip-10-0-3-14.ec2.internal | grep -A6 "Allocated resources"
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                7200m (91%)   14 (177%)
  memory             28Gi (89%)    31Gi (98%)
```

91 % de CPU reservada; `kubectl top nodes` muestra el uso real:

```console
$ kubectl top nodes
NAME                          CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-3-14.ec2.internal     1180m        14%    9Gi            28%
ip-10-0-4-88.ec2.internal     980m         12%    7Gi            22%
```

**14 % usado, 91 % reservado.** La factura paga la reserva. Ese delta es el objetivo del right-sizing.

### 4.2 Leer la recomendación de VPA

```console
$ kubectl -n payments describe vpa checkout-api-vpa
...
Status:
  Recommendation:
    Container Recommendations:
      Container Name:  checkout-api
      Lower Bound:
        Cpu:     45m
        Memory:  110Mi
      Target:
        Cpu:     80m
        Memory:  160Mi
      Uncapped Target:
        Cpu:     78m
        Memory:  158Mi
      Upper Bound:
        Cpu:     260m
        Memory:  410Mi
```

Se aplica **`Target`** (`cpu: 80m`, `memory: 160Mi`). Ahorro por Pod: de `1000m/1Gi` → `80m/160Mi` = **~92 % CPU y ~84 % memoria reservada liberada**.

### 4.3 Diagnosticar el conflicto HPA↔VPA

```console
$ kubectl -n payments describe hpa checkout-api-hpa
Conditions:
  Type            Status  Reason               Message
  ----            ------  ------               -------
  AbleToScale     True    ReadyForNewScale     recommended size matches current size
  ScalingActive   False   FailedGetResourceMetric  the HPA was unable to compute the replica count:
                          failed to get cpu utilization: did not receive metrics
Events:
  Warning  FailedComputeMetricsReplicas  the HPA target's CPU metric and a VPA
           controlling CPU on the same Deployment produce oscillation
```

Corrección: quitar CPU del HPA o poner VPA `controlledResources: ["memory"]`.

### 4.4 KEDA — verificar scale-to-zero

```console
$ kubectl -n payments get scaledobject invoice-worker-scaler
NAME                    SCALETARGETKIND      MIN   MAX   READY   ACTIVE   AGE
invoice-worker-scaler   apps/v1.Deployment   0     30    True    False    3h

$ kubectl -n payments get deploy invoice-worker
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
invoice-worker   0/0     0            0           3h
```

`ACTIVE=False` + `0/0` réplicas = cola vacía, **costo de cómputo cero**. Al llegar mensajes, `ACTIVE` pasa a `True` y KEDA crea el primer Pod desde cero.

### 4.5 Karpenter — provisión y consolidación

```console
$ kubectl logs -n kube-system deploy/karpenter -c controller | grep -E "launched|disrupt"
{"level":"INFO","message":"launched nodeclaim","NodeClaim":"general-spot-x7k2p",
 "instance-type":"c7g.2xlarge","capacity-type":"spot","zone":"us-east-1b"}
{"level":"INFO","message":"disrupting via consolidation replace, replacing 3 nodes
 with 1 node","cost-savings":"$0.4123/hour"}
```

```console
$ kubectl get nodes -L karpenter.sh/capacity-type -L node.kubernetes.io/instance-type
NAME                          STATUS   CAPACITY-TYPE   INSTANCE-TYPE
ip-10-0-3-14.ec2.internal     Ready    spot            c7g.2xlarge
ip-10-0-5-201.ec2.internal    Ready    on-demand       m7i.xlarge
```

### 4.6 OpenCost — atribución de costo por namespace

```console
$ kubectl port-forward -n opencost svc/opencost 9003 &
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace" \
    | jq -r '.data[0] | to_entries[] | "\(.key)\t$\(.value.totalCost|floor)"'
payments        $412
monitoring      $88
default         $301
kube-system     $54
```

```console
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=namespace" \
    | jq '.data[0].payments | {cpuCost,ramCost,efficiency}'
{
  "cpuCost": 210.4,
  "ramCost": 168.9,
  "efficiency": 0.11
}
```

`efficiency: 0.11` = sólo el 11 % del costo reservado se traduce en uso real. **89 % del gasto de `payments` es slack** — cuantificado, con dueño, listo para el ticket de right-sizing.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Checklist de verificación

1. **Metrics disponibles:** `kubectl top nodes` responde → `metrics-server` sano. Sin él, HPA/VPA/`top` fallan.
2. **HPA no muta requests, VPA no muta réplicas:** confirmá que no comparten métrica (§4.3).
3. **VPA recommender vivo:** `kubectl -n kube-system get pods -l app=vpa-recommender`; el `.status.recommendation` debe poblarse en 5–10 min con historia.
4. **KEDA a cero:** `get scaledobject` muestra `MIN 0` y el Deployment llega a `0/0` tras `cooldownPeriod`.
5. **Karpenter respeta PDBs:** ningún Pod queda `Terminating` eterno por consolidación bloqueada.
6. **OpenCost con precios reales:** `efficiency` y `totalCost` no nulos; si `$0`, el modelo cayó a precios default (falta cloud key).

### 5.2 Tabla de fallas

| Síntoma | Causa raíz | Diagnóstico | Remedio |
|---|---|---|---|
| HPA `unknown` / no escala | sin `metrics-server` o sin `requests` en el Pod | `kubectl top pods` falla; `describe hpa` → `FailedGetResourceMetric` | instalar metrics-server; declarar `requests` (Utilization los necesita) |
| Réplicas oscilan (flapping) | `scaleDown` sin stabilization; HPA+VPA sobre CPU | eventos `SuccessfulRescale` repetidos c/minuto | `stabilizationWindowSeconds: 300`; desacoplar métricas |
| Pods `OOMKilled` tras right-sizing | `memory limit` bajado al p50, no al p95+margen | `describe pod` → `Reason: OOMKilled`, `exitCode: 137` | usar `Upper Bound` de VPA, no `Target`, para memoria; `limit=request` |
| CPU throttling con nodo ocioso | `cpu limit` artificial | `container_cpu_cfs_throttled_periods_total` alto | quitar `cpu limit` (Burstable) o subirlo |
| Karpenter no baja nodos | PDB `maxUnavailable: 0` o Pod sin controller (naked) | `describe node` → `Cannot disrupt Node: pod ... blocks`; `karpenter.sh/do-not-disrupt` | ajustar PDB; anotar/redeployar; revisar disruption budgets |
| Cluster no escala, Pods `Pending` | quota agotada / sin instancias spot en la AZ | `describe pod` → `FailedScheduling: Insufficient cpu`; logs de Karpenter `no instance type satisfied` | subir `ResourceQuota`/`limits` del NodePool; ampliar diversidad de instancias/AZ |
| OpenCost reporta `$0` | falta cloud pricing API key → default pricing | `curl .../allocation` con costos planos irreales | montar `CLOUD_PROVIDER_API_KEY`; validar `PROMETHEUS_SERVER_ENDPOINT` |
| VPA sin recomendación | recommender sin historia o `metrics-server`/Prometheus caído | `.status.conditions` → `NoPodsMatched`/vacío | verificar `targetRef`, esperar ventana de historia, revisar el recommender |
| Nodo spot interrumpido tumba workload stateful | stateful sobre spot sin drain handling | Pods reprogramados abruptamente | mover stateful a `capacity: on-demand` vía nodeSelector; usar taints |

### 5.3 Diagnóstico de flapping (comando)

```console
$ kubectl -n payments get events --field-selector involvedObject.name=checkout-api-hpa \
    --sort-by=.lastTimestamp | tail -5
2m   Normal  SuccessfulRescale  horizontalpodautoscaler/checkout-api-hpa  New size: 8; reason: ...
1m   Normal  SuccessfulRescale  horizontalpodautoscaler/checkout-api-hpa  New size: 4; reason: ...
30s  Normal  SuccessfulRescale  horizontalpodautoscaler/checkout-api-hpa  New size: 9; reason: ...
```

Rescale cada <60 s = flapping → subí `scaleDown.stabilizationWindowSeconds`.

### 5.4 Confirmar el ahorro (el bucle FinOps cerrado)

```console
# antes del right-sizing
$ curl -s ".../allocation/compute?window=2026-07-24T00:00:00Z,2026-07-31T00:00:00Z&aggregate=namespace" \
    | jq '.data[0].payments.totalCost'
412.11
# después (misma ventana de 7 días, post-aplicación de VPA Target)
$ curl -s ".../allocation/compute?window=7d&aggregate=namespace" \
    | jq '.data[0].payments | {totalCost, efficiency}'
{ "totalCost": 96.4, "efficiency": 0.63 }
```

`$412 → $96` (−77 %), `efficiency 0.11 → 0.63`. **La atribución prueba el ahorro** — sin OpenCost, el cambio sería invisible en el cloud bill agregado.

---

## 6. Referencias

- CNCF — CNPE Curriculum: https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- OpenCost (CNCF) — documentación: https://www.opencost.io/docs/
- OpenCost — Allocation API: https://www.opencost.io/docs/integrations/api
- Kubernetes — Horizontal Pod Autoscaler: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — HPA walkthrough (`behavior`, v2): https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/
- Kubernetes Autoscaler — Vertical Pod Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Kubernetes — Resize CPU and Memory Resources assigned to Containers (in-place): https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/
- Kubernetes — Resource Management for Pods and Containers (QoS, requests/limits): https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes — ResourceQuota / LimitRange: https://kubernetes.io/docs/concepts/policy/resource-quotas/ · https://kubernetes.io/docs/concepts/policy/limit-range/
- Kubernetes Autoscaler — Cluster Autoscaler: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Karpenter — documentación oficial: https://karpenter.sh/docs/
- Karpenter — NodePool / Disruption / Consolidation: https://karpenter.sh/docs/concepts/disruption/
- KEDA (CNCF) — Scaling Deployments y scale-to-zero: https://keda.sh/docs/latest/concepts/scaling-deployments/
- Goldilocks (Fairwinds): https://goldilocks.docs.fairwinds.com/
- FinOps Foundation (Linux Foundation) — Framework: https://www.finops.org/framework/
- CNCF — Cloud Native FinOps / TAG documentation: https://tag-app-delivery.cncf.io/