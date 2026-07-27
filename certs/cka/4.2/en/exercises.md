# Guided Exercises — 4.2 Create and manage Kubernetes clusters using kubeadm

Prerequisites: Three Linux nodes (`cp-01` control plane, `worker-01`, `worker-02`) running container runtimes (`containerd`) with `sudo` access.

---

## Exercise 1 — Node Preparation

Execute on **all three nodes**:

1. Disable swap:
   ```bash
   sudo swapoff -a
   sudo sed -i '/ swap /s/^/#/' /etc/fstab
   ```
2. Load kernel modules:
   ```bash
   cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF
   sudo modprobe overlay
   sudo modprobe br_netfilter
   ```
3. Configure sysctl settings:
   ```bash
   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables  = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward                 = 1
   EOF
   sudo sysctl --system
   ```
4. Install `containerd` and enable `SystemdCgroup`:
   ```bash
   sudo apt-get update && sudo apt-get install -y containerd
   sudo mkdir -p /etc/containerd
   containerd config default | sudo tee /etc/containerd/config.toml
   sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
   sudo systemctl restart containerd
   ```
5. Install `kubeadm`, `kubelet`, and `kubectl`:
   ```bash
   KUBE_VERSION=v1.34
   sudo mkdir -m 755 -p /etc/apt/keyrings
   curl -fsSL https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/Release.key | \
     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/ /" | \
     sudo tee /etc/apt/sources.list.d/kubernetes.list
   sudo apt-get update
   sudo apt-get install -y kubelet kubeadm kubectl
   sudo apt-mark hold kubelet kubeadm kubectl
   ```

---

## Exercise 2 — Control Plane Initialization

Execute on `cp-01`:

1. Initialize cluster:
   ```bash
   sudo kubeadm init \
     --pod-network-cidr=10.244.0.0/16 \
     --control-plane-endpoint=cp-01 \
     --upload-certs
   ```
2. Configure user `kubectl` credentials:
   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```

---

## Exercise 3 — CNI Plugin Installation

1. Install Flannel:
   ```bash
   kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
   ```
2. Confirm control plane transitions to `Ready`:
   ```bash
   kubectl get nodes
   ```

---

## Exercise 4 — Joining Worker Nodes

Execute on `worker-01` and `worker-02`:

1. Run join command:
   ```bash
   sudo kubeadm join cp-01:6443 \
     --token <token> \
     --discovery-token-ca-cert-hash sha256:<hash>
   ```
2. Confirm nodes registered:
   ```bash
   kubectl get nodes -o wide
   ```

---

## Exercise 5 — Certificate Expiration and Renewal

1. Inspect certificate expiration dates:
   ```bash
   sudo kubeadm certs check-expiration
   ```
2. Renew all certificates:
   ```bash
   sudo kubeadm certs renew all
   ```

---

<details>
<summary>View Answers</summary>

1. Swap must be disabled because kubelet memory calculations assume deterministic memory bounds.
2. `br_netfilter` allows iptables to inspect bridged L2 network traffic.
3. `--upload-certs` encrypts and uploads control plane certificates for HA master join operations.
4. `--discovery-token-ca-cert-hash` verifies root CA authenticity during node join.

</details>
