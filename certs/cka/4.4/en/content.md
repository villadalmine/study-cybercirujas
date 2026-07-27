# 4.4 Implement and configure a highly-available control plane

## What is a Highly-Available Control Plane?

A Kubernetes cluster features a Highly-Available (HA) control plane when failing a single control plane node does not disrupt the `kube-apiserver` or cluster management capabilities. HA is achieved by running **multiple control plane nodes** (typically odd counts: 3, 5, or 7) executing replicated control plane components:

- **kube-apiserver**: Stateless. Replicated instances serve requests concurrently behind a load balancer.
- **etcd**: Stateful key-value store using the Raft consensus protocol. Requires a voting quorum (majority) to commit write operations.
- **kube-scheduler** and **kube-controller-manager**: Active-passive replication across control plane nodes utilizing **leader election** (via `Lease` resources in namespace `kube-system`) so only one instance processes cluster events at any given time.

---

## etcd Topologies

### Stacked etcd Topology (kubeadm default)

etcd runs as a local static pod on each control plane node alongside `kube-apiserver`.

```
[CP1: apiserver + etcd] [CP2: apiserver + etcd] [CP3: apiserver + etcd]
```

Advantages: Lower infrastructure footprint and simpler setup via `kubeadm`.
Risk: Losing a node simultaneously removes one API server instance and one etcd quorum member.

### External etcd Topology

etcd runs on dedicated host nodes separate from control plane nodes executing `kube-apiserver`.

```
[CP1: apiserver] [CP2: apiserver] [CP3: apiserver]
[etcd1]           [etcd2]          [etcd3]
```

Advantages: Decouples etcd failure domains from API servers. Highly resilient, but requires more infrastructure (minimum 6 host instances for a 3+3 architecture).

---

## API Server Load Balancing

Worker nodes and `kubectl` clients connect through a single frontend load balancer endpoint (`--control-plane-endpoint`) distributing traffic across active `kube-apiserver` instances.

Common load balancing solutions:
- Cloud load balancers (AWS NLB, GCP Load Balancing).
- HAProxy + keepalived configured with a Virtual IP (VIP) in bare-metal environments.

Example HAProxy TCP frontend/backend configuration targeting 3 control plane nodes:

```
frontend k8s-api
    bind *:6443
    mode tcp
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server cp1 10.0.0.11:6443 check
    server cp2 10.0.0.12:6443 check
    server cp3 10.0.0.13:6443 check
```

---

## etcd Quorum Calculations

For an etcd cluster of size $N$, voting quorum requires a majority of $\lfloor N/2 \rfloor + 1$ active members. Max allowed node failures $F$:

$$F = \lfloor (N - 1) / 2 \rfloor$$

| Members ($N$) | Quorum Required | Max Fault Tolerance ($F$) |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

Odd member counts maximize fault tolerance. Adding an even member (e.g. 3 to 4) increases consensus latency without increasing fault tolerance.

---

## Bootstrapping an HA Control Plane with kubeadm

### 1. Initialize the First Control Plane Node

```bash
kubeadm init \
  --control-plane-endpoint "k8s-api.internal:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16
```

- `--control-plane-endpoint`: Specifies the load balancer VIP/hostname address rather than the local node IP.
- `--upload-certs`: Encrypts and uploads control plane certificates (CA, etcd keys) to an in-cluster Secret, enabling automatic certificate downloads on subsequent control plane node joins.

Output summary:

```
Your Kubernetes control-plane has initialized successfully!
...
You can now join any number of control-plane nodes by running the following as root:

  kubeadm join k8s-api.internal:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234... \
    --control-plane --certificate-key f8902e...
```

Note: Certificate encryption keys expire after 2 hours. Regenerate expired keys using:

```bash
kubeadm init phase upload-certs --upload-certs
```

### 2. Join Secondary Control Plane Nodes

On `CP2` and `CP3`:

```bash
kubeadm join k8s-api.internal:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234... \
  --control-plane \
  --certificate-key f8902e...
```

The `--control-plane` flag instructs `kubeadm` to join the node as a control plane instance (downloading control plane certs, joining etcd quorum, starting static control plane pods) rather than a worker.

### 3. Join Worker Nodes

```bash
kubeadm join k8s-api.internal:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234...
```

---

## Verifying HA Control Plane Status

```bash
kubectl get nodes
```

```
NAME   STATUS   ROLES           AGE   VERSION
cp1    Ready    control-plane   10m   v1.35.0
cp2    Ready    control-plane   7m    v1.35.0
cp3    Ready    control-plane   5m    v1.35.0
worker1  Ready  <none>          3m    v1.35.0
```

Verify etcd member status using `etcdctl`:

```bash
kubectl exec -n kube-system etcd-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

```
+------------------+---------+-------+------------------------+------------------------+
|        ID        | STATUS  | NAME  |       PEER ADDRS       |      CLIENT ADDRS      |
+------------------+---------+-------+------------------------+------------------------+
| 4f5a3c2d1e0b1234  | started |  cp1  | https://10.0.0.11:2380 | https://10.0.0.11:2379 |
| 8b9c0d1e2f3a5678  | started |  cp2  | https://10.0.0.12:2380 | https://10.0.0.12:2379 |
| c1d2e3f4a5b69012  | started |  cp3  | https://10.0.0.13:2380 | https://10.0.0.13:2379 |
+------------------+---------+-------+------------------------+------------------------+
```

Verify active leader leases for control plane components:

```bash
kubectl get lease -n kube-system kube-scheduler kube-controller-manager -o yaml | grep holderIdentity
```

---

## Exam Tips

- If `--upload-certs` is omitted during initial `init`, certificates (`/etc/kubernetes/pki/{ca.*,sa.*,front-proxy-ca.*,etcd/ca.*}`) must be copied manually via `scp` to secondary control plane nodes prior to running `join`.
- `--control-plane-endpoint` must be set during initial `kubeadm init` executions; adding a load balancer post-initialization requires reconfiguring cluster objects.

---

## References

- Options for Highly Available Topology: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- Creating Highly Available Clusters with kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- kubeadm init Reference: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
- kubeadm join Reference: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
- etcd Cluster Size FAQ: https://etcd.io/docs/latest/faq/#what-is-failure-tolerance
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
