# ICA 1.4 — Upgrading Istio (Canary, In-Place)

> **Exam weight: 5.** This topic sits at the intersection of Istio's split architecture (control plane `istiod` + per-pod Envoy data plane) and day-2 operational risk. The exam expects you to know *how* each strategy moves bits, *why* one is safer than the other, and *how to diagnose* a half-migrated mesh.

---

## 1. Motivation and the production architectural problem

An Istio mesh is two loosely-coupled tiers that must be upgraded independently:

- **Control plane** — a single `istiod` Deployment. It compiles high-level API objects (`VirtualService`, `DestinationRule`, `Gateway`, `AuthorizationPolicy`, `Sidecar`, `PeerAuthentication`) into **xDS** (CDS/LDS/EDS/RDS/ECDS) and streams them to every proxy. It also hosts the **sidecar injection webhook** and the mesh CA (Citadel functionality).
- **Data plane** — one Envoy sidecar per workload pod, injected at admission time. A sidecar's binary version is **fixed at pod creation**; it only changes when the pod is recreated.

This split creates three coupled failure modes that make "just upgrade it" dangerous in production:

1. **Blast radius of the control plane.** One `istiod` drives *every* proxy in the mesh. If the new version has an xDS-translation regression (a subtle change in how a `VirtualService` compiles to an RDS route, or a listener filter reorder), an **in-place** swap pushes the broken config to the entire fleet at once. There is no partial exposure.

2. **The data-plane skew window is real and unavoidable.** Because sidecars only pick up a new Envoy binary on pod restart, upgrading `istiod` does **not** upgrade the proxies. You will *always* run mixed proxy versions for some window. Istio's compatibility contract is:
   > A proxy (Envoy sidecar) may be at most **two minor versions behind** `istiod`. The proxy must **never** be *newer* than the control plane.

   In-place makes this window implicit and unbounded (proxies stay old until *something* restarts them). Canary makes it explicit and controlled (you restart workloads deliberately, namespace by namespace).

3. **Rollback asymmetry.** Rolling back an in-place upgrade is *another* in-place swap of the whole mesh — the same blast radius, now under incident pressure. With a **canary (revision-based)** upgrade, rollback is a label change plus a rollout restart, and the previous `istiod` is still running untouched.

**The core architectural idea of the canary upgrade** is to exploit Istio's *revisions*: `istiod` can be installed multiple times side-by-side, each tagged with a `revision`, each owning its own injection webhook. A workload is bound to a control plane by a **namespace label** (or, better, a **revision tag**). Migration becomes "relabel a namespace, restart its pods, observe" — a per-tenant canary with instant, low-blast-radius rollback. This is the property the exam is testing under weight 5.

---

## 2. Technical comparison and trade-offs

### 2.1 In-place vs. Canary

| Dimension | In-place upgrade | Canary (revision-based) upgrade |
|---|---|---|
| Control planes running | One `istiod`, swapped in place | Two (or more) `istiod` side-by-side, one per revision |
| Blast radius on control-plane bug | **Entire mesh** immediately | Only namespaces migrated to the new revision |
| Data-plane migration | Restart all workloads (implicit, uncontrolled timing) | Restart per namespace, deliberate and observable |
| Rollback | Re-run install with old version (full-mesh swap) | Relabel namespace to old revision + rollout restart |
| Resource cost | Low (single control plane) | Higher (2× `istiod` CPU/mem for the migration window) |
| Operational complexity | Low | Higher (revisions, tags, webhook lifecycle, cleanup) |
| Time to complete | Fast | Slower (staged, per-namespace) |
| Suited for | Dev/test, single-tenant, minor patch bumps | Production, multi-tenant, minor version bumps |
| Recommended by Istio for prod | No (acceptable for patch releases) | **Yes** |

**Rule of thumb:** patch releases (`1.20.1 → 1.20.2`) are commonly done in-place; minor releases (`1.19.x → 1.20.x`) should be canary in production because that's where xDS/config-translation behavior can change.

### 2.2 Binding workloads: `istio.io/rev` on namespaces vs. Revision tags

| Aspect | Direct revision label (`istio.io/rev=1-20-2`) | Revision **tag** (`istio.io/rev=prod-stable`) |
|---|---|---|
| What the namespace label points at | A concrete revision (a specific `istiod`) | A stable **alias** that you re-point at any revision |
| Promoting a new version | Relabel **every** namespace + restart | Move the tag once (`istioctl tag set … --overwrite`) + restart |
| Rollback | Relabel every namespace back | Move the tag back once |
| Coupling to version string | Tight (namespaces know exact revision) | Decoupled (namespaces know only the tag) |
| Best for | Small mesh, one-off migration | Production, many namespaces, repeatable upgrades |

Tags are the production pattern: label namespaces once with a *role* (`prod-stable`, `prod-canary`), then upgrade by repointing the tag — no mass relabeling.

### 2.3 Injection-label precedence (a frequent exam and production trap)

| Namespace labels present | Injector used |
|---|---|
| `istio-injection=enabled` only | The revision holding the **`default`** tag |
| `istio.io/rev=<rev-or-tag>` only | That specific revision / tag |
| **Both** `istio-injection=enabled` **and** `istio.io/rev=…` | **`istio-injection` wins**; `istio.io/rev` is ignored |
| Neither | No injection |

> During a canary migration you **must remove** `istio-injection=enabled` when you add `istio.io/rev`, or the pods keep going to the `default` (old) control plane and your "migration" silently does nothing.

### 2.4 Gateway upgrade strategies

| Strategy | Mechanism | Trade-off |
|---|---|---|
| In-place gateway | `helm upgrade` (or reinstall) the same gateway Deployment | Simple; brief config churn on the single gateway |
| Canary gateway | Deploy a **second** gateway Deployment bound to the new revision, shift traffic (DNS/LB/weighted `Gateway`) | Zero-downtime, testable, but requires a traffic-shift plan and a second external IP or LB |

---

## 3. Complete manifests and infrastructure

### 3.1 In-place upgrade — `IstioOperator` (istioctl-driven)

`istio-inplace.yaml` — note there is **no `revision`**, so it manages the default control plane in place:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-control-plane
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
            memory: 2Gi
        hpaSpec:
          minReplicas: 2
          maxReplicas: 5
        # PodDisruptionBudget keeps at least one istiod during the swap
        podDisruptionBudget:
          minAvailable: 1
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
```

### 3.2 Canary upgrade — revisioned `IstioOperator`

`istio-canary-1-20-2.yaml` — the only load-bearing addition is `spec.revision`. Downloading and using the matching-version `istioctl` is what actually bumps the binaries:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-canary-1-20-2
  namespace: istio-system
spec:
  revision: 1-20-2          # dots are illegal in a revision label; use dashes
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
            memory: 2Gi
        hpaSpec:
          minReplicas: 2
          maxReplicas: 5
    # Do NOT re-declare the shared ingress gateway here during a canary,
    # or you will fight the existing one for the Service/LB. Canary the
    # gateway separately (see 3.5).
```

This produces a **parallel** control plane: Deployment `istiod-1-20-2`, Service `istiod-1-20-2`, and `MutatingWebhookConfiguration istio-sidecar-injector-1-20-2` whose namespace selector matches `istio.io/rev: 1-20-2`.

### 3.3 Namespace binding (direct revision)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/rev: 1-20-2   # bind to the canary control plane
    # istio-injection: enabled   <-- MUST be absent/removed (it wins otherwise)
```

### 3.4 Revision tags (production pattern)

Tags are created imperatively but materialize as a `MutatingWebhookConfiguration`. Inspect one you created with `istioctl tag set prod-stable --revision 1-19-3`:

```yaml
# kubectl get mutatingwebhookconfiguration istio-revision-tag-prod-stable -o yaml (abridged)
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: istio-revision-tag-prod-stable
  labels:
    istio.io/rev: 1-19-3            # tag currently points here
    istio.io/tag: prod-stable
