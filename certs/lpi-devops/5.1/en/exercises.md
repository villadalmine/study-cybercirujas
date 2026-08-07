# CNCF / LPI 701-100 (v1.0) Topic 5.1: IT Operations and Monitoring - Production-Grade Study Guide & Hands-on Labs

## 1. Official References & Technical Architecture Deep Dive

* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Prometheus Official Architecture & Documentation**: [https://prometheus.io/docs/introduction/overview/](https://prometheus.io/docs/introduction/overview/)
* **Google SRE Book - Service Level Objectives**: [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
* **Prometheus Alerting & Alertmanager Specification**: [https://prometheus.io/docs/alerting/latest/overview/](https://prometheus.io/docs/alerting/latest/overview/)

---

### Core SRE & Observability Principles

Modern IT operations transition from traditional host-centric monitoring (ICMP ping, arbitrary CPU percent thresholds) to **Service Reliability Engineering (SRE)** principles based on business outcomes and user experience.

1. **Service Level Indicator (SLI)**: A quantifiable metric measured in real time that reflects service quality.
   * *Formula Example*: $\text{SLI} = \frac{\text{Good Requests (Latency } < 200\text{ms and Status } \neq 5xx)}{\text{Total Valid Requests}} \times 100$
2. **Service Level Objective (SLO)**: A target value or range of values for a service level that is measured by an SLI, agreed upon by product and SRE teams (e.g., $99.9\%$ successful HTTP responses over a rolling 30-day window).
3. **Service Level Agreement (SLA)**: A legal contract with financial or operational consequences if the SLO is breached.
4. **Error Budget**: The acceptable margin of failure derived from the SLO ($100\% - \text{SLO}$). For a $99.9\%$ SLO, the error budget is $0.1\%$. Deployments are halted when the error budget is exhausted.
5. **The Four Golden Signals**:
   * **Latency**: The time taken to service a request (differentiating between successful and failed requests).
   * **Traffic**: A measure of demand on the system (e.g., HTTP requests/sec, concurrent transactions).
   * **Errors**: The rate of requests that fail (explicit 5xx responses, implicit timeouts, or policy violations).
   * **Saturation**: How "full" the service is (e.g., memory utilization, thread pool exhaustion, queue depth).

---

### Prometheus Storage & Scraping Architecture

```
+-------------------------------------------------------------------------------+
|                               PROMETHEUS SERVER                               |
|                                                                               |
|  +--------------------+     +---------------------+     +------------------+  |
|  | Retrieval (Scraper)| --> | TSDB (Head / Disk)  | --> |  PromQL Engine   |  |
|  +--------------------+     +---------------------+     +------------------+  |
|            ^                           |                          |           |
+------------|---------------------------|--------------------------|-----------+
             | (HTTP Pull)               v (WAL / Chomp)            | (Evaluate)
             |                    +---------------+                 v
    +-----------------+           | Disk Storage  |        +-----------------+
    | Exporters /     |           | Block 2h / 2h |        |  Alertmanager   |
    | Target Endpoints|           +---------------+        +-----------------+
    +-----------------+                                             |
                                                                    v
                                                            +-----------------+
                                                            | PagerDuty / Mail|
                                                            +-----------------+
```

#### TSDB (Time Series Database) Internal Mechanics
Prometheus uses a custom append-only Time Series Database (TSDB) stored on the local disk filesystem:
* **Head Block**: In-memory buffer where raw incoming metrics are written first. It contains a Write-Ahead Log (WAL) for crash recovery.
* **Gorilla Float64 & Delta-of-Delta Compression**: Timestamps are stored using double-delta compression. Metric values (64-bit floats) are XOR-compressed against preceding values, reducing memory footprints to ~1.37 bytes per sample.
* **Block Layout**: Every 2 hours, memory data is compacted and flushed to disk as a immutable **Block** containing:
  * `chunks/`: Raw compressed time-series data.
  * `index`: Inverted index mapping metric labels to series IDs.
  * `meta.json`: Block metadata (min/max time, stats, compaction level).
  * `tombstones`: Records of deleted metrics.
* **Pull vs. Push Architecture Trade-offs**:
  * *Pull Model (Prometheus Default)*: The server initiates HTTP GET requests to target `/metrics` endpoints. Centralizes scrape state, automatically detects target down states (via `up` metric), and prevents targets from overloading monitoring backends.
  * *Push Model (via Pushgateway)*: Required for short-lived batch/ephemeral jobs that exit before a scrape cycle occurs. *Trade-off*: Pushgateway acts as a metric cache and single point of failure; it cannot detect target death automatically.

---

## 2. Exercise 1: Deploying and Validating a Production-Grade Prometheus Stack

### Step 1: Define the Prometheus Server Configuration
Create a workspace directory and write a complete, syntactically valid `prometheus.yml` configuration specifying dynamic target scraping and metric relabeling rules.

Execute in terminal:
```bash
mkdir -p ~/prometheus-lab/config
cd ~/prometheus-lab
```

Write `~/prometheus-lab/config/prometheus.yml`:
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    environment: production
    datacenter: us-east-1

rule_files:
  - "alerts.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "localhost:9093"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node_exporter"
    scrape_interval: 5s
    static_configs:
      - targets: ["localhost:9100"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        regex: "([^:]+):.*"
        replacement: "${1}"
      - target_label: tier
        replacement: infrastructure
```

### Step 2: Define Syntactically Valid Prometheus Alerting Rules
Create the `alerts.yml` rule file referenced in `prometheus.yml`.

Write `~/prometheus-lab/config/alerts.yml`:
```yaml
groups:
  - name: node_infrastructure_alerts
    rules:
      - alert: NodeExporterDown
        expr: up{job="node_exporter"} == 0
        for: 30s
        labels:
          severity: critical
          team: platform-sre
        annotations:
          summary: "Node Exporter instance {{ $labels.instance }} is unreachable"
          description: "Target {{ $labels.instance }} has been down for more than 30 seconds."

      - alert: HighCpuUtilization
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 2m
        labels:
          severity: warning
          team: platform-sre
        annotations:
          summary: "High CPU usage on {{ $labels.instance }}"
          description: "CPU utilization on {{ $labels.instance }} is at {{ printf \"%.2f\" $value }}%."
```

### Step 3: Validate Configurations via `promtool`
Before starting Prometheus, validate the syntax of your configuration files using `promtool`.

Execute:
```bash
promtool check config ~/prometheus-lab/config/prometheus.yml
```

Expected Output:
```text
Checking /home/user/prometheus-lab/config/prometheus.yml
  SUCCESS: 1 rule files found

Checking /home/user/prometheus-lab/config/alerts.yml
  SUCCESS: 2 rules found
```

Execute rule unit validation check:
```bash
promtool check rules ~/prometheus-lab/config/alerts.yml
```

Expected Output:
```text
Checking /home/user/prometheus-lab/config/alerts.yml
  SUCCESS: 2 rules found
```

### Step 4: Run Node Exporter, Alertmanager, and Prometheus Containers
Run the full observability stack using Docker/Podman network hooks.

Execute:
```bash
docker network create monitoring-net

# 1. Run Node Exporter
docker run -d \
  --name node_exporter \
  --network monitoring-net \
  -p 9100:9100 \
  prom/node-exporter:v1.7.0

# 2. Run Alertmanager
docker run -d \
  --name alertmanager \
  --network monitoring-net \
  -p 9093:9093 \
  prom/alertmanager:v0.26.0

# 3. Run Prometheus Server
docker run -d \
  --name prometheus \
  --network monitoring-net \
  -p 9090:9090 \
  -v ~/prometheus-lab/config/prometheus.yml:/etc/prometheus/prometheus.yml \
  -v ~/prometheus-lab/config/alerts.yml:/etc/prometheus/alerts.yml \
  prom/prometheus:v2.48.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.enable-lifecycle
```

### Step 5: Verify Scraping Targets via HTTP API
Query Prometheus HTTP API to verify target scrapers are active and healthy.

Execute:
```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .discoveredLabels.job, health: .health, lastScrape: .lastScrape}'
```

Expected Output:
```json
{
  "job": "prometheus",
  "health": "up",
  "lastScrape": "2026-08-07T08:30:12.145Z"
}
{
  "job": "node_exporter",
  "health": "up",
  "lastScrape": "2026-08-07T08:30:14.892Z"
}
```

---

### Verification Questions (Exercise 1)

1. What is the difference between `relabel_configs` and `metric_relabel_configs` in a Prometheus configuration file?
2. If `promtool check config` returns `FAILED: parsing YAML file: line 12: did not find expected key`, how should an operator systematically isolate the error?
3. What is the operational impact of running Prometheus with the `--web.enable-lifecycle` flag enabled?

---

## 3. Exercise 2: PromQL Metrics Analysis, Metric Types, and SRE SLI/SLO Calculations

### Deep Dive: Prometheus Data Types

| Type | Definition | Reset Behavior | PromQL Functions |
| :--- | :--- | :--- | :--- |
| **Counter** | Monotonically increasing cumulative counter (can only go up or reset to 0 on restart). | Resets back to 0 on service crash. | `rate()`, `increase()`, `irate()` |
| **Gauge** | Single numerical value that can arbitrarily go up or down. | Represents current state snapshots. | `avg_over_time()`, `max_over_time()`, `delta()` |
| **Histogram** | Samples observations (usually durations or sizes) into configurable buckets (`_bucket{le="..."}`). Also tracks `_sum` and `_count`. | Buckets are cumulative counters. | `histogram_quantile()`, `rate()` |
| **Summary** | Calculates configurable quantiles (e.g. 0.95, 0.99) directly on the client side. Includes `_sum` and `_count`. | Cannot be aggregated across instances safely. | Direct quantile reading, `rate()` on `_count` |

---

### Step 1: Inspect Raw Exporter Metrics
Fetch raw metrics directly from Node Exporter to understand text-based metric representation.

Execute:
```bash
curl -s http://localhost:9100/metrics | grep -E '^node_cpu_seconds_total' | head -n 6
```

Expected Output:
```text
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 14820.45
node_cpu_seconds_total{cpu="0",mode="iowait"} 12.30
node_cpu_seconds_total{cpu="0",mode="irq"} 0.00
node_cpu_seconds_total{cpu="0",mode="nice"} 0.15
```

### Step 2: Formulate PromQL Queries for Rate and Aggregation

#### 1. Calculating Per-Second Rate of Monotonic Counters
`rate()` automatically handles counter resets (e.g., process restarts).

Execute Instant Query via API:
```bash
curl -s -g 'http://localhost:9090/api/v1/query?query=sum(rate(node_cpu_seconds_total{mode!="idle"}[5m]))by(instance)' | jq .
```

Expected Output:
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "instance": "localhost"
        },
        "value": [
          1757233825.123,
          "0.14500000000000002"
        ]
      }
    ]
  }
}
```

#### 2. Calculating 99th Percentile Latency from Histograms
To compute latency percentiles across aggregated nodes using `histogram_quantile()`:

$$\text{Quantile}_{\text{p99}} = \text{histogram\_quantile}\left(0.99, \sum_{\text{le}}\left(\text{rate}\left(\text{http\_request\_duration\_seconds\_bucket}[5\text{m}]\right)\right)\right)$$

PromQL Syntax:
```promql
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
```

### Step 3: Compute SRE Availability SLI/SLO in PromQL
Calculate the HTTP availability SLI over a rolling 30-day window:

PromQL Syntax:
```promql
(
  sum(rate(http_requests_total{status!~"5.."}[30d]))
  /
  sum(rate(http_requests_total[30d]))
) * 100
```

To calculate the **Error Budget Burn Rate**:
$$\text{Burn Rate} = \frac{1 - \text{SLI}_{\text{actual}}}{1 - \text{SLO}_{\text{target}}}$$

PromQL Query for $99.9\%$ SLO ($0.001$ allowable error rate) over 1 hour:
```promql
(
  sum(rate(http_requests_total{status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total[1h]))
) / 0.001
```
*Note*: A burn rate of $1$ means the service will exhaust its error budget in exactly 30 days. A burn rate of $14.4$ means $2\%$ of the error budget is consumed in 1 hour.

---

### Verification Questions (Exercise 2)

1. Why is applying `sum()` prior to `rate()` on a Counter metric (e.g., `rate(sum(node_cpu_seconds_total)[5m])`) mathematically incorrect in PromQL?
2. What is the fundamental operational drawback of using `Summary` metrics compared to `Histogram` metrics in multi-node production clusters?
3. How does `irate()` differ from `rate()`, and in what monitoring scenario should `irate()` be avoided for long-term alerting?

---

## 4. Exercise 3: Alerting Pipeline, Alertmanager Configuration, and Failure Diagnosis

### Step 1: Configure Alertmanager Routes and Receivers
Create `~/prometheus-lab/config/alertmanager.yml` to define grouping, inhibition, and routing pipelines.

Write `~/prometheus-lab/config/alertmanager.yml`:
```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  receiver: 'default-webhook'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-high-priority'
      continue: false

inhibit_rules:
  - source_match:
      alertname: 'NodeExporterDown'
    target_match:
      severity: 'warning'
    equal: ['instance']

receivers:
  - name: 'default-webhook'
    webhook_configs:
      - url: 'http://127.0.0.1:5001/webhook'
        send_resolved: true

  - name: 'pagerduty-high-priority'
    webhook_configs:
      - url: 'http://127.0.0.1:5002/pagerduty'
        send_resolved: true
```

### Step 2: Validate Alertmanager Syntax via `amtool`
Execute validation using `amtool`:
```bash
docker exec -it alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```

Expected Output:
```text
Checking '/etc/alertmanager/alertmanager.yml'  SUCCESS
```

### Step 3: Trigger a Simulated Failure
Simulate a target failure by stopping the Node Exporter container to transition `NodeExporterDown` from `Pending` to `Firing`.

Execute:
```bash
docker stop node_exporter
```

Wait 35 seconds, then check the Prometheus Alerts API:

Execute:
```bash
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {alertname: .labels.alertname, state: .state, activeAt: .activeAt}'
```

Expected Output:
```json
{
  "alertname": "NodeExporterDown",
  "state": "firing",
  "activeAt": "2026-08-07T08:35:10.512Z"
}
```

### Step 4: Inspect Alertmanager Active Alerts
Verify that Prometheus successfully forwarded the firing alert to Alertmanager.

Execute:
```bash
docker exec -it alertmanager amtool alert --alertmanager.url=http://localhost:9093
```

Expected Output:
```text
Alertname         Starts At                Summary
NodeExporterDown  2026-08-07 08:35:10 UTC  Node Exporter instance localhost:9100 is unreachable
```

### Step 5: Implement an Operational Silence
To prevent alert fatigue during scheduled maintenance, place an operational silence using `amtool`.

Execute:
```bash
docker exec -it alertmanager amtool silence add \
  --alertmanager.url=http://localhost:9093 \
  --author="SRE-OnCall" \
  --comment="Scheduled maintenance window for node exporter" \
  --duration=1h \
  alertname="NodeExporterDown"
```

Expected Output:
```text
4a8b1c9d-8e7f-4a3b-2c1d-0e9f8a7b6c5d
```

Verify active silences:
```bash
docker exec -it alertmanager amtool silence query --alertmanager.url=http://localhost:9093
```

Expected Output:
```text
ID                                    Matchers                  Ends At                  Created By  Comment
4a8b1c9d-8e7f-4a3b-2c1d-0e9f8a7b6c5d  alertname=NodeExporterDown 2026-08-07 09:35:10 UTC  SRE-OnCall  Scheduled maintenance window for node exporter
```

Clean up environment:
```bash
docker start node_exporter
```

---

### Verification Questions (Exercise 3)

1. What happens when an alert matches an inhibition rule in Alertmanager?
2. What is the role of `group_wait` versus `group_interval` in Alertmanager routing trees?
3. If an alert state is `Pending` in Prometheus, does Alertmanager send notifications to receivers (e.g., PagerDuty)? Explain the mechanics.

---

## 5. Solutions and Comprehensive Explanations

<details>
<summary>Click to expand Answers and Detailed Explanations</summary>

### Exercise 1 Answers

1. **`relabel_configs` vs `metric_relabel_configs`**:
   * `relabel_configs` takes place **before** the target is scraped, during the service discovery phase. It modifies target metadata labels (e.g., `__address__`, `__scheme__`) to determine *if* and *how* Prometheus should scrape the target.
   * `metric_relabel_configs` occurs **after** the scrape completes, but **before** samples are written into the TSDB. It allows operators to drop unneeded metrics (`action: drop`), rewrite metric names, or strip expensive high-cardinality labels to save storage.

2. **Isolating YAML Parsing Failures**:
   * YAML errors are typically caused by invalid indentation (mixing tabs and spaces), unescaped template brackets (`{{ }}`), or invalid mapping keys.
   * *Systematic Isolation*:
     1. Run `promtool check config <path>` to obtain the precise line number.
     2. Inspect the file around the line using `sed -n '5,15p' file.yml` or `cat -A file.yml` (to expose tab characters `^I`).
     3. Verify block scalar quotes around PromQL expressions or Go templates (e.g. `description: "Value is {{ $value }}"`).

3. **Impact of `--web.enable-lifecycle`**:
   * Enabling `--web.enable-lifecycle` exposes HTTP administrative endpoints (`POST /-/reload` and `POST /-/quit`).
   * It allows operators or CI/CD pipelines to dynamically reload Prometheus rules and configurations without restarting the container process (`curl -X POST http://localhost:9090/-/reload`), ensuring zero monitoring downtime.
   * *Security Risk*: If unauthenticated, unauthorized users can reload bad configs or terminate Prometheus.

---

### Exercise 2 Answers

1. **`sum()` before `rate()` Inaccuracy**:
   * Counter metrics reset to `0` whenever a process restarts. The `rate()` function detects counter decreases (e.g., $100 \to 2$) and implicitly adds the pre-reset value ($100$) to compensate for the reset.
   * If `sum()` is executed before `rate()` (i.e. `rate(sum(counter)[5m])`), individual instance resets are hidden inside the combined sum. When one instance restarts, `sum()` drops slightly, causing `rate()` to falsely interpret the change as a single counter reset across the entire aggregate, corrupting math calculations.

2. **Drawback of Client-Side `Summary` Metrics**:
   * `Summary` metrics calculate quantiles (e.g., $p99$) on the application client using sliding time windows and output pre-computed float values.
   * Quantiles are non-aggregatable across instances. Calculating the average of $p99$ summaries across 10 pods ($\text{avg}(p99)$) is mathematically invalid and yields inaccurate latency representations. `Histograms` export raw cumulative bucket counters (`_bucket`), allowing PromQL (`histogram_quantile()`) to accurately compute cluster-wide percentiles.

3. **`irate()` vs `rate()` Mechanics**:
   * `rate()` calculates the average per-second growth rate over the entire time window (e.g., `[5m]`) by comparing the first and last points in the range. It smooths out spikes and is ideal for alerting rules.
   * `irate()` (instant rate) calculates the per-second rate based strictly on the last **two** data points within the range window. It reacts instantly to rapid bursts, making it ideal for high-resolution dashboards, but prone to false alarms if used in alerting rules due to metric volatility.

---

### Exercise 3 Answers

1. **Alertmanager Inhibition Mechanics**:
   * Inhibition suppresses notifications for target alerts if a source alert matching specific criteria is already firing.
   * *Example*: If `NodeExporterDown` (source) is firing for `instance="host-1"`, Alertmanager inhibits `HighCpuUtilization` (target) for `instance="host-1"`. This prevents notification floods during infrastructure outages.

2. **`group_wait` vs `group_interval`**:
   * `group_wait`: The initial delay Alertmanager waits before sending the very first notification for a newly created group of alerts. This buffers initial alerts to batch related issues occurring at the same time into a single alert payload.
   * `group_interval`: The interval Alertmanager waits before sending update notifications about new alerts added to an *already existing* active group.

3. **Alert Pending State Mechanics**:
   * An alert in the `Pending` state has satisfied the PromQL expression (`expr`), but has not yet met the required duration specified by the `for:` clause (e.g., `for: 2m`).
   * During `Pending`, Prometheus tracks the duration locally. **Alertmanager does NOT receive or dispatch notifications** while the alert is `Pending`. Notifications are routed to Alertmanager only after the condition persists beyond the `for:` duration, transitioning the state to `Firing`.

</details>