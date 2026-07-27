# CKA 1.35 — Topic 1.2: Configure volume types, access modes and reclaim policies

**Curriculum Domain:** Storage
**Exam Weight:** 3.33%

## Introduction

In Kubernetes, containers are ephemeral by design: when a Pod restarts, the container filesystem is reset to its clean image state. **Volumes** solve two distinct operational challenges:

1. **Sharing data between containers** within the same Pod (sharing network namespaces, but separate filesystems by default).
2. **Persisting data** beyond the lifecycle of an individual Pod.

This topic covers three concepts that are frequently confused: **volume types** (where storage originates), **access modes** (how volume mounts are permitted across nodes), and **reclaim policies** (what happens to underlying data when a claim is deleted).

## Volume Types

Volumes are declared under Pod `spec.volumes` and mounted into containers via `volumeMounts`. The field defining volume type (`emptyDir`, `hostPath`, `persistentVolumeClaim`, etc.) specifies the backing storage engine.

### emptyDir

Created empty when a Pod is assigned to a Node, and persists as long as that Pod executes on that Node. Deleted automatically when the Pod is deleted (does not survive Pod deletion, though it survives individual container restarts within the Pod).

Common use case: temporary scratch space shared between sidecar and app containers (e.g., log processing or file generation).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: cache-vol
      mountPath: /cache
  volumes:
  - name: cache-vol
    emptyDir:
      sizeLimit: 500Mi
```

Setting `emptyDir.medium: Memory` mounts a RAM-backed `tmpfs` volume instead of disk storage — ideal for sensitive data or high-throughput low-latency I/O.

### hostPath

Mounts a file or directory from the host Node's filesystem directly into the Pod. Reduces workload portability (ties Pods to specific host paths) and presents security risks if unconstrained. Primarily used for system daemons (e.g. `kube-proxy` or CNI Pods requiring access to host `/etc/cni` or socket paths).

```yaml
volumes:
- name: host-logs
  hostPath:
    path: /var/log
    type: Directory
```

The `type` field (`Directory`, `DirectoryOrCreate`, `File`, `FileOrCreate`, `Socket`, etc.) validates preconditions on host filesystems prior to mounting.

### configMap and secret

Exposes configuration data or credentials as mounted files inside containers. Mounted as read-only and automatically updated when the underlying `ConfigMap` or `Secret` changes — except when mounted via `subPath`, which freezes the file version at mount time.

```yaml
volumes:
- name: app-config
  configMap:
    name: my-config
```

### persistentVolumeClaim (PVC)

Standard mechanism for persistent storage decoupled from Pod lifecycles. Pods reference a `PersistentVolumeClaim`, which binds 1:1 to a matching `PersistentVolume` — provisioned statically or dynamically via a `StorageClass`.

```yaml
volumes:
- name: data
  persistentVolumeClaim:
    claimName: mysql-pvc
```

### Additional Volume Types

- **`nfs`**: Mounts NFS exports directly (bypassing PV/PVC abstractions); supports `ReadWriteMany` out of the box.
- **`csi`**: Container Storage Interface driver integration — modern standard for third-party storage backends (EBS, Azure Disk, Ceph, Longhorn). Legacy "in-tree" drivers are deprecated in favor of CSI plugins.
- **`projected`**: Combines multiple volume sources (`secret`, `configMap`, `downwardAPI`, `serviceAccountToken`) into a single unified directory mount.
- **`downwardAPI`**: Exposes Pod metadata (labels, annotations, resource requests/limits) as files.

## Access Modes

`PersistentVolume` and `PersistentVolumeClaim` manifests declare how storage can be mounted simultaneously across cluster nodes:

| Access Mode | Abbreviation | Description |
|---|---|---|
| `ReadWriteOnce` | RWO | Mounted read-write by a single Node (multiple Pods on that same Node can mount it). |
| `ReadOnlyMany` | ROX | Mounted read-only by multiple Nodes simultaneously. |
| `ReadWriteMany` | RWX | Mounted read-write by multiple Nodes simultaneously. |
| `ReadWriteOncePod` | RWOP | Mounted read-write by a single **Pod** across the whole cluster (stricter than RWO). Requires CSI driver support. |

Storage backends differ in supported access modes. For example, cloud block storage (EBS, Azure Disk, GCE PD) supports only `ReadWriteOnce`, while shared network filesystems (NFS, CephFS, EFS, Azure Files) support `ReadWriteMany`.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
```

Verification with `kubectl`:

```bash
$ kubectl get pv
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM               STORAGECLASS   AGE
pv-mysql   10Gi       RWO            Retain           Bound    default/mysql-pvc   standard       2m

$ kubectl get pvc
NAME        STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
mysql-pvc   Bound    pv-mysql   10Gi       RWO            standard       2m
```

A PVC binds to a PV only if the PV satisfies **all** requested access modes, provides sufficient capacity, and matches `storageClassName`.

## Reclaim Policies

A `PersistentVolume`'s `persistentVolumeReclaimPolicy` dictates what happens to underlying storage assets when its bound `PersistentVolumeClaim` is deleted:

- **`Retain`**: Preserves the PV and underlying data. The PV transitions to `Released` status (not `Available`) and cannot automatically bind to new PVCs. Requires manual administrator cleanup (wiping data and removing `claimRef`, or deleting/re-creating the PV). Default for manually provisioned static volumes.
- **`Delete`**: Automatically deletes the PV and backend physical/cloud storage (e.g. AWS EBS volume) upon PVC deletion. Default for dynamically provisioned volumes via `StorageClass`.
- **`Recycle`** *(deprecated)*: Executed basic `rm -rf` cleanup on storage path to return PV to `Available`. Replaced by dynamic provisioning; unused in modern clusters.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-mysql
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: standard
  hostPath:
    path: /mnt/data/mysql
```

Updating reclaim policy on an existing PV without recreation:

```bash
$ kubectl patch pv pv-mysql -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
persistentvolume/pv-mysql patched
```

Useful when protecting data on dynamically provisioned volumes (`Delete` default) before deleting associated PVCs.

### StorageClass and Dynamic Provisioning

A `StorageClass` defines a `provisioner` (e.g. `ebs.csi.aws.com`) alongside default parameters including `reclaimPolicy` and `volumeBindingMode`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

`volumeBindingMode: WaitForFirstConsumer` delays binding and provisioning until a consuming Pod is scheduled, preventing volume creation in zones lacking available nodes.

Inspect cluster StorageClasses:

```bash
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   10d
fast-ssd              ebs.csi.aws.com         Delete          WaitForFirstConsumer   2m
```

## Complete Storage Lifecycle Summary

1. Administrator creates a `StorageClass` (or uses default), or manually provisions static PVs.
2. User creates a `PersistentVolumeClaim` specifying requested capacity and `accessModes`.
3. `PersistentVolumeController` binds PVC to an available matching PV, or triggers dynamic provisioning if a `StorageClass` is requested.
4. Pod references the PVC in `spec.volumes`; `kubelet` mounts storage into the node hosting the Pod.
5. Deleting the PVC triggers the PV's `reclaimPolicy` (retaining or destroying underlying storage).

## References

- Kubernetes docs — Volumes: https://kubernetes.io/docs/concepts/storage/volumes/
- Kubernetes docs — Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes docs — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes docs — Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Kubernetes docs — Configure a Pod to Use a PersistentVolume for Storage: https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
- CKA Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
