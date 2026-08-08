# KCSA Study Guide: Domain 1.5 – Artifact Repository and Image Security

**Exam:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Cloud Native Security Architecture  
**Topic 1.5:** Artifact Repository and Image Security  
**Weight:** 2.33%  

---

## 1. Motivation and Production Architectural Problem

In a cloud-native production environment, the container registry and artifact pipeline serve as the primary entry point for external code into the internal infrastructure. Modern container supply chain security operates under a zero-trust threat model, assuming that public base images, CI/CD runners, third-party dependencies, and registry storage layers are constantly exposed to compromise vectors.

```
+------------------+      +-------------------+      +----------------------+      +-----------------------+
|  Developer Code  | ---> |   CI/CD Pipeline  | ---> |   OCI Artifact Reg.  | ---> |  K8s Admission Ctrl  |
| (Dep. Confusion) |      | (Runner Takeover) |      | (Tag Re-pointing/MITM|      | (Unsigned / CVE Pod)  |
+------------------+      +-------------------+      +----------------------+      +-----------------------+
```

### Core Production Architectural Failures

1. **Mutable Image Tagging and Non-Deterministic Builds**  
   Relying on floating tags (e.g., `:latest`, `:v1.2`) introduces runtime non-determinism. An attacker with write access to an OCI registry can overwrite a tag without altering the tag string, causing nodes executing `imagePullPolicy: Always` to pull malicious layers. Furthermore, `imagePullPolicy: IfNotPresent` on mutable tags leads to silent cluster state drift across nodes depending on local cache timestamps.

2. **Absence of Cryptographic Image Provenance and Attestation**  
   Without verifiable cryptographic signatures attached directly to OCI artifacts, Kubernetes nodes cannot distinguish between an image compiled by an authorized CI build runner and a malicious image injected via a compromised registry, stolen credentials, or Man-in-the-Middle (MitM) attacks.

3. **Undetected Vulnerabilities & Opaque Software Supply Chains**  
   Modern container images package operating system packages (deb/rpm/apk) alongside language-specific dependencies (npm, PyPI, Go modules). Deploying images without an explicit, machine-readable Software Bill of Materials (SBOM) and continuous vulnerability index scanning exposes clusters to known Remote Code Execution (RCE) vectors (e.g., Log4Shell, heartbleed, glibc exploits).

4. **Insecure Registry Authentication and Network Routing**  
   Exposing container registries without granular Role-Based Access Control (RBAC), immutable tag enforcement, TLS mutual authentication, or private network endpoints (e.g., Cloud Provider Private Endpoints, VPC Peering) enables credential leakage, unauthorized image pushes, and network-level interception.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Cryptographic Image Signing Frameworks: Cosign (Sigstore) vs. Notary v2 (Notation) vs. Notary v1 (TUFR)

| Parameter / Feature | Sigstore / Cosign | Notary v2 (Notation / ORAS) | Notary v1 (Docker Content Trust) |
| :--- | :--- | :--- | :--- |
| **Architecture** | Keyless (OIDC + Fulcio PKI + Rekor log) or static keypairs | X.509 PKI standard (Certificates, Code Signing Certs) | The Update Framework (TUF) with client-side keys |
| **Storage Mechanism** | OCI Artifact Spec (attestations/signatures stored as OCI layers alongside image) | OCI Artifact Manifest & Reference Spec | External Notary Server (separate database / API server) |
| **Root of Trust** | Sigstore Public Good Instance or Private Sigstore Stack (Fulcio, Rekor) | Enterprise Root CA / PKI Infrastructure (e.g., AWS KMS, Azure Key Vault) | Self-managed Notary Server & TUF Key Hierarchy |
| **Transparency Log Integration** | Native (Rekor immutable append-only ledger) | Optional / Vendor Specific | None |
| **K8s Ecosystem Adoption** | High (Native integration with Kyverno, Gatekeeper, Connaisseur) | Medium (Supported via Notation K8s plugins) | Low / Legacy (Deprecated in modern Kubernetes pipelines) |
| **Operational Overhead** | Low (Keyless eliminates static private key management) | Medium (Requires managing X.509 certificate lifecycles & CRLs/OCSP) | High (Complex multi-key management: root, targets, snapshot, timestamp) |

### 2.2 Image Vulnerability Scanning Architectures

| Strategy | Execution Point | Pros | Cons / Trade-offs |
| :--- | :--- | :--- | :--- |
| **CI/CD Pipeline Scanning** *(e.g., Trivy, Grype)* | Pre-push (GitHub Actions, GitLab CI, Tekton) | Fails early in the development lifecycle; zero runtime overhead. | Cannot detect zero-days discovered *after* deployment; depends on developer compliance. |
| **Registry Scanning** *(e.g., Harbor + Trivy/Clair)* | In-registry (On push or cron schedule) | Centralized control; prevents distribution of compromised images. | High CPU/IO burden on storage nodes; limited visibility into cluster runtime context. |
| **In-Cluster Operator Scanning** *(e.g., Trivy Operator)* | Post-deployment (Continuous cluster poll) | Provides real-time visibility into running workload CVE risk profiles. | Resource consumption on control plane/worker nodes; remediation requires cluster-side rolling updates. |

### 2.3 Kubernetes Admission Control Mechanisms for Image Policy Enforcement

| Feature | Kyverno `ClusterPolicy` | OPA Gatekeeper (`ConstraintTemplate`) | Native `ImagePolicyWebhook` |
| :--- | :--- | :--- | :--- |
| **Domain-Specific Language** | Declarative YAML (Native K8s pattern) | Rego (Declarative logic query language) | Go (Requires custom HTTP Webhook Server) |
| **Image Verification Support** | Native `verifyImages` block (Cosign, Notary, Keyless) | Requires custom Rego extension / External Data features | Native API interface, but custom logic must be built into webhook |
| **Failure Mode (`failurePolicy`)** | `Fail` or `Ignore` configurable per policy | `Fail` or `Ignore` configurable per policy | Configured in kube-apiserver admission config file |
| **Maintenance Complexity** | Low | Medium (Requires Rego proficiency) | High (Requires building, patching, and scaling custom microservices) |

---

## 3. Production Manifold YAML Manifests

### Manifest 1: Kyverno `ClusterPolicy` enforcing Cosign Keyless Verification & SHA256 Digest Immutability

This manifest enforces two critical production gates:
1. Every container image must be referenced by an immutable `sha256` digest rather than a mutable tag.
2. Every image must contain a valid cryptographic signature signed by Sigstore keyless workflow (Fulcio OIDC + Rekor Transparency Log verification).

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-image-signature-and-digest
  annotations:
    policies.kyverno.io/title: Enforce Cosign Keyless Signature and Immutable Digest
    policies.kyverno.io/category: Supply Chain Security
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod, Deployment, StatefulSet, DaemonSet
    description: >-
      Blocks any pod creation if images are not pinned to an immutable digest (sha256)
      or if images fail Cosign keyless signature verification against the corporate OIDC issuer.
spec:
  validationFailureAction: Enforce
  background: false
  webhookTimeoutSeconds: 15
  rules:
    - name: reject-mutable-tags
      match:
        any:
        - resources:
            kinds:
              - Pod
      validate:
        message: "Image tag must use immutable digest reference (@sha256:...)."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                all:
                  - key: "{{ element.image }}"
                    operator: NotRegexMatch
                    value: "^.*@sha256:[a-fA-F0-9]{64}$"
    - name: verify-cosign-keyless-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
      verifyImages:
        - imageReferences:
            - "cr.enterprise.io/production/*"
            - "docker.io/enterprise/*"
          mutateDigest: true
          verifyDigest: true
          required: true
          keyless:
            issuer: "https://token.actions.githubusercontent.com"
            subject: "https://github.com/enterprise-org/core-services/.github/workflows/build-pipeline.yml@refs/heads/main"
            rekor:
              url: "https://rekor.sigstore.dev"
```

---

### Manifest 2: OPA Gatekeeper `ConstraintTemplate` and `Constraint` enforcing Allowed Container Registries

This template verifies that pod containers only load images from approved, internal OCI enterprise registries.

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8sallowedregistries
  annotations:
    metadata.gatekeeper.sh/title: Allowed Registries
    description: Requires container images to originate from an approved list of corporate registries.
spec:
  crd:
    spec:
      names:
        kind: K8sAllowedRegistries
      validation:
        openAPIV3Schema:
          type: object
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.io/genericadmissionwebhook
      rego: |
        package k8sallowedregistries

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("Container image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }

        violation[{"msg": msg}] {
          container := input.review.object.spec.initContainers[_]
          satisfied := [good | repo := input.parameters.registries[_]; good := startswith(container.image, repo)]
          not any(satisfied)
          msg := sprintf("InitContainer image '%v' comes from an unauthorized registry. Allowed registries: %v", [container.image, input.parameters.registries])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRegistries
metadata:
  name: restrict-pod-registries
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
      - "staging"
  parameters:
    registries:
      - "cr.enterprise.io/"
      - "777123456789.dkr.ecr.us-east-1.amazonaws.com/"
```

---

### Manifest 3: Production `ServiceAccount` with Private `imagePullSecrets` and Restricted Local Pull Policy

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: enterprise-registry-credentials
  namespace: production
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: e3ogImF1dGhzIjogeyAiY3IuZW50ZXJwcmlzZS5pbyI6IHsgImF1dGgiOiAiWTI5dWRISnBaMjh6TVROaFkyTnZNV1V6TW1VPSIgfSB9IH0=
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secure-workload-sa
  namespace: production
imagePullSecrets:
  - name: enterprise-registry-credentials
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-processor
  namespace: production
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
      serviceAccountName: secure-workload-sa
      containers:
        - name: processor
          image: cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
```

---

### Manifest 4: Kubernetes Control Plane `ImagePolicyWebhook` Admission Configuration

To enable API Server-level image evaluation, configure the `--admission-control-config-file` on `kube-apiserver`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/imagepolicy-kubeconfig.yaml
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: false
```

Supporting Kubeconfig for the admission webhook server:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: image-checker
    cluster:
      certificate-authority: /etc/kubernetes/admission/certs/ca.crt
      server: https://image-verifier.security.svc.cluster.local:8443/check-image
users:
  - name: apiserver
    user:
      client-certificate: /etc/kubernetes/admission/certs/apiserver-client.crt
      client-key: /etc/kubernetes/admission/certs/apiserver-client.key
contexts:
  - name: image-checker-context
    context:
      cluster: image-checker
      user: apiserver
current-context: image-checker-context
```

---

## 4. Execution Commands and Real Terminal Outputs

### 4.1 Generating Keypair and Signing Container Image with Cosign

```bash
$ cosign generate-key-pair
Enter password for private key: 
Confirm password for private key: 
Private key written to cosign.key
Public key written to cosign.pub

$ cosign sign --key cosign.key cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Enter password for private key:
Pushing signature to: cr.enterprise.io/production/payment-service

$ cosign verify --key cosign.pub cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

```json
[
  {
    "critical": {
      "identity": {
        "docker-reference": "cr.enterprise.io/production/payment-service"
      },
      "image": {
        "docker-manifest-digest": "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      },
      "type": "cosign container image signature"
    },
    "optional": {
      "Bundle": {
        "SignedEntryTimestamp": "MEUCIQD..."
      }
    }
  }
]
```

---

### 4.2 Generating an SPDX Software Bill of Materials (SBOM) with Syft and Attesting via Cosign

```bash
$ syft cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 -o spdx-json > sbom.spdx.json
 ✔ Loaded image                                
 ✔ Parsed image                                
 ✔ Cataloged packages      [142 packages]

$ cosign attest --key cosign.key --type spdx --predicate sbom.spdx.json cr.enterprise.io/production/payment-service@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Enter password for private key: 
Uploading attestation to cr.enterprise.io/production/payment-service
```

---

### 4.3 Vulnerability Scanning with Trivy and CI/CD Gate Enforcement

```bash
$ trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed cr.enterprise.io/production/payment-service:v1.2.0
```

```
2026-08-07T19:30:11.102Z    INFO    Vulnerability scanning is enabled
2026-08-07T19:30:11.102Z    INFO    Identified OS: alpine 3.18.2
2026-08-07T19:30:11.103Z    INFO    Detecting Alpine vulnerabilities...

cr.enterprise.io/production/payment-service:v1.2.0 (alpine 3.18.2)
===================================================================
Total: 2 (HIGH: 1, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬-------------------┬---------------+----------------------------------┐
│   Library    │ Vulnerability  │ Severity │ Installed Version │ Fixed Version │              Title               │
├──────────────┼────────────────┼──────────┼-------------------┼---------------+----------------------------------┤
│ libcrypto3   │ CVE-2023-3817  │ HIGH     │ 3.1.1-r1          │ 3.1.1-r3      │ openssl: excessive time spent    │
│              │                │          │                   │               │ checking DH keys                 │
│ libssl3      │ CVE-2023-44487 │ CRITICAL │ 3.1.1-r1          │ 3.1.1-r4      │ HTTP/2 Rapid Reset Attack        │
└──────────────┴────────────────┴──────────┴-------------------┴---------------+----------------------------------┤

Error: exit status 1
```

---

### 4.4 Triggering and Inspecting Kubernetes Admission Control Blockage

Attempting to run an image without a digest tag when policy is active:

```bash
$ kubectl run untrusted-pod --image=docker.io/library/nginx:latest -n production
Error from server (Forbidden): admission webhook "validate.kyverno.svc-fail" denied the request: 

policy Pod/production/untrusted-pod error:

enforce-image-signature-and-digest:
  reject-mutable-tags:
    element.image: Image tag must use immutable digest reference (@sha256:...).
```

Attempting to run an image from an unauthorized registry:

```bash
$ kubectl run untrusted-reg-pod --image=docker.io/untrusteduser/app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 -n production
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [restrict-pod-registries] Container image 'docker.io/untrusteduser/app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' comes from an unauthorized registry. Allowed registries: ["cr.enterprise.io/", "777123456789.dkr.ecr.us-east-1.amazonaws.com/"]
```

---

## 5. Verification and Diagnostic Guide

### 5.1 Failure Diagnostic Matrix

```
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Symptom                            | Root Cause                            | Verification & Resolution Step                              |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| ImagePullBackOff (401 Unauthorized)| SA missing `imagePullSecrets` or RBAC | `kubectl get sa <sa-name> -o yaml`; verify dockerconfigjson  |
|                                    | token expired.                        | secret payload and test via `docker login`.                 |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Admission Webhook Timeout (504)    | Policy Webhook server deadlocked or   | Check webhook `failurePolicy`. Inspect logs of Kyverno/OPA  |
|                                    | network policy blocking port 9443.    | controller pods. Verify control plane egress to webhook.    |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| Cosign Verification Failure        | Signature artifact missing in registry| Confirm OCI spec compatibility. Run `cosign tree <image>`   |
|                                    | or Rekor log network offline.         | to verify `.sig` and `.att` OCI layer existence.            |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
| ImagePolicyWebhook Rejected        | `allowTTL` cache expired or backend   | Tail `kube-apiserver` logs filtering for `ImagePolicy`;     |
|                                    | returned `allow: false`.              | verify webhook server TLS cert validity.                    |
+------------------------------------+---------------------------------------+-------------------------------------------------------------+
```

### 5.2 Step-by-Step Production Troubleshooting Workflow

#### Step 1: Verify OCI Image Manifest Structure and Signature Layers
When `cosign verify` fails inside cluster admission controllers, manually verify the OCI tag layout:

```bash
$ cosign tree cr.enterprise.io/production/payment-service:v1.2.0
📦 Supply Chain Security Tree
└── 🐳 Image: cr.enterprise.io/production/payment-service:v1.2.0
    ├── 🎨 Signature: cr.enterprise.io/production/payment-service:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.sig
    └── 📜 Attestation: cr.enterprise.io/production/payment-service:sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.att
```

#### Step 2: Debugging Kyverno Admission Webhook Failures
If API server operations hang or reject valid deployments, query the Kyverno Admission Webhook status:

```bash
$ kubectl get clusterpolicies.kyverno.io enforce-image-signature-and-digest -o jsonpath='{.status}' | jq .

$ kubectl logs -n kyverno -l app=kyverno --tail=100 | grep -i "signature verification failed"
2026-08-07T19:35:22Z ERROR EngineMutate "failed to verify signature" logger="kyverno.verify-images" error="no matching signatures found for image cr.enterprise.io/production/payment-service@sha256:e3b0c442..."
```

#### Step 3: Inspecting Control Plane API Server Logs for ImagePolicyWebhook
If using native Kubernetes `ImagePolicyWebhook`:

```bash
$ kubectl logs -n kube-system kube-apiserver-control-plane-0 | grep -i "imagepolicywebhook"
2026-08-07T19:36:01.123Z [IMAGE-POLICY] Image cr.enterprise.io/production/payment-service:latest rejected by webhook backend: Image tag 'latest' violates policy: forbidden-floating-tag.
```

---

## 6. References

* **CNCF KCSA Exam Curriculum**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Official Documentation – Image Policy Webhook**:  
  https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
* **Kubernetes Official Documentation – Pulling Images from Private Registries**:  
  https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
* **Sigstore Cosign Documentation**:  
  https://docs.sigstore.dev/cosign/overview/
* **Kyverno Image Verification Documentation**:  
  https://kyverno.io/docs/writing-policies/verify-images/
* **OPA Gatekeeper Documentation**:  
  https://open-policy-agent.github.io/gatekeeper/website/docs/
* **NIST SP 800-190 (Application Container Security Guide)**:  
  https://csrc.nist.gov/publications/detail/sp/800-190/final
* **Anchore Syft (SBOM Generator)**:  
  https://github.com/anchore/syft
* **Aqua Security Trivy (Vulnerability Scanner)**:  
  https://github.com/aquasecurity/trivy