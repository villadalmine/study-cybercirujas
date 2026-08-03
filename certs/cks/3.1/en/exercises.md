# CKS 3.1 — Use Role Based Access Controls to Minimize Exposure

**Guided Lab Exercises**

> **Prerequisites.** A cluster where you hold `cluster-admin` (kind, minikube, or a disposable kubeadm cluster running k8s ≥ 1.30). All impersonation checks below use `--as` / `--as-group`, which require that your own identity is allowed to impersonate. On a fresh admin `kubeconfig` this is already the case. Verify before starting:
>
> ```console
> $ kubectl auth can-i '*' '*'
> yes
> $ kubectl version -o json | grep -m1 gitVersion
>   "gitVersion": "v1.34.0",
> ```
>
> RBAC is enabled when the API server runs with `--authorization-mode=...,RBAC`. Confirm on a kubeadm node:
>
> ```console
> $ grep authorization-mode /etc/kubernetes/manifests/kube-apiserver.yaml
>     - --authorization-mode=Node,RBAC
> ```

---

## Exercise 1 — Map the RBAC API surface and the built-in roles

The four RBAC objects and the identities they bind are the vocabulary for everything that follows: `Role`/`ClusterRole` (permission sets) and `RoleBinding`/`ClusterRoleBinding` (grants to subjects).

1. List the RBAC API resources and note which are namespaced:

   ```console
   $ kubectl api-resources --api-group=rbac.authorization.k8s.io
   NAME                  SHORTNAMES   APIVERSION                        NAMESPACED   KIND
   clusterrolebindings                rbac.authorization.k8s.io/v1      false        ClusterRoleBinding
   clusterroles                       rbac.authorization.k8s.io/v1      false        ClusterRole
   rolebindings                       rbac.authorization.k8s.io/v1      true         RoleBinding
   roles                              rbac.authorization.k8s.io/v1      true         Role
   ```

2. Inspect the four default user-facing ClusterRoles that ship with every cluster:

   ```console
   $ kubectl get clusterrole cluster-admin admin edit view
   NAME            CREATED AT
   cluster-admin   2026-07-30T09:12:04Z
   admin           2026-07-30T09:12:04Z
   edit            2026-07-30T09:12:04Z
   view            2026-07-30T09:12:04Z
   ```

3. Look at the shape of the most dangerous one and at a scoped one:

   ```console
   $ kubectl get clusterrole cluster-admin -o yaml | sed -n '1,20p'
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     annotations:
       rbac.authorization.kubernetes.io/autoupdate: "true"
     labels:
       kubernetes.io/bootstrapping: rbac-defaults
     name: cluster-admin
   rules:
   - apiGroups:
     - '*'
     resources:
     - '*'
     verbs:
     - '*'
   - nonResourceURLs:
     - '*'
     verbs:
     - '*'
   ```

   ```console
   $ kubectl get clusterrole view -o yaml | grep -A4 'apiGroups' | head -8
     - apiGroups:
       - ""
       resources:
       - configmaps
       - endpoints
   ```

**Comprehension checkpoint**

- **Q1.** A `RoleBinding` lives in namespace `dev`. It references a `ClusterRole` (not a `Role`). In which namespace(s) do the granted permissions apply, and why does referencing a ClusterRole from a RoleBinding *not* grant cluster-wide access?
- **Q2.** Which of the four default roles (`cluster-admin`, `admin`, `edit`, `view`) grants read/write to most namespaced resources but is safe to bind *per namespace* rather than cluster-wide, and which single role should almost never appear in a `ClusterRoleBinding` in production?
- **Q3.** In the `cluster-admin` rules you see both a resource rule (`apiGroups/resources/verbs`) and a `nonResourceURLs` rule. What kind of request does `nonResourceURLs` authorize that the resource rule cannot?

---

## Exercise 2 — Grant a ServiceAccount least-privilege, namespaced access

The goal: a workload in `dev` that can only **read** pods in its own namespace — nothing else, nowhere else.

1. Create the namespace and a dedicated ServiceAccount (never reuse `default`):

   ```console
   $ kubectl create namespace dev
   namespace/dev created
   $ kubectl create serviceaccount app-reader -n dev
   serviceaccount/app-reader created
   ```

2. Write a tightly scoped `Role`. Apply it:

   ```yaml
   # role-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: dev
   rules:
   - apiGroups: [""]          # "" is the core API group
     resources: ["pods"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f role-pod-reader.yaml
   role.rbac.authorization.k8s.io/pod-reader created
   ```

3. Bind the Role to the ServiceAccount with a `RoleBinding` in the same namespace:

   ```yaml
   # rb-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: app-reader-can-read-pods
     namespace: dev
   subjects:
   - kind: ServiceAccount
     name: app-reader
     namespace: dev
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```console
   $ kubectl apply -f rb-pod-reader.yaml
   rolebinding.rbac.authorization.k8s.io/app-reader-can-read-pods created
   ```

4. Verify with impersonation *before* deploying any workload. The SA username format is `system:serviceaccount:<namespace>:<name>`:

   ```console
   $ kubectl auth can-i list pods --as=system:serviceaccount:dev:app-reader -n dev
   yes
   $ kubectl auth can-i delete pods --as=system:serviceaccount:dev:app-reader -n dev
   no
   $ kubectl auth can-i list pods --as=system:serviceaccount:dev:app-reader -n kube-system
   no
   $ kubectl auth can-i list secrets --as=system:serviceaccount:dev:app-reader -n dev
   no
   ```

5. Enumerate the *complete* effective permission set of the SA:

   ```console
   $ kubectl auth can-i --list --as=system:serviceaccount:dev:app-reader -n dev
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
   ```

**Comprehension checkpoint**

- **Q4.** In step 4, `-n kube-system` returned `no` even though the same `pod-reader` permissions "exist". What structural property of `RoleBinding` produced that result?
- **Q5.** The `--list` output in step 5 shows `selfsubjectaccessreviews` and `selfsubjectrulesreviews` with verb `create`, even though you never granted them. Where do those come from, and are they a privilege you need to worry about?
- **Q6.** Why is impersonation testing (`--as=system:serviceaccount:...`) preferable to actually launching a pod with the SA and running `kubectl` from inside it, when you are validating a least-privilege grant during a CKS-style task?

---

## Exercise 3 — Tighten verbs and pin to named resources with `resourceNames`

Least privilege is not just *which resource* but *which named object* and *which verb*. Here a CI ServiceAccount must update **one specific** ConfigMap and nothing else.

1. Create the target objects:

   ```console
   $ kubectl create serviceaccount ci-bot -n dev
   serviceaccount/ci-bot created
   $ kubectl create configmap app-config -n dev --from-literal=env=prod
   configmap/app-config created
   $ kubectl create configmap other-config -n dev --from-literal=x=y
   configmap/other-config created
   ```

2. Author a Role that pins to a single object via `resourceNames`:

   ```yaml
   # role-cm-patch.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: app-config-writer
     namespace: dev
   rules:
   - apiGroups: [""]
     resources: ["configmaps"]
     resourceNames: ["app-config"]     # only this named object
     verbs: ["get", "update", "patch"]
   ```

   ```console
   $ kubectl apply -f role-cm-patch.yaml
   role.rbac.authorization.k8s.io/app-config-writer created
   $ kubectl create rolebinding ci-bot-writes-config -n dev \
       --role=app-config-writer --serviceaccount=dev:ci-bot
   rolebinding.rbac.authorization.k8s.io/ci-bot-writes-config created
   ```

3. Test the boundary. Note the asymmetry between `list` and `get`:

   ```console
   $ kubectl auth can-i update configmap/app-config   --as=system:serviceaccount:dev:ci-bot -n dev
   yes
   $ kubectl auth can-i update configmap/other-config --as=system:serviceaccount:dev:ci-bot -n dev
   no
   $ kubectl auth can-i list configmaps                --as=system:serviceaccount:dev:ci-bot -n dev
   no
   ```

4. Prove that a real request behaves the same way:

   ```console
   $ kubectl patch configmap app-config -n dev --as=system:serviceaccount:dev:ci-bot \
       -p '{"data":{"env":"staging"}}'
   configmap/app-config patched

   $ kubectl get configmaps -n dev --as=system:serviceaccount:dev:ci-bot
   Error from server (Forbidden): configmaps is forbidden: User
   "system:serviceaccount:dev:ci-bot" cannot list resource "configmaps" in API group ""
   in the namespace "dev"
   ```

**Comprehension checkpoint**

- **Q7.** You granted `get` on `resourceNames: ["app-config"]` but `kubectl auth can-i list configmaps` returns `no`, and even `get` works only when the exact name is supplied. Which verbs are compatible with `resourceNames`, and which verbs can it **never** restrict? Explain the underlying reason.
- **Q8.** A teammate adds `verbs: ["create"]` to this same rule expecting `ci-bot` to be able to create *only* a ConfigMap named `app-config`. What actually happens, and why?
- **Q9.** After this Role is in place, `ci-bot` can `update` `app-config` but cannot `get` the list of ConfigMaps to discover its name. From an attacker-containment standpoint, why is "can write a known object but cannot enumerate objects" a meaningful reduction in exposure?

---

## Exercise 4 — ClusterRole reuse: one definition, per-namespace grants

A single `ClusterRole` can be reused: bound cluster-wide with a `ClusterRoleBinding`, or scoped to a namespace with a `RoleBinding`. This is the idiomatic way to grant the same permission set in many namespaces without duplicating rules.

1. Define a reusable ClusterRole for reading Deployments (apps group):

   ```yaml
   # cr-deploy-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: deployment-reader
   rules:
   - apiGroups: ["apps"]
     resources: ["deployments"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f cr-deploy-reader.yaml
   clusterrole.rbac.authorization.k8s.io/deployment-reader created
   ```

2. Grant it **only in `dev`** by referencing the ClusterRole from a namespaced RoleBinding:

   ```console
   $ kubectl create serviceaccount deploy-viewer -n dev
   serviceaccount/deploy-viewer created
   $ kubectl create rolebinding deploy-viewer-dev -n dev \
       --clusterrole=deployment-reader --serviceaccount=dev:deploy-viewer
   rolebinding.rbac.authorization.k8s.io/deploy-viewer-dev created
   ```

3. Confirm the grant is namespace-limited despite the role being cluster-scoped:

   ```console
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n dev
   yes
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n default
   no
   ```

4. Now contrast with a `ClusterRoleBinding`, which *does* grant cluster-wide. Create it, observe the difference, then delete it (this is exactly the kind of over-grant a CKS task asks you to avoid):

   ```console
   $ kubectl create clusterrolebinding deploy-viewer-global \
       --clusterrole=deployment-reader --serviceaccount=dev:deploy-viewer
   clusterrolebinding.rbac.authorization.k8s.io/deploy-viewer-global created

   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n default
   yes
   $ kubectl auth can-i list deployments --as=system:serviceaccount:dev:deploy-viewer -n kube-system
   yes

   $ kubectl delete clusterrolebinding deploy-viewer-global
   clusterrolebinding.rbac.authorization.k8s.io "deploy-viewer-global" deleted
   ```

**Comprehension checkpoint**

- **Q10.** Fill the 2×2: {`Role`, `ClusterRole`} × {`RoleBinding`, `ClusterRoleBinding`}. Which combinations are *valid*, and for each valid one, what is the effective scope of the resulting grant?
- **Q11.** A `RoleBinding` in `dev` references a `ClusterRole` that includes a rule on a **cluster-scoped** resource (e.g. `nodes` or `persistentvolumes`). Does the subject gain access to those cluster-scoped resources through this RoleBinding? Why or why not?
- **Q12.** You need the same "read deployments" permission in 30 namespaces. Compare (a) one ClusterRole + 30 RoleBindings vs (b) one ClusterRole + one ClusterRoleBinding, in terms of blast radius and the principle of least privilege.

---

## Exercise 5 — Aggregated ClusterRoles: extend without editing built-ins

You must add "read `secrets`" to everyone who already has the `view` role, without editing the (auto-updated, bootstrap-managed) `view` ClusterRole. Aggregation is the supported mechanism.

1. Inspect how `view` is assembled — it is an *aggregated* role:

   ```console
   $ kubectl get clusterrole view -o yaml | grep -A4 aggregationRule
   aggregationRule:
     clusterRoleSelectors:
     - matchLabels:
         rbac.authorization.k8s.io/aggregate-to-view: "true"
   ```

2. Create a small ClusterRole that carries the matching aggregation label. The control plane will merge its rules into `view` automatically:

   ```yaml
   # cr-aggregate-secrets-view.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: view-secrets-extension
     labels:
       rbac.authorization.k8s.io/aggregate-to-view: "true"
   rules:
   - apiGroups: [""]
     resources: ["secrets"]
     verbs: ["get", "list", "watch"]
   ```

   ```console
   $ kubectl apply -f cr-aggregate-secrets-view.yaml
   clusterrole.rbac.authorization.k8s.io/view-secrets-extension created
   ```

3. Observe that the aggregated `view` role now *contains* the secrets rule, though you never edited it directly:

   ```console
   $ kubectl get clusterrole view -o yaml | grep -B1 -A3 secrets
     - apiGroups:
       - ""
       resources:
       - secrets
       verbs:
       - get
   ```

4. Confirm the effect on a subject that has `view`, then **clean up** — granting `secrets` read to everyone with `view` is itself an exposure and this step is a demonstration, not a recommendation:

   ```console
   $ kubectl create serviceaccount auditor -n dev
   $ kubectl create rolebinding auditor-view -n dev --clusterrole=view --serviceaccount=dev:auditor
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:auditor -n dev
   yes
   $ kubectl delete clusterrole view-secrets-extension
   clusterrole.rbac.authorization.k8s.io "view-secrets-extension" deleted
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:auditor -n dev
   no
   ```

**Comprehension checkpoint**

- **Q13.** Why is aggregation the correct pattern for extending `view`/`edit`/`admin`, instead of `kubectl edit clusterrole view` and appending a rule?
- **Q14.** In step 4 the `view` role gained `secrets` read for *every* subject already bound to `view`. From a "minimize exposure" perspective, what makes aggregating `secrets` into `view` a dangerous change, and what would a safer design look like?
- **Q15.** After you deleted `view-secrets-extension`, the permission disappeared *without* touching any RoleBinding. What component recomputed the aggregated `rules`, and on what event?

---

## Exercise 6 — Find and neutralize privilege-escalation permissions

The verbs `escalate`, `bind`, `impersonate`, and wildcards on `roles`/`clusterroles`/`*` are the RBAC constructs that let a low-privileged subject become high-privileged. This exercise is the core "minimize exposure" audit.

1. Create a deliberately over-permissive Role and bind it, simulating a bad grant you might be asked to find and fix:

   ```yaml
   # role-dangerous.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: rbac-manager
     namespace: dev
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["*"]                       # includes create + bind + escalate
   ```

   ```console
   $ kubectl apply -f role-dangerous.yaml
   role.rbac.authorization.k8s.io/rbac-manager created
   $ kubectl create serviceaccount tenant -n dev
   $ kubectl create rolebinding tenant-rbac -n dev --role=rbac-manager --serviceaccount=dev:tenant
   rolebinding.rbac.authorization.k8s.io/tenant-rbac created
   ```

2. Show the escalation. `tenant` can manage Roles in `dev`, so it can mint itself a Role granting `secrets` — *unless* the escalation guard blocks it. Test whether it can escalate to permissions it does not itself hold:

   ```console
   $ kubectl auth can-i create roles --as=system:serviceaccount:dev:tenant -n dev
   yes
   $ kubectl auth can-i get secrets --as=system:serviceaccount:dev:tenant -n dev
   no
   ```

   The apiserver's escalation prevention normally stops `tenant` from creating a Role with `secrets` it lacks — **but** because the wildcard `verbs: ["*"]` grants the `escalate` and `bind` verbs on `roles`/`rolebindings`, that guard is bypassed. That is precisely why `*` on RBAC resources is a critical finding.

3. Audit the whole cluster for the highest-risk grants. These are the greps a reviewer runs:

   ```console
   # Who is bound to cluster-admin?
   $ kubectl get clusterrolebindings -o json | \
       jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
              .metadata.name + " -> " +
              ([.subjects[]?|.kind+"/"+.name]|join(","))'
   cluster-admin -> Group/system:masters

   # Every (cluster)role that uses a wildcard verb, resource, or apiGroup
   $ kubectl get clusterroles,roles -A -o json | jq -r '
       .items[] | . as $r | .rules[]? |
       select((.verbs//[]|index("*")) or (.resources//[]|index("*")) or (.apiGroups//[]|index("*"))) |
       ($r.kind+"/"+$r.metadata.name)' | sort -u | head
   ClusterRole/cluster-admin
   Role/rbac-manager

   # Anyone granted the escalate / bind / impersonate verbs
   $ kubectl get clusterroles,roles -A -o json | jq -r '
       .items[] | . as $r | .rules[]? |
       select(.verbs[]? | test("^(escalate|bind|impersonate)$")) |
       ($r.kind+"/"+$r.metadata.name+" verbs="+(.verbs|join(",")))'
   Role/rbac-manager verbs=*
   ```

4. Remediate: replace the wildcard with an explicit, minimal verb set and drop `bind`/`escalate`:

   ```yaml
   # role-rbac-manager-fixed.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: rbac-manager
     namespace: dev
   rules:
   - apiGroups: ["rbac.authorization.k8s.io"]
     resources: ["roles", "rolebindings"]
     verbs: ["get", "list", "watch"]     # read-only; no create/bind/escalate
   ```

   ```console
   $ kubectl apply -f role-rbac-manager-fixed.yaml
   role.rbac.authorization.k8s.io/rbac-manager configured
   $ kubectl auth can-i create roles --as=system:serviceaccount:dev:tenant -n dev
   no
   ```

**Comprehension checkpoint**

- **Q16.** Explain the apiserver's built-in **escalation prevention** for `create`/`update` of Roles. Under what two specific conditions is a subject allowed to create a Role containing permissions it does *not* itself hold?
- **Q17.** What does the `impersonate` verb allow, and why is `impersonate` on `users`/`groups`/`serviceaccounts` effectively equivalent to holding the union of everyone's permissions?
- **Q18.** The audit found `cluster-admin -> Group/system:masters`. Should you remediate that binding? What is special about `system:masters`, and how does a client end up in that group?
- **Q19.** Why is `verbs: ["*"]` on `roles`/`rolebindings` a more severe finding than `verbs: ["*"]` on `configmaps`, even though both are wildcards in a single namespace?

---

## Exercise 7 — Stop handing out API tokens no workload needs

A pod that mounts a ServiceAccount token gives any code (or attacker) in that container a credential to the API server. Minimizing exposure means *not mounting the token* unless the workload actually calls the API.

1. Observe the default behavior — the `default` SA token is auto-mounted into every pod:

   ```console
   $ kubectl run probe --image=busybox -n dev --restart=Never -- sleep 3600
   pod/probe created
   $ kubectl exec probe -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount
   ca.crt
   namespace
   token
   ```

2. Disable auto-mount at the **ServiceAccount** level (applies to all pods using it that don't override):

   ```yaml
   # sa-no-automount.yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: no-token
     namespace: dev
   automountServiceAccountToken: false
   ```

   ```console
   $ kubectl apply -f sa-no-automount.yaml
   serviceaccount/no-token created
   ```

3. Or disable it at the **pod** level (pod setting overrides the SA setting), which is the more explicit, least-surprise option:

   ```yaml
   # pod-no-token.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: notoken
     namespace: dev
   spec:
     serviceAccountName: no-token
     automountServiceAccountToken: false
     containers:
     - name: app
       image: busybox
       command: ["sleep", "3600"]
   ```

   ```console
   $ kubectl apply -f pod-no-token.yaml
   pod/notoken created
   $ kubectl exec notoken -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount
   ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory
   command terminated with exit code 1
   ```

4. Clean up:

   ```console
   $ kubectl delete pod probe notoken -n dev
   pod "probe" deleted
   pod "notoken" deleted
   ```

**Comprehension checkpoint**

- **Q20.** A pod sets `automountServiceAccountToken: true` while its ServiceAccount sets `automountServiceAccountToken: false`. Is the token mounted? State the precedence rule.
- **Q21.** You removed the token from a pod that never talks to the API server. Concretely, which post-exploitation step does this break for an attacker who achieves code execution in that container?
- **Q22.** Even with the token *not* mounted, why does binding minimal RBAC to the `default` ServiceAccount of every namespace still matter as defense-in-depth?

---

<details>
<summary><strong>Answers</strong></summary>

**A1.** The permissions apply **only in `dev`** — the namespace of the RoleBinding. A `RoleBinding` always confines a grant to its own namespace, regardless of whether `roleRef` points at a `Role` or a `ClusterRole`. Referencing a ClusterRole from a RoleBinding is purely a *definition-reuse* mechanism (write the rule set once, grant it in many namespaces); it does not change where the RoleBinding grants access. Only a `ClusterRoleBinding` grants a ClusterRole cluster-wide.

**A2.** `admin` and `edit` are designed to be bound **per namespace** via a RoleBinding (`admin` = full read/write within a namespace *including* managing Roles/RoleBindings there; `edit` = read/write workloads but not RBAC). `view` is read-only. The role that should essentially never appear in a `ClusterRoleBinding` in production is **`cluster-admin`** — a ClusterRoleBinding to it grants unrestricted control over the entire cluster (it is what `system:masters` effectively has).

**A3.** `nonResourceURLs` authorizes requests to API-server endpoints that are **not** Kubernetes REST resources and have no namespace or object identity — e.g. `/healthz`, `/livez`, `/readyz`, `/version`, `/metrics`, `/api`, `/openapi/v2`. Resource rules (`apiGroups`/`resources`/`verbs`) only match `/api/...` and `/apis/<group>/...` resource paths, so a separate `nonResourceURLs` rule is required to authorize those flat URL paths (only meaningful in ClusterRoles, since these URLs are not namespaced).

**A4.** A `RoleBinding` grants permissions **only within its own namespace**. The binding was created in `dev`, so the SA is authorized for pods in `dev` and nowhere else. `kube-system` has no RoleBinding granting `pod-reader` to `app-reader`, so the request is denied. To read pods in another namespace you would need a separate RoleBinding there (or a ClusterRoleBinding for all namespaces).

**A5.** They are `SelfSubjectAccessReview` and `SelfSubjectRulesReview`, granted to the built-in `system:authenticated`/`system:basic-user` groups that every authenticated identity belongs to. They only let a subject ask "what am I allowed to do?" about **itself** (`kubectl auth can-i`) — they grant no access to any real resource and cannot be used to escalate, so they are not a concern.

**A6.** Impersonation checks (`kubectl auth can-i --as=...` and `--list`) query the apiserver's authorizer directly and report the *exact* decision without side effects, without needing a running pod, a mounted token, a scheduled node, or any image pull. Launching a real pod to test is slower, mutates cluster state, can fail for unrelated reasons (scheduling, image, CrashLoopBackOff), and in an exam wastes time. `--as`/`--as-group` is the canonical, deterministic RBAC verification method.

**A7.** `resourceNames` works with verbs that address an **individual, already-named object**: `get`, `update`, `patch`, `delete` (and `watch` on a specific name). It can **never** restrict `list`, `watch` (collection), `create`, or `deletecollection`, because those operate on a whole collection or, in the case of `create`, on an object whose name does not yet exist at authorization time — there is no name to match against. That is why `list configmaps` returned `no` (no unrestricted `list` rule) and `get` only worked with the exact name.

**A8.** Adding `create` alongside `resourceNames: ["app-config"]` does **not** let `ci-bot` create a ConfigMap named `app-config`. At `create` time the object has no name yet, so `resourceNames` cannot match — the effect is that the `create` verb in that rule is unusable/ineffective, and `ci-bot` still cannot create any ConfigMap. To allow creating ConfigMaps you must grant `create` in a rule **without** `resourceNames` (which necessarily allows creating them under *any* name).

**A9.** Blocking enumeration (`list`) removes the attacker's ability to discover what exists — object names, how many, their metadata. An attacker who compromises `ci-bot` can only act on names they already know; they cannot sweep the namespace to find secrets, other configs, or targets. Combined with narrow verbs on one named object, this collapses the blast radius from "everything in the namespace" to "one known object, write-only" — a large, concrete reduction in exposure.

**A10.** 
| roleRef → binding ↓ | `Role` | `ClusterRole` |
|---|---|---|
| `RoleBinding` | Valid — grant scoped to the binding's namespace | Valid — grant scoped to the binding's namespace (ClusterRole reused as a template) |
| `ClusterRoleBinding` | **Invalid** — a ClusterRoleBinding cannot reference a namespaced Role | Valid — grant applies cluster-wide, all namespaces + cluster-scoped resources |

**A11.** **No.** A `RoleBinding` can only ever grant access to resources *in its own namespace*, and cluster-scoped resources (`nodes`, `persistentvolumes`, `namespaces`, etc.) do not live in any namespace. So even though the ClusterRole's rule mentions `nodes`, binding it via a namespaced RoleBinding grants nothing for `nodes`. Cluster-scoped resources are only reachable through a `ClusterRoleBinding`.

**A12.** (a) One ClusterRole + 30 RoleBindings limits the subject to exactly those 30 namespaces; a 31st namespace created later is *not* automatically exposed, and you can revoke one namespace by deleting one RoleBinding — minimal blast radius, more objects to manage. (b) One ClusterRoleBinding grants the permission in **all** namespaces including `kube-system` and every future namespace — far larger blast radius. Least privilege favors (a) unless the permission genuinely must be universal.

**A13.** The built-in `view`/`edit`/`admin` roles carry `rbac.authorization.kubernetes.io/autoupdate: "true"` and are reconciled by the controller on startup, so a manual `kubectl edit` is liable to be **overwritten** on the next apiserver restart/upgrade. Aggregation is the supported extension point: you add a small labeled ClusterRole and the control plane merges it in, surviving upgrades without your changes being reverted.

**A14.** `view` is intended to be broadly, even cluster-wide, granted as a "harmless read-only" role. Aggregating `secrets` read into it silently gives **every** `view` subject the ability to read all Secrets they can reach — token material, TLS keys, credentials — turning a "safe" role into a cluster-wide secret-exfiltration grant. A safer design is a **separate, narrowly named ClusterRole** (e.g. `secret-reader`) bound only to the specific identities that genuinely need it, ideally per-namespace via RoleBinding, never aggregated into `view`.

**A15.** The **ClusterRole aggregation controller** in `kube-controller-manager` recomputes the aggregated role's `rules` field. It re-evaluates the `aggregationRule.clusterRoleSelectors` whenever a ClusterRole matching (or previously matching) the selector labels is created, updated, or deleted, and rewrites the parent role's rules accordingly — so deleting the labeled extension removed the merged rule automatically.

**A16.** When a subject creates or updates a Role/ClusterRole, the apiserver requires that the subject **already holds every permission** being granted (checked rule-by-rule against the subject's own effective permissions) — this prevents privilege escalation via role authoring. It is bypassed in exactly two cases: (1) the subject has the `escalate` verb on `roles`/`clusterroles` (allows writing rules beyond its own permissions), or (2) `bind` verb on `roles`/`clusterroles` for creating bindings to a role whose permissions the subject lacks. A wildcard `verbs: ["*"]` on those resources includes `escalate` and `bind`, which is why it defeats the guard.

**A17.** `impersonate` lets a subject send requests **as** another user, group, or ServiceAccount (via `--as`/`--as-group`, or `Impersonate-User`/`Impersonate-Group` headers); the apiserver then authorizes the request using the *impersonated* identity's permissions. Holding `impersonate` on `groups` (especially being able to impersonate `system:masters`) or on arbitrary users/SAs lets the subject assume anyone's identity, so its effective authority is the **union of every identity it can impersonate** — trivially escalating to cluster-admin. It is one of the most dangerous verbs to grant.

**A18.** **No, do not remove it** — the `cluster-admin → system:masters` ClusterRoleBinding (`cluster-admin`) is a bootstrap default and deleting it can lock you out of cluster administration. `system:masters` is a **special group that the RBAC authorizer honors as a super-user**; more importantly the apiserver treats it as always-allowed (kubeadm's admin client cert carries `O=system:masters`). Clients join it by presenting a client certificate with that Organization. The correct hardening is to *avoid issuing new `system:masters` certs* and to keep the admin kubeconfig tightly controlled — not to delete the default binding.

**A19.** Wildcard on `configmaps` in one namespace lets the subject fully control ConfigMaps *there* — bad, but bounded to ConfigMap data in that namespace. Wildcard on `roles`/`rolebindings` grants (through `escalate`/`bind`) the ability to **author and bind arbitrary permissions**, i.e. to grant itself any access — it is a *privilege-escalation primitive* that can be leveraged into full control of the namespace and, via impersonation/secret access, potentially the cluster. Control over RBAC is control over all other authorization, so it is categorically more severe.

**A20.** **Yes, the token is mounted.** The **pod-level** `automountServiceAccountToken` takes precedence over the ServiceAccount-level setting. The SA setting is only the default applied when the pod does not specify one; an explicit pod value always wins. (Best practice: set `false` on the SA as the default *and* rely on pods opting in only when they call the API.)

**A21.** It breaks the attacker's ability to **authenticate to the Kubernetes API from inside the container**. Without the mounted token there is no bearer credential at `/var/run/secrets/kubernetes.io/serviceaccount/token`, so the attacker cannot enumerate or manipulate cluster resources, cannot probe RBAC, and cannot pivot via the SA's permissions — they are confined to the container's own process/network context, forcing them to find a separate credential source.

**A22.** Because a mounted token is not the only way an SA's identity is used, and defenses can be bypassed or misconfigured: a later manifest change may re-enable automount, an operator may `kubectl exec` in, another workload may share the SA, or a projected token could be mounted explicitly. If the `default` SA also has *no* RBAC bindings beyond the baseline, then even a leaked/obtained token yields near-zero authority. Layering "no token" (reduce credential exposure) with "no permissions on `default`" (reduce credential value) is defense-in-depth — either control alone can fail.

</details>

---

### Sources

- Kubernetes — *Using RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Configure Service Accounts for Pods* (token automount, `automountServiceAccountToken`): https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — *Managing Service Accounts*: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubernetes — *Authorization Overview* (verbs, resource vs non-resource requests): https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Kubernetes — *Checking API Access* (`kubectl auth can-i`, SelfSubjectAccessReview): https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access
- Kubernetes — *User Impersonation*: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#user-impersonation
- CNCF — *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf