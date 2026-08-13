# CAPA — Domain 4.1: Argo Rollouts — Guided Exercises

> **Prerequisites**: a working Kubernetes cluster (kind, k3d, minikube, or a real cluster) with `kubectl` context set, and cluster-admin on it. You install the controller and the plugin in Exercise 0. Every manifest here is complete and syntactically valid — apply them verbatim.
>
> **Reference sources** (official):
> - CAPA curriculum — https://raw.githubusercontent.com/cncf/curriculum/master/capa/README.md
> - Argo Rollouts docs — https://argo-rollouts.readthedocs.io/en/stable/
> - Kubectl plugin reference — https://argo-rollouts.readthedocs.io/en/stable/features/kubectl-plugin/
> - Rollout spec — https://argo-rollouts.readthedocs.io/en/stable/features/specification/
> - Analysis — https://argo-rollouts.readthedocs.io/en/stable/features/analysis/

---

## Exercise 0 — Install the controller and the CLI plugin

**Steps**

1. Create the dedicated namespace and install the controller (stable channel):

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   ```

2. Wait for the controller to become ready and confirm the CRDs landed:

   ```bash
   kubectl -n argo-rollouts rollout status deployment/argo-rollouts
   kubectl get crd | grep argoproj.io
   ```

   Expected (abridged):

   ```
   deployment "argo-rollouts" successfully rolled out
   analysisruns.argoproj.io          2026-08-12T...
   analysistemplates.argoproj.io     2026-08-12T...
   clusteranalysistemplates.argoproj.io  2026-08-12T...
   experiments.argoproj.io           2026-08-12T...
   rollouts.argoproj.io              2026-08-12T...
   ```

3. Install the kubectl plugin (Linux amd64 shown — adjust for your arch):

   ```bash
   curl -sSL -o kubectl-argo-rollouts \
     https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
   chmod +x kubectl-argo-rollouts
   sudo mv kubectl-argo-rollouts /usr/local/bin/
   kubectl argo rollouts version
   ```

   Expected:

   ```
   kubectl-argo-rollouts: v1.7.2+<hash>
     BuildDate: 2026-...
     GoVersion: go1.22...
     Compiler: gc
     Platform: linux/amd64
   ```

**Comprehension check**

- Q0.1 — The controller ships **five** CRDs. Name each one and, in one line, what it manages.
- Q0.2 — Is the `kubectl argo rollouts` plugin required for the controller to reconcile Rollouts? What does it actually do?

---

## Exercise 1 — A basic canary Rollout and its ReplicaSet mechanics

**Steps**

1. Create a canary `Rollout` plus its `Service`. Save as `rollout-canary.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-demo
   spec:
     replicas: 5
     revisionHistoryLimit: 2
     selector:
       matchLabels:
         app: rollouts-demo
     template:
       metadata:
         labels:
           app: rollouts-demo
       spec:
         containers:
         - name: rollouts-demo
           image: argoproj/rollouts-demo:blue
           ports:
           - containerPort: 8080
           resources:
             requests:
               memory: 32Mi
               cpu: 5m
     strategy:
       canary:
         steps:
         - setWeight: 20
         - pause: {}
         - setWeight: 40
         - pause: {duration: 30s}
         - setWeight: 60
         - pause: {duration: 30s}
         - setWeight: 80
         - pause: {duration: 30s}
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: rollouts-demo
   spec:
     ports:
     - port: 80
       targetPort: 8080
       protocol: TCP
       name: http
     selector:
       app: rollouts-demo
   ```

2. Apply it, then inspect the live state with the plugin:

   ```bash
   kubectl apply -f rollout-canary.yaml
   kubectl argo rollouts get rollout rollouts-demo
   ```

   On the **first** apply the Rollout does **not** run the canary steps — it comes up fully healthy at revision 1:

   ```
   Name:            rollouts-demo
   Namespace:       default
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          8/8
     SetWeight:     100
     ActualWeight:  100
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas:
     Desired:       5
     Current:       5
     Updated:       5
     Ready:         5
     Available:     5
   ```

3. Now trigger an actual rollout by changing the image. Use the plugin's `set image` helper:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```

   It advances to step 1 (`setWeight: 20`) and **stops at the indefinite pause** (`pause: {}`):

   ```
   Name:            rollouts-demo
   Status:          ॥ Paused
   Message:         CanaryPauseStep
   Strategy:        Canary
     Step:          1/8
     SetWeight:     20
     ActualWeight:  20
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:yellow (canary)
   Replicas:
     Desired:       5
     Current:       5
     Updated:       1
     Ready:         5
     Available:     5

   NAME                                       KIND        STATUS     AGE  INFO
   ⟳ rollouts-demo                            Rollout     ॥ Paused   9m
   ├──# revision:2
   │  └──⧉ rollouts-demo-687d76d795           ReplicaSet  ✔ Healthy  40s  canary
   │     └──□ rollouts-demo-687d76d795-9wpqf  Pod         ✔ Running  40s  ready:1/1
   └──# revision:1
      └──⧉ rollouts-demo-6cf78c96c5           ReplicaSet  ✔ Healthy  9m   stable
         ├──□ rollouts-demo-6cf78c96c5-8mggv  Pod         ✔ Running  9m   ready:1/1
         └── ...(4 more)
   ```

