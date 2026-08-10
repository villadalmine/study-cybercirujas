# Tema 5.4 — Estructurar y Nombrar Métricas — Ejercicios Guiados

> **Dominio:** Instrumentación y Exposición · **Peso en el examen:** 4
> **Objetivo:** Desarrollar memoria muscular para las convenciones de nombres de Prometheus (`namespace_subsystem_name_unit_suffix`), las unidades base, los sufijos `_total`/`_info`/`_created`, el diseño de labels, el control de cardinalidad y los dos puntos (`:`) reservados para las recording rules — instrumentando un servicio real, inspeccionando su exposición y analizándolo con `promtool`.

**Fuentes de referencia**
- Nombres de métricas y labels — https://prometheus.io/docs/practices/naming/
- Mejores prácticas de instrumentación (labels, cardinalidad) — https://prometheus.io/docs/practices/instrumentation/
- Modelo de datos (regex de nombre/label, nombres reservados) — https://prometheus.io/docs/concepts/data_model/
- Tipos de métricas (counter/gauge/histogram/summary) — https://prometheus.io/docs/concepts/metric_types/
- Nombres de recording rules (`level:metric:operations`) — https://prometheus.io/docs/practices/rules/
- Cliente de Python — https://github.com/prometheus/client_python
- Especificación de OpenMetrics — https://github.com/OpenObservability/OpenMetrics/blob/main/specification/OpenMetrics.md

**Prerrequisitos**
- Docker (o binarios locales) para `prometheus` y `node_exporter`
- `promtool` (viene en el tarball de release de Prometheus)
- Python 3.12 con `prometheus_client` (`pip install prometheus_client`)
- `curl` y `jq`

---

## Ejercicio 1 — Diseccionar el nombre de una métrica real (la anatomía)

Vas a leer métricas de un exporter de nivel productivo y descomponer cada nombre en sus partes: **namespace**, **name**, **unit** y **suffix**.

1. Ejecutá `node_exporter` y exponé su endpoint `/metrics`:

   ```bash
   docker run -d --name ne -p 9100:9100 quay.io/prometheus/node-exporter:latest
   ```

2. Obtené tres familias de métricas representativas y mirá solo sus líneas `# TYPE`:

   ```bash
   curl -s localhost:9100/metrics \
     | grep -E '^# TYPE (node_cpu_seconds_total|node_memory_MemAvailable_bytes|node_network_receive_bytes_total) '
   ```

   Salida esperada:

   ```
   # TYPE node_cpu_seconds_total counter
   # TYPE node_memory_MemAvailable_bytes gauge
   # TYPE node_network_receive_bytes_total counter
   ```

3. Ahora inspeccioná una serie de cada una para poder ver las unidades y los labels:

   ```bash
   curl -s localhost:9100/metrics | grep -E '^node_cpu_seconds_total\{cpu="0"' | head -3
   ```

   Salida esperada (los valores van a diferir):

   ```
   node_cpu_seconds_total{cpu="0",mode="idle"} 84213.55
   node_cpu_seconds_total{cpu="0",mode="system"} 612.19
   node_cpu_seconds_total{cpu="0",mode="user"} 1893.42
   ```

4. Descomponé `node_network_receive_bytes_total` en papel en: `namespace` / `name` / `unit` / `suffix`.

**Verificación de comprensión**

- **1a.** En `node_network_receive_bytes_total`, identificá el namespace, el name descriptivo, la unit y el suffix de tipo.
- **1b.** ¿Por qué la unit es `bytes` y no `kilobytes` o `mebibytes`? Enunciá la regla general que sigue.
- **1c.** `node_cpu_seconds_total` es un counter que mide el tiempo de CPU. ¿Por qué `seconds` (una *unidad base de tiempo*) es la elección correcta acá, y por qué lleva `_total`?
- **1d.** `node_memory_MemAvailable_bytes` es un gauge y **no** tiene el suffix `_total`. ¿Qué regla dicta eso?

---

## Ejercicio 2 — Instrumentar una aplicación con nombres correctos

Vas a escribir instrumentación en Python y observar cómo la librería cliente hace cumplir las convenciones (el `_total`, `_info`, `_created`, `_bucket/_sum/_count` que se agregan automáticamente).

1. Creá `app.py`:

   ```python
   #!/usr/bin/env python3
   """Minimal instrumented service demonstrating metric-naming conventions."""
   import random
   import time

   from prometheus_client import Counter, Gauge, Histogram, Info, start_http_server

   # namespace = "myapp"; base name = "http_requests".
   # NOTE: do NOT write "_total" here — the Python client appends it in the exposition.
   REQUESTS = Counter(
       "myapp_http_requests",
       "Total number of HTTP requests handled.",
       ["method", "path", "status"],
   )
   IN_FLIGHT = Gauge(
       "myapp_http_requests_in_flight",
       "Number of HTTP requests currently in flight.",
   )
   LATENCY = Histogram(
       "myapp_http_request_duration_seconds",   # base unit is seconds, never milliseconds
       "HTTP request latency in seconds.",
       ["method", "path"],
       buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
   )
   BUILD = Info("myapp_build", "Build metadata for the running binary.")
   BUILD.info({"version": "1.4.2", "revision": "ab12cd3", "language": "python"})

   PATHS = ["/", "/login", "/api/orders"]

   def handle_one_request() -> None:
       method, path = "GET", random.choice(PATHS)
       status = random.choices(["200", "404", "500"], weights=[92, 6, 2])[0]
       with IN_FLIGHT.track_inprogress():
           with LATENCY.labels(method=method, path=path).time():
               time.sleep(random.expovariate(20))   # ~50 ms mean latency
       REQUESTS.labels(method=method, path=path, status=status).inc()

   if __name__ == "__main__":
       start_http_server(8000)
       print("Serving metrics on :8000/metrics")
       while True:
           handle_one_request()
   ```

2. Ejecutalo y dejá que acumule unos segundos de tráfico:

   ```bash
   python3 app.py &
   sleep 5
   ```

3. Mirá cómo se expuso el **counter**:

   ```bash
   curl -s localhost:8000/metrics | grep -E '^# (HELP|TYPE) myapp_http_requests_total|^myapp_http_requests_total' | head -5
   ```

   Salida esperada (los valores difieren):

   ```
   # HELP myapp_http_requests_total Total number of HTTP requests handled.
   # TYPE myapp_http_requests_total counter
   myapp_http_requests_total{method="GET",path="/",status="200"} 143.0
   myapp_http_requests_total{method="GET",path="/login",status="200"} 61.0
   myapp_http_requests_total{method="GET",path="/api/orders",status="500"} 3.0
   ```

4. Mirá las métricas **histogram** e **info**:

   ```bash
   curl -s localhost:8000/metrics \
     | grep -E '^myapp_http_request_duration_seconds_(bucket|sum|count)|^myapp_build_info' | head -8
   ```

   Salida esperada (los valores difieren):

   ```
   myapp_http_request_duration_seconds_bucket{le="0.005",method="GET",path="/"} 12.0
   myapp_http_request_duration_seconds_bucket{le="0.05",method="GET",path="/"} 118.0
   myapp_http_request_duration_seconds_bucket{le="+Inf",method="GET",path="/"} 143.0
   myapp_http_request_duration_seconds_sum{method="GET",path="/"} 6.94
   myapp_http_request_duration_seconds_count{method="GET",path="/"} 143.0
   myapp_build_info{language="python",revision="ab12cd3",version="1.4.2"} 1.0
   ```

5. Fijate en la serie extra `_created` que emite el cliente:

   ```bash
   curl -s localhost:8000/metrics | grep -E '^myapp_http_requests_created' | head -1
   ```

   Salida esperada:

   ```
   myapp_http_requests_created{method="GET",path="/",status="200"} 1.7523e+09
   ```

**Verificación de comprensión**

- **2a.** En el código fuente escribiste `Counter("myapp_http_requests", ...)` sin `_total`, y sin embargo la exposición muestra `myapp_http_requests_total`. ¿Qué pasó, y cuál habría sido el nombre expuesto si hubieras escrito `"myapp_http_requests_total"` en el fuente?
- **2b.** El histogram se expandió en tres familias: `_bucket`, `_sum`, `_count`. ¿Qué significa el label `le` en `_bucket`, y por qué `le` es un nombre de label reservado que no debés reutilizar?
- **2c.** `myapp_build_info` siempre tiene el valor `1.0` y lleva `version`, `revision`, `language` como labels. ¿Cuál es el propósito de este patrón "info", y por qué la constante `1` es la clave del asunto?
- **2d.** ¿Por qué el histogram de latencia se llama `..._duration_seconds` en lugar de `..._duration_ms` o `..._latency`? Nombrá las dos convenciones en juego.
- **2e.** ¿Qué es la serie `_created`, y qué estándar de exposición la define?

