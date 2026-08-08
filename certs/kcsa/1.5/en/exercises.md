# KCSA Domain 1.5: Artifact Repository and Image Security — Advanced Production Guide & Guided Exercises

**Target Certification:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Overview of Cloud Native Security / Cloud Native Architecture  
**Topic 1.5:** Artifact Repository and Image Security  
**Weight:** ~2.33%  
**Reference Document:** [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 1. Architectural Deep Dive & Internal Mechanics

### 1.1 OCI Image Architecture & Content-Addressable Storage
Container images in modern cloud-native environments adhere to the [Open Container Initiative (OCI) Image Format Specification](https://github.com/opencontainers/image-spec). An OCI image is not a monolithic binary file; it is a tree of cryptographically verifiable content-addressable blobs:

1. **Manifest (`application/vnd.oci.image.manifest.v1+json`)**: A JSON document referencing the config blob and layer diff blobs by their cryptographic hashes (SHA-256 digests).
2. **Configuration Blob**: Contains execution metadata (entrypoint, env variables, architecture) and the layer diff IDs (`diff_ids`).
3. **Layer Blobs (`application/vnd.oci.image.layer.v1.tar+gzip`)**: Tar archives containing filesystem deltas.

```
+---------------------------------------------------------------------------------+
|                               OCI Image Manifest                                |
|  - SchemaVersion: 2                                                             |
|  - Config: sha256:a3f12... (application/vnd.oci.image.config.v1+json)            |
|  - Layers:                                                                      |
|      * sha256:e8b31... (application/vnd.oci.image.layer.v1.tar+gzip)           |
|      * sha256:7c92a... (application/vnd.oci.image.layer.v1.tar+gzip)           |
+------------------------------------+--------------------------------------------+
                                     |
                +--------------------+--------------------+
                |                                         |
                v                                         v
+-------------------------------+       +-------------------------------+
|      Configuration Blob       |       |          Layer Blob           |
|  - Architecture: amd64        |       |  - Rootfs tarball archive     |
|  - Env, Entrypoint, Cmd       |       |  - SHA-256 match verified     |
+-------------------------------+       +-------------------------------+
```

#### Tag Mutability vs. Digest Immutability
- **Image Tags (`v1.2.0`, `latest`)**: Mutable pointers stored in the registry index. A malicious or compromised actor with write privileges can push a malicious image under an existing tag (e.g., `v1.2.0`), causing new pod deployments to pull compromised software without changing the Kubernetes deployment spec.
- **Image Digest (`sha256:3b94a8...`)**: Immutable, content-derived cryptographic identifier. Mutating a single byte inside any layer blob alters the calculated digest, causing verification failures at the container runtime engine (CRI) level during image fetch.

### 1.2 Supply Chain Threat Vectors & Defense-in-Depth
Image security requires addressing multiple threat vectors across the build-to-runtime lifecycle:

```
[ Developer Commit ] ---> [ Build/CI Pipeline ] ---> [ OCI Registry ] ---> [ K8s Admission ] ---> [ Container Runtime ]
        |                         |                         |                     |                       |
   (Compromised              (Poisoned Build           (Typosquatting /      (Unsigned /          (Runtime Privilege
    Dependency)               Dependencies)            Tag Overwrites)       Vulnerable Image)     Escalation/CVE)
```

1. **Vulnerability Injection**: Software dependencies containing known CVEs packaged into base images.
2. **Man-in-the-Middle (MitM) & Registry Tampering**: In-transit modification of image layers when pulling over unencrypted channels or from untrusted registries.
3. **Impersonation & Provenance Loss**: Inability to verify which actor built and published an image artifact.
4. **Bypassing Admission Controls**: Deploying unverified or non-compliant images directly into a Kubernetes cluster bypassing CI pipeline checks.

### 1.3 Cryptographic Signing & Attestations (Sigstore / Cosign Framework)
[Sigstore](https://www.sigstore.dev/) (a CNCF project) standardizes container software signing and provenance verification.

- **Cosign**: Signs OCI artifacts using ECDSA-P256 keys or keyless identity-based signing.
- **Fulcio**: Root Certificate Authority (CA) issuing short-lived X.509 certificates based on OpenID Connect (OIDC) identities (GitHub Actions, Google Cloud IAM, AWS IAM).
- **Rekor**: Immutable, append-only cryptographic transparency ledger (Merkle tree) recording signatures and attestations.
- **In-Toto Attestations & SBOMs**: Software Bill of Materials (SBOM) and SLSA (Supply-chain Levels for Software Artifacts) provenance documents signed and attached as OCI artifacts alongside the image.

---

## 2. Production Guided Exercises

### Exercise 1: Deep Inspection of OCI Manifests and Digest Pinning

#### Scenario
As a Senior SRE, you must eliminate image mutability risks in production deployments by extracting exact cryptographic SHA-256 digests directly from remote OCI registries and enforcing digest pinning in Kubernetes Pod specifications.

#### Step 1.1: Fetch and inspect an OCI image manifest using `skopeo`
Run `skopeo` to inspect the raw manifest structure of an image without pulling layers to the local Docker engine.

```bash
skopeo inspect --raw docker://registry.k8s.io/pause:3.9 | jq .
```

##### Expected Output
```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "size": 751,
    "digest": "sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867"
  },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 268048,
      "digest": "sha256:e01353272e84610fe93c72b2123c52e825000570b898236780c102a0a2eb727e"
    }
  ]
}
```

#### Step 1.2: Calculate the exact repository digest
Calculate the immutable digest for the tag `3.9`:

```bash
skopeo inspect docker://registry.k8s.io/pause:3.9 | jq -r '.Digest'
```

##### Expected Output
```text
sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
```

#### Step 1.3: Deploy a Production Pod using strict Digest Pinning
Create a production-ready manifest `hardened-pod.yaml` using explicit digest pinning.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: production-pause-pod
  namespace: default
  labels:
    app.kubernetes.io/name: pause-service
    app.kubernetes.io/sec-level: critical
spec:
  restartPolicy: Always
  containers:
  - name: pause
    image: registry.k8s.io/pause@sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        cpu: "50m"
        memory: "32Mi"
      requests:
        cpu: "10m"
        memory: "16Mi"
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 65535
      capabilities:
        drop:
        - ALL
```

Apply the pod manifest:

```bash
kubectl apply -f hardened-pod.yaml
```

##### Expected Output
```text
pod/production-pause-pod created
```

#### Step 1.4: Verify deployed Pod runtime image resolution
Confirm that Kubernetes resolves and displays the digest in status:

```bash
kubectl get pod production-pause-pod -o jsonpath='{.status.containerStatuses[0].imageID}'
```

##### Expected Output
```text
registry.k8s.io/pause@sha256:7031c1b2821c3d4111e89b43e860c047c4b75a2027d85d45e6985ac1cbe8d867
```

---

#### Verification Questions (Exercise 1)
1. **Question 1.1**: What happens if an upstream maintainer updates `registry.k8s.io/pause:3.9` to point to a new layer, but your Kubernetes manifest uses `@sha256:7031c1b2821c...`?
2. **Question 1.2**: Why is setting `imagePullPolicy: Always` insufficient on its own to prevent image tag poisoning?

---

### Exercise 2: Automated Vulnerability Scanning & Software Bill of Materials (SBOM) Generation

#### Scenario
To meet compliance controls, you must generate standard SPDX/CycloneDX SBOMs for container images prior to deployment, and evaluate them against vulnerability databases using `trivy` and `syft`.

#### Step 2.1: Generate an SBOM using `syft`
Generate a CycloneDX JSON SBOM artifact for an image:

```bash
syft image alpine:3.18.0 -o cyclonedx-json=alpine-3.18.0.sbom.json
```

##### Expected Output
```text
 ✔ Parsed image            [1 layers]
 ✔ Cataloged packages      [17 packages]
```

Inspect the generated SBOM schema structure:

```bash
jq '{bomFormat, specVersion, components_count: (.components | length)}' alpine-3.18.0.sbom.json
```

##### Expected Output
```json
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.4",
  "components_count": 17
}
```

#### Step 2.2: Scan the Container Image for Vulnerabilities using `trivy`
Perform a severity-filtered scan on the image, failing with exit code `1` if `CRITICAL` vulnerabilities exist:

```bash
trivy image \
  --severity CRITICAL,HIGH \
  --exit-code 1 \
  --ignore-unfixed \
  --format table \
  alpine:3.14.0
```

##### Expected Output
```text
alpine:3.14.0 (alpine 3.14.0)
Total: 3 (HIGH: 2, CRITICAL: 1)

+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
|    LIBRARY    |  VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION |                TITLE                |
+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
| ssl_client    | CVE-2021-36159   | CRITICAL | 1.33.1-r3         | 1.33.1-r4     | busybox: libbb/copy_file.0 in...    |
| zlib          | CVE-2022-37434   | HIGH     | 1.2.11-r4         | 1.2.12-r0     | zlib: heap-based buffer overflow... |
| apk-tools     | CVE-2021-36159   | HIGH     | 2.12.5-r0         | 2.12.7-r0     | libapk/apk_archive.c in apk-tools...|
+---------------+------------------+----------+-------------------+---------------+-------------------------------------+
```

#### Step 2.3: Scan SBOM directly instead of raw image layers
Scan the SBOM JSON document directly to decouple scanner engine image access from artifact policy evaluation:

```bash
trivy sbom alpine-3.18.0.sbom.json --severity CRITICAL
```

##### Expected Output
```text
alpine-3.18.0.sbom.json (cyclonedx)
Total: 0 (CRITICAL: 0)
```

---

#### Verification Questions (Exercise 2)
1. **Question 2.1**: What is the key operational advantage of scanning an SBOM document compared to executing a full container image filesystem scan inside a CI pipeline?
2. **Question 2.2**: Why is `--ignore-unfixed` used in production deployment gating pipelines, and what trade-off does it introduce?

---

### Exercise 3: Keyless and Key-Based Image Signing with Cosign & Attestation Attachment

#### Scenario
You must establish a cryptographic chain of custody for application artifacts using `cosign`. You will generate a keypair, sign a container image, attach an SBOM attestation as an OCI artifact, and cryptographically verify the signature.

#### Step 3.1: Generate ECDSA Key Pair
Generate a private/public keypair using `cosign`:

```bash
export COSIGN_PASSWORD="ProductionSecurePassword123!"
cosign generate-key-pair
```

##### Expected Output
```text
Private key written to cosign.key
Public key written to cosign.pub
```

#### Step 3.2: Sign a local OCI artifact / image digest
Assuming a local test image `localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef`:

```bash
cosign sign --key cosign.key --yes localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

##### Expected Output
```text
Enter password for private key: 
Pushing signature to: localhost:5000/app/sec-service
```

#### Step 3.3: Attach an in-toto SBOM Attestation to the Image
Attach the CycloneDX SBOM generated in Exercise 2 as an in-toto attestation layer:

```bash
cosign attest --key cosign.key \
  --type cyclonedx \
  --predicate alpine-3.18.0.sbom.json \
  localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

##### Expected Output
```text
Using payload from predicate file: alpine-3.18.0.sbom.json
Attestation pushed to OCI registry: localhost:5000/app/sec-service:sha256-1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef.att
```

#### Step 3.4: Cryptographically Verify the Signature using Public Key
Verify that the remote image hasn't been altered and was signed by the matching private key:

```bash
cosign verify --key cosign.pub localhost:5000/app/sec-service@sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef | jq .
```

##### Expected Output
```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "localhost:5000/app/sec-service"
      },
      "image": {
        "docker-manifest-digest": "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
      },
      "type": "cosign container image signature"
    },
    "optional": null
  }
]
```

---

#### Verification Questions (Exercise 3)
1. **Question 3.1**: Where does `cosign` store the generated signature for an OCI image when signing with key-based signatures by default?
2. **Question 3.2**: In "Keyless" signing using Sigstore, how are public keys managed and verified without long-lived private key files?

---

### Exercise 4: Admission Control Policy Enforcement with Kyverno

#### Scenario
You are tasked with deploying a Kyverno `ClusterPolicy` in block mode (`enforce`) to prevent any pod deployment if:
1. The image does not originate from an approved internal registry.
2. The image uses a mutable tag instead of an immutable SHA-256 digest.
3. The image is not cryptographically signed with the company's `cosign` public key.

#### Step 4.1: Write the Complete Kyverno Policy Manifest
Save the following complete, syntactically valid manifest to `verify-image-policy.yaml`.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-provenance-and-digests
  annotations:
    policies.kyverno.io/title: Enforce Registry, Digest Pinning, and Cosign Signatures
    policies.kyverno.io/category: Software Supply Chain Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
    description: >-
      Requires container images to originate from approved registries, use immutable SHA-256 
      digests, and pass cryptographic Cosign signature verification before pod admission.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
  - name: verify-registry-and-digest-format
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "Image must originate from 'registry.internal.net' or 'registry.k8s.io' and use a valid @sha256: digest."
      pattern:
        spec:
          containers:
          - image: "(registry.internal.net/*|registry.k8s.io/*)@sha256:*"
  - name: verify-cosign-signature
    match:
      any:
      - resources:
          kinds:
          - Pod
    imageExtractors:
      Pod:
      - name: containers
        path: /spec/containers/*
    verifyImages:
    - imageReferences:
      - "registry.internal.net/*"
      key: |
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEU2lnbmF0dXJlVmVyaWZpY2F0aW9u
        S2V5Rm9yS0NTQUNlcnRpZmljYXRpb25UZXN0aW5nRW52aXJvbm1lbnRPbmx5MDA9
        -----END PUBLIC KEY-----
```

#### Step 4.2: Apply the Kyverno ClusterPolicy
Apply the policy manifest:

```bash
kubectl apply -f verify-image-policy.yaml
```

##### Expected Output
```text
clusterpolicy.kyverno.io/enforce-image-provenance-and-digests created
```

#### Step 4.3: Test Non-Compliant Pod Deployment (Blocked by Admission Webhook)
Attempt to deploy an unapproved image using a mutable tag (`nginx:latest`):

```bash
kubectl run non-compliant-test --image=nginx:latest
```

##### Expected Output
```text
Error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request: 
resource Pod/default/non-compliant-test was blocked due to the following policy rules:
verify-registry-and-digest-format: Image must originate from 'registry.internal.net' or 'registry.k8s.io' and use a valid @sha256: digest.
```

---

#### Verification Questions (Exercise 4)
1. **Question 4.1**: What failure occurs in the Kubernetes control plane if a `ValidatingWebhookConfiguration` for image signature verification is configured with `failurePolicy: Fail` and the webhook backend becomes unreachable?
2. **Question 4.2**: What is the purpose of setting `background: false` in Kyverno policies that perform external cryptographic image signature checks?

---

### Exercise 5: Private Registry Security, RBAC, and OCI Distribution Specification

#### Scenario
You must configure production access controls and vulnerability scanning rules for a private container registry conforming to the [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec).

#### Step 5.1: Configure Harbor Registry Robot Account RBAC
Create a read-only robot account configuration payload `robot-reader.json` for pull-only deployment service accounts:

```json
{
  "name": "k8s-image-puller",
  "description": "Production Kubernetes Cluster Pull-Only Robot Account",
  "secret": "ProductionSuperSecretRobotKey2026!",
  "level": "system",
  "disable": false,
  "duration": -1,
  "permissions": [
    {
      "resource": "repository",
      "action": "pull",
      "namespace": "production-apps"
    },
    {
      "resource": "artifact-addition",
      "action": "read",
      "namespace": "production-apps"
    }
  ]
}
```

#### Step 5.2: Create Kubernetes `docker-registry` ImagePullSecret
Store the registry robot account credentials into a Kubernetes secret within the `default` namespace:

```bash
kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=registry.internal.net \
  --docker-username='robot$k8s-image-puller' \
  --docker-password='ProductionSuperSecretRobotKey2026!' \
  --docker-email='sre-team@company.internal'
```

##### Expected Output
```text
secret/harbor-pull-secret created
```

#### Step 5.3: Attach `imagePullSecrets` to a Namespace ServiceAccount
Bind the secret to the default ServiceAccount so pods do not require individual secret references:

```bash
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "harbor-pull-secret"}]}'
```

##### Expected Output
```text
serviceaccount/default patched
```

---

#### Verification Questions (Exercise 5)
1. **Question 5.1**: What security risk arises when developers use user-level personal access tokens (PATs) instead of scoped Robot Accounts inside CI/CD pipelines for image pushing?
2. **Question 5.2**: In an OCI-compliant registry, what capability does setting a project policy to "Immutable Tags" provide against supply chain attacks?

---

## 3. Verification Answers & Diagnostic Explanations

<details>
<summary><strong>Click to expand Answers and Detailed Technical Explanations</strong></summary>

### Exercise 1 Answers
- **Answer 1.1**: The pod deployment will continue to run and pull the exact original layer content defined by the `@sha256:...` digest string. The container runtime resolves images by digest content-hash rather than tag names. The upstream tag change is completely ignored by Kubernetes, ensuring deterministic, reproducible deployments.
- **Answer 1.2**: `imagePullPolicy: Always` forces the Kubelet to contact the remote registry to verify if the tag digest has changed. However, if an attacker overwrites the remote tag `v1.2.0` with a malicious payload, Kubelet will detect a updated digest under that same tag name and pull the compromised image. Digest pinning prevents this because the specified digest itself is part of the request filter.

---

### Exercise 2 Answers
- **Answer 2.1**: Scanning an SBOM JSON document takes milliseconds and consumes negligible CPU/RAM because it operates purely on structured text data (package names and version strings), avoiding the computational overhead of pulling multi-gigabyte tarball layers, uncompressing layer diffs, and traversing full file systems. It also allows vulnerability re-scanning without storage access to the original container images.
- **Answer 2.2**: `--ignore-unfixed` filters out reported CVEs that currently have no patch released by upstream distribution maintainers.  
  *Operational Trade-off*: It reduces developer noise and pipeline friction by focusing on actionable vulnerabilities. However, it introduces security risks by hiding zero-day or unpatched vulnerabilities that require mitigating security controls (such as network policies, apparmor profiles, or WAF rules).

---

### Exercise 3 Answers
- **Answer 3.1**: By default, `cosign` writes the signature directly back to the target OCI registry as a secondary OCI manifest artifact formatted with the tag tag-name pattern: `sha256-<digest>.sig`. This stores signatures directly alongside the original container image blobs without requiring an external signature storage database.
- **Answer 3.2**: In Keyless signing, short-lived ECDSA key pairs are generated ephemerally in memory by `cosign`. `Fulcio` (the Root CA) validates the developer's or CI process's OIDC identity token (e.g., GitHub Actions token) and issues an X.509 certificate valid for a brief window (e.g., 10 minutes) containing the OIDC identity. The signature and certificate are submitted to `Rekor` (the immutable Merkle tree transparency log). Verifiers inspect Rekor and Fulcio root certificate chains to validate identity without managing long-lived public key files.

---

### Exercise 4 Answers
- **Answer 4.1**: If the admission webhook service fails or becomes unreachable under `failurePolicy: Fail`, the Kubernetes API server will reject **all** Pod creation and update requests across the cluster that match the webhook rule. This protects against unvalidated deployments but can cause complete control-plane outages if the admission controller infrastructure fails.
- **Answer 4.2**: `background: false` disables Kyverno's background audit scanning controller for that specific rule. Because cryptographic image verification requires making network calls to remote registries to retrieve OCI signatures and public keys, running these checks continuously in background loops would generate massive network overhead and rate-limiting issues against registries.

---

### Exercise 5 Answers
- **Answer 5.1**: User-level PATs possess the full access permissions of the human identity (often spanning write/delete access across multiple namespaces and administrative capabilities). If leaked from CI pipeline logs or build runners, attackers gain broad write and deletion access. Robot Accounts provide Least Privilege through fine-grained RBAC limited to specific actions (`pull` only) and single repository scopes.
- **Answer 5.2**: Immutable Tag policies enforce write-once behavior at the registry API layer. Once a tag (e.g., `v2.4.1`) is pushed, the registry rejects subsequent `HTTP PUT` requests attempting to overwrite that tag, effectively blocking tag-poisoning attacks at the storage gateway level.

</details>

---

## 4. Official References & Citation URLs

1. **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
2. **Open Container Initiative (OCI) Image Specification**: [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
3. **OCI Distribution Specification**: [https://github.com/opencontainers/distribution-spec](https://github.com/opencontainers/distribution-spec)
4. **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
5. **Kyverno Image Verification Documentation**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
6. **Aqua Security Trivy Documentation**: [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)
7. **Anchore Syft Specification**: [https://github.com/anchore/syft](https://github.com/anchore/syft)
8. **Kubernetes Image Pull Secrets Guidance**: [https://kubernetes.io/docs/concepts/containers/images/#using-a-private-registry](https://kubernetes.io/docs/concepts/containers/images/#using-a-private-registry)