# 2.2 Understanding kube-proxy and CNI Alternatives

> **Exam weight:** 4.17% · **Scope:** how Kubernetes Services turn into packet forwarding on the node, the kube-proxy modes (`iptables`, `ipvs`, `nftables`), and how eBPF CNIs replace kube-proxy (Cilium, Calico eBPF, Antrea, kube-router). It also covers how to prove which dataplane actually handles your traffic.

---

## 1. Motivation: the production problem

A Kubernetes `Service` is only an API object. It holds a virtual IP (the ClusterIP), some ports and a label selector. Nothing in the kernel knows about it by default. Something on every node has to turn "packet to `10.96.120.15:80`" into "packet to one of the ready Pod IPs behind that Service." That component is the **service proxy**.

Two different jobs get lumped together as "cluster networking," and they are owned by different components:

| Concern | Owner | Contract |
|---|---|---|
| Pod gets an interface and IP, and can reach any other Pod without NAT | **CNI plugin** (invoked by the container runtime) | CNI spec: `ADD`, `DEL`, `CHECK`, `VERSION` (+ `GC`, `STATUS` in CNI 1.1) |
| ClusterIP / NodePort / LoadBalancer / externalIPs are translated to endpoints | **Service proxy**: `kube-proxy` by default, or a CNI that replaces it | Watches `Services` + `EndpointSlices`, programs the node dataplane |
| NetworkPolicy enforcement | CNI plugin (or a separate policy agent) | `networking.k8s.io/v1` NetworkPolicy semantics |

The CNI specification says nothing about Services. That split is why you can run Flannel for Pod networking with kube-proxy for Services, or run Cilium for both and delete kube-proxy.

Why this becomes an architectural decision in production:

1. **Scale.** In `iptables` mode, the first packet of a new connection walks a list of rules that grows linearly with the number of Services. Every endpoint change also means rewriting large rulesets. At 10k+ Services, sync latency (the time from a Pod becoming Ready until traffic reaches it) is measured in seconds.
2. **Correctness under churn.** Stale conntrack entries, especially for UDP/DNS, send traffic to Pods that no longer exist.
3. **Two dataplanes fighting.** If you enable an eBPF kube-proxy replacement and leave kube-proxy running, both program Service translation. Behaviour then depends on hook ordering, and failures look intermittent.
4. **Bootstrap ordering.** The CNI agent normally reaches the API server through the `kubernetes` Service ClusterIP, which kube-proxy implements. Remove kube-proxy and the CNI must be told the real API server address, or no node ever becomes Ready.
5. **Source IP and observability.** `externalTrafficPolicy`, SNAT, DSR and socket-level load balancing decide whether your backends see the client IP and whether `tcpdump` on the node shows the ClusterIP at all.

---

## 2. How kube-proxy works internally

kube-proxy is a controller that runs as a DaemonSet (on kubeadm clusters) or as a systemd unit. On each node it:

1. Watches `Service` and `EndpointSlice` objects (`discovery.k8s.io/v1`) through informers.
2. Builds an in-memory model of the desired state: service port → list of ready or serving endpoints, filtered by topology, `internalTrafficPolicy`, `externalTrafficPolicy` and terminating state.
3. Rate-limits resyncs. `minSyncPeriod` merges bursts of changes into one sync. `syncPeriod` is a periodic full resync that repairs drift.
4. Programs the kernel through the selected **mode** backend.
5. Clears stale **UDP conntrack** entries when endpoints disappear. Without this, a DNS client keeps sending to a dead CoreDNS Pod IP.
6. Serves `/healthz` and `/livez` on port `10256`, and metrics plus `/proxyMode` on `127.0.0.1:10249`.

kube-proxy **never carries data traffic**. The old `userspace` mode, which did, was removed in v1.26. Packet translation happens entirely in the kernel.

### 2.1 Mode comparison

| Property | `iptables` | `ipvs` | `nftables` | eBPF replacement (Cilium / Calico eBPF) |
|---|---|---|---|---|
| Status | Default on Linux, GA, mature | **Deprecated** (upstream deprecation in v1.35); do not choose it for new clusters | GA since v1.33 | Out of tree, maintained by the CNI vendor |
| Kernel mechanism | netfilter `nat` table: DNAT chains | IPVS virtual servers + iptables/ipset for masquerade and filtering | nftables sets, maps and verdict maps | eBPF programs at tc/XDP and at the socket (`connect()`) hook |
| First-packet lookup | O(n) over `KUBE-SERVICES` | Hash lookup | Verdict-map lookup (effectively O(1)) | BPF hash map lookup |
| Update model | `iptables-restore`. Partial syncs since v1.28, but periodic full syncs remain | Incremental IPVS netlink + ipset | Incremental transactions | Map updates, no ruleset rewrite |
| Load balancing | Random (`statistic --mode random`) | rr, lc, dh, sh, sed, nq, … | Random (`numgen random`) | Random or **Maglev** consistent hashing |
| Min. kernel | Any supported | IPVS modules loaded | **5.13+** | Vendor-specific (roughly 5.10+ for full features) |
| Side effects | Rules visible in `iptables-save` | `kube-ipvs0` dummy interface holds every ClusterIP; needs `strictARP` for MetalLB | NodePorts only on the node's default IPs, **not** on `127.0.0.1` | ClusterIP may never appear on the wire (socket LB); `tcpdump` shows the backend IP |
| Source-IP preservation options | `externalTrafficPolicy: Local` | Same | Same | Same, plus **DSR** |
| Debug tooling | `iptables-save`, `conntrack` | `ipvsadm`, `ipset`, `conntrack` | `nft list table ip kube-proxy` | `cilium-dbg`, `bpftool`, `calico-node -bpf` |

**Architect's recommendation (2026):** choose `nftables` for new kube-proxy-based clusters on modern kernels. Use an eBPF replacement when you already run that CNI and need scale, DSR, Maglev or socket-level load balancing. Treat `ipvs` as a migration source, not a destination.

### 2.2 The Service-type pipeline (same logic in every mode)

```
packet ──► is dst a ClusterIP:port?           ──► pick endpoint ──► DNAT
       ──► is dst a NodePort on this node?    ──► (eTP Local? only local endpoints) ──► DNAT
       ──► is dst an externalIP / LB IP?      ──► same as NodePort path
       ──► needs masquerade?  (src outside clusterCIDR, or hairpin, or eTP Cluster)
                                              ──► SNAT to node IP in POSTROUTING
```

"Local" detection (`detectLocalMode`) decides whether traffic came from a Pod. The options are `ClusterCIDR`, `NodeCIDR`, `BridgeInterface` or `InterfaceNamePrefix`. If this is wrong, you get either lost source IPs or asymmetric routing.

---

## 3. Inside each mode, with real output

### 3.1 Test workload used throughout

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
  labels:
    app: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: agnhost
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
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: demo
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
      protocol: TCP
  externalTrafficPolicy: Cluster
  internalTrafficPolicy: Cluster
```

```
$ kubectl apply -f web.yaml
namespace/demo created
deployment.apps/web created
service/web created

$ kubectl -n demo get svc web
NAME   TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web    NodePort   10.96.120.15   <none>        80:30080/TCP   12s

$ kubectl -n demo get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
web-7xq2k   IPv4          8080    10.244.1.5,10.244.2.7,10.244.2.8   12s
```

`agnhost netexec` answers `/hostname` with the Pod name, which makes load-balancing distribution visible.

### 3.2 `iptables` mode

```
$ sudo iptables-save -t nat | grep 'demo/web'
-A KUBE-SERVICES -d 10.96.120.15/32 -p tcp -m comment --comment "demo/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-ULMVA6XW
-A KUBE-NODEPORTS -p tcp -m comment --comment "demo/web:http" -m tcp --dport 30080 -j KUBE-EXT-ULMVA6XW
-A KUBE-EXT-ULMVA6XW -m comment --comment "masquerade traffic for demo/web:http external destinations" -j KUBE-MARK-MASQ
-A KUBE-EXT-ULMVA6XW -j KUBE-SVC-ULMVA6XW
-A KUBE-SVC-ULMVA6XW ! -s 10.244.0.0/16 -d 10.96.120.15/32 -p tcp -m comment --comment "demo/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-ULMVA6XW -m comment --comment "demo/web:http -> 10.244.1.5:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-5OJB2KTY
-A KUBE-SVC-ULMVA6XW -m comment --comment "demo/web:http -> 10.244.2.7:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-HQ3WZ7KF
-A KUBE-SVC-ULMVA6XW -m comment --comment "demo/web:http -> 10.244.2.8:8080" -j KUBE-SEP-QX7M2BRA
-A KUBE-SEP-5OJB2KTY -s 10.244.1.5/32 -m comment --comment "demo/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-5OJB2KTY -p tcp -m comment --comment "demo/web:http" -m tcp -j DNAT --to-destination 10.244.1.5:8080
```

How to read it:

- **Probabilities cascade:** 1/3, then 1/2 of the remainder, then everything left. The result is uniform random selection with no state.
- **`KUBE-MARK-MASQ`** only sets a fwmark (`0x4000` by default). `KUBE-POSTROUTING` does the SNAT for marked packets.
- The **`-s <endpoint>` rule in `KUBE-SEP`** handles hairpin: a Pod that reaches itself through its own Service must be masqueraded, or the reply short-circuits.
- **Scale cost:** a packet to the *last* Service in `KUBE-SERVICES` is compared against every rule before it. Count what your nodes carry:

```
$ sudo iptables-save -t nat | grep -c '^-A KUBE-'
48211
```

### 3.3 `nftables` mode

```
$ sudo nft list table ip kube-proxy | sed -n '/map service-ips/,/}/p'
	map service-ips {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
		elements = { 10.96.0.1 . tcp . 443 : goto service-2QRHZV4L-default/kubernetes/tcp/https,
			     10.96.0.10 . udp . 53 : goto service-FY5PMXPG-kube-system/kube-dns/udp/dns,
			     10.96.120.15 . tcp . 80 : goto service-ULMVA6XW-demo/web/tcp/http }
	}

$ sudo nft list chain ip kube-proxy 'service-ULMVA6XW-demo/web/tcp/http'
table ip kube-proxy {
	chain service-ULMVA6XW-demo/web/tcp/http {
		ip daddr 10.96.120.15 tcp dport 80 ip saddr != 10.244.0.0/16 jump mark-for-masquerade
		numgen random mod 3 vmap { 0 : goto endpoint-5OJB2KTY-demo/web/tcp/http__10.244.1.5/8080, 1 : goto endpoint-HQ3WZ7KF-demo/web/tcp/http__10.244.2.7/8080, 2 : goto endpoint-QX7M2BRA-demo/web/tcp/http__10.244.2.8/8080 }
	}
}
```

Why it scales: **one** map lookup by `(daddr . proto . dport)` goes straight to the Service chain, however many Services exist. An endpoint change is a small transaction, not a table rewrite.

Behavioural differences that break migrations from `iptables`:

| Behaviour | `iptables` mode | `nftables` mode |
|---|---|---|
| NodePort on `127.0.0.1` | Works (sets `route_localnet=1`) | **Not supported** |
| NodePort on every local IP | Yes (unless `nodePortAddresses` is set) | Default: node's **primary** IPs only |
| Traffic to a ClusterIP on a port the Service doesn't define | Silently dropped / times out | Actively **rejected** |
| Other tools inserting into the `KUBE-*` chains | Common (and fragile) | Separate table; such hacks stop working |

### 3.4 `ipvs` mode (legacy, still in the field)

```
$ sudo ipvsadm -Ln -t 10.96.120.15:80
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  10.96.120.15:80 rr
  -> 10.244.1.5:8080              Masq    1      0          0
  -> 10.244.2.7:8080              Masq    1      0          0
  -> 10.244.2.8:8080              Masq    1      0          0

$ ip -brief addr show kube-ipvs0
kube-ipvs0       DOWN           10.96.0.1/32 10.96.0.10/32 10.96.120.15/32

$ sudo ipset list KUBE-CLUSTER-IP | head -5
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 6
Header: family inet hashsize 1024 maxelem 65536 bucketsize 12 initval 0x5d1b4b3e
Size in memory: 1432
```

Every ClusterIP is bound to the dummy `kube-ipvs0` interface so IPVS accepts it as local. Without `strictARP: true`, nodes answer ARP for those addresses on every interface. MetalLB L2 mode requires `strictARP` for exactly this reason.

### 3.5 Check the running mode (every mode)

```
$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
mode: nftables

$ curl -s http://127.0.0.1:10249/proxyMode     # run on the node
nftables

$ kubectl -n kube-system logs ds/kube-proxy | grep -i 'Using'
I0930 10:12:03.114122       1 server_linux.go:...] "Using nftables Proxier"
```

An empty `mode:` means the platform default, which is `iptables` on Linux. Always confirm through `/proxyMode` instead of assuming.

---

## 4. Configuring kube-proxy: complete manifests

### 4.1 kubeadm cluster with an explicit `KubeProxyConfiguration`

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.34.1
clusterName: ckne-lab
controlPlaneEndpoint: "192.168.10.10:6443"
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
clusterCIDR: 10.244.0.0/16
detectLocalMode: ClusterCIDR
bindAddress: 0.0.0.0
healthzBindAddress: "0.0.0.0:10256"
metricsBindAddress: "127.0.0.1:10249"
nodePortAddresses:
  - primary
nftables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncPeriod: 1s
  syncPeriod: 30s
iptables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncPeriod: 1s
  syncPeriod: 30s
  localhostNodePorts: false
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpEstablishedTimeout: 24h0m0s
  tcpCloseWaitTimeout: 1h0m0s
  udpTimeout: 0s
  udpStreamTimeout: 0s
```

```
$ sudo kubeadm init --config kubeadm-config.yaml --upload-certs
...
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy
```

Notes:
- `masqueradeBit: 14` gives the `0x4000` mark seen in the iptables output. Change it only if another tool uses the same bit.
- `udpTimeout: 0s` means "leave the kernel default."
- `minSyncPeriod` is the main latency-versus-CPU knob. `0s` syncs on every change. `1s` batches changes during rolling updates and is the upstream recommendation.

### 4.2 Changing the mode on a running cluster

```
$ kubectl -n kube-system edit cm kube-proxy          # set  mode: nftables
configmap/kube-proxy edited

$ kubectl -n kube-system rollout restart ds/kube-proxy
daemonset.apps/kube-proxy restarted

$ kubectl -n kube-system rollout status ds/kube-proxy
daemon set "kube-proxy" successfully rolled out
```

Recent kube-proxy versions try to remove the other modes' rules at startup. In production, still drain and reboot each node, or run `kube-proxy --cleanup` in the node's context. That guarantees no stale `KUBE-*` iptables chains or `kube-ipvs0` addresses are left intercepting traffic.

### 4.3 Kind lab clusters (one per dataplane)

```yaml
# kind-nftables.yaml — kube-proxy in nftables mode, default kindnet CNI
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kp-nft
networking:
  kubeProxyMode: "nftables"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```yaml
# kind-nokp.yaml — no kube-proxy, no default CNI (for Cilium KPR)
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kpr
networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```
$ kind create cluster --config kind-nokp.yaml
Creating cluster "kpr" ...
 ✓ Ensuring node image (kindest/node:v1.34.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜

$ kubectl get nodes
NAME                STATUS     ROLES           AGE   VERSION
kpr-control-plane   NotReady   control-plane   40s   v1.34.0
kpr-worker          NotReady   <none>          20s   v1.34.0
kpr-worker2         NotReady   <none>          20s   v1.34.0

$ kubectl -n kube-system get ds
NAME   DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
```

The nodes stay `NotReady` because there is no CNI yet, and there is no `kube-proxy` DaemonSet. Both are expected.

---

## 5. CNI alternatives that replace kube-proxy

### 5.1 Landscape

| Project | Service implementation | kube-proxy required? | Distinctive capabilities | Trade-offs |
|---|---|---|---|---|
| **Flannel** | None | **Yes** | Simple VXLAN/host-gw overlay | No NetworkPolicy of its own, no service LB |
| **Calico (iptables/nftables dataplane)** | None | Yes | BGP, rich policy | Two netfilter owners on each node |
| **Calico eBPF dataplane** | eBPF (tc hooks) + socket LB | **No** (replaces it) | Source-IP preservation, DSR, lower latency | Operator config, kernel requirements, different debug tooling |
| **Cilium KPR** | eBPF (tc/XDP) + socket LB | **No** | Maglev, DSR, XDP acceleration, Hubble visibility | Deepest kernel dependency; must hand-configure the API endpoint |
| **Antrea** (AntreaProxy) | OVS flows | Optional (`proxyAll: true`) | OVS-based, Windows parity | OVS operational knowledge needed |
| **kube-router** | IPVS | No (`--run-service-proxy`) | BGP + IPVS in one binary | Inherits IPVS's deprecation trajectory |
| **OVN-Kubernetes** | OVN load balancers | No | OpenShift default, strong multi-tenancy | Heavy control plane (OVN NB/SB DBs) |

### 5.2 What eBPF changes mechanically

1. **Socket-level load balancing:** a BPF program attached to cgroup `connect()`/`sendmsg()` rewrites the destination *before the packet exists*. The ClusterIP never goes onto the wire, so there is no per-packet DNAT and no conntrack entry for the translation. Consequence: `tcpdump` in the client Pod's netns shows the **backend** IP. Students often read this as broken.
2. **tc/XDP load balancing** handles NodePort/LoadBalancer traffic arriving from outside at the NIC. With XDP, this happens before the SKB (socket buffer) is allocated.
3. **Maglev hashing:** backend choice is consistent across nodes, so a flow that ECMP moves to another node still reaches the same backend.
4. **DSR (Direct Server Return):** the backend replies straight to the client, keeping the client IP without `externalTrafficPolicy: Local`. It needs native routing, or a tunnel-based DSR dispatch mode.

### 5.3 Cilium with full kube-proxy replacement: complete Helm values

```yaml
# cilium-kpr-values.yaml
kubeProxyReplacement: true
# There is no kube-proxy, so the 10.96.0.1 ClusterIP does not work until Cilium
# itself runs. The agent must reach the API server directly:
k8sServiceHost: kpr-control-plane
k8sServicePort: 6443
ipam:
  mode: kubernetes
routingMode: tunnel
tunnelProtocol: vxlan
bpf:
  masquerade: true
socketLB:
  enabled: true
  hostNamespaceOnly: false
nodePort:
  enabled: true
loadBalancer:
  algorithm: maglev
  mode: snat
maglev:
  tableSize: 16381
hubble:
  enabled: true
  relay:
    enabled: true
operator:
  replicas: 1
```

```
$ helm repo add cilium https://helm.cilium.io/
"cilium" has been added to your repositories

$ helm install cilium cilium/cilium --version 1.18.2 \
    --namespace kube-system -f cilium-kpr-values.yaml
NAME: cilium
LAST DEPLOYED: Tue Sep 30 10:31:07 2026
NAMESPACE: kube-system
STATUS: deployed

$ kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out

$ kubectl get nodes
NAME                STATUS   ROLES           AGE   VERSION
kpr-control-plane   Ready    control-plane   6m    v1.34.0
kpr-worker          Ready    <none>          6m    v1.34.0
kpr-worker2         Ready    <none>          6m    v1.34.0
```

Pin the chart version you have tested. `loadBalancer.mode: dsr` requires `routingMode: native` (plus `ipv4NativeRoutingCIDR` and `autoDirectNodeRoutes: true` on a flat L2). That is why `snat` is used above, on a kind VXLAN overlay.

Verify the replacement:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Masquerading|Routing'
KubeProxyReplacement:    True   [eth0   172.18.0.3 fc00:f853:ccd:e793::3 (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: BPF
Masquerading:            BPF   [eth0]   10.244.0.0/16 [IPv4: Enabled, IPv6: Disabled]

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
ID   Frontend              Service Type   Backend
1    10.96.0.1:443/TCP     ClusterIP      1 => 172.18.0.2:6443/TCP (active)
2    10.96.0.10:53/UDP     ClusterIP      1 => 10.244.0.143:53/UDP (active)
                                          2 => 10.244.0.201:53/UDP (active)
5    10.96.120.15:80/TCP   ClusterIP      1 => 10.244.1.5:8080/TCP (active)
                                          2 => 10.244.2.7:8080/TCP (active)
                                          3 => 10.244.2.8:8080/TCP (active)
6    0.0.0.0:30080/TCP     NodePort       1 => 10.244.1.5:8080/TCP (active)
                                          2 => 10.244.2.7:8080/TCP (active)
                                          3 => 10.244.2.8:8080/TCP (active)

$ docker exec kpr-worker iptables-save | grep -c KUBE-SVC
0
```

The proof has two parts: the Services appear in Cilium's BPF load-balancer map, **and** no `KUBE-SVC` chains exist. If you see only the first, you are running two dataplanes.

### 5.4 Migrating an existing kubeadm cluster off kube-proxy (Cilium)

Order matters. Install or upgrade the CNI with KPR **first**, then remove kube-proxy.

```
$ helm upgrade cilium cilium/cilium --version 1.18.2 -n kube-system \
    --reuse-values --set kubeProxyReplacement=true \
    --set k8sServiceHost=192.168.10.10 --set k8sServicePort=6443

$ kubectl -n kube-system rollout restart ds/cilium && kubectl -n kube-system rollout status ds/cilium
daemon set "cilium" successfully rolled out

$ kubectl -n kube-system delete ds kube-proxy
daemonset.apps "kube-proxy" deleted
$ kubectl -n kube-system delete cm kube-proxy
configmap "kube-proxy" deleted

# on EACH node — remove the leftover KUBE-* rules
$ sudo iptables-save | grep -v KUBE | sudo iptables-restore
$ sudo nft delete table ip kube-proxy 2>/dev/null; sudo nft delete table ip6 kube-proxy 2>/dev/null; true
```

Also stop `kubeadm upgrade` from reinstalling it. In kubeadm `v1beta4`, set this in the `ClusterConfiguration`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
proxy:
  disabled: true
```

On a fresh cluster, `kubeadm init --skip-phases=addon/kube-proxy` does the same at bootstrap.

### 5.5 Calico eBPF dataplane: complete manifests

The API server endpoint override (same bootstrap problem as Cilium):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "192.168.10.10"
  KUBERNETES_SERVICE_PORT: "6443"
```

The operator `Installation`, switching the dataplane to BPF:

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: BPF
    bgp: Disabled
    ipPools:
      - name: default-ipv4-ippool
        cidr: 10.244.0.0/16
        blockSize: 26
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
```

Disable kube-proxy without deleting it, which makes rollback trivial:

```
$ kubectl patch ds -n kube-system kube-proxy \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-calico": "true"}}}}}'
daemonset.apps/kube-proxy patched

$ kubectl -n kube-system get ds kube-proxy
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR       AGE
kube-proxy   0         0         0       0            0           non-calico=true     41d
```

Felix removes kube-proxy's leftover iptables rules by default (`bpfKubeProxyIptablesCleanupEnabled`). To roll back, remove the nodeSelector, set `linuxDataplane: Iptables`, and restore kube-proxy **before** Felix leaves BPF mode.

### 5.6 Choosing: a decision table

| Situation | Recommendation | Reason |
|---|---|---|
| < 1k Services, standard kernels, simple CNI | kube-proxy `nftables` (or `iptables` if the kernel is < 5.13) | Least moving parts, upstream-supported |
| Existing `ipvs` clusters | Plan migration to `nftables` or eBPF | IPVS mode is deprecated upstream |
| Need client source IP at scale without eTP Local imbalance | Cilium/Calico eBPF with DSR | Keeps client IP and spreads load evenly |
| 10k+ Services, high endpoint churn | eBPF replacement | Map updates, no ruleset rewrite |
| Heavy dependence on iptables-based tooling (legacy firewalls, HIDS) | kube-proxy `iptables` | eBPF bypasses netfilter paths those tools watch |
| Windows nodes in the cluster | kube-proxy (`kernelspace`) or Antrea | Linux eBPF replacements do not cover Windows |

---

## 6. Traffic policies that the proxy enforces

These fields are enforced by *whatever* implements Services. Exam scenarios often combine them with a dataplane question.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-local
  namespace: demo
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30081
      protocol: TCP
  externalTrafficPolicy: Local
  internalTrafficPolicy: Cluster
  trafficDistribution: PreferClose
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

| Field | Effect | Failure mode if misunderstood |
|---|---|---|
| `externalTrafficPolicy: Local` | NodePort/LB traffic only to endpoints on the receiving node; no SNAT, so the client IP is preserved | Nodes without a local endpoint **drop** the traffic. The LB must health-check `healthCheckNodePort` |
| `internalTrafficPolicy: Local` | In-cluster traffic only to endpoints on the same node | Pods on nodes without an endpoint get timeouts (not failover) |
| `trafficDistribution: PreferClose` | Prefer same-zone endpoints (via EndpointSlice hints) | Uneven zone capacity leads to hot spots |
| `sessionAffinity: ClientIP` | Sticky per source IP | Behind SNAT, every client looks like one IP |

```
$ kubectl -n demo get svc web-local -o jsonpath='{.spec.healthCheckNodePort}{"\n"}'
31642
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.3:31642/healthz   # node WITH endpoints
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.18.0.4:31642/healthz   # node WITHOUT endpoints
503
```

That 503 is what the cloud load balancer uses to take the node out of rotation.

---

## 7. Verification and failure diagnosis

### 7.1 Systematic ladder (run top to bottom)

```
$ kubectl -n demo get svc web -o wide                                   # 1. Service exists, selector correct
NAME   TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE   SELECTOR
web    NodePort   10.96.120.15   <none>        80:30080/TCP   20m   app=web

$ kubectl -n demo get endpointslices -l kubernetes.io/service-name=web \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'   # 2. ready endpoints
10.244.1.5 ready=true
10.244.2.7 ready=true
10.244.2.8 ready=true

$ kubectl -n demo run probe --rm -it --restart=Never \
    --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- \
    sh -c 'for i in 1 2 3 4 5 6; do curl -s web/hostname; echo; done'  # 3. ClusterIP from a Pod
web-6d9c7b8f5c-2kqzp
web-6d9c7b8f5c-v9xbn
web-6d9c7b8f5c-2kqzp
web-6d9c7b8f5c-lr4tw
web-6d9c7b8f5c-v9xbn
web-6d9c7b8f5c-lr4tw
pod "probe" deleted

$ curl -s http://10.244.1.5:8080/hostname                               # 4. bypass the Service (from a node)
web-6d9c7b8f5c-2kqzp
```

Reading the ladder: if step 4 works but step 3 fails, the **service proxy** is the problem, not the CNI or the app. If step 4 also fails, it is Pod networking, meaning CNI or NetworkPolicy.

### 7.2 Proxy-level checks

```
$ kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
NAME               READY   STATUS    RESTARTS   AGE   IP           NODE
kube-proxy-4hx9d   1/1     Running   0          2d    172.18.0.3   kp-nft-worker
kube-proxy-8zq2m   1/1     Running   0          2d    172.18.0.4   kp-nft-worker2
kube-proxy-lcw7t   1/1     Running   0          2d    172.18.0.2   kp-nft-control-plane

$ kubectl -n kube-system logs kube-proxy-4hx9d | grep -Ei 'error|fail' | tail -3

$ curl -s http://127.0.0.1:10249/metrics | grep -E '^kubeproxy_sync_proxy_rules_(duration_seconds_(sum|count)|last_timestamp_seconds)'
kubeproxy_sync_proxy_rules_duration_seconds_sum 14.8821
kubeproxy_sync_proxy_rules_duration_seconds_count 912
kubeproxy_sync_proxy_rules_last_timestamp_seconds 1.7592251e+09

$ curl -s http://127.0.0.1:10256/healthz
{"lastUpdated": "2026-09-30 10:44:11.2 +0000 UTC","currentTime": "2026-09-30 10:44:12.9 +0000 UTC", "nodeEligible": true}
```

The average sync is `sum/count` (≈ 16 ms here). Alert when `time() - kubeproxy_sync_proxy_rules_last_timestamp_seconds` grows while endpoints are changing, and on the p99 of `kubeproxy_sync_proxy_rules_duration_seconds`. Also watch `kubeproxy_network_programming_duration_seconds`: it measures the time from an endpoint change to programmed rules, which is the SLI users actually feel.

### 7.3 conntrack

```
$ sudo conntrack -L -d 10.96.120.15 2>/dev/null | head -2
tcp      6 86397 ESTABLISHED src=10.244.2.9 dst=10.96.120.15 sport=43120 dport=80 src=10.244.1.5 dst=10.244.2.9 sport=8080 dport=43120 [ASSURED] mark=0 use=1

$ sudo conntrack -S | awk '{print $1,$4,$5,$6}' | head -2
cpu=0 insert_failed=0 drop=0 early_drop=0
cpu=1 insert_failed=0 drop=0 early_drop=0

$ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_count = 18342
net.netfilter.nf_conntrack_max = 262144
```

The reply tuple (`src=10.244.1.5`) shows which backend the DNAT picked. A rising `insert_failed` points to the SNAT source-port race, which shows up as occasional 1–5 s DNS delays. Rising `drop`/`early_drop` means the table is full: raise `conntrack.maxPerCore`/`min`.

### 7.4 Failure catalogue

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| ClusterIP times out, Pod IP works | kube-proxy down, or wrong mode or rules missing on that node | `curl :10249/proxyMode`; `nft list table ip kube-proxy` / `iptables-save \| grep <svc>` | Restart the kube-proxy Pod; check its logs for kernel module / nft errors |
| New nodes stay `NotReady` after kube-proxy removal | CNI agent can't reach `10.96.0.1` | CNI agent logs: `dial tcp 10.96.0.1:443: i/o timeout` | Set `k8sServiceHost`/`k8sServicePort` (Cilium) or `kubernetes-services-endpoint` (Calico) |
| Intermittent resets, "works sometimes" | kube-proxy **and** eBPF KPR both active | `iptables-save \| grep -c KUBE-SVC` > 0 while `KubeProxyReplacement: True` | Remove kube-proxy and flush the `KUBE-*` rules on each node |
| NodePort works on node IP but not `localhost:30080` | `nftables` mode (by design) or `localhostNodePorts: false` | `/proxyMode` | Use the node IP; don't rely on localhost NodePorts |
| DNS resolves slowly for ~5 s after CoreDNS rollout | Stale UDP conntrack or SNAT race | `conntrack -L -p udp --dport 53`; `conntrack -S` insert_failed | Upgrade kube-proxy; NodeLocal DNSCache; `conntrack -D -p udp --dport 53` |
| eTP Local Service drops traffic on some nodes | No local endpoint; LB not using `healthCheckNodePort` | `curl node:<hcnp>/healthz` → 503 | Configure the LB health check, or spread replicas with topology constraints |
| After an ipvs→nftables switch, some ClusterIPs answer oddly | Leftover `kube-ipvs0` addresses / IPVS entries | `ip addr show kube-ipvs0`; `ipvsadm -Ln` | `ip link del kube-ipvs0`; `ipvsadm -C`, or reboot the node |
| `tcpdump` in the client Pod never shows the ClusterIP | Socket-level LB (eBPF): **not a bug** | `cilium-dbg status --verbose \| grep -A3 'Socket LB'` | Capture on the backend IP; use Hubble for Service-level flow visibility |
| Backends see the node IP instead of the client | SNAT with `externalTrafficPolicy: Cluster` | Log `X-Forwarded-For` / `remote_addr` in the app | eTP Local, DSR (eBPF), or PROXY protocol at the LB |

### 7.5 Cilium-specific datapath inspection

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list | grep 10.96.120.15
10.96.120.15:80/TCP (0)      0.0.0.0:0 (5) (0) [ClusterIP, non-routable]
10.96.120.15:80/TCP (1)      10.244.1.5:8080/TCP (5) (1)
10.96.120.15:80/TCP (2)      10.244.2.7:8080/TCP (5) (2)
10.96.120.15:80/TCP (3)      10.244.2.8:8080/TCP (5) (3)

$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop
Listening for events on 8 CPUs with 64x4096 of shared memory
xx drop (Service backend not found) flow 0x0 to endpoint 0, ifindex 5, file bpf_lxc.c:..., , identity 12345->unknown: 10.244.2.9:51112 -> 10.96.99.99:80 tcp SYN
```

`Service backend not found` is the eBPF equivalent of kube-proxy's reject for a Service with no endpoints. Check the EndpointSlice readiness before you blame the dataplane.

---

## 8. Exam-oriented practice tasks

1. **Identify the mode.** On a given node, determine the kube-proxy mode *without* reading the ConfigMap. (`curl 127.0.0.1:10249/proxyMode`, or look for the `ip kube-proxy` nft table / `KUBE-SERVICES` chain / `kube-ipvs0`.)
2. **Switch the mode.** Change a cluster from `iptables` to `nftables`, restart the DaemonSet, and prove that the `KUBE-SVC-*` chains are gone and the `service-ips` map is populated.
3. **Trace a Service.** For `demo/web`, show which chain or map entry selects the backend, and which conntrack entry proves a given connection went to `10.244.2.7`.
4. **Replace kube-proxy.** Enable Cilium KPR, remove kube-proxy, and show `KubeProxyReplacement: True` with zero `KUBE-SVC` rules. Then restart a node and prove it becomes `Ready` (this validates `k8sServiceHost`).
5. **Preserve the client IP.** Make `web` preserve the client source IP for NodePort traffic, and explain which nodes return 503 on `healthCheckNodePort` and why.

---

## Referencias

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes: Virtual IPs and Service Proxies: https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes: kube-proxy configuration API (v1alpha1): https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Kubernetes: kube-proxy command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Kubernetes blog: NFTables mode for kube-proxy: https://kubernetes.io/blog/2025/02/28/nftables-kube-proxy/
- KEP-3866: nftables kube-proxy backend: https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/3866-nftables-proxy
- Kubernetes: Service concepts (traffic policies, session affinity): https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes: Service Internal Traffic Policy: https://kubernetes.io/docs/concepts/services-networking/service-traffic-policy/
- Kubernetes: Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes: Cluster Networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- kubeadm configuration (v1beta4): https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- CNI specification: https://github.com/containernetworking/cni/blob/main/SPEC.md
- Cilium: Kubernetes without kube-proxy: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Calico: Enable the eBPF dataplane: https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf
- Antrea: AntreaProxy: https://antrea.io/docs/main/docs/antrea-proxy/
- kube-router documentation: https://www.kube-router.io/docs/
- kind configuration (kubeProxyMode, disableDefaultCNI): https://kind.sigs.k8s.io/docs/user/configuration/