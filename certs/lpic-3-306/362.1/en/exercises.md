# Guided Exercises — Topic 362.1: DRBD

> **Lab topology used throughout.** Two nodes named `node1` (`10.0.0.1`) and `node2` (`10.0.0.2`), each with a spare, *identical-sized*, unused block device `/dev/sdb`. We build one DRBD 9 resource `r0` exporting the replicated block device `/dev/drbd0`. Run commands as `root`. Unless a step says "on node1" or "on node2", run it on **both** nodes.
>
> These exercises assume DRBD 9 with `drbd-utils` (the `drbdadm`/`drbdsetup`/`drbdmeta` family). Where DRBD 8.4 differs in a way the exam cares about, it is called out. Real command output is shown; your byte counts, UUIDs and sync percentages will differ.

---

## Exercise 1 — Backing storage, kernel module, and packages

The single most common cause of a failed `create-md` is stale filesystem or partition-table signatures on the backing device. DRBD stores its own metadata on that device (or an adjacent one) and refuses to clobber data it recognizes. We prepare a clean partition first.

1. Confirm the backing block device exists and is **not mounted or in an LVM/RAID set** — DRBD sits *below* the filesystem, so its backing device must be raw:

   ```bash
   lsblk /dev/sdb
   ```
   ```
   NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
   sdb    8:16   0   4G  0 disk
   ```

2. Create a single partition `/dev/sdb1` spanning the device (using internal metadata later, DRBD will carve its metadata out of the tail of this partition):

   ```bash
   parted -s /dev/sdb mklabel gpt
   parted -s /dev/sdb mkpart primary 0% 100%
   partprobe /dev/sdb
   ```

3. Wipe any leftover signatures so `create-md` does not balk:

   ```bash
   wipefs -a /dev/sdb1
   ```

4. Install DRBD user-space tools and load the kernel module. On a RHEL-family node with ELRepo, or on Debian/Ubuntu:

   ```bash
   # Debian/Ubuntu
   apt-get install -y drbd-utils
   # RHEL/Rocky/Alma (ELRepo kmod)
   # dnf install -y kmod-drbd9x drbd9x-utils

   modprobe drbd
   lsmod | grep drbd
   ```
   ```
   drbd                  704512  0
   lru_cache              20480  1 drbd
   libcrc32c              16384  1 drbd
   ```

5. Confirm the loaded module version and utils version (they must be compatible — DRBD 9 utils talk to a DRBD 9 module):

   ```bash
   cat /proc/drbd
   drbdadm --version
   ```
   ```
   version: 9.2.11 (api:2/proto:86-122)
   ...
   DRBDADM_BUILDTAG=GIT-hash:...
   DRBDADM_API_VERSION=2
   DRBD_KERNEL_VERSION_CODE=0x090200
   ```

**Comprehension check**

- **Q1.** DRBD replicates at which layer of the storage stack — above the filesystem, or below it — and what does that imply about whether you `mkfs` the backing device `/dev/sdb1` or the `/dev/drbd0` device?
- **Q2.** Why does `create-md` fail if `/dev/sdb1` still contains an ext4 or LVM signature, and which one-line command removed that risk in step 3?
- **Q3.** You see `version: 9.2.11 (api:2/...)` from `cat /proc/drbd` but `drbdadm --version` reports API version 1. What is wrong and why will `drbdadm up` likely fail?

---

## Exercise 2 — Write the resource configuration

DRBD configuration lives in `/etc/drbd.conf`, which by convention only `include`s the global settings (`/etc/drbd.d/global_common.conf`) and per-resource files (`/etc/drbd.d/*.res`). **The configuration must be byte-identical on both nodes** — `drbdadm` parses the same file on each host and selects the local stanza by matching the node's hostname.

1. Inspect the default includes in `/etc/drbd.conf`:

   ```bash
   cat /etc/drbd.conf
   ```
   ```
   include "drbd.d/global_common.conf";
   include "drbd.d/*.res";
   ```

2. Create `/etc/drbd.d/r0.res` **identically on both nodes**:

   ```ini
   resource r0 {
       device    /dev/drbd0;
       disk      /dev/sdb1;
       meta-disk internal;

       net {
           protocol C;
       }

       on node1 {
           address   10.0.0.1:7788;
           node-id   0;
       }
       on node2 {
           address   10.0.0.2:7788;
           node-id   1;
       }

       connection-mesh {
           hosts node1 node2;
       }
   }
   ```

3. Validate the syntax and see how DRBD expands macros into the low-level `drbdsetup` calls it will run — this never touches disk:

   ```bash
   drbdadm dump r0        # parse + pretty-print the effective config
   drbdadm sh-resources   # list resources DRBD knows about
   ```
   ```
   # /etc/drbd.d/r0.res
   resource r0 {
       on node1 { ... node-id 0; ... }
       on node2 { ... node-id 1; ... }
       ...
   }
   r0
   ```

4. Confirm the hostnames actually match the `on` stanzas — a mismatch is the classic "why is DRBD ignoring my config" bug:

   ```bash
   uname -n     # must print exactly node1 (or node2)
   ```

**Comprehension check**

- **Q4.** What does `meta-disk internal;` mean physically, and by roughly how much does it reduce the space available to your filesystem on a 4 GiB backing device?
- **Q5.** `drbdadm dump r0` succeeds, but on `node2` the command reports "Missing section 'on `node2`'" while running fine on `node1`. Given the config is byte-identical, what single host-level fact is wrong on `node2`?
- **Q6.** Which line selects the *replication protocol*, and where must it live for it to apply to the peer connection?

---

## Exercise 3 — Create metadata and attach the resource

1. Create the DRBD metadata on the backing device (run on **both** nodes):

   ```bash
   drbdadm create-md r0
   ```
   ```
   initializing activity log
   initializing bitmap (128 KB) to all zero
   Writing meta data...
   New drbd meta data block successfully created.
   ```

2. Bring the resource up. `drbdadm up` is a convenience that runs *attach* (bind `/dev/drbd0` to `/dev/sdb1`) and *connect* (open the TCP replication link) in one shot:

   ```bash
   drbdadm up r0
   ```

3. Check the state on **both** nodes. Right after `up`, before any sync, *both* sides are `Secondary` and their disks are `Inconsistent` — DRBD does not yet know which copy is authoritative:

   ```bash
   drbdadm status r0
   ```
   ```
   r0 role:Secondary
     disk:Inconsistent
     node2 connection:Connected role:Secondary
       peer-disk:Inconsistent
   ```

4. If instead you see `connection:Connecting` on both nodes, the peers cannot reach each other. Diagnose the transport before proceeding:

   ```bash
   drbdadm cstate r0          # Connecting  => link not established
   ss -tlnp | grep 7788       # is DRBD listening on the replication port?
   ping -c1 10.0.0.2          # L3 reachability
   # check firewall: TCP 7788 must be open between the two nodes
   ```

**Comprehension check**

- **Q7.** Immediately after `drbdadm up` on both nodes, *both* disks are `Inconsistent`. Why is that the correct and expected state, rather than a bug — and what would happen to your data if DRBD guessed a source and synced automatically here?
- **Q8.** `drbdadm up` is equivalent to which two lower-level `drbdadm` subcommands run in sequence?
- **Q9.** Both nodes show `connection:Connecting` and never reach `Connected`. List two distinct layers you would check, and the command for each.

---

## Exercise 4 — Initial full synchronization and first promotion

We now declare one node the source of truth. This is the **only** time you use `--force` on a healthy cluster: it tells DRBD "overwrite the peer with my data," which is exactly what you want when both copies are empty.

1. On **node1 only**, force it to Primary to seed the initial sync:

   ```bash
   # node1
   drbdadm primary --force r0
   ```
   > DRBD 8.4 equivalent: `drbdadm -- --overwrite-data-of-peer primary r0`

2. Watch the resync progress. `node1` becomes `SyncSource`, `node2` becomes `SyncTarget`:

   ```bash
   # node1
   drbdadm status r0
   ```
   ```
   r0 role:Primary
     disk:UpToDate
     node2 role:Secondary
       replication:SyncSource peer-disk:Inconsistent done:41.37
   ```

3. Wait for completion (or poll `drbdsetup events2 r0` for a live stream). When done, both disks read `UpToDate`:

   ```bash
   drbdadm status r0
   ```
   ```
   r0 role:Primary
     disk:UpToDate
     node2 role:Secondary
       peer-disk:UpToDate
   ```

**Comprehension check**

- **Q10.** During the initial sync, `node1` disk is already `UpToDate` while `node2` is `Inconsistent`. Can you safely `mkfs` and mount `/dev/drbd0` on `node1` *before* the sync finishes? Why or why not?
- **Q11.** Why is `--force` (overwrite-data-of-peer) safe here but dangerous if you ran it on an established, in-service cluster?
- **Q12.** What is the difference in meaning between the disk state `Inconsistent` and the disk state `Outdated`?

---

## Exercise 5 — Filesystem, failover, and proving replication

DRBD gives you a shared-nothing replicated block device; a **single-primary** DRBD resource may be mounted on only one node at a time (mounting an ext4/xfs on both simultaneously would corrupt it — that requires a cluster filesystem, see Exercise 10).

1. On **node1** (the Primary), format `/dev/drbd0` — never the backing `/dev/sdb1`:

   ```bash
   # node1
   mkfs.ext4 /dev/drbd0
   mkdir -p /srv/data
   mount /dev/drbd0 /srv/data
   echo "written on node1 at $(date)" > /srv/data/proof.txt
   sync
   ```

2. Perform a clean, manual failover. On **node1**, unmount and demote:

   ```bash
   # node1
   umount /srv/data
   drbdadm secondary r0
   ```

3. On **node2**, promote and mount — the file written on node1 must be present:

   ```bash
   # node2
   drbdadm primary r0
   mkdir -p /srv/data
   mount /dev/drbd0 /srv/data
   cat /srv/data/proof.txt
   ```
   ```
   written on node1 at Wed Aug 12 10:14:52 UTC 2026
   ```

4. Fail back the same way (unmount + `secondary` on node2, `primary` + mount on node1).

**Comprehension check**

- **Q13.** Why must you `umount` **before** `drbdadm secondary` on the outgoing node, and what error does DRBD return if the device is still mounted when you try to demote it?
- **Q14.** In single-primary mode, why can you not simply mount `/dev/drbd0` on both nodes to get shared read-write access, even though the blocks are replicated?
- **Q15.** You promoted `node2` and the file was there — which DRBD guarantee (tied to `protocol C`) makes it certain that every byte acknowledged to the application on node1 had already reached node2's disk?

---

## Exercise 6 — Reading states: role, connection, disk

Fluency in DRBD's three orthogonal state axes is directly tested. **Role** (Primary/Secondary) is about who may write; **connection state** is about the replication link; **disk state** is about how current the local data is.

1. Query each axis individually:

   ```bash
   drbdadm role r0        # Primary | Secondary
   drbdadm cstate r0      # Connected | Connecting | StandAlone
   drbdadm dstate r0      # UpToDate | Outdated | Inconsistent | Diskless | ...
   ```

2. Get the full, statistics-rich view from `drbdsetup` (this is what `drbdadm status --verbose --statistics` wraps):

   ```bash
   drbdsetup status r0 --verbose --statistics
   ```
   ```
   r0 node-id:0 role:Primary suspended:no
     volume:0 minor:0 disk:UpToDate quorum:yes
         size:4190108 read:0 written:1024 al-writes:1 bm-writes:0 ...
     node2 node-id:1 connection:Connected role:Secondary congested:no
       volume:0 replication:Established peer-disk:UpToDate
   ```

3. On DRBD 8.4 (or for a quick legacy glance) the same information appears in `/proc/drbd`:

   ```bash
   cat /proc/drbd
   ```
   ```
   0: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----
   ```

**Comprehension check**

- **Q16.** Decode `ro:Primary/Secondary ds:UpToDate/UpToDate` from `/proc/drbd`: which side of each slash is the local node, and what does the `C` after the states mean?
- **Q17.** A node reports `role:Secondary cstate:StandAlone dstate:UpToDate`. Is its data usable, and can its peer currently receive replicated writes from it? Explain each part.
- **Q18.** Which single axis would you check to answer "is my replication link healthy right now?" — role, connection state, or disk state?

---

## Exercise 7 — Replication protocols A, B, and C

The protocol governs *when* a write is acknowledged to the upper layer, trading durability for latency. It is set per-connection in the `net {}` section.

1. Read the current protocol:

   ```bash
   drbdadm dump r0 | grep -i protocol
   ```
   ```
   protocol C;
   ```

2. Temporarily switch the running connection to protocol A **on both nodes** without editing files, to observe behavior (this is a live `drbdsetup` change):

   ```bash
   drbdadm net-options --protocol=A r0
   drbdadm cstate r0     # still Connected; protocol changed live
   ```

3. Revert to the durable default and reload from the file:

   ```bash
   drbdadm net-options --protocol=C r0
   ```

**Comprehension check**

- **Q19.** State precisely when a local write is acknowledged to the application under each protocol:
  - **A** (asynchronous)
  - **B** (memory synchronous / semi-synchronous)
  - **C** (synchronous)
- **Q20.** Your two nodes are in different data centers 40 ms apart. Which protocol keeps application write latency low, and exactly what data-loss window do you accept in return if the primary's site is destroyed mid-write?
- **Q21.** Which protocol is required if you want the guarantee that "a write acknowledged to the application survives the immediate, total loss of the primary node"?

---

## Exercise 8 — Online device verification

DRBD can compare the two copies block-by-block *while the resource is in service*, detecting silent corruption (bit rot, a bad disk controller) that normal replication would not catch because both copies are written independently.

1. Enable a verify algorithm in `/etc/drbd.d/r0.res` inside `net {}` (both nodes), then reload:

   ```ini
   net {
       protocol   C;
       verify-alg sha256;
   }
   ```
   ```bash
   drbdadm adjust r0     # apply config delta to the running resource
   ```

2. Start an online verification from the Primary:

   ```bash
   # node1 (Primary)
   drbdadm verify r0
   ```

3. Watch for out-of-sync blocks; a clean run reports zero. Any mismatch is logged to the kernel ring buffer:

   ```bash
   drbdsetup status r0 --statistics | grep -i out-of-sync
   dmesg | grep -i drbd | tail
   ```
   ```
   [ ... ] drbd r0/0 drbd0 node2: Online verify done (total 12 sec; ... )
   [ ... ] drbd r0/0 drbd0 node2: Online verify found 0 out-of-sync blocks
   ```

4. If verification *did* find out-of-sync blocks, force a resync of just those blocks by disconnecting and reconnecting the connection (DRBD 9 marks them in the bitmap during verify):

   ```bash
   drbdadm disconnect r0
   drbdadm connect r0
   ```

**Comprehension check**

- **Q22.** Both disks show `UpToDate` yet online verify finds out-of-sync blocks. How is that possible if replication was working — what class of fault does verify catch that the normal write path does not?
- **Q23.** Why does verification require a `verify-alg` to be configured on **both** nodes, and what does that algorithm actually compute?
- **Q24.** After a verify finds mismatches, does DRBD repair them automatically, and what did step 4 do to trigger the repair?

---

## Exercise 9 — Split brain: cause, detection, and recovery

Split brain occurs when *both* nodes were independently promoted to Primary while disconnected, so each accumulated writes the other never saw. DRBD detects this on reconnection, refuses to auto-merge, and drops to `StandAlone` to protect data. Recovery means *choosing a victim whose divergent changes are discarded*.

1. **Provoke a split brain (lab only).** Cut the link, then promote both sides so each writes independently:

   ```bash
   # node1
   drbdadm disconnect r0
   drbdadm primary r0
   echo "node1 side change" >> /srv/data/split.txt   # node1 mounted+primary

   # node2 (still had the resource up) — force it Primary too
   drbdadm primary --force r0
   mount /dev/drbd0 /srv/data
   echo "node2 side change" >> /srv/data/split.txt
   ```

2. Try to reconnect. DRBD detects the divergence and refuses to merge, landing in `StandAlone`:

   ```bash
   drbdadm connect r0
   drbdadm cstate r0
   dmesg | grep -i "Split-Brain"
   ```
   ```
   StandAlone
   [ ... ] drbd r0 node2: Split-Brain detected but unresolved, dropping connection!
   ```

3. **Recover.** Decide which node's divergent writes to *sacrifice* (here `node2`). On the **victim (node2)** — demote and discard its data:

   ```bash
   # node2  (the victim / loser)
   umount /srv/data 2>/dev/null
   drbdadm disconnect r0
   drbdadm secondary r0
   drbdadm connect --discard-my-data r0
   ```

4. On the **survivor (node1)** — reconnect as the authoritative side:

   ```bash
   # node1  (the survivor / winner)
   drbdadm connect r0
   ```

5. Confirm the link healed; the victim re-syncs from the survivor and returns to `UpToDate`:

   ```bash
   drbdadm status r0
   ```
   ```
   r0 role:Primary
     disk:UpToDate
     node2 role:Secondary
       peer-disk:UpToDate
   ```

**Comprehension check**

- **Q25.** Why does DRBD deliberately choose to sit in `StandAlone` rather than automatically picking a winner and merging, when it detects split brain?
- **Q26.** In the recovery, exactly what does `--discard-my-data` do, and on which node — the survivor or the victim — must it be run? What happens to the data written on the victim during the split?
- **Q27.** The `after-sb-0pri`, `after-sb-1pri`, and `after-sb-2pri` handlers exist to *automate* this decision. What does the number in each (`0pri`/`1pri`/`2pri`) count, and why is `after-sb-2pri disconnect;` the only safe default for the two-primary case?
- **Q28.** What single operational practice — enforced by a cluster manager like Pacemaker with STONITH — prevents split brain from occurring in the first place?

---

## Exercise 10 — Dual-primary mode (advanced)

Two simultaneous Primaries are only valid when the layer above DRBD coordinates concurrent access — i.e. a cluster filesystem such as OCFS2 or GFS2, or a live VM migration path. Enabling it under a normal ext4/xfs mount **will corrupt the filesystem.**

1. Enable two primaries in `net {}` and configure the split-brain auto-handlers (both nodes), then adjust:

   ```ini
   net {
       protocol            C;
       allow-two-primaries yes;
       after-sb-0pri       discard-zero-changes;
       after-sb-1pri       discard-secondary;
       after-sb-2pri       disconnect;
   }
   ```
   ```bash
   drbdadm adjust r0
   ```

2. Promote **both** nodes to Primary:

   ```bash
   # node1
   drbdadm primary r0
   # node2
   drbdadm primary r0
   drbdadm status r0
   ```
   ```
   r0 role:Primary
     disk:UpToDate
     node2 role:Primary
       peer-disk:UpToDate
   ```

3. Only now mount a **cluster** filesystem (e.g. `mount -t ocfs2 /dev/drbd0 /srv/data` on both), never a single-node filesystem.

**Comprehension check**

- **Q29.** Why is `allow-two-primaries yes` insufficient on its own to safely share the device — what must exist *above* DRBD, and what breaks if you mount ext4 on both Primaries?
- **Q30.** Name one legitimate production use of dual-primary mode where the two Primaries exist only briefly.

---

## Exercise 11 — Handing control to Pacemaker (integration overview)

In production you do not promote/demote by hand; the cluster resource manager does it as part of orchestrated failover, gated by fencing (STONITH). This exercise reads-only; do not run it against a hand-managed resource in service.

1. Ensure DRBD is *not* started by the OS and *not* left Primary — Pacemaker must own it:

   ```bash
   systemctl disable drbd
   drbdadm secondary r0
   drbdadm down r0
   ```

2. Define DRBD as a **promotable clone** in Pacemaker using the `ocf:linbit:drbd` agent (run once, from any node):

   ```bash
   pcs resource create drbd_r0 ocf:linbit:drbd drbd_resource=r0 \
       op monitor interval=15s role=Promoted \
       op monitor interval=30s role=Unpromoted
   pcs resource promotable drbd_r0 promoted-max=1 promoted-node-max=1 \
       clone-max=2 clone-node-max=1 notify=true
   ```

3. Colocate the filesystem/service with the Promoted (Primary) DRBD instance and order it after promotion:

   ```bash
   pcs constraint colocation add fs_data with Promoted drbd_r0-clone INFINITY
   pcs constraint order promote drbd_r0-clone then start fs_data
   ```

**Comprehension check**

- **Q31.** Why must you `systemctl disable drbd` and hand promotion to Pacemaker rather than letting both start it and race?
- **Q32.** In Pacemaker terms, DRBD is modeled as a *promotable clone*: what do the "Promoted" and "Unpromoted" roles map to in DRBD's own vocabulary?
- **Q33.** Why is STONITH/fencing not optional in a DRBD + Pacemaker cluster — which failure mode from Exercise 9 does it exist to prevent?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** DRBD sits **below** the filesystem — it presents a virtual block device `/dev/drbd0` layered on top of the backing device `/dev/sdb1`. You therefore run `mkfs` on `/dev/drbd0`, never on `/dev/sdb1`. Formatting the backing device directly would bypass replication and overwrite DRBD's metadata.

**Q2.** With `meta-disk internal`, DRBD writes its metadata into the tail of `/dev/sdb1`, and `create-md` inspects the device for known signatures (ext4, LVM, prior DRBD metadata) so it does not silently destroy live data. `wipefs -a /dev/sdb1` removed those signatures, letting `create-md` proceed.

**Q3.** The user-space `drbd-utils` and the loaded kernel module are version-mismatched (utils API 1 vs. a DRBD 9 module advertising API 2). The `drbdadm`/`drbdsetup` binaries speak a netlink API the running module does not, so bring-up (`drbdadm up`) fails. Fix by installing DRBD 9-compatible utils (or loading a matching module).

**Q4.** `internal` means the metadata (activity log + bitmap + superblock) lives on the *same* backing device, carved out of its tail, rather than on a separate device. It consumes roughly 32 KiB per configured node plus bitmap space — on the order of a few MiB — so your usable filesystem is slightly smaller than the raw partition. (The trade-off vs. `external` metadata is one fewer device to manage, at the cost of losing the "activity log on a separate spindle" performance option.)

**Q5.** `node2`'s hostname (`uname -n`) does not equal the string `node2` used in the `on node2 { ... }` stanza. `drbdadm` selects the local stanza by exact hostname match, so on that host it finds no matching `on` section. Fix the hostname (or the stanza name) so they agree exactly.

**Q6.** `protocol C;` selects the replication protocol. It must live in the `net {}` section (or be inherited from `common {}`), because the protocol is a property of the *connection* to the peer, not of the local disk.

**Q7.** Both disks are `Inconsistent` because neither has been declared authoritative yet — DRBD has no basis to know which of two freshly-initialized copies is the "real" data. This is correct and protective: if DRBD auto-picked a source and synced, and you had picked the wrong side later, it would have overwritten the copy you actually wanted. You break the tie explicitly with `drbdadm primary --force`.

**Q8.** `drbdadm up r0` = `drbdadm attach r0` (bind `/dev/drbd0` to the backing device and metadata) **followed by** `drbdadm connect r0` (establish the TCP replication link to the peer).

**Q9.** (1) **L3/transport:** `ping` the peer address, check `ss -tlnp | grep 7788` that DRBD is listening, and verify the firewall allows TCP 7788 between nodes. (2) **Config/identity:** `drbdadm dump r0` and confirm both nodes' `address`/`node-id`/hostnames are consistent, and that both peers actually ran `drbdadm up`.

**Q10.** Yes. `node1` is Primary with `UpToDate` disk, meaning its own copy is fully valid and writable; the ongoing sync only pushes those (and new) blocks to `node2`. You may format, mount, and use `/dev/drbd0` on node1 during the initial sync. What you must *not* do is fail over to `node2` until its disk reaches `UpToDate`, because until then node2's copy is `Inconsistent` and unusable.

**Q11.** Here both copies are empty, so "overwrite the peer" discards nothing of value. On an in-service cluster, `--force`/overwrite-data-of-peer would unconditionally declare the local node the source and blow away whatever the peer holds — if the peer actually had the newer/only good copy, that data is gone.

**Q12.** `Inconsistent` means the local copy is *partial/unusable* — a sync is in progress or was interrupted, so the data cannot be relied upon or promoted. `Outdated` means the copy is *internally consistent and complete but known to be stale* — it was good as of the last time it was connected, but the peer has since advanced. An Outdated node can be promoted in an emergency (you get old-but-coherent data); an Inconsistent one generally cannot.

**Q13.** DRBD will not demote a device that is open for writing. If `/dev/drbd0` is still mounted, `drbdadm secondary r0` fails with a "Device is held open by someone" / "State change failed: (-12) Device is held open" error. Unmounting closes the last writer so the role change can proceed.

**Q14.** The blocks are replicated, but a normal filesystem (ext4/xfs) caches metadata and assumes it is the sole writer; two independent mounts would issue conflicting, uncoordinated writes and corrupt the filesystem. Safe concurrent read-write access requires a *cluster* filesystem (OCFS2/GFS2) plus dual-primary DRBD — the cluster FS provides the distributed locking that plain ext4 lacks.

**Q15.** Protocol C is *synchronous*: a write is acknowledged to the application only after it has reached **both** the local disk and the peer's disk. So every write the application on node1 considered complete was already durably on node2 before failover.

**Q16.** The **local** node is always on the **left** of each slash. `ro:Primary/Secondary` = local is Primary, peer is Secondary. `ds:UpToDate/UpToDate` = both disks current. The trailing `C` is the active replication protocol (C = synchronous).

**Q17.** Data is usable: `dstate:UpToDate` means the local copy is complete and current, and being Secondary just means it is not currently writable by an application. But `cstate:StandAlone` means the replication link is intentionally down (no peer connection), so it is **not** replicating to or from the peer — the peer receives nothing until you `connect` again.

**Q18.** The **connection state** (`cstate`) answers link health: `Connected` = healthy, `Connecting` = trying/unreachable, `StandAlone` = deliberately disconnected. (Role is about who writes; disk state is about data currency.)

**Q19.**
- **A (async):** acknowledged as soon as the write hits the *local* disk and has been *placed in the local TCP send buffer* — it does not wait for the peer.
- **B (semi-sync / memory-synchronous):** acknowledged once the write is on local disk **and** the peer has *received it into memory* (but not necessarily written it to disk).
- **C (sync):** acknowledged only after the write is on local disk **and** on the peer's *disk*.

**Q20.** Protocol **A** keeps latency low over a 40 ms link because it does not wait for the remote round-trip. The accepted data-loss window is: any writes that were acknowledged locally but still sitting in the TCP send buffer / in flight (not yet on node2) when the primary's site is lost. Those acknowledged-but-unreplicated writes are gone.

**Q21.** Protocol **C** — only C guarantees the write was on the peer's *disk* before acknowledgment, so an acknowledged write survives the immediate total loss of the primary.

**Q22.** Both disks being `UpToDate` only means each accepted every replicated write; it does not mean the bytes on the two spindles are still identical. Independent, silent, *post-write* corruption on one side — bit rot, a flaky controller/cable, a firmware bug — changes data underneath DRBD without any write passing through it. Online verify recomputes and compares digests, catching exactly this divergence.

**Q23.** Both nodes need the same `verify-alg` because verification is a *distributed* digest comparison: the source computes a hash (e.g. SHA-256) of each block range and sends the digest; the target computes the same hash over its copy and compares. Without a matching algorithm on both sides, they cannot agree on what to compute or how to compare.

**Q24.** No — verify only *detects and marks* out-of-sync blocks in the bitmap; it does not repair them, precisely so you can decide the direction. Step 4's `disconnect` then `connect` triggers a resync of the bitmap-marked blocks from the current SyncSource, overwriting the mismatched blocks on the target and restoring identity.

**Q25.** Because there is no safe automatic answer: each Primary holds writes the other never saw, so *any* merge or auto-pick silently discards real, acknowledged data. Dropping to `StandAlone` freezes both copies intact and forces a human (or a pre-declared policy) to choose which divergent set to sacrifice, rather than losing data invisibly.

**Q26.** `--discard-my-data` tells DRBD "throw away *this* node's divergent changes and re-sync from the peer." It is run on the **victim/loser** (here node2), while the survivor runs a plain `connect`. All data written on the victim during the split-brain window is discarded and overwritten by the survivor's copy.

**Q27.** The number counts how many nodes were **Primary** at the moment the split brain occurred: `0pri` = neither was Primary during the split, `1pri` = exactly one was, `2pri` = both were. `after-sb-2pri disconnect;` is the only safe default for the both-Primary case because when both sides took writes as Primary, there is no criterion to automatically decide whose writes to destroy — so DRBD stays disconnected and demands a manual decision.

**Q28.** **Fencing (STONITH)** driven by a cluster manager: before a node is allowed to become/stay Primary, the peer that might also be Primary is forcibly powered off or isolated, so two live Primaries can never accumulate divergent writes.

**Q29.** `allow-two-primaries yes` only lets DRBD *accept* writes on both nodes; it provides no coordination between them. A **cluster filesystem** (OCFS2/GFS2) with distributed locking must sit above DRBD to serialize concurrent access. Mounting plain ext4/xfs on both Primaries corrupts it, because each mount caches and mutates filesystem metadata assuming it is the sole writer.

**Q30.** Live migration of a virtual machine between two hosts: both DRBD sides are briefly Primary so the VM's disk is writable on source and destination during the memory/state handoff, after which the source is demoted. (Another accepted answer: a clustered/parallel filesystem like OCFS2/GFS2 for genuinely concurrent access.)

**Q31.** If both the OS init and Pacemaker start and promote the resource, they race and can end up promoting both nodes independently — recreating the split-brain condition. Disabling the `drbd` service makes Pacemaker the single authority that decides who is Promoted, gated by ordering and fencing.

**Q32.** Pacemaker's **Promoted** role = DRBD **Primary**; **Unpromoted** role = DRBD **Secondary**. The promotable clone runs one Secondary/Unpromoted instance per node and promotes exactly one to Primary/Promoted (`promoted-max=1`).

**Q33.** Without fencing, when the two nodes lose contact but both are alive, Pacemaker on each side may conclude the other is dead and promote its own DRBD instance — producing two Primaries and the split brain of Exercise 9. STONITH guarantees the "other" node is provably off before promotion, so only one Primary can ever exist. It is therefore mandatory, not optional.

</details>

---

### Sources

- LPI Exam 306 Objectives (306-300, v3.0), objective 362.1 "DRBD" — https://www.lpi.org/our-certifications/exam-306-objectives/
- LINBIT, *The DRBD 9.0 User's Guide* (architecture, `drbdadm`/`drbdsetup`/`drbdmeta`, resource states, replication protocols, split-brain recovery, dual-primary) — https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/
- LINBIT, *DRBD and Pacemaker* integration chapter (promotable clone, `ocf:linbit:drbd`, fencing) — https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/#ch-pacemaker
- `drbdadm(8)`, `drbdsetup(8)`, `drbd.conf(5)` man pages — https://linbit.com/man/