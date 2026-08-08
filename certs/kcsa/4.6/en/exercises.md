# KCSA Study Guide: Topic 4.6 – Access to Sensitive Data

**Exam:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain 4:** Application Security  
**Subtopic 4.6:** Access to Sensitive Data  
**Domain Weight:** 2.29%  
**Author:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Architectural Blueprint & Deep Technical Mechanics

### 1.1 The Attack Surface of Sensitive Data in Kubernetes
In cloud-native architectures, "sensitive data" encompasses database credentials, TLS private keys, API tokens, encryption keys, and third-party SaaS tokens. Accessing and managing sensitive data introduces multiple attack vectors across the Kubernetes stack:

```
                      +-------------------------------------------------+
                      |            API Server Security Boundary         |
                      +-------------------------------------------------+
                                       |                |
                    RBAC / Audit       |                | Storage Layer
                    Inspection         v                v
            +-----------------------+     +-------------------------------+
            |  Secret Enumeration   |     |  etcd Storage (Unencrypted)   |
            |  & RBAC Misconfig     |     |  Base64 != Encryption         |
            +-----------------------+     +-------------------------------+
                       |                                |
                       v                                v
            +-----------------------+     +-------------------------------+
            | Compromised Service   |     | Physical / Snapshot Theft     |
            | Account / API Token   |     | of etcd Datastore             |
            +-----------------------+     +-------------------------------+
                       |
                       +--------------------------------+
                       |                                |
  Pod Execution        v                                v
  Memory & Env  +-----------------------+     +-------------------------------+
                | Env Var Leakage via   |     | Memory Dumping / Proc FS      |
                | /proc/$PID/environ    |     | Unencrypted Disk Swapping     |
                +-----------------------+     +-------------------------------+
```

### 1.2 Defense-in-Depth Spectrum for Kubernetes Secrets

1. **Storage Layer (At-Rest Encryption):**
   - **Default State:** Kubernetes Secrets are stored in `etcd` as Base64-encoded strings (`serializers/json`). Base64 is an encoding format, **not** encryption. Any entity with access to `etcd` backups or host memory can extract all cluster secrets.
   - **`EncryptionConfiguration`:** Configures the `kube-apiserver` to encrypt secret resources before writing them to `etcd`.
   - **KMS v2 Provider Architecture:** Uses Envelope Encryption. The `kube-apiserver` generates a local Data Encryption Key (DEK) to encrypt secrets, and delegates DEK encryption to an external Key Management Service (AWS KMS, GCP Cloud KMS, Azure Key Vault, HashiCorp Vault) via a Unix domain socket plugin. The Key Encryption Key (KEK) never leaves the HSM/KMS.

2. **Access Control Layer (RBAC & Audit Logging):**
   - Direct `get`, `list`, `watch` permissions on `secrets` resources must be severely restricted.
   - Indirect vectors must be locked down: `pods/exec`, `pods/ephemeralcontainers`, `pods/log`, and `serviceaccounts/token` creation.
   - Dedicated `AuditEvent` policy rules must log sensitive data access patterns without logging actual payload data.

3. **Runtime & Injection Layer:**
   - **Environment Variables vs. Volume Mounts:** Environment variables leak across child processes, system diagnostics (`/proc/$PID/environ`), container crashes/core dumps, and application log output. Volume-mounted secrets backed by `tmpfs` (`medium: Memory`) reside purely in volatile RAM and are isolated to the Pod file tree.
   - **Projected ServiceAccount Tokens (TokenRequest API):** Replaces static long-lived API tokens with short-lived, audience-bound JWTs signed by the `kube-apiserver` OIDC provider.
   - **External Secrets Operator (ESO):** Decouples secret storage from Kubernetes. Synchronizes sensitive keys from external vaults directly into `tmpfs`-backed Kubernetes secrets or dynamically injects them into running pods using Workload Identity Federation.

---

## 2. Official Reference Sources
- **CNCF KCSA Curriculum:** [KCSA Curriculum Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- **Kubernetes Documentation – Encrypting Confidential Data at Rest:** [https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- **Kubernetes Documentation – Using a KMS Provider for Data Encryption:** [https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- **Kubernetes Documentation – Service Account Token Projection:** [https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-projection](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-projection)
- **External Secrets Operator Documentation:** [https://external-secrets.io/latest/](https://external-secrets.io/latest/)

---

## 3. Hands-On Guided Lab Exercises

### Exercise 1: Auditing etcd Plaintext Exposure & Configuring `EncryptionConfiguration` (KMS / AES-CBC)

#### Objective
Demonstrate how Kubernetes stores secrets in `etcd` by default, configure an `EncryptionConfiguration` manifest on the API Server, verify write-side encryption, and perform zero-downtime secret re-encryption/migration.

#### Step 1.1: Create a target secret and inspect raw etcd storage
Execute the following commands to create a sensitive credential in the `production-sec` namespace and query `etcdctl` directly:

```bash
kubectl create namespace production-sec
kubectl create secret generic db-db-master-key \
  --from-literal=username='admin_db_user' \
  --from-literal=password='SuperSecretProductionP@ssw0rd2026!' \
  -n production-sec
```

Expected output:
```text
namespace/production-sec created
secret/db-db-master-key created
```

Query `etcd` directly (assuming access to master node or control plane host running etcd with client certs):

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/production-sec/db-db-master-key
```

Expected output:
```text
/registry/secrets/production-sec/db-db-master-key
k8s

v1Secret
...
db-db-master-keyproduction-sec"*
passwordSuperSecretProductionP@ssw0rd2026!
admin_db_user
```
*(Notice that the plaintext string `SuperSecretProductionP@ssw0rd2026!` is directly readable inside the etcd key payload).*

#### Step 1.2: Generate a 32-byte secret key and construct the `EncryptionConfiguration` manifest
Create a 32-byte base64 key using `head` and `openssl`:

```bash
BASE64_KEY=$(head -c 32 /dev/urandom | base64)
echo "Generated Key: ${BASE64_KEY}"
```

Expected output:
```text
Generated Key: c3VwZXJzZWNyZXRrZXlmb3Jrc2NhZXhhbXBsZTEyMzQ9
```

Create the configuration file at `/etc/kubernetes/enc/encryption-config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: c3VwZXJzZWNyZXRrZXlmb3Jrc2NhZXhhbXBsZTEyMzQ9
      - identity: {}
```

#### Step 1.3: Apply configuration to `kube-apiserver` and perform Secret Migration
Update the `kube-apiserver` pod manifest (`/etc/kubernetes/manifests/kube-apiserver.yaml`) to pass the `--encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml` flag and mount the directory volume into the apiserver container.

Once the `kube-apiserver` restarts, test newly written secret vs old secret:

```bash
kubectl create secret generic new-api-token \
  --from-literal=token='Bearer-9876543210-SecretToken' \
  -n production-sec

ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/production-sec/new-api-token
```

Expected output:
```text
/registry/secrets/production-sec/new-api-token
k8s:enc:aescbc:v1:key1:%`V+ :... [Binary Encrypted Payload]
```

Re-encrypt existing secrets created before encryption was enabled:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

Expected output:
```text
secret/db-db-master-key replaced
secret/new-api-token replaced
...
```

---

#### Verification Questions – Exercise 1
1. **Why is the `- identity: {}` provider included at the end of the `providers` list in `EncryptionConfiguration`?**
2. **What occurs during a key rotation scenario if a new key (`key2`) is added above `key1` in the `aescbc` provider block, and how is the migration of existing data triggered?**

---

### Exercise 2: Comparing Secret Consumption Mechanics (Env Vars vs RAM `tmpfs` Volume Mounts) & RBAC Containment

#### Objective
Build valid production Pod manifests demonstrating vulnerable environment variable injection vs secure `tmpfs` volume mounts, execute diagnostic process tree inspections to prove key exposure vectors, and enforce minimal RBAC scoping for secret reading.

#### Step 2.1: Deploy workloads consuming Secrets via Env Vars and Volume Mounts
Create a deployment file `secrets-workload-demo.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-db-credentials
  namespace: production-sec
type: Opaque
stringData:
  DB_USER: "pg_app_user"
  DB_PASS: "P@ssw0rd_Vault_Protected_99"
---
apiVersion: v1
kind: Pod
metadata:
  name: insecure-env-pod
  namespace: production-sec
spec:
  containers:
    - name: app-container
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      env:
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-db-credentials
              key: DB_PASS
---
apiVersion: v1
kind: Pod
metadata:
  name: secure-volume-pod
  namespace: production-sec
spec:
  containers:
    - name: app-container
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      volumeMounts:
        - name: secret-volume
          mountPath: "/var/run/secrets/app"
          readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: app-db-credentials
        defaultMode: 0400
```

Apply the manifest:

```bash
kubectl apply -f secrets-workload-demo.yaml
```

Expected output:
```text
secret/app-db-credentials created
pod/insecure-env-pod created
pod/secure-volume-pod created
```

#### Step 2.2: Perform Diagnostic Proof of Sensitive Data Leaks
Inspect process environment variables on `insecure-env-pod`:

```bash
kubectl exec -n production-sec insecure-env-pod -- cat /proc/1/environ | tr '\0' '\n' | grep DATABASE_PASSWORD
```

Expected output:
```text
DATABASE_PASSWORD=P@ssw0rd_Vault_Protected_99
```

Now inspect the process environment and mounted storage on `secure-volume-pod`:

```bash
kubectl exec -n production-sec secure-volume-pod -- cat /proc/1/environ | tr '\0' '\n' | grep DATABASE_PASSWORD
```

Expected output:
```text
(empty output - variable does not exist in process environment)
```

Inspect mounted volume filesystem type and file permissions:

```bash
kubectl exec -n production-sec secure-volume-pod -- df -T /var/run/secrets/app
kubectl exec -n production-sec secure-volume-pod -- ls -la /var/run/secrets/app
```

Expected output:
```text
Filesystem     Type  1K-blocks  Used Available Use% Mounted on
tmpfs          tmpfs   16258412     4  16258408   1% /var/run/secrets/app

total 4
drwxrwxrwt 3 root root  100 Aug  7 20:15 .
drwxr-xr-x 3 root root   17 Aug  7 20:15 ..
drwxr-xr-x 2 root root   60 Aug  7 20:15 ..2026_08_07_20_15_00.12345
lrwxrwxrwx 1 root root   31 Aug  7 20:15 ..data -> ..2026_08_07_20_15_00.12345
lrwxrwxrwx 1 root root   14 Aug  7 20:15 DB_PASS -> ..data/DB_PASS
lrwxrwxrwx 1 root root   14 Aug  7 20:15 DB_USER -> ..data/DB_USER
```

#### Step 2.3: Enforce Strict RBAC Least Privilege for Secret Access
Define a Role that grants granular secret access restricted by resource name, preventing general enumeration (`list`/`watch` on all secrets):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restricted-secret-reader
  namespace: production-sec
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["app-db-credentials"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-restricted-secret-reader
  namespace: production-sec
subjects:
  - kind: ServiceAccount
    name: default
    namespace: production-sec
roleRef:
  kind: Role
  name: restricted-secret-reader
  apiGroup: rbac.authorization.k8s.io
```

Test access boundaries using `kubectl auth can-i`:

```bash
kubectl auth can-i get secret/app-db-credentials -n production-sec --as=system:serviceaccount:production-sec:default
kubectl auth can-i list secrets -n production-sec --as=system:serviceaccount:production-sec:default
kubectl auth can-i get secret/db-db-master-key -n production-sec --as=system:serviceaccount:production-sec:default
```

Expected output:
```text
yes
no
no
```

---

#### Verification Questions – Exercise 2
1. **Why do environment variables fail to update when a Secret updated in the API Server is edited, whereas volume-mounted secrets update automatically?**
2. **If an attacker acquires `pods/exec` permissions inside `secure-volume-pod`, can they still read the secret mounted at `/var/run/secrets/app/DB_PASS`? What secondary security control mitigates this vector?**

---

### Exercise 3: Modern Secretless Workload Identity via Token Projection & External Secrets Operator Architecture

#### Objective
Configure projected ServiceAccount tokens with bound custom audiences and short expiration times, and analyze the architecture of External Secrets Operator (ESO) integration with cloud key management systems.

#### Step 3.1: Deploy Pod with Projected ServiceAccount Token
Create `projected-token-pod.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth-sa
  namespace: production-sec
---
apiVersion: v1
kind: Pod
metadata:
  name: vault-client-pod
  namespace: production-sec
spec:
  serviceAccountName: vault-auth-sa
  containers:
    - name: vault-agent
      image: registry.k8s.io/e2e-test-images/agnhost:2.43
      command: ["sleep", "3600"]
      volumeMounts:
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: vault-token
      projected:
        sources:
          - serviceAccountToken:
              audience: "https://vault.internal.net"
              expirationSeconds: 1200
              path: vault-identity-token
```

Apply and verify token payload claims:

```bash
kubectl apply -f projected-token-pod.yaml
TOKEN_CONTENT=$(kubectl exec -n production-sec vault-client-pod -- cat /var/run/secrets/tokens/vault-identity-token)
echo $TOKEN_CONTENT | jq -R 'split(".") | .[1] | @base64d | fromjson'
```

Expected output:
```json
{
  "aud": [
    "https://vault.internal.net"
  ],
  "exp": 1754603700,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "kubernetes.io": {
    "namespace": "production-sec",
    "pod": {
      "name": "vault-client-pod",
      "uid": "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
    },
    "serviceaccount": {
      "name": "vault-auth-sa",
      "uid": "f1e2d3c4-b5a6-9788-7766-554433221100"
    }
  },
  "nbf": 1754602500,
  "sub": "system:serviceaccount:production-sec:vault-auth-sa"
}
```

#### Step 3.2: Analyze External Secrets Operator (ESO) CRDs Manifest
Deploying static secrets in GitOps repositories breaks zero-trust security. ESO syncs secrets dynamically from external secret providers using the projected token identity:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production-sec
spec:
  provider:
    vault:
      server: "https://vault.internal.net"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "production-sec-vault-role"
          serviceAccountRef:
            name: vault-auth-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: production-db-external-secret
  namespace: production-sec
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: synced-db-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      metadata:
        annotations:
          security.cluster.local/managed-by: "external-secrets-operator"
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: production/database
        property: password
```

---

#### Verification Questions – Exercise 3
1. **How does setting a custom `audience` field in a projected `serviceAccountToken` defend against token theft and replay attacks on other cluster API services?**
2. **In an External Secrets Operator architecture, what happens to the native Kubernetes Secret (`synced-db-secret`) if the external Secret in HashiCorp Vault is rotated, and what controls the latency of this update?**

---

### Exercise 4: Advanced Audit Logging & Threat Hunting for Sensitive Data Access

#### Objective
Configure Kubernetes API Audit Policies to track illegal Secret enumeration and anomalous access, and execute threat hunting commands against audit logs.

#### Step 4.1: Construct a Production Security Audit Policy (`audit-policy.yaml`)
Create `/etc/kubernetes/audit/audit-policy.yaml` with explicit handling for sensitive resources:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Do not log secret data payloads, but log Metadata for all operations on Secrets
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # Log RequestResponse for authorization checks to catch privilege escalation attempts
  - level: RequestResponse
    resources:
      - group: "authorization.k8s.io"
        resources: ["subjectaccessreviews", "selfsubjectaccessreviews"]

  # Log RequestHeader level for exec into pods (potential secret stealing vector)
  - level: RequestHeader
    resources:
      - group: ""
        resources: ["pods/exec", "pods/ephemeralcontainers"]

  # Default rule for all other resources
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

#### Step 4.2: Simulate an Adversary Enumerating Secrets and Analyze Audit Log Traces
Simulate unauthorized secret enumeration via a service account:

```bash
kubectl get secrets -n production-sec --as=system:serviceaccount:production-sec:default
```

Query the API Server audit log (`/var/log/kubernetes/audit/audit.log`) for suspicious bulk listing events:

```bash
grep '"resources":["secrets"]' /var/log/kubernetes/audit/audit.log | jq '{
  timestamp: .stageTimestamp,
  user: .user.username,
  verb: .verb,
  namespace: .objectRef.namespace,
  resource: .objectRef.resource,
  status: .responseStatus.code,
  userAgent: .userAgent
}'
```

Expected output:
```json
{
  "timestamp": "2026-08-07T20:17:42Z",
  "user": "system:serviceaccount:production-sec:default",
  "verb": "list",
  "namespace": "production-sec",
  "resource": "secrets",
  "status": 403,
  "userAgent": "kubectl/v1.30.0 (linux/amd64) kubernetes/92a8320"
}
```

---

#### Verification Questions – Exercise 4
1. **Why is `level: RequestResponse` prohibited for `secrets` resources in standard Kubernetes API server audit policies?**
2. **What specific API verb and subresource combination should SRE/Security teams monitor to detect interactive shell sessions used to inspect `/proc/$PID/environ` or memory-mounted secrets inside a Pod?**

---

## 4. Comprehensive Solutions & Architectural Explanations

<details>
<summary><b>Click to expand Solutions & Deep Architectural Explanations</b></summary>

### Answers & Explanations for Exercise 1

1. **`- identity: {}` Provider Placement:**
   - **Mechanism:** The `EncryptionConfiguration` evaluates providers sequentially from top to bottom during **read** operations. During **write** operations, it only uses the *first* provider in the array (in this case, `aescbc`).
   - **Architectural Necessity:** Adding `- identity: {}` at the end of the provider list ensures backward compatibility during initial encryption rollout. It allows the `kube-apiserver` to read existing unencrypted secrets from `etcd` (handled by `identity: {}`) while encrypting all newly created or updated secrets with the primary provider (`aescbc`). If `identity: {}` were omitted before executing secret migration, reading unencrypted legacy secrets would fail with decryption errors.

2. **Key Rotation & Secret Migration Protocol:**
   - **Mechanism:** To rotate keys, a new key (`key2`) is added as the top element under the `aescbc` provider block, moving `key1` to second position:
     ```yaml
     providers:
       - aescbc:
           keys:
             - name: key2
               secret: <new-base64-key>
             - name: key1
               secret: <old-base64-key>
     ```
   - **Read/Write Mechanics:** The API Server uses `key2` for all new writes. When reading existing secrets encrypted with `key1`, the API Server tries `key2`, fails, falls back to `key1`, and successfully decrypts the payload.
   - **Migration Trigger:** Existing secrets remain encrypted with `key1` until rewritten. Running `kubectl get secrets -A -o json | kubectl replace -f -` forces the API Server to read each secret (decrypting via `key1`) and replace it (encrypting via `key2`), completing the zero-downtime key rotation.

---

### Answers & Explanations for Exercise 2

1. **Environment Variables vs. `tmpfs` Dynamic Updates:**
   - **Mechanism:** Environment variables are injected into a process's control block (`struct mm_struct` in Linux kernel) strictly at process initialization (`execve`). Kubernetes cannot alter the environment block of an already running process without restarting the container.
   - **Volume Mount Mechanics:** Kubernetes Secret volume mounts utilize `tmpfs` (RAM-backed filesystem) managed by `kubelet`. When a Secret changes in `etcd`, `kubelet` receives the update, creates a new timestamped directory inside the volume, updates symbolic links (`..data` -> `..2026_08_07_...`), and atomically swaps access. Processes observing file change events (e.g., via `inotify`) receive updated secret data immediately without container restarts.

2. **Mitigating `pods/exec` Access to Mounted Secrets:**
   - **Impact:** If an attacker achieves `pods/exec` access on `secure-volume-pod`, they run code within the execution context of the container and can read any volume path readable by the process user UID.
   - **Secondary Security Controls:**
     - **RBAC Hardening:** Remove `pods/exec` and `pods/attach` permissions from non-admin roles (`verbs: ["get"]` only on `pods`).
     - **Pod Security Standards (Restricted Profile):** Enforce `readOnlyRootFilesystem: true`, set explicit `runAsNonRoot: true`, and drop all Linux capabilities (`capabilities: { drop: ["ALL"] }`).
     - **Process Isolation & Admission Controls:** Deploy Seccomp profiles (`runtime/default`) to block debugging syscalls (`ptrace`), and implement eBPF runtime security tools (e.g., Tetragon, Falco) to generate immediate alerts if unauthorized binaries open sensitive mount paths (`/var/run/secrets/app`).

---

### Answers & Explanations for Exercise 3

1. **Projected Token Audience Restriction Defense:**
   - **Mechanism:** The standard auto-mounted ServiceAccount token has a default audience equal to the Kubernetes API server (`https://kubernetes.default.svc`). If an attacker steals this token, they can replay it against the cluster API server to perform authorized operations.
   - **Security Value of Custom Audience:** When `audience: "https://vault.internal.net"` is specified, the token issuer signs the JWT with `aud: ["https://vault.internal.net"]`. If this token is leaked and presented to the Kubernetes API server or another internal service, the receiving API rejects the token because the `aud` claim does not match the target service's identity validator.

2. **External Secrets Operator Rotation Latency:**
   - **Mechanism:** ESO runs a controller loop watching `ExternalSecret` custom resources. When a secret in HashiCorp Vault is updated, ESO reads the new payload upon the expiration of its configured `refreshInterval` (e.g., `refreshInterval: "1h"`).
   - **Target Update:** ESO updates the data fields of the target native Kubernetes Secret (`synced-db-secret`). Once the native Secret is updated by ESO, `kubelet` automatically updates the mounted `tmpfs` volume files inside consuming application pods within the next `kubelet` sync period (typically ~60 seconds).

---

### Answers & Explanations for Exercise 4

1. **`level: RequestResponse` Prohibition for Secrets:**
   - **Mechanism:** Audit logging at `RequestResponse` level records the complete HTTP request body and HTTP response body for API requests.
   - **Security Risk:** For `secrets` resources, the HTTP response body contains the raw, decoded Base64 secret values. Setting audit logging to `RequestResponse` on secrets writes all cleartext passwords, tokens, and private keys directly into audit log files (`/var/log/kubernetes/audit/audit.log`), exposing sensitive data to log aggregators (Elasticsearch, Datadog, SIEM) and log storage operators. `level: Metadata` must strictly be used for secrets.

2. **Monitoring Interactive Shell Sessions:**
   - **API Resource & Verb:** Security teams must monitor requests targeting the subresource `pods/exec` or `pods/ephemeralcontainers` with verbs `create` or `get`.
   - **Audit Detection Filter:**
     ```json
     {
       "verb": "create",
       "objectRef": {
         "resource": "pods",
         "subresource": "exec"
       }
     }
     ```
   - **Runtime Forensic Mechanics:** An `exec` call executes an interactive terminal (`sh`, `bash`) inside the target container's namespaces, providing direct interactive access to `/proc/1/environ`, system environment memory, and mounted `tmpfs` secret directories. Monitoring this event allows immediate detection of lateral movement and secret discovery operations.

</details>