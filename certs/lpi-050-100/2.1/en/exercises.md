# LPI Open Source Essentials (Exam 050-100) — Study Guide

## Topic 2.1: Concepts of Open Source Software Licenses
* **Exam Weight:** 7.5
* **Target Audience:** DevOps Engineers, SREs, Platform Architects, and Compliance Engineers.
* **Official Reference URLs:**
  * LPI Open Source Essentials Overview: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
  * Open Source Initiative (OSI) — Open Source Definition: [https://opensource.org/osd](https://opensource.org/osd)
  * Free Software Foundation (FSF) — The Free Software Definition: [https://www.gnu.org/philosophy/free-sw.html](https://www.gnu.org/philosophy/free-sw.html)
  * SPDX License List & Specification: [https://spdx.org/licenses/](https://spdx.org/licenses/)
  * GNU Licenses & Compatibility Matrix: [https://www.gnu.org/licenses/gpl-faq.html](https://www.gnu.org/licenses/gpl-faq.html)

---

## Architectural & Theoretical Mechanics

### 1. FSF Four Essential Freedoms vs. OSI Open Source Definition (OSD)
Software licensing governance rests on two foundational definitions:

```
                      ┌─────────────────────────────────────────┐
                      │    Free & Open Source Software (FOSS)   │
                      └────────────────────┬────────────────────┘
                                           │
             ┌─────────────────────────────┴─────────────────────────────┐
             ▼                                                           ▼
┌─────────────────────────┐                                 ┌─────────────────────────┐
│     FSF (Free Software) │                                 │  OSI (Open Source)      │
├─────────────────────────┤                                 ├─────────────────────────┤
│ Focus: Ethical Liberty  │                                 │ Focus: Practical Dev    │
│ - Freedom 0: Run        │                                 │ - 10 OSD Criteria       │
│ - Freedom 1: Study      │                                 │ - No Commercial/Field   │
│ - Freedom 2: Share      │                                 │   Discrimination        │
│ - Freedom 3: Improve    │                                 │ - License Neutrality    │
└─────────────────────────┘                                 └─────────────────────────┘
```

* **FSF Four Freedoms (Free Software Foundation):**
  * **Freedom 0:** The freedom to run the program for any purpose.
  * **Freedom 1:** The freedom to study how the program works, and change it (requires access to source code).
  * **Freedom 2:** The freedom to redistribute copies so you can help your neighbor.
  * **Freedom 3:** The freedom to distribute copies of your modified versions to others.

* **OSI 10 Criteria (Open Source Initiative):**
  Includes free redistribution, source code availability, allow derived works, integrity of author's source code, no discrimination against persons/groups (Criterion 5), no discrimination against fields of endeavor (Criterion 6 — e.g., commercial or military use cannot be barred), license distribution, product non-specificity, non-restriction of other software, and technology neutrality.

---

### 2. License Taxonomy Spectrum

| License Category | Examples | Distribution Trigger Reciprocity | Linking Boundary Effect | Patent Grants |
| :--- | :--- | :--- | :--- | :--- |
| **Permissive** | `MIT`, `BSD-2-Clause`, `BSD-3-Clause`, `Apache-2.0` | Minimal (Notice retention only) | Unrestricted | `Apache-2.0` includes express patent grant & retaliation clause. `MIT`/`BSD` are silent. |
| **Weak Copyleft** | `LGPL-2.1`, `LGPL-3.0`, `MPL-2.0`, `EPL-2.0` | Reciprocal for library/file modifications | Dynamic linking allows proprietary linking; Static linking requires object files to relink. | `MPL-2.0`/`EPL-2.0`/`LGPL-3.0` contain express patent clauses. |
| **Strong Copyleft** | `GPL-2.0-only`, `GPL-3.0-only` | Reciprocal for entire combined/derivative work | Static & Dynamic linking propagate copyleft to dependent code. | `GPL-3.0` contains explicit patent termination; `GPL-2.0` relies on implied grants. |
| **Network Copyleft** | `AGPL-3.0-only` | Triggered by binaries **and** SaaS/Network execution (Section 13) | Expands distribution definition to include API calls across a network. | Explicit patent grant and retaliation provisions. |

---

## Guided Production Exercises

### Exercise 1: Inspecting License Headers, SPDX Expressions, and Generating SBOMs via CLI

In this exercise, you will create a sample multi-language microservice root, apply standard SPDX header declarations, and analyze the dependency tree using CLI tooling (`syft` and `jq`) to audit license compliance.

#### Step 1.1: Environment Setup & Microservice Mocking
Run the following commands in your shell to construct a workspace with declared licenses:

```bash
mkdir -p ~/license-audit-lab/src
cd ~/license-audit-lab

# Create a Permissive python entrypoint with SPDX identifier
cat << 'EOF' > src/app.py
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Platform Engineering Team

import requests

def main():
    print("Microservice initialized under MIT License.")

if __name__ == "__main__":
    main()
EOF

# Create a Go helper with Copyleft SPDX identifier
cat << 'EOF' > src/core.go
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Infrastructure Core Team

package main

import "fmt"

func CoreLogic() {
    fmt.Println("Executing core logic governed by GPL-3.0-or-later")
}
EOF

# Create a package.json referencing external dependencies
cat << 'EOF' > package.json
{
  "name": "edge-router",
  "version": "1.0.0",
  "license": "Apache-2.0",
  "dependencies": {
    "express": "^4.18.2",
    "lodash": "^4.17.21"
  }
}
EOF
```

**Expected Command Output:**
```text
Files created under ~/license-audit-lab
```

#### Step 1.2: Generate an SPDX-Compliant Software Bill of Materials (SBOM)
Install or execute `syft` (or simulate SBOM generation via python/jq if syft is unavailable) to output an SPDX 2.3 JSON manifest:

```bash
# Executing syft to scan the directory and generate an SPDX JSON SBOM
syft dir:. -o spdx-json=sbom.spdx.json
```

**Expected Command Output:**
```text
 ✔ Scanned application                       [3 packages]
 ✔ Created SBOM                              [spdx-json]
```

#### Step 1.3: Inspect the Generated SPDX Manifest
Filter the generated SBOM to parse license expressions using `jq`:

```bash
jq '{spdxVersion, name, packages: [.packages[] | {name: .name, version: .versionDeclared, license: .licenseConcluded}]}' sbom.spdx.json
```

**Expected Command Output:**
```json
{
  "spdxVersion": "SPDX-2.3",
  "name": "license-audit-lab",
  "packages": [
    {
      "name": "express",
      "version": "4.18.2",
      "license": "MIT"
    },
    {
      "name": "lodash",
      "version": "4.17.21",
      "license": "MIT"
    }
  ]
}
```

---

#### Verification Questions — Block 1
1. **Q1.1:** Why does OSI Criterion 6 ("No Discrimination Against Fields of Endeavor") prevent a license that states *"This software cannot be used for commercial cloud hosting or military applications"* from being certified as Open Source?
2. **Q1.2:** What is the technical mechanism of an `SPDX-License-Identifier` header in source code files, and how does it reduce machine-parsing ambiguity compared to legacy free-form license blocks?

---

### Exercise 2: Dependency Graph Compatibility Analysis & Reciprocity Boundaries

In this exercise, you will analyze a combined software architecture consisting of dynamic binaries, statically linked libraries, and microservices accessed over HTTP API boundaries to determine license compliance obligations.

#### Step 2.1: Analyze Architecture Integration Scenarios

Consider the following architectural deployment diagram:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          User Application Stack                             │
│                                                                             │
│  ┌──────────────────────┐    Dynamic Link    ┌───────────────────────────┐  │
│  │ Proprietary Codebase │ ─────────────────> │ LGPL-3.0 Dynamic Library  │  │
│  └──────────┬───────────┘                    └───────────────────────────┘  │
│             │                                                               │
│             │ Static Link                                                   │
│             ▼                                                               │
│  ┌──────────────────────┐                    ┌───────────────────────────┐  │
│  │  GPL-3.0 Engine Lib  │                    │ AGPL-3.0 Microservice     │  │
│  └──────────────────────┘                    │ (Hosted across HTTP API)  │  │
│                                              └─────────────▲─────────────┘  │
│                                                            │ Network Call   │
│                                                            │ (gRPC / REST)  │
│                                              ──────────────┴──────────────  │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Step 2.2: Evaluate Dynamic vs. Static Linking Boundaries
Execute a local file dependency trace to simulate how dynamic vs static binary links propagate copyleft requirements on Linux systems:

```bash
# Simulating ldd inspection on a binary linking against LGPL vs GPL libraries
cat << 'EOF' > trace_linking.sh
#!/usr/bin/env bash
echo "=== Analyzing ELF Binary Dynamic Dependencies ==="
echo "Linking target: libcrypto.so (Permissive/Apache-Style)"
echo "Linking target: libglib-2.0.so (LGPL-2.1-or-later)"
echo "Linking target: libgengine.a (Statically Compiled GPL-3.0)"
echo ""
echo "RESULT:"
echo "1. Dynamic linkage to LGPL-2.1 does NOT force the host binary to become LGPL/GPL."
echo "2. Static linkage to GPL-3.0 archive propagates GPL-3.0 copyleft to host binary."
EOF

chmod +x trace_linking.sh
./trace_linking.sh
```

**Expected Command Output:**
```text
=== Analyzing ELF Binary Dynamic Dependencies ===
Linking target: libcrypto.so (Permissive/Apache-Style)
Linking target: libglib-2.0.so (LGPL-2.1-or-later)
Linking target: libgengine.a (Statically Compiled GPL-3.0)

RESULT:
1. Dynamic linkage to LGPL-2.1 does NOT force the host binary to become LGPL/GPL.
2. Static linkage to GPL-3.0 archive propagates GPL-3.0 copyleft to host binary.
```

---

#### Verification Questions — Block 2
1. **Q2.1:** If a company deploys an unmodified `GPL-v3.0` licensed database internally to process backend transactions for a public Web SaaS without distributing binaries to users, are they obligated under `GPL-v3.0` to release their SaaS front-end source code? How would the answer change if the database were licensed under `AGPL-3.0-only`?
2. **Q2.2:** What operational requirement does the `LGPL-3.0` place on an application developer who statically links an LGPL-3.0 library into a proprietary application, compared to dynamically linking it?

---

### Exercise 3: Implementing Automated License Compliance Policy Enforcers in CI/CD

In this exercise, you will create a syntactically valid Policy-as-Code manifest using Open Policy Agent (OPA) style syntax / YAML configuration to automatically block non-compliant licenses (e.g., `GPL-3.0-only`, `AGPL-3.0-only`, `SSPL-1.0`) during continuous integration builds.

#### Step 3.1: Write the License Policy Configuration File
Create a policy definition `license-policy.yaml` enforcing company compliance requirements:

```bash
cat << 'EOF' > license-policy.yaml
version: "1.0"
policy:
  name: Enterprise-Software-Compliance
  action_on_violation: FAIL_BUILD
  allowed_licenses:
    - MIT
    - Apache-2.0
    - BSD-2-Clause
    - BSD-3-Clause
    - MPL-2.0
  conditional_licenses:
    LGPL-2.1-or-later:
      allow_if: DYNAMIC_LINKING_ONLY
    LGPL-3.0-or-later:
      allow_if: DYNAMIC_LINKING_ONLY
  banned_licenses:
    - GPL-2.0-only
    - GPL-3.0-only
    - AGPL-3.0-only
    - SSPL-1.0
    - Commons-Clause
EOF
```

**Expected Command Output:**
```text
File license-policy.yaml created.
```

#### Step 3.2: Construct the Verification Engine Script
Write a Python validator script `check_compliance.py` that processes the generated SBOM against `license-policy.yaml`:

```bash
cat << 'EOF' > check_compliance.py
#!/usr/bin/env python3
import json
import yaml
import sys

def audit():
    with open('license-policy.yaml', 'r') as f:
        policy = yaml.safe_load(f)
    
    with open('sbom.spdx.json', 'r') as f:
        sbom = json.load(f)

    allowed = set(policy['policy']['allowed_licenses'])
    banned = set(policy['policy']['banned_licenses'])
    
    violations = []
    
    for pkg in sbom.get('packages', []):
        name = pkg.get('name')
        lic = pkg.get('licenseConcluded') or pkg.get('licenseDeclared')
        
        if lic in banned:
            violations.append(f"CRITICAL: Banned license '{lic}' found in package '{name}'")
        elif lic not in allowed:
            violations.append(f"WARNING: Unapproved license '{lic}' found in package '{name}'")

    print("=== Automated License Compliance Audit Results ===")
    if violations:
        for v in violations:
            print(f"[FAIL] {v}")
        sys.exit(1)
    else:
        print("[PASS] All dependencies comply with Enterprise License Policy.")
        sys.exit(0)

if __name__ == '__main__':
    audit()
EOF

chmod +x check_compliance.py
./check_compliance.py
```

**Expected Command Output:**
```text
=== Automated License Compliance Audit Results ===
[PASS] All dependencies comply with Enterprise License Policy.
```

---

#### Verification Questions — Block 3
1. **Q3.1:** What is the critical distinction between Apache 2.0 and MIT regarding patent rights, and how does Apache 2.0 Clause 3 (Patent Grant) protect downstream enterprise adopters against patent litigation?
2. **Q3.2:** Explain why non-compete/source-available licenses such as the Server Side Public License (SSPL) or Business Source License (BSL/BUSL) fail OSI compliance, and why they are categorized as proprietary/source-available rather than Open Source.

---

## Answers and Architectural Explanations

<details>
<summary>Click to expand Detailed Solutions & Explanations</summary>

### Block 1 Answers

* **A1.1:**
  * **Architectural Explanation:** OSI Criterion 6 explicitly mandates: *"The license must not restrict anyone from making use of the program in a specific field of endeavor."* Restricting commercial cloud hosting, military, financial, or research usage violates this core tenet. Open source licenses grant universal rights regardless of who the user is or what business/operational model they run. If field restrictions are added, the license becomes a restrictive or proprietary "source-available" license, losing its Open Source status.

* **A1.2:**
  * **Architectural Explanation:** `SPDX-License-Identifier` headers use standardized short identifier strings (defined at [https://spdx.org/licenses/](https://spdx.org/licenses/)) embedded directly into file headers (e.g., `# SPDX-License-Identifier: Apache-2.0`). This replaces legacy free-form, multi-paragraph text blocks that required complex natural language processing (NLP) or fuzzy regex matching. Automated SAST/SBOM tools can deterministically tokenize source files across millions of lines of code with zero ambiguity.

---

### Block 2 Answers

* **A2.1:**
  * **Architectural Explanation:**
    1. **GPL-v3.0 Scenario:** Under `GPL-v3.0`, the copyleft distribution trigger is defined by physical binary or source code *distribution* to third parties. Interacting with software running on a server over a network (SaaS) does **not** constitute distribution. Therefore, the company has no obligation to release its backend or front-end code.
    2. **AGPL-3.0-only Scenario:** `AGPL-3.0` (GNU Affero General Public License) specifically introduces **Section 13** (Remote Network Interaction). Section 13 states that if you run a modified version of the program on a server and let users interact with it over a computer network, you must offer those users access to the corresponding source code of the modified program via a network download.

* **A2.2:**
  * **Architectural Explanation:** The `LGPL-3.0` (Lesser General Public License) allows proprietary applications to link to LGPL libraries without forcing the host application to become open source, **provided** the user can modify and relink the LGPL library component.
    * If **dynamically linked** (`.so` / `.dylib` / `.dll`), the end-user can simply swap out the shared object file with their custom-built library.
    * If **statically linked**, the application vendor is obligated to provide the unlinked object files (`.o`) or source code of the proprietary host application so the end-user can manually relink the executable against a modified version of the LGPL library.

---

### Block 3 Answers

* **A3.1:**
  * **Architectural Explanation:** While the MIT license is permissive and requires only copyright notice retention, it is completely silent regarding patent rights. `Apache-2.0` includes an explicit, irrevocable, worldwide patent grant (Clause 3) from every contributor to the user. Furthermore, Apache 2.0 includes a **Patent Defense / Termination Clause**: if a downstream licensee initiates patent litigation against any contributor claiming that the contribution infringes their patents, any patent licenses granted to that user under Apache 2.0 terminate automatically. This creates a defensive legal shield for enterprise ecosystems.

* **A3.2:**
  * **Architectural Explanation:** Licenses like SSPL (MongoDB) or BSL (HashiCorp) prohibit third parties from offering the software as a managed commercial cloud service (e.g., Database-as-a-Service) in direct competition with the author without purchasing a commercial agreement. This directly breaches **OSI Criterion 1** (Free Redistribution) and **OSI Criterion 6** (No Discrimination Against Fields of Endeavor). Because rights are conditioned on business model protection rather than software liberty, OSI and FSF strictly classify them as non-free/source-available proprietary licenses.

</details>

---

## Summary of Key Takeaways for LPI 050-100 Exam

1. **Permissive (MIT, BSD, Apache-2.0):** Requires minimal notice retention; allows proprietary re-licensing of derivative works.
2. **Weak Copyleft (LGPL, MPL, EPL):** Protects modifications at the library/file level; permits linking with proprietary software.
3. **Strong Copyleft (GPL):** Forces the entire combined work to be released under GPL upon binary distribution.
4. **Network Copyleft (AGPL):** Triggers reciprocity upon network interaction (SaaS), closing the SaaS copyleft loophole.
5. **SPDX Identifiers:** Standardized strings (`SPDX-License-Identifier: <ID>`) used for machine-readable legal compliance in CI/CD pipelines.