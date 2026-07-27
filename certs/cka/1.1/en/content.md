# 1.1 Implement storage classes and dynamic volume provisioning

## Introduction

In Kubernetes, persistent storage is managed through three primary objects: `PersistentVolume` (PV), `PersistentVolumeClaim` (PVC), and `StorageClass` (SC). While a PV represents an already provisioned physical or cloud storage resource, the purpose of a `StorageClass` is to automate provisioning: instead of administrators manually creating PVs ("static provisioning"), the cluster provisions storage on-demand when a user requests a PVC ("dynamic provisioning").

Although this topic carries a relatively small direct weight on the CKA exam (3.33%), it intersects across multiple domains: stateful workloads (StatefulSets), backup/restore operations, and troubleshooting Pods stuck in `Pending` due to storage bottlenecks.

## StorageClass: What It Is and How It Works

A `StorageClass` is a cluster-scoped (non-namespaced) object defining a storage "class" or "profile". It instructs Kubernetes **which provisioner plugin to use** and **with what parameters** to construct the requested volume.

Basic `StorageClass` manifest structure:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

Key fields:

- **`provisioner`**: Identifies the volume creation plugin. Modern clusters almost universally use **CSI** (Container Storage Interface) drivers, such as `ebs.csi.aws.com`, `pd.csi.storage.gke.io`, `disk.csi.azure.com`, or `rook-ceph.rbd.csi.ceph.com`. Legacy "in-tree provisioners" (`kubernetes.io/aws-ebs`, etc.) are deprecated in 1.25+ in favor of CSI drivers.
- **`parameters`**: Driver-specific key-value pairs (disk type, filesystem, IOPS, replication, etc.).
- **`reclaimPolicy`**: Dictates underlying storage behavior when a PVC is deleted. `Delete` (default for most dynamic provisioners) removes physical storage; `Retain` preserves the storage resource (leaving the PV in `Released` state requiring manual cleanup).
- **`allowVolumeExpansion`**: When set to `true`, enables PVC capacity expansion by editing `spec.resources.requests.storage` without volume recreation (provided the CSI driver supports it).
- **`volumeBindingMode`**:
  - `Immediate` (default): Volume provisions immediately upon PVC creation without waiting for consuming Pod scheduling. Can trigger zone placement mismatches if storage provisions in a zone separate from the scheduled Pod node.
  - `WaitForFirstConsumer`: Delays volume binding/provisioning until a consuming Pod is scheduled. The scheduler selects an optimal node honoring Pod topology constraints, then provisions storage in the matching zone. Recommended for zonal storage (e.g. AWS EBS, GCP PersistentDisk).

## Dynamic Provisioning Workflow

1. A user creates a `PersistentVolumeClaim` specifying a `storageClassName`.
2. The `StorageClass` controller (via CSI external-provisioner) detects the pending PVC.
3. If `volumeBindingMode: WaitForFirstConsumer` is configured, it waits until scheduler assigns the Pod to a node.
4. The provisioner allocates physical storage on the backend (EBS, PD, Ceph, NFS, etc.) and automatically generates a `PersistentVolume` object referencing that storage.
5. The PV binds 1:1 to the PVC.
6. The Pod mounts the PVC volume into its container filesystem.

```
PVC (Pending) --> StorageClass --> CSI provisioner --> PV (auto-generated) --> Bound
```

## Step-by-Step Example

### 1. View Available StorageClasses

```bash
kubectl get storageclass
```

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   kubernetes.io/gce-pd    Delete          Immediate              true                   40d
fast-ssd              ebs.csi.aws.com        Delete          WaitForFirstConsumer   true                   2h
```

`kubectl get sc` serves as the short alias. The `(default)` annotation identifies which class processes PVCs omitting `storageClassName`.

### 2. Create a StorageClass

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF
```

### 3. Set Default StorageClass

Kubernetes relies on the `storageclass.kubernetes.io/is-default-class` annotation. Only one default StorageClass should exist per cluster; multiple default classes produce non-deterministic behavior.

```bash
kubectl patch storageclass standard \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 4. Create PVC Triggering Dynamic Provisioning

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f pvc.yaml
kubectl get pvc data-pvc
```

With `volumeBindingMode: WaitForFirstConsumer`, the PVC remains `Pending` until a consuming Pod is scheduled:

```
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Pending                                      fast-ssd       5s
```

Creating a Pod consuming the PVC triggers volume provisioning and binding:

```bash
kubectl get pvc data-pvc
```

```
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Bound    pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab    10Gi       RWO            fast-ssd       12s
```

```bash
kubectl get pv pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab
```

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM               STORAGECLASS   AGE
pvc-3f1a2b4c-9e21-4a5d-9c33-1234567890ab   10Gi       RWO            Delete           Bound    default/data-pvc    fast-ssd       10s
```

Note that auto-generated PV names start with prefix `pvc-` followed by a unique UID string — indicating creation via dynamic provisioning rather than manual creation (static provisioning).

### 5. Expand Volume Capacity (Volume Expansion)

If the SC enables `allowVolumeExpansion: true`, update requested capacity directly on the PVC:

```bash
kubectl patch pvc data-pvc -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
```

Kubernetes reports condition `FileSystemResizePending` until kubelet completes filesystem resizing on the host node (may require running container access depending on CSI driver implementation). Confirm final capacity with:

```bash
kubectl get pvc data-pvc -o jsonpath='{.status.capacity.storage}'
```

## Exam Troubleshooting Scenarios

- **PVC stuck in `Pending` indefinitely**: Run `kubectl describe pvc <name>` — look for events like `storageclass.storage.k8s.io "x" not found` (non-existent SC), missing default SC when PVC omits `storageClassName`, or inactive CSI driver pods (`kubectl get pods -n kube-system` or driver namespace).
- **Pod stuck in `Pending` with `Bound` volume**: Often indicates topology/zone mismatches when `volumeBindingMode: Immediate` provisions storage in a zone lacking available nodes for the Pod — prefer `WaitForFirstConsumer`.
- **Incompatible `accessModes`**: PVC requests `ReadWriteMany` on block storage provisioners supporting only `ReadWriteOnce` (common on AWS EBS / GCP PD).
- **Reclaim policy `Retain`**: Deleting the PVC leaves the PV in `Released` state without auto-cleanup; requires manually deleting PV/backend storage or resetting `claimRef` to return status to `Available`.
- **Verify installed CSI drivers**: Run `kubectl get csidrivers` and `kubectl get pods -n kube-system -l app=csi-...`.

## References

- Storage Classes official documentation: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Volume Expansion: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims
- Container Storage Interface (CSI): https://kubernetes-csi.github.io/docs/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
