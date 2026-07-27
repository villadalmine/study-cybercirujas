# Guided Exercises: Manage persistent volumes and persistent volume claims (CKA 1.3)

> Reference Source: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

## Exercise 1 — Create a Static PersistentVolume with `hostPath`

1. Create a working namespace for exercises:
   ```bash
   kubectl create namespace storage-lab
   ```
2. On the target node hosting the Pod (or inside a single-node VM/minikube environment), create the underlying backing storage directory:
   ```bash
   mkdir -p /mnt/data-lab
   echo "Hello from PersistentVolume" > /mnt/data-lab/index.html
   ```
3. Create file `pv-hostpath.yaml`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: pv-lab-01
   spec:
     capacity:
       storage: 1Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     storageClassName: manual
     hostPath:
       path: /mnt/data-lab
   ```
4. Apply manifest and inspect PV status:
   ```bash
   kubectl apply -f pv-hostpath.yaml
   kubectl get pv pv-lab-01
   ```

**Comprehension Questions**

1. Which `STATUS` should `pv-lab-01` display immediately after creation, and why?
2. What practical distinction exists between `persistentVolumeReclaimPolicy: Retain` vs `Delete` on `hostPath` backed PVs?

---

## Exercise 2 — Create PersistentVolumeClaim and Verify Binding

1. Create file `pvc-lab.yaml` inside `storage-lab` namespace:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-lab-01
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: manual
     resources:
       requests:
         storage: 500Mi
   ```
2. Apply PVC:
   ```bash
   kubectl apply -f pvc-lab.yaml
   ```
3. Observe binding status between PVC and PV:
   ```bash
   kubectl get pvc pvc-lab-01 -n storage-lab
   kubectl get pv pv-lab-01
   ```
4. Inspect PVC `spec.volumeName` and PV `spec.claimRef` to confirm 1:1 binding relationship:
   ```bash
   kubectl get pvc pvc-lab-01 -n storage-lab -o jsonpath='{.spec.volumeName}{"\n"}'
   kubectl get pv pv-lab-01 -o jsonpath='{.spec.claimRef.name}{"\n"}'
   ```

**Comprehension Questions**

1. The PVC requests `500Mi` while PV supplies `1Gi`. Why does binding succeed, and what capacity remains available for other PVCs?
2. What would occur if PVC requested `storageClassName: manual` with `accessModes: ReadWriteMany`?

---

## Exercise 3 — Mount PVC into a Pod and Verify Data Persistence

1. Create file `pod-consumer.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-lab-01
     namespace: storage-lab
   spec:
     containers:
       - name: web
         image: nginx:1.27
         volumeMounts:
           - name: data
             mountPath: /usr/share/nginx/html
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: pvc-lab-01
   ```
2. Apply manifest and wait for `Running` state:
   ```bash
   kubectl apply -f pod-consumer.yaml
   kubectl wait --for=condition=Ready pod/pod-lab-01 -n storage-lab --timeout=60s
   ```
3. Confirm `hostPath` contents are readable inside container:
   ```bash
   kubectl exec -n storage-lab pod-lab-01 -- cat /usr/share/nginx/html/index.html
   ```
4. Delete and recreate the Pod, verifying file persistence across Pod lifecycles:
   ```bash
   kubectl delete pod pod-lab-01 -n storage-lab
   kubectl apply -f pod-consumer.yaml
   kubectl exec -n storage-lab pod-lab-01 -- cat /usr/share/nginx/html/index.html
   ```

**Comprehension Questions**

1. If you delete the PVC while the Pod remains active, what behavior occurs?
2. Why does data persist across Pod recreations under `persistentVolumeClaim` whereas `emptyDir` volumes lose data?

---

## Exercise 4 — Reclaim Policy: Releasing and Recycling PVs

1. Delete active PVC (preserving PV due to `Retain` reclaim policy):
   ```bash
   kubectl delete pod pod-lab-01 -n storage-lab
   kubectl delete pvc pvc-lab-01 -n storage-lab
   ```
2. Verify PV status:
   ```bash
   kubectl get pv pv-lab-01
   ```
3. A `Released` PV cannot automatically rebind. Clear `claimRef` to release it manually:
   ```bash
   kubectl patch pv pv-lab-01 -p '{"spec":{"claimRef": null}}'
   kubectl get pv pv-lab-01
   ```
4. Re-apply PVC from Exercise 2 and verify re-binding to `pv-lab-01`:
   ```bash
   kubectl apply -f pvc-lab.yaml
   kubectl get pvc pvc-lab-01 -n storage-lab
   ```

**Comprehension Questions**

1. Which `STATUS` does a PV enter between PVC deletion and manual `claimRef` removal?
2. In production environments, what security risk accompanies reusing released storage without wiping residual data first?

---

## Exercise 5 — Dynamic Provisioning with StorageClass

1. List cluster StorageClasses and identify default class:
   ```bash
   kubectl get storageclass
   ```
2. Create custom StorageClass (adjust `provisioner` matching your environment driver, e.g. `rancher.io/local-path`):
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: sc-lab-fast
   provisioner: rancher.io/local-path
   reclaimPolicy: Delete
   volumeBindingMode: WaitForFirstConsumer
   allowVolumeExpansion: true
   ```
   ```bash
   kubectl apply -f sc-lab-fast.yaml
   ```
3. Create PVC referencing this StorageClass without manual PV pre-allocation:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-dynamic
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: sc-lab-fast
     resources:
       requests:
         storage: 1Gi
   ```
   ```bash
   kubectl apply -f pvc-dynamic.yaml
   kubectl get pvc pvc-dynamic -n storage-lab
   ```
4. With `volumeBindingMode: WaitForFirstConsumer`, PVC remains `Pending` until consumed by a Pod. Run consumer Pod and verify binding:
   ```bash
   kubectl run pod-dynamic --image=nginx:1.27 -n storage-lab \
     --overrides='{"spec":{"containers":[{"name":"pod-dynamic","image":"nginx:1.27","volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"pvc-dynamic"}}]}}'
   kubectl get pvc pvc-dynamic -n storage-lab
   kubectl get pv
   ```

**Comprehension Questions**

1. How does `volumeBindingMode: Immediate` differ from `WaitForFirstConsumer` regarding volume allocation timing?
2. With `reclaimPolicy: Delete`, what happens to PV and storage assets upon `pvc-dynamic` deletion?

---

## Exercise 6 — PVC Capacity Expansion (Volume Expansion)

1. Verify StorageClass permits volume expansion:
   ```bash
   kubectl get storageclass sc-lab-fast -o jsonpath='{.allowVolumeExpansion}{"\n"}'
   ```
2. Increase requested PVC storage capacity:
   ```bash
   kubectl patch pvc pvc-dynamic -n storage-lab -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
   ```
3. Monitor expansion progress:
   ```bash
   kubectl get pvc pvc-dynamic -n storage-lab
   kubectl describe pvc pvc-dynamic -n storage-lab
   ```
4. If filesystem resize requires running container access, verify consumer Pod is active:
   ```bash
   kubectl get pod pod-dynamic -n storage-lab
   ```

**Comprehension Questions**

1. Why does setting `allowVolumeExpansion: false` cause capacity patch attempts to fail or be ignored?
2. Is shrinking requested PVC capacity supported? Explain.

---

## Exercise 7 — StatefulSets with `volumeClaimTemplates`

1. Create `statefulset-lab.yaml`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: svc-lab
     namespace: storage-lab
   spec:
     clusterIP: None
     selector:
       app: sts-lab
     ports:
       - port: 80
   ---
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: sts-lab
     namespace: storage-lab
   spec:
     serviceName: svc-lab
     replicas: 3
     selector:
       matchLabels:
         app: sts-lab
     template:
       metadata:
         labels:
           app: sts-lab
       spec:
         containers:
           - name: web
             image: nginx:1.27
             volumeMounts:
               - name: www
                 mountPath: /usr/share/nginx/html
     volumeClaimTemplates:
       - metadata:
           name: www
         spec:
           accessModes: ["ReadWriteOnce"]
           storageClassName: sc-lab-fast
           resources:
             requests:
               storage: 500Mi
   ```
2. Apply manifest and observe parallel Pod/PVC creation:
   ```bash
   kubectl apply -f statefulset-lab.yaml
   kubectl get pods -n storage-lab -l app=sts-lab
   kubectl get pvc -n storage-lab
   ```
3. Inspect generated PVC naming patterns:
   ```bash
   kubectl get pvc -n storage-lab -o custom-columns=NAME:.metadata.name,POD:.metadata.labels
   ```
4. Delete StatefulSet and confirm generated PVCs are **not** deleted automatically:
   ```bash
   kubectl delete statefulset sts-lab -n storage-lab
   kubectl get pvc -n storage-lab
   ```

**Comprehension Questions**

1. Why does each StatefulSet replica receive an independent PVC rather than sharing a single volume like Deployments?
2. If scaling `sts-lab` from 3 to 1 replica and back to 3, does replica `sts-lab-2` rebind to its original PVC or a newly generated PVC?

---

## Exercise 8 — Troubleshooting: PVC Stuck in `Pending`

1. Create a PVC referencing a non-existent StorageClass:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-broken
     namespace: storage-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: sc-no-existe
     resources:
       requests:
         storage: 1Gi
   ```
   ```bash
   kubectl apply -f pvc-broken.yaml
   kubectl get pvc pvc-broken -n storage-lab
   ```
2. Diagnose root cause via `describe`:
   ```bash
   kubectl describe pvc pvc-broken -n storage-lab
   ```
3. Re-create PVC specifying valid StorageClass and verify binding:
   ```bash
   kubectl delete pvc pvc-broken -n storage-lab
   kubectl apply -f pvc-broken.yaml   # updating storageClassName to sc-lab-fast
   kubectl get pvc pvc-broken -n storage-lab
   ```

**Comprehension Questions**

1. List two common reasons besides missing StorageClasses causing PVCs to remain in `Pending` state.
2. Which command retrieves recent cluster events across `storage-lab` namespace in chronological order?

---

## Teardown

```bash
kubectl delete namespace storage-lab
kubectl delete pv pv-lab-01
kubectl delete storageclass sc-lab-fast
```

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
1. Displays `Available` status because no PVC currently claims it (`claimRef` is empty).
2. Under `Retain`, PVC deletion leaves PV in `Released` status with data intact until manual administrator intervention. `Delete` automatically purges PV and backend physical storage assets.

**Exercise 2**
1. Binding succeeds because `1Gi >= 500Mi` requested capacity, access modes match, and storage class matches. The entire 1Gi PV binds to the PVC; PV assets cannot be sliced across multiple PVCs.
2. Binding fails because PVC requested `ReadWriteMany` which PV does not supply. PVC remains `Pending`.

**Exercise 3**
1. PVC deletion hangs with `kubernetes.io/pvc-protection` finalizer active while actively mounted by running Pods. Deletion finishes when consuming Pod terminates.
2. `hostPath` points to fixed host node filesystem paths persisting across Pod restarts; `emptyDir` volumes bind directly to individual Pod lifecycles.

**Exercise 4**
1. PV enters `Released` status.
2. Subsequent workloads claiming uncleared storage can read residual data from prior tenants (data leakage security risk).

**Exercise 5**
1. `Immediate` provisions volume assets upon PVC creation. `WaitForFirstConsumer` delays volume provisioning until Pod node scheduling completes.
2. PV and underlying physical cloud storage assets are automatically deleted alongside stored data.

**Exercise 6**
1. `allowVolumeExpansion: false` causes API server to reject capacity expansion patches.
2. Shrinking PVC capacity is unsupported. Reducing requested storage requires creating smaller PVCs and migrating data manually.

**Exercise 7**
1. StatefulSets provide stable network identities and independent storage states per ordinal index replica.
2. Re-scaling upward rebinds `sts-lab-2` to its original deterministic PVC (`www-sts-lab-2`) preserving state.

**Exercise 8**
1. (a) Inactive CSI driver pods; (b) insufficient backend storage capacity / accessMode mismatches; (c) `WaitForFirstConsumer` waiting for un-scheduled Pods.
2. `kubectl get events -n storage-lab --sort-by=.lastTimestamp`

</details>
