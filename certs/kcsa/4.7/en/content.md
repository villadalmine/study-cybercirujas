# KCSA Study Material: Domain 4.7 – Privilege Escalation

**Exam**: Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain**: Workload Security  
**Topic**: 4.7 Privilege Escalation  
**Domain Weight**: 2.29%  

---

## 1. Motivation & Production Architectural Problem

### 1.1 Low-Level Linux Kernel Mechanics: `PR_SET_NO_NEW_PRIVS`
In Linux process execution, privilege escalation typically occurs when a process invokes `execve()` on a file with `setuid` (Set User ID) or `setgid` (Set Group ID) permissions, or when binary capabilities are attached to an executable file (via `setcap`).

When a process executes a `setuid` binary (such as `/usr/bin/sudo` or `/bin/mount`), the kernel transitions the Effective User ID (`euid`) of the process from the unprivileged user ID to the file owner ID (typically `root`, UID `0`). 

To prevent unprivileged containerized applications from obtaining elevated host or container root permissions, Linux kernel 3.5 introduced the `PR_SET_NO_NEW_PRIVS` bit flag, controllable via the `prctl(2)` system call:

```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
```

When `PR_SET_NO_NEW_PRIVS` is set to `1`:
- The kernel guarantees that the process and any of its child processes spawned via `fork()` or `execve()` can never acquire privileges that could not be granted by the calling process without `execve()`.
- Setuid (`S_ISUID`) and Setgid (`S_ISGID`) bit flags on executables are explicitly ignored during `execve()`.
- File system capabilities (e.g., `setcap cap_net_raw+ep /usr/bin/ping`) are suppressed and not transferred into the effective capability set (`CapEff`).
- Linux Security Modules (LSMs) like AppArmor or SELinux cannot transition to execution domains that grant more permissions than the parent domain.

In Kubernetes, the pod `securityContext` property `allowPrivilegeEscalation` directly controls whether container runtimes (such as `containerd` via `runc`) invoke `prctl(PR_SET_NO_NEW_PRIVS, 1, ...)` prior to running the container entrypoint process.

```
+---------------------------------------------------------------------------------------+
| Container Process (UID 1000) execution of /usr/bin/sudo                               |
+---------------------------------------------------------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
   allowPrivilegeEscalation: true               allowPrivilegeEscalation: false
   (PR_SET_NO_NEW_PRIVS = 0)                    (PR_SET_NO_NEW_PRIVS = 1)
                    |                                             |
     Kernel evaluates S_ISUID bit                  Kernel ignores S_ISUID bit
                    |                                             |
   euid transitions: 1000 -> 0                   euid remains: 1000
   Effective Capabilities = FULL                 Effective Capabilities = NONE
                    |                                             |
    [Root Privilege Escalation]                   [EPERM: Operation Not Permitted]
```

### 1.2 Kubernetes API Privilege Escalation: RBAC Mechanisms
Privilege escalation is not limited to the Linux kernel; it extends to the Kubernetes Control Plane control-loop via Role-Based Access Control (RBAC).

In Kubernetes, API privilege escalation occurs when a identity (ServiceAccount, User, or Group) can grant itself or another identity permissions higher than those currently assigned to it. Kubernetes mitigates this via two specific enforcement rules inside the API Server authorization module:

1. **Role Escalation Restriction (`escalate` verb)**:
   A subject can only create or update a `Role` or `ClusterRole` if the subject already possesses *all* the permissions contained in that role, **OR** if the subject holds explicit permission to perform the `escalate` verb on `roles` or `clusterroles` in the `rbac.authorization.k8s.io` API group.

2. **Role Binding Restriction (`bind` verb)**:
   A subject can only create or update a `RoleBinding` or `ClusterRoleBinding` if the subject already holds all permissions present in the target role, **OR** if the subject holds explicit permission to perform the `bind` verb on the target `Role` or `ClusterRole`.

If an administrator misconfigures RBAC by granting `verbs: ["*"]` or `verbs: ["create", "update"]` on `roles` or `rolebindings` without realizing the implied escalation vectors, an attacker who compromises a Pod's ServiceAccount token can instantly escalate privileges to `cluster-admin`.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Container Privilege Escalation Vectors Matrix

| Escalation Vector | Root Cause | Primary Kernel/API Primitive | Exploitation Mechanism | Impact / Blast Radius | Mitigation Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Setuid Binary Abuse** | `allowPrivilegeEscalation: true` | `PR_SET_NO_NEW_PRIVS = 0` | Invoking binaries with `S_ISUID` bit (e.g., misconfigured local binaries or host binary mounts) | Root execution within container namespace | Set `allowPrivilegeEscalation: false` |
| **Privileged Container** | `privileged: true` | Disables Linux Namespaces, Cgroups, LSMs, drops CapBnd masks | Direct access to host devices (`/dev/*`), `/sys`, `/proc`, cgroups | Full host compromise (Container Breakout) | PodSecurityAdmission `Restricted` profile |
| **Retained Capabilities** | Default capability set not dropped | `CapEff` contains `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE` | Exploiting system calls allowed by excessive capability masks | Namespace escape, raw network manipulation, file override | Set `capabilities.drop: ["ALL"]` |
| **RBAC `escalate` / `bind` Abuse** | Insecure `ClusterRole` rule definitions | `rbac.authorization.k8s.io` authorization check bypass | Creating high-privilege Roles or binding existing `cluster-admin` roles to controlled ServiceAccount | Complete Kubernetes Control Plane Takeover | Strict audit of RBAC verbs (`bind`, `escalate`, `impersonate`) |
| **HostPath Mount Abuse** | Mounting `/`, `/etc`, or `/var/run/docker.sock` | File system DAC permissions on host files | Modifying host cron jobs, ssh keys, or issuing commands to container runtime socket | Full host read/write access and host takeover | Restrict `hostPath` volumes via Admission Control |

### 2.2 Security Controls Trade-off Matrix

| Control Mechanism | Performance Overhead | Developer Friction | Security Efficacy | Operational Complexity |
| :--- | :--- | :--- | :--- | :--- |
| **`allowPrivilegeEscalation: false`** | Zero overhead (single `prctl` syscall at startup) | Low (only breaks legacy apps requiring `sudo`/`ping`) | High (stops setuid/setcap binary escalation) | Low (simple YAML field) |
| **`readOnlyRootFilesystem: true`** | Zero overhead | Medium/High (requires explicit `tmpfs` mounts for `/tmp`) | Very High (prevents writing malicious setuid payload) | Medium (requires application storage refactoring) |
| **Capabilities `drop: ["ALL"]`** | Zero overhead | Medium (requires mapping required capabilities per workload) | High (drastically reduces kernel attack surface) | Medium (requires capability discovery) |
| **PodSecurityAdmission (Restricted)** | Near-zero overhead (in-tree API Server evaluation) | High (rejects non-compliant manifests at API level) | High (enforces baseline security cluster-wide) | Low (namespace-level labeling) |

---

## 3. Production Manifests & Infrastructure Configurations

### 3.1 Vulnerable Pod Manifest (Insecure Defaults)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-workload
  namespace: production-apps
  labels:
    app.kubernetes.io/name: vulnerable-workload
    app.kubernetes.io/component: API
spec:
  containers:
  - name: web-app
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
    securityContext:
      # CRITICAL SECURITY RISK: Allows setuid/setgid binaries to escalate privileges
      allowPrivilegeEscalation: true
      # CRITICAL SECURITY RISK: Running as root UID 0 inside container
      runAsUser: 0
      # CRITICAL SECURITY RISK: Retains Linux capabilities (e.g., CAP_NET_RAW, CAP_SYS_ADMIN if set)
      capabilities:
        add:
        - NET_ADMIN
        - SYS_ADMIN
      readOnlyRootFilesystem: false
```

### 3.2 Hardened Pod Manifest (Production-Grade / KCSA Compliant)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-workload
  namespace: production-apps
  labels:
    app.kubernetes.io/name: hardened-workload
    app.kubernetes.io/component: api
spec:
  securityContext:
    # Enforce non-root execution at Pod level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    # Standardize Seccomp profile to RuntimeDefault across all containers
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web-app
    image: cgr.dev/chainguard/static:latest
    securityContext:
      # ENFORCES PR_SET_NO_NEW_PRIVS = 1 via container runtime (runc/containerd)
      allowPrivilegeEscalation: false
      # Prevent container root execution
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      # Prevent writing malicious executables to container filesystem
      readOnlyRootFilesystem: true
      # Drop ALL kernel capabilities
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: tmp-volume
      mountPath: /tmp
  volumes:
  # Provide isolated ephemeral storage for applications requiring temporary file access
  - name: tmp-volume
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

### 3.3 Namespace Enforcement with Pod Security Admission (PSA)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-apps
  labels:
    # Enforces the Restricted Pod Security Standard profile strictly
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    # Generates warnings in API client responses for non-compliant pods
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    # Logs audit events for non-compliant pods
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
```

### 3.4 Insecure vs Secure RBAC Definitions

#### Insecure Role Allowing Privilege Escalation
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-apps
  name: insecure-app-manager
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
# DANGEROUS: Allows granting any role permission to arbitrary ServiceAccounts
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings"]
  verbs: ["create", "update", "escalate", "bind"]
```

#### Secure Hardened Role
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-apps
  name: secure-app-manager
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update"]
# Explicitly omitting rbac.authorization.k8s.io resources eliminates RBAC privilege escalation
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Verifying `PR_SET_NO_NEW_PRIVS` via Container `/proc` Filesystem

Deploy the hardened pod and inspect the `/proc/1/status` file inside the container process to verify kernel bit flags.

```bash
$ kubectl apply -f hardened-workload.yaml
pod/hardened-workload created

$ kubectl exec -it hardened-workload -n production-apps -- cat /proc/1/status | grep -E "NoNewPrivs|Cap"
NoNewPrivs:	1
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
```

Contrast this output with a pod running with `allowPrivilegeEscalation: true`:

```bash
$ kubectl exec -it vulnerable-workload -n production-apps -- cat /proc/1/status | grep -E "NoNewPrivs|Cap"
NoNewPrivs:	0
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000100
CapAmb:	0000000000000000
```

### 4.2 Testing Setuid Binary Execution Failure under `allowPrivilegeEscalation: false`

Attempting to run a setuid binary inside a container configured with `allowPrivilegeEscalation: false` yields an explicit operation rejection from the kernel:

```bash
$ kubectl exec -it hardened-workload -n production-apps -- /usr/bin/sudo -u root whoami
sudo: error in /etc/sudo.conf, line 0 while loading plugin "sudoers_policy"
sudo: unable to initialize policy plugin
sudo: PERM_ROOT: setresuid(0, -1, -1): Operation not permitted
```

### 4.3 Auditing RBAC Privilege Escalation Verbs via `kubectl`

Execute authorization queries to detect if a specific ServiceAccount or user can escalate privileges:

```bash
$ kubectl auth can-i escalate roles -n production-apps --as=system:serviceaccount:production-apps:default
no

$ kubectl auth can-i bind clusterroles --as=system:serviceaccount:production-apps:default
no

$ kubectl auth can-i create rolebindings -n production-apps --as=system:serviceaccount:production-apps:default
no
```

Querying an over-privileged account:

```bash
$ kubectl auth can-i escalate clusterroles --as=dev-admin
yes
```

### 4.4 Testing Pod Security Admission (PSA) Enforcement at API Level

When applying a non-compliant pod manifest to a namespace labeled with `pod-security.kubernetes.io/enforce: restricted`:

```bash
$ kubectl apply -f vulnerable-workload.yaml -n production-apps
Error from server (Forbidden): error when creating "vulnerable-workload.yaml": pods "vulnerable-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "web-app" must set securityContext.allowPrivilegeEscalation=false), runAsNonRoot != true (pod or container "web-app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "web-app" must not set runAsUser=0), unrestricted capabilities (container "web-app" must set securityContext.capabilities.drop=["ALL"])
```

---

## 5. Verification & Failure Diagnosis Guide

### 5.1 Diagnostic Workflow for Privilege Escalation Issues

```
+-------------------------------------------------------------------------------+
|                      Pod Deployment / Security Audit                          |
+-------------------------------------------------------------------------------+
                                       |
                                       v
               +-----------------------------------------------+
               | Does namespace enforce Restricted PSA profile? |
               +-----------------------------------------------+
                                /             \
                              YES              NO
                              /                 \
                             v                   v
      +------------------------------+   +------------------------------+
      | API Server checks PodSpec    |   | Pod Created on Worker Node   |
      | - allowPrivilegeEscalation   |   +------------------------------+
      | - runAsNonRoot               |                  |
      | - capabilities.drop: ["ALL"] |                  v
      +------------------------------+   +------------------------------+
             /                \          | Container runtime (containerd|
          PASS                FAIL       | / runc) receives OCI spec    |
           /                    \        +------------------------------+
          v                      v                      |
  +---------------+      +---------------+              v
  | Pod Accepted  |      | API Rejection |     +------------------+
  +---------------+      | (403 Forbidden|     | Reads field:     |
                         +---------------+     | allowPrivilege-  |
                                               | Escalation       |
                                               +------------------+
                                                        |
                                        +---------------+---------------+
                                        |                               |
                                      FALSE                           TRUE
                                        |                               |
                                        v                               v
                              +--------------------+          +--------------------+
                              | Executes syscall:  |          | Skips prctl flag.  |
                              | prctl(PR_SET_NO_   |          | Setuid binaries    |
                              | NEW_PRIVS, 1, ...) |          | functional.        |
                              +--------------------+          +--------------------+
                                        |                               |
                                        v                               v
                              +--------------------+          +--------------------+
                              | /proc/1/status     |          | /proc/1/status     |
                              | NoNewPrivs: 1      |          | NoNewPrivs: 0      |
                              +--------------------+          +--------------------+
```

### 5.2 Common Production Errors and Solutions

#### Issue 1: Application fails with `EPERM` or `Operation not permitted` after setting `allowPrivilegeEscalation: false`
* **Root Cause**: The application executable or an internal helper script uses setuid/setgid or requires specific capabilities (e.g., `CAP_NET_BIND_SERVICE` or `CAP_NET_RAW`).
* **Diagnosis**:
  1. Inspect container logs: `kubectl logs <pod-name> -n <namespace>`.
  2. Inspect binary attributes inside container build target: `ls -la /path/to/binary` (check for `-rwsr-xr-x`).
  3. Inspect capability requirements: `getcap /path/to/binary`.
* **Resolution**:
  - Remove setuid bits from binary during image build: `RUN chmod u-s,g-s /path/to/binary`.
  - For port binding below 1024, use sysctl `net.ipv4.ip_unprivileged_port_start=80` instead of `CAP_NET_BIND_SERVICE` or setuid root wrappers.
  - Grant specific minimal capabilities via `capabilities.add` explicitly while keeping `allowPrivilegeEscalation: false` if system capabilities (not setuid binaries) are needed. Note: under Linux kernel rules, adding binary file capabilities still requires `allowPrivilegeEscalation: true` if run as non-root; use process-level explicit capability grants via container engine runtime instead.

#### Issue 2: RBAC authorization failure during automated deployment pipeline
* **Root Cause**: ServiceAccount executing the deployment holds `create` permission on `RoleBindings` but lacks `bind` on the target `ClusterRole`, or lacks the exact permissions contained within the Role it is trying to create.
* **Diagnosis**:
  1. Inspect API audit logs for `403 Forbidden` status codes.
  2. Run `kubectl auth can-i` with `--as` impersonation matching the deployment controller ServiceAccount.
* **Resolution**:
  - Explicitly grant `bind` or `escalate` permissions only to administrative management ServiceAccounts (e.g., GitOps controllers like ArgoCD/Flux running in secure namespaces). Never grant these to workload ServiceAccounts.

---

## 6. References

* **Kubernetes Documentation – Security Context**:  
  https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
* **Kubernetes Documentation – Pod Security Standards (Restricted Profile)**:  
  https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted
* **Kubernetes Documentation – Pod Security Admission**:  
  https://kubernetes.io/docs/concepts/security/pod-security-admission/
* **Kubernetes Documentation – RBAC Authorization (Privilege Escalation Prevention)**:  
  https://kubernetes.io/docs/reference/access-authn-authz/rbac/#privilege-escalation-prevention-and-bootstrapping
* **Linux Kernel Documentation – `prctl(2)` and `PR_SET_NO_NEW_PRIVS`**:  
  https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html
* **CNCF KCSA Exam Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **NIST SP 800-190 – Application Container Security Guide**:  
  https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf