# Cleanup Policies — Guided Exercises

> **Certification:** Kyverno Certified Associate (KCA) · **Domain topic 5.10 — Cleanup Policies** (exam weight 2.91)
>
> Kyverno gives you two independent mechanisms to *delete* existing resources on a schedule or after a lifetime — something `validate`/`mutate`/`generate` rules cannot do because they only act at admission time:
>
> 1. **Cleanup policy CRDs** — `CleanupPolicy` (namespaced) and `ClusterCleanupPolicy` (cluster‑scoped). They carry a cron `schedule`, a `match`/`exclude` selector, and optional `conditions`. The **cleanup‑controller** evaluates them like a background scan and deletes every matching resource.
> 2. **The `cleanup.kyverno.io/ttl` label** — attach it to *any* resource and the same controller deletes that single object once its TTL elapses. No policy object required.
>
> Both paths are enforced by the same component and are gated by the same RBAC. These exercises build up from a single namespaced policy to conditions, cluster scope, the RBAC model, TTL labels, and troubleshooting.
>
> **Source of truth for every command below:** Kyverno docs — *Cleanup* (<https://kyverno.io/docs/writing-policies/cleanup/>) and the KCA curriculum (<https://github.com/cncf/curriculum>).

---

## Prerequisites & environment setup

You need a throwaway cluster (`kind`, `minikube`, or k3d) and `kubectl`. **Do not run these on a shared or production cluster** — cleanup policies delete real objects.

**Steps**

1. Create a disposable cluster:

   ```bash
   kind create cluster --name kca-cleanup
   ```

2. Install Kyverno with Helm (the cleanup‑controller ships as a standard component in the default chart since v1.10):

   ```bash
   helm repo add kyverno https://kyverno.github.io/kyverno/
   helm repo update
   helm install kyverno kyverno/kyverno -n kyverno --create-namespace
   ```

3. Confirm all four controllers are running — the one you care about is **`kyverno-cleanup-controller`**:

   ```bash
   kubectl -n kyverno get deploy
   ```

   Expected (abbreviated):

   ```
   NAME                            READY   UP-TO-DATE   AVAILABLE   AGE
   kyverno-admission-controller    1/1     1            1           2m
   kyverno-background-controller   1/1     1            1           2m
   kyverno-cleanup-controller      1/1     1            1           2m
   kyverno-reports-controller      1/1     1            1           2m
   ```

4. Confirm which API group/version your install serves for the cleanup CRDs (this changed across releases — `v2alpha1 → v2beta1`, and 1.13+ may serve `kyverno.io/v2`):

   ```bash
   kubectl api-resources | grep -i cleanup
   ```

   Example output:

   ```
   cleanuppolicies          kyverno.io/v2beta1   true    CleanupPolicy
   clustercleanuppolicies   kyverno.io/v2beta1   false   ClusterCleanupPolicy
   ```

5. Create the working namespace used by every exercise:

   ```bash
   kubectl create namespace cleanup-demo
   ```

**Verify your understanding**

- Q0.1 — Which of the four Kyverno controllers actually performs the deletions, and why does that matter for RBAC?
- Q0.2 — Look at the `NAMESPACED` column in step 4. What does it tell you about the difference between `CleanupPolicy` and `ClusterCleanupPolicy`, and which one could ever delete a `PersistentVolume`?
- Q0.3 — Why can a cleanup policy remove a Pod that has already been admitted to the cluster, when a `validate` policy cannot?

---

## Exercise 1 — Your first `CleanupPolicy` (namespaced, label match + schedule)

**Goal:** delete Pods that carry a specific label, on a cron schedule, scoped to one namespace.

**Steps**

1. Create three bare Pods; two are marked disposable:

   ```bash
   kubectl -n cleanup-demo run keep-me   --image=nginx
   kubectl -n cleanup-demo run scratch-a --image=nginx -l canremove=true
   kubectl -n cleanup-demo run scratch-b --image=nginx -l canremove=true
   ```

2. Author the policy. Note the resource selector reuses the exact `match` grammar you already know from `validate` policies, and the required `schedule` field is standard 5‑field cron:

   ```yaml
   # cleanup-scratch-pods.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-scratch-pods
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Pod
           selector:
             matchLabels:
               canremove: "true"
     schedule: "*/1 * * * *"   # every minute (1 minute is the finest cron granularity)
   ```

3. Apply it and inspect it:

   ```bash
   kubectl apply -f cleanup-scratch-pods.yaml
   kubectl -n cleanup-demo get cleanuppolicy
   ```

   Expected:

   ```
   NAME                   SCHEDULE      AGE
   cleanup-scratch-pods   */1 * * * *   5s
   ```

4. Wait for the next minute boundary, then re‑list the Pods:

   ```bash
   sleep 65
   kubectl -n cleanup-demo get pods
   ```

   Expected — only the unlabeled Pod survives:

   ```
   NAME      READY   STATUS    RESTARTS   AGE
   keep-me   1/1     Running   0          2m
   ```

5. Confirm the controller recorded the action as an event on the policy object:

   ```bash
   kubectl -n cleanup-demo describe cleanuppolicy cleanup-scratch-pods
   ```

   Expected (tail, exact wording varies by version):

   ```
   Events:
     Type    Reason          Age   From                        Message
     ----    ------          ----  ----                        -------
     Normal  PolicyApplied   30s   kyverno-cleanup-controller  successfully cleaned up target resources
   ```

**Verify your understanding**

- Q1.1 — The `schedule` field is required. What is the smallest interval you can express, and what does that imply for how "instantly" a cleanup policy reacts to a resource that starts matching?
- Q1.2 — This policy lives in `cleanup-demo`. If an identical `canremove=true` Pod existed in `default`, would it be deleted? Why or why not?
- Q1.3 — You edited `keep-me` to add `canremove=true`. Do you have to re‑apply the policy for it to be swept on the next run?
- Q1.4 — A `validate` policy uses `request.object` in its rules. What is the analogous variable a cleanup policy uses to reference the resource being evaluated? (Foreshadowing Exercise 2.)

---

## Exercise 2 — `conditions` and the `target` variable

**Goal:** delete only the resources that satisfy a data‑driven predicate, using JMESPath over the candidate resource exposed as **`target`**.

**Steps**

1. Create two Deployments with different replica counts:

   ```bash
   kubectl -n cleanup-demo create deployment web-small --image=nginx --replicas=1
   kubectl -n cleanup-demo create deployment web-big   --image=nginx --replicas=3
   ```

2. Author a policy that matches *all* Deployments but only deletes those scaled below 2 replicas. The candidate resource is referenced as `{{ target.* }}`:

   ```yaml
   # cleanup-underscaled.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-underscaled
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Deployment
     conditions:
       all:
       - key: "{{ target.spec.replicas }}"
         operator: LessThan
         value: 2
     schedule: "*/1 * * * *"
   ```

3. Apply, wait a cycle, and observe the outcome:

   ```bash
   kubectl apply -f cleanup-underscaled.yaml
   sleep 65
   kubectl -n cleanup-demo get deploy
   ```

   Expected — `web-big` (3 replicas) remains, `web-small` (1 replica) is gone:

   ```
   NAME      READY   UP-TO-DATE   AVAILABLE   AGE
   web-big   3/3     3            3           2m
   ```

4. **Advanced predicate — "bare" resources.** Conditions are full JMESPath, so you can key off structure that isn't a scalar. This condition deletes only Pods with *no* `ownerReferences` (i.e. not managed by a ReplicaSet/Job/StatefulSet):

   ```yaml
   conditions:
     all:
     - key: "{{ target.metadata.ownerReferences[] || `[]` | length(@) }}"
       operator: Equals
       value: 0
   ```

   The `|| `[]`` guard supplies an empty array when the field is absent, and `` `0` ``/`` `[]` `` backticks are how Kyverno JMESPath writes literal JSON.

**Verify your understanding**

- Q2.1 — Precisely what object does `target` resolve to during evaluation, and how does it differ from `request.object`?
- Q2.2 — You wrote `conditions.all`. What changes if you use `conditions.any` with two conditions? Give a one‑line rule for when to pick each.
- Q2.3 — In step 4, why is the `|| `[]`` fallback necessary rather than just writing `{{ target.metadata.ownerReferences | length(@) }}`?
- Q2.4 — `match` selects Deployments and `conditions` filters on replicas. Why is it usually cheaper/clearer to narrow with `match` first rather than moving the kind filter into a condition?

---

## Exercise 3 — Cluster‑scoped cleanup (`ClusterCleanupPolicy`)

**Goal:** understand when only a cluster‑scoped policy will do, and scope it safely so it can't sweep the whole cluster.

**Steps**

1. Create a Job that runs to completion:

   ```bash
   kubectl -n cleanup-demo create job pi --image=perl:5.34 -- perl -Mbignum=bpi -wle 'print bpi(20)'
   kubectl -n cleanup-demo wait --for=condition=complete job/pi --timeout=120s
   ```

2. Author a **`ClusterCleanupPolicy`** that removes *completed* Jobs — but constrain it to the demo namespace with the `namespaces` selector so it cannot touch `kube-system` or anything else:

   ```yaml
   # cleanup-completed-jobs.yaml
   apiVersion: kyverno.io/v2beta1
   kind: ClusterCleanupPolicy
   metadata:
     name: cleanup-completed-jobs
   spec:
     match:
       any:
       - resources:
           kinds:
             - Job
           namespaces:
             - cleanup-demo      # <-- safety scope; without it this is cluster-wide
     conditions:
       all:
       - key: "{{ target.status.succeeded || `0` }}"
         operator: GreaterThanOrEquals
         value: 1
     schedule: "*/1 * * * *"
   ```

3. Apply and observe:

   ```bash
   kubectl apply -f cleanup-completed-jobs.yaml
   kubectl get clustercleanuppolicy
   sleep 65
   kubectl -n cleanup-demo get jobs
   ```

   Expected — the completed Job is removed:

   ```
   No resources found in cleanup-demo namespace.
   ```

**Verify your understanding**

- Q3.1 — Give two resource kinds that a `CleanupPolicy` (namespaced) can *never* delete, forcing you to use `ClusterCleanupPolicy`.
- Q3.2 — The manifest has no `metadata.namespace`. What is the blast radius of a `ClusterCleanupPolicy` whose `match` omits the `namespaces` selector, and why is that the single most dangerous mistake in this topic?
- Q3.3 — Why guard the condition with `{{ target.status.succeeded || `0` }}` instead of `{{ target.status.succeeded }}` on a Job that hasn't finished yet?

---

## Exercise 4 — RBAC: granting the cleanup‑controller delete rights

**Goal:** understand that *the controller's ServiceAccount*, not you, deletes the resource — so cleanup fails with a `Forbidden` error unless the aggregated cleanup role covers that kind. You'll reproduce the failure and fix it.

**Steps**

1. Inspect the aggregation rule the controller's ClusterRole uses. **Copy the exact `matchLabels` you see** — they differ across versions, so never hardcode them from memory:

   ```bash
   kubectl get clusterrole kyverno:cleanup-controller:core -o yaml
   # If that name isn't present, list candidates:
   kubectl get clusterrole | grep cleanup
   ```

   You are looking for a block like:

   ```yaml
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         app.kubernetes.io/part-of: kyverno
         rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   ```

2. Create a resource of a kind that the default cleanup role does **not** cover (Ingress is a good candidate; if your default role already covers it, pick any kind absent from the aggregated rules):

   ```bash
   kubectl -n cleanup-demo create ingress demo \
     --rule="demo.local/*=svc:80" --class=nginx
   kubectl -n cleanup-demo label ingress demo canremove=true
   ```

3. Apply a policy targeting it:

   ```yaml
   # cleanup-ingress.yaml
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: cleanup-ingress
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds:
             - Ingress
           selector:
             matchLabels:
               canremove: "true"
     schedule: "*/1 * * * *"
   ```

   ```bash
   kubectl apply -f cleanup-ingress.yaml
   ```

4. Wait a cycle and read the controller log — the deletion is **denied**, and the Ingress survives:

   ```bash
   sleep 65
   kubectl -n cleanup-demo get ingress
   kubectl -n kyverno logs deploy/kyverno-cleanup-controller | grep -i forbidden | tail -1
   ```

   Expected log line (abbreviated):

   ```
   "level":"error" "msg":"failed to cleanup" "policy":"cleanup-demo/cleanup-ingress"
   "error":"ingresses.networking.k8s.io \"demo\" is forbidden:
   User \"system:serviceaccount:kyverno:kyverno-cleanup-controller\" cannot delete
   resource \"ingresses\" in API group \"networking.k8s.io\""
   ```

5. Grant the permission by creating a ClusterRole **labelled to aggregate into the cleanup role** — reuse the `matchLabels` you copied in step 1:

   ```yaml
   # rbac-cleanup-ingress.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:cleanup-ingress
     labels:
       # MUST match the clusterRoleSelectors from step 1
       app.kubernetes.io/part-of: kyverno
       rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
   rules:
   - apiGroups: ["networking.k8s.io"]
     resources: ["ingresses"]
     verbs: ["get", "list", "watch", "delete"]
   ```

   ```bash
   kubectl apply -f rbac-cleanup-ingress.yaml
   sleep 65
   kubectl -n cleanup-demo get ingress
   ```

   Expected — the Ingress is now gone:

   ```
   No resources found in cleanup-demo namespace.
   ```

**Verify your understanding**

- Q4.1 — Whose identity appears in the `Forbidden` message, and why is it *not* your `kubectl` user?
- Q4.2 — Why does Kyverno use an *aggregated* ClusterRole (labels + `aggregationRule`) instead of asking you to edit the controller's ClusterRole directly?
- Q4.3 — Your policy validated and was accepted by the API server, yet nothing was deleted. Which of the "ladder of checks" does a missing‑RBAC failure land on — is it caught at policy admission or only at execution time? What's the practical monitoring lesson?
- Q4.4 — Which verbs, at minimum, must the ClusterRole grant for cleanup to work, and why is `delete` alone insufficient?

---

## Exercise 5 — TTL‑based cleanup with the `cleanup.kyverno.io/ttl` label

**Goal:** expire a single object without authoring any policy, and internalize the label‑value constraint that dictates the accepted TTL formats.

**Steps**

1. Create a Pod that should live only two minutes, using the reserved label:

   ```bash
   kubectl -n cleanup-demo run ephemeral --image=nginx -l cleanup.kyverno.io/ttl=2m
   ```

2. Confirm the label is present and note the creation time (the countdown starts from `creationTimestamp` for durations):

   ```bash
   kubectl -n cleanup-demo get pod ephemeral \
     -o jsonpath='{.metadata.labels.cleanup\.kyverno\.io/ttl}{"\n"}'
   # -> 2m
   ```

3. Wait past the TTL and confirm removal:

   ```bash
   sleep 130
   kubectl -n cleanup-demo get pod ephemeral
   # -> Error from server (NotFound): pods "ephemeral" not found
   ```

4. **Absolute expiry.** You can also set an absolute date. Try to set a precise timestamp first and observe the API server reject it:

   ```bash
   kubectl -n cleanup-demo run late --image=nginx \
     -l cleanup.kyverno.io/ttl=2026-12-31T23:59:59Z
   ```

   Expected — the object is rejected before Kyverno ever sees it:

   ```
   The Pod "late" is invalid: metadata.labels: Invalid value:
   "2026-12-31T23:59:59Z": a valid label must be an empty string or
   consist of alphanumeric characters, '-', '_' or '.' ...
   ```

   Now use the date‑only form, which *is* a valid label value:

   ```bash
   kubectl -n cleanup-demo run late --image=nginx -l cleanup.kyverno.io/ttl=2026-12-31
   ```

**Verify your understanding**

- Q5.1 — Which controller enforces the `cleanup.kyverno.io/ttl` label — and does the label mechanism require you to create a `CleanupPolicy` object?
- Q5.2 — In step 4 the colon‑bearing RFC3339 timestamp was rejected. *Why* — what is the underlying Kubernetes constraint, and what does it imply about the finest absolute granularity you can express through the label? How would you express "delete in 90 minutes" instead?
- Q5.3 — A resource carries `cleanup.kyverno.io/ttl=1h` but its kind isn't covered by the aggregated cleanup ClusterRole. What happens at expiry, and where would you see the symptom? (Tie back to Exercise 4.)
- Q5.4 — Name one operational advantage of the TTL label over a `CleanupPolicy` CRD, and one advantage of the CRD over the label.

---

## Exercise 6 — Observability & troubleshooting

**Goal:** learn the three authoritative signals for "did my cleanup run, and what did it do?" and how the controller schedules work.

**Steps**

1. **Policy events** — the per‑run record, attached to the policy object:

   ```bash
   kubectl -n cleanup-demo get events \
     --field-selector involvedObject.kind=CleanupPolicy
   ```

2. **Controller logs** — the ground truth for successes *and* errors (this is where `Forbidden`, bad JMESPath, and unparseable schedules surface):

   ```bash
   kubectl -n kyverno logs deploy/kyverno-cleanup-controller --tail=50
   ```

3. **Scheduling artifact** — depending on your Kyverno version, the cleanup‑controller either runs an internal scheduler or materializes a Kubernetes `CronJob` per policy in the `kyverno` namespace. Check both, and treat events/logs (steps 1–2) as authoritative regardless of which you see:

   ```bash
   kubectl -n kyverno get cronjob
   ```

   Possible output (version‑dependent — the name is derived from the policy and may carry a hash):

   ```
   NAME                   SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
   cleanup-scratch-pods   */1 * * * *   False     0        41s             5m
   ```

4. **Break it on purpose** to see validation. Apply a policy with an invalid cron and watch the admission webhook reject it *before* it is ever stored:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v2beta1
   kind: CleanupPolicy
   metadata:
     name: bad-schedule
     namespace: cleanup-demo
   spec:
     match:
       any:
       - resources:
           kinds: ["Pod"]
     schedule: "every minute"
   EOF
   ```

   Expected:

   ```
   Error from server: admission webhook "vcleanuppolicy.kyverno.svc" denied the request:
   spec.schedule: Invalid value: "every minute": schedule spec in the cleanupPolicy is not in proper cron format
   ```

**Verify your understanding**

- Q6.1 — You have three signals: policy events, controller logs, and the scheduling artifact. Which one alone proves a *deletion actually happened*, and which one would you check first when the answer is "nothing got deleted"?
- Q6.2 — In step 4 the bad schedule was rejected at apply time. Contrast that with the RBAC failure in Exercise 4, which was accepted at apply time. What does that tell you about *which* failure classes Kyverno can catch at admission versus only at execution?
- Q6.3 — A cleanup policy exists, its schedule is valid, RBAC is correct, but the target still isn't deleted. Give two `conditions`‑related root causes and the exact command you'd use to confirm each against a live resource.

---

<details>
<summary><strong>Answers</strong></summary>

### Setup

- **Q0.1** — The **`kyverno-cleanup-controller`** deployment performs every deletion (both CRD‑driven and TTL‑label‑driven). It matters because deletions are executed under *the controller's* ServiceAccount (`system:serviceaccount:kyverno:kyverno-cleanup-controller`), not under the identity of whoever applied the policy — so the controller must itself hold `delete` rights on the target kind (see Exercise 4).
- **Q0.2** — `NAMESPACED=true` for `CleanupPolicy` means it can only select namespaced resources and only within its own namespace; `ClusterCleanupPolicy` (`NAMESPACED=false`) is cluster‑scoped and can additionally target **cluster‑scoped** resources. Only a `ClusterCleanupPolicy` could ever delete a `PersistentVolume`, `Namespace`, `PV`, `ClusterRole`, etc.
- **Q0.3** — `validate`/`mutate`/`generate` run through the *admission* webhook and only see a resource at create/update time. Cleanup policies run in the **background** on a cron, evaluating resources that already exist in etcd — so they can act on objects long after admission.

### Exercise 1

- **Q1.1** — Cron's finest granularity is **one minute** (`*/1 * * * *` or `* * * * *`). A cleanup policy is therefore *not* real‑time: a resource that starts matching may live up to ~1 minute (plus controller processing latency) before the next scheduled sweep removes it.
- **Q1.2** — No. A namespaced `CleanupPolicy` only evaluates resources **in its own namespace** (`cleanup-demo`). A `canremove=true` Pod in `default` is untouched unless a policy exists there (or a `ClusterCleanupPolicy` covers it).
- **Q1.3** — No. `match`/`conditions` are re‑evaluated against the live cluster on every scheduled run. Adding the label to `keep-me` means it will be swept on the next tick; the policy object doesn't change.
- **Q1.4** — **`target`** (i.e. `{{ target.* }}`), the candidate resource under evaluation — the cleanup analogue of `request.object`.

### Exercise 2

- **Q2.1** — `target` is the **full manifest of the existing resource** currently being considered for deletion (its live `spec`, `status`, `metadata`, etc., as stored in the cluster). `request.object` is only defined in the admission context (the object *being admitted*); cleanup runs in the background with no admission request, so it exposes the resource as `target` instead — and crucially `target` includes populated `status`, which admission‑time `request.object` often does not.
- **Q2.2** — `all` is logical AND (every condition must be true); `any` is logical OR (at least one). Rule of thumb: use `all` when *every* criterion must hold to justify deletion (the safe default), `any` when *any single* red flag is sufficient.
- **Q2.3** — When a Pod has no owner, `target.metadata.ownerReferences` is **absent** (null), and `length(null)` errors / evaluates unusably. `|| `[]`` substitutes an empty array so `length(@)` reliably yields `0`. It normalizes "field missing" and "field empty" to the same, comparable value.
- **Q2.4** — `match` is a cheap structural/label selector applied first; narrowing kind there means `conditions` (JMESPath evaluated per candidate) only run against the already‑reduced set. It's both faster and more readable — `conditions` should express *data* predicates, not resource‑type filtering.

### Exercise 3

- **Q3.1** — Any cluster‑scoped kind, e.g. **`Namespace`, `PersistentVolume`, `ClusterRole`, `Node`, `StorageClass`**. A namespaced `CleanupPolicy` cannot select them.
- **Q3.2** — Without a `namespaces` (or label/`namespaceSelector`) constraint, a `ClusterCleanupPolicy` matches the kind **in every namespace of the cluster**, including `kube-system`. It's the most dangerous mistake because a broad `kinds: [Pod]` + a permissive/absent condition would sweep system workloads cluster‑wide on a schedule. Always scope cluster policies tightly.
- **Q3.3** — On a running/pending Job, `status.succeeded` is unset (null). `{{ target.status.succeeded }}` would then compare null against `1` and behave unpredictably; `|| `0`` coerces "not yet succeeded" to `0`, so the `>= 1` predicate is false and the Job is correctly spared until it actually completes.

### Exercise 4

- **Q4.1** — `system:serviceaccount:kyverno:kyverno-cleanup-controller`. Kyverno deletes on your behalf using **its own** ServiceAccount, so your personal `kubectl` permissions are irrelevant — the controller's RBAC is what's checked.
- **Q4.2** — Aggregation lets you *extend* the controller's permissions by adding a small, self‑contained ClusterRole with the right labels, without editing (and risking clobbering on upgrade) Kyverno's managed roles. The Helm chart owns `kyverno:cleanup-controller*`; your additive role survives chart upgrades.
- **Q4.3** — It is **not** caught at policy admission — the policy is valid and stored. It fails only at **execution time**, visible only in the cleanup‑controller logs (and as a `PolicyError`/failed event), never as a `kubectl apply` error. Practical lesson: "policy applied successfully" ≠ "cleanup works"; you must monitor controller logs/events to know deletions are actually succeeding.
- **Q4.4** — At minimum **`get`, `list`, `watch`, `delete`**. `delete` alone is insufficient because the controller must first *discover and read* the candidate resources (list/watch/get) before it can delete them; without the read verbs it can't enumerate what to clean up.

### Exercise 5

- **Q5.1** — The **cleanup‑controller** enforces the `cleanup.kyverno.io/ttl` label. It requires **no `CleanupPolicy` object** — labelling the resource is sufficient; the controller watches for the label and schedules the deletion.
- **Q5.2** — Kubernetes **label values may only contain alphanumerics, `-`, `_`, `.` (≤63 chars)** — colons are illegal, so an RFC3339 timestamp like `2026-12-31T23:59:59Z` is rejected by the API server before Kyverno is involved. Consequently the absolute form must be **date‑only (`YYYY-MM-DD`)**, granularity of one day. For sub‑day precision use a **duration** instead: `cleanup.kyverno.io/ttl=90m` (or `1h30m`).
- **Q5.3** — Nothing gets deleted. At expiry the controller attempts the delete under its ServiceAccount, hits a `Forbidden` error (identical class to Exercise 4), and the object lingers. The symptom appears **only in the cleanup‑controller logs** — you'd fix it by adding an aggregated ClusterRole granting `delete` (+read verbs) on that kind.
- **Q5.4** — TTL label advantage: **per‑object, zero policy management** — great for ephemeral/preview resources tagged at creation. CRD advantage: **declarative, fleet‑wide, condition‑driven** cleanup that applies to *all current and future* matching resources centrally (e.g. "every completed Job older than X"), auditable as one policy object rather than N labels.

### Exercise 6

- **Q6.1** — **Controller logs** are the only signal that proves a deletion actually executed (or failed, and why). Policy **events** summarize per‑run outcomes and are a good first stop; the CronJob/scheduler artifact only proves the *schedule* is registered, not that anything was deleted. When "nothing got deleted," check the logs first.
- **Q6.2** — Kyverno catches **structural/static** faults at admission via the validating webhook — malformed cron, bad policy shape, etc. — and rejects them at apply time. **Semantic/runtime** faults — insufficient RBAC, a condition that matches nothing, a JMESPath that errors on live data — cannot be known until the scheduled run, so they only surface at execution in logs/events. Admission validation is necessary but not sufficient.
- **Q6.3** — Two condition‑related causes: (1) the `conditions` predicate is simply false for the resource — confirm with `kubectl get <res> -o yaml` and manually evaluate the keyed path (e.g. `kubectl get deploy web-small -o jsonpath='{.spec.replicas}'`); (2) the JMESPath keys a field that's absent/null so the condition never evaluates true — confirm the path exists on the live object with `kubectl get <res> -o jsonpath='{.status.succeeded}'` (empty output ⇒ you need a `|| `0`` / `|| `[]`` fallback). Cross‑check against the controller logs for any per‑resource evaluation errors.

</details>

---

**References**

- Kyverno — *Cleanup Policies*: <https://kyverno.io/docs/writing-policies/cleanup/>
- Kyverno — RBAC / role aggregation for controllers: <https://kyverno.io/docs/installation/customization/>
- Kyverno source (CRD API versions & cleanup‑controller): <https://github.com/kyverno/kyverno>
- CNCF — Kyverno Certified Associate curriculum: <https://github.com/cncf/curriculum>