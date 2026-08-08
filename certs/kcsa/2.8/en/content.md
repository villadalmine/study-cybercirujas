# KCSA Study Guide: Topic 2.8 – Etcd Security & Architecture

---

## 1. Motivation & Production Architecture Problem

### 1.1 The Role of etcd in Kubernetes Security Boundaries
etcd is a strongly consistent, distributed key-value store implementing the **Raft consensus algorithm**. In a Kubernetes cluster, etcd serves as the single source of truth (`state store`). Every API object—including `Pods`, `ServiceAccounts`, `RBAC Roles`, `CRDs`, and `Secrets`—is serialized as JSON or Protocol Buffers and stored under the `/registry` key prefix.

From a zero-trust threat modeling perspective, etcd sits entirely outside the Kubernetes RBAC, Admission Controller, and Audit Logging subsystems:
* **Bypassing Kubernetes API Controls:** If a malicious actor or compromised process gains network or local filesystem access to etcd, they can read or modify the cluster state directly. They can forge cluster-admin privileges, extract service account tokens, inject malicious containers, or extract raw `Secret` data without triggering a single Kubernetes API audit event.
* **Storage Layer Threats:** etcd writes data to a Write-Ahead Log (`WAL`) and periodically generates snapshot files on the host disk (typically under `/var/lib/etcd`). By default, etcd stores keys and values in unencrypted plain text within its `bbolt` database file (`member/snap/db`). A leaked disk snapshot, unencrypted backup, or unauthorized volume read instantly exposes all cluster credentials.

```
+-----------------------------------------------------------------------------------+
|                                KUBERNETES CONTROL PLANE                           |
|                                                                                   |
|  +---------------------+      +---------------------+      +-------------------+  |
|  |  kubectl / Client   | ---> |   kube-apiserver    | ---> |    kubelet        |  |
|  +---------------------+      |  (RBAC, Admission,  |      +-------------------+  |
|                               |   Audit Logs)       |                             |
|                               +---------------------+                             |
|                                          |                                        |
|                                    mTLS  | Port 2379                              |
|                                          v                                        |
|                               +---------------------+                             |
|                               |     etcd Cluster    |                             |
|                               |  (Raft Consensus)   |                             |
|                               +---------------------+                             |
+------------------------------------------|----------------------------------------+
                                           | Direct Storage Access (ATTACK VECTOR)
                                           v
                              +-------------------------+
                              | /var/lib/etcd/member/db |
                              | (Unencrypted DB / WAL)  |
                              +-------------------------+
```

### 1.2 Raft Consensus Mechanics & Quorum Considerations
etcd maintains state consistency across multiple nodes through the Raft protocol. A cluster requires a **strict majority (quorum)** to perform state transitions:

$$\text{Quorum Size} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$

Where $N$ is the total number of members in the cluster.

| Total Members ($N$) | Quorum Required | Max Failure Tolerance |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

**Production SRE Trade-off:** Increasing cluster size to 5 nodes improves fault tolerance, but increases network round-trip overhead during log entry replication (`AppendEntries` RPCs). Furthermore, each additional node expands the attack surface for TLS certificate management and physical volume exposure.

### 1.3 Envelope Encryption Architecture
To protect sensitive API resources (such as `Secrets`) at rest without incurring massive performance overhead on etcd itself, Kubernetes implements **Envelope Encryption**:

1. **Data Encryption Key (DEK):** Generated locally by `kube-apiserver` (or a KMS plugin) to encrypt the raw API payload using AES-GCM or AES-CBC.
2. **Key Encryption Key (KEK):** Managed externally inside a hardware security module (HSM) or cloud KMS (e.g., AWS KMS, HashiCorp Vault, Azure Key Vault). The KEK encrypts the DEK.
3. **Payload Structure:** `kube-apiserver` writes the encrypted DEK and the encrypted payload into etcd under the target key. etcd itself remains unaware of the decryption keys.

---

## 2. Technical Comparisons & Trade-off Tables

### 2.1 Kubernetes Secret Encryption Providers Matrix

| Provider | Mechanism | Performance / Latency | Key Rotation Complexity | Security Posture | Production Recommendation |
|---|---|---|---|---|---|
| `identity` | Plaintext storage (default) | Zero overhead | N/A | **Critical Risk**: Plaintext in etcd `bbolt` DB. | Never use in Production |
| `aescbc` | AES-CBC with PKCS#7 padding | Very Low overhead | Manual (requires config updates and cluster secret re-encryption) | **Medium Risk**: Vulnerable to padding oracle attacks if IV handling is flawed; key lives in static file. | Acceptable for small/isolated bare-metal deployments |
| `secretbox` | XSalsa20 and Poly1305 | Low overhead | Manual (requires static key replacement) | **High**: Strong authenticated encryption; key lives in file. | Alternative to AES on architectures without AES-NI |
| `aesgcm` | AES-GCM with random nonce | Low overhead | Manual (key size limited, nonce reuse risk if mismanaged) | **High**: Authenticated encryption (AEAD); static key stored on host disk. | Suitable for static key AEAD requirements |
| `kms` (v2) | External KMS via gRPC Unix Domain Socket | Sub-millisecond (DEK cached in memory by APIServer) | **Automated**: KEK rotated in KMS; DEK rotated automatically without APIServer restart | **Maximum**: Keys backed by HSM/Vault; DEKs sealed by KEK; full audit trail of key access. | **Mandatory Standard for Enterprise Production** |

### 2.2 etcd Hardening Strategies Comparison

| Hardening Layer | Implementation Method | Threat Mitigated | Performance Impact | Operational Complexity |
|---|---|---|---|---|
| **Peer mTLS** | Self-signed or dedicated internal CA with SAN validation | Unauthorized node joining Raft cluster, eavesdropping on replication traffic. | Low (TLS handshake overhead on connection init) | High (Requires internal PKI and cert rotation management) |
| **Client mTLS** | `kube-apiserver` dedicated client certs (`--client-cert-auth=true`) | Unauthorized direct client queries to port 2379. | Low | High (Certs must be tightly scoped and monitored for expiration) |
| **Network Isolation** | Dedicated VLAN / CNI `NetworkPolicy` / Host Firewall (iptables/nftables) | Direct network scanning and unauthorized connection attempts to ports 2379/2380. | Negligible | Low to Medium |
| **Localhost Binding** | `--listen-client-urls=https://127.0.0.1:2379` | Remote network attacks on control plane nodes. | Zero | Low (Limits etcd to co-located single control plane nodes, not for multi-master HA) |

---

## 3. Complete, Syntactically Valid Manifests & Configurations

### 3.1 Hardened Production etcd Static Pod Manifest
File Path: `/etc/kubernetes/manifests/etcd.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/etcd.advertise-hosts.endpoint: https://192.168.10.11:2379
  creationTimestamp: null
  labels:
    component: etcd
    tier: control-plane
  name: etcd-controlplane-01
  namespace: kube-system
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://192.168.10.11:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --experimental-initial-corrupt-check=true
    - --experimental-watch-progress-notify-interval=5s
    - --initial-advertise-peer-urls=https://192.168.10.11:2380
    - --initial-cluster=controlplane-01=https://192.168.10.11:2380
    - --initial-cluster-state=new
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.10.11:2379
    - --listen-metrics-urls=https://127.0.0.1:2381
    - --listen-peer-urls=https://192.168.10.11:2380
    - --name=controlplane-01
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - --cipher-suites=TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    - --snapshot-count=10000
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    image: registry.k8s.io/etcd:3.5.12-0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 2381
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 2381
        scheme: HTTPS
      initialDelaySeconds: 5
      periodSeconds: 10
      timeoutSeconds: 5
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      readOnlyRootFilesystem: false
      runAsGroup: 0
      runAsNonRoot: false
      runAsUser: 0
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
  hostNetwork: true
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
  - hostPath:
      path: /etc/kubernetes/pki/etcd
      type: DirectoryOrCreate
    name: etcd-certs
status: {}
```

---

### 3.2 KMS v2 Encryption Configuration Manifest
File Path: `/etc/kubernetes/enc/encryption-config.yaml`

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
          endpoint: unix:///var/run/kmsplugin/v2/vault.sock
          timeout: 3s
          cachesize: 1000
      - aescbc:
          keys:
            - name: fallback-key-v1
              secret: c2V2ZW50ZWVuLWJ5dGUtbG9uZy1zZWNyZXQtcGhhc2UtMQ==
      - identity: {}
```

---

### 3.3 kube-apiserver Patch Snippet for Encryption and etcd mTLS
File Path: `/etc/kubernetes/manifests/kube-apiserver.yaml` (Excerpt under `spec.containers[0].command`)

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://192.168.10.11:2379,https://192.168.10.12:2379,https://192.168.10.13:2379
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/enc
      name: kms-enc-config
      readOnly: true
    - mountPath: /var/run/kmsplugin
      name: kms-sock
  volumes:
  - hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
    name: kms-enc-config
  - hostPath:
      path: /var/run/kmsplugin
      type: DirectoryOrCreate
    name: kms-sock
```

---

## 4. Real CLI Commands & Expected Outputs

### 4.1 Checking etcd Cluster Health and Membership via mTLS
Execute `etcdctl` using proper certificates to query cluster status across endpoints.

```bash
$ export ETCDCTL_API=3
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://192.168.10.11:2379,https://192.168.10.12:2379,https://192.168.10.13:2379 \
  endpoint health -w table
```

**Expected Output:**
```
+---------------------------+--------+-------------+-------+
|         ENDPOINT          | HEALTH |    TOOK     | ERROR |
+---------------------------+--------+-------------+-------+
| https://192.168.10.11:2379 |   true | 11.452441ms |       |
| https://192.168.10.12:2379 |   true | 12.110534ms |       |
| https://192.168.10.13:2379 |   true |  9.887213ms |       |
+---------------------------+--------+-------------+-------+
```

```bash
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://192.168.10.11:2379 \
  member list -w table
```

**Expected Output:**
```
+------------------+---------+------------------+---------------------------+---------------------------+------------+
|        ID        | STATUS  |       NAME       |        PEER URLS          |       CLIENT URLS         | IS LEARNER |
+------------------+---------+------------------+---------------------------+---------------------------+------------+
| a3e78912b45012ef | started | controlplane-01  | https://192.168.10.11:2380 | https://192.168.10.11:2379 |      false |
| b4f89023c5612300 | started | controlplane-02  | https://192.168.10.12:2380 | https://192.168.10.12:2379 |      false |
| c5a90134d6723411 | started | controlplane-03  | https://192.168.10.13:2380 | https://192.168.10.13:2379 |      false |
+------------------+---------+------------------+---------------------------+---------------------------+------------+
```

---

### 4.2 Verifying Secret Encryption at Rest in etcd

First, create a target test Secret via `kubectl`:

```bash
$ kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=SuperSecretPass123! \
  -n default
```

**Expected Output:**
```
secret/db-credentials created
```

Next, read the key directly from etcd using `etcdctl` to verify that the value is encrypted rather than plain text.

```bash
$ etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 \
  get /registry/secrets/default/db-credentials | head -n 3
```

**Expected Output (When encrypted with KMS v2):**
```
/registry/secrets/default/db-credentials
k8s:enc:kms:v2:vault-kms-provider:A%#1GV standard payload block...
```

**Expected Output (When encrypted with AES-CBC):**
```
/registry/secrets/default/db-credentials
k8s:enc:aescbc:v1:fallback-key-v1:"f+~}+~L
```

> **Security Note:** If the output begins with `{"kind":"Secret","apiVersion":"v1"`, encryption at rest is **NOT enabled**, representing a major vulnerability in a production environment.

---

### 4.3 Re-encrypting Existing Secrets After Key Rotation
Updating `EncryptionConfiguration` only encrypts *new* or *modified* write operations. Existing secrets must be re-encrypted in place.

```bash
$ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Expected Output:**
```
secret/bootstrap-token-abcdef replaced
secret/db-credentials replaced
secret/default-token-5x2pq replaced
...
```

Alternative automated method using standard Kubernetes storage migration:

```bash
$ kubectl storageversionmigrate --resources=secrets
```

---

### 4.4 Performing a Consistent Snapshot Backup

```bash
$ ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 \
  snapshot save /var/lib/etcd-backups/etcd-snapshot-$(date +%Y%m%d%H%M%S).db
```

**Expected Output:**
```
Snapshot saved at /var/lib/etcd-backups/etcd-snapshot-20260807194000.db
Initializing raw snapshot format...
Snapshot real size: 14.2 MB
Snapshot total size: 14.2 MB
Snapshot status:
Hash: a891f7c2b531
Revision: 1045923
TotalKey: 8941
TotalSize: 14876672
```

---

## 5. Verification & Troubleshooting Guide

### 5.1 Scenario A: `x509: certificate signed by unknown authority` / mTLS Handshake Failure

#### Symptom
`kube-apiserver` logs show persistent connection drops to etcd, and `etcdctl` fails with a TLS handshake error:

```
Error: remote error: tls: bad certificate
```

#### Diagnostic Protocol
1. Verify cert dates and validity periods on the node:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 2 "Validity"
   ```
2. Verify Subject Alternative Names (SANs) include the target ip address or host name:
   ```bash
   $ openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 1 "Subject Alternative Name"
   ```
3. Test mTLS connection using `openssl s_client`:
   ```bash
   $ openssl s_client -connect 192.168.10.11:2379 \
     -CAfile /etc/kubernetes/pki/etcd/ca.crt \
     -cert /etc/kubernetes/pki/etcd/server.crt \
     -key /etc/kubernetes/pki/etcd/server.key
   ```
   *Look for `Verify return code: 0 (ok)`.*

#### Remediation
If SAN is missing or cert is expired, regenerate etcd certificates using `kubeadm`:
```bash
$ kubeadm certs renew etcd-server etcd-peer etcd-healthcheck-client
```

---

### 5.2 Scenario B: Secret Decryption Failure Post-Key Rotation

#### Symptom
`kube-apiserver` returns HTTP 500 errors when reading secrets:
```
Internal error occurred: error decoding stored object: cipher: message authentication failed
```

#### Diagnostic Protocol
1. The decryption key used to encode the secret is no longer present under the `providers` list in `/etc/kubernetes/enc/encryption-config.yaml`.
2. Remember that providers are evaluated **top-to-bottom for reads**, but **only the first provider is used for writes**.
3. Inspect `kube-apiserver` pod logs:
   ```bash
   $ kubectl logs -n kube-system kube-apiserver-controlplane-01 | grep -i "encryption"
   ```

#### Remediation
Restore the previous decryption key as a secondary provider entry in `encryption-config.yaml` to allow reading older secrets, then trigger a cluster-wide secret re-encryption cycle:

```yaml
resources:
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          name: vault-kms-provider
          endpoint: unix:///var/run/kmsplugin/v2/vault.sock
      - aescbc:
          keys:
            - name: old-key-v0 # Restored for legacy read capability
              secret:T2xkS2V5VmFsdWUxMjM0NTY3ODkwMTIzNDU2Nw==
```

---

### 5.3 Scenario C: Quorum Loss and Split-Brain Recovery

#### Symptom
etcd endpoint responds with `etcdserver: request timed out` or `raft: cannot lead with stale member`.

#### Diagnostic Protocol
1. Check member status to identify the dead or non-responsive node ID:
   ```bash
   $ etcdctl --endpoints=https://127.0.0.1:2379 member list
   ```
2. If 2 nodes out of a 3-node cluster fail, quorum is permanently lost ($1 < 2$).
3. Remove dead node from Raft consensus if a majority still exists:
   ```bash
   $ etcdctl --endpoints=https://127.0.0.1:2379 member remove <unhealthy-member-id>
   ```

#### Emergency Disaster Recovery Protocol (Single Node Force Restore)
If quorum is completely lost and cannot be recovered:
1. Stop all `etcd` static pods across all control plane nodes by moving `/etc/kubernetes/manifests/etcd.yaml` out of the directory.
2. Restore the latest snapshot on a single master node with `--skip-hash-check`:
   ```bash
   $ etcdctl snapshot restore /var/lib/etcd-backups/etcd-snapshot-latest.db \
     --name=controlplane-01 \
     --initial-cluster=controlplane-01=https://192.168.10.11:2380 \
     --initial-advertise-peer-urls=https://192.168.10.11:2380 \
     --data-dir=/var/lib/etcd-restored
   ```
3. Update volume host path in `/etc/kubernetes/manifests/etcd.yaml` to point to `/var/lib/etcd-restored`.
4. Move `etcd.yaml` back to `/etc/kubernetes/manifests/` to restart the single-node cluster.

---

## 6. References

* **CNCF KCSA Curriculum:**
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Kubernetes Official Documentation – Encrypting Secret Data at Rest:**
  https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
* **Kubernetes Official Documentation – KMS v2 Provider Setup:**
  https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
* **etcd Official Security & Hardening Guide:**
  https://etcd.io/docs/v3.5/op-guide/security/
* **etcd Official Clustering & Disaster Recovery Guide:**
  https://etcd.io/docs/v3.5/op-guide/clustering/