4. Promote past the manual pause and let the timed steps run to completion:

   ```bash
   kubectl argo rollouts promote rollouts-demo
   kubectl argo rollouts get rollout rollouts-demo --watch
   ```

**Comprehension check**

- Q1.1 — Why did the first `kubectl apply` land at `Step 8/8 / SetWeight 100` instead of starting at step 1 with weight 20%?
- Q1.2 — At `setWeight: 20` with `replicas: 5`, the plugin showed `Updated: 1`. Derive that number. What rounding rule does the canary replica math use, and which field would let the canary receive 20% of *traffic* without 20% of the *pods*?
- Q1.3 — Distinguish `pause: {}` from `pause: {duration: 30s}`. Which one blocks until `promote`, and what does `Message: CanaryPauseStep` tell you?
- Q1.4 — During the pause, two ReplicaSets are `Healthy`. How does the controller keep the stable `Service` from sending traffic to the canary Pods when there is *no* traffic-router configured? (Hint: think about what label the controller injects into the selector.)

---

## Exercise 2 — Abort, promote-full, and rollback

**Steps**

1. Start a new rollout and let it pause at step 1 again:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:red
   kubectl argo rollouts get rollout rollouts-demo
   ```

2. Simulate "the canary looks bad" — **abort** it:

   ```bash
   kubectl argo rollouts abort rollouts-demo
   kubectl argo rollouts get rollout rollouts-demo
   ```

   Expected — the Rollout is `Degraded`, the canary ReplicaSet is scaled to zero, and 100% of traffic is back on stable:

   ```
   Status:          ✖ Degraded
   Message:         RolloutAborted: Rollout aborted update to revision 3
     Step:          0/8
     SetWeight:     0
     ActualWeight:  0
   Images:          argoproj/rollouts-demo:yellow (stable)
   ```

3. Recover. Because `abort` leaves the *spec* pointing at the aborted image, re-apply the stable image (or promote) to clear the aborted state, then observe it heal:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout rollouts-demo
   ```

4. Now do the opposite of a slow rollout — skip all remaining steps with a **full promotion**:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:green
   kubectl argo rollouts promote rollouts-demo --full
   kubectl argo rollouts get rollout rollouts-demo
   ```

5. Roll back to the previous revision with the plugin's `undo`:

   ```bash
   kubectl argo rollouts undo rollouts-demo
   # or to a specific revision:
   # kubectl argo rollouts undo rollouts-demo --to-revision=2
   ```

**Comprehension check**

- Q2.1 — After `abort`, `Status` was `Degraded`, not `Healthy`. Why does aborting a canary produce a *Degraded* condition even though the stable version is serving 100% of traffic correctly?
- Q2.2 — In step 2 the output showed `Images: argoproj/rollouts-demo:yellow (stable)`. Why is *yellow* still the stable image after we tried to roll out *red*?
- Q2.3 — Contrast `promote` vs `promote --full` vs `undo`. Which of these change `.spec.template`, and which only change controller-side progress state?
- Q2.4 — `undo` creates a *new* revision rather than reactivating the old ReplicaSet's revision number. Why does that matter for `revisionHistoryLimit` and for reproducibility?

---

## Exercise 3 — Blue-Green strategy with a preview service

**Steps**

1. Deploy a Blue-Green Rollout with distinct active and preview Services. Save as `rollout-bluegreen.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollout-bluegreen
   spec:
     replicas: 2
     revisionHistoryLimit: 2
     selector:
       matchLabels:
         app: rollout-bluegreen
     template:
       metadata:
         labels:
           app: rollout-bluegreen
       spec:
         containers:
         - name: rollouts-demo
           image: argoproj/rollouts-demo:blue
           ports:
           - containerPort: 8080
           resources:
             requests:
               memory: 32Mi
               cpu: 5m
     strategy:
       blueGreen:
         activeService: rollout-bluegreen-active
         previewService: rollout-bluegreen-preview
         autoPromotionEnabled: false
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: rollout-bluegreen-active
   spec:
     ports:
     - port: 80
       targetPort: 8080
       protocol: TCP
       name: http
     selector:
       app: rollout-bluegreen
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: rollout-bluegreen-preview
   spec:
     ports:
     - port: 80
       targetPort: 8080
       protocol: TCP
       name: http
     selector:
       app: rollout-bluegreen
   ```

2. Apply it and confirm both Services select the same Pods on revision 1:

   ```bash
   kubectl apply -f rollout-bluegreen.yaml
   kubectl get svc rollout-bluegreen-active rollout-bluegreen-preview -o wide
   kubectl get endpoints rollout-bluegreen-active rollout-bluegreen-preview
   ```

3. Trigger a new revision and watch the preview service diverge from active:

   ```bash
   kubectl argo rollouts set image rollout-bluegreen \
     rollouts-demo=argoproj/rollouts-demo:green
   kubectl argo rollouts get rollout rollout-bluegreen
   ```

   Expected — a full second stack is stood up, `active` still points at blue, `preview` at green, and the Rollout is **Paused** waiting for promotion:

   ```
   Status:          ॥ Paused
   Message:         BlueGreenPause
   Strategy:        BlueGreen
   Images:          argoproj/rollouts-demo:blue (stable, active)
                    argoproj/rollouts-demo:green (preview)
   Replicas:
     Desired:       2
     Current:       4
     Updated:       2
     Ready:         2
     Available:     2
   ```

4. Verify the routing split by inspecting the injected selector hash:

   ```bash
   kubectl get svc rollout-bluegreen-active   -o jsonpath='{.spec.selector}'; echo
   kubectl get svc rollout-bluegreen-preview  -o jsonpath='{.spec.selector}'; echo
   ```

   You will see the controller has appended `rollouts-pod-template-hash` to each selector, and the two hashes differ.

5. Promote and confirm the active Service cuts over atomically:

   ```bash
   kubectl argo rollouts promote rollout-bluegreen
   kubectl argo rollouts get rollout rollout-bluegreen
   ```

**Comprehension check**

- Q3.1 — In step 3, `Current: 4` while `Desired: 2`. Explain the resource cost of Blue-Green versus canary, and what `scaleDownDelaySeconds` controls after promotion.
- Q3.2 — Both Services were authored with the *same* `selector: app: rollout-bluegreen`, yet after a rollout they route to different Pods. What mechanism makes that work, and why must you **not** hand-manage the `rollouts-pod-template-hash` label?
- Q3.3 — With `autoPromotionEnabled: false`, what event promotes the preview to active? What changes if you set `autoPromotionEnabled: true` with `autoPromotionSeconds: 30`?
- Q3.4 — Give one production scenario where Blue-Green is the right choice over canary, and one where it is clearly the wrong choice.

---

## Exercise 4 — Automated canary analysis with an AnalysisTemplate

> This exercise wires metric-driven promotion. It uses a Prometheus provider in the manifest; if you have no Prometheus, read through it and substitute the `job` provider variant shown in step 4 to run it hands-on.

**Steps**

1. Define a reusable `AnalysisTemplate` measuring success rate. Save as `analysis-success-rate.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: success-rate
   spec:
     args:
     - name: service-name
     metrics:
     - name: success-rate
       interval: 30s
       count: 5
       successCondition: result[0] >= 0.95
       failureLimit: 3
       provider:
         prometheus:
           address: http://prometheus.monitoring.svc:9090
           query: |
             sum(irate(
               http_requests_total{service="{{args.service-name}}",code!~"5.."}[2m]
             )) /
             sum(irate(
               http_requests_total{service="{{args.service-name}}"}[2m]
             ))
   ```

2. Wire it into the canary strategy of `rollouts-demo` as a **background** analysis that starts at step 2. Patch the strategy:

   ```yaml
   strategy:
     canary:
       analysis:
         templates:
         - templateName: success-rate
         startingStep: 2
         args:
         - name: service-name
           value: rollouts-demo
       steps:
       - setWeight: 20
       - pause: {duration: 60s}
       - setWeight: 50
       - pause: {duration: 60s}
       - setWeight: 100
   ```

3. Apply and trigger a rollout. The controller now spawns an `AnalysisRun` alongside the canary:

   ```bash
   kubectl apply -f analysis-success-rate.yaml
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:purple
   kubectl argo rollouts get rollout rollouts-demo
   kubectl get analysisrun
   ```

   Expected AnalysisRun listing while measuring:

   ```
   NAME                                 STATUS      AGE
   rollouts-demo-687d76d795-2-1         Running     45s
   ```

4. Inspect the AnalysisRun detail to see measurements accumulate:

   ```bash
   kubectl get analysisrun rollouts-demo-687d76d795-2-1 -o yaml | \
     yq '.status.metricResults'
   ```

   Expected (abridged) — measurements with `phase` and `value`:

   ```
   - name: success-rate
     phase: Running
     successful: 3
     count: 3
     measurements:
     - value: "0.997"
       phase: Successful
       startedAt: "2026-08-12T..."
     - value: "0.991"
       phase: Successful
   ```

5. Force a failure to see the automated abort. Add an **inline** analysis step that must fail, using the deterministic `job` provider (no Prometheus needed). Insert this as a step:

   ```yaml
   - analysis:
       templates:
       - templateName: always-fail
   ```

   with:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: AnalysisTemplate
   metadata:
     name: always-fail
   spec:
     metrics:
     - name: fail-check
       provider:
         job:
           spec:
             backoffLimit: 0
             template:
               spec:
                 restartPolicy: Never
                 containers:
                 - name: fail
                   image: busybox:1.36
                   command: ["sh", "-c", "exit 1"]
   ```

   Trigger a rollout that reaches that step; the AnalysisRun goes `Failed` and the Rollout auto-aborts:

   ```
   Status:  ✖ Degraded
   Message: RolloutAborted: Rollout aborted update to revision N (analysis failed)
   ```

**Comprehension check**

- Q4.1 — Differentiate a **background** analysis (`strategy.canary.analysis`) from an **inline / step** analysis (a `- analysis:` step). When does each start, when does each end, and which one gates a specific `setWeight`?
- Q4.2 — In the template, `successCondition: result[0] >= 0.95`, `failureLimit: 3`, `count: 5`, `interval: 30s`. Walk through exactly when the AnalysisRun is declared `Successful` vs `Failed` vs `Inconclusive`. What is the difference between `failureLimit` and `inconclusiveLimit`?
- Q4.3 — What happens to the in-flight Rollout the moment its associated AnalysisRun reports `Failed`? Contrast that with `Inconclusive`.
- Q4.4 — `{{args.service-name}}` is templated. Why are `AnalysisTemplate` args the correct place to parameterize the query, rather than hard-coding the service into the template?
- Q4.5 — Name the metric providers Argo Rollouts ships and give one reason you'd pick the `job` provider over `prometheus` in a portable CAPA-lab context.

---

## Exercise 5 — Traffic management: weighted routing beyond replica counts

> Requires a supported traffic router. SMI (`smi`) with a lightweight mesh, or the NGINX ingress variant, are common CAPA-lab choices. The manifest below shows the **NGINX** integration; adapt `stableService` / `canaryService` / `trafficRouting` to your installed router.

**Steps**

1. Define the two Services and the ingress the router will manipulate, plus a Rollout that declares `trafficRouting`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-tm
   spec:
     replicas: 4
     strategy:
       canary:
         canaryService: rollouts-tm-canary
         stableService: rollouts-tm-stable
         trafficRouting:
           nginx:
             stableIngress: rollouts-tm-stable
         steps:
         - setWeight: 5
         - pause: {duration: 60s}
         - setWeight: 25
         - pause: {duration: 60s}
         - setWeight: 50
         - pause: {duration: 60s}
     selector:
       matchLabels:
         app: rollouts-tm
     template:
       metadata:
         labels:
           app: rollouts-tm
       spec:
         containers:
         - name: rollouts-tm
           image: argoproj/rollouts-demo:blue
           ports:
           - containerPort: 8080
   ```

2. Trigger a rollout and observe that with only 4 replicas the canary still receives **5%** of traffic:

   ```bash
   kubectl argo rollouts set image rollouts-tm \
     rollouts-tm=argoproj/rollouts-demo:orange
   kubectl argo rollouts get rollout rollouts-tm
   ```

   Expected — note `SetWeight: 5` with just one updated Pod, and the plugin now shows a distinct `ActualWeight` sourced from the router, not the replica ratio:

   ```
   Status:          ॥ Paused
     Step:          1/6
     SetWeight:     5
     ActualWeight:  5
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:orange (canary)
   ```

3. Confirm the router created the canary ingress with the weight annotation:

   ```bash
   kubectl get ingress rollouts-tm-stable-rollouts-tm-canary -o yaml | \
     grep -A2 'nginx.ingress.kubernetes.io/canary'
   ```

   Expected:

   ```
   nginx.ingress.kubernetes.io/canary: "true"
   nginx.ingress.kubernetes.io/canary-weight: "5"
   ```

**Comprehension check**

- Q5.1 — Without `trafficRouting`, a 5% weight is impossible with 4 replicas (minimum granularity is 25%). Explain *how* a traffic router decouples traffic percentage from Pod count, and what `ActualWeight` now measures.
- Q5.2 — The canary strategy suddenly needs **two** Services (`canaryService`, `stableService`) instead of one. What does the controller do to each Service's selector, and why is that required for weighted routing to work?
- Q5.3 — Name three supported traffic routers and the objects each one manipulates (ingress annotations vs mesh CRDs). What is `setCanaryScale` and when would you use it with a router?
- Q5.4 — What does `dynamicStableScale: true` change about how the stable ReplicaSet is scaled during a routed rollout, and what is the failure risk if you enable it without a working router?

---

## Exercise 6 — Diagnostics and lifecycle control

**Steps**

1. Get a compact status suitable for scripting/CI gates:

   ```bash
   kubectl argo rollouts status rollouts-demo
   # blocks and returns non-zero on failure; use --timeout for CI:
   kubectl argo rollouts status rollouts-demo --timeout 300s ; echo "exit=$?"
   ```

   Expected on a paused rollout:

   ```
   ॥ Paused - CanaryPauseStep
   ```

2. Read controller-side events and conditions when something is stuck:

   ```bash
   kubectl describe rollout rollouts-demo | sed -n '/Conditions/,/Events/p'
   kubectl get rollout rollouts-demo -o jsonpath='{.status.conditions}' | yq -P -
   ```

3. Restart all Pods (rotate certs/secrets) *without* a new revision:

   ```bash
   kubectl argo rollouts restart rollouts-demo
   ```

4. Retry an aborted rollout, and pause/resume manually:

   ```bash
   kubectl argo rollouts retry rollout rollouts-demo
   kubectl argo rollouts pause rollouts-demo
   kubectl argo rollouts promote rollouts-demo
   ```

5. Optional live dashboard:

   ```bash
   kubectl argo rollouts dashboard   # serves the UI at http://localhost:3100
   ```

**Comprehension check**

- Q6.1 — Distinguish `restart` from `set image ...:same-tag`. Which creates a new revision, and which reuses the current template hash? Which one would you run to force Pods to reload a rotated Secret?
- Q6.2 — `kubectl argo rollouts status` returns a non-zero exit code on failure. Why is that specifically valuable in a GitOps / CI pipeline gate, and how does `--timeout` interact with a rollout that is legitimately paused on a manual step?
- Q6.3 — You see `Status: Progressing` stuck for a long time and eventually `Degraded` with reason `ProgressDeadlineExceeded`. Which field controls that deadline, and what are the top two root causes to check first?
- Q6.4 — Which two `.status` conditions on a Rollout does an external controller (e.g. Argo CD health) read to decide the object is Healthy vs Degraded vs Progressing?

---

## Answers

<details>
<summary>Click to reveal answers for all six exercises</summary>

### Exercise 0

- **A0.1** — `Rollout` (a Deployment-like workload with progressive-delivery strategies); `AnalysisTemplate` (a reusable, namespaced definition of metrics + success/failure conditions); `ClusterAnalysisTemplate` (the same, cluster-scoped, shareable across namespaces); `AnalysisRun` (an instantiated, running measurement, spawned from a template — the "job" of analysis); `Experiment` (runs one or more ReplicaSets for a bounded time to compare versions, often with analysis, without shifting production traffic).
- **A0.2** — No. The controller reconciles Rollouts purely from the CRDs; it needs nothing client-side. The `kubectl argo rollouts` plugin is a convenience/observability client: it renders the rich tree view (`get`), computes and prints `ActualWeight`, and offers imperative helpers (`set image`, `promote`, `abort`, `retry`, `undo`, `restart`, `status`, `dashboard`). Everything the plugin does you can also do by editing the Rollout spec or patching `.status`-adjacent fields, but the plugin is the ergonomic path.

### Exercise 1

- **A1.1** — The canary steps are only executed on an **update** to an existing, healthy Rollout. The **initial** creation has no "stable" version to canary against, so the controller brings the workload straight to 100% (fully rolled out at the final step). Canarying begins the first time `.spec.template` changes.
- **A1.2** — `replicas: 5 × 20% = 1.0` → 1 canary Pod. The canary replica count is `ceil(weight × replicas)` for the canary side and the stable side scales to cover the rest, so weights that don't divide evenly round **up** for the canary (never 0 when weight > 0). To give the canary 20% of *traffic* while keeping pod counts coarse, you need `trafficRouting` (Exercise 5) — with a router the traffic weight is set at the proxy/ingress and is independent of the replica ratio.
- **A1.3** — `pause: {}` is an **indefinite** pause: it blocks until a human/automation runs `kubectl argo rollouts promote` (or sets `.spec.paused`/clears the pause condition). `pause: {duration: 30s}` auto-resumes after the timer. `Message: CanaryPauseStep` tells you the Rollout is deliberately halted *by a step in the canary plan*, i.e. this is expected progressive-delivery behavior, not a fault.
- **A1.4** — With no traffic router, Argo Rollouts controls traffic purely by **Service selector**. The controller injects the label `rollouts-pod-template-hash` into the Pods and — for a basic canary without `canaryService`/`stableService` — keeps the single `Service` pointed at the **stable** ReplicaSet's hash, so the canary Pods, though `Ready`, are not in the Service's Endpoints. That's also why basic canary granularity equals the replica granularity: traffic follows pod membership, not a weight.

### Exercise 2

- **A2.1** — `Degraded` here means "the desired update did not reach a healthy, fully-promoted state" — the update to revision 3 was aborted, so the Rollout is not at its declared target. It's a statement about the *rollout's* progress, not about whether requests are currently succeeding. Traffic is safely on stable, but the object is still flagged `Degraded` until you resolve the spec (promote a good version or roll the spec back), which clears the aborted condition.
- **A2.2** — Because *red* was aborted before it was ever promoted. The last version that successfully completed its rollout was *yellow*, so *yellow* remains the stable image and serves 100%. Abort scales the canary (red) to zero without changing which ReplicaSet is stable.
- **A2.3** — `promote` advances past the *current* pause/step (and lets analysis continue); `promote --full` **skips all remaining steps and analysis** and jumps to 100%; `undo` reverts `.spec.template` to a prior revision (creating a new forward revision). `undo` changes `.spec.template`. `promote`/`promote --full` do **not** change the template — they manipulate controller-side progress (which step, whether to skip). This is why `undo` is a real deploy and `promote` is just steering the in-flight one.
- **A2.4** — `undo` re-applies the old PodSpec as a **new** revision going forward, so history is append-only and auditable — you can always see "at time T we rolled back to the content of revision 2." That new revision counts against `revisionHistoryLimit` (old ReplicaSets beyond the limit are garbage-collected). For reproducibility it means the meta/provenance of *which* template is running is always the latest revision, never an ambiguous "we resurrected an old number."

### Exercise 3

- **A3.1** — Blue-Green runs the **entire** new stack in parallel with the old one before cutover, so peak replica usage is ~2× (`Current: 4` for `Desired: 2`). Canary only runs *incremental* extra Pods (a fraction), so it's far cheaper on resources but exposes users to the new version gradually. `scaleDownDelaySeconds` (default 30) is how long the **old** ReplicaSet is kept running *after* promotion before being scaled down — a safety window enabling instant rollback and draining of in-flight connections.
- **A3.2** — The controller appends the immutable `rollouts-pod-template-hash` to each managed Service's selector at reconcile time, pinning `active` to one ReplicaSet's hash and `preview` to the other's. You author only `app: rollout-bluegreen`; the hash is controller-owned. If you hand-edit that label you fight the controller — it will overwrite it, and in the meantime you can split-brain the routing (both services hitting the same or wrong Pods).
- **A3.3** — With `autoPromotionEnabled: false`, promotion happens only on an explicit `kubectl argo rollouts promote` (or clearing the pause). With `autoPromotionEnabled: true` + `autoPromotionSeconds: 30`, the controller waits 30 s after the preview stack is fully available, then promotes automatically — a bounded "bake time" with no human in the loop.
- **A3.4** — Right choice: a stateful/single-writer app or one that cannot tolerate two versions serving simultaneously (e.g. an incompatible schema/protocol change), where you want an atomic all-or-nothing cutover and instant rollback. Wrong choice: a large fleet where doubling replicas is prohibitively expensive, or where you specifically *want* to limit blast radius by exposing only 1–5% of users first — that's canary's job.

### Exercise 4

- **A4.1** — A **background** analysis (`strategy.canary.analysis`, optionally with `startingStep`) begins at the specified step and runs *concurrently* alongside the whole remaining rollout; it can abort the rollout at any point if it fails, but it does not by itself hold a particular `setWeight`. An **inline/step** analysis (a `- analysis:` step) is a discrete step: the rollout **blocks at that step** until the AnalysisRun finishes, and only advances if it succeeds — so it gates the specific weight that precedes it.
- **A4.2** — Every `interval` (30 s) a measurement is taken, up to `count: 5` total. Each measurement is `Successful` if `successCondition` holds, else `Failed` (or `Inconclusive` if only `inconclusiveLimit` logic applies). The AnalysisRun is declared **Failed** as soon as the number of failed measurements exceeds `failureLimit: 3`; it is **Successful** if it completes all `count` measurements without exceeding `failureLimit`; it is **Inconclusive** if inconclusive measurements exceed `inconclusiveLimit`. `failureLimit` = how many outright-failing measurements are tolerated before aborting; `inconclusiveLimit` = how many "can't decide" measurements (e.g. condition returned neither pass nor a clear fail, or `inconclusiveCondition` matched) are tolerated — inconclusive **pauses** for human judgment rather than auto-aborting.
- **A4.3** — On `Failed`, the controller **auto-aborts** the rollout immediately: canary scales to zero, traffic returns to stable, `Status: Degraded` with reason "analysis failed." On `Inconclusive`, the rollout is **paused** (not aborted) awaiting manual `promote` or `abort` — the system is saying "I couldn't decide; you decide."
- **A4.4** — Templating via `args` keeps the `AnalysisTemplate` **reusable** across many Rollouts/services. The same `success-rate` template is applied to `rollouts-demo`, `payments`, `search`, etc., each passing its own `service-name`. Hard-coding the service would force a copy of the template per workload, defeating the point of a shared, centrally-maintained SLO check.
- **A4.5** — Providers include `prometheus`, `datadog`, `newrelic`, `wavefront`, `graphite`, `influxdb`, `cloudwatch`, `kayenta`, `web` (arbitrary HTTP/JSON), and `job` (run a Kubernetes Job; success = Job succeeds). In a portable CAPA lab the `job` provider needs no external monitoring stack and is fully deterministic — ideal for demonstrating pass/fail analysis mechanics without standing up Prometheus.

### Exercise 5

- **A5.1** — A traffic router (ingress controller or service mesh) sets a **weight at the proxy layer** (e.g. NGINX `canary-weight`, an SMI `TrafficSplit`, or Istio `VirtualService` route weights). Requests are split by the proxy according to that number, regardless of how many Pods back each Service — so 5% is achievable with a single canary Pod out of four. With a router, `ActualWeight` reflects the *routing weight the controller has programmed into the router*, not the pod ratio.
- **A5.2** — Weighted routing needs two stable targets to shift between, so you declare `stableService` and `canaryService`. The controller pins each Service's selector to a specific `rollouts-pod-template-hash` — `stableService` to the stable ReplicaSet, `canaryService` to the canary ReplicaSet — so the router can address each version by a distinct, stable Service/endpoint set and blend traffic between them.
- **A5.3** — Examples: **NGINX ingress** (manipulates a canary `Ingress` via `nginx.ingress.kubernetes.io/canary*` annotations); **AWS ALB** (edits the ALB `Ingress`/target-group weights); **Istio** (edits `VirtualService`/`DestinationRule` route weights); **SMI** (`TrafficSplit` CRD); also Traefik, Apisix, Gateway API, etc. `setCanaryScale` lets you decouple the *canary replica count* from the *traffic weight* — e.g. keep the canary at a fixed small replica count while the router sends more/less traffic, or pre-scale it before shifting traffic. Useful to avoid over/under-provisioning the canary relative to the weight the router is serving.
- **A5.4** — `dynamicStableScale: true` scales the **stable** ReplicaSet down in proportion to the traffic already moved to the canary (instead of keeping stable at full size for the whole rollout), saving resources. The risk: if the router isn't actually shifting traffic (misconfigured/unhealthy router) while stable has been scaled down, you can under-provision the version still receiving most requests — capacity loss / outage. It's only safe when the router is verified working.

### Exercise 6

- **A6.1** — `restart` rotates Pods **in place** reusing the current template hash — **no new revision** — respecting the strategy's surge/availability. `set image` with the *same* tag would still be the same PodSpec and typically produce no rollout at all (no template change). To force Pods to reload a rotated Secret/ConfigMap (mounted or env-sourced), use `restart` — it recreates Pods so they re-read the mounted values without inventing a fake revision.
- **A6.2** — A non-zero exit lets a pipeline **gate** on rollout health: `kubectl argo rollouts status ... && promote-next-stage`. In GitOps the CI job fails loudly instead of silently proceeding over a degraded deploy. With `--timeout`, a rollout that is legitimately paused on a **manual** step will *not* satisfy a "healthy" wait — the command keeps waiting (and eventually times out non-zero) because a manual pause is not a completed state. Pipelines therefore either drive the promote themselves or treat "paused" as a distinct expected condition rather than success.
- **A6.3** — `progressDeadlineSeconds` (default 600) controls it; when a rollout makes no progress within that window the controller marks it `Degraded` with `ProgressDeadlineExceeded`. Top root causes: (1) Pods never becoming Ready — bad image / crashloop / failing readiness probe / insufficient resources or quota; (2) the canary blocked upstream — a stuck AnalysisRun, or a traffic router that never programmed the weight so the step can't complete. (`progressDeadlineAbort` optionally auto-aborts on deadline.)
- **A6.4** — External controllers read the `Progressing` and `Available` conditions in `.status.conditions` (plus the aggregate `.status.phase`/`Health` the controller computes). `Available=True` with `Progressing` reason `NewReplicaSetAvailable`/completed → Healthy; `Progressing=True` still moving → Progressing; `Progressing=False`/`ProgressDeadlineExceeded` or an abort → Degraded. Argo CD's Rollout health check keys off exactly these to color the app Healthy/Progressing/Degraded.

</details>