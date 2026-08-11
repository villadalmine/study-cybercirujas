# OTCA 2.4 — Señales: Trazas, Métricas, Logs (Ejercicios Guiados)

Una **señal** en OpenTelemetry es una categoría de telemetría con su propio modelo de datos, API y ruta de SDK, pero todas las señales comparten el mismo envoltorio contenedor: un **Resource** (la entidad que produce los datos — un servicio, host, contenedor) contiene uno o más **InstrumentationScopes** (la librería/módulo que emitió los datos), que contienen los registros de señal en sí (`Span`, `Metric`, `LogRecord`). Entender ese envoltorio es lo que te permite *correlacionar* las tres señales más adelante.

Estos ejercicios usan solamente el stack OpenTelemetry neutral respecto al proveedor — el **Collector** (`otelcol-contrib`), el generador de carga **`telemetrygen`**, y **OTLP** crudo sobre HTTP — así que nada de esto depende de un backend de un proveedor.

> Fuentes:
> - Trazas — https://opentelemetry.io/docs/concepts/signals/traces/
> - Métricas — https://opentelemetry.io/docs/concepts/signals/metrics/
> - Logs — https://opentelemetry.io/docs/concepts/signals/logs/
> - Protocolo OTLP — https://opentelemetry.io/docs/specs/otlp/
> - W3C Trace Context — https://www.w3.org/TR/trace-context/

---

## Ejercicio 0 — Levantar un Collector (setup compartido)

Cada ejercicio de abajo envía OTLP a un Collector local cuyo único trabajo es imprimir lo que recibe, con todo el detalle, a la consola mediante el exporter `debug`.

1. Creá `otelcol.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch:

   exporters:
     debug:
       verbosity: detailed          # print full Resource/Scope/record detail
     prometheus:                    # used only in Exercise 2
       endpoint: 0.0.0.0:8889

   service:
     pipelines:
       traces:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug]
       metrics:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug, prometheus]
       logs:
         receivers:  [otlp]
         processors: [batch]
         exporters:  [debug]
   ```

2. Ejecutá el Collector (Docker mantiene tu host limpio; se publican los dos puertos OTLP y el puerto de scrape de Prometheus):

   ```bash
   docker run --rm --name otelcol \
     -p 4317:4317 -p 4318:4318 -p 8889:8889 \
     -v "$(pwd)/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:latest \
     --config /etc/otelcol/config.yaml
   ```

3. Confirmá que está escuchando. En otra terminal:

   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4318/v1/traces -X POST -H "Content-Type: application/json" -d '{}'
   ```

   Esperado: `200`.

4. Instalá el generador de carga (una toolchain de Go te da el binario directamente; de lo contrario usá la imagen `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen`):

   ```bash
   go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
   telemetrygen --help | head -n 5
   ```

**Comprobación de comprensión**

- Q0.1 — El Collector expone gRPC en `4317` y HTTP en `4318`. Ambos hablan "OTLP". ¿Cuál es el *único* protocolo acá, y cuáles son las dos cosas que difieren entre esos puertos?
- Q0.2 — En el paso 3 hiciste POST de un `{}` vacío y obtuviste `200`. ¿Por qué eso no es prueba de que una traza real sería aceptada y exportada correctamente?
- Q0.3 — `verbosity: detailed` en el exporter `debug` — ¿qué cambia respecto al valor por defecto `basic`, y por qué *nunca* dejarías `detailed` activado en producción?

---

## Ejercicio 1 — Trazas: la anatomía de un span

Una **traza** es un DAG de **spans** que comparten un único `TraceId` de 128 bits. Cada span tiene su propio `SpanId` de 64 bits, un `ParentId` opcional, un `Kind`, una marca de tiempo de inicio/fin, un `Status`, `Attributes`, `Events` y `Links`. `telemetrygen` emite una traza canónica de dos spans: un span `CLIENT` (`lets-go`) que es el padre de un span `SERVER` (`okey-dokey-0`).

1. Enviá exactamente una traza:

   ```bash
   telemetrygen traces \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 1
   ```

2. Leé la consola del Collector. Vas a ver algo parecido a:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
       Parent ID      :
       ID             : 1a2b3c4d5e6f7a8b
       Name           : lets-go
       Kind           : Client
       Start time     : 2026-08-10 12:00:00.001 +0000 UTC
       End time       : 2026-08-10 12:00:00.124 +0000 UTC
       Status code    : Unset
   Span #1
       Trace ID       : 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
       Parent ID      : 1a2b3c4d5e6f7a8b
       ID             : 9f8e7d6c5b4a3210
       Name           : okey-dokey-0
       Kind           : Server
       Status code    : Unset
   Attributes:
        -> net.peer.ip: Str(1.2.3.4)
        -> peer.service: Str(telemetrygen-server)
   ```

