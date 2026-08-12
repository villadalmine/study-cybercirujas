# Clustered File Systems (GFS2 & OCFS2) — Guided Exercises

> **Objective 362.3 — Clustered File Systems** (Exam 306-300, v3.0)
> Configure and maintain GFS2 and OCFS2 file systems on shared storage, including the underlying Distributed Lock Manager (DLM) and cluster-stack integration.

These exercises assume a **two-node Pacemaker/Corosync cluster** (`node1`, `node2`) that is already **quorate and fenced** (STONITH enabled). Shared block storage is exposed identically to both nodes as `/dev/sdb` (e.g. via iSCSI, FC, or a hypervisor shared disk). Run every command as `root`. Where a step must run on *both* nodes it is labelled `[all nodes]`; otherwise run it on `node1`.

> ⚠️ **Fencing is not optional here.** A cluster file system lets multiple kernels write the same blocks concurrently, coordinated only by the DLM. If a node stops responding but its I/O is still in flight, the *only* safe recovery is to physically cut it off (fence/STONITH). Without working fencing, the DLM will block recovery forever — the file system hangs on purpose rather than corrupt your data.

---

## Exercise 1 — Cluster file-system principles and the DLM

**Goal:** observe why a shared-disk file system needs distributed locking, and inspect the DLM that provides it.

1. Confirm the cluster is healthy and quorate before touching storage:

   ```bash
   pcs status --full | head -n 20
   corosync-quorumtool -s
   ```

   Expected (abridged):

   ```
   Quorum information
   ------------------
   Date:             Wed Aug 12 10:14:02 2026
   Quorum provider:  corosync_votequorum
   Nodes:            2
   Node ID:          1
   Ring ID:          1.2a
   Quorate:          Yes

   Votequorum information
   ----------------------
   Expected votes:   2
   Highest expected: 2
   Total votes:      2
   Quorum:           1
   Flags:            2Node Quorate WaitForAll
   ```

2. Verify STONITH is enabled — the DLM refuses to recover a failed node without it:

   ```bash
   pcs property show stonith-enabled
   pcs stonith status
   ```

3. Load and inspect the DLM kernel module `[all nodes]`:

   ```bash
   modprobe dlm
   lsmod | grep -E '^dlm'
   ```

4. Look at what a shared-disk file system fundamentally differs from. Contrast a *network* file system (NFS: one server owns the metadata) with a *shared-disk cluster* file system (every node reads/writes the same blocks directly). Note which layer arbitrates concurrent access in each model.

**Comprehension questions (1):**

- **1a.** In a shared-disk cluster file system such as GFS2 or OCFS2, what component prevents two nodes from modifying the same on-disk metadata simultaneously, and what does the acronym DLM stand for?
- **1b.** Why must STONITH/fencing be configured *before* a cluster file system can safely recover from a node failure? What happens to file-system I/O on the surviving node if a failed node cannot be fenced?
- **1c.** Give one architectural reason a cluster file system does **not** scale the same way as a scale-out/parallel file system (e.g. why you would not deploy GFS2 across 100 nodes).

---

## Exercise 2 — Building the DLM + clustered LVM stack in Pacemaker

**Goal:** create the ordered/cloned resources that must exist on every node before any GFS2 mount. GFS2's `lock_dlm` protocol talks to `dlm_controld`; the shared VG is coordinated by `lvmlockd`.

1. Create the `dlm` clone. `ocf:pacemaker:controld` starts `dlm_controld`. `on-fail=fence` is mandatory — a DLM failure must escalate to fencing:

   ```bash
   pcs resource create dlm ocf:pacemaker:controld \
       op monitor interval=30s on-fail=fence \
       clone interleave=true ordered=true
   ```

2. Enable shared-VG locking `[all nodes]`, then create the `lvmlockd` clone:

   ```bash
   # [all nodes] enable the lock daemon in lvm.conf
   lvmconfig --type full global/use_lvmlockd
   sed -i 's/^\(\s*\)use_lvmlockd = 0/\1use_lvmlockd = 1/' /etc/lvm/lvm.conf

   pcs resource create lvmlockd ocf:heartbeat:lvmlockd \
       op monitor interval=30s on-fail=fence \
       clone interleave=true ordered=true
   ```

3. Order the stack so `lvmlockd` starts *after* `dlm`, and colocate them so they run together:

   ```bash
   pcs constraint order start dlm-clone then lvmlockd-clone
   pcs constraint colocation add lvmlockd-clone with dlm-clone
   ```

4. Create a **shared** volume group and a logical volume on the shared disk:

   ```bash
   vgcreate --shared vg_cluster /dev/sdb        # run once, on node1
   ```

   ```bash
   # [all nodes] each node must start the lockspace for the shared VG
   vgchange --lock-start vg_cluster
   ```

   ```bash
   lvcreate --activate sy -L 20G -n lv_gfs2 vg_cluster   # 'sy' = shared active
   ```

5. Confirm the DLM is now aware of the cluster and check for lockspaces:

   ```bash
   dlm_tool status
   dlm_tool ls
   ```

   Expected `dlm_tool status` (abridged):

   ```
   cluster nodeid 1 quorate 1 ring seq 42 42
   daemon now 1837 fence_pid 0
   node 1 M add 4 rem 0 fail 0 fence 0 at 0 0
   node 2 M add 5 rem 0 fail 0 fence 0 at 0 0
   ```

**Comprehension questions (2):**

- **2a.** Why are `dlm` and `lvmlockd` deployed as **cloned** resources with `interleave=true`, rather than as ordinary single-instance resources?
- **2b.** What is the practical effect of `lvcreate --activate sy` (shared activation) versus the default exclusive activation, and why does a file system like GFS2 require the shared mode across nodes?
- **2c.** The `dlm` resource uses `op monitor ... on-fail=fence`. Explain why `on-fail=fence` (rather than `restart` or `stop`) is the correct policy for the DLM specifically.

---

## Exercise 3 — Creating and mounting a GFS2 file system

**Goal:** format the shared LV with `lock_dlm`, mount it on both nodes via a cloned Pacemaker `Filesystem` resource, and verify concurrent access.

1. Inspect the corosync cluster name — the GFS2 **lock table** must use it exactly:

   ```bash
   pcs property show cluster-name
   # or:
   grep cluster_name /etc/corosync/corosync.conf
   ```

   Assume the cluster is named `alpha`.

2. Create the GFS2 file system. The lock table is `<cluster_name>:<fs_name>`, `-p lock_dlm` selects the distributed lock protocol, and `-j 3` pre-allocates **three journals** (one per node that will mount concurrently, plus a spare):

   ```bash
   mkfs.gfs2 -p lock_dlm -t alpha:web -j 3 -J 128 /dev/vg_cluster/lv_gfs2
   ```

   Expected output:

   ```
   /dev/vg_cluster/lv_gfs2 is a symbolic link to /dev/dm-3
   This will destroy any data on /dev/dm-3
   Are you sure you want to proceed? [y/n] y
   Device:                    /dev/vg_cluster/lv_gfs2
   Block size:                4096
   Device size:               20.00 GB (5242880 blocks)
   Filesystem size:           20.00 GB (5242878 blocks)
   Journals:                  3
   Journal size:              128MB
   Resource groups:           80
   Locking protocol:          "lock_dlm"
   Lock table:                "alpha:web"
   UUID:                      9b1a2c3d-4e5f-6789-abcd-ef0123456789
   ```

3. Register the mount as a **cloned** Pacemaker resource so it mounts on every node, ordered after `lvmlockd`:

   ```bash
   pcs resource create web_fs ocf:heartbeat:Filesystem \
       device="/dev/vg_cluster/lv_gfs2" directory="/mnt/web" fstype="gfs2" \
       options="noatime,nodiratime" \
       op monitor interval=10s on-fail=fence \
       clone interleave=true

   pcs constraint order start lvmlockd-clone then web_fs-clone
   pcs constraint colocation add web_fs-clone with lvmlockd-clone
   ```

4. Verify it is mounted on both nodes and that the DLM created a lockspace named after the file system:

   ```bash
   mount | grep gfs2
   dlm_tool ls
   cat /proc/mounts | grep /mnt/web
   ```

   Expected `dlm_tool ls` (abridged):

   ```
   dlm lockspaces
   name          web
   id            0x7e5c3f2a
   flags         0x00000008 fs_reg
   change        member 2 joined 1 remove 0 failed 0 seq 2,2
   members       1 2
   ```

5. Prove concurrency: write from `node1`, read instantly from `node2`:

   ```bash
   # node1
   echo "written from $(hostname) at $(date)" > /mnt/web/handshake.txt
   ```

   ```bash
   # node2
   cat /mnt/web/handshake.txt
   ```

6. Inspect GFS2's runtime tunables and per-mount state under sysfs:

   ```bash
   ls /sys/fs/gfs2/alpha:web/
   cat /sys/fs/gfs2/alpha:web/tune/statfs_slow 2>/dev/null
   ```

**Comprehension questions (3):**

- **3a.** The lock table was given as `alpha:web`. What are the two components separated by the colon, and what breaks — and with what symptom — if the first component does not match the Corosync `cluster_name`?
- **3b.** You created the file system with `-j 3` but the cluster has two nodes. Why might you deliberately allocate more journals than current nodes, and what command would you use *later* to add a journal without reformatting?
- **3c.** Why is the `Filesystem` resource created as a **clone** rather than a normal resource, and what would go wrong if you mounted a `lock_dlm` GFS2 file system on a node whose `dlm`/`lvmlockd` clones were not running?

---

## Exercise 4 — GFS2 maintenance: journals, growth, tuning, and repair

**Goal:** grow the file system online, add a journal for a third node, adjust metadata with `tunegfs2`, and understand offline repair with `fsck.gfs2`.

1. Extend the underlying LV, then grow GFS2 **online** (run on any single node that has it mounted):

   ```bash
   lvextend -L +10G /dev/vg_cluster/lv_gfs2
   gfs2_grow /mnt/web
   df -h /mnt/web
   ```

   Expected `gfs2_grow` output:

   ```
   FS: Mount point:             /mnt/web
   FS: Device:                  /dev/dm-3
   FS: Size:                    5242878 (0x4ffffe)
   DEV: Length:                 7864320 (0x780000)
   The file system grew by 10240MB.
   gfs2_grow complete.
   ```

2. Add a fourth journal so a newly-joined `node3` can mount (run on a mounted node):

   ```bash
   gfs2_jadd -j 1 /mnt/web
   ```

   Expected:

   ```
   Filesystem: /mnt/web
   Old journals: 3
   New journals: 4
   ```

3. Inspect and modify persistent superblock fields with `tunegfs2` (formerly part of `gfs2_tool`). Listing is safe online; **changing** the lock protocol/table requires the file system **unmounted on all nodes**:

   ```bash
   tunegfs2 -l /dev/vg_cluster/lv_gfs2
   ```

   Expected:

   ```
   tunegfs2 (device /dev/vg_cluster/lv_gfs2)
   File system volume name: alpha:web
   File system UUID: 9b1a2c3d-4e5f-6789-abcd-ef0123456789
   File system magic number: 0x1161970
   Block size: 4096
   Block shift: 12
   Root inode: 65627
   Lock protocol: lock_dlm
   Lock table: alpha:web
   ```

   To rename the file system to `alpha:webnew` (offline only):

   ```bash
   pcs resource disable web_fs        # unmount on all nodes
   tunegfs2 -o locktable=alpha:webnew /dev/vg_cluster/lv_gfs2
   pcs resource enable web_fs
   ```

4. Understand offline repair. `fsck.gfs2` must run with the file system **unmounted everywhere** — never on a mounted or half-mounted volume:

   ```bash
   pcs resource disable web_fs                 # unmount on all nodes first
   fsck.gfs2 -y /dev/vg_cluster/lv_gfs2
   pcs resource enable web_fs
   ```

5. Examine on-disk metadata for forensic debugging with `gfs2_edit` (read-only inspection here):

   ```bash
   gfs2_edit -p sb /dev/vg_cluster/lv_gfs2        # print the superblock
   gfs2_edit -p journals /dev/vg_cluster/lv_gfs2  # list journal locations
   ```

**Comprehension questions (4):**

- **4a.** You ran `lvextend` then `gfs2_grow`. Why is that two steps rather than one, and can `gfs2_grow` *shrink* a GFS2 file system? What is the correct order of the two commands and why?
- **4b.** `gfs2_jadd -j 1` was run while the file system was mounted. Why is adding a journal an **online** operation, whereas `fsck.gfs2` must be run fully **offline** on every node?
- **4c.** A colleague ran `fsck.gfs2` on a device that was still mounted on `node2`. What class of damage does this risk, and what single check should always precede `fsck.gfs2` in a cluster?

---

## Exercise 5 — OCFS2 with the o2cb cluster stack

**Goal:** stand up OCFS2 using its native `o2cb` stack (independent of Pacemaker), format and mount it, then manage node slots and inspect it with the OCFS2 tool family.

1. Install and load the OCFS2 tools/module `[all nodes]`:

   ```bash
   modprobe ocfs2
   which mkfs.ocfs2 o2cb o2info mounted.ocfs2 tunefs.ocfs2 debugfs.ocfs2 fsck.ocfs2
   ```

2. Create `/etc/ocfs2/cluster.conf` **identically on both nodes** `[all nodes]`. Node `name` must match `uname -n`; `number` values must be unique and stable:

   ```ini
   cluster:
           heartbeat_mode = local
           node_count = 2
           name = ocfs2cluster

   node:
           number = 0
           cluster = ocfs2cluster
           ip_port = 7777
           ip_address = 10.0.0.1
           name = node1

   node:
           number = 1
           cluster = ocfs2cluster
           ip_port = 7777
           ip_address = 10.0.0.2
           name = node2
   ```

   > Indentation in `cluster.conf` uses **tabs**, and each stanza is terminated by a blank line. A missing tab or blank line makes `o2cb` silently ignore the node.

3. Bring the o2cb stack online `[all nodes]`:

   ```bash
   o2cb register-cluster ocfs2cluster
   o2cb start-heartbeat ocfs2cluster
   service o2cb online ocfs2cluster        # or: systemctl start o2cb
   o2cb cluster-status
   ```

4. Format the shared device for OCFS2. `-N 4` pre-allocates **4 node slots**, `-L` sets the label, and `-T mail` tunes for many small files (alternatives: `datafiles`, `vmstore`):

   ```bash
   mkfs.ocfs2 -N 4 -L web-ocfs2 --cluster-stack=o2cb \
       --cluster-name=ocfs2cluster --fs-features=backup-super,xattr /dev/sdc1
   ```

   Expected (abridged):

   ```
   mkfs.ocfs2 1.8.7
   Cluster stack: o2cb
   Cluster name: ocfs2cluster
   Label: web-ocfs2
   Block size: 4096 (12 bits)
   Cluster size: 4096 (12 bits)
   Node slots: 4
   Creating bitmaps: done
   Writing superblock: done
   mkfs.ocfs2 successful
   ```

5. Mount on both nodes `[all nodes]` and confirm the volume and its members:

   ```bash
   mkdir -p /srv/ocfs2 && mount -t ocfs2 /dev/sdc1 /srv/ocfs2

   mounted.ocfs2 -d          # detect OCFS2 volumes on the system
   mounted.ocfs2 -f          # full: which nodes have it mounted
   ```

   Expected `mounted.ocfs2 -f`:

   ```
   Device                FS     Nodes
   /dev/sdc1             ocfs2  node1, node2
   ```

