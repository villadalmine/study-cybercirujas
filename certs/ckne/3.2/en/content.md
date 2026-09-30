# 3.2 Implementing Routing to Expose Networks

> **Exam weight:** 5.0 · **Domain:** 3 – Advanced Traffic Management
> **Reference stack used throughout:** Kubernetes 1.33+, Cilium 1.18+ (BGP Control Plane v2 API), Calico 3.29+, MetalLB 0.14+, FRR 9/10 as the upstream router. Field names are version-sensitive; the notes below flag where older releases differ.

---

## 1. The architectural problem

A Kubernetes cluster is, by default, a **routing island**. Pods get addresses from a Pod CIDR (for example `10.244.0.0/16`), Services get virtual IPs from a Service CIDR (for example `10.96.0.0/12`), and neither prefix exists anywhere outside the cluster. Nodes know how to reach them because the CNI programs routes, tunnels or eBPF maps on the nodes. The datacenter fabric, the firewall and the WAN router don't.

The usual consequences in production:

| Symptom | Root cause |
|---|---|
| External systems can only reach workloads through `NodePort` + an external load balancer | The fabric has no route to Service or Pod IPs |
| Every packet leaving a pod is SNATed to the node IP | The pod IP is unroutable upstream, so return traffic would be lost without NAT |
| Firewalls and audit logs see node IPs, not workload IPs | Same SNAT: the pod's identity is erased at the node boundary |
| Overlay (VXLAN/Geneve/IPIP) overhead: roughly 50 extra bytes per packet, MTU reduction, harder offload | Encapsulation is needed because the underlay can't route pod prefixes |
| `type: LoadBalancer` stays `<pending>` forever on bare metal | Nothing allocates and announces the external IP |
| A single node owns a VIP and failover takes seconds | L2 (ARP/NDP) announcement: one owner at a time, no ECMP |

**Implementing routing to expose networks** means making selected cluster prefixes (Pod CIDRs, LoadBalancer IPs, ExternalIPs and, in some cases, ClusterIPs) **first-class routes in the surrounding network**. On-premises this is done almost always with **BGP**, spoken by the nodes (or an agent on them) to the top-of-rack (ToR) routers. In the cloud the same goal is reached with VPC-native IPAM or route-table programming.

The design questions the exam, and production, expect you to answer:

1. **What** to advertise: pod CIDRs, LB IPs, ExternalIPs or ClusterIPs, and at what prefix length.
2. **From which nodes**: all nodes, or only nodes that host a ready endpoint (`externalTrafficPolicy: Local`).
3. **To whom**: which peers, which ASNs, eBGP or iBGP, full mesh or route reflectors.
4. **How fast failure converges**: hold timers, BFD, graceful restart.
5. **How the upstream protects itself**: prefix filters, max-prefix and authentication.

---

## 2. Exposure mechanisms compared

| Mechanism | Pod IPs routable externally | LB/ExternalIP routable | ECMP across nodes | Failover speed | L3 boundary crossing | Operational cost |
|---|---|---|---|---|---|---|
| `NodePort` + external LB (F5, HAProxy) | No | Via external LB | Done by the external LB | LB health checks (seconds) | Yes | External LB config per Service |
| Static routes on the router (`10.244.1.0/24 via node1`) | Yes | Possible | Manual | None; blackholes on node loss | Yes | High, and drifts from reality |
| **L2 announcements** (MetalLB L2, Cilium L2 Announcements) | No | Yes | **No**: one node owns each IP | Lease-based (≈ seconds) | **No**, same L2 segment only | Low |
| **BGP from nodes** (Calico/BIRD, Cilium BGP CP, MetalLB BGP, kube-router) | Yes | Yes | **Yes** | Hold timer, or **BFD in sub-second** | Yes | Moderate: needs router cooperation |
| Cloud VPC-native (AWS VPC CNI, GKE VPC-native, Azure CNI) | Yes, as VPC IPs | Via cloud LB | Cloud LB | Cloud-managed | Yes, within VPC | Low, but consumes VPC IP space |

**Rule of thumb:** use L2 announcements for labs, small sites and single-subnet clusters. Use BGP whenever the cluster spans racks or subnets, when you need ECMP, or when you want to drop overlay encapsulation.

### BGP implementations compared

| Implementation | Speaker | Advertises Pod CIDRs | Advertises LB IPs | Allocates LB IPs | Imports routes into node kernel | BFD | Typical pairing |
|---|---|---|---|---|---|---|---|
| **Calico** | BIRD in `calico-node` | Yes (IPAM blocks, default /26) | Yes (`serviceLoadBalancerIPs`) | Recent releases have LB IPAM; otherwise pair with an allocator | **Yes** (learns other nodes' blocks) | Limited, version-dependent | Calico no-encap / cross-subnet |
| **Cilium BGP Control Plane** | GoBGP embedded in `cilium-agent` | Yes (`PodCIDR`, `CiliumPodIPPool`) | Yes (`Service` advertisement) | Yes (LB IPAM, `CiliumLoadBalancerIPPool`) | **No**: advertise only | No (use short timers, or FRR on the host) | Cilium native routing |
| **MetalLB (BGP mode)** | Native Go speaker, or FRR / FRR-K8s | No | Yes | Yes (`IPAddressPool`) | No | **Yes** (FRR modes) | Flannel, kube-router, any CNI without BGP |
| **kube-router** | GoBGP | Yes | Yes (annotations) | No | Yes | No | Lightweight on-prem clusters |

> **Do not run two BGP speakers on the same node toward the same router.** Both bind TCP/179 or present the same source IP, and the router ends up with flapping sessions. Pick one: Calico *or* MetalLB-BGP, Cilium BGP *or* MetalLB-BGP.

---

## 3. BGP mechanics that matter in Kubernetes

### 3.1 ASN design

| Model | Layout | Pros | Cons |
|---|---|---|---|
| **eBGP, one ASN per cluster** | All nodes AS 65001, ToR AS 65000 | Simple; ECMP works because the AS_PATH is identical | Routes learned from node A aren't accepted by node B (own AS in path), which is fine unless nodes must import |
| **eBGP, one ASN per rack** | Rack1 nodes 65101, rack2 65102, spine 65000 | Mirrors the RFC 7938 datacenter design; clean failure domains | More ASNs; upstream needs `multipath-relax` for ECMP across racks |
| **iBGP full mesh** (Calico default) | Every node peers with every node in the same AS | No external router needed for pod routing on one L2 | N(N−1)/2 sessions, impractical beyond about 100 nodes |
| **iBGP + route reflectors** | 2–3 RRs (nodes or ToRs) with `routeReflectorClusterID` | Scales to thousands of nodes | RRs are a control-plane dependency; place them across failure domains |

Private ASN ranges: `64512–65534` (2-byte) and `4200000000–4294967294` (4-byte, RFC 6996).

### 3.2 Next-hop, ECMP and `externalTrafficPolicy`

When N nodes advertise the same `/32` LoadBalancer IP with identical attributes, the router installs **N equal-cost next-hops** and hashes flows (5-tuple) across them.

| `externalTrafficPolicy` | Which nodes advertise the LB IP | Client source IP at pod | Extra hop | Failure behavior |
|---|---|---|---|---|
| `Cluster` (default) | **All** selected nodes | Lost: SNAT to node IP, unless Cilium DSR is used | Possible: node → other node → pod | Node loss removes one ECMP path; flows on it rehash |
| `Local` | **Only nodes with a ready local endpoint** | **Preserved** | None | Endpoint loss withdraws the route; convergence depends on BGP timers |

Calico, Cilium and MetalLB all implement "advertise only from nodes with local endpoints" for `Local`. This is the production default for ingress controllers and gateways: it gives source-IP preservation and one hop.

**ECMP caveat:** with plain hash-based ECMP, adding or removing a next-hop remaps a share of the flow buckets, so some long-lived TCP connections are reset. Mitigations: resilient hashing on the router (`nexthop-group` resilient buckets on Linux/FRR, or vendor "resilient ECMP"); Cilium's Maglev consistent hashing (`loadBalancer.algorithm=maglev`), so any node picks the same backend; and graceful drain (withdraw the route before stopping the node).

### 3.3 Timers, BFD and graceful restart

| Mechanism | Default | Production value | Effect |
|---|---|---|---|
| Hold time / keepalive | 90 s / 30 s (RFC 4271) | 9 s / 3 s | Time to detect a dead peer without BFD |
| **BFD** | Off | 300 ms × 3 | Sub-second failure detection, independent of BGP |
| Graceful restart | Off | On, 120 s | Router keeps forwarding to a restarting agent (e.g. `cilium-agent` upgrade) instead of withdrawing |
| Connect retry | 120 s | 5–12 s | How fast a session comes back after a flap |

Graceful restart and aggressive failure detection pull in opposite directions. GR protects against **control-plane** restarts: the data plane on the node keeps working while the agent restarts. BFD protects against **data-plane** death. Use both: BFD failure overrides GR, because the node is really gone.

---

## 4. Reference topology

```
                     +------------------------------+
                     |   ToR / leaf  (FRR)          |
                     |   AS 65000   10.0.0.1/24     |
                     +---------------+--------------+
                                     |  eBGP, BFD
          +--------------------------+---------------------------+
          |                          |                           |
  +-------+--------+        +--------+-------+          +--------+-------+
  | worker-1       |        | worker-2       |          | worker-3       |
  | 10.0.0.11      |        | 10.0.0.12      |          | 10.0.0.13      |
  | AS 65001       |        | AS 65001       |          | AS 65001       |
  | pods 10.244.1/24|       | pods 10.244.2/24|         | pods 10.244.3/24|
  +----------------+        +----------------+          +----------------+

  Pod CIDR        10.244.0.0/16   (per-node /24, or Calico /26 blocks)
  Service CIDR    10.96.0.0/12    (normally NOT advertised)
  LB pool         172.20.10.0/24  (advertised as /32 per Service)
  ExternalIPs     198.51.100.0/24 (optional)
  Client network  192.168.50.0/24 behind the ToR
```

Label the nodes by rack so selectors can target them:

```
$ kubectl label node worker-1 worker-2 worker-3 rack=rack1 bgp=enabled
node/worker-1 labeled
node/worker-2 labeled
node/worker-3 labeled
```

---

## 5. Upstream router: FRR configuration

The router side is half the design, and a common place for failures. It uses a dynamic neighbor range so new nodes peer without router changes, strict inbound prefix filters, a max-prefix guard, BFD and ECMP.

`/etc/frr/frr.conf` on the ToR:

```
frr version 10.1
frr defaults datacenter
hostname tor1
log syslog informational
!
bfd
 profile k8s-fast
  receive-interval 300
  transmit-interval 300
  detect-multiplier 3
 exit
exit
!
router bgp 65000
 bgp router-id 10.0.0.1
 bgp log-neighbor-changes
 bgp bestpath as-path multipath-relax
 neighbor K8S peer-group
 neighbor K8S remote-as external
 neighbor K8S password Sup3rS3cretBGP
 neighbor K8S timers 3 9
 neighbor K8S bfd profile k8s-fast
 neighbor K8S graceful-restart
 bgp listen range 10.0.0.0/24 peer-group K8S
 bgp listen limit 200
 !
 address-family ipv4 unicast
  neighbor K8S activate
  neighbor K8S route-map K8S-IN in
  neighbor K8S route-map K8S-OUT out
  neighbor K8S maximum-prefix 1000 90
  neighbor K8S soft-reconfiguration inbound
  maximum-paths 16
 exit-address-family
exit
!
ip prefix-list K8S-PODS seq 10 permit 10.244.0.0/16 ge 24 le 32
ip prefix-list K8S-LB seq 10 permit 172.20.10.0/24 le 32
ip prefix-list K8S-EXTIP seq 10 permit 198.51.100.0/24 le 32
ip prefix-list DEFAULT-ONLY seq 10 permit 0.0.0.0/0
!
bgp community-list standard K8S-NO-EXPORT permit 65000:666
!
route-map K8S-IN permit 10
 match ip address prefix-list K8S-LB
 set community no-export additive
exit
route-map K8S-IN permit 20
 match ip address prefix-list K8S-PODS
 set community no-export additive
exit
route-map K8S-IN permit 30
 match ip address prefix-list K8S-EXTIP
exit
route-map K8S-IN deny 100
exit
!
route-map K8S-OUT permit 10
 match ip address prefix-list DEFAULT-ONLY
exit
route-map K8S-OUT deny 100
exit
```

Why each piece is there:

| Directive | Purpose |
|---|---|
| `remote-as external` | Accepts any ASN other than 65000, so the cluster ASN can change without router edits |
| `bgp listen range` | Dynamic peers: any node in `10.0.0.0/24` can open a session |
| `K8S-IN` + final `deny` | A misconfigured cluster can't advertise `0.0.0.0/0` or another tenant's prefix |
| `maximum-prefix 1000 90` | Tears the session down if a bug floods routes (warning at 90%) |
| `no-export` on pod prefixes | Pod CIDRs stay inside the fabric and never leak to the WAN/Internet |
| `maximum-paths 16` | ECMP across up to 16 nodes advertising the same LB `/32` |
| `multipath-relax` | Required for ECMP when nodes in different racks use different ASNs |
| `soft-reconfiguration inbound` | Lets you see received-but-filtered routes (`received-routes`) while debugging |

> FRR 7.4+ enables `bgp ebgp-requires-policy` by default. Without **any** inbound/outbound route-map, eBGP routes are neither accepted nor sent, and `show bgp summary` shows `(Policy)` in the State/PfxRcd column. This is one of the most common "session is up but no routes" causes.

Reload and check the listener:

```
$ sudo systemctl reload frr
$ sudo ss -ltnp 'sport = :179'
State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port  Process
LISTEN  0       4096          0.0.0.0:179        0.0.0.0:*      users:(("bgpd",pid=812,fd=22))
LISTEN  0       4096             [::]:179           [::]:*      users:(("bgpd",pid=812,fd=23))
```

---

## 6. Implementation A — Cilium BGP Control Plane

### 6.1 Architecture

- `cilium-agent` embeds **GoBGP**. The v2 API is declarative: a `CiliumBGPClusterConfig` selects nodes and defines instances and peers, a `CiliumBGPPeerConfig` holds per-peer transport, timer, family and auth settings, and a `CiliumBGPAdvertisement` defines what is announced. The operator renders these into a per-node `CiliumBGPNodeConfig`.
- **Cilium advertises but does not import.** Routes received from peers are not installed into the node's kernel. Cross-subnet pod traffic therefore relies on the node's default route to the ToR, which learned every node's Pod CIDR. That's the intended design: the fabric does the routing.
- LoadBalancer IPs are allocated by **LB IPAM** (`CiliumLoadBalancerIPPool`) and announced by BGP only when a `Service` advertisement selects the Service.

> **API version:** Cilium 1.18 promoted these CRDs to `cilium.io/v2`. On Cilium 1.16–1.17 use `cilium.io/v2alpha1` with the same structure. On LB IP pools, `spec.cidrs` is the pre-1.15 name of `spec.blocks`. The legacy `CiliumBGPPeeringPolicy` (v1 API) is deprecated; don't mix it with the v2 resources.

### 6.2 Enable it (Helm values)

`cilium-values.yaml`:

```yaml
kubeProxyReplacement: true
k8sServiceHost: 10.0.0.10
k8sServicePort: 6443
routingMode: native
ipv4NativeRoutingCIDR: 10.244.0.0/16
autoDirectNodeRoutes: false
enableIPv4Masquerade: true
bpf:
  masquerade: true
ipam:
  mode: kubernetes
bgpControlPlane:
  enabled: true
  secretsNamespace:
    name: kube-system
    create: false
loadBalancer:
  algorithm: maglev
  mode: snat
externalIPs:
  enabled: true
```

Design notes:

- `routingMode: native` removes the overlay. Pod packets leave the node with the pod IP as source, so the fabric **must** know the Pod CIDRs, and BGP is what teaches it.
- `ipv4NativeRoutingCIDR` is the range Cilium **does not masquerade**. Pod-to-pod traffic across the fabric keeps the pod source IP, while traffic to anything else (the Internet) is still SNATed.
- `autoDirectNodeRoutes: true` only works when all nodes share one L2 segment. Leave it `false` when BGP and the ToR provide the routes.
- `loadBalancer.algorithm: maglev` keeps backend selection consistent across nodes, which limits connection resets when ECMP rehashes.

```
$ helm upgrade --install cilium cilium/cilium --version 1.18.2 \
    --namespace kube-system -f cilium-values.yaml
Release "cilium" has been upgraded. Happy Helming!
NAME: cilium
LAST DEPLOYED: Wed Sep 30 10:14:02 2026
NAMESPACE: kube-system
STATUS: deployed
REVISION: 3

$ kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out

$ cilium config view | grep -E 'enable-bgp-control-plane|routing-mode|ipv4-native-routing-cidr'
enable-bgp-control-plane                          true
ipv4-native-routing-cidr                          10.244.0.0/16
routing-mode                                      native
```

### 6.3 Authentication secret

Cilium reads the TCP-MD5 password from the key `password` of a Secret in the BGP secrets namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bgp-auth-tor1
  namespace: kube-system
type: Opaque
stringData:
  password: Sup3rS3cretBGP
```

### 6.4 Peer configuration

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer
spec:
  transport:
    peerPort: 179
  timers:
    connectRetryTimeSeconds: 5
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  authSecretRef: bgp-auth-tor1
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          bgp.example.com/advertise: tor
```

`families[].advertisements` is a **label selector over `CiliumBGPAdvertisement` objects**. A peer with no matching advertisement establishes a session and advertises nothing.

### 6.5 Cluster configuration (instances and peers)

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: rack1
spec:
  nodeSelector:
    matchLabels:
      rack: rack1
      bgp: enabled
  bgpInstances:
    - name: rack1-65001
      localASN: 65001
      peers:
        - name: tor1
          peerASN: 65000
          peerAddress: 10.0.0.1
          peerConfigRef:
            name: tor-peer
```

For dual-homed nodes (two ToRs), add a second entry under `peers`. The router then sees each node twice, and ECMP spans both leaves.

### 6.6 Advertisements

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: tor-advertisements
  labels:
    bgp.example.com/advertise: tor
spec:
  advertisements:
    - advertisementType: PodCIDR
      attributes:
        communities:
          standard:
            - "65000:100"
    - advertisementType: Service
      service:
        addresses:
          - LoadBalancerIP
          - ExternalIP
      selector:
        matchExpressions:
          - key: bgp.example.com/expose
            operator: In
            values:
              - "true"
      attributes:
        communities:
          standard:
            - "65000:200"
```

Things to know:

- A `Service` advertisement **requires a selector**, and only matching Services are announced. To announce every Service, the docs use a never-matching `NotIn` expression (`key: somekey, operator: NotIn, values: ["never-used-value"]`). In production an explicit opt-in label is safer.
- `addresses` can include `ClusterIP`. That makes the virtual Service IPs reachable from the fabric, which is useful for some internal-VIP designs but exposes every selected Service outside the cluster. Treat it as a security decision, not a convenience.
- For `externalTrafficPolicy: Local` (and `internalTrafficPolicy: Local` for ClusterIP), Cilium advertises the `/32` only from nodes with a local ready endpoint.
- Advertised Service prefixes are `/32` (IPv4) and `/128` (IPv6).

### 6.7 LoadBalancer IP pool and an exposed Service

```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: public-pool
spec:
  blocks:
    - cidr: 172.20.10.0/24
  serviceSelector:
    matchLabels:
      bgp.example.com/expose: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: shop
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: shop
  labels:
    bgp.example.com/expose: "true"
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
```

```
$ kubectl apply -f bgp-cilium.yaml
secret/bgp-auth-tor1 created
ciliumbgppeerconfig.cilium.io/tor-peer created
ciliumbgpclusterconfig.cilium.io/rack1 created
ciliumbgpadvertisement.cilium.io/tor-advertisements created
ciliumloadbalancerippool.cilium.io/public-pool created
namespace/shop created
deployment.apps/web created
service/web created

$ kubectl -n shop get svc web
NAME   TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)        AGE
web    LoadBalancer   10.96.143.20    172.20.10.10   80:31544/TCP   12s

$ kubectl -n shop get pods -o wide
NAME                   READY   STATUS    RESTARTS   AGE   IP            NODE
web-6f9c7d8b54-2xkpl   1/1     Running   0          40s   10.244.1.37   worker-1
web-6f9c7d8b54-vq7wz   1/1     Running   0          40s   10.244.2.18   worker-2
```

### 6.8 Verification from the cluster

```
$ kubectl get ciliumbgpnodeconfigs
NAME       AGE
worker-1   3m
worker-2   3m
worker-3   3m

$ cilium bgp peers
Node       Local AS   Peer AS   Peer Address   Session State   Uptime   Family         Received   Advertised
worker-1   65001      65000     10.0.0.1       established     3m1s     ipv4/unicast   1          2
worker-2   65001      65000     10.0.0.1       established     3m1s     ipv4/unicast   1          2
worker-3   65001      65000     10.0.0.1       established     2m58s    ipv4/unicast   1          1

$ cilium bgp routes advertised ipv4 unicast
Node       VRouter   Peer       Prefix            NextHop     Age    Attrs
worker-1   65001     10.0.0.1   10.244.1.0/24     10.0.0.11   3m1s   [{Origin: i} {AsPath: 65001} {Nexthop: 10.0.0.11} {Communities: 65000:100}]
worker-1   65001     10.0.0.1   172.20.10.10/32   10.0.0.11   55s    [{Origin: i} {AsPath: 65001} {Nexthop: 10.0.0.11} {Communities: 65000:200}]
worker-2   65001     10.0.0.1   10.244.2.0/24     10.0.0.12   3m1s   [{Origin: i} {AsPath: 65001} {Nexthop: 10.0.0.12} {Communities: 65000:100}]
worker-2   65001     10.0.0.1   172.20.10.10/32   10.0.0.12   55s    [{Origin: i} {AsPath: 65001} {Nexthop: 10.0.0.12} {Communities: 65000:200}]
worker-3   65001     10.0.0.1   10.244.3.0/24     10.0.0.13   2m58s  [{Origin: i} {AsPath: 65001} {Nexthop: 10.0.0.13} {Communities: 65000:100}]
```

`worker-3` does **not** advertise `172.20.10.10/32`: it has no `web` pod, and the Service is `externalTrafficPolicy: Local`. This is the expected behavior, not a fault.

From inside an agent pod (same data, useful when the `cilium` CLI isn't installed):

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp peers
Local AS   Peer AS   Peer Address     Session       Uptime   Family         Received   Advertised
65001      65000     10.0.0.1:179     established   3m10s    ipv4/unicast   1          2
```

### 6.9 Per-node overrides

Use `CiliumBGPNodeConfigOverride` when a node needs an explicit router ID (IPv6-only nodes have no IPv4 address to derive one from) or a specific source address:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPNodeConfigOverride
metadata:
  name: worker-1
spec:
  bgpInstances:
    - name: rack1-65001
      routerID: 10.0.0.11
      peers:
        - name: tor1
          localAddress: 10.0.0.11
```

The object name **must equal the node name**, and `bgpInstances[].name` / `peers[].name` must match the names in the `CiliumBGPClusterConfig`.

---

## 7. Implementation B — Calico BGP (BIRD)

### 7.1 Architecture

- Each `calico-node` runs **BIRD**, which both advertises and **imports** routes. Nodes learn each other's IPAM blocks and program kernel routes (`proto bird`).
- By default, Calico builds an **iBGP full mesh** between all nodes in AS 64512. For fabric integration you disable the mesh and peer with ToRs, or with route reflectors.
- Calico advertises **IPAM blocks** (default `/26` per block, several per node), not one `/24` per node. When a node borrows an IP from another node's block, it advertises a `/32`. Size the router's prefix filters and `maximum-prefix` accordingly.
- Manifests below use `projectcalico.org/v3`. Apply them with `calicoctl`, or with `kubectl` when the Calico API server is installed (the default with the Tigera operator).

### 7.2 Remove encapsulation on the pool

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: 10.244.0.0/16
  blockSize: 26
  ipipMode: Never
  vxlanMode: Never
  natOutgoing: true
  nodeSelector: all()
```

`natOutgoing: true` SNATs pod traffic only when the destination is **outside all Calico pools**. Inbound traffic to pod IPs from the fabric is routed directly and isn't NATed. If some destinations (for example `192.168.50.0/24`) must see real pod IPs, create a disabled IPPool for that range: Calico treats destinations inside any IPPool as non-NAT.

```yaml
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: no-nat-clients
spec:
  cidr: 192.168.50.0/24
  disabled: true
  natOutgoing: false
  ipipMode: Never
  vxlanMode: Never
```

### 7.3 Global BGP configuration

```yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: false
  asNumber: 65001
  serviceLoadBalancerIPs:
    - cidr: 172.20.10.0/24
  serviceExternalIPs:
    - cidr: 198.51.100.0/24
  serviceClusterIPs:
    - cidr: 10.96.0.0/12
  communities:
    - name: pods-internal
      value: "65000:100"
  prefixAdvertisements:
    - cidr: 10.244.0.0/16
      communities:
        - pods-internal
        - "65000:666"
```

Calico's Service advertisement semantics:

- For `Cluster` policy, every node advertises the **whole configured range** (for example `172.20.10.0/24`).
- For `Local` policy, the nodes with a local endpoint **additionally** advertise the Service's `/32`. Longest-prefix match then steers traffic to them.
- `serviceClusterIPs` exposes ClusterIPs to the fabric. Only include it deliberately, and remove the block if you don't want it.
- Calico announces LB IPs; something must still **assign** them (Calico LoadBalancer IPAM in recent releases, MetalLB running with no speaker, or a cloud controller).

### 7.4 Peering with the ToR

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bgp-secrets
  namespace: calico-system
type: Opaque
stringData:
  tor1: Sup3rS3cretBGP
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: calico-bgp-secret-access
  namespace: calico-system
rules:
  - apiGroups:
      - ""
    resources:
      - secrets
    resourceNames:
      - bgp-secrets
    verbs:
      - watch
      - list
      - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: calico-bgp-secret-access
  namespace: calico-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: calico-bgp-secret-access
subjects:
  - kind: ServiceAccount
    name: calico-node
    namespace: calico-system
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: rack1-tor1
spec:
  peerIP: 10.0.0.1
  asNumber: 65000
  nodeSelector: rack == 'rack1'
  keepOriginalNextHop: false
  password:
    secretKeyRef:
      name: bgp-secrets
      key: tor1
```

With the manifest install (no operator), `calico-node` runs in `kube-system`, and the Secret, Role and RoleBinding go there instead.

### 7.5 Route reflector variant (large clusters)

Promote two nodes per rack to RRs and peer everyone with them:

```
$ kubectl label node worker-1 worker-2 route-reflector=true
node/worker-1 labeled
node/worker-2 labeled

$ calicoctl patch node worker-1 -p '{"spec":{"bgp":{"routeReflectorClusterID":"244.0.0.1"}}}'
Successfully patched 1 'Node' resource

$ calicoctl patch node worker-2 -p '{"spec":{"bgp":{"routeReflectorClusterID":"244.0.0.1"}}}'
Successfully patched 1 'Node' resource
```

```yaml
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: peer-with-route-reflectors
spec:
  nodeSelector: all()
  peerSelector: route-reflector == 'true'
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: rr-to-tor
spec:
  nodeSelector: route-reflector == 'true'
  peerIP: 10.0.0.1
  asNumber: 65000
```

### 7.6 Verification

```
$ kubectl apply -f calico-bgp.yaml
ippool.projectcalico.org/default-ipv4-ippool configured
bgpconfiguration.projectcalico.org/default configured
secret/bgp-secrets created
role.rbac.authorization.k8s.io/calico-bgp-secret-access created
rolebinding.rbac.authorization.k8s.io/calico-bgp-secret-access created
bgppeer.projectcalico.org/rack1-tor1 created

$ sudo calicoctl node status
Calico process is running.

IPv4 BGP status
+--------------+-----------+-------+----------+-------------+
| PEER ADDRESS | PEER TYPE | STATE |  SINCE   |    INFO     |
+--------------+-----------+-------+----------+-------------+
| 10.0.0.1     | global    | up    | 10:31:07 | Established |
+--------------+-----------+-------+----------+-------------+

IPv6 BGP status
No IPv6 peers found.
```

`PEER TYPE` tells you where the peering came from: `node-to-node mesh`, `global` (a `BGPPeer` without a `node` field) or `node specific`. If you still see mesh peers after disabling the mesh, the `BGPConfiguration` named `default` was not applied.

Inspecting BIRD directly:

```
$ kubectl -n calico-system exec ds/calico-node -c calico-node -- birdcl show protocols
BIRD v0.3.3+birdv1.6.8 ready.
name     proto    table    state  since       info
static1  Static   master   up     10:30:58
kernel1  Kernel   master   up     10:30:58
device1  Device   master   up     10:30:58
direct1  Direct   master   up     10:30:58
Global_10_0_0_1 BGP      master   up     10:31:07    Established

$ kubectl -n calico-system exec ds/calico-node -c calico-node -- birdcl show route export Global_10_0_0_1
BIRD v0.3.3+birdv1.6.8 ready.
10.244.1.0/26      blackhole [static1 10:30:58] * (200)
10.244.1.64/26     blackhole [static1 10:30:58] * (200)
172.20.10.0/24     blackhole [static1 10:31:02] * (200)
172.20.10.10/32    blackhole [static1 10:31:40] * (200)
```

The `blackhole` entries are expected. Calico installs blackhole routes for its own blocks locally (more specific `/32` routes to pod interfaces override them) and exports them to BGP.

---

## 8. Implementation C — MetalLB in BGP mode

Use MetalLB when the CNI can't speak BGP (Flannel, some managed on-prem distributions), or when the only goal is exposing LoadBalancer IPs without routing pod networks.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: tor1-bgp-auth
  namespace: metallb-system
type: kubernetes.io/basic-auth
stringData:
  password: Sup3rS3cretBGP
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: public
  namespace: metallb-system
spec:
  addresses:
    - 172.20.10.0/24
  autoAssign: true
  avoidBuggyIPs: true
  serviceAllocation:
    namespaces:
      - shop
---
apiVersion: metallb.io/v1beta1
kind: BFDProfile
metadata:
  name: fast
  namespace: metallb-system
spec:
  receiveInterval: 300
  transmitInterval: 300
  detectMultiplier: 3
---
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata:
  name: tor1
  namespace: metallb-system
spec:
  myASN: 65001
  peerASN: 65000
  peerAddress: 10.0.0.1
  holdTime: 9s
  keepaliveTime: 3s
  bfdProfile: fast
  passwordSecret:
    name: tor1-bgp-auth
    namespace: metallb-system
  nodeSelectors:
    - matchLabels:
        rack: rack1
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: public
  namespace: metallb-system
spec:
  ipAddressPools:
    - public
  aggregationLength: 32
  communities:
    - "65000:200"
  peers:
    - tor1
```

Notes:

- **BFD requires the FRR or FRR-K8s backend.** The native Go speaker ignores `bfdProfile`.
- `aggregationLength: 32` announces each IP individually, which ECMP and `Local` policy need. A shorter aggregation (for example `24`) cuts route count but is advertised by every node regardless of endpoint placement.
- `localPref` only applies to iBGP peers (`myASN == peerASN`).
- `avoidBuggyIPs` skips `.0` and `.255`, which some older CPE devices drop.

```
$ kubectl -n metallb-system get bgppeers,ipaddresspools,bgpadvertisements
NAME                            ADDRESS    ASN     BFD PROFILE   MULTI HOPS
bgppeer.metallb.io/tor1         10.0.0.1   65000   fast

NAME                               AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
ipaddresspool.metallb.io/public    true          true              ["172.20.10.0/24"]

NAME                                   IPADDRESSPOOLS   IPADDRESSPOOL SELECTORS   PEERS
bgpadvertisement.metallb.io/public     ["public"]                                 ["tor1"]

$ kubectl -n metallb-system exec ds/speaker -c frr -- vtysh -c 'show bgp summary'
IPv4 Unicast Summary (VRF default):
BGP router identifier 10.0.0.11, local AS number 65001 vrf-id 0
BGP table version 3

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.0.0.1        4      65000        61        63        3    0    0 00:02:57            1        1 N/A

Total number of neighbors 1

$ kubectl -n metallb-system exec ds/speaker -c frr -- vtysh -c 'show bfd peers brief'
Session count: 1
SessionId  LocalAddress                             PeerAddress                             Status
=========  ============                             ===========                             ======
2749301823 10.0.0.11                                10.0.0.1                                up
```

---

## 9. Verification from the network side

The cluster saying "advertised" proves only half the path. Always confirm on the router, then from a real client.

```
$ sudo vtysh -c 'show bgp summary'
IPv4 Unicast Summary (VRF default):
BGP router identifier 10.0.0.1, local AS number 65000 vrf-id 0
BGP table version 18
RIB entries 9, using 1728 bytes of memory
Peers 3, using 60 KiB of memory
Peer groups 1, using 64 bytes of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
*10.0.0.11      4      65001       112       110       18    0    0 00:05:21            2        1 N/A
*10.0.0.12      4      65001       112       110       18    0    0 00:05:21            2        1 N/A
*10.0.0.13      4      65001       109       108       18    0    0 00:05:18            1        1 N/A

Total number of neighbors 3
* - dynamic neighbor
3 dynamic neighbor(s), limit 200
```

```
$ sudo vtysh -c 'show ip route bgp'
Codes: K - kernel route, C - connected, S - static, R - RIP,
       O - OSPF, I - IS-IS, B - BGP, E - EIGRP, N - NHRP,
       > - selected route, * - FIB route, q - queued, r - rejected, b - backup

B>* 10.244.1.0/24 [20/0] via 10.0.0.11, eth1, weight 1, 00:05:21
B>* 10.244.2.0/24 [20/0] via 10.0.0.12, eth1, weight 1, 00:05:21
B>* 10.244.3.0/24 [20/0] via 10.0.0.13, eth1, weight 1, 00:05:18
B>* 172.20.10.10/32 [20/0] via 10.0.0.11, eth1, weight 1, 00:02:44
  *                        via 10.0.0.12, eth1, weight 1, 00:02:44
```

Two next-hops for `172.20.10.10/32` means ECMP is active and limited to the endpoint nodes. Inspect the attributes:

```
$ sudo vtysh -c 'show bgp ipv4 unicast 172.20.10.10/32'
BGP routing table entry for 172.20.10.10/32, version 17
Paths: (2 available, best #1, table default)
  Advertised to non peer-group peers:
  10.0.0.11 10.0.0.12 10.0.0.13
  65001
    10.0.0.11 from 10.0.0.11 (10.0.0.11)
      Origin IGP, valid, external, multipath, best (Router ID)
      Community: 65000:200 no-export
      Last update: Wed Sep 30 10:33:12 2026
  65001
    10.0.0.12 from 10.0.0.12 (10.0.0.12)
      Origin IGP, valid, external, multipath
      Community: 65000:200 no-export
      Last update: Wed Sep 30 10:33:12 2026
```

Confirm the kernel really has the multipath route (a BGP best path that isn't in the FIB forwards nothing):

```
$ ip route show 172.20.10.10
172.20.10.10 proto bgp metric 20
	nexthop via 10.0.0.11 dev eth1 weight 1
	nexthop via 10.0.0.12 dev eth1 weight 1
```

End-to-end, from a client in `192.168.50.0/24`:

```
$ curl -s http://172.20.10.10/hostname
web-6f9c7d8b54-2xkpl

$ for i in $(seq 1 6); do curl -s --local-port $((40000+i)) http://172.20.10.10/hostname; echo; done
web-6f9c7d8b54-2xkpl
web-6f9c7d8b54-vq7wz
web-6f9c7d8b54-vq7wz
web-6f9c7d8b54-2xkpl
web-6f9c7d8b54-2xkpl
web-6f9c7d8b54-vq7wz

$ curl -s http://172.20.10.10/clientip
192.168.50.23:40006
```

Changing the source port changes the 5-tuple hash, which spreads flows across both nodes. `/clientip` returns the real client address, which proves `externalTrafficPolicy: Local` preserved the source IP.

Pod IPs are directly reachable too (native routing):

```
$ curl -s http://10.244.2.18:8080/hostname
web-6f9c7d8b54-vq7wz
```

On Linux routers, raise ECMP hash entropy from L3-only to L4:

```
$ sudo sysctl -w net.ipv4.fib_multipath_hash_policy=1
net.ipv4.fib_multipath_hash_policy = 1
```

---

## 10. Failure behavior and convergence testing

Test failure before production does it for you.

**Scaling endpoints (Local policy):**

```
$ kubectl -n shop scale deploy web --replicas=1
deployment.apps/web scaled

$ sudo vtysh -c 'show ip route 172.20.10.10'
Routing entry for 172.20.10.10/32
  Known via "bgp", distance 20, metric 0, best
  Last update 00:00:04 ago
  * 10.0.0.11, via eth1, weight 1
```

The withdrawal happens when the endpoint leaves `EndpointSlice` readiness. Combine this with `terminationGracePeriodSeconds`, a `preStop` sleep and readiness failing first, so the route is withdrawn **before** the process stops accepting connections.

**Node failure without BFD versus with BFD:**

```
$ sudo vtysh -c 'show bgp neighbors 10.0.0.12' | grep -E 'BGP state|Hold time|BFD'
  BGP state = Established, up for 00:12:40
  Hold time is 9 seconds, keepalive interval is 3 seconds
  BFD: Type: single hop
    Detect Multiplier: 3, Min Rx interval: 300, Min Tx interval: 300
    Status: Up, Last update: 0:00:12:38

$ sudo journalctl -u frr --since "1 min ago" | grep -E 'BFD|10.0.0.12'
Sep 30 10:47:02 tor1 bgpd[812]: [HVRWP-5R9NQ] %ADJCHANGE: neighbor 10.0.0.12(Unknown) in vrf default Down BFD down received
```

| Detection | Time to withdraw |
|---|---|
| Hold timer 90 s (defaults) | Up to 90 s of blackholing |
| Hold timer 9 s | ≤ 9 s |
| BFD 300 ms × 3 | ≈ 0.9 s |

**Agent restart (graceful restart):** restart `cilium-agent` on one node and confirm the router keeps the routes as stale instead of withdrawing them:

```
$ kubectl -n kube-system delete pod -l k8s-app=cilium --field-selector spec.nodeName=worker-1
pod "cilium-7kq2d" deleted

$ sudo vtysh -c 'show bgp ipv4 unicast 10.244.1.0/24' | grep -i stale
      Origin IGP, valid, external, best (First path received), stale
```

---

## 11. Troubleshooting guide

### 11.1 Systematic ladder

1. **Is TCP/179 reachable?** `nc -zv 10.0.0.1 179` from the node; `ss -tn '( dport = :179 or sport = :179 )'`.
2. **Does the session reach `Established`?** Cluster view (`cilium bgp peers`, `calicoctl node status`, `vtysh` in the MetalLB FRR container), then router view (`show bgp summary`).
3. **Is the cluster *trying* to advertise the prefix?** `cilium bgp routes advertised`, `birdcl show route export <proto>`, the Service's `EXTERNAL-IP`.
4. **Did the router *accept* it?** `show bgp neighbors <ip> received-routes` versus `routes` (accepted after policy).
5. **Is it in the FIB with the expected next-hops?** `show ip route`, `ip route show`.
6. **Does the data path work?** Client `curl`, then `tcpdump` on the node's uplink, then `hubble observe` / `cilium-dbg monitor` / `conntrack -L` on the node.

### 11.2 Symptom → cause → fix

| Symptom | Likely cause | How to confirm | Fix |
|---|---|---|---|
| Session stuck in `Active`/`Connect`/`idle` | Firewall blocks TCP/179, wrong `peerAddress`, router has no neighbor/listen range | `tcpdump -ni eth0 tcp port 179` shows SYNs with no SYN-ACK, or RST | Open 179 both ways; fix the listen range |
| Session flaps right after `OpenSent` | ASN mismatch | Router log: `NOTIFICATION sent ... OPEN Message Error/Bad Peer AS` | Align `peerASN`/`localASN` with `remote-as` |
| Session never forms and the log shows MD5 errors | Password mismatch, or the Secret isn't readable (wrong key name, namespace or RBAC) | Kernel log: `MD5 Hash mismatch for ...`; agent log mentions the secret | Fix the Secret key (`password` for Cilium and MetalLB), namespace and RBAC |
| Peer is several hops away and never connects | eBGP TTL=1 | `tcpdump` shows packets with TTL expiring | `ebgpMultiHop` (MetalLB) / `ebgp-multihop` on the router, or peer the directly connected leaf |
| `Established` but `PfxRcd` shows `(Policy)` | FRR `ebgp-requires-policy` with no route-map | `show bgp summary` | Add inbound/outbound route-maps |
| `Established`, 0 prefixes received | No `CiliumBGPAdvertisement` matches the peer's `families[].advertisements` selector; Service lacks the selector label; Calico ranges not set in `BGPConfiguration` | `cilium bgp routes advertised` is empty; `kubectl get svc --show-labels` | Fix the labels and selectors |
| LB IP advertised by only some nodes | `externalTrafficPolicy: Local` working as designed; the other nodes have no ready endpoint | `kubectl get endpointslices -l kubernetes.io/service-name=web -o wide` | Expected. Spread replicas (topology spread constraints) for more ECMP paths |
| LB IP advertised by no node | Service `EXTERNAL-IP` is `<pending>` (no pool matches) or no ready endpoints | `kubectl describe svc`; `kubectl get ciliumloadbalancerippools` (look for `CONFLICTING`) | Fix the pool `serviceSelector` or overlapping pool CIDRs |
| Route received but not installed (`received-routes` shows it, `routes` doesn't) | Inbound prefix-list too strict (for example `le 24` while Calico sends `/26` and `/32`) | `show bgp neighbors X received-routes` vs `routes` | Widen the `le` bound |
| Route in the RIB, not in the FIB | Next-hop unreachable, or zebra/kernel problem | `show ip route` shows `inactive`/`r` | Make the next-hop reachable; check `show zebra` |
| Traffic reaches the node, reply never arrives | Asymmetric path plus `rp_filter=1`, or SNAT expectations broken | `tcpdump` on the node: SYN in, SYN-ACK leaves by a different interface | `rp_filter=2` (loose) on multi-homed nodes; align routing |
| Works for small requests, hangs on large ones | MTU mismatch after removing or keeping encapsulation | `ping -M do -s 1472 <pod-ip>` fails | Align the MTU (CNI `mtu`, fabric MTU); clamp MSS if needed |
| Pod-to-external shows the node IP in firewall logs | Masquerade still applies (`ipv4NativeRoutingCIDR` too narrow, or `natOutgoing` rules) | `conntrack -L -d <dst>` shows `src=` rewritten | Put the destination inside the non-masquerade range / a disabled IPPool |
| Existing connections reset when a node joins or leaves | ECMP rehash | Correlate resets with route changes in `journalctl -u frr` | Resilient hashing, Maglev, graceful drain |
| Router sessions flap every few seconds | Two speakers on the same node (for example Calico BIRD plus MetalLB) | `ss -ltnp 'sport = :179'` on the node lists two processes | Run a single speaker |
| Pod CIDR leaks to the upstream ISP | No `no-export` community / no outbound filter at the border | Border router `show bgp ... advertised-routes` | Tag with `no-export`, filter at the edge |

### 11.3 Useful commands

```
$ kubectl -n kube-system logs ds/cilium -c cilium-agent --since=10m | grep -i -E 'bgp|peer'
time="2026-09-30T10:31:05Z" level=info msg="Peer Up" Key=10.0.0.1 State=BGP_FSM_OPENCONFIRM Topic=Peer asn=65001 component=gobgp.BgpServerInstance subsys=bgp-control-plane

$ kubectl get ciliumbgpnodeconfigs worker-1 -o jsonpath='{.status.bgpInstances[0].peers[0].peeringState}{"\n"}'
established

$ kubectl get ciliumloadbalancerippools
NAME          DISABLED   CONFLICTING   IPS AVAILABLE   AGE
public-pool   false      False         253             20m

$ sudo tcpdump -ni eth0 -c 6 'tcp port 179'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:52:11.402113 IP 10.0.0.11.44127 > 10.0.0.1.179: Flags [P.], seq 1:20, ack 1, win 502, length 19: BGP
10:52:11.402398 IP 10.0.0.1.179 > 10.0.0.11.44127: Flags [.], ack 20, win 509, length 0
10:52:14.405774 IP 10.0.0.1.179 > 10.0.0.11.44127: Flags [P.], seq 1:20, ack 20, win 509, length 19: BGP
10:52:14.405989 IP 10.0.0.11.44127 > 10.0.0.1.179: Flags [.], ack 20, win 502, length 0

$ sudo vtysh -c 'show bgp neighbors 10.0.0.11 received-routes'
BGP table version is 18, local router ID is 10.0.0.1, vrf id 0
Default local pref 100, local AS 65000
Status codes:  s suppressed, d damped, h history, * valid, > best, = multipath,
               i internal, r RIB-failure, S Stale, R Removed
Origin codes:  i - IGP, e - EGP, ? - incomplete

    Network          Next Hop            Metric LocPrf Weight Path
 *> 10.244.1.0/24    10.0.0.11                              0 65001 i
 *> 172.20.10.10/32  10.0.0.11                              0 65001 i

Total number of prefixes 2

$ sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth0.rp_filter
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 2
```

In the 19-byte BGP packets every 3 s above, 19 bytes is the size of a BGP KEEPALIVE. Seeing them at the configured interval proves the session is healthy at the wire level.

---

## 12. Security and operational hardening

| Control | Where | Why |
|---|---|---|
| Inbound prefix-lists with explicit `le`/`ge` and a final deny | Router | A cluster must never be able to hijack arbitrary prefixes |
| `maximum-prefix` | Router | Caps the blast radius of a bug or misconfiguration |
| TCP-MD5 (or TCP-AO where supported) | Both sides | Prevents session spoofing and injection on shared segments |
| `no-export` / internal communities on pod prefixes | Cluster or ToR | Keeps pod space inside the datacenter |
| Opt-in label for Service advertisement | Cluster | A developer creating `type: LoadBalancer` doesn't automatically publish to the fabric |
| Don't advertise ClusterIPs unless it's a deliberate design | Cluster | ClusterIPs are an internal contract; exposing them bypasses the ingress/gateway layer |
| RBAC on BGP CRDs (`ciliumbgp*`, `bgppeers`, `bgpconfigurations`) | Cluster | Whoever can edit them controls datacenter routing |
| Separate pools per trust zone (`serviceSelector`, `serviceAllocation.namespaces`) | Cluster | Tenant A can't take an IP from the DMZ pool |
| GTSM / TTL security (`ttl-security hops 1`) | Router | Rejects BGP packets from more than one hop away |

---

## 13. Design decision checklist

| Question | Default recommendation |
|---|---|
| Overlay or native routing? | Native routing plus BGP when the fabric cooperates; overlay when you can't touch the network |
| Advertise Pod CIDRs? | Yes with native routing; tag them `no-export` |
| Advertise ClusterIPs? | No, unless it's a documented internal-VIP design |
| LB IP prefix length | `/32` per Service (needed for `Local` and ECMP) |
| `externalTrafficPolicy` for ingress/gateway | `Local`, with anti-affinity or topology spread for multiple ECMP paths |
| Failure detection | BFD where supported, otherwise 3 s / 9 s timers |
| Agent upgrades | Graceful restart enabled on both sides |
| ASN plan | One private ASN per cluster (or per rack), router uses `remote-as external` plus a listen range |
| Scale beyond ~100 nodes (iBGP) | Route reflectors, or eBGP to the ToRs (no mesh) |
| One BGP speaker per node | Always |

---

## 14. Practice tasks (exam style)

1. **Expose a Service over BGP with Cilium.** Given a peer at `10.0.0.1` AS 65000, configure cluster AS 65001 on nodes labeled `bgp=enabled`. Allocate LB IPs from `172.20.10.0/24` only for Services labeled `expose=true`, and advertise them. Verify with `cilium bgp routes advertised ipv4 unicast`, and confirm that a `Local` Service is advertised only from nodes hosting its pods.
2. **Disable Calico's node-to-node mesh without losing connectivity.** Create the global `BGPPeer` to the ToR **before** setting `nodeToNodeMeshEnabled: false`, then confirm `calicoctl node status` shows only `global` peers and that pod-to-pod traffic across nodes still works.
3. **Diagnose a session that stays `Active`.** Use `tcpdump tcp port 179` to tell a firewall drop (SYN, no reply) from an ASN mismatch (session opens, then NOTIFICATION) and from an MD5 mismatch (kernel log).
4. **Fix "Established, 0 prefixes".** Find a missing advertisement label on the peer config, a Service without the selector label, or FRR's `(Policy)` state.
5. **Reduce failover time** from about 90 s to under 1 s with MetalLB, using a `BFDProfile` and the matching FRR `bfd` configuration, and prove it by stopping a node and reading the router log.

---

## References

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes — Service (`type: LoadBalancer`, `externalTrafficPolicy`, `externalIPs`): https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Source IP preservation with `externalTrafficPolicy`: https://kubernetes.io/docs/tutorials/services/source-ip/
- Kubernetes — Cluster networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Cilium — BGP Control Plane overview: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/
- Cilium — BGP Control Plane v2 resources: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-v2/
- Cilium — BGP operation and troubleshooting: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-operation/
- Cilium — LoadBalancer IP Address Management (LB IPAM): https://docs.cilium.io/en/stable/network/lb-ipam/
- Cilium — Routing (native routing, `ipv4NativeRoutingCIDR`): https://docs.cilium.io/en/stable/network/concepts/routing/
- Cilium — L2 Announcements: https://docs.cilium.io/en/stable/network/l2-announcements/
- Calico — Configure BGP peering: https://docs.tigera.io/calico/latest/networking/configuring/bgp
- Calico — Advertise Kubernetes Service IP addresses: https://docs.tigera.io/calico/latest/networking/configuring/advertise-service-ips
- Calico — BGPConfiguration resource: https://docs.tigera.io/calico/latest/reference/resources/bgpconfig
- Calico — BGPPeer resource: https://docs.tigera.io/calico/latest/reference/resources/bgppeer
- Calico — IPPool resource: https://docs.tigera.io/calico/latest/reference/resources/ippool
- Calico — Determine best networking option: https://docs.tigera.io/calico/latest/networking/determine-best-networking
- MetalLB — Concepts (BGP mode): https://metallb.universe.tf/concepts/bgp/
- MetalLB — Configuration (BGPPeer, BGPAdvertisement, BFDProfile): https://metallb.universe.tf/configuration/
- MetalLB — Advanced BGP configuration: https://metallb.universe.tf/configuration/_advanced_bgp_configuration/
- FRRouting — BGP documentation: https://docs.frrouting.org/en/latest/bgp.html
- FRRouting — BFD documentation: https://docs.frrouting.org/en/latest/bfd.html
- RFC 4271 — A Border Gateway Protocol 4 (BGP-4): https://www.rfc-editor.org/rfc/rfc4271
- RFC 7938 — Use of BGP for Routing in Large-Scale Data Centers: https://www.rfc-editor.org/rfc/rfc7938
- RFC 5880 — Bidirectional Forwarding Detection (BFD): https://www.rfc-editor.org/rfc/rfc5880
- RFC 6996 — Autonomous System (AS) Reservation for Private Use: https://www.rfc-editor.org/rfc/rfc6996
- RFC 4724 — Graceful Restart Mechanism for BGP: https://www.rfc-editor.org/rfc/rfc4724