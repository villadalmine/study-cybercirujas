# KCSA Domain 3.5: Isolation and Segmentation

## 1. Production Architectural Problem & Motivation

In multi-tenant Kubernetes clusters and high-consecurity environments (such as PCI-DSS, HIPAA, or SOC2 Type II compliant infrastructures), single-kernel containerization poses a foundational security risk. Containers share the underlying host operating system kernel via system calls (`syscalls`), kernel namespaces, and control groups (`cgroups`). A breach in a single application container, combined with a local kernel vulnerability (e.g., Linux kernel privilege escalation or container escape like CVE-2022-0492 or CVE-2022-0847 Dirty Pipe), allows an attacker to compromise the host node, access the host memory space, inspect `kubelet` credentials, and pivot horizontally across all workloads scheduled on that physical or virtual instance.

### Threat Vectors and Blast Radii

```
+-----------------------------------------------------------------------------------+
| Host Node (Shared Linux Kernel v6.1)                                             |
|                                                                                   |
|  +-----------------------------------+   +-------------------------------------+  |
|  | Namespace: tenant-a               |   | Namespace: tenant-b                 |  |
|  | Pod: web-frontend                 |   | Pod: payment-processor              |  |
|  | Container: nginx                  |   | Container: java-app                 |  |
|  |                                   |   |                                     |  |
|  | [Attacker: RCE via CVE]           |   | [Target: PCI Data / Secrets]        |  |
|  |       |                           |   |                  ^                  |  |
|  |       v                           |   |                  |                  |  |
|  | Container Escape / Syscall Probe  |   | Unsegmented Network / Host Access   |  |
|  +-------|---------------------------+   +------------------|------------------+  |
|          |                                                  |                     |
|          +=================> Host Kernel <==================+                     |
|                              (Privilege Escalation)                               |
+-----------------------------------------------------------------------------------+
```

1. **Flat Network Flatland**: By default, Kubernetes enforces a flat network topology where any Pod can transmit IP packets to any other Pod across any Namespace (`0.0.0.0/0` ingress/egress permissions).
2. **Shared Kernel Syscall Surface**: Standard runtimes (e.g., `containerd` with `runc`) expose all 300+ Linux system calls directly to the host kernel, enabling memory corruption, kernel heap exploitation, and container breakouts.
3. **Implicit Node Authorization**: A compromised container running with elevated privileges (`CAP_SYS_ADMIN`, `hostNetwork: true`, or `hostPID: true`) can read sensitive service account tokens from `/var/run/secrets/kubernetes.io/serviceaccount` or query the cloud provider Metadata APIs (IMDSv2 at `169.254.169.254`) to steal IAM roles.

To satisfy the zero-trust paradigm in production platforms, Kubernetes architects implement multi-layered Defense-in-Depth isolation across four fundamental security boundaries: **Process/Kernel Isolation**, **Resource Boundary Enforcement**, **Network Micro-segmentation**, and **Tenant Node Placement**.

---

## 2. Deep Technical Comparison & Trade-off Matrices

### 2.1 Container Runtimes & Kernel Isolation Mechanisms

Standard `runc` relies entirely on Linux namespaces (`pid`, `net`, `mnt`, `ipc`, `uts`, `user`, `cgroup`) and capabilities. MicroVM and sandboxed runtimes interpose a virtualization layer or a user-space kernel between the container application and the host Linux kernel.

| Technology Layer | `runc` (Standard OCI) | `gVisor` (`runsc`) | `Kata Containers` | User Namespaces (`userns`) |
| :--- | :--- | :--- | :--- | :--- |
| **Isolation Mechanism** | Native Linux Namespaces & cgroups v2 | User-space Kernel Sentry intercepting syscalls | Hardware-assisted lightweight KVM microVM | Maps container `root` (UID 0) to unprivileged host UID |
| **Syscall Attack Surface** | Full Direct Host Kernel Syscall Exposure (~300+ syscalls) | Reduced host kernel surface (~20 restricted syscalls via Sentry) | Hardware virtualization barrier (Intel VT-x / AMD-V) | Native host syscall surface, but root privileges neutered on host |
| **CPU / Memory Overhead** | Near-zero overhead (~0-1%) | Low CPU overhead, moderate memory overhead (Sentry buffer memory) | Higher boot latency (~1-2s), ~30-50MB RAM per Pod microVM | Zero performance overhead |
| **I/O & Network Latency** | Native Linux VFS / socket throughput | Intercepted File I/O overhead; higher latency for socket operations | VFIO/vhost-net performance; slight virtio-fs overhead | Native I/O performance |
| **Hardware Requirements** | Standard x86_64 / ARM64 hardware | Standard x86_64 / ARM64 hardware | Nested Virtualization support required on cloud VMs | Requires Linux Kernel >= 6.3 and Kubernetes >= v1.30 (Beta/GA) |
| **Best Production Use Case** | Trusted internal microservices | Untrusted multi-tenant code execution, webhooks, serverless functions | Legacy monolithic workloads, highly untrusted multi-tenant workloads | General workload security hardening without performance penalty |

---

### 2.2 Network Isolation & Segmentation Engines

Network isolation in Kubernetes ranges from Layer 3/4 IP/Port filtering (Kubernetes `NetworkPolicy`) to Layer 7 Application Security Policies (Service Mesh / eBPF-native CNI).

| Dimension | Native `NetworkPolicy` (iptables/IPVS) | `CiliumNetworkPolicy` (eBPF Native) | Service Mesh (Istio / Linkerd mTLS + Authz) |
| :--- | :--- | :--- | :--- |
| **OSI Layer Enforcement** | Layer 3 (IP) & Layer 4 (TCP/UDP/SCTP) | Layer 3, Layer 4, Layer 7 (HTTP, gRPC, DNS, Kafka) | Layer 7 (HTTP/1.1, HTTP/2, gRPC, mTLS identity) |
| **Data Path Implementation** | Linux Kernel `iptables` rule chain traversal / `IPVS` | Linux Kernel Socket Layer eBPF programs (`tc`, `cgroup-skb`) | User-space Sidecar Proxy (Envoy) or Ambient node-proxy |
| **Kernel Overhead** | $O(N)$ rule evaluation scaling issue with large pod/service counts | $O(1)$ Hash table lookups via eBPF maps | Context switching overhead between user-space proxy & host kernel |
| **DNS-Aware Filtering** | No (CIDR blocks and Pod/Namespace Selectors only) | Yes (e.g., allow egress to `*.amazonaws.com` only) | Yes (via Envoy Service Entries and Virtual Services) |
| **Identity Primitives** | Pod Labels, Namespace Labels, IP Blocks | Pod Labels, Namespace Labels, SPIFFE IDs, FQDNs | SPIFFE/SPIRE X.509 Cryptographic Certificates |

---

## 3. End-to-End Complete Production YAML Manifests

The following manifests construct a multi-tenant isolation baseline containing:
1. Pod Security Admission (`PSA`) enforcing `restricted` standards at the namespace level.
2. Micro-segmentation via zero-trust ingress and egress `NetworkPolicy`.
3. MicroVM Sandboxing via a custom `RuntimeClass` bound to gVisor (`runsc`).
4. Hardened security context enforcing `seccomp`, `AppArmor`, non-root user, and root filesystem read-only locks.

### 3.1 Infrastructure Definition: Hardened Namespace with PSA Governance

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-secure-apps
  labels:
    environment: production
    tenant: secure-billing
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

---

### 3.2 Runtime Isolation: Sandboxed RuntimeClass (gVisor)

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor-sandbox
handler: runsc
scheduling:
  nodeSelector:
    sandbox.security.kubernetes.io/gvisor: "true"
  tolerations:
    - key: "security.kubernetes.io/untrusted-workload"
      operator: "Exists"
      effect: "NoSchedule"
```

---

### 3.3 Network Isolation: Default Deny-All (Ingress & Egress) NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-secure-apps
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

---

### 3.4 Network Isolation: Explicit Zero-Trust Micro-Segmentation NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-payment-processor-policy
  namespace: tenant-secure-apps
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
      tier: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow incoming traffic ONLY from API Gateway pods in the frontend namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: tenant-frontend-apps
          podSelector:
            matchLabels:
              app.kubernetes.io/name: api-gateway
      ports:
        - protocol: TCP
          port: 8443
  egress:
    # Allow outgoing TCP traffic ONLY to internal Database pods in secure namespace
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql-cluster
              tier: database
      ports:
        - protocol: TCP
          port: 5432
    # Allow outgoing UDP traffic ONLY to Cluster CoreDNS for service discovery
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
```

---

### 3.5 Workload Definition: Production MicroVM-Sandboxed & Hardened Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: tenant-secure-apps
  labels:
    app.kubernetes.io/name: payment-processor
    tier: backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-processor
      tier: backend
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-processor
        tier: backend
    spec:
      runtimeClassName: gvisor-sandbox
      serviceAccountName: payment-processor-sa
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: payment-app
          image: registry.enterprise.internal/finance/payment-processor:v2.4.1
          imagePullPolicy: Always
          command:
            - "/app/payment-service"
          args:
            - "--config=/etc/payment/config.json"
            - "--port=8443"
          ports:
            - containerPort: 8443
              name: https-api
              protocol: TCP
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
            requests:
              cpu: 250m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: config-volume
              mountPath: /etc/payment
              readOnly: true
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: config-volume
          configMap:
            name: payment-processor-config
```

---

## 4. Hands-on Terminal Execution: Real CLI Commands & Expected Output

### 4.1 Verifying Pod Security Admission Enforce Rules

Attempting to apply an unhardened Pod manifest to the `tenant-secure-apps` namespace must trigger an immediate admission webhook rejection from the API server.

```bash
$ kubectl run privilege-test-pod \
  --image=busybox:1.36 \
  --namespace=tenant-secure-apps \
  --restart=Never \
  -- privileged \
  -- command sleep 3600
```

**Expected Exact Output:**
```text
Error from server (Forbidden): pods "privilege-test-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "privilege-test-pod" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "privilege-test-pod" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "privilege-test-pod" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "privilege-test-pod" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### 4.2 Verifying Node and MicroVM Isolation via RuntimeClass

Inspect the running payment pod to confirm that the `gvisor-sandbox` RuntimeClass is assigned and intercepted by the `runsc` handler.

```bash
$ kubectl get pod -n tenant-secure-apps -l app.kubernetes.io/name=payment-processor -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.runtimeClassName}{"\t"}{.status.phase}{"\n"}{end}'
```

**Expected Exact Output:**
```text
payment-processor-7b996799-2x58n	gvisor-sandbox	Running
payment-processor-7b996799-8k7l2	gvisor-sandbox	Running
payment-processor-7b996799-m9p4q	gvisor-sandbox	Running
```

Verify kernel isolation inside the pod using `dmesg` or `uname -a`. Under gVisor (`runsc`), the kernel release string explicitly identifies the user-space sandbox engine:

```bash
$ kubectl exec -it deployment/payment-processor -n tenant-secure-apps -- uname -a
```

**Expected Exact Output:**
```text
Linux payment-processor-7b996799-2x58n 4.4.0 #1 SMP Sun Jan 10 00:00:00 2016 x86_64 Linux (gVisor runsc)
```

---

### 4.3 Testing NetworkPolicy Isolation (Egress Micro-segmentation Verification)

Test network reachability from inside the `payment-processor` container to unauthorized endpoints vs. allowed endpoints.

#### A. Unauthorized Egress Attempt (Public Internet / Unauthorized IP):

```bash
$ kubectl exec -it deployment/payment-processor -n tenant-secure-apps -- nc -zvw3 1.1.1.1 53
```

**Expected Exact Output:**
```text
nc: connect to 1.1.1.1 port 53 (tcp) timed out
```

#### B. Authorized CoreDNS Resolution Egress Attempt:

```bash
$ kubectl exec -it deployment/payment-processor -n tenant-secure-apps -- nslookup postgresql-cluster.tenant-secure-apps.svc.cluster.local
```

**Expected Exact Output:**
```text
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	postgresql-cluster.tenant-secure-apps.svc.cluster.local
Address: 10.244.2.45
```

---

### 4.4 Auditing Syscall Boundaries via Seccomp and Capabilities

Inspect container status directly via `/proc` within host node context to verify capability bitmasks drop status:

```bash
$ crictl inspect $(crictl ps --name payment-app -q) | jq '.info.runtimeSpec.process.capabilities'
```

**Expected Exact Output:**
```json
{
  "bounding": [],
  "effective": [],
  "inheritable": [],
  "permitted": []
}
```

---

## 5. Verification, Failure Modes & Diagnostic Troubleshooting Guide

### 5.1 Systemic Failure Modes Matrix

```
       +-----------------------------------------------------------------------+
       |                        DIAGNOSTIC WORKFLOW                            |
       |                                                                       |
       |  [Workload Fails to Start / Network Connection Rejected]              |
       |                                  |                                    |
       |            +---------------------+---------------------+              |
       |            |                                           |              |
       |            v                                           v              |
       |  [Pod Status: CreateContainerError /       [Pod Running, but traffic  |
       |   Syscall Operation Not Permitted]          silently dropped / 504]   |
       |            |                                           |              |
       |            v                                           v              |
       |  Check SecComp / AppArmor / PSA           Check NetworkPolicy CNI     |
       |  Audit Logs (/var/log/audit/audit.log)   Evaluations (cilium/calico) |
       +-----------------------------------------------------------------------+
```

| Symptom | Root Cause | Diagnostic Log / Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| `PodStatus: CrashLoopBackOff` or `ErrImagePull` | Missing taint toleration or invalid `RuntimeClass` handler mapping on target node | `kubectl describe pod <pod-name>` <br> Look for `FailedCreatePodSandBox` | Verify `containerd` config (`/etc/containerd/config.toml`) includes `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]` |
| `Read-only file system` runtime crash | Application attempts to write log files or state into container root `/` | `kubectl logs <pod-name> --previous` | Mount an `emptyDir` memory volume at required write locations (e.g., `/tmp`, `/var/log`) |
| `Operation not permitted` during syscall | `seccomp` profile or dropped Linux Capability blocking application call | `journalctl -u auditd -f` or `/var/log/audit/audit.log` looking for `type=SECCOMP` | Capture system call using `strace` or eBPF `bpfcc-tools` (syscount) and create a custom `Localhost` seccomp profile |
| DNS resolution succeeds, but TCP handshake hangs indefinitely | `NetworkPolicy` allows DNS egress (port 53), but drops target database IP/Port (port 5432) egress | `cilium monitor --type drop` OR `iptables-save \| grep DROP` | Update target `NetworkPolicy` egress `to:` block matching target `podSelector` or `cidr` |
| Inter-namespace communication fails unexpectedly | Missing required `kubernetes.io/metadata.name` label on target namespace | `kubectl get ns --show-labels` | Add metadata labels to namespaces targeted by `namespaceSelector` |

---

### 5.2 Deep-Dive Diagnostic Commands

#### 1. CNI NetworkPolicy Drop Tracing (Cilium Engine)
When using eBPF-based CNIs (Cilium), native `iptables` logging is bypassed. Use `cilium` CLI tools directly on the node to capture eBPF drop events real-time:

```bash
# Execute within Cilium agent pod on target node
$ kubectl exec -n kube-system daemonset/cilium -- cilium monitor --type drop --reason Policy_denied
```

**Diagnostic Output:**
```text
xx drop (Policy denied) flow 0x3f5c71d to endpoint 1042, code 133:'Policy rejected by eBPF' identity 52145->18432 egress IP 10.244.1.12:48392->10.244.2.45:5432 TCP Syn
```

#### 2. Audit Trail System Call Verification (`auditd`)
If a container fails due to Seccomp profile isolation, inspect the host operating system audit log:

```bash
$ sudo grep -i "SECCOMP" /var/log/audit/audit.log | tail -n 5
```

**Diagnostic Output:**
```text
type=SECCOMP msg=audit(1691428392.124:9482): auid=4294967295 uid=10001 gid=10001 ses=4294967295 subj=unconfined pid=48201 comm="payment-service" exe="/app/payment-service" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a12b3e8a0 code=0x0
```
*Note: `syscall=165` corresponds to `mount` on x86_64, indicating an unauthorized filesystem mount attempt blocked by `RuntimeDefault` seccomp profile.*

---

## 6. References

- **CNCF KCSA Exam Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- **Kubernetes Documentation - Network Policies**:  
  https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **Kubernetes Documentation - Pod Security Admission (PSA)**:  
  https://kubernetes.io/docs/concepts/security/pod-security-admission/
- **Kubernetes Documentation - RuntimeClass**:  
  https://kubernetes.io/docs/concepts/containers/runtime-class/
- **gVisor Architecture & Security Boundaries**:  
  https://gvisor.dev/docs/architecture_guide/
- **Kata Containers Architecture & Virtualization**:  
  https://katacontainers.io/
- **Cilium eBPF-based Network Policies Reference**:  
  https://docs.cilium.io/en/stable/security/policy/