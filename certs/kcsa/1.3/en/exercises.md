# KCSA Study Guide: Topic 1.3 — Controls and Frameworks

**Domain:** Cloud Native Security Basics  
**Weight:** 14% (Subtopic 1.3: Controls and Frameworks ~ 2.33%)  
**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  

---

## 1. Deep Technical Mechanics & Architecture Overview

Security controls and frameworks establish standardized baselines for assessing risk, enforcing compliance, and implementing defense-in-depth across the container lifecycle. In production Kubernetes environments, platforms must adhere to overlapping regulatory and technical standards.

```
+-----------------------------------------------------------------------------------+
|                        SECURITY CONTROLS & FRAMEWORKS ARCHITECTURE                |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  +---------------------+   +---------------------+   +--------------------------+ |
|  | NIST SP 800-190       |   | CIS Benchmarks      |   | NSA/CISA K8s Hardening   | |
|  | Container Risk Domains| |   | Technical Audits    |   | Operational Baselines    | |
|  +----------+----------+   +----------+----------+   +------------+-------------+ |
|             |                         |                           |               |
|             v                         v                           v               |
|  +------------------------------------------------------------------------------+ |
|  |                         MITRE ATT&CK for Containers                          | |
|  |                 Threat Vectors & Adversary Tactic Mapping                    | |
|  +------------------------------------+-----------------------------------------+ |
|                                       |                                           |
|                                       v                                           |
|  +------------------------------------------------------------------------------+ |
|  |                     POLICY ENFORCEMENT ENGINE IN K8S                         | |
|  | (Pod Security Standards / OPA Gatekeeper / Kyverno Admission Controllers)     | |
|  +------------------------------------------------------------------------------+ |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### Key Framework Breakdown & Trade-Off Matrix

1. **NIST SP 800-190 (Application Container Security Guide)**
   - **Core Focus:** Categorizes container security risks across 5 distinct tiers: Image, Registry, Orchestrator, Container, and Host OS.
   - **Architectural Trade-off:** Enforcing strict image signing and scanning gates at the registry tier reduces deployment velocity but eliminates vulnerable binaries prior to runtime.

2. **CIS Kubernetes Benchmarks**
   - **Core Focus:** Prescriptive, system-level configuration hardening checks for API server, Kubelet, etcd, Controller Manager, Scheduler, and worker nodes.
   - **Architectural Trade-off:** Disabling API Server `anonymous-auth` or enforcing `TLS 1.3` hardens control plane transport but breaks legacy telemetry collectors and external load balancer health probes if not reconfigured with proper client certificates.

3. **NSA/CISA Kubernetes Hardening Guidance**
   - **Core Focus:** Operational threat mitigation guidelines focusing on Pod security (non-root execution, immutable root filesystems), network isolation, RBAC least-privilege, audit logging, and data encryption at rest.
   - **Architectural Trade-off:** Enforcing read-only root filesystems requires explicit `emptyDir` or persistent volume mounts for application write paths (e.g., `/tmp`, log directories), increasing manifest complexity.

4. **MITRE ATT&CK® for Containers**
   - **Core Focus:** Matrix of real-world adversary tactics (e.g., Initial Access `T1610`, Execution `T1609`, Escape to Host `T1611`, Privilege Escalation `T1612`, Discovery `T1613`).
   - **Architectural Trade-off:** Restricting `pods/exec` API access mitigates `T1609` (Execution into Container) but hampers traditional interactive debugging, requiring SREs to adopt ephemeral debug containers (`kubectl debug`).

---

## 2. Guided Production Exercises

### Exercise 1: Auditing Kubernetes Control Plane & Worker Nodes using `kube-bench` (CIS Benchmark Compliance)

#### Step 1: Deploy `kube-bench` as a Kubernetes Job targeting Master Node Configurations
Execute `kube-bench` using the official CIS benchmark specification targeting Kubernetes 1.28+ control plane configurations.

Create the file `kube-bench-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: default
spec:
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:v0.7.3
          command: ["kube-bench", "run", "--targets", "master", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
```

Submit the Job and retrieve logs:

```bash
kubectl apply -f kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench-master --timeout=60s
kubectl logs job/kube-bench-master | jq '.tests[] | .results[] | select(.status=="FAIL")'
```

**Expected Terminal Output:**

```json
{
  "test_number": "1.1.12",
  "test_desc": "Ensure that the --anonymous-auth argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-apiserver | grep -v grep",
  "status": "FAIL",
  "remediation": "Edit the manifest file /etc/kubernetes/manifests/kube-apiserver.yaml on the control plane node and set --anonymous-auth=false",
  "scored": true
}
{
  "test_number": "1.2.19",
  "test_desc": "Ensure that the --profiling argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-scheduler | grep -v grep",
  "status": "FAIL",
  "remediation": "Edit the manifest file /etc/kubernetes/manifests/kube-scheduler.yaml on the control plane node and set --profiling=false",
  "scored": true
}
```

#### Step 2: Remediate CIS Item 1.1.12 on the Kube-APIServer
Inspect `/etc/kubernetes/manifests/kube-apiserver.yaml` on the master node and apply remediation.

```bash
# Verify current process arguments on control plane node
ps aux | grep kube-apiserver | grep anonymous-auth
```

**Expected Terminal Output:**

```text
root     12431  4.2  8.1 1143200 663410 ?    Ssl  18:10   0:45 kube-apiserver --anonymous-auth=true --authorization-mode=Node,RBAC ...
```

Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` to include:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --anonymous-auth=false
```

Verify Kubelet automatically restarts the static Pod container:

```bash
crictl ps --name kube-apiserver
```

#### Step 3: Re-verify CIS Compliance

```bash
kubectl delete job kube-bench-master
kubectl apply -f kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench-master --timeout=60s
kubectl logs job/kube-bench-master | jq '.tests[].results[] | select(.test_number=="1.1.12")'
```

**Expected Terminal Output:**

```json
{
  "test_number": "1.1.12",
  "test_desc": "Ensure that the --anonymous-auth argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-apiserver | grep -v grep",
  "status": "PASS",
  "remediation": "",
  "scored": true
}
```

---

### Verification Questions — Section 1

1. **Question 1.1:** Why does CIS Benchmark 1.1.12 explicitly require `--anonymous-auth=false` on the API server, and what mechanism must be configured if unauthenticated health checks (`/healthz` or `/livez`) fail after applying this control?
2. **Question 1.2:** In NIST SP 800-190, running containerized workloads with root privileges falls primarily under which vector, and how does the host OS kernel isolate UID 0 inside a container from host UID 0 if user namespaces are disabled?

---

### Exercise 2: Implementing NSA/CISA Hardening Baselines with Pod Security Standards (PSS) & Kyverno Policy Enforcement

#### Step 1: Label Namespace for PSS Enforce Mode
Enforce the native Kubernetes `restricted` Pod Security Standard (PSS) at the namespace level as specified in NSA/CISA Hardening recommendations.

```bash
kubectl create namespace production-sec
kubectl label --overwrite namespace production-sec \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
```

**Expected Terminal Output:**

```text
namespace/production-sec created
namespace/production-sec labeled
```

#### Step 2: Deploy a Syntactically Complete, Compliant Production Pod
Create `compliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-api-worker
  namespace: production-sec
  labels:
    app.kubernetes.io/name: secure-api-worker
    app.kubernetes.io/part-of: payment-pipeline
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ccr.io/google-containers/pause:3.9
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          cpu: "250m"
          memory: "128Mi"
        requests:
          cpu: "100m"
          memory: "64Mi"
      volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
  volumes:
    - name: tmp-volume
      emptyDir: {}
```

Apply the manifest:

```bash
kubectl apply -f compliant-pod.yaml
```

**Expected Terminal Output:**

```text
pod/secure-api-worker created
```

#### Step 3: Implement an Enterprise Policy Guardrail using Kyverno
Deploy a Kyverno `ClusterPolicy` to enforce that NO pods across the cluster can run without an explicit `readOnlyRootFilesystem: true` setting (NSA/CISA Hardening Section: Container Security).

Create `kyverno-readonly-rootfs.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-readonly-rootfilesystem
  annotations:
    policies.kyverno.io/title: Enforce Read-Only Root Filesystem
    policies.kyverno.io/category: NSA/CISA Pod Security Hardening
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-read-only-rootfs
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "NSA/CISA Compliance Violation: Container root filesystem must be read-only (securityContext.readOnlyRootFilesystem=true)."
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true
```

Apply the policy:

```bash
kubectl apply -f kyverno-readonly-rootfs.yaml
```

#### Step 4: Test Policy Enforcement with a Non-Compliant Pod Manifest
Create `non-compliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-worker
  namespace: production-sec
spec:
  containers:
    - name: app
      image: nginx:alpine
```

Attempt to apply the non-compliant manifest:

```bash
kubectl apply -f non-compliant-pod.yaml
```

**Expected Terminal Output:**

```text
Error from server (Forbidden): error when creating "non-compliant-pod.yaml": pods "insecure-worker" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### Verification Questions — Section 2

1. **Question 2.1:** A container defines `securityContext.readOnlyRootFilesystem: true`. However, the application requires writing temporary lock files to `/run/lock`. What is the secure architectural pattern recommended by NSA/CISA guidelines to support this requirement without setting `readOnlyRootFilesystem: false`?
2. **Question 2.2:** What is the technical operational difference between applying PSS labels in `enforce` mode versus `warn` or `audit` mode on a namespace containing existing running workloads?

---

### Exercise 3: Threat Modeling & Mitigating MITRE ATT&CK Tactics (T1609 & T1611) with RBAC & NetworkPolicies

#### Step 1: Analyze Threat Vector T1609 (Execution into Container)
Adversaries leverage the `pods/exec` API subresource to obtain interactive shells inside compromised containers for lateral movement (`T1210`) and credential discovery (`T1552`).

Audit existing cluster role permissions to find identities capable of executing commands inside containers:

```bash
kubectl get clusterroles -o json | jq -r '.items[] | select(.rules[]? | select(.resources[]? == "pods/exec" and (.verbs[]? == "create" or .verbs[]? == "*"))) | .metadata.name'
```

**Expected Terminal Output:**

```text
admin
cluster-admin
edit
developer-exec-role
```

#### Step 2: Implement Least-Privilege Scoped RBAC for Debugging
Restrict `pods/exec` to a dedicated emergency role limited to specific namespaces, preventing arbitrary cluster-wide shell access.

Create `exec-least-privilege-rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-sec
  name: SreContainerDebugger
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-sre-debugger
  namespace: production-sec
subjects:
  - kind: User
    name: platform-sre@company.internal
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: SreContainerDebugger
  apiGroup: rbac.authorization.k8s.io
```

Apply the RBAC policy:

```bash
kubectl apply -f exec-least-privilege-rbac.yaml
```

Validate user permissions via `kubectl auth can-i`:

```bash
kubectl auth can-i create pods/exec --as=platform-sre@company.internal -n production-sec
kubectl auth can-i create pods/exec --as=platform-sre@company.internal -n kube-system
```

**Expected Terminal Output:**

```text
yes
no
```

#### Step 3: Mitigate Container Escape & Lateral Movement (MITRE T1611 / T1210) via NetworkPolicy
Block container-to-metadata service access (e.g., AWS/GCP Instance Metadata Service `169.254.169.254`) and enforce strict egress zero-trust default-deny.

Create `default-deny-egress-metadata.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-cloud-metadata-and-default-deny-egress
  namespace: production-sec
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Allow intra-namespace pod-to-pod communication
    - to:
        - podSelector: {}
    # Allow CoreDNS access (port 53 UDP/TCP)
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
    # Explicitly exclusion rule: Traffic to external services allowed EXCEPT 169.254.169.254/32
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

Apply the NetworkPolicy:

```bash
kubectl apply -f default-deny-egress-metadata.yaml
```

Test metadata block from inside the compliant Pod:

```bash
kubectl exec -n production-sec secure-api-worker -- wget -qO- --timeout=2 http://169.254.169.254/latest/meta-data/
```

**Expected Terminal Output:**

```text
wget: download timed out
command terminated with exit code 1
```

---

### Verification Questions — Section 3

1. **Question 3.1:** According to MITRE ATT&CK for Containers, what is the exact mechanism behind tactic `T1611` (Escape to Host) when a container is executed with `hostPID: true` and `privileged: true`?
2. **Question 3.2:** Why is CoreDNS access (UDP/TCP port 53) explicitly required in the egress rule of a default-deny NetworkPolicy, and what security vulnerability is introduced if an egress rule allows `0.0.0.0/0` on all ports without DNS restrictions?

---

## 3. Official References & URLs

- **CNCF KCSA Curriculum Specification:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

- **NIST Special Publication 800-190 (Application Container Security Guide):**  
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)

- **NSA/CISA Kubernetes Hardening Guidance:**  
  [https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_FINAL_20220829.PDF](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_FINAL_20220829.PDF)

- **CIS Kubernetes Benchmarks:**  
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)

- **MITRE ATT&CK® for Containers Matrix:**  
  [https://attack.mitre.org/matrices/enterprise/containers/](https://attack.mitre.org/matrices/enterprise/containers/)

- **Kubernetes Pod Security Standards (PSS):**  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

## 4. Verification Answers and Explanations

<details>
<summary>Click here to expand solutions for all verification questions</summary>

### Section 1 Answers

* **Answer 1.1:**  
  Setting `--anonymous-auth=false` ensures that any request presented without explicit credentials (such as client certificates, bearer tokens, or HTTP basic auth headers) is rejected immediately with HTTP `401 Unauthorized` instead of being assigned the `system:anonymous` user and `system:unauthenticated` group.  
  *Remediation for Health Checks:* If health checks fail after disabling anonymous authentication, the Kubelet or monitoring system must be configured to pass valid client credentials or leverage the designated non-authenticated endpoints (`/livez`, `/readyz`, `/healthz`) which can be exposed securely via dedicated API Server authorization exceptions (`--authorization-mode` configuration allowing health paths to `system:anonymous` explicitly via `ClusterRoleBinding` to `system:public-info-viewer` if needed, or by allowing Kubelet local probes to authenticate via service account/client certs).

* **Answer 1.2:**  
  In NIST SP 800-190, container root execution falls under **Container Risks (Section 3.4: App Vulnerabilities & Runtime Privileges)** and **Host OS Risks (Section 3.5)**.  
  If Linux User Namespaces (`userns`) are *disabled* (the default configuration in standard Docker/containerd container runtimes), UID 0 inside the container maps directly to UID 0 on the underlying host kernel. Isolation relies solely on Linux Control Groups (cgroups), Namespaces (mnt, pid, net, ipc, uts), Linux Capabilities, and LSMs (AppArmor/SELinux). If an attacker breaks out of the container boundary via a kernel vulnerability or volume mount exploit, they instantly possess full host-level root privileges.

---

### Section 2 Answers

* **Answer 2.1:**  
  The recommended architectural pattern is to keep `readOnlyRootFilesystem: true` on the container security context and explicitly mount an ephemeral, in-memory volume (`emptyDir` with `medium: Memory` or standard `emptyDir: {}`) at the specific path requiring write capabilities (e.g., `/run/lock` or `/tmp`). This isolates mutation to a temporary volume while leaving the base container filesystem immutable, preventing file tampering or persistence attacks (`T1543`).

* **Answer 2.2:**  
  Applying Pod Security Standards labels in `enforce` mode causes the Kubernetes API server admission controller to immediately reject any new pod creation or deployment update that violates the policy. However, `enforce` mode does **not** terminate or modify pods that were already running prior to applying the label.  
  Conversely, `warn` mode permits pod creation while returning a human-readable warning header in the `kubectl` output or API response, and `audit` mode records an audit event log without blocking pod creation. SRE teams use `warn` and `audit` to evaluate policy impacts on existing workloads before switching to `enforce`.

---

### Section 3 Answers

* **Answer 3.1:**  
  When a container is deployed with `hostPID: true`, it shares the host node's process namespace, enabling it to view and interact with all processes running on the host OS. When combined with `privileged: true`, the container runtime disables all Linux capability restrictions (granting `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, etc.), turns off AppArmor/SELinux profiles, and exposes host devices under `/dev`.  
  An adversary can use `nsenter` (or access `/host/proc/1/ns/mnt`) to switch into the host mount namespace, effectively escaping the container containerization boundaries (`T1611`) and gaining full root shell access on the underlying node.

* **Answer 3.2:**  
  CoreDNS resolution is required because Kubernetes services and external API endpoints are referenced via Domain Names (FQDNs). If DNS traffic (UDP/TCP port 53 to `kube-dns`) is blocked by a default-deny egress policy, the application cannot resolve service IP addresses, breaking inter-service communication and external API calls.  
  If an egress policy permits `0.0.0.0/0` across all ports without network segmentation or DNS filtering, an adversary executing code inside a compromised container can establish outbound Command & Control (C2) channels (`T1071`), exfiltrate sensitive data/tokens to arbitrary public IP addresses, or connect to rogue external endpoints.

</details>