# KCSA Study Guide — Domain 6.1: Compliance Frameworks

## 1. Production Architectural Motivation & Problem

In production enterprise environments—particularly within FinTech, Healthcare, E-Commerce, and Public Sector infrastructure—Kubernetes clusters represent a critical security boundary. Cloud-native architectures introduce key operational paradigms that break traditional, static compliance workflows:
* **Ephemeral Workload Dynamics:** Pods are created, mutated, and terminated within seconds or minutes. Point-in-time manual audits (e.g., annual penetration tests or static spreadsheet reviews) fail to capture runtime posture drift.
* **Shared Control Plane & Multi-Tenancy Risk:** Microservices owned by separate engineering teams share control plane APIs (`kube-apiserver`), compute nodes, container runtimes, and network overlay interfaces. A single misconfiguration in one namespace can compromise the underlying host or adjacent tenants.
* **Declarative API Complexity:** Kubernetes exposes over 50 API resources. Ensuring that every workload adheres to regulatory frameworks requires mapping abstract human-readable policies to deterministic API-level constraints.

### The Architectural Problem: Translating Frameworks to Kubernetes Primitives
Compliance frameworks such as **PCI-DSS 4.0**, **NIST SP 800-53 / 800-190**, **SOC 2 Type II**, and **CIS Kubernetes Benchmarks** mandate controls across multiple operational layers:

```
+-----------------------------------------------------------------------+
|                         COMPLIANCE FRAMEWORKS                         |
|             (PCI-DSS 4.0, NIST SP 800-53, SOC 2, CIS Benchmarks)      |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 KUBERNETES CONTROL PLANE ARCHITECTURE                 |
+-----------------------------------------------------------------------+
|  [ API Server ] ----> [ Admission Controllers ] ----> [ Audit Log ]   |
|         |                      |                                      |
|         v                      v                                      |
|   (RBAC & OIDC)    (ValidatingAdmissionPolicy)                        |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 WORKLOAD & INFRASTRUCTURE ENFORCEMENT                 |
+-----------------------------------------------------------------------+
|  [ NetworkPolicies ]       [ Pod Security Standards ]   [ Node Security ]  |
|  (Microsegmentation)       (Non-root, ReadOnly FS)      (etcd, Kubelet)    |
+-----------------------------------------------------------------------+
```

Without continuous automated enforcement, systems experience **Compliance Drift**: developers push non-compliant manifests (e.g., privileged containers, wildcard RBAC permissions, unencrypted ingress routes) that pass initial peer review but violate baseline security standards once deployed to production.

---

## 2. Technical Comparisons & Trade-off Tables

The following matrix compares the four primary compliance standards encountered in cloud-native Kubernetes environments:

| Feature / Metric | CIS Kubernetes Benchmark | NIST SP 800-190 / SP 800-53 | PCI-DSS v4.0 (Req 1, 2, 7, 10) | SOC 2 Type II |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Scope** | Control plane components, Kubelet, host configuration, etcd, RBAC. | Application container security lifecycle, risk management, access control. | Cardholder Data Environment (CDE) microsegmentation, audit trail, crypto. | Operational control efficacy over an observation period (Trust Services). |
| **Kubernetes Primitives Used** | Host file permissions (`/etc/kubernetes`), Kubelet flags, API Server flags. | `PodSecurityAdmission`, `securityContext`, `seccompProfile`, `capabilities`. | `NetworkPolicy`, `Secret` encryption at rest, API Audit Logs, RBAC `RoleBinding`. | API Audit Logging, GitOps state immutability, automated policy enforcement. |
| **Enforcement Layer** | Static host scanning (`kube-bench`), node configuration management. | Admission control (`ValidatingAdmissionPolicy`, OPA/Kyverno), Container Runtime. | CNI network filter (eBPF / iptables), API admission control, Service Mesh. | Log pipelines (Fluentbit/Loki/Splunk), CI/CD pipelines, SIEM integrations. |
| **Audit Frequency** | Continuous / Scheduled daily cron scans. | Inline per API request (Real-time admission block). | Continuous runtime monitoring & quarterly penetration / posture checks. | Continuous historical evidence collection (typically 3–12 months window). |
| **Trade-offs & Operational Impact** | Low runtime cost; requires host access to execute configuration verification scripts. | Prevents non-compliant workloads from spawning; can block deployments if misconfigured. | High network complexity; improperly structured rules cause service outages. | Requires large log storage volume; log data pipeline maintenance overhead. |

---

## 3. Complete Syntactically Valid Manifests & Infrastructure

### Manifest 1: Production-Grade NetworkPolicy for PCI-DSS v4.0 (Requirements 1.2 & 1.3 Microsegmentation)
This manifest enforces strict default-deny isolation for a Payment Processing service in a Cardholder Data Environment (CDE). It explicitly permits ingress only from an authorized API Gateway on HTTPS port `8443` and limits egress exclusively to the transaction database on TCP port `5432` plus cluster internal DNS.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: pci-dss-cde-microsegmentation
  namespace: payment-cde
  labels:
    app.kubernetes.io/name: payment-processor
    compliance.framework/pci-dss: "v4.0"
    compliance.requirement: "1.2-1.3"
spec:
  podSelector:
    matchLabels:
      app: payment-processor
      tier: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              environment: production
              zone: dmz
          podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - protocol: TCP
          port: 8443
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              environment: production
              zone: secure-data
          podSelector:
            matchLabels:
              app: transaction-db
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

---

### Manifest 2: Native Kubernetes ValidatingAdmissionPolicy for NIST SP 800-190 & CIS 5.2.6
Enforces container runtime hardening rules dynamically at the API server layer without external webhooks. Blocks Pod creation if containers run as root, have a writable root filesystem, or enable privilege escalation.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: nist-sp800-190-container-hardening
  labels:
    compliance.framework/nist-sp800-190: "4.1"
    compliance.framework/cis-benchmark: "5.2.6"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"
      message: "NIST SP 800-190 Violation: All containers must explicitly set securityContext.runAsNonRoot to true."
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.readOnlyRootFilesystem) && c.securityContext.readOnlyRootFilesystem == true)"
      message: "NIST SP 800-190 Violation: All containers must set securityContext.readOnlyRootFilesystem to true."
    - expression: "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)"
      message: "CIS Benchmark 5.2.6 Violation: Container privilege escalation must be explicitly disabled (allowPrivilegeEscalation: false)."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: nist-sp800-190-container-hardening-binding
spec:
  policyName: nist-sp800-190-container-hardening
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: compliance-enforcement
          operator: In
          values: ["strict", "enabled"]
```

---

### Manifest 3: Kube-Bench Automated CIS Kubernetes Benchmark CronJob
Deploys a scheduled job running `kube-bench` to perform automated node and control plane compliance audits, reporting findings in JSON format.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-cis-audit
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    compliance.framework/cis-k8s: "v1.8"
spec:
  schedule: "0 2 * * *"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: kube-bench
        spec:
          hostPID: true
          restartPolicy: OnFailure
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node-role.kubernetes.io/master
              operator: Exists
              effect: NoSchedule
          containers:
            - name: kube-bench
              image: docker.io/aquasec/kube-bench:v0.7.3
              command: ["kube-bench", "run", "--targets", "master,node", "--json"]
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
                - name: usr-bin
                  mountPath: /usr/local/mount-from-host/bin
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
            - name: usr-bin
              hostPath:
                path: /usr/bin
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### Command 1: Validating Pod Security Admission (PSA) Enforcement
Query the operational configuration of namespaces to verify compliance labeling under Kubernetes Pod Security Admission standards.

```bash
$ kubectl get namespaces --show-labels -l pod-security.kubernetes.io/enforce
```
```text
NAME           STATUS   AGE   LABELS
payment-cde    Active   12d   app.kubernetes.io/part-of=core-banking,compliance-enforcement=strict,environment=production,pod-security.kubernetes.io/enforce-version=latest,pod-security.kubernetes.io/enforce=restricted,zone=secure-data
secure-system  Active   45d   compliance-enforcement=enabled,pod-security.kubernetes.io/enforce-version=v1.30,pod-security.kubernetes.io/enforce=restricted
```

---

### Command 2: Testing ValidatingAdmissionPolicy Enforcement against Non-Compliant Pods
Attempt to apply a non-compliant pod manifest to verify real-time admission policy rejection.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: payment-cde
spec:
  containers:
  - name: nginx
    image: nginx:1.25.3
EOF
```
```text
Error from server (Forbidden): error when creating "STDIN": pods "non-compliant-workload" is forbidden: validating admission policy "nist-sp800-190-container-hardening" with binding "nist-sp800-190-container-hardening-binding" denied the request:
- NIST SP 800-190 Violation: All containers must explicitly set securityContext.runAsNonRoot to true.
- NIST SP 800-190 Violation: All containers must set securityContext.readOnlyRootFilesystem to true.
- CIS Benchmark 5.2.6 Violation: Container privilege escalation must be explicitly disabled (allowPrivilegeEscalation: false).
```

---

### Command 3: Running `kube-bench` Directly on a Master/Control Plane Node
Execute host-level CIS Benchmark audits to evaluate file permissions and component flags.

```bash
$ kube-bench run --targets master --check 1.1.1,1.1.2,1.2.1
```
```text
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive (Automated)
[PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root (Automated)
[INFO] 1.2 API Server
[FAIL] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)

== Summary master ==
2 checks PASS
1 checks FAIL
0 checks WARN
0 checks INFO

== Remediations master ==
1.2.1 Edit the API server pod specification file /etc/kubernetes/manifests/kube-apiserver.yaml
on the control plane node and set the --anonymous-auth parameter to false.
```

---

### Command 4: Inspecting API Server Audit Logs for SOC 2 / PCI-DSS Audit Trail Verification
Extract access audit records filtered for sensitive resource operations (Secret accesses and RBAC modifications).

```bash
$ tail -n 100 /var/log/kubernetes/audit/audit.log | jq 'select(.objectRef.resource=="secrets" and .verb=="get") | {time: .stageTimestamp, user: .user.username, namespace: .objectRef.namespace, secret: .objectRef.name, decision: .annotations["authorization.k8s.io/decision"]}'
```
```json
{
  "time": "2026-08-07T20:15:32.410912Z",
  "user": "system:serviceaccount:payment-cde:payment-processor-sa",
  "namespace": "payment-cde",
  "secret": "db-credentials",
  "decision": "allow"
}
{
  "time": "2026-08-07T20:18:04.891001Z",
  "user": "developer-user@company.internal",
  "namespace": "payment-cde",
  "secret": "stripe-api-key",
  "decision": "deny"
}
```

---

## 5. Verification & Diagnostic / Troubleshooting Guide

```
                      WORKLOAD DEPLOYMENT FAILURE
                                   |
                                   v
             +-------------------------------------------+
             |   Check `kubectl describe pod` Output     |
             +-------------------------------------------+
                                   |
        +--------------------------+--------------------------+
        |                                                     |
        v                                                     v
[ Admission Policy Blocked ]                      [ Network Policy Drop ]
        |                                                     |
        v                                                     v
Check Policy Specs & Labels                       Check CNI Flow Logs / Traces
  - `kubectl get policybindings`                    - `cilium monitor --type drop`
  - Inspect `validations[].expression`             - Inspect ingress/egress labels
  - Validate Namespace matchLabels                  - Verify DNS resolution egress (53)
```

### Problem 1: Admission Policy Blocking Legitimate Workloads (`ValidatingAdmissionPolicy` Failure)
* **Symptom:** Workload deployments fail with `Error from server (Forbidden)` referencing a compliance policy rule.
* **Root Cause Analysis:**
  1. Inspect active policies matching the namespace:
     ```bash
     $ kubectl get validatingadmissionpolicybindings -o wide
     ```
  2. Check namespace labels to ensure the workload wasn't accidentally matched by an overly broad selector:
     ```bash
     $ kubectl get ns <namespace-name> --show-labels
     ```
  3. Validate policy expression against the target pod manifest:
     Ensure fields like `securityContext` are declared at the container level if required by the CEL expression:
     ```yaml
     securityContext:
       runAsNonRoot: true
       readOnlyRootFilesystem: true
       allowPrivilegeEscalation: false
       capabilities:
         drop: ["ALL"]
     ```

### Problem 2: NetworkPolicy Blocking Internal Service Communication
* **Symptom:** Pods stuck in `CrashLoopBackOff` or returning HTTP 504 Gateway Timeouts when connecting to internal services.
* **Root Cause Analysis:**
  1. Verify active network policies applied to the pod:
     ```bash
     $ kubectl get networkpolicies -n <namespace> -o wide
     ```
  2. Confirm label alignment between the target Pod `spec.template.metadata.labels` and the NetworkPolicy `podSelector` / `ingress.from.podSelector`.
  3. Check DNS Egress: A common mistake when implementing `policyTypes: [Egress]` default-deny is omitting an explicit egress rule for CoreDNS on UDP port 53. If DNS fails, connections to service endpoints fail prior to routing.

### Problem 3: `kube-bench` Host Scans Failing on Permission Rules (CIS 1.1.1 - 1.1.12)
* **Symptom:** Scans report `FAIL` for `/etc/kubernetes/manifests` or `etcd` data directories.
* **Remediation Steps:**
  1. SSH to affected node and verify exact permissions:
     ```bash
     $ stat -c "%a %U %G %n" /etc/kubernetes/manifests/kube-apiserver.yaml
     ```
  2. Correct mode bits and ownership to match CIS baseline standards:
     ```bash
     $ sudo chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
     $ sudo chown root:root /etc/kubernetes/manifests/kube-apiserver.yaml
     ```

---

## 6. References

* **CNCF KCSA Official Curriculum GitHub Repository:**
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **CIS Kubernetes Benchmark:**
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)
* **NIST SP 800-190 Application Container Security Guide:**
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **PCI Security Standards Council (PCI-DSS v4.0):**
  [https://www.pcisecuritystandards.org/document_library/](https://www.pcisecuritystandards.org/document_library/)
* **Kubernetes Official Documentation - Network Policies:**
  [https://kubernetes.io/docs/concepts/services-networking/network-policies/](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
* **Kubernetes Official Documentation - Validating Admission Policy:**
  [https://kubernetes.io/docs/concepts/security/validating-admission-policy/](https://kubernetes.io/docs/concepts/security/validating-admission-policy/)
* **Aqua Security kube-bench Documentation:**
  [https://github.com/aquasecurity/kube-bench](https://github.com/aquasecurity/kube-bench)