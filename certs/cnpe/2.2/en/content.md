# Tema 2.2 — Measuring and Improving Platform Efficiency Using Deployment Metrics and Performance Indicators

> **Perfil:** SRE Senior / Platform Architect
> **Peso en el examen:** 6.67
> **Dominio CNPE:** Platform Engineering — Observability, Efficiency & Continuous Improvement

---

## 1. Motivation: the architectural problem of an unmeasured platform

An Internal Developer Platform (IDP) is not a product with a single customer; it is a **multi-tenant leverage layer** whose value is realized indirectly, through the velocity and reliability of the teams that consume it. This creates a structural measurement problem that a normal application does not have:

- **The platform's own uptime is necessary but not sufficient.** A control plane can report 100% API availability while every consuming team is blocked because a Golden Path takes 40 minutes to deploy, rollbacks are manual, and 30% of releases fail. The platform "works" and delivers nothing.
- **Efficiency is a system property, not a component property.** A node pool at 85% CPU utilization looks efficient until you discover it is 85% *requests* against 20% *actual usage* — you are paying for reserved-but-idle capacity, and the scheduler cannot bin-pack because requests lie.
- **Improvement without a baseline is theater.** "We made deploys faster" is unfalsifiable without Lead Time for Changes measured before and after, sliced per team, with a distribution (p50/p90) rather than an average that a single 6-hour outage skews.

The platform-engineering answer is to instrument the platform against **two orthogonal axes** and refuse to conflate them:

| Axis | Question it answers | Canonical framework | Failure mode if ignored |
|---|---|---|---|
| **Delivery performance** | How fast and how safely does change flow to production? | **DORA** (Four Keys) | Fast but fragile, or safe but frozen |
| **Resource / cost efficiency** | How much infrastructure does a unit of delivered value cost? | **FinOps + utilization/saturation** | Green dashboards, red invoice |
| **Reliability** | Is the service within its error budget? | **Golden Signals + SLO/SLI** | Alert fatigue, or silent SLO breach |
| **Developer experience** | Is the platform a lever or a tax? | **SPACE / adoption KPIs** | Shadow platforms, teams route around you |

The rest of this topic is the mechanics of instrumenting all four, wiring them into Prometheus/OpenTelemetry, and closing the loop with progressive-delivery automation that *gates on the metrics themselves*.

> **Architectural principle (CNCF Platforms White Paper, §"Measuring platforms"):** a platform is measured by the *outcomes it enables for its users*, using signals grouped as **adoption, velocity, reliability, and efficiency**. Never measure only the plane you operate.

---

## 2. The metric taxonomies — technical comparison and trade-offs

### 2.1 DORA "Four Keys" — the deployment-performance quartet

DORA (DevOps Research & Assessment) reduces delivery performance to four metrics that split cleanly into a **throughput pair** and a **stability pair**. The insight that makes them non-gameable *together* is that they are in tension: you cannot indefinitely improve one pair by sacrificing the other, so reporting all four forces honesty.

| Metric | Class | Definition (operational) | Where the signal comes from | Elite band (DORA 2023) |
|---|---|---|---|---|
| **Deployment Frequency (DF)** | Throughput | Count of successful deploys to prod per unit time | CD system events (Argo/Flux sync), or `Deployment` generation bumps | On-demand (multiple/day) |
| **Lead Time for Changes (LT)** | Throughput | Time from commit merged → running in prod | VCS commit ts ↔ deploy event ts | < 1 day |
| **Change Failure Rate (CFR)** | Stability | % of deploys causing degraded service needing remediation | deploy events ⋈ incident/rollback events | 0–15% |
| **Mean Time to Restore (MTTR / failed-deployment recovery time)** | Stability | Time from failure detected → service restored | incident open ts ↔ resolve ts | < 1 hour |

**Trade-off table — where each metric lies to you:**

