# Exercises — Topic 2.4: Kubernetes Security Essentials and Hardening

> **Scope.** These guided labs cover the four hardening pillars the CNPA blueprint groups under this topic: workload isolation via **Pod Security Admission**, least-privilege **RBAC**, workload-level **SecurityContext / seccomp / capabilities**, and **NetworkPolicy** default-deny. Each exercise is self-contained. Run them against a throwaway cluster — `kind create cluster` or `minikube start` with a CNI that enforces NetworkPolicy (Cilium or Calico; the default kindnet does **not** enforce it, which Exercise 4 makes you prove).
>
> **Convention.** Prompts prefixed `$` are your shell. Everything is done in a scratch namespace so cleanup is `kubectl delete ns <name>`.

Primary sources, cited once here and referenced by short name throughout:

- **[PSS]** Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- **[PSA]** Enforce Pod Security Standards with the built-in admission controller — https://kubernetes.io/docs/tutorials/security/cluster-level-pss/
- **[RBAC]** Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- **[SC]** Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- **[SECCOMP]** Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- **[NP]** Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **[SA]** Configure Service Accounts for Pods — https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/

---

## Exercise 1 — Enforce Pod Security Standards at the namespace boundary

**Goal.** Turn a namespace into a `restricted`-tier enclave using the built-in **Pod Security Admission** controller, observe the difference between `warn`/`audit` and `enforce`, and understand why the three modes exist.

Since Kubernetes 1.25 the PodSecurityPolicy object is gone; enforcement is a **built-in admission plugin** driven entirely by three labels on the Namespace object. There is no CRD, no controller to install. [PSA]

1. Create a namespace and label it so that the `restricted` profile is **enforced**, while also warning and auditing against the same profile. Pinning `*-version` makes the rule set deterministic across cluster upgrades.

   ```bash
   $ kubectl create namespace secure-shop

   $ kubectl label namespace secure-shop \
       pod-security.kubernetes.io/enforce=restricted \
       pod-security.kubernetes.io/enforce-version=v1.31 \
       pod-security.kubernetes.io/warn=restricted \
       pod-security.kubernetes.io/warn-version=v1.31 \
       pod-security.kubernetes.io/audit=restricted \
       pod-security.kubernetes.io/audit-version=v1.31
   namespace/secure-shop labeled
   ```

2. Try to run a naïve Pod — the kind almost every tutorial ships. It sets nothing about users, capabilities or the root filesystem.

   ```bash
   $ kubectl -n secure-shop run naive --image=nginx:1.27
   ```

   Expected — the request is **rejected at admission time**, before any object is persisted:

   ```
   Error from server (Forbidden): pods "naive" is forbidden: violates PodSecurity "restricted:v1.31":
   allowPrivilegeEscalation != false (container "naive" must set securityContext.allowPrivilegeEscalation=false),
   unrestricted capabilities (container "naive" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "naive" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "naive" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

3. Now author a Pod that actually satisfies the `restricted` tier. Note the **four required knobs** the error above named, and that `runAsNonRoot` alone is not enough — the image must have a non-root default user or you must pin `runAsUser`.

   ```yaml
   # restricted-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: compliant
     namespace: secure-shop
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile:
         type: RuntimeDefault          # pod-level default for all containers
     containers:
       - name: app
         image: nginxinc/nginx-unprivileged:1.27   # listens on 8080, non-root by design
         ports:
           - containerPort: 8080
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   $ kubectl apply -f restricted-pod.yaml
   pod/compliant created

   $ kubectl -n secure-shop get pod compliant
   NAME        READY   STATUS    RESTARTS   AGE
   compliant   1/1     Running   0          8s
   ```

4. Demonstrate the difference between `enforce` and `warn`. Relax the namespace so it only **warns** at `restricted` but **enforces** the weaker `baseline`, then re-apply the naïve Pod.

   ```bash
   $ kubectl label --overwrite namespace secure-shop \
       pod-security.kubernetes.io/enforce=baseline

   $ kubectl -n secure-shop run naive --image=nginx:1.27
   Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false, ...
   pod/naive created
   ```

**Comprehension check — Exercise 1**

1. PSA is enforced by labels on the *Namespace*, not by a cluster-wide object. What is the security consequence of that design for a multi-tenant cluster, and who must be prevented from editing those labels?
2. In step 4 the naïve Pod was *created* but a warning was printed. Which of the three modes (`enforce`, `warn`, `audit`) blocks admission, and where does each of the other two surface its output?
3. Why does the `restricted` error insist on `seccompProfile.type: RuntimeDefault`? What is the default seccomp posture of a container that omits it entirely?
4. The compliant Pod sets both `runAsNonRoot: true` and `runAsUser: 10001`. If you kept `runAsNonRoot: true` but removed `runAsUser` and used a stock `nginx` image, what happens at runtime and why?

---

## Exercise 2 — RBAC least privilege: scope a ServiceAccount to exactly what it needs

**Goal.** Replace an over-permissioned workload identity with a Role that grants the minimum verbs on the minimum resources, and prove the boundary with `kubectl auth can-i --as`.

The default ServiceAccount a Pod receives can talk to the API server with whatever that SA is bound to — frequently nothing, sometimes far too much if someone bound `cluster-admin` "to make it work". RBAC is **additive and deny-by-default**: there is no deny rule, so you grant, never revoke. [RBAC]

1. Create a namespace, a dedicated ServiceAccount, and a workload that will read ConfigMaps through the API.

   ```bash
   $ kubectl create namespace billing
   $ kubectl -n billing create serviceaccount reporter
   ```

2. Before granting anything, prove the SA is powerless. `auth can-i --as=system:serviceaccount:<ns>:<name>` impersonates the identity and asks the authorizer directly — no Pod required.

   ```bash
   $ kubectl -n billing auth can-i list configmaps \
       --as=system:serviceaccount:billing:reporter
   no
   ```

3. Author a **Role** (namespaced) granting only `get`, `list`, `watch` on `configmaps` — no `create`, `update`, `delete`, no other resource. Bind it to the SA with a **RoleBinding**.

   ```yaml
   # reporter-rbac.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: configmap-reader
     namespace: billing
   rules:
     - apiGroups: [""]           # "" is the core group; ConfigMaps live there
       resources: ["configmaps"]
       verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: reporter-reads-configmaps
     namespace: billing
   subjects:
     - kind: ServiceAccount
       name: reporter
       namespace: billing
   roleRef:
     kind: Role
     name: configmap-reader
     apiGroup: rbac.authorization.k8s.io
   ```

   ```bash
   $ kubectl apply -f reporter-rbac.yaml
   role.rbac.authorization.k8s.io/configmap-reader created
   rolebinding.rbac.authorization.k8s.io/reporter-reads-configmaps created
   ```

4. Re-check the boundary. The granted verb passes; a verb you did **not** grant, and a resource you did **not** name, both fail.

   ```bash
   $ kubectl -n billing auth can-i list configmaps  --as=system:serviceaccount:billing:reporter
   yes
   $ kubectl -n billing auth can-i delete configmaps --as=system:serviceaccount:billing:reporter
   no
   $ kubectl -n billing auth can-i list secrets      --as=system:serviceaccount:billing:reporter
   no
   ```

5. Prove the namespace boundary. A **Role**+**RoleBinding** is confined to its namespace; the same identity has no rights next door.

   ```bash
   $ kubectl create namespace billing-staging
   $ kubectl -n billing-staging auth can-i list configmaps \
       --as=system:serviceaccount:billing:reporter
   no
   ```

**Comprehension check — Exercise 2**

1. You need the `reporter` identity to read ConfigMaps in **every** namespace. Which two object kinds do you use, and which one from the pair in step 3 do you *keep*? Sketch the change.
2. A colleague "fixes" a broken Deployment by running `kubectl create clusterrolebinding fix --clusterrole=cluster-admin --serviceaccount=billing:reporter`. State precisely what that identity can now do, and why RBAC gives you no `deny` rule to claw it back — what must you do instead?
3. `auth can-i --as=...` returned `yes`/`no` without ever scheduling a Pod. What component is actually answering, and why is impersonation the correct tool for auditing RBAC?
4. The Role names `apiGroups: [""]`. What resource would you be unable to reach if a workload needed `deployments`, and how does the group string differ for it?

---

## Exercise 3 — Harden a workload with SecurityContext, dropped capabilities, and seccomp

**Goal.** Take a container from "root with the full ambient capability set" to "unprivileged, read-only, minimal syscalls", and verify each control from *inside* the running container rather than trusting the manifest.

By default a Linux container process runs as **UID 0** inside its namespace and is granted a **default capability set** (~14 caps including `CAP_NET_RAW`, `CAP_CHOWN`, `CAP_SETUID`). Hardening means dropping all of them and adding back only what the app proves it needs. [SC][SECCOMP]

1. Deploy the **before** state and inspect it from inside. This is the baseline attackers count on.

   ```bash
   $ kubectl create namespace hardening
   $ kubectl -n hardening run before --image=busybox:1.36 --restart=Never -- sleep 3600

   $ kubectl -n hardening exec before -- id
   uid=0(root) gid=0(root) groups=0(root)

   $ kubectl -n hardening exec before -- sh -c 'grep CapEff /proc/self/status'
   CapEff:  00000000a80425fb        # a fat effective capability set
   ```

2. Author the **after** Pod. Every hardening control is explicit; comments name what each buys you.

   ```yaml
   # hardened.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: after
     namespace: hardening
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 65532                  # "nonroot" UID in distroless
       runAsGroup: 65532
       fsGroup: 65532                    # owns any mounted volumes
       seccompProfile:
         type: RuntimeDefault            # kernel filters dangerous syscalls
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "3600"]
         securityContext:
           allowPrivilegeEscalation: false   # blocks setuid-binary privilege gain
           readOnlyRootFilesystem: true      # image layers become immutable at runtime
           capabilities:
             drop: ["ALL"]                   # start from zero...
             # add: ["NET_BIND_SERVICE"]     # ...and add back only what is proven needed
         volumeMounts:
           - name: scratch
             mountPath: /tmp               # writable path, since root FS is read-only
     volumes:
       - name: scratch
         emptyDir: {}
   ```

   ```bash
   $ kubectl apply -f hardened.yaml
   pod/after created
   ```

3. Verify each control from inside — do not trust the YAML, prove the kernel honoured it.

   ```bash
   $ kubectl -n hardening exec after -- id
   uid=65532 gid=65532 groups=65532

   $ kubectl -n hardening exec after -- sh -c 'grep CapEff /proc/self/status'
   CapEff:  0000000000000000        # empty — no capabilities at all

   $ kubectl -n hardening exec after -- sh -c 'echo x > /root/canary'
   sh: can't create /root/canary: Read-only file system
   command terminated with exit code 1

   $ kubectl -n hardening exec after -- sh -c 'echo x > /tmp/canary && echo ok'
   ok                                # the emptyDir mount is the one writable place
   ```

4. Show `allowPrivilegeEscalation: false` in action. The `no_new_privs` bit means even a setuid binary cannot raise privileges.

   ```bash
   $ kubectl -n hardening exec after -- sh -c 'grep NoNewPrivs /proc/self/status'
   NoNewPrivs:  1
   ```

**Comprehension check — Exercise 3**

1. `CapEff` went from `a80425fb` to `0000000000000000`. If this app were a web server that must bind to TCP **80**, which single capability would you add back, and what is the *better* alternative that needs no capability at all?
2. `readOnlyRootFilesystem: true` broke the write to `/root` but `/tmp` still worked. Explain the mechanism — why is one path writable and the other not — and what class of attack an immutable root filesystem defeats.
3. What is the difference between `runAsNonRoot: true` and `runAsUser: 65532`? If you set only the former with an image whose Dockerfile has no `USER` line, what happens, and at which phase (admission vs. runtime)?
4. `allowPrivilegeEscalation: false` sets `NoNewPrivs`. Concretely, which syscall/mechanism does this neutralise, and why does dropping all capabilities *not* already cover that case?

---

## Exercise 4 — Default-deny NetworkPolicy and selective allow

**Goal.** Prove the flat-network default (any Pod can reach any Pod), impose a **default-deny** ingress posture, then re-open exactly one path with a label selector — and confirm your CNI actually enforces it.

A Kubernetes cluster is **allow-all** by default at L3/L4: every Pod can open a connection to every other Pod, across namespaces. NetworkPolicy is namespaced, additive, and only takes effect if the CNI plugin implements it. [NP]

1. Deploy a target and two clients, then prove the open default.

   ```bash
   $ kubectl create namespace netlab
   $ kubectl -n netlab run web --image=nginxinc/nginx-unprivileged:1.27 --labels=app=web --port=8080
   $ kubectl -n netlab expose pod web --port=8080 --name=web

   $ kubectl -n netlab run client-a --image=busybox:1.36 --labels=role=frontend --restart=Never -- sleep 3600
   $ kubectl -n netlab run client-b --image=busybox:1.36 --labels=role=other    --restart=Never -- sleep 3600

   $ kubectl -n netlab exec client-a -- wget -qO- --timeout=3 http://web:8080 | head -1
   <!DOCTYPE html>
   $ kubectl -n netlab exec client-b -- wget -qO- --timeout=3 http://web:8080 | head -1
   <!DOCTYPE html>          # both reach it — no isolation yet
   ```

2. Apply a **default-deny ingress** policy. An empty `podSelector` selects *every* Pod in the namespace; naming `Ingress` in `policyTypes` with no `ingress` rules denies all inbound.

   ```yaml
   # default-deny-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: netlab
   spec:
     podSelector: {}          # applies to all pods in the namespace
     policyTypes:
       - Ingress              # deny all inbound; egress untouched
   ```

   ```bash
   $ kubectl apply -f default-deny-ingress.yaml
   networkpolicy.networking.k8s.io/default-deny-ingress created

   $ kubectl -n netlab exec client-a -- wget -qO- --timeout=3 http://web:8080 | head -1
   wget: download timed out
   command terminated with exit code 1     # now nothing reaches web
   ```

   > **CNI check.** If *both* clients still succeed here, your CNI does not enforce NetworkPolicy (kindnet is the usual culprit). Recreate the cluster with Calico or Cilium before continuing — the policy object exists but does nothing.

3. Re-open exactly one path: allow ingress to `app=web` on port 8080 **only** from Pods labelled `role=frontend`. Policies are additive, so this layers on top of the default-deny.

   ```yaml
   # allow-frontend.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-web
     namespace: netlab
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 role: frontend
         ports:
           - protocol: TCP
             port: 8080
   ```

   ```bash
   $ kubectl apply -f allow-frontend.yaml
   networkpolicy.networking.k8s.io/allow-frontend-to-web created

   $ kubectl -n netlab exec client-a -- wget -qO- --timeout=3 http://web:8080 | head -1
   <!DOCTYPE html>          # role=frontend is allowed
   $ kubectl -n netlab exec client-b -- wget -qO- --timeout=3 http://web:8080 | head -1
   wget: download timed out # role=other is still denied
   command terminated with exit code 1
   ```

**Comprehension check — Exercise 4**

1. Two policies now select the `web` Pod: `default-deny-ingress` and `allow-frontend-to-web`. NetworkPolicies have no `deny` and no priority — so how does the *combination* produce "only frontend may connect"? State the evaluation rule.
2. In step 3, a `podSelector` inside `from:` matches Pods **in the same namespace**. What single field would you add to also (or instead) allow traffic from another namespace, and what is the security trap of writing `from: [{namespaceSelector: {}}]` with an empty selector?
3. The default-deny policy left **egress** untouched. Why is egress default-deny often harder to roll out than ingress default-deny in a real cluster — name one thing that breaks immediately.
4. Your policy uses `port: 8080`. A teammate reports DNS resolution failing for Pods in this namespace after adding a default-deny **egress** policy. What port/protocol and destination must an egress allow rule name to fix it?

---

## Exercise 5 — Cut off the ambient ServiceAccount token

**Goal.** Stop every Pod from silently mounting a credential to the API server, and understand why the default is a lateral-movement gift.

By default the admission controller mounts the namespace's `default` ServiceAccount token into every Pod at `/var/run/secrets/kubernetes.io/serviceaccount/token`. If a workload is compromised and that SA has any rights, the attacker inherits them. Most workloads never call the API and should not carry a token at all. [SA]

1. Show the ambient token that a stock Pod carries.

   ```bash
   $ kubectl create namespace tokens
   $ kubectl -n tokens run has-token --image=busybox:1.36 --restart=Never -- sleep 3600

   $ kubectl -n tokens exec has-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/
   ca.crt
   namespace
   token                    # a live JWT for the default SA, mounted automatically
   ```

2. Opt the workload out at the **Pod** level with `automountServiceAccountToken: false`.

   ```yaml
   # no-token.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: no-token
     namespace: tokens
   spec:
     automountServiceAccountToken: false
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "3600"]
   ```

   ```bash
   $ kubectl apply -f no-token.yaml
   pod/no-token created

   $ kubectl -n tokens exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
   ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
   command terminated with exit code 1     # no credential to steal
   ```

3. For a fleet-wide default, set the flag on the **ServiceAccount** instead, so every Pod using it inherits the opt-out (a Pod-level setting still overrides it when a workload genuinely needs the API).

   ```bash
   $ kubectl -n tokens patch serviceaccount default \
       -p '{"automountServiceAccountToken": false}'
   serviceaccount/default patched
   ```

**Comprehension check — Exercise 5**

1. Two places can set `automountServiceAccountToken`: the ServiceAccount and the Pod. When they disagree, which wins, and why is that precedence the right default for a platform team setting a fleet-wide baseline?
2. A workload genuinely needs to `list pods` via the API. Describe the least-privilege setup end to end: which token it should carry (not the `default` SA), and which objects from Exercise 2 you would combine.
3. Since Kubernetes 1.24 the token at that mount path is a **bound, short-lived projected token**, not a never-expiring Secret. Name one attacker advantage that change removes.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

1. **Consequence & who to lock down.** Because the security tier is a *label on the Namespace*, whoever can edit the namespace can downgrade `enforce=restricted` to `privileged` and then run anything. In a multi-tenant cluster, tenants must **not** have `update`/`patch` on Namespace objects (nor `patch` on the labels). The tier is only as strong as the RBAC protecting the labels; a common pattern is to let a controller/GitOps process own namespace labels and deny tenants write access to them.
2. **Which mode blocks.** Only **`enforce`** rejects the admission request. **`warn`** returns a `Warning:` header to the API client (visible in `kubectl` output and client tooling) but still admits the object. **`audit`** writes an annotation to the **API server audit log** and is invisible to the user issuing the request. The usual rollout is `warn`+`audit` first to find violators, then flip `enforce`.
3. **Why RuntimeDefault.** The `restricted` tier requires an explicit seccomp profile so that syscalls the app never needs are filtered by the kernel, shrinking the attack surface for kernel-level escapes. A container that omits `seccompProfile` runs **`Unconfined`** — *no* syscall filtering — which is exactly what `restricted` forbids. `RuntimeDefault` uses the container runtime's curated default filter.
4. **runAsNonRoot without runAsUser on stock nginx.** Admission **passes** (the manifest asserts non-root), but at **runtime** the kubelet checks the image's effective UID; stock `nginx` defaults to UID 0, so the kubelet refuses to start the container with `CreateContainerConfigError` / "container has runAsNonRoot and image will run as root". `runAsNonRoot` is a runtime assertion, not a remapping — you still need an image with a non-root `USER` or an explicit `runAsUser`.

### Exercise 2

1. **Cluster-wide read.** Use a **ClusterRole** (identical rules) plus a **ClusterRoleBinding**. You keep the *Role's rule block* but promote both kinds to their cluster-scoped versions. A ClusterRole bound with a **RoleBinding** would still be namespace-limited; it's the **ClusterRoleBinding** that makes it apply in every namespace.
2. **cluster-admin binding.** The `reporter` SA can now do **anything on any resource in any namespace**, including reading all Secrets, creating Pods, and editing RBAC to persist itself. RBAC has **no deny rule** — permissions are purely additive — so you cannot "subtract" it. You must **delete the ClusterRoleBinding** (`kubectl delete clusterrolebinding fix`). Until that object is gone, the grant stands.
3. **Who answers can-i.** The **API server's authorization stack (the RBAC authorizer)** answers, using **impersonation** (`--as`) to evaluate the decision for another subject without acquiring its credentials. It's the correct audit tool because it asks the *same* code path that gates real requests — no Pod, token, or side effects.
4. **Empty group vs deployments.** `apiGroups: [""]` is the **core** group (Pods, Services, ConfigMaps, Secrets, Nodes…). `deployments` live in the **`apps`** group, so a Role granting only `[""]` cannot reach them; you'd need a rule with `apiGroups: ["apps"]`, `resources: ["deployments"]`.

### Exercise 3

1. **Bind to port 80.** Add back **`NET_BIND_SERVICE`** (the capability that permits binding to privileged ports < 1024). The **better** option is to not need it: run the server on an unprivileged port (e.g. 8080) and expose 80 via the Service — no capability, still non-root. Modern kernels also allow lowering `net.ipv4.ip_unprivileged_port_start`, but on the app side the port swap is cleanest.
2. **Read-only root vs /tmp.** `readOnlyRootFilesystem: true` mounts the container's root filesystem (the image layers) read-only, so writes to `/root` fail. `/tmp` works because it is a **separate `emptyDir` volume** mounted over that path — volume mounts are writable independent of the root FS setting. An immutable root defeats attacks that **drop or modify binaries/config at runtime** (webshells, tampering with `/etc`, persistence) — the payload has nowhere on the executable filesystem to land.
3. **runAsNonRoot vs runAsUser.** `runAsNonRoot: true` is a **boolean assertion** checked at container start: "refuse to run if the effective UID is 0." `runAsUser: 65532` **sets** the UID. With only `runAsNonRoot` and an image that has no `USER` line (defaults to 0), the container **fails to start at runtime** — the kubelet blocks it — because the assertion is violated. Admission (PSA aside) does not know the image's UID; the check happens at the **runtime** phase.
4. **What NoNewPrivs neutralises.** It sets the kernel `no_new_privs` bit, which makes `execve()` ignore **setuid/setgid bits and file capabilities** — a process can never gain more privileges than it already has by exec'ing a setuid binary (e.g. `sudo`, `ping`). Dropping capabilities removes what the process holds *now*, but without `no_new_privs` a setuid-root binary on the image could still escalate on `exec`; the two controls cover different moments (current set vs. exec-time gain).

### Exercise 4

1. **How the combination works.** A Pod is "isolated" for ingress the moment **any** NetworkPolicy selects it; from then on traffic is allowed **only** if **at least one** policy's `ingress` rule permits it — the effective result is the **union of all allow rules**, and everything else is denied. There is no deny object and no priority; `default-deny-ingress` contributes zero allow rules and `allow-frontend-to-web` contributes the single frontend rule, so the union = "frontend only."
2. **Cross-namespace + the trap.** Add a **`namespaceSelector`** inside the `from` block (optionally combined with `podSelector` in the same array element to require *both* namespace and Pod labels). The trap: `from: [{namespaceSelector: {}}]` with an **empty** selector matches **every namespace in the cluster**, silently re-opening the door you just closed to the entire cluster. Always label namespaces and select specifically.
3. **Egress default-deny is harder.** The instant you deny all egress, Pods can no longer reach **kube-dns/CoreDNS**, so **DNS resolution breaks** and nearly every outbound connection fails by name — plus access to the API server, cloud metadata, and external dependencies all need explicit allows. Ingress default-deny only affects who can reach *you*; egress default-deny affects everything *you* depend on, which is a much larger and easier-to-miss surface.
4. **DNS egress rule.** Allow egress to the **CoreDNS/kube-dns Pods** (typically by `namespaceSelector` on `kube-system` + a `podSelector` for `k8s-app: kube-dns`) on **UDP and TCP port 53**. DNS uses UDP/53 primarily and falls back to TCP/53, so both protocols must be permitted.

### Exercise 5

1. **Precedence.** The **Pod-level** `automountServiceAccountToken` wins when it is set; it overrides the ServiceAccount-level value. That's the right default for a platform baseline: set `false` on the ServiceAccount to make **no token** the fleet default, while still letting an individual workload that genuinely needs API access opt back in with `automountServiceAccountToken: true` on its own Pod spec — secure by default, explicit exception.
2. **Least-privilege API access.** (a) Create a **dedicated ServiceAccount** (never reuse `default`) and set it on the Pod via `serviceAccountName`. (b) Grant it a **Role** with `verbs: ["list"]` on `resources: ["pods"]` in the target namespace, bound with a **RoleBinding** (Exercise 2's pattern). (c) Leave `automountServiceAccountToken: true` (the default) **only for that Pod**. The token it then carries maps to an identity that can do *nothing but* list pods.
3. **What bound tokens remove.** The pre-1.24 model mounted a **non-expiring Secret** token: steal it once and it works forever, from anywhere, even after the Pod is gone. The projected token is **short-lived (auto-rotated), audience-scoped, and bound to the Pod's lifetime**, so a leaked token **expires quickly and is rejected for the wrong audience** — removing the "steal once, use forever" advantage.

</details>