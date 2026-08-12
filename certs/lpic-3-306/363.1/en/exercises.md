# 363.1 GlusterFS Storage Clusters — Guided Exercises

> **Format.** Each part is a block of numbered steps you run on the lab, followed by comprehension questions. All answers are collapsed in the **Answer key** at the end. Commands prefixed with `[nodeN]#` run on that specific node as root; `[any]#` may run on any pool member.

## Lab topology

Three identical VMs, each with a dedicated raw disk `/dev/sdb` (20 GiB) reserved for GlusterFS bricks. `node1` doubles as the client.

| Host  | Management IP    | Brick disk |
|-------|------------------|------------|
| node1 | 192.168.122.11   | /dev/sdb   |
| node2 | 192.168.122.12   | /dev/sdb   |
| node3 | 192.168.122.13   | /dev/sdb   |

Put all three names in `/etc/hosts` on every node (GlusterFS stores peers by name and resolves them constantly):

```
192.168.122.11  node1
192.168.122.12  node2
192.168.122.13  node3
```

---

## Part 1 — Install GlusterFS and prepare the bricks

Run steps 1–5 **on all three nodes**.

1. Install the server package and the FUSE client, then enable the management daemon:

   ```bash
   [all]# apt-get install -y glusterfs-server        # Debian/Ubuntu
   [all]# dnf install -y glusterfs-server            # RHEL/Fedora family
   [all]# systemctl enable --now glusterd
   ```

2. Confirm the daemon is up and note the version:

   ```bash
   [all]# gluster --version | head -1
   glusterfs 11.1

   [all]# systemctl --no-pager status glusterd
   ● glusterd.service - GlusterFS, a clustered file-system server
        Active: active (running) since ...
   ```

3. Open the required firewall ports (management + a range for the per-brick daemons):

   ```bash
   [all]# firewall-cmd --permanent --add-service=glusterfs   # opens 24007/24008 + 49152-49664
   [all]# firewall-cmd --reload
   ```

4. Build an **XFS** filesystem for the bricks. XFS with a 512-byte inode is the recommended backing store because GlusterFS stores extensive metadata in extended attributes:

   ```bash
   [all]# mkfs.xfs -i size=512 /dev/sdb
   [all]# mkdir -p /data/glusterfs
   [all]# echo '/dev/sdb /data/glusterfs xfs defaults 0 0' >> /etc/fstab
   [all]# mount -a
   [all]# df -hT /data/glusterfs
   Filesystem     Type  Size  Used Avail Use% Mounted on
   /dev/sdb       xfs    20G  175M   20G   1% /data/glusterfs
   ```

5. Create the brick **sub-directories** (never export the mount-point root itself):

   ```bash
   [all]# mkdir -p /data/glusterfs/{gv-dist,gv-rep,gv-dr,gv-disp}/brick1
   ```

**Check your understanding — Part 1**

1. Which single daemon must be running on every node before you can form a pool or create a volume, and on which TCP port does it listen?
2. Why is XFS with `-i size=512` recommended over the default inode size for a brick?
3. Why does the guide export `/data/glusterfs/gv-rep/brick1/brick` rather than the mount point `/data/glusterfs` directly?

---

## Part 2 — Build the Trusted Storage Pool

Run these **from node1 only** (the pool is symmetric once formed).

1. Probe the other two peers:

   ```bash
   [node1]# gluster peer probe node2
   peer probe: success
   [node1]# gluster peer probe node3
   peer probe: success
   ```

2. Verify the pool state:

   ```bash
   [node1]# gluster peer status
   Number of Peers: 2

   Hostname: node2
   Uuid: 8f3c2a1b-...-...
   State: Peer in Cluster (Connected)

   Hostname: node3
   Uuid: b7d91e04-...-...
   State: Peer in Cluster (Connected)

   [node1]# gluster pool list
   UUID                                  Hostname   State
   8f3c2a1b-...-...                       node2      Connected
   b7d91e04-...-...                       node3      Connected
   ff0a...-localhost                      localhost  Connected
   ```

3. Fix the reverse-resolution asymmetry. Because node1 probed node2, node2 initially records node1 by **IP address**, not by name. Re-probe node1 *by name* from node2 so the pool is name-consistent:

   ```bash
   [node2]# gluster peer status
   ...
   Hostname: 192.168.122.11      # node1 seen as a bare IP — undesirable
   ...
   [node2]# gluster peer probe node1
   peer probe: success
   [node2]# gluster peer status | grep Hostname
   Hostname: node1               # now consistent
   Hostname: node3
   ```

**Check your understanding — Part 2**

1. `gluster peer status` on node1 reports `Number of Peers: 2`. What number would the same command report if run on node3, and why?
2. After node1 probes node2, why does node2 list node1 by IP address instead of hostname, and what problem could that cause later?
3. Which entry appears in `gluster pool list` but **not** in `gluster peer status`?

---

## Part 3 — Distributed volume (DHT, no redundancy)

1. Create and start a purely distributed volume with one brick per node:

   ```bash
   [node1]# gluster volume create gv-dist \
       node1:/data/glusterfs/gv-dist/brick1/brick \
       node2:/data/glusterfs/gv-dist/brick1/brick \
       node3:/data/glusterfs/gv-dist/brick1/brick
   volume create: gv-dist: success: please start the volume to access data
   [node1]# gluster volume start gv-dist
   volume start: gv-dist: success
   ```

2. Inspect the layout:

   ```bash
   [any]# gluster volume info gv-dist
   Volume Name: gv-dist
   Type: Distribute
   Volume ID: 1a2b...-...
   Status: Started
   Number of Bricks: 3
   Transport-type: tcp
   Bricks:
   Brick1: node1:/data/glusterfs/gv-dist/brick1/brick
   Brick2: node2:/data/glusterfs/gv-dist/brick1/brick
   Brick3: node3:/data/glusterfs/gv-dist/brick1/brick
   Options Reconfigured:
   transport.address-family: inet
   storage.fips-mode-rmdir: on
   nfs.disable: on
   ```

3. Mount it and create 30 files, then see how the **elastic hash (DHT)** scatters them across bricks:

   ```bash
   [node1]# mkdir -p /mnt/gv-dist
   [node1]# mount -t glusterfs node1:/gv-dist /mnt/gv-dist
   [node1]# for i in $(seq -w 1 30); do echo hi > /mnt/gv-dist/file-$i; done

   [node1]# ls /data/glusterfs/gv-dist/brick1/brick | wc -l   # ~10 files
   [node2]# ls /data/glusterfs/gv-dist/brick1/brick | wc -l   # ~10 files
   [node3]# ls /data/glusterfs/gv-dist/brick1/brick | wc -l   # ~10 files
   ```

   Each *whole* file lives on exactly one brick, chosen by hashing its name into the directory's layout range.

**Check your understanding — Part 3**

1. If node2 is powered off, what happens to reads of `file-17` that happens to live on node2's brick? What happens to the ~20 files on node1 and node3?
2. Which translator decides *which* brick a given file lands on, and what input does it hash?
3. What is the usable capacity of this 3 × 20 GiB distributed volume, and what redundancy does it provide?

---

## Part 4 — Replicated volume (AFR)

1. Create a `replica 3` volume. Note the confirmation prompt only appears for `replica 2`; here we go straight to 3 for safety:

   ```bash
   [node1]# gluster volume create gv-rep replica 3 \
       node1:/data/glusterfs/gv-rep/brick1/brick \
       node2:/data/glusterfs/gv-rep/brick1/brick \
       node3:/data/glusterfs/gv-rep/brick1/brick
   volume create: gv-rep: success: please start the volume to access data
   [node1]# gluster volume start gv-rep
   ```

   > If you had asked for `replica 2` you would have seen:
   > ```
   > Replica 2 volumes are prone to split-brain. Use Arbiter or Replica 3 to avoid this.
   > Do you still want to continue? (y/n)
   > ```

2. Confirm the geometry and the running brick processes:

   ```bash
   [any]# gluster volume info gv-rep | grep -E 'Type|Number of Bricks'
   Type: Replicate
   Number of Bricks: 1 x 3 = 3

   [any]# gluster volume status gv-rep
   Gluster process                                TCP Port  RDMA Port  Online  Pid
   ------------------------------------------------------------------------------
   Brick node1:/data/glusterfs/gv-rep/brick1/brick   49153    0          Y      2011
   Brick node2:/data/glusterfs/gv-rep/brick1/brick   49153    0          Y      2044
   Brick node3:/data/glusterfs/gv-rep/brick1/brick   49153    0          Y      2077
   Self-heal Daemon on localhost                     N/A      N/A        Y      2090
   Self-heal Daemon on node2                         N/A      N/A        Y      2101
   Self-heal Daemon on node3                         N/A      N/A        Y      2112
   ```

3. Prove synchronous mirroring — one write lands on **all three** bricks:

   ```bash
   [node1]# mount -t glusterfs node1:/gv-rep /mnt/gv-rep
   [node1]# echo "replicated payload" > /mnt/gv-rep/report.txt
   [node1]# cat /data/glusterfs/gv-rep/brick1/brick/report.txt   # present
   [node2]# cat /data/glusterfs/gv-rep/brick1/brick/report.txt   # present
   [node3]# cat /data/glusterfs/gv-rep/brick1/brick/report.txt   # present
   ```

**Check your understanding — Part 4**

1. Why is `replica 2` "prone to split-brain", and what are the **two** ways GlusterFS suggests to avoid it?
2. An **arbiter** brick stores what — and does *not* store what — compared to a full replica brick?
3. With three 20 GiB bricks, what is the usable capacity of this `replica 3` volume?

---

## Part 5 — Distributed-Replicated volume

You need six bricks. Add a second brick sub-directory per node first (steps assume `gv-dr/brick1` exists and you create `gv-dr/brick2`):

1. Prepare a second brick per node and create the volume with `replica 2`:

   ```bash
   [all]# mkdir -p /data/glusterfs/gv-dr/brick2
   [node1]# gluster volume create gv-dr replica 2 \
       node1:/data/glusterfs/gv-dr/brick1/brick node2:/data/glusterfs/gv-dr/brick1/brick \
       node3:/data/glusterfs/gv-dr/brick1/brick node1:/data/glusterfs/gv-dr/brick2/brick \
       node2:/data/glusterfs/gv-dr/brick2/brick node3:/data/glusterfs/gv-dr/brick2/brick
   Replica 2 volumes are prone to split-brain. ... Do you still want to continue? (y/n) y
   volume create: gv-dr: success: please start the volume to access data
   [node1]# gluster volume start gv-dr
   ```

2. Read the geometry carefully:

   ```bash
   [any]# gluster volume info gv-dr | grep -E 'Type|Number of Bricks|Brick[0-9]'
   Type: Distributed-Replicate
   Number of Bricks: 3 x 2 = 6
   Brick1: node1:/data/glusterfs/gv-dr/brick1/brick   ┐ replica set 0
   Brick2: node2:/data/glusterfs/gv-dr/brick1/brick   ┘
   Brick3: node3:/data/glusterfs/gv-dr/brick1/brick   ┐ replica set 1
   Brick4: node1:/data/glusterfs/gv-dr/brick2/brick   ┘
   Brick5: node2:/data/glusterfs/gv-dr/brick2/brick   ┐ replica set 2
   Brick6: node3:/data/glusterfs/gv-dr/brick2/brick   ┘
   ```

   Files are first distributed (DHT) across the three replica *sets*, then mirrored within each set.

**Check your understanding — Part 5**

1. `gluster volume info` prints `3 x 2 = 6`. What do the `3`, the `2`, and the `6` each mean?
2. Given the brick order above, `Brick1` and `Brick2` mirror each other. Why would writing the six bricks in a *different* order (e.g. both bricks of node1 adjacent) be a serious availability mistake?
3. In this `3 x 2` layout, how many *arbitrary* brick failures can the volume survive without data loss, and how many *worst-case* (both bricks of one replica set)?

---

## Part 6 — Dispersed volume (erasure coding)

1. Create a `disperse 3 redundancy 1` volume (the minimum viable EC configuration):

   ```bash
   [node1]# gluster volume create gv-disp disperse 3 redundancy 1 \
       node1:/data/glusterfs/gv-disp/brick1/brick \
       node2:/data/glusterfs/gv-disp/brick1/brick \
       node3:/data/glusterfs/gv-disp/brick1/brick
   volume create: gv-disp: success: please start the volume to access data
   [node1]# gluster volume start gv-disp

   [any]# gluster volume info gv-disp | grep -E 'Type|Number of Bricks'
   Type: Disperse
   Number of Bricks: 1 x (2 + 1) = 3
   ```

   The `(2 + 1)` means 2 data fragments + 1 redundancy fragment per stripe.

2. Kill one brick and confirm the volume keeps serving:

   ```bash
   [node1]# mount -t glusterfs node1:/gv-disp /mnt/gv-disp
   [node1]# dd if=/dev/urandom of=/mnt/gv-disp/blob bs=1M count=64 status=none
   [node3]# systemctl stop glusterd            # take node3's fragment offline (lab shortcut)
   [node3]# pkill -f 'glusterfsd.*gv-disp'
   [node1]# md5sum /mnt/gv-disp/blob            # still reads — reconstructed from 2 of 3 fragments
   ```

**Check your understanding — Part 6**

1. For `disperse 3 redundancy 1` built on 20 GiB bricks, what is the approximate **usable** capacity, and how does that fraction generalise to `disperse N redundancy R`?
2. How many simultaneous brick failures can `disperse 3 redundancy 1` tolerate?
3. State the core trade-off that makes you choose a dispersed volume over a `replica 3` volume of the same fault tolerance.

---

## Part 7 — Mounting: FUSE, fstab, and why not NFS

1. You already mounted via the **native FUSE client** (`mount -t glusterfs`). At mount time the client contacts the named server on port **24007** only to *download the volfile* (the translator graph); thereafter it talks **directly** to every brick daemon.

2. Make the mount persistent and resilient. `_netdev` defers the mount until the network is up; `backupvolfile-server` supplies a fallback if the primary volfile server is down at boot:

   ```bash
   [node1]# tail -1 /etc/fstab
   node1:/gv-rep /mnt/gv-rep glusterfs defaults,_netdev,backupvolfile-server=node2 0 0
   [node1]# umount /mnt/gv-rep && mount /mnt/gv-rep
   [node1]# mount | grep gv-rep
   node1:/gv-rep on /mnt/gv-rep type fuse.glusterfs (rw,relatime,...)
   ```

3. Observe that the built-in gluster-NFS server is **off by default** (`nfs.disable: on`); modern deployments export via **NFS-Ganesha** instead:

   ```bash
   [any]# gluster volume get gv-rep nfs.disable
   Option              Value
   ------              -----
   nfs.disable         on
   ```

**Check your understanding — Part 7**

1. At mount time the client contacts a single server. Once mounted, does read/write traffic flow through that one server or somewhere else? What does that imply for load distribution?
2. What does `backupvolfile-server=node2` protect against, and what does it *not* help with once the volume is already mounted?
3. Why is `_netdev` important for a GlusterFS entry in `/etc/fstab`?

---

## Part 8 — Quotas

1. Enable quota accounting on the volume, then set a hard directory limit:

   ```bash
   [node1]# gluster volume quota gv-rep enable
   volume quota : success
   [node1]# mkdir /mnt/gv-rep/projects
   [node1]# gluster volume quota gv-rep limit-usage /projects 10GB
   volume quota : success
   [node1]# gluster volume quota gv-rep list
                     Path   Hard-limit  Soft-limit  Used  Available  Soft exceeded?  Hard exceeded?
   -----------------------------------------------------------------------------------------------
   /projects              10.0GB   80%(8.0GB)  0Bytes  10.0GB      No              No
   ```

2. Adjust the soft-limit threshold at which warnings begin:

   ```bash
   [node1]# gluster volume quota gv-rep limit-usage /projects 10GB 90%
   ```

**Check your understanding — Part 8**

1. What must be true about the target directory before you can call `limit-usage /projects`, and where is that path rooted?
2. GlusterFS quota limits a **directory's** usage, not a user's. Which translator maintains the running byte-count that makes directory accounting cheap?
3. What is the practical difference between the hard limit and the soft limit?

---

## Part 9 — Snapshots

Snapshots require the brick's backing store to be an **LVM thin-provisioned** logical volume; the earlier plain-disk bricks cannot be snapshotted. Assume `gv-rep`'s bricks live on thin LVs for this part.

1. Create, list, and inspect a snapshot:

   ```bash
   [node1]# gluster snapshot create snap1 gv-rep no-timestamp
   snapshot create: success: Snap snap1 created successfully
   [node1]# gluster snapshot list
   snap1
   [node1]# gluster snapshot info snap1 | grep -E 'Snap Name|Status|Volume Name'
   Snap Name : snap1
   Status    : Stopped
   ```

2. Activate it and expose it to clients via **User-Serviceable Snapshots (USS)** — a virtual `.snaps` directory:

   ```bash
   [node1]# gluster snapshot activate snap1
   [node1]# gluster volume set gv-rep features.uss enable
   [node1]# ls /mnt/gv-rep/.snaps
   snap1
   [node1]# cat /mnt/gv-rep/.snaps/snap1/report.txt      # read-only point-in-time copy
   ```

3. Restore (destructive — the live volume must be **stopped** first):

   ```bash
   [node1]# gluster volume stop gv-rep
   [node1]# gluster snapshot restore snap1
   Snapshot restore: snap1: Snap restored successfully
   [node1]# gluster volume start gv-rep
   ```

**Check your understanding — Part 9**

1. Why does GlusterFS require LVM **thin** provisioning (not thick LVs) under the bricks to support snapshots?
2. Can you `snapshot restore` while the volume is still started and mounted? What state must the volume be in?
3. What does enabling `features.uss` give an end user, and through which special directory?

---

## Part 10 — Self-healing and split-brain

1. View the heal state (0 pending entries when healthy):

   ```bash
   [any]# gluster volume heal gv-rep info
   Brick node1:/data/glusterfs/gv-rep/brick1/brick
   Status: Connected
   Number of entries: 0
   ...
   ```

2. Simulate a brick outage, write while degraded, then bring it back and watch the **self-heal daemon (glustershd)** reconcile:

   ```bash
   [node3]# pkill -f 'glusterfsd.*gv-rep'                 # node3 brick down
   [node1]# echo "written while node3 was down" >> /mnt/gv-rep/report.txt
   [node3]# gluster volume start gv-rep force              # restart the brick process
   [any]#  gluster volume heal gv-rep info                # shows report.txt pending on node3
   [any]#  gluster volume heal gv-rep                      # trigger index heal now
   Launching heal operation to perform index self heal on volume gv-rep has been successful
   ```

3. Detect and resolve a **split-brain** (the file diverged on two bricks with no automatic winner):

   ```bash
   [any]# gluster volume heal gv-rep info split-brain
   Brick node1:/data/glusterfs/gv-rep/brick1/brick
   /report.txt
   Number of entries in split-brain: 1
   ...
   # Resolve by choosing the most recent modification time:
   [any]# gluster volume heal gv-rep split-brain latest-mtime /report.txt
   # ...or by naming an authoritative source brick:
   [any]# gluster volume heal gv-rep split-brain source-brick node1:/data/glusterfs/gv-rep/brick1/brick /report.txt
   ```

**Check your understanding — Part 10**

1. Which daemon performs background healing on a replicated volume, and how does it appear in `gluster volume status`?
2. What condition defines a *split-brain*, and why can't ordinary self-heal resolve it automatically?
3. Name two `gluster volume heal ... split-brain` resolution policies you could use on a single diverged file.

---

## Part 11 — Elasticity: add-brick, rebalance, remove-brick

1. Grow the distributed volume by one brick, then redistribute existing files:

   ```bash
   [all]# mkdir -p /data/glusterfs/gv-dist/brick2
   [node1]# gluster volume add-brick gv-dist node1:/data/glusterfs/gv-dist/brick2/brick
   volume add-brick: success
   [node1]# gluster volume rebalance gv-dist start
   volume rebalance: gv-dist: success: Rebalance on gv-dist has been started successfully.
   [node1]# gluster volume rebalance gv-dist status
   Node    Rebalanced-files  size  scanned  failures  skipped  status  run time
   -----   ----------------  ----  -------  --------  -------  ------  --------
   node1               7      7B     30       0        0       completed  0:00:03
   ```

2. Shrink safely — `start` **migrates data off** the brick before you `commit`:

   ```bash
   [node1]# gluster volume remove-brick gv-dist node1:/data/glusterfs/gv-dist/brick2/brick start
   [node1]# gluster volume remove-brick gv-dist node1:/data/glusterfs/gv-dist/brick2/brick status
   ...  status: completed
   [node1]# gluster volume remove-brick gv-dist node1:/data/glusterfs/gv-dist/brick2/brick commit
   Removing brick(s) can result in data loss. Do you want to Continue? (y/n) y
   volume remove-brick commit: success
   ```

**Check your understanding — Part 11**

1. After `add-brick` on a distributed volume, why are *existing* files still unevenly spread until you run `rebalance`?
2. What is the danger of `remove-brick ... commit` **without** first running `remove-brick ... start` and waiting for it to complete?
3. When you `add-brick` to a `replica 3` volume, how many bricks must you add at once, and why?

---

## Part 12 — Troubleshooting and teardown

1. First-line diagnostics:

   ```bash
   [any]# gluster volume status gv-rep          # per-brick Online/Y? and PIDs
   [any]# gluster volume status gv-rep clients  # connected FUSE clients
   [any]# ls /var/log/glusterfs/                # glusterd.log, brick logs, mount logs
   [any]# gluster volume statedump gv-rep       # dumps to /var/run/gluster/ for deep analysis
   ```

2. Clean teardown of a volume and a peer:

   ```bash
   [node1]# umount /mnt/gv-rep
   [node1]# gluster volume stop gv-rep
   Stopping volume will make its data inaccessible. Do you want to continue? (y/n) y
   [node1]# gluster volume delete gv-rep
   Deleting volume will erase all information about the volume. ... (y/n) y
   [node1]# gluster peer detach node3
   All clients mounted through the peer which is getting detached ... Do you want to continue? (y/n) y
   peer detach: success
   ```

**Check your understanding — Part 12**

1. In `gluster volume status`, what does the `Online` column tell you, and what would `N` next to a brick indicate?
2. Where do brick, client (mount), and management logs live by default?
3. Why must you `stop` a volume before you can `delete` it, and why does `peer detach` refuse if the peer still hosts bricks of an existing volume?

---

<details>
<summary><strong>Answer key</strong> (click to expand)</summary>

### Part 1

1. **`glusterd`**, the management/configuration daemon. It listens on TCP **24007** (with 24008 historically used for RDMA management). It must run on every node — it owns the shared configuration in `/var/lib/glusterd` and spawns the per-brick `glusterfsd` processes on ports 49152+.
2. GlusterFS stores per-file metadata (GFID, AFR/EC changelogs, DHT layout ranges) in **extended attributes**. A 512-byte inode keeps those xattrs *inline* in the inode instead of spilling into separate blocks, which is faster and avoids inode exhaustion under heavy metadata load.
3. GlusterFS refuses (or warns and requires `force`) when a brick is the **root of a mounted filesystem**, because a failed/unmounted backing disk would silently leave the brick pointing at the *underlying* root filesystem and let it fill the OS disk. Exporting a sub-directory (`.../brick1/brick`) makes an unmounted disk obvious (the sub-dir won't exist) and keeps writes off the root FS.

### Part 2

1. It would also report **`Number of Peers: 2`**. `peer status` always shows *the other* members of the pool from the perspective of the node you run it on, so in a 3-node pool every node sees the two others.
2. `peer probe` is one-directional: node1 initiated contact, so node2 only knows node1 by the **source IP** of the connection, not by a name it resolved itself. The fix (re-probing node1 by name from node2) matters because volume operations and logs key on hostnames; a bare IP can break brick identity if the address ever changes and is generally harder to operate.
3. **`localhost`** — `gluster pool list` includes the local node itself, whereas `peer status` lists only the *remote* peers.

### Part 3

1. Reads of `file-17` **fail** (the only copy is on the offline brick — distribute has no redundancy). The ~20 files hashing to node1/node3 remain fully readable and writable. New files that hash into node2's range also fail until it returns.
2. The **DHT (Distribute) translator**. It hashes the **file name** into a 32-bit value and places the file on whichever brick owns that value's range in the parent directory's layout.
3. **~60 GiB** usable (sum of all bricks). It provides **no redundancy** — capacity scales, availability does not.

### Part 4

1. With only two copies and no tie-breaker, if the two bricks are updated independently during a partition, AFR cannot know which copy is authoritative → **split-brain**. The two recommended cures are **`replica 3`** (majority quorum resolves the winner) or an **arbiter** brick.
2. An arbiter brick stores **file metadata and the AFR changelog xattrs only — no file data**. It acts as a lightweight third vote to break ties, giving `replica 2`-like storage cost with `replica 3`-like split-brain protection.
3. **20 GiB** usable. `replica 3` keeps three full copies, so usable capacity equals a single brick.

### Part 5

1. `3` = number of **distribute subvolumes (replica sets)**; `2` = **replica count** within each set; `6` = total bricks. Files are distributed across the 3 sets and mirrored across the 2 bricks in each set.
2. Brick order defines the replica sets from **consecutive** bricks. If both of node1's bricks became the two members of one replica set, then losing node1 alone would take **both copies of that set offline** → data unavailable. Correct ordering places each replica set's bricks on **different nodes** so no single node holds a full mirror pair.
3. It always survives **one** arbitrary brick failure (one per replica set can fail: up to 3 total, as long as no set loses both). **Worst case** — if *both* bricks of any single replica set fail — that set's files become unavailable. So guaranteed survival is 1 failure; up to 3 non-overlapping failures are survivable.

### Part 6

1. Usable ≈ **(N−R)/N** of raw = **(3−1)/3 ≈ 2/3**, i.e. roughly **40 GiB** out of 60 GiB raw. For `disperse N redundancy R`, usable fraction is `(N−R)/N`.
2. Exactly **R = 1** brick failure. Any one of the three fragments can be reconstructed from the other two.
3. Dispersed (erasure-coded) volumes give the same fault tolerance as replication at **much lower storage overhead** (⅓ overhead here vs. 3× for replica 3), at the cost of **higher CPU** (encode/decode) and generally **lower small-file/IOPS performance**. Choose EC for capacity-efficient bulk/archival storage; choose replication for latency-sensitive workloads.

### Part 7

1. Once mounted, the FUSE client talks **directly to every brick** — the initial server only handed out the volfile. Traffic is therefore spread across all bricks, not funneled through one node, so there is **no single-server bottleneck** for data I/O.
2. `backupvolfile-server` provides an alternative source for the **volfile at mount time** if the primary server is unreachable during `mount`. It does **not** matter after the mount succeeds (the client is already talking to all bricks), and it is *not* what provides data redundancy — that comes from the volume type.
3. `_netdev` marks the mount as network-dependent so the system **waits for networking** before attempting it at boot; without it, boot can try (and fail) to mount before the interface/pool is reachable.

### Part 8

1. The directory must **already exist inside the volume** (created via the mount, e.g. `/mnt/gv-rep/projects`). The quota path is rooted at the **volume root**, so `/projects` means `<volume>/projects`, not a host path.
2. The **marker (quota) translator** on the bricks maintains a running "contribution" byte-count up the directory tree, so directory usage is read from an xattr rather than re-scanned each time.
3. The **hard limit** is enforced — writes that would exceed it are denied (`EDQUOT`). The **soft limit** (a percentage of the hard limit) is a warning threshold: crossing it logs/flags "soft exceeded" and starts a soft-timeout grace period but does not block writes.

### Part 9

1. GlusterFS snapshots are **LVM thin-LV snapshots**. Thin provisioning lets a snapshot share unchanged blocks and only consume space for changed blocks (copy-on-write) from a shared thin pool. Thick LVs would require pre-allocating a full-size snapshot per brick, which GlusterFS's snapshot mechanism does not use — hence thin is mandatory.
2. **No.** `snapshot restore` requires the volume to be **stopped** first (it swaps the live bricks for the snapshot's LVs). You stop, restore, then start again.
3. `features.uss` gives users **self-service, read-only access to activated snapshots** without admin intervention, exposed through the virtual **`.snaps`** directory inside the mount.

### Part 10

1. The **self-heal daemon, `glustershd`**. It appears in `gluster volume status` as **`Self-heal Daemon on <node>`** (one per node), with no TCP port.
2. Split-brain occurs when the **same file is modified on two replica bricks independently** (e.g. during a network partition) so each brick's AFR changelog blames the other, leaving **no automatically determinable authoritative copy**. Self-heal refuses to guess because either choice could discard real data.
3. Any two of: **`latest-mtime`** (pick the most recently modified copy), **`source-brick <brick> <file>`** (declare one brick authoritative), or **`bigger-file`** (pick the larger copy). There is also a `source-brick` whole-brick form for bulk resolution.

### Part 11

1. DHT places each file by a **hash of its name into a per-directory layout**. Adding a brick doesn't retroactively move existing files — their old hash ranges still point at the old bricks — so they stay put until **rebalance** recomputes the layout (fix-layout) and **migrates** files into the new brick's range.
2. `commit` without a completed `start` **drops the brick immediately without migrating its data off first**, so every file that lived only on that brick is lost. `start` drains the brick (moves its files to the remaining bricks); you `commit` only after `status` reports `completed`.
3. You must add a **full replica set at a time — 3 bricks** for a `replica 3` volume (and generally a multiple of the replica count). Adding fewer would leave an incomplete mirror set and break the volume's redundancy invariant.

### Part 12

1. `Online` shows whether each brick's `glusterfsd` process is **up and serving** (`Y`) or **down** (`N`). An `N` means that brick is offline — a degraded (or, on a distribute-only volume, partially unavailable) volume that needs investigation.
2. All under **`/var/log/glusterfs/`**: management/glusterd in `glusterd.log`, per-brick logs under `bricks/`, and client/mount logs named after the mount path (e.g. `mnt-gv--rep.log`).
3. `delete` erases all configuration for a volume; requiring a prior **`stop`** prevents deleting a volume that clients are actively using (and possibly writing to). `peer detach` refuses while the peer still **hosts bricks of an existing volume**, because removing it would orphan those bricks and corrupt the volume's brick membership — you must remove/relocate the bricks (or delete the volume) first.

</details>

---

### Sources

- LPI Exam 306 Objectives, Topic 363.1 — <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Gluster Documentation — Administrator Guide (Setting Up Volumes, Managing Volumes, Trusted Storage Pools) — <https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/>
- Gluster Documentation — Managing Snapshots — <https://docs.gluster.org/en/latest/Administrator-Guide/Managing-Snapshots/>
- Gluster Documentation — Handling of Split-brain and Self-heal — <https://docs.gluster.org/en/latest/Troubleshooting/resolving-splitbrain/>
- Gluster Documentation — Directory Quota — <https://docs.gluster.org/en/latest/Administrator-Guide/Directory-Quota/>