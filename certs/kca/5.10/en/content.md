# 5.10 Cleanup Policies

> **Exam domain 5 — Applying Kyverno · Weight: 2.91**
> Kyverno Certified Associate (KCA). This topic covers Kyverno's *declarative deletion* subsystem: `CleanupPolicy`, `ClusterCleanupPolicy`, and the label-driven `cleanup.kyverno.io/ttl` TTL mechanism. Everything below assumes Kyverno ≥ 1.11 with the four-controller split (admission / background / reports / **cleanup**).

---

## 1. Motivation and the production problem

Every Kubernetes cluster leaks. Not memory — *objects*. The API server is a general-purpose datastore, and there is no built-in garbage collector for the vast majority of resource kinds. Kubernetes ships exactly three narrow cleanup primitives:

- **Owner-reference cascading GC** — deletes children when a parent is deleted (the `metadata.ownerReferences` graph walked by `kube-controller-manager`'s garbage collector).
- **`ttlSecondsAfterFinished`** — deletes `Job` objects a fixed time after completion (the TTL-after-finished controller).
- **CronJob history limits** — `successfulJobsHistoryLimit` / `failedJobsHistoryLimit`.

Everything outside those three lives forever unless a human or an operator deletes it. In production this manifests as:

- **Orphaned bare Pods** left behind by imperative `kubectl run`, failed operators, or evicted workloads stuck in `Failed`/`Succeeded`.
- **Stale ConfigMaps/Secrets** from Helm releases, cert rotation, or CI pipelines that create per-build objects.
- **Expired ephemeral namespaces** from PR-preview environments and short-lived tenant sandboxes.
- **Abandoned PVCs, Ingresses, and NetworkPolicies** whose owning workload was deleted but which had no owner reference.
- **etcd bloat and watch-cache pressure**: every lingering object consumes etcd space, inflates `LIST` responses, slows informer resyncs, and raises the blast radius of a full-cluster `kubectl get`. A cluster with 200k dead objects has measurably slower control-plane latency.

The architectural problem is that cleanup logic is **cross-cutting policy**, not workload logic. Encoding "delete any Pod that has been `Succeeded` for more than an hour" inside every team's Helm chart is unenforceable and non-auditable. Kyverno's answer is to move deletion into the same declarative, cluster-scoped policy plane that already governs `validate`/`mutate`/`generate` — with the same `match`/`exclude` selectors, the same JMESPath context, RBAC-gated execution, events, metrics, and a `PolicyReport`-adjacent audit trail.

Two complementary mechanisms exist:

| Mechanism | Kind / trigger | Who decides *what* to delete | Who decides *when* |
|---|---|---|---|
| **Cleanup Policy** | `CleanupPolicy` (namespaced), `ClusterCleanupPolicy` (cluster) | Platform team, via `match`/`exclude`/`conditions` | A cron `schedule` on the policy |
| **TTL label** | `cleanup.kyverno.io/ttl` label on any resource | The resource author (self-service) | An absolute time or duration in the label value |

Cleanup Policies are **centralized governance** ("the platform reaps"); the TTL label is **decentralized self-service** ("the owner sets its own expiry"). Both are executed by the same **cleanup controller** and both are RBAC-gated by the same aggregated ClusterRole.

---

## 2. Architecture and internal mechanics

### 2.1 The cleanup controller

Since the 1.10 controller split, cleanup runs in a dedicated `Deployment` — `kyverno-cleanup-controller` — separate from the admission webhook. This isolation matters operationally: a cleanup bug cannot stall admission, and the two scale independently. The cleanup controller does three jobs:

1. Serves a **validating admission webhook** for `CleanupPolicy`/`ClusterCleanupPolicy` objects themselves (rejects invalid cron expressions, malformed conditions, etc.).
2. Runs the **TTL reconciler** that watches resources carrying `cleanup.kyverno.io/ttl`.
3. Serves an authenticated HTTPS **`/cleanup` endpoint** that performs the actual match + condition evaluation + delete for scheduled policies.

### 2.2 The CronJob offload — the detail most people miss

Kyverno does **not** run an in-process scheduler for cleanup policies. Instead, for every `CleanupPolicy`/`ClusterCleanupPolicy`, the cleanup controller **generates a Kubernetes `CronJob`** in the Kyverno namespace, owned by the policy. When that CronJob fires, its Job Pod makes an authenticated `wget`/`curl` call back to the cleanup controller's `/cleanup` endpoint (over TLS, using the mounted CA), and the controller then evaluates `match`/`exclude`/`conditions` against live cluster state and issues the `DELETE` calls.

```
┌────────────────┐  reconciles   ┌──────────────────────────┐
│ ClusterCleanup │──────────────▶│  generated CronJob        │
│ Policy (cron)  │  owns         │  (kyverno namespace)      │
└────────────────┘               └───────────┬──────────────┘
                                     fires    │  HTTPS + CA
                                              ▼
                                 ┌──────────────────────────┐
                                 │ kyverno-cleanup-controller│
                                 │  /cleanup endpoint         │
                                 │  match/exclude/conditions  │
                                 │  → DELETE via K8s API      │
                                 └──────────────────────────┘
```

Consequences for SREs:
- The **minimum resolution is one minute** — you inherit Kubernetes CronJob semantics, so sub-minute schedules are impossible.
- Deleting a Cleanup Policy **garbage-collects its CronJob** via owner reference.
- If the cleanup controller Service is unreachable from the Job Pod (a `NetworkPolicy` blocking egress, for example), the CronJob's Job Pods fail and *nothing gets cleaned* — yet the policy still shows healthy. Diagnose at the CronJob/Job layer, not just the policy.

### 2.3 The candidate variable: `target`

Inside `conditions`, the resource currently being evaluated is exposed as **`{{ target }}`**. You write JMESPath over `target.metadata`, `target.spec`, `target.status`, etc. This is the key difference from validate rules (which expose `request.object`): cleanup is a *reconcile* over existing objects, so there is no admission request — only a `target`.

---

## 3. Comparative analysis and trade-offs

### 3.1 Kyverno cleanup vs. Kubernetes-native primitives

| Capability | `CleanupPolicy` | TTL label | `ttlSecondsAfterFinished` | CronJob history limits | Owner-ref GC |
|---|---|---|---|---|---|
| Applies to arbitrary kinds | ✅ any GVK Kyverno can delete | ✅ any labeled object | ❌ Jobs only | ❌ Jobs of a CronJob | ✅ but only via ownership |
| Condition-based (status/spec fields) | ✅ JMESPath/CEL over `target` | ❌ time-only | ❌ | ❌ | ❌ |
| Central governance (author ≠ owner) | ✅ | ❌ owner sets it | ❌ | ❌ | ❌ |
| Self-service per object | via `match` selectors | ✅ | ✅ | ✅ | ✅ |
| Time granularity | ≥ 1 min (cron) | absolute or duration | seconds | count-based | event-driven |
| Requires extra RBAC grants | ✅ (aggregated role) | ✅ (same) | ❌ | ❌ | ❌ |
| Audit trail / events / metrics | ✅ | ✅ | limited | limited | limited |
| Deletion propagation control | ✅ `deletionPropagationPolicy` | ❌ | ❌ | ❌ | Foreground/Background/Orphan on delete |

### 3.2 Kyverno cleanup vs. external janitors

| | Kyverno Cleanup | `kube-janitor` / `k8s-ttl-controller` | GitOps prune (Argo CD / Flux) |
|---|---|---|---|
| Policy model | Same engine as validate/mutate/generate | Standalone annotation/rules engine | Desired-state reconciliation |
| Deletes *unmanaged* drift | ✅ | ✅ | ❌ only prunes what Git once declared |
| Condition expressiveness | JMESPath + CEL, `context` API calls | JMESPath-ish rules | n/a |
| Single policy plane | ✅ one operator, one RBAC model | ➕ another operator to run | separate concern |
| Best for | Governance + ad-hoc reaping across the fleet | Lightweight TTL-only shops | Reconciling Git-owned resources |

**Rule of thumb:** use **owner references** for parent/child lifecycles (free, event-driven, no RBAC); use the **TTL label** for self-service expiry of individual objects; use **Cleanup Policies** when the platform must enforce reaping based on *conditions* (status, age, ownership emptiness) across resources it does not own; use **GitOps prune** only for objects that Git declared.

### 3.3 `deletionPropagationPolicy` trade-offs

| Value | Behavior | Use when |
|---|---|---|
| `Foreground` | Delete dependents *before* the owner returns; owner blocks until children gone | You need guaranteed cascade completion (e.g., delete a Deployment and confirm its Pods are gone) |
| `Background` (K8s default) | Delete owner immediately, GC reaps children async | Throughput matters; eventual consistency acceptable |
| `Orphan` | Delete only the owner, leave children | Re-parenting / adoption workflows; deliberate detach |

If unset, the API server's default (`Background` for most kinds) applies.

---

## 4. Complete, syntactically valid manifests

### 4.1 RBAC — the prerequisite everyone forgets

Kyverno's cleanup controller ships with **no delete permission** on your workload kinds by default. You extend it by creating a `ClusterRole` bearing the aggregation label `rbac.kyverno.io/aggregate-to-cleanup-controller: "true"`. Kyverno's `kyverno:cleanup-controller` role has an `aggregationRule` that pulls these in automatically — no rebind needed.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-controller:extra
  labels:
    app.kubernetes.io/part-of: kyverno
    # This label is what makes the rules take effect for cleanup:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
  - apiGroups: [""]
    resources: ["pods", "configmaps"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "delete"]
```

> `get`, `list`, and `watch` are required so the controller can *find* candidates; `delete` is required to reap them. Omit `list`/`watch` and the controller silently finds nothing.

### 4.2 `ClusterCleanupPolicy` — reap orphaned (bare) Pods

Deletes Pods with **no** owner references (i.e., not managed by a ReplicaSet/Job/etc.) that are in a terminal phase, every 10 minutes.

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-bare-terminal-pods
spec:
  match:
    any:
      - resources:
          kinds:
            - Pod
  exclude:
    any:
      - resources:
          namespaces:
            - kube-system
            - kyverno
  conditions:
    all:
      # No controller owns this Pod → it is "bare"
      - key: "{{ target.metadata.ownerReferences[] || `[]` | length(@) }}"
        operator: Equals
        value: 0
      # …and it has finished (Succeeded or Failed)
      - key: "{{ target.status.phase }}"
        operator: AnyIn
        value:
          - Succeeded
          - Failed
  deletionPropagationPolicy: Foreground
  schedule: "*/10 * * * *"
```

### 4.3 `ClusterCleanupPolicy` — scale-to-zero Deployments flagged for removal

```yaml
apiVersion: kyverno.io/v2beta1
kind: ClusterCleanupPolicy
metadata:
  name: cleanup-empty-flagged-deployments
spec:
  match:
    any:
      - resources:
          kinds:
            - Deployment
          selector:
            matchLabels:
              canremove: "true"
  conditions:
    any:
      - key: "{{ target.spec.replicas }}"
        operator: Equals
        value: 0
  schedule: "*/15 * * * *"
```

### 4.4 Namespaced `CleanupPolicy` — reap Completed Jobs older than 24h in one tenant

`CleanupPolicy` is namespaced; its `match` is implicitly scoped to `metadata.namespace`. This uses `time_since` to compute age against `.status.completionTime`.

```yaml
apiVersion: kyverno.io/v2beta1
kind: CleanupPolicy
metadata:
  name: cleanup-old-completed-jobs
  namespace: team-ci
spec:
  match:
    any:
      - resources:
          kinds:
            - Job
  conditions:
    all:
      - key: "{{ target.status.succeeded || `0` }}"
        operator: GreaterThanOrEquals
        value: 1
      # Age since completion exceeds 24h → time_since returns "HH:MM:SS",
      # compare the total hours crossing the day boundary.
      - key: "{{ time_since('', '{{ target.status.completionTime }}', '') }}"
        operator: GreaterThan
        value: "24:00:00"
  schedule: "0 * * * *"
```

### 4.5 TTL label — self-service per-object expiry

No policy object required beyond the RBAC grant in 4.1. The resource author stamps a label; the TTL reconciler deletes it when the label's clock expires. Three accepted value forms:

```yaml
# a) Relative duration (Go-style): delete 2 hours after the label is observed
apiVersion: v1
kind: Pod
metadata:
  name: debug-shell
  labels:
    cleanup.kyverno.io/ttl: 2h
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "infinity"]
---
# b) Absolute RFC3339 timestamp: delete at a wall-clock instant
apiVersion: v1
kind: ConfigMap
metadata:
  name: pr-1234-preview-config
  labels:
    cleanup.kyverno.io/ttl: "2026-08-20T00:00:00Z"
data:
  env: preview
---
# c) Date-only: delete at 00:00 UTC on that date
apiVersion: v1
kind: Secret
metadata:
  name: temp-signing-key
  labels:
    cleanup.kyverno.io/ttl: "2026-08-31"
type: Opaque
stringData:
  key: rotate-me
```

Enforce the label at admission with a companion mutate/validate policy so ephemeral namespaces always carry an expiry — closing the loop between admission governance and cleanup.

---

## 5. CLI walkthrough with real terminal output

### 5.1 Confirm the cleanup controller is running

```console
$ kubectl -n kyverno get deploy
NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
kyverno-admission-controller    1/1     1            1           9d
kyverno-background-controller   1/1     1            1           9d
kyverno-cleanup-controller      1/1     1            1           9d
kyverno-reports-controller      1/1     1            1           9d
```

### 5.2 Apply and inspect a policy

```console
$ kubectl apply -f cleanup-bare-terminal-pods.yaml
clustercleanuppolicy.kyverno.io/cleanup-bare-terminal-pods created

$ kubectl get clustercleanuppolicy
NAME                          SCHEDULE       AGE
cleanup-bare-terminal-pods    */10 * * * *   12s

$ kubectl describe clustercleanuppolicy cleanup-bare-terminal-pods | sed -n '1,25p'
Name:         cleanup-bare-terminal-pods
Kind:         ClusterCleanupPolicy
API Version:  kyverno.io/v2beta1
Spec:
  Deletion Propagation Policy:  Foreground
  Schedule:                     */10 * * * *
Status:
  Conditions:
    Message:               Ready
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
  Last Execution Time:     2026-08-13T18:20:00Z
Events:
  Type    Reason         Age    From             Message
  ----    ------         ----   ----             -------
  Normal  PolicyApplied  8m     kyverno-cleanup  successfully deleted the target resources
```

### 5.3 Observe the auto-generated CronJob (the offload made visible)

```console
$ kubectl -n kyverno get cronjob
NAME                                 SCHEDULE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
cleanup-bare-terminal-pods-3f2a9c1   */10 * * * *   False     0        3m12s           41m

$ kubectl -n kyverno get cronjob cleanup-bare-terminal-pods-3f2a9c1 \
    -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
ClusterCleanupPolicy/cleanup-bare-terminal-pods
```

### 5.4 Prove a reap happened end-to-end

```console
$ kubectl run orphan --image=busybox:1.36 --restart=Never --command -- /bin/false
pod/orphan created

$ kubectl get pod orphan
NAME     READY   STATUS   RESTARTS   AGE
orphan   0/1     Error    0          6s          # phase=Failed, zero ownerReferences

# …wait for the next */10 tick…
$ kubectl get pod orphan
Error from server (NotFound): pods "orphan" not found

$ kubectl -n kyverno logs deploy/kyverno-cleanup-controller | grep -i deleted | tail -1
"cleaned up target resource" logger=cleanup policy=cleanup-bare-terminal-pods kind=Pod name=orphan namespace=default
```

### 5.5 TTL label in action

```console
$ kubectl apply -f debug-shell.yaml
pod/debug-shell created

$ kubectl get pod debug-shell --show-labels
NAME          READY   STATUS    RESTARTS   AGE   LABELS
debug-shell   1/1     Running   0          5s    cleanup.kyverno.io/ttl=2h

# 2 hours later:
$ kubectl get pod debug-shell
Error from server (NotFound): pods "debug-shell" not found
```

---

## 6. Verification and failure diagnosis

### 6.1 Verification ladder (cheapest → most expensive)

1. **Is the policy accepted?** — `kubectl get clustercleanuppolicy` returns it; the validating webhook rejects bad cron/conditions at apply time.
2. **Is it Ready?** — `status.conditions[type=Ready].status == True`.
3. **Did the schedule materialize?** — a matching `CronJob` exists in the `kyverno` namespace, owned by the policy.
4. **Are Jobs running and succeeding?** — `kubectl -n kyverno get jobs` shows `COMPLETIONS 1/1`, not `0/1` with backoff.
5. **Did objects actually disappear?** — the definitive proof: the target is `NotFound` after a tick.
6. **Audit trail** — `PolicyApplied` events on the policy and `"cleaned up target resource"` in the controller log.

### 6.2 Failure catalogue

| Symptom | Root cause | Diagnosis | Fix |
|---|---|---|---|
| Nothing is ever deleted; no errors | **Missing RBAC** — controller can `list` but not `delete` (or can't `list` at all) | `kubectl -n kyverno logs deploy/kyverno-cleanup-controller \| grep -i forbidden` shows `pods is forbidden ... cannot delete` | Add the kind to an aggregated ClusterRole (§4.1) with `get,list,watch,delete` |
| Policy `Ready`, CronJob exists, but Job Pods `Error` | Job Pod can't reach the cleanup controller Service (NetworkPolicy egress, DNS, TLS) | `kubectl -n kyverno logs job/<generated-job>` → connection refused / timeout | Allow egress from `kyverno` namespace to the cleanup controller Service; verify CA mount |
| Some targets skipped | **Condition/JMESPath mismatch** — `target.status.phase` empty, wrong type comparison, ownerReferences null | Dry-run the expression: `kubectl get pod x -o json \| jq '<expr>'`; mind `Equals 0` (number) vs `"0"` (string) | Guard with `|| \`[]\``, use correct operator (`AnyIn`, `GreaterThan`), match value type |
| Object refuses to delete | **Finalizer** on the target holds it in `Terminating` | `kubectl get <obj> -o jsonpath='{.metadata.finalizers}'` | Resolve the finalizer's controller; Kyverno issues `DELETE`, it does not force-remove finalizers |
| Policy rejected at apply | Invalid cron or malformed condition | `kubectl apply` returns the cleanup validating-webhook error verbatim | Fix the `schedule` (5-field cron, ≥ 1 min) or the condition schema |
| Deletes too much | `match` too broad / missing `exclude` | Test selectors against live state before enabling; start with a narrow `selector.matchLabels` | Add `exclude` for `kube-system`, `kyverno`, and protected namespaces; gate with a canary label |
| TTL label ignored | Same RBAC gap, or malformed value | Controller log: `invalid cleanup value`/`forbidden`; check the label parses as duration/RFC3339/date | Correct the value format; grant delete on that kind |

### 6.3 Observability

- **Events:** `kubectl get events -A --field-selector reason=PolicyApplied` (reap successes) and `reason=PolicyError` (failures).
- **Logs:** `kubectl -n kyverno logs deploy/kyverno-cleanup-controller -f` — every delete and every `forbidden`.
- **Metrics:** the cleanup controller exposes Prometheus metrics (e.g. a counter such as `kyverno_cleanup_controller_deletedobjects_total`, labeled by policy and resource kind). Alert on the delete rate — a sudden spike is often a mis-scoped `match`; a flatline on a policy that should be active often signals the NetworkPolicy/RBAC failures above, which are *silent* at the policy layer.

### 6.4 Safe-rollout checklist

1. Grant RBAC (§4.1) **before** the policy — otherwise the first ticks fail silently.
2. Start narrow: `selector.matchLabels: { canremove: "true" }` plus an `exclude` for system namespaces.
3. Set a **long** schedule first (`0 * * * *`), verify reaps in the log, then tighten.
4. Only widen `match` after confirming zero collateral deletions across a full cycle.
5. Never let a cleanup policy match `kube-system` or `kyverno` itself.

---

## References

- Kyverno — *Cleanup Policies* (writing policies): https://kyverno.io/docs/writing-policies/cleanup/
- Kyverno — *TTL-based cleanup* (`cleanup.kyverno.io/ttl` label): https://kyverno.io/docs/writing-policies/cleanup/#cleanup-label
- Kyverno — *ClusterCleanupPolicy / CleanupPolicy* API reference: https://kyverno.io/docs/kyverno-policies/ and https://htmlpreview.github.io/?https://github.com/kyverno/kyverno/blob/main/docs/user/crd/index.html
- Kyverno — *Controllers* (admission / background / reports / cleanup split): https://kyverno.io/docs/high-availability/
- Kyverno — *Customizing Permissions* (aggregated ClusterRoles, `rbac.kyverno.io/aggregate-to-cleanup-controller`): https://kyverno.io/docs/installation/customization/#roles-and-permissions
- Kyverno — *JMESPath* and time filters (`time_since`, `time_now`): https://kyverno.io/docs/writing-policies/jmespath/
- Kubernetes — *Garbage Collection* (owner references, propagation policies): https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes — *Automatic cleanup of finished Jobs* (`ttlSecondsAfterFinished`): https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/
- CNCF — *Kyverno Certified Associate (KCA) Curriculum*: https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf