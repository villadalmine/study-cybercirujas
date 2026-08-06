# LPI 050-100 Study Guide: Topic 3.2 – Creative Commons Licenses

**Certification:** LPI Open Source Essentials (Exam 050-100)  
**Topic 3.2:** Creative Commons Licenses  
**Weight:** 5  

---

## Official Reference Sources
* **LPI Open Source Essentials Overview:** [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Creative Commons Official License Descriptions:** [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
* **Creative Commons CC0 Public Domain Dedication:** [https://creativecommons.org/publicdomain/zero/1.0/](https://creativecommons.org/publicdomain/zero/1.0/)
* **SPDX License List (Creative Commons Identifiers):** [https://spdx.org/licenses/](https://spdx.org/licenses/)
* **FSFE REUSE Specification for Software & Media Compliance:** [https://reuse.software/](https://reuse.software/)

---

## Architectural Context & SRE Principles

In production platform engineering, licensing extends beyond source code binaries. Architectural blueprints, runbooks, infrastructure-as-code documentation, API schemas, and benchmark datasets are governed by content licenses. Creative Commons (CC) is the standard legal framework for non-code artifacts. 

Engineers must understand the internal mechanics of Creative Commons layers:
1. **Legal Code:** The machine-enforceable traditional legal contract.
2. **Human-Readable Deed:** Summary of key rights and permissions.
3. **Machine-Readable Metadata (CC REL / SPDX):** Structured metadata consumable by automated CI/CD scanners and search engines.

```
+-----------------------------------------------------------------------+
|                         HUMAN-READABLE DEED                           |
|      (Commons Deed: Summary of rights, obligations, and scope)        |
+-----------------------------------------------------------------------+
|                         MACHINE-READABLE METADATA                     |
|    (SPDX Headers, RDF/XML, CC REL, HTML microdata, REUSE .dep5)      |
+-----------------------------------------------------------------------+
|                           LEGAL CODE                                  |
|   (Enforceable legal contract drafted by international legal team)   |
+-----------------------------------------------------------------------+
```

---

## Exercise 1: Deconstructing CC License Building Blocks and SPDX Validation via CLI

### Objective
Inspect and query SPDX identifiers for Creative Commons licenses using REST APIs and shell pipelines to establish baseline metadata standards for technical documentation repositories.

### Context & Mechanics
Creative Commons uses four primary designators:
* `BY` (**Attribution**): Must give appropriate credit, provide a link to the license, and indicate if changes were made.
* `SA` (**ShareAlike**): If you remix, transform, or build upon the material, you must distribute your contributions under the same license as the original.
* `NC` (**NonCommercial**): Commercial use is prohibited.
* `ND` (**NoDerivatives**): If you remix, transform, or build upon the material, you may not distribute the modified material.
* `CC0` (**Public Domain Dedication**): Waives all copyright and related rights globally.

### Execution Steps

1. Create a workspace directory and fetch the official SPDX license inventory for Creative Commons 4.0 licenses using `curl` and `jq`:

```bash
mkdir -p ~/cc-compliance-lab && cd ~/cc-compliance-lab

curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json | \
jq '.licenses[] | select(.licenseId | startswith("CC-")) | {licenseId, name, isOsiApproved, isFsfLibre}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-4.0",
  "name": "Creative Commons Attribution 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": true
}
{
  "licenseId": "CC-BY-NC-4.0",
  "name": "Creative Commons Attribution Non Commercial 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-NC-ND-4.0",
  "name": "Creative Commons Attribution Non Commercial No Derivatives 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-NC-SA-4.0",
  "name": "Creative Commons Attribution Non Commercial Share Alike 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-ND-4.0",
  "name": "Creative Commons Attribution No Derivatives 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": false
}
{
  "licenseId": "CC-BY-SA-4.0",
  "name": "Creative Commons Attribution Share Alike 4.0 International",
  "isOsiApproved": false,
  "isFsfLibre": true
}
```

2. Query specific license details to extract legal requirements for `CC-BY-SA-4.0` using the SPDX JSON API:

```bash
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/details/CC-BY-SA-4.0.json | \
jq '{licenseId, name, seeAlso: .seeAlso[0], standardLicenseHeader: .standardLicenseHeader}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-SA-4.0",
  "name": "Creative Commons Attribution Share Alike 4.0 International",
  "seeAlso": "https://creativecommons.org/licenses/by-sa/4.0/legalcode",
  "standardLicenseHeader": ""
}
```

3. Compare `CC0-1.0` metadata against `CC-BY-4.0`:

```bash
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json | \
jq '.licenses[] | select(.licenseId == "CC0-1.0" or .licenseId == "CC-BY-4.0") | {licenseId, isFsfLibre}'
```

**Expected CLI Output:**
```json
{
  "licenseId": "CC-BY-4.0",
  "isFsfLibre": true
}
{
  "licenseId": "CC0-1.0",
  "isFsfLibre": true
}
```

---

### Verification Questions (Exercise 1)

1. **Which combination of Creative Commons elements creates the most restrictive license that prevents commercial usage and modifications while enforcing attribution?**
   * A) `CC BY-NC`
   * B) `CC BY-NC-ND`
   * C) `CC BY-NC-SA`
   * D) `CC BY-ND`

2. **Why are Creative Commons licenses marked as `isOsiApproved: false` in the SPDX registry?**
   * A) OSI (Open Source Initiative) only approves licenses designed for software code, whereas CC licenses (except CC0/BY) are designed for creative/documentation content and often contain non-open restrictions like NC or ND.
   * B) Creative Commons failed to submit their legal code for review to OSI before version 4.0.
   * C) CC licenses violate copyright law by allowing public domain dedications without legal contracts.
   * D) SPDX registries only track FSF (Free Software Foundation) approved licenses.

3. **What is the key legal distinction between `CC0-1.0` and `CC-BY-4.0` regarding downstream consumers?**
   * A) `CC0-1.0` requires attribution only in commercial applications, while `CC-BY-4.0` requires it always.
   * B) `CC0-1.0` waives all copyright rights to the maximum extent permitted by law (no attribution required), whereas `CC-BY-4.0` retains copyright and legally compels downstream users to credit the creator.
   * C) `CC-BY-4.0` forces downstream modifications to be published under an identical license, whereas `CC0-1.0` permits proprietary relicensing.
   * D) `CC0-1.0` applies exclusively to software binaries, while `CC-BY-4.0` applies exclusively to documentation.

---

## Exercise 2: Implementing Automated CC Compliance and REUSE Validation in CI/CD

### Objective
Configure an automated license header compliance pipeline for a documentation repository containing Markdown guides, SVG architecture diagrams, and JSON benchmark data using the FSFE REUSE standard.

### Context & Mechanics
In modern GitOps repositories, every file must express clear copyright and license metadata. For binary/creative files (like PNG diagrams or SVGs) where inline header comments break file syntax, REUSE uses separate `.license` files or a centralized `.reuse/dep5` file using Debian copyright syntax.

### Configuration Manifest

Create `.reuse/dep5` to map non-code architectural artifacts to Creative Commons licenses:

```ini
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Platform-Architecture-Docs
Source: https://github.com/example-org/platform-docs

Files: docs/*
Copyright: 2026 Platform Engineering Team <sre@example.com>
License: CC-BY-4.0

Files: architecture/diagrams/*
Copyright: 2026 Enterprise Architecture Guild <arch@example.com>
License: CC-BY-SA-4.0

Files: benchmarks/data/*.json
Copyright: 2026 SRE Performance Group <perf@example.com>
License: CC0-1.0
```

### Execution Steps

1. Install Python `reuse` CLI tool inside a virtual environment:

```bash
cd ~/cc-compliance-lab
python3 -m venv venv
source venv/bin/activate
pip install reuse
```

2. Create sample documentation files matching the specified repository layout:

```bash
mkdir -p docs architecture/diagrams benchmarks/data .reuse

cat << 'EOF' > docs/sre-runbook.md
# Kubernetes Out-of-Memory (OOM) Troubleshooting Runbook
This document outlines standard operational procedures for SRE teams handling Pod OOMKilled events.
EOF

cat << 'EOF' > architecture/diagrams/cluster-topology.svg
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <circle cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
</svg>
EOF

cat << 'EOF' > benchmarks/data/latency-metrics.json
{
  "p99_latency_ms": 12.4,
  "p95_latency_ms": 4.1,
  "throughput_rps": 45000
}
EOF
```

3. Write the `.reuse/dep5` manifest created above:

```bash
cat << 'EOF' > .reuse/dep5
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Platform-Architecture-Docs
Source: https://github.com/example-org/platform-docs

Files: docs/*
Copyright: 2026 Platform Engineering Team <sre@example.com>
License: CC-BY-4.0

Files: architecture/diagrams/*
Copyright: 2026 Enterprise Architecture Guild <arch@example.com>
License: CC-BY-SA-4.0

Files: benchmarks/data/*.json
Copyright: 2026 SRE Performance Group <perf@example.com>
License: CC0-1.0
EOF
```

4. Download license text files required by REUSE into `LICENSES/`:

```bash
mkdir -p LICENSES

# Fetch official license texts via REUSE CLI tool
reuse download CC-BY-4.0 CC-BY-SA-4.0 CC0-1.0
```

**Expected CLI Output:**
```text
Successfully downloaded CC-BY-4.0.txt
Successfully downloaded CC-BY-SA-4.0.txt
Successfully downloaded CC0-1.0.txt
```

5. Run `reuse lint` to verify automated compliance across all assets:

```bash
reuse lint
```

**Expected CLI Output:**
```text
# Summary

* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: CC-BY-4.0, CC-BY-SA-4.0, CC0-1.0
* Read files: 4
* Total files: 4

Congratulations! Your project is compliant with version 3.0 of the REUSE Specification!
```

---

### Verification Questions (Exercise 2)

1. **Why is using `.reuse/dep5` preferable for SVGs and JSON data files compared to adding inline headers?**
   * A) `.reuse/dep5` encrypts copyright statements so third parties cannot tamper with them.
   * B) Inline header comments in structural formats like JSON render the file syntactically invalid, while SVG comments can degrade rendering performance. `.reuse/dep5` provides external mapping without modifying asset binaries.
   * C) `.reuse/dep5` automatically translates licenses into international jurisdictions.
   * D) Creative Commons rules mandate that CC licenses must never be placed inside source files directly.

2. **If a team member adds a new diagram under `architecture/diagrams/new-mesh.svg` without updating `.reuse/dep5` or adding a `.license` file, what will `reuse lint` output?**
   * A) It automatically converts the file to `CC0-1.0`.
   * B) It returns a non-zero exit code reporting `Missing licensing information` for `architecture/diagrams/new-mesh.svg`.
   * C) It ignores non-code extensions like `.svg` by default.
   * D) It raises a syntax error in python and aborts execution.

---

## Exercise 3: Resolving Remix Compatibility Matrix & Derivative Works Rules

### Objective
Evaluate license compatibility matrices for documentation derivatives and construct operational guidelines for platform teams aggregating external documentation into runbooks.

### Context & Mechanics
Mixing Creative Commons licensed works into a single derivative work is governed by the **CC Compatibility Matrix**.

Key constraints when creating a **Derivative Work** (Remix):
* **ND (NoDerivatives)** content **cannot be remixed** or included in a derivative work at all. It can only be distributed in its original form as part of a collection.
* **SA (ShareAlike)** requires that the *entire derivative work* be licensed under the exact same license or an explicit compatible license (e.g., `CC BY-SA 4.0` can be adapted into `CC BY-SA 4.0`).
* **NC (NonCommercial)** forces the resulting derivative work to retain an NC clause.
* **BY** elements must accumulate credit for all upstream authors.

```
       UPSTREAM ASSET 1                       UPSTREAM ASSET 2
    +--------------------+                 +--------------------+
    |     CC BY 4.0      |                 |    CC BY-SA 4.0    |
    +---------+----------+                 +---------+----------+
              |                                      |
              +-------------------+------------------+
                                  |
                                  v
                    +---------------------------+
                    |  REMIX / DERIVATIVE WORK  |
                    |     MUST BE LICENSED      |
                    |      CC BY-SA 4.0         |
                    +---------------------------+
```

### Compatibility Rules Matrix for Adapting Two Works

| Source 1 License | Source 2 License | Resulting Derivative License | Allowed? |
| :--- | :--- | :--- | :--- |
| `CC BY` | `CC BY` | `CC BY` | Yes |
| `CC BY` | `CC BY-SA` | `CC BY-SA` | Yes (SA propagates) |
| `CC BY` | `CC BY-NC` | `CC BY-NC` | Yes (NC propagates) |
| `CC BY-SA` | `CC BY-NC-SA` | **Incompatible** | **NO** (SA conflict: one requires NC, one permits Commercial) |
| Any License | `CC BY-ND` | **Incompatible** | **NO** (ND forbids adaptation) |
| `CC0` | `CC BY` | `CC BY` | Yes |

---

### Execution Steps

1. Create a validation script `validate_remix.sh` to simulate a pipeline checking whether combining two documentation assets violates CC rules:

```bash
cat << 'EOF' > validate_remix.sh
#!/usr/bin/env bash
set -euo pipefail

LICENSE_A="$1"
LICENSE_B="$2"

echo "Evaluating compatibility for Remix: [$LICENSE_A] + [$LICENSE_B]"

if [[ "$LICENSE_A" == *"ND"* ]] || [[ "$LICENSE_B" == *"ND"* ]]; [[ "$LICENSE_A" != "$LICENSE_B" ]]; then
    echo "ERROR: Violation of NoDerivatives (ND). Cannot create derivative work."
    exit 1
fi

if [[ "$LICENSE_A" == *"SA"* ]] && [[ "$LICENSE_B" == *"NC-SA"* ]]; then
    echo "ERROR: ShareAlike conflict! CC-BY-SA requires downstream to be CC-BY-SA (allowing commercial), while CC-BY-NC-SA forces NonCommercial."
    exit 1
fi

if [[ "$LICENSE_A" == "CC-BY" ]] && [[ "$LICENSE_B" == "CC-BY-SA" ]]; then
    echo "SUCCESS: Compatible. Output work must be licensed as CC-BY-SA."
    exit 0
fi

if [[ "$LICENSE_A" == "CC0" ]]; then
    echo "SUCCESS: Compatible. Output inherits [$LICENSE_B]."
    exit 0
fi

echo "SUCCESS: Combination permitted under standard CC compatibility terms."
EOF

chmod +x validate_remix.sh
```

2. Test valid adaptation (`CC-BY` + `CC-BY-SA`):

```bash
./validate_remix.sh "CC-BY" "CC-BY-SA"
```

**Expected CLI Output:**
```text
Evaluating compatibility for Remix: [CC-BY] + [CC-BY-SA]
SUCCESS: Compatible. Output work must be licensed as CC-BY-SA.
```

3. Test invalid adaptation (`CC-BY-SA` + `CC-BY-NC-SA`):

```bash
./validate_remix.sh "CC-BY-SA" "CC-BY-NC-SA" || echo "Execution failed as expected."
```

**Expected CLI Output:**
```text
Evaluating compatibility for Remix: [CC-BY-SA] + [CC-BY-NC-SA]
ERROR: ShareAlike conflict! CC-BY-SA requires downstream to be CC-BY-SA (allowing commercial), while CC-BY-NC-SA forces NonCommercial.
Execution failed as expected.
```

---

### Verification Questions (Exercise 3)

1. **An engineer wants to take an internal runbook licensed under `CC BY-SA 4.0` and merge sections from a third-party guide licensed under `CC BY-NC-SA 4.0`. Can the resulting combined document be legally published? Why or why not?**
   * A) Yes, provided the author grants credit to both upstream repositories under `CC BY`.
   * B) No. `CC BY-SA 4.0` requires derivative works to be released under `CC BY-SA 4.0` (which allows commercial use), whereas `CC BY-NC-SA 4.0` requires derivative works to be released under a NonCommercial license (`CC BY-NC-SA`). These ShareAlike obligations mutually conflict.
   * C) Yes, because ShareAlike licenses are universally compatible with each other regardless of NC flags.
   * D) No, because Creative Commons prohibits combining any two documents with different licenses.

2. **What is the operational constraint when hosting an image licensed under `CC BY-ND 4.0` inside a documentation portal licensed under `CC BY 4.0`?**
   * A) The image cannot be included on the portal under any circumstances.
   * B) The image can be displayed in its original, unmodified state as part of a collection (verbatim inclusion), but its visual elements cannot be edited, cropped, or altered to make a derivative work.
   * C) Including the image forces the entire documentation portal to become `CC BY-ND 4.0`.
   * D) The portal must pay royalties to Creative Commons to host ND content.

3. **Why is software source code generally discouraged from using Creative Commons licenses (such as CC BY-SA 4.0), and what should be used instead?**
   * A) CC licenses do not contain explicit grants of patent rights or provisions tailored for software source code delivery and compilation; open source software licenses like GPL, Apache 2.0, or MIT should be used instead.
   * B) Creative Commons licenses are invalid under international law when applied to ASCII text files.
   * C) Software code cannot be copyrighted under modern IP laws.
   * D) OSI prohibits the usage of any SPDX-registered license for source code repositories.

---

<details>
<summary>Exercise Answer Key & Explanations</summary>

### Exercise 1 Answer Key

1. **Correct Answer: B (`CC BY-NC-ND`)**
   * **Explanation:** `CC BY-NC-ND` is the most restrictive Creative Commons license. It requires Attribution (`BY`), restricts usage to NonCommercial (`NC`), and prohibits adaptations/remixes (`ND`).
2. **Correct Answer: A**
   * **Explanation:** The Open Source Initiative (OSI) defines the Open Source Definition specifically for software licenses. Creative Commons licenses (except CC0, which is a public domain dedication, and CC BY/CC BY-SA which are considered free culture licenses) contain clauses like `NC` (NonCommercial) or `ND` (NoDerivatives) that explicitly violate OSD Criteria 3 (No Discrimination Against Fields of Endeavor) and OSD Criteria 4 (Allowing Derived Works).
3. **Correct Answer: B**
   * **Explanation:** `CC0-1.0` is a legal tool designed to surrender all copyright and database rights to the maximum extent permitted by local law, operating as a public domain dedication. Downstream users have no legal obligation to attribute the author. `CC-BY-4.0` preserves copyright and creates a mandatory legal requirement for downstream consumers to provide attribution, link to the license, and indicate changes.

---

### Exercise 2 Answer Key

1. **Correct Answer: B**
   * **Explanation:** Non-code files such as JSON, PNG, or SVG can break parsers or suffer rendering issues if text comments are injected directly into their file structures. The FSFE REUSE specification solves this by placing copyright/licensing metadata into `.reuse/dep5` (or adjacent `.license` files), maintaining file integrity while ensuring machine-readable compliance.
2. **Correct Answer: B**
   * **Explanation:** `reuse lint` checks every file in the repository against license declarations. If a file is added without a corresponding rule in `.reuse/dep5` or an accompanying `.license` file, the tool fails with a non-zero exit code reporting unassigned license coverage.

---

### Exercise 3 Answer Key

1. **Correct Answer: B**
   * **Explanation:** `CC BY-SA 4.0` mandates that any derivative work must be licensed under `CC BY-SA 4.0` (or a listed compatible license), which allows commercial reuse. Conversely, `CC BY-NC-SA 4.0` mandates that derivative works must be released under `CC BY-NC-SA 4.0`, forbidding commercial reuse. A single derivative work cannot be simultaneously commercial and non-commercial; therefore, their ShareAlike requirements cannot be reconciled.
2. **Correct Answer: B**
   * **Explanation:** `ND` (NoDerivatives) prevents the creation of *derivative works* (adaptations/remixes). However, embedding an unaltered image alongside distinct text constitutes an *Aggregate/Collection*, which is permitted as long as the image itself is unmodified and credited properly.
3. **Correct Answer: A**
   * **Explanation:** Creative Commons licenses were designed for creative, artistic, and literary works (documentation, audio, video, images). They lack provisions addressing software patent grants, source versus binary distribution mechanisms, header declarations, and dependency linking. Software projects should use dedicated software licenses (e.g., Apache-2.0, MIT, GPL-3.0).

</details>