# 3.4 Implementing Cross-Cluster Service Discovery and Load Balancing

> **Exam weight: 5.0%**. Expect tasks where you export a Service from one cluster and consume it from another. You may also have to explain why a `*.svc.clusterset.local` name does not resolve, pick the right topology for a given network constraint, or change a global service so it prefers local endpoints and fails over to remote ones.

---

## 1. Motivation: the production problem

A single Kubernetes cluster is a **failure domain**, a **blast radius** and a **scaling ceiling** all at once. Production platforms end up with many clusters for reasons that have little to do with Kubernetes itself:

| Driver | Typical shape |
|---|---|
| Availability | Active/active in two or more regions, so the loss of a region does not take the service down |
| Blast radius | A separate cluster per environment, tenant or business unit, so a bad CRD upgrade cannot take everything down |
| Data residency / compliance | EU data stays in EU clusters, PCI workloads in a hardened cluster |
| Scale limits | etcd size, API server QPS, the node count per cluster (the scalability SLO is 5,000 nodes), IP exhaustion |
| Migration | Blue/green *clusters* for Kubernetes version upgrades or a CNI swap |
| Edge / hybrid | On-prem clusters plus cloud clusters, sometimes with overlapping RFC1918 ranges |

Once you have N clusters, the in-cluster abstractions stop working:

- `ClusterIP` Services and `cluster.local` DNS are **scoped to one cluster**. Nothing in upstream Kubernetes lets a pod in `cluster-a` resolve `payments.prod.svc.cluster.local` to endpoints in `cluster-b`.
- EndpointSlices are produced by the local `EndpointSlice` controller from local pods only.
- kube-proxy, or the eBPF replacement, programs only the endpoints its own API server knows about.
- NetworkPolicy identities (labels, namespaces) mean nothing outside the cluster that assigned them.

The architectural question behind this topic is:

> *How does a client in cluster A discover a backend in cluster B, how do the packets physically get there, and who decides which cluster serves a given request?*

Those are three separate concerns, and every product in this space answers each one differently:

1. **Discovery plane**: how endpoint information (IPs, ports, health) from remote clusters becomes visible locally, as DNS records, EndpointSlices, a kvstore or xDS.
2. **Data plane connectivity**: how a packet from pod A reaches pod B. The options are a flat routable network, tunnels between gateway nodes, or L7/mTLS gateways.
3. **Load-balancing and policy plane**: how traffic is split between local and remote endpoints (locality preference, failover, weights, session affinity) and how it is authorized (identity across clusters).

Keep this three-plane model in mind. Most cross-cluster failures come from mixing up the planes, for example "DNS resolves, so the network must be fine".

---

## 2. Network topologies: the foundation you cannot skip

Before choosing a tool, pin down how the clusters are connected at L3.

| Topology | Description | Pod-to-pod reachability | Typical tools | Constraints |
|---|---|---|---|---|
| **Flat network** | Pod CIDRs are routable between clusters (same VPC, peered VPCs, BGP-advertised pod CIDRs) | Direct, no gateway | Cilium Cluster Mesh, Istio single-network, Linkerd pod-to-pod mode, GKE MCS | PodCIDRs **must not overlap**; routes and firewalls must allow pod↔pod |
| **Tunnel / gateway nodes** | Designated gateway nodes build encrypted tunnels (IPsec/WireGuard/VXLAN) between clusters | Via gateway nodes, L3 | Submariner | Overlapping CIDRs need Globalnet (NAT); watch MTU |
| **L7 gateway (east-west)** | A dedicated ingress-like gateway per cluster accepts mTLS traffic from other clusters | Via the gateway, L4/L7 with SNI routing | Istio multi-network, Linkerd gateway mode | Needs a shared trust root; the gateway becomes a critical hop |
| **Global LB / DNS only** | Nothing is connected internally; clients reach each cluster's ingress through GSLB | Client → ingress of the selected cluster | k8gb, ExternalDNS + cloud DNS, cloud GLBs | North-south only; failover is bounded by DNS TTL |

**Rules of thumb:**

- If you control IPAM end to end and can route pod CIDRs, a **flat network with Cilium Cluster Mesh** gives the lowest latency and identity-aware policy.
- If the CIDRs overlap, or the clusters sit behind NAT and firewalls you do not control, use **Submariner with Globalnet** (L3) or a **mesh with east-west gateways** (L7).
- If you only need north-south failover for public clients, **GSLB (k8gb/ExternalDNS)** is enough. Do not build a mesh just to solve a DNS problem.

---

## 3. Technology comparison

| Capability | MCS API (spec) | Cilium Cluster Mesh | Submariner + Lighthouse | Istio multicluster | Linkerd multicluster | k8gb (GSLB) |
|---|---|---|---|---|---|---|
| Layer | API contract (discovery) | L3/L4 (eBPF), optional L7 | L3 tunnels + DNS | L7 (Envoy) | L7 (linkerd2-proxy) | DNS |
| Discovery mechanism | `ServiceExport` → `ServiceImport` + EndpointSlices | etcd kvstore (clustermesh-apiserver), shared global services; MCS-API support in recent releases | Broker cluster syncs `ServiceExport`/`ServiceImport`/EndpointSlices; Lighthouse DNS | istiod watches remote API servers (remote secrets) → xDS | Service mirror controller creates mirrored Services | CoreDNS + Gslb CRD + delegated DNS zone |
| DNS name | `svc.ns.svc.clusterset.local` | Same `svc.ns.svc.cluster.local` (global service) or `clusterset.local` in MCS mode | `svc.ns.svc.clusterset.local` | Same `svc.ns.svc.cluster.local` | `svc-<cluster>.ns.svc.cluster.local` or `svc-federated` | `app.example.com` (public FQDN) |
| Overlapping PodCIDRs | Implementation-dependent | ❌ Not supported | ✅ With Globalnet | ✅ Multi-network via gateway | ✅ Gateway mode | ✅ (no pod connectivity) |
| Encryption | n/a | WireGuard/IPsec (optional) | IPsec (Libreswan) default, WireGuard | mTLS (mandatory in practice) | mTLS (automatic) | n/a |
| Locality / failover | Implementation-dependent | `service.cilium.io/affinity: local\|remote\|none` | Lighthouse prefers the local cluster | `localityLbSetting` + outlier detection | Federated services; failover via the `linkerd-failover` extension | `failover`, `roundRobin`, `geoip`, `weighted` |
| Cross-cluster identity policy | n/a | ✅ CiliumNetworkPolicy with `io.cilium.k8s.policy.cluster` | Plain NetworkPolicy, IP-based | ✅ AuthorizationPolicy (SPIFFE) | ✅ Server/AuthorizationPolicy (mTLS identity) | ❌ |
| Operational weight | Low (API only) | Medium | Medium (broker, gateways) | High | Medium | Low–medium |

The **MCS API** (KEP-1645) is the **vendor-neutral contract**. Submariner, GKE Multi-cluster Services and newer Cilium releases implement it. Istio and Linkerd have their own discovery models and do not consume `ServiceExport` natively in the default setup.

---

## 4. Kubernetes Multi-Cluster Services API (MCS, KEP-1645)

### 4.1 Core concepts

- **ClusterSet**: a group of clusters with a high degree of mutual trust that share services.
- **Namespace sameness**: a namespace with a given name means the same thing in every cluster of the ClusterSet. `prod/payments` in cluster A and `prod/payments` in cluster B are **the same service**, and their endpoints are merged. This is a hard design assumption. Violating it (for example, two teams owning `prod` in different clusters) leaks traffic.
- **ServiceExport**: created in the *exporting* cluster, with the **same name and namespace** as the Service. Its existence is the signal: "make this Service available to the ClusterSet".
- **ServiceImport**: created **by the MCS controller** (never by hand in normal operation) in every consuming cluster. It represents the ClusterSet-wide service.
- **EndpointSlices**: the implementation creates EndpointSlices for the imported service, labeled with the ServiceImport name and the source cluster.
- **DNS**: `<service>.<namespace>.svc.clusterset.local`.

The API group is `multicluster.x-k8s.io`, version `v1alpha1`. It is **not built into Kubernetes**. You install the CRDs from `kubernetes-sigs/mcs-api`, and an implementation (controller + DNS) does the actual work.

### 4.2 Lifecycle

```
cluster-a (exporter)                         cluster-b (consumer)
────────────────────                         ─────────────────────
Service prod/payments
ServiceExport prod/payments   ──►  MCS controller  ──►  ServiceImport prod/payments
EndpointSlices (local pods)   ──►  (aggregates)    ──►  EndpointSlices labeled
                                                         multicluster.kubernetes.io/service-name=payments
                                                         multicluster.kubernetes.io/source-cluster=cluster-a
                                                     DNS: payments.prod.svc.clusterset.local
                                                          → ClusterSetIP (or pod IPs if Headless)
```

If `prod/payments` is exported from **both** clusters, the ServiceImport in each cluster aggregates the endpoints of both. Clients in either cluster then load-balance across the whole ClusterSet.

### 4.3 Installing the CRDs

```
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/master/config/crd/multicluster.x-k8s.io_serviceexports.yaml
customresourcedefinition.apiextensions.k8s.io/serviceexports.multicluster.x-k8s.io created
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/mcs-api/master/config/crd/multicluster.x-k8s.io_serviceimports.yaml
customresourcedefinition.apiextensions.k8s.io/serviceimports.multicluster.x-k8s.io created

$ kubectl api-resources --api-group=multicluster.x-k8s.io
NAME             SHORTNAMES      APIVERSION                       NAMESPACED   KIND
serviceexports   svcex,svcexport multicluster.x-k8s.io/v1alpha1   true         ServiceExport
serviceimports   svcim,svcimport multicluster.x-k8s.io/v1alpha1   true         ServiceImport
```

Most implementations (Submariner, Cilium in MCS mode, GKE) install these CRDs for you. Check before applying them a second time with a different version.

### 4.4 Cluster identity: ClusterProperty (KEP-2149)

Each cluster needs a stable, unique ID inside the ClusterSet. KEP-2149 defines the `ClusterProperty` CRD for that:

```yaml
apiVersion: about.k8s.io/v1alpha1
kind: ClusterProperty
metadata:
  name: cluster.clusterset.k8s.io
spec:
  value: cluster-a
---
apiVersion: about.k8s.io/v1alpha1
kind: ClusterProperty
metadata:
  name: clusterset.k8s.io
spec:
  value: prod-clusterset
```

The `cluster.clusterset.k8s.io` value is what appears in the `multicluster.kubernetes.io/source-cluster` label and in per-pod headless DNS names. It must be a valid DNS label and unique in the ClusterSet.

### 4.5 A complete exporting workload

Apply this in **cluster-a** (and, for an active/active service, in cluster-b as well):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments
  namespace: prod
  labels:
    app: payments
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payments
  template:
    metadata:
      labels:
        app: payments
    spec:
      containers:
        - name: payments
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payments
  namespace: prod
spec:
  type: ClusterIP
  selector:
    app: payments
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
---
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: payments
  namespace: prod
```

`ServiceExport` has no `spec`. Its name and namespace are the whole contract.

### 4.6 What the consumer sees

The controller creates this ServiceImport in cluster-b (read-only for you):

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceImport
metadata:
  name: payments
  namespace: prod
spec:
  type: ClusterSetIP
  ips:
    - 10.112.4.21
  ports:
    - name: http
      port: 80
      protocol: TCP
  sessionAffinity: None
```

| `spec.type` | Meaning | DNS answer |
|---|---|---|
| `ClusterSetIP` | One virtual IP for the ClusterSet-wide service; the local dataplane load-balances across all imported endpoints | A/AAAA → ClusterSetIP |
| `Headless` | No VIP; clients get the endpoint IPs directly (StatefulSets, client-side load balancing) | A/AAAA → pod IPs from all clusters; per-pod records |

Headless per-pod records include the cluster ID, so pods with the same hostname in different clusters do not collide:

```
<hostname>.<clusterid>.<service>.<namespace>.svc.clusterset.local
db-0.cluster-a.cassandra.data.svc.clusterset.local
db-0.cluster-b.cassandra.data.svc.clusterset.local
```

### 4.7 Checking export status and conflicts

```
$ kubectl --context cluster-a -n prod get serviceexport payments -o yaml | yq '.status'
conditions:
  - lastTransitionTime: "2026-09-30T10:14:02Z"
    message: ""
    reason: ""
    status: "True"
    type: Valid
  - lastTransitionTime: "2026-09-30T10:14:03Z"
    message: ""
    reason: NoConflicts
    status: "False"
    type: Conflict
```

The spec handles **conflicts** between exporting clusters. If cluster-a exports port `80/TCP` named `http` and cluster-b exports port `80/TCP` named `web`, or with a different protocol, the implementation resolves the difference by giving precedence to the **oldest export**. It also sets `Conflict=True` on the ServiceExports that lost. A `Valid=False` condition means the export itself is unusable, for example because the matching Service does not exist or is of an unsupported type (such as `ExternalName`).

```
$ kubectl --context cluster-b -n prod get endpointslices \
    -l multicluster.kubernetes.io/service-name=payments \
    -L multicluster.kubernetes.io/source-cluster
NAME                          ADDRESSTYPE   PORTS   ENDPOINTS                            AGE   SOURCE-CLUSTER
payments-cluster-a-7x2lq      IPv4          8080    10.10.1.14,10.10.2.9,10.10.3.22      4m    cluster-a
payments-cluster-b-kd9fp      IPv4          8080    10.20.1.5,10.20.2.17,10.20.1.33      4m    cluster-b
```

### 4.8 DNS: making `clusterset.local` resolve

Something has to answer for `clusterset.local`. The options:

- The implementation ships its own DNS server (Submariner Lighthouse, or GKE via Cloud DNS). CoreDNS **forwards** the zone to it.
- The **CoreDNS `multicluster` plugin** (an external plugin, compiled in) answers from `ServiceImport` and EndpointSlice objects directly.

A Corefile using the multicluster plugin (it requires a CoreDNS build that includes the plugin, and RBAC to read `serviceimports`):

```
.:53 {
    errors
    health {
        lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }
    multicluster clusterset.local
    prometheus :9153
    forward . /etc/resolv.conf {
        max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

The forwarding pattern that Submariner configures (the IP is the `submariner-lighthouse-coredns` Service):

```
clusterset.local:53 {
    forward . 10.96.180.12
}
```

> **Search path gotcha:** a pod's `/etc/resolv.conf` search list covers `<ns>.svc.cluster.local svc.cluster.local cluster.local`, **not** `clusterset.local`. Clients must use the fully qualified name `payments.prod.svc.clusterset.local`. The short name `payments` always resolves to the **local** `cluster.local` Service.

This is a deliberate design choice. Consumers opt in to ClusterSet-wide routing explicitly, while `cluster.local` keeps its single-cluster semantics.

---

## 5. Cilium Cluster Mesh

### 5.1 Architecture

- Each cluster runs **clustermesh-apiserver**: an etcd instance plus a sync component that publishes the local cluster's identities, endpoints, nodes and global services.
- Agents in the other clusters connect to it (TLS, port 2379). With **KVStoreMesh** (the default in recent releases), the local clustermesh-apiserver caches remote state, so agents only read from their own cluster's etcd. That cuts the fan-out from *nodes × clusters* connections.
- The dataplane is **direct pod-to-pod routing**, either native routing or a tunnel (VXLAN/Geneve) between nodes of different clusters. There is no gateway hop.
- **Security identities are cluster-aware.** Policies can match on `io.cilium.k8s.policy.cluster`.

**Hard requirements:**

| Requirement | Why |
|---|---|
| Unique `cluster.name` and `cluster.id` (1–255 by default; up to 511 with `clustermesh.maxConnectedClusters=511`) | The cluster ID is encoded into security identities; a collision corrupts identity resolution |
| Non-overlapping PodCIDRs (and ideally node CIDRs) | Routing is direct; there is no NAT |
| Node-to-node connectivity between all clusters (tunnel/encryption ports, health port 4240) | The dataplane is node to node |
| Reachability of clustermesh-apiserver (LoadBalancer or NodePort) | Control plane sync |
| Same Cilium datapath mode and compatible versions | Identity and encapsulation must match |
| Shared CA (for `cilium clustermesh connect` to work cleanly) | mTLS between agents and the remote apiserver |

### 5.2 Installation

```
$ cilium install --context kind-cluster-a \
    --set cluster.name=cluster-a --set cluster.id=1 \
    --set ipam.mode=kubernetes
$ cilium install --context kind-cluster-b \
    --set cluster.name=cluster-b --set cluster.id=2 \
    --set ipam.mode=kubernetes \
    --inherit-ca kind-cluster-a
```

Or as Helm values for cluster-b:

```yaml
cluster:
  name: cluster-b
  id: 2
ipam:
  mode: kubernetes
routingMode: tunnel
tunnelProtocol: vxlan
encryption:
  enabled: true
  type: wireguard
clustermesh:
  useAPIServer: true
  apiserver:
    replicas: 2
    kvstoremesh:
      enabled: true
    service:
      type: LoadBalancer
    tls:
      auto:
        enabled: true
        method: cronJob
hubble:
  relay:
    enabled: true
```

Enable and connect:

```
$ cilium clustermesh enable --context kind-cluster-a --service-type LoadBalancer
$ cilium clustermesh enable --context kind-cluster-b --service-type LoadBalancer

$ cilium clustermesh status --context kind-cluster-a --wait
✅ Service "clustermesh-apiserver" of type "LoadBalancer" found
✅ Cluster access information is available:
  - 172.18.255.201:2379
✅ Deployment clustermesh-apiserver is ready
ℹ️  KVStoreMesh is enabled

$ cilium clustermesh connect --context kind-cluster-a --destination-context kind-cluster-b
✅ Connected cluster kind-cluster-a <=> kind-cluster-b!

$ cilium clustermesh status --context kind-cluster-a
✅ All 2 nodes are connected to all clusters [min:1 / avg:1.0 / max:1]
✅ All 1 KVStoreMesh replicas are connected to all clusters [min:1 / avg:1.0 / max:1]
🔌 Cluster Connections:
  - cluster-b: 2/2 configured, 2/2 connected - KVStoreMesh: 1/1 configured, 1/1 connected
🔀 Global services: [ min:1 / avg:1.0 / max:1 ]
```

The built-in end-to-end test:

```
$ cilium connectivity test --context kind-cluster-a --multi-cluster kind-cluster-b
...
✅ All 62 tests (410 actions) successful, 12 tests skipped, 0 scenarios skipped.
```

### 5.3 Global services

A Service becomes global when the **same Service** (same name and namespace) exists in each cluster with the `service.cilium.io/global: "true"` annotation. Each agent then merges the backends from every cluster into the local Service's load-balancing map. The client keeps using the normal name, `rebel-base.default.svc.cluster.local`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rebel-base
  namespace: default
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/shared: "true"
    service.cilium.io/affinity: "local"
spec:
  type: ClusterIP
  selector:
    name: rebel-base
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
```

| Annotation | Values | Effect |
|---|---|---|
| `service.cilium.io/global` | `"true"` | Merge backends from every cluster that defines the same global Service |
| `service.cilium.io/shared` | `"true"` (default when global) / `"false"` | `"false"` means this cluster **consumes** remote backends but does **not** share its own backends with others |
| `service.cilium.io/affinity` | `"none"` (default), `"local"`, `"remote"` | `local`: use local backends while any are healthy, fall back to remote; `remote`: prefer remote (useful during maintenance or migration) |

(Older releases used `io.cilium/global-service` and `io.cilium/shared-service`. You may still see them in legacy manifests.)

Inspect the merged backends from an agent:

```
$ kubectl --context kind-cluster-a -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg service list --clustermesh-affinity
ID   Frontend           Service Type   Backend
12   10.96.44.110:80/TCP   ClusterIP   1 => 10.10.1.51:80/TCP (active) (preferred)
                                       2 => 10.10.2.18:80/TCP (active) (preferred)
                                       3 => 10.20.1.77:80/TCP (active)
                                       4 => 10.20.2.40:80/TCP (active)
```

`(preferred)` marks the local backends chosen by `affinity: local`.

Behaviour test:

```
$ for i in $(seq 1 6); do kubectl --context kind-cluster-a exec deploy/x-wing -- curl -s rebel-base; done
{"Galaxy": "Alderaan", "Cluster": "Cluster-1"}
{"Galaxy": "Alderaan", "Cluster": "Cluster-1"}
...
$ kubectl --context kind-cluster-a scale deploy/rebel-base --replicas=0
$ for i in $(seq 1 3); do kubectl --context kind-cluster-a exec deploy/x-wing -- curl -s rebel-base; done
{"Galaxy": "Alderaan", "Cluster": "Cluster-2"}
{"Galaxy": "Alderaan", "Cluster": "Cluster-2"}
{"Galaxy": "Alderaan", "Cluster": "Cluster-2"}
```

### 5.4 Cilium and the MCS API

Recent Cilium releases (1.17 and later) can implement the MCS API on top of Cluster Mesh. `ServiceExport` publishes a service, `ServiceImport` and derived Services are created automatically, and names resolve under `clusterset.local`. You enable it with the `clustermesh.mcsapi.enabled` Helm value; it also needs the MCS CRDs and a CoreDNS configuration for `clusterset.local`. Check the Cluster Mesh MCS-API page for the release you run, because the feature matured across versions. The two models coexist: annotations give you "same name, merged backends", and MCS gives you an explicit, portable `clusterset.local` contract.

### 5.5 Cross-cluster network policy

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-x-wing-from-cluster-a-only
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      name: rebel-base
  ingress:
    - fromEndpoints:
        - matchLabels:
            name: x-wing
            io.cilium.k8s.policy.cluster: cluster-a
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
```

Without the `io.cilium.k8s.policy.cluster` label, selectors match pods from **any** connected cluster that carry the same labels. That is namespace sameness again, applied to identity. Recent releases add `policy-default-local-cluster` to restrict unqualified selectors to the local cluster. Check which behaviour your version defaults to.

---

## 6. Submariner and Lighthouse

### 6.1 Architecture

| Component | Role |
|---|---|
| **Broker** | A set of CRDs on a designated cluster (one of the members or a dedicated one); a rendezvous point, carries no data traffic |
| **Gateway Engine** | Runs on nodes labeled `submariner.io/gateway=true`; builds tunnels to the other clusters' gateways (cable drivers: `libreswan` IPsec default, `wireguard`, `vxlan`) |
| **Route Agent** | DaemonSet; routes cross-cluster traffic from every node to the active gateway |
| **Globalnet** | Optional; assigns each cluster a slice of a global CIDR (default `242.0.0.0/8`) and NATs, for overlapping Pod/Service CIDRs |
| **Lighthouse Agent** | Syncs `ServiceExport` → `ServiceImport` and EndpointSlices through the Broker |
| **Lighthouse CoreDNS** | Answers `clusterset.local`; the cluster's CoreDNS forwards the zone to it |

Submariner is the reference-style implementation of the **MCS API**: you use the standard `ServiceExport` object.

### 6.2 Deployment with `subctl`

```
$ subctl deploy-broker --context broker --globalnet
 ✓ Setting up broker RBAC
 ✓ Deploying the Submariner operator
 ✓ Deploying the broker
 ✓ Writing the broker info to broker-info.subm

$ kubectl --context cluster-a label node worker-a1 submariner.io/gateway=true
$ kubectl --context cluster-b label node worker-b1 submariner.io/gateway=true

$ subctl join --context cluster-a broker-info.subm --clusterid cluster-a --natt=false
$ subctl join --context cluster-b broker-info.subm --clusterid cluster-b --natt=false
```

Status:

```
$ subctl show connections --context cluster-a
 ✓ Showing Connections
GATEWAY     CLUSTER     REMOTE IP     NAT   CABLE DRIVER   SUBNETS          STATUS      RTT avg.
worker-b1   cluster-b   172.18.0.9    no    libreswan      242.1.0.0/16     connected   412.3µs

$ subctl show gateways --context cluster-a
 ✓ Showing Gateways
NODE        HA STATUS   SUMMARY
worker-a1   active      All connections (1) are established
```

### 6.3 Export and consume

```
$ subctl export service --context cluster-b --namespace prod payments
 ✓ Service exported successfully
```

That is equivalent to applying:

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: payments
  namespace: prod
```

From cluster-a:

```
$ kubectl --context cluster-a -n prod get serviceimport
NAME       TYPE           IP                  AGE
payments   ClusterSetIP                       2m

$ kubectl --context cluster-a -n prod run tmp --rm -it --restart=Never \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- \
    nslookup payments.prod.svc.clusterset.local
Server:    10.96.0.10
Address:   10.96.0.10#53

Name:   payments.prod.svc.clusterset.local
Address: 242.1.255.253
```

With Globalnet the answer is a **global IP** (`242.x`), which the gateways translate. Without Globalnet, Lighthouse returns the exporting cluster's Service ClusterIP, which is routed through the tunnel.

Lighthouse resolution semantics:

- If the service is exported from the **local** cluster and has healthy endpoints, the local cluster is preferred.
- Otherwise, answers are round-robined across the clusters that have healthy endpoints.
- Clusters whose gateway connection is down are excluded.
- A specific cluster can be targeted with `<cluster-id>.<svc>.<ns>.svc.clusterset.local`.

### 6.4 Diagnosis

```
$ subctl diagnose all --context cluster-a
 ✓ Checking Submariner support for the Kubernetes version
 ✓ Checking Submariner support for the CNI network plugin
 ✓ Checking gateway connections
 ✓ Checking Submariner pods
 ✓ Checking that firewall configuration allows intra-cluster VXLAN traffic
 ✓ Checking that services have been exported properly

$ subctl verify --context cluster-a --tocontext cluster-b --only service-discovery,connectivity --verbose
```

---

## 7. Istio multicluster

### 7.1 Models

| Axis | Options |
|---|---|
| Control plane | **Multi-primary** (istiod in each cluster, each watching all API servers) vs **primary-remote** (one istiod serves remote clusters) |
| Network | **Single network** (pods reachable directly) vs **multi-network** (traffic crosses an **east-west gateway** on port 15443 with `AUTO_PASSTHROUGH` SNI routing) |

**Discovery:** istiod reads the other clusters' API servers through **remote secrets** (kubeconfigs stored as Secrets labeled `istio/multiCluster=true`). It merges endpoints for services with the same hostname (`svc.ns.svc.cluster.local`). This is namespace sameness again. **Trust:** all clusters must share a **common root CA** (plug-in CA certs), or cross-cluster mTLS fails.

### 7.2 Multi-primary, multi-network

Per-cluster IstioOperator (cluster1):

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
```

Label the network and install:

```
$ kubectl --context cluster1 label namespace istio-system topology.istio.io/network=network1
$ istioctl install --context cluster1 -f cluster1.yaml -y
```

East-west gateway and exposing services:

```
$ samples/multicluster/gen-eastwest-gateway.sh --network network1 | \
    istioctl --context cluster1 install -y -f -
$ kubectl --context cluster1 -n istio-system get svc istio-eastwestgateway
NAME                    TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)
istio-eastwestgateway   LoadBalancer   10.96.201.14   172.18.255.210 15021:31120/TCP,15443:30814/TCP,15012:30219/TCP,15017:32104/TCP
```

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
```

Exchange the remote secrets (each cluster's istiod needs read access to the other's API server):

```
$ istioctl create-remote-secret --context cluster2 --name cluster2 | \
    kubectl apply -f - --context cluster1
secret/istio-remote-secret-cluster2 created
$ istioctl create-remote-secret --context cluster1 --name cluster1 | \
    kubectl apply -f - --context cluster2
secret/istio-remote-secret-cluster1 created

$ istioctl remote-clusters --context cluster1
NAME       SECRET                                        STATUS     ISTIOD
cluster1                                                 synced     istiod-6d5c8b9f7c-kq2xw
cluster2   istio-system/istio-remote-secret-cluster2     synced     istiod-6d5c8b9f7c-kq2xw
```

### 7.3 Locality load balancing and failover

Istio distributes traffic evenly across all endpoints from all clusters by default. To prefer local endpoints and fail over to remote ones, configure a DestinationRule. **Outlier detection is mandatory**: without it Istio cannot tell that local endpoints are unhealthy, and locality failover never triggers.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payments-locality
  namespace: prod
spec:
  host: payments.prod.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http1MaxPendingRequests: 100
        maxRequestsPerConnection: 10
    loadBalancer:
      simple: ROUND_ROBIN
      localityLbSetting:
        enabled: true
        failover:
          - from: europe-west1
            to: europe-west4
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

Locality comes from the node labels `topology.kubernetes.io/region` and `topology.kubernetes.io/zone`.

To keep a service strictly **cluster-local**, even though it exists everywhere:

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    serviceSettings:
      - settings:
          clusterLocal: true
        hosts:
          - "*.kube-system.svc.cluster.local"
          - "redis.cache.svc.cluster.local"
```

Verification:

```
$ istioctl --context cluster1 proxy-config endpoints deploy/sleep -n sample \
    --cluster "outbound|5000||helloworld.sample.svc.cluster.local"
ENDPOINT              STATUS    OUTLIER CHECK   CLUSTER
10.10.1.31:5000       HEALTHY   OK              outbound|5000||helloworld.sample.svc.cluster.local
172.18.255.220:15443  HEALTHY   OK              outbound|5000||helloworld.sample.svc.cluster.local
```

The second endpoint is **cluster2's east-west gateway**. In a multi-network setup, remote pods are reached through the remote gateway, not directly.

---

## 8. Linkerd multicluster

### 8.1 Model

Linkerd **mirrors** services. The service mirror controller in the *source* cluster watches the *target* cluster's API server (through a `Link` resource) and creates a local Service named `<svc>-<target-cluster>` for every exported Service.

| Mode | Export label | Data path |
|---|---|---|
| Gateway (hierarchical) | `mirror.linkerd.io/exported=true` | Client proxy → remote **linkerd-gateway** (port 4143, mTLS) → pod. Works across non-flat networks |
| Pod-to-pod (flat network) | `mirror.linkerd.io/exported=remote-discovery` | Client proxy → remote pod directly; endpoints discovered from the remote API server |
| Federated services | `mirror.linkerd.io/federated=member` | One `<svc>-federated` Service aggregating endpoints from all linked clusters that carry the label |

Both clusters need the **same trust anchor**, because identity is SPIFFE-style mTLS issued from a shared root.

### 8.2 Setup

```
$ linkerd --context west multicluster install | kubectl --context west apply -f -
$ linkerd --context east multicluster install | kubectl --context east apply -f -

$ linkerd --context east multicluster link --cluster-name east | \
    kubectl --context west apply -f -

$ linkerd --context west multicluster check
linkerd-multicluster
--------------------
√ Link CRD exists
√ Link resources are valid
    * east
√ remote cluster access credentials are valid
    * east
√ clusters share trust anchors
    * east
√ service mirror controller has required permissions
    * east
√ service mirror controllers are running
    * east
√ probe services able to communicate with all gateway mirrors
    * east
Status check results are √

$ linkerd --context west multicluster gateways
CLUSTER  ALIVE    NUM_SVC      LATENCY
east     True           1          3ms
```

(Newer Linkerd releases move the controllers into the `multicluster install` Helm values and generate the link with `linkerd multicluster link-gen`. The concepts and labels are the same.)

### 8.3 Export and traffic split

In **east**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  namespace: test
  labels:
    mirror.linkerd.io/exported: "true"
spec:
  selector:
    app: podinfo
  ports:
    - name: http
      port: 9898
      targetPort: 9898
      protocol: TCP
```

In **west**, a `podinfo-east` Service appears automatically. To split traffic between the local and mirrored services, use a Gateway API HTTPRoute attached to the local Service (Linkerd's in-mesh use of Gateway API, known as GAMMA):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo-split
  namespace: test
spec:
  parentRefs:
    - name: podinfo
      kind: Service
      group: ""
      port: 9898
  rules:
    - backendRefs:
        - name: podinfo
          port: 9898
          weight: 50
        - name: podinfo-east
          port: 9898
          weight: 50
```

```
$ kubectl --context west -n test get svc
NAME            TYPE        CLUSTER-IP      PORT(S)
podinfo         ClusterIP   10.96.12.40     9898/TCP
podinfo-east    ClusterIP   10.96.77.201    9898/TCP

$ linkerd --context west viz stat -n test deploy/frontend --to svc/podinfo-east
NAME       MESHED   SUCCESS      RPS   LATENCY_P50   LATENCY_P95   LATENCY_P99   TCP_CONN
frontend      1/1   100.00%   4.9rps           3ms           8ms          10ms          1
```

---

## 9. Gateway API and ServiceImport backends

GEP-1748 defines how Gateway API routes point at an MCS `ServiceImport` as a backend. This is how a single Gateway (for example, a multi-cluster Gateway controller in a "config cluster") sends ingress traffic to backends in the whole ClusterSet:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payments
  namespace: prod
spec:
  parentRefs:
    - name: external-http
      namespace: infra
      kind: Gateway
  hostnames:
    - "payments.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: multicluster.x-k8s.io
          kind: ServiceImport
          name: payments
          port: 80
```

Support is implementation-specific: GKE multi-cluster Gateways, and some Cilium/Istio versions. If a controller does not support it, the route shows `ResolvedRefs=False` with the reason `InvalidKind`:

```
$ kubectl -n prod get httproute payments -o jsonpath='{.status.parents[0].conditions}' | jq
[
  {
    "type": "Accepted",
    "status": "True",
    "reason": "Accepted"
  },
  {
    "type": "ResolvedRefs",
    "status": "False",
    "reason": "InvalidKind",
    "message": "Unsupported backend kind: multicluster.x-k8s.io/ServiceImport"
  }
]
```

Cross-cluster **weights** can be expressed by mixing a local `Service` and a `ServiceImport` in `backendRefs`. That enables a controlled shift of traffic between clusters, for example 90/10 during a migration.

---

## 10. Global (north-south) load balancing

When clients are **outside** the clusters (browsers, partners), cross-cluster load balancing happens before the packet reaches Kubernetes: at DNS or at an anycast global LB.

### 10.1 k8gb (CNCF sandbox)

k8gb runs in each cluster. It owns a **delegated DNS zone** (for example `cloud.example.com`), serves it from its own CoreDNS, and health-checks the application in every cluster by looking at the Ingress/Service backends. Each cluster's k8gb answers DNS queries according to the strategy, and only includes clusters where the app is healthy.

```yaml
apiVersion: k8gb.absa.oss/v1beta1
kind: Gslb
metadata:
  name: payments
  namespace: prod
spec:
  ingress:
    ingressClassName: nginx
    rules:
      - host: payments.cloud.example.com
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: payments
                  port:
                    name: http
  strategy:
    type: failover
    primaryGeoTag: eu-west-1
    dnsTtlSeconds: 30
    splitBrainThresholdSeconds: 300
```

| Strategy | Behaviour |
|---|---|
| `roundRobin` | Returns the healthy clusters' ingress IPs |
| `failover` | Returns only the `primaryGeoTag` cluster while it is healthy; otherwise the others |
| `geoip` | Returns the cluster closest to the resolver (needs a GeoIP DB) |
| `weighted` | Proportional split across clusters |

```
$ kubectl -n prod get gslb payments -o jsonpath='{.status}' | jq
{
  "geoTag": "eu-west-1",
  "healthyRecords": {
    "payments.cloud.example.com": ["203.0.113.10", "203.0.113.11"]
  },
  "serviceHealth": {
    "payments.cloud.example.com": "Healthy"
  }
}

$ dig +short payments.cloud.example.com @203.0.113.53
203.0.113.10
203.0.113.11
```

### 10.2 ExternalDNS

ExternalDNS publishes records for Services and Ingresses into a cloud DNS provider. For multi-cluster use, each cluster's ExternalDNS needs a distinct `--txt-owner-id`, so the instances do not delete each other's records. Weighted, latency or failover routing is then configured through provider-specific annotations (for example Route53 `set-identifier` and `aws-weight`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments-public
  namespace: prod
  annotations:
    external-dns.alpha.kubernetes.io/hostname: payments.example.com
    external-dns.alpha.kubernetes.io/ttl: "30"
    external-dns.alpha.kubernetes.io/set-identifier: eu-west-1
    external-dns.alpha.kubernetes.io/aws-weight: "100"
spec:
  type: LoadBalancer
  selector:
    app: payments
  ports:
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
```

### 10.3 DNS-based failover trade-offs

| Factor | Impact |
|---|---|
| TTL | Failover is bounded below by the TTL **plus** resolver caching that ignores the TTL (JVM DNS caches, stub resolvers) |
| Health-check fidelity | k8gb checks endpoint readiness, not real user paths; a healthy-but-broken app keeps getting traffic |
| Connection reuse | Long-lived HTTP/2 and gRPC connections do not re-resolve; failover needs connection draining or max-connection-age |
| Resolver location | GeoIP sees the **resolver**, not the client (EDNS Client Subnet mitigates this) |

---

## 11. Load-balancing semantics across clusters

| Concern | Options | Production guidance |
|---|---|---|
| **Locality** | Cilium `affinity: local`; Istio `localityLbSetting`; Lighthouse prefers local; k8gb `failover` | Default to *local-first, remote on failure*: cross-region traffic costs latency and egress money |
| **Failover trigger** | Endpoint readiness (Cilium, Lighthouse), outlier detection (Istio), probe gateway (Linkerd), DNS health (k8gb) | Readiness only catches dead pods; outlier detection catches bad pods returning 5xx |
| **Capacity** | Nothing auto-scales the surviving cluster | Keep N+1 headroom, or failover causes a cascading overload; consider `maxEjectionPercent` and HPA headroom |
| **Session affinity** | `ServiceImport.spec.sessionAffinity: ClientIP`; Istio consistent hash | Affinity breaks on failover; design stateless or with replicated state |
| **Stateful services** | Headless ServiceImport with per-cluster pod names | Cross-cluster quorum systems (etcd, Cassandra) need latency-aware placement; do not stretch etcd across regions |
| **Egress cost** | Cloud providers charge for inter-zone and inter-region traffic | Measure with Hubble / Istio telemetry by `source-cluster` |

---

## 12. Verification and troubleshooting

### 12.1 A systematic runbook (walk the three planes)

**Step 1: identity and prerequisites.**

```
$ for c in cluster-a cluster-b; do
    echo "== $c"; kubectl --context $c get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}'
  done
== cluster-a
10.10.0.0/24
10.10.1.0/24
== cluster-b
10.10.0.0/24      <-- OVERLAP: flat-network solutions will fail; use Globalnet / gateway mode
10.10.1.0/24
```

Also check for unique cluster IDs: `kubectl get clusterproperty cluster.clusterset.k8s.io -o jsonpath='{.spec.value}'` for MCS, `cilium config view | grep cluster-` for Cilium.

**Step 2: discovery plane.**

```
$ kubectl --context cluster-a -n prod get serviceexport payments \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
Valid=True
Conflict=False NoConflicts

$ kubectl --context cluster-b -n prod get serviceimport payments -o wide
$ kubectl --context cluster-b -n prod get endpointslices -l multicluster.kubernetes.io/service-name=payments
```

- No ServiceImport → the controller is not syncing (check the broker connection, the Lighthouse agent logs and RBAC).
- ServiceImport present but no remote EndpointSlices → the exporter has no **ready** pods, or the agent cannot write through the broker.

**Step 3: DNS.**

```
$ kubectl --context cluster-b -n prod run dnsutil --rm -it --restart=Never \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- \
    dig +search +short payments.prod.svc.clusterset.local
$ kubectl --context cluster-b -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -A2 clusterset
clusterset.local:53 {
    forward . 10.96.180.12
}
$ kubectl --context cluster-b -n kube-system logs deploy/coredns | grep -i clusterset
```

- `NXDOMAIN` → the zone is not configured, or there is no ServiceImport.
- `SERVFAIL` → the forward target (Lighthouse DNS) is unreachable.
- It resolves to the local ClusterIP → the client used a short name (`cluster.local` via the search path).

**Step 4: data plane.**

```
$ kubectl --context cluster-b -n prod exec deploy/client -- curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://payments.prod.svc.clusterset.local
000
curl: (28) Connection timed out after 3001 milliseconds
```

A timeout while DNS works means a data plane problem. Test the pod IP directly, then look at the tool-specific datapath:

```
# Cilium
$ hubble observe --from-pod prod/client --to-namespace prod --verdict DROPPED
Sep 30 10:41:12.004: prod/client-6c9 (ID:21453) <> prod/payments-7d4 (ID:38811) policy-verdict:none DENIED (TCP Flags: SYN)
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg troubleshoot clustermesh

# Submariner
$ subctl show connections
$ kubectl -n submariner-operator logs -l app=submariner-gateway --tail=50

# Istio
$ istioctl proxy-config endpoints deploy/client -n prod | grep payments
$ istioctl analyze --all-namespaces

# Linkerd
$ linkerd multicluster gateways
$ linkerd diagnostics endpoints payments-east.prod.svc.cluster.local:80
```

**Step 5: MTU.** Symptoms: small requests work, large responses hang (TLS handshakes with long certificate chains, large JSON bodies). Tunnels stacked on tunnels (VXLAN inside IPsec) reduce the effective MTU.

```
$ kubectl exec deploy/client -- ping -M do -s 1400 -c 2 10.20.1.5
PING 10.20.1.5 (10.20.1.5) 1400(1428) bytes of data.
ping: local error: message too long, mtu=1370
```

Fix it by lowering the pod MTU in the CNI config, or by enabling MSS clamping. Submariner clamps TCP MSS on the gateways; check it with `subctl diagnose`.

### 12.2 Failure matrix

| Symptom | Likely cause | Plane | Fix |
|---|---|---|---|
| `clusterset.local` NXDOMAIN | CoreDNS not forwarding the zone / plugin missing | Discovery (DNS) | Add a `clusterset.local` stanza; check the Lighthouse/multicluster plugin |
| ServiceExport `Valid=False` | No matching Service, or an unsupported type | Discovery | Create a Service with the same name and namespace |
| ServiceExport `Conflict=True` | Port/protocol/type mismatch between clusters | Discovery | Align the Service definitions; the oldest export wins until fixed |
| Traffic only reaches local backends | Cilium `affinity: local` is working as designed, or the remote cluster uses `shared: "false"` | LB policy | Check the annotations with `cilium-dbg service list --clustermesh-affinity` |
| Traffic hits another team's pods | Namespace sameness violated | Discovery | Reserve namespaces per ClusterSet; use cluster-qualified policy |
| Cilium clusters not connecting | Duplicate `cluster.id`, CA mismatch, clustermesh-apiserver unreachable | Control | `cilium clustermesh status`; reissue certs with `--inherit-ca` |
| Identity-based policy denies remote traffic | The policy lacks cross-cluster selectors, or `policy-default-local-cluster` applies | Policy | Add `io.cilium.k8s.policy.cluster` explicitly |
| Istio remote endpoints missing | Remote secret invalid or expired, or no API server reachability | Discovery | `istioctl remote-clusters`; recreate the secret |
| Istio 503 `UF` / TLS errors cross-cluster | Different root CAs | Security | Plug in certs from a shared root |
| Istio locality failover never happens | `outlierDetection` missing | LB | Add outlier detection to the DestinationRule |
| Linkerd `podinfo-east` has no endpoints | Gateway unreachable / probe failing | Data plane | `linkerd multicluster gateways`; check the gateway LB and port 4143 |
| Submariner `connecting` forever | UDP 4500/4490 blocked, NAT-T misconfigured, wrong gateway label | Data plane | Open the ports; `--natt`; `subctl diagnose firewall inter-cluster` |
| Overlapping CIDR black hole | Flat routing across identical ranges | Data plane | Globalnet, gateway mode, or re-IP |
| Failover takes minutes (GSLB) | TTL plus client DNS caching, long-lived connections | North-south | Lower the TTL, set connection max-age, prefer anycast LB |
| Large payloads hang | MTU/PMTUD broken over tunnels | Data plane | Lower the MTU, enable MSS clamping |

### 12.3 Observability you should have before an incident

- Hubble flows or Istio/Linkerd metrics labeled by **source and destination cluster**.
- Alerts on the clustermesh connection state (`cilium_clustermesh_remote_cluster_readiness_status`), on Submariner gateway connection status and on istiod remote cluster sync.
- A synthetic probe per cluster pair that resolves `*.clusterset.local` and does an HTTP GET, so all three planes are checked continuously.

---

## 13. Exam-oriented checklist

- [ ] Explain ClusterSet, namespace sameness, ServiceExport and ServiceImport, and write a `ServiceExport` from memory (`multicluster.x-k8s.io/v1alpha1`, name and namespace only).
- [ ] Know the DNS forms: `svc.ns.svc.clusterset.local` and `host.clusterid.svc.ns.svc.clusterset.local`, and that `clusterset.local` is **not** in the default search path.
- [ ] Know `ClusterSetIP` vs `Headless` in `ServiceImport`.
- [ ] Know the EndpointSlice labels `multicluster.kubernetes.io/service-name` and `multicluster.kubernetes.io/source-cluster`.
- [ ] Cilium: unique name and ID, non-overlapping PodCIDRs, `cilium clustermesh enable/connect/status`, and the `global`, `shared`, `affinity` annotations.
- [ ] Submariner: broker, gateway label, Globalnet for overlaps, `subctl export service`, `subctl diagnose all`.
- [ ] Istio: multi-network needs an east-west gateway (15443, `AUTO_PASSTHROUGH`), remote secrets and a shared root CA; locality failover needs outlier detection.
- [ ] Linkerd: `mirror.linkerd.io/exported`, mirrored `<svc>-<cluster>` names, `linkerd multicluster check`.
- [ ] Gateway API: `backendRefs` with `group: multicluster.x-k8s.io`, `kind: ServiceImport`.
- [ ] GSLB: k8gb strategies, and TTL as the failover floor.
- [ ] Troubleshoot by plane: identity → discovery → DNS → data plane → MTU.

---

## References

- CKNE certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- KEP-1645 Multi-Cluster Services API: https://github.com/kubernetes/enhancements/tree/master/keps/sig-multicluster/1645-multi-cluster-services-api
- KEP-2149 ClusterId for ClusterSet identification: https://github.com/kubernetes/enhancements/tree/master/keps/sig-multicluster/2149-clusterid
- MCS API CRDs and reference: https://github.com/kubernetes-sigs/mcs-api
- SIG Multicluster documentation: https://multicluster.sigs.k8s.io/
- CoreDNS multicluster plugin: https://github.com/coredns/multicluster
- Gateway API GEP-1748 (ServiceImport backends): https://gateway-api.sigs.k8s.io/geps/gep-1748/
- Kubernetes Services and DNS: https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes EndpointSlices: https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Cilium Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/
- Cilium Cluster Mesh setup: https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/
- Cilium load-balancing and service discovery across clusters: https://docs.cilium.io/en/stable/network/clustermesh/services/
- Cilium Cluster Mesh MCS-API support: https://docs.cilium.io/en/stable/network/clustermesh/mcsapi/
- Cilium Cluster Mesh troubleshooting: https://docs.cilium.io/en/stable/operations/troubleshooting/#troubleshooting-clustermesh
- Submariner documentation: https://submariner.io/
- Submariner service discovery (Lighthouse): https://submariner.io/getting-started/architecture/service-discovery/
- Submariner Globalnet: https://submariner.io/getting-started/architecture/globalnet/
- Istio multicluster installation: https://istio.io/latest/docs/setup/install/multicluster/
- Istio multi-primary on different networks: https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/
- Istio locality load balancing: https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/
- Istio multicluster traffic management: https://istio.io/latest/docs/ops/configuration/traffic-management/multicluster/
- Linkerd multi-cluster communication: https://linkerd.io/2/features/multicluster/
- Linkerd multicluster tasks: https://linkerd.io/2/tasks/multicluster/
- Linkerd federated services: https://linkerd.io/2/tasks/federated-services/
- k8gb: https://www.k8gb.io/
- k8gb documentation: https://github.com/k8gb-io/k8gb/tree/master/docs
- ExternalDNS: https://kubernetes-sigs.github.io/external-dns/
- GKE Multi-cluster Services (MCS implementation): https://cloud.google.com/kubernetes-engine/docs/concepts/multi-cluster-services