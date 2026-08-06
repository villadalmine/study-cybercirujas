# LPIC-3 Exam 306-300 (v3.0) — High Availability Cluster Storage (Topic 306.2)
**Target Certification:** LPIC-3 Specialty: High Availability and Storage Clusters  
**Exam Weight:** 25  
**Audience Level:** Senior SRE / Principal Platform Architect  

---

## 1. Production Motivation & Architectural Problem Statement

### 1.1 The High-Availability Storage Dilemma
In distributed systems architecture, stateful workloads (such as relational databases, transactional message queues, and POSIX-compliant shared file repositories) introduce a fundamental challenge: maintaining storage consistency across multiple compute nodes without introducing a Single Point of Failure (SPOF) or sacrificing I/O performance.

Stateful High-Availability (HA) clusters typically leverage one of two core storage paradigms:
1. **Shared-Storage Topology (SAN/Fibre Channel/iSCSI):** Multiple compute nodes connect directly to a shared block LUN.
2. **Shared-Nothing Replicated-Block Topology (DRBD):** Host nodes maintain localized block devices, replicating raw disk blocks across dedicated network links.

```
       [Shared Storage Paradigm]                        [Shared-Nothing Paradigm]
       +-------+        +-------+                     +-------+        +-------+
       | NodeA |        | NodeB |                     | NodeA |        | NodeB |
       +---+---+        +---+---+                     +---+---+        +---+---+
           |                |                             |                |
           +-------+--------+                             |  DRBD Protocol |
                   |                                      +================+
            +------v------+                               | (Block Rep.)   |
            | SAN / iSCSI |                           +---v---+        +---v---+
            |  Shared LUN |                           | /dev  |        | /dev  |
            +-------------+                           | /sdb1 |        | /sdb1 |
                                                      +-------+        +-------+
```

### 1.2 Concurrency Hazards & Split-Brain Risks
Standard local filesystems (e.g., `ext4`, `xfs`) assume exclusive control over block allocation metadata (superblocks, inodes, free-block bitmaps). If two nodes concurrently mount a non-clustered filesystem over shared block storage:
* **Inodes Corruption:** Page caches become desynchronized; Node A writes block modifications that overwrite allocation metadata modified by Node B.
* **Kernel Panics:** Buffer cache incoherence triggers critical kernel assertions (`FS-Error` or silent filesystem remounts to read-only).

To prevent data corruption, high-availability cluster storage requires specialized synchronization mechanisms:
* **Shared-Nothing Block Replication (DRBD):** Requires strict single-primary state or dual-primary mode coupled with a cluster-aware file system.
* **Shared-Disk Clustered Filesystems (GFS2, OCFS2):** Utilize a **Distributed Lock Manager (DLM)** or cluster membership layer to arbitrate file-locking primitives across nodes.
* **Fencing & STONITH (Shoot The Other Node In The Head):** Unresponsive or split-brained nodes MUST be forcibly isolated at the hardware level (via IPMI/iLO/PDU) before block access is transferred to healthy nodes.

---

## 2. Technical Comparisons & Trade-off Matrix

### 2.1 Block-Level Replication vs. Clustered File Systems

| Architectural Metric | DRBD 9 (Protocol C) | GFS2 + DLM | OCFS2 + o2cb/DLM | iSCSI + Multipath + `lvmlockd` |
| :--- | :--- | :--- | :--- | :--- |
| **Storage Architecture** | Shared-Nothing Block Replication | Shared-Disk SAN / LUN | Shared-Disk SAN / LUN | Shared-Disk SAN / LUN |
| **Primary Operating Mode** | Single-Primary (Dual-Primary for Live Migration) | Multi-Primary (Active-Active) | Multi-Primary (Active-Active) | Active-Passive or Active-Active Volume Groups |
| **Replication / Lock Type** | Synchronous Block Replication over TCP/IP or RDMA | Distributed Lock Manager (DLM) over Corosync | `o2cb` or DLM | SAN Fabric HW Replication + Lock Manager |
| **POSIX Compliance** | Native (via local filesystem on top of `/dev/drbdX`) | Full POSIX Clustered FS | Full POSIX Clustered FS | Native via mounted LVs |
| **Max Scale (Recommended Nodes)** | 2 to 32 nodes (DRBD 9) | 2 to 16 nodes | 2 to 16 nodes | Fabric Limited (up to 64 nodes) |
| **Latency Overhead** | Round-Trip Network Latency (RTT) per block write | DLM Lock Acquisition RTT per file metadata modification | DLM/o2cb Lock RTT | SAN Fabric latency + MPath path checking overhead |
| **Split-Brain Mitigation** | Automatic Fencing Handlers + Quorum Control | Pacemaker STONITH compulsory | Pacemaker STONITH or `o2cb` Heartbeat Fencing | SAN Fencing / SCSI-3 Persistent Reservations |
| **Optimal Production Use Case** | HA Databases (PostgreSQL, MySQL, Redis), Active/Passive Failover | Shared Web Upload Directories, HPC Concurrent Writes | Oracle RAC, Shared VM Storage | Shared LVM storage infrastructure across SAN clusters |

### 2.2 DRBD Transport Protocol Matrix

```
Application Write -> Node A Buffer Cache -> DRBD Driver
                                               |
         +-------------------------------------+-------------------------------------+
         |                                     |                                     |
    [Protocol A]                          [Protocol B]                          [Protocol C]
 (Asynchronous)                      (Semi-Synchronous)                      (Synchronous)
         |                                     |                                     |
Sent to local TCP buffer            Sent to remote TCP buffer             Written to remote disk
RPO > 0 (Potential Loss)            RPO ~ 0 (Minimal Loss)                RPO = 0 (Zero Loss)
Best for WAN DR                     Best for Campus/LAN                   Required for HA Clusters
```

---

## 3. Production Manifests & Configuration Infrastructure

### 3.1 DRBD 9 Complete Production Configuration (`/etc/drbd.d/r0.res`)

```
# Production DRBD 9 Resource Definition for HA Database Cluster
resource r0 {
    version 9;

    net {
        protocol C;
        max-buffers 20480;
        max-epoch-size 20480;
        sndbuf-size 1048576;
        rcvbuf-size 2048576;
        csums-alg sha256;
        verify-alg sha256;
        allow-two-primaries no;
        cram-hmac-alg sha256;
        shared-secret "SuperComplexProductionSecretKey2026!";
        on-congestion policy-engine;
    }

    handlers {
        split-brain "/usr/lib/drbd/notify-split-brain.sh root@example.com";
        fence-peer "/usr/lib/drbd/crm-fence-peer.9.sh";
        unfence-peer "/usr/lib/drbd/crm-unfence-peer-9.sh";
        before-resync-target "/usr/lib/drbd/snapshot-resync-target-backup.sh";
        pri-lost-after-sb "/usr/lib/drbd/notify-pri-lost-after-sb.sh root@example.com";
    }

    disk {
        resync-rate 110M;
        c-plan-ahead 20;
        c-fill-target 20M;
        c-max-rate 250M;
        c-min-rate 10M;
        disk-flushes yes;
        md-flushes yes;
        on-io-error detach;
        fencing resource-and-stonith;
    }

    on san-node01.example.com {
        node-id 0;
        device /dev/drbd0 minor 0;
        disk /dev/mapper/vg_storage-lv_data;
        meta-disk internal;
        address 192.168.100.11:7788;
    }

    on san-node02.example.com {
        node-id 1;
        device /dev/drbd0 minor 0;
        disk /dev/mapper/vg_storage-lv_data;
        meta-disk internal;
        address 192.168.100.12:7788;
    }
}
```

---

### 3.2 Enterprise Device-Mapper Multipath Configuration (`/etc/multipath.conf`)

```
# Device-Mapper Multipath Production Configuration for Enterprise SAN LUNs
defaults {
    user_friendly_names yes
    find_multipaths yes
    polling_interval 5
    path_selector "service-time 0"
    path_grouping_policy group_by_prio
    supported_path_checkers "tur directio alua"
    prio "alua"
    path_checker alua
    failback immediate
    rr_weight uniform
    no_path_retry 18
    rr_min_io 1000
    flush_on_last_del yes
    dev_loss_tmo 30
    fast_io_fail_tmo 5
    features "1 queue_if_no_path"
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^sda$"
    wwid ".*"
}

blacklist_exceptions {
    wwid "360014050a12b9845d0442c8d506eef1d"
}

multipaths {
    multipath {
        wwid "360014050a12b9845d0442c8d506eef1d"
        alias mpath_shared_gfs2
        path_grouping_policy group_by_prio
        prio alua
        path_checker alua
        failback immediate
    }
}

devices {
    device {
        vendor "PURESTORAGE"
        product "FlashArray"
        path_grouping_policy group_by_prio
        path_checker tur
        fast_io_fail_tmo 10
        dev_loss_tmo 60
        no_path_retry 12
    }
}
```

---

### 3.3 Complete Pacemaker Cluster Manifest (`drbd_gfs2_stack.xml` / `pcs` Deployment Commands)

To deploy DRBD, DLM, and GFS2 under Pacemaker control, execute the following configuration sequence:

```bash
# 1. Configure Cluster Property & STONITH Fencing
pcs property set stonith-enabled=true
pcs property set no-quorum-policy=freeze

# 2. Configure IPMI Hardware Fencing Devices
pcs stonith create stonith_node1 fence_ipmilan \
    pcmk_host_list="san-node01.example.com" \
    ipaddr="192.168.1.101" login="admin" passwd="SecretIpmiPassword" action="off" \
    op monitor interval=60s timeout=20s

pcs stonith create stonith_node2 fence_ipmilan \
    pcmk_host_list="san-node02.example.com" \
    ipaddr="192.168.1.102" login="admin" passwd="SecretIpmiPassword" action="off" \
    op monitor interval=60s timeout=20s

# 3. Create DRBD Resource & Promotable Clone (Master/Slave)
pcs resource create DrbdData ocf:linbit:drbd \
    drbd_resource=r0 \
    op monitor interval=15s role="Master" timeout=30s \
    op monitor interval=30s role="Slave" timeout=30s

pcs resource promotable DrbdData \
    promoted-max=1 promoted-node-max=1 \
    clone-max=2 clone-node-max=1 \
    notify=true id=DrbdData-clone

# 4. Configure DLM (Distributed Lock Manager) Clone
pcs resource create dlm ocf:pacemaker:controld \
    op monitor interval=30s timeout=30s

pcs resource clone dlm interleave=true

# 5. Configure GFS2 Filesystem Mount Resource
pcs resource create Gfs2Fs ocf:heartbeat:Filesystem \
    device="/dev/drbd0" \
    directory="/mnt/shared_gfs2" \
    fstype="gfs2" \
    options="noatime" \
    op monitor interval=20s timeout=40s \
    op start timeout=60s \
    op stop timeout=60s

pcs resource clone Gfs2Fs interleave=true

# 6. Set Ordering & Colocation Constraints
pcs constraint order start dlm-clone then start Gfs2Fs-clone
pcs constraint order promote DrbdData-clone then start Gfs2Fs-clone
pcs constraint colocation add Gfs2Fs-clone with DrbdData-clone role=Promoted
```

---

## 4. Real CLI Commands & Expected Terminal Outputs

### 4.1 DRBD Status Verification (`drbdadm` and `drbdsetup`)

```bash
$ drbdadm status r0 --verbose
```
```text
r0 node-id:0 connection:Connected role:Primary
  volume:0 minor:0 disk:UpToDate blocked:no
  san-node02.example.com node-id:1 connection:Connected role:Secondary
    volume:0 minor:0 disk:UpToDate peer-blocked:no
```

```bash
$ drbdsetup status r0 --statistics
```
```text
r0 node-id:0 role:Primary suspended:false
  volume:0 minor:0 disk:UpToDate size:104853504 KiB read:4521092 KiB written:12894520 KiB al-writes:412 bit-map-writes:0 activity-log-resyncs:0
  san-node02.example.com node-id:1 connection:Connected role:Secondary congestion:none
    volume:0 minor:0 disk:UpToDate replication:Established ap-in-flight:0 rs-in-flight:0 resync-susp:none
```

---

### 4.2 Pacemaker Cluster State (`pcs status`)

```bash
$ pcs status
```
```text
Cluster name: ha_storage_cluster
Cluster Summary:
  * Stack: corosync
  * Current DC: san-node01.example.com (version 2.1.5-9.el9) - partition with quorum
  * Last updated: Thu Aug  6 17:14:00 2026
  * Last change:  Thu Aug  6 16:40:12 2026 by root via cibadmin on san-node01.example.com
  * 2 nodes configured
  * 6 resource instances configured

Node List:
  * Online: [ san-node01.example.com san-node02.example.com ]

Full List of Resources:
  * stonith_node1	(stonith:fence_ipmilan):	Started san-node02.example.com
  * stonith_node2	(stonith:fence_ipmilan):	Started san-node01.example.com
  * Clone Set: DrbdData-clone [DrbdData] (promotable):
    * Promoted: [ san-node01.example.com ]
    * Unpromoted: [ san-node02.example.com ]
  * Clone Set: dlm-clone [dlm]:
    * Started: [ san-node01.example.com san-node02.example.com ]
  * Clone Set: Gfs2Fs-clone [Gfs2Fs]:
    * Started: [ san-node01.example.com san-node02.example.com ]

Daemon Status:
  corosync: active/enabled
  pacemaker: active/enabled
  pcsd: active/enabled
```

---

### 4.3 Enterprise SAN Multipath Topology (`multipath -ll`)

```bash
$ multipath -ll mpath_shared_gfs2
```
```text
mpath_shared_gfs2 (360014050a12b9845d0442c8d506eef1d) dm-2 PURE,FlashArray
size=500G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
|-+- policy='service-time 0' prio=50 status=active
| |- 3:0:0:1 sdb 8:16 active ready running
| `- 4:0:0:1 sdc 8:32 active ready running
`-+- policy='service-time 0' prio=10 status=enabled
  |- 3:0:1:1 sdd 8:48 active ready running
  `- 4:0:1:1 sde 8:64 active ready running
```

---

### 4.4 DLM Lock Manager Status (`dlm_tool`)

```bash
$ dlm_tool status
```
```text
dlm status
daemon version 4.1.1
lockspaces 1
total nodes 2
clean nodes 2
dirty nodes 0
```

```bash
$ dlm_tool ls
```
```text
dlm lockspaces
name          gfs2_shared
id            0x5f8a2b1c
flags         0x00000000
change        member count 2 total run 1
members       1 2 
```

---

### 4.5 GFS2 Filesystem Journal & Tuning Inspection (`gfs2_jadd` / `tunefs.gfs2`)

```bash
$ tunefs.gfs2 -l /dev/drbd0
```
```text
Filesystem volume name: ha_storage_cluster:gfs2_shared
Filesystem UUID:        7d4a1b02-89ef-4c12-91ef-c56a88bdf201
Filesystem format #:    1801
Journal count:          2
Block size:             4096
Journal 0 size:         128 MB
Journal 1 size:         128 MB
```

```bash
$ gfs2_jadd -j 2 /mnt/shared_gfs2
```
```text
Filesystem: /mnt/shared_gfs2
Old Journals: 2
New Journals: 4
Journal 2 size: 128MB
Journal 3 size: 128MB
Done.
```

---

## 5. Verification & Diagnostic Guide for Production Failures

### 5.1 Scenario A: DRBD Split-Brain Detection and Manual Recovery

#### 1. Failure Manifestation
The network link between Node A and Node B breaks while both nodes receive write operations. Both nodes transition to `StandAlone` mode with disconnected disks.

```bash
$ drbdadm status r0
```
```text
r0 node-id:0 connection:StandAlone role:Primary
  volume:0 minor:0 disk:UpToDate
```

Kernel log (`dmesg | grep -i drbd`):
```text
[ 4120.512411] drbd r0: Split-Brain detected, dropping connection!
[ 4120.512490] drbd r0: Helper process /usr/lib/drbd/notify-split-brain.sh returned 0
[ 4120.512520] drbd r0: State change failed: Need access to UpToDate data
[ 4120.512550] drbd r0: conn( Unconnected -> StandAlone )
```

---

#### 2. Root Cause Resolution Procedure (Manual Recovery Workflow)

Step 1: Identify Victim Node (the node whose modifications will be overwritten) and Survivor Node (the canonical data source).

Step 2: On the **Victim Node** (`san-node02.example.com`):
```bash
# Demote to Secondary
$ drbdadm secondary r0

# Force rejection of local modifications
$ drbdadm connect --discard-my-data r0
```

Step 3: On the **Survivor Node** (`san-node01.example.com`):
```bash
# Re-establish connection as resync source
$ drbdadm connect r0
```

Step 4: Verify Resync Completion:
```bash
$ drbdadm status r0
```
```text
r0 node-id:0 connection:SyncSource role:Primary
  volume:0 minor:0 disk:UpToDate
  san-node02.example.com node-id:1 connection:SyncTarget role:Secondary
    volume:0 minor:0 disk:Inconsistent replication:SyncSource peer-disk:Inconsistent done:34.12%
```

---

### 5.2 Scenario B: DLM Lock Hang / Node Fencing Debugging in GFS2

#### 1. Symptom
I/O operations on `/mnt/shared_gfs2` freeze; `df -h` blocks indefinitely on GFS2 mounts.

#### 2. Diagnostic Execution Steps

Step 1: Inspect kernel lockspace structures via `debugfs`:
```bash
$ cat /sys/kernel/debug/dlm/gfs2_shared_locks | grep -E "Granted|Waiting"
```
```text
Resource 0000000000000005: Lock master: nodeid 2
  Grant queue:
    Node: 1, Mode: PR, Status: GRANTED
  Wait queue:
    Node: 1, Mode: EX, Status: WAITING (held by Node 2 unresponsive)
```

Step 2: Check Corosync cluster membership and quorum state:
```bash
$ corosync-cmapctl | grep runtime.totem.pg.mrp.srp.members
```
```text
runtime.totem.pg.mrp.srp.members.1.config_version (u64) = 0
runtime.totem.pg.mrp.srp.members.1.ip (str) = r(0) ip(192.168.100.11) 
runtime.totem.pg.mrp.srp.members.1.status (str) = joined
runtime.totem.pg.mrp.srp.members.2.status (str) = left
```

Step 3: If Pacemaker STONITH fails to auto-fence the dead node, execute manual emergency STONITH to release DLM locks:
```bash
$ pcs stonith fence san-node02.example.com
```
```text
Node san-node02.example.com successfully fenced
```

---

### 5.3 Scenario C: SAN Path Failure & Multipath Reinstatement

#### 1. Diagnostic Tracing

Check path state drops in `/var/log/messages`:
```text
Aug 6 17:02:11 san-node01 kernel: multipathd: mpath_shared_gfs2: sdb - path failed
Aug 6 17:02:11 san-node01 kernel: multipathd: mpath_shared_gfs2: Remaining active paths: 3
Aug 6 17:02:15 san-node01 kernel: multipathd: mpath_shared_gfs2: sdc - path failed
Aug 6 17:02:15 san-node01 kernel: multipathd: mpath_shared_gfs2: Switching to path group 2
```

Force multipath path re-check and daemon reconfigure:
```bash
$ multipathd reconfigure
$ multipathd show paths format "%n %d %t %T %s"
```
```text
dev dev_t failback process status
sdb 8:16  immediate active  failed
sdc 8:32  immediate active  failed
sdd 8:48  immediate active  active
sde 8:64  immediate active  active
```

Reinstate failed HBA paths after hardware repair:
```bash
$ echo 1 > /sys/block/sdb/device/rescan
$ echo 1 > /sys/block/sdc/device/rescan
$ multipathd resize map mpath_shared_gfs2
```

---

## 6. References

* **Linux Professional Institute (LPI) Exam 306-300 Objectives:**  
  [https://www.lpi.org/our-certifications/lpic-3-306-overview/](https://www.lpi.org/our-certifications/lpic-3-306-overview/)
* **LINBIT DRBD 9 User Guide & Technical Documentation:**  
  [https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/)
* **Red Hat Enterprise Linux 9 High Availability Cluster Products Guide:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/index)
* **Global File System 2 (GFS2) Architecture & Reference - Red Hat Documentation:**  
  [https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/index](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/global_file_system_2/index)
* **Linux Device-Mapper Multipathing Source & Administration Manual:**  
  [https://christophe.varoqui.free.fr/](https://christophe.varoqui.free.fr/)
* **Cluster Control Daemon (`controld`) & DLM Kernel Locking Manual:**  
  [https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/filesystems/dlmfs.rst](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/filesystems/dlmfs.rst)