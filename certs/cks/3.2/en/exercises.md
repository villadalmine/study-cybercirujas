# Exercise Caution in Using Service Accounts (CKS 1.34 — Topic 3.2)

Every Pod in Kubernetes authenticates to the API server as a **ServiceAccount** (SA). If you do nothing, that identity is the namespace's `default` SA, and — historically — its token was mounted into every container at `/var/run/secrets/kubernetes.io/serviceaccount/`. An attacker who achieves code execution in a Pod immediately inherits that identity and every RBAC permission bound to it. This module walks through hardening the ServiceAccount attack surface: disabling automatic token mounts, understanding bound (projected) tokens versus legacy Secret tokens, and building least-privilege SAs.

> **Reference sources**
> - CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
> - Configure Service Accounts for Pods — <https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/>
> - Managing Service Accounts — <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/>
> - Bound Service Account Tokens / TokenRequest — <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#bound-service-account-token-volume>
> - Using RBAC Authorization — <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>

Assume a cluster running Kubernetes **1.34** and a shell with cluster-admin. All commands are copy-paste runnable.

---

## Exercise 1 — Observe the default ServiceAccount and its automatic token mount

**Goal:** prove that a Pod with no explicit `serviceAccountName` receives the `default` SA identity and a mounted token, then read the token's contents.

1. Create an isolated namespace to work in:

   ```bash
   kubectl create namespace sa-lab
   ```

   Expected:

   ```
   namespace/sa-lab created
   ```

2. Confirm the `default` ServiceAccount already exists (Kubernetes creates one per namespace automatically):

   ```bash
   kubectl -n sa-lab get serviceaccount
   ```

   Expected:

   ```
   NAME      SECRETS   AGE
   default   0         10s
   ```

   > Note the `SECRETS` column reads `0`. Since Kubernetes 1.24 (`LegacyServiceAccountTokenNoAutoGeneration`), the control plane **no longer auto-creates a long-lived Secret token** for each SA. Tokens are now issued on demand as short-lived, audience-bound projected volumes.

3. Run a Pod that does **not** specify a ServiceAccount:

   ```bash
   kubectl -n sa-lab run probe --image=nginx:stable --restart=Never
   kubectl -n sa-lab wait --for=condition=Ready pod/probe --timeout=60s
   ```

4. Inspect which SA the Pod bound to and whether a token volume was injected:

   ```bash
   kubectl -n sa-lab get pod probe -o jsonpath='{.spec.serviceAccountName}{"\n"}'
   kubectl -n sa-lab get pod probe \
     -o jsonpath='{range .spec.volumes[*]}{.name}{"\t"}{.projected.sources}{"\n"}{end}'
   ```

   Expected (abridged):

   ```
   default
   kube-api-access-xxxxx	[{"serviceAccountToken":{...}},{"configMap":{...}},{"downwardAPI":{...}}]
   ```

5. From inside the container, read the mounted token and the namespace file:

   ```bash
   kubectl -n sa-lab exec probe -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/namespace
   echo
   kubectl -n sa-lab exec probe -- \
     head -c 60 /var/run/secrets/kubernetes.io/serviceaccount/token; echo
   ```

   Expected:

   ```
   sa-lab
   eyJhbGciOiJSUzI1NiIsImtpZCI6Il...   (a truncated JWT)
   ```

6. Decode the token's payload (base64url of the middle JWT segment) to see its claims:

   ```bash
   kubectl -n sa-lab exec probe -- \
     cat /var/run/secrets/kubernetes.io/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Expected (abridged):

   ```json
   {
       "aud": ["https://kubernetes.default.svc.cluster.local"],
       "exp": 1770000000,
       "iat": 1769996400,
       "kubernetes.io": {
           "namespace": "sa-lab",
           "pod": { "name": "probe", "uid": "..." },
           "serviceaccount": { "name": "default", "uid": "..." }
       },
       "sub": "system:serviceaccount:sa-lab:default"
   }
   ```

> **Comprehension check 1**
> 1. The `SECRETS` column on the `default` SA was `0`, yet the Pod still received a working token. Where did that token come from?
> 2. What is the identity string (the RBAC `sub`) that this Pod presents to the API server?
> 3. Name two claims in the decoded token that make it a *bound* token rather than a legacy static token, and explain why each one limits an attacker.

---

## Exercise 2 — Disable token automounting (SA-level vs Pod-level)

**Goal:** stop the token from being mounted at all, and understand the precedence rules between the ServiceAccount setting and the Pod setting.

1. Set `automountServiceAccountToken: false` on the `default` SA so that Pods in this namespace stop receiving a token by default:

   ```bash
   kubectl -n sa-lab patch serviceaccount default \
     -p '{"automountServiceAccountToken": false}'
   ```

   Expected:

   ```
   serviceaccount/default patched
   ```

2. Launch a fresh Pod (no explicit SA) and check whether the token volume is present:

   ```bash
   kubectl -n sa-lab run probe2 --image=nginx:stable --restart=Never
   kubectl -n sa-lab wait --for=condition=Ready pod/probe2 --timeout=60s
   kubectl -n sa-lab exec probe2 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "NO TOKEN MOUNTED"
   ```

   Expected:

   ```
   ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount/': No such file or directory
   NO TOKEN MOUNTED
   ```

3. Now demonstrate **Pod-level override wins**. Apply a manifest where the SA says "no automount" but the Pod explicitly opts back in:

   ```yaml
   # probe3.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe3
     namespace: sa-lab
   spec:
     serviceAccountName: default          # SA has automount=false
     automountServiceAccountToken: true   # Pod-level override forces the mount
     containers:
       - name: app
         image: nginx:stable
   ```

   ```bash
   kubectl apply -f probe3.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/probe3 --timeout=60s
   kubectl -n sa-lab exec probe3 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/
   ```

   Expected:

   ```
   ca.crt  namespace  token
   ```

4. Demonstrate the reverse override. Re-enable automount on the SA, but have the Pod opt out:

   ```bash
   kubectl -n sa-lab patch serviceaccount default \
     -p '{"automountServiceAccountToken": true}'
   ```

   ```yaml
   # probe4.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: probe4
     namespace: sa-lab
   spec:
     serviceAccountName: default          # SA has automount=true
     automountServiceAccountToken: false  # Pod-level override suppresses the mount
     containers:
       - name: app
         image: nginx:stable
   ```

   ```bash
   kubectl apply -f probe4.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/probe4 --timeout=60s
   kubectl -n sa-lab exec probe4 -- \
     ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "NO TOKEN MOUNTED"
   ```

   Expected:

   ```
   NO TOKEN MOUNTED
   ```

> **Comprehension check 2**
> 1. State the precedence rule between `ServiceAccount.automountServiceAccountToken` and `Pod.spec.automountServiceAccountToken`.
> 2. A workload genuinely needs to talk to the API server. Which is the more defensible hardening posture: set `automountServiceAccountToken: false` on the *SA* and re-enable it only on the Pods that need it, or set it `true` on the SA and disable it per-Pod? Justify your answer in terms of fail-safe defaults.
> 3. Disabling the automount removes the in-Pod token file. Does that revoke the ServiceAccount's RBAC permissions? Why or why not?

---

## Exercise 3 — Create a dedicated, least-privilege ServiceAccount

**Goal:** replace the shared `default` SA with a purpose-built SA that has exactly one narrow permission, and bind it with a namespaced Role.

1. Create a dedicated SA for a hypothetical app that only needs to *read* Pods in its own namespace. Bake in the safe default of no automount:

   ```yaml
   # app-sa.yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: pod-reader-sa
     namespace: sa-lab
   automountServiceAccountToken: false
   ```

   ```bash
   kubectl apply -f app-sa.yaml
   ```

2. Define a namespaced `Role` granting only `get`, `list`, `watch` on `pods` — nothing else:

   ```yaml
   # pod-reader-role.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: sa-lab
   rules:
     - apiGroups: [""]           # core API group
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

