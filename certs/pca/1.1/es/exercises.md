# PCA — Dominio: PromQL
## Tema 1.1 — Seleccionar datos

> **Peso en el examen:** 4 · **Dominio:** PromQL
> Todo lo que graficás, alertás o agregás en Prometheus empieza con un *selector*: la expresión que decide **qué series temporales** y **qué muestras de ellas** entran en la consulta. Si el selector está mal, cada `rate()`, `sum()` o umbral de alerta que venga después también estará mal. Este tema cubre los dos tipos de selector — **selectores de vector instantáneo** y **selectores de vector de rango** — más los matchers de etiquetas, el modificador `offset` y el modificador `@` que los gobiernan.
>
> Fuentes de referencia:
> - Fundamentos de PromQL — <https://prometheus.io/docs/prometheus/latest/querying/basics/>
> - Operadores / modificadores de PromQL — <https://prometheus.io/docs/prometheus/latest/querying/operators/>
> - Currículum de PCA — <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>

---

## Ejercicio 0 — Levantar un lab que produzca datos para seleccionar

Necesitás un Prometheus corriendo con algunos targets para que los selectores devuelvan resultados no vacíos. Con que Prometheus haga scraping de *sí mismo* alcanza para este tema.

1. Creá una configuración mínima `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Lanzá Prometheus (fijá una versión para que las salidas sean reproducibles):

   ```bash
   docker run --rm -d --name prom \
     -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:v2.53.0
   ```

3. Confirmá que está arriba y que se hizo scraping a sí mismo al menos dos veces (esperá ~30 s):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Esperado (un target, sano):

   ```json
   [
     {
       "metric": {
         "__name__": "up",
         "instance": "localhost:9090",
         "job": "prometheus"
       },
       "value": [ 1717000000.123, "1" ]
     }
   ]
   ```

4. Abrí el explorador de expresiones en <http://localhost:9090/graph> — vas a correr la mayoría de las consultas ahí y a verificar algunas por la HTTP API.

> **Q0.1** En el JSON de arriba, ¿qué representan los dos elementos de `"value": [ 1717000000.123, "1" ]`?
> **Q0.2** ¿Por qué las instrucciones dijeron de esperar ~30 s antes de esperar `up == 1`?

---

## Ejercicio 1 — Selectores de vector instantáneo: seleccionar una métrica entera

Un **selector de vector instantáneo** escrito solo como un nombre de métrica devuelve, para **cada** serie que lleve ese nombre, la **única muestra más reciente** en o antes del momento de evaluación (sujeto al lookback de staleness, por defecto 5 minutos).

1. En el explorador de expresiones, ejecutá:

   ```promql
   prometheus_http_requests_total
   ```

2. Cambiá a la pestaña **Table**. Vas a ver una fila por serie (por cada combinación de `code`/`handler`), cada una terminando en un número — el valor actual del contador:

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query",    instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="200", handler="/-/healthy",       instance="localhost:9090", job="prometheus"}    4
   prometheus_http_requests_total{code="200", handler="/metrics",         instance="localhost:9090", job="prometheus"}   22
   prometheus_http_requests_total{code="302", handler="/",                instance="localhost:9090", job="prometheus"}    1
   ...
   ```

3. Contá cuántas series coincidieron, sin leerlas una por una:

   ```promql
   count(prometheus_http_requests_total)
   ```

   ```
   {}   9
   ```

4. Ahora pedí un nombre de métrica que no existe:

   ```promql
   prometheus_http_requests_totl
   ```

   El resultado es **vacío** (sin error) — un error de tipeo en el nombre de una métrica devuelve nada silenciosamente.

> **Q1.1** Un selector de vector instantáneo pelado, ¿cuántas muestras devuelve *por cada serie que coincide*, y desde qué punto en el tiempo?
> **Q1.2** Ejecutás `prometheus_http_requests_total` y obtenés cero filas, pero estás seguro de que la métrica existía hace 20 minutos y desde entonces el target desapareció. Dá los dos mecanismos que juntos explican el resultado vacío.
> **Q1.3** ¿Por qué `count(prometheus_http_requests_total)` es una sonda más segura de "¿existe esta métrica y qué tan grande es su cardinalidad?" que mirar la tabla a ojo?

---

## Ejercicio 2 — Filtrar con matchers de etiqueta de igualdad

Un selector acota el conjunto de series con matchers de etiqueta `{...}`. Los dos matchers de igualdad son `=` (igual) y `!=` (distinto).

1. Quedate solo con el handler `/api/v1/query`:

   ```promql
   prometheus_http_requests_total{handler="/api/v1/query"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="400", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}    2
   ```

2. Apilá matchers — se combinan con **AND** lógico. Quedate con ese handler **y** solo con las respuestas exitosas:

   ```promql
   prometheus_http_requests_total{handler="/api/v1/query", code="200"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query", instance="localhost:9090", job="prometheus"}   17
   ```

3. Invertí un matcher — todos los handlers **excepto** `/metrics`:

   ```promql
   prometheus_http_requests_total{handler!="/metrics"}
   ```

4. Un comportamiento sutil pero importante — `!=` también coincide con series donde la etiqueta está **ausente** (una etiqueta ausente se trata como la cadena vacía, y `"" != "/metrics"`). Confirmá que la población de `/metrics` fue excluida:

   ```promql
   count(prometheus_http_requests_total) - count(prometheus_http_requests_total{handler!="/metrics"})
   ```

   ```
   {}   1
   ```

> **Q2.1** ¿Cómo se combinan múltiples matchers dentro de un mismo `{}` — AND u OR?
> **Q2.2** Una métrica `api_latency` tiene algunas series con una etiqueta `region` y otras sin ella del todo. ¿`api_latency{region!="eu"}` devuelve las series que *no* tienen etiqueta `region`? ¿Por qué?
> **Q2.3** Reescribí "el handler `/metrics`, pero solo respuestas no-2xx" como un único selector. (Asumí que los códigos 2xx son exactamente `"200"` acá.)

---

## Ejercicio 3 — Matchers de regex y anclado completo

`=~` (coincidencia de regex) y `!~` (no coincidencia de regex) usan sintaxis RE2. **Regla crítica:** los matchers de regex están **completamente anclados** — el patrón debe coincidir con el valor *entero* de la etiqueta, como si estuviera envuelto en `^(?:...)$`.

1. Probá la consulta intuitiva-pero-incorrecta "empieza con /api":

   ```promql
   prometheus_http_requests_total{handler=~"/api"}
   ```

   Resultado: **vacío.** Ningún valor de handler es *exactamente* `/api`; son `/api/v1/query`, `/api/v1/label/...`, etc. El anclado hace que `=~"/api"` se comporte como `="/api"`.

2. Arreglalo haciendo coincidir el valor entero:

   ```promql
   prometheus_http_requests_total{handler=~"/api/.*"}
   ```

   ```
   prometheus_http_requests_total{code="200", handler="/api/v1/query",  instance="localhost:9090", job="prometheus"}   17
   prometheus_http_requests_total{code="400", handler="/api/v1/query",  instance="localhost:9090", job="prometheus"}    2
   prometheus_http_requests_total{code="200", handler="/api/v1/labels", instance="localhost:9090", job="prometheus"}    3
   ...
   ```

3. Usá alternancia para seleccionar dos clases de estado exactas a la vez:

   ```promql
   prometheus_http_requests_total{code=~"400|500"}
   ```

4. Ahora topate con la **regla del matcher vacío**. Un selector debe contener al menos un matcher que *no* coincida con la cadena vacía. Ejecutá:

   ```promql
   prometheus_http_requests_total{code=~".*"}
   ```

   Prometheus lo rechaza:

   ```
   Error executing query: vector selector must contain at least one non-empty matcher
   ```

   Pará — ese error solo aparece cuando el nombre de la métrica *también* se saca. Con el nombre presente, `{code=~".*"}` está bien porque el nombre mismo es un matcher no vacío. Demostrá la regla sacando también el nombre:

   ```promql
   {code=~".*"}
   ```

   ```
   Error executing query: vector selector must contain at least one non-empty matcher
   ```

5. El arreglo legal es un matcher que no pueda coincidir con vacío — p. ej. `.+`:

   ```promql
   {code=~".+"}
   ```

   Esto ahora devuelve **cada serie del TSDB que tenga una etiqueta `code` no vacía**, a través de todos los nombres de métrica.

> **Q3.1** ¿Por qué `handler=~"/api"` no devuelve nada aunque muchos handlers empiecen con `/api`? Escribí la forma equivalente a la que el motor efectivamente lo compila.
> **Q3.2** `{job=~".*"}` es rechazado pero `{job=~".+"}` es aceptado. Enunciá la regla y explicá la diferencia entre `.*` y `.+` acá.
> **Q3.3** Aplicá el razonamiento de `code=~"400|500"`: ¿coincide con un código de `"4000"`? ¿Por qué sí o por qué no?

---

## Ejercicio 4 — La meta-etiqueta `__name__`

El nombre de la métrica es en sí una etiqueta: `__name__`. Cualquier cosa que puedas hacer con un nombre, la podés hacer con un matcher sobre `__name__` — que es la *única* forma de hacer coincidencia de regex a través de nombres de métrica.

1. Demostrá la equivalencia — estos dos devuelven series idénticas:

   ```promql
   prometheus_http_requests_total
   ```
   ```promql
   {__name__="prometheus_http_requests_total"}
   ```

2. Seleccioná una *familia* de métricas por patrón de nombre — cada métrica del head del TSDB que Prometheus exporta:

   ```promql
   {__name__=~"prometheus_tsdb_head_.+"}
   ```

   ```
   prometheus_tsdb_head_series{...}          1834
   prometheus_tsdb_head_chunks{...}          1834
   prometheus_tsdb_head_samples_appended_total{...}   90421
   prometheus_tsdb_head_max_time{...}        1717000000123
   ...
   ```

3. Contá cuántos nombres de métrica distintos viven en el head en este momento:

   ```promql
   count(count by (__name__) ({__name__=~".+"}))
   ```

   ```
   {}   612
   ```

> **Q4.1** ¿Cuál es la forma `{...}` completamente desazucarada del selector `up{job="prometheus"}`?
> **Q4.2** ¿Por qué *no* podés escribir `prometheus_tsdb.*` como nombre de métrica para hacer coincidir una familia, y cuál es la construcción correcta?
> **Q4.3** En el paso 3, ¿por qué `{__name__=~".+"}` es legal como selector independiente cuando `{__name__=~".*"}` sería rechazado?

---

## Ejercicio 5 — Selectores de vector de rango y sintaxis de duración

Agregar una **duración entre corchetes** convierte un selector de vector instantáneo en un **selector de vector de rango**: en vez de una muestra por serie, devuelve *todas* las muestras dentro de la ventana anterior `[d]`.

1. Pedí el último 1 minuto de muestras crudas de una serie:

   ```promql
   prometheus_http_requests_total{handler="/metrics", code="200"}[1m]
   ```

   En la vista Table obtenés una pila de pares `value @ timestamp` (aproximadamente uno por cada scrape de 15 s):

   ```
   prometheus_http_requests_total{code="200", handler="/metrics", instance="localhost:9090", job="prometheus"}
     22 @1717000000.123
     23 @1717000015.123
     24 @1717000030.123
     25 @1717000045.123
   ```

2. Intentá **graficar** esa expresión (pestaña Graph). Falla:

   ```
   Error executing query: invalid expression type "range vector" for range query, must be Scalar or instant Vector
   ```

   Un vector de rango no es directamente renderizable — debe reducirse a un vector instantáneo mediante una función. Hacé eso:

   ```promql
   rate(prometheus_http_requests_total{handler="/metrics", code="200"}[1m])
   ```

   Esto ahora grafica (tasa por segundo sobre la ventana de 1 minuto).

3. Ejercitá las **unidades de duración**. Las unidades válidas son `ms, s, m, h, d, w, y`; las duraciones compuestas deben ordenarse de **mayor → menor**, cada unidad como mucho una vez:

   ```promql
   rate(prometheus_http_requests_total[1h30m])   # valid: 1h then 30m
   ```

4. Rompé las reglas a propósito y leé las quejas del parser:

   ```promql
   prometheus_http_requests_total[5]
   ```
   ```
   Error executing query: bad number or duration syntax: "5"
   ```

   ```promql
   rate(prometheus_http_requests_total[30m1h])
   ```
   ```
   Error executing query: not a valid duration string: "30m1h"
   ```

> **Q5.1** ¿Cuál es la diferencia fundamental en la *forma* de los datos que devuelven `X` versus `X[5m]`?
> **Q5.2** ¿Por qué la expresión `prometheus_http_requests_total[1m]` se niega a graficar, y qué clase de función lo arregla?
> **Q5.3** ¿Son `[90m]` y `[1h30m]` equivalentes? ¿Es `[1h30m]` legal pero `[30m1h]` no — por qué?
> **Q5.4** ¿Aproximadamente cuántas muestras contendría `some_metric[1m]` cuando el intervalo de scrape es 15 s, y por qué es un conteo *aproximado*?

---

## Ejercicio 6 — El modificador `offset`: mirar hacia atrás en el tiempo

`offset <duration>` desplaza la evaluación de un selector hacia el pasado, **relativo al momento de evaluación de la consulta**. Es el bloque de construcción para consultas del estilo "comparado con la semana pasada".

1. Valor actual vs. el valor de hace 5 minutos:

   ```promql
   prometheus_tsdb_head_series
   ```
   ```promql
   prometheus_tsdb_head_series offset 5m
   ```

   El segundo devuelve la muestra que estaba vigente 5 minutos antes de ahora.

2. Calculá el crecimiento en la última hora usando dos selectores con offset:

   ```promql
   prometheus_tsdb_head_series - prometheus_tsdb_head_series offset 1h
   ```

   ```
   {instance="localhost:9090", job="prometheus"}   128
   ```

3. `offset` se adjunta al **selector**, no a una función/agregación que lo rodee. Esto es correcto — el offset vive *dentro* de `rate(...)` sobre el selector:

   ```promql
   sum(rate(prometheus_http_requests_total[5m] offset 1h))
   ```

4. Esto es un **error de parseo** — no podés aplicar offset al resultado de una agregación:

   ```promql
   sum(prometheus_http_requests_total) offset 1h
   ```
   ```
   Error executing query: offset modifier must be preceded by an instant vector selector or range vector selector or a subquery
   ```

5. **Offset negativo** (espiar hacia el futuro, útil con escenarios de recording-rule/backfill) y el orden preciso con vectores de rango — el offset siempre va *después* del `[range]`:

   ```promql
   rate(prometheus_http_requests_total[5m] offset -30s)
   ```

   En el Prometheus actual esto se acepta por defecto; en releases 2.2x más viejas requería `--enable-feature=promql-negative-offset`.

> **Q6.1** ¿`offset 5m` desplaza la evaluación relativo a *qué* punto de referencia?
> **Q6.2** ¿Por qué `sum(prometheus_http_requests_total) offset 1h` falla mientras `sum(prometheus_http_requests_total offset 1h)` tiene éxito? ¿Qué significan de forma distinta cada uno?
> **Q6.3** Para un vector de rango, escribí el orden correcto de tokens combinando un rango de 5 minutos y un offset de 1 semana.

---

## Ejercicio 7 — El modificador `@`: fijar a un timestamp absoluto

Donde `offset` es *relativo* al momento de evaluación, el modificador `@` **fija** la evaluación a un timestamp Unix absoluto (segundos), independiente de cuándo o sobre qué rango corre la consulta.

1. Evaluá una serie exactamente en un instante. Primero agarrá un timestamp:

   ```bash
   date -d '10 minutes ago' +%s     # e.g. 1716999400
   ```

   ```promql
   prometheus_tsdb_head_series @ 1716999400
   ```

   No importa hacia dónde arrastres un gráfico de consulta de rango, este término siempre devuelve el valor en `1716999400`.

2. Combiná `@` con un rango e incluso con `offset` (orden de evaluación: aplicar `@`, luego `offset` desplaza desde ese punto fijo):

   ```promql
   rate(prometheus_http_requests_total[5m] @ 1716999400)
   ```

3. Usá los helpers especiales `start()` / `end()`, que resuelven a los propios límites de inicio/fin de la consulta de rango — útiles en recording rules para anclar a un borde de la ventana:

   ```promql
   prometheus_tsdb_head_series @ end()
   ```

4. Un uso real común — "qué fracción del crecimiento de hoy ya había ocurrido para un checkpoint fijo" — mezclando un valor en vivo y uno fijado:

   ```promql
   prometheus_tsdb_head_samples_appended_total
     / (prometheus_tsdb_head_samples_appended_total @ 1716999400)
   ```

   En releases 2.2x más viejas el modificador `@` requería `--enable-feature=promql-at-modifier`; está habilitado por defecto en el Prometheus actual.

> **Q7.1** Enunciá la diferencia esencial entre `offset 10m` y `@ <timestamp>`.
> **Q7.2** En una consulta de **rango** (graficada), ¿cuál de estos produce una línea *plana* y cuál una que se mueve: `metric @ 1716999400` vs. `metric offset 10m`? ¿Por qué?
> **Q7.3** ¿A qué resuelven `@ start()` y `@ end()`, y en qué tipo de consulta son más útiles?

---

## Ejercicio 8 — Seleccionar datos a través de la HTTP API (lo que la UI realmente hace)

El explorador de expresiones es un cliente liviano sobre `/api/v1/query` (instantáneo) y `/api/v1/query_range` (rango). Conocer la API es examinable y esencial para hacer scripting.

1. Consulta instantánea — codificá el selector en URL:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series' | jq '.data'
   ```

   ```json
   {
     "resultType": "vector",
     "result": [
       {
         "metric": { "__name__": "prometheus_tsdb_head_series", "instance": "localhost:9090", "job": "prometheus" },
         "value": [ 1717000000.123, "1834" ]
       }
     ]
   }
   ```

2. Consulta instantánea **en un tiempo pasado** con el parámetro `time` (equivalente del lado del servidor de `@`):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series' \
     --data-urlencode 'time=1716999400' | jq '.data.result[0].value'
   ```

3. Enviá un **selector de vector de rango** al endpoint *instantáneo* e inspeccioná el tipo de resultado:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_tsdb_head_series[1m]' | jq '.data.resultType'
   ```

   ```
   "matrix"
   ```

> **Q8.1** ¿Qué cadena de `resultType` devuelve un selector de vector instantáneo pelado, y cuál devuelve un selector de vector de rango?
> **Q8.2** ¿Cuál es el equivalente en parámetro de API de poner `@ 1716999400` en un selector en una consulta instantánea?
> **Q8.3** ¿Por qué el selector debe pasarse con `--data-urlencode` en vez de concatenarse crudo en la URL?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 0**
- **Q0.1** `[ 1717000000.123, "1" ]` es `[<timestamp de evaluación en segundos Unix, float>, <valor de la muestra como cadena>]`. Prometheus devuelve los valores de las muestras como cadenas JSON para preservar la precisión completa de float y los valores especiales (`NaN`, `+Inf`).
- **Q0.2** Con un `scrape_interval` de 15 s, el primer scrape ocurre poco después del arranque y una serie necesita al menos un scrape exitoso para existir. Esperar ~30 s garantiza que al menos uno (por lo general dos) scrapes hayan aterrizado, así `up` está presente y `== 1`.

**Ejercicio 1**
- **Q1.1** Exactamente **una** muestra por serie que coincida — la muestra más reciente en o antes del instante de evaluación, siempre que caiga dentro de la ventana de lookback de staleness (`--query.lookback-delta`, por defecto 5 m).
- **Q1.2** (1) El **lookback de staleness**: con el target desaparecido, la última muestra real es más vieja que 5 minutos, así que está fuera de la ventana de lookback. (2) Los **marcadores de staleness**: cuando un target desaparece, Prometheus inyecta un marcador de stale para que la serie deje de devolver un valor casi de inmediato en vez de persistir durante los 5 minutos completos. Juntos, la serie no devuelve datos.
- **Q1.3** `count()` colapsa el conjunto a un único número tipo escalar, así aprendés "existe / cuántas series" de un vistazo sin scrollear — y no va a ocultar accidentalmente explosiones de alta cardinalidad como podría hacerlo una tabla truncada.

**Ejercicio 2**
- **Q2.1** **AND.** Todos los matchers en un mismo `{}` deben satisfacerse simultáneamente.
- **Q2.2** Sí. Una etiqueta faltante se trata como la cadena vacía `""`, y `"" != "eu"` es verdadero, así que las series que carecen de `region` por completo son devueltas por `!=`. (Esta es la trampa clásica: `!=`/`!~` incluyen series con la etiqueta ausente.)
- **Q2.3** `prometheus_http_requests_total{handler="/metrics", code!="200"}`.

**Ejercicio 3**
- **Q3.1** Los matchers de regex están **completamente anclados**, así que `handler=~"/api"` compila efectivamente a `^(?:/api)$` — coincide solo con la cadena exacta `/api`, que ningún handler iguala. Forma equivalente: `handler=~"^(?:/api)$"` (es decir, se comporta como `handler="/api"`).
- **Q3.2** Regla: *un selector de vector debe contener al menos un matcher que no coincida con la cadena vacía.* `.*` coincide con la cadena vacía (cero o más), así que `{job=~".*"}` por sí solo es ilegal; `.+` requiere al menos un carácter, así que no puede coincidir con vacío y `{job=~".+"}` es legal.
- **Q3.3** `code=~"400|500"` está anclado, así que significa `^(?:400|500)$` — el valor debe ser exactamente `400` o exactamente `500`. `"4000"` **no** coincide, porque el anclado prohíbe caracteres extra al final.

**Ejercicio 4**
- **Q4.1** `{__name__="up", job="prometheus"}`.
- **Q4.2** El nombre de la métrica no es un token comodín; es una etiqueta (`__name__`). Para hacer coincidencia de patrón sobre nombres debés usar un matcher de regex sobre esa etiqueta: `{__name__=~"prometheus_tsdb.*"}` (anclado, así que incluí `.*`).
- **Q4.3** `.+` no puede coincidir con la cadena vacía, satisfaciendo la regla de "al menos un matcher no vacío"; `.*` puede coincidir con vacío y dejaría al selector sin ningún matcher no vacío, así que es rechazado.

**Ejercicio 5**
- **Q5.1** `X` es un **vector instantáneo** — una muestra por serie. `X[5m]` es un **vector de rango** — una rebanada entera de muestras (cada muestra cruda en los 5 minutos anteriores) por serie.
- **Q5.2** Un vector de rango no tiene un único valor por serie, así que no puede graficarse como una línea; el endpoint de rango/gráfico requiere un Scalar o un Vector instantáneo. Una función que consume un vector de rango y devuelve un vector instantáneo — `rate`, `increase`, `avg_over_time`, `max_over_time`, etc. — lo arregla.
- **Q5.3** Sí, `[90m]` y `[1h30m]` son iguales (ambos 5400 s). `[1h30m]` es legal porque las unidades van de mayor→menor; `[30m1h]` es ilegal porque lista una unidad menor antes de una mayor.
- **Q5.4** Alrededor de 4 muestras (60 s ÷ 15 s). Es aproximado porque los tiempos de scrape tienen jitter, un scrape puede fallar, y el borde de la ventana rara vez se alinea exactamente con los instantes de scrape — así que podés ver 3, 4 o 5.

**Ejercicio 6**
- **Q6.1** Relativo al **momento de evaluación de la consulta** (el instante para el que se evalúa la consulta — que, en una consulta de rango, se mueve a través de cada paso).
- **Q6.2** `offset` solo puede seguir a un selector/vector de rango/subquery, no al resultado de una agregación — de ahí el error de parseo en `sum(...) offset 1h`. `sum(prometheus_http_requests_total offset 1h)` primero desplaza cada serie 1 h hacia el pasado, *luego* suma esos valores pasados; la forma ilegal intentó desplazar la suma ya computada, lo que la gramática no permite.
- **Q6.3** `rate(prometheus_http_requests_total[5m] offset 1w)` — el `[range]` va primero, luego `offset`.

**Ejercicio 7**
- **Q7.1** `offset` es **relativo** (desplazar N unidades hacia atrás desde el momento de evaluación actual, así que se mueve a medida que el momento de evaluación se mueve). `@` es **absoluto** (fijar a un timestamp Unix fijo, idéntico sin importar cuándo/sobre qué rango corre la consulta).
- **Q7.2** `metric @ 1716999400` es **plana** — cada paso de la consulta de rango devuelve el mismo valor fijado. `metric offset 10m` es **móvil** — cada paso evalúa 10 minutos antes del tiempo propio de ese paso, así que la línea sigue a la métrica desplazada 10 minutos hacia la izquierda.
- **Q7.3** `@ start()` resuelve al timestamp de inicio de la consulta de rango y `@ end()` a su timestamp de fin. Son más útiles en **consultas de rango** (y recording rules) para anclar un término a un borde de la ventana.

**Ejercicio 8**
- **Q8.1** Selector de vector instantáneo → `"vector"`. Selector de vector de rango → `"matrix"`.
- **Q8.2** El parámetro de consulta `time=<unix_ts>` en `/api/v1/query` — fija el instante de evaluación para toda la consulta, que para un único selector es equivalente a `@ <unix_ts>`.
- **Q8.3** PromQL contiene caracteres que son inseguros o tienen significado en una URL — `{`, `}`, `=`, `"`, `~`, `+`, espacios, `[`, `]`. `--data-urlencode` los codifica en porcentaje para que el servidor reciba la expresión pretendida en vez de una truncada o mal parseada (y la envía en el cuerpo, evitando los límites de longitud de URL).

</details>