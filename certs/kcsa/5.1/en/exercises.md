# KCSA Study Guide: Topic 5.1 - Supply Chain Security

**Role:** Principal Platform Architect & Senior SRE Instructor  
**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Platform Security / Supply Chain Security (Domain 5.1, Weight ~2.29%)  
**Reference Source:** [CNCF KCSA Curriculum (Official PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Architectural Deep-Dive: The Cloud-Native Supply Chain Attack Surface

Modern cloud-native supply chain security shifts trust boundaries from perimeter IP address checks to cryptographic identity proofs. Container images are no longer treated as static build outputs; they are verifiable bundles of code, metadata, cryptographically signed attestations, and Software Bills of Materials (SBOM).

```
 +------------------+     +-------------------+     +---------------------+
 |   Source Code    | --> | Ephemeral Builder | --> | OCI Image Registry  |
 | (Git Commit Hash)|     |  (SLSA Level 3)   |     | (Container + SBOM)  |
 +------------------+     +-------------------+     +---------------------+
                                   |                           |
                                   v                           v
                           +---------------+         +-------------------+
                           |  Sigstore /   |         | Admission Controller|
                           | Fulcio/Rekor  |         | (Kyverno / OPA)   |
                           +---------------+         +-------------------+
                                                               |
                                                               v
                                                     +-------------------+
                                                     | Kubernetes Worker |
                                                     |  (Kubelet Engine) |
                                                     +-------------------+
```

### The 4 Main Attack Vectors & Mitigation Mechanics
1. **Source Code & Dependency Compromise (Typosquatting / Dependency Confusion):** Attacker injects malicious code upstream. *Mitigation:* SBOM generation, lockfiles, dependency pin by commit hash.
2. **Build System Tampering (SLSA Threat Vector):** Compromised build runners modify binaries prior to containerization. *Mitigation:* Ephemeral hermetic build nodes, in-toto provenance attestations ([SLSA v1.0 Specification](https://slsa.dev/spec/v1.0/provenance)).
3. **Registry Container Image Substitution (Tag Sliding Attacks):** An attacker replaces `my-app:v1.0.0` in the registry without changing the tag. *Mitigation:* Immutable image digests (`@sha256:...`) and Cosign cryptographic signatures ([Sigstore Documentation](https://docs.sigstore.dev/cosign/overview/)).
4. **Cluster Runtime Ingestion of Unverified Artifacts:** Kubernetes nodes pull unvetted third-party images. *Mitigation:* Admission Controllers validating OIDC identities and cryptographic signatures prior to API server persistence.

---

## 2. Guided Exercise 1: Generating & Cryptographically Attesting SBOMs with Syft and Cosign

### Architectural Overview
A Software Bill of Materials (SBOM) provides machine-readable inventory (SPDX or CycloneDX) listing every binary, library, and OS package inside a container image. To prevent an adversary from tampering with the SBOM in transit, the SBOM is attached to the OCI registry as an in-toto attestation signed with Cosign.

### Step-by-Step Hands-on Execution

#### Step 1.1: Build an Image & Generate a CycloneDX SBOM
Create a minimalist alpine container image, build it locally, and generate a CycloneDX JSON SBOM using `syft`.

```bash
# 1. Create directory and Dockerfile
mkdir -p /tmp/kcsa-supply-chain && cd /tmp/kcsa-supply-chain

cat <<'EOF' > Dockerfile
FROM alpine:3.19.0
RUN apk add --no-cache curl=8.9.1-r0 bash=5.2.21-r0
ENTRYPOINT ["/bin/bash", "-c", "echo Security Pipeline Active"]
EOF

# 2. Build local image tag
docker build -t localhost:5000/sec-ops/app:v1.0.0 .

# 3. Generate CycloneDX JSON SBOM using Syft
syft localhost:5000/sec-ops/app:v1.0.0 -o cyclonedx-json=sbom.json
```

**Expected Terminal Output (`syft` execution):**
```text
 ✔ Parsed image                    localhost:5000/sec-ops/app:v1.0.0
 ✔ Cataloged packages              [18 packages]
  ├── alpine-baselayout            3.4.3-r2   apk
  ├── bash                         5.2.21-r0  apk
  ├── curl                         8.9.1-r0   apk
  └── zlib                         1.3.1-r0   apk
[INFO] SBOM successfully written to sbom.json
```

#### Step 1.2: Generate Cosign Keypair and Attest SBOM to Registry
Sign the SBOM using Cosign keypairs and push the attestation payload into the OCI registry linked directly to the image digest.

```bash
# 1. Generate local ECDSA key pair (Non-interactive mode)
COSIGN_PASSWORD="KCSA_Production_Password_2026" cosign generate-key-pair

# 2. Inspect the generated keys
ls -l cosign.key cosign.pub

# 3. Obtain precise image digest to prevent tag mutation attacks
IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' localhost:5000/sec-ops/app:v1.0.0 2>/dev/null || echo "localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612")

# 4. Attach signed attestation to OCI Artifact layer
COSIGN_PASSWORD="KCSA_Production_Password_2026" cosign attest \
  --key cosign.key \
  --type cyclonedx \
  --predicate sbom.json \
  ${IMAGE_DIGEST}
```

**Expected Terminal Output (`cosign attest` execution):**
```text
Using payload at sbom.json
Uploading attestation for [localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612] to OCI registry...
Signature verification succeeded for digest localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
Attestation attached: localhost:5000/sec-ops/app:sha256-d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612.att
```

#### Step 1.3: Cryptographically Verify the SBOM Attestation
Extract and verify the cryptographic integrity of the attestation from the registry using `cosign verify-attestation`.

```bash
cosign verify-attestation \
  --key cosign.pub \
  --type cyclonedx \
  ${IMAGE_DIGEST} | jq .
```

**Expected Terminal Output:**
```json
{
  "critical": {
    "identity": {
      "docker-reference": "localhost:5000/sec-ops/app"
    },
    "image": {
      "docker-manifest-digest": "sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612"
    },
    "type": "cosign container image attestation"
  },
  "optional": {
    "PredicateType": "https://cyclonedx.org/schema/bom-1.4.json"
  }
}
```

---

### Comprehension Verification: Exercise 1

#### Question 1.1
Why is referencing an image tag (e.g., `app:v1.0.0`) insufficient when running `cosign verify-attestation` in production, and why must the immutable digest (`app@sha256:...`) be used instead?

#### Question 1.2
What mechanism prevents a malicious actor who compromised the OCI registry from replacing the `sbom.json` payload inside an existing attestation artifact without being detected?

---

## 3. Guided Exercise 2: Enforcing Signature & SBOM Verification at Admission Control via Kyverno

### Architectural Overview
Securing the CI/CD pipeline is incomplete without runtime enforcement. If a deployment is submitted to the Kubernetes API server, the Kubernetes Admission Controller interceptor (specifically a Validating Webhook) must block Pod creation if:
1. The container image is not cryptographically signed by the organization's public key.
2. The image digest does not match the signed manifest.

We will deploy a production-grade [Kyverno `ClusterPolicy`](https://kyverno.io/docs/writing-policies/verify-images/) resource to enforce strict image verification.

```
 +----------------------+      +----------------------+      +-----------------------+
 | kubectl apply -f pod | ---> | Kubernetes API Server| ---> |  Kyverno Admission    |
 +----------------------+      +----------------------+      |  Webhook Controller   |
                                                             +-----------------------+
                                                                         |
                                                                         v
                                                              Verify Cosign Signature
                                                              against public key/digest
                                                                         |
                                                 +-----------------------+-----------------------+
                                                 |                                               |
                                                 v                                               v
                                        [ Signature Valid ]                    [ Invalid / Missing ]
                                                 |                                               |
                                                 v                                               v
                                          Allow Pod Creation                     Deny Request (403)
```

### Step-by-Step Hands-on Execution

#### Step 2.1: Deploy the Syntactically Valid Kyverno Image Verification Policy
Create a file named `verify-image-policy.yaml` containing the `ClusterPolicy` manifest.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-container-signature
  annotations:
    policies.kyverno.io/title: Enforce Cosign Image Signature Verification
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >-
      Blocks any Pod creation if the container image is not cryptographically signed
      by the SecOps trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  failurePolicy: Fail
  rules:
    - name: verify-signature-rule
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - production
      verifyImages:
        - imageReferences:
            - "localhost:5000/sec-ops/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7+rT4FqUuN22QhR90O+hU0VzR5Ew
            w4R3lM3XlY1qU0O91M3wQ4V5X6Y7Z8A9B0C1D2E3F4G5H6I7J8K9L0M1N2==
            -----END PUBLIC KEY-----
          mutateDigest: true
          required: true
          verifyDigest: true
```

Apply the manifest to your cluster:
```bash
kubectl apply -f verify-image-policy.yaml
```

**Expected Terminal Output:**
```text
clusterpolicy.kyverno.io/verify-container-signature created
```

#### Step 2.2: Test 1 - Attempt to Deploy an Unsigned Image (Expect Block)
Create a target namespace `production` and attempt to run an unsigned container image (`localhost:5000/sec-ops/untrusted-app:v1.0.0`).

```bash
# 1. Create production namespace
kubectl create namespace production

# 2. Attempt deployment of unsigned container
kubectl run rogue-workload \
  --image=localhost:5000/sec-ops/untrusted-app:v1.0.0 \
  -n production
```

**Expected Terminal Output (Kubernetes API Rejection):**
```text
Error from server (Forbidden): admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: 

policy ClusterPolicy/verify-container-signature error:
  verify-signature-rule: imageVerification failed for localhost:5000/sec-ops/untrusted-app:v1.0.0: 
  failed to verify image signature against provided key: no signatures found for image digest
```

#### Step 2.3: Test 2 - Deploy a Valid, Signed Container Image (Expect Success)
Now deploy the signed container image generated in Exercise 1 using its cryptographically verified digest.

```bash
kubectl run secure-workload \
  --image=localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612 \
  -n production
```

**Expected Terminal Output:**
```text
pod/secure-workload created
```

Verify Pod status:
```bash
kubectl get pod secure-workload -n production -o wide
```

**Expected Output:**
```text
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE       NOMINATED NODE   READINESS GATES
secure-workload   1/1     Running   0          12s   10.244.0.15  node-01    <none>           <none>
```

---

### Comprehension Verification: Exercise 2

#### Question 2.1
In the Kyverno `ClusterPolicy` manifest, what is the operational purpose of `mutateDigest: true`? What security risk does it mitigate at the Kubernetes cluster level?

#### Question 2.2
If the admission controller's `failurePolicy` is set to `Ignore` instead of `Fail`, what happens to the supply chain security posture if the Kyverno controller pod crashes or undergoes an OOMKill event?

---

## 4. Guided Exercise 3: Keyless Signatures, Transparency Logs (Rekor), and OIDC Identity Attestation

### Architectural Overview
Traditional key-pair management introduces secret sprawl, key rotation overhead, and risk of private key leakage. Sigstore solves this with **Keyless Signing**:
1. The builder authenticates to Fulcio (a short-lived Certificate Authority) via an **OIDC Identity Provider** (e.g., GitHub Actions, OIDC Token).
2. Fulcio issues a short-lived X.509 certificate bound to the builder's identity (e.g., `https://github.com/org/repo/.github/workflows/deploy.yml@refs/heads/main`).
3. The signature and certificate are published to **Rekor**, an immutable, append-only Transparency Log based on a Merkle Tree architecture ([Sigstore Architecture Docs](https://docs.sigstore.dev/)).

```
 +------------------+   1. OIDC Token    +--------------------+
 | Ephemeral CI/CD  | -----------------> | Fulcio CA          |
 | (GitHub Actions) | <----------------- | (Short-lived Cert) |
 +------------------+   2. X.509 Cert    +--------------------+
          |
          | 3. Sign Image & Log Entry
          v
 +------------------------------------------------------------+
 |                       Rekor Log                            |
 | (Immutable Merkle Tree Transparency Log - Proof of Entry) |
 +------------------------------------------------------------+
```

### Step-by-Step Hands-on Execution

#### Step 3.1: Execute Keyless Signing (Simulated CI Environment)
In an environment with OIDC capability (e.g., GitHub Actions runner or local ambient OIDC session):

```bash
# Execute keyless image signing
cosign sign \
  --yes \
  localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
```

**Expected Terminal Output:**
```text
Generating ephemeral key pair...
Retrieving signed certificate from Fulcio...
Successfully obtained X.509 certificate!
Issuer: https://token.actions.githubusercontent.com
Subject: https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main
Submitting signature to Rekor transparency log...
Successfully logged entry to Rekor transparency log with index: 10842910
Signing complete!
```

#### Step 3.2: Verify Keyless Signatures using Identity & Issuer Flags
Instead of providing a static public key file (`--key cosign.pub`), verification enforces identity attributes: `--certificate-identity` and `--certificate-oidc-issuer`.

```bash
cosign verify \
  --certificate-identity="https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  localhost:5000/sec-ops/app@sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612 | jq .
```

**Expected Terminal Output:**
```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/sec-ops/app"
      },
      "image": {
        "docker-manifest-digest": "sha256:d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612"
      },
      "type": "cosign container image signature"
    },
    "optional": {
      "Bundle": {
        "SignedEntryTimestamp": "MEQCIFx...==",
        "Payload": {
          "body": "..."
        }
      },
      "Issuer": "https://token.actions.githubusercontent.com",
      "Subject": "https://github.com/secops-org/core-pipeline/.github/workflows/build.yml@refs/heads/main"
    }
  }
]
```

#### Step 3.3: Advanced Diagnostics: Inspecting Rekor Transparency Log Entries
If an audit requires proof of signature timestamp or verification of the Merkle Tree root hash, query Rekor directly using `rekor-cli`.

```bash
# Query Rekor log by image digest
rekor-cli search --sha256 d875323a6f1938924b42bf79069d273bfd92823617300c3b879685600c3c8612
```

**Expected Terminal Output:**
```text
Found matching entries:
  10842910
```

Retrieve details of entry `10842910`:
```bash
rekor-cli get --log-index 10842910
```

**Expected Terminal Output:**
```text
Log Index: 10842910
Integrated Time: 2026-08-07T20:15:00Z
Body: {
  "spec": {
    "signature": {
      "content": "MEUCIQC...",
      "format": "x509",
      "publicKey": {
        "content": "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t..."
      }
    }
  }
}
Verification:
  Integrated Time: 2026-08-07T20:15:00Z
  Signed Entry Timestamp (SET): MEQCIDy4...==
```

---

### Comprehension Verification: Exercise 3

#### Question 3.1
How does Sigstore's Rekor transparency log guarantee that a signature entry cannot be retroactively modified or deleted by an administrator who gains root access to the Rekor server infrastructure?

#### Question 3.2
In a keyless setup, Fulcio certificates expire within minutes (e.g., 10 minutes). Why does a Cosign signature remain valid days or years later when verified by Kubernetes admission controllers?

---

## 5. Advanced Diagnostic & Troubleshooting Playbook

### Diagnostic Matrix for Supply Chain Verification Failures

| Failure Scenario / Error Message | Root Cause Analysis | Remediation Command / Procedure |
| :--- | :--- | :--- |
| `error: no matching signatures found` | Image was built or re-tagged after signing, changing its digest. | Re-sign the new image digest using `cosign sign --key ... <DIGEST>` |
| `error: certificate expired and SET missing` | Keyless verification failed because Rekor proof of entry (Signed Entry Timestamp) was omitted. | Ensure `--rekor-url` is accessible and verification includes `--attachment-tag-prefix` or bundle context. |
| `admission webhook denied request: x509: certificate signed by unknown authority` | Kyverno/API Server cannot validate Fulcio/Custom CA root certificates. | Mount custom CA bundle inside admission controller deployment or define `certManager` in policy. |
| `ImagePullBackOff` post-admission | Policy mutated image tag to digest, but registry requires authentication for digest queries. | Verify `imagePullSecrets` have permission for `application/vnd.oci.image.manifest.v1+json` reads. |

### Diagnostic CLI Commands Checklist

```bash
# 1. Check Kyverno Webhook Execution Logs for Admission Rejections
kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "imageVerification"

# 2. Inspect Raw Kubernetes Admission Review Audit Events
kubectl get events -n production --field-selector reason=FailedCreate --sort-by='.metadata.creationTimestamp'

# 3. Manually Extract Image Digest from Remote OCI Registry (No local pull needed)
crane digest localhost:5000/sec-ops/app:v1.0.0

# 4. Dump OCI Attestation Layer directly from Registry
cosign download attestation --type cyclonedx localhost:5000/sec-ops/app:v1.0.0 | jq .payload | base64 -d | jq .
```

---

## 6. Real-World Architecture Trade-offs: In-Tree vs Out-of-Tree Verification

| Metric / Dimension | Native `ImagePolicyWebhook` (In-Tree) | Admission Controller (Out-of-Tree e.g. Kyverno/OPA) |
| :--- | :--- | :--- |
| **Control Layer** | Configured via `kube-apiserver` static flags (`--admission-control-config-file`). | Deployed as standard CRDs and controllers inside the cluster. |
| **Flexibility** | Rigid backend schema; requires custom webhook server implementation. | Native support for Cosign keyless, Fulcio OIDC, Rekor transparency logs, and CEL policies. |
| **Cluster Admin Friction** | Requires control plane API server restart for configuration updates. | Dynamic policy updates applied instantly without node/control-plane restarts. |
| **Fail-Open/Fail-Closed Risk** | Hardcoded in API server startup flags. API server hangs if webhook unreachable. | Controlled via policy `failurePolicy: Fail \| Ignore` at granular CRD levels. |

---

<details>
<summary><b>Answers & Explanations to Verification Questions</b></summary>

### Exercise 1 Answers

#### Answer 1.1
**Explanation:** Container image tags (e.g., `v1.0.0`) are mutable pointers in OCI registries. A malicious registry admin or attacker could perform a "Tag Sliding Attack" by overwriting `app:v1.0.0` with a malicious payload while keeping the tag name unchanged. Cryptographic signatures and attestations are calculated over the immutable SHA-256 digest of the OCI manifest. Verifying against the tag leaves a window where the tag could resolve to a different digest between verification and pod execution.

#### Answer 1.2
**Explanation:** The SBOM payload is encapsulated inside an **in-toto statement** payload signed by the secret private key (`cosign.key`). The signature covers both the statement metadata and the hash of the predicate payload (`sbom.json`). If an attacker alters any byte in `sbom.json`, the signature hash check will fail during `cosign verify-attestation`.

---

### Exercise 2 Answers

#### Answer 2.1
**Explanation:** `mutateDigest: true` instructs Kyverno to intercept the Pod submission (which might use a tag like `image: app:v1.0.0`) and resolve it to its current immutable digest (e.g., `image: app@sha256:d875...`), mutating the Pod specification before persisting it to `etcd`. This prevents **Time-of-Check to Time-of-Use (TOCTOU)** attacks where the Kubelet pulls a different image digest than the one validated by the admission controller during API submission.

#### Answer 2.2
**Explanation:** If `failurePolicy` is set to `Ignore`, any failure of the admission controller (such as webhook timeouts, pod crashes, network partition, or OOMKill events) causes the API server to **bypass validation** and allow Pod creation. This breaks the security boundary, allowing unverified or malicious images to run in production. Production supply chain policies must enforce `failurePolicy: Fail`.

---

### Exercise 3 Answers

#### Answer 3.1
**Explanation:** Rekor uses an append-only **Merkle Tree** data structure (similar to Certificate Transparency logs). Each entry's hash is incorporated into parent nodes up to the Root Hash (Signed Tree Head). Modifying or deleting an existing entry invalidates all subsequent nodes and changes the public Tree Head. External auditors continuously monitor and archive the Signed Tree Heads; any tampering by a server administrator would cause cryptographic proof mismatches (Inclusion and Consistency Proofs) that are immediately detectable.

#### Answer 3.2
**Explanation:** Although the Fulcio X.509 certificate issued to the builder expires in minutes, the keyless signature verification relies on the **Signed Entry Timestamp (SET)** issued by Rekor. During verification, `cosign` checks that:
1. The signature was created while the short-lived X.509 certificate was valid.
2. The exact timestamp of creation is cryptographically proven by Rekor's Signed Entry Timestamp.  
Because the timestamp proves the signature occurred *during* the certificate's validity period, the signature remains valid indefinitely.

</details>