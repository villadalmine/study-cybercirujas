# Topic 3.3 — Tracing y Spans

> **Dominio PCA:** Conceptos de Observabilidad. **Peso en el examen:** 3.
> Este tema se ubica en la frontera entre las tres señales de telemetría. Para el PCA no se espera que *operes* un backend de tracing, pero *sí* se espera que entiendas qué es un span, cómo se ensambla un trace a partir de spans, en qué se diferencia el tracing de las métricas de Prometheus y cómo lo complementa, y —el punto que los examinadores realmente indagan— cómo los **exemplars** tienden un puente entre un histograma de Prometheus y un trace individual.

---

## 1. El problema en producción: por qué las métricas y los logs dejan de alcanzar

Considerá una ruta de request en un sistema moderadamente descompuesto:

```
client → api-gateway → checkout → payments → ledger
                          │           └────→ fraud-scoring
                          └────────────────→ inventory → cache → db
```

Tenés Prometheus. Tus dashboards dicen que el p99 de `http_request_duration_seconds` para `checkout` saltó de 120 ms a 4,2 s a las 14:03. Eso es una **métrica**: un agregado. Te dice *que* checkout está lento y *con qué frecuencia*, pero ha descartado estructuralmente lo único que ahora necesitás: **qué llamada downstream, en qué request específico, consumió los 4 segundos.**

Tres cosas se rompen a escala, y son la motivación arquitectónica del tracing:

1. **La agregación destruye la causalidad.** Un bucket de histograma es un contador. `checkout p99 = 4.2s` no puede descomponerse en "3,9 s fueron `fraud-scoring` esperando un lock". La información nunca se registró por request; se plegó dentro de un bucket en el momento de la ingesta.

2. **Las métricas no pueden cargar identidad de alta cardinalidad.** El "arreglo" obvio —agregar `user_id`, `request_id`, `downstream_host` como labels— es precisamente lo que el modelo de datos de Prometheus prohíbe, porque cada conjunto único de labels es una nueva serie temporal. Un millón de usuarios × 20 endpoints × 5 códigos de estado es una bomba de cardinalidad que hará OOM a tu TSDB. La identidad por request **no** pertenece a un label de métrica; pertenece a un trace.

3. **Los logs se correlacionan solo por suerte.** *Podés* loguear un `request_id` en cada servicio, pero tenés que (a) propagarlo correctamente en cada salto de red, (b) indexarlo en cada backend, y (c) reconstruir manualmente el orden y las relaciones padre/hijo a partir de timestamps en máquinas distintas con **clock skew** (desfase de reloj). Los logs te dan eventos; no te dan la *forma* del request.

El **tracing distribuido** resuelve esto convirtiendo al request mismo en la unidad de observación. Un request = un **trace**, identificado por un `trace_id` que se genera una vez en el borde y se **propaga** por cada salto. Cada unidad de trabajo dentro de ese trace es un **span**. El resultado es un árbol causal (técnicamente un DAG) que muestra exactamente adónde se fue el tiempo, por request, a través de los límites de proceso.

El modelo mental para el PCA:

| Señal | Pregunta que responde | Cardinalidad | Alcance |
|---|---|---|---|
| **Metrics** (Prometheus) | *¿Con qué frecuencia / cuánto / qué tan grave, en agregado?* | Baja (conjuntos de labels acotados) | A nivel de flota, series temporales |
| **Logs** | *¿Qué pasó exactamente en este instante?* | Alta (texto libre) | Por evento |
| **Traces** | *¿Dónde gastó su tiempo este request en particular, a través de los servicios?* | Muy alta (por request) | Por request, entre servicios |

Son complementarias, no competidoras. La postura correcta en producción es: **métricas para detectar y alertar, traces para localizar, logs para llegar a la causa raíz.** Los exemplars (Sección 3) son lo que te permite saltar directamente de lo primero a lo segundo.

---

## 2. Anatomía de un span y un trace

### 2.1 El span

Un **span** es una única operación nombrada y temporizada. Es el bloque de construcción atómico de un trace. Cada span carga los siguientes campos (modelo de datos de OpenTelemetry):

| Campo | Significado | Ejemplo |
|---|---|---|
| `trace_id` | ID de 16 bytes (128 bits) compartido por **cada** span del request. Se representa como 32 caracteres hex. | `4bf92f3577b34da6a3ce929d0e0e4736` |
| `span_id` | ID de 8 bytes (64 bits) único para **este** span. 16 caracteres hex. | `00f067aa0ba902b7` |
| `parent_span_id` | `span_id` del span que causó este. Vacío ⇒ este es el **root span**. | `a1b2c3d4e5f60718` |
| `name` | Nombre de operación de baja cardinalidad. | `HTTP GET /checkout` |
| `start_time` / `end_time` | Reloj de pared, precisión de nanosegundos. Diferencia = **duración** del span. | `2026-08-08T14:03:01.120Z` |
| `kind` | Rol en el request (ver abajo). | `SERVER` |
| `status` | `UNSET` / `OK` / `ERROR`. | `ERROR` |
| `attributes` | Metadatos clave/valor (convenciones semánticas). | `http.response.status_code=500` |
| `events` | Puntos con timestamp *dentro* de un span (p. ej. una excepción). | `exception` @ 14:03:05 |
| `links` | Referencias causales a spans en **otros** traces (p. ej. un trabajo batcheado). | → `trace_id=…` |

### 2.2 Span kind — por qué importa

`SpanKind` desambigua los dos lados de cada llamada de red y es lo que le permite a un backend coser correctamente un span cliente con el span servidor correspondiente:

| Kind | Significado | Emitido por |
|---|---|---|
| `SERVER` | Manejando un request entrante. | El callee (lado servidor de RPC/HTTP). |
| `CLIENT` | Haciendo una llamada saliente síncrona. | El caller. |
| `PRODUCER` | Encolando un mensaje asíncrono. | Publicador de mensajes. |
| `CONSUMER` | Procesando un mensaje asíncrono. | Suscriptor de mensajes. |
| `INTERNAL` | Trabajo sin contraparte remota (por defecto). | Funciones in-process. |

Un único salto HTTP produce **dos** spans que comparten la misma operación lógica: un span `CLIENT` en el caller y un span `SERVER` en el callee, enlazados por el contexto propagado.

### 2.3 El trace

Un **trace** es el conjunto de todos los spans que comparten un `trace_id`, ensamblados en un árbol por `parent_span_id`. Visualizado como una cascada (waterfall):

```
Trace 4bf92f35…  (total 4.21 s)
│
├─ [SERVER]  api-gateway  GET /checkout        ├──────────────────────────────┤  4.21s
│   └─ [CLIENT] api-gateway → checkout          ├─────────────────────────────┤  4.19s
│       └─ [SERVER] checkout  handle            ├────────────────────────────┤   4.15s
│           ├─ [CLIENT] checkout → inventory     ├─┤                             0.08s
│           │   └─ [SERVER] inventory  lookup      ├┤                            0.05s
│           ├─ [CLIENT] checkout → payments       ├──┤                          0.11s
│           └─ [CLIENT] checkout → fraud-scoring        ├──────────────────────┤ 3.94s  ← the culprit
│               └─ [SERVER] fraud-scoring  score          ├────────────────────┤ 3.90s
│                   └─ [INTERNAL] wait_for_model_lock       ├──────────────────┤ 3.88s  ← root cause
```

La cascada responde la pregunta que la métrica no pudo: **3,88 s de los 4,21 s fueron una espera de lock dentro de `fraud-scoring`.** Ninguna cantidad de agregación de métricas habría aislado ese request individual; el trace lo hace estructuralmente.

### 2.4 Propagación de contexto — el mecanismo que lo hace distribuido

Un trace solo abarca varios servicios si el `trace_id` y el `span_id` actual cruzan el cable. Esto es la **propagación de contexto**, inyectada en y extraída de headers portadores (carrier headers). El estándar de la industria es **W3C Trace Context**, dos headers HTTP:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  └── trace_id (32 hex) ───────────┘ └ parent span ┘ └ flags
             └ version
