# KCSA Domain 4.7: Privilege Escalation

## Official Reference Documentation
* [Kubernetes Security Context Documentation](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Kubernetes RBAC Privilege Escalation Prevention](https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping)
* [Linux Kernel prctl(2) Documentation - PR_SET_NO_NEW_PRIVS](https://man7.org/linux/man-pages/man2/prctl.2.html)
* [Linux Capabilities Manual - capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html)

---

## Architectural Deep Dive & Internal Mechanics

Privilege escalation in Kubernetes occurs at two primary vectors: **Node/Container Level** (Kernel process mechanics) and **Control Plane Level** (Kubernetes API and RBAC authorization).

```
                      +-------------------------------------------------------+
                      |               KUBERNETES API LAYER                    |
                      |                                                       |
                      |   [ User / SA ] --(Creates Pod/Binds Role)--> API     |
                      |                         |                             |
                      |              RBAC Admission Validation                |
                      |      Checks: 'bind', 'escalate', 'impersonate'        |
                      +-------------------------+-----------------------------+
                                                |
                                                v
                      +-------------------------------------------------------+
                      |            NODE / CONTAINER RUNTIME LAYER             |
                      |                                                       |
                      |               Kubelet -> OCI Runtime                  |
                      |                         |                             |
                      |              Translate SecurityContext                |
                      |                         |                             |
                      |                         v                             |
                      |           Linux Kernel Process Creation               |
                      |      +-----------------------------------------+      |
                      |      |  PR_SET_NO_NEW_PRIVS  (prctl)           |      |
                      |      |  Linux Capabilities   (CapEff/CapBnd)   |      |
                      |      |  Namespaces & Mounts  (hostPath/PID)    |      |
                      |      +-----------------------------------------+      |
                      +-------------------------------------------------------+
```

### 1. Node & Kernel-Level Privilege Escalation Mechanics
* **Setuid/Setgid & `PR_SET_NO_NEW_PRIVS`**: When a process executes a binary with the Set-User-ID (`SUID`) bit set (e.g., `/usr/bin/passwd` or `/bin/su`), the kernel ordinarily elevates the process's effective user ID (`eUID`) to the binary owner's ID (typically `root`).
  * In Kubernetes, setting `securityContext.allowPrivilegeEscalation: false` forces the container runtime (`containerd` or `CRI-O`) to issue the `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` system call before invoking `execve()` for the container entrypoint.
  * Once `PR_SET_NO_NEW_PRIVS` is set to `1`, it is inherited by all child processes and **cannot be cleared** (even by `root`). It guarantees that `execve()` will never grant privileges that were not already granted to the calling process, rendering `SUID`/`SGID` bits and file capability bits ineffective.

* **Linux Capabilities (`CapEff`, `CapBnd`, `CapInh`)**:
  * Containers run with a subset of Linux capabilities. Adding capabilities like `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, `CAP_NET_ADMIN`, or `CAP_DAC_OVERRIDE` bypasses DAC (Discretionary Access Control) checks.
  * If `privileged: true` is set, the container runtime disables security profiles (AppArmor, Seccomp), exposes all host `/sys` and `/dev` nodes, and grants all capabilities in the Linux kernel bounding set (`CapBnd`).

* **Host Namespace & Volume Exposure**:
  * `hostPID: true`, `hostIPC: true`, `hostNetwork: true`, or writable `hostPath` mounts allow processes inside a container to break out of namespace isolation and interact directly with host processes or the host filesystem (e.g., modifying `/etc/shadow`, `/etc/kubernetes/manifests`, or injecting code into host process memory via `ptrace`).

### 2. Control Plane & RBAC Privilege Escalation Mechanics
* **Role Binding Escalation**: An identity cannot create or update a `Role` or `ClusterRole` with permissions it does not already possess unless it explicitly holds the `escalate` verb on `roles` or `clusterroles` in the `rbac.authorization.k8s.io` API group.
* **Binding Verb**: To bind an existing `ClusterRole` to a subject, the identity must hold the `bind` verb on the target role/clusterrole or possess identical rule permissions.
* **Workload-Based Escalation**: A user who has `create` permissions on `pods`, `deployments`, or `daemonsets` within a namespace can create a workload mounting a high-privilege `ServiceAccount` token (or specifying `hostPath`/`privileged: true`), effectively inheriting `cluster-admin` rights or node root access.

---

## Hands-On Guided Exercises

### Exercise 1: Kernel Mechanics of `allowPrivilegeEscalation` & SUID Binaries

In this exercise, you will deploy pods to analyze how the Linux kernel handles SUID binary execution under different `securityContext` settings.

#### Step 1: Deploy a Pod with `allowPrivilegeEscalation: true`
Create a manifest named `pod-escalation-enabled.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: escalation-enabled-demo
  namespace: default
spec:
  containers:
  - name: security-test
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: true
      runAsUser: 1000
      runAsGroup: 1000
```

Apply the manifest and inspect the kernel process flags:

```bash
kubectl apply -f pod-escalation-enabled.yaml
```

*Expected Output:*
```text
pod/escalation-enabled-demo created
```

Wait for the pod to be running, then inspect `/proc/1/status` inside the container:

```bash
kubectl exec escalation-enabled-demo -- grep -i nonewprivs /proc/1/status
```

*Expected Output:*
```text
NoNewPrivs:	0
```

Now execute an SUID binary installed inside the image (`/usr/bin/passwd` or `/bin/su`):

```bash
kubectl exec escalation-enabled-demo -- ls -l /usr/bin/passwd
```

*Expected Output:*
```text
-rwsr-xr-x 1 root root 63968 Feb  7  2023 /usr/bin/passwd
```

#### Step 2: Deploy a Pod with `allowPrivilegeEscalation: false`
Create a manifest named `pod-escalation-disabled.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: escalation-disabled-demo
  namespace: default
spec:
  containers:
  - name: security-test
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsUser: 1000
      runAsGroup: 1000
```

Apply the manifest:

```bash
kubectl apply -f pod-escalation-disabled.yaml
```

*Expected Output:*
```text
pod/escalation-disabled-demo created
```

Check the process status for `NoNewPrivs`:

```bash
kubectl exec escalation-disabled-demo -- grep -i nonewprivs /proc/1/status
```

*Expected Output:*
```text
NoNewPrivs:	1
```

Test executing an SUID binary as an unprivileged user (UID 1000) when `NoNewPrivs` is active:

```bash
kubectl exec escalation-disabled-demo -- su -
```

*Expected Output:*
```text
su: Authentication failure
(or su: System error / Permission denied)
```

#### Comprehension Questions - Exercise 1
1. **Question 1.1**: What specific Linux kernel system call does the container runtime invoke when `allowPrivilegeEscalation: false` is configured in the pod manifest?
2. **Question 1.2**: If a container runs with `runAsUser: 0` (root), what functional impact does setting `allowPrivilegeEscalation: false` have on capabilities granted at execution?

---

### Exercise 2: Node Breakout via Capabilities and Host Mounts

In this exercise, you will simulate a high-severity privilege escalation scenario where excess Linux capabilities combined with host volume access allow container escape, and then mitigate it using Pod Security Standards.

#### Step 1: Deploy a Maliciously Over-Privileged Pod
Create a manifest named `vulnerable-host-access.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: host-breakout-demo
  namespace: default
spec:
  hostPID: true
  containers:
  - name: attacker-container
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      privileged: false
      capabilities:
        add:
        - SYS_ADMIN
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /
      type: Directory
```

Apply the manifest:

```bash
kubectl apply -f vulnerable-host-access.yaml
```

*Expected Output:*
```text
pod/host-breakout-demo created
```

Inspect the effective capabilities of PID 1 inside the container:

```bash
kubectl exec host-breakout-demo -- grep CapEff /proc/1/status
```

*Expected Output:*
```text
CapEff:	0000000000200000
```
*(Note: Bit 21 corresponding to `CAP_SYS_ADMIN` is enabled in the bitmask).*

Execute a chroot escape into the host system root filesystem:

```bash
kubectl exec -it host-breakout-demo -- chroot /host /bin/bash -c "hostname; cat /etc/os-release | grep PRETTY_NAME"
```

*Expected Output:*
```text
<node-hostname>
PRETTY_NAME="Ubuntu 22.04.3 LTS" (or host OS equivalent)
```

#### Step 2: Enforce Namespace-Level Security with Pod Security Standards (PSS)
Label the `default` namespace to enforce the `restricted` Pod Security Standard profile:

```bash
kubectl label --overwrite namespace default pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
```

*Expected Output:*
```text
namespace/default labeled
```

Attempt to re-apply the over-privileged workload:

```bash
kubectl delete pod host-breakout-demo --now
kubectl apply -f vulnerable-host-access.yaml
```

*Expected Output:*
```text
Error from server (Forbidden): error when creating "vulnerable-host-access.yaml": pods "host-breakout-demo" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), allowPrivilegeEscalation != false (container "attacker-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "attacker-container" must set securityContext.capabilities.drop=["ALL"]; container "attacker-container" adds restricted capability "SYS_ADMIN"), hostPath volumes (volume "host-root")
```

#### Step 3: Deploy a Fully Compliant Hardened Pod
Create a manifest named `hardened-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-workload
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: secure-app
    image: debian:bookworm-slim
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
```

Apply the compliant manifest:

```bash
kubectl apply -f hardened-pod.yaml
```

*Expected Output:*
```text
pod/hardened-workload created
```

Verify that effective capabilities are completely cleared (`0x0`):

```bash
kubectl exec hardened-workload -- grep CapEff /proc/1/status
```

*Expected Output:*
```text
CapEff:	0000000000000000
```

#### Comprehension Questions - Exercise 2
1. **Question 2.1**: Why is `CAP_SYS_ADMIN` considered equivalent to full host `root` access when combined with container volume mounts or unshare capabilities?
2. **Question 2.2**: In Pod Security Standards (PSS), what are the key differences between the `Baseline` profile and the `Restricted` profile regarding `allowPrivilegeEscalation` and Linux capabilities?

---

### Exercise 3: Control Plane RBAC Privilege Escalation Prevention

In this exercise, you will investigate how the API server prevents RBAC privilege escalation when a user attempts to grant permissions beyond their assigned authorization scope.

#### Step 1: Create a Restricted User Role and ServiceAccount
Create a manifest named `rbac-escalation-setup.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: junior-dev-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader-role
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles"]
  verbs: ["create", "update", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: junior-dev-binding
  namespace: default
subjects:
- kind: ServiceAccount
  name: junior-dev-sa
  namespace: default
roleRef:
  kind: Role
  name: pod-reader-role
  apiGroup: rbac.authorization.k8s.io
```

Apply the setup manifest:

```bash
kubectl apply -f rbac-escalation-setup.yaml
```

*Expected Output:*
```text
serviceaccount/junior-dev-sa created
role.rbac.authorization.k8s.io/pod-reader-role created
rolebinding.rbac.authorization.k8s.io/junior-dev-binding created
```

#### Step 2: Test Privilege Escalation via Role Creation (Impersonation)
Attempt to create an admin role while impersonating `junior-dev-sa` without holding the `escalate` verb:

```bash
kubectl apply --as=system:serviceaccount:default:junior-dev-sa -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: unauthorized-admin-role
  namespace: default
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
EOF
```

*Expected Output:*
```text
Error from server (Forbidden): roles.rbac.authorization.k8s.io "unauthorized-admin-role" is forbidden: user "system:serviceaccount:default:junior-dev-sa" cannot create resource "roles" in API group "rbac.authorization.k8s.io" in the namespace "default": covers has #2 elements outside the permission boundary
```

#### Step 3: Test Privilege Escalation via RoleBinding
Attempt to bind an existing high-privilege `ClusterRole` (such as `admin` or `cluster-admin`) to `junior-dev-sa` while impersonating `junior-dev-sa`:

```bash
kubectl apply --as=system:serviceaccount:default:junior-dev-sa -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: escalate-to-admin
  namespace: default
subjects:
- kind: ServiceAccount
  name: junior-dev-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

*Expected Output:*
```text
Error from server (Forbidden): rolebindings.rbac.authorization.k8s.io "escalate-to-admin" is forbidden: user "system:serviceaccount:default:junior-dev-sa" cannot bind clusterrole "admin" in the namespace "default"
```

#### Step 4: Validate Authorization Rules with `kubectl auth can-i`
Verify whether `junior-dev-sa` can perform the `escalate` or `bind` verbs:

```bash
kubectl auth can-i escalate roles --as=system:serviceaccount:default:junior-dev-sa -n default
```

*Expected Output:*
```text
no
```

```bash
kubectl auth can-i bind clusterroles/admin --as=system:serviceaccount:default:junior-dev-sa -n default
```

*Expected Output:*
```text
no
```

#### Comprehension Questions - Exercise 3
1. **Question 3.1**: What specific conditions must be met in RBAC for a user to update or create a `Role` that contains permissions the user does not currently hold?
2. **Question 3.2**: If a user has `create` permissions on `pods` and `serviceaccounts/token` in a namespace, how can they achieve indirect privilege escalation even if RBAC prevents them from creating `RoleBindings` directly?

---

## Diagnostic Commands Quick Reference

| Task | Diagnostic Command | Expected Output Indicator |
| :--- | :--- | :--- |
| Check Kernel `NoNewPrivs` | `kubectl exec <pod> -- grep -i nonewprivs /proc/1/status` | `NoNewPrivs: 1` (Secure) \| `0` (Insecure) |
| Check Effective Capabilities | `kubectl exec <pod> -- grep CapEff /proc/1/status` | `CapEff: 0000000000000000` (Dropped All) |
| Check `escalate` Verb Rights | `kubectl auth can-i escalate roles -n <namespace>` | `yes` or `no` |
| Check `bind` Verb Rights | `kubectl auth can-i bind clusterrole/<name>` | `yes` or `no` |
| Decode CapEff Hexadecimal | `capsh --decode=<CapEff_Hex_Value>` | List of capability names (e.g., `cap_sys_admin`) |

---

<details>
<summary><b>Click here to expand Answer Key & Detailed Explanations</b></summary>

### Exercise 1 Answer Key

* **Answer 1.1**:
  The container runtime calls `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`. This sets the process attribute `PR_SET_NO_NEW_PRIVS` in the Linux kernel struct `task_struct`. This flag ensures that operations during `execve()` do not grant privileges that were not already granted to the calling process. It explicitly disables the execution of `SUID`/`SGID` bits and ignores file capabilities on executed binaries.

* **Answer 1.2**:
  Even if a container runs as `root` (UID 0), setting `allowPrivilegeEscalation: false` prevents child processes spawned inside the container from gaining additional capabilities through `SUID` binaries or file capabilities (`setcap`). However, UID 0 still retains whatever capability set was granted at container initialization. To fully contain UID 0, `allowPrivilegeEscalation: false` must be combined with dropping all capabilities (`capabilities.drop: ["ALL"]`) and enforcing `runAsNonRoot: true`.

---

### Exercise 2 Answer Key

* **Answer 2.1**:
  `CAP_SYS_ADMIN` is often called "the new root" in Linux. It grants permissions to perform a wide range of administrative operations, including:
  1. Mounting and unmounting filesystems (`mount()`, `umount2()`).
  2. Executing `chroot()` to swap the root filesystem boundary to host mounts (`hostPath`).
  3. Accessing and configuring kernel IPC objects, network interfaces, and cgroups.
  4. Interacting with raw block devices (`/dev/sdX`).
  When combined with a `hostPath` volume mount of `/` or access to host namespaces, `CAP_SYS_ADMIN` allows a container process to mount the host root partition, escape container namespaces via `nsenter` or `chroot`, and take complete control of the underlying Kubernetes node.

* **Answer 2.2**:
  * **Baseline Profile**: A low-friction policy that prevents known privilege escalations. It permits default capabilities and does not require `allowPrivilegeEscalation: false` to be set explicitly. It allows host paths if not restricted by third-party CRDs, but restricts host namespaces (`hostPID`, `hostIPC`, `hostNetwork`) and host ports.
  * **Restricted Profile**: A strictly hardened policy following pod hardening best practices. It **mandates** that:
    1. `securityContext.allowPrivilegeEscalation` must be explicitly set to `false`.
    2. Containers must drop all capabilities (`capabilities.drop: ["ALL"]`), allowing only select safe capabilities (like `NET_BIND_SERVICE`) to be explicitly added back if required.
    3. Containers must run as non-root (`runAsNonRoot: true`).
    4. `seccompProfile` must be defined (`RuntimeDefault` or `Localhost`).
    5. `hostPath` volumes are completely prohibited.

---

### Exercise 3 Answer Key

* **Answer 3.1**:
  To create or update a `Role` or `ClusterRole` containing rules that exceed the user's current permissions, the user must explicitly hold the `escalate` verb on `roles` or `clusterroles` in the `rbac.authorization.k8s.io` API group within the relevant scope (namespace or cluster-wide). Without the `escalate` verb, the API server's RBAC validation hook enforces rule coverage checks and blocks any request that attempts to grant permissions beyond what the caller currently holds.

* **Answer 3.2**:
  If a user has `create` permissions on `pods` and can generate tokens for a high-privilege `ServiceAccount` (or mount an existing high-privilege `ServiceAccount` like `cluster-admin`), they can perform indirect privilege escalation by:
  1. Creating a pod that mounts the token of a privileged `ServiceAccount` (e.g., `system:serviceaccount:kube-system:generic-garbage-collector` or a custom admin SA).
  2. Extracting the JWT token from `/var/run/secrets/kubernetes.io/serviceaccount/token` inside the pod.
  3. Using that high-privilege ServiceAccount token to issue direct requests to the Kubernetes API server, bypassing their own restricted RBAC boundaries.

</details>