# OTCA 3.1 — Configuration (OpenTelemetry Collector)

> **Domain:** OpenTelemetry Collector · **Subtopic:** Configuration · **Exam weight:** ~5.2%
>
> Estos ejercicios guiados construyen una configuración funcional del Collector desde cero, una clase de componente a la vez, y luego ponen a prueba las partes que el examen realmente evalúa: reglas de conexión de pipelines, orden de los processors, semántica de instancias de componentes, sustitución de variables de entorno y validación de configuración. Todos los comandos se pueden ejecutar con nada más que Docker.
>
> **Distribución de referencia usada más abajo:** `otel/opentelemetry-collector-contrib:0.119.0` (Contrib). Fijá el tag que prefieras — el *esquema* de configuración que se usa acá es estable a lo largo de las versiones recientes; solo cambian los números de línea de los logs y el string de versión en la salida. Las fuentes se citan al final de cada ejercicio.

---

## Exercise 1 — The four-block anatomy and `validate`

**Goal:** Entender que una configuración del Collector es *declaración* (los mapas de componentes de nivel superior) más *activación* (el bloque `service`), y que nada se ejecuta hasta que se lo referencia en un pipeline.

1. Creá un directorio de trabajo y un archivo de configuración mínimo `otelcol.yaml`:

   ```bash
   mkdir -p ~/otca-3.1 && cd ~/otca-3.1
   ```

   ```yaml
   # otelcol.yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}

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

2. Validá la configuración *sin* iniciar el Collector. El subcomando `validate` carga, fusiona y verifica los tipos de la configuración, y luego termina:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml
   echo "exit=$?"
   ```

   Esperado: **sin salida**, y

   ```
   exit=0
   ```

3. Ahora rompé deliberadamente la conexión. Cambiá el pipeline de `service` para que referencie un exporter que nunca declaraste:

   ```yaml
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/backend]   # <-- not declared in the exporters block
   ```

4. Volvé a ejecutar el comando validate del paso 2. Esperado (exit distinto de cero):

   ```
   Error: invalid configuration: service::pipelines::traces: references exporter "otlp/backend" which is not configured
   exit=1
   ```

5. Revertí el paso 3 de vuelta a `exporters: [debug]` antes de continuar.

**Check your understanding**

- **1a.** ¿Cuáles son las cuatro clases de componentes que se declaran en el nivel superior de toda configuración del Collector, y qué *quinto* bloque de nivel superior las enciende?
- **1b.** En el paso 1, el receiver `otlp` está *declarado*. ¿Qué única cosa adicional se requería para que efectivamente escuchara en `:4317`?
- **1c.** El error del paso 4 es un error de *validación*, no un error de runtime. ¿Por qué `validate` es más barato y más seguro de ejecutar en CI que iniciar el Collector para probar una configuración?
- **1d.** Si en cambio hubieras *declarado* un exporter extra pero nunca lo hubieras listado en ningún pipeline, ¿fallaría `validate`? ¿Qué le pasa a ese componente en runtime?

*Sources: [Collector Configuration](https://opentelemetry.io/docs/collector/configuration/), [Collector components](https://opentelemetry.io/docs/collector/configuration/#basics).*

---

## Exercise 2 — Named components and multi-signal pipelines

**Goal:** Usar la sintaxis de identificador de componente `type/name` para ejecutar dos exporters del mismo tipo, y conectar pipelines independientes de `traces`, `metrics` y `logs`.

1. Reemplazá `otelcol.yaml` con una configuración de tres señales que exporta a un backend real **y** a la consola debug. Notá los dos exporters de tipo `otlp` distinguidos por nombre:

   ```yaml
   receivers:
     otlp:
       protocols:
         grpc:
           endpoint: 0.0.0.0:4317
         http:
           endpoint: 0.0.0.0:4318

   processors:
     batch: {}

   exporters:
     debug:
       verbosity: normal
     otlp/backend:                       # named instance #1
       endpoint: tempo:4317
       tls:
         insecure: true
     otlp/metrics-backend:               # named instance #2, different endpoint
       endpoint: mimir:4317
       tls:
         insecure: true

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/backend, debug]
       metrics:
         receivers: [otlp]
         processors: [batch]
         exporters: [otlp/metrics-backend]
       logs:
         receivers: [otlp]
         processors: [batch]
         exporters: [debug]
   ```

2. Validála (los backends `tempo`/`mimir` no necesitan existir para que la *validación* pase — el DNS solo se resuelve en el momento de exportar):

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

   Esperado: `OK`

3. Iniciá el Collector de verdad y observá cómo levanta cada pipeline:

   ```bash
   docker run --rm --name otca-col -p 4317:4317 -p 4318:4318 \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     --config=/etc/otelcol/config.yaml
   ```

   Esperado (abreviado):

   ```
   info  service@v0.119.0/service.go:...  Starting otelcol-contrib...  {"Version": "0.119.0", "NumCPU": 8}
   info  otlpreceiver@v0.119.0/otlp.go:...  Starting GRPC server  {"endpoint": "0.0.0.0:4317"}
   info  otlpreceiver@v0.119.0/otlp.go:...  Starting HTTP server  {"endpoint": "0.0.0.0:4318"}
   info  service@v0.119.0/service.go:...  Everything is ready. Begin running and processing data.
   ```

   Dejalo corriendo; abrí una segunda terminal para el siguiente paso.

4. En la segunda terminal, enviá tres spans reales con `telemetrygen` y confirmá que el exporter debug los imprime:

   ```bash
   docker run --rm --network host \
     ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
     traces --otlp-insecure --traces 3
   ```

   En la primera terminal deberías ver que el receiver acepta el batch y que el exporter `debug` emite un resumen como:

   ```
   info  Traces  {"kind": "exporter", "data_type": "traces", "name": "debug", "resource spans": 3, "spans": 6}
   ```

5. Detené el Collector con `Ctrl-C` (drena, y luego loguea `Shutdown complete.`).

**Check your understanding**

- **2a.** `otlp/backend` y `otlp/metrics-backend` comparten el *tipo* `otlp`. ¿Qué los hace dos instancias de exporter distintas, y por qué es imposible una segunda clave `otlp:` pelada en el mismo bloque?
- **2b.** El pipeline `traces` se abre en abanico hacia *dos* exporters. ¿En qué orden llega la telemetría a `otlp/backend` respecto de `debug` — secuencial, o cada exporter se alimenta de forma independiente?
- **2c.** El mismo id de receiver `otlp` aparece en los tres pipelines. ¿Se crea un listener OTLP o tres? (Esta es la regla de compartición de receivers — ver Exercise 5.)
- **2d.** ¿Por qué la validación del paso 2 tuvo éxito aunque `tempo:4317` no se pueda resolver en tu entorno?

*Sources: [Configuring components (type/name)](https://opentelemetry.io/docs/collector/configuration/#basics), [OTLP Exporter](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/otlpexporter/README.md).*

---

## Exercise 3 — Processor ordering: `memory_limiter` and `batch`

**Goal:** Aprender que `processors: [...]` es una *cadena ordenada* y que la ubicación es semánticamente significativa, no cosmética.

1. Agregá un `memory_limiter` y dale a `batch` un ajuste explícito. El orden importa — poné `memory_limiter` **primero**:

   ```yaml
   processors:
     memory_limiter:
       check_interval: 1s
       limit_mib: 512
       spike_limit_mib: 128
     batch:
       timeout: 5s
       send_batch_size: 1024
       send_batch_max_size: 2048

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]   # limiter guards the door; batch groups on exit
         exporters: [otlp/backend, debug]
   ```

2. Validá e iniciá (reutilizá el comando de ejecución del Exercise 2, paso 3). Confirmá que arranca de forma limpia.

3. Ahora invertí el orden a `processors: [batch, memory_limiter]` y volvé a validar.

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

   Observá que la validación igual imprime `OK` — el error de orden **no** es un error de esquema. Es un error de *diseño* que el validador no puede detectar.

4. Restaurá `[memory_limiter, batch]`.

**Check your understanding**

- **3a.** Los datos fluyen por la lista de processors de arriba hacia abajo. Concretamente, ¿qué sale mal si `batch` se ejecuta *antes* que `memory_limiter` durante un pico de presión de memoria?
- **3b.** `send_batch_size` vs `send_batch_max_size`: uno es un objetivo blando, el otro es un tope duro. ¿Cuál es cuál, y qué hace `batch` con un batch que excede el máximo?
- **3c.** El paso 3 muestra una configuración semánticamente incorrecta que pasa `validate`. ¿Qué peldaño de la escalera de verificación detecta errores de orden, y por qué la validación estática no puede?
- **3d.** `memory_limiter` también acepta `limit_percentage`/`spike_limit_percentage` en lugar de `_mib`. En un contenedor con un límite de memoria de cgroup, ¿por qué la forma en porcentaje podría ser más robusta que un `limit_mib` fijo?

*Sources: [Memory Limiter processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md), [Batch processor](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md).*

---

## Exercise 4 — Environment substitution, defaults, and config merging

**Goal:** Externalizar valores específicos del entorno con `${env:...}`, proveer valores por defecto, y superponer configuración desde múltiples providers.

1. Parametrizá el endpoint del backend y la verbosity. Usá la sintaxis del provider `${env:VAR}` con un default `:-`:

   ```yaml
   exporters:
     debug:
       verbosity: ${env:DEBUG_VERBOSITY:-normal}
     otlp/backend:
       endpoint: ${env:BACKEND_ENDPOINT:-tempo:4317}
       tls:
         insecure: true
   ```

2. Ejecutá con la variable **sin definir** y confirmá que se usa el default (agregá una validación estilo `--dry-run` con el comando `validate`, o iniciálo). Iniciálo y verificá el endpoint resuelto mediante los logs de debug — primero sin env:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo "defaulted OK"
   ```

3. Ahora sobreescribí en runtime inyectando la variable de entorno:

   ```bash
   docker run --rm \
     -e BACKEND_ENDPOINT=otlp-gateway.observability.svc:4317 \
     -e DEBUG_VERBOSITY=detailed \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo "override OK"
   ```

4. Demostrá el **merge de múltiples fuentes**. Creá un archivo de overlay `overlay.yaml` que solo ajusta la verbosity, y pasá *dos* flags `--config` más un provider inline `yaml:`. Las fuentes posteriores ganan en las claves escalares:

   ```yaml
   # overlay.yaml
   exporters:
     debug:
       verbosity: basic
   ```

   ```bash
   docker run --rm \
     -v "$PWD/otelcol.yaml:/etc/otelcol/base.yaml" \
     -v "$PWD/overlay.yaml:/etc/otelcol/overlay.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate \
       --config=/etc/otelcol/base.yaml \
       --config=/etc/otelcol/overlay.yaml \
       --config="yaml:exporters::debug::verbosity: detailed"
   ```

   El último provider `yaml:` gana, así que el `debug.verbosity` efectivo es `detailed`.

**Check your understanding**

- **4a.** ¿A qué evalúa `${env:BACKEND_ENDPOINT:-tempo:4317}` cuando `BACKEND_ENDPOINT` está (i) sin definir, (ii) definido como string vacío, (iii) definido con un valor?
- **4b.** Cuando la misma clave escalar está definida en `base.yaml`, `overlay.yaml` y un provider inline `yaml:`, ¿qué valor es el efectivo? Enunciá la regla de precedencia para las fuentes `--config`.
- **4c.** Nombrá dos *providers* de configuración distintos de `env:` desde los que el Collector puede leer un valor de `--config`.
- **4d.** ¿Por qué la sustitución `${env:...}` es más segura que hornear secretos/endpoints en el YAML versionado — y cuál es el riesgo de usarla para un *secreto* pasado como una variable de entorno de contenedor en texto plano?

*Sources: [Environment variables & providers](https://opentelemetry.io/docs/collector/configuration/#environment-variables), [Configuration structure](https://opentelemetry.io/docs/collector/configuration/).*

---

## Exercise 5 — Extensions, `service::telemetry`, and component-instance semantics

**Goal:** Habilitar componentes que no son de pipeline (extensions), exponer la salud y la telemetría interna del propio Collector, y razonar sobre cuántas *instancias* de un componente crea realmente el Collector.

1. Agregá extensions y telemetría propia al bloque `service`. Las extensions se declaran como cualquier componente pero se activan bajo `service.extensions`, **no** en un pipeline:

   ```yaml
   extensions:
     health_check:
       endpoint: 0.0.0.0:13133
     pprof:
       endpoint: 0.0.0.0:1777
     zpages:
       endpoint: 0.0.0.0:55679

   service:
     extensions: [health_check, pprof, zpages]
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
         processors: [memory_limiter, batch]
         exporters: [otlp/backend, debug]
       metrics:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp/backend]
   ```

2. Iniciá el Collector, exponiendo los nuevos puertos:

   ```bash
   docker run --rm --name otca-col \
     -p 4317:4317 -p 4318:4318 -p 13133:13133 -p 55679:55679 -p 8888:8888 \
     -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     --config=/etc/otelcol/config.yaml
   ```

3. Desde una segunda terminal, sondeá la extension health-check:

   ```bash
   curl -s localhost:13133/ ; echo
   ```

   Esperado (JSON, abreviado):

   ```json
   {"status":"Server available","upSince":"2026-08-10T14:22:03.457Z","uptime":"12.ol s"}
   ```

4. Scrapeá las métricas internas **propias** del Collector (expuestas por `service::telemetry::metrics`) y buscá los contadores de receiver/exporter:

   ```bash
   curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent)_spans' | head
   ```

   Esperado (los valores dependen del tráfico):

   ```
   otelcol_receiver_accepted_spans_total{receiver="otlp",transport="grpc"} 6
   otelcol_exporter_sent_spans_total{exporter="otlp/backend"} 6
   ```

5. Abrí `http://localhost:55679/debug/pipelinez` (zpages) en un navegador para ver la topología del pipeline en vivo, y después hacé `Ctrl-C` al Collector.

**Check your understanding**

- **5a.** Las extensions no aparecen en ningún pipeline de `receivers`/`processors`/`exporters`. ¿Cómo se activan, y qué tipo de capacidad brindan que los componentes de pipeline no?
- **5b.** En la configuración del paso 1, `otlp` (receiver) aparece tanto en `traces` como en `metrics`; `memory_limiter` y `batch` aparecen en ambos; `otlp/backend` aparece en ambos. ¿Cuáles de estos terminan siendo una **única instancia compartida** y cuáles se **instancian por pipeline**? Enunciá la regla.
- **5c.** `service::telemetry::metrics` expone métricas `otelcol_*` en `:8888`. Distinguílas de la telemetría que el Collector *procesa* — ¿por qué scrapear `:8888` es el primer movimiento al depurar un pipeline que "pierde" datos?
- **5d.** Si borraras la línea `zpages` de `service.extensions` pero la dejaras declarada bajo `extensions:`, ¿seguiría sirviendo `:55679`? ¿Por qué?

*Sources: [Health Check extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/healthcheckextension/README.md), [Internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/), [zPages extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/extension/zpagesextension/README.md).*

---

## Exercise 6 — Connectors: joining two pipelines (`spanmetrics`)

**Goal:** Usar un *connector* — un componente que es simultáneamente un exporter de un pipeline y un receiver de otro — para derivar métricas RED a partir de spans sin un processor externo.

1. Agregá el connector `spanmetrics`. Consume el pipeline `traces` y emite hacia un pipeline `metrics`:

   ```yaml
   connectors:
     spanmetrics:
       histogram:
         explicit:
           buckets: [100us, 1ms, 10ms, 100ms, 1s]
       dimensions:
         - name: http.method
         - name: http.status_code

   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch]
         exporters: [otlp/backend, spanmetrics]   # connector as an EXPORTER here
       metrics/spanmetrics:
         receivers: [spanmetrics]                  # same connector as a RECEIVER here
         processors: [batch]
         exporters: [otlp/backend]
   ```

2. Validá — notá que el connector debe aparecer como exporter en **exactamente un** pipeline y como receiver en **exactamente otro**, de los tipos de señal apropiados:

   ```bash
   docker run --rm -v "$PWD/otelcol.yaml:/etc/otelcol/config.yaml" \
     otel/opentelemetry-collector-contrib:0.119.0 \
     validate --config=/etc/otelcol/config.yaml && echo OK
   ```

3. Rompélo: quitá `spanmetrics` de la lista de receivers de `metrics/spanmetrics` (para que se use solo como exporter). Volvé a validar y leé el error:

   ```
   Error: invalid configuration: connectors::spanmetrics: must be used as both receiver and exporter but is not used as receiver
   ```

4. Restaurá el connector en ambos extremos.

**Check your understanding**

- **6a.** ¿Qué distingue estructuralmente a un *connector* de un *processor*? ¿Por qué `spanmetrics` no puede ser un processor?
- **6b.** En el paso 1, el connector convierte *traces → metrics*. ¿Qué tipo de señal de pipeline está del lado del exporter, y cuál del lado del receiver?
- **6c.** El error del paso 3 dice que el connector "must be used as both receiver and exporter." ¿Por qué un connector cableado de un solo lado siempre es un error de configuración?
- **6d.** Nombrá una ventaja operativa de generar métricas de spans dentro del Collector mediante `spanmetrics` en lugar de en cada aplicación instrumentada.

*Sources: [Connectors](https://opentelemetry.io/docs/collector/configuration/#connectors), [Spanmetrics connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/connector/spanmetricsconnector/README.md).*

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **1a.** Las cuatro clases de componentes son `receivers`, `processors`, `exporters` y `extensions` (una quinta clase opcional, `connectors`, aparece en el Exercise 6). El bloque que las activa es `service` — específicamente `service.pipelines` (y `service.extensions`). Declaración ≠ activación: un componente listado solo en el nivel superior es inerte.
- **1b.** Tenía que ser *referenciado en un pipeline*. El receiver `otlp` solo inicia sus listeners gRPC/HTTP porque `service.pipelines.traces.receivers` incluye `otlp`. La declaración por sí sola no inicia nada.
- **1c.** `validate` carga todas las fuentes de configuración, las fusiona y desmarshalla los settings de cada componente contra su esquema, y luego termina — nunca abre puertos de listener, no disca a los backends ni asigna buffers de pipeline. Por eso es rápido, sin efectos secundarios y seguro de ejecutar en CI en cada commit, mientras que iniciar el Collector enlaza puertos y puede perturbar un sistema en ejecución.
- **1d.** No — `validate` *pasaría*. Un componente que está declarado pero no referenciado en ningún pipeline simplemente **nunca se instancia** en runtime; es configuración muerta. El error solo se dispara en el sentido contrario: un pipeline que referencia un componente que nunca fue declarado.

### Exercise 2
- **2a.** La sintaxis de identificador `type/name`: `otlp/backend` y `otlp/metrics-backend` son ambos de tipo `otlp` pero llevan nombres distintos, lo que los convierte en dos claves de mapa separadas y dos instancias independientes con sus propios settings. Una segunda clave `otlp:` pelada es imposible porque los mapas YAML no pueden tener claves duplicadas dentro del bloque `exporters`.
- **2b.** Cada exporter se alimenta de forma **independiente** (fan-out). El pipeline entrega el mismo batch a cada exporter listado; no están encadenados en secuencia y la lentitud o falla de un exporter no, por sí sola, reordena ni bloquea la entrega a los demás (cada uno tiene su propia cola/reintento).
- **2c.** **Un** listener OTLP. Un id de receiver reutilizado en múltiples pipelines es una única instancia compartida que se abre en abanico hacia todos los pipelines conectados — no obtenés tres sockets enlazados a `:4317`. (Regla completa en 5b.)
- **2d.** `validate` solo verifica que la configuración *parsea y verifica tipos*. No resuelve DNS ni disca a los exporters; la conexión a `tempo:4317` se intenta de forma perezosa en el momento de exportar, así que un endpoint no resoluble es una cuestión de runtime, no una falla de validación.

### Exercise 3
- **3a.** Si `batch` se ejecuta primero, los spans se acumulan en los buffers del batcher *antes* de que `memory_limiter` llegue a verlos y rechazarlos. Durante un pico, los datos batcheados inflan el heap que el limiter se supone que protege, anulando su propósito — el limiter solo puede descartar carga de datos que le llegan, así que debe ubicarse al frente de la cadena, lo más cerca posible de los receivers.
- **3b.** `send_batch_size` es el **objetivo blando**: el batch processor descarga cuando el buffer alcanza esta cantidad de ítems (o cuando transcurre `timeout`). `send_batch_max_size` es el **tope duro**: ningún batch saliente puede exceder este valor; si un batch entrante empujara más allá del tope, el processor lo divide para que cada batch emitido sea ≤ max. `0` (default) significa sin límite superior.
- **3c.** Nada en la escalera estática gratuita lo detecta — `validate`, las verificaciones de esquema y la provenance pasan todas porque el YAML está bien formado y todo componente referenciado existe. El orden es una propiedad *semántica/de comportamiento*; solo ejecutar el Collector bajo carga (o el peldaño "¿es correcto el comportamiento?") revela que el limiter nunca descarta. La validación estática verifica *forma*, no *significado*.
- **3d.** `limit_percentage`/`spike_limit_percentage` calculan el umbral a partir de la memoria que el proceso realmente observa (honrando el límite del cgroup), así que la misma configuración se autoajusta entre un pod de dev de 256 MiB y un pod de prod de 4 GiB. Un `limit_mib: 512` fijo configurado más alto que el límite de cgroup del contenedor es peor que inútil — el kernel mata el proceso por OOM antes de que el limiter siquiera se dispare.

### Exercise 4
- **4a.** (i) sin definir → se usa el default `tempo:4317` (el default `:-` aplica cuando la variable está sin definir **o vacía**); (ii) string vacío → igual que sin definir, se usa el default `tempo:4317`; (iii) definido con un valor → se usa ese valor literalmente.
- **4b.** La **última** fuente gana para un escalar en conflicto. Las fuentes `--config` se fusionan de izquierda a derecha, así que el inline `yaml:...verbosity: detailed` (dado último) sobreescribe a `overlay.yaml` (`basic`), que sobreescribe a `base.yaml` (`${env:...}`). Los flags `--config` posteriores sobreescriben a los anteriores en la misma clave escalar; los mapas se fusionan en profundidad.
- **4c.** Cualesquiera dos de: `file:` (una ruta), `yaml:` (fragmento YAML inline), `http:`/`https:` (obtener una configuración remota), más el propio `env:`. (Estos son los *providers* de configuración.)
- **4d.** Mantiene fuera del control de versiones los valores específicos del entorno y los que rotan, así que un único YAML versionado sirve para dev/staging/prod. El riesgo con los secretos es que una variable de entorno de contenedor en texto plano es visible para cualquier cosa que pueda leer el entorno del proceso (`/proc/<pid>/environ`, `docker inspect`, `kubectl describe pod`), así que los secretos deberían venir de un archivo montado/almacén de secretos en lugar de una variable `-e` en texto plano.

### Exercise 5
- **5a.** Las extensions se activan listándolas bajo `service.extensions`, no dentro de un pipeline. Brindan capacidades a nivel de todo el Collector que *no* forman parte del flujo de datos de telemetría — health checking, profiling (`pprof`), diagnósticos en vivo (`zpages`), autenticación, almacenamiento — en lugar de recibir/procesar/exportar señales.
- **5b.** Regla: **los receivers y exporters se comparten como una única instancia** cuando el mismo id de componente se reutiliza a lo largo de pipelines (fan-out desde un receiver, fan-in hacia un exporter); **los processors se instancian una vez por pipeline**. Así que acá: `otlp` → un receiver compartido; `otlp/backend` → un exporter compartido; `memory_limiter` y `batch` → dos instancias cada uno (una por pipeline). Por eso el ajuste por pipeline de `batch`/`memory_limiter` es independiente.
- **5c.** `:8888` sirve las métricas operativas **propias** del Collector (`otelcol_receiver_accepted_*`, `otelcol_processor_dropped_*`, `otelcol_exporter_sent_*`, `otelcol_exporter_send_failed_*`), que describen la *maquinaria del pipeline*, no la telemetría del cliente que pasa a través. Cuando los datos parecen "perderse", comparar los contadores de aceptados-vs-enviados-vs-fallidos localiza la pérdida en un receiver, un processor (por ej. `refused`/`dropped`) o un exporter que falla — mucho más rápido que adivinar.
- **5d.** No. Declarar `zpages` bajo `extensions:` sin listarlo en `service.extensions` lo deja inerte — como cualquier componente, una extension solo se inicia cuando el bloque `service` la activa. `:55679` no se serviría.

### Exercise 6
- **6a.** Un connector se cablea *entre dos pipelines*: es un exporter en uno y un receiver en otro, así que puede tender un puente entre tipos de señal (por ej. traces→metrics) y cruzar fronteras de pipeline. Un processor vive *dentro de un único pipeline* y no puede emitir hacia un pipeline distinto ni cambiar el tipo de señal del pipeline, así que `spanmetrics` — que lee spans y produce un nuevo stream de métricas que alimenta un pipeline de metrics separado — no puede expresarse como un processor.
- **6b.** El pipeline de **traces** es el lado del exporter (exporta spans *hacia* el connector); el pipeline de **metrics** (`metrics/spanmetrics`) es el lado del receiver (recibe las métricas generadas *desde* el connector).
- **6c.** El propósito entero de un connector es tender un puente entre dos pipelines; cableado de un solo lado no tiene ni fuente ni destino, lo que carece de sentido. Por eso el Collector impone que un connector aparezca como exporter (en un pipeline) y como receiver (en otro) de los tipos de señal correctos, y falla la validación en caso contrario — como se vio en el paso 3.
- **6d.** Cualquiera de: es agnóstico de la instrumentación (funciona para todo servicio que ya emite spans, sin cambio de código por aplicación); produce métricas RED consistentes con dimensiones/bucketing uniformes a lo largo de todos los servicios; y descarga la agregación de la aplicación hacia el Collector, reduciendo el overhead por servicio y la deriva de cardinalidad.

</details>