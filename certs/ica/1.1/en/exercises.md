# Guided Exercises — Topic 1.1: Installing Istio with `istioctl` or Helm

> **Exam domain:** Installation, Upgrade & Configuration (this task carries an exam weight of **5**)
> **What you will build:** a working control plane using both supported installation paths (`istioctl` and Helm), a customized install via the `IstioOperator` API, a revisioned control plane suitable for canary upgrades, and sidecar injection into a workload namespace.
> **Prerequisites:** a running Kubernetes cluster (kind, minikube, k3d or a managed cluster) with `kubectl` context pointing at it, cluster-admin RBAC, and internet access to pull charts/images.

Official sources used throughout:
- Install with `istioctl`: https://istio.io/latest/docs/setup/install/istioctl/
- Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Configuration profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- `IstioOperator` API reference: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Canary upgrades & revisions: https://istio.io/latest/docs/setup/upgrade/canary/
- Sidecar injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf

Commands below use Istio **1.24.x** as the concrete version; substitute the release you downloaded.

---

## Exercise 1 — Obtain `istioctl` and run pre-installation checks

1. Confirm your cluster is reachable and note the Kubernetes version (Istio has a supported version matrix):

   ```bash
   kubectl version --short
   kubectl get nodes
   ```

   Expected:

   ```
   Client Version: v1.31.0
   Server Version: v1.30.4

   NAME                 STATUS   ROLES           AGE   VERSION
   ica-control-plane    Ready    control-plane   4m    v1.30.4
   ```

2. Download a specific Istio release (pin the version — never rely on "latest" in production):

   ```bash
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.2 sh -
   cd istio-1.24.2
   export PATH="$PWD/bin:$PATH"
   ```

3. Verify the binary and confirm the client has no control plane to talk to yet:

   ```bash
   istioctl version
   ```

   Expected (no control plane installed yet):

   ```
   client version: 1.24.2
   control plane version: 1.24.2
   no ready Istio pods in "istio-system"
   ```

4. Run the **pre-check**. This inspects the cluster for compatibility problems (RBAC, existing installations, unsupported Kubernetes versions) *before* you mutate anything:

   ```bash
   istioctl x precheck
   ```

   Expected:

   ```
   ✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
   ```

**Comprehension check 1**
- (a) Why does `istioctl version` report `no ready Istio pods in "istio-system"` instead of failing, and what does that tell you about how the client discovers the control-plane version?
- (b) What class of problems is `istioctl x precheck` designed to catch that a raw `kubectl apply` of manifests would not, and why run it before installing rather than after?
- (c) Why is pinning `ISTIO_VERSION` important for the data-plane/control-plane relationship you will manage later?

---

## Exercise 2 — Install with `istioctl` using a configuration profile

1. List the built-in configuration profiles and inspect what one actually contains:

   ```bash
   istioctl profile list
   ```

   Representative output:

   ```
   Istio configuration profiles:
       ambient
       default
       demo
       empty
       minimal
       openshift
       preview
       remote
       stable
   ```

2. Dump the effective configuration of a profile without installing it (this is the profile rendered as an `IstioOperator` resource):

   ```bash
   istioctl profile dump demo | head -40
   ```

3. Install the **demo** profile (enables ingress + egress gateways and verbose telemetry — good for learning, *not* for production):

   ```bash
   istioctl install --set profile=demo -y
   ```

   Expected:

   ```
   ✔ Istio core installed ⛵️
   ✔ Istiod installed 🧠
   ✔ Ingress gateways installed 🛬
   ✔ Egress gateways installed 🛫
   ✔ Installation complete
   Made this installation the default for cluster-wide operations.
   ```

4. Verify the control plane is healthy and identify the components the profile created:

   ```bash
   kubectl get pods -n istio-system
   kubectl get deploy -n istio-system
   ```

   Expected:

   ```
   NAME                                    READY   STATUS    RESTARTS   AGE
   istio-egressgateway-6b6c...             1/1     Running   0          90s
   istio-ingressgateway-77d...             1/1     Running   0          90s
   istiod-5f8c...                          1/1     Running   0          110s
   ```

