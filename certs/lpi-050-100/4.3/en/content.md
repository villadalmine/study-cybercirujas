# LPI 050-100: Topic 4.3 – Compliance and Risk Mitigation
**Exam Objective:** 054.3 / 4.3 Compliance and Risk Mitigation  
**Weight:** 7.5 (Targeted for Advanced SRE & Platform Architecture Production Operations)

---

## 1. Production Architectural Motivation & Problem Context

In modern enterprise cloud-native environments, open-source software (OSS) accounts for up to 80%–90% of the codebase in compiled container artifacts and deployment manifests. While OSS accelerates engineering velocity, introducing third-party code without systematic governance creates severe legal, financial, and operational risks:

1. **Licensing Legal Exposure & Viral Propagation:**
   - **Copyleft Contamination:** Inadvertently bundling Strong Copyleft (e.g., GNU GPLv3) or Network Copyleft (e.g., GNU AGPLv3) software into proprietary microservices can legally compel an organization to open-source its proprietary intellectual property (IP).
   - **License Incompatibility:** Combining software modules under incompatible licenses (e.g., Apache 2.0 and GPLv2) creates legal deadlocks where compliance with one license violates the other.
   - **Attribution & Notice Violations:** Failing to preserve copyright notices, license texts, or `NOTICE` files (required by Apache 2.0 or BSD-3-Clause) in distributed binaries or SaaS client applications triggers automatic termination of usage rights under strict license clauses.

2. **Supply Chain Attacks & Vulnerability Transitivity:**
   - **Transitive Dependency Risks:** Deep dependency trees (e.g., Node.js `npm` or Python `PyPI`) make manually tracking license changes or zero-day vulnerabilities impossible. Malicious actors leverage typosquatting or compromised maintainer accounts to insert backdoors under permissive licenses.
   - **Lack of Software Transparency:** Without a verifiable Software Bill of Materials (SBOM), Security Operations (SecOps) and Site Reliability Engineering (SRE) teams cannot determine within target Service Level Objectives (SLOs) whether a critical CVE (e.g., Log4Shell) affects deployed production workloads.

3. **Regulatory & Compliance Mandates:**
   - Frameworks such as Executive Order 14028, EU Cyber Resilience Act, ISO/IEC 5230 (OpenChain specification for open source compliance), and ISO/IEC 18974 (open source security assurance) mandate cryptographic provenance verification, complete SBOM generation (SPDX/CycloneDX), and continuous automated license governance throughout the Software Development Life Cycle (SDLC).

```
 +-----------------------------------------------------------------------------------+
 |                                  CI/CD PIPELINE                                   |
 |                                                                                   |
 |  +---------------+      +------------------+      +----------------------------+  |
 |  | Developer     | ---> | Syft / Trivy     | ---> | Cosign / Sigstore          |  |
 |  | Git Commit    |      | (SBOM & License) |      | (Image & SBOM Attestation) |  |
 |  +---------------+      +------------------+      +----------------------------+  |
 +---------------------------------------|-------------------------------------------+
                                         |
                                         v
 +-----------------------------------------------------------------------------------+
 |                           KUBERNETES PRODUCTION CLUSTER                           |
 |                                                                                   |
 |  +--------------------+    +----------------------------+    +-----------------+  |
 |  | kubectl apply /    | -> | OPA Gatekeeper / Kyverno   | -> | Pod Execution   |  |
 |  | GitOps Controller  |    | (Validating Admission Rule)|    | (Compliant)     |  |
 |  +--------------------+    +----------------------------+    +-----------------+  |
 |                                         |                                         |
 |                                         v (Non-compliant: Blocked)                |
 |                                    [Rejected 403]                                 |
 +-----------------------------------------------------------------------------------+
```

---

## 2. Technical Comparisons & Trade-Off Matrix

### 2.1 Open Source License Categories

| License Category | Representative Licenses | Source Code Disclosure Requirement | Patent Grant Protection | Commercial SaaS Risk Level | Key Operational Trade-off |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Permissive** | MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0 | None (Binary distribution allowed without source code) | Explicit in Apache-2.0; Silent in MIT/BSD | **Low** | Maximum freedom; low legal friction; requires maintaining attribution notices. |
| **Weak Copyleft** | LGPL-2.1, LGPL-3.0, MPL-2.0 | Mandatory for modifications to the library itself; dynamic linking preserves proprietary code confidentiality | Explicit in LGPL-3.0 & MPL-2.0 | **Medium** | Safe for dynamic linking; risk arises if statically linked or library source code is modified. |
| **Strong Copyleft** | GPL-2.0, GPL-3.0 | Mandatory for any derivative work distributed to third parties | Explicit in GPL-3.0 | **High** (if binaries distributed) | Triggers source code disclosure upon external distribution; low risk for pure internal SaaS unless client-side JS is delivered. |
| **Network Copyleft** | AGPL-3.0, SSPL | Mandatory for derivative works accessed over a network (SaaS/Cloud service) | Explicit | **CRITICAL** | Interacting with AGPL code via network APIs compels disclosure of the entire server-side application codebase. |

---

### 2.2 Policy Enforcement Engines for Kubernetes & CI/CD

| Feature / Metric | Open Policy Agent (OPA) Gatekeeper | Kyverno | Native ValidatingAdmissionPolicy |
| :--- | :--- | :--- | :--- |
| **Policy Language** | Rego (Declarative, Query-based) | Native YAML (Kubernetes CRDs) | Common Expression Language (CEL) |
| **Learning Curve** | High (Requires learning Rego syntax & structure) | Low (Standard K8s YAML patterns) | Moderate (Requires learning CEL expressions) |
| **External Data Lookup** | Supported via cached data replication or Provider sidecars | Supported via HTTP calls or ConfigMaps | Limited (In-tree evaluation, context-aware) |
| **Audit Capabilities** | Continuous cluster state evaluation via `Constraint` status | Background scan reports via `AdmissionReport` | In-tree metrics and dry-run execution modes |
| **Performance Impact** | Low-to-Medium (Engine evaluation in Go) | Low-to-Medium (Engine evaluation in Go) | **Extremely Low** (Evaluated directly inside `kube-apiserver`) |

---

### 2.3 Software Bill of Materials (SBOM) Standards

| Metric | SPDX (System Package Data Exchange - ISO/IEC 5921) | CycloneDX (OWASP Standard) |
| :--- | :--- | :--- |
| **Primary Focus** | Open-source license compliance, copyright tracking, and provenance | Cybersecurity supply chain, vulnerability analysis, components (VEX) |
| **Governing Body** | Linux Foundation | OWASP Foundation |
| **Data Formats** | Tag/Value, JSON, YAML, TV, XML, RDF | JSON, XML, Protobuf |
| **Vulnerability Exchange (VEX)** | Supported via extension specifications | Natively integrated (VEX BOM profile) |
| **Industry Adoption** | Preferred by Linux kernel, ISO standards, systems software | Preferred by SecOps, cloud-native application security tools |

---

## 3. Complete Production Manifests & Infrastructure Configurations

### 3.1 GitHub Actions Workflow: Automated SBOM, License Audit, and Sigstore Attestation

This pipeline builds a container image, generates a full SPDX SBOM using `syft`, audits dependencies for disallowed licenses (GPL, AGPL) using `trivy`, and signs the image and SBOM using `cosign`.

```yaml
name: Production Security & Compliance Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build-compliance-check:
    name: Build, Audit License Compliance, and Sign Attestations
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Install Sigstore Cosign
        uses: sigstore/cosign-installer@v3.5.0

      - name: Install Anchore Syft
        uses: anchore/sbom-action/download-syft@v0.16.0

      - name: Install Aqua Security Trivy
        uses: aquasecurity/trivy-action@0.20.0

      - name: Build Container Image Locally
        uses: docker/build-push-action@v5
        with:
          context: .
          load: true
          tags: ghcr.io/enterprise/secure-api:1.4.0
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Generate SPDX SBOM JSON
        run: |
          syft ghcr.io/enterprise/secure-api:1.4.0 \
            -o spdx-json=sbom.spdx.json \
            --source-version 1.4.0

      - name: Audit Open Source Licenses with Trivy
        run: |
          trivy image \
            --severity HIGH,CRITICAL \
            --scanners license \
            --ignored-licenses Apache-2.0,MIT,BSD-2-Clause,BSD-3-Clause,ISC,MPL-2.0 \
            --exit-code 1 \
            ghcr.io/enterprise/secure-api:1.4.0

      - name: Log in to GitHub Container Registry
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push Container Image
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          docker push ghcr.io/enterprise/secure-api:1.4.0

      - name: Sign Container Image (Keyless OIDC)
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          cosign sign --yes ghcr.io/enterprise/secure-api:1.4.0

      - name: Attach and Sign SBOM Attestation
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: |
          cosign attest --yes \
            --type spdxjson \
            --predicate sbom.spdx.json \
            ghcr.io/enterprise/secure-api:1.4.0
```

---

### 3.2 OPA Gatekeeper Policy: Block Forbidden Container Images and Enforce Approved Registries

#### 3.2.1 ConstraintTemplate Definitions (`k8sallowedregistries.yaml`)

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
  annotations:
    metadata.gatekeeper.sh/title: "Allowed Container Registries"
    description: "Requires container images to originate from pre-approved enterprise registries."
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Container image '%v' is not from an approved registry. Allowed prefixes: %v", [container.image, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Init container image '%v' is not from an approved registry. Allowed prefixes: %v", [container.image, input.parameters.registries])
        }
```

#### 3.2.2 Enforcement Constraint (`enforce-approved-registries.yaml`)

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: enforce-approved-registries
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
  parameters:
    registries:
      - "ghcr.io/enterprise/"
      - "765432109876.dkr.ecr.us-east-1.amazonaws.com/production/"
```

---

### 3.3 Kyverno ClusterPolicy: Enforce Mandatory Image Signatures (Cosign Verification)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signatures
  annotations:
    policies.kyverno.io/title: Verify Cosign Attestations
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Verifies that container images running in production namespaces have been signed by 
      the enterprise GitHub Actions CI/CD identity.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-signature-github-oidc
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
      verifyImages:
        - imageReferences:
            - "ghcr.io/enterprise/*"
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main"
```

---

## 4. Real CLI Commands & Terminal Output Sequences

### 4.1 Generating and Parsing SPDX SBOM Data with `syft`

**Command:**
```bash
$ syft alpine:3.19.1 -o spdx-json
```

**Expected Terminal Output:**
```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-06T19:22:10Z",
    "creators": [
      "Tool: syft-1.3.0",
      "Organization: Enterprise Platform Security"
    ],
    "licenseListVersion": "3.22"
  },
  "name": "alpine-3.19.1",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://anchore.com/syft/image/alpine-3.19.1-3965d1d6-c870-4217-b733-4fbd3540aef5",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-apk-tools-2.14.0-r5",
      "name": "apk-tools",
      "versionInfo": "2.14.0-r5",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "GPL-2.0-only",
      "licenseDeclared": "GPL-2.0-only",
      "supplier": "Organization: Alpine Linux",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:apk/alpine/apk-tools@2.14.0-r5?arch=x86_64&distro=alpine-3.19.1"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-musl-1.2.4_git20230717-r2",
      "name": "musl",
      "versionInfo": "1.2.4_git20230717-r2",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "supplier": "Organization: Alpine Linux"
    }
  ]
}
```

---

### 4.2 Scanning Container Images for Non-Compliant Licenses with `trivy`

**Command:**
```bash
$ trivy image \
    --scanners license \
    --severity CRITICAL,HIGH \
    --ignored-licenses Apache-2.0,MIT,BSD-3-Clause \
    ghcr.io/untrusted-vendor/analytics-engine:2.1.0
```

**Expected Terminal Output:**
```text
2026-08-06T19:24:45.102-0400	INFO	Need to update license DB
2026-08-06T19:24:45.103-0400	INFO	Downloading license DB...
2026-08-06T19:24:47.332-0400	INFO	License DB update successfully finished
2026-08-06T19:24:48.012-0400	INFO	License scanning is enabled
2026-08-06T19:24:48.450-0400	INFO	Detected OS: alpine
2026-08-06T19:24:48.451-0400	INFO	Number of language-specific files: 1
2026-08-06T19:24:48.451-0400	INFO	Detecting Node.js packages licenses...

ghcr.io/untrusted-vendor/analytics-engine:2.1.0 (alpine 3.19.1)
===============================================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 1, CRITICAL: 1)

┌──────────────────────┬──────────────────┬──────────┬─────────────────┬──────────────────────────────────────────┐
│       Package        │     License      │ Severity │  Category       │ File Path                                │
├──────────────────────┼──────────────────┼──────────┼─────────────────┼──────────────────────────────────────────┤
│ gnu-ghostscript      │ AGPL-3.0-only    │ CRITICAL │ NetworkCopyleft │ usr/bin/gs                               │
│ web-scraper-module   │ GPL-3.0-or-later │ HIGH     │ StrongCopyleft  │ app/node_modules/web-scraper/package.json│
└──────────────────────┴──────────────────┴──────────┴─────────────────┴──────────────────────────────────────────┘

Error: license classification violation found. Exiting with code 1
```

---

### 4.3 Verifying Image Attestation Signature with `cosign`

**Command:**
```bash
$ cosign verify \
    --certificate-identity "https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    ghcr.io/enterprise/secure-api:1.4.0
```

**Expected Terminal Output:**
```text
Verification for ghcr.io/enterprise/secure-api:1.4.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims below were verified under issuer identity 'https://token.actions.githubusercontent.com' and subject 'https://github.com/enterprise/compliance-engine/.github/workflows/pipeline.yaml@refs/heads/main'
  - The signatures were verified against the Rekor transparency log
  - The certificates were verified against the Fulcio root CA

[{"critical":{"identity":{"docker-reference":"ghcr.io/enterprise/secure-api"},"image":{"docker-manifest-digest":"sha256:e839e4407da5a5d2e09c855a9b0c26569ec11894d01b1c676d08006e8efdfc02"},"type":"cosign container image signature"},"optional":{"Bundle":{"SignedEntryTimestamp":"MEUCIQDVf3K2X...==","Payload":{"body":"..."}}}}]
```

---

### 4.4 Testing Kubernetes Admission Control Enforcement via `kubectl`

**Command:**
```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: illegal-image-test
  namespace: production
spec:
  containers:
    - name: untrusted-app
      image: docker.io/library/nginx:latest
EOF
```

**Expected Terminal Output:**
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validation.gatekeeper.sh" denied the request: [enforce-approved-registries] Container image 'docker.io/library/nginx:latest' is not from an approved registry. Allowed prefixes: ["ghcr.io/enterprise/", "765432109876.dkr.ecr.us-east-1.amazonaws.com/production/"]
```

---

## 5. Verification, Diagnostic & Failure Troubleshooting Guide

### 5.1 Troubleshooting Workflow: Kubernetes Admission Control Failure

When container deployments fail during Kubernetes API submission due to policy webhooks, follow this structured diagnostic matrix:

```
                      +------------------------------------------+
                      | Pod Admission Denied (HTTP 403 Forbidden) |
                      +------------------------------------------+
                                           |
                                           v
                     +-------------------------------------------+
                     | Inspect API error message from `kubectl`  |
                     +-------------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
                    v                                             v
  [Gatekeeper Policy Violation]                   [Webhook Timeout / Connection Refused]
                    |                                             |
                    v                                             v
  1. Check Constraint status:                     1. Inspect Gatekeeper Pod status:
     `kubectl describe k8sallowedregistries`         `kubectl get pods -n gatekeeper-system`
  2. Inspect Audit Logs:                          2. Check Webhook Configuration:
     `kubectl logs -n gatekeeper-system -l ...`      `kubectl describe validatingwebhookconfigurations`
  3. Validate Rego input payloads                 3. Verify APIServer -> Webhook Latency (<500ms)
```

---

### 5.2 Common Production Failure Modes & Remediation

#### Failure Mode 1: Dual-Licensed Package Identification False Positives
- **Symptom:** CI/CD pipeline fails during `trivy` or `fossa` scan on packages dual-licensed under `(MIT OR GPL-2.0)`. The scanner flags the package as high-risk due to the presence of `GPL-2.0`.
- **Root Cause:** Naive regex matching in scanner engine evaluates both license terms instead of applying standard SPDX disjunctive expression rules (`OR` logic).
- **Remediation:** Configure `--ignored-licenses` or an explicit `.trivyignore` file declaring chosen license paths:
  ```yaml
  # .trivyignore
  # Dual-licensed package choice: Explicitly choosing MIT over GPL-2.0
  licenses:
    - id: "GPL-2.0-only"
      package: "node-glob"
      statement: "Dual licensed under MIT OR GPL-2.0. Organization elects MIT."
  ```

#### Failure Mode 2: Gatekeeper Webhook Latency Spikes Causing API Server Timeouts
- **Symptom:** Kubernetes deployments hang, and `kubectl` throws `Internal error occurred: failed calling webhook "validation.gatekeeper.sh": deadline exceeded`.
- **Root Cause:** Gatekeeper pod CPU starvation or excessively large OPA data cache (replicated K8s resources) causing Rego execution evaluation times to exceed `failurePolicy: Fail` timeout thresholds (typically 5–10 seconds).
- **Diagnostic Commands:**
  ```bash
  # Check Gatekeeper controller-manager resource consumption
  $ kubectl top pods -n gatekeeper-system

  # Filter logs for webhook evaluation latency > 500ms
  $ kubectl logs -n gatekeeper-system -l control-plane=controller-manager --tail=1000 \
    | jq 'select(.event_type == "rego" and .latency_ms > 500)'
  ```
- **Remediation:** Increase CPU requests/limits for `gatekeeper-controller-manager` deployment, and exclude transient system namespaces (e.g., `kube-system`) from webhook evaluation scope using `namespaceSelector`.

#### Failure Mode 3: Missing OIDC Certificate Identity during Keyless Cosign Verification
- **Symptom:** `cosign verify` fails in production cluster admission webhook with `error: no matching signatures found`.
- **Root Cause:** CI/CD pipeline runs on a git commit triggered by a pull request from a fork or a detached branch, producing a different OIDC `subject` identity than expected by the production verification policy.
- **Diagnostic Commands:**
  ```bash
  # Dump exact OIDC subject embedded inside the image signature bundle
  $ cosign download signature ghcr.io/enterprise/secure-api:1.4.0 \
    | jq -r '.critical.identity'
  ```
- **Remediation:** Ensure GitHub Actions jobs set explicit `id-token: write` permissions and match the exact workflow ref path in the admission control policy.

---

## 6. References

- **Linux Professional Institute (LPI) Open Source Essentials Overview:**  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
- **Linux Foundation SPDX (System Package Data Exchange) Specification:**  
  https://spdx.dev/
- **OWASP CycloneDX Software Bill of Materials Standard:**  
  https://cyclonedx.org/
- **CNCF Open Policy Agent (OPA) Gatekeeper Documentation:**  
  https://open-policy-agent.github.io/gatekeeper/
- **CNCF Kyverno Policy Engine for Kubernetes:**  
  https://kyverno.io/
- **CNCF Sigstore Cosign Keyless Image Signing & Attestation:**  
  https://www.sigstore.dev/
- **Open Source Initiative (OSI) Official License Definitions:**  
  https://opensource.org/licenses