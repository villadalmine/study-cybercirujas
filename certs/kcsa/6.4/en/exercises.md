# KCSA Study Guide: Topic 6.4 – Automation and Tooling

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 6:** Cloud Native Security Ecosystem  
**Subtopic 6.4:** Automation and Tooling  
**Exam Weight:** 2.5%  

---

## 1. Architectural Deep-Dive & Mechanical Foundations

Security automation in cloud-native environments shifts security controls left into developer workflows (CI/CD pipelines) and automates continuous compliance and runtime protection within production Kubernetes clusters. The primary objective is to replace manual security gatekeeping with automated, deterministic, and scalable policy enforcement engines.

```
                   +-------------------------------------------------------------+
                   |                 SHIFT-LEFT SECURITY (CI/CD)                |
                   +-------------------------------------------------------------+
                   |  1. IaC & Manifest Linting (KubeLinter / Checkov / OPA)    |
                   |  2. Container Image & Dependency Scan (Trivy / Grype)       |
                   |  3. Supply Chain Integrity & Signing (Cosign / Syft SBOM)   |
                   +-------------------------------------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |               IN-CLUSTER ADMISSION AUTOMATION               |
                   +-------------------------------------------------------------+
                   |  4. Validating/Mutating Admission Webhooks (Kyverno / OPA)  |
                   |     - Blocks non-compliant resources before etcd write      |
                   +-------------------------------------------------------------+
                                                  |
                                                  v
                   +-------------------------------------------------------------+
                   |            CONTINUOUS IN-CLUSTER COMPLIANCE (CD)            |
                   +-------------------------------------------------------------+
                   |  5. Security Operators (Trivy Operator / Kubescape)         |
                   |     - Generates VulnerabilityReport / ConfigAuditReport CRDs|
                   +-------------------------------------------------------------+
```

### Key Architectural Concepts

1. **Shift-Left vs. In-Cluster Enforcement:**
   - **Shift-Left (CI/CD):** Catches vulnerabilities, misconfigurations, and supply chain tampering prior to deployment. Fast feedback loop for developers, zero runtime overhead.
   - **In-Cluster Admission (Kubernetes API Webhooks):** Serves as an immutable safety net. Ensures that even if CI/CD is bypassed or compromised, non-compliant manifests cannot be committed to `etcd`.
   - **Continuous Operator Auditing:** Detects newly disclosed CVEs (zero-days) against already-running workloads and flags configuration drift.

2. **Admission Webhook Mechanics:**
   - The API Server invokes registered `MutatingWebhookConfiguration` and `ValidatingWebhookConfiguration` endpoints during the object lifecycle.
   - Webhook decisions occur **after** Authentication and Authorization (RBAC), but **before** objects are persisted to `etcd`.
   - **Failure Policy Trade-offs:** Setting `failurePolicy: Fail` enforces strict security but introduces availability risks if the webhook controller drops offline. Setting `failurePolicy: Ignore` prioritizes cluster availability at the cost of security bypasses during outage events.

3. **Operator Pattern for Security Automation:**
   - In-cluster scanners run as standard Kubernetes Operators, reconciling Custom Resource Definitions (CRDs) like `VulnerabilityReport`, `ClusterImageScan`, or `ConfigAuditReport`.
   - Resource overhead and performance must be governed via `resource` limits and dedicated `nodeSelector` / `tolerations` to avoid impacting core workloads.

---

## 2. Guided Production Exercises

---

### Module 1: Shift-Left Vulnerability Scanning & Automated CI/CD Gates

In this module, you will automate container image vulnerability scanning and Software Bill of Materials (SBOM) verification using `trivy` in a CI/CD automation pipeline format.

#### Step 1: Execute a Local Vulnerability Scan with Strict Failure Criteria

Run `trivy` against a targeted container image, filtering exclusively for `HIGH` and `CRITICAL` vulnerabilities with known fixes. Configure the tool to return a non-zero exit code on failure to block automated pipelines.

```bash
trivy image \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --exit-code 1 \
  --format table \
  python:3.9-slim
```

**Expected Output:**

```
2026-08-07T20:40:12.112Z	INFO	Vulnerability scanning is enabled
2026-08-07T20:40:12.112Z	INFO	Detected OS: debian 11.6
2026-08-07T20:40:12.120Z	INFO	Number of language-specific files: 0

python:3.9-slim (debian 11.6)
=============================
Total: 3 (HIGH: 2, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬────────────────────────────────────────────────────────┐
│   Library    │ Vulnerability  │ Severity │ Installed    │  Fixed Version    │                         Title                          │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ libssl1.1    │ CVE-2023-0286  │ CRITICAL │ 1.1.1n-0+deb11u3 │ 1.1.1n-0+deb11u4  │ OpenSSL: X.400 address type confusion in               │
│              │                │          │              │                   │ GENERAL_NAME_cmp                                       │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼────────────────────────────────────────────────────────┤
│ zlib1g       │ CVE-2023-45853 │ HIGH     │ 1.2.11.dfsg-2│ 1.2.11.dfsg-2+deb11u1│ zlib: integer overflow in MiniZip                      │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴────────────────────────────────────────────────────────┘

Error: exit status 1
```

#### Step 2: Automated SBOM Generation and Attestation Scanning

Generate an SPDX-compliant Software Bill of Materials (SBOM) for an image to fulfill supply chain traceability requirements.

```bash
trivy image \
  --format spdx-json \
  --output sbom.spdx.json \
  python:3.9-slim
```

Verify that the generated JSON SBOM contains package identification metadata:

```bash
head -n 25 sbom.spdx.json
```

**Expected Output:**

```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-07T20:41:00Z",
    "creators": [
      "Tool: trivy-0.50.0"
    ]
  },
  "name": "python:3.9-slim",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "http://aquasecurity.github.io/trivy/container/python:3.9-slim-12345",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-debian-libssl1.1",
      "name": "libssl1.1",
      "versionInfo": "1.1.1n-0+deb11u3",
      "downloadLocation": "NONE",
      "filesAnalyzed": false
    }
  ]
}
```

---

#### Module 1 Comprehension Questions

1. Why is passing `--ignore-unfixed` recommended when configuring automated pipeline security gates in enterprise CI/CD environments?
2. If a pipeline runs `trivy image` with `--exit-code 1`, what mechanism causes the CI server (e.g., GitHub Actions, GitLab CI) to halt execution of downstream deployment tasks?

---

### Module 2: Policy-as-Code & Automated Webhook Admission Control

In this module, you will author and validate a production-grade **Kyverno ClusterPolicy** manifest to automate security enforcement at the Kubernetes API admission boundary.

#### Step 1: Deploy a Production Security ClusterPolicy

Apply the following complete, syntactically valid `ClusterPolicy` manifest to enforce read-only root filesystems and disallow privilege escalation across all non-system workloads.

Create `policy-disallow-privilege-escalation.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privilege-escalation
  annotations:
    policies.kyverno.io/title: Disallow AllowPrivilegeEscalation
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Privilege escalation allows a process to gain more privileges than its parent
      process. This policy ensures allowPrivilegeEscalation is explicitly set to false.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-privilege-escalation
    match:
      any:
      - resources:
          kinds:
          - Pod
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
  - validate:
      message: "Privilege escalation is disallowed. Set securityContext.allowPrivilegeEscalation to false."
      pattern:
        spec:
          containers:
          - securityContext:
              allowPrivilegeEscalation: false
```

Apply the manifest to your cluster:

```bash
kubectl apply -f policy-disallow-privilege-escalation.yaml
```

**Expected Output:**

```
clusterpolicy.kyverno.io/disallow-privilege-escalation created
```

#### Step 2: Test API Server Enforcement Mechanics

Attempt to deploy a non-compliant workload manifest that omits `allowPrivilegeEscalation: false` or explicitly sets it to `true`.

Create `test-noncompliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vulnerable-test-pod
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    securityContext:
      allowPrivilegeEscalation: true
```

Execute `kubectl apply`:

```bash
kubectl apply -f test-noncompliant-pod.yaml
```

**Expected Output:**

```
Error from server (Forbidden): error when creating "test-noncompliant-pod.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/default/vulnerable-test-pod was blocked due to the following policies:

disallow-privilege-escalation:
  validate-privilege-escalation: 'Privilege escalation is disallowed. Set securityContext.allowPrivilegeEscalation
    to false.'
```

#### Step 3: Inspect Admission Webhook Configuration and Health Metrics

Query the cluster's active `ValidatingWebhookConfiguration` objects to inspect failure policies and timeout configurations:

```bash
kubectl get validatingwebhookconfigurations -o custom-columns=NAME:.metadata.name,FAIL_POLICY:.webhooks[*].failurePolicy,TIMEOUT:.webhooks[*].timeoutSeconds
```

**Expected Output:**

```
NAME                                      FAIL_POLICY   TIMEOUT
kyverno-resource-validating-webhook-cfg   Fail          10
cert-manager-webhook                      Fail          30
```

---

#### Module 2 Comprehension Questions

1. In the `ClusterPolicy` manifest, what is the operational difference between setting `validationFailureAction: Audit` vs `validationFailureAction: Enforce`?
2. What risk is introduced if a `ValidatingWebhookConfiguration` has `failurePolicy: Fail` and the underlying webhook controller deployment suffers a complete node outage?

---

### Module 3: Continuous In-Cluster Compliance & Operator-Based Scanning Automation

In this module, you will examine and diagnose continuous automated vulnerability reporting generated by in-cluster Operators.

#### Step 1: Deploy a Compliance Manifest with Scanning Annotations

Create a deployment manifest `secure-app-deployment.yaml` configured with strict security context fields for continuous operator assessment.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: default
  labels:
    app.kubernetes.io/name: secure-app
    app.kubernetes.io/component: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      containers:
      - name: web
        image: ccr.io/google-containers/pause:3.9
        securityContext:
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 10001
          allowPrivilegeEscalation: false
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

Apply the deployment:

```bash
kubectl apply -f secure-app-deployment.yaml
```

**Expected Output:**

```
deployment.apps/secure-app created
```

#### Step 2: Query Custom Resource Definitions (CRDs) Generated by Automated Scanners

List `VulnerabilityReport` and `ConfigAuditReport` CRDs managed by in-cluster automated security operators (e.g., Trivy Operator / Kubescape):

```bash
kubectl get vulnerabilityreports -n default -o wide
```

**Expected Output:**

```
NAME                                  REPOSITORY                      TAG    SCANNER   AGE   CRITICAL   HIGH   MEDIUM   LOW
replica-set-secure-app-67998b48bb-web ccr.io/google-containers/pause  3.9    Trivy     45s   0          0      0        0
```

Inspect detailed security finding metadata from the CRD:

```bash
kubectl get vulnerabilityreports replica-set-secure-app-67998b48bb-web -n default -o jsonpath='{.report.summary}' | jq .
```

**Expected Output:**

```json
{
  "criticalCount": 0,
  "highCount": 0,
  "lowCount": 0,
  "mediumCount": 0,
  "unknownCount": 0
}
```

#### Step 3: Diagnostic Troubleshooting of Webhook & Security Operator Failures

Diagnose high latency or API server rejection issues caused by security webhooks using `kubectl logs` and `kubectl get events`.

Query system events for Webhook failure markers:

```bash
kubectl get events -n default --field-selector reason=FailedCreate
```

**Expected Output:**

```
LAST SEEN   TYPE      REASON         OBJECT                   MESSAGE
12s         Warning   FailedCreate   replicaset/bad-app-54f   Error creating: admission webhook "validate.kyverno.svc-fail" denied the request: timeout calling webhook
```

Check admission webhook latency metrics via the API Server metrics endpoint (if accessible):

```bash
kubectl get --raw /metrics | grep apiserver_admission_webhook_admission_duration_seconds_count
```

**Expected Output:**

```
apiserver_admission_webhook_admission_duration_seconds_count{name="validate.kyverno.svc-fail",operation="CREATE",type="validating"} 452
```

---

#### Module 3 Comprehension Questions

1. Why are Custom Resource Definitions (CRDs) such as `VulnerabilityReport` preferred over storing scan results in ConfigMaps or external databases for Kubernetes native automation?
2. What diagnostic command sequence should an SRE execute if pod creations hang indefinitely across the entire cluster?

---

## 3. Official References & Documentation Links

- **CNCF KCSA Curriculum Repository:** [cncf/curriculum KCSA Document](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Dynamic Admission Control:** [Kubernetes Official Documentation - Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- **Kyverno Policy Architecture:** [Kyverno Documentation - Concepts & Policies](https://kyverno.io/docs/writing-policies/)
- **Aqua Security Trivy Documentation:** [Trivy Vulnerability Scanning CLI](https://aquasecurity.github.io/trivy/latest/)
- **CNCF Financial & Security Technical Advisory Group (TAG-Security):** [CNCF Cloud Native Security Supply Chain Best Practices](https://tag-security.cncf.io/)

---

## 4. Answers & Deep-Dive Explanations

<details>
<summary><strong>Click to expand Answers & Deep-Dive Explanations</strong></summary>

### Module 1 Answers

1. **Why `--ignore-unfixed` is used in enterprise pipelines:**  
   Passing `--ignore-unfixed` suppresses failure alerts for vulnerabilities that currently do not have a patch available from the upstream OS/package maintainers. In production CI/CD pipelines, failing a build on an un-patchable CVE halts software delivery without giving developers an immediate remediation path. It prevents pipeline fatigue while focusing developer effort strictly on actionable updates.

2. **Mechanism of CI execution failure (`--exit-code 1`):**  
   POSIX-compliant operating systems and shell environments return an exit status code (0 for success, 1–255 for errors) when a process terminates. CI orchestrators (such as GitHub Actions, GitLab CI, or Jenkins) check the return code of executed step commands. When `trivy` returns `1`, the runner intercepts the non-zero status, marks the step as failed, skips dependent pipeline stages (such as `cd-deploy`), and flags the build pipeline as broken.

---

### Module 2 Answers

1. **`validationFailureAction: Audit` vs `Enforce`:**  
   - **`Audit`:** The API server permits non-compliant objects to be created and written to `etcd`. However, policy violation events are logged in the API server audit logs, and status entries are reported in Kyverno's policy report CRDs. This mode is used for dry-running new policies in production without risking application outage.  
   - **`Enforce`:** The admission controller actively rejects API creation/update requests that violate the policy, returning an HTTP 403 Forbidden status directly to the requesting user or CI system.

2. **Risks of `failurePolicy: Fail` during controller outages:**  
   When `failurePolicy: Fail` is configured, the Kubernetes API Server *must* receive a successful HTTP 200 validation response from the admission controller before allowing any matching API operation to proceed. If the webhook controller pods crash, experience node loss, or become network-partitioned, the API server will block *all* subsequent resource creations or updates matching the webhook configuration pattern. This creates a hard cluster outage where deployments, statefulsets, and horizontal pod autoscalers cannot instantiate new pods.

---

### Module 3 Answers

1. **Why CRDs are preferred for continuous compliance storage:**  
   Storing security reports as CRDs allows platform teams to leverage native Kubernetes RBAC, API watchers, controller reconciliation loops, and CLI tooling (`kubectl`). Security metrics become native API objects that can trigger automated remediation operators, feed GitOps dashboards, or be queried via standard Kubernetes API endpoints without introducing third-party database dependencies inside the control plane.

2. **Diagnostic workflow for cluster-wide hanging pod creations:**  
   - **Step 1:** Run `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` to identify all active admission hooks.
   - **Step 2:** Check API server events using `kubectl get events -n default --field-selector type=Warning` to search for webhook timeout or rejection errors.
   - **Step 3:** Inspect the health and logs of the security webhook controller pods (e.g., `kubectl logs -n kyverno -l app=kyverno`).
   - **Step 4:** If emergency mitigation is required to restore cluster availability, temporarily set `failurePolicy: Ignore` on the webhook configuration using `kubectl edit validatingwebhookconfiguration <webhook-name>` or temporarily delete the problematic webhook object.

</details>