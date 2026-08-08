# Module 6.1: Compliance Frameworks in Kubernetes

## 1. Technical Deep Dive & Production Architecture

### 1.1 Mechanics of Cloud-Native Compliance Frameworks
Compliance in cloud-native infrastructure is the verifiable process of aligning containerized workloads, control plane configurations, runtime environments, and operational workflows with standardized security frameworks. Unlike traditional monolithic environments, Kubernetes compliance cannot rely on static point-in-time audits. It requires continuous compliance automation across three distinct layers:

1. **Static Control Plane & Node Configuration Compliance**: Verifying API server, etcd, controller manager, scheduler, and kubelet flags and file permissions against hardening benchmarks (e.g., CIS Kubernetes Benchmark).
2. **Declarative Workload Admission Compliance**: Enforcing operational guardrails on workloads prior to persistence in etcd using Policy-as-Code engines (e.g., Kyverno, OPA Gatekeeper) aligned with guidance such as NSA/CISA Hardening Guidelines and NIST SP 800-190.
3. **Forensic Audit & Event Streaming Compliance**: Capturing, retaining, and analyzing API server request logs to establish non-repudiable audit trails required by regulatory standards (e.g., PCI-DSS v4.0 Requirement 10, SOC 2 Type II Trust Services Criteria).

---

### 1.2 Mapping Compliance Framework Controls to Kubernetes Primitives

| Regulatory / Industry Framework | Control ID & Description | Kubernetes Technical Primitive | Enforcement / Audit Engine |
| :--- | :--- | :--- | :--- |
| **CIS Kubernetes Benchmark** | **Control 1.2.19**: Ensure `--anonymous-auth=false` | `kube-apiserver` CLI Flag | Static manifest auditing (`kube-bench`) |
| **CIS Kubernetes Benchmark** | **Control 4.2.1**: Ensure `--anonymous-auth=false` on Kubelet | `kubelet-config.yaml` / Kubelet Service | Static node configuration auditing (`kube-bench`) |
| **NSA/CISA Guidance** | **Section 1**: Pod Security (Non-root, read-only root filesystem, drop caps) | Security Context (`securityContext`) | Admission Control (`Kyverno` / `OPA Gatekeeper` / `Pod Security Admission`) |
| **NIST SP 800-190** | **Section 3.1**: Container Image Flaws & Unapproved Registries | Image Pull Secrets & Image Pattern Match | Admission Control (`Kyverno` Image Verification / ImagePolicyWebhook) |
| **PCI-DSS v4.0** | **Requirement 10.2.1**: Audit all user access to cardholder data / API objects | API Server Audit Policy (`AuditPolicy`) | `kube-apiserver` Audit Logging Engine to SIEM |
| **SOC 2 Type II** | **CC6.1**: Prevent unauthorized execution & access | RBAC (`ClusterRole`, `RoleBinding`), Pod Security | Kubernetes RBAC Engine & Admission Controllers |

---

### 1.3 Continuous Compliance Architecture

```
  +---------------------------------------------------------------------------------------------------+
  |                                   Continuous Compliance Architecture                              |
  +---------------------------------------------------------------------------------------------------+
  
   [ Developer / CI/CD ]
            |
            v  (kubectl apply / GitOps Push)
   +-----------------------+
   |   kube-apiserver      |
   +-----------+-----------+
               |
               +---> [ 1. Audit Policy Engine ] ---------> Write JSON Logs ---> [ SIEM / Log Collector ]
               |                                                                (PCI-DSS 10.2 / SOC 2)
               |
               +---> [ 2. Admission Controllers ]
                           |
                           +---> [ Kyverno / OPA Gatekeeper ] ---> Validate Security Context
                                                                    (NSA/CISA & NIST SP 800-190)
                                                                    Reject Non-Compliant Pods
  [ Node Infrastructure ]
               |
   +-----------+-----------+
   |  kube-bench CronJob   | ---> Audit API / Kubelet / etcd Flags against CIS Benchmarks
   +-----------------------+
```

---

## 2. Guided Production Exercises

### Exercise 1: Automated CIS Benchmark Compliance Scanning and Node Hardening

In this exercise, you will deploy an automated `kube-bench` CronJob to continuously scan your Kubernetes node configurations against the CIS Kubernetes Benchmark, analyze non-compliant findings, and remediate control plane and kubelet flag violations.

#### Step 1.1: Deploy the CIS Benchmark Scanning CronJob
Create a syntactically valid `CronJob` manifest to run `kube-bench` on the master control-plane node using host path mounts for configuration inspection.

Execute the following command to deploy the scanner:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kube-bench-control-plane
  namespace: kube-system
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/part-of: compliance-suite
spec:
  schedule: "0 0 * * *"
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: kube-bench
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
          restartPolicy: OnFailure
          containers:
            - name: kube-bench
              image: aquasec/kube-bench:v0.7.3
              command: ["kube-bench", "run", "--targets", "master"]
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
EOF
```

Expected Output:
```text
cronjob.batch/kube-bench-control-plane created
```

---

#### Step 1.2: Manually Trigger Job and Analyze CIS Benchmark Output
Trigger a manual execution of the job and inspect the generated pod logs for CIS failures.

```bash
kubectl create job --from=cronjob/kube-bench-control-plane kube-bench-manual-01 -n kube-system
kubectl wait --for=condition=complete job/kube-bench-manual-01 -n kube-system --timeout=60s
POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-bench --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs $POD_NAME -n kube-system | grep -E "\[FAIL\]|\[WARN\]"
```

Expected Output:
```text
[FAIL] 1.2.19 Ensure that the --anonymous-auth argument is set to false (FAIL)
[FAIL] 1.2.22 Ensure that the --mode argument is set to Node,RBAC (FAIL)
[WARN] 1.1.12 Ensure that the etcd data directory permissions are set to 700 or more restrictive (WARNING)
```

---

#### Step 1.3: Remediate `kube-apiserver` Anonymous Authentication Flag
Remediate CIS Control 1.2.19 by modifying the static pod manifest for `kube-apiserver` on the control plane node to disable anonymous authentication.

Inspect `/etc/kubernetes/manifests/kube-apiserver.yaml` and ensure `--anonymous-auth=false` is explicitly set under `.spec.containers[0].command`.

```bash
# Execute on the control-plane host:
sudo sed -i '/--anonymous-auth/d' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo sed -i '/- kube-apiserver/a \    - --anonymous-auth=false' /etc/kubernetes/manifests/kube-apiserver.yaml
```

Verify `kube-apiserver` pod restarts automatically:

```bash
kubectl get pods -n kube-system -l component=kube-apiserver -w
```

Expected Output:
```text
NAME                                           READY   STATUS    RESTARTS   AGE
kube-apiserver-control-plane                   1/1     Running   0          12s
```

---

#### Step 1.4: Re-evaluate Benchmark Post-Remediation
Re-run the `kube-bench` manual job to confirm remediation of CIS Control 1.2.19.

```bash
kubectl create job --from=cronjob/kube-bench-control-plane kube-bench-manual-02 -n kube-system
kubectl wait --for=condition=complete job/kube-bench-manual-02 -n kube-system --timeout=60s
POD_NAME_02=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-bench --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs $POD_NAME_02 -n kube-system | grep "1.2.19"
```

Expected Output:
```text
[PASS] 1.2.19 Ensure that the --anonymous-auth argument is set to false
```

---

#### Verification Questions — Exercise 1
1. **Question 1.1**: Why does setting `--anonymous-auth=false` on `kube-apiserver` satisfy CIS Control 1.2.19, and what potential breaking change does this introduce for unauthenticated readiness probes or metrics endpoints?
2. **Question 1.2**: In a managed Kubernetes environment (e.g., EKS, GKE, AKS), why does running `kube-bench` against control plane components fail or report missing files, and where should compliance scanning be focused instead?

---

### Exercise 2: Declarative Compliance Policy Enforcement via Policy-as-Code (NSA/CISA & NIST SP 800-190 Mapping)

In this exercise, you will deploy a Kyverno `ClusterPolicy` to declaratively enforce NSA/CISA Pod Security Hardening guidelines and NIST SP 800-190 container runtime security controls across your cluster.

#### Step 2.1: Deploy Kyverno Policy Engine (if not present) and Apply Compliance Policy
Deploy a production-grade `ClusterPolicy` that blocks workloads failing NSA/CISA requirements:
- Disallow root user execution (`runAsNonRoot: true`).
- Enforce read-only root file systems (`readOnlyRootFilesystem: true`).
- Drop all capabilities (`drop: ["ALL"]`).
- Disallow privilege escalation (`allowPrivilegeEscalation: false`).
- Enforce NIST SP 800-190 approved container registry domain matching (`company-registry.io/*`).

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-nsa-cisa-nist-compliance
  annotations:
    policies.kyverno.io/title: NSA-CISA Pod Hardening & NIST SP 800-190 Registry Guard
    policies.kyverno.io/category: Security, Compliance
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Enforces NSA/CISA pod hardening requirements and NIST SP 800-190 unapproved registry protection.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-nsa-cisa-security-context
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "NSA/CISA Compliance Failure: Security Context must enforce runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation=false, and drop ALL capabilities."
        pattern:
          spec:
            containers:
              - securityContext:
                  runAsNonRoot: true
                  readOnlyRootFilesystem: true
                  allowPrivilegeEscalation: false
                  capabilities:
                    drop:
                      - ALL
    - name: validate-nist-approved-registry
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "NIST SP 800-190 Compliance Failure: Image must originate from approved registry 'company-registry.io'."
        pattern:
          spec:
            containers:
              - image: "company-registry.io/*"
EOF
```

Expected Output:
```text
clusterpolicy.kyverno.io/enforce-nsa-cisa-nist-compliance created
```

---

#### Step 2.2: Test Admission Control Rejection with a Non-Compliant Manifest
Attempt to deploy a non-compliant workload violating NSA/CISA security context and NIST SP 800-190 image registry policies.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: non-compliant-workload
  namespace: default
spec:
  containers:
    - name: vulnerable-app
      image: nginx:latest
      securityContext:
        runAsNonRoot: false
        allowPrivilegeEscalation: true
EOF
```

Expected Output:
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/non-compliant-workload was blocked due to the following policies:

enforce-nsa-cisa-nist-compliance:
  validate-nsa-cisa-security-context: 'NSA/CISA Compliance Failure: Security Context must enforce runAsNonRoot, readOnlyRootFilesystem, allowPrivilegeEscalation=false, and drop ALL capabilities.'
  validate-nist-approved-registry: 'NIST SP 800-190 Compliance Failure: Image must originate from approved registry ''company-registry.io''.'
```

---

#### Step 2.3: Deploy a Fully Compliant Workload
Deploy a workload that completely satisfies the NSA/CISA security context attributes and NIST SP 800-190 container registry rules.

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fully-compliant-workload
  namespace: default
spec:
  containers:
    - name: hardened-app
      image: company-registry.io/apps/secure-api:v1.0.0
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
  volumes:
    - name: tmp-volume
      emptyDir: {}
EOF
```

Expected Output:
```text
pod/fully-compliant-workload created
```

---

#### Step 2.4: Inspect Kyverno Policy Reports CLI Output
Verify that Kyverno generates structured compliance audit reports for existing resources.

```bash
kubectl get policyreport -A
```

Expected Output:
```text
NAMESPACE   NAME                   PASS   FAIL   WARN   ERROR   AGE
default     pol-nsa-cisa-report    1      0      0      0       45s
```

---

#### Verification Questions — Exercise 2
1. **Question 2.1**: Which specific component of NIST SP 800-190 (Section 3.1) is directly addressed by enforcing image registry restrictions (`company-registry.io/*`), and why is image digest tagging (`@sha256:...`) preferred over tag naming (`:v1.0.0`) in high-compliance environments?
2. **Question 2.2**: If a application requires writing temporary lock files at runtime, how does mounting an `emptyDir` volume to `/tmp` preserve compliance with the NSA/CISA `readOnlyRootFilesystem: true` mandate?

---

### Exercise 3: Kubernetes API Server Audit Logging Architecture for PCI-DSS v4.0 & SOC 2 Auditing

In this exercise, you will create a granular `AuditPolicy` manifest aligned with PCI-DSS v4.0 Requirement 10 (Logging & Auditing), configure `kube-apiserver` flags, and parse API server audit logs for forensic evidence generation.

#### Step 3.1: Construct the PCI-DSS & SOC 2 Compliant `AuditPolicy` Manifest
Create a production `audit-policy.yaml` enforcing strict log auditing rules:
- **RequestResponse Level**: For RBAC modification (`ClusterRole`, `RoleBinding`), Secret access, and `exec`/`attach`/`port-forward` pod subresources (PCI-DSS 10.2.2 & 10.2.7).
- **Metadata Level**: For workload creations/deletions across non-system namespaces.
- **None Level**: Discard noisy, high-volume requests (e.g., `kube-proxy`, endpoints, component leases).

```bash
cat <<'EOF' | sudo tee /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "ResponseStarted"
rules:
  # 1. Ignore high-volume read-only noise
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "configmaps"]

  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get"]
    resources:
      - group: ""
        resources: ["nodes", "nodes/status"]

  - level: None
    namespaces: ["kube-system"]
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]

  # 2. Critical PCI-DSS / SOC 2 Compliance Events: RequestResponse Level
  # Audit Secret reads and modifications
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]

  # Audit RBAC permissions changes (PCI-DSS 10.2.2)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]

  # Audit Interactive Pod Access (kubectl exec/attach) (PCI-DSS 10.2.7)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 3. Metadata Level for workload operations
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods", "services", "persistentvolumeclaims"]
      - group: "apps"
        resources: ["deployments", "statefulsets", "daemonsets"]

  # 4. Default catch-all for remaining authenticated requests
  - level: Metadata
    omitStages:
      - "ResponseStarted"
EOF
```

Expected Output:
```text
apiVersion: audit.k8s.io/v1
kind: Policy
...
```

---

#### Step 3.2: Configure `kube-apiserver` for Audit Log Streaming
Configure `/etc/kubernetes/manifests/kube-apiserver.yaml` to enable audit logging by attaching the audit flags and mounting the policy file and log directory.

Add the following flags to `kube-apiserver`:
```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

And mount host paths for `/etc/kubernetes/audit-policy.yaml` and `/var/log/kubernetes/audit`.

```bash
# Ensure log directory exists
sudo mkdir -p /var/log/kubernetes/audit
```

Verify audit log file generation:

```bash
sudo tail -n 5 /var/log/kubernetes/audit/audit.log
```

Expected Output (Raw JSON Log):
```json
{"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"RequestResponse","auditID":"c8b6b2e1-45a8-4e40-9a3d-612b7f8911ab","stage":"ResponseComplete","requestURI":"/api/v1/namespaces/default/secrets","verb":"get","user":{"username":"kubernetes-admin","groups":["system:masters","system:authenticated"]},"sourceIPs":["192.168.1.50"],"responseStatus":{"metadata":{},"code":200},"objectRef":{"resource":"secrets","name":"db-credential","namespace":"default"}}
```

---

#### Step 3.3: Parse and Extract Forensic Compliance Evidence using `jq`
Audit events must be parsed for compliance verification. Execute `jq` queries to extract evidence of Secret reads (PCI-DSS 10.2.1) and `kubectl exec` interactive access events (PCI-DSS 10.2.7).

Query 1: Extract all Secret read operations (`verb=get` or `list`):

```bash
sudo cat /var/log/kubernetes/audit/audit.log | jq -c 'select(.objectRef.resource=="secrets" and (.verb=="get" or .verb=="list")) | {timestamp: .requestReceivedTimestamp, user: .user.username, verb: .verb, secret: .objectRef.name, namespace: .objectRef.namespace, clientIP: .sourceIPs[0]}'
```

Expected Output:
```json
{"timestamp":"2026-08-07T20:45:12Z","user":"kubernetes-admin","verb":"get","secret":"db-credential","namespace":"default","clientIP":"192.168.1.50"}
```

Query 2: Detect interactive container shell access (`pods/exec`):

```bash
sudo cat /var/log/kubernetes/audit/audit.log | jq -c 'select(.objectRef.subresource=="exec") | {timestamp: .requestReceivedTimestamp, user: .user.username, pod: .objectRef.name, namespace: .objectRef.namespace, container: .objectRef.subresource}'
```

Expected Output:
```json
{"timestamp":"2026-08-07T20:48:30Z","user":"admin-user@company.com","pod":"fully-compliant-workload","namespace":"default","container":"exec"}
```

---

#### Verification Questions — Exercise 3
1. **Question 3.1**: Why is audit logging configured at the `RequestResponse` level for `Secret` resources and `pods/exec` subresources, while `Metadata` level is sufficient for `Deployments` under PCI-DSS v4.0 Requirement 10?
2. **Question 3.2**: In an event-driven architecture, what risk is introduced if audit logs are stored locally on the control-plane host filesystem (`/var/log/kubernetes/audit/audit.log`), and how is this mitigated for SOC 2 Type II compliance?

---

## 3. Official References & Citations

- **CNCF KCSA Curriculum**: [KCSA Exam Curriculum GitHub](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Audit Logging Reference**: [Kubernetes Auditing Tasks](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- **NSA/CISA Kubernetes Hardening Guidance**: [NSA/CISA Kubernetes Hardening Technical Report (PDF)](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2.PDF)
- **NIST SP 800-190 Application Container Security Guide**: [NIST Special Publication 800-190](https://csrc.nist.gov/pubs/sp/800/190/final)
- **CIS Kubernetes Benchmarks**: [Center for Internet Security Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- **Kyverno Policy Library**: [Kyverno Production Policies](https://kyverno.io/policies/)

---

## 4. Verification Answers & Technical Rationale

<details>
<summary><strong>Click to view Verification Answers and Deep Rationale</strong></summary>

### Answers for Exercise 1

#### Answer 1.1
Setting `--anonymous-auth=false` instructs the `kube-apiserver` to reject unauthenticated requests with an `HTTP 401 Unauthorized` status code rather than evaluating them under the `system:unauthenticated` user and `system:unauthenticated` group.

- **CIS Control Rationale**: Allowing anonymous access leaves any exposed API server port open to unauthenticated discovery, reconnaissance, and potential exploitation if RBAC permissions accidentally bind sensitive roles to `system:unauthenticated` or `system:authenticated`.
- **Potential Breaking Change**: Disabling anonymous authentication breaks `kube-apiserver` `/healthz`, `/livez`, and `/readyz` probes if external load balancers or monitoring agents query these paths without bearer tokens or TLS client certificates. In modern Kubernetes (v1.20+), health check endpoints remain accessible to unauthenticated callers under specific built-in exempt paths, but custom HTTP probes querying other API endpoints without credentials fail.

#### Answer 1.2
In managed Kubernetes offerings (EKS, GKE, AKS), cloud service providers manage the control plane nodes (API server, etcd, controller-manager, scheduler) as a black box service under the Shared Responsibility Model.

- **Why `kube-bench` Control Plane Scans Fail**: `kube-bench` attempts to read static manifest files located in host filesystem paths like `/etc/kubernetes/manifests/` or `/var/lib/etcd`. On managed control plane nodes, worker nodes do not have SSH or filesystem access to the underlying control plane infrastructure.
- **Where Scanning Shifts**: Compliance auditing in managed Kubernetes shifts from static control plane flag checks to:
  1. Managed Provider Configuration APIs (AWS Security Hub, GCP Security Command Center, Azure Defender).
  2. Worker Node Configuration Scans (executing `kube-bench --targets node`).
  3. Workload Policy-as-Code Auditing (Kyverno/OPA Gatekeeper) and Kubernetes API Audit Log analysis.

---

### Answers for Exercise 2

#### Answer 2.1
- **NIST SP 800-190 Section 3.1 Mapping**: Section 3.1 ("Image Flaws") highlights the risk of running untrusted, unvetted, or compromised container images originating from external public registries (e.g., Docker Hub public repositories) that may contain embedded malware or unpatched CVEs. Restricting registry hostnames via policy enforces image source authenticity.
- **Image Digest vs. Mutable Tags**: Image tags like `:v1.0.0` or `:latest` are mutable pointer references. A malicious actor with registry write access can overwrite `:v1.0.0` with a malicious binary without altering the deployment manifest. An image digest (`@sha256:7f83...`) represents a cryptographic hash of the image manifest and layer content. Enforcing digest pin references guarantees immutable image integrity and prevents Image Mutation/Tampering attacks.

#### Answer 2.2
When `readOnlyRootFilesystem: true` is set in a container's `securityContext`, the container runtime mounts the root directory (`/`) as a read-only filesystem via overlayfs. Any attempt by the containerized process to write files (such as `/tmp/app.lock`, session caches, or pid files) results in an `HTTP 500` or OS-level `EROFS (Read-only file system)` error.

- **Preserving Compliance via `emptyDir`**: Mounting an `emptyDir` volume specifically to `/tmp` overrides the root read-only mount at that exact path. The `emptyDir` resides in temporary node storage (or RAM if `medium: Memory` is set). The root filesystem remains strictly read-only, preventing attackers from modifying system binaries or injecting malicious scripts into container filesystems while allowing the application write access to volatile temporary directories.

---

### Answers for Exercise 3

#### Answer 3.1
- **`RequestResponse` for Secrets and Exec**: PCI-DSS v4.0 Requirement 10.2.1 and 10.2.7 mandates auditing all access to sensitive data and interactive administrative access. Setting `level: RequestResponse` records:
  1. The complete request context (who requested the secret or exec session, client IP, timestamp).
  2. The status and body returned by the API server (allowing security operations teams to verify whether an unauthorized Secret fetch succeeded or failed, and what subresource parameters were passed).
- **`Metadata` for Deployments**: Workload objects (`Deployments`, `StatefulSets`) contain non-sensitive structural configuration metadata. Recording events at the `Metadata` level captures the initiating user, timestamp, target resource, and HTTP status code without generating massive log amplification caused by serializing full resource YAML specs in audit logs.

#### Answer 3.2
- **Architectural Risk**: Storing audit logs exclusively on local control plane node disks introduces three critical risks:
  1. **Log Tampering / Non-Repudiation Failure**: An attacker who compromises a control plane host can modify or delete `/var/log/kubernetes/audit/audit.log`, destroying forensic traces of unauthorized access.
  2. **Storage Exhaustion**: Audit logs consume high disk I/O and storage. Local disk saturation causes `kube-apiserver` failure or node disk pressure.
  3. **SOC 2 Type II Non-Compliance**: SOC 2 CC6.8 requires immutable log collection, centralized retention, and continuous monitoring.
- **Mitigation Architecture**: Configure `kube-apiserver` with audit log rotation flags (`--audit-log-maxbackup`, `--audit-log-maxage`) combined with a daemon log shipping agent (e.g., Fluentbit, Vector, Logstash) or configure API server `--audit-webhook-config-file` to stream audit events synchronously over TLS to an external, write-once-read-many (WORM) compliant SIEM or object storage target (e.g., AWS CloudWatch, Datadog, Elastic, Splunk).

</details>