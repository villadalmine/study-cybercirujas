# CNCF KCSA Exam Preparation: Topic 1.4 – Isolation Techniques

**Domain:** Kubernetes & Cloud Native Security Associate (KCSA)  
**Exam Weight:** ~2.33%  
**Target Audience:** Principal Platform Architects, Lead SREs, Security Engineers  

---

## Official References
* **Kubernetes Documentation – Restricting Syscalls with Seccomp:** [https://kubernetes.io/docs/tutorials/security/seccomp/](https://kubernetes.io/docs/tutorials/security/seccomp/)
* **Kubernetes Documentation – Securing a Pod with AppArmor:** [https://kubernetes.io/docs/tutorials/security/apparmor/](https://kubernetes.io/docs/tutorials/security/apparmor/)
* **Kubernetes Documentation – Container Isolation & RuntimeClass:** [https://kubernetes.io/docs/concepts/containers/runtime-class/](https://kubernetes.io/docs/concepts/containers/runtime-class/)
* **Kubernetes Documentation – Network Policies:** [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* **CNCF Cloud Native Security Whitepaper (Isolation & Multi-Tenancy):** [https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper.md)
* **Linux Kernel Documentation – Control Groups v2:** [https://www.kernel.org/doc/Documentation/cgroup-v2.txt](https://www.kernel.org/doc/Documentation/cgroup-v2.txt)

---

## Technical Overview & Deep Mechanics

Isolation in Kubernetes operates on a defense-in-depth model across four distinct boundaries:

```
+-------------------------------------------------------------------------+
|                              NODE BOUNDARY                              |
|  Node Isolation: Taints, Tolerations, NodeAffinity, Topology Constraints|
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  |                         NETWORK BOUNDARY                          |  |
|  |  Network Policies: Ingress/Egress Isolation (CNI / eBPF / iptables) |  |
|  |                                                                   |  |
|  |  +-------------------------------------------------------------+  |  |
|  |  |                      RUNTIME BOUNDARY                       |  |  |
|  |  |  RuntimeClass: gVisor (runsc) / Kata MicroVMs / runc        |  |  |
|  |  |                                                             |  |  |
|  |  |  +-------------------------------------------------------+  |  |  |
|  |  |  |                  KERNEL / OS BOUNDARY                 |  |  |  |
|  |  |  |  Namespaces, cgroups v2, Seccomp, AppArmor, Capabilities|  |  |  |
|  |  |  +-------------------------------------------------------+  |  |  |
|  |  +-------------------------------------------------------------+  |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

1. **Kernel & OS Boundary:** Traditional containers share the host kernel. Linux kernel primitives—`namespaces` (pid, net, ipc, mnt, uts, user, cgroup), `cgroups v2` (resource enforcement), `Seccomp` (filtering syscalls via BPF), `AppArmor/SELinux` (Mandatory Access Control), and `Capabilities` (splitting `root` superuser powers)—prevent process cross-contamination and unauthorized host interactions.
2. **Runtime Boundary:** Standard runtimes (`runc`) use native host Linux primitives, exposing a large host kernel attack surface (~350+ system calls). Sandboxed runtimes mitigate host kernel exposure by intercepting system calls in user space (`gVisor` via `runsc`) or running each Pod inside an isolated hardware-assisted virtual machine (`Kata Containers` using Firecracker/QEMU).
3. **Network Boundary:** By default, Kubernetes flat networking allows unhindered Pod-to-Pod communication across namespaces. `NetworkPolicies` isolate traffic at Layer 3/4 (and Layer 7 when using eBPF/service meshes), enforced at the CNI data plane (e.g., eBPF maps in Cilium or iptables chains in Calico).
4. **Node Boundary:** Logical and physical isolation prevent multi-tenant noise and lateral movement. Scheduling constraints—`Taints`, `Tolerations`, `NodeAffinity`, and `PodAntiAffinity`—guarantee sensitive workloads are strictly scheduled on dedicated physical hardware or hardened node pools.

---

## Lab 1: Hardening the Kernel Interface (Seccomp, Capabilities, and AppArmor)

### Objective
Configure a zero-trust execution environment for a container by dropping Linux capabilities, applying a custom localhost Seccomp profile, enforcing AppArmor, and running with a read-only root file system.

### Guided Steps

1. **Step 1.1:** Log into the Kubernetes worker node host system and create a custom Seccomp profile file on the host filesystem under the Kubelet default seccomp path (`/var/lib/kubelet/seccomp/profiles/strict-block.json`).

```bash
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
cat <<'EOF' | sudo tee /var/lib/kubelet/seccomp/profiles/strict-block.json
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
        "exit",
        "exit_group",
        "futex",
        "write",
        "read",
        "fstat",
        "mmap",
        "mprotect",
        "rt_sigaction",
        "rt_sigprocmask",
        "brk",
        "getpid",
        "getuid",
        "geteuid",
        "getgid",
        "getegid",
        "close",
        "execve",
        "arch_prctl"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF
```

2. **Step 1.2:** Verify that AppArmor is active on the node and check the status of loaded profiles.

```bash
sudo aa-status
```
*Expected Output Snippet:*
```text
apparmor module is loaded.
64 profiles are loaded.
64 profiles are in enforce mode.
   /usr/bin/man
   cri-containerd.apparmor.d
```

3. **Step 1.3:** Create a fully hardened deployment manifest [`hardened-app.yaml`](file:///var/lib/kubelet/seccomp/profiles/hardened-app.yaml) that references the custom local Seccomp profile, drops `ALL` kernel capabilities, enables `readOnlyRootFilesystem`, and applies the default runtime AppArmor profile (`runtime/default`).

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-workload
  namespace: default
  labels:
    app.kubernetes.io/name: hardened-workload
    app.kubernetes.io/part-of: isolation-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hardened-workload
  template:
    metadata:
      labels:
        app: hardened-workload
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: profiles/strict-block.json
        appArmorProfile:
          type: RuntimeDefault
      containers:
      - name: workload
        image: ccr.gcr.io/google-containers/pause:3.9
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "50m"
            memory: "64Mi"
```

4. **Step 1.4:** Apply the deployment to the cluster.

```bash
kubectl apply -f hardened-app.yaml
```
*Expected Output:*
```text
deployment.apps/hardened-workload created
```

5. **Step 1.5:** Validate Pod deployment and security profile application via `kubectl`.

```bash
POD_NAME=$(kubectl get pods -l app=hardened-workload -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD_NAME" -o jsonpath='{.spec.securityContext}' | jq .
```
*Expected Output:*
```json
{
  "appArmorProfile": {
    "type": "RuntimeDefault"
  },
  "fsGroup": 10001,
  "runAsGroup": 10001,
  "runAsNonRoot": true,
  "runAsUser": 10001,
  "seccompProfile": {
    "localhostProfile": "profiles/strict-block.json",
    "type": "Localhost"
  }
}
```

6. **Step 1.6:** Attempt an operational execution test to trigger a blocked system call inside the hardened pod.

```bash
kubectl exec -it "$POD_NAME" -- sh -c "mkdir /tmp/test"
```
*Expected Output:*
```text
OCI runtime exec failed: exec failed: container_linux.go:380: starting container process caused: process_linux.go:545: container init caused: Operation not permitted
```

7. **Step 1.7:** Inspect system kernel logs on the host node for Seccomp audit violations.

```bash
sudo dmesg -T | grep -i "audit" | tail -n 5
```
*Expected Output Snippet:*
```text
[Fri Aug  7 19:30:12 2026] audit: type=1326 audit(1723059012.842:984): auid=4294967295 uid=10001 gid=10001 ses=4294967295 pid=84920 comm="sh" exe="/bin/sh" sig=31 arch=c000003e syscall=83 compat=0 ip=0x7f23a41e97bb code=0x00000000
```
*(Note: `syscall=83` corresponds to `mkdir` on x86_64).*

---

### Verification Questions (Lab 1)

1. What kernel mechanism converts Seccomp JSON definitions into runtime system call checks, and what is its operational latency impact?
2. If `allowPrivilegeEscalation` is set to `true`, how does it impact a process trying to regain dropped capabilities using `setuid` binaries?
3. Why does `mkdir` fail with `Operation not permitted` (or signal 31) in Step 1.6: is it caused by `readOnlyRootFilesystem` or `seccompProfile`? How can you differentiate the exact cause using `dmesg` audit traces?

---

## Lab 2: Container Runtime Sandboxing via RuntimeClass (gVisor & MicroVMs)

### Architectural Overview & Mechanics

Traditional container runtimes (`runc`) act as thin wrappers around host Linux kernel namespaces and cgroups. If an attacker triggers a privilege escalation flaw in the shared host kernel (e.g., Dirty COW, Dirty Pipe), container boundaries collapse.

Sandboxed runtimes eliminate shared kernel exposure:
* **gVisor (`runsc`):** Implements a user-space kernel (the **Sentry**) that intercepts container system calls via `ptrace` or `KVM`. File operations are proxied through a separate isolated process (the **Gofer**). The container never directly interacts with host kernel system calls.
* **Kata Containers (`kata-runtime`):** Spawns a dedicated, lightweight virtual machine (using Firecracker or QEMU) per Pod. The Pod runs inside its own isolated guest kernel.

```
       Standard Pod (runc)                      Sandboxed Pod (gVisor / runsc)
+--------------------------------+        +--------------------------------+
|  User Application Process      |        |  User Application Process      |
+--------------------------------+        +--------------------------------+
|  Syscall (e.g. open, socket)   |        |  Syscall (e.g. open, socket)   |
+---------------+----------------+        +---------------+----------------+
                |                                         | Intercepted
                v                                         v
+--------------------------------+        +--------------------------------+
|       Host Linux Kernel        |        |   gVisor Sentry (User Space)   |
+--------------------------------+        +---------------+----------------+
                                                          | Sanitized Syscall
                                                          v
                                          +--------------------------------+
                                          |       Host Linux Kernel        |
                                          +--------------------------------+
```

### Guided Steps

1. **Step 2.1:** Check CRI container runtime availability and configured runtime handlers on the worker node.

```bash
sudo crictl info | jq '.config.containerd.runtimes'
```
*Expected Output Snippet:*
```json
{
  "gvisor": {
    "runtimeType": "io.containerd.runsc.v1",
    "options": null
  },
  "runc": {
    "runtimeType": "io.containerd.runc.v2",
    "options": null
  }
}
```

2. **Step 2.2:** Create a cluster-scoped `RuntimeClass` resource named `gvisor` mapping to the CRI handler `gvisor`.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
overhead:
  podFixed:
    cpu: "100m"
    memory: "64Mi"
scheduling:
  nodeSelector:
    sandbox-enabled: "true"
EOF
```
*Expected Output:*
```text
runtimeclass.node.k8s.io/gvisor created
```

3. **Step 2.3:** Label target node to satisfy the `RuntimeClass` scheduling requirement.

```bash
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label node "$NODE_NAME" sandbox-enabled=true --overwrite
```

4. **Step 2.4:** Deploy a workload utilizing the `gvisor` RuntimeClass.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-sandboxed-pod
  namespace: default
spec:
  runtimeClassName: gvisor
  containers:
  - name: untrusted-app
    image: alpine:3.18
    command: ["sleep", "3600"]
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
EOF
```
*Expected Output:*
```text
pod/gvisor-sandboxed-pod created
```

5. **Step 2.5:** Inspect kernel identity inside the standard host vs inside the sandboxed Pod to confirm kernel isolation.

```bash
# Check host kernel version
uname -a

# Check kernel version reported inside gVisor sandbox
kubectl exec gvisor-sandboxed-pod -- uname -a
```
*Expected Output (gVisor internal vs Host):*
```text
Linux gvisor-sandboxed-pod 4.4.0-gVisor #1 SMP Sun Jan 1 00:00:00 2017 x86_64 Linux
```
*(Notice gVisor emulates a specific Linux release interface regardless of host kernel version).*

6. **Step 2.6:** Execute `dmesg` inside the sandboxed pod.

```bash
kubectl exec gvisor-sandboxed-pod -- dmesg
```
*Expected Output:*
```text
[  0.000000] Starting gVisor...
[  0.342100] Producing safe virtualized system calls...
```

7. **Step 2.7:** Trace host process tree to inspect the shim and sandbox boundaries using `crictl` and `ps`.

```bash
POD_ID=$(sudo crictl pods --name gvisor-sandboxed-pod -q)
sudo crictl inspectp "$POD_ID" | jq '.status.info.pid'
```
*Expected Output:*
```text
124532
```

```bash
ps aux | grep 124532
```
*Expected Output Snippet:*
```text
root      124532  0.8  0.4 1245028 34200 ?       Ssl  19:35   0:00 runsc-sandbox --root /run/containerd/runsc/k8s.io ...
```

---

### Verification Questions (Lab 2)

1. What is the performance trade-off (latency and memory footprint) of using `gVisor` (`runsc`) compared to standard `runc` for I/O-intensive workloads?
2. What role does the `overhead` field play in a `RuntimeClass` object during pod resource quota calculation and scheduling?
3. How does `Kata Containers` differ from `gVisor` in its approach to hardware virtualization and syscall interception?

---

## Lab 3: Multi-Tenant Network Isolation & Egress Enforcement

### Architectural Overview & Mechanics

Kubernetes networking operates as a non-isolated flat network model. Any Pod can route packets to any other Pod IP or Service IP across the cluster. 

`NetworkPolicies` introduce stateful firewalling rules enforced at Layer 3/4 by the Container Network Interface (CNI) plugin:
* **Default-Deny All Ingress & Egress:** Baseline zero-trust security posture. Block all incoming and outgoing connections by default.
* **Selective Ingress Allow:** Allow explicit incoming traffic based on `podSelector`, `namespaceSelector`, or `ipBlock`.
* **Selective Egress Allow:** Prevent data exfiltration by restricting outgoing connections exclusively to authorized internal microservices and external endpoints (e.g., DNS port 53).

```
[ Namespace: tenant-alpha ]                   [ Namespace: tenant-beta ]
+-------------------------+                   +------------------------+
|  Pod: frontend          |                   |  Pod: database         |
|  label: app=frontend    |                   |  label: app=postgres   |
+------------+------------+                   +-----------^------------+
             |                                            |
             |  Egress Request (Port 5432)                |
             +=================== X ======================+
                       BLOCKED BY DEFAULT-DENY
                       
  (Requires explicitly paired Namespace + Pod Selector Egress/Ingress Policy)
```

### Guided Steps

1. **Step 3.1:** Create isolated namespaces representing multi-tenant domains: `tenant-alpha` and `tenant-beta`.

```bash
kubectl create namespace tenant-alpha
kubectl create namespace tenant-beta
kubectl label namespace tenant-alpha tenant=alpha
kubectl label namespace tenant-beta tenant=beta
```

2. **Step 3.2:** Deploy web frontend workloads in `tenant-alpha` and database workloads in `tenant-beta`.

```bash
# Deploy caller application in tenant-alpha
kubectl run client-app --namespace tenant-alpha --image=alpine:3.18 --labels=app=client -- sleep 3600

# Deploy target database application in tenant-beta
kubectl run db-service --namespace tenant-beta --image=nginx:1.25-alpine --labels=app=database --port=80
kubectl expose pod db-service --namespace tenant-beta --port=80
```

3. **Step 3.3:** Test unhindered connectivity before applying NetworkPolicies.

```bash
DB_IP=$(kubectl get pod db-service -n tenant-beta -o jsonpath='{.status.podIP}')
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://$DB_IP" | head -n 3
```
*Expected Output:*
```html
<!DOCTYPE html>
<html>
<head>
```

4. **Step 3.4:** Apply a strict **Default-Deny Ingress and Egress Policy** to both namespaces.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-alpha
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-beta
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```
*Expected Output:*
```text
networkpolicy.networking.k8s.io/default-deny-all created
networkpolicy.networking.k8s.io/default-deny-all created
```

5. **Step 3.5:** Verify that connectivity is now completely blocked.

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://$DB_IP"
```
*Expected Output:*
```text
wget: download timed out
```

6. **Step 3.6:** Create explicit rule allowlists:
   - Allow `tenant-alpha/client-app` egress to kube-dns (port 53 UDP/TCP) and egress to `tenant-beta/db-service` on port 80.
   - Allow `tenant-beta/db-service` ingress from `tenant-alpha` pods matching `app=client`.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-egress
  namespace: tenant-alpha
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
  - Egress
  egress:
  # Allow DNS resolution
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow specific connection to tenant-beta database pods
  - to:
    - namespaceSelector:
        matchLabels:
          tenant: beta
      podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-db-ingress
  namespace: tenant-beta
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          tenant: alpha
      podSelector:
        matchLabels:
          app: client
    ports:
    - protocol: TCP
      port: 80
EOF
```
*Expected Output:*
```text
networkpolicy.networking.k8s.io/allow-client-egress created
networkpolicy.networking.k8s.io/allow-db-ingress created
```

7. **Step 3.7:** Test cross-namespace connectivity to confirm successful access.

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=3 "http://db-service.tenant-beta.svc.cluster.local" | head -n 3
```
*Expected Output:*
```html
<!DOCTYPE html>
<html>
<head>
```

8. **Step 3.8:** Confirm exfiltration protection by attempting connection from `client-app` to an unauthorized IP destination (e.g. `1.1.1.1`).

```bash
kubectl exec -n tenant-alpha client-app -- wget -qO- --timeout=2 "http://1.1.1.1"
```
*Expected Output:*
```text
wget: download timed out
```

---

### Verification Questions (Lab 3)

1. What happens if a NetworkPolicy specifies a `podSelector` that matches a Pod, but the `ingress` array is empty (`ingress: []`) vs omitted entirely?
2. How do `namespaceSelector` and `podSelector` evaluate when defined in separate array elements under `from:` versus combined within the same array element?
3. If an underlying CNI plugin (e.g. Flannel) does not support NetworkPolicies, what happens when you apply a `NetworkPolicy` object in Kubernetes?

---

## Lab 4: Physical & Node-Level Isolation (Taints, Tolerations, & NodeAffinity)

### Architectural Overview & Mechanics

Hard multi-tenancy requires strict isolation at the physical compute node level to eliminate side-channel attacks (e.g., Spectre, Meltdown), CPU cache contention, and kernel resource exhaustion.

Kubernetes enforces node placement isolation through two complementary primitive pairs:
1. **Taints & Tolerations (Repulsion):** Taints applied to nodes repel Pods. A Pod cannot be scheduled onto a tainted node unless it has an explicit matching `toleration`.
2. **NodeAffinity & NodeSelector (Attraction):** Explicitly attracts Pods to designated nodes based on node labels.

To guarantee dedicated multi-tenant isolation, **both primitives must be combined simultaneously**:
* Taint node -> Prevents unauthorized pods from landing on the dedicated node.
* NodeAffinity -> Ensures dedicated pods land *only* on the dedicated node and nowhere else.

```
                  [ Node: worker-pci-1 ]                    [ Node: worker-general-1 ]
                  Taint: tier=pci:NoSchedule                No Taints
                  Label: tier=pci
                          |                                             |
     +--------------------+--------------------+                        |
     |                                         |                        |
     v                                         v                        v
[ Pod: Payment-Service ]              [ Pod: General-App ]     [ Pod: General-App ]
- Toleration: tier=pci:NoSchedule     - No Tolerations         - No Tolerations
- NodeAffinity: tier=pci                |                        |
     |                                  +=========== X ==========+
     +---> SCHEDULED SUCCESSFULLY                   REPELLED BY TAINT
```

### Guided Steps

1. **Step 4.1:** Identify a node and apply a restrictive taint designating it for high-security PCI-DSS compliant workloads.

```bash
TARGET_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "$TARGET_NODE" tier=pci:NoSchedule --overwrite
kubectl label nodes "$TARGET_NODE" tier=pci --overwrite
```
*Expected Output:*
```text
node/worker-1 tainted
node/worker-1 labeled
```

2. **Step 4.2:** Attempt to deploy an standard unprivileged application without tolerations.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: standard-untrusted-pod
  namespace: default
spec:
  containers:
  - name: web
    image: nginx:alpine
EOF
```

3. **Step 4.3:** Inspect pod scheduling status.

```bash
kubectl get pod standard-untrusted-pod
```
*Expected Output:*
```text
NAME                     READY   STATUS    RESTARTS   AGE
standard-untrusted-pod   0/1     Pending   0          12s
```

```bash
kubectl describe pod standard-untrusted-pod | grep -A 3 "Events:"
```
*Expected Output Snippet:*
```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  20s   default-scheduler  0/1 nodes are available: 1 node(s) had untolerated taint {tier: pci}. preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling.
```

4. **Step 4.4:** Construct a isolated production Pod manifest using explicit **Tolerations** AND **nodeAffinity** to bind securely to the PCI node pool.

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secure-pci-payment-pod
  namespace: default
  labels:
    app.kubernetes.io/name: payment-processor
    security.domain: pci-dss
spec:
  tolerations:
  - key: "tier"
    operator: "Equal"
    value: "pci"
    effect: "NoSchedule"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: tier
            operator: In
            values:
            - pci
  containers:
  - name: payment-app
    image: nginx:alpine
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
```
*Expected Output:*
```text
pod/secure-pci-payment-pod created
```

5. **Step 4.5:** Validate that `secure-pci-payment-pod` is scheduled and running on the tainted node.

```bash
kubectl get pod secure-pci-payment-pod -o wide
```
*Expected Output Snippet:*
```text
NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE
secure-pci-payment-pod   1/1     Running   0          8s    10.244.0.9   worker-1
```

6. **Step 4.6:** Clean up test pods and remove node taint.

```bash
kubectl delete pod standard-untrusted-pod secure-pci-payment-pod --ignore-not-found
kubectl taint nodes "$TARGET_NODE" tier=pci:NoSchedule-
```

---

### Verification Questions (Lab 4)

1. What is the operational difference between the Taint effects `NoSchedule`, `PreferNoSchedule`, and `NoExecute`?
2. If a node is tainted with `NoExecute`, what happens immediately to existing Pods running on that node that lack a corresponding toleration?
3. Why does adding a `Toleration` alone fail to guarantee hard tenant isolation on a multi-node cluster?

---

<details>
<summary><strong>Click to expand: Answers & Deep-Dive Explanations</strong></summary>

### Lab 1 Answers

1. **Kernel Mechanism & Latency:**
   * **Mechanism:** Seccomp uses Linux Kernel **eBPF (Extended Berkeley Packet Filters)** via `prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ...)` to evaluate system calls against loaded BPF bytecode rules at the system call entry layer (`entry_SYSCALL_64`).
   * **Latency Impact:** Evaluating Seccomp profiles adds a tiny overhead (a few nanoseconds per syscall execution). However, unoptimized profiles with extensive linear syscall lists can introduce overhead during syscall-heavy operations. Utilizing `SCMP_ACT_ERRNO` or `SCMP_ACT_KILL_PROCESS` default actions combined with minimal allowlists minimizes BPF evaluation paths.

2. **Privilege Escalation & Capabilities:**
   * Setting `allowPrivilegeEscalation: false` sets the `no_new_privs` bit on the process via `prctl(PR_SET_NO_NEW_PRIVS)`.
   * Even if a binary inside the container has `setuid` bits enabled (e.g., `/bin/su`, `/usr/bin/sudo`) or file capabilities attached, the kernel refuses to grant elevated privileges or grant back capabilities that were dropped in the parent process hierarchy.

3. **Diagnosing the `mkdir` Failure:**
   * The failure in Step 1.6 was caused by **Seccomp** (`strict-block.json`), not `readOnlyRootFilesystem`.
   * **Differentiation:**
     * `readOnlyRootFilesystem` error returns `Read-only file system` (Errno 30 / `EROFS`).
     * Seccomp default action `SCMP_ACT_ERRNO` (or missing syscall allowlist for `mkdir` / syscall 83) returns `Operation not permitted` (Errno 1 / `EPERM`).
     * `dmesg` logs explicitly confirm Seccomp filter action: `type=1326 audit(...) ... comm="sh" ... sig=31 ... syscall=83`, where `sig=31` (SIGSYS) or audit code indicates Seccomp violation.

---

### Lab 2 Answers

1. **gVisor Performance Trade-Offs:**
   * **Overhead:** High I/O-intensive workloads (e.g., heavy file access, rapid network packet processing) incur CPU performance penalties (10% to 30% overhead) because system calls must be intercepted by the user-space Sentry and translated across context switches between Sentry, Gofer, and host kernel.
   * **Benefit:** Provides extremely fast startup time (~millisecond scale) compared to VM-based isolation while exposing zero host kernel syscall surface to untrusted container code.

2. **`RuntimeClass` Overhead Field:**
   * The `overhead` field accounts for fixed memory and CPU resources consumed by the sandboxing infrastructure itself (e.g., gVisor Sentry process memory or Kata MicroVM VMM/kernel overhead).
   * Kubernetes scheduler **adds** the specified `overhead` to the Pod's resource `requests` and `limits` when assessing node capacity and enforcing resource quotas within Namespaces.

3. **gVisor vs Kata Containers Architecture:**
   * **gVisor (`runsc`):** Emulates Linux kernel interfaces entirely in user space (written in Go). It runs in the same host OS environment but intercepts system calls.
   * **Kata Containers (`kata-runtime`):** Uses hardware-assisted virtualization extensions (Intel VT-x / AMD-V via KVM) to boot a dedicated Linux guest kernel inside a light microVM per Pod. System calls run natively inside the guest kernel without user-space interception.

---

### Lab 3 Answers

1. **`podSelector` and Ingress Array Semantics:**
   * If `podSelector: {}` matches a Pod, and `policyTypes: ["Ingress"]` is declared:
     * `ingress: []` (empty array): **Default-Deny Ingress**. Blocks ALL incoming traffic to matching pods.
     * `ingress` key omitted entirely: Allows ALL incoming traffic (no ingress restrictions active).

2. **Namespace vs Pod Selector Array Mechanics:**
   * **Separate Array Items (Logical OR):**
     ```yaml
     ingress:
     - from:
       - namespaceSelector:
           matchLabels: { tenant: alpha }
       - podSelector:
           matchLabels: { role: admin }
     ```
     *Allows traffic from ANY pod in namespaces labeled `tenant=alpha` OR ANY pod labeled `role=admin` in the local policy namespace.*

   * **Same Array Item (Logical AND):**
     ```yaml
     ingress:
     - from:
       - namespaceSelector:
           matchLabels: { tenant: alpha }
         podSelector:
           matchLabels: { role: admin }
     ```
     *Allows traffic ONLY from pods labeled `role=admin` THAT ALSO reside within namespaces labeled `tenant=alpha`.*

3. **CNI Plugins without NetworkPolicy Support:**
   * Kubernetes accepts the `NetworkPolicy` API objects successfully and stores them in `etcd`.
   * However, because plugins like standard Flannel lack a data-plane filtering engine (e.g. iptables/eBPF drivers), **the policies are completely ignored**, and all pod-to-pod network traffic remains completely unisolated.

---

### Lab 4 Answers

1. **Taint Effects Differences:**
   * `NoSchedule`: Prevents new pods without a matching toleration from being scheduled on the node. Existing running pods are unaffected.
   * `PreferNoSchedule`: Soft constraint. The scheduler tries to avoid placing pods without matching tolerations on the node, but will place them if no other compute capacity is available.
   * `NoExecute`: Prevents new pod scheduling AND immediately **evicts** existing running pods on the node that lack matching tolerations.

2. **Applying `NoExecute` to a Node:**
   * Any running Pod on that node that lacks a matching `toleration` is immediately terminated (sent `SIGTERM`, then `SIGKILL`).
   * Pods with matching tolerations remain running. If a toleration defines `tolerationSeconds`, the pod remains running on the node for that specified duration before eviction.

3. **Why Tolerations Alone Fail Multi-Tenancy:**
   * A `Toleration` gives a Pod **permission** to land on a tainted node, but it does NOT force the Pod to land on that node.
   * Without a matching `NodeAffinity` or `NodeSelector`, the Kubernetes scheduler can freely place the pod onto any normal untainted node in the cluster, breaking workload isolation requirements.

</details>