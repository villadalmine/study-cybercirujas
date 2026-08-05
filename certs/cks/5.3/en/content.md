# 5.3 Minimize external access to the network

> **Domain**: System Hardening — **Exam weight**: 2.5 % — **Exam version**: CKS v1.34
> **Scope**: reducing the network attack surface *of the nodes themselves* (host reachability, listening sockets, host firewalling, exposure primitives) — the layer **underneath** the Kubernetes authorization plane.

---

## 1. Motivation and the production architectural problem

### 1.1 A node is a Linux box that leaks

The mental model most engineers carry is "the cluster is the security boundary". It is not. A Kubernetes node is a general-purpose Linux host that happens to run a container runtime, and a stock `kubeadm` install leaves a surprisingly wide TCP surface bound to `0.0.0.0`. Every one of those sockets is reachable by anything that can route to the node IP — the corporate LAN, a misconfigured cloud security group, a VPC peering, a compromised pod using `hostNetwork: true`, or a lateral hop from an adjacent tenant.

The critical property to internalize: **NetworkPolicy does not protect the host network namespace.** With every mainstream CNI, a `NetworkPolicy` object selects *pods*. It has no opinion about traffic destined for `10.0.0.21:10250`, for `sshd`, for `etcd`, or for a `hostNetwork` pod. Three whole classes of exposure sit below it:

| Plane | Example target | Protected by NetworkPolicy? | Protected by what |
|---|---|---|---|
| Node ingress from outside the cluster | `6443`, `10250`, `22`, NodePort range | ❌ | Cloud SG/NACL + host firewall + `nodePortAddresses` |
| Node ingress from inside the cluster (pod → node) | `10250`, `2379`, IMDS via node | ❌ (traffic leaves the pod netns to the host) | Host firewall / CNI host policy / IMDS hop-limit |
| Node egress | C2 beacon, image exfil, `169.254.169.254` | Partially (pod egress only) | Host firewall `output` + egress gateway/proxy |

### 1.2 What an exposed port actually costs you

These are not theoretical. Each is a documented, reproducible full-cluster compromise chain:

| Port | Component | Failure mode when reachable | Result |
|---|---|---|---|
| `10250/tcp` | kubelet API (HTTPS) | `authentication.anonymous.enabled: true` **or** `authorization.mode: AlwaysAllow` | `POST /run/{ns}/{pod}/{container}` → arbitrary command execution in **any** pod on that node → steal every mounted ServiceAccount token |
| `10255/tcp` | kubelet read-only (HTTP, no auth) | Enabled at all | `GET /pods` dumps full PodSpecs: env vars, secret names, token mount paths, image registries. Pure reconnaissance goldmine |
| `2379/tcp` | etcd client | `--client-cert-auth=false` or cert reachable | Full read/write of every object in the cluster, **including unencrypted Secrets** |
| `2380/tcp` | etcd peer | Reachable off-subnet | Join a rogue member → cluster state injection |
| `10257` / `10259` | controller-manager / scheduler | Bound to `0.0.0.0` | `/metrics`, `/debug/pprof` heap dumps (may contain tokens), leader-election disruption |
| `30000–32767` | NodePort | Any Service of `type: NodePort` | The port is opened on **every node in the cluster**, on **all interfaces**, including control-plane nodes |
| `169.254.169.254` (egress) | Cloud IMDS | Reachable from pod netns | SSRF in one app → instance role credentials → cluster/account takeover |
| `22/tcp` | sshd | Password auth, root login, world-reachable | Direct node ownership; `/etc/kubernetes/pki/*` is right there |

### 1.3 The NodePort amplification problem

This is the single most misunderstood exposure primitive on the exam and in production. When a developer in namespace `team-a` creates:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: admin-ui
  namespace: team-a
spec:
  type: NodePort
  selector: { app: admin-ui }
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 31380
```

kube-proxy programs `31380` on **every node**, listening on **every address**, because `nodePortAddresses` is empty by default. A namespaced RBAC grant to create Services just punched a hole through the perimeter of the entire fleet, on the control-plane nodes too. There is no admission check for this out of the box.

### 1.4 Defense in depth: the four rings

```
                  ┌─────────────────────────────────────────────┐
   Ring 0         │ Cloud SG / NACL / physical VLAN + private   │  ← coarse, fails open on misconfig
                  │ control-plane endpoint                      │
                  ├─────────────────────────────────────────────┤
   Ring 1         │ Host firewall: nftables on every node       │  ← survives CNI failure, survives
                  │ (prerouting + input + forward + output)     │    kube-proxy, node-local truth
                  ├─────────────────────────────────────────────┤
   Ring 2         │ CNI host policy (Cilium host firewall /     │  ← declarative, cluster-wide,
                  │ Calico HostEndpoint) + kube-proxy           │    label-driven, GitOps-able
                  │ nodePortAddresses + service-node-port-range │
                  ├─────────────────────────────────────────────┤
   Ring 3         │ Component binding + authn/authz             │  ← the last line: even if reachable,
                  │ (readOnlyPort:0, anonymous:false, Webhook,  │    it must still refuse you
                  │  bind-address 127.0.0.1, client-cert-auth)  │
                  ├─────────────────────────────────────────────┤
   Ring 4         │ Admission control: forbid NodePort /        │  ← prevent the hole from ever
                  │ externalIPs / hostNetwork / hostPort        │    being requested
                  └─────────────────────────────────────────────┘
```

CKS 5.3 is essentially Rings 1–4. Ring 0 you inherit from the platform; do not rely on it alone — a single Terraform mistake in `0.0.0.0/0` opens everything, and the host firewall is what makes that mistake survivable.

---

## 2. Technical comparisons and trade-offs

### 2.1 The default listening surface (kubeadm, v1.34)

Values below are `kubeadm` defaults; verify on your own cluster with `ss -tulpn`.

| Port | Proto | Component | Default bind | Legitimate callers | Hardening |
|---|---|---|---|---|---|
| 6443 | TCP | kube-apiserver | `0.0.0.0` | Everyone (kubelets, kubectl, LB) | Private LB, SG allowlist, OIDC/mTLS |
| 2379 | TCP | etcd client | `127.0.0.1` + node IP | kube-apiserver on the same node | `--client-cert-auth=true`, restrict to control-plane subnet |
| 2380 | TCP | etcd peer | node IP | Other etcd members | `--peer-client-cert-auth=true`, control-plane subnet only |
| 2381 | TCP | etcd metrics | `127.0.0.1` | Local scrape / sidecar | Keep loopback |
| 10250 | TCP | kubelet API | `0.0.0.0` | kube-apiserver, metrics-server | `anonymous: false`, `mode: Webhook`, firewall to control-plane IPs |
| 10255 | TCP | kubelet read-only | disabled (`0`) | **nobody** | Keep `readOnlyPort: 0`; never re-enable |
| 10248 | TCP | kubelet healthz | `127.0.0.1` | Local | Keep loopback |
| 10256 | TCP | kube-proxy healthz | `0.0.0.0` | Cloud LB health checks | Restrict to LB subnet, or bind loopback if no external LB |
| 10249 | TCP | kube-proxy metrics | `127.0.0.1` | Local scrape | Keep loopback |
| 10257 | TCP | kube-controller-manager | `127.0.0.1` (kubeadm) | Local | Verify — upstream default is `0.0.0.0` |
| 10259 | TCP | kube-scheduler | `127.0.0.1` (kubeadm) | Local | Same |
| 30000–32767 | TCP/UDP | NodePort Services | all addrs | Depends | `nodePortAddresses`, shrink range, admission-deny |
| 8472 | UDP | VXLAN (Flannel/Cilium) | all | Peer nodes | Node subnet only |
| 4240 | TCP | Cilium health | all | Peer nodes | Node subnet only |
| 4789 | UDP | VXLAN (Calico) | all | Peer nodes | Node subnet only |
| 179 | TCP | Calico BGP | all | Peer nodes / ToR | Node subnet / ToR only |
| 5473 | TCP | Calico Typha | all | Felix on nodes | Node subnet only |
| 51820/51871 | UDP | WireGuard (Cilium/Calico) | all | Peer nodes | Node subnet only |

> **Trap**: blocking the CNI data-plane ports (8472, 4789, 4240, 179, 51820) is the #1 self-inflicted outage when hardening nodes. Symptoms in §5.

### 2.2 Where to enforce: layer comparison

| Layer | Granularity | Survives CNI outage | Survives node reboot | GitOps-able | Blast radius of a mistake | Protects host netns | Best for |
|---|---|---|---|---|---|---|---|
| Cloud SG / NACL | CIDR + port | ✅ | ✅ | ✅ (IaC) | Whole VPC | ✅ | Coarse perimeter, north-south |
| **nftables on node** | CIDR, iface, ct state, uid, rate | ✅ | ✅ (`nftables.service`) | ⚠️ (config mgmt) | One node (lock-out risk) | ✅ | The non-negotiable baseline |
| firewalld / ufw | zones / simple rules | ✅ | ✅ | ⚠️ | One node | ✅ | Distro-managed fleets — **with caveats** |
| Cilium host firewall (CCNP + `nodeSelector`) | identity, label, CIDR, port | ❌ (agent down ⇒ policy state at risk) | ✅ | ✅ | Fleet-wide (lock-out risk) | ✅ | Declarative node policy at scale |
| Calico `HostEndpoint` + `GlobalNetworkPolicy` | label, CIDR, port, pre-DNAT | ❌ | ✅ | ✅ | Fleet-wide | ✅ | Same, with `preDNAT` for NodePort |
| `NetworkPolicy` (k8s core) | pod label, ns, CIDR, port | ❌ | ✅ | ✅ | Namespace | ❌ | East-west pod traffic (topic 1.1) |
| Service mesh (mTLS/AuthZ) | workload identity, L7 | ❌ | ✅ | ✅ | Mesh | ❌ | L7 authz, not perimeter |
| Admission control (VAP/Kyverno) | API object shape | n/a | ✅ | ✅ | Cluster | prevention only | Stopping holes being requested |

**Architectural verdict**: nftables on every node is the floor — it is the only layer that is simultaneously node-local, CNI-independent, and enforced by the kernel before any userspace component gets a vote. CNI host policy sits *on top* for fleet-scale declarative management. Neither replaces the other.

### 2.3 Firewall backend comparison (and the kube-proxy interaction)

| Backend | Kernel path | Coexists with kube-proxy `iptables` mode | Coexists with kube-proxy `nftables` mode | Reload flushes k8s rules? | Recommendation |
|---|---|---|---|---|---|
| `iptables-legacy` | `x_tables` | ⚠️ Split-brain if kube-proxy uses `iptables-nft` | ⚠️ | No (but rule ordering fights) | Avoid on modern distros |
| `iptables-nft` (default RHEL9/Deb12) | `nf_tables` via translation | ✅ | ✅ | No | Acceptable |
| **`nft` native** | `nf_tables` | ✅ (separate tables, independent hooks) | ✅ (kube-proxy owns `table ip kube-proxy`) | No | **Preferred** |
| `firewalld` | `nf_tables` backend | ⚠️ Historically `--reload` flushed kube-proxy chains | ⚠️ | **Yes, historically** | Only if you must; pin and test reloads |
| `ufw` | `iptables-nft` | ⚠️ `ufw reload` rewrites `INPUT` ordering | ⚠️ | Partially | Lab only |

Two facts that make native `nft` the right answer:

1. **Multiple base chains can hook the same netfilter hook.** Your `table inet k8s_node` and kube-proxy's `table ip kube-proxy` are independent objects traversed in priority order. Neither flushes the other. `iptables -F` / `firewalld --reload` have no such guarantee.
2. **You can hook at a priority *before* NAT**, which is the only way to filter NodePort traffic correctly (§2.5).

> **v1.34 note**: the kube-proxy `nftables` backend (KEP-3866) went beta in v1.31 and GA in the v1.33 line, but it is still **not** the default in v1.34. Confirm on your cluster:
> `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'`

### 2.4 External exposure primitives compared

| Mechanism | Ports opened where | Requires admission control to restrict | Auditability | Recommended posture |
|---|---|---|---|---|
| `type: ClusterIP` | nowhere externally | — | high | ✅ Default |
| `type: NodePort` | 30000–32767 on **all nodes, all NICs** | ✅ deny by policy | low (buried in Service specs) | ❌ Forbid outside break-glass |
| `type: LoadBalancer` | cloud LB → NodePort on all nodes | ✅ force `internal` scheme | medium | ⚠️ Internal-only by default |
| `spec.externalIPs` | traffic to arbitrary IPs is hijacked cluster-wide | ✅ `DenyServiceExternalIPs` plugin | very low | ❌ Disable admission-wide |
| `hostPort` | that port on the scheduled node | ✅ PSS `baseline` | low | ❌ Except infra DaemonSets |
| `hostNetwork: true` | **every** container port on the node, bypasses NetworkPolicy | ✅ PSS `baseline` | low | ❌ Except CNI/monitoring |
| Ingress controller | one LB, terminated TLS, L7 routing, WAF hook | n/a | high (Ingress objects) | ✅ The sanctioned path |
| Gateway API | same, richer, role-separated | n/a | high | ✅ Where available |
| `kubectl port-forward` | ephemeral, on the operator's laptop, authenticated + audited | n/a | high (audit log) | ✅ For debugging |

### 2.5 Netfilter traversal: where a packet is actually filterable

This table is the difference between a rule that works and a rule that silently does nothing.

| Traffic | Hooks traversed (in order) | Correct filter point |
|---|---|---|
| To a host process (`sshd`, kubelet, etcd) | `prerouting raw(-300)` → `conntrack(-200)` → `prerouting mangle(-150)` → `prerouting dstnat(-100)` → **routing: local** → `input filter(0)` | `input` ✅ |
| To a NodePort → DNAT'd to a pod IP | `prerouting raw` → `conntrack` → `prerouting mangle` → **`prerouting dstnat` — kube-proxy DNATs here** → **routing: not local** → `forward filter(0)` → `postrouting srcnat(100)` | `prerouting` at priority < `-100`, or `forward` ✅ — **`input` NEVER matches** ❌ |
| To a `hostPort` → DNAT'd by the CNI `portmap` plugin | identical to NodePort (`CNI-HOSTPORT-DNAT` in `prerouting nat`) | same as NodePort |
| From the host outbound | `output filter(0)` → `postrouting srcnat` | `output` ✅ |
| From a pod outbound (veth → host → WAN) | `prerouting` → `forward filter` → `postrouting srcnat` (masquerade) | `forward` ✅ |

**The single most common hardening bug**: an operator writes `nft add rule inet filter input tcp dport 30000-32767 drop`, verifies the rule exists, and the NodePort is still reachable from the internet. It always will be — the packet is DNAT'd to a pod IP in `prerouting` and therefore routed to `forward`, never to `input`. Correct answers: filter at `hook prerouting priority -150`, filter in `forward`, or set `nodePortAddresses` so kube-proxy never installs the rule for that interface at all.

> Edge case for completeness: with `externalTrafficPolicy: Local` **and** a `hostNetwork` backend pod, the DNAT target is the node IP itself, so the packet *does* reach `input`. Do not rely on this asymmetry — filter in `prerouting`.

---

## 3. Complete manifests and infrastructure

### 3.1 Baseline inventory before touching anything

```bash
$ sudo ss -tulpn
Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process
udp    UNCONN  0       0         127.0.0.53%lo:53          0.0.0.0:*      users:(("systemd-resolve",pid=712,fd=14))
udp    UNCONN  0       0          10.0.0.11%ens3:68          0.0.0.0:*      users:(("systemd-network",pid=698,fd=20))
udp    UNCONN  0       0               0.0.0.0:8472         0.0.0.0:*
tcp    LISTEN  0       4096          127.0.0.1:10248        0.0.0.0:*      users:(("kubelet",pid=1201,fd=25))
tcp    LISTEN  0       4096          127.0.0.1:10249        0.0.0.0:*      users:(("kube-proxy",pid=2310,fd=15))
tcp    LISTEN  0       4096          127.0.0.1:2379         0.0.0.0:*      users:(("etcd",pid=1690,fd=8))
tcp    LISTEN  0       4096          10.0.0.11:2379         0.0.0.0:*      users:(("etcd",pid=1690,fd=9))
tcp    LISTEN  0       4096          10.0.0.11:2380         0.0.0.0:*      users:(("etcd",pid=1690,fd=7))
tcp    LISTEN  0       4096          127.0.0.1:2381         0.0.0.0:*      users:(("etcd",pid=1690,fd=6))
tcp    LISTEN  0       4096          127.0.0.1:10257        0.0.0.0:*      users:(("kube-controller",pid=1655,fd=3))
tcp    LISTEN  0       4096          127.0.0.1:10259        0.0.0.0:*      users:(("kube-scheduler",pid=1633,fd=3))
tcp    LISTEN  0       4096                  *:6443               *:*      users:(("kube-apiserver",pid=1712,fd=3))
tcp    LISTEN  0       4096                  *:10250              *:*      users:(("kubelet",pid=1201,fd=24))
tcp    LISTEN  0       4096                  *:10256              *:*      users:(("kube-proxy",pid=2310,fd=17))
tcp    LISTEN  0       128                   *:22                 *:*      users:(("sshd",pid=964,fd=4))
tcp    LISTEN  0       4096                  *:111                *:*      users:(("rpcbind",pid=690,fd=8))
tcp    LISTEN  0       5             127.0.0.1:631          0.0.0.0:*      users:(("cupsd",pid=701,fd=7))
```

Two lines there should make you stop: `rpcbind` on `*:111` and `cupsd`. Neither belongs on a Kubernetes node. That is the "minimize host OS footprint" half of this objective meeting the network half.

Machine-readable inventory of everything bound to a non-loopback address:

```bash
$ sudo ss -Hltunp | awk '{print $1, $5, $7}' \
    | grep -vE '127\.0\.0\.[0-9]+:|\[::1\]:' \
    | sed -E 's/users:\(\("([^"]+)".*/\1/' | sort -u
tcp  *:10250                kubelet
tcp  *:10256                kube-proxy
tcp  *:111                  rpcbind
tcp  *:22                   sshd
tcp  *:6443                 kube-apiserver
tcp  10.0.0.11:2379         etcd
tcp  10.0.0.11:2380         etcd
udp  0.0.0.0:8472           -
```

### 3.2 Remove what should not be listening at all

```bash
$ systemctl list-units --type=socket --state=active --no-pager --no-legend
  avahi-daemon.socket    loaded active running Avahi mDNS/DNS-SD Stack Activation Socket
  cups.socket            loaded active running CUPS Scheduler
  dbus.socket            loaded active running D-Bus System Message Bus Socket
  rpcbind.socket         loaded active running RPCbind Server Activation Socket
  systemd-udevd-control.socket loaded active running udev Control Socket

$ sudo systemctl disable --now avahi-daemon.socket avahi-daemon.service \
                                cups.socket cups.service \
                                rpcbind.socket rpcbind.service
Removed "/etc/systemd/system/sockets.target.wants/avahi-daemon.socket".
Removed "/etc/systemd/system/multi-user.target.wants/cups.service".
Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".

$ sudo systemctl mask avahi-daemon.socket cups.socket rpcbind.socket
Created symlink /etc/systemd/system/avahi-daemon.socket → /dev/null.
Created symlink /etc/systemd/system/cups.socket → /dev/null.
Created symlink /etc/systemd/system/rpcbind.socket → /dev/null.
```

`mask` rather than `disable` matters: a package update or a socket-activated dependency can re-enable a merely-disabled unit; a masked unit cannot start.

### 3.3 `/etc/nftables.conf` — worker node, complete

```nft
#!/usr/sbin/nft -f
#
# /etc/nftables.conf — Kubernetes worker node baseline (CKS v1.34 reference)
# Enforcement model:
#   prerouting_guard  : filters NodePort/hostPort BEFORE kube-proxy DNAT (priority -150)
#   input             : default-deny for traffic terminating on the host
#   forward           : pod egress restrictions (link-local metadata)
#   output            : host egress restrictions
#
# Apply with:  sudo nft -f /etc/nftables.conf
# Persist with: sudo systemctl enable --now nftables.service

flush ruleset

define WAN_IF    = "ens3"
define POD_CIDR  = 10.244.0.0/16
define SVC_CIDR  = 10.96.0.0/12
define IMDS      = 169.254.169.254

table inet k8s_node {

    # --- address sets: the only thing you edit day to day -------------------
    set admin_cidrs {
        type ipv4_addr
        flags interval
        comment "Bastion hosts / SRE jump boxes allowed to SSH"
        elements = { 10.0.100.0/24, 198.51.100.7/32 }
    }

    set control_plane {
        type ipv4_addr
        comment "kube-apiserver source IPs allowed to reach the kubelet"
        elements = { 10.0.0.11, 10.0.0.12, 10.0.0.13 }
    }

    set cluster_nodes {
        type ipv4_addr
        flags interval
        comment "All node IPs: CNI data plane and node-to-node health"
        elements = { 10.0.0.0/24 }
    }

    set lb_subnets {
        type ipv4_addr
        flags interval
        comment "Cloud/HAProxy load balancers allowed to health-check and hit NodePorts"
        elements = { 10.0.200.0/24 }
    }

    # --- ring 1a: pre-DNAT guard -------------------------------------------
    # Runs at priority -150: AFTER conntrack (-200) so ct state is valid,
    # BEFORE dstnat (-100) so kube-proxy has not yet rewritten the destination.
    # This is the ONLY correct place to filter NodePort and hostPort traffic.
    chain prerouting_guard {
        type filter hook prerouting priority -150; policy accept;

        iifname != $WAN_IF accept
        ct state established,related accept

        ip saddr @cluster_nodes accept
        ip saddr @admin_cidrs   accept
        ip saddr @lb_subnets tcp dport 30000-32767 accept
        ip saddr @lb_subnets udp dport 30000-32767 accept

        tcp dport 30000-32767 limit rate 5/minute log prefix "nft nodeport-drop: " level warn
        tcp dport 30000-32767 counter drop
        udp dport 30000-32767 counter drop
    }

    # --- ring 1b: host-terminated traffic ----------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid counter drop

        # CNI / overlay interfaces are trusted; pods reach node services
        # through these, not through the WAN NIC.
        iifname "cilium_host" accept
        iifname "cilium_net"  accept
        iifname "lxc*"        accept
        iifname "cni0"        accept
        iifname "flannel.1"   accept
        iifname "vxlan.calico" accept

        # DHCP client (broadcast replies do not match conntrack)
        udp sport 67 udp dport 68 accept

        # ICMP: keep PMTUD working or you will chase phantom TLS hangs
        ip protocol icmp icmp type { echo-request, echo-reply,
                                     destination-unreachable,
                                     time-exceeded, parameter-problem } \
            limit rate 20/second accept
        meta l4proto ipv6-icmp accept

        # --- SSH: bastion only, rate limited, everything else logged --------
        ip saddr @admin_cidrs tcp dport 22 ct state new \
            limit rate 6/minute burst 3 packets accept
        ip saddr @admin_cidrs tcp dport 22 accept
        tcp dport 22 limit rate 5/minute log prefix "nft ssh-drop: " level warn
        tcp dport 22 counter drop

        # --- kubelet API: control plane and peer nodes only ----------------
        ip saddr @control_plane  tcp dport 10250 accept
        ip saddr @cluster_nodes  tcp dport 10250 accept

        # --- kube-proxy healthz: load balancers + peers --------------------
        ip saddr @lb_subnets     tcp dport 10256 accept
        ip saddr @cluster_nodes  tcp dport 10256 accept

        # --- CNI data plane: peer nodes only -------------------------------
        # Cilium: 8472/udp VXLAN, 4240/tcp health, 51871/udp WireGuard
        # Calico: 4789/udp VXLAN, 179/tcp BGP, 5473/tcp Typha, 51820/udp WG
        ip saddr @cluster_nodes udp dport { 8472, 4789, 51820, 51871 } accept
        ip saddr @cluster_nodes tcp dport { 4240, 179, 5473 } accept

        # --- node exporter, scraped from the monitoring subnet only --------
        ip saddr @cluster_nodes tcp dport 9100 accept

        limit rate 10/second log prefix "nft input-drop: " level info flags all
        counter drop
    }

    # --- ring 1c: transit traffic (pod egress, NodePort after DNAT) ---------
    chain forward {
        type filter hook forward priority filter; policy accept;

        ct state established,related accept

        # Pods must never reach the cloud instance metadata service.
        # NOTE: with Cilium in full eBPF host-routing mode this hook may be
        # bypassed — enforce the same rule with a CiliumNetworkPolicy too.
        ip saddr $POD_CIDR ip daddr $IMDS \
            limit rate 5/minute log prefix "nft imds-drop: " level warn
        ip saddr $POD_CIDR ip daddr $IMDS counter drop

        # Pods must not reach the node management subnet directly.
        ip saddr $POD_CIDR ip daddr 10.0.100.0/24 counter drop

        # Belt-and-braces for NodePort that slipped past prerouting_guard.
        iifname $WAN_IF ip daddr $POD_CIDR ct state new \
            tcp dport 30000-32767 counter drop
    }

    # --- ring 1d: host egress ----------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;

        # Everything else on the host is allowed out; tighten per environment.
        # Example lockdown of an unused protocol family:
        meta l4proto sctp counter drop
    }
}
```

Apply with a rollback timer so a mistake cannot lock you out:

```bash
$ sudo cp /etc/nftables.conf /etc/nftables.conf.bak
$ sudo nft -c -f /etc/nftables.conf.new           # syntax check only, does not load
$ sudo systemd-run --on-active=180 --unit=nft-rollback \
      /usr/sbin/nft -f /etc/nftables.conf.bak
Running timer as unit: nft-rollback.timer
Will run service as unit: nft-rollback.service

$ sudo nft -f /etc/nftables.conf.new
# --- open a SECOND ssh session now and confirm it works ---
$ sudo systemctl stop nft-rollback.timer
$ sudo cp /etc/nftables.conf.new /etc/nftables.conf
$ sudo systemctl enable --now nftables.service
Created symlink /etc/systemd/system/multi-user.target.wants/nftables.service → /usr/lib/systemd/system/nftables.service.
```

On Fedora/RHEL, make sure `firewalld` is not fighting you:

```bash
$ sudo systemctl disable --now firewalld
$ sudo systemctl mask firewalld
Created symlink /etc/systemd/system/firewalld.service → /dev/null.
```

### 3.4 `/etc/nftables.conf` — control-plane delta

Add this table (or these chains) on control-plane nodes:

```nft
table inet k8s_control_plane {
    set etcd_peers {
        type ipv4_addr
        comment "Other etcd members ONLY — never the worker subnet"
        elements = { 10.0.0.11, 10.0.0.12, 10.0.0.13 }
    }

    set apiserver_clients {
        type ipv4_addr
        flags interval
        comment "Nodes, LBs, and the SRE bastion subnet"
        elements = { 10.0.0.0/24, 10.0.200.0/24, 10.0.100.0/24 }
    }

    chain input {
        type filter hook input priority filter + 5; policy accept;

        # etcd: strictly peer-to-peer. A worker node reaching 2379 is an
        # incident, not a feature.
        ip saddr @etcd_peers tcp dport { 2379, 2380 } accept
        tcp dport { 2379, 2380 } \
            log prefix "nft etcd-drop: " level warn counter drop

        # kube-apiserver
        ip saddr @apiserver_clients tcp dport 6443 accept
        tcp dport 6443 counter drop

        # controller-manager / scheduler must never be reachable off-box.
        tcp dport { 10257, 10259 } \
            log prefix "nft cp-secure-port-drop: " level warn counter drop
    }
}
```

> Note the `priority filter + 5`: this chain is traversed *after* the `k8s_node` `input` chain (priority 0). Since `k8s_node input` has `policy drop`, packets it drops never arrive here. Keep the control-plane chain's policy `accept` and rely on explicit drops, or merge both into one table. Mixing default-deny across two base chains on the same hook is a classic source of "the rule exists but nothing matches".

### 3.5 Ring 2 — kube-proxy: stop opening NodePorts everywhere

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    app: kube-proxy
data:
  config.conf: |-
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    bindAddress: 0.0.0.0
    bindAddressHardFail: false
    clientConnection:
      acceptContentTypes: ""
      burst: 10
      contentType: application/vnd.kubernetes.protobuf
      kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
      qps: 5
    clusterCIDR: 10.244.0.0/16
    configSyncPeriod: 15m0s
    conntrack:
      maxPerCore: 32768
      min: 131072
      tcpCloseWaitTimeout: 1h0m0s
      tcpEstablishedTimeout: 24h0m0s
    detectLocalMode: ClusterCIDR
    enableProfiling: false
    healthzBindAddress: 0.0.0.0:10256
    hostnameOverride: ""
    iptables:
      localhostNodePorts: false
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 1s
      syncPeriod: 30s
    ipvs:
      excludeCIDRs: null
      minSyncPeriod: 0s
      scheduler: ""
      strictARP: false
      syncPeriod: 30s
    metricsBindAddress: 127.0.0.1:10249
    mode: iptables
    # ── THE control that matters for 5.3 ────────────────────────────────
    # kube-proxy only installs NodePort rules for addresses inside these
    # CIDRs. An empty list (the default) means "every address on the node",
    # which is how NodePorts end up reachable from the public NIC.
    nodePortAddresses:
      - 10.0.0.0/24
    # ────────────────────────────────────────────────────────────────────
    oomScoreAdj: -999
    portRange: ""
    showHiddenMetricsForVersion: ""
```

```bash
$ kubectl -n kube-system apply -f kube-proxy-cm.yaml
configmap/kube-proxy configured

$ kubectl -n kube-system rollout restart daemonset/kube-proxy
daemonset.apps/kube-proxy restarted

$ kubectl -n kube-system rollout status daemonset/kube-proxy
Waiting for daemon set "kube-proxy" rollout to finish: 2 out of 4 new pods have been updated...
daemon set "kube-proxy" successfully rolled out
```

Trade-offs to state explicitly:

| Setting | Effect | Cost |
|---|---|---|
| `nodePortAddresses: [10.0.0.0/24]` | NodePorts bind only on the private NIC | An external LB outside that CIDR can no longer reach NodePorts directly |
| `enableProfiling: false` | Removes `/debug/pprof` from the healthz server | No live pprof; use ephemeral debug builds |
| `metricsBindAddress: 127.0.0.1:10249` | Metrics not reachable off-node | Prometheus must scrape via a hostNetwork sidecar or the node exporter |
| `healthzBindAddress: 127.0.0.1:10256` | Fully closes 10256 | **Breaks cloud LB health checks** for `externalTrafficPolicy: Local` — leave on `0.0.0.0` and firewall it to the LB subnet instead |
| `iptables.localhostNodePorts: false` | NodePorts not reachable via `127.0.0.1` | Local debug loops must use the node IP |

Recent kube-proxy releases also accept the special value `nodePortAddresses: ["primary"]` (bind only on the primary node IP). Verify availability on the cluster in front of you before relying on it:

```bash
$ kubectl -n kube-system exec ds/kube-proxy -- kube-proxy --help 2>&1 | grep -A3 nodeport-addresses
      --nodeport-addresses strings   A list of CIDR ranges that contain valid node IPs, or
                                     alternatively, the single string 'primary'. ...
```

Shrink the range itself on the API server so the hole is small even when NodePorts are allowed:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml  (excerpt)
    - --service-node-port-range=30000-30100
```

### 3.6 Ring 3 — component binding and authn/authz

`/var/lib/kubelet/config.yaml` (complete, the parts that matter for 5.3 marked):

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
address: 0.0.0.0                 # bind address of the 10250 API
port: 10250
readOnlyPort: 0                  # ← 10255 must stay closed. Never set this to 10255.
healthzBindAddress: 127.0.0.1    # ← 10248 stays on loopback
healthzPort: 10248
authentication:
  anonymous:
    enabled: false               # ← unauthenticated callers get 401
  webhook:
    enabled: true                # ← bearer tokens validated via TokenReview
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # ← mTLS against the cluster CA
authorization:
  mode: Webhook                  # ← never AlwaysAllow; SubjectAccessReview per request
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
tlsCertFile: /var/lib/kubelet/pki/kubelet.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet.key
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
tlsMinVersion: VersionTLS12
rotateCertificates: true
serverTLSBootstrap: true
protectKernelDefaults: true
makeIPTablesUtilChains: true
streamingConnectionIdleTimeout: 5m0s
enableDebuggingHandlers: true    # set false to remove exec/attach/portforward
                                 # from the kubelet — breaks `kubectl exec`
eventRecordQPS: 5
clusterDomain: cluster.local
clusterDNS:
  - 10.96.0.10
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests
```

```bash
$ sudo systemctl restart kubelet
$ sudo journalctl -u kubelet -n 5 --no-pager
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.113 4188 server.go:466] "Kubelet version" kubeletVersion="v1.34.1"
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.311 4188 server.go:1245] "Started kubelet"
Aug 04 09:41:02 node-1 kubelet[4188]: I0804 09:41:02.315 4188 server.go:236] "Starting to listen" address="0.0.0.0" port=10250
```

`/etc/kubernetes/manifests/kube-apiserver.yaml` — the flags relevant to external access:

```yaml
    - --bind-address=0.0.0.0                       # cannot be loopback in a multi-node cluster
    - --secure-port=6443
    - --anonymous-auth=false
    - --profiling=false
    - --service-node-port-range=30000-30100
    - --enable-admission-plugins=NodeRestriction,DenyServiceExternalIPs,PodSecurity
    - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS
    - --egress-selector-config-file=/etc/kubernetes/konnectivity/egress-selector.yaml
```

`DenyServiceExternalIPs` is a built-in admission plugin that rejects any Service specifying `spec.externalIPs` — the cheapest possible fix for the worst exposure primitive in the API.

`/etc/kubernetes/manifests/etcd.yaml`:

```yaml
    - --listen-client-urls=https://127.0.0.1:2379,https://10.0.0.11:2379
    - --advertise-client-urls=https://10.0.0.11:2379
    - --listen-peer-urls=https://10.0.0.11:2380
    - --listen-metrics-urls=http://127.0.0.1:2381
    - --client-cert-auth=true
    - --peer-client-cert-auth=true
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

`kube-controller-manager` / `kube-scheduler`:

```yaml
    - --bind-address=127.0.0.1
    - --profiling=false
```

**Konnectivity — minimizing API server egress.** By default the API server dials `10250` and pod/service endpoints directly from the control-plane network. `EgressSelectorConfiguration` funnels that through a proxy so the control plane needs no direct route into the cluster network:

```yaml
# /etc/kubernetes/konnectivity/egress-selector.yaml
apiVersion: apiserver.k8s.io/v1beta1
kind: EgressSelectorConfiguration
egressSelections:
  - name: cluster
    connection:
      proxyProtocol: GRPC
      transport:
        uds:
          udsName: /etc/kubernetes/konnectivity-server/konnectivity-server.socket
  - name: controlplane
    connection:
      proxyProtocol: Direct
  - name: etcd
    connection:
      proxyProtocol: Direct
```

### 3.7 Ring 2 — Cilium host firewall (declarative node policy)

Enable the host firewall and tell Cilium which devices to attach to:

```bash
$ helm upgrade cilium cilium/cilium --version 1.18.1 \
    --namespace kube-system --reuse-values \
    --set hostFirewall.enabled=true \
    --set devices='{ens3}'
Release "cilium" has been upgraded. Happy Helming!

$ kubectl -n kube-system rollout restart ds/cilium
daemonset.apps/cilium restarted
```

**Always audit before enforcing** — a `CiliumClusterwideNetworkPolicy` with a `nodeSelector` flips the host endpoint from default-allow to default-deny and can lock the whole fleet out at once:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint list | grep 'reserved:host'
1364       Disabled           Disabled          1          reserved:host   ready

$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint config 1364 PolicyAuditMode=Enabled
Endpoint 1364 configuration updated successfully
```

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: host-firewall-workers
spec:
  description: >-
    Default-deny on the host network namespace of worker nodes. Only the
    control plane, peer nodes, the bastion subnet and the load balancers may
    open new connections to a node.
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  ingress:
    # Cilium-internal entities: health checks, peer nodes, the API server,
    # and traffic originating from the node itself.
    - fromEntities:
        - health
        - remote-node
        - kube-apiserver
        - host

    # kubelet API strictly from control-plane addresses.
    - fromCIDRSet:
        - cidr: 10.0.0.11/32
        - cidr: 10.0.0.12/32
        - cidr: 10.0.0.13/32
      toPorts:
        - ports:
            - port: "10250"
              protocol: TCP

    # SSH strictly from the bastion subnet.
    - fromCIDRSet:
        - cidr: 10.0.100.0/24
      toPorts:
        - ports:
            - port: "22"
              protocol: TCP

    # Load-balancer health checks.
    - fromCIDRSet:
        - cidr: 10.0.200.0/24
      toPorts:
        - ports:
            - port: "10256"
              protocol: TCP

    # CNI data plane between nodes.
    - fromCIDRSet:
        - cidr: 10.0.0.0/24
      toPorts:
        - ports:
            - port: "8472"
              protocol: UDP
            - port: "4240"
              protocol: TCP
            - port: "51871"
              protocol: UDP
  egress:
    - toEntities:
        - remote-node
        - kube-apiserver
        - cluster
    # DNS and package/registry egress via the corporate proxy only.
    - toCIDRSet:
        - cidr: 10.0.50.0/24
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "3128"
              protocol: TCP
    # Explicitly deny the metadata service from the host too.
    - toCIDRSet:
        - cidr: 0.0.0.0/0
          except:
            - 169.254.169.254/32
```

Read the audit verdicts before enforcing:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg monitor -t policy-verdict --related-to 1364
Policy verdict log: flow 0x0 local EP ID 1364, remote ID 6, proto 6, ingress, action audit, match none, 10.0.77.4:51234 -> 10.0.0.21:9100 tcp SYN
Policy verdict log: flow 0x0 local EP ID 1364, remote ID 1, proto 6, ingress, action allow, match L3-L4, 10.0.0.11:44210 -> 10.0.0.21:10250 tcp SYN
```

The `action audit, match none` line is a connection that *would have been dropped* — node-exporter scraping on 9100 from a monitoring subnet not in the policy. Fix the policy, re-audit until the log is clean, then:

```bash
$ kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg endpoint config 1364 PolicyAuditMode=Disabled
Endpoint 1364 configuration updated successfully
```

### 3.8 Ring 2 — Calico host endpoints (with pre-DNAT)

```yaml
apiVersion: projectcalico.org/v3
kind: HostEndpoint
metadata:
  name: node-1-ens3
  labels:
    host-endpoint: "true"
    role: k8s-worker
spec:
  interfaceName: ens3
  node: node-1
  expectedIPs:
    - 10.0.0.21
---
apiVersion: projectcalico.org/v3
kind: GlobalNetworkPolicy
metadata:
  name: node-perimeter
spec:
  selector: has(host-endpoint)
  order: 100
  # preDNAT + applyOnForward is what lets this policy see NodePort traffic
  # BEFORE kube-proxy rewrites the destination — the Calico equivalent of the
  # nftables prerouting_guard chain.
  preDNAT: true
  applyOnForward: true
  types:
    - Ingress
  ingress:
    - action: Allow
      source:
        nets:
          - 10.0.0.0/24      # peer nodes
          - 10.0.100.0/24    # bastion
          - 10.0.200.0/24    # load balancers
    - action: Log
      protocol: TCP
      destination:
        ports: [30000, 30001, 30002]
    - action: Deny
      protocol: TCP
      destination:
        ports: ["30000:32767"]
    - action: Deny
      protocol: UDP
      destination:
        ports: ["30000:32767"]
```

> **Calico lock-out warning**: the instant a `HostEndpoint` exists for an interface, Calico applies default-deny to it, with only the *failsafe* ports still open. Inspect and, if necessary, widen the failsafes **before** creating the HostEndpoint:
> ```bash
> $ calicoctl get felixconfiguration default -o yaml | grep -A20 failsafe
> ```
> The defaults include inbound 22, 68, 179, 2379, 2380, 5473, 6443, 6666, 6667 and outbound 53, 67, 179, 2379, 2380, 5473, 6443, 6666, 6667. Never remove 22 and 6443 from the inbound list on a remote host.

### 3.9 Ring 4 — admission control: prevent the hole from being requested

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: restrict-external-service-exposure
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["services"]
  validations:
    - expression: "object.spec.type != 'NodePort'"
      message: >-
        Service type NodePort is not permitted: it opens a port on every node
        in the cluster. Expose the workload through the shared Ingress
        controller instead.
      reason: Forbidden

    - expression: >-
        object.spec.type != 'LoadBalancer' ||
        (has(object.metadata.annotations) &&
         'service.beta.kubernetes.io/aws-load-balancer-scheme' in object.metadata.annotations &&
         object.metadata.annotations['service.beta.kubernetes.io/aws-load-balancer-scheme'] == 'internal')
      message: >-
        LoadBalancer Services must be annotated
        service.beta.kubernetes.io/aws-load-balancer-scheme=internal.
        Internet-facing load balancers require a platform-team exception.
      reason: Forbidden

    - expression: "!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0"
      message: >-
        spec.externalIPs is forbidden: it lets a namespaced object hijack
        arbitrary destination IPs cluster-wide.
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: restrict-external-service-exposure-binding
spec:
  policyName: restrict-external-service-exposure
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "ingress-nginx", "platform-break-glass"]
```

```bash
$ kubectl apply -f restrict-external-service-exposure.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/restrict-external-service-exposure created
validatingadmissionpolicybinding.admissionregistration.k8s.io/restrict-external-service-exposure-binding created

$ kubectl -n team-a create service nodeport admin-ui --tcp=80:8080
error: failed to create NodePort service: services "admin-ui" is forbidden:
ValidatingAdmissionPolicy 'restrict-external-service-exposure' with binding
'restrict-external-service-exposure-binding' denied request: Service type
NodePort is not permitted: it opens a port on every node in the cluster.
Expose the workload through the shared Ingress controller instead.
```

Close `hostNetwork` and `hostPort` with the built-in Pod Security admission — `baseline` forbids both:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.34
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.34
```

```bash
$ kubectl -n team-a run hn --image=nginx:1.27 --overrides='{"spec":{"hostNetwork":true}}'
Error from server (Forbidden): pods "hn" is forbidden: violates PodSecurity
"baseline:v1.34": host namespaces (hostNetwork=true)
```

### 3.10 Pod egress: blocking the metadata service in the API layer

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-internet-except-linklocal
  namespace: team-a
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    # CoreDNS only
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
    # Public internet, with every RFC1918 range and the whole 169.254.0.0/16
    # link-local block carved out. 169.254.169.254 is the cloud IMDS.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

Complement at the cloud layer — on AWS, IMDSv2 with a hop limit of 1 makes the metadata service unreachable from inside a pod's network namespace regardless of policy:

```bash
$ aws ec2 modify-instance-metadata-options \
    --instance-id i-0abc123def4567890 \
    --http-tokens required \
    --http-put-response-hop-limit 1 \
    --http-endpoint enabled
{
    "InstanceId": "i-0abc123def4567890",
    "InstanceMetadataOptions": {
        "State": "pending",
        "HttpTokens": "required",
        "HttpPutResponseHopLimit": 1,
        "HttpEndpoint": "enabled"
    }
}
```

### 3.11 `/etc/ssh/sshd_config.d/50-hardening.conf`

```
# Bind only to the management interface; do not answer on the public NIC.
AddressFamily inet
ListenAddress 10.0.0.21

# Authentication
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowGroups k8s-admins
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20

# Forwarding: disabling TCP forwarding also blocks `ssh -L` tunnels to the
# API server. Keep it off on workers; allow it on the bastion only.
AllowTcpForwarding no
AllowAgentForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no

# Session hygiene
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
LogLevel VERBOSE
Banner /etc/issue.net

# Crypto
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
```

```bash
$ sudo sshd -t && echo "config OK"
config OK

$ sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|allowtcpforwarding|listenaddress|allowgroups)'
listenaddress 10.0.0.21:22
permitrootlogin no
passwordauthentication no
allowtcpforwarding no
allowgroups k8s-admins

$ sudo systemctl reload sshd
```

---

## 4. Verification: proving the surface is actually closed

### 4.1 External port scan from outside the perimeter

```bash
$ sudo nmap -Pn -n -sS --reason \
    -p 22,111,179,2379,2380,4240,5473,6443,9100,10248,10249,10250,10255,10256,10257,10259,30000-30100 \
    10.0.0.21
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-04 09:58 UTC
Nmap scan report for 10.0.0.21
Host is up, received user-set (0.00061s latency).
Not shown: 114 filtered tcp ports (no-response)
PORT      STATE  SERVICE      REASON
22/tcp    open   ssh          syn-ack ttl 64
10250/tcp open   unknown      syn-ack ttl 64
10256/tcp open   unknown      syn-ack ttl 64

Nmap done: 1 IP address (1 host up) scanned in 2.31 seconds
```

Same scan from a host outside `admin_cidrs` and outside `cluster_nodes`:

```bash
$ sudo nmap -Pn -n -sS -p 22,10250,10256,30000-30100 10.0.0.21
Nmap scan report for 10.0.0.21
Host is up, received user-set (0.00088s latency).
All 104 scanned ports on 10.0.0.21 are in ignored states.
Not shown: 104 filtered tcp ports (no-response)

Nmap done: 1 IP address (1 host up) scanned in 2.14 seconds
```

`filtered` (no response) rather than `closed` (RST) is what a `drop` policy produces, and it is what you want: it gives a scanner no signal at all.

### 4.2 Kubelet reachability and authorization

```bash
# Anonymous, before hardening — full pod inventory, no credentials:
$ curl -sk https://10.0.0.21:10250/pods | jq -r '.items[].metadata.name' | head -3
kube-proxy-8bh2t
cilium-x2n7q
payments-api-7d9f8c5b4-lm2xk

# After anonymous-auth=false:
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.0.21:10250/pods
401

$ curl -sk https://10.0.0.21:10250/pods
Unauthorized

# With a valid but unprivileged ServiceAccount token — authenticated, denied:
$ TOKEN=$(kubectl -n team-a create token default)
$ curl -sk -H "Authorization: Bearer $TOKEN" https://10.0.0.21:10250/pods
Forbidden (user=system:serviceaccount:team-a:default, verb=get,
resource=nodes, subresource=proxy)

# Read-only port must refuse the connection outright:
$ curl -s --max-time 3 http://10.0.0.21:10255/pods; echo "exit=$?"
exit=7
```

Exit code 7 from `curl` is "failed to connect" — the socket does not exist. That is `readOnlyPort: 0` doing its job.

### 4.3 etcd must reject anything that is not a control-plane peer

```bash
$ ETCDCTL_API=3 etcdctl --endpoints=https://10.0.0.11:2379 \
    --command-timeout=5s get / --prefix --keys-only
{"level":"warn","ts":"2026-08-04T10:02:44.881Z","logger":"etcd-client",
 "caller":"v3@v3.5.16/retry_interceptor.go:63",
 "msg":"retrying of unary invoker failed",
 "error":"rpc error: code = DeadlineExceeded desc = latest balancer error:
 last connection error: connection error: desc = \"transport: authentication
 handshake failed: tls: failed to verify certificate: x509: certificate
 signed by unknown authority\""}
Error: context deadline exceeded

# Even skipping verification, client-cert-auth blocks it:
$ ETCDCTL_API=3 etcdctl --endpoints=https://10.0.0.11:2379 \
    --insecure-skip-tls-verify --command-timeout=5s endpoint health
{"level":"warn", ... "error":"... remote error: tls: certificate required"}
https://10.0.0.11:2379 is unhealthy: failed to commit proposal: context deadline exceeded

# From a worker node, the firewall should not even complete the handshake:
$ nc -zv -w3 10.0.0.11 2379
nc: connect to 10.0.0.11 port 2379 (tcp) timed out: Operation now in progress
```

### 4.4 NodePort really is unreachable (the rule that people get wrong)

```bash
$ kubectl -n team-a get svc admin-ui -o wide
NAME       TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE   SELECTOR
admin-ui   NodePort   10.96.201.44   <none>        80:31380/TCP   4m    app=admin-ui

# From inside the node subnet (allowed):
$ curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.21:31380/
200

# From outside every allowed set:
$ curl -s --max-time 4 -o /dev/null -w '%{http_code}\n' http://10.0.0.21:31380/
000
curl: (28) Connection timed out after 4001 milliseconds

# Confirm the drop counter is actually incrementing — this is the proof that
# your rule, not luck, is doing the blocking:
$ sudo nft list chain inet k8s_node prerouting_guard
table inet k8s_node {
        chain prerouting_guard {
                type filter hook prerouting priority mangle; policy accept;
                iifname != "ens3" accept
                ct state established,related accept
                ip saddr @cluster_nodes accept
                ip saddr @admin_cidrs accept
                ip saddr @lb_subnets tcp dport 30000-32767 accept
                ip saddr @lb_subnets udp dport 30000-32767 accept
                tcp dport 30000-32767 limit rate 5/minute log prefix "nft nodeport-drop: " level warn
                tcp dport 30000-32767 counter packets 12 bytes 720 drop
                udp dport 30000-32767 counter packets 0 bytes 0 drop
        }
}

$ sudo journalctl -k -n 3 --no-pager | grep nodeport-drop
Aug 04 10:07:19 node-1 kernel: nft nodeport-drop: IN=ens3 OUT= MAC=... SRC=203.0.113.90 DST=10.0.0.21 LEN=60 PROTO=TCP SPT=51882 DPT=31380 SYN
```

Cross-check that kube-proxy stopped installing the NodePort rule on non-allowed addresses:

```bash
$ sudo iptables -t nat -L KUBE-NODEPORTS -n --line-numbers
Chain KUBE-NODEPORTS (1 references)
num  target                     prot opt source       destination
1    KUBE-EXT-XPGD46QRK7WJZT7O  tcp  --  0.0.0.0/0    10.0.0.21   /* team-a/admin-ui */ tcp dpt:31380
```

With `nodePortAddresses` unset, `destination` would read `0.0.0.0/0`. The narrowed destination is the visible effect of the setting.

If your cluster runs kube-proxy in `nftables` mode instead:

```bash
$ sudo nft list table ip kube-proxy | grep -A6 'chain nodeport'
        chain nodeports {
                ip daddr @nodeport-ips meta l4proto tcp th dport 31380 goto service-XPGD46QR-team-a/admin-ui/tcp/http
        }

$ sudo nft list set ip kube-proxy nodeport-ips
table ip kube-proxy {
        set nodeport-ips {
                type ipv4_addr
                comment "IPs that accept NodePort traffic"
                elements = { 10.0.0.21 }
        }
}
```

### 4.5 Cluster-wide audit of exposure primitives

```bash
$ kubectl get svc -A -o json | jq -r '
    .items[]
    | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer" or (.spec.externalIPs|length>0))
    | [.metadata.namespace, .metadata.name, .spec.type,
       ((.spec.ports//[])|map(.nodePort|tostring)|join(",")),
       ((.spec.externalIPs//[])|join(","))]
    | @tsv' | column -t
team-a       admin-ui        NodePort      31380       
team-b       metrics-proxy   NodePort      30099       
ingress-nginx ingress-nginx-controller LoadBalancer 31234,30987  
legacy       vip-service     ClusterIP                 192.0.2.44

$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select(.spec.hostNetwork==true
             or ([.spec.containers[].ports//[] | .[]?.hostPort] | map(select(. != null)) | length > 0))
    | [.metadata.namespace, .metadata.name,
       (.spec.hostNetwork|tostring),
       ([.spec.containers[].ports//[] | .[]?.hostPort] | map(select(.!=null)) | join(","))]
    | @tsv' | column -t
kube-system  cilium-x2n7q            true
kube-system  kube-proxy-8bh2t        true
monitoring   node-exporter-4kd9v     true   9100
team-c       legacy-agent-6f8b7      false  8125
```

`legacy/vip-service` with a `spec.externalIPs` of `192.0.2.44` and `team-c/legacy-agent` binding `hostPort: 8125` are both findings. Neither would be created after §3.9 is in place.

### 4.6 Run the CIS benchmark and read the network controls

```bash
$ kube-bench run --targets master,node --check 1.2.16,1.3.2,1.4.2,4.2.4,4.2.10 --noremediations
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.16 Ensure that the --profiling argument is set to false
[INFO] 1.3 Controller Manager
[PASS] 1.3.2 Ensure that the --profiling argument is set to false
[INFO] 1.4 Scheduler
[PASS] 1.4.2 Ensure that the --bind-address argument is set to 127.0.0.1
[INFO] 4 Worker Node Security Configuration
[INFO] 4.2 Kubelet
[PASS] 4.2.4 Verify that the --read-only-port argument is set to 0
[PASS] 4.2.10 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set

== Summary total ==
5 checks PASS
0 checks FAIL
0 checks WARN
0 checks INFO
```

---

## 5. Failure diagnosis

### 5.1 Symptom → cause → command → fix

| Symptom | Most likely cause | Diagnostic command | Fix |
|---|---|---|---|
| Rule exists, NodePort still reachable from WAN | Filtering in `input`; packet is DNAT'd in `prerouting` and routed to `forward` | `sudo nft list chain inet k8s_node input` shows `counter packets 0` | Move the rule to `hook prerouting priority -150`, or set `nodePortAddresses` |
| `kubectl exec/logs/port-forward` hangs then `error: unable to upgrade connection: ... i/o timeout` | 10250 blocked from control-plane IPs | `nc -zv <cp-ip-as-source> <node-ip> 10250` from a control-plane node | Add control-plane IPs to the 10250 allow rule |
| `kubectl top nodes` → `Metrics API not available` | metrics-server pod (not the API server) is the caller of 10250 | `kubectl -n kube-system logs deploy/metrics-server \| tail` shows `dial tcp 10.0.0.21:10250: i/o timeout` | Allow the pod CIDR, or the node IP if metrics-server is `hostNetwork` |
| Pods on node A cannot reach pods on node B; same-node traffic fine | Overlay port dropped (8472/4789 UDP, 51820/51871 WireGuard) | `sudo nft list chain inet k8s_node input \| grep -E '8472\|4789'` and `journalctl -k \| grep input-drop \| grep DPT=8472` | Allow the CNI port from `@cluster_nodes` |
| Cilium `cilium-health status` shows peers unreachable | 4240/tcp dropped | `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --all-health` | Allow 4240 from `@cluster_nodes` |
| Calico nodes show `BGP not established` | 179/tcp dropped | `calicoctl node status` | Allow 179 from `@cluster_nodes` / ToR |
| Cloud LB marks all nodes unhealthy | `healthzBindAddress` moved to loopback, or 10256 firewalled off from the LB subnet | `curl -s http://<node-ip>:10256/healthz` from the LB subnet | Keep 10256 on `0.0.0.0`, allow only `@lb_subnets` |
| An existing session survives a new DROP rule | conntrack entry already `ESTABLISHED`; `ct state established accept` matches first | `sudo conntrack -L -d 10.0.0.21 --dport 31380` | `sudo conntrack -D -d 10.0.0.21 -p tcp --dport 31380` |
| All kube-proxy rules vanish after a config change | `firewalld --reload` flushed the tables | `sudo iptables -t nat -L KUBE-SERVICES -n \| wc -l` returns ~2 | Stop/mask firewalld; `kubectl -n kube-system rollout restart ds/kube-proxy` to reprogram |
| TLS handshakes hang at exactly 1500-ish bytes | ICMP `fragmentation-needed` dropped, PMTUD broken | `ping -M do -s 1472 <peer>` | Allow `icmp type destination-unreachable` in `input` |
| Whole fleet unreachable right after applying a CCNP | Cilium host firewall enforced without an audit pass | Console/serial access → `cilium-dbg endpoint config <id> PolicyAuditMode=Enabled` | Always audit first; keep a serial/console path |
| Node fine, one interface default-denied on Calico | `HostEndpoint` created; only failsafes remain open | `calicoctl get felixconfiguration default -o yaml` | Widen `failsafeInboundHostPorts` before creating HostEndpoints |
| Pod still reaches `169.254.169.254` despite the `forward` rule | Cilium eBPF host-routing bypasses the netfilter `forward` hook | `kubectl exec -it pod -- curl -s -m2 169.254.169.254/latest/meta-data/` returns data | Enforce with a `CiliumNetworkPolicy` egress `except`, and set IMDSv2 hop-limit 1 |

### 5.2 Tracing a packet through the hooks

When a rule "should" match and does not, stop guessing and trace:

```bash
$ sudo nft add table inet trace_debug
$ sudo nft add chain inet trace_debug prerouting \
    '{ type filter hook prerouting priority -350; }'
$ sudo nft add rule inet trace_debug prerouting \
    ip saddr 203.0.113.90 tcp dport 31380 meta nftrace set 1

$ sudo nft monitor trace
trace id 3f2a1b04 inet trace_debug prerouting packet: iif "ens3" ip saddr 203.0.113.90 ip daddr 10.0.0.21 tcp sport 51900 tcp dport 31380 tcp flags == syn
trace id 3f2a1b04 inet trace_debug prerouting rule ip saddr 203.0.113.90 tcp dport 31380 meta nftrace set 1 (verdict continue)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule iifname != "ens3" accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ct state established,related accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ip saddr @cluster_nodes accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule ip saddr @admin_cidrs accept (no match)
trace id 3f2a1b04 inet k8s_node prerouting_guard rule tcp dport 30000-32767 counter packets 13 bytes 780 drop (verdict drop)

$ sudo nft delete table inet trace_debug
```

The trace shows the packet dying in `prerouting_guard` before ever reaching `nat`. If instead you see it traverse `nat` and land in `forward`, your `input` rules were never in the path — that is the §2.5 mistake, proven rather than assumed.

The `iptables` equivalent for clusters still on legacy tooling:

```bash
$ sudo modprobe nf_log_ipv4
$ sudo sysctl -w net.netfilter.nf_log.2=nf_log_ipv4
net.netfilter.nf_log.2 = nf_log_ipv4
$ sudo iptables -t raw -I PREROUTING 1 -p tcp --dport 31380 -j TRACE
$ sudo journalctl -k -f | grep TRACE
kernel: TRACE: raw:PREROUTING:policy:2 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: nat:PREROUTING:rule:1 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: nat:KUBE-NODEPORTS:rule:1 IN=ens3 SRC=203.0.113.90 DST=10.0.0.21 PROTO=TCP SPT=51900 DPT=31380
kernel: TRACE: filter:FORWARD:rule:3 IN=ens3 OUT=lxc9f2a SRC=203.0.113.90 DST=10.244.1.17 PROTO=TCP SPT=51900 DPT=8080
$ sudo iptables -t raw -D PREROUTING -p tcp --dport 31380 -j TRACE
```

`filter:FORWARD` on the fourth line, with `DST` already rewritten to the pod IP — the packet never touched `INPUT`. Always delete the TRACE rule; it is extremely chatty.

### 5.3 Stale conntrack: why your new DROP "didn't take"

```bash
$ sudo conntrack -L -d 10.0.0.21 -p tcp --dport 31380 2>/dev/null
tcp 6 86395 ESTABLISHED src=203.0.113.90 dst=10.0.0.21 sport=51882 dport=31380 \
    src=10.244.1.17 dst=203.0.113.90 sport=8080 dport=51882 [ASSURED] mark=0 use=1
conntrack v1.4.7 (conntrack-tools): 1 flow entries have been shown.

$ sudo conntrack -D -d 10.0.0.21 -p tcp --dport 31380
tcp 6 86394 ESTABLISHED src=203.0.113.90 dst=10.0.0.21 sport=51882 dport=31380 ...
conntrack v1.4.7 (conntrack-tools): 1 flow entries have been deleted.
```

Any `ct state established,related accept` rule keeps pre-existing flows alive indefinitely — with `tcpEstablishedTimeout: 24h` in the kube-proxy config, an attacker's session outlives your fix by a day. Flushing conntrack for the affected tuple is a mandatory step of incident containment, not an optimization.

### 5.4 Verifying host egress restrictions

```bash
# From a pod — must fail after the NetworkPolicy and forward rule:
$ kubectl -n team-a run probe --rm -it --restart=Never --image=nicolaka/netshoot -- \
    curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://169.254.169.254/latest/meta-data/
000
command terminated with exit code 28
pod "probe" deleted

# From the node — should still work if the kubelet needs IMDS, blocked otherwise:
$ curl -s -m 3 -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
    -X PUT http://169.254.169.254/latest/api/token | head -c 20
AQAEAO1sX3F0aGVyZW...

$ sudo journalctl -k --since '5 min ago' | grep imds-drop
Aug 04 10:22:03 node-1 kernel: nft imds-drop: IN=lxc9f2a OUT=ens3 SRC=10.244.1.17 DST=169.254.169.254 LEN=60 PROTO=TCP SPT=44112 DPT=80 SYN
```

### 5.5 Continuous drift detection

A one-time hardening is worthless without a check that fails loudly. Minimum viable node-level check, runnable from CI or a DaemonSet:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-node-exposure.sh — exits non-zero on drift
set -euo pipefail

ALLOWED='^(22|6443|10250|10256|2379|2380)$'
fail=0

while read -r proto addr; do
    port="${addr##*:}"
    [[ "$addr" =~ ^(127\.|\[::1\]) ]] && continue
    if ! [[ "$port" =~ $ALLOWED ]]; then
        echo "DRIFT: unexpected listener ${proto} ${addr}" >&2
        fail=1
    fi
done < <(ss -Hltn | awk '{print "tcp", $4}')

if ! nft list chain inet k8s_node input >/dev/null 2>&1; then
    echo "DRIFT: nftables table inet k8s_node is missing" >&2
    fail=1
fi

if [[ "$(nft -j list chain inet k8s_node input \
        | jq -r '.nftables[] | select(.chain) | .chain.policy')" != "drop" ]]; then
    echo "DRIFT: input chain policy is not drop" >&2
    fail=1
fi

if grep -qE '^\s*readOnlyPort:\s*(?!0)' /var/lib/kubelet/config.yaml 2>/dev/null; then
    echo "DRIFT: kubelet readOnlyPort is not 0" >&2
    fail=1
fi

exit "$fail"
```

```bash
$ sudo /usr/local/sbin/verify-node-exposure.sh; echo "exit=$?"
exit=0

# After someone re-enables rpcbind:
$ sudo /usr/local/sbin/verify-node-exposure.sh; echo "exit=$?"
DRIFT: unexpected listener tcp 0.0.0.0:111
exit=1
```

---

## 6. Exam-day checklist

1. `ss -tulpn` first — never guess the listening surface.
2. `readOnlyPort: 0`, `anonymous.enabled: false`, `authorization.mode: Webhook` in `/var/lib/kubelet/config.yaml`, then `systemctl restart kubelet`.
3. `--bind-address=127.0.0.1` on controller-manager and scheduler; `--profiling=false` on all three control-plane components.
4. etcd `--client-cert-auth=true`, `--listen-client-urls` restricted.
5. NodePort filtering goes in `prerouting` (priority `-150`) or `forward`, **never** `input`; or set `nodePortAddresses` in the kube-proxy ConfigMap.
6. Never block `8472/udp`, `4789/udp`, `4240/tcp`, `179/tcp`, `51820/udp` between node IPs.
7. Mask, do not merely disable, unneeded socket units.
8. Always stage a rollback (`systemd-run --on-active`) before applying a default-deny ruleset to a remote node, and always audit before enforcing a Cilium/Calico host policy.
9. After any DROP rule, flush the matching conntrack entries.
10. Prove it with `nmap` from outside plus the rule counters — an unverified rule is a hypothesis.

---

## Referencias

**Curriculum**
- CKS Curriculum v1.34 (CNCF): https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CNCF curriculum repository: https://github.com/cncf/curriculum

**Kubernetes — network surface and components**
- Ports and Protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubelet authentication/authorization: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- KubeletConfiguration (v1beta1) API reference: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- kube-proxy configuration (v1alpha1) API reference: https://kubernetes.io/docs/reference/config-api/kube-proxy-config.v1alpha1/
- Virtual IPs and Service proxies (incl. nftables proxy mode): https://kubernetes.io/docs/reference/networking/virtual-ips/
- kube-apiserver command-line reference: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Service (NodePort, LoadBalancer, externalIPs): https://kubernetes.io/docs/concepts/services-networking/service/
- Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Gateway API: https://kubernetes.io/docs/concepts/services-networking/gateway/

**Kubernetes — policy and admission**
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Validating Admission Policy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Admission controllers (incl. `DenyServiceExternalIPs`, `NodeRestriction`): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Securing a cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Controlling access to the Kubernetes API: https://kubernetes.io/docs/concepts/security/controlling-access/
- Set up Konnectivity service: https://kubernetes.io/docs/tasks/extend-kubernetes/setup-konnectivity/

**CNI host-level policy**
- Cilium Host Firewall: https://docs.cilium.io/en/stable/security/host-firewall/
- Cilium network policy reference: https://docs.cilium.io/en/stable/security/policy/
- Cilium firewall rules / required ports: https://docs.cilium.io/en/stable/operations/system_requirements/
- Calico — protect hosts (HostEndpoint): https://docs.tigera.io/calico/latest/network-policy/hosts/protect-hosts
- Calico — Felix configuration (failsafe ports): https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- Calico — GlobalNetworkPolicy (`preDNAT`, `applyOnForward`): https://docs.tigera.io/calico/latest/reference/resources/globalnetworkpolicy

**Linux host firewalling**
- nftables wiki: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- Netfilter hooks and priorities: https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks
- `nft(8)` manual: https://www.netfilter.org/projects/nftables/manpage.html
- conntrack-tools: https://conntrack-tools.netfilter.org/
- firewalld documentation: https://firewalld.org/documentation/
- `sshd_config(5)`: https://man.openbsd.org/sshd_config

**Benchmarks and cloud metadata**
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench: https://github.com/aquasecurity/kube-bench
- AWS EC2 Instance Metadata Service (IMDSv2, hop limit): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- GKE Workload Identity (metadata concealment): https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Azure IMDS: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service