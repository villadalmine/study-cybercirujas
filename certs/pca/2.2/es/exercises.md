# Ejercicios guiados — Tema 2.2: Configuración y scraping (PCA)

Estos labs te guían por la mecánica de cómo Prometheus descubre, configura y hace scraping de los targets. Vas a editar `prometheus.yml`, recargarlo de forma segura y observar cómo el pipeline de relabeling reescribe la identidad de un target antes de que se almacene una sola muestra. Recorrelos en orden — cada uno se apoya en la instancia en ejecución del anterior.

**Requisitos previos**

- Un host Linux con los binarios `prometheus` y `promtool` (v2.53+ o v3.x — la superficie de configuración que se usa acá es idéntica en ambos) y `node_exporter` extraído en algún lugar de `$PATH` o en el directorio actual.
- `curl` y `jq` instalados.
- Tres terminales libres. Todos los comandos asumen que primero hacés `cd` a un directorio de trabajo vacío: `mkdir -p ~/pca-lab && cd ~/pca-lab`.

> El examen es agnóstico de versión respecto a los flags, pero donde un comportamiento cambió entre versiones mayores se señala explícitamente.

---

## Ejercicio 1 — El bloque global, `promtool` y un primer scrape job

El bloque `global` define los valores por defecto que hereda todo scrape job salvo que los sobrescriba. Nunca vas a memorizar el intervalo efectivo de un target leyendo un job de forma aislada — lo leés contra `global`.

**Pasos**

1. Creá la configuración útil más pequeña. Guardá esto como `prometheus.yml`:

   ```yaml
   global:
     scrape_interval: 15s      # how often to scrape each target
     scrape_timeout: 10s       # give up on a scrape after this long
     evaluation_interval: 15s  # how often to evaluate rules (not scraping)
     external_labels:
       cluster: pca-lab
       replica: A

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ["localhost:9090"]
   ```

2. Validá el archivo **antes** de iniciar nada. Nunca inicies Prometheus con una configuración sin validar en producción — un error de sintaxis puede dejar un reload aplicado a medias:

   ```bash
   promtool check config prometheus.yml
   ```

   Salida esperada:

   ```
   Checking prometheus.yml
    SUCCESS: prometheus.yml is valid prometheus config file syntax
   ```

3. Iniciá Prometheus en la **primera** terminal, habilitando la API de lifecycle para poder recargar por HTTP más adelante:

   ```bash
   prometheus \
     --config.file=prometheus.yml \
     --web.enable-lifecycle
   ```

4. En la **segunda** terminal, confirmá que el target está up y leé el intervalo que Prometheus realmente le asignó:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq '.data.activeTargets[] | {job: .labels.job, health, scrapeInterval, scrapeUrl}'
   ```

   Esperado (abreviado):

   ```json
   {
     "job": "prometheus",
     "health": "up",
     "scrapeInterval": "15s",
     "scrapeUrl": "http://localhost:9090/metrics"
   }
   ```

5. Consultá la métrica sintética `up` y fijate en los labels que Prometheus adjuntó sin que se lo pidieras:

   ```bash
   curl -s 'localhost:9090/api/v1/query?query=up' | jq '.data.result'
   ```

   Esperado:

   ```json
   [
     {
       "metric": { "__name__": "up", "instance": "localhost:9090", "job": "prometheus" },
       "value": [ 1712345678.9, "1" ]
     }
   ]
   ```

**Preguntas de comprensión**

- **1a.** Escribiste `targets: ["localhost:9090"]` pero nunca escribiste un label `instance`. ¿De dónde salió `instance="localhost:9090"`?
- **1b.** La URL de scrape es `http://localhost:9090/metrics`. No configuraste un scheme ni un path. ¿Cuáles son los valores por defecto, y qué claves de configuración cambiarías para sobrescribirlos?
- **1c.** `external_labels` están configurados, pero **no** aparecen en el resultado de `up` de arriba. ¿Cuándo *sí* se adjuntan, y a qué?
- **1d.** ¿Qué prueba realmente `up == 1`, y qué *no* prueba sobre el target?

---

## Ejercicio 2 — Agregar un segundo job y sobrescribir `global`

**Pasos**

1. Iniciá `node_exporter` en la **tercera** terminal (escucha en `:9100` por defecto):

   ```bash
   ./node_exporter
   ```

2. Agregá un segundo scrape job que sobrescriba el intervalo y el timeout globales. Editá `prometheus.yml`, agregando debajo de `scrape_configs`:

   ```yaml
     - job_name: node
       scrape_interval: 5s     # override global 15s — this job is scraped 3x more often
       scrape_timeout: 4s      # must be <= scrape_interval
       static_configs:
         - targets: ["localhost:9100"]
           labels:
             env: dev          # a custom target label, applied to every series from this target
   ```

3. Validá, después recargá por HTTP (sin reinicio, sin muestras perdidas para el otro job):

   ```bash
   promtool check config prometheus.yml && \
     curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

   Esperado: `200`.

4. Confirmá que ambos jobs están presentes e inspeccioná el intervalo efectivo del nuevo:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.scrapeInterval)\t\(.labels.env // "-")"'
   ```

   Esperado:

   ```
   prometheus	15s	-
   node	5s	dev
   ```

5. Rompé deliberadamente la regla del timeout para ver la barrera de protección. Poné `scrape_timeout: 20s` en el job `node` (mayor que su intervalo de 5s), validá:

   ```bash
   promtool check config prometheus.yml
   ```

   Fallo esperado:

   ```
   Checking prometheus.yml
    FAILED: parsing YAML file prometheus.yml: scrape_timeout greater than scrape_interval for scrape config with job name "node"
   ```

6. Volvé `scrape_timeout` a `4s`, validá y recargá.

**Preguntas de comprensión**

- **2a.** El job `node` se scrapea cada 5s y `prometheus` cada 15s. Explicá por qué el reload por HTTP del paso 3 fue seguro de ejecutar mientras ambos estaban siendo scrapeados, frente a lo que habría costado un reinicio completo del proceso.
- **2b.** ¿Por qué Prometheus obliga a `scrape_timeout <= scrape_interval`? ¿Qué modo de fallo está previniendo?
- **2c.** El label `env: dev` se agregó bajo `static_configs[].labels`. ¿En cuántas series aparece, y en qué se diferencia de una entrada de `external_labels`?

---

## Ejercicio 3 — Vías de reload: SIGHUP vs la API de lifecycle vs reinicio

Saber *cómo* recargar es relevante para el examen porque cada vía tiene garantías y requisitos distintos.

**Pasos**

1. Confirmá que el endpoint de lifecycle está habilitado (devuelve 405 si te olvidaste del flag):

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:9090/-/reload
   ```

   Esperado: `200` (con `--web.enable-lifecycle`). Sin el flag obtendrías `403` / `405`.

2. Recargá con una señal UNIX en su lugar. Encontrá el PID y enviá `SIGHUP`:

   ```bash
   pgrep -f 'prometheus --config.file' | head -1 | xargs -r kill -HUP
   ```

   Mirá la primera terminal — deberías ver una línea de log similar a:

   ```
   level=info msg="Loading configuration file" filename=prometheus.yml
   level=info msg="Completed loading of configuration file" filename=prometheus.yml
   ```

3. Introducí un error e intentá un hot reload para probar que los reloads son transaccionales. Agregá una clave falsa `scrape_intervl: 5s` (error de tipeo) al job `node`, después:

   ```bash
   curl -s -X POST localhost:9090/-/reload
   ```

   Esperado: un no-200 con un cuerpo como:

   ```
   error loading config from "prometheus.yml": ... field scrape_intervl not found in type config.plain
   ```

4. Consultá los targets de nuevo — la configuración que estaba corriendo antes sigue activa; el archivo con errores **no** se aplicó:

   ```bash
   curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
   ```

   Esperado: `2` (sin cambios).

5. Corregí el error de tipeo, validá con `promtool` y recargá limpiamente.

**Preguntas de comprensión**

- **3a.** Enumerá las tres formas de aplicar una nueva configuración e indicá el requisito previo (si lo hay) de cada una.
- **3b.** En el paso 3 el reload falló. ¿Qué pasó con las métricas que se estaban recolectando durante ese intento fallido de reload?
- **3c.** Un compañero de equipo dice "reiniciá Prometheus y ya, es lo mismo que un reload". Nombrá dos cosas concretas que un reinicio hace y que un reload no.
- **3d.** ¿Qué mecanismo de reload conectarías a un cambio de `ConfigMap` en Kubernetes, y por qué es preferible a SIGHUP en ese entorno?

---

## Ejercicio 4 — Service discovery basado en archivos (`file_sd_configs`)

Hardcodear targets no escala. `file_sd_configs` permite que un sistema externo escriba archivos de targets que Prometheus observa y recarga *sin* un reload de configuración.

**Pasos**

1. Creá un archivo de targets `targets/nodes.yml`:

   ```bash
   mkdir -p targets
   cat > targets/nodes.yml <<'EOF'
   - targets:
       - "localhost:9100"
     labels:
       env: dev
       role: worker
   EOF
   ```

2. Reemplazá los `static_configs` del job `node` por file SD. El job ahora queda así:

   ```yaml
     - job_name: node
       scrape_interval: 5s
       scrape_timeout: 4s
       file_sd_configs:
         - files:
             - "targets/*.yml"     # glob; Prometheus watches the directory
           refresh_interval: 30s   # fallback poll if inotify misses a change
   ```

3. Validá y recargá:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

4. Ahora agregá un target *sin tocar `prometheus.yml`*. Agregá un segundo archivo de nodo:

   ```bash
   cat > targets/extra.yml <<'EOF'
   - targets: ["localhost:9090"]
     labels:
       env: dev
       role: monitoring
   EOF
   ```

5. Esperá un par de segundos, después observá cómo aparece el nuevo target — sin emitir ningún reload:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.labels.instance)\t\(.labels.role)"'
   ```

   Esperado:

   ```
   localhost:9100	worker
   localhost:9090	monitoring
   ```

6. Inspeccioná la vista del lado del discovery, que muestra los labels `__meta_*` que file SD adjunta antes del relabeling:

   ```bash
   curl -s localhost:9090/api/v1/targets/metadata >/dev/null   # (metadata endpoint)
   curl -s 'localhost:9090/api/v1/targets?state=active' | \
     jq '.data.activeTargets[] | select(.labels.job=="node") | .discoveredLabels' | head -20
   ```

   Vas a ver labels como `__meta_filepath` que identifican qué archivo produjo el target.

**Preguntas de comprensión**

- **4a.** En el paso 5 el nuevo target fue detectado sin `/-/reload` ni SIGHUP. ¿Qué mecanismo dentro de file SD lo hizo posible, y de qué es red de seguridad `refresh_interval`?
- **4b.** ¿Qué te da operativamente el discovered label `__meta_filepath` cuando estás debuggeando "por qué está este target acá"?
- **4c.** Querés mantener la lista de targets en JSON emitido por un job de CI. ¿`file_sd_configs` soporta eso, y cuál debe ser la extensión del archivo?

---

## Ejercicio 5 — El pipeline de relabeling (`relabel_configs`)

Este es el corazón del tema. `relabel_configs` se ejecuta **después** del service discovery y **antes** del scrape. Puede reescribir la dirección, descartar targets por completo y dar forma a la identidad final `instance`/`job`. Si te equivocás en esto, scrapeás el endpoint equivocado o no almacenás nada.

**Pasos**

1. Agregá relabeling al job `node` para que: (a) conserve solo los targets `worker`, (b) copie el `role` provisto por SD a un label limpio, y (c) reescriba `instance` a un hostname amigable. Reemplazá el cuerpo del job `node` con:

   ```yaml
     - job_name: node
       scrape_interval: 5s
       scrape_timeout: 4s
       file_sd_configs:
         - files: ["targets/*.yml"]
       relabel_configs:
         # 1. Drop any target whose role is not "worker".
         - source_labels: [role]
           regex: worker
           action: keep

         # 2. Build a "host" label from the address, stripping the port.
         - source_labels: [__address__]
           regex: '([^:]+):\d+'
           target_label: host
           replacement: '${1}'

         # 3. Set the final instance label explicitly instead of using __address__.
         - source_labels: [host, env]
           separator: '/'
           target_label: instance
           replacement: '${1}'
   ```

2. Validá y recargá:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   ```

3. Observá el efecto — solo sobrevive el `worker`, e `instance` ya no es `host:port`:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.labels.instance)\t\(.labels.host)\t\(.labels.role)"'
   ```

   Esperado:

   ```
   localhost	localhost	worker
   ```

   El target `localhost:9090`/`monitoring` del Ejercicio 4 desapareció — fue descartado por la acción `keep`.

