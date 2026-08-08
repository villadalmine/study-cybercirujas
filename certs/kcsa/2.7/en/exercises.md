# KCSA Study Guide: Domain 2.7 - Pod Security

**Exam**: CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain**: Kubernetes Security / Workload Security  
**Topic**: 2.7 Pod  
**Weight**: 2.0%  
**Official Reference**: [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)  
**Official Documentation**:
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Linux Capabilities Manual (capabilities(7))](https://man7.org/linux/man-pages/man7/capabilities.7.html)

---

## Technical Deep-Dive & Architectural Overview

In Kubernetes security architecture, a **Pod** is not a runtime binary itself, but an abstraction over a group of Linux containers sharing Linux kernel namespaces, cgroups, and storage volumes. Security boundaries for Pods depend directly on the configuration of container runtime primitives and API-level admission control policies.

```
+-----------------------------------------------------------------------------------------+
|                                    KUBERNETES NODE                                       |
|                                                                                         |
|  +-----------------------------------------------------------------------------------+  |
|  |                                  POD BOUNDARY                                     |  |
|  |  [ Pause Container ] ---> Holds shared Network, IPC, and UTS Namespaces           |  |
|  |                                                                                   |  |
|  |  +-------------------------------------+  +------------------------------------+  |  |
|  |  | App Container                       |  | Sidecar Container                  |  |  |
|  |  |  - Mount Namespace (OverlayFS)      |  |  - Mount Namespace (OverlayFS)     |  |  |
|  |  |  - PID Namespace (isolated/shared)  |  |  - PID Namespace (isolated/shared) |  |  |
|  |  |  - SecurityContext (Capabilities,   |  |  - SecurityContext                 |  |  |
|  |  |    Seccomp, UID/GID, no_new_privs)  |  |                                    |  |  |
|  +--+-------------------------------------+--+------------------------------------+--+  |
|                                                                                         |
|  Kernel Enforcement Layer:                                                              |
|  - Cgroups v2 (CPU, Memory, PIDs isolation)                                             |
|  - Seccomp BPF (Syscall filtering)                                                      |
|  - AppArmor / SELinux (Mandatory Access Control)                                        |
|  - Capability Bounding Set (Kernel Privileges Bitmask)                                  |
+-----------------------------------------------------------------------------------------+
```

### 1. Linux Kernel Isolation Primitives in Kubernetes

- **Namespaces**: Provide resource isolation. By default, Pods share `net` (Network), `ipc` (Inter-Process Communication), and `uts` (Hostname) namespaces via the infra/pause container. `mnt` (Mount) and `pid` (Process ID) namespaces are container-isolated by default unless `shareProcessNamespace: true` or `hostPID: true` is configured.
- **Linux Capabilities**: Thread-level privileges that break root power into distinct units (e.g., `CAP_NET_BIND_SERVICE`, `CAP_SYS_ADMIN`). Setting `capabilities.drop: ["ALL"]` strips all 41+ kernel capabilities from the process capability set (`CapPrm`, `CapEff`, `CapBnd`).
- **`allowPrivilegeEscalation: false`**: Invokes the Linux `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` system call during container creation. This prevents setuid binaries (e.g., `/usr/bin/sudo` or custom setuid binaries) from acquiring elevated permissions across `execve()` execution calls.
- **`readOnlyRootFilesystem: true`**: Mounts the container overlayfs root filesystem as read-only (`ro`). Modifying binaries, dropping WebShells, or editing `/etc` fails with `Read-only file system (errno 30)`.
- **Seccomp (Secure Computing Mode)**: Restricts executable system calls using eBPF filters. Setting `seccompProfile.type: RuntimeDefault` enables container runtime profiles (Containerd/CRI-O) that block dangerous syscalls such as `unshare`, `kexec_load`, `sys_ptrace`, and `reboot`.

### 2. Pod Security Admission (PSA) & Pod Security Standards (PSS)

Kubernetes native Pod Security Admission (PSA) enforces Pod Security Standards (PSS) at the namespace level via standard labels.

| Level | Purpose | Forbidden Features |
| :--- | :--- | :--- |
| **Privileged** | Unrestricted execution. Operational infrastructure (CNIs, storage drivers). | None (full node access possible). |
| **Baseline** | Default non-privileged workloads. Prevents known privilege escalations. | `hostNetwork`, `hostPID`, `hostIPC`, `hostPort`, `privileged: true`, dangerous capabilities (`CAP_SYS_ADMIN`), custom `sysctls`, `hostPath` volumes. |
| **Restricted** | Hardened best-practice workloads. Enforces least privilege. | Requires `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile` defined (`RuntimeDefault`/`Localhost`), restricts volume types to standard config/secret/emptyDir. |

PSA evaluates Pods using three operational **modes**:
1. `enforce`: Rejects API creation of non-compliant Pods immediately.
2. `audit`: Allows creation but logs violations to the Kubernetes API Audit log.
3. `warn`: Allows creation but returns user-facing warning headers to `kubectl` or clients.

---

## Lab Setup Instructions

Execute all commands in a running Kubernetes v1.26+ cluster (e.g., `kind`, `minikube`, or a cloud control plane).

```bash
# Verify cluster connection and node readiness
kubectl get nodes -o wide
```

Expected output:
```text
NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
kind-control-plane   Ready    control-plane   5m    v1.30.0   172.18.0.2    <none>        Ubuntu 22.04.4 LTS   5.15.0-101-generic   containerd://1.7.15
```

---

## Guided Exercise 1: Hardening Pod SecurityContext Architecture

In this exercise, you will construct a fully compliant Pod manifest adhering to the **Restricted** Pod Security Standard, apply it to the cluster, and inspect container kernel parameters from inside the execution context.

### Step 1.1: Create the Hardened Pod Manifest

Create a manifest named `hardened-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: default
  labels:
    app.kubernetes.io/name: secure-workload
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web-app
    image: cimg/base:2024.01
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
        add:
        - NET_BIND_SERVICE
    volumeMounts:
    - name: tmp-dir
      mountPath: /tmp
  volumes:
  - name: tmp-dir
    emptyDir: {}
```

### Step 1.2: Apply and Verify Execution Context

Deploy the manifest and inspect the container execution parameters.

```bash
# Apply the manifest
kubectl apply -f hardened-pod.yaml

# Wait for Pod to enter Running state
kubectl wait --for=condition=Ready pod/secure-workload --timeout=30s
```

Expected output:
```text
pod/secure-workload created
pod/secure-workload condition met
```

### Step 1.3: Inspect Kernel Privilege Bitmasks and Filesystem Restrictions

Run diagnostic commands inside the container to verify UID, capability bounding sets, and root filesystem write protections.

```bash
# Verify execution identity (UID/GID)
kubectl exec -it secure-workload -- id

# Test write protection on root filesystem
kubectl exec -it secure-workload -- touch /etc/test-write

# Test write permissions on explicit emptyDir mount
kubectl exec -it secure-workload -- touch /tmp/test-write

# Inspect process capabilities bitmask in /proc/1/status
kubectl exec -it secure-workload -- grep -E 'Cap(Inh|Prm|Eff|Bnd)' /proc/1/status
```

Expected output:
```text
uid=10001 gid=10001 groups=10001
touch: cannot touch '/etc/test-write': Read-only file system
CapInh: 0000000000000000
CapPrm: 0000000000000400
CapEff: 0000000000000400
CapBnd: 0000000000000400
```

> **Kernel Detail**: `0000000000000400` represents the hex bitmask for `CAP_NET_BIND_SERVICE` (bit 10). All other Linux capabilities (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE`, etc.) have been completely stripped.

---

### Questions (Block 1)

1. Why must an `emptyDir` volume be explicitly mounted to `/tmp` in `hardened-pod.yaml` when `readOnlyRootFilesystem: true` is configured?
2. What specific kernel call is performed when setting `allowPrivilegeEscalation: false`, and what security vector does it prevent?

---

## Guided Exercise 2: Enforcing Pod Security Admission (PSA) at Namespace Scope

In this exercise, you will configure Pod Security Admission standards using namespace labeling, evaluate how PSA enforces compliance, and analyze API server rejection messages.

### Step 2.1: Prepare Namespaces with PSS Labels

Create two separate namespaces: one configured with `warn` and `audit` modes, and another with strict `enforce` mode.

```bash
# Create namespaces
kubectl create namespace psa-warn-lab
kubectl create namespace psa-enforce-lab

# Label psa-warn-lab to trigger warnings and audit records for non-restricted Pods
kubectl label --overwrite namespace psa-warn-lab \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest

# Label psa-enforce-lab to hard-reject non-restricted Pods
kubectl label --overwrite namespace psa-enforce-lab \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Verify labels applied:

```bash
kubectl get ns --show-labels | grep psa-
```

Expected output:
```text
psa-enforce-lab   Active   20s   kubernetes.io/metadata.name=psa-enforce-lab,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/enforce-version=latest
psa-warn-lab      Active   25s   kubernetes.io/metadata.name=psa-warn-lab,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/audit-version=latest,pod-security.kubernetes.io/warn=restricted,pod-security.kubernetes.io/warn-version=latest
```

### Step 2.2: Test Workload Submissions Against PSA Warn Mode

Create a non-compliant workload manifest named `unsecure-deployment.yaml`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-nginx
  namespace: psa-warn-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-nginx
  template:
    metadata:
      labels:
        app: legacy-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
```

Deploy to the `psa-warn-lab` namespace and monitor terminal output:

```bash
kubectl apply -f unsecure-deployment.yaml
```

Expected output:
```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), uncontrolled capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/legacy-nginx created
```

Notice that the Deployment was **created**, but the API server issued a detailed warning response detailing every rule failure under the `restricted` standard.

### Step 2.3: Test Workload Submissions Against PSA Enforce Mode

Now attempt to create the identical non-compliant Pod resource directly in the `psa-enforce-lab` namespace.

```bash
# Attempt direct Pod creation in enforcement namespace
kubectl run test-unsecure --image=nginx:1.25 -n psa-enforce-lab
```

Expected output:
```text
Error from server (Forbidden): pods "test-unsecure" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), uncontrolled capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### Step 2.4: Analyze Controller Behavior (Deployments vs Direct Pods)

Now attempt to deploy the `unsecure-deployment.yaml` manifest inside `psa-enforce-lab`.

```bash
# Modify namespace target to psa-enforce-lab and apply
sed 's/namespace: psa-warn-lab/namespace: psa-enforce-lab/' unsecure-deployment.yaml | kubectl apply -f -

# Inspect the Deployment status
kubectl get deployment legacy-nginx -n psa-enforce-lab

# Inspect the ReplicaSet events
kubectl get rs -n psa-enforce-lab
kubectl describe rs -n psa-enforce-lab
```

Expected output for `kubectl get rs -n psa-enforce-lab`:
```text
NAME                            DESIRED   CURRENT   READY   AGE
legacy-nginx-7854ff8877         1         0         0       12s
```

Expected output snippet for `kubectl describe rs -n psa-enforce-lab`:
```text
Events:
  Type     Reason        Age        From                   Message
  ----     ------        ----       ----                   -------
  Warning  FailedCreate  4s (x4 over 12s)  replicaset-controller  (combined from similar events): Failed create pod pod-template-7854ff8877-xxxxx: pods "legacy-nginx-7854ff8877-xxxxx" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false ...
```

---

### Questions (Block 2)

3. Why did `kubectl apply -f unsecure-deployment.yaml` return `deployment.apps/legacy-nginx created` successfully in `psa-enforce-lab`, yet no Pods ever ran? Where did the enforcement failure take place in the Kubernetes control plane workflow?
4. How does setting `pod-security.kubernetes.io/enforce-version: v1.28` differ from setting `pod-security.kubernetes.io/enforce-version: latest`? What production operational risk does `latest` introduce during cluster upgrades?

---

## Guided Exercise 3: Low-Level Node Diagnostics & Runtime Container Inspection

In this exercise, you will inspect low-level container isolation primitives directly on the worker node using `crictl`, `/proc` filesystem introspection, and `sysctl` security boundary checks.

### Step 3.1: Locate Container ID on the Worker Node

Identify the runtime container ID of the `secure-workload` Pod created in Exercise 1.

```bash
# Obtain Pod container ID via JSONPath
POD_CID=$(kubectl get pod secure-workload -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's/containerd:\/\///')
echo "Container Runtime ID: ${POD_CID}"
```

Expected output:
```text
Container Runtime ID: 7f8a9b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a
```

### Step 3.2: Inspect Node-Level Seccomp and Namespace Settings via `crictl`

If you are using `kind`, open a shell into the control-plane/worker node:

```bash
# SSH / Exec into the node (kind example)
docker exec -it kind-control-plane bash

# Inside the node: Inspect container runtime status using crictl
crictl inspect <CONTAINER_ID> | grep -A 15 "security_context"
```

Expected output snippet:
```json
        "security_context": {
          "privileged": false,
          "readonly_rootfs": true,
          "capabilities": {
            "add": [
              "CAP_NET_BIND_SERVICE"
            ]
          },
          "seccomp": {
            "profile_type": "RuntimeDefault"
          },
          "run_as_user": {
            "value": 10001
          },
          "run_as_group": {
            "value": 10001
          }
        }
```

### Step 3.3: Verify Process Seccomp Mode in Host Kernel

Find the Host PID (HPID) of the workload and check `/proc/<HPID>/status`.

```bash
# Inside the node: Find Host PID of the process sleeping in the container
HPID=$(crictl inspect <CONTAINER_ID> | grep '"pid":' | head -n 1 | awk '{print $2}' | tr -d ',')
echo "Host PID: ${HPID}"

# Check Seccomp mode in kernel process table
grep -E 'Seccomp|NoNewPrivs' /proc/${HPID}/status
```

Expected output:
```text
NoNewPrivs:     1
Seccomp:        2
Seccomp_filters:        1
```

> **Kernel Technical Note**: 
> - `NoNewPrivs: 1` confirms `prctl(PR_SET_NO_NEW_PRIVS)` is active.
> - `Seccomp: 2` indicates `SECCOMP_MODE_FILTER` is enabled (system calls restricted via BPF filter). Mode `0` means disabled, Mode `1` means strict.

---

### Questions (Block 3)

5. If a container process attempts to invoke a forbidden system call (e.g., `unshare` or `kexec_load`) under `Seccomp: 2` with `RuntimeDefault`, what kernel signal or action is delivered to the process by default?
6. In a multi-tenant node scenario, what security vulnerability arises if a Pod manifest sets `hostIPC: true` or `hostPID: true`, and how does the Pod Security Standard `baseline` profile prevent this?

---

<details>
<summary><strong>Click to expand Solution Key & Comprehensive Technical Answers</strong></summary>

### Exercise 1 Answer Key

#### 1. Why must an `emptyDir` volume be explicitly mounted to `/tmp` in `hardened-pod.yaml` when `readOnlyRootFilesystem: true` is configured?
* **Explanation**: When `readOnlyRootFilesystem: true` is set in the container's `securityContext`, the container runtime mounts the root overlayfs read-only (`ro`). Applications, runtime libraries, and standard Linux utilities frequently require writing temporary files, lockfiles, or socket files to default locations like `/tmp`, `/var/tmp`, or `/run`. If these directories are read-only, application processes fail immediately with `Errno 30 (Read-only file system)`.
* Mounting an `emptyDir` volume over `/tmp` creates a dedicated, ephemeral writeable volume (backed by the node's disk or RAM if `medium: Memory` is specified) anchored specifically at `/tmp`. This maintains the immutability of the container image binaries and system files while providing isolated memory/disk space for legitimate application transient writes.

#### 2. What specific kernel call is performed when setting `allowPrivilegeEscalation: false`, and what security vector does it prevent?
* **Explanation**: Setting `allowPrivilegeEscalation: false` instructs the container runtime to issue the Linux system call `prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)` prior to executing the container entrypoint process.
* **Security Vector Mitigated**: It prevents set-user-ID (SUID) and set-group-ID (SGID) binary bits and file capabilities from granting elevated privileges across `execve()` system calls. If an attacker gains shell execution or leverages a local vulnerability inside the container, they cannot exploit binaries with the `s` attribute bit (such as `/usr/bin/sudo`, `/bin/mount`, or custom SUID binaries) to elevate execution privileges to `root` (UID 0).

---

### Exercise 2 Answer Key

#### 3. Why did `kubectl apply -f unsecure-deployment.yaml` return `deployment.apps/legacy-nginx created` successfully in `psa-enforce-lab`, yet no Pods ever ran? Where did the enforcement failure take place in the Kubernetes control plane workflow?
* **Explanation**: In Kubernetes, a `Deployment` is a higher-level resource managed asynchronously by the `deployment-controller` inside `kube-controller-manager`. 
* When you submit a Deployment manifest, the `kube-apiserver` validates the Deployment object itself. Pod Security Admission (PSA) validates **Pod** specs, not Deployment specs directly. Therefore, the API server accepts and persists the Deployment object to `etcd`.
* Subsequently, the `deployment-controller` creates a `ReplicaSet`. The `replicaset-controller` then attempts to create individual `Pod` instances. When the ReplicaSet sends the child `Pod` creation request to the API server, the API server's `PodSecurity` admission webhook intercepts the Pod creation request. Because `psa-enforce-lab` has `pod-security.kubernetes.io/enforce=restricted`, the admission plugin evaluates the Pod spec, detects policy violations (`runAsNonRoot`, `allowPrivilegeEscalation`, `capabilities`, `seccompProfile`), and **rejects** the Pod creation request with a `403 Forbidden` API error.
* The failure is recorded as a `FailedCreate` event on the `ReplicaSet` object.

#### 4. How does setting `pod-security.kubernetes.io/enforce-version: v1.28` differ from setting `pod-security.kubernetes.io/enforce-version: latest`? What production operational risk does `latest` introduce during cluster upgrades?
* **Explanation**: 
  - Specifying a fixed version (e.g., `v1.28`) locks the Pod Security Standards evaluation rules to the policy definitions compiled into Kubernetes version 1.28.
  - Specifying `latest` instructs the Pod Security Admission controller to evaluate Pods against the newest PSS rules supported by the currently running `kube-apiserver`.
* **Production Operational Risk**: As Kubernetes evolves, new security controls, checks, or stricter checks may be added to the `baseline` or `restricted` PSS profiles in newer Kubernetes minor releases. If a namespace is pinned to `latest`, upgrading the control plane (e.g., from `v1.28` to `v1.30`) may suddenly cause existing, previously compliant Pod workloads or new Deployment rollouts to fail admission control if a newly introduced policy check invalidates their current manifest configuration. Pinned versions ensure deterministic workload admission across cluster version upgrades.

---

### Exercise 3 Answer Key

#### 5. If a container process attempts to invoke a forbidden system call (e.g., `unshare` or `kexec_load`) under `Seccomp: 2` with `RuntimeDefault`, what kernel signal or action is delivered to the process by default?
* **Explanation**: When Seccomp filtering is active in mode 2 (`SECCOMP_MODE_FILTER`), the Linux kernel evaluates every syscall made by the thread against the loaded BPF filter program.
* For system calls blocked by the `RuntimeDefault` profile, the default seccomp action rule returns `-EPERM` (Operation not permitted, `errno 1` or `errno 13`) or fires a `SIGSYS` (Bad system call) signal to the process thread.
* Most container runtimes configure default action `SECCOMP_RET_ERRNO` (returning `-EPERM`). The process attempting the forbidden syscall receives an immediate permission error without the system call reaching the underlying host kernel subsystem, neutralizing kernel privilege escalation and escape exploits.

#### 6. In a multi-tenant node scenario, what security vulnerability arises if a Pod manifest sets `hostIPC: true` or `hostPID: true`, and how does the Pod Security Standard `baseline` profile prevent this?
* **Explanation**:
  - `hostPID: true` causes the container process to share the host node's primary Process ID namespace. A user inside the container can see all processes running on the host node (including host daemon processes like `kubelet`, `containerd`, and processes from other Pods running on the same node). They can send signals (`SIGKILL`, `SIGTERM`), inspect memory via `/proc/<PID>/mem`, or attach debuggers (`ptrace`) to host-level processes.
  - `hostIPC: true` shares the host's Inter-Process Communication namespace. This allows the container process to access System V IPC mechanisms and POSIX shared memory segments (`/dev/shm`) used by host processes or other co-located Pods, exposing shared memory data to unauthorized access or tampering.
* **Baseline PSS Prevention**: The `baseline` Pod Security Standard explicitly forbids both `spec.hostPID: true` and `spec.hostIPC: true` fields. When `baseline` enforcement is active, the PSA admission plugin intercepts any Pod spec requesting `hostPID` or `hostIPC` and rejects creation immediately at the API server boundary.

</details>