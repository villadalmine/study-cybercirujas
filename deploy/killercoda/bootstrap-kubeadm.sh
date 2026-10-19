#!/usr/bin/env bash
# A one-node kubeadm cluster like Killercoda's kubernetes-kubeadm-1node, on an Ubuntu 24.04 VM where you are root.
# What it reproduces was MEASURED on Killercoda (probe of 2026-10-19, killercoda_envs.yaml): kubeadm/kubelet/kubectl 1.36.1,
# containerd 2.2.x, Cilium as the CNI, node `controlplane`, local-path as the default StorageClass.
# Usage: bootstrap-kubeadm.sh <k8s patch, e.g. 1.36.1> <cilium tag, e.g. v1.20.3> <containerd version, e.g. 2.2.1>
# Versions come from killercoda_envs.yaml (study-lab test --print-env). Idempotent: does nothing if a node is Ready.
# Not reproduced: RAM (Killercoda ~2.2 GB; a runner has 16 GB and its memory cannot be lowered). CPU: the workflow takes the other cores offline.
set -euo pipefail
PATCH=${1:?k8s patch version, e.g. 1.36.1}; CILIUM=${2:?cilium tag, e.g. v1.20.3}; CONTAINERD=${3:?containerd version, e.g. 2.2.1}; MINOR=${PATCH%.*}
CILIUM_CLI=v0.20.1; RUNC=v1.3.6; LOCALPATH=v0.0.37
export KUBECONFIG=/etc/kubernetes/admin.conf
if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then echo "cluster already up"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
swapoff -a
modprobe overlay; modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/k8s.conf; sysctl --system >/dev/null
apt-get update -qq; apt-get install -y -qq apt-transport-https ca-certificates curl gpg >/dev/null
# containerd from the upstream release (Ubuntu 24.04 ships 1.7; Killercoda runs 2.2.x), with runc and the systemd unit
curl -fsSL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD}/containerd-${CONTAINERD}-linux-amd64.tar.gz" | tar -xz -C /usr/local
curl -fsSL "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD}/containerd.service" -o /etc/systemd/system/containerd.service
curl -fsSL "https://github.com/opencontainers/runc/releases/download/${RUNC}/runc.amd64" -o /usr/local/sbin/runc; chmod 755 /usr/local/sbin/runc
mkdir -p /etc/containerd /etc/apt/keyrings /opt/cni/bin
/usr/local/bin/containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl daemon-reload; systemctl enable containerd >/dev/null 2>&1; systemctl restart containerd
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq; # the exact patch release from killercoda_envs.yaml, never "whatever is newest" (the test records what it measured)
apt-get install -y -qq --allow-downgrades "kubelet=${PATCH}-*" "kubeadm=${PATCH}-*" "kubectl=${PATCH}-*" >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
# Killercoda has 1 CPU and ~2 GB: kubeadm's NumCPU/Mem preflight checks must not stop the test on a smaller host
kubeadm init --kubernetes-version "v${PATCH}" --pod-network-cidr=10.244.0.0/16 --node-name controlplane \
  --cri-socket unix:///run/containerd/containerd.sock --ignore-preflight-errors=NumCPU,Mem >/tmp/kubeadm-init.log 2>&1 || { tail -30 /tmp/kubeadm-init.log; exit 1; }
mkdir -p /root/.kube; cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null
# Cilium as the CNI (Killercoda: cilium, cilium-envoy, cilium-operator pods; 05-cilium.conflist)
curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI}/cilium-linux-amd64.tar.gz" | tar -xz -C /usr/local/bin cilium
cilium install --version "${CILIUM}" --wait >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=300s
# local-path as the default StorageClass (Killercoda ships it: rancher.io/local-path, Delete, WaitForFirstConsumer)
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCALPATH}/deploy/local-path-storage.yaml" >/dev/null
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
kubectl version | head -3
kubectl get sc
