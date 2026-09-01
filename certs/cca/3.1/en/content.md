# 3.1 Kubernetes Networking with Cilium

> **Reference platform for every command and manifest in this chapter**
> Cilium `v1.16.5` (Helm chart `1.16.5`), Kubernetes `v1.31`, kernel `6.6` on the nodes, `cgroup v2` unified hierarchy, `kube-proxy` **not installed**.
> Where a CRD or Helm key changed between minor releases it is flagged inline. CLI output formatting is version-sensitive: treat the shapes below as canonical for 1.16 and re-read the fields, not the columns, on other versions.

---

## 1. The architectural problem this solves

### 1.1 What Kubernetes actually mandates, and what it leaves open

The Kubernetes network model is three sentences long:

1. Every Pod gets its own IP address.
2. Pods on a node can communicate with all Pods on all nodes **without NAT**.
3. Agents on a node (kubelet, system daemons) can reach all Pods on that node.

Everything else — how the IP is allocated, how the packet crosses the wire, how `ClusterIP` becomes a backend, how policy is enforced, how you observe any of it — is delegated to a CNI plugin. Kubernetes ships no datapath. `kube-proxy` is not a datapath either; it is a controller that *writes* rules into a datapath the kernel already had (`iptables` or `ipvs`).

That delegation is where production clusters break, and it breaks in four distinct places.

### 1.2 Failure mode 1 — `iptables` is a linear list, and Services are a hot path

`kube-proxy` in `iptables` mode renders every Service into a chain of `KUBE-SERVICES` rules, and every Service into a `KUBE-SVC-*` chain that statistically fans out to `KUBE-SEP-*` chains, one per endpoint. The kernel evaluates these rules **sequentially** per packet until one matches.

The consequences are not theoretical:

| Symptom | Mechanism |
|---|---|
| p99 connection latency grows with total Service count, not with the traffic to *your* Service | Every packet walks the same shared `KUBE-SERVICES` prefix |
| A rollout of one Deployment briefly degrades unrelated Services | `iptables-restore` rewrites the **whole table** under `xtables` lock; there is no incremental update |
| Endpoint programming latency reaches tens of seconds at ~5k Services / ~20k endpoints | Rule count is `O(services × endpoints)`; sync is a full re-render |
| Rolling a node's `kube-proxy` drops in-flight connections | Rule set is replaced, not patched |

`ipvs` mode fixes the lookup complexity (hash table, `O(1)`) but not the ownership problem: it still lives outside the CNI, still needs `iptables` for masquerade/`nodePort` edge cases, and still keys everything on IP addresses.

### 1.3 Failure mode 2 — IP addresses are the wrong identity primitive

A Pod IP is valid for the lifetime of a Pod, which in a healthy cluster is minutes. Any security control that keys on IP is chasing a moving target:

- Policy must be recomputed on every Pod churn event, and the window between "IP reassigned" and "rule updated" is a **misattribution window**: traffic is authorised against the previous tenant of that address.
- Audit logs keyed on IP are unjoinable after the fact unless you retained the full IPAM history.
- Cross-cluster and cloud-native environments reuse CIDRs; IP is not even globally unique.

Cilium's answer is the **security identity**: a cluster-wide numeric ID derived from the Pod's *labels*, allocated once per distinct label set and shared by every Pod carrying that set. Policy is compiled to `(identity, port, protocol, direction)` tuples. A Pod rescheduled onto another node with a new IP keeps the same identity, and no policy recompilation happens at all.

### 1.4 Failure mode 3 — the packet leaves the kernel far too often

The legacy path for a Pod-to-Pod packet on the same node crosses the veth pair, enters the host network namespace, traverses `netfilter` `PREROUTING` → routing decision → `FORWARD` → `POSTROUTING`, then goes back down another veth. Add a sidecar proxy and you additionally cross the socket layer four times per hop.

eBPF lets Cilium attach programs at the *earliest* points in the stack — `tc` `clsact` ingress/egress on each device, `XDP` at the driver, and `cgroup` socket hooks — and use `bpf_redirect_peer()` / `bpf_redirect_neigh()` to hand the packet straight to the destination device, skipping the entire host `netfilter` and routing traversal.

### 1.5 Failure mode 4 — you cannot see any of it

`iptables -L -n -v` counters tell you a packet was dropped. They do not tell you *which* workload, *why*, or against *what policy*. There is no protocol-aware record and no flow-level export without adding a sidecar mesh or a packet-capture sidecar. Cilium emits structured events from the datapath (perf ring buffer → `cilium monitor` → Hubble) that carry source/destination identity, verdict, drop reason, and the source file and line of the eBPF program that made the decision.

### 1.6 The trade being made

eBPF is not free. You buy:

- Lower and **flatter** latency (independent of cluster size).
- Identity-based policy that survives IP churn.
- L3–L7 policy, load balancing, masquerade, encryption and observability in **one** datapath with one set of maps.

You pay with:

- A hard **kernel version floor**. Features are gated on kernel capability, not on Cilium version.
- A datapath that is opaque to your existing tooling — `tcpdump` on `eth0` will not show you a `bpf_redirect_peer()` delivery, and `iptables -L` shows an almost empty table.
- BPF **map sizing** becomes a capacity-planning dimension you did not previously have.
- Agent restarts have blast radius (L7 proxy, DNS proxy) that `kube-proxy` restarts did not.

---

## 2. Cilium's architecture

### 2.1 Control plane components

| Component | Kind | Responsibility | Failure impact |
|---|---|---|---|
| `cilium-agent` | DaemonSet, `hostNetwork`, privileged | Watches K8s + CRDs, allocates identities, compiles and loads eBPF, populates maps, runs the L7/DNS proxy control, serves the health + metrics API | **Existing traffic keeps flowing** — the datapath is in the kernel. New Pods cannot get networking; policy stops converging; DNS proxy for `toFQDNs` policies is down |
| `cilium-operator` | Deployment (2 replicas, leader-elected) | Cluster-scoped IPAM (`cluster-pool`, ENI), garbage collection of `CiliumIdentity`/`CiliumEndpoint`, `CiliumEndpointSlice` generation, LB-IPAM allocation, K8s Node/CRD GC | New nodes get no PodCIDR; stale identities accumulate; LB IPs are not assigned. Existing traffic unaffected |
| `cilium` CNI plugin | Binary on the node, dropped by the agent's init container | Called by the container runtime on Pod ADD/DEL; creates the veth pair, calls the agent's local API | If missing or the agent socket is unreachable, Pods sit in `ContainerCreating` |
| `cilium-envoy` | DaemonSet (**default deployment mode since 1.16**) | L7 proxy for HTTP/Kafka policy, Ingress, Gateway API, `CiliumEnvoyConfig` | L7-filtered traffic breaks; L3/L4 unaffected |
| `hubble-relay` | Deployment | Aggregates per-node Hubble gRPC servers into one cluster-wide flow API | Observability only |
| `clustermesh-apiserver` | Deployment | Exports local identities/endpoints/services to remote clusters | Cross-cluster state stops converging |

**Identity storage** is either `crd` (default — `CiliumIdentity` objects in the API server) or `kvstore` (an external etcd). CRD mode removes a dependency but puts identity churn on the API server; `kvstore` mode scales further. Cilium 1.17 adds a `doublewrite` mode to migrate between them without downtime.

### 2.2 The datapath: where each program is attached

| eBPF object | Attachment | Role |
|---|---|---|
| `bpf_xdp.c` → `cil_xdp_entry` | XDP, native driver on the physical device | Pre-`skb` NodePort/LB lookup; DSR forwarding; DDoS pre-filter |
| `bpf_host.c` → `cil_from_netdev` / `cil_to_netdev` | `tc` ingress/egress on physical devices | North-south LB, eBPF masquerade, host firewall, encryption hand-off |
| `bpf_host.c` → `cil_from_host` / `cil_to_host` | `tc` on `cilium_host`/`cilium_net` pair | Host ↔ Pod path, host policy |
| `bpf_lxc.c` → `cil_from_container` | `tc` ingress on each `lxcXXXXX` veth | Source identity attach, **egress** policy, service translation, redirect |
| `bpf_lxc.c` → `cil_to_container` | `tc` egress on each `lxcXXXXX` veth | **Ingress** policy, delivery into the Pod |
| `bpf_overlay.c` → `cil_from_overlay` / `cil_to_overlay` | `tc` on `cilium_vxlan` / `cilium_geneve` | Encap/decap, identity extraction from the tunnel header |
| `bpf_sock.c` → `cil_sock4_connect`, `cil_sock4_sendmsg`, … | `cgroup/connect4`, `sendmsg4`, `recvmsg4`, `getpeername4` | **Socket LB**: ClusterIP → backend translation at `connect()` time, before a packet exists |
| `bpf_network.c` | `tc` on the encryption device | Post-decryption identity restoration (IPsec) |

### 2.3 The maps that hold all the state

```
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg map list --verbose
Name                       Num entries   Num errors   Cache enabled
cilium_lxc                 14            0            true
cilium_ipcache             318           0            true
cilium_policy_01204        27            0            true
cilium_ct4_global          8912          0            false
cilium_ct_any4_global      412           0            false
cilium_snat_v4_external    1044          0            false
cilium_lb4_services_v2     96            0            true
cilium_lb4_backends_v3     141           0            true
cilium_lb4_reverse_nat     96            0            true
cilium_lb4_maglev          31            0            false
cilium_tunnel_map          2             0            true
cilium_node_map            3             0            true
cilium_metrics             46            0            false
cilium_events              8             0            false
```

