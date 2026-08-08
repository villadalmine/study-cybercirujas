# CNPE Study Guide — Topic 3.5: Integrating Security Scanning and Compliance Checks into Deployment Pipelines

**Certification:** Cloud Native Platform Engineer (CNPE)  
**Domain:** Deployment & Pipeline Architecture  
**Topic 3.5:** Integrating Security Scanning and Compliance Checks into Deployment Pipelines  
**Exam Weight:** 3%  

---

## 1. Production Motivation and Architectural Problem

In enterprise cloud-native platforms, the delivery pipeline represents both the primary pathway for business value and a high-value attack vector. Traditional security models relied on perimeter defenses and periodic manual compliance audits. In continuous deployment (CD) environments executing tens or hundreds of deployments daily, manual gating fails to scale, leading to two major anti-patterns:

1. **Security as a Bottleneck (Shift-Right Gating):** Vulnerabilities and non-compliant configurations are discovered late in production or staging environments, forcing costly post-deployment rollbacks, hotfixes, and extended remediation cycles.
2. **Unchecked Velocity (Bypassed Controls):** Security scans are decoupled from deployment pipelines to avoid slowing down releases, allowing unvetted container images, misconfigured Infrastructure-as-Code (IaC), and unsigned artifacts to enter production.

### Threat Vectors in Cloud-Native Pipelines

* **Vulnerable Dependencies & Base Images:** Exploitable CVEs inside base OS layers or application dependencies (e.g., Log4Shell, malicious npm/PyPI packages).
* **IaC and Kubernetes Manifest Drift/Misconfiguration:** Container privileges (`privileged: true`), root user execution, lack of resource limits, missing network policies, and exposed sensitive host paths (`/var/run/docker.sock`).
* **Supply Chain Tampering & Identity Impersonation:** Compromised CI worker nodes injecting malicious binaries into built images prior to registry push, or untrusted images injected directly into the cluster.
* **Lack of Attestation & Provenance:** Inability to cryptographically verify who built an image, what commit triggered the build, and which security gates were passed before deployment.

### Architectural Blueprint: Zero-Trust Continuous Compliance Pipeline

```
[ Git Commit ] 
      │
      ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Pre-Build / IaC & SAST Scan                                    │
│ ── Checkov / Trivy IaC Scan (K8s Manifests / Terraform)                │
│ ── Gitleaks (Secret Detection)                                          │
└──────────────────────────────────────┬─────────────────────────────────┘
                                       │
                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 2: Build, Vulnerability Scanning & Attestation Generation         │
│ ── Kaniko / Buildah (Rootless Image Build)                             │
│ ── Trivy / Grype (Container CVE Scan against Severity Threshold)        │
│ ── Generate SLSA Provenance & In-Toto Attestation                      │
└──────────────────────────────────────┬─────────────────────────────────┘
                                       │
                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Cryptographic Signing & Provenance Upload                      │
│ ── Sigstore Cosign (Sign Image Digest + Attach Attestation to OCI)    │
│ ── Push Signatures & Rekor Transparency Log Entry                      │
└──────────────────────────────────────┬─────────────────────────────────┘
                                       │
                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Phase 4: Runtime Admission Control & In-Cluster Enforcement            │
│ ── Kyverno / OPA Gatekeeper Admission Webhook                          │
│ ── Verify Cosign Signature & Attestation before Pod Execution          │
│ ── Audit / Block Non-Compliant Manifests (PSP/PSS Enforcement)        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Technical Comparison & Trade-Off Matrix

Integrations must occur at multiple lifecycle boundaries to achieve Defense-in-Depth. The following table contrasts the primary security scanning and compliance enforcement patterns in cloud-native pipelines.

| Metric / Attribute | Static IaC & Manifest Scanning | Container Image Vulnerability Scanning | Cryptographic Supply Chain Signing | Admission Control & Policy Enforcement |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Tooling** | Checkov, Kube-linter, TFSec, Trivy | Trivy, Grype, Clair | Sigstore Cosign, in-toto | Kyverno, OPA Gatekeeper, Falco |
| **Execution Point** | Pre-commit / Pre-build CI Phase | Post-build / Pre-push CI Phase | Post-scan / Pre-deployment CI Phase | In-Cluster Kubernetes API Server Admission (`Mutating`/`Validating`) |
| **Detection Target** | Misconfigurations, exposed secrets, non-compliant spec fields | Known CVEs in OS packages (apk, apt) & language libraries | Image tampering, unauthorized provenance, unsigned digests | Non-compliant API requests attempting object creation |
| **Pipeline Latency Impact** | Low (5s – 30s) | Medium to High (30s – 3m) | Low (2s – 10s) | Near Zero (<50ms per API request) |
| **Blocking Mechanism** | CI Job Exit Code (`exit 1`) | CI Job Exit Code (`exit 1`) based on CVSS / Severity | CI Job Exit Code (`exit 1`) | HTTP 403 Forbidden on API Server admission |
| **Bypass Vulnerability** | High (Developer can pass `--skip-check` or edit CI script) | Medium (Developer can push directly to registry bypassing CI) | Low (Registry credentials & Private key / OIDC identity required) | Extremely Low (Enforced at Kubernetes API level) |
| **False Positive Overhead**| Moderate (Requires `.trivyignore` or inline annotations) | High (Stale databases, non-exploitable CVE paths) | Minimal (Binary pass/fail signature check) | Low (Determined strictly by platform team policy definitions) |

---

## 3. Production Manifests and Infrastructure Configurations

### 3.1 Complete Tekton Pipeline Definition for Secure Delivery

The following Tekton pipeline executes:
1. Manifest & IaC Security Scan (Trivy).
2. Container Image Vulnerability Scan (Trivy).
3. Image Cryptographic Signing via Cosign.

```yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: production-security-pipeline
  namespace: cicd-pipelines
spec:
  params:
    - name: git-url
      type: string
      description: "Git repository URL"
    - name: git-revision
      type: string
      default: "main"
    - name: image-reference
      type: string
      description: "Target container image location without tag"
    - name: image-tag
      type: string
      description: "Target image tag (git commit SHA)"
  workspaces:
    - name: shared-workspace
    - name: cosign-keys
  tasks:
    - name: fetch-source
      taskRef:
        name: git-clone
      params:
        - name: url
          value: $(params.git-url)
        - name: revision
          value: $(params.git-revision)
      workspaces:
        - name: output
          workspace: shared-workspace

    - name: scan-iac-manifests
      runAfter: ["fetch-source"]
      taskSpec:
        workspaces:
          - name: source
        steps:
          - name: iac-scan
            image: aquasec/trivy:0.50.1
            workingDir: $(workspaces.source.path)
            script: |
              #!/bin/sh
              set -e
              echo "Starting IaC and Kubernetes Manifest Scan..."
              trivy config \
                --severity HIGH,CRITICAL \
                --exit-code 1 \
                --format table \
                .
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: build-and-scan-image
      runAfter: ["scan-iac-manifests"]
      taskSpec:
        params:
          - name: image
            type: string
        workspaces:
          - name: source
        steps:
          - name: container-scan
            image: aquasec/trivy:0.50.1
            workingDir: $(workspaces.source.path)
            script: |
              #!/bin/sh
              set -e
              echo "Scanning container image $(params.image) for CVEs..."
              trivy image \
                --severity CRITICAL \
                --exit-code 1 \
                --vuln-type os,library \
                --ignore-unfixed \
                --format table \
                $(params.image)
      params:
        - name: image
          value: "$(params.image-reference):$(params.image-tag)"
      workspaces:
        - name: source
          workspace: shared-workspace

    - name: sign-container-image
      runAfter: ["build-and-scan-image"]
      taskSpec:
        params:
          - name: image-digest
            type: string
        workspaces:
          - name: keys
        steps:
          - name: cosign-sign
            image: bitnami/cosign:2.2.3
            env:
              - name: COSIGN_PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: cosign-key-passphrase
                    key: password
            script: |
              #!/bin/sh
              set -e
              echo "Signing container image digest with Cosign..."
              cosign sign \
                --key $(workspaces.keys.path)/cosign.key \
                -a buildId=$(context.pipelineRun.name) \
                -a commit=$(params.image-tag) \
                --yes \
                $(params.image-digest)
      params:
        - name: image-digest
          value: "$(params.image-reference):$(params.image-tag)"
      workspaces:
        - name: keys
          workspace: cosign-keys
```

---

### 3.2 Production Kyverno ClusterPolicy for Image Verification and Security Enforcement

This policy enforces two critical rules:
1. Block any Pod execution if the image is **not cryptographically signed** by the organization's Cosign key.
2. Require all containers to run as **non-root**, disallowing privilege escalation.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signed-nonroot-images
  annotations:
    policies.kyverno.io/title: Verify Image Signatures and Enforce Non-Root Execution
    policies.kyverno.io/category: Supply Chain Security & Pod Security Standards
    policies.kyverno.io/severity: critical
    policies.kyverno.io/description: >-
      Enforces cryptographic signature verification using Cosign keys for all deployment
      images and blocks execution of containers configured with root privileges.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: verify-image-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
                - staging
      verifyImages:
        - imageReferences:
            - "ghcr.io/architecture-org/*"
            - "docker.io/architecture-org/*"
          key: |
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7pL8q7R/kHlV/Z11X1G6O0L+A8Qp
            s6H5/gJ3XqL9U8+eW+1W3X7+L2J8Z1+p3K9L5W7+N+P3L2J8Z1+p3K==
            -----END PUBLIC KEY-----
          attestations:
            - predicateType: https://slsa.dev/provenance/v0.2
              attestors:
                - count: 1
                  entries:
                    - keys:
                        publicKeys: |
                          -----BEGIN PUBLIC KEY-----
                          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7pL8q7R/kHlV/Z11X1G6O0L+A8Qp
                          s6H5/gJ3XqL9U8+eW+1W3X7+L2J8Z1+p3K9L5W7+N+P3L2J8Z1+p3K==
                          -----END PUBLIC KEY-----

    - name: restrict-root-execution
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
                - staging
      validate:
        message: "Running as root is forbidden. SecurityContext must set runAsNonRoot: true and runAsUser > 0."
        pattern:
          spec:
            securityContext:
              runAsNonRoot: true
            containers:
              - name: "*"
                securityContext:
                  allowPrivilegeEscalation: false
                  readOnlyRootFilesystem: true
                  capabilities:
                    drop:
                      - ALL
```

---

## 4. Real CLI Execution & Terminal Output Simulation

### 4.1 Step 1: Pre-Build Manifest Scan with Trivy

```bash
$ trivy config --severity HIGH,CRITICAL --exit-code 1 ./deploy/kubernetes/
```

```text
2026-08-07T14:10:02.114Z  INFO  Need to update DB
2026-08-07T14:10:02.114Z  INFO  Downloading DB...
2026-08-07T14:10:05.421Z  INFO  Misconfiguration scanning is enabled
2026-08-07T14:10:05.892Z  INFO  Detected config files: 2

deploy/kubernetes/deployment.yaml (kubernetes)
==============================================
Tests: 24 (SUCCESSES: 22, FAILURES: 2, CHECK_OV: 0)
Failures: 2 (HIGH: 1, CRITICAL: 1)

CRITICAL: Container 'payment-api' should set 'securityContext.runAsNonRoot' to true
────────────────────────────────────────────────────────────────────────────────
Inside deployment manifest, securityContext.runAsNonRoot is either missing or set to false.
Running containers as root presents a significant security risk.

See https://avd.aquasec.com/misconfig/ksv012

HIGH: Container 'payment-api' is not dropping ALL capabilities
────────────────────────────────────────────────────────────────────────────────
Containers should drop all default Linux capabilities and add back only necessary ones.

See https://avd.aquasec.com/misconfig/ksv003

Error: exit status 1
```

---

### 4.2 Step 2: Container Image Vulnerability Scanning

```bash
$ trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed ghcr.io/architecture-org/payment-api:v2.4.1
```

```text
2026-08-07T14:12:10.041Z  INFO  Vulnerability scanning is enabled
2026-08-07T14:12:10.041Z  INFO  Secret scanning is enabled
2026-08-07T14:12:10.041Z  INFO  Detected OS: alpine
2026-08-07T14:12:10.042Z  INFO  Detecting Alpine vulnerabilities...
2026-08-07T14:12:10.065Z  INFO  Number of language-specific files: 1
2026-08-07T14:12:10.065Z  INFO  Detecting gobinary vulnerabilities...

ghcr.io/architecture-org/payment-api:v2.4.1 (alpine 3.18.0)
============================================================
Total: 0 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 0)

Node.js (node_modules)
======================
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬──────────────┬───────────────────┬──────────────────────────────────────────────┐
│   LIBRARY    │ VULNERABILITY  │ SEVERITY │ INSTALLED    │   FIXED VERSION   │                    TITLE                     │
├──────────────┼────────────────┼──────────┼──────────────┼───────────────────┼──────────────────────────────────────────────┤
│ express      │ CVE-2024-99999 │ CRITICAL │ 4.17.1       │ 4.19.2            │ Remote Code Execution in Query Parser        │
└──────────────┴────────────────┴──────────┴──────────────┴───────────────────┴──────────────────────────────────────────────┘

Error: exit status 1
```

---

### 4.3 Step 3: Cryptographic Signing with Cosign

Assuming the vulnerability was remediated and the build re-executed:

```bash
$ cosign sign --key /etc/cosign/keys/cosign.key \
  -a repository="https://github.com/architecture-org/payment-api" \
  -a commit="7f3b1a9e8d" \
  --yes \
  ghcr.io/architecture-org/payment-api:v2.4.2
```

```text
Enter password for private key: 
Pushing signature to: ghcr.io/architecture-org/payment-api

Signed OCI artifact ghcr.io/architecture-org/payment-api:v2.4.2 resolve to digest:
ghcr.io/architecture-org/payment-api@sha256:a4b8c9d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9
```

---

### 4.4 Step 4: Verification of Signature and Policy Gating in Kubernetes

Verifying locally before applying:

```bash
$ cosign verify --key /etc/cosign/keys/cosign.pub ghcr.io/architecture-org/payment-api:v2.4.2
```

```text
Verification for ghcr.io/architecture-org/payment-api:v2.4.2 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims below were verified against the signature against the batch public key

[{"critical":{"identity":{"docker-reference":"ghcr.io/architecture-org/payment-api"},"image":{"docker-manifest-digest":"sha256:a4b8c9d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9"},"type":"cosign container image signature"},"optional":{"commit":"7f3b1a9e8d","repository":"https://github.com/architecture-org/payment-api"}}]
```

Attempting to deploy an **unsigned** image into the `production` namespace:

```bash
$ kubectl apply -f deploy/kubernetes/unsigned-deployment.yaml -n production
```

```text
Error from server (Forbidden): error when creating "deploy/kubernetes/unsigned-deployment.yaml": admission webhook "kyverno-resource-validating-webhook" denied the request:

resource Deployment/production/untrusted-app was blocked due to the following policies:

enforce-signed-nonroot-images:
  verify-image-signature:
    failed to verify signature for image ghcr.io/untrusted-vendor/app:v1.0.0: 
    no matching signatures found for key specification.
```

---

## 5. Verification, Debugging, and Troubleshooting Guide

### 5.1 Common Failure Modes & Root Cause Analysis

#### Mode 1: False Positive Blocking Pipeline Execution
* **Symptom:** CI/CD pipeline fails at container scanning step due to non-exploitable CVEs (e.g., CLI binaries not invoked in production runtime).
* **Diagnostic Procedure:**
  1. Inspect the detailed report output using JSON formatting: `trivy image -f json -o report.json <image>`.
  2. Verify if a vendor fix exists. If no fix exists, use `--ignore-unfixed`.
  3. If a CVE is evaluated as non-exploitable by security engineers, add an entry to `.trivyignore` accompanied by a mandatory expiry timestamp and tracking ticket ID.

```text
# .trivyignore
# CVE-2023-XXXXX verified non-exploitable due to static binary compilation
# Ticket: SEC-8891, Expires: 2026-12-31
CVE-2023-XXXXX
```

#### Mode 2: Admission Webhook Latency / Control Plane Lockout
* **Symptom:** API requests to create pods fail with `context deadline exceeded` or time out when communicating with Kyverno or OPA Gatekeeper webhooks.
* **Diagnostic Procedure:**
  1. Check the health and status of the admission controller pods:
     ```bash
     kubectl get pods -n kyverno -l app.kubernetes.io/name=kyverno
     ```
  2. Inspect the webhook configuration timeout settings (`timeoutSeconds` should typically be set between `3` and `10` seconds):
     ```bash
     kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook -o yaml
     ```
  3. Verify `failurePolicy`. In production architectures, critical namespaces should use `failurePolicy: Fail` combined with high availability (HA) webhook replicas (3+ pods with pod anti-affinity). For non-critical namespaces, temporary degraded state recovery uses `failurePolicy: Ignore`.

#### Mode 3: Cosign Key Mismatch / Fulcio OIDC Failure
* **Symptom:** Kyverno rejects validly signed images during admission control with `no matching signatures found`.
* **Diagnostic Procedure:**
  1. Verify the public key embedded in the Kyverno policy matches the private key used by the CI signer:
     ```bash
     diff <(cosign public-key --key /path/to/ci/cosign.key) <(kubectl get clusterpolicy enforce-signed-nonroot-images -o jsonpath='{.spec.rules[0].verifyImages[0].key}')
     ```
  2. If using keyless signing (Fulcio/Rekor), verify network connectivity from the cluster nodes/admission webhook to the Rekor transparency log endpoint (`rekor.sigstore.dev` or private instance).

### 5.2 Diagnostic Playbook Summary

```bash
# 1. Audit cluster policy violation history
kubectl get policyreports,clusterpolicyreports -A

# 2. Check Kyverno admission controller logs for verification errors
kubectl logs -n kyverno -l app.kubernetes.io/instance=kyverno --tail=200 | grep -i "signature verification failed"

# 3. Test Cosign verification manually against a specific public key and image digest
cosign verify --key /etc/cosign/keys/cosign.pub ghcr.io/architecture-org/payment-api@sha256:<digest>
```

---

## 6. References

* **CNCF Curriculum Repository:**  
  [https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)
* **Aquasec Trivy Official Documentation:**  
  [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)
* **Sigstore Cosign Documentation:**  
  [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
* **Kyverno Policy Engine Documentation:**  
  [https://kyverno.io/docs/](https://kyverno.io/docs/)
* **OPA Gatekeeper Documentation:**  
  [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)
* **Supply-chain Levels for Software Artifacts (SLSA):**  
  [https://slsa.dev/](https://slsa.dev/)
* **in-toto Supply Chain Security Framework:**  
  [https://in-toto.io/](https://in-toto.io/)