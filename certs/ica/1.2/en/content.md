# Installing Istio in Sidecar or Ambient Mode

> **ICA Domain 1 — Installation & Configuration · Topic 1.2 (exam weight: 5)**
> Profile: Platform Architect / SRE — production-grade depth.

---

## 1. The architectural problem: why installation mode is a Day-0 decision

Installing Istio is not "deploy a chart and move on." The mode you pick at install time — **sidecar** or **ambient** — dictates the data-plane topology, the per-pod resource tax, the mTLS boundary, and the blast radius of every future control-plane upgrade. Getting it wrong is expensive to reverse: a fleet of 4,000 pods each carrying a 60–120 MiB Envoy sidecar is a different cost and upgrade model than a handful of node-level `ztunnel` DaemonSet pods.

The problem Istio solves is the classic one: you want mTLS, L7 telemetry, retries, and traffic shifting **without editing application code**. The disagreement is *where the proxy lives*:

- **Sidecar mode** injects an Envoy proxy into every application pod. Traffic is intercepted with `iptables` (or the Istio CNI plugin) and redirected through the sidecar. Full L7 for every workload, but you pay the proxy cost per pod and every upgrade means rolling every workload.
- **Ambient mode** (GA since Istio **1.24**, Nov 2024) removes the per-pod sidecar. A per-node **`ztunnel`** DaemonSet provides the **secure L4 overlay** (mTLS, identity, TCP telemetry) over the **HBONE** tunnel; L7 features (HTTP routing, `VirtualService`, header manipulation, L7 authorization) are added *only where needed* by deploying a **waypoint proxy** per namespace or service account.

The production consequence: ambient decouples "get mTLS onto everything" from "pay for full L7 on everything." That is the single most important trade-off in this topic.

```
 SIDECAR MODE                          AMBIENT MODE
 ┌───────────────────┐                 ┌───────────────────┐
 │  Pod              │                 │  Pod              │   ← no injected proxy
 │  ┌─────┐ ┌──────┐ │                 │  ┌─────┐          │
 │  │ app │ │envoy │ │  L4+L7          │  │ app │          │
 │  └─────┘ └──────┘ │  per pod        │  └─────┘          │
 └───────────────────┘                 └────────┬──────────┘
        every pod                               │ HBONE (15008)
                                        ┌────────▼──────────┐
                                        │ ztunnel (per node)│  ← L4: mTLS, identity, telemetry
                                        └────────┬──────────┘
                                                 │ (only if L7 needed)
                                        ┌────────▼──────────┐
                                        │ waypoint (Envoy)  │  ← L7: routing, authz, per-ns/SA
                                        └───────────────────┘
```

---

## 2. Technical comparisons

### 2.1 Data-plane modes

| Dimension | Sidecar | Ambient (ztunnel only) | Ambient (+ waypoint) |
|---|---|---|---|
| Proxy placement | Per pod (Envoy) | Per node (`ztunnel`, DaemonSet) | Per node + per-ns/SA Envoy |
| L4 mTLS (STRICT-capable) | ✅ | ✅ | ✅ |
| L7 (HTTP routing, retries, L7 authz) | ✅ | ❌ | ✅ |
| Overhead per pod | High (60–120 MiB + CPU) | ~0 (no injected container) | ~0 in pods; L7 cost is shared |
| Injection restart required | ✅ (pod restart to add/remove) | ❌ (namespace label, no restart) | ❌ |
| Upgrade blast radius | Roll every workload | Roll DaemonSet + control plane | Roll waypoints + DaemonSet |
| CNI plugin | Optional (recommended) | **Required** (`istio-cni`) | **Required** |
| Transport | Envoy↔Envoy mTLS | **HBONE** over TCP/15008 | HBONE + waypoint |
| Pod-level `NET_ADMIN`/init container | Yes (unless CNI) | **No** (CNI handles redirection) | No |
| Maturity | Stable since 1.5 | GA 1.24 | GA 1.24 |

### 2.2 Installation methods

| Method | Best for | Idempotent | Notes |
|---|---|---|---|
| `istioctl install` | Interactive, canary upgrades, POCs | ✅ (reconciles to `IstioOperator`) | Validates before applying; `verify-install` available |
| **Helm** (`istio/base`, `istiod`, `istio-cni`, `ztunnel`, gateways) | GitOps / Argo CD / Flux, fine-grained control | ✅ | Recommended for production/GitOps; ordered chart install |
| In-cluster Operator | (legacy) | — | **Deprecated & removed** — do not use in new clusters |

### 2.3 Configuration profiles (`istioctl profile list`)

| Profile | Installs | Use case |
|---|---|---|
| `default` | istiod + ingress gateway | Production baseline (sidecar) |
| `demo` | istiod + ingress + egress, high tracing | Learning/labs — **not** production (verbose, permissive) |
| `minimal` | istiod only | Build up components à la carte |
| `ambient` | istiod + `istio-cni` + `ztunnel` | Ambient data plane |
| `empty` | nothing | Base for fully custom Helm/overlay installs |
| `preview` | default + experimental features | Testing upcoming APIs |

---

## 3. Complete manifests and installation

### 3.1 Prerequisites

```bash
$ kubectl version --short
Client Version: v1.31.2
Server Version: v1.31.2

# Download a pinned Istio release — never "latest" in production
$ curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.2 sh -
$ cd istio-1.24.2
$ export PATH=$PWD/bin:$PATH
$ istioctl version --remote=false
client version: 1.24.2

# Pre-flight: confirm the cluster can host Istio
$ istioctl x precheck
✔ No issues found when checking the cluster. Istio is safe to install or upgrade!
  To get started, check out https://istio.io/latest/docs/setup/getting-started/
```

### 3.2 Sidecar mode — production `IstioOperator`

Pinning the revision (`revision: 1-24-2`) is what makes **canary control-plane upgrades** possible: two `istiod` revisions run side by side and namespaces migrate by label.

```yaml
# istio-sidecar-prod.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-sidecar-prod
  namespace: istio-system
spec:
  profile: default
  revision: 1-24-2                 # enables canary upgrades
  meshConfig:
    accessLogFile: /dev/stdout     # observability; drop or sample at scale
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true   # avoid app-before-proxy races
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"        # DNS proxying
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
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: LoadBalancer
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
  values:
    global:
      proxy:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: "2"
            memory: 1Gi
    pilot:
      autoscaleEnabled: true
```

```bash
$ istioctl install -f istio-sidecar-prod.yaml -y
        |\
        | \
        |  \
        |   \
      /||    \
     / ||     \
    /  ||      \
   /   ||       \
  /    ||        \
 /     ||         \
/______||__________\
____________________
  \__       _____/
     \_____/

✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Installation complete                                                 Made this installation the default for cluster-wide operations.
```

**Enabling sidecar injection** — namespace label, then restart existing workloads:

```yaml
# namespace-injection.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    istio.io/rev: 1-24-2        # revision label — NOT istio-injection=enabled when using revisions
```

```bash
$ kubectl apply -f namespace-injection.yaml
namespace/payments configured

# Existing pods do NOT get a sidecar until restarted:
$ kubectl -n payments rollout restart deployment/checkout
deployment.apps/checkout restarted

$ kubectl -n payments get pod -l app=checkout
NAME                        READY   STATUS    RESTARTS   AGE
checkout-7d9c8b6f4c-2xk9p   2/2     Running   0          25s     # 2/2 = app + istio-proxy
```

> **Gotcha (SRE):** `istio-injection=enabled` and `istio.io/rev=<rev>` are mutually exclusive on a namespace. If both are present, injection silently uses the *default* revision, not the labelled one — a classic cause of "my canary upgrade didn't take."

### 3.3 Ambient mode — install and enroll

```yaml
# istio-ambient-prod.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-ambient-prod
  namespace: istio-system
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    cni:
      enabled: true
    ztunnel:
      enabled: true
  values:
    cni:
      # For OpenShift/GKE/EKS the CNI bin dir differs — verify per platform!
      cniBinDir: /opt/cni/bin
      cniConfDir: /etc/cni/net.d
```

```bash
$ istioctl install -f istio-ambient-prod.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ CNI installed 🪢
✔ Ztunnel installed 🔒
✔ Installation complete

$ kubectl get daemonset -n istio-system
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
istio-cni-node   3     3         3       3            3           90s
ztunnel          3     3         3       3            3           88s
```

**Enroll a namespace into ambient** — a single label, **no pod restart**:

```yaml
# ambient-enroll.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: storefront
  labels:
    istio.io/dataplane-mode: ambient
```

```bash
$ kubectl apply -f ambient-enroll.yaml
namespace/storefront configured

# Note: pods stay 1/1 — no injected container, yet they are in the mesh
$ kubectl -n storefront get pod
NAME                       READY   STATUS    RESTARTS   AGE
web-6c8f7d9b54-nq2pl       1/1     Running   0          14m
```

**Add L7 only where needed** — deploy a waypoint proxy (uses the Kubernetes **Gateway API**, which must be installed):

```bash
# Install Gateway API CRDs (required for ambient waypoints / gateways)
$ kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
...

# Generate + deploy a namespace-scoped waypoint
$ istioctl waypoint apply -n storefront --enroll-namespace
✓ waypoint storefront/waypoint applied
namespace storefront labeled with "istio.io/use-waypoint: waypoint"

$ kubectl -n storefront get gtw
NAME       CLASS            ADDRESS         PROGRAMMED   AGE
waypoint   istio-waypoint   10.96.140.11    True         20s
```

Equivalent declarative form (GitOps-friendly):

```yaml
# waypoint.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: storefront
  labels:
    istio.io/waypoint-for: service   # or: workload / all
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

### 3.4 Helm (GitOps / production) — ordered install

Charts **must** be installed in dependency order. `base` provides CRDs and cluster roles; `istiod` the control plane; then the data-plane charts.

```bash
$ helm repo add istio https://istio-release.storage.googleapis.com/charts
$ helm repo update
$ kubectl create namespace istio-system

# 1) CRDs + cluster resources
$ helm install istio-base istio/base -n istio-system --version 1.24.2 --set defaultRevision=1-24-2
NAME: istio-base
STATUS: deployed

# 2) Control plane
$ helm install istiod istio/istiod -n istio-system --version 1.24.2 \
    --set revision=1-24-2 --wait
STATUS: deployed

# --- For AMBIENT, also: ---
# 3) CNI (required for ambient)
$ helm install istio-cni istio/cni -n istio-system --version 1.24.2 --set profile=ambient --wait
# 4) ztunnel
$ helm install ztunnel istio/ztunnel -n istio-system --version 1.24.2 --wait
STATUS: deployed
```

---

## 4. Verification and failure diagnosis

### 4.1 Post-install verification ladder

```bash
# 1. Is the installed state what the manifest claims?
$ istioctl verify-install -f istio-sidecar-prod.yaml
✔ Istio is installed and verified successfully

# 2. Control plane healthy?
$ kubectl -n istio-system get pods
NAME                              READY   STATUS    RESTARTS   AGE
istiod-1-24-2-6b9f8d7c4d-abcde    1/1     Running   0          4m

# 3. Are data-plane proxies in sync with istiod? (the single most useful command)
$ istioctl proxy-status
NAME                                   CLUSTER   CDS      LDS      EDS      RDS      ISTIOD                          VERSION
checkout-7d9c8b6f4c-2xk9p.payments     cluster1  SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-24-2-6b9f8d7c4d-abcde  1.24.2
web-6c8f7d9b54-nq2pl.storefront        cluster1  SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-24-2-6b9f8d7c4d-abcde  1.24.2

# 4. Config validity / anti-pattern lint
$ istioctl analyze -A
✔ No validation issues found when analyzing all namespaces.

# 5. Ambient: confirm ztunnel sees the workload
$ istioctl ztunnel-config workloads -n storefront
NAMESPACE    POD NAME              ADDRESS      NODE       WAYPOINT   PROTOCOL
storefront   web-6c8f7d9b54-nq2pl  10.244.1.7   worker-1   waypoint   HBONE
```

### 4.2 Failure playbook

| Symptom | Command to confirm | Root cause / fix |
|---|---|---|
| Pod is `1/1` but should be `2/2` (sidecar) | `istioctl analyze -n <ns>` → "no sidecar" | Namespace label missing/wrong revision; **workloads not restarted** after labeling |
| `proxy-status` shows `STALE` / `NOT SENT` | `istioctl proxy-status` | istiod↔proxy push failure; check `istioctl proxy-config all <pod>` and istiod logs |
| App fails to start under sidecar | pod events / `kubectl logs -c istio-init` | Race: set `holdApplicationUntilProxyStarts: true`; or missing `NET_ADMIN` — use CNI |
| Ambient traffic bypasses mesh (no mTLS) | `kubectl -n istio-system logs ds/istio-cni-node` | **CNI not installed / wrong `cniBinDir`** for the platform; ztunnel never captures traffic |
| Ambient L7 policy has no effect | `istioctl waypoint status -n <ns>` | No waypoint deployed, or namespace/service not labeled `istio.io/use-waypoint` |
| Waypoint `Gateway` `PROGRAMMED: False` | `kubectl get gtw -n <ns> -o yaml` | Gateway API CRDs missing, or `gatewayClassName` ≠ `istio-waypoint` |
| Upgrade rolled back / two control planes fight | `kubectl get pods -n istio-system -l app=istiod` | Mixed default + revisioned install; standardize on `revision:` + `defaultRevision` |

**Diagnostic deep-dives:**

```bash
# Full Envoy config dump for one sidecar (clusters, listeners, routes, endpoints)
$ istioctl proxy-config all checkout-7d9c8b6f4c-2xk9p.payments

# mTLS status for a specific workload (is STRICT actually in effect?)
$ istioctl proxy-config secret checkout-7d9c8b6f4c-2xk9p.payments | head

# Ambient: is ztunnel enforcing mTLS certs for this identity?
$ istioctl ztunnel-config certificates -n storefront

# Live proxy sync / push errors from the control plane
$ kubectl -n istio-system logs deploy/istiod-1-24-2 | grep -iE "push|error|nack"
```

### 4.3 Clean uninstall (idempotent)

```bash
# Sidecar/ambient install created via istioctl:
$ istioctl uninstall --purge -y
$ kubectl delete namespace istio-system

# Helm:
$ helm uninstall ztunnel istio-cni istiod istio-base -n istio-system
```

---

## 5. Production guidance summary

- **Default to a pinned revision** (`revision:` + `defaultRevision`) from day one — it is the *only* path to zero-downtime canary control-plane upgrades. Retrofitting revisions onto a live mesh means restarting every workload.
- **Choose ambient when** the fleet is large, most workloads need only mTLS + L4 telemetry, and per-pod overhead matters. Add waypoints surgically for the services that genuinely need L7.
- **Choose sidecar when** you need mature, ubiquitous L7 per workload, `VirtualService`/`EnvoyFilter` semantics everywhere, or your platform doesn't yet support the ambient CNI cleanly.
- **`istio-cni` is mandatory for ambient** — validate `cniBinDir`/`cniConfDir` against your platform (GKE, EKS, OpenShift, k3s all differ). A silent CNI misconfig is the #1 "ambient does nothing" failure.
- **Never use `demo` in production** — it is permissive and high-cardinality; start from `default` or `ambient`.
- Ambient waypoints and gateways require the **Kubernetes Gateway API** CRDs installed first.

---

## Referencias

- Istio — Installation methods overview: https://istio.io/latest/docs/setup/install/
- Install with `istioctl`: https://istio.io/latest/docs/setup/install/istioctl/
- Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Installation configuration profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Ambient mode — Getting started: https://istio.io/latest/docs/ambient/getting-started/
- Ambient mode — Install (istioctl / Helm): https://istio.io/latest/docs/ambient/install/
- ztunnel architecture: https://istio.io/latest/docs/ambient/architecture/ztunnel/
- Waypoint proxies: https://istio.io/latest/docs/ambient/usage/waypoint/
- HBONE overlay: https://istio.io/latest/docs/ambient/architecture/hbone/
- Sidecar injection: https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Canary control-plane upgrades (revisions): https://istio.io/latest/docs/setup/upgrade/canary/
- `IstioOperator` API reference: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Istio CNI plugin: https://istio.io/latest/docs/setup/additional-setup/cni/
- Kubernetes Gateway API: https://gateway-api.sigs.k8s.io/
- Istio 1.24 release notes (ambient GA): https://istio.io/latest/news/releases/1.24.x/announcing-1.24/
- ICA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf