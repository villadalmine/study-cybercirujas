# Exercises — CNPE 3.2: Applying RBAC and Security Controls Across Platform Resources

These guided labs take you from *inspecting* the authorization surface of a running platform to *building* least-privilege access for tenant teams and platform controllers, and finally to *layering* the non-RBAC controls (admission, quotas, network isolation, policy-as-code) that RBAC alone cannot enforce. As a Platform Engineer you are not just an admin granting access — you are the author of the *guardrails* that let application teams self-serve without escalating into each other or into the control plane.

> **Reference syllabus:** CNPE Curriculum, Domain 3 — *Platform Security* → 3.2 *Applying RBAC and Security Controls Across Platform Resources* — <https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf>

## Environment prerequisites

- A cluster where you hold `cluster-admin` (a local `kind`/`minikube` cluster is ideal, since you will impersonate other identities and create cluster-scoped objects).
- `kubectl` v1.28+ (the labs use `kubectl create token` and `kubectl auth can-i --list`, both stable in modern releases).
- For Exercise 6 you will install **Kyverno** (a CNCF policy engine); the install step is included inline.

Verify your starting identity before you begin — every later `--as` flag depends on your base identity being able to *impersonate*:

```bash
kubectl auth can-i impersonate users
kubectl auth can-i '*' '*' --all-namespaces
```

Expected output:

```
yes
yes
```

If either prints `no`, stop — you are not `cluster-admin` and the impersonation steps below will be denied.

---

## Exercise 1 — Read the authorization surface before you touch it

**Goal:** Learn to *interrogate* RBAC instead of guessing. Every access decision in Kubernetes is `(subject, verb, resource, apiGroup, [resourceName])`. Before granting anything you must be able to enumerate what already exists.

1. Count the built-in roles the API server ships with. The `system:` prefix marks control-plane roles; the un-prefixed `admin`, `edit`, `view` are the user-facing defaults every platform reuses:

   ```bash
   kubectl get clusterroles | wc -l
   kubectl get clusterroles admin edit view cluster-admin
   ```

   Expected (numbers vary by version/add-ons):

   ```
   72
   NAME            CREATED AT
   admin           2026-08-07T10:00:00Z
   edit            2026-08-07T10:00:00Z
   view            2026-08-07T10:00:00Z
   cluster-admin   2026-08-07T10:00:00Z
   ```

2. Inspect the rules of the `view` ClusterRole. Note what it *cannot* see:

   ```bash
   kubectl describe clusterrole view | head -n 30
   ```

   Expected (excerpt):

   ```
   Name:         view
   Labels:       kubernetes.io/bootstrapping=rbac-defaults
                 rbac.authorization.k8s.io/aggregate-to-edit=true
   PolicyRule:
     Resources                    Non-Resource URLs  Resource Names  Verbs
     ---------                    -----------------  --------------  -----
     configmaps                   []                 []              [get list watch]
     pods                         []                 []              [get list watch]
     services                     []                 []              [get list watch]
     ...
   ```

3. Notice that `secrets` is **absent** from `view`. Confirm it, then confirm it *is* present in `edit`:

   ```bash
   kubectl describe clusterrole view | grep -c '^  secrets'
   kubectl describe clusterrole edit | grep -c '^  secrets'
   ```

   Expected:

   ```
   0
   1
   ```

4. Resolve the *effective* permissions of an identity — the answer to "what can this subject actually do?" — with a reverse query. Ask it for the default service account of `kube-system` and for a plain unauthenticated-then-authenticated user:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:default:default -n default
   ```

   Expected (a minimal service account gets only self-review + discovery):

   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                   [/api/*]            []               [get]
                                                   [/healthz]          []               [get]
   ```

**Comprehension check:**

- **Q1.1** Why does `view` deliberately omit `secrets` while `edit` includes it, and what does that tell you about how you should scope read-only dashboards or observability tooling that you give to a tenant team?
- **Q1.2** The default service account came back with almost no permissions, yet pods using it can still reach the API server. What are those `[create]` verbs on `selfsubjectaccessreviews` for, and why is it *not* a privilege-escalation risk that every identity has them?
- **Q1.3** You ran `kubectl auth can-i --list --as=...`. Which component actually renders that answer, and why is asking the API server "can I?" more trustworthy than reading the RoleBindings yourself?

---

## Exercise 2 — Least-privilege for a tenant team (Role vs ClusterRole)

**Goal:** Onboard an application team into their own namespace with exactly the access they need — and no path to the control plane or to a neighbour's namespace.

1. Create the tenant namespace and a service account that the team's CI pipeline will authenticate as:

   ```bash
   kubectl create namespace team-a
   kubectl create serviceaccount deployer -n team-a
   ```

2. Author a namespaced `Role` that lets the team manage their *workloads* but not RBAC, secrets-at-large, or namespaces. Save as `team-a-role.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: workload-manager
     namespace: team-a
   rules:
     - apiGroups: ["apps"]
       resources: ["deployments", "replicasets", "statefulsets"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     - apiGroups: [""]
       resources: ["pods", "pods/log", "services", "configmaps"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     - apiGroups: [""]
       resources: ["events"]
       verbs: ["get", "list", "watch"]
   ```

3. Bind the Role to the service account with a namespaced `RoleBinding`. Save as `team-a-binding.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: deployer-workload-manager
     namespace: team-a
   subjects:
     - kind: ServiceAccount
       name: deployer
       namespace: team-a
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: workload-manager
   ```

   ```bash
   kubectl apply -f team-a-role.yaml -f team-a-binding.yaml
   ```

4. Verify the grant from the *subject's* point of view, inside and outside the namespace:

   ```bash
   kubectl auth can-i create deployments \
     --as=system:serviceaccount:team-a:deployer -n team-a
   kubectl auth can-i create deployments \
     --as=system:serviceaccount:team-a:deployer -n team-b
   kubectl auth can-i get secrets \
     --as=system:serviceaccount:team-a:deployer -n team-a
   ```

   Expected:

   ```
   yes
   no
   no
   ```

5. Now reuse a *ClusterRole* for a namespaced grant. This is the idiom that keeps you from redefining "read-only" 40 times. Give the team's auditors read access — but only inside `team-a` — by binding the built-in `view` ClusterRole through a namespaced RoleBinding:

   ```bash
   kubectl create rolebinding auditors-view \
     --clusterrole=view \
     --group=team-a-auditors \
     -n team-a
   ```

6. Confirm the group-based grant is namespace-scoped even though the *role* is cluster-scoped:

   ```bash
   kubectl auth can-i list pods --as-group=team-a-auditors --as=jane -n team-a
   kubectl auth can-i list pods --as-group=team-a-auditors --as=jane -n team-b
   ```

   Expected:

   ```
   yes
   no
   ```

**Comprehension check:**

- **Q2.1** In step 5 you bound a **ClusterRole** with a **RoleBinding**. Where do the resulting permissions apply, and how does this differ from binding the same ClusterRole with a **ClusterRoleBinding**? Why is the RoleBinding form the workhorse of multi-tenant platforms?
- **Q2.2** The `roleRef` field cannot be changed after a binding is created — an update that alters `roleRef` is rejected. Why did the RBAC authors make `roleRef` immutable, and what operational habit does that force on you when you need to "swap" a subject's role?
- **Q2.3** You granted access to a `group` (`team-a-auditors`), not to named users. Kubernetes has no Group object. So where do group memberships actually come from, and what does that imply about who is responsible for the *authentication* half of "authN + authZ" on your platform?

---

## Exercise 3 — Composable capabilities with ClusterRole aggregation

**Goal:** Platforms grow by *adding* capabilities (a new CRD, a new operator) without editing the roles teams are already bound to. Aggregation lets you extend `admin`/`edit`/`view` — and your own roles — declaratively.

1. Look at how the built-in `edit` role is assembled. It has no static rules of its own; it is *filled in* by a controller from every ClusterRole carrying a matching label:

   ```bash
   kubectl get clusterrole edit -o jsonpath='{.aggregationRule}' | python3 -m json.tool
   ```

   Expected:

   ```json
   {
       "clusterRoleSelectors": [
           {
               "matchLabels": {
                   "rbac.authorization.k8s.io/aggregate-to-edit": "true"
               }
           }
       ]
   }
   ```

2. Create your *own* aggregated platform role — a "platform-operator" umbrella that will absorb any capability you label into it. Save as `platform-operator.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform-operator
   aggregationRule:
     clusterRoleSelectors:
       - matchLabels:
           platform.example.com/aggregate-to-operator: "true"
   rules: []   # intentionally empty; the controller fills this in
   ```

   ```bash
   kubectl apply -f platform-operator.yaml
   kubectl get clusterrole platform-operator -o jsonpath='{.rules}'
   ```

   Expected (empty, because nothing carries the label yet):

   ```
   []
   ```

3. Contribute a capability. Save as `cap-configmaps.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform-cap-configmaps
     labels:
       platform.example.com/aggregate-to-operator: "true"
   rules:
     - apiGroups: [""]
       resources: ["configmaps"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
   ```

   ```bash
   kubectl apply -f cap-configmaps.yaml
   ```

4. Re-read the umbrella role — the controller has merged the new rule *without you editing `platform-operator`*:

   ```bash
   kubectl get clusterrole platform-operator -o jsonpath='{.rules}' | python3 -m json.tool
   ```

   Expected:

   ```json
   [
       {
           "apiGroups": [""],
           "resources": ["configmaps"],
           "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"]
       }
   ]
   ```

5. Prove the "extend without touching consumers" property: add a *second* capability and watch anyone bound to `platform-operator` inherit it immediately.

   ```bash
   kubectl label clusterrole platform-cap-configmaps --overwrite \
     platform.example.com/aggregate-to-operator=true   # already labelled; no-op
   cat <<'EOF' | kubectl apply -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: platform-cap-secrets-ro
     labels:
       platform.example.com/aggregate-to-operator: "true"
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "list", "watch"]
   EOF
   kubectl get clusterrole platform-operator -o jsonpath='{range .rules[*]}{.resources}{"\n"}{end}'
   ```

   Expected:

   ```
   ["configmaps"]
   ["secrets"]
   ```

**Comprehension check:**

- **Q3.1** You never edited `platform-operator` after step 2, yet its `rules` changed twice. What component performs the merge, and what triggers it? Why is trying to `kubectl edit clusterrole platform-operator` to add a rule the *wrong* move?
- **Q3.2** A teammate wants a new operator's CRD verbs to appear automatically for everyone who has the built-in `edit` role. Which single label do they add to their CRD's ClusterRole to make that happen, and what is the risk of aggregating a `delete`-heavy capability into `edit`?
- **Q3.3** Aggregation only ever *adds* rules — it is purely additive union. What does that mean for revoking a capability, and how does it interact with the fact that RBAC has no `deny` rules?

---

## Exercise 4 — Least-privilege for a platform controller / operator

**Goal:** The service accounts your *platform automation* runs as (GitOps controllers, operators, autoscalers) are the highest-value targets on the cluster because they run unattended with broad write access. Scope them to their own CRDs and nothing else.

1. Create the operator's home namespace and identity:

   ```bash
   kubectl create namespace platform-system
   kubectl create serviceaccount widget-operator -n platform-system
   ```

2. Suppose the operator reconciles a CRD `widgets.platform.example.com` and needs to emit events and manage the Deployments it owns — but must **not** read Secrets cluster-wide or touch RBAC. Save as `widget-operator-role.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: widget-operator
   rules:
     - apiGroups: ["platform.example.com"]
       resources: ["widgets", "widgets/status", "widgets/finalizers"]
       verbs: ["get", "list", "watch", "update", "patch"]
     - apiGroups: ["apps"]
       resources: ["deployments"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     - apiGroups: [""]
       resources: ["events"]
       verbs: ["create", "patch"]
   ```

3. Bind it cluster-wide (the operator watches `widgets` in all namespaces). Save as `widget-operator-binding.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: widget-operator
   subjects:
     - kind: ServiceAccount
       name: widget-operator
       namespace: platform-system
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: widget-operator
   ```

   ```bash
   kubectl apply -f widget-operator-role.yaml -f widget-operator-binding.yaml
   ```

4. Audit the resulting blast radius. The operator should be able to drive its Deployments but should be *blind* to Secrets and RBAC:

   ```bash
   SA=system:serviceaccount:platform-system:widget-operator
   kubectl auth can-i update deployments --as=$SA --all-namespaces
   kubectl auth can-i patch widgets.platform.example.com --as=$SA --all-namespaces
   kubectl auth can-i get secrets --as=$SA --all-namespaces
   kubectl auth can-i create clusterrolebindings --as=$SA
   ```

   Expected:

   ```
   yes
   yes
   no
   no
   ```

5. Mint a short-lived, bound token for the operator the way a modern deployment would (no long-lived Secret objects since v1.24):

   ```bash
   kubectl create token widget-operator -n platform-system --duration=1h | head -c 40; echo '...'
   ```

   Expected (a truncated JWT):

   ```
   eyJhbGciOiJSUzI1NiIsImtpZCI6IlItb2p...
   ```

**Comprehension check:**

- **Q4.1** The operator's ClusterRole grants `update` and `patch` on `widgets/status` and `widgets/finalizers` as *separate* resources from `widgets`. Why are status and finalizers modelled as subresources, and what would go wrong operationally if you granted `widgets` but forgot `widgets/status`?
- **Q4.2** You issued the token with `--duration=1h` instead of mounting a legacy `ServiceAccount` token Secret. What changed in Kubernetes v1.24 regarding auto-generated token Secrets, and why are bound, expiring, audience-scoped tokens (projected `TokenRequest` tokens) a security improvement for platform controllers?
- **Q4.3** The operator got a `ClusterRoleBinding`, not a namespaced RoleBinding. Justify that choice for a controller that *watches all namespaces*, then describe the one property of the grant you should scrutinise hardest precisely *because* it is cluster-wide.

---

## Exercise 5 — Privilege-escalation prevention (the `escalate` and `bind` verbs)

**Goal:** Understand the mechanism that stops a delegated namespace admin from writing themselves a role to `cluster-admin`. This is the single most important RBAC safety property to *demonstrate*, not just recite.

1. Set up a delegated admin `alice` in `team-a` who is allowed to manage RBAC *within* her namespace, plus basic read access. Save as `team-a-rbac-admin.yaml`:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: rbac-admin
     namespace: team-a
   rules:
     - apiGroups: ["rbac.authorization.k8s.io"]
       resources: ["roles", "rolebindings"]
       verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: alice-rbac-admin
     namespace: team-a
   subjects:
     - kind: User
       name: alice
       apiGroup: rbac.authorization.k8s.io
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: Role
     name: rbac-admin
   ```

   ```bash
   kubectl apply -f team-a-rbac-admin.yaml
   kubectl auth can-i create roles --as=alice -n team-a
   ```

   Expected:

   ```
   yes
   ```

2. Now have "alice" attempt to grant herself something she does *not* already hold — read access to `secrets`. Try to create the Role **as alice**:

   ```bash
   cat <<'EOF' | kubectl apply --as=alice -n team-a -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: sneaky-secrets
     namespace: team-a
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "list"]
   EOF
   ```

   Expected — **denied**, even though alice can create Roles:

   ```
   Error from server (Forbidden): error when creating "STDIN": roles.rbac.authorization.k8s.io "sneaky-secrets" is forbidden: user "alice" (groups=["system:authenticated"]) is attempting to grant RBAC permissions not currently held:
   {APIGroups:[""], Resources:["secrets"], Verbs:["get" "list"]}
   ```

3. Confirm the same rule blocks *binding* an over-powered role. As alice, try to bind the built-in `admin` ClusterRole (which includes secrets) to herself:

   ```bash
   kubectl create rolebinding alice-escalate \
     --clusterrole=admin --user=alice -n team-a --as=alice
   ```

   Expected — **denied**:

   ```
   Error from server (Forbidden): rolebindings.rbac.authorization.k8s.io "alice-escalate" is forbidden: user "alice" (groups=["system:authenticated"]) is attempting to grant RBAC permissions not currently held: ...
   ```

4. Grant the explicit escape hatch — the `escalate` verb — and watch step 2 now succeed. As `cluster-admin`, extend alice's Role:

   ```bash
   kubectl patch role rbac-admin -n team-a --type=json -p='[
     {"op":"add","path":"/rules/-","value":{"apiGroups":["rbac.authorization.k8s.io"],"resources":["roles"],"verbs":["escalate"]}}
   ]'
   cat <<'EOF' | kubectl apply --as=alice -n team-a -f -
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: now-allowed-secrets
     namespace: team-a
   rules:
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "list"]
   EOF
   ```

   Expected:

   ```
   role.rbac.authorization.k8s.io/now-allowed-secrets created
   ```

**Comprehension check:**

- **Q5.1** In step 2 alice held `create` on `roles` yet was denied. State the exact escalation-prevention rule the API server applied, in terms of "permissions currently held."
- **Q5.2** Steps 2 and 3 failed for *related but distinct* reasons — one is guarded by the `escalate` verb, the other by the `bind` verb. Which is which, and why does RBAC need two separate verbs here instead of one?
- **Q5.3** After step 4, alice can now mint roles granting secrets access. Why is granting `escalate` (or `bind`) on `roles` almost as dangerous as granting the underlying permission directly, and what is the safer platform pattern for letting teams self-manage RBAC without this footgun?

---

## Exercise 6 — Layered controls beyond RBAC (PSA + quotas + NetworkPolicy + policy-as-code)

**Goal:** RBAC controls *who can call the API and with which verbs*. It says nothing about *what a Pod is allowed to be* once created, how much a namespace may consume, or which Pods may talk to which. A production platform stacks four more layers on top. Build them for `team-a`.

### 6a — Pod Security Admission (what a Pod may *be*)

1. Enforce the `restricted` Pod Security Standard on the tenant namespace via labels (PSA is built into the API server; no add-on needed):

   ```bash
   kubectl label namespace team-a --overwrite \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=latest \
     pod-security.kubernetes.io/warn=restricted
   ```

2. Try to run a privileged-ish Pod that violates the standard (runs as root, no `seccompProfile`, no dropped capabilities):

   ```bash
   kubectl run bad-pod --image=nginx -n team-a
   ```

   Expected — **rejected at admission**:

   ```
   Error from server (Forbidden): pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "bad-pod" must set securityContext.allowPrivilegeEscalation=false), unprivileged capabilities not dropped (container "bad-pod" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true, seccompProfile ...
   ```

3. Apply a compliant Pod. Save as `good-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: good-pod
     namespace: team-a
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:stable
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   kubectl apply -f good-pod.yaml
   ```

   Expected:

   ```
   pod/good-pod created
   ```

### 6b — ResourceQuota + default-deny NetworkPolicy (how much, and who talks to whom)

4. Cap what the namespace can consume so one tenant cannot starve the cluster. Save as `team-a-quota.yaml`:

   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-a-quota
     namespace: team-a
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
       pods: "20"
       count/services.loadbalancers: "2"
   ```

   ```bash
   kubectl apply -f team-a-quota.yaml
   kubectl describe resourcequota team-a-quota -n team-a
   ```

   Expected (excerpt):

   ```
   Name:            team-a-quota
   Namespace:       team-a
   Resource         Used  Hard
   --------         ----  ----
   limits.cpu       0     8
   pods             1     20
   requests.memory  0     8Gi
   ```

5. Isolate the namespace with a default-deny ingress policy, then poke one hole. Save as `team-a-netpol.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: team-a
   spec:
     podSelector: {}
     policyTypes: ["Ingress"]
   ---
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-same-namespace
     namespace: team-a
   spec:
     podSelector: {}
     policyTypes: ["Ingress"]
     ingress:
       - from:
           - podSelector: {}
   ```

   ```bash
   kubectl apply -f team-a-netpol.yaml
   ```

### 6c — Policy-as-code with Kyverno (rules RBAC/PSA cannot express)

6. Install Kyverno and enforce an organisational rule that PSA does not cover — *every workload must carry an `owner` label* so the platform can attribute cost and page the right team:

   ```bash
   kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
   kubectl -n kyverno rollout status deployment/kyverno-admission-controller
   ```

   Save as `require-owner-label.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: require-owner-label
   spec:
     validationFailureAction: Enforce
     background: true
     rules:
       - name: check-owner-label
         match:
           any:
             - resources:
                 kinds: ["Pod", "Deployment"]
         validate:
           message: "Every workload must carry a metadata.labels.owner."
           pattern:
             metadata:
               labels:
                 owner: "?*"
   ```

   ```bash
   kubectl apply -f require-owner-label.yaml
   kubectl run no-owner --image=nginxinc/nginx-unprivileged:stable -n team-a \
     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"no-owner","image":"nginxinc/nginx-unprivileged:stable","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
   ```

   Expected — **blocked by Kyverno**, not by RBAC or PSA:

   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
   resource Pod/team-a/no-owner was blocked due to the following policies:
   require-owner-label:
     check-owner-label: 'Every workload must carry a metadata.labels.owner.'
   ```

> **Note (Kyverno versions):** recent Kyverno (1.11+) prefers a per-rule `spec.rules[].validate.failureAction: Enforce` over the namespace-wide `spec.validationFailureAction`; the spec-level field shown here still works and is the most widely documented. Check `kubectl get clusterpolicy require-owner-label -o yaml` on your installed version.

**Comprehension check:**

- **Q6.1** A user with the `admin` ClusterRole in `team-a` (full CRUD on Pods) still could not create `bad-pod` in step 2. Explain precisely *why RBAC said "yes" but the request still failed*, and place PSA in the request lifecycle relative to RBAC (authorization) — which runs first?
- **Q6.2** Steps 4–6 add ResourceQuota, NetworkPolicy, and a Kyverno policy. For each, name one class of risk it mitigates that neither RBAC nor PSA can address. Why is "RBAC alone" never a complete security posture for a multi-tenant platform?
- **Q6.3** The Kyverno policy uses `validationFailureAction: Enforce`. What would `Audit` do instead, and describe the safe rollout sequence you would use to introduce a *new* mandatory policy across dozens of existing tenant namespaces without breaking their running deployments.

---

## Cleanup

```bash
kubectl delete namespace team-a team-b platform-system --ignore-not-found
kubectl delete clusterrole platform-operator platform-cap-configmaps \
  platform-cap-secrets-ro widget-operator --ignore-not-found
kubectl delete clusterrolebinding widget-operator --ignore-not-found
kubectl delete clusterpolicy require-owner-label --ignore-not-found
# Optional: remove Kyverno entirely
# kubectl delete -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
```

---

## Answers

<details>
<summary>Click to reveal answers</summary>

### Exercise 1

**Q1.1** `secrets` are, by design, treated as sensitive data (tokens, TLS keys, DB passwords), so the read-only `view` role deliberately excludes them while `edit` (a mutating role that legitimately needs to create/update Secrets) includes them. The lesson for platform tooling: a dashboard or observability agent that only needs to *display* cluster state should be bound to `view` (or an even tighter custom read role), **never** to `edit`. If your tool genuinely needs specific Secrets, grant `get` on *named* Secrets via `resourceNames` in a custom Role — not blanket `secrets` read. Read-only is not automatically safe; "read-only including Secrets" is a data-exfiltration grant.

**Q1.2** Those `create` verbs are on the *self-review* SubjectAccessReview APIs (`selfsubjectaccessreviews`, `selfsubjectrulesreviews`, `selfsubjectreviews`), granted to every authenticated identity by the `system:basic-user` / `system:discovery` default ClusterRoles. They let an identity ask the API server *"what am I allowed to do?"* about **itself only** — that is exactly what `kubectl auth can-i` uses. It is not an escalation because the answer is purely informational and scoped to the caller's own already-existing permissions; you cannot use a self-review to *gain* access, only to *discover* it.

**Q1.3** The **API server's authorization stack** renders the answer: `kubectl auth can-i` issues a `SubjectAccessReview` (or `SelfSubjectAccessReview`) and the server evaluates it through the *same* authorizer chain (RBAC + any Node/Webhook/ABAC authorizers) that gates real requests. Reading RoleBindings yourself is unreliable because it (a) misses ClusterRoleBindings, aggregated rules, group memberships, and non-RBAC authorizers, and (b) cannot account for order/short-circuit behaviour. Asking the server is authoritative because it is the exact code path a real request takes. *(Ref: <https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access>)*

### Exercise 2

**Q2.1** A ClusterRole bound with a **RoleBinding** grants its permissions **only within the RoleBinding's namespace**. The same ClusterRole bound with a **ClusterRoleBinding** grants those permissions across **every** namespace and on cluster-scoped resources. The RoleBinding-to-ClusterRole idiom is the multi-tenant workhorse because you define a capability *once* (e.g. `view`, or a custom `workload-manager`) as a ClusterRole and then hand it out per-namespace to different teams, without duplicating rules and without leaking cross-namespace access. *(Ref: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#rolebinding-and-clusterrolebinding>)*

**Q2.2** `roleRef` is immutable to make binding grants *auditable and non-surprising*: a subject bound to a low-privilege role can never be silently upgraded by mutating the binding in place (which could bypass escalation checks or evade change review). To "swap" a role you must **delete and recreate** the binding, which produces a clear, reviewable authorization event. The habit it forces: treat bindings as immutable grant records — change access by replacing bindings, not editing them.

**Q2.3** Kubernetes has no Group (or User) object; identities and their group memberships are asserted by the **authenticator** — OIDC tokens (`groups` claim), client-cert Organization (`O=`) fields, or a webhook/identity provider — *before* RBAC ever runs. RBAC only matches strings. This means the *authentication* layer (your IdP / SSO integration) is a first-class part of your security posture: whoever controls group assignment effectively controls authorization, so group-to-role mapping and IdP hygiene are platform-engineering responsibilities, not an afterthought.

### Exercise 3

**Q3.1** The **kube-controller-manager's ClusterRole aggregation controller** performs the merge; it watches ClusterRoles and, whenever one matching an `aggregationRule` selector is created/updated/deleted or (re)labelled, recomputes the union and writes it into the aggregate role's `.rules`. Editing `platform-operator`'s `rules` by hand is wrong because the controller *owns* that field and will overwrite your manual edits on its next reconcile — your change would silently vanish. You contribute rules by creating/labelling a *separate* ClusterRole, never by editing the aggregate.

**Q3.2** They add the label `rbac.authorization.k8s.io/aggregate-to-edit: "true"` to the CRD's ClusterRole (and typically `aggregate-to-admin`/`aggregate-to-view` as appropriate). The risk: `edit` is bound widely to application teams, so aggregating a capability with `delete`/`deletecollection` on impactful resources silently expands what *every* editor across the platform can destroy — aggregation is a blast-radius decision, not just a convenience.

**Q3.3** Because aggregation is a pure additive **union**, you cannot "subtract" a capability by adding another labelled role — RBAC has no deny rules. To revoke a capability you must **remove the label from (or delete) the contributing ClusterRole**, after which the controller recomputes the union without it. Practically: capabilities are granted by *presence* of a labelled role and revoked by its *absence*; there is no override or precedence to reason about, which keeps the model simple but means revocation is a delete/unlabel, never an "add a deny."

### Exercise 4

**Q4.1** `status` and `finalizers` are **subresources** so their write path can be authorized (and reconciled) independently of the main object's `spec`. A controller legitimately writes `status` constantly but should often be restricted from rewriting user-authored `spec`; finalizers gate deletion. If you grant `widgets` but omit `widgets/status`, the operator's `UpdateStatus` calls are **Forbidden**, so it can reconcile the world but never record the result — it will appear to "do nothing," retry forever, and never mark objects Ready. *(Ref: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#referring-to-resources>)*

**Q4.2** As of **v1.24**, Kubernetes no longer auto-generates a long-lived `Secret` token for each ServiceAccount; the recommended path is the `TokenRequest` API (`kubectl create token`, or projected `serviceAccountToken` volumes). Those tokens are **bound** to a specific object (and optionally Pod), **expire** (default ~1h, auto-rotated when projected), and are **audience-scoped**. That's a security win because a leaked token is short-lived, cannot be replayed against arbitrary audiences, and is invalidated when the bound Pod/SA is deleted — unlike the old never-expiring Secret that, if exfiltrated, was valid forever.

**Q4.3** A `ClusterRoleBinding` is correct for a controller that *watches all namespaces*: a namespaced RoleBinding would only authorize it in one namespace, so its all-namespace watch/reconcile would fail everywhere else. The property to scrutinise hardest is the **rule set itself (verbs × resources)**, because a cluster-wide binding multiplies every over-grant across every namespace at once — e.g. an accidental `secrets get` here means *cluster-wide* secret exposure, not one namespace's. Cluster-wide bindings demand the tightest possible ClusterRole.

### Exercise 5

**Q5.1** The rule: a user may only create/update a Role or ClusterRole whose rules are a **subset of permissions the user themselves currently holds** — unless the user has the `escalate` verb on that role resource. Alice could `create roles` but did *not* hold `get/list` on `secrets`, so granting those in a new Role would have handed out a permission she lacked; the API server rejected it with *"attempting to grant RBAC permissions not currently held."* This prevents "create-a-role-to-give-yourself-anything" escalation. *(Ref: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping>)*

**Q5.2** Step 2 (writing a *Role* with rules she doesn't hold) is guarded by the **`escalate`** verb — it governs *defining* permissions. Step 3 (creating a *RoleBinding* to a role she doesn't fully hold) is guarded by the **`bind`** verb — it governs *handing out an existing role*. Two verbs are needed because they are different operations: `escalate` lets you author a powerful role even without holding its powers; `bind` lets you attach an existing powerful role to subjects even without holding its powers. Splitting them lets you delegate one without the other (e.g. allow binding pre-approved roles but forbid authoring new ones).

**Q5.3** Granting `escalate`/`bind` on `roles`/`clusterrolebindings` is nearly equivalent to granting the underlying permissions because the holder can *mint or attach* any role — including one that grants secrets, or even `cluster-admin` — thereby obtaining those powers transitively. The safer platform pattern is **not** to hand teams `escalate`/`bind`; instead, offer a **curated set of pre-defined Roles** (via a self-service portal, GitOps PR review, or an operator that creates bindings on their behalf) so teams can only *select from* vetted roles, never *author* new grants. Keep RBAC-authoring privileges with the platform team and its reviewed pipelines.

### Exercise 6

**Q6.1** RBAC (authorization) only decides whether the *verb on the resource* is allowed — `admin` legitimately holds `create pods`, so authorization returned **yes**. The request then reached the **admission** phase, where the Pod Security *admission* plugin evaluated the Pod's `securityContext` against the namespace's `enforce=restricted` label and **rejected** it. Order in the request lifecycle: authentication → **authorization (RBAC)** → **admission (PSA, then other webhooks like Kyverno)** → validation/persistence. RBAC gates *who may call*; admission gates *what the object may contain*. They are independent gates and both must pass.

**Q6.2** 
- **ResourceQuota** mitigates *resource exhaustion / noisy-neighbour* — one tenant consuming all CPU/memory/Pods/LoadBalancers. RBAC/PSA say nothing about *quantity*.
- **NetworkPolicy** mitigates *lateral movement / cross-tenant network access* — a compromised Pod reaching services it should not. RBAC governs the API server, not Pod-to-Pod traffic.
- **Kyverno policy** mitigates *organisational/governance violations RBAC and PSA cannot express* — here, missing ownership metadata; more generally image-registry allow-lists, mutation of defaults, required probes, etc.
RBAC alone is never complete because it authorises **API calls**, not the *content* of objects, the *quantity* of resources, or the *runtime network*. Defence in depth stacks authorization + admission (PSA) + quotas + network isolation + policy-as-code.

**Q6.3** `Audit` (and `warn`) would **allow** the violating request but **record** a policy violation (in Kyverno's PolicyReports / API-server audit / a warning to the client) instead of blocking it. Safe rollout of a new mandatory policy: (1) deploy it in **`Audit`** mode; (2) let it run against existing workloads and collect the PolicyReports to find every current violator; (3) remediate those workloads (add the missing labels / fix the Pods) team by team; (4) only once reports are clean, flip to **`Enforce`**. This "audit → remediate → enforce" sequence prevents a new rule from instantly breaking every non-compliant deployment already running — the same graceful-adoption pattern PSA supports via its separate `warn`/`audit`/`enforce` labels. *(Refs: <https://kubernetes.io/docs/concepts/security/pod-security-admission/>, <https://kyverno.io/docs/policy-types/cluster-policy/validate/>)*

</details>