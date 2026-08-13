# Upgrading Kyverno

> KCA — Domain 2 · Topic 2.6 · Exam weight 3.0
> Profile: SRE / Platform Architect — production-grade

Kyverno is not an ordinary workload. It runs **inside the admission path of the Kubernetes API server**: every `CREATE`/`UPDATE`/`DELETE` that matches a policy is intercepted by its `MutatingWebhookConfiguration` and `ValidatingWebhookConfiguration` before it is persisted to etcd. An upgrade therefore touches three things at once — a set of controllers, a set of very large CRDs, and a set of cluster-scoped webhooks that can block the entire API surface if they go wrong. This topic is about doing that upgrade without an outage, and diagnosing it when it fails.

---

## 1. Motivation and the production architectural problem

### 1.1 Why upgrading Kyverno is a control-plane operation, not an app deploy

An ordinary Deployment upgrade fails "locally": the app degrades, users of that app see errors. Kyverno fails "globally". Consider the failure mode that defines every design decision below:

```
Client → kube-apiserver → [Kyverno webhook: failurePolicy=Fail] → etcd
                                    │
                          admission controller Pods are Terminating
                                    │
                                    ▼
             webhook call times out → apiserver rejects the request
```

If the admission controller has `failurePolicy: Fail` and **all** its replicas are unavailable during a rolling upgrade, the API server cannot satisfy the webhook and **rejects every matching write cluster-wide** — including, potentially, the very Pods Kyverno needs to come back up. This is the canonical way an administrator bricks a cluster with a policy engine. The entire upgrade strategy exists to make sure the webhook backend never has zero healthy endpoints.

### 1.2 The three things that move during an upgrade

| Moving part | What it is | Failure if mishandled |
|---|---|---|
| **Controllers** | 4 independent Deployments (since v1.10) | Rolling update drops admission capacity |
| **CRDs** | Policy/report/request schemas — very large OpenAPI v3 documents | `kubectl apply` fails on the 262 144-byte annotation limit; stored-version mismatch |
| **Webhook configs** | Dynamically reconciled `*WebhookConfiguration` objects | Stale rules point at old service ports/paths; `failurePolicy` blocks the cluster |

### 1.3 The split-controller architecture (the single most important upgrade fact)

Before **v1.10**, Kyverno shipped as one monolithic Deployment named `kyverno`. Since **v1.10** it is split into four independently scalable controllers:

| Deployment | Responsibility | In the admission hot path? |
|---|---|---|
| `kyverno-admission-controller` | Serves the mutating/validating webhooks | **Yes** — must be HA |
| `kyverno-background-controller` | `generate` rules, `mutateExisting`, background reconciliation | No |
| `kyverno-reports-controller` | Builds `PolicyReport`/`ClusterPolicyReport` | No |
| `kyverno-cleanup-controller` | TTL/`CleanupPolicy` resource deletion | No (own webhook for cleanup) |

**Consequence for upgrades:** a monolith→split jump (pre-1.10 → 1.10+) is a *rename and topology change*, not a simple image bump. The old `kyverno` Deployment is removed and four new ones appear. Only the admission controller is latency-critical, so **only it strictly needs 3 replicas for a zero-downtime upgrade** — the others tolerate brief unavailability.

### 1.4 Version skew — Kyverno ↔ Kubernetes

Kyverno depends on API-machinery behaviour (admission review versions, CEL libraries, server-side apply semantics). Each Kyverno minor is tested against a narrow, **sliding** window of Kubernetes minors. Running outside that window is unsupported and routinely breaks on subtle admission-review or CEL differences. Confirm the pair *before* touching anything (Section 6 cites the authoritative matrix).

---

## 2. Technical comparisons and trade-offs

### 2.1 Upgrade delivery method

| Method | Idempotent | CRD upgrades | Rollback | Best for |
|---|---|---|---|---|
| **Helm** (`helm upgrade`) | Yes | Managed via chart templates (`crds.install`) | `helm rollback` (schema caveats) | Production standard |
| **Raw manifest** (`install.yaml`) | With `--server-side` | Manual, must use SSA/`replace` | Re-apply previous manifest | Air-gapped / no Helm |
| **GitOps** (Argo CD / Flux) | Yes | Needs `ServerSideApply=true` + `Replace=true` sync options | Git revert + sync | Fleets, auditability |

> The native Helm `crds/` directory is **install-only** — Helm never upgrades CRDs placed there. Kyverno deliberately ships CRDs as *templates* (gated by `crds.install=true`) so that `helm upgrade` can evolve the schemas. This is why "just `helm upgrade`" actually works for Kyverno CRDs, unlike most charts.

### 2.2 How to apply the CRDs — this is where upgrades most often fail

Kyverno's CRDs (e.g. `clusterpolicies.kyverno.io`) carry enormous OpenAPI schemas.

| Command | Result on Kyverno CRDs | Verdict |
|---|---|---|
| `kubectl apply -f install.yaml` | Writes `last-applied-configuration` annotation → **exceeds 262 144 bytes** → `metadata.annotations: Too long` | ❌ Fails |
| `kubectl apply --server-side -f install.yaml` | No client-side annotation; field-manager merge | ✅ Recommended |
| `kubectl replace -f` | Works but needs the object to already exist; loses concurrent changes | ⚠️ Fallback |
| `kubectl create -f` | Works for first install only | ❌ Not for upgrades |

### 2.3 Sequential vs. skip-version

| Strategy | Risk | Official stance |
|---|---|---|
| **Sequential minors** (1.11 → 1.12 → 1.13) | Low; each migration guide applies once | **Recommended — do not skip minors** |
| **Skip minors** (1.11 → 1.13) | Compounded breaking changes, un-migrated stored CRD versions | Unsupported |

Kyverno explicitly recommends upgrading **one minor at a time** and reading each release's migration notes. Patch upgrades (1.12.3 → 1.12.5) are safe to jump.

### 2.4 In-place rolling vs. blue-green

| Approach | Downtime | Complexity | When |
|---|---|---|---|
| **Rolling** (HA admission ctrl, `maxUnavailable: 0`) | None | Low | Default |
| **Blue-green** (second install, cut webhooks over) | None | High | Major topology jumps / risk-averse changes |

### 2.5 Representative compatibility matrix

*Illustrative of the sliding pattern — always confirm the live values at the cited docs before upgrading:*

| Kyverno | Kubernetes (tested) |
|---|---|
| 1.10.x | 1.24 – 1.26 |
| 1.11.x | 1.25 – 1.28 |
| 1.12.x | 1.26 – 1.29 |
| 1.13.x | 1.28 – 1.31 |
| 1.14.x | 1.29 – 1.32 |

The rule that never changes: **each Kyverno minor supports roughly three consecutive Kubernetes minors, and the window slides forward each release.** The table above is a memory aid, not the source of truth.

---

## 3. Complete manifests and infrastructure

### 3.1 HA `values.yaml` tuned for zero-downtime upgrades

The admission controller must never reach zero healthy endpoints during the rollout. This means ≥3 replicas, a `PodDisruptionBudget`, anti-affinity across nodes, and a `RollingUpdate` strategy that adds a Pod before removing one.

```yaml
# values-ha.yaml — pass to: helm upgrade ... -f values-ha.yaml
# Chart: kyverno/kyverno (v1.12+ key layout)

# Manage CRDs through templates so `helm upgrade` evolves the schemas.
crds:
  install: true

# ---- Admission controller: the only latency-critical component ----
admissionController:
  replicas: 3                       # HA: survive one Pod down during rollout
  podDisruptionBudget:
    minAvailable: 2                 # never let voluntary eviction drop below 2
  antiAffinity:
    enabled: true                   # spread replicas across nodes
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0             # add-before-remove — endpoints never hit 0
  container:
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { memory: 512Mi }
  readinessProbe:
    httpGet: { path: /health/readiness, port: 9443, scheme: HTTPS }
    initialDelaySeconds: 5
    periodSeconds: 10
  livenessProbe:
    httpGet: { path: /health/liveness, port: 9443, scheme: HTTPS }

# ---- Non-critical controllers: single replica is acceptable ----
backgroundController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }

reportsController:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 128Mi }

cleanupController:
  replicas: 1

# ---- Webhook safety: keep Kyverno out of its own blast radius ----
config:
  # Namespaces Kyverno's webhooks must never intercept — including its own,
  # so a broken admission controller cannot block its own recovery.
  webhooks:
    - namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values:
              - kyverno
              - kube-system
```

### 3.2 A PodDisruptionBudget (explicit form, if not using the chart value)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyverno-admission-controller
  namespace: kyverno
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/part-of: kyverno
```

### 3.3 The webhook object you must understand (read-only — Kyverno reconciles it)

You do **not** hand-edit this; the admission controller generates and reconciles it from installed policies. But you must be able to read it during an upgrade, because `failurePolicy`, `service.port`, and `namespaceSelector` are exactly what breaks.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kyverno-resource-validating-webhook-cfg
  labels:
    webhook.kyverno.io/managed-by: kyverno
webhooks:
  - name: validate.kyverno.svc-fail
    failurePolicy: Fail            # ← the cluster-blocking knob
    timeoutSeconds: 10
    matchPolicy: Equivalent
    sideEffects: NoneOnDryRun
    admissionReviewVersions: ["v1"]
    clientConfig:
      service:
        namespace: kyverno
        name: kyverno-svc
        path: /validate/fail
        port: 443                  # ← must match the upgraded Service
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kyverno", "kube-system"]
```

### 3.4 GitOps (Argo CD) sync options that make CRD upgrades work

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://kyverno.github.io/kyverno/
    chart: kyverno
    targetRevision: 3.2.6          # Helm chart version (≠ Kyverno app version)
    helm:
      valueFiles: [values-ha.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    syncOptions:
      - ServerSideApply=true       # avoids the 262 144-byte annotation limit
      - Replace=false
      - CreateNamespace=true
```

---

## 4. Real CLI commands and terminal output

### 4.1 Establish the current state (always snapshot before upgrading)

```console
$ kubectl -n kyverno get deploy -o wide
NAME                             READY   UP-TO-DATE   AVAILABLE   IMAGES
kyverno-admission-controller     3/3     3            3           reg.kyverno.io/kyverno/kyverno:v1.11.4
kyverno-background-controller    1/1     1            1           reg.kyverno.io/kyverno/background-controller:v1.11.4
kyverno-cleanup-controller       1/1     1            1           reg.kyverno.io/kyverno/cleanup-controller:v1.11.4
kyverno-reports-controller       1/1     1            1           reg.kyverno.io/kyverno/reports-controller:v1.11.4

$ kubectl get crd | grep kyverno.io
admissionreports.kyverno.io              2024-02-11T09:14:02Z
backgroundscanreports.kyverno.io         2024-02-11T09:14:02Z
cleanuppolicies.kyverno.io               2024-02-11T09:14:02Z
clustercleanuppolicies.kyverno.io        2024-02-11T09:14:02Z
clusterpolicies.kyverno.io               2024-02-11T09:14:02Z
policies.kyverno.io                      2024-02-11T09:14:02Z
policyexceptions.kyverno.io              2024-02-11T09:14:02Z
updaterequests.kyverno.io                2024-02-11T09:14:02Z
```

### 4.2 Back up policies and CRs before touching the CRDs

```console
$ kubectl get clusterpolicies.kyverno.io,policies.kyverno.io -A -o yaml > kyverno-policies-backup.yaml
$ kubectl get crd -l app.kubernetes.io/part-of=kyverno -o yaml > kyverno-crds-backup.yaml
$ wc -l kyverno-policies-backup.yaml
   842 kyverno-policies-backup.yaml
```

### 4.3 Helm path (recommended)

```console
$ helm repo add kyverno https://kyverno.github.io/kyverno/
"kyverno" has been added to your repositories

$ helm repo update
Hang tight while we grab the latest from your chart repositories...
Update Complete. ⎈Happy Helming!⎈

$ helm search repo kyverno/kyverno --versions | head -5
NAME             CHART VERSION   APP VERSION   DESCRIPTION
kyverno/kyverno  3.2.6           v1.12.6       Kubernetes Native Policy Management
kyverno/kyverno  3.2.5           v1.12.5       Kubernetes Native Policy Management
kyverno/kyverno  3.1.4           v1.11.4       Kubernetes Native Policy Management
```

> Note the two version numbers: **chart version** (`3.2.6`) ≠ **app/Kyverno version** (`v1.12.6`). Always pin the chart version explicitly.

```console
$ helm upgrade kyverno kyverno/kyverno \
    --namespace kyverno \
    --version 3.2.6 \
    --values values-ha.yaml \
    --atomic --timeout 5m
Release "kyverno" has been upgraded. Happy Helming!
NAME: kyverno
LAST DEPLOYED: Thu Aug 13 10:22:41 2026
NAMESPACE: kyverno
STATUS: deployed
REVISION: 7
```

`--atomic` rolls the release back automatically if the upgrade does not become healthy within `--timeout`. This is the single most valuable flag for an unattended Kyverno upgrade.

### 4.4 Watch the rolling update (endpoints must stay ≥1 the whole time)

```console
$ kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=300s
Waiting for deployment "kyverno-admission-controller" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "kyverno-admission-controller" rollout to finish: 2 of 3 updated replicas are available...
deployment "kyverno-admission-controller" successfully rolled out

# In a second terminal — prove the webhook backend never emptied:
$ kubectl -n kyverno get endpoints kyverno-svc -w
NAME          ENDPOINTS                                         AGE
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.3.4:9443   41d
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443                   41d   # 3→2, never 0
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.4.6:9443   41d   # new Pod added
```

### 4.5 Raw manifest path (air-gapped / no Helm) — note `--server-side`

```console
$ kubectl apply --server-side --force-conflicts \
    -f https://github.com/kyverno/kyverno/releases/download/v1.12.6/install.yaml
customresourcedefinition.apiextensions.k8s.io/clusterpolicies.kyverno.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/policies.kyverno.io serverside-applied
...
deployment.apps/kyverno-admission-controller serverside-applied
deployment.apps/kyverno-background-controller serverside-applied
```

Contrast with the failure the client-side apply produces (the mistake to recognise in the exam and in production):

```console
$ kubectl apply -f install.yaml
The CustomResourceDefinition "clusterpolicies.kyverno.io" is invalid:
metadata.annotations: Too long: must have at most 262144 bytes
```

---

## 5. Verification and failure diagnosis

### 5.1 Post-upgrade verification checklist

```console
# 1) Every controller reports the new image and is Available
$ kubectl -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
kyverno-admission-controller    reg.kyverno.io/kyverno/kyverno:v1.12.6
kyverno-background-controller   reg.kyverno.io/kyverno/background-controller:v1.12.6
kyverno-cleanup-controller      reg.kyverno.io/kyverno/cleanup-controller:v1.12.6
kyverno-reports-controller      reg.kyverno.io/kyverno/reports-controller:v1.12.6

# 2) Webhooks are healthy and point at the right service/port
$ kubectl get validatingwebhookconfigurations -l webhook.kyverno.io/managed-by=kyverno
NAME                                        WEBHOOKS   AGE
kyverno-resource-validating-webhook-cfg     1          41d
kyverno-policy-validating-webhook-cfg       1          41d

# 3) Existing policies still Ready (CRD schema migration didn't break them)
$ kubectl get cpol
NAME                    ADMISSION   BACKGROUND   READY   AGE
require-run-as-nonroot  true        true         True    41d
disallow-latest-tag     true        true         True    41d

# 4) A live smoke test — an offending Pod is actually rejected
$ kubectl run bad --image=nginx:latest --dry-run=server
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
policy disallow-latest-tag/... : validation error: Using a mutable image tag is not allowed.
```

If step 4 is *silently allowed*, the webhook is not intercepting — the admission controller is up but the webhook config is stale or was not reconciled.

### 5.2 Failure catalogue

| Symptom | Root cause | Fix |
|---|---|---|
| `metadata.annotations: Too long: 262144 bytes` | Client-side `kubectl apply` on giant CRDs | Re-run with `--server-side --force-conflicts` |
| Whole cluster rejects writes during upgrade | `failurePolicy: Fail` + admission Pods all down | Ensure 3 replicas, `maxUnavailable: 0`, PDB `minAvailable: 2`; emergency: delete the `*WebhookConfiguration` to unblock, then let Kyverno recreate it |
| `no matches for kind "Policy" in version "kyverno.io/v1"` | CRD not upgraded before controllers | Apply CRDs first, then controllers |
| Old `kyverno` Deployment lingers after pre-1.10 upgrade | Monolith→split rename incomplete | `kubectl -n kyverno delete deploy kyverno` after confirming the 4 new ones are Ready |
| Policies show `READY: False` | Deprecated field (e.g. lowercase `validationFailureAction: enforce`) | Migrate to PascalCase `Enforce`/`Audit`; re-apply |
| Reports stop updating | Reports controller crash-looping on new CRD | Check its logs; verify `reports.kyverno.io`/`wgpolicyk8s.io` CRDs upgraded |
| `helm upgrade` leaves removed CRDs behind | Helm never deletes CRDs | Manually `kubectl delete crd` only after confirming no CRs of that kind remain |

### 5.3 Diagnostic commands

```console
# Which API versions are actually stored for a CRD (migration health):
$ kubectl get crd clusterpolicies.kyverno.io -o jsonpath='{.status.storedVersions}'
["v1"]

# Confirm served/deprecated versions after upgrade:
$ kubectl get crd clusterpolicies.kyverno.io \
    -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
v1 served=true storage=true
v2beta1 served=true storage=false

# Admission controller readiness and recent errors:
$ kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=20 | grep -iE 'error|webhook|ready'

# Prove the webhook is reachable from the apiserver's perspective:
$ kubectl -n kyverno get endpoints kyverno-svc
NAME          ENDPOINTS                                         AGE
kyverno-svc   10.244.1.7:9443,10.244.2.9:9443,10.244.4.6:9443   41d
```

### 5.4 Rollback

```console
$ helm history kyverno -n kyverno
REVISION  UPDATED                   STATUS      CHART           APP VERSION
6         Wed Aug 12 18:03:11 2026  superseded  kyverno-3.1.4   v1.11.4
7         Thu Aug 13 10:22:41 2026  deployed    kyverno-3.2.6   v1.12.6

$ helm rollback kyverno 6 -n kyverno --wait
Rollback was a success! Happy Helming!
```

**Caveat — schema rollback is not free.** `helm rollback` reverts controller images and webhook templates, but a **CRD schema is not automatically downgraded**, and any CR already written in a newer stored version may fail validation against the older schema. Blue-green (Section 2.4) is the safe path when a migration changes CRD storage versions.

### 5.5 Golden rules

1. **Confirm the Kyverno↔Kubernetes pair** against the live compatibility matrix first.
2. **Never skip a minor version.** Read every intervening migration guide.
3. **Upgrade CRDs before controllers**, always with `--server-side`.
4. **Keep the admission controller HA** (3 replicas, `maxUnavailable: 0`, PDB) so the webhook backend is never empty.
5. **Snapshot** policies + CRDs, and use `--atomic` so a bad upgrade rolls itself back.
6. **Smoke-test** with a known-offending resource — "Pods are running" is not proof the webhooks work.

---

## 6. References

- Kyverno — Installation & upgrade methods (Helm, manifests, CRDs): https://kyverno.io/docs/installation/
- Kyverno — High Availability installation (replica counts, webhook failure policy): https://kyverno.io/docs/installation/methods/#high-availability
- Kyverno — Kubernetes / Kyverno compatibility matrix (authoritative): https://kyverno.io/docs/installation/#compatibility-matrix
- Kyverno — Upgrading Kyverno (sequential upgrades, CRD handling): https://kyverno.io/docs/installation/upgrading/
- Kyverno Helm chart source (CRD templating, `crds.install`, values): https://github.com/kyverno/kyverno/tree/main/charts/kyverno
- Kyverno GitHub Releases (per-version `install.yaml`, migration notes): https://github.com/kyverno/kyverno/releases
- Kyverno — Webhooks and failurePolicy behaviour: https://kyverno.io/docs/introduction/admission-controllers/
- Kubernetes — Server-Side Apply (why large CRDs need `--server-side`): https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes — Versioning of CustomResourceDefinitions (`storedVersions`, migration): https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definition-versioning/
- CNCF — KCA (Kyverno Certified Associate) curriculum: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf