# Topic 3.7: Storage

## Introduction

Kubernetes decouples the lifecycle of persistent data from the lifecycle of Pods. A Pod is ephemeral: it can be rescheduled, restarted, or deleted at any time, and anything written to its local filesystem is lost in that process. The Kubernetes storage subsystem solves this through a model of abstractions that separates **what a Pod needs** (a storage claim) from **how that storage is provided** (the physical or cloud backend).

The core pieces of this model are:

- **Volumes**: the basic abstraction that attaches storage to a Pod's lifecycle.
- **PersistentVolume (PV)**: a piece of storage in the cluster, provisioned by an administrator or dynamically by a `StorageClass`.
- **PersistentVolumeClaim (PVC)**: a request for storage made by a user/application, which binds to a PV.
- **StorageClass (SC)**: defines "classes" of storage and enables dynamic provisioning of PVs.
- **CSI (Container Storage Interface)**: the standard that allows Kubernetes to talk to any storage backend (cloud, on-prem, distributed) without coupling that code to the core of Kubernetes.

## Volumes

A `Volume` in Kubernetes is a directory (possibly with data) accessible by the containers of a Pod, whose lifecycle is tied to the **Pod** (not to the individual container). This already solves a basic problem: if a container inside a Pod crashes and restarts, data in a volume survives, because the volume lives at the Pod level.

Most relevant volume types for the exam:

- **`emptyDir`**: created empty when a Pod is assigned to a node and exists as long as the Pod is running on that node. Used to share files between containers in the same Pod or as scratch space. Deleted when the Pod is removed.
- **`hostPath`**: mounts a file or directory from the node's filesystem directly into the Pod. Useful for cases like accessing Docker internals or node logs, but risky in production (breaks portability and has security implications).
- **`configMap` / `secret`**: expose configuration data or sensitive information as files inside the Pod.
- **`persistentVolumeClaim`**: the volume type that references a PVC, and is the standard way to give persistent, durable storage (that survives the Pod) to an application.

Example of a Pod using `emptyDir`:

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
    - name: cache-volume
      mountPath: /cache
  volumes:
  - name: cache-volume
    emptyDir: {}
```

## PersistentVolume (PV) and PersistentVolumeClaim (PVC)

This is the central pair of objects in Kubernetes' persistent storage model, following an analogy similar to compute (`Node` vs `Pod`):

- **PV**: a cluster-level storage resource with its own lifecycle independent of any Pod. Created by an administrator (static provisioning) or dynamically by Kubernetes via a `StorageClass`. Defines details such as capacity, `accessModes`, and the actual backend (NFS, cloud disk, CSI driver, etc.).
- **PVC**: a storage request made by a user. Specifies desired size and `accessModes`, without knowing the underlying infrastructure details. Kubernetes finds a PV that satisfies the claim and binds them.

This decoupling allows developers to request storage ("I need 10Gi with `ReadWriteOnce` access") without knowing whether underneath there is an EBS volume, an Azure disk, or an on-prem NFS array.

**Access Modes** define how the volume can be mounted:

- `ReadWriteOnce` (RWO): read/write by a single node.
- `ReadOnlyMany` (ROX): read-only by multiple nodes.
- `ReadWriteMany` (RWX): read/write by multiple nodes.
- `ReadWriteOncePod` (RWOP): read/write restricted to a single Pod (not just a node) — more recent mode, useful for strict exclusivity.

**PV lifecycle**: `Available` → `Bound` → `Released` → (`Deleted` or `Retained` depending on `reclaimPolicy`).

Example of a static PV (NFS backend):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    path: /exports/data
    server: nfs-server.example.com
```

Example of a PVC requesting that storage:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-app-data
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
```

And its usage inside a Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-storage
spec:
  containers:
  - name: app
    image: my-app:1.0
    volumeMounts:
    - name: data
      mountPath: /var/lib/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-app-data
```

Common inspection commands:

```console
$ kubectl get pv
NAME     CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                    STORAGECLASS
pv-nfs   5Gi        RWX            Retain           Bound    default/pvc-app-data     manual

$ kubectl get pvc
NAME            STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
pvc-app-data    Bound    pv-nfs   5Gi        RWX            manual
```

## StorageClass and dynamic provisioning

Manually creating PVs does not scale. The **`StorageClass`** abstraction allows defining "classes" or "profiles" of storage (e.g., `fast-ssd`, `standard-hdd`) that a `provisioner` knows how to create on demand. When a user creates a PVC referencing a `StorageClass`, Kubernetes automatically provisions the PV (dynamic provisioning), without administrator intervention.

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
```

A PVC that uses this class triggers automatic creation of the corresponding PV:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic
spec:
  storageClassName: fast-ssd
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
```

Two key parameters of `StorageClass`:

- **`reclaimPolicy`**: what happens to the PV when its PVC is deleted — `Delete` (also deletes the underlying storage) or `Retain` (retains data for manual recovery).
- **`volumeBindingMode`**: `Immediate` (provision immediately when PVC is created) or `WaitForFirstConsumer` (wait until a Pod uses the PVC, to provision in the correct zone/node — important in clouds with zonal storage).

If no `storageClassName` is specified and there is a `StorageClass` marked as default, that one is used automatically.

## Container Storage Interface (CSI)

Before CSI, storage drivers were compiled inside the core Kubernetes code ("in-tree"), meaning every new storage backend required changes to Kubernetes itself. **CSI** is an industry standard (not exclusive to Kubernetes) that defines a common interface for any storage vendor to write a driver ("out-of-tree") that orchestrates their own volumes without touching the core project.

Key benefits that the exam evaluates:

- Vendors develop and publish their drivers independently of the Kubernetes release cycle.
- Kubernetes no longer needs to maintain backend-specific code (AWS EBS, GCE PD, Azure Disk, Ceph, Portworx, etc.).
- It is the standard recommended mechanism today for any new storage integration; "in-tree" support is being deprecated.

A `StorageClass` with `provisioner: ebs.csi.aws.com` (as in the previous example) is precisely an example of using a CSI driver.

## References

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes docs — Volumes: https://kubernetes.io/docs/concepts/storage/volumes/
- Kubernetes docs — Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Kubernetes docs — Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Kubernetes docs — Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Kubernetes docs — Container Storage Interface (CSI): https://kubernetes.io/docs/concepts/storage/volumes/#csi
- Container Storage Interface (official spec): https://github.com/container-storage-interface/spec