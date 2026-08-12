# 362.1 DRBD — Distributed Replicated Block Device

> LPIC-3 306 (Exam 306-300, v3.0) · Topic 362 *Storage Clusters* · Objective weight **10**
> Profile: production-grade replicated block storage for shared-nothing HA clusters.

---

## 1. The architectural problem: shared storage without a SAN

A classic two-node active/passive HA cluster (a PostgreSQL primary, an NFS export, a mail store) needs the **same bytes visible on whichever node currently runs the service**. There are three ways to get there:

1. **Shared physical storage** (FC/iSCSI SAN, dual-ported SAS). The SAN becomes a single point of failure and a single point of *cost*. You are now paying for — and operating — a storage array whose entire job is to not be the SPOF you were trying to eliminate at the compute layer.
2. **Application-level replication** (PostgreSQL streaming replication, MySQL async/semi-sync). Excellent when it exists, but it is per-application, it does not protect files the application does not own (config, WAL archives, the filesystem itself), and every stateful workload needs its own solution.
3. **Block-level replication** — replicate the *device*, below the filesystem, so anything layered on top (ext4/XFS, LVM, a database's raw device, an NFS export) is transparently mirrored across nodes over the network.

**DRBD** (Distributed Replicated Block Device, by LINBIT) is option 3. It is a Linux kernel driver that inserts a virtual block device (`/dev/drbdX`) between the filesystem and a local backing device (`/dev/sdb1`, an LV, an NVMe partition). Every write to `/dev/drbd0` is (a) written to the local backing disk and (b) shipped over TCP/RDMA to one or more peer nodes, which write it to *their* backing disk. The result is a **network RAID-1 (mirror) across machines** — "shared-nothing" storage that behaves like shared storage without any shared hardware.

```
        ┌─────────── node1 (Primary) ───────────┐        ┌─────────── node2 (Secondary) ─────────┐
        │  filesystem / LVM / database           │        │        (device not openable while     │
        │            │                            │        │         Secondary — no local access)  │
        │        /dev/drbd0  ◀── mount here       │        │        /dev/drbd0                      │
        │            │  (DRBD driver)              │        │            │  (DRBD driver)            │
        │      ┌─────┴──────┐                      │  TCP   │      ┌─────┴──────┐                    │
        │      │ local write│───── replicate ──────┼───────▶│      │ local write│                    │
        │      ▼            ▼                      │ :7788  │      ▼            ▼                    │
        │  /dev/sdb1   metadata (AL+bitmap)        │        │  /dev/sdb1   metadata                 │
        └────────────────────────────────────────┘        └───────────────────────────────────────┘
```

### 1.1 The mental model that prevents 90% of mistakes

DRBD has **three orthogonal state axes**. Every diagnosis starts by reading all three:

| Axis | Values (the important ones) | Question it answers |
|---|---|---|
| **Role** | `Primary` / `Secondary` | May this node *open the device for writing*? Only a Primary can be mounted / opened R/W. |
| **Connection state (cstate)** | `Connected`, `WFConnection`, `StandAlone`, `SyncSource`, `SyncTarget`, `Disconnected` | Is the replication link up, and is a resync in flight? |
| **Disk state (dstate)** | `UpToDate`, `Outdated`, `Inconsistent`, `Consistent`, `Diskless`, `DUnknown` | Does *my local backing disk* hold good, current data? |

The single most useful invariant: **`ds:UpToDate/UpToDate` on `cs:Connected` is the only fully healthy steady state.** Anything else is a story about how you got there and what you must do next.

### 1.2 DRBD 8.4 vs DRBD 9 — know which one the exam and your distro give you

LPIC-3 306 (v3.0) is written against **DRBD 9**, but you must recognize DRBD 8.4 idioms because they are everywhere in the field (RHEL 7-era, older Ubuntu).

| | **DRBD 8.4** | **DRBD 9** |
|---|---|---|
| Max replicas per resource | 2 nodes (dual-primary max 2) | up to **32 nodes** per resource; **connection-mesh** |
| Diskless clients | no | yes (a node can be Primary with **no local disk**, pure network client) |
| Status source | **`/proc/drbd`** (text file) | **`drbdadm status` / `drbdsetup status`** (`/proc/drbd` is a stub) |
| Live monitor | `watch cat /proc/drbd` | **`drbdmon`** (curses UI) or `drbdsetup events2` |
| Auto-promote | no (explicit `drbdadm primary`) | **auto-promote** — opening the device promotes it |
| Quorum | no (relies on Pacemaker/fencing) | **built-in quorum** (`quorum majority`) |
| Config `node-id` | implicit | **explicit `node-id`** required for >2 nodes |

> The kernel module in DRBD 9 is called `drbd`; user tools are packaged as `drbd-utils`. `modprobe drbd; cat /proc/drbd` tells you the running version and protocol API.

---

## 2. Replication protocols A, B, C — the core trade-off (heavily examined)

DRBD lets you choose **when a write is acknowledged to the upper layers** relative to how far the replicated copy has travelled. This is *the* latency-vs-durability knob and objective 362.1 tests it directly.

| Protocol | Local write ack'd when… | Data durable against | Latency cost | Data-loss window | Typical use |
|---|---|---|---|---|---|
| **A** (async) | data is on local disk **AND** in the local **TCP send buffer** | local node survives | ~local disk only | Peer may be missing the *last* writes if Primary dies before the buffer drains → **committed writes can be lost on failover** | Long-distance / high-latency WAN links, DR replication where RPO > 0 is acceptable |
| **B** (memory-sync / semi-sync) | data is on local disk **AND** the replication packet has **reached peer RAM** | single-node crash (peer has the data in memory) | +1 network trip (ack, not disk) | Lost only if **both** nodes fail near-simultaneously (peer had it in RAM, not yet on disk) *and* Primary is gone | Rare; MAN links where C's disk-round-trip hurts but you want better-than-A |
| **C** (synchronous) | data is on local disk **AND** confirmed **written to peer disk** | any **single-node** failure — **zero data loss** | +1 network round trip **including remote disk latency** | None for single failures (that is the guarantee) | **Default and correct choice for LAN HA.** Databases, NFS, anything where "committed means committed" |

```
Write(D) issued on Primary
 │
 ├── write D to local backing disk ──────────────┐
 │                                                │
 ├── send D over TCP to peer                      │
 │      │                                         │
 │      ├─ leaves local TCP send buffer  ─► ACK for PROTOCOL A  (async)
 │      │                                         │
 │      ├─ arrives in peer RAM           ─► ACK for PROTOCOL B  (memory sync)
 │      │                                         │
 │      └─ written to peer disk          ─► ACK for PROTOCOL C  (sync)
 │                                                │
 └── upper layer sees write complete when the chosen ACK fires
```

**Rules of thumb enforced in production:**

- Use **C** unless you have measured proof the link latency is intolerable. A synchronous mirror on a 10 GbE LAN adds tens of microseconds; you almost never need A or B on a LAN.
- **A over the WAN** should be paired with **DRBD Proxy** (LINBIT's buffering/compression relay) so a WAN stall does not backpressure the Primary. Raw Protocol A with a small `sndbuf-size` will stall your application when the link hiccups.
- Protocol is **per-connection** in DRBD 9 (you can be C to your LAN peer and A to your DR site in the same resource).

---

## 3. On-disk anatomy: metadata, activity log, and the quick-sync bitmap

Understanding *why* a crash resync is fast (and why an initial sync is slow) requires knowing what DRBD stores alongside your data.

### 3.1 Metadata: internal vs external

| | **Internal metadata** | **External metadata** |
|---|---|---|
| Location | End of the **same** backing device | A **separate** dedicated device |
| Pros | One device to manage; survives together with data | Metadata writes don't contend with data seeks; can improve write throughput on spinning disk |
| Cons | Metadata write ↔ data write head contention (HDD) | Two devices to keep paired; losing the meta device = resync from scratch |
| Sizing | ~36 MiB per 1 TiB of data (must reserve it) | Same size, on its own device |

Internal metadata **shrinks the usable size** of the backing device. If you `mkfs` the whole backing device *first* and *then* try to make it a DRBD resource with internal metadata, `create-md` refuses because the filesystem already claims the tail. Always size the filesystem to the DRBD device, not the backing device.

Metadata contains three things:

1. **Generation Identifiers (GIs / UUIDs)** — `Current-UUID`, `Bitmap-UUID`, and a ring of `History-UUIDs`. DRBD compares these on connect to decide *who is ahead*, *whether a resync is needed*, and *whether this is a split brain*. This is the mechanism, not a detail.
2. **The quick-sync bitmap** — one bit per storage block, marking blocks that are **out of sync** with the peer. A resync copies only the set bits, not the whole device.
3. **The Activity Log (AL)** — a set of "hot" extents (4 MiB each) recently written. After a *crash*, DRBD only needs to resync the AL extents (recently in-flight writes) plus anything the bitmap already marked — not the whole disk. `al-extents` sizes this: bigger AL = better write performance (fewer metadata updates) but a longer post-crash resync.

### 3.2 Generation UUIDs decide everything on reconnect

When two nodes reconnect, DRBD's handshake compares Current-UUID and Bitmap-UUID:

- **Same Current-UUID** → data identical → no resync.
- **One node's Current-UUID equals the other's Bitmap-UUID** → clean parent/child relationship → resync the diff, *direction is unambiguous*.
- **Neither is the other's ancestor** (both mutated independently since they last agreed) → **split brain**. DRBD refuses to auto-pick and, per policy, either disconnects or applies an `after-sb-*` rule (§7).

You can inspect them:

```
$ drbdadm get-gi r0
BB7A1D... :0000000000000000:1B3F...:9C2E...:1:1:1:1:0:0:0
#  Current-UUID    Bitmap-UUID(0)   History...
```

---

## 4. Complete, production configuration

DRBD reads `/etc/drbd.conf`, which by convention just includes the modular tree:

```
/etc/drbd.conf                  → includes global_common.conf and *.res
/etc/drbd.d/global_common.conf  → global {} and common {} (defaults for all resources)
/etc/drbd.d/r0.res              → one resource per file
```

### 4.1 `/etc/drbd.conf`

```conf
# /etc/drbd.conf — do not put resources here; include the modular tree.
include "drbd.d/global_common.conf";
include "drbd.d/*.res";
```

### 4.2 `/etc/drbd.d/global_common.conf`

```conf
global {
    usage-count no;          # do not phone home to LINBIT's usage counter
    udev-always-use-vnr;     # stable /dev/drbd/by-res symlinks per volume
}

common {
    # Defaults inherited by every resource unless overridden.
    protocol C;

    handlers {
        # Fencing/notification hooks. In a Pacemaker cluster, wire these to
        # crm-fence-peer.9.sh so DRBD tells the CRM to fence a lost peer.
        fence-peer       "/usr/lib/drbd/crm-fence-peer.9.sh";
        unfence-peer     "/usr/lib/drbd/crm-unfence-peer.9.sh";
        split-brain      "/usr/lib/drbd/notify-split-brain.sh root";
        out-of-sync      "/usr/lib/drbd/notify-out-of-sync.sh root";
    }

    startup {
        # Wait for the peer at boot, but not forever, so a lone node still boots.
        wfc-timeout      30;   # wait-for-connection
        degr-wfc-timeout 15;   # shorter wait if we were already degraded before reboot
    }

    options {
        # DRBD 9 quorum: a node keeps I/O only while it can see a majority.
        # This is the built-in guard against split-brain data divergence.
        quorum           majority;
        on-no-quorum     io-error;   # freeze/fail I/O rather than diverge
    }

    net {
        # Synchronous replication integrity and split-brain policy.
        protocol         C;
        cram-hmac-alg    sha256;                  # authenticate the peer
        shared-secret    "REPLACE_WITH_A_LONG_RANDOM_SECRET";
        verify-alg       crc32c;                  # for online drbdadm verify
        # Automatic split-brain recovery policy (see §7 for semantics):
        after-sb-0pri    discard-zero-changes;
        after-sb-1pri    discard-secondary;
        after-sb-2pri    disconnect;
        max-buffers      8192;
        rcvbuf-size      2M;
        sndbuf-size      2M;
    }

    disk {
        al-extents       6007;      # larger AL → better random-write perf, longer crash resync
        c-plan-ahead     20;        # enable the dynamic resync-rate controller
        c-min-rate       10M;
        c-max-rate       500M;
        c-fill-target    2M;
        disk-flushes     yes;       # honor barriers; set no ONLY with a BBU-backed controller
        md-flushes       yes;
        on-io-error      detach;    # on a backing-disk error, go Diskless and keep serving from peer
    }
}
```

### 4.3 `/etc/drbd.d/r0.res` — DRBD 9, three-node mesh, LVM-backed

```conf
resource r0 {
    device    /dev/drbd0;
    disk      /dev/vg_data/lv_r0;   # backing LV, identical size on every node
    meta-disk internal;

    net {
        protocol C;                 # synchronous across the LAN mesh
    }

    on node1 {
        node-id 0;
        address 10.20.0.11:7788;
    }
    on node2 {
        node-id 1;
        address 10.20.0.12:7788;
    }
    on node3 {
        node-id 2;
        address 10.20.0.13:7788;
    }

    # Full mesh: every node replicates to every other node.
    connection-mesh {
        hosts node1 node2 node3;
    }
}
```

The equivalent **DRBD 8.4 two-node** resource (no `node-id`, no mesh) for comparison:

```conf
resource r0 {
    protocol C;
    device    /dev/drbd0;
    disk      /dev/vg_data/lv_r0;
    meta-disk internal;

    on node1 { address 10.20.0.11:7788; }
    on node2 { address 10.20.0.12:7788; }
}
```

### 4.4 A DR variant: LAN peer synchronous (C), remote site async (A) with DRBD Proxy

```conf
resource r0 {
    device /dev/drbd0; disk /dev/vg_data/lv_r0; meta-disk internal;

    on node1 { node-id 0; address 10.20.0.11:7788; }
    on node2 { node-id 1; address 10.20.0.12:7788; }
    on dr1   { node-id 2; address 10.90.0.9:7788;  }

    connection {                    # LAN pair: zero-RPO synchronous
        host node1;  host node2;
        net { protocol C; }
    }
    connection {                    # to DR: async through DRBD Proxy
        host node1;  host dr1;
        net { protocol A; }
        # DRBD Proxy buffers/compresses so WAN stalls don't backpressure node1.
        proxy on node1 { inside 127.0.0.1:7789; outside 10.20.0.11:7790; }
        proxy on dr1   { inside 127.0.0.1:7789; outside 10.90.0.9:7790;  }
    }
}
```

---

## 5. Bring-up, day-2 commands, and real terminal output

### 5.1 The three tools and their layers

| Tool | Layer | You use it for |
|---|---|---|
| **`drbdadm`** | High-level, config-aware | Everything day-to-day. Reads `drbd.conf`, expands to the low-level calls. |
| **`drbdsetup`** | Low-level kernel/netlink control | Runtime tuning, `events2`, things `drbdadm` doesn't expose. |
| **`drbdmeta`** | Metadata manipulation | `create-md`, dump/restore, forensics. `drbdadm create-md` calls it. |

Golden rule: **use `drbdadm`**; drop to `drbdsetup`/`drbdmeta` only when you must. `drbdadm -d up r0` (dry-run) prints the exact low-level commands it *would* run — invaluable for learning and debugging.

```
$ drbdadm -d up r0
drbdsetup new-resource r0 0
drbdmeta 0 v09 /dev/vg_data/lv_r0 internal apply-al
drbdsetup new-minor r0 0 0
drbdsetup attach 0 /dev/vg_data/lv_r0 /dev/vg_data/lv_r0 internal
drbdsetup new-peer r0 1 --protocol=C ; drbdsetup new-path r0 1 ipv4:10.20.0.11:7788 ipv4:10.20.0.12:7788
drbdsetup connect r0 1
...
```

### 5.2 First-time initialization (idempotent-safe order)

Run on **both/all** nodes:

```
$ sudo modprobe drbd
$ cat /proc/drbd
version: 9.1.18 (api:2/proto:86-121)

# Create metadata on the backing device (writes the AL, bitmap, and fresh UUIDs)
$ sudo drbdadm create-md r0
initializing activity log
initializing bitmap (320 KB) to all zero
Writing meta data...
New drbd meta data block successfully created.

# Attach + connect the resource (comes up Secondary/Inconsistent everywhere)
$ sudo drbdadm up r0
$ sudo drbdadm status r0
r0 role:Secondary
  disk:Inconsistent
  node2 connection:Connecting
  node3 connection:Connecting
```

Now on **exactly one** node, force it to be the sync source for the very first sync. `--force` is required because *every* node is `Inconsistent` and DRBD will not otherwise let you promote:

```
node1$ sudo drbdadm primary --force r0
```

Watch the initial full sync (this copies the whole device once; subsequent resyncs use the bitmap):

```
node1$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:47.30
  node3 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:47.30
```

Once complete:

```
node1$ drbdadm status r0
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    peer-disk:UpToDate
  node3 role:Secondary
    peer-disk:UpToDate
```

Put a filesystem on it (**only on the Primary**, only when `UpToDate`):

```
node1$ sudo mkfs.xfs /dev/drbd0
node1$ sudo mount /dev/drbd0 /srv/data
```

> **Skip the initial sync** when the backing devices are known-identical (e.g. both freshly zeroed / thin-provisioned): `drbdadm new-current-uuid --clear-bitmap r0/0` on the intended Primary marks both sides `UpToDate` without copying. Never do this on disks with unknown/differing contents.

### 5.3 `/proc/drbd` — DRBD 8.4 output you must be able to read

On 8.4 systems this file *is* the status source:

```
$ cat /proc/drbd
version: 8.4.11-1 (api:1/proto:86-101)
srcversion: 6BB2CF2A3D5C2F5A4E8B1D9

 0: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----
    ns:1048576 nr:0 dw:1048576 dr:1049600 al:8 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:f oos:0
```

Field decode (exam-relevant):

| Field | Meaning |
|---|---|
| `cs:` | connection state (`Connected`) |
| `ro:` | roles, **local/peer** (`Primary/Secondary`) |
| `ds:` | disk states, **local/peer** (`UpToDate/UpToDate`) |
| `C` | active protocol (A/B/C) |
| `ns/nr` | network sent / received (KiB) |
| `dw/dr` | disk write / read (KiB) |
| `al/bm` | activity-log / bitmap metadata updates |
| `pe/ua/ap` | pending / unacknowledged / application-pending requests |
| `wo:` | write ordering (`f`=flush, `d`=drain, `n`=none) |
| **`oos:`** | **out-of-sync KiB — the number you watch during resync; 0 = fully mirrored** |

A **resync in progress** on 8.4 shows a progress bar:

```
 0: cs:SyncTarget ro:Secondary/Primary ds:Inconsistent/UpToDate C r-----
    ns:0 nr:512000 dw:512000 dr:0 al:0 bm:31 lo:0 pe:2 ua:0 ap:0 ep:1 wo:f oos:536576
        [=========>..........] sync'ed: 48.8% (536576/1048576)K
        finish: 0:00:11 speed: 46,592 (46,592) want: 51,200 K/sec
```

### 5.4 DRBD 9 live monitoring

```
$ drbdmon                       # full-screen curses dashboard, auto-refreshes
$ drbdsetup events2 r0          # machine-parseable event stream (for scripting/alerts)
exists resource name:r0 role:Primary suspended:no
exists connection name:r0 peer-node-id:1 conn-name:node2 connection:Connected role:Secondary
exists device name:r0 volume:0 minor:0 disk:UpToDate
exists peer-device name:r0 peer-node-id:1 conn-name:node2 volume:0 replication:Established peer-disk:UpToDate
exists -
```

### 5.5 Routine day-2 commands

```
# Promote / demote (with auto-promote in v9, opening the device promotes for you)
$ sudo drbdadm primary r0
$ sudo drbdadm secondary r0            # must be unmounted first

# Take a resource fully down / up
$ sudo drbdadm down r0
$ sudo drbdadm up r0

# Re-read config and apply changes live (rate, protocol, add a peer)
$ sudo drbdadm adjust r0

# Pause/resume the network without detaching the disk
$ sudo drbdadm disconnect r0
$ sudo drbdadm connect r0

# Detach/attach the backing disk without dropping the peer (e.g. disk swap)
$ sudo drbdadm detach r0
$ sudo drbdadm attach r0

# Online verification: block-by-block checksum compare against the peer
$ sudo drbdadm verify r0
# ...then check oos / dmesg for "Out of sync" ranges, and repair with:
$ sudo drbdadm disconnect r0 && sudo drbdadm connect r0   # triggers resync of flagged blocks

# Grow the device online after growing the backing LV on BOTH nodes
node2$ sudo lvextend -L +50G /dev/vg_data/lv_r0
node1$ sudo lvextend -L +50G /dev/vg_data/lv_r0
node1$ sudo drbdadm resize r0
node1$ sudo xfs_growfs /srv/data
```

---

## 6. Verification and failure diagnosis

### 6.1 Disk-state and connection-state cheat sheet

**Disk states (dstate), best → worst:**

| dstate | Meaning | Action |
|---|---|---|
| `UpToDate` | Current, good data | Healthy |
| `Consistent` | Good data, but peer contact lost before we could confirm we're current | Will become UpToDate/Outdated on reconnect |
| `Outdated` | Data is consistent but *known stale* — a fencing handler marked it so | Must resync from an UpToDate peer before use; **cannot be promoted** |
| `Inconsistent` | Mid-resync or never synced — partial data | Wait for sync; never mount |
| `Diskless` | No usable local backing disk (detached or I/O-errored) | Serving from peer over network; replace/repair disk, `attach` |
| `DUnknown` | Peer's disk state unknown (link down) | Fix the link |

**The reason `Outdated` exists:** fencing. When DRBD loses its peer, the `fence-peer` handler (`crm-fence-peer.9.sh`) asks Pacemaker to mark the *unreachable* peer `Outdated`. A node that is `Outdated` refuses promotion, so two isolated nodes cannot *both* become Primary and diverge. This is the primary defense against split brain in an 8.4 + Pacemaker stack (v9 adds `quorum` on top).

### 6.2 Symptom → cause → fix

| Symptom (`drbdadm status`) | Likely cause | Diagnosis | Fix |
|---|---|---|---|
| `connection:Connecting` forever | firewall on :7788, wrong `address`, `cram-hmac`/`shared-secret` mismatch | `ss -tlnp sport = :7788`; `journalctl -k | grep drbd`; ping peer | open port; align `shared-secret`; `drbdadm adjust r0` |
| `connection:StandAlone` | node deliberately disconnected, or split brain auto-disconnect | `dmesg | grep -i split`; `drbdadm cstate r0` | resolve split brain (§7), then `drbdadm connect r0` |
| `disk:Diskless` unexpectedly | backing disk I/O error → `on-io-error detach` fired | `dmesg`, `smartctl -a /dev/sdb` | replace disk, recreate LV, `drbdadm attach r0` (full resync from peer) |
| `disk:Inconsistent` won't clear | resync stalled (rate too low, link saturated, paused) | `drbdadm status` shows `PausedSyncT`; check `c-min-rate` | `drbdadm resume-sync r0`; raise `c-max-rate`; check NIC/errors |
| `disk:Outdated` after failover | node was fenced/outdated and never resynced | `drbdadm dstate r0` | `drbdadm connect r0` to resync from UpToDate peer |
| Both nodes `Secondary`, nothing mounts | no one promoted (auto-promote off, or Pacemaker not managing) | `drbdadm role r0` | `drbdadm primary r0` (or let the cluster do it) |
| `oos:` non-zero on `Connected` | silent corruption / a bit-rot event surfaced by `verify` | `drbdadm verify r0`; `dmesg | grep "Out of sync"` | `disconnect`+`connect` on the target to resync flagged blocks |

### 6.3 Quorum diagnosis (DRBD 9)

```
$ drbdsetup status --verbose r0
r0 node-id:0 role:Primary suspended:no
  volume:0 minor:0 disk:UpToDate quorum:yes         ◀── watch this
  node2 ... connection:Connected role:Secondary
  node3 ... connection:Connecting                    ◀── one peer lost, still majority (2/3)
```

If `quorum:no` appears with `on-no-quorum io-error`, the Primary will **fail I/O** (EIO to the application) rather than accept writes it cannot safely replicate to a majority — this is deliberate and is what stops a minority partition from diverging. `on-no-quorum suspend-io` instead **freezes** I/O until quorum returns (better for transient partitions; risks hanging the app on a long outage).

---

## 7. Split brain — detection and recovery (the highest-stakes topic)

### 7.1 What it is and how DRBD detects it

**Split brain** = both nodes independently became **Primary** (or independently mutated data) while disconnected, so both hold divergent "current" data with no common ancestor. On reconnect, the UUID handshake finds that neither Current-UUID is the other's ancestor, and DRBD **refuses to auto-merge** — there is no correct automatic merge of two sets of real writes.

```
$ dmesg | grep -i drbd
drbd r0/0 node2: Split-Brain detected but unresolved, dropping connection!
drbd r0/0 node2: conn( NetworkFailure -> StandAlone )
```

Both nodes end up `StandAlone` / `Disconnected`. **No data is lost yet** — but you must choose a **survivor** and a **victim**, and the victim's divergent writes will be discarded.

### 7.2 Automatic policy: the `after-sb-*` options

You pre-declare in `net {}` how DRBD should resolve split brain *automatically*, categorized by how many nodes were Primary at the moment of detection:

**`after-sb-0pri`** (neither is Primary now):
| Value | Behavior |
|---|---|
| `disconnect` | Do nothing automatic — human decides (safest, default-ish) |
| `discard-younger-primary` / `discard-older-primary` | Discard changes on the node that became primary later/earlier |
| `discard-zero-changes` | If exactly one side has changes, keep it; if both changed, disconnect |
| `discard-least-changes` | Keep the side with more changes, resync the other |
| `discard-node-<name>` | Always sacrifice a named node |

**`after-sb-1pri`** (exactly one is Primary):
| Value | Behavior |
|---|---|
| `disconnect` | Human decides |
| `consensus` | Apply the 0pri policy only if both sides agree on the victim; else disconnect |
| `discard-secondary` | The current **Secondary becomes victim** (its data is discarded) — common, safe-ish default |
| `call-pri-lost-after-sb` | Run the `pri-lost-after-sb` handler (often reboots/fences the loser) |

**`after-sb-2pri`** (both Primary — the worst case): usually `disconnect` or `call-pri-lost-after-sb`. **Never** silently auto-discard when both were Primary; you are guaranteed to be throwing away someone's real committed writes.

> Production stance: keep `after-sb-2pri disconnect` and rely on **fencing + quorum** to make 2-primary split brain *impossible* rather than *auto-resolved*. Auto-resolution is a data-loss policy; prevention is better.

### 7.3 Manual recovery (memorize this procedure)

Pick the **survivor** (keeps its data) and the **victim** (discards its divergent writes, resyncs from survivor).

**On the VICTIM:**
```
victim$ sudo umount /srv/data                         # if it was mounted
victim$ sudo drbdadm secondary r0                     # must be Secondary to discard
victim$ sudo drbdadm disconnect r0
victim$ sudo drbdadm connect --discard-my-data r0
```

**On the SURVIVOR:**
```
survivor$ sudo drbdadm connect r0                     # (only needed if it went StandAlone)
```

DRBD now resyncs the victim from the survivor. Verify:

```
victim$ drbdadm status r0
r0 role:Secondary
  disk:Inconsistent
  survivor role:Primary
    replication:SyncTarget peer-disk:UpToDate done:73.10
# → converges to peer-disk:UpToDate / disk:UpToDate
```

**8.4 phrasing** is identical in spirit; the discard flag is the same:
```
victim(8.4)$ drbdadm secondary r0
victim(8.4)$ drbdadm connect --discard-my-data r0
survivor(8.4)$ drbdadm connect r0
```

### 7.4 Preventing split brain (the real fix)

1. **Fencing (STONITH) in Pacemaker** + DRBD's `fence-peer "crm-fence-peer.9.sh"` and `fencing resource-and-stonith;` in `disk {}`. A node that can't confirm its peer is dead cannot become Primary.
2. **DRBD 9 quorum** (`quorum majority; on-no-quorum io-error;`) — a minority partition fails I/O and cannot create divergent writes.
3. **A redundant, independent replication link** (bonded NICs / separate switch) so a single network fault doesn't partition the cluster in the first place.
4. **Never run dual-primary** unless you have a cluster-aware filesystem (GFS2/OCFS2) *and* fencing — dual-primary without those is a split-brain generator.

---

## 8. Pacemaker integration — the `ocf:linbit:drbd` resource agent

DRBD supplies the raw replicated device; **Pacemaker** decides *which node is Primary* and co-locates the mount + service there. DRBD is modeled as a **promotable (master/slave) clone**: the "Master" role maps to DRBD `Primary`, "Slave" to `Secondary`.

### 8.1 crmsh configuration (modern promotable clone)

```
# DRBD device managed by the linbit RA
primitive p_drbd_r0 ocf:linbit:drbd \
    params drbd_resource=r0 \
    op monitor interval=29s role=Promoted \
    op monitor interval=31s role=Unpromoted \
    op start   timeout=240s \
    op stop    timeout=100s \
    op promote timeout=90s \
    op demote  timeout=90s

# Promotable clone: at most one Primary, one copy per node
clone ms_drbd_r0 p_drbd_r0 \
    meta promotable=true promoted-max=1 promoted-node-max=1 \
         clone-max=2 clone-node-max=1 notify=true

# Filesystem mounts ONLY where DRBD is Primary
primitive p_fs_r0 ocf:heartbeat:Filesystem \
    params device=/dev/drbd0 directory=/srv/data fstype=xfs \
    op monitor interval=20s timeout=40s

# The service that uses the data
primitive p_pgsql ocf:heartbeat:pgsql \
    params pgdata=/srv/data/pgsql \
    op monitor interval=15s

# Ordering + colocation: FS follows the DRBD Master, service follows the FS
order   o_drbd_before_fs   Mandatory: ms_drbd_r0:promote p_fs_r0:start
colocate co_fs_on_master   inf: p_fs_r0 ms_drbd_r0:Promoted
order   o_fs_before_pgsql  Mandatory: p_fs_r0 p_pgsql
colocate co_pgsql_with_fs  inf: p_pgsql p_fs_r0
```

> On **DRBD 8.4 / older Pacemaker**, the same intent is written with `ms ms_drbd_r0 p_drbd_r0 meta master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true` and the role keywords `Master`/`Slave` instead of `Promoted`/`Unpromoted`. Know both spellings.

### 8.2 What the RA guarantees, and the fencing tie-in

- `notify=true` is **mandatory** — the RA relies on pre/post promote/demote notifications to coordinate.
- The RA integrates with DRBD's `fence-peer` handler so that during a partition, DRBD marks the unreachable peer `Outdated`, and Pacemaker refuses to promote an `Outdated` node. Combined with STONITH, this closes the split-brain window at the cluster layer.
- Verify from the cluster side:

```
$ sudo crm status
  * Clone Set: ms_drbd_r0 [p_drbd_r0] (promotable):
    * Promoted: [ node1 ]
    * Unpromoted: [ node2 ]
  * p_fs_r0     (ocf:heartbeat:Filesystem):  Started node1
  * p_pgsql     (ocf:heartbeat:pgsql):       Started node1

$ sudo crm_resource --resource ms_drbd_r0 --locate
resource ms_drbd_r0 is running on: node1 Promoted
```

---

## 9. Performance tuning quick reference

| Knob (`disk`/`net`) | Effect | Guidance |
|---|---|---|
| `protocol` | A/B/C durability vs latency | C on LAN; A+Proxy on WAN |
| `al-extents` | Activity-log size | Higher (e.g. 6007) for random-write DB workloads; costs longer crash resync |
| `c-plan-ahead` (>0) | Enables **dynamic resync controller** | Keep on; lets resync back off under app load |
| `c-min-rate` / `c-max-rate` | Resync throttle floor/ceiling | Set `c-max-rate` below link saturation so resync doesn't starve the app |
| `c-fill-target` | Target in-flight resync data | Tune up on high-BDP links |
| `max-buffers` / `sndbuf-size` / `rcvbuf-size` | Network buffering | Raise on 10/25/40 GbE to keep the pipe full |
| `disk-flushes` / `md-flushes` | Honor write barriers | Leave `yes` unless you have a **battery/flash-backed** controller — turning off without one risks corruption on power loss |
| `read-balancing` | Serve reads from a peer | Can offload a busy Primary in v9 |

**Measure, don't guess:** the classic method is to benchmark the raw backing device, then the DRBD device disconnected, then connected — the deltas isolate replication overhead from disk and network. `disk-flushes no` on a system without a BBU is the single most common cause of "DRBD ate my database after a power cut."

---

## 10. References (official sources)

- **LPI — Exam 306 Objectives (306-300, v3.0), Topic 362.1 DRBD:** https://www.lpi.org/our-certifications/exam-306-objectives/
- **LINBIT — The DRBD User's Guide (9.0):** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
- **LINBIT — DRBD User's Guide (8.4):** https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/
- **DRBD configuration file — `drbd.conf(5)`:** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-drbdconf
- **`drbdadm(8)` / `drbdsetup(8)` / `drbdmeta(8)` man pages:** https://linbit.com/man/ (see also `man drbdadm` on-system)
- **Replication protocols A/B/C:** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-replication-protocols
- **Split brain notification and recovery:** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-resolve-split-brain
- **DRBD quorum:** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#s-feature-quorum
- **Integrating DRBD with Pacemaker (`ocf:linbit:drbd`):** https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#ch-pacemaker
- **DRBD source, `drbd-utils`, and man pages:** https://github.com/LINBIT/drbd-utils
- **ClusterLabs — Pacemaker + DRBD reference:** https://clusterlabs.org/pacemaker/doc/