webhooks:
  - name: rev.namespace.sidecar-injector.istio.io
    namespaceSelector:
      matchExpressions:
        - key: istio.io/rev
          operator: In
          values: ["prod-stable"]   # namespaces labeled with the TAG match
    clientConfig:
      service:
        name: istiod-1-19-3          # routed to the revision's istiod
        namespace: istio-system
        path: /inject
```

Namespaces then carry only the role label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio.io/rev: prod-stable   # never needs to change again; you move the tag
```

### 3.5 Canary gateway via the Helm `gateway` chart

```bash
helm install istio-ingress-canary istio/gateway \
  -n istio-ingress \
  --set revision=1-20-2 \
  --set service.type=LoadBalancer
```

The `revision` value stamps `istio.io/rev: 1-20-2` on the gateway pod template, so the new-revision `istiod` injects and configures it. You then shift external traffic to the new gateway's LB IP and retire the old Deployment.

### 3.6 Helm-native in-place upgrade (order is mandatory)

```bash
# 1) CRDs + base first
helm upgrade istio-base istio/base -n istio-system --wait

# 2) control plane
helm upgrade istiod istio/istiod -n istio-system --wait

# 3) gateways last
helm upgrade istio-ingress istio/gateway -n istio-ingress --wait
```

For a **Helm canary**, add `--set revision=1-20-2` to a *second* `istiod` release and install it alongside the existing one:

```bash
helm install istiod-1-20-2 istio/istiod -n istio-system \
  --set revision=1-20-2 --wait
```

---

## 4. CLI walkthrough with real terminal output

### 4.1 Pre-upgrade compatibility check (always run first)

```console
$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
     To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

If deprecated/removed APIs are in use it fails loudly, e.g.:

```console
$ istioctl x precheck
Error [IST0139] (VirtualService default/reviews) The image pull secret ...
✘ Issues found when checking the cluster. Istio may not be safe to upgrade.
```

Baseline the current state:

```console
$ istioctl version
client version: 1.20.2
control plane version: 1.19.3
data plane version: 1.19.3 (24 proxies)
```

### 4.2 Install the canary control plane

```console
$ istioctl install -f istio-canary-1-20-2.yaml -y
✔ Istio core installed
✔ Istiod installed
✔ Installation complete

$ kubectl get pods -n istio-system -l app=istiod
NAME                             READY   STATUS    RESTARTS   AGE
istiod-1-19-3-6b8c9d4f7-abcde    1/1     Running   0          9d
istiod-1-19-3-6b8c9d4f7-fghij    1/1     Running   0          9d
istiod-1-20-2-7c9f5a8b2-klmno    1/1     Running   0          73s
istiod-1-20-2-7c9f5a8b2-pqrst    1/1     Running   0          73s
```

List revisions and their bindings:

```console
$ istioctl x revision list
REVISION  TAG      ISTIOD                    NAMESPACES
1-19-3    default  istiod-1-19-3 (1.19.3)    payments,bookinfo,frontend
1-20-2    <none>   istiod-1-20-2 (1.20.2)    <none>
```

### 4.3 Migrate one namespace (canary a single tenant)

```console
$ kubectl label namespace bookinfo istio.io/rev=1-20-2 istio-injection- --overwrite
namespace/bookinfo labeled

$ kubectl rollout restart deployment -n bookinfo
deployment.apps/productpage-v1 restarted
deployment.apps/reviews-v1 restarted
deployment.apps/reviews-v2 restarted
deployment.apps/reviews-v3 restarted
deployment.apps/ratings-v1 restarted
deployment.apps/details-v1 restarted
```

Confirm each proxy re-attached to the **new** `istiod`:

```console
$ istioctl proxy-status
NAME                             CLUSTER      CDS      LDS      EDS      RDS      ECDS     ISTIOD                          VERSION
details-v1-7d88...bookinfo        Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-20-2-7c9f5a8b2-klmno   1.20.2
productpage-v1-9f2...bookinfo     Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-20-2-7c9f5a8b2-klmno   1.20.2
reviews-v3-6c4...bookinfo         Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-20-2-7c9f5a8b2-pqrst   1.20.2
payments-api-84b...payments       Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-19-3-6b8c9d4f7-abcde   1.19.3
```

`istioctl version` now shows the deliberate mixed data plane — this is expected mid-migration:

```console
$ istioctl version
client version: 1.20.2
control plane version: 1.19.3, 1.20.2
data plane version: 1.19.3 (18 proxies), 1.20.2 (6 proxies)
```

### 4.4 Promote via revision tags (repeatable production flow)

```console
$ istioctl tag set prod-stable --revision 1-20-2 --overwrite
Revision 1-20-2 now pointed to by tag "prod-stable"

$ istioctl tag list
TAG          REVISION   NAMESPACES
prod-stable  1-20-2     payments,frontend
default      1-19-3
```

Every namespace labeled `istio.io/rev=prod-stable` now injects `1.20.2` on next restart — no relabeling:

```console
$ kubectl rollout restart deployment -n payments -n frontend
```

Make the canary the new default so legacy `istio-injection=enabled` namespaces also move:

```console
$ istioctl tag set default --revision 1-20-2 --overwrite
Revision 1-20-2 now pointed to by tag "default"
```

### 4.5 Decommission the old revision (only after all proxies moved)

```console
$ istioctl proxy-status | awk 'NR>1{print $NF}' | sort -u
1.20.2

$ istioctl uninstall --revision 1-19-3 -y
  Removed IstioOperator:istio-system:istio-control-plane.
  Removed Deployment:istio-system:istiod-1-19-3.
  Removed Service:istio-system:istiod-1-19-3.
  Removed MutatingWebhookConfiguration::istio-sidecar-injector-1-19-3.
✔ Uninstall complete
```

### 4.6 Rollback (canary)

Rollback is symmetric with promotion — no full-mesh swap:

```console
$ istioctl tag set prod-stable --revision 1-19-3 --overwrite
Revision 1-19-3 now pointed to by tag "prod-stable"

$ kubectl rollout restart deployment -n bookinfo
$ istioctl proxy-status -n bookinfo   # proxies snap back to istiod-1-19-3
```

---

## 5. Verification and failure diagnosis

### 5.1 The `proxy-status` state machine

| Column value | Meaning | Action |
|---|---|---|
| `SYNCED` | Proxy acknowledged the last config `istiod` sent | Healthy |
| `NOT SENT` | `istiod` has nothing of that xDS type to send (e.g. no ECDS) | Usually benign |
| `STALE` | `istiod` sent config; proxy has **not** ACKed | Investigate — the danger sign during upgrades |

A proxy stuck `STALE` after migration usually means it cannot reach the new `istiod` (NetworkPolicy, mTLS/CA mismatch, or the proxy version is *newer* than the control plane — forbidden). Confirm the config actually converged:

```console
$ istioctl proxy-config all reviews-v3-6c4xz.bookinfo -o json | jq '.configs | length'
$ istioctl proxy-config listeners productpage-v1-9f2ab.bookinfo
```

### 5.2 Injection didn't happen (the #1 canary failure)

Symptom: after `rollout restart`, pods come up with **1/1** containers instead of **2/2**.

```console
$ kubectl get pods -n bookinfo
NAME                              READY   STATUS    RESTARTS   AGE
productpage-v1-6d9c...            1/1     Running   0          40s     # <-- no sidecar
```

Diagnosis checklist:

```console
# 1) Is the namespace still carrying istio-injection (which WINS over istio.io/rev)?
$ kubectl get ns bookinfo --show-labels
NAME       STATUS   AGE   LABELS
bookinfo   Active   9d    istio-injection=enabled,istio.io/rev=1-20-2   # <-- BUG

# Fix: remove the legacy label
$ kubectl label namespace bookinfo istio-injection- --overwrite

# 2) Does a webhook exist for that revision/tag?
$ kubectl get mutatingwebhookconfiguration | grep -E 'sidecar-injector|revision-tag'
istio-sidecar-injector-1-19-3
istio-sidecar-injector-1-20-2
istio-revision-tag-prod-stable

