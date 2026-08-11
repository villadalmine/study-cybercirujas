# OTCA 3.4 — Pipelines (Ejercicios guiados)

> **Dominio 3 — El OpenTelemetry Collector · Tema 3.4 Pipelines**
> Un *pipeline* es la ruta ordenada que sigue un único tipo de señal (traces, metrics o logs) dentro del Collector: **receivers → processors → exporters**, declarada bajo `service::pipelines`. Estos labs construyen uno desde cero y luego ejercitan las reglas de compartición, el orden de los processors y los connectors que evalúa el examen.
>
> **Prerrequisitos.** Un único binario estático de la distribución contrib (`otelcol-contrib`) y el generador de carga `telemetrygen`. Ambos se publican en la [página de releases](https://github.com/open-telemetry/opentelemetry-collector-releases/releases). Verificá:
> ```console
> $ otelcol-contrib --version
> otelcol-contrib version 0.109.0
> $ telemetrygen --help | head -1
> Usage: telemetrygen [command]
> ```
> Todo lo que sigue corre localmente — no se requiere ningún backend externo, porque el exporter `debug` imprime a stdout.

---

## Ejercicio 1 — Anatomía de un pipeline: definir vs. usar

El Collector separa *declarar* un componente (los mapas de nivel superior `receivers:`, `processors:`, `exporters:`) de *usarlo* (referenciarlo dentro de una entrada de `service::pipelines`). Un componente que se declara pero nunca se referencia se construye de forma perezosa — efectivamente inactivo. Un componente que se referencia pero nunca se declara es un error fatal de configuración. Este ejercicio hace visibles ambas mitades.

**Pasos**

1. Creá `01-min.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Validalo estáticamente (carga y construye el grafo de configuración, pero **no** inicia listeners):

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   $
   ```
   Una salida limpia `0` sin ningún output significa que el grafo del pipeline resuelve.

3. Ahora rompé el lado del *uso*. Agregá `zpages` a la lista `processors` del pipeline traces **sin** declararlo, y revalidá:

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   Error: invalid configuration: service::pipelines::traces: references processor "zpages" which is not configured
   ```

4. Revertí el paso 3. Ahora rompé la regla de *forma* — borrá la línea `exporters: [debug]` del pipeline y validá:

   ```console
   $ otelcol-contrib validate --config=01-min.yaml
   Error: invalid configuration: service::pipelines::traces: must have at least one exporter
   ```

5. Restaurá el exporter. Agregá un exporter **declarado-pero-no-usado** (`nop`) al mapa de nivel superior `exporters:` pero *no* lo referencies en ningún pipeline. Validá de nuevo — pasa. Luego ejecutá el Collector y generá datos:

   ```console
   $ otelcol-contrib --config=01-min.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=2
   ```
   Observá el output del exporter `debug`:
   ```
   info    TracesExporter  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 1, "spans": 2}
   info    ResourceSpans #0
   Resource attributes:
        -> service.name: Str(telemetrygen)
   ScopeSpans #0
   ScopeSpans SchemaURL:
   InstrumentationScope telemetrygen
   Span #0
       Trace ID       : 6d3f... 
       Name           : okey-dokey-0
       Kind           : Server
   ```

**Verificación de comprensión**

- **Q1.1** Un componente aparece bajo `receivers:` pero en ningún pipeline. ¿El Collector lo inicia, advierte, o falla? Contrastá eso con referenciarlo en un pipeline sin declararlo.
- **Q1.2** Se aplican tanto `must have at least one receiver` como `must have at least one exporter`, pero no existe una regla `must have at least one processor`. ¿Por qué `processors:` es opcional en un pipeline?
- **Q1.3** ¿Cuál es el valor operativo de que `validate` devuelva un valor distinto de cero *antes* de que siquiera se enlace el puerto 4317?

---

## Ejercicio 2 — Múltiples pipelines con nombre y compartición de componentes

Los pipelines se identifican por clave `<type>[/<name>]`. Podés ejecutar varios pipelines del mismo tipo de señal — `traces`, `traces/sampled`, `traces/audit` — cada uno una ruta independiente. Cuando el **mismo componente declarado** es referenciado por más de un pipeline, el Collector aplica reglas de compartición precisas que el examen evalúa directamente.

**Pasos**

1. Creá `02-share.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug/full:
       verbosity: detailed
     debug/counts:
       verbosity: normal

   service:
     telemetry:
       metrics:
         level: none
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug/full]
       traces/mirror:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug/counts]
   ```

2. Validá, luego ejecutalo y enviá **un** batch de traces:

   ```console
   $ otelcol-contrib --config=02-share.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=1
   ```

3. Notá que un único stream OTLP llega a **ambos** exporters — un batch de spans aparece renderizado como `detailed` (desde `debug/full`) y otra vez como conteos `normal` (desde `debug/counts`). El receiver `otlp` fue declarado una vez y se enlaza al puerto 4317 exactamente una vez.

4. Razoná sobre `batch`: es referenciado tanto por `traces` como por `traces/mirror`. Consultá el [doc de arquitectura](https://opentelemetry.io/docs/collector/architecture/): los receivers y exporters referenciados en múltiples pipelines son **instancias únicas compartidas** (fan-out / fan-in), pero cada pipeline recibe su **propia instancia** de cada processor.

**Verificación de comprensión**

- **Q2.1** El puerto 4317 no se abre dos veces aunque dos pipelines listan `otlp`. ¿Qué regla de compartición explica eso, y qué pasaría si en cambio el receiver se instanciara una vez por pipeline?
- **Q2.2** El processor `batch` es stateful — acumula ítems a lo largo de las llamadas hasta un umbral de tamaño o timeout. Dada la regla de instancia-por-pipeline, ¿`traces` y `traces/mirror` comparten un buffer de acumulación o dos? ¿Por qué importa esto para un processor `tail_sampling` o `groupbytrace` colocado en dos pipelines?
- **Q2.3** Querés *exactamente una* copia de cada span enviada a dos backends diferentes. ¿Deberías usar dos pipelines cada uno con su propio exporter, o un pipeline con dos exporters? ¿Qué cuesta cada elección en instancias de receiver y en buffering?

---

## Ejercicio 3 — El orden de los processors es semántico

El orden de los receivers y el orden de los exporters dentro de un pipeline son irrelevantes. **El orden de los processors no lo es** — los ítems fluyen a través de los processors estrictamente de izquierda a derecha, así que la ubicación decide tanto la corrección como el costo. Este lab demuestra el orden canónico: `memory_limiter` primero, el filtrado después, `batch` último (lo más cerca de los exporters).

**Pasos**

1. Creá `03-order.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 512
       spike_limit_mib: 128
     filter/drop_health:
       error_mode: ignore
       traces:
         span:
           - 'attributes["http.target"] == "/healthz"'
     batch:
       timeout: 5s
       send_batch_size: 8192
       send_batch_max_size: 10000

   exporters:
     debug:
       verbosity: normal

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, filter/drop_health, batch]
         exporters: [debug]
   ```

2. Validá y ejecutá. Enviá dos tipos de tráfico — spans normales y spans de health-check:

   ```console
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=5
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=5 \
       --span-duration=1ms --attributes='http.target="/healthz"'
   ```
   Solo el primer grupo sobrevive hasta el exporter `debug`; la condición OTTL de `filter/drop_health` descarta los spans de health antes de que sean agrupados en batch.

3. Simulá mentalmente dos ordenamientos *incorrectos* y predecí el efecto:
   - `[batch, memory_limiter, filter/drop_health]` — los datos se agrupan en batch, luego el memory limiter puede rechazar un batch ya ensamblado, y el filtrado ocurre después de que ya se gastó el esfuerzo de batching.
   - `[filter/drop_health, batch, memory_limiter]` — el memory limiter ahora protege *después* de que el trabajo de batching intensivo en CPU ya está hecho, frustrando su propósito como válvula de back-pressure.

4. Confirmá el orden recomendado contra los docs oficiales de los processors: [README de `memory_limiter`](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md) ("should be the first processor defined in the pipeline") y [README de `batch`](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md).

**Verificación de comprensión**

- **Q3.1** ¿Por qué `memory_limiter` debe ir primero en lugar de último, dado que su trabajo es descartar carga bajo presión de memoria?
- **Q3.2** ¿Por qué `batch` se ubica *después* de los processors de filtrado/sampling y lo más cerca de los exporters? ¿Qué se desperdicia si agrupás en batch primero y descartás después?
- **Q3.3** `filter/drop_health` usa `error_mode: ignore`. Si a un span le faltara el atributo `http.target`, ¿qué haría `ignore` frente a `propagate`, y cómo podría la elección incorrecta descartar o detener datos silenciosamente?
- **Q3.4** Si intercambiás la posición de `otlp` con un segundo receiver en la lista `receivers:`, ¿cambia el comportamiento del pipeline? ¿Por qué el orden de los receivers — a diferencia del orden de los processors — es irrelevante?

---

## Ejercicio 4 — Connectors: puenteando dos pipelines

Un **connector** es un componente que es simultáneamente un *exporter* en un pipeline y un *receiver* en otro, permitiendo que una señal en un pipeline produzca señal (posiblemente de otro tipo) en otro. Así es como un único Collector deriva metrics a partir de traces sin un servicio externo. Aquí usamos el connector `count` para convertir un pipeline de traces en metrics de conteo de spans.

**Pasos**

1. Creá `04-connector.yaml`:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   connectors:
     count:

   exporters:
     debug:
       verbosity: detailed

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [count]          # connector acts as EXPORTER here
       metrics:
         receivers: [count]          # same connector acts as RECEIVER here
         processors: [batch]
         exporters: [debug]
   ```

2. Validá. Notá que el grafo es acíclico: `otlp → traces → count → metrics → debug`. Ejecutá y alimentá traces:

   ```console
   $ otelcol-contrib --config=04-connector.yaml &
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=4
   ```

3. Observá que el exporter `debug` ahora imprime **metrics**, no traces — el connector `count` emitió una suma `trace.span.count` derivada de los traces que consumió:

   ```
   info    MetricsExporter {"kind": "exporter", "data_type": "metrics", "name": "debug", "resource metrics": 1, "metrics": 1, "data points": 1}
   Metric #0
   Descriptor:
        -> Name: trace.span.count
        -> Description: The number of spans observed.
        -> DataType: Sum
   NumberDataPoint #0
   Value: 8
   ```
   (Cuatro traces × dos spans cada uno = 8.)

4. Rompelo: referenciá `count` como exporter en `traces` pero **eliminá** el pipeline `metrics` que lo consume. Validá:

   ```console
   $ otelcol-contrib validate --config=04-connector.yaml
   Error: connector "count" used as exporter in [traces] pipeline but not used in any supported receiver pipeline
   ```

**Verificación de comprensión**

- **Q4.1** En `04-connector.yaml`, ¿en qué pipeline `count` se comporta como exporter y en cuál como receiver? ¿Qué determina cada rol?
- **Q4.2** El exporter del pipeline `traces` es un connector, pero ningún trace sale nunca del Collector. ¿A dónde "fueron" los spans, y qué recibe realmente el pipeline `metrics`?
- **Q4.3** Un connector referenciado solo como exporter (sin pipeline que lo consuma) es un error de validación. ¿Por qué eso es más estricto que un simple exporter declarado-pero-no-usado (Ejercicio 1, paso 5), que sí está permitido?
- **Q4.4** Nombrá una combinación de tipos de señal que un connector habilita y que un par receiver/exporter no puede (pista: pensá en traces-in / metrics-out dentro de un único proceso, p. ej. `spanmetrics`, `servicegraph`, `routing`, `forward`).

---

## Ejercicio 5 — Observando el propio pipeline

Un pipeline que no podés ver es un pipeline que no podés depurar. El Collector expone su propia salud a través de `service::telemetry` (self-metrics/logs) y a través de extensions como `zpages` y `health_check`. Las extensions **no** forman parte de ningún pipeline — se adjuntan a `service::extensions`.

**Pasos**

1. Creá `05-observe.yaml`:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     zpages:
       endpoint: 0.0.0.0:55679

   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317

   processors:
     batch:

   exporters:
     debug:
       verbosity: normal

   service:
     extensions: [health_check, zpages]
     telemetry:
       logs:
         level: info
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
         processors: [batch]
         exporters: [debug]
   ```

2. Ejecutalo. Verificá la liveness y la z-page del pipeline:

   ```console
   $ curl -s localhost:13133 | head
   {"status":"Server available","upSince":"2026-08-11T10:22:04Z"}

   $ curl -s localhost:55679/debug/pipelinez | head
   Pipelines
   Pipeline           Receivers        Processors     Exporters
   traces             [otlp]           [batch]        [debug]
   ```

3. Enviá tráfico y hacé scrape de las metrics **propias** del Collector para ver el throughput por componente:

   ```console
   $ telemetrygen traces --otlp-insecure --otlp-endpoint=localhost:4317 --traces=10
   $ curl -s localhost:8888/metrics | grep -E 'receiver_accepted_spans|exporter_sent_spans'
   otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 20
   otelcol_exporter_sent_spans{exporter="debug"} 20
   ```

4. Correlacioná: `receiver_accepted_spans` debería ser igual a `exporter_sent_spans` cuando no se descarta nada. Si un `filter` o `memory_limiter` descarta datos, los contadores `refused`/`dropped` divergen — esa brecha *es* tu diagnóstico del pipeline.

**Verificación de comprensión**

- **Q5.1** `zpages` y `health_check` aparecen bajo `service::extensions`, nunca dentro de `service::pipelines`. ¿Por qué las extensions están deliberadamente fuera de la ruta receiver→processor→exporter?
- **Q5.2** Observás `otelcol_receiver_accepted_spans = 20` pero `otelcol_exporter_sent_spans = 12`. Enumerá dos causas internas del pipeline y el contador que verificarías a continuación para confirmar cada una.
- **Q5.3** ¿Cuál es la diferencia entre `service::telemetry` y un pipeline `metrics` construido a partir del receiver `prometheus`? ¿Cuál informa sobre el *propio Collector*?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **A1.1** Un receiver declarado-pero-no-referenciado simplemente no está conectado a ningún pipeline; el Collector construye solo los componentes que un pipeline usa, así que ni enlaza un puerto ni da error — está efectivamente inactivo (y no aparece en la z-page `pipelinez`). Lo inverso — referenciar un componente no declarado — es un error fatal de construcción (`references processor "zpages" which is not configured`) detectado en el momento de `validate`, porque el grafo de configuración no puede resolverse.
- **A1.2** Los processors son opcionales porque un pipeline válido es simplemente "meter datos, sacar datos" — un receiver y un exporter alcanzan. Los processors solo *transforman* el stream; un pipeline sin ninguno pasa los datos directamente. Los receivers y exporters son obligatorios porque sin una fuente no hay nada que mover y sin un destino no hay a dónde moverlo, así que ambos mínimos se aplican.
- **A1.3** `validate` resuelve y construye el grafo completo de componentes sin abrir sockets ni contactar backends, así que una configuración incorrecta falla en CI o en una verificación previa — antes de que reclame el puerto 4317, descarte tráfico, o arranque a medias en producción. Convierte una caída en tiempo de ejecución en un error en tiempo de construcción.

**Ejercicio 2**

- **A2.1** Los receivers referenciados en múltiples pipelines son una **única instancia compartida**; la salida del receiver se *distribuye por fan-out* (se duplica) a cada pipeline que lo lista. Si se instanciara por pipeline, cada instancia intentaría enlazar `0.0.0.0:4317` y la segunda fallaría con un error de dirección-ya-en-uso al iniciar.
- **A2.2** Dos buffers separados. Cada pipeline obtiene su **propia** instancia de processor, así que `traces` y `traces/mirror` acumulan de forma independiente. Esto importa críticamente para los processors stateful: un `tail_sampling` o `groupbytrace` compartido entre dos pipelines **no** agrupa los spans del mismo trace entre ambos — cada instancia ve solo la porción de su pipeline, así que las decisiones de sampling se toman sobre datos parciales. Si necesitás una única decisión global, enrutá todos los datos a través de un solo pipeline.
- **A2.3** Un pipeline con dos exporters. Los receivers/exporters se distribuyen por fan-out, así que un único pipeline entrega una copia de cada span a cada exporter con una única instancia de receiver y una sola cadena de processors (un buffer de batch). Dos pipelines que reproduzcan cada uno el mismo receiver también funcionan pero duplican las instancias de processor (dos buffers de batch, el doble de memoria/CPU para un trabajo idéntico) — pagá ese costo solo cuando las dos rutas necesiten un procesamiento *diferente*.

**Ejercicio 3**

- **A3.1** `memory_limiter` es una válvula de back-pressure: cuando la memoria cruza sus límites soft/hard *rechaza* los datos entrantes y fuerza a los receivers a aplicar back-pressure a los clientes. Ubicado primero, rechaza la carga antes de que cualquier processor posterior gaste CPU/memoria en ella. Ubicado último, el trabajo costoso (filtrado, batching) ya consumió memoria para cuando el limiter reacciona — demasiado tarde para proteger al proceso de un OOM.
- **A3.2** `batch` se ubica último para que solo agrupe en batch datos que realmente se exportarán. Filtrar/samplear *antes* del batching significa que los ítems descartados nunca entran a un batch. Batch-y-luego-descartar desperdicia la memoria y el CPU de ensamblar batches cuyo contenido luego se descarta, y diluye la eficiencia del batch.
- **A3.3** `error_mode: ignore` omite los errores de evaluación de OTTL (p. ej. un `http.target` faltante da nil, la condición es simplemente falsa, el span se conserva y el procesamiento continúa). `propagate` haría emerger el error de OTTL hacia arriba en el pipeline, potencialmente fallando el batch entero. Elegir `propagate` donde los atributos nil son normales puede detener/dar error a datos por lo demás válidos; elegir `ignore` donde *esperabas* una coincidencia puede conservar silenciosamente spans que querías descartar — de cualquier forma la mala configuración es invisible sin revisar los contadores.
- **A3.4** Ningún cambio de comportamiento. Los receivers son fuentes de fan-in fusionadas en un único stream y los exporters son destinos de fan-out; ninguno tiene un orden entre componentes. Solo los processors forman una cadena estricta de izquierda a derecha donde cada uno muta el stream que entrega al siguiente, así que solo su orden es semántico.

**Ejercicio 4**

- **A4.1** `count` es un **exporter** en el pipeline `traces` (termina ese pipeline) y un **receiver** en el pipeline `metrics` (origina ese otro). El rol se determina puramente por *dónde está listado* — en la lista `exporters:` vs. la lista `receivers:` de un pipeline — no por ninguna configuración en el propio connector.
- **A4.2** Los spans son consumidos por el connector y nunca se exportan externamente; el connector `count` los transforma en una metric derivada `trace.span.count`. El pipeline `metrics` por lo tanto recibe **metrics** producidas a partir del stream de traces, no los traces en sí.
- **A4.3** Un connector debe formar un puente completo: algo debe consumir lo que produce, o la señal producida no tiene a dónde ir — un semigrafo colgante. El Collector trata eso como un error de configuración. Un exporter simple, en cambio, es un destino terminal; declararlo y no usarlo no desperdicia nada estructuralmente, así que está meramente inactivo, no inválido.
- **A4.4** Un connector puede realizar derivación **entre señales** dentro de un mismo proceso: traces-in → metrics-out (`count`, `spanmetrics`, `servicegraph`). Un par receiver/exporter solo mueve una señal hacia dentro y fuera del Collector; no puede cambiar el tipo de señal ni sintetizar señales nuevas a partir de otra. (Los connectors también hacen trabajo dentro de la misma señal como `forward` y el `routing` basado en atributos.)

**Ejercicio 5**

- **A5.1** Las extensions proveen capacidades a nivel de todo el Collector — health, profiling, servido de páginas, auth — que son ortogonales al flujo de datos. No reciben, transforman ni emiten telemetría, así que ponerlas en un pipeline no tendría sentido; `service::extensions` es el hook de ciclo de vida que las inicia/detiene junto con los pipelines sin ser parte de ninguna ruta de señal.
- **A5.2** (1) Un processor `filter`/sampling descartó 8 spans — confirmalo con una divergencia en los contadores accepted/refused a nivel de processor o la brecha entre `sent` del exporter y `accepted` del receiver. (2) El exporter no logró entregar 8 — confirmalo con `otelcol_exporter_send_failed_spans` y/o `otelcol_exporter_enqueue_failed_spans` (cola llena / backend rechazando). Un rechazo de `memory_limiter` en cambio aparecería como `otelcol_receiver_refused_spans`.
- **A5.3** `service::telemetry` es la **auto-observabilidad** del Collector — metrics/logs/traces *sobre el proceso del Collector* (contadores de throughput, tamaños de cola, sus propios logs), expuestos aquí en `:8888`. Un pipeline `metrics` alimentado por el receiver `prometheus` hace scrape de targets *externos* y mueve sus metrics a través del Collector como datos ordinarios. El primero informa sobre el propio Collector; el segundo trata al Collector como un conducto para las metrics de otro.

</details>

---

**Fuentes**
- OpenTelemetry Collector — Configuration (pipelines, receivers/processors/exporters/connectors/extensions): https://opentelemetry.io/docs/collector/configuration/
- OpenTelemetry Collector — Architecture (compartición de componentes, fan-out/fan-in, instancias de processor por pipeline): https://opentelemetry.io/docs/collector/architecture/
- Connectors overview: https://opentelemetry.io/docs/collector/building/connector/ y https://github.com/open-telemetry/opentelemetry-collector/tree/main/connector
- processor `memory_limiter` (guía de ordenamiento): https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md
- processor `batch`: https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md
- connector `count`: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/countconnector
- Telemetría interna del Collector y `zpages`: https://opentelemetry.io/docs/collector/internal-telemetry/