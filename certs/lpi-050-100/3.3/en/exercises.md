# LPI 050-100: Open Source Essentials
## Topic 3.3: Other Open Content Licenses (Weight: 2.5)

### Reference & Official Sources
- **Linux Professional Institute (LPI) Open Source Essentials**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Creative Commons Licenses Specification**: [https://creativecommons.org/licenses/](https://creativecommons.org/licenses/)
- **GNU Free Documentation License (GFDL v1.3)**: [https://www.gnu.org/licenses/fdl-1.3.html](https://www.gnu.org/licenses/fdl-1.3.html)
- **Open Data Commons Open Database License (ODbL)**: [https://opendatacommons.org/licenses/odbl/](https://opendatacommons.org/licenses/odbl/)
- **SPDX License List & Specifications**: [https://spdx.org/licenses/](https://spdx.org/licenses/)
- **REUSE Specification for Software & Content Supply Chain**: [https://reuse.software/](https://reuse.software/)

---

### Architectural Overview & Mechanics

Traditional software licenses (e.g., GNU GPL, MIT, Apache 2.0) are designed for executable source code and software binaries. Modern enterprise platform architectures, however, deal with extensive non-code assets: technical documentation, training datasets, AI models, infrastructure schematics, and relational/graph databases. 

Applying traditional software licenses to non-code content introduces significant legal and operational trade-offs:
1. **Source Code vs. Rendered Content**: Software licenses rely on concepts like "source code availability" and "compilation/linking," which do not cleanly translate to media, documentation (Markdown/AsciiDoc/PDF), or raw datasets.
2. **Sui Generis Database Rights**: In jurisdictions such as the European Union and the United Kingdom, databases are protected by a specific legal right (*sui generis* database right) separate from standard copyright. Software licenses do not address database structure vs. database content extraction.
3. **Attribution and Modification Restrictions**: Documentation and educational media often require strict attribution formatting, preservation of invariant historical sections, or prohibition of commercial reuse—mechanisms not present in permissive software licenses.

```
+-----------------------------------------------------------------------------------+
|                            OPEN CONTENT LICENSE TAXONOMY                          |
+------------------------------------------------------+----------------------------+
| MEDIA & DOCUMENTATION                                | DATASETS & DATABASES       |
+-----------------------+------------------------------+----------------------------+
| Creative Commons      | GNU Free Documentation (GFDL)| Open Data Commons          |
| - CC BY 4.0           | - Invariant Sections         | - PDDL (Public Domain)     |
| - CC BY-SA 4.0        | - Front-Cover Texts          | - ODC-BY (Attribution)     |
| - CC BY-NC / ND       | - Back-Cover Texts           | - ODbL (ShareAlike Data)   |
+-----------------------+------------------------------+----------------------------+
```

---

### Guided Hands-On Exercises

#### Exercise 1: Creative Commons Architecture & SPDX Identification

##### Scenario
You are architecting an automated documentation pipeline for an enterprise cloud platform. The documentation contains technical guides (text), architecture diagrams (vectors), and sample datasets. You must configure SPDX identifier headers, establish compliance under the **Approved for Free Cultural Works** definition, and validate license traits using CLI tooling.

##### Step 1.1: Environment Setup and Tooling Verification
Execute the following commands in your Linux shell to install `reuse` (the SPDX supply chain compliance engine) and initialize a target directory structure:

```bash
mkdir -p ~/open-content-lab/docs ~/open-content-lab/media
cd ~/open-content-lab

# Verify python3 and pip are available, then install reuse tool
python3 -m pip install --quiet reuse
reuse --version
```

**Expected Output:**
```text
reuse, version 5.0.0 (or higher)
```

##### Step 1.2: Constructing Syntactically Valid SPDX Headers for CC Assets
Create a documentation file `docs/architecture-guide.md` with an embedded SPDX header under **CC-BY-4.0** (Creative Commons Attribution 4.0 International) and a diagram metadata descriptor under **CC-BY-SA-4.0** (Creative Commons Attribution-ShareAlike 4.0 International).

Create `docs/architecture-guide.md`:
```markdown
<!--
SPDX-FileCopyrightText: 2026 Cloud Platform Architecture Team <arch@example.com>
SPDX-License-Identifier: CC-BY-4.0
-->

# Cloud Platform Storage Architecture

## Overview
This document outlines the distributed block storage mechanism for enterprise workloads.

## License Matrix
- Narrative Documentation: CC-BY-4.0 (Free Cultural Work)
- Vector Diagrams: CC-BY-SA-4.0 (Free Cultural Work)
```

Create `.reuse/dep5` file for automated supply-chain license mapping of media files:
```ini
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Enterprise Open Content Assets
Source: https://git.example.com/platform/docs

Files: media/*.png
Copyright: 2026 Graphics Engineering Group <design@example.com>
License: CC-BY-SA-4.0
```

##### Step 1.3: Verification of REUSE Supply-Chain Compliance
Run the compliance verification tool against your documentation repo:

```bash
reuse lint
```

**Expected Output:**
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: CC-BY-4.0, CC-BY-SA-4.0
* Status: OK
```

---

##### Verification Questions (Exercise 1)

**Question 1.1:** Which of the following Creative Commons license combinations meets the criteria for the **Definition of Free Cultural Works**?
- A) CC BY-NC-SA 4.0
- B) CC BY-ND 4.0
- C) CC BY-SA 4.0
- D) CC BY-NC 4.0

**Question 1.2:** If a DevOps engineer modifies a diagram licensed under `CC-BY-SA-4.0` and embeds it inside a proprietary commercial training manual, what legal requirement does the ShareAlike (SA) clause enforce on the resulting modified diagram?
- A) The entire proprietary manual must be dual-licensed under GPL v3.
- B) The modified diagram itself must be distributed under `CC-BY-SA-4.0` or a compatible license if distributed.
- C) The modified diagram cannot be used in any commercial context.
- D) The engineer must pay a royalty fee to the original copyright holder.

---

#### Exercise 2: GNU Free Documentation License (GFDL v1.3) Mechanics

##### Scenario
Your infrastructure team maintains legacy system manuals governed by the **GNU Free Documentation License (GFDL v1.3)**. You must structure a document containing **Invariant Sections** and **Front-Cover / Back-Cover Texts**, inspect its licensing constraints, and evaluate its compatibility with Creative Commons licenses.

##### Step 2.1: Drafting a GFDL-Compliant Manual Header
Create `docs/legacy-storage-manual.adoc` with formal GFDL 1.3 notices specifying Invariant Sections:

```asciidoc
= Enterprise SAN Infrastructure Management Manual
:author: Systems Engineering Group
:revdate: 2026-08-06

== License Notice
Copyright (C) 2026 Systems Engineering Group.
Permission is granted to copy, distribute and/or modify this document
under the terms of the GNU Free Documentation License, Version 1.3
or any later version published by the Free Software Foundation;
with the Invariant Sections being "Section 1: Architectural History",
with the Front-Cover Texts being "Enterprise Systems Manual", and
with the Back-Cover Texts being "Supported by Cloud SRE Dept".

== Section 1: Architectural History
[NOTE]
This section is INVARIANT. It cannot be altered, removed, or modified
in secondary derivative versions.

== Section 2: Operational CLI Reference
Run the following command to check storage pool health:
$ zpool status storage-pool-01
```

##### Step 2.2: Programmatically Analyzing GFDL Invariant Constraints
Write a lightweight Python verification script `verify_gfdl.py` to audit Markdown/AsciiDoc documentation files for invariant clause declarations:

```python
#!/usr/bin/env python3
import sys
import re

def audit_gfdl_invariants(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    gfdl_match = re.search(r'GNU Free Documentation License', content, re.IGNORECASE)
    invariant_match = re.search(r'with the Invariant Sections being ([^\n,]+)', content)
    
    print(f"[*] Auditing File: {filepath}")
    if gfdl_match:
        print("    [+] License Detected: GFDL")
        if invariant_match:
            print(f"    [!] Invariant Sections Enforced: {invariant_match.group(1)}")
            print("    [!] Trade-Off Warning: File contains Invariant Sections. Incompatible with strict CC-BY-SA 4.0 compliance.")
        else:
            print("    [+] No Invariant Sections declared.")
    else:
        print("    [-] GFDL not detected.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        audit_gfdl_invariants(sys.argv[1])
    else:
        print("Usage: python3 verify_gfdl.py <file-path>")
```

Execute the verification script against `docs/legacy-storage-manual.adoc`:

```bash
chmod +x verify_gfdl.py
./verify_gfdl.py docs/legacy-storage-manual.adoc
```

**Expected Output:**
```text
[*] Auditing File: docs/legacy-storage-manual.adoc
    [+] License Detected: GFDL
    [!] Invariant Sections Enforced: "Section 1: Architectural History"
    [!] Trade-Off Warning: File contains Invariant Sections. Incompatible with strict CC-BY-SA 4.0 compliance.
```

---

##### Verification Questions (Exercise 2)

**Question 2.1:** What is an "Invariant Section" under the GNU Free Documentation License (GFDL), and what restriction does it impose on secondary authors?
- A) A section of code that must compile without warnings.
- B) A designated section of the document handling title/history that cannot be modified or removed when redistributing or modifying the document.
- C) A mandatory legal section that locks the document into commercial-only use.
- D) A section containing cryptographic checksums of the document binary.

**Question 2.2:** Are GFDL v1.3 manuals containing Invariant Sections compatible for direct dual-licensing or re-licensing into `CC BY-SA 4.0`?
- A) Yes, GFDL v1.3 and CC BY-SA 4.0 are 100% bi-directionally compatible under all circumstances.
- B) No, CC BY-SA 4.0 does not permit invariant sections or secondary restrictions that prohibit modification of parts of the text.
- C) Yes, provided the author pays FSF a relicensing fee.
- D) No, because GFDL only applies to binary files.

---

#### Exercise 3: Open Data & Database Licensing (ODbL, ODC-BY, PDDL)

##### Scenario
You are deploying a telemetry data collection platform that extracts network topology data and publishes aggregated topology databases. You must understand the legal boundary between **Sui Generis Database Rights**, individual data points, and schema structures using Open Data Commons licenses (ODbL, ODC-BY, PDDL).

##### Step 3.1: Defining License Scope for Database Infrastructure
Create an enterprise database licensing spec file `database-license-manifest.yaml` representing a production dataset deployment:

```yaml
apiVersion: data.enterprise.io/v1alpha1
kind: DatabaseLicenseManifest
metadata:
  name: network-topology-db
spec:
  databaseName: "global-mesh-telemetry"
  licensingFramework: "Open Data Commons"
  components:
    - target: "Database Structure & Schema"
      license: "ODc-BY-1.0"
      spdxID: "ODC-By-1.0"
      description: "Attribution required for database structural usage."
    - target: "Aggregated Topological Data Contents"
      license: "ODbL-1.0"
      spdxID: "ODbL-1.0"
      description: "Open Database License - ShareAlike enforced on database modifications and extractions."
    - target: "Raw Sensor Fact Records (Individual Data Points)"
      license: "PDDL-1.0"
      spdxID: "PDDL-1.0"
      description: "Public Domain Dedication and License - Factual data points devoid of copyright."
```

##### Step 3.2: Querying Official Open Data Commons License Metadata
Use `curl` and `jq` to verify the SPDX license identifiers and metadata for Open Data Commons licenses via the official SPDX REST API:

```bash
# Query ODbL 1.0 details from SPDX API
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses/ODbL-1.0.json | jq '{licenseId: .licenseId, name: .name, isOsiApproved: .isOsiApproved, isFsfLibre: .isFsfLibre}'

# Query ODC-By 1.0 details from SPDX API
curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses/ODC-By-1.0.json | jq '{licenseId: .licenseId, name: .name, isOsiApproved: .isOsiApproved}'
```

**Expected Output:**
```json
{
  "licenseId": "ODbL-1.0",
  "name": "Open Data Commons Open Database License v1.0",
  "isOsiApproved": false,
  "isFsfLibre": true
}
{
  "licenseId": "ODC-By-1.0",
  "name": "Open Data Commons Attribution License v1.0",
  "isOsiApproved": false
}
```

##### Step 3.3: Analyzing the Operational Trade-offs of Database Licensing
Run a python simulation script `db_compliance_check.py` to evaluate whether a proposed data enrichment task triggers ODbL's ShareAlike (Share-Alike / Derivative Database) clause:

```python
#!/usr/bin/env python3

def check_odbl_trigger(action_type, distribution_scope):
    print(f"[+] Action: {action_type} | Scope: {distribution_scope}")
    if action_type == "PUBLIC_DERIVATIVE_DATABASE" and distribution_scope == "EXTERNAL":
        return ("RESULT: ODbL ShareAlike Triggered! You MUST release the modified/enhanced "
                "database under ODbL 1.0 and provide access to the raw data/updates.")
    elif action_type == "INTERNAL_DATA_MINING" and distribution_scope == "INTERNAL_ONLY":
        return ("RESULT: Compliant. Internal use of an ODbL database does not trigger "
                "public ShareAlike distribution requirements.")
    elif action_type == "PRODUCED_WORK" and distribution_scope == "EXTERNAL":
        return ("RESULT: Compliant with Attribution. Generating a visual map (Produced Work) "
                "from ODbL data requires notice/attribution, but does NOT require releasing "
                "the underlying rendering software code under ODbL.")
    else:
        return "RESULT: Requires manual legal assessment."

print("Scenario A: Internal analytics pipeline")
print(check_odbl_trigger("INTERNAL_DATA_MINING", "INTERNAL_ONLY"))
print("\nScenario B: Public map image rendered from DB")
print(check_odbl_trigger("PRODUCED_WORK", "EXTERNAL"))
print("\nScenario C: Merging proprietary dataset with ODbL dataset & redistributing DB")
print(check_odbl_trigger("PUBLIC_DERIVATIVE_DATABASE", "EXTERNAL"))
```

Execute the script:
```bash
python3 db_compliance_check.py
```

**Expected Output:**
```text
Scenario A: Internal analytics pipeline
[+] Action: INTERNAL_DATA_MINING | Scope: INTERNAL_ONLY
RESULT: Compliant. Internal use of an ODbL database does not trigger public ShareAlike distribution requirements.

Scenario B: Public map image rendered from DB
[+] Action: PRODUCED_WORK | Scope: EXTERNAL
RESULT: Compliant with Attribution. Generating a visual map (Produced Work) from ODbL data requires notice/attribution, but does NOT require releasing the underlying rendering software code under ODbL.

Scenario C: Merging proprietary dataset with ODbL dataset & redistributing DB
[+] Action: PUBLIC_DERIVATIVE_DATABASE | Scope: EXTERNAL
RESULT: ODbL ShareAlike Triggered! You MUST release the modified/enhanced database under ODbL 1.0 and provide access to the raw data/updates.
```

---

##### Verification Questions (Exercise 3)

**Question 3.1:** What distinction does the Open Database License (ODbL) make between a **Derivative Database** and a **Produced Work**?
- A) A Produced Work is a compiled binary executable, whereas a Derivative Database is a flat JSON file.
- B) A Derivative Database modifies or enriches the underlying data/structure (requiring ShareAlike upon public distribution), while a Produced Work (e.g., an image, report, or map generated from data) only requires attribution notice.
- C) A Produced Work requires full source code disclosure under GNU GPL v3.
- D) ODbL treats both Derivative Databases and Produced Works identically, requiring full raw database access in both cases.

**Question 3.2:** Why are standard software licenses like GPL v2 or MIT often ill-suited for governing large relational databases in jurisdictions with *Sui Generis* Database Rights?
- A) Software licenses only compile on Linux platforms.
- B) Software licenses govern copyright in code execution/source text, but do not specifically address rights over extraction, re-utilization, or structural database rights independent of copyright.
- C) Standard software licenses automatically convert databases into public domain.
- D) Database management systems (DBMS) refuse to parse licenses without YAML formatting.

---

<details>
<summary><strong>Click to expand Comprehensive Answer Key & Deep Architectural Explanations</strong></summary>

### Detailed Solutions & Theoretical Deep-Dive

#### Exercise 1 Answers
- **Question 1.1: Correct Answer = C (CC BY-SA 4.0)**
  - **Architectural Explanation**: The *Definition of Free Cultural Works* (maintained by Freedom Defined) requires that a license grant four fundamental freedoms: freedom to use/perform, freedom to study/apply, freedom to redistribute copies, and freedom to modify/improve and distribute derivatives.
  - **CC BY 4.0** and **CC BY-SA 4.0** are officially recognized as **Approved for Free Cultural Works**.
  - **NC (NonCommercial)** clauses restrict commercial usage, violating Freedom 1 (freedom to use for any purpose).
  - **ND (NoDerivatives)** clauses prohibit modification, violating Freedom 4 (freedom to adapt and redistribute modifications).

- **Question 1.2: Correct Answer = B (The modified diagram itself must be distributed under CC-BY-SA-4.0 or a compatible license if distributed)**
  - **Architectural Explanation**: ShareAlike (SA) operates as a copyleft mechanism specifically targeted at the asset and its direct adaptations. If an engineer modifies a CC BY-SA asset, the modified asset itself inherits the CC BY-SA terms. Embedding it inside a larger work (like a manual) does not automatically force the entire text of the manual under CC BY-SA if the manual is a collective work, but the adapted diagram component must remain licensed under CC BY-SA 4.0.

---

#### Exercise 2 Answers
- **Question 2.1: Correct Answer = B (A designated section of the document handling title/history that cannot be modified or removed when redistributing or modifying the document)**
  - **Architectural Explanation**: The GNU Free Documentation License (GFDL) was created by the Free Software Foundation (FSF) primarily for software manuals. It includes a specific provision allowing authors to declare secondary sections (such as historical acknowledgments, legal notices, or philosophical essays) as **Invariant Sections**. Secondary editors are legally prohibited from altering, updating, or deleting these sections.

- **Question 2.2: Correct Answer = B (No, CC BY-SA 4.0 does not permit invariant sections or secondary restrictions that prohibit modification of parts of the text)**
  - **Architectural Explanation**: Creative Commons licenses (including CC BY-SA 4.0) explicitly disallow additional downstream restrictions or unmodifiable text blocks. A GFDL document containing Invariant Sections imposes restrictions that CC BY-SA 4.0 prohibits. While GFDL v1.3 included a limited relicensing clause for wiki platforms meeting specific historical criteria (migrating to CC BY-SA before 2009), general GFDL manuals with Invariant Sections cannot be dual-licensed or converted into CC BY-SA 4.0.

---

#### Exercise 3 Answers
- **Question 3.1: Correct Answer = B (A Derivative Database modifies or enriches the underlying data/structure requiring ShareAlike upon public distribution, while a Produced Work only requires attribution notice)**
  - **Architectural Explanation**: Open Data Commons licenses (specifically ODbL) were explicitly engineered to solve the database problem.
    - **Database Structure/Content**: Covered by ODbL rights.
    - **Derivative Database**: If you extract, merge, or alter the data and publish the resulting database, ShareAlike mandates publishing the updated dataset under ODbL.
    - **Produced Work**: If you use the data to create a non-database artifact (e.g., rendering a PDF map from OpenStreetMap geospatial data), the map is a *Produced Work*. You do NOT have to release your map rendering engine or raw source code; you only need to include an attribution notice (e.g., "Contains data from OpenStreetMap, licensed under ODbL").

- **Question 3.2: Correct Answer = B (Software licenses govern copyright in code execution/source text, but do not specifically address rights over extraction, re-utilization, or structural database rights independent of copyright)**
  - **Architectural Explanation**: Copyright law protects original creative expression. Raw facts inside a database (e.g., temperature readings, stock prices, IP routing tables) are often held to lack original creative expression under common law (e.g., the *Feist Publications* doctrine in the US). However, jurisdictions like the EU enforce *Sui Generis Database Rights* (EU Directive 96/9/EC), which grant rights based on the substantial investment in obtaining, verifying, or presenting database content, regardless of copyright. Traditional software licenses (MIT, GPL) only target copyrightable code and fail to address *sui generis* extraction/re-utilization rights. Licenses like **ODbL**, **ODC-BY**, and **PDDL** explicitly license both copyright and database rights.

---

### Comparative Matrix: License Selection by Asset Type

| Asset Type | Recommended License | Primary Mechanism | Key Considerations / Trade-offs |
| :--- | :--- | :--- | :--- |
| **Media / Technical Writing** | `CC BY 4.0` | Permissive Attribution | Ideal for maximum adoption; compliant with Free Cultural Works. |
| **Community Documentation** | `CC BY-SA 4.0` | Copyleft Content | Ensures modified documentation remains open to the community. |
| **Legacy FSF Documentation** | `GFDL v1.3` | Invariant Protection | Protects author history/notices; trade-off: potential CC incompatibility. |
| **Public Datasets / Facts** | `PDDL` / `CC0` | Public Domain Dedication | Waives all copyright and database rights; zero friction for ML/AI models. |
| **Relational / Spatial Data** | `ODbL 1.0` | ShareAlike Database Right | Forces public derivative databases to remain open (e.g., OpenStreetMap). |

</details>