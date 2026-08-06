# LPI 050-100: Open Source Essentials
## Topic 3.1: Concepts of Open Content Licenses (Weight: 5)

---

### Official Reference Documentation
* **LPI Open Source Essentials Overview & Objectives**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **Creative Commons Licensing Framework & Legal Code**: [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
* **GNU Free Documentation License (GFDL v1.3)**: [https://www.gnu.org/licenses/fdl-1.3.html](https://www.gnu.org/licenses/fdl-1.3.html)
* **Free Art License 1.3 (Licence Art Libre)**: [https://artlibre.org/licence/lal/en/](https://artlibre.org/licence/lal/en/)
* **Software Package Data Exchange (SPDX) Specification**: [https://spdx.dev/specifications/](https://spdx.dev/specifications/)
* **FSFE REUSE Specification for Machine-Readable Licensing**: [https://reuse.software/spec/](https://reuse.software/spec/)

---

### Deep Technical Mechanics & Architecture Framework

Open Content Licensing adapts open-source governance principles—originally engineered for executable code—to non-code digital assets, including technical documentation, system architecture diagrams, API schemas, design specifications, and multimedia assets.

#### 1. Software vs. Content Licensing Mechanics
* **Open Source Software (OSS) Licenses** (e.g., GPL, Apache-2.0, MIT) target source code binaries, linking mechanics, compiler output, and patent retaliation clauses.
* **Open Content Licenses** target textual works, data structures, artistic assets, and documentation. They address copyright rights such as reproduction, distribution, public performance, moral rights, and derivative works without requiring binary compilation models.

#### 2. The Creative Commons (CC) Modular Architecture
Creative Commons licenses use four core modular legal clauses combined into six primary license suites, alongside the `CC0` public domain dedication:

| Component | Short Code | Mechanics & Production Implications |
| :--- | :--- | :--- |
| **Attribution** | `BY` | Mandates credit to original authors, URI links to license, and modification indicators. Mandatory in all CC v4.0 standard licenses. |
| **ShareAlike** | `SA` | **Copyleft Clause**: Derivative works *must* be distributed under the exact same or compatible license. Forces downstream compliance. |
| **NonCommercial** | `NC` | Restricts utilization to non-commercial purposes. **Incompatible with the Open Source Definition (OSD) and Free Cultural Works definition**, as it prohibits commercial production use. |
| **NoDerivatives** | `ND` | Allows redistribution but **prohibits modification or creation of derivative works**. Violates OSD principles of modification rights. |

```
                       ┌──────────────────────────────────────────────┐
                       │              CC0 (Public Domain)             │
                       └──────────────────────┬───────────────────────┘
                                              │
                       ┌──────────────────────▼───────────────────────┐
                       │                CC BY (Permissive)            │
                       └──────┬────────────────────────────────┬──────┘
                              │                                │
            ┌─────────────────▼────────┐           ┌───────────▼────────────────┐
            │   CC BY-SA (Copyleft)    │           │    CC BY-NC (Restricted)    │
            │   [Free Cultural Work]   │           │    [Non-Free Content]      │
            └──────────────────────────┘           └───────────┬────────────────┘
                                                               │
                                                   ┌───────────▼────────────────┐
                                                   │ CC BY-NC-SA / CC BY-NC-ND  │
                                                   │    [Strict Commercial Ban] │
                                                   └────────────────────────────┘
```

#### 3. Legacy and Alternative Open Content Licenses
* **GNU Free Documentation License (GFDL)**: Designed by the FSF for manual documentation. Features **Invariant Sections**, **Cover Texts**, and **Front/Back Cover Texts** that cannot be altered. This creates legal friction when attempting to merge GFDL content with CC BY-SA content.
* **Free Art License (FAL 1.3 / Licence Art Libre)**: A copyleft license for artistic and textual works compatible with CC BY-SA 4.0.
* **Open Publication License (OPL)**: An earlier open content license featuring options for commercial restriction or prohibiting modified versions.

#### 4. Machine-Readable Compliance (SPDX & XMP Metadata)
In SRE automation and GitOps pipelines, human-readable legal files (`LICENSE.txt`) are complemented by machine-readable annotations:
* **SPDX License Identifiers**: Standardized short strings (e.g., `CC-BY-4.0`, `CC-BY-SA-4.0`, `GFDL-1.3-or-later`, `CC0-1.0`).
* **Extensible Metadata Platform (XMP)**: XML metadata embedded directly inside binary media containers (PNG, SVG, PDF, WebP) enforcing digital provenance.

---

### Guided Hands-on Exercises

---

#### Exercise 1: Auditing & Applying Open Content Licenses with `reuse` CLI & SPDX Validation

In this exercise, you will set up a technical documentation repository, apply machine-readable SPDX headers across Markdown and media files, and validate compliance using the Free Software Foundation Europe (`FSFE`) `reuse` tool.

##### Step 1.1: Environment Setup and Tooling Installation
Run the following commands in your Linux shell to install `python3-pip`, `git`, and the `reuse` compliance engine:

```bash
sudo apt-get update -y && sudo apt-get install -y python3-pip git jq exiftool
pip3 install reuse
reuse --version
```

*Expected Output:*
```text
reuse, version 3.0.2
```

##### Step 1.2: Repository Construction
Create a mock platform architecture documentation tree:

```bash
mkdir -p ~/platform-docs/docs/diagrams
mkdir -p ~/platform-docs/.reuse
cd ~/platform-docs
git init

cat <<'EOF' > docs/index.md
# Platform Architecture Guide
This document describes the Kubernetes cluster deployment pipeline.
EOF

cat <<'EOF' > docs/diagrams/network-topology.svg
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
  <circle cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
</svg>
EOF
```

##### Step 1.3: Apply SPDX Open Content Headers to Documentation
Annotate `docs/index.md` under the **Creative Commons Attribution 4.0 International (`CC-BY-4.0`)** license and `docs/diagrams/network-topology.svg` under **Creative Commons Zero 1.0 Universal (`CC0-1.0`)**.

```bash
reuse annotate --license CC-BY-4.0 --copyright "Platform Engineering Team <sre@example.com>" docs/index.md
reuse annotate --license CC0-1.0 --copyright "Platform Engineering Team <sre@example.com>" docs/diagrams/network-topology.svg
```

##### Step 1.4: Download Official License Texts and Audit Compliance
Download legal text files into the standard `LICENSES/` folder automatically and run `reuse lint`:

```bash
reuse download --all
reuse lint
```

*Expected Output:*
```text
# Linting ...
# Result: SUCCESS
# Congratulations! Your project is compliant with the REUSE specification.
```

##### Step 1.5: Inspect the Auto-Generated Header Format
View the modifications made to `docs/index.md` to verify syntax:

```bash
head -n 6 docs/index.md
```

*Expected Output:*
```markdown
<!--
SPDX-FileCopyrightText: 2026 Platform Engineering Team <sre@example.com>

SPDX-License-Identifier: CC-BY-4.0
-->
```

---

##### Verification Questions — Exercise 1

**Question 1.1**: Which SPDX identifier must be applied if the platform engineering team mandates that any downstream team modifying `docs/index.md` MUST publish their modifications under the exact same copyleft license terms?
A) `CC-BY-4.0`  
B) `CC-BY-NC-4.0`  
C) `CC-BY-SA-4.0`  
D) `CC-BY-ND-4.0`  

**Question 1.2**: Why does adding a `CC-BY-NC-4.0` license header to technical documentation render the repository non-compliant with the Open Source Definition (OSD)?
A) It prohibits distributing the documentation over SSH protocols.  
B) It restricts commercial usage, violating OSD Item 6 (No Discrimination Against Fields of Endeavor).  
C) It requires paying royalties to Creative Commons.  
D) It forces source code binaries to be licensed under the GNU GPLv2.  

---

#### Exercise 2: Embedding XMP Open Content Metadata into Media Assets and Automation in CI/CD

In production pipelines, documentation builds process binary images (PNG/PDF). These binary files cannot host standard comment headers (`<!-- SPDX ... -->`). Instead, SREs embed machine-readable XMP (Extensible Metadata Platform) tags.

##### Step 2.1: Convert SVG to PNG and Embed XMP Licensing Metadata
Use `exiftool` to insert SPDX license metadata into a PNG graphic asset:

```bash
cd ~/platform-docs

# Create a sample binary file
convert docs/diagrams/network-topology.svg docs/diagrams/network-topology.png 2>/dev/null || cp docs/diagrams/network-topology.svg docs/diagrams/network-topology.png

# Write XMP metadata tags for CC-BY-SA-4.0
exiftool -XMP-dc:Rights="Attribution-ShareAlike 4.0 International" \
         -XMP-cc:License="https://creativecommons.org/licenses/by-sa/4.0/" \
         -XMP-plus:LicenseID="CC-BY-SA-4.0" \
         -overwrite_original docs/diagrams/network-topology.png
```

##### Step 2.2: Verify Embedded XMP Metadata via Shell Inspection
Extract and inspect the embedded XMP licensing metadata:

```bash
exiftool -XMP-cc:License -XMP-plus:LicenseID docs/diagrams/network-topology.png
```

*Expected Output:*
```text
URL License                     : https://creativecommons.org/licenses/by-sa/4.0/
License ID                      : CC-BY-SA-4.0
```

##### Step 2.3: Build an Automated Pre-Commit Compliance Script
Create a production bash validation script (`scripts/audit-licenses.sh`) that inspects all images in the repo and rejects files missing valid XMP license metadata or containing non-approved licenses (e.g. `NC` or `ND` variants):

```bash
mkdir -p scripts

cat <<'EOF' > scripts/audit-licenses.sh
#!/usr/bin/env bash
set -euo pipefail

FAILED=0
echo "=== Starting SRE Open Content License Audit ==="

for img in $(find docs/diagrams -type f \( -name "*.png" -o -name "*.jpg" \)); do
    LICENSE_ID=$(exiftool -s -s -s -XMP-plus:LicenseID "$img" || true)
    
    if [ -z "$LICENSE_ID" ]; then
        echo "[ERROR] File $img is missing embedded XMP LicenseID metadata!"
        FAILED=1
    elif [[ "$LICENSE_ID" =~ (NC|ND) ]]; then
        echo "[ERROR] File $img contains restricted license: $LICENSE_ID (NC/ND prohibited)!"
        FAILED=1
    else
        echo "[OK] File $img verified with LicenseID: $LICENSE_ID"
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "=== Audit FAILED: Non-compliant assets detected ==="
    exit 1
else
    echo "=== Audit PASSED: All media assets comply with Open Content standards ==="
    exit 0
fi
EOF

chmod +x scripts/audit-licenses.sh
./scripts/audit-licenses.sh
```

*Expected Output:*
```text
=== Starting SRE Open Content License Audit ===
[OK] File docs/diagrams/network-topology.png verified with LicenseID: CC-BY-SA-4.0
=== Audit PASSED: All media assets comply with Open Content standards ===
```

##### Step 2.4: Create a GitHub Actions Workflow Manifest for Automated Enforcement
Write a syntactically valid GitHub Actions workflow manifest `.github/workflows/content-compliance.yml`:

```bash
mkdir -p .github/workflows

cat <<'EOF' > .github/workflows/content-compliance.yml
name: Open Content License Compliance

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

jobs:
  license-audit:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Codebase
        uses: actions/checkout@v4

      - name: Install Audit Dependencies
        run: |
          sudo apt-get update -y
          sudo apt-get install -y exiftool python3-pip
          pip3 install reuse

      - name: Validate REUSE/SPDX Syntax
        run: |
          reuse lint

      - name: Validate Embedded XMP Media Metadata
        run: |
          bash ./scripts/audit-licenses.sh
EOF
```

---

##### Verification Questions — Exercise 2

**Question 2.1**: You execute `exiftool` against a production PDF manual and discover the tag `XMP-cc:License="https://creativecommons.org/licenses/by-nd/4.0/"`. What restriction does this apply to your SRE team?
A) You cannot run the PDF generator software inside a Docker container.  
B) You are allowed to read and redistribute the manual, but you cannot modify, translate, or adapt the content for internal runbooks.  
C) You must pay a subscription fee to Creative Commons every time the document is downloaded.  
D) The PDF source code must be compiled using GCC.  

**Question 2.2**: Why is XMP metadata preferred over sidecar text files (`.txt`) for binary assets in cloud-native content pipelines?
A) XMP metadata is encrypted with RSA keys.  
B) Sidecar text files double the storage footprint in Git repositories.  
C) XMP metadata is directly embedded into the binary file container, preserving legal provenance when assets are uploaded, transformed, or moved across CDN pipelines.  
D) Linux kernels require XMP headers to render PNG files in POSIX environments.  

---

#### Exercise 3: Evaluating License Compatibility & Handling Legal Incompatibilities (GFDL vs. CC BY-SA)

In this exercise, you will analyze license compatibility conflicts when combining third-party open documentation (GFDL v1.3 with Invariant Sections vs CC BY-SA 4.0 vs Permissive Software Licenses).

##### Step 3.1: Simulate a Documentation License Friction Scenario
Create two reference files containing external documentation snippets under different legal regimes:

```bash
mkdir -p ~/platform-docs/external

# File A: GFDL 1.3 with Invariant Sections
cat <<'EOF' > ~/platform-docs/external/gfdl-manual.md
<!--
SPDX-FileCopyrightText: 2021 Free Software Foundation
SPDX-License-Identifier: GFDL-1.3-invariants-or-later
-->
# GNU System Administration Manual
Invariant Section: "Secondary History of GNU System"
This section cannot be altered or removed under GFDL v1.3 terms.
EOF

# File B: Creative Commons Attribution-ShareAlike 4.0
cat <<'EOF' > ~/platform-docs/external/cc-by-sa-guide.md
<!--
SPDX-FileCopyrightText: 2023 Open Docs Author
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Cloud Native Storage Walkthrough
This text is licensed under CC BY-SA 4.0. Derivative works must be redistributed under CC BY-SA 4.0.
EOF
```

##### Step 3.2: Inspect SPDX License Expressions and Compatibility Constraints
Run a Python script utilizing the standard `spdx-tools` parsing logic to evaluate license expressions and identify conflicts:

```bash
pip3 install spdx-tools

cat <<'EOF' > scripts/evaluate_compatibility.py
import sys

def check_compatibility(doc_a_spdx, doc_b_spdx):
    print(f"Analyzing compatibility between '{doc_a_spdx}' and '{doc_b_spdx}'...")
    
    # Conflict Rule 1: GFDL with Invariant Sections vs CC-BY-SA 4.0
    if "GFDL" in doc_a_spdx and "invariants" in doc_a_spdx and "CC-BY-SA" in doc_b_spdx:
        print("[CRITICAL CONFLICT] Incompatible License Aggregation!")
        print("Reason: GFDL Invariant Sections prohibit modification of specific text blocks.")
        print("CC-BY-SA 4.0 mandates that all derivative text must be licensed under CC BY-SA without unalterable sections.")
        return False
    elif "CC0-1.0" in doc_a_spdx or "MIT" in doc_a_spdx:
        print("[COMPATIBLE] Permissive assets can be incorporated into Copyleft documents.")
        return True
    else:
        print("[NOTICE] Conditional aggregation permitted via separate modules.")
        return True

if __name__ == "__main__":
    res = check_compatibility("GFDL-1.3-invariants-or-later", "CC-BY-SA-4.0")
    if not res:
        sys.exit(1)
EOF

python3 scripts/evaluate_compatibility.py
```

*Expected Output:*
```text
Analyzing compatibility between 'GFDL-1.3-invariants-or-later' and 'CC-BY-SA-4.0'...
[CRITICAL CONFLICT] Incompatible License Aggregation!
Reason: GFDL Invariant Sections prohibit modification of specific text blocks.
CC-BY-SA 4.0 mandates that all derivative text must be licensed under CC BY-SA without unalterable sections.
```

##### Step 3.3: Resolving Code-in-Documentation Licensing Dual-Attribution
When technical documentation contains executable shell or Python code snippets, licensing ambiguity can arise. SRE best practices dictate dual-licensing the repository via SPDX expressions:

```bash
cat <<'EOF' > ~/platform-docs/docs/runbook.md
<!--
SPDX-FileCopyrightText: 2026 Platform Team <sre@example.com>
SPDX-License-Identifier: CC-BY-4.0 AND MIT
-->
# Kubernetes Troubleshooting Runbook

The prose in this runbook is licensed under CC-BY-4.0.
The embedded executable bash code snippets are licensed under the MIT license.

```bash
kubectl get pods --all-namespaces -o json | jq '.items[] | select(.status.phase!="Running")'
```
EOF

reuse lint
```

*Expected Output:*
```text
# Linting ...
# Result: SUCCESS
```

---

##### Verification Questions — Exercise 3

**Question 3.1**: Creative Commons modified version 4.0 of the CC BY-SA legal text to establish official compatibility with which external documentation license?
A) Apache-2.0  
B) GNU Free Documentation License (GFDL) v1.3 (under specific conditions without Invariant Sections)  
C) Microsoft Public License (MS-PL)  
D) JSON License  

**Question 3.2**: An engineer extracts Python scripts from a documentation manual licensed strictly under `CC-BY-NC-SA-4.0` and imports them into a commercial production automation tool. Why does this violate open source principles?
A) `CC-BY-NC-SA-4.0` requires compiling Python into C extensions.  
B) The `NC` (NonCommercial) clause prohibits commercial execution, making it a non-free license for software usage under the Open Source Definition.  
C) `CC-BY-NC-SA-4.0` requires all scripts to run on Windows OS.  
D) Python scripts can only be licensed under BSD-3-Clause.  

---

### Answers and Explanations

<details>
<summary>Click to view Answers and Explanations</summary>

#### Exercise 1 Answers

* **1.1 Correct Answer: C (`CC-BY-SA-4.0`)**
  * **Explanation**: The `SA` (ShareAlike) component is the copyleft mechanism of the Creative Commons suite. It requires any derivative works or modified versions of the licensed material to be distributed under the exact same license terms (`CC-BY-SA-4.0` or a compatible license). `CC-BY-4.0` is permissive (requires only attribution), `CC-BY-NC-4.0` adds a non-commercial restriction, and `CC-BY-ND-4.0` prohibits derivative works altogether.
* **1.2 Correct Answer: B (It restricts commercial usage, violating OSD Item 6)**
  * **Explanation**: The Open Source Definition (OSD) explicit clause Item 6 ("No Discrimination Against Fields of Endeavor") states that a license must not restrict anyone from making use of the program or content in a specific field of endeavor, including commercial enterprise. `NC` (NonCommercial) licenses prohibit commercial production use, categorizing them as "Non-Free" or "Source-Available" restricted content rather than true Open Content / Open Source.

---

#### Exercise 2 Answers

* **2.1 Correct Answer: B (You can read and redistribute, but cannot modify, translate, or adapt)**
  * **Explanation**: The `ND` (NoDerivatives) clause explicitly permits copying and redistribution in any medium or format for any purpose (even commercial, unless combined with NC). However, if you remix, transform, or build upon the material, you **may not distribute the modified material**. This prevents creating translated manuals, updated runbooks, or modified architecture diagrams.
* **2.2 Correct Answer: C (XMP metadata is embedded in the binary container, preserving legal provenance)**
  * **Explanation**: Binary image formats (PNG, JPG, WebP) and documents (PDF) do not support inline text comment blocks like `.md` or `.py` files. While sidecar files can easily be separated from image assets during CDN distribution, asset pipeline build steps, or downloads, XMP (Extensible Metadata Platform) writes metadata directly into the binary header bytes. This ensures machine-readable copyright and license metadata travels with the media file.

---

#### Exercise 3 Answers

* **3.1 Correct Answer: B (GNU Free Documentation License v1.3)**
  * **Explanation**: CC BY-SA 4.0 was updated to allow one-way or two-way compatibility mechanisms with GFDL v1.3, provided the GFDL document has no **Invariant Sections** and no **Cover Texts**. This allows wiki ecosystems (such as Wikipedia) to relicense or cross-pollinate documentation assets legally across GFDL and CC BY-SA repositories.
* **3.2 Correct Answer: B (The NC clause prohibits commercial execution, making it non-free under OSD)**
  * **Explanation**: Applying Creative Commons licenses—especially `NC` (NonCommercial) variants—to functional software code creates severe operational and legal issues. The `NC` restriction blocks commercial deployment, commercial SaaS execution, and commercial support wrappers, directly contradicting Open Source principles. For software code embedded inside documentation, dual-licensing with an OSI-approved software license (e.g., `MIT`, `Apache-2.0`, or `GPL-3.0`) via SPDX expressions (e.g., `CC-BY-4.0 AND MIT`) is the recommended production pattern.

</details>