# KCSA Study Guide: Topic 2.7 – Pod Security Architecture & Hardening

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Topic 2.7:** Pod  
**Exam Weight:** 2.0%  

---

## 1. Production Architectural Motivation & Threat Model

In Kubernetes, the **Pod** is the smallest deployable execution unit. Architecturally, a Pod is not a single process or OS-level virtual machine, but a co-located group of Linux containers sharing kernel namespaces and IPC resources.

```
+-----------------------------------------------------------------------------------+
| Linux Worker Node (Host Kernel)                                                   |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | Pod Isolation Boundary                                                      |  |
|  |                                                                             |  |
|  | Shared Namespaces: Network (netns), IPC (ipcns), UTS (utsns)                |  |
|  | Shared Storage: Volumes (Mount Points)                                      |  |
|  |                                                                             |  |
|  |  +---------------------------+       +-----------------------------------+  |  |
|  |  | Container A (App)         |       | Container B (Sidecar)             |  |  |
|  |  |                           |       |                                   |  |  |
|  |  | Isolated Namespaces:      |       | Isolated Namespaces:              |  |  |
|  |  | - Mount (mntns)           |       | - Mount (mntns)                   |  |  |
|  |  | - PID (pidns, default)    |       | - PID (pidns, default)            |  |  |
|  |  |                           |       |                                   |  |  |
|  |  | Linux Security Controls:  |       | Linux Security Controls:          |  |  |
|  |  | - seccomp, AppArmor       |       | - seccomp, AppArmor               |  |  |
|  |  | - Capabilities (dropped)  |       | - Capabilities (dropped)          |  |  |
|  |  | - cgroups v2 limits       |       | - cgroups v2 limits               |  |  |
|  |  +---------------------------+       +-----------------------------------+  |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### The Security Perimeter Problem
By default, standard Pod definitions inherit permissive defaults from container runtimes (`containerd`, `CRI-O`). Without explicit security controls, containers running inside a Pod introduce severe security risks:

1. **Privileged Escalation & Container Breakout**: Running as `root` (UID 0) inside a container without dropping capabilities allows attackers who achieve Remote Code Execution (RCE) to exploit kernel vulnerabilities or container runtime flaws (e.g., CVE-2019-5736 in `runc`, CVE-2022-0492 in `cgroups v1`) to escape to the host node.
2. **Host Namespace & File System Traversal**: Misconfigured Pods mounting host paths (`hostPath`) or running with `hostNetwork: true`, `hostPID: true`, or `hostIPC: true` breach the Pod boundary entirely, allowing processes to sniff host network traffic, inspect host processes, or overwrite node binaries (`/usr/bin`, `/var/log`).
3. **Lateral Movement via Service Account Tokens**: Kubernetes automatically projects the default ServiceAccount JWT token into `/var/run/secrets/kubernetes.io/serviceaccount/` unless explicitly disabled. If a Pod is compromised, an attacker can use this token to query the API Server and attempt lateral movement within the cluster.
4. **Shared Resource Exhaustion (Noisy Neighbor / DoS)**: Unbounded Pods can consume all host memory, CPU, or file descriptors, causing node-wide kernel Out-Of-Memory (OOM) panics or starvation of system critical daemons (`kubelet`, `containerd`).

---

## 2. Technical Mechanics & Architecture

### Linux Kernel Isolation Primitives in Pods

Kubernetes relies on underlying Linux kernel primitives configured by the Container Runtime Interface (CRI) implementation:

*   **Namespaces (`clone` flags)**:
    *   `CLONE_NEWNET`: Pod containers share a single network namespace by default (single IP per Pod, shared `localhost`).
    *   `CLONE_NEWIPC`: Shared System V IPC and POSIX message queues across containers in the same Pod.
    *   `CLONE_NEWUTS`: Shared hostname identifier.
    *   `CLONE_NEWPID`: Isolated per container by default, but can be shared across containers within the Pod if `shareProcessNamespace: true` is defined.
    *   `CLONE_NEWNS` (Mount): Isolated per container, allowing unique root filesystems overlaying image layers.
    *   `CLONE_NEWUSER`: Maps container UIDs/GIDs to unprivileged host UIDs/GIDs (User Namespaces).
*   **Control Groups (`cgroups v2`)**: Enforces hard limits on memory, CPU bandwidth (`cpu.max`), I/O throughput (`io.max`), and process count (`pids.max`) to guarantee QoS classes (`Guaranteed`, `Burstable`, `BestEffort`).
*   **POSIX Capabilities (`capabilities(7)`)**: Breaks down the monolithic `root` privilege into distinct permissions. Hardened Pods drop `ALL` capabilities and selectively retain only necessary ones (e.g., `CAP_NET_BIND_SERVICE`).
*   **System Call Filtering (`seccomp`)**: Restricts the syscall interface exposed by the Linux kernel to the container process. The `RuntimeDefault` profile blocks risky syscalls like `unshare`, `clone` with specific flags, `keyctl`, and `sys_ptrace`.

---

### Pod Security Standards (PSS) Comparison Matrix

Kubernetes defines three Pod Security Standards (PSS) levels enforced natively by **Pod Security Admission (PSA)**:

| Feature / Control | `Privileged` | `Baseline` | `Restricted` (Production Standard) |
| :--- | :--- | :--- | :--- |
| **Intended Scope** | Infrastructure agents (CNI, CSI, system monitoring). | Un-hardened applications, legacy workloads. | Security-critical & general production workloads. |
| **Privileged Mode (`privileged`)** | Allowed (`true`) | Forbidden (`false`) | Forbidden (`false`) |
| **Host Namespaces (`hostNetwork`, `hostPID`, `hostIPC`)** | Allowed | Forbidden | Forbidden |
| **Linux Capabilities** | Unrestricted | Restricts dangerous capabilities (`SYS_ADMIN`, etc.) | Drops **ALL** capabilities (`drop: ["ALL"]`); optional addition of `NET_BIND_SERVICE`. |
| **Execution UID (`runAsNonRoot`)** | Unrestricted (Allows `root`) | Unrestricted | **Mandatory** (`runAsNonRoot: true`, non-zero `runAsUser`). |
| **Privilege Escalation (`allowPrivilegeEscalation`)** | Allowed | Allowed | **Forbidden** (`false`). |
| **Seccomp Profile (`seccompProfile`)** | Unrestricted | Unrestricted | **Mandatory** (`RuntimeDefault` or `Localhost`). |
| **Root Filesystem (`readOnlyRootFilesystem`)** | Writable | Writable | Recommended / Enforced by enterprise policy (`true`). |
| **Volume Types Allowed** | All volume types (`hostPath`, `secret`, etc.) | Restricts `hostPath` | Restricts `hostPath`; allows `configMap`, `secret`, `emptyDir`, `persistentVolumeClaim`. |

---

## 3. Production-Ready YAML Manifests

### Manifest 1: Production Hardened Workload (`Restricted` PSS Compliant)

This manifest enforces complete container isolation, immutability, zero capabilities, non-root execution, and explicit resource constraints.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production-workloads
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: e-commerce
    app.kubernetes.io/managed-by: argocd
    security.cncf.io/tier: restricted
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor
    spec:
      # Block automatic API token mounting to mitigate lateral movement vectors
      automountServiceAccountToken: false
      
      # Pod-level SecurityContext
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: "OnRootMismatch"
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: registry.enterprise.io/finance/payment-processor:v2.4.1
          imagePullPolicy: IfNotPresent

          # Container-level SecurityContext overrides/reinforcements
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL

          ports:
            - name: http-metrics
              containerPort: 8080
              protocol: TCP

          # Resource limits map to Linux cgroups v2
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"

          # Ephemeral writable mounts for applications requiring temporary storage
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: cache-volume
              mountPath: /var/cache/app

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

### Manifest 2: Pod Security Admission (PSA) Namespace Configuration

Enforces the `restricted` PSS standard at the API server admission controller level for all Pods created in the target namespace.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-workloads
  labels:
    # Pod Security Admission labels
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: "v1.30"
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: "v1.30"
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: "v1.30"
```

