# Tema 1.2 — Convenciones Semánticas: Ejercicios Guiados

> **Qué entrenan estos ejercicios.** Las Convenciones Semánticas (Semantic Conventions) son el *contrato* que hace comparable la telemetría de distintos lenguajes, bibliotecas y proveedores. Definen los nombres canónicos, tipos, unidades y niveles de requerimiento de los atributos en Resources, Spans, Metrics y Logs. En producción, esto es lo que permite que un único dashboard consulte `http.server.request.duration` a través de un servicio en Go, un servicio en Python y una biblioteca de terceros sin traducción. Estos ejercicios te hacen *observar* las convenciones en la telemetría emitida, no solo leer sobre ellas.
>
> **Prerrequisitos**
> - Docker (para ejecutar el Collector y `telemetrygen` sin instalaciones locales)
> - Python 3.9+ y `pip` (Ejercicios 2–4)
> - `git`, `grep`, `curl`, `jq`
>
> **Directorio de trabajo**
> ```bash
> mkdir -p otca-semconv && cd otca-semconv
> ```
>
> Fuente primaria: especificación de OpenTelemetry Semantic Conventions — <https://opentelemetry.io/docs/specs/semconv/>

---

## Ejercicio 1 — Leer el modelo: el Attribute Registry como fuente de verdad

La documentación del sitio web para las convenciones semánticas se *genera* a partir de YAML legible por máquina en el repositorio `open-telemetry/semantic-conventions`. Aprender a leer el modelo te dice la verdad de base: el `type`, `stability`, `requirement_level` y `brief` de un atributo.

1. Cloná el repositorio del modelo e inspeccioná la estructura de nivel superior:
   ```bash
   git clone --depth 1 https://github.com/open-telemetry/semantic-conventions.git
   cd semantic-conventions
   ls model/
   ```
   Esperado (los nombres de directorios varían levemente según la release):
   ```
   database   faas    http   messaging   registry.yaml   resource   rpc   ...
   ```

2. Localizá la definición canónica del atributo del método de petición HTTP. La entrada del registry es el único lugar donde un atributo se *declara*; en todos los demás lugares se lo referencia por `ref`:
   ```bash
   grep -rn "id: http.request.method" model/
   ```
   Esperado (la ruta depende de la release; lo que importa es la forma de la coincidencia):
   ```
   model/http/registry.yaml:12:      - id: http.request.method
   ```

3. Abrí el bloque circundante y leé los campos:
   ```bash
   grep -n -A 20 "id: http.request.method" model/http/registry.yaml
   ```
   Deberías ver una definición equivalente a:
   ```yaml
   - id: http.request.method
     type:
       allow_custom_values: true
       members:
         - id: connect
           value: "CONNECT"
         - id: get
           value: "GET"
         - id: post
           value: "POST"
         # ...
     stability: stable
     brief: 'HTTP request method.'
     examples: ["GET", "POST", "HEAD"]
   ```

4. Confirmá el mismo atributo en el registry *renderizado* del sitio web, para que puedas mapear YAML → docs:
   - <https://opentelemetry.io/docs/specs/semconv/registry/attributes/http/>

**Verificación de comprensión (Bloque 1)**
1. ¿Cuál es la diferencia entre que un atributo esté *declarado* en el registry versus *referenciado* (`ref:`) en un grupo de span o metric? ¿Por qué el proyecto separa ambos?
2. El `type` de `http.request.method` es un enum con `allow_custom_values: true`. ¿Qué valor canónico debe usar una instrumentación cuando observa un método que **no** está en el conjunto conocido, y qué atributo acompañante captura la cadena original?
3. ¿Por qué la documentación generada del sitio web se considera un artefacto derivado y no la fuente de verdad?

---

## Ejercicio 2 — Convenciones Semánticas de Resource: la identidad del productor

Cada flujo de telemetría lleva un **Resource**: el conjunto inmutable de atributos que describen *qué* la produjo (service, host, container, cloud, SDK). Las convenciones de Resource son cómo un backend agrupa spans y metrics bajo un único servicio. Aquí los definís declarativamente mediante variables de entorno y verificás qué emite realmente el SDK.

1. Creá una configuración del Collector que imprima todo lo que recibe, en su totalidad:
   ```yaml
   # collector.yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
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
       metrics:
         receivers: [otlp]
         exporters: [debug]
   ```

2. Iniciá el Collector (dejalo corriendo en esta terminal):
   ```bash
   docker run --rm --name otelcol -p 4317:4317 -p 4318:4318 \
     -v "$(pwd)/collector.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:0.109.0
   ```

3. En una **segunda** terminal, instalá el SDK de Python y una app generadora de trazas:
   ```bash
   python -m venv .venv && source .venv/bin/activate
   pip install opentelemetry-sdk opentelemetry-exporter-otlp-proto-grpc
   ```

4. Definí los atributos de Resource **únicamente** mediante las variables de entorno estándar — no los codifiques a mano:
   ```bash
   export OTEL_SERVICE_NAME="checkout"
   export OTEL_RESOURCE_ATTRIBUTES="service.version=1.4.2,service.namespace=shop,deployment.environment.name=staging,service.instance.id=checkout-7d9f-abc"
   export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
   ```

5. Emití un span para que el Resource sea transmitido:
   ```python
   # emit.py
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

   provider = TracerProvider()                 # picks up OTEL_* env resource automatically
   provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
   trace.set_tracer_provider(provider)

   tracer = trace.get_tracer("my.demo", "0.1.0")
   with tracer.start_as_current_span("warmup"):
       pass

   provider.shutdown()                          # force flush before exit
   ```
   ```bash
   python emit.py
   ```

6. Leé la terminal del Collector. Deberías ver el bloque Resource:
   ```
   ResourceSpans #0
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   Resource attributes:
        -> service.name: Str(checkout)
        -> service.version: Str(1.4.2)
        -> service.namespace: Str(shop)
        -> deployment.environment.name: Str(staging)
        -> service.instance.id: Str(checkout-7d9f-abc)
        -> telemetry.sdk.language: Str(python)
        -> telemetry.sdk.name: Str(opentelemetry)
        -> telemetry.sdk.version: Str(1.27.0)
   ```

7. Notá que nunca definiste `telemetry.sdk.*`. Confirmá qué atributos inyecta el SDK por su cuenta desactivando los tuyos personalizados y volviendo a ejecutar:
   ```bash
   unset OTEL_RESOURCE_ATTRIBUTES
   python emit.py    # Resource now shows only service.name + telemetry.sdk.*
   ```

**Verificación de comprensión (Bloque 2)**
1. `service.name` tiene nivel de requerimiento **Required**. ¿Qué valor usa el SDK como reserva (fallback) si nunca definís `OTEL_SERVICE_NAME` ni `service.name`, y por qué depender de esa reserva es un antipatrón en producción?
2. `telemetry.sdk.language`, `telemetry.sdk.name` y `telemetry.sdk.version` aparecieron sin que los definieras. ¿Qué componente es responsable de poblarlos, y cuál es el nivel de requerimiento que los hace obligatorios?
3. La salida usó `deployment.environment.name`. Material más antiguo y SDKs más antiguos emiten `deployment.environment`. ¿Qué te dice ese renombramiento sobre el *ciclo de vida de estabilidad* de un atributo, y cómo correlacionaría un backend ambos?
4. `service.instance.id` distingue réplicas del mismo `service.name`. Dá una razón concreta de cardinalidad de métricas por la que querrías tenerlo en los Resources pero **no** lo querrías como atributo de punto de datos de una métrica.

---

## Ejercicio 3 — Convenciones de Span HTTP: nombres, kinds y atributos

HTTP es la convención estable más madura y la que más apuntan las preguntas de examen. Aquí generás spans HTTP reales y verificás el **name**, el **kind** del span y el **conjunto de atributos estable** — incluyendo la regla de baja cardinalidad para los nombres de span.

1. Con el Collector del Ejercicio 2 aún corriendo, generá un span HTTP del lado **servidor** y otro del lado **cliente** usando `telemetrygen`:
   ```bash
   docker run --rm --network host \
     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
     traces --otlp-insecure --otlp-endpoint localhost:4317 \
     --traces 1 --service checkout \
     --span-duration 50ms
   ```
   *(`telemetrygen` emite spans genéricos; usalo para confirmar el pipeline, luego leé spans HTTP reales del paso 3.)*

2. Instalá una app instrumentada real para que las convenciones HTTP sean producidas por la instrumentación de la biblioteca, no a mano:
   ```bash
   pip install flask requests \
     opentelemetry-instrumentation-flask \
     opentelemetry-instrumentation-requests \
     opentelemetry-exporter-otlp-proto-grpc
   ```
   ```python
   # app.py
   from flask import Flask
   from opentelemetry import trace
   from opentelemetry.sdk.trace import TracerProvider
   from opentelemetry.sdk.trace.export import BatchSpanProcessor
   from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
   from opentelemetry.instrumentation.flask import FlaskInstrumentor

   provider = TracerProvider()
   provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
   trace.set_tracer_provider(provider)

   app = Flask(__name__)
   FlaskInstrumentor().instrument_app(app)

   @app.route("/users/<int:user_id>")
   def user(user_id):
       return {"id": user_id}
   ```

3. Ejecutala y dispará una petición con un parámetro de ruta:
   ```bash
   export OTEL_SERVICE_NAME=checkout
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
   flask --app app run --port 8080 &
   curl -s http://localhost:8080/users/42 >/dev/null
   ```

4. En la salida del Collector, inspeccioná el span del servidor:
   ```
   Span #0
       Name           : GET /users/<int:user_id>
       Kind           : Server
       Status code    : Unset
       Attributes:
            -> http.request.method: Str(GET)
            -> url.path: Str(/users/42)
            -> url.scheme: Str(http)
            -> http.route: Str(/users/<int:user_id>)
            -> http.response.status_code: Int(200)
            -> network.protocol.version: Str(1.1)
            -> server.address: Str(localhost)
            -> server.port: Int(8080)
            -> user_agent.original: Str(curl/8.5.0)
            -> client.address: Str(127.0.0.1)
   ```

5. Contrastá: el **name** del span es `GET /users/<int:user_id>` (la *plantilla de ruta*), mientras que `url.path` es `/users/42` (la petición *concreta*). Verificá que esta distinción es deliberada solicitando un segundo id:
   ```bash
   curl -s http://localhost:8080/users/99 >/dev/null
   ```
   El nombre del span sigue siendo `GET /users/<int:user_id>`; solo `url.path` cambia a `/users/99`.

**Verificación de comprensión (Bloque 3)**
1. La convención del nombre del span **servidor** HTTP es `{method} {http.route}`. ¿Por qué se usa `http.route` (y no `url.path`) en el nombre, y qué fallo operacional ocurre en un backend de métricas/trazas si una implementación nombra los spans con la ruta cruda?
2. Un span HTTP del lado cliente (SpanKind `Client`) lleva `url.full` pero normalmente **omite** `http.route`. Explicá por qué `http.route` es un concepto *exclusivo del servidor*.
3. Tu app llamó a `GET /users/42` y la respuesta fue `200`. ¿Bajo qué condición de estado de respuesta la convención requiere que el `Status` del span se ponga en `Error`, y difiere esa regla entre spans `Client` y `Server`?
4. La salida muestra tanto `server.address`/`server.port` como `client.address`. Estos provienen de los espacios de nombres *compartidos* `network`/`server`/`client` en lugar de un nombre con prefijo `http.`. ¿Cuál es el beneficio de diseño de factorizar estos fuera del espacio de nombres `http.*`?

---

## Ejercicio 4 — Convenciones de Metric: nombres, unidades UCUM y tipo de instrumento

Las convenciones de métricas fijan el *nombre*, el *tipo de instrumento* y la *unidad* (en UCUM). Un punto sutil y relevante para el examen: la métrica estable de duración HTTP se mide en **segundos**, no en milisegundos, y su nombre cambió respecto a la era experimental.

1. Consultá la convención renderizada para la métrica estable de duración del servidor:
   ```bash
   curl -s https://opentelemetry.io/docs/specs/semconv/http/http-metrics/ \
     | grep -iA2 "http.server.request.duration" | head
   ```
   Definición canónica que deberías confirmar:
   - **Name**: `http.server.request.duration`
   - **Instrument**: Histogram
   - **Unit**: `s` (segundos, UCUM)
   - **Stability**: Stable

2. Emití una métrica de duración de servidor HTTP que siga la convención y otra que la viole, luego comparalas. Primero, un instrumento correcto:
   ```python
   # metric.py
   from opentelemetry import metrics
   from opentelemetry.sdk.metrics import MeterProvider
   from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
   from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

   reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=2000)
   metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
   meter = metrics.get_meter("my.demo", "0.1.0")

   # CORRECT: convention name + UCUM 's'
   hist = meter.create_histogram(
       name="http.server.request.duration",
       unit="s",
       description="Duration of HTTP server requests.",
   )
   hist.record(0.042, {"http.request.method": "GET", "http.response.status_code": 200,
                       "http.route": "/users/{id}"})
   ```
   ```bash
   python metric.py
   ```

3. Leé la salida de métricas del Collector:
   ```
   Metric #0
   Descriptor:
        -> Name: http.server.request.duration
        -> Unit: s
        -> DataType: Histogram
   HistogramDataPoints #0
   Data point attributes:
        -> http.request.method: Str(GET)
        -> http.response.status_code: Int(200)
        -> http.route: Str(/users/{id})
   ```

4. Inspeccioná una convención de conteo adimensional. Cambiá el nombre/unidad para modelar *peticiones activas* (un `UpDownCounter`) y observá la unidad anotada:
   - **Name**: `http.server.active_requests`
   - **Instrument**: UpDownCounter
   - **Unit**: `{request}` (una *anotación* UCUM — adimensional, llaves)

5. Confirmá la disciplina de *cardinalidad*: los atributos del punto de la métrica son exactamente el subconjunto de baja cardinalidad (`http.request.method`, `http.response.status_code`, `http.route`) — **no** `url.path`, `url.full` ni `user_agent.original`.

**Verificación de comprensión (Bloque 4)**
1. La unidad estable de la métrica es `s`, pero muchos dashboards heredados esperan milisegundos. ¿Qué nombre de métrica anterior reemplazó `http.server.request.duration`, y qué unidad usaba ese predecesor? ¿Por qué mezclar ambos en un mismo dashboard corrompe silenciosamente los percentiles?
2. `{request}` y `1` son ambos "adimensionales" en UCUM. ¿Qué agrega la anotación entre llaves, y por qué se prefiere para los contadores sobre un `1` desnudo?
3. El histograma llevaba `http.route` pero no `url.path`. Reformulá la regla general que las convenciones imponen sobre qué atributos HTTP pueden aparecer en puntos de datos de **métricas** versus atributos de **span**, y relacionala con la cardinalidad de las series temporales.
4. El tipo de instrumento es parte de la convención (Histogram vs UpDownCounter vs Counter). ¿Por qué emitir el *nombre* correcto con el *tipo de instrumento* equivocado sigue siendo una violación de convención que un backend no puede reparar silenciosamente?

---

## Ejercicio 5 — Schema URLs y el opt-in de estabilidad: sobrevivir a los cambios de convención

Las convenciones evolucionan. Dos mecanismos evitan que eso rompa a los consumidores: el **Schema URL** que llevan los Resources y los Instrumentation Scopes (apunta a una versión), y los archivos de **Telemetry Schema** que describen las transformaciones entre versiones. Durante una migración con cambios incompatibles, los SDKs exponen `OTEL_SEMCONV_STABILITY_OPT_IN` para que puedas emitir el conjunto de atributos viejo, nuevo o ambos.

1. Releé la salida de Resource del Ejercicio 2 y fijate en la línea que salteaste:
   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   ```
   Descargá ese schema y comprobá que es un artefacto real y versionado:
   ```bash
   curl -s https://opentelemetry.io/schemas/1.27.0 | head -40
   ```
   Deberías ver un `file_format`, un `schema_url`, y bloques `versions:` con secciones `all`/`resources`/`spans` que contienen transformaciones `rename_attributes`, p. ej. una entrada que mapea `deployment.environment` → `deployment.environment.name`.

2. Reproducí una decisión de migración localmente. Simulá un SDK que soporta el opt-in de estabilidad HTTP inspeccionando los valores documentados (la bandera fue central durante la migración HTTP `net.*`/`http.*` → `url.*`/`server.*`):
   ```bash
   # Emit ONLY the new, stable attributes:
   export OTEL_SEMCONV_STABILITY_OPT_IN=http
   # Emit BOTH old and new for a safe cutover window:
   export OTEL_SEMCONV_STABILITY_OPT_IN=http/dup
   # Unset -> legacy attributes only (pre-stable default, for older instrumentations)
   unset OTEL_SEMCONV_STABILITY_OPT_IN
   ```
   Guía de migración (tabla de mapeo autoritativa): <https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/>

3. Mapeá a mano tres atributos HTTP viejo→nuevo desde la guía, luego verificalos contra la salida del Ejercicio 3:
   | Heredado (experimental) | Estable (actual) |
   |---|---|
   | `http.method` | `http.request.method` |
   | `http.status_code` | `http.response.status_code` |
   | `http.url` | `url.full` |

4. Confirmá dónde se adjunta el Schema URL en el formato de cable (wire format). En la salida del Collector viste **dos** schema URLs independientes: uno en el `Resource` y otro en el `ScopeSpans`/`InstrumentationScope`. Localizá ambos:
   ```
   Resource SchemaURL: https://opentelemetry.io/schemas/1.27.0
   ...
   ScopeSpans SchemaURL: https://opentelemetry.io/schemas/1.27.0
   InstrumentationScope my.demo 0.1.0
   ```

**Verificación de comprensión (Bloque 5)**
1. El Schema URL aparece en **ambos**, el Resource y cada Instrumentation Scope. ¿Por qué la convención permite dos versiones de schema distintas en un mismo lote exportado, y qué situación real produce eso?
2. Durante la migración HTTP, `OTEL_SEMCONV_STABILITY_OPT_IN=http/dup` duplica la cantidad de atributos en cada span HTTP. ¿Qué costo operacional implica `http/dup`, y cuál es la única razón por la que un equipo aún aceptaría ese costo por una ventana acotada?
3. Un backend recibe spans estampados con `schema_url = .../1.20.0` que llevan `deployment.environment`, y otros spans estampados con `.../1.27.0` que llevan `deployment.environment.name`. Explicá, en términos de `rename_attributes` de Telemetry Schema, cómo un procesador consciente del schema los unifica en una única dimensión consultable.
4. Si un SDK emite telemetría que sigue las convenciones 1.27.0 pero la estampa con `schema_url = .../1.20.0`, ¿qué comprobaciones de la escalera (la URL resuelve / los atributos son correctos) pasan, y qué se rompe aguas abajo? Relacionalo con por qué el schema URL es una *afirmación* que debe coincidir con el payload.

---

## Ejercicio 6 — Autorar una convención: reglas de nomenclatura de atributos y validación

El conjunto de reglas de propósito general gobierna cualquier atributo que inventes para tu propio dominio. Acertar con el espacio de nombres, el uso de mayúsculas/minúsculas y los niveles de requerimiento es lo que mantiene *tus* atributos compatibles hacia adelante con futuros atributos oficiales.

1. Leé las reglas de nomenclatura y anotá las cuatro restricciones estrictas:
   - <https://opentelemetry.io/docs/specs/semconv/general/naming/>
   - minúsculas; los puntos (`.`) separan **espacios de nombres**; los guiones bajos (`_`) separan **palabras dentro de un elemento**; un segmento de espacio de nombres nunca se reutiliza como nombre de atributo hoja.

2. Clasificá cada candidato como válido/inválido *y decí por qué*:
   ```
   payment.card.type          # ?
   Payment.CardType           # ?
   payment.card_holder.name   # ?
   payment                    # ? (used both as namespace and as attribute)
   user_agent.original        # ?
   http                       # ?
   ```

3. Redactá un pequeño grupo de atributos personalizado como YAML en el estilo del modelo (esta es exactamente la forma usada en `open-telemetry/semantic-conventions`):
   ```yaml
   groups:
     - id: registry.payment
       type: attribute_group
       brief: "Attributes describing a payment operation."
       attributes:
         - id: payment.provider.name
           type: string
           stability: development        # your own attributes start experimental
           requirement_level: required
           brief: "Name of the payment gateway."
           examples: ["stripe", "adyen"]
         - id: payment.card.brand
           type:
             allow_custom_values: true
             members:
               - id: visa
                 value: "visa"
               - id: mastercard
                 value: "mastercard"
           stability: development
           requirement_level: recommended
           brief: "Card network brand."
   ```

4. (Opcional, autoritativo) Validá el modelo con **Weaver**, la herramienta oficial que el proyecto usa para lintear y generar docs a partir de estos archivos YAML:
   ```bash
   docker run --rm -v "$(pwd):/work" \
     otel/weaver:latest registry check -r /work/model
   ```
   - Weaver: <https://github.com/open-telemetry/weaver>

**Verificación de comprensión (Bloque 6)**
1. Para cada uno de los seis candidatos del paso 2, indicá válido/inválido y la regla exacta que lo decide.
2. Tus nuevos atributos fueron declarados `stability: development`. ¿Qué obligación impone eso a los *consumidores* de tu telemetría, y qué debés hacer antes de poder marcar uno como `stable`?
3. La convención prohíbe usar un nombre que sea *también* un espacio de nombres (p. ej. un atributo llamado literalmente `payment` mientras existe `payment.*`). ¿Qué problema concreto de parseo/colisión previene esta regla en las claves de atributo con puntos?
4. `requirement_level: required` vs `recommended` vs `conditionally_required` vs `opt_in` — ¿qué nivel significa "emitilo solo cuando el usuario lo active explícitamente porque puede ser costoso o sensible", y dá un ejemplo plausible de pagos?

---

<details>
<summary><strong>Clave de respuestas — clic para expandir</strong></summary>

### Bloque 1 — Attribute Registry
1. **Declarado vs referenciado.** El *registry* contiene una declaración autoritativa de cada atributo (su `type`, `stability`, `brief`, `examples`). Los grupos de span, metric y resource luego hacen `ref:` a ese id y solo sobrescriben campos *contextuales* como `requirement_level` o `sampling_relevant`. La separación garantiza una única definición de `http.request.method` para que su tipo y estabilidad no puedan divergir entre los usos en span HTTP y en metric HTTP — una fuente de verdad, muchos contextos.
2. Cuando el método observado no está en el enum conocido, la instrumentación pone `http.request.method` en el valor centinela **`_OTHER`** y registra el valor crudo en **`http.request.method_original`**. Esto acota la cardinalidad del enum mientras preserva la cadena original para depuración.
3. Los docs del sitio web se **generan** a partir del YAML del modelo (históricamente vía las herramientas de build, ahora vía Weaver). El Markdown renderizado puede quedar rezagado o reformateado; el YAML en `open-telemetry/semantic-conventions/model/` es la fuente normativa, y por eso hacés grep sobre el modelo, no sobre el HTML.

### Bloque 2 — Convenciones de Resource
1. Si no se define ni `OTEL_SERVICE_NAME` ni `service.name`, el SDK emite el valor por defecto **`unknown_service`** (a menudo `unknown_service:<process>`, p. ej. `unknown_service:python`). Es un antipatrón porque toda carga de trabajo sin nombre colapsa en la misma serie/agrupación en el backend, destruyendo el aislamiento por servicio y volviendo inútiles las alertas y las cuotas.
2. El **SDK** puebla `telemetry.sdk.*` automáticamente; su nivel de requerimiento es **Required**, así que un SDK conforme siempre debe adjuntarlos. Identifican qué SDK/lenguaje/versión produjo los datos — esencial para triar bugs del lado del productor.
3. El renombramiento `deployment.environment` → `deployment.environment.name` es un paso normal en el **ciclo de vida de estabilidad** de un atributo (development → stable, a veces vía renombramiento/deprecación). Un backend consciente del schema correlaciona el viejo y el nuevo mediante la transformación `rename_attributes` de **Telemetry Schema**, tomada del `schema_url` del Resource (ver Bloque 5).
4. `service.instance.id` es deliberadamente de **alta cardinalidad** (un valor por réplica). En un Resource está bien — identifica qué pod emitió un flujo. Como atributo de **punto de datos de métrica**, multiplicaría cada serie temporal por la cantidad de réplicas (y rotaría en cada reinicio/redeploy), causando una explosión de cardinalidad. Mantené la identidad por réplica en el Resource, mantené las dimensiones de métrica de baja cardinalidad.

### Bloque 3 — Spans HTTP
1. El nombre usa `http.route` (la **plantilla** de baja cardinalidad, p. ej. `/users/{id}`) para que todas las peticiones al mismo handler compartan un único nombre de span. Si una implementación nombra los spans con el `url.path` crudo, cada id distinto (`/users/42`, `/users/99`, …) se vuelve un nuevo nombre de operación — una **explosión de cardinalidad** que rompe la agregación, el top-N por operación y los mapas de servicio.
2. `http.route` es la *plantilla de ruta del lado servidor coincidente* del router de la aplicación receptora. Un cliente no conoce la plantilla de ruta del receptor — solo conoce la URL que discó. De ahí que `http.route` sea **exclusivo del servidor**, y los clientes lleven `url.full` en su lugar.
3. Las reglas Status→Error difieren según el kind. Para spans **Client**, un estado de respuesta `4xx` **o** `5xx` pone el `Status` del span en `Error`. Para spans **Server**, solo **`5xx`** pone `Error` — un `4xx` (p. ej. `404`, `403`) es un resultado válido y esperado de un servidor correcto y permanece en `Unset`. (Un fallo de transporte sin respuesta pone `Error` de cualquiera de los dos lados.)
4. Factorizar `server.*`, `client.*`, `network.*` fuera de `http.*` permite que protocolos **no HTTP** (gRPC/RPC, database, messaging) reutilicen exactamente los mismos atributos de dirección/puerto/protocolo. Una única convención `server.address` significa que un solo filtro de dashboard funciona a través de todos los protocolos en lugar de `http.host`, `db.host`, `rpc.host`, etc.

### Bloque 4 — Métricas
1. El estable `http.server.request.duration` (unidad `s`, segundos) reemplazó al experimental **`http.server.duration`**, que usaba **milisegundos (`ms`)**. Si ambos alimentan una misma consulta de histograma/percentil, los valores difieren por 1000× así que los buckets y los p50/p95/p99 calculados quedan sin sentido — un punto de `0.042 s` y uno de `42 ms` representan la misma latencia pero caen en buckets muy distintos.
2. `{request}` es una **anotación** UCUM: sigue siendo adimensional, pero documenta *qué* se está contando. Se prefiere sobre un `1` desnudo porque autodescribe la unidad ("requests") sin cambiar la semántica numérica, ayudando a humanos y a backends conscientes de unidades. El `1` desnudo se reserva para razones/fracciones genuinamente sin unidades.
3. Regla: los atributos de punto de datos de **métrica** deben ser de **baja cardinalidad** (`http.request.method`, `http.response.status_code`, `http.route`, y campos de protocolo negociados). Los atributos de span de alta cardinalidad — `url.path`, `url.full`, `url.query`, `user_agent.original`, `client.address` — **no deben** ser dimensiones de métrica, porque cada valor distinto genera una nueva serie temporal, y las dimensiones no acotadas causan una explosión de cardinalidad en el TSDB.
4. El tipo de instrumento determina la temporalidad de agregación y la semántica de monotonicidad en el cable (un Histogram lleva buckets/sum/count; un Counter es monótono acumulativo; un UpDownCounter es no monótono). Un backend no puede "reparar" un Counter convirtiéndolo en Histogram después del hecho porque la distribución cruda nunca fue transmitida — así que el tipo de instrumento equivocado es una violación de convención irrecuperable, no una cosmética.

### Bloque 5 — Schema URLs y opt-in de estabilidad
1. La versión de schema del Resource refleja la era del **SDK/detector de recursos**, mientras que la versión de schema de cada Instrumentation Scope refleja la era de la instrumentación de *esa biblioteca específica*. Un único proceso puede correr un SDK construido contra 1.27.0 mientras carga una biblioteca de instrumentación más antigua que aún emite atributos 1.20.0 — dos schema URLs en un mismo lote es la representación honesta de esa mezcla.
2. `http/dup` emite **ambos** conjuntos de atributos, heredados y estables, en cada span HTTP, aproximadamente duplicando el volumen de atributos HTTP (más bytes, más almacenamiento, más procesamiento). Los equipos lo aceptan solo durante una **ventana de transición acotada**, para que los dashboards/alertas escritos contra los nombres viejos sigan funcionando mientras se migran los nuevos; una vez completada la migración, cambiás a `http` (solo nuevos).
3. Un procesador consciente del schema lee el `schema_url` de cada flujo, busca el Telemetry Schema, y aplica la cadena de transformaciones `rename_attributes` entre versiones (`deployment.environment` → `deployment.environment.name`). Ambos flujos se normalizan a una única versión objetivo, así que una consulta sobre `deployment.environment.name` devuelve datos que llegaron bajo cualquiera de los dos nombres — sin dashboards duplicados.
4. Si el payload es 1.27.0 pero está estampado con `schema_url = 1.20.0`: la **URL resuelve** y los **atributos son individualmente válidos**, así que las comprobaciones al estilo de citación pasan. Lo que se rompe es la transformación consciente del schema: un procesador aplica los renombramientos 1.20.0→objetivo a atributos que *ya* están en la forma nueva, corrompiéndolos o descartándolos. El schema URL es una **afirmación sobre el payload**; cuando la afirmación no coincide, cada consumidor que confía en ella transforma mal los datos — la misma clase de fallo que una URL que resuelve pero no dice lo que afirmás.

### Bloque 6 — Autorar convenciones
1. Veredictos de los candidatos:
   - `payment.card.type` — **válido** (minúsculas, espacios de nombres con puntos, elementos de una sola palabra).
   - `Payment.CardType` — **inválido** (letras mayúsculas; `CardType` debería ser `card_type` o dividirse en espacios de nombres).
   - `payment.card_holder.name` — **válido** (`card_holder` usa un guion bajo para unir palabras *dentro de un elemento*).
   - `payment` (usado como espacio de nombres y como atributo) — **inválido** (un segmento de espacio de nombres no debe ser también un nombre de atributo hoja).
   - `user_agent.original` — **válido** (el guion bajo une las palabras del elemento `user_agent`; `original` es la hoja).
   - `http` — **inválido** como nombre de atributo (es un espacio de nombres, nunca una hoja).
2. `stability: development` (experimental) significa que los consumidores **no deben** tratar esos atributos como estables: los nombres/tipos pueden cambiar sin aviso, así que no construyas dashboards/alertas duraderos que no puedas darte el lujo de arreglar. Antes de marcar uno como `stable`, debe pasar por el proceso de estabilidad del proyecto — revisión pública y un compromiso de que el nombre/tipo/semántica no cambiarán sin deprecación. (Para tus *propios* atributos privados, "stable" es tu propia garantía, pero la disciplina es la misma.)
3. Las claves de atributo son rutas con puntos parseadas como una jerarquía de espacios de nombres. Si `payment` fuera a la vez un atributo con valor y el prefijo de `payment.card.brand`, la clave `payment` es ambigua — ¿es un escalar o la raíz de un mapa? Prohibir la colisión mantiene cada clave con puntos inequívocamente como prefijo de espacio de nombres o como hoja, lo cual es esencial para los backends que modelan atributos como estructuras anidadas.
4. **`opt_in`** significa "emitir solo cuando el usuario lo habilita explícitamente", usado para atributos que son costosos de computar o **sensibles**. Ejemplo de pagos: un identificador completo del titular de la tarjeta o el cuerpo crudo de la petición — valiosos para depuración pero sensibles en cuanto a privacidad, así que están apagados por defecto y se encienden deliberadamente. (`conditionally_required` difiere: *debe* emitirse cuando se cumple una condición establecida, p. ej. `http.response.status_code` cuando se recibió una respuesta.)

</details>

---

### Fuentes
- Semantic Conventions (índice de la spec) — <https://opentelemetry.io/docs/specs/semconv/>
- Attribute Naming — <https://opentelemetry.io/docs/specs/semconv/general/naming/>
- Attribute Registry — <https://opentelemetry.io/docs/specs/semconv/registry/attributes/>
- Convenciones de Resource — <https://opentelemetry.io/docs/specs/semconv/resource/>
- Spans HTTP — <https://opentelemetry.io/docs/specs/semconv/http/http-spans/>
- Métricas HTTP — <https://opentelemetry.io/docs/specs/semconv/http/http-metrics/>
- Directrices generales de métricas / UCUM — <https://opentelemetry.io/docs/specs/semconv/general/metrics/> · <https://ucum.org/>
- Migración HTTP y `OTEL_SEMCONV_STABILITY_OPT_IN` — <https://opentelemetry.io/docs/specs/semconv/non-normative/http-migration/>
- Telemetry Schemas — <https://opentelemetry.io/docs/specs/otel/schemas/>
- Repositorio del modelo — <https://github.com/open-telemetry/semantic-conventions>
- Herramienta Weaver — <https://github.com/open-telemetry/weaver>
- Currículo OTCA — <https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf>