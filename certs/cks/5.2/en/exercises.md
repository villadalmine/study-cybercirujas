# Exercises — Topic 5.2: Using Least-Privilege Identity and Access Management

> **Domain context (CKS v1.34, exam weight 2.5).** These guided labs build the practical muscle memory the exam expects around identity and authorization: enumerating who can do what, constructing minimal `Role`/`ClusterRole` grants, hardening `ServiceAccount` token exposure, and spotting the RBAC constructs that quietly hand out cluster-admin. Every step is runnable; expected output is shown so you can confirm you are on track before answering the checkpoint questions.
>
> **Prerequisites**
> - A cluster where you are `cluster-admin` (a throwaway `kind`, `minikube`, or a real cluster's admin kubeconfig). Kubernetes **v1.30+** so that `kubectl create token`, projected bound tokens, and `auth can-i --list` behave as documented.
> - `kubectl` matching the server minor version.
> - Optional but recommended: [`kubectl-who-can`](https://github.com/aquasecurity/kubectl-who-can), [`rakkess`](https://github.com/corneliusweig/rakkess), [`rbac-lookup`](https://github.com/FairwindsOps/rbac-lookup) as `kubectl` plugins.
>
> **Reference material (official)**
> - RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
> - Authorization overview & `can-i`: https://kubernetes.io/docs/reference/access-authn-authz/authorization/
> - ServiceAccounts (admin): https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
> - Configure a ServiceAccount for a Pod: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
> - RBAC good practices: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
> - CKS curriculum: https://github.com/cncf/curriculum

Create a working namespace used by several exercises:

```bash
kubectl create namespace dev
```

---

## Exercise 1 — Enumerate the current authorization surface

Least privilege starts with *measuring* privilege. Before you write a single `Role`, learn to interrogate the authorizer directly instead of reading YAML and guessing.

**Steps**

1. Confirm what *you* (the admin) can do — a fast sanity check that RBAC is the active authorizer:

   ```bash
   kubectl auth can-i '*' '*' --all-namespaces
   ```
   Expected:
   ```
   yes
   ```

2. Ask a *scoped* question — can you delete Pods in `dev`?

   ```bash
   kubectl auth can-i delete pods -n dev
   ```
   Expected:
   ```
   yes
   ```

3. Now impersonate a subject that does not exist yet and enumerate its *effective* permissions. The `--as` flag makes the API server evaluate the request as that subject; `can-i --list` prints the full resolved matrix:

   ```bash
   kubectl auth can-i --list \
     --as=system:serviceaccount:dev:builder -n dev
   ```
   Expected (a brand-new SA with no bindings still inherits the baseline `system:discovery`/self-review rules):
   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                   [/api/*]            []               [get]
                                                   [/api]              []               [get]
                                                   ...
   ```

4. Ask a targeted question as that same SA — can it read Secrets in `dev`?

   ```bash
   kubectl auth can-i get secrets -n dev \
     --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   no
   ```

5. Use `resourceNames`-style targeting in the question itself — can the SA `get` one specific Secret by name?

   ```bash
   kubectl auth can-i get secrets/db-password -n dev \
     --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   no
   ```

**Checkpoint questions**

- **Q1.** What is the practical difference between `kubectl auth can-i get secrets -n dev` and `kubectl auth can-i --list -n dev`, and why is `--list` the more valuable audit primitive?
- **Q2.** In step 3 the SA had *no* `RoleBinding` yet `can-i --list` still returned several allowed rules. Where do those baseline permissions come from, and does their existence violate least privilege?
- **Q3.** Which RBAC verb would a subject need in order to *impersonate* another user or ServiceAccount the way `--as` does here, and why is granting it so dangerous?

---

## Exercise 2 — Build a least-privilege Role from scratch

The core skill: express exactly the access an application needs — no wildcards, no spare verbs — and prove it with the authorizer.

**Steps**

1. Suppose the `builder` workload must **read and watch ConfigMaps** in `dev` and **create Events** — nothing else. Write a namespaced `Role` (namespaced object → `Role`, not `ClusterRole`):

   ```yaml
   # role-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: builder
     namespace: dev
   rules:
     - apiGroups: [""]              # core API group
       resources: ["configmaps"]
       verbs: ["get", "list", "watch"]
     - apiGroups: [""]
       resources: ["events"]
       verbs: ["create"]
   ```

2. Bind it to the `builder` ServiceAccount with a `RoleBinding` (grant is confined to namespace `dev`):

   ```yaml
   # rolebinding-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: builder
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: builder
     apiGroup: rbac.authorization.k8s.io
   ```

3. Create the SA and apply everything:

   ```bash
   kubectl create serviceaccount builder -n dev
   kubectl apply -f role-builder.yaml -f rolebinding-builder.yaml
   ```
   Expected:
   ```
   serviceaccount/builder created
   role.rbac.authorization.k8s.io/builder created
   rolebinding.rbac.authorization.k8s.io/builder created
   ```

4. Prove the grant is exactly what you intended — allowed:

   ```bash
   kubectl auth can-i watch configmaps -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i create events   -n dev --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   yes
   yes
   ```

5. Prove the *negative space* — deny by default holds for everything you did not grant, including neighbouring verbs and cross-namespace access:

   ```bash
   kubectl auth can-i delete configmaps -n dev     --as=system:serviceaccount:dev:builder
   kubectl auth can-i get configmaps    -n default --as=system:serviceaccount:dev:builder
   kubectl auth can-i list secrets      -n dev     --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   no
   no
   no
   ```

**Checkpoint questions**

- **Q4.** The `builder` Role grants `create` on Events but not `get`/`list`. If the app only *emits* Events and never reads them back, is this correct least privilege, or a mistake?
- **Q5.** Step 5 shows `get configmaps -n default` is denied even though the Role allows `get configmaps`. Explain precisely why the namespace matters here and how a `ClusterRole` + `RoleBinding` combination would change (or not change) that result.
- **Q6.** You need to grant read access to a resource in the `apps` API group (e.g. `deployments`). What must change in the `rules` block, and what happens if you leave `apiGroups: [""]`?

---

## Exercise 3 — Stop mounting tokens that workloads never use

Every Pod that mounts a ServiceAccount token hands a bearer credential to any process (or attacker) inside that container. If the workload does not talk to the API server, that token is pure attack surface.

**Steps**

1. Observe the default behaviour. Run a throwaway Pod under the *default* SA and check whether a token was injected:

   ```bash
   kubectl run probe --image=busybox -n dev --restart=Never -- sleep 3600
   kubectl exec probe -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
   Expected:
   ```
   ca.crt
   namespace
   token
   ```

2. Disable automounting **at the ServiceAccount level** so every Pod that uses it defaults to *no* token:

   ```bash
   kubectl patch serviceaccount builder -n dev \
     -p '{"automountServiceAccountToken": false}'
   ```
   Expected:
   ```
   serviceaccount/builder patched
   ```

3. Run a Pod under `builder` and confirm the token directory is gone:

   ```bash
   kubectl run probe2 --image=busybox -n dev --restart=Never \
     --overrides='{"spec":{"serviceAccountName":"builder"}}' -- sleep 3600
   kubectl exec probe2 -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ```
   Expected:
   ```
   ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   command terminated with exit code 1
   ```

4. Learn the **precedence** rule. The Pod spec can override the SA either direction. Here a Pod *re-enables* the mount even though the SA disabled it:

   ```yaml
   # pod-explicit-mount.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: needs-api
     namespace: dev
   spec:
     serviceAccountName: builder
     automountServiceAccountToken: true   # Pod-level wins over SA-level
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
   ```
   ```bash
   kubectl apply -f pod-explicit-mount.yaml
   kubectl exec needs-api -n dev -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```
   Expected:
   ```
   ca.crt
   namespace
   token
   ```

**Checkpoint questions**

- **Q7.** State the precedence rule between `automountServiceAccountToken` on the ServiceAccount and on the Pod. Which one wins, and what is the recommended *default posture* for a hardened cluster?
- **Q8.** A workload has `automountServiceAccountToken: false` but genuinely needs to call the API for one narrow purpose. What is the least-privilege way to give it a token without re-enabling the broad automount?
- **Q9.** Why is leaving the token mounted on a Pod that never contacts the API server a real security problem and not just tidiness? Name the concrete escalation an attacker gains.

---

## Exercise 4 — Bound, short-lived tokens vs. legacy static Secrets

Since v1.24 Kubernetes no longer auto-generates a non-expiring Secret per ServiceAccount. Injected tokens are now **projected, audience-scoped, time-bound, and Pod-bound**, and are rotated by the kubelet. This exercise makes that concrete and contrasts it with the legacy static token you should avoid minting.

**Steps**

1. Mint a bound token on demand with the TokenRequest API and inspect its claims:

   ```bash
   TOKEN=$(kubectl create token builder -n dev --duration=15m)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
   ```
   Expected (abridged):
   ```json
   {
     "aud": ["https://kubernetes.default.svc.cluster.local"],
     "exp": 1754320500,
     "iat": 1754319600,
     "kubernetes.io": {
       "namespace": "dev",
       "serviceaccount": {
         "name": "builder",
         "uid": "9c1f...":
       }
     },
     "sub": "system:serviceaccount:dev:builder"
   }
   ```

2. Note the projected token inside a Pod. Inspect the volume the kubelet injects — a `projected` volume with a `serviceAccountToken` source, **not** a Secret:

   ```bash
   kubectl get pod needs-api -n dev -o jsonpath='{.spec.volumes[*].projected.sources}' | jq .
   ```
   Expected:
   ```json
   [
     { "serviceAccountToken": { "expirationSeconds": 3607, "path": "token" } },
     { "configMap": { "items": [{"key":"ca.crt","path":"ca.crt"}], "name": "kube-root-ca.crt" } },
     { "downwardAPI": { "items": [{"path":"namespace","fieldRef":{"fieldPath":"metadata.namespace"}}] } }
   ]
   ```

3. Craft a token with a **custom audience and tight expiry** — this is how you scope a token to a specific consumer (e.g. an OIDC-aware sidecar or an admission webhook) rather than the API server:

   ```yaml
   # pod-projected-token.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: vault-agent
     namespace: dev
   spec:
     serviceAccountName: builder
     automountServiceAccountToken: false   # suppress the default API-server token
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
         volumeMounts:
           - name: vault-token
             mountPath: /var/run/secrets/vault
             readOnly: true
     volumes:
       - name: vault-token
         projected:
           sources:
             - serviceAccountToken:
                 audience: vault
                 expirationSeconds: 600      # 10 min, kubelet rotates before expiry
                 path: vault-token
   ```
   ```bash
   kubectl apply -f pod-projected-token.yaml
   kubectl exec vault-agent -n dev -- \
     sh -c 'cut -d. -f2 /var/run/secrets/vault/vault-token | base64 -d 2>/dev/null' | jq .aud
   ```
   Expected:
   ```json
   ["vault"]
   ```

4. See what the **legacy static token** looks like (the anti-pattern), so you can recognise it in an audit. This Secret never expires and is not bound to any Pod:

   ```yaml
   # legacy-token.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: builder-legacy-token
     namespace: dev
     annotations:
       kubernetes.io/service-account.name: builder
   type: kubernetes.io/service-account-token
   ```
   ```bash
   kubectl apply -f legacy-token.yaml
   kubectl get secret builder-legacy-token -n dev -o jsonpath='{.data.token}' \
     | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | jq 'has("exp")'
   ```
   Expected:
   ```
   false
   ```
   (Clean up the anti-pattern immediately: `kubectl delete secret builder-legacy-token -n dev`.)

**Checkpoint questions**

- **Q10.** List the four independent properties a modern projected bound token has that the legacy static Secret token in step 4 lacks. Why does each one reduce blast radius?
- **Q11.** The token in step 1 has `"aud": ["https://kubernetes.default.svc..."]` while the step-3 token has `"aud": ["vault"]`. If you presented the `vault`-audience token to the Kubernetes API server, what happens, and why is audience binding a defence-in-depth control?
- **Q12.** A pentester finds a leaked token whose `exp` is 8 minutes away. Compared with a leaked legacy static token, how does the bound token change the incident response, and what single field in the projected source controls that window?

---

## Exercise 5 — Hunt for over-broad and dangerous grants

Least privilege is also a *detection* discipline. This exercise seeds two classic misconfigurations and then finds them the way an auditor would.

**Steps**

1. Seed a wildcard grant (the "it just works" Role that owns the namespace):

   ```yaml
   # bad-wildcard.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: bad-wildcard
     namespace: dev
   rules:
     - apiGroups: ["*"]
       resources: ["*"]
       verbs: ["*"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: bad-wildcard
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: bad-wildcard
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f bad-wildcard.yaml
   ```

2. Seed a subtle privilege-escalation grant using the `escalate` and `bind` verbs on RBAC objects:

   ```yaml
   # bad-escalate.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: bad-escalate
   rules:
     - apiGroups: ["rbac.authorization.k8s.io"]
       resources: ["roles", "clusterroles", "rolebindings", "clusterrolebindings"]
       verbs: ["create", "escalate", "bind"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: bad-escalate
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: ClusterRole
     name: bad-escalate
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f bad-escalate.yaml
   ```

3. Detect wildcard verbs quickly with a JSONPath sweep over all Roles/ClusterRoles:

   ```bash
   kubectl get roles,clusterroles -A -o json \
     | jq -r '.items[]
        | select(.rules[]? | (.verbs[]? == "*") or (.resources[]? == "*"))
        | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)"' \
     | sort -u
   ```
   Expected (your seeded Role plus a few legitimate system roles):
   ```
   ClusterRole/-/cluster-admin
   Role/dev/bad-wildcard
   ...
   ```

4. Find *who can do the dangerous thing* rather than *who holds a role*. With `kubectl-who-can`:

   ```bash
   kubectl who-can create pods -n dev
   ```
   Expected (abridged):
   ```
   ROLEBINDING       NAMESPACE  SUBJECT   TYPE            SA-NAMESPACE
   bad-wildcard      dev        builder   ServiceAccount  dev
   ```

5. Enumerate every subject bound to `cluster-admin` (the grant that must be justified for every single holder):

   ```bash
   kubectl get clusterrolebindings -o json \
     | jq -r '.items[]
        | select(.roleRef.name=="cluster-admin")
        | .metadata.name as $b | (.subjects[]? | "\($b)\t\(.kind)\t\(.namespace // "-")/\(.name)")'
   ```
   Expected:
   ```
   cluster-admin   Group   -/system:masters
   ```

6. Confirm the escalation grant is real using the authorizer:

   ```bash
   kubectl auth can-i create clusterrolebindings --as=system:serviceaccount:dev:builder
   kubectl auth can-i escalate clusterroles     --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   yes
   yes
   ```

**Checkpoint questions**

- **Q13.** Explain what the `escalate` verb actually bypasses. Normally, why *can't* a user create a Role more powerful than their own permissions, and how does `escalate` defeat that guardrail?
- **Q14.** What does the `bind` verb allow that `create` on `rolebindings` alone does not? Describe the attack that combines `create rolebindings` + `bind` to reach `cluster-admin`.
- **Q15.** In step 5 the only `cluster-admin` subject is the group `system:masters`. Why can you *not* remediate an over-privileged `system:masters` member by editing RBAC, and where does that binding actually come from?

---

## Exercise 6 — Turn RBAC grants into a concrete privilege-escalation chain (and close it)

Some verbs look harmless on paper but are equivalent to cluster-admin in practice. Here you *execute* two textbook escalations as the low-privilege SA, then remediate.

**Steps**

1. Reset `builder` to a realistic-but-dangerous grant: `create` on Pods and `get`/`list` on Secrets in `dev`. First remove the wildcard/escalate seeds from Exercise 5 so the chain is unambiguous:

   ```bash
   kubectl delete -f bad-wildcard.yaml -f bad-escalate.yaml
   ```
   ```yaml
   # risky-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: risky-builder
     namespace: dev
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["create", "get", "list"]
     - apiGroups: [""]
       resources: ["secrets"]
       verbs: ["get", "list"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: risky-builder
     namespace: dev
   subjects:
     - kind: ServiceAccount
       name: builder
       namespace: dev
   roleRef:
     kind: Role
     name: risky-builder
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f risky-builder.yaml
   ```

2. Create a privileged SA whose token the attacker wants to steal (simulating a powerful controller in `dev`):

   ```bash
   kubectl create serviceaccount powerful -n dev
   kubectl create clusterrolebinding powerful-admin \
     --clusterrole=cluster-admin \
     --serviceaccount=dev:powerful
   ```

3. **Escalation A — run a Pod as the powerful SA.** Because `builder` can `create pods` in `dev`, it can schedule a Pod that runs under *any* SA in `dev`, then read that Pod's mounted token. Impersonate `builder` to prove the API server allows it:

   ```bash
   cat <<'EOF' | kubectl create -n dev --as=system:serviceaccount:dev:builder -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: pwn
     namespace: dev
   spec:
     serviceAccountName: powerful
     containers:
       - name: c
         image: busybox
         command: ["sleep", "3600"]
   EOF
   ```
   Expected:
   ```
   pod/pwn created
   ```
   The attacker now `kubectl exec`s (or reads the projected token) and holds a `cluster-admin` credential.

4. **Escalation B — read Secrets directly.** `get`/`list` on Secrets means every credential in the namespace is exposed, including other ServiceAccounts' legacy tokens if any exist:

   ```bash
   kubectl get secrets -n dev --as=system:serviceaccount:dev:builder
   ```
   Expected: the SA can list every Secret in `dev`.

5. **Remediate.** Replace the risky grant with a minimal one that removes both vectors — drop `create pods` and scope Secret reads to named objects only:

   ```yaml
   # fixed-builder.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: risky-builder      # same name → overwrites the grant
     namespace: dev
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list"]                 # no more create
     - apiGroups: [""]
       resources: ["secrets"]
       resourceNames: ["app-config"]          # only this one Secret
       verbs: ["get"]
   ```
   ```bash
   kubectl apply -f fixed-builder.yaml
   ```

6. Verify both vectors are closed:

   ```bash
   kubectl auth can-i create pods            -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i list   secrets         -n dev --as=system:serviceaccount:dev:builder
   kubectl auth can-i get    secrets/app-config -n dev --as=system:serviceaccount:dev:builder
   ```
   Expected:
   ```
   no
   no
   yes
   ```

**Checkpoint questions**

- **Q16.** Explain step 3 in your own words: why is `create pods` in a namespace effectively equivalent to *"assume the identity of the most powerful ServiceAccount in that namespace"*? What two other Pod-spec fields grant analogous escalations?
- **Q17.** In step 6, `list secrets` is now denied but `get secrets/app-config` is allowed. Why does adding `resourceNames` force you to drop `list`/`watch`, and what is the security reasoning behind that limitation?
- **Q18.** Beyond `create pods`, `get secrets`, `escalate`, `bind`, and `impersonate`, name **two** other grants that are commonly under-estimated but yield privilege escalation, and briefly say how each is abused.

---

## Cleanup

```bash
kubectl delete namespace dev --wait=false
kubectl delete clusterrolebinding powerful-admin --ignore-not-found
kubectl delete clusterrole bad-escalate --ignore-not-found
```

---

<details>
<summary><strong>Answers — checkpoint questions Q1–Q18</strong></summary>

**Q1.** `can-i get secrets` answers one yes/no question about a single (verb, resource) tuple; `can-i --list` resolves and prints the *entire* effective permission matrix for the subject in that scope. For auditing, `--list` is superior because it reveals grants you did not think to ask about — the wildcard, the stray `escalate`, the forgotten `create pods` — instead of only confirming a hypothesis you already had. It queries the `SelfSubjectRulesReview` API and reflects the union of all bindings that apply.

**Q2.** Those rules come from the `system:discovery`, `system:public-info-viewer`, and self-review ClusterRoles bound to the `system:authenticated` (and sometimes `system:unauthenticated`) group. Every authenticated identity inherits them. They allow read-only discovery of API paths and creating `SelfSubject*Review` objects (asking "what can *I* do"). They do **not** violate least privilege: they expose no cluster data or mutation capability — only API surface metadata and self-introspection that the client already needs to function.

**Q3.** The `impersonate` verb (on `users`, `groups`, and/or `serviceaccounts`). It is dangerous because it lets the holder *become* any other subject and inherit that subject's permissions — including a `cluster-admin` user — so it is a direct, total privilege-escalation primitive. It should essentially never be granted to workloads, and to humans only for narrowly-scoped, audited tooling. (As `cluster-admin` you can use `--as` in these labs precisely because admin already implies impersonation.)

**Q4.** It is correct least privilege. Capabilities are granted per verb; an app that only *emits* Events legitimately needs only `create`. Adding `get`/`list` "for symmetry" would be spare privilege. Grant read verbs only if the code actually reads Events back.

**Q5.** A `Role` + `RoleBinding` grant is confined to the `RoleBinding`'s namespace, so `builder`'s rights exist only in `dev`; `get configmaps -n default` is therefore denied. Using a **ClusterRole** referenced by a **RoleBinding** would *still* confine the effective permission to the binding's namespace — the ClusterRole merely supplies reusable rules. Only a ClusterRole referenced by a **ClusterRoleBinding** grants the permission cluster-wide (all namespaces). So the object combination, not the object kind alone, determines scope.

**Q6.** Add a second rule (or change the existing one) with `apiGroups: ["apps"]` and `resources: ["deployments"]`. API-group membership is significant: `deployments` live in the `apps` group, so leaving `apiGroups: [""]` (the core group) means the rule simply never matches `deployments` and the request is denied. RBAC rules match on the (apiGroup, resource, verb) triple.

**Q7.** Pod-level `automountServiceAccountToken` **overrides** the ServiceAccount-level setting in both directions. The hardened default posture is to set `automountServiceAccountToken: false` on ServiceAccounts (or at least on `default`) so *nothing* mounts a token unless a Pod explicitly opts in — deny by default, opt-in per workload.

**Q8.** Keep automount off and inject a **narrowly-scoped projected `serviceAccountToken` volume** on just that Pod (custom `audience`, short `expirationSeconds`), mounted read-only where the app expects it — exactly the pattern in Exercise 4 step 3. That gives the one workload a bound, expiring, audience-scoped credential without re-enabling broad automount, and without granting the SA any extra RBAC it doesn't need.

**Q9.** A mounted token is a live bearer credential readable by every process in the container. If the workload is compromised (RCE, SSRF, a malicious dependency, a leaked debug shell), the attacker reads `/var/run/secrets/.../token` and can immediately authenticate to the API server as that ServiceAccount — turning a container-level compromise into cluster API access scoped to whatever that SA can do. An unused token is therefore free attack surface with zero benefit.

**Q10.** The projected bound token is (1) **time-bound** (`exp`, kubelet-rotated) so a leak self-heals; (2) **audience-scoped** (`aud`) so it is only accepted by the intended consumer; (3) **object-bound** — its `kubernetes.io` claim ties it to a specific Pod (and SA) UID, so it is invalidated when the Pod is deleted; and (4) **not stored as a persistent Secret**, so it never sits at rest in etcd waiting to be read via `get secrets`. The legacy static Secret token has none of these — it never expires, has no audience, is bound to nothing, and lives forever in etcd.

**Q11.** The API server rejects it (401/invalid audience) because the token's `aud` is `vault`, not the API server's audience. Audience binding is defence-in-depth: even if the `vault` token leaks, it cannot be replayed against the Kubernetes API — it is only valid for the specific service it was minted for, limiting where a stolen credential is usable.

**Q12.** With a bound token the clock is already ticking: it becomes useless in ~8 minutes without any admin action, so IR can prioritise rotating the *workload*/credential rather than racing to revoke a permanent token. A leaked legacy static token, by contrast, is valid until you delete the Secret and would require finding and deleting it everywhere. The window is controlled by `expirationSeconds` on the projected `serviceAccountToken` source (and the kubelet rotates before it lapses).

**Q13.** Normally RBAC enforces a **privilege-escalation-prevention** check: to create or update a Role/ClusterRole, you must already hold *every permission* the new role would grant (or hold `escalate`). This stops a limited user from writing themselves a more powerful role. The `escalate` verb explicitly *bypasses* that check, letting the holder author a Role containing permissions they do not themselves have — i.e. mint arbitrary privilege out of thin air.

**Q14.** `create` on `rolebindings`/`clusterrolebindings` is subject to a similar guard: to bind a role, you must already hold that role's permissions (or hold `bind`). The `bind` verb waives that guard, letting the holder create a binding to a role *more powerful than themselves*. The attack: with `create rolebindings` + `bind`, the subject creates a `ClusterRoleBinding` (or RoleBinding) referencing the existing `cluster-admin` ClusterRole with themselves as subject — instant cluster-admin, no need to author a new role.

**Q15.** `system:masters` is a **hard-coded superuser group** wired into the API server's authorization path — requests carrying that group short-circuit RBAC entirely and are always allowed; there is no Role/binding you can edit to constrain it. Membership comes from client credentials (typically x509 client certs with `O=system:masters`, e.g. the bootstrap admin cert), not from RBAC objects. To "remediate" it you must stop issuing/trusting those certificates (rotate the CA, revoke/reissue kubeconfigs), because it lives in the authentication/PKI layer, not in RBAC.

**Q16.** `create pods` lets you set `spec.serviceAccountName` to *any* SA in that namespace; the kubelet then mounts that SA's token into your Pod, which you read via `exec` or a projected volume — so you inherit the most powerful SA's identity. It is de-facto impersonation of any namespace SA. Two analogous escalations: `spec.volumes.hostPath` (mount the node filesystem, read kubelet creds / other containers' secrets, escape to the host) and `spec.nodeName` / privileged `securityContext` (run privileged or on a control-plane node). Related vectors: `pods/exec` and `pods/attach` (shell into existing privileged Pods), and `pods/ephemeralcontainers`.

**Q17.** `resourceNames` restricts a rule to specific named objects, but the `list` and `watch` verbs enumerate a *collection* — the request has no single object name to match against, so RBAC cannot filter a list/watch by `resourceNames`. Consequently `resourceNames` only works with verbs that address one object by name (`get`, `update`, `patch`, `delete`). The security reasoning: allowing `list` would let the subject read *all* objects (defeating the whitelist), so RBAC refuses to combine them. To read exactly one Secret you must use `get secrets/<name>` and forgo `list`.

**Q18.** Any two of, e.g.:
- **`create` on `serviceaccounts/token` (TokenRequest subresource)** — mint a valid token for *any* ServiceAccount, including a `cluster-admin`-bound one, without ever running a Pod.
- **`approve`/`create` on `certificatesigningrequests` (+ signer access)** — issue yourself a client cert for an arbitrary user/group such as `system:masters`, bypassing RBAC entirely.
- **`update`/`patch` on `nodes/status` or `nodes`**, or **`get nodes/proxy`** — reach the kubelet API to exec into any Pod on the node and read its secrets.
- **`patch` on your own `RoleBinding`/`ClusterRoleBinding` subjects**, or **`update` on validating/mutating `webhookconfigurations`** — intercept or rewrite API requests cluster-wide.
- **`escalate`-free but `patch` on existing powerful ClusterRoles** you are already bound to — add rules to a role you hold.

*(Sources: RBAC — https://kubernetes.io/docs/reference/access-authn-authz/rbac/ ; RBAC good practices, incl. the escalation-vector list — https://kubernetes.io/docs/concepts/security/rbac-good-practices/ ; ServiceAccount tokens — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/ .)*

</details>