# KCSA Study Material: Topic 2.11 – Storage

---

## 1. Architectural Motivation and Production Threat Landscape

In cloud-native architectures, storage presents a unique security boundary challenge. Unlike stateless compute workloads—where a compromised pod can be terminated and re-instantiated from a clean immutable image—compromised storage can lead to persistent data exfiltration, cross-tenant data leakage, host-level filesystem access, and persistent backdoors.

```
       +-----------------------------------------------------------------------+
       |                      KUBERNETES CONTROL PLANE                         |
       |  +-------------------+  RBAC / API Audit   +------------------------+ |
       |  |  kube-apiserver   | <-----------------> |  CSI Controller Driver | |
       |  +---------+---------+                     +-----------+------------+ |
       +------------|-------------------------------------------|--------------+
                    |                                           | Provisioning
                    v                                           v (gRPC / UNIX Socket)
       +-----------------------------------------------------------------------+
       |                         KUBERNETES WORKER NODE                        |
       |  +-------------------+   Kubelet gRPC      +------------------------+ |
       |  |      Kubelet      | <-----------------> |    CSI Node Plugin     | |
       |  +---------+---------+                     |  (Privileged DaemonSet)| |
       |            |                               +-----------+------------+ |
       |            | Mount Operation                           | Attach/Format|
       |            v                                           v              |
       |  +------------------------------------------------------------------+ |
       |  |                 Host Filesystem (/var/lib/kubelet)               | |
       |  +---------------------------------+--------------------------------+ |
       |                                    |                                  |
       |                                    v                                  |
       |  +------------------------------------------------------------------+ |
       |  |                CONTAINER ISOLATION BOUNDARY                      | |
       |  |                                                                  | |
       |  |   +------------------+                    +------------------+   | |
       |  |   |   App Container  | -- Mount Target -> |  Volume (/data)  |   | |
       |  |   | (fsGroup: 20001) |                    | (chown 20001:rw) |   | |
       |  |   +------------------+                    +------------------+   | |
       |  +------------------------------------------------------------------+ |
       +------------------------------------+----------------------------------+
                                            | Physical / Network Attachment
                                            v
                       +------------------------------------------+
                       |   CLOUD / INFRASTRUCTURE BLOCK STORAGE   |
                       |  (AWS EBS / GCP PD / Ceph RBD - KMS Enc) |
                       +------------------------------------------+
```

### 1.1 Key Storage Attack Vectors in Production

1. **Host-Path Traversal & Host File Exposure:**
   Mounting `hostPath` volumes allows containers to access critical host filesystems (`/etc/shadow`, `/var/run/docker.sock`, `/var/lib/kubelet/pods`). If an attacker escapes container namespaces via misconfigured permissions on a `hostPath` mount, they achieve root escalation on the host node.

2. **CSI Plugin Exploitation & Privilege Escalation:**
   Container Storage Interface (CSI) node plugins run as privileged `DaemonSets` directly on the host to execute `mount`, `mkfs`, and `iscsiadm` operations. If the CSI plugin daemon is compromised or its gRPC UNIX domain socket (`/var/lib/kubelet/plugins/.../csi.sock`) is accessible to unprivileged pods, attackers can trigger arbitrary storage mounts host-wide.

3. **Unencrypted Volume Persistence & Snapshot Exposure:**
   Persistent Volumes (PVs) created without envelope encryption (Customer Managed Keys via AWS KMS, Azure Key Vault, or GCP Cloud KMS) expose raw data on underlying physical block devices. Unsecured `VolumeSnapshot` CRDs can allow non-privileged users to snapshot stateful workloads and clone them into adversary-controlled namespaces to read sensitive databases.

4. **Multi-Tenant Volume Hopping (`ReadWriteMany` Abuse):**
   Using shared storage systems (NFS, CephFS) with weak POSIX file permissions or missing export controls allows one tenant to mount another tenant's volume by predicting or altering PVC claims, leading to cross-tenant data corruption or leakage.

5. **Storage Denial of Service (Ephemeral Storage Exhaustion):**
   Applications writing unchecked logs, core dumps, or temporary files to standard root filesystems or unthrottled `emptyDir` volumes can exhaust node disk space, causing Kubelet `DiskPressure` taints and node-wide pod evictions.

---

## 2. Technical Deep Dive & Trade-off Matrices

### 2.1 Storage Access Modes Security Comparison

| Access Mode | Abbreviation | Multi-Node Mount | Multi-Pod Write | Security Isolation Level | Primary Use Case & Risks |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **ReadWriteOnce** | `RWO` | No | Yes (Same Node) | **Medium** | Single block storage per node. Multiple pods on the *same node* can read/write simultaneously, risking local race conditions/data leaks. |
| **ReadOnlyMany** | `ROX` | Yes | No | **High** | Read-only configuration assets or static media. Prevents runtime tampering by workload containers. |
| **ReadWriteMany** | `RWX` | Yes | Yes | **Low** | Shared filesystems (NFS, CephFS). Demands strict POSIX/RBAC governance; vulnerable to cross-tenant file overwrite if UID/GID overlap. |
| **ReadWriteOncePod** | `RWOP` | No | No (Single Pod) | **Maximum** | Strict single-pod lock (introduced in K8s 1.22, GA 1.27). Prevents any second pod on the same node from mounting the volume, mitigating race conditions and unauthorized read/write. |

### 2.2 Volume Types Security & Isolation Profiles

| Volume Type | Requires Host Privileges | Scope | Isolation | Risk Vector | Mitigation Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `hostPath` | Yes | Node Root | None | Full host compromise, root escalation. | Deprecate entirely via Pod Security Standards (`baseline`/`restricted`). |
| `emptyDir` | No | Pod Lifetime | Medium | Node disk fill (DoS attack). | Enforce `sizeLimit` parameter or set `medium: Memory` (RAM-backed tmpfs). |
| `secret` / `configMap` | No | Pod Lifetime | High | Memory leakage via tmpfs or log exposure. | Set restrictive file permissions (`defaultMode: 0400`); disable container sub-path mounting. |
| `persistentVolumeClaim` | No | Cluster Persistent | High (CSI Dependent) | Unencrypted storage at rest; unauthorized snapshot access. | Mandatory KMS StorageClasses; strict `VolumeSnapshot` RBAC rules. |
| `csi` Ephemeral | No | Pod Lifetime | High | In-line driver security flaws. | Use strict driver allowlists via `CSIDriver` object specs. |

### 2.3 CSI Storage Driver Architecture: Controller vs. Node Plugin

```
+-----------------------------------------------------------------------------------+
| CSI CONTROLLER PLUGIN (Deployment / Control Plane)                                |
|  - Runs in control plane / dedicated system namespace (e.g., kube-system).         |
|  - Talks to Kubernetes API Server and Cloud Provider API (AWS EC2, GCP Compute).   |
|  - Capabilities: CreateVolume, DeleteVolume, ControllerPublishVolume (Attach).    |
|  - Security Boundary: Network API calls, IAM Roles for Service Accounts (IRSA).  |
+-----------------------------------------------------------------------------------+
                                         |
                                         | Dynamic Provisioning
                                         v
+-----------------------------------------------------------------------------------+
| CSI NODE PLUGIN (DaemonSet / Every Worker Node)                                   |
|  - Runs on EVERY worker node with hostPath mounts & elevated capabilities.        |
|  - Capabilities: NodeStageVolume (format/LUKS setup), NodePublishVolume (mount). |
|  - Required Security Settings: privileged: true, hostNetwork: true, hostPID: true.|
|  - gRPC Socket: /var/lib/kubelet/plugins/<driver-name>/csi.sock                   |
|  - Security Boundary: Direct Linux Host Kernel, mount table, block devices.       |
+-----------------------------------------------------------------------------------+
```

---

## 3. Production Manifests (Syntactically Valid & Complete)

### 3.1 Encrypted StorageClass with KMS Integration (`storageclass-encrypted.yaml`)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3-kms-encrypted
  labels:
    tier: production
    security.cncf.io/compliance: pci-dss
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: "arn:aws:kms:us-east-1:123456789012:key/a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
  iops: "3000"
  throughput: "125"
```

### 3.2 Hardened Stateful Workload with `ReadWriteOncePod` and SecurityContext (`stateful-workload.yaml`)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: db-data-pvc
  namespace: production-db
spec:
  accessModes:
    - ReadWriteOncePod
  storageClassName: ebs-gp3-kms-encrypted
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: secure-database
  namespace: production-db
  labels:
    app.kubernetes.io/name: secure-database
spec:
  replicas: 1
  serviceName: secure-database
  selector:
    matchLabels:
      app.kubernetes.io/name: secure-database
  template:
    metadata:
      labels:
        app.kubernetes.io/name: secure-database
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 20001
        runAsGroup: 20001
        fsGroup: 20001
        fsGroupChangePolicy: "OnRootMismatch"
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: database
          image: registry.k8s.io/redis:7.0-alpine
          imagePullPolicy: IfNotPresent
          command: ["redis-server", "/etc/redis/redis.conf"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data-volume
              mountPath: /data
              readOnly: false
            - name: tmp-volume
              mountPath: /tmp
            - name: config-volume
              mountPath: /etc/redis
              readOnly: true
          resources:
            limits:
              cpu: "1"
              memory: "1Gi"
              ephemeral-storage: "2Gi"
            requests:
              cpu: "250m"
              memory: "256Mi"
              ephemeral-storage: "500Mi"
      volumes:
        - name: data-volume
          persistentVolumeClaim:
            claimName: db-data-pvc
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 128Mi
        - name: config-volume
          configMap:
            name: redis-config
            defaultMode: 0400
```

### 3.3 Kyverno Policy: Restrict Insecure Storage (`policy-enforce-storage-security.yaml`)

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-storage-security
  annotations:
    policies.kyverno.io/title: Enforce Secure Storage Practices
    policies.kyverno.io/category: Pod Security & Storage
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod, StorageClass
    kyverno.io/kyverno-version: 1.10.0
    kyverno.io/kubernetes-version: "1.27+"
    description: >-
      Disallows hostPath volume mounts and forces PVCs to use KMS-encrypted StorageClasses.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: block-hostpath-volumes
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "hostPath volumes are strictly forbidden in production cluster. Use PVCs or emptyDir."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "*?"
    - name: enforce-encrypted-storageclass
      match:
        any:
          - resources:
              kinds:
                - PersistentVolumeClaim
      validate:
        message: "PVC must explicitly use an approved encrypted StorageClass."
        pattern:
          spec:
            storageClassName: "ebs-gp3-kms-encrypted"
```

### 3.4 Least-Privilege RBAC for CSI Driver Management (`rbac-csi-restricted.yaml`)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: csi-provisioner-restricted-role
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["csinodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots", "volumesnapshotcontents"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: csi-provisioner-restricted-binding
subjects:
  - kind: ServiceAccount
    name: csi-provisioner-sa
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: csi-provisioner-restricted-role
  apiGroup: rbac.authorization.k8s.io
```

---

## 4. Real-World CLI Commands and Terminal Outputs

### 4.1 CSI Driver Registration & RBAC Audit

Inspect registered CSI drivers and ensure `requiresRepublish` and `seLinuxMount` security flags are configured.

```bash
$ kubectl get csidrivers.storage.k8s.io -o wide
```

```text
NAME              ATTACHREQUIRED   PODINFOONMOUNT   STORAGECAPACITY   TOKENREQUESTS   REQUIRESREPUBLISH   BUILDINFSGROUP   AGE
ebs.csi.aws.com   true             false            false             <none>          false               true             45d
```

Verify that the node plugin runs under the correct daemonset in the `kube-system` namespace:

```bash
$ kubectl get daemonset -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

```text
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
ebs-csi-node   3         3         3       3            3           <none>          45d
```

### 4.2 Verifying StorageClass Encryption Parameters

Validate that the active `StorageClass` contains mandatory encryption parameters.

```bash
$ kubectl get sc ebs-gp3-kms-encrypted -o jsonpath='{.parameters}' | jq .
```

```json
{
  "encrypted": "true",
  "iops": "3000",
  "kmsKeyId": "arn:aws:kms:us-east-1:123456789012:key/a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d",
  "throughput": "125",
  "type": "gp3"
}
```

### 4.3 Auditing Volume Ownership and Permissions inside Container

Verify runtime enforcement of `fsGroup` and file permission isolation on the mounted PVC volume.

```bash
$ kubectl exec -n production-db secure-database-0 -c database -- id
```

```text
uid=20001(redis) gid=20001(redis) groups=20001(redis)
```

```bash
$ kubectl exec -n production-db secure-database-0 -c database -- ls -ld /data
```

```text
drwxrws--- 2 redis redis 4096 Aug  7 18:30 /data
```

```bash
$ kubectl exec -n production-db secure-database-0 -c database -- touch /data/test_file && ls -l /data/test_file
```

```text
-rw-r--r-- 1 redis redis 0 Aug  7 18:32 /data/test_file
```

### 4.4 Inspecting Ephemeral Storage Metric Consumption

Query Kubelet metrics endpoint to identify pods consuming excessive ephemeral storage on worker nodes.

```bash
$ kubectl get --raw /metrics | grep kubelet_volume_stats_used_bytes | head -n 5
```

```text
# HELP kubelet_volume_stats_used_bytes Used bytes of volume
# TYPE kubelet_volume_stats_used_bytes gauge
kubelet_volume_stats_used_bytes{namespace="production-db",persistentvolumeclaim="db-data-pvc",plugin_name="kubernetes.io/csi"} 524288000
kubelet_volume_stats_used_bytes{namespace="production-db",volume_name="tmp-volume",plugin_name="kubernetes.io/empty-dir"} 1048576
```

---

## 5. Diagnostic and Failure Troubleshooting Guide

```
                         STORAGE TROUBLESHOOTING FLOWCHART
                                         |
                                         v
                         +-------------------------------+
                         | Pod Stuck in Pending /        |
                         | ContainerCreating State?      |
                         +---------------+---------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
        [ Mounting / CSI Failure ]             [ Runtime Permission Failure ]
                       |                                   |
           kubectl describe pod <pod>             kubectl logs <pod>
                       |                                   |
           Look for event strings:                Look for error string:
           - "KMS.NotFound / AccessDenied"        - "EACCES: permission denied"
           - "VolumeAttachment timeout"           - "ReadOnlyFileSystem"
                       |                                   |
                       v                                   v
           Check AWS/Cloud IAM IRSA               Inspect Pod securityContext:
           Check CSI Node logs in                 - Fix `fsGroup` matching app UID
           kube-system namespace                  - Set `fsGroupChangePolicy`
```

### 5.1 Scenario A: `MountVolume.SetUp failed` – KMS Authorization / CSI Driver Failure

**Symptom:**
Pod remains indefinitely in `ContainerCreating` state.

**Diagnosis Step 1: Inspect Pod Events**

```bash
$ kubectl describe pod secure-database-0 -n production-db
```

```text
Events:
  Type     Reason       Age                From                     Message
  ----     ------       ----               ----                     -------
  Normal   Scheduled    2m                 default-scheduler        Successfully assigned production-db/secure-database-0 to node-worker-01
  Warning  FailedMount  30s (x4 over 90s)  kubelet, node-worker-01  MountVolume.SetUp failed for volume "pvc-8f2a1b9c" : rpc error: code = Internal desc = Could not create volume: AccessDenied: The KMS key ARN specified is not authorized for ServiceAccount csi-controller-sa
```

**Root Cause:**
The CSI Driver Controller Service Account lacks AWS IAM permissions (`kms:CreateGrant`, `kms:GenerateDataKeyWithoutPlaintext`, `kms:Decrypt`) on the KMS key ARN specified in the `StorageClass`.

**Remediation:**
Update the IAM Policy associated with the CSI Controller Service Account IRSA (IAM Roles for Service Accounts):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:DescribeKey",
        "kms:GenerateDataKey*",
        "kms:Decrypt"
      ],
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"
    }
  ]
}
```

---

### 5.2 Scenario B: `EACCES (Permission Denied)` on Persistent Volume Mounts

**Symptom:**
Pod crashes with `CrashLoopBackOff`. Logs output `open /data/db.sqlite: permission denied`.

**Diagnosis Step 1: Check Application Container Logs**

```bash
$ kubectl logs -n production-db secure-database-0 -c database
```

```text
2026-08-07T18:40:00.123Z [FATAL] Cannot open storage directory /data: EACCES: permission denied, open '/data/lock'
```

**Root Cause:**
The PV was formatted with root ownership (`root:root`, `0755`). The pod specifies `runAsUser: 20001`, but `fsGroup` was either omitted or configured incorrectly, preventing Kubelet from recursively modifying volume ownership upon attachment.

**Remediation:**
Ensure `fsGroup` matches the application group, and set `fsGroupChangePolicy: "OnRootMismatch"` in the Pod's `securityContext` to optimize mount speed and enforce directory access rights:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 20001
    fsGroup: 20001
    fsGroupChangePolicy: "OnRootMismatch"
```

---

### 5.3 Scenario C: Node `DiskPressure` Eviction from Unbounded Ephemeral Volumes

**Symptom:**
Node transitions to `NotReady` or reports `DiskPressure`. Multiple pods evicted with `Evicted` status.

**Diagnosis Step 1: Query Node Conditions**

```bash
$ kubectl describe node node-worker-01
```

```text
Conditions:
  Type                 Status  LastHeartbeatTime                 Message
  ----                 ------  -----------------                 -------
  DiskPressure         True    Fri, 07 Aug 2026 18:45:00 -0400   Kubelet has disk pressure
```

**Diagnosis Step 2: Identify Unbounded Volume offender**

```bash
$ kubectl get pods -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CONTAINERS:.spec.containers[*].name,LIMITS:.spec.containers[*].resources.limits
```

**Root Cause:**
A container mounted an `emptyDir` without a `sizeLimit`, writing massive log files directly to `/var/lib/kubelet/pods/.../volumes/kubernetes.io~empty-dir/`, consuming host ephemeral disk.

**Remediation:**
Define strict `ephemeral-storage` limits in application container requests/limits, or use `medium: Memory` for temporary files:

```yaml
resources:
  limits:
    ephemeral-storage: "2Gi"
volumes:
  - name: tmp-volume
    emptyDir:
      medium: Memory
      sizeLimit: 256Mi
```

---

## 6. References

- **Kubernetes Documentation – Volumes Security & Types:**  
  [https://kubernetes.io/docs/concepts/storage/volumes/](https://kubernetes.io/docs/concepts/storage/volumes/)

- **Kubernetes Documentation – CSI Drivers Security Architecture:**  
  [https://kubernetes.io/docs/concepts/storage/volumes/#csi](https://kubernetes.io/docs/concepts/storage/volumes/#csi)

- **Kubernetes Security – Pod Security Standards (Storage Context):**  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

- **CNCF KCSA Official Curriculum Repository:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

- **AWS EBS CSI Driver Security & KMS Setup:**  
  [https://github.com/kubernetes-sigs/aws-ebs-csi-driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)

- **Kyverno Policy Library – Prevent HostPath Volumes:**  
  [https://kyverno.io/policies/pod-security/restricted/disallow-host-path/disallow-host-path/](https://kyverno.io/policies/pod-security/restricted/disallow-host-path/disallow-host-path/)