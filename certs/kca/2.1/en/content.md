# 2.1 — Helm-based Installation and Configuration (Kyverno)

> Domain 2 · *Installation, Configuration and Upgrades* · Objective weight **3.0**
> Target reader: Platform/SRE engineer operating Kyverno as a cluster-wide admission control plane in production.

---

## 1. Motivation: why Helm, and the production architectural problem it solves

Kyverno is not a workload you drop into a namespace. It is an **in-band admission control plane**: it registers `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration` objects that the kube-apiserver calls **synchronously on the write path of every matching API request**. That places Kyverno directly on the critical path of `kubectl apply`, controllers reconciling, and the scheduler binding Pods. An installation mistake here does not degrade a feature — it can wedge the entire cluster.

Three coupled properties make a hand-rolled `kubectl apply` install fragile, and are exactly what the chart encodes correctly:

1. **CRD lifecycle.** Kyverno ships ~11 CRDs (`ClusterPolicy`, `Policy`, `PolicyException`, `CleanupPolicy`, the intermediate report CRDs, `GlobalContextEntry`, `UpdateRequest`) plus the `wgpolicyk8s.io` report CRDs. Native Helm `crds/` folders are installed but **never upgraded** by `helm upgrade` (a documented Helm limitation). Kyverno therefore ships CRDs as **regular templates** in a sub-chart gated by `crds.install`, so `helm upgrade` actually reconciles CRD schema changes between minor versions. A raw manifest install leaves you to diff and re-apply CRDs by hand on every bump.

2. **The bootstrap deadlock / self-DoS.** Kyverno's webhooks can match Pod creation. If those webhooks also matched Kyverno's own Pods, or the kube-system control-plane Pods, then a Kyverno outage (or a bad policy) would block the recreation of Kyverno itself, of CNI, of CoreDNS — an unrecoverable cluster. The chart ships a **`config.resourceFilters`** allow-list that excludes `kube-system`, `kube-public`, `kube-node-lease`, the Kyverno namespace, Nodes, TokenReviews, and the report objects, plus a **`webhooks.namespaceSelector`** that excludes the Kyverno namespace at the apiserver level. These are safety interlocks, not cosmetics.

3. **HA is a topology, not a replica count.** Since **v1.10** the monolith was split into four independently-scaled controllers with different concurrency models (see §2). "Make it HA" means *scale the admission controller horizontally, but keep the background/reports/cleanup controllers as leader-elected singletons, add anti-affinity, add a PodDisruptionBudget, and tune `failurePolicy`*. That is a dozen correlated values — precisely what a `values.yaml` exists to hold under version control and GitOps.

**The core trade-off you are configuring in 2.1** is *enforcement strength vs. cluster availability*: `failurePolicy: Fail` gives you a hard security guarantee (no unreviewed writes) at the cost of coupling cluster write-availability to Kyverno's uptime; `failurePolicy: Ignore` fails open. Helm is where you make that decision explicit, reviewable, and reversible.

---

## 2. Technical comparisons and trade-offs

### 2.1 Installation method

| Method | CRD upgrades | Webhook safety defaults | HA topology | GitOps fit | When to use |
|---|---|---|---|---|---|
| **Helm chart** (`kyverno/kyverno`) | Handled via CRD templates + `crds.install` | Ships `resourceFilters` + `namespaceSelector` | First-class values (`admissionController.replicas`, PDB, anti-affinity) | Excellent (`helm template` → Flux/Argo) | **Default for production** |
| Raw `install.yaml` (`kubectl apply -f`) | Manual re-apply each version | Baked defaults, hard to override | Fixed in the manifest | Poor — edit-in-place drift | Quick lab / air-gapped bootstrap |
| Kustomize over `install.yaml` | Manual | Patch overlays | Overlay patches | Good | Teams standardized on Kustomize |
| Flux/Argo `HelmRelease` wrapping the chart | Same as Helm | Same as Helm | Same as Helm | Best | Fleet / multi-cluster |

### 2.2 The four controllers (post-1.10 split) — what you are actually installing

| Controller | Deployment | Scaling model | Failure blast radius | HA value |
|---|---|---|---|---|
| **Admission** | `kyverno-admission-controller` | Horizontal, **all replicas active** behind a Service; apiserver load-balances webhook calls | On the synchronous write path — outage blocks matched writes if `failurePolicy: Fail` | `replicas: 3` |
| **Background** | `kyverno-background-controller` | **Leader-elected singleton** (one active) | Mutate/generate on *existing* resources stops; no write-path impact | `replicas: 2` (1 standby) |
| **Reports** | `kyverno-reports-controller` | Leader-elected singleton | `PolicyReport` generation stalls; observability only | `replicas: 2` |
| **Cleanup** | `kyverno-cleanup-controller` | Leader-elected singleton; runs a CronJob-backed webhook | TTL/`CleanupPolicy` deletions pause | `replicas: 2` |

> Key exam point: **only the admission controller benefits from >1 *active* replica.** The other three run 1 active + N standby; raising their `replicas` buys faster failover, not throughput.

### 2.3 `failurePolicy` — the central production decision

| Setting | Behavior when Kyverno is unreachable | Security posture | Availability posture | Typical use |
|---|---|---|---|---|
| `Fail` (default for validating) | Matching API writes are **rejected** | Strong: no unreviewed change slips through | Kyverno outage ⇒ writes blocked cluster-wide (for matched resources) | Enforced security baselines with HA + PDB |
| `Ignore` | Matching writes are **admitted un-reviewed** | Weaker: gap during outage | Cluster keeps accepting writes | Mutation/generation, or while stabilizing rollout |
| `features.forceFailurePolicyIgnore.enabled: true` | Forces **all** managed webhooks to Ignore regardless of policy | Global fail-open | Maximum availability | Break-glass / initial onboarding |

### 2.4 The two charts

| Chart | Installs | Contains policies? |
|---|---|---|
| `kyverno/kyverno` | The engine: CRDs, RBAC, 4 controllers, ConfigMaps, dynamic webhooks | **No** — zero policies by default |
| `kyverno/kyverno-policies` | The Pod Security Standards policy set (baseline / restricted) as `ClusterPolicy` objects | Yes |

Installing `kyverno` alone enforces **nothing** — Kyverno registers a resource webhook only *after* a matching policy exists. This is why `kyverno-resource-validating-webhook-cfg` shows `0` webhooks on a fresh engine install (see §5).

---

## 3. Complete production manifests

### 3.1 `values-ha.yaml` — hardened, highly-available engine

```yaml
# values-ha.yaml — Kyverno engine, production HA profile
# Compatible with chart 3.3.x (Kyverno v1.13.x). Pin exact versions in the release.

# ---- CRDs: install AND allow helm upgrade to reconcile schema drift ----
crds:
  install: true
  annotations:
    "helm.sh/resource-policy": keep   # do NOT delete CRDs (and their CRs) on `helm uninstall`

# ---- Cluster-wide engine configuration (rendered into ConfigMap "kyverno") ----
config:
  # Namespaces/kinds Kyverno must NEVER intercept. Appended to the chart's safe defaults.
  # Format: '[Kind,Namespace,Name]', wildcards allowed.
  resourceFiltersExcludeNamespaces:
    - kube-system
    - kube-public
    - kube-node-lease
  resourceFilters:
    - '[Event,*,*]'
    - '[*,kube-system,*]'
    - '[*,kube-public,*]'
    - '[*,kube-node-lease,*]'
    - '[Node,*,*]'
    - '[APIService,*,*]'
    - '[TokenReview,*,*]'
    - '[SubjectAccessReview,*,*]'
    - '[SelfSubjectAccessReview,*,*]'
    - '[*,kyverno,kyverno*]'          # never intercept our own namespace
    - '[*,gatekeeper-system,*]'       # avoid cross-admission-controller loops
    - '[*,flux-system,*]'
  # Exclude the Kyverno namespace at the apiserver webhook level (belt-and-suspenders).
  webhooks:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kyverno, kube-system]
  webhookAnnotations:
    "cert-manager.io/inject-ca-from-secret": "kyverno/kyverno-svc.kyverno.svc.kyverno-tls-ca"
  # Emit events for policy successes too (useful during rollout; noisier).
  generateSuccessEvents: false

# ---- Feature flags ----
features:
  logging:
    format: json
  admissionReports:
    enabled: true
  aggregateReports:
    enabled: true
  policyReports:
    enabled: true
  backgroundScan:
    enabled: true
    backgroundScanInterval: 1h
    backgroundScanWorkers: 2
  # Leave OFF in prod until you have decided the fail-open story deliberately.
  forceFailurePolicyIgnore:
    enabled: false
  # Generate native ValidatingAdmissionPolicy from Kyverno policies where possible (K8s 1.30+).
  generateValidatingAdmissionPolicy:
    enabled: false

# ========================= ADMISSION CONTROLLER (write path) =========================
admissionController:
  replicas: 3                          # active/active behind the Service
  podDisruptionBudget:
    minAvailable: 2                    # survive a node drain without losing quorum
  antiAffinity:
    enabled: true                      # spread the 3 replicas across nodes
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/component: admission-controller
  priorityClassName: system-cluster-critical
  serviceMonitor:
    enabled: true                      # Prometheus Operator scrape of :8000/metrics
  container:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { memory: 512Mi }      # NO cpu limit — avoid throttling on the write path
  initContainer:
    resources:
      requests: { cpu: 10m, memory: 64Mi }
      limits:   { memory: 128Mi }
  tolerations:
    - key: CriticalAddonsOnly
      operator: Exists
  webhookTimeoutSeconds: 10            # apiserver waits at most this long per call

# ========================= BACKGROUND CONTROLLER (existing resources) =========================
backgroundController:
  enabled: true
  replicas: 2                          # 1 active (leader) + 1 warm standby
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 256Mi }

# ========================= REPORTS CONTROLLER (PolicyReports) =========================
reportsController:
  enabled: true
  replicas: 2
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 512Mi }

# ========================= CLEANUP CONTROLLER (TTL / CleanupPolicy) =========================
cleanupController:
  enabled: true
  replicas: 2
  podDisruptionBudget:
    minAvailable: 1
  serviceMonitor:
    enabled: true
  resources:
    requests: { cpu: 50m, memory: 64Mi }
    limits:   { memory: 128Mi }
```

### 3.2 `values-policies.yaml` — the Pod Security Standards policy pack

```yaml
# values-policies.yaml — kyverno/kyverno-policies chart
# Roll out in Audit first, promote to Enforce per-namespace once report noise is clean.
podSecurityStandard: baseline          # baseline | restricted
podSecuritySeverity: medium
validationFailureAction: Audit         # Audit first; flip to Enforce after triage
# Scope enforcement without touching cluster infra namespaces:
podSecurityPolicies: []                # (chart selects the standard's rule set)
includeRestrictedPolicies: []
customLabels: {}
background: true                       # also scan pre-existing workloads
```

### 3.3 Flux `HelmRelease` (GitOps wrapper, optional but production-typical)

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kyverno
  namespace: kyverno
spec:
  interval: 30m
  chart:
    spec:
      chart: kyverno
      version: "3.3.4"                 # PIN exactly; never float in prod
      sourceRef:
        kind: HelmRepository
        name: kyverno
        namespace: flux-system
  install:
    crds: CreateReplace
    createNamespace: true
  upgrade:
    crds: CreateReplace                # let Flux reconcile CRD schema on upgrade
  valuesFrom:
    - kind: ConfigMap
      name: kyverno-values-ha
```

---

## 4. CLI commands and real terminal output

### 4.1 Add repo, pin version, preview

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
"kyverno" has been added to your repositories

$ helm repo update kyverno
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "kyverno" chart repository
Update Complete. ⎈Happy Helming!⎈

$ helm search repo kyverno --versions | head -5
NAME                     	CHART VERSION	APP VERSION	DESCRIPTION
kyverno/kyverno          	3.3.4        	v1.13.4    	Kubernetes Native Policy Management
kyverno/kyverno          	3.3.3        	v1.13.3    	Kubernetes Native Policy Management
kyverno/kyverno-policies 	3.3.4        	v1.13.4    	Kubernetes Pod Security Standards ...
kyverno/kyverno-crds     	3.3.4        	v1.13.4    	Kyverno CRDs

# Render locally and diff BEFORE touching the cluster — this is the audit gate.
$ helm template kyverno kyverno/kyverno --version 3.3.4 -n kyverno \
    -f values-ha.yaml | kubectl apply --dry-run=server -f - | tail -6
clusterrole.rbac.authorization.k8s.io/kyverno:admission-controller ... (server dry run)
deployment.apps/kyverno-admission-controller created (server dry run)
deployment.apps/kyverno-background-controller created (server dry run)
deployment.apps/kyverno-reports-controller created (server dry run)
deployment.apps/kyverno-cleanup-controller created (server dry run)
configmap/kyverno created (server dry run)
```

### 4.2 Install (engine), waiting for readiness

```console
$ helm install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --version 3.3.4 \
    -f values-ha.yaml \
    --wait --timeout 5m
NAME: kyverno
LAST DEPLOYED: Thu Aug 13 14:22:07 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 1
NOTES:
Chart version: 3.3.4
Kyverno version: v1.13.4
Thank you for installing kyverno! Your release is named kyverno.
...
```

### 4.3 Install the policy pack (separate release)

```console
$ helm install kyverno-policies kyverno/kyverno-policies \
    --namespace kyverno --version 3.3.4 \
    -f values-policies.yaml --wait
NAME: kyverno-policies
STATUS: deployed
REVISION: 1
```

### 4.4 Inspect the release and effective values

```console
$ helm list -n kyverno
NAME            	NAMESPACE	REVISION	STATUS  	CHART          	APP VERSION
kyverno         	kyverno  	1       	deployed	kyverno-3.3.4  	v1.13.4
kyverno-policies	kyverno  	1       	deployed	kyverno-policies-3.3.4	v1.13.4

# Only the values that DIFFER from chart defaults — the review artifact:
$ helm get values kyverno -n kyverno
USER-SUPPLIED VALUES:
admissionController:
  antiAffinity:
    enabled: true
  podDisruptionBudget:
    minAvailable: 2
  replicas: 3
...
```

### 4.5 Upgrade path (chart bump = CRD reconcile)

```console
$ helm upgrade kyverno kyverno/kyverno -n kyverno \
    --version 3.4.0 -f values-ha.yaml \
    --wait --timeout 5m
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
REVISION: 2
STATUS: deployed

$ helm history kyverno -n kyverno
REVISION	UPDATED                 	STATUS    	CHART        	APP VERSION	DESCRIPTION
1       	Thu Aug 13 14:22:07 2026	superseded	kyverno-3.3.4	v1.13.4    	Install complete
2       	Thu Aug 13 15:01:44 2026	deployed  	kyverno-3.4.0	v1.14.0    	Upgrade complete
```

---

## 5. Verification and failure diagnosis

### 5.1 The four-controller health check

```console
$ kubectl -n kyverno get pods
NAME                                             READY   STATUS    RESTARTS   AGE
kyverno-admission-controller-7d8f6c9b45-abcde    1/1     Running   0          3m
kyverno-admission-controller-7d8f6c9b45-fghij    1/1     Running   0          3m
kyverno-admission-controller-7d8f6c9b45-klmno    1/1     Running   0          3m
kyverno-background-controller-6c5b4d8f9-pqrst    1/1     Running   0          3m
kyverno-cleanup-controller-5f7c9d6b8-uvwxy       1/1     Running   0          3m
kyverno-reports-controller-8d6f5c7b9-zabcd       1/1     Running   0          3m
```

Expected: **3 admission** replicas Ready, **1+** of each other controller. If you see only one admission Pod, your `admissionController.replicas` override did not apply — check `helm get values`.

### 5.2 CRDs present

```console
$ kubectl get crds | grep -E 'kyverno.io|wgpolicyk8s.io'
admissionreports.kyverno.io                      2026-08-13T14:22:05Z
backgroundscanreports.kyverno.io                 2026-08-13T14:22:05Z
cleanuppolicies.kyverno.io                        2026-08-13T14:22:05Z
clusteradmissionreports.kyverno.io               2026-08-13T14:22:05Z
clustercleanuppolicies.kyverno.io                2026-08-13T14:22:05Z
clusterpolicies.kyverno.io                        2026-08-13T14:22:05Z
globalcontextentries.kyverno.io                  2026-08-13T14:22:05Z
policies.kyverno.io                               2026-08-13T14:22:05Z
policyexceptions.kyverno.io                       2026-08-13T14:22:05Z
updaterequests.kyverno.io                         2026-08-13T14:22:05Z
clusterpolicyreports.wgpolicyk8s.io              2026-08-13T14:22:05Z
policyreports.wgpolicyk8s.io                      2026-08-13T14:22:05Z
```

### 5.3 Dynamic webhooks — the counter-intuitive check

```console
$ kubectl get validatingwebhookconfigurations | grep kyverno
kyverno-policy-validating-webhook-cfg      1     3m
kyverno-resource-validating-webhook-cfg    0     3m     # ← 0 is CORRECT on a fresh engine
kyverno-exception-validating-webhook-cfg   1     3m
kyverno-cleanup-validating-webhook-cfg     1     3m
kyverno-ttl-validating-webhook-cfg         1     3m
```

`kyverno-resource-validating-webhook-cfg` carries **0 webhooks until a policy that matches real resources exists**. Kyverno rebuilds these configurations dynamically from installed policies to minimize apiserver overhead. After installing `kyverno-policies`, re-check — the count becomes non-zero:

```console
$ kubectl get clusterpolicies
NAME                             ADMISSION   BACKGROUND   READY   AGE
disallow-capabilities            true        true         True    2m
disallow-host-namespaces         true        true         True    2m
disallow-privileged-containers   true        true         True    2m
...
$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].name}'
validate.kyverno.svc-fail  validate.kyverno.svc-ignore
```

### 5.4 Config and TLS

```console
$ kubectl -n kyverno get configmap kyverno -o jsonpath='{.data.resourceFilters}' | head -c 200
[Event,*,*][*,kube-system,*][*,kube-public,*][*,kube-node-lease,*][Node,*,*]...

$ kubectl -n kyverno get secret | grep tls
kyverno-svc.kyverno.svc.kyverno-tls-ca    kubernetes.io/tls   2   4m
kyverno-svc.kyverno.svc.kyverno-tls-pair  kubernetes.io/tls   2   4m
```

Kyverno self-generates and rotates its webhook CA/serving certs into those two Secrets. If they are missing, the apiserver cannot establish TLS to the webhook and every matched request fails.

### 5.5 Smoke test the enforcement path

```console
$ kubectl run bad --image=nginx --privileged --dry-run=server
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/bad was blocked due to the following policies

disallow-privileged-containers:
  privileged-containers: 'validation error: Privileged mode is disallowed.
    rule privileged-containers failed at path /spec/containers/0/securityContext/privileged/'
```

A `denied the request` from `validate.kyverno.svc-fail` is proof the full chain works: apiserver → webhook → policy engine → verdict.

### 5.6 Failure catalogue

| Symptom | Likely root cause | Diagnosis | Fix |
|---|---|---|---|
| `context deadline exceeded` / `failed calling webhook ... i/o timeout` on **all** applies | Admission controller down/overloaded, or `webhookTimeoutSeconds` too low | `kubectl -n kyverno get pods`; `kubectl -n kyverno logs deploy/kyverno-admission-controller` | Restore replicas; raise timeout; if emergency, `helm upgrade --set features.forceFailurePolicyIgnore.enabled=true` to fail-open |
| **Cannot create ANY Pod, including in kube-system** | `resourceFilters` / `namespaceSelector` misconfigured — system namespaces not excluded | `kubectl get cm kyverno -n kyverno -o yaml` and inspect filters | Restore chart-default `resourceFilters`; **break-glass**: `kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg` |
| `helm upgrade` succeeds but new policy fields rejected | CRDs not upgraded (installed via native `crds/` or `crds.install: false`) | `kubectl get crd clusterpolicies.kyverno.io -o yaml \| grep -A2 versions` | Set `crds.install: true`; for Flux use `crds: CreateReplace` |
| Admission controller `CrashLoopBackOff`, OOMKilled | Memory limit too low for policy/report volume | `kubectl -n kyverno describe pod` → `Reason: OOMKilled` | Raise `admissionController.container.resources.limits.memory`; remove CPU limits |
| No `PolicyReport` objects appear | Reports controller down, or `features.policyReports.enabled: false` | `kubectl get polr -A`; check `kyverno-reports-controller` logs | Enable feature; restart controller |
| CPU throttling spikes latency on write path | A CPU **limit** set on the admission container | `kubectl top pod`; check `resources.limits.cpu` | Remove CPU limit (requests only) — standard for latency-critical webhooks |
| Two active background controllers doing duplicate work | Leader election disabled/broken | `kubectl -n kyverno get lease \| grep kyverno` | Ensure RBAC for `coordination.k8s.io/leases`; one holder expected |

### 5.7 Clean rollback

```console
$ helm rollback kyverno 1 -n kyverno --wait
Rollback was a success! Happy Helming!
```

> Because `crds.annotations."helm.sh/resource-policy": keep` is set, `helm uninstall` leaves CRDs (and any `PolicyReport`/policy CRs) intact. Removing them is a **deliberate** second step (`kubectl delete crd -l app.kubernetes.io/part-of=kyverno`), never a side effect of uninstall.

---

## 6. References

- Kyverno — Installation (methods, HA, controllers): https://kyverno.io/docs/installation/
- Kyverno — Helm installation: https://kyverno.io/docs/installation/methods/
- Kyverno — High Availability installation: https://kyverno.io/docs/high-availability/
- Kyverno Helm chart (`kyverno/kyverno`) values reference: https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno charts repository (Artifact Hub): https://artifacthub.io/packages/helm/kyverno/kyverno
- Kyverno — Container Flags & config (ConfigMap, resourceFilters, webhooks): https://kyverno.io/docs/installation/customization/
- Kyverno — Pod Security policy pack (`kyverno-policies`): https://kyverno.io/policies/pod-security/
- Kyverno — Webhook / failurePolicy behavior: https://kyverno.io/docs/installation/customization/#configuring-webhooks
- Kyverno — Controllers overview (admission / background / reports / cleanup): https://kyverno.io/docs/installation/#security-vs-operability
- Helm — CRD management limitation: https://helm.sh/docs/chart_best_practices/custom_resource_definitions/
- Kubernetes — Dynamic Admission Control (`failurePolicy`, `namespaceSelector`, `timeoutSeconds`): https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- KCA curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf