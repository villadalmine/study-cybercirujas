# KCSA Study Guide — Section 5.1: Supply Chain Security

**Domain**: Supply Chain Security  
**Exam**: CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain Weight**: ~2.29%  
**Target Audience**: Senior SREs, Security Engineers, and Platform Architects  

---

## 1. Production Motivation and Architectural Problem

Modern cloud-native deployment models rely heavily on third-party dependencies, public container registries, and automated CI/CD build environments. This introduce significant vulnerability vectors across the software lifecycle. A **Software Supply Chain Attack** occurs when an adversary compromises a component upstream of the target application—such as a base container image, open-source dependency library, build runner, or deployment artifact—to inject malicious logic prior to execution inside the Kubernetes cluster.

### Supply Chain Attack Vectors in Kubernetes

1. **Tag Mutability & Image Swapping**: Container tags like `:latest` or `:v1.2.0` are mutable pointer references within OCI registries. An attacker compromising a registry or intercepting network traffic can overwrite a tagged image with malicious code while preserving the tag name.
2. **Compromised Build Pipelines (CI/CD Tampering)**: If build infrastructure (e.g., GitHub Actions runners, Tekton tasks, Jenkins nodes) lacks cryptographic isolation, an attacker can modify binaries during compilation or inject malicious layers post-build.
3. **Dependency Poisoning & Typosquatting**: Ingestion of unverified packages from public repositories (PyPI, npm, crates.io) introduces backdoor code directly into the container filesystem.
4. **Lack of Provenance & Attestation**: Deploying artifacts without verifiable proof of *who* built the image, *how* it was built, and *what source code commit* it originated from makes non-repudiation impossible.

### Architectural Blueprint: Zero Trust Supply Chain Enforcement

To prevent unverified software execution, Kubernetes clusters must implement a **Zero Trust Supply Chain Architecture**. This requires moving security controls left into the build pipeline while enforcing dynamic cryptographic verification at the cluster perimeter via an **Admission Controller**.

```
  +-----------------------------------------------------------------------------------+
  |                                BUILD & ATTESTATION PHASE                          |
  |                                                                                   |
  |  +------------+     +-------------------+     +--------------------------------+  |
  |  | Git Commit | --> |  Hermetic Build   | --> | Build OCI Image + Syft SBOM    |  |
  |  +------------+     +-------------------+     +--------------------------------+  |
  |                                                              |                    |
  |                                                              v                    |
  |     +-------------------------+     +------------------------------------------+  |
  |     | Sigstore / Fulcio OIDC  | --> | Cosign Sign & Attest (SLSA Provenance)   |  |
  |     +-------------------------+     +------------------------------------------+  |
  |                                                              |                    |
  |                                                              v                    |
  |                                     +------------------------------------------+  |
  |                                     | Push Artifacts & Payload to Registry     |  |
  |                                     +------------------------------------------+  |
  +-------------------------------------------------------|---------------------------+
                                                          |
                                                          v
  +-----------------------------------------------------------------------------------+
  |                             KUBERNETES ADMISSION PHASE                            |
  |                                                                                   |
  |   kubectl apply -f deployment.yaml                                                |
  |                           |                                                       |
  |                           v                                                       |
  |         +-----------------------------------+                                     |
  |         |   Kubernetes API Server           |                                     |
  |         +-----------------------------------+                                     |
  |                           |                                                       |
  |                           v (Validating Webhook Call)                             |
  |         +-----------------------------------+                                     |
  |         | Kyverno / Gatekeeper Engine       |                                     |
  |         +-----------------------------------+                                     |
  |           /                               \                                       |
  |          /                                 \                                      |
  |         v                                   v                                     |
  |  Fetch Signature & Attestation      Verify Rekor Transparency Log                 |
  |  from Registry                      & OIDC Identity via Fulcio Root               |
  |         \                                   /                                     |
  |          \                                 /                                      |
  |           v                               v                                       |
  |         +-----------------------------------+                                     |
  |         |  Cryptographic Trust Decision     |                                     |
  |         +-----------------------------------+                                     |
  |                /                     \                                            |
  |         ALLOWED                       BLOCKED                                     |
  |            /                           \                                          |
  |           v                             v                                         |
  |  Pod Scheduled                API Server Rejects Request                          |
  |  to kubelet                   (HTTP Status 422 / Unprocessable)                   |
  +-----------------------------------------------------------------------------------+
```

### Key Security Abstractions

- **Digest Pinning**: Referencing container images by immutable cryptographic hash (`sha256:...`) instead of mutable tags (`:v1.0.0`).
- **Sigstore / Cosign**: An open-source standard for signing, verifying, and storing container signatures and attestations directly within OCI compliant registries.
- **SLSA (Supply-chain Levels for Software Artifacts)**: A security framework defining requirements for build integrity, provenance generation, and non-falsifiable metadata tracking across four progressive levels (SLSA v1.0).
- **Software Bill of Materials (SBOM)**: A structured nested inventory of software components, dependencies, and licensing details encoded in standard formats like SPDX or CycloneDX.

---

## 2. Technical Comparatives and Trade-off Analysis

### 2.1 Cryptographic Image Signing Methodologies

| Architectural Dimension | Static Asymmetric Keypairs (RSA/ECDSA) | Keyless Signing (Sigstore / Fulcio / Rekor) | PKI / Internal X.509 CA Signing |
| :--- | :--- | :--- | :--- |
| **Identity Model** | Long-lived asymmetric private key stored in CI secrets or KMS | Ephemeral X.509 certificate backed by OpenID Connect (OIDC) identity | Long-lived client certificate issued by Enterprise Internal CA |
| **Key Lifecycle Management** | High manual overhead; complex rotation and revocation procedures | Zero key management overhead; keys expire in minutes (typically 10 min) | Medium/High overhead; requires CRL/OCSP infrastructure |
| **Non-Repudiation** | Low; if the private key leaks, historical signatures can be forged retroactively | High; cryptographic timestamping bound to immutable Rekor transparency log | Medium; depends on CA timestamp authority integrity |
| **Air-Gapped Compatibility** | Native; requires no internet connectivity or external services | Requires self-hosted instances of Fulcio, Rekor, and Dex/OIDC issuer | Native; requires local internal CA connectivity |
| **Auditability** | Limited to key possession logs | Global/Internal cryptographic audit trail recorded in append-only Rekor log | Internal enterprise CA logs |

---

### 2.2 In-Cluster Policy Engine Mechanisms for Verification

| Evaluation Feature | Kyverno (`ClusterPolicy`) | OPA Gatekeeper + Ratify | Portieris |
| :--- | :--- | :--- | :--- |
| **DSL / Language** | Declarative YAML (Native K8s UX) | Rego (Datalog variant) | Declarative Custom Resources (CRDs) |
| **Cosign Verification Support** | Native inline `imageValidations` block | Via Ratify external provider integration | Native support for Notary v1 / Cosign |
| **Attestation/SBOM Check** | Native capability (`attestations` block with JMESPath filtering) | Flexible Rego policies over external payload queries | Limited to image signature validation |
| **Policy Mutation Ability** | Native (`mutate` rule can rewrite tags to exact digest hashes) | Requires Gatekeeper Mutations (separate controller) | Mutates image strings to digests |
| **Learning Curve** | Low (Standard K8s engineers) | High (Requires learning Rego and OPA mechanics) | Low/Medium |

---

## 3. Production Manifests and Infrastructure Code

### 3.1 GitHub Actions Workflow: Build, Syft SBOM, Cosign Keyless Sign & SLSA Attest

This workflow performs a build using `docker/build-push-action`, generates an SPDX SBOM via Syft, signs the OCI image keylessly via Sigstore using the GitHub OIDC id-token, and attaches SLSA provenance metadata.

```yaml
name: Production Supply Chain Pipeline

on:
  push:
    branches:
      - main
    tags:
      - 'v*'

permissions:
  contents: read
  id-token: write # Required for keyless OIDC signing with Sigstore/Fulcio
  packages: write

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-sign-attest:
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Install Cosign
        uses: sigstore/cosign-installer@v3.5.0

      - name: Install Syft
        uses: anchore/sbom-action/download-syft@v0.16.0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Metadata (Tags/Labels)
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=semver,pattern={{version}}
            type=sha,format=long

      - name: Build and Push OCI Image
        id: build-push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          provenance: false # Using custom Cosign attestation step below

      - name: Generate SPDX SBOM with Syft
        run: |
          syft ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }} \
            -o spdx-json=sbom.spdx.json

      - name: Keyless Sign OCI Image with Cosign
        run: |
          cosign sign --yes \
            -a "repo=${{ github.repository }}" \
            -a "workflow=${{ github.workflow }}" \
            -a "sha=${{ github.sha }}" \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"

      - name: Attest SBOM with Cosign
        run: |
          cosign attest --yes \
            --type spdx \
            --predicate sbom.spdx.json \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"

      - name: Attest SLSA Provenance with Cosign
        run: |
          cosign attest --yes \
            --type slsaprovenance \
            --predicate <(echo '{"builder":{"id":"https://github.com/actions/runner"}}') \
            "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}@${{ steps.build-push.outputs.digest }}"
```

---

### 3.2 Kyverno `ClusterPolicy`: Enforce Image Signatures, Keyless OIDC Identity, and Digest Mutability

This policy strictly enforces three supply chain invariants:
1. Every container image must be referenced using an explicit SHA256 digest (`mutate` rule).
2. Every image must contain a valid keyless signature issued by Fulcio under the specified GitHub Actions repository identity (`verifyImages` rule).
3. Every image must carry an attached SPDX SBOM attestation (`attestations` rule).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-supply-chain-integrity
  annotations:
    policies.kyverno.io/title: Enforce Image Signing and Digest Resolution
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: mutate-tags-to-digests
      match:
        any:
          - resources:
              kinds:
                - Pod
      mutate:
        mutateDigest:
          defaultWithDigest: true
          resolutionTimeoutSeconds: 10

    - name: verify-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/enterprise/production/*:*"
            - "ghcr.io/enterprise/production/*@sha256:*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main"
            rekor:
              url: "https://rekor.sigstore.dev"
          attestations:
            - type: https://spdx.dev/Document
              attestors:
                - count: 1
                  entries:
                    - keyless:
                        issuer: "https://token.actions.githubusercontent.com"
                        subject: "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main"
```

---

### 3.3 Production Workload Deployment (Pinned SHA256 Digest Reference)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: finance
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: financial-system
    sec.domain/supply-chain: verified
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-processor
  template:
    metadata:
      labels:
        app: payment-processor
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: processor
          # Immutable SHA256 digest pinned - bypasses tag mutation vulnerabilities
          image: ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8443
              name: https
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

---

## 4. Real Terminal CLI Executions and System Outputs

### 4.1 Local Image Inspection and Digest Extraction

```bash
$ crane digest ghcr.io/enterprise/production/payment-processor:v1.4.2
```
```text
sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

---

### 4.2 Verifying Keyless Signature with Cosign CLI

```bash
$ cosign verify \
  --certificate-identity="https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```
```text
Verification for ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Verification against the certificate was successful
  - The certificate was verified using the Fulcio root CA
  - The signature was verified using the payload
  - The SET verification was successful
  - The entry was verified against the Rekor log

[{"critical":{"identity":{"docker-reference":"ghcr.io/enterprise/production/payment-processor"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":{"Bundle":{"SignedEntryTimestamp":"MEUCIQDVz4K0J2...","Payload":{"body":"...","integratedTime":1723048912,"logIndex":104829104,"logID":"c0d23d...","entryUUID":"24258...\\"}}}}]
```

---

### 4.3 Extracting and Inspecting Attached SPDX Attestation

```bash
$ cosign verify-attestation \
  --type spdx \
  --certificate-identity="https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/enterprise/production/payment-processor@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
  | jq -r '.payload' | base64 --decode | jq .
```
```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://spdx.dev/Document",
  "subject": [
    {
      "name": "ghcr.io/enterprise/production/payment-processor",
      "digest": {
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      }
    }
  ],
  "predicate": {
    "SPDXID": "SPDXRef-DOCUMENT",
    "spdxVersion": "SPDX-2.3",
    "creationInfo": {
      "created": "2026-08-07T19:42:10Z",
      "creators": [
        "Tool: Anchore Syft-v0.16.0"
      ]
    },
    "packages": [
      {
        "name": "alpine-baselayout",
        "SPDXID": "SPDXRef-Package-apk-alpine-baselayout-3.4.3-r2",
        "versionInfo": "3.4.3-r2",
        "supplier": "Organization: Alpine Linux"
      },
      {
        "name": "openssl",
        "SPDXID": "SPDXRef-Package-apk-openssl-3.1.4-r0",
        "versionInfo": "3.1.4-r0",
        "supplier": "Organization: Alpine Linux"
      }
    ]
  }
}
```

---

### 4.4 Triggering an Admission Failure Blocked by Kyverno

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unverified-malicious-pod
  namespace: finance
spec:
  containers:
    - name: backdoor
      image: docker.io/library/nginx:latest
EOF
```
```text
Error from server (Forbidden): error when creating "STDIN": admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request:

resource Pod/finance/unverified-malicious-pod was blocked due to the following policies:

check-supply-chain-integrity:
  verify-cosign-keyless-signature:
    failed to verify signature for docker.io/library/nginx:latest:
      no matching signatures found for image docker.io/library/nginx:latest;
      certificate identity "https://github.com/enterprise/production-workloads/.github/workflows/deploy.yml@refs/heads/main" did not match actual certificate SAN
```

---

## 5. Verification and Failure Diagnostics Guide

When workload deployment fails at the admission controller stage due to supply chain policy violations, follow this systematic diagnostic workflow.

### Diagnostic Decision Tree

```
                          [Pod Deployment Failed / Rejected]
                                          |
                                          v
                      Execute: kubectl get events -n <namespace>
                                          |
                        +-----------------+-----------------+
                        |                                   |
              Webhook Timeout Error               Admission Denied (403/422)
                        |                                   |
                        v                                   v
          Inspect Webhook Connectivity            Inspect Kyverno/Gatekeeper Logs
           - Check DNS resolution                  - Identify policy rule name
           - Verify Webhook latency                - Verify OIDC SAN matching
```

### 5.1 Step 1: Query API Server Events

Determine if the failure originated from mutating/validating webhooks or kubelet image pulling:

```bash
$ kubectl get events -n finance --field-selector reason=FailedCreate --sort-by='.metadata.creationTimestamp'
```
```text
LAST SEEN   TYPE      REASON         OBJECT              MESSAGE
12s         Warning   FailedCreate   replica-set/pay-5   Error creating: admission webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc" denied the request: image verify failed
```

---

### 5.2 Step 2: Extract Kyverno Controller Webhook Logs

Inspect the policy engine container logs to extract the exact cryptographic assertion failure reason:

```bash
$ kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "signature verification failed"
```
```text
2026-08-07T20:05:14.281Z ERROR imageVerifier engine/image_verify.go:142 failed to verify image signature {"policy": "check-supply-chain-integrity", "rule": "verify-cosign-keyless-signature", "image": "ghcr.io/enterprise/production/payment-processor@sha256:e3b0c4...", "error": "verifying rekor entry: entry not found in transparency log index"}
```

---

### 5.3 Step 3: Common Root Causes & Remediation Matrices

#### Issue A: OIDC Identity / SAN Mismatch
* **Symptom**: `certificate identity ".../deploy.yml@refs/heads/dev" did not match policy subject ".../deploy.yml@refs/heads/main"`.
* **Root Cause**: The container image was built and signed on a feature branch (e.g., `dev` branch), but the deployment policy enforces that images must originate strictly from the `main` branch.
* **Remediation**: Re-trigger the build pipeline from an approved ref (`main` branch) or update the Kyverno `keyless.subject` regex pattern to support deployment environments accordingly.

#### Issue B: Missing Rekor Transparency Log Bundle
* **Symptom**: `SET verification failed: entry not found in Rekor`.
* **Root Cause**: The signature was created using `--insecure-ignore-tlog=true` during `cosign sign`, skipping transparency log publication.
* **Remediation**: Always include Rekor verification in production pipelines. Re-sign the image without skipping Rekor integration:
  ```bash
  $ cosign sign --yes ghcr.io/enterprise/production/payment-processor@sha256:<digest>
  ```

#### Issue C: Webhook Timeouts (`failurePolicy: Fail`)
* **Symptom**: `API server call to webhook timed out after 30 seconds`.
* **Root Cause**: Kyverno cannot communicate with external OIDC providers (`token.actions.githubusercontent.com`) or Rekor (`rekor.sigstore.dev`) due to egress firewall policy blocking port 443 from the `kyverno` namespace.
* **Remediation**: Apply a NetworkPolicy permitting egress from the admission controller namespace to external Sigstore PKI endpoints.

---

## 6. References

* **CNCF KCSA Curriculum**:  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

* **Sigstore Cosign Documentation**:  
  [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)

* **SLSA (Supply-chain Levels for Software Artifacts) Specification v1.0**:  
  [https://slsa.dev/spec/v1.0/](https://slsa.dev/spec/v1.0/)

* **Kyverno Policy Engine — Verify Images Documentation**:  
  [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)

* **The In-toto Framework Specification**:  
  [https://in-toto.github.io/](https://in-toto.github.io/)

* **SPDX (Software Package Data Exchange) Specification**:  
  [https://spdx.dev/specifications/](https://spdx.dev/specifications/)