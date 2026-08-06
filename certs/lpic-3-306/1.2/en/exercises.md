# LPIC-3 306 (Exam 306-300 v3.0) — Enterprise Guided Lab Manual: High Availability Cluster Storage

**Target Certification:** LPIC-3 High Availability and Storage Clusters (Exam 306-300, Version 3.0)  
**Topic 362 & 363:** High Availability Cluster Storage & Distributed Storage  
**Audience:** Principal Platform Architects, Senior SREs, Systems Engineers  
**Prerequisites:** Deep understanding of Linux Kernel block layer, POSIX file systems, TCP/IP networking, and storage primitives.

---

## Architectural Context & Topic Overview

High Availability (HA) Cluster Storage forms the foundation of fault-tolerant enterprise infrastructure. It guarantees Data Integrity, Consistency, and Availability despite node crashes, network partitions, or storage medium degradation. 

In this lab series, you will master the five core pillars of HA cluster storage defined in the **LPIC-3 306-300 v3.0** blueprint:
1. **DRBD (Distributed Replicated Block Device):** Block-level synchronous/asynchronous network RAID-1 replication.
2. **SAN High Availability & Storage Access:** iSCSI Target/Initiator configuration, Target Port Groups (TPG), ALUA, and `multipathd` I/O failover.
3. **Clustered File Systems:** Shared-disk file systems (GFS2, OCFS2) backed by the Distributed Lock Manager (DLM) and Pacemaker/Corosync integration.
4. **GlusterFS Distributed File System:** Translator stacks (xlators), bricks, replication protocols, self-healing daemons, and split-brain resolution.
5. **Ceph Unified Distributed Storage:** RADOS internals, Paxos MON quorum, CRUSH map algorithmic placement, Placement Group (PG) state machines, and RBD block mapping.

---

## Exercise 1: DRBD v9 / v8.4 Mechanics, Dual-Primary Setup, and Split-Brain Recovery

### 1.1 Deep Technical Mechanics & Architecture

DRBD operates as a virtual block device driver in the Linux Kernel between the file system / buffer cache layer and the underlying physical disk controllers.

```
+-------------------------------------------------------------+
|                     User Space / Applications               |
+-------------------------------------------------------------+
|                     Virtual File System (VFS)               |
+-------------------------------------------------------------+
|               Kernel Block Layer (/dev/drbd0)               |
+------------------------------+------------------------------+
                               |
               +---------------+---------------+
               |                               |
               v                               v
    +--------------------+           +--------------------+
    |  Local Disk Driver |           | DRBD Network Engine|
    +--------------------+           +--------------------+
               |                               |
               v                               v
     [ Physical Storage ]             [ TCP/IP / RDMA Engine ]
                                               |
                                               v (Replication Link)
                                      [ Remote Node DRBD ]
```

#### Replication Protocols:
* **Protocol A (Asynchronous):** Local write I/O completes as soon as data is written to the local disk and sent to the local TCP send buffer. High throughput over WANs; potential data loss on Primary crash.
* **Protocol B (Memory Synchronous):** Local write I/O completes once local disk write finishes and the packet arrives at the remote peer's network buffer (RAM). Protects against single-node power loss, vulnerable to dual-node failure.
* **Protocol C (Synchronous):** Write I/O is acknowledged to the application *only* after local disk write **AND** remote disk write completion are confirmed. Zero RPO (Recovery Point Objective); latency is directly bound by network Round Trip Time (RTT).

---

### 1.2 Guided Execution Steps

#### Step 1: Synthesize the DRBD Resource Configuration
On both nodes (`node1.example.com` - 192.168.1.10, `node2.example.com` - 192.168.1.11), create the resource manifest `/etc/drbd.d/r0.res`:

```conf
# /etc/drbd.d/r0.res
resource r0 {
    protocol C;

    startup {
        wfc-timeout 15;
        degr-wfc-timeout 60;
        become-primary-on both; # Enables Dual-Primary for Clustered File Systems
    }

    net {
        fencing resource-only;
        max-buffers 8000;
        max-epoch-size 8000;
        sndbuf-size 512k;
        rcvbuf-size 512k;
        allow-two-primaries yes;
        after-sb-0pri discard-younger-primary;
        after-sb-1pri discard-secondary;
        after-sb-2pri call-pri-lost-after-sb;
    }

    disk {
        on-io-error detach;
        disk-flushes yes;
        md-flushes yes;
    }

    on node1.example.com {
        node-id 0;
        device    /dev/drbd0;
        disk      /dev/sdb;
        meta-disk internal;
        address   192.168.1.10:7788;
    }

    on node2.example.com {
        node-id 1;
        device    /dev/drbd0;
        disk      /dev/sdb;
        meta-disk internal;
        address   192.168.1.11:7788;
    }
}
```

#### Step 2: Initialize DRBD Metadata & Bind Resource
Execute on **both nodes**:

```bash
sudo drbdadm create-md r0
sudo drbdadm up r0
```

*Expected Output (`node1`):*
```text
Initializing script initializing node-id 0...
Writing meta data...
New DRBD meta block successfully created.
```

#### Step 3: Force Initial Sync Source on Node1
Execute on `node1`:

```bash
sudo drbdadm primary --force r0
```

Check replication status using `drbdadm status`:

```bash
sudo drbdadm status r0
```

*Expected Output:*
```text
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    peer-disk:UpToDate
```

#### Step 4: Simulate a Split-Brain Scenario
A Split-Brain occurs when network communication fails while both nodes remain online, causing both nodes to transition to `Primary` and process divergent local writes.

1. Break the network interface on `node2` temporarily or force network disconnect:
   ```bash
   sudo drbdadm disconnect r0
   ```
2. Force `node2` into Primary role and write to `/dev/drbd0`:
   ```bash
   sudo drbdadm primary --force r0
   sudo dd if=/dev/urandom of=/dev/drbd0 bs=1M count=10 seek=1 conv=notrunc
   ```
3. Write conflicting data on `node1` while Primary:
   ```bash
   sudo dd if=/dev/urandom of=/dev/drbd0 bs=1M count=10 seek=20 conv=notrunc
   ```
4. Attempt to reconnect nodes:
   ```bash
   sudo drbdadm connect r0
   ```
5. Observe the Split-Brain diagnostic output:
   ```bash
   sudo drbdadm status r0
   ```

*Expected Terminal Output (Split-Brain state):*
```text
r0 role:Primary
  disk:UpToDate
  node2 connection:StandAlone
```
*Kernel Log (`dmesg | tail -n 15`):*
```text
drbd r0: Split-Brain detected, dropping connection!
drbd r0: Helper process returned 7 (split-brain detected)
drbd r0: conn( Unconnected ) -> conn( StandAlone )
```

#### Step 5: Execute Manual Split-Brain Recovery (Victim vs Survivor)
Designate `node2` as the **Victim** (data overwritten) and `node1` as the **Survivor** (authoritative source).

On **Victim (`node2`)**:
```bash
sudo drbdadm secondary r0
sudo drbdadm connect --discard-my-data r0
```

On **Survivor (`node1`)**:
```bash
sudo drbdadm connect r0
```

Verify status on `node1` while resynchronization completes:
```bash
sudo drbdadm status r0
```

*Expected Output:*
```text
r0 role:Primary
  disk:UpToDate
  node2 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:45.32%
```

---

### 1.3 Verification Questions (Exercise 1)

1. In DRBD Protocol C, at what exact instant is a `write()` system call acknowledged as complete to the application process?
   - A) When written to the local disk kernel page cache.
   - B) When sent over the local TCP socket buffer.
   - C) When written to local disk AND received in remote RAM.
   - D) When written to local non-volatile storage AND committed to remote physical disk.

2. A DRBD cluster reports `cstate:StandAlone` with kernel logs stating `Split-Brain detected`. What command must be executed on the victim node first to initiate recovery?
   - A) `drbdadm primary --force r0`
   - B) `drbdadm secondary r0` followed by `drbdadm connect --discard-my-data r0`
   - C) `drbdmeta /dev/sdb v09 apply-al`
   - D) `drbdadm invalidate r0`

---

## Exercise 2: Cluster Storage Access — iSCSI Target, Initiator, & Multipath I/O

### 2.1 Deep Technical Mechanics & Architecture

iSCSI wraps SCSI Command Descriptor Blocks (CDBs) inside TCP/IP packets (port 3260). High Availability SAN storage relies on multiple distinct physical network paths between Initiator (Client) and Target (Storage Server).

```
+---------------------------------------------------------------+
|                       Linux Kernel Block Layer                |
|                           (/dev/dm-0)                         |
+---------------------------------------------------------------+
                                |
                   +------------+------------+
                   |  dm-multipath (multipathd) |
                   +------------+------------+
                                |
             +------------------+------------------+
             |                                     |
             v                                     v
   +-------------------+                 +-------------------+
   | /dev/sdb (Path A) |                 | /dev/sdc (Path B) |
   | Network Interface 1                 | Network Interface 2
   +---------+---------+                 +---------+---------+
             |                                     |
             +------------------+------------------+
                                |
                                v
                   [ Storage Array / iSCSI Target ]
                   [ ALUA State: Active / Optimized]
```

* **Target Port Groups (TPG):** Logical groupings of target IP addresses, portals, and LUNs.
* **ALUA (Asymmetrical Logical Unit Access):** Enables storage arrays to inform `multipathd` about active/optimized paths vs passive/unoptimized paths.
* **Path Checkers:** `multipathd` periodically probes paths using SCSI commands (`tur` - Test Unit Ready, `directio`, or `readsector0`).

---

### 2.2 Guided Execution Steps

#### Step 1: Configure iSCSI Target via `targetcli` (Storage Node)
Run `targetcli` to export a local block device `/dev/vg_san/lv_shared` to initiator `iqn.2026-08.com.example:node1`:

```bash
sudo targetcli
```

Inside the interactive `targetcli` shell, execute:

```text
/> cd /backstores/block
/backstores/block> create name=shared_block dev=/dev/vg_san/lv_shared
/backstores/block> cd /iscsi
/iscsi> create iqn.2026-08.com.example:storage.target1
/iscsi> cd iqn.2026-08.com.example:storage.target1/tpg1/
/iscsi/iqn.20...y/tpg1> luns/ create /backstores/block/shared_block
/iscsi/iqn.20...y/tpg1> acls/ create iqn.2026-08.com.example:node1
/iscsi/iqn.20...y/tpg1> portals/ create 192.168.10.50 3260
/iscsi/iqn.20...y/tpg1> portals/ create 192.168.20.50 3260
/iscsi/iqn.20...y/tpg1> cd /
/> saveconfig
/> exit
```

#### Step 2: Configure Initiator Discovery and Login (Client Node)
On `node1`:
1. Set initiator IQN in `/etc/iscsi/initiatorname.iscsi`:
   ```conf
   InitiatorName=iqn.2026-08.com.example:node1
   ```
2. Discover targets across dual network paths:
   ```bash
   sudo iscsiadm -m discovery -t sendtargets -p 192.168.10.50:3260
   ```
3. Log in to all discovered portals:
   ```bash
   sudo iscsiadm -m node --login
   ```

*Expected Output:*
```text
Logging in to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.10.50,3260] (multiple)
Logging in to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.20.50,3260] (multiple)
Login to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.10.50,3260] successful.
Login to [iface: default, target: iqn.2026-08.com.example:storage.target1, portal: 192.168.20.50,3260] successful.
```

#### Step 3: Configure `/etc/multipath.conf` for Production Failover
Synthesize `/etc/multipath.conf` on `node1`:

```conf
# /etc/multipath.conf
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "none"
}

blacklist {
    devnode "^sda"
}

multipaths {
    multipath {
        wwid 36001405a1234567890abcdef00000001
        alias mpath_ha_storage
    }
}

devices {
    device {
        vendor "LIO-ORG"
        product "IBLOCK"
        path_grouping_policy group_by_prio
        path_selector "service-time 0"
        path_checker tur
        features "1 queue_if_no_path"
        hardware_handler "1 alua"
        prio alua
        failback immediate
        rr_weight priority
        no_path_retry 12
        fast_io_fail_tmo 5
        dev_loss_tmo 30
    }
}
```

Restart and verify `multipathd`:
```bash
sudo systemctl restart multipathd
sudo multipath -ll
```

*Expected Output:*
```text
mpath_ha_storage (36001405a1234567890abcdef00000001) dm-0 LIO-ORG,IBLOCK
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| `- 3:0:0:0 sdb 8:16 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  `- 4:0:0:0 sdc 8:32 active ready running
```

---

### 2.3 Verification Questions (Exercise 2)

1. What is the operational impact of setting `features "1 queue_if_no_path"` in `/etc/multipath.conf` when all physical storage paths fail?
   - A) System immediately returns I/O errors (`EIO`) to application processes.
   - B) Application I/O requests are blocked and queued in kernel space until a path recovers or timeouts trigger.
   - C) `multipathd` automatically unmounts the underlying file system.
   - D) The kernel kernel-panics to preserve data integrity.

2. Which command displays full path state, priority values, and ALUA metadata for all multipathing block devices?
   - A) `iscsiadm -m session -P 3`
   - B) `multipath -ll`
   - C) `targetcli ls`
   - D) `lvs -a -o +devices`

---

## Exercise 3: Shared Disk Clustered File Systems — GFS2, DLM, and OCFS2

### 3.1 Deep Technical Mechanics & Architecture

Shared disk file systems allow multiple nodes to concurrently read and write to the same physical or virtual block device. Data corruption is prevented via distributed locking.

```
Node 1                                              Node 2
+-----------------------+                           +-----------------------+
|  GFS2 File System     |                           |  GFS2 File System     |
+-----------------------+                           +-----------------------+
| DLM Kernel Module     |<==== Lock Ping/Ack =======>| DLM Kernel Module     |
| (Lockspace: "cluster")|      (TCP/IP / SCTP)      | (Lockspace: "cluster")|
+-----------------------+                           +-----------------------+
| Journal 0             |                           | Journal 1             |
+-----------------------+                           +-----------------------+
           |                                                   |
           +-------------------------+-------------------------+
                                     |
                                     v
                       [ Shared Block Device ]
                       [ /dev/drbd0 or dm-0  ]
```

* **DLM (Distributed Lock Manager):** Manages cluster-wide locks (`lock_dlm`) over IP networks via Corosync cluster messaging.
* **GFS2 Journals:** Every node mounting a GFS2 volume *must* have its own dedicated journal (`-j` parameter). Journals track uncommitted metadata operations. If Node 1 crashes, Node 2 replays Node 1's journal to recover file system consistency.
* **Fencing (STONITH) Requirement:** STONITH (Shoot The Other Node In The Head) is mandatory. If a node loses cluster quorum or fails to respond to DLM heartbeat checks, it must be forcefully power-cycled before lock recovery can occur.

---

### 3.2 Guided Execution Steps

#### Step 1: Verify Corosync & DLM Service Prerequisites
On `node1` and `node2`, ensure Pacemaker/Corosync cluster services are active and DLM daemon (`dlm_controld`) is operational:

```bash
sudo pcs status
```

*Expected Output:*
```text
Cluster name: alpha_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: node1.example.com (version 2.1.5) - partition with quorum
  * 2 nodes online: [ node1.example.com node2.example.com ]

Full List of Resources:
  * clone_dlm    (ocf::pacemaker:controld): Started [ node1.example.com node2.example.com ]
```

#### Step 2: Format Shared Block Device with GFS2
Format `/dev/drbd0` from `node1`. The table format is `-t <clustername>:<fsname>`:

```bash
sudo mkfs.gfs2 -p lock_dlm -t alpha_cluster:shared_data -j 2 /dev/drbd0
```

*Expected Output:*
```text
It appears that the device is a DRBD block device.
This will destroy any data on /dev/drbd0.
Are you sure you want to proceed? (y/n) y
Device:                    /dev/drbd0
Block size:                4096
Journals:                  2
Resource groups:           250
Locking protocol:          lock_dlm
Lock table:                alpha_cluster:shared_data
UUID:                      a1b2c3d4-e5f6-7890-abcd-1234567890ab
```

#### Step 3: Mount GFS2 on Concurrent Nodes
Execute on **both `node1` and `node2`**:

```bash
sudo mkdir -p /mnt/shared_gfs2
sudo mount -t gfs2 -o noatime /dev/drbd0 /mnt/shared_gfs2
```

Verify mount status:
```bash
findmnt /mnt/shared_gfs2
```

*Expected Output (`node1` & `node2`):*
```text
TARGET           SOURCE     FSTYPE OPTIONS
/mnt/shared_gfs2 /dev/drbd0 gfs2   rw,noatime,seclabel
```

#### Step 4: Add Journals for Cluster Expansion (`gfs2_jadd`)
To add a 3rd node (`node3`) to the cluster, expand the journal count on an existing mounted node (`node1`):

```bash
sudo gfs2_jadd -j 1 /mnt/shared_gfs2
```

Verify updated journal configuration:
```bash
sudo gfs2_tool journals /mnt/shared_gfs2
```

*Expected Output:*
```text
Journal 0: 128MB
Journal 1: 128MB
Journal 2: 128MB
3 journal(s) found.
```

#### Step 5: Advanced DLM Lock Diagnostics
Inspect active DLM lockspaces and lock state dumps:

```bash
sudo dlm_tool ls
sudo dlm_tool lockdebug alpha_cluster:shared_data
```

*Expected Output (`dlm_tool ls`):*
```text
dlm lockspaces
name          alpha_cluster:shared_data
id            0x4b2a8f01
flags         0x00000000
change        member count 2 status dirty
members       1 2
```

---

### 3.3 Verification Questions (Exercise 3)

1. What happens if a node mounting a GFS2 file system suffers a hardware power failure while holding active metadata locks?
   - A) The remaining nodes freeze indefinitely waiting for lock release.
   - B) Corosync triggers fencing (STONITH); once fenced, a surviving node replays the crashed node's dedicated GFS2 journal and releases its locks.
   - C) GFS2 switches to read-only mode across all nodes.
   - D) The file system runs `fsck.gfs2` automatically across all mounted paths live.

2. When formatting a GFS2 file system using `mkfs.gfs2 -p lock_dlm -t cluster_A:data1 -j 4 /dev/sdb`, what does the string `cluster_A:data1` represent?
   - A) The username and password for DLM authentication.
   - B) The Corosync cluster name (`cluster_A`) and unique GFS2 lockspace name (`data1`).
   - C) The target directory path where the device will be mounted.
   - D) The LVM volume group and logical volume identifier.

---

## Exercise 4: High Availability Distributed Storage — GlusterFS Architecture & Operations

### 4.1 Deep Technical Mechanics & Architecture

GlusterFS is a scale-out, user-space distributed file system operating via FUSE (Filesystem in Userspace). It uses no central metadata server; data location is calculated algorithmically using Elastic Hash Algorithms.

```
                                Client App
                                    |
                            [ FUSE Layer ]
                                    |
                       [ GlusterFS Client Stack ]
                       [ (xlators: AFR, DHT)    ]
                                    |
          +-------------------------+-------------------------+
          | (RPC Port 24007)                                  | (RPC Port 24007)
          v                                                   v
   Node 1 Brick                                        Node 2 Brick
[ /data/brick1/gv0/ ]                               [ /data/brick1/gv0/ ]
[ POSIX FS + XATTR  ]                               [ POSIX FS + XATTR  ]
  trusted.glusterfs.active                            trusted.glusterfs.active
```

#### Key Components & Translators (xlators):
* **Bricks:** A file system mount point (e.g., XFS) with a storage directory exported to GlusterFS.
* **AFR (Automatic File Replication):** Handles data replication across bricks; maintains extended attributes (`trusted.glusterfs.afr.*`) on underlying POSIX file systems to track metadata and data changelogs.
* **glustershd (Self-Heal Daemon):** Background daemon running on every node that scans bricks for pending changelogs and repairs out-of-sync files asynchronously.

---

### 4.2 Guided Execution Steps

#### Step 1: Peer Probe and Pool Initialization
From `node1` (192.168.1.10), add `node2` (192.168.1.11) and `node3` (192.168.1.12) to the Trusted Storage Pool:

```bash
sudo gluster peer probe 192.168.1.11
sudo gluster peer probe 192.168.1.12
```

Verify storage pool peer status:
```bash
sudo gluster peer status
```

*Expected Output:*
```text
Number of Peers: 2

Hostname: 192.168.1.11
Uuid: 5e6f7a8b-9c0d-1e2f-3a4b-5c6d7e8f9a0b
State: Peer in Cluster (Connected)

Hostname: 192.168.1.12
Uuid: 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
State: Peer in Cluster (Connected)
```

#### Step 2: Create a 3-Way Replicated GlusterFS Volume
Create and start volume `vol_ha` spanning bricks on all 3 nodes:

```bash
sudo gluster volume create vol_ha replica 3 \
  192.168.1.10:/data/brick1/vol_ha \
  192.168.1.11:/data/brick1/vol_ha \
  192.168.1.12:/data/brick1/vol_ha force

sudo gluster volume start vol_ha
```

Configure strict quorum to prevent split-brain:
```bash
sudo gluster volume set vol_ha cluster.quorum-type auto
sudo gluster volume set vol_ha cluster.ping-timeout 10
```

Verify volume operational status:
```bash
sudo gluster volume info vol_ha
```

