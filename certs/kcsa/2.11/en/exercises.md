# CNCF KCSA (Kubernetes and Cloud Native Security Associate)
## Domain 2.11: Storage Security (Exam Weight: 2.0%)

### Official Reference Documentation
* **CNCF KCSA Curriculum**: [KCSA Curriculum PDF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Documentation - Encrypting Secret Data at Rest**: [Kubernetes Encrypting Secrets](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
* **Kubernetes Documentation - Volume Security & Security Context**: [Kubernetes Volumes](https://kubernetes.io/docs/concepts/storage/volumes/)
* **Kubernetes Documentation - Pod Security Standards**: [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Container Storage Interface (CSI) Specification**: [CSI Spec GitHub](https://github.com/container-storage-interface/spec)

---

## Architectural Deep Dive & Internal Mechanics

### 1. Storage Security Attack Vectors & Threat Model
In cloud-native environments, storage presents multiple attack surfaces across control planes and data planes:
* **Unencrypted Control Plane Storage (`etcd`)**: By default, `etcd` stores API resources in plaintext. Any actor with physical, node-level, or backup access to `etcd` can read all cluster `Secrets`, service account tokens, and TLS certificates without authentication.
* **Over-Privileged Host Path Mounts (`hostPath`)**: Containers mounting host directories (`/`, `/var/run/docker.sock`, `/etc`) can break out of container namespaces, access host IPC, mutate kubelet credentials, or elevate privileges to node root.
* **Persistent Volume Data Spillage**: Non-encrypted persistent block devices or shared filesystem exports (NFS/Ceph) allow unauthorized read/write access if network isolation fails or if storage hardware is decommissioned without cryptographic erasure.
* **Sensitive Ephemeral Data Tracing**: Ephemeral scratch disks using standard disk-backed `emptyDir` volumes flush sensitive memory states to the underlying host disk swap or unencrypted storage nodes.

### 2. Encryption at Rest Architecture
Kubernetes API Server utilizes an `EncryptionConfiguration` pipeline to encrypt resources before writing to `etcd`. 
```
  [ Kube-API-Server ]
          │
          ▼
┌───────────────────────────────────┐
│ EncryptionConfiguration Pipeline  │
│ 1. AES-GCM / KMS Provider         │ ◄── Transmutes Plaintext Protobuf to Ciphertext
│ 2. Identity (Fallback)            │
└───────────────────────────────────┘
          │
          ▼ (Writes Ciphertext)
┌───────────────────────────────────┐
│             etcd DB               │
└───────────────────────────────────┘
```
* **Read Mechanics**: The API server evaluates providers sequentially from top to bottom. It attempts to decrypt using each configured provider until success.
* **Write Mechanics**: The API server encrypts *only* using the first matching provider in the list.
* **KMS v2 Architecture**: KMS (Key Management Service) v2 uses Envelope Encryption:
  1. Kube-apiserver generates a local Data Encryption Key (DEK) per resource.
  2. Kube-apiserver encrypts the resource payload using the DEK locally.
  3. Kube-apiserver calls the external KMS plugin over gRPC via UNIX domain socket to encrypt the DEK with a Key Encryption Key (KEK) managed inside an external KMS (e.g., AWS KMS, HashiCorp Vault).
  4. The encrypted DEK and encrypted payload are stored together in `etcd`.

---

## Hands-On Guided Exercises

---

### Exercise 1: Configuring Control Plane Secret Encryption at Rest via `EncryptionConfiguration`

#### Objective
Enable AES-CBC encryption for Kubernetes `Secrets` in `etcd`, verify cryptographic transformation using `etcdctl`, and execute key rotation.

#### Step 1: Inspect `etcd` Plaintext Storage
First, create an unencrypted Secret in the `default` namespace.

```bash
kubectl create secret generic db-credentials \
  --from-literal=username='admin' \
  --from-literal=password='SuperSecretPass2026!'
```
Expected output:
```text
secret/db-credentials created
```

Query `etcd` directly using `etcdctl` to verify the payload is readable in plaintext:

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-credentials | hexdump -C
```
Expected output snippet:
```text
00000000  00 6b 38 73 00 0a 0c 0a  02 76 31 12 06 53 65 63  |.k8s.....v1..Sec|
00000010  72 65 74 12 aa 01 0a c3  01 0a 0e 64 62 2d 63 72  |ret........db-cr|
00000020  65 64 65 6e 74 69 61 6c  73 12 00 1a 07 64 65 66  |edentials...def|
...
00000080  53 75 70 65 72 53 65 63  72 65 74 50 61 73 73 32  |SuperSecretPass2|
00000090  30 26 21 1a 08 75 73 65  72 6e 61 6d 65 12 05 61  |026!..username..a|
```

#### Step 2: Generate a 32-byte Base64 Encoded Key
Generate a secure random key for `aescbc` encryption:

```bash
head -c 32 /dev/urandom | base64
```
Expected output format:
```text
c29tZXJlYWxseXNlY3VyZXJhbmRvbTMyYnl0ZWtleT0=
```

#### Step 3: Create the `EncryptionConfiguration` Manifest
Save the following manifest to `/etc/kubernetes/enc/encryption-config.yaml` on the Control Plane node:

```yaml
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
              secret: c29tZXJlYWxseXNlY3VyZXJhbmRvbTMyYnl0ZWtleT0=
      - identity: {}
```

#### Step 4: Configure Kube-APIServer to use `EncryptionConfiguration`
Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` to pass the `--encryption-provider-config` flag and mount the configuration directory:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
    # ... other flags ...
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

Wait for `kube-apiserver` static pod to restart:

```bash
crictl ps --name kube-apiserver
```
Expected output:
```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID
a1b2c3d4e5f6        1234567890ab        10 seconds ago      Running             kube-apiserver      0                   f6e5d4c3b2a1
```

#### Step 5: Verify Encryption in `etcd`
Create a new Secret to test write encryption:

```bash
kubectl create secret generic encrypted-secret \
  --from-literal=token='EncryptedTokenValue999'
```

Query `etcd` for the newly created secret:

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/encrypted-secret
```
Expected output:
```text
/registry/secrets/default/encrypted-secret
k8s:enc:aescbc:v1:key1:%!#|p... (binary ciphertext)
```

#### Step 6: Encrypt Existing Plaintext Secrets
Notice that `db-credentials` (created in Step 1) remains in plaintext until rewritten. Execute a bulk update to encrypt all existing secrets:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```
Expected output:
```text
secret/db-credentials replaced
secret/encrypted-secret replaced
...
```

Verify `db-credentials` in `etcd` again:

```bash
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-credentials
```
Expected output:
```text
/registry/secrets/default/db-credentials
k8s:enc:aescbc:v1:key1:X9... (binary ciphertext starting with k8s:enc:aescbc:v1:key1:)
```

---

#### Verification Questions - Exercise 1
1. **Q1.1**: If you place `identity: {}` as the *first* item in the `providers` list of `EncryptionConfiguration`, what happens when a new Secret is written to the API server?
2. **Q1.2**: Why is it mandatory to keep the old encryption key in the `providers` list under a new primary key when performing key rotation?

---

### Exercise 2: Hardening Pod Volume Security & Ephemeral Storage Isolation

#### Objective
Implement strict POSIX permission constraints (`fsGroup`), enforce an immutable container filesystem (`readOnlyRootFilesystem`), and restrict sensitive scratch data to RAM using `emptyDir` with `medium: Memory`.

#### Step 1: Deploy a Hardened Stateful Workload
Create `hardened-storage-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-storage-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 20000
    fsGroupChangePolicy: "OnRootMismatch"
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app-container
    image: busybox:1.36.1
    command: ["sh", "-c", "echo 'writing to ram' > /tmp/scratch/data.txt && sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: ram-scratch
      mountPath: /tmp/scratch
    - name: persistent-data
      mountPath: /var/data
  volumes:
  - name: ram-scratch
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
  - name: persistent-data
    persistentVolumeClaim:
      claimName: secure-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: secure-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

Apply the manifest:

```bash
kubectl apply -f hardened-storage-pod.yaml
```
Expected output:
```text
pod/secure-storage-pod created
persistentvolumeclaim/secure-pvc created
```

#### Step 2: Test Immutable Root Filesystem Enforcement
Attempt to write to the root filesystem outside of configured volume mounts:

```bash
kubectl exec -it secure-storage-pod -- touch /opt/unauthorized.txt
```
Expected output:
```text
touch: /opt/unauthorized.txt: Read-only file system
command terminated with exit code 1
```

#### Step 3: Verify Memory-Backed `emptyDir` Mechanics
Inspect mount properties inside the container to confirm `/tmp/scratch` is backed by `tmpfs` (RAM):

```bash
kubectl exec -it secure-storage-pod -- df -T /tmp/scratch
```
Expected output:
```text
Filesystem           Type       1K-blocks      Used Available Use% Mounted on
tmpfs                tmpfs          65536         4     65532   0% /tmp/scratch
```

#### Step 4: Verify `fsGroup` Ownership Application
Verify that the directory `/var/data` mounted via PVC has its group ownership automatically adjusted to `GID 20000`:

```bash
kubectl exec -it secure-storage-pod -- ls -ld /var/data
```
Expected output:
```text
drwxrwxrwx    2 root     20000         4096 Aug  7 20:00 /var/data
```

---

#### Verification Questions - Exercise 2
1. **Q2.1**: How does `fsGroupChangePolicy: "OnRootMismatch"` improve Pod startup latency compared to the default `Always` policy on large volumes?
2. **Q2.2**: What security risk arises when mounting an `emptyDir` volume *without* setting `medium: Memory` when processing sensitive tokens or cryptographic keys?

---

### Exercise 3: Mitigating `hostPath` Vulnerabilities via Policy Engine Enforcement

#### Objective
Enforce Pod Security Standards (Restricted profile) and Kyverno policies to block dangerous `hostPath` volume mounts that expose node root filesystems.

#### Step 1: Attempt Mounting Node Root (`hostPath`)
Create an unhardened pod manifest `malicious-hostpath.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-attack-pod
  namespace: default
spec:
  containers:
  - name: compromise-node
    image: busybox:1.36.1
    command: ["sleep", "3600"]
    volumeMounts:
    - mountPath: /host/etc
      name: host-etc
  volumes:
  - name: host-etc
    hostPath:
      path: /etc
      type: Directory
```

#### Step 2: Enforce Native Pod Security Admission (PSA)
Label the `default` namespace to enforce the `restricted` Pod Security Standard:

```bash
kubectl label --overwrite namespace default pod-security.kubernetes.io/enforce=restricted
```
Expected output:
```text
namespace/default labeled
```

#### Step 3: Test Admission Denial of `hostPath`
Try applying the `malicious-hostpath.yaml` manifest:

```bash
kubectl apply -f malicious-hostpath.yaml
```
Expected output:
```text
Error from server (Forbidden): error when creating "malicious-hostpath.yaml": pods "hostpath-attack-pod" is forbidden: violates PodSecurity "restricted:latest": hostPath volumes (volume "host-etc")
```

#### Step 4: Write a Declarative Kyverno Policy for Fine-Grained Storage Control
Apply a Kyverno `ClusterPolicy` to enforce that non-root volumes must be `readOnly` if mounting `/etc` or `/var/run`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-dangerous-hostpath
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-hostpath-paths
    match:
      any:
      - resources:
          kinds:
          - Pod
    validate:
      message: "HostPath volumes targeting sensitive system paths (/etc, /var/run, /) are strictly forbidden."
      pattern:
        spec:
          =(volumes):
          - stroke:
              =(hostPath):
                path: "!/etc*"
          - stroke:
              =(hostPath):
                path: "!/var/run*"
          - stroke:
              =(hostPath):
                path: "!/"
```

Save and apply:

```bash
kubectl apply -f kyverno-storage-policy.yaml
```
Expected output:
```text
clusterpolicy.kyverno.io/block-dangerous-hostpath created
```

---

#### Verification Questions - Exercise 3
1. **Q3.1**: Why is mounting `/var/run/docker.sock` or `/run/containerd/containerd.sock` into a pod considered equivalent to providing full root access on the host node?
2. **Q3.2**: Does enforcing `readOnly: true` on a `hostPath` volume mounting `/var/log` fully mitigate host compromise vector risks? Explain the trade-off.

---

### Exercise 4: Container Storage Interface (CSI) Security & Volume Driver Isolation

#### Objective
Configure encrypted `StorageClass` configurations using CSI parameters, inspect driver RBAC boundaries, and restrict snapshot access.

#### Step 1: Inspect CSI Driver Security Scoping
Review standard CSI architecture:
* **CSI Controller Plugin**: Runs as a `Deployment` on control plane nodes. Handles `CreateVolume`, `DeleteVolume`, `AttachVolume`, `Snapshot`. Requires cluster-scoped storage management permissions.
* **CSI Node Plugin**: Runs as a `DaemonSet` on every worker node. Handles `NodeStageVolume` (formatting/mounting block devices) and `NodePublishVolume` (bind mounting to pod containers). Requires `privileged: true` host access.

Examine the security context required for CSI Node plugins:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: csi-node-driver
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: csi-node-driver
  template:
    metadata:
      labels:
        app: csi-node-driver
    spec:
      hostNetwork: true
      containers:
      - name: csi-driver
        image: registry.k8s.io/sig-storage/csi-node-driver:v1.5.0
        securityContext:
          privileged: true
          readOnlyRootFilesystem: false
          capabilities:
            add: ["SYS_ADMIN"]
        volumeMounts:
        - mountPath: /var/lib/kubelet
          mountPropagation: Bidirectional
          name: plugin-dir
      volumes:
      - hostPath:
          path: /var/lib/kubelet
          type: Directory
        name: plugin-dir
```

#### Step 2: Configure StorageClass Level Encryption Parameters
Create an encrypted `StorageClass` leveraging CSI driver level parameters (e.g., AWS EBS CSI or HashiCorp Vault KMS integration):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: secure-encrypted-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: "arn:aws:kms:us-east-1:123456789012:key/a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
```

Apply manifest:

```bash
kubectl apply -f storageclass-encrypted.yaml
```
Expected output:
```text
storageclass.storage.k8s.io/secure-encrypted-sc created
```

#### Step 3: Restrict VolumeSnapshot Content Access
VolumeSnapshots can contain sensitive disk state. Define a `VolumeSnapshotClass` with strict retention and access control:

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: secure-snapshot-class
driver: ebs.csi.aws.com
deletionPolicy: Delete
parameters:
  csi.storage.k8s.io/snapshotter-secret-name: snapshot-kms-secret
  csi.storage.k8s.io/snapshotter-secret-namespace: kube-system
```

Apply manifest:

```bash
kubectl apply -f snapshot-class.yaml
```
Expected output:
```text
volumesnapshotclass.snapshot.storage.k8s.io/secure-snapshot-class created
```

---

#### Verification Questions - Exercise 4
1. **Q4.1**: Why does a CSI Node Plugin require `mountPropagation: Bidirectional` on `/var/lib/kubelet` volume mounts?
2. **Q4.2**: If a user creates a `VolumeSnapshot` of an encrypted PVC, is the resulting snapshot encrypted, and which KMS key governs its access?

---

## Exercise Solutions & Detailed Explanations

<details>
<summary><strong>Click here to display solutions for all verification questions</strong></summary>

### Exercise 1 Solutions

* **A1.1**: If `identity: {}` is placed first in the `providers` list, new resources (Secrets/ConfigMaps) written to the API server will be stored in `etcd` in **plaintext**. The API server uses *only* the first provider in the list for **writes**. The subsequent providers (such as `aescbc` or `kms`) are only evaluated during **reads** for fallback decryption.
* **A1.2**: During key rotation, the new key is placed first under the provider (to handle all new writes). The old key must remain in the list below the new key so that existing resources encrypted with the old key can still be decrypted upon read. If the old key is removed before all resources are re-encrypted using `kubectl replace`, reads of old encrypted payloads will fail with decryption errors.

---

### Exercise 2 Solutions

* **A2.1**: By default (`fsGroupChangePolicy: "Always"`), Kubernetes recursively executes `chown` and `chmod` on every file inside the volume upon Pod startup. For volumes with millions of files, this causes severe I/O degradation and container startup timeouts. Setting `fsGroupChangePolicy: "OnRootMismatch"` causes Kubernetes to inspect only the top-level root directory of the volume; if its permissions match `fsGroup`, it skips the recursive ownership update completely, dramatically reducing startup time.
* **A2.2**: Standard `emptyDir` volumes (without `medium: Memory`) are backed by the host node's root disk filesystem (`/var/lib/kubelet/pods/...`). If sensitive data (private keys, tokens, unencrypted temp files) is written there, it persists on physical block storage. If the node crashes, swaps to disk, or is decommissioned without cryptographic erasure, an attacker with physical or out-of-band disk access can recover the sensitive residual data. `medium: Memory` guarantees the data lives strictly in RAM (`tmpfs`) and is destroyed immediately upon Pod termination.

---

### Exercise 3 Solutions

* **A3.1**: The container runtime socket (`/var/run/docker.sock` or `containerd.sock`) exposes the container engine's API without authentication to local socket clients. A container mounting this socket can issue API calls to spawn new containers with `privileged: true`, mount the host `/` root partition, escape all container namespaces, modify host system binaries, or access host environment secrets—effectively gaining immediate root access over the underlying node.
* **A3.2**: No, `readOnly: true` on `/var/log` does **not** fully eliminate host compromise risks. While it prevents writes, an attacker reading host logs can harvest sensitive operational data, API tokens, internal IP structures, and application credentials printed to stdout/stderr. Furthermore, `hostPath` mounts bypass storage isolation boundaries. To mitigate host access, use Pod Security Admission or Gatekeeper/Kyverno policies to block `hostPath` volumes entirely.

---

### Exercise 4 Solutions

* **A4.1**: `mountPropagation: Bidirectional` allows mounts created by the CSI Node Plugin container inside its `/var/lib/kubelet` path to propagate back out to the host node's filesystem. When the CSI driver mounts a block device under `/var/lib/kubelet/pods/<pod-uid>/volumes/...`, this mount must become visible to the host `kubelet` so that `kubelet` can bind-mount that directory into the workload container's namespace.
* **A4.2**: Yes, when creating a snapshot from an encrypted PVC, the underlying storage provider (e.g., AWS EBS CSI) creates an encrypted snapshot using the KMS key configured for the volume or StorageClass. Access to restore or clone the snapshot requires decryption permissions (`kms:Decrypt` and `kms:CreateGrant`) on the underlying KMS key referenced in the `VolumeSnapshotClass` parameters or storage backend policies.

</details>