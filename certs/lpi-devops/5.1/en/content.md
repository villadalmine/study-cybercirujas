# Study Material: LPI DevOps Tools Engineer (Exam 701-100)
## Topic 705.1: IT Operations and Monitoring (Weight: 6.67)

---

## 1. Motivation & Production Architectural Problem

### 1.1 The Operational Paradigm Shift
In legacy monolithic environments, system monitoring was predominantly static, host-centric, and black-box driven. Operators relied on periodic ICMP ping sweeps and NRPE/SNMP checks (e.g., via Nagios or Zabbix) to determine node reachability and process existence. This model fails in modern microservices, containerized infrastructure, and cloud-native environments due to several operational reality shifts:

1. **Short-Lived & Dynamic Ephemerality**: Pods and containers scale elastically and live for hours or minutes. Static IP configuration files are incapable of tracking dynamic workloads.
2. **High-Dimensionality**: Distributed systems fail in complex, partial modes. Knowing whether a host is alive is insufficient; engineers need visibility into per-endpoint HTTP status codes, gRPC status codes, queue depth rates, database pool exhaustion, and tail latencies across hundreds of microservices.
3. **Black-Box Limitations**: External polling cannot inspect application internal states, garbage collection pauses, thread pool queue lengths, or memory heap allocations.

### 1.2 The Production Architectural Problem
Consider an enterprise Kubernetes cluster hosting 50 microservices across 200 nodes executing 3,000 pod replicas. The infrastructure experiences dynamic autoscaling, frequent deployment rollouts, and multi-tenant isolation. 

```
                                 [ Push / Pull Topology Boundary ]
                                                 │
┌─────────────────────────┐                      │      ┌───────────────────────────────┐
│ Dynamic Kubernetes Pods │ ──(Scrape / Pull)───┼────► │   Prometheus Server (TSDB)    │
│  [ App A ] [ App B ]    │   HTTP /metrics      │      │ ┌───────────┐ ┌─────────────┐ │
└─────────────────────────┘                      │      │ │ Head Block│ │ Compaction  │ │
             │                                   │      │ └───────────┘ └─────────────┘ │
             ▼ (Ephemeral Jobs)                  │      └───────────────┬───────────────┘
┌─────────────────────────┐                      │                      │ Evaluates
│  Batch / Serverless     │ ──(Push Metrics)───► │ ┌──────────────────┐ │ Alert Rules
│  [ Short-Lived Jobs ]   │   HTTP POST          │ │  Pushgateway     │◄┘
└─────────────────────────┘                      │ └──────────────────┘ 
                                                 │                      │ Routes Alerts
                                                 │                      ▼
                                                 │      ┌───────────────────────────────┐
                                                 │      │         Alertmanager          │
                                                 │      └───────────────┬───────────────┘
                                                 │                      │
                                                 │                      ▼
                                                 │            [ PagerDuty / Slack ]
```

Implementing observability in this architecture introduces core engineering challenges:

* **High-Cardinality Explosion**: Metrics appended with high-cardinality labels (e.g., `user_id`, `email`, `order_id`, raw un-redacted URLs) cause exponential growth in time series index keys, crashing Time Series Databases (TSDB) due to Out-Of-Memory (OOM) conditions.
* **Scrape Target Discovery Overhead**: Manual target maintenance is impossible. The monitoring control plane must continuously interface with the Kubernetes API server (`Endpoints`, `Services`, `Pods`) to update scrape targets dynamically without losing metrics during pod churn.
* **Network Topology & NAT Boundaries**: Scrape engines rely on a **Pull-based** architecture over HTTP/HTTPS. When targets reside behind strict NAT gateways, edge routers, or inside isolated security enclaves, a pure pull model fails without intermediate proxy components such as the Prometheus `Pushgateway` or edge proxies.

### 1.3 Service Level Terminology & Observability Frameworks

#### 1.3.1 Service Level Specifications (SLA, SLO, SLI)
* **SLI (Service Level Indicator)**: A carefully defined quantitative measure of a service's performance observed in real time.
  $$\text{SLI} = \frac{\text{Good Events}}{\text{Total Events}} \times 100$$
  *Example PromQL*:
  ```promql
  sum(rate(http_requests_total{job="payment-service", status=~"2..|3.."}[5m]))
  /
  sum(rate(http_requests_total{job="payment-service"}[5m]))
  ```
* **SLO (Service Level Objective)**: A target value or range of values for a service level that is measured by an SLI, agreed upon by product and SRE teams (e.g., "Payment API latency SLI must be < 200ms for 99.9% of requests over a rolling 30-day window").
* **SLA (Service Level Agreement)**: An explicit or implicit contract with end-users that includes financial or legal consequences for missing SLOs.

#### 1.3.2 Functional vs. Non-Functional Monitoring
* **Functional Properties**: Verification that business logic produces correct outcomes (e.g., order processing completion, database transaction commit validation).
* **Non-Functional Properties**: Verification of system operational metrics (e.g., resource utilization, system availability, throughput, error rates, latency distribution).

#### 1.3.3 Observability Frameworks
* **The 4 Golden Signals (Google SRE)**:
  1. **Latency**: The time taken to service a request (distinguishing between successful and failed request latencies).
  2. **Traffic**: The demand placed on the system (e.g., HTTP requests per second, I/O operations/sec).
  3. **Errors**: The rate of requests that fail explicitly (HTTP 5xx), implicitly (HTTP 200 containing failure payload), or by policy timeout.
  4. **Saturation**: The measure of system fullness (e.g., CPU utilization, memory pressure, thread pool saturation, disk space).
* **RED Method (Services)**: **R**ate (requests/sec), **E**rrors (failed requests/sec), **D**uration (latency distribution).
* **USE Method (Hardware/Nodes)**: **U**tilization (percent time busy), **S**aturation (queue length), **E**rrors (error count).

---

## 2. Technical Comparisons & Architecture Trade-Offs

### 2.1 Black-Box vs. White-Box Monitoring
Black-box monitoring treats the system as a black box, testing external behavior without internal access. White-box monitoring inspects internal metrics exposed by application code via instrumentation libraries.

| Technical Metric / Feature | Black-Box Monitoring (e.g., Ping, Synthetic HTTP Check) | White-Box Monitoring (e.g., Prometheus Exporters, Client SDKs) |
| :--- | :--- | :--- |
| **Visibility Scope** | External availability, network reachability, TLS certificate validity. | Internal queues, thread pool states, memory heap usage, garbage collection, DB pool locks. |
| **Root Cause Attribution** | Low. Indicates *that* a service is unreachable or failing. | High. Explains *why* a service is failing (e.g., DB pool exhaustion, heap OOM). |
| **Network Footprint** | External HTTP/ICMP probes originating outside the service mesh. | In-process scrape endpoints (`/metrics`) pulled over local network fabrics. |
| **Detection Speed** | Polling intervals (e.g., 30s–60s); high latency for failure detection. | Real-time metric scraping (e.g., 5s–15s); sub-second internal counter updates. |
| **Maintenance Cost** | Low initial setup; fragile to UI or public API schema changes. | Requires application code instrumentation, library dependencies, and metric maintenance. |

### 2.2 Pull vs. Push Metrics Architecture

| Dimension | Pull Model (e.g., Native Prometheus) | Push Model (e.g., StatsD, Graphite, Pushgateway) |
| :--- | :--- | :--- |
| **Control Plane Centralization** | Central server controls scrape frequency, jitter, and target discovery. | Application instances independently decide when and where to send data. |
| **Target Liveness Detection** | Immediate. If a scrape fails (`up == 0`), Prometheus records target failure. | Indirect. Absence of data can mean either target is idle or target has crashed. |
| **Overload Protection** | High. Server throttles metric ingestion by controlling scrape loops. | Low. Sudden traffic surges cause client code to flood monitoring backends. |
| **Short-Lived / Batch Jobs** | Complex. Requires intermediate buffering like `Pushgateway`. | Native. Batch job pushes metrics upon execution completion and exits immediately. |
| **Network / Firewall Complexity**| Requires direct network access from Prometheus server to pod IP/port. | Easy behind NAT; outbound traffic from app to backend is allowed by default. |

### 2.3 TSDB Storage Architecture Comparison

| Architecture | Storage Engine Mechanics | High Availability (HA) Model | Horizontal Scalability |
| :--- | :--- | :--- | :--- |
| **Prometheus Native TSDB** | Local disk append-only WAL (Write-Ahead Log), 2-hour immutable blocks, memory mapped chunks. | Shared-nothing dual scraping (independent identical Prometheus instances). | Vertical scaling only; no native horizontal multi-node sharding. |
| **Thanos** | Sidecar/Receiver architecture uploading compacted TSDB blocks to Object Storage (S3/GCS). | Global Query Engine deduplicating metrics across replica pairs. | Unlimited horizontal storage scaling via object store + stateless query layer. |
| **VictoriaMetrics** | MergeTree-like architecture, custom encoding, optimized memory allocation. | Cluster version with split Storage, Index, and Router nodes. | High native horizontal scaling with low CPU and RAM consumption. |

---

## 3. Production-Grade Manifests & Configuration

### 3.1 Server Configuration Manifest (`prometheus.yml`)
The following manifest defines a production-ready Prometheus instance including Kubernetes endpoint discovery, advanced relabeling rules, and Alertmanager routing.

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s
  external_labels:
    cluster: 'prod-us-east-1'
    environment: 'production'

alerting:
  alertmanagers:
    - scheme: http
      path_prefix: /
      timeout: 10s
      kubernetes_sd_configs:
        - role: endpoints
          namespaces:
            names:
              - monitoring
      relabel_configs:
        - source_labels: [__meta_kubernetes_service_name]
          action: keep
          regex: alertmanager
        - source_labels: [__meta_kubernetes_endpoint_port_name]
          action: keep
          regex: web

rule_files:
  - "/etc/prometheus/rules/*.rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - monitoring
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        action: keep
        regex: node-exporter
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

  - job_name: 'kubernetes-cadvisor'
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    kubernetes_sd_configs:
      - role: node
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor

  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: 'true'
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
```

### 3.2 Alertmanager Configuration (`alertmanager.yml`)
Production Alertmanager manifest with routing trees, alert grouping, inhibition rules, and Slack/PagerDuty integration receivers.

```yaml
global:
  resolve_timeout: 5m
  pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'
  slack_api_url: 'https://hooks.slack.com/services/WORKSPACE/CHANNEL/TOKEN'

route:
  group_by: ['cluster', 'namespace', 'alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'slack-default'
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-high-priority'
      continue: true
    - match:
        severity: warning
      receiver: 'slack-warnings'

inhibit_rules:
  - source_match:
      alertname: 'NodeDown'
    target_match:
      alertname: 'InstanceDown'
    equal: ['node']

receivers:
  - name: 'slack-default'
    slack_configs:
      - channel: '#ops-alerts'
        send_resolved: true
        title: '][ Cluster: '
        text: "<!subteam^S0000000> *Description:* \n*Details:*\n"

  - name: 'slack-warnings'
    slack_configs:
      - channel: '#ops-warnings'
        send_resolved: true
        title: '][ Cluster: '
        text: "*Alert:* \n*Summary:* "

  - name: 'pagerduty-high-priority'
    pagerduty_configs:
      - service_key: 'b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d3'
        severity: 'critical'
        send_resolved: true
```

### 3.3 Recording & Alerting Rules (`slos-and-alerts.rules.yml`)
Complete rule definitions calculating 5-minute request error ratios (SLIs) and generating actionable production alerts.

```yaml
groups:
  - name: api_sli_slo_rules
    rules:
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job, status)

      - record: job:http_requests_errors:ratio_rate5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
          /
          sum(rate(http_requests_total[5m])) by (job)

  - name: infrastructure_alert_rules
    rules:
      - alert: TargetServiceDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Prometheus target unreachable: {{ $labels.instance }}"
          description: "Target {{ $labels.instance }} of job {{ $labels.job }} has been down for more than 3 minutes."

      - alert: APIHighErrorRate
        expr: job:http_requests_errors:ratio_rate5m{job="payment-api"} > 0.05
        for: 5m
        labels:
          severity: critical
          team: payments
        annotations:
          summary: "High HTTP 5xx Error Rate on {{ $labels.job }}"
          description: "Payment API error rate is {{ $value | humanizePercentage }} (threshold > 5%) over 5 minutes."

      - alert: NodeMemorySaturation
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.90
        for: 10m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "High Memory Utilization on Node {{ $labels.instance }}"
          description: "Node memory usage is at {{ $value | humanizePercentage }} for over 10 minutes."
```

### 3.4 Complete Kubernetes Deployment Manifest (`prometheus-deployment.yaml`)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus-k8s
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/metrics
  - services
  - endpoints
  - pods
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources:
  - configmaps
  verbs: ["get"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prometheus-k8s
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: prometheus-k8s
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-server
  namespace: monitoring
  labels:
    app: prometheus
    component: server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
      component: server
  template:
    metadata:
      labels:
        app: prometheus
        component: server
    spec:
      serviceAccountName: prometheus-k8s
      containers:
      - name: prometheus
        image: prom/prometheus:v2.45.0
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--storage.tsdb.path=/prometheus"
          - "--storage.tsdb.retention.time=15d"
          - "--storage.tsdb.retention.size=50GB"
          - "--web.enable-lifecycle"
        ports:
          - name: web
            containerPort: 9090
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2000m"
            memory: "4Gi"
        securityContext:
          runAsUser: 65534
          runAsGroup: 65534
          runAsNonRoot: true
          readOnlyRootFilesystem: true
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 3
        livenessProbe:
          httpGet:
            path: /-/healthy
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 3
        volumeMounts:
        - name: config-volume
          mountPath: /etc/prometheus
        - name: rules-volume
          mountPath: /etc/prometheus/rules
        - name: storage-volume
          mountPath: /prometheus
      volumes:
      - name: config-volume
        configMap:
          name: prometheus-core-config
      - name: rules-volume
        configMap:
          name: prometheus-rules-config
      - name: storage-volume
        emptyDir: {}
```

---

## 4. CLI Commands & Terminal Execution Traces

### 4.1 Config & Rules Syntax Validation (`promtool`)

The `promtool` utility is the standard CLI tool for validating configuration syntax and testing alerting logic before deployment.

```bash
$ promtool check config /etc/prometheus/prometheus.yml
Checking /etc/prometheus/prometheus.yml
  SUCCESS: 1 rule files found
  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file
```

```bash
$ promtool check rules /etc/prometheus/rules/slos-and-alerts.rules.yml
Checking /etc/prometheus/rules/slos-and-alerts.rules.yml
  SUCCESS: 3 rules found
```

### 4.2 Querying Prometheus Instant & Range APIs via `curl`

#### Instant Query Execution (`/api/v1/query`)
Executing an instant Query against the Prometheus HTTP API to compute current HTTP request rates:

```bash
$ curl -s -X POST http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total[5m])) by (job)' | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "job": "payment-api"
        },
        "value": [
          1691398800.123,
          "142.85"
        ]
      },
      {
        "metric": {
          "job": "user-service"
        },
        "value": [
          1691398800.123,
          "48.12"
        ]
      }
    ]
  }
}
```

#### Range Query Execution (`/api/v1/query_range`)
Fetching latency trends over a 15-minute window with a 5-minute step resolution:

```bash
$ curl -s -X POST http://prometheus.monitoring.svc.cluster.local:9090/api/v1/query_range \
  -d "query=histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))" \
  -d "start=1691395200" \
  -d "end=1691396100" \
  -d "step=300s" | jq .
```
```json
{
  "status": "success",
  "data": {
    "resultType": "matrix",
    "result": [
      {
        "metric": {},
        "values": [
          [ 1691395200, "0.145" ],
          [ 1691395500, "0.152" ],
          [ 1691395800, "0.489" ],
          [ 1691396100, "0.138" ]
        ]
      }
    ]
  }
}
```

### 4.3 TSDB Ingestion & Storage Block Analysis

Analyzing TSDB storage directory cardinality, series count, and label footprint directly on disk using `promtool`:

```bash
$ promtool tsdb analyze /prometheus
Block ID: 01H77F4P3Z3V8B9K019M7V0Z8K
Duration: 2h0m0s
Series: 145210
Label names: 42
Postings (label name -> label value pairs): 8920

Top 10 label names by series count:
  namespace: 145210
  pod: 138400
  container: 122100
  instance: 98400
  job: 98400
  __name__: 85400
  status: 42000
  le: 32000
  method: 18000
  endpoint: 12000

Top 10 highest cardinality labels:
  pod: 1420
  instance: 210
  endpoint: 84
  __name__: 642
  status: 12
```

### 4.4 Dynamic Configuration Reloading via HTTP

Triggering hot config reload without restarting the Prometheus process container:

```bash
$ curl -X POST http://localhost:9090/-/reload
$ echo $?
0
```

---

## 5. Verification, Failure Diagnosis & SRE Troubleshooting

### 5.1 Scrape Target Failure Diagnosis (`UP == 0`)

#### Symptom
Alert `TargetServiceDown` triggers. PromQL query `up{job="payment-api"} == 0` returns active vector results.

#### Diagnostic Playbook
1. **Inspect Target State via Prometheus API**:
   Query target status endpoint to obtain scrape error messages:
   ```bash
   $ curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="payment-api")'
   ```
   *Expected Error Snippet Output*:
   ```json
   {
     "discoveredLabels": {
       "__address__": "10.244.3.45:8080"
     },
     "labels": {
       "instance": "10.244.3.45:8080",
       "job": "payment-api"
     },
     "scrapeUrl": "http://10.244.3.45:8080/metrics",
     "lastError": "context deadline exceeded",
     "lastScrape": "2026-08-07T08:15:30.12345678Z",
     "health": "unhealthy"
   }
   ```

2. **Network Connectivity & Firewall Verification**:
   Execute `curl` or `nc` from within the Prometheus container namespace to test endpoint reachability:
   ```bash
   $ kubectl exec -n monitoring deploy/prometheus-server -c prometheus -- \
     curl -iv -m 5 http://10.244.3.45:8080/metrics
   ```
   *Failure Indication*:
   `curl: (28) Connection timed out after 5001 milliseconds`

3. **Root Cause Analysis & Resolution Matrix**:
   * **`context deadline exceeded`**: Target metric payload generation is too slow (> `scrape_timeout`). *Fix*: Optimize application metric collection logic or increase `scrape_timeout`.
   * **`connection refused`**: Application is not listening on port 8080 or process crashed. *Fix*: Inspect `kubectl logs` and `kubectl describe pod`.
   * **`HTTP 404 Not Found`**: Metrics path mismatch (`/metrics` vs `/actuator/prometheus`). *Fix*: Correct target `prometheus.io/path` annotations.

### 5.2 High-Cardinality Out-Of-Memory (OOMKilled) Troubleshooting

#### Symptom
Prometheus process crashes repeatedly with Linux kernel `OOMKilled` status (exit code 137). RAM usage spikes exponentially upon target ingestion.

#### Diagnostic & Mitigation Playbook
1. **Locate High-Cardinality Metrics**:
   Query the Prometheus runtime TSDB status endpoint:
   ```bash
   $ curl -s http://localhost:9090/api/v1/status/tsdb | jq .data.headStats
   ```
   ```json
   {
     "numSeries": 2450190,
     "numLabelPairs": 120490,
     "chunkCount": 4901200,
     "minTime": 1691395200000,
     "maxTime": 1691402400000
   }
   ```

2. **Identify Problematic Metrics & Labels**:
   Use `promtool` or administrative query endpoints to expose high-cardinality label names:
   ```bash
   $ curl -s http://localhost:9090/api/v1/status/tsdb | jq .data.seriesCountByMetricName
   ```
   *Output Example*:
   ```json
   [
     { "name": "http_requests_total", "value": 1850000 },
     { "name": "node_cpu_seconds_total", "value": 45000 }
   ]
   ```

3. **Remediation via Metric Relabeling (`metric_relabel_configs`)**:
   Drop non-compliant labels (e.g., `user_id`, `client_ip`, `order_uuid`) *before* ingestion into storage:
   ```yaml
   scrape_configs:
     - job_name: 'payment-api'
       metric_relabel_configs:
         - source_labels: [__name__]
           regex: 'http_requests_total'
           action: keep
         - regex: '(user_id|client_ip|order_uuid)'
           action: labeldrop
   ```

### 5.3 Prometheus Pushgateway Ephemeral Job Stale Metrics

#### Technical Pitfall
Unlike standard pull targets, the `Pushgateway` retains pushed time-series metrics indefinitely until they are explicitly deleted via API calls. If a batch job fails or ceases to run, Pushgateway continues serving the last pushed metric set to Prometheus, presenting false healthy status.

#### Mitigating Production Architecture
1. **Pushgateway Textfile Exporter Pattern**: For batch workloads on nodes, prefer the Node Exporter `textfile` collector over Pushgateway when possible.
2. **Automated Metrics Deletion**: Implement explicit cleanup steps in batch job wrappers using HTTP `DELETE` calls upon job completion:
   ```bash
   # Push metrics on job start
   echo "job_last_run_timestamp_seconds $(date +%s)" | \
     curl --data-binary @- http://pushgateway.monitoring.svc:9191/metrics/job/nightly_batch/instance/node-01

   # Execute batch operation
   /usr/local/bin/run_batch.sh

   # Explicitly wipe metrics from Pushgateway upon termination
   curl -X DELETE http://pushgateway.monitoring.svc:9191/metrics/job/nightly_batch/instance/node-01
   ```

---

## 6. References

* **Linux Professional Institute (LPI) DevOps Tools Engineer (Exam 701-100 Overview)**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Prometheus Official Documentation (Configuration & Architecture)**  
  [https://prometheus.io/docs/prometheus/latest/configuration/configuration/](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
* **Prometheus Alerting Rules & Alertmanager Routing**  
  [https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
* **Google Site Reliability Engineering (SRE) Book: Monitoring Distributed Systems**  
  [https://sre.google/sre-book/monitoring-distributed-systems/](https://sre.google/sre-book/monitoring-distributed-systems/)
* **Google SRE Book: Service Level Objectives**  
  [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
* **CNCF Prometheus TSDB Storage Format Specification**  
  [https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/README.md](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/README.md)