| Map | Key → Value | Sizing knob | Why it matters in production |
|---|---|---|---|
| `cilium_lxc` | Pod IP → endpoint ID, identity, MAC, ifindex | fixed 65 535 | Local endpoint table; a miss means "not local, go look in ipcache" |
| `cilium_ipcache` | CIDR/IP → identity, tunnel endpoint, encrypt key, node ID | `bpf-map-dynamic-size-ratio` | The **global** IP→identity table. Every remote decision reads it. Stale entries = wrong policy verdict |
| `cilium_policy_<epID>` | (identity, port, proto, dir) → allow/deny + L7 redirect | `bpf.policyMapMax` (default 16 384) | Per-endpoint. Overflow = policy silently cannot be programmed; watch `cilium_bpf_map_pressure` |
| `cilium_ct4_global` | 5-tuple → connection state, `RevNAT`, `SourceSecurityID` | `bpf-ct-global-tcp-max` (524 288), `bpf-ct-global-any-max` (262 144) | Full = new connections dropped. The single most common capacity incident |
| `cilium_snat_v4_external` | NAT tuple → translation | `bpf-nat-global-max` | eBPF masquerade state |
| `cilium_lb4_services_v2` | frontend (IP:port:proto, slot) → backend slot / backend ID | `bpf-lb-map-max` (65 536) | Service frontends, one entry per backend slot |
| `cilium_lb4_backends_v3` | backend ID → IP:port, state (`active`/`terminating`/`quarantined`) | same | Graceful termination lives here |
| `cilium_lb4_maglev` | service ID → consistent-hash lookup table | `maglev.tableSize` | `tableSize × services × 4` bytes of memory. Budget it |
| `cilium_tunnel_map` | remote Pod CIDR → node underlay IP | — | Only populated in tunnel mode |

### 2.4 The identity model

```
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg identity list
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
25478      k8s:app=frontend
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=prod
           k8s:io.cilium.k8s.policy.cluster=leloir-prod
           k8s:io.cilium.k8s.policy.serviceaccount=frontend
           k8s:io.kubernetes.pod.namespace=prod
31902      k8s:app=payments
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=prod
           k8s:io.cilium.k8s.policy.cluster=leloir-prod
           k8s:io.cilium.k8s.policy.serviceaccount=payments
           k8s:io.kubernetes.pod.namespace=prod
16777217   cidr:10.90.10.0/24
           reserved:world
```

Rules an SRE must internalise:

- IDs **1–255** are reserved. `world` (2) is "anything outside the cluster"; on dual-stack 1.16+ you will additionally see `reserved:world-ipv4` and `reserved:world-ipv6`.
- IDs **256–65535** are cluster-scoped, allocated by the operator/kvstore and identical on every node.
- IDs **≥ 16777216** (`1 << 24`) are **node-local** identities, used for CIDR and FQDN selectors. They are *not* shared between nodes, which is why `toCIDR`-heavy policy does not blow up the global identity space — but it does blow up the per-node ipcache.
- Only labels with the `k8s:` prefix that pass the identity-relevant label filter contribute. **Adding a high-cardinality label** (a commit SHA, a pod-template-hash used as a selector, a timestamp) to Pods creates one identity per value. This is the classic "identity explosion" incident: `cilium_identity` climbs, the operator's GC falls behind, and endpoint regeneration time spikes cluster-wide.

### 2.5 Packet walks

**A. Pod → Pod, same node, BPF host routing**

```
app socket ──(cgroup/connect4: cil_sock4_connect — if dest is a ClusterIP, rewrite to backend)
   │
   └─> pod eth0 ──> lxc1a2b3c [tc ingress: cil_from_container]
                        │ 1. source identity from cilium_lxc (this endpoint)
                        │ 2. dest identity from cilium_ipcache
                        │ 3. EGRESS policy lookup in cilium_policy_<srcEP>
                        │ 4. dest is local -> cilium_lxc hit
                        └─> bpf_redirect_peer() ───> dest pod eth0
                                                       [tc egress cil_to_container: INGRESS policy]
```

The host network namespace, `netfilter`, and the host routing table are **never touched**. `bpf_redirect_peer()` requires kernel ≥ 5.10; without it Cilium falls back to `bpf_redirect()` into the host stack (`bpf.hostLegacyRouting=true`).

**B. Pod → Pod, remote node, tunnel mode (VXLAN)**

```
lxc [cil_from_container: src identity, egress policy]
   │  ipcache lookup -> (dst identity=31902, tunnelendpoint=10.10.0.5)
   └─> cilium_vxlan [cil_to_overlay]
          encapsulate; tunnel_id (VNI) := SOURCE SECURITY IDENTITY   <-- identity travels in-band
   ═══ underlay UDP/8472 ═══>
       remote cilium_vxlan [cil_from_overlay]
          decap; read identity from tunnel_id
          cilium_lxc lookup for dst -> INGRESS policy -> deliver
```

The identity is carried **inside the tunnel header**. The receiving node does not need a fresh ipcache entry for the source IP to enforce ingress policy correctly. This is the single strongest argument for tunnel mode in a fast-churning cluster.

**C. Pod → Pod, remote node, native routing**

No encapsulation. The receiving node must derive the source identity by looking the **source IP** up in its own `cilium_ipcache`. If that node has not yet learned the source Pod (agent just restarted, CRD watch lagging), the source resolves to `reserved:world` and ingress policy denies it. Native routing therefore trades encapsulation overhead for a **convergence dependency**.

The underlay must also route the Pod CIDRs. Three ways to arrange that:
- `autoDirectNodeRoutes: true` — Cilium installs `<remote PodCIDR> via <remote nodeIP>` routes. Only valid when **all nodes share an L2 domain**.
- BGP Control Plane — each node peers with the ToR and advertises its own PodCIDR.
- Cloud-native — ENI/Azure IPAM, where Pod IPs are real VPC addresses.

**D. Pod → external (masquerade)**

```
lxc [cil_from_container: egress policy vs identity 2 (world) or a CIDR identity]
   └─> host routing -> eth0 [tc egress: cil_to_netdev]
          if dst NOT in ipv4NativeRoutingCIDR:
             eBPF SNAT to node IP, state in cilium_snat_v4_external
   ═══> internet
```

`ipv4NativeRoutingCIDR` is the definition of "internal". Getting it wrong is the cause of the "why is my Pod traffic to the on-prem database arriving as the node IP?" ticket.

**E. External → NodePort with DSR + XDP**

```
NIC driver [XDP: cil_xdp_entry]
   cilium_lb4_services_v2 lookup on (nodeIP:31080)
   backend is on ANOTHER node, mode=dsr:
      encode original client IP+port (Geneve TLV or IPv4 option)
      XDP_TX straight back out the NIC  <-- never allocates an skb
   ═══>  backend node decodes, delivers to Pod
         reply goes DIRECTLY to the client, source = the VIP
```

---

## 3. Design decisions and their trade-offs

### 3.1 Service datapath

| Dimension | `kube-proxy` iptables | `kube-proxy` IPVS | Cilium eBPF (`kubeProxyReplacement: true`) |
|---|---|---|---|
| Lookup complexity | `O(n)` rule walk | `O(1)` hash | `O(1)` hash map |
| Update model | Full table re-render under `xtables` lock | Incremental netlink | Single map entry write |
| Endpoint programming latency @5k svc | seconds → tens of seconds | sub-second | milliseconds |
| ClusterIP translation point | `PREROUTING`/`OUTPUT`, after the packet exists | same | **`connect()` syscall** (socket LB) — zero per-packet cost for Pod→Service |
| Source IP preservation for external traffic | `externalTrafficPolicy: Local` only | same | DSR preserves client IP with `Cluster` policy |
| Backend selection | `statistic random` | rr/wrr/lc/sh | `random` or **Maglev** consistent hashing |
| Graceful termination | Endpoint removed abruptly | same | `terminating` backend state, existing conns drain |
| `hostPort` support | via portmap CNI plugin | same | native in the LB maps |
| Kernel floor | any | ≥ 4.19 IPVS modules | ≥ 4.19.57 min; **5.10+** in practice |
| Debuggability with legacy tooling | excellent | good | poor — you must use `cilium-dbg` |

**Recommendation.** Full replacement (`kubeProxyReplacement: true`) for any cluster above ~50 nodes or ~500 Services. Below that, the operational cost of retraining on `cilium-dbg` may exceed the benefit; run `kubeProxyReplacement: false` and keep `kube-proxy`.

> Helm value note: in 1.15 and earlier this key took `"strict" | "probe" | "partial" | "disabled"`. Since **1.16** it is a boolean `true|false`, with individual features toggled by `nodePort.enabled`, `socketLB.enabled`, `externalIPs.enabled`, `hostPort.enabled`.

### 3.2 Routing mode

| | VXLAN (`tunnel`) | Geneve (`tunnel`) | Native + `autoDirectNodeRoutes` | Native + BGP | Cloud ENI/Azure IPAM |
|---|---|---|---|---|---|
| Underlay must know Pod CIDRs | **No** | **No** | Only ARP/L2 | Yes, via BGP | Yes, VPC-native |
| MTU overhead (bytes) | 50 | 50 (+ TLV) | 0 | 0 | 0 |
| Identity carried in-band | **Yes** (VNI) | **Yes** (TLV) | No — ipcache lookup | No | No |
| Node topology constraint | none (L3 routed underlay is fine) | none | **all nodes on one L2 segment** | none | none |
| Throughput vs bare metal | ~85–92 % (offload-dependent) | ~85–92 % | ~99 % | ~99 % | ~99 % |
| CPU cost | encap/decap per packet | encap/decap per packet | lowest | lowest | lowest |
| Network team involvement | zero | zero | zero | **required** | cloud IAM |
| Works with DSR `opt` dispatch | needs `geneve` dispatch | yes | yes | yes | yes |
| Pod IP visible to VPC/firewalls | no | no | yes | yes | yes |
| Pod density limit | PodCIDR mask | PodCIDR mask | PodCIDR mask | PodCIDR mask | **ENI/IP quota per instance type** |

**Recommendation.**
- Unknown or hostile underlay, multi-AZ, rapid node churn, no network-team access → **VXLAN**. The in-band identity alone removes an entire class of transient policy misfires.
- You control the fabric and need line rate or Pod IPs visible to external firewalls → **native + BGP**.
- Geneve over VXLAN only when you need Geneve-specific features (DSR Geneve dispatch in tunnel mode, or option-carrying for SRv6/egress-gateway HA).
- Cloud ENI mode gives you real VPC IPs and security-group integration, at the price of a hard Pod-per-node ceiling driven by the instance type.

### 3.3 MTU arithmetic — get this wrong and you get an intermittent hang, not an outage

| Underlay MTU | Mode | Effective Pod MTU | Formula |
|---|---|---|---|
| 1500 | native | 1500 | — |
| 1500 | VXLAN | 1450 | −50 (outer IP 20 + UDP 8 + VXLAN 8 + inner Eth 14) |
| 1500 | Geneve (no opts) | 1450 | −50 |
| 1500 | Geneve + DSR TLV | 1442 or lower | −50 −8 per option |
| 1500 | native + WireGuard | 1420 | −80 |
| 1500 | VXLAN + WireGuard | 1370 | −50 −80 |
| 9000 (jumbo) | VXLAN | 8950 | −50 |

Cilium auto-detects the device MTU and computes the route MTU. It **cannot** detect an MTU bottleneck three hops away in your underlay. Pin it explicitly with the `MTU` Helm value when your path MTU is not the local device MTU.

### 3.4 North-south load balancing

| | SNAT | DSR | Hybrid (`mode: hybrid`) |
|---|---|---|---|
| Client IP preserved at the backend | No | **Yes** | TCP: yes / UDP: no |
| Return path | via the ingress node | direct from the backend | mixed |
| Extra hop cost | 1 | 0 | TCP: 0 |
| Requires symmetric routing in the fabric | no | **yes** (or the reply is dropped by uRPF/stateful firewalls) | for TCP |
| MTU impact | none | `opt`: +8/+24 header; `geneve`: +50 | mixed |
| Works behind a stateful cloud LB | yes | usually no | partially |

`loadBalancer.dsrDispatch: opt` embeds the client address in an IPv4 option / IPv6 extension header — cheap, but some switches and middleboxes drop or slow-path optioned packets. `geneve` dispatch encapsulates instead: more overhead, far more robust, and the only DSR dispatch that works in tunnel mode.

**Backend selection:** `random` is stateless and cheap. `maglev` gives consistent hashing so that adding or removing a backend re-maps only ~`1/N` of flows, and — critically — every node computes the **same** table, so a client that lands on a different ingress node still reaches the same backend. Required for DSR with `externalTrafficPolicy: Cluster` if you care about flow stability. Cost: `tableSize × numServices × 4` bytes per node. `65521` primes × 500 services ≈ 131 MB. Use `16381` unless you have many backends per service.

### 3.5 Encryption

| | IPsec (ESP) | WireGuard |
|---|---|---|
| Key management | you rotate a K8s Secret; keys are cluster-wide | per-node keypair, auto-generated, auto-distributed via `CiliumNode` |
| Throughput | higher with AES-NI + hardware offload | good, but CPU-bound (ChaCha20-Poly1305) |
| Kernel requirement | XFRM stack | ≥ 5.6 (or the `wireguard` module) |
| Encrypts | Pod-to-Pod; node-to-node with extra config | Pod-to-Pod; **all** node traffic with `nodeEncryption: true` |
| Identity after decryption | restored via `bpf_network.c` + SPI mapping | restored via ipcache |
| Operational failure mode | key rotation is a two-phase dance; a stale SPI silently drops | peer key mismatch → the flow simply does not establish |
| FIPS story | mature | not FIPS-validated |
| MTU cost | ~56–80 B (cipher-dependent) | 80 B |

**Recommendation.** WireGuard unless a compliance regime names IPsec. The key-rotation ergonomics dominate the throughput difference in practice.

### 3.6 IPAM

| Mode | Who allocates | Pod IPs routable in the VPC | Density ceiling | Use when |
|---|---|---|---|---|
| `cluster-pool` (default) | operator carves a `/24` per node out of a cluster CIDR | no | 254/node | Default. On-prem, kind, anywhere you own the CIDR |
| `kubernetes` | kube-controller-manager writes `node.spec.podCIDR` | no | mask-dependent | You already run `--allocate-node-cidrs` and want Cilium to follow |
| `multi-pool` | `CiliumPodIPPool` CRDs, per-namespace/per-pod selection | no | per-pool | Multi-tenant clusters needing distinct CIDRs per tenant for external firewalls |
| `eni` / `azure` / `alibabacloud` | operator attaches ENIs / assigns secondary IPs | **yes** | instance quota | You need SG integration or VPC-visible Pod IPs |
| `crd` | you, via `CiliumNode.spec.ipam` | depends | — | Custom IPAM controller |

---

## 4. Complete infrastructure and manifests

### 4.1 Reproducible lab cluster (kind, no kube-proxy, no default CNI)

`kind-cca.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Cilium is the CNI; kind must not install kindnet.
  disableDefaultCNI: true
  # Cilium replaces kube-proxy entirely.
  kubeProxyMode: none
  podSubnet: "10.20.0.0/14"
  serviceSubnet: "10.96.0.0/16"
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=a,egress-gw=true"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=b"
```

```bash
$ kind create cluster --config kind-cca.yaml
Creating cluster "cca-lab" ...
 ✓ Ensuring node image (kindest/node:v1.31.2) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cca-lab"

$ kubectl get nodes
NAME                   STATUS     ROLES           AGE   VERSION
cca-lab-control-plane  NotReady   control-plane   41s   v1.31.2
cca-lab-worker         NotReady   <none>          22s   v1.31.2
cca-lab-worker2        NotReady   <none>          22s   v1.31.2
```

`NotReady` is expected and correct: there is no CNI yet, so the kubelet reports `NetworkReady=false`.

### 4.2 Production Helm values — native routing + BGP + kube-proxy replacement

`values-prod.yaml` (complete, nothing elided):

```yaml
# ---------------------------------------------------------------------------
# Cluster identity. `cluster.id` MUST be unique across every cluster that will
# ever join the same ClusterMesh; it is encoded into the identity space.
# ---------------------------------------------------------------------------
cluster:
  name: leloir-prod
  id: 1

# ---------------------------------------------------------------------------
# Full kube-proxy replacement. k8sServiceHost/Port are mandatory: with no
# kube-proxy, the agent cannot reach the API server through the `kubernetes`
# ClusterIP before it has programmed that ClusterIP itself (chicken and egg).
# ---------------------------------------------------------------------------
kubeProxyReplacement: true
k8sServiceHost: api.leloir.internal
k8sServicePort: 6443

nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true
socketLB:
  enabled: true
  # false => socket LB also applies inside pod netns (recommended).
  # true  => only host-namespace sockets, needed for some service meshes.
  hostNamespaceOnly: false

# ---------------------------------------------------------------------------
# Datapath: native routing. The underlay learns PodCIDRs via BGP (see 4.4),
# so autoDirectNodeRoutes stays OFF (nodes are not all on one L2 segment).
# ---------------------------------------------------------------------------
routingMode: native
ipv4NativeRoutingCIDR: "10.20.0.0/14"
autoDirectNodeRoutes: false
directRoutingDevice: "eth0"
devices: "eth0"

ipv4:
  enabled: true
ipv6:
  enabled: false

enableIPv4Masquerade: true
enableIPv6Masquerade: false

# Explicit MTU: our path MTU is 1500 even though some nodes have 9000 NICs.
MTU: 1500

# ---------------------------------------------------------------------------
# IPAM
# ---------------------------------------------------------------------------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.20.0.0/14"
    # /24 per node => 254 usable pod IPs per node, 1024 nodes max.
    clusterPoolIPv4MaskSize: 24

# ---------------------------------------------------------------------------
# eBPF datapath tuning
# ---------------------------------------------------------------------------
bpf:
  # eBPF masquerading in cil_to_netdev; removes the iptables MASQUERADE rules.
  masquerade: true
  # false => BPF host routing (bpf_redirect_peer). Requires kernel >= 5.10.
  hostLegacyRouting: false
  # Pre-allocate map memory at load time: predictable latency, higher RSS.
  preallocateMaps: true
  # Transparent proxy via TPROXY for L7/DNS redirects.
  tproxy: true
  # Per-endpoint policy map. Raise if you have many distinct peer identities.
  policyMapMax: 32768
  # Sizes CT/NAT/neigh maps as a ratio of total node memory.
  mapDynamicSizeRatio: 0.0025
  # Do not translate ClusterIP for traffic originating outside the cluster.
  lbExternalClusterIP: false

# Explicit conntrack ceilings; leave unset to let mapDynamicSizeRatio decide.
bpfClockProbe: true

# ---------------------------------------------------------------------------
# Load balancing
# ---------------------------------------------------------------------------
loadBalancer:
  algorithm: maglev
  mode: hybrid                # TCP -> DSR, UDP -> SNAT
  dsrDispatch: geneve         # robust across middleboxes; costs 50B MTU
  acceleration: native        # XDP on the driver; requires a supported NIC
  serviceTopology: true       # honour topology-aware hints

maglev:
  # Must be prime. 65521 * numServices * 4 bytes of memory per node.
  tableSize: 65521
  # Same seed on every cluster in a mesh so tables agree. Generate with:
  #   head -c12 /dev/urandom | base64 -w0
  hashSeed: "JLfvgnHc2kaSUFaI"

# ---------------------------------------------------------------------------
# BGP control plane (configuration lives in CRDs, see 4.4)
# ---------------------------------------------------------------------------
bgpControlPlane:
  enabled: true

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------
encryption:
  enabled: true
  type: wireguard
  # true also encrypts node-to-node (host) traffic. Costs CPU; verify with
  # `cilium-dbg encrypt status` before enabling in a latency-sensitive fleet.
  nodeEncryption: false
  wireguard:
    persistentKeepalive: 0s

# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------
policyEnforcementMode: default   # default | always | never
policyAuditMode: false
hostFirewall:
  enabled: true

l7Proxy: true
envoy:
  enabled: true                  # standalone DaemonSet (default since 1.16)

egressGateway:
  enabled: true

localRedirectPolicy: true

dnsProxy:
  enableTransparentMode: true
  minTtl: 3600
  maxDeferredConnectionDeletes: 10000
  endpointMaxIpPerHostname: 50

# ---------------------------------------------------------------------------
# Identity & scale
# ---------------------------------------------------------------------------
identityAllocationMode: crd
# Collapses N CiliumEndpoint watches into far fewer CiliumEndpointSlice
# watches. Mandatory above ~5k pods.
enableCiliumEndpointSlice: true

k8sClientRateLimit:
  qps: 50
  burst: 100

# ---------------------------------------------------------------------------
# Bandwidth manager (EDT-based egress shaping + BBR)
# ---------------------------------------------------------------------------
bandwidthManager:
  enabled: true
  bbr: true

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------
hubble:
  enabled: true
  # Ring buffer size per node. 4095 flows at 60 flows/s is ~68 seconds of
  # history — export to a collector, do not rely on the buffer.
  eventBufferCapacity: 16383
  metrics:
    enabled:
      - "dns:query;ignoreAAAA"
      - "drop"
      - "tcp"
      - "flow"
      - "port-distribution"
      - "icmp"
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: true
  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
  ui:
    enabled: true
    replicas: 1

prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true

operator:
  replicas: 2
  rollOutPods: true
  prometheus:
    enabled: true
    port: 9963
    serviceMonitor:
      enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      memory: 512Mi

# ---------------------------------------------------------------------------
# Agent lifecycle
# ---------------------------------------------------------------------------
rollOutCiliumPods: true
cni:
  # Remove any other CNI config files from /etc/cni/net.d. Prevents the
  # classic "two CNIs installed, pods get IPs from the wrong one" incident.
  exclusive: true
  logFile: /var/run/cilium/cilium-cni.log

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    memory: 4Gi

# Set to the version you are upgrading FROM so the chart keeps datapath
# compatibility defaults during a rolling upgrade. Remove after the upgrade.
upgradeCompatibility: "1.15"

annotateK8sNode: false
```

Install:

```bash
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm upgrade --install cilium cilium/cilium \
    --version 1.16.5 \
    --namespace kube-system \
    --values values-prod.yaml \
    --wait --timeout 10m
Release "cilium" does not exist. Installing it now.
NAME: cilium
LAST DEPLOYED: Tue Sep  1 13:41:02 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

### 4.3 Alternative datapath: tunnel mode (portable default)

Replace the routing block above with:

```yaml
routingMode: tunnel
tunnelProtocol: vxlan     # or: geneve
tunnelPort: 8472          # 6081 for geneve
ipv4NativeRoutingCIDR: ""  # not used in tunnel mode
autoDirectNodeRoutes: false
directRoutingDevice: ""
# DSR opt-dispatch is not available in tunnel mode; use geneve dispatch
# or fall back to SNAT.
loadBalancer:
  algorithm: maglev
  mode: snat
  acceleration: disabled
MTU: 0                    # let Cilium subtract the 50-byte tunnel overhead
```

### 4.4 BGP Control Plane (v2 API)

> API note: in **1.16** these CRDs are `cilium.io/v2alpha1`. In 1.17+ they graduate to `cilium.io/v2`. The legacy single-object `CiliumBGPPeeringPolicy` (also `v2alpha1`) is deprecated — do not mix the two on the same node.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: leloir-tor
spec:
  nodeSelector:
    matchLabels:
      bgp-role: tor-peer
  bgpInstances:
    - name: instance-65001
      localASN: 65001
      # Router ID is derived from the node IP unless overridden per node with
      # a CiliumBGPNodeConfigOverride.
      peers:
        - name: tor-a
          peerASN: 65000
          peerAddress: 192.168.178.2
          peerConfigRef:
            name: tor-peer-config
        - name: tor-b
          peerASN: 65000
          peerAddress: 192.168.178.3
          peerConfigRef:
            name: tor-peer-config
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer-config
spec:
  # Aggressive timers: a dead ToR must be detected in single-digit seconds,
  # otherwise the fabric blackholes pod traffic for up to 90s.
  timers:
    connectRetryTimeSeconds: 12
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  # Survive a cilium-agent restart without withdrawing routes.
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  ebgpMultihop: 1
  authSecretRef: bgp-tor-md5      # Secret in kube-system with key "password"
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: leloir-prod
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: leloir-prod-advertisements
  labels:
    advertise: leloir-prod
spec:
  advertisements:
    # Each node advertises only the PodCIDR the operator gave it.
    - advertisementType: PodCIDR
      attributes:
        communities:
          standard: ["65000:100"]
    # LoadBalancer VIPs, /32, advertised by every node that has a local
    # backend when externalTrafficPolicy=Local (ECMP anycast otherwise).
    - advertisementType: Service
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchLabels:
          bgp-advertise: "true"
      attributes:
        communities:
          standard: ["65000:200"]
        localPreference: 200
---
apiVersion: v1
kind: Secret
metadata:
  name: bgp-tor-md5
  namespace: kube-system
type: Opaque
stringData:
  password: "replace-me-with-a-real-secret"
```

### 4.5 LB-IPAM and an advertised Service

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: prod-vips
spec:
  blocks:
    - cidr: "192.168.180.0/24"
    - start: "192.168.181.10"
      stop: "192.168.181.60"
  serviceSelector:
    matchLabels:
      io.kubernetes.service.namespace: prod
  # Reserve network and broadcast addresses of each block.
  allowFirstLastIPs: "No"
  disabled: false
---
apiVersion: v1
kind: Service
metadata:
  name: storefront
  namespace: prod
  labels:
    bgp-advertise: "true"
  annotations:
    # Request a specific VIP out of the pool (optional).
    lbipam.cilium.io/ips: "192.168.180.42"
    # Restrict which pools may serve this service.
    lbipam.cilium.io/sharing-key: "storefront-shared"
spec:
  type: LoadBalancer
  # Local preserves the client IP and makes BGP advertise the VIP only from
  # nodes that actually run a backend — no extra hop, no blackhole.
  externalTrafficPolicy: Local
  loadBalancerSourceRanges:
    - "192.168.0.0/16"
    - "10.0.0.0/8"
  selector:
    app: storefront
  ports:
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
```

### 4.6 Multi-pool IPAM (tenant-scoped Pod CIDRs)

Requires `ipam.mode: multi-pool` in the Helm values.

```yaml
---
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: tenant-payments
spec:
  ipv4:
    cidrs:
      - "10.30.0.0/16"
    # /27 = 30 usable addresses per node from this pool.
    maskSize: 27
---
apiVersion: v1
kind: Pod
metadata:
  name: ledger-writer
  namespace: prod
  annotations:
    ipam.cilium.io/ip-pool: "tenant-payments"
spec:
  containers:
    - name: app
      image: ghcr.io/example/ledger-writer:1.4.2
      ports:
        - containerPort: 8080
```

### 4.7 Egress Gateway — a stable source IP for a legacy firewall

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-to-legacy-erp
spec:
  # Which pods' traffic is redirected.
  selectors:
    - podSelector:
        matchLabels:
          io.kubernetes.pod.namespace: prod
          app: payments
  # Only traffic to these destinations is redirected.
  destinationCIDRs:
    - "10.90.10.0/24"
  # Carve-outs that must keep the normal path (e.g. the on-prem resolver).
  excludedCIDRs:
    - "10.90.10.53/32"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gw: "true"
    # SNAT to the address configured on this interface of the gateway node.
    interface: eth1
```

Prerequisites: `egressGateway.enabled: true`, `bpf.masquerade: true`, `kubeProxyReplacement: true`. The gateway node is a **single point of failure and a bandwidth bottleneck** — label at most a small, dedicated set of nodes and monitor their NIC saturation.

### 4.8 Bandwidth management and node-local DNS redirection

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-shipper
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels:
      app: log-shipper
  template:
    metadata:
      labels:
        app: log-shipper
      annotations:
        # EDT-based shaping in the eBPF datapath, enforced at the source.
        kubernetes.io/egress-bandwidth: "50M"
    spec:
      containers:
        - name: shipper
          image: ghcr.io/example/log-shipper:2.9.0
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
---
# Transparently steer every pod's DNS traffic to a node-local cache without
# changing a single pod's /etc/resolv.conf.
apiVersion: cilium.io/v2
kind: CiliumLocalRedirectPolicy
metadata:
  name: nodelocaldns
  namespace: kube-system
spec:
  redirectFrontend:
    serviceMatcher:
      serviceName: kube-dns
      namespace: kube-system
  redirectBackend:
    localEndpointSelector:
      matchLabels:
        k8s-app: node-local-dns
    toPorts:
      - port: "53"
        name: dns
        protocol: UDP
      - port: "53"
        name: dns-tcp
        protocol: TCP
```

### 4.9 Policy: L3/L4, DNS-aware egress, L7 HTTP, and host firewall

```yaml
---
# Default-deny for the namespace. An empty ingress AND egress array selects
# everything and allows nothing — this is what "switches on" enforcement.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: prod
spec:
  description: "Default deny both directions for every pod in prod."
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-egress
  namespace: prod
spec:
  description: >-
    payments may resolve a restricted DNS namespace, call the ledger's write
    API only with POST, reach one external SaaS by FQDN, and talk to the
    apiserver. Nothing else.
  endpointSelector:
    matchLabels:
      app: payments
  egress:
    # 1. DNS, via the L7 DNS proxy. This rule is what populates the toFQDNs
    #    cache below; without it, toFQDNs can never match anything.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*.prod.svc.cluster.local"
              - matchPattern: "*.kube-system.svc.cluster.local"
              - matchName: "api.stripe.com"

    # 2. External SaaS by name. Cilium learns the IPs from the DNS proxy above
    #    and injects them as local CIDR identities into cilium_ipcache.
    - toFQDNs:
        - matchName: "api.stripe.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP

    # 3. East-west with L7 HTTP enforcement (redirected to Envoy).
    - toEndpoints:
        - matchLabels:
            app: ledger
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/entries"
                headers:
                  - "X-Tenant: .*"
              - method: "GET"
                path: "/healthz"

    # 4. The apiserver, via the reserved identity — survives control-plane
    #    IP changes, unlike a hand-written toCIDR.
    - toEntities:
        - kube-apiserver
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payments-ingress
  namespace: prod
spec:
  endpointSelector:
    matchLabels:
      app: payments
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    # Allow the cluster-internal health checker and Prometheus.
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
    - fromEntities:
        - health
---
# Host firewall. READ THE WARNING BELOW BEFORE APPLYING THIS.
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: host-lockdown-workers
spec:
  description: "Restrict what may reach the worker nodes' host namespace."
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Cluster-internal machinery: other nodes, health checks, VXLAN/WireGuard.
    - fromEntities:
        - remote-node
        - health
        - cluster
    # kubelet and metrics from the control plane and monitoring only.
    - fromEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP
    # SSH from the bastion subnet only.
    - fromCIDR:
        - "192.168.178.0/24"
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP
    # NodePort range from the load-balancer tier.
    - fromCIDR:
        - "192.168.179.0/24"
      toPorts:
        - ports:
            - port: "30000"
              endPort: 32767
              protocol: TCP
```

> **Host-firewall warning.** A `CiliumClusterwideNetworkPolicy` with a `nodeSelector` puts the node's `reserved:host` endpoint into enforcing mode. Omit SSH, the kubelet port, or the tunnel/WireGuard ports and you lock yourself out of the node with no in-band recovery path. Always stage it:
> ```bash
> $ HOST_EP=$(kubectl exec -n kube-system ds/cilium -- \
>     cilium-dbg endpoint list -o jsonpath='{[?(@.status.identity.id==1)].id}')
> $ kubectl exec -n kube-system ds/cilium -- \
>     cilium-dbg endpoint config $HOST_EP PolicyAuditMode=Enabled
> Endpoint 3129 configuration updated successfully
> ```
> Run for a full business cycle, read every `policy-verdict ... AUDITED` flow in Hubble, then disable audit mode.

### 4.10 Test workloads

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    kubernetes.io/metadata.name: prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: curl
          image: quay.io/curl/curl:8.11.0
          command: ["sleep", "infinity"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: prod
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
        - name: server
          image: quay.io/cilium/json-mock:v1.3.8
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: prod
spec:
  selector:
    app: payments
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
```

---

## 5. Verification: proving the datapath is what you think it is

### 5.1 Cluster-level health (`cilium-cli`)

```bash
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy             Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 3
                       cilium-envoy             Running: 3
                       cilium-operator          Running: 2
                       hubble-relay             Running: 2
                       hubble-ui                Running: 1
Cluster Pods:          47/47 managed by Cilium
Helm chart version:    1.16.5
Image versions         cilium           quay.io/cilium/cilium:v1.16.5: 3
                       cilium-envoy     quay.io/cilium/cilium-envoy:v1.30.8: 3
                       cilium-operator  quay.io/cilium/operator-generic:v1.16.5: 2
                       hubble-relay     quay.io/cilium/hubble-relay:v1.16.5: 2
```

`Cluster Pods: 47/47 managed by Cilium` is the line that matters. Anything less means Pods exist that Cilium did not create endpoints for — usually leftovers from a previous CNI, or `hostNetwork` Pods (which are correctly excluded).

### 5.2 Per-node datapath configuration

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg status --verbose
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:         ["cilium/v2::CiliumClusterwideNetworkPolicy", "cilium/v2::CiliumEgressGatewayPolicy", "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy", "cilium/v2::CiliumNode", "core::Namespace", "core::Pods", "core::Service", "discovery::EndpointSlice", "networking.k8s.io::NetworkPolicy"]
KubeProxyReplacement:    True   [eth0   10.10.0.4 (Direct Routing)]
Host firewall:           Enabled   [eth0]
SRv6:                    Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.16.5 (v1.16.5-b7b9a3d2)
NodeMonitor:             Listening for events on 16 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 14/254 allocated from 10.20.1.0/24,
IPv4 BIG TCP:            Disabled
BandwidthManager:        EDT with BPF [BBR] [eth0]
Routing:                 Network: Native   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.20.0.0/14 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       61/61 healthy
Proxy Status:            OK, ip 10.20.1.204, 2 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 214.77   Metrics: Ok
Encryption:              Wireguard   [NodeEncryption: Disabled, cilium_wg0 (Pubkey: 9pS1n+..., Port: 51871, Peers: 2)]
Cluster health:          3/3 reachable   (2026-09-01T14:02:44Z)
Modules Health:          Stopped(0) Degraded(0) OK(118)

KubeProxyReplacement Details:
  Status:                 True
  Socket LB:              Enabled
  Socket LB Tracing:      Enabled
  Socket LB Coverage:     Full
  Devices:                eth0 10.10.0.4 (Direct Routing)
  Mode:                   Hybrid
  Backend Selection:      Maglev (Table Size: 65521)
  Session Affinity:       Enabled
  Graceful Termination:   Enabled
  NAT46/64 Support:       Disabled
  XDP Acceleration:       Native
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

The five lines you read first, every time:

| Line | What it proves | Red flag |
|---|---|---|
| `KubeProxyReplacement: True [eth0 ... (Direct Routing)]` | eBPF LB is active on the right device | `False`, or the wrong device listed |
| `Routing: Network: Native Host: BPF` | Both the network and the host-routing decisions match your intent | `Host: Legacy` when you configured `hostLegacyRouting: false` (kernel too old) |
| `Masquerading: BPF [eth0] 10.20.0.0/14` | SNAT is in eBPF and the "internal" CIDR is what you set | `Masquerading: IPTables` |
| `Controller Status: 61/61 healthy` | No background reconciler is stuck | any `N/M` where `N < M` |
| `Cluster health: 3/3 reachable` | Every node's health endpoint answers over both the tunnel and the direct path | `2/3` → run `cilium-dbg status --all-health` |

Effective runtime configuration, after all Helm/ConfigMap/flag merging:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg config --all | \
    grep -E 'enable-bpf-masquerade|routing-mode|kube-proxy-replacement|bpf-lb-mode|bpf-lb-algorithm|enable-host-firewall|enable-wireguard'
bpf-lb-algorithm                          maglev
bpf-lb-mode                               hybrid
enable-bpf-masquerade                     true
enable-host-firewall                      true
enable-wireguard                          true
kube-proxy-replacement                    true
routing-mode                              native
```

### 5.3 Endpoints, identities, ipcache

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4         STATUS
           ENFORCEMENT        ENFORCEMENT
187        Disabled           Disabled          4          reserved:health                                                 10.20.1.31   ready
1204       Enabled            Enabled           31902      k8s:app=payments                                                10.20.1.88   ready
                                                           k8s:io.cilium.k8s.policy.cluster=leloir-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=payments
                                                           k8s:io.kubernetes.pod.namespace=prod
2361       Enabled            Enabled           25478      k8s:app=frontend                                                10.20.1.113  ready
                                                           k8s:io.cilium.k8s.policy.cluster=leloir-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=frontend
                                                           k8s:io.kubernetes.pod.namespace=prod
3129       Enabled            Disabled          1          reserved:host                                                                ready
```

Read it as a table of three facts per row: **is policy enforced**, **what identity**, **is the endpoint `ready`**. An endpoint stuck in `regenerating` for more than a few seconds is a policy-compilation problem; check `cilium-dbg endpoint get <id>` and the agent log.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ipcache list | head -12
IP PREFIX/ADDRESS   IDENTITY
10.10.0.3/32        identity=6 encryptkey=3 tunnelendpoint=0.0.0.0 nodeid=0x0e11
10.10.0.4/32        identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.10.0.5/32        identity=6 encryptkey=3 tunnelendpoint=0.0.0.0 nodeid=0x2a7c
10.20.1.31/32       identity=4 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.1.88/32       identity=31902 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.1.113/32      identity=25478 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
10.20.2.19/32       identity=25478 encryptkey=3 tunnelendpoint=10.10.0.5 nodeid=0x2a7c
10.20.2.44/32       identity=31902 encryptkey=3 tunnelendpoint=10.10.0.5 nodeid=0x2a7c
0.0.0.0/0           identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
```

`tunnelendpoint=0.0.0.0` on remote Pod IPs is *correct* in native routing and *a bug indicator* in tunnel mode. `encryptkey=3` on remote entries confirms WireGuard is expected for that peer.

### 5.4 Service load balancing

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg service list
ID   Frontend                Service Type   Backend
1    10.96.0.1:443/TCP       ClusterIP      1 => 10.10.0.3:6443 (active)
12   10.96.0.10:53/UDP       ClusterIP      1 => 10.20.1.7:53 (active)
                                            2 => 10.20.2.9:53 (active)
14   10.96.0.10:53/TCP       ClusterIP      1 => 10.20.1.7:53 (active)
                                            2 => 10.20.2.9:53 (active)
31   10.96.214.7:8080/TCP    ClusterIP      1 => 10.20.1.88:8080 (active)
                                            2 => 10.20.2.44:8080 (active)
44   192.168.180.42:443/TCP  LoadBalancer   1 => 10.20.1.51:8443 (active)
                                            2 => 10.20.2.62:8443 (terminating)
45   10.10.0.4:31080/TCP     NodePort       1 => 10.20.1.51:8443 (active)

$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf lb list --frontends | grep 10.96.214.7
10.96.214.7:8080/TCP (0)   0.0.0.0:0 (31) (0) [ClusterIP, non-routable]
10.96.214.7:8080/TCP (1)   10.20.1.88:8080 (31) (1)
10.96.214.7:8080/TCP (2)   10.20.2.44:8080 (31) (2)
```

Slot `(0)` is the master entry holding the backend count and flags; slots `1..N` are the backends. A frontend with slot 0 present and **no** backend slots is the classic "Service exists, EndpointSlice is empty" case.

**Proving socket LB is doing the translation** — the packet is *born* with the backend address, so `tcpdump` inside the Pod never shows the ClusterIP:

```bash
$ kubectl -n prod exec deploy/frontend -- curl -s -o /dev/null -w '%{remote_ip}\n' http://payments.prod.svc:8080/
10.20.2.44
```

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf sock list | head -5
Cookie   Backend ID   Service ID   Backend Address    Service Address
32418    2            31           10.20.2.44:8080    10.96.214.7:8080
32419    1            12           10.20.1.7:53       10.96.0.10:53
```

### 5.5 Confirming the eBPF programs are attached where you expect

```bash
$ kubectl exec -n kube-system ds/cilium -- bpftool net show dev eth0
xdp:
eth0(2) driver id 1841

tc:
eth0(2) tcx/ingress cil_from_netdev prog_id 1802 link_id 41
eth0(2) tcx/egress cil_to_netdev prog_id 1809 link_id 42

flow_dissector:

netfilter:
```

`driver id` under `xdp:` means **native** XDP. If it says `generic id`, the NIC driver does not support XDP and you are running the slow `skb`-mode fallback — `loadBalancer.acceleration: native` silently degraded. `tcx/` (rather than `clsact/`) indicates the modern TCX attach mode, available on kernel ≥ 6.6 and reported by `Attach Mode: TCX` in `cilium-dbg status`.

```bash
$ kubectl exec -n kube-system ds/cilium -- bpftool prog show | grep -c cil_
34

$ kubectl exec -n kube-system ds/cilium -- bpftool cgroup show /run/cilium/cgroupv2
ID    AttachType      AttachFlags     Name
1751  cgroup_inet4_connect             cil_sock4_connect
1754  cgroup_inet4_post_bind           cil_sock4_post_bind
1757  cgroup_udp4_sendmsg              cil_sock4_sendmsg
1760  cgroup_udp4_recvmsg              cil_sock4_recvmsg
1763  cgroup_inet4_getpeername         cil_sock4_getpeername
```

An empty `bpftool cgroup show` output is the definitive symptom of a socket-LB failure — almost always `cgroup v2` not mounted, or the agent unable to mount it at `/run/cilium/cgroupv2`.

### 5.6 Verifying there is genuinely no `kube-proxy` residue

```bash
$ kubectl -n kube-system get ds kube-proxy
Error from server (NotFound): daemonsets.apps "kube-proxy" not found

$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c KUBE-SVC
0

$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c CILIUM
6
```

Six `CILIUM_*` chains is normal even with `bpf.masquerade: true` — Cilium keeps a small set for the proxy redirect and for `NOTRACK` rules. Any non-zero `KUBE-SVC` count on a node means stale rules from a removed `kube-proxy` are still shadowing the eBPF datapath; see §6.5.

### 5.7 Flow observability with Hubble

```bash
$ cilium hubble port-forward &
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 49,149/49,149 (100.00%)
Flows/s: 214.77
Connected Nodes: 3/3

