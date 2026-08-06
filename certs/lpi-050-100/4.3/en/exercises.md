# LPI 050-100 | Topic 4.3: Compliance and Risk Mitigation

## Technical Deep Dive: Open Source Compliance, SBOM & Supply Chain Security

In modern cloud-native architecture, Open Source Software (OSS) constitutes up to 80–90% of a typical production software stack. Managing open-source risk requires a multi-layered compliance and governance strategy covering three core pillars: **Licensing Compliance**, **Vulnerability & CVE Risk Mitigation**, and **Software Supply Chain Provenance**.

```
                           [ Source Repository ]
                                     │
                                     ▼
                ┌─────────────────────────────────────────┐
                │        CI/CD Build & Packaging          │
                └────────────────────┬────────────────────┘
                                     │
             ┌───────────────────────┼───────────────────────┐
             ▼                       ▼                       ▼
   ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
   │ SBOM Generation  │    │ License Audit    │    │  Vulnerability   │
   │ (SPDX / Cyclone) │    │ Compliance (OPA) │    │  Scan (Grype)    │
   └─────────┬────────┘    └─────────┬────────┘    └─────────┬────────┘
             │                       │                       │
             └───────────────────────┼───────────────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │ Cryptographic Signing   │
                        │   (Cosign / SLSA Proven)│
                        └────────────┬────────────┘
                                     ▼
                        ┌─────────────────────────┐
                        │ Kubernetes Admission    │
                        │   Control Enforcement   │
                        └─────────────────────────┘
```

### Core Architecture & Mechanics

1. **Software Bill of Materials (SBOM)**:
   An SBOM is a nested inventory of software components, dependencies, metadata, and licensing info. Standardized specifications include:
   - **SPDX (ISO/IEC 5962)**: Linux Foundation standard emphasizing precise licensing identifier definitions, relationships, and file-level copyrights.
   - **CycloneDX (OWASP)**: Designed primarily for security automation, vulnerability identification, and component graph mapping.

2. **License Compliance Mechanics & Compatibility Matrix**:
   - **Permissive (MIT, Apache-2.0, BSD-3-Clause)**: Allows redistribution, modification, and integration into proprietary software without forcing derivative source disclosure. Apache-2.0 explicitly adds patent grant protections.
   - **Weak Copyleft (LGPL-3.0, MPL-2.0)**: Requires modifications to the library itself to remain open source, but allows dynamic linking with proprietary code.
   - **Strong Copyleft (GPL-2.0, GPL-3.0)**: Requires any derivative work distributed to end-users to release its full source code under the same license terms.
   - **Network Copyleft (AGPL-3.0)**: Extends strong copyleft obligations to software operated over a network as a service (SaaS), eliminating the "SaaS loophole."

3. **Risk Mitigation Architectures**:
   - **Static Analysis & Composition Analysis (SCA)**: Inspects direct and transitive dependencies against known vulnerability databases (NVD, GHSA) and open-source license databases.
   - **Policy Engine Gatekeeping**: Declarative policies (e.g., Open Policy Agent/Rego or Kyverno) evaluated during CI/CD execution and container admission control to reject prohibited licenses (e.g., AGPL-3.0 in proprietary images) or critical CVEs without active patches.

---

## Guided Exercises

### Exercise 1: Software Bill of Materials (SBOM) Generation & License Compliance Auditing

#### Objective
Generate a production-grade SPDX 2.3 SBOM for a containerized application using `syft`, perform automated license compliance validation against enterprise governance policy, and audit transitive dependencies.

#### Step 1.1: Environment Setup & Artifact Creation
Create a mock production microservice container definition with mixed open-source dependencies.

```bash
mkdir -p /tmp/compliance-lab && cd /tmp/compliance-lab

cat <<'EOF' > Dockerfile
FROM alpine:3.19.1
RUN apk add --no-舆-cache bash curl openssl py3-pip
RUN pip install --no-cache-dir requests==2.31.0 flask==3.0.2
COPY app.py /app/app.py
ENTRYPOINT ["python3", "/app/app.py"]
EOF

cat <<'EOF' > app.py
import requests
from flask import Flask
app = Flask(__name__)

@app.route('/')
def health():
    return {"status": "healthy", "upstream": requests.get("https://httpbin.org/status/200").status_code}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

docker build -t microservice:v1.0.0 .
```

*Expected Output:*
```text
[+] Building 8.4s (8/8) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 245B
 => [1/4] FROM docker.io/library/alpine:3.19.1
 => [2/4] RUN apk add --no-cache bash curl openssl py3-pip
 => [3/4] RUN pip install --no-cache-dir requests==2.31.0 flask==3.0.2
 => [4/4] COPY app.py /app/app.py
 => exporting to image
 => => naming to docker.io/library/microservice:v1.0.0
```

#### Step 1.2: SPDX SBOM Generation
Extract a full machine-readable SPDX JSON document detailing all OS packages and language-level packages.

```bash
syft microservice:v1.0.0 -o spdx-json=sbom.spdx.json
```

*Expected Output:*
```text
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
```

#### Step 1.3: Inspecting Dependency Graph and License Declarations
Use `jq` to inspect the generated SBOM for component licenses and SPDX IDs.

```bash
jq '{spdxVersion: .spdxVersion, name: .name, packagesCount: (.packages | length), forbidden_licenses: [.packages[] | select(.licenseConcluded | test("AGPL|GPL-3.0"; "i")) | {name: .name, versionInfo: .versionInfo, license: .licenseConcluded}]}' sbom.spdx.json
```

*Expected Output:*
```json
{
  "spdxVersion": "SPDX-2.3",
  "name": "microservice:v1.0.0",
  "packagesCount": 74,
  "forbidden_licenses": []
}
```

#### Step 1.4: Writing a Custom Open Policy Agent (OPA) License Governance Rule
Create a Rego policy file (`license_policy.rego`) that blocks images containing Strong Copyleft licenses (GPL-3.0, AGPL-3.0) or unapproved licenses.

```bash
cat <<'EOF' > license_policy.rego
package compliance.licensing

default allow = false

forbidden_licenses := ["AGPL-3.0-only", "AGPL-3.0-or-later", "GPL-3.0-only", "GPL-3.0-or-later"]

violations[msg] {
    pkg := input.packages[_]
    lic := pkg.licenseConcluded
    lic == forbidden_licenses[_]
    msg := sprintf("Package %s version %s uses prohibited license: %s", [pkg.name, pkg.versionInfo, lic])
}

allow {
    count(violations) == 0
}
EOF
```

#### Step 1.5: Evaluating Policy Against Generated SBOM
Evaluate the policy using `opa`.

```bash
opa eval --data license_policy.rego --input sbom.spdx.json "data.compliance.licensing"
```

*Expected Output:*
```json
{
  "result": [
    {
      "expressions": [
        {
          "value": {
            "allow": true,
            "forbidden_licenses": [
              "AGPL-3.0-only",
              "AGPL-3.0-or-later",
              "GPL-3.0-only",
              "GPL-3.0-or-later"
            ],
            "violations": []
          },
          "text": "data.compliance.licensing",
          "location": {
            "file": "",
            "row": 1,
            "col": 1
          }
        }
      ]
    }
  ]
}
```

---

### Verification Questions - Exercise 1

1. **What is the key functional difference between SPDX `licenseDeclared` and `licenseConcluded` inside an SBOM payload?**
2. **Why does an AGPL-3.0 license pose a specific compliance risk to SaaS providers that standard GPL-3.0 does not?**

---

### Exercise 2: Automated Vulnerability Assessment, CVSS Scoring, and CI/CD Quality Gate Enforcement

#### Objective
Configure `grype` to evaluate container image vulnerabilities against NVD and EPSS feeds, enforce an automated risk threshold break on Critical/High vulnerabilities with available fixes, and export structured compliance reports.

#### Step 2.1: Execute Vulnerability Scanning on Container Image
Run `grype` on the `microservice:v1.0.0` image built in Exercise 1.

```bash
grype microservice:v1.0.0 -o json > vulnerability_report.json
```

*Expected Output:*
```text
 ✔ Vulnerability DB        [updated]
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
 ✔ Scanned image           [14 vulnerabilities]
```

#### Step 2.2: Extract Critical and High Severity CVEs
Filter vulnerabilities using `jq` to display CVE ID, package, severity, and patch state.

```bash
jq '[.matches[] | select(.vulnerability.severity == "Critical" or .vulnerability.severity == "High") | {cve: .vulnerability.id, severity: .vulnerability.severity, package: .artifact.name, installed_ver: .artifact.version, fix_ver: .vulnerability.fix.versions[0]}]' vulnerability_report.json
```

*Expected Output:*
```json
[
  {
    "cve": "CVE-2023-5363",
    "severity": "High",
    "package": "openssl",
    "installed_ver": "3.1.4-r1",
    "fix_ver": "3.1.4-r2"
  }
]
```

#### Step 2.3: Configure Automated CI/CD Fail-On-Severity Pipeline Gate
Create a local configuration file `.grype.yaml` to configure automated threshold failures.

```bash
cat <<'EOF' > .grype.yaml
fail-on-severity: high
ignore:
  - vulnerability: CVE-2099-99999 # Example false positive
    reason: "Mitigated by infrastructure firewall rules"
only-fixed: true
output: table
EOF
```

#### Step 2.4: Test Quality Gate Triggering
Execute `grype` with the custom failure threshold configuration.

```bash
grype microservice:v1.0.0 -c .grype.yaml
echo "Exit Code: $?"
```

*Expected Output:*
```text
 ✔ Vulnerability DB        [valid]
 ✔ Loaded image            microservice:v1.0.0
 ✔ Parsed image           
 ✔ Cataloged packages      [74 packages]
 ✔ Scanned image           [1 High vulnerabilities fail threshold]

NAME      INSTALLED  FIXED-IN  TYPE  VULNERABILITY  SEVERITY 
openssl   3.1.4-r1   3.1.4-r2  apk   CVE-2023-5363  High     

[ERROR] threshold fail criteria met: 1 High severity vulnerabilities found
Exit Code: 1
```

---

### Verification Questions - Exercise 2

1. **In the context of Risk Mitigation, how does the Exploit Prediction Scoring System (EPSS) differ from the Common Vulnerability Scoring System (CVSS) when prioritizing patch deployment?**
2. **What is the risk of enabling `only-fixed: true` in production vulnerability pipeline enforcement?**

---

### Exercise 3: Supply Chain Cryptographic Signing, Attestation, and In-Cluster Admission Control

#### Objective
Sign a container image using keyless `cosign` (Fulcio/Rekor architecture), attach an SBOM attestation, and enforce an policy using Kubernetes admission control primitives.

#### Step 3.1: Generate Local Signing Keys
Create a local key-pair using `cosign` for offline/isolated signing simulation.

```bash
export COSIGN_PASSWORD="ProductionPassphrase123!"
cosign generate-key-pair
```

*Expected Output:*
```text
Private key written to cosign.key
Public key written to cosign.pub
```

#### Step 3.2: Sign the Container Image Digest
Sign the container image using its immutable SHA256 digest (assuming a local registry tag `localhost:5000/microservice@sha256:...`).

```bash
# Note: Simulating tag digest extraction
IMAGE_DIGEST="microservice@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
cosign sign --key cosign.key --yes $IMAGE_DIGEST
```

*Expected Output:*
```text
Enter password for private key: 
Signing weight for microservice@sha256:e3b0c442...
Digest signed successfully.
Pushing signature to: localhost:5000/microservice:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
```

#### Step 3.3: Attach In-Toto SBOM Attestation
Attach the generated SPDX SBOM as a cryptographically signed attestation to the registry image reference.

```bash
cosign attest --key cosign.key --type spdx --predicate sbom.spdx.json $IMAGE_DIGEST
```

*Expected Output:*
```text
Enter password for private key: 
Storing attestation in image destination: localhost:5000/microservice:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.att
```

#### Step 3.4: Verify Signature and Attestation Integrity
Verify the image signature against the public key.

```bash
cosign verify --key cosign.pub $IMAGE_DIGEST
```

*Expected Output:*
```json
Verification for microservice@sha256:e3b0c442... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Claims were validated against the supplied public key
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/microservice"
      },
      "image": {
        "docker-manifest-digest": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "type": "cosign container image signature"
    },
    "optional": null
  }
]
```

#### Step 3.5: Define Kubernetes Kyverno Policy for Image Signature Enforcement
Create a complete, syntactically valid Kyverno `ClusterPolicy` that denies any deployment running images not signed by the organization's public key.

```bash
cat <<'EOF' > cluster_policy.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signature
  annotations:
    policies.kyverno.io/title: Verify Container Image Signature
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "localhost:5000/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE3j10/YmR+1p7Gk7N/3a/0s2uP5b1
            1x4+8bWqH0kH0N7kL+5F8c8d8e8f8g8h8i8j8k8l8m8n8o8p8q8r8s8t8u8v8w==
            -----END PUBLIC KEY-----
EOF
```

---

### Verification Questions - Exercise 3

1. **What vulnerability vector does referencing container images by immutable SHA256 digest prevent compared to using mutable tags like `:latest` or `:v1.0.0`?**
2. **How does keyless signing using Sigstore (Fulcio & Rekor) avoid the operational burden of long-lived private key management?**

---

## Solutions & Answers

<details>
<summary>Click to view Answers and Explanations for Exercises 1-3</summary>

### Exercise 1 Solutions

1. **`licenseDeclared` vs. `licenseConcluded`**:
   - `licenseDeclared`: The raw license string as stated directly by the upstream package author in metadata (e.g., inside `package.json`, `setup.py`, or `Cargo.toml`). This may be ambiguous, non-standardized, or missing.
   - `licenseConcluded`: The verified, canonical SPDX identifier assigned after automated analysis or manual curation by a compliance tool or auditor (e.g., converting "GPLv3+" to `GPL-3.0-or-later`). Policy engines must always evaluate against `licenseConcluded` for legal accuracy.

2. **AGPL-3.0 SaaS Compliance Risk**:
   - Standard GPL-3.0 copyleft obligations are triggered upon **distribution** of software to third parties. If a company runs GPL-3.0 software on its own servers as a SaaS platform without distributing binaries to users, source code disclosure is not required.
   - AGPL-3.0 (GNU Affero General Public License) specifically introduces Section 13 (Remote Network Interaction). Running AGPL-3.0 software over a network (SaaS) is legally defined as triggering copyleft distribution requirements, obligating the operator to make the complete source code available to all network users.

---

### Exercise 2 Solutions

1. **CVSS vs. EPSS in Risk Mitigation**:
   - **CVSS (Common Vulnerability Scoring System)**: Measures the theoretical **severity** and technical impact of a vulnerability based on intrinsic characteristics (e.g., attack vector, complexity, privileges required). It does not measure active exploitation probability.
   - **EPSS (Exploit Prediction Scoring System)**: Provides a dynamic, data-driven probability score (0.0 to 1.0 / 0% to 100%) that a specific CVE will be **actively exploited in the wild** within the next 30 days. SRE teams use EPSS alongside CVSS to prioritize urgent patching for lower-severity bugs with high active exploitation over higher-severity bugs with zero real-world exploitation.

2. **Risk of `only-fixed: true`**:
   - Setting `only-fixed: true` causes the scanner to ignore vulnerabilities that do not currently have a vendor-provided patch or updated package version available.
   - **Risk**: While it prevents blocking CI/CD pipelines on unpatchable upstream bugs, it creates a massive blind spot. Critical zero-day vulnerabilities or unpatched High-severity bugs will silently pass through into production without secondary mitigations (such as WAF rules, network microsegmentation, or compensating security controls).

---

### Exercise 3 Solutions

1. **Digest vs. Tag Vulnerability Vector**:
   - Container tags (e.g., `:latest`, `:v1.0.0`) are **mutable pointers**. A malicious actor with registry access or a compromised CI pipeline can overwrite a tag to point to a malicious image without altering the tag name.
   - A SHA256 digest is an **immutable cryptographic content address**. If a single byte of the container image is modified, the hash changes completely. Pulling by digest guarantees execution of the exact code that was audited, scanned, and signed.

2. **Keyless Signing (Fulcio & Rekor) Architecture**:
   - Keyless signing removes long-lived private keys that can be leaked or compromised.
   - **Fulcio**: Acts as an Ephemeral Certificate Authority. When a developer or CI pipeline signs an artifact, it authenticates via OpenID Connect (OIDC). Fulcio issues a short-lived X.509 certificate bound to the OIDC identity (e.g., GitHub Actions workflow URL or email) valid for only a few minutes.
   - **Rekor**: A tamper-evident, append-only transparency log. The signature, short-lived certificate, and artifact hash are recorded into Rekor. Verification checks the Rekor log entry to prove the signature was generated during the certificate's valid timeframe, eliminating the need to manage PKI revocation lists or long-lived keys.

</details>

---

## Official References & Standards

- **LPI Open Source Essentials Overview**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **SPDX Specification v2.3 (ISO/IEC 5962:2021)**: [https://spdx.dev/specifications/](https://spdx.dev/specifications/)
- **OWASP CycloneDX Standard**: [https://cyclonedx.org/docs/](https://cyclonedx.org/docs/)
- **OpenChain Project (ISO/IEC 5230:2020 License Compliance)**: [https://www.openchainproject.org/](https://www.openchainproject.org/)
- **Sigstore / Cosign Documentation**: [https://docs.sigstore.dev/](https://docs.sigstore.dev/)
- **FIRST EPSS Specification**: [https://www.first.org/epss/](https://www.first.org/epss/)