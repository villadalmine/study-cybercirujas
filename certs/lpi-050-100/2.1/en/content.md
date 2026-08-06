# LPI 050-100 Study Guide — Topic 2.1: Concepts of Open Source Software Licenses

**Target Certification:** LPI Open Source Essentials (Exam 050-100)  
**Topic:** 2.1 Concepts of Open Source Software Licenses (Weight: 7.5)  
**Target Audience:** SREs, Platform Architects, and Cloud Native Security Engineers  

---

## 1. Production Architectural Motivation & Legal Risk Engineering

### The Production Problem: Supply Chain Contamination & Copyleft Infection
In cloud-native enterprise environments, modern software architectures heavily rely on containerization, dynamic dependency trees, and open-source software (OSS) components. A single container image in a production Kubernetes cluster often contains hundreds of OS-level packages (e.g., `apt`, `apk`) and language runtime dependencies (e.g., `npm`, `Go modules`, `PyPI`).

Without automated governance, software supply chains face severe legal and operational risks:
1. **Copyleft Contamination (Viral Effect):** Including a library licensed under a strong copyleft license (e.g., GNU General Public License v3 / GPL-3.0) inside a proprietary codebase or linking against it dynamically/statically can legally mandate that the *entire enterprise application* be re-licensed and publicly distributed under the GPL-3.0.
2. **Network Copyleft Triggers (SaaS Leakage):** Under the GNU Affero General Public License v3 (AGPL-3.0), interacting with software over a network (e.g., via REST API, gRPC, or microservice RPC) without physical distribution still triggers the copyleft requirement. Hosting an unmodified or modified AGPL component as a backend microservice obligates the operator to make the complete source code of the interacting service accessible to all network users.
3. **Patent Retaliation Risk:** Permissive licenses without explicit patent grants (such as early BSD licenses or MIT) leave enterprises vulnerable to patent infringement claims by upstream contributors. Conversely, modern licenses with explicit patent termination clauses (e.g., Apache-2.0 section 3) automatically void license rights if a licensee files a patent lawsuit against the project.

```
+-----------------------------------------------------------------------------------+
|                        ENTERPRISE MICROSERVICE ARCHITECTURE                        |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  +--------------------------+          +---------------------------------------+  |
|  | Proprietary App Service  |  gRPC    | AGPL-3.0 Microservice (e.g., DB/Cache)|  |
|  | (Closed-Source Binary)   |--------->| (Triggers source code release request |  |
|  +------------+-------------+          |  to all end-users via Network Clause) |  |
|               |                        +---------------------------------------+  |
|               | Dynamic Linking                                                   |
|               v                                                                   |
|  +--------------------------+          +---------------------------------------+  |
|  | GPL-3.0 Shared Library   |          | Apache-2.0 / MIT Component            |  |
|  | (Triggers Copyleft for   |          | (Permissive: Requires Notice/Attrib)  |  |
|  |  entire host binary)     |          +---------------------------------------+  |
|  +--------------------------+                                                     |
+-----------------------------------------------------------------------------------+
```

### Intellectual Property Primitives: Copyright as the Enforcement Mechanism
All open-source licenses derive their legal enforceability from **Copyright Law** (e.g., Title 17 of the U.S. Code, Bern Convention). Under copyright law:
* **Default Rights:** The creator of a software work holds exclusive rights to copy, modify, distribute, perform, and display the code. Without an explicit grant of rights, all usage by third parties constitutes **copyright infringement**.
* **The Role of the License:** An open-source license is a legal contract/grant wherein the copyright holder relinquishes certain exclusive rights to the public, subject to specific **conditions** and **obligations**.
* **Conditions vs. Covenants:** Compliance obligations (e.g., preserving `LICENSE` files, disclosing source code) operate as conditions precedent to the copyright grant. If an SRE deploys software in violation of these conditions, the license grant automatically terminates, transforming the operational deployment into active copyright infringement.

### Institutional Frameworks: OSI OSD vs. FSF Four Freedoms

Platform architects must differentiate between the governance frameworks defined by the **Open Source Initiative (OSI)** and the **Free Software Foundation (FSF)**.

```
                     +---------------------------------------+
                     |         SOFTWARE FREEDOM SPACE        |
                     |                                       |
                     |   +-------------------------------+   |
                     |   |    FSF "Free Software"        |   |
                     |   |  Focus: Ethical User Liberty  |   |
                     |   |    (Four Essential Freedoms)  |   |
                     |   +---------------+---------------+   |
                     |                   |                   |
                     |                   | Intersection      |
                     |                   v                   |
                     |   +---------------+---------------+   |
                     |   |    OSI "Open Source"          |   |
                     |   |  Focus: Pragmatic Legal &     |   |
                     |   |  Development Methodology (OSD)|   |
                     |   +-------------------------------+   |
                     +---------------------------------------+
```

#### 1. FSF Four Essential Freedoms
The FSF focuses on user autonomy and ethical software distribution:
* **Freedom 0:** The freedom to run the program for any purpose.
* **Freedom 1:** The freedom to study how the program works, and change it so it does your computing as you wish (access to source code is a precondition).
* **Freedom 2:** The freedom to redistribute copies so you can help your neighbor.
* **Freedom 3:** The freedom to distribute copies of your modified versions to others (access to source code is a precondition).

#### 2. OSI Open Source Definition (OSD)
The OSI maintains a 10-point checklist ensuring software meets commercial and operational standards:
1. **Free Redistribution:** No restrictions on selling or giving away the software.
2. **Source Code:** Unobfuscated source code must be distributed or explicitly made available.
3. **Derived Works:** Modifications and derived works must be permitted under the same terms.
4. **Integrity of the Author's Source Code:** Patch files may be required, but execution must not be restricted.
5. **No Discrimination Against Persons or Groups:** Universal access guarantees.
6. **No Discrimination Against Fields of Endeavor:** Cannot restrict usage in commercial, military, or research environments.
7. **Distribution of License:** Rights apply to all downstream recipients without additional contracts.
8. **License Must Not Be Specific to a Product:** License cannot depend on inclusion in a specific distribution.
9. **License Must Not Restrict Other Software:** Cannot demand that aggregated software on the same media be open source.
10. **License Must Be Technology-Neutral:** Cannot require interface-specific assent (e.g., click-through contracts).

---

## 2. Technical Taxonomy & Trade-off Matrix

### Architectural Comparison Matrix

| License Category | Representative SPDX IDs | Reciprocal Source Disclosure (Copyleft) | Patent Grant / Protection | Commercial SaaS Exemption | Linking Boundary Isolates Copyleft? |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Permissive** | `MIT`, `BSD-3-Clause`, `Apache-2.0` | None | `Apache-2.0` (Yes, Sec 3); `MIT`/`BSD` (No explicit grant) | Yes | Yes (No copyleft exists) |
| **Weak Copyleft** | `LGPL-3.0-only`, `MPL-2.0`, `EPL-2.0` | Limited to modified files or direct library code | `LGPL-3.0` (Yes); `MPL-2.0` (Yes) | Yes (If unmodified library call) | Yes (Dynamic linking or file-level isolation protects host) |
| **Strong Copyleft** | `GPL-2.0-only`, `GPL-3.0-only` | Full (All derivative works & linked binaries) | `GPL-3.0` (Yes); `GPL-2.0` (Implicit/Unclear) | Yes (If hosted via network API without binary distribution) | No (Static and dynamic linking infects host application) |
| **Network Copyleft** | `AGPL-3.0-only` | Full (Includes remote network interactions) | Yes (Clause via GPLv3 base) | **NO** (Triggers on API / SaaS consumption) | No (IPC/Network boundary does **not** protect host from disclosure) |
| **Source-Available / Business** | `SSPL-1.0`, `BSL-1.1` | Extreme (Requires management infrastructure code) | Varies | **NO** (Explicitly bans competitive cloud offerings) | Not OSI approved; license triggers under cloud deployment |

---

### In-Depth Deep Dives on License Mechanisms

```
+---------------------------------------------------------------------------------------+
|                              COPYLEFT EXTENSION BOUNDARIES                             |
+---------------------------------------------------------------------------------------+
|                                                                                       |
|  PERMISSIVE (MIT/Apache):                                                             |
|  [ Your Proprietary Code ] ===(Imports/Links)===> [ MIT Code ]                        |
|  Result: Entire binary remains Proprietary.                                           |
|                                                                                       |
|  WEAK COPYLEFT (LGPL/MPL):                                                            |
|  [ Your Proprietary Code ] ---(Dynamic Link/Header)---> [ LGPL Library ]              |
|  Result: Your code remains Proprietary. Modifications to LGPL Library MUST be shared. |
|                                                                                       |
|  STRONG COPYLEFT (GPL):                                                               |
|  [ Your Proprietary Code ] ===(Static/Dynamic Link)===> [ GPL Library ]               |
|  Result: Entire binary MUST be licensed under GPL and source code disclosed.          |
|                                                                                       |
|  NETWORK COPYLEFT (AGPL):                                                             |
|  [ Your App Front-End ] -----(gRPC / REST API)-----> [ AGPL Backend Service ]         |
|  Result: Entire App Front-End source code MUST be released to end-users.              |
+---------------------------------------------------------------------------------------+
```

#### 1. Apache License 2.0 (`Apache-2.0`)
* **Mechanism:** Permissive license with strong corporate protection primitives.
* **Patent Protection:** Contains an explicit grant of patent rights from every contributor to the user. Section 3 includes a **Retaliatory Patent Clause**: if an entity initiates patent litigation against any contributor alleging that the work constitutes patent infringement, all patent licenses granted under `Apache-2.0` for that work terminate immediately.
* **State Changes:** Section 4(b) requires modified files to carry prominent notices stating that the code was changed.

#### 2. GNU General Public License v3 (`GPL-3.0-only`)
* **Mechanism:** Strong Copyleft requiring complete derivative work re-licensing.
* **Tivoization Clause (Section 6):** Enacted to prevent hardware vendors from running GPLv3 software on embedded systems that enforce signature checks to block modified software (a practice named after TiVo). Requires providing complete Installation Information (keys, signatures) alongside source code.
* **Patent Termination (Section 11):** Assures downstream users that upstream distributors who convey GPLv3 code automatically grant licenses to any patents they hold covering the software.

#### 3. GNU Affero General Public License v3 (`AGPL-3.0-only`)
* **Mechanism:** Strong Network Copyleft designed specifically for SaaS platforms.
* **Section 13 (Remote Network Interaction):** Closing the "SaaS loophole" of GPLv3. If a modified version of AGPL-3.0 software runs on a server and interacts with users remotely over a computer network, the operator **must** offer those users access to the corresponding source code over the network without charge (typically via a prominent `Download Source` link in the UI or API endpoint).

#### 4. Source-Available / Non-OSI Licenses (`SSPL-1.0`, `BSL-1.1`)
* **Server Side Public License (SSPL-1.0):** Created by MongoDB. Extends AGPL-3.0 Section 13 such that if an entity offers the software as a commercial service, it must release the source code of **all** management software, automation scripts, backup software, storage layers, and monitoring tools used to run the service. **Not approved by OSI** because it violates OSD Criterion 1 (Free Redistribution) and Criterion 6 (Field of Endeavor).
* **Business Source License (BSL-1.1 / BUSL):** Used by HashiCorp (Terraform, Vault) and CockroachDB. Grants rights to copy, modify, and redistribute, but prohibits use in production for specified commercial micro-use cases (e.g., managed service platforms) for a set time (Change Date, max 4 years), after which it automatically converts to an OSI-approved license (e.g., Apache-2.0 or GPL-2.0). **Not an open-source license during the initial licensed period.**

---

## 3. Complete Production Manifests & Pipeline Infrastructure

### A. Automated CI/CD Compliance Pipeline
File: `.github/workflows/license-compliance-sbom.yml`

```yaml
name: Production FOSS License Compliance and SBOM Generation

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

permissions:
  contents: read
  pull-requests: write
  security-events: write

jobs:
  license-compliance:
    name: Audit FOSS Licenses & Generate SPDX SBOM
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Go Environment
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Install Compliance CLI Tools
        run: |
          set -euo pipefail
          echo "=== Installing Syft (SBOM Generator) ==="
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v1.3.0
          
          echo "=== Installing Trivy (License Scanner) ==="
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin v0.50.1
          
          echo "=== Installing REUSE (Header Auditor) ==="
          python3 -m pip install --no-cache-dir reuse==3.0.2
          
          syft --version
          trivy --version
          reuse --version

      - name: Audit File Header License Compliance (REUSE Standard)
        run: |
          set -euo pipefail
          echo "=== Checking REUSE Specification Compliance ==="
          reuse lint

      - name: Generate Machine-Readable SPDX v2.3 SBOM
        run: |
          set -euo pipefail
          echo "=== Generating SPDX JSON SBOM for Workspace ==="
          syft dir:. --output spdx-json=sbom.spdx.json

      - name: Enforce Policy Gates via Trivy License Scanning
        run: |
          set -euo pipefail
          echo "=== Executing License Enforcement Scan ==="
          # Severities mapped to prohibited license categories:
          # AGPL-3.0, SSPL-1.0, BSL-1.1 generate CRITICAL violations.
          # GPL-3.0, LGPL-3.0 generate HIGH violations.
          trivy fs \
            --security-checks license \
            --severity HIGH,CRITICAL \
            --exit-code 1 \
            --format table \
            .

      - name: Upload SPDX SBOM Artifact
        uses: actions/upload-artifact@v4
        with:
          name: sbom-spdx-json
          path: sbom.spdx.json
          retention-days: 90
```

---

### B. Valid SPDX v2.3 JSON Software Bill of Materials (SBOM)
File: `sbom.spdx.json`

```json
{
  "SPDXID": "SPDXRef-DOCUMENT",
  "spdxVersion": "SPDX-2.3",
  "creationInfo": {
    "created": "2026-08-06T19:00:00Z",
    "creators": [
      "Organization: Enterprise Platform Architecture Team",
      "Tool: Anchore Syft-v1.3.0"
    ],
    "licenseListVersion": "3.23"
  },
  "name": "payment-gateway-service-container",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://spdx.org/spdxdocs/payment-gateway-service-v1.4.2-7a8f9e0d-8c4b",
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-ContainerImage-payment-gateway",
      "name": "payment-gateway-service",
      "versionInfo": "v1.4.2",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright 2026 Enterprise Financial Corp",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:oci/payment-gateway-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-GoModule-gin-gonic",
      "name": "github.com/gin-gonic/gin",
      "versionInfo": "v1.9.1",
      "downloadLocation": "https://github.com/gin-gonic/gin",
      "filesAnalyzed": false,
      "licenseConcluded": "MIT",
      "licenseDeclared": "MIT",
      "copyrightText": "Copyright (c) 2014 Manuel Martinez-Almeida",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:golang/github.com/gin-gonic/gin@v1.9.1"
        }
      ]
    },
    {
      "SPDXID": "SPDXRef-Package-Debian-libc6",
      "name": "libc6",
      "versionInfo": "2.36-9+deb12u4",
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "LGPL-2.1-or-later",
      "licenseDeclared": "LGPL-2.1-or-later",
      "copyrightText": "Copyright (C) 1991-2022 Free Software Foundation, Inc.",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:deb/debian/libc6@2.36-9+deb12u4?arch=amd64"
        }
      ]
    }
  ],
  "relationships": [
    {
      "spdxElementId": "SPDXRef-DOCUMENT",
      "relatedSpdxElement": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relationshipType": "DESCRIBES"
    },
    {
      "spdxElementId": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relatedSpdxElement": "SPDXRef-Package-GoModule-gin-gonic",
      "relationshipType": "DEPENDS_ON"
    },
    {
      "spdxElementId": "SPDXRef-Package-ContainerImage-payment-gateway",
      "relatedSpdxElement": "SPDXRef-Package-Debian-libc6",
      "relationshipType": "DEPENDS_ON"
    }
  ]
}
```

---

### C. Kubernetes Kyverno Admission Control License Policy
File: `license-compliance-policy.yaml`

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-container-license-compliance
  annotations:
    policies.kyverno.io/title: Block Unapproved Open Source Licenses
    policies.kyverno.io/category: Supply Chain Security & Governance
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Container Image
    policies.kyverno.io/description: >-
      Scans container images entering the cluster to block execution of software
      carrying high-risk licenses (AGPL-3.0, SSPL-1.0, BSL-1.1, GPL-3.0) 
      violating corporate legal compliance policy.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-no-banned-licenses
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Deployment rejected: Image contains dependencies under prohibited licenses (AGPL-3.0, SSPL-1.0, BSL-1.1, or GPL-3.0)."
        foreach:
          - list: "request.object.spec.containers"
            elementScope: true
            deny:
              conditions:
                all:
                  - key: "{{ image_licenses(element.image) }}"
                    operator: AnyIn
                    value:
                      - "AGPL-3.0-only"
                      - "AGPL-3.0-or-later"
                      - "SSPL-1.0"
                      - "BSL-1.1"
                      - "GPL-3.0-only"
                      - "GPL-3.0-or-later"
```

---

## 4. Real-World CLI Orchestration & Terminal Outputs

### Scenario 1: Generating and Inspecting an SBOM via `syft`

```bash
$ syft dir:. -o table
```

**Expected Terminal Output:**

```text
[0000]  INFO Syft version: 1.3.0
[0000]  INFO loading metadata for source: .
[0001]  INFO cataloging packages
 [Packages] 📦 3 packages identified

NAME                    VERSION        TYPE          LICENSE           
github.com/gin-gonic/gin v1.9.1        go-module     MIT               
github.com/mattn/go-isatty v0.0.19       go-module     MIT               
golang.org/x/net        v0.17.0        go-module     BSD-3-Clause      

✔ Cataloged packages [3 packages]
```

---

### Scenario 2: Blocking a CI Build due to an AGPL-3.0 Contamination Trigger

```bash
$ trivy fs --security-checks license --severity CRITICAL --exit-code 1 .
```

**Expected Terminal Output:**

```text
2026-08-06T19:05:12.102Z	INFO	[license] License scanning is enabled
2026-08-06T19:05:12.441Z	INFO	Number of language-specific files: 1
2026-08-06T19:05:12.441Z	INFO	Detecting Go dependencies licenses...

go.mod (gomod)

Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

+-----------------------+------------------+----------+---------------+----------------------------------+
|        PACKAGE        | LICENSE CATEGORY | SEVERITY |  LICENSE NAME |             CAPTION              |
+-----------------------+------------------+----------+---------------+----------------------------------+
| github.com/affero/db  | Restricted       | CRITICAL | AGPL-3.0-only | Forbidden license in commercial  |
|                       |                  |          |               | SaaS application deployment      |
+-----------------------+------------------+----------+---------------+----------------------------------+

Error: exit status 1
```

---

### Scenario 3: Validating Copyright and License Headers via `reuse`

```bash
$ reuse lint
```

**Expected Terminal Output:**

```text
# Synthesis of lint result
Summary of compliance checks:
* Compliant: 42 files
* Non-compliant: 2 files
* Total files: 44

The following files have missing copyright or license information:
* pkg/payment/processor.go
* scripts/deploy-production.sh

================================================================================
FAILURE: Project does not conform to the REUSE specification version 3.0.
================================================================================
```

---

## 5. Verification & Diagnostic Troubleshooting Guide

```
+-----------------------------------------------------------------------------------+
|                        FOSS LICENSE TRIAGE & DIAGNOSTIC TREE                      |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|                   [ CI/CD Pipeline License Gate Failed ]                          |
|                                     |                                             |
|                                     v                                             |
|               What type of License Violation was reported?                        |
|                                     |                                             |
|        +----------------------------+----------------------------+                |
|        |                                                         |                |
|        v                                                         v                |
| [ Missing Header / Notice ]                             [ Prohibited License ]    |
|        |                                                         |                |
|        v                                                         v                |
| Fix: Add SPDX header to file:                         Is it a direct or           |
| // SPDX-License-Identifier: Apache-2.0                transitive dependency?      |
| // SPDX-FileCopyrightText: 2026 Corp                             |                |
|                                            +---------------------+----------------+
|                                            |                                      |
|                                            v                                      v
|                                    [ Direct Dep ]                 [ Transitive Dep ]
|                                            |                                      |
|                                            v                                      v
|                                    Replace library or             Use go.mod replace /
|                                    isolate via network RPC        npm override / vendor
|                                    sidecar container.             patch & update tree.
+-----------------------------------------------------------------------------------+
```

### Triage Matrix for Compliance Failures

| Error Symptom | Root Cause | Diagnostic Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| **`CRITICAL: AGPL-3.0-only detected`** | Direct or transitive inclusion of a network-copyleft package. | `go mod why -m github.com/vendor/agpl-pkg` or `npm ls <pkg>` | 1. Replace with a permissive equivalent.<br>2. If unreplaceable, isolate execution into an external microservice bounded purely by network APIs (RPC/HTTP) and open-source that specific sub-service. |
| **`HIGH: GPL-3.0 detected in shared library`** | Linking a GPL-3.0 dynamic/static library directly into a proprietary binary. | `ldd /path/to/binary` or `syft image:<image-tag>` | 1. Replace with an `LGPL-3.0` or `MIT`/`Apache-2.0` alternative.<br>2. Recompile library with dynamic link boundaries if LGPL, ensuring user can substitute the object file. |
| **`REUSE Lint Missing License/Copyright`** | Source code file lacks SPDX tag header. | `reuse lint` | Run `reuse annotate --license Apache-2.0 --copyright "Enterprise Corp" path/to/file.go`. |
| **`SPDX Parsing Error: Unknown License`** | Custom or non-standard license string found in dependency manifest. | `syft dir:. -o json \| jq '.packages[] \| select(.licenseDeclared == "NOASSERTION")'` | Inspect package repository `LICENSE` file. Map manually in scanning configuration via custom SPDX override rules. |

---

### Step-by-Step Incident Remediation Protocol

#### Problem: A deep transitive dependency introduces a GPL-3.0 component into an enterprise service written in Go.

1. **Trace Dependency Path:**
   ```bash
   $ go mod why -m github.com/gpl-author/copyleft-lib
   ```
   *Output:*
   ```text
   # github.com/gpl-author/copyleft-lib
   main-service/pkg/telemetry
   github.com/intermediate/framework
   github.com/gpl-author/copyleft-lib
   ```

2. **Isolate or Replace via Dependency Overrides:**
   If the intermediate framework can be updated or forced to use a permissive fork, configure your package manager manifest (`go.mod`):
   ```go
   module main-service

   go 1.22

   require (
       github.com/intermediate/framework v1.4.0
   )

   // Override copyleft transitive dependency with permissive maintained fork
   replace github.com/gpl-author/copyleft-lib v1.0.0 => github.com/enterprise-forks/copyleft-lib-mit v1.0.1-mit
   ```

3. **Re-Run Automated Verification Gate:**
   ```bash
   $ syft dir:. -o json | jq '.packages[] | select(.name | contains("copyleft-lib"))'
   $ trivy fs --security-checks license --severity HIGH,CRITICAL --exit-code 1 .
   ```

---

## 6. References

* **Linux Professional Institute (LPI) Official Site:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **The Open Source Initiative (OSI) Open Source Definition:**  
  [https://opensource.org/osd](https://opensource.org/osd)
* **Free Software Foundation (FSF) The Free Software Definition:**  
  [https://www.gnu.org/philosophy/free-sw.html](https://www.gnu.org/philosophy/free-sw.html)
* **SPDX License List & Specification (Linux Foundation):**  
  [https://spdx.org/licenses/](https://spdx.org/licenses/)
* **REUSE Specification for Software Licensing Metadata:**  
  [https://reuse.software/spec/](https://reuse.software/spec/)
* **Anchore Syft (SBOM Generator Documentation):**  
  [https://github.com/anchore/syft](https://github.com/anchore/syft)
* **Trivy License Scanner (Aqua Security):**  
  [https://aquasecurity.github.io/trivy/latest/docs/coverage/license/](https://aquasecurity.github.io/trivy/latest/docs/coverage/license/)
* **Kyverno Cluster Policy Engine (CNCF Graduate Project):**  
  [https://kyverno.io/docs/policies/](https://kyverno.io/docs/policies/)