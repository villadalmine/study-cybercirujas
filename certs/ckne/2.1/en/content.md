# 2.1 Configuring L4 Services

> **Exam weight:** 4.17% · **Level:** Advanced (SRE / Platform Architect)
> **Scope:** the Kubernetes `Service` as a Layer 4 (TCP/UDP/SCTP) abstraction: ClusterIP, NodePort, LoadBalancer, ExternalName, headless and selector-less Services; EndpointSlices; traffic policies; session affinity; dual-stack; how kube-proxy programs the data path; and how to diagnose a Service that does not answer.

---

## 1. Motivation: the architectural problem

Pods are disposable. A Deployment rollout, a node drain, an eviction or an OOM kill replaces Pods, and each new Pod gets a new IP from the node's Pod CIDR. A client that stores a Pod IP is holding a pointer that will go stale.

Production needs four things that raw Pod IPs cannot provide:

| Requirement | Why Pod IPs fail | What the Service provides |
|---|---|---|
| **Stable address** | IPs change on every reschedule | A virtual IP (ClusterIP) that lasts as long as the Service object |
| **Load distribution** | One IP means one backend | L4 spreading across every *ready* endpoint |
| **Health-aware membership** | Clients cannot see readiness | Only Pods that pass `readinessProbe` are programmed as `ready` endpoints |
| **External exposure** | Pod CIDRs are usually not routable outside the cluster | NodePort / LoadBalancer entry points on the nodes and in the cloud |

The key point, and the thing most troubleshooting depends on: **a ClusterIP is not bound to any interface.** No process listens on it. It exists only as rules in the kernel of each node (iptables, nftables or IPVS), or in eBPF maps when a CNI replaces kube-proxy. A packet sent to `10.96.14.20:80` is rewritten (DNAT) to a real `PodIP:targetPort` **on the node where the client runs**, before it leaves that node. A Service is distributed NAT configuration, not a proxy process in the path.

That is why a Service can look correct in the API (`kubectl get svc` shows an IP) and still drop every packet. The API object, the EndpointSlices and the kernel rules are three separate layers, and each can fail on its own.

---

## 2. The control loop behind a Service

```
                 ┌───────────────────────────── control plane ─────────────────────────────┐
  kubectl apply  │                                                                          │
  Service ──────▶│ kube-apiserver ── allocates ClusterIP (Service CIDR) and nodePort         │
                 │        │                                                                 │
                 │        ▼                                                                 │
                 │ kube-controller-manager: EndpointSlice controller                        │
                 │   watches Service.spec.selector + Pods → writes EndpointSlices           │
                 │   (addresses, ready/serving/terminating, nodeName, zone)                 │
                 │                                                                          │
                 │ cloud-controller-manager (type: LoadBalancer only)                        │
                 │   provisions an external LB → writes status.loadBalancer.ingress         │
                 └──────────────────────────────────────────────────────────────────────────┘
                                   │ watch Services + EndpointSlices
                                   ▼
        ┌─────────────── every node ───────────────┐
        │ kube-proxy (or CNI kube-proxy replacement)│
        │   programs iptables / nftables / IPVS /   │
        │   eBPF: VIP:port → {PodIP:targetPort,...} │
        └───────────────────────────────────────────┘
```

Consequences for diagnosis:

1. **ClusterIP allocated, no endpoints** → a selector or readiness problem (EndpointSlice controller layer).
2. **Endpoints exist, traffic fails** → a data-path problem (kube-proxy/CNI layer), or the application does not listen on `targetPort`.
3. **`EXTERNAL-IP` stays `<pending>`** → no cloud controller or LB implementation (MetalLB, kube-vip, Cilium LB-IPAM, etc.) has claimed the Service.

EndpointSlices replaced the legacy `Endpoints` object as the source kube-proxy consumes. Each slice holds up to 100 endpoints by default (`--max-endpoints-per-slice` on kube-controller-manager), so a 5,000-Pod Service changes one slice per update instead of rewriting one very large object that is sent to every node.

---

## 3. Service types: technical comparison

| Type | Reachable from | Allocates | Data path | Typical use | Main trade-off |
|---|---|---|---|---|---|
| `ClusterIP` (default) | Inside the cluster | ClusterIP | DNAT on the client's node | East-west traffic between microservices | Not reachable from outside without a proxy or Ingress/Gateway |
| `ClusterIP` + `clusterIP: None` (headless) | Inside the cluster (DNS) | Nothing | None: DNS returns the Pod IPs | StatefulSets, client-side load balancing, gRPC | The client picks the backend; no kernel load balancing |
| `NodePort` | `<AnyNodeIP>:<nodePort>` | ClusterIP + nodePort (30000–32767) | DNAT on the receiving node, possibly SNAT + a second hop | Bare metal, an external LB you manage yourself | Awkward port range; exposes every node; SNAT hides the client IP under the `Cluster` policy |
| `LoadBalancer` | External VIP | ClusterIP + nodePort (optional) + external IP | Cloud/LB → node → Pod (or LB → Pod directly, depending on implementation) | Production north-south L4 | Cost per LB, provider dependence, extra hop |
| `ExternalName` | Inside the cluster (DNS) | Nothing | None: a DNS CNAME | Aliasing an external database or SaaS | No ports, no proxying, no health checking; breaks TLS SNI/Host expectations |
| Selector-less + manual EndpointSlice | Inside the cluster | ClusterIP | DNAT to IPs you declare | Legacy VMs, external databases with a stable in-cluster name | Nothing checks those IPs; you own their lifecycle |

The types nest: **every `LoadBalancer` is also a `NodePort` (unless `allocateLoadBalancerNodePorts: false`), and every `NodePort` is also a `ClusterIP`.**

---

## 4. Anatomy of the ports

```
client ──▶ ClusterIP:port ──┐
client ──▶ NodeIP:nodePort ─┼──▶ DNAT ──▶ PodIP:targetPort ──▶ containerPort (the process listening)
client ──▶ LB-IP:port ──────┘
```

| Field | Meaning | Common mistake |
|---|---|---|
| `port` | Port exposed on the ClusterIP / LB | Assuming it must match the container port |
| `targetPort` | Port on the Pod; a number **or a named port** | Pointing at a port nothing listens on → `Connection refused` |
| `nodePort` | Port opened on every node | Hard-coding a value in the dynamic band and colliding with another Service |
| `protocol` | `TCP` (default), `UDP`, `SCTP` | Forgetting `UDP` for DNS/syslog; TCP and UDP on the same port need two entries |
| `name` | Required when there is more than one port | Omitting it on multi-port Services → the API rejects the object |
| `appProtocol` | L7 hint (`http`, `kubernetes.io/h2c`, `kubernetes.io/ws`) | Assuming kube-proxy uses it (it doesn't; LBs and meshes do) |

**Named `targetPort`s let you decouple.** If `targetPort: http` and the Pod template declares `containerPort: 8080, name: http`, you can later move the app to 9090 by changing only the Pod template. During a rolling update, old and new Pods can even listen on different numbers, because each endpoint is resolved per Pod.

---

## 5. Complete manifests

All the examples use the `shop` namespace and `agnhost netexec`, an official Kubernetes e2e image whose `/hostname` endpoint returns the Pod name and whose `/clientip` endpoint returns the source address it sees. Both are useful for checking load balancing and source-IP preservation.

### 5.1 Namespace and backend Deployment

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout
        app.kubernetes.io/version: "1.4.2"
    spec:
      containers:
        - name: app
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
            - --udp-port=5353
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: udp-echo
              containerPort: 5353
              protocol: UDP
          readinessProbe:
            httpGet:
              path: /hostname
              port: http
            periodSeconds: 5
            failureThreshold: 2
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: checkout
```

Note that the Service selector must match **Pod** labels (`spec.template.metadata.labels`), not the Deployment's labels. Adding `app.kubernetes.io/version` to the selector is a classic outage: at the next version bump the Service loses every endpoint.

### 5.2 Multi-port ClusterIP (TCP + UDP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: shop
  labels:
    app.kubernetes.io/name: checkout
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
      appProtocol: http
    - name: udp-echo
      port: 53
      targetPort: udp-echo
      protocol: UDP
```

### 5.3 ClusterIP with a static IP and dual-stack

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-stable
  namespace: shop
spec:
  type: ClusterIP
  clusterIP: 10.96.0.40
  ipFamilyPolicy: PreferDualStack
  ipFamilies:
    - IPv4
    - IPv6
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
```

- `clusterIP` must fall inside the Service CIDR (`--service-cluster-ip-range` on kube-apiserver, or a `ServiceCIDR` object on clusters that use multiple Service CIDRs). The apiserver reserves a **lower band** of the range for static assignments and allocates dynamic IPs from the upper band first, so a manually chosen low IP (for example, the one kube-dns uses) rarely collides with an automatic allocation.
- `ipFamilyPolicy`: `SingleStack` (default), `PreferDualStack` (dual-stack if the cluster supports it, otherwise single-stack without an error), `RequireDualStack` (fails if the cluster is not dual-stack). The first family in `ipFamilies` becomes the primary `spec.clusterIP`.
- `spec.clusterIP` and `ipFamilies[0]` are **immutable**. To change them you delete and recreate the Service, which causes a brief outage and a new IP for every client that did not use DNS.

### 5.4 NodePort with a pinned port and preserved source IP

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-np
  namespace: shop
spec:
  type: NodePort
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
      protocol: TCP
```

The same banding applies to the NodePort range: the lower part of `--service-node-port-range` (30000–32767 by default) is preferred for static assignments such as `30080`, and dynamic allocation fills the upper part first.

### 5.5 Production LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-lb
  namespace: shop
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  loadBalancerClass: service.k8s.aws/nlb
  externalTrafficPolicy: Local
  allocateLoadBalancerNodePorts: false
  loadBalancerSourceRanges:
    - 203.0.113.0/24
    - 198.51.100.17/32
  ipFamilyPolicy: SingleStack
  ipFamilies:
    - IPv4
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

| Field | Effect | When to use it |
|---|---|---|
| `loadBalancerClass` | Chooses which LB implementation reconciles the Service; the cloud provider's default controller ignores Services whose class it does not own | Several LB implementations in one cluster (for example, cloud NLB plus MetalLB) |
| `allocateLoadBalancerNodePorts: false` | No nodePort is allocated | Only when the LB routes **directly to Pod IPs** (IP target mode, BGP to Pods). With instance-style LBs, traffic has nowhere to land |
| `loadBalancerSourceRanges` | Client allowlist, enforced by the provider or by kube-proxy | Admin endpoints, partner access |
| `externalTrafficPolicy: Local` | Preserves the client IP and avoids the second hop | See section 6 |
| Annotations | Provider-specific; not portable | Always check your provider's documentation |

**On bare metal**, the equivalent without a cloud (MetalLB in L2 mode, for example) is:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-lb-metal
  namespace: shop
  annotations:
    metallb.universe.tf/address-pool: public-pool
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
```

`status.loadBalancer.ingress[].ipMode` (`VIP` or `Proxy`) tells kube-proxy whether the LB delivers packets with the VIP as the destination (`VIP`, so kube-proxy short-circuits in-cluster traffic to the VIP) or rewrites it to the node (`Proxy`, so in-cluster clients go out through the real LB, which is needed when the LB does TLS termination or PROXY protocol).

### 5.6 Headless Service (for StatefulSets)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ledger
  namespace: shop
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app.kubernetes.io/name: ledger
  ports:
    - name: tcp-db
      port: 5432
      targetPort: 5432
```

DNS returns one A/AAAA record per Pod, plus `<pod>.ledger.shop.svc.cluster.local` when the StatefulSet's `serviceName` points at this Service. `publishNotReadyAddresses: true` is what quorum systems (etcd, ZooKeeper, Cassandra) need to find their peers **before** they are ready. Do not use it on Services that clients consume.

### 5.7 ExternalName

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-db
  namespace: shop
spec:
  type: ExternalName
  externalName: payments.prod.db.example.com
```

CoreDNS answers `payments-db.shop.svc.cluster.local` with a CNAME. It does not accept IPs (use 5.8 for that), does not remap ports, and the client still sends its original name in TLS SNI and the HTTP `Host` header, so a certificate for `payments.prod.db.example.com` will not validate if the client connects with the internal name.

### 5.8 Selector-less Service with a manual EndpointSlice

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-inventory
  namespace: shop
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 8443
      protocol: TCP
```

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-inventory-1
  namespace: shop
  labels:
    kubernetes.io/service-name: legacy-inventory
    endpointslice.kubernetes.io/managed-by: platform-team.example.com
addressType: IPv4
ports:
  - name: http
    port: 8443
    protocol: TCP
endpoints:
  - addresses:
      - 10.20.4.11
    conditions:
      ready: true
  - addresses:
      - 10.20.4.12
    conditions:
      ready: true
```

- `kubernetes.io/service-name` links the slice to the Service.
- `managed-by` must **not** be `endpointslice-controller.k8s.io`, or the controller will treat the slice as its own and delete it.
- `ports[].name` must match the Service's port name. `port` is the real destination (the equivalent of `targetPort`).
- The API rejects loopback and link-local addresses (`127.0.0.0/8`, `169.254.0.0/16`) as endpoints.

### 5.9 Session affinity and internal traffic policies

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout-sticky
  namespace: shop
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 1800
  internalTrafficPolicy: Cluster
  trafficDistribution: PreferClose
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - name: http
      port: 80
      targetPort: http
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: node-agent
  namespace: monitoring
spec:
  type: ClusterIP
  internalTrafficPolicy: Local
  selector:
    app.kubernetes.io/name: node-agent
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
      appProtocol: grpc
```

---

## 6. Traffic policies: the real trade-offs

### 6.1 `externalTrafficPolicy` (NodePort / LoadBalancer traffic)

```
Cluster (default)                              Local
 client 198.51.100.7                            client 198.51.100.7
   │                                              │
   ▼                                              ▼
 node-a:30080 (no local Pod)                    node-b:30080 (has a local Pod)
   │ DNAT + SNAT to node-a's IP                   │ DNAT only, no SNAT
   ▼                                              ▼
 Pod on node-b  sees src = node-a IP            Pod on node-b  sees src = 198.51.100.7
                                                node-a: no local Pod → DROP
                                                (LB health check marks node-a unhealthy)
```

| Aspect | `Cluster` | `Local` |
|---|---|---|
| Client source IP | Lost (SNAT to the node IP) | **Preserved** |
| Extra hop | Possible (node → other node) | No |
| Spread | Even across Pods | Even across **nodes**; a node with 1 Pod and a node with 10 Pods receive the same share from the LB |
| Nodes without Pods | Forward the traffic | Drop it; the LB must stop sending to them |
| LB health check | Standard | kube-proxy serves `healthCheckNodePort` → `/healthz` returns 200 only if the node has local endpoints |
| Rollout risk | Low | Needs `topologySpreadConstraints` and draining; a node whose last Pod is terminating becomes a black hole until the LB notices |

With `type: LoadBalancer` and `Local`, the apiserver allocates `spec.healthCheckNodePort`. Since v1.28, kube-proxy also uses `terminating` + `serving` endpoints as a fallback when there are no `ready` local endpoints, so connections in flight during a graceful shutdown do not fail. This behaviour was previously the `ProxyTerminatingEndpoints` feature gate.

### 6.2 `internalTrafficPolicy` (ClusterIP traffic from inside the cluster)

- `Cluster`: any ready endpoint in the cluster.
- `Local`: **only** endpoints on the same node as the client. There is no fallback: if none exist, the packet is dropped. That is correct for per-node agents (DaemonSets: log/trace collectors, node-local DNS caches) and wrong for everything else.

### 6.3 `trafficDistribution`: topology preference with fallback

`trafficDistribution: PreferClose` (GA in v1.33) asks the data path to prefer endpoints in the client's zone, **with fallback to the whole cluster** when the zone has none. The EndpointSlice controller writes `hints.forZones` into each endpoint, and kube-proxy filters on them. v1.34 added `PreferSameZone` (the explicit name for `PreferClose`) and `PreferSameNode` (same node first, then any node). Check your cluster version before using them.

| Mechanism | Scope | Fallback | Main use |
|---|---|---|---|
| `internalTrafficPolicy: Local` | Node | **None** (drop) | DaemonSets |
| `externalTrafficPolicy: Local` | Node (external traffic) | None (the LB routes around it) | Client IP preservation |
| `trafficDistribution: PreferClose` | Zone | Yes | Cutting cross-AZ cost and latency |
| Annotation `service.kubernetes.io/topology-mode: Auto` | Zone, proportional to CPU per zone | Yes, but the controller withholds hints when the distribution is too uneven | The predecessor; still supported |

Trade-off: `PreferClose` can overload a zone with few replicas, because it does not balance by capacity. Pair it with zone-level `topologySpreadConstraints` and an HPA.

### 6.4 `sessionAffinity: ClientIP`

- Pins by **source IP**, not by cookie. Behind SNAT (`externalTrafficPolicy: Cluster`, corporate NAT, a proxy) thousands of clients share one IP and land on a single Pod.
- `timeoutSeconds` defaults to 10800 (3 h) and has a maximum of 86400.
- In iptables mode it uses the `recent` module; in IPVS it uses persistence; in nftables it uses per-endpoint sets with timeouts.
- For real stickiness use L7: cookies in an Ingress/Gateway, or consistent hashing in a mesh.

---

## 7. How kube-proxy programs the data path

| Mode | Mechanism | Load balancing | Scale | State |
|---|---|---|---|---|
| `iptables` | NAT chains `KUBE-SERVICES → KUBE-SVC-* → KUBE-SEP-*` | Random with `statistic --probability` | Service lookup is O(n); full reloads with `iptables-restore`, slow at tens of thousands of rules | Default on Linux, very mature |
| `ipvs` | Kernel L4 LB (hash tables) + `kube-ipvs0` dummy interface + ipset | rr, lc, sh, etc. | O(1) lookup | The Kubernetes project deprecated it in v1.35 in favour of `nftables`; plan a migration |
| `nftables` | Table `ip kube-proxy` / `ip6 kube-proxy`, verdict maps | `numgen random mod N vmap` | O(1) lookup, incremental updates | GA in v1.33; the recommended mode on modern kernels (≥ 5.13) |
| eBPF replacement (Cilium, Calico eBPF) | BPF maps at the socket or tc level | Maglev/random, DSR | Very high | Outside kube-proxy; `kube-proxy` is not running at all |

Useful check: `kubectl -n kube-system get ds kube-proxy`. If it does not exist, the CNI is the data path, and `iptables-save | grep KUBE` will show nothing, which is normal. Use the CNI's tooling (`cilium service list`, `cilium-dbg bpf lb list`).

---

## 8. Hands-on walkthrough with real output

### 8.1 Create and check the objects

```
$ kubectl apply -f ns.yaml -f checkout-deploy.yaml -f checkout-svc.yaml
namespace/shop created
deployment.apps/checkout created
service/checkout created

$ kubectl -n shop rollout status deploy/checkout
deployment "checkout" successfully rolled out

$ kubectl -n shop get svc checkout -o wide
NAME       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)         AGE   SELECTOR
checkout   ClusterIP   10.96.14.20    <none>        80/TCP,53/UDP   21s   app.kubernetes.io/name=checkout

$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=checkout
NAME             ADDRESSTYPE   PORTS       ENDPOINTS                            AGE
checkout-7xk2p   IPv4          8080,5353   10.244.1.12,10.244.2.8,10.244.3.15   21s
```

Look at the conditions for each endpoint:

```
$ kubectl -n shop get endpointslice checkout-7xk2p \
    -o jsonpath='{range .endpoints[*]}{.addresses[0]}{"\t"}{.nodeName}{"\t"}{.conditions}{"\n"}{end}'
10.244.1.12	worker-1	{"ready":true,"serving":true,"terminating":false}
10.244.2.8	worker-2	{"ready":true,"serving":true,"terminating":false}
10.244.3.15	worker-3	{"ready":true,"serving":true,"terminating":false}
```

### 8.2 Test from inside the cluster

```
$ kubectl -n shop run probe --rm -it --restart=Never \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- \
    sh -c 'for i in 1 2 3 4 5 6; do wget -qO- http://checkout/hostname; echo; done'
checkout-6d9c7f8b5-qm4xz
checkout-6d9c7f8b5-2hrtl
checkout-6d9c7f8b5-qm4xz
checkout-6d9c7f8b5-v8d7n
checkout-6d9c7f8b5-2hrtl
checkout-6d9c7f8b5-v8d7n
pod "probe" deleted
```

The distribution is **random per connection**, not round-robin. Keep in mind that HTTP/2 or gRPC with long-lived connections pins all requests to one Pod. That is L4 behaviour, not a bug.

Check DNS resolution:

```
$ kubectl -n shop run dns --rm -it --restart=Never \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- \
    nslookup checkout.shop.svc.cluster.local
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	checkout.shop.svc.cluster.local
Address: 10.96.14.20
pod "dns" deleted
```

### 8.3 Inspect the rules on the node (iptables mode)

```
$ sudo iptables-save -t nat | grep 'shop/checkout:http'
-A KUBE-SERVICES -d 10.96.14.20/32 -p tcp -m comment --comment "shop/checkout:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-5QZRL2XUYVHJ3WQK
-A KUBE-SVC-5QZRL2XUYVHJ3WQK ! -s 10.244.0.0/16 -d 10.96.14.20/32 -p tcp -m comment --comment "shop/checkout:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-5QZRL2XUYVHJ3WQK -m comment --comment "shop/checkout:http -> 10.244.1.12:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-AOVKHS7PGR3QPYVG
-A KUBE-SVC-5QZRL2XUYVHJ3WQK -m comment --comment "shop/checkout:http -> 10.244.2.8:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-L3JGX5TQO4D2WQRM
-A KUBE-SVC-5QZRL2XUYVHJ3WQK -m comment --comment "shop/checkout:http -> 10.244.3.15:8080" -j KUBE-SEP-QX6FQB2ZE7MJKD4N
-A KUBE-SEP-AOVKHS7PGR3QPYVG -p tcp -m comment --comment "shop/checkout:http" -m tcp -j DNAT --to-destination 10.244.1.12:8080
```

How to read it: the probabilities are cascading (1/3, then 1/2 of the remainder, then the rest), which gives a uniform distribution. `KUBE-MARK-MASQ` marks traffic that does not come from the Pod CIDR so that it gets SNAT on the way out.

### 8.4 Inspect the rules on the node (nftables mode)

```
$ sudo nft list chain ip kube-proxy service-5QZRL2XU-shop/checkout/tcp/http
table ip kube-proxy {
	chain service-5QZRL2XU-shop/checkout/tcp/http {
		ip daddr 10.96.14.20 tcp dport 80 ip saddr != 10.244.0.0/16 jump mark-for-masquerade
		numgen random mod 3 vmap { 0 : goto endpoint-AOVKHS7P-shop/checkout/tcp/http__10.244.1.12/8080, 1 : goto endpoint-L3JGX5TQ-shop/checkout/tcp/http__10.244.2.8/8080, 2 : goto endpoint-QX6FQB2Z-shop/checkout/tcp/http__10.244.3.15/8080 }
	}
}

$ sudo nft list map ip kube-proxy service-ips | grep 10.96.14.20
		10.96.14.20 . tcp . 80 : goto service-5QZRL2XU-shop/checkout/tcp/http,
		10.96.14.20 . udp . 53 : goto service-4MPLC7NR-shop/checkout/udp/udp-echo,
```

### 8.5 Inspect IPVS (if applicable)

```
$ sudo ipvsadm -Ln -t 10.96.14.20:80
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.14.20:80 rr
  -> 10.244.1.12:8080             Masq    1      0          2
  -> 10.244.2.8:8080              Masq    1      0          2
  -> 10.244.3.15:8080             Masq    1      0          2

$ ip -brief addr show kube-ipvs0 | tr ' ' '\n' | grep 10.96.14.20
10.96.14.20/32
```

In IPVS mode the ClusterIP **is** assigned to the `kube-ipvs0` interface on every node. It is the only mode where that happens.

### 8.6 NodePort and source-IP preservation

```
$ kubectl apply -f checkout-np.yaml
service/checkout-np created

$ kubectl -n shop get svc checkout-np
NAME          TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
checkout-np   NodePort   10.96.201.7    <none>        80:30080/TCP   5s

$ kubectl get nodes -o wide | awk '{print $1, $6}'
NAME INTERNAL-IP
cp-1 192.168.10.10
worker-1 192.168.10.11
worker-2 192.168.10.12
worker-3 192.168.10.13

$ curl -s http://192.168.10.11:30080/clientip
192.168.10.250:51734
```

`externalTrafficPolicy: Local` preserves the real client IP (`192.168.10.250`). Change it to `Cluster` and repeat against a node that has **no** local Pod:

```
$ kubectl -n shop patch svc checkout-np -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
service/checkout-np patched

$ kubectl -n shop scale deploy/checkout --replicas=1
deployment.apps/checkout scaled

$ kubectl -n shop get pod -l app.kubernetes.io/name=checkout -o wide | awk '{print $1, $7}'
NAME NODE
checkout-6d9c7f8b5-v8d7n worker-3

$ curl -s http://192.168.10.11:30080/clientip
10.244.1.0:48212
```

The Pod now sees worker-1's address (SNAT). Switch back to `Local` and repeat against worker-1:

```
$ kubectl -n shop patch svc checkout-np -p '{"spec":{"externalTrafficPolicy":"Local"}}'
service/checkout-np patched

$ curl -s --max-time 3 http://192.168.10.11:30080/clientip
curl: (28) Connection timed out after 3001 milliseconds

$ curl -s http://192.168.10.13:30080/clientip
192.168.10.250:51790
```

A silent drop, not a `RST`. That is the expected behaviour and exactly what a failing LB health check protects you from.

### 8.7 LoadBalancer health check with `Local`

```
$ kubectl -n shop get svc checkout-lb -o jsonpath='{.spec.healthCheckNodePort}{"\n"}'
31492

$ curl -s http://192.168.10.13:31492/healthz
{
  "service": {
    "namespace": "shop",
    "name": "checkout-lb"
  },
  "localEndpoints": 1,
  "serviceProxyHealthy": true
}

$ curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.11:31492/healthz
503
```

### 8.8 Conntrack: the state that outlives the rules

```
$ sudo conntrack -L -d 10.96.14.20 -p tcp 2>/dev/null | head -3
tcp      6 86397 ESTABLISHED src=10.244.2.30 dst=10.96.14.20 sport=40218 dport=80 src=10.244.3.15 dst=10.244.2.30 sport=8080 dport=40218 [ASSURED] mark=0 use=1
tcp      6 117 TIME_WAIT src=10.244.2.30 dst=10.96.14.20 sport=40196 dport=80 src=10.244.1.12 dst=10.244.2.30 sport=8080 dport=40196 [ASSURED] mark=0 use=1

$ sudo conntrack -L -p udp --orig-dst 10.96.14.20 --orig-port-dst 53
udp      17 27 src=10.244.2.30 dst=10.96.14.20 sport=39011 dport=53 src=10.244.1.12 dst=10.244.2.30 sport=5353 dport=39011 mark=0 use=1
conntrack v1.4.8 (conntrack-tools): 1 flow entries have been shown.
```

The **reply** tuple shows which Pod the NAT actually picked. UDP has no teardown, so an entry pointing at a dead Pod black-holes the flow until it expires. kube-proxy deletes the stale UDP entries when an endpoint disappears. If you see UDP loss after a rollout, this is the first suspect:

```
$ sudo conntrack -D -p udp --orig-dst 10.96.14.20 --orig-port-dst 53
conntrack v1.4.8 (conntrack-tools): 1 flow entries have been deleted.
```

---

## 9. Troubleshooting guide

### 9.1 Decision flow

```
Service not responding
│
├─ 1. Does it resolve?  nslookup <svc>.<ns>.svc.cluster.local
│     └─ NXDOMAIN → wrong name/namespace, CoreDNS down, bad search path in resolv.conf
│
├─ 2. Does it have endpoints?  kubectl get endpointslices -l kubernetes.io/service-name=<svc>
│     ├─ ENDPOINTS <unset> → selector ≠ Pod labels, or the Pods are in another namespace
│     └─ all ready=false  → readinessProbe failing (kubectl describe pod)
│
├─ 3. Does the Pod answer directly?  curl <PodIP>:<targetPort>
│     ├─ Connection refused → targetPort wrong, or the app listens on 127.0.0.1
│     └─ Timeout            → NetworkPolicy, or CNI routing between nodes
│
├─ 4. Does the ClusterIP answer from a Pod?
│     └─ No, but 3 works → kube-proxy/CNI: logs, mode, rules (iptables/nft/ipvs)
│
└─ 5. Does it answer from outside (NodePort/LB)?
      ├─ EXTERNAL-IP <pending> → no LB controller / wrong loadBalancerClass
      ├─ Some nodes fail       → externalTrafficPolicy: Local with no local Pod
      ├─ Everything fails      → firewall/security group on the nodePort, loadBalancerSourceRanges
      └─ Wrong client IP       → externalTrafficPolicy: Cluster (SNAT)
```

### 9.2 Diagnostic commands

```
$ kubectl -n shop get svc checkout -o jsonpath='{.spec.selector}{"\n"}'
{"app.kubernetes.io/name":"checkout"}

$ kubectl -n shop get pods -l app.kubernetes.io/name=checkout --show-labels
NAME                       READY   STATUS    RESTARTS   AGE   LABELS
checkout-6d9c7f8b5-2hrtl   1/1     Running   0          12m   app.kubernetes.io/name=checkout,app.kubernetes.io/version=1.4.2,pod-template-hash=6d9c7f8b5
```

The classic failure case:

```
$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=checkout-broken
NAME                    ADDRESSTYPE   PORTS     ENDPOINTS   AGE
checkout-broken-p9w4d   IPv4          <unset>   <unset>     3m

$ kubectl -n shop describe svc checkout-broken | grep -E 'Selector|Endpoints'
Selector:          app=checkout
Endpoints:         <none>
```

Check what the app actually listens on:

```
$ kubectl -n shop exec deploy/checkout -- netstat -tlnp 2>/dev/null || \
  kubectl debug -n shop -it deploy/checkout --image=nicolaka/netshoot --target=app -- ss -tlnp
State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096                 *:8080              *:*      users:(("agnhost",pid=1,fd=3))
```

If you see `127.0.0.1:8080`, the app only accepts local connections, and no Service will ever reach it.

kube-proxy state:

```
$ kubectl -n kube-system get ds kube-proxy
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kube-proxy   4         4         4       4            4           kubernetes.io/os=linux   41d

$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode|clusterCIDR'
clusterCIDR: 10.244.0.0/16
mode: nftables

$ kubectl -n kube-system logs ds/kube-proxy --tail=20 | grep -iE 'error|fail|sync'
I0930 10:14:02.118231       1 proxier.go:809] "SyncProxyRules complete" ipFamily="IPv4" elapsed="21.4ms"

$ curl -s http://127.0.0.1:10256/healthz
{"lastUpdated": "2026-09-30 10:14:02.118 +0000 UTC","currentTime": "2026-09-30 10:14:05.491 +0000 UTC", "nodeEligible": true}
```

(Port `10256` is kube-proxy's healthz endpoint, run on the node itself.)

Recent events on the Service (useful for LB and allocation problems):

```
$ kubectl -n shop get events --field-selector involvedObject.name=checkout-lb --sort-by=.lastTimestamp
LAST SEEN   TYPE      REASON                   OBJECT                MESSAGE
2m          Normal    EnsuringLoadBalancer     service/checkout-lb   Ensuring load balancer
90s         Warning   SyncLoadBalancerFailed   service/checkout-lb   Error syncing load balancer: failed to ensure load balancer: ...
```

### 9.3 Symptom → cause → fix table

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `Connection refused` to the ClusterIP | No endpoints (kube-proxy installs a REJECT) or wrong `targetPort` | `get endpointslices` | Fix the selector or targetPort |
| Timeout to the ClusterIP, the Pod IP works | Stale kube-proxy rules, kube-proxy down, conflict with another data path | `nft list ...` / `iptables-save`, kube-proxy logs | Restart kube-proxy; avoid two data paths (kube-proxy + CNI replacement) |
| Intermittent: 1 in N requests fails | One Pod `Ready` but broken (the probe does not test the real path) | `curl` to each endpoint individually | Make the readinessProbe test what the Service serves |
| Pod cannot reach itself through its own Service | Hairpin not enabled in the bridge/CNI | Test from another Pod | `hairpinMode` in kubelet/CNI |
| NodePort works on some nodes only | `externalTrafficPolicy: Local` | `.spec.externalTrafficPolicy`, Pods per node | Expected; use an LB with a health check or spread the Pods |
| NodePort does not answer on any node | Host firewall / security group; `nodePortAddresses` limits the IPs | `ss -lnt` does not help (there is no socket); check the rules | Open 30000–32767; check kube-proxy's `nodePortAddresses` |
| `EXTERNAL-IP <pending>` indefinitely | No LB controller, or unrecognised `loadBalancerClass` | Service events | Install/configure MetalLB, the cloud CCM, etc. |
| App logs show node IPs, not client IPs | SNAT from `externalTrafficPolicy: Cluster` | `/clientip` | `Local`, or PROXY protocol at the LB |
| Load skewed toward one Pod | `sessionAffinity: ClientIP` behind NAT, or long-lived gRPC connections | `.spec.sessionAffinity` | Remove the affinity; balance at L7 (mesh, client-side LB via headless) |
| UDP loss after a rollout | Stale conntrack entries | `conntrack -L -p udp` | `conntrack -D`; check that kube-proxy is up to date |
| `internalTrafficPolicy: Local` returns nothing on some nodes | No local Pod on that node | Pods per node | Use a DaemonSet, or go back to `Cluster` |
| `spec.clusterIP: Invalid value ... provided IP is already allocated` | Static IP collision | `kubectl get ipaddresses` (MultiCIDR API) | Use the static band of the range, or choose another IP |
| `provided port is already allocated` | nodePort collision | `kubectl get svc -A \| grep <port>` | Choose another port in the static band |

---

## 10. Production and exam guidance

**In production:**

- **Selectors should use stable labels only** (`app.kubernetes.io/name`, `component`). Never the version, the hash or the environment when those change during a rollout.
- **Name the ports** and use named `targetPort`s. It is required for multi-port Services, and it is what makes port migrations possible without touching the Service.
- **The readinessProbe is the Service's contract.** It must test the same path and port that clients use. A probe on `/healthz` of an admin sidecar lets a broken backend into the pool.
- **Graceful shutdown:** a `preStop` of a few seconds (`sleep 5`) covers the propagation delay of EndpointSlices to every node. Without it, some kube-proxies keep sending new connections to a Pod that has already closed its socket.
- **`externalTrafficPolicy: Local` + `topologySpreadConstraints` + a PodDisruptionBudget** is the minimum combination for exposing workloads that need the client IP.
- **A single data path.** If the CNI replaces kube-proxy, remove the kube-proxy DaemonSet, and clean up leftover rules with `kube-proxy --cleanup` when migrating.
- **Monitor** `kubeproxy_sync_proxy_rules_duration_seconds` and `kubeproxy_sync_proxy_rules_last_timestamp_seconds`. A kube-proxy that stops syncing leaves the node with stale rules without logging a single error per request.

**For the exam (hands-on, time-limited):**

```
$ kubectl -n shop expose deploy checkout --name=checkout-quick --port=80 --target-port=http --type=NodePort --dry-run=client -o yaml > svc.yaml
$ kubectl -n shop create service clusterip ledger --clusterip=None --tcp=5432:5432 --dry-run=client -o yaml
$ kubectl -n shop create service externalname payments-db --external-name=payments.prod.db.example.com
$ kubectl explain service.spec.externalTrafficPolicy
$ kubectl explain service.spec.trafficDistribution
```

- `kubectl expose` copies the Deployment's selector. Check it; if the Deployment's `matchLabels` include too many labels, the Service will inherit them.
- `kubectl create service` generates the selector `app=<name>`, which almost never matches. Edit it before applying.
- Always check the chain: **Service → EndpointSlice → Pod → port**, in that order.

---

## References

- CNCF / Linux Foundation — Certified Kubernetes Network Engineer (CKNE): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes — Service: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Virtual IPs and Service Proxies (kube-proxy modes: iptables, IPVS, nftables; session affinity): https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes — Service ClusterIP allocation (static/dynamic bands): https://kubernetes.io/docs/concepts/services-networking/cluster-ip-allocation/
- Kubernetes — EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Kubernetes — Service Internal Traffic Policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Kubernetes — Topology Aware Routing: https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/
- Kubernetes — IPv4/IPv6 dual-stack: https://kubernetes.io/docs/concepts/services-networking/dual-stack/
- Kubernetes — Create an External Load Balancer: https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/
- Kubernetes — Using Source IP: https://kubernetes.io/docs/tutorials/services/source-ip/
- Kubernetes — Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes — DNS for Services and Pods: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes API reference — Service v1: https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/
- Kubernetes API reference — EndpointSlice v1: https://kubernetes.io/docs/reference/kubernetes-api/service-resources/endpoint-slice-v1/
- Kubernetes — kube-proxy command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Kubernetes — kube-proxy configuration (v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/