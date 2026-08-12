# 361.1 High Availability Concepts and Theory

> **Weight: 10** · Exam 306-300 v3.0 · Objective 361 *High Availability Cluster Management*
> Author profile: Principal Platform Architect / Senior SRE. This is the theory that every later objective (Pacemaker, Corosync, LVS, DRBD, GFS2) is built on. If quorum, fencing and the availability arithmetic are not internalized here, every practical topic downstream becomes cargo-culting.

---

## 1. The production problem: availability is not a property you buy, it is one you engineer

A single server has an availability ceiling set by its least reliable component. A commodity server with quality parts fails a few times per decade; a power supply, a disk, a kernel panic, a botched `dnf update`, a data-center PDU trip, or a careless `systemctl stop` collapses that number instantly. At n=1 nodes the question is never *"will it fail?"* but *"what happens to the service when it does?"*

High Availability is the discipline of removing **single points of failure (SPOF)** so that the failure of any one component is survived automatically, within a bounded time, without human intervention and without data corruption. Three constraints are load-bearing and they fight each other:

1. **Detection** — the cluster must *know* a node/resource failed. Detection that is too fast causes false failovers (flapping); too slow inflates downtime.
2. **Recovery** — the service must restart elsewhere. Recovery requires that the failed node is *provably* not still writing to shared state — this is why **fencing** exists.
3. **Consistency** — under a network partition, at most one side may act. This is why **quorum** exists.

The naïve mental model — "add a second server and a floating IP" — is exactly how you build a **split-brain**: two nodes each believing they are the survivor, both mounting the same filesystem, both answering the VIP, silently corrupting data. HA theory is largely the set of mechanisms that make that impossible.

### 1.1 SPOF and fault domains

A **fault domain** is the blast radius of a single failure: a disk, a NIC, a host, a rack, a PDU, a top-of-rack switch, an availability zone, a region. HA is only meaningful *relative to a declared fault domain*. Two Pacemaker nodes in the same rack survive a node failure but not a rack PDU failure — the rack is still a SPOF. Genuinely fault-tolerant design pushes redundancy *up the fault-domain hierarchy* until the residual SPOF is acceptable for the SLA.

```
Component  →  Host  →  Rack  →  Row/PDU  →  AZ/Room  →  Region  →  Provider
   RAID       cluster    2 racks   dual PDU   multi-AZ   DR site   multi-cloud
```

Each rung up the ladder multiplies cost and latency and complicates consistency. The architect's job is to buy the *cheapest rung that meets the SLA*, not the highest one.

---

## 2. The arithmetic of availability

### 2.1 The core identity

$$A = \frac{\text{MTBF}}{\text{MTBF} + \text{MTTR}} = \frac{\text{MTTF}}{\text{MTTF} + \text{MTTR}}, \qquad \text{MTBF} = \text{MTTF} + \text{MTTR}$$

| Symbol | Name | Meaning |
|---|---|---|
| **MTTF** | Mean Time To Failure | Average *uptime* interval — how long a working unit runs before it breaks (non-repairable framing). |
| **MTTR** | Mean Time To Repair/Recovery | Average *downtime* interval — detect + decide + act + verify. In a cluster this is failover time, not human repair time. |
| **MTBF** | Mean Time Between Failures | Full cycle = MTTF + MTTR (repairable framing). |
| **MTBSI** | Mean Time Between System Incidents | Cycle including *service* incidents, not just hardware. |

**The load-bearing insight for SREs:** availability is dominated by the term you can actually move. You almost never improve MTTF (hardware is what it is); you crush **MTTR**. Going from a 30-minute human failover to a 30-second automated one improves availability by three orders of magnitude *without touching the hardware*. HA clustering is fundamentally an MTTR-reduction technology.

### 2.2 The "nines" — the number every SLA is written in

$$\text{Downtime}_{\text{year}} = (1 - A)\times 365.25\ \text{days}$$

| Availability | "Nines" | Downtime / year | / month | / week | Typical tier |
|---|---|---|---|---|---|
| 90 % | one nine | 36.5 days | 73 h | 16.8 h | toy / dev |
| 99 % | two nines | 3.65 days | 7.30 h | 1.68 h | internal tools |
| 99.9 % | three nines | 8.77 h | 43.8 min | 10.1 min | standard SaaS |
| 99.95 % | — | 4.38 h | 21.9 min | 5.04 min | business tier |
| 99.99 % | four nines | 52.6 min | 4.38 min | 1.01 min | HA cluster target |
| 99.999 % | five nines | 5.26 min | 26.3 s | 6.05 s | telco / carrier |
| 99.9999 % | six nines | 31.6 s | 2.63 s | 0.61 s | exotic / rarely real |

**Reading the table like an architect:** each nine costs roughly an order of magnitude more than the last for a linear gain in the customer's eyes. Five nines (5.26 min/year) means your *entire annual downtime budget* — including planned maintenance, kernel patching, and failover events — is smaller than a single reboot. That is why five-nines systems do rolling upgrades and never take the whole cluster down. The diminishing-returns curve is the central economic fact of HA: **know which nine the business is paying for, and stop there.**

### 2.3 Composition: serial dependencies vs parallel redundancy

A service is a *graph* of components. How their availabilities combine depends on the topology.

**Serial (dependency chain)** — the request needs *all* of them; failure of any one fails the whole:

$$A_{\text{serial}} = A_1 \times A_2 \times \dots \times A_n$$

Serial composition is corrosive: chaining components *always lowers* availability below the weakest link. Ten independent 99.9 % components in series = $0.999^{10} \approx 99.0\,\%$ — you lost a full nine just by having a chain. This is why microservice fan-outs and long dependency chains are an availability liability.

**Parallel (redundant)** — the service needs *any one* to survive; it fails only if *all* fail:

$$A_{\text{parallel}} = 1 - \prod_{i=1}^{n}(1 - A_i)$$

Redundancy is multiplicative in the *right* direction. Two 99 % nodes in parallel:

$$A = 1 - (1 - 0.99)^2 = 1 - 0.0001 = 99.99\,\%$$

Two nines of hardware → four nines of service, purely from a second node. **This single equation is the mathematical justification for the entire objective.** Add a third node: $1-(0.01)^3 = 99.9999\,\%$.

**The catch the equation hides:** the formula assumes *independent* failures. Shared PDU, shared switch, shared NFS server, shared control plane, correlated software bugs, or a common bad config deploy make the failures *correlated*, and correlated failures destroy the product. Real redundancy math is only as good as the independence of your fault domains. This is the quantitative version of §1.1.

### 2.4 Worked example (interview-grade)

A stateless web tier: 3 app nodes (each 99.5 %) behind a load balancer (99.95 %), talking to an HA database pair (each 99.9 %, active/passive).

- App tier (parallel, need ≥1): $1-(1-0.995)^3 = 1 - 1.25\times10^{-7} \approx 99.99999\%$
- DB pair (parallel): $1-(1-0.999)^2 = 99.9999\%$
- End-to-end (serial: LB × app-tier × DB): $0.9995 \times 0.9999999 \times 0.999999 \approx 99.949\%$

The **load balancer is now the SPOF** — it dominates the serial product. The lesson generalizes: after you cluster everything, availability is capped by whatever you *didn't* make redundant. A single LB caps you at 99.95 % no matter how many app nodes you add. Fix: redundant LBs (VRRP/keepalived), which is exactly why §9 exists.

### 2.5 SLA / SLO / SLI / error budget

| Term | Definition | Owner |
|---|---|---|
| **SLI** | Service Level *Indicator* — the measured number (e.g. successful-request ratio, p99 latency). | measured |
| **SLO** | Service Level *Objective* — internal target the SLI must meet (e.g. 99.95 % over 28 days). | engineering |
| **SLA** | Service Level *Agreement* — contractual promise with financial penalty; always **looser** than the SLO. | business/legal |
| **Error budget** | $1 - \text{SLO}$ — the *permitted* unavailability. Spent on releases, maintenance, and incidents. | SRE |

The error budget reframes availability from "never fail" to "fail no more than X." A 99.9 % SLO grants 43.8 min/month of budget; a risky rollout or a planned Corosync upgrade *spends* it deliberately. HA clusters exist to keep unplanned spend near zero so the budget funds *change*.

---

## 3. Redundancy models

| Model | Meaning | Spare cost | Survives | Typical use |
|---|---|---|---|---|
| **N** | No redundancy — N units carry the load, all needed. | 0 % | nothing | dev |
| **N+1** | One spare beyond the N needed. | ~1/N | any *single* failure | most HA clusters |
| **N+M** | M spares. | M/N | up to M simultaneous | large fleets |
| **2N** | Full duplicate of the whole system. | 100 % | entire primary set | active/passive DR |
| **2N+1** | Full duplicate plus one. | >100 % | primary set + 1 | five-nines telco |
| **Geo / 3-site** | Copies across regions. | 200 %+ | region/AZ loss | DR, disaster tolerance |

N+1 is the sweet spot for most Pacemaker clusters: a 3-node cluster is "2 doing work + 1 spare," survives any single node, and keeps quorum (see §5). 2N is the model behind active/passive database pairs and cross-site DR.

---

## 4. Cluster taxonomies

### 4.1 Three cluster purposes (do not conflate them)

| Cluster type | Goal | What it optimizes | Load spread? | Example stack |
|---|---|---|---|---|
| **High Availability (failover)** | Keep a service *up* through node loss. | MTTR / continuity | usually no | Pacemaker + Corosync |
| **Load Balancing** | Distribute request load across many backends; scale + availability. | throughput + availability | yes | LVS/IPVS, HAProxy, keepalived |
| **High Performance Computing (HPC)** | Parallelize one large computation. | wall-clock of a job | job parallelism | Slurm, MPI, Beowulf |

The exam tests that you *differentiate* these. HA ≠ load balancing: an HA failover cluster can run entirely active/passive with the standby idle (no load spread at all), while a load-balancing cluster spreads load but a naïve one has no failover of the *balancer itself*. Production systems compose them: LB cluster in front, HA cluster for stateful backends.

### 4.2 Active/Passive vs Active/Active

| Dimension | Active/Passive (failover) | Active/Active (load-sharing) |
|---|---|---|
| Standby utilization | Idle or "hot standby" — capacity wasted | All nodes serve — full utilization |
| Capacity after 1 failure | 100 % (spare takes full load) | **Degraded** — surviving nodes absorb the failed node's share |
| Application requirement | Any app; no coordination needed | App must be *cluster-aware* (concurrent access safe) |
| Shared state | Single owner at a time (safe) | Concurrent writers → needs cluster FS (GFS2/OCFS2) + DLM, or shared-nothing sharding |
| Failover visibility | Brief outage during takeover | Near-seamless (surviving nodes already live) |
| Complexity | Lower | Higher (distributed locking, split-brain risk higher) |
| Cost efficiency | Poor (paying for idle) | Good (all iron works) |
| Typical use | Databases, stateful single-writer services | Web tiers, read replicas, stateless services, clustered FS |

**Capacity-planning trap:** active/active looks cheaper because no node is idle — but if you run each node at 90 % and one dies, the survivors must absorb its load and immediately overload. Safe active/active is sized so that **N surviving nodes can carry N+1's worth of load** — i.e. you *still* keep headroom equivalent to the passive spare. The "no wasted capacity" pitch is only true if you overprovision anyway. In practice active/active buys *seamless failover and horizontal scale*, not free capacity.

### 4.3 Standby temperatures

| Standby | State of the spare | Failover time | Cost |
|---|---|---|---|
| **Cold** | Powered off / not provisioned | minutes–hours | lowest |
| **Warm** | Running, service stopped, data syncing | seconds–minutes | medium |
| **Hot** | Running, service loaded, state current | sub-second–seconds | highest |

---

## 5. Quorum — the mechanism that decides *who is allowed to act*

### 5.1 The problem it solves

When the cluster interconnect partitions, each side can still see itself and (falsely) conclude the other side is dead. If both sides then start the service and grab shared storage, you get **split-brain** and data corruption. Quorum is the rule that **at most one partition is permitted to run resources** — the partition holding a *majority* of votes.

$$\text{Quorate} \iff \text{votes}_{\text{partition}} \ge \left\lfloor \frac{\text{expected\_votes}}{2} \right\rfloor + 1$$

A 5-node cluster (expected_votes=5) needs ≥3 to be quorate. A 3–2 partition → the 3-side runs, the 2-side *self-inhibits* (Pacemaker default `no-quorum-policy=stop`). Only one side can ever hold the majority, so split-brain is arithmetically impossible **as long as fencing guarantees the losing side truly stops** (quorum and fencing are a pair, never one alone — see §6).

### 5.2 The two-node problem

Two nodes, one vote each, expected_votes=2 → majority needs 2. Any single failure leaves 1 vote → **no partition is ever quorate**, so a healthy survivor would refuse to run. Useless. Three canonical fixes:

| Fix | Mechanism | Trade-off |
|---|---|---|
| **`two_node: 1`** (Corosync) | Sets quorum to 1 and forces `wait_for_all`; relies **entirely on fencing** to prevent split-brain. | Both sides think they have quorum on a partition → *must* fence, or you corrupt data. |
| **Quorum device (qdevice/qnetd)** | A lightweight external arbiter casts a tie-breaking vote. | Adds a 3rd host (but not a full cluster node). Cleanest 2-node answer. |
| **SBD + watchdog** | Poison-pill on shared storage + hardware watchdog self-fences the loser. | Needs shared block device or reliable watchdog. |

### 5.3 Corosync votequorum tunables (know these cold)

| Option | Effect |
|---|---|
| `two_node: 1` | Two-node mode; quorum=1; auto-enables `wait_for_all`. |
| `wait_for_all: 1` | On cold start the cluster is *inquorate* until **every** node has been seen once. Prevents a booting node from fencing a slow-to-boot peer. |
| `last_man_standing: 1` | Dynamically recompute `expected_votes` as nodes leave cleanly, so a shrinking cluster can stay quorate down to the last node. |
| `last_man_standing_window` | Settling time (ms) before LMS recalculates. |
| `auto_tie_breaker: 1` | On an exact 50/50 split, the partition containing the node with the lowest nodeid (default) keeps quorum. |
| `expected_votes` | Total votes in a healthy cluster. |
| `quorum_gain / device votes` | Extra votes contributed by a qdevice. |

**LMS caveat:** `last_man_standing` will happily let a cluster shrink to a single surviving node holding quorum — powerful, but only safe when fencing is rock-solid, otherwise it is a split-brain generator. It also is incompatible with a qdevice on the same cluster.

---

## 6. Fencing / STONITH — *"the only cluster you can trust is one where the loser is provably dead"*

### 6.1 Why quorum is not enough

Quorum tells the *losing* side to stop — but a hung node, a frozen kernel, a stuck I/O path, or a node that lost its interconnect but not its storage may **not obey**. It could still be writing to the SAN or answering the VIP. **Fencing** (a.k.a. **STONITH — Shoot The Other Node In The Head**) *forcibly* removes the suspect node from the shared resources so the survivor can take over *safely*. Without fencing, Pacemaker will (correctly) refuse to recover resources — a cluster with `stonith-enabled=false` is a demo, never production.

### 6.2 Fencing methods

| Method | Mechanism | Agent examples | Notes |
|---|---|---|---|
| **Power / node fencing** | Cut/cycle the machine's power. | `fence_ipmilan`, `fence_ilo`, `fence_idrac`, `fence_apc` (PDU), `fence_vmware`, `fence_aws` | Most reliable — a powered-off node writes nothing. Needs out-of-band access (IPMI/BMC). |
| **Storage / fabric fencing** | Revoke the node's access to shared storage. | SCSI-3 PR (`fence_scsi`), `fence_mpath`, fabric zoning | Node stays up but cannot touch data. |
| **SBD (Storage-Based Death)** | Poison-pill written to a shared block "slot" + a **hardware watchdog** that self-resets the node. | `sbd` + `fence_sbd` | Works without a BMC; ideal for VMs / no-IPMI. Watchdog is the enforcer of last resort. |
| **Fabric / switch fencing** | Disable the node's switch port. | `fence_ifmib`, managed-switch agents | Isolates network access. |

### 6.3 Fencing pathologies

- **Fence race / fence loop:** on a partition each side tries to fence the other; the faster BMC wins. A 50/50 race can leave *both* dead or ping-pong reboot. Mitigations: `fencing delay` (`pcmk_delay_base` / `pcmk_delay_max`), quorum-gated fencing (only the quorate side fences), or an odd node count / qdevice to break symmetry.
- **`fence_ipmilan` on shared board power:** if IPMI shares the mainboard power rail, a truly dead node can't answer its own BMC → fencing "fails" → cluster blocks. Use a *separate* PDU-based agent or SBD as a fallback fencing topology.
- **Topology fallback:** Pacemaker supports fencing *levels* — try IPMI first, fall back to PDU — so a single BMC failure doesn't wedge recovery.

---

## 7. Split-brain and network partitioning

**Split-brain** = two (or more) partitions each independently deciding it is the authoritative one, both running the resource, both mutating shared state → **irreversible corruption**. It is the failure mode HA theory exists to prevent, and it is prevented by the *combination*:

```
Network partition  →  Quorum says "only the majority may act"
                   →  Fencing guarantees the minority is actually stopped
                   →  ∴ at most one active writer  ⇒ no corruption
```

Remove *either* leg and the guarantee collapses: quorum without fencing trusts a possibly-hung node to obey; fencing without quorum lets a minority fence the majority (a 1-node partition murdering the healthy 2). The exam wants you to state that **quorum decides, fencing enforces, and split-brain is the thing both together prevent.**

**Network partitioning awareness:** partitions arise from switch failures, MTU/jumbo-frame mismatches, spanning-tree convergence storms, saturated interconnects (Corosync token loss), firewall drops of the ring ports (UDP 5404/5405), or asymmetric routing. Best practice: **redundant, dedicated cluster interconnects** (Corosync ring0/ring1 on separate NICs/switches, `knet` transport with link redundancy) so a single network fault does not look like a node death.

---

## 8. Cluster resources and resource types

A **resource** is anything the cluster manager (Pacemaker) starts, stops, monitors and recovers — a VIP, a filesystem mount, a database, an apache instance. Resources are driven by **Resource Agents (RA)** implementing a `start / stop / monitor / (promote/demote)` contract.

### 8.1 Resource-agent classes

| Class | Standard | Example |
|---|---|---|
| **OCF** | Open Cluster Framework — the richest (params, health scoring). | `ocf:heartbeat:IPaddr2`, `ocf:heartbeat:Filesystem`, `ocf:pacemaker:ping` |
| **systemd** | Wraps a `.service` unit. | `systemd:nginx` |
| **LSB** | Legacy `/etc/init.d` scripts. | `lsb:myapp` |
| **service** | Auto-detects systemd/LSB. | `service:httpd` |
| **STONITH** | Fencing agents. | `stonith:fence_ipmilan` |

### 8.2 Resource composition primitives

| Construct | Meaning |
|---|---|
| **Primitive** | A single resource instance (one VIP, one FS). |
| **Group** | Ordered, colocated set — starts left→right, stops right→left, all land on the same node. The classic "VIP → filesystem → service" stack. |
| **Clone** | Same resource run on *many* nodes at once (active/active), e.g. a clustered FS or `ping` monitor. |
| **Promotable clone** (formerly master/slave) | A clone with **roles** — Promoted/Unpromoted (Primary/Secondary). Backs DRBD, Galera, PostgreSQL replication. |

### 8.3 Constraints — how resources are placed

| Constraint | Controls | Example |
|---|---|---|
| **Location** | *Where* a resource may/may not run (node preference / scoring, `INFINITY`). | "prefer node1", "never node3". |
| **Colocation** | Resources that must (or must not) share a node. | VIP colocated with the DB primary. |
| **Order** | Start/stop sequencing. | Mount FS *before* starting DB. |

Scores from `-INFINITY` to `+INFINITY` resolve conflicts; `INFINITY` means mandatory, finite scores are preferences the policy engine sums.

---

## 9. Load balancing (the "availability + scale" cluster)

### 9.1 L4 vs L7

| Layer | Operates on | Sees | Pros | Cons | Tools |
|---|---|---|---|---|---|
| **L4 (transport)** | IP:port, TCP/UDP | connection tuple | very fast, protocol-agnostic, high throughput | no app awareness, no content routing | LVS/IPVS, `keepalived` |
| **L7 (application)** | HTTP, headers, URL, TLS | full request | content routing, TLS termination, retries, health of app | more CPU, protocol-specific | HAProxy, nginx, Envoy |

### 9.2 Scheduling algorithms

| Algorithm | Rule | Best for |
|---|---|---|
| **Round Robin (rr)** | Next backend in rotation. | homogeneous, stateless |
| **Weighted RR (wrr)** | RR biased by capacity weight. | heterogeneous hardware |
| **Least Connections (lc)** | Fewest active connections. | long-lived / uneven sessions |
| **Weighted LC (wlc)** | LC biased by weight. | mixed capacity + long sessions |
| **Source Hash (sh)** | Hash client IP → sticky backend. | session affinity without cookies |
| **Destination Hash (dh)** | Hash on destination. | cache/proxy tiers |

### 9.3 LVS forwarding modes

| Mode | How | Return path | Scale | Constraint |
|---|---|---|---|---|
| **NAT** | Director rewrites dst IP. | back *through* director | limited (director is bottleneck) | simplest |
| **DR (Direct Routing)** | Director rewrites MAC only; VIP on all reals (lo). | reals → client **directly** | highest | same L2 segment |
| **TUN (IP tunneling)** | Encapsulates to real server. | reals → client directly | high, cross-subnet | reals must support IPIP |

The **Virtual IP (VIP)** is the shared service address that floats to whichever node/director is live — moved via `IPaddr2` (Pacemaker, gratuitous ARP) or **VRRP** (keepalived). A redundant LB pair on VRRP is the fix for the §2.4 SPOF.

---

## 10. Storage: shared vs replicated

| Property | Shared storage (SAN/iSCSI/NFS) | Replicated storage (DRBD) |
|---|---|---|
| Model | One external array, many nodes attach. | Block device mirrored node→node over network. |
| SPOF | The array/NFS server (unless itself HA). | None inherent — no shared box. |
| Cost | Expensive array + fabric. | Commodity local disks. |
| Concurrent write | Needs cluster FS (GFS2/OCFS2) + **DLM** to avoid corruption. | Protocol C = synchronous; primary/secondary or dual-primary (with cluster FS). |
| Distance | Fabric-limited. | LAN sync; WAN async (DRBD Proxy). |
| Fencing coupling | fence_scsi / mpath integrate. | must fence to avoid diverged replicas. |

**Cluster filesystem note:** ext4/xfs are *single-mount* — mounting on two nodes at once corrupts them. Active/active shared access requires **GFS2 or OCFS2** plus the **DLM (Distributed Lock Manager)**, itself a cloned Pacemaker resource. This is the storage half of objective 362.

---

## 11. The reference HA stack (Linux)

```
┌─────────────────────────────────────────────────────────┐
│  Resources:  IPaddr2 · Filesystem · systemd:pgsql · ...  │  ← Resource Agents (OCF/systemd/LSB/STONITH)
├─────────────────────────────────────────────────────────┤
│  Pacemaker  (CRM)                                         │  ← Cluster Resource Manager: policy engine (pengine),
│    pacemaker-controld / -schedulerd / -based (CIB)       │     placement, monitoring, recovery, fencing (fenced)
├─────────────────────────────────────────────────────────┤
│  Corosync   (messaging + membership + votequorum)        │  ← totem/knet ring, closed process group, quorum
├─────────────────────────────────────────────────────────┤
│  Kernel · NICs (redundant rings) · SBD/watchdog · BMC    │
└─────────────────────────────────────────────────────────┘
```

- **Corosync** = the *messaging & membership* layer: heartbeats over the token ring (knet transport, UDP 5405), decides who is in the cluster, runs **votequorum**.
- **Pacemaker** = the *brain*: holds cluster state in the **CIB** (Cluster Information Base, replicated XML), computes desired placement, drives resource agents, orchestrates fencing.
- **pcs / crmsh** = the admin CLIs on top.

---

## 12. Complete, syntactically valid configurations

### 12.1 `/etc/corosync/corosync.conf` — 3-node cluster, redundant knet rings, votequorum

```conf
totem {
    version:            2
    cluster_name:       ha-prod
    transport:          knet
    crypto_cipher:      aes256
    crypto_hash:        sha256
    token:              3000
    token_retransmits_before_loss_const: 10
    join:               50
    consensus:          3600
}

nodelist {
    node {
        ring0_addr:     10.10.0.11
        ring1_addr:     10.20.0.11
        name:           node1
        nodeid:         1
    }
    node {
        ring0_addr:     10.10.0.12
        ring1_addr:     10.20.0.12
        name:           node2
        nodeid:         2
    }
    node {
        ring0_addr:     10.10.0.13
        ring1_addr:     10.20.0.13
        name:           node3
        nodeid:         3
    }
}

quorum {
    provider:               corosync_votequorum
    expected_votes:         3
    wait_for_all:           1
    last_man_standing:      1
    last_man_standing_window: 10000
}

logging {
    to_logfile:     yes
    logfile:        /var/log/cluster/corosync.log
    to_syslog:      yes
    timestamp:      on
}
```

> Two rings (`ring0_addr` on 10.10.0.0/24, `ring1_addr` on 10.20.0.0/24) mean a single switch/NIC failure degrades but does not partition the cluster — the practical answer to §7.

### 12.2 Two-node cluster with an external **quorum device**

`corosync.conf` quorum block:

```conf
quorum {
    provider:       corosync_votequorum
    two_node:       0            # disabled: the qdevice supplies the tie-breaker instead
    device {
        model:      net
        votes:      1
        net {
            tls:            on
            host:           qnetd-arbiter.example.net
            algorithm:      ffsplit      # fifty-fifty split resolver
        }
    }
}
```

Arbiter (a small 3rd host, *not* a cluster node) runs `corosync-qnetd`; both cluster nodes run `corosync-qdevice`. Now a 1–1 partition is broken by the arbiter's vote → exactly one side is quorate.

### 12.3 STONITH — IPMI power fencing per node, with an SBD fallback level

```bash
# Primary fencing: IPMI/BMC power fencing, one device per victim node
pcs stonith create fence-node1 fence_ipmilan \
    pcmk_host_list="node1" ip="10.30.0.11" lanplus=1 \
    username="fenceadmin" password="REDACTED" \
    pcmk_delay_base="5s" \
    op monitor interval=60s

pcs stonith create fence-node2 fence_ipmilan \
    pcmk_host_list="node2" ip="10.30.0.12" lanplus=1 \
    username="fenceadmin" password="REDACTED" \
    pcmk_delay_base="0s" \
    op monitor interval=60s

# Keep each fence device off the node it kills
pcs constraint location fence-node1 avoids node1=INFINITY
pcs constraint location fence-node2 avoids node2=INFINITY

# Fallback: SBD as fencing level 2 (used if IPMI is unreachable)
pcs stonith create fence-sbd fence_sbd devices="/dev/disk/by-id/wwn-0xSHARED" \
    op monitor interval=120s
pcs stonith level add 1 node1 fence-node1
pcs stonith level add 2 node1 fence-sbd
pcs stonith level add 1 node2 fence-node2
pcs stonith level add 2 node2 fence-sbd

pcs property set stonith-enabled=true
```

> Asymmetric `pcmk_delay_base` (5 s vs 0 s) deterministically breaks the fence race of §6.3: node2's device fires first, so on a symmetric 2-node partition node1 loses.

### 12.4 SBD daemon config `/etc/sysconfig/sbd`

```bash
SBD_DEVICE="/dev/disk/by-id/wwn-0xSHARED"
SBD_WATCHDOG_DEV="/dev/watchdog"
SBD_WATCHDOG_TIMEOUT="5"
SBD_STARTMODE="always"
SBD_PACEMAKER="yes"
SBD_DELAY_START="no"
```

```bash
# Format the shared block device with SBD slots (msgwait ≈ 2× watchdog):
$ sbd -d /dev/disk/by-id/wwn-0xSHARED -4 20 -1 10 create
Initializing device /dev/disk/by-id/wwn-0xSHARED
Creating version 2.1 header on device 3 (uuid: 8f3c...)
Initializing 255 slots on device 3
Device /dev/disk/by-id/wwn-0xSHARED is initialized.
```

### 12.5 A classic active/passive resource **group** (VIP → filesystem → service)

```bash
pcs resource create webvip ocf:heartbeat:IPaddr2 \
    ip=10.10.0.100 cidr_netmask=24 nic=eth0 \
    op monitor interval=10s timeout=20s

pcs resource create webfs ocf:heartbeat:Filesystem \
    device="/dev/drbd0" directory="/srv/www" fstype="xfs" \
    op monitor interval=20s timeout=40s

pcs resource create webserver systemd:nginx \
    op monitor interval=15s timeout=30s

# Group = ordered + colocated. Start VIP→FS→nginx; stop reverse; all on one node.
pcs resource group add webstack webvip webfs webserver

# Prefer node1, but fail over automatically
pcs constraint location webstack prefers node1=100

# Don't ping-pong: require 2 failures in 5 min before migrating away
pcs resource meta webserver migration-threshold=2 failure-timeout=300s
```

### 12.6 DRBD replicated block device `/etc/drbd.d/r0.res` + promotable clone

```conf
resource r0 {
    protocol C;                 # synchronous: ack only after remote disk write
    device      /dev/drbd0;
    disk        /dev/vg0/lv_data;
    meta-disk   internal;

    net {
        cram-hmac-alg   sha256;
        shared-secret   "REDACTED";
        after-sb-0pri   discard-zero-changes;
        after-sb-1pri   discard-secondary;
        after-sb-2pri   disconnect;      # never auto-resolve a real split-brain
    }
    on node1 { address 10.20.0.11:7788; node-id 0; }
    on node2 { address 10.20.0.12:7788; node-id 1; }
}
```

```bash
# Pacemaker promotable clone: exactly one Primary, follows resources
pcs resource create drbd-r0 ocf:linbit:drbd drbd_resource=r0 \
    op monitor interval=29s role=Promoted \
    op monitor interval=31s role=Unpromoted
pcs resource promotable drbd-r0 promoted-max=1 promoted-node-max=1 \
    clone-max=2 clone-node-max=1 notify=true
pcs constraint order promote drbd-r0-clone then start webfs
pcs constraint colocation add webfs with Promoted drbd-r0-clone INFINITY
```

### 12.7 Redundant load-balancer VIP with `keepalived` (VRRP) — fixes §2.4

```conf
# /etc/keepalived/keepalived.conf  — MASTER (backup node uses state BACKUP, lower priority)
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight   -20            # drop priority if HAProxy dies → failover
}

vrrp_instance VI_1 {
    state           MASTER
    interface       eth0
    virtual_router_id 51
    priority        150
    advert_int      1
    authentication { auth_type PASS; auth_pass REDACTED }
    virtual_ipaddress { 10.10.0.200/24 dev eth0 }
    track_script    { chk_haproxy }
}
```

### 12.8 L7 balancer `/etc/haproxy/haproxy.cfg`

```conf
global
    maxconn 20000
    log /dev/log local0

defaults
    mode    http
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    option  httpchk GET /healthz

frontend web_in
    bind 10.10.0.200:80
    default_backend app_pool

backend app_pool
    balance leastconn
    option  redispatch
    server app1 10.10.0.11:8080 check inter 2s fall 3 rise 2
    server app2 10.10.0.12:8080 check inter 2s fall 3 rise 2
    server app3 10.10.0.13:8080 check inter 2s fall 3 rise 2
```

---

## 13. Verification and failure-diagnosis playbook

### 13.1 Is the cluster healthy? (`pcs status`)

```console
$ pcs status
Cluster name: ha-prod
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.7) - partition WITH quorum
  * Last updated: Wed Aug 12 14:03:11 2026
  * 3 nodes configured
  * 6 resource instances configured

Node List:
  * Online: [ node1 node2 node3 ]

Full List of Resources:
  * fence-node1  (stonith:fence_ipmilan):  Started node2
  * fence-node2  (stonith:fence_ipmilan):  Started node1
  * Resource Group: webstack:
    * webvip     (ocf:heartbeat:IPaddr2):  Started node1
    * webfs      (ocf:heartbeat:Filesystem): Started node1
    * webserver  (systemd:nginx):          Started node1

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

Read it top-down: **`partition WITH quorum`** (quorate), all nodes **Online**, and every resource **Started** — including the STONITH devices, which must never sit on the node they fence.

### 13.2 Quorum state (`corosync-quorumtool`)

```console
$ corosync-quorumtool -s
Quorum information
------------------
Date:             Wed Aug 12 14:04:02 2026
Quorum provider:  corosync_votequorum
Nodes:            3
Node ID:          1
Ring ID:          1.1a3
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
Flags:            Quorate WaitForAll LastManStanding

Membership information
----------------------
    Nodeid      Votes  Name
         1          1  node1 (local)
         2          1  node2
         3          1  node3
```

`Quorum: 2`, `Total votes: 3`, `Quorate: Yes`. If a partition dropped `Total votes` below `Quorum`, this flips to `Quorate: No` and Pacemaker stops resources on that side (default `no-quorum-policy=stop`).

### 13.3 Ring / interconnect health (`corosync-cfgtool`)

```console
$ corosync-cfgtool -s
Local node ID 1, transport knet
LINK ID 0 udp
        addr    = 10.10.0.11
        status  = 1 1 1        # all 3 peers connected on ring0
LINK ID 1 udp
        addr    = 10.20.0.11
        status  = 1 1 1        # all 3 peers connected on ring1
```

A `0` in the status vector = that peer unreachable on that ring. If ring0 shows `0` but ring1 shows `1`, the redundant ring saved you from a false partition — investigate the ring0 switch, do not panic-failover.

### 13.4 Validate config *before* it bites you (`crm_verify`)

```console
$ crm_verify -LV
   error: unpack_resources:  Resource start-up disabled since no STONITH resources have been defined
   error: unpack_resources:  Either configure some or disable STONITH with the stonith-enabled option
   error: unpack_resources:  NOTE: Clusters with shared data need STONITH to ensure data integrity
Errors found during check: config not valid
```

This is the single most common production mistake — **`stonith-enabled=false` on a cluster with shared data**. `crm_verify` catches it before failover proves it the hard way.

### 13.5 Fencing verification (`stonith_admin`)

```console
$ stonith_admin --list-registered
 fence-node1
 fence-node2
2 devices found

$ stonith_admin --history=node2
node2 was reset by node1 (fence-node2) at Wed Aug 12 13:41:57 2026: OK

# Dry-run a fence device without actually killing a node:
$ pcs stonith fence node2 --off        # DANGEROUS: really powers node2 off
Node: node2 fenced
```

### 13.6 Diagnosing the four canonical failure modes

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| Resources **stopped everywhere**, `partition WITHOUT quorum` | quorum lost (too many nodes/rings down) | `corosync-quorumtool -s` → `Quorate: No` | restore nodes/interconnect; qdevice; check `expected_votes` |
| `UNCLEAN (offline)` node, resources won't move | fencing failed/pending — cluster refuses to recover an unfenced node | `pcs status` shows `UNCLEAN`; `crm_mon -1` | fix BMC creds/reachability (`fence_ipmilan -o status`); add SBD fallback level |
| Both nodes reboot each other repeatedly | **fence loop / race** | `stonith_admin --history=*` ping-pong | add `pcmk_delay_base` asymmetry; quorum-gate fencing; add qdevice |
| DRBD both `Primary/StandAlone`, data diverged | **DRBD split-brain** | `drbdadm status` → `StandAlone`, `split-brain detected` | pick a survivor, discard victim (`drbdadm secondary`/`connect --discard-my-data`); fix fencing so it can't recur |

```console
$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  node2 connection:StandAlone       # <-- split-brain: peers refuse to talk
  peer-disk:DUnknown
```

```console
# Live event stream while you fail a node in a maintenance window:
$ crm_mon -rfANL
Node node1: online
Node node2: OFFLINE (standby)         # you put it in standby
  webvip    (ocf:heartbeat:IPaddr2):  Started node1
Migration Summary:
  * Node node1:
      webserver: migration-threshold=2 fail-count=0
```

### 13.7 Simulate before you break prod (`crm_simulate`)

```console
$ crm_simulate -L -S            # "what would the policy engine do right now?"
Current cluster status:
  Online: [ node1 node2 node3 ]
Transition Summary:
  * No actions need to be taken            # cluster is at its desired state
```

`crm_simulate` runs the scheduler against the live CIB *without acting* — the safest way to predict a failover's behavior before triggering it, and the SRE's answer to "what happens if node1 dies right now?"

---

## 14. References

- LPI — Exam 306 Objectives (306-300, v3.0): https://www.lpi.org/our-certifications/exam-306-objectives/
- LPI — LPIC-3 High Availability and Storage Clusters certification overview: https://www.lpi.org/our-certifications/lpic-3-306/
- ClusterLabs — Pacemaker documentation (Clusters from Scratch, Pacemaker Explained): https://clusterlabs.org/pacemaker/doc/
- ClusterLabs — *Pacemaker Explained* (fencing, quorum, constraints): https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/html/
- Corosync — `votequorum(5)` and project documentation: https://corosync.github.io/corosync/
- ClusterLabs — quorum device / `corosync-qdevice(8)`, `corosync-qnetd(8)`: https://github.com/corosync/corosync-qdevice
- ClusterLabs — SBD (Storage-Based Death) fencing: https://github.com/ClusterLabs/sbd
- LINBIT — DRBD 9 User's Guide: https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
- The Linux Virtual Server Project (LVS/IPVS): http://www.linuxvirtualserver.org/
- Keepalived — official documentation (VRRP, healthchecks): https://www.keepalived.org/documentation.html
- HAProxy — Configuration Manual: https://docs.haproxy.org/
- Red Hat — Configuring and Managing High Availability Clusters (RHEL 9): https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index
- SUSE — Linux Enterprise High Availability Extension Administration Guide: https://documentation.suse.com/sle-ha/
- Google SRE Book — *Service Level Objectives* and *Embracing Risk* (error budgets, availability math): https://sre.google/sre-book/service-level-objectives/