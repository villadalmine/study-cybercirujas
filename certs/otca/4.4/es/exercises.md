# 4.4 Gestión de Schemas

Un *telemetry schema* es una descripción versionada y legible por máquina de un conjunto de semantic conventions más las transformaciones que llevan la telemetría de una versión a la siguiente. Cada Resource y cada InstrumentationScope puede anunciar una **Schema URL** (por ejemplo `https://opentelemetry.io/schemas/1.21.0`); los backends y el Collector usan esa URL para normalizar datos producidos contra distintas versiones de conventions en lugar de forzar a cada productor a actualizarse al mismo tiempo.

## Prerrequisitos

- Docker (para ejecutar `otel/opentelemetry-collector-contrib`), **con salida hacia `opentelemetry.io`** para el Ejercicio 4.
- Python 3.10+ y `pip` (Ejercicio 1). Opcionalmente Go 1.21+ (fragmentos de los Ejercicios 1 y 5).
- `curl` y un editor de texto.

```bash
python3 -m venv venv && source venv/bin/activate
pip install "opentelemetry-api==1.29.0" "opentelemetry-sdk==1.29.0"
```

> Fijá las versiones a las que provea tu entorno; la mecánica de abajo es estable a lo largo de las versiones recientes. El processor `schema` es un componente contrib **alpha / en desarrollo** — confirmá su nivel de estabilidad para tu versión del Collector.

---

## Ejercicio 1 — Emitir una Schema URL desde el SDK (Resource + Scope)

La schema URL se establece en *dos lugares independientes*: en el Resource (una vez por proceso) y en cada InstrumentationScope (una vez por tracer/meter/logger). Vas a establecer ambos y observarlos.

**Pasos**

1. Guardá esto como `emit.py`:

   ```python
   from opentelemetry import trace
   from opentelemetry.sdk.resources import Resource
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import (
       ConsoleSpanExporter,
       SimpleSpanProcessor,
   )

   SCHEMA = "https://opentelemetry.io/schemas/1.21.0"

   # (a) Resource-level schema URL — describes the entity producing telemetry.
   resource = Resource.create(
       {"service.name": "checkout"},
       schema_url=SCHEMA,
   )

   provider = TracerProvider(resource=resource)
   provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
   trace.set_tracer_provider(provider)

   # (b) Scope-level schema URL — describes the convention version THIS library follows.
   tracer = trace.get_tracer(
       "checkout.instrumentation",
       "1.0.0",
       schema_url=SCHEMA,
   )

   with tracer.start_as_current_span("checkout") as span:
       span.set_attribute("http.request.method", "POST")  # 1.21.0 name
   ```

2. Ejecutalo y leé el JSON emitido a la consola:

   ```bash
   python emit.py
   ```

   Salida esperada (abreviada) — fijate en el `schema_url` en el bloque `resource`:

   ```json
   {
       "name": "checkout",
       "kind": "SpanKind.INTERNAL",
       "attributes": { "http.request.method": "POST" },
       "resource": {
           "attributes": {
               "telemetry.sdk.language": "python",
               "telemetry.sdk.name": "opentelemetry",
               "telemetry.sdk.version": "1.29.0",
               "service.name": "checkout"
           },
           "schema_url": "https://opentelemetry.io/schemas/1.21.0"
       }
   }
   ```

3. (Equivalente en Go — forma idiomática usando la constante `semconv`, que *es* la schema URL para esa versión del paquete):

   ```go
   import (
       "go.opentelemetry.io/otel"
       "go.opentelemetry.io/otel/sdk/resource"
       "go.opentelemetry.io/otel/trace"
       semconv "go.opentelemetry.io/otel/semconv/v1.21.0"
   )

   res, _ := resource.New(ctx,
       resource.WithSchemaURL(semconv.SchemaURL),                 // resource-level
       resource.WithAttributes(semconv.ServiceNameKey.String("checkout")),
   )

   tracer := otel.Tracer(
       "checkout.instrumentation",
       trace.WithInstrumentationVersion("1.0.0"),
       trace.WithSchemaURL(semconv.SchemaURL),                    // scope-level
   )
   ```

**Comprensión**

- **Q1.** La schema URL aparece en dos niveles — Resource e InstrumentationScope. ¿Por qué es necesaria la schema URL a nivel *scope* además de la de nivel resource? Dá un escenario concreto donde un único proceso necesite dos schema URLs de scope diferentes.
- **Q2.** Si establecés `schema_url` en el tracer pero lo omitís de `Resource.create(...)`, ¿qué lleva cada uno, y puede un backend igualmente saber qué versión de convention siguen los *atributos del span*?

---

## Ejercicio 2 — Ubicar la Schema URL en el cable (OTLP)

Vas a enviar un trace OTLP/JSON hecho a mano y leer exactamente dónde cae la schema URL en el envoltorio OTLP, usando el exporter `debug` del Collector.

**Pasos**

1. Creá `collector.yaml` (sin procesamiento de schema todavía — puro passthrough):

   ```yaml
   receivers:
     otlp:
       protocols:
         http:
           endpoint: 0.0.0.0:4318
   exporters:
     debug:
       verbosity: detailed
   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
   ```

2. Iniciá el Collector:

   ```bash
   docker run --rm -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.116.0
   ```

3. Creá `trace.json`. Notá que `schemaUrl` se ubica **al lado** (no dentro) de `resource`, y **al lado** de `scope`:

   ```json
   {
     "resourceSpans": [
       {
         "resource": {
           "attributes": [
             { "key": "service.name", "value": { "stringValue": "orders-db-client" } }
           ]
         },
         "schemaUrl": "https://opentelemetry.io/schemas/1.4.0",
         "scopeSpans": [
           {
             "scope": { "name": "cassandra.instrumentation", "version": "0.9.0" },
             "schemaUrl": "https://opentelemetry.io/schemas/1.4.0",
             "spans": [
               {
                 "traceId": "5b8efff798038103d269b633813fc60c",
                 "spanId": "eee19b7ec3c1b174",
                 "name": "SELECT orders",
                 "kind": 3,
                 "startTimeUnixNano": "1700000000000000000",
                 "endTimeUnixNano": "1700000000500000000",
                 "attributes": [
                   { "key": "db.system", "value": { "stringValue": "cassandra" } },
                   { "key": "db.cassandra.keyspace", "value": { "stringValue": "orders" } }
                 ]
               }
             ]
           }
         ]
       }
     ]
   }
   ```

4. Envialo:

   ```bash
   curl -s -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" \
     --data-binary @trace.json
   ```

5. Leé el log del Collector. Ambas schema URLs afloran, y el atributo de la era 1.4.0 pasa sin cambios:

   ```
   ResourceSpans #0
   Resource SchemaURL: https://opentelemetry.io/schemas/1.4.0
   Resource attributes:
        -> service.name: Str(orders-db-client)
   ScopeSpans #0
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.4.0
   InstrumentationScope cassandra.instrumentation 0.9.0
   Span #0
       Name           : SELECT orders
       Kind           : Client
       Attributes:
            -> db.system: Str(cassandra)
            -> db.cassandra.keyspace: Str(orders)
   ```

**Comprensión**

- **Q3.** En el protobuf de OTLP, ¿en qué mensajes vive el campo `schema_url` de *nivel resource* para traces, metrics y logs, y en qué mensajes vive el campo `schema_url` de *nivel scope*?
- **Q4.** Un backend ingiere spans que no llevan `schemaUrl` en ninguno de los dos niveles. ¿Qué capacidad específica pierde el backend, y cómo se manifiesta eso cuando dos equipos emiten `http.method` vs `http.request.method`?

---

## Ejercicio 3 — Leer el archivo de schema: el lenguaje de transformación

La schema URL apunta a un *archivo de schema* YAML que enumera, versión por versión, cómo cambiaron los atributos/metrics/events. Aprendé a leerlo.

**Pasos**

1. Guardá este archivo **ilustrativo** como `schema-1.3.0.yaml`. Ejercita cada sección y tipo de cambio del formato de archivo `1.1.0`:

   ```yaml
   file_format: 1.1.0
   schema_url: https://example.com/schemas/1.3.0
   versions:
     1.3.0:
       all:                         # attribute rename applied to EVERY signal type
         changes:
           - rename_attributes:
               attribute_map:
                 k8s.cluster.name: kubernetes.cluster.name
       resources:                   # resource attributes only
         changes:
           - rename_attributes:
               attribute_map:
                 telemetry.auto.version: telemetry.distro.version
       spans:
         changes:
           - rename_attributes:
               attribute_map:
                 peer.service: network.peer.service
               apply_to_spans:      # limit the rename to these span names
                 - "HTTP GET"
                 - "HTTP POST"
       span_events:
         changes:
           - rename_events:
               name_map:
                 exception.stacktrace.v1: exception.stacktrace
           - rename_attributes:
               attribute_map:
                 message.type: rpc.message.type
               apply_to_events:
                 - message
       metrics:
         changes:
           - rename_metrics:
               process.runtime.jvm.gc.count: jvm.gc.count
           - rename_attributes:
               attribute_map:
                 state: process.state
               apply_to_metrics:
                 - system.memory.usage
           - split:                 # one metric -> several, keyed by an attribute
               apply_to_metric: system.paging.operations
               by_attribute: direction
               metrics_from_attributes:
                 system.paging.operations.in: in
                 system.paging.operations.out: out
       logs:
         changes:
           - rename_attributes:
               attribute_map:
                 log.severity: severity.text
     1.2.0:
   ```

2. Rastreá la semántica de cada bloque:
   - Cada sección `<version>:` describe cómo convertir telemetría **desde la versión anterior hasta esta versión**.
   - `attribute_map` / `name_map` se escriben como **`old_name: new_name`**.
   - `all` es una abreviatura que se expande a un rename de atributos sobre resources, spans, span events, metric data points y log records.
   - `apply_to_*` restringe un cambio a nombres específicos de span/event/metric.
   - `split` divide los data points de una métrica según el valor de `by_attribute`, los emite como las métricas nombradas y **descarta ese atributo**.

3. Compará con un schema real y hosteado para confirmar el formato:

   ```bash
   curl -s https://opentelemetry.io/schemas/1.9.0 | sed -n '1,40p'
   ```

   Vas a encontrar el bloque `1.5.0` genuino renombrando `db.cassandra.keyspace → db.name` (spans) y `system.processes.count → system.process.count` (metrics) — el cambio que vas a explotar en el Ejercicio 4.

**Comprensión**

- **Q5.** Telemetría etiquetada `1.2.0` se convierte a `1.3.0`. Para un span llamado `"HTTP GET"` que lleva `peer.service=payments`, listá cada cambio del archivo que aplica y el estado resultante de los atributos.
- **Q6.** Describí exactamente qué le hace el cambio `split` a los data points de `system.paging.operations` (valores, nombres de métricas, atributos) al convertir **hacia adelante** a `1.3.0`.
- **Q7.** ¿El rename `all` de `k8s.cluster.name` afecta a los atributos de los *metric* data points? ¿Cómo coexiste con el propio `rename_attributes` de `state` de la sección `metrics`?
- **Q8.** ¿Cómo convertiría un consumidor telemetría **hacia abajo** de `1.3.0` a `1.2.0` usando este mismo archivo? ¿Qué debe registrar el cambio `split` para que esa dirección inversa funcione?

---

## Ejercicio 4 — Normalizar telemetría entre versiones con el schema processor

Ahora hacé que el Collector *reescriba* telemetría de convention vieja a una versión objetivo automáticamente.

**Pasos**

1. Editá `collector.yaml` para insertar el processor `schema` y apuntarlo al target `1.9.0`:

   ```yaml
   receivers:
     otlp:
       protocols:
         http:
           endpoint: 0.0.0.0:4318
   processors:
     schema:
       prefetch:                                   # warm the cache at startup (optional)
         - https://opentelemetry.io/schemas/1.9.0
       targets:                                    # convert each matching family to this version
         - https://opentelemetry.io/schemas/1.9.0
   exporters:
     debug:
       verbosity: detailed
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [schema]
         exporters: [debug]
   ```

2. Reiniciá el Collector (ahora necesita salida de red para descargar el archivo de schema):

   ```bash
   docker run --rm -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.116.0
   ```

3. Reenviá el **mismo** `trace.json` del Ejercicio 2 (todavía etiquetado `1.4.0`, todavía llevando `db.cassandra.keyspace`):

   ```bash
   curl -s -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" --data-binary @trace.json
   ```

4. Compará la salida de debug con la del Ejercicio 2. Dos cosas cambiaron — las schema URLs se reescribieron al target, y el atributo se renombró por la regla `1.5.0`:

   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.9.0
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.9.0
   Span #0
       Name           : SELECT orders
       Attributes:
            -> db.system: Str(cassandra)
            -> db.name: Str(orders)
   ```

5. Enviá un span etiquetado con una familia de schema que el processor **no** tenga como target (por ejemplo cambiando `schemaUrl` a `https://schemas.acme.internal/1.0.0`) y confirmá que pasa sin tocar.

**Comprensión**

- **Q9.** Tras el procesamiento, `Resource SchemaURL` dice `1.9.0` y `db.cassandra.keyspace` se convirtió en `db.name`. Explicá la cadena: qué regla de qué versión de schema se disparó, en qué dirección, y por qué la schema URL de *salida* es ahora `1.9.0`.
- **Q10.** El processor sale hacia `opentelemetry.io`. ¿Qué te da `prefetch`, y qué le pasa a este processor en un cluster totalmente air-gapped? ¿Qué tendrías que cambiar para que la traducción de schemas funcione ahí?
- **Q11.** Llega telemetría cuya schema URL pertenece a una familia ausente de `targets`. ¿Qué hace el processor con ella, y por qué ese es el default correcto en lugar de descartarla?

---

## Ejercicio 5 — Diagnosticar conflictos y fallas de schema

La gestión de schemas falla de unas pocas maneras características. Reproducilas y razoná sobre ellas.

**Pasos**

1. **Conflicto de merge de Resource (Go).** Construí dos resources con schema URLs *diferentes* y hacé merge:

   ```go
   r1, _ := resource.New(ctx, resource.WithSchemaURL("https://opentelemetry.io/schemas/1.21.0"))
   r2, _ := resource.New(ctx, resource.WithSchemaURL("https://opentelemetry.io/schemas/1.24.0"))

   merged, err := resource.Merge(r1, r2)
   fmt.Println(err)     // cannot merge resource due to conflicting Schema URL
   fmt.Println(merged)  // empty resource
   ```

   `resource.Merge` devuelve `Empty()` **y** un error no-nil cuando ambos operandos tienen schema URLs no vacías y diferentes.

2. **El disparador del mundo real.** Esto muerde con más frecuencia cuando `resource.Default()` (que lleva la schema URL de `semconv` incluida en el SDK) se mergea con un resource que construiste usando un import `semconv/vX.Y.Z` *diferente* — por ejemplo tras actualizar una instrumentation library que subió su versión embebida de semantic-conventions.

3. **Schema URL faltante.** Reejecutá el Ejercicio 2 pero borrá ambas líneas `schemaUrl` de `trace.json`. Observá que `Resource SchemaURL` / `ScopeSpans SchemaURL` ya no se imprimen — y que el processor `schema` del Ejercicio 4 ya no puede transformar esos spans.

4. **Archivo de schema inalcanzable.** Apuntá una entrada de `targets` (o enviá telemetría) a una schema URL que dé 404 (por ejemplo `https://opentelemetry.io/schemas/9.9.9`) y observá en los logs del Collector el error de fetch.

**Comprensión**

- **Q12.** ¿Por qué `resource.Merge` se rehúsa a mergear dos schema URLs diferentes en lugar de elegir una? ¿Qué contiene el resource devuelto?
- **Q13.** Un servicio que arrancaba bien ahora hace panic/error al inicio con un "conflicting Schema URL" tras subir una dependencia. Enunciá la causa raíz y dá **dos** arreglos distintos.
- **Q14.** El processor `schema` registra que no puede descargar un archivo de schema (error de red / 404). ¿Cuál es el efecto sobre la telemetría afectada mientras fluye por la pipeline, y qué señal de monitoreo atraparía esto en producción?

---

## Referencias (fuentes oficiales)

- Telemetry Schemas — especificación: <https://opentelemetry.io/docs/specs/otel/schemas/>
- Schema file format v1.1.0 (secciones, `all`/`resources`/`spans`/`span_events`/`metrics`/`logs`, `split`): <https://opentelemetry.io/docs/specs/otel/schemas/file_format_v1.1.0/>
- Schemas de OpenTelemetry hosteados (navegar transformaciones reales): <https://opentelemetry.io/schemas/1.9.0>
- Especificación & proto de OTLP (`schema_url` en mensajes `Resource*`/`Scope*`): <https://opentelemetry.io/docs/specs/otlp/> · <https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/trace/v1/trace.proto>
- Resource SDK — semántica de schema URL & reglas de merge: <https://opentelemetry.io/docs/specs/otel/resource/sdk/>
- Semantic Conventions (el versionado que impulsa los cambios de schema): <https://opentelemetry.io/docs/specs/semconv/>
- `schemaprocessor` del Collector (config: `prefetch`, `targets`; estabilidad): <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/schemaprocessor>
- Exporter `debug` del Collector: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/debugexporter>

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** La schema URL del Resource describe *la entidad* (el servicio/proceso) y sus atributos de resource; la schema URL del InstrumentationScope describe *qué versión de convention usó una instrumentation library específica para las señales que emitió*. Están desacopladas porque un único proceso corre muchas instrumentation libraries que se actualizan de forma independiente. Caso concreto: tu HTTP client library se actualizó para emitir `http.request.method` (scope schema `1.21.0`) mientras una database library legada todavía emite `db.cassandra.keyspace` (scope schema `1.4.0`). Ambas viven en el mismo proceso/Resource pero deben anunciar schema URLs de scope diferentes para que un consumidor pueda normalizar cada una correctamente.

**Q2.** El tracer/scope lleva `1.21.0`; el Resource lleva una schema URL **vacía**. Un backend igual puede determinar la versión de convention de los atributos del *span* a partir de la schema URL del scope — precisamente por eso existe el campo a nivel scope. Simplemente no puede atribuir una versión de convention a los atributos del *resource* (por ejemplo, no sabría si se espera `telemetry.auto.version` vs `telemetry.distro.version`).

**Q3.** El `schema_url` de nivel resource vive en **`ResourceSpans`**, **`ResourceMetrics`** y **`ResourceLogs`**. El `schema_url` de nivel scope vive en **`ScopeSpans`**, **`ScopeMetrics`** y **`ScopeLogs`**. En cada mensaje es un campo string de nivel superior (número de campo 3), hermano del `resource`/`scope` y de las listas de datos — no anidado dentro de los mensajes `Resource` o `InstrumentationScope` mismos.

**Q4.** Pierde la capacidad de **normalizar/traducir** entre versiones de convention. Sin una schema URL el backend no puede saber a qué versión pertenece un nombre de atributo dado, así que no puede mapear `http.method` y `http.request.method` al mismo campo lógico. Los datos de los dos equipos entonces se parten entre dos claves de atributo — dashboards y alertas ven silenciosamente la mitad del tráfico bajo cada nombre, y las consultas entre versiones requieren alias mantenidos a mano.

**Q5.** Convirtiendo `1.2.0 → 1.3.0`, todos los cambios de la sección `1.3.0` que coinciden aplican, en orden:
- `all`: `k8s.cluster.name → kubernetes.cluster.name` (si está presente en el span).
- `spans` `rename_attributes` con `apply_to_spans: ["HTTP GET","HTTP POST"]`: como el nombre del span es `"HTTP GET"`, `peer.service` se renombra a `network.peer.service`. Resultado: el span ahora lleva `network.peer.service=payments` (y cualquier `k8s.cluster.name` se renombra). Un span con otro nombre (por ejemplo `"GET /cart"`) mantendría `peer.service` sin cambios, ya que el rename está condicionado por el nombre del span.

**Q6.** Hacia adelante a `1.3.0`, `split` toma cada data point de `system.paging.operations`, lee su atributo `direction`, y lo enruta: los puntos con `direction=in` se convierten en la nueva métrica **`system.paging.operations.in`**, los puntos con `direction=out` se convierten en **`system.paging.operations.out`**. Los valores numéricos se preservan; la métrica original `system.paging.operations` desaparece y el atributo `direction` se **elimina** de los data points resultantes (su información ahora está codificada en el nombre de la métrica).

**Q7.** Sí — `all` renombra el atributo en *cada* tipo de señal, incluidos los atributos de los metric data points, así que `k8s.cluster.name → kubernetes.cluster.name` también aplica a metrics. Coexiste con el rename de la sección `metrics` de `state → process.state` porque apuntan a atributos *diferentes*; ambos renames aplican y no entran en conflicto. (`all` simplemente se expande en un rename sobre cada señal; un cambio por-señal a una clave diferente compone de forma independiente.)

**Q8.** Convirtiendo **hacia abajo** `1.3.0 → 1.2.0`, el consumidor aplica los cambios de `1.3.0` **en reversa e invertidos**: los mapas de atributos/métricas/eventos se leen `new_name → old_name` (por ejemplo `network.peer.service → peer.service`, `jvm.gc.count → process.runtime.jvm.gc.count`). Las transformaciones de schema están diseñadas para ser reversibles. Para que `split` se revierta, la definición del cambio debe registrar el atributo por el que dividió (`direction`) y el valor que representa cada métrica derivada (`system.paging.operations.in → in`), de modo que la reversa ("merge") recree `system.paging.operations` y vuelva a agregar `direction=in`/`direction=out` a partir de los nombres de las métricas.

**Q9.** El span entró etiquetado `1.4.0`. El processor identifica la *familia* de schema (`https://opentelemetry.io/schemas/…`) y el target `1.9.0`, descarga el archivo de schema `1.9.0`, y aplica cada cambio con versión en `(1.4.0, 1.9.0]` en la dirección **hacia adelante**. La regla `spans` `db.cassandra.keyspace → db.name` del bloque `1.5.0` se dispara, renombrando el atributo. Como la telemetría fue traducida *a* `1.9.0`, el processor reescribe tanto la schema URL del Resource como la del Scope a `1.9.0`, de modo que los consumidores downstream vean datos `1.9.0` internamente consistentes.

**Q10.** `prefetch` descarga y cachea los archivos de schema listados al inicio, evitando un fetch (y su latencia/falla) en el primer batch que coincida. En un cluster totalmente air-gapped el processor no puede alcanzar `opentelemetry.io`, así que no puede obtener las reglas de transformación y no puede traducir. Para hacerlo funcionar tenés que hostear los archivos de schema en un servidor interno, usar schema URLs internas (`https://schemas.corp.internal/…`), **y asegurarte de que los productores emitan esas URLs internas** — el processor descarga la URL exacta que la telemetría anuncia; no hay copia offline incluida.

**Q11.** **Pasa la telemetría sin cambios.** El processor solo reescribe las familias listadas en `targets`; cualquier otra cosa queda fuera de alcance. Eso es correcto porque descartar telemetría meramente por carecer de un mapeo de schema conocido causaría pérdida silenciosa de datos — el passthrough preserva los datos (todavía etiquetados con su schema URL original) para que otro processor/backend pueda manejarlos.

**Q12.** Dos schema URLs no vacías y diferentes son genuinamente incompatibles: el resource mergeado no puede afirmar con verdad que sigue *ambas* versiones de convention, y elegir una silenciosamente podría mal-etiquetar los atributos del otro operando. Por eso `Merge` lo trata como un error en lugar de adivinar. El resource devuelto es `Empty()` (sin atributos, schema URL vacía), acompañado de un error no-nil `cannot merge resource due to conflicting Schema URL`.

**Q13.** Causa raíz: una actualización de dependencia subió la versión de `semconv` incluida en un componente, así que dos resources que se mergean (típicamente `resource.Default()` y tu resource custom, o los resources de dos libraries) ahora anuncian schema URLs *diferentes*, y `resource.Merge` rechaza la combinación. Dos arreglos: (a) **alinear las versiones de semconv** — importar el mismo `go.opentelemetry.io/otel/semconv/vX.Y.Z` en todos lados para que todos los resources compartan una schema URL; o (b) **construir tu resource con la schema URL coincidente de forma explícita** (o sin schema URL en un lado, ya que mergear vacío-con-no-vacío está permitido) para que no haya conflicto. (Actualizar todo el conjunto SDK/semconv junto es la versión durable del arreglo (a).)

**Q14.** El processor no puede construir la traducción para ese schema, así que registra un error y la telemetría afectada **no se convierte** — dependiendo de la versión del componente se pasa con su schema URL original (o el batch se rechaza); no se "traduce con éxito" silenciosamente. La consecuencia operativa es datos de versiones mezcladas llegando a tu backend. Atrapalo en producción alertando sobre las propias métricas/logs internos del Collector — los logs de error del processor más los contadores `otelcol_processor_*` / refused-vs-accepted de la pipeline — en lugar de esperar a notar nombres de atributos partidos downstream.

</details>