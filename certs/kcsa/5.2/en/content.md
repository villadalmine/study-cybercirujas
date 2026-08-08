# KCSA Study Guide — Topic 5.2: Image Repository

## 1. Production Motivation & Architectural Problem

### 1.1 The Container Supply Chain Threat Landscape
In enterprise Kubernetes environments, container image repositories serve as the gateway between software development and cluster runtime. Weak security controls at the repository layer expose clusters to severe supply chain attack vectors:

1. **Floating Tag Mutation & Image Tampering**: Container tags (e.g., `:latest` or `:v1.2.0`) are mutable pointers in OCI registries. An adversary who gains write access to an internal or public repository can overwrite a legitimate image tag with a malicious build containing backdoors or crypto-miners. If Kubelet pulls by tag rather than immutable SHA256 content digest, running workloads will silently absorb compromised binaries.
2. **Credential Proliferation & Sprawl**: Managing access to private image registries using Kubernetes static `corev1.Secret` objects (`kubernetes.io/dockerconfigjson`) introduces operational risk. These secrets are often duplicated across multiple namespaces, stored unencrypted at rest in `etcd`, and logged in CI/CD pipelines, increasing the attack surface for credential theft.
3. **Repository Typosquatting & Uncontrolled Pulls**: Without explicit registry restriction policies, developers or compromised deployment manifests can reference unauthorized, public, or untrusted external registries (`docker.io/malicious-user/nginx` instead of `private-registry.enterprise.internal/base/nginx`).
4. **Vulnerable Artifact Ingestion**: Images pulled without mandatory vulnerability scanning or cryptographic attestation verification introduce known CVEs and non-compliant software directly into high-privilege production nodes.

### 1.2 Internal Mechanics: OCI Registry Pull Workflow & Admission Interception
When a Pod is scheduled onto a node, the process follows a structured sequence:

```
[ kubectl apply ] 
       │
       ▼
[ API Server ] ──(Validating Webhook)──► [ Policy Engine: Kyverno / OPA Gatekeeper ]
       │                                     (Verifies Signature & Registry Domain)
       │ (Persisted to etcd)
       ▼
[ Kubelet ] ──(CRI gRPC)──► [ Container Runtime: containerd / CRI-O ]
                                 │
                                 ├──► [ Credential Provider Plugin / imagePullSecrets ]
                                 │      (Retrieves Ephemeral OCI Token)
                                 │
                                 └──► [ OCI Registry API v2 ]
                                        (Pulls Layers by SHA256 Digest)
```

1. **Admission Phase**: The API Server passes the Pod spec through Validating Admission Webhooks (e.g., Kyverno or Gatekeeper). The policy engine intercepts the request, checks if the image URL matches allowed registries, and validates cryptographic signatures (e.g., Sigstore/Cosign) against Rekor transparency logs or trusted public keys.
2. **Credential Resolution**: If accepted, Kubelet invokes the Container Runtime Interface (CRI) to pull the image. The runtime resolves authorization tokens by first querying Pod-level `imagePullSecrets`, falling back to ServiceAccount `imagePullSecrets`, and finally executing Node-level dynamic Kubelet Credential Provider plugins.
3. **Layer Fetch & Manifest Verification**: The runtime communicates with the OCI Registry v2 API over TLS 1.3, retrieves the image manifest index, resolves layer tarballs via content-addressable digests (`sha256:...`), and extracts them onto the node storage overlay.

---

## 2. Technical Comparisons & Trade-offs

### Table 2.1: Registry Authentication & Credential Delivery Mechanisms

| Dimension | Static Kubernetes `imagePullSecrets` | Kubelet Credential Provider Plugin | Cloud IAM / Workload Identity (IRSA/WI) |
| :--- | :--- | :--- | :--- |
| **Mechanism** | Namespace-scoped `dockerconfigjson` Secrets linked to Pods or ServiceAccounts. | Executable binary called by Kubelet on demand to fetch ephemeral tokens. | Node/Pod assumes Cloud IAM role via OIDC token exchange to authenticate to ECR/GAR/ACR. |
| **Credential Lifetime** | Long-lived static basic auth or permanent API tokens. | Short-lived dynamic tokens (15 mins – 12 hours). | Short-lived ephemeral tokens managed by STS/OIDC. |
| **Operational Overhead** | High. Requires secret distribution across namespaces via operators or GitOps. | Medium. Requires daemonset/AMI installation of the plugin binary on node images. | Low once cloud OIDC provider and IAM roles are provisioned. |
| **Security Risk Profile** | High risk of secret exposure in `etcd`, CI/CD pipelines, and RBAC read access. | Low risk; credentials remain in node memory, never stored in Kubernetes API objects. | Zero static secret storage in Kubernetes; strictly gated by IAM role trust relationships. |
| **Scope of Access** | Per-namespace or per-ServiceAccount. | Node-wide for matching image domain patterns. | Per-node or per-Pod IAM role. |

### Table 2.2: Image Integrity & Provenance Verification Models

| Dimension | Cosign Key-Based Verification | Sigstore Keyless (Fulcio + Rekor) | Docker Content Trust (Notary v1) |
| :--- | :--- | :--- | :--- |
| **Identity Anchor** | Asymmetric Key Pair (RSA/ECDSA) stored in KMS or secret manager. | Short-lived x509 cert issued by Fulcio CA via OIDC Identity Provider (GitHub/Google). | Static X.509 keys managed via local Notary CLI repository state. |
| **Auditability** | Limited to key possession; no public append-only audit trail. | High. Signatures are recorded in Rekor public/private immutable transparency log. | Moderate; relies on Notary server timestamps. |
| **Key Management** | Manual rotation, secure storage, and risk of private key compromise. | Keyless. No private key management; identity tied to OIDC identity claims. | Complex key hierarchy (root, target, snapshot, timestamp keys). |
| **K8s Integration** | Supported natively by Kyverno, Gatekeeper/Ratify, and Connaisseur. | Native integration with modern admission engines via OIDC issuer checks. | Legacy; deprecated in modern OCI supply chain standards. |

---

## 3. Complete Production Manifests & Infrastructure Configurations

### 3.1 Secure ServiceAccount with Explicit `imagePullSecrets` and Restricted Spec
This manifest configures a production workload constrained to use an explicit ServiceAccount carrying image pull credentials, while enforcing digest pinning and `imagePullPolicy: Always`.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Secret
metadata:
  name: internal-registry-creds
  namespace: payment-processing
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ewogICJhdXRocyI6IHsKICAgICJyZWdpc3RyeS5wcm9kdWN0aW9uLmludGVybmFsIjogewogICAgICAiYXV0aCI6ICJZbVZrY21sdGFXNWxYM05sWTNKbGRGOTBZV3A1T25OMFlXMWxYMEU9IgogICAgfQogIH0KfQ==
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service-sa
  namespace: payment-processing
imagePullSecrets:
  - name: internal-registry-creds
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-processing
  labels:
    app.kubernetes.io/name: payment-api
    app.kubernetes.io/part-of: checkout-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: payment-service-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-server
          image: registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: "500m"
              memory: "512Mi"
            requests:
              cpu: "100m"
              memory: "128Mi"
          ports:
            - containerPort: 8443
              name: https
```

### 3.2 Kubelet Dynamic Credential Provider Configuration
This configuration is deployed directly to Kubelet nodes (`/etc/kubernetes/credential-provider-config.yaml`) to enable out-of-band, short-lived IAM token retrieval for AWS ECR without using static secrets in etcd.

```yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/v1
    args:
      - get-credentials
    env:
      - name: AWS_STS_REGIONAL_ENDPOINTS
        value: regional
```

### 3.3 Kyverno ClusterPolicy: Enforcing Registry Source and Cosign Keyless Image Verification
This cluster-wide policy enforces two non-negotiable production controls:
1. Rejects any container image coming from outside the internal trusted registry domain.
2. Verifies that images pulled from the trusted domain contain a valid keyless signature generated via Sigstore/Fulcio tied to the enterprise GitHub Actions repository OIDC identity.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-provenance-and-registry
  annotations:
    policies.kyverno.io/title: Enforce Image Provenance and Registry Lockdown
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Container
    kyverno.io/kyverno-version: 1.10.0
    kyverno.io/kubernetes-version: "1.26-1.28"
    description: >-
      Blocks untrusted registries and verifies Cosign keyless signatures via Fulcio/Rekor.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  failurePolicy: Fail
  rules:
    - name: restrict-registry-source
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Container image source is untrusted. Images must originate from registry.production.internal."
        pattern:
          spec:
            containers:
              - image: "registry.production.internal/*"
            =(initContainers):
              - image: "registry.production.internal/*"
            =(ephemeralContainers):
              - image: "registry.production.internal/*"

    - name: verify-cosign-keyless-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.production.internal/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/enterprise-org/secure-repo/.github/workflows/build-pipeline.yml@refs/heads/main"
                    rekor:
                      url: "https://rekor.sigstore.dev"
```

---

## 4. Real CLI Commands & Terminal Outputs

### 4.1 Keyless Container Image Signing with Cosign
Generating an OIDC-authenticated keyless signature for an image digest using Google Cloud Identity / OpenID Connect:

```bash
$ cosign sign --yes registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
Generating ephemeral keys...
Retrieving signed certificate from Fulcio...
Successfully obtained OIDC token for identity: developer@enterprise.com
Issuer: https://accounts.google.com
Url: https://fulcio.sigstore.dev
Creating signature with ephemeral key...
Uploading signature to registry...
Logging entry to Rekor transparency log...
Rekor entry created at index: 29481048
Signature uploaded to: registry.production.internal/finance/payment-api:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
```

### 4.2 Manual Cosign Signature Verification
Verifying the keyless signature against Fulcio and Rekor transparency log CLI before deployment:

```bash
$ cosign verify \
  --certificate-identity "https://github.com/enterprise-org/secure-repo/.github/workflows/build-pipeline.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
Verification for registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The claims were verified against the signature: true
  - Certificate is trusted by Fulcio Root CA
  - Certificate log entry was verified in Rekor transparency log
  - Certificate identity matches policy specification

[{"critical":{"identity":{"docker-reference":"registry.production.internal/finance/payment-api"},"image":{"docker-manifest-digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},"type":"cosign container image signature"},"optional":{"GitHubWorkflowTrigger":"push","GitHubWorkflowSha":"a1b2c3d4e5f67890123456789abcdef012345678"}}]
```

### 4.3 Static Vulnerability Scanning via Trivy with Severity Gating
Executing a strict local/CI vulnerability scan on the target image, failing on `CRITICAL` or `HIGH` vulnerabilities:

```bash
$ trivy image \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  --ignore-unfixed \
  --format table \
  registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```text
2026-08-07T20:15:00.123Z	INFO	Vulnerability scanning is enabled
2026-08-07T20:15:00.456Z	INFO	Loaded 12415 vulnerabilities from DB

registry.production.internal/finance/payment-api@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 (debian 12.1)
========================================================================================================================
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+
|   LIBRARY   | VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION |                 TITLE                 |
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+
| libssl3     | CVE-2023-3817    | HIGH     | 3.0.9-1           | 3.0.9-2       | OpenSSL: excessive time spending in   |
|             |                  |          |                   |               | DH check functions                    |
+-------------+------------------+----------+-------------------+---------------+---------------------------------------+

Error: exit status 1 (vulnerabilities found matching severity criteria)
```

### 4.4 Admission Controller Policy Rejection Log
Attempting to deploy an unauthorized image (`docker.io/library/nginx:latest`) that violates the policy:

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: untrusted-nginx
  namespace: payment-processing
spec:
  containers:
    - name: nginx
      image: docker.io/library/nginx:latest
EOF
```

```text
Error from server (Forbidden): error when creating "STDIN": pods "untrusted-nginx" is forbidden: admission webhook "kyverno-resource-validating-webhook" denied the request:

resource Pod/payment-processing/untrusted-nginx was blocked due to the following policies:

enforce-image-provenance-and-registry:
  restrict-registry-source: 'Container image source is untrusted. Images must originate
    from registry.production.internal.'
  verify-cosign-keyless-signature: 'failed to verify image signature for docker.io/library/nginx:latest:
    no matching signatures found'
```

---

## 5. Diagnostic & Failure Troubleshooting Guide

### 5.1 Diagnostic Decision Tree: Repository & Image Pull Failures

```
                    Image Pull / Pod Deployment Failure
                                     │
             ┌───────────────────────┴───────────────────────┐
             ▼                                               ▼
   Admission Phase Error                           Runtime Node Error
(Failed at API Server apply)                     (Pod state: ImagePullBackOff)
             │                                               │
   ┌─────────┴─────────┐                           ┌─────────┴─────────┐
   ▼                   ▼                           ▼                   ▼
Webhook Rejection   Policy Error               Authentication       Image/Digest
 (Kyverno/OPA)     (Timeout/Failure)              (401/403)           (404 Not Found)
   │                   │                           │                   │
 Check policy        Verify Admission            Check Secret /      Verify exact hash
 signatures /        Webhook service             Kubelet Credential  & registry network
 registry rules      latency & certs             Provider & Token    route (DNS/VPC)
```

### 5.2 Common Production Failure Modes & Root Cause Analysis

#### Failure Mode 1: `ImagePullBackOff` due to Missing or Malformed `imagePullSecrets`
* **Symptoms**: Pod status displays `ErrImagePull` or `ImagePullBackOff`. Running `kubectl describe pod <pod-name>` shows:
  `Failed to pull image "registry.production.internal/finance/payment-api:v1.0.0": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: unexpected status code 401 Unauthorized`.
* **Root Cause Analysis**:
  1. The target Secret does not exist in the Pod's local namespace (`payment-processing`). `imagePullSecrets` cannot reference Secrets across namespace boundaries.
  2. The `.dockerconfigjson` key inside the Secret payload contains invalid JSON or base64 decoding errors.
  3. The ServiceAccount lacks the binding to the secret.
* **Resolution Steps**:
  1. Verify Secret presence in namespace:
     ```bash
     $ kubectl get secret internal-registry-creds -n payment-processing -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode
     ```
  2. Validate auth tokens and ensure the registry hostname in `.dockerconfigjson` exactly matches the image string (`registry.production.internal` vs `http://registry.production.internal`).

#### Failure Mode 2: Kubelet Credential Provider Executable Failure
* **Symptoms**: Pod fails to pull images from cloud repositories (e.g., ECR/GAR) despite correct IAM roles. Kubelet log (`/var/log/journal/kubelet.service` or `journalctl -u kubelet`) shows:
  `Credential provider plugin "ecr-credential-provider" failed with exit code 127` or `plugin timed out after 30s`.
* **Root Cause Analysis**:
  1. The credential provider binary path `/usr/libexec/kubernetes/kubelet-plugins/credentialprovider/exec/ecr-credential-provider` is not executable (`chmod +x`) or is missing from node disk.
  2. The node's IAM instance profile lacks permissions to issue `ecr:GetAuthorizationToken` or `sts:AssumeRole`.
  3. Network policy or security group blocks node egress to the cloud STS/IAM endpoint.
* **Resolution Steps**:
  1. SSH to the affected node and manually execute the plugin binary to check stderr:
     ```bash
     $ /usr/libexec/kubernetes/kubelet-plugins/credentialprovider/exec/ecr-credential-provider get-credentials
     ```
  2. Inspect node IAM role associations via cloud CLI (`aws sts get-caller-identity` or `gcloud auth list`).

#### Failure Mode 3: Cosign Admission Verification Timeout or Rekor Unavailable
* **Symptoms**: Pod creation hangs for 15 seconds during `kubectl apply`, then fails with:
  `Internal error occurred: failed calling webhook "verify-images.kyverno.svc": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/mutate?timeout=15s": context deadline exceeded`.
* **Root Cause Analysis**:
  1. Kyverno admission controller is configured with `failurePolicy: Fail` and cannot reach the public Rekor transparency log (`https://rekor.sigstore.dev`) due to air-gapped node egress rules or firewall blocks.
  2. High latency or outages on public Sigstore infrastructure.
* **Resolution Steps**:
  1. Check network connectivity from within the policy engine pod to Rekor:
     ```bash
     $ kubectl exec -n kyverno -it deployment/kyverno -- curl -iv https://rekor.sigstore.dev/api/v1/log/publicKey
     ```
  2. For air-gapped production environments, deploy an internal Rekor and Fulcio instance, and update the Kyverno policy `rekor.url` field to point to internal services (`https://rekor.internal.domain`).

---

## 6. References

* **CNCF KCSA Exam Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Official Documentation — Images**: [https://kubernetes.io/docs/concepts/containers/images/](https://kubernetes.io/docs/concepts/containers/images/)
* **Kubernetes Official Documentation — Kubelet Credential Provider**: [https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
* **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
* **Kyverno Image Verification Reference**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
* **NIST SP 800-190 (Application Container Security Guide)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **CNCF TAG Security — Supply Chain Security Best Practices**: [https://github.com/cncf/tag-security/tree/main/supply-chain-security](https://github.com/cncf/tag-security/tree/main/supply-chain-security)