---

## Ejercicio 3 — Labels: dimensiones, consistencia y cardinalidad

Vas a medir cómo las elecciones de labels determinan la cantidad de series, y reproducir el clásico anti-patrón de alta cardinalidad.

1. Con `app.py` todavía corriendo y Prometheus haciéndole scraping (o consultando el exporter directamente), contá las series actuales del counter de requests:

   ```bash
   curl -s localhost:8000/metrics | grep -c '^myapp_http_requests_total{'
   ```

   Salida esperada (≤ methods×paths×statuses = 1×3×3 = 9):

   ```
   7
   ```

2. Calculá la cota superior *teórica* de esta métrica a partir de sus dimensiones de labels: `method` (1 valor) × `path` (3 valores) × `status` (3 valores).

3. Ahora introducí el anti-patrón. Editá `app.py` para agregar un label único por usuario. Cambiá la definición del counter y la llamada a `.inc()`:

   ```python
   REQUESTS = Counter(
       "myapp_http_requests",
       "Total number of HTTP requests handled.",
       ["method", "path", "status", "user_id"],   # ← unbounded dimension
   )
   # ...
   REQUESTS.labels(
       method=method, path=path, status=status,
       user_id=str(random.randint(1, 10000)),      # up to 10,000 distinct values
   ).inc()
   ```

4. Reiniciá la app, dejala correr y contá de nuevo:

   ```bash
   kill %1 2>/dev/null; python3 app.py & sleep 8
   curl -s localhost:8000/metrics | grep -c '^myapp_http_requests_total{'
   ```

   Salida esperada (crece sin límite a medida que se ven más usuarios):

   ```
   2871
   ```

5. Si Prometheus está haciendo scraping de este target, preguntale a su TSDB qué nombres de métricas dominan la cardinalidad:

   ```bash
   curl -s localhost:9090/api/v1/status/tsdb \
     | jq '.data.seriesCountByMetricName[] | select(.name|startswith("myapp"))'
   ```

   Salida esperada:

   ```json
   { "name": "myapp_http_requests_total", "value": 2871 }
   ```

6. Revertí el label `user_id` antes de continuar.

**Verificación de comprensión**

- **3a.** La cota teórica en el paso 2 era 9, pero observaste 7. ¿Por qué la cantidad real de series puede ser menor que el producto de las cardinalidades de los labels?
- **3b.** La cardinalidad es aproximadamente el *producto* de los valores distintos de cada label. Explicá por qué agregar `user_id` convirtió una métrica de 9 series en miles, y cuáles son los dos costos operativos de eso.
- **3c.** Un compañero de equipo propone un label `path` cuyo valor es la URL cruda completa del request (incluyendo query strings como `?id=847213`). ¿Por qué esto es peligroso, y cómo debería manejarse el path en su lugar?
- **3d.** Dos métricas distintas en la misma app usan un label para el verbo HTTP — una lo llama `method`, la otra `verb`. ¿Por qué la convención de nombres insiste en que un concepto dado use el **mismo nombre de label** en todos lados?
- **3e.** Los nombres de labels que empiezan con `__` (doble guion bajo) se rechazan para uso del usuario. ¿Para qué están reservados?

---

## Ejercicio 4 — Analizar nombres con `promtool check metrics`

Vas a alimentar a `promtool` con una exposición rota a propósito e interpretar cada mensaje del linter.

1. Creá `bad.prom` — parsea como exposición válida pero viola cuatro reglas de nombres:

   ```bash
   cat > bad.prom <<'EOF'
   # HELP myapp_processed Number of processed items.
   # TYPE myapp_processed counter
   myapp_processed 100
   # HELP myapp_queue_length_total Current queue length.
   # TYPE myapp_queue_length_total gauge
   myapp_queue_length_total 7
   # HELP myapp_request_latency_milliseconds Last request latency.
   # TYPE myapp_request_latency_milliseconds gauge
   myapp_request_latency_milliseconds 12
   # HELP myapp_disk_usage_bytes Disk space used.
   # TYPE myapp_disk_usage_bytes gauge
   myapp_disk_usage_bytes{deviceName="sda"} 2048
   EOF
   ```

2. Analizalo:

   ```bash
   cat bad.prom | promtool check metrics
   ```

   Salida esperada:

   ```
   myapp_processed counter metrics should have "_total" suffix
   myapp_queue_length_total non-counter metrics should not have "_total" suffix
   myapp_request_latency_milliseconds use base unit "seconds" instead of "milliseconds"
   myapp_disk_usage_bytes label names should be written in 'snake_case' not 'camelCase'
   ```

3. Escribí el `good.prom` corregido que resuelve los cuatro hallazgos, luego volvé a analizarlo hasta que quede en silencio:

   ```bash
   cat > good.prom <<'EOF'
   # HELP myapp_processed_total Number of processed items.
   # TYPE myapp_processed_total counter
   myapp_processed_total 100
   # HELP myapp_queue_length Current queue length.
   # TYPE myapp_queue_length gauge
   myapp_queue_length 7
   # HELP myapp_request_latency_seconds Last request latency in seconds.
   # TYPE myapp_request_latency_seconds gauge
   myapp_request_latency_seconds 0.012
   # HELP myapp_disk_usage_bytes Disk space used.
   # TYPE myapp_disk_usage_bytes gauge
   myapp_disk_usage_bytes{device_name="sda"} 2048
   EOF
   cat good.prom | promtool check metrics && echo "clean"
   ```

   Salida esperada:

   ```
   clean
   ```

**Verificación de comprensión**

- **4a.** Asociá cada uno de los cuatro mensajes del linter de `bad.prom` con la edición exacta que hiciste en `good.prom`.
- **4b.** Para `myapp_request_latency_milliseconds`, convertir a segundos cambió el valor de `12` a `0.012`. ¿Por qué debe cambiar el *valor* y no solo el nombre?
- **4c.** `promtool check metrics` marcó problemas de estilo pero el archivo igual *parseó*. ¿Cuál es la diferencia entre una exposición que es **inválida** (falla al parsear) y una que es meramente **no convencional** (genera avisos del linter)? ¿Qué clase de problema rompería un scrape?
- **4d.** El conjunto de caracteres válidos para el nombre de una métrica es `[a-zA-Z_:][a-zA-Z0-9_:]*`. Los dos puntos `:` son legales en ese regex, y sin embargo la guía de nombres dice que nunca los uses en métricas instrumentadas. ¿Por qué?

---

## Ejercicio 5 — Metadata y los dos puntos reservados para las recording rules

Vas a leer la metadata de tipo/unidad que Prometheus almacena por métrica, y luego crear una recording rule correctamente nombrada que *usa* los dos puntos reservados.

1. Consultá el catálogo de metadata que Prometheus construye a partir de las líneas `# TYPE`/`# HELP` scrapeadas:

   ```bash
   curl -s 'localhost:9090/api/v1/metadata?metric=myapp_http_requests_total' | jq .
   ```

   Salida esperada:

   ```json
   {
     "status": "success",
     "data": {
       "myapp_http_requests_total": [
         {
           "type": "counter",
           "help": "Total number of HTTP requests handled.",
           "unit": ""
         }
       ]
     }
   }
   ```

2. Creá una recording rule que pre-agrega el rate de requests por job. Fijate en el formato de nombre `level:metric:operations`:

   ```bash
   cat > rules.yml <<'EOF'
   groups:
     - name: myapp.rules
       rules:
         - record: job:myapp_http_requests:rate5m
           expr: sum by (job) (rate(myapp_http_requests_total[5m]))
   EOF
   ```

3. Validá el archivo de reglas:

   ```bash
   promtool check rules rules.yml
   ```

   Salida esperada:

   ```
   Checking rules.yml
     SUCCESS: 1 rules found
   ```

4. Confirmá que `promtool check metrics` rechazaría ese mismo nombre con dos puntos si apareciera como una métrica *instrumentada directamente*:

   ```bash
   printf '# TYPE job:myapp_http_requests:rate5m gauge\njob:myapp_http_requests:rate5m 1\n' \
     | promtool check metrics
   ```

   Salida esperada:

   ```
   job:myapp_http_requests:rate5m metric names should not contain ':'
   ```

**Verificación de comprensión**

- **5a.** En el nombre de recording rule `job:myapp_http_requests:rate5m`, decodificá cada uno de los tres segmentos separados por dos puntos según la convención `level:metric:operations`.
- **5b.** El paso 3 aceptó los dos puntos mientras que el paso 4 los rechazó. Enunciá la única regla que reconcilia esos dos resultados.
- **5c.** El campo `unit` de `/api/v1/metadata` estaba vacío para nuestro counter aunque el nombre termina en una palabra parecida a una unidad en otras partes del código. ¿De dónde viene realmente ese valor `unit`, y por qué está en blanco acá?
- **5d.** ¿Por qué es buena práctica darle a la recording rule su propio nombre agregado en lugar de reutilizar `myapp_http_requests_total` con un conjunto distinto de labels?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

- **1a.** `namespace = node` · `name = network_receive` · `unit = bytes` · `suffix = _total`. Así que es "bytes recibidos acumulados en una interfaz de red", un counter.
- **1b.** Convención de Prometheus: **usá siempre unidades base sin calificar** y dejá que la capa de query/dashboard escale para la visualización (bytes, seconds, ratios en 0–1). Codificar `kilobytes`/`mebibytes` en el nombre obliga a cada consumidor a conocer y deshacer el factor de escala, y mezclar escalas entre métricas rompe la aritmética. Ref: https://prometheus.io/docs/practices/naming/.
- **1c.** El tiempo de CPU es tiempo *acumulado*, y la unidad base de tiempo es el **segundo** (nunca milisegundos/nanosegundos en el nombre). Como solo aumenta (acumulativo monotónico), es un counter, y los counters llevan el sufijo `_total` para que `rate()`/`increase()` y las herramientas puedan reconocerlos.
- **1d.** Los counters terminan en `_total`; **los que no son counters (gauges, etc.) no deben hacerlo**. `MemAvailable` es un nivel instantáneo que sube y baja — un gauge — así que no lleva `_total`.

**Ejercicio 2**

- **2a.** El cliente de Python **agrega automáticamente `_total`** a los nombres de counters en la exposición; vos proveés el nombre base. Si hubieras escrito `"myapp_http_requests_total"` en el fuente, el cliente lo habría agregado de nuevo y expuesto el nombre duplicado e incorrecto `myapp_http_requests_total_total`. (Contraste: el cliente de Go *no* lo agrega automáticamente — ahí tenés que escribir `_total` vos mismo. Sabé qué librería estás usando.)
- **2b.** `le` = "less than or equal to" (menor o igual que): cada serie `_bucket` cuenta las observaciones cuyo valor es ≤ esa cota superior (buckets acumulativos; el bucket `+Inf` es igual a `_count`). `le` está **reservado para los límites de los buckets del histogram**, así que nunca debés definir tu propio label llamado `le` (igual que `quantile` está reservado para los summaries).
- **2c.** El **patrón info / machine-state**: un gauge fijado en `1` cuyos *labels* llevan metadata constante y de baja rotación (version, revision, build). Lo unís con las métricas reales usando `* on(...) group_left(version) myapp_build_info` para adjuntar la dimensión de versión sin incrustar strings de alta rotación en cada métrica operativa. La constante `1` significa que la serie solo contribuye sus labels, nunca un valor.
- **2d.** (1) **Unidades base** — la latencia es tiempo, así que la unidad base es `seconds`, no `ms`. (2) **Nombres descriptivos con sufijo de unidad** — `..._duration_seconds` dice qué se mide y su unidad; un simple `..._latency` omite la unidad y es ambiguo.
- **2e.** `_created` lleva el timestamp Unix en el que esa serie fue creada por primera vez, emitido por defecto bajo el formato de exposición **OpenMetrics** para que los consumidores puedan detectar reinicios de counters. Ref: especificación de OpenMetrics.

**Ejercicio 3**

- **3a.** La cardinalidad solo se *materializa* cuando una combinación de labels se observa efectivamente. Algunas combinaciones podrían no ocurrir nunca en la ventana de muestreo (por ejemplo, todavía ningún `500` en `/login`), y algunas son lógicamente imposibles, así que el conteo en vivo se ubica en o por debajo del producto teórico.
- **3b.** Total de series ≈ producto de la cantidad de valores por label, así que `9 × (hasta 10,000 user_ids) →` decenas de miles. Costos: (1) **memoria/TSDB** — cada serie activa consume memoria del head-block y espacio de índice; (2) **costo de query** — las agregaciones deben tocar cada serie, así que los dashboards y las reglas se vuelven más lentos. Esta es la forma principal en que las instancias de Prometheus se caen.
- **3c.** Una URL cruda con query strings es efectivamente cardinalidad **no acotada, única por request** — el mismo modo de falla que `user_id`. Usá en su lugar el **template de ruta** (`/api/orders/{id}`, `/user/{name}`), de modo que todos los requests a un mismo handler compartan un único valor de label.
- **3d.** Los labels son las claves de agregación y de join. Si el mismo concepto es `method` en una métrica y `verb` en otra, no podés unirlas con `group_left`/`group_right` ni agregar de forma consistente entre métricas — **los nombres de labels deben ser estables e idénticos para el mismo significado**.
- **3e.** Los labels con prefijo `__` están **reservados para uso interno de Prometheus** — por ejemplo, `__name__` (el nombre de la métrica en sí), y los labels `__meta_*` / `__address__` presentes durante el relabeling antes de que se haga scraping de un target. La instrumentación de usuario no debe crearlos.

**Ejercicio 4**

- **4a.**
  - `counter metrics should have "_total" suffix` → renombrado `myapp_processed` → `myapp_processed_total`.
  - `non-counter metrics should not have "_total" suffix` → el gauge `myapp_queue_length_total` → `myapp_queue_length`.
  - `use base unit "seconds" instead of "milliseconds"` → `myapp_request_latency_milliseconds` → `myapp_request_latency_seconds`.
  - `label names should be written in 'snake_case' not 'camelCase'` → el label `deviceName` → `device_name`.
- **4b.** El nombre es un *contrato sobre la unidad*. Renombrar a `_seconds` dejando `12` afirmaría 12 **segundos** de latencia; la cantidad real era 12 ms, así que el valor debe dividirse por 1000 a `0.012` para mantener consistentes el nombre y el valor.
- **4c.** **Inválida** = viola la gramática de exposición (sintaxis incorrecta, series duplicadas, labels malformados) → el scrape **falla** y el target se marca como caído. **No convencional** = parsea bien pero rompe las mejores prácticas de nombres → `promlint` avisa, el scrape igual tiene éxito. Solo la clase inválida rompe un scrape.
- **4d.** Los dos puntos están **reservados por convención para los nombres de salida de las recording rules** (`level:metric:operations`). Mantenerlos fuera de las métricas instrumentadas directamente preserva esa señal: un `:` en un nombre te dice de un vistazo que la serie es una recording rule derivada, no instrumentación cruda.

**Ejercicio 5**

- **5a.** `job` = el **nivel** de agregación (agregado a un valor por job); `myapp_http_requests` = la **métrica de origen** de la que deriva; `rate5m` = la(s) **operación(es)** aplicada(s) (un rate de 5 minutos, luego sumado). Se lee como "el rate de requests de 5 minutos por job".
- **5b.** **Los dos puntos se permiten solo en nombres de recording rules (y de queries), nunca en nombres de métricas instrumentadas/expuestas directamente.** `check rules` trata el nombre como salida de regla (permitido); `check metrics` lo trata como instrumentación (prohibido).
- **5c.** El campo `unit` se llena a partir de la línea de metadata `# UNIT` (opcional) de la exposición **OpenMetrics**, no se infiere del nombre. Nuestro exporter no emite ningún `# UNIT`, así que es el string vacío aunque la unidad viva en el sufijo del nombre.
- **5d.** Las recording rules deberían publicar un **nombre nuevo y distinto** (con la convención de los dos puntos) para que la serie pre-agregada sea inconfundiblemente derivada y no pueda colisionar ni confundirse con el counter crudo. Reemitir el nombre original con labels reducidos crearía dos series distintas reclamando el mismo nombre/semántica — ambiguo para consultar y para razonar.

</details>