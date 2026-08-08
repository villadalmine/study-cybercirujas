# KCSA Study Guide — Domain 6.2: Threat Modeling Frameworks

**Exam Target:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 6:** Cloud Native Security & Threat Landscape  
**Subtopic 6.2:** Threat Modeling Frameworks  
**Weight:** 2.5%  
**Official References:**
* [CNCF KCSA Curriculum (v1.0+)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* [CNCF Cloud Native Security Whitepaper v2](https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cncf-security-whitepaper-v2.pdf)
* [MITRE ATT&CK® Matrix for Containers](https://attack.mitre.org/matrices/enterprise/containers/)
* [NIST SP 800-190: Application Container Security Guide](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf)

---

## Technical Overview & Architecture

Threat modeling in cloud-native environments requires decomposing a Kubernetes architecture into its core components (API server, etcd, Kubelet, container runtime, ingress controllers, service mesh, workloads) and systematically evaluating attack vectors.

```
       +-----------------------------------------------------------------------+
       |                      TRUST BOUNDARY: EXTERNAL / INGRESS              |
       +-----------------------------------------------------------------------+
                                           |
                                           v
    +-----------------------------------------------------------------------------+
    |                         KUBERNETES CONTROL PLANE                            |
    |  +--------------------+     +-------------------+     +------------------+  |
    |  | kube-apiserver     |<--->| kube-scheduler    |<--->| etcd (TLS/mTLS)  |  |
    |  | (AuthN/AuthZ/RBAC) |     +-------------------+     +------------------+  |
    |  +--------------------+                                                     |
    +-----------------------------------------------------------------------------+
               |                                                   |
     TRUST BOUNDARY: CONTROL PLANE TO WORKER             TRUST BOUNDARY: INTER-POD
               |                                                   |
               v                                                   v
    +-----------------------------+                     +-------------------------+
    |      WORKER NODE 01         |                     |     WORKER NODE 02      |
    |  +-----------------------+  |    NetworkPolicy    |  +-------------------+  |
    |  | kubelet (Port 10250)  |  | <-----------------> |  | Pod B (Restricted)|  |
    |  +-----------------------+  |   (mTLS via CNI)    |  +-------------------+  |
    |  | Pod A (Compromised)   |  |                     +-------------------------+
    |  | - ServiceAccount Token|  |
    |  | - HostPath Mount      |  |
    |  +-----------------------+  |
    +-----------------------------+
```

### Core Frameworks in Cloud Native Threat Modeling
1. **STRIDE** (*Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege*): A taxonomy used to identify specific threat categories across data flows and trust boundaries within Kubernetes clusters.
2. **MITRE ATT&CK® for Containers**: A matrix detailing real-world adversary tactics, techniques, and procedures (TTPs) specific to container runtime environments, container orchestrators, and cloud infrastructures.
3. **DREAD** (*Damage, Reproducibility, Exploitability, Affected Users, Discoverability*): A risk rating methodology for quantifying threat severity to prioritize mitigation efforts.
4. **PASTA** (*Process for Attack Simulation and Threat Analysis*): An enterprise risk-centric threat modeling methodology that aligns technical vulnerabilities with business impact.

---

## Guided Hands-on Exercises

### Exercise 1: Applying the STRIDE Framework to Kubernetes Workloads & Control Plane

#### Step 1.1: Deploy an Over-Privileged Target Workload
Inspect and deploy a syntactically valid Kubernetes manifest containing common architectural security misconfigurations (host path mounts, unconfined capabilities, auto-mounted service account tokens).

```bash
cat << 'EOF' > stride-target.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-processor-sa
  namespace: payment-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: payment-processor-admin-binding
subjects:
- kind: ServiceAccount
  name: payment-processor-sa
  namespace: payment-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: payment-processor-sa
      automountServiceAccountToken: true
      containers:
      - name: api-container
        image: nginx:1.25-alpine
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
        - mountPath: /host/etc
          name: host-etc
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
          type: Directory
EOF

kubectl apply -f stride-target.yaml
```

**Expected Output:**
```
namespace/payment-system created
serviceaccount/payment-processor-sa created
clusterrolebinding.rbac.authorization.k8s.io/payment-processor-admin-binding created
deployment.apps/payment-api created
```

#### Step 1.2: Perform Diagnostic Auditing to Detect STRIDE Threats
Execute runtime verification commands to identify where STRIDE threats materialize in the deployed architecture.

```bash
# 1. Verify Service Account Token exposure (Information Disclosure / Elevation of Privilege)
kubectl exec -it deploy/payment-api -n payment-system -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/

# 2. Check token permissions via SelfSubjectAccessReview (Elevation of Privilege)
TOKEN=$(kubectl exec -it deploy/payment-api -n payment-system -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
kubectl auth can-i --list --token="$TOKEN"
```

**Expected Output:**
```
total 0
drwxrwxrwx    3 root     root           140 Aug  7 20:00 .
drwxr-xr-x    3 root     root            70 Aug  7 20:00 ..
lrwxrwxrwx    1 root     root            13 Aug  7 20:00 ca.crt -> ..data/ca.crt
lrwxrwxrwx    1 root     root            16 Aug  7 20:00 namespace -> ..data/namespace
lrwxrwxrwx    1 root     root            12 Aug  7 20:00 token -> ..data/token

Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             [*]                 []               [*]
                                                [*]                 []               [*]
```

#### Step 1.3: Remediate Workload Using STRIDE Hardening Constraints
Apply a hardened manifest enforcing Principle of Least Privilege (PoLP) across identity and container security contexts.

```bash
cat << 'EOF' > stride-hardened.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-processor-sa-hardened
  namespace: payment-system
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api-hardened
  namespace: payment-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api-hardened
  template:
    metadata:
      labels:
        app: payment-api-hardened
    spec:
      serviceAccountName: payment-processor-sa-hardened
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: api-container
        image: nginxinc/nginx-unprivileged:1.25-alpine
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
EOF

kubectl apply -f stride-hardened.yaml
```

**Expected Output:**
```
serviceaccount/payment-processor-sa-hardened created
deployment.apps/payment-api-hardened created
```

---

#### Verification Questions — Exercise 1
1. **[Spoofing]** How does setting `automountServiceAccountToken: false` prevent identity spoofing attacks within a Kubernetes cluster?
2. **[Elevation of Privilege / Tampering]** Why does mounting a `hostPath` directory (such as `/etc`) combined with `privileged: true` allow an attacker to escape the container runtime and compromise the underlying host node?
3. **[Information Disclosure]** Which standard API endpoint or protocol can be queried by an attacker inside a Pod to exfiltrate node metadata or cloud provider credentials if not blocked by a `NetworkPolicy`?

---

### Exercise 2: Mapping Attack Vectors to MITRE ATT&CK® for Containers & Diagnostic Auditing

#### Step 2.1: Simulate MITRE ATT&CK T1613 (Container and Resource Discovery)
Simulate an adversary discovering resources inside the cluster using unauthenticated/partially authenticated commands against node endpoints.

```bash
# Query the anonymous Kubelet read-only port or standard API server endpoint
kubectl get pods --all-namespaces -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,SA:.spec.serviceAccountName
```

**Expected Output:**
```
NAME                                    NODE       SA
payment-api-7b89799b6-x492l             worker-1   payment-processor-sa
payment-api-hardened-6c5df58c97-m9q2z   worker-2   payment-processor-sa-hardened
coredns-558bd4d5db-2l4z8                master-1   coredns
```

#### Step 2.2: Simulate MITRE ATT&CK T1059.004 (Unix Shell Access) & T1609 (Execution in Container)
Execute an in-memory command injection audit to trace exec calls in API server audit logs.

```bash
# 1. Trigger container execution
kubectl exec -n payment-system deploy/payment-api -- id

# 2. Inspect API Server Audit Log for the Exec Event (Run on Master/Control Plane node)
# Note: Path may vary depending on audit sink configuration (/var/log/kubernetes/audit.log)
grep -E '"verb":"create".*"subresource":"exec"' /var/log/kubernetes/audit.log | tail -n 1 | jq .
```

**Expected Output:**
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["system:masters", "system:authenticated"]
  },
  "objectRef": {
    "resource": "pods",
    "namespace": "payment-system",
    "name": "payment-api-7b89799b6-x492l",
    "subresource": "exec"
  },
  "responseStatus": {
    "metadata": {},
    "status": "Success",
    "code": 101
  }
}
```

#### Step 2.3: Mitigate Lateral Movement (T1210) using Strict NetworkPolicy
Deploy a zero-trust default-deny NetworkPolicy to isolate namespaces and block container-to-container lateral movement.

```bash
cat << 'EOF' > default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payment-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

