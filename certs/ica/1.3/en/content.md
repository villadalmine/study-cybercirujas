# Topic 1.3 — Customizing your Istio Installation

> **Exam domain:** Installing, Upgrading & Configuring Istio · **Weight:** 5
> **Level:** Production SRE / Platform Architect

A default `istioctl install` gives you a working mesh, but it is *not* a production mesh. Customization is where you encode your organization's requirements into the control plane: high availability of `istiod`, right-sized proxy resources, gateway topology, access-log format, outbound egress policy, revision-based upgrade strategy, and observability wiring. This topic covers the four supported configuration surfaces — **profiles**, the **`IstioOperator` API** (used as *input* to `istioctl`, not as an in-cluster controller), **Helm values**, and **`MeshConfig`** — and how they compose.

---

## 1. Motivation and the production architectural problem

Istio's control plane (`istiod`) is a single point of failure for *config distribution*. If `istiod` is down, existing data-plane proxies keep serving traffic from their last-pushed configuration (fail-static), but no new endpoints, no new certificates, and no new sidecar injections happen. A default single-replica install with default requests/limits will:

- Be evicted or OOM-killed during a large xDS push (thousands of endpoints), taking config propagation with it.
- Be rescheduled onto any node, causing a full-mesh config recompute and push storm.
- Reject nothing at the mesh boundary, because the default `outboundTrafficPolicy` is `ALLOW_ANY` — every workload can reach any external host, defeating the point of a service mesh at the security perimeter.

The architectural problem customization solves is **turning a demo into an SLO-bearing platform component**: bounded blast radius on upgrade (revisions/canary), predictable resource behaviour under push load (requests/limits + HPA + PDB), a hardened egress posture (`REGISTRY_ONLY`), and structured telemetry your existing pipeline can ingest (access logs + `extensionProviders`).

There is a second, subtler problem: **reproducibility and rollback.** An install driven by ad-hoc `--set` flags is not diffable and cannot be reliably reproduced. Everything below is expressed as declarative artifacts (`IstioOperator` YAML or Helm `values.yaml`) that live in Git, render deterministically, and diff cleanly against the running state.

---

## 2. Technical comparison of the installation surfaces

### 2.1 Installation methods

| Method | Mechanism | HA / GitOps fit | Deprecation status | When to choose |
|---|---|---|---|---|
| `istioctl install` | Renders `IstioOperator` → manifests, applies them, runs post-install validation | Good; imperative apply, but config is declarative | Supported; **recommended for most users** | Interactive installs, quick canary revisions, validation built in |
| Helm charts (`base`, `istiod`, `gateway`, `cni`, `ztunnel`) | Standard Helm templating | Best for GitOps (Argo/Flux), fine-grained lifecycle per chart | Supported; **recommended for production automation** | CD pipelines, teams already standardized on Helm |
| In-cluster Istio Operator (`istioctl operator init`) | A controller reconciles an `IstioOperator` CR | Reconciliation loop, but privileged controller | **Deprecated (1.23), removed** — do not build new platforms on it | Legacy only; migrate off |

> **Critical exam/production nuance:** the `IstioOperator` **API object** (`kind: IstioOperator`) is *still fully supported* as the configuration input to `istioctl install` / `istioctl manifest generate`. What is deprecated is the **in-cluster operator controller** that watched that CR. Passing `-f iop.yaml` to `istioctl` is current and correct.

### 2.2 Built-in configuration profiles

| Profile | Components enabled | Intended use | Notes |
|---|---|---|---|
| `default` | `istiod` + `istio-ingressgateway` | **Production baseline** | Chosen per the settings in `istioctl profile dump default` |
| `demo` | `istiod` + ingress + **egress** gateway + full access logs + tracing sampling 100% | Demos / tutorials | High resource footprint; **never** for perf tests or prod |
| `minimal` | `istiod` only | Control plane only; add gateways separately | Common base for custom gateway topologies |
| `empty` | nothing | Scaffold for fully custom installs | Start here for tightly controlled installs |
| `preview` | default + experimental features | Trial upcoming features | Behaviour may change between releases |
| `ambient` | `istiod` + `ztunnel` + `istio-cni` | **Ambient (sidecar-less) mesh** | L4 via ztunnel, L7 via waypoints |
| `remote` / `external` | data plane pointed at an external control plane | Multi-cluster / external `istiod` | No local control plane |

Profiles are just **presets of `IstioOperator` fields**. Anything a profile sets, you can override; a profile is the *base layer* your overlay is merged onto.

### 2.3 Configuration layering (merge order)

Everything resolves into one effective `IstioOperator`. Layers merge in this precedence (later wins):

```
built-in profile  ->  your IstioOperator YAML (-f)  ->  --set flags (CLI)
```

Within the resulting object, three sub-surfaces do different jobs:

| Surface | Path | Governs | Example |
|---|---|---|---|
| Component config | `spec.components.<comp>` | *Which* components exist and their **Kubernetes** shape | `pilot.k8s.hpaSpec`, `ingressGateways[].k8s.service` |
| Helm values passthrough | `spec.values.*` | Chart-level behaviour flags | `values.global.proxy.resources`, `values.pilot.autoscaleEnabled` |
| Mesh config | `spec.meshConfig.*` | **Runtime mesh behaviour** (the `istio` ConfigMap) | `accessLogFile`, `outboundTrafficPolicy`, `extensionProviders` |

Rule of thumb: **`components.*.k8s` shapes the Pod/Deployment/Service (infra); `meshConfig` shapes traffic behaviour (runtime); `values.*` is the escape hatch to raw chart flags.**

---

## 3. Complete, unabridged manifests

### 3.1 Production `IstioOperator` (istioctl input)

This is a full, syntactically valid production baseline: HA `istiod`, sized proxies, HPA + PDB, hardened egress, structured access logs, an OpenTelemetry `extensionProvider`, and a revision for canary upgrades.

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: istio-system
spec:
  profile: default
  # Pin image source explicitly; never rely on floating tags in prod.
  hub: docker.io/istio
  tag: 1.23.2
  # Revision enables canary control-plane upgrades (see §4.4).
  revision: 1-23-2

  meshConfig:
    # Structured access logs to stdout, consumed by your log pipeline.
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
    # Lock the egress perimeter: only hosts in the registry (ServiceEntry) are reachable.
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
    enableTracing: true
    defaultConfig:
      # Avoid the app receiving traffic before Envoy is ready (503s on startup).
      holdApplicationUntilProxyStarts: true
      # Drain connections gracefully on shutdown.
      terminationDrainDuration: 30s
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
      tracing:
        sampling: 1.0            # 1% (value is a percentage: 1.0 == 1%)
    # Telemetry v2 wiring: reference this provider from a Telemetry CR.
    extensionProviders:
    - name: otel-tracing
      opentelemetry:
        service: opentelemetry-collector.observability.svc.cluster.local
        port: 4317
    - name: envoy-access-log
      envoyFileAccessLog:
        path: /dev/stdout

  components:
    pilot:
      k8s:
        replicaCount: 2
        resources:
          requests:
            cpu: "500m"
            memory: "2048Mi"
          limits:
            memory: "4096Mi"     # No CPU limit: avoid CFS throttling of xDS pushes.
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
        # Spread istiod replicas across nodes/zones.
        affinity:
          podAntiAffinity:
            preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: istiod

    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        replicaCount: 3
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
            cpu: "100m"
            memory: "128Mi"
          limits:
            memory: "256Mi"
        hpaSpec:
          minReplicas: 3
          maxReplicas: 10
        podDisruptionBudget:
          minAvailable: 2
        # Arbitrary-field patch: raise the gateway proxy log level via overlay.
        overlays:
        - kind: Deployment
          name: istio-ingressgateway
          patches:
          - path: spec.template.spec.containers.[name:istio-proxy].readinessProbe.periodSeconds
            value: 5

    egressGateways:
    - name: istio-egressgateway
      enabled: true          # Required to actually mediate egress under REGISTRY_ONLY.
      k8s:
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"

  values:
    global:
      proxy:
        # Default sidecar sizing (per-workload override via pod annotations).
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            memory: "256Mi"
      # Distroless proxy images: smaller attack surface, no shell.
      variant: distroless
    pilot:
      autoscaleEnabled: true
```

### 3.2 Equivalent production install via Helm

Helm is the recommended path for GitOps. Note the chart split: **`base`** installs CRDs + cluster-scoped RBAC, **`istiod`** the control plane, **`gateway`** each gateway (once per gateway), optionally **`cni`** and **`ztunnel`**.

`istiod-values.yaml`:

```yaml
revision: "1-23-2"
pilot:
  autoscaleEnabled: true
  autoscaleMin: 2
  autoscaleMax: 5
  resources:
    requests:
      cpu: "500m"
      memory: "2048Mi"
    limits:
      memory: "4096Mi"
  podAnnotations: {}
meshConfig:
  accessLogFile: /dev/stdout
  accessLogEncoding: JSON
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
  defaultConfig:
    holdApplicationUntilProxyStarts: true
global:
  proxy:
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
```

`gateway-values.yaml`:

```yaml
service:
  type: LoadBalancer
  ports:
  - name: status-port
    port: 15021
    targetPort: 15021
  - name: http2
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
```

---

## 4. Real CLI commands and terminal output

### 4.1 Inspecting profiles before committing

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
    openshift-ambient
    preview
    remote
    stable
```

```console
$ istioctl profile diff default demo | head -n 30
The difference between profiles:
 components:
   egressGateways:
   - enabled: true
+    name: istio-egressgateway
   ingressGateways:
   - enabled: true
     name: istio-ingressgateway
 meshConfig:
   accessLogFile: /dev/stdout
+  enableTracing: true
 values:
   global:
     proxy:
       tracer: zipkin
   pilot:
     traceSampling: 100
```

`profile diff` is the single most useful pre-install command: it shows *exactly* what a profile changes versus your baseline before you apply anything.

### 4.2 Render, never blind-apply

Always render to a file, diff it in review, then apply — never let `install` be the first time anyone sees the manifest.

```console
$ istioctl manifest generate -f control-plane.yaml > rendered.yaml
$ grep -c 'kind:' rendered.yaml
57
$ istioctl manifest generate -f control-plane.yaml \
    | kubectl diff -f - || true
```

### 4.3 Install and post-install verification

```console
$ istioctl install -f control-plane.yaml -y
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ Ingress gateways installed 🛬
✔ Egress gateways installed 🛫
✔ Installation complete                                          
Made this installation the default for cluster-wide operations.

$ istioctl verify-install -f control-plane.yaml
✔ ClusterRole: istiod-clusterrole-istio-system.rbac.authorization.k8s.io checked
✔ Deployment: istiod-1-23-2.apps/v1 checked
✔ Service: istiod-1-23-2.core checked
✔ Deployment: istio-ingressgateway.apps/v1 checked
...
Checked 25 custom resource definitions
Checked 3 Istio Deployments
✔ Istio is installed and verified successfully
```

### 4.4 Canary control-plane upgrade with revisions

The safe upgrade primitive: install a second `istiod` revision *alongside* the current one, then move namespaces one at a time.

```console
$ istioctl install -f control-plane-1-24-0.yaml --set revision=1-24-0 -y
✔ Istiod installed 🧠
✔ Installation complete

$ kubectl get pods -n istio-system -l app=istiod
NAME                             READY   STATUS    RESTARTS   AGE
istiod-1-23-2-6c9f8b7d4-abcde    1/1     Running   0          9d
istiod-1-23-2-6c9f8b7d4-fghij    1/1     Running   0          9d
istiod-1-24-0-7d8a9c6e5-klmno    1/1     Running   0          40s
istiod-1-24-0-7d8a9c6e5-pqrst    1/1     Running   0          40s

$ istioctl tag list
TAG      REVISION   NAMESPACES
default  1-23-2     payments,checkout,frontend

# Re-label ONE namespace to the new revision and restart its workloads.
$ kubectl label ns checkout istio.io/rev=1-24-0 istio-injection- --overwrite
namespace/checkout labeled
$ kubectl rollout restart deployment -n checkout

$ istioctl proxy-status | grep checkout
checkout-7d5c9-abcde.checkout    Kubernetes     SYNCED   SYNCED   SYNCED   SYNCED   istiod-1-24-0-7d8a9c6e5-klmno   1.24.0
```

Once every namespace is validated on `1-24-0`, flip the `default` tag and uninstall the old revision:

```console
$ istioctl tag set default --revision 1-24-0 --overwrite -y
$ istioctl uninstall --revision 1-23-2 -y
```

### 4.5 Overriding a single field ad-hoc (for triage, not for prod state)

```console
$ istioctl install --set meshConfig.outboundTrafficPolicy.mode=ALLOW_ANY -y
```

---

## 5. Verification and failure diagnosis

### 5.1 Static config validation

```console
$ istioctl analyze -A
✔ No validation issues found when analyzing all namespaces.
```

`istioctl analyze` catches misconfigurations the API server accepts but the mesh will reject (dangling `Gateway`↔`VirtualService` references, conflicting `mtls` policies, missing `ServiceEntry` under `REGISTRY_ONLY`).

### 5.2 Drift detection — running state vs. declared intent

```console
$ istioctl manifest generate -f control-plane.yaml > desired.yaml
$ istioctl manifest generate --revision 1-23-2 > cluster-effective.yaml
$ istioctl manifest diff desired.yaml cluster-effective.yaml
Differences of manifests are:
  Object Deployment:istio-system:istiod-1-23-2 changed:
-        cpu: 500m
+        cpu: 250m
```

A non-empty diff means someone patched the live cluster out-of-band; reconcile from Git.

### 5.3 Data-plane / control-plane sync health

```console
$ istioctl proxy-status
NAME                                CLUSTER    CDS     LDS     EDS     RDS     ECDS   ISTIOD                          VERSION
istio-ingressgateway-6b8...istio    Kubernetes SYNCED  SYNCED  SYNCED  SYNCED  IGNORED istiod-1-23-2-6c9f8b7d4-abcde  1.23.2
payments-5f7c...payments            Kubernetes SYNCED  SYNCED  SYNCED  STALE   IGNORED istiod-1-23-2-6c9f8b7d4-abcde  1.23.2
```

| Column state | Meaning | Action |
|---|---|---|
| `SYNCED` | Proxy has istiod's latest config | Healthy |
| `STALE` | istiod pushed, ack not received | Check proxy CPU throttling, network to istiod:15012 |
| `NOT SENT` | istiod computed nothing to push | Usually benign (no relevant config) |
| Version mismatch vs istiod | Proxy on old revision | Namespace not re-labeled / not restarted after canary |

### 5.4 Common failure modes and root causes

| Symptom | Likely root cause | Diagnosis / fix |
|---|---|---|
| Workloads can't reach external hosts after install | `outboundTrafficPolicy: REGISTRY_ONLY` with no `ServiceEntry` | `istioctl analyze`; add a `ServiceEntry`, or confirm egress gateway is enabled |
| `istiod` OOMKilled during large deploys | Memory limit too low for endpoint count | Raise `pilot.k8s.resources.limits.memory`; scale via HPA; check push size in istiod metrics |
| App returns 503 for a few seconds on pod start | Sidecar not ready before app traffic | `meshConfig.defaultConfig.holdApplicationUntilProxyStarts: true` |
| New sidecars never injected | Namespace labeled for a revision with no running `istiod` | `istioctl tag list`; re-label to a live revision; restart workloads |
| CPU throttling / latency on `istiod` | CPU **limit** set, CFS throttling xDS work | Remove the CPU limit on `istiod` (keep requests + HPA) |
| `istioctl install` succeeds but gateway has no external IP | `service.type` mismatch with the environment (no LB) | `kubectl get svc -n istio-system`; use `NodePort` or install a LB controller (MetalLB) |
| Gateway pods `CrashLoopBackOff` after upgrade | Stale revision webhook / mismatched CRDs | Reinstall `base` CRDs; verify `istioctl verify-install` |

```console
$ kubectl -n istio-system logs deploy/istiod-1-23-2 | grep -iE 'push|error' | tail -5
2026-08-08T14:02:11.334Z info ads Push debounce stable[482] 1 for config ServiceEntry/...: 100.2ms
2026-08-08T14:02:11.440Z info ads XDS: Pushing Services:214 ConnectedEndpoints:1287
```

Rising `Push debounce` times and growing `ConnectedEndpoints` are your leading indicator that `istiod` needs more replicas or memory — size the control plane against these, not against pod count alone.

---

## 6. References

- Istio — Installation Configuration Profiles: https://istio.io/latest/docs/setup/additional-setup/config-profiles/
- Istio — Customizing the configuration (`IstioOperator`): https://istio.io/latest/docs/setup/additional-setup/customize-installation/
- Istio — Install with `istioctl`: https://istio.io/latest/docs/setup/install/istioctl/
- Istio — Install with Helm: https://istio.io/latest/docs/setup/install/helm/
- Istio — `IstioOperator` API reference: https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/
- Istio — Global Mesh Options (`MeshConfig`): https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Istio — Canary upgrades / revisions: https://istio.io/latest/docs/setup/upgrade/canary/
- Istio — Stable revision labels (`istioctl tag`): https://istio.io/latest/docs/setup/upgrade/canary/#stable-revision-labels
- Istio — `istioctl` command reference: https://istio.io/latest/docs/reference/commands/istioctl/
- Istio — Operator deprecation notice: https://istio.io/latest/blog/2024/in-cluster-operator-deprecation-announcement/
- CNCF — Istio Certified Associate (ICA) curriculum: https://github.com/cncf/curriculum/raw/master/ICA_Curriculum.pdf