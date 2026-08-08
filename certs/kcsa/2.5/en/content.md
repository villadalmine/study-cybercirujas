# CNCF KCSA Study Guide: Topic 2.5 – Container Runtime Security

**Target Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** 2.0 – Container Security  
**Subtopic:** 2.5 Container Runtime  
**Weight:** 2.0  

---

## 1. Production Motivation & Architectural Problem

In traditional containerization architectures, containers do not virtualize hardware; they isolate operating system resources using Linux kernel primitives—specifically **namespaces** (`mnt`, `pid`, `net`, `ipc`, `uts`, `user`, `cgroup`) and **control groups (cgroups)**. While this design yields low overhead and high density, it creates a flat attack surface: **all containers running on a host node share the same underlying Linux kernel**.

```
+-----------------------------------------------------------------------+
|                         Host OS & Linux Kernel                        |
|   (Shared Syscall Table: sys_ptrace, sys_bpf, sys_unshare, etc.)       |
+-----------------------------------+-----------------------------------+
|     Standard Runtime (runc)       |      Sandboxed Runtime (runsc)    |
| +-------------------------------+ | +-------------------------------+ |
| | Pod A (Untrusted Workload)    | | | Pod B (Multi-tenant Tenant)  | |
| | - Direct kernel syscall pass  | | | - Intercepted syscalls (Go)   | |
| | - Vulnerable to kernel CVEs   | | | - Isolated Sentry / Gofer     | |
| +-------------------------------+ | +-------------------------------+ |
+-----------------------------------+-----------------------------------+
```

### The Security Gap in Production
1. **Shared Kernel Vulnerability Surface**: A zero-day vulnerability in any of the ~350+ Linux system calls (e.g., `CVE-2022-0492` in cgroups v1, `CVE-2022-0847` Dirty Pipe) allows an attacker who achieves code execution inside a container to compromise the shared host kernel, escape the container boundary, and compromise all adjacent Pods on the node.
2. **Coarse-Grained System Call Access**: By default, standard low-level runtimes present an uncurated syscall interface to workloads. Even with default Seccomp profiles, over 300 syscalls remain available to containerized processes.
3. **Improper Separation of Responsibilities**: Historically, monolithic container daemons ran as single privileged background processes. The modern Cloud Native Architecture mandates separation into **High-Level Runtimes** (CRI implementations managing lifecycle, image distribution, and gRPC endpoints) and **Low-Level Runtimes** (OCI-compliant binaries executing container state transitions).

---

## 2. Technical Comparisons & Architecture Deep Dive

### Architectural Layers: CRI vs. OCI

```
[ Kubelet ]
     |
     | gRPC (Container Runtime Interface - CRI)
     v
[ High-Level Runtime: containerd / CRI-O ]
     |
     | OCI Runtime Spec (JSON bundle & rootfs)
     v
[ Low-Level Runtime: runc / runsc / kata-runtime ]
     |
     v
[ Linux Kernel / MicroVM Sandbox ]
```

* **CRI (Container Runtime Interface)**: A gRPC API defined by Kubernetes that enables `kubelet` to communicate with high-level container runtimes (`containerd`, `CRI-O`) without recompiling the Kubernetes binary.
* **OCI (Open Container Initiative)**: Standards governing container images (`image-spec`) and container execution (`runtime-spec`). Low-level runtimes consume an OCI bundle (a directory containing `config.json` and a root filesystem) to spawn isolated execution contexts.

---

### High-Level Runtimes: containerd vs. CRI-O

| Feature | containerd | CRI-O |
| :--- | :--- | :--- |
| **Origin & Governance** | CNCF Graduated (originally Docker) | CNCF Graduated (Red Hat / Kubernetes community) |
| **Primary Design Goal** | General-purpose container engine embedding CRI via plugin | Dedicated, lightweight CRI runtime exclusively for Kubernetes |
| **Architecture** | Modular plugin system (`io.containerd.grpc.v1.cri`) | Single-purpose binary adhering strictly to Kubernetes CRI versions |
| **Image Management** | Integrated storage drivers, native image distribution | Uses containers/image and containers/storage libraries |
| **Configuration File** | `/etc/containerd/config.toml` | `/etc/crio/crio.conf` |
| **CLI Diagnostic Tool** | `ctr` (native), `crictl` (CRI-focused) | `crictl` (CRI-focused) |

---

### Low-Level OCI Runtimes: runc vs. gVisor (runsc) vs. Kata Containers

| Technical Metric | `runc` (Default) | `gVisor` (`runsc`) | `Kata Containers` |
| :--- | :--- | :--- | :--- |
| **Isolation Mechanism** | Shared Host Kernel (Namespaces + cgroups) | Application Kernel in User Space (Sentry intercepts syscalls) | Hardware-assisted Virtualization (MicroVM per Pod) |
| **Security Boundary** | Soft (Host Kernel Syscall Surface) | Hard (User-space Sentry / Limited Host Syscalls) | Hard (Hardware Hypervisor / VMX Root / Non-Root) |
| **Hypervisor / Kernel** | None (Direct Host Kernel) | Custom Sentry written in Go | QEMU / Cloud-Hypervisor / Firecracker |
| **Syscall Latency Overhead** | Negligible (~0%) | Moderate (~10–30% for IO/syscall heavy tasks) | Low (~2–5% with VIRTIO devices) |
| **Memory Footprint Overhead** | Minimal (~15–30 MB per container) | Low (~15–50 MB per sandbox) | High (~100–300 MB minimum for VM guest kernel) |
| **Startup Latency** | Instantaneous (< 50ms) | Fast (< 150ms) | Slower (300ms – 1.5s depending on VMM) |
| **Compatibility** | 100% Linux API compliant | ~70% (Blocks raw sockets, custom kernel modules) | 100% Linux API compliant |
| **Production Use Case** | Trusted internal workloads | Untrusted multi-tenant microservices, user code execution | Untrusted legacy code, multi-tenant hard boundary |

---

### Resource Boundaries: cgroups v1 vs. cgroups v2

```
cgroups v1 (Multi-Hierarchy):               cgroups v2 (Unified Hierarchy):
/sys/fs/cgroup/memory/kubepods/            /sys/fs/cgroup/kubepods.slice/
/sys/fs/cgroup/cpu/kubepods/               ├── cgroup.controllers
/sys/fs/cgroup/pids/kubepods/              ├── cgroup.procs
                                           └── memory.max, cpu.max, pids.max
```

1. **Unified Hierarchy**: cgroups v1 uses independent hierarchies per subsystem (`memory`, `cpu`, `pids`), leading to race conditions and disjointed resource allocation accounting. cgroups v2 uses a single unified tree where processes reside only in leaf nodes.
2. **Pressure Stall Information (PSI)**: cgroups v2 introduces PSI to measure CPU, memory, and I/O thrashing before out-of-memory (OOM) killer events occur.
3. **Rootless Resource Management**: cgroups v2 natively allows non-root users to safely manage cgroup sub-trees without host privilege escalation.
4. **Enhanced OOM Control**: cgroups v2 allows `memory.oom.group` configuration, ensuring all processes within a Pod container sandbox are killed simultaneously if an OOM event occurs, preventing half-dead container states.

---

## 3. Production Infrastructure & Manifests

### 3.1 containerd Multi-Runtime Configuration (`/etc/containerd/config.toml`)

This production snippet configures `containerd` with multiple OCI runtime handlers: default `runc`, `gvisor` (`runsc`), and `kata-qemu`.

```toml
version = 2

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        
        # Standard default OCI runtime
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          runtime_engine = ""
          runtime_root = ""
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true

        # Sandboxed Runtime: gVisor (runsc)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
          runtime_type = "io.containerd.runsc.v1"
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor.options]
            TypeUrl = "io.containerd.runsc.v1.options"
            ConfigPath = "/etc/containerd/runsc.toml"

        # Sandboxed Runtime: Kata Containers (MicroVM)
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
          runtime_type = "io.containerd.kata.v2"
          
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
            ConfigPath = "/usr/share/defaults/kata-containers/configuration-qemu.toml"
```

---

### 3.2 Kubernetes RuntimeClass Definitions

#### `runtime-class-gvisor.yaml`
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
  labels:
    security.cncf.io/tier: sandboxed
handler: gvisor
overhead:
  podFixed:
    memory: "50Mi"
    cpu: "100m"
scheduling:
  nodeSelector:
    container-runtime.cncf.io/gvisor-enabled: "true"
  tolerations:
    - key: "security.cncf.io/untrusted-workloads"
      operator: "Exists"
      effect: "NoSchedule"
```

#### `runtime-class-kata.yaml`
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
  labels:
    security.cncf.io/tier: microvm
handler: kata
overhead:
  podFixed:
    memory: "250Mi"
    cpu: "250m"
scheduling:
  nodeSelector:
    container-runtime.cncf.io/kata-enabled: "true"
```

---

### 3.3 Strict Custom Seccomp Profile (`/var/lib/kubelet/seccomp/profiles/strict-sec.json`)

Deploy this profile on all worker nodes at `/var/lib/kubelet/seccomp/profiles/strict-sec.json`.

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "accept4",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "exit",
        "exit_group",
        "futex",
        "getpid",
        "gettid",
        "read",
        "write",
        "mmap",
        "mprotect",
        "munmap",
        "brk",
        "rt_sigaction",
        "rt_sigprocmask",
        "sigaltstack",
        "version",
        "clock_gettime",
        "fstat",
        "close"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

---

### 3.4 Production Hardened Pod Manifest utilizing Sandboxed Runtime & Seccomp

#### `hardened-sandboxed-pod.yaml`
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-payment-processor
  namespace: production
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/tier: backend
spec:
  runtimeClassName: gvisor
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/strict-sec.json
  containers:
    - name: processor
      image: registry.enterprise.io/finance/payment-processor:v2.4.1
      imagePullPolicy: IfNotPresent
      command: ["/app/processor_binary"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          memory: "128Mi"
          cpu: "250m"
        limits:
          memory: "512Mi"
          cpu: "1000m"
      volumeMounts:
        - name: tmp-dir
          mountPath: /tmp
        - name: app-cache
          mountPath: /var/cache/app
  volumes:
    - name: tmp-dir
      emptyDir:
        medium: Memory
        sizeLimit: "64Mi"
    - name: app-cache
      emptyDir:
        sizeLimit: "128Mi"
```

---

## 4. Real CLI Commands & Expected Outputs

### 4.1 Inspecting High-Level Runtime Socket via `crictl`

```bash
$ crictl --runtime-endpoint unix:///run/containerd/containerd.sock info
```
```json
{
  "status": {
    "conditions": [
      {
        "type": "RuntimeReady",
        "status": true,
        "reason": "",
        "message": ""
      },
      {
        "type": "NetworkReady",
        "status": true,
        "reason": "",
        "message": ""
      }
    ]
  },
  "runtimeHandlers": {
    "gvisor": {
      "features": {
        "recursiveReadOnlyMounts": true
      }
    },
    "kata": {
      "features": {
        "recursiveReadOnlyMounts": false
      }
    },
    "runc": {
      "features": {
        "recursiveReadOnlyMounts": true
      }
    }
  },
  "config": {
    "containerd": {
      "defaultRuntimeName": "runc"
    }
  }
}
```

---

### 4.2 Listing Running Pod Sandboxes & Low-Level Runtime Handlers

```bash
$ crictl pods --namespace production -o table
```
```
POD ID              CREATED             STATE               NAME                        NAMESPACE           ATTEMPT             RUNTIME GROUP
8f3a1b0c9e8d        10 minutes ago      Ready               secure-payment-processor    production          0                   gvisor
a2b3c4d5e6f7        2 hours ago         Ready               auth-service-7654321-x89    production          0                   runc
```

---

### 4.3 Inspecting Low-Level OCI Process Trees via `ctr`

```bash
$ ctr --namespace k8s.io task list
```
```
TASK                                    PID      STATUS    
secure-payment-processor-processor      48291    RUNNING
auth-service-7654321-x89-auth           51022    RUNNING
```

Executing `pstree` on the host to verify gVisor (`runsc`) user-space sandbox isolation:

```bash
$ pstree -p 48291
```
```
containerd-shim-(48201)───runsc(48291)───runsc-sandbox(48310)───processor_binar(48350)
```

---

### 4.4 Verifying Kernel System Call Interception (gVisor Sentry vs. Host Kernel)

Executing `uname -a` inside a `runc` pod returns the **host node kernel version**:

```bash
$ kubectl exec -it auth-service-7654321-x89 -n production -- uname -a
```
```
Linux worker-node-01.infrastructure.internal 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 x86_64 GNU/Linux
```

Executing `uname -a` inside a `gvisor` pod returns the **gVisor Virtual Kernel (Sentry)** emulation layer:

```bash
$ kubectl exec -it secure-payment-processor -n production -- uname -a
```
```
Linux secure-payment-processor 4.4.0 #1 SMP Sun Jan 10 00:00:00 2017 x86_64 GNU/Linux
```

---

## 5. Verification, Hardening & Failure Diagnostics Guide

```
                            [ Diagnosis Flow ]
                                    |
                    Is the Pod stuck in ContainerCreating?
                                   / \
                                 YES  NO
                                 /     \
    Check containerd logs via journalctl   Verify applied Seccomp status
    Filter by CRI runtime handler error     Inspect /proc/<PID>/status
```

### 5.1 Verifying Applied Seccomp Status for a Process
To confirm that a seccomp filter is active on a running container without trusting internal tool assertions, locate the container's main PID on the host and inspect `/proc/<PID>/status`.

```bash
# Step 1: Find host PID of the target container
$ PID=$(crictl inspect --output go-template --template '{{.info.pid}}' <CONTAINER_ID>)

# Step 2: Query Seccomp field in kernel process status
$ grep -i "Seccomp" /proc/$PID/status
```
```
Seccomp:	2
Seccomp_filters:	1
```

> **Seccomp Status Key:**
> * `0`: Disabled (No seccomp isolation active — **CRITICAL RISK**)
> * `1`: Strict Mode (Allows only `read`, `write`, `exit`, `sigreturn`)
> * `2`: Filter Mode (Active `seccomp-bpf` custom or `RuntimeDefault` profile applied)

---

### 5.2 Common Production Failures & Diagnostics Matrix

#### Problem 1: `RuntimeHandlerNotSupported` Error
* **Symptom**: Pod status remains `ContainerCreating`. `kubectl describe pod <pod-name>` outputs:
  `Failed to create pod sandbox: rpc error: code = Unknown desc = RuntimeHandler "gvisor" not supported`
* **Root Cause**: The `RuntimeClass` handler name specified in the YAML (`handler: gvisor`) does not match any entry registered under `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes]` in `/etc/containerd/config.toml`.
* **Remediation**:
  1. Update `/etc/containerd/config.toml` on all affected nodes to define the target runtime handler section.
  2. Reload containerd daemon: `$ systemctl restart containerd`.

#### Problem 2: Seccomp Profile Violation (`SIGSYS` / Exit Code 159)
* **Symptom**: Container repeatedly crashes upon startup with exit code `159` or `139` (Killed by `SIGSYS`).
* **Root Cause**: The containerized binary issued a system call explicitly blocked by the custom seccomp JSON profile (`defaultAction: SCMP_ACT_ERRNO` or `SCMP_ACT_KILL`).
* **Diagnostic Procedure**:
  Inspect host kernel audit logs (`dmesg` or `auditd`) to pinpoint the blocked syscall number:
  ```bash
  $ dmesg -T | grep -i "seccomp"
  ```
  ```
  [Fri Aug  7 20:15:30 2026] audit: type=1326 audit(1723061730.412:98): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=48350 comm="processor_binary" exe="/app/processor_binary" sig=31 arch=c000003e syscall=257 compat=0 ip=0x7f9a12c4e10b code=0x0
  ```
  * `syscall=257`: Translate `257` using `ausyscall x86_64 257` -> outputs `openat`.
* **Remediation**: Append `"openat"` to the allowed syscall names list within `/var/lib/kubelet/seccomp/profiles/strict-sec.json` and re-apply.

#### Problem 3: Invalid Runtime Overhead Allocation
* **Symptom**: Cluster experiences node pressure or unscheduled evicted pods due to uncounted resource usage from Kata MicroVMs or gVisor Sentry daemons.
* **Root Cause**: `RuntimeClass` was created without defining the `overhead` field. Kubelet capacity planning only accounts for container request limits, leading to host memory exhaustion when low-level runtimes consume memory outside the container's cgroup boundary.
* **Remediation**: Enforce `overhead.podFixed` within `RuntimeClass` specifications for all non-`runc` execution handlers.

---

## 6. References

* **CNCF KCSA Curriculum Repository**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Documentation – Container Runtimes**:  
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
* **Kubernetes Documentation – RuntimeClass**:  
  https://kubernetes.io/docs/concepts/containers/runtime-class/
* **Kubernetes Documentation – Restrict a Container's Syscalls with Seccomp**:  
  https://kubernetes.io/docs/tutorials/security/seccomp/
* **Open Container Initiative (OCI) Runtime Specification**:  
  https://github.com/opencontainers/runtime-spec
* **containerd Advanced Configuration & CRI Plugin**:  
  https://github.com/containerd/containerd/blob/main/docs/cri/config.md
* **gVisor Architecture & Security Model**:  
  https://gvisor.dev/docs/architecture/
* **Kata Containers Documentation & Architecture**:  
  https://katacontainers.io/docs/
* **Control Groups v2 (cgroups v2) Linux Kernel Documentation**:  
  https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html