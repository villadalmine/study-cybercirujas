# 3.1 Configuration — The OpenTelemetry Collector

> **Domain 3: The OpenTelemetry Collector · Peso en el examen ≈ 5.2%**
> Nivel: Principal Platform / SRE. Asume que ya sabés qué es una señal (trace, metric, log), el protocolo OTLP y una pipeline.

---

## 1. Motivación: la configuración *es* el Collector

El Collector se distribuye como un único binario estático con **cero comportamiento incorporado**. No tiene receivers escuchando por defecto, ni destino por defecto, ni opinión alguna sobre tu topología. Cada byte de lo que hace — qué ingiere, cómo lo transforma, dónde lo escribe, cuánta memoria defiende, qué expone para debugging — se declara en un único documento YAML. No hay API imperativa ni consola de administración. **El archivo de configuración es el contrato de runtime completo.**

Esta es una decisión arquitectónica deliberada y crea el problema central de producción de este dominio:

- **Fan-in / fan-out.** En una topología de gateway, un único deployment del Collector recibe OTLP desde cientos de servicios instrumentados y lo multiplexa hacia N backends (Tempo, TSDB compatible con Prometheus, un vendor, un object store). Todo ese cableado — qué source alimenta a qué sink, con qué transforms — vive en el bloque `service::pipelines`. Una pipeline que *declaraste* pero no *cableaste* silenciosamente no hace nada.
- **Backpressure y autoprotección.** Un Collector bajo un pico de tráfico sin `memory_limiter` va a hacer OOM y va a tirar abajo todo el tier de ingesta. La autoprotección no es un flag; es un processor que tenés que ubicar, en el orden correcto, en cada pipeline.
- **Config drift y multi-tenancy.** El mismo binario corre como **agent** por nodo (DaemonSet) y como **gateway** central (Deployment). Son la misma imagen con distinta config. Lograr que las dos configs difieran de la forma equivocada (el agent batchea, el gateway también batchea pero con una ventana más chica; el agent tiene `memory_limiter`, el gateway se lo olvidó) es el incidente de producción más común en este espacio.
- **Secrets y reproducibilidad.** Los endpoints, tokens y material TLS no pueden hardcodearse en una imagen que enviás a cada nodo. La configuración debe *componerse al arrancar* a partir de un archivo base más sustitución de entorno más overlays — y debe validar antes de siquiera bindear un puerto.

El examen y este material tratan a "Configuration" como: **el schema del archivo, las seis clases de componentes, cómo las pipelines los cablean, cómo se entregan y mergean las configs, y cómo demostrás que una config es correcta antes y después de que corra.**

---

## 2. Anatomía de una configuración del Collector

Una config del Collector tiene exactamente **seis claves de nivel superior**. Cinco *declaran* componentes; la sexta (`service`) los *activa y cablea*.

| Clave de nivel superior | Rol | Activada por | Notas |
|---|---|---|---|
| `receivers` | Traer o aceptar telemetría hacia adentro | Referenciada en una pipeline | p. ej. `otlp`, `prometheus`, `filelog`, `kubeletstats` |
| `processors` | Transformar / batchear / descartar / proteger | Referenciada en una pipeline | **El orden es significativo** (ver §2.2) |
| `exporters` | Emitir telemetría hacia afuera | Referenciada en una pipeline | p. ej. `otlp`, `otlphttp`, `debug`, `prometheusremotewrite` |
| `connectors` | Actuar como **exporter de una pipeline y receiver de otra** | Referenciada en ambos extremos | p. ej. `spanmetrics`, `forward`, `count`, `routing` |
| `extensions` | Capacidades transversales, **fuera de toda pipeline** | Listada en `service::extensions` | p. ej. `health_check`, `pprof`, `zpages`, auth |
| `service` | Convierte las declaraciones en un grafo en ejecución | — | Contiene `extensions`, `pipelines`, `telemetry` |

### 2.1 La regla más importante de la config del Collector

> **Declarar un componente no hace nada. Un componente solo corre si está referenciado bajo `service`.** Un receiver no nombrado en una pipeline nunca bindea un puerto. Un exporter no nombrado en una pipeline nunca abre una conexión. Una extension no listada en `service::extensions` es config muerta e inerte.

Esta es la causa #1 de los tickets "mi config está bien pero no pasa nada". La validación *pasa* sobre componentes sin usar — son legales, solo que están ociosos.

### 2.2 Identidad del componente: `type` y `type/name`

Cada instancia de componente se identifica por su **type**, opcionalmente con el sufijo `/name` para crear múltiples instancias del mismo type:

```yaml
exporters:
  otlp:                 # instance id = "otlp"
    endpoint: tempo:4317
  otlp/metrics:         # instance id = "otlp/metrics" — a DIFFERENT instance
    endpoint: mimir:4317
```

`otlp` y `otlp/metrics` son dos exporters independientes. Las pipelines los referencian por su id completo.

### 2.3 Pipelines: el cableado, y por qué el orden de los processors importa

Una pipeline tiene un **tipo de señal** (`traces`, `metrics` o `logs`, opcionalmente `/name`) y tres etapas ordenadas:

```yaml
service:
  pipelines:
    traces:
      receivers:  [otlp]                 # SET — order irrelevant, fan-in
      processors: [memory_limiter, batch] # LIST — order is the data flow order
      exporters:  [otlp, debug]           # SET — order irrelevant, fan-out
```

- **Los receivers y exporters son conjuntos (sets)**: múltiples receivers hacen fan-in, múltiples exporters hacen fan-out; el orden no tiene significado.
- **Los processors son una lista ordenada**: la telemetría fluye de izquierda a derecha, cada processor ve la salida del anterior. La regla de ordenamiento canónica:

| Posición | Processor | Por qué va ahí |
|---|---|---|
| **Primero** | `memory_limiter` | Debe rechazar/aplicar back-pressure *antes* de que se haga cualquier trabajo costoso, para proteger toda la cadena |
| Temprano | `k8sattributes`, `resourcedetection` | Enriquecer antes de samplear/filtrar sobre esos atributos |
| Medio | `filter`, `transform`, `attributes`, tail sampling | La lógica de negocio opera sobre datos enriquecidos |
| **Último (antes de los exporters)** | `batch` | Batchear *después* de todos los descartes, para que nunca batchees datos que estás por descartar |

Poner `batch` antes de `memory_limiter` anula la autoprotección; poner `memory_limiter` al final significa que la pipeline ya asignó los buffers que estabas tratando de acotar.

### 2.4 Un connector es un exporter *y* un receiver

Los connectors unen dos pipelines. `spanmetrics`, por ejemplo, consume spans y produce metrics:

```yaml
connectors:
  spanmetrics: {}

service:
  pipelines:
    traces:
      receivers:  [otlp]
      exporters:  [spanmetrics, otlp]   # spanmetrics acts as an EXPORTER here
    metrics/spanmetrics:
      receivers:  [spanmetrics]         # ...and as a RECEIVER here
      exporters:  [prometheusremotewrite]
```

El mismo instance id aparece una vez como exporter y una vez como receiver. Eso es lo que lo convierte en un connector en lugar de un processor.

---

## 3. Entrega y composición de la configuración

La config se carga a través de **confmap providers**, direccionados por un esquema de URI. `--config` puede darse múltiples veces; los maps se **deep-mergean de izquierda a derecha, gana el último**.

| Esquema de provider | Fuente | Uso típico | Compromiso |
|---|---|---|---|
| `file:` (por defecto) | Archivo local | Config base en imagen/ConfigMap | Inmutable por pod; necesita restart al cambiar |
| `env:` | Variable de entorno que contiene **YAML completo** | Inyectar config completa desde un secret | Doc completo en una var; difícil de diffear |
| `yaml:` | Literal YAML inline en la CLI | Overrides chicos, tests | Excelente para `validate`; poco práctico para prod |
| `http:` / `https:` | URL remota | Servicio centralizado de config | Agrega una dependencia de red al arranque (fail-fast) |
| `s3:`, `gcs:`, etc. (contrib) | Object storage | Distribución de config a la flota | Requiere credenciales de cloud en el boot |

Dentro de cualquier YAML cargado, la **sustitución de valores** usa el provider `env` inline:

```yaml
exporters:
  otlp:
    endpoint: ${env:BACKEND_ENDPOINT}          # required — fails if unset
    headers:
      authorization: "Bearer ${env:OTLP_TOKEN}"
  otlphttp:
    endpoint: ${env:OTLP_HTTP_ENDPOINT:-http://localhost:4318}  # default if unset
```

- `${env:VAR}` — sustituye; **error duro en el arranque si `VAR` no está seteada** (una característica de seguridad, no un bug).
- `${env:VAR:-default}` — usa `default` cuando `VAR` está vacía/sin setear.
- `$$` — un `$` literal (escape), necesario por ejemplo para los grupos de captura `$1` del relabel de Prometheus, que deben escribirse `$$1`.

### 3.1 Semántica del merge que tenés que conocer

Dados base + overlay:

```yaml
# base.yaml
exporters:
  otlp:
    endpoint: tempo:4317
    tls:
      insecure: true
```
```yaml
# overlay-prod.yaml
exporters:
  otlp:
    tls:
      insecure: false
      ca_file: /etc/otel/ca.pem
```

`otelcol --config base.yaml --config overlay-prod.yaml` da `endpoint: tempo:4317` (conservado) con `tls: {insecure: false, ca_file: /etc/otel/ca.pem}`. **Los maps se mergean clave por clave; los escalares y las listas se *reemplazan por completo*, no se agregan.** Este último punto atrapa a todos: un overlay `processors: [batch]` **no** se agrega a la lista `processors` de la base — la reemplaza por completo.

---

## 4. Manifests completos, de grado productivo

### 4.1 Una config completa de Collector gateway (sin recortar nada)

```yaml
# otelcol-gateway.yaml — central gateway: OTLP in, fan-out to traces+metrics backends
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317        # gateway must listen on all interfaces
        max_recv_msg_size_mib: 16
      http:
        endpoint: 0.0.0.0:4318

processors:
  # 1) SELF-PROTECTION FIRST — bounds heap before any allocation-heavy work
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80              # soft-limit at 80% of the cgroup limit
    spike_limit_percentage: 25        # hard drop headroom for bursts

  # 2) Enrichment / normalization
  resourcedetection:
    detectors: [env, system]
    timeout: 5s
    override: false

  # 3) BATCH LAST — never batch data you might still drop
  batch:
    timeout: 5s
    send_batch_size: 8192
    send_batch_max_size: 16384

exporters:
  otlp/traces:
    endpoint: ${env:TEMPO_ENDPOINT}
    tls:
      insecure: false
      ca_file: /etc/otel/certs/ca.pem
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

  prometheusremotewrite:
    endpoint: ${env:MIMIR_ENDPOINT}
    headers:
      X-Scope-OrgID: ${env:TENANT_ID}
    resource_to_telemetry_conversion:
      enabled: true

  debug:
    verbosity: normal                 # replaces the removed "logging" exporter

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: 0.0.0.0:1777
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, pprof, zpages]   # extensions are ONLY active if listed here
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters:  [otlp/traces, debug]
    metrics:
      receivers:  [otlp]
      processors: [memory_limiter, batch]
      exporters:  [prometheusremotewrite]
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
                port: 8888          # internal self-metrics scrape target
```

### 4.2 Kubernetes: ConfigMap + Deployment (gateway), secrets vía env

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otelcol-gateway
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch:
        timeout: 5s
        send_batch_size: 8192
    exporters:
      otlp/traces:
        endpoint: ${env:TEMPO_ENDPOINT}
        tls: { insecure: false, ca_file: /etc/otel/certs/ca.pem }
    extensions:
      health_check: { endpoint: 0.0.0.0:13133 }
    service:
      extensions: [health_check]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/traces]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otelcol-gateway
  namespace: observability
spec:
  replicas: 3
  selector: { matchLabels: { app: otelcol-gateway } }
  template:
    metadata:
      labels: { app: otelcol-gateway }
    spec:
      containers:
        - name: otelcol
          image: otel/opentelemetry-collector-contrib:0.116.0
          args: ["--config=/etc/otel/config.yaml"]
          env:
            - name: TEMPO_ENDPOINT
              value: "tempo.observability.svc:4317"
            - name: GOMEMLIMIT              # let Go GC cooperate with memory_limiter
              value: "1600MiB"
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { cpu: "2",    memory: "2Gi" }   # memory_limiter reads THIS via percentage
          ports:
            - { containerPort: 4317, name: otlp-grpc }
            - { containerPort: 4318, name: otlp-http }
            - { containerPort: 13133, name: health }
          livenessProbe:
            httpGet: { path: /, port: 13133 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /, port: 13133 }
          volumeMounts:
            - { name: cfg, mountPath: /etc/otel }
      volumes:
        - name: cfg
          configMap: { name: otelcol-gateway }
```

> **Nota de producción:** `limit_percentage` es un porcentaje del **límite de memoria del cgroup** que el Collector lee en runtime — seteá `resources.limits.memory` y `GOMEMLIMIT` deliberadamente, o el porcentaje se computa contra el número equivocado.

### 4.3 La forma del Operator: el CRD `OpenTelemetryCollector` (config tipada)

Cuando el [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator) está instalado, declarás la *misma* config dentro de un CRD `v1beta1` y el Operator renderiza el Deployment/DaemonSet, Service, ConfigMap y RBAC por vos:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: gateway
  namespace: observability
spec:
  mode: deployment          # deployment | daemonset | statefulset | sidecar
  replicas: 3
  image: otel/opentelemetry-collector-contrib:0.116.0
  resources:
    limits: { cpu: "2", memory: 2Gi }
  config:                   # structured, schema-validated by the Operator's webhook
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 80
        spike_limit_percentage: 25
      batch: {}
    exporters:
      debug: { verbosity: basic }
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
```

`mode: daemonset` reutiliza el schema idéntico para producir el **agent** por nodo; `mode: sidecar` inyecta un contenedor Collector en los pods anotados. Un schema, cuatro topologías — la config *es* el deployment.

---

## 5. Comandos de CLI y salida esperada en terminal

### 5.1 Validá antes de siquiera bindear un puerto — `validate` es gratis y offline

```console
$ otelcol-contrib validate --config=otelcol-gateway.yaml
$ echo $?
0
```

Silencio + exit `0` = la config parseó, cada componente referenciado existe, y la config propia de cada componente se deserializó. Una config malformada falla ruidosamente y **nunca arranca un listener**:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: service::pipelines::traces: references exporter "otlp/traces" which is not configured
$ echo $?
1
```

```console
$ otelcol-contrib validate --config=broken2.yaml
Error: invalid configuration: exporters::otlp/traces: endpoint must be specified
```

```console
$ otelcol-contrib validate --config=broken3.yaml
Error: failed to get config: cannot resolve the configuration: environment variable "TEMPO_ENDPOINT" is not set
```

Ese último es el punto de `${env:...}` sin default — un secret faltante es un **fallo de arranque**, no un Collector que descarta silenciosamente tus datos.

### 5.2 Descubrí qué contiene realmente un build — `components`

Qué receivers/processors/exporters existen depende de la distribución (`otelcol` core vs `otelcol-contrib` vs un build custom de OCB). Nunca adivines; preguntale al binario:

```console
$ otelcol-contrib components | head -n 20
buildinfo:
    command: otelcol-contrib
    description: OpenTelemetry Collector Contrib
    version: 0.116.0
receivers:
    - name: otlp
      stability:
        logs: beta
        metrics: stable
        traces: stable
    - name: filelog
    - name: kubeletstats
    - name: prometheus
processors:
    - name: batch
    - name: memory_limiter
    - name: k8sattributes
    - name: transform
exporters:
    - name: otlp
    - name: debug
    - name: prometheusremotewrite
```

Si `components` no lista `spanmetrics`, ninguna config lo va a hacer funcionar — necesitás un build distinto.

### 5.3 Ejecutá con config en capas y observá el merge

```console
$ otelcol-contrib --config=base.yaml \
    --config=overlay-prod.yaml \
    --config='yaml:service::telemetry::logs::level: debug'
2026-08-10T14:22:01.114Z  info  service@v0.116.0/service.go:164  Setting up own telemetry...
2026-08-10T14:22:01.116Z  info  memorylimiter/memorylimiter.go  Using percentage memory limiter  {"total_memory_mib": 2048, "limit_percentage": 80, "spike_limit_percentage": 25}
2026-08-10T14:22:01.121Z  info  service@v0.116.0/service.go  Starting otelcol-contrib...  {"Version": "0.116.0", "NumCPU": 4}
2026-08-10T14:22:01.122Z  info  extensions/extensions.go  Extension is starting...  {"kind": "extension", "name": "health_check"}
2026-08-10T14:22:01.123Z  info  otlpreceiver@v0.116.0  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2026-08-10T14:22:01.123Z  info  otlpreceiver@v0.116.0  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
2026-08-10T14:22:01.124Z  info  service@v0.116.0/service.go  Everything is ready. Begin running and processing data.
```

Los tres flags `--config` se deep-mergean; el override inline `yaml:` gana y cambia el log level a `debug`.

### 5.4 Alterná comportamiento con feature gates

```console
$ otelcol-contrib --config=otelcol-gateway.yaml \
    --feature-gates=+component.UseLocalHostAsDefaultHost,-some.other.gate
```

`+gate` habilita, `-gate` deshabilita. Los feature gates son cómo el proyecto va desplegando defaults rompedores (p. ej. hacer que los endpoints del OTLP receiver apunten por defecto a `localhost` en lugar de `0.0.0.0`) — leé la línea de log en el arranque que reporta qué gates están activos.

---

## 6. Verificación y diagnóstico de fallos

Verificás un Collector a tres altitudes: **config-time** (offline), **arranque** (¿bindea y reporta ready?) y **runtime** (¿fluyen los datos de verdad y está sano consigo mismo?).

### 6.1 Las superficies de diagnóstico que configurás a propósito

| Extension / superficie | Endpoint por defecto | Qué responde |
|---|---|---|
| `health_check` | `:13133/` | ¿Está el Collector arriba y sus pipelines iniciadas? (target de probe) |
| **Internal metrics** (`service::telemetry::metrics`) | `:8888/metrics` | Conteos de accepted vs refused vs dropped, tamaño de cola, fallos de exporter |
| `zpages` | `:55679/debug/pipelinez` | Vista en vivo por pipeline de processor/exporter, spans en vuelo |
| `pprof` | `:1777/debug/pprof/` | Profiles de CPU/heap cuando el propio Collector es el cuello de botella |

### 6.2 Leé la telemetría interna — acá es donde encontrás pérdida de datos

Las self-metrics en `:8888` son la caja negra. Las series clave:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver|processor|exporter)_' | head
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 148213
otelcol_receiver_refused_spans{receiver="otlp",transport="grpc"} 0
otelcol_processor_dropped_spans{processor="memory_limiter"} 512
otelcol_exporter_sent_spans{exporter="otlp/traces"} 147701
otelcol_exporter_send_failed_spans{exporter="otlp/traces"} 0
otelcol_exporter_queue_size{exporter="otlp/traces"} 128
otelcol_exporter_queue_capacity{exporter="otlp/traces"} 5000
```

Leyéndolo:
- `receiver_refused_*` > 0 → estás rechazando en la ingesta (auth, tamaño de mensaje, o el límite propio del receiver).
- `processor_dropped_spans{processor="memory_limiter"}` > 0 → **estás bajo presión de memoria y descartando carga**; subí los límites/replicas o agregá backpressure aguas arriba.
- `exporter_send_failed_*` subiendo → el backend es inalcanzable o rechaza; revisá `retry_on_failure` y el backend.
- `exporter_queue_size` acercándose a `exporter_queue_capacity` → el sink no da abasto; la cola es tu último buffer antes de los descartes.

### 6.3 Un playbook de diagnóstico de campo

**Síntoma: la config valida pero no llega telemetría al backend.**
1. `curl -s localhost:8888/metrics | grep receiver_accepted` — ¿el receiver siquiera está viendo datos? Si es `0`, el problema está aguas arriba (endpoint/TLS del cliente), no en el Collector.
2. Si accepted > 0 pero `exporter_sent` es `0`, la pipeline probablemente no referencia a ese exporter. Releé `service::pipelines` — **un exporter declarado pero no cableado nunca envía.**
3. Agregá el exporter `debug` a la pipeline temporalmente (`verbosity: detailed`) y observá los spans imprimirse por stdout — esto prueba que los datos llegaron a la etapa del exporter.

**Síntoma: el Collector es OOMKilled bajo carga.**
1. Confirmá que `memory_limiter` esté **primero** en la lista de processors de cada pipeline.
2. Confirmá que `resources.limits.memory` esté seteado y `GOMEMLIMIT` alineado (~80% del límite).
3. Observá `otelcol_processor_dropped_spans{processor="memory_limiter"}` — distinto de cero significa que está funcionando (descartando en lugar de crashear).

**Síntoma: `references exporter "X" which is not configured`.**
Una pipeline nombra un id de componente que no tiene declaración (typo, o el sufijo `/name` no coincide). Los ids son strings exactos: `otlp/traces` ≠ `otlp`.

**Síntoma: `environment variable "X" is not set`.**
Un `${env:X}` sin `:-default` y sin valor exportado. Corregí el env, o dale un default si es genuinamente opcional.

**Síntoma: config de relabel/regex rechazada o mangleada.**
Un `$` literal dentro de config embebida (Prometheus `$1`, expresiones de transform) fue consumido por la sustitución de confmap. Escapalo como `$$`.

### 6.4 Inspección en vivo de la pipeline con zpages

```console
$ curl -s localhost:55679/debug/pipelinez
Pipeline: traces
  Receivers:  otlp
  Processors: memory_limiter -> resourcedetection -> batch
  Exporters:  otlp/traces, debug
  Spans received (last minute): 148213
  Spans exported (last minute): 147701
```

`pipelinez` muestra el *grafo realmente ensamblado* que el proceso en ejecución construyó a partir de tu config mergeada — la respuesta definitiva a "¿está mi config cableada como creo que está?". Cuando el archivo y la realidad no coinciden, esta página es donde lo ves.

---

## 7. References

- OpenTelemetry Collector — Configuration: https://opentelemetry.io/docs/collector/configuration/
- Configuration providers & environment variable substitution: https://opentelemetry.io/docs/collector/configuration/#environment-variables
- Data collection & pipeline concepts: https://opentelemetry.io/docs/collector/architecture/
- Connectors: https://opentelemetry.io/docs/collector/building/connector/
- Internal telemetry (`service::telemetry`, self-metrics): https://opentelemetry.io/docs/collector/internal-telemetry/
- `memory_limiter` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- `batch` processor: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- OTLP receiver: https://github.com/open-telemetry/opentelemetry-collector/blob/main/receiver/otlpreceiver/README.md
- `debug` exporter: https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md
- Extensions (`health_check`, `pprof`, `zpages`): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension
- Feature gates: https://github.com/open-telemetry/opentelemetry-collector/blob/main/featuregate/README.md
- OpenTelemetry Operator — `OpenTelemetryCollector` CRD: https://github.com/open-telemetry/opentelemetry-operator
- OTCA certification & curriculum (CNCF/Linux Foundation): https://training.linuxfoundation.org/certification/opentelemetry-certified-associate-otca/
- OTCA curriculum repository: https://github.com/cncf/curriculum