kubectl apply -f default-deny-all.yaml
```

**Expected Output:**
```
networkpolicy.networking.k8s.io/default-deny-all created
```

---

#### Verification Questions — Exercise 2
1. In the MITRE ATT&CK® for Containers matrix, under which tactic does **Technique T1611 (Escape to Host)** fall, and what container security context parameters prevent it?
2. Which audit log field in `audit.k8s.io/v1` records the identity of a compromised ServiceAccount attempting lateral API calls?
3. What is the fundamental difference in risk exposure between MITRE Technique **T1068 (Exploitation for Privilege Escalation)** occurring inside an unconfined container versus a container enforced with a custom AppArmor/Seccomp profile?

---

### Exercise 3: Quantitative Threat Prioritization using DREAD & PASTA Methodologies

#### Step 3.1: Risk Scoring Matrix Construction
Evaluate three distinct Kubernetes production scenarios using the DREAD scoring system (Scale: 1 [Low] to 10 [High]). 

**DREAD Formula:**
$$\text{Risk Score} = \frac{\text{Damage} + \text{Reproducibility} + \text{Exploitability} + \text{Affected Users} + \text{Discoverability}}{5}$$

| Threat ID | Threat Description | Damage | Repr. | Exploit. | Aff. Users | Disc. | Overall DREAD | Priority |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **TH-01** | Exposed Kubelet API (Port 10250) with `Anonymous.Enabled=true` | 10 | 10 | 10 | 10 | 9 | **9.8** | Critical |
| **TH-02** | Unencrypted etcd datastore accessible from worker nodes | 10 | 8 | 7 | 10 | 6 | **8.2** | High |
| **TH-03** | Missing Egress NetworkPolicy allowing outbound internet traffic | 7 | 9 | 6 | 4 | 5 | **6.2** | Medium |

#### Step 3.2: Applying the 7 Stages of PASTA to Kubernetes Architectures
Understand how PASTA maps business impact to container security operations:

```
Stage 1: Define Objectives (Business Impact & Compliance Requirements)
   └── Stage 2: Define Technical Scope (Assets, Nodes, CNI, Control Plane)
        └── Stage 3: Application Decomposition (Data Flow Diagrams, Trust Boundaries)
             └── Stage 4: Threat Analysis (STRIDE, Threat Intelligence, ATT&CK)
                  └── Stage 5: Vulnerability Analysis (CVE Scanning, Misconfigurations)
                       └── Stage 6: Attack Modeling (Attack Trees, Exploitation Proof-of-Concepts)
                            └── Stage 7: Risk & Impact Analysis (Countermeasures, Remediation Cost)
```

#### Step 3.3: Diagnostic Validation of etcd Encryption at Rest (Mitigating TH-02)
Verify if etcd sensitive secrets are encrypted on disk to protect against host-level data exfiltration.

```bash
# Check API server configuration for encryption-provider-config flag
kubectl get pod -n kube-system -l component=kube-apiserver -o yaml | grep -- --encryption-provider-config
```

**Expected Output (if configured):**
```
- --encryption-provider-config=/etc/kubernetes/enc/config.yaml
```

If missing, secrets stored in etcd remain in plain-text base64 encoding, resulting in high DREAD score for Information Disclosure.

---

#### Verification Questions — Exercise 3
1. Calculate the DREAD score for a scenario where a Pod has access to `/var/run/docker.sock`:  
   * Damage: 10, Reproducibility: 9, Exploitability: 8, Affected Users: 9, Discoverability: 8. What is the calculated DREAD score and severity rating?
2. In Stage 3 of PASTA (Application Decomposition), what specific Kubernetes abstraction serves as the primary logical trust boundary between microservices?
3. Why is PASTA considered more suitable for enterprise risk compliance (e.g., PCI-DSS, SOC 2) in cloud-native deployments than pure STRIDE analysis?

---

<details>
<summary><strong>Click to View Solutions & Answers to Verification Questions</strong></summary>

### Answers — Exercise 1
1. **Spoofing Solution:** Disabling `automountServiceAccountToken` prevents Kubernetes from projecting the JWT credential into `/var/run/secrets/kubernetes.io/serviceaccount/`. Without this token, an attacker who gains remote code execution (RCE) inside a container cannot authenticate against the `kube-apiserver` as the Pod's identity.
2. **Elevation of Privilege / Tampering Solution:** A `privileged: true` container disables Linux kernel namespace protections and exposes host devices (`/dev`). Combined with a `hostPath` mount of `/etc`, an attacker can modify critical host files (e.g., `/etc/shadow`, `/etc/kubernetes/manifests`), inject malicious systemd services, or rewrite Kubelet configurations to escalate privileges to the underlying worker node root user.
3. **Information Disclosure Solution:** The Cloud Provider Metadata API endpoint (e.g., `169.254.169.254` for AWS/GCP/Azure) can be queried by unmitigated Pods to extract IAM role credentials, node bootstrap tokens, or instance identity documents. Egress `NetworkPolicy` objects or Instance Metadata Service version 2 (IMDSv2) enforced hops must be used to block unauthorized access.

### Answers — Exercise 2
1. **MITRE ATT&CK Matrix Solution:** Technique **T1611** falls under the **Privilege Escalation** (and **Privilege Escalation / Execution**) tactic. It is prevented by enforcing:
   * `allowPrivilegeEscalation: false`
   * `readOnlyRootFilesystem: true`
   * `capabilities.drop: ["ALL"]`
   * Non-root execution (`runAsNonRoot: true`)
   * Restricting `hostPath` and `hostPID`/`hostIPC`/`hostNetwork` in Pod Security Standards (Restricted profile).
2. **Audit Log Identification Solution:** The `user.username` field (e.g., `system:serviceaccount:payment-system:payment-processor-sa`) and `user.groups` identify the ServiceAccount credential making the API request.
3. **Privilege Escalation Vulnerability Exposure Solution:** An unconfined container running without Seccomp or AppArmor profile constraints permits system calls directly to the host Linux kernel (e.g., `unshare`, `ptrace`, `bpf`). A restricted container with `seccompProfile: {type: RuntimeDefault}` blocks dangerous syscalls, neutralizing kernel exploitation primitives even if a zero-day kernel vulnerability exists.

### Answers — Exercise 3
1. **DREAD Score Calculation:**
   $$\text{Score} = \frac{10 + 9 + 8 + 9 + 8}{5} = \frac{44}{5} = 8.8$$
   * **Rating:** Critical (Scores $\ge 8.0$ are classified as High/Critical). Mounting socket interfaces grants full control over the host engine runtime.
2. **PASTA Trust Boundary Solution:** The Kubernetes **Namespace** serves as the fundamental logical boundary, enforced alongside RBAC roles, `ResourceQuotas`, and `NetworkPolicies`.
3. **PASTA Enterprise Compliance Advantage:** PASTA incorporates business impact analysis (Stage 1) and threat intelligence (Stage 4) directly into attack simulation (Stage 6), allowing security teams to justify security control investments based on financial loss, regulatory non-compliance fines, and operational disruption rather than purely technical software bugs.

</details>