| Metric | Gaming vector | Guardrail |
|---|---|---|
| DF | Split one deploy into ten no-op syncs | Count only deploys that change the running image digest |
| LT | Measure from "deploy started" not "commit merged" | Anchor `t0` at merge to the release branch, not at pipeline start |
| CFR | Classify rollbacks as "planned" | Auto-derive from rollback events + SLO burn, not a human checkbox |
| MTTR | Close incidents optimistically | Tie "restored" to the SLI recovering, not to a Jira transition |

### 2.2 Golden Signals vs USE vs RED — the reliability lenses

Three complementary methods; a mature platform runs all three at different layers.

| Method | Author / source | Primary target | The signals | Best for |
|---|---|---|---|---|
| **Four Golden Signals** | Google SRE Book | User-facing services | Latency, Traffic, Errors, Saturation | Request-driven microservices |
| **RED** | Tom Wilkie (Weaveworks) | Request-driven services | Rate, Errors, Duration | Simplified per-endpoint SLOs |
| **USE** | Brendan Gregg | Resources (CPU, mem, disk, net) | Utilization, Saturation, Errors | Node/kernel/hardware bottlenecks |

**Why you need both RED and USE:** RED tells you the *service* is slow; USE tells you *which resource* is the constraint. A p99 latency spike (RED, Duration) explained by a run-queue-length saturation (USE, Saturation) on the node is a right-sizing problem, not a code problem. Diagnosing with only one lens sends you to the wrong team.

### 2.3 Efficiency metrics — utilization is not efficiency

The single most common platform-engineering error is treating **utilization** (used ÷ allocatable) as the efficiency KPI. The correct denominator hierarchy:

```
Efficiency = actual_usage / provisioned_capacity
           = (usage / requests)  ×  (requests / allocatable)  ×  (allocatable / provisioned)
              └── request accuracy    └── bin-packing         └── node overhead
```

| Efficiency KPI | Formula | Healthy target | What a bad value means |
|---|---|---|---|
| **Request accuracy (CPU)** | `rate(container_cpu_usage) / kube_pod_container_resource_requests` | 0.6–0.8 | < 0.3 → over-requested, blocking bin-packing |
| **Allocation efficiency** | `sum(requests) / sum(allocatable)` | 0.7–0.85 | Low → over-provisioned node pool |
| **Memory over-commit risk** | `sum(limits.mem) / sum(allocatable.mem)` | ≤ 1.0 (guaranteed) | > 1.3 → OOMKill roulette under pressure |
| **Cost per deployment** | `$ / count(successful_deploys)` | trending ↓ | Rising → CI/CD or infra waste per unit value |
| **Idle cost ratio** | `(requests − usage) × unit_cost / total_cost` | < 0.25 | High → paying for reserved idle |

> **Trade-off:** driving request accuracy to 1.0 maximizes bin-packing but removes burst headroom → latency SLO risk under traffic spikes. The correct target is *request ≈ p90 usage, limit ≈ p99 usage* for latency-sensitive workloads, and *request ≈ p50* for batch. This is exactly what VPA computes (§4.3).

### 2.4 SPACE / adoption — the human-throughput layer

DORA measures the pipeline; SPACE (Satisfaction, Performance, Activity, Communication, Efficiency) measures the *engineers*. For a platform team the operational proxies are:

| Signal | Concrete metric | Source |
|---|---|---|
| Adoption | % of services onboarded to a Golden Path | Backstage catalog / IDP registry |
| Time-to-first-deploy | Hours from `git init` → prod for a new service | Scaffolder events |
| Self-service ratio | Deploys with zero platform-team tickets | Ticketing ⋈ deploy events |
| Golden-path retention | % services still on the path after 90 days | Catalog snapshots |

---

## 3. Instrumentation architecture — the full pipeline

```
                        ┌────────────────────────────────────────────┐
   app pods ── OTLP ───►│ OpenTelemetry Collector (agent + gateway)   │
                        └───────┬───────────────────────┬────────────┘
                                │ metrics (remote_write) │ traces
   kubelet /cadvisor ──────┐    ▼                        ▼
   kube-state-metrics ─────┼──► Prometheus  ──recording──► Thanos/Mimir (long-term)
   node-exporter ──────────┘        │  rules                    │
                                    │ SLO/DORA rules            │
   CD events (Argo/Flux) ──webhook──► Pushgateway/eventrouter ──┘
                                    ▼
                              Grafana  ◄── SLO dashboards, DORA Four Keys, cost
```

The load-bearing decisions:

- **kube-state-metrics (KSM)** exposes *object state* (`kube_pod_status_phase`, `kube_deployment_status_replicas_updated`, resource requests/limits). It is **not** metrics-server; KSM is for dashboards/alerts, metrics-server is for the HPA/`kubectl top` control loop. Confusing them is a classic exam trap.
- **Deployment events are not scrape targets.** A deploy is a discrete event, so it arrives by webhook → Pushgateway (or a dedicated event exporter), not by pull.

### 3.1 kube-state-metrics deployment (complete, unabridged)

```yaml
# kube-state-metrics-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/version: "2.13.0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics
  labels:
    app.kubernetes.io/name: kube-state-metrics
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - secrets
      - nodes
      - pods
      - services
      - serviceaccounts
      - resourcequotas
      - replicationcontrollers
      - limitranges
      - persistentvolumeclaims
      - persistentvolumes
      - namespaces
      - endpoints
    verbs: ["list", "watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "daemonsets", "deployments", "replicasets"]
    verbs: ["list", "watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs", "jobs"]
    verbs: ["list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["list", "watch"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-state-metrics
subjects:
  - kind: ServiceAccount
    name: kube-state-metrics
    namespace: monitoring
---
# kube-state-metrics-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    app.kubernetes.io/name: kube-state-metrics
spec:
  replicas: 1                      # shard with --shard/--total-shards for >100 nodes
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-state-metrics
    spec:
      serviceAccountName: kube-state-metrics
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: kube-state-metrics
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
          args:
            - --resources=pods,deployments,replicasets,statefulsets,daemonsets,nodes,horizontalpodautoscalers,resourcequotas,poddisruptionbudgets
            - --metric-labels-allowlist=pods=[app.kubernetes.io/name,team],deployments=[team,tier]
          ports:
            - name: http-metrics
              containerPort: 8080
            - name: telemetry
              containerPort: 8081
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi        # no CPU limit: avoid throttling the exporter
          livenessProbe:
            httpGet: { path: /livez, port: 8080 }
            initialDelaySeconds: 5
          readinessProbe:
            httpGet: { path: /readyz, port: 8081 }
            initialDelaySeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    app.kubernetes.io/name: kube-state-metrics
spec:
  clusterIP: None                  # headless → each shard scraped individually
  ports:
    - name: http-metrics
      port: 8080
      targetPort: http-metrics
    - name: telemetry
      port: 8081
      targetPort: telemetry
  selector:
    app.kubernetes.io/name: kube-state-metrics
```

### 3.2 ServiceMonitor (Prometheus Operator) — scraping KSM

```yaml
# kube-state-metrics-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    release: prometheus            # must match the Prometheus CR's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kube-state-metrics
  endpoints:
    - port: http-metrics
      interval: 30s
      scrapeTimeout: 25s
      honorLabels: true
    - port: telemetry
      interval: 30s
```

---

## 4. Deployment & efficiency signals — recording rules and manifests

### 4.1 DORA Four Keys as Prometheus recording + query rules

The pattern: a lightweight **event exporter** pushes a counter on every successful CD sync and on every rollback, labelled by app/team; recording rules turn those counters into the Four Keys.

```yaml
# dora-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-four-keys
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
    - name: dora.throughput
      interval: 1m
      rules:
        # --- Deployment Frequency: successful prod deploys / day, per app ---
        - record: dora:deployment_frequency:rate1d
          expr: |
            sum by (app, team) (
              increase(cd_deployment_success_total{env="prod"}[1d])
            )

        # --- Lead Time for Changes: commit->prod, exposed by the exporter
        #     as a histogram in seconds; report p50 and p90 over 7d ---
        - record: dora:lead_time_seconds:p50
          expr: |
            histogram_quantile(0.50,
              sum by (app, team, le) (
                rate(cd_lead_time_seconds_bucket{env="prod"}[7d])
              )
            )
        - record: dora:lead_time_seconds:p90
          expr: |
            histogram_quantile(0.90,
              sum by (app, team, le) (
                rate(cd_lead_time_seconds_bucket{env="prod"}[7d])
              )
            )

    - name: dora.stability
      interval: 1m
      rules:
        # --- Change Failure Rate: failed deploys / all deploys over 7d ---
        - record: dora:change_failure_rate:ratio7d
          expr: |
            sum by (app, team) (increase(cd_deployment_failure_total{env="prod"}[7d]))
            /
            clamp_min(
              sum by (app, team) (increase(cd_deployment_total{env="prod"}[7d])),
              1
            )

        # --- MTTR: mean of per-incident recovery durations over 30d ---
        - record: dora:mttr_seconds:avg30d
          expr: |
            sum by (app, team) (increase(cd_incident_recovery_seconds_sum[30d]))
            /
            clamp_min(
              sum by (app, team) (increase(cd_incident_recovery_seconds_count[30d])),
              1
            )

    - name: dora.alerts
      rules:
        - alert: ChangeFailureRateHigh
          expr: dora:change_failure_rate:ratio7d > 0.15
          for: 1h
          labels: { severity: warning }
          annotations:
            summary: "CFR {{ $value | humanizePercentage }} for {{ $labels.app }}"
            description: "Change Failure Rate exceeds the 15% elite threshold over 7d."
        - alert: LeadTimeRegressed
          expr: dora:lead_time_seconds:p90 > 86400   # > 1 day
          for: 2h
          labels: { severity: info }
          annotations:
            summary: "p90 lead time {{ $labels.app }} above 1 day"
```

### 4.2 Efficiency & SLO recording rules

```yaml
# efficiency-slo-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-efficiency-slo
  namespace: monitoring
  labels: { release: prometheus }
spec:
  groups:
    - name: efficiency.resource
      interval: 30s
      rules:
        # CPU request accuracy per workload (usage vs requested)
        - record: workload:cpu_request_accuracy:ratio
          expr: |
            sum by (namespace, workload) (
              rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])
            )
            /
            clamp_min(
              sum by (namespace, workload) (
                kube_pod_container_resource_requests{resource="cpu"}
                * on(namespace, pod) group_left(workload)
                  namespace_workload_pod:kube_pod_owner:relabel
              ), 0.001
            )

        # Cluster-wide CPU allocation efficiency (requests / allocatable)
        - record: cluster:cpu_allocation_efficiency:ratio
          expr: |
            sum(kube_pod_container_resource_requests{resource="cpu"})
            /
            sum(kube_node_status_allocatable{resource="cpu"})

        # Memory over-commit factor (limits / allocatable) — > 1 is risky
        - record: cluster:memory_overcommit:ratio
          expr: |
            sum(kube_pod_container_resource_limits{resource="memory"})
            /
            sum(kube_node_status_allocatable{resource="memory"})

        # Idle cost ratio: reserved-but-unused CPU as fraction of reserved
        - record: cluster:cpu_idle_reserved:ratio
          expr: |
            (
              sum(kube_pod_container_resource_requests{resource="cpu"})
              -
              sum(rate(container_cpu_usage_seconds_total{container!="POD"}[5m]))
            )
            /
            clamp_min(sum(kube_pod_container_resource_requests{resource="cpu"}), 0.001)

    - name: slo.golden_signals
      interval: 30s
      rules:
        # RED — request error ratio per service (multi-window for burn rate)
        - record: service:request_errors:ratio_rate5m
          expr: |
            sum by (service) (rate(http_requests_total{code=~"5.."}[5m]))
            /
            clamp_min(sum by (service) (rate(http_requests_total[5m])), 1)
        - record: service:request_errors:ratio_rate1h
          expr: |
            sum by (service) (rate(http_requests_total{code=~"5.."}[1h]))
            /
            clamp_min(sum by (service) (rate(http_requests_total[1h])), 1)
        # RED — latency p99
        - record: service:request_latency_seconds:p99_5m
          expr: |
            histogram_quantile(0.99,
              sum by (service, le) (rate(http_request_duration_seconds_bucket[5m]))
            )

    - name: slo.error_budget_burn
      rules:
        # Multi-window multi-burn-rate alert (Google SRE workbook, 2%/1h budget)
        - alert: ErrorBudgetFastBurn
          expr: |
            service:request_errors:ratio_rate5m > (14.4 * 0.001)
            and
            service:request_errors:ratio_rate1h > (14.4 * 0.001)
          for: 2m
          labels: { severity: page }
          annotations:
            summary: "Fast burn: {{ $labels.service }} spending 30-day budget in ~2 days"
```

> The `14.4` factor is the canonical fast-burn multiplier for a 99.9% SLO: consuming the 30-day budget in ~2 days. Pairing a 5m and a 1h window suppresses single-spike false pages (Google SRE Workbook, *Alerting on SLOs*).

### 4.3 Vertical Pod Autoscaler — closing the request-accuracy loop in `recommender` mode

VPA turns "request accuracy is 0.3" into an actionable target. Run it in `Off`/recommender mode first so it advises without evicting.

```yaml
# vpa-recommender.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-vpa
  namespace: shop
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout
  updatePolicy:
    updateMode: "Off"          # recommend only — no eviction. Flip to "Auto" later.
  resourcePolicy:
    containerPolicies:
      - containerName: checkout
        controlledResources: ["cpu", "memory"]
        controlledValues: RequestsAndLimits
        minAllowed: { cpu: 50m, memory: 128Mi }
        maxAllowed: { cpu: "2",  memory: 2Gi }
```

```console
$ kubectl -n shop describe vpa checkout-vpa | sed -n '/Recommendation/,/Events/p'
  Recommendation:
    Container Recommendations:
      Container Name:  checkout
      Lower Bound:
        Cpu:     120m
        Memory:  180Mi
      Target:
        Cpu:     250m
        Memory:  256Mi
      Uncapped Target:
        Cpu:     250m
        Memory:  256Mi
      Upper Bound:
        Cpu:     410m
        Memory:  340Mi
Events:            <none>
```

Interpretation: the Deployment currently requests `cpu: 1` but the VPA `Target` (p90-based) is `250m`. Request accuracy ≈ 0.25 → you are reserving **4×** the CPU the workload needs. Aligning requests to `Target` frees 750m per replica for the scheduler to bin-pack.

---

## 5. Closing the loop — gating deployments on the metrics (Argo Rollouts)

Measuring is inert unless the deployment pipeline *consumes* the measurement. A canary that promotes only when the SLI holds is the mechanism that turns metrics into a lower Change Failure Rate.

```yaml
# analysis-template.yaml — reusable metric gate
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-and-latency
  namespace: shop
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5
      successCondition: result[0] >= 0.99
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            1 - (
              sum(rate(http_requests_total{service="{{args.service-name}}",code=~"5.."}[2m]))
              /
              clamp_min(sum(rate(http_requests_total{service="{{args.service-name}}"}[2m])), 1)
            )
    - name: latency-p99
      interval: 1m
      count: 5
      successCondition: result[0] <= 0.30       # 300 ms
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            histogram_quantile(0.99,
              sum by (le) (
                rate(http_request_duration_seconds_bucket{service="{{args.service-name}}"}[2m])
              )
            )
---
# rollout.yaml — canary that self-aborts on SLI breach (raising nothing to CFR)
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: checkout
  namespace: shop
spec:
  replicas: 6
  strategy:
    canary:
      canaryService: checkout-canary
      stableService: checkout-stable
      trafficRouting:
        smi: { rootService: checkout }
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: success-rate-and-latency
            args:
              - name: service-name
                value: checkout-canary
        - setWeight: 50
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate-and-latency
            args:
              - name: service-name
                value: checkout-canary
        - setWeight: 100
  selector:
    matchLabels: { app: checkout }
  template:
    metadata:
      labels: { app: checkout }
    spec:
      containers:
        - name: checkout
          image: registry.example.com/checkout:1.8.2
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 250m, memory: 256Mi }   # aligned to VPA target
            limits:   { memory: 384Mi }
```

```console
$ kubectl argo rollouts get rollout checkout -n shop
Name:            checkout
Namespace:       shop
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          2/6
  SetWeight:     10
  ActualWeight:  10
Images:          checkout:1.8.1 (stable)
                 checkout:1.8.2 (canary)
Replicas:
  Desired:       6
  Current:       6
  Updated:       1
  Ready:         6
  Available:     6

NAME                                  KIND         STATUS     AGE  INFO
⟳ checkout                            Rollout      ॥ Paused   14d
├──# revision:9
│  └──⧉ checkout-6b4c8f9c7d           ReplicaSet   ✔ Healthy  90s  canary
│     └──□ checkout-6b4c8f9c7d-x2p9q  Pod          ✔ Running  90s  ready:1/1
└──# revision:8
   └──⧉ checkout-7f9d5b6c88           ReplicaSet   ✔ Healthy  14d  stable
```

When the AnalysisRun fails, the Rollout aborts *before* the failure ever reaches 100% of traffic — the event exporter records it as a `cd_deployment_failure_total`, so a caught regression shows up as one line in the CFR numerator instead of an incident in MTTR.

---

## 6. Verification & failure diagnosis

### 6.1 Verify the metrics pipeline is actually collecting

```console
$ kubectl -n monitoring get servicemonitor kube-state-metrics
NAME                   AGE
kube-state-metrics     6d

# Confirm Prometheus discovered the target (not silently dropped by relabeling)
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
    | jq -r '.data.activeTargets[] | select(.labels.job=="kube-state-metrics") | "\(.scrapeUrl) \(.health)"'
http://10.244.2.14:8080/metrics up

# Confirm a KSM series exists
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=kube_deployment_status_replicas' \
    | jq '.data.result | length'
37
```

### 6.2 Verify recording rules evaluate (not just parse)

```console
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=cluster:cpu_allocation_efficiency:ratio' \
    | jq -r '.data.result[0].value[1]'
0.42
```

`0.42` → the cluster reserves 42% of allocatable CPU. If `workload:cpu_request_accuracy:ratio` is simultaneously ~0.3, the diagnosis is **over-requesting**, not under-provisioning — do *not* scale the node pool up; right-size the requests (VPA §4.3).

### 6.3 Diagnose: rule shows `NaN` / empty result

| Symptom | Root cause | Fix |
|---|---|---|
| Query returns empty | Label join key mismatch (`workload` label absent) | Verify the `namespace_workload_pod:kube_pod_owner:relabel` recording rule exists (ships with kube-prometheus); without it the `group_left` join yields nothing |
| Ratio = `+Inf` | Denominator hit zero | Wrap denominators in `clamp_min(..., 1)` / small epsilon — already applied above |
| DF stuck at 0 | Event exporter not pushing, or `env` label ≠ `prod` | `curl` the Pushgateway `/metrics`; check `cd_deployment_success_total` labels |
| p99 latency = `NaN` | Histogram has no `+Inf` bucket or too few samples | Confirm the app exports `_bucket` series and traffic > 0 in the window |
| CFR spikes to 1.0 | Failure counter increments but total counter doesn't | Ensure the exporter bumps `cd_deployment_total` on **every** attempt, success or fail |

### 6.4 Verify the SLO alert actually fires (don't trust an untested alert)

```console
# Force-evaluate the burn-rate expression against live data
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=ALERTS{alertname="ErrorBudgetFastBurn"}' \
    | jq -r '.data.result[] | "\(.metric.service) \(.metric.alertstate)"'
checkout pending

# Confirm the rule group is healthy and evaluating on schedule
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/rules' \
    | jq -r '.data.groups[] | select(.name=="slo.error_budget_burn") | .rules[] | "\(.name) health=\(.health) lastEval=\(.evaluationTime)s"'
ErrorBudgetFastBurn health=ok lastEval=0.0031s
```

An alert in `health=err` (bad expression) is worse than no alert — it is a silent blind spot. Always assert `health=ok`.

### 6.5 Diagnose efficiency regressions with the USE lens

```console
# Node saturation: run-queue pressure (USE Saturation) behind a latency spike
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=node_load1 / count by(instance)(node_cpu_seconds_total{mode="idle"})' \
    | jq -r '.data.result[] | "\(.metric.instance) load-per-core=\(.value[1])"'
ip-10-0-3-21 load-per-core=1.9
ip-10-0-3-44 load-per-core=0.4

# CPU throttling (the invisible latency killer when limits are too tight)
$ kubectl -n monitoring exec -it prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=rate(container_cpu_cfs_throttled_periods_total{namespace="shop"}[5m]) / clamp_min(rate(container_cpu_cfs_periods_total{namespace="shop"}[5m]),1)' \
    | jq -r '.data.result[] | select((.value[1]|tonumber) > 0.1) | "\(.metric.pod) throttled=\(.value[1])"'
checkout-6b4c8f9c7d-x2p9q throttled=0.34
```

`load-per-core = 1.9` on one node + 34% CFS throttling on the canary pod → the p99 latency breach that aborted the canary was **CPU-limit throttling under a saturated node**, not a code regression. The remediation is capacity/limit, and the metric gate correctly prevented it from becoming a Change Failure — exactly the loop this topic is about.

---

## 7. Reference implementation checklist (production readiness)

- [ ] KSM, node-exporter, metrics-server, cAdvisor all scraped; targets `up`.
- [ ] DORA Four Keys computed from **event** data, sliced per team, reported as distributions (p50/p90), never single averages.
- [ ] Efficiency reported as `usage/requests` AND `requests/allocatable` — never utilization alone.
- [ ] SLOs use multi-window multi-burn-rate alerts; every alert rule asserted `health=ok`.
- [ ] Deployments gated on Prometheus AnalysisTemplates so caught regressions land in CFR, not MTTR.
- [ ] VPA in recommender mode feeding request right-sizing; over-commit ratio ≤ 1.0 for latency-critical tiers.
- [ ] Cost-per-deployment and idle-cost-ratio trended over time, tied back to the efficiency rules.

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- CNCF Platforms White Paper (TAG App Delivery), "Measuring platforms" — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- DORA — Four Keys / State of DevOps metrics — https://dora.dev/guides/dora-metrics-four-keys/
- Google SRE Book, "Monitoring Distributed Systems" (Four Golden Signals) — https://sre.google/sre-book/monitoring-distributed-systems/
- Google SRE Workbook, "Alerting on SLOs" (multi-window multi-burn-rate) — https://sre.google/workbook/alerting-on-slos/
- Prometheus — Recording rules — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- Prometheus — Querying / `histogram_quantile` — https://prometheus.io/docs/prometheus/latest/querying/functions/
- kube-state-metrics — https://github.com/kubernetes/kube-state-metrics
- Kubernetes metrics-server — https://github.com/kubernetes-sigs/metrics-server
- Prometheus Operator — ServiceMonitor / PrometheusRule CRDs — https://prometheus-operator.dev/docs/operator/api/
- Vertical Pod Autoscaler — https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Argo Rollouts — Analysis & Progressive Delivery — https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- OpenTelemetry Collector — https://opentelemetry.io/docs/collector/
- Brendan Gregg — USE Method — https://www.brendangregg.com/usemethod.html
- Tom Wilkie — RED Method — https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- FinOps Foundation — Framework & KPIs — https://www.finops.org/framework/
- SPACE framework (ACM Queue) — https://queue.acm.org/detail.cfm?id=3454124