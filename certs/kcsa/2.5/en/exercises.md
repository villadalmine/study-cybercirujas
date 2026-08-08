# KCSA Domain 2.5: Container Runtime Security & Hardening

**Domain Weight:** 2.0  
**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Reference Sources:**
- CNCF KCSA Curriculum: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- Kubernetes Container Runtimes Architecture: [https://kubernetes.io/docs/setup/production-environment/container-runtimes/](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- Kubernetes RuntimeClass API Specification: [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- Open Container Initiative (OCI) Runtime Specification: [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
- CNCF containerd Architecture & Hardening: [https://containerd.io/docs/](https://containerd.io/docs/)
- gVisor Sandbox Architecture: [https://gvisor.dev/docs/architecture_guide/](https://gvisor.dev/docs/architecture_guide/)

---

## 1. Architectural Deep-Dive: The Container Runtime Stack

In modern Kubernetes clusters, the container execution pipeline is decoupled across distinct layers via the **Container Runtime Interface (CRI)** and **Open Container Initiative (OCI)** specifications. Understanding this architecture is vital for securing the host node and enforcing isolation boundaries.

```
+-------------------------------------------------------------------------------+
|                                Kubelet                                        |
+-------------------------------------------------------------------------------+
                                   |
                       gRPC over Unix Domain Socket
               (/run/containerd/containerd.sock or /run/crio/crio.sock)
                                   v
+-------------------------------------------------------------------------------+
| Higher-Level CRI Runtime (containerd / CRI-O)                                |
|  - Image pull & unpacking                                                     |
|  - Storage management (snapshotters/overlayfs)                                |
|  - Cgroup lifecycle & network namespace orchestration                         |
+-------------------------------------------------------------------------------+
                                   |
                         OCI Runtime Spec Execution
                                   v
+-------------------------------------------------------------------------------+
| OCI Runtime Shim (containerd-shim-runc-v2 / containerd-shim-runsc-v1)         |
+-------------------------------------------------------------------------------+
                                   |
                Direct Kernel Syscall Interception / Execution
                                   v
  +--------------------------+    +--------------------------+    +--------------------------+
  |      Standard OCI        |    |     User-Space Kernel    |    |     MicroVM Sandbox      |
  |     (runc / crun)        |    |     (gVisor / runsc)     |    |    (Kata Containers)     |
  | Shared Host Kernel       |    | Syscall Interception     |    | Dedicated Guest Kernel   |
  | Namespaces + Cgroups     |    | Sentry/Gofer Isolation   |    | QEMU/Cloud-Hypervisor    |
  +--------------------------+    +--------------------------+    +--------------------------+
```

### Key Components & Mechanics
1. **CRI Runtime (`containerd` / `CRI-O`)**: Manages pod lifecycle, container state, image pulling, and namespace attachment. Communicates with Kubelet over a local Unix domain socket using standard gRPC endpoints defined in the CRI API (`RuntimeService` and `ImageService`).
2. **OCI Runtime (`runc`, `crun`)**: Lightweight CLI tool that interprets the OCI `config.json` standard specification to configure Linux namespaces (`pid`, `net`, `mnt`, `ipc`, `uts`, `user`, `cgroup`), cgroups (v1 or v2), capabilities, seccomp filters, and execution binaries.
3. **OCI Shim (`containerd-shim-v2`)**: A daemonless process bound to each running pod/container that holds file descriptors (`stdio`), tracks process exit status, and isolates `containerd` restarts from running container processes.
4. **Sandboxed Runtimes (`gVisor`, `Kata Containers`)**:
   - **gVisor (`runsc`)**: Implements an in-process user-space kernel ("Sentry") written in Go that intercepts container syscalls. It prevents untrusted application code from directly reaching the underlying host Linux kernel.
   - **Kata Containers**: Runs each Kubernetes Pod inside a dedicated lightweight Virtual Machine (MicroVM) using hardware-assisted virtualization (KVM). It provides strong hypervisor boundary isolation with a dedicated guest Linux kernel.

---

## 2. Guided Production Exercises

---

### Exercise 1: CRI Communication Interception and Engine Hardening

**Objective:** Inspect raw gRPC CRI operations using `crictl`, configure containerd plugin isolation rules, and analyze default OCI runtime behaviors.

#### Step 1.1: Inspect the local CRI socket and list active runtime pods
Execute `crictl` directly against the node's unix domain socket to inspect container engine internals without passing through Kubelet API abstraction.

```bash
# Set the default runtime endpoint for crictl
export CONTAINER_RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock"

# Verify CRI system info and status
sudo crictl info
```

**Expected Output:**
```json
{
  "status": {
    "conditions": [
      {
        "type": "RuntimeReady",
        "status": true
      },
      {
        "type": "NetworkReady",
        "status": true
      }
    ]
  },
  "cniselfservice": "true",
  "config": {
    "containerd": {
      "defaultRuntimeName": "runc"
    }
  }
}
```

#### Step 1.2: Inspect container process tree and shim association
Locate a running container process on the host OS and observe how `containerd-shim-runc-v2` parents the container process.

```bash
# Get PID of a running container via crictl
CONTAINER_ID=$(sudo crictl ps --state Running -q | head -n 1)
HOST_PID=$(sudo crictl inspect $CONTAINER_ID | jq '.info.pid')

echo "Container ID: ${CONTAINER_ID} mapped to Host PID: ${HOST_PID}"

# Trace process tree hierarchy on host
pstree -ps ${HOST_PID}
```

**Expected Output:**
```
systemd(1)---containerd(1240)---containerd-shim(8920)---nginx(9102)---nginx(9145)
```

#### Step 1.3: Audit containerd security configuration for default OCI flags
Inspect `/etc/containerd/config.toml` to verify if standard security handlers and cgroup drivers are set to systemd.

```bash
# View containerd CRI plugin configuration
sudo containerd config dump | grep -A 15 "\[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc\]"
```

**Expected Output:**
```toml
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          base_runtime_spec = ""
          cgroup_writable = false
          container_annotations = []
          pod_annotations = []
          privileged_without_host_devices = false
          runtime_engine = ""
          runtime_path = ""
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            BinaryName = ""
            CgroupParent = ""
            CriuPath = ""
            EnableTty = false
            NoPivotRoot = false
            NoNewKeyring = false
            SystemdCgroup = true
```

---

#### Verification Questions (Exercise 1)

1. **Question:** What is the critical security hazard of setting `NoPivotRoot = true` in the OCI runtime options within `/etc/containerd/config.toml`?
2. **Question:** Why does `containerd` spawn a unique `containerd-shim-runc-v2` binary for every Pod sandbox rather than having the main `containerd` daemon parent the container processes directly?

---

### Exercise 2: Implementing MicroVM & User-Space Sandboxing via `RuntimeClass`

**Objective:** Configure `containerd` to support `gVisor` (`runsc`) as a secondary runtime handler, declare a Kubernetes `RuntimeClass`, and deploy a workload to verify syscall isolation.

#### Step 2.1: Add gVisor (`runsc`) runtime handler to containerd configuration
Create a snippet configuration or append the `runsc` handler definition to `/etc/containerd/config.toml`.

```bash
# Append runsc configuration to containerd config
sudo tee -a /etc/containerd/config.toml << 'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"
EOF

# Restart containerd service to apply runtime registration
sudo systemctl restart containerd
```

#### Step 2.2: Create the Kubernetes `RuntimeClass` manifest
Apply the cluster-scoped `RuntimeClass` resource targeting the handler registered in `containerd`.

```yaml
# File: runtime-class-gvisor.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
scheduling:
  nodeSelector:
    sandbox.type/gvisor: "true"
tolerations:
  - key: "sandbox.type/gvisor"
    operator: "Exists"
    effect: "NoSchedule"
---
```

Apply manifest:
```bash
kubectl apply -f runtime-class-gvisor.yaml
```

#### Step 2.3: Deploy a Pod assigned to the sandboxed `RuntimeClass`
Deploy an untrusted workload that requests the `gvisor` runtime.

```yaml
# File: sandboxed-workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-workload
  namespace: default
spec:
  runtimeClassName: gvisor
  containers:
  - name: untrusted-app
    image: alpine:3.19
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
      capabilities:
        drop:
        - ALL
```

Apply manifest:
```bash
kubectl apply -f sandboxed-workload.yaml
```

#### Step 2.4: Validate Kernel isolation inside the sandboxed container
Execute `uname -a` and inspect dmesg logs inside the container to confirm kernel redirection by gVisor Sentry.

```bash
# Execute uname inside standard pod vs gvisor pod
kubectl exec untrusted-workload -- uname -a
```

**Expected Output:**
```
Linux untrusted-workload 4.4.0-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 Linux
```
*(Notice the static fake kernel version `4.4.0-gVisor` returned by Sentry, proving the workload is decoupled from host kernel version details)*.

---

#### Verification Questions (Exercise 2)

1. **Question:** If an application running inside a gVisor-sandboxed pod attempts to execute an unsupported Linux syscall, what happens at the architecture level?
2. **Question:** What are the key performance trade-offs when selecting a user-space kernel (gVisor `runsc`) versus a hardware MicroVM (Kata Containers) versus default OCI (`runc`)?

---

### Exercise 3: Advanced Syscall Restriction via Custom Seccomp Profiles

**Objective:** Write a custom, restrictive Seccomp profile in JSON, install it across cluster nodes, attach it using Kubernetes `securityContext`, and verify blocked execution using `strace` / `bpftrace`.

#### Step 3.1: Create a restrictive custom Seccomp JSON profile
Save this custom profile to the Kubelet root directory on the node: `/var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json`.

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
        "write",
        "writev",
        "read",
        "close",
        "fstat",
        "mmap",
        "mprotect",
        "munmap",
        "brk",
        "rt_sigaction",
        "rt_sigprocmask",
        "execve",
        "arch_prctl"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

Copy file to target location:
```bash
sudo mkdir -p /var/lib/kubelet/seccomp/profiles/
sudo cp fine-grained-restrictive.json /var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json
```

#### Step 3.2: Deploy a Pod referencing the Localhost Seccomp Profile
Create a manifest enforcing the custom seccomp profile.

```yaml
# File: hardened-seccomp-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-seccomp-pod
  namespace: default
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/fine-grained-restrictive.json
  containers:
  - name: hardened-container
    image: alpine:3.19
    command: ["/bin/sh", "-c", "echo Application Started; sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 10002
      capabilities:
        drop:
        - ALL
```

Apply manifest:
```bash
kubectl apply -f hardened-seccomp-pod.yaml
```

#### Step 3.3: Verify execution failure on unauthorized syscalls
Attempt to execute a binary inside the pod that issues unallowed syscalls (e.g., `mkdir` or `chown`).

```bash
# Attempt unauthorized syscall
kubectl exec hardened-seccomp-pod -- mkdir /tmp/test-dir
```

**Expected Output:**
```
command terminated with exit code 1
mkdir: cannot create directory '/tmp/test-dir': Operation not permitted
```

#### Step 3.4: Diagnose blocked syscall via Kernel Audit Logs
Inspect host system audit logs to identify the exact blocked syscall number.

```bash
# Query auditd / dmesg logs for audit SECCOMP events
sudo journalctl -k --grep="SECCOMP" | tail -n 5
```

**Expected Output:**
```
Audit: type=1326 audit(1710001200.412:981): auid=4294967295 uid=10002 gid=10002 ses=4294967295 pid=14201 comm="mkdir" exe="/bin/mkdir" sig=0 arch=c000003e syscall=83 compat=0 ip=0x7f8a1012a417 code=0x050000
```
*(Here `syscall=83` corresponds to `mkdir` on x86_64, which was denied with `SCMP_ACT_ERRNO`)*.

---

#### Verification Questions (Exercise 3)

1. **Question:** What is the difference between `defaultAction: "SCMP_ACT_ERRNO"` and `defaultAction: "SCMP_ACT_KILL"` in production Seccomp security design?
2. **Question:** How does Kubelet map the path defined in `localhostProfile: profiles/fine-grained-restrictive.json` to the host filesystem path?

---

### Exercise 4: Mandatory Access Control via AppArmor Profile Enforcement

**Objective:** Write, load, and enforce an AppArmor profile on host nodes to restrict container filesystem access, network sockets, and execution privileges.

#### Step 4.1: Write an AppArmor Security Profile on Node
Define an AppArmor profile preventing write access to `/etc` and restricting binary execution.

```apparmor
# File: /etc/apparmor.d/k8s-deny-etc-write
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow read access to standard system paths
  /usr/bin/* ix,
  /bin/* ix,
  /lib/* mr,
  /lib64/* mr,

  # Explicitly deny write access to /etc directory and subpaths
  deny /etc/** w,

  # Allow read access to /etc
  /etc/** r,
}
```

#### Step 4.2: Load profile into Linux Kernel AppArmor engine
Parse and parse-load the profile using `apparmor_parser`.

```bash
# Load profile into kernel
sudo apparmor_parser -q -r /etc/apparmor.d/k8s-deny-etc-write

# Verify profile is active in kernel memory
sudo aa-status | grep k8s-deny-etc-write
```

**Expected Output:**
```
   k8s-deny-etc-write
```

#### Step 4.3: Deploy Pod enforcing the custom AppArmor Profile
Attach the profile via standard Kubernetes `securityContext` (`appArmorProfile`).

```yaml
# File: apparmor-restricted-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-restricted-pod
  namespace: default
spec:
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-etc-write
  containers:
  - name: restricted-app
    image: alpine:3.19
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
```

Apply manifest:
```bash
kubectl apply -f apparmor-restricted-pod.yaml
```

#### Step 4.4: Validate mandatory access control enforcement
Attempt writing to `/etc/test.conf` from inside the pod.

```bash
kubectl exec apparmor-restricted-pod -- touch /etc/test.conf
```

**Expected Output:**
```
touch: /etc/test.conf: Permission denied
```

---

#### Verification Questions (Exercise 4)

1. **Question:** What is the functional difference between AppArmor enforce mode vs complain mode, and how do SRE teams safely roll out new AppArmor profiles to high-traffic production workloads?
2. **Question:** In a multi-node Kubernetes cluster, what mechanism guarantees that a Pod specifying `localhostProfile: k8s-deny-etc-write` is scheduled only onto nodes where the profile is already loaded in kernel space?

---

## 3. Verification Answers & Diagnostic Explanations

<details>
<summary><strong>Click to view Answers and Technical Explanations</strong></summary>

### Exercise 1 Answers

1. **Answer (NoPivotRoot security hazard):**
   - **Mechanics:** In OCI runtimes (`runc`), `pivot_root` changes the root mount namespace of the container process so it cannot see or traverse to the host system filesystem. Setting `NoPivotRoot = true` forces `runc` to use `chroot` instead of `pivot_root`.
   - **Security Risk:** `chroot` does not modify the mount table or isolate the mount namespace completely. A process inside the container with `CAP_SYS_CHROOT` or root capabilities can break out of `chroot` using open file descriptors pointing outside the chroot (e.g., standard `fchdir` exploit loops), leading to total host filesystem compromise.

2. **Answer (Shim Architecture rationale):**
   - **Mechanics:** The `containerd-shim-v2` daemon acts as a lightweight supervisor for a single Pod sandbox.
   - **Rationale:**
     1. **Daemonless Maintenance:** If `containerd` main daemon crashes or undergoes a zero-downtime binary upgrade, container processes remain running uninterrupted because their parent process is the shim, not `containerd`.
     2. **File Descriptor Isolation:** Holds container `stdin`, `stdout`, and `stderr` pipes open across daemon restarts.
     3. **Exit Code Propagation:** Captures container exit codes and reports them asynchronously back to CRI upon request.

---

### Exercise 2 Answers

1. **Answer (gVisor unsupported syscall behavior):**
   - **Mechanics:** When an application executes an unsupported or unimplemented syscall in gVisor, the call is intercepted by the user-space **Sentry** process.
   - **Behavior:** The Sentry does not forward the call to the host kernel. Instead, it directly returns `ENOSYS` (Function not implemented) or `EPERM` to the container process within user-space. This prevents zero-day kernel exploits via unvetted kernel code paths.

2. **Answer (Runtime Trade-off Analysis):**

| Feature | Default OCI (`runc` / `crun`) | User-Space Kernel (`gVisor`) | MicroVM (`Kata Containers`) |
| :--- | :--- | :--- | :--- |
| **Isolation Boundary** | Shared Linux Kernel (Namespaces + Cgroups) | User-space Syscall Interception (Sentry) | Dedicated Hardware Virtualization (KVM Guest Kernel) |
| **Attack Surface** | High (Direct access to ~350+ host syscalls) | Minimal (Host syscalls reduced to ~50) | Minimal (Hypervisor boundary protects host kernel) |
| **Startup Overhead** | Extremely Low (~10ms) | Low (~50-100ms) | Moderate to High (~500ms - 2s) |
| **Memory Footprint** | Minimal (~5-10MB overhead) | Low (~15-30MB Sentry memory) | Higher (~100MB+ for Guest Kernel + QEMU) |
| **I/O & Network Performance** | Near-native speed | Moderate overhead (Context switches in Go Sentry) | Near-native with vhost-user / SR-IOV pass-through |
| **Primary Production Use Case** | Trusted internal workloads | Untrusted multi-tenant microservices / Webhooks | Multi-tenant SaaS, untrusted code execution |

---

### Exercise 3 Answers

1. **Answer (`SCMP_ACT_ERRNO` vs `SCMP_ACT_KILL`):**
   - **`SCMP_ACT_ERRNO`:** Returns an error code (such as `EPERM`) to the requesting process when a restricted syscall occurs. The process catches the error and can fail gracefully, log a error message, or take alternative execution paths. Recommended for initial testing and resilient production applications.
   - **`SCMP_ACT_KILL` / `SCMP_ACT_KILL_PROCESS`:** Immediately terminates the entire thread or process group at the kernel level without returning an error.
   - **Production Design Trade-off:** `SCMP_ACT_KILL` provides absolute zero-tolerance security (stopping an attacker mid-exploit), but can lead to unhandled application crashes or crash loops if a rare, legitimate syscall is invoked.

2. **Answer (Kubelet Seccomp Path Mapping):**
   - **Mechanics:** Kubelet resolves relative seccomp profile paths relative to its configured root seccomp directory: `--seccomp-profile-root` (which defaults to `/var/lib/kubelet/seccomp`).
   - Therefore, `localhostProfile: profiles/fine-grained-restrictive.json` expands strictly on the node node filesystem to `/var/lib/kubelet/seccomp/profiles/fine-grained-restrictive.json`. Path traversal out of this root directory using `..` is blocked by Kubelet.

---

### Exercise 4 Answers

1. **Answer (AppArmor Rollout Strategy):**
   - **Enforce Mode:** Blocks unauthorized actions matching `deny` rules or lacking `allow` rules, logging violations to auditd.
   - **Complain Mode:** Permits unauthorized actions but logs a warning to the kernel log (`dmesg` / `auditd`).
   - **SRE Safe Rollout Strategy:**
     1. Deploy profile in **Complain Mode** (`aa-complain /etc/apparmor.d/k8s-profile`).
     2. Run full integration testing and synthetic production traffic against the workload.
     3. Collect and parse audit logs using `aa-logprof` to discover all legitimate filesystem and binary execution events.
     4. Refine rules and convert the profile to **Enforce Mode** (`aa-enforce`) in production.

2. **Answer (Cluster Scheduling Enforcement for Profiles):**
   - **Problem:** If a Pod requests an AppArmor profile that does not exist on the node selected by `kube-scheduler`, the container engine fails to start the container (`CreateContainerError`).
   - **Solution:** Native Kubernetes `kube-scheduler` does not automatically check profile presence on nodes. Production platforms enforce scheduling alignment using:
     1. Node Labeling + `nodeSelector` / `nodeAffinity` (as shown in Exercise 2 for RuntimeClasses).
     2. DaemonSets that ensure profile distribution across 100% of cluster nodes prior to scheduling workloads (e.g., using **Security Profiles Operator**).
     3. Admission Controllers (like Kyverno or OPA Gatekeeper) that validate node readiness or mutate node affinity based on requested security profiles.

</details>