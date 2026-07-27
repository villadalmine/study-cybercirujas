# Guided Exercises — CKA 1.2: Configure volume types, access modes and reclaim policies

> Exam Weight: 3.33%
> Reference Source: [CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)
> Prerequisites: A working cluster with at least 1 worker node (kind, minikube, or similar) and `kubectl` configured.

---

## Exercise 1 — `emptyDir`: Ephemeral Shared Volume Between Containers

1. Create a working namespace:

   ```bash
   kubectl create namespace vol-lab
   ```

2. Create `emptydir-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: emptydir-demo
     namespace: vol-lab
   spec:
     containers:
     - name: writer
       image: busybox
       command: ["sh", "-c", "echo hello from writer > /data/msg.txt && sleep 3600"]
       volumeMounts:
       - name: shared
         mountPath: /data
     - name: reader
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: shared
         mountPath: /data
     volumes:
     - name: shared
       emptyDir: {}
   ```

3. Apply manifest and wait for `Running` state:

   ```bash
   kubectl apply -f emptydir-pod.yaml
   kubectl wait --for=condition=Ready pod/emptydir-demo -n vol-lab --timeout=60s
   ```

4. Verify `reader` container can read file written by `writer`:

   ```bash
   kubectl exec -n vol-lab emptydir-demo -c reader -- cat /data/msg.txt
   ```

5. Delete Pod and confirm volume data vanishes with it:

   ```bash
   kubectl delete pod emptydir-demo -n vol-lab
   ```

**Comprehension Questions**

- What happens to `emptyDir` data if a container inside the Pod crashes and restarts rather than deleting the entire Pod?
- Which field in `spec.volumes[].emptyDir` configures RAM storage (`tmpfs`) instead of disk storage, and how does that affect persistence?

---

## Exercise 2 — `hostPath`: Direct Access to Host Node Filesystem

1. Identify node assigned for scheduling:

   ```bash
   kubectl get nodes
   ```

2. Create `hostpath-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hostpath-demo
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: host-data
         mountPath: /hostdata
     volumes:
     - name: host-data
       hostPath:
         path: /tmp/vol-lab-data
         type: DirectoryOrCreate
   ```

3. Apply manifest and verify `Running` state:

   ```bash
   kubectl apply -f hostpath-pod.yaml
   kubectl wait --for=condition=Ready pod/hostpath-demo -n vol-lab --timeout=60s
   ```

4. Write a file inside container and verify existence on host node filesystem (in kind use `docker exec` into node container; in minikube use `minikube ssh`):

   ```bash
   kubectl exec -n vol-lab hostpath-demo -- sh -c "echo test > /hostdata/archivo.txt"
   ```

5. Compare `type: DirectoryOrCreate` against `type: Directory` for comprehension.

**Comprehension Questions**

- If a Pod using `hostPath` is rescheduled onto another node, what happens to data written in step 4?
- What practical difference exists between `type: Directory` vs `type: DirectoryOrCreate` if target path does not exist yet on node?

---

## Exercise 3 — Static PersistentVolume, PersistentVolumeClaim, and Access Modes

1. Create a `PersistentVolume` backed by `hostPath` specifying `accessModes: ReadWriteOnce` in `pv-demo.yaml`:

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
     storageClassName: manual
     hostPath:
       path: /tmp/pv-demo-data
   ```

2. Create `PersistentVolumeClaim` claiming that PV in `pvc-demo.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-demo
     namespace: vol-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: manual
     resources:
       requests:
         storage: 500Mi
   ```

3. Apply manifests in sequence and inspect object `STATUS`:

   ```bash
   kubectl apply -f pv-demo.yaml
   kubectl apply -f pvc-demo.yaml
   kubectl get pv pv-demo
   kubectl get pvc pvc-demo -n vol-lab
   ```

4. Confirm 1:1 binding between PV and PVC by inspecting PV `spec.claimRef`:

   ```bash
   kubectl get pv pv-demo -o jsonpath='{.spec.claimRef.name}{"\n"}'
   ```

5. Mount PVC into a Pod in `pvc-pod.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-consumer
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-demo
   ```

   ```bash
   kubectl apply -f pvc-pod.yaml
   kubectl wait --for=condition=Ready pod/pvc-consumer -n vol-lab --timeout=60s
   ```

**Comprehension Questions**

- If PVC requests `storage: 500Mi` but matching available PV has `capacity: 1Gi`, does binding succeed? Is PVC restricted to requested 500Mi or full 1Gi capacity?
- Why can a second PVC in another namespace not claim `pv-demo` even if PV specifies `accessModes: ReadWriteOnce` and has unused capacity?
- Which access mode allows multiple Pods across different nodes to write to the same volume concurrently, and what backend types typically support it?

---

## Exercise 4 — Reclaim Policies: `Retain` vs `Delete`

1. Confirm current PV reclaim policy:

   ```bash
   kubectl get pv pv-demo -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

2. Delete consuming Pod and PVC:

   ```bash
   kubectl delete pod pvc-consumer -n vol-lab
   kubectl delete pvc pvc-demo -n vol-lab
   ```

3. Inspect PV status following PVC deletion:

   ```bash
   kubectl get pv pv-demo
   ```

4. Note new `Released` status and verify data in `/tmp/pv-demo-data` on host node **remains intact**. Clear `claimRef` to make PV reusable:

   ```bash
   kubectl patch pv pv-demo --type=json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
   kubectl get pv pv-demo
   ```

5. Create a second PV specifying `persistentVolumeReclaimPolicy: Delete` in `pv-delete.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: pv-delete-demo
   spec:
     capacity:
       storage: 1Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Delete
     storageClassName: manual-delete
     hostPath:
       path: /tmp/pv-delete-demo-data
   ```

   Apply it, create a matching PVC, then delete PVC and observe PV behavior.

**Comprehension Questions**

- Under `persistentVolumeReclaimPolicy: Retain`, what status does a PV enter after PVC deletion, and what manual actions enable reuse?
- On `hostPath` volumes, why might `Delete` policy not automatically wipe host directory files compared to cloud CSI provisioners?
- What did deprecated `Recycle` policy perform, and what mechanism replaced it in modern clusters?

---

## Exercise 5 — Dynamic Provisioning with `StorageClass`

1. List cluster `StorageClass` objects:

   ```bash
   kubectl get storageclass
   ```

2. Inspect reclaim policies and provisioners:

   ```bash
   kubectl get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIMPOLICY:.reclaimPolicy,BINDINGMODE:.volumeBindingMode
   ```

3. Create `pvc-dynamic.yaml` leveraging default `StorageClass`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-dynamic
     namespace: vol-lab
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   ```

4. Apply and observe auto-provisioned PV creation:

   ```bash
   kubectl apply -f pvc-dynamic.yaml
   kubectl get pvc pvc-dynamic -n vol-lab
   kubectl get pv
   ```

5. Identify auto-provisioned PV and confirm inherited `persistentVolumeReclaimPolicy`:

   ```bash
   PV_NAME=$(kubectl get pvc pvc-dynamic -n vol-lab -o jsonpath='{.spec.volumeName}')
   kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
   ```

**Comprehension Questions**

- Which `StorageClass` field controls whether PV binding triggers immediately (`Immediate`) vs delaying until Pod scheduling (`WaitForFirstConsumer`), and why is this critical in multi-zone clusters?
- If deleting `pvc-dynamic` on a `StorageClass` specifying `reclaimPolicy: Delete`, how does behavior differ from manual `Retain` PVs?
- How is a `StorageClass` designated as default via annotations, and what happens if two classes set this annotation to `true`?

---

## Exercise 6 — Access Modes: `ReadWriteOnce` vs `ReadWriteOncePod`

1. Explain access mode parameters:

   ```bash
   kubectl explain pvc.spec.accessModes
   ```

2. Mount `pvc-dynamic` simultaneously across two Pods in `two-consumers.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer-a
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-dynamic
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: consumer-b
     namespace: vol-lab
   spec:
     containers:
     - name: app
       image: busybox
       command: ["sh", "-c", "sleep 3600"]
       volumeMounts:
       - name: data
         mountPath: /data
     volumes:
     - name: data
       persistentVolumeClaim:
         claimName: pvc-dynamic
   ```

3. Apply and inspect Pod statuses:

   ```bash
   kubectl apply -f two-consumers.yaml
   kubectl get pods -n vol-lab -o wide
   ```

4. If both Pods land on the same node, both reach `Running` (`ReadWriteOnce` permits multiple Pods on the **same node**). Verify node placement:

   ```bash
   kubectl get pod consumer-a consumer-b -n vol-lab -o jsonpath='{.items[*].spec.nodeName}{"\n"}'
   ```

5. Teardown namespace resources:

   ```bash
   kubectl delete namespace vol-lab
   ```

**Comprehension Questions**

- What exact distinction separates `ReadWriteOnce` (RWO) vs `ReadWriteOncePod` (RWOP)?
- On multi-node clusters, if two Pods sharing an RWO PVC are scheduled on separate nodes, what happens to the second Pod?
- Which access mode fits a PVC mounted by multiple read-only Deployment replicas (e.g., static web assets)?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — `emptyDir`

- If a container crashes and restarts within the Pod, `emptyDir` **data persists** — volumes bind to Pod lifecycles rather than container lifecycles. Data vanishes only when the Pod object itself is deleted or rescheduled.
- Configured via `spec.volumes[].emptyDir.medium: Memory`. Uses RAM-backed `tmpfs`, offering higher performance while consuming Pod memory limits. Data disappears on host reboot.

### Exercise 2 — `hostPath`

- Data remains on the original host node and **does not travel with Pods**. Rescheduled Pods on new nodes view empty host paths because `hostPath` mounts node-local filesystems.
- `type: Directory` requires the directory to **exist prior to mounting**; missing paths fail Pod startup. `type: DirectoryOrCreate` creates missing host directories (`0755` permissions) automatically.

### Exercise 3 — Static PV/PVC and Access Modes

- Binding succeeds: Kubernetes binds PVCs to the **first matching PV meeting or exceeding** capacity and access mode criteria. PVC gets bound to full 1Gi PV capacity (requests act as minimum thresholds, not upper caps).
- PV-to-PVC binding is exclusive 1:1 cluster-wide: once a PV references a `claimRef`, no other PVC can bind to it until released. `accessModes: ReadWriteOnce` defines concurrent node mounting capabilities, not multi-PVC binding capabilities.
- `ReadWriteMany` (RWX) handles multi-node concurrent write access. Backends include NFS, CephFS, EFS, or Azure Files. Block storage (EBS, GCE PD) supports RWO only.

### Exercise 4 — Reclaim Policies

- Under `Retain`, deleting PVC transitions PV to `Released` status: data remains intact, but PV cannot rebind to new PVCs until administrators manually clear `spec.claimRef`.
- `hostPath` lacks automated CSI cleanup drivers on local filesystems, so `Delete` behavior on host paths depends on local provisioners. Cloud CSI drivers (`Delete`) issue API calls removing physical cloud storage assets upon PVC deletion.
- Deprecated `Recycle` executed `rm -rf` file cleanup. Replaced by dynamic provisioning via `StorageClass`.

### Exercise 5 — StorageClass and Dynamic Provisioning

- `volumeBindingMode`: `WaitForFirstConsumer` delays binding/provisioning until Pod scheduling succeeds, preventing zone placement mismatches in multi-zone clusters.
- `Delete` automatically removes provisioned PV objects and backend cloud storage upon PVC deletion, requiring zero manual cleanup compared to `Retain`.
- Set annotation `storageclass.kubernetes.io/is-default-class: "true"`. If multiple classes set default annotations, `DefaultStorageClass` selects the most recently created class timestamp while emitting warnings.

### Exercise 6 — Access Modes

- `ReadWriteOnce` allows multiple Pods on the **same node** to mount storage read-write. `ReadWriteOncePod` restricts mounting to a **single Pod cluster-wide**.
- The second Pod on a separate node stays in `Pending` state: `kube-scheduler` blocks scheduling due to single-node RWO mount constraints.
- `ReadOnlyMany` (ROX) permits concurrent read-only mounts across multiple nodes simultaneously.

</details>