$ hubble observe --namespace prod --follow --output compact
Sep  1 14:11:03.117: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) -> prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 14:11:03.117: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) <- prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Sep  1 14:11:03.118: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) -> prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) http-request FORWARDED (HTTP/1.1 GET http://payments.prod.svc:8080/healthz)
Sep  1 14:11:03.121: prod/frontend-6d9f7c8b5-2xk4t:52118 (ID:25478) <- prod/payments-7c5d9f4b6-h8vqz:8080 (ID:31902) http-response FORWARDED (HTTP/1.1 200 3ms (GET http://payments.prod.svc:8080/healthz))

$ hubble observe --verdict DROPPED --last 20
Sep  1 14:12:41.883: prod/frontend-6d9f7c8b5-2xk4t:44120 (ID:25478) <> prod/ledger-5b7c9d8f4-qm2pw:8080 (ID:44117) policy-verdict:none EGRESS DENIED (TCP Flags: SYN)
Sep  1 14:12:41.883: prod/frontend-6d9f7c8b5-2xk4t:44120 (ID:25478) <> prod/ledger-5b7c9d8f4-qm2pw:8080 (ID:44117) Policy denied DROPPED (TCP Flags: SYN)

$ hubble observe --verdict DROPPED --last 200 -o json | \
    jq -r '[.source.namespace + "/" + .source.pod_name,
            .destination.namespace + "/" + .destination.pod_name,
            (.l4.TCP.destination_port // .l4.UDP.destination_port // 0 | tostring),
            .drop_reason_desc] | @tsv' | sort | uniq -c | sort -rn
     87 prod/frontend-6d9f7c8b5-2xk4t  prod/ledger-5b7c9d8f4-qm2pw  8080  POLICY_DENIED
     11 prod/batch-runner-9f4c2       -/-                           443   POLICY_DENIED
```

That last pipeline — group drops by `(src, dst, port, reason)` — is the single most useful command when a policy rollout breaks something and you need the blast radius in one screen.

### 5.8 The full connectivity suite

```bash
$ cilium connectivity test --test-namespace cilium-test
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [cca-lab] Creating namespace cilium-test-1 for connectivity check...
✨ [cca-lab] Deploying echo-same-node service...
✨ [cca-lab] Deploying DNS test server configmap...
⌛ [cca-lab] Waiting for deployment cilium-test-1/client to become ready...
⌛ [cca-lab] Waiting for CiliumEndpoint for pod cilium-test-1/echo-other-node-...
🏃[cilium-test-1] Running 82 tests ...
[=] [cilium-test-1] Test [no-policies] [1/82]
.................................
[=] [cilium-test-1] Test [client-egress-l7] [44/82]
.........
[=] [cilium-test-1] Test [north-south-loadbalancing] [61/82]
......
✅ [cilium-test-1] All 82 tests (417 actions) successful, 12 tests skipped, 1 scenarios skipped.
```

Run it after every upgrade and every datapath configuration change. `--test-concurrency`, `--include-unsafe-tests` and `--perf` extend it; `--perf` runs `netperf` between Pods and reports throughput/latency, which is how you quantify the cost of turning encryption on.

### 5.9 BGP session verification

```bash
$ cilium bgp peers
Node             Local AS   Peer AS   Peer Address     Session State   Uptime     Family         Received   Advertised
cca-lab-worker   65001      65000     192.168.178.2    established     3h12m45s   ipv4/unicast   142        2
cca-lab-worker   65001      65000     192.168.178.3    established     3h12m44s   ipv4/unicast   142        2
cca-lab-worker2  65001      65000     192.168.178.2    established     3h12m41s   ipv4/unicast   142        1
cca-lab-worker2  65001      65000     192.168.178.3    established     3h12m40s   ipv4/unicast   142        1

$ cilium bgp routes advertised ipv4 unicast
Node             VRouter   Peer            Prefix              NextHop         Age        Attrs
cca-lab-worker   65001     192.168.178.2   10.20.1.0/24        192.168.178.11  3h12m45s   [{Origin: i} {AsPath: 65001} {Communities: 65000:100} {Nexthop: 192.168.178.11}]
cca-lab-worker   65001     192.168.178.2   192.168.180.42/32   192.168.178.11  1h04m11s   [{Origin: i} {AsPath: 65001} {Communities: 65000:200} {LocalPref: 200}]
```

`Advertised` counts that differ between nodes with `externalTrafficPolicy: Local` are expected — only nodes carrying a backend advertise the VIP.

---

## 6. Failure diagnosis

### 6.1 Triage order

```
Is the Pod getting an IP?
  no  -> §6.2 CNI / IPAM
  yes -> Is the endpoint 'ready' in `cilium-dbg endpoint list`?
           no  -> policy compilation / agent. `cilium-dbg endpoint get <id>`, agent logs
           yes -> Does traffic leave the source pod?
                    check `hubble observe --from-pod ...`
                    DROPPED with a reason -> §6.4 policy / §6.7 datapath drops
                    no flow at all        -> §6.6 socket LB / service programming
                    FORWARDED but no reply-> §6.3 MTU / §6.8 asymmetric routing
```

### 6.2 Pods stuck in `ContainerCreating`

```bash
$ kubectl -n prod describe pod frontend-6d9f7c8b5-9xzqk | tail -6
Events:
  Type     Reason                  Age                From     Message
  ----     ------                  ----               ----     -------
  Warning  FailedCreatePodSandBox  12s (x8 over 92s)  kubelet  Failed to create pod sandbox:
    plugin type="cilium-cni" name="cilium" failed (add): unable to allocate IP via local cilium agent:
    [POST /ipam][502] postIpamFailure  Unable to allocate IP: all pod CIDR ranges are exhausted
```

Three distinct causes share this symptom. Distinguish them:

```bash
# (a) IPAM exhausted on this node
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg status | grep IPAM
IPAM:   IPv4: 254/254 allocated from 10.20.1.0/24,

# (b) the agent is not running / its API socket is gone
$ kubectl -n kube-system get pods -l k8s-app=cilium -o wide
NAME           READY   STATUS             RESTARTS      AGE   NODE
cilium-7h2kp   0/1     CrashLoopBackOff   6 (31s ago)   4m    cca-lab-worker

# (c) two CNI configs on disk — another plugin is winning the lexical race
$ kubectl -n kube-system exec ds/cilium -- ls -1 /host/etc/cni/net.d/
05-cilium.conflist
10-kindnet.conflist            # <-- the offender
```

Fixes, in order:
- **(a)** raise `ipam.operator.clusterPoolIPv4MaskSize` (e.g. `/24` → `/23`) — this affects **new** node allocations only; existing nodes keep their CIDR until the `CiliumNode` is recreated. Or reduce Pod density per node. Verify headroom fleet-wide before it bites:
  ```bash
  $ kubectl get ciliumnodes -o json | jq -r '.items[] |
      [.metadata.name, (.spec.ipam.podCIDRs | join(",")),
       (.status.ipam.used | length)] | @tsv'
  cca-lab-worker    10.20.1.0/24   254
  cca-lab-worker2   10.20.2.0/24   61
  ```
- **(b)** read the agent log; the top three causes are a kernel below the feature floor, `cgroup v2` unmountable, and a bad `k8sServiceHost`.
- **(c)** set `cni.exclusive: true` and restart the agent, which cleans `/etc/cni/net.d`.

### 6.3 The MTU black hole — small requests work, large ones hang

This is the highest-cost-to-diagnose failure in the chapter because nothing is logged and nothing is counted as a drop. `curl http://svc/healthz` succeeds; a TLS handshake or any response over ~1.4 kB hangs forever.

```bash
$ kubectl -n prod exec deploy/frontend -- ip link show eth0
3: eth0@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
                                                    ^^^^ suspicious in a tunnelled cluster

$ kubectl -n prod exec deploy/frontend -- \
    ping -M do -s 1472 -c 2 10.20.2.44
PING 10.20.2.44 (10.20.2.44) 1472(1500) bytes of data.
From 10.20.1.113 icmp_seq=1 Frag needed and DF set (mtu 1450)

--- 10.20.2.44 ping statistics ---
2 packets transmitted, 0 received, +1 errors, 100% packet loss
```

Bisect the working size:

```bash
$ for s in 1500 1450 1422 1400; do
    printf '%5s: ' "$s"
    kubectl -n prod exec deploy/frontend -- \
      ping -M do -s $((s-28)) -c1 -W1 10.20.2.44 >/dev/null 2>&1 \
      && echo OK || echo FAIL
  done
 1500: FAIL
 1450: FAIL
 1422: OK
 1400: OK
```

1422 working and 1450 failing in a VXLAN + WireGuard cluster is exactly `1500 − 50 − 80 = 1370`… no: it points at a **1472-byte** path somewhere, i.e. an intermediate device with a reduced MTU. Root causes ranked by frequency:

1. Underlay path MTU is lower than the local NIC MTU (a VPN, a cloud VPC peering link, a GRE hop). Fix: set the `MTU` Helm value to the real path MTU.
2. ICMP "fragmentation needed" is blocked by a firewall, so PMTUD silently fails. Fix: allow ICMP type 3 code 4, or clamp the MTU.
3. Encryption turned on without re-running `helm upgrade` with an updated `MTU` and without restarting Pods — **existing Pods keep the old veth MTU**. Fix: roll the workloads:
   ```bash
   $ kubectl get ns -o name | xargs -I{} kubectl -n $(basename {}) rollout restart deploy --all
   ```

### 6.4 Policy denies traffic you believe you allowed

```bash
$ hubble observe --from-pod prod/frontend --verdict DROPPED --last 5 -o json | \
    jq -r '"\(.source.identity) -> \(.destination.identity)  \(.event_type.type)  \(.drop_reason_desc)"'
25478 -> 44117  1  POLICY_DENIED
```

Resolve the two identities and diff the label sets — a policy that "should" match almost always fails because the selector is written against a label the Pod does not carry, or against a namespace label that does not exist:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg identity get 44117
ID      LABELS
44117   k8s:app.kubernetes.io/name=ledger        # <-- policy selects app=ledger
        k8s:io.cilium.k8s.policy.cluster=leloir-prod
        k8s:io.cilium.k8s.policy.serviceaccount=ledger
        k8s:io.kubernetes.pod.namespace=prod
```

Then ask the datapath directly, rather than reasoning about YAML:

```bash
$ kubectl exec -n kube-system ds/cilium -- \
    cilium-dbg policy trace --src-identity 25478 --dst-identity 44117 --dport 8080/TCP
Resolving egress policy for [k8s:app=frontend k8s:io.kubernetes.pod.namespace=prod ...]
* Rule {"matchLabels":{"any:app":"frontend","k8s:io.kubernetes.pod.namespace":"prod"}}: selected
    Allows Egress port [{8080 0 TCP}]
      Requires: []
      Labels: [k8s:app=ledger]
    No label match for [k8s:app.kubernetes.io/name=ledger ...]
0/1 rules selected
Found no allow rule
Egress verdict: denied

Final verdict: DENIED
```

And inspect the compiled per-endpoint policy map, which is the ground truth:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf policy get 2361
DIRECTION   LABELS (source:key[=value])                  PORT/PROTO   PROXY PORT   AUTH TYPE   BYTES   PACKETS   PREFIX
Allow       Egress   reserved:unknown                    ANY          NONE         disabled    0       0         0
Allow       Egress   k8s:app=payments                    8080/TCP     18441        disabled    4821    38        24
Allow       Egress   k8s:k8s-app=kube-dns                53/ANY       18442        disabled    1204    18        24
Allow       Ingress  k8s:app=frontend                    8080/TCP     NONE         disabled    9312    64        24
```

A non-zero `PROXY PORT` confirms the flow is being redirected to Envoy for L7 evaluation. `PROXY PORT: NONE` on a rule you wrote with an `http:` block means the L7 rule was not compiled — check `l7Proxy: true` and that `cilium-envoy` is running on that node.

**Rollout hygiene.** Never apply a new default-deny to a live namespace without audit mode first:

```yaml
# add to the CNP's metadata, or set policyAuditMode: true cluster-wide
metadata:
  annotations:
    io.cilium/policy-audit-mode: "true"
```
```bash
$ hubble observe --verdict AUDIT --namespace prod --last 500 -o json | \
    jq -r '[.source.labels[]?|select(startswith("k8s:app"))] as $s |
           [$s[0], .destination.identity, (.l4.TCP.destination_port//0)] | @tsv' | sort -u
```
Every line in that output is a rule you still have to write.

### 6.5 Stale `kube-proxy` rules shadowing the eBPF datapath

Symptom: after migrating to `kubeProxyReplacement`, some Services work and some intermittently fail, with no drops in Hubble.

```bash
$ kubectl exec -n kube-system ds/cilium -- iptables-save -t nat | grep -c KUBE-SVC
94
```

Deleting the `kube-proxy` DaemonSet does **not** remove the rules it wrote. They persist until the node reboots or you flush them. Run once per node:

```bash
$ kubectl -n kube-system delete ds kube-proxy
$ kubectl -n kube-system delete cm kube-proxy
$ for n in $(kubectl get nodes -o name); do
    kubectl debug $n --image=alpine:3.20 --profile=sysadmin -q -- \
      sh -c 'nsenter --target 1 --mount --uts --ipc --net --pid -- \
             sh -c "iptables-save | grep -v KUBE- | iptables-restore &&
                    ip link del kube-ipvs0 2>/dev/null; ipvsadm -C 2>/dev/null; true"'
  done
```

Then re-verify the count is `0`. This is a one-way, node-affecting operation — do it node by node, draining first, in a maintenance window.

### 6.6 Conntrack or LB map exhaustion

Symptom: new connections fail under load while existing ones are fine; `hubble observe --verdict DROPPED` shows `CT_MAP_INSERTION_FAILED`.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg map list --verbose | grep -E 'ct4|nat|lb4_services'
cilium_ct4_global          524288        0            false
cilium_snat_v4_external    511922        0            false
cilium_lb4_services_v2     65530         0            true

$ kubectl exec -n kube-system ds/cilium -- \
    curl -s localhost:9962/metrics | grep cilium_bpf_map_pressure | sort -t' ' -k2 -rn | head -3
cilium_bpf_map_pressure{map_name="cilium_ct4_global"} 0.998
cilium_bpf_map_pressure{map_name="cilium_snat_v4_external"} 0.976
cilium_bpf_map_pressure{map_name="cilium_lb4_services_v2"} 0.999
```

Fix by raising the ceilings and rolling the agent (map resize requires reload; existing connections in the map are **lost**, so drain the node):

```yaml
bpf:
  ctTcpMax: 1048576
  ctAnyMax: 524288
  natMax: 1048576
  lbMapMax: 131072
  mapDynamicSizeRatio: 0.005
```

Standing alert:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-datapath
  namespace: monitoring
spec:
  groups:
    - name: cilium.datapath
      rules:
        - alert: CiliumBPFMapPressureHigh
          expr: cilium_bpf_map_pressure > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "BPF map {{ $labels.map_name }} on {{ $labels.node }} is {{ $value | humanizePercentage }} full"
            runbook: "Raise the corresponding bpf.* Helm value and roll the agent after draining."
        - alert: CiliumPolicyDropSpike
          expr: sum by (node, reason) (rate(cilium_drop_count_total{reason="Policy denied"}[5m])) > 20
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Policy drop rate spike on {{ $labels.node }}"
        - alert: CiliumUnreachableNodes
          expr: cilium_unreachable_nodes > 0
          for: 5m
          labels:
            severity: critical
        - alert: CiliumEndpointRegenerationSlow
          expr: histogram_quantile(0.99, sum by (le, node) (rate(cilium_endpoint_regeneration_time_stats_seconds_bucket{scope="total"}[10m]))) > 10
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "p99 endpoint regeneration > 10s — usually identity churn or an oversized policy set"
        - alert: CiliumIdentityExplosion
          expr: cilium_identity{type="cluster_local"} > 45000
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Approaching the 65535 cluster-local identity ceiling"
```

### 6.7 Reading raw datapath drops

When Hubble is not enough, go to the perf ring buffer:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop -v
Listening for events on 16 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8f2a1c3d to endpoint 1204, ifindex 24, file bpf_lxc.c:2004, , identity 25478->31902: 10.20.1.113:44120 -> 10.20.1.88:8080 tcp SYN
xx drop (Stale or unroutable IP) flow 0x1c04a9de to endpoint 0, ifindex 2, file bpf_host.c:1122, , identity 6->unknown: 10.10.0.9 -> 10.20.4.7 tcp SYN
xx drop (Unsupported L3 protocol) flow 0x7712bb01 to endpoint 0, ifindex 24, file bpf_lxc.c:1402, , identity 31902->0: 0.0.0.0 -> 0.0.0.0
```

| Drop reason | Most common root cause |
|---|---|
| `Policy denied` | Selector/label mismatch — §6.4 |
| `Stale or unroutable IP` | ipcache has no entry for the destination: a node was removed, or CRD/kvstore sync is lagging |
| `Invalid source ip` | Source address spoofing check failed — a Pod using an IP that is not its own, or an unmanaged Pod |
| `CT: Map insertion failed` | Conntrack full — §6.6 |
| `No mapping for NAT masquerade` | NAT map exhausted, or the egress device is not in `devices` |
| `FIB lookup failed` | Host has no route to the destination: native routing without a route to the remote PodCIDR |
| `Missed tail call` | Datapath program set is inconsistent — restart the agent; if it recurs, file a bug with a sysdump |
| `Unsupported protocol for NAT masquerade` | Something other than TCP/UDP/ICMP being masqueraded (SCTP, ESP) |
| `Authentication required` | Mutual-auth policy with no established SPIRE identity |

The `file bpf_lxc.c:2004` field is the exact source location of the decision — invaluable when reading the upstream datapath source.

### 6.8 Native routing without a route to the remote PodCIDR

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop | grep 'FIB lookup'
xx drop (FIB lookup failed) flow 0x2a1c to endpoint 0, ifindex 2, file bpf_lxc.c:1691, , identity 25478->31902: 10.20.1.113:33420 -> 10.20.2.44:8080 tcp SYN

$ kubectl exec -n kube-system ds/cilium -- ip route get 10.20.2.44
RTNETLINK answers: Network is unreachable
```

The eBPF datapath deliberately does **not** invent routes in native mode. Either:
- the nodes are on one L2 segment → set `autoDirectNodeRoutes: true`;
- they are not → BGP (§4.4), or static routes on the fabric, or switch to `routingMode: tunnel`.

Confirm which mode is in force before debugging further:

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf tunnel list
TUNNEL   VALUE
# empty in native routing — this is correct, not a fault
```

### 6.9 `toFQDNs` policy allows nothing

`toFQDNs` **only** works if the same policy also permits DNS through the L7 DNS proxy. Without the `rules: dns:` block, the proxy never sees the query, never learns the answer, and the FQDN selector matches an empty IP set.

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg fqdn cache list | head
Endpoint   Source       FQDN                 TTL    ExpirationTime                    IPs
1204       lookup       api.stripe.com.      60     2026-09-01T14:23:11.004Z          104.18.6.14,104.18.7.14

$ kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ipcache list | grep 104.18
104.18.6.14/32   identity=16777231 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
104.18.7.14/32   identity=16777231 encryptkey=0 tunnelendpoint=0.0.0.0 nodeid=0x0000
```

An empty FQDN cache with a correct-looking policy means the DNS rule is missing or the query is going somewhere other than the selected DNS endpoints.

Two production caveats:
- **Agent restarts interrupt DNS** for every Pod under a `toFQDNs` policy, because the DNS proxy lives in the agent. Keep `rollOutCiliumPods` restarts to one node at a time and measure the gap.
- A CDN behind a short TTL and a large address pool can push a single hostname past `dnsProxy.endpointMaxIpPerHostname` (default 50), after which the oldest IPs are evicted and previously-working connections start failing intermittently. Raise the limit or use `toCIDRSet` for such destinations.

### 6.10 Encryption that is not actually encrypting

```bash
$ kubectl exec -n kube-system ds/cilium -- cilium-dbg encrypt status
Encryption: Wireguard
Interface: cilium_wg0
  Public key: 9pS1n+FQ0v0KcS3fA1qWQ2mZ1Y8cH0jV6t5RmL9pXQY=
  Number of peers: 2

$ kubectl exec -n kube-system ds/cilium -- wg show cilium_wg0
interface: cilium_wg0
  public key: 9pS1n+FQ0v0KcS3fA1qWQ2mZ1Y8cH0jV6t5RmL9pXQY=
  private key: (hidden)
  listening port: 51871

peer: hK2mF8xQ...
  endpoint: 10.10.0.5:51871
  allowed ips: 10.20.2.0/24, 10.10.0.5/32
  latest handshake: 41 seconds ago
  transfer: 1.24 GiB received, 894.11 MiB sent
```

`Number of peers` must equal `nodes − 1`. Fewer means a node's public key has not propagated — check the `CiliumNode` object:

```bash
$ kubectl get ciliumnode cca-lab-worker2 -o jsonpath='{.metadata.annotations}' | jq .
{
  "network.cilium.io/wg-pub-key": "hK2mF8xQ..."
}
```

Prove it end-to-end from the underlay rather than trusting the status line:

```bash
$ kubectl debug node/cca-lab-worker --image=nicolaka/netshoot -q -- \
    tcpdump -ni eth0 -c 5 'host 10.10.0.5 and not port 51871'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes

0 packets captured
```

Zero packets between node IPs outside the WireGuard port is the proof. Any cleartext Pod-to-Pod packet there is a finding.

### 6.11 Capturing everything for escalation

```bash
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M)
🔍 Collecting Kubernetes nodes...
🔍 Collecting Cilium configuration...
🔍 Collecting Cilium BPF maps from all nodes...
🔍 Collecting Hubble flows from all nodes...
🔍 Collecting gops stats from Cilium pods...
✅ The sysdump has been saved to cilium-sysdump-20260901-1417.zip
```

The bundle contains, per node: `cilium-dbg status --verbose`, every BPF map dump, the full policy set, endpoint/identity lists, agent + operator logs, `bpftool` output, and a Hubble flow snapshot. It is the correct first attachment to any upstream issue, and it is also the fastest way to compare two nodes that behave differently. It contains **Pod IPs, labels, and flow records** — treat it as sensitive and redact before sharing outside the organisation.

---

## 7. The mental model to carry into the exam and into production

1. **Identity, not IP.** Every policy verdict resolves to `(source identity, destination identity, port, protocol, direction)`. When something is denied, resolve both identities and diff the label sets before reading any YAML.
2. **The ipcache is the global truth table.** `IP → identity, tunnel endpoint, encryption key`. Native routing depends on it for ingress policy; tunnel mode carries the identity in-band and does not.
3. **Three layers of load balancing.** Socket LB at `connect()` for Pod→Service; `tc` for east-west; XDP for north-south. If Pod→Service works and NodePort does not, you are looking at different code paths and different maps.
4. **Configuration lives in three places and they must agree.** Helm values → the `cilium-config` ConfigMap → the agent's effective flags. `cilium-dbg config --all` is the only one that counts.
5. **Maps are capacity.** Conntrack, NAT, per-endpoint policy, LB and Maglev tables all have ceilings that you sized (or defaulted). `cilium_bpf_map_pressure` belongs on your dashboard from day one.
6. **The agent is not the datapath.** Existing traffic survives an agent restart; new Pods, policy convergence, and the L7/DNS proxy do not.
7. **Kernel version gates features, not the Cilium version.** Read `cilium-dbg status --verbose` and confirm `Host Routing: BPF`, `Masquerading: BPF`, and native XDP — a silently degraded fallback looks identical from the API server.
8. **Audit before enforce.** `PolicyAuditMode` for host firewall and every new default-deny. The failure mode of getting this wrong is a locked-out node or a namespace-wide outage.

---

## Referencias

**Official Cilium documentation**
- Cilium documentation root — https://docs.cilium.io/en/stable/
- Component overview and architecture — https://docs.cilium.io/en/stable/overview/component-overview/
- eBPF datapath internals — https://docs.cilium.io/en/stable/reference-guides/bpf/
- Life of a packet — https://docs.cilium.io/en/stable/reference-guides/bpf/lifeofapacket/
- Routing modes (encapsulation and native) — https://docs.cilium.io/en/stable/network/concepts/routing/
- IPAM concepts and modes — https://docs.cilium.io/en/stable/network/concepts/ipam/
- Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
- MTU configuration — https://docs.cilium.io/en/stable/network/mtu/
- Kubernetes without kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- kube-proxy replacement (Maglev, DSR, XDP) — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#maglev-consistent-hashing
- BGP Control Plane (v2 resources) — https://docs.cilium.io/en/stable/network/bgp-control-plane/
- LoadBalancer IP Address Management — https://docs.cilium.io/en/stable/network/lb-ipam/
- Egress Gateway — https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
- Bandwidth Manager — https://docs.cilium.io/en/stable/network/kubernetes/bandwidth-manager/
- Local Redirect Policy — https://docs.cilium.io/en/stable/network/kubernetes/local-redirect-policy/
- Transparent encryption (IPsec and WireGuard) — https://docs.cilium.io/en/stable/security/network/encryption/
- Network policy concepts and CRD reference — https://docs.cilium.io/en/stable/security/policy/
- Host firewall — https://docs.cilium.io/en/stable/security/host-firewall/
- DNS-based policy and `toFQDNs` — https://docs.cilium.io/en/stable/security/policy/language/#dns-based
- Policy troubleshooting and audit mode — https://docs.cilium.io/en/stable/security/policy/troubleshooting/
- Hubble observability — https://docs.cilium.io/en/stable/observability/hubble/
- Monitoring and metrics reference — https://docs.cilium.io/en/stable/observability/metrics/
- Troubleshooting guide — https://docs.cilium.io/en/stable/operations/troubleshooting/
- System requirements (kernel and distribution matrix) — https://docs.cilium.io/en/stable/operations/system_requirements/
- Helm reference (every value used above) — https://docs.cilium.io/en/stable/helm-reference/
- Upgrade guide — https://docs.cilium.io/en/stable/operations/upgrade/
- Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/
- `cilium-dbg` command reference — https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Cilium CLI — https://github.com/cilium/cilium-cli
- Cilium source (datapath under `bpf/`) — https://github.com/cilium/cilium

**Kubernetes upstream**
- Cluster networking model — https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service — https://kubernetes.io/docs/concepts/services-networking/service/
- Virtual IPs and Service proxies (`kube-proxy` modes) — https://kubernetes.io/docs/reference/networking/virtual-ips/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Topology-aware routing — https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/
- Gateway API — https://gateway-api.sigs.k8s.io/

**Certification and curriculum**
- CCA curriculum (source of this topic's weighting) — https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md
- CNCF curriculum repository — https://github.com/cncf/curriculum
- Cilium Certified Associate program page — https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Background**
- eBPF documentation — https://ebpf.io/what-is-ebpf/
- `bpftool` manual pages — https://docs.kernel.org/bpf/
- Maglev: A Fast and Reliable Software Network Load Balancer (Google, NSDI'16) — https://research.google/pubs/pub44824/
- WireGuard protocol — https://www.wireguard.com/protocol/
- CNI specification — https://github.com/containernetworking/cni/blob/main/SPEC.md