# Guided Exercises — 4.4 Implement and configure a highly-available control plane

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: Access to a `kubeadm` cluster with active control-plane nodes.

---

## Block 1 — Explore HA Architecture

1. List nodes and confirm control plane roles:
   ```bash
   kubectl get nodes -o wide
   kubectl get nodes -l node-role.kubernetes.io/control-plane
   ```
2. Inspect active kubeconfig server endpoints:
   ```bash
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
   ```
3. Compare target endpoints against individual control plane node internal IPs (`kubectl get nodes -o wide`).

### Questions

1. Why does an HA cluster kubeconfig target a load balancer address rather than individual API server node IPs?

---

## Block 2 — Inspect etcd Topology

1. SSH into a control plane node and view the static etcd manifest:
   ```bash
   sudo cat /etc/kubernetes/manifests/etcd.yaml
   ```
2. Inspect `--initial-cluster`, `--listen-peer-urls`, and `--listen-client-urls` flags.
3. Check etcd member status using `etcdctl`:
   ```bash
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list -w table
   ```

### Questions

1. What distinguishes **stacked etcd** topologies from **external etcd** topologies?
2. If `--initial-cluster` lists 3 members, how many member failures can etcd sustain without losing quorum?

---

## Block 3 — Join Additional Control Plane Nodes

1. Upload certificates from an active control plane node:
   ```bash
   sudo kubeadm init phase upload-certs --upload-certs
   ```
2. Generate join commands:
   ```bash
   kubeadm token create --print-join-command
   ```
3. Combine outputs and execute on the new node:
   ```bash
   sudo kubeadm join <control-plane-endpoint>:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash> \
     --control-plane \
     --certificate-key <certificate-key>
   ```

---

## Block 4 — Verify Leader Election

1. Inspect control plane leases in namespace `kube-system`:
   ```bash
   kubectl get lease -n kube-system
   kubectl describe lease kube-controller-manager -n kube-system
   kubectl describe lease kube-scheduler -n kube-system
   ```

---

<details>
<summary>View Answers</summary>

1. Kubeconfig targets load balancer VIPs to ensure API availability if individual master nodes crash.
2. Stacked etcd runs local etcd pods on master nodes. External etcd decouples etcd onto separate hosts.
3. 3-member etcd clusters sustain 1 node failure without losing quorum.

</details>
