# Topic 3.2 — Continuous Delivery Concepts and GitOps Principles: Guided Exercises

> **Format.** Each *Lab* below is a self-contained block: numbered steps you run in a terminal against a local cluster, followed by **Check your understanding** questions. Every answer lives in the collapsible **Solutions** section at the end. Expected outputs are shown so you can verify each step even without a cluster in front of you.
>
> **Prerequisites.** A running Kubernetes cluster (`kind create cluster` or `minikube start` is enough), `kubectl` on your `PATH`, and internet access to pull manifests. Labs 1–3 use **Argo CD**; Lab 4 uses **Flux**; Lab 5 uses **Argo Rollouts**. You do *not* need all four installed at once — each lab installs what it needs.
>
> **Sources of truth for this topic:**
> - OpenGitOps Principles v1.0.0 — https://opengitops.dev/ and https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
> - Argo CD docs — https://argo-cd.readthedocs.io/en/stable/
> - Flux docs — https://fluxcd.io/flux/
> - Argo Rollouts — https://argo-rollouts.readthedocs.io/en/stable/
> - CNCF App Delivery TAG, "GitOps Principles" — https://github.com/cncf/tag-app-delivery

---

## Lab 0 — Warm-up: name the four principles before you touch a cluster

GitOps is defined by **four principles** (OpenGitOps v1.0.0). Every later lab is just one of these principles made concrete, so anchor them first.

1. Write down, from memory, the four OpenGitOps principles. Then open https://opengitops.dev/ and correct yourself.
2. For each principle, write one sentence stating *which component enforces it* in a pull-based tool like Argo CD or Flux.

**Check your understanding**

- Q0.1 — What are the four OpenGitOps principles, in the official wording?
- Q0.2 — "GitOps" and "Infrastructure as Code" are often used interchangeably. Name the one principle that a plain IaC-in-a-repo setup usually lacks.
- Q0.3 — Is *Git* mandatory for GitOps according to the specification? Justify with the exact principle wording.

---

## Lab 1 — Install Argo CD and observe the reconciliation loop

**Goal:** stand up a pull-based CD controller and watch it converge desired state (Git) onto actual state (cluster).

1. Create the namespace and install Argo CD:

   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd \
     -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

2. Wait for the control-plane pods to become ready:

   ```bash
   kubectl -n argocd rollout status deploy/argocd-repo-server
   kubectl -n argocd wait --for=condition=available --timeout=180s \
     deploy --all
   ```

   Expected (abridged):

   ```
   deployment "argocd-repo-server" successfully rolled out
   deployment.apps/argocd-applicationset-controller condition met
   deployment.apps/argocd-dex-server condition met
   deployment.apps/argocd-redis condition met
   deployment.apps/argocd-repo-server condition met
   deployment.apps/argocd-server condition met
   ```

3. List the workloads and identify the reconciler. Note that `argocd-application-controller` is a **StatefulSet**, not a Deployment:

   ```bash
   kubectl -n argocd get statefulset,deploy
   ```

   Expected (abridged):

   ```
   NAME                                             READY
   statefulset.apps/argocd-application-controller   1/1

   NAME                                        READY   UP-TO-DATE   AVAILABLE
   deployment.apps/argocd-server               1/1     1            1
   deployment.apps/argocd-repo-server          1/1     1            1
   deployment.apps/argocd-applicationset-...   1/1     1            1
   ...
   ```

4. Retrieve the initial admin password and expose the API/UI locally:

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d ; echo
   kubectl -n argocd port-forward svc/argocd-server 8080:443 &
   ```

**Check your understanding**

- Q1.1 — Three components did most of the work above: `argocd-application-controller`, `argocd-repo-server`, and `argocd-server`. State the single responsibility of each.
- Q1.2 — Why is the reconciler shipped as a **StatefulSet** rather than a Deployment? What breaks if you naively scale it to `replicas: 3` with default settings?
- Q1.3 — Nothing has been deployed yet, but the controller is already running a loop. What is it comparing against what, and where does it get "desired state" from when no `Application` exists?

---

## Lab 2 — Your first Application: declarative, versioned, pulled

**Goal:** deploy a real workload by declaring an `Application` that *points at Git*. You will not run `kubectl apply` on the app itself — the controller pulls it.

1. Create an `Application` that tracks the public Argo CD example repo. Save as `guestbook-app.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: guestbook
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/argoproj/argocd-example-apps.git
       targetRevision: HEAD
       path: guestbook
     destination:
       server: https://kubernetes.default.svc
       namespace: guestbook
     syncPolicy:
       syncOptions:
         - CreateNamespace=true
   ```

2. Apply the `Application` **object** (this is the only imperative step — you are registering the source, not the app):

   ```bash
   kubectl apply -f guestbook-app.yaml
   ```

3. Inspect its state. It should be `Synced`? No — with no automation it will report `OutOfSync`:

   ```bash
   kubectl -n argocd get application guestbook \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```

   Expected:

   ```
   NAME        SYNC        HEALTH
   guestbook   OutOfSync   Missing
   ```

4. Trigger a one-time sync (still declarative — the manifests come from Git, not from you):

   ```bash
   argocd app sync guestbook            # if the argocd CLI is installed and logged in
   # --- or, purely with kubectl, patch the operation ---
   kubectl -n argocd patch application guestbook --type merge \
     -p '{"operation":{"sync":{"revision":"HEAD"}}}'
   ```

5. Confirm the workload now exists and the Application is healthy:

   ```bash
   kubectl -n guestbook get deploy,svc
   kubectl -n argocd get application guestbook \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
   ```

   Expected:

   ```
   NAME                              READY   UP-TO-DATE   AVAILABLE
   deployment.apps/guestbook-ui      1/1     1            1
   NAME                    TYPE        CLUSTER-IP     PORT(S)
   service/guestbook-ui   ClusterIP   10.96.a.b      80/TCP

   NAME        SYNC     HEALTH
   guestbook   Synced   Healthy
   ```

**Check your understanding**

- Q2.1 — Map each field of the `Application` (`source.repoURL`, `source.path`, `source.targetRevision`, `destination.server`, `destination.namespace`) to what it controls.
- Q2.2 — You applied the `Application` with `kubectl apply`. Doesn't that violate GitOps ("no imperative changes")? Explain why registering the `Application` is different from deploying the workload — and what the *fully* GitOps-native way to create the `Application` itself is called.
- Q2.3 — `targetRevision: HEAD` tracks the tip of the default branch. Why is this a poor choice for production, and which principle does it weaken? What would you pin it to instead?
- Q2.4 — After step 4 the app is `Synced / Healthy`. Distinguish **Sync status** from **Health status** — give one scenario that is `Synced` but `Degraded`, and one that is `OutOfSync` but `Healthy`.

---

## Lab 3 — Drift detection, self-heal, and pruning

**Goal:** experience *continuous reconciliation* — the principle that separates GitOps from a one-shot `kubectl apply`. You will introduce drift out-of-band and watch the controller's behavior with automation **off**, then **on**.

1. With automation still off (from Lab 2), manually scale the deployment out-of-band — simulating a `kubectl edit` by a panicking on-call engineer:

   ```bash
   kubectl -n guestbook scale deploy/guestbook-ui --replicas=5
   kubectl -n argocd get application guestbook \
     -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status
   ```

   Expected — the controller *detects* drift but does not correct it:

   ```
   NAME        SYNC
   guestbook   OutOfSync
   ```

2. Inspect the diff the controller computed:

   ```bash
   argocd app diff guestbook        # or view "APP DIFF" in the UI
   ```

   Expected (abridged) — Git says 1 replica, cluster has 5:

   ```
   ===== apps/Deployment guestbook/guestbook-ui ======
   -   replicas: 1
   +   replicas: 5
   ```

3. Now enable automated sync **with self-heal and prune**. Patch the `Application`:

   ```bash
   kubectl -n argocd patch application guestbook --type merge -p '
   spec:
     syncPolicy:
       automated:
         selfHeal: true
         prune: true
       syncOptions:
         - CreateNamespace=true'
   ```

4. Re-introduce drift and watch it get reverted automatically (self-heal reconciles back toward Git):

   ```bash
   kubectl -n guestbook scale deploy/guestbook-ui --replicas=5
   sleep 15
   kubectl -n guestbook get deploy/guestbook-ui \
     -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   Expected:

   ```
   1
   ```

5. Test **prune**. Manually create a rogue resource in the app's namespace that is *not* in Git, then create one that *is* managed and delete it from the live cluster:

   ```bash
   # a) A resource NOT in Git — prune does NOT touch it (not Argo-managed):
   kubectl -n guestbook create configmap rogue --from-literal=x=1

   # b) Delete a Git-managed resource from the cluster — self-heal recreates it:
   kubectl -n guestbook delete svc guestbook-ui
   sleep 15
   kubectl -n guestbook get svc guestbook-ui
   ```

   Expected — the managed Service comes back, the rogue ConfigMap survives:

   ```
   NAME           TYPE        CLUSTER-IP    PORT(S)
   guestbook-ui   ClusterIP   10.96.a.b     80/TCP
   ```

**Check your understanding**

- Q3.1 — Precisely differentiate **`prune: true`** from **`selfHeal: true`**. Which one acted in step 4, and which would act if you *removed* a resource from the Git repo?
- Q3.2 — In step 5a the rogue ConfigMap survived even with `prune: true`. Why? What determines whether a live object is a prune candidate?
- Q3.3 — Self-heal reverted your manual scale-up in ~15 s. What is the risk of self-heal during a genuine incident where an operator scales up to absorb load, and what is the correct GitOps remedy?
- Q3.4 — Reconciliation here is **pull-based** and runs on a timer (default ~3 min) plus webhooks. Contrast pull-based CD with the older **push-based** model (CI pipeline runs `kubectl apply`). Give two concrete security or operational advantages of pull.

---

## Lab 4 — The same principles with a second tool: Flux

**Goal:** prove the principles are tool-independent by reconciling the *same* Git repo with **Flux**, whose model splits "where is the source" from "what to apply."

1. Install the Flux controllers:

   ```bash
   kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
   kubectl -n flux-system wait --for=condition=available --timeout=180s deploy --all
   kubectl -n flux-system get deploy
   ```

   Expected (abridged):

   ```
   NAME                          READY
   helm-controller               1/1
   kustomize-controller          1/1
   notification-controller       1/1
   source-controller             1/1
   ```

2. Declare a `GitRepository` **source** (this maps to Argo CD's `source.repoURL` + `targetRevision`):

   ```yaml
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: GitRepository
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 1m
     url: https://github.com/stefanprodan/podinfo
     ref:
       branch: master
   ```

3. Declare a `Kustomization` that *applies* a path from that source (this maps to `source.path` + `syncPolicy`):

   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: podinfo
     namespace: flux-system
   spec:
     interval: 10m
     targetNamespace: default
     sourceRef:
       kind: GitRepository
       name: podinfo
     path: ./kustomize
     prune: true
   ```

4. Apply both and watch reconciliation:

   ```bash
   kubectl apply -f gitrepository.yaml -f kustomization.yaml
   kubectl -n flux-system get gitrepository,kustomization
   kubectl -n default get deploy podinfo
   ```

   Expected (abridged):

   ```
   NAME                        READY   AGE
   gitrepository/podinfo       True    30s
   kustomization/podinfo       True    25s
   NAME       READY   UP-TO-DATE   AVAILABLE
   podinfo    1/1     1            1
   ```

**Check your understanding**

- Q4.1 — Flux splits `GitRepository` from `Kustomization`; Argo CD combines source + destination in one `Application`. What architectural advantage does Flux's split give you when *ten* Kustomizations track the *same* repo?
- Q4.2 — Map these Flux fields to their Argo CD equivalents: `GitRepository.spec.interval`, `Kustomization.spec.path`, `Kustomization.spec.prune`, `Kustomization.spec.targetNamespace`.
- Q4.3 — Flux's `Kustomization.spec.interval: 10m` is the reconcile cadence. If someone drifts a live resource 30 s after a reconcile, worst-case how long until Flux corrects it, and how do you make correction near-instant on Git pushes?

---

## Lab 5 — Progressive delivery: canary with Argo Rollouts

**Goal:** GitOps answers *how state converges*; **progressive delivery** answers *how a new version is rolled out safely*. You'll replace a `Deployment` with a `Rollout` that shifts traffic in weighted steps with an analysis gate.

1. Install the Argo Rollouts controller:

   ```bash
   kubectl create namespace argo-rollouts
   kubectl apply -n argo-rollouts \
     -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
   kubectl -n argo-rollouts rollout status deploy/argo-rollouts
   ```

2. Declare a canary `Rollout`. Save as `rollout.yaml`:

   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Rollout
   metadata:
     name: rollouts-demo
   spec:
     replicas: 5
     strategy:
       canary:
         steps:
           - setWeight: 20
           - pause: { duration: 30s }
           - setWeight: 40
           - pause: { duration: 30s }
           - setWeight: 60
           - pause: {}              # pause indefinitely — requires manual promotion
           - setWeight: 80
           - pause: { duration: 30s }
     selector:
       matchLabels: { app: rollouts-demo }
     template:
       metadata:
         labels: { app: rollouts-demo }
       spec:
         containers:
           - name: rollouts-demo
             image: argoproj/rollouts-demo:blue
             ports:
               - containerPort: 8080
   ```

3. Apply it and confirm all 5 replicas are on the "blue" (stable) version:

   ```bash
   kubectl apply -f rollout.yaml
   kubectl argo rollouts get rollout rollouts-demo   # plugin; or use the dashboard
   ```

   Expected (abridged):

   ```
   Name:            rollouts-demo
   Status:          ✔ Healthy
   Strategy:        Canary
     Step:          8/8
     SetWeight:     100
   Images:          argoproj/rollouts-demo:blue (stable)
   Replicas:
     Desired:       5
     Updated:       5   Ready: 5   Available: 5
   ```

4. Trigger a new version. In GitOps you'd commit an image bump; here, simulate the merge:

   ```bash
   kubectl argo rollouts set image rollouts-demo \
     rollouts-demo=argoproj/rollouts-demo:yellow
   kubectl argo rollouts get rollout rollouts-demo
   ```

   Expected — the canary is at 20% and progressing through the steps:

   ```
   Status:          ॥ Paused
     Step:          1/8
     SetWeight:     20
   Images:          argoproj/rollouts-demo:blue (stable)
                    argoproj/rollouts-demo:yellow (canary)
   ```

5. Advance past the indefinite `pause: {}` at step 6 by promoting manually, then verify full rollout:

   ```bash
   kubectl argo rollouts promote rollouts-demo
   kubectl argo rollouts status rollouts-demo   # blocks until Healthy
   ```

   Expected:

   ```
   Healthy
   ```

**Check your understanding**

- Q5.1 — Define **canary** and **blue-green** deployment and state the key difference in how each treats production traffic during a release.
- Q5.2 — Progressive delivery vs. continuous delivery: is a canary rollout *itself* a GitOps action? Where does GitOps end and progressive delivery begin in Lab 5?
- Q5.3 — Step 6 used `pause: {}` (no duration). Why would you deliberately design an *indefinite* pause into an automated pipeline, and what CNCF-native mechanism replaces the human by auto-promoting or auto-aborting based on metrics?
- Q5.4 — A rollback in a `Deployment` means re-applying the old ReplicaSet. In GitOps, what is the canonical way to roll back, and why is `kubectl argo rollouts undo` an anti-pattern in a GitOps-managed cluster?

---

## Lab 6 — Capstone: reason about a broken pipeline

**Goal:** synthesize everything by diagnosing failures from symptoms alone (no new commands).

1. **Scenario A.** An `Application` is `Synced` and `Healthy`, but the new feature is not live for users. `git log` shows the feature was merged 2 hours ago. `targetRevision: v1.4.0`.
2. **Scenario B.** `Application` flaps between `Synced` and `OutOfSync` every ~3 minutes forever. The diff always shows a `metadata.annotations` field with a timestamp that keeps changing.
3. **Scenario C.** You deleted a Deployment from Git and merged. With `prune: false`, the workload is still running in the cluster a day later. Argo CD reports `OutOfSync`.
4. **Scenario D.** Two teams both manage the `default` namespace from two different repos. Every reconcile, each controller deletes the other team's resources.

**Check your understanding**

- Q6.1 — Scenario A: why is a `Synced`/`Healthy` app still not shipping the feature? Name the exact field to inspect.
- Q6.2 — Scenario B: what is this failure mode called, what commonly causes it (name a mutating source), and what field resolves it?
- Q6.3 — Scenario C: is the controller behaving correctly? What single change makes the delete propagate, and what is the safety trade-off?
- Q6.4 — Scenario D: name the isolation boundary each tool provides to prevent this (Argo CD *and* Flux), and the principle being violated.

---

## Solutions

<details>
<summary>Click to reveal all answers</summary>

### Lab 0

**A0.1 — The four OpenGitOps principles (v1.0.0):**
1. **Declarative** — the entire system's desired state is expressed declaratively.
2. **Versioned and Immutable** — desired state is stored in a way that enforces immutability and versioning and retains a complete version history.
3. **Pulled Automatically** — software agents automatically pull the desired state declarations from the source.
4. **Continuously Reconciled** — software agents continuously observe actual system state and attempt to apply the desired state.
Source: https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md

**A0.2 —** The principle usually missing from plain "IaC in a repo" is **Continuously Reconciled** (and often **Pulled Automatically**). Committing Terraform/YAML to Git and running `apply` from CI is push-based and one-shot: nothing continuously observes the cluster and corrects drift. IaC is a *practice about how state is described*; GitOps additionally mandates an agent that closes the loop.

**A0.3 —** No — Git is **not** mandatory. The principles say "**versioned and immutable**" and "pull from **the source**," never "Git." Any store with immutability and complete version history (e.g., an OCI registry with immutable tags/digests) satisfies principle 2. "Git" is the common implementation, not the requirement.

### Lab 1

**A1.1 —**
- **`argocd-application-controller`** — the reconciler. Compares desired state (rendered from Git) against live cluster state, computes diffs, and performs syncs. This is the loop.
- **`argocd-repo-server`** — clones the Git repo and *renders* manifests (runs `kustomize build`, `helm template`, plain YAML, plugins) into final Kubernetes objects. Stateless template engine.
- **`argocd-server`** — the API/UI/gRPC front end (auth, RBAC, the web UI, the `argocd` CLI target). It does no reconciliation.

**A1.2 —** It's a StatefulSet because the controller holds an in-memory cache of cluster state and shards *clusters* across replicas for HA; it needs stable identity/ordinals to assign shards deterministically. Naively setting `replicas: 3` without configuring sharding (`ARGOCD_CONTROLLER_REPLICAS` / shard env) means multiple controllers reconcile the **same** Applications simultaneously — duplicated work, conflicting sync operations, and API thrash. Sharding must be configured so each replica owns a disjoint set of clusters.

**A1.3 —** The controller continuously lists `Application` custom resources in its watched namespace(s) and reconciles each. With **zero** Applications there is nothing to reconcile, so "desired state" has no source yet; the loop simply watches for `Application` objects to appear. Desired state for a *workload* only exists once an `Application` names a `repoURL`/`path` — the repo is the source of truth, the `Application` is the pointer to it.

### Lab 2

**A2.1 —**
- `source.repoURL` — which Git repository holds the manifests.
- `source.path` — the directory within that repo to render.
- `source.targetRevision` — which Git ref (branch, tag, or commit SHA) to track.
- `destination.server` — which cluster to deploy to (`https://kubernetes.default.svc` = the in-cluster API, i.e. "this cluster").
- `destination.namespace` — the default namespace for namespaced resources that don't specify one.

**A2.2 —** Registering the `Application` is *bootstrapping the pointer*, not deploying the workload. The workload's manifests still come exclusively from Git and are pulled by the controller — the app is never applied by a human. The fully GitOps-native way to manage the `Application` objects themselves is the **App-of-Apps** pattern (or `ApplicationSet`): a root Application in Git whose manifests are *other* Applications, so even the pointers are versioned and reconciled. That eliminates the one imperative `kubectl apply`.

**A2.3 —** `HEAD` (tip of default branch) is mutable — the deployed version silently changes whenever anyone merges, so you cannot reproduce or audit "what was running at 3pm," weakening **Versioned and Immutable**. Pin to an **immutable ref**: a Git **tag** (`v1.4.0`) or, best, a **commit SHA**. Then every deployment is reproducible and rollback is "point back at the previous SHA."

**A2.4 —**
- **Sync status** = does the *live* state match the *desired* (Git) state? (`Synced` / `OutOfSync`).
- **Health status** = are the resources *functioning*? (`Healthy` / `Progressing` / `Degraded` / `Missing`), computed from resource-specific health checks (e.g., Deployment availability, Pod readiness).
- **`Synced` but `Degraded`:** the exact manifest from Git is applied, but the container crash-loops (bad image, failing readiness probe) — cluster matches Git, app is broken.
- **`OutOfSync` but `Healthy`:** someone manually scaled the Deployment up; all pods are running fine (Healthy) but the live spec no longer matches Git (OutOfSync).

### Lab 3

**A3.1 —**
- **`selfHeal: true`** — when the *live* state drifts from Git (out-of-band change to a resource that still exists in Git), automatically re-apply Git's version. It fixed step 4's manual scale-up.
- **`prune: true`** — when a resource is *removed from Git*, delete it from the cluster. It would act if you deleted a manifest from the repo and merged. Self-heal fixes *modified/deleted-live* managed resources; prune deletes *no-longer-declared* ones.

**A3.2 —** The rogue ConfigMap survived because Argo CD only prunes resources it **tracks** — objects it created carry the app's tracking label/annotation (e.g., `app.kubernetes.io/instance` or the `argocd.argoproj.io/tracking-id` annotation). The ConfigMap was created out-of-band, has no tracking metadata, and therefore is not a prune candidate. Prune deletes "things I once applied that are no longer in Git," never "everything in the namespace."

**A3.3 —** During a real incident, self-heal will **fight the operator**: it reverts the emergency scale-up back to Git's value within seconds, potentially re-triggering the outage. The correct GitOps remedy is to *change Git*, not the cluster: commit the higher replica count (or bump an HPA floor) so desired state reflects intent — reconciliation then keeps it. If you must intervene immediately, temporarily disable automated sync or set a `maintenance`/sync window, then reconcile Git back to truth.

**A3.4 —** Two advantages of **pull** over **push**:
1. **Credentials stay in the cluster.** The in-cluster agent needs no inbound access and CI needs no cluster-admin kubeconfig; you never hand production credentials to an external pipeline (smaller blast radius, no long-lived kubeconfig in CI secrets).
2. **Continuous drift correction.** Push applies once and forgets; pull continuously reconciles, so out-of-band drift is detected and (optionally) healed, and a compromised/edited cluster self-corrects toward Git.
(Also: the cluster can be private/firewalled with no ingress from CI; and the agent gives you a real-time single source of "what's actually deployed.")

### Lab 4

**A4.1 —** One `GitRepository` source is fetched **once** and shared by all ten `Kustomization` objects (each pointing at a different `path`). That means a single clone/interval, one set of credentials, one dedup'd artifact — instead of ten Applications each independently cloning the same repo. Separation of *source acquisition* from *application* reduces load and centralizes credential/verification config.

**A4.2 —**
- `GitRepository.spec.interval` ≈ Argo CD repo polling / `Application` refresh cadence (how often the source is re-fetched).
- `Kustomization.spec.path` ≈ `Application.spec.source.path`.
- `Kustomization.spec.prune` ≈ `Application.spec.syncPolicy.automated.prune`.
- `Kustomization.spec.targetNamespace` ≈ `Application.spec.destination.namespace`.

**A4.3 —** Worst case is roughly the **`Kustomization.spec.interval` (10m)** before Flux next reconciles and corrects drift (source re-fetch is separate at 1m, but the *apply/reconcile* of that Kustomization is 10m). To make Git pushes near-instant, configure a **webhook receiver** (Flux `Receiver` + notification-controller) so a push triggers immediate reconciliation instead of waiting for the interval. (You can also `flux reconcile kustomization podinfo` to force it.)

### Lab 5

**A5.1 —**
- **Canary:** the new version runs alongside the stable version and receives a *gradually increasing slice* of live production traffic (20% → 40% → …). Both versions serve real users simultaneously; you widen exposure only if metrics stay healthy.
- **Blue-green:** two full environments — blue (current) and green (new). Green is deployed and tested while receiving **no production traffic**, then traffic is **cut over all at once** by flipping the service/router. Rollback is flipping back to blue.
- **Key difference:** canary exposes real traffic *incrementally* to the new version; blue-green keeps the new version dark until an *atomic 0→100%* switch.

**A5.2 —** The canary *strategy definition* (the `Rollout` manifest, its steps, weights, analysis) **is** GitOps — it's declarative desired state in Git, pulled and reconciled like anything else. The **execution** of the canary (shifting weights, pausing, promoting/aborting based on metrics) is **progressive delivery**, driven by the Rollouts controller. GitOps gets the desired *rollout definition* onto the cluster; progressive delivery governs the *runtime transition* between versions. They compose: Argo CD syncs the `Rollout`, Argo Rollouts executes it.

**A5.3 —** An indefinite `pause: {}` is a deliberate **manual gate/soak point** — hold at, say, 60% while a human reviews dashboards, waits for a bake period, or gets sign-off before widening. The CNCF-native replacement for the human is an **`AnalysisTemplate` / `AnalysisRun`** (Argo Rollouts) — or **Flagger** with Flux — that queries a metrics provider (Prometheus, Datadog, etc.) and **auto-promotes** on success or **auto-aborts/rolls back** when success-rate/latency SLOs are breached, removing the manual pause.

**A5.4 —** The canonical GitOps rollback is to **revert the change in Git** (revert the commit / re-point `targetRevision` to the previous tag or SHA) and let the controller reconcile the cluster back. `kubectl argo rollouts undo` mutates the cluster **out-of-band**: it creates drift that a self-healing GitOps controller will immediately fight (reconciling back to the still-bad Git state), and it leaves no version-controlled record of the rollback. In a GitOps-managed cluster, *the repo is the rollback mechanism*.

### Lab 6

**A6.1 — Scenario A:** `Synced`/`Healthy` only means "live state matches the tracked revision." The app tracks `targetRevision: v1.4.0`, but the feature merged to `main` and no one moved the tag/ref. Inspect **`spec.source.targetRevision`** (and `status.sync.revision`) — the pointer is pinned behind the feature commit. Fix: bump `targetRevision` to the tag/SHA containing the feature (in Git, then sync).

**A6.2 — Scenario B:** This is **perpetual/永动 drift ("sync loop" / never-Synced flapping)**, caused by a **mutating admission source** or a controller that keeps rewriting a field — e.g., a mutating webhook, a `metadata.annotations` timestamp injected by another operator, or `kubectl.kubernetes.io/last-applied-configuration` churn. The live object never matches rendered Git, so it oscillates. Resolve with **`ignoreDifferences`** (Argo CD) on that JSON path (`/metadata/annotations/<key>`), or stop the mutating source from writing a managed field.

**A6.3 — Scenario C:** Yes, the controller is behaving **correctly** — with `prune: false`, resources removed from Git are intentionally *not* deleted; Argo CD flags the divergence as `OutOfSync` and waits for a human. Set **`syncPolicy.automated.prune: true`** (or prune on manual sync) to propagate the deletion. Trade-off: prune makes accidental manifest deletion (or a bad merge) destroy live workloads automatically — hence prune-off is the cautious default, often paired with `PruneLast` and deletion-safety options.

**A6.4 — Scenario D:** The two tools' isolation boundaries:
- **Argo CD:** an **`AppProject`** — restricts which repos, destinations (clusters/namespaces), and resource kinds an Application may manage, preventing one team's app from touching another's namespace.
- **Flux:** **multi-tenancy** via per-tenant namespaces, `ServiceAccount` impersonation (`spec.serviceAccountName`), and RBAC scoping so each `Kustomization` can only act within its tenant's boundary.
The principle being violated is fundamentally ownership/isolation — two agents both asserting authoritative desired state over the same objects means neither namespace has a single source of truth; **Continuously Reconciled** turns into a delete-war because the *scope of authority* was never bounded.

</details>