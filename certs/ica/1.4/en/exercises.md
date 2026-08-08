# Topic 1.4 — Upgrading Istio (Canary, In-Place)

> Guided exercises. Run each numbered step against a live cluster, compare your output with the expected output shown, then answer the checkpoint questions before moving on. Answers are collapsed at the end.
>
> **Environment assumed:** a Kubernetes cluster (kind/minikube/managed), `kubectl` with cluster-admin, and Istio **1.19.x** already installed with `istioctl install` (the *default*, revisionless control plane). We will upgrade toward **1.20.0**. Substitute your own versions where noted.
>
> Official references used throughout:
> - Upgrade overview — https://istio.io/latest/docs/setup/upgrade/
> - In-place upgrade — https://istio.io/latest/docs/setup/upgrade/in-place/
> - Canary upgrade — https://istio.io/latest/docs/setup/upgrade/canary/
> - Stable revision labels (revision tags) — https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels

---

## Exercise 1 — Establish and understand the baseline

Before any upgrade, you must know exactly what is running: control-plane version, data-plane versions, and how injection is currently wired.

1. Record the versions of the CLI, the control plane, and every sidecar:

   ```bash
   istioctl version
   ```

   Expected output:

   ```text
   client version: 1.19.3
   control plane version: 1.19.3
   data plane version: 1.19.3 (4 proxies)
   ```

2. Deploy a sample workload so you have proxies to migrate later:

   ```bash
   kubectl create namespace demo
   kubectl label namespace demo istio-injection=enabled
   kubectl apply -n demo -f https://raw.githubusercontent.com/istio/istio/release-1.19/samples/httpbin/httpbin.yaml
   kubectl rollout status -n demo deployment/httpbin
   ```

3. Confirm the sidecar was injected and note which control plane manages it:

   ```bash
   istioctl proxy-status
   ```

   Expected output (abridged):

   ```text
   NAME                             CLUSTER      CDS        LDS        EDS        RDS          ISTIOD                      VERSION
   httpbin-7d...-abcde.demo         Kubernetes   SYNCED     SYNCED     SYNCED     SYNCED       istiod-5f9c...              1.19.3
   ```

4. Inspect how injection is decided for the `demo` namespace:

   ```bash
   kubectl get namespace demo --show-labels
   ```

   Expected output:

   ```text
   NAME   STATUS   AGE   LABELS
   demo   Active   1m    istio-injection=enabled,kubernetes.io/metadata.name=demo
   ```

**Checkpoint 1**

- a) The `data plane version` line reports "(4 proxies)". Where do sidecar proxies get the version they run — from the pod spec you wrote, or from the control plane? What does that imply for a data-plane upgrade?
- b) The namespace carries `istio-injection=enabled`, not `istio.io/rev=...`. Which control plane will inject sidecars into new pods in `demo`, and how does Istio resolve that label to a specific `istiod`?

---

## Exercise 2 — In-place (revisionless) upgrade

An in-place upgrade **replaces** the existing control plane. There is only ever one `istiod`; workloads are unaware until you restart them. Simplest to reason about, but there is no side-by-side safety net.

1. Download the **target** `istioctl` (it must match the version you intend to run):

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.20.0 sh -
   cd istio-1.20.0
   export PATH=$PWD/bin:$PATH
   istioctl version --remote=false
   ```

   Expected output:

   ```text
   client version: 1.20.0
   ```

2. Run the pre-upgrade check. This validates that skipping is not required (Istio supports upgrading only **one minor version at a time**) and flags deprecated config:

   ```bash
   istioctl x precheck
   ```

   Expected output:

   ```text
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

3. Perform the in-place upgrade of the control plane:

   ```bash
   istioctl upgrade
   ```

   You will be prompted to confirm. Expected tail of output:

   ```text
   This will install the Istio 1.20.0 profile "default" into the cluster. Proceed? (y/N) y
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Ingress gateways installed
   ✔ Installation complete
   ```

4. Verify the control plane moved but the **data plane has not**:

   ```bash
   istioctl version
   ```

   Expected output — note the version skew:

   ```text
   client version: 1.20.0
   control plane version: 1.20.0
   data plane version: 1.19.3 (4 proxies)
   ```

5. Upgrade the data plane by restarting the injected workloads so they pick up the new sidecar:

   ```bash
   kubectl rollout restart deployment -n demo
   kubectl rollout status -n demo deployment/httpbin
   ```

6. Confirm convergence:

   ```bash
   istioctl version
   ```

   Expected output:

   ```text
   client version: 1.20.0
   control plane version: 1.20.0
   data plane version: 1.20.0 (4 proxies)
   ```

**Checkpoint 2**

- a) Between step 3 and step 5 the control plane is 1.20.0 while sidecars are still 1.19.3. Is this supported, and for how wide a version gap is proxy↔istiod skew tolerated?
- b) Why is `kubectl rollout restart` required to finish the upgrade, and what would happen to the sidecar version if you instead just `kubectl delete pod` a single httpbin pod?
- c) In this strategy, if the new control plane is faulty, what is your rollback path — and why is it riskier than the canary approach you'll see next?

---

## Exercise 3 — Canary upgrade: install a revisioned control plane

A canary upgrade installs the **new** control plane **alongside** the old one, each identified by a *revision*. Nothing migrates until you opt a namespace in. This gives you a real rollback: the old `istiod` never leaves until you say so.

> Reset assumption for this exercise: you are back on a revisionless 1.19.3 install (as in Exercise 1). We will canary to 1.20.0.

1. Install the target control plane **with a revision** — the old default `istiod` stays untouched:

   ```bash
   istioctl install --set revision=1-20-0 -y
   ```

   Expected output:

   ```text
   ✔ Istio core installed
   ✔ Istiod installed
   ✔ Installation complete
   ```

2. Confirm two control planes now coexist:

   ```bash
   kubectl get pods -n istio-system -l app=istiod -L istio.io/rev
   ```

   Expected output:

   ```text
   NAME                             READY   STATUS    RESTARTS   AGE   REV
   istiod-5f9c...                   1/1     Running   0          40m   default
   istiod-1-20-0-7c8d...            1/1     Running   0          30s   1-20-0
   ```

3. List revisions and see what each is serving:

   ```bash
   istioctl x revision list
   ```

   Expected output (abridged):

   ```text
   REVISION   TAG   ISTIOD                CONTROL PLANE   OPERATOR
   1-20-0     <no-tag>   Healthy (1 istiod)   1.20.0        ...
   default    <no-tag>   Healthy (1 istiod)   1.19.3        ...
   ```

4. Confirm the data plane is **still** entirely on the old revision — installing the canary changed nothing for running proxies:

   ```bash
   istioctl proxy-status
   ```

   Expected output:

   ```text
   NAME                       CLUSTER      ...   ISTIOD              VERSION
   httpbin-7d...-abcde.demo   Kubernetes   ...   istiod-5f9c...      1.19.3
   ```

**Checkpoint 3**

- a) After step 1 there are two `istiod` Deployments. Why did the sidecars in `demo` **not** re-register with the new one, even though it is healthy?
- b) What does each revisioned `istiod` create that lets a namespace's pods target *it specifically* for sidecar injection?
- c) You used revision name `1-20-0` (with dashes) rather than `1.20.0`. Why can't the revision contain dots?

---

## Exercise 4 — Migrate the data plane to the canary revision

Now move workloads, namespace by namespace, restarting so the new revision injects its sidecar. This is the actual "canary" — do one namespace, validate, then widen.

1. Point the `demo` namespace at the new revision. The two injection labels are mutually exclusive, so you must **remove** `istio-injection` while adding `istio.io/rev`:

   ```bash
   kubectl label namespace demo istio-injection- istio.io/rev=1-20-0 --overwrite
   kubectl get namespace demo --show-labels
   ```

   Expected output:

   ```text
   NAME   STATUS   AGE   LABELS
   demo   Active   45m   istio.io/rev=1-20-0,kubernetes.io/metadata.name=demo
   ```

2. Roll the workload so new pods get a sidecar from the canary control plane:

   ```bash
   kubectl rollout restart deployment -n demo
   kubectl rollout status -n demo deployment/httpbin
   ```

3. Verify the proxy now syncs from the **new** `istiod`:

   ```bash
   istioctl proxy-status
   ```

   Expected output:

   ```text
   NAME                       CLUSTER      ...   ISTIOD                     VERSION
   httpbin-7d...-fghij.demo   Kubernetes   ...   istiod-1-20-0-7c8d...      1.20.0
   ```

4. Double-check the sidecar image version on the pod itself:

   ```bash
   kubectl get pod -n demo -l app=httpbin \
     -o jsonpath='{.items[0].spec.containers[?(@.name=="istio-proxy")].image}{"\n"}'
   ```

   Expected output:

   ```text
   docker.io/istio/proxyv2:1.20.0
   ```

**Checkpoint 4**

- a) Step 1 uses `istio-injection-` (trailing hyphen) **and** sets `istio.io/rev`. What happens to injection if you forget the `istio-injection-` part and a namespace ends up with **both** labels?
- b) At this instant, is 1.19.3 traffic to/from other namespaces broken by the fact that `demo` now runs 1.20.0 proxies? Why or why not?
- c) You migrated `demo` first and left everything else on `default`. What is the operational value of validating one namespace before relabeling the rest?

---

## Exercise 5 — Promote with revision tags, then retire the old control plane

Relabeling every namespace on each upgrade doesn't scale. **Revision tags** (stable revision labels) let namespaces point at an alias like `default` or `prod`, and you move the alias between revisions with one command.

1. Create/point a stable `default` tag at the new revision:

   ```bash
   istioctl tag set default --revision 1-20-0 --overwrite
   istioctl tag list
   ```

   Expected output:

   ```text
   TAG       REVISION   NAMESPACES
   default   1-20-0     ...
   ```

2. Understand what this did: the `default` tag now owns the `istio-injection=enabled` webhook. Any namespace that uses the classic `istio-injection=enabled` label is now served by `1-20-0` — no per-namespace relabeling needed. Prove it with a fresh namespace:

   ```bash
   kubectl create namespace demo2
   kubectl label namespace demo2 istio-injection=enabled
   kubectl apply -n demo2 -f samples/httpbin/httpbin.yaml
   kubectl rollout status -n demo2 deployment/httpbin
   istioctl proxy-status | grep demo2
   ```

   Expected output:

   ```text
   httpbin-...-.demo2   Kubernetes   ...   istiod-1-20-0-7c8d...   1.20.0
   ```

3. When you are confident, remove the **old** control plane by revision:

   ```bash
   istioctl uninstall --revision default -y
   ```

   Expected tail:

   ```text
   ✔ Uninstall complete
   ```

4. Confirm only one control plane remains:

   ```bash
   kubectl get pods -n istio-system -l app=istiod -L istio.io/rev
   istioctl x revision list
   ```

   Expected output:

   ```text
   NAME                    READY   STATUS    RESTARTS   AGE   REV
   istiod-1-20-0-7c8d...   1/1     Running   0          20m   1-20-0
   ```

**Checkpoint 5**

- a) A namespace labeled `istio.io/rev=default` versus `istio.io/rev=1-20-0` — which one survives an upgrade to 1.21 without being relabeled, and why is that the whole point of a revision tag?
- b) Before running `istioctl uninstall --revision default`, what one check (a single command) confirms that no proxy is still attached to the `default` control plane, so uninstalling won't strand any sidecar?
- c) If you `istioctl uninstall` the old revision while a namespace is still labeled `istio.io/rev=default` (the raw revision, not the tag), what breaks for that namespace's *new* pods, and does it break *running* pods?

---

## Exercise 6 — Rolling back a canary upgrade

The reason to pay the canary tax is this exercise: reverting is a label change plus a restart, not a control-plane reinstall.

1. Suppose 1.20.0 misbehaves for `demo`. Point the namespace back at the old revision (still installed, because you did **not** run Exercise 5's uninstall):

   ```bash
   kubectl label namespace demo istio.io/rev=default --overwrite
   ```

   Or, if you had promoted via the `default` tag, repoint the tag instead:

   ```bash
   istioctl tag set default --revision default --overwrite
   ```

2. Restart to re-inject the old sidecar:

   ```bash
   kubectl rollout restart deployment -n demo
   kubectl rollout status -n demo deployment/httpbin
   ```

3. Confirm the rollback:

   ```bash
   istioctl proxy-status | grep demo
   ```

   Expected output:

   ```text
   httpbin-...-.demo   Kubernetes   ...   istiod-5f9c...   1.19.3
   ```

**Checkpoint 6**

- a) Why is canary rollback fundamentally safer than in-place rollback, in terms of *what has to be reinstalled* and *what state the cluster passes through*?
- b) The rollback restarts pods to swap sidecars. What is the one prerequisite about the old control plane that must have been true for this to work at all?

---

<details>
<summary><strong>Answers</strong></summary>

### Checkpoint 1
- **a)** The sidecar version comes from the **`istio-proxy` container image injected into the pod spec at admission time**, not from anything the control plane pushes at runtime. `istiod` only pushes *configuration* (xDS) to whatever proxy is already running. Therefore upgrading the data plane means **producing new pods with a new proxy image** — i.e. a rollout/restart — not a live in-memory swap.
- **b)** With `istio-injection=enabled`, the pod is matched by the **default sidecar injector `MutatingWebhookConfiguration`**, which is owned by the revisionless (`default`) control plane. Istio maps the `istio-injection=enabled` label to a specific `istiod` through that webhook's namespace selector; whichever revision currently owns the `istio-injection` webhook (the revisionless install, or later the revision holding the `default` tag) does the injecting.

### Checkpoint 2
- **a)** Yes, it is supported and expected during an upgrade. Istio supports **proxies running up to one minor version behind or ahead of `istiod`** (n-1 skew), which is exactly why an in-place upgrade can leave old sidecars talking to a new control plane until you restart them. You must still finish the restart promptly rather than living on the skew.
- **b)** `kubectl rollout restart` recreates the pods, and **injection happens on pod creation**, so the recreated pods get the new proxy image. Deleting a single pod also works for that one pod (the Deployment recreates it and it gets injected with the new sidecar), but it only upgrades that pod — `rollout restart` upgrades the whole workload in a controlled, surge-aware manner.
- **c)** Rollback for in-place means **reinstalling the previous version over the current one** (`istioctl upgrade`/`install` with the old binary) and restarting workloads again. It is riskier because there was never a second control plane to fall back to: the cluster spent time with only the new, possibly-broken `istiod`, and reverting is another full control-plane replacement rather than a label flip.

### Checkpoint 3
- **a)** Injection labels decide **which webhook injects a proxy at pod creation**; they do not affect **already-running** pods. The existing sidecars keep their xDS connection to the `default` `istiod` because nothing recreated them. The new control plane only takes effect once a namespace is relabeled *and* its pods are restarted.
- **b)** Each revisioned control plane creates its own **`MutatingWebhookConfiguration`** (e.g. `istio-sidecar-injector-1-20-0`) whose selector matches `istio.io/rev=1-20-0`. That is what lets a namespace target one specific `istiod` for injection. (It also gets its own `istiod` Service/Deployment and validating webhook.)
- **c)** The revision becomes part of Kubernetes object names and label **values**, and it is used to derive resource names that must be RFC 1123 / DNS-1123 compliant. Dots are not valid there, so `1.20.0` is written `1-20-0`.

### Checkpoint 4
- **a)** If a namespace has **both** `istio-injection=enabled` and `istio.io/rev=...`, the **`istio-injection` label wins** and the `istio.io/rev` label is ignored — so your pods would keep being injected by the *default/tagged* control plane, not the revision you intended. That is why you must remove `istio-injection` with `istio-injection-` when moving to an explicit revision.
- **b)** No. Sidecars of different minor versions interoperate on the data path; a 1.20.0 proxy in `demo` and a 1.19.3 proxy elsewhere still speak mTLS/HTTP to each other normally. The revision only governs **which control plane configures a proxy**, not wire compatibility between proxies within the supported skew.
- **c)** Validating one namespace first limits blast radius: if the new control plane has a regression (bad config push, CNI/injection issue, telemetry break), it is contained to `demo`, and rollback is a single relabel-and-restart instead of a fleet-wide incident.

### Checkpoint 5
- **a)** A namespace labeled **`istio.io/rev=default`** (a *tag*) survives future upgrades without relabeling, because you just repoint the `default` tag to the next revision (`istioctl tag set default --revision 1-21-0`). A namespace labeled **`istio.io/rev=1-20-0`** (a raw revision) is pinned to that exact control plane and must be relabeled on every upgrade. Decoupling namespaces from concrete revisions via a stable tag is the entire purpose of revision tags.
- **b)** Run **`istioctl proxy-status`** and confirm no proxy still lists the old `default` `istiod` in the `ISTIOD` column (equivalently, `istioctl x revision list` should show `0 proxies`/no dependents for `default`). If any proxy is still attached, restart those workloads before uninstalling.
- **c)** New pods in that namespace **fail to get a sidecar injected** (their injection webhook now points at a control plane that no longer exists — depending on the webhook `failurePolicy`, pod creation is either sidecar-less or rejected). **Running** pods are unaffected in the moment: they keep their already-connected proxy and last-known config, but they receive no further config updates and cannot be safely restarted until relabeled to a live revision.

### Checkpoint 6
- **a)** Canary rollback requires **reinstalling nothing** — the old control plane was never removed, so you only flip a namespace/tag label and restart. The cluster never passes through a "only the broken version exists" state, which is precisely the window an in-place rollback cannot avoid.
- **b)** The **old control plane (its revision and injection webhook) must still be installed** — i.e. you must not have run `istioctl uninstall --revision default` yet. Rollback re-injects the old proxy at pod restart, which only works if that revision's injector is still present to serve the injection.

</details>