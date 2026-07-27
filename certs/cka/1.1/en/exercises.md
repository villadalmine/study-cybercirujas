# CKA 1.35 — Topic 1.1: Implement storage classes and dynamic volume provisioning

**Exam Weight:** 3.33%
**Reference Source:** [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

> Prerequisites: A working cluster with configured `kubectl` and at least one active dynamic provisioner (e.g. `rancher.io/local-path` in `kind`, `k8s.io/minikube-hostpath` in `minikube`, or your cloud provider CSI driver). If your cluster lacks default provisioners, Exercises 2 through 6 operate identically by substituting `provisioner` with any available driver name in your environment.

---

## Exercise 1 — Inspect Existing StorageClasses

1. List available `StorageClass` objects in the cluster:
   ```bash
   kubectl get storageclass
   ```
2. Note which class carries the `(default)` annotation next to its name. If missing, no default `StorageClass` is set.
3. Describe the class to inspect provisioner and parameters:
   ```bash
   kubectl describe storageclass <name>
   ```
4. Output the full YAML manifest to inspect fields unexposed by `describe` (`volumeBindingMode`, `allowVolumeExpansion`):
   ```bash
   kubectl get storageclass <name> -o yaml
   ```

**Comprehension Questions — Exercise 1**
- Q1.1: Which manifest field determines which cluster component (in-tree plugin or CSI driver) dynamic provisions the physical volume?
- Q1.2: Which annotation designates a `StorageClass` as the cluster default, and what happens if two classes carry `"true"` simultaneously?

---

## Exercise 2 — Create a Custom StorageClass

1. Create file `sc-wffc.yaml` (adjust `provisioner` matching your cluster environment):
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast-retain
   provisioner: rancher.io/local-path
   reclaimPolicy: Retain
   volumeBindingMode: WaitForFirstConsumer
   allowVolumeExpansion: true
   ```
2. Apply manifest:
   ```bash
   kubectl apply -f sc-wffc.yaml
   ```
3. Confirm creation and inspect status:
   ```bash
   kubectl get storageclass fast-retain
   ```

**Comprehension Questions — Exercise 2**
- Q2.1: How does `volumeBindingMode: WaitForFirstConsumer` alter `PersistentVolume` creation timing compared to default `Immediate` mode?
- Q2.2: Can the `provisioner` field of an existing `StorageClass` be updated via `kubectl edit`? Why or why not?

---

## Exercise 3 — Dynamic Provisioning via PVC

1. Create a `PersistentVolumeClaim` consuming `fast-retain` in file `pvc-app.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-app
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: fast-retain
     resources:
       requests:
         storage: 1Gi
   ```
2. Apply and inspect status immediately:
   ```bash
   kubectl apply -f pvc-app.yaml
   kubectl get pvc pvc-app
   ```
3. Check if a bound `PersistentVolume` exists yet:
   ```bash
   kubectl get pv
   ```
4. Create a Pod consuming the PVC in `pod-app.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-app
   spec:
     containers:
       - name: app
         image: busybox
         command: ["sleep", "3600"]
         volumeMounts:
           - name: data
             mountPath: /data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: pvc-app
   ```
5. Apply and inspect PVC, PV, and Pod status:
   ```bash
   kubectl apply -f pod-app.yaml
   kubectl get pvc pvc-app
   kubectl get pv
   kubectl get pod pod-app
   ```

**Comprehension Questions — Exercise 3**
- Q3.1: Right after step 2, which `STATUS` do you expect on the PVC, and why is it not `Bound` yet?
- Q3.2: At what exact moment is dynamic `PersistentVolume` provisioning triggered under `volumeBindingMode: WaitForFirstConsumer`?

---

## Exercise 4 — Reclaim Policy: Retain vs Delete

1. Note the auto-generated `PersistentVolume` name bound to `pvc-app`:
   ```bash
   kubectl get pvc pvc-app -o jsonpath='{.spec.volumeName}'
   ```
2. Delete both Pod and PVC:
   ```bash
   kubectl delete pod pod-app
   kubectl delete pvc pvc-app
   ```
3. Inspect `PersistentVolume` status noted in step 1:
   ```bash
   kubectl get pv
   ```
4. Compare: create a second `StorageClass` identical except for `reclaimPolicy: Delete` named `fast-delete`. Repeat steps 1 through 3 using a new PVC (`pvc-app2`) targeting `fast-delete`, observing final PV status differences.

**Comprehension Questions — Exercise 4**
- Q4.1: Under `reclaimPolicy: Retain`, which `STATUS` does the `PersistentVolume` enter after deleting the PVC, and what manual steps allow reusing that storage for a new PVC?
- Q4.2: Does modifying a `StorageClass` `reclaimPolicy` via `kubectl edit` update existing provisioned `PersistentVolumes` retroactively?

---

## Exercise 5 — Volume Expansion (allowVolumeExpansion)

1. With `pvc-app` existing (or recreated) using `fast-retain` (`allowVolumeExpansion: true`), request increased capacity:
   ```bash
   kubectl patch pvc pvc-app -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   ```
2. Observe expansion status:
   ```bash
   kubectl get pvc pvc-app -o jsonpath='{.status.capacity.storage}{"\n"}'
   kubectl describe pvc pvc-app
   ```
3. Attempt the same patch on a PVC using a `StorageClass` with `allowVolumeExpansion: false` (or omitted), noting error output.

**Comprehension Questions — Exercise 5**
- Q5.1: Is shrinking PVC capacity supported via `allowVolumeExpansion`?
- Q5.2: What condition appears in `kubectl describe pvc` when filesystem expansion on the host node is pending (`FileSystemResizePending`), and when does filesystem resize trigger?

---

## Exercise 6 — Changing Default StorageClass

1. List `StorageClass` objects and note current default:
   ```bash
   kubectl get storageclass
   ```
2. Remove default annotation from current class (replace `<current-default>`):
   ```bash
   kubectl patch storageclass <current-default> -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
   ```
3. Mark `fast-retain` as new default:
   ```bash
   kubectl patch storageclass fast-retain -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
   ```
4. Confirm updated default status:
   ```bash
   kubectl get storageclass
   ```
5. Create a PVC omitting `storageClassName` and verify assigned class:
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-default-test
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   EOF
   kubectl get pvc pvc-default-test -o jsonpath='{.spec.storageClassName}{"\n"}'
   ```

**Comprehension Questions — Exercise 6**
- Q6.1: If a PVC omits `storageClassName` and no cluster default `StorageClass` exists, what happens to the PVC?
- Q6.2: What is the difference between omitting `storageClassName` vs setting an explicit empty string (`storageClassName: ""`)?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.1:** The `provisioner` field. Identifies the plugin responsible for dynamic physical volume allocation (in-tree legacy `kubernetes.io/...` vs out-of-tree CSI drivers like `ebs.csi.aws.com` or `rancher.io/local-path`).

**Q1.2:** Annotation `storageclass.kubernetes.io/is-default-class: "true"`. If multiple classes set this annotation to `"true"`, behavior becomes ambiguous: `DefaultStorageClass` admission plugin selects the most recently created class by timestamp. Best practice dictates maintaining a single default class.

**Q2.1:** `Immediate` provisions physical storage as soon as the PVC is created without considering Pod scheduling constraints. `WaitForFirstConsumer` delays binding and provisioning until a consuming Pod is scheduled, ensuring storage is allocated in matching availability zones/topologies.

**Q2.2:** No. `provisioner` is an immutable field post-creation. `kubectl edit` modifications on immutable fields are rejected by the API server. Creating a new `StorageClass` is required.

**Q3.1:** PVC status is `Pending`. `WaitForFirstConsumer` delays PV allocation and binding until a consuming Pod is scheduled to a specific node.

**Q3.2:** Dynamic provisioning triggers when `kube-scheduler` assigns (binds) the consuming Pod to a node. The volume controller allocates matching storage for that node topology, transitioning PVC to `Bound`.

**Q4.1:** PV enters `Released` status. Storage retains data but cannot be automatically rebound. Manual reuse requires: (1) deleting `spec.claimRef` from PV manifest to reset status to `Available`, and (2) manually clearing data before binding a new PVC.

**Q4.2:** No. `StorageClass` `reclaimPolicy` supplies default values for newly provisioned PVs. Existing PVs retain their initial `persistentVolumeReclaimPolicy`. Modifying existing PVs requires patching `spec.persistentVolumeReclaimPolicy` directly on PV objects.

**Q5.1:** No. `allowVolumeExpansion` permits only capacity increases. Decreasing requested storage returns API server validation errors.

**Q5.2:** `FileSystemResizePending` condition indicates physical storage expanded at cloud provider layer, but filesystem expansion on host node remains pending. Kubelet executes filesystem expansion when volume mounts to a running container.

**Q6.1:** PVC remains in `Pending` status indefinitely until manually bound to a pre-provisioned static `PersistentVolume`.

**Q6.2:** Omitting `storageClassName` allows `DefaultStorageClass` admission controller to assign the default `StorageClass`. Setting `storageClassName: ""` explicitly disables default class assignment, restricting binding exclusively to static `PersistentVolumes` matching empty storage class.

</details>
