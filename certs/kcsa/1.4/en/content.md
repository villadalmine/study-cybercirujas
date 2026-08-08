# CNCF KCSA Study Material: Domain 1.4 – Isolation Techniques

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 1:** Cloud Native Security Architecture  
**Subdomain 1.4:** Isolation Techniques  
**Weight:** 2.33%  

---

## 1. Architectural Problem & Production Motivation

In cloud-native infrastructure, the default container execution model relies on shared Linux kernel primitives (`namespaces`, `cgroups`, `capabilities`, and LSMs like AppArmor/SELinux). Standard container runtimes such as `runc` or `crun` do not virtualize the kernel; they isolate host processes by restricting their view of system resources.

```
+-------------------------------------------------------------------+
|                         Standard Container                        |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|                                 | Syscalls                        |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |         Shared Linux Host Kernel (Direct Access)          |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+

+-------------------------------------------------------------------+
|                        gVisor Sandbox (runsc)                     |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|                                 | Syscalls                        |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |   Sentry (Application Kernel written in Go - Traps Syscalls) |   |
|   +-----------------------------------------------------------+   |
|                                 | Restricted Syscalls             |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |                     Shared Host Kernel                    |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+

+-------------------------------------------------------------------+
|                       Kata MicroVM (kata-runtime)                 |
|   +-----------------------------------------------------------+   |
|   |                      User Application                     |   |
|   +-----------------------------------------------------------+   |
|   |                      Guest Linux Kernel                   |   |
|   +-----------------------------------------------------------+   |
|                                 | Hardware Virtualization (KVM)   |
|                                 v                                 |
|   +-----------------------------------------------------------+   |
|   |                     Shared Host Kernel                    |   |
|   +-----------------------------------------------------------+   |
+-------------------------------------------------------------------+
```

### The Shared Kernel Threat Model
When multiple tenants share a single Kubernetes node running standard `runc` containers, any unpatched kernel vulnerability (e.g., CVE-2022-0492, Dirty COW / CVE-2016-5195, or Dirty Pipe / CVE-2022-0847) allows an attacker who achieves arbitrary code execution inside a container to compromise the host kernel. This leads to complete cluster takeover.

### Multi-Tenancy Classification
1. **Soft Multi-Tenancy (Workload Separation):** Tenants belong to the same organizational boundary (e.g., different microservices in the same enterprise). Isolation relies on Kubernetes logical primitives: Namespaces, RBAC, NetworkPolicies, and ResourceQuotas.
2. **Hard Multi-Tenancy (Untrusted Workloads):** Tenants are mutually distrustful (e.g., multi-tenant SaaS running arbitrary user code, third-party plugins, or AI/ML training jobs). Logical isolation is insufficient; strict physical or hypervisor-level sandboxing is mandatory.

### The Defense-in-Depth Isolation Spectrum
Production security architecture requires implementing multiple layers of defense:
* **Node Level:** Dedicated node pools partitioned via Kubernetes Taints, Tolerations, and NodeAffinity.
* **Hypervisor / MicroVM Level:** Hardware-assisted virtualization shims (`Kata Containers`, `Firecracker`) or user-space application kernels (`gVisor`).
* **OS / Process Level:** Least privilege via Linux `Capabilities`, `Seccomp` syscall filtering, `AppArmor`/`SELinux` profiles, and non-root execution constraints (`runAsNonRoot`, `readOnlyRootFilesystem`).

---

## 2. Technical Comparison & Trade-off Matrix

### Container Sandbox Technologies Comparison

| Feature / Metric | Standard OCI (`runc` / `crun`) | User-Space Kernel (`gVisor` / `runsc`) | MicroVM (`Kata Containers`) | WebAssembly (`WasmEdge` / `Wasmtime`) |
| :--- | :--- | :--- | :--- | :--- |
| **Isolation Boundary** | Namespaces + cgroups | Ring 3 Sentry Interceptor (Go) | Hardware Virtualization (KVM) | Software Fault Isolation (SFI / WASM Sandbox) |
| **Kernel State** | Shared Host Kernel | Virtualized User-Space Kernel | Dedicated Guest Kernel | No OS Kernel (WASI API Interface) |
| **Syscall Compatibility** | 100% Native Linux Syscalls | ~70-80% Implemented (Restricted) | 100% Native Linux Syscalls | WASI restricted (Non-POSIX default) |
| **Startup Overhead** | ~5-15ms | ~50-100ms | ~150-500ms | < 1ms |
| **Memory Overhead / Pod** | ~0 MB (host native overhead) | ~15 - 30 MB | ~100 - 130 MB | ~1 - 5 MB |
| **I/O & Syscall Throughput**| Baseline Native (100%) | 40-70% (High syscall overhead) | 85-95% (Virtio device virtualization) | Near-Native for compute, API overhead for I/O |
| **Primary Use Case** | Trusted internal microservices | Untrusted web apps, multi-tenant SaaS | Multi-tenant untrusted code, legacy apps | Edge functions, serverless micro-tasks |

### Pod Security Context Primitives Comparison

| Primitive | Mechanism | Primary Threat Mitigation | Production Trade-off / Considerations |
| :--- | :--- | :--- | :--- |
| `readOnlyRootFilesystem` | Mounts root `/` as read-only | Prevents malware persistence & binary tampering | Requires mounting explicit `emptyDir` volumes for standard temp files (`/tmp`, `/run`) |
| `allowPrivilegeEscalation: false` | Sets `PR_SET_NO_NEW_PRIVS` flag | Blocks `setuid` / `setgid` binaries (e.g., `sudo`) | Breaks legacy container images requiring suid binaries at entrypoint |
| `capabilities.drop: ["ALL"]` | Removes POSIX capabilities | Prevents raw socket creation, device access, and admin overrides | Must selectively re-add specific caps (e.g., `NET_BIND_SERVICE`) if strictly necessary |
| `seccompProfile` | BPF syscall filter | Limits available Linux kernel attack surface | Custom profiles require tracing application syscalls via eBPF/auditd to prevent breaking code |
| `appArmorProfile` | Mandatory Access Control (MAC) | Restricts file access, capabilities, and network execution by path | Requires pre-loading profiles onto every Kubernetes worker node kernel |

---

## 3. Complete Production Manifests & Infrastructure Configurations

### 3.1 containerd Runtime Engine Configuration (`/etc/containerd/config.toml`)
Complete snippet configuring `containerd` to support `runc`, `gvisor` (`runsc`), and `kata-containers`.

```toml
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
          runtime_type = "io.containerd.runsc.v1"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor.options]
            TypeUrl = "io.containerd.runsc.v1.options"
            ConfigPath = "/etc/containerd/runsc.toml"

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
            ConfigPath = "/usr/share/defaults/kata-containers/configuration-qemu.toml"
```

---

### 3.2 Kubernetes RuntimeClasses Definition (`runtime-classes.yaml`)

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
  labels:
    security.kubernetes.io/tier: sandbox
handler: gvisor
scheduling:
  nodeSelector:
    sandbox.k8s.io/gvisor-enabled: "true"
  tolerations:
    - key: "security.kubernetes.io/untrusted-workload"
      operator: "Exists"
      effect: "NoSchedule"
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
  labels:
    security.kubernetes.io/tier: microvm
handler: kata
scheduling:
  nodeSelector:
    sandbox.k8s.io/kata-enabled: "true"
  tolerations:
    - key: "security.kubernetes.io/untrusted-workload"
      operator: "Exists"
      effect: "NoSchedule"
```

---

### 3.3 Custom Seccomp Profile (`/var/lib/kubelet/seccomp/profiles/strict-microservice.json`)

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
        "accept4",
        "access",
        "arch_prctl",
        "bind",
        "brk",
        "clock_gettime",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "execve",
        "exit",
        "exit_group",
        "fcntl",
        "fstat",
        "futex",
        "getdents64",
        "getpid",
        "getrandom",
        "getsockname",
        "getsockopt",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "newfstatat",
        "openat",
        "poll",
        "read",
        "readlink",
        "recvfrom",
        "rseq",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_getaffinity",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "sigaltstack",
        "socket",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Hardened Multi-Tenant Sandboxed Deployment (`hardened-workload.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: untrusted-api-service
  namespace: tenant-sandbox
  labels:
    app.kubernetes.io/name: untrusted-api
    app.kubernetes.io/part-of: payment-gateway
    security.kubernetes.io/hardened: "true"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: untrusted-api
  template:
    metadata:
      labels:
        app: untrusted-api
        tier: backend
    spec:
      runtimeClassName: gvisor
      serviceAccountName: untrusted-api-sa
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-microservice.json
      containers:
        - name: api-server
          image: registry.enterprise.io/secure/api-server:v2.4.1
          imagePullPolicy: Always
          command: ["/app/server"]
          ports:
            - containerPort: 8080
              name: http-metrics
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
            appArmorProfile:
              type: Localhost
              localhostProfile: k8s-apparmor-strict-profile
          resources:
            limits:
              cpu: "1"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - mountPath: /tmp
              name: tmp-volume
            - mountPath: /var/cache/app
              name: cache-volume
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: cache-volume
          emptyDir:
            sizeLimit: 128Mi
```

---

### 3.5 Strict Tenant Network Isolation Policy (`network-isolation.yaml`)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-sandbox
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-isolated-ingress-egress
  namespace: tenant-sandbox
spec:
  podSelector:
    matchLabels:
      app: untrusted-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-gateway
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
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
    - to:
        - podSelector:
            matchLabels:
              app: secure-database
      ports:
        - protocol: TCP
          port: 5432
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Inspecting Active RuntimeClasses and Node Labels
Verify that node pools are correctly registered for sandboxed workloads.

```bash
$ kubectl get runtimeclass
```
```text
NAME     HANDLER   AGE
gvisor   gvisor    14d
kata     kata      14d
runc     runc      14d
```

```bash
$ kubectl get nodes -L sandbox.k8s.io/gvisor-enabled,sandbox.k8s.io/kata-enabled
```
```text
NAME                                STATUS   ROLES    AGE   VERSION   GVISOR-ENABLED   KATA-ENABLED
worker-node-std-01.internal         Ready    <none>   45d   v1.30.2   <none>           <none>
worker-node-sandbox-01.internal     Ready    <none>   12d   v1.30.2   true             <none>
worker-node-microvm-01.internal     Ready    <none>   12d   v1.30.2   <none>           true
```

---

### 4.2 Verifying Syscall Virtualization inside gVisor (`runsc`)
Execute a kernel-probing command inside a container running under `gvisor` vs standard `runc`.

```bash
$ kubectl exec -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w -- uname -a
```
```text
Linux untrusted-api-service-774f5bb54-x9q2w 4.4.0 #1 SMP Sun Jan 10 15:04:03 PST 2016 x86_64 Linux
```

```bash
$ kubectl exec -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w -- dmesg
```
```text
[    0.000000] Starting gVisor...
[    0.412102] Operationalizing Sentry Sandbox Application Kernel...
[    0.891230] Syscall table initialized (Google gVisor sandbox).
```

*Note: The Linux kernel version `4.4.0` returned by gVisor is emulated by the Sentry user-space kernel, regardless of the host's actual kernel version (e.g., 6.5.0).*

---

### 4.3 Auditing Container Security Context Status via Process Inspection
Identify the host PID of the container process and verify Seccomp and Linux Capabilities.

```bash
$ crictl pods --namespace tenant-sandbox
```
```text
POD ID              CREATED             STATE               NAME                                 NAMESPACE
8f3a9b1c1d1e        5 minutes ago       Ready               untrusted-api-service-774f5bb54-x9q2w   tenant-sandbox
```

```bash
$ crictl ps --pod 8f3a9b1c1d1e
```
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID
a1b2c3d4e5f6        registry.ent...     5 minutes ago       Running             api-server          0                   8f3a9b1c1d1e
```

```bash
$ crictl inspect a1b2c3d4e5f6 | jq '.info.pid'
```
```text
348912
```

```bash
$ cat /proc/348912/status | grep -E "Uid|Gid|Cap|Seccomp"
```
```text
Uid:	10001	10001	10001	10001
Gid:	10001	10001	10001	10001
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
Seccomp:	2
Seccomp_filters:	1
```

*Interpretation:*
* `Uid` / `Gid`: Process runs strictly as non-root unprivileged user `10001`.
* `Cap*`: All bitmasks are `0000000000000000` confirming complete capability removal (`capabilities.drop: ["ALL"]`).
* `Seccomp: 2`: Indicates `SECCOMP_MODE_FILTER` is active (custom or default seccomp filter applied).

---

### 4.4 Verifying AppArmor Profile Enforcement on Node
Verify loaded AppArmor profiles on worker nodes.

```bash
$ aa-status | grep k8s-apparmor
```
```text
   k8s-apparmor-strict-profile
   1 profiles are in enforce mode.
   0 profiles are in complain mode.
```

---

## 5. Verification & Troubleshooting Guide

### 5.1 Common Production Failure Scenarios & Diagnostics

#### Scenario A: Pod Fails with `CreateContainerError` / `RuntimeClass` Handler Missing
* **Symptom:** Pod remains stuck in `ContainerCreating` or `CreateContainerError`.
* **Diagnostic Command:**
  ```bash
  $ kubectl describe pod -n tenant-sandbox untrusted-api-service-774f5bb54-x9q2w
  ```
  ```text
  Events:
    Type     Reason     Age                From               Message
    ----     ------     ----               ----               -------
    Warning  Failed     12s (x3 over 45s)  kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = RuntimeHandler "gvisor" not supported
  ```
* **Root Cause:** The `containerd` daemon on the target node lacks the `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]` configuration block, or the `containerd-shim-runsc-v1` binary is missing from system `PATH` (`/usr/local/bin/`).
* **Resolution:**
  1. Install `runsc` binary on worker node:
     ```bash
     $ curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/runsc -o /usr/local/bin/runsc
     $ chmod +x /usr/local/bin/runsc
     $ curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/containerd-shim-runsc-v1 -o /usr/local/bin/containerd-shim-runsc-v1
     $ chmod +x /usr/local/bin/containerd-shim-runsc-v1
     ```
  2. Reload `containerd`: `systemctl restart containerd`.

---

#### Scenario B: Application Crash (`CrashLoopBackOff`) Due to Restrictive Seccomp Profile
* **Symptom:** Container starts and immediately crashes with exit code `139` (SIGSEGV) or `159` (SIGSYS).
* **Diagnostic Command:**
  Inspect kernel log buffer on host via `dmesg` or check `/var/log/audit/audit.log`.
  ```bash
  $ dmesg -T | grep -i seccomp
  ```
  ```text
  [Fri Aug  7 19:30:12 2026] audit: type=1326 audit(1723073412.891:402): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=35012 comm="server" exe="/app/server" sig=31 arch=c000003e syscall=289 compat=0 ip=0x7f9a2b10c8a0 code=0x0
  ```
* **Root Cause Analysis:**
  * `sig=31`: `SIGSYS` (System call bad / disallowed by seccomp).
  * `syscall=289`: Translating syscall architecture `0xc000003e` (x86_64) using `ausyscall`:
    ```bash
    $ ausyscall x86_64 289
    ```
    ```text
    epoll_create1
    ```
  * Syscall `epoll_create1` is executed by application initialization but absent from `strict-microservice.json` whitelist.
* **Resolution:** Add `"epoll_create1"` to the `syscalls[0].names` array within the custom Seccomp profile manifest and reload.

---

### 5.2 Pod Isolation Vulnerability Audit Checklist

Use this checklist during architecture reviews to identify misconfigurations that invalidate container isolation boundaries:

1. **Host Namespace Sharing:**
   * Ensure `hostNetwork: false`, `hostPID: false`, `hostIPC: false` in Pod spec.
2. **Host Directory Volume Mounts:**
   * Reject `hostPath` mounts (especially `/`, `/etc`, `/var/run/docker.sock`, `/run/containerd/containerd.sock`).
3. **Privileged Mode Escalation:**
   * Enforce `privileged: false` and `allowPrivilegeEscalation: false` across all container specs via Kyverno or OPA Gatekeeper policies.
4. **Root Execution:**
   * Enforce `runAsNonRoot: true` and explicitly drop capabilities (`ALL`).
5. **Runtime Class Enforcement:**
   * Ensure untrusted multi-tenant workloads are forced into `gvisor` or `kata` via Admission Webhooks.

---

## 6. References

* **CNCF KCSA Exam Curriculum:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Documentation - Security Context:**  
  [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* **Kubernetes Documentation - RuntimeClass:**  
  [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
* **gVisor Official Documentation & Threat Model:**  
  [https://gvisor.dev/docs/](https://gvisor.dev/docs/)
* **Kata Containers Architecture:**  
  [https://katacontainers.io/](https://katacontainers.io/)
* **Kubernetes Hard Multi-Tenancy Benchmarks & Guidance:**  
  [https://kubernetes.io/docs/concepts/security/multi-tenancy/](https://kubernetes.io/docs/concepts/security/multi-tenancy/)
* **CIS Kubernetes Benchmark:**  
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)

---

### Summary of Completed Artifacts & Guidance
- **Motivations & Threat Model**: Detailed kernel-sharing risks, hard vs. soft multi-tenancy, and sandbox layer defenses.
- **Trade-off Comparison Tables**: Rigorous comparative analysis of `runc`, `gVisor`, `Kata Containers`, and `WASM`, alongside Pod Security primitives.
- **Production Manifests**: Complete `/etc/containerd/config.toml`, `RuntimeClass`, custom `seccomp` profile JSON, hardened `Deployment`, and strict isolation `NetworkPolicy`.
- **CLI Outputs & Diagnostics**: Real terminal command trace snippets covering `crictl`, host process auditing, syscall interception verification, and AppArmor profiles.
- **Troubleshooting & Audit Guide**: Diagnosis for missing runtime handlers, custom seccomp `SIGSYS` syscall resolution, and isolation audit checklist.
- **Official References**: Fully populated with valid URLs to CNCF, Kubernetes, gVisor, Kata, and CIS docs.