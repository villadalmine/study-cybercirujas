# Guided Exercises — 4.1 Prepare underlying infrastructure for installing a Kubernetes cluster

> Reference: [CNCF CKA Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Prerequisites: At least two Linux virtual machines (Ubuntu 22.04/24.04 recommended) with `sudo` access, designated as control-plane and worker nodes.

---

## Step 1: Verify Hostname, MAC Address, and product_uuid Uniqueness

1. Verify unique hostnames across all nodes:
   ```bash
   hostnamectl status | grep hostname
   ```
2. Verify primary network interface MAC addresses:
   ```bash
   ip link show
   ```
3. Inspect `product_uuid`:
   ```bash
   sudo cat /sys/class/dmi/id/product_uuid
   ```
4. Confirm values do not collide between control-plane and worker nodes. Update hostname if necessary: `sudo hostnamectl set-hostname <new-name>`.

### Questions

1. Why does `kubeadm` require unique `product_uuid` values across cluster nodes?
2. Which Kubernetes component consumes these identifiers to distinguish node instances?

---

## Step 2: Verify Port Connectivity Between Nodes

1. Inspect listening ports on control-plane nodes:
   ```bash
   sudo ss -tulpn | grep LISTEN
   ```
2. Review minimum required control-plane ports: `6443` (API server), `2379-2380` (etcd), `10250` (kubelet API), `10259` (kube-scheduler), `10257` (kube-controller-manager).
3. Review minimum required worker ports: `10250` (kubelet API), `30000-32767` (NodePort Services).
4. Test connectivity from worker nodes to the control-plane API server:
   ```bash
   nc -zv <control-plane-ip> 6443
   ```

### Questions

1. Why must port range `30000-32767` be accessible across worker nodes?
2. What causes `nc -zv` connectivity timeouts targeting port `6443`?

---

## Step 3: Disable Swap Permanently

1. Disable swap for current session:
   ```bash
   sudo swapoff -a
   ```
2. Confirm swap state:
   ```bash
   free -h
   ```
3. Comment out swap mounts in `/etc/fstab`:
   ```bash
   sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
   ```

### Questions

1. How does `kubelet` respond if started with swap active without explicit `failSwapOn: false` configurations?
2. Why is modifying `/etc/fstab` necessary alongside `swapoff -a`?

---

## Step 4: Load Required Kernel Modules

1. Configure persistent kernel module loading:
   ```bash
   cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF
   ```
2. Load modules immediately:
   ```bash
   sudo modprobe overlay
   sudo modprobe br_netfilter
   ```
3. Verify loaded modules:
   ```bash
   lsmod | grep -E 'overlay|br_netfilter'
   ```

### Questions

1. What networking failure occurs if `br_netfilter` is un-loaded?
2. Why is `overlay` required by container runtimes?

---

## Step 5: Configure Sysctl Network Parameters

1. Configure sysctl settings:
   ```bash
   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables  = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward                 = 1
   EOF
   ```
2. Apply parameters:
   ```bash
   sudo sysctl --system
   ```
3. Verify parameters:
   ```bash
   sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
   ```

### Questions

1. If `net.ipv4.ip_forward` remains set to `0`, what network traffic fails?

---

## Step 6: Install and Configure `containerd`

1. Install `containerd`:
   ```bash
   sudo apt update
   sudo apt install -y containerd
   ```
2. Generate default configuration:
   ```bash
   sudo mkdir -p /etc/containerd
   containerd config default | sudo tee /etc/containerd/config.toml
   ```
3. Enable `SystemdCgroup` in `/etc/containerd/config.toml`:
   ```bash
   sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
   ```
4. Restart containerd service:
   ```bash
   sudo systemctl restart containerd
   sudo systemctl enable containerd
   ```

### Questions

1. Why must `containerd` cgroup drivers align with `kubelet` cgroup drivers?

---

## Step 7: Install `kubeadm`, `kubelet`, and `kubectl`

1. Add Kubernetes repository key and sources (v1.35):
   ```bash
   sudo apt update
   sudo apt install -y apt-transport-https ca-certificates curl gpg
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | \
     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | \
     sudo tee /etc/apt/sources.list.d/kubernetes.list
   ```
2. Install packages:
   ```bash
   sudo apt update
   sudo apt install -y kubelet kubeadm kubectl
   sudo apt-mark hold kubelet kubeadm kubectl
   ```

---

## Step 8: Preflight Check Validation

1. Run `kubeadm` preflight phase validation:
   ```bash
   sudo kubeadm init phase preflight
   ```
2. Pull control plane images in advance:
   ```bash
   sudo kubeadm config images pull --kubernetes-version v1.35.0
   ```

---

<details>
<summary>View Answers</summary>

1. Identical UUIDs confuse node identity registration in API servers.
2. Port range 30000–32767 exposes NodePort Services across worker nodes.
3. Kubelet fails to start when swap is active unless `failSwapOn: false` is configured.
4. Un-loaded `br_netfilter` prevents iptables from inspecting bridged L2 network traffic.
5. Setting `net.ipv4.ip_forward = 0` drops routed IP packets between Pod interfaces across host nodes.
6. Mismatched cgroup drivers cause node instability and container lifecycle management failures.

</details>
