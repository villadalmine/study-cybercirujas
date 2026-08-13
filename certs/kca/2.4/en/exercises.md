# Guided Exercises — Configuring Kyverno RBAC, Roles, and Permissions

> **Exam topic:** KCA 2.4 · Weight 3.0
> **Goal:** operate Kyverno's split-controller RBAC model with confidence — inspect the shipped `ServiceAccount`s and aggregated `ClusterRole`s, grant the *background controller* the least-privilege permissions that `generate` and `mutateExisting` rules require, expose policies and reports to developers through Kubernetes' built-in aggregation, and prove every grant with `kubectl auth can-i`.

## Prerequisites

- A working cluster where you have `cluster-admin` (kind, minikube, k3d, or a lab cluster all work).
- `kubectl` v1.27+ and Helm v3.
- Kyverno **1.10 or newer** — this is the release where Kyverno split its monolithic controller into four independent controllers, each with its own `ServiceAccount`. Everything in this topic assumes that split.

Install Kyverno from the official chart:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
kubectl -n kyverno rollout status deploy --timeout=120s
```

Expected:

```
deployment "kyverno-admission-controller" successfully rolled out
deployment "kyverno-background-controller" successfully rolled out
deployment "kyverno-cleanup-controller" successfully rolled out
deployment "kyverno-reports-controller" successfully rolled out
```

> Source: Kyverno installation — https://kyverno.io/docs/installation/ · Kyverno RBAC customization — https://kyverno.io/docs/installation/customization/

---

## Exercise 1 — Map Kyverno's identities and the controller that owns each concern

Kyverno does not run as one process with one identity. Each of the four controllers has a distinct job, and — critically for RBAC — a distinct `ServiceAccount`. Knowing which controller performs a given action tells you *which* identity to grant permissions to.

1. List the ServiceAccounts Kyverno created:

   ```bash
   kubectl get serviceaccounts -n kyverno
   ```

   Expected (secrets column trimmed):

   ```
   NAME                            AGE
   kyverno-admission-controller    3m
   kyverno-background-controller   3m
   kyverno-cleanup-controller      3m
   kyverno-reports-controller      3m
   ```

2. Map each Deployment to its ServiceAccount to confirm the one-identity-per-controller model:

   ```bash
   kubectl get deploy -n kyverno \
     -o custom-columns='DEPLOY:.metadata.name,SA:.spec.template.spec.serviceAccountName'
   ```

   Expected:

   ```
   DEPLOY                          SA
   kyverno-admission-controller    kyverno-admission-controller
   kyverno-background-controller   kyverno-background-controller
   kyverno-cleanup-controller      kyverno-cleanup-controller
   kyverno-reports-controller      kyverno-reports-controller
   ```

3. Note the division of labour (memorize this table — it is the whole point of the topic):

   | Controller | ServiceAccount | Owns |
   |---|---|---|
   | admission | `kyverno-admission-controller` | Serves the webhook; runs `validate` and `mutate` (on the incoming request); reads context resources (ConfigMaps, API calls) |
   | background | `kyverno-background-controller` | Runs `generate` and `mutateExisting` — the rules that **create/modify other resources** |
   | reports | `kyverno-reports-controller` | Background-scans existing resources and writes `PolicyReport`/`ClusterPolicyReport` |
   | cleanup | `kyverno-cleanup-controller` | Executes `CleanupPolicy` (TTL-style deletes) |

**Comprehension check 1**
- a) A `generate` rule that creates a default `NetworkPolicy` in every new namespace fails silently — nothing is generated. Which ServiceAccount's permissions do you inspect first, and why not the admission controller's?
- b) Why does Kyverno deliberately split into four ServiceAccounts instead of one? Give the RBAC-specific benefit.

---

## Exercise 2 — Understand the aggregated-ClusterRole mechanism Kyverno uses

Kyverno does **not** want you to edit its shipped `ClusterRole`s (a chart upgrade would overwrite them). Instead every controller's effective ClusterRole is an **aggregated ClusterRole**: an empty shell whose rules are assembled by the Kubernetes controller-manager from any ClusterRole carrying the right label. You extend Kyverno by *adding* a labelled ClusterRole, never by editing an existing one.

1. Look at the shell for the background controller. Notice it declares an `aggregationRule` and its `rules` are populated automatically:

   ```bash
   kubectl get clusterrole kyverno:background-controller -o yaml
   ```

   Expected (abridged):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:background-controller
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:                       # <-- filled in by the controller-manager, do not edit
   - apiGroups: [""]
     resources: [configmaps]
     verbs: [get, list, watch]
   # ...more, assembled from every matching ClusterRole
   ```

2. List the source ClusterRoles that feed that aggregate — these carry the `rbac.kyverno.io/aggregate-to-background-controller: "true"` label:

   ```bash
   kubectl get clusterroles \
     -l rbac.kyverno.io/aggregate-to-background-controller=true
   ```

   Expected:

   ```
   NAME                                     AGE
   kyverno:background-controller:core       6m
   kyverno:background-controller:additional 6m
   ```

   `:core` is Kyverno's baseline. `:additional` is an **intentionally empty placeholder** the chart ships so you have a slot — but in practice you add your own uniquely-named ClusterRole rather than editing that one.

3. Confirm the four aggregation labels exist, one per controller:

   ```bash
   kubectl get clusterroles -o jsonpath='{range .items[*]}{.metadata.labels}{"\n"}{end}' \
     | grep -o 'rbac.kyverno.io/aggregate-to-[a-z-]*' | sort -u
   ```

   Expected:

   ```
   rbac.kyverno.io/aggregate-to-admission-controller
   rbac.kyverno.io/aggregate-to-background-controller
   rbac.kyverno.io/aggregate-to-reports-controller
   ```
   *(cleanup uses its own `kyverno:cleanup-controller` aggregation label in the same family.)*

**Comprehension check 2**
- a) You edit `kyverno:background-controller:core` directly to add a permission. Two weeks later the grant is gone. What happened?
- b) What is the single label key that makes a new `ClusterRole`'s rules appear in `kyverno:background-controller`'s effective permissions? What is its value?
- c) After you create a correctly-labelled ClusterRole, which component actually merges its rules into the aggregate — Kyverno, or something native to Kubernetes?

> Source: Kubernetes aggregated ClusterRoles — https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles · Kyverno RBAC — https://kyverno.io/docs/installation/customization/

---

## Exercise 3 — Grant the background controller the permissions a `generate` rule needs

Kyverno ships with **deliberately minimal** permissions — it is not `cluster-admin`. So a `generate` rule that creates a resource type Kyverno was never granted will fail. You will reproduce that failure, then fix it the correct way.

1. Apply a policy that generates a default-deny `NetworkPolicy` into every new namespace:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: add-default-networkpolicy
   spec:
     rules:
     - name: default-deny
       match:
         any:
         - resources:
             kinds:
             - Namespace
       generate:
         apiVersion: networking.k8s.io/v1
         kind: NetworkPolicy
         name: default-deny
         namespace: "{{request.object.metadata.name}}"
         synchronize: true
         data:
           spec:
             podSelector: {}
             policyTypes:
             - Ingress
             - Egress
   EOF
   ```

2. **First, prove the identity lacks the permission** — this is the diagnostic reflex the exam rewards. Impersonate the background controller's ServiceAccount:

   ```bash
   kubectl auth can-i create networkpolicies.networking.k8s.io \
     --as=system:serviceaccount:kyverno:kyverno-background-controller \
     -n default
   ```

   Expected:

   ```
   no
   ```

3. Trigger the rule by creating a namespace, then look for the generated resource:

   ```bash
   kubectl create namespace team-a
   kubectl get networkpolicy -n team-a
   ```

   Expected — nothing is generated:

   ```
   No resources found in team-a namespace.
   ```

4. Confirm the *reason* is authorization, not a policy error. Inspect the UpdateRequest (the CR Kyverno uses to track generation) and the controller log:

   ```bash
   kubectl get updaterequests -n kyverno
   kubectl -n kyverno logs deploy/kyverno-background-controller | grep -i "forbidden\|not authorized" | tail -1
   ```

   Expected (log line, abridged):

   ```
   ... failed to generate resource ... networkpolicies.networking.k8s.io is forbidden:
   User "system:serviceaccount:kyverno:kyverno-background-controller" cannot create
   resource "networkpolicies" in API group "networking.k8s.io" in the namespace "team-a"
   ```

5. Fix it the aggregation way — create a uniquely-named ClusterRole with the background-controller label:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:generate-networkpolicies
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
   - apiGroups:
     - networking.k8s.io
     resources:
     - networkpolicies
     verbs:
     - create
     - update
     - delete
     - get
     - list
     - watch
   EOF
   ```

6. Verify the grant took effect, then re-trigger:

   ```bash
   kubectl auth can-i create networkpolicies.networking.k8s.io \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   # -> yes

   kubectl create namespace team-b
   kubectl get networkpolicy -n team-b
   ```

   Expected:

   ```
   NAME           POD-SELECTOR   AGE
   default-deny   <none>         3s
   ```

7. (Optional) Backfill the namespace that failed before the grant. Because `synchronize: true`, the background controller reconciles it — re-annotate or recreate `team-a`, or simply wait for the next reconcile; `kubectl get netpol -n team-a` should now show `default-deny`.

**Comprehension check 3**
- a) Why did `kubectl apply` of the `ClusterPolicy` succeed even though Kyverno could not fulfil it? What does that tell you about *where* generate-permission failures surface (admission time vs. runtime)?
- b) You granted `create`, `update`, and `delete`. Why does a `generate` rule with `synchronize: true` need `update` and `delete`, not just `create`?
- c) Rewrite the `can-i` command to check the permission cluster-wide instead of in one namespace. Why does the namespace matter for a `NetworkPolicy` but not for a `ClusterRole`?

> Source: Kyverno generate rules & required permissions — https://kyverno.io/docs/writing-policies/generate/ · Kyverno customizing permissions — https://kyverno.io/docs/installation/customization/

---

## Exercise 4 — Permissions for `mutateExisting` (modifying resources that already exist)

`mutate` on an *incoming* request runs in the admission controller and needs no extra RBAC (the object is in the request body). `mutateExisting` reaches out and **patches objects already in etcd** — that is the background controller acting on the cluster, so it needs `update` on the target kind.

1. Apply a policy that, whenever a namespace is labelled `stage=prod`, adds an annotation to every existing Deployment in it:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: annotate-existing-deployments
   spec:
     mutateExistingOnPolicyUpdate: false
     rules:
     - name: add-tier-annotation
       match:
         any:
         - resources:
             kinds:
             - Namespace
             selector:
               matchLabels:
                 stage: prod
       mutate:
         targets:
         - apiVersion: apps/v1
           kind: Deployment
           namespace: "{{request.object.metadata.name}}"
         patchStrategicMerge:
           metadata:
             annotations:
               tier: "regulated"
   EOF
   ```

2. Predict the permission gap before triggering it:

   ```bash
   kubectl auth can-i update deployments.apps \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   ```

   Expected (Kyverno's baseline does not grant write on Deployments):

   ```
   no
   ```

3. Grant it with another labelled ClusterRole:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:mutate-deployments
     labels:
       rbac.kyverno.io/aggregate-to-background-controller: "true"
   rules:
   - apiGroups: ["apps"]
     resources: ["deployments"]
     verbs: ["get", "list", "watch", "update", "patch"]
   EOF

   kubectl auth can-i update deployments.apps \
     --as=system:serviceaccount:kyverno:kyverno-background-controller -n default
   # -> yes
   ```

4. Prove the end-to-end behaviour:

   ```bash
   kubectl create namespace prod-ns
   kubectl -n prod-ns create deployment web --image=nginx
   kubectl label namespace prod-ns stage=prod
   sleep 5
   kubectl -n prod-ns get deploy web -o jsonpath='{.metadata.annotations.tier}{"\n"}'
   ```

   Expected:

   ```
   regulated
   ```

**Comprehension check 4**
- a) A plain `mutate` rule (no `targets:`) that adds the same annotation to Deployments *as they are created* needs no RBAC grant. `mutateExisting` needs `update` on Deployments. Explain the difference in terms of *where the object lives* when Kyverno acts on it.
- b) The grant in step 3 includes `get`/`list`/`watch` alongside `update`. Why can't the background controller patch an object it is not allowed to read?

> Source: Kyverno mutate existing resources — https://kyverno.io/docs/writing-policies/mutate/#mutate-existing-resources

---

## Exercise 5 — Expose policies and reports to developers via Kubernetes' built-in aggregation

The other half of Kyverno RBAC is *consumer* access: letting developers **read** policies and their `PolicyReport`s without cluster-admin. Kyverno's CRDs are just API resources, so you grant read access by aggregating into Kubernetes' native `view`/`edit`/`admin` ClusterRoles — the `rbac.authorization.k8s.io/aggregate-to-*` family (note: a *different* label family from Exercise 2).

1. Confirm a namespace-scoped viewer currently **cannot** read policy reports. Simulate a user bound to the built-in `view` role in `team-b`:

   ```bash
   kubectl auth can-i list policyreports.wgpolicyk8s.io \
     --as=dev-alice \
     --as-group=system:authenticated \
     -n team-b
   ```

   Depending on your cluster's defaults this is `no` (the built-in `view` role predates your Kyverno CRDs and doesn't include them).

2. Create a ClusterRole that aggregates into the native `view` role, granting read on Kyverno policies and reports:

   ```bash
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: kyverno:policies-and-reports:view
     labels:
       rbac.authorization.k8s.io/aggregate-to-view: "true"
   rules:
   - apiGroups: ["kyverno.io"]
     resources: ["policies", "clusterpolicies"]
     verbs: ["get", "list", "watch"]
   - apiGroups: ["wgpolicyk8s.io"]
     resources: ["policyreports", "clusterpolicyreports"]
     verbs: ["get", "list", "watch"]
   EOF
   ```

3. Bind `dev-alice` to the built-in `view` ClusterRole in `team-b` (a normal RoleBinding — you are *not* naming your new ClusterRole, you rely on aggregation to have folded it into `view`):

   ```bash
   kubectl -n team-b create rolebinding alice-view \
     --clusterrole=view --user=dev-alice
   ```

4. Re-check — the viewer can now read reports but still cannot write policies:

   ```bash
   kubectl auth can-i list policyreports.wgpolicyk8s.io --as=dev-alice -n team-b
   # -> yes
   kubectl auth can-i delete clusterpolicies.kyverno.io --as=dev-alice
   # -> no
   ```

**Comprehension check 5**
- a) You never referenced `kyverno:policies-and-reports:view` in the RoleBinding — you bound `view`. How did Alice get the Kyverno permissions?
- b) Contrast the two label families you have used: `rbac.kyverno.io/aggregate-to-background-controller` vs. `rbac.authorization.k8s.io/aggregate-to-view`. Which one grants *Kyverno's own identity* the power to act, and which one grants *humans* the power to observe?
- c) A developer needs to *create* their own namespaced `Policy` objects, not just read them. Which built-in role would you aggregate into instead, and which verbs would you add?

> Source: Kyverno RBAC for policy/report access — https://kyverno.io/docs/installation/customization/ · Kubernetes RBAC aggregation — https://kubernetes.io/docs/reference/access-authn-authz/rbac/#aggregated-clusterroles

---

## Exercise 6 — Audit least privilege and clean up

The exam-grade habit is: never assume a grant, always prove it — for the identity, the verb, the resource, and the namespace.

1. Produce a compact audit of what the background controller can do on the two kinds you granted:

   ```bash
   SA=system:serviceaccount:kyverno:kyverno-background-controller
   for verb in get create update delete; do
     for res in networkpolicies.networking.k8s.io deployments.apps; do
       printf "%-8s %-32s -> " "$verb" "$res"
       kubectl auth can-i "$verb" "$res" --as="$SA" -n default
     done
   done
   ```

   Expected:

   ```
   get      networkpolicies.networking.k8s.io -> yes
   get      deployments.apps                  -> yes
   create   networkpolicies.networking.k8s.io -> yes
   create   deployments.apps                  -> no
   update   networkpolicies.networking.k8s.io -> yes
   update   deployments.apps                  -> yes
   delete   networkpolicies.networking.k8s.io -> yes
   delete   deployments.apps                  -> no
   ```

2. Confirm the boundary — the background controller was **not** granted anything you didn't ask for (e.g. it cannot touch Secrets):

   ```bash
   kubectl auth can-i get secrets --as="$SA" -n default
   # -> no
   ```

3. Tear down the lab (leave Kyverno installed):

   ```bash
   kubectl delete clusterpolicy add-default-networkpolicy annotate-existing-deployments
   kubectl delete clusterrole kyverno:generate-networkpolicies kyverno:mutate-deployments kyverno:policies-and-reports:view
   kubectl delete namespace team-a team-b prod-ns
   ```

**Comprehension check 6**
- a) In the step-1 output, `create deployments.apps -> no` but `update -> yes`. Is that a misconfiguration, or exactly what Exercise 4 required? Justify against least privilege.
- b) You delete `kyverno:generate-networkpolicies` while `add-default-networkpolicy` is still active. What happens on the *next* namespace creation, and where does the failure show up?
- c) Write the one command that answers "can the **reports** controller list Pods cluster-wide?" — correct ServiceAccount, correct scope.

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- a) The **`kyverno-background-controller`** ServiceAccount. `generate` (and `mutateExisting`) are executed by the background controller, which reaches into the cluster to create/modify other objects. The admission controller only serves the webhook and acts on the object already inside the AdmissionReview request, so it never needs create/update permissions on *other* resources. Inspecting the admission controller's RBAC would be a dead end.
- b) Least privilege / blast-radius isolation. Each controller carries only the permissions its job needs: the admission controller can read context resources but can't create arbitrary objects; only the background controller gets create/update on generated kinds; only the reports controller gets broad read for scanning. A single monolithic ServiceAccount would need the union of all four, so a compromise of any one process would expose the full set. The split also lets you grant/revoke a capability (e.g. "may create NetworkPolicies") to exactly the identity that uses it.

**Exercise 2**
- a) A Helm/chart upgrade (or Kyverno's own reconciliation of its managed ClusterRoles) reset `kyverno:background-controller:core` to its shipped contents, dropping your edit. Kyverno-managed roles are not a safe place for custom rules — that's why aggregation exists.
- b) Key `rbac.kyverno.io/aggregate-to-background-controller`, value `"true"` (a string). Any ClusterRole with that label has its `rules` folded into `kyverno:background-controller`.
- c) Native Kubernetes — the **controller-manager's ClusterRole aggregation controller** watches for ClusterRoles matching an `aggregationRule`'s `clusterRoleSelectors` and populates the aggregate's `rules`. Kyverno only *defines* the shell with its `aggregationRule`; it does not do the merging.

**Exercise 3**
- a) A `generate` rule's permission requirement is not checked at policy admission — the `ClusterPolicy` is a valid object, so `kubectl apply` succeeds. The permission is exercised **at runtime**, when the background controller tries to create the target resource. So generate-permission failures surface as UpdateRequest failures / controller-log `forbidden` errors / a missing generated resource — never as a rejected `kubectl apply` of the policy. (This is why the `can-i` diagnostic in step 2 is the fast path.)
- b) With `synchronize: true`, Kyverno keeps the generated resource in lockstep with the policy: if someone edits or deletes the generated `default-deny`, Kyverno must **update** it back or **recreate** it, and if the rule/trigger stops matching it must **delete** the orphan. `create` alone would let a user permanently tamper with or remove the generated object.
- c) Cluster-wide form drops `-n default` and adds `--all-namespaces` (or just omit the namespace and query a cluster-scoped check):
  `kubectl auth can-i create networkpolicies.networking.k8s.io --as=system:serviceaccount:kyverno:kyverno-background-controller --all-namespaces`.
  Namespace matters for `NetworkPolicy` because it is a **namespaced** resource — a permission can be granted per-namespace (via RoleBinding) or cluster-wide (ClusterRoleBinding). `ClusterRole` is **cluster-scoped**, so there is no namespace dimension to authorize against.

**Exercise 4**
- a) In a plain `mutate` rule the target object is **inside the incoming AdmissionReview request** — it hasn't been persisted yet, and Kyverno mutates the request payload the API server is about to store. No API call against an existing object, so no RBAC. In `mutateExisting` the target **already lives in etcd**; the background controller issues a real `PATCH`/`UPDATE` against the API server for that object, which the API server authorizes — hence `update` (and `patch`) permission is required.
- b) To patch an object Kyverno must first read its current state (to build/verify the patch and to watch for drift). Kubernetes authorizes read and write verbs independently; `update` without `get`/`list`/`watch` leaves the controller unable to fetch or reconcile the target, so it can't compute or apply the mutation reliably.

**Exercise 5**
- a) Aggregation. Your ClusterRole carried `rbac.authorization.k8s.io/aggregate-to-view: "true"`, so the controller-manager merged its rules into the built-in `view` ClusterRole. Binding Alice to `view` therefore transitively includes the Kyverno read rules — no direct reference to your ClusterRole is needed.
- b) `rbac.kyverno.io/aggregate-to-background-controller` grants **Kyverno's own ServiceAccount identity** the power to act on cluster resources (create NetworkPolicies, patch Deployments). `rbac.authorization.k8s.io/aggregate-to-view` grants **human/API users** bound to the native `view` role the power to observe Kyverno's CRDs. One is about the controller's authority; the other is about consumer visibility.
- c) Aggregate into the built-in **`edit`** (namespaced) role — `rbac.authorization.k8s.io/aggregate-to-edit: "true"` — and add `create`, `update`, `patch`, `delete` on `policies` in the `kyverno.io` group (keep `clusterpolicies` out of `edit`, since ClusterPolicies are cluster-scoped and shouldn't be writable from a namespaced editor).

**Exercise 6**
- a) Exactly what Exercise 4 required, and it *is* least privilege. `mutateExisting` on Deployments needs only to modify existing objects (`update`/`patch`), never to create or delete them, so granting `create`/`delete` on Deployments would be excess authority. `create`/`delete` on NetworkPolicies is correct because the `generate`+`synchronize` rule genuinely creates and removes them.
- b) On the next namespace creation the background controller again lacks `create networkpolicies`, so generation fails at runtime: no `default-deny` appears, the UpdateRequest goes to a failed/pending state, and the `kyverno-background-controller` log shows the `forbidden` line. The `ClusterPolicy` itself stays happily `Ready`/admitted — the failure only shows up in generation, not in policy validation.
- c) `kubectl auth can-i list pods --as=system:serviceaccount:kyverno:kyverno-reports-controller --all-namespaces` (or `-A`). Correct identity is the **reports** ServiceAccount; `--all-namespaces` makes it a cluster-wide check, matching how the reports controller scans every namespace.

</details>