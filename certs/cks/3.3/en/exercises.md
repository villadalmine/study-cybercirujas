# Topic 3.3 — Restrict access to the Kubernetes API (CKS v1.34)

> **Lab environment assumption:** a `kubeadm`-provisioned cluster. The control-plane components run as **static pods**, so the `kube-apiserver` manifest lives at `/etc/kubernetes/manifests/kube-apiserver.yaml`. Editing that file makes the kubelet restart the API server automatically (watch for the container to be recreated). Run every step as `root` on the control-plane node unless noted.
>
> **Danger note:** a malformed `kube-apiserver.yaml` makes the API server fail to start and `kubectl` stops responding. Always `cp` a backup first and know how to recover by reading kubelet/container logs.

---

## Exercise 1 — Disable anonymous authentication

The API server treats any request that no authenticator accepts as the anonymous user `system:anonymous` in group `system:unauthenticated` **when `--anonymous-auth=true`**. On a hardened cluster you either disable it entirely or scope it to health endpoints only (Exercise 1b).

### Steps

1. Confirm the current setting on the running API server:

   ```bash
   ps -ef | grep kube-apiserver | grep -o 'anonymous-auth=[a-z]*'
   ```

   If it prints nothing, the flag is unset — and the **default is `true`**.

2. Probe anonymous access from *outside* any kubeconfig context. Use the API server's advertised address:

   ```bash
   APISERVER=https://$(kubectl -n default get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):6443
   curl -k $APISERVER/api/v1/namespaces/default/pods
   ```

   Expected (anonymous auth on, but RBAC denies) — HTTP 403, note the username:

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\" ...",
     "reason": "Forbidden",
     "code": 403
   }
   ```

3. Back up and edit the manifest:

   ```bash
   cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
   ```

   Add (or change) the flag under `spec.containers[0].command`:

   ```yaml
       - --anonymous-auth=false
   ```

4. Wait for the API server pod to be recreated, then re-probe:

   ```bash
   crictl ps | grep kube-apiserver          # watch for a fresh container / new age
   curl -k $APISERVER/api/v1/namespaces/default/pods
   ```

   Expected now — HTTP 401 (rejected before authorization even runs):

   ```json
   {
     "kind": "Status",
     "status": "Failure",
     "message": "Unauthorized",
     "reason": "Unauthorized",
     "code": 401
   }
   ```

> ❓ **Check your understanding**
> 1. In step 2 the response was `403 Forbidden`, but in step 4 it became `401 Unauthorized`. What changed in the request-processing pipeline, and which stage produced each code?
> 2. Why is disabling anonymous auth *not sufficient* on its own to say "the API is locked down"? What still governs what an authenticated identity can do?
> 3. A teammate says `--anonymous-auth=false` broke their external load-balancer health check hitting `/healthz`. Why, and what is the modern fix that avoids re-enabling blanket anonymous access?

---

## Exercise 1b — Scope anonymous access to health endpoints only (`AnonymousAuthConfigurableEndpoints`)

Since v1.32 the `AnonymousAuthConfigurableEndpoints` feature (enabled by default in v1.34) lets you keep anonymous access **only** for specific unauthenticated paths (`/healthz`, `/livez`, `/readyz`) while everything else returns 401. This is the production-correct answer to the "health probe broke" problem.

### Steps

1. Create an `AuthenticationConfiguration` file on the control-plane node, e.g. `/etc/kubernetes/authn/anon.yaml`:

   ```yaml
   apiVersion: apiserver.config.k8s.io/v1beta1
   kind: AuthenticationConfiguration
   anonymous:
     enabled: true
     conditions:
     - path: /livez
     - path: /readyz
     - path: /healthz
   ```

2. Reference it from the API server manifest and **remove** the `--anonymous-auth` flag (the two are mutually exclusive; setting both makes the API server refuse to start):

   ```yaml
       - --authentication-config=/etc/kubernetes/authn/anon.yaml
   ```

3. Ensure the file is mounted into the static pod. Add a `hostPath` volume + `volumeMount` (static pods do not see host files otherwise):

   ```yaml
       volumeMounts:
       - name: authn-config
         mountPath: /etc/kubernetes/authn
         readOnly: true
   ...
     volumes:
     - name: authn-config
       hostPath:
         path: /etc/kubernetes/authn
         type: DirectoryOrCreate
   ```

4. Verify the scoping after the API server restarts:

   ```bash
   curl -k $APISERVER/healthz        # expect: ok
   curl -k $APISERVER/api/v1/nodes   # expect: 401 Unauthorized
   ```

> ❓ **Check your understanding**
> 1. What happens at API server startup if you specify **both** `--anonymous-auth=true` and `--authentication-config` with an `anonymous` block?
> 2. Why does the `AuthenticationConfiguration` file need a `hostPath` volume mount, whereas the `--anonymous-auth` flag did not need anything mounted?

---

## Exercise 2 — Verify there is no insecure serving port

Historically the API server exposed an unauthenticated `--insecure-port` (default 8080). This flag was **removed entirely in v1.20**; on v1.34 there is nothing to disable, but you must be able to *prove* the API server serves only over TLS on 6443.

### Steps

1. Confirm no insecure/localhost plaintext listener exists:

   ```bash
   ps -ef | grep kube-apiserver | grep -oE 'insecure-port=[0-9]+' || echo "no insecure-port flag (expected on v1.20+)"
   ```

2. Confirm the only listener is the secure port and that plaintext is refused:

   ```bash
   ss -tlnp | grep kube-apiserver          # expect :6443 only
   curl http://127.0.0.1:8080/api          # expect: connection refused
   ```

3. Confirm the secure port requires a client credential:

   ```bash
   curl -k $APISERVER/api/v1/nodes          # 401 (no creds) — not a plaintext 200
   ```

> ❓ **Check your understanding**
> 1. On a v1.34 cluster, if `ps` shows no `--insecure-port`, is the insecure port disabled or absent — and does the distinction matter for the exam answer?
> 2. Before v1.20, why was `--insecure-port=8080` considered a critical bypass even with RBAC enabled? (Hint: which pipeline stages did the insecure port skip?)

---

## Exercise 3 — Least-privilege RBAC: a namespaced read-only Role

Authentication only proves *who* you are; **RBAC** decides *what* you may do. Here you build a minimal `Role` that grants read-only access to pods in one namespace and nothing else, then prove the boundaries.

### Steps

1. Create the namespace and a ServiceAccount that will act as the identity:

   ```bash
   kubectl create namespace team-a
   kubectl -n team-a create serviceaccount viewer
   ```

2. Author a tightly-scoped `Role` (verbs limited to read verbs; resources limited to pods and their logs):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: team-a
     name: pod-reader
   rules:
   - apiGroups: [""]
     resources: ["pods", "pods/log"]
     verbs: ["get", "list", "watch"]
   ```

   ```bash
   kubectl apply -f pod-reader-role.yaml
   ```

3. Bind the Role to the ServiceAccount with a `RoleBinding` (namespaced — grants apply only inside `team-a`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     namespace: team-a
     name: viewer-can-read-pods
   subjects:
   - kind: ServiceAccount
     name: viewer
     namespace: team-a
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   kubectl apply -f viewer-binding.yaml
   ```

4. Test the exact boundaries with `kubectl auth can-i --as=<serviceaccount>`:

   ```bash
   kubectl -n team-a auth can-i list pods   --as=system:serviceaccount:team-a:viewer   # yes
   kubectl -n team-a auth can-i delete pods --as=system:serviceaccount:team-a:viewer   # no
   kubectl -n team-b auth can-i list pods   --as=system:serviceaccount:team-a:viewer   # no
   kubectl -n team-a auth can-i get secrets --as=system:serviceaccount:team-a:viewer   # no
   ```

5. Enumerate *everything* the identity can do — the fastest way to spot over-grants:

   ```bash
   kubectl -n team-a auth can-i --list --as=system:serviceaccount:team-a:viewer
   ```

   Expected (trimmed):

   ```
   Resources    Non-Resource URLs   Resource Names   Verbs
   pods         []                  []               [get list watch]
   pods/log     []                  []               [get list watch]
   ...
   ```

> ❓ **Check your understanding**
> 1. The `RoleBinding` lives in `team-a`. If you wanted `viewer` to read pods in *every* namespace with a single grant, which two objects would you use instead, and which one is namespaced vs cluster-scoped?
> 2. Why did `auth can-i list pods` in `team-b` return `no`, even though the `pod-reader` Role's rules never mention namespaces?
> 3. The full subject string is `system:serviceaccount:team-a:viewer`. Decode each colon-separated segment. What group is this SA automatically a member of?

---

## Exercise 4 — Node authorization + NodeRestriction admission

Kubelets authenticate as `system:node:<nodeName>` in group `system:nodes`. Two mechanisms confine them: the **Node authorizer** (an authz mode that grants kubelets only the API reads/writes they need) and the **NodeRestriction admission plugin** (stops a compromised kubelet from editing *other* nodes' objects or labelling itself into restricted scheduling).

### Steps

1. Confirm both are active on the API server:

   ```bash
   ps -ef | grep kube-apiserver | grep -oE 'authorization-mode=[^ ]+'
   ps -ef | grep kube-apiserver | grep -oE 'enable-admission-plugins=[^ ]+'
   ```

   Expected to contain:

   ```
   authorization-mode=Node,RBAC
   enable-admission-plugins=NodeRestriction
   ```

   If missing, edit `/etc/kubernetes/manifests/kube-apiserver.yaml`:

   ```yaml
       - --authorization-mode=Node,RBAC
       - --enable-admission-plugins=NodeRestriction
   ```

   > Order matters: `Node` must precede `RBAC`; authorizers are consulted left-to-right and the first "allow" wins.

2. Impersonate a kubelet identity and confirm the Node authorizer scopes it. A node may read *its own* Node object but must not list all secrets:

   ```bash
   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl auth can-i get  nodes/$NODE --as=system:node:$NODE --as-group=system:nodes   # yes
   kubectl auth can-i list secrets     --as=system:node:$NODE --as-group=system:nodes   # no
   ```

3. Demonstrate what **NodeRestriction** blocks — a kubelet mutating a *different* node. Simulate node `nodeA` trying to label `nodeB`:

   ```bash
   kubectl label node otherNode color=red \
     --as=system:node:nodeA --as-group=system:nodes
   ```

   Expected — admission (not RBAC) rejects it:

   ```
   Error from server (Forbidden): nodes "otherNode" is forbidden:
   node "nodeA" is not allowed to modify node "otherNode"
   ```

4. Show NodeRestriction also blocks a kubelet from removing security-relevant labels on *itself* (e.g. `node-restriction.kubernetes.io/*`), which would otherwise let it dodge `nodeAffinity` isolation:

   ```bash
   kubectl label node nodeA node-restriction.kubernetes.io/tier- \
     --as=system:node:nodeA --as-group=system:nodes
   # Forbidden: is not allowed to modify labels: node-restriction.kubernetes.io/tier
   ```

> ❓ **Check your understanding**
> 1. The Node **authorizer** and the NodeRestriction **admission plugin** both constrain kubelets. Which pipeline stage does each run in, and why do you need *both* rather than one?
> 2. In `authorization-mode=Node,RBAC`, why must `Node` come first? What would break if a request is denied by `Node` but allowed by `RBAC`?
> 3. The `node-restriction.kubernetes.io/` label prefix is special. What attack does protecting it prevent when you use it in a pod's `nodeAffinity`?

---

## Exercise 5 — Stop mounting ServiceAccount tokens into pods that don't need them

Every pod that mounts a SA token holds a live API credential. A compromised container can replay it. Disable automounting where the workload never calls the API.

### Steps

1. Inspect a running pod — the token is mounted at a well-known path:

   ```bash
   kubectl run probe --image=nginx --restart=Never
   kubectl exec probe -- ls /var/run/secrets/kubernetes.io/serviceaccount
   # ca.crt  namespace  token
   ```

2. Turn off automount at the **ServiceAccount** level (applies to every pod using it, unless the pod overrides):

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: no-api
     namespace: default
   automountServiceAccountToken: false
   ```

3. Or override per-**pod** (takes precedence over the SA setting):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
   spec:
     serviceAccountName: no-api
     automountServiceAccountToken: false
     containers:
     - name: app
       image: nginx
   ```

4. Verify no token is present:

   ```bash
   kubectl exec hardened -- ls /var/run/secrets/kubernetes.io/serviceaccount
   # ls: cannot access ...: No such file or directory
   ```

5. Confirm the *default* SA in a namespace is not silently over-permissioned and prefer a purpose-built SA over `default`:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:default:default
   ```

> ❓ **Check your understanding**
> 1. If the ServiceAccount sets `automountServiceAccountToken: false` but the Pod sets `true`, which wins and why?
> 2. Turning off automounting removes the credential *file*. Does it change what that SA is *authorized* to do if a token were obtained another way? What is the complementary control?
> 3. Modern SA tokens mounted in pods are "bound" projected tokens rather than the old non-expiring Secret tokens. Name two properties that make bound tokens harder to abuse.

---

## Exercise 6 — Provision a human user via X.509 client cert and the CSR API, then scope it

Kubernetes has no user objects; a "user" is just a client certificate whose `CN`/`O` map to username/groups. You'll mint one through the built-in `CertificateSigningRequest` API and constrain it with RBAC.

### Steps

1. Generate a key and CSR. `CN` becomes the username, `O` becomes the group:

   ```bash
   openssl genrsa -out dev.key 2048
   openssl req -new -key dev.key -out dev.csr -subj "/CN=dev/O=developers"
   ```

2. Submit it as a Kubernetes `CertificateSigningRequest` with the kube-apiserver client signer:

   ```yaml
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: dev
   spec:
     request: <BASE64_OF_dev.csr>
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages:
     - client auth
   ```

   ```bash
   # produce the base64 (single line, no wrapping):
   cat dev.csr | base64 | tr -d '\n'
   kubectl apply -f dev-csr.yaml
   ```

3. Approve and extract the signed certificate:

   ```bash
   kubectl get csr                     # dev  ...  Pending
   kubectl certificate approve dev
   kubectl get csr dev -o jsonpath='{.status.certificate}' | base64 -d > dev.crt
   ```

4. Wire up a kubeconfig context for the new identity:

   ```bash
   kubectl config set-credentials dev --client-key=dev.key --client-certificate=dev.crt --embed-certs=true
   kubectl config set-context dev --cluster=kubernetes --user=dev
   ```

5. Grant it something scoped (reuse `pod-reader` pattern or a namespaced RoleBinding to the *user*, not a SA):

   ```bash
   kubectl -n team-a create rolebinding dev-read \
     --role=pod-reader --user=dev
   ```

6. Test under the new context:

   ```bash
   kubectl --context=dev -n team-a get pods    # works
   kubectl --context=dev -n team-a get secrets # Forbidden
   ```

> ❓ **Check your understanding**
> 1. Where in the cert did the *username* and *group* come from, and which RBAC subject `kind` do you bind to for an X.509 user (vs a workload)?
> 2. You set `expirationSeconds: 86400`. Why is a short-lived client cert preferable, and what is the operational cost? (Contrast with the fact that Kubernetes has **no built-in cert revocation list**.)
> 3. If you had signed the CSR with your own CA outside the cluster instead of the `kubernetes.io/kube-apiserver-client` signer, what must be true of `--client-ca-file` on the API server for the cert to authenticate?

---

## Exercise 7 — Restrict access to the kubelet API

The kubelet exposes its own API (port 10250). If it accepts anonymous requests or serves the deprecated read-only port (10255), an attacker on the node network can read pod data or exec into containers, bypassing the API server entirely.

### Steps

1. Inspect the kubelet config (kubeadm stores it at `/var/lib/kubelet/config.yaml`):

   ```bash
   grep -E 'anonymous|authorization|readOnlyPort|webhook' /var/lib/kubelet/config.yaml
   ```

   Hardened values:

   ```yaml
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
   authorization:
     mode: Webhook
   readOnlyPort: 0
   ```

2. Prove anonymous kubelet access is closed. From the node:

   ```bash
   curl -sk https://localhost:10250/pods          # expect: 401 Unauthorized
   curl -s  http://localhost:10255/pods           # expect: connection refused (read-only port off)
   ```

3. Prove authorized access still works using the API server's client cert (delegated Webhook authz to the API server):

   ```bash
   curl -sk https://localhost:10250/pods \
     --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
     --key  /etc/kubernetes/pki/apiserver-kubelet-client.key | head -c 200
   ```

4. Restart the kubelet after any change:

   ```bash
   systemctl restart kubelet && systemctl status kubelet --no-pager
   ```

> ❓ **Check your understanding**
> 1. With `authorization.mode: Webhook`, *who* actually decides whether a kubelet API request is allowed, and how does that tie kubelet access back into the cluster's RBAC?
> 2. Why is `readOnlyPort: 10255` dangerous even though it is "read only"? Name one piece of data it leaks.
> 3. A pod on the node runs with `hostNetwork: true` and reaches `https://localhost:10250`. What now stands between it and a container `exec` on that node?

---

## Exercise 8 — Diagnose "who can do what" across the cluster

Restricting access is only credible if you can audit it. Master the RBAC introspection verbs.

### Steps

1. Ask about *yourself* and about arbitrary subjects:

   ```bash
   kubectl auth can-i create deployments -n team-a
   kubectl auth can-i '*' '*' --as=system:serviceaccount:kube-system:namespace-controller
   ```

2. List the effective permission set for any identity (single best triage command):

   ```bash
   kubectl auth can-i --list --as=dev -n team-a
   ```

3. Find *every* binding that references a subject or role — spot the over-grant:

   ```bash
   kubectl get clusterrolebindings,rolebindings -A -o wide | grep -i cluster-admin
   ```

4. Inspect what a dangerous built-in ClusterRole actually allows before you ever bind it:

   ```bash
   kubectl describe clusterrole cluster-admin
   # PolicyRule:  *.*  []  [*]     -> full access, wildcard everything
   ```

5. Confirm a specific secret is *not* readable by a low-privilege SA (defense-in-depth check after Exercise 5):

   ```bash
   kubectl auth can-i get secret/db-password -n team-a \
     --as=system:serviceaccount:team-a:viewer   # no
   ```

> ❓ **Check your understanding**
> 1. `kubectl auth can-i --list` returned a rule with `*.*` verbs `[*]` for an SA you thought was scoped. What one ClusterRoleBinding would you look for, and how do you find it fast?
> 2. Why is `auth can-i` a more reliable audit than reading Role YAML by hand? (Think about how multiple bindings combine.)
> 3. RBAC is purely additive with no `deny` rules. Given that, how do you actually *reduce* an over-permissioned identity's access?

---

## Recovery reference (if the API server won't come back)

```bash
# The kubelet keeps trying to run the static pod; read why it fails:
crictl ps -a | grep kube-apiserver
crictl logs <container-id>
journalctl -u kubelet -f
# Restore the known-good manifest:
cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Sources

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Authenticating (anonymous requests, X.509, `AuthenticationConfiguration`) — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- RBAC authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Node authorization — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Admission controllers (`NodeRestriction`) — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Managing ServiceAccounts & bound tokens — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- `kube-apiserver` flags reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/

---

<details>
<summary><strong>Answers — verify your understanding</strong></summary>

### Exercise 1
1. **Authentication vs authorization stages.** With `--anonymous-auth=true`, an unauthenticated request is *accepted* by the anonymous authenticator as `system:anonymous`, passes authentication, and is then rejected by **authorization (RBAC)** → `403 Forbidden` ("User system:anonymous cannot..."). With `--anonymous-auth=false`, there is no authenticator that accepts the request, so it fails at the **authentication** stage before authorization runs → `401 Unauthorized`. A `403` means "I know who you are, you're not allowed"; a `401` means "I don't know who you are."
2. Disabling anonymous only removes one *identity*. Everything an *authenticated* identity may do is still governed by **RBAC (authorization)** plus **admission control**. A leaked token or over-broad RoleBinding is unaffected by the anonymous setting. AuthN and AuthZ are independent layers.
3. `/healthz`, `/livez`, `/readyz` were being served to `system:anonymous`; turning anonymous fully off returns 401 to unauthenticated probes. The modern fix is **`AnonymousAuthConfigurableEndpoints`** (Exercise 1b): an `AuthenticationConfiguration` that enables anonymous access **only** for those health paths, keeping 401 everywhere else — instead of re-enabling blanket anonymous auth or giving the LB a real credential.

### Exercise 1b
1. The API server **refuses to start**. `--anonymous-auth` and the `anonymous` block in `--authentication-config` are mutually exclusive; you must pick one mechanism. (This shows up as a crash-looping kube-apiserver static pod — check `crictl logs`.)
2. Static pods only see files that are explicitly mounted from the host. A command-line *flag* is baked into the pod spec and needs no filesystem access, but a *config file* referenced by `--authentication-config` must be made visible inside the container via a `hostPath` volume + `volumeMount`, or the API server reports "no such file."

### Exercise 2
1. On v1.34 the flag is **absent** — the insecure port was removed in v1.20, so there is no port to "disable." For the exam, the correct action is to *verify* TLS-only serving on 6443 (no plaintext listener, 401 without creds), not to add `--insecure-port=0` (which is now an unknown flag and would fail to start on some versions). Know that "removed" ≠ "set to 0."
2. The insecure port bypassed **both authentication and authorization** — requests to `localhost:8080` were treated as fully privileged with no credentials and no RBAC evaluation. Anyone with local (or misconfigured network) access to that port had de-facto `cluster-admin`, regardless of how tight RBAC was.

### Exercise 3
1. A **ClusterRole** (cluster-scoped, defines the read-pods permission once) bound with a **ClusterRoleBinding** (cluster-scoped, applies the grant in every namespace). Role/RoleBinding are namespaced; ClusterRole/ClusterRoleBinding are cluster-scoped.
2. Because the **RoleBinding** is namespaced — it exists only in `team-a`, so the grant only takes effect there. The Role's rules describe *what* actions; the binding's namespace describes *where*. No binding in `team-b` = no access in `team-b`.
3. `system` (built-in prefix) : `serviceaccount` (subject type) : `team-a` (namespace) : `viewer` (SA name). Every SA is automatically in the group `system:serviceaccounts` and in `system:serviceaccounts:<namespace>` (here `system:serviceaccounts:team-a`).

### Exercise 4
1. The **Node authorizer** runs in the *authorization* stage and decides whether a kubelet identity may perform an API action at all (e.g. read the secrets/configmaps of pods scheduled to it). **NodeRestriction** runs in the *admission* stage and limits *which objects* a kubelet may mutate (only its own Node and pods bound to it). You need both because authorization grants a *class* of action while admission enforces the *object-level* "own node only" constraint that authorization can't express.
2. Authorizers are evaluated **left-to-right and the first explicit allow wins**; there is no deny that stops later authorizers. `Node` first lets kubelet-specific requests be granted by the purpose-built Node authorizer; if a request isn't a Node case it falls through to `RBAC`. A request "denied by Node" is not final — RBAC can still allow it, so ordering is about giving each authorizer its turn, not about Node vetoing RBAC.
3. It prevents a **compromised kubelet from relabeling its own node to defeat workload isolation.** If you isolate sensitive pods with `nodeAffinity` on a `node-restriction.kubernetes.io/*` label, NodeRestriction forbids the kubelet from adding/removing that label prefix — so a hijacked node can't relabel itself to attract (or shed) restricted workloads.

### Exercise 5
1. The **Pod-level setting wins** (`true`) — the more specific pod spec overrides the ServiceAccount default. Precedence flows SA → Pod, most-specific last.
2. No. Removing the mount only removes the *credential file* from the container; it does **not** change what that SA is *authorized* to do. The complementary control is **RBAC** — scope the SA's Role/ClusterRole to least privilege so that even a stolen token is nearly useless. Automount-off and least-privilege RBAC are defense-in-depth, not substitutes.
3. Bound projected tokens are (a) **time-limited / auto-rotated** (they expire and are refreshed, unlike legacy non-expiring Secret tokens), and (b) **audience- and object-bound** (scoped to a specific `audience` and tied to the pod's lifetime, so they're invalid outside that context and after the pod is gone). They are also not stored as a readable Secret object.

### Exercise 6
1. The **`CN` (`dev`)** became the username and **`O` (`developers`)** became a group; the API server derives identity from the client cert's subject. For an X.509 user you bind to RBAC subject `kind: User` (and `kind: Group` for the `O`), whereas a workload uses `kind: ServiceAccount`.
2. Short-lived certs limit the blast radius of a leaked key — because **Kubernetes has no CRL/revocation**, a long-lived signed cert is valid until it expires, full stop. The cost is operational: the user must re-request/re-sign frequently (or automate it). Expiry is your *only* revocation mechanism for client certs, so keep it short.
3. The signing CA's certificate must be included in the bundle referenced by the API server's **`--client-ca-file`**. The API server trusts a client cert only if it chains to a CA in that file; a cert signed by an unknown CA authenticates as nobody (401).

### Exercise 7
1. With `authorization.mode: Webhook`, the kubelet **delegates the authorization decision to the API server** (SubjectAccessReview). Access to kubelet endpoints is therefore governed by cluster **RBAC** on the `nodes/*` subresources (e.g. `nodes/proxy`, `nodes/log`), so a caller needs an identity the API server can authorize — not just network reachability.
2. The read-only port `10255` serves cluster metadata **without any authentication** — anyone who can reach it gets pod specs, running container details, and environment/config information (which can leak service topology and, in bad setups, secrets referenced in specs). No creds required is the danger, not the "read-only" part.
3. **Kubelet authentication + Webhook authorization.** Even from `hostNetwork` on `localhost:10250`, anonymous auth is off (401 without a credential) and any authenticated request is checked via SubjectAccessReview against RBAC — so the pod needs an identity with `nodes/proxy` `create` (exec) rights, which a normal workload SA does not have.

### Exercise 8
1. Look for a **ClusterRoleBinding to `cluster-admin`** (or another wildcard ClusterRole) that lists your SA as a subject. Find it fast with `kubectl get clusterrolebindings -o wide | grep <sa-name>` or `... | grep cluster-admin`, then `kubectl describe` the offender.
2. Because an identity's effective permissions are the **union of every Role/ClusterRole granted through every Role/ClusterRoleBinding** (plus group memberships). Reading one Role's YAML misses grants coming from other bindings or from group-based ClusterRoleBindings. `auth can-i` evaluates the *combined* result the way the API server actually would.
3. RBAC has **no deny rules** and is purely additive, so you cannot "subtract" a permission. You reduce access by **removing or editing the binding/role that grants it** — delete the over-broad RoleBinding/ClusterRoleBinding, or replace the bound Role with a narrower one. There is nothing to add; you take a grant away.

</details>