3. Bind the Role to the SA with a `RoleBinding`:

   ```yaml
   # pod-reader-binding.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-reader-binding
     namespace: sa-lab
   subjects:
     - kind: ServiceAccount
       name: pod-reader-sa
       namespace: sa-lab
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f pod-reader-binding.yaml
   ```

4. Verify the effective permissions with `kubectl auth can-i` **impersonating the SA** (the `--as` flag uses the `system:serviceaccount:<ns>:<name>` form). Confirm both the allowed and the denied cases:

   ```bash
   kubectl -n sa-lab auth can-i list pods \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl -n sa-lab auth can-i delete pods \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   kubectl -n sa-lab auth can-i get secrets \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Expected:

   ```
   yes
   no
   no
   ```

5. Run a Pod that uses the new SA and explicitly opts into the token mount (since the SA defaults to no automount), so it can actually call the API:

   ```yaml
   # reader-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: reader
     namespace: sa-lab
   spec:
     serviceAccountName: pod-reader-sa
     automountServiceAccountToken: true
     containers:
       - name: kubectl
         image: bitnami/kubectl:1.34
         command: ["sleep", "3600"]
   ```

   ```bash
   kubectl apply -f reader-pod.yaml
   kubectl -n sa-lab wait --for=condition=Ready pod/reader --timeout=90s
   ```

6. From *inside* the Pod, exercise the real bound token against the API server — the allowed call succeeds, the forbidden call returns `403`:

   ```bash
   kubectl -n sa-lab exec reader -- kubectl get pods
   echo "---"
   kubectl -n sa-lab exec reader -- kubectl get secrets 2>&1 || true
   ```

   Expected (abridged):

   ```
   NAME     READY   STATUS    ...
   reader   1/1     Running   ...
   probe    1/1     Running   ...
   ---
   Error from server (Forbidden): secrets is forbidden: User
   "system:serviceaccount:sa-lab:pod-reader-sa" cannot list resource
   "secrets" in API group "" in the namespace "sa-lab"
   ```

> **Comprehension check 3**
> 1. Why is `kubectl auth can-i ... --as=system:serviceaccount:sa-lab:pod-reader-sa` a better verification method than reading the Role YAML by eye?
> 2. The Role above uses `apiGroups: [""]`. What does the empty string denote, and what would happen to the `pods` rule if you wrote `apiGroups: ["v1"]` instead?
> 3. This SA can read Pods only in `sa-lab`. What single change to the RBAC objects would (incorrectly) widen that to *all* namespaces, and why is that a common least-privilege mistake?

---

## Exercise 4 — Issue and understand bound tokens with the TokenRequest API

**Goal:** mint a short-lived, audience-scoped token on demand with `kubectl create token`, contrast it with a legacy Secret-based token, and understand why bound tokens are the safer primitive.

1. Request a bound token for the SA with a 15-minute lifetime, scoped to a specific audience:

   ```bash
   kubectl -n sa-lab create token pod-reader-sa \
     --duration=15m \
     --audience=vault.internal \
     --output=json | python3 -c \
     'import sys,json; d=json.load(sys.stdin); print(d["status"]["expirationTimestamp"])'
   ```

   Expected (a timestamp ~15 minutes in the future):

   ```
   2026-07-30T12:15:00Z
   ```

2. Mint a token and decode its claims to confirm the audience and expiry are enforced by the issuer:

   ```bash
   TOKEN=$(kubectl -n sa-lab create token pod-reader-sa --duration=15m --audience=vault.internal)
   echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Expected (abridged):

   ```json
   {
       "aud": ["vault.internal"],
       "exp": 1769998200,
       "iat": 1769997300,
       "sub": "system:serviceaccount:sa-lab:pod-reader-sa"
   }
   ```

3. Contrast with a **legacy** long-lived token. You can still force one by creating a Secret of type `kubernetes.io/service-account-token`. Do this to *understand the risk*, not as a recommended pattern:

   ```yaml
   # legacy-token.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: pod-reader-legacy-token
     namespace: sa-lab
     annotations:
       kubernetes.io/service-account.name: pod-reader-sa
   type: kubernetes.io/service-account-token
   ```

   ```bash
   kubectl apply -f legacy-token.yaml
   kubectl -n sa-lab get secret pod-reader-legacy-token \
     -o jsonpath='{.data.token}' | base64 -d | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
   ```

   Expected (abridged) — note the **absence** of an `exp` claim:

   ```json
   {
       "iss": "https://kubernetes.default.svc.cluster.local",
       "kubernetes.io/serviceaccount/namespace": "sa-lab",
       "kubernetes.io/serviceaccount/service-account.name": "pod-reader-sa",
       "sub": "system:serviceaccount:sa-lab:pod-reader-sa"
   }
   ```

4. Confirm the control plane tracks legacy-token usage so you can find stale ones. After the token is used at least once, the SA-token Secret gets a `kubernetes.io/legacy-token-last-used` label on a tracking object; more directly, audit for these Secrets cluster-wide:

   ```bash
   kubectl get secrets --all-namespaces \
     --field-selector type=kubernetes.io/service-account-token
   ```

   Expected:

   ```
   NAMESPACE   NAME                       TYPE                                  DATA   AGE
   sa-lab      pod-reader-legacy-token    kubernetes.io/service-account-token   3      1m
   ```

5. Clean up the legacy token immediately — it is exactly the kind of durable credential you want to eliminate:

   ```bash
   kubectl -n sa-lab delete secret pod-reader-legacy-token
   ```

> **Comprehension check 4**
> 1. Name three properties of a `kubectl create token` (TokenRequest) credential that a legacy Secret token lacks.
> 2. The bound token in step 2 has `"aud": ["vault.internal"]`. If a Pod presents that token to the *kube-apiserver* (default audience `https://kubernetes.default.svc...`), what happens, and why is audience binding a defense against token replay?
> 3. Legacy Secret tokens have no `exp`. What operational and security problems does that create, and what is the modern replacement for the workflow that used to depend on them (e.g. an external CI system authenticating to the cluster)?

---

## Exercise 5 — Audit the cluster for over-privileged and dangerous ServiceAccount bindings

**Goal:** find the SAs that a CKS scenario would flag: those bound to `cluster-admin`, those mounting tokens they don't need, and the `default` SA carrying real permissions.

1. List every ClusterRoleBinding whose subjects include a ServiceAccount, and surface any bound to `cluster-admin`:

   ```bash
   kubectl get clusterrolebindings -o json \
   | python3 - <<'PY'
   import json, subprocess
   data = json.loads(subprocess.check_output(
       ["kubectl", "get", "clusterrolebindings", "-o", "json"]))
   for crb in data["items"]:
       role = crb.get("roleRef", {}).get("name")
       for s in crb.get("subjects") or []:
           if s.get("kind") == "ServiceAccount":
               marker = "  <-- REVIEW" if role in ("cluster-admin", "admin", "edit") else ""
               print(f'{crb["metadata"]["name"]:40} role={role:20} '
                     f'sa={s.get("namespace")}/{s["name"]}{marker}')
   PY
   ```

   Expected (illustrative):

   ```
   system:kube-scheduler                   role=system:kube-scheduler sa=kube-system/kube-scheduler
   dangerous-binding                       role=cluster-admin        sa=sa-lab/pod-reader-sa  <-- REVIEW
   ```

2. Reproduce the flagged finding so you can practice remediating it. Grant the SA `cluster-admin` (the anti-pattern), verify, then revoke:

   ```bash
   kubectl create clusterrolebinding dangerous-binding \
     --clusterrole=cluster-admin \
     --serviceaccount=sa-lab:pod-reader-sa
   ```

   ```bash
   kubectl auth can-i '*' '*' --all-namespaces \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Expected:

   ```
   yes
   ```

3. Remediate by deleting the over-broad binding (leaving the narrow namespaced Role from Exercise 3 intact):

   ```bash
   kubectl delete clusterrolebinding dangerous-binding
   kubectl auth can-i '*' '*' --all-namespaces \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Expected:

   ```
   no
   ```

4. Harden the `default` SA in **every** namespace so a forgotten Pod never silently gets a token. This one-liner patches all `default` SAs:

   ```bash
   for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
     kubectl -n "$ns" patch serviceaccount default \
       -p '{"automountServiceAccountToken": false}' 2>/dev/null \
       && echo "patched default SA in $ns"
   done
   ```

   Expected (illustrative):

   ```
   patched default SA in default
   patched default SA in sa-lab
   patched default SA in kube-node-lease
   ...
   ```

5. Verify a specific SA's actual grants end-to-end by listing what it can do — the `--list` form enumerates every allowed verb/resource:

   ```bash
   kubectl -n sa-lab auth can-i --list \
     --as=system:serviceaccount:sa-lab:pod-reader-sa
   ```

   Expected (abridged):

   ```
   Resources   Non-Resource URLs   Resource Names   Verbs
   pods        []                  []               [get list watch]
   ...
   ```

6. Tear down the lab:

   ```bash
   kubectl delete namespace sa-lab
   ```

> **Comprehension check 5**
> 1. Binding a ServiceAccount to `cluster-admin` is dangerous even if the Pod "seems trusted." Describe the concrete blast radius if that Pod is compromised.
> 2. Why is patching the `default` ServiceAccount to `automountServiceAccountToken: false` a strong baseline control, and what is the one operational risk you must check for before rolling it out fleet-wide?
> 3. `kubectl auth can-i --list --as=...` is a powerful audit primitive. Why can it still *understate* an SA's real power in a cluster that also runs an admission or aggregated-API layer?

---

## Answers

<details>
<summary>Click to reveal answers to all comprehension checks</summary>

### Comprehension check 1
1. **The token was issued on demand by the TokenRequest API as a projected volume.** Since Kubernetes 1.24, SAs no longer get an auto-generated Secret (hence `SECRETS: 0`). Instead, the `kube-api-access-xxxxx` projected volume that the admission controller injects contains a `serviceAccountToken` source; the kubelet requests a fresh, short-lived, audience-bound token from the API server and refreshes it before expiry. The `ca.crt` and `namespace` come from a ConfigMap and the downward API in the same projected volume.
2. `system:serviceaccount:sa-lab:default` — the value of the `sub` claim, and the identity RBAC evaluates. The general form is `system:serviceaccount:<namespace>:<name>`, and every SA is also a member of the group `system:serviceaccounts` and `system:serviceaccounts:<namespace>`.
3. Any two of: **`exp`** — the token expires (bounded lifetime), so a stolen token is only useful for a short window rather than forever; **`aud`** (audience) — the token is only valid for the listed audience(s), so it can't be replayed against a different service that checks audience; **`kubernetes.io.pod`** (the bound object reference) — the token is tied to the Pod's UID and is invalidated when the Pod is deleted, so it can't outlive the workload. Legacy tokens have none of these bindings.

### Comprehension check 2
1. **The Pod-level `spec.automountServiceAccountToken` always wins when it is set.** If the field is present on the Pod, its value overrides the ServiceAccount's setting; if the Pod does not set it, the ServiceAccount's value applies; if neither sets it, the default is `true` (mount).
2. **Set `false` on the SA and re-enable only where needed.** This is the *fail-safe / secure-by-default* posture: a newly created or forgotten Pod inherits "no token," so a mistake fails *closed* (no credential exposed) rather than *open*. Requiring an explicit `automountServiceAccountToken: true` on the workloads that legitimately call the API server makes the API dependency visible and auditable.
3. **No — it does not revoke RBAC.** `automountServiceAccountToken` only controls whether a token is *mounted into the Pod's filesystem*. The ServiceAccount identity and every Role/ClusterRole bound to it still exist. A process that obtains a token another way (e.g. via the TokenRequest API, or a token deliberately passed in) would still wield those permissions. Not mounting the token reduces exposure; minimizing RBAC is what actually limits authority.

### Comprehension check 3
1. `kubectl auth can-i --as=...` asks the **live authorizer** (RBAC + any other enabled authorization modules), so it reflects the *effective* decision after combining every Role, ClusterRole, RoleBinding, ClusterRoleBinding, and group membership that applies to that SA. Reading a single Role YAML misses additive bindings (another RoleBinding could grant more), aggregation, and group-level grants — so eyeballing YAML routinely under- or over-estimates real access.
2. The empty string `""` denotes the **core (legacy) API group**, which contains `pods`, `services`, `secrets`, `configmaps`, `nodes`, etc. `apiGroups` expects an *API group name*, not a version. Writing `apiGroups: ["v1"]` matches a group literally named `v1` (which does not exist for `pods`), so the rule would **grant nothing** for pods and the SA's pod reads would be denied.
3. **Changing the `RoleBinding` to a `ClusterRoleBinding` (and the `Role` to a `ClusterRole`)** would grant pod-read across *all* namespaces. It's a common mistake because operators reach for `ClusterRole`/`ClusterRoleBinding` for convenience or copy an example, not realizing that a `ClusterRoleBinding` grants the role's verbs cluster-wide regardless of namespace. (Namespaced scope requires a `RoleBinding` — even when it references a `ClusterRole`, the binding confines the grant to its own namespace.)

### Comprehension check 4
1. Any three of: **bounded lifetime** (`exp` — auto-expires and is auto-rotated), **audience scoping** (`aud` — only valid for the intended recipient), **object binding** (can be tied to a Pod/Secret UID and invalidated when that object is deleted), **not stored at rest** (never persisted as a Secret in etcd; minted on demand). A legacy Secret token is a static, non-expiring, unscoped credential stored in etcd.
2. **The API server rejects it with `401 Unauthorized`.** The kube-apiserver only accepts tokens whose audience includes its own API server audience; a token minted for `vault.internal` is not valid for the API server. Audience binding defeats replay: a token captured by (or leaked to) one service cannot be turned around and used against a different service, because each verifier checks that its own identifier is in `aud`.
3. **No `exp` means the token never expires** — it stays valid until the SA/Secret is deleted, so a leaked legacy token is a permanent backdoor, rotation requires manual Secret deletion/recreation, and stale credentials accumulate invisibly. The modern replacement is the **TokenRequest API** (`kubectl create token`, or projected `serviceAccountToken` volumes) for in-cluster workloads, and short-lived tokens obtained on demand (with `--audience`/`--duration`) for external systems — ideally exchanged through an OIDC/identity federation flow rather than a stored static token.

### Comprehension check 5
1. `cluster-admin` grants `*` verbs on `*` resources in `*` namespaces, including `secrets` (all credentials), the ability to create Pods on any node, modify RBAC to persist access, read/alter every workload, and exec into any Pod. A single compromised container therefore becomes **full cluster takeover** — the attacker can dump every Secret, deploy privileged/hostPath Pods to break out to nodes, disable logging, and establish persistence. The blast radius is the entire cluster and every workload/tenant on it.
2. It enforces a **secure default**: any Pod that forgets to declare its API dependency simply never receives a token, so accidental credential exposure fails closed and the API-access surface shrinks to only the workloads that explicitly opt in. The operational risk to check first: **existing workloads that silently rely on the `default` SA token** (sidecars, operators, controllers, in-Pod `kubectl`, service-mesh agents) will break when the mount disappears — so audit for Pods using `default` and add an explicit SA + `automountServiceAccountToken: true` to the ones that genuinely need it before flipping the switch.
3. `auth can-i --list` reflects only the **authorization** decision for standard RBAC-evaluated resources. It can understate real power because: authority can be exercised **indirectly** (e.g. permission to create a Pod/Deployment lets the SA run a container as a *different, more privileged* SA — privilege escalation via workload creation); **aggregated API servers** and **custom/webhook authorizers** may grant access the RBAC listing doesn't enumerate; and permissions like `escalate`/`bind`, `impersonate`, or write access to admission/webhook configs let the SA expand its own rights. Effective power is about what the identity can *reach or become*, not just the verbs RBAC lists directly.

</details>