# PCA 1.2 — Rates and Derivatives — Ejercicios Guiados

> **Dominio:** PromQL · **Peso en el examen:** 4 · **Certificación:** Prometheus Certified Associate (PCA)
>
> Estos ejercicios asumen que tenés Docker y `curl` + `jq` en tu estación de trabajo. Todo corre contra un único Prometheus que se scrapea **a sí mismo**, así que no necesitás targets externos. Trabajá los ejercicios en orden — cada uno se apoya en las series de counter/gauge producidas por la carga del anterior.
>
> **Fuentes de referencia (oficiales):**
> - Query functions — https://prometheus.io/docs/prometheus/latest/querying/functions/
> - Query basics (instant vs range vectors, staleness) — https://prometheus.io/docs/prometheus/latest/querying/basics/
> - Metric types (counter vs gauge) — https://prometheus.io/docs/concepts/metric_types/
> - Instrumentation best practices — https://prometheus.io/docs/practices/instrumentation/
> - Recording/alerting rules & the aggregation-order rule — https://prometheus.io/docs/prometheus/latest/querying/rules/
> - PCA curriculum — https://github.com/cncf/curriculum

---

## Ejercicio 0 — Armar el laboratorio

**Objetivo:** levantar un Prometheus que se scrapee a sí mismo con un intervalo rápido, y generar tráfico para que los counters incorporados se muevan de forma visible.

1. Creá un directorio de trabajo y un archivo de configuración. El `scrape_interval` corto (5 s) hace que las ventanas de rate converjan rápido durante un lab; los valores por defecto en producción son 15 s.

   ```bash
   mkdir -p pca-rates && cd pca-rates
   cat > prometheus.yml <<'EOF'
   global:
     scrape_interval: 5s
     evaluation_interval: 5s
   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']
   EOF
   ```

2. Lanzá Prometheus (funciona cualquier imagen reciente 2.x/3.x):

   ```bash
   docker run -d --name pca-prom -p 9090:9090 \
     -v "$PWD/prometheus.yml:/etc/prometheus/prometheus.yml" \
     prom/prometheus:latest
   ```

3. Confirmá que está levantado y scrapeándose a sí mismo:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Esperado (el valor `"1"` significa que el target está sano):

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1733664000.123, "1" ]
     }
   ]
   ```

4. Iniciá un generador de carga en segundo plano. Cada request a la query API incrementa el counter `prometheus_http_requests_total{handler="/api/v1/query"}`. Dejalo corriendo durante toda la sesión:

   ```bash
   ( while true; do
       curl -s 'http://localhost:9090/api/v1/query?query=1' >/dev/null
       sleep 0.2
     done ) &
   echo "load PID: $!"    # remember this to kill it later
   ```

5. Esperá ~2 minutos para que los counters acumulen al menos una docena de samples, y después continuá.

**Chequeo de comprensión**

- **Q0.1** ¿Por qué golpeamos deliberadamente `/api/v1/query` en un loop en lugar de simplemente mirar la métrica quieta?
- **Q0.2** Con `scrape_interval: 5s`, ¿cuántos samples crudos contiene un range vector `[1m]` para una serie, y cuál es el número mínimo que necesita `rate()` para devolver algo?

---

## Ejercicio 1 — Por qué un counter crudo es (casi) inútil

**Objetivo:** ver que los counters son totales monótonamente crecientes, no rates, y que su valor absoluto casi no tiene significado operacional.

1. Mirá el counter crudo como un **instant vector**:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_http_requests_total{handler="/api/v1/query"}' \
     | jq '.data.result[] | {code: .metric.code, value: .value[1]}'
   ```

   Esperado (un entero que crece sin parar — el tuyo va a diferir):

   ```json
   { "code": "200", "value": "1487" }
   ```

2. Corré la misma query 10 segundos después. Fijate que el número es **mayor**.

3. Reiniciá Prometheus para simular un reinicio del proceso, y después releé el counter:

   ```bash
   docker restart pca-prom
   sleep 8
   curl -s 'http://localhost:9090/api/v1/query?query=prometheus_http_requests_total{handler="/api/v1/query"}' \
     | jq '.data.result[] | {code: .metric.code, value: .value[1]}'
   ```

   Esperado — el valor **cayó de vuelta hacia cero** (un counter reset):

   ```json
   { "code": "200", "value": "12" }
   ```

4. Reconectá un generador de carga si el reinicio lo mató (repetí el paso 4 del Ejercicio 0).

**Chequeo de comprensión**

- **Q1.1** El valor absoluto `1487` no te dice casi nada por sí solo. Nombrá dos hechos que *no podés* inferir de él.
- **Q1.2** Después del reinicio el valor cayó. ¿Cómo se llama este evento, y qué familia de funciones de PromQL está específicamente diseñada para sobrevivirlo sin producir un pico negativo enorme?

---

## Ejercicio 2 — `rate()`: el promedio por segundo, y cómo la ventana lo moldea

**Objetivo:** entender que `rate()` da el **rate de incremento promedio por segundo** sobre una ventana de rango, y que la longitud de la ventana intercambia responsividad por suavidad.

1. Calculá el rate de requests sobre tres ventanas distintas en el mismo instante:

   ```bash
   for w in 30s 1m 5m; do
     echo -n "[$w] => "
     curl -s "http://localhost:9090/api/v1/query?query=rate(prometheus_http_requests_total%7Bhandler=%22/api/v1/query%22%7D%5B$w%5D)" \
       | jq -r '.data.result[0].value[1]'
   done
   ```

   Esperado (≈5 req/s por nuestro loop de 0.2 s; la ventana más corta reacciona más rápido y es más ruidosa):

   ```
   [30s] => 4.87
   [1m]  => 4.93
   [5m]  => 4.62
   ```

2. Ahora rompé la regla de que la ventana debe abarcar **al menos dos scrape intervals**. Consultá una ventana más corta que un scrape interval:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[3s])' \
     | jq '.data.result'
   ```

   Esperado — **vacío**, porque una ventana `[3s]` con un scrape interval de 5 s usualmente contiene menos de dos samples:

   ```json
   []
   ```

3. Corregilo ampliando la ventana a al menos `[15s]` (≥ 2× el scrape interval) y confirmá que devuelve un valor.

**Chequeo de comprensión**

- **Q2.1** Las tres ventanas del paso 1 midieron el *mismo* momento y sin embargo devolvieron números distintos. ¿Qué selecciona realmente la ventana de rango, y por qué una ventana más larga se ve más suave?
- **Q2.2** ¿Por qué `[3s]` no devolvió nada, y cuál es la regla práctica para elegir una ventana de `rate()` relativa al `scrape_interval`?
- **Q2.3** Prometheus no conoce el tipo de una métrica en tiempo de query. ¿Qué única suposición hace `rate()` sobre los datos que le permite manejar counter resets — y qué pasa si le alimentás un gauge?

---

## Ejercicio 3 — `irate()` vs `rate()`: instantáneo vs promedio

**Objetivo:** contrastar `irate()` (rate instantáneo a partir de los **últimos dos** samples) con `rate()` (promedio sobre toda la ventana), y aprender cuándo es apropiado cada uno.

1. Compará ambos lado a lado sobre la misma ventana `[1m]`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=irate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"irate = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate  = " + .data.result[0].value[1]'
   ```

   Esperado — cercanos bajo carga estable, pero `irate` es más saltarín:

   ```
   irate = 5.20
   rate  = 4.93
   ```

2. Inyectá un burst para que ambos divergan. Disparás 300 requests rápidos, y después consultás ambos de inmediato:

   ```bash
   for i in $(seq 1 300); do curl -s 'http://localhost:9090/api/v1/query?query=1' >/dev/null; done
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=irate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"irate = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate  = " + .data.result[0].value[1]'
   ```

   Esperado — `irate` da un pico sobre los dos samples más recientes; `rate` promedia el burst a lo largo del minuto y apenas se mueve:

   ```
   irate = 63.40
   rate  = 9.85
   ```

**Chequeo de comprensión**

- **Q3.1** En `irate(...[1m])`, ¿qué rol juega la ventana `[1m]`, dado que `irate` solo usa dos samples?
- **Q3.2** Estás escribiendo una regla de alerta evaluada cada 1 minuto sobre un counter lento. ¿Por qué `irate` es la elección incorrecta acá, y qué modo de falla ("aliasing") puede causar?
- **Q3.3** Dá un uso legítimo donde `irate` sea *preferible* a `rate`.

---

## Ejercicio 4 — `increase()` y la trampa de la extrapolación

**Objetivo:** ver que `increase()` es `rate()` × ventana, que ambos **extrapolan** hacia los bordes de la ventana, y por qué eso produce conteos no enteros.

1. Calculá el incremento total sobre 1 minuto y el rate que eso implica:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=increase(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"increase[1m] = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m]) * 60' \
     | jq -r '"rate[1m]*60  = " + .data.result[0].value[1]'
   ```

   Esperado — las dos líneas son (esencialmente) idénticas:

   ```
   increase[1m] = 296.4
   rate[1m]*60  = 296.4
   ```

2. Fijate que `296.4` **no** es un entero, aunque un counter de requests solo se incrementa de a números enteros. Agarrá los samples crudos para ver el delta entero real:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=prometheus_http_requests_total{handler="/api/v1/query"}[1m]' \
     | jq -r '.data.result[0].values | "first=\(.[0][1])  last=\(.[-1][1])  raw_delta=\(( .[-1][1]|tonumber) - (.[0][1]|tonumber))"'
   ```

   Esperado — el delta crudo entre el primer y el último sample almacenado es un número entero *más chico* que `296.4`:

   ```
   first=1502  last=1789  raw_delta=287
   ```

**Chequeo de comprensión**

- **Q4.1** ¿Por qué el `increase` reportado (`296.4`) es mayor que y distinto del delta entero crudo (`287`)?
- **Q4.2** Enunciá la relación exacta entre `increase(v[w])` y `rate(v[w])`.
- **Q4.3** Un colega alerta sobre `increase(errors_total[5m]) < 1` esperando "exactamente cero errores". ¿Por qué comparar un float extrapolado contra un umbral entero es frágil?

---

## Ejercicio 5 — La regla del orden de agregación: `sum(rate(...))`, nunca `rate(sum(...))`

**Objetivo:** internalizar la regla de corrección de PromQL más evaluada — siempre tomar `rate()` **antes** de agregar a través de series, para que los counter resets se manejen por serie.

1. Forma correcta — hacé rate de cada serie hija, y después sumá:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=sum(rate(prometheus_http_requests_total[1m]))' \
     | jq -r '"sum(rate(...)) = " + .data.result[0].value[1]'
   ```

   Esperado — un rate de requests agregado limpio a través de todos los handlers/codes:

   ```
   sum(rate(...)) = 11.72
   ```

2. Forma incorrecta — sumá los counters crudos primero (esto incluso falla el type-check, porque `sum()` devuelve un instant vector pero `rate()` necesita un range vector):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(sum(prometheus_http_requests_total)[1m])' \
     | jq -r '.error // .data'
   ```

   Esperado — un error de parse/tipo, que ilustra que el lenguaje te empuja hacia el orden correcto:

   ```
   parse error: ranges only allowed for vector selectors
   ```

3. Para hacer concreto el peligro *semántico*, imaginá dos series hijas donde una se resetea. Razonalo en papel antes de las respuestas: la serie A va `…, 100, 101, 2, 3` (reset) y la serie B va `…, 50, 51, 52, 53`. Si sumaras los counters crudos primero obtendrías `…, 150, 152, 54, 56` — una gran caída falsa en el reset. `rate()` aplicado a esa serie fusionada malinterpretaría la caída.

**Chequeo de comprensión**

- **Q5.1** Reformulá la regla en una oración, y explicá *por qué* el orden importa en términos de cómo `rate()` detecta resets.
- **Q5.2** Incluso ignorando resets, ¿por qué `rate(sum(...))` es rechazado directamente por el query engine? (Pista: instant vector vs range vector.)
- **Q5.3** Escribí la expresión correcta para "rate de requests 5xx por segundo, sumado a través de todos los handlers, por `code`". Mantené el label `code`.

---

## Ejercicio 6 — Gauges: `delta()`, `idelta()`, `deriv()`, `predict_linear()`

**Objetivo:** aplicar las funciones exclusivas de gauge a un gauge de diente de sierra real (`go_memstats_alloc_bytes`, que sube y después cae en el garbage collection) y a un gauge de crecimiento lento (`prometheus_tsdb_head_series`).

1. Mirá la forma del gauge del heap sobre 2 minutos:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=go_memstats_alloc_bytes[2m]' \
     | jq -r '.data.result[0].values[] | .[1]' | head
   ```

   Esperado — los valores suben, y después caen abruptamente en un GC (un diente de sierra):

   ```
   41200112
   47881040
   53992120
   19004416     <-- GC dropped it
   24771328
   ```

2. `delta()` — diferencia del primero al último sobre la ventana (puede ser negativa):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=delta(go_memstats_alloc_bytes[2m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Esperado (el signo depende de dónde cayó el GC dentro de la ventana):

   ```
   -8402112
   ```

3. `idelta()` — diferencia entre solo los **últimos dos** samples:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=idelta(go_memstats_alloc_bytes[2m])' \
     | jq -r '.data.result[0].value[1]'
   ```

4. `deriv()` — derivada por segundo vía regresión lineal por mínimos cuadrados, sobre el gauge de conteo de series de crecimiento lento:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=deriv(prometheus_tsdb_head_series[5m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Esperado — crecimiento de series por segundo (cercano a cero en un servidor ocioso):

   ```
   0.0138
   ```

5. `predict_linear()` — extrapolá la regresión hacia adelante. Predecí el conteo de head series una hora (3600 s) a partir de ahora:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=predict_linear(prometheus_tsdb_head_series[10m], 3600)' \
     | jq -r '.data.result[0].value[1]'
   ```

   Esperado — el conteo actual más `deriv × 3600`:

   ```
   1284.7
   ```

**Chequeo de comprensión**

- **Q6.1** ¿Qué pasa si llamás `rate()` sobre `go_memstats_alloc_bytes`, y por qué `deriv()` es la herramienta correcta para un gauge en su lugar?
- **Q6.2** Contrastá `delta()` e `idelta()` sobre el gauge de diente de sierra — ¿cuándo te engañaría cada uno sobre la tendencia de la memoria?
- **Q6.3** Escribí una expresión de alerta con `predict_linear()` que dispare cuando un gauge de filesystem `node_filesystem_avail_bytes` tienda a llegar a **cero dentro de 4 horas**. Explicá cada término.
- **Q6.4** ¿Por qué `deriv()` usa regresión lineal en vez de simplemente `(last − first) / window`, como efectivamente hace `delta()`?

---

## Ejercicio 7 — Counter resets y `resets()`

**Objetivo:** contar los eventos de reset explícitamente y confirmar que `rate()`/`increase()` los absorben para que la matemática downstream siga siendo correcta.

1. Leé el conteo de resets sobre los últimos 15 minutos (debería incluir el reinicio del Ejercicio 1):

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=resets(prometheus_http_requests_total{handler="/api/v1/query"}[15m])' \
     | jq -r '.data.result[0].value[1]'
   ```

   Esperado (≥ 1 porque reiniciamos el proceso):

   ```
   1
   ```

2. Forzá un segundo reset, esperá unos cuantos scrapes, y volvé a chequear que `resets()` incrementa mientras `rate()` se mantiene sano (no negativo):

   ```bash
   docker restart pca-prom && sleep 20
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=resets(prometheus_http_requests_total{handler="/api/v1/query"}[15m])' \
     | jq -r '"resets = " + .data.result[0].value[1]'
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq -r '"rate   = " + (.data.result[0].value[1] // "none-yet")'
   ```

   Esperado:

   ```
   resets = 2
   rate   = 3.10
   ```

3. Relanzá el generador de carga después del reinicio si hace falta.

**Chequeo de comprensión**

- **Q7.1** ¿Cómo decide `rate()` que ocurrió un reset, y qué agrega al incremento calculado para compensar?
- **Q7.2** `resets()` devuelve `2` pero sabés que el counter crudo cayó solo cuando el proceso se reinició. ¿Podría `resets()` alguna vez *sobrecontar* en un counter sano? ¿Bajo qué condición una disminución legítima de valor sería malinterpretada como un reset?
- **Q7.3** ¿Es `resets()` significativo sobre un gauge? ¿Por qué o por qué no?

---

## Ejercicio 8 — Diagnosticar gaps, staleness y trampas de rate

**Objetivo:** conectar la matemática de rate con modos de falla que un SRE realmente debuggea — samples faltantes, extrapolación en el límite, y counters lentos.

1. Detené el scraping a mitad de vuelo para crear un gap, y después observá que `rate()` decae a nada:

   ```bash
   docker stop pca-prom && sleep 20 && docker start pca-prom && sleep 3
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/api/v1/query"}[1m])' \
     | jq '.data.result'
   ```

   Esperado — justo después del reinicio la ventana `[1m]` tiene < 2 samples frescos, así que el resultado está **vacío** por un momento:

   ```json
   []
   ```

2. Consultá un counter **muy lento** con una ventana **corta** para ver cómo una serie de movimiento lento parece que "no se mueve". Elegí un handler golpeado raramente:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query' \
     --data-urlencode 'query=rate(prometheus_http_requests_total{handler="/-/healthy"}[1m])' \
     | jq -r '.data.result[0].value[1] // "no data / 0-ish"'
   ```

3. Inspeccioná el comportamiento de extrapolación en el límite. Compará `increase` sobre una ventana apenas más larga que dos scrapes vs una ventana larga, sobre un counter estable, y notá que la ventana corta sobre-reporta proporcionalmente más debido a la extrapolación en el borde.

**Chequeo de comprensión**

- **Q8.1** Después de un gap de scrape de 20 s, ¿por qué `rate(...[1m])` devolvió brevemente nada en lugar de un valor viejo (stale)? Atá tu respuesta al manejo de **staleness** de Prometheus y al mínimo de dos samples.
- **Q8.2** Un counter lento que se incrementa unas pocas veces por hora, consultado con `rate(...[1m])`, frecuentemente lee `0` o vacío. ¿Qué dos perillas (longitud de la ventana y, si hace falta, elección de función) lo arreglan, y cuál es el costo de cada una?
- **Q8.3** Explicá, en términos del algoritmo de extrapolación, por qué `increase()` sobre una ventana corta tiende a sobre-reportar comparado con el verdadero delta entero, y cómo Prometheus acota esto cerca del inicio de vida de la serie o de cero.

---

## Respuestas

<details>
<summary>Click to reveal all answers</summary>

**Q0.1** Un counter solo cambia cuando ocurre el evento instrumentado. Una métrica ociosa produce samples planos, y `rate()`/`increase()` de un counter plano es `0` — nada que observar. Generar tráfico hace que el counter suba para que las funciones de rate tengan una pendiente real que medir.

**Q0.2** Con un scrape interval de 5 s, `[1m]` contiene aproximadamente `60 / 5 = 12` samples por serie (11–13 dependiendo de la alineación). `rate()` necesita **al menos dos** samples dentro de la ventana para calcular una pendiente; con menos de dos no devuelve nada para esa serie.

---

**Q1.1** A partir de `1487` solo no podés inferir (a) *qué tan rápido* están llegando los requests ahora — el valor es un total de por vida, no un rate; (b) *cuándo arrancó el proceso*, así que no conocés la base de tiempo; (c) si ocurrió algún reset en el camino. Los valores absolutos de counter son significativos solo después de diferenciar.

**Q1.2** Es un **counter reset** (el proceso se reinició, así que el counter volvió a cero). La familia `rate()` — `rate()`, `irate()`, `increase()` y `resets()` — está diseñada para detectar la disminución, tratarla como un reset y compensar en lugar de emitir un gran pico negativo.

---

**Q2.1** La ventana de rango `[w]` selecciona **todos los samples crudos en los últimos `w` segundos** para cada serie. `rate()` calcula el incremento promedio por segundo a través de esos samples. Una ventana más larga promedia sobre más samples, así que los bursts transitorios se diluyen → más suave pero más lenta para reaccionar; una ventana más corta sigue de cerca el comportamiento reciente → responsiva pero ruidosa.

**Q2.2** `[3s]` es más corta que un scrape interval de 5 s, así que la ventana usualmente contiene 0 o 1 samples — por debajo del mínimo de dos samples — de ahí que quede vacía. Regla práctica: **la ventana de rate debería ser al menos 2× (idealmente ~4×) el `scrape_interval`** para que contenga confiablemente suficientes samples y tolere un scrape perdido.

**Q2.3** `rate()` asume que la serie es **monótonamente creciente** (un counter): cualquier *disminución* observada entre samples adyacentes se interpreta como un reset y se compensa. Alimentale un gauge que legítimamente sube y baja y cada movimiento hacia abajo se malinterpreta como un reset, inflando el resultado en picos positivos sin sentido. Usá funciones de gauge (`deriv`, `delta`) para gauges.

---

**Q3.1** En `irate(...[1m])` la ventana `[1m]` solo delimita *cuáles* samples son elegibles; `irate` entonces usa los **dos más recientes** samples dentro de ella. La ventana todavía debe ser lo suficientemente larga como para contener al menos dos samples, pero su longitud no cambia el período de promediado de la forma en que lo hace para `rate`.

**Q3.2** `irate` refleja solo los últimos dos scrapes. Si la regla se evalúa con menor frecuencia de la que llegan los datos (evaluada cada 1 min pero scrapeada cada 5 s), cada evaluación muestrea apenas una franja angosta de 5–10 s e ignora todo lo que hay entre evaluaciones — **aliasing**. En un counter lento o con bursts esto hace que las alertas parpadeen o se pierdan problemas sostenidos. Usá `rate()` para alertar así se promedia toda la ventana.

**Q3.3** `irate` brilla para **graficar counters volátiles de movimiento rápido** donde querés ver detalle de alta frecuencia (ej. un endpoint de alto QPS en un dashboard con refresco corto), y *querés* ver picos instantáneos en lugar de suavizarlos.

---

**Q4.1** `increase()` (y `rate()`) **extrapolan** la pendiente observada hacia los bordes exactos de la ventana `[1m]`, porque el primer/último sample almacenado rara vez cae precisamente sobre los límites de la ventana. El delta crudo `287` cubre solo el tramo *entre samples almacenados*; la extrapolación lo escala hasta los 60 s completos, dando `296.4`. La parte fraccionaria es la fracción extrapolada de un intervalo de sample.

**Q4.2** `increase(v[w]) == rate(v[w]) * w_seconds`. `increase` es exactamente `rate` multiplicado por la longitud de la ventana en segundos; comparten el mismo manejo de resets y extrapolación.

**Q4.3** Debido a la extrapolación el resultado es un **float**, no el verdadero conteo entero de eventos, y su valor exacto deriva con la alineación de los samples. Comparar `increase(...) < 1` contra un límite entero puede voltearse por ruido de redondeo. Para "¿ocurrió algún evento?", preferí patrones robustos como `increase(errors_total[5m]) > 0` con ventanas generosas, y nunca asumas que el número es igual a un conteo entero de eventos.

---

**Q5.1** **Siempre hacé `rate()` (o `increase()`) de cada serie de counter individual primero, y después agregá con `sum()`.** El orden importa porque `rate()` detecta y compensa resets **por serie**; si fusionás las series primero, el reset de una hija aparece como una caída en el total fusionado que ninguna lógica por serie puede atribuir, corrompiendo el rate.

**Q5.2** `sum(prometheus_http_requests_total)` devuelve un **instant vector** (un valor por grupo en un instante). `rate()` requiere un **range vector** (`[w]`). No podés aplicar un selector de rango a la salida de `sum()`, así que el engine rechaza `rate(sum(...)[1m])` con un error de parse — el lenguaje deliberadamente previene el orden incorrecto.

**Q5.3**
```promql
sum by (code) (rate(prometheus_http_requests_total{code=~"5.."}[5m]))
```
`rate` por serie, y después `sum by (code)` para mantener el label `code` mientras colapsás todo lo demás; el matcher `code=~"5.."` restringe a 5xx.

---

**Q6.1** `rate()` sobre `go_memstats_alloc_bytes` malinterpreta cada caída de GC como un counter reset e infla el resultado — basura. `deriv()` es la función apropiada para gauge: ajusta una **línea de mínimos cuadrados** a los samples y reporta la pendiente por segundo, así una tendencia genuina hacia abajo produce una derivada negativa en lugar de un reset falso.

**Q6.2** `delta()` = último − primero sobre toda la ventana; en un diente de sierra depende enteramente de dónde cae la caída de GC relativa a los bordes de la ventana, así que puede reportar una gran "tendencia" negativa que en realidad es solo un GC. `idelta()` = último − penúltimo, así que refleja solo el único paso más reciente (asignación o GC) y no te dice nada sobre la tendencia más larga. Ambos engañan en la memoria de diente de sierra; `deriv()` sobre una ventana de múltiples ciclos es la tendencia honesta.

**Q6.3**
```promql
predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0
```
`node_filesystem_avail_bytes[1h]` da una hora de historia del gauge; `predict_linear(..., 14400)` ajusta una línea y extrapola el valor **4 horas (14400 s) hacia el futuro**; `< 0` dispara cuando el espacio libre proyectado sería negativo, es decir, el disco tiende a llenarse dentro de 4 horas. Usar una ventana de regresión de 1 h suaviza los dips efímeros.

**Q6.4** `deriv()` usa regresión así que es **robusto al ruido**: un único sample atípico (o un dip de GC) apenas mueve una línea de mejor ajuste, mientras que `(last − first)/window` está completamente a merced de exactamente dos samples de extremo. Para predecir tendencias (llenado de disco, crecimiento de memoria) la pendiente de la regresión es mucho más estable, que es también por qué `predict_linear` está construido sobre el mismo ajuste de mínimos cuadrados.

---

**Q7.1** `rate()` recorre los samples adyacentes en la ventana; cada vez que un sample es **más chico que su predecesor**, trata el hueco como un reset y suma el **valor previo al reset** de vuelta al incremento acumulado (así la serie se trata como si hubiera seguido subiendo desde cero). Esto hace que el incremento total — y por lo tanto el rate — sea no negativo a través de los resets.

**Q7.2** Sí, `resets()` puede sobrecontar si una serie alguna vez disminuye legítimamente. Cualquier paso hacia abajo se cuenta como un reset — así que un counter que (incorrectamente) tiene permitido disminuir, o un valor que baja debido a un bug de instrumentación, infla el conteo. Los counters verdaderos deben ser monótonos; si la instrumentación viola eso, tanto `resets()` como `rate()` son engañados.

**Q7.3** No. `resets()` solo es significativo para counters, donde una disminución implica un reinicio. Un gauge disminuye como comportamiento normal, así que `resets()` sobre un gauge solo cuenta cuán a menudo bajó — no un reset, y no una señal útil.

---

**Q8.1** Durante el gap de 20 s no se escribieron samples, y después de `staleness` (default 5 min) los samples viejos todavía existen pero una ventana `[1m]` fresca justo después del reinicio contiene a lo sumo un sample *nuevo*. Con menos de dos samples, `rate()` no devuelve nada para esa serie en lugar de fabricar un valor o reutilizar uno viejo (stale) — Prometheus marca las series ausentes como stale en vez de arrastrar el último valor hacia adelante dentro de la matemática de rate.

**Q8.2** (1) **Ampliá la ventana** — ej. `rate(slow_counter[15m])` — así abarca varios incrementos; costo: reacción más lenta y resolución temporal más gruesa. (2) Si necesitás "¿ocurrió algo en absoluto?", cambiá a `increase(slow_counter[…]) > 0` sobre una ventana larga; costo: la extrapolación hace que el número sea un float, así que usalo como un umbral tipo booleano, no como un conteo exacto. `irate` es el arreglo incorrecto acá — empeora el problema en counters lentos.

**Q8.3** `rate`/`increase` calculan la pendiente a partir del primer y último sample dentro de la ventana, y después **extrapolan esa pendiente hacia ambos bordes de la ventana**. Sobre una ventana corta la fracción extrapolada es una porción más grande del total, así que el incremento reportado se pasa del verdadero delta entero proporcionalmente más. Prometheus limita esto: si el primer/último sample está lejos del límite (más de ~110 % del intervalo de sample promedio) solo extrapola hasta la mitad del intervalo promedio, y **acota** para que el resultado nunca se proyecte antes de que la serie empezara o por debajo de cero — previniendo incrementos negativos o imposiblemente grandes cerca del inicio de vida de un counter.

</details>

---

### Teardown

```bash
kill %1 2>/dev/null        # stop the load generator(s)
docker rm -f pca-prom      # remove the lab container