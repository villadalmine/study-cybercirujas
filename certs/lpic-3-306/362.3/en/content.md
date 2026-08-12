# Topic 362.3: Clustered File Systems

> **LPIC-3 306-300 — High Availability and Storage Clusters**
> Objective 362.3 · Exam weight: 6.67
> *Candidates should be able to install and manage GFS2 and OCFS2 file systems, including the use of the cluster infrastructure for these file systems. This includes the use of the Distributed Lock Manager (DLM), and an awareness of CephFS, GlusterFS and Lustre.*

---

## 1. The production problem: what a clustered file system actually solves

Take a two-node Pacemaker/Corosync cluster with a SAN LUN, an iSCSI target, or a DRBD device running in **dual-primary** mode. The block device is visible and writable from both nodes simultaneously. Now mount an ordinary local file system — `ext4`, `xfs` — on that shared LUN from **both** nodes at once and write to it.

The result is deterministic and catastrophic: **near-instant, unrecoverable corruption.**

The reason is that a local file system assumes it is the *sole* authority over the device. It caches inodes, the block bitmap, the journal head, and directory blocks in the node's page cache and writes them back lazily. Node A allocates block 4711 to file `/a.log`; Node B, whose cached bitmap still shows 4711 free, allocates the *same* block to `/b.log`. Neither node ever sees the other's dirty buffers. The journal — designed to protect against a *crash*, not against a *second concurrent writer* — makes it worse: two nodes replaying two journals over one metadata tree guarantees divergence.

```
        Node A page cache            Node B page cache
        ┌───────────────┐            ┌───────────────┐
        │ bitmap: 4711=0│            │ bitmap: 4711=0│   ← both think it's free
        │ inode /a.log  │            │ inode /b.log  │
        └───────┬───────┘            └───────┬───────┘
                │ write blk 4711 → a.log      │ write blk 4711 → b.log
                └──────────────┬──────────────┘
                               ▼
                    ┌───────────────────┐
                    │   Shared LUN      │   ← block 4711 written twice, silently
                    │   (SAN / iSCSI /  │      one file's data is gone,
                    │    DRBD primary)  │      metadata tree is inconsistent
                    └───────────────────┘
```

There are two families of answers, and choosing the wrong one is the most common architectural mistake at this layer:

1. **Active/passive with a local FS.** Keep `xfs`/`ext4`, but guarantee the device is mounted on **exactly one node at a time**, enforced by Pacemaker ordering + colocation + **STONITH**. Simple, robust, and correct for most HA services (databases, NFS heads). But only one node serves I/O — no read/write scale-out, and failover incurs a journal-replay + mount delay.

2. **Active/active with a clustered file system.** Every node mounts the *same* device *at the same time* and reads/writes concurrently. This requires the file system to coordinate every metadata mutation cluster-wide through a **Distributed Lock Manager (DLM)**. This is GFS2 and OCFS2. It buys you concurrent access (shared web roots, cluster-wide `maildir`, VM image pools, shared scratch) at the cost of a mandatory, correctly-fenced cluster stack and a locking round-trip on contended metadata.

A separate, orthogonal family — **scale-out distributed file systems** (CephFS, GlusterFS, Lustre) — abandons the shared block device entirely. There is no single LUN; data lives on independent servers' local disks and is replicated or erasure-coded over the network. These solve *scale* and *availability* rather than *concurrent access to one LUN*, and the exam requires awareness of them (§7).

The objective 362.3 is fundamentally about **shared-disk cluster file systems and the lock manager that makes them safe.**

---

## 2. Taxonomy and trade-offs

### 2.1 Shared-disk vs. scale-out

| Property | **Shared-disk** (GFS2, OCFS2) | **Scale-out / distributed** (CephFS, GlusterFS, Lustre) |
|---|---|---|
| Storage substrate | One block device visible to all nodes (SAN/FC, iSCSI, SAS, DRBD dual-primary) | Independent servers with local disks; no shared LUN |
| Coordination mechanism | DLM over the cluster interconnect | Metadata servers (Ceph MDS, Lustre MDS) or algorithmic placement (Gluster DHT / CRUSH) |
| Data redundancy | External — the LUN itself (RAID/SAN replication/DRBD) | Built-in — replication or erasure coding across nodes |
| **Fencing / STONITH** | **Mandatory.** A stray writer corrupts the LUN | Not required for correctness — quorum + replication tolerate node loss |
| Practical node count | ~2–16 (GFS2), up to ~32 (OCFS2) | Hundreds to thousands |
| Failure domain of the data | The shared LUN is a SPOF unless independently replicated | Loss of N replicas / erasure fragments tolerated |
| Network sensitivity | Interconnect latency drives lock RTT | Throughput/latency drive data path |
| Canonical use | Active/active on a SAN, small clusters, shared VM images | Cloud object+file at scale, HPC scratch, media |

**Rule of thumb:** if you have exactly one LUN and a handful of nodes, use a shared-disk FS. If you have many servers each with disks and need to grow horizontally, use a scale-out FS. Do not try to make a shared-disk FS scale past ~16 nodes; DLM lock traffic on hot metadata becomes the bottleneck long before that.

### 2.2 GFS2 vs. OCFS2

| Feature | **GFS2** | **OCFS2** |
|---|---|---|
| Origin / maintainer | Red Hat (Sistina → Red Hat) | Oracle |
| Kernel module | `gfs2` | `ocfs2` |
| Lock manager | Linux kernel **DLM** (`fs/dlm`) driven by `dlm_controld` | Built-in **O2DLM** (O2CB stack) *or* kernel DLM (Pacemaker/`pcmk` user stack) |
| Cluster stack | **Corosync + Pacemaker only** (mandatory) | **O2CB** (self-contained) *or* Pacemaker |
| Fencing | STONITH via Pacemaker (mandatory) | O2CB **self-fences** (kernel panic on heartbeat loss) or STONITH via Pacemaker |
| Per-node unit of concurrency | **Journal** (`mkfs.gfs2 -j N`) | **Node slot** (`mkfs.ocfs2 -N N`) |
| Grow online | `gfs2_grow` | `tunefs.ocfs2 -S` |
| Add journals/slots online | `gfs2_jadd -j N` | `tunefs.ocfs2 -N N` |
| Volume management | Shared VG via `lvmlockd` (or legacy CLVM) | Raw partition or CLVM |
| Heartbeat | Corosync (network) | Disk heartbeat (local or global) + network, or Corosync (pcmk) |
| Primary distros | RHEL, SUSE (Resilient Storage add-on) | Oracle Linux (UEK), SUSE |
| Practical max size | ~100 TB | up to 4 PB |
| POSIX locks (`fcntl`) | via DLM plock | via DLM/O2DLM plock |

**Key mental model:** GFS2 *outsources* everything cluster-related (membership, fencing, locking transport) to the Pacemaker/Corosync/DLM stack. OCFS2 historically *ships its own* stack (O2CB) and can run without Pacemaker at all — but modern deployments increasingly wire it into Pacemaker (`--cluster-stack=pcmk`) so the same STONITH policy governs both.

### 2.3 The scale-out three (awareness level — see §7)

| | **CephFS** | **GlusterFS** | **Lustre** |
|---|---|---|---|
| Architecture | POSIX FS on RADOS; MON + OSD + **MDS** | FUSE, no metadata server, elastic hashing (DHT) | MDS/MDT + OSS/OST, parallel |
| Metadata | Dedicated MDS daemons, dynamic subtree partitioning | Distributed algorithmically (no MDS) | Dedicated Metadata Targets |
| Data placement | CRUSH map | DHT translator | Striped across OSTs |
| Redundancy | Replication / erasure coding | Replicated / dispersed volumes | External (RAID on OST) + failover |
| Sweet spot | Unified block+object+file, cloud | Simple file scale-out, appliances | HPC, extreme throughput, RDMA/InfiniBand |

---

## 3. The Distributed Lock Manager (DLM)

Everything in this objective rests on the DLM. Understand it and the rest is bookkeeping.

### 3.1 Heritage and model

The Linux in-kernel DLM (`fs/dlm`, module `dlm`) is a direct descendant of the **VMS Distributed Lock Manager (VAXcluster, ~1984)**. Its job: let independent nodes agree on *who may do what* to a named resource, so that at most one node holds an incompatible lock at any instant.

Core concepts:

- **Lockspace** — a named namespace of lock resources. Each mounted GFS2 file system creates one lockspace; CLVM/`lvmlockd` creates another. Visible under `configfs` at `/sys/kernel/config/dlm/cluster/spaces/` and via `dlm_tool ls`.
- **Lock resource** — a named object (in GFS2, encoded from glock type + inode/rgrp number).
- **Lock** — a request against a resource at one of **six modes**.
- **Lock Value Block (LVB)** — a small (typically 32-byte) piece of data attached to a resource that the holder can update and other requesters can read on grant — GFS2 uses it to piggyback metadata generation numbers.
- **Resource master / directory** — each resource is *mastered* by one node (which tracks its grant queue). A separate distributed **directory** maps resource name → master. Mastering is usually local to the first node to lock the resource, minimizing network hops for node-affine workloads.

### 3.2 The six lock modes and the compatibility matrix

| Mode | Meaning |
|---|---|
| **NL** | Null — no access; a placeholder to hold a reference / read the LVB |
| **CR** | Concurrent Read — read; permit others to read and write |
| **CW** | Concurrent Write — write; permit others concurrent write (caller does own serialization) |
| **PR** | Protected Read — shared read lock; no writers |
| **PW** | Protected Write — update lock; permits concurrent readers (CR), no other writers |
| **EX** | Exclusive — sole access |

Compatibility (`Y` = the two modes may be held simultaneously on the same resource by different nodes):

```
         Held →
Req ↓    NL   CR   CW   PR   PW   EX
 NL      Y    Y    Y    Y    Y    Y
 CR      Y    Y    Y    Y    Y    N
 CW      Y    Y    Y    N    N    N
 PR      Y    Y    N    Y    N    N
 PW      Y    Y    N    N    N    N
 EX      Y    N    N    N    N    N
```

Read this matrix as the physics of active/active I/O: many nodes can hold **PR** (all reading a file), but the instant one requests **EX** (to write metadata/extend the inode) every other holder must be demoted first — that demotion is a network round-trip, and it is why *write-shared hot files across nodes* is the classic GFS2/OCFS2 performance killer.

### 3.3 `dlm_controld` and the hard dependency on fencing

`dlm_controld` (package `dlm`, RHEL/SUSE) is the userspace daemon that:

1. Joins Corosync's closed process group (CPG) to learn cluster membership.
2. Manages lockspace join/leave and drives **recovery** when membership changes.
3. **Blocks lock recovery until fencing of a failed node is confirmed.**

Point 3 is the single most important operational fact in this entire topic. When a node drops out, the DLM must not grant the locks that node held to anyone else until it is *certain* the dead node can no longer touch the shared storage. That certainty comes only from a **successful STONITH (fence) operation.** Therefore:

> **If fencing is not configured, or is configured but fails, all cluster I/O to the GFS2/OCFS2 file system hangs indefinitely — on every surviving node — after any node failure.** This is not a bug; it is the DLM refusing to risk corruption. A "hung cluster FS after a node died" almost always means "fencing did not complete."

Relevant `configfs` and tools:

```
/sys/kernel/config/dlm/cluster/          # tunables: comms, timers, protocol
/sys/kernel/config/dlm/cluster/spaces/   # active lockspaces
/sys/kernel/config/dlm/cluster/comms/    # node comms endpoints
```

```
dlm_tool ls               # list lockspaces + membership
dlm_tool status           # daemon + node status
dlm_tool lockdebug <ls>   # full lock dump for a lockspace
dlm_tool plocks <ls>      # POSIX (fcntl) locks held in a lockspace
dlm_tool dump             # in-kernel debug log
dlm_tool fence_ack <nid>  # (advanced) manual fence acknowledgement
```

---

## 4. GFS2 — Red Hat Global File System 2

### 4.1 Internal architecture

- **64-bit, journaling, symmetric shared-disk FS.** No metadata master node — every node is a peer that locks via DLM.
- **Journals are per-node.** A node needs a private journal to mount. `N` journals ⇒ up to `N` concurrent mounts. Running out of journals is a hard mount failure (fix online with `gfs2_jadd`).
- **Resource groups (rgrps).** The disk is divided into resource groups, each with its own block bitmap. An rgrp is protected by one glock, so more/appropriately-sized rgrps reduce allocation contention.
- **Glocks (global locks).** GFS2's abstraction over DLM locks; one glock per protected object. Glock *types* you will see in debug output: `2` = inode, `3` = resource group (rgrp), `5` = `iopen` (tracks open/unlink across nodes), `1` = trans, `4` = non-disk, `6` = flock, `9` = quota. The glock number is the disk block of the object.
- **The `withdraw` mechanism.** On detecting internal inconsistency or an I/O error, GFS2 does **not** panic the node or (worse) keep writing garbage — it **withdraws** from the cluster: it stops touching that file system, releases its journal for another node to recover, and logs `withdrawing from cluster`. Recovery requires unmounting on that node (often a reboot). `errors=panic` mount option forces a panic instead — useful when you'd rather fence-and-restart than leave a withdrawn mount.

### 4.2 Complete cluster stack — RHEL 8/9 with `lvmlockd` shared VG

This is the canonical, current procedure (RHEL Resilient Storage; SUSE is analogous with `crmsh`). It assumes a working 2-node Pacemaker cluster with **STONITH already configured and tested**.

**Packages (all nodes):**

```bash
$ sudo dnf install -y dlm lvm2-lockd gfs2-utils
```

**Enable the shared-VG lock daemon in LVM (all nodes) — `/etc/lvm/lvm.conf`:**

```
    # Type 1 = sanlock, 2 = dlm.  For a Pacemaker/Corosync cluster use dlm.
    use_lvmlockd = 1
```

**Pacemaker policy — freeze on quorum loss so the DLM recovers correctly:**

```bash
$ sudo pcs property set no-quorum-policy=freeze
```

**Locking resources (DLM + lvmlockd), cloned and ordered `dlm → lvmlockd`:**

```bash
# Both resources live in a group so they start/stop as a unit, then clone it.
$ sudo pcs resource create dlm ocf:pacemaker:controld \
      op monitor interval=30s on-fail=fence \
      --group locking

$ sudo pcs resource create lvmlockd ocf:heartbeat:lvmlockd \
      op monitor interval=30s on-fail=fence \
      --group locking

$ sudo pcs resource clone locking interleave=true
```

**Create the shared VG and a logical volume (on ONE node):**

```bash
$ sudo vgcreate --shared shared_vg1 /dev/sdb1
  Physical volume "/dev/sdb1" successfully created.
  Logical volume lock manager (lvmlockd) started.
  Volume group "shared_vg1" successfully created
  VG shared_vg1 starting dlm lockspace
  Starting locking.  Waiting until locks are ready...

$ sudo lvcreate -l 100%FREE -n shared_lv1 shared_vg1
  Logical volume "shared_lv1" created.
```

**On the OTHER node, start the lockspace so the shared VG is visible:**

```bash
$ sudo vgchange --lockstart shared_vg1
  VG shared_vg1 starting dlm lockspace
  Starting locking.  Waiting until locks are ready...
```

**Shared-mode LV activation as a cloned Pacemaker resource:**

```bash
$ sudo pcs resource create sharedlv1 ocf:heartbeat:LVM-activate \
      lvname=shared_lv1 vgname=shared_vg1 \
      activation_mode=shared vg_access_mode=lvmlockd \
      --group shared_vg1

$ sudo pcs resource clone shared_vg1 interleave=true
```

**Order + colocate: storage must start after locking on every node:**

```bash
$ sudo pcs constraint order start locking-clone then shared_vg1-clone
Adding locking-clone shared_vg1-clone (kind: Mandatory)

$ sudo pcs constraint colocation add shared_vg1-clone with locking-clone
```

### 4.3 Making the file system — `mkfs.gfs2`

The lock table `-t` is **`<clustername>:<fsname>`**. `<clustername>` **must** match your Corosync cluster name exactly, or the mount will be rejected. `-p lock_dlm` selects clustered locking; `-p lock_nolock` makes a single-node-only FS (no cluster) — never mount a `lock_nolock` FS on two nodes.

```bash
$ sudo mkfs.gfs2 -p lock_dlm -t my_cluster:gfs2demo1 -j 2 /dev/shared_vg1/shared_lv1
It appears to contain an existing filesystem (lvm2)
This will destroy any data on /dev/shared_vg1/shared_lv1
Are you sure you want to proceed? [y/n] y
Discarding device contents (may take a while on large devices): Done
Adding journals: Done
Building resource groups: Done
Creating quota file: Done
Writing superblock and syncing: Done
Device:                    /dev/shared_vg1/shared_lv1
Block size:                4096
Device size:               10.00 GB (2621440 blocks)
Filesystem size:           10.00 GB (2621438 blocks)
Journals:                  2
Journal size:              32MB
Resource groups:           41
Locking protocol:          "lock_dlm"
Lock table:                "my_cluster:gfs2demo1"
UUID:                      7f3d2c1b-9a84-4e6f-b210-8c5e4d9a1f77
```

`mkfs.gfs2` key options:

| Option | Meaning |
|---|---|
| `-p lock_dlm` \| `lock_nolock` | Locking protocol (clustered vs. standalone) |
| `-t clus:fs` | Lock table name — cluster name **must** match Corosync |
| `-j N` | Number of journals (⇒ max simultaneous mounts). Rule: `journals ≥ nodes` |
| `-J size` | Journal size in MB (default 128, min 8; larger helps metadata-heavy writes) |
| `-r MB` | Resource group size (default auto; tune for very large or contended FS) |
| `-b bytes` | Block size (default 4096; keep 4096 unless you know why) |
| `-o align=…` | Align rgrps to storage stripe geometry |
| `-O` | Skip the "are you sure" prompt (scripting) |

### 4.4 Filesystem resource and mount

Let Pacemaker mount it as a clone (one mount per node), ordered after the shared VG:

```bash
$ sudo pcs resource create sharedfs1 ocf:heartbeat:Filesystem \
      device="/dev/shared_vg1/shared_lv1" \
      directory="/mnt/gfs2demo1" \
      fstype="gfs2" options="noatime,nodiratime" \
      op monitor interval=10s on-fail=fence \
      --group shared_vg1
```

Because `sharedfs1` is in the already-cloned `shared_vg1` group, it inherits the clone and mounts on every node. Verify:

```bash
$ sudo pcs status --full | grep -A6 'Clone Set: shared_vg1-clone'
  * Clone Set: shared_vg1-clone [shared_vg1]:
    * Started: [ node1 node2 ]

$ cat /proc/mounts | grep gfs2
/dev/mapper/shared_vg1-shared_lv1 /mnt/gfs2demo1 gfs2 rw,noatime,nodiratime 0 0
```

Manual mount (for testing outside Pacemaker) uses the `mount.gfs2` helper implicitly:

```bash
$ sudo mount -t gfs2 -o noatime /dev/shared_vg1/shared_lv1 /mnt/gfs2demo1
```

Important GFS2 mount options:

| Option | Effect |
|---|---|
| `lockproto=lock_dlm` | Override the on-disk lock protocol (rarely needed) |
| `locktable=clus:fs` | Override the on-disk lock table (e.g. cluster renamed) |
| `noatime,nodiratime` | Avoid a metadata glock write on every read — **strongly recommended** |
| `data=ordered` \| `writeback` | Journal data ordering (ordered is safer, the default) |
| `errors=withdraw` \| `panic` | On error, withdraw (default) or panic the node |
| `quota=on\|off\|account` | Enable/account quotas |
| `statfs_percent=N` | Bound `df` inaccuracy vs. sync cost for fast `statfs` |

### 4.5 Growing, adding journals, tuning, repairing

**Grow online** (after extending the LV first):

```bash
$ sudo lvextend -L +5G /dev/shared_vg1/shared_lv1
  Size of logical volume shared_vg1/shared_lv1 changed from 10.00 GiB to 15.00 GiB.

$ sudo gfs2_grow /mnt/gfs2demo1
FS: Mount point:             /mnt/gfs2demo1
FS: Device:                  /dev/mapper/shared_vg1-shared_lv1
FS: Size:                    2621438 (0x27fffe)
DEV: Length:                 3932160 (0x3c0000)
The file system will grow by 5120MB.
gfs2_grow complete.
```

**Add a journal online** (before adding a third node, so it can mount):

```bash
$ sudo gfs2_jadd -j 1 /mnt/gfs2demo1
Filesystem: /mnt/gfs2demo1
Old journals: 2
New journals: 3
```

**Inspect / tune the superblock** with `tunegfs2` (the modern replacement for the old `gfs2_tool`):

```bash
$ sudo tunegfs2 -l /dev/shared_vg1/shared_lv1
tunegfs2 (device /dev/shared_vg1/shared_lv1)
Filesystem volume name:   my_cluster:gfs2demo1
Filesystem UUID:          7f3d2c1b-9a84-4e6f-b210-8c5e4d9a1f77
Filesystem magic number:  0x1161970
Block size:               4096
Filesystem size:          15.00 GB
Journals:                 3
Resource groups:          61
Locking protocol:         lock_dlm
Lock table:               my_cluster:gfs2demo1

# Re-point a filesystem at a renamed cluster (UNMOUNTED everywhere first):
$ sudo tunegfs2 -o locktable=new_cluster:gfs2demo1 /dev/shared_vg1/shared_lv1
```

**Low-level offline inspection / repair** with `gfs2_edit` (dangerous; unmount everywhere):

```bash
$ sudo gfs2_edit -p sb /dev/shared_vg1/shared_lv1   # dump superblock
$ sudo gfs2_edit -p rindex /dev/shared_vg1/shared_lv1   # resource index
$ sudo gfs2_edit savemeta /dev/shared_vg1/shared_lv1 /root/gfs2.meta   # metadata image for support
```

**Check/repair** with `fsck.gfs2` — **the file system must be unmounted on ALL nodes.** Running it against a mounted GFS2 will corrupt it:

```bash
# 1) Take the FS clone out of the cluster so nothing remounts it:
$ sudo pcs resource disable sharedfs1

# 2) Confirm unmounted everywhere (run on each node):
$ mount | grep gfs2 || echo "not mounted here"
not mounted here

# 3) Now repair:
$ sudo fsck.gfs2 -y /dev/shared_vg1/shared_lv1
Initializing fsck
Validating Resource Group index.
Level 1 rgrp check: Checking if all rgrp and rindex values are good.
(level 1 passed)
Starting pass1
Pass1 complete
...
Starting pass5
Pass5 complete
Writing changes to disk
gfs2_fsck complete

# 4) Re-enable:
$ sudo pcs resource enable sharedfs1
```

---

## 5. OCFS2 — Oracle Cluster File System 2

### 5.1 Architecture and the two stacks

OCFS2 is a general-purpose 64-bit shared-disk FS in the mainline kernel. Its defining feature relative to GFS2 is that it ships a **self-contained cluster stack, O2CB**, so it can run active/active **without** Pacemaker at all — historically its main appeal for Oracle RAC deployments.

Two stacks, selectable at format time and boot:

- **`o2cb`** (default, built-in): membership + a **disk heartbeat** + a TCP network (port **7777**) + the in-kernel **O2DLM**. Configured through `/etc/ocfs2/cluster.conf` and `/etc/sysconfig/o2cb`. On loss of heartbeat past a threshold, a node **self-fences by kernel panic** — the equivalent of STONITH, done from the inside.
- **`pcmk`** (user stack): membership/fencing from **Pacemaker/Corosync**, locking via the kernel **`fs/dlm`** (same DLM as GFS2). Chosen with `--cluster-stack=pcmk` / `mount.ocfs2 -o cluster_stack=pcmk`. Use this when OCFS2 must share one STONITH policy with the rest of a Pacemaker cluster.

Per-node concurrency unit = **node slot** (`-N`), directly analogous to a GFS2 journal.

### 5.2 O2CB stack configuration

Build `/etc/ocfs2/cluster.conf` — either edit it directly (tab-indented; **tabs, not spaces**) or generate it with `o2cb`.

**Generated with `o2cb` (recommended, run on one node then copy the file to all):**

```bash
$ sudo o2cb add-cluster ocfs2cluster
$ sudo o2cb add-node ocfs2cluster node1 --ip 192.168.100.11 --port 7777 --number 0
$ sudo o2cb add-node ocfs2cluster node2 --ip 192.168.100.12 --port 7777 --number 1
```

Resulting `/etc/ocfs2/cluster.conf`:

```
cluster:
	heartbeat_mode = local
	node_count = 2
	name = ocfs2cluster

node:
	number = 0
	cluster = ocfs2cluster
	ip_port = 7777
	ip_address = 192.168.100.11
	name = node1

node:
	number = 1
	cluster = ocfs2cluster
	ip_port = 7777
	ip_address = 192.168.100.12
	name = node2
```

> The `name` of each node **must equal `hostname -s`** on that node, and the IP must be the interconnect the nodes use to reach each other.

**Global vs. local heartbeat.** *Local* heartbeat writes a heartbeat region into **every** OCFS2 volume — I/O scales with the number of mounted volumes. *Global* heartbeat uses **one** dedicated heartbeat device shared by the whole cluster, decoupling heartbeat cost from volume count — preferred when you mount many OCFS2 volumes:

```bash
# Format a small dedicated device for global heartbeat, then register it:
$ sudo o2cb add-heartbeat ocfs2cluster /dev/sdb1
$ sudo o2cb heartbeat-mode ocfs2cluster global
```

**Stack tunables — `/etc/sysconfig/o2cb`** (Debian/SUSE: `/etc/default/o2cb`). These directly govern how aggressively a node self-fences:

```bash
# O2CB cluster configuration.
O2CB_ENABLED=true
O2CB_STACK=o2cb
O2CB_BOOTCLUSTER=ocfs2cluster
# Iterations before a node is considered dead (each ~2s) → (T-1)*2s:
O2CB_HEARTBEAT_THRESHOLD=31
# Network idle timeout before a connection is torn down (ms):
O2CB_IDLE_TIMEOUT_MS=30000
# Keepalive packet interval (ms):
O2CB_KEEPALIVE_DELAY_MS=2000
# Delay between reconnect attempts (ms):
O2CB_RECONNECT_DELAY_MS=2000
```

`O2CB_HEARTBEAT_THRESHOLD=31` ⇒ a node is fenced after ~`(31-1)*2 = 60 s` of missed disk heartbeats. Too low → spurious self-fences on transient SAN latency; too high → slow failover. Tune to your storage's worst-case latency.

**Start the stack (all nodes) and enable at boot:**

```bash
$ sudo o2cb register-cluster ocfs2cluster
$ sudo systemctl enable --now o2cb
$ sudo systemctl enable --now ocfs2      # mounts OCFS2 entries from /etc/fstab

$ sudo o2cb cluster-status
Cluster 'ocfs2cluster' is online

$ sudo systemctl status o2cb --no-pager
● o2cb.service - Load o2cb Modules
   Active: active (exited) since ...
```

### 5.3 Formatting — `mkfs.ocfs2`

`-N` sets **node slots** (max simultaneous mounts). `-T` applies a feature template (`mail` = many small files, `datafiles` = few large files with big clusters, `vmstore` = VM images).

```bash
$ sudo mkfs.ocfs2 -N 4 -L "ocfs2vol" \
      --cluster-name=ocfs2cluster --cluster-stack=o2cb \
      /dev/sdc1
mkfs.ocfs2 1.8.7
Cluster stack: o2cb
Cluster name: ocfs2cluster
Stack Flags: 0x0
NTP enabled: no
Overwriting existing ocfs2 partition.
WARNING: Cluster check disabled.
Proceed (y/N): y
Label: ocfs2vol
Features: sparse extended-slotmap backup-super unwritten inline-data strict-journal-super
Features: metaecc xattr indexed-dirs refcount discontig-bg append-dio
Block size: 4096 (12 bits)
Cluster size: 4096 (12 bits)
Volume size: 10733223936 (2620416 clusters) (2620416 blocks)
Cluster groups: 82 (tail covers 5568 clusters, rest cover 32256 clusters)
Extent allocator size: 4194304 (1 groups)
Journal size: 67108864
Node slots: 4
Creating bitmaps: done
Initializing superblock: done
Writing system files: done
Writing superblock: done
Writing backup superblock: 3 block(s)
Formatting Journals: done
Growing extent allocator: done
Formatting slot map: done
Formatting quota files: done
Writing lost+found: done
mkfs.ocfs2 successful
```

`mkfs.ocfs2` key options:

| Option | Meaning |
|---|---|
| `-N n` | Node slots (max concurrent mounts) — grow later with `tunefs.ocfs2 -N` |
| `-J size=…` | Journal size per slot |
| `-b bytes` | Block size (512–4096) |
| `-C bytes` | Cluster (allocation) size (4 KB–1 MB) — large for VM/datafiles |
| `-T mail\|datafiles\|vmstore` | Feature/geometry template |
| `--fs-features=…` | Toggle features (e.g. `+refcount`, `-inline-data`) |
| `--cluster-stack=o2cb\|pcmk` | Which cluster stack this volume trusts |
| `--cluster-name=NAME` | Owning cluster name |
| `-L label` | Volume label |

### 5.4 Mounting

```bash
$ sudo mkdir -p /mnt/ocfs2vol
$ sudo mount -t ocfs2 /dev/sdc1 /mnt/ocfs2vol

# Persistent — note _netdev so it mounts after the network + o2cb:
$ grep ocfs2 /etc/fstab
/dev/sdc1  /mnt/ocfs2vol  ocfs2  _netdev,defaults  0  0

# For the Pacemaker (pcmk) stack instead of O2CB:
$ sudo mount -t ocfs2 -o cluster_stack=pcmk /dev/sdc1 /mnt/ocfs2vol
```

### 5.5 The OCFS2 toolchain

**`o2info` — file system / feature introspection:**

```bash
$ o2info --volinfo /dev/sdc1
        Label: ocfs2vol
         UUID: 7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C
   Block Size: 4096
 Cluster Size: 4096
   Node Slots: 4
     Features: backup-super strict-journal-super sparse extended-slotmap
     Features: inline-data metaecc xattr indexed-dirs refcount discontig-bg
     Features: unwritten append-dio

$ o2info --fs-features /dev/sdc1
backup-super strict-journal-super sparse extended-slotmap inline-data metaecc ...

$ o2info --freefrag /mnt/ocfs2vol      # free-space fragmentation report
```

**`mounted.ocfs2` — who has it, and where:**

```bash
# -d : detect OCFS2 volumes on the system (from disk labels/UUIDs)
$ sudo mounted.ocfs2 -d
Device      Stack  Cluster       F  UUID                              Label
/dev/sdc1   o2cb   ocfs2cluster     7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C  ocfs2vol

# -f : which nodes currently have it mounted (reads the slot map)
$ sudo mounted.ocfs2 -f
Device      Stack  Cluster       F  Nodes
/dev/sdc1   o2cb   ocfs2cluster     node1, node2
```

**`tunefs.ocfs2` — resize, add slots, relabel, toggle features (mostly online):**

```bash
# Grow the FS to fill an enlarged device (after extending the LUN/LV):
$ sudo tunefs.ocfs2 -S /dev/sdc1

# Add node slots so a 5th/6th node can mount:
$ sudo tunefs.ocfs2 -N 6 /dev/sdc1
Changing number of node slots from 4 to 6
Adding node slots: done
Growing extent allocator: done
Formatting Journals: done
Formatting slot map: done
Writing lost+found: done
tunefs.ocfs2 successful

# Relabel; move the volume to the pcmk stack:
$ sudo tunefs.ocfs2 -L "ocfs2prod" /dev/sdc1
$ sudo tunefs.ocfs2 --update-cluster-stack /dev/sdc1     # re-stamp owning stack
```

**`o2image` — save/restore metadata (for support / forensics, like `gfs2_edit savemeta`):**

```bash
$ sudo o2image /dev/sdc1 /root/ocfs2vol.image     # capture metadata only
$ sudo o2image -r /root/ocfs2vol.image /dev/sdd1  # restore metadata to a device
```

**`debugfs.ocfs2` — interactive on-disk debugger (read-only inspection while mounted):**

```bash
$ sudo debugfs.ocfs2 /dev/sdc1
debugfs: stats            # superblock + feature flags
debugfs: slotmap          # which slot each node holds
        Slot#   Node#
            0       0
            1       1
debugfs: stat /somefile   # inode of a path
debugfs: fs_locks -B      # show DLM locks the FS holds (Blocked ones with -B)
debugfs: quit
```

**`fsck.ocfs2` — repair (unmount on ALL nodes first):**

```bash
# Read-only forced check (safe to run on a mounted FS for a quick look):
$ sudo fsck.ocfs2 -fn /dev/sdc1

# Full repair — must be unmounted everywhere:
$ sudo fsck.ocfs2 -fy /dev/sdc1
fsck.ocfs2 1.8.7
Checking OCFS2 filesystem in /dev/sdc1:
  Label:              ocfs2vol
  UUID:               7B5B8F1C2D3E4F5A6B7C8D9E0F1A2B3C
  Number of blocks:   2620416
  Block size:         4096
  Number of clusters: 2620416
  Cluster size:       4096
  Number of slots:    6
/dev/sdc1 was run with -f, check forced.
Pass 0a: Checking cluster allocation chains
Pass 0b: Checking inode allocation chains
Pass 1: Checking inodes and blocks.
Pass 2: Checking directory entries.
Pass 3: Checking directory connectivity.
Pass 4a: checking for orphaned inodes
Pass 4b: Checking inodes link counts.
All passes succeeded.
```

**`o2cluster` — read/repair the cluster stack info stamped on a device:**

```bash
$ sudo o2cluster /dev/sdc1
o2cb,ocfs2cluster,0x0
```

---

## 6. Verification and failure diagnosis

The recurring theme: in a shared-disk cluster FS, **a hang is the file system correctly refusing to corrupt the LUN.** Your job in an incident is to find *which* safety interlock is waiting and *why*.

### 6.1 Healthy-state verification checklist

**Cluster + fencing (GFS2 path):**

```bash
$ sudo pcs status | sed -n '1,20p'
Cluster name: my_cluster
Status of pacemakerd: 'Pacemaker is running'
...
  * Clone Set: locking-clone [locking]:
    * Started: [ node1 node2 ]
  * Clone Set: shared_vg1-clone [shared_vg1]:
    * Started: [ node1 node2 ]

$ sudo pcs property show stonith-enabled
stonith-enabled: true

$ sudo pcs stonith status
  * fence_node1  (stonith:fence_ipmilan): Started node2
  * fence_node2  (stonith:fence_ipmilan): Started node1

# Prove fencing actually works BEFORE you rely on it:
$ sudo pcs stonith history show
We failed reboot node <none> (last known: ...)   # ← empty history is fine; a FAILED here is a red flag
```

**Quorum + membership:**

```bash
$ sudo corosync-quorumtool -s
Quorate:          Yes
Nodes:            2
Node ID           Name
         1        node1
         2        node2

$ sudo corosync-cfgtool -s
Printing link status.
Local node ID 1
LINK ID 0
        addr = 192.168.100.11
        status: 1 1        # both links 'connected'
```

**DLM lockspaces present and populated:**

```bash
$ sudo dlm_tool ls
dlm lockspaces
name          lvm_global
id            0x4104eefa
flags         0x00000000
change        member 2 joined 1 remove 0 failed 0 seq 1,1
members       1 2

name          gfs2demo1
id            0xef7a1234
flags         0x00000008 fs_reg
change        member 2 joined 1 remove 0 failed 0 seq 2,2
members       1 2

$ sudo dlm_tool status
cluster nodeid 1 quorate 1 ring seq 44 44
daemon now 1180 fence_pid 0
node 1 M add 40 rem 0 fail 0 fence 0 at 0 0
node 2 M add 40 rem 0 fail 0 fence 0 at 0 0
```

`members 1 2` on every lockspace and `fence_pid 0` (no fence in progress) is the healthy steady state.

### 6.2 Failure playbook

| Symptom | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| **All nodes' I/O to the FS hangs after a node died** | Fencing not configured or failing → DLM won't recover | `dlm_tool status` shows `fence_pid` ≠ 0 / stuck; `pcs stonith history show` shows FAILED; `journalctl -u pacemaker` "Requesting fencing"→no confirm | Fix STONITH (IPMI creds, network, agent). Once fence succeeds, DLM recovery unblocks and I/O resumes |
| **Mount fails: `Can not mount ... no free journals`** (GFS2) | More nodes than journals | `tunegfs2 -l <dev>` → `Journals:` < node count | `gfs2_jadd -j N /mnt/...` online, then retry mount |
| **Mount fails: `no free slots`** (OCFS2) | More nodes than node slots | `o2info --volinfo <dev>` → `Node Slots:` too low | `tunefs.ocfs2 -N <bigger> <dev>`, retry |
| **`dmesg`: `gfs2: fsid=…: withdrawing from cluster`** | I/O error or metadata inconsistency detected | `dmesg`/`journalctl -k`; the node stopped using the FS to protect it | Unmount on that node (usually reboot); run `fsck.gfs2` **only after unmounting everywhere** |
| **A node spontaneously reboots/panics** (OCFS2, O2CB) | O2CB self-fenced on heartbeat timeout | `dmesg`/console: `o2cb: o2net ... no longer connected` / "self-fencing"; check SAN/network latency vs `O2CB_HEARTBEAT_THRESHOLD` | Fix interconnect/SAN latency; raise threshold if storage is legitimately slow |
| **Mount rejected: lock table / cluster name mismatch** | On-disk `-t clus:fs` ≠ running cluster name | `tunegfs2 -l <dev>` vs. `pcs property show cluster-name` (GFS2); `o2cluster <dev>` vs. `cluster.conf` (OCFS2) | Re-stamp: `tunegfs2 -o locktable=…` / `tunefs.ocfs2 --update-cluster-stack` |
| **Severe, cluster-wide slowness under write load** | Cross-node write contention on the same inodes/rgrps (glock/DLM bouncing) | GFS2: `cat /sys/kernel/debug/gfs2/<fs>/glocks` shows many demote requests; OCFS2: `debugfs.ocfs2 -R 'fs_locks -B' <dev>` shows blocked locks | Partition the workload so hot files/dirs are node-affine; add rgrps; use `noatime` |
| **CLVM/`lvmlockd` VG not visible on a node** | Lockspace not started on that node | `dlm_tool ls` missing the `lvm_*` lockspace; `vgs` doesn't show shared VG | `vgchange --lockstart <vg>` (ensure `lvmlockd`+`dlm` clones are Started) |

### 6.3 Deep DLM inspection

```bash
# Blocked locks in a lockspace (who is waiting on whom):
$ sudo dlm_tool lockdebug gfs2demo1 | grep -i wait

# POSIX/fcntl locks the FS is holding across the cluster:
$ sudo dlm_tool plocks gfs2demo1

# GFS2 glock state (types: 2=inode 3=rgrp 5=iopen). 'W' waiters indicate contention:
$ sudo cat /sys/kernel/debug/gfs2/my_cluster:gfs2demo1/glocks | head
G:  s:SH n:2/1a4 f:Iqob t:SH d:EX/0 a:0 v:0 r:3 m:200
 H: s:SH f:H e:0 p:12345 [df]

# In-kernel DLM debug ring buffer (recovery events, fence waits):
$ sudo dlm_tool dump | tail -30
```

The golden diagnostic sequence for "cluster FS hung": **quorum? → DLM members? → is a fence pending? → did fencing succeed?** In that order. Nine times out of ten the trail ends at a fence that never completed.

---

## 7. Awareness: CephFS, GlusterFS, Lustre

The objective requires you to *recognize* these and know they belong to a different class — **scale-out distributed** file systems — that need no shared LUN and no DLM-style shared-disk fencing.

- **CephFS** — a POSIX file system layered on Ceph's **RADOS** object store. Cluster roles: **MON** (monitors, maintain the cluster map + quorum via Paxos), **OSD** (object storage daemons, one per disk, hold data with replication or erasure coding), and **MDS** (metadata servers, manage the POSIX namespace with dynamic subtree partitioning). Placement is computed by **CRUSH**, so there is no central data lookup. Strength: one cluster serving block (RBD), object (RGW), and file (CephFS) with self-healing redundancy. `ceph -s`, `ceph fs status`.

- **GlusterFS** — a userspace, **FUSE**-mounted scale-out FS with **no metadata server**. Files are placed by an **elastic hashing (DHT)** translator, so there is no metadata bottleneck or SPOF. Volume types: **distributed** (spread), **replicated** (mirrored), **dispersed** (erasure-coded), and combinations. Managed with `gluster volume create/info/status`. Strength: operational simplicity and commodity hardware; weakness: small-file and metadata-heavy latency.

- **Lustre** — the HPC parallel file system behind most of the world's largest supercomputers. Roles: **MGS** (management), **MDS/MDT** (metadata targets), and **OSS/OST** (object storage targets holding striped file data). A single file is striped across many OSTs for aggregate throughput, typically over **RDMA/InfiniBand**. Strength: extreme parallel bandwidth to thousands of clients; weakness: operational complexity and metadata scaling for many small files.

**One-line contrast to anchor the exam:** GFS2/OCFS2 = *many nodes, one shared LUN, DLM + fencing*; CephFS/Gluster/Lustre = *many nodes, many local disks, network replication, no shared LUN*.

---

## 8. References

- LPI — Exam 306 Objectives (306-300, v3.0), Objective 362.3: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux kernel documentation — GFS2: <https://www.kernel.org/doc/html/latest/filesystems/gfs2.html>
- Linux kernel documentation — GFS2 glocks: <https://www.kernel.org/doc/html/latest/filesystems/gfs2-glocks.html>
- Linux kernel documentation — OCFS2: <https://www.kernel.org/doc/html/latest/filesystems/ocfs2.html>
- Linux kernel source — DLM (`fs/dlm`): <https://www.kernel.org/doc/html/latest/filesystems/index.html>
- Red Hat Enterprise Linux 9 — Configuring GFS2 file systems: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/index>
- Red Hat Enterprise Linux 9 — Configuring and managing high availability clusters (DLM, fencing): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index>
- Red Hat — Configuring and managing logical volumes (`lvmlockd`, shared VGs): <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index>
- Oracle Linux — Administering the OCFS2 File System: <https://docs.oracle.com/en/operating-systems/oracle-linux/8/fsadmin/ocfs2.html>
- OCFS2 project documentation (o2cb, tools, cluster.conf): <https://oss.oracle.com/projects/ocfs2/documentation/>
- SUSE Linux Enterprise High Availability — OCFS2 and GFS2 chapters: <https://documentation.suse.com/sle-ha/>
- Ceph documentation — CephFS: <https://docs.ceph.com/en/latest/cephfs/>
- Gluster documentation — Architecture and volume types: <https://docs.gluster.org/en/latest/>
- Lustre documentation — Lustre Manual: <https://doc.lustre.org/lustre_manual.xhtml>
- `mkfs.gfs2(8)`, `gfs2_grow(8)`, `gfs2_jadd(8)`, `fsck.gfs2(8)`, `tunegfs2(8)`, `gfs2_edit(8)`, `dlm_controld(8)`, `dlm_tool(8)`
- `mkfs.ocfs2(8)`, `tunefs.ocfs2(8)`, `fsck.ocfs2(8)`, `mounted.ocfs2(8)`, `o2info(1)`, `o2image(8)`, `o2cb(7)`, `debugfs.ocfs2(8)`, `o2cluster(8)`