tracestate:  vendor1=opaqueValue,vendor2=opaqueValue
```

Decodificando `traceparent`:
- `00` — versión.
- `4bf9…4736` — el `trace_id` de 128 bits (constante a lo largo de todo el request).
- `00f067aa0ba902b7` — el `span_id` del caller, que se convierte en el `parent_span_id` del callee.
- `01` — `trace-flags`; el bit 0 = **sampled**. `01` significa "registrado y exportado"; `00` significa "no sampleado".

Si algún servicio de la cadena falla en propagar `traceparent`, el trace **se rompe**: el servicio downstream inicia un *nuevo* root span con un *nuevo* `trace_id`, y obtenés dos fragmentos de trace desconectados en lugar de una cascada. Esta es la falla de tracing más común en producción (Sección 7).

---

## 3. El puente hacia Prometheus: exemplars

Esta es la integración relevante para el PCA y la parte que a los examinadores más les importa. Los **exemplars** conectan una muestra de métrica de Prometheus con un trace específico —cerrando el bucle "detectar con métricas → localizar con traces" *dentro de la métrica misma*.

Un exemplar es una **anotación adjunta a una muestra de métrica** que registra: un valor, un timestamp y un conjunto de labels —convencionalmente `trace_id` (y a menudo `span_id`). Se expone en el formato de exposición **OpenMetrics** después de un `#`:

```
# HELP http_request_duration_seconds Request latency
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.1",service="checkout"} 24054
http_request_duration_seconds_bucket{le="0.5",service="checkout"} 24333
http_request_duration_seconds_bucket{le="1",service="checkout"} 24344
http_request_duration_seconds_bucket{le="5",service="checkout"} 24357 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 4.19 1.7549e+09
http_request_duration_seconds_bucket{le="+Inf",service="checkout"} 24357
```

Leé la última línea de bucket: el bucket `le="5"` registró una observación de **4,19 s** en ese timestamp, y *esa observación en particular vino del trace `4bf92f35…`*. En Grafana, ese exemplar se renderiza como un marcador de diamante sobre el gráfico de latencia; al hacer clic te lleva directamente (deep-link) a la cascada del trace en Tempo/Jaeger.

**Datos clave para el examen:**

- Los exemplars requieren el formato **OpenMetrics** (`Accept: application/openmetrics-text`). El formato de texto legacy de Prometheus no puede cargarlos.
- Prometheus almacena exemplars **solo** cuando el feature flag está activado: `--enable-feature=exemplar-storage`. El almacenamiento es un **buffer circular en memoria** de tamaño fijo (`--storage.exemplars.exemplars-limit`), *no* la TSDB en disco —los exemplars viejos se sobreescriben; sirven para correlación reciente, no para historial de largo plazo.
- Los exemplars se consultan a través de una **API dedicada**, no mediante evaluación de PromQL: `GET /api/v1/query_exemplars`.
- Solo ciertos tipos de métrica los cargan de forma significativa —principalmente **histogramas** y **contadores**— ya que todo el punto es "qué request produjo esta observación".

---

## 4. Tablas comparativas (trade-offs)

### 4.1 Backends de tracing

| | **Jaeger** | **Grafana Tempo** | **Zipkin** |
|---|---|---|---|
| Origen | CNCF (graduado) | Grafana Labs | Original (OpenZipkin) |
| Almacenamiento | Cassandra / Elasticsearch / Badger | **Object storage** (S3/GCS/Azure) | Cassandra / ES / MySQL |
| Indexado | Índice completo sobre tags/service/operation | **Sin índice por defecto** — búsqueda por trace-ID + scan de TraceQL | Índice de tags |
| Perfil de costo | Más alto (almacenamiento de índice) | **El más bajo** (object storage, sin índice) | Moderado |
| Consulta por atributos | Rica | TraceQL (escanea bloques) | Básica |
| Correlación con métricas | Vía exemplars + SPM | **Estrecha** — exemplar → deep-link a trace nativo, metrics-generator | Vía exemplars |
| Mejor ajuste | Búsqueda con muchos atributos | Retención barata de alto volumen, "tengo el trace_id" | Legacy / simple |

La apuesta de diseño de Tempo: **casi siempre llegás vía un exemplar o un `trace_id` conocido** (desde una métrica o un log), así que pagar para indexar cada span es desperdicio. Object storage barato + búsqueda por trace-ID cubre el patrón de acceso dominante.

### 4.2 Formatos de propagación de contexto

| Formato | Header(s) | ¿Estándar? | Notas |
|---|---|---|---|
| **W3C Trace Context** | `traceparent`, `tracestate` | **Recomendación de W3C** | El formato por defecto y recomendado; interoperable. |
| **B3 (Zipkin)** | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled`, `X-B3-ParentSpanId` (o único `b3`) | De facto | Ubicuo en mallas más viejas/Istio. |
| **Jaeger** | `uber-trace-id` | De proveedor | Clientes Jaeger legacy. |
| **Baggage** | `baggage` | W3C | Carga claves/valores a nivel de aplicación (no IDs) a lo largo del trace. |

Formatos no coincidentes entre dos servicios rompen el trace silenciosamente —un gateway emitiendo `b3` a un servicio configurado para leer solo `traceparent` produce un trace roto. Configurá un **propagador compuesto** (`tracecontext,baggage,b3`) en los límites.

### 4.3 Estrategias de sampling

Tracear cada request a escala es caro; el **sampling** decide cuáles traces conservar.

| Estrategia | Cuándo se decide | Pro | Contra |
|---|---|---|---|
| **Head sampling** | En el root, *antes* de que corra el request (p. ej. conservar 1%). Decisión propagada en `trace-flags`. | Barato, simple, sin buffering. | Ciego — decide antes de saber si el request tuvo error o fue lento. Los errores raros se descartan. |
| **Tail sampling** | En el collector, *después* de que el trace completo termina, según latencia/error/atributos. | Conserva los traces *interesantes* (errores, lentos). | Debe bufferear todos los spans de un trace en memoria hasta completarse; necesita `groupbytrace`; más costo de collector. |
| **Probabilistic** | Head, ratio fijo. | Volumen predecible. | Misma ceguera que head. |
| **Rate-limiting** | Head, tope de N traces/seg. | Acota el costo de forma dura. | Puede matar de hambre a servicios de bajo tráfico. |

Patrón de producción: **head-samplear generosamente (o 100%) → tail-samplear en el collector** para conservar el 100% de los errores + traces lentos y un pequeño % del resto.

### 4.4 Los tres pilares, lado a lado

| | Metrics | Logs | Traces |
|---|---|---|---|
| Forma del dato | Series temporales numéricas | Eventos de texto/estructurados con timestamp | DAG de spans por request |
| Lenguaje de consulta | PromQL | LogQL / Lucene / SQL | TraceQL / búsqueda por tags |
| Costo de almacenamiento | Bajo | Alto (volumen) | Alto (volumen) — mitigado por sampling |
| Tolerancia a cardinalidad | **Baja** | Alta | Muy alta |
| Uso principal | Alertar, tendencia, SLO | Detalle de causa raíz | Localizar latencia entre servicios |
| Enlace entre señales | — | Campo `trace_id` | `trace_id` ⇄ exemplar / log |

---

## 5. Infraestructura completa y manifiestos

Lo siguiente es un pipeline de tracing de extremo a extremo, con forma de producción, sobre Kubernetes: **app instrumentada → OpenTelemetry Collector → Tempo**, más un **Prometheus** configurado para almacenamiento de exemplars de modo que las métricas hagan deep-link a esos traces. Cada manifiesto es completo y sintácticamente válido.

### 5.1 OpenTelemetry Collector (Deployment + Config)

```yaml
# otel-collector.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-conf
  namespace: observability
data:
  otel-collector-config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      # Buffer complete traces before the tail sampler can judge them.
      groupbytrace:
        wait_duration: 10s
        num_traces: 100000
      # Keep 100% of errors and slow traces, 5% of the rest.
      tail_sampling:
        decision_wait: 12s
        num_traces: 100000
        policies:
          - name: keep-errors
            type: status_code
            status_code: { status_codes: [ERROR] }
          - name: keep-slow
            type: latency
            latency: { threshold_ms: 1000 }
          - name: sample-the-rest
            type: probabilistic
            probabilistic: { sampling_percentage: 5 }
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25

    exporters:
      otlp/tempo:
        endpoint: tempo.observability.svc.cluster.local:4317
        tls:
          insecure: true
      # Emit RED metrics derived from spans, for Prometheus to scrape.
      prometheus:
        endpoint: 0.0.0.0:8889
        enable_open_metrics: true      # required so exemplars are exposed
      debug:
        verbosity: basic

    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [10ms, 50ms, 100ms, 500ms, 1s, 5s]
        exemplars:
          enabled: true                # attach trace_id exemplars to the histogram

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, groupbytrace, tail_sampling, batch]
          exporters:  [otlp/tempo, spanmetrics]
        metrics/spanmetrics:
          receivers:  [spanmetrics]
          exporters:  [prometheus]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
  labels: { app: otel-collector }
spec:
  replicas: 2
  selector:
    matchLabels: { app: otel-collector }
  template:
    metadata:
      labels: { app: otel-collector }
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.109.0
          args: ["--config=/conf/otel-collector-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: prom-exp,  containerPort: 8889 }
          resources:
            requests: { cpu: "200m", memory: "400Mi" }
            limits:   { cpu: "1",    memory: "1Gi" }
          volumeMounts:
            - { name: conf, mountPath: /conf }
      volumes:
        - name: conf
          configMap:
            name: otel-collector-conf
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
  labels: { app: otel-collector }
spec:
  selector: { app: otel-collector }
  ports:
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
    - { name: otlp-http, port: 4318, targetPort: 4318 }
    - { name: prom-exp,  port: 8889, targetPort: 8889 }
```

### 5.2 Grafana Tempo (single-binary, respaldado por object-storage)

```yaml
# tempo.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-conf
  namespace: observability
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
    ingester:
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: 336h        # 14 days
    storage:
      trace:
        backend: s3
        s3:
          endpoint: minio.observability.svc.cluster.local:9000
          bucket: tempo-traces
          insecure: true
          access_key: ${S3_ACCESS_KEY}
          secret_key: ${S3_SECRET_KEY}
        wal:
          path: /var/tempo/wal
    metrics_generator:
      registry:
        external_labels: { source: tempo }
      storage:
        path: /var/tempo/generator/wal
        remote_write:
          - url: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
    overrides:
      defaults:
        metrics_generator:
          processors: [service-graphs, span-metrics]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: observability
spec:
  replicas: 1
  selector: { matchLabels: { app: tempo } }
  template:
    metadata:
      labels: { app: tempo }
    spec:
      containers:
        - name: tempo
          image: grafana/tempo:2.6.0
          args: ["-config.file=/etc/tempo/tempo.yaml"]
          ports:
            - { name: http,      containerPort: 3200 }
            - { name: otlp-grpc, containerPort: 4317 }
          envFrom:
            - secretRef: { name: tempo-s3-credentials }
          volumeMounts:
            - { name: conf, mountPath: /etc/tempo }
      volumes:
        - name: conf
          configMap: { name: tempo-conf }
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: observability
spec:
  selector: { app: tempo }
  ports:
    - { name: http,      port: 3200, targetPort: 3200 }
    - { name: otlp-grpc, port: 4317, targetPort: 4317 }
```

### 5.3 Prometheus configurado para exemplars

Lo crítico: el **feature flag**, el **límite del buffer de exemplars** y el scraping del endpoint OpenMetrics del collector.

```yaml
# prometheus-deploy.yaml (excerpt — container args + scrape config)
containers:
  - name: prometheus
    image: prom/prometheus:v2.54.1
    args:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--enable-feature=exemplar-storage"          # ← without this, exemplars are dropped
      - "--storage.exemplars.exemplars-limit=100000" # in-memory circular buffer size
      - "--web.enable-remote-write-receiver"         # accept Tempo's remote_write
```

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: otel-spanmetrics
    honor_labels: true
    metrics_path: /metrics
    scheme: http
    static_configs:
      - targets: ["otel-collector.observability.svc.cluster.local:8889"]
```

> Prometheus autonegocia OpenMetrics vía `Accept: application/openmetrics-text` en el scrape; el exporter `prometheus` del collector activa `enable_open_metrics: true`, así que los exemplars sobreviven el salto.

### 5.4 Auto-instrumentación de la aplicación (CR del OpenTelemetry Operator)

En lugar de editar el código de la app, el OTel Operator inyecta el SDK como sidecar/init-container vía una annotation:

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: checkout-instrumentation
  namespace: shop
spec:
  exporter:
    endpoint: http://otel-collector.observability.svc.cluster.local:4318
  propagators:
    - tracecontext        # W3C traceparent/tracestate
    - baggage
    - b3                  # accept legacy callers too
  sampler:
    type: parentbased_traceidratio
    argument: "1.0"       # head-sample 100%; the collector tail-samples
```

```yaml
# The workload opts in with one annotation:
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "checkout-instrumentation"
    spec:
      containers:
        - name: checkout
          image: registry.internal/shop/checkout:1.8.2
```

---

## 6. Comandos de CLI y salida de terminal real

### 6.1 Confirmar que la app está exportando spans (alcance de OTLP)

```console
$ kubectl -n shop exec deploy/checkout -- \
    curl -s -o /dev/null -w "%{http_code}\n" \
    http://otel-collector.observability.svc.cluster.local:4318/v1/traces \
    -X POST -H "Content-Type: application/json" -d '{"resourceSpans":[]}'
200
```

### 6.2 Inspeccionar qué está haciendo el collector

```console
$ kubectl -n observability logs deploy/otel-collector | grep -iE "TracesExporter|refused|dropped" | tail -5
2026-08-08T14:03:22.114Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "otlp/tempo", "#spans": 1043}
2026-08-08T14:03:37.220Z  info  TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "otlp/tempo", "#spans": 987}

# Collector's own metrics — accepted vs refused spans
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s localhost:8888/metrics | grep -E "receiver_accepted_spans|exporter_send_failed"
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1.284501e+06
otelcol_exporter_send_failed_spans{exporter="otlp/tempo"} 0
```

### 6.3 Verificar que la exposición OpenMetrics carga exemplars

```console
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s -H 'Accept: application/openmetrics-text' localhost:8889/metrics \
    | grep 'duration.*# {trace_id' | head -1
traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",span_name="HTTP GET /checkout",le="5000"} 24357 # {trace_id="4bf92f3577b34da6a3ce929d0e0e4736",span_id="00f067aa0ba902b7"} 4190.4 1.754901e+09
```

El sufijo `# {trace_id=…}` es el exemplar. Si está ausente, o bien `enable_open_metrics` es false o hiciste el fetch sin el header `Accept` de OpenMetrics.

### 6.4 Confirmar que Prometheus efectivamente almacenó el exemplar

```console
$ kubectl -n observability port-forward svc/prometheus 9090:9090 &
$ curl -s -G 'http://localhost:9090/api/v1/query_exemplars' \
    --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"}' \
    --data-urlencode 'start=2026-08-08T14:00:00Z' \
    --data-urlencode 'end=2026-08-08T14:05:00Z' | python3 -m json.tool
{
    "status": "success",
    "data": [
        {
            "seriesLabels": {
                "__name__": "traces_span_metrics_duration_milliseconds_bucket",
                "service_name": "checkout",
                "span_name": "HTTP GET /checkout"
            },
            "exemplars": [
                {
                    "labels": { "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
                                "span_id":  "00f067aa0ba902b7" },
                    "value": "4190.4",
                    "timestamp": 1754901801.774
                }
            ]
        }
    ]
}
```

Si `data` es `[]` acá pero la Sección 6.3 mostró exemplars, falta el feature flag (`--enable-feature=exemplar-storage`).

### 6.5 Traer el trace real desde Tempo por ese `trace_id`

```console
$ kubectl -n observability port-forward svc/tempo 3200:3200 &
$ curl -s http://localhost:3200/api/traces/4bf92f3577b34da6a3ce929d0e0e4736 \
    | jq '.batches[].scopeSpans[].spans[] | {name, kind, durMs: ((.endTimeUnixNano|tonumber - (.startTimeUnixNano|tonumber))/1e6)}'
{ "name": "HTTP GET /checkout",       "kind": 2, "durMs": 4210.1 }
{ "name": "checkout → fraud-scoring", "kind": 3, "durMs": 3940.6 }
{ "name": "wait_for_model_lock",      "kind": 1, "durMs": 3880.2 }
{ "name": "checkout → inventory",     "kind": 3, "durMs": 80.4 }
{ "name": "checkout → payments",      "kind": 3, "durMs": 110.7 }
```

(`kind`: 1=INTERNAL, 2=SERVER, 3=CLIENT.) La ruta alerta de métrica → exemplar → trace → span de causa raíz queda ahora cerrada de extremo a extremo.

### 6.6 Buscar en Tempo por atributo (TraceQL)

```console
$ curl -s -G http://localhost:3200/api/search \
    --data-urlencode 'q={ .service.name="checkout" && duration > 1s && status=error }' \
    | jq '.traces[] | {traceID, durMs: .durationMs, root: .rootTraceName}'
{ "traceID": "4bf92f3577b34da6a3ce929d0e0e4736", "durMs": 4210, "root": "HTTP GET /checkout" }
```

### 6.7 Validar la configuración del collector antes del rollout

```console
$ docker run --rm -v "$PWD/otel-collector-config.yaml:/c.yaml" \
    otel/opentelemetry-collector-contrib:0.109.0 validate --config=/c.yaml
$ echo $?
0
```

---

## 7. Verificación y diagnóstico de fallas

Las fallas de tracing dominantes son los **traces rotos** (contexto no propagado) y los **exemplars faltantes** (huecos de configuración). Trabajalos metódicamente.

### 7.1 Trace roto — el request produce dos `trace_id`s desconectados

**Síntoma:** en la UI, el árbol de spans de `checkout` termina en un límite de servicio; el servicio downstream aparece como un trace *raíz separado*.

**Escalera de causa raíz:**

1. **Header no propagado.** El servicio intermedio inicia un trace nuevo. Confirmalo capturando los headers en el callee:
   ```console
   $ kubectl -n shop exec deploy/fraud-scoring -- \
       sh -c 'nc -l -p 8080 | grep -i traceparent'
   # (no output) → traceparent never arrived → caller isn't injecting it
   ```
2. **Formato de propagador no coincidente.** El caller emite `b3`, el callee lee solo `tracecontext`. Arreglo: configurá un propagador compuesto (`tracecontext,baggage,b3`) en **ambos** extremos (Sección 5.4).
3. **Un proxy elimina headers desconocidos.** Un ingress/mesh que hace whitelisting de headers puede descartar `traceparent`. Permitilo explícitamente en la configuración del proxy.

### 7.2 Ningún span llega al backend

```console
# Is the app even exporting? Check the SDK's own error stream.
$ kubectl -n shop logs deploy/checkout | grep -iE "otel|export|4317|4318" | tail
Failed to export spans: connection refused: otel-collector:4317

# → endpoint wrong or collector Service down. Verify:
$ kubectl -n observability get endpoints otel-collector
NAME             ENDPOINTS                             AGE
otel-collector   10.244.1.7:4317,10.244.2.9:4317       6d
```
`ENDPOINTS` vacío ⇒ desajuste de selector/label entre el Service y los pods.

### 7.3 Los spans llegan pero todo se descarta — mala configuración de sampling

```console
$ kubectl -n observability exec deploy/otel-collector -- \
    curl -s localhost:8888/metrics | grep tail_sampling
otelcol_processor_tail_sampling_count_traces_sampled{policy="sample-the-rest",sampled="false"} 1.9e+06
otelcol_processor_tail_sampling_count_traces_sampled{policy="keep-errors",sampled="true"}      412
```
Si `sampled="false"` domina y hasta los errores faltan, verificá que `groupbytrace.wait_duration` ≥ tu request más largo, y `decision_wait` ≥ `wait_duration` —de lo contrario el tail sampler juzga traces incompletos y los descarta.

### 7.4 Exemplars faltantes en Prometheus (las métricas están bien)

Hacé búsqueda binaria en el pipeline:

| Verificación | Comando | Si falla |
|---|---|---|
| ¿El collector emite exemplars? | §6.3 `grep '# {trace_id'` | Poné `enable_open_metrics: true`; `spanmetrics.exemplars.enabled: true`. |
| ¿Prometheus scrapea OpenMetrics? | `curl .../targets` → revisá `scrapePool` | Prometheus lo negocia automáticamente; verificá que el target esté `up`. |
| ¿Feature flag activado? | `curl .../api/v1/status/flags \| grep exemplar` | Agregá `--enable-feature=exemplar-storage`. |
| ¿Almacenado? | §6.4 `query_exemplars` | Si el buffer está lleno, subí `--storage.exemplars.exemplars-limit`. |

```console
$ curl -s http://localhost:9090/api/v1/status/flags | jq '."enable-feature", ."storage.exemplars.exemplars-limit"'
"exemplar-storage"
"100000"
```

### 7.5 El clock skew corrompe la cascada

**Síntoma:** un span hijo parece *empezar antes que su padre*, o muestra duración negativa.

**Causa:** los timestamps de los spans se establecen con el reloj local de cada host; un nodo con tiempo a la deriva desfasa la cascada. **El diagnóstico y el arreglo viven en NTP, no en el stack de tracing:**

```console
$ kubectl get nodes -o name | while read n; do
    echo "== $n =="; kubectl debug $n -it --image=busybox -- date -u 2>/dev/null; done
== node/worker-1 == Sat Aug  8 14:03:07 UTC 2026
== node/worker-2 == Sat Aug  8 14:03:11 UTC 2026   # ← 4s ahead; enforce chrony/NTP
```
El tracing expone el clock skew sin piedad; tratá la sincronización sub-segundo por NTP como un prerrequisito para traces confiables.

### 7.6 Checklist de sanidad

- [ ] `otelcol_receiver_accepted_spans` en aumento, `otelcol_exporter_send_failed_spans` plano en 0.
- [ ] Un `trace_id` conocido es recuperable desde el backend (§6.5) y muestra **un** árbol conectado.
- [ ] `traceparent` observado intacto en el último salto de la cadena.
- [ ] Exemplar visible en OpenMetrics (§6.3) **y** almacenado en Prometheus (§6.4).
- [ ] `--enable-feature=exemplar-storage` presente en los flags de Prometheus.
- [ ] Relojes de los nodos dentro de sub-segundo entre sí.

---

## 8. Referencias

- Prometheus — Exemplars (feature, storage, API): https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- Prometheus — Querying exemplars (`/api/v1/query_exemplars`): https://prometheus.io/docs/prometheus/latest/querying/api/#querying-exemplars
- OpenMetrics specification (exemplar exposition format): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md#exemplars
- W3C Trace Context (Recommendation — `traceparent`/`tracestate`): https://www.w3.org/TR/trace-context/
- OpenTelemetry — Traces / spans data model & specification: https://opentelemetry.io/docs/concepts/signals/traces/
- OpenTelemetry — Context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- OpenTelemetry — Sampling (head vs tail): https://opentelemetry.io/docs/concepts/sampling/
- OpenTelemetry Collector — configuration & tail-sampling processor: https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Operator — auto-instrumentation (`Instrumentation` CR): https://github.com/open-telemetry/opentelemetry-operator
- Grafana Tempo — architecture & configuration: https://grafana.com/docs/tempo/latest/
- Grafana Tempo — TraceQL: https://grafana.com/docs/tempo/latest/traceql/
- Jaeger (CNCF) — architecture: https://www.jaegertracing.io/docs/latest/architecture/
- CNCF — PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf