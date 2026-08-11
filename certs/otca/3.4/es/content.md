# 3.4 Pipelines — Data Pipelines del OpenTelemetry Collector

> **Dominio 3 — El OpenTelemetry Collector.** Un pipeline es la unidad de composición del Collector: el camino ordenado que recorre un único tipo de señal desde la ingesta hasta la salida, expresado como `receivers → processors → exporters` y conectado mediante el bloque `service::pipelines`. Todo lo demás en el Collector — connectors, clonado por fan-out, backpressure, self-telemetry — existe para hacer que ese camino sea correcto y observable bajo carga de producción.

---

## 1. Motivación y el problema arquitectónico de producción

### 1.1 Qué es realmente un pipeline

El binario del Collector es inerte. Contiene un registro de **componentes** (receivers, processors, exporters, connectors, extensions), pero ninguno de ellos hace nada hasta que la sección `service::pipelines` *construye un grafo* que los conecta. Un pipeline es una cadena de nodos en ese grafo, acotada a exactamente un tipo de señal:

```
traces:   otlp ──► memory_limiter ──► batch ──► otlp/backend
metrics:  prometheus ──► memory_limiter ──► batch ──► prometheusremotewrite
logs:     filelog ──► k8sattributes ──► batch ──► loki
```

Internamente (dado que la refactorización de pipelines de la v0.61 vive en `service/internal/graph`) todo el `service` se compila en un único **grafo acíclico dirigido** (DAG). Cada pipeline aporta nodos receiver, una cadena lineal de nodos processor, un nodo de fan-out y nodos exporter. Los connectors agregan aristas *entre* pipelines. El grafo se valida contra ciclos y compatibilidad de tipo de señal al arranque, y luego los datos fluyen por él como llamadas síncronas a funciones Go.

### 1.2 El problema que resuelven los pipelines

Sin un Collector, cada SDK de aplicación exporta directamente a cada backend. Eso acopla tu flota a la topología de los backends (cada servicio necesita endpoints de backend, credenciales, lógica de reintentos), hace imposible imponer políticas transversales — sampling, redacción de PII, enrutamiento por tenant — de forma centralizada, y convierte una migración de backend en un redeploy de toda la flota.

El modelo de pipeline invierte esto. Las aplicaciones hablan OTLP a un **punto de decisión local**; el Collector es dueño de:

| Preocupación | Dónde vive en el pipeline |
|---|---|
| Traducción de protocolo (Jaeger/Zipkin/Prometheus → OTLP interno) | receivers |
| Enriquecimiento (metadata de k8s, detección de recursos) | processors |
| Reducción (sampling, filtrado, batching) | processors / connectors |
| Fiabilidad (queue, retry, buffer persistente) | exporter helper |
| Backpressure hacia las fuentes | camino de retorno síncrono |
| Fan-out de egreso y abstracción de backend | exporters |

La idea arquitectónica clave que evalúa el examen: **un pipeline es por-señal y síncrono por defecto**. La propiedad de los datos, la mutación y la propagación de errores se derivan todas de esa cadena síncrona. Equivocá el orden y o bien filtrás memoria (batch antes de memory_limiter) o bien contás datos por duplicado silenciosamente (connectors mal conectados).

---

## 2. Anatomía y comparaciones técnicas

### 2.1 Los cinco roles de componente

| Rol | Interfaz que satisface | Cardinalidad en un pipeline | ¿Ordenado? |
|---|---|---|---|
| **Receiver** | `consumer.Traces/Metrics/Logs` (push) o scraper | 1..N (fan-in) | No |
| **Processor** | `consumer.Traces/...` (encadenado) | 0..N | **Sí — el orden es semántico** |
| **Exporter** | `consumer` terminal | 1..N (fan-out) | No |
| **Connector** | exporter del pipeline A + receiver del pipeline B | conecta pipelines | arista |
| **Extension** | no está en un pipeline | global | — |

Los receivers y exporters son **conjuntos no ordenados**; los processors son una **lista ordenada** y el orden cambia el comportamiento. Esta asimetría es la fuente individual más común de incidentes en producción.

### 2.2 Pipelines con nombre y compartición de componentes

Un pipeline se identifica con la clave `type[/name]`: `traces`, `traces/tail`, `metrics/internal`. Dos reglas gobiernan la compartición de instancias:

- **Mismo ID de componente en múltiples pipelines → una sola instancia compartida.** Un receiver `otlp` listado tanto en `traces` como en `traces/tail` se instancia **una vez** y hace fan-out a ambos. Por eso no podés vincular dos receivers `otlp` al mismo puerto sin nombres distintos (`otlp` vs `otlp/2`) y configuraciones de `endpoint` distintas.
- **`type` vs `type/name` son instancias diferentes.** `batch` y `batch/logs` son dos processors independientes con buffers independientes.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

service:
  pipelines:
    traces:
      receivers:  [otlp]           # ┐ same otlp instance
      processors: [memory_limiter, batch]
      exporters:  [otlp/jaeger]
    traces/sampled:
      receivers:  [otlp]           # ┘ fans out from the one receiver
      processors: [memory_limiter, tail_sampling, batch]
      exporters:  [otlp/coldstore]
```

### 2.3 Trade-offs del orden de los processors

| Decisión de orden | Elección correcta | Por qué |
|---|---|---|
| Posición de `memory_limiter` | **Primero** | Debe poder *rechazar* datos (devolver error → backpressure) antes de que cualquier processor posterior asigne memoria haciendo trabajo. |
| Posición de `batch` | **Último processor, antes de los exporters** | Batchear después de sampling/filtrado significa que solo batcheás los datos que conservás, maximizando la compresión y minimizando las RPC salientes. Batchear antes de `memory_limiter` acumularía memoria que el limiter ya no puede acotar. |
| sampling (`tail_sampling`, `probabilistic_sampler`) | Antes de `batch` | Descartar primero, batchear a los sobrevivientes. |
| enriquecimiento (`k8sattributes`, `resourcedetection`) | Temprano, antes del sampling si el sampling depende de esos atributos | El sampling basado en OTTL/atributos necesita que los atributos estén presentes. |
| `transform` / `filter` (OTTL) | Después del enriquecimiento, antes de batch | Opera sobre el conjunto de atributos final. |

> **Orden canónico:** `memory_limiter → resourcedetection/k8sattributes → transform/filter → sampling → batch`.

### 2.4 Comparación de topología de despliegue

| Dimensión | **Agent** (DaemonSet / sidecar) | **Gateway** (Deployment, N réplicas) |
|---|---|---|
| Localidad | Uno por nodo/pod, salto a `localhost` | Servicio centralizado, salto de red |
| Enriquecimiento | Metadata local del nodo/pod (`k8sattributes`, recurso del host) | Pierde la localidad del nodo; necesita reenviar la metadata |
| Eficiencia de batching | Pequeña (volumen por nodo) | Grande (agregada) — mejor compresión |
| Tail sampling | **Imposible** (una traza se reparte entre nodos) | **Nivel requerido** — pero necesita enrutamiento con afinidad de traza |
| Radio de impacto del backpressure | Contenido a un nodo | Compartido; un backend lento estanca a la flota |
| Credenciales | Fan-out de secrets a cada nodo | Sostenidas por un pequeño nivel gateway |

La arquitectura de referencia de producción es **de dos niveles**: los agents hacen enriquecimiento local del nodo y batching liviano, y luego usan el **exporter `loadbalancing` con clave en el `traceID`** para enrutar todos los spans de una traza a la *misma* réplica gateway, donde `tail_sampling` puede ver la traza completa.

### 2.5 Connectors vs processors vs exporters

Un **connector** es el único componente que cruza las fronteras entre pipelines y puede cambiar el tipo de señal. Es simultáneamente el *exporter* de un pipeline previo y el *receiver* de uno posterior.

| Necesidad | Usar |
|---|---|
| Transformar datos en el lugar, misma señal | processor |
| Enviar datos fuera del Collector | exporter |
| Derivar una *nueva señal* a partir de una existente (traces → métricas RED) | **connector** (`spanmetrics`) |
| Enrutar a pipelines distintos según atributo | **connector** (`routing`) |
| Unir múltiples pipelines en uno | **connector** (`forward`) |
| Contar telemetría en métricas | **connector** (`count`) |

---

## 3. Manifests completos e infraestructura (sin abreviar)

### 3.1 Config de gateway completa con todos los controles de producción

`collector-gateway.yaml`:

```yaml
# OpenTelemetry Collector — gateway tier, production profile
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /healthz
  pprof:
    endpoint: 0.0.0.0:1777
  zpages:
    endpoint: 0.0.0.0:55679
  file_storage/queue:
    directory: /var/lib/otelcol/queue
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/otelcol/queue
      max_transaction_size: 65536

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 16
      http:
        endpoint: 0.0.0.0:4318

