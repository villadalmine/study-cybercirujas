# 1.1 Cilium Fundamentals

> **Domain weight: 20%** — the largest single block of the CCA exam, and the substrate every other domain (Network Policy, Observability, Service Mesh, Cluster Mesh) is built on. If you do not understand *identity*, *the ipcache*, and *where the eBPF programs are attached*, every troubleshooting question in the other domains becomes guesswork.

---

## 1. The architectural problem Cilium exists to solve

### 1.1 The two lies of the pre-eBPF Kubernetes datapath

Kubernetes networking, as originally specified, rests on two assumptions that stop being true at production scale:

**Lie #1: "the IP address identifies the workload."**
Every `iptables`-based CNI, every legacy firewall, and every ACL in your enterprise network encodes policy as `10.244.3.17 may talk to 10.244.9.4`. In a cluster where a Deployment rollout replaces every Pod IP in 40 seconds, and where the same `/16` is recycled across namespaces within minutes, an IP is a *lease*, not an identity. The failure mode is not theoretical: policy converges more slowly than the workload churns, so there exists a window in which a newly scheduled Pod inherits an IP that still carries the previous tenant's ACL. That is a silent authorization bug that no test suite catches.

**Lie #2: "the packet must traverse the full network stack."**
A Pod-to-Pod packet on the same node, with a veth pair and a bridge, traverses: socket → TCP → IP → netfilter `OUTPUT` → routing → netfilter `POSTROUTING` → veth xmit → veth rx (softirq) → netfilter `PREROUTING` → routing → netfilter `FORWARD` → veth xmit → veth rx → netfilter `PREROUTING` → routing → netfilter `INPUT` → TCP → socket. The packet is parsed, conntracked, and re-routed several times to move between two processes on the same kernel.

### 1.2 The quantitative case against `kube-proxy` + `iptables`

`kube-proxy` in `iptables` mode programs a chain structure that is *linear in the number of services* and *linear in the number of backends per service*. For each ClusterIP service it emits (approximately) one `KUBE-SERVICES` match rule, one `KUBE-SVC-XXXX` chain with one probabilistic-jump rule per endpoint, and one `KUBE-SEP-XXXX` chain with two rules (mark-masq + DNAT) per endpoint.

| Cluster shape | Services | Endpoints/svc | Approx. iptables rules | Full `iptables-restore` sync (observed) |
|---|---:|---:|---:|---:|
| Small | 100 | 4 | ~2,000 | < 50 ms |
| Medium | 1,000 | 8 | ~20,000 | ~0.5–1 s |
| Large | 5,000 | 10 | ~120,000 | ~3–10 s |
| Very large | 10,000 | 20 | ~450,000 | tens of seconds |

Three distinct pathologies emerge:

1. **Update cost is O(total rules), not O(changed rules).** `kube-proxy` rewrites the whole table under the `xtables` lock. One Endpoint change in one Service pays for all 10,000 Services. This is why `--iptables-min-sync-period` exists — it is a rate limiter that trades *correctness latency* (how long a terminated backend keeps receiving traffic) for *CPU*.
2. **Lookup cost is O(n) in the match path.** Netfilter walks the rule list. A packet to a service near the end of `KUBE-SERVICES` is evaluated against thousands of preceding rules. IPVS mode fixes the *lookup* (hash table) but not the identity model, and it still relies on netfilter for masquerading and policy.
3. **The `xtables` lock is a cluster-wide serialization point** shared with anything else on the node touching iptables (Docker, other CNIs, node agents, `firewalld`).

### 1.3 What Cilium changes

Cilium replaces both lies:

- **Identity replaces IP.** A workload's security identity is derived from its *labels*. `10.244.3.17` is not an identity; `k8s:app=deathstar, k8s:io.kubernetes.pod.namespace=default` is, and it maps to a stable numeric identity (e.g. `35109`) that is valid cluster-wide (and, with Cluster Mesh, mesh-wide). Policy is compiled against that number. Pod churn does not invalidate policy.
- **eBPF replaces the traversal.** Programs attached at `tc`, XDP, and cgroup hooks perform lookup, policy enforcement, NAT and forwarding in hash-map lookups (O(1)), short-circuiting the netfilter and (with BPF host routing) large parts of the routing stack.

---

## 2. eBPF: the mechanism, not the marketing

You will be examined on *where* Cilium's programs run and *what state they read*. That requires knowing the substrate.

### 2.1 The execution model

eBPF is an in-kernel virtual machine with a strict safety contract:

| Stage | What happens | Failure mode you will see |
|---|---|---|
| **Compile** | Clang/LLVM emits BPF bytecode from restricted C (`bpf/*.c` in the Cilium tree) | Build-time only |
| **Load** | `bpf()` syscall, program + map FDs | `Failed to load program` in agent log |
| **Verify** | Static analysis: bounded loops, no unchecked pointer arithmetic, all memory accesses proven in-bounds, ≤1M instructions analyzed | `permission denied` / verifier log dump in `cilium-agent` logs |
| **JIT** | Bytecode → native machine code (x86-64/arm64) | — |
| **Attach** | Program bound to a hook (tc/XDP/cgroup/tracing) | `Unable to attach program to device` |

The verifier is why an eBPF program cannot crash the kernel or loop forever, and also why Cilium's datapath uses **tail calls** (`bpf_tail_call()` via the `cilium_calls_*` program-array maps) — the per-program instruction budget forces the datapath to be split into chained programs rather than one monolith.

### 2.2 Maps: the shared state plane

Maps are the only durable state and the only channel between the eBPF datapath and the userspace agent. This is the single most important operational fact in this domain: **`cilium-agent` is a control plane that writes maps; it is not in the packet path.** If the agent dies, the datapath keeps forwarding with the last-programmed state.

| Map (pinned under `/sys/fs/bpf/tc/globals/`) | Type | Contents | Read by |
|---|---|---|---|
| `cilium_lxc` | hash | local endpoint IP → endpoint ID, MAC, ifindex, identity | `bpf_lxc`, `bpf_host` |
| `cilium_ipcache` | LPM trie | **any** IP/CIDR → security identity + tunnel endpoint + encryption key | all programs |
| `cilium_policy_v2_<epid>` | hash | (identity, direction, proto, port) → allow/deny + proxy port | `bpf_lxc` |
| `cilium_ct4_global` / `cilium_ct6_global` | LRU hash | TCP connection tracking entries | all |
| `cilium_ct_any4_global` | LRU hash | non-TCP (UDP/ICMP) CT entries | all |
| `cilium_lb4_services_v2` | hash | (frontend IP, port, proto, slot) → backend slot / revNAT ID | `bpf_sock`, `bpf_host`, `bpf_lxc` |
| `cilium_lb4_backends_v3` | hash | backend ID → IP, port, state | same |
| `cilium_lb4_reverse_nat` | hash | revNAT ID → original frontend (for reply rewriting) | same |
| `cilium_lb4_maglev` | array-of-array | per-service Maglev lookup table (default 16381 entries) | same |
| `cilium_snat_v4_external` | LRU hash | masquerade NAT bindings | `bpf_host` |
| `cilium_tunnel_map` | hash | remote pod CIDR / endpoint IP → remote node tunnel IP | `bpf_overlay`, `bpf_lxc` |
| `cilium_node_map` | hash | node IP → node ID (used by egress gw / encryption) | `bpf_host` |
| `cilium_events` | perf event array | datapath → agent notifications (drops, traces, policy verdicts) | Hubble / `cilium monitor` |
| `cilium_metrics` | per-CPU hash | datapath counters (drop reasons, forward counts) | `cilium-dbg bpf metrics list` |
| `cilium_calls_*` | prog array | tail-call targets | datapath |

### 2.3 Hook points and the packet path

```
                    ┌──────────────── application process ────────────────┐
                    │  connect() / sendmsg() / getpeername()              │
                    └──────────────────────┬──────────────────────────────┘
                                           │  cgroup/connect4  ── bpf_sock.c
                                           │  (SOCKET LB: ClusterIP rewritten
                                           │   to a backend IP *before* a packet
                                           │   ever exists — zero per-packet NAT)
                    ┌──────────────────────▼──────────────────────────────┐
                    │  TCP/IP stack inside the Pod netns                  │
                    └──────────────────────┬──────────────────────────────┘
                                           │ veth (or netkit) xmit
          ┌────────────────────────────────▼───────────────────────────────┐
          │ tc ingress on lxcXXXX (host side)  ── bpf_lxc.c "from-container"│
          │   • resolve source identity from cilium_lxc                    │
          │   • resolve dest identity from cilium_ipcache (LPM)            │
          │   • EGRESS policy lookup in cilium_policy_v2_<epid>            │
          │   • service translation (if not already done by socket LB)     │
          │   • conntrack create/lookup in cilium_ct4_global               │
          └────────────────┬───────────────────────┬───────────────────────┘
                           │ same node             │ remote node
           ┌───────────────▼──────────┐   ┌────────▼───────────────────────┐
           │ tc ingress on peer lxc   │   │ encap → cilium_vxlan (bpf_over- │
           │  bpf_lxc "to-container"  │   │ lay.c)  OR  native route out    │
           │  • INGRESS policy        │   │ eth0 (bpf_host.c "to-netdev":   │
           │  • deliver               │   │ masquerade, NodePort revDNAT)   │
           └──────────────────────────┘   └─────────────────────────────────┘

XDP (optional, driver-level, pre-skb): bpf_xdp.c — NodePort/LoadBalancer forwarding
and CIDR prefilter at line rate, before sk_buff allocation.
```

**Exam-relevant asymmetry:** the program attached to `tc ingress` of the *host-side veth* handles the Pod's **egress** traffic. Packets leaving the Pod arrive at the host as ingress. This confuses people reading `tc filter show` output.

---

## 3. Component architecture

### 3.1 The pieces

| Component | Kind | Runs where | Responsibility | Datapath-critical? |
|---|---|---|---|---|
| `cilium-agent` | DaemonSet | every node | Watches K8s API; computes identities & policy; compiles/loads eBPF; writes maps; runs the DNS proxy; serves the health API | **No** (control plane) |
| `cilium-cni` | binary at `/opt/cni/bin/cilium-cni` | every node | CNI ADD/DEL called by the kubelet's container runtime; talks to the agent over `/var/run/cilium/cilium.sock` | Yes for Pod creation |
| `cilium-operator` | Deployment (HA: 2 replicas, leader-elected) | any node | Cluster-scoped work: IPAM CIDR allocation per node, `CiliumIdentity` garbage collection, `CiliumEndpoint` GC, KVStore heartbeat, Ingress/LB-IPAM reconciliation | No |
| `cilium-envoy` | DaemonSet (default since 1.16) | every node | L7 proxy for L7 policy, Ingress, Gateway API, mTLS termination | Only for L7-redirected flows |
| `hubble-relay` | Deployment | any node | Aggregates per-node Hubble gRPC into one cluster-wide API | No |
| `hubble-ui` | Deployment | any node | Web frontend for Relay | No |
| `clustermesh-apiserver` | Deployment | any node | Exposes this cluster's identities/endpoints/services to remote clusters | No |
| `cilium-dbg` | binary **inside** the agent pod | — | Low-level introspection of *this node's* state and maps | — |
| `cilium` (cilium-cli) | binary on your workstation | — | Install/upgrade, `status`, `connectivity test`, `sysdump` | — |

> **Naming trap (frequently tested):** since v1.16 the in-pod binary is **`cilium-dbg`**; `cilium` inside the pod is a compatibility shim. The host-side `cilium` CLI (`cilium-cli`) and the in-pod `cilium-dbg` have *different, non-overlapping* subcommands. `cilium status` (host) reports Deployment/DaemonSet health; `cilium-dbg status` (pod) reports datapath state on one node.

### 3.2 Where cluster state lives

Cilium needs a distributed store for identities and endpoint metadata. Two modes:

| | `identityAllocationMode: crd` (default) | `identityAllocationMode: kvstore` |
|---|---|---|
| Backing store | Kubernetes API (`CiliumIdentity` CRs) | external etcd (or `clustermesh-apiserver` etcd) |
| Extra infrastructure | none | etcd cluster to operate, back up, TLS-rotate |
| Scale ceiling | kube-apiserver watch/write load; degrades around very high identity churn (thousands of identities, rapid churn) | much higher; decouples from kube-apiserver |
| Failure blast radius | apiserver outage stalls identity allocation (existing datapath keeps working) | etcd outage stalls it |
| Typical use | 99% of clusters | very large clusters, Cluster Mesh at scale |
| Migration path | `doublewrite-readonly-kvstore` / `doublewrite-readonly-crd` intermediate modes | — |

### 3.3 The CRDs you must recognize

```
$ kubectl get crd -o name | grep cilium
customresourcedefinition.apiextensions.k8s.io/ciliumbgpadvertisements.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgpclusterconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgpnodeconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumbgppeerconfigs.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumcidrgroups.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumclusterwidenetworkpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumendpoints.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumendpointslices.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumexternalworkloads.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumidentities.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumloadbalancerippools.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliuml2announcementpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumnetworkpolicies.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumnodes.cilium.io
customresourcedefinition.apiextensions.k8s.io/ciliumpodippools.cilium.io
```

| CRD | Scope | What it is |
|---|---|---|
| `CiliumIdentity` (`ciliumid`) | cluster | The label-set ↔ numeric-identity binding. GC'd by the operator. |
| `CiliumEndpoint` (`cep`) | namespaced | Per-Pod datapath state: identity, IPs, policy enforcement status. One per Pod. |
| `CiliumEndpointSlice` (`ces`) | cluster | Batches many `CiliumEndpoint`s into one object to cut apiserver watch traffic at scale. |
| `CiliumNode` (`cn`) | cluster | Per-node IPAM pool, node IPs, encryption key index, health IPs. |
| `CiliumNetworkPolicy` (`cnp`) | namespaced | Identity-aware L3/L4/L7 policy. |
| `CiliumClusterwideNetworkPolicy` (`ccnp`) | cluster | Same, but cluster-scoped (and the only one that can select `reserved:host`). |
| `CiliumLoadBalancerIPPool` | cluster | LB-IPAM address pools for `type: LoadBalancer` Services. |

---

## 4. The identity model — the conceptual core of Cilium

### 4.1 From labels to a number

1. The agent observes a Pod and collects its labels.
2. It **filters** them through the label allow/deny list (`--labels`, default: drop `pod-template-hash`, `controller-revision-hash`, and other high-cardinality churn labels). *This filtering is what keeps identity count bounded* — without it, every ReplicaSet rollout would mint new identities.
3. The surviving label set, canonically sorted with source prefixes (`k8s:`, `container:`, `reserved:`, `unspec:`), is the **identity key**.
4. The agent allocates (or reuses) a numeric identity for that key via the CRD/kvstore allocator.
5. Every node learns `IP → identity` via the **ipcache** and compiles policy against the number.

Two Pods with identical (filtered) labels **share one identity**, even across nodes and namespaces-with-same-labels. Scaling a Deployment from 3 to 300 replicas creates **zero** new identities and **zero** new policy-map entries.

### 4.2 Identity number spaces

| Range | Scope | Meaning |
|---:|---|---|
| `1`–`255` | reserved | Well-known identities, hardcoded |
| `256`–`65535` | cluster-global | Label-derived workload identities |
| `≥ 16777216` (`1<<24`) | **node-local** | CIDR and FQDN-derived identities — allocated *locally*, never shared, never valid on another node |
| `clusterID<<16 \| localID` | mesh-global | With Cluster Mesh, the cluster ID is encoded in the high bits (default `max-connected-clusters=255` → 8 bits of cluster ID) |

**Reserved identities (memorize these):**

| ID | Name | Meaning |
|---:|---|---|
| 1 | `reserved:host` | The local node itself (all host IPs, including `cilium_host`) |
| 2 | `reserved:world` | Anything outside the cluster |
| 3 | `reserved:unmanaged` | An endpoint Cilium knows about but does not manage |
| 4 | `reserved:health` | Cilium's own health-check endpoint (`cilium_health`) |
| 5 | `reserved:init` | Endpoint whose labels are not yet resolved (transient at Pod start) |
| 6 | `reserved:remote-node` | Any **other** node in the cluster (or mesh) |
| 7 | `reserved:kube-apiserver` | The API server(s), in-cluster or external |
| 8 | `reserved:ingress` | Cilium Ingress/Gateway API source identity |
| 9 | `reserved:world-ipv4` | `reserved:world` split, IPv4 half (dual-stack) |
| 10 | `reserved:world-ipv6` | `reserved:world` split, IPv6 half (dual-stack) |

> **Production trap:** `reserved:host` and `reserved:remote-node` are distinct. Before Cilium 1.7, remote nodes were part of `host`. A policy that allows `fromEntities: [host]` does **not** allow other nodes. And `reserved:host` traffic is **always allowed by default** unless the Host Firewall (`hostFirewall.enabled=true`) is on — this is a deliberate safety property to avoid locking yourself out of the node, and a common source of "why isn't my policy blocking the kubelet?" confusion.

### 4.3 The ipcache: the LPM trie that makes it all work

The ipcache answers one question for every packet: *given this IP, what identity is it, and if it is remote, which node holds it?*

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf ipcache list
IP PREFIX/ADDRESS        IDENTITY
0.0.0.0/0                identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.10/32             identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.11/32             identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.12/32             identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.13/32             identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.9/32            identity=4 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.87/32           identity=24512 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.201/32          identity=35109 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.2.31/32           identity=35109 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.2.0/24            identity=6 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.3.0/24            identity=6 encryptkey=0 tunnelendpoint=10.0.1.13 flags=<none>
203.0.113.0/24           identity=16777218 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

Read this carefully — it encodes the whole design:

- `0.0.0.0/0 → identity=2` is the **default route of the identity space**: anything not otherwise known is `reserved:world`.
- `10.244.2.31/32 → identity=35109, tunnelendpoint=10.0.1.12` — a *remote* Pod: we know both its identity (so we can enforce policy locally, at the source) and the node to encapsulate toward.
- `203.0.113.0/24 → 16777218` — a **local-scope CIDR identity** created by a `toCIDR` policy rule on this node. That number is meaningless on any other node.
- Longest-prefix match means `10.244.2.31/32` (a specific pod) wins over `10.244.2.0/24` (the remote node's pod CIDR).

**Egress policy is enforced at the source node** because the source node already knows the destination's identity from the ipcache. **Ingress policy is enforced at the destination node.** A single connection is therefore evaluated twice, by two different policy maps, on two different machines.

### 4.4 Seeing identities

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity list
ID         LABELS
1          reserved:host
2          reserved:world
3          reserved:unmanaged
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
9          reserved:world-ipv4
10         reserved:world-ipv6
6789       k8s:app=kube-dns
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=kube-system
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=coredns
           k8s:io.kubernetes.pod.namespace=kube-system
           k8s:k8s-app=kube-dns
24512      k8s:app.kubernetes.io/name=tiefighter
           k8s:class=tiefighter
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
35109      k8s:app.kubernetes.io/name=deathstar
           k8s:class=deathstar
           k8s:io.cilium.k8s.namespace.labels.kubernetes.io/metadata.name=default
           k8s:io.cilium.k8s.policy.cluster=leloir
           k8s:io.cilium.k8s.policy.serviceaccount=default
           k8s:io.kubernetes.pod.namespace=default
           k8s:org=empire
16777218   cidr:203.0.113.0/24
           reserved:world
```

Note the four automatically-injected `k8s:` labels present on every workload identity: namespace, namespace-labels (`io.cilium.k8s.namespace.labels.*`), service account (`io.cilium.k8s.policy.serviceaccount`), and cluster name (`io.cilium.k8s.policy.cluster`). These are what make `namespaceSelector`, ServiceAccount-based policy, and Cluster Mesh policy possible.

### 4.5 Endpoints

An **endpoint** is Cilium's unit of datapath management — usually a Pod, but also `cilium_host` (the node itself) and `cilium_health`.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4           STATUS
           ENFORCEMENT        ENFORCEMENT
196        Disabled           Disabled          4          reserved:health                                                 10.244.1.9     ready
742        Disabled           Disabled          6789       k8s:app=kube-dns                                                10.244.1.42    ready
                                                           k8s:io.kubernetes.pod.namespace=kube-system
                                                           k8s:k8s-app=kube-dns
1420       Enabled            Disabled          35109      k8s:app.kubernetes.io/name=deathstar                            10.244.1.201   ready
                                                           k8s:class=deathstar
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
2103       Disabled           Enabled           24512      k8s:app.kubernetes.io/name=tiefighter                           10.244.1.87    ready
                                                           k8s:class=tiefighter
                                                           k8s:io.kubernetes.pod.namespace=default
                                                           k8s:org=empire
3187       Disabled           Disabled          1          reserved:host                                                                  ready
```

**Endpoint lifecycle states** (`STATUS` column): `waiting-for-identity` → `waiting-to-regenerate` → `regenerating` → `ready`. Also `restoring` (agent restart, endpoints being re-adopted from `/var/run/cilium/state/`), `disconnecting`, `disconnected`, `invalid`.

An endpoint stuck in `waiting-for-identity` means the identity allocator cannot reach its backing store (kube-apiserver or etcd). An endpoint stuck in `regenerating` usually means eBPF compilation/loading is failing — check the agent log for verifier output.

**Policy enforcement is per-direction and per-endpoint, and it is implicitly "default allow until selected".** An endpoint shows `Enabled` for a direction only once at least one policy rule selects it in that direction. This is the Kubernetes model (`NetworkPolicy` semantics) and it is why `tiefighter` above shows `Egress: Enabled, Ingress: Disabled`.

---

## 5. Datapath modes: encapsulation vs. native routing

### 5.1 The decision

| | **Encapsulation** (`routingMode: tunnel`) | **Native routing** (`routingMode: native`) |
|---|---|---|
| Protocols | VXLAN (UDP/8472, default) or Geneve (UDP/6081) | none — plain IP |
| Underlay requirement | Only node-to-node IP reachability. Pod CIDRs are invisible to the network. | The underlay **must** route Pod CIDRs: either L2 adjacency + `autoDirectNodeRoutes`, or a router that learns them (BGP, cloud route tables) |
| MTU cost | −50 bytes (VXLAN and Geneve-with-default-options over IPv4) | 0 |
| Throughput | Lower: encap/decap + extra checksum work; TSO/GRO offload varies by NIC | Highest |
| Multi-subnet nodes | Works out of the box | Needs BGP or cloud routes |
| Metadata channel | Geneve options / VXLAN VNI carry the source security identity for free | Identity must be resolved from the ipcache at the destination (works, but DSR needs `dsrDispatch: opt` or `geneve` to carry state) |
| Cloud provider caps | Immune to route-table entry limits | AWS VPC route tables cap ~50 (100 by request) entries → hard node ceiling unless using ENI mode |
| Debuggability | `tcpdump` shows encapsulated frames; needs `-d cilium_vxlan` or decap filters | Trivial to `tcpdump` |
| Default in Cilium | **yes** (VXLAN) | opt-in |

**MTU arithmetic you should be able to do on the whiteboard:**

| Underlay MTU | Mode | Pod MTU | Reason |
|---:|---|---:|---|
| 1500 | native | 1500 | — |
| 1500 | VXLAN | 1450 | 14 (inner Eth) + 8 (VXLAN) + 8 (UDP) + 20 (outer IPv4) |
| 1500 | Geneve | 1450 | same, 8-byte Geneve base header, no options |
| 1500 | VXLAN + WireGuard | 1370 | WireGuard adds 80 bytes on top |
| 9000 | VXLAN | 8950 | jumbo underlay, same overhead |

An MTU mismatch is the classic "small requests work, large responses hang" bug: TCP handshake and short HTTP GETs succeed, a 40 KB response stalls. Verify with `cilium-dbg status | grep MTU` and by pinging with `-M do -s <size>`.

### 5.2 Native routing sub-modes

```yaml
# Direct routing on a flat L2 segment (all nodes on the same subnet)
routingMode: native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: true      # program a route per remote node's PodCIDR via its node IP
```

`autoDirectNodeRoutes: true` requires **L2 adjacency between all nodes**. On a routed underlay you instead advertise Pod CIDRs with Cilium's BGP control plane (`CiliumBGPClusterConfig`) or rely on the cloud provider's route programming.

### 5.3 BPF host routing and netkit

Two orthogonal performance levers layered on native routing:

| Feature | Requires | What it removes | Typical gain |
|---|---|---|---|
| **BPF host routing** (`bpf.masquerade` + native routing, auto-enabled when possible) | kernel ≥ 5.10, native routing, no legacy iptables interference | The host's routing + netfilter traversal; uses `bpf_redirect_peer()`/`bpf_redirect_neigh()` | Meaningful latency reduction on pod↔pod and pod↔external |
| **netkit devices** (`bpf.datapathMode: netkit`) | kernel ≥ 6.8 | The veth pair itself; BPF program runs in the peer's context, eliminating a full softirq/queueing hop | Pod networking approaching host-network performance |

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'Host Routing|Device Mode|Masquerading'
Host Routing:            BPF
Device Mode:             netkit
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
```

If `Host Routing: Legacy` appears when you expected BPF, the agent log states the reason (e.g. tunnel mode active, or a per-endpoint route requirement).

---

## 6. IPAM modes

| Mode (`ipam.mode`) | Who allocates the node's CIDR | Who allocates the Pod IP | When to use | Caveat |
|---|---|---|---|---|
| `cluster-pool` (**default**) | `cilium-operator`, carving `clusterPoolIPv4PodCIDRList` into `/clusterPoolIPv4MaskSize` blocks, written to `CiliumNode.spec.ipam.podCIDRs` | agent, from the node block | Most on-prem/self-managed clusters | Pod CIDR is unknown to the underlay → tunnel or BGP |
| `kubernetes` | kube-controller-manager (`--allocate-node-cidrs`), read from `Node.spec.podCIDR` | agent | When another component already owns CIDR allocation | Requires the controller-manager flag; `/24` per node fixed by `--node-cidr-mask-size` |
| `multi-pool` | operator, from multiple `CiliumPodIPPool` CRs | agent, pool chosen by Pod annotation | Multi-tenant clusters needing routable IPs for some tenants only | Newer feature; check version support |
| `eni` (AWS) | operator, via EC2 API — attaches ENIs and secondary IPs | agent | EKS / AWS with fully routable pod IPs in the VPC | Instance-type limits ENI/IP counts; needs IAM |
| `azure` | operator via Azure API | agent | AKS with Azure CNI-style IPAM | — |
| `alibabacloud` | operator | agent | Alibaba ENI | — |
| `crd` | external controller writes `CiliumNode.spec.ipam.pool` | agent | Custom integrations | You own the allocator |
| `delegated-plugin` | another CNI IPAM plugin | that plugin | CNI chaining scenarios | Cilium cannot report IPAM status |

```
$ kubectl get ciliumnode worker-01 -o jsonpath='{.spec.ipam}' | jq
{
  "podCIDRs": [
    "10.244.1.0/24"
  ],
  "pool": {}
}

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -A2 IPAM
IPAM:                    IPv4: 12/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.9 (health)
```

---

## 7. kube-proxy replacement and the service datapath

### 7.1 Three generations of service load balancing

| | `kube-proxy` iptables | `kube-proxy` IPVS | **Cilium eBPF** |
|---|---|---|---|
| Data structure | linear rule chains | hash table + IPVS scheduler | eBPF hash maps + optional Maglev table |
| Lookup complexity | O(n) rules | O(1) | O(1) |
| Update complexity | O(total rules) full-table rewrite | O(changed) | O(changed) — single map entry write |
| Where translation happens | per-packet, netfilter NAT | per-packet, IPVS | **at `connect()`** for east-west (socket LB); per-packet at tc/XDP for north-south |
| Per-packet NAT for in-cluster TCP | yes | yes | **none** — the socket is connected directly to the backend |
| `externalTrafficPolicy` / source IP preservation | SNAT unless `Local` | SNAT unless `Local` | DSR preserves source IP even with `Cluster` |
| Consistent hashing on backend change | no (random/`probability`) | limited | **Maglev** — minimal disruption |
| Health-check cost | conntrack + rules | — | map entry state flag |
| Node-local optimization | no | no | `Local Redirect Policy`, node-local backend preference |

### 7.2 Socket-level load balancing — the key insight

For a Pod in the cluster calling `10.96.0.10:53`:

- **With kube-proxy:** the Pod sends a packet to `10.96.0.10`; netfilter DNATs it to `10.244.2.11`; a conntrack entry is created; every reply is reverse-NAT'd. The application believes it is talking to `10.96.0.10`.
- **With Cilium socket LB:** a cgroup-attached eBPF program intercepts the `connect(2)` syscall and **rewrites the destination address in the socket itself** before any packet exists. The kernel then opens a normal connection to `10.244.2.11:53`. There is no NAT, no per-packet cost, and no service-related conntrack entry. `getpeername4` is hooked so the application still observes `10.96.0.10` if it asks.

Consequences to remember:
- Socket LB requires **cgroup v2** and the cgroup2 filesystem mounted (`/run/cilium/cgroupv2` by default). This is why containerized/kind/CI installs sometimes need `cgroup.autoMount.enabled`.
- Socket LB applies to Pods **sharing the host's cgroup hierarchy**, which includes hostNetwork Pods and node processes — hence `socketLB.hostNamespaceOnly` for environments where that is unwanted.
- Because there is no packet-level DNAT for east-west traffic, `tcpdump` inside the Pod shows the **backend IP**, not the ClusterIP. This surprises people debugging.

### 7.3 North-south: SNAT vs DSR vs Hybrid

| Mode (`loadBalancer.mode`) | Return path | Client source IP | Requirement | Trade-off |
|---|---|---|---|---|
| `snat` (default) | back through the ingress node | lost (unless `externalTrafficPolicy: Local`) | none | Extra hop; hides client IP |
| `dsr` | backend node replies **directly** to the client | preserved | The reply must be routable to the client from the backend node; original service IP/port carried via `dsrDispatch: opt` (IPv4 option / IPv6 ext header) or `geneve` (Geneve option, works across L3) | `opt` can be dropped by middleboxes/MTU-sensitive paths |
| `hybrid` | DSR for TCP, SNAT for UDP | preserved for TCP | as DSR | Pragmatic default for mixed workloads |
| `annotation` | per-Service, via annotation | — | as DSR | Fine-grained |

Backend selection algorithm (`loadBalancer.algorithm`): `random` (default) or `maglev` (consistent hashing; `maglev.tableSize` default `16381`, `maglev.hashSeed` **must be identical on every node**, otherwise nodes disagree about which backend a flow belongs to and DSR breaks).

### 7.4 Inspecting the service maps

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
ID   Frontend             Service Type   Backend
1    10.96.0.1:443/TCP    ClusterIP      1 => 10.0.1.10:6443/TCP (active)
2    10.96.0.10:53/UDP    ClusterIP      1 => 10.244.1.42:53/UDP (active)
                                         2 => 10.244.2.17:53/UDP (active)
3    10.96.0.10:53/TCP    ClusterIP      1 => 10.244.1.42:53/TCP (active)
                                         2 => 10.244.2.17:53/TCP (active)
4    10.96.0.10:9153/TCP  ClusterIP      1 => 10.244.1.42:9153/TCP (active)
                                         2 => 10.244.2.17:9153/TCP (active)
9    10.96.184.22:80/TCP  ClusterIP      1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
10   0.0.0.0:31234/TCP    NodePort       1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
11   10.0.1.11:31234/TCP  NodePort       1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)
12   192.168.30.10:80/TCP LoadBalancer   1 => 10.244.1.201:8080/TCP (active)
                                         2 => 10.244.2.31:8080/TCP (active)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list
SERVICE ADDRESS          BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.96.184.22:80/TCP      0.0.0.0:0 (9) (0) [ClusterIP, non-routable]
                         10.244.1.201:8080/TCP (9) (1)
                         10.244.2.31:8080/TCP (9) (2)
10.96.0.10:53/UDP        0.0.0.0:0 (2) (0) [ClusterIP, non-routable]
                         10.244.1.42:53/UDP (2) (1)
                         10.244.2.17:53/UDP (2) (2)
192.168.30.10:80/TCP     0.0.0.0:0 (12) (0) [LoadBalancer]
                         10.244.1.201:8080/TCP (12) (1)
                         10.244.2.31:8080/TCP (12) (2)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list --revnat
ID   BACKEND ADDRESS (REVNAT_ID) (SLOT)
2    10.96.0.10:53
9    10.96.184.22:80
12   192.168.30.10:80
```

**Slot 0 is the master entry** (it holds the backend count and service flags); slots 1..N are the backend slots. A service showing slot 0 with `count=0` and no backend slots is a service with no ready endpoints — this is exactly what "connection refused / no route" looks like from the datapath side.

---

## 8. Complete, deployable configuration

### 8.1 A reproducible lab cluster (kind, no CNI, no kube-proxy)

`kind-cilium.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
networking:
  # Cilium provides the CNI; disable kind's kindnet.
  disableDefaultCNI: true
  # Disable kube-proxy so Cilium can fully replace it.
  kubeProxyMode: "none"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-a"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-b"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/zone=zone-b"
```

```
$ kind create cluster --config kind-cilium.yaml
Creating cluster "cca-lab" ...
 ✓ Ensuring node image (kindest/node:v1.31.4) 🖼
 ✓ Preparing nodes 📦 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-cca-lab"

$ kubectl get nodes
NAME                   STATUS     ROLES           AGE   VERSION
cca-lab-control-plane  NotReady   control-plane   47s   v1.31.4
cca-lab-worker         NotReady   <none>          31s   v1.31.4
cca-lab-worker2        NotReady   <none>          31s   v1.31.4
cca-lab-worker3        NotReady   <none>          31s   v1.31.4
```

`NotReady` is expected and correct: the kubelet reports `NetworkReady=false` because no CNI configuration exists yet. This is the single most common "is my cluster broken?" false alarm.

### 8.2 Full Helm values — production baseline

`values-cilium.yaml`:

```yaml
# ---------------------------------------------------------------------------
# Cilium production baseline. Every value below is deliberate; comments state
# the trade-off being taken. Tested against the 1.17 chart.
# ---------------------------------------------------------------------------

# --- Cluster identity (mandatory before any Cluster Mesh work) -------------
cluster:
  name: leloir
  id: 1                      # 1..255 with the default max-connected-clusters

k8sServiceHost: 10.0.1.10    # REQUIRED when kube-proxy is absent: the agent
k8sServicePort: 6443         # cannot resolve kubernetes.default without it.

# --- Datapath --------------------------------------------------------------
routingMode: native          # tunnel | native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: true   # valid only when all nodes share an L2 segment
enableIPv4Masquerade: true
enableIPv6Masquerade: false

bpf:
  masquerade: true           # eBPF masquerading instead of iptables
  hostLegacyRouting: false   # allow BPF host routing (kernel >= 5.10)
  preallocateMaps: false     # true = lower latency, higher constant memory
  lbExternalClusterIP: false
  # Sizing: raise these BEFORE you hit the ceiling; changing them restarts
  # the datapath and flushes state.
  ctTcpMax: 524288
  ctAnyMax: 262144
  natMax: 524288
  neighMax: 524288
  policyMapMax: 16384        # per-endpoint policy entries
  mapDynamicSizeRatio: 0.0025

# --- kube-proxy replacement -------------------------------------------------
kubeProxyReplacement: true   # 1.16+ uses true/false (was strict/partial/disabled)
k8sServiceProxyName: ""
socketLB:
  enabled: true
  hostNamespaceOnly: false
loadBalancer:
  mode: hybrid               # DSR for TCP, SNAT for UDP
  algorithm: maglev
  dsrDispatch: geneve        # survives L3 hops; 'opt' is IPv4-option based
  acceleration: disabled     # set to 'native' for XDP LB on supported NICs
  serviceTopology: true
maglev:
  tableSize: 16381           # prime; must match on every node
  hashSeed: "JLfvgnHc2kaSUFaI"   # MUST be identical cluster-wide
nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true

# --- IPAM -------------------------------------------------------------------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24     # 254 usable pod IPs per node

# --- Identity ---------------------------------------------------------------
identityAllocationMode: crd
identityChangeGracePeriod: 5s
# Keep identity cardinality bounded: never let deployment-generated labels in.
labels: "k8s:io\\.kubernetes\\.pod\\.namespace k8s:io\\.cilium\\.k8s\\.namespace\\.labels k8s:io\\.cilium\\.k8s\\.policy k8s:app k8s:app\\.kubernetes\\.io/name k8s:tier k8s:class k8s:org k8s:team k8s:env"

# --- Policy -----------------------------------------------------------------
policyEnforcementMode: default      # default | always | never
policyAuditMode: false              # true = log, do not drop. Use for rollout.
hostFirewall:
  enabled: false                    # enabling this can lock you out of nodes

# --- Encryption (choose ONE, or neither) ------------------------------------
encryption:
  enabled: false
  type: wireguard                   # wireguard | ipsec
  nodeEncryption: false
  wireguard:
    persistentKeepalive: 0s

# --- Observability ----------------------------------------------------------
hubble:
  enabled: true
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
    serviceMonitor:
      enabled: false
  relay:
    enabled: true
    rollOutPods: true
  ui:
    enabled: true
  eventBufferCapacity: 16383        # per-node ring buffer of flows
  eventQueueSize: 0                 # 0 = auto (based on CPU count)

prometheus:
  enabled: true
  port: 9962
operator:
  prometheus:
    enabled: true
    port: 9963
  replicas: 2
  rollOutPods: true

# --- L7 / Envoy -------------------------------------------------------------
envoy:
  enabled: true                     # standalone DaemonSet (default since 1.16)
  log:
    defaultLevel: info

ingressController:
  enabled: false
gatewayAPI:
  enabled: false

# --- Resilience -------------------------------------------------------------
rollOutCiliumPods: true
priorityClassName: system-node-critical
resources:
  requests:
    cpu: 200m
    memory: 512Mi
operator:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi

# --- Upgrade safety ---------------------------------------------------------
upgradeCompatibility: "1.17"
cni:
  exclusive: true                   # remove other CNI conf files from /etc/cni/net.d
  chainingMode: none

# --- Debug ------------------------------------------------------------------
debug:
  enabled: false
  verbose: ""                       # e.g. "flow datapath policy"
```

Install:

```
$ helm repo add cilium https://helm.cilium.io/
"cilium" has been added to your repositories

$ helm upgrade --install cilium cilium/cilium \
    --version 1.17.4 \
    --namespace kube-system \
    --values values-cilium.yaml \
    --wait --timeout 10m
Release "cilium" does not exist. Installing it now.
NAME: cilium
LAST DEPLOYED: Tue Sep  1 11:52:07 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

### 8.3 The rendered runtime configuration

Everything above ends up in one ConfigMap that the agent reads at startup. Reading it is the fastest way to know what a cluster is *actually* running:

```
$ kubectl -n kube-system get configmap cilium-config -o yaml | head -60
apiVersion: v1
data:
  agent-not-ready-taint-key: node.cilium.io/agent-not-ready
  arping-refresh-period: 30s
  auto-direct-node-routes: "true"
  bpf-lb-algorithm: maglev
  bpf-lb-external-clusterip: "false"
  bpf-lb-maglev-table-size: "16381"
  bpf-lb-map-max: "65536"
  bpf-lb-mode: hybrid
  bpf-lb-dsr-dispatch: geneve
  bpf-map-dynamic-size-ratio: "0.0025"
  bpf-policy-map-max: "16384"
  bpf-root: /sys/fs/bpf
  cgroup-root: /run/cilium/cgroupv2
  cluster-id: "1"
  cluster-name: leloir
  cni-exclusive: "true"
  debug: "false"
  enable-bpf-masquerade: "true"
  enable-endpoint-health-checking: "true"
  enable-health-checking: "true"
  enable-hubble: "true"
  enable-ipv4: "true"
  enable-ipv4-masquerade: "true"
  enable-ipv6: "false"
  enable-l7-proxy: "true"
  enable-policy: default
  identity-allocation-mode: crd
  ipam: cluster-pool
  ipv4-native-routing-cidr: 10.244.0.0/16
  kube-proxy-replacement: "true"
  routing-mode: native
  tunnel-protocol: vxlan
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
```

> **Operational rule:** never hand-edit `cilium-config`. The agent watches it and some keys hot-reload while others do not, so a manual edit produces a node whose datapath does not match its config and which reverts on the next Helm run. Change values through Helm and roll the DaemonSet.

### 8.4 An identity-based policy (the payoff)

This is what identity buys you — a rule that survives every Pod IP change:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deathstar-access
  namespace: default
spec:
  description: "Only empire tiefighters may request landing; only on POST /v1/request-landing"
  endpointSelector:
    matchLabels:
      org: empire
      class: deathstar
  ingress:
    - fromEndpoints:
        - matchLabels:
            org: empire
            class: tiefighter
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/v1/request-landing"
  egress:
    # DNS must be explicitly allowed once egress enforcement turns on.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: "telemetry.empire.internal"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

Applying this creates: a new entry in `cilium_policy_v2_1420` keyed on identity `24512`, an L7 redirect to the node's Envoy, and (on DNS resolution) a **local-scope** FQDN identity in the ipcache for `telemetry.empire.internal`.

---

## 9. The verification ladder

### 9.1 Level 0 — is the control plane healthy?

```
$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:                  OK
 \__/¯¯\__/    Operator:                OK
 /¯¯\__/¯¯\    Envoy DaemonSet:         OK
 \__/¯¯\__/    Hubble Relay:            OK
    \__/       ClusterMesh:             disabled

DaemonSet              cilium                   Desired: 4, Ready: 4/4, Available: 4/4
DaemonSet              cilium-envoy             Desired: 4, Ready: 4/4, Available: 4/4
Deployment             cilium-operator          Desired: 2, Ready: 2/2, Available: 2/2
Deployment             hubble-relay             Desired: 1, Ready: 1/1, Available: 1/1
Deployment             hubble-ui                Desired: 1, Ready: 1/1, Available: 1/1
Containers:            cilium                   Running: 4
                       cilium-envoy             Running: 4
                       cilium-operator          Running: 2
                       hubble-relay             Running: 1
                       hubble-ui                Running: 1
Cluster Pods:          31/31 managed by Cilium
Helm chart version:    1.17.4
Image versions         cilium             quay.io/cilium/cilium:v1.17.4: 4
                       cilium-envoy       quay.io/cilium/cilium-envoy:v1.31.5-...: 4
                       cilium-operator    quay.io/cilium/operator-generic:v1.17.4: 2
                       hubble-relay       quay.io/cilium/hubble-relay:v1.17.4: 1
                       hubble-ui          quay.io/cilium/hubble-ui:v0.13.2: 1
```

`Cluster Pods: 31/31 managed by Cilium` is the line that matters. `29/31` means two Pods have no `CiliumEndpoint` — almost always Pods that were running under a previous CNI and were never restarted, or hostNetwork Pods (which are correctly excluded from the denominator).

### 9.2 Level 1 — is this node's datapath healthy?

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose
KVStore:                 Ok   Disabled
Kubernetes:              Ok   1.31 (v1.31.4) [linux/amd64]
Kubernetes APIs:         ["EndpointSliceOrEndpoint", "cilium/v2::CiliumClusterwideNetworkPolicy",
                          "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy",
                          "cilium/v2::CiliumNode", "core/v1::Namespace", "core/v1::Pods",
                          "core/v1::Service", "networking.k8s.io/v1::NetworkPolicy"]
KubeProxyReplacement:    True   [eth0   10.0.1.11 (Direct Routing)]
Host firewall:           Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.17.4 (v1.17.4-6c4f9c1a)
NodeMonitor:             Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok
IPAM:                    IPv4: 12/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.9 (health)
  10.244.1.42 (kube-system/coredns-7db6d8ff4d-4x9lp)
  10.244.1.87 (default/tiefighter-6d9b8f4c7-lm2vz)
  10.244.1.201 (default/deathstar-6f87496b94-8kx2m)
  10.244.1.254 (router)
ClusterMesh:             0/0 remote clusters ready
IPv4 BIG TCP:            Disabled
IPv6 BIG TCP:            Disabled
BandwidthManager:        Disabled
Routing:                 Network: Native   Host: BPF
Attach Mode:             TCX
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:    ktime
Controller Status:       58/58 healthy
Proxy Status:            OK, ip 10.244.1.254, 0 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:   min 256, max 65535
Hubble:                  Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 41.72   Metrics: Ok
Encryption:              Disabled
Cluster health:          4/4 reachable   (2026-09-01T12:03:44Z)
  Name                     IP              Node        Endpoints
  leloir/worker-01 (localhost)   10.0.1.11   reachable   reachable
  leloir/control-01              10.0.1.10   reachable   reachable
  leloir/worker-02               10.0.1.12   reachable   reachable
  leloir/worker-03               10.0.1.13   reachable   reachable
Modules Health:          Stopped(0) Degraded(0) OK(102)
BPF Maps:                dynamic sizing: on (ratio: 0.002500)
  Name                          Size
  Auth                          524288
  Non-TCP connection tracking   147903
  TCP connection tracking       295807
  Endpoint policy               65535
  IPv4 masquerading agent       16384
  IPv4 fragmentation            8192
  IPv4 service                  65536
  IPv4 service backend          65536
  IPv4 service reverse NAT      65536
  Metrics                       1024
  NAT                           295807
  Neighbor table                295807
  Global policy                 16384
  Session affinity              65536
  Signal                        8
  Sockmap                       65535
  Sock reverse NAT              65536
  Tunnel                        65536
```

Every line here is a diagnostic. Read `Controller Status: 58/58 healthy` and `Modules Health: ... Degraded(0)` first — a non-zero degraded count names the failing subsystem.

### 9.3 Level 2 — does traffic actually work?

```
$ cilium connectivity test --test-concurrency 2
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [leloir] Creating namespace cilium-test-1 for connectivity check...
✨ [leloir] Deploying echo-same-node service...
✨ [leloir] Deploying DNS test server configmap...
✨ [leloir] Deploying same-node deployment...
✨ [leloir] Deploying client deployment...
✨ [leloir] Deploying client2 deployment...
✨ [leloir] Deploying echo-other-node service...
⌛ [leloir] Waiting for deployment cilium-test-1/client to become ready...
⌛ [leloir] Waiting for pod cilium-test-1/client-6f8b7d9c4-2xk8p to reach DNS server...
⌛ [leloir] Waiting for CiliumEndpoint for pod cilium-test-1/echo-same-node-...
🏃[cilium-test-1] Running 87 tests ...
[=] [cilium-test-1] Test [no-policies] [1/87]
.........................
[=] [cilium-test-1] Test [no-policies-from-outside] [2/87]
....
[=] [cilium-test-1] Test [allow-all-except-world] [4/87]
..........
[=] [cilium-test-1] Test [client-ingress] [5/87]
..
[=] [cilium-test-1] Test [echo-ingress] [8/87]
....
[=] [cilium-test-1] Test [dns-only] [21/87]
........
[=] [cilium-test-1] Test [to-fqdns] [22/87]
......
✅ [cilium-test-1] All 87 tests (412 actions) successful, 19 tests skipped, 0 scenarios skipped.
```

Skipped tests are informative: `19 tests skipped` typically means encryption, Cluster Mesh, Ingress and egress-gateway suites were skipped because those features are disabled. Run with `--test '!pod-to-pod-encryption'` style filters to narrow scope, and `--flow-validation=disabled` on clusters with monitor aggregation set high.

### 9.4 Level 3 — observe the flows

```
$ cilium hubble port-forward &
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 65,532/65,532 (100.00%)
Flows/s: 167.44
Connected Nodes: 4/4

$ hubble observe --namespace default --follow
Sep  1 12:04:11.219: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) -> kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) to-endpoint FORWARDED (UDP)
Sep  1 12:04:11.220: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) -> kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) dns-request proxy FORWARDED (DNS Query deathstar.default.svc.cluster.local. A)
Sep  1 12:04:11.221: default/tiefighter-6d9b8f4c7-lm2vz:44210 (ID:24512) <- kube-system/coredns-7db6d8ff4d-4x9lp:53 (ID:6789) dns-response proxy FORWARDED (DNS Answer "10.96.184.22" TTL: 30)
Sep  1 12:04:11.223: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) -> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) to-endpoint FORWARDED (TCP Flags: SYN)
Sep  1 12:04:11.224: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) -> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) http-request FORWARDED (HTTP/1.1 POST http://deathstar.default.svc.cluster.local/v1/request-landing)
Sep  1 12:04:11.229: default/tiefighter-6d9b8f4c7-lm2vz:51884 (ID:24512) <- default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) http-response FORWARDED (HTTP/1.1 200 6ms (POST http://deathstar.default.svc.cluster.local/v1/request-landing))
```

Notice the identity numbers in every line — Hubble reports the *identity*, not just the name. That is what makes drop attribution unambiguous.

Denied traffic:

```
$ hubble observe --verdict DROPPED --last 5
Sep  1 12:07:02.110: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 12:07:02.110: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 12:07:03.145: default/xwing-7c9f5b6d8-q4mzn:38104 (ID:41022) <> default/deathstar-6f87496b94-8kx2m:8080 (ID:35109) Policy denied DROPPED (TCP Flags: SYN)
```

The pair `policy-verdict:none INGRESS DENIED` + `Policy denied DROPPED` tells you: (a) enforcement happened on **ingress**, (b) at the **destination** endpoint, (c) **no** rule matched (`:none`; contrast with `policy-verdict:L3-Only ALLOWED`).

---

## 10. Failure diagnosis: a working runbook

### 10.1 Symptom → command → cause

| Symptom | First command | Likely causes |
|---|---|---|
| Nodes `NotReady`, `container runtime network not ready` | `kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=100` | CNI conf not written; agent crash-looping; `k8sServiceHost` missing with no kube-proxy |
| `cilium-agent` CrashLoopBackOff, `Unable to mount BPF filesystem` | `mount \| grep bpf` on the node | `/sys/fs/bpf` not mounted; the init container should do it — check `hostPath` mounts and node security policy |
| Agent logs verifier errors, endpoints stuck `regenerating` | `kubectl -n kube-system logs ds/cilium -c cilium-agent \| grep -A40 "Verifier analysis"` | Kernel too old for a requested feature; disable the feature or upgrade |
| Pods get IPs but no connectivity between nodes | `cilium-dbg bpf ipcache list` on both nodes; `cilium-dbg status \| grep Routing` | Native routing without underlay routes; `autoDirectNodeRoutes` on a routed (non-L2) underlay; firewall blocking UDP/8472 |
| Handshake OK, large transfers hang | `cilium-dbg status \| grep MTU`; `ping -M do -s 1422` | MTU mismatch after enabling tunneling or encryption |
| Random 5 s DNS latency | `hubble observe --protocol dns --verdict DROPPED` | Conntrack pressure, or DNS proxy backlog; check `cilium_ct_any4_global` occupancy |
| Services resolve but connections refuse | `cilium-dbg service list \| grep <clusterIP>` | Service master entry with zero backends → EndpointSlice not ready |
| `kubectl exec/logs` broken but Pod networking fine | `cilium-dbg bpf ipcache list \| grep <nodeIP>` | Missing `reserved:host`/`remote-node` entry; kube-proxy remnants; host firewall misconfigured |
| Policy not enforced at all | `cilium-dbg endpoint list` (ENFORCEMENT columns) | Policy selects nothing (label typo); `policyAuditMode: true`; `policyEnforcementMode: never` |
| Policy over-enforced after install | `cilium-dbg policy get` | A cluster-wide default-deny you forgot; DNS egress not allowed |
| New Pods fail to start, `failed to allocate IP` | `kubectl get ciliumnode <node> -o yaml` | Node pod CIDR exhausted; raise `clusterPoolIPv4MaskSize` scope or add CIDRs |
| Intermittent drops under load | `cilium-dbg bpf ct list global \| wc -l`; `cilium-dbg map get cilium_ct4_global` | CT/NAT map at capacity → LRU eviction of live flows. Raise `bpf.ctTcpMax`/`bpf.natMax` |
| `Policy map is full` in logs | `cilium-dbg map get cilium_policy_v2_<id>` | >16384 policy entries on one endpoint, usually from a huge `toCIDR` set — use `CiliumCIDRGroup` or aggregate prefixes |

### 10.2 Reading drops from the datapath directly

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --type policy-verdict
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
Policy verdict log: flow 0x1f3ac2b1 local EP ID 1420, remote ID 41022, proto 6, ingress true, action deny, auth: disabled, match none, 10.244.3.55:38104 -> 10.244.1.201:8080 tcp SYN
xx drop (Policy denied) flow 0x1f3ac2b1 to endpoint 1420, ifindex 24, file bpf_lxc.c:2145, , identity 41022->35109: 10.244.3.55:38104 -> 10.244.1.201:8080 tcp SYN
```

The `file bpf_lxc.c:2145` field is not decoration — it is the exact source location in the datapath that dropped the packet, which distinguishes "policy denied at the destination endpoint" from "policy denied on egress at the source".

Aggregate counters:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf metrics list
REASON                           DIRECTION   PACKETS   BYTES
Policy denied                    INGRESS     1247      74820
Success                          EGRESS      8829143   1204987222
Success                          INGRESS     8814002   994201338
Stale or unroutable IP           EGRESS      12        720
Unsupported L3 protocol          INGRESS     3         198
CT: Map insertion failed         EGRESS      0         0
Service backend not found        EGRESS      41        2460
```

**Drop reasons you must be able to interpret:**

| Reason | Meaning | Typical root cause |
|---|---|---|
| `Policy denied` | Policy map lookup returned no allow entry | Missing/incorrect CNP; identity not what you assumed |
| `Stale or unroutable IP` | ipcache has no entry, or the tunnel endpoint is unknown | Node just joined; ipcache not yet propagated; deleted endpoint |
| `Service backend not found` | LB map has a frontend but the selected backend slot is empty | EndpointSlice churn; backend in `terminating` |
| `CT: Map insertion failed` | Conntrack map full | Undersized `ctTcpMax`/`ctAnyMax` for the connection rate |
| `Unsupported protocol for NAT masquerade` | Masquerade path saw a protocol it cannot rewrite | SCTP/GRE/ESP egress to the internet |
| `No mapping for NAT masquerade` | Reverse NAT lookup failed | NAT map eviction under pressure |
| `Missed tail call` | A tail-call slot was not populated | Datapath reload race; usually transient at agent start |
| `Authentication required` | Mutual auth policy in effect, identity not yet authenticated | SPIFFE/mTLS auth handshake pending |
| `VXLAN traffic disallowed` | Tunnel packet from an unexpected source | Node not in the ipcache as `remote-node`; spoofing guard |

### 10.3 Confirming the eBPF programs are actually attached

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool net show
xdp:

tc:
eth0(2) tcx/ingress cil_from_netdev prog_id 1842
eth0(2) tcx/egress cil_to_netdev prog_id 1847
cilium_host(4) tcx/ingress cil_to_host prog_id 1855
cilium_host(4) tcx/egress cil_from_host prog_id 1861
cilium_net(3) tcx/ingress cil_to_host prog_id 1866
lxc9f21c4a3b70e(24) tcx/ingress cil_from_container prog_id 1902
lxc9f21c4a3b70e(24) tcx/egress cil_to_container prog_id 1907

flow_dissector:

netfilter:

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool cgroup show /run/cilium/cgroupv2
ID     AttachType      AttachFlags     Name
1783   cgroup_inet4_connect               cil_sock4_connect
1785   cgroup_inet4_post_bind             cil_sock4_post_bind
1787   cgroup_inet4_getpeername           cil_sock4_getpeername
1789   cgroup_udp4_sendmsg                cil_sock4_sendmsg
1791   cgroup_udp4_recvmsg                cil_sock4_recvmsg

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- bpftool map show | head -20
12: lpm_trie  name cilium_ipcache  flags 0x1
        key 20B  value 16B  max_entries 512000  memlock 40960000B
14: hash  name cilium_lxc  flags 0x0
        key 20B  value 48B  max_entries 65535  memlock 7864320B
19: lru_hash  name cilium_ct4_global  flags 0x0
        key 20B  value 56B  max_entries 295807  memlock 30474240B
23: hash  name cilium_lb4_services_v2  flags 0x1
        key 12B  value 20B  max_entries 65536  memlock 5242880B
27: hash  name cilium_lb4_backends_v3  flags 0x1
        key 4B  value 16B  max_entries 65536  memlock 2621440B
31: perf_event_array  name cilium_events  flags 0x0
        key 4B  value 4B  max_entries 8
```

`tcx/ingress` (rather than the older `clsact` qdisc filters) indicates the **TCX** attach mode available on kernel ≥ 6.6, which gives Cilium a stable, ordered attachment that other tc users cannot silently displace. On older kernels you will see `clsact/ingress` instead and should check `tc filter show dev eth0 ingress` for competing programs.

### 10.4 Cilium's own health mesh

Cilium runs a `reserved:health` endpoint per node and continuously probes every other node's health endpoint over both the node IP and the pod-network path:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg-health status
Probe time:   2026-09-01T12:09:12Z
Nodes:
  leloir/worker-01 (localhost):
    Host connectivity to 10.0.1.11:
      ICMP to stack:   OK, RTT=201.44µs
      HTTP to agent:   OK, RTT=142.77µs
    Endpoint connectivity to 10.244.1.9:
      ICMP to stack:   OK, RTT=188.02µs
      HTTP to agent:   OK, RTT=317.19µs
  leloir/worker-03:
    Host connectivity to 10.0.1.13:
      ICMP to stack:   OK, RTT=1.221ms
      HTTP to agent:   OK, RTT=1.884ms
    Endpoint connectivity to 10.244.3.9:
      ICMP to stack:   Connection timed out
      HTTP to agent:   Connection timed out
```

This output is a precise bisection: **host connectivity OK but endpoint connectivity failing** means the underlay is fine and the *pod-network* path to that node is broken — MTU, tunnel port blocked, missing route, or missing ipcache entry. Host failing too means the underlay itself.

### 10.5 When you need to escalate

```
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M%S)
🔍 Collecting Kubernetes nodes
🔍 Collecting Kubernetes events
🔍 Collecting Kubernetes namespaces
🔍 Collecting Cilium network policies
🔍 Collecting Cilium endpoints
🔍 Collecting Cilium identities
🔍 Collecting Cilium BPF maps
🔍 Collecting cilium-bugtool output from Cilium pods
🔍 Collecting logs from Cilium pods
🔍 Collecting gops stats from Cilium pods
⚠️  The sysdump may contain sensitive information (e.g. Kubernetes secrets are NOT collected)
✅ Collected sysdump at "cilium-sysdump-20260901-121455.zip"
```

`cilium sysdump` is the single artifact to attach to a bug report or support case: it contains every command in this section, for every node, at one point in time. Collect it **before** restarting anything — restarting the agent regenerates the maps and destroys the evidence.

---

## 11. Consolidated trade-off view

### 11.1 Cilium vs. other CNIs (architectural, not marketing)

| Dimension | Flannel | Calico (iptables/eBPF) | Cilium |
|---|---|---|---|
| Datapath | VXLAN/host-gw, kernel routing | iptables/ipsets, or eBPF mode | eBPF (tc/XDP/cgroup) |
| Policy identity | none (no policy) | IP sets derived from label selectors | **numeric security identity**, label-derived |
| Policy layers | — | L3/L4 (+ limited L7 via Envoy sidecar-less in Calico Cloud) | L3/L4 **and native L7** (HTTP, gRPC, Kafka, DNS) via embedded Envoy |
| kube-proxy replacement | no | yes (eBPF mode) | yes, including socket LB + Maglev + DSR |
| Observability | none | flow logs (Enterprise) | **Hubble** — identity-aware flows, L7, metrics, service map, all OSS |
| Multi-cluster | no | limited | Cluster Mesh with global services and mesh-wide identities |
| Transparent encryption | no | WireGuard | WireGuard and IPsec, plus node-to-node |
| Egress gateway | no | Enterprise | OSS |
| L2/BGP | host-gw | BGP (BIRD/GoBGP) | BGP control plane, L2 announcements, LB-IPAM |
| Kernel floor | low | low (higher for eBPF mode) | **higher** — real 5.4+/5.10+ requirements |
| Operational complexity | very low | medium | **high** — the price of the feature surface |

Be honest about the last row in an interview or a design review: Cilium's failure modes require kernel-level literacy. That is the trade.

### 11.2 Feature-to-kernel matrix

| Capability | Minimum kernel |
|---|---:|
| Base Cilium (recent releases) | 5.4 |
| Socket LB (`connect`/`sendmsg` hooks) | 4.19 (5.7 for full `getpeername`) |
| BPF host routing (`bpf_redirect_peer`) | 5.10 |
| eBPF masquerading | 5.4 |
| WireGuard transparent encryption | 5.6 |
| Bandwidth Manager (EDT + `fq`) | 5.1 (BBR needs 5.18) |
| Egress Gateway | 5.10 |
| IPv6 BIG TCP | 5.19 |
| IPv4 BIG TCP | 6.3 |
| TCX attach mode | 6.6 |
| netkit device mode | 6.8 |

Always confirm against the release's own *System Requirements* page rather than memory — these floors move between minor versions.

### 11.3 Twelve facts worth memorizing for the exam

1. Identity comes from **filtered labels**, not IPs; identical label sets share one identity.
2. Reserved identities: `1 host`, `2 world`, `4 health`, `6 remote-node`, `7 kube-apiserver`.
3. Cluster-global identities: **256–65535**. CIDR/FQDN identities are **node-local**, ≥ `1<<24`.
4. The **ipcache** (LPM trie) maps IP/CIDR → identity + tunnel endpoint, and is what lets the *source* node enforce egress policy.
5. Egress policy is enforced at the source node; ingress policy at the destination node.
6. `cilium-agent` is not in the datapath; the eBPF maps are. Agent down ≠ traffic down.
7. `cilium` (host CLI) ≠ `cilium-dbg` (in-pod CLI).
8. Default routing mode is **tunnel/VXLAN**; `native` requires the underlay to route Pod CIDRs.
9. VXLAN/Geneve cost **50 bytes** of MTU; WireGuard adds **80** more.
10. Socket LB translates ClusterIP at `connect()` — east-west service traffic has **no per-packet NAT** and no service conntrack entry.
11. `kubeProxyReplacement: true` requires `k8sServiceHost`/`k8sServicePort` when kube-proxy is absent.
12. Policy enforcement is per-endpoint **and per-direction**, and turns on for a direction only when a rule selects that endpoint in that direction.

---

## 12. Referencias

**CNCF / certification**
- CCA curriculum (source of record for domains and weights): https://github.com/cncf/curriculum/blob/master/cca/README.md
- CNCF curriculum repository: https://github.com/cncf/curriculum
- Cilium Certified Associate program page: https://training.linuxfoundation.org/certification/cilium-certified-associate-cca/

**Cilium official documentation**
- Documentation root: https://docs.cilium.io/en/stable/
- Component overview / architecture: https://docs.cilium.io/en/stable/overview/component-overview/
- Introduction and use cases: https://docs.cilium.io/en/stable/overview/intro/
- eBPF datapath internals: https://docs.cilium.io/en/stable/reference-guides/bpf/
- Life of a packet: https://docs.cilium.io/en/stable/reference-guides/bpf/progtypes/
- Security identity model: https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Endpoint lifecycle: https://docs.cilium.io/en/stable/reference-guides/bpf/architecture/
- Routing modes (encapsulation / native): https://docs.cilium.io/en/stable/network/concepts/routing/
- IPAM concepts and modes: https://docs.cilium.io/en/stable/network/concepts/ipam/
- kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Masquerading: https://docs.cilium.io/en/stable/network/concepts/masquerading/
- MTU configuration: https://docs.cilium.io/en/stable/network/mtu/
- System requirements (kernel versions): https://docs.cilium.io/en/stable/operations/system_requirements/
- Helm reference (every value): https://docs.cilium.io/en/stable/helm-reference/
- Installation with Helm: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Installation with the Cilium CLI: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
- Kind quick install: https://docs.cilium.io/en/stable/installation/kind/
- Troubleshooting guide: https://docs.cilium.io/en/stable/operations/troubleshooting/
- Command cheat sheet: https://docs.cilium.io/en/stable/cheatsheet/
- `cilium-dbg` command reference: https://docs.cilium.io/en/stable/cmdref/cilium-dbg/
- Custom Resource Definitions: https://docs.cilium.io/en/stable/network/kubernetes/ciliumendpoint/
- Network policy concepts: https://docs.cilium.io/en/stable/security/policy/
- Hubble (setup and use): https://docs.cilium.io/en/stable/observability/hubble/
- Performance tuning guide: https://docs.cilium.io/en/stable/operations/performance/tuning/
- Cluster Mesh concepts: https://docs.cilium.io/en/stable/network/clustermesh/

**Source and upstream projects**
- Cilium source (datapath under `bpf/`): https://github.com/cilium/cilium
- Cilium CLI: https://github.com/cilium/cilium-cli
- Hubble: https://github.com/cilium/hubble
- eBPF project site and documentation: https://ebpf.io/
- Kernel BPF documentation: https://docs.kernel.org/bpf/
- `bpftool` documentation: https://docs.kernel.org/bpf/bpftool.html

**Kubernetes**
- Cluster networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Service `ClusterIP`/`NodePort`/`LoadBalancer`: https://kubernetes.io/docs/concepts/services-networking/service/
- NetworkPolicy: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- `kube-proxy` reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- CNI specification: https://github.com/containernetworking/cni/blob/main/SPEC.md