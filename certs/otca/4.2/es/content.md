# 4.2 Depuración de pipelines

*OTCA — Dominio 4: Mantenimiento y depuración de pipelines de telemetría de OpenTelemetry*

---

## 1. Motivación y el problema de arquitectura en producción

Un pipeline de telemetría es el único sistema de tu stack que falla **silenciosa y autorreferencialmente**. Cuando tu servicio de pagos se rompe, la telemetría te avisa. Cuando se rompe tu *telemetría*, nada te avisa: lo descubrís durante el próximo incidente, cuando los dashboards están planos y los traces desaparecieron justamente en la ventana que necesitás investigar. Este es el riesgo operativo que define a la observabilidad: el instrumento que mide todo lo demás no tiene ningún instrumento externo que lo mida a él.

La ruta de datos de OpenTelemetry es una cadena de múltiples saltos, y cada salto es un lugar donde los datos pueden descartarse sin que ningún error se propague de vuelta al origen:

```
Application SDK ──OTLP──▶ Collector (agent/DaemonSet) ──OTLP──▶ Collector (gateway/Deployment) ──▶ Backend
   │  receiver → [memory_limiter → batch → attributes/filter/sampling] → exporter (sending_queue)
```

Cada etapa tiene modos de falla independientes y asíncronos:

- El **SDK** almacena en buffer los spans en un `BatchSpanProcessor` y los descarta cuando se desborda: la app nunca se bloquea, así que un buffer lleno es invisible para la latencia de las requests.
- El **receiver** puede rechazar (`refuse`) datos (devuelve un error reintentable) cuando la contrapresión (backpressure) aguas abajo se propaga hacia arriba.
- El **processor memory_limiter** rechaza datos deliberadamente para proteger el proceso de un OOM.
- La **`sending_queue` del exporter** descarta los elementos encolados *más antiguos* cuando se llena, así que bajo carga perdés datos y el proceso sigue corriendo «sanamente».

El problema arquitectónico es que **la contrapresión y la pérdida de datos están desacopladas de la ruta de las requests por diseño**: el pipeline es asíncrono para que la telemetría nunca frene a la aplicación. Ese mismo desacoplamiento hace que la pérdida sea invisible a menos que instrumentes el propio pipeline. Depurar un pipeline de OpenTelemetry no es, por lo tanto, «leer un stack trace»; es un **recorrido disciplinado de la cadena**, respondiendo en cada salto: *¿están llegando datos aquí, están saliendo de aquí y, si no, qué contador dice por qué.*

El Collector expone exactamente esto: su propia **telemetría interna** (métricas, logs, traces sobre sí mismo), más componentes de diagnóstico creados a propósito: el exporter `debug`, y las extensions `zpages`, `pprof` y `health_check`. Dominar el pipeline significa saber cuál de estos responde qué pregunta, y a qué costo.

---

## 2. Comparación técnica — La caja de herramientas de diagnóstico

No existe un único botón de «debug». Cada herramienta observa una capa distinta a un costo distinto. Elegir mal desperdicia una ventana de incidente.

| Herramienta | Capa observada | Qué responde | Sobrecarga / riesgo | ¿Segura en producción? |
|---|---|---|---|---|
| **Métricas internas del Collector** (`:8888/metrics`) | Todo el pipeline, agregado | *Cuánto* se aceptó / rechazó / envió / falló / encoló, por componente | Insignificante (contadores) | ✅ Siempre activa |
| **Exporter `debug`** | Una rama del pipeline, por registro | *Qué* aspecto tiene el payload real (attributes, resource, nombres de span) | Alta en `detailed`: registra cada registro; puede inundar disco y CPU | ⚠️ Solo con muestreo |
| **Extension `zpages`** | Estado en vivo dentro del proceso | Spans recientes/en ejecución/con error (`tracez`), cableado efectivo del pipeline (`pipelinez`) | Baja (ring buffers en memoria) | ✅ Enlazar a localhost |
| **Extension `pprof`** | Runtime (Go) | Perfiles de CPU/heap/goroutines: *por qué* el Collector está lento o tiene fugas | Baja salvo que se esté perfilando activamente | ✅ Enlazar a localhost |
| **Extension `health_check`** | Liveness del proceso | ¿El Collector está arriba y sirviendo? | Insignificante | ✅ Usar para probes de k8s |
| **Exporter console/stdout del SDK** | Aplicación, antes de la red | ¿La *app* siquiera está produciendo telemetría? | I/O de consola por span | ⚠️ Desarrollo / alcance acotado |
| **`telemetrygen`** | Inyección sintética | Aislar el pipeline de la app (enviar datos válidos conocidos) | N/A (herramienta de prueba) | Test/staging |

### 2.1 Compromisos de verbosidad del exporter debug

El exporter `debug` (el sucesor renombrado del viejo exporter `logging`, deprecado desde la versión v0.86.0 del Collector) tiene tres niveles de verbosidad. La elección es un compromiso entre señal e inundación:

| `verbosity` | Salida | Usar cuando | Costo |
|---|---|---|---|
| `basic` | Una línea de resumen por batch: solo conteos | Confirmar que los datos *fluyen* por una rama | Mínimo |
| `normal` (por defecto) | Una línea compacta por registro con campos clave | Chequear identificadores/nombres de servicio | Moderado |
| `detailed` | resource + scope + attributes + body completos | Inspeccionar *por qué* un registro está malformado o mal atribuido | **Severo**: puede saturar stdout y disco |

Siempre combiná `detailed` con muestreo (`sampling_initial`, `sampling_thereafter`) para inspeccionar unos pocos registros, no la manguera entera.

### 2.2 Niveles de `service.telemetry` (las propias métricas del Collector)

| `metrics.level` | Emite | Cuándo subirlo |
|---|---|---|
| `none` | Nada | Nunca en producción: te quedás ciego |
| `basic` | Contadores de proceso + throughput de alto nivel | Mínimo viable |
| `normal` (por defecto) | accepted/refused/sent/failed por componente | Línea base estándar de producción |
| `detailed` | Agrega tamaños de cola, histogramas de tamaño de batch, métricas a nivel RPC | Depurando activamente descartes/latencia |

---

## 3. Manifiestos completos — Un Collector depurable

Lo siguiente es una configuración de `otelcol-contrib` **completa y sintácticamente válida**, cableada para diagnóstico: telemetría interna expuesta en Prometheus, las cuatro extensions de diagnóstico habilitadas, `memory_limiter` primero, un exporter `debug` en fan-out junto al backend real, y una `sending_queue` con capacidad explícita para que los descartes sean observables.

```yaml
# otel-collector-config.yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health/status
  zpages:
    endpoint: localhost:55679
  pprof:
    endpoint: localhost:1777
    block_profile_fraction: 0   # raise to 3 only while chasing a specific mutex/block stall
    mutex_profile_fraction: 0

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # ORDER MATTERS: memory_limiter must be first so it can refuse before
  # the batch processor accumulates unbounded data in memory.
  memory_limiter:
    check_interval: 1s
    limit_mib: 1500
    spike_limit_mib: 400
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  debug:
    verbosity: detailed
    sampling_initial: 5       # log the first 5 records...
    sampling_thereafter: 500  # ...then 1 in every 500
  otlp/backend:
    endpoint: otel-gateway.observability.svc.cluster.local:4317
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.crt
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000        # explicit so queue_size/queue_capacity are meaningful
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  extensions: [health_check, zpages, pprof]
  telemetry:
    logs:
      level: info            # flip to debug during an incident
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
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug, otlp/backend]   # fan-out: debug + real backend
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/backend]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/backend]
```

### 3.1 Deployment de Kubernetes con probes conectados a `health_check`

La extension `health_check` solo es útil si el orquestador realmente la consulta. Este Deployment enlaza liveness/readiness a ella y hace scraping del puerto de auto-métricas:

```yaml
# otel-collector-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels: { app: otel-collector }
  template:
    metadata:
      labels: { app: otel-collector }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8888"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.108.0
          args: ["--config=/conf/otel-collector-config.yaml"]
          ports:
            - { name: otlp-grpc, containerPort: 4317 }
            - { name: otlp-http, containerPort: 4318 }
            - { name: metrics,   containerPort: 8888 }
            - { name: health,    containerPort: 13133 }
          resources:
            requests: { cpu: "200m", memory: "512Mi" }
            limits:   { cpu: "1",    memory: "2Gi" }   # keep limit_mib < this
          livenessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet: { path: /health/status, port: 13133 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - { name: config, mountPath: /conf }
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
```

> **Regla de dimensionamiento:** mantené `memory_limiter.limit_mib` (1500) cómodamente por debajo del `memory.limit` del contenedor (2Gi). Si se alcanza primero el límite duro, el kernel mata el proceso por OOM antes de que el limiter pueda aplicar contrapresión: perdés la degradación elegante que el limiter existe para proveer.

### 3.2 Un pipeline cableado deliberadamente para descartar (para enseñar el síntoma)

Para *ver* un descarte, subdimensioná la cola y apuntá el exporter a un endpoint muerto:

```yaml
exporters:
  otlp/backend:
    endpoint: 127.0.0.1:9999   # nothing listening → every send fails
    tls: { insecure: true }
    sending_queue:
      enabled: true
      queue_size: 100          # tiny → fills instantly under load
    retry_on_failure:
      enabled: true
      max_elapsed_time: 10s    # after this, items are dropped
```

---

## 4. Comandos de CLI y salida real de terminal

### 4.1 Confirmar que el Collector arrancó y registró sus diagnósticos

```console
$ kubectl -n observability logs deploy/otel-collector | head -n 20
2026-08-11T14:20:03.112Z  info  service@v0.108.0/service.go:135  Setting up own telemetry...
2026-08-11T14:20:03.113Z  info  telemetry/telemetry.go:96  Serving metrics  {"address": "0.0.0.0:8888", "metrics level": "Detailed"}
2026-08-11T14:20:03.115Z  info  service@v0.108.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.108.0", "NumCPU": 8}
2026-08-11T14:20:03.116Z  info  extensions/extensions.go:39  Starting extensions...
2026-08-11T14:20:03.116Z  info  healthcheckextension@v0.108.0/healthcheckextension.go:35  Starting health_check extension  {"config": {"Endpoint":"0.0.0.0:13133"}}
2026-08-11T14:20:03.117Z  info  zpagesextension@v0.108.0/zpagesextension.go:56  Registered zPages span processor on tracer provider
2026-08-11T14:20:03.117Z  info  zpagesextension@v0.108.0/zpagesextension.go:69  Serving zPages  {"address": "localhost:55679"}
2026-08-11T14:20:03.118Z  info  pprofextension@v0.108.0/pprofextension.go:60  Starting net/http/pprof server  {"config": {"TCPAddr":{"Endpoint":"localhost:1777"}}}
2026-08-11T14:20:03.120Z  info  service@v0.108.0/service.go:230  Everything is ready. Begin running and processing data.
```

### 4.2 Health check

```console
$ kubectl -n observability port-forward deploy/otel-collector 13133:13133 &
$ curl -s localhost:13133/health/status | jq
{
  "status": "Server available",
  "upSince": "2026-08-11T14:20:03.115Z",
  "uptime": "15m3.204s"
}
```

### 4.3 El diagnóstico central: leer los contadores internos

La habilidad de depuración más importante es leer `:8888/metrics` y comparar **accepted vs refused** (ingreso) y **sent vs send_failed** (egreso).

```console
$ kubectl -n observability port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|exporter|processor)_' | grep spans
# HELP otelcol_receiver_accepted_spans Number of spans successfully pushed into the pipeline.
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148203
# HELP otelcol_receiver_refused_spans Number of spans that could not be pushed into the pipeline.
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 5120
# HELP otelcol_exporter_sent_spans Number of spans successfully sent to destination.
otelcol_exporter_sent_spans{exporter="otlp/backend"} 138900
# HELP otelcol_exporter_send_failed_spans Number of spans in failed attempts to send.
otelcol_exporter_send_failed_spans{exporter="otlp/backend"} 9303
# HELP otelcol_exporter_queue_size Current size of the retry queue (in batches).
otelcol_exporter_queue_size{exporter="otlp/backend"} 4998
otelcol_exporter_queue_capacity{exporter="otlp/backend"} 5000
```

Cómo se lee esto: `refused > 0` en el receiver significa que la contrapresión está llegando al ingreso. `send_failed > 0` con `queue_size` clavado en `queue_capacity` es la firma de manual de **una cola saturada contra un backend que falla**: el exporter no puede drenar, la cola se llena, la contrapresión trepa por la cadena, el receiver empieza a rechazar, y el `BatchSpanProcessor` del SDK empieza a descartar. Un vistazo a cuatro contadores localiza la falla en el egreso.

> **Nota sobre los nombres de métricas:** los nombres de Prometheus `otelcol_*` dependen de la versión. Las versiones históricas usaban `otelcol_processor_dropped_spans`; los Collectors recientes emiten `..._refused_spans` / `..._send_failed_spans`, y la telemetría interna está migrando al SDK de métricas de OpenTelemetry. Confirmá siempre contra la versión que ejecutás: `grep HELP` sobre el endpoint en vivo es la fuente autoritativa.

### 4.4 Ver el payload real con el exporter `debug`

```console
$ kubectl -n observability logs deploy/otel-collector | grep -A25 'TracesExporter'
2026-08-11T14:23:11.482Z  info  TracesExporter  {"kind":"exporter","data_type":"traces","name":"debug","resource spans":1,"spans":2}
2026-08-11T14:23:11.482Z  info  ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.21.0
Resource attributes:
     -> service.name: Str(cartservice)
     -> service.namespace: Str(shop)
     -> telemetry.sdk.language: Str(go)
     -> k8s.pod.name: Str(cartservice-7d9f-abcde)
ScopeSpans #0
InstrumentationScope go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp 0.53.0
Span #0
    Trace ID       : 5b8efff798038103d269b633813fc60c
    Parent ID      :
    ID             : eee19b7ec3c1b174
    Name           : GET /cart
    Kind           : Server
    Start time     : 2026-08-11 14:23:11.400 +0000 UTC
    End time       : 2026-08-11 14:23:11.481 +0000 UTC
    Status code    : Ok
Attributes:
     -> http.request.method: Str(GET)
     -> http.response.status_code: Int(200)
     -> url.path: Str(/cart)
```

Un `Parent ID` vacío en lo que debería ser un span hijo es la firma visual de **una propagación de contexto rota**: los traces se renderizarán como fragmentos desconectados en el backend.

### 4.5 Inspeccionar el estado en vivo del pipeline con zpages

```console
$ kubectl -n observability port-forward deploy/otel-collector 55679:55679 &
$ curl -s localhost:55679/debug/servicez | head
Pipelines
  traces: otlp -> [memory_limiter, batch] -> [debug, otlp/backend]
  metrics: otlp -> [memory_limiter, batch] -> [otlp/backend]

$ curl -s "localhost:55679/debug/tracez?ztype=1&tracename=exporter/otlp/backend"
# tracez shows spans bucketed by latency and by error — a non-empty
# "errors" bucket for the exporter span is a direct pointer to failing sends.
```

`pipelinez`/`servicez` confirman el cableado **efectivo**: invaluable cuando una config no se recargó o un componente desapareció silenciosamente de un pipeline. `tracez` muestra los spans de operación del propio Collector agrupados por latencia y error.

### 4.6 Aislar el pipeline de la aplicación con `telemetrygen`

Cuando no podés distinguir si la falla es de la app o del pipeline, inyectá telemetría válida conocida y observá cómo se mueven los contadores:

```console
$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 50 --rate 10
2026-08-11T14:35:22.101Z  info  traces/worker.go:99   generation of traces isn't finite, generating until stop condition
2026-08-11T14:35:27.104Z  info  traces/worker.go:120  traces generated  {"worker": 0, "traces": 50}
2026-08-11T14:35:27.104Z  info  traces/traces.go:124  stop the batch span processor

$ curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148253   # +50 → receiver is healthy
```

Si `accepted` sube pero `sent` no, la falla está aguas abajo del ingreso (processor o exporter). Si `accepted` no se mueve, la falla está en la red/endpoint/TLS entre el generador y el receiver, y por extensión, en la misma ruta que usa la app.

### 4.7 Del lado del SDK: ¿la aplicación siquiera está produciendo spans?

Antes de culpar al Collector, comprobá que la app emite. Redirigí el SDK a un exporter de consola y subí su nivel de log:

```console
$ export OTEL_TRACES_EXPORTER=console
$ export OTEL_LOG_LEVEL=debug
$ export OTEL_SERVICE_NAME=cartservice
$ ./cartservice
{"Name":"GET /cart","SpanContext":{"TraceID":"5b8efff7...","SpanID":"eee19b7e..."},"Parent":{"TraceID":"00000000...","remote":false},"Kind":2,"StartTime":"...","Attributes":[{"Key":"http.request.method","Value":"GET"}]}
```

Si no imprime nada, el problema es la instrumentación, no el pipeline: ninguna depuración del Collector va a ayudar.

### 4.8 Perfilar un Collector con fugas/lento con pprof

```console
$ go tool pprof -top http://localhost:1777/debug/pprof/heap
Showing nodes accounting for 812MB, 96.4% of 842MB total
      flat  flat%   sum%        cum   cum%
   410MB   48.7%  48.7%      410MB  48.7%  batchprocessor.(*batchTraces).add
   180MB   21.4%  70.1%      180MB  21.4%  collector/exporter/exporterhelper.(*queueSender)
```

Un heap dominado por el batch processor o el queue sender apunta a un problema de acumulación: normalmente un backend aguas abajo demasiado lento para drenar, que retiene datos en memoria hasta que `memory_limiter` interviene.

---

## 5. Verificación y diagnóstico de fallas

### 5.1 El método del recorrido (memorizá esto)

Depurar un pipeline es un **recorrido lineal de la cadena**; en cada salto hacé las mismas dos preguntas y consultá un contador:

| # | Salto | «¿Están llegando datos?» | «¿Están saliendo datos?» | Herramienta |
|---|---|---|---|---|
| 1 | SDK de la app | — | El exporter de consola imprime spans | `OTEL_TRACES_EXPORTER=console` |
| 2 | App → Collector | `receiver_accepted_*` sube | — | `:8888/metrics` + `telemetrygen` |
| 3 | Receiver → processors | accepted > 0 | `receiver_refused_*` == 0 | métricas internas |
| 4 | memory_limiter | logs: sin "Refusing data" | — | logs del Collector |
| 5 | Processors → exporter | — | `exporter_enqueue_failed_*` == 0 | métricas internas + `servicez` de zpages |
| 6 | Exporter → backend | `exporter_sent_*` sube | `exporter_send_failed_*` == 0, `queue_size` < capacidad | métricas internas + exporter `debug` |

Encontrá el primer salto donde «llegando» es verdadero pero «saliendo» es falso: ese es tu dominio de falla.

### 5.2 Catálogo de modos de falla

| Síntoma (lo que ves) | Firma (la evidencia) | Causa raíz | Solución |
|---|---|---|---|
| Al backend le faltan datos recientes, Collector "sano" | `exporter_send_failed_spans` en aumento, `queue_size == queue_capacity` | Backend caído/lento; cola llena, descartando los más antiguos | Reparar el backend; subir `queue_size`/`num_consumers`; alertar sobre `queue_size / queue_capacity` |
| Pérdida de datos durante picos de tráfico | Logs: `Memory usage is above soft limit. Refusing data.`; `receiver_refused_*` sube | `memory_limiter` protegiendo el proceso | Subir `limit_mib` (y el límite del contenedor); agregar un gateway de batching; escalar réplicas |
| Los traces se renderizan como fragmentos desconectados | `debug` muestra spans hijos con `Parent ID` vacío | Propagación de contexto rota (headers faltantes, propagator no soportado, límite de hilo/async) | Asegurar la propagación W3C `traceparent`; configurar propagators coincidentes de extremo a extremo |
| Ningún dato, la app parece bien | `receiver_accepted_* == 0`, sin logs del receiver | Endpoint o protocolo equivocado: gRPC `:4317` vs HTTP `:4318`, o desajuste de TLS | Alinear `OTEL_EXPORTER_OTLP_PROTOCOL`/endpoint; verificar TLS/`insecure` |
| Costo/latencia del backend de métricas explotando | `otelcol_processor_batch_batch_send_size` enorme; conjuntos de labels de alta cardinalidad en el payload (`debug detailed`) | Explosión de cardinalidad (valores de label sin límite como IDs de usuario) | Descartar/agregar vía processor `attributes`/`transform`/`filter`; corregir la instrumentación |
| Menos traces de los esperados, sin errores | Proporción estable de spans presentes; consistente con un argumento de muestreo | Muestreo head/tail descartando por diseño | Confirmar que la política de `OTEL_TRACES_SAMPLER` / tail-sampling es la buscada |
| El RSS del Collector sube y luego lo matan por OOM | `otelcol_process_memory_rss` en aumento; heap de pprof en batch/queue | El backend no puede drenar; los datos se acumulan más rápido de lo que el limiter libera | Reparar el egreso; bajar `send_batch_size`/`timeout`; asegurar `limit_mib` < límite del contenedor |
| La edición de config no tuvo efecto | `servicez`/`pipelinez` muestra el cableado viejo | Config no recargada / el reinicio no tomó el ConfigMap | Reiniciar/rolar el Collector; verificar la config montada; revisar los logs de arranque |

### 5.3 Alertar sobre el propio pipeline (para que no sea silencioso la próxima vez)

Toda la motivación de §1 se reduce a un puñado de alertas de PromQL sobre las propias métricas del Collector:

```promql
# Egress failing
rate(otelcol_exporter_send_failed_spans[5m]) > 0

# Ingress backpressure — data refused at the door
rate(otelcol_receiver_refused_spans[5m]) > 0

# Queue near saturation (drops imminent)
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8

# The Collector is missing entirely
up{job="otel-collector"} == 0
```

### 5.4 Checklist rápido de verificación

1. `curl :13133/health/status` → `Server available`.
2. `grep "Everything is ready"` en los logs de arranque; confirmar que no hay errores de componentes.
3. `curl :8888/metrics` → `receiver_accepted_*` aumentando mientras fluye el tráfico.
4. `receiver_refused_* == 0` y `exporter_send_failed_* == 0`.
5. `exporter_queue_size` bien por debajo de `queue_capacity`.
6. `curl :55679/debug/servicez` → el cableado del pipeline coincide con la intención.
7. Inyectar con `telemetrygen`; confirmar que los contadores se mueven de extremo a extremo.
8. exporter `debug` en `detailed` (muestreado) → attributes y `Parent ID` correctos.

---

## Referencias

- OpenTelemetry — Troubleshooting del Collector: https://opentelemetry.io/docs/collector/troubleshooting/
- OpenTelemetry — Telemetría interna del Collector (`service.telemetry`, auto-métricas): https://opentelemetry.io/docs/collector/internal-telemetry/
- OpenTelemetry — Configuración del Collector (receivers, processors, exporters, extensions): https://opentelemetry.io/docs/collector/configuration/
- Exporter `debug` del Collector (verbosidad, muestreo): https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/debugexporter
- Extension `zpages` del Collector: https://github.com/open-telemetry/opentelemetry-collector/tree/main/extension/zpagesextension
- Extension `pprof` del Collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/pprofextension
- Extension `health_check` del Collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/healthcheckextension
- Processor `memory_limiter` del Collector: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor
- Processor `batch` del Collector: https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor
- Helper de exporter (`sending_queue`, `retry_on_failure`): https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/exporterhelper
- `telemetrygen`, generador de carga/diagnóstico: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- Variables de entorno del SDK de OpenTelemetry (`OTEL_LOG_LEVEL`, `OTEL_TRACES_EXPORTER`, samplers): https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
- Propagación de contexto de OpenTelemetry (W3C `traceparent`): https://opentelemetry.io/docs/concepts/context-propagation/
- CNCF — Currículo de OTCA: https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf