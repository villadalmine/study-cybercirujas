# PCA · Domain 3.2 — Understand Logs and Events

Guided, hands-on exercises. Each block is a sequence of commands you run yourself; after each block, answer the comprehension questions before moving on. The full answer key is in the collapsible section at the end.

**Prerequisites:** Docker Engine, `curl`, `jq`, and a throwaway Kubernetes cluster (`kind create cluster` or `minikube start`) for Exercises 2 and 4b. Everything runs locally; tear it all down at the end.

> **Mental model for this domain.** Prometheus itself stores exactly one signal: **metrics** (numeric samples over time). "Understand logs and events" is about the *other two discrete signals* — what they are, how they differ from metrics, and how the Prometheus ecosystem (Loki, LogQL, kube-state-metrics, exporters, exemplars) connects them. The exam tests the *distinctions and the trade-offs*, not just tool syntax. Keep asking: what does one "record" represent, and what is its cardinality cost?

---

## Exercise 1 — The same process, two signals: metrics vs. logs

A running process emits both continuously. Seeing them side by side is the fastest way to internalize the difference.

**Block A — Start a workload that emits both signals**

```bash
# 1. Prometheus itself is a perfect specimen: it exposes /metrics AND logs to stdout.
docker run -d --name prom -p 9090:9090 prom/prometheus:v2.53.0

# 2. Read the LOGS (discrete, timestamped events).
docker logs prom
```

Expected output (logfmt, one event per line):

```
ts=2024-06-20T10:00:00.123Z caller=main.go:627 level=info msg="Starting Prometheus Server" mode=server version="(version=2.53.0, branch=HEAD, revision=a2c6d15)"
ts=2024-06-20T10:00:00.124Z caller=main.go:632 level=info build_context="(go=go1.22.4, platform=linux/amd64)"
ts=2024-06-20T10:00:00.130Z caller=web.go:565 level=info component=web msg="Start listening for connections" address=0.0.0.0:9090
ts=2024-06-20T10:00:00.150Z caller=head.go:626 level=info component=tsdb msg="Replaying on-disk memory mappable chunks if any"
ts=2024-06-20T10:00:00.161Z caller=main.go:1148 level=info msg="Server is ready to receive web and API requests."
```

**Block B — Read the metrics from the same process**

```bash
# 3. Read the METRICS (aggregated numeric samples).
curl -s localhost:9090/metrics | grep -E '^prometheus_tsdb_head_series '
```

Expected output:

```
prometheus_tsdb_head_series 1247
```

```bash
# 4. Scrape twice, ten seconds apart, and watch the value evolve.
curl -s localhost:9090/metrics | grep -E '^prometheus_http_requests_total.*handler="/metrics"'
sleep 10
curl -s localhost:9090/metrics | grep -E '^prometheus_http_requests_total.*handler="/metrics"'
```

Expected output (a counter that only increases):

```
prometheus_http_requests_total{code="200",handler="/metrics"} 4
prometheus_http_requests_total{code="200",handler="/metrics"} 5
```

> **Questions**
> - **Q1.1** — Both `docker logs prom` and `/metrics` describe the *same* process. Classify each as a signal type and state the fundamental difference in what a single "record" (one log line vs. one metric sample) represents.
> - **Q1.2** — The log lines use `ts=… caller=… level=info msg="…"`. What is this line format called, and why does emitting logs this way (rather than free-form prose) matter the moment you start *aggregating* logs from many instances?
> - **Q1.3** — You cannot compute "the p95 of the head-series count over the last hour" from `docker logs`, and you cannot recover "the exact `revision` string Prometheus started with" from `/metrics`. Explain both gaps, and state the general rule for *when* you reach for metrics versus logs.

---

## Exercise 2 — Kubernetes Events as a first-class discrete signal

Events are neither metrics nor container logs. They are structured records of *state changes* the control plane wants you to notice. This is the piece students most often conflate with "logs."

**Block A — Provoke a failure and watch the Events**

```bash
# 1. Create a Pod that cannot possibly start (image does not exist).
kubectl run broken --image=nginx:doesnotexist

# 2. List Events in time order.
kubectl get events --sort-by='.lastTimestamp'
```

Expected output:

```
LAST SEEN   TYPE      REASON      OBJECT       MESSAGE
25s         Normal    Scheduled   pod/broken   Successfully assigned default/broken to kind-control-plane
23s         Normal    Pulling     pod/broken   Pulling image "nginx:doesnotexist"
22s         Warning   Failed      pod/broken   Failed to pull image "nginx:doesnotexist": ... not found
22s         Warning   Failed      pod/broken   Error: ErrImagePull
8s          Warning   BackOff     pod/broken   Back-off pulling image "nginx:doesnotexist"
8s          Warning   Failed      pod/broken   Error: ImagePullBackOff
```

**Block B — Inspect the structure of a single Event**

```bash
# 3. The same Events appear in `describe`, attached to the object.
kubectl describe pod broken | sed -n '/Events:/,$p'

# 4. Dump one Event as JSON to see its real fields.
kubectl get events -o json \
  | jq '.items[] | select(.reason=="Failed") | {reason, message, type, count, firstTimestamp, lastTimestamp, involvedObject: .involvedObject.name, source: .source.component}' \
  | head -20
```

Expected output:

```json
{
  "reason": "Failed",
  "message": "Failed to pull image \"nginx:doesnotexist\": ... not found",
  "type": "Warning",
  "count": 4,
  "firstTimestamp": "2024-06-20T10:05:10Z",
  "lastTimestamp": "2024-06-20T10:06:02Z",
  "involvedObject": "broken",
  "source": "kubelet"
}
```

```bash
# 5. Clean up.
kubectl delete pod broken
```

> **Questions**
> - **Q2.1** — In one sentence each, distinguish a **container log line** (`kubectl logs`) from a **Kubernetes Event** (`kubectl get events`). What produces each, and what does each describe?
> - **Q2.2** — The `Failed` Event shows `count: 4` with distinct `firstTimestamp` and `lastTimestamp`. What is Kubernetes doing here, and what would you lose if it emitted four separate records instead?
> - **Q2.3** — What does the `type` field (`Normal` / `Warning`) signify, and given that the API server's default event retention is ~1 hour (`--event-ttl`), why are Events *not* a reliable audit trail? What do you deploy to keep them?

---

## Exercise 3 — Aggregating logs with Loki + Promtail, querying with LogQL

Loki is the log store built to sit next to Prometheus: **same label-based data model, PromQL-shaped query language (LogQL).** Understanding this parallel is core to the topic.

**Block A — Bring up a log pipeline**

Create `promtail.yaml`:

```yaml
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: flog
    static_configs:
      - targets: [localhost]
        labels:
          job: flog
          __path__: /logs/*.log
```

Create `docker-compose.yaml`:

```yaml
services:
  loki:
    image: grafana/loki:3.0.0
    ports: ["3100:3100"]
    command: -config.file=/etc/loki/local-config.yaml

  flog:
    image: mingrammer/flog:0.4.3
    command: ["-f", "apache_combined", "-o", "/logs/access.log", "-t", "log", "-l", "-d", "200ms"]
    volumes:
      - logs:/logs

  promtail:
    image: grafana/promtail:3.0.0
    depends_on: [loki]
    volumes:
      - logs:/logs
      - ./promtail.yaml:/etc/promtail/config.yaml
    command: -config.file=/etc/promtail/config.yaml

volumes:
  logs:
```

```bash
# 1. Start the stack (Loki, a fake Apache-log generator, and Promtail shipping to Loki).
docker compose up -d

# 2. Give it ~15s, then confirm Loki knows the stream labels.
sleep 15
curl -sG http://localhost:3100/loki/api/v1/labels | jq
```

Expected output:

```json
{ "status": "success", "data": ["filename", "job", "service_name"] }
```

**Block B — Query logs and then derive a metric from them**

```bash
# 3. A LOG query: return raw lines for a stream selected by labels.
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="flog"}' \
  --data-urlencode 'limit=2' | jq -r '.data.result[0].values[][1]'
```

Expected output (raw Apache-combined lines):

```
102.34.11.9 - - [20/Jun/2024:10:10:01 +0000] "GET /wp-admin HTTP/1.1" 200 4881 "-" "Mozilla/5.0..."
88.4.201.3 - - [20/Jun/2024:10:10:01 +0000] "POST /list HTTP/1.1" 503 1198 "-" "curl/8.0"
```

```bash
# 4. A METRIC query over logs: count GET lines per minute across the stream.
curl -sG "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(count_over_time({job="flog"} |= "GET" [1m]))' \
  | jq '.data.result[0].value[1]'
```

Expected output:

```
"143"
```

```bash
# 5. Tear down.
docker compose down -v
```

> **Questions**
> - **Q3.1** — In the selector `{job="flog"}`, what exactly does `job="flog"` identify inside Loki, and how does that map onto Prometheus's own data model? Define a Loki **stream**.
> - **Q3.2** — Suppose you reconfigure Promtail to extract the full request path and attach it as a stream label (`path="/wp-admin"`, `path="/list?id=abc123"`, …). Explain precisely why this is dangerous in Loki, using the same reasoning you'd apply to a Prometheus label.
> - **Q3.3** — Step 4's query returned a single number, `"143"`, from a *log* stream. What class of LogQL query is `sum(count_over_time(... [1m]))`, and what does its existence demonstrate about the boundary between logs and metrics?

---

## Exercise 4 — From logs and events to metrics, and the cardinality trap

The last idea in this domain: you can *derive* metrics from logs and events, but only by collapsing high-cardinality detail into bounded labels.

**Block A — Reason about deriving a metric from a log stream**

```bash
# 1. (Conceptual, using the Ex.3 pattern.) A LogQL metric query that keeps a BOUNDED label —
#    the HTTP status class — while discarding the unbounded request line:
#      sum by (status) (
#        count_over_time({job="flog"} | pattern `<_> - - <_> "<_>" <status> <_>` [1m])
#      )
#    Contrast with an attempt to keep the FULL request line as a label — which would create
#    one series per unique URL+query-string.
echo "status is bounded (~5 classes); request line is effectively unbounded"
```

**Block B — Events → metrics via kube-state-metrics**

```bash
# 2. Recreate the failing Pod from Exercise 2.
kubectl run broken --image=nginx:doesnotexist

# 3. Deploy kube-state-metrics (KSM turns object *state* into Prometheus metrics).
kubectl apply -k github.com/kubernetes/kube-state-metrics//examples/standard
kubectl -n kube-system rollout status deploy/kube-state-metrics

# 4. Port-forward and read the state metric that mirrors the ImagePullBackOff condition.
kubectl -n kube-system port-forward svc/kube-state-metrics 8080:8080 >/dev/null 2>&1 &
sleep 3
curl -s localhost:8080/metrics | grep 'kube_pod_container_status_waiting_reason.*broken'
```

Expected output:

```
kube_pod_container_status_waiting_reason{namespace="default",pod="broken",container="broken",reason="ImagePullBackOff"} 1
```

```bash
# 5. Clean up.
kubectl delete pod broken
kubectl delete -k github.com/kubernetes/kube-state-metrics//examples/standard
```

> **Questions**
> - **Q4.1** — Name two tools that turn *unstructured log lines* into Prometheus metrics, and describe what one resulting time series looks like (metric name + a plausible label set + value type).
> - **Q4.2** — You want to page on-call when a Pod is stuck in `ImagePullBackOff`. Your three candidate signals are: the Kubernetes **Event** (`reason=Failed`), a **log line** from the kubelet, or the **metric** `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"}`. Which do you build the alert on, and why are the other two poor choices *for alerting*?
> - **Q4.3** — Describe the standard three-signal "drill-down" workflow an operator follows during an incident, and explain where Prometheus **exemplars** fit into stitching the signals together.

---

<details>
<summary><strong>Answer key</strong> (expand only after attempting all questions)</summary>

### Exercise 1

**Q1.1** — `docker logs` is the **logs** signal; `/metrics` is the **metrics** signal.
- A log **record** is a *discrete event*: one thing that happened at one instant, carrying rich, mostly-textual, unbounded context ("Server is ready…", with the full version string). It is append-only and event-per-line.
- A metric **record** is a *sample*: a single numeric value of a named, labelled time series at a scrape timestamp (`prometheus_tsdb_head_series 1247`). It is an aggregate/summary of state, deliberately low in cardinality, and only meaningful as part of a series over time.
The core difference: a log line answers *"what specifically happened here?"*; a metric sample answers *"how much / how many, right now, as a number I can do math on across time and instances?"*

**Q1.2** — It is **logfmt** (structured `key=value` logging; JSON is the other common structured format). Structure matters for aggregation because a log pipeline (Promtail, Fluent Bit, Loki) can **parse fields reliably** — filter by `level=error`, group by `component`, extract `caller` — instead of writing brittle regexes against free-form prose. Once you ship logs from dozens of replicas into one store, consistent machine-parseable fields are what make querying, label extraction, and log-to-metric conversion possible at all.

**Q1.3** — You can't compute a p95-over-an-hour from `docker logs` because logs are discrete events, not a continuous numeric series — there is no pre-aggregated `head_series` time series to run a quantile over (you'd have to invent metrics from the text). You can't recover the exact `revision` string from `/metrics` because metrics deliberately discard high-cardinality, one-off textual detail — that build string would be a useless, unbounded label. **Rule:** use **metrics** for aggregatable, bounded-cardinality numbers you alert and trend on ("is it healthy / how much"); use **logs** for the specific, high-detail context you need to explain *why* a particular event happened.

### Exercise 2

**Q2.1** — A **container log line** is produced by the *application process* writing to stdout/stderr; it describes whatever the app chose to say. A **Kubernetes Event** is produced by a *control-plane component* (kubelet, scheduler, controllers) via the API server; it describes a *state transition or decision about an object* (scheduled, pulling, failed, backing off). One is app-authored text; the other is cluster-authored, structured, and attached to a specific `involvedObject`.

**Q2.2** — Kubernetes is **deduplicating repeated identical occurrences into a single Event with a `count` and a `first/lastTimestamp` window** (aggregation/coalescing). Emitting four separate records would flood etcd and the Event stream with near-identical entries; the count+window form preserves *how often* and *over what span* while keeping it one object. (In the newer `events.k8s.io/v1` API this is modelled explicitly as a `series` with `count` + `lastObservedTime`.)

**Q2.3** — `type` classifies the Event as routine (`Normal`) or something demanding attention (`Warning`) — a coarse severity. Events are **not** an audit trail because they are stored in etcd with a short TTL (`--event-ttl`, ~1h by default) and are garbage-collected; anything older is simply gone. To retain them you deploy an **event exporter** (e.g. `kubernetes-event-exporter`) that ships Events out to a durable sink (a log store like Loki/Elasticsearch, or a metrics/alerting pipeline) before they expire.

### Exercise 3

**Q3.1** — `job="flog"` is a **label selector**; Loki identifies log data by *label sets*, exactly as Prometheus identifies metrics by label sets. A **stream** is the unit of storage in Loki: the set of all log lines sharing one unique combination of labels (e.g. `{job="flog", filename="/logs/access.log"}`). It is the log-world analogue of a single Prometheus time series — same "unique label combination = one addressable entity" model.

**Q3.2** — Every distinct label-value combination creates a **new stream**, just as every distinct label combination creates a new Prometheus time series. Request paths (especially with query strings or IDs) are effectively **unbounded**, so making `path` a label produces a near-infinite number of tiny streams — "stream/cardinality explosion." This blows up Loki's index, wrecks ingestion and query performance, and can OOM the ingesters. High-cardinality data belongs *inside the log line* (queried at read time with a LogQL filter/parser), **never** in a stream label — the identical discipline you apply to Prometheus labels.

**Q3.3** — It is a **LogQL metric query** (a range aggregation, `count_over_time`, wrapped in `sum`). Its existence shows the log↔metric boundary is *crossable at query time*: you can compute a numeric, PromQL-shaped result *from raw logs on the fly*, without ever having pre-created that metric. The trade-off is cost — it scans log lines per query rather than reading a cheap pre-aggregated series — so it complements, rather than replaces, a real Prometheus counter for anything you query or alert on frequently.

### Exercise 4

**Q4.1** — Any two of: **mtail**, **grok_exporter**, or **Loki recording rules / LogQL metric queries** (Promtail's `metrics` pipeline stage also qualifies). A resulting series looks like a normal Prometheus counter, e.g. `log_http_requests_total{method="GET", status="200"} 143` — a bounded label set (method, status class) and a monotonically increasing value. The point is that the tool *collapses* unbounded log text into a small, fixed set of labels.

**Q4.2** — Build the alert on the **metric** `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"} == 1`. It is a stable, continuously-evaluated time series Prometheus already scrapes, so an alerting rule can fire deterministically and describe *for how long* the condition has held (`for: 5m`). The **Event** is a poor alerting source because it is ephemeral (TTL-expired within the hour) and not natively scraped by Prometheus — it can vanish before/after you look. The **log line** is poor because alerting on raw log text means brittle string matching and per-line scanning; logs are for *investigation after* the metric fires, not for the trigger.

**Q4.3** — The drill-down: **(1) Metrics alert** — a bounded, always-on series (error rate, `ImagePullBackOff`, latency SLO) crosses a threshold and pages you: *what* is wrong and *how much*. **(2) Traces/logs to localize** — you pivot to the affected service/time window to find *where* in the request path it breaks and *which* specific requests. **(3) Logs for root cause** — you read the exact high-detail lines/events explaining *why*. **Exemplars** are the connective tissue: Prometheus can attach an exemplar (a trace ID, and often enough context to reach the corresponding logs) to a specific metric sample — e.g. a slow bucket in a latency histogram — letting you jump straight from "this metric spiked" to "here is the exact trace/log for one of the requests that caused it," instead of guessing at the correlated time window.

</details>