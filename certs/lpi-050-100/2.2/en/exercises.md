# Advanced Production Study Guide: LPI 050-100 (Open Source Essentials)
## Topic 2.2: Copyleft Software Licenses (Exam Weight: 7.5)

---

### Architectural & Technical Foundations

#### 1. The Legal & Mechanics Framework of Copyleft
Copyleft is a legal mechanism that leverages standard copyright law to guarantee software freedom. Rather than using copyright to restrict distribution and modification (as in proprietary software), copyleft uses copyright to mandate that all downstream redistributions and derivative works preserve the same freedoms.

```
+-----------------------------------------------------------------------------------+
|                                 SOFTWARE LICENSES                                 |
+------------------------------------------+----------------------------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
          [ Permissive Licenses ]                       [ Copyleft Licenses ]
          - MIT, Apache-2.0, BSD                        - Reciprocal duty triggered
          - Minimal downstream constraints               upon distribution / service
          - Relicensing allowed                          - Prevents proprietary derivative works
                    |                                             |
                    +                      +----------------------+----------------------+
                                           |                                             |
                                [ Strong / Full Copyleft ]                    [ Weak / Limited Copyleft ]
                                - GPLv2, GPLv3, AGPLv3                        - LGPLv2.1/v3, MPL-2.0, EPL-2.0
                                - Covers entire combined work                 - Scoped to library / file / module
                                - Links (static/dynamic) propagate duty       - Proprietary code can link dynamically
```

#### 2. License Taxonomy & Comparison Matrix

| License | Copyleft Strength | Scope of Reciprocity | SaaS/Network Loophole Addressed? | Patent License Clause | Hardware Lock / Anti-Tivoization |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **GPLv2** | Strong | Entire combined work (static & dynamic linking) | No | Implied (Unclear) | No |
| **GPLv3** | Strong | Entire combined work (static & dynamic linking) | No | Explicit (§11) | Yes (§6 Installation Info) |
| **AGPLv3** | Strongest | Entire combined work + Network-accessible services | Yes (§13) | Explicit (§11) | Yes (§6 Installation Info) |
| **LGPLv3** | Weak | Library binaries (Allows dynamic linking with proprietary code) | No | Explicit (§11) | Yes (§6 Installation Info) |
| **MPL-2.0** | Weak (File-level) | Modified existing files under MPL | No | Explicit (§3) | No |
| **EPL-2.0** | Weak (Module-level)| Modified EPL modules/files | No | Explicit (§2) | No |
| **Apache-2.0**| Permissive | None | No | Explicit (§3) | No |

---

### Deep Technical Mechanics & Legal Trade-offs

#### A. Combined Works vs. Isolated Processes (Linking Dynamics)
According to the Free Software Foundation (FSF) interpretation:
1. **Static Linking (`.a` / `.lib`)**: The compiler merges copyleft object code into the main binary. The final executable is indisputably a single combined work subject to the copyleft license.
2. **Dynamic Linking (`.so` / `.dll`)**: Symbols are resolved at runtime. FSF asserts that shared memory address spaces create a single combined work. Downstream applications dynamically linking against a GPL library must be released under a GPL-compatible license.
3. **IPC / Microservices (Process Boundary)**: Systems interacting strictly across network sockets (HTTP/gRPC) or UNIX domain sockets via well-defined REST/RPC schemas, without sharing memory or internal structures, maintain separate copyright boundaries under standard GPL.

#### B. The SaaS Loophole & AGPLv3 §13
Standard GPLv2 and GPLv3 trigger source-code release obligations **only upon distribution** (conveyance) of binaries to third parties. If an organization hosts modified GPL software in a cloud environment (Software-as-a-Service) and exposes its endpoints over HTTP without delivering binaries to clients, no "distribution" occurs.

**AGPLv3 Section 13** closes this loophole:
> *"If you modify the Program, your modified version must prominently offer to all users interacting with it remotely through a computer network [...] an opportunity to receive the Corresponding Source of your version..."*

#### C. Anti-Tivoization & DRM (GPLv2 vs. GPLv3)
Tivoization occurs when hardware vendors run GPL-licensed software (e.g., Linux kernel) on consumer devices, but enforce hardware key checks that block execution if the user uploads modified software binaries.
- **GPLv2 §3**: Requires providing source code, but does not explicitly demand private signing keys required by hardware bootloaders.
- **GPLv3 §6**: Mandates the provision of **Installation Information**—all keys, authorization codes, and verification methods necessary to install and run modified versions of the software on the target hardware.

#### D. License Compatibility Matrix
License compatibility determines whether code under License A can be combined into a single binary with code under License B.

```
       +-------------------------------------------------------------+
       | Downstream Target License (Combined Binary)                 |
       +--------------------+-------------------+--------------------+
Source | GPLv2-only         | GPLv3             | Apache-2.0         |
-------+--------------------+-------------------+--------------------+
GPLv2  | Compatible         | Incompatible*     | Incompatible       |
GPLv3  | Incompatible       | Compatible        | Compatible (v3->v2)|
Apache | Incompatible       | Compatible (§11)  | Compatible         |
AGPLv3 | Incompatible       | Compatible (§13)  | Incompatible       |
+------+--------------------+-------------------+--------------------+
*Note: GPLv2 code containing the "or (at your option) any later version" clause 
 (GPLv2+) can be re-licensed under GPLv3 to allow Apache-2.0 integration.
```

---

### Guided Production Lab Exercises

#### Exercise 1: Low-Level Binary & Linker Analysis for Copyleft Boundary Auditing

##### Objective
Analyze executable object files and shared libraries using GNU Binary Utilities (`gcc`, `readelf`, `ldd`, `nm`) to determine whether a compiled application dynamically or statically links against a strong copyleft (GPL) library versus a weak copyleft (LGPL) library.

##### Steps to Execute

1. Prepare an isolated workspace and construct a mock GPL-licensed library (`libgpl.c` / `libgpl.h`) and a proprietary core application (`app.c`):

```bash
mkdir -p ~/license-audit-lab/ex1 && cd ~/license-audit-lab/ex1

cat << 'EOF' > libgpl.h
#ifndef LIBGPL_H
#define LIBGPL_H
void gpl_licensed_function(void);
#endif
EOF

cat << 'EOF' > libgpl.c
#include <stdio.h>
#include "libgpl.h"

void gpl_licensed_function(void) {
    printf("[GPL CORE] Executing strong copyleft algorithm v1.0\n");
}
EOF

cat << 'EOF' > app.c
#include <stdio.h>
#include "libgpl.h"

int main(void) {
    printf("[APP CORE] Running proprietary control plane...\n");
    gpl_licensed_function();
    return 0;
}
EOF
```

2. Compile the GPL component into both a static archive (`libgpl.a`) and a shared library (`libgpl.so`):

```bash
# Compile object file
gcc -c -fPIC libgpl.c -o libgpl.o

# Create static archive (.a)
ar rcs libgpl.a libgpl.o

# Create shared library (.so)
gcc -shared -o libgpl.so libgpl.o
```

3. Build two binaries: `app_static` (statically linked) and `app_dynamic` (dynamically linked):

```bash
# Static compilation
gcc app.c -L. libgpl.a -o app_static

# Dynamic compilation
gcc app.c -L. -lgpl -Wl,-rpath,'$ORIGIN' -o app_dynamic
```

4. Audit shared library dependencies using `ldd`:

```bash
ldd app_static
ldd app_dynamic
```

*Expected Output (`ldd app_static`):*
```text
	statically linked
```

*Expected Output (`ldd app_dynamic`):*
```text
	linux-vdso.so.1 (0x00007ffd395f2000)
	libgpl.so => ./libgpl.so (0x00007f3b8a1c0000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f3b89f00000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f3b8a1c8000)
```

5. Perform ELF symbol table inspection using `readelf` and `nm` to prove symbol absorption:

```bash
nm -g app_static | grep gpl_licensed_function
nm -g app_dynamic | grep gpl_licensed_function
```

*Expected Output (`nm app_static`):*
```text
0000000000001159 T gpl_licensed_function
```

*Expected Output (`nm app_dynamic`):*
```text
                 U gpl_licensed_function
```

##### Verification Questions

**Q1.1**: In `app_static`, symbol `gpl_licensed_function` shows status `T` (Text section), whereas in `app_dynamic` it shows status `U` (Undefined symbol resolved at runtime). From an SRE/Legal engineering perspective, why does static link absorption (`T`) represent an undeniable single combined work under GPLv2/GPLv3 §5, eliminating any dynamic linking legal defense?

**Q1.2**: If `libgpl` were licensed under LGPLv2.1 instead of GPLv2, what requirement must the developer satisfy if they distribute `app_static` to end-users without releasing `app.c` source code?

---

#### Exercise 2: Automated Container SBOM Analysis & CI Compliance Enforcement

##### Objective
Configure an automated Software Bill of Materials (SBOM) scanner using Anchore `syft` and Aqua `trivy` to audit container filesystem layers for high-risk strong copyleft (AGPLv3/GPLv3) packages within enterprise deployment artifacts.

##### Steps to Execute

1. Navigate to the exercise workspace and create a mock Node.js project containing mixed dependencies (Permissive, Weak Copyleft, and AGPL Copyleft):

```bash
mkdir -p ~/license-audit-lab/ex2 && cd ~/license-audit-lab/ex2

cat << 'EOF' > package.json
{
  "name": "microservice-api",
  "version": "2.4.0",
  "private": true,
  "dependencies": {
    "express": "^4.18.2",
    "agpl-pdf-generator": "1.0.0",
    "lgpl-string-utils": "2.1.0"
  }
}
EOF

mkdir -p node_modules/express node_modules/agpl-pdf-generator node_modules/lgpl-string-utils

# Mock Express (MIT)
cat << 'EOF' > node_modules/express/package.json
{ "name": "express", "version": "4.18.2", "license": "MIT" }
EOF

# Mock AGPL PDF Generator (AGPL-3.0-only)
cat << 'EOF' > node_modules/agpl-pdf-generator/package.json
{ "name": "agpl-pdf-generator", "version": "1.0.0", "license": "AGPL-3.0-only" }
EOF

# Mock LGPL String Utils (LGPL-3.0-or-later)
cat << 'EOF' > node_modules/lgpl-string-utils/package.json
{ "name": "lgpl-string-utils", "version": "2.1.0", "license": "LGPL-3.0-or-later" }
EOF
```

2. Construct a production container image using Docker/Podman or Dockerfile manifest:

```bash
cat << 'EOF' > Dockerfile
FROM alpine:3.19
RUN apk add --no-linux-headers --no-cache bash curl
WORKDIR /app
COPY package.json ./
COPY node_modules ./node_modules
CMD ["node", "server.js"]
EOF
```

3. Build the container image locally:

```bash
docker build -t microservice-api:2.4.0 .
```

4. Install `syft` (or use a local binary/container execution) to generate a standardized SPDX JSON SBOM:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /tmp/bin v1.0.0
/tmp/bin/syft microservice-api:2.4.0 -o spdx-json=sbom.spdx.json
```

5. Audit the generated SPDX document for AGPL licenses using `jq`:

```bash
jq '.packages[] | select(.licenseConcluded | contains("AGPL")) | {name: .name, versionInfo: .versionInfo, licenseConcluded: .licenseConcluded}' sbom.spdx.json
```

*Expected Output:*
```json
{
  "name": "agpl-pdf-generator",
  "versionInfo": "1.0.0",
  "licenseConcluded": "AGPL-3.0-only"
}
```

6. Formulate a Trivy license compliance configuration (`.trivyignore` or Trivy policy invocation) to break CI/CD pipelines if AGPL-3.0 licenses are present:

```bash
cat << 'EOF' > trivy-license-policy.yaml
license:
  severities:
    - CRITICAL
  forbidden:
    - AGPL-1.0-only
    - AGPL-1.0-or-later
    - AGPL-3.0-only
    - AGPL-3.0-or-later
    - GPL-3.0-only
    - GPL-3.0-or-later
EOF

trivy image --config trivy-license-policy.yaml --scanners license microservice-api:2.4.0
```

*Expected CLI Output:*
```text
2026-08-06T19:04:00.000Z	[INFO] License scanning is enabled
2026-08-06T19:04:00.120Z	[WARN] Number of language-specific files: 1

node_modules/agpl-pdf-generator (Node.js)
==========================================
Total: 1 (UNKNOWN: 0, LOW: 0, MEDIUM: 0, HIGH: 0, CRITICAL: 1)

CRITICAL: AGPL-3.0-only license found in agpl-pdf-generator@1.0.0
Classification: Forbidden License Category (AGPL-3.0)
Action Required: Remove dependency or isolate behind process network boundary.
```

##### Verification Questions

**Q2.1**: A SaaS backend service dynamically imports `agpl-pdf-generator` inside its Node.js container process to render invoices. The container is never distributed to clients, but exposed over HTTP APIs. Why does this deployment trigger a legal violation under AGPLv3 §13, while standard GPLv3 §13 would remain un-triggered in the exact same cloud deployment mode?

**Q2.2**: If the SRE team rewrites `agpl-pdf-generator` integration into a separate, isolated microservice running in its own Kubernetes Pod, exposed strictly via gRPC over TCP, does the primary Node.js API service inherit the AGPLv3 source code disclosure obligation? Explain the architectural rationale.

---

#### Exercise 3: File-Level vs. Strong Copyleft Isolation Auditing (MPL-2.0 / EPL-2.0)

##### Objective
Demonstrate the operational difference between File-Level (Weak) Copyleft (MPL-2.0) and Strong Copyleft (GPLv3) when modifying upstream open-source source files alongside proprietary project files.

##### Steps to Execute

1. Setup the exercise directory structure:

```bash
mkdir -p ~/license-audit-lab/ex3 && cd ~/license-audit-lab/ex3
```

2. Create a modified upstream file under Mozilla Public License 2.0 (`mpl_utility.go`):

```bash
cat << 'EOF' > mpl_utility.go
// Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

package main

import "fmt"

// Modified Upstream Function
func MPLOptimizedBuffer() {
    fmt.Println("[MPL-2.0] High performance ring buffer v2")
}
EOF
```

3. Create a proprietary application file in the same package/directory (`proprietary_logic.go`):

```bash
cat << 'EOF' > proprietary_logic.go
// Copyright 2026 Enterprise Corp. All Rights Reserved.
// Proprietary and Confidential.

package main

import "fmt"

func ExecuteTradeEngine() {
    fmt.Println("[PROPRIETARY] Executing algorithmic trading strategy...")
    MPLOptimizedBuffer()
}

func main() {
    ExecuteTradeEngine()
}
EOF
```

4. Build the binary and generate source package distributions:

```bash
go build -o trading_engine .
./trading_engine
```

*Expected Output:*
```text
[PROPRIETARY] Executing algorithmic trading strategy...
[MPL-2.0] High performance ring buffer v2
```

##### Verification Questions

**Q3.1**: Under MPL-2.0 Section 3.1 & 3.2, if Enterprise Corp distributes the compiled `trading_engine` binary to third-party clients, which specific files must be made publicly available under the MPL-2.0 license terms?

**Q3.2**: If `mpl_utility.go` were instead licensed under GPLv3, how would the source code disclosure obligation change regarding `proprietary_logic.go` upon distribution of `trading_engine`?

---

#### Exercise 4: SPDX License Identifier Validation and Compliance Linters

##### Objective
Audit, enforce, and validate standardized Software Package Data Exchange (SPDX) short identifiers in multi-language codebase header declarations using the `reuse` compliance tool.

##### Steps to Execute

1. Install the Free Software Foundation Europe `reuse` tool in a virtual environment:

```bash
mkdir -p ~/license-audit-lab/ex4 && cd ~/license-audit-lab/ex4
python3 -m venv venv
./venv/bin/pip install reuse
```

2. Create compliant and non-compliant source files:

```bash
# File A: Valid SPDX GPL-3.0 Header
cat << 'EOF' > compliant_gpl.py
# SPDX-FileCopyrightText: 2026 SRE Platform Team <sre@example.com>
# SPDX-License-Identifier: GPL-3.0-or-later

def engine_init():
    print("GPL Engine Ready")
EOF

# File B: Non-compliant missing copyright/license file
cat << 'EOF' > non_compliant.py
def orphan_function():
    pass
EOF
```

3. Execute `reuse lint` to inspect project compliance:

```bash
./venv/bin/reuse lint
```

*Expected Output:*
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: GPL-3.0-or-later
* Files with copyright information: 1 / 2
* Files with license information: 1 / 2

FAIL: The project is not REUSE compliant.
Missing information for:
- non_compliant.py
```

4. Resolve the compliance failure by adding an explicit SPDX header using `reuse annotate`:

```bash
./venv/bin/reuse annotate --license GPL-3.0-or-later --copyright "2026 SRE Platform Team <sre@example.com>" non_compliant.py
./venv/bin/reuse lint
```

*Expected Output:*
```text
# Summary
* Bad licenses: 0
* Deprecated licenses: 0
* Licenses without file extension: 0
* Missing licenses: 0
* Unused licenses: 0
* Used licenses: GPL-3.0-or-later
* Files with copyright information: 2 / 2
* Files with license information: 2 / 2

Congratulations! Your project is compliant with the REUSE specification :D
```

##### Verification Questions

**Q4.1**: What is the precise semantic difference between `GPL-3.0-only` and `GPL-3.0-or-later` according to the official SPDX license list schema?

**Q4.2**: Why is using standardized SPDX identifiers inside source code headers critical for automated SBOM tools (`syft`, `trivy`, `fossology`) in modern enterprise DevSecOps pipelines?

---

### Official Reference Sources
- Linux Professional Institute Open Source Essentials: https://www.lpi.org/our-certifications/open-source-essentials-overview/
- GNU General Public License v3.0 Text & FAQs: https://www.gnu.org/licenses/gpl-3.0.html
- GNU Affero General Public License v3.0: https://www.gnu.org/licenses/agpl-3.0.html
- Open Source Initiative (OSI) Licenses: https://opensource.org/licenses
- SPDX License List & Specification: https://spdx.dev/learn/handling-license-info/
- REUSE Specification (FSFE): https://reuse.software/spec/

---

<details>
<summary>Answers & Diagnostic Explanations</summary>

#### Answer to Q1.1
Static linking merges the compiled machine instructions of `libgpl.a` directly into the text segment (`T`) of `app_static`. The executable cannot function without this code embedded in its binary image. Under GPLv2 Section 2 and GPLv3 Section 5, this creates an undeniable combined work. The distribution of `app_static` triggers the full copyleft obligation: the source code of `app.c` must be disclosed under GPL. In dynamic linking, proponents sometimes argue that the binary on disk is distinct until runtime; however, with static linking, the physical binary artifact contains both parts fused together, destroying any legal separation defense.

#### Answer to Q1.2
LGPLv2.1 Section 6 permits static linking with proprietary code (`app.c`), provided that the vendor distributes the unlinked object files (`app.o`) or full source of `app.c` alongside the static library (`libgpl.a`). This allows downstream users to modify `libgpl` and relink the binary manually. Alternatively, if dynamic linking (`.so`) is used under LGPL, the vendor is not required to provide `app.c` object files at all.

#### Answer to Q2.1
Standard GPLv3 §13 obligation triggers **only when the program is conveyed (distributed)**. Because the container runs in a cloud data center and only exposes HTTP network endpoints, no conveyance of software binaries takes place under GPLv3. In contrast, AGPLv3 Section 13 explicitly defines remote network interaction over a computer network as a trigger condition. Running modified AGPLv3 software on a network server requires making the complete corresponding source code accessible for download to all remote users interacting with that service via HTTP/gRPC.

#### Answer to Q2.2
No, the primary Node.js API service does not inherit the AGPLv3 copyleft obligation. Operating across network sockets (gRPC/HTTP) between decoupled OS processes establishes a process boundary. Because the Node.js API and the AGPL service interact as separate programs via standard remote procedure calls—without sharing memory address space, database schemas, or internal data structures—they do not form a single combined work under legal copyleft interpretation. Only the isolated AGPL microservice must have its source code made available.

#### Answer to Q3.1
Under MPL-2.0 Section 3.1, copyleft reciprocity is strictly **file-scoped**. Enterprise Corp must publicly disclose modifications made to `mpl_utility.go` under the MPL-2.0 license. However, `proprietary_logic.go` is a separate file and is not a modification of MPL code; therefore, it remains completely proprietary, and its source code does not need to be disclosed.

#### Answer to Q3.2
If `mpl_utility.go` were licensed under GPLv3, compiling `mpl_utility.go` and `proprietary_logic.go` into a single Go binary creates a single combined work. GPLv3 strong copyleft propagates across all files within the binary compilation unit. As a result, Enterprise Corp would be legally obligated to release `proprietary_logic.go` under GPLv3 upon distributing `trading_engine`.

#### Answer to Q4.1
`GPL-3.0-only` restricts downstream users to the terms of GPL Version 3.0 exclusively. `GPL-3.0-or-later` gives downstream users the legal option to apply the terms of any future version of the GNU General Public License published by the Free Software Foundation (e.g., GPLv4). `GPL-3.0-or-later` improves long-term license compatibility with future copyleft revisions.

#### Answer to Q4.2
Automated SBOM analysis tools rely on deterministic parsing of source headers and package metadata. Arbitrary or missing text strings force tools to rely on heavy natural language processing (NLP) heuristics, which frequently generate false positives or false negatives during CI compliance checks. Standardized SPDX short identifiers (`SPDX-License-Identifier: <ID>`) allow scanners to instantly resolve precise, unambiguous license machine-readable keys, enabling automated pipeline gates to enforce enterprise license policies accurately.

</details>