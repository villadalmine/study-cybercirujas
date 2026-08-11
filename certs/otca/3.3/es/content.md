# Tema 3.3 — Escalado del OpenTelemetry Collector

> Dominio 3: *El OpenTelemetry Collector* · Peso ≈ 5.2%
> Certificación: **OTCA — OpenTelemetry Certified Associate**

---

## 1. Motivación: el problema de la arquitectura de producción

Un único proceso Collector es trivial de ejecutar y peligroso del cual depender. En el momento en que tu volumen de telemetría supera el margen de un solo nodo — o en el momento en que introducís un paso de procesamiento *con estado* — la respuesta ingenua ("ejecutá más réplicas detrás de un Service") corrompe tus datos silenciosamente. Escalar el Collector no es, por lo tanto, un problema de capacidad; es un **problema de afinidad de datos**.

Dos fuerzas guían el diseño:

1. **Throughput y radio de impacto.** Las aplicaciones no deberían bloquearse esperando la exportación de telemetría, y un reinicio del Collector no debe tirar abajo una aplicación con él. Esto empuja el procesamiento *fuera* de la carga de trabajo (el patrón **agent**) y concentra el trabajo pesado en una capa compartida y escalable de forma independiente (el patrón **gateway**).

2. **Los pipelines con estado se rompen bajo un escalado horizontal ingenuo.** El tail-based sampling, `spanmetrics`, `servicegraph` y `groupbytrace` necesitan todos **cada span de una traza dada (o cada span de una arista de servicio dada) en la misma instancia**. Poné un balanceador de carga round-robin simple frente a un gateway de tail-sampling y fragmentás una única traza entre N réplicas: cada réplica ve un fragmento, cada una toma una decisión parcial, y la política "keep on error" no se dispara porque el span que erroró aterrizó en un pod distinto al del root. La telemetría se ve saludable y está silenciosamente equivocada — el peor modo de falla en observabilidad.

La idea central de SRE: **clasificá cada componente como stateless o stateful antes de elegir una estrategia de escalado.** Los componentes stateless escalan como cualquier servicio web. Los componentes stateful requieren *ruteo consistente* por una clave (usualmente `traceID`) para que los datos relacionados converjan en una única instancia.

---

## 2. Patrones de despliegue y dónde vive el estado

### 2.1 Agent vs Gateway

| Dimensión | Agent (DaemonSet / sidecar) | Gateway (Deployment/StatefulSet standalone) |
|---|---|---|
| Topología | Uno por nodo (DaemonSet) o por pod (sidecar) | Pool central pequeño, N réplicas |
| Tarea principal | Descargar la app rápido; resource detection; `k8sattributes`; host metrics | Tail sampling, filtrado, limpieza de PII, agregación, egress/auth |
| Eje de escalado | Escala *con el cluster* (nodos/pods) — sin HPA explícito | Escala de forma independiente vía HPA/KEDA |
| Estado | Debe mantenerse **stateless** | A menudo **stateful** (sampling/agregación) |
| Radio de impacto de fallas | Un nodo/pod | Compartido — necesita réplicas + colas |
| Red | Salto local (menor latencia, sin costo cross-AZ) | Fan-in; cuidado con el costo de egress cross-AZ |

El estándar de producción es **ambos**: una capa agent stateless alimentando un gateway escalable. Empujá el trabajo barato en CPU y local al nodo (batching, enriquecimiento de metadata de k8s, resource detection) al agent; reservá el gateway para el trabajo que necesita una vista global o egress privilegiado.

### 2.2 Componentes stateless vs stateful (la tabla de decisión)

| Componente | Tipo | ¿Escala por round-robin? | Requisito de ruteo |
|---|---|---|---|
| `batch`, `resource`, `attributes`, `filter`, `transform`, `memory_limiter` | Stateless | ✅ Sí | ninguno |
| `tail_sampling` | **Stateful** | ❌ No | todos los spans de una traza → misma instancia (`traceID`) |
| `groupbytrace` | **Stateful** | ❌ No | `traceID` |
| conector `spanmetrics` | **Stateful (agregador)** | ❌ No | consistente por `service`/`traceID`; si no, las series cuentan doble |
| conector `servicegraph` | **Stateful** | ❌ No | ambos spans de la arista (client+server) → misma instancia (`traceID`) |
| `groupbyattrs` | Stateless (por batch) | ✅ Sí | ninguno |

Cualquier cosa en las filas "stateful" fuerza el diseño de dos niveles con `loadbalancing` de la §3.

---

## 3. Manifiestos completos

### 3.1 Agent — DaemonSet (stateless, descarga local al nodo)

```yaml
# otel-agent-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
  labels: { app: otel-agent }
spec:
  selector:
    matchLabels: { app: otel-agent }
  template:
    metadata:
      labels: { app: otel-agent }
    spec:
      serviceAccountName: otel-agent          # RBAC for k8sattributes below
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.110.0
          args: ["--config=/conf/agent.yaml"]
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
          resources:
            requests: { cpu: "100m", memory: "192Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }   # limit == memory_limiter anchor
          ports:
            - { name: otlp-grpc, containerPort: 4317, protocol: TCP }
            - { name: metrics,   containerPort: 8888, protocol: TCP }
          volumeMounts:
            - { name: conf, mountPath: /conf }
      volumes:
        - name: conf
          configMap: { name: otel-agent-conf }
```

```yaml
# otel-agent-conf.yaml (ConfigMap data key: agent.yaml)
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

processors:
  # ORDER MATTERS: memory_limiter FIRST, batch LAST (before export).
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80          # relative to the container memory LIMIT
    spike_limit_percentage: 25
  k8sattributes:                  # enrich here (node-local), not on the gateway
    passthrough: false
    extract:
      metadata: [k8s.pod.name, k8s.namespace.name, k8s.deployment.name, k8s.node.name]
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  otlp:
    endpoint: otel-gateway-lb.observability.svc.cluster.local:4317
    tls: { insecure: true }
    sending_queue: { enabled: true, num_consumers: 4, queue_size: 5000 }
    retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s }

service:
  telemetry:
    metrics: { level: detailed, address: 0.0.0.0:8888 }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters:  [otlp]
```

RBAC requerido para `k8sattributes`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: otel-agent }
rules:
  - apiGroups: [""]
    resources: [pods, namespaces, nodes]
    verbs: [get, list, watch]
  - apiGroups: ["apps"]
    resources: [replicasets, deployments]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: otel-agent }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: otel-agent }
subjects:
  - { kind: ServiceAccount, name: otel-agent, namespace: observability }
```

### 3.2 El gateway de dos niveles — el diseño escalable canónico

La única forma correcta de escalar horizontalmente el tail sampling: un **Tier-1 stateless** que rutea por `traceID` usando el exporter `loadbalancing`, alimentando un pool **Tier-2 stateful** que es dueño de la decisión de sampling.

```
agents ──▶  Tier-1 (loadbalancing, stateless, HPA on CPU)
                │  consistent-hash by traceID
                ▼
           Tier-2 (tail_sampling, stateful, FIXED replicas)  ──▶  backend (OTLP/Tempo/…)
```

**Tier-1 — router de balanceo de carga (stateless):**

```yaml
# gateway-lb-conf.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }

exporters:
  loadbalancing:
    routing_key: traceID                 # traceID | service | metric | resource | streamID
    protocol:
      otlp:
        tls: { insecure: true }
        timeout: 3s
    resolver:
      k8s:                               # watches EndpointSlices → auto-detects Tier-2 scale changes
        service: otel-sampling.observability.svc.cluster.local
        ports: [4317]

service:
  telemetry: { metrics: { address: 0.0.0.0:8888 } }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter]
      exporters:  [loadbalancing]
```

**Tier-2 — pool de tail-sampling (stateful, Service headless):**

```yaml
# gateway-sampling-conf.yaml
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }

processors:
  memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 }
  tail_sampling:
    decision_wait: 15s                   # must exceed max inter-span gap of a trace
    num_traces: 200000                   # in-memory trace buffer; sized for peak
    expected_new_traces_per_sec: 2000
    policies:
      - name: keep-errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: keep-slow
        type: latency
        latency: { threshold_ms: 500 }
      - name: baseline-10pct
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
  batch: { send_batch_size: 8192, timeout: 5s }

exporters:
  otlp/backend:
    endpoint: tempo-distributor.tracing.svc.cluster.local:4317
    tls: { insecure: true }
    sending_queue: { enabled: true, queue_size: 10000 }
    retry_on_failure: { enabled: true }

service:
  telemetry: { metrics: { level: detailed, address: 0.0.0.0:8888 } }
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, tail_sampling, batch]
      exporters:  [otlp/backend]
```

El Service headless que el resolver `k8s` observa (su `EndpointSlice` es la fuente de verdad para el consistent hashing — por esto los eventos de escalado de Tier-2 se detectan automáticamente):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: otel-sampling
  namespace: observability
spec:
  clusterIP: None                        # headless → per-pod endpoints for the resolver
  selector: { app: otel-sampling }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317, protocol: TCP }
```

### 3.3 Autoescalado con el OpenTelemetry Operator (CRD + HPA)

Preferí el CRD `OpenTelemetryCollector` del Operator — cablea el HPA por vos y agrega el **Target Allocator** para el escalado de métricas (§3.4).

```yaml
# tier1-lb-collector.yaml — STATELESS tier: safe to autoscale
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-lb
  namespace: observability
spec:
  mode: deployment
  image: otel/opentelemetry-collector-contrib:0.110.0
  autoscaler:
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilization: 70
    behavior:
      scaleDown:
        stabilizationWindowSeconds: 300   # damp flapping on bursty trace volume
  resources:
    requests: { cpu: "500m", memory: "512Mi" }
    limits:   { cpu: "2",    memory: "2Gi" }
  config:                                 # inline the Tier-1 config from §3.2
    receivers:  { otlp: { protocols: { grpc: { endpoint: 0.0.0.0:4317 } } } }
    processors: { memory_limiter: { check_interval: 1s, limit_percentage: 80, spike_limit_percentage: 25 } }
    exporters:
      loadbalancing:
        routing_key: traceID
        protocol: { otlp: { tls: { insecure: true } } }
        resolver: { k8s: { service: otel-sampling.observability.svc.cluster.local, ports: [4317] } }
    service:
      pipelines:
        traces: { receivers: [otlp], processors: [memory_limiter], exporters: [loadbalancing] }
```

> ⚠️ **NO pongas un HPA sobre el pool de sampling Tier-2 sin cuidado.** Cuando un pod de sampling se agrega/quita, el consistent hash de Tier-1 re-mapea una porción del espacio de `traceID` hacia backends distintos. Las trazas en vuelo que atraviesan el rebalanceo se parten y obtienen decisiones parciales. Mitigaciones: mantené las réplicas de Tier-2 **fijas** (o escalá rara vez con ventanas de estabilización largas), dimensioná `decision_wait` con generosidad, y usá siempre `allocationStrategy: consistent-hashing` para que solo ~`1/N` de las claves se muevan por evento de escalado en lugar de todo el ring.

### 3.4 Escalar el scraping de Prometheus — el Target Allocator

Un problema de escalado distinto: un solo Collector no puede hacer scraping de miles de targets de Prometheus. El **Target Allocator** fragmenta los targets de `ServiceMonitor`/`PodMonitor` entre un `StatefulSet` de Collectors usando consistent hashing, de modo que agregar una réplica redistribuye la carga de scraping automáticamente.

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-metrics
  namespace: observability
spec:
  mode: statefulset                       # stable identity for per-replica target assignment
  replicas: 3
  targetAllocator:
    enabled: true
    allocationStrategy: consistent-hashing
    prometheusCR:
      enabled: true                       # discover ServiceMonitor/PodMonitor CRs
      scrapeInterval: 30s
  config:
    receivers:
      prometheus:
        config:
          scrape_configs: []              # Target Allocator injects the sharded targets
        target_allocator:
          endpoint: http://otel-metrics-targetallocator:80
          interval: 30s
          collector_id: ${env:POD_NAME}
    processors: { batch: {} }
    exporters:
      otlphttp/prom:
        endpoint: http://prometheus.monitoring.svc:9090/api/v1/otlp
    service:
      pipelines:
        metrics: { receivers: [prometheus], processors: [batch], exporters: [otlphttp/prom] }
```

---

## 4. CLI y salida de terminal esperada

Desplegá y confirmá la topología:

```console
$ kubectl -n observability get deploy,ds,hpa
NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/otel-lb-collector 2/2     2            2
deployment.apps/otel-sampling     3/3     3            3

NAME                        DESIRED   CURRENT   READY   NODE SELECTOR
daemonset.apps/otel-agent   6         6         6       <none>

NAME                                            REFERENCE                     TARGETS   MINPODS MAXPODS REPLICAS
horizontalpodautoscaler/otel-lb-collector-hpa  Deployment/otel-lb-collector  62%/70%   2       10      2
```

Observá el pool Tier-1 escalar bajo carga:

```console
$ kubectl -n observability get hpa otel-lb-collector-hpa -w
NAME                     TARGETS    MINPODS  MAXPODS  REPLICAS
otel-lb-collector-hpa    62%/70%    2        10       2
otel-lb-collector-hpa    88%/70%    2        10       2
otel-lb-collector-hpa    91%/70%    2        10       4      # scale-up fired
otel-lb-collector-hpa    58%/70%    2        10       4
```

Confirmá que el resolver de `loadbalancing` realmente ve cada endpoint de Tier-2 (hacé scraping de la telemetría interna en `:8888`):

```console
$ kubectl -n observability port-forward deploy/otel-lb-collector 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep -E 'loadbalancer_num_backends|loadbalancer_backend_latency_count'
otelcol_loadbalancer_num_backends{...} 3
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.1.7:4317",...} 41233
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.2.9:4317",...} 40817
otelcol_loadbalancer_backend_latency_count{endpoint="10.42.3.4:4317",...} 41902
```

`num_backends = 3` y conteos por endpoint casi iguales prueban que el ring está balanceado. Si ves `num_backends 1` mientras corren tres pods de sampling, el resolver está mal configurado (DNS de Service incorrecto o un Service con `clusterIP` en lugar de headless) y **todas las trazas están fijadas a un solo pod** — tu tier de sampling no está escalando en absoluto.

Inspeccioná las decisiones de sampling en un pod Tier-2:

```console
$ kubectl -n observability port-forward otel-sampling-0 8888:8888 >/dev/null 2>&1 &
$ curl -s localhost:8888/metrics | grep tail_sampling
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-errors",sampled="true"} 1204
otelcol_processor_tail_sampling_count_traces_sampled{policy="baseline-10pct",sampled="true"} 9871
otelcol_processor_tail_sampling_global_count_traces_sampled 210443
otelcol_processor_tail_sampling_sampling_trace_dropped_too_early 0
otelcol_processor_tail_sampling_new_trace_id_received 210443
```

Spans de decisión en vivo vía la extensión `zpages`:

```console
$ kubectl -n observability port-forward otel-sampling-0 55679:55679 >/dev/null 2>&1 &
$ curl -s "localhost:55679/debug/tracez?ztype=1&tracename=tail_sampling" | head
# HTML table of recent sampling-decision latencies and error samples
```

---

## 5. Verificación y diagnóstico de fallas

Métricas clave de telemetría interna (`:8888/metrics`) y qué significan cuando se mueven:

| Síntoma (métrica) | Causa probable | Solución |
|---|---|---|
| `otelcol_receiver_refused_spans` subiendo | `memory_limiter` aplicando backpressure — heap cerca del límite | Subí el límite de memoria **y** `check_interval`/réplicas; bajá `send_batch_size`; agregá persistencia de `sending_queue` |
| `otelcol_exporter_send_failed_spans` subiendo | Downstream (backend/Tier-2) caído o lento | Revisá `retry_on_failure`, salud del backend, TLS; observá `otelcol_exporter_queue_size` vs `_queue_capacity` |
| `otelcol_exporter_queue_size ≈ _queue_capacity` | Exportación más lenta que la ingesta; cola saturándose → drops a continuación | Aumentá `num_consumers`, `queue_size`; escalá Tier-2; habilitá cola persistente `file_storage` |
| `otelcol_loadbalancer_num_backends` < cantidad de réplicas | Resolver mal configurado / Service no headless | Usá Service headless + FQDN correcto; el resolver `k8s` necesita RBAC de EndpointSlice |
| Trazas incompletas / "keep-errors" no se dispara | Round-robin en lugar de ruteo por `traceID`; spans de una traza partidos | Insertá Tier-1 `loadbalancing` con `routing_key: traceID` |
| `tail_sampling_trace_dropped_too_early > 0` | `decision_wait` más corto que el gap de spans de la traza, o buffer `num_traces` demasiado chico | Subí `decision_wait`; aumentá `num_traces`; agregá réplicas de sampling |
| Series `spanmetrics` duplicadas/dobladas tras el scale-out | Conector agregador partido entre instancias | Ruteá por `traceID`/`service` a una única instancia, o sumá en el backend con la temporality correcta |
| `process_runtime_total_alloc_bytes` trepando hacia OOM a pesar del `memory_limiter` | `memory_limiter` colocado después de un procesador con buffering, o límite fijado por encima del límite del contenedor | Poné `memory_limiter` **primero**; anclá `limit_percentage` al *límite* de memoria del contenedor |

Playbook de triage rápido:

```console
# 1. Is the Collector even healthy? (health_check extension on :13133)
$ curl -s localhost:13133/ | jq .status
"Server available"

# 2. Ingest vs egress balance
$ curl -s localhost:8888/metrics | grep -E 'accepted_spans|sent_spans|refused_spans|send_failed'

# 3. Queue pressure (drops imminent when size→capacity)
$ curl -s localhost:8888/metrics | grep -E 'exporter_queue_(size|capacity)'

# 4. Confirm memory_limiter is armed, not thrashing
$ curl -s localhost:8888/metrics | grep -E 'process_runtime_total_(alloc|sys)_bytes'
```

**La regla de oro de la verificación de escalado del Collector:** los conteos deben reconciliar de punta a punta. `receiver_accepted` en los agents debería igualar `receiver_accepted` en Tier-1, y `tail_sampling_new_trace_id_received` de Tier-2 sumado a lo largo del pool debería seguir a las trazas distintas — no divergir por un factor de la cantidad de réplicas. Una divergencia proporcional a la cantidad de réplicas es la firma de una afinidad por `traceID` rota.

---

## 6. Referencias

- OpenTelemetry — *Scaling the Collector*: https://opentelemetry.io/docs/collector/scaling/
- OpenTelemetry — *Gateway deployment*: https://opentelemetry.io/docs/collector/deployment/gateway/
- OpenTelemetry — *Agent deployment*: https://opentelemetry.io/docs/collector/deployment/agent/
- `loadbalancingexporter` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/loadbalancingexporter
- `tailsamplingprocessor` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- `spanmetricsconnector` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md
- `servicegraphconnector` (contrib): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/servicegraphconnector/README.md
- `memorylimiterprocessor`: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batchprocessor`: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- OpenTelemetry Operator — *Target Allocator*: https://opentelemetry.io/docs/platforms/kubernetes/operator/target-allocator/
- OpenTelemetry Operator (CRD, autoscaler): https://github.com/open-telemetry/opentelemetry-operator
- Collector *internal telemetry*: https://opentelemetry.io/docs/collector/internal-telemetry/
- CNCF OTCA curriculum: https://github.com/cncf/curriculum