# OTCA 3.5 — Transformando Datos

> **Dominio 3 · El OpenTelemetry Collector — Tema 3.5 (peso en el examen ≈ 5.2)**
>
> El valor del Collector no es que *mueva* la telemetría, sino que la *remodela* al vuelo: enriqueciendo recursos, normalizando claves de atributos, descartando ruido, enmascarando PII, agregando labels de métricas e incluso derivando nuevas señales a partir de las existentes. Este tema es donde aprendés a hacerlo de forma determinista, con los processors y el **OpenTelemetry Transformation Language (OTTL)**.
>
> Estos son labs prácticos. Vas a ejecutar un Collector real, enviarle payloads OTLP hechos a mano y leer la salida del exporter `debug` para *probar* que cada transformación ocurrió. No te saltees los pasos de observación — leer la salida transformada es el objetivo completo.

---

## Objetivos

Al finalizar vas a poder:

- Ordenar processors correctamente en un pipeline y explicar por qué el orden cambia el resultado.
- Usar el processor **attributes** (`insert`/`update`/`upsert`/`delete`/`hash`/`extract`) y el processor **resource**.
- Escribir sentencias **OTTL** en el processor **transform** a través de los contextos `resource`, `span`, `metric`, `datapoint` y `log`.
- Descartar telemetría con el processor **filter** usando condiciones OTTL.
- Enmascarar valores sensibles con el processor **redaction**.
- Renombrar y agregar labels de métricas con el processor **metricstransform**.
- Derivar métricas a partir de traces con el connector **spanmetrics**.

**Distribución de referencia:** OpenTelemetry Collector *Contrib* (`otelcol-contrib`), porque `transform`, `filter`, `redaction`, `metricstransform` y el connector `spanmetrics` vienen solo en Contrib, no en la distribución Core.

Fuentes:
- Collector overview — https://opentelemetry.io/docs/collector/
- Transform processor — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/transformprocessor/README.md
- OTTL grammar & functions — https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/README.md and https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/ottlfuncs/README.md

---

## Lab 0 — Setup y el harness de observación

Necesitás un Collector en ejecución y una forma de ver qué sale por el otro extremo. El exporter `debug` (el sucesor del viejo exporter `logging`) imprime la telemetría decodificada a stdout.

1. Descargá el binario del Collector Contrib para tu plataforma desde la página de releases (https://github.com/open-telemetry/opentelemetry-collector-contrib/releases) y confirmá que ejecuta:

   ```bash
   otelcol-contrib --version
   # otelcol-contrib version 0.109.0   (any recent 0.10x is fine)
   ```

2. Creá `base.yaml`, el harness que vas a extender en cada ejercicio. Acepta OTLP sobre gRPC (4317) y HTTP (4318) y hace eco de todo a la consola con detalle completo:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   exporters:
     debug:
       verbosity: detailed        # prints resource/scope/attributes, not just counts

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: []
         exporters: [debug]
   ```

3. Iniciálo:

   ```bash
   otelcol-contrib --config ./base.yaml
   ```

   Dejá esta terminal abierta — es tu ventana de salida.

4. En una segunda terminal, guardá este span OTLP/HTTP JSON en crudo como `span.json`. Contiene deliberadamente una ruta de health-check, un e-mail PII y un número de tarjeta de crédito — la materia prima para los ejercicios posteriores:

   ```json
   {
     "resourceSpans": [{
       "resource": {
         "attributes": [
           {"key": "service.name", "value": {"stringValue": "checkout"}},
           {"key": "host.name", "value": {"stringValue": "node-7"}}
         ]
       },
       "scopeSpans": [{
         "scope": {"name": "manual-test"},
         "spans": [{
           "traceId": "5b8efff798038103d269b633813fc60c",
           "spanId": "eee19b7ec3c1b174",
           "name": "GET /user/12345/profile",
           "kind": 2,
           "startTimeUnixNano": "1700000000000000000",
           "endTimeUnixNano":   "1700000000100000000",
           "attributes": [
             {"key": "http.request.method", "value": {"stringValue": "GET"}},
             {"key": "http.route",          "value": {"stringValue": "/health"}},
             {"key": "user.email",          "value": {"stringValue": "alice@example.com"}},
             {"key": "credit_card",         "value": {"stringValue": "4716123456789012"}}
           ]
         }]
       }]
     }]
   }
   ```

5. Enviálo y confirmá el round-trip:

   ```bash
   curl -sS -X POST http://localhost:4318/v1/traces \
     -H "Content-Type: application/json" \
     -d @span.json
   # {"partialSuccess":{}}   <- empty partialSuccess means fully accepted
   ```

   La terminal del Collector debería imprimir el span con los cuatro atributos, por ejemplo:

   ```
   Span #0
       Trace ID       : 5b8efff798038103d269b633813fc60c
       ID             : eee19b7ec3c1b174
       Name           : GET /user/12345/profile
       Kind           : Server
       Attributes:
            -> http.request.method: Str(GET)
            -> http.route: Str(/health)
            -> user.email: Str(alice@example.com)
            -> credit_card: Str(4716123456789012)
   ```

**Preguntas de control — Lab 0**

- **Q0.1** ¿Por qué este lab usa `otelcol-contrib` en lugar del binario Core `otelcol`?
- **Q0.2** ¿Qué te dice un `{"partialSuccess":{}}` vacío en el cuerpo de la respuesta OTLP/HTTP, y qué significaría un conteo `rejectedSpans` no vacío?
- **Q0.3** Con `verbosity: detailed`, el campo imprime `Str(...)` junto a cada atributo. ¿Por qué importa el tipo del valor cuando más adelante escribís condiciones OTTL que comparan un atributo con `"/health"`?

---

## Lab 1 — Los processors attributes y resource

El processor attributes edita atributos a **nivel de señal** (atributos de span, de datapoint de métrica o de log). El processor resource edita atributos a **nivel de recurso** (el bloque `service.name`, `host.name` que identifica *qué produjo* la telemetría). Confundir los dos ámbitos es el error más común.

1. Creá `01-attributes.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     resource:
       attributes:
         - key: deployment.environment
           value: production
           action: insert           # only if absent
         - key: host.name
           action: delete            # strip a high-cardinality identifier

     attributes:
       actions:
         - key: team
           value: payments
           action: insert            # add if missing
         - key: http.request.method
           value: UNKNOWN
           action: update            # change ONLY if it already exists
         - key: http.status_code
           value: 200
           action: upsert            # insert-or-update
         - key: user.email
           action: hash              # irreversible one-way hash of the value
         - key: user_id
           from_attribute: http.route
           pattern: ^/user/(?P<user_id>\d+)/.*$   # (extract shown in transform lab too)
           action: extract

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [resource, attributes]
         exporters: [debug]
   ```

2. Reiniciá el Collector con esta config y reenviá `span.json`:

   ```bash
   otelcol-contrib --config ./01-attributes.yaml
   # (other terminal)
   curl -sS -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" -d @span.json
   ```

3. En la salida, verificá cada acción. Ahora deberías ver (abreviado):

   ```
   Resource attributes:
        -> service.name: Str(checkout)
        -> deployment.environment: Str(production)     # inserted; host.name is gone
   ...
   Span #0
       Attributes:
            -> http.request.method: Str(GET)           # update kept GET (it existed)
            -> http.route: Str(/health)
            -> user.email: Str(2bd806c9...)            # hashed, no longer readable
            -> credit_card: Str(4716123456789012)
            -> team: Str(payments)                     # inserted
            -> http.status_code: Int(200)              # upserted (was absent)
   ```

4. Ahora enviá un segundo span **sin** `http.request.method` (borrá ese atributo de una copia de `span.json`) y observá que `update` **no** lo crea — probando que `update` ≠ `upsert`.

**Preguntas de control — Lab 1**

- **Q1.1** Para cada acción, indicá si actúa cuando la clave está ausente, presente o en ambos casos: `insert`, `update`, `upsert`, `delete`.
- **Q1.2** El borrado de `host.name` está en el processor **resource** y `team` está en el processor **attributes**. ¿Por qué no podrías intercambiarlos — qué pasaría si pusieras `key: host.name / action: delete` bajo el processor attributes?
- **Q1.3** ¿Por qué es preferible `hash` sobre `user.email` a `delete` cuando tus dashboards todavía necesitan contar *usuarios distintos* pero no deben exponer la dirección?
- **Q1.4** La acción `extract` pobló `user_id` a partir de un grupo de captura nombrado por regex. Dado que `http.route` era `/health` (no `/user/12345/...`), ¿se creó `user_id` para nuestro span? ¿Por qué sí o por qué no?

---

## Lab 2 — El processor transform y OTTL

El processor attributes es declarativo y limitado. **OTTL** es un pequeño lenguaje de expresiones que te da condicionales, funciones y múltiples **contextos**. En el processor transform agrupás sentencias por `context` — `resource`, `scope`, `span`, `spanevent`, `metric`, `datapoint` o `log` — y el Collector ejecuta cada sentencia contra cada ítem que coincida.

Vocabulario clave:
- Las funciones **editor** mutan la telemetría y no devuelven nada: `set`, `delete_key`, `keep_keys`, `replace_pattern`, `limit`, `truncate_all`, `merge_maps`.
- Las funciones **converter** computan y devuelven un valor: `SHA256`, `Concat`, `Split`, `IsMatch`, `Substring`, `Hour`, `ConvertCase`.
- Cada sentencia puede terminar con un guard `where <condition>`.
- `error_mode: ignore | silent | propagate` controla qué pasa cuando una sentencia da error en un registro (por ejemplo, una clave faltante).

1. Creá `02-transform.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     transform:
       error_mode: ignore
       trace_statements:
         - context: resource
           statements:
             # Keep only the resource keys we care about, drop the rest.
             - keep_keys(attributes, ["service.name", "deployment.environment"])
         - context: span
           statements:
             # 1) Normalize a high-cardinality name into a route template.
             - replace_pattern(name, "/user/[0-9]+/", "/user/{id}/")
             # 2) Derive a boolean-ish attribute only for health checks.
             - set(attributes["is_synthetic"], true) where attributes["http.route"] == "/health"
             # 3) Irreversibly hash PII with an explicit algorithm.
             - set(attributes["user.email"], SHA256(attributes["user.email"])) where attributes["user.email"] != nil
             # 4) Mark the span as an error if it took too long (fabricated rule).
             - set(status.code, STATUS_CODE_ERROR) where (end_time_unix_nano - start_time_unix_nano) > 90000000
             # 5) Defensive hygiene: cap attribute count and value length.
             - limit(attributes, 128, ["service.name"])
             - truncate_all(attributes, 4096)

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [transform]
         exporters: [debug]
   ```

2. Reiniciá y enviá `span.json`. Verificá:
   - `Name` pasó a ser `GET /user/{id}/profile`.
   - `is_synthetic: Bool(true)` fue agregado (la ruta es `/health`).
   - `user.email` ahora es un digest SHA-256 de 64 caracteres hex.
   - Nuestro span duró `100ms` (100000000 ns) > 90ms, así que `Status.Code` es `Error`.

   ```
   Span #0
       Name           : GET /user/{id}/profile
       Status code    : Error
       Attributes:
            -> http.route: Str(/health)
            -> user.email: Str(2bd806c9f...e3b0c44)   # SHA256 digest
            -> is_synthetic: Bool(true)
   ```

3. Experimentá con `error_mode`. Agregá una sentencia que referencie una clave presente solo en algunos spans, por ejemplo `set(attributes["x"], Substring(attributes["missing"], 0, 3))`. Con `error_mode: ignore`, el registro defectuoso pasa sin tocar y el procesamiento continúa; cambiá a `propagate` y observá cómo el Collector registra el error de la sentencia para ese registro.

**Preguntas de control — Lab 2**

- **Q2.1** ¿Cuáles de estas son editors y cuáles converters: `set`, `SHA256`, `keep_keys`, `IsMatch`, `truncate_all`? ¿Cuál es la consecuencia práctica de esa distinción — podés escribir `keep_keys(...) == true`?
- **Q2.2** La sentencia `keep_keys` está en el contexto `resource` y `replace_pattern(name, ...)` está en el contexto `span`. ¿Qué pasa si movés `keep_keys(attributes, [...])` al contexto `span` por error — qué atributos filtra entonces?
- **Q2.3** Explicá, usando el ejemplo `set(status.code, ...) where duration > 90ms`, por qué los guards `where` importan para `error_mode`. Si `end_time_unix_nano` faltara, ¿en qué diferirían `ignore` y `propagate`?
- **Q2.4** Tanto el Lab 1 como el Lab 2 hashearon `user.email`. ¿Por qué un revisor de seguridad podría preferir la forma `SHA256(...)` del processor transform sobre la acción `hash` del processor attributes?

---

## Lab 3 — Descartando datos con el processor filter

Transformar incluye *remover*. El processor filter evalúa **condiciones** OTTL (no sentencias); cuando una condición es verdadera, el registro es **descartado** del pipeline. Así es como te sacás de encima el ruido de los health-check, los logs de nivel debug o una métrica charlatana antes de que te cueste dinero en el backend.

1. Creá `03-filter.yaml`. Descarta spans de health-check y logs de nivel debug:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     filter/drop_noise:
       error_mode: ignore
       traces:
         span:
           - 'attributes["http.route"] == "/health"'
           - 'IsMatch(name, ".*(healthz|readyz|livez).*")'
       logs:
         log_record:
           - 'severity_number < SEVERITY_NUMBER_INFO'   # drop TRACE/DEBUG
       metrics:
         datapoint:
           - 'attributes["state"] == "idle"'            # drop idle CPU datapoints

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [filter/drop_noise]
         exporters: [debug]
   ```

2. Reiniciá y enviá `span.json`. Como `http.route == "/health"`, el span es descartado — la terminal del Collector no debería imprimir **nada** para esta solicitud (o solo un ack HTTP `{"partialSuccess":{}}`, sin span decodificado).

3. Probá el caso negativo. Editá una copia de `span.json`, cambiá `http.route` a `/checkout` y reenviá. Ahora el span *sí* aparece en la salida, confirmando que el filter es selectivo y no descarta todo.

**Preguntas de control — Lab 3**

- **Q3.1** En el processor filter, cuando una condición evalúa a **verdadero**, ¿el registro se conserva o se descarta? Contrastá eso con una cláusula `where` en el processor transform.
- **Q3.2** Las dos condiciones `traces.span` se combinan con OR. Si necesitaras "descartar solo cuando la ruta es `/health` **y** el método es `GET`", ¿cómo lo expresarías en una sola condición OTTL?
- **Q3.3** La regla de metrics usa el contexto `datapoint`, no el contexto `metric`. ¿Por qué importa descartar a granularidad de datapoint para un gauge como `system.cpu.time{state=idle|user|system}` — qué haría en cambio un filtrado en contexto `metric` sobre `name == "system.cpu.time"`?
- **Q3.4** Colocás `filter/drop_noise` primero en el pipeline, antes de `transform`. Dá una razón de costo y una razón de corrección por las que este orden suele ser el correcto.

---

## Lab 4 — Enmascarando valores sensibles con el processor redaction

Hashear cambia un valor; redaction lo *enmascara* mientras conserva la clave, y también puede imponer una allow-list para que las claves inesperadas nunca se filtren. Esta es la herramienta con nivel de compliance para PANs, tokens y secretos.

1. Creá `04-redaction.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     redaction:
       allow_all_keys: false          # anything not allowed/ignored is deleted
       allowed_keys:
         - http.request.method
         - http.route
         - credit_card                # allowed to exist, but its VALUE is inspected
       ignored_keys:
         - http.status_code           # never inspected, always kept
       blocked_values:                # regexes matched against allowed values
         - '4[0-9]{12}(?:[0-9]{3})?'  # Visa PAN
         - '5[1-5][0-9]{14}'          # MasterCard PAN
       summary: debug                 # add redaction.* meta-attributes

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [redaction]
         exporters: [debug]
   ```

2. Reiniciá y enviá `span.json`. Verificá:
   - `user.email` **desapareció** (no está en `allowed_keys`, `allow_all_keys: false`).
   - `credit_card` está presente pero **enmascarado** (su valor coincidió con un patrón bloqueado).
   - Aparecen meta-atributos gracias a `summary: debug`.

   ```
   Span #0
       Attributes:
            -> http.request.method: Str(GET)
            -> http.route: Str(/health)
            -> credit_card: Str(****)
            -> redaction.masked.count: Int(1)
            -> redaction.masked.keys: Str(credit_card)
            -> redaction.allowed.count: Int(3)
   ```

3. Cambiá el valor de `credit_card` en una copia de `span.json` a `not-a-card` y reenviá. La clave permanece y el valor **no** se enmascara, porque no coincidió con ningún regex de `blocked_values` — probando que redaction enmascara por *valor*, no por *nombre de clave*.

**Preguntas de control — Lab 4**

- **Q4.1** Con `allow_all_keys: false`, ¿qué le pasa a una clave que no está ni en `allowed_keys` ni en `ignored_keys`? ¿Cuál de los atributos originales de nuestro span eliminó esa regla?
- **Q4.2** ¿Cuál es la diferencia entre `ignored_keys` y `allowed_keys` — específicamente, se verifica un valor de `ignored_keys` contra `blocked_values`?
- **Q4.3** `credit_card` fue enmascarado pero `user.email` fue removido por completo. Si compliance requiriera que el *email* se enmascare a `****` (conservado, no borrado) en lugar de descartado, ¿qué dos cambios a esta config lo logran?
- **Q4.4** ¿Por qué es operativamente útil `summary: debug` en un pipeline real, y por qué podrías ponerlo en `info` u omitirlo en producción?

---

## Lab 5 — Remodelando métricas con el processor metricstransform

OTTL puede editar datapoints de métricas, pero **renombrar métricas** y **agregar labels para eliminarlos** (para reducir cardinalidad) es la especialidad del processor metricstransform.

1. Guardá esta métrica como `metric.json` — un sum de `system.cpu.time` dividido por `cpu` y `state`:

   ```json
   {
     "resourceMetrics": [{
       "resource": { "attributes": [{"key":"service.name","value":{"stringValue":"node-exporter"}}] },
       "scopeMetrics": [{
         "scope": {"name": "manual-test"},
         "metrics": [{
           "name": "system.cpu.time",
           "sum": {
             "aggregationTemporality": 2,
             "isMonotonic": true,
             "dataPoints": [
               {"asDouble": 10, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"0"}},{"key":"state","value":{"stringValue":"user"}}]},
               {"asDouble": 20, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"1"}},{"key":"state","value":{"stringValue":"user"}}]},
               {"asDouble":  5, "timeUnixNano":"1700000000000000000", "attributes":[{"key":"cpu","value":{"stringValue":"0"}},{"key":"state","value":{"stringValue":"system"}}]}
             ]
           }
         }]
       }]
     }]
   }
   ```

2. Creá `05-metricstransform.yaml` — renombrá la métrica y colapsá la dimensión por-`cpu` sumando:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   processors:
     metricstransform:
       transforms:
         - include: system.cpu.time
           action: update
           new_name: system.cpu.time.seconds        # rename
         - include: system.cpu.time.seconds
           action: update
           operations:
             - action: aggregate_labels
               label_set: [state]                    # keep 'state', drop 'cpu'
               aggregation_type: sum

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       metrics:
         receivers: [otlp]
         processors: [metricstransform]
         exporters: [debug]
   ```

3. Reiniciá y enviá:

   ```bash
   curl -sS -X POST http://localhost:4318/v1/metrics -H "Content-Type: application/json" -d @metric.json
   ```

   Empezaste con 3 datapoints a través de 2 valores de `cpu`; después de agregar y eliminar `cpu` deberías ver **2** datapoints indexados solo por `state`:

   ```
   Metric #0
        Name: system.cpu.time.seconds
        DataPoints
        NumberDataPoint  Value: 30.0   Attributes: state=user     # 10 + 20
        NumberDataPoint  Value:  5.0   Attributes: state=system
   ```

**Preguntas de control — Lab 5**

- **Q5.1** ¿Por qué el segundo bloque transform usa `include: system.cpu.time.seconds` y no el nombre original? ¿Qué te dice esto sobre cómo se encadenan los transforms secuenciales?
- **Q5.2** `aggregate_labels` usó `aggregation_type: sum`. Para una métrica que era un gauge de temperatura por rack, ¿por qué `sum` estaría mal, y qué tipo de agregación elegirías?
- **Q5.3** ¿Cómo reduce el costo del backend descartar el label `cpu`, y qué información se pierde de forma irreversible al hacerlo?
- **Q5.4** Tanto metricstransform como el processor transform OTTL pueden tocar atributos de métricas. Nombrá una cosa que metricstransform hace que OTTL (contexto `datapoint`) no puede hacer tan limpiamente.

---

## Lab 6 — Derivando nuevas señales: el connector spanmetrics

La "transformación" más poderosa convierte una señal de un *tipo* a otro. Un **connector** es un exporter en un pipeline y un receiver en otro. El connector `spanmetrics` consume spans y **produce** métricas de conteo de solicitudes e histogramas de latencia (el método R.E.D.) sin ningún cambio en la aplicación.

1. Creá `06-spanmetrics.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols: { grpc: { endpoint: 0.0.0.0:4317 }, http: { endpoint: 0.0.0.0:4318 } }

   connectors:
     spanmetrics:
       histogram:
         explicit:
           buckets: [5ms, 10ms, 50ms, 100ms, 250ms, 1s]
       dimensions:
         - name: http.route
         - name: http.request.method
           default: GET
       metrics_flush_interval: 5s

   exporters:
     debug: { verbosity: detailed }

   service:
     pipelines:
       traces:                       # spans go IN to the connector
         receivers: [otlp]
         exporters: [spanmetrics]
       metrics:                      # derived metrics come OUT of the connector
         receivers: [spanmetrics]
         exporters: [debug]
   ```

2. Reiniciá y enviá `span.json` unas cuantas veces dentro del intervalo de flush:

   ```bash
   for i in 1 2 3; do
     curl -sS -X POST http://localhost:4318/v1/traces -H "Content-Type: application/json" -d @span.json
   done
   ```

3. Dentro de ~5 s el pipeline de metrics imprime las métricas derivadas — un contador monotónico de llamadas y un histograma de latencia, dimensionados por los atributos de span que listaste:

   ```
   Metric #0
        Name: calls               # (a.k.a. traces.span.metrics.calls)
        NumberDataPoint  Value: 3.0
             -> http.route: Str(/user/{id}/profile-ish)   # from span name/route
             -> http.request.method: Str(GET)
             -> span.kind: Str(SPAN_KIND_SERVER)
   Metric #1
        Name: duration            # histogram, buckets from config
        HistogramDataPoint  Count: 3  Sum: 300  ...
   ```

**Preguntas de control — Lab 6**

- **Q6.1** En el bloque `service.pipelines`, `spanmetrics` aparece como una entrada `exporters` bajo `traces` y una entrada `receivers` bajo `metrics`. Explicá en una oración cómo ese único componente puentea dos pipelines.
- **Q6.2** Listaste `http.route` y `http.request.method` como `dimensions`. ¿Cuál es el riesgo de cardinalidad de agregar `user.email` como dimensión, y cómo se conecta eso con el Lab 4?
- **Q6.3** Si removieras el pipeline `metrics` por completo pero mantuvieras `spanmetrics` bajo los exporters de `traces`, ¿qué pasaría con las métricas generadas?
- **Q6.4** Un compañero dice "spanmetrics es un processor". Corregílo: ¿cuál es la diferencia arquitectónica definitoria entre un **processor** y un **connector**?

---

## Síntesis — un pipeline ordenado para producción

Combiná lo que construiste en un solo pipeline y razoná sobre el orden. Los processors se ejecutan **de arriba hacia abajo** en la lista `processors:`.

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors:
        - memory_limiter        # 1. shed load first, protect the process
        - filter/drop_noise     # 2. drop what you'll never keep — cheapest to do early
        - redaction             # 3. mask PII before it can be copied downstream
        - transform             # 4. enrich/normalize the survivors
        - resource
        - attributes
        - batch                 # 5. batch LAST, just before export
      exporters: [debug, spanmetrics]
```

**Preguntas de control — Síntesis**

- **S.1** Dá el razonamiento para dos de estas ubicaciones: por qué `memory_limiter` primero, y por qué `batch` último.
- **S.2** Si movieras `redaction` para que corra *después* de que `spanmetrics` ya exportó, ¿qué falla de compliance podría ocurrir?
- **S.3** Una métrica aparece con el nombre *viejo* en tu backend aunque metricstransform la renombra. Nombrá dos errores de orden/pipeline que podrían explicarlo.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Lab 0**

- **A0.1** `transform`, `filter`, `redaction`, `metricstransform` y el connector `spanmetrics` son todos parte de la distribución *Contrib*. El binario Core `otelcol` incluye solo un conjunto mínimo y estable de componentes (receivers/exporters básicos, `batch`, `memory_limiter`), así que no puede cargar estas configs en absoluto — falla en el arranque con un error "unknown type".
- **A0.2** Un `partialSuccess` vacío significa que el Collector aceptó **todos** los ítems de la solicitud. Una respuesta no vacía con `rejectedSpans: N` y un `errorMessage` significa que el receiver rechazó N spans (por ejemplo, malformados, o un componente downstream dio error permanentemente) — el cliente no debería reintentarlos. Este es el mecanismo de OTLP para la aceptación parcial.
- **A0.3** OTTL y los processors son **conscientes del tipo** (type-aware). El valor del atributo es un *string* (`Str(...)`), así que `attributes["http.route"] == "/health"` compara string con string y coincide. Si el valor fuera un `Int` o `Bool`, esa comparación sería falsa (o daría error), y necesitarías un converter. Leer el tipo impreso te dice qué comparaciones y funciones son válidas.

**Lab 1**

- **A1.1** `insert`: actúa solo cuando la clave está **ausente**. `update`: actúa solo cuando la clave está **presente**. `upsert`: actúa en **ambos** casos (insert-or-update). `delete`: actúa solo cuando está **presente** (la elimina).
- **A1.2** `host.name` es un atributo de **resource** — vive en el bloque de resource, no en el span. El processor attributes opera sobre atributos de **span/datapoint/log**, así que `action: delete` sobre `host.name` ahí no encontraría nada en el span y no haría nada; el `host.name` a nivel de resource sobreviviría. El ámbito determina qué mapa puede siquiera ver el processor.
- **A1.3** `hash` es una función determinista de un solo sentido: el mismo e-mail siempre mapea al mismo digest, así que los conteos de usuarios distintos y los joins siguen funcionando, pero la dirección original no puede recuperarse. `delete` removería el valor por completo y haría imposible el conteo por usuario.
- **A1.4** No. La regex de `extract` requería una forma `/user/<dígitos>/...`, pero nuestro `http.route` era `/health`, que no coincide, así que ningún grupo de captura `user_id` se activó y no se creó ningún atributo. `extract` solo escribe los grupos nombrados que efectivamente coincidieron.

**Lab 2**

- **A2.1** Editors: `set`, `keep_keys`, `truncate_all` (mutan y no devuelven nada). Converters: `SHA256`, `IsMatch` (devuelven un valor). Consecuencia: no podés escribir `keep_keys(...) == true` — un editor no tiene valor de retorno para comparar. Los converters son lo que usás dentro de `set(...)` o de una condición `where`/filter.
- **A2.2** En el contexto `span`, `keep_keys(attributes, [...])` filtra el mapa de atributos **del span**, no el del resource. Así que borraría cada atributo del span que no esté en la lista (descartando `http.route`, `user.email`, etc.) y dejaría los atributos del resource sin tocar — lo opuesto a lo que pretendía la sentencia de contexto resource.
- **A2.3** El guard `where` significa que el `set` solo corre sobre spans que satisfacen la condición, así que los spans no relacionados nunca se tocan. Si `end_time_unix_nano` faltara, evaluar `end - start` da error en ese registro: con `error_mode: ignore` el registro pasa sin cambios y el procesamiento continúa; con `propagate` el error se expone (se registra / se devuelve) y puede hacer fallar el batch. `ignore` favorece la resiliencia; `propagate` favorece atrapar bugs de config.
- **A2.4** La forma transform es explícita sobre el algoritmo (`SHA256`) y la condición (`where ... != nil`), y vive en OTTL versionado que podés revisar y testear. La acción `hash` del processor attributes esconde la elección del algoritmo detrás de una palabra clave. Para auditabilidad, una función criptográfica explícita y nombrada es más fácil de certificar.

**Lab 3**

- **A3.1** En el processor filter, una condición que es **verdadera descarta** el registro. Eso es lo inverso a un guard `where` de transform, donde una condición verdadera significa "aplicá esta mutación". La misma expresión booleana OTTL, efecto opuesto — una trampa clásica del examen.
- **A3.2** Combinálas con `and` en una sola condición: `'attributes["http.route"] == "/health" and attributes["http.request.method"] == "GET"'`. Dos entradas de lista separadas se combinan con OR, así que no pueden expresar AND.
- **A3.3** El contexto `datapoint` evalúa la condición por datapoint, así que solo la serie temporal `state=idle` se descarta y `user`/`system` sobreviven. Un filtrado en contexto `metric` sobre `name == "system.cpu.time"` coincide con la **métrica completa** y descartaría *todos* sus datapoints — perderías `user` y `system` también. La granularidad del contexto determina qué se remueve.
- **A3.4** Costo: descartar temprano significa que la costosa `transform`/enriquecimiento y la exportación nunca corren sobre datos que ibas a descartar — ahorrás CPU y egress. Corrección: filtrar antes del enriquecimiento asegura que nunca emitas atributos derivados ni spanmetrics para registros que no deberían existir en absoluto.

**Lab 4**

- **A4.1** Con `allow_all_keys: false`, cualquier clave que no esté en `allowed_keys` y no esté en `ignored_keys` es **eliminada**. En nuestro span eso removió `user.email` (no estaba ni permitida ni ignorada).
- **A4.2** Las `allowed_keys` se conservan **y sus valores se inspeccionan** contra `blocked_values`. Las `ignored_keys` se conservan pero **nunca se inspeccionan** — evitan la redacción de valores por completo. Así que un valor bajo una clave ignorada *no* se verifica contra `blocked_values`; usá `ignored_keys` solo para valores que sabés que son seguros.
- **A4.3** (1) Agregá `user.email` a `allowed_keys` para que se conserve en lugar de borrarse; (2) agregá un regex a `blocked_values` que coincida con un e-mail (por ejemplo, `'[^@\s]+@[^@\s]+\.[^@\s]+'`) para que su valor se enmascare a `****`.
- **A4.4** `summary: debug` emite `redaction.masked.count`, `redaction.masked.keys`, etc., que te permiten verificar que el processor está efectivamente atrapando secretos y alertar si los conteos de enmascaramiento se disparan o caen a cero. En producción podrías bajarlo a `info` u omitirlo para evitar agregar atributos (y cardinalidad) a cada registro una vez que confiás en la config.

**Lab 5**

- **A5.1** metricstransform aplica los transforms **en orden**, y cada uno ve la salida del anterior. Después de que el primer bloque renombra la métrica, su nombre es `system.cpu.time.seconds`, así que el segundo bloque debe hacer `include` del *nuevo* nombre para coincidir. Referenciar el nombre viejo no coincidiría con nada.
- **A5.2** La temperatura es un gauge; sumar las temperaturas por rack produce un total sin sentido. Usarías `mean` (promedio) — o conservarías el label y no agregarías en absoluto. `aggregate_labels` requiere una agregación que sea semánticamente válida para el tipo de métrica.
- **A5.3** Costo: cada combinación única de valor-label es una serie temporal separada facturada/almacenada en el backend; descartar `cpu` colapsa N series por-core en una, recortando la cardinalidad aproximadamente por el conteo de cores. Pérdida: ya no podés desglosar la métrica por core de CPU — esa dimensión desaparece permanentemente para los datos transformados acá.
- **A5.4** metricstransform puede **agregar datapoints a través de un label** (sumar/promediar los datapoints que comparten el conjunto de labels sobreviviente) y **renombrar la métrica en sí**. El contexto `datapoint` de OTTL edita atributos sobre datapoints existentes pero no fusiona datapoints entre sí, y renombrar la métrica se hace en contexto `metric` — metricstransform empaqueta ambas cosas limpiamente en un solo componente.

**Lab 6**

- **A6.1** Un connector es simultáneamente un exporter (final del pipeline `traces`) y un receiver (inicio del pipeline `metrics`); los spans fluyen *hacia* él y las métricas derivadas fluyen *fuera*, así que puentea los dos tipos de pipeline a través de una única instancia de componente.
- **A6.2** `user.email` es efectivamente único por usuario, así que hacerlo una dimensión de métrica crea una serie temporal por usuario — una explosión de cardinalidad no acotada que puede saturar el backend. Eso es exactamente por qué el Lab 4 enmascaró/removió esos campos: la PII de alta cardinalidad no debe convertirse en un label de métrica.
- **A6.3** El connector igual generaría métricas internamente, pero sin un pipeline `metrics` que las consuma no hay lugar a dónde vayan — quedan efectivamente descartadas (y típicamente obtendrías un error de config o una advertencia de callejón sin salida, ya que el lado de salida del connector queda sin usar).
- **A6.4** Un **processor** transforma telemetría *dentro de un único pipeline de un solo tipo de señal* y pasa el mismo tipo de señal adelante. Un **connector** une **dos pipelines**, consumiendo un tipo de señal y emitiendo otro (o el mismo tipo hacia un pipeline distinto). Puentear pipelines es el rasgo definitorio del connector; un processor nunca abandona su pipeline.

**Síntesis**

- **S.1** `memory_limiter` primero para que, bajo carga, el Collector rechace/limite datos antes de gastar CPU en transformación, protegiéndose de un OOM. `batch` último para que el batching agrupe la forma *final* de los datos justo antes de la exportación, maximizando el throughput y sin re-batchear después de cada mutación.
- **S.2** Si `redaction` corre después de que `spanmetrics` ya exportó, las métricas derivadas (y cualquier exemplar) podrían llevar PII/secretos sin enmascarar hacia el backend de métricas antes de que redaction tocara las traces — el secreto se filtra por la ruta de *métricas*. El enmascaramiento debe ocurrir aguas arriba de cada exporter/connector que pueda copiar el valor.
- **S.3** (1) El processor metricstransform está ubicado **después** del exporter/connector que emite la métrica, o no está en ese pipeline de métricas en absoluto, así que el renombrado nunca corre antes de la exportación. (2) Hay **dos pipelines** y el renombrado está solo en uno, mientras que la métrica llega al backend a través del otro pipeline (sin modificar). En cualquier caso, el transform no está en la ruta que la métrica exportada efectivamente recorre.

</details>