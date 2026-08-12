# Topic 362.2 — Cluster Storage Access

> LPIC-3 306 (exam 306-300, v3.0) · Topic 362: High Availability Cluster Storage · **Weight: 5**
>
> Scope: connecting a Linux node to remote block storage. SAN transports (Fibre Channel, FCoE, InfiniBand, iSCSI), the Linux SCSI stack and its addressing, the LIO/`targetcli` target, the `open-iscsi` initiator, and Device Mapper Multipath (`multipathd`, `multipath.conf`, `kpartx`).

---

## 1. The architectural problem: shared block storage under a cluster

A high-availability cluster exists to survive the loss of a node. The moment a stateful service (a database, an NFS export, a mail spool) can run on more than one node, a single hard question appears: **where do its bytes live, and who is allowed to write them?**

There are two fundamentally different answers, and this objective is about the second one.

| Model | Data location | Access pattern | Filesystem | Examples |
|---|---|---|---|---|
| **Shared-nothing** | Each node has a private copy; the copy is replicated | One active writer, replica is passive | Ordinary (`ext4`, `xfs`) | DRBD (topic 362.1) |
| **Shared-disk** | One LUN, physically reachable by every node | Either single active mount (failover) or concurrent mount | Ordinary for failover; **cluster-aware** (GFS2/OCFS2, topic 362.3) for concurrent | SAN + multipath (**this topic**) |

In the shared-disk model the storage is a **block device presented over a network fabric** — a *SAN* (Storage Area Network), not a *NAS* (which serves a filesystem over NFS/SMB). The node sees `/dev/sdb` as if it were a local disk; it has no idea another node can see the very same blocks.

That last sentence is the whole danger. Block storage has no arbitration. If two nodes mount an `ext4` filesystem on the same LUN read-write at the same time, both caches diverge and the filesystem is destroyed within seconds — this is not a theoretical risk, it is the default outcome. Two rules follow, and they are why this objective sits *inside* the HA-cluster exam rather than in a generic storage exam:

1. **A non-cluster filesystem on shared storage must be mounted by exactly one node at a time.** Pacemaker guarantees this with resource constraints (the `Filesystem` resource is colocated with the service and ordered after it) **and** with *fencing/STONITH*. Fencing is not optional here: if a node hangs but still holds the SCSI reservation, the only safe recovery is to power it off before another node mounts the LUN. Multipath and fencing solve orthogonal problems — multipath keeps *one* node's access alive across a path failure; fencing keeps a *dead* node from corrupting the LUN.
2. **The transport itself must not become the single point of failure.** A SAN LUN reachable through one HBA, one cable, one switch, and one target port has simply moved the SPOF from the disk to the wire. The answer is **multipathing**: present the same LUN over ≥2 independent physical paths and let the kernel collapse them into one logical device with automatic failover and load balancing.

So the production problem this topic solves is: *deliver one logical, redundant, correctly-addressed block device to every cluster node, over a network, in a way that survives the loss of any single path component.* The pieces are the transport (§2–3), the target/initiator that speak it (§4), and multipath that makes it redundant (§5).

---

## 2. SAN transport technologies — trade-offs

All SAN transports carry the **SCSI command set** (or NVMe) over some fabric. They differ in the wire, the cost, the latency, and the operational skills required.

| Transport | Wire / encapsulation | Typical speed | Lossless fabric required? | Cost / complexity | Where it wins |
|---|---|---|---|---|---|
| **Fibre Channel (FC)** | Dedicated FC fabric, FCP (SCSI over FC) | 8/16/32/64 GFC | Yes (buffer credits, inherently lossless) | High: dedicated HBAs, FC switches, zoning | Large enterprise SANs, deterministic latency |
| **FCoE** | FC frames inside Ethernet (needs DCB/PFC) | 10–100 GbE | Yes — requires lossless DCB Ethernet | Medium-high, converged but fragile | Converged datacenter fabrics (declining) |
| **iSCSI** | SCSI inside TCP/IP | 1–100 GbE | No (TCP retransmits) | Low: any NIC, any switch | Commodity HA clusters, cloud, labs — **the exam's focus** |
| **iSER** | iSCSI over RDMA (RoCE/InfiniBand) | 25–200 Gb | Yes for RoCE | Medium | Low-latency iSCSI on RDMA fabrics |
| **InfiniBand (SRP)** | SCSI RDMA Protocol over IB | 40–400 Gb | Native lossless | High, specialised | HPC storage, ultra-low latency |
| **NVMe-oF** | NVMe over TCP/RDMA/FC | 25–400 Gb | Depends on fabric | Medium | Modern all-flash, high IOPS (beyond SCSI) |

**What the exam expects you to internalise:**

- **FC** gives a dedicated, lossless fabric and deterministic latency, at the price of a parallel network you must *zone* (the FC equivalent of ACLs) and a per-port cost measured in hundreds of dollars.
- **FCoE** tried to converge FC and Ethernet onto one wire but needs **DCB** (Data Center Bridging: PFC, ETS) to make Ethernet lossless — a single mis-configured priority flow-control class silently corrupts throughput. It is in decline.
- **iSCSI** carries SCSI over ordinary TCP/IP. TCP handles retransmission, so it tolerates lossy Ethernet, runs on any NIC, and needs no special fabric — which is exactly why it dominates open-source HA clusters and why LPI centres the objective on it. Its costs are latency (a TCP/IP stack in the path) and the need to isolate storage traffic (dedicated VLAN/subnet, jumbo frames, no routing through congested links).
- **InfiniBand** and **iSER**/**NVMe-oF/RDMA** move the data path into the NIC with RDMA, removing CPU copies and cutting latency to microseconds, at the cost of RDMA-capable hardware and a lossless fabric (native IB, or RoCE with PFC).

For the rest of this material the concrete transport is **iSCSI**, because it is the objective's core and because every concept (initiator, target, LUN, portal, multipath) maps one-to-one onto FC with only the addressing changing (WWN/WWPN instead of IQN, zoning instead of ACLs).

---

## 3. The Linux SCSI stack and how a remote LUN is addressed

Before any target or initiator, understand what the kernel does with a discovered device. Every SAN LUN — FC, iSCSI, SAS — enters through the **SCSI mid-layer** and becomes an `sd` block device.

```
  application / filesystem
        │
   block layer (bio, I/O scheduler)
        │
   /dev/sdX  ←  sd (SCSI disk) upper-level driver
        │
   SCSI mid-layer  (scsi_mod)   ── addresses devices as H:C:T:L
        │
   low-level driver (LLD):  qla2xxx (FC HBA) │ iscsi_tcp (software iSCSI) │ ...
        │
   transport (FC fabric │ TCP/IP │ IB)
```

**H:C:T:L addressing.** Each SCSI device has a four-tuple: **H**ost (the HBA / iSCSI host), **C**hannel (bus), **T**arget (the port on the array), **L**UN (the logical unit). You will read these constantly in `multipath -ll` output and `lsscsi`.

```console
# lsscsi -t
[0:0:0:0]    disk    sata:...                        /dev/sda
[6:0:0:0]    disk    iqn.2026-08.club.cybercirujas:san.array0,t,0x1  /dev/sdb
[7:0:0:0]    disk    iqn.2026-08.club.cybercirujas:san.array0,t,0x1  /dev/sdc
```

Here `/dev/sdb` and `/dev/sdc` are the **same LUN** seen through two different SCSI hosts (6 and 7) — i.e. two paths. The kernel does not know they are the same disk; that is multipath's job (§5), and the fact it can prove they are identical rests on the **WWID**.

**Stable names — never trust `/dev/sdX`.** The `sd` letters are assigned in *discovery order* and change across reboots and path flaps. Production always addresses storage through `udev`'s persistent symlinks:

```console
$ ls -l /dev/disk/by-id/ | grep -i lio
lrwxrwxrwx 1 root root  9 Aug 12 10:14 scsi-3600140572616e6461736574303100000 -> ../../sdb
lrwxrwxrwx 1 root root  9 Aug 12 10:14 scsi-3600140572616e6461736574303100000 -> ../../sdc   # same id, two paths
lrwxrwxrwx 1 root root  9 Aug 12 10:14 wwn-0x600140572616e6461736574303100000  -> ../../sdb

$ ls -l /dev/disk/by-path/ | grep iscsi
... ip-192.168.50.10:3260-iscsi-iqn.2026-08.club.cybercirujas:san.array0-lun-0 -> ../../sdb
... ip-192.168.51.10:3260-iscsi-iqn.2026-08.club.cybercirujas:san.array0-lun-0 -> ../../sdc
```

- **WWID / WWN (World Wide Identifier / Name):** a globally-unique identifier the storage device reports (SCSI `INQUIRY` VPD page 0x83). It is *the same across every path and every node*. This is the anchor multipath uses to prove "sdb on host 6 and sdc on host 7 are one LUN." On FC you also have **WWPN** (port) and **WWNN** (node) — 64-bit names used for fabric zoning.
- **`by-path`** encodes the transport route (portal IP + IQN + LUN); it is per-path, so it *differs* between the two paths — useful precisely when you want to name one specific path.

**Rescanning without a reboot** — after the target exposes a new LUN or a path returns:

```console
# software iSCSI: re-run discovery/login (see §4), or rescan a session
# rescan all SCSI hosts for new LUNs (sg3_utils):
# rescan-scsi-bus.sh
# or by hand, per host:
# echo "- - -" > /sys/class/scsi_host/host6/scan
# resize an existing device after the array grows the LUN:
# echo 1 > /sys/block/sdb/device/rescan
```

---

## 4. iSCSI in depth

### 4.1 Protocol vocabulary

| Term | Meaning |
|---|---|
| **Initiator** | The client. It *initiates* SCSI commands. On Linux: `open-iscsi` (`iscsid` + `iscsiadm`). |
| **Target** | The server exporting LUNs. On Linux: **LIO** (kernel `target_core_mod`), configured with `targetcli`. |
| **IQN** | *iSCSI Qualified Name* — the address of an initiator or target. Format `iqn.YYYY-MM.<reversed-domain>:<unique>` e.g. `iqn.2026-08.club.cybercirujas:node1`. |
| **Portal** | An `IP:port` the target listens on (default TCP **3260**). |
| **TPG** | *Target Portal Group* — a set of portals + LUNs + ACLs + auth, exposed together (`tpg1`, `tpg2`…). |
| **LUN** | A logical unit inside a TPG, backed by a *backstore*. |
| **Backstore** | What actually stores the bytes on the target: a block device, a file, a ramdisk, or a pass-through SCSI device. |
| **Session / Connection** | An initiator↔target *session* carries one or more TCP *connections* (MC/S = multiple connections per session). |
| **CHAP** | Challenge-Handshake auth; one-way (target authenticates initiator) or mutual (both). |

### 4.2 Backstore types (target side)

| Backstore | Backed by | Sync/behaviour | Use |
|---|---|---|---|
| **block** | A real block device (`/dev/sdX`, an LV, a multipath dev) | Full SCSI passthrough incl. UNMAP/TRIM | Production — LVM LV or array LUN |
| **fileio** | A regular file | Buffered or `write_back=false` for O_DSYNC | Flexible LUNs on a filesystem; labs |
| **ramdisk** | RAM | Volatile | Testing, scratch |
| **pscsi** | A physical SCSI device, command pass-through | No caching in LIO | Tape libraries, special HW |

**Rule of thumb:** production HA clusters use **block** backstores over an LVM logical volume (thin-provisioned or not). `fileio` is common in labs and in appliances that layer LUNs on a filesystem.

### 4.3 Building the target with `targetcli` (LIO)

LIO (`target_core_mod` and the `iscsi_target_mod` fabric) is the standard in-kernel Linux SCSI target; `targetcli-fb` is its shell. Assume the array node has an LVM volume group `vg_san` on top of which we carve LUNs.

```console
# lvcreate -n lv_lun0 -L 50G vg_san
  Logical volume "lv_lun0" created.
# lvcreate -n lv_lun1 -L 50G vg_san
  Logical volume "lv_lun1" created.

# systemctl enable --now target
# targetcli
targetcli shell version 2.1.58
Copyright 2011-2013 by Datera, Inc and others.
For help on commands, type 'help'.

/> cd /backstores/block
/backstores/block> create name=lun0 dev=/dev/vg_san/lv_lun0
Created block storage object lun0 using /dev/vg_san/lv_lun0.
/backstores/block> create name=lun1 dev=/dev/vg_san/lv_lun1
Created block storage object lun1 using /dev/vg_san/lv_lun1.

/backstores/block> cd /iscsi
/iscsi> create iqn.2026-08.club.cybercirujas:san.array0
Created target iqn.2026-08.club.cybercirujas:san.array0.
Created TPG 1.
Global pref auto_add_default_portal=true
Created default portal listening on all IPs (0.0.0.0), port 3260.
```

> **Production note:** the default portal binds `0.0.0.0:3260`, exposing the target on *every* interface — including the public one. Delete it and bind only the two dedicated storage subnets, one portal per fabric (this is what makes the two multipath paths independent).

```console
/iscsi> cd iqn.2026-08.club.cybercirujas:san.array0/tpg1
/iscsi/iqn.20...array0/tpg1> portals/ delete 0.0.0.0 3260
Deleted network portal 0.0.0.0:3260
/iscsi/iqn.20...array0/tpg1> portals/ create 192.168.50.10 3260
Created network portal 192.168.50.10:3260.
/iscsi/iqn.20...array0/tpg1> portals/ create 192.168.51.10 3260
Created network portal 192.168.51.10:3260.

# map the two backstores as LUN 0 and LUN 1
/iscsi/iqn.20...array0/tpg1> luns/ create /backstores/block/lun0
Created LUN 0.
/iscsi/iqn.20...array0/tpg1> luns/ create /backstores/block/lun1
Created LUN 1.

# ACL: only these initiator IQNs may attach (the two cluster nodes)
/iscsi/iqn.20...array0/tpg1> acls/ create iqn.2026-08.club.cybercirujas:node1
Created Node ACL for iqn.2026-08.club.cybercirujas:node1
Created mapped LUN 0.
Created mapped LUN 1.
/iscsi/iqn.20...array0/tpg1> acls/ create iqn.2026-08.club.cybercirujas:node2
Created Node ACL for iqn.2026-08.club.cybercirujas:node2
Created mapped LUN 0.
Created mapped LUN 1.
```

**Enable CHAP** (one-way here; mutual adds `mutual_userid`/`mutual_password`). Auth is set on the TPG, credentials per-ACL:

```console
/iscsi/iqn.20...array0/tpg1> set attribute authentication=1 generate_node_acls=0 demo_mode_write_protect=1
Parameter authentication is now '1'.
Parameter generate_node_acls is now '0'.
Parameter demo_mode_write_protect is now '1'.

/iscsi/iqn.20...array0/tpg1> cd acls/iqn.2026-08.club.cybercirujas:node1
/iscsi/iqn.20.../node1> set auth userid=node1 password=S3cr3t-node1-chap
Parameter userid is now 'node1'.
Parameter password is now 'S3cr3t-node1-chap'.
```

Persist the configuration — LIO's runtime lives in kernel config-fs; `saveconfig` writes it to `/etc/target/saveconfig.json`, which `target.service` restores at boot:

```console
/iscsi/iqn.20.../node1> cd /
/> saveconfig
Configuration saved to /etc/target/saveconfig.json
/> exit
Global pref auto_save_on_exit=true
Last 10 configs saved in /etc/target/backup/.
Configuration saved to /etc/target/saveconfig.json
```

Verify the resulting tree — this is the single most useful target-side diagnostic:

```console
# targetcli ls
o- / ......................................................................... [...]
  o- backstores .............................................................. [...]
  | o- block .................................................. [Storage Objects: 2]
  | | o- lun0 .............. [/dev/vg_san/lv_lun0 (50.0GiB) write-thru activated]
  | | | o- alua ................................................... [ALUA Groups: 1]
  | | |   o- default_tg_pt_gp ....................... [ALUA state: Active/optimized]
  | | o- lun1 .............. [/dev/vg_san/lv_lun1 (50.0GiB) write-thru activated]
  | o- fileio ................................................. [Storage Objects: 0]
  | o- pscsi .................................................. [Storage Objects: 0]
  | o- ramdisk ................................................ [Storage Objects: 0]
  o- iscsi ............................................................ [Targets: 1]
  | o- iqn.2026-08.club.cybercirujas:san.array0 ......................... [TPGs: 1]
  |   o- tpg1 ............................................... [gen-acls: no, auth]
  |     o- acls .......................................................... [ACLs: 2]
  |     | o- iqn.2026-08.club.cybercirujas:node1 ................. [Mapped LUNs: 2]
  |     | | o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     | | o- mapped_lun1 ........................... [lun1 block/lun1 (rw)]
  |     | o- iqn.2026-08.club.cybercirujas:node2 ................. [Mapped LUNs: 2]
  |     |   o- mapped_lun0 ........................... [lun0 block/lun0 (rw)]
  |     |   o- mapped_lun1 ........................... [lun1 block/lun1 (rw)]
  |     o- luns .......................................................... [LUNs: 2]
  |     | o- lun0 .... [block/lun0 (/dev/vg_san/lv_lun0) (default_tg_pt_gp)]
  |     | o- lun1 .... [block/lun1 (/dev/vg_san/lv_lun1) (default_tg_pt_gp)]
  |     o- portals .................................................... [Portals: 2]
  |       o- 192.168.50.10:3260 ................................................ [OK]
  |       o- 192.168.51.10:3260 ................................................ [OK]
  o- loopback ......................................................... [Targets: 0]
```

Open the firewall on the storage subnets only:

```console
# firewall-cmd --permanent --zone=internal --add-port=3260/tcp
# firewall-cmd --reload
```

### 4.4 The initiator with `open-iscsi`

On each cluster node install `open-iscsi`, set a unique, stable **initiator IQN** (it must match the ACL you created), and configure `iscsid`.

```console
# cat /etc/iscsi/initiatorname.iscsi
InitiatorName=iqn.2026-08.club.cybercirujas:node1

# systemctl enable --now iscsid
```

Key knobs in `/etc/iscsi/iscsid.conf` (these become the *defaults* baked into each discovered node record). The single most important one for HA is **`replacement_timeout`**:

```ini
# /etc/iscsi/iscsid.conf  (excerpt)

# Start sessions automatically at boot (needed so the LUN is present
# before Pacemaker's Filesystem/LVM resources start).
node.startup = automatic

# CHAP (one-way). Must match the target ACL credentials.
node.session.auth.authmethod = CHAP
node.session.auth.username   = node1
node.session.auth.password   = S3cr3t-node1-chap

# --- The multipath-critical timer ---
# How long the SCSI layer waits for a path to come back before it fails
# outstanding I/O and tears the path down. Default is 120s (right for a
# SINGLE-path setup so a brief blip does not kill I/O). With multipath you
# WANT the SCSI layer to give up fast so multipathd can redirect: set 5.
node.session.timeo.replacement_timeout = 5

# NOP-out ping to detect a dead connection quickly.
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout  = 5
```

> **The `replacement_timeout` trap.** On a *single-path* device you keep the default 120 s so a transient network blip does not throw I/O errors up to the filesystem. On a *multipath* device you invert the logic: set it low (5 s) so the failing path dies quickly and `multipathd` fails over, while `no_path_retry` in `multipath.conf` (see §5) owns the "all paths down" queueing decision. Leaving it at 120 with multipath means a path failure freezes I/O for two minutes before failover — a classic production incident.

**Discover and log in.** Run discovery against *each* portal (each fabric), so you build two node records = two paths:

```console
# iscsiadm -m discovery -t sendtargets -p 192.168.50.10:3260
192.168.50.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0
# iscsiadm -m discovery -t sendtargets -p 192.168.51.10:3260
192.168.51.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0

# log in to both portals
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -p 192.168.50.10:3260 --login
Logging in to [iface: default, target: iqn.2026-08.club.cybercirujas:san.array0, portal: 192.168.50.10,3260]
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san.array0, portal: 192.168.50.10,3260] successful.
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -p 192.168.51.10:3260 --login
Login to [iface: default, target: iqn.2026-08.club.cybercirujas:san.array0, portal: 192.168.51.10,3260] successful.
```

Inspect the live session at maximum verbosity — this shows the negotiated parameters, the connection state, and the resulting `sd` devices:

```console
# iscsiadm -m session
tcp: [1] 192.168.50.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0 (non-flash)
tcp: [2] 192.168.51.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0 (non-flash)

# iscsiadm -m session -P 3
iSCSI Transport Class version 2.0-870
...
Target: iqn.2026-08.club.cybercirujas:san.array0 (non-flash)
    Current Portal: 192.168.50.10:3260,1
    ...
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        ...
        negotiated iSCSI params:
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        FirstBurstLength: 65536
        MaxBurstLength: 262144
        ...
        Attached SCSI devices:
        Host Number: 6	State: running
        scsi6 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdb		State: running
        scsi6 Channel 00 Id 0 Lun: 1
            Attached scsi disk sdc		State: running
    Current Portal: 192.168.51.10:3260,1
        SID: 2
        ...
        Attached SCSI devices:
        Host Number: 7	State: running
        scsi7 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdd		State: running
        scsi7 Channel 00 Id 0 Lun: 1
            Attached scsi disk sde		State: running
```

We now have **two paths per LUN**: LUN0 = `sdb`+`sdd`, LUN1 = `sdc`+`sde`. Confirm they share one WWID (the proof they are the same LUN):

```console
# /lib/udev/scsi_id -g -u -d /dev/sdb
3600140572616e6461736574303100000
# /lib/udev/scsi_id -g -u -d /dev/sdd
3600140572616e6461736574303100000     # identical → same LUN, two paths
```

Make the node records persistent-on-boot and manage teardown cleanly:

```console
# ensure automatic startup (so LUNs exist before Pacemaker LVM/Filesystem RAs)
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 --op update -n node.startup -v automatic

# controlled logout of one portal (for maintenance)
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -p 192.168.51.10:3260 --logout
# log out everything
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 --logout
# forget a target completely (delete node records)
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -o delete
```

Persistent iSCSI state lives under `/etc/iscsi/nodes/<iqn>/<portal>/default` and `/etc/iscsi/send_targets/`. Per-node overrides written with `--op update` land there and *override* `iscsid.conf` for that specific target.

---

## 5. Device Mapper Multipath (DM-MPIO)

### 5.1 Why, and the architecture

We have four `sd` devices that are really two LUNs. Handing `sdb` straight to LVM would (a) pin us to one path with no failover, and (b) break the instant `sdb` renumbered on reboot. **DM-Multipath** collapses each set of paths into one `dm` device with a stable name, automatic failover, and load balancing.

```
        /dev/mapper/san_lun0   ← dm-3, stable, WWID-anchored
                 │
        ┌────────┴────────┐        device-mapper "multipath" target
   path group A       path group B   (kernel: dm_multipath.ko)
     (priority)         (priority)
    ┌────┴────┐        ┌────┴────┐
   sdb        —       sdd        —
  (host6)             (host7)
        ▲                  ▲
        └── multipathd (userspace) monitors paths, runs path_checker,
            computes priorities (prio), reinstates/fails paths, and
            reconfigures the kernel map.
```

- **`dm_multipath.ko`** (kernel) is the fast path: it routes each I/O to a path chosen by the **`path_selector`**.
- **`multipathd`** (userspace daemon) is the control plane: it runs the **`path_checker`** on each path, applies **`prio`** to rank paths into **path groups**, and tells the kernel to fail/reinstate paths and switch groups on failure. It also reacts to udev uevents when paths appear/disappear.
- Paths are grouped by **`path_grouping_policy`**; all paths in the *active* group share the load, and the daemon fails over to the next group only when the active group is exhausted.

### 5.2 The key tunables

| Setting | What it controls | Common values |
|---|---|---|
| **`path_grouping_policy`** | How paths are grouped | `failover` (1 path/group, active-passive) · `multibus` (all in one group, active-active) · `group_by_prio` (group by ALUA priority) · `group_by_serial` |
| **`path_selector`** | Which path in the active group gets the next I/O | `"service-time 0"` (default, latency-aware) · `"round-robin 0"` · `"queue-length 0"` |
| **`path_checker`** | How liveness is tested | `tur` (TEST UNIT READY, default & recommended) · `directio` · `readsector0` · `emc_clariion`, etc. |
| **`prio`** | Path priority source | `alua` (ask the array via ALUA) · `const` · `sysfs` · vendor callouts |
| **`failback`** | When to return to a higher-prio group after it recovers | `immediate` · `manual` · `<seconds>` (deferred) |
| **`no_path_retry`** | Behaviour when *all* paths are down | `queue` (block I/O forever — never lose data, may hang) · `fail` (error immediately) · `<N>` (retry N checker cycles, then fail) |
| **`features`** | Kernel feature flags | `"1 queue_if_no_path"` (equivalent to `no_path_retry queue`) |
| **`dev_loss_tmo` / `fast_io_fail_tmo`** | FC transport: how long before a lost rport is removed / I/O fast-failed | seconds |

**The `no_path_retry` decision is a cluster-safety decision, not a storage preference.** `queue` means I/O blocks indefinitely if every path dies — data is never lost, but the mount hangs, and under Pacemaker a hung `Filesystem` resource must be resolved by *fencing*. `fail` returns errors immediately, which lets the cluster react fast but risks application errors on a transient total outage. A common HA compromise is a bounded retry (`no_path_retry 30`) so brief full outages ride through while a genuine outage eventually errors out and triggers recovery. Match this to your fencing configuration deliberately.

### 5.3 `/etc/multipath.conf` — complete, production-shaped

```conf
# /etc/multipath.conf
#
# DM-Multipath configuration for the cybercirujas HA cluster.
# LUNs are LIO (LIO-ORG) block backstores, presented over two iSCSI fabrics.

defaults {
    # Use /etc/multipath/bindings-derived friendly names (mpatha, mpathb...)
    # We override per-LUN with explicit aliases below, so this only affects
    # any LUN we forgot to name.
    user_friendly_names     yes

    # Only build a map for a device that has >1 path OR is listed under
    # multipaths{}. Prevents accidentally wrapping local single-path disks.
    find_multipaths         yes

    path_checker            tur
    path_selector           "service-time 0"

    # ALUA-aware: ask the target which port group is active/optimized.
    prio                    alua

    # Group paths by their ALUA priority (active-optimized vs non-optimized).
    path_grouping_policy    group_by_prio

    # Return to the optimized group as soon as it recovers.
    failback                immediate

    # Retry the checker 30 times (~30 * polling_interval seconds) before
    # failing I/O when ALL paths are down. Bounded queueing for HA.
    no_path_retry           30

    polling_interval        5
    max_fds                 max
    dev_loss_tmo            60
    fast_io_fail_tmo        5
}

blacklist {
    # Never manage local/virtual/uninteresting devices.
    devnode "^(ram|zram|raw|loop|fd|md|dm-|sr|scd|st|nvme)[0-9]*"
    devnode "^(hd|vd)[a-z]"
    # Blacklist the local root disk explicitly by WWID:
    wwid    "3600508b1001c6e3b0000000000000000"
}

blacklist_exceptions {
    # Whitelist exactly the SAN WWIDs we DO want multipathed.
    wwid    "3600140572616e6461736574303100000"   # san_lun0
    wwid    "3600140572616e6461736574303200000"   # san_lun1
}

multipaths {
    multipath {
        wwid    3600140572616e6461736574303100000
        alias   san_lun0
    }
    multipath {
        wwid    3600140572616e6461736574303200000
        alias   san_lun1
    }
}

# Per-array overrides. LIO reports vendor "LIO-ORG"; tune defaults for it.
devices {
    device {
        vendor                  "LIO-ORG"
        product                 ".*"
        path_grouping_policy    group_by_prio
        path_checker            tur
        prio                    alua
        hardware_handler        "1 alua"
        failback                immediate
        no_path_retry           30
    }
}
```

Apply and inspect. `multipath -ll` is the primary status command:

```console
# systemctl enable --now multipathd
# multipath -r          # reload maps from current config
# multipath -ll
san_lun0 (3600140572616e6461736574303100000) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 6:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 7:0:0:0 sdd 8:48 active ready running
san_lun1 (3600140572616e6461736574303200000) dm-4 LIO-ORG,lun1
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 6:0:0:1 sdc 8:32 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 7:0:0:1 sde 8:64 active ready running
```

**How to read this** (memorise the vocabulary — it is exam and incident bread-and-butter):

- `san_lun0 (WWID) dm-3 LIO-ORG,lun0` — friendly name/alias, WWID, the `dm-N` device, vendor/product.
- `features='1 queue_if_no_path'` — the queueing feature is active (from `no_path_retry`).
- `hwhandler='1 alua'` — the kernel ALUA hardware handler is loaded.
- Each `-+-` block is a **path group** with its `policy` (selector), `prio`, and `status` (`active` = currently serving I/O, `enabled` = standby, `disabled`).
- Each leaf `6:0:0:0 sdb 8:16 active ready running` — H:C:T:L, kernel name, major:minor, dm state (`active`/`failed`), path checker state (`ready`/`faulty`/`ghost`), and the kernel running state.

The persistent WWID and alias bindings live in:

```console
# cat /etc/multipath/wwids
# Multipath wwids, Version : 1.0
/3600140572616e6461736574303100000/
/3600140572616e6461736574303200000/
# cat /etc/multipath/bindings
san_lun0 3600140572616e6461736574303100000
san_lun1 3600140572616e6461736574303200000
```

### 5.4 Partitions on a multipath device: `kpartx`

A multipath device is a single `dm` node — its partition table is *not* automatically exposed as child devices. `kpartx` reads the partition table and creates `/dev/mapper/<name>pN` device-mapper nodes:

```console
# partition the LUN through the multipath device (not through sdb!)
# parted -s /dev/mapper/san_lun0 mklabel gpt mkpart primary 0% 100%

# expose the partition(s) as dm devices
# kpartx -av /dev/mapper/san_lun0
add map san_lun0p1 (253:5): 0 104855552 linear 253:3 2048

# multipathd usually calls kpartx via udev; -a=add, -v=verbose, -d=delete
# ls -l /dev/mapper/san_lun0*
lrwxrwxrwx 1 root root 7 Aug 12 10:31 /dev/mapper/san_lun0 -> ../dm-3
lrwxrwxrwx 1 root root 7 Aug 12 10:31 /dev/mapper/san_lun0p1 -> ../dm-5
```

In most modern setups you avoid a partition table entirely and hand the *whole* multipath device to LVM — cleaner and avoids alignment surprises.

### 5.5 The live control plane: `multipathd` interactive shell

`multipathd` accepts commands at runtime — the fastest way to see reality without editing config:

```console
# multipathd show maps
name     sysfs uuid
san_lun0 dm-3  3600140572616e6461736574303100000
san_lun1 dm-4  3600140572616e6461736574303200000

# multipathd show paths
hcil     dev dev_t  pri dm_st  chk_st dev_st  next_check
6:0:0:0  sdb 8:16   50  active ready  running XXXX...... 12/20
7:0:0:0  sdd 8:48   10  active ready  running XXXX...... 12/20
6:0:0:1  sdc 8:32   50  active ready  running XXX....... 9/20
7:0:0:1  sde 8:64   10  active ready  running XXX....... 9/20

# multipathd show config      # the FULL effective config (defaults + your file + built-ins)
# multipathd show topology    # same tree as `multipath -ll`

# reconfigure after editing multipath.conf, without a restart:
# multipathd reconfigure
ok
```

---

## 6. Wiring it into the cluster

### 6.1 LVM on shared storage — avoid dual activation

If you put LVM on the multipath device, both nodes can *see* the VG, and both must not activate it at once (for a failover, non-cluster filesystem). Two mechanisms exist:

- **`system_id`** (LVM host-tagging): the VG carries an owning host id; only that host may activate it. On failover Pacemaker's `LVM-activate` resource (`vg_access_mode=system_id`) changes ownership. This is the modern, `clvmd`-free approach.
- **`lvmlockd`** (with `sanlock`/`dlm`) for genuinely *shared* activation, needed only when a cluster filesystem (GFS2/OCFS2, topic 362.3) mounts the LV on multiple nodes concurrently. The old `clvmd` is deprecated in its favour.

Point LVM only at multipath devices, never the raw `sd` paths, or LVM will see the VG twice:

```conf
# /etc/lvm/lvm.conf  (excerpt)
devices {
    # Only scan multipath maps and local disks; ignore raw SAN sd* paths.
    filter = [ "a|/dev/mapper/san_.*|", "a|/dev/sda|", "r|.*|" ]
    multipath_component_detection = 1
}
```

### 6.2 Pacemaker ordering (conceptual)

The dependency chain that must hold at boot and on failover:

```
iscsi session (node.startup=automatic / systemd)  →  multipath map present
     →  LVM-activate (vg_san, system_id)  →  Filesystem (mount /dev/vg_san/lv_data)
     →  service (e.g. pgsql)         ...all colocated, ordered, and FENCED.
```

```console
# example ordering/colocation with pcs (Pacemaker)
# pcs resource create san_vg   ocf:heartbeat:LVM-activate \
#       vgname=vg_san vg_access_mode=system_id \
#       op monitor interval=30s
# pcs resource create san_fs   ocf:heartbeat:Filesystem \
#       device=/dev/vg_san/lv_data directory=/srv/data fstype=xfs \
#       op monitor interval=20s
# pcs constraint order san_vg then san_fs
# pcs constraint colocation add san_fs with san_vg INFINITY
```

The iSCSI login itself is usually handled by `iscsid` (`node.startup=automatic`) and multipath by `multipathd.service`, so the cluster typically starts *above* the LUN. Fencing (a separate STONITH resource) is mandatory: it is what lets node2 safely activate `vg_san` after node1 is confirmed dead.

---

## 7. Verification and failure diagnosis

### 7.1 The verification ladder (run top to bottom)

```console
# 1. Is the iSCSI session up on both fabrics?
# iscsiadm -m session
tcp: [1] 192.168.50.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0 (non-flash)
tcp: [2] 192.168.51.10:3260,1 iqn.2026-08.club.cybercirujas:san.array0 (non-flash)

# 2. Do we see the raw sd devices? (expect 2 per LUN)
# lsscsi | grep LIO
[6:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdb
[6:0:0:1]    disk    LIO-ORG  lun1             4.0   /dev/sdc
[7:0:0:0]    disk    LIO-ORG  lun0             4.0   /dev/sdd
[7:0:0:1]    disk    LIO-ORG  lun1             4.0   /dev/sde

# 3. Do the paths share a WWID? (proof they're one LUN)
# multipath -ll san_lun0 | head -1
san_lun0 (3600140572616e6461736574303100000) dm-3 LIO-ORG,lun0

# 4. Are all paths active/ready?
# multipathd show paths | grep san || multipath -ll
# 5. Filesystem/LVM stacked on the map (never on sdX)?
# lsblk /dev/mapper/san_lun0
NAME       MAJ:MIN RM SIZE RO TYPE  MOUNTPOINT
san_lun0   253:3    0  50G  0 mpath
`-vg_san-lv_data 253:6 0 50G 0 lvm  /srv/data
```

### 7.2 Deliberate failover test (the acceptance test for HA)

Prove failover works *before* you trust it in production. Kill one fabric and watch I/O continue:

```console
# start continuous I/O
# dd if=/dev/zero of=/srv/data/test.bin bs=1M count=20000 oflag=direct status=progress &

# fail path fabric B by logging out that portal (or admin-down the switch port)
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -p 192.168.51.10:3260 --logout

# multipath -ll now shows the B paths gone; I/O keeps flowing on A
# multipath -ll san_lun0
san_lun0 (3600140572616e6461736574303100000) dm-3 LIO-ORG,lun0
size=50G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 6:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=0  status=enabled
  `- 7:0:0:0 sdd 8:48 failed faulty running

# restore the path; with failback=immediate it rejoins automatically
# iscsiadm -m node -T iqn.2026-08.club.cybercirujas:san.array0 -p 192.168.51.10:3260 --login
# multipathd reinstates the path within polling_interval; dd never errored.
```

### 7.3 Failure catalogue

| Symptom | Likely cause | Where to look / fix |
|---|---|---|
| Login fails: *"Authorization failure"* | CHAP mismatch or initiator IQN not in target ACL | Target: `targetcli ls` ACLs & `set auth`. Initiator: `initiatorname.iscsi`, `iscsid.conf` CHAP creds. `journalctl -u iscsid`. |
| Discovery works, login times out | Firewall/routing on the storage subnet; portal bound to wrong IP | `ss -ltnp sport = :3260` on target; `firewall-cmd --list-ports`; ping each portal. |
| Only 1 path per LUN | Second discovery/login not done, or one fabric down | Re-run discovery on the 2nd portal; `iscsiadm -m session -P3`; check `by-path` symlinks. |
| `multipath -ll` shows the disk but as a **single** path map (or not at all) | `find_multipaths yes` + only one path present; WWID blacklisted; alias not matching WWID | `multipath -ll`, `multipathd show config`, verify WWID in `blacklist_exceptions`/`multipaths`. |
| Path flapping (`faulty`↔`ready`) | Wrong `path_checker` for the array; MTU/jumbo-frame mismatch causing drops; network errors | Match `path_checker`/device profile; verify MTU end-to-end (`ping -M do -s 8972`); `dmesg`, `journalctl -k`. |
| I/O freezes for ~2 min on a path failure | `replacement_timeout` left at 120 with multipath | Set `node.session.timeo.replacement_timeout = 5`, re-login. |
| Mount hangs forever when all paths die | `no_path_retry queue` / `queue_if_no_path` — by design | Expected for `queue`; use bounded `no_path_retry N`, or let fencing recover. `multipathd disablequeueing maps` to release a stuck map in an emergency. |
| Two nodes corrupt an `ext4`/`xfs` on the LUN | Dual mount of a non-cluster FS; fencing missing/broken | Never mount shared FS on 2 nodes; enforce Pacemaker colocation + working STONITH; use GFS2/OCFS2 (362.3) for concurrent mounts. |
| LVM sees the VG twice / wrong PV | LVM scanning raw `sd*` instead of the map | `lvm.conf` `filter` to `/dev/mapper/` + `multipath_component_detection = 1`. |
| New/grown LUN not visible | Missing rescan | `rescan-scsi-bus.sh`, `echo "- - -" > /sys/class/scsi_host/hostN/scan`, then `multipath -r`; for resize `echo 1 > /sys/block/sdX/device/rescan && multipathd resize map <name>`. |

Primary log sources: `journalctl -u iscsid -u multipathd`, `dmesg`/`journalctl -k` (SCSI errors, path events), `/var/log/messages`. Turn up multipath verbosity with `verbosity` in `defaults{}` or run `multipathd -d -v3` in the foreground while reproducing.

---

## 8. References

- **LPI Exam 306 Objectives (306-300, v3.0)** — https://www.lpi.org/our-certifications/exam-306-objectives/
- **open-iscsi (initiator: `iscsid`, `iscsiadm`, `iscsid.conf`)** — https://github.com/open-iscsi/open-iscsi and https://www.open-iscsi.com/
- **targetcli-fb / LIO target** — https://github.com/open-iscsi/targetcli-fb · man `targetcli(8)`
- **Linux LIO / TCM kernel target documentation** — https://docs.kernel.org/target/index.html
- **Device Mapper Multipath — kernel** — https://docs.kernel.org/admin-guide/device-mapper/dm-multipath.html (or `dm-queue-length`, `dm-service-time` selector docs)
- **Red Hat: Configuring Device Mapper Multipath (RHEL 9)** — https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_device_mapper_multipath/index
- **Red Hat: Configuring and Managing Storage Devices — iSCSI** — https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/
- **SUSE Linux Enterprise Storage Administration Guide (multipath, iSCSI)** — https://documentation.suse.com/sles/html/SLES-all/cha-multipath.html
- **`multipath.conf(5)`, `multipath(8)`, `multipathd(8)`, `kpartx(8)`, `iscsiadm(8)`, `lsscsi(8)`** — system manual pages
- **T10 SCSI standards (SAM/SPC/SBC, ALUA), SNIA references** — https://www.t10.org/ · https://www.snia.org/
- **SCSI ALUA (Asymmetric Logical Unit Access)** — SPC-4, T10, and the Linux `scsi_dh_alua` device handler