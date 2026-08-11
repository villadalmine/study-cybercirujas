# 3.5 Transformando Datos

> **Dominio 3 — El OpenTelemetry Collector.** Este tema cubre cómo la telemetría se remodela *dentro del pipeline*, después de recibirse y antes de exportarse: manipulación de atributos, normalización, redacción, enriquecimiento, agregación y reescritura estructural. Los instrumentos son los processors de transformación del Collector — `transform` (OTTL), `attributes`, `resource`, `metricstransform`, `redaction`, `groupbyattrs` — y su lenguaje rector, **OTTL**.

---

## 1. El problema de producción: la telemetría nunca tiene la forma que necesitás

Un SRE hereda telemetría de tres fuentes poco cooperativas a la vez:

1. **Instrumentación que no controlás.** Bibliotecas de terceros, sidecars, exporters heredados y agentes de nube emiten cada uno sus propias claves de atributos (`http.status`, `http_status_code`, `status`), su propia identidad de resource y sus propias codificaciones de severidad. Los backends necesitan *un* esquema.
2. **Datos demasiado caros para almacenar tal cual.** Los atributos de trace que cargan URLs completas hacen explotar la cardinalidad de métricas cuando luego se vuelven dimensiones; un atributo `user.id` en un span multiplica el costo de índice; un `http.url` con query strings es ilimitado. El costo es función de la *forma*, y la forma se fija en el Collector.
3. **Datos inseguros o no conformes para reenviar.** Números de tarjeta de crédito en cuerpos de log, bearer tokens en `http.request.header.authorization`, PII en atributos de span. Estos nunca deben llegar al vendor, y la redacción debe ocurrir *antes* de la cola de exportación, en infraestructura que poseés.

La idea arquitectónica que OTCA evalúa: **el Collector es el único lugar en el plano de observabilidad donde podés normalizar, reducir y sanear telemetría de todas las fuentes de manera uniforme, sin tocar el código de la aplicación ni la configuración del backend.** La transformación en el Collector es un punto de control — un único deployment gobierna el esquema, el costo y el cumplimiento para cada servicio detrás de él.

### El contrato del pipeline

La transformación ocurre en la etapa `processors` de un pipeline. El orden es explícito y significativo:

```
receivers → [ processor_1 → processor_2 → … → processor_n ] → exporters
```

Los processors corren **en el orden exacto listado en el array `processors:` del pipeline**, no en el orden en que se definen en el bloque `processors:` de nivel superior. Un `transform` que reescribe `http.route` antes de un `filter` que descarta rutas `/health` se comporta distinto si los intercambiás. Este ordenamiento es la fuente más común de incidentes del tipo "mi config es correcta pero los datos están mal".

---

## 2. La caja de herramientas de transformación — análisis comparativo

Hay dos familias. Los **processors basados en acciones** (`attributes`, `resource`, `metricstransform`) toman una lista declarativa de operaciones tipadas. Los **processors OTTL** (`transform`, `filter`) toman sentencias escritas en el OpenTelemetry Transformation Language — un lenguaje de expresiones pequeño y tipado que es estrictamente más poderoso pero tiene un costo real de CPU por sentencia.

| Processor | Signal(s) | Modelo | Fortaleza | Debilidad | Cuándo recurrir a él |
|---|---|---|---|---|---|
| `attributes` | traces, logs, metrics (datapoint attrs) | Lista de acciones (`insert/update/upsert/delete/hash/extract/convert/from_attribute`) | Rápido, declarativo, `extract` con regex | Solo toca atributos, sin lógica cross-signal | Rename/hash/delete simple de claves en atributos |
| `resource` | all | Lista de acciones (mismas acciones, sobre Resource) | Reescribe la identidad de resource uniformemente | Solo alcance de resource | Corregir `service.name`, descartar resource attrs ruidosos |
| `transform` | traces, logs, metrics | Sentencias **OTTL** | Lógica condicional, matemática, parsing, lecturas cross-scope, cualquier field | El mayor costo de CPU por registro; fácil escribir un regex lento | Cualquier cosa condicional, estructural o a nivel de field más allá de atributos |
| `filter` | traces, logs, metrics | Condiciones booleanas **OTTL** | Descarta registros enteros por predicado | Solo descarta (ver [Filtering Data]) | Eliminar `/health`, descartar logs de debug, recortar cardinalidad descartando |
| `metricstransform` | metrics | Lista de acciones (rename metric/label, aggregate) | Renombra métricas, agrega quitando labels | Solo métricas; siendo reemplazado por OTTL | Renombrar métricas, sumar-quitando una dimensión de label |
| `redaction` | traces, logs, metrics | Allow-list de claves + regexes de valores bloqueados | Enmascaramiento de grado compliance, modelo allow-list | Costo de regex en cada valor | Enmascaramiento de PII/secretos con postura allow-list |
| `groupbyattrs` | traces, logs, metrics | Reparticiona registros por conjunto de atributos | Mueve attrs de registro hacia resource; compacta el payload | Solo estructural, sin edición de valores | Normalizar dónde "pertenece" un atributo (registro vs resource) |

