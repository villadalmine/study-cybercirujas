# LPI 050-100 Study Guide | Topic 4.1: Software Development Business Models
**Target Level:** Principal Platform Architect / Senior SRE  
**Exam Weight:** 5  
**Domain:** Open Source Essentials (LPI 050-100)

---

## 1. Motivation and Architectural Production Problem

### 1.1 The Enterprise Software Supply Chain & Monetization Dynamics
In modern cloud-native platform architecture, open-source software (OSS) forms the foundational runtime substrate—ranging from operating system kernels (Linux) and container orchestrators (Kubernetes) to database engines (PostgreSQL) and observability stacks (Prometheus). However, the economics of software development require sustainable funding models. The strategy chosen by a project or vendor to monetize software directly influences:

1. **Architectural Coupling & Lock-in Risk**: How features are split between community (FLOSS) editions and enterprise (proprietary) add-ons.
2. **License Compliance & Legal Exposure**: Copyleft (GPL, AGPL) vs. Permissive (Apache 2.0, MIT) vs. Source-Available (BSL/BUSL, SSPL) implications for enterprise container images and SaaS wrappers.
3. **Operational Viability & Fork Contingency**: The probability of sudden relicensing events (e.g., Terraform to OpenTofu under BUSL 1.1; Redis to dual RSALv2/SSPLv1; Elasticsearch to SSPL).

```
                      +-------------------------------------------------+
                      |     Enterprise Software Supply Chain Intake      |
                      +-------------------------------------------------+
                                               |
                                               v
                      +-------------------------------------------------+
                      |      License & Business Model Classifier        |
                      +-------------------------------------------------+
                               /               |               \
                              /                |                \
                             v                 v                 v
               +-------------------+  +-----------------+  +-------------------+
               | Permissive/FLOSS  |  |   Open Core     |  | Source-Available  |
               | (MIT, Apache 2.0) |  | (Proprietary    |  | (BSL, SSPL, AGPL) |
               |                   |  | Extensions)     |  |                   |
               +-------------------+  +-----------------+  +-------------------+
                         |                     |                     |
                         v                     v                     v
               +-------------------+  +-----------------+  +-------------------+
               | Unrestricted      |  | Audit Features &|  | SRE Isolation &   |
               | Cloud Deployment  |  | Feature Gates   |  | Legal Gatekeeping |
               +-------------------+  +-----------------+  +-------------------+
```

### 1.2 The Production SRE Challenge: License Compliance Enforcement at Scale
Platform engineering teams must automatically inspect every binary, container image, and third-party dependency pulled into continuous delivery (CD) pipelines. Allowing an incompatible or source-available license into a multi-tenant cloud application can trigger copyleft contagion (requiring proprietary code disclosure) or statutory violation of vendor terms of service.

From an architectural standpoint, SREs must design automated admission controllers and build-time static scanners that intercept non-compliant software before it is scheduled onto production Kubernetes clusters.

---

## 2. Technical Comparisons & Trade-Off Matrix

### 2.1 Software Development Business Models Breakdown

1. **Open Core Model**:
   - *Mechanics*: The core application logic is licensed under a permissive (e.g., Apache 2.0) or copyleft license, while advanced enterprise capabilities (RBAC, SSO, multi-region replication, audit logging, clustering) are kept closed-source under a proprietary license.
   - *Architectural Impact*: Requires running separate enterprise binaries or loading proprietary plugins/sidecars alongside the core engine.

2. **Dual Licensing Model**:
   - *Mechanics*: The vendor releases the software under a strong copyleft license (e.g., AGPLv3 or GPLv2) to prevent commercial competitors from embedding it into proprietary products without releasing their code. Simultaneously, the vendor sells commercial licenses to enterprise buyers who wish to keep their derivative work proprietary.
   - *Architectural Impact*: Strong legal guardrails required in CI/CD to prevent mixing GPL/AGPL dependencies into proprietary microservices.

3. **Software as a Service (SaaS) / Managed Services**:
   - *Mechanics*: The core software remains open source, but the commercial entity hosts, manages, scales, and secures the software as a cloud offering (e.g., Managed Grafana, AWS Aurora). Monetization relies on operational efficiency, uptime SLAs, and infrastructure abstraction.
   - *Architectural Impact*: SRE teams must evaluate "Self-Hosted Open Source TCO" (infrastructure + engineer operational toil) versus "Managed SaaS TCO" (network egress + vendor subscription costs).

4. **Services, Support & Subscription Model**:
   - *Mechanics*: Pure open-source codebase (100% FLOSS). Revenue is generated through enterprise SLAs, security patching, long-term support (LTS) releases, custom integration engineering, and certification training (e.g., Red Hat Enterprise Linux, SUSE).
   - *Architectural Impact*: Complete vendor portability with zero codebase locks; reliance on external repositories for certified enterprise security patches.

5. **Source-Available / Business Source License (BSL/BUSL / SSPL)**:
   - *Mechanics*: Non-OSI-approved licenses designed to block Cloud Service Providers (CSPs) from re-selling the software as a managed service without contributing revenue. Code is viewable, but commercial competition or hosting is restricted until a change-date (e.g., 4 years) converts it back to Apache 2.0 / MIT.
   - *Architectural Impact*: SREs must track change-date timelines and audit internal cloud platform services to prevent trademark or license breach when hosting internal developer platforms.

### 2.2 Deep Trade-Off Analysis

| Business Model | Primary Revenue Engine | License Profile | SRE Operational Complexity | Supply Chain Security Risk | License Lock-in Risk |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Open Core** | Proprietary add-on features (SSO, Encryption, Audit) | Mixed (Apache 2.0 Core + Commercial Enterprise) | **Medium-High**: Requires managing distinct upstream builds & licensing keys. | **Low**: Vendor curates security patches for enterprise builds. | **High**: Enterprise features create hard vendor dependency. |
| **Dual Licensing** | Commercial exemption sales to proprietary developers | Strong Copyleft (GPL/AGPL) or Proprietary Commercial | **Low**: Unified binary build. | **Medium**: Requires tracking internal redistribution of linked code. | **Medium**: Relicensing code require Contributor License Agreements (CLAs). |
| **SaaS / Hosted** | Usage-based infrastructure billing & management SLA | Permissive (MIT, Apache 2.0, BSD) | **Lowest (Managed)** / **High (Self-Hosted)** | **Low**: CSP manages patch management and operational guardrails. | **Medium**: API compatibility drift across cloud providers. |
| **Support/Subscription** | SLA support, certified binaries, security backports | 100% FLOSS (GPL, Apache 2.0) | **Medium**: standard OS/middleware lifecycle management. | **Lowest**: Enterprise-backed security errata (CVE remediation). | **Lowest**: Absolute code freedom; can fork if vendor strays. |
| **Source-Available** | Protective monetization against Cloud Providers | Non-OSI (BSL 1.1, SSPL, RSALv2) | **Medium**: Strict usage tracking required for hosting scenarios. | **Medium**: Dependent on single vendor patch pipelines. | **Highest**: Risk of sudden restrictive relicensing terms. |

---

## 3. Production Infrastructure & Compliance Manifests

To enforce business model and license compliance across cloud-native platforms, architects deploy build-time Software Bill of Materials (SBOM) analyzers alongside cluster admission policies.

The manifests below illustrate a complete, production-grade supply chain guardrail:
1. **Tekton PipelineRun**: Generates a SPDX SBOM using `syft` and audits licenses using `trivy` during container image build.
2. **Kyverno ClusterPolicy**: Intercepts `Pod` creation in Kubernetes to prevent deployment of container images tagged with restricted licenses (e.g., AGPL-3.0, BSL-1.1) or missing verified compliance annotations.

### 3.1 Build-Time Compliance: Tekton PipelineRun (`license-audit-pipeline.yaml`)

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: supply-chain-license-audit-run
  namespace: cicd-pipelines
  labels:
    app.kubernetes.io/name: license-audit
    app.kubernetes.io/part-of: platform-governance
spec:
  pipelineSpec:
    tasks:
      - name: generate-sbom-and-audit-license
        taskSpec:
          steps:
            - name: extract-sbom
              image: anchore/syft:v1.3.0
              script: |
                #!/usr/bin/env sh
                set -euo pipefail
                echo "[+] Scanning container image for dependency SBOM generation..."
                syft registry:quay.io/prometheus/prometheus:v2.51.0 \
                  -o spdx-json=/workspace/sbom.spdx.json \
                  -o table=/workspace/sbom-summary.txt
                echo "[+] SBOM generation complete."
                cat /workspace/sbom-summary.txt
            - name: evaluate-license-compliance
              image: aquasec/trivy:0.50.1
              script: |
                #!/usr/bin/env sh
                set -euo pipefail
                echo "[+] Executing Trivy License Compliance Evaluation..."
                trivy image \
                  --severity HIGH,CRITICAL \
                  --scanners license \
                  --ignored-licenses "MIT,Apache-2.0,BSD-3-Clause,BSD-2-Clause,MPL-2.0" \
                  --exit-code 1 \
                  quay.io/prometheus/prometheus:v2.51.0
                echo "[+] Image passed software license compliance policies."
---
```

### 3.2 Runtime Admission Guardrail: Kyverno ClusterPolicy (`enforce-license-guardrail.yaml`)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-approved-software-licenses
  annotations:
    policies.kyverno.io/title: Enforce Approved Open Source Licenses
    policies.kyverno.io/category: Software Supply Chain Governance
    policies.kyverno.io/severity: High
    policies.kyverno.io/subject: Pod, Container
    description: >-
      Blocks pod deployment if container images contain restricted licenses
      (e.g., AGPL-3.0, SSPL-1.0, BUSL-1.1) or lack verified supply-chain metadata.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: block-restricted-licenses-annotation
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Pod deployment rejected: Container image contains prohibited or non-compliant license terms (AGPL/SSPL/BUSL)."
        pattern:
          metadata:
            annotations:
              compliance.platform.io/license-audit: "APPROVED"
              compliance.platform.io/license-classification: "!AGPL-3.0 & !SSPL-1.0 & !BUSL-1.1"
    - name: require-sbom-attestation
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Pod deployment rejected: Missing mandatory SBOM attestation metadata."
        pattern:
          metadata:
            annotations:
              compliance.platform.io/sbom-spdx-hash: "?*"
```

---

## 4. Real CLI Commands & Real Terminal Outputs

### 4.1 CLI Command 1: Generating a Production SBOM and License Audit with Syft
SREs use `syft` to catalog all packages and software licenses embedded within a production container image.

```bash
$ syft quay.io/keycloak/keycloak:24.0.2 -o json | jq '.artifacts[] | {name: .name, version: .version, licenses: .licenses[].value}' | head -n 30
```

**Expected Real Output:**
```json
{
  "name": "microprofile-openapi-api",
  "version": "3.1.1",
  "licenses": "Apache-2.0"
}
{
  "name": "netty-buffer",
  "version": "4.1.108.Final",
  "licenses": "Apache-2.0"
}
{
  "name": "hibernate-core",
  "version": "6.4.4.Final",
  "licenses": "LGPL-2.1-or-later"
}
{
  "name": "jackson-databind",
  "version": "2.16.1",
  "licenses": "Apache-2.0"
}
{
  "name": "quarkus-core",
  "version": "3.8.3",
  "licenses": "Apache-2.0"
}
```

### 4.2 CLI Command 2: Evaluating License Violations via Trivy
This command executes a strict license check against a target image, asserting an exit code of `1` upon discovering forbidden or copyleft licenses.

```bash
$ trivy image --scanners license --ignored-licenses "MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause" --exit-code 1 redis:7.2.4-alpine
```

**Expected Real Output:**
```text
2026-08-06T19:15:22.412Z	[INFO]	License scanner progress: 100%
2026-08-06T19:15:22.891Z	[INFO]	Number of language-specific files: 1

redis:7.2.4-alpine (alpine 3.19.1)
==================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 2, CRITICAL: 0)

┌──────────┬──────────────────┬──────────┬───────────────────┬──────────────────────────────────────────┐
│ Package  │ Classification   │ Severity │ License           │ Resource Path                            │
├──────────┼──────────────────┼──────────┼───────────────────┼──────────────────────────────────────────┤
│ redis    │ Restricted       │ HIGH     │ RSALv2            │ usr/local/bin/redis-server               │
│ redis    │ Restricted       │ HIGH     │ SSPL-1.0          │ usr/local/bin/redis-server               │
└──────────┴──────────────────┴──────────┴───────────────────┴──────────────────────────────────────────┘

Error: exit status 1
```

### 4.3 CLI Command 3: Testing Kyverno Policy Enforcement on Kubernetes
Verifying runtime block of non-compliant manifests against a live Kubernetes control plane.

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unverified-redis-workload
  namespace: production
  annotations:
    compliance.platform.io/license-audit: "REJECTED"
    compliance.platform.io/license-classification: "SSPL-1.0"
spec:
  containers:
  - name: redis
    image: redis:7.2.4
EOF
```

**Expected Real Output:**
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Pod/production/unverified-redis-workload was blocked due to the following policies:

enforce-approved-software-licenses:
  block-restricted-licenses-annotation: 'Pod deployment rejected: Container image contains prohibited or non-compliant license terms (AGPL/SSPL/BUSL).'
```

---

## 5. Verification & Diagnostic Failure Guide

### 5.1 Diagnostic Workflow for License & Business Model Compliance Failures

```
                          [ Deployment Pipeline Failure ]
                                         |
                                         v
                         +-------------------------------+
                         | Check CI/CD Stage Exit Code   |
                         +-------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
             [ Exit Code 1: Trivy ]               [ Admission Blocked ]
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         | Inspect Scanner Output    |       | Check Kyverno Event Logs  |
         | Identify Forbidden SPDX   |       | Verify Pod Annotations    |
         +---------------------------+       +---------------------------+
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         | Perform Dependency Trace  |       | Audit Registry Signatures |
         | (Transitive vs Direct)    |       | & Cosign Attestations     |
         +---------------------------+       +---------------------------+
                       |                                   |
                       +-----------------+-----------------+
                                         |
                                         v
                         +-------------------------------+
                         | Apply Remediation Decision    |
                         | (Replace/Isolate/Dual License)|
                         +-------------------------------+
```

### 5.2 Common Production Failures & SRE Troubleshooting Matrix

#### Failure Scenario 1: Transitive Copyleft Contagion (AGPL/GPL Leakage)
* **Symptom**: Build pipeline fails at security gate with `Exit Code 1`. Trivy flags a sub-dependency buried deep in `node_modules` or `go.mod` (e.g., `github.com/marten-seemann/qtls-go1-19` licensed under BSD, but bringing in a GPL helper module).
* **Diagnostic Command**:
  ```bash
  $ go mod why -m <dependency_name>
  # For Node.js platforms:
  $ npm ls <package-name>
  ```
* **Remediation**:
  1. Replace the upstream library with a permissively licensed alternative (e.g., MIT/Apache 2.0).
  2. If the dependency is strictly required, isolate the component into a separate microservice bounded by an HTTP/gRPC network barrier (preventing in-process dynamic/static linking legal contagion).

#### Failure Scenario 2: Sudden Upstream License Relicensing (BSL / SSPL Shift)
* **Symptom**: Security scanner triggers alerts on base infrastructure components after automated patch updates (e.g., pulling latest image versions of enterprise stateful engines).
* **Diagnostic Command**:
  ```bash
  $ syft diff registry:myrepo/engine:v1.0.0 registry:myrepo/engine:v2.0.0
  ```
* **Remediation**:
  1. Pin infrastructure images to the last known permissive version (e.g., Terraform `1.5.7`, Redis `7.2.4` pre-relicense build).
  2. Migrate platform infrastructure to community-backed Linux Foundation / CNCF forks (e.g., migrate from Terraform to OpenTofu; migrate from Redis to Valkey).

#### Failure Scenario 3: Missing Dual-Licensing Entitlement Key in Open Core Stack
* **Symptom**: Production pods crash-loop with `Error: Enterprise Feature Requested (SSO/RBAC) but no valid license key found`.
* **Diagnostic Command**:
  ```bash
  $ kubectl logs -n platform deployment/identity-service --tail=100 | grep -i "license"
  ```
* **Remediation**:
  1. Verify Kubernetes `Secret` mounting the commercial entitlement key string.
  2. Inspect key expiration metadata via CLI tool or API endpoint exposed by vendor runtime.

---

## 6. References

* **LPI Open Source Essentials Overview**:  
  https://www.lpi.org/our-certifications/open-source-essentials-overview/
* **Open Source Initiative (OSI) Licenses & Standards**:  
  https://opensource.org/licenses
* **Linux Foundation Software Supply Chain Security & SPDX Specification**:  
  https://spdx.dev/
* **CNCF Software Supply Chain Best Practices**:  
  https://github.com/cncf/tag-security/tree/main/supply-chain-security
* **Kyverno Cluster Policy Manual & Software Compliance**:  
  https://kyverno.io/docs/policies/
* **Anchore Syft SBOM Specification**:  
  https://github.com/anchore/syft
* **Aqua Security Trivy Vulnerability & License Scanner**:  
  https://aquasecurity.github.trivy.dev/

---

### End of Study Guide — LPI 050-100 Topic 4.1