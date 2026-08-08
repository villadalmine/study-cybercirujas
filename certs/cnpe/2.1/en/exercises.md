# Exercises — 2.1 Implementing Monitoring, Alerting, Logging, and Tracing Solutions

> **Prerequisites.** A working Kubernetes cluster (`kind`, `minikube`, or a real one) with `kubectl` context set, Helm 3.x installed, and cluster-admin on a throwaway namespace. Every exercise cleans up after itself. Commands assume `bash`. When you see `# →` it marks *expected output* — yours will differ in timestamps and generated suffixes, not in shape.
>
> These exercises build the **four observability signals** — metrics, alerts, logs, traces — the way a platform team ships them: as a self-service capability other teams consume, not a one-off dashboard. We use the CNCF-graduated projects named in the curriculum: Prometheus, Alertmanager, OpenTelemetry, Jaeger, plus Grafana Loki for logs.

---

## Exercise 1 — Stand up Prometheus with the Operator and scrape a workload

The Prometheus Operator turns "configure Prometheus" into "create Kubernetes objects". Instead of editing `prometheus.yml` by hand, you declare a `Prometheus` CR and let `ServiceMonitor`/`PodMonitor` objects tell it what to scrape. This is the platform-engineering pattern: app teams drop a `ServiceMonitor` next to their Deployment and get scraped automatically, with no central config edit.

### Steps

1. Create the namespace and install `kube-prometheus-stack` (bundles the Operator, Prometheus, Alertmanager, Grafana, and the `kube-state-metrics` + `node-exporter` exporters):

   ```bash
   kubectl create namespace observability
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install kps prometheus-community/kube-prometheus-stack \
     --namespace observability \
     --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
     --set prometheus.prometheusSpec.retention=6h
   ```

   > The `serviceMonitorSelectorNilUsesHelmValues=false` flag is the one people miss. By default the chart makes Prometheus only pick up `ServiceMonitor`s carrying the Helm release label. Setting it `false` makes Prometheus select **every** `ServiceMonitor` in the cluster — the behaviour you want for a shared platform.

2. Wait for the stack and confirm the Operator created the core objects:

   ```bash
   kubectl -n observability rollout status statefulset/prometheus-kps-kube-prometheus-stack-prometheus
   kubectl -n observability get prometheus,alertmanager,servicemonitor | head
   # → prometheus.monitoring.coreos.com/kps-kube-prometheus-stack-prometheus   2h
   # → alertmanager.monitoring.coreos.com/kps-kube-prometheus-stack-alertmanager   2h
   ```

3. Deploy a workload that already exposes Prometheus metrics — the `prometheus-example-app` publishes an HTTP handler at `/metrics`:

   ```yaml
   # sample-app.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: sample-app
     namespace: observability
     labels: { app: sample-app }
   spec:
     replicas: 2
     selector: { matchLabels: { app: sample-app } }
     template:
       metadata:
         labels: { app: sample-app }
       spec:
         containers:
           - name: app
             image: ghcr.io/prometheus/prometheus-example-app:latest
             ports:
               - name: metrics          # named port — the ServiceMonitor references it by name
                 containerPort: 8080
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: sample-app
     namespace: observability
     labels: { app: sample-app }
   spec:
     selector: { app: sample-app }
     ports:
       - name: metrics
         port: 8080
         targetPort: metrics
   ```

   ```bash
   kubectl apply -f sample-app.yaml
   ```

4. Tell Prometheus to scrape it with a `ServiceMonitor`. Note the selector matches the **Service** labels, and `endpoints.port` matches the **named** Service port:

   ```yaml
   # sample-app-servicemonitor.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: ServiceMonitor
   metadata:
     name: sample-app
     namespace: observability
     labels: { app: sample-app }
   spec:
     selector:
       matchLabels: { app: sample-app }
     endpoints:
       - port: metrics                  # matches Service port NAME, not number
         interval: 15s
         path: /metrics
   ```

   ```bash
   kubectl apply -f sample-app-servicemonitor.yaml
   ```

5. Port-forward Prometheus and confirm the target is **UP**. Give the Operator ~30 s to reconcile the config into the Prometheus pod first:

   ```bash
   kubectl -n observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
   sleep 5
   curl -s 'http://localhost:9090/api/v1/targets?state=active' \
     | jq -r '.data.activeTargets[] | select(.labels.service=="sample-app") | "\(.scrapeUrl) \(.health)"'
   # → http://10.244.0.14:8080/metrics up
   # → http://10.244.0.15:8080/metrics up
   ```

6. Query a metric the app exports, over the HTTP API:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=up{service="sample-app"}' \
     | jq '.data.result[] | {pod: .metric.pod, value: .value[1]}'
   # → { "pod": "sample-app-6c9f...-abcde", "value": "1" }
   # → { "pod": "sample-app-6c9f...-fghij", "value": "1" }
   ```

### Comprehension check

- **1a.** A colleague creates a `ServiceMonitor` and the target never appears in Prometheus. List the three most common causes given how the object is wired (label selector, port, and Operator selection).
- **1b.** Why does `ServiceMonitor.spec.endpoints[].port` take a *string* (the port name) rather than the port number, and what breaks if the Service port is unnamed?
- **1c.** What is the difference between a `ServiceMonitor` and a `PodMonitor`, and when must you use the latter?
- **1d.** The metric `up` was not defined by the application. Where does it come from, and what exactly does `up == 0` tell you versus `up` being absent entirely?

---

## Exercise 2 — Recording rules and PromQL for a RED/SLI view

Raw metrics are cheap to collect and expensive to query. Recording rules pre-compute the expressions dashboards and alerts hit thousands of times, so you evaluate the heavy `rate()`/`histogram_quantile()` once per interval instead of once per query. This exercise builds the **RED** signals (Rate, Errors, Duration) that most SLOs rest on.

### Steps

1. Generate some traffic so the app's `http_requests_total` counter moves. The example app increments it on every request to `/`:

   ```bash
   kubectl -n observability port-forward svc/sample-app 8080:8080 &
   sleep 3
   for i in $(seq 1 300); do curl -s -o /dev/null "http://localhost:8080/"; done
   # also generate some errors (the app returns 404 for unknown paths)
   for i in $(seq 1 40); do curl -s -o /dev/null "http://localhost:8080/nope"; done
   ```

2. In the Prometheus UI (`http://localhost:9090`), evaluate the **request rate** per pod over 5 minutes:

   ```promql
   sum by (pod) (rate(http_requests_total{service="sample-app"}[5m]))
   ```

3. Evaluate the **error ratio** — the fraction of responses with a 5xx (or here, non-2xx) status code. Note the label matching and the guard against divide-by-zero via the numerator/denominator both being rates:

   ```promql
   sum(rate(http_requests_total{service="sample-app", code=~"5.."}[5m]))
     /
   sum(rate(http_requests_total{service="sample-app"}[5m]))
   ```

4. Create a `PrometheusRule` with **recording rules** that materialise those SLIs. Recording rule names follow the convention `level:metric:operation`:

   ```yaml
   # sample-app-recording-rules.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: sample-app-slis
     namespace: observability
     labels: { role: alert-rules }
   spec:
     groups:
       - name: sample-app.sli
         interval: 30s
         rules:
           - record: job:http_requests:rate5m
             expr: sum by (job) (rate(http_requests_total{service="sample-app"}[5m]))
           - record: job:http_requests_errors:ratio5m
             expr: |
               sum by (job) (rate(http_requests_total{service="sample-app", code=~"5.."}[5m]))
                 /
               sum by (job) (rate(http_requests_total{service="sample-app"}[5m]))
   ```

   ```bash
   kubectl apply -f sample-app-recording-rules.yaml
   ```

5. Confirm the rule group loaded and the recorded series exist:

   ```bash
   curl -s 'http://localhost:9090/api/v1/rules?type=record' \
     | jq -r '.data.groups[] | select(.name=="sample-app.sli") | .rules[].name'
   # → job:http_requests:rate5m
   # → job:http_requests_errors:ratio5m

   curl -s 'http://localhost:9090/api/v1/query?query=job:http_requests:rate5m' \
     | jq '.data.result[].value[1]'
   # → "1.13"
   ```

### Comprehension check

- **2a.** You have `http_requests_total` as a **counter**. Why must every query wrap it in `rate()`/`increase()` before summing, and what wrong number do you get if you `sum()` the raw counter across pods?
- **2b.** A pod restarts and its counter resets to 0. Explain how `rate()` still returns a correct value across that reset — what does it assume?
- **2c.** Recording rules cost extra storage and evaluation. Give two concrete reasons a team still adopts them instead of putting the same expression directly in dashboards and alerts.
- **2d.** In step 3 the error ratio can produce no result (empty vector) rather than `0`. Under what traffic condition does that happen, and why is "no data" a genuinely different alerting state than "ratio is zero"?

---

## Exercise 3 — Alerting rules and Alertmanager routing

An alert has two halves: Prometheus **fires** it (a rule whose expression is true for `for` long enough), and Alertmanager **routes** it (deduplicates, groups, silences, and delivers). Confusing the two is the classic mistake — "the alert didn't page" is usually a routing problem, not a rule problem.

### Steps

1. Add an **alerting rule** to a `PrometheusRule`. It fires when the recorded error ratio exceeds 5% for 2 minutes. `for` is what separates a spike from an incident; labels drive routing; annotations are for humans:

   ```yaml
   # sample-app-alerts.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: sample-app-alerts
     namespace: observability
     labels: { role: alert-rules }
   spec:
     groups:
       - name: sample-app.alerts
         rules:
           - alert: SampleAppHighErrorRate
             expr: job:http_requests_errors:ratio5m > 0.05
             for: 2m
             labels:
               severity: critical
               team: payments
             annotations:
               summary: "High 5xx error ratio on sample-app"
               description: "Error ratio is {{ $value | humanizePercentage }} (threshold 5%) for 2m."
               runbook_url: "https://runbooks.example.com/sample-app/high-error-rate"
   ```

   ```bash
   kubectl apply -f sample-app-alerts.yaml
   ```

2. Watch the alert move through its lifecycle. Right after creation it is `inactive`; once the expression is true it becomes `pending`; after `for: 2m` it becomes `firing`:

   ```bash
   curl -s 'http://localhost:9090/api/v1/rules?type=alert' \
     | jq -r '.data.groups[].rules[] | select(.name=="SampleAppHighErrorRate") | .state'
   # → pending      (immediately after the expression first goes true)
   # → firing       (after 2 minutes sustained)
   ```

3. Configure Alertmanager routing with the Operator's `AlertmanagerConfig` CR. This routes `team=payments` critical alerts to a dedicated receiver, groups by alertname, and inhibits noise:

   ```yaml
   # payments-routing.yaml
   apiVersion: monitoring.coreos.com/v1alpha1
   kind: AlertmanagerConfig
   metadata:
     name: payments-routing
     namespace: observability
     labels: { alertmanagerConfig: payments }
   spec:
     route:
       receiver: 'payments-oncall'
       groupBy: ['alertname', 'team']
       groupWait: 30s
       groupInterval: 5m
       repeatInterval: 4h
       routes:
         - matchers:
             - name: severity
               value: critical
           receiver: 'payments-oncall'
     receivers:
       - name: 'payments-oncall'
         webhookConfigs:
           - url: 'http://alert-sink.observability.svc:8080/hook'
             sendResolved: true
   ```

   ```bash
   kubectl apply -f payments-routing.yaml
   ```

4. Verify the alert reached Alertmanager and shows the routing labels:

   ```bash
   kubectl -n observability port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093 &
   sleep 3
   curl -s 'http://localhost:9093/api/v2/alerts' \
     | jq -r '.[] | "\(.labels.alertname) \(.status.state) team=\(.labels.team)"'
   # → SampleAppHighErrorRate active team=payments
   ```

5. Silence the alert while you fix it, so on-call stops paging but the alert still evaluates:

   ```bash
   amtool --alertmanager.url=http://localhost:9093 silence add \
     alertname="SampleAppHighErrorRate" team="payments" \
     --duration="1h" --comment="Investigating under INC-1234" --author="you@example.com"
   # → 6f1c2e9a-...   (silence ID)
   ```

### Comprehension check

- **3a.** Explain the precise difference between `pending` and `firing`, and what the `for` field controls. Why is `for: 0` (or omitting it) dangerous for a noisy signal?
- **3b.** `groupWait`, `groupInterval`, and `repeatInterval` are three different timers. Match each to what it protects against: (i) an initial burst of related alerts, (ii) new alerts joining an existing group, (iii) re-notification of an unresolved alert.
- **3c.** A silence and an inhibition rule both suppress notifications. What is the semantic difference, and which one would you use to stop `HighLatency` alerts firing when the parent `ClusterDown` alert is already active?
- **3d.** The alert has both `labels` and `annotations`. Which of the two can you route or group on, and why must the runbook URL be an annotation and not a label?

---

## Exercise 4 — Centralised logging with Loki and a Fluent Bit forwarder

Metrics tell you *that* something is wrong; logs tell you *what*. Loki indexes only labels (not the log body), which is why it scales cheaply — but that same design punishes high-cardinality labels. This exercise ships container logs from every node into Loki via a Fluent Bit `DaemonSet`, then queries them with LogQL.

### Steps

1. Install Loki (single-binary mode is fine for a lab) and Fluent Bit:

   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo update
   helm install loki grafana/loki \
     --namespace observability \
     --set loki.auth_enabled=false \
     --set loki.commonConfig.replication_factor=1 \
     --set singleBinary.replicas=1 \
     --set deploymentMode=SingleBinary \
     --set 'loki.schemaConfig.configs[0].from=2024-01-01' \
     --set 'loki.schemaConfig.configs[0].store=tsdb' \
     --set 'loki.schemaConfig.configs[0].object_store=filesystem' \
     --set 'loki.schemaConfig.configs[0].schema=v13' \
     --set 'loki.schemaConfig.configs[0].index.prefix=index_' \
     --set 'loki.schemaConfig.configs[0].index.period=24h'
   ```

2. Deploy Fluent Bit as a `DaemonSet` (one pod per node) pointed at Loki. The key is the parser and the labels — keep labels to `namespace`, `pod`, `container`, never the log line contents:

   ```yaml
   # fluent-bit-values.yaml
   config:
     inputs: |
       [INPUT]
           Name              tail
           Path              /var/log/containers/*.log
           multiline.parser  cri
           Tag               kube.*
           Mem_Buf_Limit     5MB
           Skip_Long_Lines   On
     filters: |
       [FILTER]
           Name                kubernetes
           Match               kube.*
           Merge_Log           On
           Keep_Log            Off
           K8S-Logging.Parser  On
           K8S-Logging.Exclude On
     outputs: |
       [OUTPUT]
           Name                   loki
           Match                  kube.*
           Host                   loki-gateway.observability.svc
           Port                   80
           Labels                 job=fluentbit
           Label_keys             $kubernetes['namespace_name'],$kubernetes['pod_name'],$kubernetes['container_name']
           Auto_Kubernetes_Labels Off
   ```

   ```bash
   helm install fluent-bit grafana/fluent-bit \
     --namespace observability -f fluent-bit-values.yaml
   kubectl -n observability rollout status daemonset/fluent-bit
   ```

3. Query Loki directly for the sample app's logs with **LogQL**. The `{}` stream selector uses labels (indexed); the `|=` line filter greps the body (brute-forced over the selected streams):

   ```bash
   kubectl -n observability port-forward svc/loki-gateway 3100:80 &
   sleep 3
   curl -s -G 'http://localhost:3100/loki/api/v1/query_range' \
     --data-urlencode 'query={namespace_name="observability", pod_name=~"sample-app.*"}' \
     --data-urlencode 'limit=5' \
     | jq -r '.data.result[].values[][1]' | head
   # → 10.244.0.1 - - [.../nope] "GET /nope HTTP/1.1" 404 19
   ```

4. Now a query that filters the *body* — every non-2xx response line — and counts them per minute with a metric query over logs:

   ```bash
   curl -s -G 'http://localhost:3100/loki/api/v1/query_range' \
     --data-urlencode 'query=sum(count_over_time({namespace_name="observability", pod_name=~"sample-app.*"} |= " 404 " [1m]))' \
     | jq -r '.data.result[0].values[-1][1]'
   # → 40
   ```

### Comprehension check

- **4a.** Fluent Bit runs as a `DaemonSet` and Loki as a `Deployment`/`StatefulSet`. Explain why the collector *must* be a DaemonSet and what it would miss if it were a 2-replica Deployment instead.
- **4b.** The values file labels streams with `namespace`, `pod`, `container` but deliberately **not** `request_id` or `user_id`. Explain Loki's cardinality problem and what specifically degrades if you label by `request_id`.
- **4c.** In LogQL, `{namespace_name="observability"} |= "404"` — which part uses the index and which part scans? What is the performance consequence of writing `{job=~".+"} |= "404"` instead of a tight stream selector?
- **4d.** How does this logging pipeline let you *correlate* a log line with a metric spike from Exercise 2? Name the shared label(s) that make the join possible in Grafana.

---

## Exercise 5 — Distributed tracing with OpenTelemetry and Jaeger

A trace follows one request across service boundaries; each hop is a **span**, and spans link into a tree by trace/span IDs propagated in headers. The platform provides the **collector** (a vendor-neutral OTel pipeline) and the **backend** (Jaeger); app teams only emit spans. This exercise wires the OpenTelemetry Collector to Jaeger and confirms trace propagation.

### Steps

1. Install the OpenTelemetry Operator (it needs cert-manager for its webhooks) and Jaeger's all-in-one for the lab:

   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   kubectl -n cert-manager rollout status deploy/cert-manager-webhook
   kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
   kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager

   helm install jaeger jaegertracing/jaeger \
     --namespace observability \
     --set provisionDataStore.cassandra=false \
     --set allInOne.enabled=true \
     --set storage.type=memory \
     --set agent.enabled=false --set collector.enabled=false --set query.enabled=false
   ```

2. Declare the collector with an `OpenTelemetryCollector` CR. It receives OTLP (gRPC + HTTP), batches, and exports to Jaeger over OTLP:

   ```yaml
   # otel-collector.yaml
   apiVersion: opentelemetry.io/v1beta1
   kind: OpenTelemetryCollector
   metadata:
     name: platform
     namespace: observability
   spec:
     mode: deployment
     config:
       receivers:
         otlp:
           protocols:
             grpc: { endpoint: 0.0.0.0:4317 }
             http: { endpoint: 0.0.0.0:4318 }
       processors:
         batch: {}
         memory_limiter:
           check_interval: 1s
           limit_percentage: 80
           spike_limit_percentage: 25
       exporters:
         otlp/jaeger:
           endpoint: jaeger-collector.observability.svc:4317
           tls: { insecure: true }
       service:
         pipelines:
           traces:
             receivers: [otlp]
             processors: [memory_limiter, batch]
             exporters: [otlp/jaeger]
   ```

   ```bash
   kubectl apply -f otel-collector.yaml
   kubectl -n observability rollout status deploy/platform-collector
   ```

3. Emit a trace without writing app code — use the `telemetrygen` tool, which speaks OTLP directly at the collector service (the Operator names the service `platform-collector`):

   ```bash
   kubectl -n observability run telemetrygen --rm -it --restart=Never \
     --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest -- \
     traces --otlp-insecure \
     --otlp-endpoint platform-collector.observability.svc:4317 \
     --service my-checkout --traces 5 --child-spans 3
   # → traces generated: 5
   ```

4. Query Jaeger's API for the service and its trace count:

   ```bash
   kubectl -n observability port-forward svc/jaeger-query 16686:16686 &
   sleep 3
   curl -s 'http://localhost:16686/api/services' | jq '.data'
   # → [ "my-checkout", "jaeger-all-in-one" ]

   curl -s 'http://localhost:16686/api/traces?service=my-checkout&limit=5' \
     | jq '.data | length, .data[0].spans | length'
   # → 5      (traces)
   # → 4      (spans per trace: 1 root + 3 children)
   ```

### Comprehension check

- **5a.** Trace context propagates via HTTP headers (`traceparent`/`tracestate`, the W3C Trace Context standard). If service B calls service C but B does **not** forward those headers, what does the trace in Jaeger look like, and why?
- **5b.** The pipeline is `receivers → processors → exporters`. Explain the job of the `batch` processor and the `memory_limiter` processor, and why the order `[memory_limiter, batch]` matters.
- **5c.** OTLP is the wire format both to *and* from the collector. What does putting a vendor-neutral collector between the app and Jaeger buy the platform team that shipping spans straight to Jaeger would not?
- **5d.** Sampling: you configured none, so 100% of traces are stored. Name the two families of sampling (where the decision is made relative to the trace completing) and state which one can keep "all traces that contain an error" and why the other cannot.

---

## Exercise 6 — Tie the four signals into an SLO and clean up

The payoff of doing all four is *correlation*: an alert links to a trace links to logs. Here you define a simple availability SLO, an error-budget burn-rate alert, and then tear everything down.

### Steps

1. Define an SLO as a multi-window, multi-burn-rate alert — the Google SRE pattern that pages fast on a severe burn and slowly on a mild one, without flapping. Add to a `PrometheusRule`:

   ```yaml
   # sample-app-slo.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: sample-app-slo
     namespace: observability
     labels: { role: alert-rules }
   spec:
     groups:
       - name: sample-app.slo
         rules:
           # Fast burn: 14.4x budget consumption over 1h AND 5m — pages hard.
           - alert: SampleAppErrorBudgetFastBurn
             expr: |
               job:http_requests_errors:ratio5m > (14.4 * 0.001)
               and
               (sum(rate(http_requests_total{service="sample-app",code=~"5.."}[1h]))
                 / sum(rate(http_requests_total{service="sample-app"}[1h]))) > (14.4 * 0.001)
             for: 2m
             labels: { severity: critical, slo: "availability-99.9" }
             annotations:
               summary: "Fast error-budget burn on sample-app"
   ```

   ```bash
   kubectl apply -f sample-app-slo.yaml
   ```

2. Confirm the SLO rule is loaded:

   ```bash
   curl -s 'http://localhost:9090/api/v1/rules?type=alert' \
     | jq -r '.data.groups[].rules[] | select(.labels.slo) | "\(.name) \(.labels.slo) \(.state)"'
   # → SampleAppErrorBudgetFastBurn availability-99.9 inactive
   ```

3. Tear down everything you created — reverse order, then the namespace:

   ```bash
   kubectl delete -f sample-app-slo.yaml -f sample-app-alerts.yaml \
     -f sample-app-recording-rules.yaml -f payments-routing.yaml \
     -f sample-app-servicemonitor.yaml -f otel-collector.yaml -f sample-app.yaml --ignore-not-found
   helm uninstall fluent-bit loki jaeger kps -n observability
   kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml --ignore-not-found
   kubectl delete namespace observability
   # kill any lingering port-forwards
   jobs -p | xargs -r kill
   ```

### Comprehension check

- **6a.** The fast-burn rule ANDs a 1h window with a 5m window. What failure mode does requiring **both** windows to exceed the threshold prevent, compared to alerting on the 5m window alone?
- **6b.** For a 99.9% availability SLO over 30 days, roughly how much total downtime is the error budget, and what does "14.4x burn rate" mean in terms of how fast you'd exhaust a 30-day budget?
- **6c.** You have metrics, alerts, logs, and traces all carrying `namespace`, `pod`, and (for traces) a `trace_id`. Walk through, signal by signal, how an on-call engineer goes from "the pager fired" to "here is the exact request that failed and why."
- **6d.** Why is the teardown ordered app-objects-first, then Helm releases, then the namespace? What can go wrong if you `kubectl delete namespace` while the Operators still have finalizers on their CRs?

---

## Answers

<details>
<summary>Show answers for all exercises</summary>

### Exercise 1

- **1a.** (i) The `ServiceMonitor.spec.selector.matchLabels` doesn't match the **Service**'s labels (people match Pod labels by mistake — it selects Services, not Pods). (ii) `endpoints[].port` doesn't match a *named* port on the Service, or the Service port is unnamed. (iii) The Prometheus CR's `serviceMonitorSelector`/`serviceMonitorNamespaceSelector` doesn't select this `ServiceMonitor` — the default kube-prometheus-stack behaviour requires a release label unless you set `serviceMonitorSelectorNilUsesHelmValues=false` (step 1). Also check RBAC: Prometheus needs `get/list/watch` on endpoints/services/pods in the target namespace.
- **1b.** The Operator resolves the named port to the concrete `Endpoints`/`EndpointSlice` addresses and generates the scrape config from them; the name is stable across pod churn where numbers on a per-pod basis are not the referent. If the Service port is unnamed, there is nothing for `endpoints.port` (a string) to match and no target is generated — you'd have to switch to `targetPort`/relabeling. Naming the port is the intended path.
- **1c.** A `ServiceMonitor` scrapes **Endpoints behind a Service** — it needs a Service to exist. A `PodMonitor` scrapes **Pods directly** by pod label selector, with no Service required. Use `PodMonitor` when the workload has no Service (e.g. a `Job`, a headless component, or metrics on a pod port you don't want to expose through a Service).
- **1d.** `up` is a synthetic metric Prometheus injects for **every scrape target**: `1` if the scrape succeeded, `0` if it failed (connection refused, timeout, HTTP error). `up == 0` means the target exists and is configured but the scrape failed — the endpoint is down or unreachable. `up` being **absent** means the target isn't configured at all (the ServiceMonitor didn't match) — a config problem, not an outage. They demand different fixes.

### Exercise 2

- **2a.** A counter only ever increases (until reset); its absolute value is meaningless — it depends on how long the process has been running. `rate()` computes the per-second average increase over the window, which is the actual signal. `sum()` on the raw counter adds up total-since-start across pods, a number that only grows and tells you nothing about current load; worse, it jumps down when any pod restarts.
- **2b.** `rate()` (and `increase()`) detect counter resets: whenever a sample is lower than the previous one, they assume a reset to 0 and add the pre-reset value back in, treating the drop as "counter went to 0 then climbed." It assumes counters are monotonic and that any decrease is a reset, not a real decrement — which is why you must never use `rate()` on a gauge.
- **2c.** (i) **Query performance / cost**: a heavy expression (many series, long window, `histogram_quantile`) is computed once per `interval` and stored as a small series, so dashboards and alerts read a cheap pre-aggregated metric instead of recomputing on every refresh. (ii) **Consistency**: the SLI is defined in exactly one place, so the dashboard, the alert, and the SLO all use the identical definition — no drift between a graph that says "healthy" and an alert that fires.
- **2d.** If there is **no traffic at all** in the window, the denominator `sum(rate(...))` is an empty vector, and `<empty> / <empty>` yields an empty result — not `0`. "No data" means you can't compute the ratio (no requests happened), which is operationally different from "requests happened and none errored" (ratio genuinely `0`). Alerting on `ratio > 0.05` silently ignores the no-data case; you often need a separate "no requests / target down" alert so an outage that stops all traffic doesn't hide behind an empty error ratio.

### Exercise 3

- **3a.** `pending` means the alert expression is currently true but has **not** been true for the full `for` duration yet; `firing` means it has been continuously true for at least `for`. The `for` field is the sustain window that filters transient spikes. `for: 0` (or omitting it) fires on a single true evaluation, so any one-scrape blip pages someone — noisy signals need a `for` long enough to outlast normal jitter.
- **3b.** (i) initial burst → **`groupWait`** (wait a bit after the first alert in a new group so related alerts arrive together in one notification); (ii) new alerts joining an existing group → **`groupInterval`** (how long to wait before sending an updated notification when the group's membership changes); (iii) re-notification of an unresolved alert → **`repeatInterval`** (how often to re-send a still-firing alert as a reminder).
- **3c.** A **silence** is a manual, time-boxed, matcher-based mute an operator sets (e.g. "mute everything for INC-1234 for 1h") — the alert still evaluates and shows as active, just isn't delivered. An **inhibition** is a declarative rule: when a *source* alert is firing, matching *target* alerts are automatically suppressed. For "stop `HighLatency` when `ClusterDown` is active" you use an **inhibition rule** (source = `ClusterDown`, target = `HighLatency`, matched on a common label like `cluster`) — it's automatic and needs no human to notice the parent alert.
- **3d.** You route and group on **labels** only — labels are the identity/dimensions of the alert and are indexed for matching. **Annotations** are free-form human text (summary, description, runbook URL) and are *not* used for routing. The runbook URL must be an annotation because it's a value for humans, not a routing dimension; putting a high-cardinality URL in labels would also fragment grouping (every distinct label set is a distinct group).

### Exercise 4

- **4a.** Container logs live on the node's filesystem (`/var/log/containers/*.log`), and each node has different files. A DaemonSet guarantees exactly one collector pod **per node**, each tailing that node's local logs. A 2-replica Deployment would land on (at most) 2 nodes and silently miss the logs of every other node — you'd lose logs for whole nodes and never know from the pipeline itself.
- **4b.** Loki indexes **label sets**, and each unique combination of label values is a separate **stream**. Cardinality = number of distinct streams. `namespace/pod/container` is bounded (dozens to thousands). `request_id` is unbounded — effectively one stream per request — which explodes the index, destroys compression (streams no longer share a body), and drives memory/cost up while making queries slower. High-cardinality values belong in the **log line**, filtered with `|=`, never in labels.
- **4c.** The stream selector `{namespace_name="observability"}` uses the **index** to pick matching streams cheaply. The line filter `|= "404"` **scans** the bodies of those selected streams. `{job=~".+"} |= "404"` selects essentially *every* stream first, so Loki must decompress and scan the entire cluster's logs — orders of magnitude more work. Tighten the stream selector so the index does the pruning before the body scan.
- **4d.** Both the metrics from Exercise 2 and the log streams here carry the same Kubernetes identity labels — `namespace`, `pod` (and `container`). In Grafana you pivot from a Prometheus panel showing an error spike on a given `pod` to a Loki query `{namespace_name="observability", pod_name="<that-pod>"}` for the same time range and pod, landing on the exact log lines behind the spike. Shared labels are the join key across signals.

### Exercise 5

- **5a.** Without B forwarding `traceparent`/`tracestate`, C has no parent context, so C **starts a brand-new trace** with a new trace ID. In Jaeger you see two disconnected traces (A→B, and a separate C) instead of one A→B→C tree — the chain is broken at B. Propagation is the app's responsibility; the collector can't reconstruct a link that was never sent.
- **5b.** `batch` groups spans into fewer, larger export requests, reducing network overhead and load on the backend — essential for throughput. `memory_limiter` watches the collector's own memory and starts refusing/dropping data before it OOMs, protecting the collector as a shared platform component. Order `[memory_limiter, batch]` matters: the limiter must run **first** so it can shed load before spans are buffered into batches; putting `batch` first would let memory balloon in the batcher before the limiter reacts.
- **5c.** A vendor-neutral OTel collector decouples the app from the backend: you can add processors (batching, tail sampling, PII redaction, attribute enrichment), fan out to multiple backends, apply consistent sampling policy centrally, and **swap Jaeger for another backend without touching a single application** — the apps only ever know OTLP. Shipping straight to Jaeger hard-codes the backend into every service and gives you no central place to sample or scrub.
- **5d.** **Head-based** sampling decides at the *start* of the trace (at the first service, before the outcome is known); it's cheap and stateless but **cannot** guarantee keeping error traces, because when the root span begins you don't yet know the request will error. **Tail-based** sampling decides after the *whole* trace is collected at the collector, so it can inspect the full trace and keep, e.g., every trace containing an error or exceeding a latency threshold — at the cost of buffering complete traces in memory.

### Exercise 6

- **6a.** Alerting on the 5m window alone makes the alert **flap**: it fires on a short spike and immediately resolves, paging repeatedly. Requiring the 1h window to *also* be over threshold confirms the burn is sustained (a real budget problem), while the 5m window keeps the alert **fast to fire and fast to clear** once the incident is actually over. The pairing gives both responsiveness and low false-positive/flap rate.
- **6b.** 99.9% over 30 days allows 0.1% downtime ≈ **43.2 minutes** per 30 days. A "1x" burn rate consumes the budget exactly over the full 30 days. **14.4x** means you're burning budget 14.4 times faster than sustainable — at that rate you'd exhaust the entire 30-day budget in about **30 days / 14.4 ≈ 2 days** (which is why 14.4x/1h is the canonical "page now" fast-burn threshold: ~2% of budget gone in 1h).
- **6c.** (1) **Alert** fires with labels (`namespace`, `pod`, `severity`, `slo`) and a runbook annotation — you know *which* workload and *how bad*. (2) **Metrics**: open the RED dashboard filtered to that `namespace`/`pod`, see the error-rate/latency spike and its start time. (3) **Logs**: query Loki `{namespace_name=..., pod_name=...}` for that window, find the erroring request lines and their `trace_id` (if logged). (4) **Traces**: paste that `trace_id` into Jaeger to see the exact request's span tree, the failing hop, and its error tags/duration — "here is the request and why it failed." Shared `namespace`/`pod` labels chain the first three; `trace_id` bridges logs to the trace.
- **6d.** Reverse-of-creation order avoids dangling references and stuck finalizers. App objects (CRs like `ServiceMonitor`, `OpenTelemetryCollector`) are removed while their Operators are **still running** to process any finalizers; then the Helm releases (which own the Operators/backends) are uninstalled; then the namespace. If you `kubectl delete namespace` first while Operators still hold finalizers on their CRs, those CRs can't finalize (their controller is being torn down simultaneously), and the namespace hangs in `Terminating` — you'd have to manually strip finalizers to unstick it.

</details>

---

**Sources**

- CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Prometheus — querying & rules: https://prometheus.io/docs/prometheus/latest/querying/basics/ · https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/ · https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Operator (ServiceMonitor / PodMonitor / PrometheusRule / AlertmanagerConfig): https://prometheus-operator.dev/docs/getting-started/design/
- Alertmanager configuration & routing: https://prometheus.io/docs/alerting/latest/configuration/ · `amtool`: https://github.com/prometheus/alertmanager#amtool
- Grafana Loki (LogQL, labels & cardinality): https://grafana.com/docs/loki/latest/query/ · https://grafana.com/docs/loki/latest/get-started/labels/
- Fluent Bit Kubernetes & Loki output: https://docs.fluentbit.io/manual/pipeline/outputs/loki
- OpenTelemetry Collector (pipelines, processors, sampling): https://opentelemetry.io/docs/collector/configuration/ · https://opentelemetry.io/docs/concepts/sampling/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- Jaeger architecture & APIs: https://www.jaegertracing.io/docs/latest/architecture/
- Google SRE Workbook — Alerting on SLOs (multi-window multi-burn-rate): https://sre.google/workbook/alerting-on-slos/