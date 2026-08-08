# Topic 4.6: Access to Sensitive Data

## 1. Motivation and Production Architectural Problem

In a cloud-native Kubernetes environment, sensitive data—including API tokens, TLS private keys, database credentials, and cryptographic seeds—represents the primary target for malicious actors engaging in lateral movement and privilege escalation. Managed incorrectly, sensitive data becomes accessible through multiple attack surfaces across the control plane, node runtime, storage backends, and application processes.

```
                     +-------------------------------------------------------------+
                     |                Control Plane Attack Surface                 |
                     |                                                             |
                     |   [ API Request ] ---> [ RBAC Check ]                       |
                     |                             |                               |
                     |                             v                               |
                     |                  [ etcd Storage Backend ]                   |
                     |                 (Unencrypted at Rest Risk)                  |
                     +-----------------------------+-------------------------------+
                                                   |
                                                   v
                     +-------------------------------------------------------------+
                     |                 Node Runtime Attack Surface                 |
                     |                                                             |
                     |   [ kubelet ] ---> [ Pod Spec Injection ]                   |
                     |                           |                                 |
                     |           +---------------+---------------+                 |
                     |           |                               |                 |
                     |           v                               v                 |
                     |  [ Environment Variables ]       [ Volume Mounts ]          |
                     |  - Leak via /proc/$PID/environ   - Written to Disk/tmpfs   |
                     |  - Leak via Crash Dumps          - File Permission Risks    |
                     |  - Leak via Stack Traces                                    |
                     +-------------------------------------------------------------+
```

### Critical Production Risks & Threat Vectors

1. **etcd Unencrypted Storage at Rest:**
   By default, Kubernetes stores objects in etcd in plain text (encoded as Protobuf or JSON). If an attacker obtains raw access to etcd snapshots, persistent volume backups, or the underlying host storage block devices, all `Secret` objects across the cluster are compromised without needing control plane authentication.

2. **Secrets via Environment Variables:**
   Injecting secrets as environment variables (`env.valueFrom.secretKeyRef`) is a widespread antipattern in production systems due to runtime exposure:
   - **Process Inspection:** Any user or diagnostic process inside the container can read `/proc/1/environ` or run `env`/`printenv`.
   - **Subprocess Leakage:** Environment variables are automatically inherited by spawned child processes, third-party libraries, and shell executions.
   - **Logging & Crash Dumps:** Application crashes, unhandled exception stack traces, and APM tracing agents frequently capture the process environment table and export it to centralized logging stacks (e.g., Elasticsearch, Datadog).

3. **Over-Privileged ServiceAccount RBAC:**
   Assigning coarse permissions (such as `get`, `list`, `watch` on `secrets` at the `ClusterRole` level) allows compromised workloads or compromised CI/CD ServiceAccounts to scrape all cluster secrets. Wildcard rules (`verbs: ["*"]`, `resources: ["*"]`) eliminate privilege boundaries.

4. **In-Memory & Storage Persistence Risks:**
   When secrets are mounted as files, standard Kubernetes `Secret` volumes use an `in-memory` backing store (`tmpfs`). However, if node RAM experiences heavy memory pressure, secrets held in memory can be swapped out to unencrypted node swap partitions (`/dev/swap`) or included in unencrypted kernel core dumps (`/var/crash`).

5. **Lack of Lifecycle Synchronization & Secret Rotation:**
   Standard Kubernetes `Secret` objects lack built-in auto-rotation capabilities. When credentials in an external authority (e.g., HashiCorp Vault, AWS Secrets Manager) change, static Kubernetes secrets become stale, forcing dangerous manual updates or custom scripting that risks operational outages.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Secret Injection Architectures

| Architecture Pattern | Security Posture | Operational Complexity | Rotation Capabilities | Performance & Latency | Failure Blast Radius |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Environment Variables (`envFrom` / `secretKeyRef`)** | **Low:** Exposed in `/proc/$PID/environ`, crash dumps, logs, and process child trees. | **Low:** Native Kubernetes functionality; no external controllers required. | **None:** Requires pod restart/recreation to pick up updated values. | **Optimal:** Injected at pod startup; zero runtime API calls. | High (Static, easily leaked credentials across logs). |
| **Mounted `tmpfs` Volumes (`spec.volumes.secret`)** | **Medium-High:** Isolated to filesystem permissions (`defaultMode: 0400`), non-persistent memory. | **Low:** Native Kubernetes feature supported by `kubelet`. | **Partial:** `kubelet` syncs updates to volume, but application must watch file events. | **High:** Memory-mapped reads from node `tmpfs`. | Medium (Scoped to filesystem path inside the container). |
| **External Secrets Operator (ESO)** | **High:** Native secrets synced dynamically from Vault/AWS/GCP with fine-grained RBAC. | **Medium:** Requires installing ESO controller CRDs and managing authentication tokens. | **High:** Native reconciliation loop auto-updates Kubernetes `Secret` resources. | **High:** Local reads; sync happens out-of-band via operator control loop. | Medium (Creates standard K8s Secret objects in etcd). |
| **Secrets Store CSI Driver** | **Very High:** Secret payloads fetched on demand; optional non-persistence in etcd. | **High:** Requires CSI driver DaemonSet, provider plugins, and `SecretProviderClass` CRDs. | **Very High:** Auto-rotation updates mounted files dynamically in `tmpfs`. | **Medium:** Storage mount latency at pod startup due to external gRPC calls. | Low (No Secret object stored in etcd if etcd sync is disabled). |
| **Direct SDK Integration (e.g., Vault SDK)** | **Maximum:** No sensitive data stored on disk or etcd; credentials held only in app memory. | **Very High:** Application code refactoring required; tight coupling to Secret Provider API. | **Maximum:** Application manages dynamic lease renewal and token rotation in RAM. | **Low-Medium:** Network latency on app boot and token renewal cycles. | Isolated (Scoped strictly to the application process runtime). |

---

### 2.2 etcd Encryption at Rest Providers

| Encryption Provider | Cryptographic Algorithm | Key Storage Location | Rotation Complexity | Threat Model Coverage | Performance Overhead |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`identity` (Default)** | None (Plaintext / Protobuf) | etcd database | N/A | None | Zero |
| **`aescbc`** | AES-CBC with PKCS#7 padding | Plaintext in `EncryptionConfiguration` file on control plane host | **High:** Manual double-phase file modification and API server restarts | Protects against raw etcd disk theft. Vulnerable if control plane disk is compromised. | Very Low |
| **`secretbox`** | XSalsa20 and Poly1305 | Plaintext in `EncryptionConfiguration` file on control plane host | **High:** Manual key file manipulation and control plane rolling updates | Protects against raw etcd disk theft. | Very Low |
| **`kms` (v2)** | AES-GCM-256 (DEK) encrypted by Remote Envelope Key (KEK) | Remote Cloud KMS (AWS KMS, GCP KMS, Vault, Azure Key Vault) | **Low:** Automated KEK rotation handled remotely; automated DEK generation | Full protection against etcd theft, control plane disk theft, and snapshot compromises. | Low (DEKs cached locally in memory by KMS v2 plugin). |

---

## 3. Production-Ready Infrastructure & Workload Manifests

### 3.1 Control Plane Encryption Configuration (`EncryptionConfiguration` KMS v2)

The following manifest configures `kube-apiserver` to encrypt all `Secret` objects in etcd using a KMS v2 gRPC provider, falling back to `aescbc` for key transitions, with `identity` at the bottom to allow decrypting legacy unencrypted data.

Save as `/etc/kubernetes/etcd-encryption/encryption-config.yaml` on control plane nodes:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - kms:
          apiVersion: v2
          name: vault-kms-provider
          endpoint: unix:///var/run/kmsplugin/kms.sock
          timeout: 3s
      - aescbc:
          keys:
            - name: key-20260807
              secret: dGhpcyBpcyBhIDMyIGJ5dGUgYWVzIGtleSBleGFtcGxlIQ==
      - identity: {}
```

---

### 3.2 External Secrets Operator (ESO) Architecture Integration

This manifest sets up an isolated `SecretStore` authenticating to HashiCorp Vault via Kubernetes ServiceAccount Token Volume Projection, followed by an `ExternalSecret` resource that syncs production database credentials into a Kubernetes native `Secret`.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-vault-auth-sa
  namespace: production
---
apiVersion: v1
kind: Secret
metadata:
  name: eso-vault-auth-sa-token
  namespace: production
  annotations:
    kubernetes.io/service-account.name: eso-vault-auth-sa
type: kubernetes.io/service-account-token
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend-store
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.internal.example.com:8200"
      path: "secret"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: internal-ca-bundle
        key: ca.crt
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "production-app-role"
          secretRef:
            name: eso-vault-auth-sa-token
            key: token
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: production-db-credentials-sync
  namespace: production
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend-store
    kind: SecretStore
  target:
    name: production-db-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          app.kubernetes.io/managed-by: external-secrets
        annotations:
          security.kubernetes.io/sensitive: "true"
      data:
        DB_USERNAME: "{{ .username }}"
        DB_PASSWORD: "{{ .password }}"
  data:
    - secretKey: username
      remoteRef:
        key: production/database/config
        property: db_user
    - secretKey: password
      remoteRef:
        key: production/database/config
        property: db_pass
```

---

### 3.3 Workload Deployment using Secrets Store CSI Driver with `tmpfs`

This production deployment mounts sensitive credentials into a memory-backed (`tmpfs`) volume via the Secrets Store CSI Driver. It explicitly disables etcd synchronization, preventing sensitive payload persistence in etcd, and enforces strict security contexts (`readOnlyRootFilesystem`, non-root execution, `seccompProfile`).

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-db-csi-provider
  namespace: production
spec:
  provider: vault
  parameters:
    vaultAddress: "https://vault.internal.example.com:8200"
    roleName: "production-app-role"
    objects: |
      - objectName: "db-username"
        secretPath: "secret/data/production/database/config"
        secretKey: "db_user"
      - objectName: "db-password"
        secretPath: "secret/data/production/database/config"
        secretKey: "db_pass"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-api-service
  namespace: production
  labels:
    app.kubernetes.io/name: secure-api-service
    app.kubernetes.io/part-of: payment-gateway
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: secure-api-service
  template:
    metadata:
      labels:
        app.kubernetes.io/name: secure-api-service
    spec:
      serviceAccountName: eso-vault-auth-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-container
          image: registry.example.com/payment/api:v2.4.1
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: secrets-store-inline
              mountPath: "/mnt/secrets/db"
              readOnly: true
          ports:
            - containerPort: 8443
              name: https
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-db-csi-provider"
```

---

### 3.4 Least-Privilege RBAC Manifest for Secret Access

This RBAC specification grants strict, single-resource read access to a specific `Secret` for an operator controller while blocking cluster-wide wildcard escalation.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: db-credential-reader
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["production-db-credentials"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-db-credential-reader
  namespace: production
subjects:
  - kind: ServiceAccount
    name: eso-vault-auth-sa
    namespace: production
roleRef:
  kind: Role
  name: db-credential-reader
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Real CLI Commands and Terminal Outputs

### 4.1 Verifying etcd Encryption at Rest

#### Command 1: Creating a test Secret in the cluster
```bash
$ kubectl create secret generic production-api-key \
  --namespace=production \
  --from-literal=api-token="SECURE_TOKEN_VALUE_2026_KCSA"
```
```output
secret/production-api-key created
```

#### Command 2: Querying raw etcd storage directly using `etcdctl` to verify encryption
```bash
$ ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get /registry/secrets/production/production-api-key
```
```output
/registry/secrets/production/production-api-key
k8s:enc:kms:v2:vault-kms-provider:7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a...[BINARY KMS DEK DATA]...
```

*Analysis:* The output prefix `k8s:enc:kms:v2:vault-kms-provider:` proves that the secret payload stored at key `/registry/secrets/production/production-api-key` is fully encrypted by KMS v2. Unencrypted secrets display standard ASCII Protobuf text containing `apiVersion` and plaintext keys.

---

### 4.2 Demonstrating Process Environment Variable Leakage Threat

#### Command 1: Executing into a container misconfigured with environment variable secret references
```bash
$ kubectl exec -n production deployment/vulnerable-api-service -- cat /proc/1/environ | tr '\0' '\n' | grep DB_
```
```output
DB_USERNAME=admin_user
DB_PASSWORD=SuperSecretPassWord123!
DB_HOST=prod-db.internal.net
```

#### Command 2: Inspecting the filesystem mount of the CSI driver secure pod configuration
```bash
$ kubectl exec -n production deployment/secure-api-service -- ls -la /mnt/secrets/db
```
```output
total 0
drwxrwxrwt 2 root root  80 Aug  7 20:25 .
drwxr-xr-x 3 root root  16 Aug  7 20:25 ..
-r--r--r-- 1 root root  10 Aug  7 20:25 db-password
-r--r--r-- 1 root root  10 Aug  7 20:25 db-username
```

#### Command 3: Verifying that volume backing store is `tmpfs` (RAM) inside the container node host
```bash
$ kubectl exec -n production deployment/secure-api-service -- df -T /mnt/secrets/db
```
```output
Filesystem           Type       1K-blocks      Used Available Use% Mounted on
tmpfs                tmpfs        8153408         4   8153404   1% /mnt/secrets/db
```

---

### 4.3 Auditing Secret Access via Kubernetes Audit Logs

#### Command 1: Querying audit logs for high-risk Secret `get`/`list` requests using `jq`
```bash
$ tail -n 1000 /var/log/kubernetes/audit/audit.log | jq -r '
  select(.objectRef.resource=="secrets" and (.verb=="list" or .verb=="get")) |
  [.stageTimestamp, .user.username, .verb, .objectRef.namespace, .objectRef.name, .responseStatus.code] |
  @tsv'
```
```output
2026-08-07T20:28:12Z    system:serviceaccount:production:unauthorized-sa    list    production    <nil>   403
2026-08-07T20:29:45Z    kubernetes-admin    get    production    production-api-key    200
2026-08-07T20:31:02Z    system:serviceaccount:production:eso-vault-auth-sa    get    production    production-db-credentials    200
```

---

### 4.4 Verifying RBAC Access Restrictions

#### Command: Testing API access using `kubectl auth can-i`
```bash
$ kubectl auth can-i list secrets \
  --namespace=production \
  --as=system:serviceaccount:production:eso-vault-auth-sa
```
```output
no
```

```bash
$ kubectl auth can-i get secrets/production-db-credentials \
  --namespace=production \
  --as=system:serviceaccount:production:eso-vault-auth-sa
```
```output
yes
```

---

## 5. Verification and Failure Diagnostic Guide

### 5.1 Decision Tree: Diagnosing KMS Encryption at Rest Failures

```
                     +---------------------------------------------------+
                     | kube-apiserver fails to start or Secret creation |
                     | throws "Internal error occurred: KMS provider..." |
                     +-------------------------+-------------------------+
                                               |
                                               v
                     +---------------------------------------------------+
                     | Inspect /var/log/pods/kube-system_kube-apiserver |
                     | or control plane journalctl -u kube-apiserver     |
                     +-------------------------+-------------------------+
                                               |
              +--------------------------------+--------------------------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| Error: "connection refused"|                                     | Error: "kms provider      |
| or "no such file/directory"|                                     | operation timed out"      |
+-------------+-------------+                                     +-------------+-------------+
              |                                                                 |
              v                                                                 v
+---------------------------+                                     +---------------------------+
| Check UNIX domain socket: |                                     | Check upstream KMS health:|
| Is the KMS plugin daemon  |                                     | Vault/Cloud KMS latency,  |
| running on host?          |                                     | network egress policies,  |
| Is socket volume-mounted  |                                     | IAM authorization status. |
| into apiserver pod spec?  |                                     +---------------------------+
+---------------------------+
```

---

### 5.2 Diagnostic Commands & Troubleshooting Workflow

#### Issue 1: KMS Plugin Connection Failure
**Symptom:** `kubectl create secret` fails with `rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing dialect...`.

1. Check if the KMS plugin socket exists on the host:
   ```bash
   $ ls -la /var/run/kmsplugin/kms.sock
   ```
   *Expected Output:* `srw-rw---- 1 root root 0 Aug 7 20:00 /var/run/kmsplugin/kms.sock`

2. Verify `hostPath` mount in `/etc/kubernetes/manifests/kube-apiserver.yaml`:
   ```yaml
   volumeMounts:
     - mountPath: /var/run/kmsplugin/kms.sock
       name: kms-socket
   volumes:
     - hostPath:
         path: /var/run/kmsplugin/kms.sock
         type: Socket
       name: kms-socket
   ```

---

#### Issue 2: ExternalSecret Synchronization Failure (`SecretStore` Error)
**Symptom:** `ExternalSecret` status shows `SecretSyncedError`.

1. Inspect the status conditions of the `ExternalSecret` CRD:
   ```bash
   $ kubectl get externalsecret production-db-credentials-sync \
     --namespace=production \
     -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' | jq
   ```
   ```output
   {
     "lastTransitionTime": "2026-08-07T20:35:10Z",
     "message": "can not config provider client: vault access denied: permission denied for path secret/data/production/database/config",
     "reason": "SecretStoreUnavailable",
     "status": "False",
     "type": "Ready"
   }
   ```

2. Validate Vault auth role alignment:
   Ensure the ServiceAccount token namespace matches the bound authentication role configured inside HashiCorp Vault policies:
   ```bash
   $ vault read auth/kubernetes/role/production-app-role
   ```

---

#### Issue 3: Secrets Store CSI Driver Mount Failures
**Symptom:** Pod stuck in `ContainerCreating` status.

1. Inspect Pod events:
   ```bash
   $ kubectl describe pod -l app.kubernetes.io/name=secure-api-service -n production
   ```
   ```output
   Events:
     Type     Reason       Age    From               Message
     ----     ------       ----   ----               -------
     Warning  FailedMount  12s    kubelet            MountVolume.SetUp failed for volume "secrets-store-inline" : rpc error: code = Unknown desc = failed to mount secrets store objects for pod production/secure-api-service-7d8f9b6c-x4z12, err: error mounting target "/var/lib/kubelet/pods/.../volumes/kubernetes.io~csi/secrets-store-inline/mount": provider "vault" not registered
   ```

2. Fix: Verify that the specific provider DaemonSet (e.g., `csi-secrets-store-provider-vault`) is active on the node:
   ```bash
   $ kubectl get daemonset -n kube-system -l app.kubernetes.io/name=csi-secrets-store-provider-vault
   ```
   ```output
   NAME                               READY   DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
   csi-secrets-store-provider-vault   5       5         5         5            5           42d
   ```

---

## 6. References

- [CNCF KCSA Curriculum GitHub Repository](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Official Documentation: Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes Official Documentation: KMS v2 Provider Configuration](https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/)
- [External Secrets Operator (ESO) Architecture & Docs](https://external-secrets.io/latest/)
- [Kubernetes Secrets Store CSI Driver Documentation](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Kubernetes Official Documentation: Controlling Access to Secrets](https://kubernetes.io/docs/concepts/configuration/secret/#information-security-for-secrets)
- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)