*Expected Output:*
```text
Volume Name: vol_ha
Type: Replicate
Volume ID: c3d4e5f6-7a8b-9c0d-1e2f-3a4b5c6d7e8f
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: 192.168.1.10:/data/brick1/vol_ha
Brick2: 192.168.1.11:/data/brick1/vol_ha
Brick3: 192.168.1.12:/data/brick1/vol_ha
Options Reconfigured:
cluster.ping-timeout: 10
cluster.quorum-type: auto
transport.address-family: inet
nfs.disable: on
performance.client-io-threads: off
```

#### Step 3: Trigger & Diagnose GlusterFS Split-Brain
If two bricks lose connectivity and receive divergent writes independently, the volume enters Split-Brain.

1. Inspect pending split-brain state via CLI:
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```

*Expected Output (split-brain detected):*
```text
Brick 192.168.1.10:/data/brick1/vol_ha
<gfid:a4b5c6d7-e8f9-0a1b-2c3d-4e5f6a7b8c9d>
Number of entries: 1

Brick 192.168.1.11:/data/brick1/vol_ha
<gfid:a4b5c6d7-e8f9-0a1b-2c3d-4e5f6a7b8c9d>
Number of entries: 1
```

2. Inspect underlying POSIX Extended Attributes (xattrs) on brick path:
   ```bash
   sudo getfattr -d -m "trusted.glusterfs" /data/brick1/vol_ha/file1.dat
   ```

*Expected Output:*
```text
# file: data/brick1/vol_ha/file1.dat
trusted.glusterfs.afr.vol_ha-client-0=0x000000000000000000000001
trusted.glusterfs.afr.vol_ha-client-1=0x000000010000000000000000
trusted.glusterfs.version=0x0000000000000001
```

#### Step 4: Resolve Split-Brain via CLI Policies
Resolve split-brain by picking `192.168.1.10` as the authoritative source file:

```bash
sudo gluster volume heal vol_ha split-brain source-brick 192.168.1.10:/data/brick1/vol_ha /file1.dat
```

*Expected Output:*
```text
Healing /file1.dat localized on 192.168.1.10:/data/brick1/vol_ha ... Success
```

Force background self-healing verification:
```bash
sudo gluster volume heal vol_ha
```

---

### 4.3 Verification Questions (Exercise 4)

1. How does GlusterFS track file modifications and pending sync operations across bricks without a central database?
   - A) By logging writes in `/var/log/glusterfs/glusterd.log`.
   - B) By writing metadata into POSIX Extended Attributes (`trusted.glusterfs.afr.*`) directly on file headers inside brick storage paths.
   - C) By keeping changes exclusively in host RAM caches.
   - D) By storing state in an external Etcd cluster.

2. Which GlusterFS volume option guarantees that a 3-way replicated volume blocks all client write operations if fewer than 2 nodes are active, avoiding split-brain?
   - A) `cluster.self-heal-daemon off`
   - B) `cluster.quorum-type auto`
   - C) `performance.stat-prefetch off`
   - D) `features.shard on`

---

## Exercise 5: Enterprise Distributed Object & Block Storage — Ceph Architecture & Operations

### 5.1 Deep Technical Mechanics & Architecture

Ceph provides object (RADOS), block (RBD), and file (CephFS) storage backed by an autonomous self-healing object store engine.

```
+-------------------------------------------------------------------+
|               Ceph Storage Applications / Clients                 |
+-------------------+-----------------------+-----------------------+
|  RADOS Gateway    |  RADOS Block Device   |  CephFS File System   |
|   (S3 / Swift)    |      (RBD Kernel)     |      (MDS Daemon)     |
+-------------------+-----------------------+-----------------------+
                                |
                                v
+-------------------------------------------------------------------+
|                        RADOS Cluster Layer                        |
|                                                                   |
|   +-------------------+  +-------------------+  +-------------+   |
|   | Ceph MON (Paxos)  |  | Ceph MGR (Metrics)|  | CRUSH Engine|   |
|   +-------------------+  +-------------------+  +-------------+   |
|                                                                   |
|   [OSD.0]        [OSD.1]        [OSD.2]        [OSD.3]        ... |
+-------------------------------------------------------------------+
```

#### Core Subsystems:
* **Ceph MON (Monitors):** Maintains cluster map master state (mon map, osd map, pg map, crush map) using the Paxos consensus algorithm. Requires an odd number of MONs ($N/2 + 1$) for quorum.
* **Ceph OSD (Object Storage Daemon):** Manages local disk storage (BlueStore engine), responds to client read/write calls, handles replication, scrubbing, and recovery.
* **CRUSH Algorithm (Controlled Replication Under Scalable Hashing):** Eliminates central metadata lookups. Clients calculate exact target OSD IDs deterministically using CRUSH rules based on object name and cluster map topology.
* **Placement Groups (PGs):** Logical aggregations of objects mapped to target OSD sets.
  * *PG Lifecycle States:* `active+clean` -> `peering` -> `degraded` -> `recovering` -> `undersized` -> `inconsistent`.

---

### 5.2 Guided Execution Steps

#### Step 1: Health Inspection & MON Paxos Quorum Verification
Execute cluster health inspection CLI commands:

```bash
sudo ceph -s
sudo ceph quorum_status --format json-pretty
```

*Expected Output (`ceph -s`):*
```text
  cluster:
    id:     7f3a8b2c-1e4d-5f6a-8b0c-9d8e7f6a5b4c
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum mon1,mon2,mon3 (age 2d)
    mgr: mon1(active, since 2d), standbys: mon2
    osd: 6 osds: 6 up, 6 in

  data:
    pools:   2 pools, 64 pgs
    objects: 1.25k objects, 4.8 GiB
    usage:   14.6 GiB used, 585 GiB / 600 GiB avail
    pgs:     64 active+clean
```

#### Step 2: Create OSD Pool & Map RADOS Block Device (RBD)
Create a replicated pool named `pool_ha` with 64 PGs and provision an RBD block image:

```bash
sudo ceph osd pool create pool_ha 64 64 replicated
sudo ceph osd pool application enable pool_ha rbd
rbd create --size 10240 pool_ha/vol_block_01
rbd info pool_ha/vol_block_01
```

*Expected Output (`rbd info`):*
```text
rbd image 'vol_block_01':
	size 10 GiB in 2560 objects
	order 22 (4 MiB objects)
	snapshot_count: 0
	id: 4f1a2b3c4d5e
	block_name_prefix: rbd_data.4f1a2b3c4d5e
	format: 2
	features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
	op_features: 
	flags: 
	create_timestamp: Thu Aug  6 17:14:39 2026
```

Map the RBD image into kernel space as `/dev/rbd0`:
```bash
sudo rbd map pool_ha/vol_block_01
lsblk /dev/rbd0
```

*Expected Output:*
```text
NAME lg-size major:minor ro size type mountpoint
rbd0          252:0        0  10G disk 
```

#### Step 3: Simulate OSD Degradation and Track PG State Machine
1. Force stop `osd.2` daemon to trigger degraded state:
   ```bash
   sudo systemctl stop ceph-osd@2
   ```
2. Monitor health transitions:
   ```bash
   sudo ceph health detail
   ```

*Expected Output:*
```text
HEALTH_WARN 1 osds down; 16 pgs degraded; 16 pgs undersized
[WRN] OSD_DOWN: 1 osds down
    osd.2 (root=default,host=node2) is down
[WRN] PG_DEGRADED: Degraded data redundancy: 16/64 pgs degraded
    pg 2.1a is stuck degraded for 45s, act: [2,0] -> [0]
```

3. Query specific PG metadata internal details:
   ```bash
   sudo ceph pg 2.1a query
   ```

#### Step 4: Detect and Repair Inconsistent Placement Groups (Scrubbing)
If silent data corruption occurs on an OSD, scrubbing marks the PG as `inconsistent`.

```bash
sudo ceph pg deep-scrub 2.1a
sudo ceph health detail
```

*Expected Output (If silent corruption exists):*
```text
HEALTH_ERR 1 pgs inconsistent; 1 scrub errors
[ERR] PG_DAMAGED: Possible data damaged on 1 pgs
    pg 2.1a is active+clean+inconsistent, acting [0,1,3]
```

Execute online PG repair:
```bash
sudo ceph pg repair 2.1a
```

*Expected Output:*
```text
instructing pg 2.1a on osd.0 to repair
```

Verify state returns to clean:
```bash
sudo ceph pg stat
```

*Expected Output:*
```text
64 pgs: 64 active+clean; 4.8 GiB data, 14.6 GiB used, 585 GiB / 600 GiB avail
```

---

### 5.3 Verification Questions (Exercise 5)

1. In a Ceph cluster with 3 Monitor nodes (MONs), what is the minimum number of MON daemons that must remain online and communicating to maintain Paxos consensus and process client requests?
   - A) 1
   - B) 2
   - C) 3
   - D) 0 (MONs are only needed during initial bootstrap)

2. How does the Ceph client library determine which specific OSD to contact when writing object `obj_data_001`?
   - A) It sends an ARP broadcast to find the master MON node address.
   - B) It queries an active Redis instance storing object metadata.
   - C) It passes the object name and CRUSH map locally through the CRUSH algorithm to calculate the target OSD ID deterministically.
   - D) It sends write operations sequentially to `osd.0`, which redirects them.

---

<details>
<summary><strong>Solutions and Explanations</strong></summary>

### Exercise 1 Solutions
* **1.1 Answer: D**  
  *Explanation:* In DRBD Protocol C, write operations are completely synchronous. The local kernel block layer does not return write completion to the calling application until local storage I/O finishes **and** the remote peer acknowledges that data was committed to non-volatile disk storage.
* **1.2 Answer: B**  
  *Explanation:* When DRBD detects Split-Brain, the resource transitions to `StandAlone`. To resolve this state manually, the administrator selects the victim node, demotes it to `secondary` if necessary, and runs `drbdadm connect --discard-my-data <resource>`. Subsequently, connecting the survivor node triggers synchronization from survivor to victim.

---

### Exercise 2 Solutions
* **2.1 Answer: B**  
  *Explanation:* The `queue_if_no_path` feature (equivalent to `no_path_retry`) instructs `multipathd` to queue incoming application block I/O requests in kernel memory during total path loss rather than failing writes immediately with `EIO`.
* **2.2 Answer: B**  
  *Explanation:* `multipath -ll` parses `/sys/class/san_path` and `dm-multipath` kernel devices, displaying active paths, path states (`active`, `enabled`, `failed`), priority values, and ALUA path target group states.

---

### Exercise 3 Solutions
* **3.1 Answer: B**  
  *Explanation:* GFS2 requires a mandatory fencing mechanism (STONITH). When a node crashes, Pacemaker/Corosync isolates and powers off the failed node. Once fencing confirmation is received by DLM, a surviving cluster node accesses the crashed node's dedicated GFS2 journal, replays uncommitted metadata, and releases orphaned locks.
* **3.2 Answer: B**  
  *Explanation:* The `-t <clustername>:<fsname>` parameter passed to `mkfs.gfs2` specifies the Corosync cluster identifier (`cluster_A`) and the distinct lockspace table (`data1`) that DLM binds to when managing lock state across nodes.

---

### Exercise 4 Solutions
* **4.1 Answer: B**  
  *Explanation:* GlusterFS uses POSIX Extended Attributes (xattrs) like `trusted.glusterfs.afr.*` stored directly on local brick directories/files to track data, metadata, and entry pending changelogs for self-healing.
* **4.2 Answer: B**  
  *Explanation:* `cluster.quorum-type auto` activates server-side quorum verification. In a 3-way replicated volume, if active node count drops below $\lfloor N/2 \rfloor + 1 = 2$, GlusterFS rejects write I/O to prevent split-brain creation.

---

### Exercise 5 Solutions
* **5.1 Answer: B**  
  *Explanation:* Ceph MONs use Paxos consensus. Maintaining quorum requires a strict majority of nodes: $Q = \lfloor N/2 \rfloor + 1$. For $N=3$, $Q = \lfloor 3/2 \rfloor + 1 = 2$.
* **5.2 Answer: C**  
  *Explanation:* Ceph eliminates central metadata bottlenecks. Ceph clients compute object placement by hashing object identifiers into Placement Group (PG) IDs and passing the result along with the current cluster map through the local CRUSH (Controlled Replication Under Scalable Hashing) algorithm.

</details>

---

## Technical Citations & Official References

* **Linux Professional Institute (LPI) LPIC-3 306 Objectives:** [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* **LINBIT DRBD 9.0 Official User's Guide:** [https://docs.linbit.com/docs/users-guide-9.0/](https://docs.linbit.com/docs/users-guide-9.0/)
* **Red Hat Enterprise Linux 9 - Configuring and Managing Storage Devices (iSCSI & Multipath):** [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/)
* **Red Hat Enterprise Linux 9 - GFS2 File System Architecture and Administration:** [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/)
* **GlusterFS Architecture & Operations Documentation:** [https://docs.gluster.org/en/latest/Architecture/](https://docs.gluster.org/en/latest/Architecture/)
* **Ceph Storage Architecture & Operations Manual:** [https://docs.ceph.com/en/latest/architecture/](https://docs.ceph.com/en/latest/architecture/)