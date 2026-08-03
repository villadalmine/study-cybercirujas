# Storage in Kubernetes — Guided Exercises (KCNA 3.7)

> Reference source: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

Requirements: a Kubernetes cluster accessible with `kubectl` (`minikube`, `kind`, or `Docker Desktop` work, as you need a default `StorageClass` for dynamic provisioning exercises).

---

## Exercise 1 — `emptyDir`: ephemeral storage shared between containers

1. Create the file `pod-emptydir.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-emptydir
spec:
  containers:
  - name: writer
    image: busybox
    command: ["sh", "-c", "echo 'hola desde writer' > /data/mensaje.txt && sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  - name: reader
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  volumes:
  - name: shared-data
    emptyDir: {}
```

2. Apply the manifest:

```
kubectl apply -f pod-emptydir.yaml
```

3. Wait until the Pod is `Running`:

```
kubectl get pod demo-emptydir -w
```

4. Read the file from the `reader` container (which never wrote it):

```
kubectl exec demo-emptydir -c reader -- cat /data/mensaje.txt
```

5. Delete the Pod and confirm that the volume disappears with it:

```
kubectl delete pod demo-emptydir
```

**Comprehension questions:**

1. Why was the `reader` container able to read a file it never wrote?
2. What happens to the data in an `emptyDir` if the Pod is deleted or rescheduled to another Node? What if only a container within the same Pod is restarted?

---

## Exercise 2 — `hostPath`: mount a Node path

1. Create a test file on the Node (if using `minikube`, enter with `minikube ssh`; if using `kind`, with `docker exec -it <node-name> sh`):

```
mkdir -p /tmp/kcna-hostpath
echo "dato del host" > /tmp/kcna-hostpath/archivo.txt
exit
```

2. Create `pod-hostpath.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-hostpath
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: host-vol
      mountPath: /host-data
  volumes:
  - name: host-vol
    hostPath:
      path: /tmp/kcna-hostpath
      type: Directory
```

3. Apply and verify the mounted content:

```
kubectl apply -f pod-hostpath.yaml
kubectl exec demo-hostpath -- cat /host-data/archivo.txt
```

4. Clean up the resource:

```
kubectl delete pod demo-hostpath
```

**Comprehension questions:**

1. What happens to this Pod if Kubernetes reschedules it to a different Node than the one that has the file at `/tmp/kcna-hostpath`?
2. Name a security risk of using `hostPath` in a multi-tenant cluster.

---

## Exercise 3 — Static PersistentVolume (PV)

1. Create `pv-demo.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-demo
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/kcna-pv-data
```

2. Apply the manifest and check its status:

```
kubectl apply -f pv-demo.yaml
kubectl get pv pv-demo
```

3. Observe the `STATUS` column: it should show `Available`.

4. Inspect the full object:

```
kubectl describe pv pv-demo
```

**Comprehension questions:**

1. A PV is a cluster-scoped resource, not Namespace-scoped. What practical implication does this have when listing PVs with `kubectl get pv -n <namespace>`?
2. What does the `accessMode` `ReadWriteOnce` (RWO) mean?

---

## Exercise 4 — PersistentVolumeClaim (PVC) and binding

1. Create `pvc-demo.yaml`, requesting less storage than the PV offers to force binding to `pv-demo`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
  storageClassName: ""
```

2. Apply the PVC and verify it became `Bound` to `pv-demo`:

```
kubectl apply -f pvc-demo.yaml
kubectl get pvc pvc-demo
kubectl get pv pv-demo
```

3. Mount the PVC in a Pod (`pod-pvc.yaml`):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pvc-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'via PVC' > /data/out.txt && sleep 3600"]
    volumeMounts:
    - name: pv-storage
      mountPath: /data
  volumes:
  - name: pv-storage
    persistentVolumeClaim:
      claimName: pvc-demo
```

4. Apply and verify that the file was written:

```
kubectl apply -f pod-pvc.yaml
kubectl exec demo-pvc-pod -- cat /data/out.txt
```

**Comprehension questions:**

1. Why was it necessary to set `storageClassName: ""` in the PVC so it would bind to `pv-demo`?
2. If two PVs existed that both met the PVC's requirements (capacity and `accessMode`), does the user choose which one to bind to?

---

## Exercise 5 — Dynamic provisioning with `StorageClass`

1. List the `StorageClass` resources available in the cluster and identify which one has the default annotation:

```
kubectl get storageclass
```

2. Create a PVC **without** manually specifying a PV, letting the default `StorageClass` provision the volume (`pvc-dynamic.yaml`):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-dynamic
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

3. Apply the manifest and watch it go from `Pending` to `Bound` without you having created a PV yourself:

```
kubectl apply -f pvc-dynamic.yaml
kubectl get pvc pvc-dynamic -w
```

4. Confirm that a new PV was automatically created:

```
kubectl get pv
```

**Comprehension questions:**

1. Which component is responsible for automatically creating the PV when the PVC references a `StorageClass`? (Think of the role of the **provisioner** / CSI driver)
2. What is the difference, from the user's workflow perspective, between the binding in Exercise 4 (static) and this exercise (dynamic)?

---

## Exercise 6 — Reclaim Policy: `Retain` vs `Delete`

1. Check the `reclaimPolicy` of the dynamically created PV from Exercise 5:

```
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

2. Delete the dynamic PVC and observe what happens to its associated PV:

```
kubectl delete pvc pvc-dynamic
kubectl get pv
```

3. Now delete the static PVC from Exercise 4 (bound to `pv-demo`, which has `persistentVolumeReclaimPolicy: Retain`) and observe the difference:

```
kubectl delete pvc pvc-demo
kubectl get pv pv-demo
```

4. Clean up the remaining resources:

```
kubectl delete pod demo-pvc-pod
kubectl delete pv pv-demo
```

**Comprehension questions:**

1. What `STATUS` did `pv-demo` show after deleting `pvc-demo`, and why wasn't the PV automatically deleted?
2. If `pv-demo` had `persistentVolumeReclaimPolicy: Delete`, what would have happened to the PV (and the underlying data on the `hostPath`) when the PVC was deleted?

---

<details>
<summary><strong>View answers</strong></summary>

**Exercise 1**

1. Because both containers in the same Pod share the same `emptyDir` volume, mounted in both as `/data`. The volume is shared at the Pod level, not isolated per container.
2. If the Pod is deleted or rescheduled to another Node, the `emptyDir` is permanently deleted (its lifecycle is tied to the Pod, not the Node). If only an individual container within the same Pod is restarted (e.g., due to a crash), the `emptyDir` survives because the Pod itself still exists.

**Exercise 2**

1. The Pod would fail to start (or be unable to read the expected file), because `hostPath` references a path on the filesystem of the Node where the Pod runs. The scheduler does not guarantee that the Pod will always land on the same Node, so the `hostPath` content does not travel with the Pod.
2. A container with access to `hostPath` can read/write directly to the underlying Node's filesystem, which can expose sensitive host files or even allow escaping container isolation if a critical path (e.g., `/`, `/etc`, or the Docker socket) is mounted.

**Exercise 3**

1. A PV does not belong to any Namespace: it appears in `kubectl get pv` regardless of the `-n` flag, and any PVC from any Namespace (subject to `accessModes` and `storageClassName`) can potentially bind to it.
2. `ReadWriteOnce` means the volume can be mounted in read-write mode by Pods on a single Node at a time (from Kubernetes 1.22+ it technically allows multiple Pods on that same Node). It does not imply that only one Pod can use it, but it is limited to one Node.

**Exercise 4**

1. Because the PV `pv-demo` has no `storageClassName` defined (it defaults to `""`). If the PVC does not also specify `storageClassName: ""`, Kubernetes would use the cluster's default `StorageClass` (if it exists) and trigger dynamic provisioning instead of binding to the existing static PV.
2. No. The binding is resolved by the Kubernetes control plane (the PersistentVolume controller), not the user. It automatically binds to the available PV that best meets the criteria (sufficient minimum capacity, compatible `accessModes`, matching `storageClassName`), not necessarily the smallest one.

**Exercise 5**

1. The **provisioner** associated with the `StorageClass` (e.g., a **CSI – Container Storage Interface** driver) is responsible for creating the actual storage volume and the corresponding PV object. The `StorageClass` only defines *which* provisioner to use and with what parameters.
2. In the static flow, a cluster administrator creates the PV manually in advance; the PVC only binds to an already existing PV. In the dynamic flow, the user only creates the PVC, and the PV is created automatically "on demand" at the moment the PVC requests it – no pre-existing PV is required.

**Exercise 6**

1. The PV changed to `STATUS: Released` (not `Available` nor deleted). It is not automatically deleted because its `persistentVolumeReclaimPolicy` is `Retain`, a policy designed to preserve data and require manual administrator intervention before reusing or releasing the volume.
2. With `Delete`, when the PVC was deleted, Kubernetes would have automatically deleted both the PV object and the underlying storage (in this case, the `hostPath` directory), without requiring manual cleanup. `Delete` is the default policy for many dynamic provisioners, while `Retain` prioritizes not losing data accidentally.

</details>