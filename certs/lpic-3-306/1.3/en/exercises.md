# LPIC-3 Exam 306-300 (v3.0) — Topic 306.3: High Availability Distributed Storage

**Weight:** 25  
**Official Reference Sources:**
* [LPI LPIC-3 Exam 306-300 Objectives Overview](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* [Ceph Storage Documentation](https://docs.ceph.com/en/latest/)
* [GlusterFS Architecture & Administration Manual](https://docs.gluster.org/en/latest/)
* [LINBIT DRBD 9.0 User Guide](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/)

---

## Exercise 1: Ceph Cluster Initialization, CRUSH Rule Engineering, and BlueStore Diagnostic Recovery

### Architecture & Mechanics Overview
Ceph achieves high availability and scalable object/block/file storage through the **Controlled Replication Under Scalable Hashing (CRUSH)** algorithm. Unlike traditional storage clusters that rely on a centralized metadata lookup table, Ceph clients compute object locations directly using a deterministic CRUSH calculation based on:
1. The Object ID.
2. The target **Placement Group (PG)** mapping ($PG\_ID = hash(object\_name) \pmod {num\_pgs}$).
3. The cluster's **CRUSH Map hierarchy** and defined **CRUSH rules**.

Storage nodes run **Ceph Object Storage Daemons (OSDs)** utilizing the **BlueStore** backend engine, which directly manages raw block devices via `RocksDB` (for metadata and write-ahead logs) and `BlueFS` (an internal minimal filesystem backing RocksDB), bypassing the Linux page cache and virtual file system (VFS) layer to eliminate filesystem-level journaling overhead. Cluster quorum and state consensus (OSD maps, Monitor maps, PG maps) are maintained by **Ceph Monitors (MONs)** running a Paxos-based distributed consensus protocol.

```
+-------------------------------------------------------------------------+
|                              Ceph Client                                |
|   1. Hash Object ID ---> 2. Map to PG ---> 3. CRUSH calculation OSD Set |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                          Ceph Storage Cluster                           |
|  +-------------------+  +-------------------+  +---------------------+  |
|  | OSD.0 (Primary)   |  | OSD.1 (Secondary) |  | OSD.2 (Tertiary)    |  |
|  | +---------------+ |  | +---------------+ |  | +-----------------+ |  |
|  | | BlueStore Engine|  | | BlueStore Engine|  | | BlueStore Engine| |  |
|  | | - RocksDB     | |  | | - RocksDB     | |  | | - RocksDB       | |  |
|  | | - BlueFS      | |  | | - BlueFS      | |  | | - BlueFS        | |  |
|  | +---------------+ |  | +---------------+ |  | +-----------------+ |  |
|  +-------------------+  +-------------------+  +---------------------+  |
+-------------------------------------------------------------------------+
```

---

### Execution Steps

1. Inspect the running Ceph daemon statuses and health state across the nodes.
   ```bash
   sudo ceph health detail
   ```
   *Expected Output:*
   ```text
   HEALTH_OK
   ```

2. Retrieve the active OSD tree structure to identify the failure domain hierarchy (root, rack, host).
   ```bash
   sudo ceph osd tree
   ```
   *Expected Output:*
   ```text
   ID  CLASS  WEIGHT   TYPE NAME           STATUS  REWEIGHT  PRIO-SET
   -1         0.23999  root default                                  
   -3         0.07999      rack rack1                                
   -2         0.07999          host node01                           
    0   ssd   0.03999              osd.0       up   1.00000   1.00000
    1   ssd   0.03999              osd.1       up   1.00000   1.00000
   -4         0.07999      rack rack2                                
   -5         0.07999          host node02                           
    2   ssd   0.03999              osd.2       up   1.00000   1.00000
    3   ssd   0.03999              osd.3       up   1.00000   1.00000
   -6         0.07999      rack rack3                                
   -7         0.07999          host node03                           
    4   ssd   0.03999              osd.4       up   1.00000   1.00000
    5   ssd   0.03999              osd.5       up   1.00000   1.00000
   ```

3. Export the compiled CRUSH map, decompile it into plain text, and inspect the default placement rules.
   ```bash
   sudo ceph osd getcrushmap -o /tmp/crushmap.bin
   crushtool -d /tmp/crushmap.bin -o /tmp/crushmap.txt
   cat /tmp/crushmap.txt | grep -A 8 "rule replicated_ruleset"
   ```
   *Expected Output:*
   ```text
   rule replicated_ruleset {
           id 0
           type replicated
           step take default
           step chooseleaf firstn 0 type host
           step emit
   }
   ```

4. Create a custom CRUSH rule named `rack_aware_rule` that enforces data replication across distinct **racks** rather than individual hosts.
   ```bash
   sudo ceph osd crush rule create-replicated rack_aware_rule default rack ssd
   sudo ceph osd crush rule ls
   ```
   *Expected Output:*
   ```text
   replicated_ruleset
   rack_aware_rule
   ```

5. Create a dedicated storage pool named `production_data` configured with 64 PGs and assign the `rack_aware_rule` to it.
   ```bash
   sudo ceph osd pool create production_data 64 64 replicated rack_aware_rule
   sudo ceph osd pool set production_data size 3
   sudo ceph osd pool set production_data min_size 2
   ```

6. Verify pool parameters and operational PG mapping.
   ```bash
   sudo ceph osd pool get production_data all | egrep "size|crush_rule"
   ```
   *Expected Output:*
   ```text
   size: 3
   min_size: 2
   crush_rule: rack_aware_rule
   ```

7. Simulate a hardware fault by marking `osd.0` down and out of the cluster, then observe the PG state transitions during peer peering and backfill recovery.
   ```bash
   sudo ceph osd down osd.0
   sudo ceph osd out osd.0
   sudo ceph -w
   ```
   *Expected Output:*
   ```text
   2026-08-06 17:30:10.102938 mon.node01 osd.0 line 1: osd.0 is down
   2026-08-06 17:30:12.482019 mon.node01 pgmap v4021: 64 pgs: 64 active+clean; 0B data, 1.2GiB used, 240GiB / 241GiB avail
   2026-08-06 17:30:15.892019 mon.node01 pgmap v4022: 64 pgs: 12 active+undersized+degraded, 52 active+clean
   2026-08-06 17:30:22.110293 mon.node01 pgmap v4025: 64 pgs: 12 active+remapped+backfilling, 52 active+clean
   2026-08-06 17:30:35.402111 mon.node01 pgmap v4030: 64 pgs: 64 active+clean
   ```

8. Inspect the BlueStore metadata and block allocation statistics for a specific healthy OSD (`osd.1`).
   ```bash
   sudo ceph-volume lvm list /dev/sdb
   sudo ceph osd metadata 1 | jq '{id, bluefs_dedicated_db, osd_data, storage_backend}'
   ```
   *Expected Output:*
   ```json
   {
     "id": 1,
     "bluefs_dedicated_db": "1",
     "osd_data": "/var/lib/ceph/osd/ceph-1",
     "storage_backend": "bluestore"
   }
   ```

---

### Verification Questions

#### Question 1.1
A Ceph cluster administrator creates a pool with `size = 3` and `min_size = 2`. Due to a network partition, two out of three OSDs holding replicas of a specific PG become unreachable. The remaining primary OSD has `min_size = 2` enforced. What is the precise client write behavior for I/O requests directed to this PG, and why?

#### Question 1.2
In a BlueStore-backed OSD, what specific role does `RocksDB` play, which component stores `RocksDB` data if no dedicated fast NVMe drive is provided, and what diagnostic tool provides insight into BlueFS device allocation space?

---

## Exercise 2: GlusterFS Distributed-Replicated Volume Provisioning and Split-Brain Recovery Mechanics

### Architecture & Mechanics Overview
GlusterFS is a scale-out, user-space cluster filesystem operating via FUSE (Filesystem in Userspace). It abstracts underlying local filesystems (XFS) on storage servers (**Bricks**) into a unified namespace without centralized metadata servers. Volume behavior is governed by a stack of modular units called **Translators (xlators)**:

1. **Protocol/client translator**: Handles network transport via TCP/IP or RDMA.
2. **AFR (Automatic File Replication) translator**: Implements synchronous file-level replication, locking, and Extended Attribute (`xattr`) updates (`trusted.afr.<volume>-client-*`).
3. **DHT (Distributed Hash Table) translator**: Maps filenames to specific brick pairs using consistent hashing over a 32-bit checksum space.

When a network partition occurs between bricks in a replicated volume, concurrent writes to the same file on both partitions corrupt the extended attribute changelogs, resulting in a **Split-Brain state**. GlusterFS prevents inconsistent data reads by blocking I/O access to affected files until manual or policy-based resolution is performed using the `gluster volume heal` toolchain or extended attribute modification (`attr` / `setfattr`).

```
+-------------------------------------------------------------------+
|                        GlusterFS Client                           |
|  +-------------------------------------------------------------+  |
|  | DHT Translator (Distributes files across brick subvolumes)  |  |
|  +-------------------------------------------------------------+  |
|         |                                        |                |
|         v                                        v                |
|  +--------------------------+         +--------------------------+|
|  | AFR Translator (Replica 1)|         | AFR Translator (Replica 2)||
|  +--------------------------+         +--------------------------+|
+-------------------------------------------------------------------+
       |                  |                    |                  |
       v                  v                    v                  v
+--------------+   +--------------+     +--------------+   +--------------+
| Node1: Brick1|   | Node2: Brick2|     | Node3: Brick3|   | Node4: Brick4|
| (Subvol 0)   |   | (Subvol 0)   |     | (Subvol 1)   |   | (Subvol 1)   |
+--------------+   +--------------+     +--------------+   +--------------+
```

---

### Execution Steps

1. Verify the GlusterFS trusted storage pool peer connectivity across four nodes (`node01` to `node04`).
   ```bash
   sudo gluster peer status
   ```
   *Expected Output:*
   ```text
   Number of Peers: 3

   Hostname: node02
   Uuid: 8f4a100a-4d22-411a-a92d-904d9b1092a1
   State: Peer in Cluster (Connected)

   Hostname: node03
   Uuid: 7b311c12-32a1-432d-b102-109238471ad2
   State: Peer in Cluster (Connected)

   Hostname: node04
   Uuid: c410a991-0193-4a11-821c-99120485912a
   State: Peer in Cluster (Connected)
   ```

2. Provision a **Distributed-Replicated** GlusterFS volume named `vol_ha` consisting of 4 bricks (2 subvolumes with 2 replicas each).
   ```bash
   sudo gluster volume create vol_ha replica 2 \
     node01:/data/glusterfs/brick1/b1 \
     node02:/data/glusterfs/brick2/b1 \
     node03:/data/glusterfs/brick3/b1 \
     node04:/data/glusterfs/brick4/b1 \
     force
   sudo gluster volume start vol_ha
   ```
   *Expected Output:*
   ```text
   volume create: vol_ha: success: please start the volume to access data
   volume start: vol_ha: success
   ```

3. Configure network quorum on the volume to mitigate split-brain scenarios automatically when nodes disconnect.
   ```bash
   sudo gluster volume set vol_ha cluster.quorum-type auto
   sudo gluster volume set vol_ha cluster.quorum-reads false
   sudo gluster volume set vol_ha network.ping-timeout 10
   ```
   *Expected Output:*
   ```text
   volume set: success
   volume set: success
   volume set: success
   ```

4. Mount the volume on a client machine using native FUSE.
   ```bash
   sudo mkdir -p /mnt/gluster_data
   sudo mount -t glusterfs node01:/vol_ha /mnt/gluster_data
   df -hT /mnt/gluster_data
   ```
   *Expected Output:*
   ```text
   Filesystem     Type       Size  Used Avail Use% Mounted on
   node01:/vol_ha fuse.glusterfs  100G  1.2G   99G   2% /mnt/gluster_data
   ```

5. Simulate a forced split-brain condition: Block network traffic between `node01` and `node02` using `iptables` while writing conflicting data to the same file from different clients or directly on the brick backend.
   ```bash
   # On node01: append data to target file on Brick 1 directly
   echo "Data block update from Node 01" >> /data/glusterfs/brick1/b1/critical_file.txt
   
   # On node02: append conflicting data to target file on Brick 2 directly
   echo "Data block update from Node 02" >> /data/glusterfs/brick2/b1/critical_file.txt
   ```

6. Inspect the heal status log to confirm GlusterFS has flagged `critical_file.txt` in split-brain state.
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```
   *Expected Output:*
   ```text
   Brick node01:/data/glusterfs/brick1/b1
   <gfid:a8e8f230-1092-421b-8012-98401928491a>
   /critical_file.txt
   Status: Is in split-brain

   Brick node02:/data/glusterfs/brick2/b1
   <gfid:a8e8f230-1092-421b-8012-98401928491a>
   /critical_file.txt
   Status: Is in split-brain
   Number of entries in split-brain is 1
   ```

7. Resolve the split-brain state deterministically by selecting `node01` as the authoritative source file.
   ```bash
   sudo gluster volume heal vol_ha split-brain source-brick node01:/data/glusterfs/brick1/b1 /critical_file.txt
   ```
   *Expected Output:*
   ```text
   Healing /critical_file.txt completed
   ```

8. Verify split-brain status resolution.
   ```bash
   sudo gluster volume heal vol_ha info split-brain
   ```
   *Expected Output:*
   ```text
   Brick node01:/data/glusterfs/brick1/b1
   Number of entries in split-brain is 0

   Brick node02:/data/glusterfs/brick2/b1
   Number of entries in split-brain is 0
   ```

---

### Verification Questions

#### Question 2.1
What are the exact binary extended attributes (`xattrs`) assigned by GlusterFS AFR translator to files on backend bricks, and how do their hexadecimal matrix counters determine whether a file requires normal healing versus entering a split-brain state?

#### Question 2.2
In a GlusterFS volume configured with `replica 3`, how does enabling `cluster.reserve-quorum` combined with an `arbiter 1` brick affect write availability and disk utilization compared to a standard `replica 3` configuration?

---

## Exercise 3: DRBD9 Synchronous Block-Level Replication and Pacemaker Cluster Integration

### Architecture & Mechanics Overview
**DRBD (Distributed Replicated Block Device)** operates as a Linux kernel block device driver (`drbd.ko`) situated virtualized below local filesystems and above physical disk controllers. It synchronizes block-level write operations out-of-band across network links between hosts.

```
+--------------------------------------------------------------------------+
|                              Application                                 |
|                                   |                                      |
|                                   v                                      |
|                            Filesystem (XFS)                              |
+--------------------------------------------------------------------------+
                                    |
                                    v
+--------------------------------------------------------------------------+
|                          DRBD Kernel Module                              |
|   1. Local IO Write -------------------> 2. TCP/IP Network Replication    |
+--------------------------------------------------------------------------+
           |                                                 |
           v                                                 v
+-----------------------+                         +-----------------------+
|  Local Storage Disk   |                         | Remote Storage Disk   |
|  (/dev/sdb1)          |                         | (/dev/sdb1)           |
+-----------------------+                         +-----------------------+
```

DRBD supports three distinct replication modes:
* **Protocol A (Asynchronous):** Local write completes as soon as local disk I/O finishes and the write packet is placed in the local network transmit buffer.
* **Protocol B (Memory Synchronous):** Local write completes when local disk I/O finishes and the network packet reaches the remote peer's memory (TCP receiver buffer).
* **Protocol C (Fully Synchronous):** Local write completes ONLY after both local and remote storage disks acknowledge successful block write completion.

When integrated into high-availability clusters, **Pacemaker** and **Corosync** orchestrate DRBD primary/secondary roles. If node communication degrades, DRBD relies on Pacemaker's fencing mechanism (STONITH) or its own `fence-peer` handler executing hardware-level node power off (PDU/IPMI) to prevent split-brain write conditions on raw block devices.

---

### Execution Steps

1. Inspect the configuration file for the DRBD resource `ha_data` on both nodes (`node01` and `node02`).
   ```bash
   cat /etc/drbd.d/ha_data.res
   ```
   *Expected Output:*
   ```text
   resource ha_data {
     protocol C;

     net {
       fencing resource-and-stonith;
       csums-alg sha1;
       verify-alg sha1;
       on-congestion pull-ahead;
       congestion-fill-threshold 10G;
       congestion-extents 2000;
     }

     handlers {
       fence-peer "/usr/lib/drbd/crm-fence-peer.9.sh";
       unfence-peer "/usr/lib/drbd/crm-unfence-peer.9.sh";
       split-brain "/usr/lib/drbd/notify-split-brain.sh";
     }

     on node01 {
       node-id 0;
       device /dev/drbd0;
       disk /dev/sdb1;
       meta-disk internal;
       address 192.168.10.11:7788;
     }

     on node02 {
       node-id 1;
       device /dev/drbd0;
       disk /dev/sdb1;
       meta-disk internal;
       address 192.168.10.12:7788;
     }
   }
   ```

2. Initialize metadata, enable the DRBD resource, and perform initial synchronization forcing `node01` as the primary sync source.
   ```bash
   # Executed on node01:
   sudo drbdadm create-md ha_data
   sudo drbdadm up ha_data
   sudo drbdadm primary --force ha_data
   ```
   *Expected Output:*
   ```text
   Initializing metadata cumulative count 1...
   Storage engine initialized.
   Resource ha_data brought up.
   ```

3. Query the real-time block replication status using `drbdadm`.
   ```bash
   sudo drbdadm status ha_data
   ```
   *Expected Output:*
   ```text
   ha_data role:Primary
     disk:UpToDate
     node02 role:Secondary
       peer-disk:UpToDate
   ```

4. Create an XFS filesystem on the `/dev/drbd0` block device from `node01`.
   ```bash
   sudo mkfs.xfs /dev/drbd0
   sudo mkdir -p /mnt/ha_block
   sudo mount /dev/drbd0 /mnt/ha_block
   ```

5. Configure a Pacemaker cluster resource agent for the DRBD device and filesystem using `pcs`.
   ```bash
   sudo pcs cluster setup ha_cluster node01 node02 --force
   sudo pcs cluster start --all
   sudo pcs property set stonith-enabled=true
   
   # Create DRBD Data primitive and Master/Slave clone
   sudo pcs resource create DRBD_Data ocf:linbit:drbd \
     drbd_resource=ha_data \
     op monitor interval=60s role="Master" \
     op monitor interval=61s role="Slave"
     
   sudo pcs resource promotable DRBD_Data \
     promoted-max=1 promoted-node-max=1 \
     clone-max=2 clone-node-max=1 \
     notify=true

   # Create Mount primitive
   sudo pcs resource create FS_Data ocf:heartbeat:Filesystem \
     device="/dev/drbd0" \
     directory="/mnt/ha_block" \
     fstype="xfs"

   # Constrain execution order and colocation
   sudo pcs constraint colocation add FS_Data with promoted DRBD_Data-clone INFINITY
   sudo pcs constraint order promote DRBD_Data-clone then start FS_Data
   ```

6. Inspect Pacemaker cluster status to verify successful master promotion and resource mounting.
   ```bash
   sudo pcs status
   ```
   *Expected Output:*
   ```text
   Cluster name: ha_cluster
   Cluster Summary:
     * Stack: corosync
     * Current DC: node01 (version 2.1.2) - partition with quorum
     * Last updated: Thu Aug  6 17:45:12 2026
     * 2 nodes configured
     * 3 resource instances configured

   Node List:
     * Online: [ node01 node02 ]

   Full List of Resources:
     * Resource Group:
       * Clone Set: DRBD_Data-clone [DRBD_Data] (promotable):
         * Masters: [ node01 ]
         * Slaves: [ node02 ]
       * FS_Data	(ocf::heartbeat:Filesystem):	Started node01
   ```

7. Simulate node failure on `node01` by putting it into standby mode and observe automated failover of the DRBD master role and filesystem mount to `node02`.
   ```bash
   sudo pcs node standby node01
   sudo pcs status
   ```
   *Expected Output:*
   ```text
   Node List:
     * Node node01: standby
     * Online: [ node02 ]

   Full List of Resources:
     * Resource Group:
       * Clone Set: DRBD_Data-clone [DRBD_Data] (promotable):
         * Masters: [ node02 ]
         * Stopped: [ node01 ]
       * FS_Data	(ocf::heartbeat:Filesystem):	Started node02
   ```

8. Check DRBD status on `node02` to confirm promotion to `Primary`.
   ```bash
   sudo drbdadm status ha_data
   ```
   *Expected Output:*
   ```text
   ha_data role:Primary
     disk:UpToDate
     node01 connection:Standby
   ```

---

### Verification Questions

#### Question 3.1
If a dual-node DRBD cluster operating with `protocol C` suffers a complete network partition without STONITH/fencing configured, and writes occur independently on both nodes after manual forced promotion, DRBD enters a `SplitBrain` connection state upon network restoration. What exact steps and `drbdadm` sub-commands are required to resolve this condition manually and re-establish replication synchronization?

#### Question 3.2
In a Pacemaker cluster managing a DRBD resource, what is the architectural significance of setting `fencing resource-and-stonith;` inside `/etc/drbd.d/ha_data.res`, and what exact mechanism prevents data corruption if node-to-node replication drops while I/O operations are active?

---

<details>
<summary><b>Click to expand Solutions and Detailed Technical Explanations</b></summary>

### Solution: Exercise 1 — Ceph

#### Answer 1.1
When two out of three OSDs fail for a PG in a pool with `size = 3` and `min_size = 2`, the remaining active OSD counts only 1 surviving replica. Because the number of available healthy replicas (1) is **below** the strict requirement enforced by `min_size` (2), Ceph immediately **blocks all client write I/O operations** for that PG.
* **Mechanism:** The PG transitions to an `active+undersized+degraded` or `active+degraded` state, but refuses to commit new write transactions to disk.
* **Architectural Rationale:** This design guarantees strict strong consistency (CP in CAP theorem) over availability. Accepting writes with fewer than `min_size` replicas would risk permanent data loss if the single surviving OSD suffered an unrecoverable hardware failure before recovery completed. Client read requests for existing committed data may still complete, depending on cluster configurations, but writes stall until peer OSDs recover or `min_size` is manually overridden.

#### Answer 1.2
* **RocksDB Role:** In Ceph BlueStore, `RocksDB` stores all OSD metadata. This includes key-value structures such as object names, PG metadata, OSD maps, write-ahead logs (WAL), and allocation maps for raw disk blocks.
* **Fallback Storage:** If no dedicated fast block device (such as a separate NVMe partition) is specified for `block.db`, RocksDB stores its data directly on the main BlueStore primary block device (`block`) inside an embedded lightweight filesystem called **BlueFS**.
* **Diagnostic Inspection:** The `ceph-bluestore-tool` CLI utility provides deep insights into internal device allocation, BlueFS filesystem metrics, and RocksDB metadata stats. Example syntax:
  ```bash
  sudo ceph-bluestore-tool bluefs-bdev-sizes --path /var/lib/ceph/osd/ceph-1
  ```

---

### Solution: Exercise 2 — GlusterFS

#### Answer 2.1
* **AFR Extended Attributes:** GlusterFS AFR translator uses native filesystem Extended Attributes (`xattrs`) namespaced under `trusted.afr.<volume_name>-client-<index>`.
* **Structure:** Each brick maintains an attribute array containing 3 distinct 4-byte big-endian integer counters (totaling 12 bytes / 24 hex characters):
  1. Bytes 0–3: Data modification counter.
  2. Bytes 4–7: Metadata (permissions, ownership) counter.
  3. Bytes 8–11: Extended attribute modification counter.
* **Split-Brain Identification:**
  * **Normal Healing:** Brick A displays `000000010000000000000000` (indicating 1 pending data update for Brick B), while Brick B displays `000000000000000000000000`. AFR knows Brick A contains the updated file and automatically syncs data to Brick B.
  * **Split-Brain:** Brick A displays `000000050000000000000000` (Brick A modified while B was offline) AND Brick B displays `000000020000000000000000` (Brick B modified while A was offline). Because both bricks reflect non-zero counters accusing the other peer of missing data changes, AFR cannot determine which file copy is authoritative, locks the file, and flags a **Split-Brain error**.

#### Answer 2.2
* **Write Availability & Quorum:** In a `replica 3` setup, quorum requires a simple majority (2 out of 3 bricks) to commit writes. If 2 bricks fail, writes halt entirely.
* **Arbiter Brick Mechanism:** An `arbiter 1` configuration replaces one of the full data bricks with a lightweight metadata-only brick (storing only file names, structure, and `xattrs`, without actual payload content).
* **Benefits:**
  1. **Storage Optimization:** Reduces total raw storage footprint from $3 \times \text{Data Size}$ down to $2 \times \text{Data Size} + \text{Metadata}$, saving nearly 33% total capacity while retaining 3-way split-brain protection.
  2. **Split-Brain Mitigation:** If network partitioning splits the two main data bricks, the arbiter acts as the tie-breaker node, allowing the side connected to the arbiter to maintain active write quorum while preventing split-brain writes on the isolated brick.

---

### Solution: Exercise 3 — DRBD9

#### Answer 3.1
To resolve a DRBD `SplitBrain` condition manually, one node must be designated as the data victim (its modifications discarded) and the other node as the authoritative source (its data preserved).

**Step 1: On the Victim Node (e.g., `node02`):**
```bash
# Demote resource to secondary if active
sudo drbdadm secondary ha_data

# Discard modifications and set connection state to StandAlone
sudo drbdadm disconnect ha_data
sudo drbdadm secondary ha_data
sudo drbdadm connect --discard-my-data ha_data
```

**Step 2: On the Authoritative Node (e.g., `node01`):**
```bash
# Force connection sync initiation
sudo drbdadm disconnect ha_data
sudo drbdadm connect ha_data
```
Upon connection, `node01` overwrites conflicting blocks on `node02`, returning both devices to an `UpToDate` state and clearing the split-brain condition.

#### Answer 3.2
* **Architectural Significance:** `fencing resource-and-stonith;` instructs the DRBD kernel driver to halt disk write operations (placing the local block device in an I/O freeze state) whenever communication with the peer node is abruptly severed.
* **Interactions with Pacemaker:**
  1. DRBD halts local storage I/O and invokes the designated handler script (`crm-fence-peer.9.sh`).
  2. The handler script communicates with Pacemaker to request immediate fencing (power off or reset via IPMI/PDU STONITH) of the unreachable peer.
  3. This hard lock guarantees that the secondary node cannot attempt local disk writes or mount the filesystem concurrently. Data integrity is preserved at the block layer before Pacemaker promotes a new primary node.

</details>