5. Confirm the installed resources match the intended manifest (post-install verification against the rendered chart):

   ```bash
   istioctl verify-install
   ```

   Expected (tail):

   ```
   ✔ Istio is installed and verified successfully
   ```

**Comprehension check 2**
- (a) Compare the `default`, `demo` and `minimal` profiles: which components does each enable, and why is `demo` explicitly discouraged for production?
- (b) The output says *"Made this installation the default for cluster-wide operations."* What does "default" mean here in terms of revisions and the `default` revision tag?
- (c) `istioctl verify-install` and `istioctl x precheck` both "check" — what is the difference in *what* and *when* each verifies?

---

## Exercise 3 — Customize the install with an `IstioOperator` manifest

Profiles are the starting point; real installs are declarative overrides on top of a profile.

1. Author an `IstioOperator` manifest that starts from `default`, renames the mesh, tunes `istiod` resources, and sets a couple of `MeshConfig` values:

   ```yaml
   # ica-istio.yaml
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   metadata:
     name: ica-control-plane
     namespace: istio-system
   spec:
     profile: default
     meshConfig:
       accessLogFile: /dev/stdout
       defaultConfig:
         holdApplicationUntilProxyStarts: true
     components:
       pilot:
         k8s:
           resources:
             requests:
               cpu: 500m
               memory: 2048Mi
           hpaSpec:
             minReplicas: 2
             maxReplicas: 5
       ingressGateways:
         - name: istio-ingressgateway
           enabled: true
           k8s:
             service:
               type: LoadBalancer
     values:
       global:
         proxy:
           logLevel: warning
   ```

2. Render the manifest to plain Kubernetes YAML **without applying** — this is what you commit to Git for GitOps and code review:

   ```bash
   istioctl manifest generate -f ica-istio.yaml > rendered-istio.yaml
   grep -c 'kind:' rendered-istio.yaml
   ```

3. Apply the customized install (idempotent — re-running reconciles to the desired state):

   ```bash
   istioctl install -f ica-istio.yaml -y
   ```

4. Prove the overrides took effect:

   ```bash
   kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].resources.requests}'; echo
   kubectl -n istio-system get hpa
   istioctl analyze -A
   ```

   Expected (fragments):

   ```
   {"cpu":"500m","memory":"2048Mi"}

   NAME     REFERENCE           TARGETS       MINPODS   MAXPODS   REPLICAS
   istiod   Deployment/istiod   12%/80%       2         5         2

   ✔ No validation issues found when analyzing namespace: all.
   ```

**Comprehension check 3**
- (a) In the `IstioOperator` spec, what is the difference between the `spec.components.*.k8s` block and the `spec.values` block — which one is a typed API and which is a passthrough, and why does that distinction matter for validation?
- (b) Why is `istioctl manifest generate` (render-then-apply) preferable to `istioctl install` in a GitOps pipeline, and what capability do you lose by using generate + `kubectl apply` instead of `istioctl install`?
- (c) What does `holdApplicationUntilProxyStarts: true` prevent, and which failure mode during pod startup does it address?

---

## Exercise 4 — Install Istio with Helm

The Helm path splits the control plane into discrete charts, giving you independent lifecycle control (and it is the path you'll debug when a customer uses ArgoCD/Flux).

1. Add and update the Istio chart repository:

   ```bash
   helm repo add istio https://istio-release.storage.googleapis.com/charts
   helm repo update
   ```

   Expected:

   ```
   "istio" has been added to your repositories
   ...Successfully got an update from the "istio" chart repository
   ```

2. Create the namespace and install `istio-base` first — it ships the **CRDs and cluster roles**, nothing else:

   ```bash
   kubectl create namespace istio-system
   helm install istio-base istio/base -n istio-system --set defaultRevision=default --wait
   ```

3. Install the control plane (`istiod`):

   ```bash
   helm install istiod istio/istiod -n istio-system --wait
   ```

4. Install an ingress gateway as a **separate** chart into its own namespace:

   ```bash
   kubectl create namespace istio-ingress
   helm install istio-ingressgateway istio/gateway -n istio-ingress --wait
   ```

5. Verify install state and CRDs:

   ```bash
   helm ls -n istio-system
   kubectl get crd | grep 'istio.io' | wc -l
   kubectl get deploy -n istio-system
   ```

   Expected:

   ```
   NAME        NAMESPACE     REVISION  STATUS    CHART           APP VERSION
   istio-base  istio-system  1         deployed  base-1.24.2     1.24.2
   istiod      istio-system  1         deployed  istiod-1.24.2   1.24.2

   14
   NAME     READY   UP-TO-DATE   AVAILABLE   AGE
   istiod   1/1     1            1           60s
   ```

**Comprehension check 4**
- (a) Why must `istio-base` be installed **before** `istiod`, and what breaks if you reverse the order?
- (b) The gateway is a standalone chart in a different namespace than `istiod`. What is the operational advantage of decoupling gateway lifecycle from the control-plane chart?
- (c) Helm does not remove CRDs on `helm uninstall` by default. Why is that behavior deliberate, and what is the risk of manually deleting Istio CRDs on a live mesh?
- (d) Name one capability `istioctl install` provides (compared to raw Helm) that you must reproduce manually when using Helm.

---

## Exercise 5 — Install a *revisioned* control plane (canary-upgrade foundation)

Revisions let two control planes coexist so you can migrate workloads gradually — the mechanism the exam expects you to understand for upgrades.

1. Install a control plane tagged with an explicit revision (dots become dashes because it's a label value):

   ```bash
   istioctl install --set revision=1-24-2 -y
   ```

2. Observe that `istiod` now carries the revision in its name and label:

   ```bash
   kubectl get pods -n istio-system -l app=istiod --show-labels
   ```

   Expected:

   ```
   NAME                        READY   STATUS    ...  LABELS
   istiod-1-24-2-6c9...        1/1     Running   ...  istio.io/rev=1-24-2,...
   ```

3. Point the stable `default` **tag** at this revision, so namespaces using `istio-injection=enabled` resolve to it:

   ```bash
   istioctl tag set default --revision 1-24-2 --overwrite
   istioctl tag list
   ```

   Expected:

   ```
   TAG      REVISION   NAMESPACES
   default  1-24-2     default
   ```

4. Confirm version skew between client, control plane and data plane:

   ```bash
   istioctl version
   ```

   Expected:

   ```
   client version: 1.24.2
   control plane version: 1.24.2
   data plane version: 1.24.2 (2 proxies)
   ```

**Comprehension check 5**
- (a) What is the difference between a **revision** and a **tag** (e.g. `default`), and why does routing injection through a *tag* rather than a raw revision make canary upgrades safer?
- (b) A namespace is labeled `istio-injection=enabled` and another `istio.io/rev=1-24-2`. Which one binds to the `default` tag and which binds to a specific revision — and what happens to the first namespace's sidecars when you re-point the `default` tag?
- (c) In a canary upgrade, why must the *new* control plane be installed and healthy before you touch any namespace labels or restart workloads?

---

## Exercise 6 — Enable sidecar injection and verify data-plane enrollment

An installed control plane does nothing until proxies are injected. This closes the loop from "installed" to "meshed".

1. Label a workload namespace for automatic injection (via the `default` tag from Exercise 5):

   ```bash
   kubectl label namespace default istio-injection=enabled --overwrite
   kubectl get namespace -L istio-injection
   ```

2. Deploy a test workload and confirm it receives a proxy (container count `2/2` = app + `istio-proxy`):

   ```bash
   kubectl -n default create deployment httpbin --image=kennethreitz/httpbin
   kubectl -n default rollout status deploy/httpbin
   kubectl -n default get pod -l app=httpbin
   ```

   Expected:

   ```
   NAME                       READY   STATUS    RESTARTS   AGE
   httpbin-7d8f...            2/2     Running   0          25s
   ```

3. Inspect which control plane the proxy is attached to and confirm config sync:

   ```bash
   istioctl proxy-status
   ```

   Expected:

   ```
   NAME                         CLUSTER   CDS   LDS   EDS   RDS   ECDS  ISTIOD              VERSION
   httpbin-7d8f....default      Kubernetes SYNCED SYNCED SYNCED SYNCED SYNCED istiod-1-24-2-...  1.24.2
   ```

4. Run a final config sanity pass across all namespaces:

   ```bash
   istioctl analyze -A
   ```

**Comprehension check 6**
- (a) The webhook injects the sidecar at pod-creation time. Why does labeling the namespace **not** retroactively add proxies to pods that already exist, and what command forces enrollment of existing workloads?
- (b) In `istioctl proxy-status`, what do the `CDS/LDS/EDS/RDS` columns represent, and what does a `STALE` value in one of them tell you about the control-plane↔data-plane relationship?
- (c) If `istio-injection=enabled` and `istio.io/rev=<rev>` are both present on a namespace, which wins, and why is mixing them a common misconfiguration during upgrades?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1
- **(a)** `istioctl` is a normal Kubernetes client: it reads its own version from the compiled binary and discovers the control-plane version by querying the `istiod` pods in `istio-system`. With none present it degrades gracefully to a message rather than erroring, because a missing control plane is the *expected* state before installation. This also means the "control plane version" line is only trustworthy once pods are Running.
- **(b)** `precheck` inspects live cluster state: Kubernetes API version against Istio's supported matrix, sufficient RBAC to create cluster-scoped resources, conflicting/previous Istio installs, and required CRDs/admission-webhook capabilities. A raw `kubectl apply` would happily create objects and fail *midway*, leaving a half-installed mesh. Running it first is fail-fast: it aborts before any mutation, so the cluster stays clean.
- **(c)** Istio supports version skew of at most **n-1** minor versions between control plane and data plane (proxies). Pinning `ISTIO_VERSION` means your `istioctl` client, the `istiod` it installs, and the injected proxies are a known, matched set — essential when you later run canary upgrades where two versions coexist intentionally.

### Exercise 2
- **(a)** `default` enables `istiod` + an ingress gateway and is the production baseline. `demo` adds an egress gateway plus high-cardinality tracing/access-logging and relaxed resource limits — great for tutorials, wasteful and less secure in production. `minimal` installs *only* `istiod` (no gateways), used when you manage gateways separately or via the Gateway API. `demo` is discouraged because its telemetry verbosity and egress gateway are not what you want carrying production traffic.
- **(b)** "Default" means this control plane owns the **`default` revision tag**. Namespaces labeled `istio-injection=enabled` resolve their injector through that tag, so this install becomes the one that injects sidecars cluster-wide unless a namespace explicitly opts into another revision.
- **(c)** `precheck` runs **before** install and validates the *cluster's readiness* (versions, RBAC, conflicts). `verify-install` runs **after** and compares *what is actually deployed* against the rendered manifest/expected resources, confirming the install completed and matches intent. One gates entry; the other confirms the outcome.

### Exercise 3
- **(a)** `spec.components.*.k8s` is a **typed, validated API** (the `IstioOperator` schema) covering Kubernetes settings like resources, HPA, service type, node selectors — mistakes here are caught by schema validation. `spec.values` is a **passthrough** to the underlying Helm chart values; it is powerful but largely unvalidated, so typos silently do nothing. Prefer the typed `k8s` block when an option exists there, and reserve `values` for chart knobs the operator API doesn't expose.
- **(b)** `manifest generate` produces deterministic, reviewable YAML you can commit, diff, and reconcile with a GitOps controller — the cluster state derives from Git, not from an imperative command. What you lose with generate + `kubectl apply` is `istioctl`'s **install-time orchestration and ordering/pruning logic** (e.g. correct CRD-then-control-plane sequencing and removal of resources no longer in the spec); you must ensure ordering and prune orphans yourself.
- **(c)** `holdApplicationUntilProxyStarts: true` delays the application container from starting until the `istio-proxy` sidecar is up and has its Envoy config. It prevents the race where the app makes outbound calls before the proxy can route/secure them — which otherwise causes transient connection failures during pod startup.

### Exercise 4
- **(a)** `istio-base` installs the CRDs (and cluster roles) that `istiod` and every Istio resource depend on. Install `istiod` first and it fails because the custom resources and RBAC it expects don't exist yet. Base establishes the API surface; the control plane populates it.
- **(b)** Decoupling lets you scale, upgrade, redeploy, or roll back gateways independently of the control plane, run multiple gateways with different configs/namespaces, and give gateway ownership to a different team without granting them control-plane access. It also isolates blast radius: a gateway change can't disturb `istiod`.
- **(c)** CRDs are cluster-scoped and hold **all** the mesh's custom resources; deleting a CRD cascades to delete every object of that kind. Helm keeps them on uninstall so you don't accidentally wipe live configuration. Manually deleting Istio CRDs on a running mesh would delete all `VirtualService`, `DestinationRule`, `Gateway`, etc. objects at once — an outage.
- **(d)** `istioctl install` provides pre/post checks and automatic resource **pruning** (removing components you disabled/renamed between installs). With Helm you get none of that automatically — disabled components linger unless you uninstall their release, and you run `precheck`/`verify-install`/`analyze` yourself.

### Exercise 5
- **(a)** A **revision** is a concrete, versioned control-plane instance (e.g. `1-24-2`); a **tag** is a stable, human-friendly alias (e.g. `default`, `prod-stable`) that points *at* a revision. Injecting through a tag means you migrate workloads by re-pointing the tag and restarting pods — no need to relabel every namespace when you change the underlying revision, which makes rollouts and rollbacks a single, reversible operation.
- **(b)** `istio-injection=enabled` binds to the **`default` tag**; `istio.io/rev=1-24-2` binds to that **specific revision**. When you re-point the `default` tag to a new revision, namespaces using `istio-injection=enabled` will get sidecars from the new revision on their **next pod restart** (injection happens at pod creation, so existing pods are unchanged until restarted).
- **(c)** Because canary upgrades rely on **coexistence**: the new control plane must be Running and serving config so that when you shift a namespace/restart workloads, the new proxies have a healthy `istiod` to connect to. If you relabel or restart before the new control plane is ready, those pods have no control plane to sync from and traffic breaks.

### Exercise 6
- **(a)** Injection is performed by a **mutating admission webhook** that fires only on pod *creation*. Existing pods were admitted before the label changed, so they were never rewritten. To enroll them you must recreate the pods, typically `kubectl rollout restart deployment/<name>` (or delete the pods and let the controller recreate them).
- **(b)** They are Envoy's xDS subscriptions: **CDS** clusters (upstreams), **LDS** listeners (ports/filters), **EDS** endpoints (the IPs behind clusters), **RDS** routes (HTTP routing rules). `SYNCED` means the proxy has the latest config `istiod` pushed; `STALE` means `istiod` has newer config the proxy hasn't acknowledged — usually a connectivity, load, or proxy-health problem between data plane and control plane. `NOT SENT` means no config of that type is required yet.
- **(c)** `istio.io/rev=<rev>` **takes precedence** over `istio-injection=enabled` when both are present. It's a common upgrade footgun: an operator adds a revision label to migrate a namespace but forgets to remove the old `istio-injection=enabled` label, and then is surprised that injection follows the revision (not the `default` tag). Keep exactly one injection label per namespace.

</details>