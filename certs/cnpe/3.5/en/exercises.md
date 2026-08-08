# CNPE Study Module 3.5: Integrating Security Scanning and Compliance Checks into Deployment Pipelines

**Domain**: GitOps and Continuous Delivery / Platform Security  
**Weight**: 3  
**Target Audience**: Senior SREs, Lead Platform Engineers, Cloud Native Architects  
**Official References**:
- [CNCF Certification - CNPE](https://www.cncf.io/certification/cnpe/)
- [Trivy Documentation](https://aquasecurity.github.io/trivy/)
- [Sigstore / Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Kyverno CLI & Policy Documentation](https://kyverno.io/docs/kyverno-cli/)
- [Open Policy Agent (OPA) / Conftest](https://www.conftest.dev/)
- [in-toto Attestations Specification](https://github.com/in-toto/attestation)

---

## Technical Architecture & Mechanical Foundations

Integrating security scanning and compliance verification into cloud-native continuous delivery (CD) workflows requires shifting security controls to the left (CI build stage) while continuously enforcing them to the right (Kubernetes Admission Controllers & Runtime Operators).

```
   +-----------------------------------------------------------------------------------+
   |                                 CI/CD PIPELINE                                   |
   |                                                                                   |
   |  [ Git Commit ] ---> [ IaC / Lint Scan ] ---> [ Container Build & SBOM Gen ]     |
   |                             |                           |                         |
   |                     (Trivy / Conftest)          (Syft / Trivy SBOM)               |
   |                                                         v                         |
   |                                               [ Vulnerability Scan ]              |
   |                                                         |                         |
   |                                              [ Cosign Image & Attest Sign ]       |
   +---------------------------------------------------------|-------------------------+
                                                             |
                                           Push Artifact &   | Signatures / Attestations
                                           Metadata Bundle   v
   +-----------------------------------------------------------------------------------+
   |                            OCI CONTAINER REGISTRY                                 |
   +-----------------------------------------------------------------------------------+
                                                             |
                                                   Image Pull & Manifests
                                                             v
   +-----------------------------------------------------------------------------------+
   |                        KUBERNETES ADMISSION CONTROL LAYER                         |
   |                                                                                   |
   | [ API Request ] ---> [ Kyverno / Gatekeeper ] ---> [ Cosign Verify Signature ]    |
   |                              |                         |                          |
   |                    Check Manifest Rules      Verify Image Provenance & SBOM       |
   |                              v                         v                          |
   |                    [ Allow / Block API ]   [ Generate Cluster Policy Report ]     |
   +-----------------------------------------------------------------------------------+
```

### Architectural Trade-Off Matrix

| Strategy Stage | Tooling Ecosystem | Primary Objectives | Latency vs. Protection Trade-Off |
| :--- | :--- | :--- | :--- |
| **Pre-Commit / Local** | `trivy`, `pre-commit`, `checkov` | Immediate developer feedback on secret leaks & IaC misconfigurations. | Extremely low latency (<2s). High risk of developer bypass (`--no-verify`). |
| **CI Build Pipeline** | `trivy`, `syft`, `cosign`, `conftest` | Block non-compliant builds, produce verifiable SBOMs, sign OCI artifacts. | Medium latency (30s–5m). Prevents vulnerable images from entering registry. |
| **Admission Control** | `kyverno`, `OPA Gatekeeper` | Cryptographic verification of signatures/attestations; enforcement of K8s Pod Security Standards. | Sub-second API overhead (~10ms–100ms). Hard gate against unauthorized workload execution. |
| **Runtime Audit** | `trivy-operator`, `falco` | Detect newly published zero-day CVEs post-deployment and monitor anomalous syscalls. | Asynchronous, zero pipeline latency. High alert volume requiring auto-remediation loops. |

---

## Guided Hands-On Exercises

---

### Module 1: Vulnerability & IaC Scanning with Trivy and SARIF Integration

#### Context & Objectives
You need to configure a deterministic CI step that scans both container images and Infrastructure-as-Code (Helm/Kustomize/YAML) manifests. The step must fail on `CRITICAL` vulnerabilities with known fixes, ignore non-actionable CVEs using an audit trail file (`.trivyignore`), and emit a standard SARIF (Static Analysis Results Interchange Format) artifact.

#### Execution Steps

1. Create a project directory and an example insecure Kubernetes Deployment manifest (`deployment.yaml`):

```bash
mkdir -p ~/cnpe-sec-lab/manifests
cat <<'EOF' > ~/cnpe-sec-lab/manifests/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      containers:
      - name: app
        image: nginx:1.18.0
        securityContext:
          privileged: true
          runAsUser: 0
        ports:
        - containerPort: 80
EOF
```

2. Execute Trivy via CLI to perform a static IaC misconfiguration scan against the `manifests/` directory:

```bash
trivy iac ~/cnpe-sec-lab/manifests/ \
  --severity HIGH,CRITICAL \
  --format table
```

**Expected Terminal Output:**
```text
Target: /home/user/cnpe-sec-lab/manifests/deployment.yaml (k8s)
================================================================
Tests: 23 (SUCCESSES: 21, FAILURES: 2, EXCEPTIONS: 0)
Failures: 2 (HIGH: 1, CRITICAL: 1)

+-------------------+------------+----------+--------------------+------------------------------------------------+
|       TYPE        |  RULE ID   | SEVERITY |     RESOURCE       |                  DESCRIPTION                   |
+-------------------+------------+----------+--------------------+------------------------------------------------+
| Kubernetes Security| KSV014     | CRITICAL | payment-processor  | Container 'app' should not run as root         |
| Kubernetes Security| KSV017     | HIGH     | payment-processor  | Container 'app' is running in privileged mode  |
+-------------------+------------+----------+--------------------+------------------------------------------------+
```

3. Configure an audit-approved ignore file `.trivyignore` to filter out specific non-fixable or risk-accepted CVEs for container image scanning:

```bash
cat <<'EOF' > ~/cnpe-sec-lab/.trivyignore
# CVE-2023-99999 accepted by SecOps team ticket SEC-8843 until Q4 upstream patch
CVE-2023-99999
EOF
```

4. Run a container image scan outputting results to a SARIF report while exiting with non-zero code on unignored `CRITICAL` vulnerabilities with available fixes:

```bash
trivy image \
  --exit-code 1 \
  --severity CRITICAL \
  --ignore-unfixed \
  --ignorefile ~/cnpe-sec-lab/.trivyignore \
  --format sarif \
  --output ~/cnpe-sec-lab/trivy-results.sarif \
  nginx:1.18.0
```

**Expected Terminal Output:**
```text
2026-08-07T18:30:00.000Z	INFO	Vulnerability scanning is enabled
2026-08-07T18:30:01.000Z	INFO	Detected OS: debian/10
2026-08-07T18:30:01.000Z	INFO	Number of language-specific files: 0
2026-08-07T18:30:02.000Z	INFO	[debian] Detecting vulnerabilities...
2026-08-07T18:30:03.000Z	CRITICAL	CVE-2021-3618 (nginx) - fixed in 1.20.1-1
Error: exit status 1
```

5. Inspect the generated SARIF schema using `jq` to verify structure validity:

```bash
jq '{version: .version, runs: [.runs[] | {tool: .tool.driver.name, resultCount: (.results | length)}]}' ~/cnpe-sec-lab/trivy-results.sarif
```

**Expected Terminal Output:**
```json
{
  "version": "2.1.0",
  "runs": [
    {
      "tool": "Trivy",
      "resultCount": 18
    }
  ]
}
```

6. Inspect a declarative GitHub Actions workflow integration (`.github/workflows/security.yaml`):

```yaml
name: Security Pipeline Scan
on:
  push:
    branches: [ "main" ]
  pull_request:

jobs:
  security-audit:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Run Trivy IaC Scan
        uses: aquasecurity/trivy-action@0.20.0
        with:
          scan-type: 'config'
          scan-ref: './manifests'
          exit-code: '1'
          severity: 'HIGH,CRITICAL'

      - name: Run Trivy Image Scan & Generate SARIF
        uses: aquasecurity/trivy-action@0.20.0
        if: always()
        with:
          image-ref: 'nginx:1.18.0'
          format: 'sarif'
          output: 'trivy-results.sarif'
          severity: 'CRITICAL,HIGH'

      - name: Upload SARIF to GitHub Code Scanning
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: 'trivy-results.sarif'
```

---

#### Verification Questions - Module 1

1. **Why is `--ignore-unfixed` standard practice in automated build gating for production pipelines? What is the primary operational trade-off?**
2. **What structural guarantees does SARIF output provide over standard human-readable stdout tables when integrating with enterprise DevSecOps platforms?**

---

### Module 2: Generating SBOMs and Cryptographic Signing with Cosign

#### Context & Objectives
To ensure Supply Chain Levels for Software Artifacts (SLSA) compliance, you will generate an SBOM (Software Bill of Materials) in SPDX/CycloneDX format, build a local container image, sign the OCI artifact cryptographically using `cosign`, and attach an in-toto vulnerability attestation directly to the OCI registry metadata layer.

#### Execution Steps

1. Install `cosign` and generate a cryptographic key pair locally:

```bash
# Set password for private key non-interactively for CI simulation
export COSIGN_PASSWORD="ProductionGradePassword123!"

cosign generate-key-pair file://~/cnpe-sec-lab/cosign-key
```

**Expected Terminal Output:**
```text
Logging writing key to /home/user/cnpe-sec-lab/cosign-key.key
Private key written to /home/user/cnpe-sec-lab/cosign-key.key
Public key written to /home/user/cnpe-sec-lab/cosign-key.pub
```

2. Build a dummy image and push it to a local registry (or emulate a local registry using Docker/Podman):

```bash
# Spin up a lightweight OCI distribution registry locally
docker run -d -p 5000:5000 --name registry registry:2

# Create a sample Dockerfile and build
mkdir -p ~/cnpe-sec-lab/app && cd ~/cnpe-sec-lab/app
cat <<'EOF' > Dockerfile
FROM alpine:3.19.1
RUN apk add --no-舆 curl
ENTRYPOINT ["curl"]
EOF

docker build -t localhost:5000/secure-app:v1.0.0 .
docker push localhost:5000/secure-app:v1.0.0
```

3. Generate a CycloneDX SBOM for the pushed container image using Trivy (or Syft):

```bash
trivy image \
  --format cyclonedx \
  --output ~/cnpe-sec-lab/app/sbom.cdx.json \
  localhost:5000/secure-app:v1.0.0
```

4. Sign the OCI Container Image using `cosign` and the generated private key:

```bash
cosign sign \
  --key ~/cnpe-sec-lab/cosign-key.key \
  --yes \
  localhost:5000/secure-app:v1.0.0
```

**Expected Terminal Output:**
```text
Enter password for private key: 
Pushing signature to: localhost:5000/secure-app
```

5. Attach the SBOM as an in-toto attestation to the image digest on the OCI registry:

```bash
cosign attest \
  --key ~/cnpe-sec-lab/cosign-key.key \
  --type cyclonedx \
  --predicate ~/cnpe-sec-lab/app/sbom.cdx.json \
  --yes \
  localhost:5000/secure-app:v1.0.0
```

**Expected Terminal Output:**
```text
Uploading attestation for [localhost:5000/secure-app:v1.0.0] to [localhost:5000/secure-app]...
```

6. Obtain the precise immutable digest tag generated by Cosign in the registry:

```bash
# Verify signature against public key
cosign verify \
  --key ~/cnpe-sec-lab/cosign-key.pub \
  localhost:5000/secure-app:v1.0.0
```

**Expected Terminal Output:**
```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/secure-app"
      },
      "image": {
        "docker-manifest-digest": "sha256:8f4c22b10a97b2b647612f0e08f870503ef974ee0f09a5676eeefae7cf712869"
      },
      "type": "cosign container image signature"
    },
    "optional": null
  }
]
```

---

#### Verification Questions - Module 2

1. **How does Cosign store signatures and attestations inside an OCI v1.1 spec compliant container registry without altering the underlying image layers or digest?**
2. **What is the security difference between signing an OCI image by `tag` (e.g., `:v1.0.0`) versus signing by `digest` (`@sha256:...`), and how does this impact pipeline security?**

---

### Module 3: Pre-Deployment Policy-as-Code Enforcement via Kyverno CLI & Conftest

#### Context & Objectives
Pipeline validation must catch structural violations prior to contacting the cluster API server. You will author a production Kyverno `ClusterPolicy` and an OPA/Rego `Conftest` policy, then execute local static validation against deployment manifests within the pipeline.

#### Execution Steps

1. Create a declarative Kyverno policy file (`~/cnpe-sec-lab/policies/disallow-root.yaml`) enforcing non-root user execution and disallowing privileged escalation:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-pod-security-baseline
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-non-root
      match:
        any:
        - resources:
            kinds:
              - Pod
              - Deployment
      validate:
        message: "Running as root is forbidden. SecurityContext must define runAsNonRoot: true."
        pattern:
          spec:
            template:
              spec:
                containers:
                  - securityContext:
                      runAsNonRoot: true
                      allowPrivilegeEscalation: false
```

2. Test the policy against your `deployment.yaml` using the `kyverno` CLI tool directly in the pipeline step:

```bash
kyverno apply ~/cnpe-sec-lab/policies/disallow-root.yaml \
  --resource ~/cnpe-sec-lab/manifests/deployment.yaml
```

**Expected Terminal Output:**
```text
Applying 1 policy rule(s) to 1 resource(s)...

POLICY                         RULE             RESOURCE                         RESULT
enforce-pod-security-baseline  check-non-root   apps/v1/Deployment/production/payment-processor  FAIL

PASS: 0 | FAIL: 1 | WARN: 0 | SKIP: 0
```

3. Create an equivalent OPA/Rego rule for `Conftest` in `policy/security.rego`:

```rego
package main

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.privileged == true
  msg := sprintf("Container '%v' in Deployment '%v' is not allowed to run in privileged mode", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.containers[_].securityContext.runAsNonRoot == true
  msg := sprintf("Container '%v' in Deployment '%v' must explicitly set runAsNonRoot to true", [input.spec.template.spec.containers[_].name, input.metadata.name])
}
```

4. Execute `conftest` over the Kubernetes manifests:

```bash
conftest test ~/cnpe-sec-lab/manifests/deployment.yaml --policy ~/cnpe-sec-lab/policy/
```

**Expected Terminal Output:**
```text
FAIL - /home/user/cnpe-sec-lab/manifests/deployment.yaml - main - Container 'app' in Deployment 'payment-processor' is not allowed to run in privileged mode
FAIL - /home/user/cnpe-sec-lab/manifests/deployment.yaml - main - Container 'app' in Deployment 'payment-processor' must explicitly set runAsNonRoot to true

2 tests, 0 passed, 0 warnings, 2 failures, 0 exceptions
```

---

#### Verification Questions - Module 3

1. **What are the primary operational trade-offs between evaluating manifests in CI using `kyverno apply` / `conftest` versus relying exclusively on an in-cluster Admission Webhook?**
2. **If a manifest relies on dynamic mutations (e.g., Kyverno mutate rules or Helm template rendering), how must the CI pipeline be configured to prevent false-negative policy validation results?**

---

### Module 4: In-Cluster Admission Verification & Advanced Diagnostics

#### Context & Objectives
Even if pipeline scanning passes, an attacker or compromised CD agent could attempt to deploy unsigned images directly to the API server. You will deploy a Kyverno image verification policy in an active Kubernetes cluster, attempt to deploy an unsigned container image, diagnose the failure using `kubectl` inspection tools, and view generated Policy Reports.

#### Execution Steps

1. Apply a Kyverno `ClusterPolicy` that enforces Cosign image signature verification at the Kubernetes Admission Controller level:

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
      - imageReferences:
        - "localhost:5000/*"
        - "quay.io/secure-org/*"
        key: |
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE... [YOUR_PUBLIC_KEY_PEM]
-----END PUBLIC KEY-----
EOF
```

2. Attempt to deploy an unsigned image (`nginx:latest`) into a restricted namespace:

```bash
kubectl create namespace production-secured
kubectl run unauthorized-pod \
  --image=nginx:latest \
  -n production-secured
```

**Expected Terminal Output:**
```text
Error from server (BadRequest): admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: 

resource Pod/production-secured/unauthorized-pod was blocked due to the following policies:
verify-image-signature:
  verify-signature: 'image "docker.io/library/nginx:latest" failed signature verification: no matching signatures found'
```

3. Perform advanced diagnostic querying on the Kyverno admission webhook events and Policy Reports:

```bash
# Query API server warning events for admission rejections
kubectl get events \
  -n production-secured \
  --field-selector type=Warning \
  --reason PolicyViolation
```

4. Retrieve cluster-wide Security Policy Reports formatted as CRDs:

```bash
kubectl get policyreport -n production-secured -o yaml
```

**Expected Terminal Output Snippet:**
```yaml
apiVersion: wgpolicyk8s.io/v1alpha2
kind: PolicyReport
metadata:
  name: cpol-verify-image-signature
  namespace: production-secured
results:
  - category: Pod Security Standard
    message: 'image "docker.io/library/nginx:latest" failed signature verification'
    policy: verify-image-signature
    resources:
      - apiVersion: v1
        kind: Pod
        name: unauthorized-pod
        namespace: production-secured
    result: fail
    severity: high
```

---

#### Verification Questions - Module 4

1. **When an Admission Webhook times out due to registry network latency during signature verification, how does the `failurePolicy` (`Fail` vs `Ignore`) impact cluster availability and security posture?**
2. **How do SREs isolate whether a deployment blockage originated from a GitOps engine (e.g., ArgoCD/Flux sync failure) or an API Server Admission Controller rejection?**

---

## <details><summary>Exercise Solutions & Deep Technical Explanations</summary>

### Module 1 Solutions

1. **`--ignore-unfixed` Mechanics & Operational Trade-offs**:
   - *Mechanics*: Flags CVEs that have been identified in upstream packages (e.g., OS libraries or language runtimes) for which the vendor/maintainer has **not yet released a patched version**.
   - *Rationale*: If a pipeline fails on unfixable CVEs, developers cannot remediate the issue without altering base images or dropping dependencies. This causes pipeline toil, deployment lockouts, and alert fatigue.
   - *Trade-off*: Using `--ignore-unfixed` prevents pipeline blocking on non-actionable vulnerabilities, maintaining deployment velocity. However, it introduces exposure to unmitigated residual risks. SREs must compensate by using compensating controls (e.g., runtime WAFs, eBPF syscall filtering with Falco) and running asynchronous background scans to track unpatched zero-days.

2. **SARIF Structural Guarantees**:
   - *Interoperability*: SARIF (JSON-based IEEE standard) provides a unified JSON schema for static analysis tools.
   - *Rich Context*: Unlike human-readable tables, SARIF includes precise source-code URI mapping, line/column offsets, CWE rule mappings, fingerprinting IDs (to track persistent alerts across commits), and remediation snippets.
   - *Automation*: DevSecOps dashboards (e.g., GitHub Code Scanning, DefectDojo) natively parse SARIF to automatically open/close vulnerability tickets without regex scraping of terminal stdout.

---

### Module 2 Solutions

1. **Cosign OCI Storage Mechanics**:
   - Cosign leverages the OCI Image Index and Distribution Specification. It converts signatures and attestations into standard OCI artifacts.
   - For an image with digest `sha256:123456...`, Cosign pushes signature payloads to a calculated image tag formatted as `sha256-123456....sig` inside the same registry repository.
   - Because signatures reside in a separate manifest linked by digest reference, the base container image manifest and layer hashes remain entirely unmodified, ensuring digest immutability.

2. **Image Tag vs. Digest Signing Security**:
   - *Signing by Tag (`:v1.0.0`)*: Tags in OCI registries are mutable pointers. An attacker with registry access can overwrite `:v1.0.0` to point to a malicious image layer. If a signature was bound strictly to the tag string rather than the underlying manifest payload, the integrity check could be bypassed or rendered ambiguous.
   - *Signing by Digest (`@sha256:...`)*: Digests are cryptographically immutable SHA-256 hashes of the image manifest. Signing the digest guarantees that the signature is immutably tied to the exact byte content of the container layers. Production pipelines must resolve tags to explicit digests (`image:tag@sha256:...`) before generating Cosign signatures and validating them in admission controllers.

---

### Module 3 Solutions

1. **CI-based Validation vs. In-Cluster Admission Trade-offs**:
   - *CI Validation (`kyverno apply` / `conftest`)*: 
     - **Pros**: Fast feedback loop (seconds), zero impact on cluster API Server performance, blocks invalid PRs before merging to `main`.
     - **Cons**: Can be bypassed if users bypass CI, cannot evaluate runtime-dependent states (e.g., checking dynamically assigned cluster IP pools or existing cluster resources).
   - *Admission Controllers*:
     - **Pros**: Ultimate authorization gate; enforces policies regardless of how the API call reached the cluster (kubectl, GitOps, CI/CD, script).
     - **Cons**: Introduces API latency; misconfigured webhooks can crash control plane deployments; error messages occur late in the deployment cycle.
   - *Best Practice*: Implement a **Shift-Smart** strategy—use identical policy definitions in both CI (for fast feedback) and Admission (for hard enforcement).

2. **Handling Dynamic Mutations in CI**:
   - If cluster admission engines apply mutations (e.g., injecting sidecars, mutating image paths, adding standard labels), testing raw source manifests in CI will trigger false positives.
   - *Solution*: Pipelines must execute dry-run templating steps prior to policy checks. For Helm, run `helm template`. For Kustomize, run `kustomize build`. For Kyverno mutations, use `kyverno apply --resource=manifest.yaml --policy=mutate-policy.yaml` to simulate the post-mutation manifest state before evaluating validation rules.

---

### Module 4 Solutions

1. **`failurePolicy` Dynamics**:
   - `failurePolicy: Fail` (Production Security Default): If the admission webhook endpoint times out or experiences network partition while attempting to verify image signatures against external registries/KMS, the API server **rejects** the workload creation.
     - *Security Posture*: High security (Fail-Closed).
     - *Availability Risk*: High vulnerability to cluster outage if network/registry latency causes webhooks to exceed `webhookTimeoutSeconds`.
   - `failurePolicy: Ignore`: If the webhook times out, the API server bypasses verification and permits the pod creation.
     - *Security Posture*: Vulnerable (Fail-Open).
     - *Availability Risk*: Prioritizes application uptime over security checks.

2. **Diagnostic Separation: GitOps vs. Admission Webhook Failure**:
   - SREs execute the following diagnostic sequence:
     1. **Check GitOps Status**: Inspect ArgoCD/Flux application sync status. If ArgoCD reports `SharedResourceWarning` or `SyncFailed`, inspect the app sync details via `argocd app get <app-name>`.
     2. **Inspect API Server Response**: If the error states `admission webhook "...kyverno..." denied the request`, the block occurred at the API server entry point.
     3. **Query Cluster Events**: Run `kubectl get events -n <namespace> --field-selector reason=FailedCreate` to see exact rejection messages returned by the validating webhook controller.
     4. **Review Controller Logs**: Tail logs of the admission controller (`kubectl logs -n kyverno -l app=kyverno`) to trace certificate errors, network timeouts, or signature evaluation stack traces.

</details>