# 3) Does the injection template render for this revision?
$ istioctl x revision tag list
$ kubectl -n istio-system get cm istio-sidecar-injector-1-20-2 -o yaml | head
```

Then re-restart the workload so admission re-runs.

### 5.3 Static config sanity with `istioctl analyze`

```console
$ istioctl analyze -n bookinfo --revision 1-20-2
✔ No validation issues found when analyzing namespace: bookinfo.
```

Warnings such as `IST0102 (namespace bookinfo) is enabled for Istio injection but no injection label found` point straight at label problems.

### 5.4 Webhook / CA conflicts between revisions

If pods intermittently fail admission with a webhook timeout, two injectors may be racing, or the old revision was uninstalled while namespaces still pointed at it:

```console
$ kubectl describe pod productpage-v1-... -n bookinfo | grep -i webhook
Warning  FailedCreate  ... failed calling webhook "sidecar-injector.istio.io":
  Post "https://istiod-1-19-3.istio-system.svc:443/inject...": service "istiod-1-19-3" not found
```

Cause: `istiod-1-19-3` was uninstalled but `bookinfo` still had `istio.io/rev=1-19-3`. Fix by repointing the namespace/tag to a live revision **before** uninstalling, then restart.

### 5.5 Rollout blocked by PodDisruptionBudget

A `rollout restart` that hangs is often a PDB with `minAvailable` equal to replica count:

```console
$ kubectl get pdb -n bookinfo
NAME         MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
reviews-pdb  3               N/A               0                     9d   # <-- 0 disruptions

$ kubectl rollout status deploy/reviews-v3 -n bookinfo
Waiting for deployment "reviews-v3" rollout to finish: 2 of 3 updated replicas are available...
```

Temporarily relax the PDB or scale up before restarting.

### 5.6 Gateway forgotten during upgrade

`istioctl proxy-status` will show a gateway proxy still on the old version while workloads are new — a supported skew, but if you uninstall the old revision the gateway's injection template disappears on its next restart:

```console
$ istioctl proxy-status | grep gateway
istio-ingressgateway-5f7...istio-system   ...   istiod-1-19-3-...   1.19.3   # <-- still old
```

Upgrade the gateway (in-place `helm upgrade` or a canary gateway) **before** decommissioning `1-19-3`.

### 5.7 Post-upgrade "definition of done" checklist

```console
# 1) Single control-plane version reported
$ istioctl version
control plane version: 1.20.2
data plane version: 1.20.2 (24 proxies)

# 2) No proxy left on the old revision
$ istioctl proxy-status | awk 'NR>1{print $NF}' | sort -u
1.20.2

# 3) No orphaned webhooks / operators for the retired revision
$ kubectl get mutatingwebhookconfiguration | grep 1-19-3   # (empty)
$ istioctl x revision list                                  # old revision gone

# 4) Clean static analysis, mesh-wide
$ istioctl analyze --all-namespaces
✔ No validation issues found when analyzing all namespaces.
```

Only when all four hold is the upgrade complete and the old control plane safe to remove.

---

## 6. References

- Canary upgrades (revisions & stable revision labels/tags): https://istio.io/latest/docs/setup/upgrade/canary/
- In-place upgrades: https://istio.io/latest/docs/setup/upgrade/in-place/
- Upgrade overview & pre-upgrade checks: https://istio.io/latest/docs/setup/upgrade/
- `istioctl tag` reference: https://istio.io/latest/docs/reference/commands/istioctl/#istioctl-tag
- `istioctl x precheck` / `analyze` / `proxy-status`: https://istio.io/latest/docs/reference/commands/istioctl/
- Sidecar injection & webhook label precedence: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Installing/upgrading with Helm (base → istiod → gateway): https://istio.io/latest/docs/setup/install/helm/
- Gateway Helm chart (`revision` value): https://istio.io/latest/docs/setup/additional-setup/gateway/
- `IstioOperator` API (`spec.revision`): https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Supported control-plane/data-plane version skew: https://istio.io/latest/docs/releases/supported-releases/
- ICA curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf