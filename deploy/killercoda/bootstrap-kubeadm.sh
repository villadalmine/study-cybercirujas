#!/usr/bin/env bash
# A one-node kubeadm cluster like Killercoda's kubernetes-kubeadm-1node, on an Ubuntu 24.04 VM where you are root.
# Usage: bootstrap-kubeadm.sh <k8s patch, e.g. 1.36.5> <flannel tag, e.g. v0.28.10>
# Versions come from killercoda_envs.yaml (study-lab test --print-env). Idempotent: does nothing if a node is Ready.
set -euo pipefail
PATCH=${1:?k8s patch version, e.g. 1.36.5}; FLANNEL=${2:?flannel tag}; MINOR=${PATCH%.*}
export KUBECONFIG=/etc/kubernetes/admin.conf
if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then echo "cluster already up"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
swapoff -a
modprobe overlay; modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/k8s.conf; sysctl --system >/dev/null
apt-get update -qq; apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd >/dev/null
mkdir -p /opt/cni/bin; curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz | tar -xz -C /opt/cni/bin
mkdir -p /etc/containerd /etc/apt/keyrings
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl restart containerd
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq; # the exact patch release from killercoda_envs.yaml, never "whatever is newest" (the test records what it measured)
apt-get install -y -qq "kubelet=${PATCH}-*" "kubeadm=${PATCH}-*" "kubectl=${PATCH}-*" >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
kubeadm init --kubernetes-version "v${PATCH}" --pod-network-cidr=10.244.0.0/16 --node-name controlplane >/tmp/kubeadm-init.log 2>&1 || { tail -30 /tmp/kubeadm-init.log; exit 1; }
mkdir -p /root/.kube; cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL}/kube-flannel.yml" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl version | head -3
