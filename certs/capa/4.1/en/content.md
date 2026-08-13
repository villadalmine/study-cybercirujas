# 4.1 Argo Rollouts — Progressive Delivery for Kubernetes

> CAPA domain weight: **20%**. This section assumes fluency with Deployments, ReplicaSets, Services and the reconciliation model. It targets the depth an SRE needs to run progressive delivery in production, not just to pass a multiple-choice item.

---

## 1. Motivation: why the native Deployment is not a release strategy

A Kubernetes `Deployment` with `strategy.type: RollingUpdate` gives you a *pod-replacement* algorithm, not a *release* algorithm. The distinction is where most production incidents live.

The rolling update loop only knows two things about a new pod: does it pass its `readinessProbe`, and is it `Available`. Both are **liveness-of-the-process** signals. Neither of them can observe:

- the **5xx rate** the new version is returning to real users,
- **p99 latency** regression,
- a **business KPI** (checkout success, ad fill rate) that degraded even though every probe is green,
- errors that only appear **under real traffic mix**, not under a `/healthz` GET.

So the failure mode is classic: the new ReplicaSet reports `Ready 10/10`, the Deployment reports `Available`, and you are now serving 100% of traffic from a build that returns HTTP 500 on the checkout path. The `readinessProbe` was satisfied; the *release* failed. Your MTTR is now bounded by how fast a human notices dashboards and types `kubectl rollout undo`.

Three structural gaps follow from this:

1. **No traffic control.** A Deployment shifts traffic implicitly, as a side effect of Endpoints churn. You cannot say "send 5% of requests to the new version." Weight is a function of replica ratio, and only if your Service happens to load-balance evenly.
2. **No gate.** There is no place to run an automated check *between* "some pods updated" and "all pods updated" and *stop* on a bad signal.
3. **No automated, metric-driven rollback.** `progressDeadlineSeconds` will mark a Deployment `Degraded` if pods never become Available, but a fully-Available bad release sails straight through.

**Progressive delivery** is the practice of closing those gaps: shift traffic in controlled increments, gate each increment on real metrics, and automatically roll back when a Service Level Objective is violated — bounding the *blast radius* (fraction of users exposed to a bad build) and the *MTTR* (time to detect + time to revert), both without a human in the loop.

Argo Rollouts (a CNCF Incubating project, part of the Argo family) implements this as a Kubernetes controller plus a set of CRDs. Ref: <https://argoproj.github.io/argo-rollouts/>.

---

## 2. Architecture and internal mechanics

### 2.1 The CRDs

| CRD | Scope | Role |
|---|---|---|
| `Rollout` | namespaced | Drop-in replacement for `Deployment`. Owns and scales ReplicaSets, drives traffic weight and analysis. |
| `AnalysisTemplate` | namespaced | Reusable definition of metric queries + success/failure conditions. |
| `ClusterAnalysisTemplate` | cluster | Same, shared across namespaces. |
| `AnalysisRun` | namespaced | A running instantiation of a template (like a Job is to a CronJob). Terminal phases: `Successful`, `Failed`, `Inconclusive`, `Error`. |
| `Experiment` | namespaced | Ephemeral run of one or more ReplicaSets for a bounded time, optionally with analysis. Used for A/B and pre-flight tests. |

### 2.2 The reconcile loop

The `Rollout` object embeds a full `PodSpec` in `spec.template`, exactly like a Deployment (or references an existing workload via `spec.workloadRef`). The controller:

1. Hashes the pod template into a `rollouts-pod-template-hash` label and creates/finds the matching ReplicaSet. Each spec change produces a new **revision** (a new ReplicaSet).
2. Designates the currently-serving ReplicaSet as **stable** and the new one as **canary** (or **preview**, for blue-green).
3. Executes the `strategy` — for canary, it walks the ordered `steps` list; for blue-green, it manages the `activeService`/`previewService` cutover.
4. Manipulates **Service label selectors** and/or a **traffic-router object** (Istio `VirtualService`, an Ingress, an `HTTPRoute`, etc.) to move weight.
5. Launches `AnalysisRun`s at the points the strategy dictates and reacts to their terminal phase.
6. Writes `status.phase` (`Progressing` / `Paused` / `Healthy` / `Degraded`), `status.currentStepIndex`, weights, and a `status.message`.

Crucially, the controller **injects the pod-template-hash into the Service selectors it manages**. That is the mechanism behind traffic control without a mesh: the stable Service selects `hash=A`, the canary Service selects `hash=B`, and shifting weight is (in the basic case) shifting the replica ratio behind two otherwise-identical Services.

### 2.3 The two families of strategy

- **`blueGreen`** — two full environments. `previewService` points at the new version; you validate it out-of-band; promotion is an atomic selector swap of `activeService`. Fast rollback, but you pay ~2× replicas during the overlap.
- **`canary`** — one environment, progressively weighted. Fine-grained blast radius, cheaper, but the new version *is* in the serving path from step 1, so it needs metric gating to be safe.

---

## 3. Strategy comparison

| Property | Deployment `Recreate` | Deployment `RollingUpdate` | Rollout `blueGreen` | Rollout `canary` (replica-based) | Rollout `canary` + `trafficRouting` + `analysis` |
|---|---|---|---|---|---|
| Downtime | Yes (full) | No | No | No | No |
| Traffic granularity | n/a | replica ratio, implicit | 0% or 100% (atomic swap) | replica ratio (coarse) | **arbitrary % (mesh/ingress)** |
| Metric-gated promotion | No | No | pre/post-promotion analysis | inline/background analysis | **inline + background** |
| Automated rollback on SLO breach | No | No | Yes | Yes | Yes |
| Extra compute during rollout | ~0 | `maxSurge` | **~2× (both envs live)** | `maxSurge` | canary can be scaled independently (`setCanaryScale`) |
| Rollback speed | slow (redeploy) | slow (redeploy) | **instant (selector swap)** | fast (abort) | fast (abort, weight→0) |
| Requires a traffic router | No | No | No | No | **Yes** (Istio / NGINX / ALB / Gateway API / SMI …) |
| Best for | dev, singletons | stateless, low-risk | risky releases needing full pre-prod validation | cost-sensitive canary | high-traffic services with good telemetry |

**Rule of thumb.** Blue-green when you must fully validate the new stack before *any* user sees it and can afford double capacity. Canary + analysis when you have high, representative traffic and trustworthy SLO metrics, and want the smallest possible blast radius per step.

---

## 4. Canary — complete, production manifests

This is a 10-replica frontend using **Istio** traffic routing, **background analysis** (runs continuously from step 2), and an **inline analysis** gate mid-rollout.

### 4.1 The Rollout

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web-frontend
  namespace: prod
spec:
  replicas: 10
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600          # mark Degraded if a step makes no progress in 10m
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      containers:
        - name: web-frontend
          image: registry.example.com/web-frontend:v1.0.0
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: 500m, memory: 256Mi}
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /healthz, port: http}
            initialDelaySeconds: 10
            periodSeconds: 10
  strategy:
    canary:
      canaryService: web-frontend-canary
      stableService: web-frontend-stable
      trafficRouting:
        istio:
          virtualServices:
            - name: web-frontend-vsvc
              routes:
                - primary
      maxSurge: "25%"
      maxUnavailable: 0
      # Background analysis: starts once step index >= 2 and runs for the whole rollout.
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 2
        args:
          - name: service-name
            value: web-frontend-canary.prod.svc.cluster.local
      steps:
        - setWeight: 5
        - pause: {duration: 2m}
        - setWeight: 20
        - pause: {duration: 5m}
        - analysis:                     # inline gate — blocks until Successful
            templates:
              - templateName: latency-p99
            args:
              - name: service-name
                value: web-frontend-canary.prod.svc.cluster.local
        - setWeight: 50
        - pause: {duration: 5m}
        - setWeight: 80
        - pause: {duration: 2m}
        # implicit final step: setWeight 100, promote canary to stable
```

**Step semantics to internalize:**

- `pause: {}` (no `duration`) pauses **indefinitely** — it needs a manual `promote`. `pause: {duration: 5m}` auto-resumes. Durations accept `s`/`m`/`h`.
- `setWeight: N` asks the traffic router to send N% to canary. Without `trafficRouting`, N is approximated by the replica ratio (rounded up), which is why replica-based canary is coarse.
- An `analysis` step is a **gate**: the rollout is `Paused` (Message `InconclusiveAnalysisRun`/waiting) until the `AnalysisRun` is `Successful`; a `Failed` run **aborts** the rollout.
- `setCanaryScale` (not shown) decouples canary *replica count* from *traffic weight* — e.g. send 5% of traffic but only run 2 canary pods, avoiding over-provisioning. `dynamicStableScale: true` scales the stable RS down as weight moves to canary, so you don't run 2× capacity.

### 4.2 Services and the Istio VirtualService

Both Services are ordinary `ClusterIP`s with the *same* selector; the controller adds the pod-template-hash to differentiate them.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-frontend-stable
  namespace: prod
spec:
  selector:
    app: web-frontend
  ports:
    - {name: http, port: 80, targetPort: http}
---
apiVersion: v1
kind: Service
metadata:
  name: web-frontend-canary
  namespace: prod
spec:
  selector:
    app: web-frontend
  ports:
    - {name: http, port: 80, targetPort: http}
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: web-frontend-vsvc
  namespace: prod
spec:
  hosts:
    - web-frontend.example.com
  gateways:
    - public-gateway
  http:
    - name: primary                      # <-- the route named in trafficRouting.istio
      route:
        - destination:
            host: web-frontend-stable
          weight: 100                     # controller rewrites these two weights
        - destination:
            host: web-frontend-canary
          weight: 0
```

You author `weight: 100 / 0`; the Rollout controller **owns and mutates those numbers** as the steps advance. Do not manage them from Git — that fights the controller (a common Argo CD "OutOfSync" flapping cause; use `ignoreDifferences` on the VirtualService weights).

### 4.3 AnalysisTemplates (Prometheus provider)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: prod
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      count: 5                # 0 = run forever (typical for background analysis)
      successCondition: "result[0] >= 0.99"
      failureLimit: 2         # tolerate 2 bad measurements before failing the run
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            sum(rate(istio_requests_total{
              reporter="destination",
              destination_service=~"{{args.service-name}}",
              response_code!~"5.."}[2m]))
            /
            sum(rate(istio_requests_total{
              reporter="destination",
              destination_service=~"{{args.service-name}}"}[2m]))
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: latency-p99
  namespace: prod
spec:
  args:
    - name: service-name
  metrics:
    - name: latency-p99
      interval: 30s
      count: 4
      successCondition: "result[0] <= 500"   # milliseconds
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.monitoring.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99, sum(rate(
              istio_request_duration_milliseconds_bucket{
                reporter="destination",
                destination_service=~"{{args.service-name}}"}[2m])) by (le))
```

Ref canary: <https://argo-rollouts.readthedocs.io/en/stable/features/canary/>.

---

## 5. Blue-Green — complete manifest

Two Services (`active` serves users, `preview` serves validators), manual promotion gated by a **pre-promotion** smoke test and a **post-promotion** SLO check.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payments-api
  namespace: prod
spec:
  replicas: 6
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      containers:
        - name: payments-api
          image: registry.example.com/payments-api:v2.3.0
          ports:
            - {name: http, containerPort: 8443}
          readinessProbe:
            httpGet: {path: /ready, port: http}
            periodSeconds: 5
  strategy:
    blueGreen:
      activeService: payments-api-active
      previewService: payments-api-preview
      autoPromotionEnabled: false        # require a human/automated promote
      scaleDownDelaySeconds: 30          # keep old RS 30s after cutover for instant rollback
      previewReplicaCount: 2             # optional: run preview cheaper than full active
      prePromotionAnalysis:
        templates:
          - templateName: smoke-test
        args:
          - name: service-name
            value: payments-api-preview.prod.svc.cluster.local
      postPromotionAnalysis:
        templates:
          - templateName: success-rate
        args:
          - name: service-name
            value: payments-api-active.prod.svc.cluster.local
```

Job-based smoke test (the `job` provider runs a Kubernetes Job; exit 0 = success):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: smoke-test
  namespace: prod
spec:
  args:
    - name: service-name
  metrics:
    - name: smoke-test
      provider:
        job:
          spec:
            backoffLimit: 1
            template:
              spec:
                restartPolicy: Never
                containers:
                  - name: smoke
                    image: registry.example.com/smoke-runner:latest
                    command: ["/bin/sh", "-c"]
                    args:
                      - |
                        set -e
                        curl -sf https://{{args.service-name}}:8443/ready
                        curl -sf https://{{args.service-name}}:8443/api/v1/ping
```

**Blue-green lifecycle:** new revision comes up behind `previewService` → `prePromotionAnalysis` runs against preview → on success and a `promote`, the controller **swaps `activeService`'s selector** to the new hash (atomic) → `postPromotionAnalysis` runs against active → after `scaleDownDelaySeconds` the old ReplicaSet scales to 0 (kept warm briefly so an abort is an instant swap-back). Ref: <https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/>.

---

## 6. Analysis subsystem — the part that actually gates releases

### 6.1 Where analysis attaches

| Placement | Field | When it runs | Effect of failure |
|---|---|---|---|
| Inline step | `steps: [{analysis: …}]` (canary) | at that step index | aborts the rollout |
| Background | `strategy.canary.analysis` | continuously from `startingStep`/`startingIndex` | aborts the rollout at any point |
| Pre-promotion | `blueGreen.prePromotionAnalysis` | before active cutover | blocks promotion |
| Post-promotion | `blueGreen.postPromotionAnalysis` | after cutover | rolls back (re-swaps to old) |

### 6.2 Measurement outcome semantics (know these cold)

For each measurement the provider returns `result`, then:

- **Successful**: `successCondition` true (or `failureCondition` false, if only that is set).
- **Failed**: `failureCondition` true, or `successCondition` false.
- **Error**: the provider itself failed — query timeout, unreachable Prometheus, bad PromQL. Errors are tracked separately.
- **Inconclusive**: neither condition matched, or explicitly configured — the run pauses for human judgment.

Run-level limits:

| Field | Default | Meaning |
|---|---|---|
| `failureLimit` | 0 | max **Failed** measurements before the AnalysisRun is `Failed` |
| `inconclusiveLimit` | 0 | max **Inconclusive** measurements before the run is `Inconclusive` |
| `consecutiveErrorLimit` | 4 | max **consecutive Errors** before the run is `Error` |
| `count` | ∞ | total measurements to take (`0`/unset = run until told to stop — used for background) |
| `interval` | — | spacing between measurements (required if `count > 1`) |
| `initialDelay` | 0 | wait before first measurement (let metrics warm up) |

A subtle production trap: with `failureLimit: 0`, a **single** transient bad scrape aborts your rollout. Set `failureLimit` ≥ 1–2 for noisy signals, and prefer conditions over rate windows long enough to be stable (`[2m]`, not `[30s]`).

### 6.3 Provider catalogue

`prometheus`, `datadog`, `newRelic`, `wavefront`, `cloudWatch`, `graphite`, `influxdb`, `skywalking`, `kayenta` (Netflix automated canary analysis), `web` (any HTTP+JSONPath), `job` (arbitrary pass/fail container), and `plugin` (out-of-tree providers). Ref: <https://argo-rollouts.readthedocs.io/en/stable/features/analysis/>.

---

## 7. Traffic-management integrations

`trafficRouting` decides *how* weight is applied. Without it, canary weight is only the replica ratio.

| Integrer | Object it mutates | Weighted split | Header/mirror routing | Notes |
|---|---|---|---|---|
| `istio` | `VirtualService` (+ optional `DestinationRule`) | Yes | Yes (match rules, mirror) | Richest; supports subset-based routing |
| `nginx` | NGINX Ingress (canary annotations) | Yes | Yes (header/cookie) | Creates a shadow canary Ingress |
| `alb` | AWS ALB Ingress (target-group weights) | Yes | Limited | Weight via ALB action |
| `smi` | SMI `TrafficSplit` | Yes | No | Vendor-neutral mesh interface (Linkerd etc.) |
| `plugin` (Gateway API) | `HTTPRoute` | Yes | Yes | The forward-looking, portable option |
| `traefik`, `apisix`, `ambassador`, `contour` | provider CRD | Yes | varies | via plugins |

Choose SMI or the Gateway API plugin for portability; choose Istio if you already run the mesh and need header-based routing or traffic mirroring. Ref: <https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/>.

---

## 8. CLI — `kubectl argo rollouts` with real output

The plugin is the operational surface; `kubectl get rollout -o yaml` alone hides the tree.

```console
$ kubectl argo rollouts version
kubectl-argo-rollouts: v1.7.2+8d73ba7

$ kubectl argo rollouts list rollouts -n prod
NAME          STRATEGY   STATUS        STEP   SET-WEIGHT   READY   DESIRED   UP-TO-DATE   AVAILABLE
web-frontend  Canary     Paused        2/9    5            10/10   10        1            10
payments-api  BlueGreen  Healthy       -      -            6/6     6         6            6
```

Trigger a release by bumping the image (idempotent; re-running with the same tag is a no-op):

```console
$ kubectl argo rollouts set image web-frontend \
    web-frontend=registry.example.com/web-frontend:v1.1.0 -n prod
rollout "web-frontend" image updated
```

Watch the live tree (the primary diagnostic view):

```console
$ kubectl argo rollouts get rollout web-frontend -n prod --watch
Name:            web-frontend
Namespace:       prod
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          1/9
  SetWeight:     5
  ActualWeight:  5
Images:          registry.example.com/web-frontend:v1.0.0 (stable)
                 registry.example.com/web-frontend:v1.1.0 (canary)
Replicas:
  Desired:       10
  Current:       10
  Updated:       1
  Ready:         10
  Available:     10

NAME                                       KIND        STATUS     AGE    INFO
⟳ web-frontend                             Rollout     ॥ Paused   3h     
├──# revision:2                                                          
│  ├──⧉ web-frontend-687d76d795            ReplicaSet  ✔ Healthy  40s    canary
│  │  └──□ web-frontend-687d76d795-fnx2f   Pod         ✔ Running  40s    ready:1/1
│  └──α web-frontend-687d76d795-2          AnalysisRun ◌ Running  38s    ✔ 3
└──# revision:1                                                          
   └──⧉ web-frontend-6cf78c66c5            ReplicaSet  ✔ Healthy  3h     stable
      ├──□ web-frontend-6cf78c66c5-9wf67   Pod         ✔ Running  3h     ready:1/1
      └──□ web-frontend-6cf78c66c5-vg8bl   Pod         ✔ Running  3h     ready:1/1
```

Promote past an indefinite pause / advance one step:

```console
$ kubectl argo rollouts promote web-frontend -n prod
rollout 'web-frontend' promoted

# Skip ALL remaining steps and analysis — go straight to 100% (use with care):
$ kubectl argo rollouts promote web-frontend -n prod --full
rollout 'web-frontend' fully promoted
```

Abort (freezes canary at weight 0, keeps it around) and later retry:

```console
$ kubectl argo rollouts abort web-frontend -n prod
rollout 'web-frontend' aborted

$ kubectl argo rollouts get rollout web-frontend -n prod | head -4
Name:      web-frontend
Namespace: prod
Status:    ✖ Degraded
Message:   RolloutAborted: metric "success-rate" assessed Failed

$ kubectl argo rollouts retry rollout web-frontend -n prod
rollout 'web-frontend' retried
```

Roll back to a prior revision (spec-level rollback; still goes through the strategy):

```console
$ kubectl argo rollouts undo web-frontend -n prod --to-revision=1
rollout 'web-frontend' undo
```

Manual restart (rotate all pods, e.g. to pick up a rotated Secret):

```console
$ kubectl argo rollouts restart web-frontend -n prod
rollout 'web-frontend' restarts in 0s
```

Local UI (read + promote/abort from a browser):

```console
$ kubectl argo rollouts dashboard
Argo Rollouts Dashboard is now available at http://localhost:3100/rollouts
```

Ref: <https://argo-rollouts.readthedocs.io/en/stable/features/kubectl-plugin/>.

---

## 9. Verification and failure diagnosis

### 9.1 The status vocabulary

`status.phase` is your first read:

- **`Progressing`** — actively rolling / scaling.
- **`Paused`** — waiting on a `pause` step, an inline `analysis`, or a manual promote. `status.message` tells you which (`CanaryPauseStep`, `InconclusiveAnalysisRun`, `BlueGreenPause`).
- **`Healthy`** — fully promoted, stable == desired.
- **`Degraded`** — aborted, analysis failed, or `progressDeadlineSeconds` exceeded.

Always pair phase with `.status.message`:

```console
$ kubectl get rollout web-frontend -n prod \
    -o jsonpath='{.status.phase}{"  "}{.status.message}{"\n"}'
Degraded  RolloutAborted: metric "latency-p99" assessed Failed
```

### 9.2 A diagnostic decision tree

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Stuck `Paused`, `Message: CanaryPauseStep` | a `pause: {}` with no duration | `kubectl argo rollouts get rollout` shows current step | `promote` it (or add a `duration`) |
| Stuck `Paused`, `Message: InconclusiveAnalysisRun` | analysis returned Inconclusive | `kubectl get analysisrun -n prod` then `-o yaml` | inspect `status.metricResults`, resume or fix query |
| `Degraded`, `ProgressDeadlineExceeded` | new pods never became Available in time | `kubectl describe rollout`; check pod events | fix image/probe/resources; raise `progressDeadlineSeconds` |
| `Degraded`, `metric … assessed Failed` | SLO breach in analysis | `kubectl argo rollouts get analysisrun <name>` shows per-measurement values | fix the app, `retry`, or `undo` |
| Traffic never shifts (weight stays 0 effect) | `trafficRouting` object/route name mismatch | `kubectl describe rollout` events: `route "primary" not found` | align VirtualService route name with `routes:` |
| Both stable & canary get 50/50 unexpectedly | Services share a selector *without* pod-template-hash injection (bad selector) | check Service `.spec.selector` includes controller-added hash | let the controller manage selectors; don't hard-code the hash |
| Analysis errors immediately | Prometheus unreachable / bad PromQL | AnalysisRun `phase: Error`, `message` has the HTTP/parse error | fix `provider.prometheus.address`, test the query in Prometheus first |
| Argo CD keeps showing VirtualService `OutOfSync` | controller rewrites weights Git can't match | `argocd app diff` shows only `weight` fields | add `ignoreDifferences` on the weight paths |

### 9.3 Inspecting an AnalysisRun

```console
$ kubectl get analysisrun -n prod
NAME                       STATUS    AGE
web-frontend-687d76d795-2  Failed    4m

$ kubectl argo rollouts get analysisrun web-frontend-687d76d795-2 -n prod
Name:            web-frontend-687d76d795-2
Namespace:       prod
Status:          ✖ Failed
Message:         metric "latency-p99" assessed Failed due to failed (2) > failureLimit (1)

METRIC       STATUS   INFO
latency-p99  ✖ Failed 
  ✔ 620      Measurement    Value  Phase
  ✖ 940                     620    Failed
  ✖ 1180                    940    Failed
```

### 9.4 Controller-level checks

```console
# Is the controller healthy?
$ kubectl -n argo-rollouts get deploy argo-rollouts
NAME            READY   UP-TO-DATE   AVAILABLE   AGE
argo-rollouts   1/1     1            1           21d

# What is it actually doing / erroring on?
$ kubectl -n argo-rollouts logs deploy/argo-rollouts --tail=50 | grep -iE 'error|abort|analysis'
```

### 9.5 Pre-flight checklist before your first canary

1. Both `canaryService` and `stableService` exist and are `ClusterIP` with the same base selector.
2. The `trafficRouting` object exists and the route name matches (`routes: [primary]` ↔ VirtualService `http[].name: primary`).
3. Every referenced `AnalysisTemplate`/`ClusterAnalysisTemplate` exists in scope and its `args` are all supplied by the Rollout.
4. The metric query returns a value **now**, for the *stable* version — run it in Prometheus first. A query that returns empty on a healthy service will fail every canary.
5. `progressDeadlineSeconds` > (max `pause` duration + analysis time), or the deadline will fire mid-rollout.
6. If under Argo CD, `ignoreDifferences` covers the traffic-router weight fields.

---

## 10. References

- Argo Rollouts — official documentation (stable): <https://argo-rollouts.readthedocs.io/en/stable/>
- Argo Rollouts — project site: <https://argoproj.github.io/argo-rollouts/>
- Source repository: <https://github.com/argoproj/argo-rollouts>
- Canary strategy: <https://argo-rollouts.readthedocs.io/en/stable/features/canary/>
- Blue-Green strategy: <https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/>
- Analysis, AnalysisTemplate & metrics: <https://argo-rollouts.readthedocs.io/en/stable/features/analysis/>
- Traffic management overview: <https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/>
- kubectl plugin reference: <https://argo-rollouts.readthedocs.io/en/stable/features/kubectl-plugin/>
- Specification / full field reference: <https://argo-rollouts.readthedocs.io/en/stable/features/specification/>
- Best practices: <https://argo-rollouts.readthedocs.io/en/stable/best-practices/>
- CAPA certification (curriculum & exam): <https://www.cncf.io/training/certification/capa/>
- CNCF curriculum repository (CAPA README): <https://github.com/cncf/curriculum>