6. Query the volume with `o2info`:

   ```bash
   o2info --volinfo /dev/sdc1
   o2info --fs-features /dev/sdc1
   o2info --freeinode /dev/sdc1
   ```

   Expected `--volinfo`:

   ```
           Label: web-ocfs2
            UUID: 1A2B3C4D5E6F70819A2B3C4D5E6F7081
      Block Size: 4096
    Cluster Size: 4096
     Node Slots: 4
        Features: backup-super strict-journal-super sparse extended-slotmap
        Features: inline-data xattr indexed-dirs refcount discontig-bg
   ```

**Comprehension questions (5):**

- **5a.** OCFS2 was configured with the native `o2cb` stack and its own `cluster.conf`, whereas GFS2 relied on Pacemaker + DLM. What are the two cluster stacks OCFS2 can use, and what does `--cluster-stack=pcmk` change about the deployment?
- **5b.** In `cluster.conf`, why must the node `name` equal `uname -n` exactly, and why must the file be byte-identical (same node numbers) on every node?
- **5c.** `mkfs.ocfs2 -N 4` set four node slots. What is a "node slot" in OCFS2, what does each slot own, and what happens if you try to mount on more nodes than there are slots?

---

## Exercise 6 — OCFS2 tuning, diagnostics, and failure handling

**Goal:** grow the number of node slots online, inspect metadata with `debugfs.ocfs2`, and understand offline repair and DLM-driven recovery.

1. Increase node slots from 4 to 6 online with `tunefs.ocfs2` (needed before a 5th/6th node can mount):

   ```bash
   tunefs.ocfs2 -N 6 /dev/sdc1
   o2info --volinfo /dev/sdc1 | grep 'Node Slots'
   ```

2. Relabel and toggle a feature (features may require the volume unmounted):

   ```bash
   tunefs.ocfs2 -L web-shared /dev/sdc1
   tunefs.ocfs2 --fs-features=usrquota,grpquota /dev/sdc1
   ```

3. Inspect internal structures interactively with `debugfs.ocfs2` — the OCFS2 analogue of `debugfs`:

   ```bash
   debugfs.ocfs2 -R "stats" /dev/sdc1 | head -n 20
   debugfs.ocfs2 -R "slotmap" /dev/sdc1
   debugfs.ocfs2 -R "ls -l //" /dev/sdc1        # the system directory
   ```

   Expected `slotmap`:

   ```
       Slot#   Node#
           0       0
           1       1
   ```

4. Capture full metadata for offline analysis with `o2image` (does not touch data blocks):

   ```bash
   o2image /dev/sdc1 /root/web-ocfs2.o2img
   ls -lh /root/web-ocfs2.o2img
   ```

5. Understand offline repair. `fsck.ocfs2` must run with the volume **unmounted on all nodes**; `-f` forces a full check, `-y` auto-answers yes:

   ```bash
   umount /srv/ocfs2                  # [all nodes] — must be unmounted everywhere
   fsck.ocfs2 -fy /dev/sdc1
   ```

   Expected (abridged):

   ```
   fsck.ocfs2 1.8.7
   Checking OCFS2 filesystem in /dev/sdc1:
     Label:              web-shared
     UUID:               1A2B3C4D5E6F70819A2B3C4D5E6F7081
     Number of blocks:   2621440
     Bytes per block:    4096
     Number of clusters: 2621440
     Number of slots:    6
   /dev/sdc1 was run with -f, check forced.
   Pass 0a: Checking cluster allocation chains
   Pass 1: Checking inodes and blocks.
   ...
   All passes succeeded.
   ```

6. Simulate a node failure to observe recovery. Fence/reboot `node2` while a write is in progress on `node1`, then watch OCFS2's journal recovery replay `node2`'s slot:

   ```bash
   # node1 — start a continuous write
   dd if=/dev/zero of=/srv/ocfs2/bigfile bs=1M count=2048 &

   # from another host, hard-power-cycle node2 (or: pcs stonith fence node2)

   # node1 — observe recovery in the kernel log
   dmesg -w | grep -iE 'ocfs2|recover'
   ```

   Expected kernel messages:

   ```
   ocfs2: Begin replay journal (node 1, slot 1) on device (8,33)
   ocfs2: End replay journal (node 1, slot 1) on device (8,33)
   ocfs2: Beginning quota recovery on device (8,33) for slot 1
   ocfs2: Finishing quota recovery on device (8,33) for slot 1
   ```

**Comprehension questions (6):**

- **6a.** `tunefs.ocfs2 -N 6` increased the node slots online. Why can OCFS2 add slots without unmounting, and why can slot count only ever be **increased**, never easily decreased in place?
- **6b.** When `node2` was fenced, `node1` logged "replay journal (slot 1)". In your own words, describe what journal replay recovers and why the *surviving* node performs it rather than the dead one.
- **6c.** Match each diagnostic tool to what it inspects: `o2info`, `mounted.ocfs2`, `debugfs.ocfs2`, `o2image`, `fsck.ocfs2`. Which of these are safe on a mounted volume and which demand it be unmounted?

---

## Answers

<details>
<summary>Click to reveal answers to all comprehension questions</summary>

### Exercise 1

**1a.** The **Distributed Lock Manager (DLM)** arbitrates concurrent access. In this stack it runs in-kernel and is coordinated in userspace by `dlm_controld` (started by the `ocf:pacemaker:controld` resource). Every metadata or data lock a node wants (a "glock" in GFS2 terms, a lock resource in OCFS2) is granted cluster-wide by the DLM, so two nodes can never hold conflicting write locks on the same object. **DLM = Distributed Lock Manager.**

**1b.** A cluster file system allows *every* node to write directly to the shared blocks. If a node crashes or hangs with dirty I/O outstanding, the DLM cannot know whether that node's in-flight writes have completed, so it **cannot safely release the dead node's locks**. STONITH/fencing resolves this by forcibly powering off (or isolating) the failed node — once fencing confirms the node is dead, the DLM releases its locks and recovery/journal replay proceeds. Without working fencing, the surviving node's I/O **blocks indefinitely** (the mount appears hung) because releasing the locks prematurely could corrupt the file system. This is why the `dlm` resource uses `on-fail=fence`.

**1c.** A shared-disk cluster file system uses a *symmetric* design where every node participates in a single distributed lock domain over one shared device. Every lock acquisition/release generates cross-node DLM traffic, and lock/recovery coordination cost grows with node count, so throughput on hot metadata degrades as nodes are added. It is designed for a **small number of nodes** (typically ≤16–32) sharing one storage LUN, not for hundreds of nodes — that is the domain of scale-out/parallel or distributed object file systems (Ceph, GlusterFS, Lustre) which partition data and metadata across servers instead of sharing one block device.

### Exercise 2

**2a.** DLM and lock management must be **running on every node** that participates in the file system, and they must recover in lock-step with cluster membership changes. A **clone** runs one instance of the resource on each node; `interleave=true` means the ordered start/stop relationship is evaluated **per node** rather than waiting for *all* copies of the dependency across the whole cluster. That lets a single node bring up its `dlm → lvmlockd → Filesystem` chain independently, which is essential for clean join/leave behaviour and avoids one slow node stalling the entire clone set.

**2b.** `--activate sy` (shared activation) activates the LV in **shared mode** so it can be active simultaneously on multiple nodes — which is exactly what a cluster file system needs, since all nodes mount the same LV at once. The default (exclusive, `-ay`/`ey`) allows activation on only **one** node at a time and is correct for a non-clustered file system like ext4/XFS on shared storage (active-passive). GFS2/OCFS2 require shared activation because concurrent multi-node mounting is the whole point; exclusive activation would prevent the second node from activating the LV.

**2c.** The DLM is the arbiter that guarantees data integrity. If `dlm_controld` fails on a node, that node can no longer participate safely in the lock domain, yet it may still have the file system mounted and dirty I/O in flight. **Restarting** the daemon locally does not resolve the outstanding-I/O uncertainty for the rest of the cluster, and merely **stopping** the resource leaves the node in an ambiguous state. The only safe resolution is to **fence** the node — remove it entirely so the remaining nodes can recover its locks and journals deterministically. Hence `on-fail=fence`.

### Exercise 3

**3a.** The lock table `alpha:web` is `<cluster_name>:<filesystem_name>`. The first field (`alpha`) **must match the Corosync `cluster_name`**; it tells `lock_dlm`/`dlm_controld` which cluster's lock domain to join. The second field (`web`) is the file-system's unique name (and becomes the DLM lockspace / sysfs directory name). If the first field does **not** match the Corosync cluster name, the mount **fails** — the kernel cannot join a lockspace for a cluster it is not a member of, and you get a mount error such as `error mounting lockproto lock_dlm` / "gfs_controld join connect error" in `dmesg`.

**3b.** Each node that mounts a GFS2 file system **consumes one journal**; GFS2 cannot dynamically create journals on the fly at mount time. Pre-allocating extra journals (`-j 3` on a 2-node cluster) leaves headroom so a third node can join and mount **without** reformatting. To add a journal later, run **`gfs2_jadd -j <n> <mountpoint>`** on a node where the file system is mounted (and after extending the device if there is no free space).

**3c.** The `Filesystem` resource is a **clone** because the file system must be mounted **concurrently on all nodes** — that is the definition of a cluster file system in active-active use; a plain resource would mount it on only one node. If you tried to mount a `lock_dlm` GFS2 without `dlm`/`lvmlockd` running, the mount would **fail or hang**: `lock_dlm` cannot reach `dlm_controld` to join the lockspace, so the kernel has no way to acquire locks. This is why the ordering constraints force `dlm → lvmlockd → Filesystem`.

### Exercise 4

**4a.** `lvextend` grows the **block device** (the LV); `gfs2_grow` then grows the **file system** to fill the newly available space. They are separate because the volume manager and the file system are separate layers. The correct order is **`lvextend` first, then `gfs2_grow`** — you must have the extra block space present before the file system can expand into it. **`gfs2_grow` can only grow, never shrink** a GFS2 file system; there is no supported online (or offline) shrink for GFS2, so size-down requires backup, reformat, and restore.

**4b.** Adding a journal (`gfs2_jadd`) allocates new metadata into free space and registers it while the file system is live and the DLM protects the operation — it does not require exclusive/offline access, so it is **online**. `fsck.gfs2`, by contrast, must have **exclusive** access to check and rewrite arbitrary metadata consistently; if any node had the file system mounted, that node could modify blocks underneath the checker, so `fsck.gfs2` requires the file system **unmounted on every node**.

**4c.** Running `fsck.gfs2` on a device still mounted elsewhere risks **catastrophic metadata corruption**: the checker and the live kernel both write metadata with no coordination (fsck does not go through the DLM), producing cross-linked inodes, lost blocks, or an unmountable file system. The mandatory pre-check is to **confirm the file system is unmounted on all nodes** (e.g. `pcs resource disable` the clone, then verify with `mount`/`mounted`/`dlm_tool ls` on every node) before invoking `fsck.gfs2`.

### Exercise 5

**5a.** OCFS2 supports two cluster stacks: the native **`o2cb`** stack (its own `cluster.conf`, `o2cb` service and heartbeat, independent of Pacemaker) and the **`pcmk`** stack, which integrates OCFS2 with **Pacemaker + the kernel DLM** (`ocf:pacemaker:controld`), the same infrastructure GFS2 uses. `--cluster-stack=pcmk` (with `--cluster-name` = the Pacemaker cluster) makes OCFS2 use Pacemaker for membership/fencing and the DLM for locking instead of the standalone `o2cb` heartbeat — preferred when you already run a Pacemaker cluster so fencing and membership are unified.

**5b.** OCFS2's `o2cb` stack identifies each node by its `name`, which it resolves against the local hostname; if `name` ≠ `uname -n`, the node cannot recognise itself in `cluster.conf` and **fails to join** the cluster. The file must be **byte-identical (same node numbers, IPs, ports) on every node** because each node uses the same map to identify peers and to index the disk heartbeat/slot map; mismatched node numbers or membership between nodes causes split-brain-style inconsistencies and mount/heartbeat failures.

**5c.** A **node slot** is a per-node reservation inside the OCFS2 volume — each slot owns its **own journal** (and quota recovery area). A node claims a free slot when it mounts and replays that slot's journal during recovery if the owner dies. `mkfs.ocfs2 -N 4` created four slots, so up to four nodes may mount concurrently. If you try to mount on **more nodes than there are slots**, the extra mount **fails** ("no free slots") until you add slots with `tunefs.ocfs2 -N`.

### Exercise 6

**6a.** Increasing slots only **allocates additional journals and slot-map entries in free space** and updates the superblock count — it does not disturb existing slots or live mounts, so it is safe **online**. Slot count can only be increased because decreasing would require **removing journals that may hold un-replayed recovery data** and relocating/validating metadata tied to those slots, which is unsafe while any node might need them; OCFS2 therefore treats slot growth as one-way (reducing slots is not an ordinary online operation).

**6b.** Each node writes metadata transactions to **its own journal** (its slot). When a node dies, its last transactions may be committed to the journal but not yet fully written back to their final on-disk locations, leaving the file system inconsistent. **Journal replay** reads the dead node's journal and completes (or discards) those pending transactions, restoring consistency. A **surviving** node performs it precisely because the dead node cannot — a healthy node claims/reads the failed slot's journal and replays it (after the node is confirmed dead via heartbeat/fencing), which is why you saw `replay journal (slot 1)` logged on `node1`.

**6c.**
- `o2info` — reports volume/feature/free-space info; **safe mounted**.
- `mounted.ocfs2` — detects OCFS2 volumes and which nodes mount them; **safe mounted** (read-only scan).
- `debugfs.ocfs2` — interactive metadata inspector; **safe read-only on a mounted volume** (use write/debug commands with great care).
- `o2image` — copies metadata to an image file for offline analysis; **safe mounted** (reads metadata only).
- `fsck.ocfs2` — consistency check/repair; **requires the volume unmounted on all nodes** (it writes/repairs metadata and cannot coordinate with live mounts).

</details>

---

### Sources

- LPI — Exam 306-300 Objectives (Topic 362.3): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux kernel documentation — GFS2: <https://www.kernel.org/doc/html/latest/filesystems/gfs2.html>
- Linux kernel documentation — OCFS2: <https://www.kernel.org/doc/html/latest/filesystems/ocfs2.html>
- Red Hat — *Configuring GFS2 File Systems* (RHEL 9): <https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_gfs2_file_systems/index>
- SUSE — *Administration Guide: OCFS2* (SLE HA): <https://documentation.suse.com/sle-ha/15-SP6/html/SLE-HA-all/cha-ha-ocfs2.html>
- The DLM man pages: `dlm_tool(8)`, `dlm_controld(8)`; GFS2 tools: `mkfs.gfs2(8)`, `gfs2_jadd(8)`, `gfs2_grow(8)`, `tunegfs2(8)`, `fsck.gfs2(8)`, `gfs2_edit(8)`; OCFS2 tools: `mkfs.ocfs2(8)`, `o2cb(7)`, `o2info(8)`, `mounted.ocfs2(8)`, `tunefs.ocfs2(8)`, `debugfs.ocfs2(8)`, `fsck.ocfs2(8)`, `o2image(8)`