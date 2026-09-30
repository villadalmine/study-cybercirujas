# Topic 1.3: Using Linux Tools (iptables, ip, tcpdump) for Packet-level Issues

> **Exam weight: 3.0** · Certification: CKNE (Certified Kubernetes Network Engineer)
> Official certification page: https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/

---

## 1. Motivation: the architectural problem in production

Kubernetes networking is built from abstractions: Services, Endpoints/EndpointSlices, NetworkPolicies and CNI plugins. None of them moves packets. In the default dataplanes, every one of them ends up as a few kernel objects on each node:

| Kubernetes abstraction | What it becomes in the Linux kernel |
|---|---|
| Pod IP / Pod network | A network namespace, a `veth` pair, routes, sometimes a bridge (`cni0`) |
| Cross-node Pod traffic | Routes plus a tunnel device (`flannel.1`, `vxlan.calico`, `tunl0`, `genev_sys_6081`) or native routes via BGP |
| ClusterIP / NodePort Service | `iptables` NAT chains (`KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*`), `nftables` maps, IPVS virtual servers, or eBPF maps |
| NetworkPolicy | `iptables`/`nftables` filter chains (Calico `cali-*`, kube-router), or eBPF programs (Cilium) |
| Connection affinity / NAT state | `nf_conntrack` entries |

When `kubectl` reports everything as `Running` and `Ready` but requests still time out, the problem is in these kernel objects, and the only way to see them is at packet level. Most production networking incidents fall into a few categories:

1. **Silent drops.** A SYN leaves the client and never gets an answer. The cause could be a NetworkPolicy, a `FORWARD` policy of `DROP`, `rp_filter`, a missing route, or a full conntrack table.
2. **Wrong translation.** DNAT sends traffic to a stale or unintended endpoint, or SNAT/MASQUERADE is missing, so the reply takes an asymmetric path and gets dropped.
3. **Size problems.** Small requests work and large ones hang, because the overlay MTU is lower than the Pod MTU and Path MTU Discovery (PMTUD) is being blackholed.
4. **State problems.** UDP conntrack entries still point to a deleted Pod (DNS), or `insert_failed` races drop the first packet of a connection.

The CKNE expects you to **locate the hop where the packet dies** and prove it with evidence, not guesses. The method is always the same: *follow the packet, count at every hop, and compare what enters with what leaves.*

---

## 2. Mental model: the packet path of Pod → ClusterIP → remote Pod

Reference scenario: kube-proxy in `iptables` mode, CNI with a bridge plus VXLAN overlay (Flannel-style). Client Pod `10.244.1.5` on `worker-1` (`192.168.1.11`) calls Service `10.96.120.15:80`, which is backed by Pod `10.244.2.8:8080` on `worker-2` (`192.168.1.12`).

```
worker-1                                                          worker-2
┌──────────────────────────────────────────────┐        ┌────────────────────────────────────┐
│ Pod netns   eth0 (10.244.1.5)                │        │ Pod netns   eth0 (10.244.2.8)      │
│              │  [capture A]                  │        │              ▲  [capture H]        │
│ host netns  vethXXXX ──► cni0 (bridge)       │        │ host netns  vethYYYY ◄── cni0      │
│              [B]           │                 │        │              [G]          ▲        │
│   PREROUTING  raw → mangle → nat             │        │   PREROUTING / FORWARD / POSTROUTING│
│      nat/KUBE-SERVICES → KUBE-SVC → KUBE-SEP │        │              │                     │
│      DNAT 10.96.120.15:80 → 10.244.2.8:8080  │        │   flannel.1 (decap)  [F]           │
│   routing decision: 10.244.2.0/24 dev flannel.1       │              ▲                     │
│   FORWARD  filter (KUBE-FORWARD, CNI chains) │        │   eth0 UDP/8472      [E]           │
│   POSTROUTING nat (KUBE-POSTROUTING: MASQ?)  │        │              ▲                     │
│   flannel.1 (encap)  [C]                     │        │              │                     │
│   eth0 → UDP 192.168.1.11 → 192.168.1.12:8472 [D] ───────────────────┘                     │
└──────────────────────────────────────────────┘        └────────────────────────────────────┘
```

Four details that trip people up:

- **DNAT happens in `PREROUTING` on the client's node.** On the wire, and on the destination node, the packet's destination is already the Pod IP (`10.244.2.8`). If you capture for the ClusterIP on `worker-2`, you will never see it.
- **Traffic between Pods on the same bridge goes through iptables only if `br_netfilter` is loaded and `net.bridge.bridge-nf-call-iptables=1`.** Without it, ClusterIP DNAT does not apply to bridged frames, and the hairpin and same-node Service cases break.
- **Replies are translated back by conntrack, not by rules.** Only the first packet of a connection traverses the `nat` table. Everything after it uses the conntrack entry. This is why deleting a rule doesn't affect established flows, and why stale entries survive endpoint changes.
- **ClusterIP is not bound to any interface** in iptables/nftables mode. `ping 10.96.120.15` fails by design, because only the port/protocol tuples are translated. In IPVS mode the IP *is* assigned to the `kube-ipvs0` dummy interface, and ICMP to it may get an answer.

---

## 3. Technical comparisons and trade-offs

### 3.1 The toolset: what each tool proves

| Tool | Question it answers | Layer | Strength | Blind spot |
|---|---|---|---|---|
| `ip link` / `ip -s link` | Is the interface up? What MTU? Are there RX/TX drops? | L2 | Per-interface counters, veth peer index (`@ifN`) | Doesn't say *why* a packet was dropped |
| `ip addr` | Which IPs live where? | L3 | Detects duplicate or missing IPs | — |
| `ip route` / `ip route get` | Where will the kernel send *this* packet? | L3 | `route get` runs the real FIB lookup, including policy rules | Doesn't account for later netfilter rewrites (DNAT happens before routing only in PREROUTING) |
| `ip rule` | Which routing table applies? | L3 | Required for Cilium, AWS VPC CNI, multi-homing | — |
| `ip neigh` / `bridge fdb` | Is L2 resolution OK (ARP, VXLAN FDB)? | L2 | Detects `FAILED`/`INCOMPLETE` entries and missing VTEP entries | — |
| `ip netns` / `nsenter` | Run the tools *inside* the Pod's namespace | — | Pod view without an image that includes the tools | Needs root on the node |
| `iptables-save` / `iptables -L -v -n` | Which rules exist, and which ones match (counters)? | L3/L4 | Counters prove whether a rule matched | Blind to eBPF dataplanes; backend (legacy vs nft) must match the one writing the rules |
| `nft list ruleset` | Same for the nftables backend / kube-proxy `nftables` mode | L3/L4 | Sees *everything* written through `iptables-nft` as well | Verbose |
| `conntrack -L/-E/-S` | Which translation was applied to *this* connection? Is the table full? | L3/L4 | The only view of the real NAT of an established flow | Requires `conntrack-tools` |
| `tcpdump` | Did the packet pass through this point, and how did it look? | L2–L7 | Ground truth per capture point | One point per capture; eBPF may redirect packets around the host's capture points |
| `ss -tanp` / `nstat` | Sockets and kernel counters (retransmits, `ListenDrops`) | L4 | Proves the process is listening; SYN backlog saturation | — |