4. Probá que la dirección de scrape no se ve afectada por la reescritura de `instance`. Aunque `instance=localhost`, el scrape sigue apuntando al puerto 9100:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | .scrapeUrl'
   ```

   Esperado:

   ```
   http://localhost:9100/metrics
   ```

5. Agregá un ejemplo de `labelmap` para auto-promover los meta labels de SD. Agregá a `relabel_configs`:

   ```yaml
         # Promote every __meta_* label into a plain label of the same suffix.
         - action: labelmap
           regex: __meta_(.+)
           replacement: 'sd_${1}'
   ```

   Recargá y confirmá que aparecen labels como `sd_filepath`.

**Preguntas de comprensión**

- **5a.** Después de ejecutarse todo el relabeling, `instance=localhost` pero la URL de scrape sigue apuntando a `:9100`. Explicá el orden exacto de operaciones que hace verdaderas ambas afirmaciones. ¿Qué label especial determina realmente la dirección de scrape?
- **5b.** ¿Cuál es la diferencia de resultado entre `action: keep` y `action: drop` con los *mismos* `source_labels`/`regex`?
- **5c.** Cada target label que definís en relabeling empieza como un label normal — pero toda una clase de labels se elimina justo antes del scrape. ¿Qué labels se remueven, y por qué `__address__` sobrevive lo suficiente para construir la URL pero no aparece en la serie final?
- **5d.** Querés hashear los targets entre dos réplicas para que cada una scrapee la mitad. ¿Qué `action` de relabeling y qué claves de configuración lo implementan, y qué impide que ambas réplicas scrapeen el mismo target?

---

## Ejercicio 6 — `metric_relabel_configs`: dar forma a las muestras, no a los targets

`relabel_configs` actúa sobre *targets* antes del scraping. `metric_relabel_configs` actúa sobre *muestras individuales* después del scraping, justo antes de la ingesta — acá es donde descartás series de alta cardinalidad para proteger tu TSDB.

**Pasos**

1. Primero, medí qué expone realmente el target `node`:

   ```bash
   curl -s localhost:9100/metrics | grep -c '^node_'
   ```

   Anotá el conteo (van a ser varios cientos).

2. Descartá una familia de métricas ruidosa en la ingesta. Agregá al job `node`:

   ```yaml
       metric_relabel_configs:
         # Never store per-CPU scheduler stats — high cardinality, low value here.
         - source_labels: [__name__]
           regex: 'node_scrape_collector_.*'
           action: drop

         # Drop the "mode=idle" time series specifically (keeps other modes).
         - source_labels: [__name__, mode]
           regex: 'node_cpu_seconds_total;idle'
           action: drop
   ```

3. Validá, recargá y confirmá que la serie idle desapareció del almacenamiento pero los otros modos permanecen:

   ```bash
   promtool check config prometheus.yml && curl -s -X POST localhost:9090/-/reload -w '%{http_code}\n'
   sleep 6
   curl -s 'localhost:9090/api/v1/query?query=count(node_cpu_seconds_total)%20by%20(mode)' | \
     jq -r '.data.result[] | "\(.metric.mode)\t\(.value[1])"'
   ```

   Esperado: filas para `user`, `system`, `iowait`, etc. — pero **ninguna** fila `idle`.

4. Confirmá que la exposición cruda todavía contiene `idle` (lo descartaste en el servidor, no en el target):

   ```bash
   curl -s localhost:9100/metrics | grep 'node_cpu_seconds_total{cpu="0",mode="idle"}'
   ```

   Esperado: la línea sigue presente en el exporter. El drop ocurrió dentro de Prometheus.

**Preguntas de comprensión**

- **6a.** Indicá la etapa precisa del ciclo de vida del scrape en la que se ejecuta `metric_relabel_configs`, respecto de `relabel_configs` y del almacenamiento.
- **6b.** En el paso 4 la métrica todavía existe en el exporter pero no en Prometheus. ¿Qué te dice esto sobre *dónde* se reduce y no se reduce el costo de cardinalidad (red vs. TSDB)?
- **6c.** ¿Por qué `__name__` está disponible como valor de `source_labels` en `metric_relabel_configs` pero conceptualmente no tiene sentido en `relabel_configs`?
- **6d.** Un colega agrega una regla `keep` que matchea solo `node_memory_.*` para ahorrar espacio. ¿Cuál es el efecto secundario peligroso de usar `keep` (frente a `drop`s puntuales) en `metric_relabel_configs`?

---

## Ejercicio 7 — `honor_labels`, `honor_timestamps` y colisiones de labels

Cuando un target expone un label que Prometheus también asigna (`job`, `instance`), alguien tiene que perder. `honor_labels` decide quién.

**Pasos**

1. Creá un target chiquito que miente sobre su propio label `job`. Guardá `fake_exporter.txt`:

   ```
   # HELP demo_requests_total A demo counter that ships a job label.
   # TYPE demo_requests_total counter
   demo_requests_total{job="i-set-this-myself"} 42
   ```

   Servilo en el puerto 8000:

   ```bash
   python3 -m http.server 8000 --bind 127.0.0.1 &
   # expose the file at /metrics via a symlink so the path matches
   ln -sf fake_exporter.txt metrics
   ```

   > Para una prueba fiel, apuntá `metrics_path` al archivo servido; lo que importa es la mecánica de la colisión.

2. Agregá un job que lo scrapee con el **valor por defecto** (`honor_labels: false`), agregando a `prometheus.yml`:

   ```yaml
     - job_name: demo
       metrics_path: /metrics
       honor_labels: false
       static_configs:
         - targets: ["localhost:8000"]
   ```

3. Recargá, scrapeá e inspeccioná qué pasó con el label `job` en conflicto:

   ```bash
   curl -s -X POST localhost:9090/-/reload >/dev/null; sleep 3
   curl -s 'localhost:9090/api/v1/query?query=demo_requests_total' | \
     jq '.data.result[0].metric'
   ```

   Esperado (gana el label del servidor; el valor del target se conserva bajo un prefijo):

   ```json
   {
     "__name__": "demo_requests_total",
     "job": "demo",
     "instance": "localhost:8000",
     "exported_job": "i-set-this-myself"
   }
   ```

4. Cambiá a `honor_labels: true`, recargá, volvé a consultar:

   ```json
   {
     "__name__": "demo_requests_total",
     "job": "i-set-this-myself",
     "instance": "localhost:8000"
   }
   ```

**Preguntas de comprensión**

- **7a.** Con `honor_labels: false`, ¿a dónde fue a parar el `job="i-set-this-myself"` del target, y qué valor ganó?
- **7b.** Con `honor_labels: true`, ¿qué pasó con el `job="demo"` asignado por el servidor? Da un escenario real (pista: federación, o un Pushgateway) donde `true` es la opción correcta.
- **7c.** `honor_timestamps` es una perilla aparte. ¿Qué obliga a hacer a Prometheus ponerlo en `false` con cualquier timestamp embebido en el formato de exposición, y por qué lo desactivarías?

---

## Ejercicio 8 — Scheme, path, params y scrapes autenticados

Los targets reales están detrás de HTTPS, paths personalizados, parámetros de query y autenticación. Este ejercicio ensambla toda la superficie de configuración de la request.

**Pasos**

1. Estudiá un job completamente especificado (no lo ejecutes — leé y predecí la URL de scrape resultante):

   ```yaml
     - job_name: secured-app
       scheme: https                 # default is http
       metrics_path: /internal/metrics
       params:
         format: ["prometheus"]      # appended as ?format=prometheus
         module: ["http_2xx"]        # blackbox-style multi param
       basic_auth:
         username: scraper
         password_file: /etc/prometheus/scrape_pw   # file, not inline, so it stays out of the config
       tls_config:
         ca_file: /etc/prometheus/ca.crt
         server_name: app.internal
         insecure_skip_verify: false
       static_configs:
         - targets: ["app.internal:8443"]
   ```

2. Razoná sobre la URL y los headers resultantes antes de validar. La request de scrape es:

   ```
   GET https://app.internal:8443/internal/metrics?format=prometheus&module=http_2xx
   Authorization: Basic <base64(scraper:<contents of scrape_pw>)>
   ```

3. Fijate en los labels internos a los que mapean estas claves (usados en relabeling): `scheme → __scheme__`, `metrics_path → __metrics_path__`, cada param → `__param_<name>`, `targets → __address__`.

4. Validá una versión con un error deliberado — `password` inline **y** `password_file` configurados a la vez — para ver la protección de exclusión mutua:

   ```yaml
       basic_auth:
         username: scraper
         password: hunter2
         password_file: /etc/prometheus/scrape_pw
   ```

   Fallo esperado de `promtool check config`:

   ```
   FAILED: at most one of basic_auth password & password_file must be configured
   ```

**Preguntas de comprensión**

- **8a.** Reconstruí a mano la URL de scrape completa del job `secured-app`, en orden (scheme, host, path, query string).
- **8b.** ¿Qué cuatro labels internos apuntarías en `relabel_configs` si quisieras cambiar este mismo job de HTTPS a HTTP y cambiar su path *dinámicamente* a partir de un meta label de service discovery?
- **8c.** ¿Por qué se prefiere `password_file` a un `password` inline, dado que ambos terminan en memoria de todos modos? Pensá en la configuración dentro de un `ConfigMap` y en `git`.
- **8d.** `insecure_skip_verify: false` con un `server_name` personalizado — ¿qué te permite hacer `server_name` que un target con hostname simple no?

---

## Ejercicio 9 — Leer las métricas de salud del propio scrape

Cada scrape emite métricas sintéticas sobre *sí mismo*. Estas son tu primera parada de diagnóstico cuando un target se porta mal.

**Pasos**

1. Consultá las cuatro métricas sintéticas por scrape principales del job `node`:

   ```bash
   for m in up scrape_duration_seconds scrape_samples_scraped scrape_samples_post_metric_relabeling; do
     echo "== $m =="
     curl -s "localhost:9090/api/v1/query?query=${m}%7Bjob%3D%22node%22%7D" | \
       jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
   done
   ```

   Forma esperada:

   ```
   == up ==
   localhost	1
   == scrape_duration_seconds ==
   localhost	0.0123
   == scrape_samples_scraped ==
   localhost	540
   == scrape_samples_post_metric_relabeling ==
   localhost	450
   ```

2. Compará `scrape_samples_scraped` (540) con `scrape_samples_post_metric_relabeling` (450). La diferencia es exactamente las muestras que removieron tus reglas `drop` del Ejercicio 6.

3. Simulá un target lento/muerto: detené `node_exporter` (Ctrl-C en la tercera terminal), esperá un intervalo de scrape, y volvé a consultar `up`:

   ```bash
   sleep 6
   curl -s 'localhost:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' | jq -r '.data.result[] | .value[1]'
   ```

   Esperado: `0`.

4. Confirmá el string de salud del target y el último error en la API de targets:

   ```bash
   curl -s localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | "\(.health)\t\(.lastError)"'
   ```

   Esperado (ejemplo):

   ```
   down	Get "http://localhost:9100/metrics": dial tcp 127.0.0.1:9100: connect: connection refused
   ```

5. Reiniciá `node_exporter` y confirmá que `up` vuelve a `1` en el próximo scrape.

**Preguntas de comprensión**

- **9a.** `scrape_samples_scraped` fue 540 pero `scrape_samples_post_metric_relabeling` fue 450. ¿Qué bloque de configuración explica la diferencia de 90 muestras, y cuál de los dos números refleja lo que realmente termina en la TSDB?
- **9b.** `up == 0` y `scrape_duration_seconds` se sigue registrando. ¿Cómo puede Prometheus reportar una duración para un scrape que falló?
- **9c.** Ves que `scrape_samples_scraped` sube semana a semana para un job mientras los demás se mantienen planos. ¿Qué señala eso, y cuáles son los dos bloques de configuración que son tus palancas para contenerlo?
- **9d.** Nombrá la métrica sobre la que alertarías para detectar un target que está *up* pero devuelve sospechosamente pocas muestras (un exporter parcial/roto), y explicá por qué `up` por sí sola no lo detectaría.

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas a todas las preguntas de comprensión</summary>

### Ejercicio 1

- **1a.** Cuando no se define un label `instance`, Prometheus asigna automáticamente `instance` al valor del label `__address__` — que viene de la entrada `targets` (`localhost:9090`). Esta asignación ocurre al final de la fase de relabeling. Ver <https://prometheus.io/docs/concepts/jobs_instances/>.
- **1b.** Los valores por defecto son `scheme: http` y `metrics_path: /metrics`. Sobrescribilos con las claves `scheme` y `metrics_path` en el scrape job (mapean a los labels internos `__scheme__` y `__metrics_path__`). Ver <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config>.
- **1c.** `external_labels` **no** se adjuntan a las series almacenadas y no son visibles en las consultas instantáneas contra los datos locales. Se aplican solo a los datos que *salen* del servidor: remote_write, federación y alertas enviadas a Alertmanager. Su propósito es identificar a *este* Prometheus entre muchos (de ahí `cluster`/`replica`). Ver <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#configuration-file>.
- **1d.** `up == 1` prueba únicamente que Prometheus completó con éxito un scrape HTTP del endpoint de métricas del target (2xx, parseable, dentro del timeout). No dice nada sobre si los valores expuestos son correctos, completos o frescos — un exporter roto que devuelve una página vacía-pero-válida igual reporta `up == 1`.

### Ejercicio 2

- **2a.** Un `/-/reload` por HTTP (o SIGHUP) vuelve a leer la configuración y reconcilia los scrape jobs en el lugar: los jobs sin cambios mantienen sus scrape loops y su estado en memoria intactos, así que la cadencia de 15s de `prometheus` nunca se interrumpe. Un reinicio completo del proceso desmonta cada scrape loop, reproduce el WAL y vuelve a ejecutar el service discovery desde cero, causando un hueco en todas las series y un arranque en frío. 
- **2b.** Si un scrape pudiera durar más que el intervalo, se lanzaría un nuevo scrape antes de que terminara el anterior, acumulando requests en vuelo superpuestas contra el target y distorsionando la cadencia de muestras. Exigir `scrape_timeout <= scrape_interval` garantiza como mucho un scrape en vuelo por target a la vez.
- **2c.** `env: dev` bajo `static_configs[].labels` es un **target label**: se adjunta a *cada* serie scrapeada de ese target y se almacena en la TSDB (consultable, parte de la identidad de la serie). Una entrada de `external_labels` se adjunta solo a los datos salientes (remote_write/federación/alertas) y no se almacena localmente. Alcance distinto, ciclo de vida distinto.

### Ejercicio 3

- **3a.** (1) POST HTTP a `/-/reload` — requiere `--web.enable-lifecycle`. (2) `SIGHUP` al proceso — sin requisito previo, siempre disponible. (3) Reinicio completo — sin requisito previo pero pierde el estado. Ver <https://prometheus.io/docs/prometheus/latest/management_api/>.
- **3b.** No se perdió nada. Los reloads de configuración son transaccionales: el nuevo archivo se parsea y valida primero; si falla, se devuelve el error y la **configuración que estaba corriendo antes queda totalmente activa**. El scraping continuó sin interrupción con la configuración vieja.
- **3c.** Dos cualesquiera de: un reinicio reproduce el WAL y recarga el head block desde disco (un reload no lo hace); un reinicio resetea todos los scrape loops y el estado de staleness, creando un hueco de datos; un reinicio vuelve a ejecutar los flags de línea de comandos (un reload no puede cambiar flags — p. ej. `--web.enable-lifecycle`, la retención de almacenamiento y la dirección de escucha son solo por flag y requieren un reinicio para cambiar).
- **3d.** El endpoint HTTP `/-/reload`, típicamente disparado por un sidecar config-reloader que vigila los cambios del `ConfigMap` montado. Es preferible a SIGHUP en Kubernetes porque el sidecar puede alcanzar el endpoint por la red/localhost sin necesidad de compartir un namespace de proceso ni privilegios de `kill` contra el PID del contenedor principal.

### Ejercicio 4

- **4a.** File SD vigila los archivos/directorios referenciados en busca de cambios (vía notificación del sistema de archivos) y aplica los cambios de targets de inmediato, sin reload de configuración. `refresh_interval` (por defecto 5m) es un poll de respaldo que vuelve a leer los archivos periódicamente por si se perdió un evento del sistema de archivos (p. ej. en sistemas de archivos de red o ciertos montajes de contenedores). Ver <https://prometheus.io/docs/guides/file-sd/>.
- **4b.** `__meta_filepath` te dice exactamente qué archivo SD produjo un target dado, así que cuando un target aparece inesperadamente podés rastrearlo hasta el archivo específico (y el sistema que lo escribió) en vez de adivinar.
- **4c.** Sí — file SD soporta `.json`, `.yml` y `.yaml`. La extensión debe ser una de esas; el esquema JSON es una lista de objetos `{ "targets": [...], "labels": {...} }`.

### Ejercicio 5

- **5a.** Orden: SD produce labels (incluyendo `__address__`, `__scheme__`, `__metrics_path__`, `__meta_*`) → `relabel_configs` se ejecutan en secuencia, leyendo/escribiendo libremente cualquier label incluido `instance` → la dirección de scrape se construye a partir del valor **final** de `__address__` (combinado con `__scheme__`, `__metrics_path__`, `__param_*`) → si `instance` no está definido, toma por defecto `__address__` → todos los labels restantes con prefijo `__` se eliminan antes de que el scrape almacene series. Así que reescribir `instance` nunca tocó `__address__`, por eso la URL sigue apuntando a `:9100`. El label `__address__` determina la dirección de scrape. Ver <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config>.
- **5b.** `keep` descarta todo target cuyos `source_labels` concatenados **no** matcheen `regex` (lista blanca). `drop` descarta todo target que **sí** matchee (lista negra). Mismas entradas, sobrevivientes opuestos.
- **5c.** Todos los labels que empiezan con `__` (los labels "internos"/meta: `__address__`, `__scheme__`, `__metrics_path__`, `__meta_*`, `__param_*`, `__tmp_*`) se remueven al final del relabeling, justo antes del scrape. `__address__` sobrevive *a través* de la fase de relabeling porque es cuando se construye la URL de scrape a partir de él; recién después de que la URL se construye y `instance` toma su valor por defecto ocurre la eliminación — así que nunca se convierte en un label almacenado.
- **5d.** `action: hashmod` calcula `mod(hash(source_labels), modulus)` en un `target_label` (p. ej. `__tmp_hash`), seguido de una acción `keep` que matchea solo el número de shard que pertenece a esta réplica. Como ambas réplicas hashean los *mismos* source labels pero cada una conserva un residuo *distinto*, particionan los targets de forma disjunta. Claves: `source_labels`, `modulus`, `target_label` en el paso `hashmod`; `source_labels`+`regex` en el `keep`.

### Ejercicio 6

- **6a.** `metric_relabel_configs` se ejecuta **después** de que el scrape se completa y **después** de `relabel_configs` (que se ejecutó antes del scrape sobre el target), operando sobre cada muestra parseada, y **antes** de que la muestra se escriba en el almacenamiento. Pipeline: SD → relabel_configs → scrape → metric_relabel_configs → TSDB.
- **6b.** El costo de cardinalidad/tráfico en la **red y en el exporter** no cambia — Prometheus igual trajo cada serie por el cable. El ahorro es puramente en la **TSDB** (ingesta, índice, disco, costo de consulta). Para reducir el costo de red/exporter tenés que dejar de exponer la métrica en el origen o usar flags de collector del lado del scrape.
- **6c.** Después de un scrape, cada muestra lleva su nombre de métrica en el label `__name__`, así que `metric_relabel_configs` puede matchearlo. En `relabel_configs` todavía no hay muestras — solo target labels — así que no hay ningún `__name__` para matchear; existe por serie, no por target.
- **6d.** `keep` en `metric_relabel_configs` descarta **todo lo que no matchea**. Así que un `keep` sobre `node_memory_.*` descarta silenciosamente *todas* las demás familias de métricas de ese target — incluyendo las sintéticas adyacentes a `up` y cualquier otra cosa de la que dependas — lo que es un radio de impacto mucho mayor del pretendido. Preferí reglas `drop` explícitas para las pocas familias que querés eliminar.

### Ejercicio 7

- **7a.** Con `honor_labels: false` (por defecto), gana el `job="demo"` asignado por el servidor; el valor `job` en conflicto del propio target se conserva pero se renombra a `exported_job`. No se pierde nada, pero el `job` autoritativo es el de Prometheus.
- **7b.** Con `honor_labels: true`, el servidor no sobrescribe los labels expuestos: el `job="i-set-this-myself"` del target se mantiene como `job`, y el `job="demo"` del servidor se descarta para los nombres en conflicto. Correcto cuando el target es en sí mismo autoritativo sobre la identidad — los casos clásicos son la **federación** (`/federate` re-expone series que ya llevan su verdadero `job`/`instance`) y el **Pushgateway** (las métricas empujadas llevan los labels del job de origen). Ver <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config>.
- **7c.** `honor_timestamps: false` hace que Prometheus **ignore** cualquier timestamp embebido en la exposición y asigne su propio tiempo de scrape a cada muestra. Lo desactivás cuando un target exporta timestamps obsoletos o poco confiables (p. ej. un proxy con caché o un exporter batch) que de otro modo crearían tiempos de muestra fuera de orden o engañosos.

### Ejercicio 8

- **8a.** `https://app.internal:8443/internal/metrics?format=prometheus&module=http_2xx` — scheme `https`, host:port del target, path de `metrics_path`, query string de `params` (el orden de los params dentro del query string no está garantizado pero ambos están presentes).
- **8b.** `__scheme__` (http/https), `__metrics_path__` (el path), `__address__` (host:port) y `__param_<name>` (parámetros de query) — cada uno puede reescribirse en `relabel_configs`, típicamente tomando valores de los labels `__meta_*` producidos por el service discovery.
- **8c.** `password_file` mantiene el secreto fuera del propio documento de configuración, así que un `prometheus.yml` almacenado en un `ConfigMap` o commiteado a `git` nunca contiene la credencial — el archivo se monta por separado (p. ej. desde un `Secret`). Un `password` inline filtraría el secreto al control de versiones y a cualquier cosa que lea el texto de la configuración.
- **8d.** `server_name` establece el valor de SNI y el nombre que se verifica contra el SAN del certificado del servidor, independiente de la dirección que discás. Eso te permite conectarte a un target por IP o por una dirección de load balancer mientras seguís validando el certificado contra su nombre DNS real (en vez de desactivar la verificación). Ver <https://prometheus.io/docs/prometheus/latest/configuration/configuration/#tls_config>.

### Ejercicio 9

- **9a.** `metric_relabel_configs` explica la diferencia (las reglas `drop` del Ejercicio 6 removieron 90 muestras). `scrape_samples_post_metric_relabeling` (450) refleja lo que realmente termina en la TSDB; `scrape_samples_scraped` (540) es el conteo parseado del cable antes del metric relabeling.
- **9b.** `scrape_duration_seconds` mide el tiempo empleado en intentar el scrape — incluyendo una conexión que fue rechazada o que expiró. Un scrape fallido igual consume tiempo de reloj (hasta el timeout), así que se registra una duración incluso cuando `up == 0`.
- **9c.** Un `scrape_samples_scraped` creciente para un job señala **crecimiento de cardinalidad** en ese target (nuevos valores de label / nuevas series). Tus dos palancas de contención son `metric_relabel_configs` (descartar las series ofensoras del lado del servidor, protege la TSDB) e, idealmente, `sample_limit` / cambios del lado del target para dejar de exponerlas (protege también la red). Un `sample_limit` en el scrape job también puede poner un tope duro a la ingesta y hacer fallar el scrape cuando se excede.
- **9d.** Alertá sobre `scrape_samples_post_metric_relabeling` (o `scrape_samples_scraped`) cayendo por debajo de un piso esperado — p. ej. `scrape_samples_post_metric_relabeling{job="node"} < 100`. `up` no lo detectaría porque un target que devuelve una página válida pero casi vacía igual se scrapea con éxito (`up == 1`); solo el conteo de muestras revela los datos faltantes.

</details>

---

**Fuentes**

- Referencia de configuración de Prometheus — <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- Jobs e instancias (auto `instance`, `up` sintético) — <https://prometheus.io/docs/concepts/jobs_instances/>
- API de gestión / lifecycle (`/-/reload`) — <https://prometheus.io/docs/prometheus/latest/management_api/>
- Guía de service discovery basado en archivos — <https://prometheus.io/docs/guides/file-sd/>
- TLS/`tls_config` y configuración web — <https://prometheus.io/docs/prometheus/latest/configuration/https/>
- Currículum de PCA — <https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf>