# 2.1 Cilium Architecture & Components

**Domain weight: 20%** — this is the single heaviest block of the CCA. Almost every other domain (policy, service mesh, ClusterMesh, observability, troubleshooting) is a *consequence* of the architecture described here. If you can draw the component graph, name the eBPF maps behind each feature, and explain what breaks when each process dies, the rest of the exam becomes deduction rather than memorisation.

---

## 1. The production problem Cilium exists to solve

### 1.1 The IP-address identity crisis

Kubernetes networking inherited a 1990s assumption: **an IP address identifies a workload**. `NetworkPolicy`, `iptables`, security groups, firewalls and audit logs all encode this assumption. In a cluster where a Deployment rolls every 40 seconds, the assumption is false in a way that is not merely inconvenient — it is a *correctness* problem:

* Pod `10.244.3.17` is `payments-api` at 14:02:11 and `crypto-miner-debug-shell` at 14:02:19.
* An `iptables` rule referencing `10.244.3.17` is a **race condition with a security consequence**. The window between pod deletion, IP reuse and rule reprogramming is a real, exploited gap.
* Cross-cluster and cross-cloud, the IP space overlaps outright. `10.244.0.0/16` in `eu-prod` and `10.244.0.0/16` in `us-prod` are different workloads with identical addresses.

Cilium's foundational architectural decision is to **decouple policy from addressing**: every workload is assigned a *security identity*, a numeric value derived from its labels, and the datapath enforces policy on `(source identity, destination identity, port, protocol, L7 rule)`. IPs become a lookup key into an identity table (`ipcache`), not the subject of policy.

### 1.2 The `kube-proxy` scaling wall

`kube-proxy` in `iptables` mode builds a linear chain of rules per Service and per backend. Rule evaluation is **O(n)** in the number of Services, and — critically — every update rewrites and atomically reloads the whole table via `iptables-restore`.

Real production numbers from large clusters:

| Services | iptables rules (approx) | `iptables-restore` reload latency | Per-packet lookup |
|---|---|---|---|
| 1,000 | ~20,000 | ~250 ms | O(n) chain walk |
| 5,000 | ~100,000 | ~2–5 s | O(n) chain walk |
| 20,000 | ~400,000 | 30 s – several minutes | O(n) chain walk |

At the top of that table, a single Deployment scale event stalls Service programming cluster-wide for minutes. Meanwhile the eBPF datapath uses a **hash map lookup — O(1)** — and updates a *single map entry* for a single backend change, with no global reload and no lock.

### 1.3 The sidecar tax

The classic service-mesh model injects an Envoy sidecar per pod. Each L7-processed request traverses the network stack **four extra times** (pod → sidecar loopback, sidecar → host, host → sidecar, sidecar → pod), costing latency, ~50–100 MiB RSS per pod, and an operational burden of injection webhooks and lifecycle races (`istio-proxy` outliving the app container, init-order deadlocks).

Cilium's answer is **one Envoy per node**, reached through eBPF socket redirection rather than iptables `REDIRECT`, and only for traffic that actually needs L7 semantics. Everything else stays in the kernel.

### 1.4 The observability black hole

`tcpdump` on a busy node is a sampling tool at best and a production incident at worst. Flow logs from a CNI that only sees IPs cannot answer *"which service called which service"*. Cilium emits events from the datapath itself, already annotated with source identity, destination identity, verdict, drop reason and (for L7) HTTP method/path or DNS query — because the enforcement point and the observation point are the same eBPF program.

> **Architectural thesis to remember for the exam:** Cilium moves connectivity, security and observability into a *single* programmable kernel datapath, keyed on *identity*, programmed by a *per-node agent*, coordinated by CRDs in the Kubernetes API server.

---

## 2. eBPF: the substrate, in the depth the exam expects

eBPF is a sandboxed virtual machine inside the Linux kernel. Programs are:

1. **Written** in restricted C, compiled by LLVM/clang to eBPF bytecode.
2. **Verified** at load time — the verifier proves termination (bounded loops), memory safety (every pointer dereference is range-checked), and privilege correctness. A program that cannot be proven safe is *rejected*; it cannot panic the kernel.
3. **JIT-compiled** to native machine code, so it runs at near-native speed.
4. **Attached** to a hook, where it executes on every event at that hook.
5. **Stateful** via *maps* — kernel data structures shared between eBPF programs and userspace.

### 2.1 Hook points used by the Cilium datapath

| Hook | Kernel attach point | Cilium object | What runs there |
|---|---|---|---|
| **XDP** | NIC driver, pre-`sk_buff` | `bpf_xdp.o` | NodePort/LB acceleration, DDoS drops, `cilium_lb4_*` lookups at line rate |
| **tc ingress/egress** (`clsact` qdisc) | After `sk_buff` allocation | `bpf_lxc.o` | Per-endpoint policy enforcement, identity resolution, CT, L7 redirect |
| **tc on host device** | Physical/bond NIC | `bpf_host.o`, `bpf_netdev.o` | Host firewall, NodePort, masquerading, encryption steering |
| **tc on tunnel device** | `cilium_vxlan` / `cilium_geneve` | `bpf_overlay.o` | Decapsulation, identity extraction from tunnel metadata |
| **cgroup v2 socket ops** | `connect()`, `sendmsg()`, `recvmsg()`, `getpeername()` | `bpf_sock.o` | **Socket-based load balancing** — Service VIP → backend translated *before a packet exists* |
| **sockmap / sockops** | TCP socket establishment | `bpf_sockops.o` | Same-node socket-level forwarding (bypasses TCP/IP stack entirely) |
| **tracing / kprobes** | Kernel functions | monitor helpers | Drop reasons, trace notifications |

The consequence of the **cgroup connect hook** is the single most exam-relevant fact about the datapath: with `kube-proxy` replacement enabled, a pod connecting to `10.96.0.1:443` never sends a packet to `10.96.0.1`. `connect()` itself rewrites the destination to a backend pod IP. There is **no DNAT on the packet path, no conntrack entry for the VIP, and no reverse translation cost**.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep -A6 'KubeProxyReplacement'
KubeProxyReplacement:    True   [eth0   10.0.1.11 fe80::5054:ff:fe12:3456 (Direct Routing)]
  Protocols:             TCP, UDP
  Devices:               eth0   10.0.1.11 fe80::5054:ff:fe12:3456 (Direct Routing)
  Mode:                  SNAT
  Backend Selection:     Random
  Session Affinity:      Enabled
  Graceful Termination:  Enabled
  NAT46/64 Support:      Disabled
  XDP Acceleration:      Native
  Services:
  - ClusterIP:      Enabled
  - NodePort:       Enabled (Range: 30000-32767)
  - LoadBalancer:   Enabled
  - externalIPs:    Enabled
  - HostPort:       Enabled
```

### 2.2 The eBPF maps you must be able to name

Maps *are* the datapath state. Every feature in Cilium is "a map plus a program that reads it".

| Map | Type | Scope | Purpose | Inspect with |
|---|---|---|---|---|
| `cilium_lxc` | hash | node | Endpoint (pod) index: IP → endpoint ID, identity, MAC, ifindex | `cilium-dbg bpf endpoint list` |
| `cilium_ipcache` | LPM trie | node | **IP/CIDR → security identity + tunnel endpoint** — the identity resolution table | `cilium-dbg bpf ipcache list` |
| `cilium_policy_v2_<epID>` | hash | endpoint | Allowed `(identity, port, proto, direction)` tuples for one endpoint | `cilium-dbg bpf policy get <epID>` |
| `cilium_ct4_global` / `cilium_ct6_global` | LRU hash | node | Connection tracking (TCP), also stores policy verdict for the flow | `cilium-dbg bpf ct list global` |
| `cilium_ct_any4_global` | LRU hash | node | Non-TCP conntrack (UDP, ICMP) | `cilium-dbg bpf ct list global` |
| `cilium_lb4_services_v2` | hash | node | Service frontend (VIP:port) → backend slot count + flags | `cilium-dbg bpf lb list` |
| `cilium_lb4_backends_v3` | hash | node | Backend ID → pod IP:port, state (active/terminating/quarantined) | `cilium-dbg bpf lb list --backends` |
| `cilium_lb4_reverse_nat` | hash | node | Reverse translation for SNAT-mode NodePort replies | `cilium-dbg bpf lb list --revnat` |
| `cilium_lb4_affinity` | LRU hash | node | `sessionAffinity: ClientIP` state | — |
| `cilium_lb4_maglev` | hash of arrays | node | Maglev consistent-hash backend tables | `cilium-dbg bpf lb maglev list` |
| `cilium_snat_v4_external` | LRU hash | node | eBPF masquerading NAT table | `cilium-dbg bpf nat list` |
| `cilium_tunnel_map` | hash | node | Remote pod CIDR / IP → remote node IP (VXLAN/Geneve endpoint) | `cilium-dbg bpf tunnel list` |
| `cilium_node_map` | hash | node | Node ID ↔ node IP (used by encryption, egress gateway) | `cilium-dbg bpf nodeid list` |
| `cilium_events` | perf ring buffer | node | Datapath → userspace event channel feeding **Hubble** and `cilium-dbg monitor` | `cilium-dbg monitor` |
| `cilium_metrics` | per-CPU hash | node | Datapath counters (drops by reason, forwards) | `cilium-dbg bpf metrics list` |
| `cilium_egress_gw_policy_v4` | LPM trie | node | Egress gateway: `(src, dstCIDR)` → gateway + egress IP | `cilium-dbg bpf egress list` |
| `cilium_ipmasq_v4` | LPM trie | node | ip-masq-agent style non-masquerade CIDRs | `cilium-dbg bpf ipmasq list` |
| `cilium_auth_map` | hash | node | Mutual authentication (SPIFFE) state for `authentication.mode: required` | `cilium-dbg bpf auth list` |
| `cilium_l2_responder_v4` | hash | node | L2 announcements (ARP replies for LB IPs) | `cilium-dbg bpf l2responder list` |
| `cilium_call_policy` | prog array | node | **Tail-call map** — how `bpf_host.o` jumps into a per-endpoint policy program | — |

Maps live on the **bpffs** mount at `/sys/fs/bpf/tc/globals/`. This is the reason `cilium-agent` mounts bpffs from the host and *not* from an `emptyDir`: map lifetime must exceed agent lifetime, so that **an agent restart does not drop traffic**.

```
$ sudo ls /sys/fs/bpf/tc/globals/ | head -20
cilium_auth_map
cilium_call_policy
cilium_calls_00341
cilium_calls_hostns_01245
cilium_capture_cache
cilium_ct4_global
cilium_ct_any4_global
cilium_events
cilium_ipcache_v2
cilium_ipv4_frag_datagrams
cilium_lb4_affinity
cilium_lb4_backends_v3
cilium_lb4_reverse_nat
cilium_lb4_reverse_sk
cilium_lb4_services_v2
cilium_lb_affinity_match
cilium_lxc
cilium_metrics
cilium_node_map
cilium_nodeport_neigh4
```

---

## 3. The component inventory

This is the table to be able to reproduce from memory.

| Component | Kubernetes object | Cardinality | Plane | Hard dependency | Blast radius if down |
|---|---|---|---|---|---|
| **cilium-agent** | DaemonSet `cilium` | 1 per node | Control + datapath programming | kube-apiserver (or kvstore) | **Existing traffic keeps flowing** (eBPF is in-kernel). No *new* pods can be networked on that node; policy and Service updates stall for that node; Hubble flows stop |
| **cilium-cni** | binary `/opt/cni/bin/cilium-cni` | 1 per node | Datapath setup | cilium-agent unix socket | Pod sandbox creation fails on that node → `ContainerCreating` |
| **cilium-operator** | Deployment (2 replicas, HA via Lease) | 1–2 per cluster | Control | kube-apiserver | IPAM PodCIDR allocation stops (new *nodes* can't get CIDRs), identity GC stops, CiliumEndpointSlice sync stops, LB-IPAM stops, Ingress/Gateway reconciliation stops. **Existing traffic unaffected** |
| **cilium-envoy** | DaemonSet `cilium-envoy` | 1 per node | L7 datapath | cilium-agent xDS socket | L7 policy / Ingress / Gateway API / L7 mesh traffic fails. L3/L4 unaffected |
| **hubble** (embedded) | inside cilium-agent | 1 per node | Observability | `cilium_events` map | Node-local flow visibility lost |
| **hubble-relay** | Deployment | 1+ per cluster | Observability | hubble peer service on each agent | Cluster-wide `hubble observe` fails; per-node still works via `cilium-dbg monitor` |
| **hubble-ui** | Deployment | 1 per cluster | Observability | hubble-relay | Web UI down only |
| **clustermesh-apiserver** | Deployment (etcd + apiserver containers) | 1+ per *cluster* in the mesh | Control (multi-cluster) | local kube-apiserver | Remote clusters stop receiving state updates; **cached** remote endpoints keep working until stale |
| **cilium-cli** (`cilium`) | out-of-cluster binary | operator laptop / CI | Tooling | kubeconfig | Nothing; it is a client |

### 3.1 The architecture diagram to memorise

```
                     ┌──────────────────────────────────────────────┐
                     │            kube-apiserver (CRDs)             │
                     │  CiliumNetworkPolicy  CiliumEndpoint         │
                     │  CiliumIdentity       CiliumNode             │
                     │  CiliumEndpointSlice  CiliumLBIPPool ...     │
                     └───────┬──────────────────────────┬───────────┘
                             │ watch/update             │ watch/update
                             │                          │
             ┌───────────────┴─────────┐      ┌─────────┴──────────────┐
             │     cilium-operator     │      │  clustermesh-apiserver │
             │  · cluster-pool IPAM    │      │  · etcd (2379, mTLS)   │
             │  · identity GC          │      │  · exports identities, │
             │  · CES controller       │      │    endpoints, services │
             │  · LB-IPAM / BGP        │      └─────────┬──────────────┘
             │  · Ingress / GW API     │                │
             │  · CiliumEndpoint GC    │                │ remote watch
             └─────────────────────────┘                │
                                                        │
 ══════════════════════════ per node ═══════════════════│══════════════════
                                                        │
   ┌────────────────────────────────────────────────────┴─────────────────┐
   │  cilium-agent (DaemonSet, hostNetwork, privileged/CAP_*)             │
   │                                                                      │
   │  k8s watchers → StateDB/Hive cells → Endpoint Manager                │
   │        │                                  │                          │
   │        ├─► Identity Allocator ────────────┤                          │
   │        ├─► Policy Repository ─► Policy Calculation ─► SelectorCache  │
   │        ├─► IPCache / Node Discovery                                  │
   │        ├─► Service/LB Manager                                        │
   │        ├─► IPAM                                                      │
   │        ├─► DNS Proxy (ToFQDN)                                        │
   │        ├─► Hubble Observer  ──► gRPC :4244 ──► hubble-relay :4245    │
   │        └─► Datapath Loader (clang → tc/XDP/cgroup)                   │
   │                       │                                              │
   │       xDS over unix socket │  /var/run/cilium/envoy/sockets/xds.sock │
   └───────────────────────┼──────────────────────┼──────────────────────┘
                           │                      │
              ┌────────────┴─────────┐            │ writes
              │  cilium-envoy (DS)   │            ▼
              │  L7 HTTP/gRPC/Kafka  │   ┌────────────────────────────────┐
              │  Ingress / GW API    │   │  eBPF maps  /sys/fs/bpf/tc/... │
              └──────────────────────┘   │  + programs on XDP/tc/cgroup   │
                                         └────────────────────────────────┘
                                                    ▲
              ┌──────────────┐   CNI ADD/DEL        │ writes cilium_lxc
              │  containerd  ├──► /opt/cni/bin/cilium-cni ──► agent unix sock
              └──────────────┘
```

---

## 4. `cilium-agent` internals

The agent is a Go binary built on **Hive**, a dependency-injection framework organising the agent into *cells* (modules with explicit lifecycles). Recent versions expose runtime state through **StateDB**, an in-memory, transactional, immutable-radix-tree database with tables for devices, routes, node addresses, health, and more.

### 4.1 Subsystems

**Kubernetes watchers.** Informers over `Pod`, `Service`, `EndpointSlice`, `Node`, `Namespace`, `NetworkPolicy`, and every Cilium CRD. The agent is a *reader* of intent and a *writer* of status (`CiliumEndpoint`, `CiliumNode`).

**Endpoint Manager.** Owns the lifecycle of every local endpoint. An *endpoint* is anything with a Cilium-managed network interface: a pod, the host itself (`reserved:host`), the health endpoint, and the ingress endpoint. Each has a node-local numeric **endpoint ID** and a state machine:

```
waiting-for-identity → waiting-to-regenerate → regenerating → ready
                                     ↑                │
                                     └── disconnected ┘
```

**Identity Allocator.** Converts a label set into a numeric identity. In CRD mode (default) it does this by creating/reusing a `CiliumIdentity` object; in kvstore mode, by a key in etcd. Allocation is *cluster-global* — the same label set yields the same identity on every node, which is what makes distributed policy enforcement coherent.

**Policy Repository + SelectorCache.** Holds all `CiliumNetworkPolicy`, `CiliumClusterwideNetworkPolicy` and upstream `NetworkPolicy` objects. On any change, it recomputes which identities each selector matches and produces, per endpoint, a flat set of allowed `(identity, port, protocol, L7-redirect)` entries. Only endpoints whose *effective* policy changed are regenerated — this incrementality is why a 5,000-pod cluster does not melt when one policy is edited.

**IPCache.** The bridge between addressing and identity. Every known IP in the cluster (local pods, remote pods, nodes, external CIDRs from policy, FQDN-resolved IPs) maps to an identity and, in tunnel mode, to the node that owns it. Written into the `cilium_ipcache` LPM trie.

**Datapath Loader.** Renders per-endpoint C headers (`ep_config.h`), compiles with clang (using a **template cache** so identical configurations reuse a pre-compiled object), and attaches via `tc`/`bpf` netlink. Object files and headers per endpoint live under `/var/run/cilium/state/<endpointID>/`.

**Proxies.** The **DNS proxy** is *in-process in the agent* (not Envoy) — it intercepts DNS via tproxy for `toFQDNs` rules and populates the FQDN cache and ipcache. **Envoy** handles HTTP/gRPC/Kafka L7 policy and Ingress/Gateway API.

**cilium-health.** Probes every other node over ICMP and HTTP on port **4240**, both node-IP-to-node-IP and health-endpoint-to-health-endpoint (via the `cilium_health` veth), which distinguishes *node reachability* from *pod-network reachability*.

**Monitor.** Reads the `cilium_events` perf ring buffer and fans out to `cilium-dbg monitor` clients and to the Hubble observer.

### 4.2 The endpoint regeneration pipeline

This is the highest-value internal flow for troubleshooting:

```
1. Trigger      : new pod / label change / policy change / identity change
2. Identity     : labels → allocate or resolve numeric identity (CiliumIdentity)
3. Policy calc  : SelectorCache → resolved L4 + L7 policy map entries
4. Header gen   : write ep_config.h into /var/run/cilium/state/<epID>/
5. Compile      : clang → bpf_lxc.o   (template cache hit ⇒ skipped)
6. Load         : tc filter replace on the veth (ingress + egress)
7. Map update   : cilium_policy_v2_<epID>, cilium_lxc, cilium_ipcache
8. State        : endpoint → ready ; CiliumEndpoint status updated
```

Latency of a **cold** regeneration (compile) is hundreds of milliseconds; a **warm** one (template hit, map update only) is single-digit milliseconds. This is why label churn on a large Deployment is cheap but a config change forcing global recompilation is not.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])                              IPv6   IPv4          STATUS
           ENFORCEMENT        ENFORCEMENT                                                                                                ENFORCEMENT
164        Enabled            Disabled          46212      k8s:app=payments-api                                            10.244.1.87   ready
                                                           k8s:io.cilium.k8s.policy.cluster=eu-prod
                                                           k8s:io.cilium.k8s.policy.serviceaccount=payments
                                                           k8s:io.kubernetes.pod.namespace=payments
712        Disabled           Disabled          4          reserved:health                                                 10.244.1.201  ready
1188       Enabled            Enabled           52901      k8s:app=frontend                                                10.244.1.14   ready
                                                           k8s:io.cilium.k8s.policy.cluster=eu-prod
                                                           k8s:io.kubernetes.pod.namespace=shop
2455       Disabled           Disabled          1          reserved:host                                                                 ready
3021       Enabled            Disabled          16777231   reserved:ingress                                                10.244.1.3    ready
```

Read that table carefully — it is a favourite exam shape:

* `POLICY ENFORCEMENT` is **per direction**. `Disabled` means *no policy selects this endpoint in that direction*, so everything is allowed (default-allow). It does **not** mean traffic is blocked.
* Identity `4` = `reserved:health`, `1` = `reserved:host` — reserved identities, not label-derived.
* `16777231` is above `2^24` → a **node-local** identity (see §6.2).

---

## 5. `cilium-operator`

The operator handles work that must happen **once per cluster**, not once per node. It is deliberately **off the datapath**: no packet ever depends on it.

| Responsibility | Detail | Failure symptom |
|---|---|---|
| **Cluster-pool IPAM** | Carves `/24`s out of `clusterPoolIPv4PodCIDRList` and writes them to `CiliumNode.spec.ipam.podCIDRs` | New nodes stay `NotReady`, agent logs `waiting for IPAM to be initialized` |
| **Cloud IPAM (ENI/Azure/AlibabaCloud)** | Talks to the cloud API to attach ENIs/IPs and pre-allocate a warm pool | Pods stuck `ContainerCreating`, `failed to allocate IP` |
| **Identity garbage collection** | Deletes `CiliumIdentity` objects with no live endpoint; heartbeat-based | Identity leak → etcd/API server bloat, eventual identity exhaustion |
| **CiliumEndpoint GC** | Removes stale `CiliumEndpoint` objects for dead pods | Stale flows attributed to dead workloads |
| **CiliumEndpointSlice controller** | Batches `CiliumEndpoint` into slices to cut apiserver watch traffic at scale | High apiserver load at 5k+ pods |
| **LB-IPAM** | Assigns `status.loadBalancer.ingress` IPs from `CiliumLoadBalancerIPPool` | `Service type=LoadBalancer` stays `<pending>` |
| **Ingress / Gateway API** | Translates `Ingress` and Gateway API objects into `CiliumEnvoyConfig` | Ingress routes never program |
| **kvstore heartbeat** | Writes a heartbeat key so agents can detect a dead kvstore | Agents can't tell stale kvstore from healthy |
| **Node GC** | Deletes `CiliumNode` for removed nodes | Tunnels and ipcache entries to dead nodes linger |

HA is **active/passive leader election** on a `Lease` in `kube-system`:

```
$ kubectl -n kube-system get lease cilium-operator-resource-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
cilium-operator-6c9d4f7b8d-x2r4k

$ kubectl -n kube-system logs deploy/cilium-operator | grep -i leader
level=info msg="Leading the operator HA deployment" subsys=cilium-operator-generic
```

---

## 6. The identity model

### 6.1 From labels to a number

Not all labels participate. By default, `k8s:` labels are used **except** a filtered set (`pod-template-hash`, `controller-revision-hash`, `statefulset.kubernetes.io/pod-name`, annotations). This is deliberate: including `pod-template-hash` would mint a fresh identity on every rollout, defeating the whole design. The filter is configurable via the `labels` ConfigMap key.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity list | head -12
ID         LABELS
1          reserved:host
2          reserved:world
4          reserved:health
5          reserved:init
6          reserved:remote-node
7          reserved:kube-apiserver
8          reserved:ingress
46212      k8s:app=payments-api
           k8s:io.cilium.k8s.namespace.labels.env=prod
           k8s:io.cilium.k8s.policy.cluster=eu-prod
           k8s:io.cilium.k8s.policy.serviceaccount=payments
           k8s:io.kubernetes.pod.namespace=payments
```

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg identity get 46212 -o json | jq '.[0].labels'
[
  "k8s:app=payments-api",
  "k8s:io.cilium.k8s.namespace.labels.env=prod",
  "k8s:io.cilium.k8s.policy.cluster=eu-prod",
  "k8s:io.cilium.k8s.policy.serviceaccount=payments",
  "k8s:io.kubernetes.pod.namespace=payments"
]
```

### 6.2 Identity number ranges

| Range | Class | Scope | Examples |
|---|---|---|---|
| `1`–`255` | **Reserved** | Fixed, cluster-independent | `host=1`, `world=2`, `health=4`, `init=5`, `remote-node=6`, `kube-apiserver=7`, `ingress=8` |
| `256`–`65535` | **Cluster-scoped** | Cluster-global; allocated by `CiliumIdentity` CRD or kvstore | Every label-derived workload identity |
| `≥ 2^24` (16777216) | **Node-local** | Only meaningful on the node that allocated it | CIDR identities from `toCIDR`, FQDN-derived IPs, `reserved:ingress` per-node instances |
| `(clusterID << 16) \| localID` | **ClusterMesh** | Per-cluster shard | Cluster 3, local 4711 → `196_x` range |

The ClusterMesh shift is why the default `max-connected-clusters` is **255** (8 bits of cluster ID, 16 bits of local ID). Raising it to 511 re-partitions the bit layout and is a **cluster-wide, disruptive, one-way** setting — it must be chosen at install time for every cluster in the mesh.

### 6.3 The ipcache: where identity meets the wire

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf ipcache list | head -14
IP PREFIX/ADDRESS       IDENTITY
0.0.0.0/0               identity=2 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.11/32            identity=1 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.12/32            identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.0.1.13/32            identity=6 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.14/32          identity=52901 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.1.87/32          identity=46212 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
10.244.2.0/24           identity=2 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.2.31/32          identity=52901 encryptkey=0 tunnelendpoint=10.0.1.12 flags=<none>
10.244.3.0/24           identity=2 encryptkey=0 tunnelendpoint=10.0.1.13 flags=<none>
34.117.59.81/32         identity=16777224 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
172.20.0.0/16           identity=16777221 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
192.168.10.20/32        identity=7 encryptkey=0 tunnelendpoint=0.0.0.0 flags=<none>
```

Two things to extract:

1. **`tunnelendpoint`** is non-zero only for remote pod prefixes in tunnel mode — that column *is* the overlay routing table.
2. `34.117.59.81/32 → 16777224` is a **FQDN-derived, node-local** identity: the DNS proxy saw a `toFQDNs` match, resolved it, and minted a local identity so the datapath can enforce on it.

---

## 7. Datapath modes and their trade-offs

### 7.1 Routing mode

| Dimension | **Tunnel (VXLAN / Geneve)** | **Native routing** |
|---|---|---|
| Underlay requirement | None — any L3 reachability between nodes | Underlay **must** route the pod CIDR (BGP, cloud VPC routes, or same-L2 with `auto-direct-node-routes`) |
| MTU cost | ~50 bytes overhead → 1450 on a 1500 underlay | Zero |
| Throughput | Lower (encap/decap, often no NIC offload for Geneve) | Highest |
| Identity propagation | Carried **in the tunnel header** (VXLAN VNI / Geneve TLV) — free | Requires ipcache lookup on the receiving node, or IPsec/WireGuard metadata |
| Cloud LB integration | Pod IPs invisible to cloud LB | Pod IPs directly addressable (AWS ENI, Azure) |
| Debuggability | `cilium_vxlan` device is a clean capture point | Packets look like ordinary routed traffic |
| Node scale-out | Trivial | Route table / BGP session scaling |
| Typical use | On-prem, mixed subnets, multi-AZ with L3 boundaries | Cloud with ENI/VPC-native IPAM, single-L2 racks, BGP fabrics |

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf tunnel list
TUNNEL          VALUE
10.244.2.0:0    10.0.1.12:0
10.244.3.0:0    10.0.1.13:0
10.244.4.0:0    10.0.1.14:0
```

### 7.2 kube-proxy replacement — Service handling comparison

| | **kube-proxy iptables** | **kube-proxy IPVS** | **Cilium eBPF** |
|---|---|---|---|
| Lookup complexity | O(n) chain walk | O(1) hash | **O(1) hash** |
| Update cost | Full table reload | Per-service ipvsadm ops | **Single map entry write** |
| East-west ClusterIP | DNAT on packet path | DNAT on packet path | **Socket-level (`connect()`), no packet DNAT** |
| Conntrack for ClusterIP | Required | Required | **Not required** (socket LB) |
| NodePort DSR | No | No | **Yes** (`bpf-lb-mode: dsr`) |
| XDP acceleration | No | No | **Yes** (`loadBalancer.acceleration: native`) |
| Consistent hashing | No | Limited | **Maglev** |
| Source IP preservation | `externalTrafficPolicy: Local` only | Same | DSR or `Local`, plus Hybrid mode |
| Graceful backend termination | Weak | Weak | **Yes** (terminating backends drain) |
| Observability | Counters only | Counters only | Per-flow via Hubble |

Replacement can be **`true`** (full) or **`false`** (co-exist with kube-proxy, eBPF handles only what's explicitly enabled). Partial enablement is expressed through the individual flags (`enable-node-port`, `enable-external-ips`, `enable-host-port`, `enable-socket-lb`).

### 7.3 SNAT vs DSR vs Hybrid for NodePort

| Mode | Return path | Source IP seen by backend | MTU impact | Constraint |
|---|---|---|---|---|
| **SNAT** | Via the ingress node (hairpin) | Node IP (unless `externalTrafficPolicy: Local`) | None | Extra hop, extra NAT state |
| **DSR** | Backend node replies **directly** to client | Real client IP | Option/IPIP header adds bytes | Underlay must accept asymmetric routing; no strict RPF |
| **Hybrid** | DSR for TCP, SNAT for UDP | Mixed | Mixed | Best default when UDP breaks DSR |

### 7.4 Masquerading

| Mode | Implementation | Requirement | Notes |
|---|---|---|---|
| **eBPF masquerading** (`bpf.masquerade: true`) | `bpf_host.o` + `cilium_snat_v4_external` | Kernel ≥ 4.19, `kube-proxy` replacement, devices detected | Faster, no iptables; `cilium-dbg bpf nat list` |
| **iptables masquerading** | `POSTROUTING` rules in the `CILIUM_POST_nat` chain | Any | Default fallback; visible in `iptables-save` |
| **Disabled** | — | Underlay routes pod CIDR | Required for correct source IP to on-prem services |

### 7.5 Encryption

| | **WireGuard** | **IPsec (ESP)** |
|---|---|---|
| Config surface | `encryption.type: wireguard`, keys auto-generated per node | Pre-shared keys in a Secret, manual rotation |
| Kernel requirement | ≥ 5.6 (or wireguard module) | XFRM stack |
| MTU overhead | ~60 bytes | ~50–60 bytes (cipher-dependent) |
| FIPS | Not FIPS-validated | FIPS-capable ciphers available |
| Node-to-node vs pod-to-pod | Node-to-node tunnels carrying pod traffic | Per-node SAs; identity carried in the SPI/mark |
| Operational simplicity | **High** — key rotation automatic on node restart | Low — key rotation is a documented multi-step procedure |
| Inspect | `cilium-dbg encrypt status` | `cilium-dbg encrypt status` |

---

## 8. `cilium-envoy` and the L7 datapath

Since Cilium 1.16 Envoy runs as its **own DaemonSet** (`cilium-envoy`) rather than embedded in the agent process. The separation matters operationally: an Envoy OOM or crash-loop no longer takes the agent — and therefore the L3/L4 datapath — with it, and Envoy can be upgraded on a different cadence.

**Wiring:**

* Agent → Envoy configuration via **xDS over a unix socket**: `/var/run/cilium/envoy/sockets/xds.sock`.
* Envoy → agent for policy verdicts and access logs: `/var/run/cilium/envoy/sockets/access_log.sock`.
* Admin interface: `/var/run/cilium/envoy/sockets/admin.sock` (a unix socket, deliberately not a TCP port).
* Bootstrap config from ConfigMap `cilium-envoy-config`, mounted at `/var/run/cilium/envoy/bootstrap-config.json`.
* Prometheus metrics: **:9964**.

**Redirect mechanics:** when a policy contains an L7 rule (`toPorts[].rules.http`), the per-endpoint policy map entry for that `(identity, port)` carries a **proxy port**. `bpf_lxc.o` sets an skb mark and uses tproxy to steer the packet to the local Envoy listener. Envoy receives the connection *with the original 5-tuple preserved* (via the `cilium.bpf_metadata` listener filter, which recovers the source identity from the ipcache), applies the L7 rules with the `cilium.l7policy` filter, and forwards.

**Key exam point:** an L7 rule makes the whole `toPorts` entry L7-enforced. Traffic that does not parse as the declared protocol is dropped, and the flow appears in Hubble with `L7` verdict information rather than only `Forwarded`/`Dropped`.

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg policy get --all | head -40
[
  {
    "endpointSelector": {
      "matchLabels": { "k8s:app": "payments-api", "k8s:io.kubernetes.pod.namespace": "payments" }
    },
    "ingress": [
      {
        "fromEndpoints": [
          { "matchLabels": { "k8s:app": "frontend", "k8s:io.kubernetes.pod.namespace": "shop" } }
        ],
        "toPorts": [
          {
            "ports": [ { "port": "8080", "protocol": "TCP" } ],
            "rules": {
              "http": [ { "method": "GET", "path": "/api/v1/charges(/.*)?$" } ]
            }
          }
        ]
      }
    ],
    "labels": [
      { "key": "io.cilium.k8s.policy.derived-from", "value": "CiliumNetworkPolicy", "source": "k8s" },
      { "key": "io.cilium.k8s.policy.name", "value": "payments-l7", "source": "k8s" },
      { "key": "io.cilium.k8s.policy.namespace", "value": "payments", "source": "k8s" }
    ]
  }
]
Revision: 47
```

---

## 9. Hubble

Hubble is **three layers**, and confusing them is the classic troubleshooting mistake:

| Layer | Where | Port | Scope | Fails independently? |
|---|---|---|---|---|
| **Hubble (embedded)** | inside `cilium-agent` | gRPC **4244** (`hubble.listenAddress`) | One node | Yes — `hubble.enabled=false` leaves the datapath intact |
| **Hubble Relay** | Deployment | gRPC **4245** | Whole cluster (fan-out to every agent's peer service) | Yes |
| **Hubble UI** | Deployment | HTTP **8081** (svc), backend + frontend containers | Whole cluster | Yes |

**Data path of a flow:** eBPF program → `cilium_events` perf ring buffer → agent monitor → Hubble observer → in-memory **ring buffer** (default `hubble.eventBufferCapacity: 4095` events per node) → gRPC stream / metrics exporter / flow log file.

That in-memory ring buffer is the thing to internalise: **Hubble is not a database.** Flows are lost on agent restart and evicted continuously. For retention you export — `hubble.export.static` to a file for a log shipper, or `hubble.metrics` to Prometheus, or Hubble Timescape (Isovalent Enterprise).

Metrics are opt-in per context, and **cardinality is a production hazard**:

```yaml
hubble:
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop:sourceContext=pod;destinationContext=pod
      - tcp
      - flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - port-distribution
      - icmp
      - httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction
```

Adding `sourceContext=pod` on `flow` in a cluster with thousands of short-lived pods produces unbounded label cardinality. Prefer `workload-name` over `pod`.

```
$ hubble observe --namespace payments --verdict DROPPED --last 5
Sep  1 09:14:02.113: shop/frontend-7d9c8b5f6-2xqzk:41022 (ID:52901) -> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 09:14:02.113: shop/frontend-7d9c8b5f6-2xqzk:41022 (ID:52901) <> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) Policy denied DROPPED (TCP Flags: SYN)
Sep  1 09:14:03.221: shop/frontend-7d9c8b5f6-2xqzk:41024 (ID:52901) -> payments/payments-api-5f7b9d4c8-jk2mn:8080 (ID:46212) policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
Sep  1 09:14:05.998: kube-system/coredns-7db6d8ff4d-4gk7z:53 (ID:23409) <> shop/cart-6b7f8c9d5-plm4x:38821 (ID:19022) Policy denied DROPPED (UDP)
Sep  1 09:14:06.004: shop/cart-6b7f8c9d5-plm4x:38821 (ID:19022) -> kube-system/coredns-7db6d8ff4d-4gk7z:53 (ID:23409) policy-verdict:none EGRESS DENIED (UDP)
```

```
$ hubble observe --http-status 5xx --protocol http --last 3 -o json | jq -c '{t:.time, src:.source.pod_name, dst:.destination.pod_name, http:.l7.http}'
{"t":"2026-09-01T09:15:11.442Z","src":"frontend-7d9c8b5f6-2xqzk","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":503,"method":"POST","url":"http://payments-api:8080/api/v1/charges","protocol":"HTTP/1.1"}}
{"t":"2026-09-01T09:15:11.889Z","src":"frontend-7d9c8b5f6-2xqzk","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":503,"method":"POST","url":"http://payments-api:8080/api/v1/charges","protocol":"HTTP/1.1"}}
{"t":"2026-09-01T09:15:12.331Z","src":"checkout-58d9f7b4c-9rt2v","dst":"payments-api-5f7b9d4c8-jk2mn","http":{"code":500,"method":"GET","url":"http://payments-api:8080/healthz","protocol":"HTTP/1.1"}}
```

---

## 10. ClusterMesh

`clustermesh-apiserver` is a Deployment containing **two containers**: an embedded `etcd` and a `clustermesh-apiserver` process that mirrors the local cluster's identities, endpoints, nodes and global services into that etcd. Remote clusters' agents connect to it as **read-only etcd clients over mTLS**.

Requirements that the exam tests:

1. **Unique `cluster-name` and `cluster-id`** (1–255 by default) per cluster. A duplicate `cluster-id` corrupts identity allocation across the mesh.
2. **Non-overlapping Pod CIDRs** across all clusters.
3. **Node-to-node reachability** between clusters for the pod network (or tunnels/encryption between them).
4. The `clustermesh-apiserver` must be **reachable from remote clusters** — LoadBalancer, NodePort, or a shared network path — on **2379/TCP**.
5. Mesh CA: all clusters must trust a **common CA** for the mTLS between agents and remote apiservers.

Global services are opt-in per Service via annotations:

```yaml
metadata:
  annotations:
    service.cilium.io/global: "true"                 # backends from all clusters
    service.cilium.io/shared: "true"                 # export this cluster's backends to the mesh
    service.cilium.io/affinity: "local"              # prefer local backends; fail over remote
    service.cilium.io/global-sync-endpoint-slices: "true"
```

```
$ cilium clustermesh status --context eu-prod
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 10.0.9.44:2379
✅ Deployment clustermesh-apiserver is ready
ℹ️  KVStoreMesh is enabled

✅ All 6 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]

🔌 Cluster Connections:
  - us-prod: 6/6 configured, 6/6 connected

🔀 Global services: [ min:4 / avg:4.0 / max:4 ]
```

**KVStoreMesh** (an operating mode of `clustermesh-apiserver`) adds a caching layer: instead of every agent in cluster A watching cluster B's apiserver directly, the local `clustermesh-apiserver` caches remote state and agents watch locally. This turns an N×M connection matrix into N+M and is the recommended mode at scale.

---

## 11. Complete infrastructure manifests

### 11.1 Production Helm values (`values-prod.yaml`) — complete

```yaml
# Cilium production values — native routing + full kube-proxy replacement,
# WireGuard node-to-node encryption, Hubble with Prometheus export.
# Install:
#   helm repo add cilium https://helm.cilium.io/
#   helm upgrade --install cilium cilium/cilium --version 1.16.5 \
#     --namespace kube-system -f values-prod.yaml

k8sServiceHost: api.eu-prod.internal
k8sServicePort: 6443

cluster:
  name: eu-prod
  id: 1

# ---------- Datapath ----------
routingMode: native
autoDirectNodeRoutes: true
ipv4NativeRoutingCIDR: 10.244.0.0/16
enableIPv4Masquerade: true
enableIPv6Masquerade: false
bpf:
  masquerade: true
  hostLegacyRouting: false
  preallocateMaps: true
  lbMapMax: 131072
  policyMapMax: 32768
  mapDynamicSizeRatio: 0.0025
  monitorAggregation: medium
  monitorInterval: 5s
  monitorFlags: all
  tproxy: true

ipv4:
  enabled: true
ipv6:
  enabled: false

# ---------- IPAM ----------
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
    clusterPoolIPv4MaskSize: 24

# ---------- kube-proxy replacement ----------
kubeProxyReplacement: "true"
k8sServiceLookupOrder: ""
socketLB:
  enabled: true
  hostNamespaceOnly: false
loadBalancer:
  algorithm: maglev
  mode: hybrid
  acceleration: native
  serviceTopology: true
maglev:
  tableSize: 16381
  hashSeed: "JLfvgnHc2kaSUFaI"
nodePort:
  enabled: true
  range: "30000,32767"
externalIPs:
  enabled: true
hostPort:
  enabled: true
devices: "eth+ bond+"

# ---------- Encryption ----------
encryption:
  enabled: true
  type: wireguard
  nodeEncryption: true
  wireguard:
    persistentKeepalive: 0s

# ---------- Policy ----------
policyEnforcementMode: default
policyAuditMode: false
hostFirewall:
  enabled: true
enableCiliumEndpointSlice: true
identityAllocationMode: crd
identityChangeGracePeriod: 5s
labels: "k8s:app k8s:name k8s:component k8s:tier k8s:io.kubernetes.pod.namespace k8s:io.cilium.k8s.policy.* k8s:io.cilium.k8s.namespace.labels.*"

dnsProxy:
  enableTransparentMode: true
  minTtl: 3600
  maxDeferredConnectionDeletes: 10000
  endpointMaxIpPerHostname: 100

# ---------- L7 / Envoy ----------
envoy:
  enabled: true
  prometheus:
    enabled: true
    port: "9964"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
ingressController:
  enabled: true
  loadbalancerMode: shared
  default: false
  enforceHttps: true
gatewayAPI:
  enabled: false

# ---------- Observability ----------
hubble:
  enabled: true
  eventBufferCapacity: 16383
  eventQueueSize: 0
  metrics:
    enabled:
      - dns:query;ignoreAAAA
      - drop:sourceContext=workload-name;destinationContext=workload-name
      - tcp
      - flow:sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
      - port-distribution
      - icmp
      - httpV2:exemplars=true;labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction
    serviceMonitor:
      enabled: true
    dashboards:
      enabled: true
      namespace: monitoring
  relay:
    enabled: true
    replicas: 2
    rollOutPods: true
    prometheus:
      enabled: true
      port: 9966
      serviceMonitor:
        enabled: true
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 512Mi
  ui:
    enabled: true
    replicas: 1
  tls:
    auto:
      enabled: true
      method: helm
      certValidityDuration: 1095

# ---------- Prometheus ----------
prometheus:
  enabled: true
  port: 9962
  serviceMonitor:
    enabled: true
    trustCRDsExist: true
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
      memory: 1Gi
  podDisruptionBudget:
    enabled: true
    maxUnavailable: 1

# ---------- Agent runtime ----------
rollOutCiliumPods: true
priorityClassName: system-node-critical
resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    memory: 4Gi
cni:
  exclusive: true
  logFile: /var/run/cilium/cilium-cni.log
  install: true
  chainingMode: none

# ---------- ClusterMesh ----------
clustermesh:
  useAPIServer: true
  apiserver:
    kvstoremesh:
      enabled: true
    replicas: 2
    service:
      type: LoadBalancer
    tls:
      auto:
        enabled: true
        method: certmanager
        certManagerIssuerRef:
          group: cert-manager.io
          kind: ClusterIssuer
          name: mesh-ca

# ---------- Upgrade safety ----------
upgradeCompatibility: "1.16"
```

### 11.2 The `cilium-config` ConfigMap this renders (excerpt of the real object)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  agent-not-ready-taint-key: node.cilium.io/agent-not-ready
  arping-refresh-period: 30s
  auto-direct-node-routes: "true"
  bpf-lb-algorithm: maglev
  bpf-lb-external-clusterip: "false"
  bpf-lb-map-max: "131072"
  bpf-lb-maglev-table-size: "16381"
  bpf-lb-mode: hybrid
  bpf-map-dynamic-size-ratio: "0.0025"
  bpf-policy-map-max: "32768"
  bpf-root: /sys/fs/bpf
  cgroup-root: /run/cilium/cgroupv2
  cluster-id: "1"
  cluster-name: eu-prod
  cni-exclusive: "true"
  cni-log-file: /var/run/cilium/cilium-cni.log
  custom-cni-conf: "false"
  debug: "false"
  enable-auto-protect-node-port-range: "true"
  enable-bpf-clock-probe: "false"
  enable-bpf-masquerade: "true"
  enable-cilium-endpoint-slice: "true"
  enable-endpoint-health-checking: "true"
  enable-endpoint-routes: "false"
  enable-health-check-nodeport: "true"
  enable-health-checking: "true"
  enable-host-firewall: "true"
  enable-hubble: "true"
  enable-ipv4: "true"
  enable-ipv4-masquerade: "true"
  enable-ipv6: "false"
  enable-k8s-networkpolicy: "true"
  enable-l2-neigh-discovery: "true"
  enable-l7-proxy: "true"
  enable-local-redirect-policy: "false"
  enable-metrics: "true"
  enable-node-port: "true"
  enable-policy: default
  enable-remote-node-identity: "true"
  enable-sctp: "false"
  enable-svc-source-range-check: "true"
  enable-wireguard: "true"
  enable-xt-socket-fallback: "true"
  encrypt-node: "true"
  hubble-disable-tls: "false"
  hubble-event-buffer-capacity: "16383"
  hubble-listen-address: ":4244"
  hubble-metrics-server: ":9965"
  hubble-socket-path: /var/run/cilium/hubble.sock
  identity-allocation-mode: crd
  identity-gc-interval: 15m0s
  identity-heartbeat-timeout: 30m0s
  install-no-conntrack-iptables-rules: "false"
  ipam: cluster-pool
  ipv4-native-routing-cidr: 10.244.0.0/16
  kube-proxy-replacement: "true"
  monitor-aggregation: medium
  monitor-aggregation-flags: all
  monitor-aggregation-interval: 5s
  node-port-bind-protection: "true"
  nodes-gc-interval: 5m0s
  operator-api-serve-addr: 127.0.0.1:9234
  operator-prometheus-serve-addr: :9963
  preallocate-bpf-maps: "true"
  procfs: /host/proc
  prometheus-serve-addr: :9962
  proxy-connect-timeout: "2"
  remove-cilium-node-taints: "true"
  routing-mode: native
  set-cilium-is-up-condition: "true"
  set-cilium-node-taints: "true"
  sync-k8s-nodes: "true"
  sync-k8s-services: "true"
  tofqdns-dns-reject-response-code: refused
  tofqdns-enable-dns-compression: "true"
  tofqdns-endpoint-max-ip-per-hostname: "100"
  tofqdns-idle-connection-grace-period: 0s
  tofqdns-max-deferred-connection-deletes: "10000"
  tofqdns-proxy-response-max-delay: 100ms
  tunnel-protocol: vxlan
  write-cni-conf-when-ready: /host/etc/cni/net.d/05-cilium.conflist
```

### 11.3 The `cilium` DaemonSet — the parts that explain the architecture

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cilium
  namespace: kube-system
  labels:
    k8s-app: cilium
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 2
  template:
    metadata:
      labels:
        k8s-app: cilium
      annotations:
        container.apparmor.security.beta.kubernetes.io/cilium-agent: unconfined
        container.apparmor.security.beta.kubernetes.io/clean-cilium-state: unconfined
    spec:
      # hostNetwork is mandatory: the agent programs the host's devices and
      # must reach the apiserver before pod networking exists.
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      restartPolicy: Always
      priorityClassName: system-node-critical
      serviceAccountName: cilium
      terminationGracePeriodSeconds: 1
      # Tolerate everything: the CNI must start on a NotReady node.
      tolerations:
        - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  k8s-app: cilium
              topologyKey: kubernetes.io/hostname

      initContainers:
        # 1. Mount cgroup v2 for the socket-LB (cgroup connect) hooks.
        - name: mount-cgroup
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - sh
            - -ec
            - |
              cp /usr/bin/cilium-mount /hostbin/cilium-mount;
              nsenter --cgroup=/hostproc/1/ns/cgroup --mount=/hostproc/1/ns/mnt \
                "${BIN_PATH}/cilium-mount" $CGROUP_ROOT;
              rm /hostbin/cilium-mount
          env:
            - name: CGROUP_ROOT
              value: /run/cilium/cgroupv2
            - name: BIN_PATH
              value: /opt/cni/bin
          securityContext:
            privileged: true
          volumeMounts:
            - name: hostproc
              mountPath: /hostproc
            - name: cni-path
              mountPath: /hostbin

        # 2. Sysctl overrides required by the datapath (rp_filter, forwarding).
        - name: apply-sysctl-overwrites
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - sh
            - -ec
            - |
              cp /usr/bin/cilium-sysctlfix /hostbin/cilium-sysctlfix;
              nsenter --mount=/hostproc/1/ns/mnt "${BIN_PATH}/cilium-sysctlfix";
              rm /hostbin/cilium-sysctlfix
          env:
            - name: BIN_PATH
              value: /opt/cni/bin
          securityContext:
            privileged: true
          volumeMounts:
            - name: hostproc
              mountPath: /hostproc
            - name: cni-path
              mountPath: /hostbin

        # 3. Mount bpffs inside the agent's mount namespace.
        - name: mount-bpf-fs
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /bin/bash
            - -c
            - --
          args:
            - 'mount | grep "/sys/fs/bpf type bpf" || mount -t bpf bpf /sys/fs/bpf'
          securityContext:
            privileged: true
          volumeMounts:
            - name: bpf-maps
              mountPath: /sys/fs/bpf
              mountPropagation: Bidirectional

        # 4. Optional teardown of previous datapath state on restart.
        - name: clean-cilium-state
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /init-container.sh
          env:
            - name: CILIUM_ALL_STATE
              valueFrom:
                configMapKeyRef:
                  name: cilium-config
                  key: clean-cilium-state
                  optional: true
            - name: CILIUM_BPF_STATE
              valueFrom:
                configMapKeyRef:
                  name: cilium-config
                  key: clean-cilium-bpf-state
                  optional: true
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              add:
                - NET_ADMIN
                - SYS_MODULE
                - SYS_ADMIN
                - SYS_RESOURCE
              drop:
                - ALL
          volumeMounts:
            - name: bpf-maps
              mountPath: /sys/fs/bpf
            - name: cilium-cgroup
              mountPath: /run/cilium/cgroupv2
              mountPropagation: HostToContainer
            - name: cilium-run
              mountPath: /var/run/cilium

        # 5. Place the CNI binaries on the host.
        - name: install-cni-binaries
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - /install-plugin.sh
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: cni-path
              mountPath: /host/opt/cni/bin

      containers:
        - name: cilium-agent
          image: quay.io/cilium/cilium:v1.16.5
          command:
            - cilium-agent
          args:
            - --config-dir=/tmp/cilium/config-map
          env:
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: spec.nodeName
            - name: CILIUM_K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  apiVersion: v1
                  fieldPath: metadata.namespace
            - name: KUBERNETES_SERVICE_HOST
              value: api.eu-prod.internal
            - name: KUBERNETES_SERVICE_PORT
              value: "6443"
          ports:
            - name: peer-service
              containerPort: 4244
              hostPort: 4244
              protocol: TCP
            - name: prometheus
              containerPort: 9962
              hostPort: 9962
              protocol: TCP
            - name: hubble-metrics
              containerPort: 9965
              hostPort: 9965
              protocol: TCP
          startupProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            failureThreshold: 105
            periodSeconds: 2
            successThreshold: 1
          livenessProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            periodSeconds: 30
            successThreshold: 1
            failureThreshold: 10
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              host: 127.0.0.1
              path: /healthz
              port: 9879
              scheme: HTTP
              httpHeaders:
                - name: brief
                  value: "true"
            periodSeconds: 30
            successThreshold: 1
            failureThreshold: 3
            timeoutSeconds: 5
          lifecycle:
            preStop:
              exec:
                command:
                  - /cni-uninstall.sh
          securityContext:
            seLinuxOptions:
              level: s0
              type: spc_t
            capabilities:
              add:
                - CHOWN
                - KILL
                - NET_ADMIN
                - NET_RAW
                - IPC_LOCK
                - SYS_MODULE
                - SYS_ADMIN
                - SYS_RESOURCE
                - DAC_OVERRIDE
                - FOWNER
                - SETGID
                - SETUID
              drop:
                - ALL
          volumeMounts:
            - name: cilium-run
              mountPath: /var/run/cilium
            - name: bpf-maps
              mountPath: /sys/fs/bpf
              mountPropagation: HostToContainer
            - name: cilium-cgroup
              mountPath: /run/cilium/cgroupv2
              mountPropagation: HostToContainer
            - name: cni-path
              mountPath: /host/opt/cni/bin
            - name: etc-cni-netd
              mountPath: /host/etc/cni/net.d
            - name: clustermesh-secrets
              mountPath: /var/lib/cilium/clustermesh
              readOnly: true
            - name: lib-modules
              mountPath: /lib/modules
              readOnly: true
            - name: xtables-lock
              mountPath: /run/xtables.lock
            - name: hubble-tls
              mountPath: /var/lib/cilium/tls/hubble
              readOnly: true
            - name: tmp
              mountPath: /tmp
            - name: envoy-sockets
              mountPath: /var/run/cilium/envoy/sockets

      volumes:
        - name: tmp
          emptyDir: {}
        # Host-backed: state must survive an agent restart.
        - name: cilium-run
          hostPath:
            path: /var/run/cilium
            type: DirectoryOrCreate
        - name: bpf-maps
          hostPath:
            path: /sys/fs/bpf
            type: DirectoryOrCreate
        - name: hostproc
          hostPath:
            path: /proc
            type: Directory
        - name: cilium-cgroup
          hostPath:
            path: /run/cilium/cgroupv2
            type: DirectoryOrCreate
        - name: cni-path
          hostPath:
            path: /opt/cni/bin
            type: DirectoryOrCreate
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d
            type: DirectoryOrCreate
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
        - name: envoy-sockets
          hostPath:
            path: /var/run/cilium/envoy/sockets
            type: DirectoryOrCreate
        - name: clustermesh-secrets
          projected:
            defaultMode: 256
            sources:
              - secret:
                  name: cilium-clustermesh
                  optional: true
              - secret:
                  name: clustermesh-apiserver-remote-cert
                  optional: true
                  items:
                    - key: tls.key
                      path: common-etcd-client.key
                    - key: tls.crt
                      path: common-etcd-client.crt
                    - key: ca.crt
                      path: common-etcd-client-ca.crt
        - name: hubble-tls
          projected:
            defaultMode: 256
            sources:
              - secret:
                  name: hubble-server-certs
                  optional: true
                  items:
                    - key: tls.crt
                      path: server.crt
                    - key: tls.key
                      path: server.key
                    - key: ca.crt
                      path: client-ca.crt
