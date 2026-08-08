# KCSA Study Guide: Domain 3.4 — Secrets Management & Hardening

**Exam:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Domain:** 3.4 Secrets  
**Target Audience:** SREs, Security Engineers, and Platform Architects  

---

## 1. Production Architectural Problem & Security Fundamentals

### The Base64 Encoding Misconception
A fundamental security anti-pattern in Kubernetes is treating native `Secret` objects as confidential data stores out of the box. Kubernetes `Secret` resources (`v1.Secret`) store key-value payloads encoded in **Base64** (`RFC 4648`). Base64 is an encoding scheme designed for data serialization over text-based transport protocols, **not an encryption mechanism**. Any user or process with `get` or `list` permissions on `secrets` in a namespace can trivially decode payloads:

```bash
echo "c3VwZXItc2VjcmV0LXBhc3N3b3Jk" | base64 --decode
# Output: super-secret-password
```

### Threat Vectors & Attack Surfaces

```
   ┌────────────────────────────────────────────────────────────────────────┐
   │                          ATTACK SURFACES                               │
   └────────────────────────────────────────────────────────────────────────┘
                                      │
       ┌──────────────────────────────┼──────────────────────────────┐
       ▼                              ▼                              ▼
┌──────────────┐              ┌──────────────┐              ┌────────────────┐
│   etcd Database              │ Node Filesystem             │ Container Proc │
│   Unencrypted   │              │   Host Path  │              │  /proc/1/env   │
│  Persistence │              │ Leakage Risk │              │ Environment    │
└──────────────┘              └──────────────┘              └────────────────┘
```

#### 1. etcd Cleartext Persistence
By default, the `kube-apiserver` serializes state objects (including `v1.Secret`) directly into the `etcd` key-value store as unencrypted JSON or Protocol Buffers. Anyone with direct access to `etcd` endpoints, storage snapshots, or node disk backups can extract plaintext credentials directly from `/registry/secrets/<namespace>/<secret-name>`.

#### 2. Environment Variable Exposure
Injecting secrets via container `env` or `envFrom` fields exposes sensitive strings through multiple host mechanisms:
* `/proc/<pid>/environ` process inspect files accessible by other processes on the host running with sufficient privileges or container escapes.
* Application crash dumps, stack traces, and unredacted stdout/stderr log aggregators (e.g., Fluentbit, Datadog Agent).
* `kubectl describe pod` commands and `kube-apiserver` audit logs revealing pod specifications.

#### 3. Over-privileged RBAC & API Access
Granting wildcard RBAC permissions (`verbs: ["*"]` or `resources: ["secrets"]` with `verbs: ["get", "list", "watch"]`) allows lateral movement. Additionally, permissions like `pods/exec` or `pods/ephemeralcontainers` allow attackers to execute interactive sessions inside pods where secrets are mounted or injected.

#### 4. Static ServiceAccount Tokens
Legacy Kubernetes ServiceAccount tokens were auto-generated static secrets stored indefinitely as `v1.Secret` resources (`kubernetes.io/service-account-token`). If exfiltrated, these tokens provided indefinite cluster access unless manually deleted or rotated.

---

## 2. Technical Architecture & Deep-Dive Mechanics

### etcd Encryption at Rest (KMS v2 Architecture)

To secure secrets at rest in `etcd`, Kubernetes provides API server Encryption at Rest via the `EncryptionConfiguration` resource. In production environments, **KMS v2 (Key Management Service)** is the gold standard architecture.

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    KUBE-APISERVER                                         │
│                                                                                           │
│  ┌──────────────┐      Envelope Encryption      ┌──────────────────────────────────────┐  │
│  │  v1.Secret   │ ────────────────────────────> │ KMS v2 Provider (gRPC Plugin Driver) │  │
│  └──────────────┘                               └──────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┬──────────────────────────────┘
                                                             │ UNIX Domain Socket
                                                             │ (/var/run/kmsplugin/socket.sock)
                                                             ▼
                                                  ┌──────────────────────┐
                                                  │   KMS Plugin App     │
                                                  └──────────┬───────────┘
                                                             │ REST / gRPC API (TLS)
                                                             ▼
                                                  ┌──────────────────────┐
                                                  │ External Cloud KMS   │
                                                  │ (AWS KMS / GCP KMS)  │
                                                  └──────────────────────┘
```

#### Envelope Encryption Mechanics:
1. **Data Encryption Key (DEK):** The `kube-apiserver` generates a local, unique DEK (e.g., AES-256 GCM) in memory to encrypt the `v1.Secret` payload.
2. **Key Encryption Key (KEK):** The DEK is passed via a local UNIX domain socket to a KMS plugin process using gRPC. The plugin forwards the DEK to an external HSM/KMS (e.g., AWS KMS, GCP Cloud KMS, HashiCorp Vault), which encrypts the DEK using a master KEK.
3. **Storage:** The `kube-apiserver` writes the encrypted secret payload alongside the encrypted DEK metadata into `etcd`.
4. **Decryption:** During read operations, the `kube-apiserver` sends the encrypted DEK to the KMS plugin to recover the plaintext DEK, caches the decrypted DEK (subject to KMS v2 key cache TTL), and decrypts the secret.

### Secrets Delivery Vectors: Memory-Backed Volumes vs. Projected Tokens

To prevent secret leakage via the filesystem disk or container inspects, production workloads must strictly use **tmpfs-backed Secret Volumes** or **Bound ServiceAccount Token Volume Projection**.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 KUBERNETES NODE                                 │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                             KUBELET ENGINE                                │  │
│  └─────────────────────────────────────┬─────────────────────────────────────┘  │
│                                        │ Mounts tmpfs                           │
│                                        ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │ RAM-backed File System: /var/lib/kubelet/pods/<pod-id>/volumes/.../tmpfs  │  │
│  └─────────────────────────────────────┬─────────────────────────────────────┘  │
│                                        │ Bind Mount (ReadOnly)                  │
│                                        ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │ CONTAINER PROCESS                                                         │  │
│  │ Mount Path: /var/run/secrets/tokens/vault-token                           │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

#### Bound ServiceAccount Token Projection
Kubernetes modern security posture relies on TokenRequest API (`serviceAccountToken` volume projection):
* **Audience Binding (`aud`):** Tokens are scoped strictly to target services (e.g., `vault`, `sts.amazonaws.com`).
* **Time Bound (`expirationSeconds`):** Short-lived TTLs (e.g., 3600s). Kubelet automatically rotates the token on disk when 80% of its lifetime has elapsed.
* **Object Binding:** Tokens are bound to the specific Pod instance (`podName`, `podUID`). If the Pod is terminated, the token is invalidated immediately by the API server.

---

## 3. Technical Comparisons & Trade-offs Tables

### Table 3.1: etcd Secret Encryption Providers

| Encryption Provider | Encryption Algorithm | Key Location | Production Readiness | Security & Operational Trade-offs |
| :--- | :--- | :--- | :--- | :--- |
| `identity` | None (Plaintext) | N/A | **Unsafe** (Default) | Zero overhead. Payload is saved directly as unencrypted JSON/Protobuf in `etcd`. |
| `aescbc` | AES-CBC with PKCS#7 | Static key in YAML file on control plane host | **Moderate** | Protects against raw `etcd` dumps. Vulnerable if control plane filesystem containing `EncryptionConfiguration` is compromised. |
| `secretbox` | XSalsa20 and Poly1305 | Static key in YAML file on control plane host | **Moderate** | Modern authenticated encryption scheme. Shares the same static key exposure risk as `aescbc`. |
| `kms` (v1) | AES-GCM (DEK) / KMS Master Key (KEK) | Remote Cloud KMS / HSM via gRPC socket | **Deprecated** | Envelope encryption. High latency overhead under load due to synchronous call paths and lack of robust DEK caching. |
| **`kms` (v2)** | AES-GCM (DEK) / KMS Master Key (KEK) | Remote Cloud KMS / HSM via gRPC socket | **Recommended Gold Standard** | Asynchronous status checks, highly optimized DEK caching, key rotation metadata embedded in encrypted payload, seamless multi-key rotation. |

---

### Table 3.2: Secret Delivery Mechanisms to Containers

| Mechanism | Resistance to Leakage | Persistence Medium | Rotation Support | Operational Trade-offs |
| :--- | :--- | :--- | :--- | :--- |
| **Environment Variables** (`env`, `envFrom`) | **Low** | Process Environment (`/proc/<pid>/environ`) | **None** (Requires container restart) | Easy to implement, but vulnerable to log dumps, process inspects, and child process inheritance leaks. |
| **Standard Secret Volume** (`volumes.secret`) | **High** | Node RAM (`tmpfs` virtual filesystem) | **Automatic** (Kubelet sync propagation delay ~1 min) | Non-persistent across node reboots. Application must watch filesystem (inotify) to reload rotated keys dynamically. |
| **Projected ServiceAccount Token** | **Critical / Maximum** | Node RAM (`tmpfs`) with `readOnly: true` | **Automatic** (Kubelet proactive rotation at 80% TTL) | Cryptographically bound to Pod identity, audience, and time-to-live. Mitigates credential exfiltration replay attacks. |

---

### Table 3.3: External Secrets Management Patterns

| Pattern / Solution | Secret Store Location | Kubernetes Manifest Safety | Zero-Trust Capabilities | Trade-offs & Operational Complexity |
| :--- | :--- | :--- | :--- | :--- |
| **Sealed Secrets** (Bitnami) | Asymmetrical Public Key in Cluster | Encrypted YAML safe to commit to Git (GitOps) | Low (Decrypts back to standard `v1.Secret` in `etcd`) | Easy setup. Does not integrate natively with external enterprise vaults; private key management inside cluster remains a single point of failure. |
| **External Secrets Operator (ESO)** | External Enterprise Vault (AWS Secrets Mgr, HashiCorp Vault) | Manifest contains references, not raw payload values | Medium (Synchronizes external secret into a `v1.Secret` in `etcd`) | Native Kubernetes controller model. Excellent for multicloud synchronization; target state still materializes as a standard Kubernetes `Secret`. |
| **Vault Sidecar / Agent Injector** | HashiCorp Vault Cluster | No secret manifest stored inside Kubernetes | **High** (Dynamic short-lived credentials generated on demand) | Circumvents Kubernetes `v1.Secret` storage completely. Secrets reside strictly in app memory/tmpfs. Requires Vault infrastructure and init-container/sidecar overhead. |

---

## 4. Complete Production Manifests & Infrastructure Configurations

### Manifest 4.1: Production `EncryptionConfiguration` (KMS v2 Provider with Fallback)

Save this configuration on control plane nodes (e.g., `/etc/kubernetes/etcd-encryption/config.yaml`) and point `kube-apiserver` to it using `--encryption-provider-config=/etc/kubernetes/etcd-encryption/config.yaml`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      # Primary Encryption Provider (KMS v2)
      - kms:
          apiVersion: v2
          name: aws-kms-provider
          endpoint: unix:///var/run/kmsplugin/kms.sock
          timeout: 3s
          cachesize: 1000
      # Secondary Provider for smooth key rotation/fallback operations
      - aescbc:
          keys:
            - name: key-20260807
              secret: dGhpcyBpcyBhIHZlcnkgc2VjdXJlIDMyIGJ5dGUga2V5IQ==
      # Identity provider at the bottom allows reading older unencrypted secrets
      - identity: {}
```

---

### Manifest 4.2: Hardened Pod Spec Utilizing Mounted Secrets & Projected Bound SA Tokens

This manifest enforces complete container isolation, non-root execution, `tmpfs` secret volume mounting, and short-lived projected tokens.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload-pod
  namespace: production-apps
  labels:
    app.kubernetes.io/name: payment-processor
    security.kubernetes.io/tier: hardened
spec:
  serviceAccountName: payment-processor-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: payment-app
      image: registry.enterprise.internal/finance/payment-processor:v2.4.1
      imagePullPolicy: IfNotPresent
      command: ["/app/payment-processor"]
      args: ["--config=/etc/app-secrets/db-credentials.json"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: db-secret-volume
          mountPath: /etc/app-secrets
          readOnly: true
        - name: vault-token-projected
          mountPath: /var/run/secrets/tokens/vault
          readOnly: true
      resources:
        limits:
          cpu: "500m"
          memory: "512Mi"
        requests:
          cpu: "100m"
          memory: "128Mi"
  volumes:
    # Memory-backed tmpfs volume for standard secret payload
    - name: db-secret-volume
      secret:
        secretName: db-primary-credentials
        defaultMode: 256 # Decimal for 0400 octal (read-only by owner)
        optional: false
    # Bound projected ServiceAccount token volume
    - name: vault-token-projected
      projected:
        defaultMode: 256
        sources:
          - serviceAccountToken:
              audience: https://vault.enterprise.internal:8200
              expirationSeconds: 3600
              path: vault-token
```

---

### Manifest 4.3: External Secrets Operator (`SecretStore` & `ExternalSecret`)

Integrates external secret engines (e.g., HashiCorp Vault) directly into Kubernetes without hardcoding sensitive strings into deployment manifests.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend-store
  namespace: production-apps
spec:
  provider:
    vault:
      server: "https://vault.internal.domain:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "payment-processor-role"
          secretRef:
            name: payment-processor-sa-token
            key: token
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-primary-credentials-sync
  namespace: production-apps
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend-store
    kind: SecretStore
  target:
    name: db-primary-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          managed-by: external-secrets
      data:
        db-credentials.json: '{"username":"{{ .username }}","password":"{{ .password }}"}'
  data:
    - secretKey: username
      remoteRef:
        key: production/databases/mysql
        property: DB_USER
    - secretKey: password
      remoteRef:
        key: production/databases/mysql
        property: DB_PASS
```

---

### Manifest 4.4: Hardened RBAC for Secrets (Least-Privilege Isolation)

Establishes strict boundary controls preventing unauthorized secret exfiltration or pod injection vectors.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: secret-reader-restricted
rules:
  # Allows reading metadata only, strictly prohibiting listing or fetching raw secret payloads
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: payment-app-config-operator
  namespace: production-apps
rules:
  # Granting update access strictly to specific named secret instances
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-primary-credentials"]
    verbs: ["get", "update", "patch"]
  # Explicitly DENY exec/attach/ephemeralcontainers access on pods to mitigate container inspection attacks
  - apiGroups: [""]
    resources: ["pods/exec", "pods/attach", "pods/ephemeralcontainers"]
    verbs: [] # Explicit omission denies operational capabilities
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-payment-operator
  namespace: production-apps
subjects:
  - kind: ServiceAccount
    name: payment-processor-sa
    namespace: production-apps
roleRef:
  kind: Role
  name: payment-app-config-operator
  apiGroup: rbac.authorization.k8s.io
```

---

## 5. Real CLI Commands & Realistic Terminal Outputs

### Step 1: Create a Secret and Inspect Raw Base64 Payload via API

```bash
$ kubectl create secret generic db-primary-credentials \
    --namespace=production-apps \
    --from-literal=username='admin_prod' \
    --from-literal=password='K8sSecOps#2026!DeepPass'
```

```text
secret/db-primary-credentials created
```

```bash
$ kubectl get secret db-primary-credentials -n production-apps -o jsonpath='{.data.password}'
```

```text
SzhzU2VjT3BzIzIwMjYhRGVlcFBhc3M=
```

---

### Step 2: Directly Query etcd Key to Verify KMS Encryption at Rest

To verify that the secret is encrypted at rest in `etcd` (and not stored as unencrypted Base64/plaintext), execute `etcdctl` on a master control plane node using valid cluster certificates:

```bash
$ ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/production-apps/db-primary-credentials
```

#### Expected Terminal Output (Encrypted with KMS v2):

```text
/registry/secrets/production-apps/db-primary-credentials
k8s:enc:kms:v2:aws-kms-provider:AQICAHg7X1l9k8...[BINARY DATA TRUNCATED]...9b3X1A0fZ8==
```

> **Security Verification Note:** The output string starts with the prefix `k8s:enc:kms:v2:aws-kms-provider:`. If the output contains legible JSON strings or raw Base64 data (e.g., `k8s...{"kind":"Secret"...`), Encryption at Rest is **NOT** active or misconfigured.

---

### Step 3: Re-encrypt Existing Secrets After Enabling KMS

Modifying `EncryptionConfiguration` encrypts **newly created or updated** secrets. Existing secrets stored in `etcd` before configuration remain unencrypted until explicitly mutated. Re-encrypt all existing secrets cluster-wide with:

```bash
$ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

```text
secret/db-primary-credentials replaced
secret/default-token-x8z9q replaced
secret/vault-tls-certs replaced
...
```

---

### Step 4: Audit RBAC Secret Access Permissions (`auth can-i`)

Impersonate specific ServiceAccounts or cluster roles to verify least-privilege boundary rules:

```bash
$ kubectl auth can-i get secrets/db-primary-credentials \
    --as=system:serviceaccount:production-apps:payment-processor-sa \
    --namespace=production-apps
```

```text
yes
```

```bash
$ kubectl auth can-i list secrets \
    --as=system:serviceaccount:production-apps:payment-processor-sa \
    --namespace=production-apps
```

```text
no
```

```bash
$ kubectl auth can-i exec pods \
    --as=system:serviceaccount:production-apps:payment-processor-sa \
    --namespace=production-apps
```

```text
no
```

---

## 6. Verification, Failure Modes & Troubleshooting Guide

### Common Production Failure Scenarios & Diagnostics

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                 DIAGNOSTIC MATRIX                               │
└─────────────────────────────────────────────────────────────────────────────────┘
     │
     ├─► KMS Socket Disconnection ───► Kube-APISERVER 500 / Timeout Errors
     │
     ├─► Unencrypted Legacy Keys  ───► ETCD Direct Query Validation Failure
     │
     └─► Mount Permission Denied  ───► Container CrashLoopBackOff (0400 Check)
```

#### Scenario 1: KMS Plugin Unix Socket Unavailable or Unresponsive
* **Symptom:** `kubectl get secrets` or pod creation commands fail with HTTP 500 status code: `Internal error occurred: error spending DEK: rpc error: code = Unavailable desc = connection error`.
* **Root Cause:** The KMS plugin container or systemd service crashed, or the UNIX domain socket path defined in `EncryptionConfiguration` (`unix:///var/run/kmsplugin/kms.sock`) is unreachable by `kube-apiserver`.
* **Troubleshooting Steps:**
  1. Inspect API server logs for gRPC failures:
     ```bash
     journalctl -u kube-apiserver | grep -i "kms"
     ```
  2. Verify UNIX socket existence and permissions on control plane host:
     ```bash
     ls -la /var/run/kmsplugin/kms.sock
     ```
  3. Test gRPC connectivity using `grpc_health_probe`:
     ```bash
     /usr/local/bin/grpc_health_probe -addr=unix:///var/run/kmsplugin/kms.sock
     ```

#### Scenario 2: Decryption Failure During Control Plane Key Rotation
* **Symptom:** `kube-apiserver` fails to start or throws `decryption failed: cipher: message authentication failed` when retrieving secrets.
* **Root Cause:** The `EncryptionConfiguration` provider list was updated, but the key used to encrypt historical secrets was removed from the file instead of being placed below the new primary key.
* **Remediation Rule:** Always preserve old encryption keys at the bottom of the `providers` list in `EncryptionConfiguration` until all secrets have been re-encrypted with the new primary key via `kubectl replace`.

#### Scenario 3: Container Mount Permission Denied on Memory Volume
* **Symptom:** Pod stuck in `CrashLoopBackOff`. Logs state `open /etc/app-secrets/db-credentials.json: permission denied`.
* **Root Cause:** `defaultMode: 256` (`0400` octal) restricts reading to UID `10001`. If the container process executes under a different user or UID without matching `fsGroup` permissions, execution fails.
* **Verification:**
  ```bash
  kubectl get pod secure-workload-pod -n production-apps -o jsonpath='{.spec.securityContext}'
  ```

---

## 7. References

* **Kubernetes Official Documentation — Encrypting Confidential Data at Rest:**  
  https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
* **Kubernetes Official Documentation — KMS v2 Provider Configuration:**  
  https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
* **Kubernetes Official Documentation — ServiceAccount Token Volume Projection:**  
  https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-token-volume-projection
* **CNCF KCSA Official Curriculum Repository:**  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **OWASP Kubernetes Security Cheat Sheet (Secrets Management):**  
  https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html
* **External Secrets Operator Official Documentation:**  
  https://external-secrets.io/latest/