3. Fijate en tres hechos de la salida: (a) ambos spans comparten un único `Trace ID`; (b) `Span #0` tiene un `Parent ID` vacío; (c) el `Parent ID` de `Span #1` es igual al `ID` de `Span #0`.

4. Ahora forzá un status de error y agregá más spans por traza:

   ```bash
   telemetrygen traces \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --traces 1 --status-code Error --child-spans 3
   ```

   Observá la línea `Status code : Error` en el span afectado.

**Comprobación de comprensión**

- Q1.1 — `Span #0` (`lets-go`) tiene un `Parent ID` vacío. ¿Cómo llamamos a un span sin padre, y qué te dice eso sobre dónde se inició la traza?
- Q1.2 — El hijo (`okey-dokey-0`) es `Kind: Server` y el padre (`lets-go`) es `Kind: Client`. Nombrá los cinco kinds de span y explicá qué hace que `CLIENT`/`SERVER` sean un *par* frente a `PRODUCER`/`CONSUMER`.
- Q1.3 — Para un span sano el `Status code` es `Unset`, no `Ok`. ¿Por qué la especificación distingue `Unset` de `Ok`, y quién está autorizado a establecer `Ok`?
- Q1.4 — Cuando el span `SERVER` se creó dentro del servicio downstream, ¿cómo se enteró ese servicio del `TraceId` y del `SpanId` del padre? Nombrá el estándar de propagación y el header HTTP exacto, y dá el significado de cada uno de sus cuatro campos separados por guiones.
- Q1.5 — Necesitás modelar un fan-in: un span causado por *muchas* operaciones upstream (ej.: un job batch procesando 100 mensajes). `ParentId` solo contiene un valor. ¿Qué característica de span expresa las otras 99 relaciones causales?

---

## Ejercicio 2 — Métricas: instrumentos y temporalidad

Una métrica es producida por un **instrumento**. El *kind* del instrumento fija su semántica: `Counter` (suma monotónica), `UpDownCounter` (suma no monotónica), `Histogram` (distribución), `Gauge` (último valor), más las variantes **asíncronas** (Observable) manejadas por callbacks. El SDK luego agrega los data points con una **temporalidad** — **cumulative** (valor desde el inicio) o **delta** (valor desde el export anterior). Prometheus es un sistema cumulative; este ejercicio lo hace concreto.

1. Enviá una métrica `Sum` monotónica llamada `gen`:

   ```bash
   telemetrygen metrics \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --metric-type Sum --metrics 5
   ```

2. En la salida `debug`, encontrá el descriptor y confirmá las dos propiedades que definen una suma estilo `Counter`:

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Sum
   IsMonotonic: true
   AggregationTemporality: Cumulative
   NumberDataPoints #0
   Data point attributes:
        -> foo: Str(bar)
   Value: 5
   ```

3. Ahora leé la *misma* métrica a través del exporter de Prometheus, que se scrapea, no se pushea:

   ```bash
   curl -s http://localhost:8889/metrics | grep -A1 '^# TYPE gen'
   ```

   Forma esperada:

   ```
   # TYPE gen_total counter
   gen_total{foo="bar"} 5
   ```

4. Compará un `Gauge` con el `Sum`:

   ```bash
   telemetrygen metrics \
     --otlp-endpoint localhost:4317 --otlp-insecure \
     --metric-type Gauge --metrics 1
   ```

   Notá que el descriptor ahora dice `DataType: Gauge` **sin** `IsMonotonic` y **sin** línea `AggregationTemporality`.

**Comprobación de comprensión**

- Q2.1 — El descriptor `Sum` imprimió `IsMonotonic: true` y `AggregationTemporality: Cumulative`; el `Gauge` no imprimió ninguno de los dos campos. Explicá por qué *la temporalidad no tiene sentido para un Gauge*.
- Q2.2 — En el paso 3 el exporter de Prometheus renombró `gen` a `gen_total` y lo tipó como `counter`. ¿Qué regla motivó el sufijo `_total`, y qué le señala el sufijo a quien escribe una query de Prometheus?
- Q2.3 — Querés registrar la *latencia* de requests y más tarde computar p50/p95/p99 en el backend. ¿Qué instrumento elegís, y qué tres familias de data points lleva un único data point de `Histogram` de OTLP que hacen posible la estimación de percentiles?
- Q2.4 — Tenés un `Counter` y querés observar el número de conexiones a base de datos *actualmente activas* (un valor que sube y baja). ¿Por qué `Counter` está mal acá, y cuáles dos instrumentos (uno sync, uno async) son correctos — y cómo elegís entre ellos?
- Q2.5 — Tu backend solo acepta temporalidad **delta**, pero tu SDK usa cumulative por defecto. En lugar de re-instrumentar la app, ¿en qué parte del pipeline podés convertir, y qué estado debe mantener en memoria ese componente de conversión para lograrlo — y qué se rompe si ese componente reinicia?

---

## Ejercicio 3 — Logs: el LogRecord y el modelo de severidad

OpenTelemetry trata a los logs como una señal de primera clase con un **LogRecord** estructurado: `Timestamp`, `ObservedTimestamp`, `SeverityNumber` (1–24), `SeverityText`, un `Body` tipado, `Attributes`, y — crucialmente — campos `TraceId`/`SpanId`/`TraceFlags` para correlación. Acá emitís un LogRecord a mano sobre OTLP/HTTP para que puedas ver cada campo, y después lo leés de vuelta.

1. Creá `log.json`. Notá el `severityNumber: 17` numérico (el comienzo del rango `ERROR`) y el `traceId`/`spanId` codificados en hexadecimal:

   ```json
   {
     "resourceLogs": [{
       "resource": {
         "attributes": [
           { "key": "service.name", "value": { "stringValue": "checkout" } }
         ]
       },
       "scopeLogs": [{
         "scope": { "name": "manual-test" },
         "logRecords": [{
           "timeUnixNano": "1754827200000000000",
           "severityNumber": 17,
           "severityText": "ERROR",
           "body": { "stringValue": "payment gateway timeout after 3 retries" },
           "attributes": [
             { "key": "http.response.status_code", "value": { "intValue": 504 } },
             { "key": "retry.count", "value": { "intValue": 3 } }
           ],
           "traceId": "7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c",
           "spanId": "1a2b3c4d5e6f7a8b"
         }]
       }]
     }]
   }
   ```

2. Envialo al endpoint de logs OTLP/HTTP:

   ```bash
   curl -s http://localhost:4318/v1/logs \
     -H "Content-Type: application/json" \
     -d @log.json
   ```

   Respuesta esperada: `{"partialSuccess":{}}` (un partial-success vacío significa que todo fue aceptado).

3. Leé la consola del Collector:

   ```
   ResourceLog #0
   Resource attributes:
        -> service.name: Str(checkout)
   ScopeLogs #0
   InstrumentationScope manual-test
   LogRecord #0
   ObservedTimestamp: 2026-08-10 12:00:07.512 +0000 UTC
   Timestamp: 2026-08-10 12:00:00 +0000 UTC
   SeverityText: ERROR
   SeverityNumber: Error(17)
   Body: Str(payment gateway timeout after 3 retries)
   Attributes:
        -> http.response.status_code: Int(504)
        -> retry.count: Int(3)
   Trace ID: 7d3d1e6a2b9c4f0a8e5c1b2d3a4f5e6c
   Span ID: 1a2b3c4d5e6f7a8b
   ```

4. Reenvialo con `"timeUnixNano"` quitado del registro y observá que `Timestamp` queda vacío mientras que `ObservedTimestamp` sigue siendo poblado por el Collector.

**Comprobación de comprensión**

- Q3.1 — Tu registro estableció `Timestamp` explícitamente, pero el Collector también imprimió un `ObservedTimestamp` *diferente*. Definí ambos, y describí el escenario del mundo real en el que difieren legítimamente por minutos.
- Q3.2 — `severityNumber` era `17` y `severityText` era `"ERROR"`. La especificación define `SeverityNumber` como un rango 1–24 agrupado en seis bandas. ¿Cuál es el sentido del campo numérico cuando ya tenemos el `SeverityText` de texto libre, y qué banda abre `17`?
- Q3.3 — En el paso 1 el `traceId`/`spanId` están escritos como strings **hexadecimales**, sin embargo OTLP/Protobuf define esos campos como `bytes`. ¿Qué regla especial en la codificación OTLP/JSON hace que hexadecimal sea correcto acá (y por qué base64 también sería aceptado por el receptor pero *no* es la forma canónica para esos dos campos)?
- Q3.4 — El `Body` usó `stringValue`, pero el campo es un `AnyValue`. Dá una ventaja concreta de enviar un body *estructurado* (un `kvlistValue`) en lugar de un string pre-formateado, desde el punto de vista de un backend que indexa logs.

---

## Ejercicio 4 — Correlación: uniendo las tres señales

El premio del envoltorio compartido: un único incidente puede pivotearse entre señales. Dos mecanismos hacen la unión — el **Resource** (un mismo `service.name`/`service.instance.id` liga las trazas, métricas y logs de un servicio) y el **trace context** (`TraceId`/`SpanId` en un LogRecord, y **exemplars** en una métrica, ambos apuntan de vuelta a un span específico).

1. Emití una traza y capturá su `Trace ID` desde la consola del Collector:

   ```bash
   telemetrygen traces --otlp-endpoint localhost:4317 --otlp-insecure --traces 1
   ```

2. Editá el `log.json` del Ejercicio 3 para que su `traceId` coincida con el `Trace ID` que acabás de ver, y su `spanId` coincida con uno de los `ID`s de span de esa traza. También establecé el `service.name` del log en `telemetrygen` para que coincida con el Resource de la traza. Reenvialo (paso 2 del Ejercicio 3).

3. Ahora produjiste un log que es unible a un span en *dos* ejes independientes. Razoná sobre qué eje usa una query en cada uno de estos casos:
   - "Mostrame cada línea de log, a través de todos los servicios, emitida mientras el span `1a2b3c4d5e6f7a8b` estaba activo."
   - "Mostrame la métrica de tasa de requests de este servicio junto a sus logs de error de la última hora."

4. (Concepto) Un data point de métrica puede llevar un **exemplar** — una tupla muestreada `(value, TraceId, SpanId, timestamp)`. Imaginá un `Histogram` de latencia cuyo bucket p99 lleva un exemplar. Trazá el recorrido de clics que un operador sigue desde un gráfico de p99 en pico hasta el único request lento.

**Comprobación de comprensión**

- Q4.1 — Arriba se usaron dos ejes de correlación: el **Resource** y el **trace context**. Emparejá cada una de las dos queries del paso 3 con el eje del que depende, y explicá por qué la query *entre servicios* no puede usar el Resource.
- Q4.2 — Definí un **exemplar** y explicá por qué es el puente desde el mundo *agregado* de las métricas (donde los requests individuales se pierden en la agregación) de vuelta al mundo *por-request* de las trazas.
- Q4.3 — Un colega propone correlacionar logs con trazas escribiendo el trace id en el texto del **body** del log (`"... traceId=7d3d..."`) en lugar del campo `TraceId` dedicado. Dá dos razones operativas concretas de por qué eso es inferior.
- Q4.4 — Las tres señales de un servicio deben coincidir en `service.name` para que la correlación basada en Resource funcione. En el SDK, *dónde* se garantiza que sea idéntico entre señales en lugar de establecerse tres veces?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0
- **Q0.1** — El único protocolo es **OTLP** (OpenTelemetry Protocol). Los puertos difieren en (1) **transporte/codificación**: `4317` es OTLP/gRPC (HTTP/2 + Protobuf), `4318` es OTLP/HTTP (body Protobuf *o* JSON); y (2) la **forma de la request**: gRPC usa métodos de servicio (`Export`), HTTP usa rutas específicas por señal (`/v1/traces`, `/v1/metrics`, `/v1/logs`). Semánticamente el payload es el mismo modelo de datos OTLP.
- **Q0.2** — Un `200` sobre un `{}` vacío solo prueba que el endpoint es alcanzable y que el JSON parsea; no contiene spans, así que nada se valida sobre la estructura real de un ResourceSpans/Span, la codificación de atributos, o el pipeline del exporter. Alcanzabilidad ≠ corrección; hay que enviar telemetría real y leerla de vuelta (como hacen los ejercicios posteriores).
- **Q0.3** — `basic` imprime un resumen de una línea (conteos de resource spans/metrics/logs). `detailed` imprime los atributos completos del Resource, el InstrumentationScope, y todos los campos de cada registro. Nunca corrés `detailed` en producción porque serializa y escribe *cada* registro al log — I/O y volumen de logs enormes, y re-emite atributos potencialmente sensibles a stdout. Es una herramienta de debugging solamente.

### Ejercicio 1
- **Q1.1** — Un span sin padre es el **root span**. Marca dónde *empezó* la traza en este sistema — típicamente el primer servicio en recibir una request sin trazar (generó un `TraceId` nuevo), o el proceso que inició el workflow.
- **Q1.2** — Los cinco kinds: **INTERNAL, SERVER, CLIENT, PRODUCER, CONSUMER**. `CLIENT`/`SERVER` son un par de RPC **síncrono**: el cliente se bloquea esperando la respuesta del servidor, así que los dos spans se solapan en el tiempo y son directamente padre/hijo a través del cable. `PRODUCER`/`CONSUMER` son un par de mensajería **asíncrono**: el producer encola y retorna inmediatamente, el consumer corre más tarde (posiblemente mucho más tarde), así que usualmente se unen por un **Link** en lugar de una relación estrecha de temporización padre/hijo. `INTERNAL` es trabajo sin frontera remota.
- **Q1.3** — `Unset` significa "la instrumentación no hizo ninguna afirmación" — el valor por defecto, y el estado normal de un span exitoso. `Ok` es una **sobreescritura explícita** reservada para que el *desarrollador de la aplicación* fuerce el éxito incluso cuando un backend podría inferir error de otra forma; las librerías de instrumentación no deben establecer `Ok`. Distinguirlos permite que las herramientas traten "sin opinión" de forma diferente a "el desarrollador afirma que esto está bien".
- **Q1.4** — **W3C Trace Context**, transportado en el header HTTP **`traceparent`**. Sus cuatro campos separados por guiones son: `version` (`00`), `trace-id` (32 hex / 16 bytes), `parent-id` es decir el span id del que llama (16 hex / 8 bytes), y `trace-flags` (2 hex; el bit 0 es la flag `sampled`). El servicio downstream parsea `traceparent`, reutiliza el `trace-id`, y establece el padre de su nuevo span SERVER en el `parent-id` entrante.
- **Q1.5** — **Span Links**. Un link referencia a otro span (su `SpanContext`) sin una relación de temporización padre/hijo, así que un span puede apuntar de vuelta a los muchos spans upstream que lo causaron — el caso canónico de batch/fan-in.

### Ejercicio 2
- **Q2.1** — La temporalidad responde "¿sobre qué intervalo de tiempo se acumula este número?" Un **Gauge** es una muestra de *último valor* — una lectura instantánea (ej.: temperatura actual, profundidad de cola actual). No hay intervalo sobre el cual acumular, así que cumulative-vs-delta es indefinido; solo las sumas y los histogramas (que acumulan) llevan un `AggregationTemporality`.
- **Q2.2** — Convenciones de nombres de Prometheus: un counter que crece monotónicamente se expone con un sufijo **`_total`** y TYPE `counter`. Le dice a quien escribe la query que este valor solo sube (se resetea a 0 al reiniciar), así que hay que envolverlo en `rate()`/`increase()` en lugar de leer el valor crudo.
- **Q2.3** — Elegí un **Histogram**. Un único data point de histograma OTLP lleva: (1) el `count` y `sum` de todos los valores registrados, (2) los **límites de bucket** explícitos (`explicit_bounds`), y (3) los **`bucket_counts`** por bucket. A partir de los límites + conteos el backend interpola percentiles. (La variante de histograma exponencial/nativo lleva scale + offsets de bucket en lugar de límites explícitos.)
- **Q2.4** — Un `Counter` es **monotónico**; solo se le puede sumar, así que no puede representar un valor que decrece (las conexiones activas bajan cuando una conexión se cierra). Opciones correctas: **`UpDownCounter`** (síncrono — hacés `Add(+1)` al abrir, `Add(-1)` al cerrar, cuando sos dueño de esos eventos) o **`ObservableGauge`/`ObservableUpDownCounter`** (asíncrono — un callback lee el tamaño actual del pool en cada colección). Usá el UpDownCounter síncrono cuando los eventos de cambio pasan por tu código; usá el observable async cuando solo podés *sondear* el valor actual desde una fuente externa.
- **Q2.5** — Convertí en el **Collector**, no en la app: el processor `cumulativetodelta`. Debe retener, en memoria, el **valor cumulative anterior para cada serie temporal (cada conjunto único de atributos)** para poder restar y producir el delta. Al reiniciar ese estado se pierde, así que el primer export tras el reinicio no tiene punto previo contra el cual diferenciar — el primer delta de esa serie se descarta (o se computa mal), una brecha conocida de la conversión con estado.

### Ejercicio 3
- **Q3.1** — `Timestamp` es cuándo el evento *ocurrió realmente* (establecido por la fuente). `ObservedTimestamp` es cuándo el pipeline de OpenTelemetry *lo vio por primera vez*. Divergen cuando los logs se recolectan fuera de banda — ej.: un **tailer de archivos/logs** leyendo un archivo de log que se escribió hace minutos (backlog, rotación, el archivo de un pod caído scrapeado a posteriori): el tiempo del evento es viejo, el tiempo observado es ahora.
- **Q3.2** — `SeverityText` es texto libre del proveedor (`"warn"`, `"WARNING"`, `"W"`, `"Warn"` — todos strings diferentes). `SeverityNumber` es un **ordinal 1–24 normalizado** para que los backends puedan *filtrar y comparar* severidad de forma consistente sin importar la redacción de la fuente (`severity >= 17` == "errores y peores"). `17` abre la banda **ERROR** (`ERROR` = 17–20; las bandas son TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24).
- **Q3.3** — OTLP/JSON sigue el mapeo JSON de proto3, bajo el cual los campos `bytes` son base64. Pero la especificación de OTLP hace una **excepción especial: `trace_id` y `span_id` se codifican como strings hexadecimales en minúscula insensibles a mayúsculas** (porque así es como los humanos y W3C Trace Context ya los representan). Un receptor también puede aceptar base64 para otros campos `bytes`, pero para estos dos la forma canónica, mandada por la especificación, es hexadecimal — enviá base64 ahí y arriesgás que un receptor lo rechace o lo decodifique mal.
- **Q3.4** — Un body `kvlistValue` estructurado mantiene los campos **individualmente tipados e indexables** — el backend puede indexar/filtrar por `order_id` o `amount` directamente, sin parsear con regex un string formateado. También evita ambigüedad y deriva de locale/formato, y sobrevive a cambios en la plantilla del mensaje. Un string pre-formateado obliga al backend a re-extraer campos que se le entregaron estructurados en primer lugar.

### Ejercicio 4
- **Q4.1** — La primera query ("todos los logs mientras el span X estaba activo") usa el eje **trace-context** (`SpanId`), porque abarca *múltiples servicios* — el Resource difiere por servicio, así que solo los ids de traza/span compartidos pueden unirlos. La segunda query ("la métrica de este servicio junto a sus logs de error") usa el eje **Resource** (`service.name`), porque ambas señales vienen del *mismo* servicio y estás pivoteando por identidad de servicio, no por un único request. La query entre servicios no puede usar el Resource precisamente porque cada servicio tiene su propio Resource distinto.
- **Q4.2** — Un **exemplar** es una medición de ejemplo muestreada adjunta a un data point de métrica, que registra el `value` crudo junto con el `TraceId`/`SpanId` (y timestamp) que estaban activos cuando fue registrado. La agregación (un bucket de histograma, un counter) descarta la identidad de los requests individuales; el exemplar preserva un *puntero* desde un bucket agregado de vuelta a un span real, así que un operador puede saltar de "el agregado se ve mal" a "acá hay un request específico que lo causó".
- **Q4.3** — (1) **No es consultable como clave de join** — el id queda enterrado en texto no estructurado, así que el backend debe raspar con regex cada línea en lugar de indexar un campo `TraceId` tipado; el linkeo automático traza↔log en la UI no se disparará. (2) Es **frágil y con pérdidas** — un cambio en la plantilla del mensaje, un truncamiento, o una línea de log que formatea el id de forma diferente rompe la correlación silenciosamente, y los `TraceFlags` dedicados (el bit sampled) se pierden por completo.
- **Q4.4** — En el **`Resource` compartido**: el SDK construye un único `Resource` (a partir de resource detectors + `OTEL_RESOURCE_ATTRIBUTES`/`service.name`) e inyecta la *misma* instancia en los tres providers (`TracerProvider`, `MeterProvider`, `LoggerProvider`). Como comparten ese único objeto Resource, `service.name` queda garantizado idéntico entre señales en lugar de tipearse tres veces y arriesgar deriva.

</details>