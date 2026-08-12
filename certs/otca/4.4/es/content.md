# 4.4 Gestión de esquemas

> OTCA Dominio 4 — *Mantenimiento y depuración de pipelines de observabilidad*. Peso en el examen: 2.5.
> Alcance: **Telemetry Schemas** de OpenTelemetry, el campo `schema_url`, los archivos de esquema, la transformación guiada por esquema y las herramientas operativas (el `schemaprocessor` del Collector, Weaver) que permiten que una flota heterogénea converja en un único vocabulario.

---

## 1. El problema en producción: la deriva de las convenciones semánticas

Las convenciones semánticas son el vocabulario compartido que hace que la telemetría sea *portable*: `http.request.method`, `server.address`, `db.system.name`. Los backends, dashboards, reglas de alerta y consultas de SLO están codificados en duro contra estos nombres de atributos y métricas. El problema es que el vocabulario **evoluciona**, y lo hace más rápido de lo que podés redesplegar una flota.

Renombramientos reales y rompedores que se publicaron en las convenciones HTTP de OpenTelemetry:

| Nombre viejo (≤ semconv 1.20) | Nombre nuevo (semconv estable ≥ 1.23) |
|---|---|
| `http.method` | `http.request.method` |
| `http.status_code` | `http.response.status_code` |
| `net.peer.name` | `server.address` |
| `net.peer.port` | `server.port` |
| `http.url` | `url.full` |

Ahora imaginá el modo de falla a escala:

- El Equipo A actualiza su auto-instrumentación de Java y empieza a emitir `http.request.method`. El Equipo B sigue con el agente viejo emitiendo `http.method`.
- El dashboard central agrupa por `http.method`. El tráfico del Equipo A **desaparece** silenciosamente del panel — sin error, sin hueco, apenas un número más chico. Esto es peor que una ruptura dura: una alerta anclada en `http.status_code >= 500` deja de coincidir por completo con el Equipo A y se queda **muda** durante un incidente.
- No podés forzar una actualización sincronizada en toda la flota, y no podés reescribir cada dashboard para cada versión intermedia.

Necesitás dos cosas, y OpenTelemetry provee exactamente dos mecanismos:

1. **Autodescripción** — cada flujo de telemetría lleva un `schema_url` que declara *contra qué versión de convención fue producido*. La telemetría deja de ser ambigua.
2. **Un delta legible por máquina** — un **archivo de Telemetry Schema** que codifica los cambios entre versiones, de modo que un procesador pueda *transformar* automáticamente la telemetría de la versión del productor a la versión que espera el consumidor.

La gestión de esquemas es la disciplina de emitir (1) correctamente y operar (2) de forma confiable.

---

## 2. Anatomía de un Telemetry Schema

### 2.1 El Schema URL

Un **Schema URL** identifica de forma única una versión de esquema. Es un identificador opaco cuyo **último segmento de ruta es una versión semántica**:

```
https://opentelemetry.io/schemas/1.26.0
                                  ^^^^^^ version
https://opentelemetry.io/schemas/  ← "schema family" (everything but the version)
```

- Dos URLs pertenecen a la **misma schema family** si y solo si todo excepto el segmento final de versión es idéntico. La transformación solo está definida *dentro* de una familia.
- Por convención la URL **debería ser resoluble**: un `GET` HTTP devuelve el archivo de esquema para esa familia (la de OTel lo hace). Esto le permite a un Collector obtener deltas que nunca ha visto.

### 2.2 Dónde vive `schema_url` en el formato de cable (OTLP)

`schema_url` se adjunta en **dos granularidades**, a nivel de Resource y a nivel de InstrumentationScope. De `trace.proto`:

```proto
message ResourceSpans {
  Resource resource      = 1;
  repeated ScopeSpans scope_spans = 2;
  string schema_url      = 3;   // applies to resource.attributes
}
message ScopeSpans {
  InstrumentationScope scope = 1;
  repeated Span spans        = 2;
  string schema_url          = 3;   // applies to the scope's spans/attributes
}
```

La misma forma existe para `ResourceMetrics/ScopeMetrics` y `ResourceLogs/ScopeLogs`. La URL a nivel de scope es la que importa para los atributos de señal, porque una biblioteca de instrumentación declara la versión de semconv *contra la que ella* fue compilada — independiente de la versión del resource.

### 2.3 El archivo de esquema (formato de archivo 1.1.0)

Un único documento YAML describe una familia entera:

- `file_format` — versión del **formato de archivo en sí** (actualmente `1.1.0`), no de tu esquema.
- `schema_url` — la URL de la familia. Su versión **debe ser igual a la versión más alta listada** bajo `versions`.
- `versions` — un mapa `version → { section → changes }`. Los `changes` de una versión describen *qué ocurrió en esa versión* respecto de la anterior. Los mapas de atributos se escriben **old → new**.

Secciones y los tipos de cambio que acepta cada una:

| Sección | Tipos de cambio | Propósito |
|---|---|---|
| `all` | `rename_attributes` | Renombrar un atributo *en todos lados* (resource, spans, events, metric datapoints, logs) |
| `resources` | `rename_attributes` | Renombrar solo atributos de resource |
| `spans` | `rename_attributes` (opc. `apply_to_spans`) | Renombrar atributos de span, opcionalmente acotado a spans nombrados |
| `span_events` | `rename_events`, `rename_attributes` (opc. `apply_to_events`, `apply_to_spans`) | Renombrar events y sus atributos |
| `metrics` | `rename_metrics`, `rename_attributes` (opc. `apply_to_metrics`), `split` | Renombrar *streams* de métricas, sus atributos, o dividir una métrica en muchas |
| `logs` | `rename_attributes` | Renombrar atributos de log record |

**Dirección de la transformación.** Para mover telemetría de la versión `X` a un destino `Y > X`, aplicá los cambios de cada versión en `(X, Y]` en orden ascendente, usando cada `attribute_map` hacia adelante (old→new). Para mover *hacia atrás* (`Y → X`), aplicá los mismos cambios en orden descendente **invertidos**. Por esto los deltas deben ser renombramientos/divisiones sin pérdida, no lógica arbitraria.

---

## 3. Compensaciones

### 3.1 ¿Dónde realizás la transformación?

| Ubicación | Latencia hasta el vocabulario correcto | Radio de impacto en el rollback | Control de cardinalidad/costo | Flexibilidad multi-consumidor | Veredicto |
|---|---|---|---|---|---|
| **En el SDK / productor** (solo emitir nombres nuevos) | Inmediata, pero requiere redesplegar cada productor | Hay que redesplegar para deshacer | Ninguno (ya emitido) | Un vocabulario para todos los consumidores | Ideal *eventualmente*; imposible de coordinar en toda una flota a la vez |
| **En el Collector (`schemaprocessor`)** | Central, solo config, sin redesplegar la app | Cambiar config + reiniciar | Normaliza antes del fan-out → menos streams distintos aguas abajo | Una versión canónica por pipeline | **Punto de control recomendado** para flotas mixtas |
| **En el backend / al momento de la consulta** | Cero coordinación del productor | Solo editar las consultas | El almacenamiento sigue teniendo nombres mezclados (alta cardinalidad) | Por equipo, pero cada consulta debe conocer el mapeo | Frágil; la deriva vive para siempre en el almacenamiento |

El Collector es el punto natural de convergencia: los productores se quedan con la versión con la que salen, y el pipeline emite un único `schema_url` canónico al almacenamiento.

### 3.2 `schema_url` a nivel de Resource vs a nivel de Scope

