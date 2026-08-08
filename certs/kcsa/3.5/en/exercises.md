# KCSA Exam Preparation: Topic 3.5 — Isolation and Segmentation

**Domain:** Workload Security / Cluster Hardening  
**Exam Topic:** 3.5 Isolation and Segmentation  
**Weight:** ~15% (Workload Security & Hardening Domain)  
**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  

---

## 1. Deep Technical Architecture & Mechanics

### 1.1 Linux Isolation Primitives vs. Kubernetes Boundaries

Kubernetes does not provide isolation natively at the hypervisor level by default; instead, it relies on Linux kernel primitives exposed through the Container Runtime Interface (CRI) and Open Container Initiative (OCI) runtimes (such as `runc`).

```
+-------------------------------------------------------------------------------+
|                               KUBERNETES POD                                  |
|                                                                               |
|  +-------------------------------------------------------------------------+  |
|  |                           Pod Network Namespace                         |  |
|  |  +-----------------------------------+   +---------------------------+  |  |
|  |  |      Container 1 (App)            |   |   Container 2 (Sidecar)   |  |  |
|  |  |  - Mount Namespace (rootfs)       |   |  - Mount Namespace        |  |  |
|  |  |  - PID Namespace (isolated)       |   |  - PID Namespace          |  |  |
|  |  |  - User Namespace (UID mapping)   |   |  - User Namespace         |  |  |
|  |  +-----------------------------------+   +---------------------------+  |  |
|  |                    ^                                   ^                |  |
|  +--------------------|-----------------------------------|----------------+  |
|                       v                                   v                   |
|       cgroups v2 (CPU, Memory, IO)        cgroups v2 (CPU, Memory, IO)        |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
|                              HOST LINUX KERNEL                                |
|  - Seccomp Profile Filter (syscall filtering via BPF)                         |
|  - AppArmor / SELinux (Mandatory Access Control for files & capabilities)     |
|  - eBPF / iptables / IPVS (NetworkPolicy enforcement via CNI)                 |
+-------------------------------------------------------------------------------+
```

1. **Linux Namespaces**: Provide virtualization of system resources.
   - `net`: Virtualizes network devices, IP routing tables, firewall rules. Containers in a Pod share the same `net` namespace (loopback interface `lo`).
   - `mnt`: Isolates file system mount points.
   - `pid`: Isolates process IDs. Inside container, main process is PID 1; on host, it maps to an unprivileged PID.
   - `ipc`: Isolates System V IPC and POSIX message queues.
   - `uts`: Isolates hostname and NIS domain name.
   - `user`: Maps container UIDs/GIDs to different host UIDs/GIDs (e.g., container root `UID 0` maps to host unprivileged `UID 100000`).

2. **Control Groups (cgroups v2)**: Restrict, account for, and isolate resource usage (CPU, Memory, I/O, pids) for a group of processes. Prevents noisy neighbor problems and Denial of Service (DoS) attacks.

3. **Seccomp (Secure Computing Mode)**: Restricts syscall access. The Linux kernel has ~450 system calls. A standard container requires ~40–70 syscalls. Seccomp uses BPF filters to return `EPERM` (Operation not permitted) or terminate processes attempting forbidden syscalls (e.g., `unshare`, `kexec_load`).

4. **AppArmor / SELinux**: Mandatory Access Control (MAC) mechanisms enforcing path-based (AppArmor) or label-based (SELinux) policies on file access, capability usage, and network socket binding.

---

### 1.2 Network Segmentation Mechanics: CNI Enforcement (iptables vs. eBPF)

Kubernetes native `NetworkPolicy` resources are declarative specifications. The Kubernetes API server stores them, but **kube-router** or the installed **CNI plugin** (e.g., Calico, Cilium) enforces them.

```
+-------------------------------------------------------------------------------+
|                            CNI Enforcement Mechanics                          |
|                                                                               |
| [iptables Mode (Calico / kube-proxy)]                                         |
|  Packet -> Prerouting -> FORWARD -> iptables Chain Lookup -> ACCEPT/DROP      |
|  * O(N) evaluation complexity per packet as rule count grows.                 |
|  * High CPU overhead with thousands of NetworkPolicies.                       |
|                                                                               |
| [eBPF Mode (Cilium)]                                                          |
|  Packet -> TC (Traffic Control) / XDP hook -> BPF Map Lookup -> FAST PASS/DROP|
|  * O(1) hash map lookup complexity.                                           |
|  * Socket-level filtering (sockops) bypasses TCP/IP stack overhead entirely.  |
+-------------------------------------------------------------------------------+
```

* **iptables / IPVS Enforcement (e.g., Calico Felix)**: Translates `NetworkPolicy` objects into iptables chains (`cali-pi-*` for ingress, `cali-po-*` for egress). Rule evaluation is sequential ($O(N)$), leading to high latency at scale.
* **eBPF Enforcement (e.g., Cilium)**: Compiles `NetworkPolicy` and `CiliumNetworkPolicy` into bytecode loaded into Linux kernel hooks (`tc` for traffic control, XDP for network interface, `sockops` for socket layer). Rules use BPF Maps ($O(1)$ lookups), enabling identity-based security enforcement regardless of IP address churn.

---

### 1.3 Container Runtime Isolation: `runc` vs. `gVisor` vs. `Kata Containers`

```
+-------------------------------------------------------------------------------+
|                            Container Runtime Spectrum                         |
|                                                                               |
|  Shared Kernel (Default)      Application Kernel (gVisor)      MicroVM (Kata)  |
|  +--------------------+        +-----------------------+    +---------------+ |
|  | App -> runc        |        | App -> Sentry (Go)    |    | App -> Linux  | |
|  +--------------------+        +-----------------------+    |        Guest  | |
|           | (Syscalls)                     | (Sanitized)    +---------------+ |
|           v                                v                | QEMU / Firecracker|
|  +--------------------+        +-----------------------+    +---------------+ |
|  | Host Linux Kernel  |        | Gofer -> Host Kernel  |    | Host Kernel   | |
|  +--------------------+        +-----------------------+    +---------------+ |
|  [Threat: Kernel Exploit]      [Shield: Intercepts     [Boundary: Hardware|
|   Escalates to Host root       Syscalls in User Space]  Virtualization VT-x]  |
+-------------------------------------------------------------------------------+
```

* **Standard OCI (`runc`)**: Shared kernel model. System calls pass directly to the host kernel. Vulnerable to kernel zero-day exploits (e.g., Dirty Cow, CVE-2022-0492).
* **gVisor (`runsc`)**: User-space kernel proxy written in Go. Intercepts syscalls via `ptrace` or `KVM`. Implements the Linux kernel API (`Sentry`) in user space and proxies file operations through `Gofer`, severely reducing host kernel attack surface.
* **Kata Containers**: MicroVM isolation. Each Pod runs inside a hardware-isolated lightweight virtual machine (using QEMU or Cloud Hypervisor). Provides dedicated kernel instance per Pod.

---

## 2. Official References & Documentation Links

* [Kubernetes Documentation — Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* [Kubernetes Documentation — Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* [Kubernetes Documentation — Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* [Kubernetes Documentation — RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
* [gVisor Security Architecture](https://gvisor.dev/docs/architecture_guide/)
* [Cilium Network Policy Reference](https://docs.cilium.io/en/stable/security/policy/)
* [CNCF KCSA Official Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Guided Practical Exercises

---

### Guided Exercise 1: Multi-Tenant Network Segmentation & Egress Lockdown with Native `NetworkPolicy`

#### Objectives
1. Implement a Zero-Trust Default-Deny Ingress and Egress policy in namespace `finance`.
2. Selectively permit ingress from frontend tier `payment-ui` to backend tier `payment-api`.
3. Configure explicitly scoped egress allowing `payment-api` to query CoreDNS for domain resolution and reach external payment gateway IPs (`198.51.100.50/32`), blocking all unapproved egress.
4. Verify iptables/eBPF enforcement using diagnostic CLI tools.

---

#### Step 1: Create Multi-Tenant Namespaces and Workloads

Execute the following commands to establish isolated namespaces and workloads:

```bash
kubectl create namespace finance
kubectl create namespace marketing

# Deploy Payment API in finance namespace
kubectl run payment-api --namespace=finance --image=nginx:1.25-alpine --labels=app=payment-api,tier=backend
kubectl expose pod payment-api --namespace=finance --port=80 --target-port=80

# Deploy Payment UI in finance namespace
kubectl run payment-ui --namespace=finance --image=nginx:1.25-alpine --labels=app=payment-ui,tier=frontend

# Deploy rogue app in marketing namespace
kubectl run rogue-pod --namespace=marketing --image=alpine:3.19 -- sleep 3600
```

**Expected Output:**
```text
namespace/finance created
namespace/marketing created
pod/payment-api created
service/payment-api exposed
pod/payment-ui created
pod/rogue-pod created
```

---

#### Step 2: Enforce Default Deny Ingress & Egress in Namespace `finance`

Apply the following `NetworkPolicy` manifest:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: finance
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

Save as `default-deny.yaml` and execute:

```bash
kubectl apply -f default-deny.yaml
```

**Verification Command:**
Test connectivity from `payment-ui` to `payment-api`:

```bash
kubectl exec -n finance payment-ui -- wget -qO- --timeout=2 http://payment-api.finance.svc.cluster.local
```

**Expected Output:**
```text
wget: download timed out
command terminated with exit code 1
```

---

#### Step 3: Implement Granular Ingress and Egress Rule for Payment API

Apply the complete production-grade policy allowing DNS egress, restricted payment gateway IP egress, and explicit UI ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-api-security-policy
  namespace: finance
spec:
  podSelector:
    matchLabels:
      app: payment-api
      tier: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: payment-ui
          tier: frontend
    ports:
    - protocol: TCP
      port: 80
  egress:
  # Allow UDP/TCP DNS Resolution to kube-dns/CoreDNS in kube-system
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow Egress only to External Payment Gateway IP range
  - to:
    - ipBlock:
        cidr: 198.51.100.0/24
        except:
        - 198.51.100.128/25
    ports:
    - protocol: TCP
      port: 443
```

Save as `payment-api-policy.yaml` and execute:

```bash
kubectl apply -f payment-api-policy.yaml
```

---

#### Step 4: Diagnostic & Verification Suite

1. **Valid Ingress Check:**
```bash
kubectl exec -n finance payment-ui -- wget -qO- --timeout=2 http://payment-api.finance.svc.cluster.local
```
*Expected Output:* HTML content from NGINX (`<!DOCTYPE html>...`).

2. **Cross-Namespace Ingress Check (Rogue Pod):**
```bash
kubectl exec -n marketing rogue-pod -- wget -qO- --timeout=2 http://payment-api.finance.svc.cluster.local
```
*Expected Output:* `wget: download timed out`.

3. **Egress Restriction Check (Unapproved External Traffic):**
```bash
kubectl exec -n finance payment-api -- wget -qO- --timeout=2 https://8.8.8.8
```
*Expected Output:* `wget: download timed out`.

---

#### Verification Checkpoint 1

**Question 1.1:** An engineer modifies `payment-api-security-policy` and specifies `namespaceSelector: {}` without a `podSelector` under the `ingress.from` rule block. What is the security implication of this configuration?

**Question 1.2:** If a CNI uses eBPF (e.g., Cilium) instead of iptables, where in the network datapath is an egress packet dropped when violating a `NetworkPolicy`, and how does this affect host CPU utilization compared to iptables?

---

### Guided Exercise 2: Workload Sandboxing with `RuntimeClass`, gVisor (`runsc`), and Custom Seccomp Profiles

#### Objectives
1. Configure a Kubernetes `RuntimeClass` bound to a sandboxed CRI handler (`runsc`).
2. Deploy a high-risk microservice enforcing custom `seccomp` profiles and disabling privilege escalation.
3. Diagnose and verify syscall intercept behavior between `runc` and `runsc` using low-level container runtime tools (`crictl`, `/proc` inspection).

---

#### Step 1: Create `RuntimeClass` Resource

Ensure the underlying node CRI (containerd or CRI-O) has the `runsc` handler registered in its configuration (`/etc/containerd/config.toml`). Manifest definition:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
overhead:
  podFixed:
    cpu: "100m"
    memory: "50Mi"
scheduling:
  nodeSelector:
    sandbox: gvisor-enabled
```

Save as `runtimeclass-gvisor.yaml` and execute:

```bash
kubectl apply -f runtimeclass-gvisor.yaml
```

---

#### Step 2: Create Custom Audit/Deny Seccomp Profile

Create a JSON `seccomp` profile at host location `/var/lib/kubelet/seccomp/profiles/strict-sandbox.json`:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept", "accept4", "access", "arch_prctl", "bind", "brk", "clone",
        "close", "connect", "epoll_create1", "epoll_ctl", "epoll_wait",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "getsockname", "getsockopt",
        "listen", "lseek", "mmap", "mprotect", "munmap", "nanosleep",
        "newfstatat", "openat", "poll", "read", "readv", "recvfrom",
        "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "sched_yield",
        "sendto", "set_tid_address", "setsockopt", "shutdown", "socket",
        "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

#### Step 3: Deploy Sandboxed Hardened Microservice Manifest

Apply a complete `Pod` specification deploying into the `gvisor` runtime with hardened security context:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-processor
  namespace: finance
  labels:
    app: untrusted-processor
    tier: processing
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/strict-sandbox.json
  containers:
  - name: processor
    image: alpine:3.19
    command: ["sh", "-c", "uname -a && sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    resources:
      limits:
        cpu: "500m"
        memory: "256Mi"
      requests:
        cpu: "100m"
        memory: "128Mi"
```

Save as `sandboxed-pod.yaml` and execute:

```bash
kubectl apply -f sandboxed-pod.yaml
```

---

#### Step 4: Low-Level Runtime Diagnostics

1. **Verify Kernel Version & Architecture String inside Sandbox:**

```bash
kubectl exec -n finance untrusted-processor -- uname -a
```

**Expected Output (gVisor Sentry Virtual Kernel):**
```text
Linux untrusted-processor 4.4.0 #1 SMP Sun Jan 10 00:00:00 UTC 2016 x86_64 Linux
```
*(Notice gVisor emulates an older Linux kernel string `4.4.0` regardless of the host's actual kernel version).*

2. **Inspect Host Process & Container Runtime via `crictl` on Node:**

```bash
# Obtain Container ID via crictl
CONTAINER_ID=$(crictl ps --name=processor -q)
crictl inspect $CONTAINER_ID | jq '.info.runtimeSpec.linux.namespaces'
```

**Expected Output:**
```json
[
  { "type": "pid" },
  { "type": "network" },
  { "type": "mount" },
  { "type": "ipc" },
  { "type": "uts" }
]
```

3. **Verify Seccomp Profile Status in `/proc` File System:**

```bash
POD_PID=$(crictl inspect $CONTAINER_ID | jq '.info.pid')
cat /proc/$POD_PID/status | grep -i Seccomp
```

**Expected Output:**
```text
Seccomp:	2
Seccomp_filters:	1
```
*(Value `2` indicates `SECCOMP_MODE_FILTER` is active).*

---

#### Verification Checkpoint 2

**Question 2.1:** What is the technical mechanism by which `allowPrivilegeEscalation: false` prevents a binary with the Setuid (`SUID`) bit set (e.g., `/bin/su` or `sudo`) from escalating privileges inside a container, even if run as root?

**Question 2.2:** Why does deploying a container with gVisor (`runsc`) prevent root exploits targeting host `/sys/kernel/debug` or kernel module loading (`kexec_load`), whereas standard `runc` relies entirely on capability dropping and seccomp filters?

---

### Guided Exercise 3: Pod Security Admission (PSA) Enforcement & User Namespace (`userns`) Isolation

#### Objectives
1. Enforce Kubernetes **Restricted** Pod Security Standard at the namespace level using Pod Security Admission (PSA) labels.
2. Observe PSA validation rejection when applying non-compliant Pod manifests.
3. Configure Linux User Namespaces (`hostUsers: false`) to map container `root` (`UID 0`) to unprivileged UIDs on the host kernel.

---

#### Step 1: Label Namespace for Pod Security Admission Enforcement

Apply PSA labels enforcing `restricted` level while providing `warn` and `audit` feedback:

```bash
kubectl create namespace secure-workloads

kubectl label --overwrite namespace secure-workloads \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

**Verification Command:**
```bash
kubectl get ns secure-workloads --show-labels
```

---

#### Step 2: Test PSA Enforcement (Negative Testing)

Attempt to apply a non-compliant workload (`privileged-test.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: secure-workloads
spec:
  containers:
  - name: attacker
    image: nginx:1.25
    securityContext:
      privileged: true
```

Execute application command:

```bash
kubectl apply -f privileged-test.yaml
```

**Expected Output (Admission Webhook Denial):**
```text
Error from server (Forbidden): error when creating "privileged-test.yaml": pods "privileged-pod" is forbidden: 
violates PodSecurity "restricted:latest": privileged (container "attacker" must not set securityContext.privileged=true), 
allowPrivilegeEscalation != false (container "attacker" must set securityContext.allowPrivilegeEscalation=false), 
unrestricted capabilities (container "attacker" must set securityContext.capabilities.drop=["ALL"]), 
runAsNonRoot != true (pod or container "attacker" must set securityContext.runAsNonRoot=true), 
seccompProfile (pod or container "attacker" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

#### Step 3: Deploy Valid Restricted Pod with User Namespaces (`userns`)

Apply a fully compliant Restricted PSS manifest utilizing User Namespaces (`hostUsers: false` available in K8s v1.28+):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-userns-pod
  namespace: secure-workloads
spec:
  hostUsers: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10002
    runAsGroup: 10002
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: secure-app
    image: alpine:3.19
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
      requests:
        cpu: "50m"
        memory: "64Mi"
```

Save as `userns-pod.yaml` and execute:

```bash
kubectl apply -f userns-pod.yaml
```

**Expected Output:**
```text
pod/hardened-userns-pod created
```

---

#### Step 4: Verify Host UID Mapping for User Namespace Isolation

Execute diagnostic checks on the node to verify UID mapping:

```bash
# 1. Fetch Node Host Process ID (PID) of the container
CONTAINER_ID=$(crictl ps --name=secure-app -q)
HOST_PID=$(crictl inspect $CONTAINER_ID | jq '.info.pid')

# 2. Inspect kernel UID map for the container PID
cat /proc/$HOST_PID/uid_map
```

**Expected Output:**
```text
         0     655360      65536
```
*(Explanation: Inside the container, UID `0` starts at mapping `655360` on the host kernel for a range of `65536` UIDs. Container UID `10002` translates to host UID `665362`).*

---

#### Verification Checkpoint 3

**Question 3.1:** What is the critical structural difference between Pod Security Policies (PSP) (deprecated/removed in K8s 1.25) and Pod Security Admission (PSA)?

**Question 3.2:** If a container running with `hostUsers: false` suffers a container breakout exploit where the attacker escapes the mount namespace to the host filesystem, why does User Namespace isolation prevent the attacker from modifying host files owned by real host `root` (`UID 0`)?

---

## 4. Comprehensive Solutions & Architectural Answers

<details>
<summary><strong>Click to expand Solution Key & Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Answer 1.1:** Specifying `namespaceSelector: {}` without a `podSelector` matches **all pods in all namespaces** across the cluster. This effectively turns the ingress policy into an open rule allowing any workload in any namespace to connect to `payment-api` on TCP port 80, completely negating cross-namespace isolation. To restrict ingress to a specific namespace, `namespaceSelector` must be paired with specific `matchLabels` (e.g., `kubernetes.io/metadata.name: finance`), or combined with a `podSelector`.

* **Answer 1.2:** In an eBPF-based CNI (such as Cilium), the egress packet is intercepted directly at the Linux Kernel network hook—specifically at the **Traffic Control (`tc`)** layer or at the socket layer (`sockops`) via eBPF program hooks attached to the pod's virtual Ethernet (`veth`) interface. 
  
  * **CPU Impact:** Unlike iptables, which evaluates rules sequentially ($O(N)$ complexity, causing CPU consumption to scale linearly with the number of policies), eBPF uses kernel BPF Map lookups ($O(1)$ hash tables). This reduces host CPU overhead to near-constant time regardless of whether there are 10 or 10,000 active NetworkPolicies.

---

### Exercise 2 Solutions

* **Answer 2.1:** Setting `allowPrivilegeEscalation: false` sets the `PR_SET_NO_NEW_PRIVS` flag via the `prctl()` system call on the container process during initialization. This kernel flag ensures that child processes created via `execve()` cannot gain privileges beyond what the parent process possessed. It explicitly ignores the `Setuid` (`SUID`) and `Setgid` (`SGID`) bits on file binaries and strips file capabilities, preventing unprivileged users from executing binaries like `/bin/su` or custom SUID executables to elevate privileges to root.

* **Answer 2.2:** `runc` shares the host Linux kernel directly. If an attacker bypasses seccomp/capabilities, any vulnerability in a host syscall handler (e.g., kernel memory corruption) directly compromises the host kernel. 
  
  gVisor (`runsc`) introduces a user-space kernel (the **Sentry**). The container process makes system calls that are intercepted by the Sentry in user space. The Sentry implements over 300 Linux system calls internally without invoking the host kernel. Any attempt to interact with dangerous host kernel structures (like `/sys/kernel/debug` or calling `kexec_load`) is handled entirely inside gVisor's sandboxed Go memory space, returning `EPERM` or failing safely without ever issuing a system call to the host kernel.

---

### Exercise 3 Solutions

* **Answer 3.1:** 
  1. **Architecture & Enforcement:** PSP was an in-tree authorization mechanism relying on complex RBAC bindings (`Use` permissions on `PodSecurityPolicy` objects), which suffered from performance bottlenecks, unpredictable policy application order, and extreme operational complexity. PSA is built directly into the Kubernetes API Server as an admission controller using declarative HTTP webhook logic based on predefined Pod Security Standards (Privileged, Baseline, Restricted).
  2. **Mutation vs. Validation:** PSP supported mutating pods (e.g., injecting default securityContexts). PSA is strictly **non-mutating/validating only**. It evaluates incoming Pod definitions against standard levels and rejects non-compliant Pods at admission time.
  3. **Scoping:** PSA operates natively via namespace labels (`pod-security.kubernetes.io/enforce`), eliminating the need for RBAC cluster bindings to enforce security levels.

* **Answer 3.2:** When `hostUsers: false` is configured, Linux User Namespaces map UIDs/GIDs inside the container namespace to an unprivileged range on the host kernel (e.g., container UID 0 maps to host UID 655360). 
  
  If the process escapes the container runtime and accesses the host filesystem, the host kernel checks the inode owner permissions against the **host kernel credentials** of the process. Since the process possesses host `UID 655360`, the kernel treats it as an unprivileged user on the host. Any attempt to write to host files owned by host `root` (`UID 0`, such as `/etc/shadow` or `/etc/kubernetes/pki`) will be denied with `EACCES` (Permission denied) by the host VFS (Virtual File System) permission check.

</details>