**Regla general evaluada por OTCA:** preferí la herramienta *más estrecha*. Si un rename lo puede hacer `attributes`, no recurras a `transform` — los processors basados en acciones son más baratos y su intención es autodocumentada. Escalá a OTTL solo cuando necesitás una condición, un valor computado, parsing o acceso a un field que no es un atributo (`status.code`, `severity_number`, `body`, `name`).

### Editors vs. Converters — la distinción de OTTL que debés internalizar

Las funciones de OTTL se dividen en dos categorías, y confundirlas es el error clásico del principiante:

- **Editors** mutan la telemetría en el lugar y **no retornan nada**. Son el *verbo* de una sentencia: `set`, `delete_key`, `keep_keys`, `limit`, `truncate_all`, `replace_pattern`, `merge_maps`. Un editor es una sentencia completa por sí mismo.
- **Converters** computan y **retornan un valor**. Nunca son una sentencia por sí solos — son argumentos *para* un editor: `SHA256(...)`, `Concat(...)`, `ParseJSON(...)`, `Int(...)`, `IsMatch(...)`, `Truncate...`, `UUID()`.

```
set(attributes["user.hash"], SHA256(attributes["user.id"]))
│    └─────────── target ──┘  └──────── Converter ───────┘
└─ Editor (the statement)
```

Los converters se capitalizan por convención; los editors son lower_snake_case. Una sentencia es: **`editor(args...) [where <boolean condition>]`**.

---

## 3. OTTL — el lenguaje, con precisión

### 3.1 Contexts

OTTL evalúa sentencias dentro de un **context** — el "nivel" de telemetría sobre el que opera la sentencia. El context determina qué paths son direccionables y cuántas veces corre una sentencia.

| Signal | Contexts (externo → interno) | Una sentencia en este context corre una vez por… |
|---|---|---|
| Traces | `resource` → `scope` → `span` → `spanevent` | resource / scope / **span** / span event |
| Metrics | `resource` → `scope` → `metric` → `datapoint` | resource / scope / metric / **datapoint** |
| Logs | `resource` → `scope` → `log` | resource / scope / **log record** |

Los contexts internos pueden **leer** los externos (`span` puede leer `resource.attributes["k8s.pod.name"]`) pero no al revés sin un context más grueso. Elegir el context más grueso que aún exponga el field que necesitás es una decisión de rendimiento: una sentencia en context `datapoint` corre una vez por datapoint (potencialmente miles por métrica), mientras que el mismo efecto en context `metric` corre una vez por métrica.

### 3.2 Paths (seleccionados, por context)

```
# span context
name, kind, trace_id, span_id, parent_span_id, trace_state,
start_time_unix_nano, end_time_unix_nano,
attributes["k"], dropped_attributes_count,
status.code, status.message, events, links,
resource.attributes["k"], instrumentation_scope.name

# log context
time_unix_nano, observed_time_unix_nano,
severity_number, severity_text, body,
attributes["k"], trace_id, span_id, flags

# datapoint context
metric.name, metric.type, metric.unit,
attributes["k"], time_unix_nano, start_time_unix_nano,
value_double, value_int, count, sum, exemplars, flags
```

### 3.3 Operadores y condiciones

`==` `!=` `<` `<=` `>` `>=`, booleanos `and` / `or` / `not`, aritmética `+ - * /`, indexado de map/slice `attributes["a"]["b"]`, `slice[0]`. La cláusula `where` habilita el editor; si la condición es falsa, el editor no corre para ese registro.

```
set(status.code, STATUS_CODE_ERROR) where attributes["http.response.status_code"] >= 500
```

---

## 4. Manifiesto de producción completo

Lo siguiente es una configuración completa y sintácticamente válida de `otelcol-contrib` para un gateway Collector que normaliza, enriquece, reduce cardinalidad y redacta secretos a través de las tres señales. Está sin recortar y es desplegable.

```yaml
# collector-gateway.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # 1) ALWAYS FIRST — sheds load before it reaches the heap-heavy processors.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25

  # 2) Enrich with k8s identity (from the downward API / API server).
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: app.version
          key: app.kubernetes.io/version
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip

  # 3) Detect cloud/host resource identity.
  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: [os]

  # 4) Action-based resource normalization (cheap, declarative).
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert
      - key: telemetry.sdk.language      # noisy, drop it
        action: delete

  # 5) Attribute-level normalization on records (traces/logs).
  attributes/normalize:
    actions:
      # Unify divergent status-code keys emitted by different libraries.
      - key: http.response.status_code
        from_attribute: http.status_code
        action: upsert
      - key: http.status_code
        action: delete
      # Hash a high-cardinality / PII dimension instead of storing it raw.
      - key: enduser.id
        action: hash

  # 6) OTTL — the conditional / structural work the action processors can't do.
  transform/shape:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          # Strip query strings so http.url is bounded.
          - replace_pattern(attributes["url.full"], "\\?.*$", "")
          # Derive a low-cardinality route bucket for metrics later.
          - set(attributes["http.route.class"], "5xx")
              where attributes["http.response.status_code"] >= 500
          - set(attributes["http.route.class"], "4xx")
              where attributes["http.response.status_code"] >= 400
              and attributes["http.response.status_code"] < 500
          # Mark server errors as span-level errors.
          - set(status.code, STATUS_CODE_ERROR)
              where attributes["http.response.status_code"] >= 500
          # Bound blast radius: cap and truncate attributes.
          - limit(attributes, 128, ["service.name", "http.route"])
          - truncate_all(attributes, 4096)
    log_statements:
      - context: log
        statements:
          # Promote a numeric level field into OTel severity.
          - set(severity_number, SEVERITY_NUMBER_ERROR)
              where IsMatch(body, "(?i)\\b(error|fatal|panic)\\b")
          # Parse a JSON body into structured attributes.
          - merge_maps(attributes, ParseJSON(body), "upsert")
              where IsMatch(body, "^\\s*\\{")
    metric_statements:
      - context: datapoint
        statements:
          # Copy a resource attr down so it survives metric aggregation.
          - set(attributes["k8s.namespace.name"],
                resource.attributes["k8s.namespace.name"])

  # 7) Compliance-grade redaction — allow-list posture, blocked patterns.
  redaction:
    allow_all_keys: false
    allowed_keys:
      - http.method
      - http.route
      - http.response.status_code
      - service.name
      - k8s.namespace.name
      - deployment.environment
    blocked_values:
      - "4[0-9]{12}(?:[0-9]{3})?"        # Visa PAN
      - "5[1-5][0-9]{14}"                # Mastercard PAN
      - "(?i)bearer\\s+[a-z0-9._\\-]+"    # bearer tokens
    summary: info

  # 8) ALWAYS NEAR LAST — batch for export efficiency.
  batch:
    send_batch_size: 8192
    send_batch_max_size: 10000
    timeout: 5s

exporters:
  otlphttp/backend:
    endpoint: https://otel-backend.internal:4318
    tls:
      insecure: false
  debug:
    verbosity: detailed
    sampling_initial: 5
    sampling_thereafter: 200

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, zpages]
  telemetry:
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
    logs:
      level: info
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resourcedetection,
                   resource, attributes/normalize, transform/shape,
                   redaction, batch]
      exporters: [otlphttp/backend]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resource,
                   transform/shape, redaction, batch]
      exporters: [otlphttp/backend]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, resource,
                   transform/shape, batch]
      exporters: [otlphttp/backend]
```

**La ley de ordenamiento demostrada arriba:** `memory_limiter` primero (proteger el proceso), enriquecimiento antes de la transformación (solo podés normalizar atributos que existen), `transform` antes de `redaction` (dar forma primero, luego sanear el resultado con forma), `batch` último (nunca hagas batch antes de haber descartado/reducido — desperdiciarías memoria haciendo batch de datos que estás por descartar, y `memory_limiter` debe ver la presión antes de que el batcher acapare).

### Fragmento de deployment de Kubernetes

Para que `k8sattributes` enriquezca, el ServiceAccount del Collector necesita acceso de lectura a pods:

```yaml
# rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "watch", "list"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: observability
```

---

## 5. Flujo de trabajo de CLI y salida real de terminal

### 5.1 Validar la config antes de desplegar

```console
$ otelcol-contrib validate --config=collector-gateway.yaml
$ echo $?
0
```

`validate` es silencioso en caso de éxito (exit 0) y ruidoso en caso de falla. Un converter mal ubicado usado como sentencia:

```console
$ otelcol-contrib validate --config=broken.yaml
Error: invalid configuration: processors::transform/shape: unable to parse OTTL
statement "SHA256(attributes[\"user.id\"])": editor names must start with a
lowercase letter but got "SHA256"
2026/08/11 14:03:11 collector server run finished with error: invalid configuration
$ echo $?
1
```

Ese error es OTTL diciéndote que se usó un **converter** donde se requiere un **editor** (una sentencia completa) — querías decir `set(attributes["user.id"], SHA256(attributes["user.id"]))`.

### 5.2 Conducir telemetría sintética a través del pipeline

```console
$ otelcol-contrib --config=collector-gateway.yaml &
2026-08-11T14:05:02.114Z  info  service@v0.112.0/service.go:135  Setting up own telemetry...
2026-08-11T14:05:02.121Z  info  service@v0.112.0/service.go:207  Starting otelcol-contrib...  {"Version": "0.112.0"}
2026-08-11T14:05:02.121Z  info  extensions/extensions.go:39  Starting extensions...
2026-08-11T14:05:02.122Z  info  otlpreceiver@v0.112.0/otlp.go:169  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
2026-08-11T14:05:02.122Z  info  service@v0.112.0/service.go:230  Everything is ready. Begin running and processing data.

$ telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 \
    --traces 1 --span-duration 250ms \
    --telemetry-attributes 'http.status_code="503"' \
    --telemetry-attributes 'enduser.id="alice@corp.io"'
2026-08-11T14:05:31.902Z  info  traces/traces.go:58  generation of traces isn't being throttled
2026-08-11T14:05:31.905Z  info  traces/worker.go:96  traces generated  {"worker": 0, "traces": 1}
2026-08-11T14:05:31.905Z  info  traces/traces.go:74  stop the batch span processor
```

### 5.3 Observar el resultado transformado vía el exporter `debug`

```console
2026-08-11T14:05:31.921Z  info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 1}
2026-08-11T14:05:31.921Z  info  ResourceSpans #0
Resource attributes:
     -> service.name: Str(telemetrygen)
     -> deployment.environment: Str(production)
     -> k8s.namespace.name: Str(observability)
ScopeSpans #0
Span #0
    Name           : okey-dokey-0
    Kind           : Server
    Status code    : Error
    Status message :
Attributes:
     -> http.response.status_code: Int(503)
     -> http.route.class: Str(5xx)
     -> enduser.id: Str(b94d27b9934d3e08a52e52d7da7dabfa...)
```

Confirmá que las transformaciones se aplicaron: `http.status_code` (503) se unificó en `http.response.status_code`; se derivó `http.route.class=5xx`; el `Status code` del span se cambió a `Error` por la sentencia OTTL `where >= 500`; se hizo upsert de `deployment.environment=production` sobre el resource; y `enduser.id` fue reemplazado por su hash SHA-256 — el email crudo nunca salió del Collector.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 `error_mode` — la perilla de seguridad más importante

Cada processor OTTL toma `error_mode`, que decide qué pasa cuando una sentencia falla en tiempo de ejecución (p. ej. `ParseJSON` sobre un body no-JSON, indexar una clave faltante):

| `error_mode` | Comportamiento ante error de sentencia | Usalo cuando |
|---|---|---|
| `propagate` | El batch entero se rechaza y se devuelve como error al componente anterior | Querés fallar rápido en staging; una sentencia mala debería paginarte |
| `ignore` | Registra el error, saltea **esa sentencia**, continúa el batch | Default de producción — un registro malformado no debe descartar el batch |
| `silent` | Saltea la sentencia, sin log | Rutas de alto volumen donde los errores esperados inundarían los logs |

La trampa de producción: `propagate` sobre un `transform` que parsea un `body` de forma libre descartará *batches enteros* en el momento en que una línea de log no sea JSON. Protegé los converters con un predicado `where IsMatch(...)` **y** corré `error_mode: ignore`.

### 6.2 Auto-observabilidad — probar que el processor está trabajando

El Collector exporta sus propias métricas en `:8888`. Scrapealas para verificar throughput y rechazos:

```console
$ curl -s localhost:8888/metrics | grep -E 'otelcol_processor|otelcol_receiver_accepted'
otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1
otelcol_processor_incoming_items{processor="transform/shape",otel_signal="traces"} 1
otelcol_processor_outgoing_items{processor="transform/shape",otel_signal="traces"} 1
otelcol_processor_incoming_items{processor="redaction",otel_signal="traces"} 1
otelcol_processor_outgoing_items{processor="redaction",otel_signal="traces"} 1
```

Para el `memory_limiter`, observá los rechazos — un valor distinto de cero significa que estás descartando carga y debés escalar horizontalmente o subir los límites:

