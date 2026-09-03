# 704.2 — Prometheus Monitoring — Ejercicios guiados

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, v2.0.0
**Peso del objetivo:** 10 (el objetivo individual más pesado del Tema 704)
**Nivel:** producción / avanzado
**Tiempo estimado:** 4–6 horas

---

## Lo que debes ser capaz de hacer al terminar

- Explicar la arquitectura basada en *pull* y cada componente que la integra (server, exporters, Pushgateway, Alertmanager, service discovery, Grafana) y justificar por qué existe cada uno.
- Leer y escribir `prometheus.yml`, incluidos `relabel_configs`, `metric_relabel_configs` y service discovery.
- Distinguir counter / gauge / histogram / summary y elegir correctamente al instrumentar.
- Escribir PromQL que sobreviva a una revisión de producción: ventanas de `rate()` correctas, agregación correcta antes de `histogram_quantile()`, vector matching correcto.
- Escribir recording rules y alerting rules, hacerles tests unitarios con `promtool` y enrutarlas a través de Alertmanager.
- Diagnosticar los cuatro fallos con los que realmente te vas a encontrar: un target que no se deja scrapear, una query que no devuelve nada, una alerta que nunca dispara y una explosión de cardinalidad.

---

## Entorno de laboratorio

Un host Linux con Docker Engine ≥ 24 y el plugin Compose v2. Todo corre en contenedores para que el laboratorio sea reproducible y desechable, pero **cada concepto se traduce 1:1 a binarios bajo systemd** — los archivos de configuración son idénticos.

Versiones contra las que se validó este laboratorio (fíjalas; no uses `:latest` en un laboratorio cuya salida esperada quieras reproducir):

| Componente | Versión | Puerto |
|---|---|---|
| Prometheus server | v3.1.0 | 9090 |
| Alertmanager | v0.28.0 | 9093 |
| node_exporter | v1.8.2 | 9100 |
| Pushgateway | v1.10.0 | 9091 |
| blackbox_exporter | v0.25.0 | 9115 |
| Grafana | 11.5.0 | 3000 |
| app demo (instrumentada, escrita en el Ejercicio 3) | — | 8000 |

> **Nota sobre versiones.** Prometheus 3.0 introdujo cambios de comportamiento que verás en este laboratorio: los selectores de rango ahora son **abiertos por la izquierda** — `[5m]` en el instante de evaluación `t` cubre `(t-5m, t]`, mientras que 2.x usaba `[t-5m, t]` — y la UI web por defecto es la reescrita. Todo lo demás en este documento se comporta igual en 2.53 LTS.

---

## Ejercicio 0 — Levantar el stack y leer la arquitectura directamente del cable

### Pasos

1. Crea el árbol de trabajo:

   ```bash
   mkdir -p ~/prom-lab/{prometheus/{rules,targets},alertmanager,blackbox,grafana/provisioning/datasources,app}
   cd ~/prom-lab
   ```

2. Escribe el primer `prometheus/prometheus.yml`. Léelo antes de pegarlo — cada bloque de abajo es un concepto distinto y relevante para el examen.

   ```yaml
   # prometheus/prometheus.yml
   global:
     scrape_interval:     15s   # how often targets are polled
     scrape_timeout:      10s   # must be < scrape_interval
     evaluation_interval: 15s   # how often recording/alerting rules run
     external_labels:           # attached ONLY on the way out (Alertmanager, remote_write, federation)
       cluster: lab-01
       replica: prom-a

   rule_files:
     - /etc/prometheus/rules/*.yml

   alerting:
     alertmanagers:
       - static_configs:
           - targets: ['alertmanager:9093']

   scrape_configs:
     - job_name: prometheus
       static_configs:
         - targets: ['localhost:9090']

     - job_name: node
       static_configs:
         - targets: ['node-exporter:9100']
   ```

3. Escribe `docker-compose.yml`:

   ```yaml
   # docker-compose.yml
   name: prom-lab

   services:
     prometheus:
       image: quay.io/prometheus/prometheus:v3.1.0
       container_name: prometheus
       command:
         - '--config.file=/etc/prometheus/prometheus.yml'
         - '--storage.tsdb.path=/prometheus'
         - '--storage.tsdb.retention.time=15d'
         - '--web.enable-lifecycle'      # enables POST /-/reload
         - '--web.enable-admin-api'      # enables the delete_series admin endpoint
         - '--log.level=info'
       volumes:
         - ./prometheus:/etc/prometheus:ro
         - prom-data:/prometheus
       ports:
         - '9090:9090'
       restart: unless-stopped

     node-exporter:
       image: quay.io/prometheus/node-exporter:v1.8.2
       container_name: node-exporter
       command:
         - '--path.procfs=/host/proc'
         - '--path.sysfs=/host/sys'
         - '--path.rootfs=/host/root'
         - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
       pid: host
       volumes:
         - /proc:/host/proc:ro
         - /sys:/host/sys:ro
         - /:/host/root:ro,rslave
       ports:
         - '9100:9100'
       restart: unless-stopped

     alertmanager:
       image: quay.io/prometheus/alertmanager:v0.28.0
       container_name: alertmanager
       command:
         - '--config.file=/etc/alertmanager/alertmanager.yml'
         - '--storage.path=/alertmanager'
       volumes:
         - ./alertmanager:/etc/alertmanager:ro
         - am-data:/alertmanager
       ports:
         - '9093:9093'
       restart: unless-stopped

     pushgateway:
       image: quay.io/prometheus/pushgateway:v1.10.0
       container_name: pushgateway
       command:
         - '--persistence.file=/data/pushgateway.store'
         - '--persistence.interval=1m'
       volumes:
         - pg-data:/data
       ports:
         - '9091:9091'
       restart: unless-stopped

     blackbox:
       image: quay.io/prometheus/blackbox-exporter:v0.25.0
       container_name: blackbox
       command:
         - '--config.file=/etc/blackbox/blackbox.yml'
       volumes:
         - ./blackbox:/etc/blackbox:ro
       ports:
         - '9115:9115'
       restart: unless-stopped

     grafana:
       image: docker.io/grafana/grafana:11.5.0
       container_name: grafana
       environment:
         GF_SECURITY_ADMIN_PASSWORD: admin
         GF_USERS_ALLOW_SIGN_UP: 'false'
       volumes:
         - ./grafana/provisioning:/etc/grafana/provisioning:ro
         - grafana-data:/var/lib/grafana
       ports:
         - '3000:3000'
       restart: unless-stopped

   volumes:
     prom-data:
     am-data:
     pg-data:
     grafana-data:
   ```

4. Alertmanager se niega a arrancar sin configuración. Escribe una mínima ahora; la reemplazarás en el Ejercicio 7:

   ```yaml
   # alertmanager/alertmanager.yml
   route:
     receiver: 'null'
   receivers:
     - name: 'null'
   ```

   Y una configuración de blackbox para que ese servicio también arranque:

   ```yaml
   # blackbox/blackbox.yml
   modules:
     http_2xx:
       prober: http
       timeout: 5s
       http:
         valid_http_versions: ['HTTP/1.1', 'HTTP/2.0']
         method: GET
         preferred_ip_protocol: ip4
         follow_redirects: true
   ```

5. Arranca solo lo que existe hasta ahora y verifica:

   ```bash
   docker compose up -d prometheus node-exporter alertmanager pushgateway blackbox
   docker compose ps
   ```

6. Pregúntale a Prometheus cuáles cree que son sus targets — vía la API, no la UI. **La API es lo que puedes automatizar; apréndela primero.**

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
   ```

   Salida esperada:

   ```
   node    http://node-exporter:9100/metrics    up
   prometheus      http://localhost:9090/metrics up
   ```

7. Confirma la configuración en tiempo de ejecución que Prometheus cargó realmente (no el archivo que *crees* que cargó):

   ```bash
   curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head -20
   curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq
   ```

8. Mira el flujo con tus propios ojos: scrapea un target a mano, exactamente como lo hace Prometheus.

   ```bash
   curl -s http://localhost:9100/metrics | head -20
   curl -sI http://localhost:9100/metrics | grep -i content-type
   ```

   `Content-Type` esperado:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

### Preguntas — Bloque 0

1. `node-exporter` no está escuchando en el `localhost` del contenedor de Prometheus y, sin embargo, el job `prometheus` apunta a `localhost:9090` y funciona. ¿Por qué `localhost` resuelve correctamente para un target y no para el otro, y qué pasaría si escribieras `localhost:9100` en el job `node`?
2. `external_labels` define `cluster: lab-01`. Consulta `up` en la UI de Prometheus. ¿Está presente `cluster="lab-01"` en el resultado? Explica con precisión cuándo *sí* se aplican las external labels.
3. `scrape_timeout` es 10s y `scrape_interval` es 15s. ¿Cuál es el modo de fallo si defines `scrape_timeout: 30s`, y qué hace Prometheus al respecto al cargar la configuración?
4. Nada en `prometheus.yml` le dice a node_exporter que envíe datos. Describe la dirección de cada flecha en esta arquitectura (Prometheus ↔ exporter, Prometheus ↔ Alertmanager, job ↔ Pushgateway) y nombra el único componente que invierte el modelo de pull.
5. ¿Qué flag pasaste que hace funcionar `POST /-/reload`, y cuál es la consecuencia de seguridad de habilitarlo en un Prometheus alcanzable desde fuera del host?

---

## Ejercicio 1 — El scrape: formato de exposición, métricas sintéticas y *staleness*

### Pasos

1. Lee una única familia de métricas en formato de exposición crudo:

   ```bash
   curl -s http://localhost:9100/metrics | grep -A3 '^# HELP node_filesystem_avail_bytes'
   ```

   Forma esperada:

   ```
   # HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
   # TYPE node_filesystem_avail_bytes gauge
   node_filesystem_avail_bytes{device="/dev/nvme0n1p3",fstype="ext4",mountpoint="/host/root"} 1.28449536e+11
   ```

2. Pide OpenMetrics en su lugar y compara:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
     http://localhost:9100/metrics | tail -5
   ```

   Fíjate en la línea final `# EOF` — es obligatoria en OpenMetrics y es lo que le permite a un parser detectar una respuesta truncada.

3. Ahora mira lo que Prometheus *agrega* por su cuenta. En la UI (`http://localhost:9090`) o vía la API, ejecuta:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query={__name__=~"up|scrape_.+",job="node"}' \
     | jq -r '.data.result[] | "\(.metric.__name__)\t\(.value[1])"'
   ```

   Salida esperada:

   ```
   scrape_duration_seconds         0.0143921
   scrape_samples_post_metric_relabeling    1284
   scrape_samples_scraped          1284
   scrape_series_added             0
   up                              1
   ```

4. Rompe el target y observa cómo reaccionan las métricas sintéticas:

   ```bash
   docker compose stop node-exporter
   sleep 30
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="node"}' | jq -c '.data.result[].value'
   curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="node") | .lastError'
   ```

   Esperado:

   ```
   ["1756900123.456","0"]
   Get "http://node-exporter:9100/metrics": dial tcp 172.19.0.4:9100: connect: connection refused
   ```

5. Ahora comprueba qué le pasó a `node_filesystem_avail_bytes` durante la caída:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=count(node_filesystem_avail_bytes)' | jq -c '.data.result'
   ```

   Esperado: `[]` — un resultado vacío, **no** el último valor conocido.

6. Reinícialo y confirma la recuperación:

   ```bash
   docker compose start node-exporter
   sleep 30
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="node"}' | jq -c '.data.result[].value'
   ```

### Preguntas — Bloque 1

1. ¿De dónde salieron `up`, `scrape_duration_seconds` y `scrape_samples_scraped`? No están en la salida del exporter — nombra el componente que las crea y explica por qué un exporter nunca debe exponer una métrica llamada `up`.
2. En el paso 5 la query devolvió un resultado vacío de inmediato en lugar del último valor scrapeado. Nombra el mecanismo y explica qué escribe Prometheus en la TSDB cuando una serie desaparece de un scrape.
3. ¿Qué es `query.lookback-delta`, cuál es su valor por defecto y cómo interactúa con un job cuyo `scrape_interval` es `10m`?
4. `scrape_series_added` valía `0` en un target estable. ¿Bajo qué circunstancia esta métrica sería persistentemente distinta de cero, y qué problema de producción indica eso?
5. Un colega propone alertar con `absent(node_filesystem_avail_bytes)` en lugar de `up{job="node"} == 0`. Da un escenario donde solo dispare la primera y otro donde solo dispare la segunda.
6. Dada la línea `# TYPE ... gauge`, ¿almacena Prometheus el tipo en la TSDB? ¿Cuál es la consecuencia práctica cuando después escribes `rate()` sobre un gauge?

---

## Ejercicio 2 — Configuración, `promtool`, recargas, relabeling y service discovery

### Pasos

1. **Nunca reinicies Prometheus para aplicar configuración.** Primero, rompe la configuración a propósito:

   ```bash
   cd ~/prom-lab
   cp prometheus/prometheus.yml /tmp/prometheus.yml.bak
   sed -i 's/scrape_interval:     15s/scrape_interval:     15/' prometheus/prometheus.yml
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```

   Salida esperada (estado de salida distinto de cero):

   ```
   Checking /etc/prometheus/prometheus.yml
     FAILED: parsing YAML file /etc/prometheus/prometheus.yml: unmarshal errors:
       line 3: cannot unmarshal !!int `15` into model.Duration
   ```

2. Restaura y luego convierte el job estático `node` a **service discovery basado en archivos**, que es lo que se usa cuando una CMDB, Ansible o Terraform son dueños del inventario:

   ```bash
   cp /tmp/prometheus.yml.bak prometheus/prometheus.yml
   ```

   ```json
   // prometheus/targets/node.json
   [
     {
       "targets": ["node-exporter:9100"],
       "labels": {
         "env": "lab",
         "role": "compute",
         "datacenter": "dc1"
       }
     }
   ]
   ```

   Reemplaza el job `node` por:

   ```yaml
     - job_name: node
       file_sd_configs:
         - files:
             - /etc/prometheus/targets/*.json
           refresh_interval: 30s
       relabel_configs:
         # Derive a clean `instance` label: strip the port.
         - source_labels: [__address__]
           regex: '([^:]+)(?::\d+)?'
           target_label: instance
           replacement: '${1}'
         # Record which SD file produced this target — invaluable when debugging inventory.
         - source_labels: [__meta_filepath]
           target_label: sd_file
       metric_relabel_configs:
         # Drop a famously high-cardinality, low-value family before it hits the TSDB.
         - source_labels: [__name__]
           regex: 'node_scrape_collector_.*'
           action: drop
   ```

3. Valida y recarga en caliente:

   ```bash
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo "reload ok"
   ```

   Esperado:

   ```
   Checking /etc/prometheus/prometheus.yml
    SUCCESS: 1 rule files found
    ...
   reload ok
   ```

4. Verifica que el relabeling realmente tuvo efecto e inspecciona las labels *descubiertas* antes del relabeling:

   ```bash
   curl -s http://localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | {labels, discoveredLabels}'
   ```

   Esperado (abreviado):

   ```json
   {
     "labels": {
       "datacenter": "dc1",
       "env": "lab",
       "instance": "node-exporter",
       "job": "node",
       "role": "compute",
       "sd_file": "/etc/prometheus/targets/node.json"
     },
     "discoveredLabels": {
       "__address__": "node-exporter:9100",
       "__meta_filepath": "/etc/prometheus/targets/node.json",
       "__metrics_path__": "/metrics",
       "__scheme__": "http",
       "datacenter": "dc1",
       "env": "lab",
       "job": "node",
       "role": "compute"
     }
   }
   ```

5. Demuestra que el file SD es dinámico — no hace falta recargar:

   ```bash
   jq '.[0].labels.role = "compute-a"' prometheus/targets/node.json > /tmp/n.json && mv /tmp/n.json prometheus/targets/node.json
   sleep 35
   curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="node") | .labels.role'
   ```

6. Prueba una regla de relabel de forma aislada, sin tocar el server, usando el comando hermano del linter de configuración:

   ```bash
   docker compose exec prometheus promtool check service-discovery /etc/prometheus/prometheus.yml node
   ```

7. Agrega un segundo job que demuestre `keep` y `labelmap`, además de `honor_labels`:

   ```yaml
     - job_name: pushgateway
       honor_labels: true          # pushed job/instance labels win over the target's
       static_configs:
         - targets: ['pushgateway:9091']
   ```

   Recarga de nuevo.

### Preguntas — Bloque 2

1. `relabel_configs` y `metric_relabel_configs` aparecen ambos en el job `node`. Indica exactamente cuándo corre cada uno, qué entrada recibe cada uno y cuál de los dos puede impedir que un target se scrapee siquiera.
2. `__address__`, `__scheme__`, `__metrics_path__` y `__meta_filepath` empiezan todos con guiones bajos. ¿Qué les pasa a las labels que empiezan con `__` cuando termina el relabeling, y cuál es la excepción que se convierte en una label real por defecto?
3. Quieres repartir 400 targets entre 4 servidores Prometheus sin coordinación central. ¿Qué `action` de relabel hace esto? Escribe la regla para el shard 2 de 4.
4. Con `honor_labels: true` en el job de Pushgateway, ¿qué valor tendrá la label `instance` en una métrica empujada bajo `/metrics/job/backup/instance/db-01`? ¿Cuál sería con `honor_labels: false`?
5. `metric_relabel_configs` descarta `node_scrape_collector_.*`. ¿Reduce esto el número reportado por `scrape_samples_scraped`, por `scrape_samples_post_metric_relabeling`, o por ambos? Explica.
6. ¿Por qué `promtool check config` en un pipeline de CI es estrictamente mejor que `docker compose restart prometheus`, tanto en radio de impacto como en tiempo de detección?

---

## Ejercicio 3 — Tipos de métricas y la decisión de instrumentación

### Pasos

1. Construye una aplicación deliberadamente instrumentada que exponga los cuatro tipos de métricas más una métrica *info*.

   ```python
   # app/app.py
   import random
   import threading
   import time

   from prometheus_client import (
       CollectorRegistry, Counter, Gauge, Histogram, Summary,
       start_http_server,
   )

   REQUESTS = Counter(
       "demo_http_requests_total",
       "Total HTTP requests handled by the demo app.",
       ["method", "path", "status"],
   )
   INFLIGHT = Gauge(
       "demo_http_requests_in_flight",
       "HTTP requests currently being served.",
   )
   LATENCY = Histogram(
       "demo_http_request_duration_seconds",
       "HTTP request latency in seconds.",
       ["path"],
       buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
   )
   PAYLOAD = Summary(
       "demo_http_response_size_bytes",
       "Response body size in bytes.",
       ["path"],
   )
   BUILD = Gauge(
       "demo_build_info",
       "Build metadata; value is always 1, the information is in the labels.",
       ["version", "revision", "goversion"],
   )
   QUEUE = Gauge(
       "demo_work_queue_depth",
       "Items waiting in the background work queue.",
   )

   PATHS = ("/", "/api/orders", "/api/users", "/healthz")


   def serve_one() -> None:
       path = random.choice(PATHS)
       method = "GET" if path != "/api/orders" else random.choice(("GET", "POST"))
       # /api/orders is deliberately slow and occasionally fails.
       if path == "/api/orders":
           duration = random.lognormvariate(-1.2, 0.9)
           status = "500" if random.random() < 0.04 else "200"
       else:
           duration = random.lognormvariate(-3.5, 0.5)
           status = "200"

       INFLIGHT.inc()
       try:
           time.sleep(min(duration, 5.0))
           LATENCY.labels(path=path).observe(duration)
           PAYLOAD.labels(path=path).observe(random.gauss(4096, 900))
           REQUESTS.labels(method=method, path=path, status=status).inc()
       finally:
           INFLIGHT.dec()


   def traffic() -> None:
       while True:
           threading.Thread(target=serve_one, daemon=True).start()
           QUEUE.set(max(0, QUEUE._value.get() + random.randint(-3, 4)))
           time.sleep(random.uniform(0.01, 0.08))


   if __name__ == "__main__":
       BUILD.labels(version="2.4.1", revision="9f3c1ab", goversion="n/a").set(1)
       start_http_server(8000)
       traffic()
   ```

   ```dockerfile
   # app/Dockerfile
   FROM docker.io/library/python:3.12-slim
   RUN pip install --no-cache-dir prometheus_client==0.21.1
   COPY app.py /app/app.py
   EXPOSE 8000
   CMD ["python", "-u", "/app/app.py"]
   ```

2. Agrega el servicio a `docker-compose.yml`:

   ```yaml
     demo-app:
       build: ./app
       container_name: demo-app
       ports:
         - '8000:8000'
       restart: unless-stopped
   ```

   y el job de scrape a `prometheus.yml`:

   ```yaml
     - job_name: demo-app
       static_configs:
         - targets: ['demo-app:8000']
           labels:
             env: lab
             service: orders-api
   ```

3. Levántalo, valida, recarga:

   ```bash
   docker compose up -d --build demo-app
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   sleep 60
   ```

4. Inspecciona cómo se ve realmente cada tipo en el cable:

   ```bash
   curl -s http://localhost:8000/metrics | grep -E '^demo_http_request_duration_seconds' | head -14
   ```

   Esperado:

   ```
   demo_http_request_duration_seconds_bucket{le="0.005",path="/"} 41.0
   demo_http_request_duration_seconds_bucket{le="0.01",path="/"} 233.0
   demo_http_request_duration_seconds_bucket{le="0.025",path="/"} 682.0
   demo_http_request_duration_seconds_bucket{le="0.05",path="/"} 851.0
   demo_http_request_duration_seconds_bucket{le="0.1",path="/"} 884.0
   demo_http_request_duration_seconds_bucket{le="0.25",path="/"} 888.0
   demo_http_request_duration_seconds_bucket{le="0.5",path="/"} 888.0
   demo_http_request_duration_seconds_bucket{le="1.0",path="/"} 888.0
   demo_http_request_duration_seconds_bucket{le="2.5",path="/"} 888.0
   demo_http_request_duration_seconds_bucket{le="5.0",path="/"} 888.0
   demo_http_request_duration_seconds_bucket{le="+Inf",path="/"} 888.0
   demo_http_request_duration_seconds_count{path="/"} 888.0
   demo_http_request_duration_seconds_sum{path="/"} 21.3416...
   ```

   ```bash
   curl -s http://localhost:8000/metrics | grep -E '^demo_http_response_size_bytes' | head -6
   ```

   Esperado:

   ```
   demo_http_response_size_bytes_count{path="/"} 888.0
   demo_http_response_size_bytes_sum{path="/"} 3639296.4...
   ```

5. Cuenta las series temporales que cuesta cada tipo:

   ```bash
   for m in demo_http_requests_total demo_http_requests_in_flight \
            demo_http_request_duration_seconds_bucket demo_http_response_size_bytes_count; do
     printf '%-45s ' "$m"
     curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=count($m)" \
       | jq -r '.data.result[0].value[1] // "0"'
   done
   ```

6. Ahora la lección central de PromQL. Ejecuta estas cuatro queries en la UI y compara los gráficos en un rango de 15 minutos:

   ```promql
   demo_http_requests_total{path="/api/orders"}
   rate(demo_http_requests_total{path="/api/orders"}[5m])
   irate(demo_http_requests_total{path="/api/orders"}[5m])
   increase(demo_http_requests_total{path="/api/orders"}[5m])
   ```

7. Fuerza un reinicio de contador y observa que `rate()` lo maneja:

   ```bash
   docker compose restart demo-app
   ```

   Espera 5 minutos y luego grafica juntos `demo_http_requests_total` en crudo y `rate(demo_http_requests_total[5m])` sobre los últimos 15 minutos.

8. Verifica empíricamente la regla práctica de la ventana de rate:

   ```promql
   rate(demo_http_requests_total{path="/"}[15s])
   rate(demo_http_requests_total{path="/"}[1m])
   rate(demo_http_requests_total{path="/"}[5m])
   ```

### Preguntas — Bloque 3

1. `demo_http_requests_total` es un counter y `demo_work_queue_depth` es un gauge. Da la regla de una frase que decide qué tipo usar, y explica por qué aplicar `rate()` al gauge no tiene sentido.
2. En el paso 4, el histogram tiene 11 series `_bucket` por `path` más `_sum` y `_count`. Calcula el costo total en series de `demo_http_request_duration_seconds` para 4 paths a lo largo de 30 réplicas de la aplicación. Ahora haz lo mismo para `demo_http_response_size_bytes` (un summary sin quantiles configurados). ¿Qué compromiso de cardinalidad acabas de cuantificar?
3. `demo_http_request_duration_seconds_bucket{le="0.05"}` vale `851` mientras que `{le="0.025"}` vale `682`. ¿Estos buckets son acumulativos o disjuntos? ¿Cuántas observaciones cayeron en el intervalo `(0.025, 0.05]`?
4. ¿Por qué no puedes calcular un percentil 99 significativo a lo largo de 30 réplicas a partir de un *summary*, pero sí a partir de un *histogram*? Nombra la propiedad que marca la diferencia.
5. En el paso 6, `increase(...[5m])` devolvió un valor no entero como `1247.83` aunque un counter solo se incrementa en números enteros. Explica el algoritmo que produce esto.
6. Enuncia la regla práctica que relaciona el rango de `rate()` con `scrape_interval`, y describe exactamente qué observaste con `[15s]` en el paso 8 y por qué.
7. Tras el reinicio del paso 7, `rate()` no se disparó a un valor enorme, negativo ni positivo. ¿Qué asume `rate()` cuando la muestra N+1 es menor que la muestra N, y cuál es la única situación en la que esa suposición produce una respuesta equivocada?
8. `demo_build_info` es un gauge cuyo valor siempre es `1`. ¿Cómo se llama este patrón, por qué el valor es irrelevante, y qué saldría mal si en su lugar pusieras `version` como label en `demo_http_requests_total`?
9. `irate()` produjo un gráfico mucho más picudo que `rate()`. Da un uso legítimo de `irate()` y explica por qué nunca debe aparecer en una alerting rule.

---

## Ejercicio 4 — Agregación, vector matching y percentiles correctos

### Pasos

1. Agrega a través de labels. Ejecuta cada una y observa la cardinalidad del resultado:

   ```promql
   sum(rate(demo_http_requests_total[5m]))
   sum by (path) (rate(demo_http_requests_total[5m]))
   sum without (status, method) (rate(demo_http_requests_total[5m]))
   topk(3, sum by (path) (rate(demo_http_requests_total[5m])))
   ```

2. Calcula una ratio de errores — la expresión PromQL más común del mundo real:

   ```promql
   sum by (path) (rate(demo_http_requests_total{status=~"5.."}[5m]))
     /
   sum by (path) (rate(demo_http_requests_total[5m]))
   ```

   Esperado: un valor cercano a `0.04` para `/api/orders` y **ninguna serie** para los demás paths.

3. Corrige el problema de las series faltantes con `or`:

   ```promql
   (
     sum by (path) (rate(demo_http_requests_total{status=~"5.."}[5m]))
     or
     sum by (path) (rate(demo_http_requests_total[5m])) * 0
   )
     /
   sum by (path) (rate(demo_http_requests_total[5m]))
   ```

4. Percentiles — la forma incorrecta y la correcta. Ejecuta ambas:

   ```promql
   # WRONG: quantile of a per-series bucket rate, never aggregated
   histogram_quantile(0.99, rate(demo_http_request_duration_seconds_bucket[5m]))

   # RIGHT: aggregate the bucket rates by `le` first
   histogram_quantile(
     0.99,
     sum by (le) (rate(demo_http_request_duration_seconds_bucket[5m]))
   )

   # RIGHT, per path
   histogram_quantile(
     0.99,
     sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[5m]))
   )
   ```

5. Confirma el efecto de los límites de bucket. El p99 de `/api/orders` debería caer entre dos de los bordes de bucket que configuraste:

   ```bash
   curl -sG http://localhost:9090/api/v1/query --data-urlencode \
     'query=histogram_quantile(0.99, sum by (le,path) (rate(demo_http_request_duration_seconds_bucket[5m])))' \
     | jq -r '.data.result[] | "\(.metric.path)\t\(.value[1])"'
   ```

   Esperado (los valores diferirán):

   ```
   /               0.02478...
   /api/orders     1.9147...
   /api/users      0.02391...
   /healthz        0.02402...
   ```

6. Calcula la latencia *promedio*, que no necesita buckets en absoluto:

   ```promql
   sum by (path) (rate(demo_http_request_duration_seconds_sum[5m]))
     /
   sum by (path) (rate(demo_http_request_duration_seconds_count[5m]))
   ```

7. Vector matching con una métrica info — adjunta la versión de build a un rate:

   ```promql
   sum by (instance) (rate(demo_http_requests_total[5m]))
     * on (instance) group_left(version)
   demo_build_info
   ```

8. Provoca deliberadamente un error de matching para aprender el mensaje:

   ```promql
   rate(demo_http_requests_total[5m]) / demo_build_info
   ```

   Error esperado:

   ```
   found duplicate series for the match group {instance="demo-app:8000", job="demo-app", ...}
   on the right hand-side of the operation: ...
   many-to-many matching not allowed: matching labels must be unique on one side
   ```

   (Si `demo_build_info` tiene una sola serie, en su lugar obtendrás un resultado vacío — porque los conjuntos de labels no coinciden. Arréglalo con `on (instance)`.)

9. Predice el futuro, una técnica que reutilizarás en el Ejercicio 6:

   ```promql
   predict_linear(node_filesystem_avail_bytes{mountpoint="/host/root"}[6h], 24 * 3600)
   ```

### Preguntas — Bloque 4

1. `sum by (path)` y `sum without (status, method)` dieron conjuntos de labels distintos en la salida. ¿Cuál preserva `job` e `instance`, y por qué importa eso cuando el resultado alimenta una alerting rule cuya anotación referencia `{{ $labels.instance }}`?
2. En el paso 2 la ratio no produjo ninguna serie para `/healthz`. Explica la regla de vector matching que causó esto, y luego explica en una frase por qué el idiom `or ... * 0` del paso 3 lo arregla.
3. ¿Por qué `histogram_quantile(0.99, rate(..._bucket[5m]))` sin agregación es incorrecto incluso en una *sola* réplica cuando la métrica tiene una label `path`? ¿Qué exige la función de su vector de entrada?
4. `avg(histogram_quantile(0.99, ...))` entre instancias es un rechazo clásico en revisión. Enuncia la razón matemática por la que los percentiles no son promediables.
5. Tu p99 para `/api/orders` volvió como aproximadamente `1.91`, y tus bordes de bucket son `1.0` y `2.5`. ¿De dónde sale exactamente ese número? ¿Qué devolvería `histogram_quantile` si el percentil 99 cayera en el bucket `+Inf`?
6. En el paso 6 calculaste una latencia media a partir de `_sum / _count`. Da una pregunta de producción que la media responde mejor que el p99, y otra donde la media miente activamente.
7. En el paso 7, explica cada una de las tres partes: `on (instance)`, `group_left` y `(version)`. ¿Qué cambia si escribes `group_right` en su lugar?
8. `predict_linear(...[6h], 24 * 3600)` devuelve bytes. ¿Qué modelo ajusta, y nombra un comportamiento de sistemas de archivos que hace que su salida sea gravemente incorrecta?

---

## Ejercicio 5 — Recording rules y tests unitarios con `promtool`

### Pasos

1. Escribe recording rules usando la nomenclatura convencional `level:metric:operations`:

   ```yaml
   # prometheus/rules/recording.yml
   groups:
     - name: demo-app.recording
       interval: 15s
       limit: 500                      # hard cap on series produced by this group
       rules:
         - record: path:demo_http_requests:rate5m
           expr: sum by (path, job, service) (rate(demo_http_requests_total[5m]))

         - record: path:demo_http_requests_errors:rate5m
           expr: |
             sum by (path, job, service) (
               rate(demo_http_requests_total{status=~"5.."}[5m])
             )
             or
             path:demo_http_requests:rate5m * 0

         - record: path:demo_http_requests_errors:ratio5m
           expr: >-
             path:demo_http_requests_errors:rate5m
               /
             path:demo_http_requests:rate5m

         - record: path:demo_http_request_duration_seconds:p99_5m
           expr: |
             histogram_quantile(
               0.99,
               sum by (le, path, job, service) (
                 rate(demo_http_request_duration_seconds_bucket[5m])
               )
             )
   ```

2. Analiza el archivo de reglas con el linter y luego recarga:

   ```bash
   docker compose exec prometheus promtool check rules /etc/prometheus/rules/recording.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   ```

   Esperado:

   ```
   Checking /etc/prometheus/rules/recording.yml
     SUCCESS: 4 rules found
   ```

3. Verifica que las reglas se están evaluando, y con qué rapidez:

   ```bash
   curl -s http://localhost:9090/api/v1/rules | jq -r \
     '.data.groups[] | .name as $g | .rules[] | [$g, .name, .health, (.evaluationTime|tostring)] | @tsv'
   ```

   Esperado:

   ```
   demo-app.recording  path:demo_http_requests:rate5m           ok  0.001842
   demo-app.recording  path:demo_http_requests_errors:rate5m    ok  0.002104
   demo-app.recording  path:demo_http_requests_errors:ratio5m   ok  0.000391
   demo-app.recording  path:demo_http_request_duration_seconds:p99_5m  ok  0.003118
   ```

4. Demuestra que las reglas dentro de un grupo se evalúan **en orden**: `path:demo_http_requests_errors:rate5m` referencia a la regla declarada encima. Consúltala:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=path:demo_http_requests_errors:ratio5m' \
     | jq -r '.data.result[] | "\(.metric.path)\t\(.value[1])"'
   ```

5. Ahora haz tests unitarios de las reglas **sin Prometheus corriendo y sin datos reales**. Esta es la parte que la mayoría de los ingenieros nunca aprende y que todo repositorio de producción debería tener.

   ```yaml
   # prometheus/rules/recording_test.yml
   rule_files:
     - recording.yml

   evaluation_interval: 1m

   tests:
     - interval: 1m
       input_series:
         # 10 req/min total on /api/orders  -> 0 + 10 per minute
         - series: 'demo_http_requests_total{job="demo-app",service="orders-api",path="/api/orders",method="GET",status="200"}'
           values: '0+570x10'
         - series: 'demo_http_requests_total{job="demo-app",service="orders-api",path="/api/orders",method="GET",status="500"}'
           values: '0+30x10'
         # A path with zero errors, to exercise the `or ... * 0` branch.
         - series: 'demo_http_requests_total{job="demo-app",service="orders-api",path="/healthz",method="GET",status="200"}'
           values: '0+600x10'

       promql_expr_test:
         - expr: path:demo_http_requests:rate5m
           eval_time: 10m
           exp_samples:
             - labels: 'path:demo_http_requests:rate5m{job="demo-app",path="/api/orders",service="orders-api"}'
               value: 10
             - labels: 'path:demo_http_requests:rate5m{job="demo-app",path="/healthz",service="orders-api"}'
               value: 10

         - expr: path:demo_http_requests_errors:ratio5m
           eval_time: 10m
           exp_samples:
             - labels: 'path:demo_http_requests_errors:ratio5m{job="demo-app",path="/api/orders",service="orders-api"}'
               value: 0.05
             - labels: 'path:demo_http_requests_errors:ratio5m{job="demo-app",path="/healthz",service="orders-api"}'
               value: 0
   ```

6. Ejecuta los tests:

   ```bash
   docker compose exec -w /etc/prometheus/rules prometheus \
     promtool test rules recording_test.yml
   ```

   Esperado:

   ```
   Unit Testing:  recording_test.yml
     SUCCESS
   ```

7. Rómpelo a propósito para ver un informe de fallo — cambia `value: 0.05` por `value: 0.5` y vuelve a ejecutar:

   ```
   Unit Testing:  recording_test.yml
     FAILED:
       expr: "path:demo_http_requests_errors:ratio5m", time: 10m0s,
           exp: {job="demo-app", path="/api/orders", service="orders-api"} 0.5,
           got: {job="demo-app", path="/api/orders", service="orders-api"} 0.05
   ```

   Restáuralo.

8. Mide lo que te compraron las recording rules. Compara el costo de query antes y después:

   ```bash
   time curl -sG http://localhost:9090/api/v1/query_range \
     --data-urlencode 'query=histogram_quantile(0.99, sum by (le,path) (rate(demo_http_request_duration_seconds_bucket[5m])))' \
     --data-urlencode "start=$(date -d '-6 hours' +%s)" \
     --data-urlencode "end=$(date +%s)" --data-urlencode 'step=15' > /dev/null

   time curl -sG http://localhost:9090/api/v1/query_range \
     --data-urlencode 'query=path:demo_http_request_duration_seconds:p99_5m' \
     --data-urlencode "start=$(date -d '-6 hours' +%s)" \
     --data-urlencode "end=$(date +%s)" --data-urlencode 'step=15' > /dev/null
   ```

### Preguntas — Bloque 5

1. `path:demo_http_requests_errors:rate5m` usa la salida de una regla declarada antes en el mismo grupo. ¿Es seguro? Enuncia la regla sobre el orden de evaluación *dentro* de un grupo frente a *entre* grupos, y qué pasaría si las dos reglas estuvieran en grupos distintos.
2. El grupo define `interval: 15s` y las expresiones usan `[5m]`. ¿Qué relación deben satisfacer esos dos números, y qué se rompe si `interval` es `10m` mientras el rango es `[5m]`?
3. Explica la convención de nombres `path:demo_http_requests_errors:ratio5m` — qué significa cada una de las tres partes separadas por dos puntos, y por qué la convención prohíbe los dos puntos en el nombre de una métrica instrumentada directamente.
4. En el test unitario, `values: '0+570x10'` se expande a una serie de muestras concreta. Escribe los primeros cuatro valores y explica por qué el `rate` resultante es exactamente `10`.
5. ¿Por qué `rule_files` en el archivo de test debe ser una ruta *relativa*, y por qué el comando usó `-w /etc/prometheus/rules`?
6. El grupo tiene `limit: 500`. ¿Qué hace Prometheus cuando una regla de ese grupo produciría 501 series, y en qué se convierte el campo `health` de la regla?
7. El `evaluation_time` de la regla p99 fue de ~3 ms en este laboratorio. En un servidor real puede llegar a segundos. Nombra las dos métricas sobre las que alertarías para detectar que la evaluación de reglas se está atrasando.
8. Las recording rules aceleran los dashboards. Nombra lo único que no pueden hacer y sí puede hacer una consulta a los buckets crudos — es decir, ¿qué renunciaste permanentemente al preagregar y eliminar la dimensión `le`?

---

## Ejercicio 6 — Alerting rules: el ciclo de vida de `expr` a `firing`

### Pasos

1. Escribe alerting rules que ejerciten cada parte del ciclo de vida:

   ```yaml
   # prometheus/rules/alerts.yml
   groups:
     - name: availability.rules
       interval: 15s
       rules:
         - alert: TargetDown
           expr: up == 0
           for: 2m
           labels:
             severity: critical
           annotations:
             summary: 'Target {{ $labels.instance }} ({{ $labels.job }}) is down'
             description: >-
               Prometheus has been unable to scrape {{ $labels.instance }}
               for more than 2 minutes. Last value of up is {{ $value }}.
             runbook_url: 'https://runbooks.example.com/TargetDown'

         - alert: DemoAppMetricsAbsent
           expr: absent(demo_http_requests_total)
           for: 5m
           labels:
             severity: critical
           annotations:
             summary: 'demo_http_requests_total has disappeared entirely'

     - name: slo.rules
       interval: 15s
       rules:
         - alert: HighErrorRate
           expr: path:demo_http_requests_errors:ratio5m > 0.02
           for: 3m
           keep_firing_for: 5m
           labels:
             severity: warning
             team: orders
           annotations:
             summary: '{{ $labels.path }} error ratio is {{ $value | humanizePercentage }}'
             description: >-
               Error ratio on {{ $labels.path }} ({{ $labels.service }}) has been
               above 2% for 3 minutes. Current value: {{ $value | humanizePercentage }}.

         - alert: HighLatencyP99
           expr: path:demo_http_request_duration_seconds:p99_5m > 1
           for: 5m
           labels:
             severity: warning
             team: orders
           annotations:
             summary: 'p99 latency on {{ $labels.path }} is {{ $value | humanizeDuration }}'

     - name: capacity.rules
       interval: 1m
       rules:
         - alert: NodeFilesystemWillFillIn24h
           expr: |
             (
               node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}
                 / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}
               < 0.20
             )
             and
             (
               predict_linear(
                 node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}[6h],
                 24 * 3600
               ) < 0
             )
           for: 30m
           labels:
             severity: warning
           annotations:
             summary: '{{ $labels.mountpoint }} on {{ $labels.instance }} fills within 24h'
   ```

2. Pasa el linter y recarga:

   ```bash
   docker compose exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   ```

3. Observa el ciclo de vida. `HighErrorRate` ya debería estar en `firing` (la app produce ~4% de errores en `/api/orders`):

   ```bash
   curl -s http://localhost:9090/api/v1/alerts | jq -r \
     '.data.alerts[] | [.labels.alertname, .state, .labels.severity, (.value|tostring)] | @tsv'
   ```

   Esperado:

   ```
   HighErrorRate   firing  warning 0.0413...
   ```

4. Ahora observa `pending` con tus propios ojos. Detén un target y consulta cada 20 segundos:

   ```bash
   docker compose stop node-exporter
   for i in $(seq 1 9); do
     date +%T
     curl -s http://localhost:9090/api/v1/alerts | jq -r \
       '.data.alerts[] | select(.labels.alertname=="TargetDown") | "\(.state)\t\(.activeAt)"'
     sleep 20
   done
   ```

   Esperado: `pending` durante ~2 minutos, luego `firing`.

5. Observa el estado de la alerta como serie temporal consultable:

   ```promql
   ALERTS{alertname="TargetDown"}
   ALERTS_FOR_STATE{alertname="TargetDown"}
   ```

6. Reinicia el target y observa `keep_firing_for` en la *otra* alerta, estrangulando en su lugar la app demo:

   ```bash
   docker compose start node-exporter
   ```

7. Verifica el renderizado de las plantillas sin esperar a una notificación:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | .annotations.summary'
   ```

   Esperado:

   ```
   /api/orders error ratio is 4.13%
   ```

8. Haz un test unitario de una alerting rule — el ciclo de vida, no solo la expresión:

   ```yaml
   # prometheus/rules/alerts_test.yml
   rule_files:
     - recording.yml
     - alerts.yml

   evaluation_interval: 1m

   tests:
     - interval: 1m
       input_series:
         - series: 'up{job="node",instance="node-exporter"}'
           values: '1 1 1 0 0 0 0 0 1 1'

       alert_rule_test:
         # At 4m the target has been down 1m -> pending, not firing.
         - eval_time: 4m
           alertname: TargetDown
           exp_alerts:
             - exp_labels:
                 severity: critical
                 job: node
                 instance: node-exporter
               exp_annotations:
                 summary: 'Target node-exporter (node) is down'
                 description: 'Prometheus has been unable to scrape node-exporter for more than 2 minutes. Last value of up is 0.'
                 runbook_url: 'https://runbooks.example.com/TargetDown'

         # At 9m the target is back up -> no alerts at all.
         - eval_time: 9m
           alertname: TargetDown
           exp_alerts: []
   ```

   ```bash
   docker compose exec -w /etc/prometheus/rules prometheus promtool test rules alerts_test.yml
   ```

### Preguntas — Bloque 6

1. Dibuja los tres estados de una alerta y nombra la condición exacta que la mueve entre cada par. ¿Dónde actúa `for` y dónde actúa `keep_firing_for`?
2. En el paso 8, se esperaba que `eval_time: 4m` con `up` yendo a 0 en el minuto 3 produjera una alerta. ¿Esa alerta estaba en `pending` o en `firing`? ¿Distingue `exp_alerts` de `alert_rule_test` entre ambos, y cómo se hace una aserción específicamente sobre `pending`?
3. `TargetDown` usa `up == 0`. Explica por qué `absent(up)` sería una alerta *diferente* y en general inútil, y da el único caso en que una alerta basada en `absent()` es lo único que funciona.
4. `HighErrorRate` tiene `keep_firing_for: 5m`. Describe un escenario concreto de *flapping* que esto previene y qué experimentaría el ingeniero de guardia sin ello.
5. En `NodeFilesystemWillFillIn24h`, ¿por qué las dos condiciones se unen con `and` en lugar de multiplicarse o escribirse como una única comparación? ¿Qué le hace `and` a los conjuntos de labels de los dos operandos?
6. `{{ $value }}` renderiza `0.0413` y `{{ $value | humanizePercentage }}` renderiza `4.13%`. ¿Dónde se evalúa esta plantilla — en Prometheus o en Alertmanager — y cuál es la consecuencia práctica para la disponibilidad de `$labels` en las plantillas de Alertmanager?
7. El grupo `capacity.rules` tiene `interval: 1m` mientras que `slo.rules` tiene `15s`. Da dos razones independientes para ralentizar el intervalo de evaluación de un grupo.
8. Una alerta tiene `for: 2m` y el `interval` del grupo es `5m`. ¿Cuánto puede tardar realmente entre que la condición se vuelve verdadera y la alerta dispara? Generaliza la fórmula.

---

## Ejercicio 7 — Alertmanager: enrutamiento, agrupación, inhibición, silencios

### Pasos

1. Reemplaza la configuración provisional por una con forma de producción:

   ```yaml
   # alertmanager/alertmanager.yml
   global:
     resolve_timeout: 5m

   templates:
     - '/etc/alertmanager/templates/*.tmpl'

   route:
     receiver: default-webhook
     group_by: ['alertname', 'cluster', 'service']
     group_wait: 30s          # buffer before the FIRST notification for a new group
     group_interval: 5m       # wait before notifying about NEW alerts added to an existing group
     repeat_interval: 4h      # re-notify about unchanged firing alerts

     routes:
       - receiver: critical-webhook
         matchers:
           - severity = "critical"
         group_wait: 10s
         repeat_interval: 1h
         continue: false

       - receiver: orders-webhook
         matchers:
           - team = "orders"
           - severity =~ "warning|info"
         group_by: ['alertname', 'path']

       - receiver: 'null'
         matchers:
           - alertname = "Watchdog"

   inhibit_rules:
     # A down target makes every other alert about that instance noise.
     - source_matchers:
         - alertname = "TargetDown"
       target_matchers:
         - severity =~ "warning|info"
       equal: ['instance']

     # A critical alert suppresses the warning-level twin of the same alertname.
     - source_matchers:
         - severity = "critical"
       target_matchers:
         - severity = "warning"
       equal: ['alertname', 'cluster', 'service']

   receivers:
     - name: 'null'

     - name: default-webhook
       webhook_configs:
         - url: 'http://webhook-sink:8080/default'
           send_resolved: true

     - name: critical-webhook
       webhook_configs:
         - url: 'http://webhook-sink:8080/critical'
           send_resolved: true

     - name: orders-webhook
       webhook_configs:
         - url: 'http://webhook-sink:8080/orders'
           send_resolved: true
   ```

2. Agrega un receptor para poder ver realmente los payloads:

   ```yaml
     webhook-sink:
       image: docker.io/mendhak/http-https-echo:34
       container_name: webhook-sink
       environment:
         HTTP_PORT: '8080'
       ports:
         - '8080:8080'
       restart: unless-stopped
   ```

3. Valida y recarga Alertmanager (también soporta `POST /-/reload` y `SIGHUP`):

   ```bash
   docker compose up -d webhook-sink
   docker compose exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
   curl -sf -X POST http://localhost:9093/-/reload && echo ok
   ```

   Esperado:

   ```
   Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
   Found:
    - global config
    - route
    - 2 inhibit rules
    - 4 receivers
    - 0 templates
   ```

4. **Prueba el árbol de enrutamiento sin generar una sola alerta** — esta es la habilidad de Alertmanager con mayor retorno:

   ```bash
   docker compose exec alertmanager amtool config routes test \
     --config.file=/etc/alertmanager/alertmanager.yml \
     alertname=HighErrorRate severity=warning team=orders

   docker compose exec alertmanager amtool config routes test \
     --config.file=/etc/alertmanager/alertmanager.yml \
     alertname=TargetDown severity=critical

   docker compose exec alertmanager amtool config routes test \
     --config.file=/etc/alertmanager/alertmanager.yml \
     alertname=SomethingElse severity=warning
   ```

   Esperado:

   ```
   orders-webhook
   critical-webhook
   default-webhook
   ```

5. Visualiza el árbol completo:

   ```bash
   docker compose exec alertmanager amtool config routes show \
     --config.file=/etc/alertmanager/alertmanager.yml
   ```

6. Inyecta una alerta sintética directamente en la API de Alertmanager — sin Prometheus de por medio:

   ```bash
   curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
     {
       "labels": {
         "alertname": "SyntheticPage",
         "severity": "critical",
         "cluster": "lab-01",
         "service": "orders-api",
         "instance": "demo-app:8000"
       },
       "annotations": {"summary": "Injected by hand to test routing"},
       "generatorURL": "http://localhost:9090/graph"
     }
   ]'

   docker compose exec alertmanager amtool alert query --alertmanager.url=http://localhost:9093
   docker compose logs --tail=40 webhook-sink | grep -i '"path"'
   ```

7. Siléncialaa y luego verifica que el silencio coincidió:

   ```bash
   docker compose exec alertmanager amtool silence add \
     --alertmanager.url=http://localhost:9093 \
     --duration=1h --comment='Planned maintenance, ticket OPS-4412' \
     alertname=SyntheticPage cluster=lab-01

   docker compose exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093
   docker compose exec alertmanager amtool alert query --alertmanager.url=http://localhost:9093 --silenced
   ```

8. Verifica que Prometheus sabe adónde enviar las alertas:

   ```bash
   curl -s http://localhost:9090/api/v1/alertmanagers | jq
   ```

   Esperado:

   ```json
   {
     "status": "success",
     "data": {
       "activeAlertmanagers": [{"url": "http://alertmanager:9093/api/v2/alerts"}],
       "droppedAlertmanagers": []
     }
   }
   ```

9. Inspecciona un payload de notificación real y encuentra las `external_labels` del Ejercicio 0:

   ```bash
   docker compose logs webhook-sink | grep -o '"cluster":"[^"]*"' | tail -3
   ```

### Preguntas — Bloque 7

1. Explica `group_wait`, `group_interval` y `repeat_interval` en términos de la *primera* notificación, la notificación *modificada* y el *recordatorio*. ¿Cuál acortarías para reducir el tiempo hasta el aviso, y cuál alargarías para reducir la fatiga de alertas?
2. `group_by: ['alertname', 'cluster', 'service']` — ¿qué pasa operativamente si defines `group_by: ['...']` (el comodín especial), frente a omitir `group_by` por completo, frente a `group_by: []`?
3. La ruta `critical` define `continue: false` (el valor por defecto). Traza qué le pasa a una alerta con `severity="critical", team="orders"`: qué receptores la reciben, y cómo cambia la respuesta con `continue: true`.
4. Enuncia los tres componentes de una regla de inhibición y explica con precisión qué garantiza `equal: ['instance']`. ¿Qué error catastrófico cometes si omites `equal` en la primera regla de inhibición?
5. Un silencio y una inhibición ambos suprimen una notificación. Nombra dos diferencias operativas entre ellos (quién los crea, cuánto duran, qué aparece en la UI).
6. En el paso 9 el payload contenía `cluster: lab-01`, que configuraste en el Ejercicio 0 bajo `external_labels`. ¿Qué componente lo adjuntó, en qué momento, y por qué `replica: prom-a` es un problema para la agrupación cuando corres dos servidores Prometheus idénticos?
7. `resolve_timeout: 5m` es un parámetro global. ¿A qué alertas se aplica — a las enviadas por Prometheus o a las empujadas vía la API — y por qué?
8. Te avisan a las 03:00 por una alerta cuya anotación `runbook_url` falta. Nombra las dos superficies de configuración (una en Prometheus, otra en Alertmanager) donde ese campo debería haberse exigido o renderizado.

---

## Ejercicio 8 — Exporters multi-target y el Pushgateway

### Pasos

1. Agrega el blackbox exporter como job de scrape **multi-target**. Lee la cadena de relabel con atención — este patrón aparece en el examen y en todo despliegue real:

   ```yaml
     - job_name: blackbox-http
       metrics_path: /probe
       params:
         module: [http_2xx]
       static_configs:
         - targets:
             - http://demo-app:8000/metrics
             - http://prometheus:9090/-/healthy
             - http://does-not-exist.invalid/
       relabel_configs:
         # 1. The SD target becomes the ?target= query parameter.
         - source_labels: [__address__]
           target_label: __param_target
         # 2. The probed URL becomes the human-readable `instance`.
         - source_labels: [__param_target]
           target_label: instance
         # 3. The address Prometheus actually connects to is the EXPORTER.
         - target_label: __address__
           replacement: blackbox:9115
   ```

2. Recarga e inspecciona:

   ```bash
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   sleep 20
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=probe_success' \
     | jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
   ```

   Esperado:

   ```
   http://demo-app:8000/metrics    1
   http://does-not-exist.invalid/  0
   http://prometheus:9090/-/healthy        1
   ```

3. Reproduce el sondeo a mano — exactamente lo que hizo Prometheus:

   ```bash
   curl -s 'http://localhost:9115/probe?module=http_2xx&target=http://demo-app:8000/metrics&debug=true' | head -40
   ```

4. Ahora el Pushgateway. Empuja el resultado de un batch job:

   ```bash
   cat <<EOF | curl --data-binary @- http://localhost:9091/metrics/job/nightly_backup/instance/db-01
   # HELP backup_last_success_timestamp_seconds Unix time of the last successful backup.
   # TYPE backup_last_success_timestamp_seconds gauge
   backup_last_success_timestamp_seconds $(date +%s)
   # HELP backup_duration_seconds Wall-clock duration of the backup run.
   # TYPE backup_duration_seconds gauge
   backup_duration_seconds 412.7
   # HELP backup_size_bytes Size of the resulting archive.
   # TYPE backup_size_bytes gauge
   backup_size_bytes 8293476352
   EOF
   ```

5. Verifica lo que ahora expone el Pushgateway y lo que Prometheus scrapeó:

   ```bash
   curl -s http://localhost:9091/metrics | grep -E '^(backup_|push_)' 
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=backup_duration_seconds' | jq -c '.data.result'
   ```

   Esperado (nota que `job` e `instance` vinieron de la URL del *push*, no del target de scrape):

   ```json
   [{"metric":{"__name__":"backup_duration_seconds","instance":"db-01","job":"nightly_backup"},"value":["1756901234.5","412.7"]}]
   ```

6. Demuestra que el Pushgateway es una **caché, no una cola**. Deja de empujar y observa:

   ```bash
   sleep 120
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=time() - backup_last_success_timestamp_seconds' \
     | jq -r '.data.result[0].value[1]'
   ```

   La métrica sigue ahí y la antigüedad sigue creciendo. Ese es justamente el punto.

7. Escribe la alerta que hace útil a un Pushgateway:

   ```yaml
   # append to prometheus/rules/alerts.yml under a new group
     - name: batch.rules
       interval: 1m
       rules:
         - alert: BackupStale
           expr: time() - backup_last_success_timestamp_seconds > 26 * 3600
           for: 10m
           labels:
             severity: critical
           annotations:
             summary: 'Backup {{ $labels.job }}/{{ $labels.instance }} last succeeded {{ $value | humanizeDuration }} ago'

         - alert: BackupNeverRan
           expr: absent(backup_last_success_timestamp_seconds{job="nightly_backup"})
           for: 30m
           labels:
             severity: critical
           annotations:
             summary: 'No backup metric has ever been pushed for nightly_backup'
   ```

8. Limpia un grupo — la operación que todos olvidan:

   ```bash
   curl -X DELETE http://localhost:9091/metrics/job/nightly_backup/instance/db-01
   curl -s http://localhost:9091/metrics | grep -c '^backup_' || echo "0 (deleted)"
   ```

### Preguntas — Bloque 8

1. En el job `blackbox-http`, `__address__` se reescribe dos veces — una implícitamente como origen de `__param_target`, y otra explícitamente a `blackbox:9115`. Explica qué se rompería si omitieras la regla 3, y qué se rompería si omitieras la regla 2.
2. `probe_success` para `does-not-exist.invalid` es `0`, pero `up` para ese mismo target es `1`. Explica por qué, e indica cuál de los dos debes usar para alertar y detectar un sitio web caído.
3. Nombra la propiedad que convierte a blackbox_exporter en un "exporter multi-target" y da otro exporter del ecosistema que siga el mismo patrón.
4. El paso 5 mostró `job="nightly_backup"` e `instance="db-01"` aunque el target de scrape es `pushgateway:9091`. ¿Qué única opción de configuración lo hizo posible, y cuáles habrían sido las labels sin ella?
5. La documentación de Prometheus dice que el Pushgateway es para batch jobs a *nivel de servicio* y explícitamente no para métricas a nivel de máquina ni como pasarela de push general. Da los tres modos de fallo que justifican esto: qué pasa con `up`, qué pasa cuando el job desaparece y qué pasa con una métrica después de que el job se da de baja.
6. `BackupNeverRan` usa `absent(...)`. ¿Por qué esta alerta nunca puede llevar la label `instance` del backup ausente, y cuál es la solución estándar cuando necesitas alertas de ausencia por instancia?
7. Se configuró `--persistence.file`. ¿Qué se pierde en un reinicio del Pushgateway sin él, y cambia eso la corrección de `BackupStale`?
8. Un desarrollador quiere empujar el contador de peticiones de una aplicación al Pushgateway cada 15 segundos "para que Prometheus no tenga que meterse en nuestra red". Da la respuesta arquitectónica correcta y nombra las dos alternativas soportadas.

---

## Ejercicio 9 — Integración con Grafana

### Pasos

1. Aprovisiona el datasource como código — nunca lo configures a mano en la interfaz:

   ```yaml
   # grafana/provisioning/datasources/prometheus.yml
   apiVersion: 1

   datasources:
     - name: Prometheus
       uid: prom-lab
       type: prometheus
       access: proxy
       url: http://prometheus:9090
       isDefault: true
       editable: false
       jsonData:
         httpMethod: POST
         timeInterval: 15s        # tells Grafana the scrape interval; drives $__rate_interval
         prometheusType: Prometheus
         prometheusVersion: 3.1.0
         incrementalQuerying: true
   ```

2. Arranca Grafana y confirma que el datasource cargó:

   ```bash
   docker compose up -d grafana
   sleep 15
   curl -s -u admin:admin http://localhost:3000/api/datasources | jq -r '.[] | "\(.name)\t\(.type)\t\(.url)"'
   ```

   Esperado:

   ```
   Prometheus      prometheus      http://prometheus:9090
   ```

3. Prueba el datasource de extremo a extremo a través del proxy de Grafana:

   ```bash
   DS_UID=prom-lab
   curl -s -u admin:admin -H 'Content-Type: application/json' \
     "http://localhost:3000/api/datasources/uid/${DS_UID}/resources/api/v1/query?query=up" \
     | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"'
   ```

4. Abre `http://localhost:3000` (admin/admin) y construye un panel a mano:
   - **Panel A — Tasa de peticiones.** Query: `sum by (path) (rate(demo_http_requests_total[$__rate_interval]))`, leyenda `{{path}}`, unidad `reqps`.
   - **Panel B — Ratio de errores.** Query: `path:demo_http_requests_errors:ratio5m`, unidad `percentunit`, umbrales en `0.02` (amarillo) y `0.05` (rojo).
   - **Panel C — Mapa de latencia.** Tres queries con leyendas `p50 {{path}}`, `p90 {{path}}`, `p99 {{path}}`:
     ```promql
     histogram_quantile(0.50, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     histogram_quantile(0.90, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     histogram_quantile(0.99, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     ```
   - **Panel D — Salud de targets.** Query `up`, visualización *Stat*, mapeos de valores `0 → DOWN (red)`, `1 → UP (green)`.

5. Agrega una variable de plantilla para que el dashboard funcione con cualquier path. Dashboard settings → Variables → New:
   - Nombre `path`, Tipo *Query*, Datasource `Prometheus`
   - Query type *Label values*, Label `path`, Metric `demo_http_requests_total`
   - Habilita *Multi-value* e *Include All option*

   Luego cambia la query del Panel A a:

   ```promql
   sum by (path) (rate(demo_http_requests_total{path=~"$path"}[$__rate_interval]))
   ```

6. Compara directamente las variables de intervalo. Crea un panel de texto/stat con cada una de estas y cambia el rango temporal del dashboard de *last 1 hour* a *last 7 days*:

   ```promql
   rate(demo_http_requests_total{path="/"}[$__interval])
   rate(demo_http_requests_total{path="/"}[$__rate_interval])
   rate(demo_http_requests_total{path="/"}[5m])
   ```

7. Exporta el dashboard como JSON y súbelo al repositorio:

   ```bash
   curl -s -u admin:admin http://localhost:3000/api/search?query= | jq -r '.[] | .uid'
   curl -s -u admin:admin http://localhost:3000/api/dashboards/uid/<UID> \
     | jq '.dashboard' > grafana/dashboards/demo-app.json
   ```

### Preguntas — Bloque 9

1. `access: proxy` frente a `access: direct` (navegador). ¿Cuál configuraste, y cuáles son las dos razones por las que `proxy` es correcto para un Prometheus que no está expuesto a internet?
2. `timeInterval: 15s` está definido en el datasource. ¿Qué variable de Grafana alimenta, y cuál es la fórmula que usa Grafana para calcular `$__rate_interval` a partir de ella?
3. En el paso 6, `rate(...[$__interval])` se rompió al alejar el zoom a 7 días pero `[$__rate_interval]` no. Explica el fallo con precisión — qué le pasa a `rate()` cuando el rango es menor que el intervalo de scrape frente a cuando es mucho mayor.
4. ¿Por qué el `[5m]` fijo no es ni incorrecto ni ideal? Enuncia el único escenario en el que fijarlo a mano es la elección *correcta*.
5. Está configurado `httpMethod: POST`. ¿Qué límite eleva esto, y cuándo lo alcanzarás por primera vez?
6. Grafana también puede enviar alertas (Grafana Alerting). Da dos razones para mantener las alerting rules en Prometheus y Alertmanager en lugar de en Grafana, en un montaje donde existen ambos.
7. La query de la variable usó *Label values* sobre `path` para la métrica `demo_http_requests_total`. ¿Qué endpoint de la API llama Grafana, y por qué consultar los valores de una label para una métrica es más barato que `count by (path) (demo_http_requests_total)`?
8. El Panel B consulta la recording rule `path:demo_http_requests_errors:ratio5m` mientras que el Panel C consulta buckets crudos. ¿Qué panel sobrevive a un rango temporal de 30 días en un servidor grande, y por qué?

---

## Ejercicio 10 — Diagnóstico en producción: cardinalidad, TSDB y los cuatro fallos clásicos

### Pasos

1. **Inspecciona el bloque head.** Este endpoint responde "¿qué está llenando mi Prometheus?" en una sola llamada:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '{
     headStats: .data.headStats,
     topMetricNames: [.data.seriesCountByMetricName[:5][] | "\(.name)=\(.value)"],
     topLabelPairs: [.data.seriesCountByLabelValuePair[:5][] | "\(.name)=\(.value)"],
     memoryByLabel: [.data.memoryInBytesByLabelName[:5][] | "\(.name)=\(.value)"]
   }'
   ```

   Esperado (abreviado):

   ```json
   {
     "headStats": {
       "numSeries": 2417,
       "numLabelPairs": 3902,
       "chunkCount": 4831,
       "minTime": 1756890000000,
       "maxTime": 1756901234000
     },
     "topMetricNames": [
       "node_cpu_seconds_total=48",
       "demo_http_request_duration_seconds_bucket=44",
       "node_scrape_collector_duration_seconds=42"
     ],
     ...
   }
   ```

2. **Provoca una explosión de cardinalidad a propósito** y luego encuéntrala. Agrega un job malo que se ramifique con una label única por scrape abusando de `params`:

   ```yaml
     - job_name: cardinality-bomb
       metrics_path: /probe
       params:
         module: [http_2xx]
       static_configs:
         - targets:
             - 'http://demo-app:8000/?req=1'
             - 'http://demo-app:8000/?req=2'
             - 'http://demo-app:8000/?req=3'
       relabel_configs:
         - source_labels: [__address__]
           target_label: __param_target
         - source_labels: [__param_target]
           target_label: instance
         - target_label: __address__
           replacement: blackbox:9115
   ```

   En un incidente real el equivalente es un `user_id`, `request_id`, `session_id`, `pod_name` o una ruta URL completa llegando como label.

3. **Defiéndete en el scrape.** Agrega los límites que todo job de producción debería llevar:

   ```yaml
     - job_name: demo-app
       sample_limit: 5000               # fail the scrape entirely above this
       label_limit: 30
       label_name_length_limit: 128
       label_value_length_limit: 512
       static_configs:
         - targets: ['demo-app:8000']
           labels:
             env: lab
             service: orders-api
   ```

   Recarga, luego define `sample_limit: 5` temporalmente y observa:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | select(.labels.job=="demo-app") | "\(.health)\t\(.lastError)"'
   ```

   Esperado:

   ```
   down    sample limit exceeded
   ```

   Restaura `sample_limit: 5000`.

4. **Encuentra la label culpable** con PromQL, sobre una métrica que sospeches:

   ```promql
   # How many series does each metric name have? (expensive — prefer /status/tsdb)
   topk(10, count by (__name__) ({__name__!=""}))

   # Which label is the culprit within one metric family?
   count(count by (path)   (demo_http_requests_total))
   count(count by (status) (demo_http_requests_total))
   count(count by (method) (demo_http_requests_total))
   ```

5. **Analiza la TSDB en disco** sin conexión:

   ```bash
   docker compose exec prometheus promtool tsdb list /prometheus
   docker compose exec prometheus promtool tsdb analyze /prometheus | head -40
   ```

   Esperado (abreviado):

   ```
   Block ID: 01JQ8ZK6R2F5M0V9YB3XT4W7NQ
   Duration: 2h0m0s
   Series: 2417
   Label names: 41
   Postings (unique label pairs): 3902
   Postings entries (total label pairs): 29104

   Highest cardinality labels:
   1284 __name__
    412 le
     97 device
     ...
   Highest cardinality metric names:
    48 node_cpu_seconds_total
    44 demo_http_request_duration_seconds_bucket
   ```

6. **Inspecciona la disposición del almacenamiento** para que el vocabulario de bloques y WAL sea concreto:

   ```bash
   docker compose exec prometheus sh -c 'ls -la /prometheus && ls /prometheus/wal | head'
   ```

   Esperado:

   ```
   drwxr-xr-x  01JQ8ZK6R2F5M0V9YB3XT4W7NQ
   drwxr-xr-x  chunks_head
   drwxr-xr-x  wal
   -rw-r--r--  lock
   -rw-r--r--  queries.active
   00000000
   00000001
   checkpoint.00000000
   ```

7. **Monitorea Prometheus con Prometheus.** Estas son las métricas por las que te llaman de guardia:

   ```promql
   # Head series growth — the leading indicator of a cardinality incident
   prometheus_tsdb_head_series

   # Rule evaluation falling behind
   rate(prometheus_rule_evaluation_failures_total[5m])
   prometheus_rule_group_last_duration_seconds > on (rule_group) prometheus_rule_group_interval_seconds

   # Config reload failed — the silent killer
   prometheus_config_last_reload_successful == 0

   # Scrapes being dropped for exceeding limits
   rate(prometheus_target_scrapes_exceeded_sample_limit_total[5m])

   # Notification delivery to Alertmanager
   rate(prometheus_notifications_errors_total[5m])
   prometheus_notifications_dropped_total
   ```

8. **Los cuatro fallos clásicos.** Para cada uno, ejecuta el diagnóstico y anota la respuesta:

   ```bash
   # (a) Target will not scrape
   curl -s http://localhost:9090/api/v1/targets | jq -r \
     '.data.activeTargets[] | select(.health!="up") | "\(.scrapeUrl)\n  \(.lastError)"'
   curl -s http://localhost:9090/api/v1/targets?state=dropped | jq -r \
     '.data.droppedTargets[]?.discoveredLabels.__address__'

   # (b) Query returns nothing — check the series actually exist, ignoring the value
   curl -sG http://localhost:9090/api/v1/series \
     --data-urlencode 'match[]=demo_http_requests_total' \
     --data-urlencode "start=$(date -d '-1 hour' +%s)" | jq -r '.data[0]'

   # (c) Alert never fires — is the rule healthy, is it pending, what is $value?
   curl -s http://localhost:9090/api/v1/rules?type=alert | jq -r \
     '.data.groups[].rules[] | select(.type=="alerting") | [.name, .state, .health, (.lastError//"-")] | @tsv'

   # (d) Notification never arrives — did Prometheus even send it?
   curl -s http://localhost:9090/api/v1/alertmanagers | jq -r '.data.activeAlertmanagers[].url'
   docker compose exec alertmanager amtool alert query --alertmanager.url=http://localhost:9093
   docker compose exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093
   ```

9. **Borrado quirúrgico** (requiere `--web.enable-admin-api`, que habilitaste en el Ejercicio 0):

   ```bash
   curl -s -X POST -g \
     'http://localhost:9090/api/v1/admin/tsdb/delete_series?match[]={job="cardinality-bomb"}'
   curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones
   ```

10. Desmonta el laboratorio cuando termines:

    ```bash
    docker compose down -v
    ```

### Preguntas — Bloque 10

1. Se superó `sample_limit` y el target quedó `down`. ¿El scrape se ingiere *parcialmente* o se descarta por completo? ¿Cuál es el valor de `up` para ese target, y por qué ese es el comportamiento más seguro posible?
2. Ordena estas cuatro defensas según dónde actúan en el pipeline, de la más temprana a la más tardía: `sample_limit`, `metric_relabel_configs` con `action: drop`, `--storage.tsdb.retention.time`, `label_limit`. ¿Cuáles reducen el costo de *ingestión* y cuáles solo reducen el costo de *almacenamiento*?
3. `topk(10, count by (__name__)({__name__!=""}))` responde la misma pregunta que `/api/v1/status/tsdb`. Da las dos razones para preferir el endpoint de la API en un servidor cargado.
4. Explica qué vive en `wal/`, en `chunks_head/` y en los directorios con nombre ULID. ¿Qué le pasa a cada uno en un reinicio sucio?
5. `prometheus_config_last_reload_successful == 0` se llama "el asesino silencioso". Describe la secuencia exacta del fallo: editas `prometheus.yml`, envías SIGHUP y Prometheus sigue corriendo. ¿Qué está corriendo?
6. En el diagnóstico (b), `/api/v1/series` devolvió un resultado pero la query instantánea no devolvió nada. Nombra dos causas independientes, y la query que ejecutarías para distinguirlas.
7. `prometheus_rule_group_last_duration_seconds > on (rule_group) prometheus_rule_group_interval_seconds` — describe en lenguaje llano qué significa que dispare, y el efecto acumulativo sobre la latencia de las alertas.
8. `delete_series` tuvo éxito pero el uso de disco no bajó. Explica qué son las *tombstones*, qué hace `clean_tombstones`, y por qué el borrado no es la herramienta adecuada para un problema de cardinalidad en primer lugar.
9. Tienes 30 segundos en una llamada de crisis. Un único Prometheus está en 40 M de series activas y lo está matando el OOM killer. Nombra tres acciones en orden de prioridad — una inmediata, una en el siguiente scrape, una arquitectónica.

---

## Fuentes

- LPI — Exam 701 Objectives (DevOps Tools Engineer, v2.0): <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Prometheus — Configuration reference: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- Prometheus — Recording rules: <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus — Alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Prometheus — Querying basics and operators: <https://prometheus.io/docs/prometheus/latest/querying/basics/> · <https://prometheus.io/docs/prometheus/latest/querying/operators/>
- Prometheus — Query functions (`rate`, `irate`, `increase`, `histogram_quantile`, `predict_linear`, `absent`): <https://prometheus.io/docs/prometheus/latest/querying/functions/>
- Prometheus — HTTP API: <https://prometheus.io/docs/prometheus/latest/querying/api/>
- Prometheus — Metric types: <https://prometheus.io/docs/concepts/metric_types/>
- Prometheus — Exposition formats: <https://prometheus.io/docs/instrumenting/exposition_formats/>
- Prometheus — Staleness: <https://prometheus.io/docs/prometheus/latest/querying/basics/#staleness>
- Prometheus — Storage and TSDB: <https://prometheus.io/docs/prometheus/latest/storage/>
- Prometheus — Unit testing rules with `promtool`: <https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/>
- Prometheus — Instrumentation and naming best practices: <https://prometheus.io/docs/practices/instrumentation/> · <https://prometheus.io/docs/practices/naming/>
- Prometheus — Histograms and summaries: <https://prometheus.io/docs/practices/histograms/>
- Prometheus — When to use the Pushgateway: <https://prometheus.io/docs/practices/pushing/>
- Prometheus — Migration guide (2.x → 3.0 behaviour changes): <https://prometheus.io/docs/prometheus/latest/migration/>
- Alertmanager — Configuration: <https://prometheus.io/docs/alerting/latest/configuration/>
- Alertmanager — `amtool` and notification concepts: <https://github.com/prometheus/alertmanager#amtool>
- node_exporter: <https://github.com/prometheus/node_exporter>
- blackbox_exporter (multi-target exporter pattern): <https://github.com/prometheus/blackbox_exporter> · <https://prometheus.io/docs/guides/multi-target-exporter/>
- Pushgateway: <https://github.com/prometheus/pushgateway>
- Grafana — Prometheus data source and `$__rate_interval`: <https://grafana.com/docs/grafana/latest/datasources/prometheus/> · <https://grafana.com/docs/grafana/latest/datasources/prometheus/query-editor/>
- Grafana — Provisioning: <https://grafana.com/docs/grafana/latest/administration/provisioning/>

---

<details>
<summary><strong>Respuestas — clic para desplegar</strong></summary>

## Bloque 0 — Arquitectura

**0.1** `localhost` se resuelve dentro del *namespace de red del contenedor de Prometheus*. Prometheus mismo escucha en `:9090` en ese namespace, así que `localhost:9090` funciona. `node-exporter` corre en un contenedor distinto con un namespace distinto, así que `localhost:9100` dentro del contenedor de Prometheus no encontraría nada y el scrape fallaría con `dial tcp 127.0.0.1:9100: connect: connection refused`. El direccionamiento entre contenedores usa el nombre del servicio de Compose, que el DNS embebido de Docker resuelve. En metal desnudo bajo systemd esta distinción desaparece — ambos procesos comparten un namespace y `localhost:9100` es correcto.

**0.2** No. `cluster="lab-01"` **no** está presente en `up` cuando se consulta localmente. Las `external_labels` se aplican únicamente a los datos que salen de este servidor: alertas enviadas a Alertmanager, `remote_write` y `/federate`. Su propósito es identificar *qué* Prometheus produjo un dato una vez que se agrupan los datos de varios servidores. Aplicarlas localmente sería redundante y rompería la identidad entre la expresión de una regla y la serie que almacena.

**0.3** `scrape_timeout` debe ser menor o igual que `scrape_interval`. Si es mayor, un target lento puede seguir en vuelo cuando toca el siguiente scrape, produciendo scrapes solapados y muestras fuera de orden o duplicadas. Prometheus se niega a cargar una configuración así: `promtool check config` falla con `scrape timeout greater than scrape interval for scrape config with job name "..."`, y el servidor registra el error y mantiene la configuración anterior al recargar (o sale al arrancar).

**0.4**
- Prometheus → exporter: **pull**, HTTP GET a `/metrics`. Prometheus inicia.
- Prometheus → Alertmanager: **push**, HTTP POST a `/api/v2/alerts`. Prometheus inicia.
- batch job → Pushgateway: **push**, HTTP POST/PUT. El job inicia.
- Prometheus → Pushgateway: **pull**, exactamente como cualquier otro exporter.
- Grafana → Prometheus: **pull**, API de consultas HTTP.
- Service discovery → Prometheus: Prometheus consulta la fuente de SD (archivo, DNS, API de Kubernetes…).

El componente que invierte el modelo de pull es el **Pushgateway** — y solo en el primer salto; Prometheus sigue haciendo pull desde él.

**0.5** `--web.enable-lifecycle`. Expone `POST /-/reload` y `POST /-/quit` sin autenticación. En un Prometheus expuesto, cualquiera que alcance el puerto 9090 puede apagar el servidor o forzar una recarga. Prometheus no tiene autenticación integrada para estos endpoints por defecto — ponlo detrás de un proxy inverso con autenticación, enlázalo a una interfaz de gestión, o configura `--web.config.file` con basic auth y TLS.

---

## Bloque 1 — El scrape

**1.1** El **servidor Prometheus** las sintetiza al final de cada scrape. `up` vale `1` cuando la petición HTTP tuvo éxito *y* el cuerpo se parseó, y `0` en caso contrario. Un exporter nunca debe exponer `up` porque el servidor la sobrescribiría (o, con `honor_labels`/semánticas en conflicto, produciría una serie que miente): si el exporter no es alcanzable no puede exponer nada, así que un `up` autorreportado es por definición incapaz de reportar su propio fallo.

**1.2** **Manejo de staleness** (Prometheus ≥ 2.0). Cuando una serie presente en el scrape N está ausente en el scrape N+1, Prometheus agrega un **marcador de staleness** explícito — un valor NaN especial — en la marca temporal del scrape N+1. Las consultas que encuentran un marcador de staleness no devuelven valor para esa serie a partir de ese punto. Lo mismo ocurre cuando un target desaparece del service discovery, o cuando el scrape entero falla (todas sus series reciben marcadores).

**1.3** `--query.lookback-delta`, por defecto **5m**. Al evaluar una consulta instantánea en el instante `t`, Prometheus mira hacia atrás hasta 5 minutos buscando la muestra más reciente de cada serie. Con un intervalo de scrape de `10m`, una serie parecerá desvanecerse durante 5 de cada 10 minutos — los gráficos y las alertas harán *flapping*. O subes `--query.lookback-delta` por encima del intervalo de scrape, o (mejor) no scrapeas a intervalos mayores de ~2 minutos; para eso están las recording rules y las funciones `_over_time`.

**1.4** `scrape_series_added` cuenta las series de este scrape que **no** estaban presentes en el anterior. Un valor persistentemente distinto de cero significa que el target está emitiendo series nuevas en cada scrape — una **explosión de cardinalidad en curso**, típicamente causada por una label sin cota como `request_id`, una ruta URL completa, una marca temporal o un identificador de cliente. Esta es la señal más temprana disponible, mucho antes de que `prometheus_tsdb_head_series` se doble visiblemente.

**1.5**
- Solo dispara `absent()`: el exporter está arriba y respondiendo, pero un collector se deshabilitó o dio error, así que la familia de métricas concreta desapareció mientras `up` sigue en `1`.
- Solo dispara `up == 0`: el target es inalcanzable *y* otra instancia del mismo job sigue exponiendo `node_filesystem_avail_bytes`, así que `absent()` — que trata de si la *serie* existe en algún lado — se mantiene en silencio.

Ambas son complementarias: `up == 0` para alcanzabilidad por target, `absent()` para "esta señal completa desapareció del sistema".

**1.6** No. La línea `# TYPE` la consume el parser pero la TSDB solo almacena `(labels, timestamp, float)` — el tipo no se persiste (los native histograms son la excepción, y solo para el propio tipo histogram). La consecuencia es que PromQL te dejará escribir alegremente `rate()` sobre un gauge y devolverá un número de aspecto plausible que carece de sentido semántico: `rate()` asume monotonía, así que cada descenso del gauge se malinterpreta como un reinicio de contador y se descarta silenciosamente, produciendo un resultado sistemáticamente inflado.

---

## Bloque 2 — Configuración y relabeling

**2.1**
- `relabel_configs` corre **una vez por target, antes del scrape**, sobre el conjunto de labels descubiertas del target (todas las `__meta_*`, `__address__`, `__scheme__`, `__metrics_path__`, más cualquier label estática). Decide *si y cómo* scrapear. Un `action: drop` o un `action: keep` que falle aquí elimina el target por completo — nunca se contacta, y aparece bajo `droppedTargets`.
- `metric_relabel_configs` corre **después de cada scrape, una vez por muestra**, sobre el conjunto de labels de la métrica parseada (incluida `__name__`). No puede impedir un scrape; solo puede descartar o reescribir muestras camino a la TSDB.

Regla mnemotécnica: relabel da forma al *target*, metric_relabel da forma a los *datos*.

**2.2** Las labels que empiezan con `__` se **descartan cuando termina el relabeling** — son internas y nunca se almacenan. La excepción es `__name__`, que se convierte en el nombre de la métrica y es una label real (especial). `__address__` tampoco se descarta tanto como se *consume*: determina el endpoint de conexión y, si `instance` no se estableció explícitamente por relabeling, se copia a `instance` por defecto.

**2.3** `action: hashmod`, combinado con un `keep`:

```yaml
relabel_configs:
  - source_labels: [__address__]
    modulus: 4
    target_label: __tmp_shard
    action: hashmod
  - source_labels: [__tmp_shard]
    regex: '2'          # this server takes shard 2
    action: keep
```

Cada uno de los cuatro servidores despliega una configuración idéntica que solo difiere en el `regex`. `hashmod` es determinista (MD5 de los valores concatenados de las source labels, módulo `modulus`), así que los cuatro servidores particionan el conjunto de targets sin coordinación y sin solapamiento. Nota que `__tmp_shard` empieza con `__`, de modo que desaparece después.

**2.4** Con `honor_labels: true`, `instance="db-01"` — ganan las labels presentes en los *datos scrapeados* (que el Pushgateway deriva de la ruta de la URL de push). Con `honor_labels: false` (el valor por defecto), ganan las labels del target: `instance` pasaría a ser `pushgateway:9091` y el valor empujado se conservaría pero renombrado a `exported_instance="db-01"`. Del mismo modo `job` pasaría a ser `pushgateway` y `exported_job="nightly_backup"`. Por eso `honor_labels: true` es obligatorio en un job de Pushgateway.

**2.5** Solo `scrape_samples_post_metric_relabeling`. `scrape_samples_scraped` cuenta lo que llegó por el cable, antes de cualquier metric relabeling. La brecha entre ambos es exactamente lo que descartaron tus `metric_relabel_configs` — lo que convierte a `scrape_samples_scraped - scrape_samples_post_metric_relabeling` en una comprobación útil de que tus reglas de drop hacen lo que crees.

**2.6** Radio de impacto: `promtool check config` es una función pura del archivo — no toca ningún proceso en marcha, no abre la TSDB y no pierde ningún scrape. Un reinicio relee la configuración *y además* reproduce el WAL, borra el estado en memoria del bloque head, reinicia todos los temporizadores `for:` de las alertas (una alerta a mitad de `pending` empieza a contar desde cero) y crea un hueco en cada serie durante lo que dure el reinicio. Tiempo de detección: `promtool` falla en CI, antes del merge, en la pantalla de un desarrollador; un reinicio malo falla en producción, a la hora en que se ejecutó el despliegue, y el único síntoma puede ser `prometheus_config_last_reload_successful == 0` en un servidor que por lo demás sirve alegremente configuración obsoleta.

---

## Bloque 3 — Tipos de métricas

**3.1** Usa un **counter** para un valor que solo aumenta (y se reinicia a cero al reiniciar el proceso) — lo que te interesa es su *tasa*. Usa un **gauge** para un valor que puede subir y bajar — lo que te interesa es su *valor actual*. `rate()` sobre un gauge no tiene sentido porque `rate()` trata cada descenso como un reinicio de contador y vuelve a sumar el valor previo al reinicio, produciendo un número sin interpretación física.

**3.2**
- Histogram: `(11 buckets + _sum + _count) × 4 paths × 30 réplicas` = `13 × 4 × 30` = **1560 series**.
- Summary sin quantiles: `(_sum + _count) × 4 paths × 30 réplicas` = `2 × 4 × 30` = **240 series**.

El compromiso: el histogram cuesta **6,5×** el almacenamiento y te da análisis de latencia agregable, con cuantiles arbitrarios y entre réplicas. El summary es barato pero solo te da media y conteo (y, si se hubieran configurado quantiles, cuantiles por réplica que no puedes combinar).

**3.3** **Acumulativos.** Cada `_bucket{le="X"}` cuenta todas las observaciones `≤ X`. Por eso el bucket `+Inf` siempre equivale a `_count`. Observaciones en `(0.025, 0.05]` = `851 − 682` = **169**.

**3.4** Un histogram almacena *conteos de bucket* crudos, que son counters y por tanto **aditivos**: sumar el bucket `le="0.05"` a lo largo de 30 réplicas da el conteo global real de observaciones ≤ 0,05, y el cuantil se puede interpolar a partir de los conteos globales de bucket. Un summary almacena *cuantiles ya calculados* — el propio valor p99. No hay aritmética que recupere un p99 global a partir de 30 p99 locales; necesitarías la distribución subyacente, que el summary descartó. La propiedad es la **agregabilidad**: los conteos se agregan, los cuantiles no.

**3.5** `increase(v[t])` se define como `rate(v[t]) * t`, y `rate()` **extrapola**. La primera y la última muestra dentro del rango casi nunca caen exactamente en los bordes de la ventana, así que Prometheus calcula la pendiente a partir de las muestras que tiene y la extiende hasta los bordes de la ventana (limitando la extrapolación a como máximo medio intervalo de muestreo en cada lado, y negándose a extrapolar un contador por debajo de cero). El resultado es el incremento *estimado* durante exactamente `t` segundos, que es un número real. Esto es intencional — hace que `rate()` sea estable ante el jitter — y es la razón por la que la salida de `increase()` nunca debe presentarse como un conteo exacto de eventos.

**3.6** **Regla práctica: el rango debe ser al menos 4× el intervalo de scrape** (muchos equipos usan 4–5×). Con `scrape_interval: 15s`:
- `[15s]` contiene frecuentemente una **sola** muestra. `rate()` necesita al menos dos puntos para calcular una pendiente, así que devuelve **sin datos** en esos pasos de evaluación — el gráfico queda vacío o lleno de huecos.
- `[1m]` contiene ~4 muestras: funciona, pero un solo scrape perdido te deja en 3 y el resultado se vuelve ruidoso.
- `[5m]` contiene ~20 muestras: tolera scrapes perdidos y reinicios del target, a costa de suavizar los picos cortos.

**3.7** `rate()` (y `increase()`, e `irate()`) asumen que un descenso solo puede significar un **reinicio del contador**, así que suman el último valor previo al reinicio a la diferencia — es decir, asumen que el contador subió desde `v_n` hasta cierto valor y luego reinició desde 0. La suposición es errónea cuando ocurre un descenso *genuino* que no es un reinicio: el caso clásico es una métrica que en realidad es un gauge pero se declaró como counter, y el caso más sutil es un balanceador de carga o proxy agregador cuyo "contador" es una suma sobre un conjunto fluctuante de backends — cuando un backend se va, la suma cae, `rate()` lee un reinicio y reporta un incremento fantasma enorme.

**3.8** El patrón de la **métrica info** (o "metadatos legibles por máquina"). El valor siempre es `1` y es irrelevante porque la información vive enteramente en las labels; el valor constante existe solo para que la serie pueda participar en un join `group_left`. Poner `version` directamente en `demo_http_requests_total` multiplicaría el conteo de series de esa métrica por el número de versiones desplegadas alguna vez y — peor aún — cada despliegue crearía una serie *nueva* y rompería la continuidad de `rate()` en la frontera del despliegue, justo cuando más necesitas que el gráfico sea legible.

**3.9** `irate()` usa solo las **dos últimas muestras** del rango, dando una tasa instantánea que revela picos cortos que un promedio de 5 minutos aplanaría. Uso legítimo: gráficas interactivas de alta resolución cuando estás depurando activamente una carga con picos. Nunca debe aparecer en una alerting rule porque es máximamente sensible al jitter de un solo scrape o a una muestra perdida — un único punto anómalo puede disparar o limpiar la alerta, y las alerting rules se evalúan a un intervalo fijo donde ese ruido no es visible para un humano que pudiera descartarlo.

---

## Bloque 4 — PromQL

**4.1** `sum by (path)` **descarta** todo excepto `path` — sin `job`, sin `instance`. `sum without (status, method)` **conserva** todo excepto las dos labels nombradas, así que `job`, `instance`, `path`, `env` y `service` sobreviven todas. Esto importa enormemente para las alertas: una anotación que referencia `{{ $labels.instance }}` se renderiza vacía si la expresión usó `by (path)`, y el aviso resultante le dice al ingeniero de guardia *qué* está mal pero no *dónde*. Como regla, prefiere `without` en las expresiones de alerta, o enumera explícitamente cada label que necesites en la cláusula `by`.

**4.2** Los operadores binarios entre dos vectores instantáneos usan por defecto **emparejamiento uno-a-uno sobre el conjunto completo de labels**: una muestra de la izquierda se empareja con una de la derecha solo si *todas* las labels coinciden. `/healthz` no produce ninguna serie `status=~"5.."`, así que el lado izquierdo no tiene ningún elemento con `path="/healthz"`, así que no hay nada con qué emparejar el lado derecho y no se produce serie de salida. El idiom `or` lo arregla suministrando una serie de valor cero para cada path presente a la derecha y ausente a la izquierda: `or` devuelve las series del operando izquierdo más, para los conjuntos de labels que solo aparecen a la derecha, las series del operando derecho — aquí multiplicadas deliberadamente por `0`.

**4.3** `histogram_quantile()` exige un vector de entrada en el que la label `le` sea la **única** dimensión que varía dentro de cada grupo de salida; agrupa la entrada por todas las labels *excepto* `le` y lee cada grupo como un histograma acumulativo completo. Incluso en una sola réplica, un `rate(..._bucket[5m])` sin agregar lleva `path`, `job` e `instance` — lo cual de hecho está bien para agrupar — pero el problema real es que cualquier *otra* dimensión suelta (una label extra, o varias réplicas) divide o fusiona histogramas silenciosa e incorrectamente, y si luego agregas eliminando `le` primero la función no tiene nada sobre lo que interpolar. La forma segura y universal es `sum by (le, <dimensiones que quieras>) (rate(..._bucket[5m]))`: hace explícita la agrupación en lugar de accidental.

**4.4** Los percentiles son **estadísticos de orden, no funcionales lineales**. La media de los percentiles 99 de N distribuciones no es el percentil 99 de la distribución conjunta — promediar asume que la magnitud es aditiva bajo una suma ponderada, y los cuantiles no lo son. Concretamente: nueve réplicas con p99 = 100 ms y una réplica con p99 = 10 s promedian 1,09 s, un número que no describe ninguna petición que nadie hizo, mientras que el p99 conjunto real depende de los volúmenes relativos de peticiones y podría estar en cualquier punto entre 100 ms y 10 s.

**4.5** **Interpolación lineal dentro del bucket.** `histogram_quantile` encuentra el bucket en el que cae el rango objetivo — aquí `(1.0, 2.5]` — e interpola linealmente entre los límites inferior y superior del bucket según lo adentro que esté el rango en ese bucket. Así que `1.91` significa "aproximadamente un 61% dentro del bucket 1.0–2.5". Por tanto, la precisión de la respuesta está acotada enteramente por la disposición de tus buckets, no por el número de observaciones: con bordes en 1.0 y 2.5, el p99 solo se conoce con un margen de 1,5 segundos.

Si el cuantil cae en el bucket `+Inf`, no hay límite superior hacia el cual interpolar, y `histogram_quantile` devuelve el **límite superior del bucket finito más alto** (aquí `5.0`). Por eso un p99 clavado exactamente en el borde de tu bucket más grande es una señal de que tus buckets son demasiado estrechos, no de que la latencia sea estable. (Simétricamente, si el bucket más bajo tiene `le > 0` y el cuantil cae en él, la interpolación se hace entre `0` y ese límite.)

**4.6** La media es mejor para preguntas de **capacidad y coste**: tiempo total dedicado a servir peticiones, throughput × latencia media = concurrencia (ley de Little), CPU-segundos por petición. La media miente activamente sobre la **experiencia de usuario** en cualquier distribución de latencia con cola larga — es decir, todas. Un servicio donde el 99% de las peticiones tarda 5 ms y el 1% tarda 5 s tiene una media de ~55 ms, que se ve excelente y oculta por completo que uno de cada cien usuarios está agotando el tiempo de espera.

**4.7**
- `on (instance)` — restringe el emparejamiento a la label `instance` únicamente; ignora todas las demás labels al emparejar muestras de la izquierda y de la derecha.
- `group_left` — esto es un emparejamiento **muchos-a-uno**: muchas muestras de la *izquierda* pueden emparejarse con una muestra de la derecha. La cardinalidad del resultado sigue al lado izquierdo.
- `(version)` — copia la label `version` del lado derecho (el lado "uno") al resultado. Sin esta lista, el join filtra y escala pero no copia nada.

`group_right` lo invierte: uno-a-muchos, el lado *derecho* pasa a ser el lado "muchos" y determina la cardinalidad del resultado, y las labels listadas se copian desde la izquierda. Escribirías la expresión al revés: `demo_build_info * on (instance) group_right(...) sum by (instance) (rate(...))`.

**4.8** `predict_linear` ajusta una **regresión lineal simple (mínimos cuadrados ordinarios)** sobre todas las muestras del rango y extrapola la recta ajustada hacia adelante el número de segundos indicado. Falla gravemente con los sistemas de archivos porque el uso real de disco no es lineal: la rotación de logs y `tmpwatch` producen dientes de sierra que una recta interpreta como una tendencia sostenida; el borrado de un único archivo grande dentro de la ventana invierte la pendiente; y un sistema de archivos que está al 99% y estable produce una pendiente cercana a cero y nunca alerta. Mitigaciones: combínalo con un umbral absoluto (como hace el ejercicio con `< 0.20`), usa un rango suficientemente largo (6h, no 15m) y añade `for:` para que una pendiente transitoria no genere un aviso.

---

## Bloque 5 — Recording rules

**5.1** Sí, es seguro y es el diseño previsto. **Las reglas dentro de un grupo se evalúan secuencialmente, en el orden en que están escritas**, contra una única marca temporal de evaluación consistente — así que una regla puede depender de la salida de cualquier regla declarada por encima en el mismo grupo. **Los grupos distintos se evalúan de forma independiente y concurrente.** Si las dos reglas estuvieran en grupos distintos, la regla dependiente leería el valor que el otro grupo hubiera escrito en su ejecución *anterior*, obsoleto en hasta un intervalo de evaluación, o directamente ausente en la primera evaluación tras un reinicio. Las reglas encadenadas deben vivir en el mismo grupo, en orden de dependencia.

**5.2** El `interval` del grupo debe ser **más corto que el rango** usado en las expresiones — idealmente como máximo la mitad, y nunca más largo. Con `interval: 15s` y `[5m]`, las evaluaciones consecutivas se solapan mucho, que es lo que hace que la serie registrada sea suave y sin huecos. Con `interval: 10m` y `[5m]`, cada evaluación cubre 5 minutos y luego pasan 5 minutos sin cubrir: la mitad de cada muestra de origen nunca la ve ninguna evaluación, y la serie registrada es una vista submuestreada y con *aliasing* de la original.

**5.3** `level:metric:operations`:
- `level` — el nivel de agregación / las labels por las que se agrupa la serie (`path`, o `job`, `instance`, `cluster`…).
- `metric` — el nombre de la métrica subyacente de la que deriva la regla.
- `operations` — la lista de operaciones aplicadas, la más reciente al final (`rate5m`, `ratio5m`, `sum:rate5m`).

Los dos puntos están **reservados por convención para las recording rules** y nunca deben aparecer en el nombre de una métrica instrumentada directamente. Esa convención es lo que permite a un lector (y a un linter) distinguir de un vistazo si una serie salió de un exporter o de una regla, y significa que las librerías cliente pueden rechazar con seguridad los dos puntos en los nombres de métricas.

**5.4** `'0+570x10'` significa "empieza en 0, suma 570, repite 10 veces más" — 11 muestras en total:

```
0, 570, 1140, 1710, ... , 5700
```

a intervalos de 1 minuto (el `interval: 1m` del test). El contador aumenta 570 por minuto; combinado con la serie de errores `500` a 30 por minuto, el total es 600 por minuto = **10 por segundo**. `rate(...[5m])` sobre un contador perfectamente lineal devuelve exactamente la pendiente en unidades por segundo, así que la respuesta es exactamente `10`.

**5.5** `promtool test rules` resuelve las rutas de `rule_files` **relativas al directorio de trabajo actual**, no al archivo de test. `docker compose exec -w /etc/prometheus/rules` establece el directorio de trabajo dentro del contenedor donde vive `recording.yml`, de modo que `rule_files: ['recording.yml']` resuelve. Usar una ruta absoluta dentro del archivo de test también funcionaría, pero ataría el test a la disposición de montajes del contenedor y se rompería cuando el mismo test corriera en CI fuera de un contenedor.

**5.6** La evaluación de la regla **falla**: Prometheus descarta el resultado completo de esa evaluación (sin escritura parcial), marca el `health` de la regla como `err`, rellena `lastError` con un mensaje sobre el límite superado e incrementa `prometheus_rule_evaluation_failures_total`. La serie registrada simplemente no recibe una muestra nueva en ese intervalo, así que las consultas y alertas aguas abajo la ven volverse obsoleta. `limit` es una válvula de seguridad contra una regla que se ramifica inesperadamente, no un mecanismo de truncado.

**5.7**
- `prometheus_rule_group_last_duration_seconds` comparada con `prometheus_rule_group_interval_seconds` — si la evaluación tarda más que el intervalo, el grupo se está atrasando por construcción.
- `prometheus_rule_group_iterations_missed_total` (rate > 0 significa que se saltaron evaluaciones) y `prometheus_rule_evaluation_failures_total` para la vía de error.

**5.8** Renunciaste a la **recuantización**. Una vez que la serie registrada es `p99`, nunca podrás preguntarle a esos datos por p50, p90, p999, ni "qué fracción de las peticiones estuvo por debajo de 250 ms" — esas preguntas necesitan la dimensión `le`, que la recording rule colapsó. La mitigación estándar es registrar las *tasas de bucket agregadas* (conservando `le`) en lugar del cuantil en sí: `record: path:demo_http_request_duration_seconds_bucket:rate5m` con `sum by (le, path) (rate(...))`. Obtienes la mayor parte de la aceleración en tiempo de consulta y conservas la capacidad de calcular cualquier cuantil después.

---

## Bloque 6 — Alerting rules

**6.1**
- **inactive → pending**: la `expr` devuelve al menos una muestra para un conjunto de labels dado en una evaluación.
- **pending → firing**: la `expr` ha devuelto ese mismo conjunto de labels de forma continua durante al menos la duración de `for`. Si la expresión deja de coincidir en cualquier momento durante `for`, la alerta vuelve a `inactive` y el temporizador se reinicia.
- **firing → inactive**: la `expr` deja de devolver ese conjunto de labels (inmediatamente, salvo que se haya definido `keep_firing_for`, en cuyo caso la alerta sigue en firing durante esa duración adicional tras dejar de coincidir la expresión).

`for` actúa sobre la **entrada** a firing (un antirrebote contra transitorios). `keep_firing_for` actúa sobre la **salida** de firing (un antirrebote contra el flapping/la agitación en la resolución). Si `for` se omite o es `0`, una alerta pasa directamente de inactive a firing.

**6.2** En `eval_time: 4m` el target lleva caído desde el minuto 3 (una evaluación), y `for: 2m` no ha transcurrido, así que la alerta está en **pending**. `exp_alerts` de `alert_rule_test` reporta **solo alertas en firing** — las alertas en pending no se incluyen. Por lo tanto, el test tal como está escrito fallaría con "expected 1 alert, got 0". Para hacer una aserción sobre el estado pending, o bien mueves `eval_time` más allá de `for` (p. ej. `6m`) para afirmar firing, o bien haces la aserción directamente sobre la serie `ALERTS` vía `promql_expr_test` con `expr: ALERTS{alertname="TargetDown", alertstate="pending"}`. Esta es exactamente la clase de bug para la que existen los tests unitarios de reglas.

**6.3** `absent(up)` devuelve un valor solo cuando **no existe ninguna serie `up` en toda la TSDB** — es decir, cuando Prometheus no está scrapeando literalmente nada. Como Prometheus siempre se scrapea a sí mismo, esa condición prácticamente nunca es verdadera, así que la alerta es código muerto. `up == 0` es por target y es lo que quieres.

`absent()` es lo único que funciona cuando aquello que vigilas **no tiene ningún target en absoluto**: un job cuyo service discovery devolvió cero targets (así que no hay serie `up` que pueda valer `0`), una métrica que debería empujarse al Pushgateway y nunca se empujó, o una señal federada/enviada por remote_write que dejó de llegar. En los tres casos no hay nada que comparar con cero — la serie simplemente no existe, y solo `absent()` (o `absent_over_time()`) puede expresarlo.

**6.4** La ratio de errores de la app demo ronda el 4% con jitter real; a lo largo de una ventana de 3 minutos puede caer por debajo del umbral del 2% durante una evaluación y volver enseguida. Sin `keep_firing_for`, la alerta se resuelve, Alertmanager envía una notificación `[RESOLVED]`, y 15 segundos después la alerta vuelve a `pending`, espera 3 minutos, dispara otra vez y Alertmanager envía una notificación nueva. El ingeniero de guardia recibe un flujo interminable de pares resolver/disparar por una condición que en realidad nunca mejoró — y, peor aún, aprende a ignorar esa alerta. `keep_firing_for: 5m` mantiene la alerta en firing a través de esas caídas, de modo que un incidente produce una notificación.

**6.5** `and` es un **operador de conjuntos**: devuelve los elementos del vector izquierdo para los que existe una muestra con **exactamente el mismo conjunto de labels** en el vector derecho. La multiplicación produciría un producto numérico sin significado (una ratio por un conteo de bytes predicho), y un operador de comparación devuelve el *valor* del lado izquierdo, no un booleano, así que no puede expresar "ambas condiciones se cumplen".

El requisito sobre el conjunto de labels es la razón por la que ambos operandos llevan el selector `fstype!~...` idéntico: ambos lados producen series etiquetadas `{device, fstype, mountpoint, instance, job}`, así que se emparejan uno a uno. Si los selectores difirieran, o si un lado estuviera agregado, nada coincidiría y la alerta nunca podría disparar. El resultado lleva las labels y los valores del lado izquierdo — así que `$value` en la anotación es la *ratio*, no la predicción.

**6.6** Las plantillas de anotaciones y labels las evalúa **Prometheus**, en el momento en que la alerta se envía a Alertmanager. Alertmanager las recibe como cadenas ya renderizadas.

La consecuencia es que en las propias plantillas de notificación de Alertmanager, `$labels` y `$value` no existen. Alertmanager ve una lista de alertas, cada una con `.Labels`, `.Annotations`, `.StartsAt`, `.GeneratorURL` — así que escribes `{{ .CommonLabels.severity }}` o `{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}`. Todo lo que quieras disponible en una notificación tiene que haber sido renderizado antes por Prometheus en una label o una anotación.

**6.7**
1. **Coste.** La expresión es cara — `predict_linear` sobre un rango `[6h]` lee seis horas de muestras por evaluación y por serie. Ejecutar eso cada 15 segundos es un desperdicio cuando la entrada apenas se mueve.
2. **Escala temporal de la señal.** Una predicción de llenado de sistema de archivos es significativa a lo largo de horas; evaluarla cuatro veces por minuto no añade información, solo ruido y CPU. Ajustar el intervalo de evaluación a la escala temporal del fenómeno es un argumento de corrección, no solo de eficiencia.

(Una tercera razón relacionada: reducir la carga de evaluación de un grupo evita que los grupos *rápidos* — los que realmente necesitan avisar deprisa — queden encolados detrás de él.)

**6.8** La alerta puede tardar hasta **`for` + `interval`** ≈ 7 minutos, y en el peor caso algo más. La regla se evalúa solo cada 5 minutos, así que la condición puede volverse verdadera justo después de una evaluación y pasar desapercibida durante casi 5 minutos; la siguiente evaluación mueve la alerta a `pending`; `for: 2m` exige entonces que la condición siga cumpliéndose en una evaluación *posterior* — y la siguiente evaluación es 5 minutos después, no 2. Así que el firing ocurre en la segunda evaluación tras volverse verdadera la condición.

Fórmula general: latencia de detección en el peor caso ≈ `scrape_interval + interval + ceil(for / interval) × interval`, más el `group_wait` de Alertmanager. La regla práctica: **`for` debería ser un múltiplo del `interval` del grupo, y el `interval` del grupo debería ser mucho menor que `for`.**

---

## Bloque 7 — Alertmanager

**7.1**
- **`group_wait`** — tras llegar la *primera* alerta de un grupo completamente nuevo, espera este tiempo antes de notificar, para que las alertas hermanas que disparan en el mismo momento se agrupen en una sola notificación. Por defecto 30s.
- **`group_interval`** — una vez notificado un grupo, espera al menos este tiempo antes de enviar una notificación *modificada* sobre alertas recién añadidas a (o resueltas dentro de) ese mismo grupo. Por defecto 5m.
- **`repeat_interval`** — cuánto esperar antes de reenviar una notificación de un grupo cuyo contenido **no** ha cambiado y que sigue en firing. Por defecto 4h.

Para reducir el tiempo hasta el aviso, acorta **`group_wait`** (la ruta crítica de este ejercicio lo pone en 10s). Para reducir la fatiga de alertas, alarga **`repeat_interval`** — ese es el recordatorio, y es el que despierta a la gente por algo que ya sabe.

**7.2**
- `group_by: ['alertname', 'cluster', 'service']` — un grupo (y por tanto un hilo de notificación) por cada combinación distinta de esas tres labels.
- **Omitir `group_by`** en una ruta hija hereda el valor del padre. Omitirlo en la `route` de nivel superior significa no agrupar por nada — equivalente a `group_by: []`.
- **`group_by: []`** — sin agrupación: **cada alerta genera su propia notificación.** Una caída de 200 nodos produce 200 avisos.
- **`group_by: ['...']`** — la cadena literal de tres puntos es un valor especial que significa "agrupar por **todas** las labels, deshabilitando la agregación". Cada conjunto de labels distinto es su propio grupo. Esto se usa cuando un sistema aguas abajo (una integración de tickets) necesita una notificación por instancia de alerta, y está explícitamente documentado como no recomendado para destinatarios humanos.

**7.3** El enrutamiento recorre el árbol en profundidad, tomando la **primera ruta hija cuyos matchers coincidan todos**; si ninguna coincide, la alerta se queda con el receptor del nodo actual. Una alerta con `severity="critical", team="orders"` coincide con la primera hija (`severity = "critical"`) y, como `continue: false`, el enrutamiento **se detiene ahí** — va solo a `critical-webhook`. La ruta `orders-webhook` nunca se evalúa, aunque `team="orders"` habría coincidido con ella (en realidad no lo haría — esa ruta también exige `severity =~ "warning|info"` — pero el argumento vale para una ruta que sí coincidiera).

Con `continue: true` en la ruta crítica, la evaluación continúa hacia las rutas *hermanas* tras coincidir, así que la alerta se entregaría a `critical-webhook` **y** a cualquier hermana posterior que coincida. `continue` es la forma de implementar "avisa al de guardia *y* replica al canal del equipo".

**7.4** Los tres componentes:
- `source_matchers` — qué alertas, al estar en firing, hacen la inhibición.
- `target_matchers` — qué alertas quedan suprimidas.
- `equal` — la lista de labels que deben tener **valores idénticos** en la alerta origen y en la alerta destino para que la inhibición se aplique.

`equal: ['instance']` garantiza que un `TargetDown` en `node-a` solo suprima advertencias **sobre `node-a`**. Omite `equal`, y un único `TargetDown` en cualquier punto de la flota suprime **todas las alertas de severidad warning de todo el sistema** — has construido un mecanismo por el cual una máquina muerta te ciega ante cualquier otro problema. Un `equal` ausente es la mala configuración más peligrosa de Alertmanager.

**7.5**
1. **Quién y cuándo.** Un silencio lo crea un **humano** (o una automatización) a través de la API/UI/`amtool`, tiene una expiración explícita y lleva un comentario y un autor. Una inhibición es una **regla permanente de configuración** evaluada automáticamente que dura exactamente lo que dure el firing de la alerta origen.
2. **Visibilidad e intención.** Una alerta silenciada aparece en la UI como silenciada, con quién la silenció y por qué, y el silencio en sí es un objeto de primera clase que puedes listar, extender o expirar. Una alerta inhibida aparece como inhibida, sin autor — el "por qué" vive en `alertmanager.yml`. Los silencios expresan "lo sé, estoy en ello / es mantenimiento planificado"; las inhibiciones expresan "esta alerta es una consecuencia estructural de aquella otra y nunca es accionable de forma independiente".

**7.6** Lo adjuntó **Prometheus**, en el momento en que construyó la notificación de alerta para hacer POST a Alertmanager — las `external_labels` se aplican a la salida (ver 0.2).

`replica: prom-a` es un problema en un par HA porque los dos servidores producen alertas cuyos conjuntos de labels difieren **únicamente** en esa label. La deduplicación de Alertmanager funciona por igualdad exacta del conjunto de labels, así que las copias de la misma alerta de `prom-a` y `prom-b` se ven como dos alertas distintas, caen en dos grupos distintos y generan dos notificaciones. La solución estándar es eliminar la label de réplica antes de enviar — `alert_relabel_configs` en el bloque `alerting` con `action: labeldrop, regex: replica` — conservándola para `remote_write` y federación, donde sí es genuinamente necesaria.

**7.7** Se aplica a las alertas que fueron **empujadas vía la API sin una marca temporal `endsAt`**. Las alertas enviadas por Prometheus siempre llevan un `endsAt` explícito (Prometheus reenvía periódicamente las alertas en firing y fija `endsAt` en un punto ligeramente futuro; cuando deja de reenviarlas, `endsAt` pasa y la alerta se resuelve), así que no dependen de `resolve_timeout`. Una alerta empujada a mano sin `endsAt` estaría en firing para siempre, así que Alertmanager la expira `resolve_timeout` después de la última vez que la vio. Esta es precisamente la razón por la que la alerta que inyectaste en el paso 6 acabó desapareciendo sola.

**7.8**
1. **Prometheus:** el bloque `annotations` de la alerting rule — `runbook_url` es una anotación y debería ser obligatoria. Impónlo en CI con un linter sobre los archivos de reglas (`promtool check rules` no lo hará por ti; un script pequeño o `pint` sí).
2. **Alertmanager:** la **plantilla** de notificación del receptor, que decide qué llega realmente al humano. Una plantilla que renderice `{{ .Annotations.runbook_url }}` y recurra a una cadena visible tipo "NO RUNBOOK — fix the alerting rule" convierte una omisión silenciosa en una ruidosa.

---

## Bloque 8 — Exporters multi-target y Pushgateway

**8.1**
- **Sin la regla 3**, `__address__` sigue siendo la URL sondeada, así que Prometheus intentaría conectarse *directamente* a `demo-app:8000` (y a `does-not-exist.invalid`) y hacer GET a `/probe?module=http_2xx&target=...` allí. La app demo no sirve `/probe`, así que el scrape falla con un 404; el host inválido no resuelve. Al blackbox exporter nunca se lo contacta.
- **Sin la regla 2**, el sondeo sigue funcionando — Prometheus habla con `blackbox:9115` y pasa el parámetro `target` correcto — pero todas las series resultantes llevan `instance="blackbox:9115"`. Los tres sondeos colisionan en un mismo conjunto de labels, así que gana el último scrape y en la práctica monitoreas un target arbitrario. La regla 2 es lo que preserva *qué* cosa se sondeó.

**8.2** `up` describe la salud del **scrape del exporter**: Prometheus alcanzó `blackbox:9115` con éxito, obtuvo un 200 y parseó el cuerpo — así que `up=1`. `probe_success` describe la salud del **sondeo que el exporter realizó en tu nombre**: la resolución DNS de `does-not-exist.invalid` falló, así que `probe_success=0`. Debes alertar sobre **`probe_success == 0`** para detectar un sitio web caído; `up == 0` en un job de blackbox significa que el propio blackbox exporter está roto, que es una condición distinta (y también digna de alerta).

**8.3** Un **exporter multi-target** no expone métricas sobre sí mismo; expone un endpoint estilo `/probe` que recibe la cosa a inspeccionar como **parámetro de consulta**, de modo que una instancia del exporter sirve a un número ilimitado de targets monitoreados. Otros exporters que siguen el patrón: `snmp_exporter`, `blackbox_exporter` y el `ssl_exporter`. (`mysqld_exporter` y `postgres_exporter` también soportan un modo multi-target en versiones recientes.)

**8.4** `honor_labels: true` en el job `pushgateway`. El Pushgateway deriva `job` e `instance` de la ruta de la URL de push y las expone como labels ordinarias en la métrica; `honor_labels: true` le dice a Prometheus que no las sobrescriba con las del propio target. Sin ello, las labels habrían sido `job="pushgateway"`, `instance="pushgateway:9091"`, con los valores empujados conservados como `exported_job="nightly_backup"` y `exported_instance="db-01"` — lo que sigue funcionando pero rompe toda consulta y alerta escrita contra los nombres naturales.

**8.5**
1. **`up` deja de ser útil como señal de salud.** `up` ahora refleja la disponibilidad del Pushgateway, no la del batch job. El job puede llevar muerto una semana con `up=1`.
2. **Cuando el job desaparece, sus métricas no.** El Pushgateway no tiene noción de que el emisor se fue — sin marcadores de staleness, sin expiración. No hay nada sobre lo que alertar salvo la *antigüedad* de la métrica, que es por lo que `BackupStale` compara `time()` contra una marca temporal empujada.
3. **Tras dar de baja el servicio, las métricas persisten para siempre.** Hay que hacerles `DELETE` explícitamente. Un host retirado sigue reportando un "último backup exitoso" obsoleto hasta que alguien se dé cuenta, y con `--persistence.file` configurado sobrevive incluso a los reinicios.

Además, el Pushgateway es un **punto único de fallo y un cuello de botella único** para todo lo que se enrute a través de él — una razón más por la que su alcance se limita a batch jobs a nivel de servicio.

**8.6** `absent()` devuelve una serie etiquetada con las labels que aparecen como **matchers de igualdad en el selector de su argumento** — aquí `{job="nightly_backup"}` — y nada más. No puede conocer `instance="db-01"` porque ese valor es precisamente lo que falta; no hay ninguna serie de la que leerlo.

La solución estándar es alertar contra un **inventario conocido** en lugar de contra la ausencia en abstracto: haz un join de la métrica con una serie de info/inventario que siempre exista (`up`, una métrica `..._info`, o una serie estática generada por una recording rule) y alerta cuando el join no produzca coincidencia — p. ej. `expected_backup_targets unless on (instance) backup_last_success_timestamp_seconds`. En Kubernetes ese mismo trabajo lo hacen las métricas de inventario `kube_*` de kube-state-metrics.

**8.7** Sin `--persistence.file`, el Pushgateway guarda todo **solo en memoria**: un reinicio pierde toda métrica empujada hasta la siguiente ejecución de cada batch job, lo que para un backup nocturno significa hasta 24 horas de "la métrica no existe".

No cambia la *corrección* de `BackupStale` — esa alerta compara una marca temporal y no puede dispararse sobre una serie ausente — pero cambia qué alerta dispara: tras un reinicio, `BackupStale` queda en silencio (sin serie) y `BackupNeverRan` (la alerta con `absent()`) toma el relevo. Por eso exactamente ambas alertas existen como pareja; cualquiera de ellas por separado deja un punto ciego.

**8.8** La respuesta correcta es: **no uses el Pushgateway para esto.** Un servicio de larga duración debe ser scrapeado, y el Pushgateway está documentado como destinado solo a batch jobs a nivel de servicio — empujar cada 15 segundos reintroduce todos los modos de fallo de 8.5 sin ganar nada.

Las dos alternativas soportadas:
1. **Haz que el servicio sea scrapeable a través de la frontera de red** — expón `/metrics` y deja que Prometheus lo alcance, o corre un Prometheus dentro de su red que scrapee localmente y **federe** (`/federate`) o haga **`remote_write`** del resultado agregado hacia fuera. Esta es la respuesta normal a "no puedes meterte en nuestra red".
2. **`remote_write` / ingesta OTLP** — si los datos realmente deben empujarse, empújalos como un flujo remote-write de primera clase (Prometheus 3.x acepta remote-write con `--web.enable-remote-write-receiver`, y OTLP con `--web.enable-otlp-receiver`), lo que preserva marcas temporales, staleness e identidad por instancia de una forma que el Pushgateway no puede.

---

## Bloque 9 — Grafana

**9.1** Configuraste **`access: proxy`**: el backend de Grafana hace la petición HTTP a Prometheus y retransmite la respuesta al navegador. Dos razones por las que es lo correcto aquí:
1. **Alcanzabilidad.** `http://prometheus:9090` es un nombre de la red Docker que solo resuelve dentro de la red de Compose. El navegador del usuario no puede resolverlo; el backend de Grafana sí. El mismo argumento vale para un Prometheus en una VLAN privada o detrás de una VPN.
2. **Credenciales y exposición.** Cualquier autenticación (basic auth, certificado cliente TLS, un token de API) la guarda Grafana del lado del servidor y nunca se envía al navegador, y Prometheus no necesita quedar expuesto a usuarios finales ni tener CORS configurado.

(`access: direct` / modo navegador está obsoleto en las versiones modernas de Grafana exactamente por estas razones.)

**9.2** Alimenta la noción que tiene Grafana del **intervalo de scrape** del datasource, que fija el suelo de `$__interval` y es la entrada de `$__rate_interval`. La fórmula es:

```
$__rate_interval = max($__interval + scrape_interval, 4 × scrape_interval)
```

donde `scrape_interval` es `timeInterval` del datasource (o el *Min step* del panel si se ha configurado). Con `timeInterval: 15s` y un panel con zoom donde `$__interval` es `15s`, `$__rate_interval` es `max(30s, 60s)` = `60s`.

**9.3** `$__interval` se calcula puramente a partir del ancho en píxeles del panel y del rango temporal — es el *paso* de la consulta, no el intervalo de scrape. Con zoom sobre unos pocos minutos en un panel ancho, `$__interval` puede ser `5s` o `10s`, que es **menor que el intervalo de scrape de 15 s**: el selector de rango entonces suele contener menos de dos muestras, `rate()` no puede calcular una pendiente y el panel queda vacío o lleno de huecos. (Alejando el zoom a 7 días, `$__interval` se vuelve grande — minutos u horas — y `rate()` sigue funcionando pero suaviza mucho.)

`$__rate_interval` existe precisamente para resolver esto: su término `max(..., 4 × scrape_interval)` garantiza que el rango nunca baje de cuatro intervalos de scrape, así que siempre hay muestras suficientes por mucho que acerques el zoom, y su término `$__interval + scrape_interval` lo mantiene creciendo de forma sensata al alejarte.

**9.4** Un `[5m]` fijo es **siempre correcto** — nunca tiene muestras insuficientes — pero no es *ideal* porque ignora la resolución del panel: alejado a 30 días suaviza en exceso (de todos modos no puedes ver nada más corto que 5 minutos, así que no hay pérdida), y con zoom a 2 minutos muestra un promedio de 5 minutos sobre una ventana de 2 minutos, ocultando exactamente el detalle para el que acercaste el zoom.

Fijarlo a mano es la elección **correcta** cuando el panel debe coincidir exactamente con una alerting rule o una recording rule. Si tu alerta dispara con `rate(x[5m]) > 0.02`, el panel del dashboard usado para investigar esa alerta debe usar `[5m]` también — de lo contrario el gráfico y la alerta no coinciden y el ingeniero de guardia pierde la confianza en ambos.

**9.5** Eleva el **límite de longitud de la URL**. Con `GET`, la expresión PromQL viaja en la cadena de consulta, y las expresiones largas — cadenas grandes de recording rules, selectores con regex de muchas alternativas, dashboards con variables de plantilla expandidas a decenas de valores — chocan con el tope de longitud de URL del servidor o del proxy (habitualmente 2 KB–8 KB) y fallan con `414 Request-URI Too Large`. Con `POST`, la expresión va en el cuerpo de la petición. Lo alcanzarás por primera vez en un panel con una variable de plantilla multivalor que se expande a un regex largo `=~"a|b|c|..."` — el clásico "el dashboard funciona con un pod y se rompe cuando selecciono All".

**9.6**
1. **Disponibilidad de la vía de alerta.** Las alertas de Prometheus + Alertmanager siguen funcionando cuando Grafana está caído, actualizándose o con un problema de base de datos. Grafana es una capa de visualización; convertirla en una dependencia de tu vía de avisos añade un componente cuyo fallo es silencioso.
2. **Alertas como código, junto a las reglas de las que dependen.** Las alerting rules de Prometheus viven en YAML en el mismo repositorio que las recording rules a las que referencian, las valida `promtool check rules` y son **testeables unitariamente** con `promtool test rules` — nada de lo cual tiene un equivalente limpio para las alertas gestionadas por Grafana. Además comparten el enrutamiento, la agrupación, la inhibición y los silencios de Alertmanager con cualquier otra fuente de alertas, así que hay exactamente un sitio donde silenciar durante un mantenimiento.

(Una tercera: la alerta de Grafana se evalúa consultando a Prometheus sobre HTTP, añadiendo modos de fallo de red y de capa de consulta entre los datos y la decisión.)

**9.7** Grafana llama a **`GET /api/v1/label/path/values`** con un parámetro `match[]` para el selector de la métrica y el rango temporal del dashboard.

Es más barato porque se responde desde el **índice invertido (postings)** de la TSDB — el conjunto de valores distintos de un nombre de label es metadato de índice precalculado, y no se lee ninguna muestra. `count by (path) (demo_http_requests_total)` es una consulta completa: selecciona cada serie coincidente, lee una muestra de cada una dentro de la ventana de lookback, agrupa y cuenta. En una métrica con decenas de miles de series la diferencia es de milisegundos frente a segundos, y se paga en cada carga del dashboard y en cada refresco de la variable.

**9.8** El **Panel B**, el que consulta la recording rule. A lo largo de 30 días con resolución de 15 segundos, el Panel C debe leer todas las series `_bucket` (11 buckets × 4 paths × cada réplica) durante todo el rango, calcular un rate por serie y por paso, agregar por `le` e interpolar — una consulta cuyo coste escala con buckets × paths × réplicas × pasos. El Panel B lee una única serie precalculada por path: el trabajo caro ya se hizo una vez, de forma incremental, en el momento de evaluar la regla. Este es el argumento económico completo a favor de las recording rules — pagar una vez en tiempo de escritura en lugar de cada vez que alguien abre el dashboard.

---

## Bloque 10 — Diagnóstico

**10.1** El scrape se **descarta por completo**. Prometheus parsea la respuesta, cuenta las muestras y, si el conteo supera `sample_limit`, rechaza el scrape entero — sin ingestión parcial. `up` pasa a **0** y `lastError` dice `sample limit exceeded`.

Todo o nada es el comportamiento más seguro porque la ingestión parcial sería silenciosa e impredeciblemente lossy: tendrías *algunas* de las series del target, sin manera de saber cuáles se descartaron, y los dashboards mostrarían datos plausibles pero erróneos. Fallar el scrape entero hace el problema ruidoso (`up == 0` genera un aviso) y mantiene los datos ingeridos internamente consistentes.

**10.2** De más temprano a más tardío:
1. **`label_limit`** — se aplica durante el parseo, por muestra, antes de aceptarla. También falla el scrape.
2. **`sample_limit`** — se aplica tras parsear la respuesta, antes de añadir nada. Falla el scrape entero.
3. **`metric_relabel_configs` con `action: drop`** — corre tras el parseo, por muestra, descartando muestras camino al appender.
4. **`--storage.tsdb.retention.time`** — actúa mucho después de la ingestión, borrando bloques completos cuando caducan.

Los tres primeros reducen el coste de **ingestión** — CPU, memoria del bloque head, tamaño del índice, volumen del WAL — y por tanto también el almacenamiento. La retención reduce **solo el almacenamiento**: cada muestra descartada se parseó, se añadió, se indexó y se escribió en el WAL antes. Por eso la retención nunca es la respuesta a un problema de cardinalidad; la presión de memoria está en el bloque head, que la retención no toca.

**10.3**
1. **Coste.** `{__name__!=""}` es un selector que coincide con todas las series de la base de datos. Evaluarlo carga la lista completa de postings y toca todas las series, lo que en un servidor cargado puede tardar decenas de segundos, reservar gigabytes y — en el peor caso — provocar un OOM en el mismísimo servidor que intentas diagnosticar. `/api/v1/status/tsdb` lee estadísticas precalculadas del bloque head y responde en milisegundos.
2. **Corrección del alcance.** La consulta PromQL está acotada por `--query.lookback-delta` y refleja las series con una muestra reciente; `/status/tsdb` reporta el conteo real de series del bloque head y el verdadero top-N por nombre de métrica, par de labels y memoria. También te da `memoryInBytesByLabelName`, que PromQL no puede producir en absoluto — y ese suele ser el número que identifica al culpable más rápido.

**10.4**
- **`wal/`** — el write-ahead log. Cada muestra añadida y cada serie nueva se escribe aquí primero, en segmentos numerados de 128 MB, más directorios `checkpoint.NNNNNN` periódicos que compactan los segmentos más antiguos. Existe únicamente para que el bloque head en memoria pueda reconstruirse tras una caída.
- **`chunks_head/`** — chunks completados pertenecientes al bloque head aún abierto, volcados a disco para no tener que permanecer en RAM, pero que todavía no forman parte de un bloque persistente.
- **Directorios con nombre ULID** — bloques persistidos e inmutables, cada uno cubriendo un rango temporal fijo (2 horas inicialmente, luego fusionados por compactación en bloques progresivamente mayores). Cada uno contiene `chunks/`, `index`, `meta.json` y `tombstones`.

En un **reinicio sucio**: los bloques persistidos son inmutables y quedan intactos. `chunks_head/` y `wal/` se reproducen para reconstruir el bloque head — esta es la parte lenta del arranque de Prometheus (`Replaying WAL...` en los logs), y es por lo que un servidor con un bloque head grande puede tardar muchos minutos en quedar listo. Un segmento de WAL corrupto se trunca en el punto de la corrupción, perdiendo las muestras posteriores, y Prometheus registra el truncado y continúa.

**10.5** Editas `prometheus.yml`, envías SIGHUP (o haces POST a `/-/reload`). Prometheus lee y valida el archivo nuevo, lo encuentra inválido, **registra un error, pone `prometheus_config_last_reload_successful` a 0 y sigue ejecutando la configuración cargada previamente.** No sale, no deja de scrapear y no se degrada de ninguna forma visible.

Así que está corriendo la **configuración vieja** — la anterior a tu edición. Tu nuevo job de scrape nunca se scrapea, tu nueva alerting rule nunca dispara, tu corrección de un relabel roto no se aplica. Todos los dashboards se ven sanos. El fallo es invisible hasta que alguien pregunta por qué el servicio nuevo no tiene datos, lo que en la práctica ocurre durante el incidente sobre el que ese servicio nuevo debía avisarte. Por eso `prometheus_config_last_reload_successful == 0` pertenece a todo paquete de alertas, y por eso `promtool check config` pertenece a CI.

**10.6** Dos causas independientes:
1. **Las series existen históricamente pero ahora están stale** — el target desapareció, así que la última muestra es más antigua que `--query.lookback-delta` (5m). `/api/v1/series` buscó en una ventana de 1 hora y las encontró; la consulta instantánea mira solo 5 minutos atrás y no encuentra nada.
2. **Las series existen y son actuales, pero los matchers de labels de la consulta o un operador las eliminaron** — un error tipográfico en un valor de label, una cláusula `by (…)` que descartó una label necesaria para un join posterior, o un emparejamiento uno-a-uno que falla como en 4.2.

Para distinguirlas: consulta el **selector desnudo sin operadores**, `demo_http_requests_total`, como consulta instantánea.
- Vacío → causa 1 (staleness). Confírmalo con una consulta de rango `demo_http_requests_total[1h]` o `timestamp(demo_http_requests_total)` sobre un rango, y revisa `up` para ese job.
- No vacío → causa 2. Vuelve a añadir tu expresión un operador a la vez hasta que el resultado desaparezca; ese operador es el culpable.

**10.7** En lenguaje llano: **un grupo de reglas está tardando más en evaluarse que el intervalo al que se supone que debe ejecutarse.** El grupo no puede seguir su propio calendario.

El efecto acumulativo: Prometheus no ejecuta evaluaciones solapadas de un grupo, así que simplemente se salta las franjas perdidas (`prometheus_rule_group_iterations_missed_total` se incrementa). Cada alerting rule de ese grupo se evalúa, por tanto, con menos frecuencia que su intervalo configurado, lo que estira la duración de `for` en tiempo de reloj (ver 6.8) — una alerta con `for: 2m` en un grupo que en la práctica evalúa cada 90 segundos puede tardar cuatro minutos en disparar. Peor aún, las recording rules del grupo producen una serie con huecos y submuestreada, y cualquier alerta construida sobre esas series registradas hereda los huecos — reiniciando potencialmente su temporizador `for` cada vez que la serie se vuelve stale, de modo que nunca dispara.

**10.8** `delete_series` **no** elimina datos. Escribe **tombstones** — pequeños archivos dentro de cada bloque afectado que registran "las series que coinciden con X, en el rango temporal Y, están borradas". Las consultas consultan las tombstones y filtran las muestras coincidentes de los resultados, así que los datos se vuelven invisibles, pero los chunks y las entradas del índice permanecen en disco exactamente como estaban.

`clean_tombstones` obliga a Prometheus a **reescribir** los bloques afectados sin las series marcadas, que es lo que realmente recupera espacio. Es una reescritura cara de potencialmente muchos gigabytes, y solo toca los bloques persistidos — las series del bloque head no se recuperan hasta que se compactan fuera de él.

El borrado es la herramienta equivocada para un problema de cardinalidad porque la presión está **en la ingestión**, no en el disco: las series ofensivas se están creando de nuevo en cada scrape. Borrarlas libera espacio que se vuelve a consumir de inmediato, mientras que el bloque head, el índice y la huella de memoria se recuperan durante como mucho un intervalo de scrape. La solución debe impedir que las series se *creen*: `metric_relabel_configs` para descartar la label, `sample_limit` para fallar ruidosamente, o un cambio en la instrumentación.

**10.9**
1. **Inmediato — corta la hemorragia en la capa de consulta y consigue margen.** Identifica el job ofensivo desde `/api/v1/status/tsdb` (`seriesCountByMetricName`, `memoryInBytesByLabelName`) y **elimina ese job de scrape o añade una regla de drop en `metric_relabel_configs`, y recarga**. Recarga, no reinicies: un reinicio con un bloque head de 40 M de series significa una reproducción del WAL medida en decenas de minutos, durante los cuales estás ciego. Si ya está en bucle de OOM, quizá no tengas alternativa — en ese caso deja de lado `--storage.tsdb.head-chunks-write-queue-size` y empieza por el cambio de configuración, para que el estado reproducido no vuelva a explotar de inmediato.
2. **En el siguiente scrape — pon un suelo firme.** Añade `sample_limit` y `label_limit` al job ofensivo (y, como política, a todos los jobs). Esto convierte una ramificación silenciosa y sin cota en un ruidoso `up == 0` con `sample limit exceeded`, que es un aviso sobre el que puedes actuar en segundos en lugar de un OOM que diagnosticas en horas.
3. **Arquitectónico — deja de ser un solo servidor.** 40 M de series activas está más allá del punto en que un único Prometheus es la forma adecuada. Reparte por `hashmod` entre N servidores (ver 2.3), o pásate a un almacenamiento de largo plazo escalable horizontalmente (Thanos, Cortex/Mimir) con límites de series por inquilino aplicados en la ingestión. Combínalo con una alerta permanente de cardinalidad — la tasa de crecimiento de `prometheus_tsdb_head_series`, y `rate(scrape_series_added[10m])` por job — para que la próxima explosión se detecte con 100 k series nuevas, no con 40 M.

</details>