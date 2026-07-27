# 1.4 Utilize Persistent and Ephemeral Volumes

## Why volumes exist

A container's filesystem is ephemeral by default: it lives only as long as the container. If a container crashes and is restarted by the kubelet, or if a Pod has multiple containers that need to share files, the default filesystem does not survive or does not help. Kubernetes **volumes** solve this by attaching storage to a **Pod** (not to a container) with a lifecycle tied to the Pod. All containers in the Pod can mount the same volume, and depending on the volume type, that storage can outlive the Pod itself.

There are two broad categories relevant to the CKAD exam:

- **Ephemeral volumes** — tied to the Pod's lifecycle; deleted when the Pod is deleted. Examples: `emptyDir`, `configMap`, `secret`, `downwardAPI`, generic ephemeral volumes.
- **Persistent volumes** — storage that exists independently of any Pod, provisioned via the `PersistentVolume`/`PersistentVolumeClaim` API objects, allowing data to survive Pod restarts, rescheduling, and deletion.

---

## Ephemeral volumes

### `emptyDir`

An `emptyDir` volume is created empty when a Pod is assigned to a node and exists as long as that Pod runs on that node. It is deleted permanently when the Pod is removed (including if it's just rescheduled to another node). It's ideal for scratch space or for sharing files between containers in the same Pod (sidecar patterns).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-demo
spec:
  containers:
  - name: writer
    image: busybox:1.36
    command: ["sh", "-c", "echo hello > /cache/data.txt && sleep 3600"]
    volumeMounts:
    - name: scratch
      mountPath: /cache
  - name: reader
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: scratch
      mountPath: /data
  volumes:
  - name: scratch
    emptyDir: {}
```

```bash
kubectl exec cache-demo -c reader -- cat /data/data.txt
```
```
hello
```

By default `emptyDir` is backed by the node's disk (or default medium). You can force it into RAM (tmpfs) with `medium: Memory`, which is fast but counts against the Pod's memory limit and is lost on node reboot:

```yaml
volumes:
- name: scratch
  emptyDir:
    medium: Memory
    sizeLimit: 128Mi
```

### `configMap` and `secret` as volumes

These project existing API objects as files into a Pod's filesystem. They're technically ephemeral volumes but backed by data stored in etcd, not by the node.

```yaml
volumes:
- name: app-config
  configMap:
    name: my-config
- name: app-secret
  secret:
    secretName: my-secret
    defaultMode: 0400
```

Each key in the ConfigMap/Secret becomes a file named after the key, with the value as content. Updates to the ConfigMap/Secret propagate to the mounted files (with a sync delay), but the application must re-read the file itself — Kubernetes doesn't restart the Pod for you.

### `downwardAPI`

Exposes Pod/container metadata (labels, annotations, resource requests) as files — covered in more depth under the Pod design topic, but it is technically also an ephemeral volume type.

### Generic ephemeral volumes

A generic ephemeral volume lets a Pod spec embed a full `PersistentVolumeClaim` template directly, so storage is dynamically provisioned per-Pod but still deleted with the Pod:

```yaml
volumes:
- name: scratch-data
  ephemeral:
    volumeClaimTemplate:
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast
        resources:
          requests:
            storage: 1Gi
```

This differs from `emptyDir` because it can use any CSI driver's backing storage (e.g. block storage), not just local node storage.

### `hostPath`

Mounts a file or directory from the **host node's** filesystem directly into the Pod. It is not portable across nodes (data stays on whichever node wrote it) and is a common source of security risk, so it's mostly used for node-level agents (log collectors, monitoring daemons) rather than application data.

```yaml
volumes:
- name: host-logs
  hostPath:
    path: /var/log
    type: Directory
```

`type` matters for safety: `Directory`/`File` require the path to already exist; `DirectoryOrCreate`/`FileOrCreate` create it if missing; omitting `type` performs no checks at all.

---

## Persistent storage: PV, PVC, StorageClass

Persistent storage decouples the **lifecycle of the data** from the **lifecycle of the Pod**. Three objects work together:

| Object | Role | Created by |
|---|---|---|
| `PersistentVolume` (PV) | Cluster-scoped piece of actual storage | Admin, or dynamically by a provisioner |
| `PersistentVolumeClaim` (PVC) | Namespaced *request* for storage, binds to a PV | App developer |
| `StorageClass` | Template describing *how* to dynamically provision a PV | Admin (usually pre-existing in the cluster) |

### The flow

1. A `StorageClass` exists (or the cluster has a default one) describing a provisioner (e.g. a cloud disk, NFS, Ceph, or a CSI driver).
2. A developer creates a `PersistentVolumeClaim` requesting size, access mode, and (optionally) a `storageClassName`.
3. If dynamic provisioning is used, the StorageClass's provisioner creates a matching `PersistentVolume` automatically and binds it to the PVC. If using static provisioning, an admin pre-created PVs and Kubernetes binds the claim to a matching, unclaimed PV.
4. The Pod references the PVC (never the PV directly) in its `volumes` section.

```
Pod --uses--> PVC --binds to--> PV --backed by--> actual storage (disk, NFS export, CSI volume...)
```

### PersistentVolume example (static provisioning)

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs-01
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  nfs:
    server: 10.0.0.5
    path: /exports/data
```

### PersistentVolumeClaim example

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-claim
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: manual
```

```bash
kubectl apply -f pv-nfs.yaml -f pvc.yaml
kubectl get pv,pvc
```
```
NAME                          CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS
persistentvolume/pv-nfs-01    5Gi        RWX            Retain           Bound    default/data-claim   manual

NAME                                STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS
persistentvolumeclaim/data-claim    Bound    pv-nfs-01    5Gi        RWX            manual
```

### Mounting the PVC in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
  - name: web
    image: nginx:1.27
    volumeMounts:
    - name: data
      mountPath: /usr/share/nginx/html
      # optional: mount only a sub-directory of the volume
      subPath: html
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-claim
```

`subPath` is useful when several containers or several logical datasets share a single PVC but each needs its own subdirectory (e.g. one PVC, sidecar writes to `subPath: logs`, main container writes to `subPath: html`).

### Dynamic provisioning with a StorageClass

Most real clusters use dynamic provisioning — no admin pre-creates PVs.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
provisioner: kubernetes.io/aws-ebs   # or any CSI driver name
parameters:
  type: gp3
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dyn-claim
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f sc.yaml -f dyn-claim.yaml
kubectl get pvc dyn-claim
```
```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
dyn-claim   Bound    pvc-3f1a9e0c-9b21-4b13-8e11-7a1d9c2f4b6e    10Gi       RWO            fast           4s
```

A matching PV named `pvc-<uuid>` is created automatically. `volumeBindingMode: WaitForFirstConsumer` delays binding/provisioning until a Pod that uses the PVC is actually scheduled — important for topology-aware storage (e.g. a zone-local disk).

If you omit `storageClassName` entirely, the PVC uses the cluster's **default** StorageClass, marked with the annotation `storageclass.kubernetes.io/is-default-class: "true"`:

```bash
kubectl get storageclass
```
```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   kubernetes.io/gce-pd    Delete          Immediate              10d
fast                 kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer   2m
```

### Access modes

| Mode | Meaning |
|---|---|
| `ReadWriteOnce` (RWO) | Mounted read-write by a single node |
| `ReadOnlyMany` (ROX) | Mounted read-only by many nodes |
| `ReadWriteMany` (RWX) | Mounted read-write by many nodes |
| `ReadWriteOncePod` (RWOP) | Mounted read-write by a single **Pod** (stricter than RWO, GA since 1.29) |

Not every storage backend supports every mode — block storage (EBS, GCE PD, most CSI block drivers) is typically RWO-only; file/network storage (NFS, CephFS, EFS) can support RWX.

### Reclaim policy

Controls what happens to the underlying storage when its PVC is deleted:

- **Retain** — PV and data are kept, PV goes to `Released` state, requires manual admin cleanup before it can be reused.
- **Delete** — PV and underlying storage are deleted automatically (common default for dynamically provisioned volumes).
- **Recycle** — deprecated; do not use.

```bash
kubectl patch pv pv-nfs-01 -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

### PV lifecycle / status

```bash
kubectl get pv
```
```
NAME        CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                AGE
pv-nfs-01   5Gi        RWX            Retain           Released    default/data-claim   1h
```

Phases: `Available` (unbound, free) → `Bound` (claimed) → `Released` (claim deleted, not yet reclaimed) → `Failed` (automatic reclamation failed).

---

## StatefulSets and `volumeClaimTemplates`

Deployments share a single set of volumes across all replica Pods (or none), which doesn't work for stateful apps where each replica needs its **own** persistent storage. `StatefulSet` solves this with `volumeClaimTemplates`: Kubernetes creates one PVC per Pod replica, named `<template-name>-<statefulset-name>-<ordinal>`, and that PVC sticks with that Pod's identity across rescheduling.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db
  replicas: 3
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: db
        image: postgres:16
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast
      resources:
        requests:
          storage: 20Gi
```

```bash
kubectl get pvc -l app=db
```
```
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-db-0    Bound    pvc-1111...                                20Gi       RWO            fast
data-db-1    Bound    pvc-2222...                                20Gi       RWO            fast
data-db-2    Bound    pvc-3333...                                20Gi       RWO            fast
```

Deleting the StatefulSet (or scaling it down) does **not** delete these PVCs by default — this protects data from accidental loss. They must be deleted explicitly, or you can set a `persistentVolumeClaimRetentionPolicy` (`whenDeleted`/`whenScaled`: `Retain` or `Delete`) on the StatefulSet spec to change this behavior.

---

## Debugging volume issues

Common failure: PVC stuck in `Pending`.

```bash
kubectl describe pvc dyn-claim
```
```
Events:
  Type     Reason              Age   From                         Message
  ----     ------              ----  ----                         -------
  Warning  ProvisioningFailed  5s    persistentvolume-controller  no persistent volumes available for this claim and no storage class is set
```

Typical causes: no default StorageClass, `storageClassName` typo, no PV matches the requested access mode/size (static provisioning), or (with `WaitForFirstConsumer`) no Pod has referenced the PVC yet — check `kubectl get pod` for the consuming Pod first.

Pod stuck in `Pending`/`ContainerCreating` due to volume mount failure:

```bash
kubectl describe pod web
```
```
Events:
  Type     Reason       Age   From               Message
  ----     ------       ----  ----               -------
  Warning  FailedMount  10s   kubelet            Unable to attach or mount volumes: unmounted volumes=[data]: timed out waiting for the condition
```

---

## Quick decision guide

- Need scratch space shared between containers in one Pod, gone when the Pod dies → `emptyDir`.
- Need to inject config/secret files → `configMap`/`secret` volume.
- Need data to survive Pod restart/rescheduling → PVC backed by a PV.
- Need per-replica durable storage for a stateful app → `StatefulSet` + `volumeClaimTemplates`.
- Need to read node-local files (logs, sockets) → `hostPath` (use sparingly, security-sensitive).

---

## Referencias

- Volumes overview: https://kubernetes.io/docs/concepts/storage/volumes/
- Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- Storage Classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- Dynamic Volume Provisioning: https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- Ephemeral Volumes: https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/
- StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf