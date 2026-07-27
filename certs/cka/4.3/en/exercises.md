# Guided Exercises — 4.3 Manage the lifecycle of Kubernetes clusters

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: A working `kubeadm` cluster with one control plane node (`k8s-cp1`) and two worker nodes (`k8s-worker1`, `k8s-worker2`).

---

## Exercise 1 — Audit Cluster Version States

1. List cluster nodes and `kubelet` versions:
   ```bash
   kubectl get nodes -o wide
   ```
2. Confirm `kube-apiserver` versions:
   ```bash
   kubectl version
   ```
3. Verify control plane Pod health in `kube-system`:
   ```bash
   kubectl get pods -n kube-system
   ```

### Questions

1. Which version skew policy regulates minor version differences between `kube-apiserver` and node `kubelet` agents?
2. Why is skipping minor versions during upgrades (e.g. 1.33 to 1.35) prohibited by `kubeadm`?

---

## Exercise 2 — Cordon and Drain Worker Nodes

1. Mark `k8s-worker1` unschedulable:
   ```bash
   kubectl cordon k8s-worker1
   ```
2. Verify `SchedulingDisabled` status:
   ```bash
   kubectl get nodes
   ```
3. Drain target node:
   ```bash
   kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
   ```
4. Confirm no application Pods remain on the drained node:
   ```bash
   kubectl get pods -o wide --all-namespaces --field-selector spec.nodeName=k8s-worker1
   ```

### Questions

1. What separates `cordon` from `drain` operations?
2. Why does `drain` require passing `--ignore-daemonsets` in standard clusters?

---

## Exercise 3 — Upgrade Primary Control Plane Node

1. SSH into `k8s-cp1` and inspect active `kubeadm` versions:
   ```bash
   kubeadm version
   ```
2. Upgrade `kubeadm` package:
   ```bash
   sudo apt-get update
   sudo apt-get install -y --allow-change-held-packages kubeadm=1.35.x-00
   ```
3. Inspect upgrade plan:
   ```bash
   sudo kubeadm upgrade plan
   ```
4. Apply control plane upgrade:
   ```bash
   sudo kubeadm upgrade apply v1.35.x
   ```

### Questions

1. Why does `kubeadm upgrade plan` execute without modifying cluster state?
2. When do operators use `kubeadm upgrade apply` vs `kubeadm upgrade node`?

---

## Exercise 4 — Upgrade kubelet and kubectl on Control Plane

1. Drain `k8s-cp1`:
   ```bash
   kubectl drain k8s-cp1 --ignore-daemonsets
   ```
2. Upgrade `kubelet` and `kubectl`:
   ```bash
   sudo apt-get install -y --allow-change-held-packages kubelet=1.35.x-00 kubectl=1.35.x-00
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```
3. Uncordon node:
   ```bash
   kubectl uncordon k8s-cp1
   ```

---

## Exercise 5 — Upgrade Worker Nodes

1. Drain worker node from control plane:
   ```bash
   kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
   ```
2. SSH into `k8s-worker1` and upgrade `kubeadm`:
   ```bash
   sudo apt-get update
   sudo apt-get install -y --allow-change-held-packages kubeadm=1.35.x-00
   sudo kubeadm upgrade node
   ```
3. Upgrade `kubelet` and `kubectl`, then restart services:
   ```bash
   sudo apt-get install -y --allow-change-held-packages kubelet=1.35.x-00 kubectl=1.35.x-00
   sudo systemctl daemon-reload
   sudo systemctl restart kubelet
   ```
4. Uncordon worker node:
   ```bash
   kubectl uncordon k8s-worker1
   ```

---

## Exercise 6 — etcd Snapshot Backup and Recovery

1. Generate etcd snapshot backup:
   ```bash
   ETCDCTL_API=3 etcdctl snapshot save /opt/backups/etcd-snapshot.db \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key
   ```
2. Verify snapshot status:
   ```bash
   ETCDCTL_API=3 etcdctl snapshot status /opt/backups/etcd-snapshot.db --write-out=table
   ```
3. Restore etcd snapshot to a new data directory:
   ```bash
   ETCDCTL_API=3 etcdctl snapshot restore /opt/backups/etcd-snapshot.db \
     --data-dir=/var/lib/etcd-restore
   ```

---

<details>
<summary>View Answers</summary>

1. Version skew allows node `kubelet` versions to lag up to 3 minor versions behind `kube-apiserver`.
2. Skipping minor versions breaks configuration migration hooks and API schema compatibility.
3. `cordon` flags nodes unschedulable; `drain` evicts active running Pods to remaining cluster nodes.
4. `kubeadm upgrade apply` updates cluster-wide control plane components on the initial master node; `kubeadm upgrade node` updates local node configurations.

</details>
