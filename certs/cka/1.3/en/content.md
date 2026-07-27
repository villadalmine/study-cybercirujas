# 1.3 Manage persistent volumes and persistent volume claims

## 1. The Problem Persistent Storage Solves

Containers are ephemeral: when a Pod dies, its filesystem changes vanish. For data that must survive container restarts, Pod rescheduling, or complete Pod deletion, Kubernetes decouples **storage management** from **Pod lifecycles** via three primary objects:

- **PersistentVolume (PV)**: Represents physical/cloud storage allocated within the cluster (cloud disk, NFS, iSCSI, local storage), provisioned statically by cluster admins or dynamically by a CSI provisioner.
- **PersistentVolumeClaim (PVC)**: A user request for storage specifying capacity requirements and `accessModes`. Similar to how a Pod requests compute resources (CPU/memory) supplied by a Node.
- **StorageClass (SC)**: Defines storage profiles (disk types, provisioners, parameters) enabling **dynamic volume provisioning** of PVs without requiring manual admin pre-creation.

Standard workflow: `Pod` → references → `PVC` → binds 1:1 to → `PV` → backed by underlying storage (CSI driver, NFS, cloud disk).

## 2. PersistentVolume (PV)

A PV is a cluster-scoped (non-namespaced) resource. Static example using `hostPath` (testing/lab use only, non-production):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: /mnt/data
```

Key fields:

- `capacity.storage`: Offered volume size.
- `accessModes`: Supported mount capabilities (see Section 4).
- `persistentVolumeReclaimPolicy`: Action taken when bound PVC is deleted (`Retain`, `Delete`, `Recycle` — legacy/deprecated).
- `storageClassName`: Binds the PV to a storage class name; if omitted, matches only PVCs omitting class specifications.
- `volumeMode`: `Filesystem` (default) or `Block` (raw unformatted block devices).

```bash
kubectl get pv
```
```
NAME       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   AGE
pv-data    5Gi        RWO            Retain           Available           manual         10s
```

## 3. PersistentVolumeClaim (PVC)

A PVC is a namespaced resource. Users request storage without requiring underlying infrastructure details:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 3Gi
  storageClassName: manual
```

Kubernetes searches for an `Available` PV satisfying `accessModes`, minimum capacity requirements, and `storageClassName`, establishing a 1:1 binding.

```bash
kubectl get pvc
```
```
NAME       STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Bound    pv-data    5Gi        RWO            manual         5s
```

Note that the PVC binds to a 5Gi PV even though requesting 3Gi: binding occurs on the complete volume asset, not a sliced fraction.

## 4. Access Modes

| Mode | Abbreviation | Description |
|---|---|---|
| ReadWriteOnce | RWO | Single Node can mount volume read-write |
| ReadOnlyMany | ROX | Multiple Nodes can mount volume read-only |
| ReadWriteMany | RWX | Multiple Nodes can mount volume read-write (e.g. NFS, CephFS) |
| ReadWriteOncePod | RWOP | Single **Pod** (cluster-wide) can mount volume read-write |

Storage backends differ in supported access modes (e.g., cloud block storage backends support RWO only).

## 5. Reclaim Policy

Dictates PV cleanup behavior when its bound PVC is deleted:

- **Retain**: Preserves PV and data assets. PV enters `Released` status and requires manual administrator cleanup/recycling before re-use.
- **Delete** (default for dynamic provisioners): Automatically deletes PV and underlying physical/cloud storage.
- **Recycle**: Legacy/deprecated `rm -rf` behavior; replaced by dynamic provisioning.

```bash
kubectl patch pv pv-data -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

## 6. StorageClass and Dynamic Provisioning

Production clusters rely on `StorageClass` configurations where PVCs trigger dynamic PV allocation via **CSI drivers**.

```yaml
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
```

Key fields:

- `provisioner`: CSI driver identifier (`ebs.csi.aws.com`, `pd.csi.storage.gke.io`, `disk.csi.azure.com`, `rancher.io/local-path`).
- `allowVolumeExpansion: true`: Permits expanding PVC capacity by updating `spec.resources.requests.storage`.
- `volumeBindingMode`:
  - `Immediate`: Provisions storage immediately upon PVC creation.
  - `WaitForFirstConsumer`: Delays provisioning until consuming Pod scheduling occurs, ensuring storage matches node topology/zones.

PVCs omitting `storageClassName` consume default cluster StorageClasses:

```bash
kubectl get storageclass
```
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      DEFAULT
fast-ssd (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true
standard             rancher.io/local-path   Delete          WaitForFirstConsumer   false
```

Configured via annotation `storageclass.kubernetes.io/is-default-class: "true"`.

## 7. Using PVCs in Pods

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - name: storage
          mountPath: /usr/share/nginx/html
  volumes:
    - name: storage
      persistentVolumeClaim:
        claimName: pvc-data
```

Deployments use identical volume definitions. StatefulSets support `volumeClaimTemplates` to provision distinct PVCs per replica automatically:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
```

## 8. PVC Capacity Expansion

When `StorageClass` specifies `allowVolumeExpansion: true`:

```bash
kubectl patch pvc pvc-data -p '{"spec":{"resources":{"requests":{"storage":"10Gi"}}}}'
kubectl get pvc pvc-data
```
```
NAME       STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-data   Bound    pv-data    10Gi       RWO            fast-ssd       2m
```

Online filesystem resizing completes inside running Pod containers shortly after capacity expansion.

## 9. Common Exam Troubleshooting Scenarios

**PVC stuck in `Pending`:**

```bash
kubectl describe pvc pvc-data
```
Causes:
- No `Available` PV satisfies `accessModes`, capacity, or `storageClassName`.
- Incorrect or non-existent `storageClassName`.
- `volumeBindingMode: WaitForFirstConsumer` active while waiting for consuming Pod scheduling (normal state).
- Inactive CSI provisioner driver pods (`kubectl get pods -n kube-system`).

**Pod stuck in `Pending` due to Volume:**

```bash
kubectl describe pod app-pod
```
Inspect events: `FailedMount`, `FailedAttachVolume`, or `node(s) had volume node affinity conflict` (indicates topology mismatch between PV zone and scheduled node zone).

**PV stuck in `Released` state:**
Under `reclaimPolicy: Retain`, clear `spec.claimRef` manually to reset PV status to `Available`:

```bash
kubectl patch pv pv-data -p '{"spec":{"claimRef": null}}'
```

## References

- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Volume Snapshots reference: https://kubernetes.io/docs/concepts/storage/volume-snapshots/
- Configure a Pod to Use a PersistentVolume for Storage: https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/
- Expanding Persistent Volume Claims: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims
- CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
