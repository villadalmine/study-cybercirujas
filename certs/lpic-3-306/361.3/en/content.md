# LPIC-3 306 — Topic 361.3: Failover Clusters

> Exam 306-300, version 3.0 · Objective weight: **13.34** · Focus: Pacemaker + Corosync active/passive and multi-state failover clustering, fencing (STONITH), quorum, constraints, and operational diagnosis.

---

## 1. The production problem: what a failover cluster actually buys you

A *failover cluster* keeps a **stateful, single-writer service** available across the failure of a node, a link, a disk, or a whole rack — without ever letting two nodes believe they own the same resource at the same time. That last clause is the entire discipline. Availability is easy; **integrity under partition** is the hard part.

Consider the canonical production incident. You run PostgreSQL as a primary/standby pair with a floating service IP `10.0.10.100`. The primary's kernel soft-locks: it stops answering the network but its disks and its `postgres` backends are still very much alive. Your monitoring flips the standby to primary and moves the VIP. Ninety seconds later the original node recovers, still holding its old VIP alias and still accepting writes on its data directory. You now have **two primaries writing divergent WAL** to what your applications think is one database. This is *split-brain*, and no amount of "the standby is healthier" logic prevents it — the sick node never agreed to give up.

A failover cluster solves this with three cooperating mechanisms, and you must understand where each one lives:

| Concern | Question it answers | Layer | Linux component |
|---|---|---|---|
| **Membership & messaging** | Which nodes can talk, right now? | Totem / knet | **Corosync** |
| **Quorum** | Is *my* partition the authoritative one? | votequorum | **Corosync** (`votequorum`) + optional `qdevice` |
| **Resource orchestration** | What should run where, and in what order? | Cluster Resource Manager | **Pacemaker** |
| **Fencing** | How do I *guarantee* the other side is dead before I take over? | STONITH | **Pacemaker** `pacemaker-fenced` + fence agents / SBD |

The non-negotiable architectural truth of this topic: **you may not fail over a shared or single-writer resource until you have positively fenced the previous owner.** "It stopped answering" is not evidence it stopped writing. Fencing turns an *assumption* ("it's probably dead") into a *fact* ("I power-cycled it / I cut its disk access"). Every design decision below flows from that.

---

## 2. Architecture in depth

### 2.1 The two-layer stack

```
        ┌──────────────────────────────────────────────────────────┐
        │                      Pacemaker (CRM)                       │
        │  pacemakerd ── supervises ──▶ the daemons below            │
        │   ├── pacemaker-based       (CIB manager: the XML config)  │
        │   ├── pacemaker-controld    (controller / DC election)     │
        │   ├── pacemaker-schedulerd   (policy engine → transition)  │
        │   ├── pacemaker-execd        (runs resource agents)        │
        │   ├── pacemaker-fenced       (STONITH / fencing)           │
        │   └── pacemaker-attrd        (transient node attributes)   │
        └───────────────▲───────────── CPG API ─────────────────────┘
                        │ (closed process group messaging + membership + quorum)
        ┌───────────────┴──────────────────────────────────────────┐
        │                       Corosync                             │
        │   Totem SRP / Kronosnet (knet) transport                   │
        │   votequorum  ·  CPG  ·  cmap (runtime config map)         │
        └────────────────────────────────────────────────────────────┘
```

**Corosync** is the substrate. It runs the **Totem** protocol (a token-passing membership/ordering protocol) over the **knet** transport (Corosync 3.x default — supports up to 8 redundant links, per-link crypto, compression, and automatic link failover). Corosync gives Pacemaker three services: **CPG** (totally-ordered, reliable group messaging), **membership** (who is up), and **votequorum** (is this partition quorate).

**Pacemaker** is the brain. It never talks to the network directly for cluster membership — it *subscribes* to Corosync. Its daemons split responsibilities:

- **`pacemaker-based`** (the CIB manager) owns the **Cluster Information Base**, an XML document replicated and kept consistent across all nodes. Everything you configure lives here.
- **`pacemaker-controld`** runs on every node; the cluster elects one node's controld as the **DC (Designated Controller)**. The DC is the only node that *computes* decisions.
- **`pacemaker-schedulerd`** (the policy engine) runs on the DC. Given the current CIB + status, it computes a **transition graph**: the ordered set of resource actions needed to reach the desired state. It is a pure function — same input, same output — which is exactly what makes `crm_simulate` possible.
- **`pacemaker-execd`** executes resource agents locally (unprivileged where possible). It is the only component that touches your actual service.
- **`pacemaker-fenced`** executes fencing. It is deliberately separate so that fencing can happen even when resource management is wedged.
- **`pacemaker-attrd`** manages node attributes (e.g., a resource agent recording replication lag).

### 2.2 The CIB: one XML tree to rule them all

Everything — nodes, resources, constraints, defaults, and live status — is one document. You rarely edit it by hand, but you must be able to read it, because every tool (`pcs`, `crmsh`) is a front-end that renders down to this.

```xml
<cib crm_feature_set="3.16.2" validate-with="pacemaker-3.9" epoch="42" num_updates="7" admin_epoch="0" have-quorum="1" dc-uuid="1">
  <configuration>
    <crm_config>
      <cluster_property_set id="cib-bootstrap-options">
        <nvpair id="cib-bootstrap-options-stonith-enabled"   name="stonith-enabled"   value="true"/>
        <nvpair id="cib-bootstrap-options-no-quorum-policy"  name="no-quorum-policy"  value="stop"/>
        <nvpair id="cib-bootstrap-options-cluster-name"      name="cluster-name"      value="pgcluster"/>
      </cluster_property_set>
    </crm_config>
    <nodes>
      <node id="1" uname="node1"/>
      <node id="2" uname="node2"/>
      <node id="3" uname="node3"/>
    </nodes>
    <resources><!-- primitives, groups, clones, promotables --></resources>
    <constraints><!-- location, colocation, order --></constraints>
    <rsc_defaults>
      <meta_attributes id="rsc-options">
        <nvpair id="rsc-options-resource-stickiness"   name="resource-stickiness"   value="100"/>
        <nvpair id="rsc-options-migration-threshold"   name="migration-threshold"   value="3"/>
      </meta_attributes>
    </rsc_defaults>
    <op_defaults>
      <meta_attributes id="op-options">
        <nvpair id="op-options-timeout" name="timeout" value="60s"/>
      </meta_attributes>
    </op_defaults>
  </configuration>
  <status><!-- runtime only: never edit; regenerated by the cluster --></status>
</cib>
```

Key invariants to internalize:

- **`epoch`/`num_updates`/`admin_epoch`** form the CIB version. On a partition merge the *higher* version wins — this is how a rejoining node's stale config is discarded rather than overwriting the live one.
- The `<configuration>` half is what you manage. The `<status>` half is machine-owned; treat it as read-only. `crm_verify` validates the former against the schema named in `validate-with`.

### 2.3 Resource agents (the abstraction that makes a service "clusterable")

Pacemaker never knows what "PostgreSQL" is. It knows *resource agents* — executables implementing a fixed verb set. The **class** determines the calling convention:

| Class | Example | start/stop | monitor | promote/demote | Parameters | Notes |
|---|---|---|---|---|---|---|
| **ocf** | `ocf:heartbeat:IPaddr2` | ✅ | ✅ (rich) | ✅ | ✅ typed, validated | The only fully cluster-aware class. Use it. |
| **systemd** | `systemd:nginx` | ✅ | ✅ (active/failed) | ❌ | ❌ | Handy, but no parameters and shallow health. Beware unit also enabled at boot → double start. |
| **lsb** | `lsb:myapp` | ✅ | ⚠️ status only | ❌ | ❌ | Legacy `/etc/init.d`; must be LSB-compliant or monitor lies. |
| **service** | `service:foo` | ✅ | varies | ❌ | ❌ | Auto-resolves to systemd/lsb. |
| **stonith** | `stonith:fence_ipmilan` | n/a | ✅ | n/a | ✅ | Fence agents; managed by `pacemaker-fenced`. |

**OCF return codes are the contract** — a `monitor` that returns the wrong code is the single most common cause of phantom failovers:

| Code | Symbol | Meaning to the cluster |
|---|---|---|
| 0 | `OCF_SUCCESS` | Running (or, for promote, now Promoted) |
| 1 | `OCF_ERR_GENERIC` | Soft error → will retry/recover |
| 2 | `OCF_ERR_ARGS` | Bad invocation |
| 5 | `OCF_ERR_INSTALLED` | Binary/package missing → **won't even try elsewhere the same way** |
| 6 | `OCF_ERR_CONFIGURED` | Config invalid → fatal, no failover |
| 7 | `OCF_NOT_RUNNING` | Cleanly stopped (expected during monitor of a stopped instance) |
| 8 | `OCF_RUNNING_MASTER` | Running **and promoted** |
| 9 | `OCF_FAILED_MASTER` | Promoted instance is broken → demote/recover |

### 2.4 Resource *shapes*

- **primitive** — one instance of one service.
- **group** — an ordered, colocated stack. Members start left→right, stop right→left, and always land on the same node. Sugar for the 90% active/passive case (VIP → filesystem → daemon).
- **clone** — the same primitive on N nodes. *Anonymous* (stateless, e.g. a monitoring agent) or *globally-unique* (each copy distinct).
- **promotable clone** (formerly *master/slave*, now **Promoted/Unpromoted**) — a clone whose instances have two runtime roles. This is how PostgreSQL/DRBD/GaleraArbitrator model "one primary, N replicas." The RA implements `promote`/`demote`/`notify`.

---

## 3. Design comparisons and trade-offs

### 3.1 Failover cluster vs. load-balanced cluster (why 361.3 ≠ 361.2)

| Dimension | Failover cluster (this topic) | Load-balanced cluster |
|---|---|---|
| Concurrency model | **Single active owner** per resource | All backends active |
| State | Stateful / single-writer (DB, filesystem, VIP) | Ideally stateless |
| Failure response | Migrate ownership after **fencing** | Drop a backend from the pool |
| Split-brain risk | **High** — the core problem | Low (no shared write state) |
| Typical stack | Pacemaker + Corosync + STONITH | LVS/IPVS, HAProxy, keepalived |
| Recovery time | seconds → tens of seconds (fence + start) | sub-second (health-check eviction) |

### 3.2 Front-end tools: `pcs` vs `crmsh`

| | `pcs` | `crmsh` (`crm`) |
|---|---|---|
| Origin / default on | Red Hat family (RHEL, Rocky, Alma), now also SUSE | SUSE / openSUSE historically |
| Daemon dependency | Needs **`pcsd`** running (also does node auth, config sync, web UI on :2224) | No daemon; edits CIB directly |
| Auth model | Token-based host auth (`pcs host auth`) | Relies on SSH/hacluster you set up |
| Batch editing | `pcs cluster cib` → edit file → `pcs cluster cib-push` | `crm configure edit` (interactive shell, atomic commit) |
| Learning curve | Verb-noun, discoverable | Terser, powerful `configure` sub-shell |

Both compile to the same CIB; pick the one your distro ships and stay consistent. The exam expects fluency in **both** for reading, `pcs` for driving.

### 3.3 Fencing methods

| Method | Agent | Kills by | Needs | Best for | Gotcha |
|---|---|---|---|---|---|
| **IPMI/BMC** | `fence_ipmilan` | Power off/cycle via out-of-band board | BMC reachable on a **separate** network | Bare metal | If BMC shares the failed node's power/switch, it can't fence |
| **PDU** | `fence_apc`, `fence_apc_snmp` | Cutting the outlet | Managed PDU | Bare metal, no BMC | Dual-corded servers need both outlets cut |
| **Hypervisor** | `fence_vmware_soap`, `fence_xvm`, `fence_kubevirt` | Destroying the VM | Access to host API | Virtualized clusters | Host API is a new SPOF |
| **Cloud** | `fence_aws`, `fence_gce`, `fence_azure_arm` | Stop/terminate instance | Cloud credentials/IAM | Cloud IaaS | API latency; IAM scoping |
| **Storage fencing** | `fence_scsi`, `fence_mpath` | SCSI-3 PR reservation eviction | Shared LUN w/ PR support | Shared-disk clusters | *Cuts I/O, doesn't reboot* — node may keep running |
| **SBD (poison pill)** | `fence_sbd` (disk) / diskless | Watchdog self-reset triggered by disk message or lost quorum | Hardware/softdog watchdog + (optional) shared block dev | Clusters lacking a power fence | Watchdog timeouts must be tuned precisely |

**Rule of thumb:** prefer a *power/isolation* fence (IPMI/PDU/hypervisor/cloud) as level 1. Add **SBD** as a self-fencing safety net (fence level 2) when the primary path can be unreachable. Two independent methods = a **fencing topology**.

### 3.4 Quorum strategies for a 2-node cluster (the classic trap)

Two nodes can't vote a majority when they split — each side sees 1 of 2. Options:

| Strategy | Config | Behaviour on partition | Trade-off |
|---|---|---|---|
| `two_node: 1` | corosync votequorum | Both sides stay "quorate"; **relies entirely on fencing + `pcmk_delay`** to break the tie | Simple, but a fence race is possible without delay tuning |
| **QDevice** (`corosync-qnetd`) | 3rd arbiter host runs `qnetd`; nodes run `qdevice` | Arbiter casts the deciding vote → true majority | Best answer; needs one small always-on host |
| **Diskless SBD** | `stonith-watchdog-timeout` | Losing quorum → node self-fences via watchdog | No extra host, but a full network cut can fence *both* |
| **Shared-disk SBD** | `fence_sbd` + shared LUN | Poison pill on shared storage | Needs shared storage reachable by both |

`two_node: 1` **implicitly enables** `wait_for_all: 1`: after a cold boot the cluster refuses to be quorate until it has seen *both* nodes at least once — preventing a lone survivor from fencing a peer it never met.

---

## 4. Complete, uncut infrastructure

The scenario below is a **3-node cluster** (`node1`, `node2`, `node3`) providing:
1. An **active/passive web stack** — floating VIP + Apache in a group.
2. A **promotable PostgreSQL** (via PAF `pgsqlms`) demonstrating multi-state failover.
3. **IPMI fencing** with per-node stagger, plus **diskless SBD** as a watchdog safety net.
4. **QDevice is not needed at 3 nodes** (natural majority), but the 2-node variant is shown for contrast.

Networks: `10.0.10.0/24` (service/ring0), `10.0.20.0/24` (dedicated ring1 for Corosync redundancy), BMCs on `10.0.30.0/24`.

### 4.1 `/etc/corosync/corosync.conf` — knet, two links, encrypted

```ini
# /etc/corosync/corosync.conf  — Corosync 3.x (knet transport)
totem {
    version:        2
    cluster_name:   pgcluster
    transport:      knet          # default in Corosync 3; enables multi-link + crypto
    crypto_cipher:  aes256        # encrypt on-wire cluster traffic
    crypto_hash:    sha256        # authenticate (replaces the old plain authkey-only model)

    # token loss detection. Default is 1000 ms. On virtualized / busy nodes,
    # raise it to avoid spurious membership churn. Effective token for knet =
    # token + (nodes - 2) * token_coefficient (token_coefficient default 650 ms).
    token:              3000
    token_coefficient:  650
    # Number of consecutive token losses before declaring the ring faulty.
    token_retransmits_before_loss_const: 10
}

nodelist {
    node {
        ring0_addr: 10.0.10.11    # LINK 0
        ring1_addr: 10.0.20.11    # LINK 1 (independent NIC + switch)
        name:       node1
        nodeid:     1
    }
    node {
        ring0_addr: 10.0.10.12
        ring1_addr: 10.0.20.12
        name:       node2
        nodeid:     2
    }
    node {
        ring0_addr: 10.0.10.13
        ring1_addr: 10.0.20.13
        name:       node3
        nodeid:     3
    }
}

quorum {
    provider: corosync_votequorum
    # For the 2-node variant instead of 3 nodes, you would set:
    #   two_node: 1          # implies wait_for_all: 1
    # and add a qdevice{} block pointing at a corosync-qnetd arbiter.
}

logging {
    to_logfile:   yes
    logfile:      /var/log/cluster/corosync.log
    to_syslog:    yes
    timestamp:    on
    debug:        off
}
```

The shared secret for `crypto_*` lives in `/etc/corosync/authkey` (mode `0400`, root-only), generated once and copied to every node:

```bash
$ corosync-keygen                 # writes /etc/corosync/authkey (2048 bits from /dev/urandom)
Corosync Cluster Engine Authentication key generator.
Gathering 2048 bits for key from /dev/urandom.
Writing corosync key to /etc/corosync/authkey.
$ scp /etc/corosync/authkey node2:/etc/corosync/authkey
$ scp /etc/corosync/authkey node3:/etc/corosync/authkey
```

### 4.2 The `pcs` build script (idempotent, end-to-end)

```bash
#!/usr/bin/env bash
# build-cluster.sh — run from node1. Idempotent: re-running only reconciles drift.
set -euo pipefail

# --- 0. Prereqs on every node (packages + hacluster password + daemons) -------
for n in node1 node2 node3; do
  ssh "$n" 'dnf install -y pacemaker corosync pcs fence-agents-ipmilan sbd resource-agents'
  ssh "$n" 'echo "hacluster:S3cureCluster!" | chpasswd'
  ssh "$n" 'systemctl enable --now pcsd'
done

# --- 1. Authenticate the pcsd nodes to each other ------------------------------
pcs host auth node1 node2 node3 -u hacluster -p 'S3cureCluster!'

# --- 2. Create the cluster (writes corosync.conf + authkey to all nodes) --------
pcs cluster setup pgcluster \
    node1 addr=10.0.10.11 addr=10.0.20.11 \
    node2 addr=10.0.10.12 addr=10.0.20.12 \
    node3 addr=10.0.10.13 addr=10.0.20.13 \
    transport knet crypto_cipher=aes256 crypto_hash=sha256 \
    totem token=3000

# --- 3. Start + enable on boot -------------------------------------------------
pcs cluster start --all
pcs cluster enable --all

# --- 4. Cluster-wide properties -------------------------------------------------
pcs property set stonith-enabled=true
pcs property set no-quorum-policy=stop           # safest default for stateful data
pcs resource defaults update resource-stickiness=100
pcs resource defaults update migration-threshold=3

# --- 5. Fencing level 1: IPMI, one stonith device per target -------------------
# pcmk_delay_base staggers simultaneous fence attempts so a 2-way race can't
# power both nodes off. (Not strictly needed at 3 nodes, shown for completeness.)
pcs stonith create fence-node1 fence_ipmilan \
    pcmk_host_list="node1" ip=10.0.30.11 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=0s   op monitor interval=60s
pcs stonith create fence-node2 fence_ipmilan \
    pcmk_host_list="node2" ip=10.0.30.12 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=5s   op monitor interval=60s
pcs stonith create fence-node3 fence_ipmilan \
    pcmk_host_list="node3" ip=10.0.30.13 username=fenceadm password=REDACTED \
    lanplus=1 pcmk_delay_base=10s  op monitor interval=60s

# Never let a node fence its own IPMI board:
pcs constraint location fence-node1 avoids node1=INFINITY
pcs constraint location fence-node2 avoids node2=INFINITY
pcs constraint location fence-node3 avoids node3=INFINITY

# --- 6. Web stack: VIP + Apache as an ordered, colocated group -----------------
pcs resource create web-vip ocf:heartbeat:IPaddr2 \
    ip=10.0.10.100 cidr_netmask=24 nic=eth0 \
    op monitor interval=10s timeout=20s

pcs resource create web-srv ocf:heartbeat:apache \
    configfile=/etc/httpd/conf/httpd.conf \
    statusurl="http://127.0.0.1/server-status" \
    op monitor interval=20s timeout=30s

pcs resource group add web web-vip web-srv       # start vip→srv, stop srv→vip, colocated

# --- 7. Promotable PostgreSQL (PAF) --------------------------------------------
pcs resource create pgsqld ocf:heartbeat:pgsqlms \
    bindir=/usr/pgsql-15/bin pgdata=/var/lib/pgsql/15/data \
    recovery_template=/etc/postgresql/pg_replica.conf.pcmk \
    op start   timeout=60s  interval=0s \
    op stop    timeout=60s  interval=0s \
    op promote timeout=30s  interval=0s \
    op demote  timeout=120s interval=0s \
    op monitor interval=15s timeout=10s role="Promoted" \
    op monitor interval=16s timeout=10s role="Unpromoted" \
    meta notify=true \
    promotable notify=true promoted-max=1 promoted-node-max=1 clone-max=3 clone-node-max=1

# The DB VIP must live where PostgreSQL is *promoted*:
pcs resource create pg-vip ocf:heartbeat:IPaddr2 \
    ip=10.0.10.101 cidr_netmask=24 nic=eth0 op monitor interval=10s
pcs constraint colocation add pg-vip with promoted pgsqld-clone INFINITY
pcs constraint order promote pgsqld-clone then start pg-vip symmetrical=false kind=Mandatory

# --- 8. Push and verify --------------------------------------------------------
crm_verify -L -V && echo "CIB OK"
pcs status
```

### 4.3 Diskless SBD as fence level 2 (watchdog self-reset)

```bash
# /etc/sysconfig/sbd  (on every node)
SBD_WATCHDOG_DEV=/dev/watchdog          # hardware watchdog; softdog only as last resort
SBD_WATCHDOG_TIMEOUT=5                   # seconds; the CPU must pet the dog within this
SBD_STARTMODE=always
SBD_PACEMAKER=yes                        # tie SBD liveness to Pacemaker health
SBD_DELAY_START=no
# No SBD_DEVICE line ⇒ diskless mode (watchdog + quorum only).
```

Wire it into Pacemaker and layer it under IPMI:

```bash
$ pcs stonith sbd enable                 # regenerates config across nodes, needs a restart
$ pcs cluster stop --all && pcs cluster start --all
$ pcs property set stonith-watchdog-timeout=10   # must be >= 2 * SBD_WATCHDOG_TIMEOUT

# Fencing topology: try IPMI first, fall back to watchdog self-fence.
$ pcs stonith level add 1 node1 fence-node1
$ pcs stonith level add 2 node1 watchdog
$ pcs stonith level add 1 node2 fence-node2
$ pcs stonith level add 2 node2 watchdog
$ pcs stonith level add 1 node3 fence-node3
$ pcs stonith level add 2 node3 watchdog
```

### 4.4 Ansible provisioning (YAML) — the same build, declaratively

```yaml
---
# playbooks/failover-cluster.yml — provisions the Pacemaker/Corosync stack.
- name: Provision Pacemaker failover cluster
  hosts: cluster_nodes            # node1, node2, node3 in inventory
  become: true
  vars:
    cluster_name: pgcluster
    hacluster_password: "S3cureCluster!"
    fence_user: fenceadm
    fence_password: "REDACTED"
  tasks:
    - name: Install HA packages
      ansible.builtin.dnf:
        name:
          - pacemaker
          - corosync
          - pcs
          - fence-agents-ipmilan
          - sbd
          - resource-agents
        state: present

    - name: Set the hacluster password
      ansible.builtin.user:
        name: hacluster
        password: "{{ hacluster_password | password_hash('sha512') }}"

    - name: Enable and start pcsd
      ansible.builtin.systemd:
        name: pcsd
        enabled: true
        state: started

- name: Form the cluster (run once, on the primary)
  hosts: node1
  become: true
  vars:
    cluster_name: pgcluster
    hacluster_password: "S3cureCluster!"
  tasks:
    - name: Authenticate pcsd hosts
      ansible.builtin.command: >
        pcs host auth node1 node2 node3
        -u hacluster -p {{ hacluster_password }}
      register: auth
      changed_when: "'Authorized' in auth.stdout"

    - name: Create the cluster if it does not exist
      ansible.builtin.command: >
        pcs cluster setup {{ cluster_name }}
        node1 addr=10.0.10.11 addr=10.0.20.11
        node2 addr=10.0.10.12 addr=10.0.20.12
        node3 addr=10.0.10.13 addr=10.0.20.13
        transport knet crypto_cipher=aes256 crypto_hash=sha256
      args:
        creates: /etc/corosync/corosync.conf   # idempotency guard

    - name: Start and enable the whole cluster
      ansible.builtin.command: "pcs cluster {{ item }} --all"
      loop: [start, enable]

    - name: Baseline cluster properties
      ansible.builtin.command: "pcs property set {{ item }}"
      loop:
        - stonith-enabled=true
        - no-quorum-policy=stop
```

---

## 5. Driving and observing the cluster (real terminal sessions)

### 5.1 Health at a glance

```console
$ pcs status
Cluster name: pgcluster
Cluster Summary:
  * Stack: corosync (Pacemaker is running)
  * Current DC: node1 (version 2.1.6-9.1.el9-6fdc9deea29) - partition with quorum
  * Last updated: Wed Aug 12 14:22:07 2026 on node1
  * Last change:  Wed Aug 12 14:20:43 2026 by root via cibadmin on node1
  * 3 nodes configured
  * 9 resource instances configured

Node List:
  * Online: [ node1 node2 node3 ]

Full List of Resources:
  * fence-node1        (stonith:fence_ipmilan):  Started node2
  * fence-node2        (stonith:fence_ipmilan):  Started node3
  * fence-node3        (stonith:fence_ipmilan):  Started node1
  * Resource Group: web:
    * web-vip          (ocf:heartbeat:IPaddr2):  Started node1
    * web-srv          (ocf:heartbeat:apache):   Started node1
  * pg-vip             (ocf:heartbeat:IPaddr2):  Started node2
  * Clone Set: pgsqld-clone [pgsqld] (promotable):
    * pgsqld           (ocf:heartbeat:pgsqlms):  Promoted node2
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node1
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node3

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

### 5.2 Membership and quorum (Corosync side)

```console
$ corosync-quorumtool -s
Quorum information
------------------
Date:             Wed Aug 12 14:25:31 2026
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
Flags:            Quorate

Membership information
----------------------
    Nodeid      Votes Name
         1          1 node1 (local)
         2          1 node2
         3          1 node3
```

Link (ring) health, per node, per link:

```console
$ corosync-cfgtool -s
Local node ID 1, transport knet
LINK ID 0 udp
	addr	= 10.0.10.11
	status:
		nodeid:   1:	localhost
		nodeid:   2:	connected
		nodeid:   3:	connected
LINK ID 1 udp
	addr	= 10.0.20.11
	status:
		nodeid:   1:	localhost
		nodeid:   2:	connected
		nodeid:   3:	connected
```

### 5.3 Watching a failover live

`crm_mon` is the operator's dashboard. In one pane run `crm_mon -rfA` (show inactive `-r`, failcounts `-f`, node attributes `-A`), then hard-kill `node2`:

```console
$ crm_mon -rfA
Cluster Summary:
  * Stack: corosync
  * Current DC: node1 (version 2.1.6) - partition with quorum
  * 3 nodes configured
  * 9 resource instances configured

Node List:
  * Online: [ node1 node3 ]
  * OFFLINE: [ node2 ]

Full List of Resources:
  * fence-node2        (stonith:fence_ipmilan):  Started node3
  * Clone Set: pgsqld-clone [pgsqld] (promotable):
    * pgsqld           (ocf:heartbeat:pgsqlms):  Promoted node1      # promoted here now
    * pgsqld           (ocf:heartbeat:pgsqlms):  Unpromoted node3
    * pgsqld           (ocf:heartbeat:pgsqlms):  Stopped (node2 offline)
  * pg-vip             (ocf:heartbeat:IPaddr2):  Started node1

Node Attributes:
  * Node: node1:
    + master-pgsqld    : 1001
  * Node: node3:
    + master-pgsqld    : 1000

Migration Summary:
```

The corresponding controller log shows the exact chain — **fence first, promote second**. This ordering is the whole point:

```console
$ journalctl -u pacemaker -n 12 --no-pager
node1 pacemaker-controld  [1123] notice: State transition S_IDLE -> S_POLICY_ENGINE
node1 pacemaker-schedulerd[1120] warning: Cluster node node2 will be fenced: peer is no longer part of the cluster
node1 pacemaker-schedulerd[1120] notice: Scheduling Node node2 for STONITH
node1 pacemaker-fenced     [1117] notice: Requesting that node3 perform 'reboot' of node2
node3 pacemaker-fenced     [1119] notice: Operation 'reboot' [4451] for node2 using fence-node2 returned 0 (OK)
node1 pacemaker-fenced     [1117] notice: Peer node2 was terminated (reboot) by node3 on behalf of pacemaker-controld: OK
node1 pacemaker-controld  [1123] notice: Peer node2 was fenced: OK — promoting pgsqld on node1
node1 pacemaker-schedulerd[1120] notice: Promote pgsqld:0 ( Unpromoted -> Promoted node1 )
node1 pacemaker-controld  [1123] notice: Initiating promote operation pgsqld_promote_0 on node1
node1 pacemaker-controld  [1123] notice: Transition 47 (Complete=6, Pending=0): Complete
node1 pacemaker-controld  [1123] notice: State transition S_TRANSITION_ENGINE -> S_IDLE
```

### 5.4 Common day-2 operations

```console
# Graceful maintenance: park node3, then take the whole cluster hands-off.
$ pcs node standby node3
$ pcs property set maintenance-mode=true       # cluster stops monitoring/acting; services keep running
$ pcs property set maintenance-mode=false

# Move the web group off node1 for a reboot (adds a temporary +INF location rule):
$ pcs resource move web node3
$ pcs resource clear web                        # remove the temporary constraint afterwards

# Ban a resource from a node entirely:
$ pcs resource ban pgsqld-clone node3

# Manually promote/relocate the DB primary (controlled switchover):
$ pcs resource move pgsqld-clone --promoted node3
```

---

## 6. Verification and failure diagnosis

### 6.1 The verification ladder — cheapest checks first

```console
# 1) Does the configuration even validate against the schema?
$ crm_verify -L -V
$   # (silent + exit 0 means valid; errors print with -V)

# 2) What WOULD the scheduler do right now? (dry run, no changes)
$ crm_simulate -sL
Current cluster status:
  * Online: [ node1 node2 node3 ]
  ...
Allocation scores:
native_color: pgsqld:0 allocation score on node1: 1001
native_color: pgsqld:0 allocation score on node2: -INFINITY
promotion_color: pgsqld:0 promotion score on node1: 1001
...
Transition Summary:
  * (no actions required — cluster is in the desired state)

# 3) Any resource failures accumulated?
$ pcs status --full | sed -n '/Migration Summary/,$p'
Migration Summary:
  * Node: node2:
    * web-srv: migration-threshold=3 fail-count=1 last-failure='Wed Aug 12 13:58:02 2026'
```

`crm_simulate` is the killer diagnostic: point it at a *saved* CIB and inject events to answer "if node2 dies, where does everything land?" **before** it happens:

```console
$ pcs cluster cib > /tmp/cib.xml
$ crm_simulate -x /tmp/cib.xml -S --node-down node2
...
Transition Summary:
  * Fence (reboot) node2 'peer is no longer part of the cluster'
  * Promote    pgsqld:0   ( Unpromoted -> Promoted node1 )
  * Move       pg-vip     ( node2 -> node1 )
  * Start      fence-node2 ( node3 )
```

### 6.2 Failure playbook

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| Resource stuck `Stopped`, `stonith-enabled=true`, but nothing runs | **No working fence device** — Pacemaker refuses to start resources it can't safely fail over | `pcs stonith status`; `journalctl -u pacemaker \| grep -i stonith` shows `Requesting fencing … no device` | Configure a real STONITH device. **Do not** just set `stonith-enabled=false` in production. |
| One node repeatedly fenced (fence loop) | Token timeout too low for a busy/virtual node; or NTP skew; or a flaky ring | `corosync-cfgtool -s` (link FAULTY), `journalctl` for `Token has not been received` | Raise `token`; add/fix ring1; enforce chrony/NTP; check NIC offload/pause frames. |
| Both nodes fence each other (2-node) | Simultaneous fence race, no delay stagger | Both power off at once | Add `pcmk_delay_base`/`pcmk_delay_max` asymmetrically; better: add a QDevice. |
| `FAILED` resource won't recover | Bad RA config → returns `OCF_ERR_CONFIGURED`(6)/`OCF_ERR_INSTALLED`(5) | `pcs resource debug-start <rsc> --full` runs the RA verbatim and prints its stderr | Fix the parameter/package, then clear the failure (below). |
| Cluster won't act after a fault | Lost quorum, `no-quorum-policy=stop` | `corosync-quorumtool -s` → `Quorate: No` | Restore the missing node/link; or add a QDevice; understand the policy is *protecting* you. |
| `pcs` commands time out | `pcsd` down or nodes not authed | `systemctl status pcsd`; `pcs host auth …` | Start pcsd; re-auth. |

Clearing a resolved failure (Pacemaker keeps a *failcount* that, at `migration-threshold`, pins the resource off that node forever until reset):

```console
$ pcs resource cleanup web-srv         # deletes failcount + re-probes; lets it run there again
Cleaned up web-srv on node2
Waiting for 1 reply from the controller ... got reply (done)

# Inspect / reset a specific failcount manually:
$ crm_failcount --query -r web-srv -N node2
scope=status  name=fail-count-web-srv  value=1
$ crm_resource --refresh --resource web-srv    # force re-probe of real state across the cluster
```

### 6.3 Recovering from split-brain / a stale rejoin

After a partition heals, the CIB with the **higher `admin_epoch/epoch`** wins and the minority's changes are dropped — this is by design. If a formerly-partitioned node rejoins with a divergent *data* state (e.g. an old PostgreSQL primary), the cluster's job was to have **fenced** it before promoting the survivor; on reboot it comes back as a clean `Unpromoted` replica (PAF re-clones/pg_rewinds it per your `recovery_template`). Operationally:

```console
# Confirm the survivor is authoritative and the rejoined node is subordinate:
$ pcs status | grep -E 'Promoted|Unpromoted'
    * pgsqld  (ocf:heartbeat:pgsqlms):  Promoted node1
    * pgsqld  (ocf:heartbeat:pgsqlms):  Unpromoted node2   # rejoined, now a replica

# If a fence was requested but never confirmed, the DC BLOCKS all resource actions
# ("Requesting fencing … " with no "was terminated" follow-up). Never bypass this by
# faking the fence unless you have physically confirmed the node is off:
$ stonith_admin --confirm node2        # DANGER: asserts "I verified node2 is dead" by hand
```

The rule this enforces, and the one to leave the exam with: **an unconfirmed fence must halt failover, not proceed with it.** A cluster that keeps availability while risking a double-write has failed at its only real job.

---

## 7. References

- LPI — Exam 306 Objectives (306-300, v3.0): https://www.lpi.org/our-certifications/exam-306-objectives/
- Pacemaker documentation portal (ClusterLabs): https://clusterlabs.org/pacemaker/doc/
- *Pacemaker Explained* (configuration reference): https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Explained/html/
- *Pacemaker Administration*: https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Administration/html/
- Corosync project and `corosync.conf(5)` / `votequorum(5)` man pages: https://corosync.github.io/corosync/
- Kronosnet (knet) transport: https://kronosnet.org/
- ClusterLabs QDevice / `corosync-qnetd`: https://clusterlabs.org/pacemaker/doc/2.1/Pacemaker_Administration/html/quorum.html
- SBD (Storage-Based Death) fencing: https://github.com/ClusterLabs/sbd
- OCF Resource Agents (`resource-agents`, `heartbeat` provider): https://github.com/ClusterLabs/resource-agents
- Fence agents: https://github.com/ClusterLabs/fence-agents
- `pcs` / `pcsd` reference: https://clusterlabs.org/pcs/ · man page: https://manpages.org/pcs/8
- `crmsh` (crm shell) documentation: https://crmsh.github.io/
- PAF — PostgreSQL Automatic Failover (`pgsqlms` OCF agent): https://clusterlabs.github.io/PAF/
- Red Hat Enterprise Linux 9 — *Configuring and managing high availability clusters*: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index
- SUSE Linux Enterprise High Availability — Administration Guide: https://documentation.suse.com/sle-ha/