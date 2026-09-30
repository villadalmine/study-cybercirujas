# 1.2 Managing IPAM and Pod CIDR Allocation

> **Exam weight: 3.0** — IPAM problems are common in real clusters and hard to debug. A cluster can pass every health check and still refuse to schedule pod #111 on a node, or fail to register node #257. This topic covers the whole path from a CIDR plan to an address on a pod's `eth0`. It explains who owns each range, how each layer allocates addresses, and how to diagnose exhaustion, leaks and overlap.

---

## 1. Motivation: the production problem

Every Kubernetes networking model makes one promise: **each pod gets its own routable IP, and it can reach every other pod without NAT**. Keeping that promise at scale needs an **IP Address Management (IPAM)** system that answers four questions, each of which can fail differently:

| Question | Who answers it (typical) | Failure mode when wrong |
|---|---|---|
| Which supernet do pods live in? | Cluster architect → `--cluster-cidr` / CNI pool config | Overlap with VPC, on-prem or VPN ranges → blackholed traffic that is hard to trace |
| How is that supernet split between nodes? | `kube-controller-manager` node-ipam-controller, **or** the CNI's own allocator (Calico blocks, Cilium operator) | Node registers but gets no range → `CIDRNotAvailable`, CNI never becomes ready |
| Which exact IP does *this* pod get? | The CNI IPAM plugin on the node (`host-local`, `calico-ipam`, Cilium agent, AWS `ipamd`) | `no IP addresses available in range set` → pods stuck in `ContainerCreating` |
| Which range do Services use? | `kube-apiserver` `--service-cluster-ip-range` + `ServiceCIDR` objects | ClusterIP exhaustion, or Service IPs that collide with pod or node IPs |

Two properties make this an architecture problem and not just a configuration detail:

1. **Most of these decisions are effectively permanent.** `Node.spec.podCIDR` cannot be changed once it is set. Calico cannot change the `blockSize` of an existing pool. Cilium's cluster-pool CIDRs cannot be re-cut under running nodes. Changing the ClusterIP range of a live cluster was impossible before `ServiceCIDR`. A bad early plan means a migration later.
2. **The capacity limits multiply.** Maximum nodes, maximum pods per node and maximum Services all come from the prefix lengths you choose on day zero. Pick `/16` for the cluster and `/24` per node and you have committed to **256 nodes**, whatever your cloud quota allows.

---

## 2. The IPAM layers in Kubernetes

```
                ┌───────────────────────────────────────────────────────────┐
  Day-0 plan    │ Pod supernet 10.244.0.0/16   Service range 10.96.0.0/16   │
                │ Node network 192.168.10.0/24 (must not overlap either)    │
                └───────────────┬─────────────────────────────┬─────────────┘
                                │                             │
      Layer 1: cluster → node   │                             │ Service IPAM
  ┌─────────────────────────────▼──────────────┐   ┌──────────▼────────────────────┐
  │ kube-controller-manager (node-ipam)        │   │ kube-apiserver                │
  │  --allocate-node-cidrs=true                │   │  --service-cluster-ip-range   │
  │  --cluster-cidr / --node-cidr-mask-size-*  │   │  ServiceCIDR + IPAddress (v1) │
  │  writes Node.spec.podCIDRs  (once!)        │   └───────────────────────────────┘
  │   ── OR ──                                 │
  │ CNI-native allocator                       │
  │  Calico IPPool → /26 blocks w/ affinity    │
  │  Cilium operator → CiliumNode.spec.ipam    │
  │  AWS VPC CNI → ENI secondary IPs/prefixes  │
  └─────────────────────────────┬──────────────┘
                                │
      Layer 2: node → pod       │  CNI ADD (kubelet → containerd/CRI-O → CNI plugin)
  ┌─────────────────────────────▼──────────────────────────────────────────────┐
  │ IPAM plugin: host-local (files in /var/lib/cni/networks/<net>/)            │
  │              calico-ipam (IPAMBlock / IPAMHandle CRs in the datastore)     │
  │              cilium-agent (in-memory + CiliumNode status)                  │
  │              whereabouts (cluster-wide, for Multus secondary networks)     │
  └────────────────────────────────────────────────────────────────────────────┘
```

The key design question for any CNI is **whether it trusts `Node.spec.podCIDRs` or ignores it**:

| CNI / mode | Uses `Node.spec.podCIDRs`? | Allocator of record | Per-node granularity |
|---|---|---|---|
| Flannel (`kube-subnet-mgr`) | **Yes, required** | kube-controller-manager | One fixed range per node |
| Calico + `host-local` IPAM (`usePodCidr`) | Yes | kube-controller-manager | One fixed range per node |
| Calico + `calico-ipam` (default) | **No** | Calico IPAM (IPPool → blocks) | Dynamic `/26` blocks, as many as needed |
| Cilium `ipam.mode=kubernetes` | Yes | kube-controller-manager | One fixed range per node |
| Cilium `ipam.mode=cluster-pool` (default) | No | cilium-operator → `CiliumNode` | One or more ranges per node |
| Cilium `ipam.mode=multi-pool` | No | cilium-operator → `CiliumPodIPPool` | Chunks from several pools on demand |
| AWS VPC CNI | No | `ipamd` + EC2 API | ENI secondary IPs or `/28` prefixes |
| Azure CNI Overlay / GKE VPC-native | Varies (cloud allocator) | Cloud control plane | Provider-defined |

When the CNI ignores `podCIDRs`, the controller-manager may still write them, and `kubectl describe node` then shows a `PodCIDR` that **has nothing to do with the IPs the pods actually get**. Mixing up these two sources is a common cause of wrong diagnoses.

---

## 3. Layer 1 in depth: the node-ipam-controller

### 3.1 Mechanics

The node IPAM controller inside `kube-controller-manager` runs only when `--allocate-node-cidrs=true`. Its default allocator (`--cidr-allocator-type=RangeAllocator`) works like this:

1. It builds a bitmap for each configured `--cluster-cidr` (one per IP family), where each bit is one node-sized subnet.
2. On startup, it **marks as used every CIDR already recorded on existing Node objects**. This is how it survives restarts without a separate datastore: the Node objects *are* the datastore.
3. For every new Node without `spec.podCIDRs`, it takes the next free subnet from each family and patches `spec.podCIDR` (legacy, single value) and `spec.podCIDRs` (list, one per family).
4. When a Node is deleted, it frees the subnet.
5. If the bitmap is full, it emits a `CIDRNotAvailable` event on the Node and the node never receives a range.

`CloudAllocator` delegates the decision to the cloud provider (historically GCE alias ranges). The `MultiCIDRRangeAllocator` + `ClusterCIDR` alpha API (`networking.k8s.io/v1alpha1`) was **removed in v1.29**. Its KEP was withdrawn, so do not design around it. To grow pod space today, you use CNI-native pools (Calico/Cilium), not multiple `ClusterCIDR` objects.

### 3.2 Relevant flags

| Component | Flag | Meaning |
|---|---|---|
| kube-controller-manager | `--allocate-node-cidrs` | Enable per-node pod CIDR allocation |
| kube-controller-manager | `--cluster-cidr` | Pod supernet(s); comma-separated for dual-stack (`10.244.0.0/16,fd00:10:244::/56`) |
| kube-controller-manager | `--node-cidr-mask-size-ipv4` | Per-node IPv4 prefix (default `24`) |
| kube-controller-manager | `--node-cidr-mask-size-ipv6` | Per-node IPv6 prefix (default `64`) |
| kube-controller-manager | `--node-cidr-mask-size` | Single-stack legacy form |
| kube-controller-manager | `--service-cluster-ip-range` | Used to make sure node CIDRs never overlap the Service range |
| kube-apiserver | `--service-cluster-ip-range` | Initial ClusterIP range(s) |
| kube-proxy | `--cluster-cidr` / `clusterCIDR` | Used by `detectLocalMode: ClusterCIDR` to decide what is "local" traffic for masquerade |
| kubelet | `maxPods` | Scheduling limit per node, **independent** of the CIDR size |

**Hard constraint:** the difference between the cluster CIDR prefix and the node mask cannot be more than **16 bits**. The cidrset bitmap refuses to track more than 65,536 subnets. So `fd00:10:244::/48` with `/64` per node is the limit, and `/32` with `/64` fails when the controller-manager starts.

### 3.3 Capacity math

```
max_nodes        = 2^(node_mask − cluster_mask)
addresses/node   = 2^(32 − node_mask)                 (IPv4)
usable/node      ≈ addresses/node − 3                 (host-local: network, gateway, broadcast)
```

| Cluster CIDR | Node mask | Max nodes | Addresses per node | Sensible `maxPods` |
|---|---|---|---|---|
| `/16` | `/24` | 256 | 256 | 110 (the default; roughly 2x headroom for IP churn) |
| `/16` | `/25` | 512 | 128 | 64 |
| `/14` | `/24` | 1,024 | 256 | 110 |
| `/12` | `/24` | 4,096 | 256 | 110 |
| `/16` | `/26` | 1,024 | 64 | 30 |
| `/16` | `/23` | 128 | 512 | 250 |

Why keep 2x headroom instead of exactly `maxPods` addresses: an IP freed by a terminating pod is only reusable after the CNI `DEL` completes. On churn-heavy nodes (CronJobs, CI runners), the allocator needs spare addresses while old sandboxes are still being torn down. GKE applies the same rule: `/24` for 110 pods.

### 3.4 Complete kubeadm configuration (dual-stack)

`kubeadm` turns `networking.podSubnet` into `--allocate-node-cidrs=true --cluster-cidr=...` on the controller-manager, and `serviceSubnet` into `--service-cluster-ip-range` on both the API server and the controller-manager. This uses the `v1beta4` API, where `extraArgs` is a list of `name`/`value` pairs.

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.11
  bindPort: 6443
nodeRegistration:
  name: cp1
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "192.168.10.11,2001:db8:10::11"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
clusterName: prod-eu1
controlPlaneEndpoint: "k8s-api.prod-eu1.internal:6443"
networking:
  dnsDomain: cluster.local
  podSubnet: "10.244.0.0/16,fd00:10:244::/56"
  serviceSubnet: "10.96.0.0/16,fd00:10:96::/112"
controllerManager:
  extraArgs:
    - name: node-cidr-mask-size-ipv4
      value: "24"
    - name: node-cidr-mask-size-ipv6
      value: "64"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
maxPods: 110
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
clusterCIDR: "10.244.0.0/16,fd00:10:244::/56"
detectLocalMode: ClusterCIDR
```

```
$ sudo kubeadm init --config kubeadm-config.yaml
...
[control-plane] Creating static Pod manifest for "kube-controller-manager"
...
Your Kubernetes control-plane has initialized successfully!
```

Check what the controller-manager actually received. The static pod manifest is the source of truth, not the kubeadm config you think you used:

```
$ sudo grep -E 'cidr|allocate' /etc/kubernetes/manifests/kube-controller-manager.yaml
    - --allocate-node-cidrs=true
    - --cluster-cidr=10.244.0.0/16,fd00:10:244::/56
    - --node-cidr-mask-size-ipv4=24
    - --node-cidr-mask-size-ipv6=64
    - --service-cluster-ip-range=10.96.0.0/16,fd00:10:96::/112
```

```
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.podCIDRs
NAME   PODCIDRS
cp1    [10.244.0.0/24 fd00:10:244::/64]
w1     [10.244.1.0/24 fd00:10:244:1::/64]
w2     [10.244.2.0/24 fd00:10:244:2::/64]
```

### 3.5 Immutability and what "changing the CIDR" really means

`spec.podCIDR` and `spec.podCIDRs` can only go from empty to set. Any later change is rejected by API validation:

```
$ kubectl patch node w1 --type merge -p '{"spec":{"podCIDR":"10.250.1.0/24","podCIDRs":["10.250.1.0/24"]}}'
The Node "w1" is invalid: spec.podCIDRs: Forbidden: node updates may not change podCIDR except from "" to valid
```

So moving to a new cluster CIDR is a **node-by-node rotation**:

1. Update `--cluster-cidr` on every controller-manager and, where relevant, the CNI's config (for example Flannel's `net-conf.json` `Network`) and kube-proxy's `clusterCIDR`.
2. For each node: `kubectl drain`, then `kubectl delete node`, then clean CNI state on the host (`/var/lib/cni/`, `cni0`/`flannel.1` interfaces, or reboot), then let the kubelet re-register. The node gets a range from the new supernet.
3. During the transition, both supernets must be routable and excluded from masquerade.

For anything larger than a lab, this is the strongest argument for a CNI with **pool-based IPAM**, where adding address space is purely additive.

---

## 4. Layer 2 in depth: CNI IPAM plugins

### 4.1 The CNI contract

IPAM is a **delegated plugin**. The main plugin (bridge, ptp, macvlan...) calls the plugin named in `ipam.type` for `ADD`, `DEL` and `CHECK`. The IPAM plugin returns IPs, routes and DNS, and it alone must remember what it handed out. A `DEL` that never arrives, for example because containerd crashed mid-teardown, leaks an address until something runs garbage collection. CNI spec 1.1 adds a `GC` verb for exactly this reason.

### 4.2 `host-local`: node-scoped, file-backed

`host-local` allocates from ranges given in its own config and records each lease as a **file named after the IP** under `dataDir/<network-name>/`. The file contains the container ID and interface name. It knows nothing outside the node, so the node range must be unique, which is exactly what `Node.spec.podCIDRs` guarantees.

A complete conflist (for example `/etc/cni/net.d/10-lab-bridge.conflist`):

```json
{
  "cniVersion": "1.0.0",
  "name": "lab-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [
            {
              "subnet": "10.244.1.0/24",
              "rangeStart": "10.244.1.10",
              "rangeEnd": "10.244.1.250",
              "gateway": "10.244.1.1"
            }
          ],
          [
            {
              "subnet": "fd00:10:244:1::/64"
            }
          ]
        ],
        "routes": [
          { "dst": "0.0.0.0/0" },
          { "dst": "::/0" }
        ],
        "dataDir": "/var/lib/cni/networks"
      }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true }
    }
  ]
}
```

Notes:
- `ranges` is a **list of range sets**. Each inner list is one set, and the plugin allocates **one IP from each set**. Two sets means a dual-stack pod.
- Several entries in the same inner list form a single pool, tried in order.
- `rangeStart`/`rangeEnd` let you reserve addresses inside the node range (for example `.2–.9` for static host services).

Inspecting the lease store:

```
$ sudo ls /var/lib/cni/networks/lab-bridge/
10.244.1.10  10.244.1.11  10.244.1.12  last_reserved_ip.0  lock
$ sudo cat /var/lib/cni/networks/lab-bridge/10.244.1.11
9c1f4e0d2b7a4f3e8e1c6a5b0d9f8e7c6b5a4d3c2b1a0f9e8d7c6b5a4d3c2b1a
eth0
```

`last_reserved_ip.0` makes allocation **round-robin rather than lowest-free**. A freed IP is not reused immediately, which reduces stale-ARP and stale-conntrack collisions.

### 4.3 Calico IPAM: pools, blocks and affinity

Calico's default IPAM (`calico-ipam`) ignores `Node.spec.podCIDRs`. It keeps its own state in the datastore (Kubernetes CRDs or etcd):

- **IPPool**: a supernet with its policies: encapsulation, `natOutgoing`, `nodeSelector`, `blockSize`, `allowedUses`.
- **IPAMBlock**: a slice of a pool (default `/26` = 64 IPs for IPv4, `/122` for IPv6) with an **affinity** to one node. The node advertises the whole block as one route (BGP or VXLAN), so routing tables stay small.
- **IPAMHandle**: maps a pod or tunnel to its allocations, which is how releases are tracked.
- **BlockAffinity**: node ↔ block claim.

Allocation algorithm, simplified: first look for a free IP in a block already affine to this node. If none, claim a new block from an eligible pool. If the pool has no free blocks and `strictAffinity` is `false` (the default for IPv4), **borrow** an IP from another node's block. That pod is then reached through a `/32` route, which works but grows the routing table on every node.

| `blockSize` (IPv4) | IPs per block | Pros | Cons |
|---|---|---|---|
| `/24` | 256 | Fewer routes | Wastes space when nodes are small; fewer blocks means earlier pool exhaustion with many nodes |
| `/26` (default) | 64 | Balanced | — |
| `/28` | 16 | Fine-grained, little waste | Many routes per node; more datastore objects |
| `/32` | 1 | Every IP is its own route | Only for special cases (for example tiny, IP-scarce pools) |

Calico `blockSize` must be between `/20` and `/32` for IPv4 (`/116`–`/128` for IPv6), and it **cannot be changed on an existing pool**. You create a new pool and migrate to it.

#### Operator-managed install (Tigera operator)

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  variant: Calico
  calicoNetwork:
    bgp: Enabled
    linuxDataplane: Iptables
    ipPools:
      - name: default-ipv4-ippool
        cidr: 10.244.0.0/16
        blockSize: 26
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
      - name: default-ipv6-ippool
        cidr: fd00:10:244::/48
        blockSize: 122
        encapsulation: None
        natOutgoing: Disabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
```

The `APIServer` resource installs the Calico API server, which is what lets `kubectl` manage `projectcalico.org/v3` objects directly. How the operator handles later edits to `ipPools` depends on the Calico version. Check your version's docs before assuming it will reconcile changes. For extra pools, create `IPPool` objects directly.

#### Topology-aware pools (per zone / rack)

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool-zone-a
spec:
  cidr: 10.245.0.0/18
  blockSize: 26
  ipipMode: Never
  vxlanMode: CrossSubnet
  natOutgoing: true
  nodeSelector: 'topology.kubernetes.io/zone == "eu-west-1a"'
  allowedUses:
    - Workload
    - Tunnel
---
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool-zone-b
spec:
  cidr: 10.245.64.0/18
  blockSize: 26
  ipipMode: Never
  vxlanMode: CrossSubnet
  natOutgoing: true
  nodeSelector: 'topology.kubernetes.io/zone == "eu-west-1b"'
  allowedUses:
    - Workload
    - Tunnel
---
apiVersion: projectcalico.org/v3
kind: IPAMConfiguration
metadata:
  name: default
spec:
  strictAffinity: false
  maxBlocksPerHost: 0
```

With per-zone pools, the ToR/BGP fabric in each zone only needs to learn one aggregate. `strictAffinity: true` forbids borrowing, which is required on Windows nodes and useful when you want strict route aggregation. The trade-off is that a node whose blocks are full now **fails** allocations instead of borrowing.

#### Pinning workloads to a pool

The annotation can go on a Namespace or a Pod. The Pod annotation takes precedence.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  annotations:
    cni.projectcalico.org/ipv4pools: '["pool-payments"]'
---
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool-payments
spec:
  cidr: 10.246.0.0/22
  blockSize: 28
  ipipMode: Never
  vxlanMode: Never
  natOutgoing: false
  nodeSelector: all()
---
apiVersion: v1
kind: Pod
metadata:
  name: static-egress
  namespace: payments
  annotations:
    cni.projectcalico.org/ipAddrs: '["10.246.0.20"]'
spec:
  containers:
    - name: app
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      args:
        - netexec
        - --http-port=8080
```

This is the usual pattern when a legacy firewall downstream allowlists a specific source range: `payments` egresses from `10.246.0.0/22` without NAT. `cni.projectcalico.org/ipAddrs` requests a fixed IP, which must be inside an enabled pool.

#### Inspecting Calico IPAM

```
$ calicoctl ipam show
+----------+----------------+-----------+------------+--------------+
| GROUPING |      CIDR      | IPS TOTAL | IPS IN USE |   IPS FREE   |
+----------+----------------+-----------+------------+--------------+
| IP Pool  | 10.244.0.0/16  |     65536 | 147 (0%)   | 65389 (100%) |
| IP Pool  | 10.246.0.0/22  |      1024 | 12 (1%)    | 1012 (99%)   |
+----------+----------------+-----------+------------+--------------+

$ calicoctl ipam show --show-blocks
+----------+-----------------+-----------+------------+--------------+
| GROUPING |      CIDR       | IPS TOTAL | IPS IN USE |   IPS FREE   |
+----------+-----------------+-----------+------------+--------------+
| IP Pool  | 10.244.0.0/16   |     65536 | 147 (0%)   | 65389 (100%) |
| Block    | 10.244.33.0/26  |        64 | 51 (80%)   | 13 (20%)     |
| Block    | 10.244.33.64/26 |        64 | 39 (61%)   | 25 (39%)     |
| Block    | 10.244.97.128/26|        64 | 57 (89%)   | 7 (11%)      |
+----------+-----------------+-----------+------------+--------------+

$ kubectl get blockaffinities.crd.projectcalico.org -o custom-columns=NAME:.metadata.name,NODE:.spec.node,CIDR:.spec.cidr,STATE:.spec.state
NAME                          NODE   CIDR              STATE
w1-10-244-33-0-26             w1     10.244.33.0/26    confirmed
w1-10-244-33-64-26            w1     10.244.33.64/26   confirmed
w2-10-244-97-128-26           w2     10.244.97.128/26  confirmed

$ calicoctl ipam show --ip=10.244.33.17
IP 10.244.33.17 is in use
Attributes:
  namespace: shop
  node: w1
  pod: cart-6d5f9c7b8-xk2lq
  timestamp: 2026-09-28 10:41:07.113 +0000 UTC
```

Leak detection and repair (Calico documents this as the procedure for IPAM inconsistencies):

```
$ calicoctl ipam check --show-problem-ips -o /tmp/ipam-report.json
Checking IPAM for inconsistencies...

Loading all IPAM blocks...
Found 3 IPAM blocks.
...
Scanning for IPs that are allocated but not actually in use...
  10.244.97.141 leaked; attrs Main:k8s-pod-network.3f9a... namespace=ci pod=job-2931-x8k
Found 1 IPs that are allocated in IPAM but not actually in use.
Scanning for IPs that are in use by a workload or node but not allocated in IPAM...
Found 0 in-use IPs that are not in active IP pools.
Found 0 in-use IPs that are allocated in IPAM but not actually in use.
Check complete; found 1 problems.

$ calicoctl datastore migrate lock
$ calicoctl ipam release --from-report=/tmp/ipam-report.json
$ calicoctl datastore migrate unlock
```

Always lock the datastore around `ipam release --from-report`. Otherwise an allocation that happens between the report and the release can be freed while it is in use, which gives you a duplicate IP.

#### Pool migration (for example to fix an overlapping or wrongly-sized pool)

```
$ calicoctl create -f new-pool.yaml                     # 10.248.0.0/16, blockSize 26
$ calicoctl patch ippool default-ipv4-ippool -p '{"spec": {"disabled": true}}'
Successfully patched 1 'IPPool' resource
$ calicoctl get ippool -o wide
NAME                  CIDR            NAT    IPIPMODE   VXLANMODE     DISABLED   DISABLEBGPEXPORT   SELECTOR
default-ipv4-ippool   10.244.0.0/16   true   Never      CrossSubnet   true       false              all()
new-pool              10.248.0.0/16   true   Never      CrossSubnet   false      false              all()
$ kubectl -n shop rollout restart deployment      # repeat per namespace; recreated pods get 10.248.x.x
$ calicoctl ipam show                              # wait for 0 IPs in use in the old pool
$ calicoctl delete ippool default-ipv4-ippool
```

A disabled pool keeps existing pods working, both routing and policy. It just stops handing out new addresses. That is why this migration can be done with a rolling restart and no downtime.

### 4.4 Cilium IPAM

| `ipam.mode` | Allocator | When to use |
|---|---|---|
| `cluster-pool` (default) | cilium-operator carves `clusterPoolIPv4MaskSize` chunks from `clusterPoolIPv4PodCIDRList` into `CiliumNode.spec.ipam.podCIDRs` | Self-managed clusters that want CNI-owned IPAM, independent of controller-manager flags |
| `kubernetes` | kube-controller-manager (`Node.spec.podCIDRs`) | When the platform already allocates node CIDRs (kubeadm with `podSubnet`, some managed offerings) |
| `multi-pool` | operator, several `CiliumPodIPPool` objects, handed out on demand | Per-tenant / per-namespace ranges, growing pod space without re-IPing |
| `eni` / `azure` / `alibabacloud` | Cloud APIs | Pods get VPC-native IPs |
| `crd` | External operator writes `CiliumNode` | Custom IPAM integrations |

**Default trap:** `cluster-pool` defaults to `10.0.0.0/8`, which overlaps with a very large number of corporate and VPC networks. Always set it explicitly.

Helm values for cluster-pool:

```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.200.0.0/16
    clusterPoolIPv4MaskSize: 24
    clusterPoolIPv6PodCIDRList:
      - fd00:10:200::/104
    clusterPoolIPv6MaskSize: 120
ipv4:
  enabled: true
ipv6:
  enabled: true
routingMode: tunnel
tunnelProtocol: vxlan
k8sServiceHost: k8s-api.prod-eu1.internal
k8sServicePort: 6443
kubeProxyReplacement: true
```

```
$ helm upgrade --install cilium cilium/cilium --namespace kube-system -f cilium-values.yaml
$ kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.ipam.podCIDRs
NAME   PODCIDRS
cp1    [10.200.0.0/24 fd00:10:200::/120]
w1     [10.200.1.0/24 fd00:10:200::100/120]
w2     [10.200.2.0/24 fd00:10:200::200/120]

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 IPAM
IPAM:                    IPv4: 7/254 allocated from 10.200.1.0/24, IPv6: 7/254 allocated from fd00:10:200::100/120
```

Growing a cluster-pool: Cilium documents that you may **append** CIDRs to `clusterPoolIPv4PodCIDRList`, but you must not change or remove entries that are already allocated to nodes. Treat the list as append-only. Also, `clusterPoolIPv4MaskSize` cannot be changed for nodes that already have allocations.

Multi-pool (check your Cilium version's limitations section: routing-mode and feature support have changed between releases):

```yaml
ipam:
  mode: multi-pool
  operator:
    autoCreateCiliumPodIPPools:
      default:
        ipv4:
          cidrs:
            - 10.210.0.0/16
          maskSize: 27
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: 10.192.0.0/10
enableIPv4Masquerade: true
kubeProxyReplacement: true
```

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: tenant-mars
spec:
  ipv4:
    cidrs:
      - 10.220.0.0/20
    maskSize: 27
---
apiVersion: v1
kind: Namespace
metadata:
  name: mars
  annotations:
    ipam.cilium.io/ip-pool: tenant-mars
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rover
  namespace: mars
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rover
  template:
    metadata:
      labels:
        app: rover
    spec:
      containers:
        - name: rover
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
          ports:
            - containerPort: 8080
```

```
$ kubectl -n mars get pods -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP            NODE
rover-7c8d9f6b5d-2kq7m   1/1     Running   0          40s   10.220.0.4    w1
rover-7c8d9f6b5d-9xv4n   1/1     Running   0          40s   10.220.0.37   w2
rover-7c8d9f6b5d-r8m2p   1/1     Running   0          40s   10.220.0.5    w1
```

### 4.5 Cloud-native IPAM: AWS VPC CNI as the reference case

With VPC-native IPAM, pod IPs are real VPC addresses. The limit is no longer your CIDR plan. It is **the number of ENIs and IPs per ENI of the instance type**, plus the free space in the subnet.

```
max_pods (secondary-IP mode) = ENIs × (IPv4 per ENI − 1) + 2
m5.large: 3 × (10 − 1) + 2 = 29
```

| Knob (env on `aws-node` DaemonSet) | Effect | Trade-off |
|---|---|---|
| `WARM_ENI_TARGET=1` (default) | Keep one whole spare ENI's worth of IPs attached | Fast pod start; can reserve many unused subnet IPs |
| `WARM_IP_TARGET` / `MINIMUM_IP_TARGET` | Keep N spare IPs / at least M total | Saves subnet space; more EC2 API calls (throttling risk at scale) |
| `ENABLE_PREFIX_DELEGATION=true` | Assign `/28` prefixes (16 IPs) per ENI slot | Much higher density (Nitro only); needs **contiguous free `/28`s** in the subnet, and fragmented subnets fail |
| Custom networking (`ENIConfig`) | Pods in a secondary CIDR (for example `100.64.0.0/16`) distinct from the node subnet | Frees primary VPC space; the node's primary ENI is not used for pods |

```
$ kubectl -n kube-system set env daemonset aws-node ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
daemonset.apps/aws-node env updated
```

With prefix delegation the ENI arithmetic gives 434 on `m5.large`, but you must still set `maxPods`. EKS recommends 110 for instances with fewer than 30 vCPUs and 250 otherwise, because kubelet and runtime overhead becomes the real limit.

### 4.6 Secondary networks: Whereabouts with Multus

`host-local` on a secondary network such as macvlan to a storage VLAN breaks immediately, because every node would hand out the same addresses. Whereabouts provides **cluster-wide** allocation for these networks, storing leases in `IPPool` CRs (`whereabouts.cni.cncf.io`):

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: storage-net
  namespace: data
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "storage-net",
      "type": "macvlan",
      "master": "eth1",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.50.0/24",
        "range_start": "192.168.50.10",
        "range_end": "192.168.50.200",
        "exclude": [
          "192.168.50.100/30"
        ]
      }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: db-0
  namespace: data
  annotations:
    k8s.v1.cni.cncf.io/networks: storage-net
spec:
  containers:
    - name: db
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      args:
        - pause
```

```
$ kubectl -n data exec db-0 -- ip -4 addr show net1
3: net1@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue
    inet 192.168.50.10/24 brd 192.168.50.255 scope global net1
```

Whereabouts relies on a reconciler (the `ip-reconciler` CronJob, or its controller in newer releases) to reclaim leases of deleted pods. If that stops running, the range leaks just like `host-local` does.

---

## 5. Service IPAM: ClusterIP ranges and `ServiceCIDR`

### 5.1 Mechanics

ClusterIPs are allocated by the **API server**, not the CNI. Historically, the range was a single bitmap stored in one etcd object, which caused three problems: the range could not be resized, IPv6 was limited to `/108` (a 20-bit host space), and a busy allocator was a point of contention.

**KEP-1880 (Multiple Service CIDRs)**, GA in **v1.33**, replaces this with two `networking.k8s.io/v1` objects:

- **`ServiceCIDR`**: a range the allocator may use. The default one, named `kubernetes`, is created from `--service-cluster-ip-range`.
- **`IPAddress`**: one object per allocated ClusterIP, with a `parentRef` to its Service. Uniqueness is enforced by the object name, which is the IP itself.

Also relevant is **KEP-3070**: the lower part of every Service range is set aside for static ClusterIPs (`spec.clusterIP: 10.96.0.10` for DNS, for example). Dynamic allocation prefers the upper band, so static assignments rarely collide.

### 5.2 Extending the Service range on a live cluster

```
$ kubectl get servicecidrs
NAME         CIDRS                         AGE
kubernetes   10.96.0.0/16,fd00:10:96::/112   41d

$ kubectl create service clusterip overflow --tcp=80:80
error: failed to create ClusterIP service: Internal error occurred: failed to allocate a serviceIP: range is full
```

```yaml
apiVersion: networking.k8s.io/v1
kind: ServiceCIDR
metadata:
  name: extra-svc-cidr-01
spec:
  cidrs:
    - 10.97.0.0/20
```

```
$ kubectl apply -f servicecidr-extra.yaml
servicecidr.networking.k8s.io/extra-svc-cidr-01 created

$ kubectl get servicecidr extra-svc-cidr-01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
True

$ kubectl create service clusterip overflow --tcp=80:80
service/overflow created

$ kubectl get ipaddresses | grep overflow
10.97.12.201   services/default/overflow

$ kubectl get ipaddress 10.96.0.1
NAME        PARENTREF
10.96.0.1   services/default/kubernetes
```

Rules to remember:
- A new `ServiceCIDR` must not overlap the node network or the pod supernets. The API server does not know your pod CIDR, so it **will not stop you** from creating one that does.
- Deleting a `ServiceCIDR` that still has allocated IPs is blocked by the finalizer `networking.k8s.io/service-cidr-finalizer`, unless another ServiceCIDR also covers those IPs. The object stays in `Terminating` until those Services go away.
- The default `kubernetes` ServiceCIDR comes from flags. To shrink or replace it, you change the flags on **all** API servers. The documented procedure keeps both ranges alive while Services are recreated.
- kube-proxy and Cilium must route the new range. Both read ClusterIPs from the Services themselves, so no CIDR config is needed there. Anything that hard-codes the Service range does need updating: NetworkPolicy `ipBlock`, firewalls, `nonMasqueradeCIDRs`.

---

## 6. CIDR planning: a production-grade worked example

Scenario: three clusters (prod-eu1, prod-us1, staging) that must be **flat-routable to each other**, for Cilium ClusterMesh or Calico BGP peering to a shared fabric, and must never overlap the corporate `10.0.0.0/12` or VPC `172.16.0.0/16`.

| Range | Purpose | Size / justification |
|---|---|---|
| `172.16.0.0/16` | VPC / node network (existing) | Given |
| `10.0.0.0/12` | Corporate (existing) | Given — **excluded** |
| `10.64.0.0/14` | prod-eu1 pods | 1,024 nodes × `/24` |
| `10.68.0.0/14` | prod-us1 pods | 1,024 nodes × `/24` |
| `10.72.0.0/16` | staging pods | 256 nodes × `/24` |
| `10.96.0.0/16` | Services (each cluster may reuse it, but **not** if ClusterMesh global services or routed ClusterIPs are used, in which case give each cluster a unique `/16`) | 65k Services |
| `100.64.0.0/10` (CGNAT) | Reserve for future pod pools / secondary CIDRs | Avoid RFC1918 conflicts with mergers/VPNs |

Checklist before `kubeadm init` or a Helm install:

1. No overlap among node, pod, Service, VPN, peered VPC, Docker `bridge` (`172.17.0.0/16` default) and on-prem ranges.
2. `node_mask − cluster_mask ≤ 16`.
3. Addresses per node ≥ 2 × `maxPods`.
4. `maxPods` ≤ what the CNI can actually provide (critical for AWS VPC CNI).
5. The pod supernet is listed in non-masquerade config (`ip-masq-agent`, Calico `natOutgoing`, Cilium `ipv4NativeRoutingCIDR`) as required by your routing design.
6. The pod supernet is in kube-proxy `clusterCIDR` if `detectLocalMode: ClusterCIDR`.

Quick overlap check with Python's standard library (no packages needed):

```
$ python3 - <<'EOF'
import ipaddress, itertools
nets = {
  "vpc": "172.16.0.0/16", "corp": "10.0.0.0/12", "docker": "172.17.0.0/16",
  "pods-eu1": "10.64.0.0/14", "pods-us1": "10.68.0.0/14",
  "pods-stg": "10.72.0.0/16", "svc": "10.96.0.0/16",
}
for (a, x), (b, y) in itertools.combinations(nets.items(), 2):
    if ipaddress.ip_network(x).overlaps(ipaddress.ip_network(y)):
        print(f"OVERLAP {a} {x} <-> {b} {y}")
print("check done")
EOF
check done
```

---

## 7. Verification and failure diagnosis

### 7.1 Triage flow

```
Pod stuck ContainerCreating / sandbox errors?
 ├─ kubectl describe pod → FailedCreatePodSandBox message
 │    ├─ "no IP addresses available in range set"  → node range exhausted or leaked (7.3)
 │    ├─ "failed to acquire lease ... pod cidr not assigned" → Layer 1 failure (7.2)
 │    ├─ Calico "no configured Calico pools" / "no IPs available in pools" → pool disabled/selector/exhaustion (7.4)
 │    └─ AWS "failed to assign an IP address to container" → ENI/subnet exhaustion (7.5)
Node NotReady with NetworkUnavailable=True?
 └─ CNI never initialised → usually Layer 1 (7.2)
Pods Running but cross-node traffic fails?
 └─ Overlap / missing route / masquerade mismatch (7.6)
ClusterIP creation fails?
 └─ Service range full → ServiceCIDR (5.2)
```

### 7.2 Node without a pod CIDR

```
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
NAME    PODCIDR
cp1     10.244.0.0/24
w1      10.244.1.0/24
w257    <none>

$ kubectl get events -A --field-selector reason=CIDRNotAvailable
NAMESPACE   LAST SEEN   TYPE     REASON             OBJECT      MESSAGE
default     2m          Normal   CIDRNotAvailable   node/w257   Node w257 status is now: CIDRNotAvailable

$ kubectl -n kube-flannel logs ds/kube-flannel-ds --tail=3
E0930 09:12:44.118231       1 main.go:343] Error registering network: failed to acquire lease: node "w257" pod cidr not assigned
```

Causes and fixes:

| Cause | Evidence | Fix |
|---|---|---|
| Supernet exhausted | `CIDRNotAvailable` events; node count = `2^(node_mask − cluster_mask)` | Delete stale Node objects (their CIDRs are freed); otherwise plan a migration (3.5) or move to pool-based IPAM |
| `--allocate-node-cidrs` missing | No CIDR on **any** node; flags missing in the static pod | Set `podSubnet` in kubeadm config / add the flags; restart the controller-manager |
| Stale Node objects from destroyed VMs | `kubectl get nodes` shows long-`NotReady` nodes that no longer exist | `kubectl delete node <name>` |
| Controller-manager not the leader / crashlooping | `kubectl -n kube-system get lease kube-controller-manager` holder is stale | Fix the control plane first |

Look at the controller-manager logs for the allocator's own view:

```
$ kubectl -n kube-system logs kube-controller-manager-cp1 | grep -iE 'cidr|range_allocator' | tail -3
I0930 09:12:40.771020       1 range_allocator.go:177] "Starting range CIDR allocator"
E0930 09:12:44.101877       1 controller_utils.go:260] "Error while processing Node Add/Delete" err="failed to allocate cidr from cluster cidr at idx:0: CIDR allocation failed; there are no remaining CIDRs left to allocate in the accepted range"
```

### 7.3 Per-node exhaustion and leaked `host-local` leases

```
$ kubectl describe pod web-5d9c8b7f4-q2x8n | sed -n '/Events/,$p'
Events:
  Type     Reason                  Age   From     Message
  ----     ------                  ----  ----     -------
  Warning  FailedCreatePodSandBox  12s   kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "4e1b...": plugin type="bridge" failed (add): failed to allocate for range 0: no IP addresses available in range set: 10.244.1.1-10.244.1.254
```

Compare lease files with the pods that are actually running on the node:

```
$ ssh w1 'sudo ls /var/lib/cni/networks/cbr0 | grep -c "^10\."'
253
$ kubectl get pods -A --field-selector spec.nodeName=w1,status.phase=Running -o json \
    | jq '[.items[] | select(.spec.hostNetwork != true)] | length'
38
```

253 leases for 38 pods means a **leak**. It is typically caused by container runtime crashes, forced node reboots without CNI `DEL`, or an old runtime/plugin that does not implement CNI `GC`. Safe cleanup on the node:

```
$ kubectl drain w1 --ignore-daemonsets --delete-emptydir-data
$ ssh w1 'sudo systemctl stop kubelet containerd'
$ ssh w1 'for f in /var/lib/cni/networks/cbr0/10.*; do
            id=$(head -1 "$f")
            sudo ctr -n k8s.io c info "$id" >/dev/null 2>&1 || { echo "release $(basename "$f")"; sudo rm -f "$f"; }
          done'
$ ssh w1 'sudo systemctl start containerd kubelet'
$ kubectl uncordon w1
```

With the node drained you can simply remove all lease files. The loop above is the more conservative version, for when a few host-critical pods must stay.

If there is no leak and the node is really full, `maxPods` is set higher than the node's range can hold. Lower `maxPods` in `KubeletConfiguration`, or increase `--node-cidr-mask-size`, which only affects **newly registered** nodes.

### 7.4 Calico-specific failures

```
Warning  FailedCreatePodSandBox  ... plugin type="calico" failed (add): failed to request IPv4 addresses: failed to get IPv4 address: ... no IPs available in pools: [10.246.0.0/22]
```

| Symptom | Check | Typical cause |
|---|---|---|
| All pools reported empty | `calicoctl ipam show --show-blocks` | Pool exhausted by blocks: many nodes × few pods each (for example 1,024 nodes × one `/26` = `/16` gone) → add a pool or use smaller blocks in a new pool |
| Pods on one node only fail | `kubectl get blockaffinities` for that node; `IPAMConfiguration` | `strictAffinity: true` and `maxBlocksPerHost` reached |
| Namespace pods fail, others fine | Namespace/Pod annotations | Annotation points at a disabled pool or one whose `nodeSelector` excludes the node |
| Random `/32` routes everywhere | `ip route \| grep -c '/32'` on nodes | Heavy borrowing → blocks too large or pool too small |
| Leaked allocations | `calicoctl ipam check` | Nodes deleted without the Calico node controller cleaning up → `ipam release` (4.3) |

### 7.5 AWS VPC CNI exhaustion

```
$ kubectl -n kube-system exec ds/aws-node -c aws-node -- /app/grpc-health-probe -addr=:50051
status: SERVING
$ kubectl -n kube-system logs ds/aws-node -c aws-node | grep -iE 'insufficient|InsufficientFreeAddresses' | tail -2
{"level":"error","msg":"Failed to increase pool size due to not able to allocate ENI AllocENI: error assigning private IP addrs InsufficientFreeAddressesInSubnet: The specified subnet does not have enough free addresses to satisfy the request."}
$ aws ec2 describe-subnets --subnet-ids subnet-0abc123 --query 'Subnets[].AvailableIpAddressCount'
[
    3
]
```

Fixes: reduce warm-pool reservation (`WARM_IP_TARGET`/`MINIMUM_IP_TARGET`), add a secondary VPC CIDR with custom networking (`ENIConfig`), or use prefix delegation on subnets that still have contiguous free space. Also check whether `maxPods` exceeds the ENI formula for the instance type.

### 7.6 Overlap and routing validation

```
# 1) Where does the node think a remote pod IP lives?
$ ip route get 10.244.2.15
10.244.2.15 via 10.244.2.0 dev flannel.1 src 10.244.1.0 uid 0

# 2) Does a corporate route shadow the pod range? (a VPN pushing 10.244.0.0/16)
$ ip route show | grep -E '^10\.244\.'
10.244.0.0/16 via 192.168.10.1 dev eth0 proto static metric 50
10.244.1.0/24 dev cni0 proto kernel scope link src 10.244.1.1
10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink

# 3) Is the actual pod IP from the range you expect?
$ kubectl get pod -n shop -o custom-columns=NAME:.metadata.name,IPS:.status.podIPs[*].ip,NODE:.spec.nodeName
NAME                   IPS                          NODE
cart-6d5f9c7b8-xk2lq   10.244.33.17,fd00:10:244::9  w1
```

Line 2 shows a real hazard. Here the more specific per-node routes still win, but the static `/16` catches every pod range that has no more specific route (a new node, a Calico borrowed `/32` that has not propagated yet). Traffic then silently leaves through `eth0` toward the corporate gateway.

Dual-stack sanity:

```
$ kubectl get svc kubernetes -o jsonpath='{.spec.clusterIPs}{"\n"}'
["10.96.0.1"]
$ kubectl create deployment ds-test --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
$ kubectl expose deployment ds-test --port=80 --target-port=8080 --overrides='{"spec":{"ipFamilyPolicy":"RequireDualStack"}}'
$ kubectl get svc ds-test -o jsonpath='{.spec.ipFamilies} {.spec.clusterIPs}{"\n"}'
["IPv4","IPv6"] ["10.96.121.44","fd00:10:96::5f2a"]
```

The `kubernetes` Service keeps its original single family unless you recreate it. That is expected and does not mean dual-stack is broken.

### 7.7 Consolidated command reference

| Goal | Command |
|---|---|
| Node pod CIDRs (Layer 1) | `kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.podCIDRs` |
| Controller-manager IPAM flags | `sudo grep -E 'cidr\|allocate' /etc/kubernetes/manifests/kube-controller-manager.yaml` |
| Cluster CIDR from a running cluster | `kubectl cluster-info dump \| grep -m1 -- --cluster-cidr` |
| Allocator exhaustion | `kubectl get events -A --field-selector reason=CIDRNotAvailable` |
| Pod IPs (both families) | `kubectl get pods -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,IPS:.status.podIPs[*].ip` |
| host-local leases | `sudo ls /var/lib/cni/networks/<network>/` |
| Calico utilisation / blocks / leaks | `calicoctl ipam show --show-blocks`, `calicoctl ipam check` |
| Cilium per-node ranges | `kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,PODCIDRS:.spec.ipam.podCIDRs` |
| Cilium agent IPAM view | `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose` |
| Service ranges / allocations | `kubectl get servicecidrs`, `kubectl get ipaddresses` |

---

## 8. Design trade-offs summary

| Decision | Option A | Option B | Guidance |
|---|---|---|---|
| Who owns node ranges | kube-controller-manager (`podCIDRs`) | CNI pool IPAM (Calico/Cilium) | Pick B for anything that may need to grow; A is simpler and portable across CNIs |
| Per-node granularity | Fixed `/24` per node | Dynamic blocks (`/26`, `/27`) | Dynamic avoids waste with small nodes and big clusters; fixed is predictable for firewalls and routing |
| Pod IPs routable outside the cluster | Overlay + SNAT (`natOutgoing`) | Native routing / VPC-native | Native is required for inbound-to-pod and allowlisting; it consumes real routable address space |
| IPv4 scarcity | Larger RFC1918 blocks | IPv6 / dual-stack, CGNAT `100.64.0.0/10`, prefix delegation | Plan IPv6 early: Service families and podCIDRs are hard to add to live nodes |
| Tenant isolation by address | One flat pool | Pools per namespace / zone (Calico annotations, Cilium multi-pool) | Per-tenant pools help with legacy firewalls and egress audit, but add operational objects to manage |
| Leak handling | Trust CNI `DEL` | Periodic reconcilers (`calicoctl ipam check`, Whereabouts reconciler, CNI `GC`) | Always have one; leaks are a matter of *when*, not *if*, on large, churn-heavy clusters |

---

## 9. Practice tasks

1. On a kubeadm cluster, find the pod supernet, the per-node mask and the Service range using only `kubectl` and the static pod manifests. Compute the maximum node count.
2. A new worker stays `NotReady` and Flannel logs `pod cidr not assigned`. Find the cause using events and controller-manager logs, and free capacity by removing stale Node objects.
3. With Calico: create a `/24` pool with `blockSize: 28` for namespace `legacy`, pin the namespace to it, then migrate the default pool to a new CIDR without downtime.
4. With Cilium in `cluster-pool` mode: append a second CIDR to `clusterPoolIPv4PodCIDRList`, add a node, and confirm from `CiliumNode` which range it received.
5. Fill a small Service range (for example a lab created with `--service-cluster-ip-range=10.96.0.0/28`), confirm the `range is full` error, add a `ServiceCIDR`, and check the new `IPAddress` objects.
6. On one node, simulate `host-local` leaks by force-killing the runtime during pod churn. Detect them by comparing lease files to running sandboxes, and clean them up safely.

---

## Referencias

- CKNE certification page — Linux Foundation: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Cluster Networking — Kubernetes: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- IPv4/IPv6 dual-stack — Kubernetes: https://kubernetes.io/docs/concepts/services-networking/dual-stack/
- Validate IPv4/IPv6 dual-stack — Kubernetes: https://kubernetes.io/docs/tasks/network/validate-dual-stack/
- kube-controller-manager command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/
- kube-apiserver command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- kubeadm configuration (v1beta4): https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Kubelet configuration (v1beta1): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Node API reference (`spec.podCIDRs`): https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/node-v1/
- Service ClusterIP allocation — Kubernetes: https://kubernetes.io/docs/concepts/services-networking/cluster-ip-allocation/
- Extend Service IP Ranges (ServiceCIDR) — Kubernetes: https://kubernetes.io/docs/tasks/network/extend-service-ip-ranges/
- KEP-1880 Multiple Service CIDRs: https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/1880-multiple-service-cidrs
- CNI Specification: https://github.com/containernetworking/cni/blob/main/SPEC.md
- host-local IPAM plugin — CNI: https://www.cni.dev/plugins/current/ipam/host-local/
- Calico IP pool resource: https://docs.tigera.io/calico/latest/reference/resources/ippool
- Calico IPAM configuration resource: https://docs.tigera.io/calico/latest/reference/resources/ipamconfig
- Calico — Migrate from one IP pool to another: https://docs.tigera.io/calico/latest/networking/ipam/migrate-pools
- Calico — Change IP pool block size: https://docs.tigera.io/calico/latest/networking/ipam/change-block-size
- Calico — Assign IP addresses based on topology: https://docs.tigera.io/calico/latest/networking/ipam/assign-ip-addresses-topology
- Calico — `calicoctl ipam`: https://docs.tigera.io/calico/latest/reference/calicoctl/ipam/
- Cilium IPAM concepts: https://docs.cilium.io/en/stable/network/concepts/ipam/
- Cilium cluster-pool IPAM: https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/
- Cilium multi-pool IPAM: https://docs.cilium.io/en/stable/network/concepts/ipam/multi-pool/
- Cilium Kubernetes host-scope IPAM: https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/
- Amazon VPC CNI — increase available IP addresses (prefix delegation): https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
- Amazon VPC CNI plugin source and configuration: https://github.com/aws/amazon-vpc-cni-k8s
- Whereabouts IPAM: https://github.com/k8snetworkplumbingwg/whereabouts
- Multus CNI: https://github.com/k8snetworkplumbingwg/multus-cni