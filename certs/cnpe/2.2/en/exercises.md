# Guided Exercises — CNPE 2.2: Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

> **Format.** Each exercise is a block of numbered steps you execute against a running Kubernetes cluster, followed by comprehension questions. All answers are collected in the collapsible `<details>` section at the end.
>
> **Prerequisites.** A cluster (kind/minikube/k3d or a real one) with `kubectl` context set, `helm` v3, and cluster-admin. You will install `metrics-server`, `kube-state-metrics`, `Prometheus`, and the `VPA recommender`. Namespaces `platform` (tooling) and `prod` (workloads) are used throughout.
>
> **Framing.** Platform efficiency has three orthogonal axes, and this topic measures all three:
> 1. **Flow / delivery efficiency** — how fast and safely change reaches production (DORA metrics).
> 2. **Resource / cost efficiency** — how much of what you pay for is actually doing work (utilization, bin-packing, slack).
> 3. **Reliability efficiency** — how much of your reliability budget you spend to deliver that flow (SLIs / SLOs / error budgets).
> A metric on one axis is meaningless without the other two: shipping fast while burning the error budget, or running lean while dropping requests, is not "efficient." The exercises deliberately measure across all three so you learn to read them as a system.

---

## Exercise 1 — Establish the measurement substrate (metrics-server, kube-state-metrics, Prometheus)

You cannot improve what you cannot see. Before any KPI, you need a metrics pipeline: cAdvisor (in the kubelet) for real resource usage, `metrics-server` for the Metrics API, `kube-state-metrics` (KSM) for *desired-state* object metrics (deployments, replicasets, requests/limits), and Prometheus to store and query the time series.

### Steps

1. Create the two namespaces:

   ```bash
   kubectl create namespace platform
   kubectl create namespace prod
   ```

2. Install `metrics-server` (provides `kubectl top`, the Metrics API `metrics.k8s.io`). On kind/minikube add the insecure-kubelet flag because the kubelet serving cert is self-signed:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   kubectl -n kube-system patch deployment metrics-server --type=json \
     -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
   ```

3. Wait for it and confirm the Metrics API answers:

   ```bash
   kubectl -n kube-system rollout status deploy/metrics-server
   kubectl top nodes
   ```

   Expected (values differ):

   ```
   NAME           CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
   kind-control   248m         6%     1120Mi          14%
   ```

4. Install the Prometheus stack (bundles Prometheus, Alertmanager, Grafana, and **kube-state-metrics**) into `platform`:

   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   helm install kps prometheus-community/kube-prometheus-stack -n platform
   kubectl -n platform rollout status deploy/kps-kube-state-metrics
   ```

5. Deploy a realistic sample workload into `prod` with **explicit requests and limits** (this is what makes efficiency measurable — a Pod with no requests is invisible to allocation math):

   ```yaml
   # web.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: prod
     labels: { app: web }
   spec:
     replicas: 4
     selector:
       matchLabels: { app: web }
     template:
       metadata:
         labels: { app: web }
       spec:
         containers:
           - name: web
             image: registry.k8s.io/e2e-test-images/agnhost:2.47
             args: ["netexec", "--http-port=8080"]
             ports:
               - containerPort: 8080
             resources:
               requests:
                 cpu: "250m"
                 memory: "256Mi"
               limits:
                 cpu: "500m"
                 memory: "256Mi"
   ```

   ```bash
   kubectl apply -f web.yaml
   kubectl -n prod rollout status deploy/web
   ```

6. Port-forward Prometheus and confirm KSM is scraped. In one terminal:

   ```bash
   kubectl -n platform port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
   ```

   Then query the deployment's desired replica count (KSM metric) via the HTTP API:

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=kube_deployment_spec_replicas{deployment="web"}' \
     | jq '.data.result[0].value[1]'
   ```

   Expected:

   ```
   "4"
   ```

### Comprehension questions

- **1a.** Two components report "CPU for the `web` deployment": `metrics-server` and `kube-state-metrics`. What does each one actually measure, and why do you need *both* to compute an efficiency ratio?
- **1b.** A teammate says "just scrape cAdvisor, drop kube-state-metrics." What class of platform KPI becomes impossible to compute, and why?
- **1c.** The `web` Pods declare `requests` *and* `limits`. Which of the two does the Kubernetes scheduler use to place Pods on nodes, and which one does the kubelet/cgroup use to throttle or OOM-kill at runtime?

---

## Exercise 2 — Compute the four DORA delivery metrics

DORA (DevOps Research and Assessment) defines four keys that predict software delivery performance: **Deployment Frequency**, **Lead Time for Changes**, **Change Failure Rate**, and **Failed Deployment Recovery Time** (formerly "Time to Restore Service" / MTTR). Source: <https://dora.dev/guides/dora-metrics-four-keys/>.

We approximate the two "cluster-observable" keys (frequency, change-failure) directly from Kubernetes state, and compute the two "process" keys (lead time, recovery) from event timestamps — because DORA is fundamentally about the *value stream*, not the cluster alone.

### Steps

1. **Deployment Frequency.** Each rolled-out spec change bumps the Deployment's observed generation. Over a window, `changes()` on that gauge counts rollouts. Roll the `web` deployment three times to create signal:

   ```bash
   for i in 1 2 3; do
     kubectl -n prod set env deploy/web ROLLOUT=$i
     kubectl -n prod rollout status deploy/web
   done
   ```

   Query deployment frequency over the last day in Prometheus:

   ```promql
   changes(kube_deployment_status_observed_generation{namespace="prod", deployment="web"}[1d])
   ```

   Interpret the scalar as *deployments/day* for that service. To get a **fleet-wide daily deploy rate**:

   ```promql
   sum(changes(kube_deployment_status_observed_generation{namespace="prod"}[1d]))
   ```

2. **Change Failure Rate (CFR).** A failed change is a rollout that never reached `Available` (e.g. `ProgressDeadlineExceeded`) or that was rolled back. Simulate one bad deploy with an image that never becomes ready:

   ```bash
   kubectl -n prod set image deploy/web web=registry.k8s.io/does-not-exist:0.0
   sleep 20
   kubectl -n prod rollout status deploy/web --timeout=30s || echo "ROLLOUT FAILED (expected)"
   ```

   Observe the failing condition exported by KSM:

   ```promql
   kube_deployment_status_condition{namespace="prod", deployment="web", condition="Progressing", status="false"}
   ```

   Then roll back to a good state so the cluster recovers:

   ```bash
   kubectl -n prod rollout undo deploy/web
   kubectl -n prod rollout status deploy/web
   ```

   Conceptually: `CFR = failed_deployments / total_deployments` over the same window. With deploys = 4 (3 good + 1 bad) and 1 failure, `CFR = 25%`.

3. **Lead Time for Changes** cannot be read from the cluster — it needs the commit→prod timestamps. Stamp the deployment with the source commit's authored time at deploy time (a golden-path CI step would do this automatically):

   ```bash
   # In CI, right before kubectl apply:
   COMMIT_TS=$(git show -s --format=%ct HEAD)          # commit authored time (unix)
   kubectl -n prod annotate deploy/web \
     platform.io/commit-timestamp="$COMMIT_TS" --overwrite
   ```

   Compute lead time when the rollout completes:

   ```bash
   DEPLOY_TS=$(date +%s)
   COMMIT_TS=$(kubectl -n prod get deploy/web \
     -o jsonpath='{.metadata.annotations.platform\.io/commit-timestamp}')
   echo "Lead time for changes: $(( (DEPLOY_TS - COMMIT_TS) / 60 )) minutes"
   ```

4. **Failed Deployment Recovery Time.** This is the wall-clock from "service impaired" to "service restored." Read it from the duration the `Available` condition was `false`. If you record incident open/close events (e.g. from Alertmanager firing/resolving), recovery time is `resolved_at − fired_at`. As a cluster proxy, the time between the bad-image event in step 2 and the successful `rollout undo` is your recovery time — capture it:

   ```bash
   kubectl -n prod get events --sort-by=.lastTimestamp \
     --field-selector involvedObject.name=web | tail -n 10
   ```

5. Classify your service against DORA's performance clusters (Elite / High / Medium / Low). For reference, **Elite** teams deploy on-demand (multiple/day), lead time < 1 day, CFR 5–10%, and recover in < 1 hour. Source: <https://dora.dev/research/>.

### Comprehension questions

- **2a.** Why is `changes(kube_deployment_status_observed_generation[...])` a *proxy* for deployment frequency rather than a true count? Name one deployment scenario it **under**-counts and one it might **over**-count.
- **2b.** DORA pairs the four metrics into two tensions: throughput (frequency + lead time) vs. stability (CFR + recovery). Why is reporting only the throughput pair actively dangerous for a platform team, and what perverse incentive does it create?
- **2c.** Lead Time for Changes required an out-of-cluster timestamp (the commit time), but Change Failure Rate did not. What does this tell you structurally about *where* each DORA metric's data must be instrumented — and why a platform's golden-path CI/CD is the only place to capture lead time correctly?
- **2d.** Your CFR is 2%. Is that unambiguously good? Give one interpretation where a *very low* CFR is actually a warning sign about the team's delivery behavior.

---

## Exercise 3 — Measure resource efficiency: utilization, allocation, and slack

Cost efficiency has two distinct ratios that are frequently confused:
- **Utilization** = *actual usage ÷ requests* (are the Pods using what they reserved?).
- **Allocation / bin-packing efficiency** = *sum of requests ÷ allocatable capacity* (are the nodes packed?).
The gap between them is **slack** — capacity you pay for that does no work. FinOps calls this the core of rate-and-usage optimization: <https://www.finops.org/framework/capabilities/>.

### Steps

1. **CPU utilization vs. requests** for `prod` (usage from cAdvisor, requests from KSM):

   ```promql
   sum(rate(container_cpu_usage_seconds_total{namespace="prod", container!=""}[5m]))
     /
   sum(kube_pod_container_resource_requests{namespace="prod", resource="cpu"})
   ```

   A result of `0.08` means the workloads use **8%** of the CPU they reserved — massively over-provisioned.

2. **Memory utilization vs. requests** (use working-set, not RSS — it's what the OOM-killer watches):

   ```promql
   sum(container_memory_working_set_bytes{namespace="prod", container!=""})
     /
   sum(kube_pod_container_resource_requests{namespace="prod", resource="memory"})
   ```

3. **Allocation efficiency (bin-packing)** — how much of the *cluster's* schedulable CPU is reserved by requests:

   ```promql
   sum(kube_pod_container_resource_requests{resource="cpu"})
     /
   sum(kube_node_status_allocatable{resource="cpu"})
   ```

4. **Compute the slack explicitly** with `kubectl` for a quick spot-check:

   ```bash
   kubectl top pods -n prod --containers
   ```

   Expected:

   ```
   POD                    NAME   CPU(cores)   MEMORY(bytes)
   web-6f9c8b7d4-abcde    web    3m           12Mi
   web-6f9c8b7d4-fghij    web    2m           11Mi
   ...
   ```

   Note the contrast: each Pod *requests* `250m` CPU / `256Mi` but *uses* ~`3m` / `~12Mi`. That is roughly **1% CPU** and **~5% memory** utilization — a textbook over-provisioning signal.

5. **Detect the two failure modes.** Over-provisioning wastes money; *under*-provisioning causes throttling and OOM-kills. Check for CPU throttling (limits too tight relative to demand):

   ```promql
   sum(rate(container_cpu_cfs_throttled_periods_total{namespace="prod"}[5m]))
     /
   sum(rate(container_cpu_cfs_periods_total{namespace="prod"}[5m]))
   ```

   And for OOM-kills:

   ```promql
   increase(kube_pod_container_status_restarts_total{namespace="prod"}[1h])
   # cross-reference reason:
   kube_pod_container_status_last_terminated_reason{namespace="prod", reason="OOMKilled"}
   ```

6. **Turn efficiency into a single reportable KPI.** A common platform SLI is *effective utilization* = usage ÷ allocatable (usage all the way through to what you pay for), which folds both ratios together:

   ```promql
   sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]))
     /
   sum(kube_node_status_allocatable{resource="cpu"})
   ```

### Comprehension questions

- **3a.** Utilization (usage÷requests) is 8% but allocation (requests÷allocatable) is 85%. Adding nodes won't help and you can't schedule new workloads. Diagnose the root cause in one sentence, and state the *single* lever that fixes it.
- **3b.** Why must you measure memory with `container_memory_working_set_bytes` rather than `container_memory_rss` or `..._usage_bytes` when your goal is to right-size the memory *request/limit*?
- **3c.** A dashboard shows 8% CPU utilization and someone proposes halving every request. What two runtime signals from step 5 must you check *first*, and what does ignoring them risk?
- **3d.** Explain why "increase node utilization" and "increase request utilization" can be in direct conflict, and which one a platform team optimizing *cost* should target first.

---

## Exercise 4 — Define SLIs, SLOs, and an error budget for a platform service

Delivery speed is only "efficient" if reliability holds. SLIs quantify user-visible behavior; an SLO is the target; the **error budget** (`1 − SLO`) is the amount of unreliability you're *allowed* to spend — and it's the objective link between the two DORA tensions. Source: Google SRE Workbook, <https://sre.google/workbook/implementing-slos/>.

### Steps

1. Assume the platform's ingress/gateway exposes `http_requests_total{code=...}` and `http_request_duration_seconds_bucket`. Define the **availability SLI** (fraction of non-5xx requests):

   ```promql
   sum(rate(http_requests_total{job="web", code!~"5.."}[5m]))
     /
   sum(rate(http_requests_total{job="web"}[5m]))
   ```

2. Define the **latency SLI** (fraction of requests served under 300 ms, using the histogram bucket):

   ```promql
   sum(rate(http_request_duration_seconds_bucket{job="web", le="0.3"}[5m]))
     /
   sum(rate(http_request_duration_seconds_count{job="web"}[5m]))
   ```

3. Set the **SLO**: 99.9% availability over 28 days. That yields an error budget of `0.1%` — about **40 minutes** of full-outage-equivalent per 28 days. Record the SLO as a recording rule so it's a first-class time series:

   ```yaml
   # slo-rules.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: web-slo
     namespace: platform
     labels: { release: kps }
   spec:
     groups:
       - name: web-slo.rules
         rules:
           - record: slo:web_availability:ratio_rate5m
             expr: |
               sum(rate(http_requests_total{job="web", code!~"5.."}[5m]))
                 /
               sum(rate(http_requests_total{job="web"}[5m]))
   ```

   ```bash
   kubectl apply -f slo-rules.yaml
   ```

4. Add **multi-window, multi-burn-rate** alerting — the SRE-recommended pattern that pages fast on catastrophic burn but stays quiet on slow, tolerable burn. A 14.4× burn rate exhausts a 30-day budget in ~2 days; requiring both a 1h *and* 5m window suppresses flapping:

   ```yaml
   # burn-rate.yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: web-burn-rate
     namespace: platform
     labels: { release: kps }
   spec:
     groups:
       - name: web-burnrate.rules
         rules:
           - alert: WebErrorBudgetFastBurn
             # error rate = 1 - availability; 14.4x burn of a 0.1% budget = 1.44% errors
             expr: |
               (1 - (sum(rate(http_requests_total{job="web", code!~"5.."}[1h]))
                     / sum(rate(http_requests_total{job="web"}[1h])))) > (14.4 * 0.001)
               and
               (1 - (sum(rate(http_requests_total{job="web", code!~"5.."}[5m]))
                     / sum(rate(http_requests_total{job="web"}[5m])))) > (14.4 * 0.001)
             for: 2m
             labels: { severity: page }
             annotations:
               summary: "web is burning its 28-day error budget 14.4x too fast"
   ```

   ```bash
   kubectl apply -f burn-rate.yaml
   ```

5. **Connect the budget to delivery.** The policy that makes this efficient: *when the error budget is healthy, ship freely (favor throughput); when it's exhausted, freeze feature deploys and spend the window on reliability.* Compute remaining budget over 28 days:

   ```promql
   1 -
   (
     (1 - avg_over_time(slo:web_availability:ratio_rate5m[28d]))
     / 0.001
   )
   ```

   A result of `0.6` means 60% of the budget remains.

### Comprehension questions

- **4a.** 99.9% and 99.99% differ by one nine but the error budget shrinks 10×, from ~40 min to ~4 min per 28 days. Explain concretely why "just set the SLO to 100%" is not only impossible but *anti-efficient* for a platform.
- **4b.** Why does the fast-burn alert AND-combine a 1-hour and a 5-minute window instead of just alerting on the 5-minute rate? What noise and what blind spot does each window guard against?
- **4c.** The error budget is the mechanism that resolves the DORA throughput-vs-stability tension from Exercise 2. Describe the concrete decision rule it gives a platform team on a Monday morning, in both the "budget healthy" and "budget exhausted" states.
- **4d.** Your availability SLI is 99.95% but users are complaining. Name two ways an availability-only SLI can be *green while users suffer*, and which additional SLI from this exercise closes one of those gaps.

---

## Exercise 5 — Platform adoption & developer-flow KPIs (the platform-as-a-product view)

CNPE treats the platform as a product with internal customers. Efficiency here is measured by *adoption of golden paths*, *self-service ratio*, and *cognitive-load / flow* signals — the SPACE dimensions (Satisfaction, Performance, Activity, Communication, Efficiency-flow). Sources: CNCF Platform Engineering Maturity Model <https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/> and the SPACE framework <https://queue.acm.org/detail.cfm?id=3454124>.

### Steps

1. **Golden-path adoption.** Suppose golden-path services carry the label `platform.io/golden-path="true"`. Measure the fraction of deployments on the paved road:

   ```promql
   count(kube_deployment_labels{label_platform_io_golden_path="true"})
     /
   count(kube_deployment_created)
   ```

2. **Self-service ratio.** Count how many namespaces/apps were provisioned via the platform's self-service API (label `platform.io/provisioned-by="idp"`) vs. total. A high ratio means fewer manual tickets = lower platform-team toil:

   ```promql
   count(kube_namespace_labels{label_platform_io_provisioned_by="idp"})
     /
   count(kube_namespace_created)
   ```

3. **Onboarding lead time** ("time to first deploy") — the flow KPI that most directly measures whether the golden path *works*. In a golden-path scaffolding step, stamp the namespace at creation and the first successful rollout, then diff:

   ```bash
   # at namespace creation (IDP does this):
   kubectl annotate ns team-alpha platform.io/created-at="$(date +%s)" --overwrite
   # after their first successful prod rollout:
   CREATED=$(kubectl get ns team-alpha -o jsonpath='{.metadata.annotations.platform\.io/created-at}')
   echo "Time to first deploy: $(( ($(date +%s) - CREATED) / 3600 )) hours"
   ```

4. **Toil / paging load on the platform team** — a Satisfaction/Efficiency proxy. Alert volume per on-call week is a leading indicator of an inefficient platform:

   ```promql
   sum(increase(alertmanager_notifications_total{integration="pagerduty"}[7d]))
   ```

5. **Assemble a single "platform scorecard"** by pairing one metric per axis so no axis can be gamed in isolation:

   | Axis | KPI | Query source | Healthy direction |
   |---|---|---|---|
   | Flow | Deployment frequency | Ex. 2 step 1 | ↑ |
   | Flow | Lead time for changes | Ex. 2 step 3 | ↓ |
   | Stability | Change failure rate | Ex. 2 step 2 | ↓ |
   | Stability | Failed-deploy recovery time | Ex. 2 step 4 | ↓ |
   | Cost | Effective CPU utilization | Ex. 3 step 6 | ↑ (to a safe ceiling) |
   | Reliability | Error budget remaining | Ex. 4 step 5 | ≥ 0 |
   | Adoption | Golden-path adoption | Ex. 5 step 1 | ↑ |
   | Toil | Onboarding lead time | Ex. 5 step 3 | ↓ |

### Comprehension questions

- **5a.** Deployment frequency is up 40% but golden-path adoption is *flat* and platform-team paging is up 25%. What is the most likely story these three numbers tell together, and why would looking at deployment frequency alone mislead you?
- **5b.** Why is "time to first deploy" (onboarding lead time) considered a truer measure of a platform's efficiency than the platform team's own throughput?
- **5c.** SPACE deliberately warns against optimizing a single dimension, especially "Activity" (e.g. commits, deploy counts). Give a concrete example of how optimizing *only* deployment frequency degrades a different SPACE dimension.
- **5d.** Why must a platform scorecard pair a "counter-metric" against every "goal-metric" (e.g. utilization ↑ *paired with* OOM-kills, or deploy frequency ↑ *paired with* CFR)? Name the specific failure this pairing prevents.

---

## Exercise 6 — Close the loop: use the metrics to drive a right-sizing improvement, then re-measure

Measurement is only efficient if it changes behavior. You will act on the Exercise 3 finding (1% CPU / 5% memory utilization) using the **Vertical Pod Autoscaler in recommendation-only mode**, then re-measure the same KPIs to prove the improvement.

### Steps

1. Install the VPA (recommender + admission + updater). From the autoscaler repo:

   ```bash
   git clone --depth=1 https://github.com/kubernetes/autoscaler.git
   ./autoscaler/vertical-pod-autoscaler/hack/vpa-up.sh
   ```

   Source: <https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler>.

2. Create a VPA in `Off` mode — it **only recommends**, never mutates Pods (safe for production, and the correct first step: measure the recommendation before you let anything act on it):

   ```yaml
   # web-vpa.yaml
   apiVersion: autoscaling.k8s.io/v1
   kind: VerticalPodAutoscaler
   metadata:
     name: web
     namespace: prod
   spec:
     targetRef:
       apiVersion: apps/v1
       kind: Deployment
       name: web
     updatePolicy:
       updateMode: "Off"     # recommend only; do not evict/resize
   ```

   ```bash
   kubectl apply -f web-vpa.yaml
   ```

3. After ~5–10 minutes of usage history, read the recommendation:

   ```bash
   kubectl -n prod describe vpa web
   ```

   Expected (illustrative):

   ```
   Recommendation:
     Container Recommendations:
       Container Name:  web
       Lower Bound:
         Cpu:     11m
         Memory:  20Mi
       Target:
         Cpu:     15m
         Memory:  28Mi
       Uncapped Target:
         Cpu:     15m
         Memory:  28Mi
       Upper Bound:
         Cpu:     40m
         Memory:  70Mi
   ```

   The `Target` (15m / 28Mi) vs. your current request (250m / 256Mi) quantifies the over-provisioning: **~16× CPU** and **~9× memory** headroom being paid for.

4. Apply a right-sized request/limit derived from the `Target` (leave a safety margin above `Upper Bound` for spikes; here ~50m/64Mi):

   ```bash
   kubectl -n prod set resources deploy/web \
     --requests=cpu=50m,memory=64Mi --limits=cpu=100m,memory=64Mi
   kubectl -n prod rollout status deploy/web
   ```

5. **Re-measure the same KPIs.** Utilization should climb toward a healthy band (target ~40–60% for request headroom), and — because requests shrank — more Pods now fit per node, improving allocation. Re-run the Exercise 3 queries:

   ```promql
   # utilization should now be much higher (e.g. ~0.3 instead of 0.08)
   sum(rate(container_cpu_usage_seconds_total{namespace="prod", container!=""}[5m]))
     / sum(kube_pod_container_resource_requests{namespace="prod", resource="cpu"})
   ```

6. **Guard the improvement.** Right-sizing that causes throttling/OOM is a regression, not a win. Re-run the step-5 throttling and OOM queries from Exercise 3 and confirm they are still ~0. Record before/after in the scorecard so the change is auditable.

7. **State the closed loop** you just executed: *measure (Ex. 3) → set target (VPA `Off`) → act (right-size) → re-measure (Ex. 3 again) → guard against regression (throttle/OOM) → report (scorecard).* This is the operational meaning of "measuring **and improving** platform efficiency."

### Comprehension questions

- **6a.** Why start the VPA in `updateMode: "Off"` instead of `"Auto"`? What production risk does `"Auto"` introduce that `"Off"` avoids, and what is the trade-off?
- **6b.** The recommendation gives `Lower Bound`, `Target`, and `Upper Bound`. Why did step 4 set the *request* near `Target` but the *limit* above `Upper Bound` rather than pinning both to `Target`?
- **6c.** VPA and the Horizontal Pod Autoscaler (HPA) both "autoscale," but composing them naively on the same metric is a known anti-pattern. Explain the conflict, and state the one supported way to combine them.
- **6d.** After right-sizing, CPU utilization jumped from 8% to 30% but *node* allocation efficiency barely moved. Give one reason the cluster-level saving didn't materialize yet, and the follow-up action (hint: think about what still has to happen at the node layer).

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**1a.** `metrics-server` exposes *actual, live* resource **usage** sampled from the kubelet/cAdvisor (it's the backend of the Metrics API and `kubectl top`). `kube-state-metrics` exposes *desired/declared* object state — `spec.replicas`, `resources.requests`, `resources.limits`, conditions — by watching the API server; it reports **zero** live usage. An efficiency ratio is *usage ÷ requested*, so you need the numerator from metrics-server/cAdvisor and the denominator from KSM. Neither alone can compute utilization.

**1b.** Any KPI that depends on *declared/desired state or object counts*: requests/limits utilization, allocation/bin-packing efficiency, deployment/replica counts, deployment conditions (hence change-failure detection), golden-path label ratios. cAdvisor only knows live container usage; it has no concept of a Deployment, a request, or a replica target.

**1c.** The **scheduler** uses **`requests`** to decide placement (a node must have enough *unreserved requested* CPU/memory to fit the Pod). The **kubelet/cgroup** enforces **`limits`** at runtime — CPU limits become CFS throttling, memory limits trigger OOM-kill when exceeded. Requests = scheduling reservation; limits = runtime ceiling.

### Exercise 2

**2a.** `observed_generation` only bumps when the Deployment's *spec* (usually the Pod template) changes and is *rolled out by the controller*. It **under**-counts: scaling replicas without a template change may not create a new revision the way a template change does, and any deploy path that doesn't touch this Deployment object (a Job, a config-only change applied to a ConfigMap, a canary handled outside the Deployment) is invisible. It can **over**-count relative to "successful production releases": a rollout that's immediately rolled back is two generation changes but arguably one (failed) release; rapid successive edits collapse or inflate depending on scrape resolution. The authoritative source of deployment frequency is the CI/CD pipeline emitting a deploy event, not cluster state.

**2b.** Throughput without stability rewards shipping fast regardless of breakage. If you report only frequency + lead time, the rational way to "improve the metric" is to deploy more and faster even as change-failure and recovery time balloon — you optimize the number that's watched and silently degrade reliability. The four metrics are a *balanced set precisely so one pair caps the other*; DORA's research shows elite performers are high on **both** pairs simultaneously, which is only visible if you report all four.

**2c.** Change Failure Rate is *observable at the deployment boundary* — the cluster (or CD system) sees whether the rollout succeeded/rolled back — so it can be instrumented at the platform layer. Lead Time for Changes spans the *whole value stream* from commit to prod, so its start timestamp lives in the SCM/CI, not the cluster; the cluster only knows the deploy end. This is why lead time **must** be captured by the golden-path pipeline (which sees both commit and deploy): no cluster-only measurement can reconstruct when the code was written.

**2d.** Not unambiguously good. A very low CFR can mean the team ships *rarely and in huge, heavily-gated batches* — long lead time, low frequency — trading throughput away for apparent stability. It can also mean failures aren't being detected/attributed. DORA's point is that Elite teams keep CFR low *while* deploying frequently with short lead time; a 2% CFR paired with monthly deploys is a low-performer signature, not an elite one.

### Exercise 3

**3a.** Root cause: requests are set far above real usage, so the scheduler *reserves* capacity nobody uses — the nodes are "full" of reservations while sitting nearly idle. The single lever: **lower the requests** (right-size) so reservations track real usage; only that frees allocatable room. Adding nodes just adds more idle reserved capacity.

**3b.** `working_set_bytes` is what the kernel considers *unreclaimable* and is exactly the figure the OOM-killer compares against the memory limit — it's the number that decides life/death. `rss` omits page-cache/other accounted memory and can undercount what triggers OOM; `usage_bytes` includes reclaimable cache and overcounts, making you set the request too high. Right-sizing against working-set is the only choice that matches runtime enforcement.

**3c.** Check (1) **CPU throttling** (`container_cpu_cfs_throttled_periods_total / ..._periods_total`) and (2) **OOM-kills / restart reason** (`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`). Low *average* utilization can hide short, sharp **peaks**; if you halve requests/limits into those peaks you cause throttling (latency) or OOM-kills (crashes). Average utilization must be read alongside peak behavior.

**3d.** "Increase node utilization" (pack more onto each node → higher allocation) and "increase request utilization" (make each Pod use closer to what it requests → right-size *down*) can conflict because right-sizing *down* lowers total requests, which *lowers* node allocation for the same workloads — the nodes look emptier. For cost, target **request utilization / right-sizing first**: it's the accurate signal of waste. Then *consolidate* the freed capacity (fewer/smaller nodes) to convert the slack into actual savings — otherwise you just moved idle from Pods to nodes.

### Exercise 4

**4a.** 100% is impossible: dependencies, deploys, hardware, and network all fail sometime, so a 100% SLO is breached the instant anything goes wrong and stops being a decision tool. It's anti-efficient because the last fractions of a nine cost exponentially more (redundancy, review gates, change freezes) for value users can't perceive, and a zero error budget means you can *never* ship risk — no deploys, no experiments. The error budget exists specifically to *spend* some unreliability on velocity; 100% sets that budget to zero.

**4b.** The 1-hour window confirms the burn is *sustained* (real budget damage), filtering out a momentary 5-minute spike that self-heals. The 5-minute window ensures the alert *clears quickly* once the incident is over instead of staying latched for an hour. AND-combining gives you "fires only on a genuine fast burn, and resets promptly" — the 5m guards against slow detection/slow reset, the 1h guards against flapping on transient noise.

**4c.** Budget healthy → **favor throughput**: ship features, run risky migrations, deploy freely; you have reliability to spend. Budget exhausted → **favor stability**: freeze feature deploys, redirect the team to reliability work (hardening, rollback tooling, fixing the top burners) until the budget recovers. On Monday, the on-call/lead reads "budget remaining" and that single number decides which mode the team is in — replacing an argument with a policy.

**4d.** (1) **Aggregate hides per-user/per-route pain**: a global 99.95% can be 100% for big tenants and 95% for one critical route or customer. (2) **"Non-5xx" isn't "correct"**: slow-but-200 responses, wrong-but-200 responses, or 4xx caused by a broken API all count as "available." The **latency SLI** (step 2) closes the slow-but-200 gap; per-route/per-tenant SLIs close the aggregation gap.

### Exercise 5

**5a.** Most likely: teams are deploying more but *off the golden path* — hand-rolled pipelines and bespoke infra — so the platform team absorbs the resulting operational load (hence paging up 25%) while adoption stays flat. Deployment frequency alone reads as "success," but the platform is actually failing at its real job (reducing cognitive load / toil); the extra deploys are creating support burden, not paved-road leverage.

**5b.** The platform team's own throughput measures *how busy the platform team is*, which can rise precisely when the platform is inefficient (lots of manual tickets). "Time to first deploy" measures the **customer's** flow — how fast a new team gets to production self-service — which is the platform's actual product outcome. A short onboarding time means the golden path genuinely removes friction; it can't be faked by the platform team working harder.

**5c.** Optimizing deploy count (an "Activity" metric) can degrade **Satisfaction** (developers deploy trivial changes just to move the number, or feel pressured) and **Performance/quality** (more deploys with weaker gates → higher CFR). Activity is easy to game and doesn't imply value delivered — SPACE's core warning.

**5d.** Every goal-metric has a cheap way to move it that damages something unmeasured; the counter-metric makes that damage visible. Deploy frequency ↑ can be bought with reliability (pair with CFR/error budget); utilization ↑ can be bought with throttling/OOM (pair with those signals). Pairing prevents **local optimization / metric-gaming** — moving one number by silently degrading a value the platform actually cares about.

### Exercise 6

**6a.** `"Off"` only writes recommendations to the VPA object — it never evicts or mutates Pods, so it's observe-only and safe. `"Auto"` (and `"Recreate"`) lets the updater **evict and recreate** Pods to apply new resources, which causes disruption and, if the recommendation is wrong or the app is spiky, can destabilize a running service. The trade-off: `"Off"` requires a human/GitOps step to apply the change; you get safety and auditability at the cost of automation. (Correct first move: measure the recommendation, then apply deliberately.)

**6b.** `Target` is the *typical* need; `Upper Bound` is the recommender's estimate of the *peak* it has observed (with confidence widening for short history). Set the **request** near `Target` so scheduling reserves the typical footprint (good bin-packing), but set the **limit** above `Upper Bound` so legitimate peaks aren't throttled/OOM-killed. Pinning both to `Target` would leave zero burst headroom and reintroduce the throttling/OOM risk right-sizing was meant to avoid.

**6c.** HPA scales replica *count* based on a utilization metric (e.g. CPU); VPA changes per-Pod *requests*. If both act on the **same** resource metric, they fight: VPA lowers the request, which raises the utilization percentage HPA reads, which makes HPA scale out — oscillation. The supported combination is to have **HPA drive on a different signal** (custom/external metric like RPS or queue depth, not the CPU/memory VPA manages) while VPA right-sizes CPU/memory — so the two never contend over the same number.

**6d.** Right-sizing lowered *requests*, so Pods now *fit* more densely, but the existing Pods are still spread across the same nodes — the freed request capacity is stranded until something *consolidates* it. Follow-up: run a **descheduler / node consolidation** (or Karpenter/cluster-autoscaler scale-down) to bin-pack Pods onto fewer nodes and remove the now-underutilized ones. Only turning slack into *fewer nodes* converts the utilization win into an actual cost saving.

</details>

---

**Reference sources**

- DORA — Four Keys / metrics definitions & research: <https://dora.dev/guides/dora-metrics-four-keys/>, <https://dora.dev/research/>
- Google SRE Workbook — Implementing SLOs & multi-window burn-rate alerting: <https://sre.google/workbook/implementing-slos/> and <https://sre.google/workbook/alerting-on-slos/>
- CNCF TAG App Delivery — Platform Engineering Maturity Model: <https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/>
- SPACE framework (developer productivity dimensions): <https://queue.acm.org/detail.cfm?id=3454124>
- FinOps Framework — capabilities (rate & usage optimization): <https://www.finops.org/framework/capabilities/>
- Kubernetes — kube-state-metrics: <https://github.com/kubernetes/kube-state-metrics>; metrics-server: <https://github.com/kubernetes-sigs/metrics-server>; Vertical Pod Autoscaler: <https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler>
- Prometheus — querying & PromQL: <https://prometheus.io/docs/prometheus/latest/querying/basics/>
- CNPE curriculum (topic 2.2, exam weight): <https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf>