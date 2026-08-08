# CNCF KCSA (Kubernetes & Cloud Native Security Associate)
## Topic 2.8: Etcd Security, Architecture & Operations

---

### Official Reference Documentation
- [Kubernetes Documentation: Operating etcd clusters for Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
- [Kubernetes Documentation: Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Etcd Official Security Guide](https://etcd.io/docs/v3.5/op-guide/security/)
- [Etcd Disaster Recovery Guide](https://etcd.io/docs/v3.5/op-guide/recovery/)
- [CNCF KCSA Curriculum](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

### Deep-Dive Architectural Overview: Etcd in Kubernetes

Etcd is a strongly consistent, distributed key-value store implementing the **Raft Consensus Algorithm**. In Kubernetes, etcd functions as the single source of truth for all cluster state, object metadata, and configuration secrets. 

#### Internal Storage & MVCC Engine
- **Multiversion Concurrency Control (MVCC):** Etcd does not overwrite existing key-value pairs in place. Instead, every mutation (write, update, delete) creates a new revision incrementing the global 64-bit cluster revision counter. A single logical key (e.g., `/registry/secrets/default/app-db-pass`) maintains multiple historical revisions until explicit database compaction occurs.
- **Underlying Storage Engine:** Etcd v3 uses **bbolt** (an embedded ACID key-value database written in Go) to store memory-mapped pages on disk. Keys are stored as b-tree indexes mapping logical keys to generation revisions, while values are stored in a B+ tree indexed by revision numbers.
- **Write-Ahead Log (WAL):** Before any transaction is committed to the bbolt storage engine, it is written to the WAL file and synced to physical storage (`fsync`). Raft guarantees that if a majority (quorum: $\lfloor N/2 \rfloor + 1$) of nodes successfully append the entry to their local WAL, the transaction is committed.

#### Network Architecture & Security Boundaries
Etcd exposes two distinct network endpoints:
1. **Peer Communication Port (Default `2380`):** Used exclusively for Raft consensus IPC between etcd nodes (leader election, log replication, heartbeat frames).
2. **Client Communication Port (Default `2379`):** Used by `kube-apiserver` and CLI tools (`etcdctl`) for gRPC read/write transactions.

```
       +-------------------------------------------------------------+
       |               Control Plane Node (IP: 10.0.1.10)            |
       |                                                             |
       |  +--------------------+             +--------------------+  |
       |  |  kube-apiserver    | -- mTLS --> |     etcd Server    |  |
       |  |                    |  Port 2379  |                    |  |
       |  +--------------------+             +--------------------+  |
       |                                                ^            |
       +------------------------------------------------|------------+
                                                        |
                                            mTLS (Raft Consensus)
                                            Port 2380
                                                        |
       +------------------------------------------------|------------+
       |               Control Plane Node (IP: 10.0.1.11) v          |
       |  +--------------------+             +--------------------+  |
       |  |  kube-apiserver    | -- mTLS --> |     etcd Server    |  |
       |  |                    |  Port 2379  |                    |  |
       |  +--------------------+             +--------------------+  |
       +-------------------------------------------------------------+
```

---

### Module 1: PKI Mutual TLS (mTLS) & Cluster Health Verification

Because possession of client access to etcd allows arbitrary state mutation—including bypassing API server Admission Controllers, RBAC rules, and Audit Logging—securing etcd with strict X.509 Mutual TLS (mTLS) is mandatory.

#### Guided Hands-on Execution

1. SSH into the control plane node and verify the static pod manifest parameters governing etcd transport security located at `/etc/kubernetes/manifests/etcd.yaml`.

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E '\--(cert-file|key-file|trusted-ca-file|client-cert-auth|peer-cert-file|peer-key-file|peer-trusted-ca-file|peer-client-cert-auth)'
```

**Expected Command Output:**
```text
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

2. Inspect the X.509 Server Certificate to verify Subject Alternative Names (SANs) match the control plane local loopback and node internal IP.

```bash
sudo openssl x509 -in /etc/kubernetes/pki/etcd/server.crt -text -noout | grep -A 2 "Subject Alternative Name"
```

**Expected Command Output:**
```text
            X509v3 Subject Alternative Name: 
                DNS:localhost, DNS:cp-node-01, IP Address:127.0.0.1, IP Address:10.0.1.10, IP Address:0:0:0:0:0:0:0:1
```

3. Configure environment variables for `etcdctl` using API version 3 and run health checks against the local endpoint.

```bash
export ETCDCTL_API=3
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --write-out=table
```

**Expected Command Output:**
```text
+------------------------+--------+-------------+-------+
|        ENDPOINT        | HEALTH |    TOOK     | ERROR |
+------------------------+--------+-------------+-------+
| https://127.0.0.1:2379 |   true |  8.41243ms  |       |
+------------------------+--------+-------------+-------+
```

4. Retrieve the detailed etcd member topology and check leader election status across all endpoints.

```bash
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list --write-out=table
```

**Expected Command Output:**
```text
+------------------+---------+------------+------------------------+------------------------+------------+
|        ID        | STATUS  |    NAME    |       PEER URLS        |      CLIENT URLS       | IS LEARNER |
+------------------+---------+------------+------------------------+------------------------+------------+
| 8e9e05c52164694d | started | cp-node-01 | https://10.0.1.10:2380 | https://10.0.1.10:2379 |      false |
+------------------+---------+------------+------------------------+------------------------+------------+
```

#### Verification & Comprehension Questions

- **Question 1.1:** What is the precise security consequence of setting `--client-cert-auth=false` on an etcd instance exposed on IP `0.0.0.0:2379` inside a cloud VPC?
- **Question 1.2:** Why does etcd maintain two completely separate Certificate Authority (CA) configurations or pairs of certificates for peer-to-peer (`--peer-cert-file`) and client-to-server (`--cert-file`) communications in production HA topologies?

---

### Module 2: Kubernetes Encryption at Rest (KMS v2 & AES-GCM Integration)

By default, Kubernetes writes objects to etcd in unencrypted UTF-8 serialized JSON/Protocol Buffers format. Anyone with read access to the underlying storage volume (`/var/lib/etcd`) or client access to port `2379` can extract high-privilege Secret data, including ServiceAccount tokens and database credentials.

#### Architectural Mechanics of Envelope Encryption (KMS v2)
1. **DEK Generation:** The `kube-apiserver` generates a random Data Encryption Key (DEK) locally using AES-GCM or AES-CBC.
2. **Data Encryption:** The `kube-apiserver` encrypts the plaintext Kubernetes resource (e.g., a Secret) using the DEK.
3. **Key Encryption (Envelope):** The `kube-apiserver` calls an external KMS Plugin (HashiCorp Vault, AWS KMS, GCP KMS, Azure Key Vault) via gRPC UNIX Domain Socket to encrypt the local DEK using a master Key Encryption Key (KEK).
4. **Storage:** The encrypted object payload along with the encrypted DEK metadata is stored in etcd.

```
                  +---------------------------------------------------+
                  |                 kube-apiserver                    |
                  |                                                   |
                  |  Plaintext Secret                                 |
                  |         |                                         |
                  |         v                                         |
                  |  +--------------+  Encrypts Data   +-----------+  |
                  |  |  AES-GCM     | <--------------  | Random    |  |
                  |  |  Ciphertext  |                  | DEK       |  |
                  |  +--------------+                  +-----------+  |
                  |         |                                |        |
                  +---------|--------------------------------|--------+
                            |                                |
                            |                        gRPC (UNIX Socket)
                            |                                v
                            |                          +-----------+
                            |                          | KMS Plugin| (Encrypts DEK with KEK)
                            |                          +-----------+
                            |                                |
                            v                                v
                  +---------------------------------------------------+
                  |           Combined Payload in etcd                |
                  |  [ Encrypted DEK Header ] + [ Encrypted Payload ] |
                  +---------------------------------------------------+
```

#### Guided Hands-on Execution

1. Create a complete, syntactically valid `EncryptionConfiguration` manifest at `/etc/kubernetes/enc/encryption-config.yaml` using the `aescbc` provider and a secure 32-byte base64-encoded secret key.

Generate 32 random bytes encoded in base64:
```bash
head -c 32 /dev/urandom | base64
```
*Sample Output Key: `k9X8jZ2L1pQ4vR7mS3tU5wX8yZ1aB3cD5eF7gH9iJ0k=`*

2. Construct the configuration file:

```yaml
# File path: /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
      - configmaps
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: k9X8jZ2L1pQ4vR7mS3tU5wX8yZ1aB3cD5eF7gH9iJ0k=
      - identity: {}
```

3. Modify `/etc/kubernetes/manifests/kube-apiserver.yaml` to enable the encryption provider and mount the configuration directory.

Add the following flag to the `kube-apiserver` container args:
```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

Add hostPath volumes and volumeMounts:
```yaml
  volumeMounts:
  - mountPath: /etc/kubernetes/enc
    name: enc-config
    readOnly: true
  volumes:
  - name: enc-config
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

4. Create a test secret in the `default` namespace.

```bash
kubectl create secret generic production-db-creds \
  --from-literal=username='postgres_admin' \
  --from-literal=password='SuperSecretPass2026!' \
  --namespace=default
```

**Expected Command Output:**
```text
secret/production-db-creds created
```

5. Read the raw stored byte stream directly from etcd using `etcdctl` to verify the payload is encrypted at rest and contains the key header prefix `k8s:enc:aescbc:v1:key1`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/production-db-creds
```

**Expected Command Output:**
```text
/registry/secrets/default/production-db-creds
k8s:enc:aescbc:v1:key1:%` =|U|+G-q^.?C#]0;{~,%#x!+\[4.[r+!L standard-output...
```

6. Verify that existing Secrets created prior to applying the configuration can be migrated to an encrypted state using `kubectl`.

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Expected Command Output:**
```text
secret/production-db-creds replaced
secret/sh.helm.release.v1.ingress-nginx.v1 replaced
...
```

#### Verification & Comprehension Questions

- **Question 2.1:** In an `EncryptionConfiguration` file containing multiple providers in the list, what rule governs how read transactions vs write transactions are processed by `kube-apiserver`?
- **Question 2.2:** During an encryption key rotation procedure, why must the new encryption key be positioned at the top of the provider list while keeping the old encryption key immediately below it?

---

### Module 3: Etcd Native Authentication, RBAC & Host Network Firewalling

While Kubernetes manages access control via `kube-apiserver` RBAC, etcd itself has a built-in authentication and Role-Based Access Control (RBAC) system for gRPC requests. Additionally, network-level isolation via Linux `iptables` / firewalls prevents unauthorized nodes from connecting to ports `2379` and `2380`.

#### Guided Hands-on Execution

1. Inspect the host network firewall (`iptables`) rules to ensure port 2379 is strictly restricted to incoming connections originating from authorized `kube-apiserver` IPs.

```bash
sudo iptables -L INPUT -v -n | grep -E '(2379|2380)'
```

**Expected Command Output (Standard Secure Firewall Setup):**
```text
    0     0 ACCEPT     tcp  --  *      *       10.0.1.10            0.0.0.0/0            tcp dpt:2379 /* Allow API Server access to etcd */
    0     0 ACCEPT     tcp  --  *      *       10.0.1.11            0.0.0.0/0            tcp dpt:2379 /* Allow API Server access to etcd */
    0     0 DROP       tcp  --  *      *       0.0.0.0/0            0.0.0.0/0            tcp dpt:2379 /* Drop unauthorized etcd client traffic */
```

2. Enable etcd native authentication and test creating a root administrative user along with a restricted role for monitoring applications (e.g., Prometheus etcd-exporter).

```bash
# Create root user
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  user add root --interactive=false <<< "ComplexRootPass2026!"

# Enable Auth
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  auth enable
```

**Expected Command Output:**
```text
User root created
Authentication Enabled
```

3. Create a restricted read-only role named `metrics-reader` granting access only to the `/health` and `/metrics` key prefixes, assign it to a user, and verify access denial on `/registry`.

```bash
# Create role
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! role add metrics-reader

# Grant permission to read key range
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! role grant-permission metrics-reader read --prefix /metrics

# Create user and assign role
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! user add metrics-user --interactive=false <<< "MetricsPass2026!"
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --user=root:ComplexRootPass2026! user grant-role metrics-user metrics-reader
```

4. Attempt to query `/registry/secrets` using the `metrics-user` identity.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --user=metrics-user:MetricsPass2026! \
  get /registry/secrets/default/production-db-creds
```

**Expected Command Output:**
```text
Error: etcdserver: permission denied
```

#### Verification & Comprehension Questions

- **Question 3.1:** Why does standard `kubeadm`-deployed Kubernetes rely primarily on mTLS client certificate CN/OU matching (`--client-cert-auth=true`) rather than etcd username/password RBAC for authenticating the API server?
- **Question 3.2:** If an attacker gains network access to port 2380 (the Raft peer port) on an etcd cluster member without mTLS peer authentication enforced (`--peer-client-cert-auth=false`), what specific attack vector becomes possible?

---

### Module 4: Disaster Recovery, Database Snapshotting & Integrity Verification

In a catastrophic control plane failure or ransomware scenario, SREs must restore the state of the cluster from a verified, uncorrupted Point-in-Time (PiT) etcd snapshot.

#### Guided Hands-on Execution

1. Generate a consistent database snapshot using `etcdctl snapshot save`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db
```

**Expected Command Output:**
```text
Snapshot saved at /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db
```

2. Validate the integrity, hash sum, total keys, and revision count of the generated snapshot.

```bash
sudo ETCDCTL_API=3 etcdctl \
  --write-out=table \
  snapshot status /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db
```

**Expected Command Output:**
```text
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| c4e8b9a1 |    45912 |       3210 |     4.2 MB |
+----------+----------+------------+------------+
```

3. Simulate a cluster disaster recovery procedure by restoring the snapshot into an isolated data directory `/var/lib/etcd-restored`.

```bash
sudo ETCDCTL_API=3 etcdctl \
  snapshot restore /var/lib/etcd-backup/etcd-snapshot-20260807-194500.db \
  --data-dir=/var/lib/etcd-restored \
  --name=cp-node-01 \
  --initial-cluster=cp-node-01=https://10.0.1.10:2380 \
  --initial-cluster-token=etcd-cluster-token-1 \
  --initial-advertise-peer-urls=https://10.0.1.10:2380
```

**Expected Command Output:**
```text
2026-08-07T19:46:12Z	INFO	snapshot/v3_snapshot.go:309	restoring snapshot	{"path": "/var/lib/etcd-backup/etcd-snapshot-20260807-194500.db", "wal-dir": "/var/lib/etcd-restored/member/wal", "data-dir": "/var/lib/etcd-restored", "default-backend-freelist-type": "map"}
2026-08-07T19:46:12Z	INFO	snapshot/v3_snapshot.go:336	successfully restored snapshot to "/var/lib/etcd-restored"
```

4. Update `/etc/kubernetes/manifests/etcd.yaml` hostPath volume to switch the active database pointer from `/var/lib/etcd` to `/var/lib/etcd-restored`.

```yaml
  volumes:
  - name: etcd-data
    hostPath:
      path: /var/lib/etcd-restored
      type: DirectoryOrCreate
```

5. Monitor Kubelet logs to confirm the etcd pod restarts successfully and `kube-apiserver` reconnects.

```bash
sudo crictl logs $(sudo crictl ps --name=etcd -q) 2>&1 | tail -n 10
```

**Expected Command Output:**
```text
2026-08-07T19:47:05.123Z INFO ready to serve client requests
2026-08-07T19:47:05.125Z INFO serving client requests requests on 127.0.0.1:2379
2026-08-07T19:47:05.125Z INFO serving client requests requests on 10.0.1.10:2379
```

#### Verification & Comprehension Questions

- **Question 4.1:** Why is it imperative to pass `--initial-cluster-token` and explicit `--initial-advertise-peer-urls` when executing `etcdctl snapshot restore` in a multi-node High Availability control plane?
- **Question 4.2:** What operational issue occurs if `etcdctl snapshot restore` is executed while the `etcd` static pod container is actively running and writing to `/var/lib/etcd`?

---

<details>
<summary><b>Answers & Explanations</b></summary>

### Module 1 Answers

- **Answer 1.1:** Setting `--client-cert-auth=false` disables client X.509 certificate validation on port 2379. If etcd is listening on a public or unfirewalled network interface (`0.0.0.0`), any unauthenticated network attacker can issue gRPC API requests to read all cluster secrets, bypass Kubernetes RBAC completely, modify cluster state, create privileged pods, or wipe the database entire state.
- **Answer 1.2:** Peer communication (port 2380) handles Raft consensus operations between cluster members, whereas client communication (port 2379) serves API consumers (`kube-apiserver`). Using separate CAs or distinct certificate pairs isolates security domains: compromised API server client credentials cannot be misused to join a malicious rogue etcd node to the Raft peer group, and vice versa.

---

### Module 2 Answers

- **Answer 2.1:** Providers listed in `EncryptionConfiguration` are evaluated in sequential top-to-bottom order:
  - **Write Operations:** The `kube-apiserver` strictly uses the **first** provider in the list to encrypt new or modified objects.
  - **Read Operations:** The `kube-apiserver` attempts to decrypt objects using each provider sequentially from top to bottom until one successfully decrypts the payload. If none succeed (or if an unencrypted object is read when `identity` is absent), the read fails.
- **Answer 2.2:** Placing the new key at the top of the provider list ensures that all subsequent write operations encrypt data using the new key. Retaining the old key directly underneath allows the `kube-apiserver` to seamlessly read existing objects encrypted with the old key during the transition phase. Running `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` re-writes all existing secrets, encrypting them with the top (new) key, after which the old key can safely be removed.

---

### Module 3 Answers

- **Answer 3.1:** Kubernetes relies on mTLS client certificate authentication (`--client-cert-auth=true`) because certificate-based identity verification is integrated directly into the PKI infrastructure managed by `kubeadm` or custom control plane provisioners. The client certificate SAN/CN uniquely authenticates the `kube-apiserver` over encrypted TLS channels without storing static plaintext credentials or needing stateful user databases inside etcd before bootstrapping.
- **Answer 3.2:** If port 2380 is accessible without mTLS peer authentication (`--peer-client-cert-auth=false`), an attacker can connect a rogue etcd instance to the Raft cluster topology, trigger a Raft election disruption, stream full WAL log replication updates containing all database entries, or inject malicious WAL entries to corrupt cluster consensus.

---

### Module 4 Answers

- **Answer 4.1:** Restoring a snapshot creates a new logical Raft cluster membership identity. Providing explicit `--initial-cluster-token`, `--name`, and `--initial-advertise-peer-urls` parameters prevents restored members from attempting to communicate with pre-existing, running cluster members using stale cluster IDs, preventing Raft split-brain conditions and snapshot ID mismatch panics.
- **Answer 4.2:** Restoring a snapshot into an active data directory (`/var/lib/etcd`) while etcd is running causes file descriptor locks and state inconsistencies between memory-mapped bbolt pages and the underlying WAL logs. This results in database corruption, application panics, and unrecoverable database locks. The etcd process (or static pod) must be stopped prior to directory restoration.

</details>