---

### Manifest 3: Secure Multi-Container Pod (Sidecar Pattern)

Demonstrates IPC isolation and shared volume communication between an application container and a log shipping sidecar under strict security constraints.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app-with-sidecar
  namespace: production-workloads
spec:
  automountServiceAccountToken: false
  
  # Enable PID namespace sharing ONLY if explicitly required for process monitoring sidecars
  shareProcessNamespace: false

  securityContext:
    runAsNonRoot: true
    runAsUser: 20000
    runAsGroup: 20000
    fsGroup: 20000
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: primary-api
      image: registry.enterprise.io/apps/api-service:v1.1.0
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
      volumeMounts:
        - name: shared-logs
          mountPath: /var/log/app

    - name: log-shipper
      image: registry.enterprise.io/ops/fluent-bit:v3.0.2
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"
      volumeMounts:
        - name: shared-logs
          mountPath: /var/log/app
          readOnly: true
        - name: fluentbit-config
          mountPath: /fluent-bit/etc

  volumes:
    - name: shared-logs
      emptyDir:
        sizeLimit: 256Mi
    - name: fluentbit-config
      configMap:
        name: fluentbit-config
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### Command 1: Verifying PSA Policy Enforcement via Dry-Run

Executing `kubectl apply` with an unhardened Pod against a namespace configured with `pod-security.kubernetes.io/enforce: restricted`.

```bash
$ kubectl apply --dry-run=server -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unhardened-test-pod
  namespace: production-workloads
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Expected Output:**

```text
Error from server (Forbidden): error when creating "STDIN": pods "unhardened-test-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### Command 2: Inspecting Low-Level Linux Capabilities and Seccomp Inside a Pod

Executing internal capability checks using `capsh` and `/proc/1/status`.

```bash
$ kubectl exec -it payment-processor-65b8c9d4b5-x8z2l -n production-workloads -c app -- capsh --print
```

**Expected Output:**

```text
Current: =
Bounding set =
Securebits: 00000004/0x4/2 (secure-keep-caps)
 secure-noroot: no (setsuid/sgid permissions ignored when uids/gids are 0)
 secure-no-suid-fixup: yes (setsuid/sgid permissions ignored when uids/gids are 0)
 secure-keep-caps: yes (set keep capabilities when uids/gids are set to 0)
 secure-no-ambient-caps: no (ambient capabilities maintained across execve)
Supplementary groups = 10001
UID: 10001(appuser)
GID: 10001(appgroup)
```

Direct inspection of kernel status bits:

```bash
$ kubectl exec -it payment-processor-65b8c9d4b5-x8z2l -n production-workloads -c app -- grep -E 'Cap|Seccomp|Speculation' /proc/1/status
```

**Expected Output:**

```text
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000
CapAmb:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1
Speculation_Store_Bypass:	thread vulnerable
```

> **SRE Key Takeaway**: `CapEff: 0000000000000000` proves that **all** Linux capabilities are dropped. `Seccomp: 2` indicates that Seccomp filtering is active in `SECCOMP_MODE_FILTER` mode (configured via `RuntimeDefault`). `NoNewPrivs: 1` confirms `allowPrivilegeEscalation: false`.

---

### Command 3: Node-Level CRI Container & Linux Namespace Inspection

From an SRE/Platform Architect node debugging shell, inspect the container state using `crictl` and locate its underlying Linux Network and PID namespaces.

```bash
$ sudo crictl ps --name app --state Running
```

**Expected Output:**

```text
CONTAINER           IMAGE                                                               CREATED             STATE               NAME                ATTEMPTS            POD ID              DEFAULT-NAME
a1f2b3c4d5e61       registry.enterprise.io/finance/payment-processor@sha256:d8e7f...   10 minutes ago      Running             app                 0                   7f8e9d0c1b2a        payment-processor-65b8c9d4b5-x8z2l
```

Inspect the container's security context settings at the runtime layer:

```bash
$ sudo crictl inspect a1f2b3c4d5e61 | jq '.info.runtimeSpec.linux.securityContext'
```

**Expected Output:**

```json
{
  "readonlyPaths": [
    "/proc/asound",
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger"
  ],
  "seccomp": {
    "profileType": "RuntimeDefault"
  },
  "maskedPaths": [
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/sched_debug",
    "/sys/firmware",
    "/proc/scsi"
  ]
}
```

---

## 5. Verification & Diagnostic Troubleshooting Guide

When hardening Pod security configurations, workloads frequently encounter runtime errors. SREs must systematically diagnose these failures.

```
+-----------------------------------------------------------------------------------+
| Pod Hardening Failure Diagnostic Workflow                                         |
+-----------------------------------------------------------------------------------+
                                          |
                                 [ Deploy Pod Manifest ]
                                          |
                                          v
                         /---------------------------------\
                        /  Is Deployment Accepted by API?   \
                        \---------------------------------/
                                 /                 \
                             NO /                   \ YES
                               v                     v
              +-------------------------------+  +----------------------------------+
              | Pod Security Admission (PSA)  |  | Container Enters CrashLoopBackOff|
              | Rejection (Forbidden 403)     |  | or Error Status                  |
              +-------------------------------+  +----------------------------------+
                               |                                  |
                               v                                  v
              [ Check PSA Label Rules ]           [ Check Kubelet Container Logs ]
              - Missing drop ALL caps?            - Read-only root FS write failure?
              - Missing runAsNonRoot?             - UID/GID mount EACCES permission?
              - Missing seccompProfile?           - Denied syscall (Seccomp EPERM)?
```

---

### Failure Scenario 1: `CrashLoopBackOff` due to `readOnlyRootFilesystem: true`

*   **Symptom**: The container repeatedly crashes immediately after startup.
*   **Log Extraction**:

```bash
$ kubectl logs payment-processor-65b8c9d4b5-x8z2l -n production-workloads --previous
```

*   **Error Output**:

```text
2026-08-07T23:14:02.102Z [FATAL] main: failed to initialize logger: open /var/log/app/execution.log: read-only file system
```

*   **Root Cause**: Application code attempts to create or open a file in write mode (`O_WRONLY | O_CREAT`) on a directory within the container root filesystem that has not been explicitly mounted as a writable volume (`emptyDir` or `PVC`).
*   **Remediation**: Update the Deployment manifest to add an `emptyDir` volume and corresponding `volumeMount` at `/var/log/app`. Do **not** disable `readOnlyRootFilesystem`.

---

### Failure Scenario 2: Volume Permission Denied (`EACCES`) for Non-Root UID

*   **Symptom**: Application fails to write to a Mounted Persistent Volume.
*   **Log Extraction**:

```bash
$ kubectl logs payment-processor-65b8c9d4b5-x8z2l -n production-workloads
```

*   **Error Output**:

```text
2026-08-07T23:18:44.891Z [ERROR] storage: unable to write lockfile to /mnt/data/lock: permission denied
```

*   **Root Cause**: The volume is owned by `root:root` (UID/GID 0) on the host or storage provisioner, but the container runs as `runAsUser: 10001`.
*   **Diagnostic Verification**:

```bash
$ kubectl get pod payment-processor-65b8c9d4b5-x8z2l -n production-workloads -o jsonpath='{.spec.securityContext}'
```

*   **Remediation**: Set `fsGroup: 10001` and `fsGroupChangePolicy: "OnRootMismatch"` in the **Pod-level** `securityContext`. This instructs `kubelet` to recursively recursively `chown`/`chgrp` volume contents to GID `10001` upon volume mount.

---

### Failure Scenario 3: Sycall Blocked by Seccomp (`Operation not permitted` / `EPERM`)

*   **Symptom**: Application panics or terminates abruptly during specific operations (e.g., executing sub-processes, network socket bindings).
*   **Node-Level Diagnostic (Kernel Audit Logs)**:

```bash
$ sudo journalctl -k --since "10 minutes ago" | grep -i seccomp
```

*   **Kernel Output**:

```text
Aug 07 23:22:10 node-01 kernel: audit: type=1326 audit(1723072930.412:984): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84921 comm="payment-proc" exe="/app/payment-proc" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a12c41b8a code=0x00000000
```

*   **Root Cause**: Syscall `165` (`mount`) was invoked by the application code, which is explicitly prohibited by the `RuntimeDefault` seccomp profile.
*   **Remediation**: Audit application dependencies to remove host system calls, or construct a custom seccomp profile under `securityContext.seccompProfile.type: Localhost` that permits the audited syscall safely.

---

## 6. References

*   [Kubernetes Official Documentation: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
*   [Kubernetes Official Documentation: Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
*   [Kubernetes Official Documentation: Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
*   [Kubernetes Official Documentation: Pods Architecture](https://kubernetes.io/docs/concepts/workloads/pods/)
*   [CNCF KCSA Exam Curriculum Guide (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)