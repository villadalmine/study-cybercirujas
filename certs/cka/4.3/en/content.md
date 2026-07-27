# 4.3 Manage the lifecycle of Kubernetes clusters

## Scope

This topic covers operational tasks required to maintain healthy Kubernetes clusters over time: understanding **version skew policies**, executing control-plane and worker node **upgrades** using `kubeadm`, creating and restoring **etcd backups**, and performing node maintenance operations (drain/cordon/uncordon) to apply OS patches or hardware upgrades without workload downtime. On the CKA exam, this frequently appears as an end-to-end task upgrading a `kubeadm` cluster to the next minor version.

---

## Version Skew Policy

Kubernetes supports defined version skew limits between cluster components. Core rules:

- **kube-apiserver**: Functions as the reference version anchor. No cluster component can be newer than the API server.
- **kube-controller-manager, kube-scheduler, cloud-controller-manager**: May lag up to **1 minor version** behind `kube-apiserver`.
- **kubelet**: May lag up to **3 minor versions** behind `kube-apiserver` (extended skew support enabled since v1.28).
- **kube-proxy**: Must match the `kubelet` version installed on the local node and cannot be newer than `kube-apiserver`.
- **kubectl**: May be 1 minor version newer or older than `kube-apiserver`.
- **Upgrades must proceed sequentially by single minor versions** (e.g. 1.33 → 1.34 → 1.35); skipping minor versions is unsupported.

Standard upgrade ordering for a cluster:

1. Upgrade the **control plane** (primary control plane node first, followed by secondary control plane instances in HA topologies).
2. Upgrade **worker nodes** incrementally to preserve cluster scheduling capacity.

---

## Upgrading a Cluster Using kubeadm

### 1. Check Available Package Versions

```bash
# On control plane nodes
apt update
apt-cache madison kubeadm
```

```
kubeadm | 1.35.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.35/deb  Packages
kubeadm | 1.35.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.35/deb  Packages
```

### 2. Upgrade the Primary Control Plane Node

```bash
# Unhold and upgrade the kubeadm package first
apt-mark unhold kubeadm
apt install -y kubeadm='1.35.1-1.1'
apt-mark hold kubeadm

# Inspect the upgrade plan
kubeadm upgrade plan
```

Summary output:

```
[upgrade/versions] Cluster version: v1.34.1
[upgrade/versions] kubeadm version: v1.35.1
Upgrade to the latest stable version:

COMPONENT                 CURRENT   TARGET
kube-apiserver             v1.34.1   v1.35.1
kube-controller-manager    v1.34.1   v1.34.1
kube-scheduler             v1.34.1   v1.35.1
kube-proxy                 v1.34.1   v1.35.1
CoreDNS                    v1.11.3   v1.11.3
etcd                       3.5.15-0  3.5.16-0

You can now apply the upgrade by executing the following command:
        kubeadm upgrade apply v1.35.1
```

```bash
kubeadm upgrade apply v1.35.1
```

This command updates control plane static pod manifests (`/etc/kubernetes/manifests/`), rotates certificates (unless `--certificate-renewal=false` is set), and updates cluster add-on components (CoreDNS, kube-proxy).

On **secondary** control plane nodes in HA setups, run `kubeadm upgrade node` instead:

```bash
kubeadm upgrade node
```

### 3. Drain the Node Before Upgrading kubelet

```bash
kubectl drain <control-plane-node> --ignore-daemonsets
```

This marks the target node as **unschedulable** (`cordon`) and evicts non-DaemonSet Pods.

### 4. Upgrade kubelet and kubectl Packages

```bash
apt-mark unhold kubelet kubectl
apt install -y kubelet='1.35.1-1.1' kubectl='1.35.1-1.1'
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
```

### 5. Uncordon the Node

```bash
kubectl uncordon <control-plane-node>
```

### 6. Upgrade Worker Nodes

On each worker node, the workflow uses `upgrade node` rather than `upgrade apply`:

```bash
# On control plane, drain worker node
kubectl drain <worker-node> --ignore-daemonsets --delete-emptydir-data

# On worker node
apt-mark unhold kubeadm
apt install -y kubeadm='1.35.1-1.1'
apt-mark hold kubeadm

kubeadm upgrade node

apt-mark unhold kubelet kubectl
apt install -y kubelet='1.35.1-1.1' kubectl='1.35.1-1.1'
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet

# On control plane, verify node status and uncordon
kubectl get nodes
kubectl uncordon <worker-node>
```

### Final Verification

```bash
kubectl get nodes -o wide
```

```
NAME           STATUS   ROLES           AGE   VERSION
cp-01          Ready    control-plane   90d   v1.35.1
worker-01      Ready    <none>          90d   v1.35.1
worker-02      Ready    <none>          90d   v1.35.1
```

---

## etcd Backup and Restore

etcd stores all cluster state data. etcd backup and restore tasks are core exam requirements.

### etcd Snapshot Backup

```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/backups/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

```
{"level":"info","msg":"created temporary db file","path":"/opt/backups/etcd-snapshot.db.part"}
{"level":"info","msg":"saved","path":"/opt/backups/etcd-snapshot.db"}
Snapshot saved at /opt/backups/etcd-snapshot.db
```

Verify snapshot status:

```bash
ETCDCTL_API=3 etcdctl snapshot status /opt/backups/etcd-snapshot.db --write-out=table
```

### etcd Restore

Restoring an etcd snapshot writes data into a **new target directory**; it does not overwrite active etcd directories in-place.

```bash
ETCDCTL_API=3 etcdctl snapshot restore /opt/backups/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restore
```

After restoring snapshot files, update the etcd static pod manifest (`/etc/kubernetes/manifests/etcd.yaml`) to point volume mounts to `/var/lib/etcd-restore`, then restart `kubelet`:

```bash
systemctl restart kubelet
```

```bash
kubectl get pods -n kube-system | grep etcd
```

Key Exam Tips:
- Run backup commands on the host node executing `etcd`, consuming certificates under `/etc/kubernetes/pki/etcd/`.
- Always generate an etcd snapshot **before** executing cluster upgrades or destructive operations.

---

## Node Maintenance Workflow

`cordon`, `drain`, and `uncordon` commands manage node maintenance operations (kernel updates, host reboots, node decommissioning):

```bash
kubectl cordon <node>     # Mark node unschedulable (running Pods are unaffected)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... Execute host maintenance operations (reboots, OS patches) ...
kubectl uncordon <node>   # Re-enable scheduling on the node
```

Key `drain` flags:
- `--ignore-daemonsets`: Ignores DaemonSet Pods (DaemonSets cannot be evicted to other nodes).
- `--delete-emptydir-data`: Forces eviction of Pods mounting local `emptyDir` volumes (data stored on `emptyDir` is deleted).
- `--force`: Evicts unmanaged standalone Pods not backed by controllers.

---

## References

- kubeadm upgrade: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Version Skew Policy: https://kubernetes.io/releases/version-skew-policy/
- Safely Drain a Node: https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- Operating etcd clusters for Kubernetes: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcdctl snapshot recovery: https://etcd.io/docs/latest/op-guide/recovery/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
