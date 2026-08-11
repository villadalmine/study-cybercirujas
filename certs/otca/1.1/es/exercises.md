# Ejercicios guiados — Tema 1.1: Datos de telemetría (OTCA)

Estos ejercicios construyen un pipeline de telemetría real en tu estación de trabajo y lo usan para diseccionar el modelo de datos de OpenTelemetry señal por señal. Vas a levantar un OpenTelemetry Collector como sink pasivo, enviarle telemetría sintética con `telemetrygen` y leer los payloads OTLP crudos que el Collector imprime. Leer payloads reales — en lugar de diagramas — es la forma en que los modelos de datos de span, métrica y log realmente dejan de ser abstractos.

**Fuentes de referencia**
- OTCA Curriculum — https://github.com/cncf/curriculum/raw/master/OTCA_Curriculum.pdf
- Resumen de señales — https://opentelemetry.io/docs/concepts/signals/
- Especificación de OTLP — https://opentelemetry.io/docs/specs/otlp/
- Especificación del modelo de datos (traces/metrics/logs) — https://opentelemetry.io/docs/specs/otel/

---

## Prerrequisitos

- Docker (o Podman) disponible para ejecutar el contenedor del Collector.
- Go ≥ 1.21 para instalar `telemetrygen`, **o** la capacidad de ejecutarlo desde una imagen de contenedor. Se muestran ambos caminos.
- Un `4317` (OTLP/gRPC) y un `4318` (OTLP/HTTP) libres en `localhost`.

> Todas las salidas esperadas a continuación están **abreviadas y son representativas** — los trace/span IDs, timestamps y el orden varían en cada ejecución. Enfocate en los *campos*, no en los valores literales.

---

## Ejercicio 1 — Levantar un Collector como sink de telemetría

El exporter `debug` del Collector (el componente antes llamado `logging`, renombrado en la v0.86.0 del Collector) escribe OTLP decodificado a stdout. Eso lo convierte en el microscopio ideal para observar datos de telemetría.

**Pasos**

1. Creá un directorio de trabajo y un archivo de configuración del Collector:

   ```bash
   mkdir -p ~/otca-1.1 && cd ~/otca-1.1
   ```

2. Escribí `config.yaml`:

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
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         exporters: [debug]
       metrics:
         receivers: [otlp]
         exporters: [debug]
       logs:
         receivers: [otlp]
         exporters: [debug]
   ```

3. Iniciá el Collector, montando la configuración:

   ```bash
   docker run --rm --name otelcol \
     -p 4317:4317 -p 4318:4318 \
     -v "$(pwd)/config.yaml:/etc/otelcol-contrib/config.yaml" \
     otel/opentelemetry-collector-contrib:latest
   ```

4. Confirmá que las tres pipelines se levantaron. En el log de arranque deberías ver el inicio del receiver y del exporter, y líneas similares a:

   ```
   info    service@v0.x.x/service.go   Everything is ready. Begin running and processing data.
   ```

5. Instalá `telemetrygen` (nativo), o tené presente la alternativa por contenedor usada en pasos posteriores:

   ```bash
   # Native install:
   go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
   # Container alternative (use --network host so localhost:4317 resolves):
   #   docker run --rm --network host \
   #     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
   #     traces --otlp-insecure --duration 2s
   ```

**Preguntas de comprensión**

- **Q1.1** — La configuración declara `otlp` bajo *receivers* y `debug` bajo *exporters*. En el modelo de pipeline de OpenTelemetry, ¿cuál es el rol direccional de cada uno, y cuál está *recibiendo* telemetría por la red acá?
- **Q1.2** — ¿Por qué hay tres `pipelines` separadas (`traces`, `metrics`, `logs`) en lugar de una? ¿Qué te dice esto sobre cómo OpenTelemetry trata internamente las distintas señales?
- **Q1.3** — El receiver expone tanto `4317` (gRPC) como `4318` (HTTP). Ambos hablan el mismo protocolo de transporte. ¿Cuál es ese protocolo, y qué formato de serialización usa por defecto?

---

## Ejercicio 2 — Traces: diseccionar un span

Un trace es un árbol de spans que comparten un mismo Trace ID. `telemetrygen traces` emite un pequeño grafo de llamadas client→server que podés leer campo por campo.

**Pasos**

1. Con el Collector todavía corriendo, en una segunda terminal enviá un único trace:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1
   ```

2. Cambiá a la terminal del Collector. Deberías ver un bloque `ResourceSpans`. Abreviado:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       Parent ID      :
       ID             : 00f067aa0ba902b7
       Name           : lets-go
       Kind           : Client
       Start time     : 2026-08-10 12:00:00.000000 +0000 UTC
       End time       : 2026-08-10 12:00:00.000123 +0000 UTC
       Status code    : Unset
   Span #1
       Trace ID       : 4bf92f3577b34da6a3ce929d0e0e4736
       Parent ID      : 00f067aa0ba902b7
       ID             : a1b2c3d4e5f60718
       Name           : okey-dokey-0
       Kind           : Server
       Status code    : Unset
   Attributes:
        -> net.peer.ip: Str(1.2.3.4)
        -> peer.service: Str(telemetrygen-server)
   ```

3. Identificá el **span raíz**: es aquel cuyo `Parent ID` está vacío. Fijate que ambos spans llevan el *mismo* `Trace ID`.

4. Emparejá el `Parent ID` del hijo con el `ID` de la raíz. Ese enlace es la arista padre-hijo del árbol del trace.

5. Aumentá el fan-out y volvé a ejecutar para ver múltiples traces, cada uno un árbol independiente:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3
   ```

**Preguntas de comprensión**

- **Q2.1** — Un Trace ID tiene 16 bytes (32 caracteres hex) y un Span ID tiene 8 bytes (16 caracteres hex). Dada la salida de arriba, ¿qué campo establece que el Span #1 es *hijo* del Span #0, y cómo reconstruye un backend el árbol completo a partir de un flujo plano de spans?
- **Q2.2** — El Span #0 tiene `Kind: Client` y el Span #1 tiene `Kind: Server`. Enumerá los cinco valores válidos de `SpanKind` y explicá por qué la *misma* operación lógica (una llamada HTTP) suele producir tanto un span Client como un span Server.
- **Q2.3** — Cada span lleva `Status code: Unset`. ¿Cuáles son los tres valores posibles de status de un span, y qué lado (la instrumentación o el backend) es responsable de establecer `Error`?
- **Q2.4** — El header `traceparent` de W3C Trace Context tiene la forma `00-<trace-id>-<parent-id>-<flags>`. Usando los valores del Span #1, escribí el header `traceparent` que el server habría recibido. (Asumí muestreado, `flags = 01`.)

---

## Ejercicio 3 — Metrics: instrumentos, data points y temporalidad

El modelo de datos de metrics es donde los candidatos de OTCA más suelen perder puntos. `telemetrygen metrics` te permite emitir cada tipo de dato central y observar cómo lo renderiza el Collector.

**Pasos**

1. Emití una **Sum** monotónica (el tipo de dato que produce un Counter):

   ```bash
   telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
     --metric-type Sum --metrics 1
   ```

   Salida del Collector (abreviada):

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Sum
        -> IsMonotonic: true
        -> AggregationTemporality: Cumulative
   NumberDataPoints #0
   StartTimestamp: 2026-08-10 12:00:00 +0000 UTC
   Timestamp:      2026-08-10 12:00:05 +0000 UTC
   Value: 1
   ```

2. Ahora emití un **Gauge**:

   ```bash
   telemetrygen metrics --otlp-insecure --otlp-endpoint localhost:4317 \
     --metric-type Gauge --metrics 1
   ```

   ```
   Metric #0
   Descriptor:
        -> Name: gen
        -> DataType: Gauge
   NumberDataPoints #0
   Timestamp: 2026-08-10 12:00:10 +0000 UTC
   Value: 42
   ```

3. Compará los dos descriptores con cuidado. Fijate qué campos están presentes en la Sum pero **ausentes** en el Gauge (`IsMonotonic`, `AggregationTemporality`, `StartTimestamp`).

4. (Conceptual) Un data point de **Histogram** se renderiza con `Count`, `Sum`, `ExplicitBounds` y `BucketCounts` por bucket, en lugar de un único `Value`. Bosquejá en papel qué llevaría un histograma de latencia de peticiones con bounds `[5, 10, 25, 50, 100]` ms tras observar las latencias `4, 8, 8, 30, 200` ms.

**Preguntas de comprensión**

- **Q3.1** — El descriptor de la Sum muestra `AggregationTemporality: Cumulative`. Contrastá la temporalidad **Cumulative** vs. **Delta**: para un Counter observado en t=1s (valor 10) y t=2s (valor 25), ¿qué reporta cada data point bajo cada temporalidad?
- **Q3.2** — El Gauge no tiene `StartTimestamp` ni `AggregationTemporality`. ¿Por qué esos campos carecen de sentido para un Gauge pero son esenciales para una Sum?
- **Q3.3** — Nombrá los seis **instrumentos de API** síncronos/asíncronos (Counter, UpDownCounter, Histogram, Gauge, y las variantes observables) y mapeá cada uno al **tipo de dato** que produce en el modelo de datos de OTLP (Sum / Gauge / Histogram).
- **Q3.4** — Para el histograma del paso 4, completá `Count`, `Sum` y `BucketCounts` (seis buckets: cinco acotados + uno de overflow). ¿En qué único bucket cae la observación de `200 ms`?

---

## Ejercicio 4 — Logs y correlación con traces

Un `LogRecord` de OpenTelemetry es una señal de primera clase con una estructura definida — no apenas una línea de texto. Su poder viene de llevar el *mismo* Trace ID y Span ID que el span que estaba activo cuando fue emitido.

**Pasos**

1. Enviá un lote de log records:

   ```bash
   telemetrygen logs --otlp-insecure --otlp-endpoint localhost:4317 --logs 2
   ```

2. Leé los bloques `LogRecord` (abreviados):

   ```
   LogRecord #0
   ObservedTimestamp: 2026-08-10 12:00:00 +0000 UTC
   Timestamp:         2026-08-10 12:00:00 +0000 UTC
   SeverityText:      Info
   SeverityNumber:    Info(9)
   Body:              Str(the message)
   Attributes:
        -> app: Str(server)
   Trace ID:
   Span ID:
   ```

3. Notá que los log records independientes de arriba tienen `Trace ID` / `Span ID` **vacíos** — fueron emitidos sin ningún span activo. En código instrumentado real, un log emitido dentro de un span se estampa automáticamente con el contexto de ese span.

4. Compará los dos campos de timestamp: `Timestamp` (cuándo *ocurrió* el evento) vs. `ObservedTimestamp` (cuándo lo *vio* la capa de recolección). Difieren cuando los logs se recolectan desde archivos a posteriori.

5. Localizá el `SeverityNumber: Info(9)`. Mapealo contra los rangos numéricos de severidad para entender por qué `9` significa «Info».

**Preguntas de comprensión**

- **Q4.1** — `SeverityText` es un string de forma libre (`"Info"`, `"WARNING"`, `"emerg"`), pero `SeverityNumber` está normalizado de 1 a 24. Dá el rango numérico de cada una de las seis clases de severidad (TRACE, DEBUG, INFO, WARN, ERROR, FATAL). ¿Por qué la spec define un número normalizado *además del* texto?
- **Q4.2** — ¿Qué dos campos de un `LogRecord` habilitan la **correlación log↔trace**, y qué debe ser verdad en el momento de la emisión para que se completen? ¿Por qué es imposible reconstruir esta correlación de forma confiable si solo enviás los logs como líneas de texto plano?
- **Q4.3** — Explicá un escenario concreto donde `Timestamp` y `ObservedTimestamp` divergen legítimamente, y por cuál ordenarías al investigar un incidente.

---

## Ejercicio 5 — Resource, atributos y convenciones semánticas

Cada señal de los ejercicios anteriores estaba envuelta en un `Resource` (`service.name: telemetrygen`). El Resource identifica *qué* produjo la telemetría; las convenciones semánticas hacen que los nombres de atributos sean portables entre distintos proveedores. Este ejercicio también traza la línea entre los atributos y el **Baggage**.

**Pasos**

1. Sobreescribí el `service.name` del Resource y agregá un atributo de telemetría personalizado:

   ```bash
   telemetrygen traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 1 \
     --otlp-attributes 'service.name="checkout"' \
     --telemetry-attributes 'tenant="acme"'
   ```

2. En la salida del Collector, confirmá la división:

   ```
   ResourceSpans #0
   Resource attributes:
        -> service.name: Str(checkout)      # ← Resource-level (the producer)
   ...
   Span #0
   Attributes:
        -> tenant: Str(acme)                 # ← Span-level (this operation)
   ```

3. Fijate en la ubicación: `service.name` está bajo **Resource attributes** (aplica a *cada* span/metric/log de este servicio), mientras que `tenant` está bajo los `Attributes` propios del **Span** (aplica a esa única operación).

4. Cotejá `service.name`, `net.peer.ip` y `peer.service` contra el registro de Semantic Conventions de OpenTelemetry (https://opentelemetry.io/docs/specs/semconv/) para confirmar que están estandarizados, no inventados por cada equipo.

5. (Conceptual) El **Baggage** es un mecanismo aparte: pares clave-valor propagados a través del header `baggage` de W3C junto con `traceparent`, para que los servicios downstream puedan *leer* contexto establecido upstream. El Baggage **no** se escribe automáticamente en los spans como atributos — copiarlo requiere un processor explícito o código.

**Preguntas de comprensión**

- **Q5.1** — Distinguí los **Resource attributes** de los **atributos de span/metric/log** por alcance y ciclo de vida. ¿Por qué `service.name` es un Resource attribute y no uno por span?
- **Q5.2** — ¿Qué problema resuelven las **convenciones semánticas** para un backend que ingiere telemetría de docenas de servicios instrumentados de forma independiente? Dá un atributo de ejemplo y qué se rompería si cada equipo lo nombrara libremente.
- **Q5.3** — El **Baggage** viaja sobre la misma propagación de contexto que el trace context pero es un concepto *distinto*, adyacente a las señales. Indicá (a) para qué sirve el Baggage, y (b) el error común de seguridad/costo de asumir que los valores de Baggage aparecen automáticamente como atributos de span.
- **Q5.4** — `service.name` es el único Resource attribute que la spec trata como requerido. ¿Cuál es el valor de fallback definido si la instrumentación no lo establece, y por qué un `service.name` faltante/duplicado degrada el mapa de servicios de un backend?

---

## Limpieza

```bash
docker stop otelcol
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**A1.1** — En la pipeline del Collector, un **receiver** ingiere telemetría *hacia adentro* del Collector y un **exporter** envía telemetría *hacia afuera*. Acá el receiver `otlp` está recibiendo datos por la red (gRPC/HTTP), y el exporter `debug` los «exporta» a stdout como texto decodificado. Los datos fluyen receiver → (processors) → exporter.

**A1.2** — OpenTelemetry modela **traces, metrics y logs como tres señales distintas**, cada una con su propio modelo de datos, representación de transporte y pipeline. Una pipeline está tipada por señal: una pipeline `traces` solo puede transportar spans, una pipeline `metrics` solo data points de métricas, etc. Esta separación es la razón por la que un componente (receiver/processor/exporter) debe declarar qué señales soporta.

**A1.3** — El protocolo es **OTLP** (OpenTelemetry Protocol). Su codificación canónica es **Protocol Buffers**; OTLP/gRPC siempre usa protobuf, y OTLP/HTTP usa por defecto protobuf binario (`application/x-protobuf`) con una codificación JSON opcional. El puerto 4317 es OTLP/gRPC, el 4318 es OTLP/HTTP.

### Ejercicio 2

**A2.1** — El campo **`Parent ID` del Span #1 es igual al `ID` del Span #0**; esa referencia hacia atrás es la arista padre-hijo. Un backend agrupa todos los spans que comparten un mismo **Trace ID**, y luego reconstruye el árbol enlazando cada span con el span cuyo `ID` coincide con su `Parent ID`. La raíz es el span con `Parent ID` vacío. Como el enlace se transporta *en cada span*, el flujo puede llegar desordenado y aun así reensamblarse.

**A2.2** — Los cinco valores de `SpanKind` son **INTERNAL, SERVER, CLIENT, PRODUCER, CONSUMER**. Una única llamada remota produce dos spans porque ambos lados la instrumentan: el que llama registra un span **CLIENT** (el tiempo esperando la respuesta, incluida la red), y el que recibe registra un span **SERVER** (el tiempo manejando la petición). El span CLIENT es el padre del span SERVER a través del trace context propagado. PRODUCER/CONSUMER son los análogos para mensajería asíncrona.

**A2.3** — Los tres valores de status de un span son **Unset**, **Ok** y **Error**. `Unset` es el valor por defecto y significa «sin juicio explícito». La instrumentación (el SDK/la aplicación), no el backend, establece `Error` cuando la operación falló; los backends no deben inferirlo. `Ok` se establece solo para anular explícitamente una heurística — la mayoría de los spans exitosos se dejan en `Unset`.

**A2.4** — Usando el Span #1 (`Trace ID = 4bf92f3577b34da6a3ce929d0e0e4736`, su propio `ID = a1b2c3d4e5f60718`) — pero el header que el server *recibió* lleva el span ID **del padre** (`00f067aa0ba902b7`):

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

`00` = versión, luego el trace-id, luego el span-id de quien llama, luego `01` = flag de muestreado. (El server genera `a1b2c3d4e5f60718` localmente como su propio span ID; no está en el header entrante.)

### Ejercicio 3

**A3.1** — Bajo temporalidad **Cumulative** cada data point reporta el total acumulado desde `StartTimestamp`: t=1s → `10`, t=2s → `25`. Bajo temporalidad **Delta** cada punto reporta solo el cambio en su propio intervalo: t=1s → `10`, t=2s → `15` (25−10). Cumulative es resiliente a data points perdidos y es el valor por defecto de OTLP para muchos exporters; Delta es más barato de agregar sin estado, pero un único punto perdido pierde ese incremento de forma permanente.

**A3.2** — Un Gauge es una medición **instantánea, no aditiva** (p. ej., la temperatura actual o la profundidad de una cola). No hay intervalo sobre el cual acumular, así que `AggregationTemporality` no está definido, y no hay «inicio» de una acumulación, así que `StartTimestamp` carece de sentido. Una Sum acumula a lo largo del tiempo, así que ambos campos son necesarios para interpretar su `Value` (un total *relativo al* inicio, agregado *de forma acumulada o como delta*).

**A3.3** — Mapeo instrumento → tipo de dato:
- **Counter** (sync) → Sum, monotónico
- **UpDownCounter** (sync) → Sum, no monotónico
- **Histogram** (sync) → Histogram
- **Gauge** (sync) → Gauge
- **ObservableCounter** (async) → Sum, monotónico
- **ObservableUpDownCounter** (async) → Sum, no monotónico
- **ObservableGauge** (async) → Gauge

(El **Gauge** síncrono es la incorporación más reciente; los SDKs más viejos solo tenían el observable gauge.)

**A3.4** — Los bounds `[5, 10, 25, 50, 100]` crean seis buckets: `(-∞,5], (5,10], (10,25], (25,50], (50,100], (100,+∞)`. Observaciones `4, 8, 8, 30, 200`:
- `Count = 5`, `Sum = 4+8+8+30+200 = 250`
- `BucketCounts = [1, 2, 0, 1, 0, 1]` → `4`→b0; `8,8`→b1; `30`→b3 `(25,50]`; `200`→**b5**, el bucket de overflow `(100,+∞)`.

### Ejercicio 4

**A4.1** — Rangos de severidad: **TRACE 1–4, DEBUG 5–8, INFO 9–12, WARN 13–16, ERROR 17–20, FATAL 21–24**. `SeverityNumber` está normalizado para que los backends puedan **filtrar y comparar entre fuentes** («mostrame ≥ WARN») sin tener que parsear los strings de nivel idiosincráticos de cada proyecto, mientras que `SeverityText` preserva la etiqueta *original* de la fuente por fidelidad. Los números dentro de una clase (p. ej., 9–12) permiten que una fuente exprese severidad relativa.

**A4.2** — El **`Trace ID` y el `Span ID`** en el `LogRecord` habilitan la correlación log↔trace. Se completan solo si había un span **activo en el contexto actual** cuando se emitió el log (el logging bridge lee el span activo). Si los logs se envían como texto plano, ese contexto se pierde — tendrías que hacer ingeniería inversa de la correlación a partir de los timestamps y el contenido de los mensajes, lo cual es poco confiable bajo concurrencia.

**A4.3** — Divergen siempre que la recolección está desacoplada de la emisión: p. ej., una app escribe una línea de log en un archivo a las 12:00:00 (`Timestamp`), y un receiver que hace tail del archivo la lee y la convierte a las 12:00:07 (`ObservedTimestamp`). Al investigar un incidente ordenás por **`Timestamp`** (cuándo ocurrió realmente el evento); `ObservedTimestamp` es un fallback usado solo cuando se desconoce el tiempo real del evento.

### Ejercicio 5

**A5.1** — Los **Resource attributes** describen la *entidad que produce la telemetría* (una instancia de servicio, un host, un contenedor) y aplican a **cada** señal que esa entidad emite, durante toda su vida. Los **atributos de span/metric/log** describen una *única* operación o medición y varían por registro. `service.name` es un Resource attribute porque es una propiedad del productor, constante en todos sus spans — almacenarlo por span sería redundante e impediría que el backend agrupe la telemetría por servicio.

**A5.2** — Las convenciones semánticas definen **nombres, tipos y significados estándar** para los atributos comunes, de modo que un backend pueda construir dashboards entre servicios, mapas de servicios y alertas sin un mapeo por equipo. Ejemplo: `http.request.method`. Si un equipo lo llamara `method`, otro `httpMethod` y un tercero `verb`, ninguna consulta del backend podría agregar el tráfico HTTP entre servicios, y las funciones de correlación/enriquecimiento perderían datos silenciosamente.

**A5.3** — (a) El **Baggage** transporta pares clave-valor definidos por el usuario *a través de* los límites entre servicios mediante el header `baggage` de W3C, para que un servicio downstream pueda leer contexto (p. ej., `tenant.id`, `feature.flag`) establecido upstream sin volver a derivarlo. (b) El error: **el Baggage no se escribe automáticamente en los spans como atributos** — necesitás un processor/código explícito para copiarlo. Peor aún, si *sí* copiás el Baggage a atributos de forma indiscriminada, corrés el riesgo de (i) propagar **datos sensibles** a cada servicio downstream y a los almacenes de telemetría, y (ii) **explosiones de costo/cardinalidad**. El Baggage debería tratarse como no confiable, sin cifrar y con tamaño acotado.

**A5.4** — Si la instrumentación no establece `service.name`, la spec define el valor de fallback **`unknown_service`** (los SDKs suelen agregar el nombre del proceso, p. ej., `unknown_service:python`). Un `service.name` faltante o duplicado rompe el **mapa de servicios**: la telemetría de servicios distintos colapsa en un único nodo `unknown_service` (o un servicio real queda fragmentado), volviendo sin sentido los grafos de dependencias, los SLOs por servicio y la atribución de errores.

</details>