```console
$ curl -s localhost:8888/metrics | grep refused
otelcol_processor_refused_spans{processor="memory_limiter"} 0
```

### 6.3 zPages — inspeccionar el pipeline en vivo

```console
$ curl -s localhost:55679/debug/pipelinez | head -20
Pipeline: traces
  Processors: memory_limiter, k8sattributes, resourcedetection,
              resource, attributes/normalize, transform/shape,
              redaction, batch
  MutatesData: true
```

`MutatesData: true` confirma que el pipeline contiene processors que mutan — el Collector debe por lo tanto darle a cada pipeline su propia copia de los datos (costo de fan-out). Por esto, enrutar el *mismo* receiver hacia dos pipelines que ambos transforman duplica la memoria.

### 6.4 Tabla de decisión de diagnóstico

| Síntoma | Causa probable | Verificación |
|---|---|---|
| El rename de atributo no ocurrió | Clave fuente ausente cuando corrió `attributes`; u orden de processors incorrecto | Agregá un exporter `debug` *antes* del transform; compará |
| Batches enteros desapareciendo | `error_mode: propagate` + un converter fallando sobre entrada malformada | Buscá con grep en los logs del Collector `failed to execute statement`; cambiá a `ignore` + guarda `where` |
| La sentencia OTTL nunca se dispara | Condición `where` falsa; desajuste de tipo (comparar `Int` vs `Str`) | Registrá el tipo de `attributes["k"]` con `debug`; envolvé con `Int(...)`/`String(...)` |
| CPU alta después de agregar transform | Regex caro (`replace_pattern`) o sentencia en context `datapoint` sobre una serie enorme | Chequeá `otelcol_process_cpu_seconds`; movete a context `metric`/`resource`; anclá los regexes |
| Valor redactado igual se filtra | `allow_all_keys: true`, o la clave está en allow-list pero el *valor* del patrón no está bloqueado | Poné `summary: info`; leé los atributos de resumen de redacción en los registros |
| `service.name` muestra `unknown_service` | `resource`/`resourcedetection` corrió después de la exportación, o el detector está deshabilitado | Confirmá que el processor está en el array `processors:` del pipeline, no solo declarado |
| Config válida pero datos sin cambios | Processor declarado bajo `processors:` pero omitido del array del pipeline | La zPage `pipelinez` lista la cadena activa *real* |

---

## 7. Guía de diseño (notas de Platform Architect)

- **Transformá en el gateway, no en el agente.** Los Collectors agente local-del-nodo deberían hacer trabajo mínimo (batch, memory_limiter) y reenviar; centralizá la normalización/redacción en un nivel de gateway escalado horizontalmente para que la política viva en un solo lugar. La redacción *debe* ser del lado del gateway para que la PII cruda nunca cruce la red hacia el vendor.
- **Preferí contexts gruesos.** Un `set` que podés hacer en context `resource` no debería vivir en context `datapoint` — el delta de CPU es multiplicativo en el conteo de series.
- **Recortá cardinalidad descartando el atributo, no solo hasheándolo.** El hashing preserva la cardinalidad (cada valor distinto → hash distinto); si el objetivo es el costo, `delete` o agrupá en una clase (`http.route.class`) en su lugar.
- **Protegé cada converter con un predicado.** `merge_maps(attributes, ParseJSON(body), "upsert") where IsMatch(body, "^\\s*\\{")` — nunca llames a un parser incondicionalmente sobre entrada de forma libre.
- **`metricstransform` es legacy para renames/agregación; el trabajo nuevo debería usar OTTL `transform`** por uniformidad, pero la agregación de labels de `metricstransform` (`combine`/`sum` a través de un label descartado) todavía no tiene un equivalente OTTL limpio para agregación escalar — sabé que ambos existen.

---

## Referencias

- OpenTelemetry Collector — Transforming telemetry (Processors overview): https://opentelemetry.io/docs/collector/transforming-telemetry/
- OTTL — OpenTelemetry Transformation Language: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md
- OTTL Functions (editors & converters reference): https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md
- OTTL Contexts (span/log/metric/datapoint paths): https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/pkg/ottl/contexts
- Transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md
- Attributes processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/attributesprocessor/README.md
- Resource processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/resourceprocessor/README.md
- Filter processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/filterprocessor/README.md
- Redaction processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/redactionprocessor/README.md
- Metrics Transform processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/metricstransformprocessor/README.md
- Memory Limiter processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/memorylimiterprocessor/README.md
- k8sattributes processor: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md
- Collector internal telemetry / self-observability: https://opentelemetry.io/docs/collector/internal-telemetry/
- OTCA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf