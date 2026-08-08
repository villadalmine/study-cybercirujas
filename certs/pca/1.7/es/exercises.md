# Métricas de Timestamp — Ejercicios Guiados

> **Certificación:** Prometheus Certified Associate (PCA)
> **Dominio 1 · Tema 1.7 — Métricas de Timestamp** · Peso en el examen: 4
>
> Cada sample de Prometheus es un par *(timestamp, value)*. Este tema trata sobre las dos formas en que el tiempo aparece en Prometheus y la constante confusión entre ellas:
>
> 1. **El timestamp del sample** — metadata adjunta a cada sample, que indica *cuándo se tomó esta observación*. Lo leés con la función `timestamp()`.
> 2. **Una métrica cuyo valor resulta ser un tiempo Unix** — p. ej. `process_start_time_seconds`, `node_boot_time_seconds`, `..._last_success_timestamp_seconds`. Es un float común y corriente que restás de `time()` para obtener una antigüedad.
>
> Estos ejercicios te hacen producir, observar y razonar sobre ambos, además de la opción de scrape `honor_timestamps` y la staleness. Cada bloque termina con preguntas de verificación; las respuestas están colapsadas al final.

---

## Ejercicio 0 — Levantar un laboratorio reproducible

Necesitás un Prometheus vivo, un target autoinstrumentado (el propio Prometheus ya expone `process_start_time_seconds`), un node_exporter para `node_boot_time_seconds`, un Pushgateway para el patrón de batch-job, y un target hecho a mano que emita un timestamp **explícito** para que puedas ejercitar `honor_timestamps`.

**Pasos**

1. Creá un directorio de trabajo y la configuración de Prometheus:

   ```bash
   mkdir -p ts-lab && cd ts-lab
   ```

   ```yaml
   # prometheus.yml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: 'prometheus'
       static_configs:
         - targets: ['prometheus:9090']

     - job_name: 'node'
       static_configs:
         - targets: ['node-exporter:9100']

     - job_name: 'pushgateway'
       honor_labels: true
       static_configs:
         - targets: ['pushgateway:9091']

     - job_name: 'stamped'          # our hand-rolled target, edited in Ex. 4
       # honor_timestamps: true      # (default) — we will flip this later
       static_configs:
         - targets: ['stamped:8000']
   ```

2. Levantá el stack:

   ```yaml
   # docker-compose.yml
   services:
     prometheus:
       image: prom/prometheus:v2.53.0
       command: ["--config.file=/etc/prometheus/prometheus.yml"]
       volumes: ["./prometheus.yml:/etc/prometheus/prometheus.yml:ro",
                 "./rules.yml:/etc/prometheus/rules.yml:ro"]
       ports: ["9090:9090"]
     node-exporter:
       image: prom/node-exporter:v1.8.1
       ports: ["9100:9100"]
     pushgateway:
       image: prom/pushgateway:v1.9.0
       ports: ["9091:9091"]
     stamped:
       image: python:3.12-slim
       working_dir: /app
       volumes: ["./stamped.py:/app/stamped.py:ro"]
       command: ["python", "stamped.py"]
       ports: ["8000:8000"]
   ```

   ```bash
   touch rules.yml stamped.py     # placeholders, filled in later
   docker compose up -d prometheus node-exporter pushgateway
   ```

3. Confirmá que los dos targets principales están `UP`:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | grep -o '"job":"[a-z-]*","[^}]*"health":"[a-z]*"'
   ```

   Esperado (el orden puede variar):

   ```
   "job":"prometheus", ... "health":"up"
   "job":"node", ...       "health":"up"
   ```

**Verificá tu comprensión**

- **Q0.1** Con `scrape_interval: 15s`, ¿qué distancia hay entre dos samples consecutivos de la *misma* serie sobre el eje del tiempo, y en qué unidad almacena Prometheus internamente esa distancia?
- **Q0.2** Nada en esta configuración establece un timestamp para los samples de los jobs `prometheus` o `node`. Entonces, ¿de dónde viene el timestamp de cada sample?

---

## Ejercicio 1 — La anatomía de un sample: value vs. timestamp

**Pasos**

1. Hacé scrape a mano del endpoint de métricas del propio Prometheus y aislá la métrica de start-time:

   ```bash
   curl -s http://localhost:9090/metrics | grep '^process_start_time_seconds'
   ```

   Esperado (tu número será distinto):

   ```
   process_start_time_seconds 1.7549280e+09
   ```

   Esta línea es el clásico **formato de exposición de texto** de Prometheus: `metric_name value`. *No* hay un token de timestamp al final aquí — el valor `1.7549280e+09` es un tiempo Unix **en segundos** que es el *valor* de la métrica, no el timestamp del sample.

2. Ahora consultá la misma métrica a través de la API y observá qué es realmente un sample almacenado:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=process_start_time_seconds{job="prometheus"}' \
     | python3 -m json.tool
   ```

   Forma esperada:

   ```json
   {
     "status": "success",
     "data": {
       "resultType": "vector",
       "result": [
         {
           "metric": {"__name__": "process_start_time_seconds", "instance": "prometheus:9090", "job": "prometheus"},
           "value": [1754928315.123, "1754928000"]
         }
       ]
     }
   }
   ```

3. Leé con atención el array `"value"`. Es **`[ <sample timestamp, seconds>, "<sample value>" ]`**:
   - `1754928315.123` — el *timestamp del sample*: el momento de evaluación de la query, inyectado por el motor.
   - `"1754928000"` — el *value*: cuándo arrancó este proceso de Prometheus.

**Verificá tu comprensión**

- **Q1.1** En la respuesta de la API, ¿qué elemento del array `value` es *metadata sobre cuándo existe la observación* y cuál es *la cantidad observada*? ¿Por qué contienen dos números de aspecto distinto aunque ambos parezcan tiempos Unix?
- **Q1.2** En la línea de exposición cruda `process_start_time_seconds 1.7549280e+09`, ¿`1.7549280e+09` es un timestamp o un value? ¿Qué pasará con el timestamp del *sample* de esta serie una vez que Prometheus lo almacene?
- **Q1.3** Prometheus almacena el value de cada sample como un `float64` y su timestamp como un `int64`. Dado eso, ¿cuál es la resolución (la menor distancia representable) de un timestamp de sample?

---

## Ejercicio 2 — `timestamp()` lee la metadata, no el value

La función `timestamp()` (agregada en Prometheus 2.0) devuelve, para cada elemento de un instant vector, **el timestamp del sample expresado en segundos desde el epoch de Unix** — deliberadamente independiente del value del sample.

**Pasos**

1. En la UI de Prometheus (`http://localhost:9090/graph`) o vía `curl`, evaluá el valor de la métrica:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=process_start_time_seconds{job="prometheus"}' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928000"]
   ```

2. Ahora envolvela en `timestamp()` y evaluá de nuevo:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=timestamp(process_start_time_seconds{job="prometheus"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928311"]
   ```

3. Compará los dos resultados:
   - Métrica pelada → value `1754928000` (arranque del proceso).
   - `timestamp(...)` → value `1754928311` (el timestamp del **sample scrapeado más reciente**, es decir, aproximadamente *ahora*, retrocedido hasta el último scrape, a lo sumo un `scrape_interval` atrás).

4. Confirmá que `timestamp()` ignora por completo el valor subyacente aplicándola a una métrica cuyo valor es un entero minúsculo:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928315.123,"1754928309"]
   ```

   `up` tiene valor `1`, y sin embargo `timestamp(up)` devuelve un tiempo Unix de ~10 dígitos — prueba de que `timestamp()` reporta *cuándo se registró el sample*, nunca el número almacenado en él.

**Verificá tu comprensión**

- **Q2.1** `timestamp(up)` devuelve algo como `1754928309` mientras que `up` en sí devuelve `1`. Explicá, en una sola oración, por qué los dos números no tienen nada que ver entre sí.
- **Q2.2** Evaluás `timestamp(up)` y obtenés un valor 12 segundos menor que `time()`. ¿Qué representa físicamente esa distancia de 12 segundos, y cuál es su cota superior esperada en este laboratorio?
- **Q2.3** Verdadero o falso: `timestamp(process_start_time_seconds)` te dice cuándo arrancó el proceso. Justificá.

---

## Ejercicio 3 — Convertir una métrica con valor de timestamp en una antigüedad

El modismo para "qué antigüedad tiene X" es siempre el mismo: **`time() - <a_metric_whose_value_is_a_unix_time_in_seconds>`**. `time()` devuelve el momento de evaluación de la query en segundos desde el epoch.

**Pasos**

1. Calculá el uptime de este proceso de Prometheus a partir de su métrica de start-time:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-process_start_time_seconds{job="prometheus"}' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"700.5498733520508"]
   ```

   → ~700 segundos de uptime.

2. Calculá el uptime del host a partir de la métrica de boot-time de node_exporter:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-node_boot_time_seconds' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"864321.4470000267"]
   ```

   → ~10 días.

3. Contrastá eso con una fórmula **incorrecta** pero tentadora que usa `timestamp()` sobre la misma métrica:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(node_boot_time_seconds)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928700.55,"7.550000190734863"]
   ```

   → ~7 segundos. Eso es *tiempo desde el último scrape*, **no** el uptime del host — porque `timestamp()` devolvió el momento del scrape, no el momento del boot.

**Verificá tu comprensión**

- **Q3.1** Querés la **antigüedad del host** (cuánto tiempo pasó desde el boot). ¿Cuál es correcta: `time() - node_boot_time_seconds` o `time() - timestamp(node_boot_time_seconds)`? ¿Qué mide en realidad la *otra* expresión?
- **Q3.2** Un colega escribe `node_boot_time_seconds - time()` para obtener el uptime y siempre le da negativo. ¿Qué hizo mal, y a qué equivale en magnitud el número negativo?
- **Q3.3** ¿Por qué una métrica de "punto en el tiempo" debe expresarse como **segundos desde el epoch de Unix** (según las convenciones de nomenclatura de Prometheus, sufijo `_timestamp_seconds` / `_time_seconds`) para que `time() - metric` tenga sentido? ¿Qué se rompe si alguien la expone en milisegundos?

---

## Ejercicio 4 — Timestamps explícitos en la exposición y `honor_timestamps`

El formato de texto permite un tercer token **opcional**: `metric_name{labels} <value> <timestamp_ms>`, donde el timestamp está en **milisegundos** desde el epoch (un `int64`). Que Prometheus conserve ese timestamp o lo sobrescriba con el momento del scrape lo gobierna la opción por scrape `honor_timestamps` (por defecto **`true`**).

**Pasos**

1. Escribí un target minúsculo que emita un timestamp explícito deliberadamente **60 segundos en el pasado**:

   ```python
   # stamped.py
   import time
   from http.server import BaseHTTPRequestHandler, HTTPServer

   class H(BaseHTTPRequestHandler):
       def do_GET(self):
           ts_ms = int((time.time() - 60) * 1000)   # 60s in the past, in ms
           body = (
               "# HELP demo_reading A gauge exposed with an explicit past timestamp\n"
               "# TYPE demo_reading gauge\n"
               f"demo_reading{{source=\"sensor-a\"}} 42 {ts_ms}\n"
           ).encode()
           self.send_response(200)
           self.send_header("Content-Type", "text/plain; version=0.0.4")
           self.end_headers()
           self.wfile.write(body)
       def log_message(self, *a): pass

   HTTPServer(("0.0.0.0", 8000), H).serve_forever()
   ```

2. Arrancalo y agregalo al scrape (el job `stamped` ya está en `prometheus.yml`):

   ```bash
   docker compose up -d stamped
   curl -s http://localhost:8000/       # confirm the third token is present
   ```

   ```
   demo_reading{source="sensor-a"} 42 1754928650000
   ```

3. Con `honor_timestamps` en su valor por defecto (`true`), recargá e inspeccioná dónde ubicó Prometheus el sample sobre el eje del tiempo:

   ```bash
   docker compose kill -s HUP prometheus     # or restart
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(demo_reading)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928710.9,"60.90000009536743"]
   ```

   → ~60 s: Prometheus **honró** el timestamp expuesto, así que el sample queda 60 s en el pasado aunque se lo scrapeó recién.

4. Ahora invertí la opción. Editá `prometheus.yml`, poné `honor_timestamps: false` en el job `stamped`, recargá y volvé a medir:

   ```yaml
     - job_name: 'stamped'
       honor_timestamps: false
       static_configs:
         - targets: ['stamped:8000']
   ```

   ```bash
   docker compose kill -s HUP prometheus
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(demo_reading)' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754928760.4,"5.400000095367432"]
   ```

   → ahora solo ~5 s (un scrape atrás): Prometheus **ignoró** el token expuesto y estampó el sample con el momento del scrape.

**Verificá tu comprensión**

- **Q4.1** En la línea de exposición `demo_reading{source="sensor-a"} 42 1754928650000`, nombrá cada uno de los tres tokens y dá la unidad del tercero.
- **Q4.2** Con `honor_timestamps: true`, ¿por qué `time() - timestamp(demo_reading)` devolvió ~60 aunque el scrape ocurrió hace milisegundos?
- **Q4.3** ¿Cuál es el valor por defecto de `honor_timestamps`, y qué le hace, ponerlo en `false`, a cualquier timestamp que exponga un target?
- **Q4.4** Un target sigue reexponiendo el *mismo* timestamp explícito en cada scrape (su reloj está trabado). Con `honor_timestamps: true`, ¿qué pasa con el segundo sample y los siguientes, y por qué Prometheus considera stale esa serie unos minutos después aunque el target esté `up`?

---

## Ejercicio 5 — Detectar scrapes estancados y desfasaje de reloj

Como `timestamp(up)` reporta el wall-clock del *último scrape exitoso*, `time() - timestamp(up)` es una sonda portable de "segundos desde la última vez que supe de este target".

**Pasos**

