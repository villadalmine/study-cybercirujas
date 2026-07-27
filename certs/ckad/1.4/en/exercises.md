# CKAD 1.4 — Utilize Persistent and Ephemeral Volumes

*Reference: CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf*

Assumes a running cluster with `kubectl` configured (a local `kind` cluster works fine) and a namespace `volumes-demo`:

```bash
kubectl create namespace volumes-demo
kubectl config set-context --current --namespace=volumes-demo
```

---

## Exercise 1 — Share data between containers with `emptyDir`

1. Save the following as `emptydir-sidecar.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: emptydir-demo
   spec:
     volumes:
       - name: shared-data
         emptyDir: {}
     containers:
       - name: writer
         image: busybox:1.36
         command: ["sh", "-c", "while true; do date >> /data/log.txt; sleep 5; done"]
         volumeMounts:
           - name: shared-data
             mountPath: /data
       - name: reader
         image: busybox:1.36
         command: ["sh", "-c", "tail -f /data/log.txt"]
         volumeMounts:
           - name: shared-data
             mountPath: /data
   ```

2. Apply it and wait for the Pod to be `Running`:

   ```bash
   kubectl apply -f emptydir-sidecar.yaml
   kubectl get pod emptydir-demo -w
   ```

3. Stream the `reader` container's logs and confirm it prints timestamps written by `writer`:

   ```bash
   kubectl logs -f emptydir-demo -c reader
   ```

4. Confirm both containers see the exact same inode by comparing checksums:

   ```bash
   kubectl exec emptydir-demo -c writer -- md5sum /data/log.txt
   kubectl exec emptydir-demo -c reader -- md5sum /data/log.txt
   ```

5. Delete the Pod and confirm the volume is gone with it:

   ```bash
   kubectl delete pod emptydir-demo
   ```

**Check your understanding**
- Q1.1: What happens to the contents of `/data` once the Pod is deleted?
- Q1.2: Why do both containers see the same file even though they run as separate processes in separate containers?

---

## Exercise 2 — `emptyDir` backed by memory (tmpfs)

1. Save as `emptydir-memory.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: emptydir-memory-demo
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         resources:
           limits:
             memory: "128Mi"
         volumeMounts:
           - name: cache
             mountPath: /cache
     volumes:
       - name: cache
         emptyDir:
           medium: Memory
           sizeLimit: 64Mi
   ```

2. Apply and check the mount type from inside the container:

   ```bash
   kubectl apply -f emptydir-memory.yaml
   kubectl exec emptydir-memory-demo -- df -h /cache
   ```

3. Try to exceed `sizeLimit` and observe the failure:

   ```bash
   kubectl exec emptydir-memory-demo -- dd if=/dev/zero of=/cache/bigfile bs=1M count=100
   ```

4. Clean up:

   ```bash
   kubectl delete pod emptydir-memory-demo
   ```

**Check your understanding**
- Q2.1: What storage medium backs an `emptyDir` volume when `medium` is left unset?
- Q2.2: Why does memory-backed `emptyDir` usage count against the container's memory limit?

---

## Exercise 3 — Static provisioning with `PersistentVolume` and `PersistentVolumeClaim`

1. If you're on `kind`, create a directory on the node container to back the `hostPath` volume:

   ```bash
   docker exec "$(kind get nodes)" mkdir -p /mnt/pv-data
   ```

2. Save as `pv-manual.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: pv-manual
   spec:
     capacity:
       storage: 5Gi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     storageClassName: manual
     hostPath:
       path: /mnt/pv-data
   ```

3. Apply it and confirm it's `Available`:

   ```bash
   kubectl apply -f pv-manual.yaml
   kubectl get pv pv-manual
   ```

4. Save as `pvc-manual.yaml`:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-manual
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: manual
     resources:
       requests:
         storage: 1Gi
   ```

5. Apply it and verify it binds to `pv-manual`:

   ```bash
   kubectl apply -f pvc-manual.yaml
   kubectl get pvc pvc-manual
   kubectl get pv pv-manual
   ```

6. Mount the claim in a Pod and write data:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-writer
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "echo hello-pvc > /usr/share/data/greeting.txt && sleep 3600"]
         volumeMounts:
           - name: data
             mountPath: /usr/share/data
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: pvc-manual
   ```

   ```bash
   kubectl apply -f pvc-writer.yaml
   kubectl exec pvc-writer -- cat /usr/share/data/greeting.txt
   ```

7. Delete and recreate the Pod, then confirm the data survived:

   ```bash
   kubectl delete pod pvc-writer
   kubectl apply -f pvc-writer.yaml
   kubectl exec pvc-writer -- cat /usr/share/data/greeting.txt
   ```

**Check your understanding**
- Q3.1: Which field must match between the PV and the PVC for static binding to succeed, given both request `ReadWriteOnce`?
- Q3.2: The PV has 5Gi capacity but the PVC requested only 1Gi. How much storage does the Pod actually get to use, and why?

---

## Exercise 4 — Reclaim policy

1. Delete the Pod from Exercise 3, then delete the PVC:

   ```bash
   kubectl delete pod pvc-writer
   kubectl delete pvc pvc-manual
   ```

2. Check the PV's status:

   ```bash
   kubectl get pv pv-manual
   ```

3. Read the reclaim policy directly:

   ```bash
   kubectl describe pv pv-manual | grep -i reclaim
   ```

4. Manually reclaim it for reuse — delete the PV and clear the underlying data:

   ```bash
   kubectl delete pv pv-manual
   docker exec "$(kind get nodes)" rm -rf /mnt/pv-data/*
   ```

**Check your understanding**
- Q4.1: After deleting the PVC, the PV shows `Released` instead of `Available`. Why can't a new PVC bind to it immediately, and what has to happen before it can be reused?
- Q4.2: Which reclaim policy is the default when a PV is created dynamically through a `StorageClass`?

---

## Exercise 5 — Dynamic provisioning with a `StorageClass`

1. List the available storage classes and identify the default:

   ```bash
   kubectl get storageclass
   ```

2. Save as `pvc-dynamic.yaml`, omitting `storageClassName` to use the cluster default:

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

3. Apply it and confirm Kubernetes provisions a PV for you automatically:

   ```bash
   kubectl apply -f pvc-dynamic.yaml
   kubectl get pvc pvc-dynamic
   kubectl get pv
   ```

4. Inspect who provisioned it:

   ```bash
   kubectl describe pv "$(kubectl get pvc pvc-dynamic -o jsonpath='{.spec.volumeName}')" | grep -i provisioner
   ```

5. Delete the PVC and check whether the PV disappears with it:

   ```bash
   kubectl delete pvc pvc-dynamic
   kubectl get pv
   ```

**Check your understanding**
- Q5.1: If you don't set `storageClassName` on the PVC, how does the cluster decide which provisioner creates the volume?
- Q5.2: What happens to a PVC that requests no `storageClassName` in a cluster that has no default `StorageClass`?

---

## Exercise 6 — Isolate paths in one volume with `subPath`

1. Save as `subpath-demo.yaml`, mounting one dynamically-provisioned PVC into two containers at different subdirectories:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-subpath
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 1Gi
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: subpath-demo
   spec:
     volumes:
       - name: shared
         persistentVolumeClaim:
           claimName: pvc-subpath
     containers:
       - name: logger
         image: busybox:1.36
         command: ["sh", "-c", "echo app-logs > /var/log/app/note.txt && sleep 3600"]
         volumeMounts:
           - name: shared
             mountPath: /var/log/app
             subPath: logs
       - name: web
         image: busybox:1.36
         command: ["sh", "-c", "echo hello-html > /usr/share/html/index.html && sleep 3600"]
         volumeMounts:
           - name: shared
             mountPath: /usr/share/html
             subPath: html
   ```

2. Apply it and confirm each container only sees its own subdirectory:

   ```bash
   kubectl apply -f subpath-demo.yaml
   kubectl exec subpath-demo -c logger -- ls /var/log/app
   kubectl exec subpath-demo -c web -- ls /usr/share/html
   ```

**Check your understanding**
- Q6.1: Why use `subPath` here instead of giving each container its own PVC?
- Q6.2: If `shared` were a `configMap` volume instead of a PVC, what's the tradeoff of mounting one of its keys via `subPath`?

---

## Exercise 7 — Diagnose a `Pending` PVC

1. Save as `pvc-pending.yaml`, requesting an access mode the `manual` StorageClass's PV doesn't support:

   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-broken
   spec:
     accessModes:
       - ReadWriteMany
     storageClassName: manual
     resources:
       requests:
         storage: 1Gi
   ```

   > Recreate `pv-manual` from Exercise 3 first if you deleted it (it only offers `ReadWriteOnce`).

2. Apply it and observe the status:

   ```bash
   kubectl apply -f pvc-pending.yaml
   kubectl get pvc pvc-broken
   ```

3. Inspect the events to find the reason:

   ```bash
   kubectl describe pvc pvc-broken
   ```

4. Fix it by requesting `ReadWriteOnce` instead, reapply, and confirm it binds:

   ```bash
   kubectl delete pvc pvc-broken
   # edit accessModes to ReadWriteOnce in pvc-pending.yaml, then:
   kubectl apply -f pvc-pending.yaml
   kubectl get pvc pvc-broken
   ```

**Check your understanding**
- Q7.1: For a PVC to statically bind to a PV, which three things must be compatible between them?
- Q7.2: What's the first command you should run when a PVC is stuck `Pending`?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- A1.1: It's deleted permanently along with the Pod — `emptyDir` storage is tied to the Pod's lifetime on that node, not to any container within it.
- A1.2: Both containers mount the same `emptyDir` volume (`shared-data`) from the same Pod spec, so Kubernetes mounts the same underlying directory on the node into both containers' filesystems.

**Exercise 2**
- A2.1: The node's own filesystem (typically the container runtime's local disk).
- A2.2: `medium: Memory` mounts a tmpfs, which lives in RAM; anything written to it consumes memory, so the kubelet counts it against the container's memory limit and can OOM-kill the container if it's exceeded.

**Exercise 3**
- A3.1: `storageClassName` — the PVC only considers PVs whose `storageClassName` matches its own (here, `manual`); accessModes must also be compatible.
- A3.2: The Pod only gets access to the volume backing `pv-manual` (5Gi in this case, since `hostPath` doesn't actually partition storage) — the PVC's `requests.storage` is a minimum the PV must satisfy, not a hard cap enforced on `hostPath`. In cloud-provisioned volumes, capacity is typically enforced at the requested size.

**Exercise 4**
- A4.1: With `persistentVolumeReclaimPolicy: Retain`, Kubernetes never automatically frees or wipes the PV's data — it just marks it `Released` so a human can inspect/back up the data first. An administrator must manually delete the PV object and clean the underlying storage before it becomes `Available` again.
- A4.2: `Delete` — dynamically provisioned PVs default to `Delete`, so removing the PVC also removes the PV and its backing storage.

**Exercise 5**
- A5.1: It uses the `StorageClass` marked as default (the one with the `storageclass.kubernetes.io/is-default-class: "true"` annotation); that class's `provisioner` field determines which plugin creates the volume.
- A5.2: The PVC stays `Pending` indefinitely — with no `storageClassName` and no default class, there's no provisioner to satisfy the claim and no eligible static PV to bind to (unless one happens to match manually).

**Exercise 6**
- A6.1: `subPath` lets multiple containers share one PVC while keeping their data in isolated subdirectories, avoiding the need to provision, request, and manage a separate PVC (and possibly separate storage quota) per container.
- A6.2: Files mounted via `subPath` from a `configMap` (or `secret`) do **not** receive live updates when the source object changes — only whole-volume mounts get the periodic sync that updates mounted files in place.

**Exercise 7**
- A7.1: `storageClassName`, `accessModes` (the PV must support at least what the PVC requests), and capacity (the PV's `storage` must be ≥ the PVC's request).
- A7.2: `kubectl describe pvc <name>` — the Events section reports why the claim hasn't been able to bind (e.g., no matching volumes, no provisioner, access mode mismatch).

</details>