| Aspecto | `schema_url` de Resource | `schema_url` de Scope |
|---|---|---|
| Describe | `resource.attributes` (p. ej. `service.*`, `k8s.*`) | Los atributos de señal de la biblioteca de instrumentación |
| Fijado por | La construcción del `Resource` de tu app | La biblioteca, vía la creación de su tracer/meter |
| Rotación típica | Baja (las convenciones de resource son estables) | Alta (una lib puede diferir de otra en el mismo proceso) |
| Peligro en el merge | `Resource.Merge` entra en conflicto si las URLs difieren | N/A — cada scope es independiente |

**Insight clave:** un único proceso legítimamente emite **múltiples** URLs de esquema de scope (distintas bibliotecas, distintas versiones). Nunca asumas una URL por proceso.

---

## 4. Manifiestos completos

### 4.1 Un archivo de esquema de producción (familia `https://myco.example.com/schemas`)

```yaml
# https://myco.example.com/schemas/1.3.0  (served verbatim at this URL)
file_format: 1.1.0
schema_url: https://myco.example.com/schemas/1.3.0

versions:
  # -------- 1.3.0: the HTTP rename lands + a paging-metric split --------
  1.3.0:
    all:
      changes:
        # Applies to resources, spans, events, metric datapoints, and logs.
        - rename_attributes:
            attribute_map:
              net.peer.name: server.address
              net.peer.port: server.port

    spans:
      changes:
        - rename_attributes:
            attribute_map:
              http.method: http.request.method
              http.status_code: http.response.status_code
              http.url: url.full
            # Optional: restrict the rename to specific span names.
            # apply_to_spans:
            #   - "HTTP GET"
            #   - "HTTP POST"

    span_events:
      changes:
        - rename_events:
            name_map:
              exception.stacktrace: exception
        - rename_attributes:
            attribute_map:
              message.uncompressed_size: message.uncompressed.size

    metrics:
      changes:
        - rename_metrics:
            http.server.duration: http.server.request.duration
        - rename_attributes:
            apply_to_metrics:
              - http.server.request.duration
            attribute_map:
              http.method: http.request.method
        - split:
            # Split one bidirectional metric into two directional metrics.
            apply_to_metric: system.paging.operations
            by_attribute: direction         # this attribute is REMOVED from outputs
            metrics_from_attributes:
              system.paging.operations.in: in
              system.paging.operations.out: out

    logs:
      changes:
        - rename_attributes:
            attribute_map:
              log.severity: severity.text

  # -------- 1.2.0: earlier delta, kept for backward transforms --------
  1.2.0:
    resources:
      changes:
        - rename_attributes:
            attribute_map:
              service.instance: service.instance.id

  # -------- 1.1.0: family baseline (no changes recorded) --------
  1.1.0:
```

### 4.2 Pipeline del Collector con el `schemaprocessor`

> Estabilidad: el `schemaprocessor` está en **development/alpha** en `opentelemetry-collector-contrib`. Fijá tu versión del Collector y probá las transformaciones antes de depender de ellas en una ruta de alertas.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Converts any incoming telemetry whose schema_url is in a known family
  # to the target version of that family. Streams already at target are no-ops.
  schema:
    # Warm the cache at startup so the first request isn't blocked on a fetch.
    prefetch:
      - https://myco.example.com/schemas/1.3.0
      - https://opentelemetry.io/schemas/1.26.0
    # One target per family. Everything in that family is normalized to this version.
    targets:
      - https://myco.example.com/schemas/1.3.0
      - https://opentelemetry.io/schemas/1.26.0

  batch:
    send_batch_size: 8192
    timeout: 5s

exporters:
  debug:
    verbosity: detailed          # prints Resource/Scope SchemaURL — see §6
  otlp/backend:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [schema, batch]   # schema BEFORE batch/export
      exporters:  [debug, otlp/backend]
    metrics:
      receivers:  [otlp]
      processors: [schema, batch]
      exporters:  [otlp/backend]
  telemetry:
    logs:
      level: info
```

### 4.3 Emitir `schema_url` desde el SDK (Go)

```go
import (
    "go.opentelemetry.io/otel/sdk/resource"
    "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0" // package pins the version
)

// Resource carries the RESOURCE-level schema_url.
res, err := resource.New(ctx,
    resource.WithSchemaURL(semconv.SchemaURL), // "https://opentelemetry.io/schemas/1.26.0"
    resource.WithAttributes(
        semconv.ServiceName("checkout"),
        semconv.ServiceVersion("2.4.1"),
    ),
)
if err != nil {
    log.Fatalf("resource: %v", err) // includes ErrSchemaURLConflict on merge collisions
}

tp := trace.NewTracerProvider(trace.WithResource(res) /* + exporter */)

// Tracer carries the SCOPE-level schema_url — independent of the resource's.
tracer := tp.Tracer(
    "github.com/myco/checkout",
    trace.WithInstrumentationVersion("2.4.1"),
    trace.WithSchemaURL(semconv.SchemaURL),
)
```

Equivalente en Python para el resource:

```python
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.semconv import SCHEMA_URL   # e.g. https://opentelemetry.io/schemas/1.26.0

resource = Resource.create(
    attributes={ResourceAttributes.SERVICE_NAME: "checkout"},
    schema_url=SCHEMA_URL,
)
```

---

## 5. Comandos de CLI y salida real de terminal

**Obtener e inspeccionar un archivo de esquema en vivo** (prueba que la URL es resoluble):

```console
$ curl -sS https://opentelemetry.io/schemas/1.26.0 | head -n 6
file_format: 1.1.0
schema_url: https://opentelemetry.io/schemas/1.26.0
versions:
  1.26.0:
  1.25.0:
    spans:

$ curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://opentelemetry.io/schemas/1.26.0
200 text/yaml
```

**Generar spans con un `schema_url` conocido y ver cómo el Collector los transforma.** `telemetrygen` estampa el `schema_url` de OTLP en su salida:

```console
$ telemetrygen traces \
    --otlp-endpoint localhost:4317 --otlp-insecure \
    --otlp-attributes 'http.method="GET"' \
    --traces 1
2026-08-11T14:02:11.874Z  info  traces/worker.go:110  traces generated  {"worker": 0, "traces": 1}
```

**Exportador `debug` del Collector — el `schema_url` se imprime en ambos niveles** (esta es tu verdad de base sobre el cable):

```console
$ docker logs otel-collector 2>&1 | sed -n '/ResourceSpans #0/,/Attributes:/p'
ResourceSpans #0
Resource SchemaURL: https://opentelemetry.io/schemas/1.26.0
Resource attributes:
     -> service.name: Str(telemetrygen)
ScopeSpans #0
ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.26.0
InstrumentationScope telemetrygen
Span #0
    Trace ID       : 5b8aa5a2d2c872e8321cf37308d69df9
    Name           : okey-dokey-0
    Attributes:
         -> http.request.method: Str(GET)   # <-- was http.method on the wire; schemaprocessor renamed it
```

**Comparar dos versiones del registro de convenciones semánticas con Weaver** (la fuente de verdad desde la que se autoran los deltas de esquema):

```console
$ weaver registry diff \
    --registry https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.26.0.zip \
    --baseline-registry https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.23.0.zip \
    --diff-format markdown
Resolved registry (baseline): 1.23.0
Resolved registry (current):  1.26.0
Attributes renamed:
  - http.method            -> http.request.method
  - http.status_code       -> http.response.status_code
  - net.peer.name          -> server.address
Metrics renamed:
  - http.server.duration   -> http.server.request.duration