### 3.2 Service dataplanes: where to look

| kube-proxy / dataplane mode | Kernel objects | Primary inspection command | Scales to | Diagnostic notes |
|---|---|---|---|---|
| `iptables` (historical default) | `nat` chains `KUBE-SERVICES` → `KUBE-SVC-*`/`KUBE-EXT-*` → `KUBE-SEP-*` | `iptables-save -t nat` | Thousands of Services; linear evaluation per first packet | Counters per chain; `statistic --mode random` load balancing |
| `nftables` (GA in recent Kubernetes versions) | Table `ip kube-proxy` / `ip6 kube-proxy`, verdict maps | `nft list table ip kube-proxy` | Better: O(1) lookup through maps | `iptables-save` **does not** show these rules |
| `ipvs` | IPVS virtual servers + ipsets + few iptables rules | `ipvsadm -Ln`, `ipset list` | Tens of thousands | ClusterIP is assigned to `kube-ipvs0`; still depends on iptables for MASQ |
| Cilium / eBPF kube-proxy replacement | BPF maps attached to tc/XDP/cgroup | `cilium-dbg service list`, `cilium-dbg monitor`, Hubble | Very high | Socket-level load balancing translates **before** the packet exists: the Pod's `tcpdump` shows the backend IP, not the ClusterIP |

**Key trade-off:** the more efficient the dataplane, the less visible it is to classic tools. In an eBPF cluster, `iptables` tells you almost nothing about Services. `tcpdump` and `ip` are still useful, but you need to know that the capture point may sit *after* the translation.

### 3.3 iptables backends: legacy vs nf_tables

| Aspect | `iptables-legacy` | `iptables-nft` |
|---|---|---|
| Kernel API | `x_tables` (setsockopt) | `nf_tables` (netlink) |
| `iptables -V` shows | `iptables v1.8.x (legacy)` | `iptables v1.8.x (nf_tables)` |
| Visible in `nft list ruleset` | No | Yes (as `table ip nat`, etc.) |
| Tracing | `-j TRACE` → kernel log | `-j TRACE` → `xtables-monitor --trace` |
| Classic failure | **Mixing them**: kube-proxy writes with one backend and you inspect with the other. The rules "don't exist", but they are there, and both rulesets apply |

Always check this first: `iptables -V` on the node and inside the kube-proxy/CNI container. Both must show the same backend.

### 3.4 Where to capture with tcpdump

| Capture point | What you see | Useful for |
|---|---|---|
| Pod `eth0` (via `nsenter`/ephemeral container) | Exactly what the application sends and receives (pre-DNAT in iptables mode) | "Is the app sending at all?", RSTs from the app |
| Host `veth*` | The same packets from the host side | Confirms the veth isn't losing packets; does not require entering the netns |
| `cni0` bridge | Traffic of all local Pods | Same-node traffic, hairpin |
| Tunnel device (`flannel.1`, `vxlan.calico`, `tunl0`) | Inner packets, already DNAT'd, *before* encapsulation | Is DNAT correct? Is MASQ applied? |
| Physical `eth0` | Encapsulated packets (UDP 8472/4789, IP proto 4, UDP 6081) | Does the overlay leave the node? Is it blocked by a cloud security group/firewall? |
| `-i any` | Everything, using the Linux "cooked" header (tcpdump ≥ 4.99 prints interface and direction) | Quick first look, correlating hops on a single timeline |

---

## 4. Laboratory: complete manifests

All the commands in the following sections run against this environment. Apply it on any cluster with a bridge + VXLAN CNI (Flannel), or adjust the interface names for Calico/Cilium.

### 4.1 Namespace, backend and Service

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netlab
  labels:
    kubernetes.io/metadata.name: netlab
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: netlab
  labels:
    app: web
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
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: web
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.52
          args:
            - netexec
            - --http-port=8080
            - --udp-port=8081
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: udp
              containerPort: 8081
              protocol: UDP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: netlab
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
    - name: udp
      port: 8081
      targetPort: udp
      protocol: UDP
---
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
  namespace: netlab
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080
      protocol: TCP
```

### 4.2 Client with network tools

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: client
  namespace: netlab
  labels:
    role: client
spec:
  containers:
    - name: netshoot
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 128Mi
```

`tcpdump` needs `NET_RAW` to open an `AF_PACKET` socket. `NET_ADMIN` lets you change routes and MTU inside the Pod (for example, to test PMTU hypotheses).

### 4.3 Privileged diagnostics Pod on the node (host netns)

When you don't have SSH to the node, this Pod gives you `iptables`, `nft`, `conntrack`, `ip` and `tcpdump` in the **host** namespace, plus access to the Pods' netns through `hostPID` + `nsenter`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nettools-worker-1
  namespace: kube-system
  labels:
    app: nettools
spec:
  nodeName: worker-1
  hostNetwork: true
  hostPID: true
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: nettools
      image: nicolaka/netshoot:v0.13
      command: ["sleep", "infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: run-netns
          mountPath: /run/netns
          mountPropagation: HostToContainer
        - name: xtables-lock
          mountPath: /run/xtables.lock
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
  volumes:
    - name: run-netns
      hostPath:
        path: /run/netns
        type: Directory
    - name: xtables-lock
      hostPath:
        path: /run/xtables.lock
        type: FileOrCreate
    - name: lib-modules
      hostPath:
        path: /lib/modules
        type: Directory
```

Mounting `/run/xtables.lock` is not cosmetic. If you run `iptables` without sharing the lock with kube-proxy and the CNI, you can race with them while they rewrite the ruleset.

> Equivalent without YAML: `kubectl debug node/worker-1 -it --image=nicolaka/netshoot:v0.13 --profile=sysadmin`. The node's filesystem is mounted at `/host`, and the Pod runs with `hostNetwork`/`hostPID`.

### 4.4 NetworkPolicy used in the drop scenario

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: netlab
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-web
  namespace: netlab
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: client
      ports:
        - protocol: TCP
          port: 8080
```

Note that the policy's `port` is **8080 (the Pod's `targetPort`)**, not 80. NetworkPolicies are evaluated after DNAT, against the real Pod IP and port. Writing the Service port here is a classic production mistake, and `tcpdump` finds it in seconds.

---

## 5. `ip`: interfaces, routes and namespaces

### 5.1 From Pod to node: finding the veth peer

Inside the Pod:

```
$ kubectl -n netlab exec client -- ip -d link show eth0
2: eth0@if14: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP mode DEFAULT group default
    link/ether 6e:1f:4a:9c:22:01 brd ff:ff:ff:ff:ff:ff link-netnsid 0 promiscuity 0
    veth addrgenmode eui64 numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535

$ kubectl -n netlab exec client -- cat /sys/class/net/eth0/iflink
14
```

`@if14` / `iflink=14` is the **ifindex of the peer in the host netns**. On the node:

```
$ ip -o link | awk -F': ' '$1 == 14 {print $2}'
veth3c1a9f2e@if2

$ ip link show veth3c1a9f2e
14: veth3c1a9f2e@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master cni0 state UP mode DEFAULT group default
    link/ether 9a:b4:0c:71:e8:5d brd ff:ff:ff:ff:ff:ff link-netns cni-4b7f1e0a-2c3d-9e8f-1a2b-3c4d5e6f7a8b
```

`master cni0` confirms the port is on the bridge. `link-netns cni-...` is the name of the netns that the CNI/containerd created under `/run/netns`.

### 5.2 Entering the Pod netns from the node

```
$ crictl pods --name client --namespace netlab -q
7f3e9a1c2b4d5e6f...

$ crictl ps --pod 7f3e9a1c2b4d -q
c81d2e3f4a5b...

$ PID=$(crictl inspect --output go-template --template '{{.info.pid}}' c81d2e3f4a5b)
$ echo $PID
48213

$ nsenter -t $PID -n ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if14        UP             10.244.1.5/24 fe80::6c1f:4aff:fe9c:2201/64

$ nsenter -t $PID -n ip route
default via 10.244.1.1 dev eth0
10.244.0.0/16 via 10.244.1.1 dev eth0
10.244.1.0/24 dev eth0 proto kernel scope link src 10.244.1.5
```

`nsenter -n` enters **only** the network namespace. The tools come from the node's filesystem, so you can run `tcpdump` against a distroless Pod that has no shell. Alternative: `ip netns exec cni-4b7f1e0a-... ip addr`.

From the API, without node access:

```
$ kubectl -n netlab debug -it pod/web-6d9c7b8f5-abcde --image=nicolaka/netshoot:v0.13 --target=web --profile=netadmin -- tcpdump -nn -i eth0 port 8080
```

The ephemeral container shares the Pod's netns. `--profile=netadmin` adds `NET_ADMIN` and `NET_RAW`.

### 5.3 `ip route get`: the real lookup

`ip route show` lists routes. `ip route get` **runs the FIB lookup**, including `ip rule`, and tells you the device, gateway and source address the kernel will use:

```
# On worker-1 (Flannel VXLAN)
$ ip route get 10.244.2.8
10.244.2.8 via 10.244.2.0 dev flannel.1 src 10.244.1.0 uid 0
    cache

# Lookup as if the packet came in from the Pod veth (simulates forwarding)
$ ip route get 10.244.2.8 from 10.244.1.5 iif cni0
10.244.2.8 from 10.244.1.5 via 10.244.2.0 dev flannel.1
    cache iif cni0

# Calico IPIP: route learned via BGP (proto bird) through tunl0
$ ip route get 10.244.2.8
10.244.2.8 via 192.168.1.12 dev tunl0 src 10.244.1.0 uid 0
    cache

# Symptom: missing route → falls to the default gateway (the packet leaves the cluster)
$ ip route get 10.244.3.4
10.244.3.4 via 192.168.1.1 dev eth0 src 192.168.1.11 uid 0
    cache
```

The last case is a strong signal. The Pod CIDR of the node hosting `10.244.3.0/24` never got installed. Causes include a flanneld/calico-node that failed on that node, a BGP session that isn't `Established`, or a node without `spec.podCIDR`.

With a failing `iif` lookup:

```
$ ip route get 10.244.2.8 from 10.244.9.9 iif eth0
RTNETLINK answers: Invalid cross-device link
```

This means `rp_filter` in strict mode would reject that source on that interface (see §8.5).

### 5.4 L2 in the overlay: `ip neigh` and `bridge fdb`

In Flannel VXLAN, each remote node has three entries: a route, a static ARP entry for its `flannel.1` address, and an FDB entry that maps that MAC to the node's IP (VTEP):

```
$ ip -d link show flannel.1
5: flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default
    link/ether 5e:8a:31:0f:c2:77 brd ff:ff:ff:ff:ff:ff promiscuity 0
    vxlan id 1 local 192.168.1.11 dev eth0 srcport 0 0 dstport 8472 nolearning ttl auto ageing 300 udpcsum noudp6zerocsumtx noudp6zerocsumrx

$ ip neigh show dev flannel.1
10.244.2.0 lladdr 7a:11:4d:e3:90:0c PERMANENT
10.244.0.0 lladdr 1e:c2:88:5a:07:3f PERMANENT

$ bridge fdb show dev flannel.1
7a:11:4d:e3:90:0c dst 192.168.1.12 self permanent
1e:c2:88:5a:07:3f dst 192.168.1.10 self permanent
```

Read the line `vxlan id 1 ... dstport 8472`: VNI 1 and UDP port 8472 (the Linux kernel's historical port, used by Flannel). The IANA standard is 4789, and Calico VXLAN uses 4789. If a firewall between nodes only opens 4789 and the CNI uses 8472, the overlay dies silently.

A missing FDB entry for a node means `tcpdump -i flannel.1` shows the packet leaving, while `tcpdump -i eth0 udp port 8472` shows nothing. The encapsulation has nowhere to send it.

### 5.5 Counters: `ip -s link`

```
$ ip -s link show veth3c1a9f2e
14: veth3c1a9f2e@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master cni0 state UP mode DEFAULT group default
    link/ether 9a:b4:0c:71:e8:5d brd ff:ff:ff:ff:ff:ff link-netns cni-4b7f1e0a-2c3d-9e8f-1a2b-3c4d5e6f7a8b
    RX:  bytes packets errors dropped  missed   mcast
       1843210   12044      0       0       0       0
    TX:  bytes packets errors dropped carrier collsns
       2210987   11873      0     412       0       0
```

A non-zero `TX dropped` on the host veth usually means the peer end (the Pod) couldn't receive: the Pod's receive queue is full, or the netns is being destroyed. Take a snapshot, reproduce, and compare the deltas. An absolute counter without a baseline proves nothing.

---

## 6. `iptables` / `nft`: reading kube-proxy and the policy chains

### 6.1 Identify the backend and the mode first

```
$ iptables -V
iptables v1.8.10 (nf_tables)

$ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
mode: iptables

$ curl -s http://localhost:10249/proxyMode
iptables
```

(`:10249` is kube-proxy's metrics/health port on the node. `/proxyMode` returns the active mode.)

### 6.2 Walking the chain of one Service

```
$ iptables-save -t nat | grep 'netlab/web:http'
-A KUBE-SERVICES -d 10.96.120.15/32 -p tcp -m comment --comment "netlab/web:http cluster IP" -m tcp --dport 80 -j KUBE-SVC-XQ3KZ2C7M5RDJW4A
-A KUBE-SVC-XQ3KZ2C7M5RDJW4A ! -s 10.244.0.0/16 -d 10.96.120.15/32 -p tcp -m comment --comment "netlab/web:http cluster IP" -m tcp --dport 80 -j KUBE-MARK-MASQ
-A KUBE-SVC-XQ3KZ2C7M5RDJW4A -m comment --comment "netlab/web:http -> 10.244.1.12:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-2LQJ6MZ7HXJ4TQ5N
-A KUBE-SVC-XQ3KZ2C7M5RDJW4A -m comment --comment "netlab/web:http -> 10.244.2.8:8080" -j KUBE-SEP-V7N3JQ2PZK5W6YHC
-A KUBE-SEP-2LQJ6MZ7HXJ4TQ5N -s 10.244.1.12/32 -m comment --comment "netlab/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-2LQJ6MZ7HXJ4TQ5N -p tcp -m comment --comment "netlab/web:http" -m tcp -j DNAT --to-destination 10.244.1.12:8080
-A KUBE-SEP-V7N3JQ2PZK5W6YHC -s 10.244.2.8/32 -m comment --comment "netlab/web:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-V7N3JQ2PZK5W6YHC -p tcp -m comment --comment "netlab/web:http" -m tcp -j DNAT --to-destination 10.244.2.8:8080
```

How to read it:

| Rule | Meaning |
|---|---|
| `KUBE-SERVICES ... -j KUBE-SVC-*` | Match on ClusterIP:port → jump to the Service chain |
| `! -s 10.244.0.0/16 ... -j KUBE-MARK-MASQ` | If the source is **outside** the Pod CIDR (e.g. a process in the host netns), mark it for SNAT so the reply comes back through this node |
| `statistic --mode random --probability 0.5` | Load balancing. With N endpoints, rule *i* has probability 1/(N−i+1), and the last one has no condition. It is random per connection, not round-robin |
| `KUBE-SEP-* -s <own IP> -j KUBE-MARK-MASQ` | **Hairpin**: if the Pod calls its own Service and lands on itself, it must be SNAT'd, or the reply would bypass conntrack |
| `DNAT --to-destination` | The real translation |

The marking and SNAT mechanism:

```
$ iptables-save -t nat | grep -E 'KUBE-MARK-MASQ|KUBE-POSTROUTING' | grep -- '-A'
-A POSTROUTING -m comment --comment "kubernetes postrouting rules" -j KUBE-POSTROUTING
-A KUBE-MARK-MASQ -j MARK --set-xmark 0x4000/0x4000
-A KUBE-POSTROUTING -m mark ! --mark 0x4000/0x4000 -j RETURN
-A KUBE-POSTROUTING -j MARK --set-xmark 0x4000/0x0
-A KUBE-POSTROUTING -m comment --comment "kubernetes service traffic requiring SNAT" -j MASQUERADE --random-fully
```

Bit `0x4000` of the fwmark is the contract between `PREROUTING`, which decides, and `POSTROUTING`, which executes. If another component (a CNI, a service mesh, an agent) reuses that bit, you get phantom SNAT, or SNAT that goes missing.

NodePort traffic passes through `KUBE-NODEPORTS` and `KUBE-EXT-*` chains. `KUBE-EXT-*` is where `externalTrafficPolicy: Cluster` (MASQ always) and `Local` (no MASQ, local endpoints only) differ:

```
$ iptables-save -t nat | grep -E 'KUBE-NODEPORTS.*30080|KUBE-EXT-.*netlab/web-nodeport' | head -4
-A KUBE-NODEPORTS -p tcp -m comment --comment "netlab/web-nodeport:http" -m tcp --dport 30080 -j KUBE-EXT-PL4RZ7Q2W9B3KF6D
-A KUBE-EXT-PL4RZ7Q2W9B3KF6D -m comment --comment "masquerade traffic for netlab/web-nodeport:http external destinations" -j KUBE-MARK-MASQ
-A KUBE-EXT-PL4RZ7Q2W9B3KF6D -j KUBE-SVC-PL4RZ7Q2W9B3KF6D
```

### 6.3 A Service with no endpoints

When no endpoint is `Ready`, kube-proxy doesn't generate a `KUBE-SVC` chain in `nat`. It installs a REJECT in the `filter` table instead:

```
$ iptables-save -t filter | grep 'netlab/web:http'
-A KUBE-SERVICES -d 10.96.120.15/32 -p tcp -m comment --comment "netlab/web:http has no endpoints" -m tcp --dport 80 -j REJECT --reject-with icmp-port-unreachable
```

The client sees `Connection refused` **immediately**, not a timeout. That difference alone tells you where to look:

| Client symptom | Most likely cause |
|---|---|
| `Connection refused` instantly | Service with no Ready endpoints (kube-proxy REJECT), or Pod not listening on `targetPort` (RST from the Pod) |
| Timeout (SYN retransmitted) | Silent drop: NetworkPolicy, firewall, missing route, broken overlay, `rp_filter` |
| Connects, but stalls on large responses | MTU / PMTUD |
| Works intermittently (~1/N) | One of the N endpoints is broken or unreachable from this node |

### 6.4 Counters: proving a rule matches

```
$ iptables -t nat -L KUBE-SVC-XQ3KZ2C7M5RDJW4A -n -v -x --line-numbers
Chain KUBE-SVC-XQ3KZ2C7M5RDJW4A (1 references)
num      pkts      bytes target                     prot opt in     out     source               destination
1           0          0 KUBE-MARK-MASQ             tcp  --  *      *      !10.244.0.0/16        10.96.120.15         /* netlab/web:http cluster IP */ tcp dpt:80
2          37       2220 KUBE-SEP-2LQJ6MZ7HXJ4TQ5N  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* netlab/web:http -> 10.244.1.12:8080 */ statistic mode random probability 0.50000000000
3          41       2460 KUBE-SEP-V7N3JQ2PZK5W6YHC  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* netlab/web:http -> 10.244.2.8:8080 */ statistic mode random probability 0.50000000000
```

In `nat`, the counters count **connections** (first packets), not total packets. To watch them change live:

```
$ watch -n1 -d 'iptables -t nat -L KUBE-SVC-XQ3KZ2C7M5RDJW4A -n -v -x'
```

To reset a chain's counters without touching the rules (safe, but it wipes the evidence other people might be looking at): `iptables -t nat -Z KUBE-SVC-XQ3KZ2C7M5RDJW4A`.

Don't use `-L` without `-n` in production. It resolves every IP through DNS and can hang for minutes precisely when DNS is broken.

### 6.5 Filter chains: FORWARD and the default policy

```
$ iptables -L FORWARD -n -v --line-numbers | head -8
Chain FORWARD (policy DROP 1287 packets, 77220 bytes)
num   pkts bytes target            prot opt in     out     source               destination
1     912K  611M KUBE-PROXY-FIREWALL  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate NEW /* kubernetes load balancer firewall */
2     912K  611M KUBE-FORWARD      all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes forwarding rules */
3     912K  611M KUBE-SERVICES     all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate NEW /* kubernetes service portals */
4     912K  611M KUBE-EXTERNAL-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ctstate NEW /* kubernetes externally-visible service portals */
5     903K  609M FLANNEL-FWD       all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* flanneld forward */
```

`policy DROP 1287 packets` is the evidence. 1287 packets reached the end of `FORWARD` without an explicit ACCEPT. Docker installed on the same node sets `FORWARD` to `DROP`, which is a classic cause of broken cross-node traffic on hand-built clusters. If that counter goes up while you reproduce, you've found your drop.

### 6.6 Tracing: which rule does *this* packet hit?

With the nf_tables backend:

```
$ iptables -t raw -I PREROUTING -p tcp -s 10.244.1.5 --dport 80 -j TRACE
$ xtables-monitor --trace
PACKET: 2 7c1e0a4b PREROUTING IN=cni0 MACSRC=6e:1f:4a:9c:22:1 MACDST=e2:5b:10:aa:7c:44 MACPROTO=0800 SRC=10.244.1.5 DST=10.96.120.15 LEN=60 TOS=0x0 TTL=64 ID=51234DF SPORT=41234 DPORT=80 SYN
 TRACE: 2 7c1e0a4b raw:PREROUTING:rule:0x3:CONTINUE  -4 -t raw -A PREROUTING -s 10.244.1.5/32 -p tcp -m tcp --dport 80 -j TRACE
 TRACE: 2 7c1e0a4b nat:PREROUTING:rule:0x5:JUMP:KUBE-SERVICES  -4 -t nat -A PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
 TRACE: 2 7c1e0a4b nat:KUBE-SERVICES:rule:0x1c:JUMP:KUBE-SVC-XQ3KZ2C7M5RDJW4A  ...
 TRACE: 2 7c1e0a4b nat:KUBE-SEP-V7N3JQ2PZK5W6YHC:rule:0x2a:ACCEPT  -4 -t nat -A KUBE-SEP-V7N3JQ2PZK5W6YHC -p tcp ... -j DNAT --to-destination 10.244.2.8:8080
...
$ iptables -t raw -D PREROUTING -p tcp -s 10.244.1.5 --dport 80 -j TRACE
```

With the legacy backend, the trace goes to the kernel log (`dmesg -w` / `journalctl -k -f`) and needs `nf_log_ipv4`. **Always remove the TRACE rule.** It generates a log line per rule traversed for every matching packet, and on a busy node it can saturate the log.

With native nftables (`nft`), the equivalent is `meta nftrace set 1` in a chain with priority `raw`, read with `nft monitor trace`.

### 6.7 kube-proxy in `nftables` mode

```
$ nft list tables
table ip kube-proxy
table ip6 kube-proxy
table ip filter
table ip nat

$ nft list chain ip kube-proxy services
table ip kube-proxy {
	chain services {
		ip daddr . meta l4proto . th dport vmap @service-ips
		ip daddr @nodeport-ips meta l4proto . th dport vmap @service-nodeports
	}
}

$ nft list map ip kube-proxy service-ips | grep 10.96.120.15
		10.96.120.15 . tcp . 80 : goto service-XQ3KZ2C7-netlab/web/tcp/http,
```

(Abridged output. The exact chain names vary between versions.) Keep one practical point in mind: in this mode, `iptables-save` shows **nothing** from kube-proxy. That isn't a bug.

### 6.8 NetworkPolicy chains (Calico as an example)

```
$ iptables-save -t filter | grep -c '^-A cali-'
214

$ iptables -L cali-tw-cali3c1a9f2e4b1 -n -v | head -6
Chain cali-tw-cali3c1a9f2e4b1 (1 references)
 pkts bytes target     prot opt in     out     source               destination
  118  7080 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:... */ ctstate RELATED,ESTABLISHED
    0     0 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:... */ ctstate INVALID
   ...
   23  1380 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* cali:... Drop if no policies passed packet */
```

`cali-tw-<iface>` means *to workload* (ingress to the Pod), and `cali-fw-<iface>` means *from workload* (egress). A counter increasing on the final `DROP` while you reproduce proves the policy is rejecting the traffic. Cilium doesn't use iptables for policy, so the equivalent is `cilium-dbg monitor --type drop` or `hubble observe --verdict DROPPED`.

---

## 7. `tcpdump`: the ground truth

### 7.1 Essential flags

| Flag | Why it matters in production |
|---|---|
| `-nn` | No DNS or port-name resolution. Faster, and it doesn't generate DNS traffic of its own that pollutes the capture |
| `-i <if>` / `-i any` | Capture point. `any` prints interface and direction (`In`/`Out`) in tcpdump ≥ 4.99 |
| `-e` | Shows MACs: useful for ARP/FDB and bridge problems |
| `-v` / `-vv` | TTL, IP ID, DF flag, checksums (`bad cksum` is usually offload, not corruption) |
| `-c N` | Stops after N packets. **Always** use it on production nodes |
| `-s 0` / `-s 128` | Snaplen. The default already captures the full packet. Reduce it for headers only |
| `-w file.pcap` / `-r` | Save for Wireshark, or compare two points afterwards |
| `-p` | Doesn't put the interface in promiscuous mode |
| `-Q in\|out` | Filters by direction (not supported on every interface) |
| `-l` | Line buffering, for piping into `grep` |

### 7.2 Useful BPF filters (pcap-filter)

```
# SYN and RST only: the minimum to diagnose connection establishment
tcpdump -nn -i any 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0 and host 10.244.2.8'

# ICMP "destination unreachable" (includes "frag needed")
tcpdump -nn -i any 'icmp[icmptype] == icmp-unreach'

# Flannel VXLAN on the physical interface (encapsulated view)
tcpdump -nn -i eth0 'udp port 8472'

# Calico IPIP (IP protocol 4) and Geneve (Cilium/OVN)
tcpdump -nn -i eth0 'ip proto 4'
tcpdump -nn -i eth0 'udp port 6081'

# DNS towards CoreDNS
tcpdump -nn -i any 'udp port 53 or tcp port 53'

# Large packets (MTU tests)
tcpdump -nn -i any 'greater 1400 and host 10.244.2.8'
```

### 7.3 Reading a healthy handshake, on two points at once

On `worker-1`, `-i any`, while the client runs `curl http://web.netlab/hostname`:

```
$ tcpdump -nn -i any -c 6 'tcp port 80 or tcp port 8080'
tcpdump: data link type LINUX_SLL2
listening on any, link-type LINUX_SLL2 (Linux cooked v2), snapshot length 262144 bytes
10:14:02.118204 veth3c1a9f2e P   IP 10.244.1.5.41234 > 10.96.120.15.80: Flags [S], seq 3021447788, win 64390, options [mss 1410,sackOK,TS val 912330 ecr 0,nop,wscale 7], length 0
10:14:02.118259 flannel.1 Out IP 10.244.1.5.41234 > 10.244.2.8.8080: Flags [S], seq 3021447788, win 64390, options [mss 1410,sackOK,TS val 912330 ecr 0,nop,wscale 7], length 0
10:14:02.118731 flannel.1 In  IP 10.244.2.8.8080 > 10.244.1.5.41234: Flags [S.], seq 881245120, ack 3021447789, win 64308, options [mss 1410,sackOK,TS val 55012 ecr 912330,nop,wscale 7], length 0
10:14:02.118760 veth3c1a9f2e Out IP 10.96.120.15.80 > 10.244.1.5.41234: Flags [S.], seq 881245120, ack 3021447789, win 64308, options [mss 1410,sackOK,TS val 55012 ecr 912330,nop,wscale 7], length 0
10:14:02.118802 veth3c1a9f2e P   IP 10.244.1.5.41234 > 10.96.120.15.80: Flags [.], ack 1, win 504, length 0
10:14:02.118815 flannel.1 Out IP 10.244.1.5.41234 > 10.244.2.8.8080: Flags [.], ack 1, win 504, length 0
```

Everything is proven in six lines:

- On `veth` the destination is `10.96.120.15:80` (pre-DNAT). On `flannel.1` it is already `10.244.2.8:8080`. **DNAT confirmed.**
- The source stays `10.244.1.5`. There is **no MASQ** for Pod→Service inside the Pod CIDR, which matches `! -s 10.244.0.0/16`.
- The reply returns as `10.96.120.15.80` on the veth. The **conntrack reverse translation** is working.
- `mss 1410` = 1450 (MTU) − 40. The Pod's MTU already accounts for the 50 bytes of VXLAN overhead.

The same flow on the physical interface:

```
$ tcpdump -nn -i eth0 -c 2 'udp port 8472'
10:14:02.118270 IP 192.168.1.11.47823 > 192.168.1.12.8472: OTV, flags [I] (0x08), overlay 0, instance 1
IP 10.244.1.5.41234 > 10.244.2.8.8080: Flags [S], seq 3021447788, win 64390, options [mss 1410,sackOK,TS val 912330 ecr 0,nop,wscale 7], length 0
10:14:02.118725 IP 192.168.1.12.40117 > 192.168.1.11.8472: OTV, flags [I] (0x08), overlay 0, instance 1
IP 10.244.2.8.8080 > 10.244.1.5.41234: Flags [S.], seq 881245120, ack 3021447789, ...
```

tcpdump decodes UDP 8472 as **OTV** by default, because that port is also assigned to OTV. `instance 1` is the VNI. On port 4789 it prints `VXLAN, flags [I] (0x08), vni 1`. To force it: `tcpdump -nn -i eth0 -T vxlan 'udp port 8472'`.

### 7.4 Failure signatures

**Silent drop (NetworkPolicy, firewall, broken overlay):**

```
10:20:11.004120 veth3c1a9f2e P   IP 10.244.1.5.52110 > 10.96.120.15.80: Flags [S], seq 1204498811, win 64390, length 0
10:20:11.004170 flannel.1 Out IP 10.244.1.5.52110 > 10.244.2.8.8080: Flags [S], seq 1204498811, win 64390, length 0
10:20:12.031882 veth3c1a9f2e P   IP 10.244.1.5.52110 > 10.96.120.15.80: Flags [S], seq 1204498811, win 64390, length 0
10:20:12.031921 flannel.1 Out IP 10.244.1.5.52110 > 10.244.2.8.8080: Flags [S], seq 1204498811, win 64390, length 0
10:20:14.079877 veth3c1a9f2e P   IP 10.244.1.5.52110 > 10.96.120.15.80: Flags [S], seq 1204498811, win 64390, length 0
```

The **same `seq`** retransmitted at 1s, 2s, 4s (exponential backoff) is a SYN nobody answers. The next step is capturing on `worker-2`. If the SYN arrives at `flannel.1` there but not at the backend's `veth`, the drop is on the destination node: policy or FORWARD.

**No endpoints / not listening:**

```
10:22:40.550112 veth3c1a9f2e P   IP 10.244.1.5.52330 > 10.96.120.15.80: Flags [S], seq 99812231, win 64390, length 0
10:22:40.550160 veth3c1a9f2e Out IP 10.244.1.1 > 10.244.1.5: ICMP 10.96.120.15 tcp port 80 unreachable, length 68
```

This is the ICMP port unreachable from the kube-proxy REJECT. If the Pod isn't listening on the port instead, you would see `Flags [R.]` coming back from the backend's IP.

**MTU / PMTUD:**

```
10:30:05.771002 flannel.1 Out IP 10.244.1.5.41800 > 10.244.2.8.8080: Flags [P.], seq 1:1399, ack 1, length 1398
10:30:05.771440 eth0  In  IP 192.168.1.1 > 192.168.1.11: ICMP 192.168.1.12 unreachable - need to frag (mtu 1400), length 556
```

Some hop along the way (a VPN, a VLAN with a lower MTU) has an MTU of 1400. If a firewall drops that ICMP, you see the same data segment retransmitted forever, with no ICMP at all. That is the PMTUD blackhole.

---

## 8. Complementary kernel state: conntrack and sysctls

### 8.1 conntrack: the real NAT of each flow

```
$ conntrack -L -p tcp --orig-dst 10.96.120.15 2>/dev/null
tcp      6 86397 ESTABLISHED src=10.244.1.5 dst=10.96.120.15 sport=41234 dport=80 src=10.244.2.8 dst=10.244.1.5 sport=8080 dport=41234 [ASSURED] mark=0 use=1
```

It reads as *original tuple* → *reply tuple*. The reply comes from `10.244.2.8:8080` to `10.244.1.5`, so there was DNAT and no SNAT. With SNAT, the reply tuple's `dst` would be the node's IP.

Events in real time, which are very useful for UDP/DNS:

```
$ conntrack -E -p udp --orig-port-dst 53
    [NEW] udp      17 30 src=10.244.1.5 dst=10.96.0.10 sport=38211 dport=53 [UNREPLIED] src=10.244.0.7 dst=10.244.1.5 sport=53 dport=38211
 [UPDATE] udp      17 30 src=10.244.1.5 dst=10.96.0.10 sport=38211 dport=53 src=10.244.0.7 dst=10.244.1.5 sport=53 dport=38211
```

A **stale entry for UDP**: if `10.244.0.7` (CoreDNS) is deleted and the client keeps reusing the same source port, the entry keeps sending packets to a dead IP. kube-proxy deletes these entries when an endpoint is removed, but if it fails to, you can clear them by hand:

```
$ conntrack -D -p udp --orig-dst 10.96.0.10 --reply-src 10.244.0.7
conntrack v1.4.8 (conntrack-tools): 3 flow entries have been deleted.
```

### 8.2 Saturation and races

```
$ sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_count = 262139
net.netfilter.nf_conntrack_max = 262144

$ dmesg -T | grep conntrack | tail -2
[Tue Sep 29 22:41:07 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Tue Sep 29 22:41:07 2026] nf_conntrack: nf_conntrack: table full, dropping packet

$ conntrack -S | head -2
cpu=0   	found=0 invalid=1843 insert=0 insert_failed=312 drop=312 early_drop=0 error=0 search_restart=4
cpu=1   	found=0 invalid=1712 insert=0 insert_failed=287 drop=287 early_drop=0 error=0 search_restart=2
```

- `table full` means **every new connection** fails on that node. kube-proxy adjusts `nf_conntrack_max` via `conntrack.maxPerCore`. On high-fan-out nodes, raise it and review `nf_conntrack_tcp_timeout_close_wait` / `time_wait`.
- A growing `insert_failed` is the SNAT/DNAT race on UDP. This is the classic source of **5-second DNS timeouts**, because glibc sends A and AAAA in parallel from the same socket. Mitigations: NodeLocal DNSCache, `options single-request-reopen` in `dnsConfig`, `--random-fully` on MASQUERADE.

### 8.3 Forwarding

```
$ sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 0
```

With `ip_forward=0`, packets reach the host veth and **never** leave through `flannel.1`/`eth0`. `tcpdump` shows them arriving and nothing leaving. Fix: `sysctl -w net.ipv4.ip_forward=1`, persisted in `/etc/sysctl.d/`.

### 8.4 br_netfilter

```
$ lsmod | grep br_netfilter
$ sysctl net.bridge.bridge-nf-call-iptables
sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory
```

Without the module, frames that are switched inside `cni0` skip iptables. Pod→Service works when the backend is on another node (the packet gets routed), but fails when the backend is on the same node. Fix: `modprobe br_netfilter`, `sysctl -w net.bridge.bridge-nf-call-iptables=1`, and persist both in `/etc/modules-load.d/` and `/etc/sysctl.d/`.

### 8.5 rp_filter and asymmetric routing

```
$ sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.eth1.rp_filter
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.eth1.rp_filter = 1

$ sysctl -w net.ipv4.conf.all.log_martians=1
$ dmesg -T | grep martian | tail -2
[Tue Sep 29 23:02:11 2026] IPv4: martian source 10.244.2.8 from 10.244.2.8, on dev eth1
[Tue Sep 29 23:02:11 2026] ll header: 00000000: 52 54 00 12 34 56 52 54 00 ab cd ef 08 00
```

In strict mode (`1`), the kernel drops a packet if the route back to its source doesn't leave through the interface it arrived on. On multi-NIC nodes, or with policy routing, this is a silent drop that `tcpdump` *does* see (the capture happens before the check) but that the stack discards. The effective value is `max(all, <iface>)`. Loose mode (`2`) is the usual fix for multi-homing. Cilium and other CNIs set it per interface.

---

## 9. Systematic diagnosis guide

### 9.1 Procedure: bisect the path

```
1. Reproduce with a deterministic client:
   kubectl -n netlab exec client -- curl -sS -m 3 -o /dev/null -w '%{http_code} %{time_connect}\n' http://web.netlab/hostname

2. Classify the symptom (refused / timeout / partial / intermittent)  → table in §6.3

3. Control plane first (quick, rules out half of the cases):
   kubectl -n netlab get endpointslices -l kubernetes.io/service-name=web -o wide
   kubectl -n netlab get pods -o wide -l app=web

4. Client node:
   a) Does the packet leave the Pod?            tcpdump -i <veth>
   b) Is it translated correctly?               iptables-save -t nat | grep <svc>  + counters
   c) Where does the kernel route it?           ip route get <podIP> from <clientIP> iif cni0
   d) Does it leave the node encapsulated?      tcpdump -i eth0 'udp port 8472'
   e) Is it dropped in FORWARD?                 iptables -L FORWARD -n -v (policy counter)

5. Destination node:
   f) Does the encapsulated packet arrive?      tcpdump -i eth0 'udp port 8472'
   g) Is it decapsulated?                       tcpdump -i flannel.1 host <podIP>
   h) Does it reach the backend veth?           tcpdump -i <veth-backend>
   i) Is the Pod listening?                     nsenter -t <PID> -n ss -ltnp

6. The first hop where the packet appears "in" but not "out" is where the fault is.
   Confirm with counters or a trace; fix; verify again with the same command from step 1.
```

### 9.2 Fault catalog

| # | Symptom | Decisive evidence | Tool | Fix |
|---|---|---|---|---|
| 1 | Instant refused | `REJECT ... has no endpoints` in `filter` | `iptables-save -t filter` | Fix readinessProbe / Service selector |
| 2 | Refused only on one endpoint | `Flags [R.]` from the Pod IP; `ss -ltn` shows no port | `tcpdump`, `nsenter ... ss` | `targetPort` ≠ the port the process listens on |
| 3 | Timeout, SYN visible on the destination veth, no SYN-ACK | Final `DROP` counter in `cali-tw-*` goes up | `iptables -L -v`, `tcpdump` | Fix NetworkPolicy (port = `targetPort`) |
| 4 | Timeout, SYN leaves `flannel.1` but not `eth0` | No FDB entry for the remote node | `bridge fdb show dev flannel.1` | Restart the node's flanneld; check node annotations |
| 5 | Timeout, UDP 8472 leaves `worker-1`, never reaches `worker-2` | Only `Out` on eth0 of worker-1 | `tcpdump -i eth0 udp port 8472` on both | Open UDP 8472/4789 (or proto 4, UDP 6081) in the firewall / security group |
| 6 | Timeout, packets reach the host and don't leave | `ip_forward = 0` or `FORWARD policy DROP` with a growing counter | `sysctl`, `iptables -L FORWARD -v` | Enable forwarding; ACCEPT rules for the Pod CIDR |
| 7 | Same-node Service fails, cross-node works | `bridge-nf-call-iptables` missing | `sysctl`, `lsmod` | `br_netfilter` + sysctl |
| 8 | Small requests OK, large ones hang | `need to frag (mtu N)`, or data retransmissions with no ACK | `tcpdump 'icmp[icmptype]==icmp-unreach'`, `ping -M do -s` | Pod MTU = underlay MTU − overhead (VXLAN 50, IPIP 20, Geneve 50+, WireGuard 60/80) |
| 9 | Replies never arrive, multi-NIC node | `martian source` in dmesg | `sysctl rp_filter`, `log_martians` | `rp_filter=2` or fix routes/`ip rule` |
| 10 | Intermittent 5 s on DNS | `insert_failed` grows | `conntrack -S` | NodeLocal DNSCache / `single-request-reopen` |
| 11 | All new connections fail on one node | `table full, dropping packet` | `dmesg`, `sysctl nf_conntrack_count` | Raise `nf_conntrack_max`, review timeouts |
| 12 | "There are no kube-proxy rules" | `iptables -V` shows a different backend than kube-proxy, or mode `nftables`/`ipvs` | `iptables -V`, `curl :10249/proxyMode` | Use the right tool (`nft`, `ipvsadm`, `iptables-legacy-save`) |
| 13 | A process on the node can't reach a ClusterIP | No `KUBE-MARK-MASQ` for a source outside the CIDR; `--cluster-cidr` missing in kube-proxy | `iptables-save -t nat`, kube-proxy config | Set `clusterCIDR` in `KubeProxyConfiguration` |

### 9.3 Verifying MTU without guessing

```
$ kubectl -n netlab exec client -- ip link show eth0 | grep -o 'mtu [0-9]*'
mtu 1450

# 1450 - 20 (IP) - 8 (ICMP) = 1422 bytes of payload with DF set
$ kubectl -n netlab exec client -- ping -c 2 -M do -s 1422 10.244.2.8
PING 10.244.2.8 (10.244.2.8) 1422(1450) bytes of data.
1430 bytes from 10.244.2.8: icmp_seq=1 ttl=62 time=0.612 ms
1430 bytes from 10.244.2.8: icmp_seq=2 ttl=62 time=0.540 ms

$ kubectl -n netlab exec client -- ping -c 2 -M do -s 1423 10.244.2.8
PING 10.244.2.8 (10.244.2.8) 1423(1451) bytes of data.
ping: local error: message too long, mtu=1450
```

If 1422 fails *with no local error* (a silent timeout), then somewhere past the node the effective MTU is lower than 1450 + 50 = 1500. Lower the size with `-s` until you find the real threshold, then subtract the overhead to get the correct Pod MTU.

### 9.4 Safe operation on production nodes

- **Read before you write.** `iptables-save > /tmp/before.rules` before touching anything, so you can compare with `diff` afterwards.
- **Don't edit kube-proxy or CNI chains by hand.** They get resynchronized (kube-proxy on `syncPeriod`, Calico/Felix continuously) and your change disappears. The permanent fix belongs in the Kubernetes object or in the component's configuration.
- **Keep `tcpdump` bounded**: `-c`, a narrow filter, `-w` to a file with rotation (`-C 100 -W 5`) if it has to run for a long time.
- **Remove every `TRACE` and every `log_martians` you enable** once you're done.
- **Correlate on a single timeline.** If you capture on two nodes, make sure NTP is synchronized, or the timestamps will mislead you.

---

## 10. Exam-speed checklist

```
# Backend and mode
iptables -V ; curl -s localhost:10249/proxyMode

# Everything about one Service in one pass
SVC=netlab/web ; iptables-save | grep -F "$SVC"

# Real path of the packet
ip route get <dstIP> from <srcIP> iif cni0

# Interfaces and drops
ip -br link ; ip -s link show <iface>

# Pod netns from the node
PID=$(crictl inspect --output go-template --template '{{.info.pid}}' <ctr>) ; nsenter -t $PID -n <cmd>

# Capture at two points, SYN/RST only
tcpdump -nn -i any -c 20 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0 and host <podIP>'

# Kernel state
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.ipv4.conf.all.rp_filter
conntrack -S ; conntrack -L --orig-dst <clusterIP>
```

---

## References

- CNCF / Linux Foundation — Certified Kubernetes Network Engineer (CKNE): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes — Virtual IPs and Service Proxies (iptables, IPVS and nftables modes): https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes — Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes — Debug Running Pods (`kubectl debug`, ephemeral containers): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes — Debugging Kubernetes nodes with crictl: https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/
- Kubernetes — kube-proxy reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Network Plugins (bridge-nf-call-iptables requirements): https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/
- iproute2 — `ip(8)`: https://man7.org/linux/man-pages/man8/ip.8.html
- iproute2 — `ip-route(8)`: https://man7.org/linux/man-pages/man8/ip-route.8.html
- iproute2 — `ip-link(8)`: https://man7.org/linux/man-pages/man8/ip-link.8.html
- iproute2 — `bridge(8)`: https://man7.org/linux/man-pages/man8/bridge.8.html
- netfilter — `iptables(8)`: https://man7.org/linux/man-pages/man8/iptables.8.html
- netfilter — `iptables-extensions(8)` (statistic, TRACE, MASQUERADE, DNAT): https://man7.org/linux/man-pages/man8/iptables-extensions.8.html
- netfilter — nftables wiki: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- netfilter — conntrack-tools user manual: https://conntrack-tools.netfilter.org/manual.html
- tcpdump — `tcpdump(1)`: https://www.tcpdump.org/manpages/tcpdump.1.html
- libpcap — `pcap-filter(7)`: https://www.tcpdump.org/manpages/pcap-filter.7.html
- Linux kernel — IP sysctl documentation (`ip_forward`, `rp_filter`, `log_martians`): https://docs.kernel.org/networking/ip-sysctl.html
- Linux kernel — Netfilter conntrack sysctl: https://docs.kernel.org/networking/nf_conntrack-sysctl.html
- RFC 7348 — Virtual eXtensible Local Area Network (VXLAN): https://www.rfc-editor.org/rfc/rfc7348