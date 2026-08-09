# 2.5 Formato de Exposición — Ejercicios Guiados

> **Alcance.** Estos labs te hacen *leer, escribir, validar y negociar* los dos formatos de exposición basados en texto que Prometheus entiende — el clásico **formato de texto de Prometheus `0.0.4`** y **OpenMetrics `1.0.0`** — más la mecánica de cómo un scrape efectivamente los recupera sobre HTTP. Peso en el examen: 4.
>
> **Prerrequisitos.** Un `docker` (o `podman`) funcionando, `curl` y una shell. `promtool` viene *dentro* de la imagen `prom/prometheus`, así que no necesitás una instalación aparte; lo invocamos con `docker exec`.

**Levantá el target una vez y dejalo corriendo** — cada ejercicio lo reutiliza:

```bash
docker run -d --name prom -p 9090:9090 prom/prometheus:v2.53.0
# wait ~2s for the server to start, then confirm it answers:
curl -s -o /dev/null -w '%{http_code}\n' localhost:9090/metrics
```

Esperado:

```
200
```

Prometheus expone sus **propios** internos en `/metrics` usando la librería cliente de Go, que convenientemente nos da los cuatro tipos de métrica centrales (`counter`, `gauge`, `histogram`, `summary`) desde un único endpoint.

---

## Exercise 1 — Los tres tipos de línea

Una exposición es texto UTF-8 orientado a líneas, separado por `\n`. Cada línea es exactamente una de: una línea de metadata `# HELP`, una línea de metadata `# TYPE`, o una **muestra** (un comentario `# ...` que no es ni HELP ni TYPE se ignora). Veamos los tres.

**Pasos**

1. Recuperá el endpoint crudo y leé el primer bloque de métrica:

   ```bash
   curl -s localhost:9090/metrics | grep -A2 '^# HELP go_goroutines'
   ```

   Esperado:

   ```
   # HELP go_goroutines Number of goroutines that currently exist.
   # TYPE go_goroutines gauge
   go_goroutines 42
   ```

2. Contá cuántas líneas son metadata vs. muestras para una métrica más ocupada:

   ```bash
   curl -s localhost:9090/metrics | grep '^prometheus_http_requests_total'
   ```

   Esperado (los valores diferirán):

   ```
   prometheus_http_requests_total{code="200",handler="/-/ready"} 3
   prometheus_http_requests_total{code="200",handler="/metrics"} 8
   prometheus_http_requests_total{code="200",handler="/api/v1/query"} 2
   ```

3. Confirmá que la metadata aparece **una vez por familia de métrica**, no una vez por muestra:

   ```bash
   curl -s localhost:9090/metrics | grep -c '^# TYPE prometheus_http_requests_total'
   ```

   Esperado:

   ```
   1
   ```

**Comprensión**

- **Q1.1** Un único par `# HELP`/`# TYPE` describió tres muestras `prometheus_http_requests_total` en el paso 2. ¿Qué distingue a esas tres muestras entre sí, dado que comparten el mismo nombre de métrica?
- **Q1.2** Si un exporter emitiera una línea `# some free-form note here`, ¿cómo la trata el parser?
- **Q1.3** La línea `# TYPE go_goroutines gauge` — ¿es obligatoria para una exposición válida? ¿Qué asume Prometheus si está ausente?

---

## Exercise 2 — Anatomía de una línea de muestra

Una muestra es `metric_name [ "{" label_name="value",… "}" ] SP value [ SP timestamp ]`. Diseccioná cada campo.

**Pasos**

1. Aislá una muestra de counter completamente etiquetada:

   ```bash
   curl -s localhost:9090/metrics \
     | grep '^prometheus_http_requests_total{code="200",handler="/metrics"}'
   ```

   Esperado:

   ```
   prometheus_http_requests_total{code="200",handler="/metrics"} 8
   ```

2. Verificá la regla de caracteres del nombre de métrica. Los nombres válidos coinciden con `[a-zA-Z_:][a-zA-Z0-9_:]*`; los dos puntos están **reservados para las recording rules**, así que los exporters no deben usarlos. Probá que ninguna métrica de exporter contenga dos puntos:

   ```bash
   curl -s localhost:9090/metrics | grep -E '^[a-zA-Z_]+:[a-zA-Z_]*' | head
   ```

   Esperado: *(sin salida — grep sale con código distinto de cero)*

3. Observá que los valores son floats parseables por Go, incluyendo notación científica:

   ```bash
   curl -s localhost:9090/metrics | grep '^go_memstats_alloc_bytes '
   ```

   Esperado:

   ```
   go_memstats_alloc_bytes 1.8874e+07
   ```

4. Notá que el propio endpoint de Prometheus omite el **timestamp** opcional por muestra (deja que el scraper estampe la muestra en el momento del scrape — el caso normal). La gramática de la línea *permite* un timestamp int64 al final en **milisegundos** desde la época Unix, por ejemplo `my_metric 42 1609459200000`.

**Comprensión**

- **Q2.1** En `prometheus_http_requests_total{code="200",handler="/metrics"} 8`, nombrá los cuatro campos sintácticos presentes y el único campo que está ausente.
- **Q2.2** `1.8874e+07` — ¿qué valor decimal plano es este, y por qué es aceptable la notación científica en el cable?
- **Q2.3** Un ingeniero junior hardcodea un timestamp por muestra de `1609459200` (segundos Unix) dentro de un exporter. ¿Qué sale mal, y cuál es la unidad correcta para el formato de texto clásico?
- **Q2.4** Además de los números ordinarios, ¿cuáles tres tokens de float especiales son legales como valor?

---

## Exercise 3 — Los cuatro tipos tal como aparecen en el cable

`counter` y `gauge` son muestras únicas. `histogram` y `summary` son **compuestos**: cada uno se expande en varias muestras que el parser vuelve a coser por sufijo.

**Pasos**

1. Leé la expansión del histogram:

   ```bash
   curl -s localhost:9090/metrics \
     | grep '^prometheus_http_request_duration_seconds' | head -n 12
   ```

   Esperado (abreviado):

   ```
   # HELP prometheus_http_request_duration_seconds Histogram of latencies for HTTP requests.
   # TYPE prometheus_http_request_duration_seconds histogram
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.1"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="0.2"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="1"} 12
   prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"} 12
   prometheus_http_request_duration_seconds_sum{handler="/metrics"} 0.0123
   prometheus_http_request_duration_seconds_count{handler="/metrics"} 12
   ```

2. Confirmá que los buckets son **acumulativos** ("menor o igual que `le`") y que el último bucket es siempre `le="+Inf"`, cuyo valor es igual a `_count`:

   ```bash
   curl -s localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds_bucket{handler="/metrics",le="+Inf"}'
   curl -s localhost:9090/metrics \
     | grep 'prometheus_http_request_duration_seconds_count{handler="/metrics"}'
   ```

   Ambos valores deberían coincidir.

3. Leé la expansión del summary:

   ```bash
   curl -s localhost:9090/metrics | grep '^go_gc_duration_seconds' | head -n 10
   ```

   Esperado (abreviado):

   ```
   # HELP go_gc_duration_seconds A summary of the wall-time pause (in seconds) spent in GC.
   # TYPE go_gc_duration_seconds summary
   go_gc_duration_seconds{quantile="0"} 4.5e-05
   go_gc_duration_seconds{quantile="0.5"} 0.000105
   go_gc_duration_seconds{quantile="1"} 0.000345
   go_gc_duration_seconds_sum 0.008589
   go_gc_duration_seconds_count 65
   ```

**Comprensión**

- **Q3.1** ¿Qué tres sufijos reservados componen una familia `histogram`, y qué label especial lleva el límite del bucket?
- **Q3.2** ¿Por qué debe existir el bucket `le="+Inf"`, y cuál es la relación entre su valor y la muestra `_count`?
- **Q3.3** Tanto `histogram` como `summary` publican `_sum` y `_count`. ¿Cuál es la única diferencia estructural entre ellos en el cable, y cuál de los dos computa sus percentiles **del lado del cliente, dentro del exporter**?
- **Q3.4** Una muestra de bucket de histogram lleva un label `le`; un summary lleva `quantile`. ¿Por qué no podés reutilizar de forma segura ninguno de estos nombres de label como un label de negocio ordinario en la *misma* métrica?

---

## Exercise 4 — Escribí una exposición válida y validala con `promtool`

`promtool check metrics` lee una exposición por **stdin**, la parsea y la lintea. Esta es la herramienta que vas a usar en CI para proteger un exporter.

**Pasos**

1. Escribí una exposición pequeña y correcta:

   ```bash
   cat > demo.prom <<'EOF'
   # HELP myapp_requests_total Total number of processed requests.
   # TYPE myapp_requests_total counter
   myapp_requests_total{method="get",status="200"} 1027
   myapp_requests_total{method="post",status="500"} 3
   # HELP myapp_temperature_celsius Current sensor temperature.
   # TYPE myapp_temperature_celsius gauge
   myapp_temperature_celsius 23.5
   EOF
   ```

2. Validala:

   ```bash
   cat demo.prom | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado (parseo limpio, sin hallazgos de lint):

   ```
   exit=0
   ```

3. **Rompé la sintaxis** — agregá un segundo `# HELP` para la misma métrica:

   ```bash
   printf '# HELP x_total help one.\n# TYPE x_total counter\n# HELP x_total help two.\nx_total 5\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado:

   ```
   error while linting: text format parsing error in line 3: second HELP line for metric name "x_total"
   exit=1
   ```

4. **Rompé el valor** — un no-float donde se requiere un float:

   ```bash
   printf '# TYPE y_total counter\ny_total abc\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado:

   ```
   error while linting: text format parsing error in line 2: expected float as value, got "abc"
   exit=1
   ```

5. **Disparar una regla de lint (no un error de sintaxis)** — un counter sin el sufijo `_total`:

   ```bash
   printf '# HELP myapp_requests requests.\n# TYPE myapp_requests counter\nmyapp_requests 5\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado:

   ```
   myapp_requests counter metrics should have "_total" suffix
   exit=1
   ```

**Comprensión**

- **Q4.1** El archivo limpio del paso 1 declaró cada `# HELP`/`# TYPE` una vez pero tenía **dos** muestras `myapp_requests_total`. ¿Por qué eso es legal, mientras que dos líneas `# HELP` (paso 3) no lo es?
- **Q4.2** El paso 5 produjo un mensaje de *lint*, no un error de *parseo*. Explicá la diferencia entre las dos clases de problema que reporta `promtool check metrics`, y por qué ambos igual dan código de salida 1.
- **Q4.3** Tu CI corre `curl -s http://exporter/metrics | promtool check metrics`. Dá dos defectos reales distintos que esto atrapa *antes* de que las métricas lleguen a un TSDB de Prometheus.

---

## Exercise 5 — Escape de valores de label

Los **valores** de label pueden contener UTF-8 arbitrario, pero tres caracteres deben escaparse: backslash `\` → `\\`, comilla doble `"` → `\"`, y line-feed → `\n`. (En los docstrings de `# HELP`, se escapan el backslash y el line-feed; la comilla no es especial ahí.) Los **nombres** de label son estrictos: `[a-zA-Z_][a-zA-Z0-9_]*`, y los nombres que empiezan con `__` están reservados para uso interno.

**Pasos**

1. Escribí una métrica cuyos labels contengan cada carácter complicado:

   ```bash
   cat > escapes.prom <<'EOF'
   # HELP myapp_build_info Build metadata.
   # TYPE myapp_build_info gauge
   myapp_build_info{path="C:\\logs\\app.log",quote="he said \"hi\"",multi="line1\nline2"} 1
   EOF
   ```

2. Validá — el escape correcto parsea limpiamente:

   ```bash
   cat escapes.prom | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado:

   ```
   exit=1
   ```

   …a causa de un hallazgo de **lint** (las métricas `_info` tienen una convención de nomenclatura). Confirmá que **no hay error de parseo** — el escape en sí es válido:

   ```bash
   cat escapes.prom | docker exec -i prom promtool check metrics 2>&1 | grep -i 'parsing error'; echo "found=$?"
   ```

   Esperado:

   ```
   found=1
   ```

   *(grep no encontró nada → el escape del valor es sintácticamente correcto.)*

3. **Rompelo** — una comilla literal sin escapar dentro de un valor termina el valor antes de tiempo:

   ```bash
   printf 'myapp_build_info{note="say "hi""} 1\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado:

   ```
   error while linting: text format parsing error in line 1: expected "=" after label name, found ...
   exit=1
   ```

4. **Rompé el nombre del label** — un guion es ilegal en un nombre de label:

   ```bash
   printf 'myapp_x{trace-id="abc"} 1\n' \
     | docker exec -i prom promtool check metrics; echo "exit=$?"
   ```

   Esperado: un error de parseo (`invalid label name` / carácter inesperado), salida `1`.

**Comprensión**

- **Q5.1** ¿Cuáles exactamente tres caracteres requieren escape dentro de un **valor** de label, y en qué se convierte cada uno?
- **Q5.2** En el paso 3, ¿por qué el *parser* — y no una regla de lint — rechaza `note="say "hi""`? Rastreá lo que ve el tokenizer después de la primera comilla de cierre.
- **Q5.3** Un colega quiere un label llamado `trace-id`. Dá la regla que viola y un nombre conforme.
- **Q5.4** ¿Es el valor de label de string vacío `foo{bar=""} 1` lo mismo, para Prometheus, que omitir el label `bar` por completo? Justificá.

---

## Exercise 6 — OpenMetrics vs. el formato de texto clásico (content negotiation)

Prometheus (como scraper) y el cliente de Go (como exporter) hablan **dos** formatos. El cliente elige uno según el header `Accept` de la request. OpenMetrics `1.0.0` es el sucesor en la vía IETF: exige un `# EOF` al final, requiere el sufijo `_total` en los counters, usa **segundos** (float) para los timestamps, agrega metadata `# UNIT` y series `_created`, y soporta **exemplars**.

**Pasos**

1. Mirá qué negocia la request *por defecto* (curl envía `Accept: */*`):

   ```bash
   curl -s -D - -o /dev/null localhost:9090/metrics | grep -i '^content-type'
   ```

   Esperado:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

2. Pedí explícitamente OpenMetrics e inspeccioná el tipo negociado:

   ```bash
   curl -s -D - -o /dev/null \
     -H 'Accept: application/openmetrics-text; version=1.0.0; charset=utf-8' \
     localhost:9090/metrics | grep -i '^content-type'
   ```

   Esperado:

   ```
   Content-Type: application/openmetrics-text; version=1.0.0; charset=utf-8
   ```

3. Confirmá que el cuerpo de OpenMetrics termina con el centinela obligatorio:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
     localhost:9090/metrics | tail -n 1
   ```

   Esperado:

   ```
   # EOF
   ```

4. Compará la presentación de un counter entre los dos formatos. En el formato de texto clásico un counter puede aparecer con o sin `_total`; en OpenMetrics el sufijo `_total` es **obligatorio** y la línea de tipo describe la familia sin él. Notá también que OpenMetrics prohíbe las líneas en blanco y puede agregar series de timestamp `_created`.

5. Los **exemplars** adjuntan una referencia de trace a una muestra; existen *solo* en OpenMetrics y *solo* en muestras de counter (`_total`) y de histogram `_bucket`. Su forma en el cable es un sufijo delimitado por `#`:

   ```
   myapp_requests_total{method="get"} 1027 # {trace_id="abcd1234"} 1.0 1609459200.0
   #                                    │   └ exemplar labels    │   └ optional ts (seconds)
   #                                    └ separates sample from   └ exemplar value
   #                                      exemplar
   ```

**Comprensión**

- **Q6.1** ¿Cómo decide un exporter si emitir formato de texto clásico u OpenMetrics para un scrape dado? ¿Qué header HTTP lo determina, y qué lado (scraper o exporter) lo envía?
- **Q6.2** Nombrá tres diferencias concretas que un `diff` a nivel de bytes revelaría entre los dos formatos para el *mismo* conjunto de métricas.
- **Q6.3** Un timestamp por muestra dice `1609459200000` en un formato y `1609459200.000` en el otro. ¿Cuál es cuál, y cuáles son las unidades?
- **Q6.4** Querés adjuntar un exemplar `trace_id` a un gauge. ¿Por qué es imposible, y en qué dos tipos de muestra *sí* se permiten los exemplars?
- **Q6.5** Un parser llega al EOF de un stream de OpenMetrics pero nunca vio `# EOF`. ¿Qué debe hacer un parser estricto de OpenMetrics, y por qué el formato de texto clásico no necesita tal marcador?

---

## Exercise 7 — Más allá del texto: protobuf y native histograms (conocimiento general)

Los dos formatos de texto no son la única codificación en el cable. Prometheus conserva un formato de exposición **Protocol Buffer**, y es el *único* transporte para los **native (sparse) histograms**, que codifican buckets exponenciales mucho más compactamente que los buckets `le` fijos de un histogram clásico.

**Pasos**

1. Observá que el scraper moderno de Prometheus anuncia protobuf en sus propias requests de scrape. Inspeccioná el header `Accept` que Prometheus *envía* apuntándole un listener descartable — o simplemente razoná desde la config: los native histograms requieren `--enable-feature=native-histograms`, y Prometheus entonces negocia `application/vnd.google.protobuf` primero en su `Accept`.

2. Confirmá que tus habilidades con el formato de texto siguen valiendo: los native histograms *hacen fallback* a una representación clásica con buckets cuando se scrapean sobre texto, así que un histogram clásico sigue siendo la línea base interoperable.

**Comprensión**

- **Q7.1** ¿Por qué un **native histogram** no puede representarse en el formato de texto clásico `0.0.4` sin pérdida, y qué transporte lo lleva sin pérdida?
- **Q7.2** Dado que protobuf existe y es más compacto, ¿por qué el formato de texto sigue siendo el default recomendado para exporters escritos a mano y debugging rápido?

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Exercise 1
- **Q1.1** Sus **conjuntos de labels** difieren (combinaciones de `code`/`handler`). Una "métrica" (una time series) se identifica por el nombre de la métrica **más** su conjunto único de pares nombre/valor de label; las tres líneas son tres series distintas de la misma *familia* de métrica.
- **Q1.2** Como un comentario común: cualquier línea `#` que no sea `# HELP` o `# TYPE` es ignorada por el parser.
- **Q1.3** No, `# TYPE` es opcional. Si está ausente, la métrica se trata como **`untyped`** (formato de texto clásico) / **`unknown`** (OpenMetrics) — Prometheus igual ingiere las muestras pero sin semántica de tipo. `# HELP` es igualmente opcional.

### Exercise 2
- **Q2.1** Presentes: (1) el nombre de métrica `prometheus_http_requests_total`, (2) el conjunto de labels `{code="200",handler="/metrics"}`, (3) el valor `8`. Ausente: (4) el **timestamp** opcional por muestra.
- **Q2.2** `1.8874e+07` = `18,874,000`. Los valores se parsean con `ParseFloat` de Go, que acepta notación científica, así que los exporters pueden emitir números grandes/chicos de forma compacta.
- **Q2.3** Proveer segundos donde se esperan **milisegundos** hace que Prometheus interprete la muestra como ~enero de 1970, así que o se rechaza por estar demasiado lejos de la ventana de scrape o cae con un timestamp descabelladamente equivocado. Los timestamps del formato de texto clásico son int64 en **milisegundos** desde la época Unix. (OpenMetrics, en cambio, usa segundos como float.) El hábito correcto es emitir **ningún** timestamp y dejar que el scraper lo estampe.
- **Q2.4** `NaN`, `+Inf`, `-Inf`.

### Exercise 3
- **Q3.1** `_bucket`, `_sum`, `_count`. El límite del bucket lo lleva el label reservado `le` ("less than or equal" / menor o igual).
- **Q3.2** `le="+Inf"` cuenta cada observación sin importar el tamaño, así que es el total; por lo tanto su valor es **igual** a la muestra `_count`. Sin él no habría forma de saber cuántas observaciones cayeron por encima del bucket finito más grande.
- **Q3.3** Diferencia estructural: un `histogram` lleva muestras `_bucket{le=…}`; un `summary` lleva muestras `{quantile=…}` en lugar de buckets. El **summary** computa sus φ-quantiles del lado del cliente dentro del exporter (no pueden agregarse entre instancias después), mientras que un histogram envía buckets crudos y los quantiles se estiman más tarde vía `histogram_quantile()` en PromQL.
- **Q3.4** Porque en esas métricas `le` y `quantile` son labels **reservados, estructurales** que el parser usa para reconstruir el tipo compuesto. Reutilizarlos como labels de negocio choca con la maquinaria de tipos y corrompe la interpretación de buckets/quantiles.

### Exercise 4
- **Q4.1** Múltiples **muestras** de una familia son el caso normal — son series distintas que difieren por labels. Pero `# HELP`/`# TYPE` son **metadata a nivel de familia**; el formato permite exactamente una de cada una por nombre de métrica, así que un segundo `# HELP` es un error de sintaxis.
- **Q4.2** Un **error de parseo** significa que los bytes no son una exposición bien formada (el parser no puede construir muestras en absoluto). Un hallazgo de **lint** significa que la entrada parseó bien pero viola una convención de buenas prácticas/nomenclatura (por ejemplo, un counter sin `_total`). Ambos son tratados como fallas por `promtool check metrics`, así que ambos salen con `1` — que es lo que le permite gatear el CI.
- **Q4.3** Dos cualesquiera de: un counter al que le falta o usa mal el sufijo `_total`; un valor no-float; un `# HELP`/`# TYPE` duplicado; un label malformado (nombre inválido, comilla sin escapar); un histogram al que le falta su bucket `+Inf`; texto HELP faltante; unidades no base.

### Exercise 5
- **Q5.1** `\` → `\\`, `"` → `\"`, line-feed → `\n`.
- **Q5.2** Después de `note="say "`, el parser ya consumió un valor completo y cerrado (`say `). El siguiente carácter `h` es donde espera o bien una coma (otro label) o `}`. Al ver `hi` ahí, reporta que no puede encontrar el `=`/`,`/`}` que necesita — una violación de **gramática**, de ahí un error de parseo, no una advertencia de lint.
- **Q5.3** Los nombres de label deben coincidir con `[a-zA-Z_][a-zA-Z0-9_]*`; `-` no está permitido. Usá `trace_id`.
- **Q5.4** Sí — un **valor de label vacío es equivalente a que el label esté ausente**. `foo{bar=""} 1` y `foo 1` refieren a la misma time series.

### Exercise 6
- **Q6.1** El **scraper** envía un header `Accept`; el **exporter** lo respeta y elige el mejor formato que puede servir (content negotiation). `Accept: application/openmetrics-text…` produce OpenMetrics; `Accept: */*` (o una preferencia de text/plain) produce el clásico `0.0.4`.
- **Q6.2** Tres cualesquiera de: OpenMetrics termina con `# EOF` (el formato de texto no); el `Content-Type` de OpenMetrics es `application/openmetrics-text; version=1.0.0`; los counters siempre llevan el sufijo `_total` en OpenMetrics; los timestamps son float en **segundos** vs. int en **milisegundos**; OpenMetrics puede agregar series `_created` y líneas `# UNIT` y exemplars; OpenMetrics prohíbe las líneas en blanco.
- **Q6.3** `1609459200000` es el **formato de texto clásico** (int64 en **milisegundos**); `1609459200.000` es **OpenMetrics** (float en **segundos**).
- **Q6.4** Los exemplars son una característica de OpenMetrics y se permiten **solo** en muestras de counter (`_total`) y de histogram `_bucket` — los puntos a los que un trace de "un evento representativo" se adjunta de forma significativa. Un gauge es un nivel actual, no un conteo de eventos discretos, así que no existe ranura de exemplar para él.
- **Q6.5** Un parser estricto de OpenMetrics debe tratar un stream que termina sin `# EOF` como **truncado/inválido** y rechazarlo — el marcador garantiza que el scraper recibió el payload completo (protegiendo contra un corte de conexión a mitad de transferencia). El formato de texto clásico no tiene tal garantía; simplemente parsea las líneas que lleguen.

### Exercise 7
- **Q7.1** Un native histogram usa un esquema de buckets sparse, dinámico y espaciado exponencialmente, con una resolución que los buckets `le` de string fijo de `0.0.4` no pueden expresar sin conteos de buckets enormes o pérdida de precisión. Se lleva sin pérdida sobre el formato de exposición **Protocol Buffer** (`application/vnd.google.protobuf`).
- **Q7.2** El formato de texto es legible por humanos, trivial de emitir desde cualquier lenguaje (solo imprimir líneas), e instantáneamente debuggeable con `curl`/`grep`/`promtool` — sin schema ni codec necesarios. La compacidad de protobuf importa a escala pero cuesta tooling y legibilidad, así que el texto sigue siendo el default para autoría y troubleshooting.

</details>

---

### Sources
- Prometheus — *Exposition formats* (text format `0.0.4`, escaping, histogram/summary rules): https://prometheus.io/docs/instrumenting/exposition_formats/
- OpenMetrics specification `1.0.0` (`# EOF`, `_total`, `_created`, exemplars, seconds timestamps): https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md
- Prometheus — *Metric and label naming* best practices (`_total`, base units, reserved characters): https://prometheus.io/docs/practices/naming/
- Prometheus — *Metric types* (counter, gauge, histogram, summary; native histograms): https://prometheus.io/docs/concepts/metric_types/
- `promtool` reference (`check metrics` lint/validate): https://prometheus.io/docs/prometheus/latest/command-line/promtool/
- CNCF PCA Curriculum: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf