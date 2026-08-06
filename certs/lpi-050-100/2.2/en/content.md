# LPI Open Source Essentials (Exam 050-100) — Topic 2.2: Copyleft Software Licenses

**Target Audience:** Principal Platform Architects, Senior SREs, DevSecOps Engineers, and Cloud-Native Security Practitioners  
**Exam Weight:** 7.5  
**Domain Focus:** Open Source Licensing Governance, Copyleft Mechanics, Software Supply Chain Security, and Enterprise Architecture Compliance  

---

## 1. Motivation & Production Architectural Problem

### 1.1 The Enterprise Software Supply Chain Dilemma
In modern cloud-native platform engineering, over 80% of a containerized application's codebase consists of open-source software (OSS) transitive dependencies, runtime libraries, sidecars, and OS base image packages. While open-source adoption accelerates delivery velocity, it introduces binding legal obligations governed by software licenses.

Software licenses operate under copyright law. When software is distributed or made accessible over a network, the recipient receives specific rights (use, modify, redistribute) contingent upon complying with the license terms. Failing to comply results in copyright infringement, exposing enterprises to legal liability, injunctions to halt product distribution, mandatory source code disclosure, and severe financial damages.

```
+-----------------------------------------------------------------------------------+
|                            ENTERPRISE APP DEPLOYMENT                              |
+-----------------------------------------------------------------------------------+
|  +--------------------------+  +----------------------+  +---------------------+  |
|  | Proprietary Core Logic   |  | Permissive Libs      |  | Weak Copyleft Libs  |  |
|  | (Closed Source / IP)     |  | (MIT, Apache-2.0)    |  | (LGPLv3, MPL-2.0)   |  |
|  +-------------+------------+  +----------+-----------+  +----------+----------+  |
|                |                          |                         |             |
|                +--------------------------+-------------------------+             |
|                                           |                                       |
|                                           v                                       |
|                  +-------------------------------------------------+              |
|                  | LINKING / IPC / IN-PROCESS COMPILATION          |              |
|                  +------------------------+------------------------+              |
|                                           |                                       |
|                                           v                                       |
|                  +-------------------------------------------------+              |
|                  |  CRITICAL INFECTION RISK (Strong / Network)     |              |
|                  |  - GPL-3.0-or-later (Static / Dynamic Link)     |              |
|                  |  - AGPL-3.0-only   (Network Access Trigger)   |              |
|                  +------------------------+------------------------+              |
+-------------------------------------------|---------------------------------------+
                                            v
               +--------------------------------------------------------+
               | IMPLICATION: Legal requirement to release entire core   |
               | business logic under copyleft license or face lawsuit. |
               +--------------------------------------------------------+
```

### 1.2 Copyleft Mechanics & The "Reciprocity" Engine
Copyleft is a legal mechanism that uses copyright law to keep software free and open. Unlike *permissive* licenses (which allow downstream users to relicense modified code under closed/proprietary terms), *copyleft* licenses require that any derivative work or modified version distributed to others must be released under the **same copyleft license**.

Key technical mechanisms include:
*   **Reciprocity (The "Viral" Clause):** If Component $A$ (Copyleft) is bundled or combined with Component $B$ (Proprietary) such that $A+B$ forms a single derivative work, the entire combined work ($A+B$) must be released under Component $A$'s license upon distribution.
*   **Source Code Redistribution Trigger:** Downstream users must be provided with complete, corresponding source code, including build scripts, configuration flags, and installation instructions.
*   **Anti-SaaS Loophole (Network Copyleft):** Standard copyleft (GPL) triggers compliance obligations upon *distribution* (binaries shipped to a customer). Cloud-native platforms operating as Software-as-a-Service (SaaS) do not "distribute" binaries; execution occurs on cloud infrastructure. Network Copyleft (AGPL/SSPL) re-defines the trigger to include interaction over a computer network.

### 1.3 Architectural Impact on SRE & Platform Engineering
Platform teams building internal developer platforms (IDPs), microservice meshes, and CI/CD pipelines must enforce automated governance gates. An unvetted `npm install`, `go get`, or container base image inclusion containing a Strong or Network Copyleft license can compromise proprietary enterprise intellectual property (IP).

Key SRE concerns:
1.  **Static vs. Dynamic Linking:** Static linking merges machine code into a single executable binary, unequivocally creating a derivative work under GPL. Dynamic linking (`.so`, `.dll`) binds shared libraries at runtime; standard GPL considers dynamically linked binaries as derivative works, whereas LGPL explicitly allows dynamic linking with proprietary code.
2.  **Process Boundaries vs. Shared Memory:** Microservices communicating via network RPCs (gRPC, REST, JSON-HTTP) across network sockets are generally isolated from standard GPL reciprocity. However, sharing in-memory data structures, IPC UNIX domain sockets with tight binding, or shared memory segments can trigger legal derivative-work arguments.
3.  **Tivoization & Hardware Lock-In:** GPLv3 specifically forbids "Tivoization"—shipping copyleft software on hardware devices that restrict users from running modified versions of the software via cryptographic signature verification.

---

## 2. Technical Comparison & Trade-off Matrix

The following matrix contrasts open-source licensing categories across key technical dimensions:

| License Family | Example Licenses | Derivative Work Trigger | Source Code Release Scope | Patent Rights Clause | Tivoization Protection | SaaS / Cloud Network Trigger | Enterprise SRE Risk Level |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Strong Copyleft** | GPL-2.0-only, GPL-3.0-or-later | Static & Dynamic linking, in-process compilation | Complete program + build tools + scripts | Explicit in v3; implicit/unclear in v2 | Protected in v3 (Section 6); None in v2 | **No** (Requires binary distribution) | **CRITICAL** for internal proprietary code |
| **Weak Copyleft** | LGPL-2.1-only, LGPL-3.0-only, MPL-2.0 | File-level modification (MPL); Static link without relinking mechanism (LGPL) | Modified library files / Object files for relinking | Explicit in LGPLv3 / MPL-2.0 | Protected in LGPLv3 | **No** | **MEDIUM** (Requires dynamic linking hygiene) |
| **Network Copyleft** | AGPL-3.0-only, EUPL-1.2 | Network access, API calls, remote interaction | Full application + network service modifications | Explicit | Protected | **YES** (Interacting over network triggers release) | **MAXIMUM** for SaaS & Hosted Platforms |
| **Permissive** | MIT, Apache-2.0, BSD-3-Clause | Sublicensing allowed; no reciprocal copyleft requirement | None required (Notice retention only) | Explicit patent grant in Apache-2.0 | None | **No** | **LOW** (Safe for enterprise adoption) |
| **Source Available** *(Non-OSI)* | SSPL-1.0, BSL-1.1 | Providing the software as a commercial managed cloud service | Entire management infrastructure stack (SSPL) | Varies per vendor | N/A | **YES** (Strict commercial hosting restriction) | **HIGH / PROPRIETARY** (Vendor lock-in risk) |

---

## 3. Production Infrastructure & Policy Manifests

To protect production platforms against unauthorized copyleft exposure, platform teams deploy automated policy enforcement using Open Policy Agent (OPA) Gatekeeper, Kyverno, and container image SBOM scanning jobs within Kubernetes.

### 3.1 OPA Gatekeeper Policy: Restrict Images Containing AGPL/GPL Packages

The following complete, syntactically valid Kubernetes `ConstraintTemplate` and `Constraint` inspect deployment annotations containing Software Bill of Materials (SBOM) SPDX metadata and deny pods containing banned copyleft licenses (`AGPL-3.0-only`, `GPL-3.0-or-later`).

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sdisallowcopyleftlicenses
  annotations:
    description: >-
      Enforces software supply chain license compliance by blocking container images
      annotated with restricted Copyleft (GPL/AGPL) SPDX license identifiers.
spec:
  crd:
    spec:
      names:
        kind: K8sDisallowCopyleftLicenses
      validation:
        openAPIV3Schema:
          type: object
          properties:
            bannedLicenses:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8sdisallowcopyleftlicenses

        violation[{"msg": msg}] {
          container := input.review.object.spec.template.spec.containers[_]
          sbom_license := input.review.object.metadata.annotations[sprintf("sbom.spdx.org/license-%s", [container.name])]
          banned := input.parameters.bannedLicenses[_]
          contains(lower(sbom_license), lower(banned))
          msg := sprintf("CONTAINER REJECTED: Container '%s' in Pod '%s' uses restricted Copyleft license '%s' (Banned policy match: '%s')", [container.name, input.review.object.metadata.name, sbom_license, banned])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.template.spec.containers[_]
          not input.review.object.metadata.annotations[sprintf("sbom.spdx.org/license-%s", [container.name])]
          msg := sprintf("CONTAINER REJECTED: Container '%s' in Pod '%s' lacks mandatory SPDX license annotation 'sbom.spdx.org/license-%s'", [container.name, input.review.object.metadata.name, container.name])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sDisallowCopyleftLicenses
metadata:
  name: enforce-no-agpl-gpl-in-prod
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment", "StatefulSet"]
    namespaces:
      - "production"
      - "payments-service"
  parameters:
    bannedLicenses:
      - "AGPL-3.0-only"
      - "AGPL-3.0-or-later"
      - "GPL-3.0-only"
      - "GPL-3.0-or-later"
      - "SSPL-1.0"
```

### 3.2 Kyverno ClusterPolicy: Verify Image SBOM & Enforce License Attestation

This Kyverno `ClusterPolicy` validates that images deployed to production have passed license compliance verification through attestations signed by Cosign/In-Toto.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: audit-and-enforce-license-compliance
  annotations:
    policies.kyverno.io/title: Enforce Signed License Attestation
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, ImageAttestation
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-license-attestation
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - production
      verifyImages:
        - imageReferences:
            - "cr.enterprise.internal/apps/*"
          key: |
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N1a/j5+6z1j/QnJ6eY6N+wV7vM9
            5gL4W1pDkFzX0bQ4fH9Y8uKz3Z9xW7vM95gL4W1pDkFzX0bQ4fH9Y8uKz3Z==
            -----END PUBLIC KEY-----
          attestations:
            - predicateType: https://spdx.dev/Document
              attestors:
                - entries:
                    - keys:
                        publicKeys: |
                          -----BEGIN PUBLIC KEY-----
                          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N1a/j5+6z1j/QnJ6eY6N+wV7vM9
                          5gL4W1pDkFzX0bQ4fH9Y8uKz3Z9xW7vM95gL4W1pDkFzX0bQ4fH9Y8uKz3Z==
                          -----END PUBLIC KEY-----
              conditions:
                - all:
                    - key: "{{ request.object.spec.containers[*].image }}"
                      operator: Defined
```

### 3.3 Automated Kubernetes CI/CD SBOM & License Scanner Job

This complete, production-grade Kubernetes `Job` runs Anchore Syft and Trivy within a CI pipeline runner to generate an SPDX 2.3 JSON report, evaluate it against license policies, and emit compliance metrics.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: license-compliance-audit-job
  namespace: cicd-runners
spec:
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: license-auditor
    spec:
      restartPolicy: Never
      containers:
        - name: sbom-generator-syft
          image: docker.io/anchore/syft:v1.3.0
          command:
            - "/syft"
          args:
            - "packages"
            - "registry.internal.net/payment/processor:v3.1.0"
            - "-o"
            - "spdx-json=/workspace/sbom.spdx.json"
          volumeMounts:
            - name: shared-workspace
              mountPath: /workspace
            - name: docker-config
              mountPath: /root/.docker/config.json
              subPath: config.json

        - name: license-policy-checker
          image: aquasec/trivy:0.50.1
          command:
            - "trivy"
          args:
            - "sbom"
            - "/workspace/sbom.spdx.json"
            - "--scanners"
            - "license"
            - "--severity"
            - "HIGH,CRITICAL"
            - "--exit-code"
            - "1"
            - "--ignored-licenses"
            - "MIT,Apache-2.0,BSD-2-Clause,BSD-3-Clause,MPL-2.0,LGPL-3.0-only"
          volumeMounts:
            - name: shared-workspace
              mountPath: /workspace

      volumes:
        - name: shared-workspace
          emptyDir: {}
        - name: docker-config
          secret:
            secretName: internal-registry-creds
```

---

## 4. Real-World CLI Commands & Terminal Outputs ($)

Hands-on commands for platform architects and SREs to inspect binaries, repos, and container images for license compliance.

### 4.1 Generating SPDX 2.3 SBOM with Syft
Generate a complete Software Bill of Materials (SBOM) in SPDX format for a production container image:

```bash
$ syft registry.internal.net/finance/billing-service:v1.4.2 -o spdx-json=billing-sbom.spdx.json
```

**Expected Output:**
```
[0000]  INFO Parsing image "registry.internal.net/finance/billing-service:v1.4.2"
[0002]  INFO Cataloging packages 
[0004]  INFO PyPI: 42 packages discovered
[0005]  INFO Go Module: 128 packages discovered
[0006]  INFO dpkg: 112 packages discovered
[0007]  INFO Finalizing SBOM report...
 ✔ Cataloged packages      [282 packages]
 ✔ Created SPDX JSON document -> billing-sbom.spdx.json
```

### 4.2 Querying License Metadata via `jq` Filter
Extract all packages identified with GPL or AGPL licenses from the SPDX document:

```bash
$ jq '.packages[] | select(.licenseConcluded | test("GPL|AGPL")) | {name: .name, versionInfo: .versionInfo, licenseConcluded: .licenseConcluded}' billing-sbom.spdx.json
```

**Expected Output:**
```json
{
  "name": "github.com/mewmew/goplugin",
  "versionInfo": "v1.2.0",
  "licenseConcluded": "GPL-3.0-only"
}
{
  "name": "github.com/db-driver/agpl-connector",
  "versionInfo": "v0.9.4",
  "licenseConcluded": "AGPL-3.0-or-later"
}
```

### 4.3 License Enforcement with Trivy CLI
Run an automated license compliance scan against an OCI container image with non-zero exit code on violation:

```bash
$ trivy image --scanners license --license-full --severity CRITICAL --exit-code 1 registry.internal.net/finance/billing-service:v1.4.2
```

**Expected Output (Violation Detected):**
```
2026-08-06T19:12:04.112Z	INFO	License scanning enabled
2026-08-06T19:12:05.421Z	INFO	Detected OS: alpine 3.19.1
2026-08-06T19:12:06.890Z	INFO	Number of language-specific files: 2

billing-service:v1.4.2 (gobinary)
==================================
Total: 2 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 2)

CRITICAL: AGPL-3.0-only
────────────────────────────────────────────────────────────────────────────────
PkgName: github.com/db-driver/agpl-connector
Category: Network Copyleft
Classification: Restricted for Commercial Hosted SaaS
File: /usr/local/bin/billing-service

CRITICAL: GPL-3.0-only
────────────────────────────────────────────────────────────────────────────────
PkgName: github.com/mewmew/goplugin
Category: Strong Copyleft
Classification: Forbidden in Proprietary Compiled Executable
File: /usr/local/bin/billing-service

Error: License compliance check failed. Exited with code 1.
```

### 4.4 In-Repo Go License Compliance Check using `golicense`
Run `golicense` against a compiled Go binary to verify compiled-in module licenses:

```bash
$ golicense -config .license-policy.hcl ./bin/payment-gateway
```

**Content of `.license-policy.hcl`:**
```hcl
allow = [
  "MIT",
  "Apache-2.0",
  "BSD-3-Clause",
  "MPL-2.0"
]

deny = [
  "GPL-2.0-only",
  "GPL-3.0-only",
  "AGPL-3.0-only"
]
```

**Expected Output:**
```
Loading binary...
Analyzing dependency graph (142 modules)...

[FAIL] Forbidden license detected!
  Module: github.com/gorilla/gpl-component
  License: GPL-2.0-only
  Path: main -> github.com/enterprise/core -> github.com/gorilla/gpl-component

Summary: 141 Allowed, 1 Denied, 0 Unspecified.
Process terminated with status code 1.
```

---

## 5. Verification & Diagnostic Troubleshooting Guide

When a build fails or a legal audit flags a copyleft license violation in production, platform SREs must follow a systematic diagnostic and remediation workflow.

```
+-----------------------------------------------------------------------------------+
|                        COPYLEFT VIOLATION DIAGNOSTIC FLOW                         |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [ CI/CD Gate / Security Alert ] --> Copyleft Violation Detected                  |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 1: Identification ] --------> Trace Package via Dependency Tree           |
|                                       (e.g., `go mod why`, `npm ls`)              |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 2: Linkage Analysis ] ------> Determine Binding Mode                      |
|                                       - Direct Static In-Process Compile?         |
|                                       - Dynamic Shared Library (.so)?             |
|                                       - Separate Process IPC / gRPC?              |
|                                            |                                      |
|                                            +-------------------+                  |
|                                            |                   |                  |
|                                  Direct / In-Process      Process Boundary        |
|                                            | (GPL Reciprocity) | (No Reciprocity) |
|                                            v                   v                  |
|  [ STEP 3: Action Path ] ---------> [ REFACTOR TO RPC ]   [ DOCUMENT ISOLATION ]  |
|                                       or REPLACE LIB       Create Architecture     |
|                                                            Compliance Record      |
|                                            |                                      |
|                                            v                                      |
|  [ STEP 4: Verification ] ---------> Re-generate SBOM & Re-run Trivy/Syft Gate     |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### 5.1 Root Cause Isolation: Dependency Tree Tracing

#### Scenario A: Go Module Ingestion
A developer imported `github.com/some/helper` which transitively imports a GPL-3.0 library.

```bash
# Trace why the GPL package is in the build graph
$ go mod why github.com/mewmew/goplugin

# Output:
# # github.com/mewmew/goplugin
# main.val
# github.com/enterprise/core/pkg/processor
# github.com/mewmew/goplugin
```

#### Scenario B: Node.js / NPM Transitive Dependency
```bash
# Locate AGPL package in NPM tree
$ npm ls agpl-connector --all

# Output:
# payment-ui@2.1.0 /home/sre/src/payment-ui
# └─┬ analytics-tracker@1.0.4
#   └── agpl-connector@0.9.4
```

### 5.2 Architectural Isolation Patterns

If replacing the copyleft package is technically impossible or cost-prohibitive, SREs and Architects must decouple the software across legal boundaries:

#### Pattern 1: Microservice Network Boundary Isolation (gRPC / REST Sidecar)
*   **Problem:** Using a GPL-licensed graph calculation C++ library inside a proprietary Go billing engine directly via CGO creates a single combined binary (GPL violation).
*   **Remediation:** Wrap the C++ GPL library inside a standalone containerized daemon that exposes a gRPC API interface.

```
BEFORE (NON-COMPLIANT):
+-----------------------------------------------------------------+
| PROPRIETARY GO BINARY (In-Process CGO Calls)                    |
|  [ Go Core Code ] <---> [ GPL C++ Library ]  <-- INFECTION RISK |
+-----------------------------------------------------------------+

AFTER (COMPLIANT ARCHITECTURE):
+-----------------------------+          +----------------------------------+
| PROPRIETARY SERVICE         |  gRPC    | STANDALONE GPL DAEMON CONTAINER  |
| [ Go Core Code ]            | -------- | [ gRPC Server (GPL Wrappers) ]   |
| (Proprietary / Closed)      |  over    | [ GPL C++ Library ]              |
|                             |  TCP     | (Source Released on Request)     |
+-----------------------------+          +----------------------------------+
```

*   **Legal Rationale:** Processes communicating over standard network socket IPC (gRPC/HTTP) are separate programs under FSF GPL enforcement guidelines. Reciprocity does not cross network socket process boundaries for standard GPLv2/GPLv3 (Note: AGPL does cross network boundaries if network interaction is provided).

#### Pattern 2: Clean-Room Dual License Negotiation
For critical dependencies where RPC isolation introduces unacceptable latency:
1.  Contact copyright holder for a **Commercial Dual License** (paying a fee to receive code under non-copyleft terms).
2.  Perform a **Clean-Room Reimplementation**: Developer Group A writes functional specifications without looking at copyleft code; Developer Group B implements code strictly from specification.

### 5.3 Automated Audit & Verification Workflow

Verify remediation success before merging pull requests:

```bash
# Step 1: Clean build environment & purge cache
$ go clean -modcache
$ npm cache clean --force

# Step 2: Re-generate fresh SBOM
$ syft dir:. -o spdx-json=remediation-check.spdx.json

# Step 3: Run Policy Engine Check
$ trivy sbom remediation-check.spdx.json --scanners license --severity CRITICAL --exit-code 1

# Expected Output upon successful isolation:
# 2026-08-06T19:25:00.000Z INFO License scan passed cleanly. 0 CRITICAL violations found.
```

---

## 6. Referencias

*   **LPI Open Source Essentials Official Overview:**  
    [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
*   **GNU Project — Frequently Asked Questions about the GNU Licenses:**  
    [https://www.gnu.org/licenses/gpl-faq.html](https://www.gnu.org/licenses/gpl-faq.html)
*   **Open Source Initiative (OSI) Licenses & Standards:**  
    [https://opensource.org/licenses](https://opensource.org/licenses)
*   **Software Package Data Exchange (SPDX) Specification & License List:**  
    [https://spdx.org/licenses/](https://spdx.org/licenses/)  
    [https://spdx.dev/](https://spdx.dev/)
*   **CNCF Software Supply Chain Best Practices:**  
    [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/gaps-and-future-trends.md](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/gaps-and-future-trends.md)
*   **Open Policy Agent (OPA) Gatekeeper:**  
    [https://open-policy-agent.github.io/gatekeeper/website/docs/](https://open-policy-agent.github.io/gatekeeper/website/docs/)
*   **Anchore Syft SBOM Tool:**  
    [https://github.com/anchore/syft](https://github.com/anchore/syft)
*   **Aqua Security Trivy Scanner:**  
    [https://aquasecurity.github.io/trivy/](https://aquasecurity.github.io/trivy/)