1. Establecé una línea base de la frescura de cada target:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up)' \
     | python3 -c 'import sys,json; [print(r["metric"]["job"], r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'
   ```

   ```
   prometheus 4.90
   node       9.90
   pushgateway 1.90
   stamped    6.40
   ```

   Todos chicos — cada job está dentro de aproximadamente un `scrape_interval`.

2. Simulá un target muerto y observá cómo trepa el número:

   ```bash
   docker compose stop node-exporter
   sleep 90
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929050.0,"85.0"]
   ```

   → ~85 s y subiendo. Pero seguí observando:

   ```bash
   sleep 240
   curl -s 'http://localhost:9090/api/v1/query?query=time()-timestamp(up{job="node"})' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929290.0,"[]"]   # empty result — see below
   ```

   Una vez que no aparece ningún sample de `up{job="node"}` dentro del lookback delta por defecto de 5 minutos, la serie se vuelve **stale** y sale de la evaluación de instant-vector, de modo que la expresión no devuelve *nada*.

3. Restaurá el target:

   ```bash
   docker compose start node-exporter
   ```

**Verificá tu comprensión**

- **Q5.1** ¿Por qué `time() - timestamp(up)` es una buena señal de "frescura de scrape", y qué indica un valor que crece de forma sostenida?
- **Q5.2** Después de que el target estuvo caído ~5 minutos, la expresión devolvió un resultado vacío en lugar de un número grande. ¿Qué mecanismo de Prometheus causa eso, y cuál es la ventana por defecto antes de que actúe?
- **Q5.3** Dado Q5.2, ¿por qué `time() - timestamp(up)` no es confiable para alertar sobre caídas *largas*, y qué expresión más simple (usando `up` en sí, o `absent()`) le sumarías para atrapar un target que desapareció por completo?

---

## Ejercicio 6 — El patrón de frescura de batch-job (Pushgateway + alerta)

Los batch jobs no corren el tiempo suficiente como para ser scrapeados, así que **pushean** un timestamp de "último éxito" al Pushgateway; después alertás cuando se vuelve demasiado viejo. Este es el *timestamp metric* canónico en producción.

**Pasos**

1. Simulá una corrida exitosa de batch pusheando un gauge `_last_success_timestamp_seconds` (value = ahora, en **segundos**):

   ```bash
   cat <<EOF | curl -s --data-binary @- \
     http://localhost:9091/metrics/job/nightly_backup/instance/host01
   # TYPE backup_last_success_timestamp_seconds gauge
   # HELP backup_last_success_timestamp_seconds Unix time of the last successful backup
   backup_last_success_timestamp_seconds $(date +%s)
   EOF
   ```

2. Confirmá que Prometheus lo scrapeó desde el Pushgateway y calculá su antigüedad:

   ```bash
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-backup_last_success_timestamp_seconds' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929400.0,"18.0"]
   ```

   → 18 s de antigüedad — fresco.

3. Agregá una regla de alerta y cargala:

   ```yaml
   # rules.yml
   groups:
     - name: batch-freshness
       rules:
         - alert: BackupStale
           expr: time() - backup_last_success_timestamp_seconds > 24 * 3600
           for: 5m
           labels:
             severity: warning
           annotations:
             summary: "Backup for {{ $labels.instance }} has not succeeded recently"
             description: "Last success was {{ $value | humanizeDuration }} ago."
   ```

   ```bash
   docker compose kill -s HUP prometheus
   curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"BackupStale","state":"[a-z]*"'
   ```

   ```
   "name":"BackupStale","state":"inactive"
   ```

4. Falseá una corrida vieja para disparar la alerta *ahora* (pusheá un timestamp 30 horas en el pasado):

   ```bash
   cat <<EOF | curl -s --data-binary @- \
     http://localhost:9091/metrics/job/nightly_backup/instance/host01
   backup_last_success_timestamp_seconds $(( $(date +%s) - 30*3600 ))
   EOF
   sleep 20
   curl -s 'http://localhost:9090/api/v1/query?query=time()-backup_last_success_timestamp_seconds > 24*3600' \
     | grep -o '"value":\[[^]]*\]'
   ```

   ```
   "value":[1754929500.0,"108020.0"]
   ```

   → ~30 h > 24 h: la expresión ahora devuelve un valor, así que después de la ventana `for: 5m` la alerta pasa a `firing`.

**Verificá tu comprensión**

- **Q6.1** ¿Por qué un batch job pushea un *timestamp de último éxito* en lugar de, digamos, un booleano `backup_ok`? ¿Qué modo de falla atrapa el timestamp que un booleano seteado solo en caso de éxito pasaría por alto?
- **Q6.2** El valor pusheado es `$(date +%s)`. ¿Qué unidad es esa, y por qué la expresión de alerta compara contra `24 * 3600` en lugar de `24`?
- **Q6.3** ¿Por qué está seteado `honor_labels: true` en el job de scrape `pushgateway` (recordá la config del Ej. 0), y qué se rompería en este patrón sin él?
- **Q6.4** Si el Pushgateway se reiniciara y perdiera las series pusheadas, `time() - backup_last_success_timestamp_seconds` devolvería vacío en lugar de un número enorme — así que `BackupStale` dejaría de dispararse silenciosamente. ¿Sobre qué función agregarías una alerta complementaria para detectar la *desaparición* de la métrica?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0
- **A0.1** A 15 segundos de distancia (un `scrape_interval`). Internamente Prometheus almacena el timestamp de cada sample como un **`int64` de milisegundos desde el epoch de Unix**, así que la distancia se almacena como `15000`.
- **A0.2** Del **scrape**: como ninguno de estos targets expone un token de timestamp explícito, Prometheus le asigna a cada sample el wall-clock del momento en que ocurrió el scrape. (Fuente: https://prometheus.io/docs/concepts/data_model/ y https://prometheus.io/docs/instrumenting/exposition_formats/)

### Ejercicio 1
- **A1.1** El **primer** elemento (`1754928315.123`) es metadata — el timestamp del sample, es decir, *cuándo existe la observación sobre el eje del tiempo*. El **segundo** elemento (`"1754928000"`) es la cantidad observada — acá resulta ser también un tiempo Unix (arranque del proceso), razón por la cual ambos parecen fechas, pero conceptualmente no tienen relación: uno es *cuándo miramos*, el otro es *qué vimos*.
- **A1.2** Es un **value** (el momento de arranque del proceso). El timestamp de su *sample* no está presente en esa línea, así que Prometheus le asignará el **momento del scrape** cuando almacene la serie.
- **A1.3** Los values son `float64`; los timestamps son `int64` en **milisegundos**, así que la menor distancia representable entre dos timestamps de sample es **1 milisegundo**.

### Ejercicio 2
- **A2.1** `up` devuelve su *value* almacenado (`1` = el scrape tuvo éxito); `timestamp(up)` devuelve el *timestamp del sample* (cuándo se registró ese sample). `timestamp()` nunca mira el value, así que los dos números son independientes por construcción.
- **A2.2** La distancia es el tiempo entre el último scrape exitoso de esa serie y el instante de evaluación de la query — es decir, hace cuánto Prometheus registró por última vez el sample. Su cota superior esperada es aproximadamente un `scrape_interval` (~15 s) más el jitter del scrape, mientras el target esté sano.
- **A2.3** **Falso.** `timestamp(process_start_time_seconds)` devuelve *cuándo se scrapeó el sample* (~ahora). El momento de arranque del proceso es el **value** de la métrica; lo leés directamente, no a través de `timestamp()`. (Fuente: https://prometheus.io/docs/prometheus/latest/querying/functions/#timestamp)

### Ejercicio 3
- **A3.1** `time() - node_boot_time_seconds` es la correcta — resta el instante del boot (el value de la métrica) del ahora, dando el uptime del host. `time() - timestamp(node_boot_time_seconds)` mide *el tiempo desde el último scrape* de esa serie (~segundos), porque `timestamp()` devuelve el momento del scrape, no el value.
- **A3.2** Invirtieron los operandos. `time()` (ahora) es mayor que `node_boot_time_seconds` (un instante pasado), así que `boot - now` es negativo; su magnitud equivale al uptime correcto. Solución: `time() - node_boot_time_seconds`.
- **A3.3** `time()` devuelve **segundos** desde el epoch, así que la métrica también debe estar en segundos para que la resta sea dimensionalmente consistente (unidad base del SI, según https://prometheus.io/docs/practices/naming/). Si estuviera en milisegundos, `time() - metric` produciría un número absurdo, enormemente negativo (restar ~1.75e12 de ~1.75e9).

### Ejercicio 4
- **A4.1** Token 1 = nombre de la métrica **con labels** (`demo_reading{source="sensor-a"}`); token 2 = el **value** (`42`); token 3 = el **timestamp explícito del sample**, en **milisegundos** desde el epoch de Unix (`1754928650000`).
- **A4.2** Con `honor_timestamps: true`, Prometheus almacenó el sample en el timestamp expuesto (60 s en el pasado), no en el momento del scrape. Así que `timestamp(demo_reading)` devuelve ese momento pasado, y `time()` menos eso ≈ 60.
- **A4.3** El valor por defecto es **`true`**. Ponerlo en `false` hace que Prometheus **descarte** cualquier timestamp que exponga el target y estampe en cambio cada sample con el momento del scrape. (Fuente: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- **A4.4** Cada scrape trae el mismo timestamp (o uno más viejo), así que después del primero, los samples siguientes quedan **fuera de orden / duplicados** para esa serie y se descartan — la serie deja de avanzar. Una vez que no cae ningún sample *más nuevo* dentro del lookback delta de 5 minutos, la serie se trata como **stale** y desaparece de las queries, aunque el endpoint HTTP del target siga `up`. Este es el peligro clásico de exponer timestamps explícitos y la razón por la que se desaconseja para métricas comunes.

### Ejercicio 5
- **A5.1** `timestamp(up)` es el wall-clock del último scrape exitoso; restarlo de `time()` da los segundos desde la última vez que Prometheus supo del target. Un valor que crece de forma sostenida significa que los scrapes ya no están cayendo (target colgado, red rota, o scrape agotando el timeout).
- **A5.2** **Manejo de staleness.** Tras no haber ningún sample para la serie dentro del **lookback delta (5 minutos por defecto)**, la serie se considera stale y se excluye de la evaluación de instant-vector, así que la expresión devuelve un resultado vacío. (Fuente: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness)
- **A5.3** Porque una vez que la serie se vuelve stale la expresión no arroja *nada* — no puede reportar "10 minutos de antigüedad", reporta vacío — así que un umbral sobre ella nunca dispara para caídas largas. Sumale `up{job="node"} == 0` (target scrapeado pero fallando) y/o `absent(up{job="node"})` (target desaparecido por completo) para atrapar la caída que la expresión de frescura ya no puede ver.

### Ejercicio 6
- **A6.1** Un *timestamp* de último éxito te permite calcular *hace cuánto fue la última corrida buena* con `time() - metric`, así que un job que deja de correr por completo (nunca vuelve a pushear) queda atrapado a medida que crece la antigüedad. Un booleano seteado solo en caso de éxito queda **trabado en `1`** para siempre después del último éxito y no puede distinguir "tuvo éxito hace poco" de "no corre desde hace una semana".
- **A6.2** `date +%s` son **segundos** desde el epoch, que coinciden con `time()`. El umbral es `24 * 3600` porque ambos lados están en segundos, así que 24 horas deben escribirse como **86 400 segundos**, no `24`.
- **A6.3** `honor_labels: true` le dice a Prometheus que **no** sobrescriba los labels `job`/`instance` que el Pushgateway ya trae (el `job=nightly_backup`, `instance=host01` pusheados) con el `job="pushgateway"` propio del job de scrape. Sin él, cada serie pusheada se reetiquetaría a `job="pushgateway"`, colapsando/renombrando la identidad del batch y rompiendo la alerta por job. (Fuente: https://prometheus.io/docs/practices/pushing/ y https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config)
- **A6.4** Alertá sobre **`absent(backup_last_success_timestamp_seconds)`** (opcionalmente acotado por job/instance), que dispara precisamente cuando la serie desaparece — cubriendo el punto ciego donde la expresión de antigüedad devuelve vacío y `BackupStale` ya no puede saltar.

</details>

---

**Fuentes**
- Modelo de datos (samples = timestamp+value): https://prometheus.io/docs/concepts/data_model/
- Formato de exposición (timestamp opcional en milisegundos): https://prometheus.io/docs/instrumenting/exposition_formats/
- Opción de scrape `honor_timestamps`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- Funciones `timestamp()` y `time()`: https://prometheus.io/docs/prometheus/latest/querying/functions/#timestamp · https://prometheus.io/docs/prometheus/latest/querying/functions/#time
- Staleness: https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness
- Nomenclatura de métricas / unidades base: https://prometheus.io/docs/practices/naming/
- Batch jobs y Pushgateway: https://prometheus.io/docs/practices/pushing/
- Currículum de PCA: https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf