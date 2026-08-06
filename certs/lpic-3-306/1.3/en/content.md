# LPIC-3 Exam 306-300 (Version 3.0) — Topic 1.3: High Availability Distributed Storage

---

## 1. Production Architectural Motivation & Problem Statement

### 1.1 The Cloud-Native Statefulness Dilemma
In modern cloud-native infrastructures and enterprise stateful clusters, compute nodes are inherently transient, but data persistence must remain immutable, available, and durable. Traditional SAN (Storage Area Network) and NAS (Network Attached Storage) solutions introduce severe operational bottlenecks in large-scale deployments:
* **Single Points of Failure (SPOF):** Shared storage backplanes rely on dual controllers that suffer from split-brain scenarios or hardware-bound scaling limits.
* **CapEx and Vendor Lock-in:** Proprietary SAN fabrics (e.g., Fibre Channel) require custom hardware HBAs and expensive license tiers.
* **Horizontal Scaling Constraints:** Traditional SAN architectures scale vertically (scale-up). Increasing capacity requires larger storage arrays rather than appending commodity hardware nodes (scale-out).

Distributed storage systems overcome these limits by aggregating local drives (NVMe, SSD, HDD) across commodity server nodes into a unified, resilient, software-defined storage pool.

```
       +-----------------------------------------------------------------------+
       |                         Client / Compute Layer                        |
       |             [ Kubernetes Pods / Hypervisors / Bare-Metal ]           |
       +-----------------------------------------------------------------------+
            | (RBD / NVMe-oF)               | (CephFS / NFS)       | (RGW S3)
            v                               v                      v
  +--------------------+         +--------------------+  +-------------------+
  |  Block Storage     |         | Shared File System |  |   Object Storage  |
  +--------------------+         +--------------------+  +-------------------+
  | - Persistent Disks |         | - Multi-writer     |  | - RESTful S3/Swift|
  | - Low Latency RWX  |         | - POSIX Compliance |  | - Unstructured    |
  +--------------------+         +--------------------+  +-------------------+
                                    |
  ==================================v===========================================
                      SOFTWARE-DEFINED STORAGE FABRIC
  ==============================================================================
  +----------------------------------------------------------------------------+
  | Ceph RADOS (CRUSH Engine) / GlusterFS Glusterd (Translator Stack)          |
  +----------------------------------------------------------------------------+
       |                             |                             |
       v                             v                             v
+--------------+             +--------------+             +--------------+
| Node 1 (OSD) |             | Node 2 (OSD) |             | Node 3 (OSD) |
| [NVMe] [SSD] |<----------->| [NVMe] [SSD] |<----------->| [NVMe] [SSD] |
+--------------+   Network   +--------------+   Network   +--------------+
                   Replication                  Replication
```

### 1.2 The CAP Theorem in Storage Architecture
Every distributed storage engine is constrained by the **CAP Theorem** (Consistency, Availability, Partition Tolerance):

* **Consistency (C):** Every read receives the most recent write or an error.
* **Availability (A):** Every non-failing node returns a non-error response without guaranteeing it contains the most recent write.
* **Partition Tolerance (P):** The system continues to operate despite an arbitrary number of messages being dropped or delayed by the network between nodes.

Because network partitions ($P$) are inevitable in physical infrastructure, distributed storage engines must choose between **CP** (Consistency + Partition Tolerance) or **AP** (Availability + Partition Tolerance).

#### Storage Engine Trade-Off Classification
1. **Ceph (CP System):** Prefers strong consistency over availability during split-brain events. If a Paxos quorum of Monitors (`ceph-mon`) is lost, writes are blocked to protect data integrity.
2. **GlusterFS (Tunable CP/AP):** Operates primarily as an AP system by default (allowing reads/writes during network partitions), but can be tuned toward CP using quorum enforce mechanisms (`cluster.quorum-type auto`, `cluster.quorum-action freeze-writes`) and arbiter bricks to prevent split-brain.

### 1.3 Split-Brain Mechanics & Quorum Consensus
Split-brain occurs when a network partition divides a storage cluster into isolated sub-clusters. If both sub-clusters continue accepting write operations independently to the same storage blocks, data divergence and corruption occur.

#### Consensus Protocols
* **Paxos Engine (Ceph Monitors):** Requires an odd number of Monitor instances ($N \ge 3$). Quorum threshold is defined as:
  $$\text{Quorum} = \left\lfloor \frac{N}{2} \right\rfloor + 1$$
  If $N=3$, 2 MONs must agree. If 2 MONs fail, the cluster halts write I/O.
* **Quorum & Replica 3 with Arbiter (GlusterFS):** Uses 3 nodes where Node 3 acts as an **Arbiter** (stores metadata and file attributes only, without full file data payloads). This eliminates 50% of storage overhead while retaining 3-way split-brain protection.

---

## 2. Technical Architecture & Deep Comparisons

### 2.1 Ceph Architecture & Internal Mechanics

Ceph provides object, block, and file storage from a single unified storage layer called **RADOS** (Reliable Autonomic Distributed Object Store).

```
 +-------------------------------------------------------------------------+
 |                          Ceph User Clients                              |
 |   librbd (Block)   |   libcephfs (POSIX File)   |   radosgw (S3/Swift)   |
 +--------------------+----------------------------+-----------------------+
                                    |
                                    v
 +-------------------------------------------------------------------------+
 |                   RADOS Layer (Object Storage Fabric)                   |
 |                                                                         |
 |  +--------------------+  +--------------------+  +-------------------+  |
 |  |   Ceph Monitors    |  |    Ceph Managers   |  | Metadata Servers  |  |
 |  |  (MON - Quorum)    |  |  (MGR - Metrics)   |  |   (MDS - CephFS)  |  |
 |  +--------------------+  +--------------------+  +-------------------+  |
 |                                                                         |
 |  +-------------------------------------------------------------------+  |
 |  |                  Object Storage Daemons (OSDs)                    |  |
 |  |   OSD.0 (BlueStore)  |  OSD.1 (BlueStore)  |  OSD.2 (BlueStore)    |  |
 |  +-------------------------------------------------------------------+  |
 +-------------------------------------------------------------------------+
```

#### Core Components
1. **Ceph OSD (Object Storage Daemon):** Handles storage drives (HDD/SSD/NVMe), data replication, rebalancing, recovery, and scrubbing. Uses the **BlueStore** engine to write directly to raw block devices without filesystem overhead.
2. **Ceph MON (Monitor):** Maintains cluster maps (MonMap, OSDMap, PGMap, CRUSH map). Executes Paxos consensus.
3. **Ceph MGR (Manager):** Collects cluster metrics (Prometheus exporter), manages operational modules, and handles PG allocation.
4. **Ceph MDS (Metadata Server):** Manages POSIX metadata for CephFS (allows OSDs to serve direct file reads without central bottlenecks).
5. **CRUSH Algorithm (Controlled Replication Under Scalable Hashing):** Eliminates central lookup tables. When a client writes object `obj1` to pool `pool1`:
   $$\text{Placement Group (PG)} = \text{hash}(obj1) \pmod{\text{pg\_num}}$$
   $$\text{OSD List} = \text{CRUSH}(\text{PG}, \text{CRUSH\_Map}, \text{Rule})$$

#### BlueStore Storage Engine Layout
BlueStore replaces the legacy FileStore (which used ext4/XFS with POSIX overhead).

```
+---------------------------------------------------------------------------+
|                            Ceph BlueStore OSD                             |
+---------------------------------------------------------------------------+
|  +--------------------+  +---------------------------------------------+  |
|  |     RocksDB        |  |                 BlueFS                      |  |
|  | (Metadata / WAL)   |  | (Small Allocator for RocksDB SST files)     |  |
|  +--------------------+  +---------------------------------------------+  |
|  +---------------------------------------------------------------------+  |
|  |                       BlueStore Allocator                           |  |
|  |           (Direct I/O to Raw Block Device / NVMe / Disk)            |  |
|  +---------------------------------------------------------------------+  |
+---------------------------------------------------------------------------+
```

### 2.2 GlusterFS Architecture & Translator Stack

GlusterFS is a user-space, software-defined distributed file system built on a modular **Translator Stack** (`xlators`).

```
+---------------------------------------------------------------------------+
|                          GlusterFS Client Mount                           |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                          FUSE Kernel Module                               |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                             Translator Stack                              |
|  +---------------------------------------------------------------------+  |
|  | Performance Translators (read-ahead, write-behind, io-cache)        |  |
|  +---------------------------------------------------------------------+  |
|  | Cluster Translators (AFR - Automatic File Replication / DHT)      |  |
|  +---------------------------------------------------------------------+  |
|  | Protocol Translators (rpc-clnt -> network -> rpc-server)           |  |
|  +---------------------------------------------------------------------+  |
+---------------------------------------------------------------------------+
                                     |
                                     v
+---------------------------------------------------------------------------+
|                             GlusterFS Bricks                              |
|  Node 1: /data/brick1/b1   Node 2: /data/brick2/b1   Node 3: /data/b3/b1  |
|        (XFS File System)         (XFS File System)       (XFS File System)|
+---------------------------------------------------------------------------+
```

* **Bricks:** A basic storage unit represented as a directory mounted on an underlying file system (typically XFS with extended attributes `user.glusterfs.*`).
* **Trusted Storage Pool (TSP):** A network collection of storage nodes running `glusterd`.
* **Self-Heal Daemon (`glustershd`):** Runs background processes to reconcile out-of-sync bricks during reconnects.

---

### 2.3 Comprehensive Technical Trade-Off Tables

#### Table 1: High Availability Distributed Storage Architecture Comparison

| Feature / Metric | Ceph (RADOS) | GlusterFS | DRBD (Distributed Replicated Block Device) |
| :--- | :--- | :--- | :--- |
| **Storage Abstractions** | Unified (Block: RBD, Object: RGW, File: CephFS) | File (POSIX Mount) & Block via `gluster-block` | Network Block Device (`/dev/drbd*`) |
| **Data Placement Engine** | Algorithmic (CRUSH Hashing Engine) | Elastic Hash / DHT (Distributed Hash Table) | Static Block Replication (Primary/Secondary) |
| **Underlying Substrate** | Raw Block Device (BlueStore DB/WAL + Data) | POSIX File System (XFS recommended) | Raw Partition, LVM Logical Volume, or Disk |
| **Consensus Protocol** | Paxos via Ceph Monitor Quorum | Quorum settings (`auto`/`server`) + Arbiter | TCP Kernel-level State Engine |
| **Replication Modes** | Synchronous inside PG, Async Async-Mirroring | Synchronous AFR (Automatic File Replication) | Protocol A (Async), B (Semi-Sync), C (Sync) |
| **Max Scale Limits** | 10,000+ Nodes / Exabytes | ~100-200 Nodes / Petabytes | Typically 2 Nodes (Up to 32 nodes in DRBD 9) |
| **Small File I/O Latency** | Moderate (Metadata overhead via BlueStore/MDS) | Low to High (FUSE layer context switches) | Ultra-Low (Near-native kernel block layer) |
| **Self-Healing Mechanics** | Automatic via Peering & PG Scrubbing | Background via `glustershd` & client-side heal | Re-synchronization via bitmap delta tracking |

---

#### Table 2: Ceph BlueStore vs Legacy FileStore & Replication Strategies

| Metric / Parameter | BlueStore (Modern Default) | FileStore (Legacy) | Replicated Pools | Erasure Coded (EC) Pools |
| :--- | :--- | :--- | :--- | :--- |
| **Metadata Engine** | Embedded RocksDB on BlueFS | File system directory structures | N/A | N/A |
| **Double Write Problem** | Eliminated (writes straight to disk) | Present (Journal write + File system write) | N/A | N/A |
| **Storage Efficiency** | ~100% device utilisation | Hardware file system overhead (~5-10%) | $\frac{1}{N}$ (e.g., $33\%$ for 3x replica) | $\frac{K}{K+M}$ (e.g., $66\%$ for $K=4, M=2$) |
| **Fault Tolerance** | Configurable via Pool Rules | Configurable via Pool Rules | Sustains $N-1$ failures | Sustains $M$ node/disk failures |
| **Workload Suitability** | High IOPS, DBs, VMs, Cloud Native | Obsolete / Legacy deployments | Low Latency Block (RBD) & Database IOPS | Cold Storage, Backup Targets, Object (RGW) |

---

#### Table 3: GlusterFS Volume Configurations Comparison

| Volume Type | Brick Layout Formula | Fault Tolerance | Capacity Efficiency | Read/Write Performance |
| :--- | :--- | :--- | :--- | :--- |
| **Distributed** | $N$ Bricks | 0 Brick Failures | 100% | High Read/Write throughput (No replica overhead) |
| **Replicated (Replica 3)** | $3 \times N$ Bricks | 2 Bricks per replica set | $33.3\%$ | High Read (Parallel), Moderate Write (Sync lock) |
| **Replica 3 Arbiter 1** | 2 Data + 1 Arbiter Brick | 1 Data Brick Failure | $50.0\%$ | High Read, Optimized Write (Metadata-only on Arbiter) |
| **Dispersed (Erasure Coded)** | Redundancy $M$, Data $K$ ($K+M$) | $M$ Bricks | $\frac{K}{K+M}$ | High Sequential Read/Write, Poor Random Write IOPS |

---

## 3. Production-Ready Configuration Files & Syntactically Complete Manifests

### 3.1 Production Ceph Cluster Configuration (`/etc/ceph/ceph.conf`)

This configuration is optimized for a production cluster with dedicated networks, BlueStore tuning, and automated scrubbing schedules.

```ini
[global]
fsid = a7f5892c-63e8-4982-a0e2-89241bda207e
mon_initial_members = ceph-mon01, ceph-mon02, ceph-mon03
mon_host = 192.168.10.11, 192.168.10.12, 192.168.10.13

# Network Separation: Public (Client I/O) vs Cluster (Replication I/O)
public_network = 192.168.10.0/24
cluster_network = 10.10.10.0/24

# Authentication and Security Protocols
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx

# Storage Architecture Limits
osd_pool_default_size = 3
osd_pool_default_min_size = 2
osd_pool_default_pg_autoscale_mode = on

[mon]
mon_clock_drift_allowed = 0.05
mon_osd_down_out_interval = 600
mon_pg_warn_max_per_osd = 300

[osd]
osd_journal_size = 10240
osd_mkfs_type = xfs
osd_max_backfills = 1
osd_recovery_max_active = 2
osd_recovery_op_priority = 2

# BlueStore Memory & Allocation Settings
bluestore_block_db_size = 67108864000
bluestore_block_wal_size = 10737418240
bluestore_cache_size_ssd = 3221225472

# Scrubbing Schedule (Off-peak maintenance window: 01:00 AM - 05:00 AM)
osd_scrub_begin_hour = 1
osd_scrub_end_hour = 5
osd_scrub_load_threshold = 2.5
osd_deep_scrub_interval = 604800

[client]
rbd_cache = true
rbd_cache_size = 67108864
rbd_cache_max_dirty = 50331648
rbd_cache_target_dirty = 33554432
rbd_cache_writethrough_until_flush = true
```

---

### 3.2 Ceph Decompiled CRUSH Map Source Code

This text CRUSH map defines a failure domain hierarchy (`root` $\rightarrow$ `datacenter` $\rightarrow$ `rack` $\rightarrow$ `host` $\rightarrow$ `osd`).

```crush
# Begin CRUSH Map

# Tunables
tunables legacy

# Devices
device 0 osd.0 class nvme
device 1 osd.1 class nvme
device 2 osd.2 class nvme
device 3 osd.3 class nvme
device 4 osd.4 class nvme
device 5 osd.5 class nvme

# Types
type 0 osd
type 1 host
type 2 rack
type 3 datacenter
type 4 root

# Buckets (Hierarchy Definition)
host ceph-node01 {
    id -2
    id -3 class nvme
    alg straw2
    hash 0
    item osd.0 weight 1.800
    item osd.1 weight 1.800
}

host ceph-node02 {
    id -4
    id -5 class nvme
    alg straw2
    hash 0
    item osd.2 weight 1.800
    item osd.3 weight 1.800
}

host ceph-node03 {
    id -6
    id -7 class nvme
    alg straw2
    hash 0
    item osd.4 weight 1.800
    item osd.5 weight 1.800
}

rack rack01 {
    id -8
    id -9 class nvme
    alg straw2
    hash 0
    item ceph-node01 weight 3.600
    item ceph-node02 weight 3.600
}

rack rack02 {
    id -10
    id -11 class nvme
    alg straw2
    hash 0
    item ceph-node03 weight 3.600
}

datacenter dc-primary {
    id -12
    id -13 class nvme
    alg straw2
    hash 0
    item rack01 weight 7.200
    item rack02 weight 3.600
}

root default {
    id -1
    id -14 class nvme
    alg straw2
    hash 0
    item dc-primary weight 10.800
}

# CRUSH Rules
rule replicated_ruleset {
    id 0
    type replicated
    step take default
    step chooseleaf firstn 0 type host
    step emit
}

rule hdd_rack_rule {
    id 1
    type replicated
    step take default class nvme
    step choose firstn 0 type rack
    step chooseleaf firstn 1 type host
    step emit
}
# End CRUSH Map
```

---

### 3.3 GlusterFS Client Mount Configuration (`/etc/fstab`)

To ensure high availability on client mounts, specify backup volume file servers to handle node outages during mount negotiation.

```etc
# /etc/fstab: GlusterFS HA Client Mount Entry
192.168.10.21:/gv_production  /mnt/gluster_ha  glusterfs  defaults,_netdev,backup-volfile-servers=192.168.10.22:192.168.10.23,log-level=WARNING,log-file=/var/log/glusterfs/gv_production.log  0  0
```

---

### 3.4 Production Cloud-Native Storage Manifests (Rook-Ceph on Kubernetes)

The following manifests deploy a Rook-Ceph storage fabric, a custom `StorageClass`, a dynamic `PersistentVolumeClaim`, and a stateful `Deployment`.

```yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.1
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 2
    modules:
      - name: pg_autoscaler
        enabled: true
  dashboard:
    enabled: true
    ssl: true
  network:
    provider: host
  resources:
    mon:
      limits:
        cpu: "2"
        memory: "4Gi"
      requests:
        cpu: "1"
        memory: "2Gi"
    osd:
      limits:
        cpu: "4"
        memory: "8Gi"
      requests:
        cpu: "2"
        memory: "4Gi"
  storage:
    useAllNodes: false
    useAllDevices: false
    config:
      databaseSizeMB: "30720"
      walSizeMB: "10240"
    nodes:
      - name: "node-01.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
      - name: "node-02.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
      - name: "node-03.storage.internal"
        devices:
          - name: "/dev/nvme0n1"
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool-fast
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: 3
    requireSafeReplicaSize: true
  parameters:
    compression_mode: passive
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool-fast
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: production-db-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 250Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stateful-app-server
  namespace: default
  labels:
    app: stateful-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stateful-app
  template:
    metadata:
      labels:
        app: stateful-app
    spec:
      containers:
        - name: database
          image: postgres:15.3-alpine
          env:
            - name: POSTGRES_PASSWORD
              value: "ProductionSecurePassword123!"
            - name: PGDATA
              value: "/var/lib/postgresql/data/pgdata"
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: db-persistent-storage
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: db-persistent-storage
          persistentVolumeClaim:
            claimName: production-db-pvc
```

---

## 4. Real CLI Commands & Terminal Outputs ($)

### 4.1 Ceph Operational Administration

#### Inspecting Cluster Health Status
```console
$ sudo ceph status
```
```text
  cluster:
    id:     a7f5892c-63e8-4982-a0e2-89241bda207e
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum ceph-mon01,ceph-mon02,ceph-mon03 (age 4w)
    mgr: ceph-node01(active, since 2w), standbys: ceph-node02
    osd: 6 osds: 6 up, 6 in (since 5d)

  data:
    pools:   3 pools, 128 pgs
    objects: 1.24M objects, 4.8 TiB
    usage:   14.4 TiB used, 18.0 TiB / 32.4 TiB avail
    pgs:     128 active+clean

  io:
    client:  12.4 MiB/s rd, 45.2 MiB/s wr, 3.45k op/s rd, 1.21k op/s wr
```

#### Detailed OSD Tree Layout Verification
```console
$ sudo ceph osd tree
```
```text
ID  CLASS  WEIGHT    TYPE NAME               STATUS  REWEIGHT  PRI-AFF
-1         10.80000  root default
-12         7.20000      datacenter dc-primary
-8          3.60000          rack rack01
-2          1.80000              host ceph-node01
 0   nvme   0.90000                  osd.0       up   1.00000  1.00000
 1   nvme   0.90000                  osd.1       up   1.00000  1.00000
-4          1.80000              host ceph-node02
 2   nvme   0.90000                  osd.2       up   1.00000  1.00000
 3   nvme   0.90000                  osd.3       up   1.00000  1.00000
-10         3.60000          rack rack02
-6          1.80000              host ceph-node03
 4   nvme   0.90000                  osd.4       up   1.00000  1.00000
 5   nvme   0.90000                  osd.5       up   1.00000  1.00000
```

#### Provisioning a Replicated RADOS Pool and RBD Block Image
```console
$ sudo ceph osd pool create rbd_production 64 64 replicated
```
```text
pool 'rbd_production' created
```

```console
$ sudo rbd pool init rbd_production
$ sudo rbd create --size 102400 --pool rbd_production sys-disk-01.img
$ sudo rbd info rbd_production/sys-disk-01.img
```
```text
rbd image 'sys-disk-01.img':
	size 100 GiB in 25600 objects
	order 22 (4 MiB objects)
	snapshot_count: 0
	id: 4b88491d9047
	block_name_prefix: rbd_data.4b88491d9047
	format: 2
	features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
	op_features: 
	flags: 
	create_timestamp: Thu Aug  6 14:22:01 2026
	access_timestamp: Thu Aug  6 14:22:01 2026
	modify_timestamp: Thu Aug  6 14:22:01 2026
```

#### Mapping an RBD Image to a Local Linux Block Device
```console
$ sudo rbd device map rbd_production/sys-disk-01.img --name client.admin
```
```text
/dev/rbd0
```

```console
$ lsblk /dev/rbd0
```
```text
NAME BASE-DEF MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
rbd0          252:0    0  100G  0 rbd  
```

---

### 4.2 GlusterFS Cluster Administration

#### Provisioning Trusted Storage Peers
```console
$ sudo gluster peer probe 192.168.10.22
```
```text
peer probe: success.
```

```console
$ sudo gluster peer status
```
```text
Number of Peers: 2

Hostname: 192.168.10.22
Uuid: 5e617d12-1a13-432d-944f-c4f4a3d44111
State: Peer in Cluster (Connected)

Hostname: 192.168.10.23
Uuid: a11b22c3-33d4-45e5-66f7-889900aabbcc
State: Peer in Cluster (Connected)
```

#### Creating and Starting a High-Availability Distributed-Replicated Arbiter Volume
```console
$ sudo gluster volume create gv_production replica 3 arbiter 1 \
  192.168.10.21:/data/brick1/b1 \
  192.168.10.22:/data/brick1/b1 \
  192.168.10.23:/data/arbiter/b1 force
```
```text
volume create: gv_production: success: please start the volume to access data
```

```console
$ sudo gluster volume start gv_production
```
```text
volume start: gv_production: success
```

```console
$ sudo gluster volume info gv_production
```
```text
Volume Name: gv_production
Type: Distributed-Replication
Volume ID: c181e194-e349-410a-8bf8-0955376da6c8
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x (2 + 1) = 3
Transport-type: tcp
Bricks:
Brick1: 192.168.10.21:/data/brick1/b1
Brick2: 192.168.10.22:/data/brick1/b1
Brick3: 192.168.10.23:/data/arbiter/b1 (arbiter)
Options Reconfigured:
cluster.arbiter-prune: on
transport.address-family: inet
nfs.disable: on
performance.client-io-threads: off
```

---

## 5. Verification, Debugging, and Troubleshooting Guide

### 5.1 Diagnostic Decision Tree Matrix

```
                      INCOMING STORAGE DEGRADATION ALERT
                                      |
         +----------------------------+----------------------------+
         |                                                         |
         v                                                         v
   [ Ceph Cluster Alert ]                                [ GlusterFS Alert ]
         |                                                         |
         v                                                         v
Execute `ceph health detail`                            Execute `gluster volume status`
         |                                                         |
  +------+------+                                           +------+------+
  |             |                                           |             |
  v             v                                           v             v
[OSD DOWN]  [PG Inconsistent]                         [Brick Offline] [Split-Brain]
  |             |                                           |             |
  v             v                                           v             v
1. Check OSD   1. Run `ceph pg map <id>`                 1. Verify Systemd 1. Run heal info
   Systemd &      to locate primary OSD.                    `glusterd`     2. Inspect POSIX
   dmesg.      2. Trigger `ceph pg deep-scrub <id>`.        2. Check network  extended attributes
2. Check disk  3. Run `ceph osd repair <osd_id>`            connectivity   `getfattr -d -m .`
   health via     if corrupt objects exist.                 on port 24007. 3. Resolve using
   smartctl.                                                               `gluster volume heal
                                                                           <vol> split-brain`
```

---

### 5.2 Failure Scenario 1: Ceph OSD Flapping & PG Degraded / Inconsistent

#### Symptom & Initial Diagnostic Input
Monitoring alerts trigger a `HEALTH_WARN` state with degraded placement groups.

```console
$ sudo ceph health detail
```
```text
HEALTH_WARN 1 pgs degraded; 1 pgs inconsistent; 1 osds down; 1 scrub errors
[NXERROR] PG_DEGRADED: PG 2.1f is degraded (2 copies out of 3 expected)
[NXERROR] OSD_DOWN: osd.2 on host 'ceph-node02' is down
[NXERROR] OSD_SCRUB_ERRORS: 1 scrub errors, use 'ceph health detail' or 'ceph pg query'
```

#### Step-by-Step Diagnostic and Resolution Procedure

##### Step 1: Isolate the Degraded Placement Group & Identify Component Mapping
```console
$ sudo ceph pg map 2.1f
```
```text
osdmap e142 pg 2.1f (2.1f) -> up [2,0,4] acting [0,4]
```
*Analysis:* `osd.2` is missing from the `acting` OSD set.

##### Step 2: Trace Systems Logs for Disk Failure or Memory OOM Kills
```console
$ ssh ceph-node02 "journalctl -u ceph-osd@2.service -n 50 --no-pager"
```
```text
Aug 06 15:10:12 ceph-node02 ceph-osd[4102]: BlueStore::_verify_csum bad crc32c/0x1000 at offset 0x40000000
Aug 06 15:10:12 ceph-node02 ceph-osd[4102]: osd.2 142 err -5 (Input/output error) read block 0x40000000
Aug 06 15:10:13 ceph-node02 systemd[1]: ceph-osd@2.service: Main process exited, code=exited, status=1/FAILURE
```

##### Step 3: Run Hardware-Level SMART Diagnosis
```console
$ ssh ceph-node02 "sudo smartctl -H /dev/nvme1n1"
```
```text
smartctl 7.3 2022-02-28 r5338 [x86_64-linux-5.15.0-76-generic] (local build)
Copyright (C) 2002-22, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: FAILED!
Drive failure expected in less than 24 hours. SAVE ALL DATA.
```

##### Step 4: Remove Corrupted OSD Safely from CRUSH Map & Rebalance Data
```console
$ sudo ceph osd out osd.2
```
```text
marked out osd.2.
```
```console
$ sudo ceph osd down osd.2
```
```text
marked down osd.2.
```

Wait for data backfilling to reach 100% clean state across remaining nodes (`osd.0`, `osd.4`):
```console
$ sudo ceph pg query 2.1f | grep -E "state|acting"
```
```text
    "state": "active+clean",
    "acting": [0,4,5],
```

##### Step 5: Execute Inconsistency Repair Command
```console
$ sudo ceph osd repair osd.0
```
```text
instruction sent to osd.0
```
```console
$ sudo ceph health
```
```text
HEALTH_OK
```

---

### 5.3 Failure Scenario 2: GlusterFS Split-Brain Resolution

#### Symptom & Initial Diagnostic Input
Applications accessing `/mnt/gluster_ha/app_data.db` return an `Input/output error` (EIO).

```console
$ ls -l /mnt/gluster_ha/app_data.db
```
```text
ls: cannot access '/mnt/gluster_ha/app_data.db': Input/output error
```

#### Step-by-Step Diagnostic and Resolution Procedure

##### Step 1: Identify Split-Brain Files via Gluster CLI
```console
$ sudo gluster volume heal gv_production info split-brain
```
```text
Brick 192.168.10.21:/data/brick1/b1
/app_data.db
Number of entries in split-brain: 1

Brick 192.168.10.22:/data/brick1/b1
/app_data.db
Number of entries in split-brain: 1

Brick 192.168.10.23:/data/arbiter/b1
Number of entries in split-brain: 0
```

##### Step 2: Inspect POSIX Extended Attributes (`xattr`) across Bricks
Check the AFR extended attributes (`trusted.afr.<volname>-client-*`) on the storage nodes.

```console
$ ssh 192.168.10.21 "getfattr -d -m . -e hex /data/brick1/b1/app_data.db"
```
```text
# file: data/brick1/b1/app_data.db
trusted.afr.gv_production-client-0=0x000000000000000000000000
trusted.afr.gv_production-client-1=0x000000010000000000000000
trusted.gfid=0xa923f4c1e2904518b2c589001245781a
```

```console
$ ssh 192.168.10.22 "getfattr -d -m . -e hex /data/brick1/b1/app_data.db"
```
```text
# file: data/brick1/b1/app_data.db
trusted.afr.gv_production-client-0=0x000000020000000000000000
trusted.afr.gv_production-client-1=0x000000000000000000000000
trusted.gfid=0xa923f4c1e2904518b2c589001245781a
```
*Analysis:* Both Node 1 (`client-0`) and Node 2 (`client-1`) modified the file independently while isolated from each other.

##### Step 3: Resolve Split-Brain by Selecting Node 1 as the Source of Truth
Force self-heal using the source-brick resolution option.

```console
$ sudo gluster volume heal gv_production split-brain source-brick 192.168.10.21:/data/brick1/b1 /app_data.db
```
```text
Healing /app_data.db on volume gv_production succeeded.
```

##### Step 4: Verify Heal Completion and Clear Errors
```console
$ sudo gluster volume heal gv_production info split-brain
```
```text
Brick 192.168.10.21:/data/brick1/b1
Number of entries in split-brain: 0

Brick 192.168.10.22:/data/brick1/b1
Number of entries in split-brain: 0

Brick 192.168.10.23:/data/arbiter/b1
Number of entries in split-brain: 0
```

```console
$ head -n 2 /mnt/gluster_ha/app_data.db
```
```text
SQLite format 3...
```
*Result:* The file is accessible, and the split-brain state is resolved.

---

### 5.4 Diagnostic & Observability Cheat Sheet

```
+---------------------------------------------------------------------------------------------------------+
|                                    STORAGE DIAGNOSTIC CHEAT SHEET                                       |
+------------------------------------+--------------------------------------------------------------------+
| Task / Diagnostic Objective        | Execution Command Syntax                                           |
+------------------------------------+--------------------------------------------------------------------+
| Ceph Monitoring Paxos Quorum Status| ceph quorum_status --format json-pretty                            |
| Ceph PG Distribution & Autoscale   | ceph osd pool autoscale-status                                     |
| Ceph Live IOPS / Latency Metrics   | ceph osd perf                                                      |
| Ceph Deep Scrub Triggering         | ceph pg deep-scrub <pg_id>                                         |
| Ceph Extract Active MonMap Binary  | ceph-mon --extract-monmap /tmp/monmap -i <mon_name>                |
| GlusterFS Active Volume Locks      | gluster volume locks info <vol_name>                               |
| GlusterFS Active Self-Heal Status  | gluster volume heal <vol_name> statistics                          |
| GlusterFS Profile I/O Metrics      | gluster volume profile <vol_name> start                            |
|                                    | gluster volume profile <vol_name> info                             |
| GlusterFS Force Brick Re-sync      | gluster volume heal <vol_name> full                                |
+------------------------------------+--------------------------------------------------------------------+
```

---

## 6. References

* **Linux Professional Institute (LPI) LPIC-3 306 Official Exam Overview:**
  `https://www.lpi.org/our-certifications/lpic-3-306-overview/`
* **LPI Wiki — LPIC-3 Exam 306 Topic 363 (High Availability Distributed Storage):**
  `https://wiki.lpi.org/wiki/LPIC-3_306_Objectives`
* **Ceph Official Architectural & Operational Documentation:**
  `https://docs.ceph.com/en/latest/`
* **Ceph CRUSH Map Architecture and Algorithm Specifications:**
  `https://docs.ceph.com/en/latest/rados/operations/crush-map/`
* **GlusterFS Official Administration Guide & Translator Stack Reference:**
  `https://docs.gluster.org/en/latest/`
* **Rook Cloud-Native Storage Orchestrator for Kubernetes:**
  `https://rook.io/docs/rook/latest/`
* **CNCF Cloud Native Storage Landscape & Taxonomy Whitepaper:**
  `https://github.com/cncf/tag-storage/blob/main/cncf-storage-whitepaper.md`