# Troubleshooting Pod Connectivity (DNS, pod-to-pod)

## 1. Motivation: why this is the most expensive ticket in the platform queue

Almost every Kubernetes connectivity ticket reads the same way: *"service A can't reach service B"*. Behind that sentence are at least seven separate subsystems, and any one of them can be the cause:

1. The application's resolver library (glibc, musl, Go's pure-Go resolver, the JVM's DNS cache)
2. The Pod's `/etc/resolv.conf`, written by the kubelet from `dnsPolicy` and `dnsConfig`
3. The Service virtual IP layer (kube-proxy in iptables, IPVS or nftables mode, or an eBPF replacement such as Cilium's)
4. CoreDNS: its Corefile, its upstreams, its capacity
5. The CNI data plane: veth pairs, bridges, routes, overlay encapsulation (VXLAN, Geneve, IPIP, WireGuard) or native routing (BGP, cloud VPC routes)
6. Policy enforcement: NetworkPolicy, CiliumNetworkPolicy, Calico `GlobalNetworkPolicy`, plus node firewalls and cloud security groups
7. The node kernel: `ip_forward`, `rp_filter`, the conntrack table, the iptables `FORWARD` policy, MTU

The architectural problem is that **Kubernetes networking is a contract, not an implementation**. The Kubernetes networking model requires that every Pod can reach every other Pod without NAT, and that agents on a node can reach all Pods on that node (https://kubernetes.io/docs/concepts/cluster-administration/networking/). *How* that happens is left to the CNI plugin, so the failure modes of a Flannel VXLAN cluster, a Calico BGP cluster and a Cilium eBPF cluster with kube-proxy replacement are different even though the symptom is identical.

A senior engineer's advantage is not knowing more commands. It is **isolating the failing layer in a few tests** rather than guessing. This chapter builds that method:

- A layered mental model of the packet path and the DNS path
- A **connectivity matrix** that points to the broken layer from the pattern of which tests pass and fail
- Deep mechanics of Kubernetes DNS: `ndots`, search paths, conntrack races, NodeLocal DNSCache
- Deep mechanics of pod-to-pod failures: MTU, overlay ports, forwarding, policy
- A catalogue of production failures, each with symptom, proof and fix

---

## 2. The two paths you must be able to draw from memory

### 2.1 The pod-to-pod packet path (overlay CNI, cross-node)

```
 Node A                                                     Node B
┌──────────────────────────────────────┐                   ┌──────────────────────────────────────┐
│ Pod A netns                          │                   │                          Pod B netns │
│  eth0 10.244.1.5/24                  │                   │                  10.244.2.7/24 eth0  │
│   │ default via 10.244.1.1           │                   │                                  ▲   │
│   ▼                                  │                   │                                  │   │
│  veth (host side) ──► cni0 / routing │                   │ routing / cni0 ◄── veth (host side)  │
│        │  route 10.244.2.0/24        │                   │        ▲                             │
│        ▼  via flannel.1 / vxlan.calico│                  │        │ decapsulation               │
│  [iptables/nftables FORWARD, policy] │                   │ [policy, FORWARD, conntrack]         │
│        │  encapsulation              │                   │        │                             │
│        ▼  outer: 192.168.10.11 ──────┼── UDP 8472/4789 ──┼──────► 192.168.10.12  eth0           │
│  eth0 192.168.10.11 (MTU 1500)       │   underlay        │                                      │
└──────────────────────────────────────┘                   └──────────────────────────────────────┘
```

Every arrow is a place where a packet can be dropped:

| Hop | What can break | How you prove it |
|---|---|---|
| Pod `eth0` | No IP (sandbox failed), wrong default route | `ip addr`, `ip route` inside the netns |
| veth ↔ host | veth missing after a CNI crash, stale interface | `ip link` on the node, `crictl inspectp` |
| Host routing | Route to the remote Pod CIDR missing (BGP session down, Flannel lease lost) | `ip route get <remote-pod-ip>` on the node |
| FORWARD chain | Policy `DROP` (Docker sets it), NetworkPolicy drop | `iptables -S FORWARD`, CNI policy logs, `hubble observe` |
| Encapsulation | Overlay port blocked by firewall or security group | `tcpdump -ni eth0 udp port 8472` on both nodes |
| Underlay | MTU smaller than overlay MTU + overhead | `ping -M do -s <size>` |
| Remote node | `rp_filter` drops asymmetric traffic, conntrack full | `sysctl`, `dmesg`, `conntrack -S` |

### 2.2 The DNS resolution path

```
app → libc resolver → /etc/resolv.conf (nameserver 10.96.0.10, search ..., ndots:5)
    → UDP :53 to 10.96.0.10 (Service ClusterIP: virtual, has no interface anywhere)
    → kube-proxy DNAT (iptables/IPVS/nftables) or eBPF socket-LB → CoreDNS Pod IP 10.244.0.3:53
    → CoreDNS plugin chain: errors → cache → kubernetes (cluster.local) | forward (everything else)
    → forward → node /etc/resolv.conf upstreams (or explicit resolvers)
```

This path has a property that surprises people: **DNS for every Pod depends on Service routing and on pod-to-pod connectivity to the CoreDNS Pods**. When pod-to-pod networking is broken across nodes, the first symptom users report is often "DNS is down", because the Pod they tested from happens to sit on a node with no CoreDNS replica. DNS failures are frequently a *symptom* of a data-plane failure, not the cause.

---

## 3. Methodology: the connectivity matrix

Don't start with `tcpdump`. Run five cheap tests from the affected Pod (or from a debug Pod on the same node) and read the pattern.

| # | Test | Command (from inside a Pod) |
|---|---|---|
| T1 | Pod → Pod, **same node** | `curl -sS -m 3 http://<pod-ip-same-node>:8080/hostname` |
| T2 | Pod → Pod, **other node** | `curl -sS -m 3 http://<pod-ip-other-node>:8080/hostname` |
| T3 | Pod → Service **ClusterIP** (by IP) | `curl -sS -m 3 http://<cluster-ip>:<port>/` |
| T4 | Pod → **CoreDNS Pod IP** directly | `dig @<coredns-pod-ip> kubernetes.default.svc.cluster.local +short` |
| T5 | Pod → **kube-dns ClusterIP** | `dig @10.96.0.10 kubernetes.default.svc.cluster.local +short` |
| T6 | Resolver path as the app sees it | `getent hosts web.shop` / `nslookup web.shop` |
| T7 | External name | `dig @10.96.0.10 example.com +short` |

### 3.1 Reading the pattern

| T1 | T2 | T3 | T4 | T5 | T6 | T7 | Most likely layer |
|---|---|---|---|---|---|---|---|
| ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | Pod has no working network (sandbox/CNI ADD failed, egress default-deny policy) |
| ✓ | ✗ | ~ | ~ | ~ | ~ | ~ | **Cross-node data plane**: overlay port blocked, routes missing, FORWARD DROP, MTU |
| ✓ | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | **Service layer**: kube-proxy down or not programming, conntrack full, eBPF LB broken |
| ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | CoreDNS Pods unhealthy, or a policy blocking port 53 to them |
| ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | **Resolver config**: wrong namespace / short name, `dnsPolicy`, `search`, `ndots` |
| ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | CoreDNS `forward` upstream broken, egress to upstream blocked, loop |
| ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ but slow/intermittent | conntrack race, CoreDNS saturation, `ndots` amplification, MTU on large responses |

`~` means "depends on where the target Pod lives": when cross-node networking is broken, T3–T7 pass or fail depending on whether the chosen backend is local.

This matrix is the core of the chapter. Everything that follows explains how to run each test correctly and what each failure means at the kernel level.

---

## 4. Tooling: what to use and when

| Tool | Where it runs | Strengths | Limitations |
|---|---|---|---|
| `kubectl exec` | Inside an app container | Exact view of the app's netns and resolv.conf | Distroless and scratch images have no shell, no `dig` |
| `kubectl debug -it pod/x --image=... --target=c` | Ephemeral container in the **same Pod** | Same netns as the app, full toolset, no restart | Cannot be removed once added; needs RBAC for `pods/ephemeralcontainers` |
| `kubectl debug node/n -it --image=...` | Pod in the node's host namespaces | Node routes, iptables, `tcpdump` on `eth0`, host fs at `/host` | Privileged; your security policy may forbid it |
| Standalone debug Pod (netshoot, dnsutils) | New Pod, scheduled where you choose | Reproducible, `nodeName`-pinned tests | Not the app's netns, so it can't reproduce policy applied to the app's labels unless you copy them |
| `nsenter -t <pid> -n` | Node shell | Host tools inside any Pod's netns | Needs node access and the container PID from `crictl` |
| `tcpdump` | Pod netns or node | Ground truth: did the packet leave / arrive? | Encrypted overlays (WireGuard, IPsec) hide the inner packet on the underlay |
| `conntrack` | Node | NAT state, `insert_failed`, table exhaustion | Useless for eBPF data planes that bypass netfilter conntrack |
| `hubble observe` (Cilium) | Cilium agents | Per-flow verdicts with drop reasons (`policy-denied`, `CT: Map insertion failed`) | Cilium only |
| `calicoctl node status` (Calico) | Node / cluster | BGP peer state | Calico only |

### 4.1 Debug workloads

The official Kubernetes DNS debugging guide uses a dedicated `dnsutils` Pod (https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dnsutils
  namespace: default
spec:
  containers:
  - name: dnsutils
    image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
    command:
    - sleep
    - "infinity"
    imagePullPolicy: IfNotPresent
  restartPolicy: Always
```

For pod-to-pod work you need more than DNS tools. Pin a full network toolbox to a chosen node, and add `NET_ADMIN`/`NET_RAW` so `tcpdump` and `ping` work under restrictive runtimes:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-worker1
  namespace: default
  labels:
    app: netshoot
spec:
  nodeName: worker-1
  containers:
  - name: netshoot
    image: nicolaka/netshoot:v0.13
    command: ["sleep", "infinity"]
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
  restartPolicy: Always
```

Setting `nodeName` bypasses the scheduler. That is the point here: you choose which node the test runs from.

When the application image has no shell, attach an ephemeral container to the **same** Pod so you test from the exact netns, with the exact labels that NetworkPolicy matches on (https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/):

```
$ kubectl -n shop debug -it pod/web-7d9f8c6b5-x2kqp --image=nicolaka/netshoot:v0.13 --target=web
Targeting container "web". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-7kq2m.
If you don't see a command prompt, try pressing enter.
web-7d9f8c6b5-x2kqp:~# cat /etc/resolv.conf
search shop.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

For node-level inspection:

```
$ kubectl debug node/worker-1 -it --image=nicolaka/netshoot:v0.13
Creating debugging pod node-debugger-worker-1-bx7tz with container debugger on node worker-1.
If you don't see a command prompt, try pressing enter.
worker-1:~# ip route | grep 10.244
10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink
10.244.1.0/24 dev cni0 proto kernel scope link src 10.244.1.1
10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink
```

The node debug Pod shares the host network namespace, and the host root filesystem is mounted at `/host`. Delete it when you finish: `kubectl delete pod node-debugger-worker-1-bx7tz`.

### 4.2 Entering a Pod's netns from the node (`nsenter`)

When you have SSH to the node, this is the fastest way to use host tools against a Pod:

```
$ POD_ID=$(sudo crictl pods --name web-7d9f8c6b5-x2kqp -q)
$ CID=$(sudo crictl ps --pod "$POD_ID" -q | head -1)
$ PID=$(sudo crictl inspect --output go-template --template '{{.info.pid}}' "$CID")
$ sudo nsenter -t "$PID" -n ip -4 addr show eth0
3: eth0@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UP group default
    inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0
       valid_lft forever preferred_lft forever
$ sudo nsenter -t "$PID" -n tcpdump -ni eth0 -c 5 port 53
```

`eth0@if12` tells you the peer veth is interface index 12 on the host. `ip -o link | grep '^12:'` on the node shows its host-side name, which is where you run `tcpdump` to see whether traffic leaves the Pod.

---

## 5. A reusable connectivity matrix: DaemonSet + headless Service

Under incident pressure, testing by hand produces inconsistent results. Deploy one echo server per node and test every pair, so you get a node × node matrix in seconds. `agnhost netexec` is the upstream e2e test server, and `agnhost connect` is the e2e TCP client used by Kubernetes' own NetworkPolicy tests.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netdiag
  labels:
    purpose: network-diagnostics
```

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: netprobe
  namespace: netdiag
  labels:
    app: netprobe
spec:
  selector:
    matchLabels:
      app: netprobe
  template:
    metadata:
      labels:
        app: netprobe
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: probe
        image: registry.k8s.io/e2e-test-images/agnhost:2.52
        args: ["netexec", "--http-port=8080", "--udp-port=8081"]
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
            port: 8080
          periodSeconds: 5
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 64Mi
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: netprobe
  namespace: netdiag
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: netprobe
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
```

The headless Service gives you a DNS test target that resolves to every probe Pod's IP. `publishNotReadyAddresses: true` keeps unready probes in DNS, which matters when you are debugging why they are unready.

The matrix script:

```bash
#!/usr/bin/env bash
# Node x node TCP reachability matrix using the netprobe DaemonSet.
set -euo pipefail
NS=netdiag

mapfile -t PODS < <(kubectl -n "$NS" get pods -l app=netprobe \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.spec.nodeName}{"\n"}{end}')

printf '%-12s %-12s %-15s %s\n' SRC_NODE DST_NODE DST_POD_IP RESULT
for src in "${PODS[@]}"; do
  read -r sname _ snode <<<"$src"
  for dst in "${PODS[@]}"; do
    read -r _ dip dnode <<<"$dst"
    if kubectl -n "$NS" exec "$sname" -- /agnhost connect "${dip}:8080" --timeout=3s >/dev/null 2>&1; then
      r=OK
    else
      r=FAIL
    fi
    printf '%-12s %-12s %-15s %s\n' "$snode" "$dnode" "$dip" "$r"
  done
done
```

A typical output when one node's overlay is broken:

```
$ ./netmatrix.sh
SRC_NODE     DST_NODE     DST_POD_IP      RESULT
cp-1         cp-1         10.244.0.12     OK
cp-1         worker-1     10.244.1.9      OK
cp-1         worker-2     10.244.2.14     FAIL
worker-1     cp-1         10.244.0.12     OK
worker-1     worker-1     10.244.1.9      OK
worker-1     worker-2     10.244.2.14     FAIL
worker-2     cp-1         10.244.0.12     FAIL
worker-2     worker-1     10.244.1.9      FAIL
worker-2     worker-2     10.244.2.14     OK
```

Read it the way you read the matrix in §3: `worker-2` reaches itself but nothing else, and nothing reaches `worker-2`. Pod networking on the node is fine; its **encapsulated or routed traffic** is not. Suspects, in order: the overlay port on `worker-2`'s firewall or security group, a missing route or BGP peer, the CNI agent on `worker-2`, the underlay MTU of its NIC.

---

## 6. Kubernetes DNS: deep mechanics

### 6.1 What the kubelet writes into `/etc/resolv.conf`

With the default `dnsPolicy: ClusterFirst`, a Pod in namespace `shop` gets:

```
search shop.svc.cluster.local svc.cluster.local cluster.local corp.example.com
nameserver 10.96.0.10
options ndots:5
```

- `nameserver` comes from the kubelet's `clusterDNS`, which is the kube-dns Service ClusterIP (or a NodeLocal DNSCache address, see §6.6).
- The first three `search` entries are Kubernetes'. Anything after them is appended from the **node's** resolv.conf search list.
- `ndots:5` is the Kubernetes default.

The record forms CoreDNS serves are defined in https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/:

| Record | Form | Returns |
|---|---|---|
| ClusterIP Service | `web.shop.svc.cluster.local` | A/AAAA of the ClusterIP |
| Headless Service | `db.data.svc.cluster.local` | A/AAAA of every ready endpoint (Pod IPs) |
| StatefulSet Pod (headless governing Service) | `db-0.db.data.svc.cluster.local` | The Pod's IP |
| Named port | `_http._tcp.web.shop.svc.cluster.local` | SRV record |
| Pod (by IP) | `10-244-1-5.shop.pod.cluster.local` | The Pod IP (only with `pods insecure` or `pods verified`) |

### 6.2 `dnsPolicy`: four values and a trap

| `dnsPolicy` | Resolver used | Typical use | Trap |
|---|---|---|---|
| `ClusterFirst` (**default**) | CoreDNS; non-cluster names forwarded upstream | Every normal workload | For `hostNetwork: true` Pods it silently behaves like `Default` |
| `ClusterFirstWithHostNet` | CoreDNS, even with `hostNetwork: true` | Ingress controllers, CNI agents and monitoring agents on host network that must resolve Services | Must be set explicitly |
| `Default` | Inherits the **node's** resolv.conf | Pods that must not depend on cluster DNS (CoreDNS itself uses this) | Despite the name, it is **not** the default policy |
| `None` | Only what `dnsConfig` specifies | Full control, custom resolvers | Without `dnsConfig.nameservers` the Pod has no DNS |

The `hostNetwork` trap is a classic: an ingress controller moved to `hostNetwork: true` for performance suddenly can't resolve `backend.shop.svc.cluster.local`, because it now uses the node's resolver, which knows nothing about `cluster.local`.

### 6.3 `ndots:5` and query amplification

The resolver rule: **if a name has fewer dots than `ndots`, try every search domain first, then the name as given**. Kubernetes uses 5 so that `web`, `web.shop` and `web.shop.svc` all resolve through search domains.

The cost falls on external names. `api.stripe.com` has 2 dots, fewer than 5, so a glibc resolver in namespace `shop` issues:

```
api.stripe.com.shop.svc.cluster.local.    A + AAAA  → NXDOMAIN
api.stripe.com.svc.cluster.local.         A + AAAA  → NXDOMAIN
api.stripe.com.cluster.local.             A + AAAA  → NXDOMAIN
api.stripe.com.corp.example.com.          A + AAAA  → NXDOMAIN (forwarded upstream!)
api.stripe.com.                           A + AAAA  → NOERROR
```

That is **10 queries for one lookup**, and the fourth pair leaves the cluster to your corporate resolver. At thousands of RPS this becomes CoreDNS CPU saturation, upstream rate limiting and tail latency.

You can see it in CoreDNS's `log` plugin output (§6.5):

```
[INFO] 10.244.1.5:51234 - 3310 "AAAA IN api.stripe.com.shop.svc.cluster.local. udp 55 false 512" NXDOMAIN qr,aa,rd 148 0.000121s
[INFO] 10.244.1.5:51234 - 2877 "A IN api.stripe.com.shop.svc.cluster.local. udp 55 false 512" NXDOMAIN qr,aa,rd 148 0.000098s
[INFO] 10.244.1.5:40177 - 6021 "A IN api.stripe.com.svc.cluster.local. udp 50 false 512" NXDOMAIN qr,aa,rd 143 0.000087s
...
[INFO] 10.244.1.5:39816 - 1452 "A IN api.stripe.com. udp 32 false 512" NOERROR qr,rd,ra 76 0.012411s
```

Mitigations, from least to most invasive:

| Mitigation | Effect | Trade-off |
|---|---|---|
| Use an FQDN with a trailing dot in app config (`api.stripe.com.`) | One query pair, no search expansion | Some HTTP clients and TLS SNI mishandle the trailing dot; test it |
| `dnsConfig.options: ndots: "2"` per Pod | Names with ≥2 dots go straight to absolute lookup | `web.shop` (1 dot) still expands; `web.shop.svc` (2 dots) now tries absolute first, which is one wasted query |
| CoreDNS `autopath` plugin (with `pods verified`) | Server-side search-path walk, one round trip from the client | CoreDNS must watch all Pods, which costs memory in large clusters |
| NodeLocal DNSCache | Negative answers cached on each node | Another DaemonSet to operate |

Per-Pod tuning:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-client
  namespace: payments
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    options:
    - name: ndots
      value: "2"
    - name: single-request-reopen
  containers:
  - name: app
    image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
    command: ["sleep", "infinity"]
```

Result:

```
$ kubectl -n payments exec api-client -- cat /etc/resolv.conf
search payments.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:2 single-request-reopen
```

`dnsConfig` is merged with the policy-generated config; with `dnsPolicy: None` it replaces it entirely. Kubernetes accepts up to 32 search domains with a total length of 2048 characters (https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/).

### 6.4 The conntrack race and the "5-second DNS" symptom

**Symptom:** most lookups take milliseconds, but a fraction take almost exactly **5 seconds** (glibc's default `timeout:5`), or occasionally 10.

**Mechanism:** glibc sends the A and AAAA queries **in parallel from the same UDP socket**, so both packets share the same 5-tuple. Both traverse kube-proxy's DNAT to a CoreDNS Pod IP. Netfilter creates the conntrack entry at the *confirm* step at the end of the hook path; when two packets with the same tuple race to confirm on different CPUs, and especially when DNAT picked different backends for each, one insert fails and that packet is dropped. The client waits out its timeout and retries.

**Proof on the node:**

```
$ sudo conntrack -S
cpu=0   found=12 invalid=431 insert=0 insert_failed=1873 drop=1873 early_drop=0 error=0 search_restart=52
cpu=1   found=9 invalid=402 insert=0 insert_failed=1790 drop=1790 early_drop=0 error=0 search_restart=47
```

A steadily rising `insert_failed` that correlates with DNS latency spikes is the fingerprint.

**Fixes:**

| Fix | How it helps | Caveat |
|---|---|---|
| Newer kernels | Clash-resolution fixes merged upstream around the 5.x series greatly reduce the race | Doesn't help the multi-backend case in every configuration |
| `options single-request-reopen` (glibc) | A and AAAA sent sequentially from different sockets | **Ignored by musl (Alpine)**; costs one extra RTT |
| `options use-vc` | Forces TCP, so there is no UDP race | TCP handshake cost on every lookup |
| **NodeLocal DNSCache** | Pods talk to a node-local link-local IP with **no DNAT** on the path; the cache talks to CoreDNS over TCP | Another DaemonSet; interacts with NetworkPolicy (§6.6) |

The NodeLocal DNSCache documentation names this conntrack race and the resulting 5-second timeouts as a primary motivation for the feature (https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/).

**The musl caveat:** Alpine's musl resolver queries all nameservers in parallel, historically ignored many `options`, and did not fall back to TCP for truncated responses until musl 1.2.4. The Kubernetes DNS debugging page lists Alpine as a known source of DNS issues (https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/). If exactly one image family has DNS trouble, check its libc before touching CoreDNS.

### 6.5 CoreDNS: the Corefile you must be able to read

A kubeadm-style Corefile, with the `log` plugin added for debugging and a stub domain for a corporate zone (https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        log
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
    corp.example.com:53 {
        errors
        cache 30
        forward . 10.10.0.53 10.10.0.54
    }
```

| Plugin | Role | Troubleshooting relevance |
|---|---|---|
| `errors` | Logs errors to stdout | First place to look for `SERVFAIL` causes such as upstream i/o timeouts |
| `log` | Logs **every** query | Diagnostic only: very noisy and CPU-costly at scale; remove it afterwards |
| `health` / `ready` | `:8080/health` liveness, `:8181/ready` readiness | A CoreDNS Pod that isn't `Ready` is removed from kube-dns endpoints |
| `kubernetes` | Answers `cluster.local` from the API (Services, EndpointSlices) | Lost API connectivity means stale or empty answers; check logs for `Failed to watch` |
| `forward` | Sends non-cluster names upstream | `/etc/resolv.conf` here is **CoreDNS's own** file, inherited from the node because CoreDNS runs with `dnsPolicy: Default` |
| `cache` | Positive and negative cache | Explains why a fix "takes 30 s to show up" |
| `loop` | Detects forwarding loops and **exits fatally** | Source of the classic CrashLoopBackOff (§8.3) |
| `reload` | Reloads a changed Corefile without a restart | ConfigMap propagation to the volume can take up to about a minute; don't restart impatiently |
| `loadbalance` | Shuffles A/AAAA order | Client-side spread across multiple IPs |

Plugin **order in the Corefile does not define execution order**. Execution order is fixed at CoreDNS compile time (`plugin.cfg`). Placing `cache` before `kubernetes` in the file changes nothing.

Enable query logging, then watch:

```
$ kubectl -n kube-system edit configmap coredns     # add "log" inside .:53 { }
$ kubectl -n kube-system logs -l k8s-app=kube-dns -f --max-log-requests=10
[INFO] Reloading
[INFO] plugin/reload: Running configuration SHA512 = 4c1a9b...
[INFO] Reloading complete
[INFO] 10.244.1.5:47285 - 15473 "A IN web.shop.svc.cluster.local. udp 55 false 512" NOERROR qr,aa,rd 110 0.000167s
```

Anatomy of a log line: client `IP:port`, query ID, `"TYPE CLASS name. proto size DO-bit bufsize"`, rcode, response flags (`aa` = authoritative, so answered by the `kubernetes` plugin; `ra` without `aa` = forwarded), response size, duration.

### 6.6 NodeLocal DNSCache: architecture and its NetworkPolicy consequence

NodeLocal DNSCache runs a caching CoreDNS instance as a DaemonSet on every node, listening on a link-local address (commonly `169.254.20.10`). Its effects:

- The Pod → cache hop is on-node and needs **no DNAT**, so the conntrack race disappears.
- Cache misses for `cluster.local` go to CoreDNS **over TCP**.
- A CoreDNS outage degrades gradually (cache hits keep working) rather than immediately.

Configuration depends on the kube-proxy mode (https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/):

| kube-proxy mode | node-local-dns listens on | Kubelet `clusterDNS` |
|---|---|---|
| iptables | Link-local IP **and** the kube-dns ClusterIP (it installs NOTRACK rules) | Unchanged |
| IPVS | Link-local IP only | Must change to the link-local IP |

For IPVS mode, the kubelet configuration change looks like this:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
clusterDNS:
- 169.254.20.10
clusterDomain: cluster.local
resolvConf: /run/systemd/resolve/resolv.conf
```

**Policy consequence:** with NodeLocal DNSCache, the Pod's DNS packets go to a **node-local address**, not to the CoreDNS Pods. A NetworkPolicy that allows egress only to `k8s-app: kube-dns` Pods won't match that traffic. How policy treats the link-local address depends on the CNI. Some treat node-local traffic as host traffic, others need an explicit `ipBlock` for `169.254.20.10/32`. Test it; don't assume.

### 6.7 DNS and NetworkPolicy: the most common self-inflicted outage

A namespace-wide default-deny egress policy blocks **DNS too**:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

Explicitly allow DNS. The selector targets the **CoreDNS Pods**, not the Service IP. Standard kube-proxy rewrites the destination to a CoreDNS Pod IP before policy is evaluated, so an `ipBlock` for `10.96.0.10/32` typically never matches. Allow **TCP 53 as well as UDP**: responses larger than the UDP buffer are truncated (`TC` bit) and retried over TCP, and NodeLocal DNSCache uses TCP upstream.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

`namespaceSelector` and `podSelector` sit in the **same** `to` element (logical AND: kube-dns Pods *in* kube-system). Splitting them into two list items (`- namespaceSelector` and `- podSelector`) means OR, which silently allows egress to every Pod in `kube-system` plus every `k8s-app: kube-dns` Pod anywhere. The `kubernetes.io/metadata.name` label is set automatically on every namespace (https://kubernetes.io/docs/concepts/services-networking/network-policies/).

A NetworkPolicy object has **no effect** unless the CNI enforces policy. Flannel alone does not; Calico, Cilium, Antrea and others do. "The policy is there but traffic still flows" is often "nothing implements policy on this cluster".

---

## 7. Pod-to-pod: deep mechanics of cross-node failures

### 7.1 Overlay protocols and the ports your firewall must allow

| Data plane | Encapsulation | Underlay requirement |
|---|---|---|
| Flannel VXLAN | VXLAN | UDP **8472** (Linux kernel default port) |
| Calico VXLAN | VXLAN | UDP **4789** |
| Calico IP-in-IP | IPIP | IP **protocol 4** (not a port: many cloud security groups can't express this without "all protocols") |
| Calico BGP (native routing) | None | TCP **179** between peers; the underlay must accept Pod-CIDR source addresses (disable cloud source/dest checks) |
| Cilium VXLAN | VXLAN | UDP **8472** |
| Cilium Geneve | Geneve | UDP **6081** |
| WireGuard (Calico/Cilium encryption) | WireGuard | UDP 51820 or 51871, depending on the CNI and version |

Check your CNI's documentation for its exact defaults; they are configurable, and hardened installations change them.

Prove the overlay is the problem with `tcpdump` on **both** ends:

```
# on worker-1 (sender), while curling 10.244.2.14 from a pod on worker-1
worker-1:~# tcpdump -ni eth0 -c 3 udp port 8472
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:14:02.118822 IP 192.168.10.11.49841 > 192.168.10.12.8472: OTV, flags [I] (0x08), overlay 0, instance 1
IP 10.244.1.9.52814 > 10.244.2.14.8080: Flags [S], seq 2931148101, win 64860, length 0
10:14:03.141503 IP 192.168.10.11.49841 > 192.168.10.12.8472: OTV, flags [I] (0x08), overlay 0, instance 1
IP 10.244.1.9.52814 > 10.244.2.14.8080: Flags [S], seq 2931148101, win 64860, length 0

# on worker-2 (receiver)
worker-2:~# tcpdump -ni eth0 -c 3 udp port 8472
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
^C
0 packets captured
```

tcpdump prints port 8472 as `OTV` because of a port-number heuristic. Read it as VXLAN. The SYN is **retransmitted** on the sender and **never arrives** at the receiver, so the drop is between the NICs: a security group, a host firewall (`firewalld`, `nftables`) or a switch ACL. Kubernetes is not involved at that hop.

If packets **do** arrive encapsulated but never reach the Pod, look at the receiving node: the VXLAN device (`ip -d link show flannel.1`), the FDB and ARP entries for the remote VTEP (`bridge fdb show dev flannel.1`, `ip neigh show dev flannel.1`), `rp_filter`, and the FORWARD chain.

### 7.2 MTU: "small requests work, big ones hang"

**Mechanism:** VXLAN adds 50 bytes of headers (outer Ethernet 14 + IP 20 + UDP 8 + VXLAN 8) on IPv4. With a 1500-byte underlay, the Pod MTU must be ≤1450. If the Pod MTU is 1500, or the underlay is actually *smaller* than you assume (cloud VPCs at 1460, VPN or IPsec paths, nested virtualization), full-size packets are dropped. Because the encapsulated packet typically has DF set or ICMP "fragmentation needed" is filtered, the result is a **black hole**:

- The TCP handshake succeeds (small packets)
- `curl` of a tiny `/healthz` succeeds
- A large response, TLS certificate exchange, or `kubectl logs` through a proxy **hangs**
- DNS over UDP works; large DNS responses over TCP stall

**Proof:** send DF-set pings of exact sizes. The ICMP payload plus 28 bytes (IP 20 + ICMP 8) equals the IP packet size.

```
$ kubectl exec netshoot-worker1 -- ip link show eth0 | grep -o 'mtu [0-9]*'
mtu 1450

$ kubectl exec netshoot-worker1 -- ping -M do -c 2 -s 1422 10.244.2.14
PING 10.244.2.14 (10.244.2.14) 1422(1450) bytes of data.

--- 10.244.2.14 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1023ms

$ kubectl exec netshoot-worker1 -- ping -M do -c 2 -s 1372 10.244.2.14
PING 10.244.2.14 (10.244.2.14) 1372(1400) bytes of data.
1380 bytes from 10.244.2.14: icmp_seq=1 ttl=62 time=0.612 ms
1380 bytes from 10.244.2.14: icmp_seq=2 ttl=62 time=0.544 ms
```

A 1450-byte inner packet is lost while 1400 passes, so the effective path MTU is below what the CNI assumes. Binary-search the exact value, then check the underlay:

```
worker-1:~# ip link show eth0 | grep -o 'mtu [0-9]*'
mtu 1400
```

Here the node NIC itself is 1400 (for example, a VM behind a tunnel), but the CNI was configured for a 1500 underlay. Fix it **in the CNI configuration** (Flannel derives MTU from the interface at start-up; Calico and Cilium have explicit MTU settings or auto-detection), then **recreate Pods**. Existing veths keep their old MTU.

If the local interface MTU is the limit, `ping` fails immediately and differently:

```
ping: local error: message too long, mtu=1450
```

That distinguishes "my own interface refuses it" from "something on the path drops it silently".

### 7.3 Routing and forwarding on the node

```
worker-1:~# ip route get 10.244.2.14
10.244.2.14 via 10.244.2.0 dev flannel.1 src 10.244.1.0 uid 0
    cache

worker-1:~# sysctl net.ipv4.ip_forward
net.ipv4.ip_forward = 1

worker-1:~# iptables -S FORWARD | head -3
-P FORWARD DROP
-A FORWARD -m comment --comment "kubernetes forwarding rules" -j KUBE-FORWARD
-A FORWARD -m comment --comment "flanneld forward" -j FLANNEL-FWD
```

| Check | Bad result | Meaning |
|---|---|---|
| `ip route get <remote-pod-ip>` | `via <node default gateway> dev eth0` | No route for the remote Pod CIDR: the CNI never programmed it (BGP down, lease lost, agent crashed) |
| `net.ipv4.ip_forward` | `0` | The node won't forward anything; often reset by a hardening baseline or a missing `sysctl.d` file after reboot |
| `iptables -P FORWARD` | `DROP` with no CNI accept rules | Docker, or a hardened baseline, sets `DROP`; a CNI that doesn't add its own accept rules loses cross-node traffic |
| `net.ipv4.conf.all.rp_filter` | `1` (strict) with asymmetric paths | Replies arriving on a different interface than the route back are dropped (multi-NIC nodes, some native-routing setups) |

For BGP-based Calico:

```
$ sudo calicoctl node status
Calico process is running.

IPv4 BGP status
+---------------+-------------------+-------+------------+--------------------------------+
| PEER ADDRESS  |     PEER TYPE     | STATE |   SINCE    |              INFO              |
+---------------+-------------------+-------+------------+--------------------------------+
| 192.168.10.11 | node-to-node mesh | up    | 2026-09-28 | Established                    |
| 192.168.10.12 | node-to-node mesh | start | 09:51:07   | Active Socket: Connection      |
|               |                   |       |            | refused                        |
+---------------+-------------------+-------+------------+--------------------------------+
```

`Active` with `Connection refused` means TCP 179 to that peer is blocked or the peer's BIRD daemon is down. No session, no routes to that node's Pod CIDR, so the §5 matrix shows that node isolated.

### 7.4 conntrack table exhaustion

On nodes with heavy connection churn (NAT gateways, ingress nodes, noisy clients):

```
worker-1:~# dmesg -T | grep -i conntrack | tail -2
[Tue Sep 30 09:58:12 2026] nf_conntrack: nf_conntrack: table full, dropping packet
[Tue Sep 30 09:58:12 2026] nf_conntrack: nf_conntrack: table full, dropping packet

worker-1:~# sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max
net.netfilter.nf_conntrack_count = 131072
net.netfilter.nf_conntrack_max = 131072
```

New connections are dropped at random, including DNS and Service traffic. kube-proxy sizes `nf_conntrack_max` from its `conntrack.maxPerCore` and `conntrack.min` settings. Raise them, and fix the churn (connection pooling, keep-alives) rather than only raising the ceiling.

### 7.5 The Service layer: pod IP works, ClusterIP doesn't

When T2 passes and T3 fails, stop looking at the CNI. Follow the Service debugging guide order (https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/):

```
$ kubectl -n shop get svc web -o wide
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.96.142.37    <none>        80/TCP    41d   app=web,tier=frontend

$ kubectl -n shop get endpointslices -l kubernetes.io/service-name=web
NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
web-8xk2p   IPv4          <unset>   <unset>     41d

$ kubectl -n shop get pods -l app=web --show-labels
NAME                   READY   STATUS    RESTARTS   AGE   LABELS
web-7d9f8c6b5-x2kqp    1/1     Running   0          3h    app=web,pod-template-hash=7d9f8c6b5,tier=front-end
```

`ENDPOINTS <unset>` means no backends at all. The selector says `tier=frontend`, the Pods carry `tier=front-end`. kube-proxy faithfully programs a Service with zero backends, and in iptables mode it **rejects** traffic to it, so clients get `connection refused` immediately rather than a timeout. That fast failure is itself a clue.

Other Service-layer causes:

| Symptom | Cause | Proof |
|---|---|---|
| Endpoints exist, connection refused | `targetPort` doesn't match the container's listening port | `kubectl exec <pod> -- ss -ltnp` vs `kubectl get svc -o yaml` |
| Endpoints empty, Pods `0/1 Ready` | Readiness probe failing | `kubectl describe pod`, Events |
| Endpoints fine, timeouts on every node | kube-proxy not running or not syncing | `kubectl -n kube-system get ds kube-proxy`, kube-proxy logs, `iptables-save \| grep web` / `nft list table ip kube-proxy` / `ipvsadm -Ln` |
| Pod can't reach **its own** Service | Hairpin: traffic DNATs back to the same Pod | Kubelet `hairpinMode`, CNI hairpin support |
| Works with kube-proxy, broken with eBPF replacement | kube-proxy still running alongside, stale rules | `cilium status` (KubeProxyReplacement line), leftover `KUBE-SVC` chains |

Proving kube-proxy programmed the Service (iptables mode):

```
worker-1:~# iptables-save -t nat | grep -E 'shop/web' | head -4
-A KUBE-SERVICES -d 10.96.142.37/32 -p tcp -m comment --comment "shop/web cluster IP" -m tcp --dport 80 -j KUBE-SVC-KX3CUCJP5SXXOYHB
-A KUBE-SVC-KX3CUCJP5SXXOYHB -m comment --comment "shop/web -> 10.244.1.9:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-7ZC4CUKFDGZ3VPN5
-A KUBE-SVC-KX3CUCJP5SXXOYHB -m comment --comment "shop/web -> 10.244.2.14:8080" -j KUBE-SEP-QMMUF3SZ6CCXTGFF
```

The mechanics of each proxy mode are documented in https://kubernetes.io/docs/reference/networking/virtual-ips/.

### 7.6 When the Pod never got a network: sandbox creation failures

If the Pod is stuck in `ContainerCreating`, you are debugging CNI `ADD`, not connectivity:

```
$ kubectl -n shop describe pod web-7d9f8c6b5-q9wzt | sed -n '/Events/,$p'
Events:
  Type     Reason                  Age                From     Message
  ----     ------                  ----               ----     -------
  Warning  FailedCreatePodSandBox  12s (x6 over 78s)  kubelet  Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "3f1c...": plugin type="calico" failed (add): failed to request IPv4 addresses: IPAM: no more free affine blocks
```

Typical causes: IPAM exhaustion (the Pod CIDR is too small for the Pod density), the CNI agent not ready on that node, a missing CNI binary or config in `/opt/cni/bin` / `/etc/cni/net.d`, or the CNI's datastore being unreachable. The IPAM design itself belongs to topic 1.2; here, recognise the event and route the ticket.

### 7.7 eBPF data planes: use their observability, not netfilter

With Cilium in kube-proxy-replacement mode, `iptables-save` and `conntrack` show you almost nothing relevant. Use the flow log instead, which records the exact drop reason:

```
$ hubble observe --namespace payments --verdict DROPPED --last 5
Sep 30 10:21:44.019: payments/api-5c6d8f7b9-lm2xz:41832 (ID:48213) <> kube-system/coredns-6f6b679f8f-2jx9k:53 (ID:10522) policy-denied DROPPED (UDP)
Sep 30 10:21:49.020: payments/api-5c6d8f7b9-lm2xz:41832 (ID:48213) <> kube-system/coredns-6f6b679f8f-2jx9k:53 (ID:10522) policy-denied DROPPED (UDP)
```

The retry comes 5 s after the first attempt, which is glibc's timeout. The drop is `policy-denied` towards CoreDNS: this is the §6.7 default-deny outage, proven in one command.

```
$ cilium status --brief
OK
$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing'
KubeProxyReplacement:    True   [eth0   192.168.10.11 (Direct Routing)]
Routing:                 Network: Tunnel [vxlan]   Host: BPF
```

(See the Cilium troubleshooting guide: https://docs.cilium.io/en/stable/operations/troubleshooting/.)

---

## 8. Production failure catalogue

Each entry: **symptom → proof → root cause → fix**.

### 8.1 Short name fails across namespaces

```
$ kubectl -n shop exec dnsutils -- nslookup postgres
Server:		10.96.0.10
Address:	10.96.0.10#53

** server can't find postgres: NXDOMAIN

$ kubectl -n shop exec dnsutils -- nslookup postgres.data
Server:		10.96.0.10
Address:	10.96.0.10#53

Name:	postgres.data.svc.cluster.local
Address: 10.96.77.201
```

- **Cause:** a short name expands only within the client's own namespace (`postgres.shop.svc.cluster.local`).
- **Fix:** use `<svc>.<namespace>` or the FQDN in application config. This is not a DNS bug.

### 8.2 Everything times out after a "security hardening" change

```
$ kubectl -n payments exec deploy/api -- nslookup kubernetes.default
;; connection timed out; no servers could be reached

command terminated with exit code 1
$ kubectl -n payments get networkpolicy
NAME               POD-SELECTOR   AGE
default-deny-all   <none>         14m
```

- **Cause:** default-deny egress with no DNS allowance. A timeout (not NXDOMAIN) means queries never got an answer.
- **Fix:** the `allow-dns-egress` policy from §6.7, with UDP **and** TCP 53.

### 8.3 CoreDNS in CrashLoopBackOff after an OS upgrade

```
$ kubectl -n kube-system get pods -l k8s-app=kube-dns
NAME                       READY   STATUS             RESTARTS      AGE
coredns-6f6b679f8f-2jx9k   0/1     CrashLoopBackOff   7 (2m ago)    14m
coredns-6f6b679f8f-8w4tq   0/1     CrashLoopBackOff   7 (2m ago)    14m

$ kubectl -n kube-system logs coredns-6f6b679f8f-2jx9k --previous
[FATAL] plugin/loop: Loop (127.0.0.1:55953 -> :53) detected for zone ".", see https://coredns.io/plugins/loop#troubleshooting. Query: "HINFO 4547991504243258144.3688648895315093531."
```

- **Cause:** the node's `/etc/resolv.conf` points to `127.0.0.53` (systemd-resolved stub). CoreDNS inherits it via `dnsPolicy: Default`, and `forward . /etc/resolv.conf` sends queries to 127.0.0.53 **inside the CoreDNS Pod's own netns**, which is CoreDNS itself. The `loop` plugin detects this and exits.
- **Fix:** point the kubelet at the real upstream list with `resolvConf: /run/systemd/resolve/resolv.conf` in `KubeletConfiguration`, restart the kubelet, then restart the CoreDNS Pods. Alternatively, forward to explicit resolver IPs in the Corefile. **Do not** delete the `loop` plugin to "fix" it: that turns a visible crash into an invisible CPU-burning loop. This case is documented in https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/ and https://coredns.io/plugins/loop/.

### 8.4 Intermittent 5-second latency, fleet-wide

```
$ kubectl exec dnsutils -- bash -c 'for i in $(seq 1 20); do /usr/bin/time -f "%e s" getent hosts web.shop >/dev/null; done' 2>&1 | sort | uniq -c
     18 0.00 s
      2 5.01 s
```

- **Proof:** rising `insert_failed` in `conntrack -S` on the client's node (§6.4).
- **Fix:** NodeLocal DNSCache (strategic); `single-request-reopen` for glibc workloads (tactical); kernel upgrade.

### 8.5 External names resolve but slowly; CoreDNS CPU at its limit

- **Proof:** the `log` plugin shows NXDOMAIN storms of `*.svc.cluster.local` suffixes (§6.3). CoreDNS metrics show `NXDOMAIN` dominating.
- **Fix:** trailing-dot FQDNs or `ndots: "2"` for the chatty workloads; scale CoreDNS (for example, with cluster-proportional-autoscaler); NodeLocal DNSCache.

### 8.6 Same-node works, cross-node fails

- **Proof:** §5 matrix plus §7.1 `tcpdump` on both nodes.
- **Cause:** overlay port or protocol blocked (typically a new node pool created with a security group missing UDP 8472/4789 or IP protocol 4), BGP down, FORWARD DROP.
- **Fix:** open the underlay path; restore routes; ensure CNI accept rules or set the FORWARD policy deliberately.

### 8.7 Health checks pass, real traffic hangs

- **Proof:** §7.2 DF-ping bisection.
- **Cause:** MTU mismatch between CNI config and underlay.
- **Fix:** correct the CNI MTU, then roll every Pod so veths are recreated.

### 8.8 Ingress controller on `hostNetwork` can't resolve Services

```
$ kubectl -n ingress exec ds/ingress-nginx-controller -- cat /etc/resolv.conf
nameserver 192.168.10.1
search corp.example.com
```

- **Cause:** `hostNetwork: true` with the default `ClusterFirst` falls back to the node's resolver.
- **Fix:** `dnsPolicy: ClusterFirstWithHostNet`.

### 8.9 DNS works, but only for some Pods, and only on some nodes

- **Proof:** find where the CoreDNS replicas run, then test T4 against **each** CoreDNS Pod IP from a Pod on each node:

```
$ kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP            NODE       NOMINATED NODE   READINESS GATES
coredns-6f6b679f8f-2jx9k   1/1     Running   0          2d    10.244.0.3    cp-1       <none>           <none>
coredns-6f6b679f8f-8w4tq   1/1     Running   0          2d    10.244.0.4    cp-1       <none>           <none>

$ kubectl exec netshoot-worker1 -- dig @10.244.0.3 kubernetes.default.svc.cluster.local +short +time=2 +tries=1
;; communications error to 10.244.0.3#53: timed out
```

- **Cause:** both replicas on the same node, and that node is isolated from `worker-1` at the data-plane level. This is a pod-to-pod problem that surfaces as DNS.
- **Fix:** repair the data plane (§7). Also add `topologySpreadConstraints` or anti-affinity to CoreDNS so one node's failure can't take out cluster DNS.

---

## 9. Verification runbook

Run it top to bottom; each step either passes or names the layer to investigate.

```
# 0. Is cluster DNS itself healthy?
$ kubectl -n kube-system get deploy coredns
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           94d
$ kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
NAME             ADDRESSTYPE   PORTS        ENDPOINTS               AGE
kube-dns-7qfz6   IPv4          53,53,9153   10.244.0.3,10.244.2.5   94d

# 1. What does the failing Pod actually use?
$ kubectl -n shop exec deploy/web -- cat /etc/resolv.conf

# 2. Resolve through the Service IP, then directly against each CoreDNS Pod
$ kubectl -n shop exec dnsutils -- dig +short kubernetes.default.svc.cluster.local
10.96.0.1
$ kubectl -n shop exec dnsutils -- dig +short @10.244.0.3 kubernetes.default.svc.cluster.local
10.96.0.1

# 3. External resolution (tests CoreDNS forward + egress)
$ kubectl -n shop exec dnsutils -- dig +short example.com

# 4. Pod-to-pod same node / other node (§5 matrix)
$ ./netmatrix.sh

# 5. Service VIP vs backend Pod IP
$ kubectl -n shop exec netshoot-worker1 -- curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://10.96.142.37/
$ kubectl -n shop exec netshoot-worker1 -- curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://10.244.2.14:8080/

# 6. Large-packet path
$ kubectl exec netshoot-worker1 -- ping -M do -c 2 -s 1422 10.244.2.14

# 7. Policy in the path?
$ kubectl get networkpolicy -A
```

**Interpreting DNS error types.** They point to different layers:

| Client sees | Meaning | Layer |
|---|---|---|
| `NXDOMAIN` | Server answered: the name doesn't exist | Naming: namespace, typo, search path; or the Service doesn't exist |
| `SERVFAIL` | Server answered: it couldn't resolve | CoreDNS upstream failure, API watch failure, DNSSEC |
| `REFUSED` | Server answered: it won't serve this | Upstream ACL; zone not configured |
| `connection timed out; no servers could be reached` | **No answer at all** | Network: policy, data plane, CoreDNS down, Service VIP not programmed |
| Answer after about 5 s | First attempt lost, retry succeeded | conntrack race, packet loss, overloaded CoreDNS |

### 9.1 Continuous verification: alert before users notice

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: coredns-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: coredns.rules
    rules:
    - alert: CoreDNSServfailRatioHigh
      expr: |
        sum(rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]))
        /
        sum(rate(coredns_dns_responses_total[5m]))
        > 0.01
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "CoreDNS SERVFAIL ratio above 1% for 10 minutes"
        runbook: "Check CoreDNS errors log and forward upstream health"
    - alert: CoreDNSLatencyP99High
      expr: |
        histogram_quantile(0.99, sum by (le) (rate(coredns_dns_request_duration_seconds_bucket[5m])))
        > 0.1
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "CoreDNS p99 latency above 100ms"
        runbook: "Check CoreDNS CPU throttling, NXDOMAIN storms from ndots, upstream latency"
    - alert: CoreDNSForwardHealthcheckFailing
      expr: |
        sum(rate(coredns_forward_healthcheck_failures_total[5m])) > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "CoreDNS cannot reach its upstream resolvers"
        runbook: "Test node resolv.conf upstreams and egress from CoreDNS pods"
```

Server-side CoreDNS metrics **cannot see queries that never arrive**: policy drops, data-plane isolation and conntrack races are invisible to them. Pair them with a blackbox probe that resolves and connects *from Pods on every node*, which is what the §5 DaemonSet gives you when you run it on a schedule.

---

## 10. Trade-off summary

| Decision | Option A | Option B | Production guidance |
|---|---|---|---|
| DNS caching | Central CoreDNS only | + NodeLocal DNSCache | NodeLocal for large or high-QPS clusters or when you see the 5 s race; account for its NetworkPolicy interaction |
| Search expansion | Keep `ndots:5` | Lower `ndots` / FQDNs | Keep the default cluster-wide; tune per workload that calls external APIs heavily |
| Overlay vs native routing | Overlay (VXLAN/Geneve/IPIP) | Native (BGP / cloud routes) | Overlay is portable, with MTU overhead and firewall-port dependencies; native routing needs underlay cooperation and gives cleaner packet captures |
| Service implementation | kube-proxy iptables/nftables | eBPF replacement | eBPF scales better and has built-in flow visibility; your toolkit changes from `iptables-save`/`conntrack` to the CNI's CLI |
| Debug access | Ephemeral containers | Node shell / `nsenter` | Ephemeral containers keep the app's labels and policy context; node access is needed for underlay, routes and kernel counters |
| DNS logging | `log` plugin always on | On only during incidents | Incidents only: at scale it costs CPU and log volume, and it records every name every workload looks up |

---

## Referencias

- CKNE certification page (Linux Foundation): https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/
- Kubernetes: Debugging DNS Resolution: https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Kubernetes: DNS for Services and Pods (`dnsPolicy`, `dnsConfig`, record forms, search limits): https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes: Customizing DNS Service (Corefile, stub domains, upstreams): https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
- Kubernetes: Using NodeLocal DNSCache: https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
- Kubernetes: Debug Services: https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Kubernetes: Debug Running Pods (ephemeral containers, `kubectl debug`): https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes: Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes: Cluster Networking model: https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Kubernetes: Virtual IPs and Service Proxies: https://kubernetes.io/docs/reference/networking/virtual-ips/
- CoreDNS `kubernetes` plugin: https://coredns.io/plugins/kubernetes/
- CoreDNS `forward` plugin: https://coredns.io/plugins/forward/
- CoreDNS `log` plugin: https://coredns.io/plugins/log/
- CoreDNS `loop` plugin (troubleshooting loops): https://coredns.io/plugins/loop/
- CoreDNS `autopath` plugin: https://coredns.io/plugins/autopath/
- Cilium troubleshooting guide: https://docs.cilium.io/en/stable/operations/troubleshooting/