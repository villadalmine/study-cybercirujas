# Topic 6.1 — Platform Efficiency, Product Value, and Team Productivity

> CNPA Domain 6 — *Measuring Your Platform*. Exam weight for this competency: **4.0%**.
> Level: Principal Platform Architect / Senior SRE. Everything below is production-grade and reproducible on a real cluster.

---

## 1. The production architectural problem: a platform you cannot measure is a platform you cannot fund

An Internal Developer Platform (IDP) is not a project with an end date; it is a **product with a lifecycle**. The moment your platform team ships a golden path, a self-service portal, or a paved-road CI template, three questions immediately determine whether the platform survives the next budget cycle:

1. **Efficiency** — Are we spending compute, storage, and human toil in proportion to the value produced? Or is the platform a cost sink that grows faster than adoption?
2. **Product value** — Do the stream-aligned teams (the *customers*) actually adopt the paved roads, and does adoption correlate with better outcomes? Or did we build a beautiful abstraction nobody uses (the classic "shadow platform" failure, where teams route around your golden path back to raw `kubectl` and hand-rolled Terraform)?
3. **Team productivity** — Is the platform reducing the **cognitive load** of stream-aligned teams and increasing their delivery throughput, or is it adding a layer of ticket-driven friction?

The failure mode this competency exists to prevent is the **unmeasurable platform**: an engineering org spends two years and several FTEs building an IDP, cannot produce a single number that ties platform investment to business outcome, and is defunded the first time finance runs a cost-cutting pass. The CNCF *Platform Engineering Maturity Model* codifies "Measurement" as one of its five aspects precisely because platforms that skip it plateau at the "Applied" level and never reach "Managed" or "Optimizing."

### 1.1 Why this is an architecture problem, not a spreadsheet problem

Measuring a platform correctly forces architectural decisions that must be designed *into* the platform from day one, not bolted on:

- **Deployment-frequency and lead-time signals** must be emitted by the delivery machinery (Argo CD / Flux / Tekton), which means your CD layer must be **event-emitting and queryable**, not a black box.
- **Cost attribution** requires that every workload carry ownership metadata (`team`, `cost-center`, `product`) as labels/annotations from the moment it is scheduled — retrofitting labels onto 4,000 running pods is a migration project.
- **Developer-experience feedback** requires an out-of-band survey/telemetry channel (portal analytics, periodic DevEx surveys) because system metrics alone cannot tell you whether an engineer *felt* blocked.

The core architectural tension is **system metrics vs. perceptual metrics**. Neither alone is sufficient. A platform can have world-class deployment frequency (system metric) while every developer hates it (perceptual). This is exactly why the industry converged on multi-dimensional frameworks (DORA + SPACE + DevEx) rather than a single north-star number — a single metric is always gameable.

---

## 2. Technical comparatives and trade-offs

### 2.1 The three measurement frameworks you must be able to distinguish

| Framework | What it measures | Primary unit of analysis | Strength | Failure mode / gaming risk | Best used for |
|---|---|---|---|---|---|
| **DORA** (Four Keys + Reliability) | Delivery throughput & stability | The *delivery pipeline* / system | Objective, system-derived, benchmarkable against industry | Ignores developer sentiment & cognitive load; deploy frequency is gameable by splitting deploys | Proving the paved road improves *outcomes* |
| **SPACE** | Satisfaction, Performance, Activity, Communication, Efficiency | The *individual & team* (holistic) | Balances perceptual + system; explicitly warns against single-metric use | Requires survey infrastructure; slower feedback loop | Guarding against optimizing one metric at the expense of others |
| **DX Core 4 / DevEx** (feedback loops, cognitive load, flow state) | Developer experience quality | The *developer's daily friction* | Directly actionable for a platform team; maps to concrete friction points | Perceptual bias; needs consistent survey cadence | Prioritizing which platform friction to remove next |

**Key exam distinction:** DORA answers *"is our delivery fast and stable?"*, SPACE answers *"are we improving throughput without burning people out or degrading quality?"*, and DevEx answers *"where exactly is the friction the platform should remove?"*. A mature platform reports on all three; the CNCF maturity model's "Measurement" aspect expects both **operational** (system) and **experiential** (perceptual) signals.

### 2.2 The four DORA keys — precise definitions and derivation source

| DORA metric | Definition | Where the signal comes from | Elite benchmark (2024) |
|---|---|---|---|
| **Deployment Frequency** | How often the org successfully releases to production | CD system events (Argo CD `Sync` succeeded → prod) | On-demand (multiple/day) |
| **Lead Time for Changes** | Time from code committed → running in production | `git commit` timestamp → deploy timestamp | < 1 day (elite: < 1 hour) |
| **Change Failure Rate (CFR)** | % of deployments causing a production failure | Deployments requiring rollback/hotfix ÷ total deployments | 0–15% |
| **Failed Deployment Recovery Time** (formerly MTTR) | Time to restore service after a failed deployment | Incident open → resolved | < 1 hour |

> Note the 2024 rename: DORA replaced "Time to Restore Service / MTTR" with **Failed Deployment Recovery Time** to tie recovery specifically to deployment-induced failures. Know both names for the exam.

### 2.3 Efficiency: right-sizing strategies compared

Platform efficiency is dominated by the gap between **requested** and **actually used** resources — the single largest source of cloud waste in Kubernetes. Comparison of the mechanisms:

| Approach | Mechanism | Latency to adjust | Disruption | Best for | Trade-off |
|---|---|---|---|---|---|
| **Manual right-sizing** | Human reads `kubectl top` / dashboards, edits requests | Days–weeks | None (planned) | Small, stable fleets | Doesn't scale; stale immediately |
| **VPA (`Auto`/`Recreate`)** | Recommender computes P90/P95 usage → mutates requests, evicts pod | Minutes | Pod restart on update | Batch, stateful, single-replica-tolerant | Restarts; conflicts with HPA on same resource |
| **VPA (`Off` = recommend-only) + Goldilocks** | Recommender only; human/GitOps applies | Advisory | None | Getting recommendations without auto-eviction | Requires human/pipeline to act |
| **HPA** | Scales *replicas* on a metric (CPU/custom) | Seconds–minutes | Adds/removes pods | Stateless, spiky, latency-sensitive | Scales count, not per-pod size |
| **In-place Pod Resize** (`resize` subresource, beta in 1.33) | Patches container resources without restart | Seconds | **None** | Vertical scaling of running workloads | Newer; not all runtimes/resources support in-place |

**Golden rule for the exam:** never run **HPA and VPA on the same resource dimension** (e.g. both on CPU) — they fight, because HPA scales out while VPA scales up, and each reacts to the other's changes. Use HPA on CPU + VPA on memory, or use VPA in `Off` mode for recommendations only.

### 2.4 Cost visibility: build vs. buy

| Option | Model | Data source | Multi-cloud | License | Notes |
|---|---|---|---|---|---|
| **OpenCost** (CNCF incubating) | Open spec + reference impl | Prometheus + cloud billing APIs | Yes | Apache-2.0 | The vendor-neutral standard; Kubecost is built on it |
| **Kubecost** | Commercial (free tier) | OpenCost core + enterprise features | Yes | Proprietary + OSS core | Adds savings recommendations, longer retention |
| **Cloud-native (AWS Split Cost Allocation, GCP GKE cost breakdown)** | Provider billing | Provider only | No | Included | Accurate for one cloud, no in-cluster granularity per namespace by default |
| **kube-state-metrics + custom recording rules** | DIY | KSM + Prometheus | Yes | Apache-2.0 | Full control, no cost model — you supply the $/core-hour |

---

## 3. Complete infrastructure and manifests (uncut)

Everything in this section is designed to be `kubectl apply`-able against a cluster running kube-prometheus-stack (Prometheus Operator), kube-state-metrics, and Argo CD.

### 3.1 Enforcing ownership metadata so cost and productivity can be attributed

Attribution is impossible without labels. This `Kyverno` policy **rejects any Deployment that lacks the ownership labels** the measurement layer depends on. Without enforcement, your cost dashboards silently show 30% "unallocated."

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-ownership-labels
  annotations:
    policies.kyverno.io/title: Require Ownership & Cost Labels
    policies.kyverno.io/category: FinOps, Measurement
    policies.kyverno.io/description: >-
      Every workload must carry team, product and cost-center labels so that
      platform efficiency (cost) and product value (adoption) can be attributed.
spec:
  validationFailureAction: Enforce   # reject on violation; use Audit to observe first
  background: true
  rules:
    - name: check-workload-labels
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
                - Rollout
      validate:
        message: >-
          Workloads must set metadata.labels: team, product, cost-center,
          and app.kubernetes.io/part-of (the golden-path template stamps these).
        pattern:
          metadata:
            labels:
              team: "?*"
              product: "?*"
              cost-center: "?*"
              app.kubernetes.io/part-of: "?*"
```

### 3.2 Namespace-level resource governance (efficiency guardrail)

`ResourceQuota` caps total spend per team; `LimitRange` prevents the two efficiency killers: pods with **no requests** (unschedulable accounting, cost invisible) and pods with **absurd limits** (bin-packing killer).

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-payments-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu: "40"
    requests.memory: 80Gi
    limits.cpu: "80"
    limits.memory: 160Gi
    persistentvolumeclaims: "20"
    count/deployments.apps: "50"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: team-payments-limits
  namespace: team-payments
spec:
  limits:
    - type: Container
      default:              # applied as limit if container omits one
        cpu: "500m"
        memory: 512Mi
      defaultRequest:       # applied as request if container omits one
        cpu: "100m"
        memory: 128Mi
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: "10m"
        memory: 16Mi
      maxLimitRequestRatio:  # limit may be at most 4x the request — curbs overcommit
        cpu: "4"
        memory: "4"
```

### 3.3 VPA in recommend-only mode (safe efficiency signal)

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: checkout-api-vpa
  namespace: team-payments
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  updatePolicy:
    updateMode: "Off"        # recommend only — never evicts. Safe for measurement.
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        minAllowed:
          cpu: 25m
          memory: 64Mi
        maxAllowed:
          cpu: "2"
          memory: 2Gi
        controlledResources: ["cpu", "memory"]
```

### 3.4 OpenCost deployment (the cost-attribution engine)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opencost
  namespace: opencost
  labels:
    app.kubernetes.io/name: opencost
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: opencost
  template:
    metadata:
      labels:
        app.kubernetes.io/name: opencost
    spec:
      serviceAccountName: opencost
      containers:
        - name: opencost
          image: ghcr.io/opencost/opencost:1.114.0
          ports:
            - containerPort: 9003   # API
            - containerPort: 9090   # UI
          env:
            - name: PROMETHEUS_SERVER_ENDPOINT
              value: "http://prometheus-operated.monitoring.svc:9090"
            - name: CLOUD_PROVIDER_API_KEY
              value: ""             # falls back to on-prem/default pricing model
            - name: CLUSTER_ID
              value: "prod-eu-west-1"
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet: { path: /healthz, port: 9003 }
            initialDelaySeconds: 30
```

### 3.5 DORA metrics as Prometheus recording rules

This is the heart of the measurement architecture. We derive DORA signals from **kube-state-metrics** (deployment status changes) and **Argo CD** metrics (sync history). The exporter pattern: Argo CD exposes `argocd_app_sync_total` and `argocd_app_info`; a deploy-frequency series is the rate of successful prod syncs.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dora-platform-metrics
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # so the operator picks it up
spec:
  groups:
    - name: dora.deployment-frequency
      interval: 60s
      rules:
        # Deployment frequency: successful Argo CD syncs to prod per day, per team.
        - record: dora:deployment_frequency:rate1d
          expr: |
            sum by (team, product) (
              increase(argocd_app_sync_total{phase="Succeeded", dest_server=~".*prod.*"}[1d])
              * on(name) group_left(team, product)
                argocd_app_info
            )

    - name: dora.change-failure-rate
      interval: 60s
      rules:
        # Numerator: deploys that were followed by a rollback within 1h.
        - record: dora:failed_deployments:rate1d
          expr: |
            sum by (team, product) (
              increase(argocd_app_sync_total{phase="Failed", dest_server=~".*prod.*"}[1d])
            )
        # Change Failure Rate = failed deploys / total deploys (guard against div-by-zero).
        - record: dora:change_failure_rate:ratio1d
          expr: |
            dora:failed_deployments:rate1d
            /
            clamp_min(dora:deployment_frequency:rate1d + dora:failed_deployments:rate1d, 1)

    - name: dora.recovery-time
      interval: 60s
      rules:
        # Failed Deployment Recovery Time: mean incident duration, sourced from an
        # Alertmanager-driven incident recorder that emits incident_duration_seconds.
        - record: dora:recovery_time_seconds:avg1d
          expr: |
            avg by (team) (
              avg_over_time(incident_duration_seconds{severity="page"}[1d])
            )

    - name: platform.efficiency
      interval: 60s
      rules:
        # Cluster-wide CPU request efficiency = used / requested. Low = waste.
        - record: platform:cpu_request_efficiency:ratio
          expr: |
            sum(rate(container_cpu_usage_seconds_total{container!=""}[5m]))
            /
            sum(kube_pod_container_resource_requests{resource="cpu"})
        # Memory request efficiency.
        - record: platform:memory_request_efficiency:ratio
          expr: |
            sum(container_memory_working_set_bytes{container!=""})
            /
            sum(kube_pod_container_resource_requests{resource="memory"})
        # Per-team monthly cost projection (OpenCost exposes node_total_hourly_cost).
        - record: platform:team_cpu_cost:monthly
          expr: |
            sum by (team) (
              kube_pod_container_resource_requests{resource="cpu"}
              * on(node) group_left() node_cpu_hourly_cost
            ) * 730
```

### 3.6 Platform SLOs — measuring the platform *as a product*

The platform itself must meet SLOs for its consumers. Example: the golden-path CI template's build API and the self-service provisioning API.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-product-slos
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: platform.slo.provisioning-api
      rules:
        # SLI: fraction of self-service provisioning requests served < 500ms and 2xx.
        - record: slo:provisioning_api:availability:ratio_rate5m
          expr: |
            sum(rate(http_requests_total{job="provisioning-api",code=~"2.."}[5m]))
            /
            sum(rate(http_requests_total{job="provisioning-api"}[5m]))
        - alert: PlatformProvisioningSLOBurn
          expr: |
            (1 - slo:provisioning_api:availability:ratio_rate5m) > (14.4 * (1 - 0.999))
          for: 5m
          labels:
            severity: page
            slo: provisioning-api
          annotations:
            summary: "Provisioning API burning 99.9% error budget 14.4x too fast"
            description: "Fast-burn (1h window) multi-window burn-rate alert tripped."
```

### 3.7 Product-value signal: a Backstage scorecard (Tech Insights / Soundcheck-style check)

Adoption is a product-value metric. This Backstage `catalog-info.yaml` annotation + a Tech Insights fact check let the portal score whether a service is *on the golden path* (uses the paved CI, has an owner, ships an SBOM).

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-api
  annotations:
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: checkout-api-prod
    tech-insights.io/paved-road: "true"    # golden-path template stamps this
  labels:
    tier: "1"
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: payments
```

```typescript
// packages/backend/src/plugins/techInsights.ts — a golden-path adoption check.
// Scores a component 1.0 if it is on the paved road, has an owner, and passed CI.
export const goldenPathAdoptionCheck: TechInsightCheck = {
  id: 'golden-path-adoption',
  name: 'Golden Path Adoption',
  type: 'json-rules-engine',
  factIds: ['pavedRoadFactRetriever'],
  rule: {
    conditions: {
      all: [
        { fact: 'usesPavedCiTemplate', operator: 'equal', value: true },
        { fact: 'hasOwner',            operator: 'equal', value: true },
        { fact: 'hasSbom',             operator: 'equal', value: true },
      ],
    },
  },
};
```

---

## 4. CLI commands and real terminal output

### 4.1 Baseline efficiency: what is requested vs. what is used

```console
$ kubectl top pods -n team-payments --sort-by=cpu
NAME                            CPU(cores)   MEMORY(bytes)
checkout-api-7c9f4b8d6-4xk2p    412m         push 738Mi
checkout-api-7c9f4b8d6-l9m7q    388m         701Mi
ledger-worker-5d8c7-2ptzr       55m          1204Mi
notify-fanout-6b4f9-qr8sn       12m          64Mi
```

```console
$ kubectl get deploy checkout-api -n team-payments \
    -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq
{
  "requests": { "cpu": "1", "memory": "1Gi" },
  "limits":   { "cpu": "2", "memory": "2Gi" }
}
```

The pod requests `1000m` CPU but uses `~400m`. That is **~40% CPU request efficiency** — a textbook over-provisioning finding. Multiply across the fleet with a cluster-capacity tool:

```console
$ kube-capacity --util --sort cpu.util.percent
NODE            CPU REQUESTS   CPU LIMITS    CPU UTIL     MEMORY REQUESTS   MEMORY UTIL
*               186 (77%)      340 (141%)    71 (29%)     412Gi (64%)       206Gi (32%)
ip-10-0-3-14    46  (95%)      92  (191%)    18 (37%)     104Gi (81%)       51Gi  (39%)
ip-10-0-3-88    44  (91%)      80  (166%)    16 (33%)     98Gi  (76%)       48Gi  (37%)
```

Reading this: **77% of CPU is *requested* but only 29% is *used*.** Limits at 141% mean heavy overcommit. This is the number that funds a right-sizing initiative: reclaim ~48% of requested CPU.

### 4.2 Pull VPA recommendations

```console
$ kubectl get vpa checkout-api-vpa -n team-payments \
    -o jsonpath='{.status.recommendation.containerRecommendations[0]}' | jq
{
  "containerName": "checkout-api",
  "lowerBound": { "cpu": "327m",  "memory": "629145600" },
  "target":     { "cpu": "451m",  "memory": "734003200" },
  "uncappedTarget": { "cpu": "451m", "memory": "734003200" },
  "upperBound": { "cpu": "612m",  "memory": "912261120" }
}
```

VPA's `target` says request `451m` / `~700Mi`, not `1000m` / `1Gi`. Applying that reclaims **~55% of the CPU request** for this Deployment alone.

### 4.3 Query DORA metrics directly from Prometheus

```console
$ promtool query instant http://localhost:9090 'dora:deployment_frequency:rate1d'
dora:deployment_frequency:rate1d{team="team-payments", product="checkout"} => 6.2 @[1723046400]
dora:deployment_frequency:rate1d{team="team-search",   product="catalog"}  => 1.1 @[1723046400]

$ promtool query instant http://localhost:9090 'dora:change_failure_rate:ratio1d'
dora:change_failure_rate:ratio1d{team="team-payments", product="checkout"} => 0.048 @[1723046400]
dora:change_failure_rate:ratio1d{team="team-search",   product="catalog"}  => 0.21 @[1723046400]
```

Interpretation: `team-payments` deploys **6.2×/day** (elite) with a **4.8% CFR** (elite). `team-search` deploys **once/day** with a **21% CFR** (below the elite 15% threshold) — the platform team now has a data-driven target: help `team-search` adopt progressive delivery (canary/analysis) to bring CFR down.

### 4.4 Cost attribution from OpenCost

```console
$ kubectl port-forward -n opencost svc/opencost 9003:9003 &
$ curl -s "http://localhost:9003/allocation/compute?window=7d&aggregate=label:team" \
    | jq '.data[0] | to_entries | map({team: .key, cpuCost: .value.cpuCost, ramCost: .value.ramCost, total: .value.totalCost})'
[
  { "team": "team-payments", "cpuCost": 214.55, "ramCost": 88.21, "total": 331.02 },
  { "team": "team-search",   "cpuCost": 402.19, "ramCost": 151.77, "total": 598.44 },
  { "team": "__unallocated__", "cpuCost": 9.11, "ramCost": 3.02, "total": 12.44 }
]
```

`team-search` costs 1.8× `team-payments` while shipping 1/6th the deploys — the **efficiency-vs-value** gap made concrete. `__unallocated__` at $12/wk (< 2%) confirms the Kyverno label enforcement is working (a healthy platform keeps unallocated < 5%).

### 4.5 Verify Goldilocks surfaced the fleet-wide recommendations

```console
$ kubectl get vpa -A -l goldilocks.fairwinds.com/enabled=true \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
TARGET_CPU:.status.recommendation.containerRecommendations[0].target.cpu,\
TARGET_MEM:.status.recommendation.containerRecommendations[0].target.memory
NS              NAME                 TARGET_CPU   TARGET_MEM
team-payments   checkout-api-vpa     451m         734003200
team-payments   ledger-worker-vpa    63m          1310720000
team-search     catalog-api-vpa      120m         402653184
```

---

## 5. Verification and failure-diagnosis guide

### 5.1 Pre-flight: prove the recording rules actually load and evaluate

```console
$ promtool check rules /etc/prometheus/rules/dora-platform-metrics.yaml
Checking /etc/prometheus/rules/dora-platform-metrics.yaml
  SUCCESS: 8 rules found

$ kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | select(.health!="ok") | {name, health, lastError}'
# (empty output = every rule healthy)
```

If a rule shows `"health": "err"`, the most common cause is a **missing input series** — e.g. `argocd_app_sync_total` isn't scraped because the Argo CD `ServiceMonitor` is absent.

### 5.2 Diagnostic decision tree

| Symptom | Likely root cause | Verification command | Fix |
|---|---|---|---|
| `deployment_frequency` is always `0` | Argo CD metrics not scraped | `promtool query instant … 'argocd_app_sync_total'` returns empty | Add a `ServiceMonitor` for `argocd-metrics` and `argocd-application-controller-metrics` |
| DORA metrics exist but **no `team` label** | `argocd_app_info` join failed | `… 'argocd_app_info'` — check the label carrying the team | Ensure `argocd/instance` → team mapping; fix `group_left(team)` join key |
| Cost dashboard shows large `__unallocated__` | Workloads missing `team` label | `kubectl get pods -A -L team \| grep '<none>'` | Turn Kyverno policy from `Audit` → `Enforce`; backfill labels |
| CFR spikes to `1.0` | Div-by-zero when deploy freq is 0 | Inspect `dora:change_failure_rate:ratio1d` denominator | Confirm `clamp_min(…, 1)` guard is present (it is, in §3.5) |
| VPA `status.recommendation` is null | Recommender has no history yet | `kubectl logs -n vpa deploy/vpa-recommender` | Wait ≥ the recommender's warmup (needs ~8+ min of metrics); confirm metrics-server is healthy |
| `kubectl top` returns `error: Metrics API not available` | metrics-server down | `kubectl get apiservice v1beta1.metrics.k8s.io` | Reinstall/repair metrics-server; without it VPA & efficiency metrics are blind |
| Efficiency ratio > 1.0 | Usage exceeds requests (under-provisioned!) | `platform:cpu_request_efficiency:ratio` | This is the *opposite* problem — raise requests; risk of CPU throttling/OOMKill |

### 5.3 The gaming/validity check (SPACE's core warning)

Before you report a metric to leadership, run the **anti-gaming validation**: cross-check each system metric against an orthogonal signal.

```console
# Deployment frequency doubled — real improvement, or teams splitting one release into two?
$ promtool query instant http://localhost:9090 \
    'dora:deployment_frequency:rate1d / dora:change_failure_rate:ratio1d'
```

If deployment frequency rises **while CFR stays flat and lead time drops**, the improvement is real. If frequency rises but **CFR also rises**, you are shipping more, worse — a classic single-metric optimization trap. This is exactly why DORA is reported as a **balanced set**, never as an isolated deploy-frequency number, and why SPACE insists on pairing an activity metric with a satisfaction/quality metric.

### 5.4 Closing the perceptual loop

System metrics cannot detect cognitive load. Verify you have a **perceptual channel** wired up:

```console
$ curl -s http://localhost:7007/api/tech-insights/checks/golden-path-adoption/facts \
    | jq '{onPavedRoad: [.[] | select(.result==true)] | length, total: length, adoptionPct: (([.[] | select(.result==true)] | length) / length * 100 | floor)}'
{ "onPavedRoad": 41, "total": 63, "adoptionPct": 65 }
```

**65% golden-path adoption** is the single most important product-value number a platform team owns: it says nearly two-thirds of services trust the paved road, and names the 22 that don't — your next quarter's backlog. Pair it with a quarterly DevEx survey (self-reported feedback-loop latency, deployment confidence) so the *experiential* half of the CNCF maturity model's "Measurement" aspect is covered, not just the operational half.

---

## 6. References

- CNCF **Cloud Native Platform Engineering Associate (CNPA) Curriculum** — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- CNCF **Platform Engineering Maturity Model** (TAG App Delivery) — https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
- CNCF **Platforms White Paper** (definition of platforms as products) — https://tag-app-delivery.cncf.io/whitepapers/platforms/
- **DORA — DevOps Research and Assessment** (Four Keys, 2024 metric definitions incl. Failed Deployment Recovery Time) — https://dora.dev/guides/dora-metrics-four-keys/
- **The SPACE of Developer Productivity** (Forsgren et al., ACM Queue) — https://queue.acm.org/detail.cfm?id=3454124
- **OpenCost** documentation (CNCF) — https://www.opencost.io/docs/
- **FinOps Foundation — FinOps Framework** — https://www.finops.org/framework/
- Kubernetes **Vertical Pod Autoscaler** — https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
- Kubernetes **Resource Management for Pods and Containers** (requests, limits, LimitRange) — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes **Resource Quotas** — https://kubernetes.io/docs/concepts/policy/resource-quotas/
- Kubernetes **Resize CPU and Memory Resources assigned to Containers** (in-place resize) — https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/
- **Prometheus — Recording Rules** — https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
- **Prometheus Operator — PrometheusRule** — https://prometheus-operator.dev/docs/developer/alerting/
- **kube-state-metrics** — https://github.com/kubernetes/kube-state-metrics
- **Argo CD Metrics** — https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
- **Backstage — Tech Insights / Scorecards** — https://backstage.io/docs/features/tech-insights/
- **Fairwinds Goldilocks** (VPA-driven right-sizing dashboard) — https://goldilocks.docs.fairwinds.com/
- **Team Topologies** (cognitive load, platform as a product, team interaction modes) — https://teamtopologies.com/
- **Google SRE Workbook — Alerting on SLOs** (multi-window burn-rate) — https://sre.google/workbook/alerting-on-slos/