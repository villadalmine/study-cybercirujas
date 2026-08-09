# 3.4 Push vs Pull

## 1. Motivation: the architectural problem

Every metrics pipeline must answer one question before it collects a single sample: **who initiates the transfer of data — the monitored process, or the monitoring system?** This single decision propagates into your service discovery model, your firewall rules, your failure-detection semantics, and your ability to reason about "is this target actually alive?".

Prometheus makes an opinionated choice: it is a **pull-based** (scrape-based) system. The Prometheus server periodically issues an HTTP `GET /metrics` to each target it has discovered, parses the text exposition format, and appends the samples to its TSDB. The target is *passive* — it maintains an in-memory registry of metrics and renders them on demand. It has no knowledge of Prometheus, no backend address configured, and no responsibility for delivery.

This inverts the model of push-based systems (StatsD, Graphite, InfluxDB's line protocol, most APM agents), where the application actively transmits metrics to a collector, usually over UDP or a persistent TCP connection.

The production problem this topic addresses: **pull is correct for the vast majority of long-running services, but it breaks for a specific class of workload — short-lived and service-level batch jobs — that terminate before Prometheus can scrape them.** The naïve fix ("just let the job push") is a trap that silently corrupts target liveness semantics, creates a single point of failure, and produces zombie time series that never die. The Prometheus ecosystem's answer is a narrow, deliberately limited push bridge (the **Pushgateway**) plus a machine-local alternative (**node_exporter textfile collector**). Knowing *when each is appropriate* — and, more often, when neither is — is the real competency this topic tests.

### Why Prometheus pulls

The upstream FAQ is explicit that this is a mild preference, not a religious position, but the operational advantages are concrete:

- **Target liveness is a first-class signal.** If a scrape fails, Prometheus records the synthetic `up` series as `0` for that target. With push, a silent process and a dead process are indistinguishable — both simply stop sending.
- **The monitoring system controls the load.** Prometheus decides the `scrape_interval`. A misbehaving target cannot flood the TSDB, because it never initiates anything.
- **Targets need zero backend configuration.** No monitoring endpoint, no credentials, no retry/buffering logic embedded in every application.
- **Horizontal redundancy is free.** Two Prometheus servers (prod + staging, or an HA pair) can scrape the same target independently. In a push model the target must be told about every consumer.
- **Manual debugging is trivial.** `curl http://target:port/metrics` reproduces exactly what the server sees. You can inspect a target from your laptop.

### Where pull genuinely fails

- **Short-lived / batch / cron jobs.** A job that runs for 8 seconds every night will almost never coincide with a scrape. Its metrics (records processed, duration, exit status) must survive the process.
- **Ephemeral serverless / FaaS invocations** with no stable endpoint to scrape.
- **Egress-only network topologies** where the target can reach out but Prometheus cannot reach in (some NAT/firewall situations — though this is usually better solved with a proxy or an agent, not push).

---

## 2. Technical comparison and trade-offs

### 2.1 Pull vs Push — fundamental model

| Dimension | Pull (Prometheus scrape) | Push (Pushgateway / StatsD / OTLP) |
|---|---|---|
| Who initiates | Monitoring server | Monitored process |
| Target liveness (`up`) | Directly observable per target | Not observable; server sees only the collector |
| Load control | Server-side (`scrape_interval`) | Client-side; can flood the sink |
| Service discovery | Native (K8s, Consul, EC2, files…) | Client must know the sink address |
| Firewall direction | Server → target (ingress to target) | Target → sink (egress from target) |
| Short-lived jobs | Poor — job dies before scrape | Good — the reason push bridges exist |
| Redundant consumers | Trivial (N servers scrape same target) | Client must fan out to N sinks |
| Manual inspection | `curl /metrics` on the target | Inspect the intermediary, not the source |
| Stale series handling | Automatic (target gone ⇒ `up=0`, series go stale) | Manual — Pushgateway **never forgets** |

### 2.2 Decision matrix — which tool for which workload

| Workload | Recommended mechanism | Why |
|---|---|---|
| Long-running service (API, DB, sidecar) | **Pull** — expose `/metrics`, scrape it | Native model; keep `up` semantics |
| Machine-level batch job (a cron on *this* host) | **node_exporter textfile collector** | Metric is tied to a machine already being scraped |
| Service-level batch job (a nightly ETL, not tied to any one host) | **Pushgateway** | The only officially endorsed Pushgateway use case |
| Serverless / FaaS with an emitter | **OTLP push into Prometheus** (native receiver) or Pushgateway | No stable endpoint to scrape |
| Long-term storage / global view | **`remote_write`** (Prometheus *pushes* to Mimir/Thanos/Cortex/VictoriaMetrics) | Storage-layer push; orthogonal to scraping |

### 2.3 The Pushgateway is NOT a "make Prometheus push-based" switch

This is the single most-tested misconception. From the official docs, the Pushgateway is appropriate **only** for capturing the outcome of a *service-level* batch job. Using it as a general ingestion point for application metrics defeats the design:

| Consequence of misuse | Failure mode |
|---|---|
| `up` reflects the **Pushgateway**, not your job | You lose per-job liveness detection entirely |
| Pushgateway **never expires** pushed series | A retired job leaves stale metrics forever → false dashboards/alerts |
| Single instance = SPOF and bottleneck | All batch metrics funnel through one process |
| Counters look like they reset | A replaced group can make counters appear to decrease |
| Timestamp is the **scrape** time, not the push time | Use the injected `push_time_seconds`, never the sample timestamp, to reason about freshness |

### 2.4 Pushgateway HTTP methods

| Method | Path | Semantics |
|---|---|---|
| `PUT` | `/metrics/job/<job>{/<label>/<value>}` | Replace **all** metrics in this grouping key with the body |
| `POST` | `/metrics/job/<job>{/<label>/<value>}` | Replace only metrics **with the same name** in this group; leave others |
| `DELETE` | `/metrics/job/<job>{/<label>/<value>}` | Remove the entire grouping key |

The **grouping key** is `job` plus every `<label>/<value>` pair in the URL path (conventionally at least `instance`). Two pushes with the same grouping key overwrite each other; different keys coexist.

### 2.5 Machine-level vs service-level batch — textfile collector vs Pushgateway

| | node_exporter textfile collector | Pushgateway |
|---|---|---|
| Metric scope | Tied to a specific host | Independent of any host |
| Delivery | Job writes a local `*.prom` file | Job HTTP-pushes over the network |
| Liveness | Inherits the host's `up` | Loses per-job `up` |
| Staleness | Follows the node's scrape; overwrite the file | Manual delete or `push_time_seconds` alerting |
| Failure domain | Local disk | Network + shared intermediary |
| Use when | Backup script, log rotation, cert renewal on a box | Cluster-wide ETL, CI pipeline result |

---

## 3. Complete manifests and infrastructure

### 3.1 Pushgateway on Kubernetes (Deployment + Service + PVC)

Persistence (`--persistence.file`) is what lets pushed groups survive a Pushgateway restart; without it, a pod reschedule silently drops every group until each job pushes again.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pushgateway-data
  namespace: monitoring
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pushgateway
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pushgateway
spec:
  replicas: 1                       # keep at 1: multiple replicas fragment grouping keys
  strategy:
    type: Recreate                  # RWO volume cannot be mounted by two pods at once
  selector:
    matchLabels:
      app.kubernetes.io/name: pushgateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pushgateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534            # nobody
        fsGroup: 65534
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          args:
            - --persistence.file=/data/pushgateway.data
            - --persistence.interval=5m
            - --web.enable-admin-api          # enables PUT /api/v1/admin/wipe
            - --log.level=info
          ports:
            - name: http
              containerPort: 9091
          volumeMounts:
            - name: storage
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: http
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /-/ready
              port: http
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: pushgateway-data
---
apiVersion: v1
kind: Service
metadata:
  name: pushgateway
  namespace: monitoring
  labels:
    app.kubernetes.io/name: pushgateway
spec:
  selector:
    app.kubernetes.io/name: pushgateway
  ports:
    - name: http
      port: 9091
      targetPort: http
```

### 3.2 Prometheus scrape config — the `honor_labels` requirement

`honor_labels: true` is mandatory for a Pushgateway job. Without it Prometheus overwrites the pushed `job`/`instance` with the *Pushgateway's own* target labels and renames the originals to `exported_job`/`exported_instance` — silently attributing every batch job to the gateway.

```yaml
scrape_configs:
  - job_name: pushgateway
    honor_labels: true                 # keep job/instance from the pushed metrics
    scrape_interval: 15s
    static_configs:
      - targets: ["pushgateway.monitoring.svc:9091"]
    # In-cluster equivalent via Kubernetes SD + relabeling:
  - job_name: pushgateway-sd
    honor_labels: true
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names: [monitoring]
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        action: keep
        regex: pushgateway
```

### 3.3 node_exporter textfile collector — the machine-level alternative

Enable the collector on node_exporter and write metrics **atomically** so the collector never reads a half-written file:

```yaml
# node_exporter DaemonSet arg (excerpt)
args:
  - --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/report-backup.sh — run from cron on the host
set -euo pipefail

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
name=backup

# Do the work, capture outcome
start=$(date +%s)
if /usr/local/bin/do-backup.sh; then rc=0; else rc=1; fi
end=$(date +%s)

# Render to a temp file on the SAME filesystem, then atomically rename.
tmp="$(mktemp -p "$TEXTFILE_DIR" .${name}.XXXXXX)"
cat > "$tmp" <<EOF
# HELP node_backup_last_run_timestamp_seconds Unix time of the last backup attempt.
# TYPE node_backup_last_run_timestamp_seconds gauge
node_backup_last_run_timestamp_seconds ${end}
# HELP node_backup_success Whether the last backup succeeded (1) or failed (0).
# TYPE node_backup_success gauge
node_backup_success $([ "$rc" -eq 0 ] && echo 1 || echo 0)
# HELP node_backup_duration_seconds Duration of the last backup in seconds.
# TYPE node_backup_duration_seconds gauge
node_backup_duration_seconds $((end - start))
EOF
mv "$tmp" "$TEXTFILE_DIR/${name}.prom"   # atomic on the same FS
```

### 3.4 Instrumented batch job pushing to the gateway (Python client)

```python
#!/usr/bin/env python3
"""Nightly ETL that reports its outcome to the Pushgateway on completion."""
from prometheus_client import CollectorRegistry, Counter, Gauge, push_to_gateway

PUSHGATEWAY = "pushgateway.monitoring.svc:9091"
JOB = "nightly_etl"
INSTANCE = "etl-runner-01"

registry = CollectorRegistry()  # isolated registry: push exactly these series
records = Counter("etl_records_processed_total",
                  "Records processed by the ETL run", registry=registry)
duration = Gauge("etl_duration_seconds",
                 "Wall-clock duration of the ETL run", registry=registry)
last_success = Gauge("etl_last_success_timestamp_seconds",
                     "Unix time of the last successful ETL run", registry=registry)

def main() -> None:
    with duration.time():
        n = run_etl()          # your work
        records.inc(n)
    last_success.set_to_current_time()

if __name__ == "__main__":
    try:
        main()
    finally:
        # PUT: replace the ENTIRE grouping key {job,instance} with this registry.
        push_to_gateway(
            PUSHGATEWAY, job=JOB,
            grouping_key={"instance": INSTANCE},
            registry=registry,
        )
```

Client function ↔ HTTP method mapping:

| Client function | HTTP verb | Effect on the grouping key |
|---|---|---|
| `push_to_gateway(...)` | `PUT` | Replace all metrics in the group |
| `pushadd_to_gateway(...)` | `POST` | Add/replace same-named metrics only |
| `delete_from_gateway(...)` | `DELETE` | Remove the group entirely |

---

## 4. CLI commands and real terminal output

### 4.1 Push a metric with `curl`

```console
$ echo "example_metric 42" | curl -i --data-binary @- \
    http://localhost:9091/metrics/job/demo/instance/host-1
HTTP/1.1 200 OK
Date: Sat, 08 Aug 2026 09:14:22 GMT
Content-Length: 0
```

Push a full group via heredoc (note the required trailing newline in the body):

```console
$ cat <<'EOF' | curl -s --data-binary @- \
    http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01
# TYPE etl_records_processed_total counter
etl_records_processed_total 128443
# TYPE etl_duration_seconds gauge
etl_duration_seconds 42.7
# TYPE etl_last_success_timestamp_seconds gauge
etl_last_success_timestamp_seconds 1754643262
EOF
```

### 4.2 Inspect what the Pushgateway now exposes

The gateway injects `push_time_seconds` and `push_failure_time_seconds` per group — these are your freshness signals, not the sample timestamps.

```console
$ curl -s http://localhost:9091/metrics | grep -E 'etl_|push_time' | grep nightly_etl
etl_duration_seconds{instance="etl-runner-01",job="nightly_etl"} 42.7
etl_last_success_timestamp_seconds{instance="etl-runner-01",job="nightly_etl"} 1.754643262e+09
etl_records_processed_total{instance="etl-runner-01",job="nightly_etl"} 128443
push_failure_time_seconds{instance="etl-runner-01",job="nightly_etl"} 0
push_time_seconds{instance="etl-runner-01",job="nightly_etl"} 1.7546432627e+09
```

### 4.3 POST vs PUT difference in practice

```console
# POST adds a new metric to the group without touching the others:
$ echo "etl_rows_rejected_total 12" | curl -s --data-binary @- -X POST \
    http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01

$ curl -s http://localhost:9091/metrics | grep 'job="nightly_etl"' | wc -l
5      # 4 metrics + push_time; the earlier PUT payload survived

# A PUT with only one metric would have WIPED the other three.
```

### 4.4 Delete a stale group and wipe everything

```console
$ curl -s -X DELETE http://localhost:9091/metrics/job/nightly_etl/instance/etl-runner-01
$ curl -s http://localhost:9091/metrics | grep -c nightly_etl
0

# Wipe ALL groups (requires --web.enable-admin-api):
$ curl -s -X PUT http://localhost:9091/api/v1/admin/wipe
```

### 4.5 Confirm Prometheus sees it correctly (labels preserved)

```console
$ curl -sG http://prometheus:9090/api/v1/query \
    --data-urlencode 'query=etl_records_processed_total' | jq '.data.result[0].metric'
{
  "__name__": "etl_records_processed_total",
  "instance": "etl-runner-01",
  "job": "nightly_etl"
}
```

If instead you see `"job": "pushgateway"` and `"exported_job": "nightly_etl"`, `honor_labels: true` is missing.

---

## 5. Verification and failure diagnosis

### 5.1 Is the bridge healthy?

```promql
up{job="pushgateway"}          # 1 = Prometheus can scrape the gateway
```
Remember: this is the **gateway's** liveness, never the batch job's. For job freshness you must use the injected push timestamp.

### 5.2 Detect stale / dead batch jobs (the #1 gap of push)

Because the Pushgateway never forgets, a job that stops running leaves its last values frozen forever. Alert on staleness explicitly:

```yaml
groups:
  - name: batch-jobs
    rules:
      - alert: BatchJobNotRunning
        # No successful push in the last 25 hours for a daily job
        expr: time() - push_time_seconds{job="nightly_etl"} > 25 * 3600
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "nightly_etl has not pushed in over 25h"

      - alert: BatchJobFailing
        expr: push_failure_time_seconds{job="nightly_etl"} > push_time_seconds{job="nightly_etl"}
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "nightly_etl last push was a failure"

      - alert: BatchJobFailedRun
        # Requires the job to expose an explicit success gauge
        expr: etl_last_success_timestamp_seconds < time() - 25 * 3600
        for: 10m
        labels: { severity: critical }
```

### 5.3 Failure catalogue

| Symptom | Root cause | Fix |
|---|---|---|
| Metrics never appear in Prometheus | Pushgateway not scraped | Check `up{job="pushgateway"}`, target status, network policy to :9091 |
| Everything labelled `job="pushgateway"` / `exported_job` present | `honor_labels: true` missing | Add it to the scrape job |
| Retired job's metrics linger forever | Pushgateway never expires groups | `DELETE` the group at teardown; alert on `push_time_seconds` |
| Counter appears to reset / decrease | A `PUT`/`POST` replaced the group with lower values | Use monotonic counters; prefer `push_to_gateway` (full PUT) with a stable registry |
| All batch metrics vanished after a restart | No persistence configured | `--persistence.file` + a PVC |
| Two `instance` values for one logical job | Multiple runners share `job` but not `instance` | Standardize the grouping key (`job`+`instance`) |
| `push_time` looks like "now" but data is old | You read the sample timestamp (= scrape time), not the push time | Reason about freshness only via `push_time_seconds` |
| Batch metrics tied to a host you can already scrape | Wrong tool | Use the node_exporter **textfile collector**, not the Pushgateway |

### 5.4 End-to-end smoke test

```console
$ curl -s http://localhost:9091/-/ready && echo READY
READY
$ echo 'smoke_test 1' | curl -s --data-binary @- \
    http://localhost:9091/metrics/job/smoke/instance/ci
$ sleep 20   # allow one scrape_interval
$ curl -sG http://prometheus:9090/api/v1/query \
    --data-urlencode 'query=smoke_test{job="smoke"}' | jq '.data.result[0].value[1]'
"1"
$ curl -s -X DELETE http://localhost:9091/metrics/job/smoke/instance/ci   # clean up
```

### 5.5 Note on native push paths (context)

Two legitimate "push" flows exist in modern Prometheus and should not be confused with the Pushgateway:

- **`remote_write`** — Prometheus itself *pushes* scraped data to long-term storage (Thanos Receive, Mimir, Cortex, VictoriaMetrics). This is a storage concern, downstream of scraping.
- **Native OTLP ingestion** — recent Prometheus can receive OpenTelemetry metrics via `/api/v1/otlp/v1/metrics` (enabled with `--web.enable-otlp-receiver`, historically the `otlp-write-receiver` feature flag). This is a true push ingress for OTel-instrumented and serverless emitters, and is increasingly the preferred alternative to the Pushgateway for those cases.

---

## 6. References

- Prometheus FAQ — *Why do you pull rather than push?*: https://prometheus.io/docs/introduction/faq/#why-do-you-pull-rather-than-push
- Pushing metrics — *When to use the Pushgateway*: https://prometheus.io/docs/practices/pushing/
- Pushgateway project (README, API, admin endpoints): https://github.com/prometheus/pushgateway
- Prometheus configuration — `scrape_config`, `honor_labels`: https://prometheus.io/docs/prometheus/latest/configuration/configuration/#scrape_config
- node_exporter textfile collector: https://github.com/prometheus/node_exporter#textfile-collector
- Prometheus client_python — Pushgateway helpers (`push_to_gateway`, `pushadd_to_gateway`, `delete_from_gateway`): https://prometheus.github.io/client_python/exporting/pushgateway/
- Exposition formats (text format the gateway/collector parse): https://prometheus.io/docs/instrumenting/exposition_formats/
- Remote write specification: https://prometheus.io/docs/specs/prw/remote_write_spec/
- OpenTelemetry ingestion into Prometheus: https://prometheus.io/docs/guides/opentelemetry/
- PCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/PCA_Curriculum.pdf