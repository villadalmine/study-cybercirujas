# KCSA Study Guide: Topic 6.3 – Supply Chain Compliance

**Exam**: Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain**: Supply Chain Security  
**Topic 6.3**: Supply Chain Compliance  
**Weight**: 2.5%  

---

## Official Reference Sources
* **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **CNCF Software Supply Chain Best Practices**: [https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsc-v1.pdf](https://github.com/cncf/tag-security/blob/main/supply-chain-security/supply-chain-security-paper/sscsc-v1.pdf)
* **SLSA Framework Specification (v1.0)**: [https://slsa.dev/spec/v1.0/](https://slsa.dev/spec/v1.0/)
* **Sigstore Documentation**: [https://docs.sigstore.dev/](https://docs.sigstore.dev/)
* **in-toto Attestation Framework**: [https://in-toto.github.io/](https://in-toto.github.io/)
* **SPDX Specification (v2.3)**: [https://spdx.github.io/spdx-spec/v2.3/](https://spdx.github.io/spdx-spec/v2.3/)
* **CycloneDX Specification**: [https://cyclonedx.org/docs/1.5/json/](https://cyclonedx.org/docs/1.5/json/)
* **Kyverno Image Verification Policy**: [https://kyverno.io/docs/user-guide/image-verify/](https://kyverno.io/docs/user-guide/image-verify/)

---

## Technical Context & Architectural Overview

Supply Chain Compliance in cloud-native environments guarantees that software artifacts deployed to production clusters are verifiable, tamper-evident, and traceable back to their origin. Compliance spans the software development life cycle (SDLC) through four foundational primitives:

1. **Software Bill of Materials (SBOM)**: An inventory of open-source and proprietary components, dependencies, licenses, and hashes inside a build. Standardized formats include **SPDX** (ISO/IEC 5962:2021) and **CycloneDX** (OWASP).
2. **Provenance & Attestations**: Cryptographic metadata adhering to frameworks like **SLSA** (Supply-chain Levels for Software Artifacts) and **in-toto**. Attestations bind an artifact hash to its build environment parameters and build logs.
3. **Cryptographic Artifact Signing (Sigstore Ecosystem)**:
   * **Cosign**: Signs container images, blob stores, and attestations.
   * **Fulcio**: Free Root Certificate Authority (CA) issuing short-lived X.509 certificates tied to OIDC identities (Keyless signing).
   * **Rekor**: Immutable, append-only transparency log providing public proof of signature existence via Merkle Tree roots.
4. **In-Cluster Dynamic Enforcement**: Kubernetes Dynamic Admission Controllers (e.g., Kyverno or OPA Gatekeeper) intercept pod creation requests, query transparency logs/OCI registries, and block non-compliant artifacts at admission time.

---

## Exercise 1: Generating, Auditing, and Validating SBOM Compliance

In this exercise, you will generate production-grade SBOMs using `syft` across standard formats (SPDX and CycloneDX), inspect structural integrity, verify license compliance, and scan the generated SBOM for vulnerabilities.

### Step 1.1: Generate an SPDX 2.3 JSON SBOM from an OCI Image

Execute the `syft` CLI to inspect a production-grade image (`registry.k8s.io/kube-apiserver:v1.30.0`) and export an SPDX JSON artifact.

```bash
syft registry.k8s.io/kube-apiserver:v1.30.0 -o spdx-json=apiserver-spdx.json
```

**Expected Output:**
```text
 ✔ Loaded image            registry.k8s.io/kube-apiserver:v1.30.0
 ✔ Parsed image            sha256:d8b22a0134bc5bd8e50b7b12d98d2ef071e626e5e0cf79f972b9a71db294e7df
 ✔ Cataloged packages      [142 packages]
```

### Step 1.2: Audit SPDX Document Structure and Cryptographic Checksums

Use `jq` to query critical compliance fields inside `apiserver-spdx.json`: document namespace, creation timestamp, data license, and package checksums.

```bash
jq '{
  spdxVersion: .spdxVersion,
  dataLicense: .dataLicense,
  documentNamespace: .documentNamespace,
  packageCount: (.packages | length),
  samplePackage: .packages[0] | {name: .name, versionInfo: .versionInfo, checksums: .checksums}
}' apiserver-spdx.json
```

**Expected Output:**
```json
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "documentNamespace": "https://anchore.com/syft/image/registry.k8s.io/kube-apiserver-v1.30.0-60b81e81-3c22-4467-9c6a-c2ff5d56abf2",
  "packageCount": 142,
  "samplePackage": {
    "name": "golang.org/x/net",
    "versionInfo": "v0.17.0",
    "checksums": [
      {
        "algorithm": "SHA256",
        "checksumValue": "4bc49bf55d9d70df88e89fcf2f42a1705e4922129d381014e86a074c5d6e24ee"
      }
    ]
  }
}
```

### Step 1.3: Generate a CycloneDX 1.5 JSON SBOM and Perform License Compliance Filtering

Generate a CycloneDX JSON representation of the same artifact, then filter packages missing compliant open-source licenses.

```bash
syft registry.k8s.io/kube-apiserver:v1.30.0 -o cyclonedx-json=apiserver-cyclonedx.json

jq '[.components[] | select(.licenses == null or (.licenses | length) == 0) | {name: .name, version: .version}]' apiserver-cyclonedx.json
```

**Expected Output:**
```json
[]
```

---

### Questions – Exercise 1

**Q1.1**: What is the key structural difference between SPDX and CycloneDX regarding primary design intents?  
**Q1.2**: In a high-security supply chain pipeline, why is generating an SBOM *inside* a running container at deployment time considered anti-pattern compared to generating it *during build execution*?

---

## Exercise 2: Cryptographic Image Signing & In-Toto Attestations with Sigstore Cosign

In this exercise, you will generate static cryptographic keys, attach an in-toto SBOM predicate attestation to an OCI artifact using `cosign`, and audit the transparency log entries.

### Step 2.1: Generate a Cosign Keypair

Generate a public/private keypair using `cosign`. Secure the private key with a password.

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign generate-key-pair
```

**Expected Output:**
```text
Private key written to cosign.key
Public key written to cosign.pub
```

### Step 2.2: Sign a Container Image with Static Keys

Sign an OCI image target (replace `localhost:5000/demo/app:v1.0.0` with your target registry path or local distribution registry).

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign sign --key cosign.key localhost:5000/demo/app:v1.0.0
```

**Expected Output:**
```text
Pushing signature to: localhost:5000/demo/app:sha256-a1b2c3...sig
Enter password for private key: 
Applying signature tag to localhost:5000/demo/app:sha256-a1b2c3...sig
```

### Step 2.3: Attach the SBOM as an In-Toto Predicate Attestation

Attach `apiserver-spdx.json` to the container image using the `spdxjson` predicate type.

```bash
COSIGN_PASSWORD="KcsASecurePassword2026!" cosign attest \
  --key cosign.key \
  --type spdxjson \
  --predicate apiserver-spdx.json \
  localhost:5000/demo/app:v1.0.0
```

**Expected Output:**
```text
Pushing attestation to: localhost:5000/demo/app:sha256-a1b2c3...att
Uploading attestation to Rekor transparency log...
Attestation entry created with index: 89432104
```

### Step 2.4: Verify the Image Attestation and Audit Payload

Verify the attestation using `cosign verify-attestation` and decode the payload.

```bash
cosign verify-attestation \
  --key cosign.pub \
  --type spdxjson \
  localhost:5000/demo/app:v1.0.0 | jq -r '.[].payload' | base64 --decode | jq
```

**Expected Output:**
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "localhost:5000/demo/app",
      "digest": {
        "sha256": "a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0"
      }
    }
  ],
  "predicate": {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0"
  }
}
```

---

### Questions – Exercise 2

**Q2.1**: What key risk does Sigstore **Fulcio** (Keyless Signing) resolve when compared to managing static asymmetric key pairs (`cosign.key`/`cosign.pub`) across multi-tenant CI/CD engineering platforms?  
**Q2.2**: How does **Rekor** prevent a compromised container registry administrator from covertly swapping a valid signed OCI image layer digest without detection?

---

## Exercise 3: In-Cluster Policy Enforcement with Kyverno Admission Control

In this exercise, you will deploy a syntactically valid production-grade Kyverno `ClusterPolicy` that mandates Cosign cryptographic signature verification on all Pod images before allowing deployment into the cluster.

### Step 3.1: Create the Kyverno Image Verification ClusterPolicy Manifest

Save the following complete manifest to `kyverno-supply-chain-policy.yaml`. This policy enforces signature checks against a designated Cosign public key for all images deployed in namespaces labeled `compliance=strict`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-supply-chain
  annotations:
    policies.kyverno.io/title: Verify Image Signatures with Cosign
    policies.kyverno.io/category: Supply Chain Compliance
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    description: >-
      Enforces that all container images deployed into compliance-monitored 
      namespaces have a valid Cosign cryptographic signature matching the 
      enterprise trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  rules:
    - name: verify-signature-cosign
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaceSelector:
              matchLabels:
                compliance: strict
      verifyImages:
        - imageReferences:
            - "localhost:5000/*"
            - "docker.io/myorg/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless: {}
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N3f9...[YOUR_PUBLIC_KEY_PEM]...
                      -----END PUBLIC KEY-----
```

### Step 3.2: Apply the Manifest and Namespace Labels

Apply the policy and create a target namespace labeled for compliance enforcement.

```bash
kubectl apply -f kyverno-supply-chain-policy.yaml
kubectl create namespace prod-secure
kubectl label namespace prod-secure compliance=strict
```

**Expected Output:**
```text
clusterpolicy.kyverno.io/verify-image-supply-chain created
namespace/prod-secure created
namespace/prod-secure labeled
```

### Step 3.3: Test Enforced Rejection of Unsigned Container Images

Attempt to deploy an unsigned container image (`docker.io/myorg/untrusted-app:v1.0.0`) into the `prod-secure` namespace.

```bash
kubectl run test-unsigned \
  --image=docker.io/myorg/untrusted-app:v1.0.0 \
  -n prod-secure
```

**Expected Output:**
```text
Error from server (Forbidden): admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: 

resource Pod/prod-secure/test-unsigned was blocked due to the following policies:

verify-image-supply-chain:
  verify-signature-cosign: 'image verification failed for docker.io/myorg/untrusted-app:v1.0.0: 
    failed to verify signature: no matching signatures found'
```

### Step 3.4: Advanced Diagnostics & Webhook Auditing

Inspect policy execution status and search admission audit logs for compliance validation traces.

```bash
# Check status of cluster policy
kubectl get clusterpolicy verify-image-supply-chain -o jsonpath='{.status}' | jq

# Search Kyverno webhook admission events
kubectl get events -n prod-secure --field-selector reason=PolicyViolation
```

**Expected Output:**
```json
{
  "conditions": [
    {
      "lastTransitionTime": "2026-08-07T20:35:43Z",
      "message": "Ready",
      "reason": "Succeeded",
      "status": "True",
      "type": "Ready"
    }
  ],
  "rulecount": {
    "generate": 0,
    "mutate": 0,
    "validate": 0,
    "verifyimages": 1
  }
}
```

---

### Questions – Exercise 3

**Q3.1**: In the Kyverno `ClusterPolicy`, what is the functional trade-off of setting `mutateDigest: true` within the `verifyImages` rule context?  
**Q3.2**: If a cluster node suffers temporary WAN network disruption preventing access to external OCI image registries or transparency logs during a Pod restart event, how does admission control behavior differ depending on `webhookTimeoutSeconds` and `failurePolicy` configurations in the `ValidatingWebhookConfiguration`?

---

<details>
<summary><b>Click to Expand: Answers and Explanations</b></summary>

### Exercise 1 Answers

* **A1.1**: **SPDX** (System Package Data Exchange) was originated by the Linux Foundation with a primary focus on software licensing compliance, legal tracking, and precise package copyright documentation. **CycloneDX** was created by OWASP specifically tailored for security use cases, application security testing (AST), vulnerability disclosure, and Software Supply Chain Risk Management (SCRM).
* **A1.2**: Generating an SBOM inside a running container at deployment time poses two severe security issues:
  1. **Taint & Integrity Risk**: A runtime container environment might have been mutated or infected with transient malware prior to scanning, yielding an inaccurate/tampered SBOM.
  2. **Non-Repudiation & Build Attestation Failure**: An SBOM generated after image creation cannot be deterministically cryptographically bound to the build-time source code commits, compiler flags, and CI runner pipeline identity. SLSA Compliance mandates SBOM creation during the build phase.

---

### Exercise 2 Answers

* **A2.1**: **Fulcio Keyless Signing** eliminates long-lived static private keys (`cosign.key`), avoiding private key leaks, password storage, and complex cross-team key rotation operations. Fulcio leverages OpenID Connect (OIDC) tokens (from GitHub Actions, GitLab CI, or Google Cloud identity providers) to issue short-lived (10-minute validity) X.509 certificates. The certificate binds the signature directly to the ephemeral CI job identity without storing private keys anywhere.
* **A2.2**: **Rekor** is an append-only transparency log built upon a cryptographic Merkle Tree (similar to Certificate Transparency logs). Once an entry (image hash, signature, public key/certificate) is recorded in Rekor, the log generates a Signed Entry Timestamp (SET) and an inclusion proof. Even if a registry admin replaces an OCI image layer digest on the storage backend, the new digest will not match the immutable Merkle tree leaf hash recorded in public Rekor logs, triggering immediate admission verification failure.

---

### Exercise 3 Answers

* **A3.1**: Setting `mutateDigest: true` instructs Kyverno to automatically resolve mutable image tags (e.g., `:v1.0.0` or `:latest`) to their exact immutable SHA-256 digest (`@sha256:d8b22a0...`) during admission mutation. 
  * **Trade-off**: This eliminates Time-of-Check to Time-of-Use (TOCTOU) vulnerability vectors where a tag is modified between admission check and kubelet image pull. However, it requires the admission controller to make outbound network calls to the OCI registry at pod creation time to query image manifests, introducing API latency and dependencies on registry uptime.
* **A3.2**: If external registry/transparency connectivity fails during pod admission:
  * If the admission webhook's `failurePolicy` is set to `Fail` (production default for security), any Pod creation or restart attempt will be **blocked** completely by the API server if the webhook times out (exceeds `webhookTimeoutSeconds`).
  * If set to `Ignore`, the API server bypasses verification, allowing potentially unsigned or unverified container images to run. 
  * **Note**: Kubelet cached images on existing nodes might restart under local `kubelet` control without hitting the API server admission webhook, but scaling operations or new Pod creations will fail under `failurePolicy: Fail`.

</details>