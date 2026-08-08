# KCSA Study Material: Topic 5.2 - Image Repository

**Certification:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** Supply Chain Security  
**Topic 5.2:** Image Repository  
**Exam Weight:** 2.29%  

---

## Architectural Deep Dive & Production Trade-offs

An Image Repository (or Container Registry) serves as the primary artifact store in cloud-native supply chains. In modern Kubernetes security architectures, securing the image repository lifecycle spans three distinct boundaries: **Authentication & Access Control**, **Artifact Integrity & Authenticity**, and **Vulnerability Governance**.

```
  +-----------------------------------------------------------------------------------+
  |                                 CONTAINER REGISTRY                                |
  |                                                                                   |
  |  +---------------------+      +---------------------+      +-------------------+  |
  |  |   OCI Image Manifest|      |  Layer Blobs (tar)  |      | Cosign Signature  |  |
  |  |   (sha256 digest)   |      |  (read-only layers) |      | (OCI Artifact)    |  |
  |  +----------+----------+      +----------+----------+      +---------+---------+  |
  +-------------|----------------------------|---------------------------|------------+
                |                            |                           |
                v                            v                           v
  +-----------------------------------------------------------------------------------+
  |                             KUBERNETES CONTROL PLANE                              |
  |                                                                                   |
  |  +-----------------------------------------------------------------------------+  |
  |  | ValidatingAdmissionWebhook (e.g., Kyverno / OPA Gatekeeper / ImagePolicy)  |  |
  |  | - Verifies Cosign Signature against PKI / Rekor Transparency Log           |  |
  |  | - Enforces Image Digest Pinning (mutates tag to @sha256:<hash>)             |  |
  |  +-------------------------------------+---------------------------------------+  |
  +----------------------------------------|------------------------------------------+
                                           v
  +-----------------------------------------------------------------------------------+
  |                                  WORKER NODE                                      |
  |                                                                                   |
  |  +-----------------------------------------------------------------------------+  |
  |  | Kubelet / CRI Runtime (containerd/CRI-O)                                    |  |
  |  | - Kubelet Credential Provider (exec plugin fetches short-lived OIDC tokens) |  |
  |  | - Pulls layers to local store (/var/lib/containerd/io.containerd.content)   |  |
  |  +-----------------------------------------------------------------------------+  |
  +-----------------------------------------------------------------------------------+
```

### 1. Authentication and Authorization Mechanics
* **ImagePullSecrets & ServiceAccounts:** Kubernetes decouples pod definitions from registry credentials by attaching `imagePullSecrets` directly to `ServiceAccount` objects or `PodSpec` definitions. During Pod scheduled state transition, the Kubelet extracts the secret token (Base64-encoded `.dockerconfigjson`) and transmits it via HTTP Basic Authentication or bearer tokens to the registry endpoint.
* **Kubelet Image Credential Provider:** Traditional static `imagePullSecrets` leak credentials across namespaces if misconfigured. Kubernetes production clusters utilize the `Kubelet Image Credential Provider` plugin pattern (`--image-credential-provider-config`). The Kubelet calls an out-of-band executable binary on the node to dynamically obtain short-lived cloud IAM tokens (e.g., AWS ECR, GCP GAR, Azure ACR) right before layer fetch operations.

### 2. Image Verification & Integrity (Supply Chain Security)
* **Tag vs. Digest Pinning:** Tags like `v1.2.0` or `latest` are mutable references subject to **man-in-the-middle (MITM)** substitution or malicious overwrite in the repository. Cryptographic digests (`sha256:abcd...`) represent immutable cryptographic hashes of the OCI Image Index/Manifest.
* **Sigstore & Cosign:** Modern artifact signing uses Sigstore (`cosign`). Signatures can be stored inside the OCI registry alongside the image as standard OCI artifacts or stored off-registry. Verification occurs at the Kubernetes Admission Control layer using mutating/validating webhooks prior to pod scheduling.

### 3. Vulnerability Scanning & Static Analysis
* **Scanning Scopes:** Static image analysis occurs at three pipeline stages:
  1. **CI/CD Pipeline Gate:** Blocks artifact push if CVE severity thresholds are exceeded.
  2. **Registry-Side Scanning:** Continuous asynchronous scanning of stored layers (e.g., Harbor + Trivy integration).
  3. **Admission Control Gate:** Validates scan result metadata before workload admission.

---

## Official References
* [Kubernetes Documentation: Images](https://kubernetes.io/docs/concepts/containers/images/)
* [Kubernetes Documentation: Kubelet Credential Provider](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/)
* [CNCF KCSA Exam Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* [Sigstore Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
* [Trivy Vulnerability Scanner Documentation](https://aquasecurity.github.io/trivy/)
* [Kyverno Image Verification Documentation](https://kyverno.io/docs/writing-policies/verify-images/)

---

## Guided Exercises

### Exercise 1: Enforcing Immutable Image Digests and ServiceAccount ImagePullSecrets

#### Context & Objectives
You need to configure a secure production namespace where workloads are restricted from pulling mutable tags (`:latest`) and must authenticate against a private OCI registry (`registry.internal.enterprise.io`) using a dedicated `ServiceAccount` credentials link.

#### Step 1: Create a Kubernetes Docker Registry Secret
Execute the CLI command to synthesize a `.dockerconfigjson` secret containing authenticated access tokens for the private repository:

```bash
kubectl create secret docker-registry private-registry-creds \
  --namespace=prod-secure \
  --docker-server=registry.internal.enterprise.io \
  --docker-username=svc-image-puller \
  --docker-password=dGhpcy1pcy1hLXNlY3VyZS10b2tlbi1mb3ItY3Jp \
  --docker-email=security-ops@enterprise.io \
  --dry-run=client -o yaml > registry-secret.yaml

kubectl create namespace prod-secure
kubectl apply -f registry-secret.yaml
```

**Expected Output:**
```
secret/private-registry-creds created (dry run)
namespace/prod-secure created
secret/private-registry-creds created
```

#### Step 2: Configure ServiceAccount Auto-Injection of ImagePullSecrets
Create a declarative ServiceAccount manifest (`serviceaccount-secure.yaml`) that automatically attaches `private-registry-creds` to any Pod that executes under its context:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secure-app-sa
  namespace: prod-secure
imagePullSecrets:
  - name: private-registry-creds
```

Apply the ServiceAccount manifest:

```bash
kubectl apply -f serviceaccount-secure.yaml
```

**Expected Output:**
```
serviceaccount/secure-app-sa created
```

#### Step 3: Deploy Pod with Digest Pinning (`sha256`)
Deploy a pod manifest (`pod-digest-pinned.yaml`) bound to `secure-app-sa` using strict SHA256 digest pinning instead of a mutable tag:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: payment-processor
  namespace: prod-secure
  labels:
    tier: payment
spec:
  serviceAccountName: secure-app-sa
  containers:
  - name: processor
    image: registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    imagePullPolicy: IfNotPresent
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 10001
```

Apply the Pod manifest:

```bash
kubectl apply -f pod-digest-pinned.yaml
```

**Expected Output:**
```
pod/payment-processor created
```

---

#### Comprehension Questions - Exercise 1
1. **Question 1.1:** Why does referencing an image by a mutable tag (e.g., `image:v1.2.0`) introduce a critical supply chain risk compared to immutable digest referencing (`image@sha256:...`), even if `imagePullPolicy` is set to `Always`?
2. **Question 1.2:** If a developer submits a Pod manifest without specifying `imagePullSecrets`, but the Pod specifies `serviceAccountName: secure-app-sa`, how does the Kubelet evaluate authentication credentials against the container registry?

---

### Exercise 2: Static Vulnerability Scanning & Gatekeeper Policy Generation using Trivy

#### Context & Objectives
You are auditing an OCI container image (`nginx:1.21.6`) before allowing it into production. You will execute a vulnerability scan using `trivy`, filter for `CRITICAL` CVEs, generate a vulnerability report, and create an OPA Gatekeeper constraint to block vulnerable images at admission.

#### Step 1: Execute Container Image Scanning via Trivy CLI
Run `trivy` to perform a static layer vulnerability analysis, parsing OS packages and application dependencies:

```bash
trivy image --severity CRITICAL,HIGH \
  --format table \
  --ignore-unfixed \
  nginx:1.21.6
```

**Expected Output:**
```
nginx:1.21.6 (debian 11.3)

Total: 28 (HIGH: 22, CRITICAL: 6)

+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
| LIBRARY          | VULNERABILITY ID | SEVERITY | INSTALLED VERSION | FIXED VERSION | TITLE                                 |
+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
| zlib1g           | CVE-2022-37434   | CRITICAL | 1.2.11.dfsg-2+deb11u1 | 1.2.11.dfsg-2+deb11u2 | zlib: heap-based buffer overflow in   |
|                  |                  |          |                   |               | inflate() via large gzip header extra |
| libssl1.1        | CVE-2023-0286    | CRITICAL | 1.1.1n-0+deb11u1  | 1.1.1t-0+deb11u1 | openssl: BN_mod_exp overrun in        |
|                  |                  |          |                   |               | X509 verification                     |
| dpkg             | CVE-2022-36227   | HIGH     | 1.20.9            | 1.20.12       | libarchive: Buffer overflow           |
+------------------+------------------+----------+-------------------+---------------+---------------------------------------+
```

#### Step 2: Formulate OPA Gatekeeper ConstraintTemplate to Block Mutable Tags
Create an OPA Gatekeeper ConstraintTemplate (`ct-disallow-tags.yaml`) that rejects any Pod whose image string does not contain an explicit `@sha256:` digest string:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: kcsadisallowtags
spec:
  crd:
    spec:
      names:
        kind: KCSADisallowTags
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package kcsadisallowtags

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not contains(container.image, "@sha256:")
          msg := sprintf("Container image '%v' in pod '%v' must specify an immutable digest (@sha256:). Mutable tags are forbidden.", [container.image, input.review.object.metadata.name])
        }
```

Apply the ConstraintTemplate:

```bash
kubectl apply -f ct-disallow-tags.yaml
```

**Expected Output:**
```
constrainttemplate.templates.gatekeeper.sh/kcsadisallowtags created
```

#### Step 3: Instantiate Gatekeeper Enforcement Constraint
Create the constraint resource (`constraint-enforce-digests.yaml`) targeting all Pod creation requests in production namespaces:

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: KCSADisallowTags
metadata:
  name: enforce-image-digests
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "prod-secure"
```

Apply the Constraint:

```bash
kubectl apply -f constraint-enforce-digests.yaml
```

**Expected Output:**
```
kcsadisallowtags.constraints.gatekeeper.sh/enforce-image-digests created
```

#### Step 4: Validate Admission Policy Rejection
Attempt to deploy an insecure workload using a mutable tag (`pod-violating.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: rogue-workload
  namespace: prod-secure
spec:
  containers:
  - name: web
    image: nginx:1.21.6
```

Apply the violating Pod manifest:

```bash
kubectl apply -f pod-violating.yaml
```

**Expected Output (Rejection trace):**
```
Error from server (Forbidden): error when creating "pod-violating.yaml": admission webhook "validation.gatekeeper.sh" denied the request: [enforce-image-digests] Container image 'nginx:1.21.6' in pod 'rogue-workload' must specify an immutable digest (@sha256:). Mutable tags are forbidden.
```

---

#### Comprehension Questions - Exercise 2
1. **Question 2.1:** What is the technical difference between `--ignore-unfixed` in a Trivy scan vs. running a scan without this flag, and how does this impact SRE decision-making during production deployment gates?
2. **Question 2.2:** In the OPA Gatekeeper Rego policy provided, how does evaluating `input.review.object.spec.containers[_]` handle Pods containing init containers or ephemeral containers?

---

### Exercise 3: Supply Chain Cryptographic Verification using Cosign and Kyverno

#### Context & Objectives
You will generate an asymmetric key pair using Sigstore's `cosign`, sign an OCI container image in a local registry, and deploy a Kyverno `ClusterPolicy` that cryptographically validates signatures prior to Pod admission.

#### Step 1: Generate Cryptographic Keypair via Cosign CLI
Execute `cosign` to create a public/private keypair for artifact signing:

```bash
export COSIGN_PASSWORD="ProductionSecurityPassphrase123!"
cosign generate-key-pair
```

**Expected Output:**
```
Private key written to cosign.key
Public key written to cosign.pub
```

#### Step 2: Sign the Container Image Digest
Sign an image artifact published to a target registry (`myregistry.internal.enterprise.io/apps/auth-service@sha256:7f83b1657ff1fc53b92cb1...`):

```bash
cosign sign --key cosign.key \
  myregistry.internal.enterprise.io/apps/auth-service@sha256:7f83b1657ff1fc53b92cb1015b6d51a66c8b9134015ef05d76201a4e1d6e3f22
```

**Expected Output:**
```
Enter password for private key: 
Pushing signature to: myregistry.internal.enterprise.io/apps/auth-service:sha256-7f83b1657ff1fc53b92cb1015b6d51a66c8b9134015ef05d76201a4e1d6e3f22.sig
```

#### Step 3: Extract Public Key Content for Policy Inclusion
View the exported public key:

```bash
cat cosign.pub
```

**Expected Output:**
```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p3V+p23Hk6kXw+Fv98L8mO8sY8N
W+4m1h3901nK1qW4LgS8K8z+y1Hw8m8z43s1n2m9k0L1==
-----END PUBLIC KEY-----
```

#### Step 4: Create a Kyverno Image Verification Policy
Write a declarative Kyverno `ClusterPolicy` (`kyverno-verify-signature.yaml`) that enforces signature checks against `cosign.pub`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-cosign-signature
      match:
        any:
        - resources:
            kinds:
              - Pod
            namespaces:
              - prod-secure
      verifyImages:
      - imageReferences:
        - "myregistry.internal.enterprise.io/apps/*"
        key: |
          -----BEGIN PUBLIC KEY-----
          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7p3V+p23Hk6kXw+Fv98L8mO8sY8N
          W+4m1h3901nK1qW4LgS8K8z+y1Hw8m8z43s1n2m9k0L1==
          -----END PUBLIC KEY-----
```

Apply the Kyverno ClusterPolicy:

```bash
kubectl apply -f kyverno-verify-signature.yaml
```

**Expected Output:**
```
clusterpolicy.kyverno.io/verify-image-signature created
```

---

#### Comprehension Questions - Exercise 3
1. **Question 3.1:** Where does Cosign store the cryptographic signature when signing an OCI image by default, and how does this impact registry permission management?
2. **Question 3.2:** What is the fundamental difference between **Key-Based** Cosign signing (as used above) and **Keyless** signing using Sigstore's Fulcio and Rekor architecture?

---

### Exercise 4: Advanced Diagnostics & Kubelet Image Security Troubleshooting

#### Context & Objectives
A critical microservice is stuck in `ImagePullBackOff`. You must perform low-level diagnostic analysis using `kubectl`, `crictl`, and node-level system logs to isolate whether the failure is caused by authentication failure, TLS handshake misconfiguration, or image digest mismatch.

#### Step 1: Inspect Pod Status and Event Stream
Query the failing Pod status in the cluster:

```bash
kubectl get pod payment-processor -n prod-secure -o wide
```

**Expected Output:**
```
NAME                READY   STATUS             RESTARTS   AGE   IP           NODE          NOMINATED NODE   READINESS GATES
payment-processor   0/1     ImagePullBackOff   0          4m    10.244.1.15   worker-node-2 <none>           <none>
```

Execute `kubectl describe` to extract the detailed Kubernetes Event Log:

```bash
kubectl describe pod payment-processor -n prod-secure
```

**Expected Output (Snippet):**
```
Events:
  Type     Reason     Age                  From               Message
  ----     ------     ----                 ----               -------
  Normal   Scheduled  4m12s                default-scheduler  Successfully assigned prod-secure/payment-processor to worker-node-2
  Normal   Pulling    2m40s (x3 over 4m)   kubelet            Pulling image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442..."
  Warning  Failed     2m38s (x3 over 4m)   kubelet            Failed to pull image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442...": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: pull access denied, repository does not exist or may require login: authorization failed
  Warning  Failed     2m38s (x3 over 4m)   kubelet            Error: ErrImagePull
  Normal   BackOff    1m15s (x6 over 3m)   kubelet            Back-off pulling image "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442..."
```

#### Step 2: Low-Level Node Diagnostics using `crictl` and `journalctl`
Log in to `worker-node-2` and use `crictl` to query the Container Runtime Interface (CRI) layer directly:

```bash
# SSH into worker-node-2
crictl pull --creds "svc-image-puller:wrong-password" \
  registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

**Expected Output:**
```
FATAL[0001] pulling image failed: rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference "registry.internal.enterprise.io/finance/payment-app@sha256:e3b0c442...": pull access denied, repository does not exist or may require login: server message: insufficient_scope: authorization failed
```

Extract the `containment`/`kubelet` journal log to verify credential provider execution errors:

```bash
journalctl -u kubelet --since "10 minutes ago" | grep -E "credentialprovider|imagePull"
```

**Expected Output:**
```
Aug 07 20:15:10 worker-node-2 kubelet[1245]: E0807 20:15:10.112443    1245 provider.go:142] "Credential provider plugin returned error" plugin="aws-ecr-credential-provider" err="exit status 1"
Aug 07 20:15:10 worker-node-2 kubelet[1245]: E0807 20:15:10.112510    1245 kuberuntime_image.go:154] "PullImage from image service failed" err="rpc error: code = Unknown desc = failed to pull and unpack image..."
```

---

#### Comprehension Questions - Exercise 4
1. **Question 4.1:** What is the technical difference between the `ErrImagePull` error state and the `ImagePullBackOff` state in Kubernetes?
2. **Question 4.2:** If `kubectl describe pod` reveals `x509: certificate signed by unknown authority` during image pull, what specific node-level configuration must be adjusted in `containerd` or `CRI-O` without disabling TLS verification?

---

<details>
<summary>Answers & Explanations</summary>

### Exercise 1 Solutions

* **Answer 1.1:**  
  Referencing an image by a tag like `v1.2.0` relies on a mutable pointer in the registry. If an attacker gains write access to the repository, they can overwrite `v1.2.0` with a malicious layer payload without changing the tag name. Even with `imagePullPolicy: Always`, the Kubelet pulls the updated tag, leading to arbitrary remote code execution (RCE). Conversely, an immutable SHA256 digest (`@sha256:...`) is a cryptographic hash of the image manifest. If the image layers are tampered with, the resulting hash changes, causing the pull operation to fail cryptographic integrity verification.

* **Answer 1.2:**  
  When a Pod omits `imagePullSecrets`, the Kubelet inspects the `ServiceAccount` specified in `spec.serviceAccountName` (or `default` if unspecified). It reads the `imagePullSecrets` array defined on that `ServiceAccount` object, retrieves the associated `Secret` data containing `.dockerconfigjson`, decodes the Base64 credentials, and uses them to authenticate against the target OCI registry. If node-level credential providers are enabled, the Kubelet falls back to calling the credential provider plugin executable if the ServiceAccount lacks relevant credentials.

---

### Exercise 2 Solutions

* **Answer 2.1:**  
  The `--ignore-unfixed` flag instructs Trivy to exclude CVEs for which the upstream distribution/maintainer has **not** released a security patch (`FIXED VERSION` is empty). 
  * **SRE Trade-off:** Using `--ignore-unfixed` reduces alert fatigue by hiding unactionable vulnerabilities, allowing automated build pipelines to focus only on actionable fixes. However, from a zero-trust posture, unpatched `CRITICAL` vulnerabilities remain present in the running container and require compensating controls (e.g., AppArmor, Seccomp, NetworkPolicies).

* **Answer 2.2:**  
  The Rego line `container := input.review.object.spec.containers[_]` evaluates **only** standard application containers. It does **not** evaluate `initContainers` or `ephemeralContainers` because in the Kubernetes PodSpec schema, those reside under separate arrays (`spec.initContainers` and `spec.ephemeralContainers`). To cover all container types, the Rego policy must iterate over a combined array:
  ```rego
  all_containers := array.concat(
    object.get(input.review.object.spec, "containers", []),
    object.get(input.review.object.spec, "initContainers", [])
  )
  container := all_containers[_]
  ```

---

### Exercise 3 Solutions

* **Answer 3.1:**  
  By default, Cosign writes signatures directly to the target OCI container registry as a separate OCI artifact. The signature tag is deterministically named using the image digest prefix: `sha256-<digest>.sig`.  
  * **Permission Impact:** The CI/CD service account or human identity executing `cosign sign` must possess **write/push permissions** to the image repository location, as it uploads a distinct manifest layer containing the signature payload.

* **Answer 3.2:**  
  * **Key-Based Signing:** Uses a static private key (e.g., `cosign.key`) protected by a passphrase. The public key must be manually distributed to consumers (or embedded in admission controllers like Kyverno). Key rotation and revocation require manual policy updates across all clusters.
  * **Keyless Signing (Fulcio + Rekor):** Uses short-lived X.509 certificates issued by Fulcio based on OIDC identity tokens (e.g., GitHub Actions, Google IAM). The signature event is logged to Rekor, a tamper-evident public transparency log. Verification relies on trusting the Fulcio Root CA and inspecting the Rekor log entry, eliminating the need to store and rotate static long-lived private keys.

---

### Exercise 4 Solutions

* **Answer 4.1:**  
  * `ErrImagePull`: Represents an immediate failure of a single image pull attempt (e.g., network timeout, 404 Not Found, 401 Unauthorized, or invalid manifest).
  * `ImagePullBackOff`: Represents the Kubernetes Kubelet state machine status when an image pull repeatedly fails. The Kubelet enters an exponential back-off loop (waiting 10s, 20s, 40s, up to 5 minutes) before retrying the pull operation to prevent hammering the container registry or exhausting node CPU/network resources.

* **Answer 4.2:**  
  The error indicates that the CRI container runtime (`containerd` or `CRI-O`) does not trust the Custom Root CA certificate of the internal container registry. To resolve this without disabling TLS (`insecure_skip_verify` anti-pattern):
  1. Copy the internal Enterprise CA Certificate (`ca.crt`) to the node's system trust store (e.g., `/usr/local/share/ca-certificates/` on Debian/Ubuntu or `/etc/pki/ca-trust/source/anchors/` on RHEL) and execute `update-ca-certificates`.
  2. Configure `containerd` host settings in `/etc/containerd/certs.d/registry.internal.enterprise.io/hosts.toml`:
     ```toml
     server = "https://registry.internal.enterprise.io"

     [host."https://registry.internal.enterprise.io"]
       ca = "/etc/containerd/certs.d/registry.internal.enterprise.io/ca.crt"
     ```
  3. Restart the `containerd` service: `systemctl restart containerd`.

</details>