```

**What to notice, because it is architecture and not boilerplate:**

* `hostNetwork: true` + `tolerations: [{operator: Exists}]` — the CNI must run before the node is Ready and before pod networking exists.
* `bpf-maps` mounted from `/sys/fs/bpf` with `mountPropagation` — map lifetime is decoupled from container lifetime. **Restarting the agent does not drop existing traffic.**
* `cilium-cgroup` at `/run/cilium/cgroupv2` — required for socket LB.
* `preStop: /cni-uninstall.sh` — removes the CNI conf so the kubelet does not try to schedule pods on a node with no working CNI.
* The `startupProbe` has `failureThreshold: 105, periodSeconds: 2` ≈ **3.5 minutes** of grace: initial datapath compilation on a cold node is slow, and a tighter probe causes crash-loops.
* `agent-not-ready-taint-key: node.cilium.io/agent-not-ready` — the node is tainted until the agent is ready, preventing pods from being scheduled onto a node with no datapath.

### 11.4 CNI configuration installed on the host

```json
{
  "cniVersion": "1.0.0",
  "name": "cilium",
  "plugins": [
    {
      "type": "cilium-cni",
      "log-file": "/var/run/cilium/cilium-cni.log",
      "enable-debug": false,
      "ipam": {
        "type": "cilium-cni"
      }
    }
  ]
}
```

### 11.5 Verification workload + policy — complete and applyable

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: arch-lab
  labels:
    env: lab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: arch-lab
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: data
    spec:
      containers:
        - name: echo
          image: gcr.io/k8s-staging-gateway-api/echo-basic:v20231214-v1.0.0-140-gf544a46e
          ports:
            - name: http
              containerPort: 3000
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: arch-lab
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - name: http
      port: 8080
      targetPort: 3000
      protocol: TCP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client
  namespace: arch-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: client
  template:
    metadata:
      labels:
        app: client
        tier: front
    spec:
      containers:
        - name: curl
          image: curlimages/curl:8.11.0
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-l7
  namespace: arch-lab
spec:
  description: "Only app=client may GET /healthz and /api/* on backend:3000"
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      toPorts:
        - ports:
            - port: "3000"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/healthz"
              - method: GET
                path: "/api/.*"
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
---
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-health-and-dns-everywhere
spec:
  description: "Baseline: never break cilium-health or cluster DNS"
  endpointSelector: {}
  ingress:
    - fromEntities:
        - health
        - remote-node
  egress:
    - toEntities:
        - health
        - remote-node
        - kube-apiserver
```

### 11.6 Per-node override with `CiliumNodeConfig`

```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  name: debug-on-canary-nodes
  namespace: kube-system
spec:
  nodeSelector:
    matchLabels:
      cilium.io/profile: canary
  defaults:
    debug: "true"
    debug-verbose: "flow datapath"
    monitor-aggregation: "none"
```

### 11.7 Reproducible lab cluster (kind) with Cilium as the only CNI

```yaml
# kind-cilium.yaml
#   kind create cluster --config kind-cilium.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cca-lab
nodes:
  - role: control-plane
  - role: worker
  - role: worker
networking:
  disableDefaultCNI: true   # no kindnet
  kubeProxyMode: none       # full eBPF kube-proxy replacement
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
```

```
$ kind create cluster --config kind-cilium.yaml
$ docker exec cca-lab-control-plane mount | grep bpf
none on /sys/fs/bpf type bpf (rw,nosuid,nodev,noexec,relatime,mode=700)

$ helm repo add cilium https://helm.cilium.io/ && helm repo update
$ helm install cilium cilium/cilium --version 1.16.5 \
    --namespace kube-system \
    --set image.pullPolicy=IfNotPresent \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=cca-lab-control-plane \
    --set k8sServicePort=6443 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
NAME: cilium
LAST DEPLOYED: Tue Sep  1 09:02:41 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1

$ cilium status --wait
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled

DaemonSet         cilium            Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet         cilium-envoy      Desired: 3, Ready: 3/3, Available: 3/3
Deployment        cilium-operator   Desired: 1, Ready: 1/1, Available: 1/1
Deployment        hubble-relay      Desired: 1, Ready: 1/1, Available: 1/1
Deployment        hubble-ui         Desired: 1, Ready: 1/1, Available: 1/1
Cluster Pods:     12/12 managed by Cilium
```

---

## 12. Verification and diagnostics

### 12.1 The diagnostic ladder — cheapest first

| Rung | Command | Answers |
|---|---|---|
| 0 | `cilium status --wait` | Are all components scheduled, ready and version-consistent? |
| 1 | `cilium-dbg status --verbose` | On **this node**: kube-proxy replacement, IPAM, encryption, map pressure, controller failures |
| 2 | `cilium-dbg endpoint list` | Is my pod a managed endpoint? Is policy enforced in that direction? |
| 3 | `cilium-dbg identity list` / `identity get` | Do the labels I think exist actually form the identity? |
| 4 | `cilium-dbg bpf ipcache list` | Does the datapath know this IP's identity and owning node? |
| 5 | `cilium-dbg policy get` / `bpf policy get <ep>` | What is *actually* programmed, vs what the CRD says? |
| 6 | `hubble observe --verdict DROPPED` | Which flows are dropped, with which reason? |
| 7 | `cilium-dbg monitor -t drop --related-to <ep>` | Raw datapath events, no aggregation |
| 8 | `cilium connectivity test` | End-to-end functional proof across ~50 scenarios |
| 9 | `cilium sysdump` | Everything, bundled, for escalation |

### 12.2 `cilium-dbg status --verbose` — annotated real output

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose
KVStore:                Ok   Disabled
Kubernetes:             Ok   1.31 (v1.31.2) [linux/amd64]
Kubernetes APIs:        ["EndpointSliceOrEndpoint", "cilium/v2::CiliumClusterwideNetworkPolicy", "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy", "cilium/v2::CiliumNode", "core/v1::Namespace", "core/v1::Pods", "core/v1::Service", "networking.k8s.io/v1::NetworkPolicy"]
KubeProxyReplacement:   True   [eth0   10.0.1.11 (Direct Routing)]
Host firewall:          Enabled   [eth0]
SRv6:                   Disabled
CNI Chaining:           none
CNI Config file:        successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                 Ok   1.16.5 (v1.16.5-a1b2c3d4)
NodeMonitor:            Listening for events on 8 CPUs with 64x4096 of shared memory
Cilium health daemon:   Ok
IPAM:                   IPv4: 27/254 allocated from 10.244.1.0/24,
Allocated addresses:
  10.244.1.1 (router)
  10.244.1.14 (shop/frontend-7d9c8b5f6-2xqzk)
  10.244.1.87 (payments/payments-api-5f7b9d4c8-jk2mn)
  10.244.1.201 (health)
IPv4 BIG TCP:           Disabled
IPv6 BIG TCP:           Disabled
BandwidthManager:       EDT with BPF [CUBIC] [eth0]
Host Routing:           BPF
Masquerading:           BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]
Clock Source for BPF:   ktime
Controller Status:      142/142 healthy
Proxy Status:           OK, ip 10.244.1.1, 2 redirects active on ports 10000-20000, Envoy: external
Global Identity Range:  min 256, max 65535
Hubble:                 Ok   Current/Max Flows: 16383/16383 (100.00%), Flows/s: 412.77   Metrics: Ok
Encryption:             Wireguard   [NodeEncryption: Enabled, cilium_wg0 (Pubkey: t6X...=, Port: 51871, Peers: 5)]
Cluster health:         6/6 reachable   (2026-09-01T09:16:02Z)
  Name                  IP              Node        Endpoints
  eu-prod/node-01       10.0.1.11       reachable   reachable
  eu-prod/node-02       10.0.1.12       reachable   reachable
  eu-prod/node-03       10.0.1.13       reachable   reachable
  eu-prod/node-04       10.0.1.14       reachable   reachable
  eu-prod/node-05       10.0.1.15       reachable   reachable
  eu-prod/node-06       10.0.1.16       reachable   reachable
Modules Health:
  agent
  ├── controlplane                                                     
  │   ├── auth                             [OK] Primed (2m, x1)
  │   ├── cilium-endpoint-slice-controller [OK] Synchronized (5m, x3)
  │   ├── daemon                           [OK] daemon-validate-config (12m, x1)
  │   └── endpoint-manager                 [OK] cilium-endpoint-27 (3s, x841)
  └── datapath                                                          
      ├── agent-liveness-updater           [OK] Running (12m, x1)
      ├── l2-responder                     [OK] Primed (12m, x1)
      └── node-address                     [OK] 3 addresses (12m, x1)
```

**Read these lines specifically:**

* `Controller Status: 142/142 healthy` — any `x/y` where `x < y` means a background controller is failing; run `cilium-dbg status --all-controllers`.
* `Hubble: Current/Max Flows: 16383/16383 (100.00%)` — the ring is **full**, which is normal steady state, not an error. It means old flows are being evicted.
* `Host Routing: BPF` vs `Legacy` — `Legacy` means traffic traverses the host iptables/routing stack; a silent performance regression usually caused by an unsupported kernel.
* `Proxy Status: ... Envoy: external` — Envoy is the separate DaemonSet, not embedded.
* `Cluster health: 6/6 reachable` with two columns: **Node** (node IP path) and **Endpoints** (pod network path). `reachable / unreachable` means the underlay is fine but the pod overlay is broken — that pair localises a fault instantly.

### 12.3 Verifying Service programming end-to-end

```
$ kubectl -n arch-lab get svc backend -o jsonpath='{.spec.clusterIP}{"\n"}'
10.96.184.22

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -A4 10.96.184.22
ID   Frontend               Service Type   Backend
17   10.96.184.22:8080/TCP  ClusterIP      1 => 10.244.1.31:3000/TCP (active)
                                           2 => 10.244.2.44:3000/TCP (active)
                                           3 => 10.244.3.19:3000/TCP (active)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list | grep -A4 10.96.184.22
SERVICE ADDRESS        BACKEND ADDRESS (REVNAT_ID) (SLOT)
10.96.184.22:8080/TCP  0.0.0.0:0 (17) (0) [ClusterIP, non-routable]
                       10.244.1.31:3000/TCP (17) (1)
                       10.244.2.44:3000/TCP (17) (2)
                       10.244.3.19:3000/TCP (17) (3)
```

Slot `0` holds the frontend metadata (backend count, flags); slots `1..n` are the backends. If `cilium-dbg service list` shows backends but `bpf lb list` does not, **userspace and the datapath have diverged** — a map-full or a failed map update.

Prove socket LB is doing the work — the packet never carries the VIP:

```
$ kubectl -n arch-lab exec deploy/client -- curl -s -o /dev/null -w '%{remote_ip}:%{remote_port}\n' http://backend:8080/healthz
10.244.2.44:3000
```

The client dialled `backend:8080` (→ `10.96.184.22:8080`) and `curl` reports the peer as a **pod IP**, because `connect()` was rewritten at the cgroup hook.

### 12.4 The full connectivity test

```
$ cilium connectivity test --test-namespace cilium-test
ℹ️  Monitor aggregation detected, will skip some flow validation steps
✨ [eu-prod] Creating namespace cilium-test for connectivity check...
✨ [eu-prod] Deploying echo-same-node service...
✨ [eu-prod] Deploying DNS test server configmap...
⌛ [eu-prod] Waiting for deployment cilium-test/client to become ready...
⌛ [eu-prod] Waiting for CiliumEndpoint for pod cilium-test/client-6f6788d7cc-9zx4t to appear...
🏃 Running 82 tests ...
[=] Test [no-policies] .........................
[=] Test [allow-all-except-world] ..............
[=] Test [client-ingress] ......
[=] Test [echo-ingress] ........
[=] Test [client-egress-l7] ....................
[=] Test [dns-only] ............
[=] Test [to-fqdns] ........
[=] Test [pod-to-pod-encryption] ......
[=] Test [health] ..
[=] Test [north-south-loadbalancing] ..........
✅ [eu-prod] 82/82 tests successful (0 warnings)
```

A failure prints the exact command, the flows on both sides, and the expected vs observed verdict — it is the single most useful artefact to attach to a bug report, alongside `cilium sysdump`.

### 12.5 Failure catalogue

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| Pods stuck `ContainerCreating`, `plugin type="cilium-cni" failed` | Agent not ready on that node, or CNI conf absent | `kubectl -n kube-system logs -l k8s-app=cilium -c cilium-agent --tail=50`; `ls /etc/cni/net.d/` | Fix agent startup; check `cni.exclusive` did not remove another CNI's conf you still need |
| `Unable to allocate IP` | Cluster-pool exhausted, or operator down | `cilium-dbg status --verbose \| grep IPAM`; `kubectl -n kube-system get ciliumnode <node> -o yaml` | Enlarge `clusterPoolIPv4PodCIDRList` / fix operator |
| Node stays `NotReady`, taint `node.cilium.io/agent-not-ready` | Agent failing readiness | `kubectl -n kube-system describe pod -l k8s-app=cilium` | See probe failure reason; usually bpffs/cgroup mount or kernel too old |
| Traffic allowed that a policy should deny | `policyAuditMode` on, or the endpoint has no policy in that direction | `cilium-dbg endpoint list` (check `ENFORCEMENT` column); `cilium-dbg config \| grep -i audit` | Disable audit mode; add a policy selecting the endpoint |
| `Policy denied DROPPED` for traffic that should be allowed | Identity mismatch — the labels you selected are filtered out or namespaced differently | `cilium-dbg identity get <id>`; `hubble observe --verdict DROPPED -o json \| jq .source.labels` | Select on labels that actually survive the label filter |
| Only *cross-node* traffic fails | Tunnel/route/MTU/encryption asymmetry | `cilium-dbg bpf tunnel list`; `cilium status` health matrix; `ip route` | Fix underlay routes, MTU, or firewall on 8472/6081/51871 |
| Intermittent drops under load, `Map insertion failed` | eBPF map full (CT, NAT, policy, LB) | `cilium-dbg bpf ct list global \| wc -l`; metric `cilium_bpf_map_pressure` | Raise `bpf-ct-global-*-max`, `bpf-lb-map-max`, `bpf-policy-map-max` (**requires agent restart**) |
| L7 policy never matches; connections hang | `cilium-envoy` down or xDS socket unmounted | `kubectl -n kube-system get ds cilium-envoy`; `cilium-dbg status \| grep Proxy` | Restart `cilium-envoy`; verify `envoy-sockets` hostPath volume |
| `hubble observe` empty but `cilium-dbg monitor` works | Relay can't reach peers, or TLS mismatch | `cilium hubble port-forward &`; `kubectl -n kube-system logs deploy/hubble-relay` | Regenerate Hubble certs; check port 4244 reachability |
| DNS resolution fails only for `toFQDNs`-restricted pods | DNS proxy not in transparent mode, or CoreDNS egress not allowed | `hubble observe --protocol dns --verdict DROPPED` | Add an explicit egress rule to `kube-dns` on UDP/53 **with a `dns` L7 rule** |
| After upgrade, all Services broken | `upgradeCompatibility` skipped → map format change | `cilium-dbg status`; agent logs `unable to open map` | Follow the documented upgrade path; set `upgradeCompatibility` to the previous minor |

### 12.6 Datapath drop reasons, straight from the counters

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf metrics list
REASON                           DIRECTION   PACKETS   BYTES
Policy denied                    INGRESS     18422     1104920
Policy denied                    EGRESS      3311      198660
Invalid source ip                INGRESS     0         0
Unsupported L3 protocol          INGRESS     412       24720
CT: Truncated or invalid header   INGRESS     7         420
Stale or unroutable IP           EGRESS      64        3840
Success                          INGRESS     91882314  71229381020
Success                          EGRESS      88401277  64110228893
```

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor -t drop --related-to 164
Listening for events on 8 CPUs with 64x4096 of shared memory
Press Ctrl-C to quit
xx drop (Policy denied) flow 0x8a1f2c3d to endpoint 164, ifindex 42, file bpf_lxc.c:1998, , identity 52901->46212: 10.244.1.14:41022 -> 10.244.1.87:8080 tcp SYN
xx drop (Policy denied) flow 0x8a1f2c3e to endpoint 164, ifindex 42, file bpf_lxc.c:1998, , identity 52901->46212: 10.244.1.14:41024 -> 10.244.1.87:8080 tcp SYN
```

`identity 52901->46212` and `file bpf_lxc.c:1998` are the two fields that turn "it's broken" into "ingress policy on the destination endpoint has no rule for source identity 52901".

### 12.7 Map pressure — the metric to alert on

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    curl -s http://127.0.0.1:9962/metrics | grep cilium_bpf_map_pressure | sort -k2 -rn | head -6
cilium_bpf_map_pressure{map_name="cilium_ct4_global"} 0.71
cilium_bpf_map_pressure{map_name="cilium_lb4_backends_v3"} 0.44
cilium_bpf_map_pressure{map_name="cilium_snat_v4_external"} 0.38
cilium_bpf_map_pressure{map_name="cilium_ipcache"} 0.22
cilium_bpf_map_pressure{map_name="cilium_lxc"} 0.11
cilium_bpf_map_pressure{map_name="cilium_policy_v2_00164"} 0.03
```

A `PrometheusRule` worth deploying:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-datapath
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: cilium-datapath
      rules:
        - alert: CiliumBPFMapPressureHigh
          expr: cilium_bpf_map_pressure > 0.85
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "eBPF map {{ $labels.map_name }} above 85% on {{ $labels.node }}"
            runbook: "Increase the corresponding *-map-max option; requires an agent restart."
        - alert: CiliumAgentUnreachableNodes
          expr: cilium_unreachable_nodes > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cilium reports {{ $value }} unreachable nodes from {{ $labels.node }}"
        - alert: CiliumEndpointRegenerationFailing
          expr: rate(cilium_endpoint_regeneration_total{outcome="fail"}[10m]) > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Endpoint regeneration failing on {{ $labels.node }}"
        - alert: CiliumPolicyImportErrors
          expr: increase(cilium_policy_import_errors_total[15m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "Cilium rejected a policy on {{ $labels.node }}"
        - alert: CiliumOperatorNoLeader
          expr: absent(cilium_operator_process_start_time_seconds) == 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "No cilium-operator instance is reporting metrics"
```

### 12.8 The escalation artefact

```
$ cilium sysdump --output-filename cilium-sysdump-$(date +%Y%m%d-%H%M)
🔮 Detected Cilium installation in namespace "kube-system"
🔍 Collecting Kubernetes nodes
🔍 Collecting Kubernetes events / pods / services / endpoints
🔍 Collecting Cilium CRDs (CiliumNetworkPolicy, CiliumEndpoint, CiliumIdentity, CiliumNode)
🔍 Collecting Cilium agent logs, `cilium-dbg status --verbose`, bpf map dumps, endpoint list
🔍 Collecting Hubble flows (last 10000 per node)
🗳 Compiling sysdump
✅ The sysdump has been saved to cilium-sysdump-20260901-0918.zip
```

A sysdump contains full policy, all identities, all endpoints and recent flows — treat it as **sensitive**: it exposes your entire network topology and label taxonomy.

---

## 13. Platform-level design decisions and their consequences

| Decision | Option A | Option B | Choose A when | Irreversible? |
|---|---|---|---|---|
| Identity backend | **CRD** (default) | **kvstore (etcd)** | You want zero extra infrastructure; cluster < ~5k identities | Migration is disruptive |
| IPAM | **cluster-pool** | **kubernetes** / **ENI** / **azure** / **multi-pool** | Cilium should own PodCIDR allocation | Changing IPAM mode requires pod recreation |
| Routing | **native** | **tunnel** | Underlay routes pod CIDRs; you need max throughput | Changing requires a rolling restart + route reprogramming |
| kube-proxy | **replacement=true** | co-exist | Kernel ≥ 5.x, you want DSR/Maglev/XDP | Removing kube-proxy is easy to roll back; enabling socket LB is not free of surprises with some CNI-chained setups |
| Endpoint sync | `CiliumEndpoint` | **`CiliumEndpointSlice`** | ≥ ~5k pods, apiserver watch load matters | Toggle is safe but causes a resync storm |
| Encryption | **WireGuard** | IPsec | You want operational simplicity and no key management | Switching requires a coordinated rollout; mixed-mode is broken |
| L7 proxy | **cilium-envoy DaemonSet** | (legacy embedded) | Always, on ≥ 1.16 | — |
| Cluster ID width | `max-connected-clusters=255` | `511` | You will never exceed 255 clusters | **Yes — must be identical across the whole mesh, set at install time** |
| Hubble retention | metrics + export | in-memory only | You need post-incident forensics | — |

### 13.1 Kernel feature gates

| Feature | Minimum kernel | Notes |
|---|---|---|
| Base Cilium datapath | 4.19.57 | 5.10+ strongly recommended; 6.1+ preferred |
| eBPF host routing | 5.10 | Otherwise falls back to `Legacy` — check `Host Routing:` in status |
| eBPF masquerading | 4.19 | Needs kube-proxy replacement |
| Socket LB (cgroup) | 4.19 | `getpeername()` fix-up needs 5.x for full correctness |
| Bandwidth Manager (EDT/fq) | 5.1 | |
| WireGuard | 5.6 | Or the wireguard module |
| BBR for pods | 5.18 | |
| BIG TCP (IPv6/IPv4) | 5.19 / 6.3 | |
| Native XDP acceleration | driver-dependent | Not all NIC drivers support native XDP |

---

## 14. Exam-critical recall sheet

**Ports**

| Port | Component |
|---|---|
| 4240/TCP | `cilium-health` node & endpoint probes |
| 4244/TCP | Hubble server (per agent, peer service) |
| 4245/TCP | Hubble Relay |
| 2379/TCP | `clustermesh-apiserver` etcd |
| 8472/UDP | VXLAN |
| 6081/UDP | Geneve |
| 51871/UDP | WireGuard |
| 9962 / 9963 / 9964 / 9965 / 9966 | Prometheus: agent / operator / envoy / hubble (agent) / hubble-relay |
| 9879 | agent health API (probes) |
| 9234 | operator health API |

**Paths**

| Path | Meaning |
|---|---|
| `/sys/fs/bpf/tc/globals/` | eBPF maps (bpffs) |
| `/run/cilium/cgroupv2` | cgroup v2 mount for socket LB |
| `/var/run/cilium/state/<epID>/` | Per-endpoint generated headers and objects |
| `/var/run/cilium/cilium.sock` | Agent REST API (used by `cilium-dbg` and the CNI plugin) |
| `/var/run/cilium/hubble.sock` | Hubble local socket |
| `/var/run/cilium/envoy/sockets/` | xDS, access-log and admin sockets |
| `/opt/cni/bin/cilium-cni` | CNI plugin binary |
| `/etc/cni/net.d/05-cilium.conflist` | CNI configuration |

**Reserved identities:** `1 host`, `2 world`, `4 health`, `5 init`, `6 remote-node`, `7 kube-apiserver`, `8 ingress`.

**Two CLIs, do not confuse them:**
* `cilium` (cilium-cli) — runs **outside** the cluster, talks to the Kubernetes API. `cilium status`, `cilium install`, `cilium connectivity test`, `cilium sysdump`, `cilium clustermesh`.
* `cilium-dbg` — runs **inside** the agent pod, talks to the agent's unix socket. `cilium-dbg endpoint list`, `cilium-dbg bpf …`, `cilium-dbg monitor`, `cilium-dbg policy get`. (In Cilium ≤ 1.15 this in-pod binary was named `cilium`; `cilium-dbg` is the current name and `cilium` remains as an alias inside the pod.)

**One-line summaries that answer most architecture questions:**
* The agent programs the datapath; **it is not on the datapath**. Killing it does not stop existing traffic.
* The operator does cluster-wide bookkeeping; **it is not on the datapath** either.
* Policy is enforced on **identity**, resolved from the **ipcache**, stored in **per-endpoint policy maps**.
* L7 means **Envoy** (HTTP/gRPC/Kafka) or the **in-agent DNS proxy** (ToFQDN); everything else stays in eBPF.
* Hubble is a **ring buffer**, not storage.

---

## References

- CNCF Cilium Certified Associate (CCA) curriculum — https://github.com/cncf/curriculum (raw: https://raw.githubusercontent.com/cncf/curriculum/master/cca/README.md)
- Cilium — Component Overview — https://docs.cilium.io/en/stable/overview/component-overview/
- Cilium — Introduction & Concepts — https://docs.cilium.io/en/stable/overview/intro/
- Cilium — eBPF Datapath — https://docs.cilium.io/en/stable/network/ebpf/
- Cilium — Life of a Packet — https://docs.cilium.io/en/stable/network/ebpf/lifeofapacket/
- Cilium — Security Identities & Terminology — https://docs.cilium.io/en/stable/gettingstarted/terminology/
- Cilium — Routing (Encapsulation & Native Routing) — https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium — Kubernetes Without kube-proxy — https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Cilium — IPAM — https://docs.cilium.io/en/stable/network/concepts/ipam/
- Cilium — Masquerading — https://docs.cilium.io/en/stable/network/concepts/masquerading/
- Cilium — Transparent Encryption (WireGuard / IPsec) — https://docs.cilium.io/en/stable/security/network/encryption/
- Cilium — Network Policy (CNP / CCNP) — https://docs.cilium.io/en/stable/security/policy/
- Cilium — Kubernetes CRD list — https://docs.cilium.io/en/stable/network/kubernetes/ciliumnetworkpolicy/
- Cilium — Hubble Overview — https://docs.cilium.io/en/stable/overview/intro/#what-is-hubble
- Cilium — Hubble Setup & Metrics — https://docs.cilium.io/en/stable/observability/hubble/
- Cilium — Hubble Metrics Reference — https://docs.cilium.io/en/stable/observability/metrics/
- Cilium — Cluster Mesh — https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
- Cilium — KVStoreMesh — https://docs.cilium.io/en/stable/network/clustermesh/kvstoremesh/
- Cilium — Envoy (L7 proxy) — https://docs.cilium.io/en/stable/security/network/proxy/envoy/
- Cilium — Troubleshooting — https://docs.cilium.io/en/stable/operations/troubleshooting/
- Cilium — System Requirements (kernel, ports) — https://docs.cilium.io/en/stable/operations/system_requirements/
- Cilium — Helm Reference (`values.yaml`) — https://docs.cilium.io/en/stable/helm-reference/
- Cilium — Command Reference (`cilium-dbg`) — https://docs.cilium.io/en/stable/cmdref/
- Cilium CLI (`cilium-cli`) — https://github.com/cilium/cilium-cli
- Cilium source: reserved identities — https://github.com/cilium/cilium/blob/main/pkg/identity/reserved.go
- Cilium source: eBPF datapath (`bpf/`) — https://github.com/cilium/cilium/tree/main/bpf
- eBPF documentation — https://ebpf.io/what-is-ebpf/
- Kubernetes — CNI Network Plugins — https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- Kubernetes — Service `kube-proxy` modes — https://kubernetes.io/docs/reference/networking/virtual-ips/
- kind — Cluster configuration — https://kind.sigs.k8s.io/docs/user/configuration/