processors:
  # MUST be first: bounds memory before any work is done.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]
    timeout: 5s
    override: false
  # Tail sampling: keep all errors + slow traces, 10% of the rest.
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 2000
    policies:
      - name: errors-policy
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: slow-policy
        type: latency
        latency:
          threshold_ms: 500
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

connectors:
  # Derive RED metrics from the trace stream.
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2s, 5s]
    dimensions:
      - name: http.method
      - name: http.status_code
    exemplars:
      enabled: true

exporters:
  otlp/jaeger:
    endpoint: jaeger-collector.observability.svc:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage/queue      # persistent — survives restart
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    timeout: 10s
  prometheusremotewrite:
    endpoint: https://mimir.observability.svc/api/v1/push
    tls:
      ca_file: /etc/otel/certs/ca.crt
    resource_to_telemetry_conversion:
      enabled: true
  debug:
    verbosity: normal
    sampling_initial: 5
    sampling_thereafter: 200

service:
  extensions: [health_check, pprof, zpages, file_storage/queue]
  telemetry:
    logs:
      level: info
      encoding: json
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, resourcedetection, tail_sampling, batch]
      exporters:  [otlp/jaeger, spanmetrics]     # fan-out: backend + connector
    metrics:
      receivers:  [otlp, spanmetrics]            # fan-in: apps + derived RED metrics
      processors: [memory_limiter, batch]
      exporters:  [prometheusremotewrite]
```

Dos cosas para internalizar de este manifest:

1. El pipeline `traces` hace **fan-out** hacia `otlp/jaeger` *y* el connector `spanmetrics`. Como `tail_sampling` fija `MutatesData: true`, el nodo de fan-out **clona la pdata** para todos los consumidores posteriores menos uno (§4.2). Luego el connector alimenta a `metrics`, que hace **fan-in** de las métricas RED derivadas junto a las métricas `otlp` de la aplicación.
2. `sending_queue.storage: file_storage/queue` mejora la queue en memoria a una queue persistente respaldada por WAL. Al reiniciar, los batches sin confirmar se reproducen en lugar de descartarse — la diferencia entre "at-least-once hasta la frontera del backend" y "best effort".

### 3.2 Kubernetes: ConfigMap + Deployment (crudo)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability
data:
  collector.yaml: |
    # (contents of collector-gateway.yaml above)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability
  labels: { app.kubernetes.io/name: otel-gateway }
spec:
  replicas: 3
  selector:
    matchLabels: { app.kubernetes.io/name: otel-gateway }
  template:
    metadata:
      labels: { app.kubernetes.io/name: otel-gateway }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.111.0
          args: ["--config=/conf/collector.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: zpages,    containerPort: 55679 }
          env:
            # memory_limiter limit_percentage reads this cgroup limit.
            - name: GOMEMLIMIT
              value: "1600MiB"
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { memory: "2Gi" }
          livenessProbe:
            httpGet: { path: /healthz, port: 13133 }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /healthz, port: 13133 }
          volumeMounts:
            - { name: config, mountPath: /conf }
            - { name: queue,  mountPath: /var/lib/otelcol/queue }
      volumes:
        - name: config
          configMap: { name: otel-gateway-config }
        - name: queue
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability
spec:
  selector: { app.kubernetes.io/name: otel-gateway }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
```

### 3.3 Nivel agent con enrutamiento de afinidad de traza hacia el gateway

El agent debe garantizar que todos los spans de una traza aterricen en la **misma** réplica gateway, o el tail sampling se rompe. Ese es el trabajo del exporter `loadbalancing`:

```yaml
# agent (DaemonSet) — routes by traceID to gateway replicas
exporters:
  loadbalancing:
    routing_key: traceID          # hash traceID → stable replica
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      k8s:
        service: otel-gateway.observability
        ports: [4317]

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, k8sattributes, batch]
      exporters:  [loadbalancing]
```

---

## 4. Mecánica interna y verificación por CLI

### 4.1 Validá antes de desplegar

El Collector incluye un subcomando `validate` que compila el grafo sin arrancarlo — detecta desajustes de tipo, componentes desconocidos y ciclos de forma offline:

```console
$ otelcol-contrib validate --config=collector-gateway.yaml
$ echo $?
0
```

Un desajuste de tipo de señal (p. ej. conectar un receiver `prometheus` — solo métricas — a un pipeline `traces`) falla ruidosamente:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: service::pipelines::traces: references receiver "prometheus" which is not configured
2024-... error   Collector failed to start   {"error": "invalid configuration"}
$ echo $?
1
```

Un componente no compilado dentro de la distribución:

```console
$ otelcol-contrib validate --config=needs-custom.yaml
Error: failed to get config: cannot unmarshal the configuration:
  error decoding 'processors': unknown type: "redaction/enterprise"
  for id: "redaction/enterprise" (valid values: [attributes batch filter ...])
```

### 4.2 Propiedad de los datos, mutación y clonado por fan-out

El modelo de datos interno del Collector es **pdata** (`ptrace.Traces`, `pmetric.Metrics`, `plog.Logs`) — la representación OTLP en memoria. Cada consumidor declara una capacidad:

```go
func (p *tailSamplingProcessor) Capabilities() consumer.Capabilities {
    return consumer.Capabilities{MutatesData: true}
}
```

En un punto de fan-out el service inserta un `fanoutconsumer`. Su regla:

- Si **todos** los consumidores posteriores son de solo lectura (`MutatesData: false`) → comparten el **mismo** puntero de pdata. Cero copias.
- Si **alguno** posterior muta → el fan-out **clona** la pdata para cada consumidor mutante (y entrega la original a lo sumo a un consumidor de solo lectura), evitando una race de datos donde un exporter lee spans que otro processor está reescribiendo.

Por eso agregar un processor mutante a un pipeline con fan-out puede duplicar silenciosamente tu CPU y tu tasa de asignación de memoria. Lo confirmás desde la self-telemetry, no desde los logs.

### 4.3 Log de arranque — leyendo el grafo compilado

```console
$ otelcol-contrib --config=collector-gateway.yaml
2024-06-10T12:00:01.114Z info    service@v0.111.0/service.go:135  Setting up own telemetry...
2024-06-10T12:00:01.115Z info    memorylimiter/memorylimiter.go:151  Using percentage memory limiter  {"total_memory_mib": 2000, "limit_percentage": 80, "spike_limit_percentage": 25}
2024-06-10T12:00:01.116Z info    memorylimiter/memorylimiter.go:75   Memory limiter configured  {"limit_mib": 1600, "spike_limit_mib": 500, "check_interval": 1}
2024-06-10T12:00:01.118Z info    tailsamplingprocessor@...  Sampling Policy Evaluation  {"policy": "errors-policy"}
2024-06-10T12:00:01.121Z info    service@v0.111.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.111.0", "NumCPU": 8}
2024-06-10T12:00:01.121Z info    extensions/extensions.go:39  Starting extensions...
2024-06-10T12:00:01.122Z info    otlpreceiver@...  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2024-06-10T12:00:01.122Z info    otlpreceiver@...  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
2024-06-10T12:00:01.123Z info    service@v0.111.0/service.go:230  Everything is ready. Begin running and processing data.
```

### 4.4 zpages — inspeccionando el grafo del pipeline en vivo

La extensión `zpages` expone la vista *en tiempo de ejecución* del DAG compilado:

```console
$ curl -s localhost:55679/debug/pipelinez | sed 's/<[^>]*>//g' | grep -A4 traces
Pipeline traces
  receivers:  otlp
  processors: memory_limiter, resourcedetection, tail_sampling, batch
  exporters:  otlp/jaeger, spanmetrics
  MutatesData: true
```

`/debug/servicez` lista las extensions y el service general; `/debug/tracez` muestra los spans internos *propios* del Collector (muestreados por bucket de latencia) — invaluable cuando un processor es el cuello de botella.

### 4.5 Self-telemetry — los números que importan

El Collector exporta sus propias métricas en `:8888`. Estos son los signos vitales del pipeline:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)' | grep -v '#'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"}      1.284e+06
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"}       0
otelcol_processor_batch_batch_send_size_sum{processor="batch"}         1.109e+06
otelcol_processor_batch_batch_send_size_count{processor="batch"}       152
otelcol_processor_batch_timeout_trigger_send_total{processor="batch"}  38
otelcol_exporter_sent_spans{exporter="otlp/jaeger"}                    1.101e+06
otelcol_exporter_send_failed_spans{exporter="otlp/jaeger"}             0
otelcol_exporter_queue_size{exporter="otlp/jaeger"}                    83
otelcol_exporter_queue_capacity{exporter="otlp/jaeger"}               5000
otelcol_exporter_enqueue_failed_spans{exporter="otlp/jaeger"}          0
```

La invariante contra la que auditás:

```
accepted − refused  ≈  Σ(sent + still-queued + dropped)
```

Si `accepted ≫ sent` y `queue_size → queue_capacity`, el backend es el cuello de botella y la queue se está llenando. Si `enqueue_failed_spans` sube, la queue está *llena* y estás descartando datos — eso es pérdida de datos, y debería generar un page.

---

## 5. Guía de verificación y diagnóstico de fallas

### 5.1 Tabla de decisión — síntoma a causa

| Síntoma (desde `:8888/metrics`) | Causa raíz | Solución |
|---|---|---|
| `receiver_refused_spans > 0`, los logs muestran `data refused due to high memory usage` | Límite duro de `memory_limiter` alcanzado; descartando carga correctamente | Subir el límite de memoria / agregar réplicas / reducir `send_batch_size`. Esto es el backpressure funcionando, no un bug. |
| `exporter_queue_size` clavado en `queue_capacity` | Backend más lento que la ingesta | Aumentar `num_consumers`, escalar el backend, o habilitar la queue persistente para sobrellevar los picos. |
| `exporter_enqueue_failed_spans > 0` | Queue llena → **descartando datos** | Queue persistente con `storage:` + capacidad de backend. Alertar. |
| `exporter_send_failed_spans` subiendo, logs de retry | Backend con errores/inalcanzable | Revisar `retry_on_failure`; verificar TLS/endpoint; vigilar `max_elapsed_time` (tras el cual los datos se descartan). |
| Spanmetrics/tail_sampling no producen nada | Connector/processor ubicado en el pipeline equivocado o desajuste de tipo de señal | `validate`; confirmar que el connector es exporter de un pipeline y receiver de otro. |
| OOMKilled por memoria a pesar de `memory_limiter` | `batch` ubicado **antes** de `memory_limiter`, o `limit_percentage` por encima del límite del contenedor | Reordenar; alinear `limit_*` con el cgroup / `GOMEMLIMIT`. |
| El tail sampling conserva trazas *parciales* | Spans de una traza llegando a réplicas gateway distintas | Anteponer el exporter `loadbalancing` con `routing_key: traceID`. |
| Métricas contadas por duplicado | Mismo connector conectado a dos pipelines, o receiver compartido sin querer | Auditar `service::pipelines` en busca de fan-out accidental. |

### 5.2 Backpressure — probando la cadena de punta a punta

Como el pipeline es síncrono hasta la sending queue, un backend sobrecargado se manifiesta como un **error gRPC reintentable en el cliente**. Verificalo deliberadamente:

```console
# Backend down; queue will fill, then the receiver refuses, then the client sees it.
$ telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --rate 20000 --duration 30s
...
2024-... traces_worker  rpc error: code = Unavailable desc = no more queue space, dropping data
```

Del lado del Collector, en el mismo momento:

```console
$ curl -s localhost:8888/metrics | grep -E 'refused_spans|enqueue_failed'
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"}   45210
otelcol_exporter_enqueue_failed_spans{exporter="otlp/jaeger"}      45210
```

La igualdad de esos dos contadores prueba que el camino de backpressure está intacto: el Collector rechazó exactamente lo que no pudo encolar, y al cliente se le indicó reintentar en lugar de que el Collector absorbiera (y perdiera) los datos silenciosamente.

### 5.3 El exporter debug — ver la pdata real

Cuando tenés que confirmar *qué* está fluyendo (¿los atributos presentes? ¿el recurso enriquecido?), agregá temporalmente el exporter `debug` (el reemplazo moderno del exporter `logging` eliminado):

```yaml
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      exporters: [otlp/jaeger, debug]   # tee to stdout
```

```console
$ otelcol-contrib --config=debug.yaml 2>&1 | head -20
2024-... info    Traces  {"resource spans": 1, "spans": 3}
2024-... info    ResourceSpans #0
Resource attributes:
     -> service.name: Str(checkout)
     -> k8s.pod.name: Str(checkout-7d9f-abc12)
     -> host.name: Str(node-3)
ScopeSpans #0
Span #0
    Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
    Name           : POST /cart/checkout
    Kind           : Server
    Status code    : Error
    Attributes:
         -> http.method: Str(POST)
         -> http.status_code: Int(500)
```

### 5.4 Salud y profiling bajo carga

```console
$ curl -s localhost:13133/healthz | jq
{ "status": "Server available", "upSince": "2024-06-10T12:00:01Z", "uptime": "4h12m" }

# CPU profile when a processor is suspected hot (pprof extension):
$ go tool pprof -top http://localhost:1777/debug/pprof/profile?seconds=30
      flat  flat%   sum%        cum   cum%
   1200ms 24.0%  24.0%     1800ms 36.0%  ...tailsamplingprocessor.(*policyEvaluator).Evaluate
    640ms 12.8%  36.8%      640ms 12.8%  runtime.memmove   # fan-out cloning cost
```

Ver `runtime.memmove` alto junto a un fan-out hacia un processor mutante confirma el costo de clonado de §4.2 — el remedio es mover la mutación fuera del camino con fan-out o dividir los pipelines.

---

## 6. Referencias

- OpenTelemetry Collector — Configuration & pipelines: https://opentelemetry.io/docs/collector/configuration/
- Collector architecture (data pipelines, components): https://opentelemetry.io/docs/collector/architecture/
- Building a custom Collector / component registry (OCB): https://opentelemetry.io/docs/collector/custom-collector/
- Connectors (spanmetrics, routing, forward, count): https://opentelemetry.io/docs/collector/building/connector/
- Deployment patterns (agent vs gateway): https://opentelemetry.io/docs/collector/deployment/
- Internal telemetry & self-monitoring metrics: https://opentelemetry.io/docs/collector/internal-telemetry/
- Scaling the Collector (tail sampling, loadbalancing): https://opentelemetry.io/docs/collector/scaling/
- `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- Exporter helper (sending_queue, retry_on_failure): https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/exporterhelper/README.md
- `tail_sampling` processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md
- `loadbalancing` exporter: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/exporter/loadbalancingexporter/README.md
- `spanmetrics` connector: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md
- `zpages` extension: https://github.com/open-telemetry/opentelemetry-collector/blob/main/extension/zpagesextension/README.md
- OTCA certification & curriculum (CNCF/Linux Foundation): https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/
- OTCA curriculum repository: https://github.com/cncf/curriculum