# 2.5 High Availability Installations

**Domain weight: 3.0** · Profile: SRE / Platform Architect · Target: production-grade `kubeadm` clusters

---

## 1. The architectural problem

A single-control-plane cluster is not "a cluster with one master". It is a cluster where **one host owns the only copy of the entire desired state**, and where every write path — Deployments scaling, CSI attaching volumes, the ingress controller reconciling routes, the kubelet reporting node status — terminates at one process on one disk.

The failure that matters is rarely "the control plane node exploded". It is subtler:

| Real incident | Single control plane | HA control plane (3 nodes) |
|---|---|---|
| Kernel panic on the control-plane host | Full API outage. Running Pods survive; nothing self-heals, no scaling, no rollout, no Service endpoint updates | ~5–15 s API blip while the LB drains the dead backend and leader election moves |
| `/var/lib/etcd` fills the root filesystem | etcd raises `NOSPACE`, cluster goes **read-only**, no recovery without manual defrag | Same alarm, but it is per-member; a single member can be defragmented while quorum serves traffic |
| Control-plane host OS upgrade | Scheduled outage of the API | Rolling maintenance, zero API downtime |
| etcd data corruption | Restore from snapshot = accepted data loss window | Raft repairs the member from the leader's log |
| Certificate expiry (365 d default) | Total outage, and `kubeadm certs renew` on a dead API | Same failure mode — **HA does not protect you from expiry**, it is a correlated failure |

The last row is the one that catches teams: HA is protection against *independent* failures. Correlated failures — expired CA-signed certs, a bad config pushed to all three nodes, a clock skew event, an exhausted `quota-backend-bytes` — take down all replicas simultaneously. Design accordingly: HA plus *staggered change* plus *tested restore*.

### 1.1 What is actually replicated

The control plane is not one thing. Each component has a different HA mechanism, and knowing which is which is the whole topic:

| Component | State | HA mechanism | Concurrency | If all replicas die |
|---|---|---|---|---|
| `kube-apiserver` | **Stateless** | N active replicas behind an L4 load balancer | All active (active/active) | No API at all; workloads keep running, nothing reconciles |
| `etcd` | **The only state** | Raft consensus, quorum writes | One leader, N-1 followers serve linearizable reads via the leader | API returns `500`; cluster is frozen |
| `kube-controller-manager` | Stateless (caches) | **Leader election** via `Lease` in `kube-system` | Exactly one active (active/passive) | No reconciliation: no ReplicaSet healing, no node eviction, no PV binding |
| `kube-scheduler` | Stateless | **Leader election** via `Lease` | Exactly one active | New Pods stay `Pending` forever |
| `cloud-controller-manager` | Stateless | Leader election | One active | No LB provisioning, no node lifecycle from the cloud API |
| `kubelet` (control-plane) | Local | Not HA — it is the thing that runs the static Pods | N/A | That node's control-plane Pods are unmanaged |
| CoreDNS | Stateless | Deployment replicas + anti-affinity | All active | In-cluster DNS resolution fails |

So an HA install is exactly three engineering decisions:

1. **Where does etcd live** (stacked vs external) → determines blast radius and operational coupling.
2. **How does a client reach a live `kube-apiserver`** (VIP, hardware/cloud LB, DNS) → determines failover time and cloud portability.
3. **How many failure domains** → determines what "tolerated failure" means in your infrastructure.

Everything else — leader election, Raft — is already built in and needs only correct configuration.

---

## 2. Quorum arithmetic — the non-negotiable constraint

etcd commits a write only when a **majority of members** persist it to their Raft log. Majority = `floor(N/2) + 1`.

| Members `N` | Quorum | Tolerated simultaneous failures | Verdict |
|---|---|---|---|
| 1 | 1 | 0 | Dev only. No HA. |
| 2 | 2 | **0** | **Worse than 1.** Twice the failure probability, zero tolerance. Never deploy. |
| 3 | 2 | 1 | **The default for production.** |
| 4 | 3 | 1 | Same tolerance as 3, higher write latency. Pointless. |
| 5 | 3 | 2 | Use when you need to survive an AZ loss *plus* one node, or during member replacement. |
| 6 | 4 | 2 | Pointless. |
| 7 | 4 | 3 | Write latency degrades noticeably; etcd docs cap the recommendation at 7. |

Two rules follow mechanically:

- **Always an odd number.** An even member count buys nothing and adds a member that must also acknowledge writes.
- **More members = more availability, less throughput.** Every write is an fsync on a majority of members, so p99 write latency is governed by the *slowest member of the quorum*, not the average.

### 2.1 Failure domains, not machines

Three etcd members on three VMs in one hypervisor is not HA — it is one failure domain wearing a hat. Map members to real independent domains:

| Layout | Members per AZ | Survives 1 AZ loss? | Notes |
|---|---|---|---|
| 3 members, 1 AZ | 3 | ❌ | Protects against host failure only |
| 3 members, 3 AZs | 1/1/1 | ✅ (quorum 2 of remaining 2) | **Canonical cloud layout** |
| 3 members, 2 AZs | 2/1 | ⚠️ Only if the AZ holding 2 survives | Asymmetric — do not do this |
| 5 members, 3 AZs | 2/2/1 | ✅ (worst case loses 2, quorum 3 of 3) | Survives AZ loss with zero remaining margin |
| 5 members, 2 regions | 3/2 | ❌ for the 2-member region | Cross-region etcd: see latency below |

### 2.2 The latency budget

etcd's tolerance is bounded by physics, not configuration:

| Metric | Healthy target | Meaning if breached |
|---|---|---|
| `etcd_disk_wal_fsync_duration_seconds` p99 | **< 10 ms** | Disk is too slow. Use local NVMe/SSD. Network storage (EBS gp2, NFS, Ceph RBD) for etcd is a chronic outage generator. |
| `etcd_disk_backend_commit_duration_seconds` p99 | < 25 ms | Backend b-tree commit pressure; often accompanies a large DB |
| `etcd_network_peer_round_trip_time_seconds` p99 | **< 50 ms** | Peers are too far apart; leader elections will flap |
| `etcd_server_leader_changes_seen_total` | Flat | Every increment is a ~1 s cluster-wide write stall |
| `etcd_server_has_leader` | `1` | `0` = quorum lost, cluster is read-only-ish and failing |
| DB size (`etcd_mvcc_db_total_size_in_bytes`) | < 8 GiB | `--quota-backend-bytes` hard ceiling; default 2 GiB |

Default timing is `--heartbeat-interval=100ms` and `--election-timeout=1000ms`. The rule from the etcd tuning guide: **heartbeat ≈ the p99 RTT between members**, and **election timeout ≥ 10× heartbeat**, capped at 50 000 ms. For members spread across AZs with 5–20 ms RTT, raise them:

```yaml
# stretched-AZ etcd timing, applied via kubeadm ClusterConfiguration (see §5.4)
--heartbeat-interval=250
--election-timeout=2500
```

Set the **same values on every member** — mismatched timing produces spurious elections that are extremely hard to diagnose.

---

## 3. Topology comparison: stacked vs external etcd

```
STACKED (kubeadm default)                    EXTERNAL
┌──────────── VIP / LB ────────────┐         ┌──────────── VIP / LB ────────────┐
│                                  │         │                                  │
┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐
│ apiserver  │ │ apiserver  │ │ apiserver  │ │ apiserver  │ │ apiserver  │ │ apiserver  │
│ ctrl-mgr   │ │ ctrl-mgr   │ │ ctrl-mgr   │ │ ctrl-mgr   │ │ ctrl-mgr   │ │ ctrl-mgr   │
│ scheduler  │ │ scheduler  │ │ scheduler  │ │ scheduler  │ │ scheduler  │ │ scheduler  │
│ etcd  ◄────┼─┼─► etcd ◄───┼─┼─► etcd     │ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
└────────────┘ └────────────┘ └────────────┘       └───────────────┼──────────────┘
  cp1            cp2            cp3                        mTLS ────┼──── :2379
                                                    ┌────────────┐ ┌┴───────────┐ ┌────────────┐
  3 hosts, coupled failure                          │  etcd-1 ◄──┼─┼─► etcd-2 ◄─┼─┼─► etcd-3   │
                                                    └────────────┘ └────────────┘ └────────────┘
                                                          6 hosts, decoupled failure
```

| Dimension | Stacked etcd | External etcd |
|---|---|---|
| Hosts for 3-way HA | 3 | 6 (3 CP + 3 etcd) |
| Blast radius of one host loss | Loses an apiserver **and** an etcd member simultaneously | Loses one of the two, independently |
| Losing 1 of 3 hosts | Quorum 2/3 → survives; **a second loss kills the cluster** | Control plane 2/3 *and* etcd 3/3 → far more margin |
| Setup effort with `kubeadm` | One command (`--upload-certs`) | Manual etcd bootstrap, separate PKI distribution |
| etcd version lifecycle | Coupled to Kubernetes upgrades (kubeadm upgrades etcd for you) | Decoupled — you own the etcd upgrade path |
| Disk contention | apiserver + etcd + container runtime share IOPS on the same volume | etcd gets dedicated disks |
| Sharing etcd across clusters | Not possible | Possible (separate `--etcd-prefix`), though rarely wise |
| Security surface | etcd peer/client certs on nodes that also run workloads-adjacent components | etcd hosts can be locked down to ports 2379/2380 only |
| Recommended for | Most clusters; anything under ~500 nodes | Large clusters, regulated environments, existing etcd operations team |

**Decision heuristic:** start stacked. Move to external when *any* of these becomes true: etcd disk latency competes with apiserver/runtime I/O; you need to upgrade etcd out-of-band; compliance requires the datastore on isolated hosts; or the cluster exceeds ~5 000 Pods and etcd needs dedicated tuning.

### 3.1 A third option worth naming

| Model | Who owns the control plane | HA responsibility |
|---|---|---|
| Self-managed `kubeadm` HA | You | Yours entirely — this topic |
| Managed (EKS/GKE/AKS) | Provider | Theirs; you own worker HA and PDBs |
| Hosted control planes (Cluster API, Kamaji, HyperShift) | Control planes run as Pods **inside** a management cluster | Recursive: the management cluster must itself be HA |

The exam and this material cover the first. But state the trade-off honestly in a design review: a self-managed HA control plane is a permanent operational commitment — snapshots, cert rotation, quorum drills, upgrade rehearsals — measured in engineer-hours per month.

---

## 4. Reaching a live apiserver: load balancer options

`controlPlaneEndpoint` is a **single stable address** — `host:port` — that must resolve to a healthy `kube-apiserver`. Every kubelet, every `kubectl`, every in-cluster component using the `kubernetes` Service ultimately depends on this being correct at `kubeadm init` time.

> **Critical, non-recoverable-by-accident:** if you run `kubeadm init` **without** `--control-plane-endpoint` (or `controlPlaneEndpoint` in the config), the cluster is pinned to that single node's IP in the apiserver certificate, in `admin.conf`, in every kubelet kubeconfig and in the `kubeadm-config` ConfigMap. Converting it to HA afterwards requires regenerating the apiserver certificate with new SANs and rewriting every kubeconfig on every node. Always set it, even for a cluster you *think* will stay single-node.

| Option | How it works | Failover time | Works in public cloud? | Extra hosts | Failure modes to watch |
|---|---|---|---|---|---|
| **keepalived + HAProxy** (static Pods on CP nodes) | VRRP moves a VIP; HAProxy L4-balances to all apiservers | ~6–10 s (`fall`×`inter` + VRRP) | ❌ VRRP/gratuitous ARP is usually blocked | 0 | Split brain if VRRP multicast is filtered; `virtual_router_id` collision with another cluster on the same L2 |
| **keepalived + HAProxy** (2 dedicated LB hosts) | Same, off the control plane | ~6–10 s | ❌ | 2 | Same, plus 2 more hosts to patch |
| **kube-vip (ARP/L2 mode)** | Leader-elected VIP via Kubernetes `Lease`, gratuitous ARP | ~5–10 s (lease duration) | ❌ (L2) | 0 | Chicken-and-egg at bootstrap (see §5.3) |
| **kube-vip (BGP mode)** | Announces the VIP to ToR routers via BGP | Sub-second to seconds (BFD-dependent) | ⚠️ Only where you peer BGP | 0 | Requires network team cooperation, ASN/peer config |
| **Cloud L4 LB** (NLB / GCP TCP LB / Azure LB) | Managed, health-checked | 10–30 s (health-check interval) | ✅ **Preferred in cloud** | 0 | Idle-timeout kills watches (see below); hairpin/loopback restrictions |
| **DNS round-robin** | Multiple A records | **Minutes** (client caching) | ✅ | 0 | No health checking. Clients cache dead IPs. Unacceptable alone. |
| **Hardware LB (F5, etc.)** | Enterprise appliance | Depends | N/A | 0 | Change control latency; often the slowest thing in an incident |

### 4.1 Two load-balancer settings that break clusters silently

**(a) Health check endpoint.** Use **`/readyz`**, not `/healthz`.

- `/livez` — is the process alive? Restart if failing.
- `/readyz` — should it receive traffic? Accounts for `--shutdown-delay-duration`, so a gracefully terminating apiserver reports **not ready while still serving**, letting the LB drain it before connections are cut.
- `/healthz` — legacy composite; deprecated for this purpose.

All three are readable **unauthenticated** because the `system:public-info-viewer` ClusterRole grants them to `system:unauthenticated`. If you harden the apiserver with `--anonymous-auth=false`, every health check starts returning `401` and the LB marks all backends down — a self-inflicted total outage. Keep anonymous auth on (it is limited to those paths) or configure the LB with a client certificate.

**(b) Idle timeout.** Kubernetes clients hold **long-lived watch connections**. An LB with a 60 s idle timeout silently severs every watch each minute; controllers resync, the apiserver's watch cache thrashes, and you see mysterious `Unexpected watch close` storms. Set the LB's client/server timeout to **≥ 1 hour** (4 h is common), or below the apiserver's `--min-request-timeout` behaviour, and never lower.

---

## 5. Full build: stacked etcd, 3 control-plane nodes, keepalived + HAProxy

Reference topology used throughout:

| Host | IP | Role |
|---|---|---|
| `cp1` | 10.0.1.11 | control plane + etcd, keepalived MASTER |
| `cp2` | 10.0.1.12 | control plane + etcd, keepalived BACKUP |
| `cp3` | 10.0.1.13 | control plane + etcd, keepalived BACKUP |
| VIP | **10.0.1.10** | `k8s-api.prod.example.com`, HAProxy frontend on **8443** |
| `w1..wN` | 10.0.2.0/24 | workers |

> HAProxy runs **on the control-plane nodes**, so its frontend cannot bind 6443 — the apiserver already owns it. Frontend `8443` → backends `*:6443`. `controlPlaneEndpoint` is therefore `k8s-api.prod.example.com:8443`.

### 5.1 Host preparation (identical on all control-plane nodes)

```bash
# --- kernel modules and sysctl required by the CNI and kube-proxy ---
$ cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
$ sudo modprobe overlay && sudo modprobe br_netfilter

$ cat <<'EOF' | sudo tee /etc/sysctl.d/99-kubernetes.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.ip_nonlocal_bind           = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
$ sudo sysctl --system

# ip_nonlocal_bind=1 lets HAProxy bind the VIP before keepalived assigns it.

# --- swap off: the kubelet refuses to start otherwise (unless NodeSwap is configured) ---
$ sudo swapoff -a
$ sudo sed -i '/ swap / s/^/#/' /etc/fstab

# --- time sync: Raft and TLS both depend on it ---
$ sudo systemctl enable --now chronyd
$ chronyc tracking | head -3
Reference ID    : 0A000101 (ntp.internal.example.com)
Stratum         : 3
Ref time (UTC)  : Thu Aug 13 09:14:22 2026

# --- container runtime ---
$ containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
$ sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
$ sudo systemctl restart containerd
```

Verify the ports are free and reachable between nodes before going further:

| Port | Direction | Purpose |
|---|---|---|
| 6443/tcp | all → CP | kube-apiserver |
| 8443/tcp | all → VIP | HAProxy frontend |
| 2379/tcp | CP ↔ CP | etcd client |
| 2380/tcp | CP ↔ CP | etcd peer (Raft) |
| 2381/tcp | monitoring → CP | etcd metrics (if enabled) |
| 10250/tcp | CP → all | kubelet API |
| 10257,10259/tcp | localhost | controller-manager, scheduler |
| VRRP (proto 112) | CP ↔ CP | keepalived |

```bash
$ sudo ss -lntp | grep -E ':(6443|8443|2379|2380|10250)'   # must be empty pre-install
$ nc -zv 10.0.1.12 2380
Connection to 10.0.1.12 2380 port [tcp/*] succeeded!
```

### 5.2 HAProxy + keepalived as static Pods

`/etc/haproxy/haproxy.cfg` — identical on all three nodes:

```
global
    log         /dev/log local0
    log         /dev/log local1 notice
    maxconn     20000
    daemon
    stats socket /var/lib/haproxy/stats mode 660 level admin expose-fd listeners

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout connect         5s
    timeout client          4h          # long enough for watch streams
    timeout server          4h          # ditto — NEVER lower this
    timeout check           3s
    maxconn                 18000

#---------------------------------------------------------------------
# Control-plane frontend on the VIP. 8443 because 6443 is taken locally
# by the kube-apiserver running on this same host.
#---------------------------------------------------------------------
frontend kube-apiserver
    bind                *:8443
    mode                tcp
    option              tcplog
    default_backend     kube-apiserver

backend kube-apiserver
    mode                tcp
    balance             roundrobin
    option              httpchk GET /readyz
    http-check          expect status 200
    # inter 2s / fall 3  => a dead apiserver leaves rotation in ~6s
    default-server      inter 2s fall 3 rise 2 check check-ssl verify none
    server  cp1  10.0.1.11:6443
    server  cp2  10.0.1.12:6443
    server  cp3  10.0.1.13:6443

#---------------------------------------------------------------------
# Local-only stats: the fastest way to prove which backends are UP
#---------------------------------------------------------------------
listen stats
    bind                127.0.0.1:9000
    mode                http
    stats enable
    stats uri           /stats
    stats refresh       5s
```

`/etc/keepalived/keepalived.conf` — `state`/`priority` differ per node:

```
! cp1: state MASTER, priority 101
! cp2: state BACKUP, priority 100
! cp3: state BACKUP, priority  99
global_defs {
    router_id            LVS_K8S_PROD
    script_user          root
    enable_script_security
    vrrp_skip_check_adv_addr
    vrrp_garp_interval   0
    vrrp_gna_interval    0
}

vrrp_script check_apiserver {
    script   "/etc/keepalived/check_apiserver.sh"
    interval 3
    weight  -2
    fall     10
    rise     2
    timeout  5
}

vrrp_instance VI_K8S {
    state             MASTER
    interface         ens192
    virtual_router_id 51          # must be UNIQUE per L2 segment
    priority          101
    advert_int        1
    authentication {
        auth_type PASS
        auth_pass 8f3Qm2Zx        # 8 chars max is significant to VRRPv2
    }
    virtual_ipaddress {
        10.0.1.10/24 dev ens192
    }
    track_script {
        check_apiserver
    }
}
```

`/etc/keepalived/check_apiserver.sh` (mode `0755`, owned by root — `enable_script_security` refuses otherwise):

```bash
#!/bin/sh
# Demote this node if the local HAProxy frontend cannot serve /readyz,
# and — when we currently hold the VIP — if the VIP itself is not serving.
set -e

APISERVER_VIP=10.0.1.10
APISERVER_DEST_PORT=8443

errorExit() {
    echo "*** $*" 1>&2
    exit 1
}

curl --silent --fail --insecure --max-time 2 \
     "https://localhost:${APISERVER_DEST_PORT}/readyz" -o /dev/null \
  || errorExit "GET https://localhost:${APISERVER_DEST_PORT}/readyz failed"

if ip addr | grep -q "${APISERVER_VIP}"; then
    curl --silent --fail --insecure --max-time 2 \
         "https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/readyz" -o /dev/null \
      || errorExit "GET https://${APISERVER_VIP}:${APISERVER_DEST_PORT}/readyz failed"
fi
```

Static Pod manifests. Drop these in `/etc/kubernetes/manifests/` **before** `kubeadm init` — the kubelet starts static Pods without an apiserver, which is exactly why this bootstraps:

```yaml
# /etc/kubernetes/manifests/haproxy.yaml
apiVersion: v1
kind: Pod
metadata:
  name: haproxy
  namespace: kube-system
  labels:
    component: haproxy
    tier: control-plane
spec:
  priorityClassName: system-node-critical
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
  - name: haproxy
    image: haproxy:2.8-alpine
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
      limits:
        memory: 256Mi
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: localhost
        path: /readyz
        port: 8443
        scheme: HTTPS
      initialDelaySeconds: 15
      timeoutSeconds: 15
    volumeMounts:
    - name: haproxyconf
      mountPath: /usr/local/etc/haproxy/haproxy.cfg
      readOnly: true
  volumes:
  - name: haproxyconf
    hostPath:
      path: /etc/haproxy/haproxy.cfg
      type: FileOrCreate
```

```yaml
# /etc/kubernetes/manifests/keepalived.yaml
apiVersion: v1
kind: Pod
metadata:
  name: keepalived
  namespace: kube-system
  labels:
    component: keepalived
    tier: control-plane
spec:
  priorityClassName: system-node-critical
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
  - name: keepalived
    image: osixia/keepalived:2.0.20
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_BROADCAST", "NET_RAW"]
    volumeMounts:
    - name: config
      mountPath: /usr/local/etc/keepalived/keepalived.conf
      readOnly: true
    - name: check
      mountPath: /etc/keepalived/check_apiserver.sh
      readOnly: true
  volumes:
  - name: config
    hostPath:
      path: /etc/keepalived/keepalived.conf
      type: File
  - name: check
    hostPath:
      path: /etc/keepalived/check_apiserver.sh
      type: File
```

Confirm the VIP is live and HAProxy answers **before** initialising anything:

```bash
$ ip -4 addr show dev ens192 | grep inet
    inet 10.0.1.11/24 brd 10.0.1.255 scope global ens192
    inet 10.0.1.10/24 scope global secondary ens192     # VIP acquired by cp1

$ nc -zv 10.0.1.10 8443
Connection to 10.0.1.10 8443 port [tcp/*] succeeded!
```

(HAProxy will report all backends `DOWN` at this stage — no apiserver exists yet. That is correct.)

### 5.3 Alternative: kube-vip instead of keepalived + HAProxy

kube-vip collapses VIP and load balancing into one static Pod that uses the Kubernetes API's own leader election.

```bash
$ export VIP=10.0.1.10 INTERFACE=ens192 KVVERSION=v0.8.9
$ sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
$ sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip \
    /kube-vip manifest pod \
      --interface $INTERFACE \
      --address   $VIP \
      --controlplane \
      --arp \
      --leaderElection \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
```

**The bootstrap trap (Kubernetes ≥ 1.29).** kubeadm now issues `admin.conf` bound to the `kubeadm:cluster-admins` Group and creates a separate `super-admin.conf` with the real `cluster-admin` binding. The generated kube-vip manifest mounts `admin.conf`, which during `kubeadm init` does not yet have RBAC — kube-vip crash-loops, the VIP never appears, and `kubeadm init` times out waiting for the control plane. Work around it for the bootstrap only:

```bash
# before kubeadm init on cp1
$ sudo sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' \
    /etc/kubernetes/manifests/kube-vip.yaml

# after init succeeds, revert so joined nodes (which never get super-admin.conf) work
$ sudo sed -i 's#path: /etc/kubernetes/super-admin.conf#path: /etc/kubernetes/admin.conf#' \
    /etc/kubernetes/manifests/kube-vip.yaml
```

| | keepalived + HAProxy | kube-vip |
|---|---|---|
| VIP ownership decided by | VRRP (network protocol) | Kubernetes `Lease` (needs a working API) |
| Behaviour when the API is fully down | Independent — keeps failing over | Leader election stalls; VIP stays where it is |
| Load balancing across apiservers | Yes, real L4 balancing | Yes (`--enableLoadBalancer`), or VIP-pins to the leader node |
| Moving parts | 2 daemons, 3 config files | 1 static Pod |
| Bootstrap complexity | Works before the cluster exists | Chicken-and-egg, needs the workaround above |
| Also does Service `type=LoadBalancer` | No | Yes |

For bare metal with a competent network team, keepalived + HAProxy remains the most debuggable choice: it fails independently of Kubernetes.

### 5.4 Full `kubeadm` configuration (`v1beta4`)

`kubeadm-cp1.yaml`. Note that in **`v1beta4` (kubeadm v1.31+)** `extraArgs` is a **list of `{name, value}`**, not a map — porting a `v1beta3` file verbatim fails validation.

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.0.1.11
  bindPort: 6443
nodeRegistration:
  name: cp1
  criSocket: unix:///run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  taints:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule
  kubeletExtraArgs:
  - name: node-ip
    value: "10.0.1.11"
bootstrapTokens:
- token: "abcdef.0123456789abcdef"
  description: "bootstrap token for the initial HA join window"
  ttl: "2h"
  usages: ["signing", "authentication"]
  groups: ["system:bootstrappers:kubeadm:default-node-token"]
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.1
clusterName: prod-eu-1
# THE line that makes this cluster highly available. Host:port of the VIP.
controlPlaneEndpoint: "k8s-api.prod.example.com:8443"
certificatesDir: /etc/kubernetes/pki
imageRepository: registry.k8s.io
# v1.31+: control the leaf/CA lifetimes instead of accepting 1 y / 10 y
certificateValidityPeriod: 8760h0m0s      # 1 year, leaf certs
caCertificateValidityPeriod: 87600h0m0s   # 10 years, CAs
networking:
  serviceSubnet: 10.96.0.0/16
  podSubnet: 10.244.0.0/16
  dnsDomain: cluster.local
etcd:
  local:
    dataDir: /var/lib/etcd
    # SANs must cover every address a peer or the apiserver may dial
    serverCertSANs:
    - "10.0.1.11"
    - "cp1.prod.example.com"
    peerCertSANs:
    - "10.0.1.11"
    - "cp1.prod.example.com"
    extraArgs:
    # Timing tuned for cross-AZ RTT; MUST be identical on every member
    - name: heartbeat-interval
      value: "250"
    - name: election-timeout
      value: "2500"
    # Raise the 2 GiB default ceiling; 8 GiB is the supported maximum
    - name: quota-backend-bytes
      value: "8589934592"
    # Unauthenticated metrics + /health on a management interface only
    - name: listen-metrics-urls
      value: "http://10.0.1.11:2381"
    - name: snapshot-count
      value: "10000"
apiServer:
  # Every name/IP a client may present in TLS SNI must be here, and it
  # CANNOT be extended later without regenerating the certificate.
  certSANs:
  - "k8s-api.prod.example.com"
  - "k8s-api.internal"
  - "10.0.1.10"          # VIP
  - "10.0.1.11"
  - "10.0.1.12"
  - "10.0.1.13"
  - "127.0.0.1"
  - "localhost"
  extraArgs:
  # Graceful shutdown: fail /readyz for 30 s while still serving, so the
  # LB drains this backend before connections are cut.
  - name: shutdown-delay-duration
    value: "30s"
  - name: shutdown-send-retry-after
    value: "true"
  - name: audit-log-path
    value: "/var/log/kubernetes/audit/audit.log"
  - name: audit-log-maxage
    value: "30"
  - name: audit-log-maxbackup
    value: "10"
  - name: audit-log-maxsize
    value: "100"
  - name: audit-policy-file
    value: "/etc/kubernetes/audit/policy.yaml"
  # Lease-based reconciler keeps the `kubernetes` Service endpoints
  # accurate as apiservers come and go. This is the default; pinned here
  # because a wrong value here breaks in-cluster API access during failover.
  - name: endpoint-reconciler-type
    value: "lease"
  - name: request-timeout
    value: "1m0s"
  extraVolumes:
  - name: audit-policy
    hostPath: /etc/kubernetes/audit
    mountPath: /etc/kubernetes/audit
    readOnly: true
    pathType: DirectoryOrCreate
  - name: audit-log
    hostPath: /var/log/kubernetes/audit
    mountPath: /var/log/kubernetes/audit
    pathType: DirectoryOrCreate
  timeoutForControlPlane: 4m0s
controllerManager:
  extraArgs:
  - name: bind-address
    value: "0.0.0.0"           # so Prometheus can scrape :10257
  - name: node-monitor-period
    value: "5s"
  - name: terminated-pod-gc-threshold
    value: "1000"
  # Leader election defaults are lease 15s / renew 10s / retry 2s.
  # Raise them only if the API is latency-prone; every increase adds
  # directly to controller failover time.
  - name: leader-elect-lease-duration
    value: "15s"
  - name: leader-elect-renew-deadline
    value: "10s"
  - name: leader-elect-retry-period
    value: "2s"
scheduler:
  extraArgs:
  - name: bind-address
    value: "0.0.0.0"           # :10259
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
rotateCertificates: true
serverTLSBootstrap: true       # requires a CSR approver (e.g. kubelet-csr-approver)
nodeStatusUpdateFrequency: 10s
nodeStatusReportFrequency: 5m
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "2Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  scheduler: rr
  strictARP: true              # required if you also run kube-vip or MetalLB
```

### 5.5 Initialise the first control-plane node

```bash
$ sudo kubeadm init --config kubeadm-cp1.yaml --upload-certs --v=5
[init] Using Kubernetes version: v1.33.1
[preflight] Running pre-flight checks
[preflight] Pulling images required for setting up a Kubernetes cluster
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [cp1 k8s-api.internal k8s-api.prod.example.com kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local localhost] and IPs [10.96.0.1 10.0.1.11 10.0.1.10 10.0.1.12 10.0.1.13 127.0.0.1]
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [cp1 cp1.prod.example.com localhost] and IPs [10.0.1.11 127.0.0.1 ::1]
[certs] Generating "etcd/peer" certificate and key
[certs] Generating "sa" key and public key
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "super-admin.conf" kubeconfig file
[kubeconfig] Writing "kubelet.conf" kubeconfig file
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[kubelet-start] Starting the kubelet
[apiclient] All control plane components are healthy after 12.503561 seconds
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[upload-certs] Storing the certificates in Secret "kubeadm-certs" in the "kube-system" Namespace
[upload-certs] Using certificate key:
4b1f0c9a7d2e6318bf05a4c7de91302b8ac6f47159de2f0b8e3d1a67c9048fbb
[mark-control-plane] Marking the node cp1 as control-plane
[bootstrap-token] Using token: abcdef.0123456789abcdef
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

You can now join any number of control-plane nodes running the following
command on each as root:

  kubeadm join k8s-api.prod.example.com:8443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:6f3b0a1c9e77d2f4a58b31c0de6942f7a1b8c5d093e2f61a7c48b90d1e2f3a4b \
    --control-plane --certificate-key 4b1f0c9a7d2e6318bf05a4c7de91302b8ac6f47159de2f0b8e3d1a67c9048fbb

Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
As a safeguard, uploaded-certs will be deleted in two hours...
```

**Two expiry clocks start here:**

| Artefact | TTL | Regenerate with |
|---|---|---|
| `kubeadm-certs` Secret (the `--certificate-key` payload) | **2 hours** | `sudo kubeadm init phase upload-certs --upload-certs` |
| Bootstrap token | 24 h default (2 h in the config above) | `sudo kubeadm token create --print-join-command` |

Install the CNI now — until then every node is `NotReady` and CoreDNS is `Pending`:

```bash
$ mkdir -p $HOME/.kube && sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
$ kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

### 5.6 Join `cp2` and `cp3`

Join **sequentially**, never in parallel — two simultaneous `member add` operations against a 1-member cluster can transiently break quorum.

```bash
# on cp2 (its own haproxy.yaml/keepalived.yaml are already in /etc/kubernetes/manifests)
$ sudo kubeadm join k8s-api.prod.example.com:8443 \
    --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:6f3b0a1c9e77d2f4a58b31c0de6942f7a1b8c5d093e2f61a7c48b90d1e2f3a4b \
    --control-plane \
    --certificate-key 4b1f0c9a7d2e6318bf05a4c7de91302b8ac6f47159de2f0b8e3d1a67c9048fbb \
    --apiserver-advertise-address 10.0.1.12
[preflight] Running pre-flight checks
[preflight] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[download-certs] Downloading the certificates in Secret "kubeadm-certs" in the "kube-system" Namespace
[certs] Using the existing "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[check-etcd] Checking that the etcd cluster is healthy
[etcd] Announced new etcd member joining to the existing etcd cluster
[etcd] Creating static Pod manifest for "etcd"
[etcd] Waiting for the new etcd member to join the cluster. This can take up to 40s
[mark-control-plane] Marking the node cp2 as control-plane

This node has joined the cluster and a new control plane instance was created.
```

Repeat on `cp3` with `--apiserver-advertise-address 10.0.1.13`. Workers join without `--control-plane`:

```bash
$ sudo kubeadm join k8s-api.prod.example.com:8443 \
    --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:6f3b0a1c9e77d2f4a58b31c0de6942f7a1b8c5d093e2f61a7c48b90d1e2f3a4b
```

### 5.7 The external-etcd variant

Only the deltas matter. Build the etcd cluster first on `etcd1..3` (10.0.3.11–13), generate the PKI with `kubeadm` phases on one host, then distribute:

```bash
# On etcd1, generate certs for ALL members using per-host kubeadm configs
$ for h in etcd1:10.0.3.11 etcd2:10.0.3.12 etcd3:10.0.3.13; do
    NAME=${h%%:*}; IP=${h##*:}
    cat > /tmp/${NAME}.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  name: ${NAME}
localAPIEndpoint:
  advertiseAddress: ${IP}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
etcd:
  local:
    serverCertSANs: ["${IP}", "${NAME}.prod.example.com"]
    peerCertSANs:   ["${IP}", "${NAME}.prod.example.com"]
EOF
    sudo kubeadm init phase certs etcd-server --config=/tmp/${NAME}.yaml
    sudo kubeadm init phase certs etcd-peer   --config=/tmp/${NAME}.yaml
    sudo kubeadm init phase certs etcd-healthcheck-client --config=/tmp/${NAME}.yaml
    sudo kubeadm init phase certs apiserver-etcd-client   --config=/tmp/${NAME}.yaml
    sudo mkdir -p /tmp/pki-${NAME}/etcd
    sudo cp -r /etc/kubernetes/pki/etcd/{ca.crt,server.crt,server.key,peer.crt,peer.key,healthcheck-client.crt,healthcheck-client.key} /tmp/pki-${NAME}/etcd/
    sudo cp /etc/kubernetes/pki/apiserver-etcd-client.{crt,key} /tmp/pki-${NAME}/
    # remove the non-CA leaf certs so the next iteration regenerates them
    sudo find /etc/kubernetes/pki -name '*peer*' -o -name '*server*' -o -name '*healthcheck*' | sudo xargs rm -f
  done
```

Then the control plane points at them instead of running local etcd:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.33.1
controlPlaneEndpoint: "k8s-api.prod.example.com:8443"
etcd:
  external:
    endpoints:
    - https://10.0.3.11:2379
    - https://10.0.3.12:2379
    - https://10.0.3.13:2379
    caFile:   /etc/kubernetes/pki/etcd/ca.crt
    certFile: /etc/kubernetes/pki/apiserver-etcd-client.crt
    keyFile:  /etc/kubernetes/pki/apiserver-etcd-client.key
```

Copy `etcd/ca.crt`, `apiserver-etcd-client.crt` and `apiserver-etcd-client.key` to every control-plane node before `kubeadm init`. With external etcd, **kubeadm will not upgrade etcd for you** — that becomes your responsibility, one minor version at a time (3.4 → 3.5 → 3.6; never skip).

---

## 6. Verification: a ladder from cheap to conclusive

### Rung 1 — the control plane exists and is distributed

```bash
$ kubectl get nodes -o wide
NAME   STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
cp1    Ready    control-plane   34m   v1.33.1   10.0.1.11     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://1.7.24
cp2    Ready    control-plane   21m   v1.33.1   10.0.1.12     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://1.7.24
cp3    Ready    control-plane   18m   v1.33.1   10.0.1.13     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://1.7.24
w1     Ready    <none>          12m   v1.33.1   10.0.2.21     Ubuntu 24.04.2 LTS   6.8.0-51-generic    containerd://1.7.24

$ kubectl -n kube-system get pods -o wide --field-selector spec.nodeName!=w1 \
    | grep -E 'etcd|apiserver|controller-manager|scheduler'
etcd-cp1                           1/1   Running   0   34m   10.0.1.11   cp1
etcd-cp2                           1/1   Running   0   21m   10.0.1.12   cp2
etcd-cp3                           1/1   Running   0   18m   10.0.1.13   cp3
kube-apiserver-cp1                 1/1   Running   0   34m   10.0.1.11   cp1
kube-apiserver-cp2                 1/1   Running   0   21m   10.0.1.12   cp2
kube-apiserver-cp3                 1/1   Running   0   18m   10.0.1.13   cp3
kube-controller-manager-cp1        1/1   Running   0   34m   10.0.1.11   cp1
kube-controller-manager-cp2        1/1   Running   0   21m   10.0.1.12   cp2
kube-controller-manager-cp3        1/1   Running   0   18m   10.0.1.13   cp3
kube-scheduler-cp1                 1/1   Running   0   34m   10.0.1.11   cp1
kube-scheduler-cp2                 1/1   Running   0   21m   10.0.1.12   cp2
kube-scheduler-cp3                 1/1   Running   0   18m   10.0.1.13   cp3
```

### Rung 2 — all three apiservers registered themselves

This is the check people skip. The `kubernetes` Service's EndpointSlice is populated by each apiserver's own lease reconciler; if only one IP appears, the others are not really participating and in-cluster clients will never reach them.

```bash
$ kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
    -o jsonpath='{.items[*].endpoints[*].addresses[*]}{"\n"}'
10.0.1.11 10.0.1.12 10.0.1.13

$ kubectl -n kube-system get leases | grep apiserver | head -3
apiserver-4d3xk7p2q...   9s
apiserver-9b1zc6m4t...   6s
apiserver-f7h2n8v5w...   3s
```

### Rung 3 — leader election is real

```bash
$ kubectl -n kube-system get lease kube-scheduler kube-controller-manager \
    -o custom-columns='LEASE:.metadata.name,HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime'
LEASE                     HOLDER                  RENEWED
kube-scheduler            cp1_3f2b18ac-...        2026-08-13T09:47:12.000000Z
kube-controller-manager   cp2_a91c07de-...        2026-08-13T09:47:11.000000Z
```

Different holders on different nodes is normal and healthy — the two components elect independently.

### Rung 4 — etcd quorum and per-member health

```bash
$ export ETCDCTL_API=3
$ sudo etcdctl \
    --endpoints=https://10.0.1.11:2379,https://10.0.1.12:2379,https://10.0.1.13:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status -w table
+-------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|        ENDPOINT         |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+-------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| https://10.0.1.11:2379  | 3a57933972cb5131 | 3.5.21  |  4.2 MB |     false |      false |         4 |      28471 |              28471 |        |
| https://10.0.1.12:2379  | 8e9e05c52164694d | 3.5.21  |  4.2 MB |      true |      false |         4 |      28471 |              28471 |        |
| https://10.0.1.13:2379  | c1f5d9e04a3b7268 | 3.5.21  |  4.2 MB |     false |      false |         4 |      28471 |              28471 |        |
+-------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+

$ sudo etcdctl --endpoints=... --cacert=... --cert=... --key=... endpoint health --cluster -w table
+-------------------------+--------+-------------+-------+
|        ENDPOINT         | HEALTH |    TOOK     | ERROR |
+-------------------------+--------+-------------+-------+
| https://10.0.1.12:2379  |   true |  8.410261ms |       |
| https://10.0.1.11:2379  |   true |  9.117402ms |       |
| https://10.0.1.13:2379  |   true | 11.203915ms |       |
+-------------------------+--------+-------------+-------+

$ sudo etcdctl --endpoints=... --cacert=... --cert=... --key=... alarm list
# (empty output = no NOSPACE / CORRUPT alarms — this is the good case)
```

Read the `RAFT INDEX` column: three identical values means all members are caught up. A member lagging by thousands of entries is being fed by the leader's snapshot and is not yet contributing to quorum reliably.

Without `etcdctl` on the host, run it inside the container:

```bash
$ kubectl -n kube-system exec -it etcd-cp1 -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    member list -w table
```

### Rung 5 — the VIP and load balancer actually distribute

```bash
$ curl -sk https://10.0.1.10:8443/readyz
ok

$ kubectl get --raw='/readyz?verbose' | tail -20
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/start-kube-apiserver-admission-initializer ok
[+]poststarthook/rbac/bootstrap-roles ok
[+]poststarthook/scheduling/bootstrap-system-priority-classes ok
[+]shutdown ok
readyz check passed

$ echo "show stat" | sudo socat /var/lib/haproxy/stats stdio \
    | awk -F, 'NR==1 || $1=="kube-apiserver" {print $1","$2","$18","$8}'
# pxname,svname,status,stot
kube-apiserver,cp1,UP,412
kube-apiserver,cp2,UP,398
kube-apiserver,cp3,UP,405
```

Roughly equal session counts across all three is the proof that traffic is balanced, not merely that the VIP answers.

### Rung 6 — the drill that proves it

Availability claims are worthless until failed over on purpose. Do this in a maintenance window, once, before production traffic:

```bash
# Terminal 1 — continuous probe from a worker
$ while true; do
    printf '%s ' "$(date +%T)"
    kubectl get --raw='/readyz' 2>&1 | head -c 40
    echo
    sleep 1
  done

# Terminal 2 — hard-fail cp1 (the current VIP holder)
$ sudo systemctl stop kubelet && sudo crictl stop \
    $(sudo crictl ps -q --name kube-apiserver)
```

Expected trace:

```
09:52:01 ok
09:52:02 ok
09:52:03 Get "https://k8s-api.prod.example.com:8443/readyz": EOF
09:52:04 Get "https://k8s-api.prod.example.com:8443/readyz": EOF
09:52:09 ok
09:52:10 ok
```

A ~6 s gap matches `inter 2s × fall 3`. If the outage lasts minutes, your health check or timeouts are wrong. Then verify the state converged:

```bash
$ kubectl get nodes
NAME   STATUS     ROLES           AGE   VERSION
cp1    NotReady   control-plane   58m   v1.33.1
cp2    Ready      control-plane   45m   v1.33.1
cp3    Ready      control-plane   42m   v1.33.1

$ sudo etcdctl ... endpoint health --cluster -w table
| https://10.0.1.11:2379 |  false | ... | context deadline exceeded |
| https://10.0.1.12:2379 |   true | 8.9ms |  |
| https://10.0.1.13:2379 |   true | 9.4ms |  |
# 2 of 3 healthy => quorum holds => writes still succeed:
$ kubectl create deployment probe --image=nginx --replicas=2
deployment.apps/probe created
```

Restore with `sudo systemctl start kubelet` on cp1 and confirm `Ready` returns.

---

## 7. Failure diagnosis

### 7.1 Symptom → cause table

| Symptom | Most likely cause | First command |
|---|---|---|
| `kubectl` hangs, then `Unable to connect to the server: EOF` | VIP not assigned (keepalived down on all nodes) or HAProxy backends all DOWN | `ip -4 addr show` on each CP; `echo "show stat" \| socat …` |
| `x509: certificate is valid for A, not B` | The address you dialled is missing from `apiServer.certSANs` | `openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \| grep -A1 'Alternative'` |
| `etcdserver: request timed out` on every write | Quorum lost, or leader disk fsync stalled | `etcdctl endpoint status -w table`; check `etcd_disk_wal_fsync_duration_seconds` |
| `etcdserver: mvcc: database space exceeded` | `NOSPACE` alarm, DB hit `quota-backend-bytes` | `etcdctl alarm list` → compact, defrag, `alarm disarm` |
| Pods stay `Pending`, no events | No scheduler leader (all replicas crash-looping or lease stale) | `kubectl -n kube-system get lease kube-scheduler -o yaml` |
| Deployments do not scale, deleted Pods not recreated | No controller-manager leader | `kubectl -n kube-system get lease kube-controller-manager -o yaml` |
| Two nodes both hold the VIP | keepalived split brain — VRRP blocked between nodes | `tcpdump -i ens192 -n proto 112` on both |
| Watches drop exactly every 60 s | LB idle timeout too low | Check `timeout client`/`timeout server` or the cloud LB idle timeout |
| Everything worked yesterday, total outage today, `Unauthorized` | Certificates expired | `sudo kubeadm certs check-expiration` |
| One CP node's apiserver never becomes ready after join | Clock skew or wrong `--apiserver-advertise-address` | `chronyc tracking`; `crictl logs $(crictl ps -a -q --name kube-apiserver)` |
| `kubeadm join --control-plane` fails with `error execution phase control-plane-prepare/download-certs` | The `kubeadm-certs` Secret expired (2 h) | `sudo kubeadm init phase upload-certs --upload-certs` on a live CP |

### 7.2 Where to look when the API is down

With no working `kubectl`, static Pods are still reachable through the runtime:

```bash
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT   POD ID
9f1a2b3c4d5e   6f3b0a1c9e77   2 minutes ago   Exited    kube-apiserver   7         a1b2c3d4e5f6

$ sudo crictl logs --tail 40 9f1a2b3c4d5e
W0813 10:02:11.442901  1 clientconn.go:1331] grpc: addrConn.createTransport failed to connect to
  {127.0.0.1:2379 <nil> 0 <nil>}. Err :connection error: desc = "transport: Error while dialing
  dial tcp 127.0.0.1:2379: connect: connection refused"
F0813 10:02:41.885017  1 instance.go:292] Error creating leases: error creating storage factory:
  context deadline exceeded

$ sudo journalctl -u kubelet -n 50 --no-pager
$ sudo crictl logs --tail 60 $(sudo crictl ps -a -q --name etcd | head -1)
```

### 7.3 Replacing a failed control-plane node

etcd does **not** forget a dead member. Leaving a phantom member in the list turns a 3-member cluster into "3 members, 1 permanently down" — you have silently lost your failure tolerance.

```bash
# 1. Identify and remove the etcd member
$ sudo etcdctl --endpoints=https://10.0.1.12:2379 --cacert=... --cert=... --key=... member list
3a57933972cb5131, started, cp1, https://10.0.1.11:2380, https://10.0.1.11:2379, false
8e9e05c52164694d, started, cp2, https://10.0.1.12:2380, https://10.0.1.12:2379, false
c1f5d9e04a3b7268, started, cp3, https://10.0.1.13:2380, https://10.0.1.13:2379, false

$ sudo etcdctl --endpoints=https://10.0.1.12:2379 --cacert=... --cert=... --key=... \
    member remove 3a57933972cb5131
Member 3a57933972cb5131 removed from cluster 8f2d1e6c9b4a7350

# 2. Remove the Node object
$ kubectl delete node cp1
node "cp1" deleted

# 3. On the (rebuilt) host, wipe any residue
$ sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
$ sudo rm -rf /etc/cni/net.d /var/lib/etcd
$ sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
$ sudo ipvsadm -C   # if using IPVS mode

# 4. Mint fresh credentials on a surviving CP node
$ sudo kubeadm init phase upload-certs --upload-certs
[upload-certs] Using certificate key:
e7c2a91b45d80f36cb1e5027a9f4d8630bc17e5942af0d3b6ec81729d40b5fa8

$ sudo kubeadm token create --print-join-command
kubeadm join k8s-api.prod.example.com:8443 --token 9x1kq2.p8m3v7t0slz6yc4a \
  --discovery-token-ca-cert-hash sha256:6f3b0a1c9e77d2f4a58b31c0de6942f7a1b8c5d093e2f61a7c48b90d1e2f3a4b

# 5. Re-join as a control-plane node
$ sudo kubeadm join k8s-api.prod.example.com:8443 \
    --token 9x1kq2.p8m3v7t0slz6yc4a \
    --discovery-token-ca-cert-hash sha256:6f3b0a1c9e77d2f4a58b31c0de6942f7a1b8c5d093e2f61a7c48b90d1e2f3a4b \
    --control-plane --certificate-key e7c2a91b45d80f36cb1e5027a9f4d8630bc17e5942af0d3b6ec81729d40b5fa8 \
    --apiserver-advertise-address 10.0.1.11
```

**Safer variant for a live cluster (etcd 3.4+):** add the replacement as a **learner** first. A learner replicates the log but does not count toward quorum, so a slow initial sync cannot destabilise the cluster:

```bash
$ sudo etcdctl ... member add cp1 --learner --peer-urls=https://10.0.1.11:2380
$ sudo etcdctl ... member promote 3a57933972cb5131   # once RAFT INDEX has caught up
```

### 7.4 Recovering from total quorum loss

When 2 of 3 (or 3 of 5) members are gone, Raft cannot elect a leader and **no amount of restarting helps**. You must rebuild from a snapshot.

```bash
# --- Prerequisite: you have been taking snapshots (see §8.3) ---
$ sudo etcdutl snapshot status /var/backups/etcd/etcd-2026-08-13-0300.db -w table
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 8f3d2a91 |   184203 |       1847 |     4.2 MB |
+----------+----------+------------+------------+

# --- On the ONE surviving node, stop the whole control plane ---
$ sudo mkdir -p /etc/kubernetes/manifests.bak
$ sudo mv /etc/kubernetes/manifests/*.yaml /etc/kubernetes/manifests.bak/
$ sudo crictl ps    # wait until etcd and apiserver are gone
$ sudo mv /var/lib/etcd /var/lib/etcd.corrupt-$(date +%s)

# --- Restore into a fresh data dir as a single-member cluster ---
$ sudo etcdutl snapshot restore /var/backups/etcd/etcd-2026-08-13-0300.db \
    --name cp1 \
    --initial-cluster cp1=https://10.0.1.11:2380 \
    --initial-cluster-token prod-eu-1-restore-20260813 \
    --initial-advertise-peer-urls https://10.0.1.11:2380 \
    --data-dir /var/lib/etcd
2026-08-13T10:31:02Z  info  snapshot/v3_snapshot.go:265  restoring snapshot
2026-08-13T10:31:02Z  info  membership/cluster.go:421    added member  {"cluster-id":"7d2f...","member-id":"3a57933972cb5131","added-peer-peer-urls":["https://10.0.1.11:2380"]}
2026-08-13T10:31:03Z  info  snapshot/v3_snapshot.go:293  restored snapshot

# --- Bring the control plane back on this node only ---
$ sudo mv /etc/kubernetes/manifests.bak/*.yaml /etc/kubernetes/manifests/
$ sudo systemctl restart kubelet
$ sleep 45 && kubectl get nodes
NAME   STATUS     ROLES           AGE   VERSION
cp1    Ready      control-plane   3h    v1.33.1
cp2    NotReady   control-plane   2h    v1.33.1
cp3    NotReady   control-plane   2h    v1.33.1

# --- Now rebuild cp2 and cp3 with the §7.3 procedure, one at a time ---
```

Key points: use `etcdutl` (not `etcdctl`) for restore in etcd 3.5+; change `--initial-cluster-token` so a stale member cannot rejoin the old cluster identity; and **everything written after the snapshot is lost** — that is your RPO, and it equals your snapshot interval.

### 7.5 `NOSPACE` alarm — compact, defragment, disarm

```bash
$ sudo etcdctl ... alarm list
memberID:8e9e05c52164694d alarm:NOSPACE

# 1. Compact away old revisions
$ REV=$(sudo etcdctl ... endpoint status --write-out=json \
        | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
$ sudo etcdctl ... compact $REV --physical
compacted revision 184203

# 2. Defragment ONE MEMBER AT A TIME — defrag blocks that member entirely
$ sudo etcdctl --endpoints=https://10.0.1.11:2379 ... defrag
Finished defragmenting etcd member[https://10.0.1.11:2379]
$ sudo etcdctl --endpoints=https://10.0.1.12:2379 ... defrag
$ sudo etcdctl --endpoints=https://10.0.1.13:2379 ... defrag

# Defragment the LEADER LAST, or move leadership away first:
$ sudo etcdctl ... move-leader c1f5d9e04a3b7268

# 3. Clear the alarm
$ sudo etcdctl ... alarm disarm
```

Never run `defrag --cluster` on a production cluster: it defragments every member concurrently and takes the whole datastore offline.

---

## 8. Day-2 operations specific to HA

### 8.1 Upgrades

The order is fixed and asymmetric — one node runs `upgrade apply`, the rest run `upgrade node`:

```bash
# --- cp1: the only node that runs `apply` ---
$ sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm=1.33.2-1.1 && sudo apt-mark hold kubeadm
$ sudo kubeadm upgrade plan
[upgrade/config] Reading configuration from the cluster...
Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE   CURRENT   TARGET
kubelet     cp1    v1.33.1   v1.33.2
kubelet     cp2    v1.33.1   v1.33.2
kubelet     cp3    v1.33.1   v1.33.2

Upgrade to the latest version in the v1.33 series:
COMPONENT                 CURRENT    TARGET
kube-apiserver            v1.33.1    v1.33.2
kube-controller-manager   v1.33.1    v1.33.2
kube-scheduler            v1.33.1    v1.33.2
etcd                      3.5.21-0   3.5.21-0

$ sudo kubeadm upgrade apply v1.33.2
[upgrade/successful] SUCCESS! Your cluster was upgraded to "v1.33.2". Enjoy!

# --- cp2 and cp3, one at a time ---
$ sudo kubeadm upgrade node
[upgrade] Upgrading your Static Pod-hosted control plane instance to version "v1.33.2"...
[upgrade] The control plane instance for this node was successfully upgraded!

# --- kubelet on every node, drain first ---
$ kubectl drain cp2 --ignore-daemonsets --delete-emptydir-data
$ sudo apt-get install -y kubelet=1.33.2-1.1 kubectl=1.33.2-1.1
$ sudo systemctl daemon-reload && sudo systemctl restart kubelet
$ kubectl uncordon cp2
```

During the whole procedure the API stays available because the LB removes each node as its apiserver restarts — provided your health check is `/readyz` and `shutdown-delay-duration` is set.

### 8.2 Certificate rotation

```bash
$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Aug 13, 2027 09:14 UTC   364d            no
apiserver                  Aug 13, 2027 09:14 UTC   364d            no
apiserver-etcd-client      Aug 13, 2027 09:14 UTC   364d            no
apiserver-kubelet-client   Aug 13, 2027 09:14 UTC   364d            no
controller-manager.conf    Aug 13, 2027 09:14 UTC   364d            no
etcd-healthcheck-client    Aug 13, 2027 09:14 UTC   364d            no
etcd-peer                  Aug 13, 2027 09:14 UTC   364d            no
etcd-server                Aug 13, 2027 09:14 UTC   364d            no
front-proxy-client         Aug 13, 2027 09:14 UTC   364d            no
scheduler.conf             Aug 13, 2027 09:14 UTC   364d            no
super-admin.conf           Aug 13, 2027 09:14 UTC   364d            no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME
ca                      Aug 11, 2036 09:14 UTC   9y
etcd-ca                 Aug 11, 2036 09:14 UTC   9y
front-proxy-ca          Aug 11, 2036 09:14 UTC   9y

# Renew on EACH control-plane node, one at a time, then restart the static Pods
$ sudo kubeadm certs renew all
$ sudo mv /etc/kubernetes/manifests/*.yaml /tmp/ && sleep 25 && sudo mv /tmp/*.yaml /etc/kubernetes/manifests/
$ sudo cp /etc/kubernetes/admin.conf ~/.kube/config   # admin.conf was regenerated
```

`kubeadm upgrade` renews leaf certificates automatically — a cluster upgraded at least annually never hits expiry. A cluster left untouched for a year does. This is the single most common self-inflicted total outage in self-managed Kubernetes, and **HA does not mitigate it**: all three nodes' certificates expire within minutes of each other.

### 8.3 Backups are not optional

Raft protects against member loss, not against `kubectl delete namespace prod`. Run a snapshot on **one** member (they are identical):

```yaml
# /etc/systemd/system/etcd-snapshot.service
[Unit]
Description=etcd snapshot to /var/backups/etcd

[Service]
Type=oneshot
Environment=ETCDCTL_API=3
ExecStart=/usr/local/bin/etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save /var/backups/etcd/etcd-%i.db
ExecStartPost=/usr/bin/find /var/backups/etcd -name 'etcd-*.db' -mtime +14 -delete
```

Back up **`/etc/kubernetes/pki`** alongside every snapshot. A snapshot restored against a different CA is useless — every kubelet, every ServiceAccount token signed by the old `sa.key`, and every client certificate stops validating.

| Backup component | Why |
|---|---|
| etcd snapshot | The cluster state |
| `/etc/kubernetes/pki/ca.{crt,key}` | Node and client certs chain to it |
| `/etc/kubernetes/pki/etcd/ca.{crt,key}` | etcd peer/server certs |
| `/etc/kubernetes/pki/sa.{key,pub}` | Existing ServiceAccount tokens stay valid |
| `/etc/kubernetes/pki/front-proxy-ca.*` | Aggregated API servers (metrics-server) |
| `kubeadm-config` ConfigMap | Reproduces the cluster configuration |

---

## 9. Above the control plane: making workloads survive too

An HA control plane on a cluster where every replica of your app landed on one node is theatre. The install is only half the story:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: prod
spec:
  replicas: 6
  selector:
    matchLabels: {app: payments-api}
  template:
    metadata:
      labels: {app: payments-api}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {app: payments-api}
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels: {app: payments-api}
      containers:
      - name: api
        image: registry.internal/payments-api:1.14.2
        readinessProbe:
          httpGet: {path: /readyz, port: 8080}
          periodSeconds: 5
        resources:
          requests: {cpu: 250m, memory: 512Mi}
          limits:   {memory: 1Gi}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-api
  namespace: prod
spec:
  minAvailable: 4          # survives a node drain without dipping below capacity
  selector:
    matchLabels: {app: payments-api}
```

And the addons that the cluster itself depends on — CoreDNS above all — need the same treatment:

```bash
$ kubectl -n kube-system patch deployment coredns --patch '
spec:
  replicas: 3
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels: {k8s-app: kube-dns}'
deployment.apps/coredns patched
```

Node-failure detection timing, for reference when tuning eviction behaviour:

| Knob | Component | Typical default | Effect |
|---|---|---|---|
| `nodeStatusUpdateFrequency` | kubelet | 10 s | How often the Node `Lease` is renewed |
| `--node-monitor-period` | controller-manager | 5 s | How often node health is evaluated |
| `--node-monitor-grace-period` | controller-manager | 40 s (verify per release) | Time before a Node is marked `NotReady` |
| `tolerationSeconds` for `node.kubernetes.io/unreachable` | Pod spec (defaulted) | 300 s | Delay before Pods are evicted from an unreachable node |

Total time from node death to Pod rescheduling ≈ grace period + toleration ≈ **~5.5 minutes** by default. Lower `tolerationSeconds` per workload if that is too slow; do not lower it globally, or a brief network blip evicts the whole cluster.

---

## 10. Production traps worth memorising

1. **Forgetting `--control-plane-endpoint` at init.** Non-recoverable without regenerating certificates and rewriting every kubeconfig.
2. **A 2-member etcd cluster.** Strictly worse than 1.
3. **`--certificate-key` expired.** The `kubeadm-certs` Secret lives 2 hours; regenerate with `kubeadm init phase upload-certs --upload-certs`.
4. **LB health check on a path that requires auth**, or `--anonymous-auth=false` breaking `/readyz`.
5. **LB idle timeout below the watch lifetime.** Silent, constant controller resyncs.
6. **HAProxy bound to 6443 on a control-plane node.** Port conflict with the apiserver; use 8443.
7. **`virtual_router_id` collision.** Two clusters on the same L2 with `51` fight over each other's VIPs.
8. **VRRP in a public cloud.** It does not work; use the cloud LB or kube-vip BGP.
9. **Removing a control-plane node without `etcdctl member remove`.** The phantom member consumes a quorum slot forever.
10. **`etcdctl defrag --cluster` in production.** Defragments all members at once — full datastore outage.
11. **Backing up etcd without `/etc/kubernetes/pki`.** The restore will not authenticate anything.
12. **Never testing a restore.** An untested backup is a hypothesis, not a recovery plan.
13. **Mismatched etcd timing flags across members.** Produces intermittent leader elections that look like network faults.
14. **etcd on network-attached storage.** `wal_fsync` p99 goes to hundreds of milliseconds and the cluster flaps under load.

---

## 11. Referencias

**Kubernetes — official documentation**
- Options for Highly Available topology: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/
- Creating Highly Available clusters with kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/
- Set up a High Availability etcd cluster with kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/setup-ha-etcd-with-kubeadm/
- Creating a cluster with kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm HA considerations (keepalived/HAProxy reference configs): https://github.com/kubernetes/kubeadm/blob/main/docs/ha-considerations.md
- `kubeadm init` reference: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/
- `kubeadm join` reference: https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
- kubeadm configuration API `v1beta4`: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Certificate management with kubeadm: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- Upgrading kubeadm clusters: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Operating etcd clusters for Kubernetes (backup and restore): https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- Kubernetes API health endpoints: https://kubernetes.io/docs/reference/using-api/health-checks/
- Leases: https://kubernetes.io/docs/concepts/architecture/leases/
- Running in multiple zones: https://kubernetes.io/docs/setup/best-practices/multiple-zones/
- Pod topology spread constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Ports and protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/

**etcd — official documentation**
- Clustering guide: https://etcd.io/docs/v3.5/op-guide/clustering/
- Disaster recovery: https://etcd.io/docs/v3.5/op-guide/recovery/
- Runtime reconfiguration: https://etcd.io/docs/v3.5/op-guide/runtime-configuration/
- Hardware recommendations: https://etcd.io/docs/v3.5/op-guide/hardware/
- Tuning (heartbeat interval, election timeout): https://etcd.io/docs/v3.5/tuning/
- Maintenance (compaction, defragmentation, alarms): https://etcd.io/docs/v3.5/op-guide/maintenance/
- FAQ (quorum, cluster sizing): https://etcd.io/docs/v3.5/faq/

**Load balancing components**
- kube-vip static Pod installation: https://kube-vip.io/docs/installation/static/
- kube-vip repository: https://github.com/kube-vip/kube-vip
- HAProxy configuration manual: https://docs.haproxy.org/
- Keepalived documentation: https://keepalived.readthedocs.io/en/latest/

**Certification**
- CNCF curriculum repository: https://github.com/cncf/curriculum
- KCA curriculum (PDF): https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf