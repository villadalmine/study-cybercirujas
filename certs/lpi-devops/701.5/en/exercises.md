# 701.5 — Software Composition, Licensing and Open Source

## Guided Exercises

**Exam:** LPI DevOps Tools Engineer 701-100, version 2.0.0 · **Weight:** 3.34
**Objective reference:** <https://www.lpi.org/our-certifications/exam-701-objectives/>

These exercises are executable. Every command was written against a Linux x86_64 workstation with network access to public registries. Outputs shown are *illustrative*: version strings, vulnerability counts and digests change daily, so match the **shape** of the output, not the literal bytes.

---

## Lab environment

| Tool | Purpose | Upstream |
|---|---|---|
| `syft` | SBOM generation (SPDX, CycloneDX) | <https://github.com/anchore/syft> |
| `grype` | Vulnerability match against an SBOM | <https://github.com/anchore/grype> |
| `osv-scanner` | Vulnerability match against OSV.dev | <https://google.github.io/osv-scanner/> |
| `trivy` | Image scanning incl. license detection | <https://trivy.dev/> |
| `cosign` | Signing, attestation, verification | <https://docs.sigstore.dev/cosign/system_config/installation/> |
| `reuse` | REUSE 3.x compliance linting | <https://reuse.software/> |
| `jq` | JSON inspection | <https://jqlang.github.io/jq/> |

### Steps

1. Create an isolated workspace and record it as an environment variable used by every later exercise.

   ```bash
   export LAB=~/lab-701.5
   mkdir -p "$LAB"/{bin,artifacts,app}
   cd "$LAB"
   export PATH="$LAB/bin:$PATH"
   ```

2. Install the Anchore tools into the lab-local `bin/` so nothing lands in system paths.

   ```bash
   curl -sSfL https://get.anchore.io/syft  | sh -s -- -b "$LAB/bin"
   curl -sSfL https://get.anchore.io/grype | sh -s -- -b "$LAB/bin"
   ```

3. Install the remaining tools. Prefer your distribution's packages where they exist; the fallbacks below are upstream release binaries.

   ```bash
   # Trivy (Aqua Security) — see https://trivy.dev/latest/getting-started/installation/
   curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
     | sh -s -- -b "$LAB/bin"

   # Cosign (Sigstore)
   curl -sSfLo "$LAB/bin/cosign" \
     https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
   chmod +x "$LAB/bin/cosign"

   # OSV-Scanner (Google)
   curl -sSfLo "$LAB/bin/osv-scanner" \
     https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64
   chmod +x "$LAB/bin/osv-scanner"

   # REUSE tool (FSFE)
   python3 -m venv "$LAB/.venv" && "$LAB/.venv/bin/pip" -q install reuse
   ln -sf "$LAB/.venv/bin/reuse" "$LAB/bin/reuse"
   ```

4. Verify the toolchain answers.

   ```bash
   for t in syft grype trivy cosign osv-scanner reuse; do printf '%-12s ' "$t"; "$t" --version 2>&1 | head -1; done
   ```

   ```text
   syft         syft 1.18.1
   grype        grype 0.87.0
   trivy        Version: 0.58.2
   cosign       GitVersion:    v2.4.1
   osv-scanner  osv-scanner version: 1.9.2
   reuse        reuse 5.0.2
   ```

> **Comprehension check — Block 0**
>
> **Q0.1** All six tools above are downloaded over HTTPS from a vendor endpoint and executed immediately. Name the supply-chain risk this introduces and the two verification artifacts you would demand before running any of them in a CI pipeline.
> **Q0.2** Why is a tool-local `bin/` with a prepended `PATH` the correct pattern for a lab, and what production anti-pattern does it mirror if you do the same thing inside a build image?

---

## Exercise 1 — Build a polyglot project and generate its SBOM in both formats

The point of this exercise is that **SBOM format is a serialization choice, not a semantic one** — but the two dominant formats disagree about how much they let you say.

### Steps

1. Create a small Python application with pinned, deliberately mixed-license dependencies.

   ```bash
   cd "$LAB/app"
   cat > requirements.txt <<'EOF'
   requests==2.31.0
   Flask==2.2.5
   PyYAML==6.0.1
   paramiko==3.4.0
   chardet==5.2.0
   EOF
   ```

2. Materialize the dependency tree into a virtualenv so the scanner has real installed metadata to read (not just a declaration file).

   ```bash
   python3 -m venv "$LAB/app/.venv"
   "$LAB/app/.venv/bin/pip" -q install -r requirements.txt
   "$LAB/app/.venv/bin/pip" list --format=freeze | wc -l
   ```

   ```text
   17
   ```

3. Generate a **CycloneDX** SBOM (OWASP; standardized as ECMA-424) and an **SPDX** SBOM (Linux Foundation; SPDX 2.2.1 is ISO/IEC 5962:2021) from the same directory.

   ```bash
   cd "$LAB"
   syft dir:"$LAB/app" -o cyclonedx-json="$LAB/artifacts/app.cdx.json" \
                       -o spdx-json="$LAB/artifacts/app.spdx.json" \
                       -o table
   ```

   ```text
    ✔ Indexed file system                    /home/user/lab-701.5/app
    ✔ Cataloged contents      3f7c1a2b9e04d5c6a8b1f0e2d3c4b5a6978869fa0b1c2d3e4f5061728394a5b6
      ├── ✔ Packages                        [17 packages]
      └── ✔ Executables                     [0 executables]

   NAME                VERSION   TYPE
   Flask               2.2.5     python
   Jinja2              3.1.4     python
   MarkupSafe          2.1.5     python
   PyNaCl              1.5.0     python
   PyYAML              6.0.1     python
   Werkzeug            3.0.6     python
   bcrypt              4.2.0     python
   certifi             2024.8.30 python
   cffi                1.17.1    python
   chardet             5.2.0     python
   charset-normalizer  3.4.0     python
   cryptography        43.0.1    python
   idna                3.10      python
   paramiko            3.4.0     python
   pycparser           2.22      python
   requests            2.31.0    python
   urllib3             2.2.3     python
   ```

4. Compare the two documents' top-level identity metadata.

   ```bash
   jq '{format: .bomFormat, spec: .specVersion, serial: .serialNumber, tool: .metadata.tools}' \
     "$LAB/artifacts/app.cdx.json"
   jq '{spdxVersion, dataLicense, name: .name, ns: .documentNamespace, creators: .creationInfo.creators}' \
     "$LAB/artifacts/app.spdx.json"
   ```

   ```text
   {
     "format": "CycloneDX",
     "spec": "1.6",
     "serial": "urn:uuid:6b0f2e5a-9c31-4c0a-9a7d-2e51f8c0b4d1",
     "tool": { "components": [ { "type": "application", "name": "syft", "version": "1.18.1" } ] }
   }
   {
     "spdxVersion": "SPDX-2.3",
     "dataLicense": "CC0-1.0",
     "name": "/home/user/lab-701.5/app",
     "ns": "https://anchore.com/syft/dir/home/user/lab-701.5/app-1c9a...",
     "creators": [ "Organization: Anchore, Inc", "Tool: syft-1.18.1" ]
   }
   ```

5. Count components in each and confirm they agree.

   ```bash
   jq '.components | length' "$LAB/artifacts/app.cdx.json"
   jq '[.packages[] | select(.name != "app")] | length' "$LAB/artifacts/app.spdx.json"
   ```

   ```text
   17
   17
   ```

> **Comprehension check — Block 1**
>
> **Q1.1** `dataLicense` in the SPDX document is `CC0-1.0` and the SPDX specification *requires* that value. What problem is that constraint solving, and why would `"dataLicense": "Proprietary"` defeat the purpose of publishing an SBOM at all?
> **Q1.2** The CycloneDX document carries a `serialNumber` (a UUID URN) and SPDX carries a `documentNamespace` (a URI). Both are mandatory. What identity property do they provide that a filename cannot, and why does it matter when the same artifact is rebuilt nightly?
> **Q1.3** Step 2 installs the dependencies before scanning. If you had scanned only `requirements.txt`, `syft` would still have produced an SBOM. Name two concrete accuracy differences between an SBOM derived from a declaration file and one derived from an installed tree.
> **Q1.4** Which of these two formats would you choose to carry a *vulnerability* section inside the SBOM itself, and why is that even a question?

---

## Exercise 2 — Read the SBOM like an auditor: purl, CPE, and license fields

An SBOM is only useful if each component is *identifiable* and *attributable*. This exercise separates the two.

### Steps

1. Extract the Package URL (purl) for every component. The purl spec is at <https://github.com/package-url/purl-spec>.

   ```bash
   jq -r '.components[] | "\(.purl)"' "$LAB/artifacts/app.cdx.json" | sort | head -6
   ```

   ```text
   pkg:pypi/bcrypt@4.2.0
   pkg:pypi/certifi@2024.8.30
   pkg:pypi/cffi@1.17.1
   pkg:pypi/charset-normalizer@3.4.0
   pkg:pypi/chardet@5.2.0
   pkg:pypi/cryptography@43.0.1
   ```

2. Now pull the declared licenses, and note that some components report an SPDX **id**, some an SPDX **expression**, and some only free text.

   ```bash
   jq -r '.components[] | [.name, ( .licenses // [] | map(.license.id // .license.name // .expression) | join(" | ") )] | @tsv' \
     "$LAB/artifacts/app.cdx.json" | column -t -s $'\t'
   ```

   ```text
   Flask               BSD-3-Clause
   Jinja2              BSD-3-Clause
   MarkupSafe          BSD-3-Clause
   PyNaCl              Apache-2.0
   PyYAML              MIT
   Werkzeug            BSD-3-Clause
   bcrypt              Apache-2.0
   certifi             MPL-2.0
   cffi                MIT
   chardet             LGPL-2.1-or-later
   charset-normalizer  MIT
   cryptography        Apache-2.0 OR BSD-3-Clause
   idna                BSD-3-Clause
   paramiko            LGPL-2.1-or-later
   pycparser           BSD-3-Clause
   requests            Apache-2.0
   urllib3             MIT
   ```

3. Isolate the components that are **not** permissive — this is the list that generates obligations.

   ```bash
   jq -r '.components[] | select( (.licenses // []) | tostring | test("GPL|MPL|EPL|CDDL"; "i") ) | "\(.name)\t\(.version)"' \
     "$LAB/artifacts/app.cdx.json"
   ```

   ```text
   certifi   2024.8.30
   chardet   5.2.0
   paramiko  3.4.0
   ```

4. Confirm the machine-readable license identifiers are valid SPDX identifiers against the official list at <https://spdx.org/licenses/>.

   ```bash
   curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json \
     | jq -r '.licenses[] | select(.licenseId=="LGPL-2.1-or-later" or .licenseId=="MPL-2.0" or .licenseId=="BSD-3-Clause")
              | [.licenseId, (.isOsiApproved|tostring), (.isFsfLibre|tostring), (.isDeprecatedLicenseId|tostring)] | @tsv'
   ```

   ```text
   BSD-3-Clause        true   true   false
   LGPL-2.1-or-later   true   true   false
   MPL-2.0             true   true   false
   ```

5. Demonstrate the deprecation trap. `LGPL-2.1` (bare) and `GPL-2.0` (bare) are **deprecated** identifiers because they are ambiguous about the "or later" clause.

   ```bash
   curl -s https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json \
     | jq -r '.licenses[] | select(.isDeprecatedLicenseId==true and (.licenseId|test("^(GPL|LGPL|AGPL)-[0-9]")))
              | [.licenseId, .name] | @tsv' | head -6
   ```

   ```text
   AGPL-1.0    Affero General Public License v1.0
   AGPL-3.0    GNU Affero General Public License v3.0
   GPL-2.0     GNU General Public License v2.0
   GPL-3.0     GNU General Public License v3.0
   LGPL-2.1    GNU Lesser General Public License v2.1
   ```

> **Comprehension check — Block 2**
>
> **Q2.1** `cryptography` reports `Apache-2.0 OR BSD-3-Clause`. As the downstream consumer, what does the `OR` obligate you to do, and what would `AND` have obligated instead? Which one do you record in your compliance inventory?
> **Q2.2** Explain precisely why SPDX deprecated the bare `GPL-2.0` identifier in favour of `GPL-2.0-only` and `GPL-2.0-or-later`. Give a licensing decision that changes depending on which one is true.
> **Q2.3** A purl is `pkg:pypi/requests@2.31.0`; a CPE for the same component might be `cpe:2.3:a:python:requests:2.31.0:*:*:*:*:*:*:*`. Which identifier drives *dependency* resolution and which drives *vulnerability* matching, and what failure mode appears when a tool only has one of them?
> **Q2.4** `isOsiApproved` and `isFsfLibre` are separate booleans in the SPDX license list. Why are they not the same field?

---

## Exercise 3 — Make *your own* repository compliant: SPDX headers and REUSE

Consuming open source is half the objective. Publishing it correctly is the other half.

### Steps

1. Initialize a repository for your application and write a source file with **no** licensing information — the starting state of most projects.

   ```bash
   cd "$LAB/app"
   git init -q
   cat > server.py <<'EOF'
   from flask import Flask
   app = Flask(__name__)

   @app.get("/healthz")
   def healthz():
       return {"status": "ok"}, 200
   EOF
   reuse lint
   ```

   ```text
   # MISSING COPYRIGHT AND LICENSING INFORMATION

   The following files have no copyright and licensing information:
   * requirements.txt
   * server.py

   # SUMMARY

   * Bad licenses: 0
   * Deprecated licenses: 0
   * Licenses without file extension: 0
   * Missing licenses: 0
   * Unused licenses: 0
   * Used licenses:
   * Read errors: 0
   * Files with copyright information: 0 / 2
   * Files with license information: 0 / 2

   Unfortunately, your project is not compliant with version 3.3 of the REUSE Specification :-(
   ```

2. Download the full license text into the `LICENSES/` directory the REUSE specification mandates (<https://reuse.software/spec/>).

   ```bash
   reuse download Apache-2.0
   ls LICENSES/
   ```

   ```text
   Successfully downloaded LICENSES/Apache-2.0.txt.
   Apache-2.0.txt
   ```

3. Annotate every file with a machine-readable copyright line and an `SPDX-License-Identifier` tag.

   ```bash
   reuse annotate --copyright="ACME Platform Engineering <platform@acme.example>" \
                  --license=Apache-2.0 --year=2026 \
                  server.py requirements.txt
   head -3 server.py
   ```

   ```text
   # SPDX-FileCopyrightText: 2026 ACME Platform Engineering <platform@acme.example>
   #
   # SPDX-License-Identifier: Apache-2.0
   ```

4. Handle a file that cannot carry a comment header — a binary asset — using `REUSE.toml` (REUSE 3.2+ replacement for `.reuse/dep5`).

   ```bash
   mkdir -p assets && head -c 512 /dev/urandom > assets/logo.png
   cat > REUSE.toml <<'EOF'
   version = 1

   [[annotations]]
   path = "assets/**"
   precedence = "aggregate"
   SPDX-FileCopyrightText = "2026 ACME Platform Engineering <platform@acme.example>"
   SPDX-License-Identifier = "CC-BY-4.0"
   EOF
   reuse download CC-BY-4.0
   reuse lint | tail -12
   ```

   ```text
   * Bad licenses: 0
   * Deprecated licenses: 0
   * Licenses without file extension: 0
   * Missing licenses: 0
   * Unused licenses: 0
   * Used licenses: Apache-2.0, CC-BY-4.0
   * Read errors: 0
   * Files with copyright information: 4 / 4
   * Files with license information: 4 / 4

   Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)
   ```

5. Emit an SBOM **of your own project's licensing** — REUSE can produce an SPDX document directly, which is the artifact you attach to a release.

   ```bash
   reuse spdx -o "$LAB/artifacts/reuse.spdx"
   grep -E '^(PackageName|LicenseInfoInFile|FileName)' "$LAB/artifacts/reuse.spdx" | head -8
   ```

   ```text
   PackageName: app
   FileName: ./server.py
   LicenseInfoInFile: Apache-2.0
   FileName: ./requirements.txt
   LicenseInfoInFile: Apache-2.0
   FileName: ./assets/logo.png
   LicenseInfoInFile: CC-BY-4.0
   ```

6. Add the contribution-provenance control. Configure DCO sign-off (<https://developercertificate.org/>) and prove it lands in the commit object.

   ```bash
   git config user.name "Platform Engineer"
   git config user.email "platform@acme.example"
   git add -A && git commit -q -s -m "feat: add health endpoint and REUSE compliance"
   git log -1 --format='%B'
   ```

   ```text
   feat: add health endpoint and REUSE compliance

   Signed-off-by: Platform Engineer <platform@acme.example>
   ```

7. Enforce it mechanically, the way a CI gate would.

   ```bash
   git log --format='%H %(trailers:key=Signed-off-by,valueonly)' -1 \
     | awk 'NF<2 {print "DCO MISSING on "$1; exit 1} {print "DCO OK"}'
   ```

   ```text
   DCO OK
   ```

> **Comprehension check — Block 3**
>
> **Q3.1** A single `SPDX-License-Identifier: Apache-2.0` line at the top of a file is a *tag*, not a license. What else must be present in the repository for the tag to be legally meaningful, and which REUSE rule enforces it?
> **Q3.2** Your `assets/` entry uses `precedence = "aggregate"`. What would change if a `logo.png.license` sidecar file existed at the same time, and why does REUSE define a precedence at all?
> **Q3.3** Distinguish a **DCO sign-off** from a **CLA**. For each, state who is making an assertion, what is being asserted, and whether copyright is transferred or licensed.
> **Q3.4** `git commit -s` and `git commit -S` differ by one bit of case. Explain what each does and why a DCO gate that accepts `-s` alone still leaves an authorship-forgery hole.

---

## Exercise 4 — Composition analysis: correlate the SBOM against vulnerability data

Software composition analysis (SCA) is the *join* between "what is in it" and "what is known about it". Keep those two datasets separate — that is the whole architectural point of an SBOM.

### Steps

1. Match your existing SBOM against Grype's database. Note that you scan the **SBOM**, not the filesystem: no rebuild, no source access needed.

   ```bash
   grype sbom:"$LAB/artifacts/app.cdx.json" -o table
   ```

   ```text
   NAME        INSTALLED   FIXED-IN   TYPE    VULNERABILITY        SEVERITY
   Werkzeug    3.0.6       3.0.6      python  GHSA-f9vj-2wh5-fj8j  Medium
   requests    2.31.0      2.32.0     python  GHSA-9wx4-h78v-vm56  Medium
   requests    2.31.0      2.32.4     python  GHSA-9hjg-9r4m-mvj7  Medium
   cryptography 43.0.1     44.0.1     python  GHSA-79v4-65xg-pq4g  Medium
   paramiko    3.4.0       (none)     python  GHSA-...             Low
   ```

2. Cross-check with a second, independently-sourced database — OSV.dev (<https://osv.dev/>) — because vulnerability feeds disagree.

   ```bash
   osv-scanner --sbom="$LAB/artifacts/app.cdx.json" 2>/dev/null | head -20
   ```

   ```text
   ╭─────────────────────────────────────┬──────┬───────────┬─────────┬─────────┬──────────────╮
   │ OSV URL                             │ CVSS │ ECOSYSTEM │ PACKAGE │ VERSION │ SOURCE       │
   ├─────────────────────────────────────┼──────┼───────────┼─────────┼─────────┼──────────────┤
   │ https://osv.dev/GHSA-9wx4-h78v-vm56 │ 6.1  │ PyPI      │ requests│ 2.31.0  │ app.cdx.json │
   │ https://osv.dev/GHSA-9hjg-9r4m-mvj7 │ 5.3  │ PyPI      │ requests│ 2.31.0  │ app.cdx.json │
   ╰─────────────────────────────────────┴──────┴───────────┴─────────┴─────────┴──────────────╯
   ```

3. Pull the authoritative record for one finding and read the CVSS **vector**, not the number. CVSS is specified by FIRST at <https://www.first.org/cvss/>.

   ```bash
   curl -s https://api.osv.dev/v1/vulns/GHSA-9wx4-h78v-vm56 \
     | jq '{id, aliases, severity, affected: [.affected[].ranges[].events]}'
   ```

   ```text
   {
     "id": "GHSA-9wx4-h78v-vm56",
     "aliases": ["CVE-2024-35195"],
     "severity": [
       { "type": "CVSS_V3", "score": "CVSS:3.1/AV:N/AC:H/PR:H/UI:N/S:U/C:H/I:N/A:N" }
     ],
     "affected": [[ {"introduced": "0"}, {"fixed": "2.32.0"} ]]
   }
   ```

4. Decide whether the finding is *reachable* in your deployment, then suppress it honestly with a **VEX** statement (OpenVEX: <https://github.com/openvex/spec>) rather than by editing the scanner config.

   ```bash
   cat > "$LAB/artifacts/app.openvex.json" <<'EOF'
   {
     "@context": "https://openvex.dev/ns/v0.2.0",
     "@id": "https://acme.example/vex/app-2026-09-01",
     "author": "ACME Platform Engineering <platform@acme.example>",
     "timestamp": "2026-09-01T10:00:00Z",
     "version": 1,
     "statements": [
       {
         "vulnerability": { "name": "CVE-2024-35195" },
         "products": [ { "@id": "pkg:pypi/requests@2.31.0" } ],
         "status": "not_affected",
         "justification": "vulnerable_code_not_in_execute_path",
         "impact_statement": "The application never sets Session.verify=False; the affected code path is unreachable."
       }
     ]
   }
   EOF
   grype sbom:"$LAB/artifacts/app.cdx.json" --vex "$LAB/artifacts/app.openvex.json" \
         --show-suppressed -o table | grep -i -A1 suppressed | head -4
   ```

   ```text
   requests  2.31.0  2.32.0  python  GHSA-9wx4-h78v-vm56  Medium (suppressed by VEX)
   ```

5. Make the gate deterministic for CI: fail only on severity at or above a threshold, and emit machine-readable output for the pipeline artifact store.

   ```bash
   grype sbom:"$LAB/artifacts/app.cdx.json" \
         --vex "$LAB/artifacts/app.openvex.json" \
         --fail-on high -o json > "$LAB/artifacts/grype.json"
   echo "exit=$?"
   jq '[.matches[] | .vulnerability.severity] | group_by(.) | map({sev: .[0], n: length})' "$LAB/artifacts/grype.json"
   ```

   ```text
   exit=0
   [ {"sev":"Low","n":1}, {"sev":"Medium","n":3} ]
   ```

> **Comprehension check — Block 4**
>
> **Q4.1** Grype reported `Werkzeug 3.0.6` as vulnerable with `FIXED-IN 3.0.6` — the installed version equals the fixed version. Name two mechanisms that produce this apparent contradiction and say which one is a defect in the *data*, not in the tool.
> **Q4.2** Decode `CVSS:3.1/AV:N/AC:H/PR:H/UI:N/S:U/C:H/I:N/A:N` metric by metric. Then argue why this base score is *not* sufficient to prioritize the finding in your backlog, and name two datasets that would improve the decision.
> **Q4.3** A VEX `not_affected` statement and a scanner ignore-rule both remove a finding from the report. State three properties VEX has that the ignore-rule does not.
> **Q4.4** `--fail-on high` returned exit code 0 with four open findings. Explain what security property this gate actually guarantees, and what it explicitly does not.
> **Q4.5** Why must the SBOM be generated at *build* time but the vulnerability scan re-run *continuously* against the stored SBOM?

---

## Exercise 5 — Copyleft inside a container image: obligations you inherit by shipping

Base images bring the license obligations your application code never had. This is the exercise most engineers get wrong in production.

### Steps

1. Generate an SBOM for two common base images and count components. Use pinned digests so the exercise is reproducible.

   ```bash
   syft alpine:3.20 -o spdx-json="$LAB/artifacts/alpine.spdx.json" -q
   syft debian:12-slim -o spdx-json="$LAB/artifacts/debian.spdx.json" -q
   jq '.packages | length' "$LAB/artifacts/alpine.spdx.json" "$LAB/artifacts/debian.spdx.json"
   ```

   ```text
   15
   93
   ```

2. Extract the declared license of every OS package in the Alpine image.

   ```bash
   jq -r '.packages[] | [.name, (.licenseDeclared // "NOASSERTION")] | @tsv' \
      "$LAB/artifacts/alpine.spdx.json" | sort | column -t -s $'\t'
   ```

   ```text
   alpine-baselayout        GPL-2.0-only
   alpine-baselayout-data   GPL-2.0-only
   alpine-keys              MIT
   apk-tools                GPL-2.0-only
   busybox                  GPL-2.0-only
   busybox-binsh            GPL-2.0-only
   ca-certificates-bundle   MPL-2.0 AND MIT
   libcrypto3               Apache-2.0
   libssl3                  Apache-2.0
   musl                     MIT
   musl-utils               MIT AND BSD-3-Clause AND GPL-2.0-or-later
   scanelf                  GPL-2.0-only
   ssl_client               GPL-2.0-only
   zlib                     Zlib
   ```

3. Use a second tool to corroborate, and to catch licenses that appear only in file headers rather than package metadata.

   ```bash
   trivy image --scanners license --license-full --severity HIGH,CRITICAL debian:12-slim 2>/dev/null | head -18
   ```

   ```text
   debian:12-slim (debian 12.8)
   ============================
   OS Packages (license)
   ┌──────────────┬──────────────┬──────────────────────────┬──────────┐
   │   Package    │   License    │      Classification      │ Severity │
   ├──────────────┼──────────────┼──────────────────────────┼──────────┤
   │ bash         │ GPL-3.0      │ restricted               │ HIGH     │
   │ coreutils    │ GPL-3.0      │ restricted               │ HIGH     │
   │ gpgv         │ GPL-3.0      │ restricted               │ HIGH     │
   │ libgcrypt20  │ LGPL-2.1     │ reciprocal               │ MEDIUM   │
   │ tar          │ GPL-3.0      │ restricted               │ HIGH     │
   └──────────────┴──────────────┴──────────────────────────┴──────────┘
   ```

4. Produce the artifact that actually satisfies the obligation: a per-component attribution inventory shipped alongside the image.

   ```bash
   jq -r '["component","version","license","supplier"], (.packages[] |
          [.name, .versionInfo, (.licenseDeclared // "NOASSERTION"), (.supplier // "NOASSERTION")]) | @csv' \
      "$LAB/artifacts/alpine.spdx.json" > "$LAB/artifacts/THIRD-PARTY-NOTICES.csv"
   head -4 "$LAB/artifacts/THIRD-PARTY-NOTICES.csv"
   ```

   ```text
   "component","version","license","supplier"
   "busybox","1.36.1-r29","GPL-2.0-only","Organization: Alpine Linux"
   "musl","1.2.5-r0","MIT","Organization: Alpine Linux"
   "libssl3","3.3.2-r0","Apache-2.0","Organization: Alpine Linux"
   ```

5. Verify that the corresponding source is actually retrievable — the obligation is source *availability*, not a URL you hope still works.

   ```bash
   curl -sI https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/busybox-1.36.1-r29.apk \
     | head -1
   ```

   ```text
   HTTP/2 200
   ```

> **Comprehension check — Block 5**
>
> **Q5.1** Your proprietary Python application runs in a container built `FROM alpine:3.20`. That image contains `busybox` under `GPL-2.0-only`. Does the GPL obligate you to release your application's source code? Justify the answer using the concepts of *aggregation* and *derivative work*.
> **Q5.2** Pushing that image to a public registry — is it "distribution" in the licence sense? What concretely must you make available at that moment, and for how long does GPL-2.0 §3(b) bind a written offer?
> **Q5.3** `musl-utils` is `MIT AND BSD-3-Clause AND GPL-2.0-or-later`. Contrast the obligation created by this `AND` expression with the `OR` you saw in Exercise 2.
> **Q5.4** Trivy classifies GPL-3.0 as `restricted` and LGPL-2.1 as `reciprocal`. Explain the engineering difference between the two for a binary you link against, and what LGPL §6 / LGPL-3 §4 require you to enable for your users.
> **Q5.5** Your service is a public SaaS API. It never ships a binary to anyone. Which single licence family destroys the assumption that "we don't distribute, so no copyleft obligations apply", and by which clause?
> **Q5.6** A component reports `licenseDeclared: NOASSERTION`. Why is this *worse* than a component declaring GPL-3.0, from a release-gate perspective?

---

## Exercise 6 — Provenance: sign the artifact and attest the SBOM

An SBOM you cannot authenticate is a text file someone sent you. This closes the loop between composition and supply-chain integrity.

### Steps

1. Verify an existing keyless signature to see the trust model before producing one. Sigstore documents this example at <https://docs.sigstore.dev/>.

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-identity=keyless@distroless.iam.gserviceaccount.com \
     --certificate-oidc-issuer=https://accounts.google.com 2>&1 | head -8
   ```

   ```text
   Verification for gcr.io/distroless/static-debian12:latest --
   The following checks were performed on each of these signatures:
     - The cosign claims were validated
     - Existence of the claims in the transparency log was verified offline
     - The code-signing certificate was verified using trusted certificate authority certificates
   ```

2. Note what the two mandatory flags do. Remove one and observe the failure — this is the single most common misconfiguration in cosign verification.

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-oidc-issuer=https://accounts.google.com 2>&1 | tail -2
   ```

   ```text
   Error: --certificate-identity or --certificate-identity-regexp is required for verification in keyless mode
   main.go:74: error during command execution: ...
   ```

3. Inspect the transparency-log entry backing a signature. Rekor is the append-only log (<https://docs.sigstore.dev/logging/overview/>).

   ```bash
   cosign verify gcr.io/distroless/static-debian12 \
     --certificate-identity=keyless@distroless.iam.gserviceaccount.com \
     --certificate-oidc-issuer=https://accounts.google.com -o json 2>/dev/null \
     | jq -r '.[0].optional | {logIndex: .Bundle.Payload.logIndex, integratedTime: .Bundle.Payload.integratedTime, issuer: .Issuer, subject: .Subject}'
   ```

   ```text
   {
     "logIndex": 148903771,
     "integratedTime": 1735689421,
     "issuer": "https://accounts.google.com",
     "subject": "keyless@distroless.iam.gserviceaccount.com"
   }
   ```

4. Produce your own signed **attestation** binding the SBOM to an image digest. Use a local key pair so the exercise runs without an OIDC flow; production pipelines use keyless with a workload identity instead.

   ```bash
   cd "$LAB/artifacts"
   COSIGN_PASSWORD="" cosign generate-key-pair
   # Attest an SBOM as an in-toto predicate against a digest you control:
   # cosign attest --key cosign.key --predicate app.cdx.json \
   #               --type cyclonedx ghcr.io/acme/app@sha256:<digest>
   ls cosign.key cosign.pub
   ```

   ```text
   Private key written to cosign.key
   Public key written to cosign.pub
   cosign.key
   cosign.pub
   ```

5. Verify an attestation and extract the predicate back out — the round trip a consumer performs.

   ```bash
   # cosign verify-attestation --key cosign.pub --type cyclonedx \
   #   ghcr.io/acme/app@sha256:<digest> \
   #   | jq -r '.payload' | base64 -d | jq '{type: .predicateType, subject: .subject[0].name}'
   echo '{"predicateType":"https://cyclonedx.org/bom","subject":"ghcr.io/acme/app"}' | jq .
   ```

   ```text
   {
     "predicateType": "https://cyclonedx.org/bom",
     "subject": "ghcr.io/acme/app"
   }
   ```

6. Map your pipeline against SLSA build levels (<https://slsa.dev/spec/v1.0/levels>) and record the honest answer.

   ```bash
   cat > "$LAB/artifacts/slsa-self-assessment.md" <<'EOF'
   | Requirement                                   | Level | Status |
   |-----------------------------------------------|-------|--------|
   | Provenance exists and is distributed          | L1    | YES — cosign attest on every push |
   | Build runs on a hosted, isolated build service | L2    | YES — ephemeral CI runner |
   | Provenance signed by the build service         | L2    | YES — OIDC keyless, no long-lived key |
   | Build platform hardened; secrets non-forgeable | L3    | NO  — runners share a cache volume |
   EOF
   cat "$LAB/artifacts/slsa-self-assessment.md"
   ```

> **Comprehension check — Block 6**
>
> **Q6.1** In step 2, omitting `--certificate-identity` is a hard error. Explain what a verification that checked only "a valid Sigstore certificate signed this" would actually prove, and why that is nearly worthless.
> **Q6.2** Keyless signing issues a certificate valid for roughly ten minutes. If the certificate expired months ago, how can the signature still verify today? Name the component that makes this work and the property it provides.
> **Q6.3** Distinguish `cosign sign` from `cosign attest`. What is the *subject* in each case and what extra information does an attestation carry?
> **Q6.4** An attestation binds an SBOM to `sha256:<digest>`, not to the tag `:latest`. State the attack this prevents.
> **Q6.5** Your self-assessment claims SLSA L2 but not L3. Which specific threat does L3 address that L2 leaves open, and why does a shared cache volume between runners break it?
> **Q6.6** You verify an image's signature successfully and its SBOM attestation lists a component with a critical CVE. Did signature verification fail? Explain the relationship between *integrity* and *quality* in supply-chain controls.

---

## Cleanup

```bash
deactivate 2>/dev/null
rm -rf "$LAB"
docker image rm alpine:3.20 debian:12-slim 2>/dev/null || true
```

---

<details>
<summary><strong>Answers</strong></summary>

### Block 0

**A0.1** The risk is **unauthenticated code execution from a remote endpoint** — a classic supply-chain compromise vector: whoever controls the CDN, the DNS name, or the release pipeline controls what your machine executes as your user. `curl | sh` also composes badly with partial downloads, since the shell can execute a truncated script. Before running any of them in CI you should demand (1) a **checksum file plus a detached signature** over it (`*_checksums.txt` + `*_checksums.txt.sig`, verified against the vendor's published public key or via `cosign verify-blob` with a pinned `--certificate-identity`), and (2) a **pinned version and digest**, never `latest` — so the artifact you audited is the artifact you run. In practice you go one step further: vendor the verified binary into an internal registry or a purpose-built tool image, and have CI pull from there.

**A0.2** In a lab it is correct because it makes the whole installation **self-contained and reversible** — `rm -rf "$LAB"` removes every trace, nothing collides with distribution-managed binaries, and the exercise is reproducible on a machine you do not own. Inside a build image the same pattern becomes an anti-pattern: unversioned binaries fetched at build time into an ad-hoc `PATH` directory mean the image is **not reproducible** (the same Dockerfile yields different tool versions on different days), the tools are **invisible to your own SBOM scanners** (they carry no package-manager metadata, so `syft` catalogs them as bare executables at best), and you have inserted an unpinned network dependency into every build.

### Block 1

**A1.1** `CC0-1.0` is a public-domain dedication. The SPDX specification fixes `dataLicense` to `CC0-1.0` so that the **SBOM document itself** — as opposed to the software it describes — can always be copied, republished, aggregated and machine-processed by anyone, with no permission required. An SBOM's entire value is that it flows downstream: through your customer, their auditor, a CERT, a regulator. `"dataLicense": "Proprietary"` would make the document non-redistributable, meaning your customer could not forward it to *their* customer, an automated aggregator could not ingest it, and the transparency the artifact exists to provide would stop at the first recipient. It would also violate the spec, so conformant tooling should reject the document.

**A1.2** They provide **globally unique identity for a specific document instance**. A filename is neither unique nor stable — every nightly build writes `sbom.json`, and two different teams' `sbom.json` collide the moment they are stored together. The UUID/URI lets a consumer say "this vulnerability triage applies to SBOM `urn:uuid:6b0f…`", lets one document *reference* another (SPDX `ExternalDocumentRef`, CycloneDX `externalReferences`/BOM-Link), and lets you distinguish "the SBOM was regenerated" from "the software changed". For a nightly rebuild this is exactly what you need: identical component sets across two builds still yield two distinct document identities, so you can prove which scan ran against which build.

**A1.3** (1) **Transitive completeness.** `requirements.txt` in this lab lists 5 direct dependencies; the installed tree has 17 packages. A declaration-file scan misses the 12 transitive components, which is where most vulnerabilities and most copyleft surprises live. (2) **Version resolution.** A declaration may contain ranges (`Flask>=2.2`), so the scanner records a constraint rather than a fact; the installed tree records the exact version that was actually resolved on that platform, at that moment, for that Python version — including platform-conditional dependencies that would never appear in the declaration. A third real difference: an installed tree exposes the actual distribution metadata (`METADATA`, `RECORD`) with declared licenses and file hashes, which a `requirements.txt` simply does not have.

**A1.4** **CycloneDX**, because it was designed as a security-focused BOM and defines a first-class `vulnerabilities` array (plus VEX semantics) inside the document. It is a question at all because it is a genuine architectural disagreement: SPDX's model treats the SBOM as a *composition and licensing* record whose facts are stable for the life of the artifact, and vulnerability data as a separate, continuously-changing dataset joined to it at query time. The SPDX position is the safer default in practice — an SBOM with vulnerabilities baked in is stale the day after it is signed, and re-signing it on every NVD update is not viable. Use CycloneDX's inline vulnerabilities for a point-in-time report; keep the distributed, attested SBOM free of them.

### Block 2

**A2.1** `OR` is a **choice granted to you**: you may use `cryptography` under Apache-2.0 *or* under BSD-3-Clause, and you comply with exactly one. `AND` would have been **cumulative**: you must satisfy every listed licence's conditions simultaneously. In your compliance inventory you record **the licence you actually chose**, not the raw expression — because the obligations that flow downstream (attribution text, NOTICE propagation, patent grant scope) differ between the two. Here the choice is not cosmetic: Apache-2.0 §3 carries an express patent grant with a termination clause and §4 requires you to propagate the `NOTICE` file; BSD-3-Clause has neither, but adds a no-endorsement clause. Most organizations standardize on one for the whole inventory and document the decision.

**A2.2** Bare `GPL-2.0` was ambiguous about the **"or (at your option) any later version"** clause. The GPL's own §9/§14 text distinguishes a work licensed strictly under version 2 from one licensed under "version 2 or later", and that distinction is the licensee's, not a stylistic detail — so SPDX split it into `GPL-2.0-only` and `GPL-2.0-or-later` and deprecated the ambiguous form. The decision it changes: **combining the component with GPL-3.0-licensed code.** GPL-2.0-only is *incompatible* with GPL-3.0 — the two cannot be linked into one work, because each imposes conditions the other forbids adding. `GPL-2.0-or-later` lets the recipient elect GPL-3.0 and combine freely. Same for Apache-2.0: it is incompatible with GPL-2.0-only (its patent-termination and indemnity terms are "further restrictions" under GPLv2) but explicitly compatible one-way with GPL-3.0.

**A2.3** **purl drives dependency resolution**: it is a package-manager-native coordinate (`pkg:pypi/requests@2.31.0`) that unambiguously names where the artifact came from and how to fetch it. **CPE drives vulnerability matching** against NVD, whose records are indexed by CPE. The failure mode when a tool has only one: with **purl only**, you can query ecosystem-native feeds (OSV, GitHub Advisory) but you miss NVD entries that were never mapped to a purl. With **CPE only**, you get NVD coverage but suffer CPE's notorious ambiguity — vendor/product strings are assigned by humans, the same library appears under multiple CPEs, and unrelated products collide on a name — producing both false positives and silent false negatives. Serious scanners carry both and reconcile them, which is why `syft` emits both fields.

**A2.4** Because **OSI and the FSF are different organizations applying different criteria to different definitions.** OSI approves licences against the *Open Source Definition*; the FSF evaluates them against the *Free Software Definition* and additionally asks whether a licence is **GPL-compatible**. The sets overlap heavily but not completely — some licences are OSI-approved and considered non-free or GPL-incompatible by the FSF, and a few FSF-libre licences were never submitted to OSI. Modelling them as two booleans lets a policy engine express organizational rules precisely ("only OSI-approved" vs. "only GPL-compatible") instead of collapsing them into a single, wrong notion of "open source".

### Block 3

**A3.1** The **full licence text must exist in the repository**, in `LICENSES/Apache-2.0.txt`. A short identifier is a reference; the grant of rights is the licence text itself, and a recipient who gets your tarball with only the tag has received a pointer to a document they were not given. REUSE enforces this with its *Missing licenses* check — a file tagged `SPDX-License-Identifier: Apache-2.0` with no `LICENSES/Apache-2.0.txt` fails `reuse lint`. (The converse check, *Unused licenses*, catches licence texts you ship but no file claims — dead legal weight that confuses auditors.) Apache-2.0 additionally has §4 obligations around retaining notices and propagating any `NOTICE` file.

**A3.2** A `logo.png.license` **sidecar file always wins** over `REUSE.toml`. Precedence exists because the same file can be covered by information from several sources — a comment header, a sidecar, and one or more `REUSE.toml` entries — and a compliance tool must produce one deterministic answer. `precedence = "aggregate"` (the default) means the `REUSE.toml` entry applies only where the file has no information of its own; `precedence = "override"` makes the `REUSE.toml` entry win even over in-file tags, which is the escape hatch for third-party code you vendored and must not modify; `precedence = "closest"` picks the most specific matching path. Getting this wrong means your published SPDX document asserts a licence the file itself contradicts.

**A3.3** **DCO** (Developer Certificate of Origin 1.1): the **contributor** asserts, per commit, that they wrote the contribution or have the right to submit it under the project's existing licence, and that the contribution is a public record. Nothing is transferred and no new licence is granted — it is a *provenance attestation*, lightweight, verifiable from the commit trailer alone. **CLA** (Contributor License Agreement): the contributor **signs a separate legal agreement with the project's steward**, typically granting the steward a broad, irrevocable copyright *and patent* licence (a licence-CLA) or, in the aggressive form, **assigning copyright** to the steward (a CAA). The practical consequence is that a CLA lets the steward relicense or dual-license the project unilaterally; a DCO does not. That asymmetry is why CLAs are contentious and why the Linux kernel, GitLab and CNCF projects use the DCO.

**A3.4** `git commit -s` appends a textual `Signed-off-by:` trailer to the commit message — plain text, no cryptography. `git commit -S` creates a **GPG/SSH cryptographic signature** over the commit object, verifiable with `git log --show-signature`. The hole: `Signed-off-by:` is a string anyone can type, and `git commit --author` lets anyone set an arbitrary author. So a DCO gate that only greps for the trailer can be satisfied by a commit that forges another developer's name and email — the attestation names a person who never made it. Closing it requires binding identity cryptographically: `-S` with a key registered to the account, or a forge-side control (GitHub's verified-commits / required signatures, or an OIDC-authenticated push identity checked against the trailer).

### Block 4

**A4.1** (1) **Backported fixes in a repackaged distribution.** A distro or vendor patches the vulnerability without bumping the upstream version; the scanner compares upstream version strings and cannot see the patch. This is the tool behaving as designed against incomplete data. (2) **An advisory whose affected-range metadata is wrong** — the `fixed` event was recorded as `3.0.6` when the fix actually landed in `3.0.6` *plus* a later constraint, or the range was published as inclusive when it should be exclusive. That one is a **defect in the data**, in the advisory record itself, and the remedy is to file a correction against the advisory source (GHSA/OSV) rather than to tune your scanner. A third, less common cause: two distinct advisories for the same package where the tool merges rows.

**A4.2** `AV:N` attack vector Network — exploitable remotely. `AC:H` attack complexity High — the attacker needs conditions outside their control (here, a specific redirect/proxy configuration). `PR:H` privileges required High — the attacker must already hold elevated privileges on the component. `UI:N` no user interaction. `S:U` scope Unchanged — impact stays within the vulnerable component's security authority. `C:H` confidentiality High, `I:N` no integrity impact, `A:N` no availability impact. Base score ≈ 6.1 (Medium).
It is insufficient for prioritization because CVSS **base** deliberately describes the vulnerability in the abstract, with no knowledge of your deployment: it does not know whether the code path is reachable, whether the component is internet-facing, whether compensating controls exist, or whether anyone is actually exploiting it. Two datasets that improve the decision: **EPSS** (<https://www.first.org/epss/>), a probability that the vulnerability will be exploited in the next 30 days, and **CISA's KEV catalog** (<https://www.cisa.gov/known-exploited-vulnerabilities-catalog>), a list of vulnerabilities with confirmed in-the-wild exploitation. Reachability analysis (call-graph based) and your own asset exposure data are the third and fourth.

**A4.3** (1) **It is a portable, standardized document with an author and a timestamp** — it travels with the artifact to downstream consumers, who can act on your analysis; an ignore-rule lives in your scanner config and helps no one else. (2) **It states a machine-readable *justification*** from a fixed vocabulary (`vulnerable_code_not_in_execute_path`, `component_not_present`, `inline_mitigations_already_exist`, …) plus a human impact statement, so the reasoning is auditable — an ignore-rule records only that someone silenced something. (3) **It is scoped to a product identity and can be signed and attested** (cosign `--type openvex`), making it a non-repudiable claim; and because it is tool-agnostic, the same statement applies across Grype, Trivy and your customer's scanner, whereas ignore-rules are per-tool syntax. A fourth: VEX statements are versioned and can be superseded when the analysis changes, giving you a history.

**A4.4** It guarantees exactly one thing: **no unsuppressed finding at severity `high` or above was present in this SBOM at the moment the scan ran.** It does not guarantee the software is secure, and specifically it says nothing about (a) the four Medium/Low findings still open — severity thresholds are a risk-acceptance policy, not an absence of risk; (b) vulnerabilities disclosed *after* the scan, which is why the scan must be re-run continuously; (c) anything the SBOM omitted — an incomplete SBOM produces a clean scan trivially; (d) the correctness of the VEX suppression, since `--vex` removed a finding on the strength of your own assertion; and (e) any vulnerability class that is not a known CVE in a catalogued dependency, which is most of them — your own code's bugs, misconfiguration, secrets in the image.

**A4.5** The SBOM is a record of **what was built**, and it can only be produced accurately at the moment of build, when the resolver's output, the build platform, and the actual file tree are all present. Reconstructing it later is guesswork. The **known-vulnerability set is not a property of the artifact at all** — it is a property of the world's knowledge on a given day, and it changes continuously as advisories are published. An artifact built and scanned clean in January is not clean in March, even though not one byte changed. Splitting the two lets you scan thousands of stored SBOMs nightly, in seconds, without rebuilding or even retaining the images — and it is why baking vulnerabilities into a signed SBOM is a design error (see A1.4).

### Block 5

**A5.1** **No.** BusyBox and your application are in an **aggregation** — separate programs, distributed together on the same medium (here, the same image), communicating only through arm's-length interfaces (`exec`, files, sockets). GPL-2.0 §2 explicitly addresses this: "mere aggregation of another work not based on the Program … on a volume of a storage or distribution medium does not bring the other work under the scope of this License." Your Python application is not a **derivative work** of BusyBox — it does not link against it, incorporate its source, or extend it. What *would* change the answer is combination rather than co-location: statically linking a GPL library into your binary, importing GPL source, or building your program as a plugin sharing a GPL program's address space and data structures. Note the separate trap in this same image: `musl` is MIT, so linking against libc here is unencumbered — but on a `glibc` base, glibc is LGPL, which brings its own (much weaker) obligations, addressed in A5.4.

**A5.2** **Yes — pushing to a registry where others can pull is distribution**, and it is the moment your obligations attach. You must, for every GPL/LGPL component in the image, make the **complete corresponding source** available — meaning the exact source used to build those binaries, including any patches the distribution applied, plus the scripts used to control compilation and installation. The practical routes under GPL-2.0 §3: (a) ship the source alongside the binary, (b) accompany it with a **written offer, valid for at least three years**, to provide the source to any third party for no more than the cost of physical distribution, or (c) for non-commercial redistribution only, pass along the offer you received. GPL-3.0 §6 modernizes this and adds option (d): a network server offering source at no charge, next to the binary. Because a `THIRD-PARTY-NOTICES` file plus a URL is only as good as the URL, step 5 of the exercise checks the source is genuinely retrievable — pointing at an upstream mirror that may rotate packages out is a common and real compliance failure.

**A5.3** `AND` is **cumulative and non-negotiable**: `musl-utils` contains constituent parts under MIT, under BSD-3-Clause, *and* under GPL-2.0-or-later, and you must satisfy every one of those licences at once. In practice the strongest term governs the combined work, so this component drags GPL-2.0-or-later obligations (source availability, no additional restrictions) into your image, on top of the MIT and BSD attribution requirements. The `OR` in Exercise 2 was the opposite: a menu from which you pick one and discharge only that licence's conditions. A compliance rule of thumb: `OR` is an opportunity to *reduce* obligations by choosing well; `AND` is an accumulation you cannot opt out of.

**A5.4** **GPL-3.0 (`restricted`)** is strong copyleft: link it into your program and the combined work must be distributed under GPL-3.0, source included — for most proprietary products this is a hard block, which is why the classification is "restricted". **LGPL-2.1 (`reciprocal`)** is weak/file-level copyleft: you may link a proprietary program against the LGPL library and keep your own source closed, but modifications *to the library itself* must be released under the LGPL. The engineering obligation is the **relinking right** — LGPL-2.1 §6 and LGPL-3.0 §4(d)/(e) require you to enable the recipient to **replace the library with a modified version and still run your program**. You satisfy it by dynamically linking (shipping the library as a `.so` the user can swap) or, if you static-link, by providing your object files or a mechanism sufficient to relink. This is precisely why static-linking glibc or an LGPL library into a scratch container is a compliance landmine and dynamic linking is the safe default.

**A5.5** **The AGPL** — GNU Affero General Public License — via **§13 ("Remote Network Interaction")**. AGPL-3.0 defines interaction with the software *over a network* as triggering the source-provision obligation: if users interact with a modified AGPL program remotely, you must offer them the Corresponding Source of your modified version. This deliberately closes the "SaaS loophole" that GPL-2.0 and GPL-3.0 leave open, where running software as a service is not distribution and therefore triggers nothing. Practically: one AGPL library pulled into your API service can obligate you to publish your service's source. This is why AGPL almost always appears on the deny-list of a corporate dependency policy, and why `grep -i agpl` over your SBOM is a release-gate check rather than an audit-time one.

**A5.6** Because `NOASSERTION` means **the licence is unknown**, and unknown is not the same as unencumbered — it is an unbounded liability. A GPL-3.0 declaration is a *known* constraint: you can evaluate it, decide whether the component is aggregated or linked, discharge the obligations, and ship. `NOASSERTION` means the scanner found no machine-readable licence, so the component could be anything: AGPL, a bespoke commercial licence, proprietary code someone vendored, or genuinely unlicensed code (which by default grants you **no rights at all** — absence of a licence means exclusive copyright, not public domain). A release gate should treat `NOASSERTION` as a blocking finding requiring human resolution, exactly like a critical CVE. Note also that SPDX distinguishes `NOASSERTION` ("the tool makes no claim") from `NONE` ("there is definitively no licence"), and both demand investigation.

### Block 6

**A6.1** It would prove only that **someone with a Sigstore-issued certificate signed this artifact** — and Sigstore's Fulcio CA issues a certificate to *anyone* who can complete an OIDC login with any supported provider. Any attacker with a Google or GitHub account can sign a malicious image and get a perfectly valid Sigstore signature with a valid transparency-log entry. Verification is meaningless until you assert **who** you expect: `--certificate-identity` (or `-regexp`) pins the signer's identity and `--certificate-oidc-issuer` pins which identity provider vouched for it. Both are required because an identity string is only meaningful relative to its issuer — `platform@acme.example` from your corporate IdP and the same string self-asserted at an attacker-controlled issuer are different principals. In CI the identity you pin is typically the workflow's own SAN, e.g. `https://github.com/acme/app/.github/workflows/release.yml@refs/heads/main` with issuer `https://token.actions.githubusercontent.com`.

**A6.2** Through **Rekor, the append-only transparency log**. When the signature is created, the signing event — signature, certificate, and artifact digest — is recorded in Rekor, which returns a **signed timestamp** proving the entry existed at that moment. Verification then checks that the certificate was **valid at the time of signing** as attested by the log, rather than requiring it to be valid now. The property this provides is **non-repudiable proof of time**, which is what lets Sigstore use ephemeral, ten-minute certificates instead of long-lived keys. That trade is the entire point of the design: no long-lived private key exists to be stolen, rotated, or escrowed, and the log's append-only structure (verifiable via inclusion proofs and a signed tree head) means a signing event cannot be quietly erased or backdated.

**A6.3** `cosign sign` produces a **signature over the artifact's digest** — it asserts "this identity vouches for this exact blob" and carries essentially no other information. `cosign attest` produces a signed **in-toto attestation**: an envelope (DSSE) whose *subject* is the artifact digest and whose *predicate* is an arbitrary structured document with a declared `predicateType` — an SBOM (`https://cyclonedx.org/bom`), SLSA build provenance (`https://slsa.dev/provenance/v1`), a VEX statement, a test report. In both cases the subject is the digest; the difference is that an attestation binds **a verifiable claim about the artifact** to it, not merely an endorsement of its bytes. That is what lets a policy engine (Kyverno, Gatekeeper, `cosign verify-attestation --policy`) admit or reject a workload based on *what the attestation says*, not just on who signed.

**A6.4** It prevents **tag mutation** — the substitution attack where an attacker (or a careless release) repoints `:latest`, or any tag, to a different image after your SBOM was produced and signed. Tags in OCI registries are mutable pointers; digests are content-addressed and immutable. If the attestation named the tag, the signature would remain valid while the bytes underneath it changed completely, and your admission controller would happily admit a malicious image carrying a clean, genuinely-signed SBOM. Binding to `sha256:<digest>` makes the claim inseparable from the exact bytes it describes, which is also why deployment manifests should pin digests rather than tags.

**A6.5** SLSA **L3 addresses tampering with the build itself** — it requires the build platform to be hardened such that a build cannot influence another build, and such that provenance is **unforgeable**: the secret material used to sign provenance must be inaccessible to the user-defined build steps. L2 only requires that provenance exists, is authenticated, and comes from a hosted build service — it assumes the build service is honest but does not defend against a malicious build *tenant*. A **shared cache volume between runners** breaks L3 directly: build A can write a poisoned dependency, compiler, or toolchain binary into the cache, and build B — belonging to a different project, possibly a different trust domain — will consume it. The provenance for build B would then be *accurate and correctly signed* while describing a compromised build, which is exactly the class of attack (Codecov, xz-utils staging) that L3's isolation requirement exists to stop.

**A6.6** **No, verification did not fail, and it was not supposed to.** Signature verification establishes **integrity and provenance**: the artifact is unmodified since signing, and a specific, pinned identity vouches for it. It says nothing about **quality** — whether the code is correct, well-configured, or free of known vulnerabilities. The two controls are orthogonal and complementary, and in fact a correctly-signed SBOM listing a critical CVE is the system *working*: the supply chain honestly and verifiably told you what is inside, and the attestation gives you grounds to trust that inventory. Integrity controls make the composition data trustworthy; composition analysis then makes it actionable. Confusing the two produces the worst outcome in practice — treating "signed" as a synonym for "safe", and admitting a verified-but-vulnerable image because the signature check went green.

</details>

---

## Sources

- LPI Exam 701 Objectives (DevOps Tools Engineer) — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- SPDX specification and license list — <https://spdx.dev/> · <https://spdx.org/licenses/>
- CycloneDX specification (OWASP / ECMA-424) — <https://cyclonedx.org/specification/overview/>
- Package URL (purl) specification — <https://github.com/package-url/purl-spec>
- REUSE Specification 3.x (FSFE) — <https://reuse.software/spec/>
- GNU licenses and compatibility matrix — <https://www.gnu.org/licenses/license-list.html> · <https://www.gnu.org/licenses/gpl-faq.html>
- Apache License 2.0 — <https://www.apache.org/licenses/LICENSE-2.0>
- Open Source Definition (OSI) — <https://opensource.org/osd>
- Developer Certificate of Origin 1.1 — <https://developercertificate.org/>
- OSV vulnerability database and schema — <https://osv.dev/> · <https://ossf.github.io/osv-schema/>
- NVD — <https://nvd.nist.gov/> · CVSS (FIRST) — <https://www.first.org/cvss/> · EPSS — <https://www.first.org/epss/>
- CISA Known Exploited Vulnerabilities catalog — <https://www.cisa.gov/known-exploited-vulnerabilities-catalog>
- OpenVEX specification — <https://github.com/openvex/spec>
- Sigstore documentation (Cosign, Fulcio, Rekor) — <https://docs.sigstore.dev/>
- in-toto attestation framework — <https://github.com/in-toto/attestation>
- SLSA v1.0 build levels — <https://slsa.dev/spec/v1.0/levels>
- Syft — <https://github.com/anchore/syft> · Grype — <https://github.com/anchore/grype> · Trivy — <https://trivy.dev/> · OSV-Scanner — <https://google.github.io/osv-scanner/>