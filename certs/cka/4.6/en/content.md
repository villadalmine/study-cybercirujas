# 4.6 Understand extension interfaces (CNI, CSI, CRI, etc.)

## Introduction

Kubernetes delegates container runtime execution, networking topology, and volume storage management to **pluggable extension interfaces** defined via gRPC APIs and binary specification contracts. This design decouples core Kubernetes control plane code from underlying infrastructure implementations (`containerd`, `CRI-O`, `Calico`, `Cilium`, `AWS EBS`, `Ceph`).

Core Extension Interfaces:

| Interface | Abstraction Scope | Consuming Component |
|---|---|---|
| **CRI** (Container Runtime Interface) | Container lifecycle execution and image management | `kubelet` |
| **CNI** (Container Network Interface) | Pod network namespace provisioning and IP allocation | `kubelet` (invokes CNI binary plugins) |
| **CSI** (Container Storage Interface) | Volume provisioning, mounting, and snapshotting | `kube-controller-manager`, `kubelet` |

Kubernetes also provides the **Device Plugin Framework** to expose specialized hardware resources (GPUs, SR-IOV NICs, FPGAs) to Pods.

---

## CRI (Container Runtime Interface)

CRI defines gRPC services that `kubelet` uses to interact with container runtimes without embedded runtime code:

- **RuntimeService**: Handles Pod sandbox and container lifecycle management (create, start, stop, remove, status).
- **ImageService**: Manages image pulling, listing, and deletion.

### CRI Runtimes

- **containerd**: CNCF-maintained core runtime engine.
- **CRI-O**: Lightweight OCI runtime built specifically for Kubernetes.
- Legacy Docker Engine is unsupported directly (`dockershim` removed in v1.24); requires `cri-dockerd` adapters.

### Configuration

`kubelet` defines runtime sockets via `--container-runtime-endpoint`:

```bash
cat /var/lib/kubelet/kubeadm-flags.env
# --container-runtime-endpoint=unix:///run/containerd/containerd.sock
```

### Debugging with crictl

`crictl` is the standard CLI tool for inspecting CRI runtimes:

```bash
# Configure socket endpoint
crictl config runtime-endpoint unix:///run/containerd/containerd.sock

# List active Pod sandboxes
crictl pods

# List active containers
crictl ps -a

# Fetch container log streams
crictl logs <container-id>

# List cached container images
crictl images
```

Inspect node runtime engine versions:

```bash
kubectl get nodes -o wide
# NAME       STATUS   ROLES           VERSION   CONTAINER-RUNTIME
# node-01    Ready    control-plane   v1.35.0   containerd://1.7.13
```

---

## CNI (Container Network Interface)

CNI is a CNCF specification governing network interface allocation for Linux containers. `kubelet` invokes configured CNI binaries whenever Pod sandboxes are created or destroyed.

### Workflow

1. `kubelet` provisions a **pause container** holding the Pod network namespace.
2. `kubelet` executes configured CNI binaries, passing network namespace parameters via JSON stdin and environment variables.
3. CNI plugins configure host veth pairs and bridges, delegate address allocation to IPAM drivers, and return JSON configuration payloads.

### Configuration Files

CNI configurations reside under `/etc/cni/net.d/`, with plugin binaries installed under `/opt/cni/bin/`:

```bash
cat /etc/cni/net.d/10-calico.conflist
```

```json
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "ipam": { "type": "calico-ipam" }
    },
    { "type": "portmap", "capabilities": {"portMappings": true} }
  ]
}
```

### Common CNI Drivers

- **Calico**: BGP or overlay routing (VXLAN/IPIP) supporting `NetworkPolicy`.
- **Cilium**: eBPF-driven networking with L3–L7 security and observability (Hubble).
- **Flannel**: Lightweight VXLAN overlay network.

---

## CSI (Container Storage Interface)

CSI provides an out-of-tree specification allowing storage vendors to develop volume plugins outside core Kubernetes source code.

### Driver Components

A complete CSI driver deployment consists of:

- **Controller Plugin** (`Deployment` or `StatefulSet`): Executes cluster-level volume operations (`CreateVolume`, `DeleteVolume`, `ControllerPublishVolume`).
- **Node Plugin** (`DaemonSet` on every node): Mounts volume targets to host paths (`NodeStageVolume`, `NodePublishVolume`).

CSI sidecar containers translate API resources into gRPC calls:

- `external-provisioner`: Watches `PersistentVolumeClaim` objects and invokes `CreateVolume`.
- `external-attacher`: Manages node volume attachment.
- `node-driver-registrar`: Registers node plugins with `kubelet` via sockets under `/var/lib/kubelet/plugins_registry/`.
- `external-resizer`: Handles volume expansion operations.

```bash
# View registered cluster CSI drivers
kubectl get csidrivers

# Inspect active node CSI driver registrations
kubectl get csinodes

# View active volume attachments
kubectl get volumeattachments
```

---

## References

- Container Runtime Interface (CRI): https://kubernetes.io/docs/concepts/architecture/cri/
- Container Network Interface (CNI): https://github.com/containernetworking/cni
- Container Storage Interface (CSI): https://kubernetes.io/docs/concepts/storage/volumes/#csi
- crictl CLI Reference: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
