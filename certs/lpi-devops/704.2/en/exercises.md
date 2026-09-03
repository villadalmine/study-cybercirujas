# 704.2 — Prometheus Monitoring — Guided Exercises

**Certification:** LPI DevOps Tools Engineer — Exam 701-100, v2.0.0
**Objective weight:** 10 (the heaviest single objective in Topic 704)
**Level:** production / advanced
**Estimated time:** 4–6 hours

---

## What you must be able to do at the end

- Explain the pull-based architecture and every component in it (server, exporters, Pushgateway, Alertmanager, service discovery, Grafana) and justify why each exists.
- Read and write `prometheus.yml`, including `relabel_configs`, `metric_relabel_configs` and service discovery.
- Distinguish counter / gauge / histogram / summary and choose correctly when instrumenting.
- Write PromQL that survives a production review: correct `rate()` windows, correct aggregation before `histogram_quantile()`, correct vector matching.
- Write recording rules and alerting rules, unit-test them with `promtool`, and route them through Alertmanager.
- Diagnose the four failures you will actually meet: a target that will not scrape, a query that returns nothing, an alert that never fires, and a cardinality explosion.

---

## Lab environment

One Linux host with Docker Engine ≥ 24 and the Compose v2 plugin. Everything runs in containers so the lab is reproducible and disposable, but **every concept maps 1:1 to binaries under systemd** — the config files are identical.

Versions this lab was validated against (pin them; do not use `:latest` in a lab whose expected output you want to match):

| Component | Version | Port |
|---|---|---|
| Prometheus server | v3.1.0 | 9090 |
| Alertmanager | v0.28.0 | 9093 |
| node_exporter | v1.8.2 | 9100 |
| Pushgateway | v1.10.0 | 9091 |
| blackbox_exporter | v0.25.0 | 9115 |
| Grafana | 11.5.0 | 3000 |
| demo app (instrumented, written in Exercise 3) | — | 8000 |

> **Version note.** Prometheus 3.0 introduced behaviour changes you will see in this lab: range selectors are now **left-open** — `[5m]` at evaluation time `t` covers `(t-5m, t]`, where 2.x used `[t-5m, t]` — and the default web UI is the rewritten one. Everything else in this document behaves the same on 2.53 LTS.

---

## Exercise 0 — Bootstrap the stack and read the architecture off the wire

### Steps

1. Create the working tree:

   ```bash
   mkdir -p ~/prom-lab/{prometheus/{rules,targets},alertmanager,blackbox,grafana/provisioning/datasources,app}
   cd ~/prom-lab
   ```

2. Write the first `prometheus/prometheus.yml`. Read it before you paste it — every block below is a separate exam-relevant concept.

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

3. Write `docker-compose.yml`:

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

4. Alertmanager will refuse to start without a config. Write a minimal one now; you will replace it in Exercise 7:

   ```yaml
   # alertmanager/alertmanager.yml
   route:
     receiver: 'null'
   receivers:
     - name: 'null'
   ```

   And a blackbox config so that service starts too:

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

5. Start only what exists so far and verify:

   ```bash
   docker compose up -d prometheus node-exporter alertmanager pushgateway blackbox
   docker compose ps
   ```

6. Ask Prometheus what it thinks its targets are — via the API, not the UI. **The API is the thing you can script; learn it first.**

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | [.labels.job, .scrapeUrl, .health, .lastError] | @tsv'
   ```

   Expected output:

   ```
   node    http://node-exporter:9100/metrics    up
   prometheus      http://localhost:9090/metrics up
   ```

7. Confirm the runtime configuration Prometheus actually loaded (not the file you *think* it loaded):

   ```bash
   curl -s http://localhost:9090/api/v1/status/config | jq -r '.data.yaml' | head -20
   curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq
   ```

8. Look at the flow with your own eyes: scrape a target manually, exactly the way Prometheus does.

   ```bash
   curl -s http://localhost:9100/metrics | head -20
   curl -sI http://localhost:9100/metrics | grep -i content-type
   ```

   Expected `Content-Type`:

   ```
   Content-Type: text/plain; version=0.0.4; charset=utf-8
   ```

### Questions — Block 0

1. `node-exporter` is not listening on the Prometheus container's `localhost`, yet the `prometheus` job targets `localhost:9090` and it works. Why does `localhost` resolve correctly for one target and not the other, and what would happen if you wrote `localhost:9100` in the `node` job?
2. `external_labels` sets `cluster: lab-01`. Query `up` in the Prometheus UI. Is `cluster="lab-01"` present in the result? Explain precisely when external labels *are* applied.
3. `scrape_timeout` is 10s and `scrape_interval` is 15s. What is the failure mode if you set `scrape_timeout: 30s`, and what does Prometheus do about it at config-load time?
4. Nothing in `prometheus.yml` tells node_exporter to send data. Describe the direction of every arrow in this architecture (Prometheus ↔ exporter, Prometheus ↔ Alertmanager, job ↔ Pushgateway) and name the single component that inverts the pull model.
5. Which flag did you pass that makes `POST /-/reload` work, and what is the security consequence of enabling it on a Prometheus reachable from outside the host?

---

## Exercise 1 — The scrape: exposition format, synthetic metrics, and staleness

### Steps

1. Read a single metric family in raw exposition format:

   ```bash
   curl -s http://localhost:9100/metrics | grep -A3 '^# HELP node_filesystem_avail_bytes'
   ```

   Expected shape:

   ```
   # HELP node_filesystem_avail_bytes Filesystem space available to non-root users in bytes.
   # TYPE node_filesystem_avail_bytes gauge
   node_filesystem_avail_bytes{device="/dev/nvme0n1p3",fstype="ext4",mountpoint="/host/root"} 1.28449536e+11
   ```

2. Ask for OpenMetrics instead and compare:

   ```bash
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' \
     http://localhost:9100/metrics | tail -5
   ```

   Note the trailing `# EOF` line — it is mandatory in OpenMetrics and is what lets a parser detect a truncated response.

3. Now look at what Prometheus *adds* on its own. In the UI (`http://localhost:9090`) or via the API, run:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query={__name__=~"up|scrape_.+",job="node"}' \
     | jq -r '.data.result[] | "\(.metric.__name__)\t\(.value[1])"'
   ```

   Expected output:

   ```
   scrape_duration_seconds         0.0143921
   scrape_samples_post_metric_relabeling    1284
   scrape_samples_scraped          1284
   scrape_series_added             0
   up                              1
   ```

4. Break the target and watch the synthetic metrics react:

   ```bash
   docker compose stop node-exporter
   sleep 30
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="node"}' | jq -c '.data.result[].value'
   curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="node") | .lastError'
   ```

   Expected:

   ```
   ["1756900123.456","0"]
   Get "http://node-exporter:9100/metrics": dial tcp 172.19.0.4:9100: connect: connection refused
   ```

5. Now check what happened to `node_filesystem_avail_bytes` during the outage:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=count(node_filesystem_avail_bytes)' | jq -c '.data.result'
   ```

   Expected: `[]` — an empty result, **not** the last known value.

6. Restart it and confirm recovery:

   ```bash
   docker compose start node-exporter
   sleep 30
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up{job="node"}' | jq -c '.data.result[].value'
   ```

### Questions — Block 1

1. Where did `up`, `scrape_duration_seconds` and `scrape_samples_scraped` come from? They are not in the exporter's output — name the component that creates them and explain why an exporter must never expose a metric called `up`.
2. In step 5 the query returned an empty result immediately rather than the last scraped value. Name the mechanism and explain what Prometheus writes into the TSDB when a series disappears from a scrape.
3. What is `query.lookback-delta`, what is its default, and how does it interact with a job whose `scrape_interval` is `10m`?
4. `scrape_series_added` was `0` on a steady target. Under what circumstance would this metric be persistently non-zero, and what production problem does that indicate?
5. A colleague proposes alerting on `absent(node_filesystem_avail_bytes)` instead of `up{job="node"} == 0`. Give one scenario each where only the first fires, and where only the second fires.
6. Given the `# TYPE ... gauge` line, does Prometheus store the type in the TSDB? What is the practical consequence when you later write `rate()` against a gauge?

---

## Exercise 2 — Configuration, `promtool`, reloads, relabeling and service discovery

### Steps

1. **Never restart Prometheus to apply config.** First, break the config on purpose:

   ```bash
   cd ~/prom-lab
   cp prometheus/prometheus.yml /tmp/prometheus.yml.bak
   sed -i 's/scrape_interval:     15s/scrape_interval:     15/' prometheus/prometheus.yml
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   ```

   Expected output (non-zero exit status):

   ```
   Checking /etc/prometheus/prometheus.yml
     FAILED: parsing YAML file /etc/prometheus/prometheus.yml: unmarshal errors:
       line 3: cannot unmarshal !!int `15` into model.Duration
   ```

2. Restore, then convert the static `node` job to **file-based service discovery**, which is what you use when a CMDB, Ansible or Terraform owns the inventory:

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

   Replace the `node` job with:

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

3. Validate and hot-reload:

   ```bash
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo "reload ok"
   ```

   Expected:

   ```
   Checking /etc/prometheus/prometheus.yml
    SUCCESS: 1 rule files found
    ...
   reload ok
   ```

4. Verify the relabeling actually took effect, and inspect the *discovered* labels before relabeling:

   ```bash
   curl -s http://localhost:9090/api/v1/targets | \
     jq -r '.data.activeTargets[] | select(.labels.job=="node") | {labels, discoveredLabels}'
   ```

   Expected (abridged):

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

5. Prove file SD is live — no reload required:

   ```bash
   jq '.[0].labels.role = "compute-a"' prometheus/targets/node.json > /tmp/n.json && mv /tmp/n.json prometheus/targets/node.json
   sleep 35
   curl -s http://localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job=="node") | .labels.role'
   ```

6. Test a relabel rule in isolation, without touching the server, using the config-file linter's sibling command:

   ```bash
   docker compose exec prometheus promtool check service-discovery /etc/prometheus/prometheus.yml node
   ```

7. Add a second job that demonstrates `keep` and `labelmap`, plus `honor_labels`:

   ```yaml
     - job_name: pushgateway
       honor_labels: true          # pushed job/instance labels win over the target's
       static_configs:
         - targets: ['pushgateway:9091']
   ```

   Reload again.

### Questions — Block 2

1. `relabel_configs` and `metric_relabel_configs` both appear in the `node` job. State exactly when each runs, what input each receives, and which one can prevent a target from being scraped at all.
2. `__address__`, `__scheme__`, `__metrics_path__` and `__meta_filepath` all start with underscores. What happens to labels beginning with `__` after relabeling finishes, and which one is the exception that becomes a real label by default?
3. You want to shard 400 targets across 4 Prometheus servers with no central coordination. Which relabel `action` does this, and write the rule for shard 2 of 4.
4. With `honor_labels: true` on the Pushgateway job, what value will the `instance` label have on a metric pushed under `/metrics/job/backup/instance/db-01`? What would it be with `honor_labels: false`?
5. `metric_relabel_configs` drops `node_scrape_collector_.*`. Does this reduce the number reported by `scrape_samples_scraped`, `scrape_samples_post_metric_relabeling`, or both? Explain.
6. Why is `promtool check config` in a CI pipeline strictly better than `docker compose restart prometheus`, in terms of both blast radius and detection time?

---

## Exercise 3 — Metric types and the instrumentation decision

### Steps

1. Build a deliberately instrumented application that exposes all four metric types plus an *info* metric.

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

2. Add the service to `docker-compose.yml`:

   ```yaml
     demo-app:
       build: ./app
       container_name: demo-app
       ports:
         - '8000:8000'
       restart: unless-stopped
   ```

   and the scrape job to `prometheus.yml`:

   ```yaml
     - job_name: demo-app
       static_configs:
         - targets: ['demo-app:8000']
           labels:
             env: lab
             service: orders-api
   ```

3. Bring it up, validate, reload:

   ```bash
   docker compose up -d --build demo-app
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   sleep 60
   ```

4. Inspect what each type actually looks like on the wire:

   ```bash
   curl -s http://localhost:8000/metrics | grep -E '^demo_http_request_duration_seconds' | head -14
   ```

   Expected:

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

   Expected:

   ```
   demo_http_response_size_bytes_count{path="/"} 888.0
   demo_http_response_size_bytes_sum{path="/"} 3639296.4...
   ```

5. Count the time series each type costs:

   ```bash
   for m in demo_http_requests_total demo_http_requests_in_flight \
            demo_http_request_duration_seconds_bucket demo_http_response_size_bytes_count; do
     printf '%-45s ' "$m"
     curl -sG http://localhost:9090/api/v1/query --data-urlencode "query=count($m)" \
       | jq -r '.data.result[0].value[1] // "0"'
   done
   ```

6. Now the central PromQL lesson. Run these four queries in the UI and compare the graphs over a 15-minute range:

   ```promql
   demo_http_requests_total{path="/api/orders"}
   rate(demo_http_requests_total{path="/api/orders"}[5m])
   irate(demo_http_requests_total{path="/api/orders"}[5m])
   increase(demo_http_requests_total{path="/api/orders"}[5m])
   ```

7. Force a counter reset and observe that `rate()` handles it:

   ```bash
   docker compose restart demo-app
   ```

   Wait 5 minutes, then graph raw `demo_http_requests_total` and `rate(demo_http_requests_total[5m])` together over the last 15 minutes.

8. Verify the rate-window rule of thumb empirically:

   ```promql
   rate(demo_http_requests_total{path="/"}[15s])
   rate(demo_http_requests_total{path="/"}[1m])
   rate(demo_http_requests_total{path="/"}[5m])
   ```

### Questions — Block 3

1. `demo_http_requests_total` is a counter and `demo_work_queue_depth` is a gauge. Give the one-sentence rule that decides which type to use, and explain why applying `rate()` to the gauge is meaningless.
2. In step 4, the histogram has 11 `_bucket` series per `path` plus `_sum` and `_count`. Compute the total series cost of `demo_http_request_duration_seconds` for 4 paths across 30 application replicas. Now do the same for `demo_http_response_size_bytes` (a summary with no quantiles configured). What is the cardinality trade-off you just quantified?
3. `demo_http_request_duration_seconds_bucket{le="0.05"}` is `851` while `{le="0.025"}` is `682`. Are these buckets cumulative or disjoint? How many observations fell in the interval `(0.025, 0.05]`?
4. Why can you not compute a meaningful 99th percentile across 30 replicas from a *summary*, but you can from a *histogram*? Name the property that makes the difference.
5. In step 6, `increase(...[5m])` returned a non-integer value such as `1247.83` even though a counter only ever increments by whole numbers. Explain the algorithm that produces this.
6. State the rule of thumb relating the `rate()` range to `scrape_interval`, and describe exactly what you observed with `[15s]` in step 8 and why.
7. After the restart in step 7, `rate()` did not spike to a huge negative or positive value. What does `rate()` assume when sample N+1 is smaller than sample N, and what is the one situation where that assumption produces a wrong answer?
8. `demo_build_info` is a gauge whose value is always `1`. What is this pattern called, why is the value irrelevant, and what would go wrong if you instead put `version` as a label on `demo_http_requests_total`?
9. `irate()` produced a much spikier graph than `rate()`. Give one legitimate use for `irate()` and state why it must never appear in an alerting rule.

---

## Exercise 4 — Aggregation, vector matching, and correct percentiles

### Steps

1. Aggregate across labels. Run each and read the result cardinality:

   ```promql
   sum(rate(demo_http_requests_total[5m]))
   sum by (path) (rate(demo_http_requests_total[5m]))
   sum without (status, method) (rate(demo_http_requests_total[5m]))
   topk(3, sum by (path) (rate(demo_http_requests_total[5m])))
   ```

2. Compute an error ratio — the single most common real-world PromQL expression:

   ```promql
   sum by (path) (rate(demo_http_requests_total{status=~"5.."}[5m]))
     /
   sum by (path) (rate(demo_http_requests_total[5m]))
   ```

   Expected: a value near `0.04` for `/api/orders` and **no series at all** for the other paths.

3. Fix the missing-series problem with `or`:

   ```promql
   (
     sum by (path) (rate(demo_http_requests_total{status=~"5.."}[5m]))
     or
     sum by (path) (rate(demo_http_requests_total[5m])) * 0
   )
     /
   sum by (path) (rate(demo_http_requests_total[5m]))
   ```

4. Percentiles — the wrong way and the right way. Run both:

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

5. Confirm the bucket boundary effect. The p99 for `/api/orders` should land between two of your configured bucket edges:

   ```bash
   curl -sG http://localhost:9090/api/v1/query --data-urlencode \
     'query=histogram_quantile(0.99, sum by (le,path) (rate(demo_http_request_duration_seconds_bucket[5m])))' \
     | jq -r '.data.result[] | "\(.metric.path)\t\(.value[1])"'
   ```

   Expected (values will differ):

   ```
   /               0.02478...
   /api/orders     1.9147...
   /api/users      0.02391...
   /healthz        0.02402...
   ```

6. Compute the *average* latency, which needs no buckets at all:

   ```promql
   sum by (path) (rate(demo_http_request_duration_seconds_sum[5m]))
     /
   sum by (path) (rate(demo_http_request_duration_seconds_count[5m]))
   ```

7. Vector matching with an info metric — attach the build version to a rate:

   ```promql
   sum by (instance) (rate(demo_http_requests_total[5m]))
     * on (instance) group_left(version)
   demo_build_info
   ```

8. Deliberately trigger a matching error to learn the message:

   ```promql
   rate(demo_http_requests_total[5m]) / demo_build_info
   ```

   Expected error:

   ```
   found duplicate series for the match group {instance="demo-app:8000", job="demo-app", ...}
   on the right hand-side of the operation: ...
   many-to-many matching not allowed: matching labels must be unique on one side
   ```

   (If `demo_build_info` carries only one series, you will instead get an empty result — because the label sets do not match. Fix it with `on (instance)`.)

9. Predict the future, a technique you will reuse in Exercise 6:

   ```promql
   predict_linear(node_filesystem_avail_bytes{mountpoint="/host/root"}[6h], 24 * 3600)
   ```

### Questions — Block 4

1. `sum by (path)` and `sum without (status, method)` gave different label sets on the output. Which one preserves `job` and `instance`, and why does that matter when the result feeds an alerting rule whose annotation references `{{ $labels.instance }}`?
2. In step 2 the ratio produced no series for `/healthz`. Explain the vector-matching rule that caused this, then explain in one sentence why the `or ... * 0` idiom in step 3 fixes it.
3. Why is `histogram_quantile(0.99, rate(..._bucket[5m]))` without aggregation wrong even on a *single* replica when the metric has a `path` label? What does the function require of its input vector?
4. `avg(histogram_quantile(0.99, ...))` across instances is a classic review rejection. State the mathematical reason percentiles are not averageable.
5. Your p99 for `/api/orders` came back as roughly `1.91`, and your bucket edges are `1.0` and `2.5`. Where exactly does that number come from? What would `histogram_quantile` return if the 99th percentile fell into the `+Inf` bucket?
6. In step 6 you computed a mean latency from `_sum / _count`. Give one production question that the mean answers better than p99, and one where the mean actively lies.
7. In step 7, explain each of the three parts: `on (instance)`, `group_left`, and `(version)`. What changes if you write `group_right` instead?
8. `predict_linear(...[6h], 24 * 3600)` returns bytes. What model does it fit, and name one filesystem behaviour that makes its output badly wrong.

---

## Exercise 5 — Recording rules and unit-testing them with `promtool`

### Steps

1. Write recording rules using the conventional `level:metric:operations` naming:

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

2. Lint the rule file, then reload:

   ```bash
   docker compose exec prometheus promtool check rules /etc/prometheus/rules/recording.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   ```

   Expected:

   ```
   Checking /etc/prometheus/rules/recording.yml
     SUCCESS: 4 rules found
   ```

3. Verify the rules are evaluating, and how fast:

   ```bash
   curl -s http://localhost:9090/api/v1/rules | jq -r \
     '.data.groups[] | .name as $g | .rules[] | [$g, .name, .health, (.evaluationTime|tostring)] | @tsv'
   ```

   Expected:

   ```
   demo-app.recording  path:demo_http_requests:rate5m           ok  0.001842
   demo-app.recording  path:demo_http_requests_errors:rate5m    ok  0.002104
   demo-app.recording  path:demo_http_requests_errors:ratio5m   ok  0.000391
   demo-app.recording  path:demo_http_request_duration_seconds:p99_5m  ok  0.003118
   ```

4. Prove that rules inside a group evaluate **in order**: `path:demo_http_requests_errors:rate5m` references the rule declared above it. Query it:

   ```bash
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=path:demo_http_requests_errors:ratio5m' \
     | jq -r '.data.result[] | "\(.metric.path)\t\(.value[1])"'
   ```

5. Now unit-test the rules **with no running Prometheus and no real data**. This is the part most engineers never learn and every production repo should have.

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

6. Run the tests:

   ```bash
   docker compose exec -w /etc/prometheus/rules prometheus \
     promtool test rules recording_test.yml
   ```

   Expected:

   ```
   Unit Testing:  recording_test.yml
     SUCCESS
   ```

7. Break it on purpose to see a failure report — change `value: 0.05` to `value: 0.5` and re-run:

   ```
   Unit Testing:  recording_test.yml
     FAILED:
       expr: "path:demo_http_requests_errors:ratio5m", time: 10m0s,
           exp: {job="demo-app", path="/api/orders", service="orders-api"} 0.5,
           got: {job="demo-app", path="/api/orders", service="orders-api"} 0.05
   ```

   Restore it.

8. Measure what recording rules bought you. Compare query cost before and after:

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

### Questions — Block 5

1. `path:demo_http_requests_errors:rate5m` uses the output of a rule declared earlier in the same group. Is that safe? State the rule about evaluation order *within* a group versus *between* groups, and what would happen if the two rules were in different groups.
2. The group sets `interval: 15s` and the expressions use `[5m]`. What is the relationship these two numbers must satisfy, and what breaks if `interval` is `10m` while the range is `[5m]`?
3. Explain the naming convention `path:demo_http_requests_errors:ratio5m` — what does each of the three colon-separated parts mean, and why does the convention forbid a colon in a directly-instrumented metric name?
4. In the unit test, `values: '0+570x10'` expands to a specific sample series. Write out the first four values, and explain why the resulting `rate` is exactly `10`.
5. Why must `rule_files` in the test file be a *relative* path, and why did the command use `-w /etc/prometheus/rules`?
6. `limit: 500` is set on the group. What does Prometheus do when a rule in that group would produce 501 series, and what does the rule's `health` field become?
7. `evaluation_time` for the p99 rule was ~3 ms in this lab. On a real server this can reach seconds. Name the two metrics you would alert on to detect rule evaluation falling behind.
8. Recording rules speed up dashboards. Name the one thing they cannot do that querying the raw buckets can — i.e. what did you permanently give up by pre-aggregating away the `le` dimension?

---

## Exercise 6 — Alerting rules: the lifecycle from `expr` to `firing`

### Steps

1. Write alerting rules that exercise every part of the lifecycle:

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

2. Lint and reload:

   ```bash
   docker compose exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   ```

3. Watch the lifecycle. `HighErrorRate` should already be `firing` (the app produces ~4% errors on `/api/orders`):

   ```bash
   curl -s http://localhost:9090/api/v1/alerts | jq -r \
     '.data.alerts[] | [.labels.alertname, .state, .labels.severity, (.value|tostring)] | @tsv'
   ```

   Expected:

   ```
   HighErrorRate   firing  warning 0.0413...
   ```

4. Now watch `pending` with your own eyes. Stop a target and poll every 20 seconds:

   ```bash
   docker compose stop node-exporter
   for i in $(seq 1 9); do
     date +%T
     curl -s http://localhost:9090/api/v1/alerts | jq -r \
       '.data.alerts[] | select(.labels.alertname=="TargetDown") | "\(.state)\t\(.activeAt)"'
     sleep 20
   done
   ```

   Expected: `pending` for ~2 minutes, then `firing`.

5. Observe the alert state as a queryable time series:

   ```promql
   ALERTS{alertname="TargetDown"}
   ALERTS_FOR_STATE{alertname="TargetDown"}
   ```

6. Restart the target and observe `keep_firing_for` on the *other* alert by throttling the demo app instead:

   ```bash
   docker compose start node-exporter
   ```

7. Verify template rendering without waiting for a notification:

   ```bash
   curl -s http://localhost:9090/api/v1/alerts \
     | jq -r '.data.alerts[] | .annotations.summary'
   ```

   Expected:

   ```
   /api/orders error ratio is 4.13%
   ```

8. Unit-test an alerting rule — the lifecycle, not just the expression:

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

### Questions — Block 6

1. Draw the three states of an alert and name the exact condition that moves it between each pair. Where does `for` act, and where does `keep_firing_for` act?
2. In step 8, `eval_time: 4m` with `up` going to 0 at minute 3 was expected to produce an alert. Was that alert `pending` or `firing`? Does `alert_rule_test`'s `exp_alerts` distinguish the two, and how do you assert on `pending` specifically?
3. `TargetDown` uses `up == 0`. Explain why `absent(up)` would be a *different* and mostly useless alert, and give the one case where an `absent()`-based alert is the only thing that works.
4. `HighErrorRate` has `keep_firing_for: 5m`. Describe a concrete flapping scenario this prevents and what the on-call engineer would experience without it.
5. In `NodeFilesystemWillFillIn24h`, why are the two conditions joined with `and` rather than multiplied or written as a single comparison? What does `and` do to the label sets of the two operands?
6. `{{ $value }}` renders `0.0413` and `{{ $value | humanizePercentage }}` renders `4.13%`. Where is this template evaluated — Prometheus or Alertmanager — and what is the practical consequence for `$labels` availability in Alertmanager templates?
7. The `capacity.rules` group has `interval: 1m` while `slo.rules` has `15s`. Give two independent reasons to slow down a group's evaluation interval.
8. An alert has `for: 2m` and the group's `interval` is `5m`. How long can it actually take between the condition becoming true and the alert firing? Generalise the formula.

---

## Exercise 7 — Alertmanager: routing, grouping, inhibition, silences

### Steps

1. Replace the placeholder config with a production-shaped one:

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

2. Add a sink so you can actually see the payloads:

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

3. Validate and reload Alertmanager (it also supports `POST /-/reload` and `SIGHUP`):

   ```bash
   docker compose up -d webhook-sink
   docker compose exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
   curl -sf -X POST http://localhost:9093/-/reload && echo ok
   ```

   Expected:

   ```
   Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
   Found:
    - global config
    - route
    - 2 inhibit rules
    - 4 receivers
    - 0 templates
   ```

4. **Test the routing tree without generating a single alert** — this is the single highest-value Alertmanager skill:

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

   Expected:

   ```
   orders-webhook
   critical-webhook
   default-webhook
   ```

5. Visualise the whole tree:

   ```bash
   docker compose exec alertmanager amtool config routes show \
     --config.file=/etc/alertmanager/alertmanager.yml
   ```

6. Inject a synthetic alert directly into the Alertmanager API — no Prometheus involved:

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

7. Silence it, then verify the silence matched:

   ```bash
   docker compose exec alertmanager amtool silence add \
     --alertmanager.url=http://localhost:9093 \
     --duration=1h --comment='Planned maintenance, ticket OPS-4412' \
     alertname=SyntheticPage cluster=lab-01

   docker compose exec alertmanager amtool silence query --alertmanager.url=http://localhost:9093
   docker compose exec alertmanager amtool alert query --alertmanager.url=http://localhost:9093 --silenced
   ```

8. Verify Prometheus knows where to send alerts:

   ```bash
   curl -s http://localhost:9090/api/v1/alertmanagers | jq
   ```

   Expected:

   ```json
   {
     "status": "success",
     "data": {
       "activeAlertmanagers": [{"url": "http://alertmanager:9093/api/v2/alerts"}],
       "droppedAlertmanagers": []
     }
   }
   ```

9. Inspect a real notification payload and find the `external_labels` from Exercise 0:

   ```bash
   docker compose logs webhook-sink | grep -o '"cluster":"[^"]*"' | tail -3
   ```

### Questions — Block 7

1. Explain `group_wait`, `group_interval` and `repeat_interval` in terms of the *first* notification, the *amended* notification, and the *reminder*. Which one would you shorten to reduce time-to-page, and which one would you lengthen to reduce alert fatigue?
2. `group_by: ['alertname', 'cluster', 'service']` — what happens operationally if you set `group_by: ['...']` (the special catch-all) versus omitting `group_by` entirely versus `group_by: []`?
3. The `critical` route sets `continue: false` (the default). Trace what happens to an alert with `severity="critical", team="orders"`: which receivers get it, and how does the answer change with `continue: true`?
4. State the three components of an inhibit rule and explain precisely what `equal: ['instance']` guarantees. What catastrophic mistake do you make if you omit `equal` from the first inhibit rule?
5. A silence and an inhibition both suppress a notification. Name two operational differences between them (who creates them, how long they last, what appears in the UI).
6. In step 9 the payload contained `cluster: lab-01`, which you configured in Exercise 0 under `external_labels`. Which component attached it, at what moment, and why is `replica: prom-a` a problem for grouping when you run two identical Prometheus servers?
7. `resolve_timeout: 5m` is a global. Which alerts does it apply to — those sent by Prometheus, or those pushed via the API — and why?
8. You are paged at 03:00 for an alert whose `runbook_url` annotation is missing. Name the two config surfaces (one in Prometheus, one in Alertmanager) where that field should have been enforced or rendered.

---

## Exercise 8 — Multi-target exporters and the Pushgateway

### Steps

1. Add the blackbox exporter as a **multi-target** scrape job. Read the relabel chain carefully — this pattern appears on the exam and in every real deployment:

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

2. Reload and inspect:

   ```bash
   docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
   curl -sf -X POST http://localhost:9090/-/reload && echo ok
   sleep 20
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=probe_success' \
     | jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1])"'
   ```

   Expected:

   ```
   http://demo-app:8000/metrics    1
   http://does-not-exist.invalid/  0
   http://prometheus:9090/-/healthy        1
   ```

3. Reproduce the probe by hand — exactly what Prometheus did:

   ```bash
   curl -s 'http://localhost:9115/probe?module=http_2xx&target=http://demo-app:8000/metrics&debug=true' | head -40
   ```

4. Now the Pushgateway. Push a batch-job result:

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

5. Verify what the Pushgateway now exposes and what Prometheus scraped:

   ```bash
   curl -s http://localhost:9091/metrics | grep -E '^(backup_|push_)' 
   curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=backup_duration_seconds' | jq -c '.data.result'
   ```

   Expected (note `job` and `instance` came from the *push* URL, not the scrape target):

   ```json
   [{"metric":{"__name__":"backup_duration_seconds","instance":"db-01","job":"nightly_backup"},"value":["1756901234.5","412.7"]}]
   ```

6. Prove the Pushgateway is a **cache, not a queue**. Stop pushing and observe:

   ```bash
   sleep 120
   curl -sG http://localhost:9090/api/v1/query \
     --data-urlencode 'query=time() - backup_last_success_timestamp_seconds' \
     | jq -r '.data.result[0].value[1]'
   ```

   The metric is still there, and the age keeps growing. That is the point.

7. Write the alert that makes a Pushgateway useful:

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

8. Clean up a group — the operation everyone forgets:

   ```bash
   curl -X DELETE http://localhost:9091/metrics/job/nightly_backup/instance/db-01
   curl -s http://localhost:9091/metrics | grep -c '^backup_' || echo "0 (deleted)"
   ```

### Questions — Block 8

1. In the `blackbox-http` job, `__address__` is rewritten twice — once implicitly as the source of `__param_target`, and once explicitly to `blackbox:9115`. Explain what would break if you omitted rule 3, and what would break if you omitted rule 2.
2. `probe_success` for `does-not-exist.invalid` is `0`, but `up` for that same target is `1`. Explain why, and state which of the two you must alert on to detect a broken website.
3. Name the property that makes blackbox_exporter a "multi-target exporter" and give one other exporter from the ecosystem that follows the same pattern.
4. Step 5 showed `job="nightly_backup"` and `instance="db-01"` even though the scrape target is `pushgateway:9091`. Which single config option made this possible, and what would the labels have been without it?
5. The Prometheus documentation says the Pushgateway is for *service-level* batch jobs and explicitly not for machine-level metrics or as a general push gateway. Give the three failure modes that justify this: what happens to `up`, what happens when the job disappears, and what happens to a metric after the job is decommissioned.
6. `BackupNeverRan` uses `absent(...)`. Why can this alert never carry the `instance` label of the missing backup, and what is the standard workaround when you need per-instance absence alerts?
7. `--persistence.file` was configured. What is lost on a Pushgateway restart without it, and does that change the correctness of `BackupStale`?
8. A developer wants to push an application's request counter to the Pushgateway every 15 seconds "so Prometheus doesn't have to reach into our network". Give the correct architectural answer and name the two supported alternatives.

---

## Exercise 9 — Grafana integration

### Steps

1. Provision the datasource as code — never click it in:

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

2. Start Grafana and confirm the datasource loaded:

   ```bash
   docker compose up -d grafana
   sleep 15
   curl -s -u admin:admin http://localhost:3000/api/datasources | jq -r '.[] | "\(.name)\t\(.type)\t\(.url)"'
   ```

   Expected:

   ```
   Prometheus      prometheus      http://prometheus:9090
   ```

3. Test the datasource end to end through Grafana's proxy:

   ```bash
   DS_UID=prom-lab
   curl -s -u admin:admin -H 'Content-Type: application/json' \
     "http://localhost:3000/api/datasources/uid/${DS_UID}/resources/api/v1/query?query=up" \
     | jq -r '.data.result[] | "\(.metric.job)\t\(.value[1])"'
   ```

4. Open `http://localhost:3000` (admin/admin) and build one panel by hand:
   - **Panel A — Request rate.** Query: `sum by (path) (rate(demo_http_requests_total[$__rate_interval]))`, legend `{{path}}`, unit `reqps`.
   - **Panel B — Error ratio.** Query: `path:demo_http_requests_errors:ratio5m`, unit `percentunit`, thresholds at `0.02` (yellow) and `0.05` (red).
   - **Panel C — Latency heat.** Three queries with legends `p50 {{path}}`, `p90 {{path}}`, `p99 {{path}}`:
     ```promql
     histogram_quantile(0.50, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     histogram_quantile(0.90, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     histogram_quantile(0.99, sum by (le, path) (rate(demo_http_request_duration_seconds_bucket[$__rate_interval])))
     ```
   - **Panel D — Target health.** Query `up`, visualization *Stat*, value mappings `0 → DOWN (red)`, `1 → UP (green)`.

5. Add a template variable so the dashboard works for any path. Dashboard settings → Variables → New:
   - Name `path`, Type *Query*, Datasource `Prometheus`
   - Query type *Label values*, Label `path`, Metric `demo_http_requests_total`
   - Enable *Multi-value* and *Include All option*

   Then change Panel A's query to:

   ```promql
   sum by (path) (rate(demo_http_requests_total{path=~"$path"}[$__rate_interval]))
   ```

6. Compare interval variables directly. Create a text/stat panel with each of these and change the dashboard time range from *last 1 hour* to *last 7 days*:

   ```promql
   rate(demo_http_requests_total{path="/"}[$__interval])
   rate(demo_http_requests_total{path="/"}[$__rate_interval])
   rate(demo_http_requests_total{path="/"}[5m])
   ```

7. Export the dashboard as JSON and check it into the repo:

   ```bash
   curl -s -u admin:admin http://localhost:3000/api/search?query= | jq -r '.[] | .uid'
   curl -s -u admin:admin http://localhost:3000/api/dashboards/uid/<UID> \
     | jq '.dashboard' > grafana/dashboards/demo-app.json
   ```

### Questions — Block 9

1. `access: proxy` versus `access: direct` (browser). Which one did you configure, and give the two reasons `proxy` is correct for a Prometheus that is not exposed to the internet.
2. `timeInterval: 15s` is set on the datasource. Which Grafana variable does it feed, and what is the formula Grafana uses to compute `$__rate_interval` from it?
3. In step 6, `rate(...[$__interval])` broke when you zoomed out to 7 days but `[$__rate_interval]` did not. Explain the failure precisely — what happens to `rate()` when the range is smaller than the scrape interval versus much larger?
4. Why is the hard-coded `[5m]` neither wrong nor ideal? State the one scenario where hard-coding is the *correct* choice.
5. `httpMethod: POST` is configured. What limit does this raise, and when will you first hit it?
6. Grafana can also send alerts (Grafana Alerting). Give two reasons to keep alerting rules in Prometheus and Alertmanager rather than in Grafana, in a setup where both exist.
7. The variable query used *Label values* on `path` for metric `demo_http_requests_total`. What API endpoint does Grafana call, and why is querying label values for a metric cheaper than `count by (path) (demo_http_requests_total)`?
8. Panel B queries the recording rule `path:demo_http_requests_errors:ratio5m` while Panel C queries raw buckets. Which panel survives a 30-day time range on a large server, and why?

---

## Exercise 10 — Production diagnostics: cardinality, TSDB, and the four classic failures

### Steps

1. **Inspect the head block.** This endpoint answers "what is filling my Prometheus?" in one call:

   ```bash
   curl -s http://localhost:9090/api/v1/status/tsdb | jq '{
     headStats: .data.headStats,
     topMetricNames: [.data.seriesCountByMetricName[:5][] | "\(.name)=\(.value)"],
     topLabelPairs: [.data.seriesCountByLabelValuePair[:5][] | "\(.name)=\(.value)"],
     memoryByLabel: [.data.memoryInBytesByLabelName[:5][] | "\(.name)=\(.value)"]
   }'
   ```

   Expected (abridged):

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

2. **Cause a cardinality explosion on purpose**, then find it. Add a bad job that fans out a unique label per scrape by abusing `params`:

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

   In a real incident the equivalent is a `user_id`, `request_id`, `session_id`, `pod_name` or full URL path arriving as a label.

3. **Defend at the scrape.** Add the limits every production job should carry:

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

   Reload, then set `sample_limit: 5` temporarily and observe:

   ```bash
   curl -s http://localhost:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | select(.labels.job=="demo-app") | "\(.health)\t\(.lastError)"'
   ```

   Expected:

   ```
   down    sample limit exceeded
   ```

   Restore `sample_limit: 5000`.

4. **Find the offending label** with PromQL, on a metric you suspect:

   ```promql
   # How many series does each metric name have? (expensive — prefer /status/tsdb)
   topk(10, count by (__name__) ({__name__!=""}))

   # Which label is the culprit within one metric family?
   count(count by (path)   (demo_http_requests_total))
   count(count by (status) (demo_http_requests_total))
   count(count by (method) (demo_http_requests_total))
   ```

5. **Analyse the on-disk TSDB** offline:

   ```bash
   docker compose exec prometheus promtool tsdb list /prometheus
   docker compose exec prometheus promtool tsdb analyze /prometheus | head -40
   ```

   Expected (abridged):

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

6. **Inspect the storage layout** so the block/WAL vocabulary is concrete:

   ```bash
   docker compose exec prometheus sh -c 'ls -la /prometheus && ls /prometheus/wal | head'
   ```

   Expected:

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

7. **Monitor Prometheus with Prometheus.** These are the metrics you page on:

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

8. **The four classic failures.** For each, run the diagnostic and record the answer:

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

9. **Surgical deletion** (requires `--web.enable-admin-api`, which you enabled in Exercise 0):

   ```bash
   curl -s -X POST -g \
     'http://localhost:9090/api/v1/admin/tsdb/delete_series?match[]={job="cardinality-bomb"}'
   curl -s -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones
   ```

10. Tear the lab down when you are finished:

    ```bash
    docker compose down -v
    ```

### Questions — Block 10

1. `sample_limit` was exceeded and the target went `down`. Is the scrape *partially* ingested or discarded entirely? What is the value of `up` for that target, and why is that the safest possible behaviour?
2. Rank these four defences by where they act in the pipeline, earliest first: `sample_limit`, `metric_relabel_configs` with `action: drop`, `--storage.tsdb.retention.time`, `label_limit`. Which of them reduces *ingestion* cost and which only reduces *storage* cost?
3. `topk(10, count by (__name__)({__name__!=""}))` answers the same question as `/api/v1/status/tsdb`. Give the two reasons to prefer the API endpoint on a loaded server.
4. Explain what lives in `wal/`, in `chunks_head/`, and in the ULID-named directories. What happens to each on an unclean restart?
5. `prometheus_config_last_reload_successful == 0` is called "the silent killer". Describe the exact failure sequence: you edit `prometheus.yml`, send SIGHUP, and Prometheus keeps running. What is it running?
6. In diagnostic (b), `/api/v1/series` returned a result but the instant query returned nothing. Name two independent causes, and the query you would run to distinguish them.
7. `prometheus_rule_group_last_duration_seconds > on (rule_group) prometheus_rule_group_interval_seconds` — describe in plain language what firing means, and the compounding effect on alert latency.
8. `delete_series` succeeded but disk usage did not drop. Explain tombstones, what `clean_tombstones` does, and why deletion is not the right tool for a cardinality problem in the first place.
9. You have 30 seconds on a bridge call. A single Prometheus is at 40 M active series and OOM-killing. Name three actions in priority order — one immediate, one at the next scrape, one architectural.

---

## Sources

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
<summary><strong>Answers — click to expand</strong></summary>

## Block 0 — Architecture

**0.1** `localhost` is resolved inside the *Prometheus container's* network namespace. Prometheus itself listens on `:9090` in that namespace, so `localhost:9090` works. `node-exporter` runs in a different container with a different namespace, so `localhost:9100` inside the Prometheus container would find nothing and the scrape would fail with `dial tcp 127.0.0.1:9100: connect: connection refused`. Cross-container addressing uses the Compose service name, which Docker's embedded DNS resolves. On bare metal under systemd this distinction disappears — both processes share one namespace and `localhost:9100` is correct.

**0.2** No. `cluster="lab-01"` is **not** present on `up` when queried locally. `external_labels` are applied only on data leaving this server: alerts sent to Alertmanager, `remote_write`, and `/federate`. Their purpose is to identify *which* Prometheus produced a datum once several servers' data are pooled. Applying them locally would be redundant and would break the identity between a rule's expression and its stored series.

**0.3** `scrape_timeout` must be less than or equal to `scrape_interval`. If it is larger, a slow target can still be in-flight when the next scrape is due, producing overlapping scrapes and out-of-order or duplicated samples. Prometheus refuses to load such a config: `promtool check config` fails with `scrape timeout greater than scrape interval for scrape config with job name "..."`, and the server logs the error and keeps the previous config on reload (or exits at startup).

**0.4**
- Prometheus → exporter: **pull**, HTTP GET on `/metrics`. Prometheus initiates.
- Prometheus → Alertmanager: **push**, HTTP POST to `/api/v2/alerts`. Prometheus initiates.
- batch job → Pushgateway: **push**, HTTP POST/PUT. The job initiates.
- Prometheus → Pushgateway: **pull**, exactly like any other exporter.
- Grafana → Prometheus: **pull**, HTTP query API.
- Service discovery → Prometheus: Prometheus polls the SD source (file, DNS, Kubernetes API…).

The component that inverts the pull model is the **Pushgateway** — and only for the first hop; Prometheus still pulls from it.

**0.5** `--web.enable-lifecycle`. It exposes `POST /-/reload` and `POST /-/quit` without authentication. On an exposed Prometheus, anyone who can reach port 9090 can shut the server down or force a reload. Prometheus has no built-in authentication for these endpoints by default — put it behind a reverse proxy with authentication, bind it to a management interface, or configure `--web.config.file` with basic auth and TLS.

---

## Block 1 — The scrape

**1.1** The **Prometheus server** synthesises them at the end of every scrape. `up` is `1` when the HTTP request succeeded *and* the body parsed, `0` otherwise. An exporter must never expose `up` because the server would overwrite it (or, with `honor_labels`/conflicting semantics, produce a series that lies): if the exporter is unreachable it cannot expose anything, so a self-reported `up` is definitionally incapable of reporting its own failure.

**1.2** **Staleness handling** (Prometheus ≥ 2.0). When a series present in scrape N is absent in scrape N+1, Prometheus appends an explicit **staleness marker** — a special NaN value — at the timestamp of scrape N+1. Queries that encounter a staleness marker return no value for that series from that point forward. The same happens when a target disappears from service discovery, or when the whole scrape fails (all its series get markers).

**1.3** `--query.lookback-delta`, default **5m**. When evaluating an instant query at time `t`, Prometheus looks back up to 5 minutes for the most recent sample of each series. With a `10m` scrape interval, a series will appear to vanish for 5 minutes out of every 10 — graphs and alerts will flap. Either raise `--query.lookback-delta` above the scrape interval, or (better) do not scrape at intervals longer than ~2 minutes; that is what recording rules and `_over_time` functions are for.

**1.4** `scrape_series_added` counts series in this scrape that were **not** present in the previous one. A persistently non-zero value means the target is emitting new series on every scrape — a **cardinality explosion in progress**, typically caused by an unbounded label such as `request_id`, a full URL path, a timestamp, or a customer identifier. This is the earliest available signal, well before `prometheus_tsdb_head_series` visibly bends.

**1.5**
- Only `absent()` fires: the exporter is up and answering, but a collector was disabled or errored, so the specific metric family disappeared while `up` stays `1`.
- Only `up == 0` fires: the target is unreachable *and* another instance in the same job still exposes `node_filesystem_avail_bytes`, so `absent()` — which is about the *series* existing anywhere — stays silent.

The two are complementary: `up == 0` for per-target reachability, `absent()` for "this whole signal is gone from the system".

**1.6** No. The `# TYPE` line is consumed by the parser but the TSDB stores only `(labels, timestamp, float)` — the type is not persisted (native histograms are the exception, and only for the histogram type itself). The consequence is that PromQL will happily let you write `rate()` on a gauge and return a plausible-looking number that is semantically meaningless: `rate()` assumes monotonicity, so every decrease of the gauge is misread as a counter reset and silently dropped, producing a systematically inflated result.

---

## Block 2 — Configuration and relabeling

**2.1**
- `relabel_configs` runs **once per target, before the scrape**, on the target's discovered label set (all the `__meta_*`, `__address__`, `__scheme__`, `__metrics_path__`, plus any static labels). It decides *whether and how* to scrape. An `action: drop` or a failing `action: keep` here removes the target entirely — it is never contacted, and it appears under `droppedTargets`.
- `metric_relabel_configs` runs **after every scrape, once per sample**, on the parsed metric's label set (including `__name__`). It cannot prevent a scrape; it can only discard or rewrite samples on their way into the TSDB.

Mnemonic: relabel shapes the *target*, metric_relabel shapes the *data*.

**2.2** Labels beginning with `__` are **discarded after relabeling completes** — they are internal and never stored. The exception is `__name__`, which becomes the metric name and is a real (special) label. `__address__` is also not discarded so much as *consumed*: it determines the connection endpoint and, if `instance` was not explicitly set by relabeling, it is copied into `instance` by default.

**2.3** `action: hashmod`, combined with a `keep`:

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

Each of the four servers ships an identical config differing only in the `regex`. `hashmod` is deterministic (MD5 of the concatenated source label values, mod `modulus`), so the four servers partition the target set with no coordination and no overlap. Note `__tmp_shard` starts with `__` so it disappears afterwards.

**2.4** With `honor_labels: true`, `instance="db-01"` — the labels present in the *scraped data* (which the Pushgateway derives from the push URL path) win. With `honor_labels: false` (the default), the target's labels win: `instance` would become `pushgateway:9091` and the pushed value would be preserved but renamed to `exported_instance="db-01"`. Likewise `job` would become `pushgateway` and `exported_job="nightly_backup"`. This is why `honor_labels: true` is mandatory on a Pushgateway job.

**2.5** Only `scrape_samples_post_metric_relabeling`. `scrape_samples_scraped` counts what came off the wire, before any metric relabeling. The gap between the two is exactly what your `metric_relabel_configs` discarded — which makes `scrape_samples_scraped - scrape_samples_post_metric_relabeling` a useful sanity check that your drop rules are doing what you think.

**2.6** Blast radius: `promtool check config` is a pure function of the file — it touches no running process, opens no TSDB, and drops no scrape. A restart re-reads the config *and* replays the WAL, blanks the head block's in-memory state, resets all `for:` timers on alerts (an alert mid-`pending` starts counting from zero), and creates a gap in every series for the duration of the restart. Detection time: `promtool` fails in CI, before merge, on a developer's screen; a bad restart fails in production, at whatever hour the deploy ran, and the only symptom may be `prometheus_config_last_reload_successful == 0` on a server that is otherwise happily serving stale config.

---

## Block 3 — Metric types

**3.1** Use a **counter** for a value that only ever increases (and resets to zero on process restart) — you care about its *rate*. Use a **gauge** for a value that can go up and down — you care about its *current value*. `rate()` on a gauge is meaningless because `rate()` treats every decrease as a counter reset and adds the pre-reset value back in, producing a number with no physical interpretation.

**3.2**
- Histogram: `(11 buckets + _sum + _count) × 4 paths × 30 replicas` = `13 × 4 × 30` = **1560 series**.
- Summary with no quantiles: `(_sum + _count) × 4 paths × 30 replicas` = `2 × 4 × 30` = **240 series**.

The trade-off: the histogram costs **6.5×** the storage and gives you aggregatable, arbitrary-quantile, cross-replica latency analysis. The summary is cheap but gives you only mean and count (and, if quantiles were configured, per-replica quantiles you cannot combine).

**3.3** **Cumulative.** Each `_bucket{le="X"}` counts every observation `≤ X`. The `+Inf` bucket therefore always equals `_count`. Observations in `(0.025, 0.05]` = `851 − 682` = **169**.

**3.4** A histogram stores raw *bucket counts*, which are counters and therefore **additive**: summing bucket `le="0.05"` across 30 replicas gives the true global count of observations ≤ 0.05, and the quantile can be interpolated from the global bucket counts. A summary stores *already-computed quantiles* — the p99 value itself. There is no arithmetic that recovers a global p99 from 30 local p99s; you would need the underlying distribution, which the summary threw away. The property is **aggregatability**: counts aggregate, quantiles do not.

**3.5** `increase(v[t])` is defined as `rate(v[t]) * t`, and `rate()` **extrapolates**. The first and last samples inside the range almost never sit exactly on the window boundaries, so Prometheus computes the slope from the samples it has and extends it to the edges of the window (clamping the extrapolation to at most half a sample interval on each side, and refusing to extrapolate a counter below zero). The result is the *estimated* increase over exactly `t` seconds, which is a real number. This is intentional — it makes `rate()` stable under jitter — and it is why `increase()` output should never be presented as an exact event count.

**3.6** **Rule of thumb: the range must be at least 4× the scrape interval** (many teams use 4–5×). With `scrape_interval: 15s`:
- `[15s]` frequently contains only **one** sample. `rate()` requires at least two points to compute a slope, so it returns **no data** for those evaluation steps — the graph is empty or full of holes.
- `[1m]` contains ~4 samples: it works, but a single missed scrape drops you to 3 and the result becomes noisy.
- `[5m]` contains ~20 samples: it tolerates missed scrapes and target restarts, at the cost of smoothing over short spikes.

**3.7** `rate()` (and `increase()`, and `irate()`) assume that a decrease can only mean a **counter reset**, so they add the last pre-reset value to the difference — i.e. they assume the counter went from `v_n` up to some value and then restarted from 0. The assumption is wrong when a *genuine* decrease occurs that is not a reset: the classic case is a metric that is really a gauge but was declared a counter, and the subtler case is a load balancer or aggregating proxy whose "counter" is a sum over a fluctuating set of backends — when a backend leaves, the sum drops, `rate()` reads a reset, and reports a large phantom increase.

**3.8** The **info metric** (or "machine-readable metadata") pattern. The value is always `1` and is irrelevant because the information lives entirely in the labels; the constant value exists only so the series can participate in a `group_left` join. Putting `version` directly on `demo_http_requests_total` would multiply that metric's series count by the number of versions ever deployed, and — worse — every deploy would create a *new* series and break `rate()` continuity across the deploy boundary, exactly when you most need the graph to be readable.

**3.9** `irate()` uses only the **last two samples** in the range, giving an instantaneous rate that reveals short spikes a 5-minute average would flatten. Legitimate use: interactive high-resolution graphing when you are actively debugging a spiky workload. It must never appear in an alerting rule because it is maximally sensitive to a single scrape's jitter or one missed sample — one anomalous data point can trip or clear the alert, and alerting rules are evaluated at a fixed interval where that noise is not visible to a human who could discount it.

---

## Block 4 — PromQL

**4.1** `sum by (path)` **drops** everything except `path` — no `job`, no `instance`. `sum without (status, method)` **keeps** everything except the two named labels, so `job`, `instance`, `path`, `env` and `service` all survive. This matters enormously for alerting: an annotation referencing `{{ $labels.instance }}` renders empty if the expression used `by (path)`, and the resulting page tells the on-call engineer *what* is wrong but not *where*. As a rule, prefer `without` in alerting expressions, or explicitly list every label you need in the `by` clause.

**4.2** Binary operators between two instant vectors use **one-to-one matching on the full label set** by default: a sample on the left is paired with a sample on the right only if *every* label matches. `/healthz` produces no `status=~"5.."` series at all, so the left-hand side has no `path="/healthz"` element, so there is nothing to pair with the right-hand side and no output series is produced. The `or` idiom fixes it by supplying a zero-valued series for every path present on the right but missing on the left: `or` returns the left operand's series plus, for label sets that appear only on the right, the right operand's series — here deliberately multiplied by `0`.

**4.3** `histogram_quantile()` requires an input vector in which the `le` label is the **only** dimension that varies within each output group; it groups the input by all labels *except* `le` and reads each group as one complete cumulative histogram. Even on a single replica, an un-aggregated `rate(..._bucket[5m])` carries `path`, `job` and `instance` — which is actually fine for grouping — but the real problem is that any *other* stray dimension (an extra label, or several replicas) silently splits or merges histograms incorrectly, and if you later aggregate away `le` first the function has nothing to interpolate over. The safe, universal form is `sum by (le, <dimensions you want>) (rate(..._bucket[5m]))`: it makes the grouping explicit rather than accidental.

**4.4** Percentiles are **order statistics, not linear functionals**. The mean of the 99th percentiles of N distributions is not the 99th percentile of the pooled distribution — averaging assumes the quantity is additive under a weighted sum, and quantiles are not. Concretely: nine replicas with p99 = 100 ms and one replica with p99 = 10 s average to 1.09 s, a number that describes no request anyone made, while the true pooled p99 depends on the relative request volumes and could be anywhere between 100 ms and 10 s.

**4.5** **Linear interpolation inside the bucket.** `histogram_quantile` finds the bucket in which the target rank falls — here `(1.0, 2.5]` — and interpolates linearly between the bucket's lower and upper bounds according to how far into that bucket the rank lies. So `1.91` means "about 61% of the way into the 1.0–2.5 bucket". The accuracy of the answer is therefore bounded entirely by your bucket layout, not by the number of observations: with edges at 1.0 and 2.5, the p99 is only known to within 1.5 seconds.

If the quantile falls in the `+Inf` bucket, there is no upper bound to interpolate to, and `histogram_quantile` returns the **upper bound of the highest finite bucket** (here `5.0`). This is why a p99 pinned exactly at your largest bucket edge is a signal that your buckets are too narrow, not that latency is stable. (Symmetrically, if the lowest bucket has `le > 0` and the quantile falls into it, interpolation is done between `0` and that bound.)

**4.6** The mean is better for **capacity and cost** questions: total time spent serving requests, throughput × mean latency = concurrency (Little's law), CPU-seconds per request. The mean actively lies about **user experience** on any long-tailed latency distribution — which is all of them. A service where 99% of requests take 5 ms and 1% take 5 s has a mean of ~55 ms, which looks excellent and completely conceals that one user in a hundred is timing out.

**4.7**
- `on (instance)` — restrict matching to the `instance` label only; ignore every other label when pairing left-hand and right-hand samples.
- `group_left` — this is a **many-to-one** match: many samples on the *left* may pair with one sample on the right. The cardinality of the result follows the left side.
- `(version)` — copy the `version` label from the right-hand (the "one") side onto the result. Without this list, the join filters and scales but copies nothing.

`group_right` inverts it: one-to-many, the *right* side becomes the "many" side and drives the result cardinality, and the labels listed are copied from the left. You would write the expression the other way round: `demo_build_info * on (instance) group_right(...) sum by (instance) (rate(...))`.

**4.8** `predict_linear` fits a **simple linear regression (ordinary least squares)** over all samples in the range and extrapolates the fitted line forward by the given number of seconds. It goes badly wrong on filesystems because real disk usage is not linear: log rotation and `tmpwatch` produce sawtooths that a straight line reads as a steady trend; a single large file deletion inside the window flips the slope; and a filesystem that is 99% full and stable produces a slope near zero and never alerts. Mitigations: pair it with an absolute threshold (as the exercise does with `< 0.20`), use a long enough range (6h, not 15m), and add `for:` so a transient slope does not page.

---

## Block 5 — Recording rules

**5.1** Yes, it is safe and it is the intended design. **Rules within a group are evaluated sequentially, in the order they are written**, against a single consistent evaluation timestamp — so a rule may depend on the output of any rule declared above it in the same group. **Different groups are evaluated independently and concurrently.** If the two rules were in different groups, the dependent rule would read whatever value the other group happened to have written on its *previous* run, which is stale by up to one evaluation interval, or missing entirely for the first evaluation after a restart. Chained rules must live in the same group, in dependency order.

**5.2** The group's `interval` must be **shorter than the range** used in the expressions — ideally at most half, and never longer. With `interval: 15s` and `[5m]`, consecutive evaluations overlap heavily, which is what makes the recorded series smooth and gap-free. With `interval: 10m` and `[5m]`, each evaluation covers 5 minutes and then 5 minutes pass uncovered: half of every source sample is never seen by any evaluation, and the recorded series is an undersampled, aliased view of the original.

**5.3** `level:metric:operations`:
- `level` — the aggregation level / the labels the series is grouped by (`path`, or `job`, `instance`, `cluster`…).
- `metric` — the underlying metric name the rule is derived from.
- `operations` — the list of operations applied, most recent last (`rate5m`, `ratio5m`, `sum:rate5m`).

The colon is **reserved for recording rules by convention** and must never appear in a directly-instrumented metric name. That convention is what lets a reader (and a linter) tell at a glance whether a series came off an exporter or out of a rule, and it means client libraries can safely reject colons in metric names.

**5.4** `'0+570x10'` means "start at 0, add 570, repeat 10 more times" — 11 samples in total:

```
0, 570, 1140, 1710, ... , 5700
```

at 1-minute intervals (the test's `interval: 1m`). The counter increases by 570 per minute; combined with the `500`-error series at 30 per minute, the total is 600 per minute = **10 per second**. `rate(...[5m])` over a perfectly linear counter returns exactly the slope in per-second units, so the answer is exactly `10`.

**5.5** `promtool test rules` resolves the paths in `rule_files` **relative to the current working directory**, not relative to the test file. `docker compose exec -w /etc/prometheus/rules` sets the working directory inside the container to where `recording.yml` lives, so `rule_files: ['recording.yml']` resolves. Using an absolute path inside the test file would work too but would tie the test to the container's mount layout and break when the same test runs in CI outside a container.

**5.6** The rule's evaluation **fails**: Prometheus discards the entire result of that evaluation (no partial write), marks the rule's `health` as `err`, populates `lastError` with a message about the limit being exceeded, and increments `prometheus_rule_evaluation_failures_total`. The recorded series simply gets no new sample for that interval, so downstream queries and alerts see it go stale. `limit` is a safety valve against a rule that unexpectedly fans out, not a truncation mechanism.

**5.7**
- `prometheus_rule_group_last_duration_seconds` compared against `prometheus_rule_group_interval_seconds` — if evaluation takes longer than the interval, the group is falling behind by construction.
- `prometheus_rule_group_iterations_missed_total` (rate > 0 means evaluations were skipped) and `prometheus_rule_evaluation_failures_total` for the error path.

**5.8** You gave up **re-quantisation**. Once the recorded series is `p99`, you can never ask that data for p50, p90, p999, or "what fraction of requests were under 250 ms" — those questions need the `le` dimension, which the recording rule collapsed. The standard mitigation is to record the *aggregated bucket rates* (keeping `le`) rather than the quantile itself: `record: path:demo_http_request_duration_seconds_bucket:rate5m` with `sum by (le, path) (rate(...))`. You get most of the query-time speedup and keep the ability to compute any quantile later.

---

## Block 6 — Alerting rules

**6.1**
- **inactive → pending**: the `expr` returns at least one sample for a given label set at an evaluation.
- **pending → firing**: the `expr` has returned that same label set continuously for at least `for` duration. If the expression stops matching at any point during `for`, the alert returns to `inactive` and the timer resets.
- **firing → inactive**: the `expr` stops returning that label set (immediately, unless `keep_firing_for` is set, in which case the alert stays firing for that additional duration after the expression stops matching).

`for` acts on the **entry** into firing (a debounce against transients). `keep_firing_for` acts on the **exit** from firing (a debounce against flapping/resolution churn). If `for` is omitted or `0`, an alert goes straight from inactive to firing.

**6.2** At `eval_time: 4m` the target has been down since minute 3 (one evaluation), and `for: 2m` has not elapsed, so the alert is **pending**. `alert_rule_test`'s `exp_alerts` reports **only firing alerts** — pending alerts are not included. Therefore the test as written would fail with "expected 1 alert, got 0". To assert on the pending state you either move `eval_time` past `for` (e.g. `6m`) to assert firing, or you assert on the `ALERTS` series directly via `promql_expr_test` with `expr: ALERTS{alertname="TargetDown", alertstate="pending"}`. This is exactly the class of bug rule unit tests exist to catch.

**6.3** `absent(up)` returns a value only when **no `up` series exists anywhere in the entire TSDB** — i.e. when Prometheus is scraping literally nothing. Since Prometheus always scrapes itself, that condition is essentially never true, so the alert is dead code. `up == 0` is per-target and is what you want.

`absent()` is the only thing that works when the thing you are watching **has no target at all**: a job whose service discovery returned zero targets (so there is no `up` series to be `0`), a metric that should be pushed to the Pushgateway and never was, or a federated/remote-written signal that stopped arriving. In all three cases there is nothing to compare to zero — the series simply does not exist, and only `absent()` (or `absent_over_time()`) can express that.

**6.4** The demo app's error ratio hovers around 4% with real jitter; over a 3-minute window it can dip below the 2% threshold for one evaluation and come straight back. Without `keep_firing_for`, the alert resolves, Alertmanager sends a `[RESOLVED]` notification, and 15 seconds later the alert re-enters `pending`, waits 3 minutes, fires again, and Alertmanager sends a fresh notification. The on-call engineer receives an endless stream of resolve/fire pairs for a condition that never actually improved — and worse, learns to ignore that alert. `keep_firing_for: 5m` holds the alert firing across those dips, so one incident produces one notification.

**6.5** `and` is a **set operator**: it returns the elements of the left-hand vector for which a sample with **exactly the same label set** exists in the right-hand vector. Multiplication would produce a numeric product with no meaning (a ratio times a predicted byte count), and a comparison operator returns the left side's *value*, not a boolean, so it cannot express "both conditions hold".

The label-set requirement is why both operands carry the identical `fstype!~...` selector: both sides produce series labelled `{device, fstype, mountpoint, instance, job}`, so they pair one-to-one. If the selectors differed, or if one side were aggregated, nothing would match and the alert could never fire. The result carries the left side's labels and values — so `$value` in the annotation is the *ratio*, not the prediction.

**6.6** Annotation and label templates are evaluated by **Prometheus**, at the moment the alert is sent to Alertmanager. Alertmanager receives them as already-rendered strings.

The consequence is that in Alertmanager's own notification templates, `$labels` and `$value` do not exist. Alertmanager sees a list of alerts, each with `.Labels`, `.Annotations`, `.StartsAt`, `.GeneratorURL` — so you write `{{ .CommonLabels.severity }}` or `{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}`. Anything you want available in a notification must have been rendered into a label or annotation by Prometheus first.

**6.7**
1. **Cost.** The expression is expensive — `predict_linear` over a `[6h]` range reads six hours of samples per evaluation per series. Running that every 15 seconds is wasteful when the input barely moves.
2. **Signal timescale.** A filesystem-fill prediction is meaningful over hours; evaluating it four times a minute adds no information, only noise and CPU. Matching the evaluation interval to the timescale of the phenomenon is a correctness argument, not just an efficiency one.

(A third, related reason: reducing evaluation load on a group keeps the *fast* groups — the ones that actually need to page quickly — from queueing behind it.)

**6.8** The alert can take up to **`for` + `interval`** ≈ 7 minutes, and in the worst case a little more. The rule is evaluated only every 5 minutes, so the condition can become true immediately after an evaluation and go unnoticed for nearly 5 minutes; the next evaluation moves the alert to `pending`; `for: 2m` then requires the condition to still hold at a *subsequent* evaluation — and the next evaluation is 5 minutes later, not 2. So firing happens at the second evaluation after the condition became true.

General formula: worst-case detection latency ≈ `scrape_interval + interval + ceil(for / interval) × interval`, plus Alertmanager's `group_wait`. The practical rule: **`for` should be a multiple of the group `interval`, and the group `interval` should be much smaller than `for`.**

---

## Block 7 — Alertmanager

**7.1**
- **`group_wait`** — after the *first* alert of a brand-new group arrives, wait this long before notifying, so that sibling alerts firing at the same moment are batched into one notification. Default 30s.
- **`group_interval`** — once a group has been notified, wait at least this long before sending an *amended* notification about alerts newly added to (or resolved within) that same group. Default 5m.
- **`repeat_interval`** — how long before re-sending a notification for a group whose contents have **not** changed and which is still firing. Default 4h.

To reduce time-to-page, shorten **`group_wait`** (the critical route in this exercise sets it to 10s). To reduce alert fatigue, lengthen **`repeat_interval`** — that is the reminder, and it is the one that wakes people up for something they already know about.

**7.2**
- `group_by: ['alertname', 'cluster', 'service']` — one group (and therefore one notification thread) per distinct combination of those three labels.
- **Omitting `group_by`** on a child route inherits the parent's value. Omitting it on the top-level `route` means grouping by nothing — equivalent to `group_by: []`.
- **`group_by: []`** — no grouping: **every alert gets its own notification.** A 200-node outage produces 200 pages.
- **`group_by: ['...']`** — the literal three-dot string is a special value meaning "group by **all** labels, disabling aggregation". Every distinct label set is its own group. This is what you use when a downstream system (a ticketing integration) needs one notification per alert instance, and it is explicitly documented as not recommended for human recipients.

**7.3** Routing walks the tree depth-first, taking the **first child route whose matchers all match**; if none match, the alert stays at the current node's receiver. An alert with `severity="critical", team="orders"` matches the first child (`severity = "critical"`) and, because `continue: false`, routing **stops there** — it goes to `critical-webhook` only. The `orders-webhook` route is never evaluated, even though `team="orders"` would have matched it (it would not, actually — that route also requires `severity =~ "warning|info"` — but the point stands for a route that would match).

With `continue: true` on the critical route, evaluation continues to the *sibling* routes after matching, so the alert would be delivered to `critical-webhook` **and** to any subsequent matching sibling. `continue` is how you implement "page the on-call *and* mirror to the team channel".

**7.4** The three components:
- `source_matchers` — which alerts, when firing, do the inhibiting.
- `target_matchers` — which alerts get suppressed.
- `equal` — the list of labels that must have **identical values** on the source and target alert for the inhibition to apply.

`equal: ['instance']` guarantees that a `TargetDown` on `node-a` only suppresses warnings **about `node-a`**. Omit `equal`, and a single `TargetDown` anywhere in the fleet suppresses **every warning-severity alert in the entire system** — you have built a mechanism whereby one dead machine blinds you to every other problem. Missing `equal` is the single most dangerous Alertmanager misconfiguration.

**7.5**
1. **Who and when.** A silence is created by a **human** (or automation) through the API/UI/`amtool`, has an explicit expiry, and carries a comment and an author. An inhibition is a **standing config rule** evaluated automatically and lasting exactly as long as the source alert fires.
2. **Visibility and intent.** A silenced alert is shown in the UI as silenced, with who silenced it and why, and the silence itself is a first-class object you can list, extend or expire. An inhibited alert is shown as inhibited, with no author — the "why" lives in `alertmanager.yml`. Silences express "I know, I'm working on it / it's planned maintenance"; inhibitions express "this alert is a structural consequence of that other alert and is never independently actionable".

**7.6** **Prometheus** attached it, at the moment it built the alert notification to POST to Alertmanager — `external_labels` are applied on egress (see 0.2).

`replica: prom-a` is a problem in an HA pair because the two servers produce alerts whose label sets differ **only** in that label. Alertmanager's deduplication works by exact label-set equality, so `prom-a`'s and `prom-b`'s copies of the same alert are seen as two distinct alerts, land in two distinct groups, and generate two notifications. The standard fix is to strip the replica label before sending — `alert_relabel_configs` in the `alerting` block with `action: labeldrop, regex: replica` — while keeping it for `remote_write` and federation, where it is genuinely needed.

**7.7** It applies to alerts that were **pushed via the API without an `endsAt` timestamp**. Alerts sent by Prometheus always carry an explicit `endsAt` (Prometheus re-sends firing alerts periodically and sets `endsAt` to a point slightly in the future; when it stops re-sending, `endsAt` passes and the alert resolves), so they do not depend on `resolve_timeout`. A hand-pushed alert with no `endsAt` would otherwise fire forever, so Alertmanager expires it `resolve_timeout` after the last time it was seen. This is precisely why the alert you injected in step 6 eventually disappeared on its own.

**7.8**
1. **Prometheus:** the alerting rule's `annotations` block — `runbook_url` is an annotation and should be mandatory. Enforce it in CI with a linter over the rule files (`promtool check rules` will not do this for you; a small script or `pint` will).
2. **Alertmanager:** the receiver's notification **template**, which decides what actually reaches the human. A template that renders `{{ .Annotations.runbook_url }}` and falls back to a visible "NO RUNBOOK — fix the alerting rule" string turns a silent omission into a loud one.

---

## Block 8 — Multi-target exporters and Pushgateway

**8.1**
- **Without rule 3**, `__address__` remains the probed URL, so Prometheus would try to connect *directly* to `demo-app:8000` (and to `does-not-exist.invalid`) and GET `/probe?module=http_2xx&target=...` there. The demo app does not serve `/probe`, so the scrape fails with a 404; the invalid host fails to resolve. The blackbox exporter is never contacted at all.
- **Without rule 2**, the probe still works — Prometheus talks to `blackbox:9115` and passes the right `target` parameter — but every resulting series carries `instance="blackbox:9115"`. All three probes collide into one label set, so the last scrape wins and you effectively monitor one arbitrary target. Rule 2 is what preserves *which* thing was probed.

**8.2** `up` describes the health of the **scrape of the exporter**: Prometheus successfully reached `blackbox:9115`, got a 200, and parsed the body — so `up=1`. `probe_success` describes the health of the **probe the exporter performed on your behalf**: the DNS lookup for `does-not-exist.invalid` failed, so `probe_success=0`. You must alert on **`probe_success == 0`** to detect a broken website; `up == 0` on a blackbox job means the blackbox exporter itself is broken, which is a different (and also worth alerting on) condition.

**8.3** A **multi-target exporter** does not expose metrics about itself; it exposes a `/probe`-style endpoint that takes the thing to inspect as a **query parameter**, so one exporter instance serves an unbounded number of monitored targets. Other exporters following the pattern: `snmp_exporter`, `blackbox_exporter`, and the `ssl_exporter`. (The `mysqld_exporter` and `postgres_exporter` support a multi-target mode as well in recent versions.)

**8.4** `honor_labels: true` on the `pushgateway` job. The Pushgateway derives `job` and `instance` from the push URL path and exposes them as ordinary labels on the metric; `honor_labels: true` tells Prometheus not to overwrite them with the target's own. Without it, the labels would have been `job="pushgateway"`, `instance="pushgateway:9091"`, with the pushed values preserved as `exported_job="nightly_backup"` and `exported_instance="db-01"` — which still works but breaks every query and alert written against the natural names.

**8.5**
1. **`up` becomes useless as a health signal.** `up` now reflects the Pushgateway's availability, not the batch job's. The job can have been dead for a week while `up=1`.
2. **When the job disappears, its metrics do not.** The Pushgateway has no notion of the pusher going away — no staleness markers, no expiry. There is nothing to alert on except metric *age*, which is why `BackupStale` compares `time()` against a pushed timestamp.
3. **After decommissioning, the metrics persist forever.** They must be explicitly `DELETE`d. A retired host keeps reporting a stale "last successful backup" until somebody notices, and with `--persistence.file` configured it survives restarts too.

Additionally, the Pushgateway is a **single point of failure and a single bottleneck** for everything routed through it — one more reason it is scoped to service-level batch jobs.

**8.6** `absent()` returns a series labelled with whatever labels appear as **equality matchers in its argument's selector** — here `{job="nightly_backup"}` — and nothing else. It cannot know `instance="db-01"` because that value is precisely what is missing; there is no series from which to read it.

The standard workaround is to alert against a **known inventory** rather than against absence in the abstract: join the metric to an info/inventory series that always exists (`up`, a `..._info` metric, or a static series generated by a recording rule) and alert on the join producing no match — e.g. `expected_backup_targets unless on (instance) backup_last_success_timestamp_seconds`. In Kubernetes the same job is done by `kube_*` inventory metrics from kube-state-metrics.

**8.7** Without `--persistence.file`, the Pushgateway keeps everything **in memory only**: a restart loses every pushed metric until each batch job next runs, which for a nightly backup means up to 24 hours of "the metric does not exist".

It does not change the *correctness* of `BackupStale` — that alert compares a timestamp and cannot fire on a series that is absent — but it changes which alert fires: after a restart, `BackupStale` goes silent (no series) and `BackupNeverRan` (the `absent()` alert) takes over. That is exactly why both alerts exist as a pair; either one alone leaves a blind spot.

**8.8** The correct answer is: **do not use the Pushgateway for this.** A long-running service should be scraped, and the Pushgateway is documented as being for service-level batch jobs only — pushing every 15 seconds reintroduces every failure mode in 8.5 while gaining nothing.

The two supported alternatives:
1. **Make the service scrapeable across the network boundary** — expose `/metrics` and let Prometheus reach it, or run a Prometheus inside their network that scrapes locally and **federates** (`/federate`) or **`remote_write`s** the aggregated result out. This is the normal answer to "you can't reach into our network".
2. **`remote_write` / OTLP ingest** — if the data genuinely must be pushed, push it as a first-class remote-write stream (Prometheus 3.x accepts remote-write with `--web.enable-remote-write-receiver`, and OTLP with `--web.enable-otlp-receiver`), which preserves timestamps, staleness and per-instance identity in a way the Pushgateway cannot.

---

## Block 9 — Grafana

**9.1** You configured **`access: proxy`**: Grafana's backend makes the HTTP request to Prometheus and relays the response to the browser. Two reasons it is correct here:
1. **Reachability.** `http://prometheus:9090` is a Docker-network name that only resolves inside the Compose network. The user's browser cannot resolve it; Grafana's backend can. Same argument for a Prometheus on a private VLAN or behind a VPN.
2. **Credentials and exposure.** Any authentication (basic auth, TLS client cert, an API token) is held server-side by Grafana and never shipped to the browser, and Prometheus never needs to be exposed to end users or to have CORS configured.

(`access: direct` / browser mode is deprecated in modern Grafana for exactly these reasons.)

**9.2** It feeds Grafana's notion of the datasource's **scrape interval**, which sets the floor for `$__interval` and is the input to `$__rate_interval`. The formula is:

```
$__rate_interval = max($__interval + scrape_interval, 4 × scrape_interval)
```

where `scrape_interval` is `timeInterval` from the datasource (or the panel's *Min step* if set). With `timeInterval: 15s` and a zoomed-in panel where `$__interval` is `15s`, `$__rate_interval` is `max(30s, 60s)` = `60s`.

**9.3** `$__interval` is computed purely from the panel's pixel width and time range — it is the *step* of the query, not the scrape interval. Zoomed in to a few minutes on a wide panel, `$__interval` can be `5s` or `10s`, which is **smaller than the 15 s scrape interval**: the range selector then usually contains fewer than two samples, `rate()` cannot compute a slope, and the panel goes empty or full of gaps. (Zoomed *out* to 7 days, `$__interval` becomes large — minutes or hours — and `rate()` still works but heavily smooths.)

`$__rate_interval` exists precisely to solve this: its `max(..., 4 × scrape_interval)` term guarantees the range never drops below four scrape intervals, so there are always enough samples no matter how far you zoom in, and its `$__interval + scrape_interval` term keeps it growing sensibly as you zoom out.

**9.4** A hard-coded `[5m]` is **always correct** — it never has too few samples — but it is not *ideal* because it ignores the panel's resolution: zoomed out to 30 days it over-smooths (you cannot see anything shorter than 5 minutes anyway, so no loss), and zoomed in to 2 minutes it shows a 5-minute average on a 2-minute window, hiding exactly the detail you zoomed in to see.

Hard-coding is the **correct** choice when the panel must match an alerting rule or a recording rule exactly. If your alert fires on `rate(x[5m]) > 0.02`, the dashboard panel used to investigate that alert must use `[5m]` too — otherwise the graph and the alert disagree and the on-call engineer loses trust in both.

**9.5** It raises the **URL length limit**. With `GET`, the PromQL expression travels in the query string, and long expressions — big recording-rule chains, regex selectors with many alternatives, dashboards with template variables expanded to dozens of values — hit the server's or proxy's URL length cap (commonly 2 KB–8 KB) and fail with `414 Request-URI Too Large`. With `POST`, the expression goes in the request body. You will first hit it on a panel with a multi-value template variable that expands to a long `=~"a|b|c|..."` regex — the classic "the dashboard works for one pod and breaks when I select All".

**9.6**
1. **Availability of the alerting path.** Prometheus + Alertmanager alerting keeps working when Grafana is down, being upgraded, or having a database problem. Grafana is a visualisation layer; making it a dependency of your paging path adds a component whose failure is silent.
2. **Alerts as code, next to the rules they depend on.** Prometheus alerting rules live in YAML in the same repository as the recording rules they reference, are validated by `promtool check rules`, and are **unit-testable** with `promtool test rules` — none of which has a clean equivalent for Grafana-managed alerts. They also share Alertmanager's routing, grouping, inhibition and silencing with every other alert source, so there is exactly one place to silence during maintenance.

(A third: Grafana alerting evaluates by querying Prometheus over HTTP, adding network and query-layer failure modes between the data and the decision.)

**9.7** Grafana calls **`GET /api/v1/label/path/values`** with a `match[]` parameter for the metric selector and the dashboard's time range.

It is cheaper because it is answered from the TSDB's **inverted index (postings)** — the set of distinct values for a label name is precomputed index metadata, and no samples are read. `count by (path) (demo_http_requests_total)` is a full query: it selects every matching series, reads a sample from each within the lookback window, groups and counts. On a metric with tens of thousands of series the difference is milliseconds versus seconds, and it is paid on every dashboard load and every variable refresh.

**9.8** **Panel B**, the one querying the recording rule. Over 30 days at a 15-second resolution, Panel C must read every `_bucket` series (11 buckets × 4 paths × every replica) for the entire range, compute a rate per series per step, aggregate by `le`, and interpolate — a query whose cost scales with buckets × paths × replicas × steps. Panel B reads a single pre-computed series per path: the expensive work was already done once, incrementally, at rule-evaluation time. This is the entire economic argument for recording rules — pay once at write time instead of every time someone opens the dashboard.

---

## Block 10 — Diagnostics

**10.1** The scrape is **discarded entirely**. Prometheus parses the response, counts the samples, and if the count exceeds `sample_limit` it rejects the whole scrape — no partial ingestion. `up` becomes **0** and `lastError` reads `sample limit exceeded`.

All-or-nothing is the safest behaviour because partial ingestion would be silently and unpredictably lossy: you would have *some* of the target's series, with no way to know which ones were dropped, and dashboards would show plausible but wrong data. Failing the whole scrape makes the problem loud (`up == 0` pages) and keeps the ingested data internally consistent.

**10.2** Earliest first:
1. **`label_limit`** — enforced during parsing, per sample, before the sample is accepted. Also fails the scrape.
2. **`sample_limit`** — enforced after parsing the response, before anything is appended. Fails the whole scrape.
3. **`metric_relabel_configs` with `action: drop`** — runs after parsing, per sample, discarding samples on the way to the appender.
4. **`--storage.tsdb.retention.time`** — acts long after ingestion, deleting whole blocks once they age out.

The first three reduce **ingestion** cost — CPU, head-block memory, index size, WAL volume — and therefore also storage. Retention reduces **storage only**: every dropped sample was still parsed, appended, indexed and written to the WAL first. This is why retention is never the answer to a cardinality problem; the memory pressure is in the head block, which retention does not touch.

**10.3**
1. **Cost.** `{__name__!=""}` is a selector that matches every series in the database. Evaluating it loads the full postings list and touches every series, which on a loaded server can take tens of seconds, allocate gigabytes, and — in the worst case — OOM the very server you are trying to diagnose. `/api/v1/status/tsdb` reads precomputed head-block statistics and returns in milliseconds.
2. **Correctness of scope.** The PromQL query is bounded by `--query.lookback-delta` and reflects series with a recent sample; `/status/tsdb` reports the actual head-block series count and the true top-N by metric name, label pair and memory. It also gives you `memoryInBytesByLabelName`, which PromQL cannot produce at all — and that is usually the number that identifies the culprit fastest.

**10.4**
- **`wal/`** — the write-ahead log. Every appended sample and every new series is written here first, in numbered 128 MB segments, plus periodic `checkpoint.NNNNNN` directories that compact the older segments. It exists solely so the in-memory head block can be reconstructed after a crash.
- **`chunks_head/`** — completed chunks belonging to the still-open head block, flushed to disk so they need not stay in RAM, but not yet part of a persistent block.
- **ULID-named directories** — immutable persisted blocks, each covering a fixed time range (2 hours initially, then merged by compaction into progressively larger blocks). Each contains `chunks/`, `index`, `meta.json` and `tombstones`.

On an **unclean restart**: the persisted blocks are immutable and untouched. `chunks_head/` and `wal/` are replayed to rebuild the head block — this is the slow part of Prometheus startup (`Replaying WAL...` in the logs), and it is why a server with a large head block can take many minutes to become ready. A corrupt WAL segment is truncated at the corruption point, losing the samples after it, and Prometheus logs the truncation and continues.

**10.5** You edit `prometheus.yml`, send SIGHUP (or POST `/-/reload`). Prometheus reads and validates the new file, finds it invalid, **logs an error, sets `prometheus_config_last_reload_successful` to 0, and keeps running the previously loaded configuration.** It does not exit, does not stop scraping, and does not degrade in any visible way.

So it is running the **old config** — the one from before your edit. Your new scrape job never gets scraped, your new alerting rule never fires, your fix to a broken relabel is not applied. Every dashboard looks healthy. The failure is invisible until someone asks why the new service has no data, which in practice is during the incident that new service was supposed to warn you about. This is why `prometheus_config_last_reload_successful == 0` belongs in every alert bundle, and why `promtool check config` belongs in CI.

**10.6** Two independent causes:
1. **The series exist historically but are stale now** — the target went away, so the last sample is older than `--query.lookback-delta` (5m). `/api/v1/series` searched a 1-hour window and found them; the instant query looks back only 5 minutes and finds nothing.
2. **The series exist and are current, but the query's label matchers or an operator eliminated them** — a typo in a label value, a `by (…)` clause that dropped a label needed for a later join, or one-to-one matching failing as in 4.2.

To distinguish: query the **bare selector with no operators**, `demo_http_requests_total`, as an instant query.
- Empty → cause 1 (staleness). Confirm with a range query `demo_http_requests_total[1h]` or `timestamp(demo_http_requests_total)` over a range, and check `up` for that job.
- Non-empty → cause 2. Re-add your expression one operator at a time until the result disappears; that operator is the culprit.

**10.7** In plain language: **a rule group is taking longer to evaluate than the interval at which it is supposed to run.** The group cannot keep up with its own schedule.

The compounding effect: Prometheus does not run overlapping evaluations of a group, so it simply skips the missed slots (`prometheus_rule_group_iterations_missed_total` increments). Every alerting rule in that group is therefore evaluated less often than its configured interval, which stretches the `for` duration in wall-clock terms (see 6.8) — an alert with `for: 2m` in a group that is effectively evaluating every 90 seconds can take four minutes to fire. Worse, recording rules in the group produce a gappy, undersampled series, and any alert built on those recorded series inherits the gaps — potentially resetting its `for` timer each time the series goes stale, so it never fires at all.

**10.8** `delete_series` does **not** remove data. It writes **tombstones** — small files inside each affected block recording "series matching X, over time range Y, are deleted". Queries consult tombstones and filter the matching samples out of results, so the data becomes invisible, but the chunks and index entries stay on disk exactly as they were.

`clean_tombstones` forces Prometheus to **rewrite** the affected blocks without the tombstoned series, which is what actually reclaims space. It is an expensive rewrite of potentially many gigabytes, and it only touches persisted blocks — series in the head block are not reclaimed until they are compacted out.

Deletion is the wrong tool for a cardinality problem because the pressure is **at ingestion**, not on disk: the offending series are being created again on every scrape. Deleting them frees space that is immediately re-consumed, while the head block, the index, and the memory footprint recover for at most one scrape interval. The fix must stop the series from being *created*: `metric_relabel_configs` to drop the label, `sample_limit` to fail loudly, or a change to the instrumentation.

**10.9**
1. **Immediate — stop the bleeding at the query layer and buy headroom.** Identify the offending job from `/api/v1/status/tsdb` (`seriesCountByMetricName`, `memoryInBytesByLabelName`) and **drop that scrape job or add a `metric_relabel_configs` drop rule, then reload**. Reload, not restart: a restart on a 40 M-series head block means a WAL replay measured in tens of minutes, during which you are blind. If it is already OOM-looping, you may have no choice — in that case set `--storage.tsdb.head-chunks-write-queue-size` aside and start with the config change so the replayed state does not immediately re-explode.
2. **At the next scrape — put a hard floor under it.** Add `sample_limit` and `label_limit` to the offending job (and, as policy, to every job). This converts a silent unbounded fan-out into a loud `up == 0` with `sample limit exceeded`, which is a page you can act on in seconds instead of an OOM you diagnose in hours.
3. **Architectural — stop being one server.** 40 M active series is past the point where a single Prometheus is the right shape. Shard by `hashmod` across N servers (see 2.3), or move to a horizontally scalable long-term store (Thanos, Cortex/Mimir) with per-tenant series limits enforced at ingest. Pair that with a standing cardinality alert — `prometheus_tsdb_head_series` growth rate, and `rate(scrape_series_added[10m])` per job — so the next explosion is caught at 100 k new series, not 40 M.

</details>