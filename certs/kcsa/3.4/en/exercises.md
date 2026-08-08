# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
## Domain 3.4: Secrets Management & Protection
**Exam Weight**: ~3.14% | **Target Level**: Advanced / Production SRE & Platform Security Architect

---

## 1. Architectural Deep Dive & Internal Mechanics

### 1.1 Kubernetes Secret Storage Mechanics and Default Vulnerabilities
By default, Kubernetes `Secret` objects stored in `etcd` are **base64-encoded**, not encrypted. Base64 is an encoding scheme, not encryption; anyone with read access to `etcd` or RBAC permissions to `get` or `list` secrets can decode the plaintext payload instantaneously.

```
+------------------+         +---------------------+         +----------------------+
|  kubectl create  |         |  kube-apiserver     |         |  etcd Storage        |
|  secret generic  | ------> |  (Validates RBAC &  | ------> |  /registry/secrets/  |
|  --from-literal  |         |   schema structure) |         |  [BASE64 PLAINTEXT]  |
+------------------+         +---------------------+         +----------------------+
```

#### Memory & Process Leakage: Volume Mounts vs. Environment Variables
Secrets can be exposed to containers in two primary ways:

1. **Environment Variables (`env` / `envFrom`)**:
   - **Mechanism**: The `kubelet` injects the secret value directly into the container process's environment table at startup.
   - **Vulnerabilities**: 
     - Process environment variables are readable by any process running under the same UID or with `ptrace` capabilities via `/proc/[pid]/environ`.
     - Application crash dumps, diagnostic logs, monitoring APMs, and subprocess children inherit environment tables, frequently resulting in unintended credential leakage to log aggregators (e.g., Datadog, Elasticsearch).
     - Environment variables cannot be dynamically updated without restarting the container process.

2. **Volume Mounts (`spec.volumes[].secret`)**:
   - **Mechanism**: The `kubelet` writes the secret payload to a local, memory-backed file system (`tmpfs`) at `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~secret/<volume-name>`.
   - **Vulnerabilities**:
     - Leaves filesystem footprints inside the container namespace.
     - However, `tmpfs` prevents secret writes to physical disk media. `kubelet` also automatically updates secret files when the underlying `Secret` object changes (unless marked `immutable: true`).

---

### 1.2 Static Encryption at Rest Mechanics
To protect `etcd` against storage device compromise or unauthorized raw key-value access, Kubernetes provides the `EncryptionConfiguration` API. When configured, `kube-apiserver` intercepts Secret read/write operations and processes data through configured providers before writing to `etcd`.

```
[ Unencrypted Data ] ---> [ kube-apiserver ] ---> [ EncryptionProvider (AES-GCM/KMS) ] ---> [ Encrypted Ciphertext ] ---> [ etcd ]
```

#### Provider Hierarchy & Security Trade-offs

| Provider | Mechanism | Performance | Key Management Security | Production Suitability |
| :--- | :--- | :--- | :--- | :--- |
| `identity` | Plaintext (No encryption) | Native speed | None | **Unsafe** for production. |
| `aescbc` | AES-CBC mode with PKCS#7 padding | Fast | Static key stored in `EncryptionConfiguration` on control plane disk | Vulnerable to padding oracle attacks if IVs collide. |
| `aesgcm` | AES-GCM mode with random 12-byte IV | High throughput | Static key stored in `EncryptionConfiguration` on control plane disk | **Recommended static provider** (authenticated encryption preventing tampering). |
| `secretbox` | XSalsa20 and Poly1305 | Fast | Static key stored on disk | Cryptographically strong alternative to AES. |
| `kms` (v2) | Envelope Encryption via external KMS (HashiCorp Vault, AWS KMS, GCP KMS) | Network hop on DEK generation / Local DEK caching | Master Key (KEK) stays inside HSM/KMS; Data Encryption Key (DEK) encrypted at rest | **Gold standard for Enterprise Production**. |

---

### 1.3 External Secret Management & CSI Architecture
In zero-trust enterprise environments, Kubernetes `Secret` objects are entirely decoupled from version control and GitOps workflows using two primary patterns:

1. **Secrets Store CSI Driver (Pull/Mount Model)**:
   - Mounts external secrets (Vault, AWS Secrets Manager, Azure Key Vault) directly into Pod `tmpfs` volumes via gRPC IPC plugins without writing intermediate Kubernetes `Secret` objects to `etcd` (unless optional secret synchronization is enabled).

2. **External Secrets Operator (ESO - Sync Model)**:
   - Controller pattern that queries external secret APIs via Custom Resources (`SecretStore` / `ExternalSecret`) and reconciles them into native Kubernetes `Secret` resources in `etcd`.

---

## 2. Official References & Standards
- [Kubernetes Documentation: Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes Documentation: Secrets Management Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/)
- [CNCF KCSA Curriculum (v1.0)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [NIST SP 800-57: Recommendation for Key Management](https://csrc.nist.gov/publications/detail/sp/800-57-part-1/rev-5/final)

---

## 3. Production Guided Exercises

### Exercise 1: Demonstrating Etcd Plaintext Vulnerability & API Base64 Extraction

#### Objective
Understand the underlying storage format of unencrypted Kubernetes secrets in `etcd` and verify how RBAC exposure leads to plaintext credential compromise.

#### Step 1: Create a Production-like Opaque Secret
Execute the following command to create a namespace and a secret containing sensitive database credentials:

```bash
kubectl create namespace sec-lab
kubectl create secret generic db-credentials \
  --namespace=sec-lab \
  --from-literal=username='postgres_admin' \
  --from-literal=password='p@ssw0rd1234!Secure'
```

##### Expected Output
```text
namespace/sec-lab created
secret/db-credentials created
```

#### Step 2: Retrieve and Decode Secret via Kubernetes API
Query the secret via `kubectl` and decode the base64 payload to demonstrate how base64 encoding offers zero cryptographic protection:

```bash
kubectl get secret db-credentials --namespace=sec-lab -o jsonpath='{.data.password}' | base64 --decode; echo
```

##### Expected Output
```text
p@ssw0rd1234!Secure
```

#### Step 3: Direct Etcd Inspection (Simulating Storage Medium Access)
Using `etcdctl` on a control-plane node (or inside an etcd pod), inspect the raw key-value entry stored under `/registry/secrets/sec-lab/db-credentials`:

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/sec-lab/db-credentials
```

##### Expected Output
```text
/registry/secrets/sec-lab/db-credentials
k8s

v1Secret
db-credentialssec-lab"*$5103a890-50d4-4cf1-a477-897c5ad9116e2
usernamepostgres_adminpasswordp@ssw0rd1234!Secure...
```
*(Notice the unencrypted plaintext strings `postgres_admin` and `p@ssw0rd1234!Secure` inside the raw binary storage layout).*

---

#### Verification Questions - Exercise 1

1. **Question 1.1**: Why does base64 encoding fail to satisfy compliance frameworks (e.g., PCI-DSS, SOC2, ISO 27001) for secret storage, and what Kubernetes cluster component must be configured to achieve compliance?
2. **Question 1.2**: If an attacker gains `get` and `list` permissions on `secrets` via RBAC in a namespace, what security boundary has failed, and how can administrators mitigate this without revoking namespace access?

---

### Exercise 2: Implementing API Server Static Encryption at Rest (AES-GCM)

#### Objective
Formulate a production-grade `EncryptionConfiguration` file, configure `kube-apiserver` to use `aesgcm` as the primary provider, and re-encrypt pre-existing unencrypted secrets in `etcd`.

#### Step 1: Generate a Cryptographically Secure 32-Byte Key
Generate a 256-bit (32-byte) key formatted as base64:

```bash
head -c 32 /dev/urandom | base64
```

##### Expected Output (Example output, yours will vary)
```text
K3v9jQ2mX8ZpL5rT1vN4wY7uI0oP9sA2dB4fG6hJ8kL=
```

#### Step 2: Create the EncryptionConfiguration Manifest
Create `/etc/kubernetes/enc/encryption-config.yaml` on all control plane nodes with the following complete, syntactically valid manifest:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aesgcm:
          keys:
            - name: key1
              secret: "K3v9jQ2mX8ZpL5rT1vN4wY7uI0oP9sA2dB4fG6hJ8kL="
      - identity: {}
```

> [!IMPORTANT]
> The `providers` list order defines write priority. The first provider listed is used to **encrypt** new writes. All listed providers are tried in sequential order to **decrypt** existing data. `identity: {}` must remain at the end during initial migration to allow reading existing unencrypted secrets.

#### Step 3: Update Kube-APIServer Configuration
Modify `/etc/kubernetes/manifests/kube-apiserver.yaml` to mount the configuration file and pass the `--encryption-provider-config` flag:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    # ... other flags
    volumeMounts:
    - mountPath: /etc/kubernetes/enc
      name: enc-config
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
    name: enc-config
```

Verify `kube-apiserver` successfully restarts:

```bash
crictl ps --name kube-apiserver
```

#### Step 4: Create a New Secret and Verify Encryption in Etcd
Create a new secret after enabling encryption:

```bash
kubectl create secret generic enc-secret \
  --namespace=sec-lab \
  --from-literal=api-key='PROD_SECURE_TOKEN_9988'
```

Query `etcd` directly for `enc-secret`:

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/sec-lab/enc-secret
```

##### Expected Output
```text
/registry/secrets/sec-lab/enc-secret
k8s:enc:aesgcm:v1:key1:%`V... [Binary Ciphertext Output - No Plaintext Visible]
```

#### Step 5: Re-encrypt Pre-Existing Secrets
The old secret `db-credentials` remains unencrypted in `etcd` because encryption occurs on **write**. Re-encrypt all existing secrets across all namespaces:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

##### Expected Output
```text
secret/db-credentials replaced
secret/sh.helm.release.v1... replaced
```

---

#### Verification Questions - Exercise 2

1. **Question 2.1**: What happens if an administrator removes `- identity: {}` from the `providers` list BEFORE running `kubectl replace` on pre-existing secrets created prior to enabling encryption?
2. **Question 2.2**: During key rotation, what is the exact required order of keys under the `aesgcm` provider in `EncryptionConfiguration` to safely re-encrypt data with `key2` while retaining the capability to read data encrypted with `key1`?

---

### Exercise 3: Secure In-Pod Secret Consumption & Immutability Enforcement

#### Objective
Deploy a workload demonstrating secure memory-backed `tmpfs` volume mounts vs. unsafe environment variable consumption, inspect memory/process footprints, and enforce secret immutability.

#### Step 1: Deploy Workload Manifest
Apply the following manifest containing an immutable Secret and a Pod demonstrating both secret projection methods:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-sec-config
  namespace: sec-lab
type: Opaque
immutable: true
data:
  # base64 encoded "db-pass-2026-prod"
  DB_PASSWORD: ZGItcGFzcy0yMDI2LXByb2Q=
  # base64 encoded "tls-cert-data-stream"
  TLS_CERT: dGxzLWNlcnQtZGF0YS1zdHJlYW0=
---
apiVersion: v1
kind: Pod
metadata:
  name: sec-consumer-pod
  namespace: sec-lab
spec:
  containers:
  - name: app-container
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    env:
    - name: INSECURE_DB_PASS
      valueFrom:
        secretKeyRef:
          name: app-sec-config
          key: DB_PASSWORD
    volumeMounts:
    - name: secure-secret-vol
      mountPath: "/etc/secrets"
      readOnly: true
  volumes:
  - name: secure-secret-vol
    secret:
      secretName: app-sec-config
      defaultMode: 0400
```

```bash
kubectl apply -f pod-secret-demo.yaml
```

##### Expected Output
```text
secret/app-sec-config created
pod/sec-consumer-pod created
```

#### Step 2: Inspect Insecure Environment Variable Exposure
Exec into the container process environment table via `/proc/1/environ` to observe secret leakage:

```bash
kubectl exec -n sec-lab sec-consumer-pod -- strings /proc/1/environ | grep INSECURE_DB_PASS
```

##### Expected Output
```text
INSECURE_DB_PASS=db-pass-2026-prod
```

#### Step 3: Inspect Secure Volume Mount & File Permissions
Verify that volume-mounted secrets are placed on a `tmpfs` (RAM-backed filesystem) with non-permissive file permissions (`0400` - read-only by owner):

```bash
kubectl exec -n sec-lab sec-consumer-pod -- ls -la /etc/secrets
```

##### Expected Output
```text
drwxrwxrwt    2 root     root            80 Aug  7 19:50 .
drwxr-xr-x    1 root     root            18 Aug  7 19:50 ..
lrwxrwxrwx    1 root     root            15 Aug  7 19:50 DB_PASSWORD -> ..data/DB_PASSWORD
lrwxrwxrwx    1 root     root            15 Aug  7 19:50 TLS_CERT -> ..data/TLS_CERT
```

Verify permissions on the target data file:

```bash
kubectl exec -n sec-lab sec-consumer-pod -- ls -l /etc/secrets/DB_PASSWORD
```

##### Expected Output
```text
-r--------    1 root     root            16 Aug  7 19:50 /etc/secrets/DB_PASSWORD
```

#### Step 4: Validate Immutability Enforcement
Attempt to update the secret object payload in API Server:

```bash
kubectl patch secret app-sec-config -n sec-lab -p '{"data":{"DB_PASSWORD":"TmV3UGFzc3dvcmQxMjM="}}'
```

##### Expected Output
```text
Error from server (Forbidden): secrets "app-sec-config" is invalid: : Field is immutable
```

---

#### Verification Questions - Exercise 3

1. **Question 3.1**: What significant performance benefit does setting `immutable: true` on Secrets provide to large-scale Kubernetes clusters (e.g., 5,000 nodes)?
2. **Question 3.2**: If a secret mounted as a volume file is updated in the API server (and is not immutable), how does `kubelet` update the file inside the container namespace, and why does this fail if the volume is mounted using `subPath`?

---

### Exercise 4: External Secrets Operator (ESO) Architecture & Mechanics

#### Objective
Understand the manifest structure and reconciliation loop of the External Secrets Operator pattern, bridging enterprise secret stores (e.g., HashiCorp Vault) into Kubernetes namespaces securely.

#### Step 1: Analyze Architecture & CRD Declarations
Examine the following production manifest defining a `ClusterSecretStore` connection to HashiCorp Vault and an `ExternalSecret` synchronization object:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.internal.domain:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "k8s-sec-lab-role"
          secretRef:
            name: eso-vault-sa-token
            namespace: external-secrets
            key: token
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials-eso
  namespace: sec-lab
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: synced-db-secret
    creationPolicy: Owner
    template:
      type: Opaque
      engineVersion: v2
      data:
        DB_USER: "{{ .vault_username }}"
        DB_PASS: "{{ .vault_password }}"
  data:
    - secretKey: vault_username
      remoteRef:
        key: production/db
        property: username
    - secretKey: vault_password
      remoteRef:
        key: production/db
        property: password
```

---

#### Verification Questions - Exercise 4

1. **Question 4.1**: In the External Secrets Operator architecture, what security vulnerability is introduced if `creationPolicy: Owner` is modified to `creationPolicy: Orphan` when an `ExternalSecret` resource is deleted?
2. **Question 4.2**: Contrast Secrets Store CSI Driver vs. External Secrets Operator regarding `etcd` persistence, pod startup latency, and offline availability.

---

<details>
<summary><b>Solutions & Detailed Technical Explanations</b></summary>

### Exercise 1 Solutions

- **Answer 1.1**: Base64 is a reversible, 1-to-1 encoding standard (RFC 4648) designed for data transmission over text-based protocols, offering zero confidentiality or entropy. Anyone reading `etcd` raw storage (e.g., via backups, unencrypted disk snapshots, or `etcdctl`) retrieves plaintext secrets. To satisfy regulatory frameworks, Kubernetes must be configured with an `EncryptionConfiguration` using authenticated encryption (such as `aesgcm` or a `kms` v2 provider), combined with etcd disk encryption and strict TLS transport layer security.
- **Answer 1.2**: The RBAC authorization boundary failed due to over-privileged RBAC roles granting `secrets` verb access (`get`, `list`, `watch`). To mitigate this without revoking namespace access entirely, administrators should:
  1. Restrict RBAC bindings using granular roles that omit `secrets` verbs.
  2. Implement fine-grained admission policies (ValidatingAdmissionPolicies or OPA/Gatekeeper) to deny secret fetching.
  3. Use external secret stores (such as Secrets Store CSI Driver) where pods consume secrets via mounted volumes without granting the user or ServiceAccount any RBAC read permissions to native Kubernetes `Secret` objects.

---

### Exercise 2 Solutions

- **Answer 2.1**: If `- identity: {}` is removed **before** existing secrets are re-encrypted via `kubectl replace`, the `kube-apiserver` will fail to decrypt existing unencrypted secrets when requested by workloads or administrators. The API server iterates through the listed providers sequentially; if no provider matches the storage format (unencrypted plaintext requires `identity`), `kube-apiserver` throws a decryption error (`error decoding key...`).
- **Answer 2.2**: To rotate keys safely:
  1. Add `key2` at the **top** of the `aesgcm` key list so all new writes use `key2`.
  2. Keep `key1` immediately below `key2` so pre-existing data encrypted with `key1` can still be decrypted.
  3. Run `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` to re-encrypt all stored data using `key2`.
  4. Once re-encryption is verified, remove `key1` from the configuration file.

```yaml
providers:
  - aesgcm:
      keys:
        - name: key2  # Primary (Write/Encrypt)
          secret: "Base64StringForNewKey2..."
        - name: key1  # Secondary (Decrypt existing)
          secret: "Base64StringForOldKey1..."
```

---

### Exercise 3 Solutions

- **Answer 3.1**: In large clusters, `kubelet` establishes long-lived `watch` connections to `kube-apiserver` for every Secret mounted in pods. When secrets are updated, the API server broadcasts watch events to all subscribed nodes, causing high CPU and memory pressure on `kube-apiserver` and `etcd`. Setting `immutable: true` instructs `kubelet` to stop watching the Secret object for updates, dramatically reducing API server memory allocation, network overhead, and CPU load.
- **Answer 3.2**: For standard volume mounts, `kubelet` periodically re-reads the updated Secret payload from the API server and performs an atomic directory update on the `tmpfs` volume using symlink rotation (`..data_tmp` -> `..data`). However, if a secret is mounted using `subPath` (e.g., mounting a single file inside an existing folder), the container receives a direct bind-mount of the specific file node at pod startup. Bind-mounted single files bypass symlink updates and **never receive automated live updates** when the underlying Secret changes.

---

### Exercise 4 Solutions

- **Answer 4.1**: Setting `creationPolicy: Orphan` causes the generated Kubernetes `Secret` in `etcd` to remain intact even if the parent `ExternalSecret` custom resource is deleted. This results in stale, unmanaged secret artifacts lingering in `etcd` without reconciliation lifecycle control or automated clean-up, creating potential security drift and compliance violations.
- **Answer 4.2**: 

| Architecture Metric | Secrets Store CSI Driver | External Secrets Operator (ESO) |
| :--- | :--- | :--- |
| **`etcd` Persistence** | **None** (by default). Mounted directly to pod `tmpfs`. (Optional secret creation available). | **Persisted in `etcd`** as native Kubernetes `Secret` objects. |
| **Pod Startup Latency** | **Higher**. Pod startup blocks until gRPC call to external Vault/KMS completes during volume mount phase. | **Zero added pod latency**. Secret already exists in `etcd` prior to pod creation. |
| **Offline/Store Outage Resiliency** | **Vulnerable**. If Vault/KMS is down during pod creation/reschedule, new pods fail to start. | **Resilient**. Pods continue to read existing `etcd` secrets even if external Vault goes offline. |

</details>