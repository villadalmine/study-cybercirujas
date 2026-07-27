# 4.1 Prepare underlying infrastructure for installing a Kubernetes cluster

## Scope

Before running `kubeadm init` (or executing any cluster provisioner), cluster administrators must complete fundamental **infrastructure readiness** tasks: ensuring host machines (bare-metal nodes, virtual machines, or cloud instances) satisfy hardware minimums, maintain network connectivity across cluster nodes, execute CRI-compliant container runtimes, and configure Linux kernel parameters for container packet forwarding. Incomplete infrastructure preparation causes partial cluster provisioning failures (kubelet in `NotReady` states, CNI allocation timeouts, network-related `CrashLoopBackOff` loops) that are difficult to diagnose post-installation.

This topic lays the foundation for Topic 4.2 (bootstrapping via `kubeadm`).

---

## 1. Hardware and Operating System Requirements

Recommended baseline resource requirements per node (documented by the `kubeadm` project):

| Resource | Control Plane | Worker Node |
|---|---|---|
| CPU | 2 vCPUs | 1 vCPU |
| RAM | 2 GiB | 1 GiB |
| Storage | 20 GiB free | 20 GiB free |
| Swap | Disabled | Disabled |

In production environments, these baseline values represent absolute minimum thresholds required for `kubeadm init` preflight verification passes rather than production sizing targets.

Operating System requirements: Any Linux distribution featuring `systemd` init management (Ubuntu, Debian, RHEL/CentOS/Rocky, Flatcar, etc.). Windows Server is supported strictly for *worker nodes* in hybrid clusters; control plane instances require Linux.

---

## 2. Node Network Identifiers and Connectivity

Every node requires:

- A **unique hostname** across the cluster topology.
- A **unique MAC address** on primary network interfaces.
- A **unique `product_uuid`** (critical when cloning virtual machines from identical templates).
- **Full-mesh network connectivity**: Nodes must reach each other (and control plane nodes must reach all workers) on required Kubernetes ports.

Verification steps prior to cluster provisioning:

```bash
# Hostname verification
hostnamectl status | grep "Static hostname"

# MAC address of primary interface
ip link show eth0 | awk '/ether/ {print $2}'

# product_uuid (crucial for cloned VMs)
sudo cat /sys/class/dmi/id/product_uuid
```

If multiple virtual machine nodes report identical `product_uuid` values (common when cloning VMs without regenerating identities), subsequent `kubeadm join` commands fail during node registration.

---

## 3. Required Port Mappings

Kubernetes requires open network ports between nodes. If host firewalls (`ufw`, `firewalld`) or cloud security groups are enabled, configure rules explicitly:

**Control Plane Nodes:**

| Port | Component |
|---|---|
| 6443 | kube-apiserver |
| 2379–2380 | etcd client / peer communication |
| 10250 | kubelet API |
| 10259 | kube-scheduler |
| 10257 | kube-controller-manager |

**Worker Nodes:**

| Port | Component |
|---|---|
| 10250 | kubelet API |
| 30000–32767 | NodePort Services |

Example `ufw` configuration on Ubuntu control plane nodes:

```bash
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 10259/tcp
sudo ufw allow 10257/tcp
sudo ufw status
```

Output:

```
Status: active

To                         Action      From
--                         ------      ----
6443/tcp                   ALLOW       Anywhere
2379:2380/tcp               ALLOW       Anywhere
10250/tcp                  ALLOW       Anywhere
10259/tcp                  ALLOW       Anywhere
10257/tcp                  ALLOW       Anywhere
```

In test labs and cloud setups, host firewalls are frequently disabled in favor of cloud security group filtering, preventing local host firewall rules from colliding with CNI driver rules (`iptables`/`nftables`).

---

## 4. Disabling Swap

kubelet agents fail to start when host swap memory is enabled unless explicitly configured via feature flags (`NodeSwap` feature gate and `failSwapOn: false` in kubelet configuration files). Standard CKA exam environments mandate disabling swap completely:

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

Verification:

```bash
free -h
```

```
               total        used        free      shared  buff/cache   available
Mem:           3.8Gi       412Mi       2.9Gi        1.0Mi       498Mi       3.2Gi
Swap:             0B          0B          0B
```

`Swap: 0B` across memory columns confirms swap is disabled and will remain inactive across node reboots (via modified `/etc/fstab` entries).

---

## 5. Kernel Modules and Sysctl Parameters

Kubernetes requires kernel support to make network bridge traffic visible to `iptables` and to enable IP packet forwarding.

Load required kernel modules:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

- `overlay`: Overlay filesystem driver utilized by containerd/CRI-O for container image layers.
- `br_netfilter`: Enables L2 network bridge traffic inspection by `iptables` rules (required for NetworkPolicies and `kube-proxy` packet routing).

Configure sysctl parameters:

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

Verification:

```bash
sudo sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```

```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

Without `net.ipv4.ip_forward = 1`, host nodes drop routed packets between network interfaces, severing Pod-to-Pod cross-node traffic via CNI plugins.

---

## 6. Container Runtime (CRI)

Since Kubernetes removed `dockershim` (v1.24+), host nodes require a container runtime implementing the **Container Runtime Interface (CRI)** natively: `containerd`, `CRI-O`, or alternative CRI runtimes. `containerd` represents the standard runtime tested on the exam.

Installation on Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

**Critical Configuration**: Aligning the **cgroup driver**. kubelet agents require container runtimes to use `systemd` as the cgroup driver to match host init systems. Update `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd --no-pager
```

```
● containerd.service - containerd container runtime
     Loaded: loaded (/lib/systemd/system/containerd.service; enabled; vendor preset: enabled)
     Active: active (running) since ...
```

Leaving `SystemdCgroup` set to `false` creates driver mismatches with kubelet, causing `kubelet` service crashes logged under `journalctl -u kubelet` during `kubeadm init` executions.

---

## 7. Pre-Installation Infrastructure Checklist

Before proceeding to cluster bootstrapping (Topic 4.2), validate host states across all nodes:

```bash
# Verify hostname and unique UUID
hostnamectl status
sudo cat /sys/class/dmi/id/product_uuid

# Confirm swap is inactive
free -h

# Confirm required kernel modules are loaded
lsmod | grep -E 'overlay|br_netfilter'

# Verify sysctl settings
sysctl net.ipv4.ip_forward

# Confirm containerd service status and CRI socket availability
sudo systemctl is-active containerd
sudo crictl info 2>/dev/null | head -n 5

# Test network port connectivity to control plane API server ports
nc -zv <control-plane-ip> 6443
```

---

## References

- Installing kubeadm — Before you begin: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- Container runtimes: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Ports and Protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- kubeadm init Preflight Checks: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#preflight-checks
- Swap memory management in Kubernetes: https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