Diff written to: registry_diff.md
```

**Validar un registro / detectar violaciones de política rompedoras antes de publicar:**

```console
$ weaver registry check --registry ./semconv-registry
✔ Registry `./semconv-registry` loaded (312 attributes, 41 metrics)
✔ No parsing errors
✔ Policy checks passed (0 violations)
```

---

## 6. Verificación y diagnóstico de fallas

| Síntoma | Causa probable | Diagnóstico | Solución |
|---|---|---|---|
| El `schemaprocessor` es un **no-op**; los nombres nunca cambian | El productor emite `schema_url` **vacío** | El exportador `debug` muestra `Resource SchemaURL:` en blanco | Fijá `WithSchemaURL(semconv.SchemaURL)` en el SDK — la transformación es indefinida sin una versión de origen |
| Solo *algunos* atributos renombrados | El renombramiento se declaró bajo `spans`/`metrics` pero necesitabas `all` (o viceversa) | Leé en qué sección está el cambio; revisá los filtros `apply_to_*` | Mové el cambio a la sección correcta o ampliá `apply_to_*` |
| El Collector registra `schema version X not in family` / sin transformación | La familia del `schema_url` del productor ≠ cualquier familia de `targets` | Compará el prefijo de la URL (todo menos la versión) con `targets` | Agregá la familia correcta a `targets`; las familias nunca se transforman entre sí |
| El arranque se cuelga / las primeras solicitudes hacen timeout | Descarga del esquema en la ruta caliente; registro inalcanzable | Salida de red desde el Collector; falta `prefetch` | Agregá `prefetch:`; corré un espejo interno de las URLs de esquema para clusters air-gapped |
| El Collector se niega a cargar el archivo de esquema | `file_format` ≠ versión soportada, o versión de `schema_url` ≠ la clave más alta de `versions` | `weaver` / parseá el YAML; revisá los dos invariantes | Fijá `file_format: 1.1.0`; hacé que la versión de `schema_url` sea igual a la versión máxima listada |
| Go: `resource.New` devuelve error, el resource resultante tiene schema URL **vacío** | `Resource.Merge` de dos resources con schema URLs **distintos y no vacíos** → `ErrSchemaURLConflict` | El log muestra el conflicto; el schema URL fusionado se descarta | Alineá ambos resources a un único `schema_url`, o fusioná solo resources de la misma versión |
| Una métrica `split` pierde datos / cuenta doble | El valor de `by_attribute` tiene casos no cubiertos en `metrics_from_attributes` | Compará los valores distintos del atributo vs. las claves del mapa | Cubrí cada valor; el split **descarta** la dimensión `by_attribute` de las salidas |

**Bucle de verificación de oro:**

1. `curl` a cada URL de esquema de la que dependés → esperá `200` + YAML válido (`file_format`, `schema_url`, `versions`).
2. Emití una señal con un nombre de atributo viejo *conocido* vía `telemetrygen`.
3. Leé la salida `debug` del Collector → confirmá que el nombre del atributo es el nombre de la versión **destino** y que ambas líneas `SchemaURL` son iguales a tu destino.
4. Afirmá en el backend que el nombre canónico es el *único* presente (sin vocabulario de cerebro dividido).

---

## Referencias

- Telemetry Schemas — specification: https://opentelemetry.io/docs/specs/otel/schemas/
- Schema file format v1.1.0: https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/
- Published OpenTelemetry schema files: https://opentelemetry.io/schemas/
- OTLP trace proto (`schema_url` fields): https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/trace/v1/trace.proto
- Collector `schemaprocessor`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor
- Semantic Conventions (versioning & schema URLs): https://opentelemetry.io/docs/specs/semconv/
- Semantic Conventions repository & CHANGELOG: https://github.com/open-telemetry/semantic-conventions
- OpenTelemetry Weaver (registry resolve / diff / check): https://github.com/open-telemetry/weaver
- Go SDK `resource` (schema URL & merge conflict): https://pkg.go.dev/go.opentelemetry.io/otel/sdk/resource
- `telemetrygen` utility: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- OTCA curriculum: https://github.com/cncf/curriculum