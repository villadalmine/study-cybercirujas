# 1.1 — Installing Istio with istioctl or Helm

*ICA domain 1 · exam weight 5 · authoring language: English*

---

## 1. The production problem: installation is an architectural commitment, not a bootstrap step

A service mesh control plane is not an application you `kubectl apply` once and forget. `istiod` is an in-cluster certificate authority (it signs the mTLS identities of every workload), an xDS server (it pushes Envoy configuration to every sidecar), and the target of two admission webhooks that sit in the *critical path of pod creation* for every injected namespace. The way you install it therefore decides three things you cannot easily change later:

1. **How you upgrade.** The single most common Istio outage is an in-place control-plane upgrade that breaks sidecar↔istiod xDS compatibility mid-flight. Your installation tool determines whether upgrades are *in-place* (risky, all-at-once) or *revision-based canary* (two control planes side by side, data plane migrated namespace by namespace). This is the reason the tool matters.
2. **How installation drift is detected and reconciled.** GitOps (Argo CD / Flux) needs a *declarative artifact* it can diff against live state. `istioctl install` mutates the cluster imperatively; Helm and rendered manifests produce artifacts a reconciler can own.
3. **The blast radius of a mistake.** If the mutating webhook is installed but `istiod` is not `Ready`, *every pod creation in an injected namespace fails* with `failed calling webhook sidecar-injector.istio.io`. Install ordering (CRDs → base RBAC → istiod → gateways) is not cosmetic; getting it wrong wedges the cluster.

The choice, concretely, is between **`istioctl`** (an opinionated installer that wraps the `IstioOperator` API, ships an embedded validator, and understands revisions natively) and **Helm** (three plain charts you compose yourself, native to any GitOps or templating pipeline). A third path — the **in-cluster operator** (`istioctl operator init`) — is **deprecated since Istio 1.23 and removed in newer releases**; do not build new platforms on it. Note the naming trap: the *in-cluster operator controller* is dead, but the *`IstioOperator` API object* (`install.istio.io/v1alpha1`) lives on as the configuration input to `istioctl install -f`. They are different things.

---

## 2. Installation methods compared

| Dimension | `istioctl install` | Helm (`base` + `istiod` + `gateway`) | In-cluster Operator *(deprecated)* |
|---|---|---|---|
| Configuration surface | `IstioOperator` CR / `--set` | Helm `values.yaml` per chart | `IstioOperator` CR reconciled by a pod |
| Pre-flight validation | **Built in** (`x precheck`, `verify-install`) | None (you script it) | None |
| CRD & ordering handling | Automatic, single command | **Manual** — you must install `base` first | Automatic |
| Canary revisions | First-class (`--set revision=`) | Supported (`revision`/`revisionTags` values) | Supported but clunky |
| GitOps / declarative artifact | Via `istioctl manifest generate` | **Native** — charts are the artifact | CR is the artifact, controller reconciles |
| Rollback model | Re-install prior revision | `helm rollback` | Edit/kubectl apply prior CR |
| Drift reconciliation | None (imperative) | Reconciler-driven (Argo/Flux) | Continuous (the controller) |
| Ambient mode components | `--set profile=ambient` | `cni` + `ztunnel` charts | n/a |
| Istio's recommendation | Default for most users | **Recommended for production / GitOps** | **Do not use — removed** |

**How to choose, in one line each:**

- **`istioctl`** when you want the shortest correct path, embedded validation, and interactive canary upgrades — day-1 installs, PoCs, and clusters managed imperatively.
- **Helm** when a reconciler (Argo CD, Flux) must own mesh state, when you need per-chart lifecycle (upgrade `istiod` without touching CRDs), or when policy requires every change to arrive as a reviewed manifest.
- A hybrid many platforms adopt: author an `IstioOperator`, run `istioctl manifest generate -f iop.yaml` to produce a rendered manifest, and commit *that* to Git — validation from `istioctl`, declarative ownership from GitOps.

---

## 3. Configuration profiles

A profile is a named starting set of components and values. Everything you set afterward is a delta on top of the profile. Both installers accept `profile=`.

| Component | `default` | `demo` | `minimal` | `ambient` | `empty` | `preview` |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| `istiod` (control plane) | ✔ | ✔ | ✔ | ✔ | | ✔ |
| `istio-ingressgateway` | ✔ | ✔ | | | | ✔ |
| `istio-egressgateway` | | ✔ | | | | |
| `istio-cni` | | | | ✔ | | |
| `ztunnel` (ambient data plane) | | | | ✔ | | |

- **`default`** — production baseline: istiod + ingress gateway, conservative resources. Start here.
- **`demo`** — high verbosity, egress gateway on, tracing sampling at 100%. **Never in production** — it's tuned for tutorials, not cost or signal-to-noise.
- **`minimal`** — control plane only; you install gateways separately (e.g. as their own Helm release per team).
- **`ambient`** — sidecar-less data plane (`ztunnel` + CNI). Different topic, but this is where it's enabled.
- **`empty` / `preview`** — build-your-own baseline / early-access features respectively.

Inspect and diff profiles before committing:

```console
$ istioctl profile list
Istio configuration profiles:
    ambient
    default
    demo
    empty
    external
    minimal
    openshift
    preview
    remote
    stable

$ istioctl profile dump default | head -n 20
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    base:
      enabled: true
    pilot:
      enabled: true
  profile: default
  ...

$ istioctl profile diff default demo | head -n 12
 The difference between profiles: default and demo is:
   components:
     egressGateways:
-      enabled: false
+      enabled: true
     ...
```

---

## 4. Installing with istioctl (the `IstioOperator` API)

### 4.1 Pre-flight — always run before touching the cluster

```console
$ istioctl version --remote=false
client version: 1.24.1

$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

`precheck` verifies Kubernetes version support, that no conflicting install exists, that required cluster permissions are present, and that no unsupported/removed APIs are in play. A failing precheck looks like this — treat it as a hard stop:

```console
$ istioctl x precheck
✘ Kubernetes version v1.24.0 is not supported by Istio 1.24.1 (>=1.28.0, <=1.31.x recommended)
Error: 1 error occurred:
    * check failed
```

### 4.2 Quick imperative install (dev / PoC)

```console
$ istioctl install --set profile=default -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster-wide operations.
```

### 4.3 Production install from a declarative `IstioOperator` (the real pattern)

Do **not** ship `--set` flags to production — they are undocumented drift. Author a complete, reviewable manifest. This one is a full, syntactically valid production baseline: HA istiod behind an HPA + PDB, a `LoadBalancer` ingress gateway, tuned sidecar resources, JSON access logs, distributed tracing, and a named **revision** so the very next upgrade can be a canary.

```yaml
# iop-prod.yaml — production control-plane definition
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-control-plane
  namespace: istio-system
spec:
  profile: default
  # Naming the revision now makes the FIRST upgrade a canary, not an in-place swap.
  revision: 1-24-1
  meshConfig:
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true   # app waits for Envoy — no cold-start 503s
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
    extensionProviders:
      - name: otel-tracing
        opentelemetry:
          service: opentelemetry-collector.observability.svc.cluster.local
          port: 4317
  components:
    pilot:
      k8s:
        replicaCount: 2
        resources:
          requests:
            cpu: "500m"
            memory: "2048Mi"
          limits:
            memory: "4096Mi"
        hpaSpec:
          minReplicas: 2
          maxReplicas: 5
          metrics:
            - type: Resource
              resource:
                name: cpu
                target:
                  type: Utilization
                  averageUtilization: 80
        podDisruptionBudget:
          minAvailable: 1
        env:
          - name: PILOT_ENABLE_STATUS
            value: "true"
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: LoadBalancer
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: http2
                port: 80
                targetPort: 8080
              - name: https
                port: 443
                targetPort: 8443
          resources:
            requests:
              cpu: "500m"
              memory: "256Mi"
            limits:
              memory: "1024Mi"
          hpaSpec:
            minReplicas: 2
            maxReplicas: 5
          podDisruptionBudget:
            minAvailable: 1
          serviceAnnotations:
            service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    egressGateways:
      - name: istio-egressgateway
        enabled: false
  values:
    global:
      proxy:
        # Per-sidecar footprint — multiplied by every workload in the mesh.
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "2000m"
            memory: "1024Mi"
        logLevel: warning
      logging:
        level: "default:info"
```

Apply it, generate the GitOps artifact, and diff live state against the definition:

```console
$ istioctl install -f iop-prod.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete
Made this installation the default for cluster-wide operations.

# Render the same manifest for review / commit to Git — no cluster mutation:
$ istioctl manifest generate -f iop-prod.yaml > rendered/istio-1-24-1.yaml

# Diff the live cluster against what the manifest declares (drift detection):
$ istioctl manifest diff rendered/istio-1-24-1.yaml <(istioctl manifest generate -f iop-prod.yaml)
Manifests are identical
```

Because a `revision` is set, workloads opt in with a **revision label**, not the legacy `istio-injection=enabled`:

```console
$ kubectl label namespace payments istio.io/rev=1-24-1
namespace/payments labeled

$ kubectl get namespace payments --show-labels
NAME       STATUS   AGE   LABELS
payments   Active   9d    istio.io/rev=1-24-1
```

---

## 5. Installing with Helm (chart-by-chart, GitOps-native)

Helm is the production-recommended path when a reconciler must own mesh state. There are three charts and **the order is not optional**: `base` (CRDs + cluster RBAC) → `istiod` (control plane) → `gateway` (one release per gateway). Installing `istiod` before its CRDs exist fails; installing a gateway before `istiod` is `Ready` produces a pod that can never pull config.

```console
$ helm repo add istio https://istio-release.storage.googleapis.com/charts
"istio" has been added to your repositories

$ helm repo update
Hang tight while we grab the latest from your chart repositories...
Update Complete. ⎈Happy Helming!⎈

$ helm search repo istio/ --versions | head -n 6
NAME                    CHART VERSION   APP VERSION     DESCRIPTION
istio/base              1.24.1          1.24.1          Helm chart for deploying Istio cluster resources
istio/cni               1.24.1          1.24.1          Helm chart for Istio CNI components
istio/gateway           1.24.1          1.24.1          Helm chart for deploying Istio gateways
istio/istiod            1.24.1          1.24.1          Helm chart for Istio control plane
istio/ztunnel           1.24.1          1.24.1          Helm chart for Istio ztunnel (ambient)
```

### 5.1 Step 1 — CRDs and cluster resources (`base`)

```console
$ kubectl create namespace istio-system
namespace/istio-system created

$ helm install istio-base istio/base -n istio-system \
    --set defaultRevision=1-24-1 --version 1.24.1
NAME: istio-base
LAST DEPLOYED: ...
NAMESPACE: istio-system
STATUS: deployed
REVISION: 1
```

### 5.2 Step 2 — control plane (`istiod`), matching the istioctl production values

`istiod-values.yaml`:

```yaml
# istiod-values.yaml
revision: "1-24-1"
pilot:
  autoscaleEnabled: true
  autoscaleMin: 2
  autoscaleMax: 5
  cpu:
    targetAverageUtilization: 80
  resources:
    requests:
      cpu: 500m
      memory: 2048Mi
    limits:
      memory: 4096Mi
  podDisruptionBudget:
    minAvailable: 1
global:
  proxy:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 2000m
        memory: 1024Mi
    logLevel: warning
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
  enableTracing: true
  defaultConfig:
    holdApplicationUntilProxyStarts: true
```

```console
$ helm install istiod-1-24-1 istio/istiod -n istio-system \
    -f istiod-values.yaml --version 1.24.1 --wait
NAME: istiod-1-24-1
STATUS: deployed
REVISION: 1
...
Istio control plane installed with revision "1-24-1".
```

### 5.3 Step 3 — ingress gateway (its own release, own namespace)

```console
$ kubectl create namespace istio-ingress
$ kubectl label namespace istio-ingress istio.io/rev=1-24-1

$ helm install istio-ingressgateway istio/gateway -n istio-ingress \
    --set service.type=LoadBalancer \
    --set autoscaling.minReplicas=2 --set autoscaling.maxReplicas=5 \
    --version 1.24.1 --wait
NAME: istio-ingressgateway
STATUS: deployed
REVISION: 1
```

### 5.4 Confirm the release set

```console
$ helm ls -n istio-system
NAME            NAMESPACE       REVISION  STATUS      CHART           APP VERSION
istio-base      istio-system    1         deployed    base-1.24.1     1.24.1
istiod-1-24-1   istio-system    1         deployed    istiod-1.24.1   1.24.1

$ helm ls -n istio-ingress
NAME                    NAMESPACE       REVISION  STATUS    CHART           APP VERSION
istio-ingressgateway    istio-ingress   1         deployed  gateway-1.24.1  1.24.1
```

---

## 6. Revisions and canary control-plane upgrades

This is the exam's *point* — the reason the topic exists. An **in-place** upgrade (`helm upgrade istiod`, or `istioctl upgrade`) mutates the running control plane; every sidecar re-syncs against the new xDS at once, and if there's an incompatibility the whole mesh degrades simultaneously with no clean rollback. A **canary** upgrade runs the new control plane *alongside* the old under a distinct `revision`, then migrates the data plane namespace by namespace by re-labeling and restarting — reversible at every step.

**istioctl canary:**

```console
# Install the new revision beside the running one (both control planes live):
$ istioctl install -f iop-1-24-2.yaml --set revision=1-24-2 -y

$ kubectl get pods -n istio-system -l app=istiod
NAME                            READY   STATUS    RESTARTS   AGE
istiod-1-24-1-6b8f...           1/1     Running   0          21d
istiod-1-24-2-7c9a...           1/1     Running   0          40s

# Migrate ONE namespace: relabel + rolling restart so sidecars re-inject from new istiod.
$ kubectl label namespace payments istio.io/rev=1-24-2 --overwrite
$ kubectl rollout restart deployment -n payments

# Verify each proxy now points at the new control plane, then move on.
$ istioctl proxy-status | grep payments
checkout-7d9f...payments   ...   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-24-2-7c9a...   1.24.2

# Rollback is just the reverse label + restart — the old istiod never went away.
```

**Helm canary** is the same principle with a second `istiod` release under a new revision (`helm install istiod-1-24-2 istio/istiod -n istio-system --set revision=1-24-2`), then optionally moving the **default revision tag** so unlabeled namespaces follow the new plane without being individually relabeled:

```console
$ istioctl tag set default --revision 1-24-2 --overwrite
$ istioctl tag list
TAG      REVISION   NAMESPACES
default  1-24-2     2
```

---

## 7. Verification and failure diagnosis

### 7.1 The verification ladder — run top to bottom

```console
# 1. Control-plane pods healthy?
$ kubectl get pods -n istio-system
NAME                            READY   STATUS    RESTARTS   AGE
istiod-1-24-1-6b8f5c9d7-abcde   1/1     Running   0          3m

# 2. Did every declared object actually get created and match the spec?
$ istioctl verify-install -f iop-prod.yaml
✔ ClusterRole: istiod-clusterrole-istio-system.rbac.authorization.k8s.io checked successfully
✔ ServiceAccount: istiod.istio-system checked successfully
✔ Deployment: istiod-1-24-1.istio-system checked successfully
✔ Service: istiod.istio-system checked successfully
✔ MutatingWebhookConfiguration: istio-sidecar-injector-1-24-1 checked successfully
Checked 15 custom resource definitions
Checked 1 Istio Deployments
✔ Istio is installed and verified successfully

# 3. Client and control-plane versions agree?
$ istioctl version
client version: 1.24.1
control plane version: 1.24.1
data plane version: 1.24.1 (7 proxies)

# 4. Config-level lint across the whole cluster (mesh-wide misconfig, not just install):
$ istioctl analyze --all-namespaces
✔ No validation issues found when analyzing all namespaces.

# 5. Is every sidecar in sync with istiod? SYNCED across the board is the goal.
$ istioctl proxy-status
NAME                          CLUSTER      CDS      LDS      EDS      RDS      ISTIOD                  VERSION
checkout-7d9f.payments        Kubernetes   SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-24-1-6b8f...   1.24.1
```

### 7.2 Failure playbook

| Symptom (what you see) | Root cause | Diagnose | Fix |
|---|---|---|---|
| `Internal error ... failed calling webhook "sidecar-injector.istio.io"` on *every* pod create | Mutating webhook exists but `istiod` is not `Ready` (crashed, wrong revision, or deleted) | `kubectl get mutatingwebhookconfiguration`; `kubectl get pods -n istio-system`; `kubectl logs deploy/istiod-1-24-1 -n istio-system` | Restore/ready istiod, or delete the orphaned webhook if istiod is gone |
| Helm `no matches for kind "IstioOperator"` / CRD errors | `base` chart not installed first | `kubectl get crd | grep istio.io` | `helm install istio-base` **before** `istiod` |
| Pod runs but has **no sidecar** (`1/1`, expected `2/2`) | Namespace not labeled, or labeled `istio-injection=enabled` while the install uses a **revision** | `kubectl get ns -L istio-injection,istio.io/rev`; `istioctl analyze -n <ns>` | Apply the matching `istio.io/rev=<rev>` label and restart the workload |
| `proxy-status` shows `STALE` / `NOT SENT` for a workload | Sidecar can't reach istiod (network policy, mTLS/cert issue) or config push failed | `istioctl proxy-config all <pod>`; `kubectl logs <pod> -c istio-proxy` | Fix connectivity to `istiod:15012`; check CA / cert rotation |
| Ingress gateway `EXTERNAL-IP` stuck `<pending>` | No LB provider (bare metal / missing cloud controller) | `kubectl get svc -n istio-ingress` | Install MetalLB, or use `NodePort`/`ClusterIP` + external LB |
| `istioctl version` shows control plane ≠ data plane after upgrade | Data plane not migrated to the new revision | `istioctl proxy-status` (ISTIOD column) | Relabel namespaces to new revision and `kubectl rollout restart` |

Two commands that resolve most of the above:

```console
# Which control plane injected this pod, and is it in sync?
$ istioctl proxy-status checkout-7d9f5.payments

# Is the mutating webhook present, and pointing at a live service?
$ kubectl get mutatingwebhookconfiguration -l app=sidecar-injector \
    -o custom-columns=NAME:.metadata.name,REV:.metadata.labels.istio\\.io/rev
NAME                            REV
istio-sidecar-injector-1-24-1   1-24-1
```

**Uninstall / cleanup** (leave nothing that wedges the next install):

```console
$ istioctl uninstall --purge -y          # removes all revisions + shared cluster resources
# Helm equivalent, in reverse install order:
$ helm uninstall istio-ingressgateway -n istio-ingress
$ helm uninstall istiod-1-24-1 -n istio-system
$ helm uninstall istio-base -n istio-system
$ kubectl delete namespace istio-system istio-ingress
```

---

## 8. References

- Install with `istioctl` — https://istio.io/latest/docs/setup/install/istioctl/
- Install with Helm — https://istio.io/latest/docs/setup/install/helm/
- Configuration profiles — https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Customizing the configuration (`IstioOperator`) — https://istio.io/latest/docs/setup/additional-setup/customize-installation/
- `IstioOperator` API reference — https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Canary upgrades with revisions — https://istio.io/latest/docs/setup/upgrade/canary/
- Stable revision labels (revision tags) — https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels
- Getting started / getting help — https://istio.io/latest/docs/setup/getting-started/
- Operator install deprecation notice — https://istio.io/latest/docs/setup/install/operator/
- `istioctl` command reference — https://istio.io/latest/docs/reference/commands/istioctl/
- Istio release artifacts (Helm repo, charts) — https://github.com/istio/istio and https://istio-release.storage.googleapis.com/charts
- CNCF ICA curriculum — https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf