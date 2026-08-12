# LPIC-3 306 · Topic 362.2 — Cluster Storage Access

> **Exam 306-300 (v3.0) · Objective weight: 5**
> Candidates must be able to connect a Linux node to remote block storage and manage redundant access to it. Scope: SAN concepts, Fibre Channel / FCoE, iSCSI targets and initiators (LIO/targetcli, open-iscsi/iscsiadm), and Device-Mapper Multipath I/O (DM-MPIO). This is *block-level* shared storage — the substrate a cluster file system (GFS2/OCFS2, objective 362.3) or a Pacemaker-managed service is later stacked on top of.

---

## 1. The production problem: why a cluster needs remote block storage

A high-availability cluster exists to move a service from a failed node to a healthy one. That only works if the *state* the service owns — a PostgreSQL data directory, a mail spool, a VM image — is reachable from **every** node that might run it. If the data lives on a local disk (`/dev/sda`), a node failure takes the data with it, and failover has nothing to fail over to.

There are two architectural answers, and 362.2 is the foundation of the second:

| Model | State location | Consistency responsibility | Objective |
|---|---|---|---|
| **Shared-nothing (replicated)** | Each node keeps its own copy; a replication layer keeps them in sync | Replication engine (DRBD, database streaming) | 362.1 (DRBD) |
| **Shared-disk (shared storage)** | One block device, physically external, presented to N nodes | The nodes cooperate via a cluster FS + DLM, and fencing enforces exclusivity | **362.2 + 362.3** |

In the shared-disk model, the "disk" is not local. It lives in a **SAN (Storage Area Network)** — an array (NetApp, Dell/EMC, Pure, or a Linux box running LIO) that exports **LUNs (Logical Unit Numbers)**: block devices addressed over a storage protocol. A node that logs into the SAN sees the LUN as an ordinary SCSI disk (`/dev/sdb`) even though the platters (or NAND) are meters or kilometers away.

Two hard production requirements fall out of this, and they define the whole objective:

1. **The transport must not be a single point of failure.** One cable, one switch, one HBA port, one NIC — any of them can fail. If the node reaches the LUN through exactly one path, that path *is* a SPOF, and you have merely relocated the availability problem from the disk to the wire. The answer is **multipath**: present the same LUN over ≥2 independent physical paths and let `device-mapper` fuse them into one logical device that survives the loss of any single path. This is why DM-MPIO is inseparable from cluster storage.

2. **Concurrent writers must be arbitrated.** A raw LUN presented to two nodes offers *zero* protection against both mounting `ext4` and corrupting each other in seconds. Block storage guarantees delivery of blocks, not coherence of a filesystem. Coherence is enforced above (cluster FS + DLM, 362.3) and exclusivity is enforced by **fencing** — frequently *storage* fencing via SCSI-3 Persistent Reservations (`fence_scsi`), covered in §5.6, which is where 362.2 and 361.2 meet.

```
   ┌───────── node1 ─────────┐        ┌───────── node2 ─────────┐
   │  service (Pacemaker)    │        │  service (Pacemaker)    │
   │  /dev/mapper/mpatha     │        │  /dev/mapper/mpatha     │
   │   ▲            ▲        │        │   ▲            ▲        │
   │  HBA0        HBA1       │        │  HBA0        HBA1       │
   └───┼────────────┼────────┘        └───┼────────────┼────────┘
       │            │                     │            │
   ┌───┴──── fabric A ───┐            ┌───┴──── fabric B ───┐   (two independent
   │  switch A           │            │  switch B           │    switches / VLANs)
   └───────┬─────────────┘            └───────┬─────────────┘
           │                                  │
       ┌───┴──────────────── SAN array (LUN 0) ─────────────┴───┐
       │        one LUN, four paths (2 nodes × 2 fabrics)       │
       └────────────────────────────────────────────────────────┘
```

The rest of this objective is how to build, log into, harden, multipath, and diagnose that picture on Linux.

---

## 2. Transport comparison: FC, FCoE, iSCSI, NVMe-oF

The exam names FC, FCoE and iSCSI explicitly and expects you to reason about the trade-offs. NVMe-oF is not on the 306-300 objective list but is included here because it is what production is migrating to and it sharpens the comparison.

| Property | **Fibre Channel (FC)** | **FCoE** | **iSCSI** | *NVMe/TCP (context)* |
|---|---|---|---|---|
| Encapsulation | SCSI over FC frames | FC frames over lossless Ethernet | SCSI over TCP/IP | NVMe over TCP/IP |
| Physical layer | Dedicated FC HBAs + FC switches | 10GbE+ NICs (CNA) + DCB switches | Any Ethernet NIC | Any Ethernet NIC |
| Requires lossless fabric? | Yes (buffer credits, native) | **Yes — DCB/PFC mandatory** | No (TCP retransmits) | No |
| Routable across subnets | No (Layer 2 fabric) | No | **Yes** | Yes |
| Typical latency | Lowest | Low | Higher (TCP stack) | Low |
| Node address | WWPN (`50:01:...`) | WWPN over MAC | IQN (`iqn.2026-08...`) | NQN |
| CapEx | High (separate SAN fabric) | Medium | **Low (reuse LAN kit)** | Low |
| Operational skill | Specialist (zoning) | Specialist (DCB tuning) | **Generalist (TCP/IP)** | Generalist |
| Linux target stack | — (array-side) | — | **LIO / targetcli** | LIO / SPDK |
| Linux initiator | HBA driver (`lpfc`, `qla2xxx`) | `fcoe`/`libfc` + `fcoeadm` | **open-iscsi / `iscsiadm`** | `nvme-cli` |
| Status in RHEL 9 | Supported | **Deprecated / removed** | Fully supported | Supported, rising |

**Reading the table for the exam and for production:**

- **iSCSI is the default choice for a self-built Linux SAN.** It runs on the LAN you already have, it is routable, and both ends are pure Linux (LIO target, open-iscsi initiator). Its cost is CPU/latency from the TCP/IP stack — mitigated with jumbo frames, a dedicated storage VLAN, and iSCSI offload NICs.
- **FC is the incumbent enterprise fabric.** Lowest latency, hardware-isolated from the LAN, but expensive and operated by storage specialists. On Linux the initiator side is mostly "the HBA driver presents `/dev/sdX`"; there is no Linux *target* to configure for FC in this objective.
- **FCoE was the convergence bet** — carry FC frames on Ethernet to collapse two fabrics into one. It mandates a **lossless** Ethernet built on **DCB (Data Center Bridging)**: PFC (Priority Flow Control, 802.1Qbb), ETS, DCBX. It never displaced native FC or iSCSI and is **deprecated/removed in RHEL 8/9**. Know the terms (`fcoeadm`, `lldpad`, `dcbtool`, DCB, CNA) for the exam; do not deploy it new.

### iSCSI target implementations on Linux

| Target stack | Kernel path | Config tool | State file | Status |
|---|---|---|---|---|
| **LIO (target_core_mod)** | In-kernel, since 2.6.38 | **`targetcli`** (rtslib) | `/etc/target/saveconfig.json` | **Default & standard** (RHEL, SUSE, Debian) |
| **SCST** | Out-of-tree kernel module | `scstadmin` | `/etc/scst.conf` | High-performance, niche |
| **tgt (scsi-target-utils)** | User-space (`tgtd`) | `tgtadm` / `/etc/tgt/targets.conf` | `targets.conf` | Legacy, being retired |

**LIO is the canonical, exam-relevant target** — it is the upstream in-kernel SCSI target and `targetcli` is its shell. Recognize `tgtadm`/`targets.conf` as the older user-space alternative, but build with `targetcli`.

---

## 3. Complete configuration & infrastructure

### 3.1 Reference topology

Two initiator nodes reach one 50 GiB LUN exported by a LIO target, over **two** portal IPs for redundancy.

```
target host  san0     : 192.168.178.20 (fabric A), 192.168.178.21 (fabric B)
                        backstore = /dev/sdb (50 GiB), IQN target below
initiator    node1    : 192.168.178.31 / .41
initiator    node2    : 192.168.178.32 / .42

Target IQN    : iqn.2026-08.club.cybercirujas:san0.lun0
node1 IQN     : iqn.2026-08.club.cybercirujas:node1
node2 IQN     : iqn.2026-08.club.cybercirujas:node2
CHAP          : mutual (bidirectional)
```

### 3.2 Target side — LIO via `targetcli` (complete build)

Packages (Debian/Ubuntu `targetcli-fb`, RHEL/Fedora/SUSE `targetcli`):

```console
root@san0:~# apt-get install -y targetcli-fb        # Debian/Ubuntu
root@san0:~# dnf install -y targetcli               # RHEL/Fedora/SUSE
root@san0:~# systemctl enable --now target.service
```

Interactive build. Every `create` is applied to the live kernel immediately; `saveconfig` persists it.

```console
root@san0:~# targetcli
targetcli shell version 2.1.58
Copyright 2011-2013 by Datera, Inc and others.
For help on commands, type 'help'.

/> cd /backstores/block
/backstores/block> create name=lun0 dev=/dev/sdb
Created block storage object lun0 using /dev/sdb.

/backstores/block> cd /iscsi
/iscsi> create iqn.2026-08.club.cybercirujas:san0.lun0
Created target iqn.2026-08.club.cybercirujas:san0.lun0.
Created TPG 1.
Global pref auto_add_default_portal=true
Created default portal listening on all IPs (0.0.0.0), port 3260.
```

Because the default portal binds `0.0.0.0:3260`, delete it and bind the two explicit fabric IPs so each maps to a discrete path:

```console
/iscsi> cd iqn.2026-08.club.cybercirujas:san0.lun0/tpg1/portals
/iscsi/iqn.20...lun0/tpg1/portals> delete 0.0.0.0 3260
Deleted network portal 0.0.0.0:3260
/iscsi/iqn.20...lun0/tpg1/portals> create 192.168.178.20
Created network portal 192.168.178.20:3260.
/iscsi/iqn.20...lun0/tpg1/portals> create 192.168.178.21
Created network portal 192.168.178.21:3260.

/iscsi/iqn.20...lun0/tpg1/portals> cd ../luns
/iscsi/iqn.20...lun0/tpg1/luns> create /backstores/block/lun0
Created LUN 0.

/iscsi/iqn.20...lun0/tpg1/luns> cd ../acls
/iscsi/iqn.20...lun0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node1
Created Node ACL for iqn.2026-08.club.cybercirujas:node1
Created mapped LUN 0.
/iscsi/iqn.20...lun0/tpg1/acls> create iqn.2026-08.club.cybercirujas:node2
Created Node ACL for iqn.2026-08.club.cybercirujas:node2
Created mapped LUN 0.
```

Enforce **mutual CHAP** on the TPG, then per-ACL credentials (target authenticates initiator via `userid/password`; initiator authenticates target via `mutual_userid/mutual_password`):

```console
/iscsi/iqn.20...lun0/tpg1/acls> cd ..
/iscsi/iqn.20...lun0/tpg1> set attribute authentication=1 generate_node_acls=0 demo_mode_write_protect=1
Parameter authentication is now '1'.
Parameter generate_node_acls is now '0'.
Parameter demo_mode_write_protect is now '1'.

/iscsi/iqn.20...lun0/tpg1> cd acls/iqn.2026-08.club.cybercirujas:node1
/iscsi/iqn.20...:node1> set auth userid=node1 password=S3cret-node1-in
Parameter userid is now 'node1'.
Parameter password is now 'S3cret-node1-in'.
/iscsi/iqn.20...:node1> set auth mutual_userid=san0 mutual_password=S3cret-target-out
Parameter mutual_userid is now 'san0'.
Parameter mutual_password is now 'S3cret-target-out'.
```

Verify the tree, then persist:

```console
/> ls
o- / ......................................................................... [...]
  o- backstores .............................................................. [...]
  | o- block .................................................. [Storage Objects: 1]
  | | o- lun0 ................................ [/dev/sdb (50.0GiB) write-thru activated]
  | |   o- alua ................................................... [ALUA Groups: 1]
  | |     o- default_tg_pt_gp ....................... [ALUA state: Active/optimized]
  | o- fileio ................................................. [Storage Objects: 0]
  | o- pscsi .................................................. [Storage Objects: 0]
  | o- ramdisk ................................................ [Storage Objects: 0]
  o- iscsi ............................................................ [Targets: 1]
  | o- iqn.2026-08.club.cybercirujas:san0.lun0 ......................... [TPGs: 1]
  |   o- tpg1 ............................................... [gen-acls disabled, auth]
  |     o- acls .......................................................... [ACLs: 2]
  |     | o- iqn.2026-08.club.cybercirujas:node1 ................. [Mapped LUNs: 1]
  |     | | o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     | o- iqn.2026-08.club.cybercirujas:node2 ................. [Mapped LUNs: 1]
  |     |   o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     o- luns .......................................................... [LUNs: 1]
  |     | o- lun0 .......... [block/lun0 (/dev/sdb) (default_tg_pt_gp)]
  |     o- portals .................................................... [Portals: 2]
  |       o- 192.168.178.20:3260 ............................................ [OK]
  |       o- 192.168.178.21:3260 ............................................ [OK]
  o- loopback ......................................................... [Targets: 0]

/> saveconfig
Configuration saved to /etc/target/saveconfig.json
/> exit
Global pref auto_save_on_exit=true
```

**`/etc/target/saveconfig.json` (persisted state — never hand-edited; `targetcli` owns it):**

```json
{
  "storage_objects": [
    {
      "name": "lun0",
      "plugin": "block",
      "dev": "/dev/sdb",
      "write_back": false,
      "attributes": { "emulate_3pc": 1, "emulate_tpu": 1 },
      "wwn": "b7f4d2c1-9a3e-4f52-8c0d-2e1a6b7c9d84"
    }
  ],
  "targets": [
    {
      "wwn": "iqn.2026-08.club.cybercirujas:san0.lun0",
      "fabric": "iscsi",
      "tpgs": [
        {
          "tag": 1,
          "enable": true,
          "attributes": { "authentication": 1, "generate_node_acls": 0,
                          "demo_mode_write_protect": 1 },
          "node_acls": [
            {
              "node_wwn": "iqn.2026-08.club.cybercirujas:node1",
              "mapped_luns": [ { "index": 0, "tpg_lun": 0, "write_protect": false } ],
              "chap_userid": "node1", "chap_password": "S3cret-node1-in",
              "chap_mutual_userid": "san0", "chap_mutual_password": "S3cret-target-out"
            },
            {
              "node_wwn": "iqn.2026-08.club.cybercirujas:node2",
              "mapped_luns": [ { "index": 0, "tpg_lun": 0, "write_protect": false } ],
              "chap_userid": "node2", "chap_password": "S3cret-node2-in",
              "chap_mutual_userid": "san0", "chap_mutual_password": "S3cret-target-out"
            }
          ],
          "luns": [ { "index": 0, "storage_object": "/backstores/block/lun0" } ],
          "portals": [
            { "ip_address": "192.168.178.20", "port": 3260 },
            { "ip_address": "192.168.178.21", "port": 3260 }
          ]
        }
      ]
    }
  ]
}
```

Open the firewall (target listens on TCP/3260):

```console
root@san0:~# firewall-cmd --permanent --add-service=iscsi-target && firewall-cmd --reload   # RHEL/SUSE
root@san0:~# nft add rule inet filter input tcp dport 3260 accept                            # nftables
```

### 3.3 Initiator side — open-iscsi (`iscsiadm`)

`/etc/iscsi/initiatorname.iscsi` — the node's identity, must match the target ACL exactly:

```ini
InitiatorName=iqn.2026-08.club.cybercirujas:node1
```

`/etc/iscsi/iscsid.conf` — the essential production stanza (mutual CHAP + failover-friendly timeouts):

```ini
# --- Startup: let multipathd own login, not the config ---
node.startup = automatic
node.leading_login = No

# --- Authentication: mutual (bidirectional) CHAP ---
node.session.auth.authmethod = CHAP
node.session.auth.username   = node1
node.session.auth.password   = S3cret-node1-in
node.session.auth.username_in = san0
node.session.auth.password_in = S3cret-target-out

# Same CHAP for the discovery phase (sendtargets)
discovery.sendtargets.auth.authmethod = CHAP
discovery.sendtargets.auth.username   = node1
discovery.sendtargets.auth.password   = S3cret-node1-in
discovery.sendtargets.auth.username_in = san0
discovery.sendtargets.auth.password_in = S3cret-target-out

# --- Timeouts: with multipath, fail the PATH fast so DM reroutes ---
# Default is 120s; that stalls I/O for 2 min before multipath sees a dead path.
node.session.timeo.replacement_timeout = 5
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout  = 5

# Queue depth
node.session.queue_depth = 32
```

> **Production rule:** on a *single-path* iSCSI root or non-multipathed volume, keep `replacement_timeout = 120` (ride out a brief network blip). On a *multipathed* LUN, set it to **5** and let `no_path_retry` in `multipath.conf` own the long queueing decision. Getting this wrong is the #1 cause of "the whole box hangs for two minutes when one NIC flaps."

Enable the daemons:

```console
root@node1:~# systemctl enable --now iscsid.service iscsi.service
```

### 3.4 Multipath — `/etc/multipath.conf` (complete, annotated)

```conf
defaults {
    user_friendly_names     yes          # name devices mpatha, mpathb... via /etc/multipath/bindings
    find_multipaths         yes          # only multipath devices with >1 path or an explicit wwid
    path_grouping_policy    group_by_prio # group paths by ALUA priority (active/optimized vs non-opt)
    path_selector           "service-time 0"  # send I/O to the path with lowest estimated service time
    path_checker            tur          # TEST UNIT READY probe; directio for arrays that mishandle TUR
    prio                    alua         # SCSI ALUA reports which paths are optimal
    failback                followover   # fail back only if the whole preferred group is healthy again
    no_path_retry           18           # queue I/O for 18 * polling_interval before erroring
    polling_interval        5            # seconds between path checks  (18 * 5 = 90s grace)
    max_fds                 8192
    dev_loss_tmo            60
    fast_io_fail_tmo        5
}

blacklist {
    devnode "^(ram|zram|raw|loop|fd|md|dm-|sr|scd|st|nvme)[0-9]*"
    devnode "^sd[a]$"                    # local root disk /dev/sda — never multipath it
    wwid    ".*"                         # default-deny; explicitly allow real SAN LUNs below
}

blacklist_exceptions {
    wwid "36001405b7f4d2c19a3e4f528c0d2e1a6"   # our LUN0 (from /lib/udev/scsi_id -g -u /dev/sdX)
}

multipaths {
    multipath {
        wwid    "36001405b7f4d2c19a3e4f528c0d2e1a6"
        alias   mpath-lun0               # stable app-facing name: /dev/mapper/mpath-lun0
    }
}

devices {
    device {
        vendor              "LIO-ORG"
        product             ".*"
        path_grouping_policy group_by_prio
        prio                alua
        path_checker        tur
        hardware_handler    "1 alua"
        failback            followover
        no_path_retry       18
    }
}
```

Key `multipath.conf` decisions and their trade-offs:

| Parameter | Options | Trade-off |
|---|---|---|
| `path_grouping_policy` | `failover` / `multibus` / `group_by_prio` / `group_by_serial` | `failover` = 1 active path (safe, no bandwidth aggregation). `multibus` = all paths active (max throughput, requires true active/active array). `group_by_prio` = ALUA-aware, the correct default for modern arrays. |
| `path_selector` | `round-robin 0` / `queue-length 0` / `service-time 0` | RR is naïve (equal split ignores latency). `queue-length`/`service-time` adapt to real path speed — prefer them on heterogeneous paths. |
| `no_path_retry` | `fail` / `queue` / *N* | `fail` errors instantly (good for clustered FS that wants fast fencing). `queue` blocks forever (risks unkillable D-state processes on total outage). *N* = queue for N·`polling_interval`s then fail — the safe middle ground. |
| `failback` | `manual` / `immediate` / *N* / `followover` | `immediate` can cause path flapping storms. `followover` fails back only when the preferred path group is fully restored — safest for ALUA. |
| `path_checker` | `tur` / `directio` / `readsector0` / array-specific | `tur` is cheap and universal; some arrays need `directio` or a vendor checker (`rdac`, `emc_clariion`). |

Enable multipath:

```console
root@node1:~# mpathconf --enable --with_multipathd y      # RHEL helper; or edit conf directly
root@node1:~# systemctl enable --now multipathd.service
```

---

## 4. CLI workflow with real terminal output

### 4.1 Discovery and login (initiator)

```console
root@node1:~# iscsiadm -m discovery -t sendtargets -p 192.168.178.20:3260
192.168.178.20:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0
192.168.178.21:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0
```

`sendtargets` (`-t st`) returned **both** portals — this is what makes multipath possible from a single discovery. Log in to the discovered node records (both portals):

```console
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 --login
Logging in to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.20,3260]
Logging in to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.21,3260]
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.20,3260] successful.
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san0.lun0, portal: 192.168.178.21,3260] successful.
```

Two sessions, one per portal:

```console
root@node1:~# iscsiadm -m session
tcp: [1] 192.168.178.20:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
tcp: [2] 192.168.178.21:3260,1 iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
```

The kernel now shows the *same* LUN twice — `sdb` via session 1, `sdc` via session 2:

```console
root@node1:~# lsscsi
[7:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdb
[8:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdc

root@node1:~# lsblk -o NAME,SIZE,TYPE,VENDOR,WWN
NAME             SIZE TYPE VENDOR   WWN
sda               40G disk ATA
└─sda1            40G part
sdb               50G disk LIO-ORG  0x6001405b7f4d2c19a3e4f528c0d2e1a6
sdc               50G disk LIO-ORG  0x6001405b7f4d2c19a3e4f528c0d2e1a6
```

Identical WWN on `sdb` and `sdc` — proof they are two paths to one LUN, which is exactly what multipath keys on.

### 4.2 The WWID — how multipath identifies "the same disk"

```console
root@node1:~# /lib/udev/scsi_id -g -u -d /dev/sdb
36001405b7f4d2c19a3e4f528c0d2e1a6
root@node1:~# /lib/udev/scsi_id -g -u -d /dev/sdc
36001405b7f4d2c19a3e4f528c0d2e1a6
```

The leading `3` is the NAA designator type; the rest is the LUN's device identifier from VPD page 0x83. Matching WWIDs → multipathd coalesces the paths.

### 4.3 Verify the multipath device

```console
root@node1:~# multipath -ll
mpath-lun0 (36001405b7f4d2c19a3e4f528c0d2e1a6) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 7:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 8:0:0:0 sdc 8:32 active ready running

root@node1:~# ls -l /dev/mapper/
total 0
crw-------. 1 root root 10, 236 Aug 12 09:14 control
lrwxrwxrwx. 1 root root       7 Aug 12 09:41 mpath-lun0 -> ../dm-3
```

Reading `multipath -ll`:
- `prio=50 status=active` vs `prio=10 status=enabled` → ALUA reports the first group **Active/Optimized** and the second **Active/Non-optimized**; DM sends I/O to the prio-50 group and holds the other in reserve.
- `hwhandler='1 alua'` → the kernel ALUA hardware handler is loaded.
- `features='1 queue_if_no_path'` → I/O queues rather than errors when *all* paths die (driven by `no_path_retry`).

Partition the multipath device and expose partitions with `kpartx`:

```console
root@node1:~# parted -s /dev/mapper/mpath-lun0 mklabel gpt mkpart primary 0% 100%
root@node1:~# kpartx -a -v /dev/mapper/mpath-lun0
add map mpath-lun0-part1 (253:4): 0 104855552 linear 253:3 2048
root@node1:~# ls /dev/mapper/mpath-lun0*
/dev/mapper/mpath-lun0  /dev/mapper/mpath-lun0-part1
```

You now format `/dev/mapper/mpath-lun0-part1` (with a *cluster* FS like GFS2 for shared write, or ext4/xfs only if exactly one node ever mounts it at a time, enforced by the cluster).

### 4.4 Making login persistent and clean

```console
# Bring these node records up automatically at boot (already node.startup=automatic in iscsid.conf):
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 -o update -n node.startup -v automatic

# Graceful teardown (flush multipath first, then logout, then delete records):
root@node1:~# multipath -f mpath-lun0
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 --logout
Logging out of session [sid: 1, target: iqn.2026-08...san0.lun0, portal: 192.168.178.20,3260]
Logging out of session [sid: 2, target: iqn.2026-08...san0.lun0, portal: 192.168.178.21,3260]
Logout of [sid: 1 ...] successful.
Logout of [sid: 2 ...] successful.
root@node1:~# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san0.lun0 -o delete
```

### 4.5 Fibre Channel initiator inspection (no config, just discovery)

For FC the fabric/zoning is array- and switch-side; the Linux node just reads its HBA:

```console
root@node1:~# systool -c fc_host -v | egrep 'Class Device|port_name|port_state|speed'
  Class Device = "host7"
    port_name           = "0x50014380023d1a71"
    port_state          = "Online"
    speed               = "16 Gbit"

root@node1:~# cat /sys/class/fc_host/host7/port_name
0x50014380023d1a71
```

Rescan the FC/SCSI bus after the storage team maps a new LUN (no reboot needed):

```console
root@node1:~# rescan-scsi-bus.sh -a         # from sg3_utils
# or, per host, the LIP/rescan wildcard:
root@node1:~# echo "- - -" > /sys/class/scsi_host/host7/scan
# rescan an existing device that grew:
root@node1:~# echo 1 > /sys/block/sdb/device/rescan
```

---

## 5. Verification and failure diagnosis

### 5.1 The verification ladder (each rung proves more than the last)

| Question | Command | Healthy signal |
|---|---|---|
| Is the target reachable on the wire? | `nc -vz 192.168.178.20 3260` | `Connection to ... succeeded!` |
| Does discovery return the portals? | `iscsiadm -m discovery -t st -p <ip>` | one line per portal |
| Did CHAP succeed and sessions form? | `iscsiadm -m session` | one `tcp: [n] ...` per portal |
| Did the kernel enumerate the LUN? | `lsscsi` / `lsblk` | `LIO-ORG lun0` on ≥2 `sdX` |
| Do the paths share a WWID? | `scsi_id -g -u -d /dev/sdX` | identical string on all paths |
| Did DM coalesce them? | `multipath -ll` | one map, all paths `active ready running` |
| Does failover actually work? | pull a path, watch `multipathd show paths` | failed path → `failed faulty`, I/O continues |

### 5.2 `multipathd` interactive shell — the live diagnostic console

```console
root@node1:~# multipathd -k
multipathd> show paths
hcil     dev dev_t  pri dm_st  chk_st  dev_st  next_check
7:0:0:0  sdb 8:16   50  active  ready   running X........ 4/20
8:0:0:0  sdc 8:32   10  active  ready   running XX....... 3/20

multipathd> show maps status
name        failback queueing paths  dm-st  write_prot
mpath-lun0  -        -        2       active rw

multipathd> show config          # dump the *effective* merged config (defaults + your overrides)
multipathd> reconfigure          # re-read /etc/multipath.conf without a restart
multipathd> exit
```

`show config` is the single most useful command when behavior doesn't match your file: it prints what multipathd *actually* computed after merging built-in device defaults with your `devices{}` block — vendor built-ins silently override you otherwise.

### 5.3 Path-failure drill (prove redundancy before you trust it)

```console
# Snapshot: two live paths
root@node1:~# multipath -ll | grep -E 'sd[bc]'
| `- 7:0:0:0 sdb 8:16 active ready running
  `- 8:0:0:0 sdc 8:32 active ready running

# Simulate loss of fabric B by killing that session's connectivity
root@node1:~# iptables -A OUTPUT -d 192.168.178.21 -j DROP

# Within ~replacement_timeout the path drops; I/O keeps flowing on fabric A:
root@node1:~# multipath -ll
mpath-lun0 (36001405b7f4d2c19a3e4f528c0d2e1a6) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 7:0:0:0 sdb 8:16 active ready  running
`-+- policy='service-time 0' prio=0  status=enabled
  `- 8:0:0:0 sdc 8:32 failed faulty  running

root@node1:~# dmesg -T | tail -3
[Wed Aug 12 09:52:11 2026] connection2:0: detected conn error (1020)
[Wed Aug 12 09:52:16 2026] sd 8:0:0:0: rejecting I/O to offline device
[Wed Aug 12 09:52:16 2026] device-mapper: multipath: Failing path 8:32.

# Restore and confirm followover failback
root@node1:~# iptables -D OUTPUT -d 192.168.178.21 -j DROP
root@node1:~# multipathd -k'show paths' | grep sdc
8:0:0:0  sdc 8:32   10  active  ready   running X........ 1/20
```

If I/O *stalled* instead of rerouting, your `node.session.timeo.replacement_timeout` is still at the 120 default (§3.3) — the path stayed "up" in the kernel far too long. This drill is where that misconfiguration surfaces.

### 5.4 Diagnosing the common failures

| Symptom | Root cause | Fix |
|---|---|---|
| `iscsiadm ... discovery` → `Login authentication failed` | CHAP mismatch or ACL missing the initiator IQN | Confirm `initiatorname.iscsi` matches the target ACL; re-check `node.session.auth.*` both directions |
| Discovery works, login → `iscsid: Connection ... failed (503)` | Target ACL has no `mapped_lun`, or `generate_node_acls=0` with no ACL | Add the initiator ACL + mapped LUN in `targetcli` |
| `multipath -ll` shows only **one** path | Second session never formed, or WWIDs differ | `iscsiadm -m session`; if two sessions but one path, compare `scsi_id`; check `find_multipaths`/blacklist |
| LUN not multipathed at all | Device caught by `blacklist { wwid ".*" }` with no exception | Add its WWID to `blacklist_exceptions` |
| Paths flap `active`↔`failed` repeatedly | `failback immediate` on an ALUA array; or a marginal NIC | Set `failback followover`; check `dmesg` for conn errors |
| Whole node hangs for 2 min on a NIC blip | `replacement_timeout=120` on a multipathed LUN | Set to `5`; move long-queue decision to `no_path_retry` |
| Processes stuck in `D` state after total outage | `no_path_retry queue` / `queue_if_no_path` never gives up | Use `no_path_retry <N>`; emergency: `multipathd -k'disablequeueing map <name>'` |
| New LUN not visible after array maps it | SCSI bus not rescanned | `rescan-scsi-bus.sh -a` or `echo "- - -" > /sys/class/scsi_host/hostX/scan` |
| `/dev/mapper/mpathaN` partitions missing | `kpartx` not run after partitioning | `kpartx -a -v /dev/mapper/<map>` |

Emergency unblock of a fully-queued map (when every path is gone and I/O is wedged):

```console
root@node1:~# multipathd -k'disablequeueing map mpath-lun0'
ok
# I/O now errors out cleanly instead of hanging forever, releasing D-state processes.
```

### 5.5 iSCSI session inspection at depth

```console
root@node1:~# iscsiadm -m session -P 3
Target: iqn.2026-08.club.cybercirujas:san0.lun0 (non-flash)
    Current Portal: 192.168.178.20:3260,1
    Persistent Portal: 192.168.178.20:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.2026-08.club.cybercirujas:node1
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        FirstBurstLength: 65536
        MaxBurstLength: 262144
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 7  State: running
        scsi7 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdb  State: running
```

`iSCSI Session State: LOGGED_IN` on **both** SIDs is the health bar. `MaxRecvDataSegmentLength`/`FirstBurstLength` are the negotiated PDU sizes — tune with jumbo frames + `iscsid.conf` for throughput.

### 5.6 Where storage meets fencing — SCSI-3 Persistent Reservations

In a shared-disk cluster, storage itself becomes the fencing mechanism. `fence_scsi` uses **SCSI-3 Persistent Reservations (PR)**: each node registers a key on the LUN; a node being fenced has its key *preempted*, after which the array rejects its writes — the node is cut off from the data even if it is still alive and confused (the split-brain scenario).

```console
# Every node registers its unique key (integrate with Pacemaker's fence_scsi agent):
root@node1:~# sg_persist --out --register --param-sark=0x0a1b1001 /dev/mapper/mpath-lun0
root@node1:~# sg_persist --out --reserve --param-rk=0x0a1b1001 \
                --prout-type=5 /dev/mapper/mpath-lun0     # type 5 = Write Exclusive-Registrants Only

# Read who holds the reservation and which keys are registered:
root@node1:~# sg_persist --in --read-reservation /dev/mapper/mpath-lun0
  LIO-ORG   lun0              4.0
  Peripheral device type: disk
  PR generation=0x2, Reservation follows:
    Key=0x0a1b1001
    scope: LU_SCOPE,  type: Write Exclusive, registrants only

# Fence node2 by preempting its key (this is what fence_scsi does under Pacemaker):
root@node1:~# sg_persist --out --preempt-abort --param-rk=0x0a1b1001 \
                --param-sark=0x0a1b1002 --prout-type=5 /dev/mapper/mpath-lun0
```

Requirement for this to work: the backstore must advertise PR support (LIO block backstores do). Verify `emulate_pr` is on and the LUN exposes PR VPD. This is the reason `fence_scsi` needs a *shared* LUN reachable by all nodes over multipath — which is exactly the infrastructure this objective builds.

---

## 6. References

- LPI — Exam 306 Objectives (306-300, v3.0), Topic 362.2 Cluster Storage Access: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux-IO Target (LIO) / `targetcli` documentation: <https://linux-iscsi.org/wiki/Targetcli>
- `targetcli-fb` (Datera fork used by most distros): <https://github.com/open-iscsi/targetcli-fb>
- Open-iSCSI project (initiator, `iscsiadm`, `iscsid`): <https://github.com/open-iscsi/open-iscsi> · <https://www.open-iscsi.com/>
- The Linux Kernel — SCSI target (LIO) documentation: <https://www.kernel.org/doc/html/latest/target/index.html>
- The Linux Kernel — Device Mapper multipath: <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-queue-length.html>
- multipath-tools upstream (multipathd, `multipath.conf`): <https://github.com/opensvc/multipath-tools>
- Red Hat — Configuring and Managing Storage Devices, *Using device mapper multipath*: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_storage_devices/configuring-device-mapper-multipath_configuring-and-managing-storage-devices>
- Red Hat — Getting started with iSCSI (target and initiator): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices>
- SUSE Linux Enterprise — Storage Administration Guide (iSCSI, Multipath I/O): <https://documentation.suse.com/sles/html/SLES-all/cha-multipath.html>
- RFC 7143 — iSCSI (Internet Small Computer System Interface) Protocol (Consolidated): <https://www.rfc-editor.org/rfc/rfc7143>
- RFC 7144 — iSCSI SCSI Features (SAM, task management): <https://www.rfc-editor.org/rfc/rfc7144>
- `sg3_utils` (`sg_persist`, `rescan-scsi-bus.sh`) — SCSI-3 Persistent Reservations: <https://sg.danny.cz/sg/sg3_utils.html>
- Pacemaker `fence_scsi` fencing agent (fence-agents): <https://github.com/ClusterLabs/fence-agents>
- Open-FCoE (`fcoeadm`, DCB — context/awareness): <https://github.com/openSUSE/open-fcoe>