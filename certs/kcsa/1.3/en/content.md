# KCSA Domain 1.3: Controls and Frameworks

## 1. Production Architectural Motivation & Problem

In production enterprise Kubernetes environments, security cannot be managed as an ad-hoc checklist or reactive patching protocol. As cloud-native environments scale across multi-tenant clusters, diverse microservices, and continuous delivery pipelines, organizations encounter critical security management challenges:

1. **Drift and Inconsistent Enforcement**: Without automated guardrails, developer teams deploy workloads with varying security configurations—ranging from root execution (`runAsUser: 0`) and writable root filesystems to unconstrained network communication (`0.0.0.0/0`).
2. **Regulatory & Compliance Mapping**: Standard enterprise compliance frameworks (such as PCI-DSS, SOC 2, HIPAA, and ISO 27001) do not natively speak "Kubernetes". Security engineering teams must map high-level regulatory controls (e.g., Least Privilege, Data-in-Transit Encryption, Audit Logging) to low-level container runtime primitives.
3. **The 4Cs Security Model Vulnerability Gaps**: Security failures at higher layers cannot be mitigated by controls at lower layers, and vice versa. Securing the **Cloud** (IaaS infrastructure) does not compensate for weak **Code** or misconfigured **Containers**.

```
            +-------------------------------------------------------+
            |                        CODE                           |
            |   (Static Analysis, Secret Scanning, Dependencies)    |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                      CONTAINER                        |
            |     (Image Signing, Vulnerability Scanning, SBOM)     |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                       CLUSTER                         |
            |   (RBAC, NetworkPolicies, Pod Security, Audit Logs)   |
            +---------------------------+---------------------------+
                                        |
                                        v
            +-------------------------------------------------------+
            |                        CLOUD                          |
            |   (IAM, Node Hardening, VPC Segmentation, Encryption)  |
            +-------------------------------------------------------+
```

To resolve these architectural challenges, Cloud Native Security relies on structured **Security Frameworks** and actionable **Security Controls**:
* **Frameworks** (e.g., NIST SP 800-190, CIS Benchmarks, NSA/CISA Hardening Guide, CNCF TAG-Security Lifecycle Model, MITRE ATT&CK for Kubernetes) provide the governance structure, threat taxonomies, and control objectives.
* **Controls** (e.g., Pod Security Admission, Network Policies, OPA Gatekeeper/Kyverno policies, Seccomp profiles, RBAC restrictions) enforce the operational boundary within the cluster control plane and data plane.

---

## 2. Technical Comparison & Trade-Off Matrix

When selecting security controls and governance frameworks for production Kubernetes clusters, platform architects must balance security efficacy, operational overhead, performance impact, and implementation complexity.

| Control / Framework | Core Focus & Objective | Architectural Mechanism | Operational Overhead | Developer Friction | Primary Production Trade-Off |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Pod Security Admission (PSA)** | Built-in cluster workload enforcement (Privileged, Baseline, Restricted). | Admission Controller integrated into `kube-apiserver`. Evaluates Pod templates against PSS labels. | Low (Native feature, zero external dependencies). | Medium (Strict profiles break legacy images running as root). | Fast and lightweight, but lacks custom fine-grained rule logic (all-or-nothing per namespace label). |
| **OPA Gatekeeper** | Declarative policy enforcement via custom Rego logic. | Validating/Mutating Webhook Controller using Open Policy Agent engine. | High (Requires managing OPA CRDs, Gatekeeper pods, Rego DSL expertise). | Medium to High (Complex Rego syntax learning curve). | Extremely expressive custom validation, but higher latency overhead and memory footprint on control plane. |
| **Kyverno** | Kubernetes-native policy management using YAML CRDs. | Validating/Mutating/Generating Webhook Controller operating natively on K8s resources. | Medium (Requires managing Kyverno controller state and CRDs). | Low (Uses familiar K8s YAML declarative structure). | High developer ergonomics in native YAML, but less expressive than Turing-complete Rego for multi-resource context matching. |
| **CIS Kubernetes Benchmark** | Node and Control Plane hardening baseline recommendations. | Auditing scripts checking file permissions, flags on API server, etcd, kubelet (`kube-bench`). | Low (Runs as standard CronJob or host utility). | None (Non-blocking operational assessment tool). | Comprehensive configuration assessment, but audit-only (requires secondary tooling to enforce remediations). |
| **NIST SP 800-190** | Application Container Security Architecture Standards. | Governance framework categorizing risks across Image, Registry, Orchestrator, Container, Host. | High (Strategic compliance alignment across organizational teams). | Low (Framework level, not direct CLI friction). | Covers end-to-end lifecycle security, but abstract—requires translation into concrete K8s manifests and CI/CD gates. |

---

## 3. Production Manifests & Infrastructure Configurations

### 3.1. Cluster-Wide PodSecurityConfiguration (`kube-apiserver` configuration)

The following manifest defines a complete, syntactically valid `PodSecurityConfiguration` file passed to the `kube-apiserver` via `--admission-control-config-file`. It enforces the `restricted` profile by default across all namespaces while establishing warn and audit modes.

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "restricted"
  enforce-version: "latest"
  warn: "restricted"
  warn-version: "latest"
  audit: "restricted"
  audit-version: "latest"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces:
    - kube-system
    - cert-manager
    - ingress-nginx
```

### 3.2. Production Namespace with Pod Security Standards Enforced via Labels

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-service-prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
```

### 3.3. Fully Compliant Restricted Workload Manifest

This Deployment strictly adheres to the **PSS Restricted Profile**, **CIS Benchmark recommendations**, and **NSA/CISA Hardening Standards**.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: payment-service-prod
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: payment-system
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
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: processor
          image: internal-registry.enterprise.io/finance/payment-processor:v2.4.1
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          volumeMounts:
            - mountPath: /tmp
              name: tmp-volume
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

### 3.4. Kyverno Policy: Enforce Disallow Privilege Escalation & Require Read-Only Root Filesystem

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-hardened-container-security
  annotations:
    policies.kyverno.io/title: Enforce Hardened Container Security Context
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Enforces that allowPrivilegeEscalation is set to false and readOnlyRootFilesystem
      is set to true for all container instances in user workload namespaces.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-privilege-escalation-and-readonly-root
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - "payment-service-prod"
                - "order-service-prod"
      validate:
        message: "Containers must disable privilege escalation and mandate a read-only root filesystem."
        pattern:
          spec:
            containers:
              - securityContext:
                  allowPrivilegeEscalation: false
                  readOnlyRootFilesystem: true
```

---

## 4. Real CLI Commands & Terminal Output Verification

### 4.1. Audit Cluster Hardening using `kube-bench` (CIS Kubernetes Benchmark)

Execute `kube-bench` targeting a Master/Control Plane Node to verify compliance against the CIS Kubernetes Benchmark framework.

```bash
$ kube-bench run --targets master --check 1.2.1,1.2.2,1.2.5
```

**Expected Terminal Output:**

```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server Configuration
[FAIL] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set (Automated)
[PASS] 1.2.5 Ensure that the --kubelet-client-certificate and --kubelet-client-key arguments are set (Automated)

== Summary master ==
2 checks PASS
1 checks FAIL
0 checks WARN
0 checks INFO

== Remediations master ==
1.2.1 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the below parameter.
--anonymous-auth=false
```

### 4.2. Testing Pod Security Admission (PSA) Rejection on Non-Compliant Pod

Attempt to apply a non-compliant pod (running as root and missing `seccompProfile`) into the labeled namespace `payment-service-prod`.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-pod
  namespace: payment-service-prod
spec:
  containers:
  - name: nginx
    image: nginx:latest
EOF
```

**Expected Terminal Output:**

```text
Error from server (Forbidden): error when creating "STDIN": pods "non-compliant-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 4.3. Verifying Kyverno Policy Execution and Violations

Check the cluster policy enforcement status directly using `kubectl`.

```bash
$ kubectl get clusterpolicy enforce-hardened-container-security -o wide
```

**Expected Terminal Output:**

```text
NAME                                     ADMISSION   BACKGROUND   READY   AGE   MESSAGE
enforce-hardened-container-security      true        true         True    18h   Ready
```

Inspect Kyverno policy reports across the cluster:

```bash
$ kubectl get policyreports -n payment-service-prod
```

**Expected Terminal Output:**

```text
NAME                                PASS   FAIL   WARN   ERROR   AGE
cpol-enforce-hardened-container-security   3      0      0      0       4h22m
```

---

## 5. Verification, Troubleshooting & Diagnostic Guide

### 5.1. Diagnostic Flowchart: Workload Security Rejection

```
               [ Workload Deployment Submitted ]
                                |
                                v
               +---------------------------------+
               |  Is Namespace Exempt in PSA?   |
               +----------------+----------------+
                                |
                      +---------+---------+
                      |                   |
                     YES                  NO
                      |                   |
                      v                   v
            [ Bypass PSA Checks ]   [ Evaluate PSS Profile ]
                                          |
                                 +--------+--------+
                                 |                 |
                               PASS              FAIL
                                 |                 |
                                 v                 v
                    [ Kyverno/OPA Webhook ]  [ Blocked by kube-apiserver ]
                                 |            (403 Forbidden Error)
                       +---------+---------+
                       |                   |
                     PASS              VIOLATION
                       |                   |
                       v                   v
              [ Pod Scheduled ]     [ Rejected by Policy Engine ]
```

### 5.2. Common Production Issues and Root Cause Analysis

#### Issue 1: `CrashLoopBackOff` after setting `readOnlyRootFilesystem: true`
* **Root Cause**: The application framework attempts to write runtime state, logs, or temporary files (e.g., `/tmp`, `/var/cache`, `/var/log`) directly to the container root filesystem.
* **Diagnostic Command**:
  ```bash
  $ kubectl logs -n payment-service-prod deployment/payment-processor --previous
  ```
  *Output*: `Error: open /tmp/app.lock: read-only file system`
* **Resolution**: Mount an ephemeral volume (`emptyDir`) specifically at the write-required directories (e.g., `/tmp`).

#### Issue 2: Admission Webhook Timeout (`500 Internal Server Error` on Pod Creation)
* **Root Cause**: Custom Policy Engines (OPA Gatekeeper or Kyverno) webhooks are misconfigured with `failurePolicy: Fail` while the policy controller pods are crashing, unreachable, or resource-starved.
* **Diagnostic Commands**:
  ```bash
  $ kubectl get validatingservicepolicies,validatingwebhookconfigurations -A
  $ kubectl get pods -n kyverno
  $ kubectl top pod -n kyverno
  ```
* **Resolution**: Verify network communication between control plane and admission controllers. Ensure policy controller deployments have redundant replicas and adequate CPU/memory resource reservations.

---

## 6. References

* **CNCF TAG Security Whitepaper**: [https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper-v2.md](https://github.com/cncf/tag-security/blob/main/security-whitepaper/cloud-native-security-whitepaper-v2.md)
* **Kubernetes Pod Security Standards Documentation**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Kubernetes Pod Security Admission Documentation**: [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **NIST SP 800-190 (Application Container Security Guide)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **CIS Kubernetes Benchmarks**: [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)
* **NSA/CISA Kubernetes Hardening Guidance**: [https://www.nsa.gov/Cybersecurity/Cybersecurity-Technical-Reports/](https://www.nsa.gov/Cybersecurity/Cybersecurity-Technical-Reports/)
* **MITRE ATT&CK for Kubernetes**: [https://attack.mitre.org/matrices/enterprise/kubernetes/](https://attack.mitre.org/matrices/enterprise/kubernetes/)