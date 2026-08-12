# 363.2 Ceph Storage Clusters

> LPIC-3 306 · Exam 306-300 (v3.0) · Topic 363.2 · Weight 13.33
> Candidates should be able to manage and maintain a Ceph cluster. This includes the architecture and components of Ceph, the management of OSD, MON, MGR and MDS daemons, placement groups and pools, the RADOS object store, RADOS Block Devices (RBD), the Ceph Filesystem (CephFS), CRUSH maps, and the diagnosis and resolution of cluster health problems.

---

## 1. Motivation and the production architectural problem

### 1.1 The failure mode Ceph is designed to eliminate

Every storage architecture eventually confronts the same three coupled pressures: **capacity** (petabytes that outgrow any single chassis), **durability** (surviving disk, host and rack failures without data loss), and **availability** (surviving those failures without an outage or a manual failover window). Classic answers each break one of the other two:

- A **dual-controller SAN** (or DRBD pair, see 362.1) gives you strong consistency and low latency, but scaling is *vertical*: you buy a bigger head unit. The controller pair is a hard ceiling on IOPS and a blast radius — a firmware bug takes out both paths.
- **NFS / a single file server** centralizes metadata and namespace. It is simple, but the metadata server is a single point of failure and a single point of contention, and rebuild after a disk loss is a manual, RAID-bound operation whose window grows linearly with disk size.
- **Sharded application-level storage** scales horizontally but pushes placement, rebalancing and durability up into every application team — the hardest distributed-systems problems, re-solved badly N times.

The architectural problem Ceph solves is: **provide object, block and file storage from one horizontally-scalable pool, with no central metadata bottleneck, no manual data placement, and self-healing recovery — on commodity hardware.** The three deliberate design choices that make this possible:

1. **No lookup table for object placement.** A metadata server that maps `object → location` is a bottleneck and a SPOF. Ceph replaces it with **CRUSH** (Controlled Replication Under Scalable Hashing): a deterministic, pseudo-random hash function that *computes* placement from the object name and the cluster topology. Any client that has the cluster map can independently calculate where any object lives — no round-trip to a directory service.
2. **Autonomic recovery.** OSDs (the per-disk daemons) peer with each other, detect failures, and re-replicate lost data automatically according to the CRUSH rules, without operator intervention and without a global lock.
3. **One object store, three personalities.** RADOS (the Reliable Autonomic Distributed Object Store) is the substrate. RBD (block), CephFS (POSIX file) and RGW (S3/Swift object) are thin translation layers on top of the *same* pool of OSDs. You provision capacity once.

### 1.2 The components you must be able to reason about

```
                          ┌──────────────────────────────────────────────┐
   Clients (librados,     │                   RADOS                       │
   RBD, CephFS, RGW/S3) ──┤   Reliable Autonomic Distributed Object Store │
                          └───────────────────┬──────────────────────────┘
        ┌───────────────┬────────────────┬────┴─────────┬────────────────┐
        │               │                │              │                │
   ┌────▼────┐     ┌────▼────┐      ┌────▼────┐    ┌────▼────┐      ┌────▼────┐
   │  MON    │     │  MGR    │      │  OSD    │    │  MDS    │      │  RGW    │
   │ cluster │     │ metrics │      │ per-disk│    │ CephFS  │      │ S3/Swift│
   │  maps + │     │dashboard│      │ storage │    │metadata │      │ gateway │
   │  Paxos  │     │ modules │      │ +recover│    │ (opt.)  │      │ (opt.)  │
   └─────────┘     └─────────┘      └─────────┘    └─────────┘      └─────────┘
   quorum: 3/5     active/stby      1 per device   active/stby      stateless
```

| Daemon | Binary | Role | Cardinality (production) | State it owns |
|---|---|---|---|---|
| Monitor | `ceph-mon` | Holds the authoritative **cluster maps** (MonMap, OSDMap, PGMap, CRUSHMap, MDSMap), forms Paxos **quorum**, authenticates clients (CephX) | **Odd**, 3 (small) or 5 (large). Never 2 or 4. | The single source of truth; small, consensus-critical |
| Manager | `ceph-mgr` | Metrics, `ceph orch`, dashboard, Prometheus exporter, `pg_autoscaler`, `balancer`, `devicehealth` | 2 (active + standby), co-located with MONs | Runtime/derived state; no data |
| OSD | `ceph-osd` | Stores objects on **one** block device via BlueStore; handles replication, recovery, backfill, scrubbing | **1 per data device** (dozens–thousands) | The actual data + PG membership |
| MDS | `ceph-mds` | POSIX metadata (inodes, dentries, capabilities) for **CephFS only** | ≥1 active + ≥1 standby *per filesystem* | Metadata, cached in RAM, journaled to a RADOS pool |
| RGW | `radosgw` | S3 / Swift REST gateway | ≥2 behind a load balancer | Stateless; data + index in pools |

**The mental model the exam rewards:** the MONs are a small, strongly-consistent control plane (Paxos, quorum, cluster maps). The OSDs are a large, eventually-peered data plane. CRUSH is the function that lets the data plane operate without asking the control plane where anything goes. Everything else (RBD, CephFS, RGW) is a client of RADOS.

---

## 2. Technical comparisons and trade-offs

### 2.1 Data protection: Replication vs Erasure Coding

The single most consequential pool-level decision. It trades raw-capacity efficiency against CPU, latency, and recovery cost.

| Dimension | Replication (`size=3`) | Erasure Coding (`k=4, m=2`) |
|---|---|---|
| Usable capacity | 33% (3× overhead) | 67% (1.5× overhead) |
| Failure tolerance | `size − 1` = 2 OSDs/hosts | `m` = 2 chunks |
| Write path | Write full object to 3 OSDs | Encode into `k+m` chunks, write to 6 OSDs |
| Read latency | Low — read from primary | Higher — may need to reconstruct from `k` chunks |
| Small-object / random I/O | Excellent | Poor (read-modify-write amplification) |
| CPU cost | Negligible | Significant (Reed-Solomon encode/decode) |
| Recovery traffic on failure | Copy whole objects | Recompute chunks — read `k` to rebuild 1 |
| Partial overwrites | Native | **Not supported** on EC pools without `allow_ec_overwrites` (and even then costly); RBD/CephFS on EC needs it |
| Typical use | RBD, CephFS metadata, hot data, MON-critical pools | RGW bulk objects, cold data, backups, media |

**Rule of thumb for production:** replication (`size=3`, `min_size=2`) for anything latency-sensitive or randomly-overwritten (RBD volumes, CephFS metadata pool); erasure coding for large-object, append-mostly workloads (object storage, archives). `min_size=2` on a 3× pool is deliberate: it means I/O blocks (rather than risks accepting a write to a single copy) when only one replica survives — availability yields to durability.

### 2.2 OSD backend: BlueStore vs FileStore

| Dimension | BlueStore (default since Luminous) | FileStore (removed in Reef) |
|---|---|---|
| Storage model | Raw block device, no filesystem | Objects as files on XFS |
| Metadata | RocksDB embedded | LevelDB + XFS extended attrs |
| Write amplification | ~1× (no double-write for large I/O) | ~2× (journal + filesystem journal) |
| Journal / WAL | Internal WAL + optional separate DB/WAL device | Separate journal partition mandatory |
| Checksums | Full-data CRC32C on every read | None (relies on XFS) |
| Compression | Native (inline, per-pool) | None |
| Status | **The only supported backend** | Deprecated; **do not deploy** |

**Takeaway for the exam and for production:** BlueStore is mandatory on any modern cluster. Its one tuning knob you must know is device separation — putting the RocksDB metadata (`block.db`) and WAL on fast NVMe while data sits on HDD dramatically improves small-write and metadata performance. Sizing: budget the `block.db` at roughly **1–4% of the data device** (Ceph's historical guidance was ~4% for RBD, less for RGW); an undersized DB *spills over* onto the slow data device silently and kills performance.

### 2.3 Deployment tooling: cephadm vs ceph-deploy vs Rook vs manual

| Tool | Model | Status | When |
|---|---|---|---|
| **cephadm** | Container (Podman/Docker) + systemd, driven by `ceph orch` over SSH | **Current, recommended** (since Octopus) | Bare-metal / VM production |
| `ceph-deploy` | Python SSH push, packages on host | **Deprecated / removed** | Legacy only — exam-historical |
| **Rook** | Kubernetes operator | Current | Ceph on/for Kubernetes |
| Manual / `ceph-volume` | Hand-placed systemd units | Supported but laborious | Air-gapped, bespoke |

`ceph-deploy` still appears in the LPI *Terms and Utilities* list because the objective predates its removal — know that it *existed* and pushed packages over SSH, but that **cephadm is the deployment path** and `ceph-volume` is the OSD-provisioning primitive underneath both.

### 2.4 Access method: RBD vs CephFS vs RGW

| | RBD | CephFS | RGW |
|---|---|---|---|
| Abstraction | Block device (virtual disk) | POSIX filesystem | Object store (S3/Swift REST) |
| Consumer | VMs (KVM/QEMU), `krbd`, k8s PVs | Multiple hosts, shared mount | Applications over HTTP |
| Extra daemon | none | **MDS** required | **RGW** required |
| Concurrency | Single writer (or clustered FS on top) | Many readers/writers, POSIX locks | Many, eventual within a bucket |
| Snapshots/clones | Yes (copy-on-write clones) | Yes (subtree snapshots) | Versioning |
| Typical pool layout | 1 replicated pool | metadata (repl) + data (repl or EC) pools | index/data pools (data often EC) |

---

## 3. Complete infrastructure and manifests

The following is a full, unabridged bootstrap of a production-shaped cluster with `cephadm`: 3 MON/MGR nodes and 4 OSD nodes, each OSD node carrying HDDs for data and NVMe for `block.db`.

### 3.1 Host inventory and prerequisites

```
# Topology
ceph-mon01  10.10.0.11   labels: _admin,mon,mgr
ceph-mon02  10.10.0.12   labels: mon,mgr
ceph-mon03  10.10.0.13   labels: mon,mgr
ceph-osd01  10.10.0.21   labels: osd    (sdb,sdc,sdd = HDD; nvme0n1 = DB)
ceph-osd02  10.10.0.22   labels: osd
ceph-osd03  10.10.0.23   labels: osd
ceph-osd04  10.10.0.24   labels: osd

# Networks (recommended split):
#   public network  10.10.0.0/24   client <-> daemon traffic
#   cluster network  10.20.0.0/24   OSD <-> OSD replication/recovery (isolates rebuild load)
```

Prerequisites on every node: Podman (or Docker), `chrony` (time sync is **not optional** — MON quorum breaks on clock skew), Python 3, and passwordless SSH for the cephadm key.

### 3.2 Bootstrap

```bash
# On ceph-mon01 — install the cephadm bootstrap tool for the Reef release
$ curl --silent --remote-name --location https://download.ceph.com/rpm-18.2.4/el9/noarch/cephadm
$ chmod +x cephadm
$ ./cephadm add-repo --release reef
$ ./cephadm install ceph-common

# Bootstrap the first MON + MGR, pinning the public network
$ cephadm bootstrap \
    --mon-ip 10.10.0.11 \
    --cluster-network 10.20.0.0/24 \
    --ssh-user root \
    --initial-dashboard-user admin \
    --initial-dashboard-password 'REDACTED' \
    --allow-fqdn-hostname
```

Expected tail of the bootstrap output:

```
Ceph Dashboard is now available at:

             URL: https://ceph-mon01:8443/
            User: admin
        Password: REDACTED

Enabling client.admin keyring and conf on hosts with "_admin" label
Saving cluster configuration to /var/lib/ceph/a7f64266-0894-4f1e-a635-d0aeaca0e993/config directory
Enabling autotune for osd_memory_target
You can access the Ceph CLI as following in case of multi-cluster or non-default config:

        sudo /usr/sbin/cephadm shell --fsid a7f64266-0894-4f1e-a635-d0aeaca0e993 -c /etc/ceph/ceph.conf -k /etc/ceph/ceph.client.admin.keyring

Bootstrap complete.
```

### 3.3 Enroll hosts and distribute the SSH key

```bash
# Copy the cluster's SSH public key to every future member
$ ceph cephadm get-pub-key > ~/ceph.pub
$ for h in mon02 mon03 osd01 osd02 osd03 osd04; do
    ssh-copy-id -f -i ~/ceph.pub root@ceph-$h
  done

# Add hosts with labels that drive placement
$ ceph orch host add ceph-mon02 10.10.0.12 --labels _no_schedule=false mon mgr
$ ceph orch host add ceph-mon03 10.10.0.13 mon mgr
$ ceph orch host add ceph-osd01 10.10.0.21 osd
$ ceph orch host add ceph-osd02 10.10.0.22 osd
$ ceph orch host add ceph-osd03 10.10.0.23 osd
$ ceph orch host add ceph-osd04 10.10.0.24 osd

$ ceph orch host ls
HOST        ADDR         LABELS          STATUS
ceph-mon01  10.10.0.11   _admin,mon,mgr
ceph-mon02  10.10.0.12   mon,mgr
ceph-mon03  10.10.0.13   mon,mgr
ceph-osd01  10.10.0.21   osd
ceph-osd02  10.10.0.22   osd
ceph-osd03  10.10.0.23   osd
ceph-osd04  10.10.0.24   osd
7 hosts in cluster
```

### 3.4 Declarative service specification (the whole cluster in one file)

cephadm is **declarative**: you describe the desired state in a spec and `ceph orch apply` reconciles it — the equivalent of a Kubernetes manifest for Ceph daemons.

```yaml
# cluster-services.yaml — apply with: ceph orch apply -i cluster-services.yaml
---
service_type: mon
service_name: mon
placement:
  label: mon
  count: 3
---
service_type: mgr
service_name: mgr
placement:
  label: mgr
  count: 2
---
# OSD "drive group": every OSD host, HDDs as data, NVMe as shared block.db,
# 4 DB slots per NVMe (one per HDD) so RocksDB lands on fast media.
service_type: osd
service_id: hdd_data_nvme_db
placement:
  label: osd
spec:
  data_devices:
    rotational: 1          # spinning disks -> data
  db_devices:
    rotational: 0          # NVMe/SSD      -> RocksDB (block.db)
  db_slots: 4
  filter_logic: AND
  objectstore: bluestore
---
service_type: mds
service_id: cephfs          # MDS for the "cephfs" filesystem
placement:
  label: mon                # co-locate MDS with control-plane nodes
  count: 2
---
service_type: rgw
service_id: default
placement:
  label: mon
  count: 2
spec:
  rgw_frontend_port: 8080
```

```bash
$ ceph orch apply -i cluster-services.yaml
Scheduled mon update...
Scheduled mgr update...
Scheduled osd.hdd_data_nvme_db update...
Scheduled mds.cephfs update...
Scheduled rgw.default update...

# Watch OSDs being created device-by-device
$ ceph orch device ls
HOST        PATH          TYPE  DEVICE ID          SIZE  AVAILABLE  REJECT REASONS
ceph-osd01  /dev/sdb      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/sdc      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/sdd      hdd   WDC_WD40EFRX...     4TB  Yes
ceph-osd01  /dev/nvme0n1  ssd   Samsung_PM983...  960GB  Yes
...
```

### 3.5 Pools, RBD, CephFS, erasure coding

```bash
# --- Replicated RBD pool (block storage for VMs) ---
$ ceph osd pool create rbd 128 128 replicated
$ ceph osd pool set rbd size 3
$ ceph osd pool set rbd min_size 2
$ ceph osd pool application enable rbd rbd
$ rbd pool init rbd

# Create a 100 GiB image and map it
$ rbd create rbd/vm-disk-01 --size 102400
$ rbd info rbd/vm-disk-01
rbd image 'vm-disk-01':
        size 100 GiB in 25600 objects
        order 22 (4 MiB objects)
        snapshot_count: 0
        id: 3a9f2c1b4e5d
        block_name_prefix: rbd_data.3a9f2c1b4e5d
        format: 2
        features: layering, exclusive-lock, object-map, fast-diff, deep-flatten
        op_features:
        flags:

# --- CephFS: metadata pool (replicated) + data pool (replicated) ---
$ ceph osd pool create cephfs_metadata 32 32
$ ceph osd pool create cephfs_data 128 128
$ ceph fs new cephfs cephfs_metadata cephfs_data
new fs with metadata pool 5 and data pool 6

$ ceph fs status cephfs
cephfs - 0 clients
======
RANK  STATE       MDS         ACTIVITY     DNS    INOS   DIRS   CAPS
 0    active  cephfs.ceph-mon01  Reqs:    0 /s    10     13     12      0
      POOL         TYPE     USED  AVAIL
cephfs_metadata  metadata   96k   13.6T
  cephfs_data      data       0   13.6T
STANDBY MDS
cephfs.ceph-mon02

# --- Erasure-coded pool for RGW bulk data (k=4, m=2, host-level failure domain) ---
$ ceph osd erasure-code-profile set ec42 \
    k=4 m=2 crush-failure-domain=host plugin=jerasure technique=reed_sol_van
$ ceph osd erasure-code-profile get ec42
crush-device-class=
crush-failure-domain=host
crush-root=default
jerasure-per-chunk-alignment=false
k=4
m=2
plugin=jerasure
technique=reed_sol_van
w=8
$ ceph osd pool create rgw_data 128 128 erasure ec42
$ ceph osd pool set rgw_data allow_ec_overwrites true   # only if a client needs partial writes
```

### 3.6 Working with the CRUSH map directly

The CRUSH map encodes the physical topology (device → host → rack → root) and the placement rules. You extract it, decompile to text, edit, recompile and inject.

```bash
# Extract, decompile, edit, recompile, inject
$ ceph osd getcrushmap -o crush.bin
$ crushtool -d crush.bin -o crush.txt
```

A representative decompiled `crush.txt` (edited to add a `rack` tier and an SSD rule):

```
# begin crush map
tunable choose_local_tries 0
tunable choose_local_fallback_tries 0
tunable choose_total_tries 50
tunable chooseleaf_descend_once 1
tunable chooseleaf_vary_r 1
tunable chooseleaf_stable 1
tunable straw_calc_version 1
tunable allowed_bucket_algs 54

# devices
device 0 osd.0 class hdd
device 1 osd.1 class hdd
device 2 osd.2 class hdd
device 3 osd.3 class ssd

# types
type 0 osd
type 1 host
type 2 rack
type 3 root

# buckets
host ceph-osd01 {
        id -3          # do not change unnecessarily
        alg straw2
        hash 0         # rjenkins1
        item osd.0 weight 3.638
        item osd.1 weight 3.638
        item osd.2 weight 3.638
}
rack rack-a {
        id -10
        alg straw2
        hash 0
        item ceph-osd01 weight 10.914
        item ceph-osd02 weight 10.914
}
root default {
        id -1
        alg straw2
        hash 0
        item rack-a weight 21.828
        item rack-b weight 21.828
}

# rules
rule replicated_rule {
        id 0
        type replicated
        step take default
        step chooseleaf firstn 0 type host
        step emit
}
rule ssd_rule {
        id 1
        type replicated
        step take default class ssd
        step chooseleaf firstn 0 type host
        step emit
}
# end crush map
```

```bash
$ crushtool -c crush.txt -o crush-new.bin
# Test the rule against a virtual cluster before injecting (dry-run mapping)
$ crushtool -i crush-new.bin --test --rule 0 --num-rep 3 --show-mappings | head
CRUSH rule 0 x 0 [1,4,7]
CRUSH rule 0 x 1 [8,2,5]
CRUSH rule 0 x 2 [0,6,3]
...
$ ceph osd setcrushmap -i crush-new.bin
```

The safer, modern alternative to hand-editing is the CLI, which mutates the CRUSH map transactionally:

```bash
$ ceph osd crush add-bucket rack-a rack
$ ceph osd crush move rack-a root=default
$ ceph osd crush move ceph-osd01 rack=rack-a
$ ceph osd crush rule create-replicated rack_rule default rack hdd
```

---

## 4. Operational CLI and real terminal output

### 4.1 The one command you run first, always: `ceph -s`

```
$ ceph -s
  cluster:
    id:     a7f64266-0894-4f1e-a635-d0aeaca0e993
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum ceph-mon01,ceph-mon02,ceph-mon03 (age 3d)
    mgr: ceph-mon01(active, since 3d), standbys: ceph-mon02
    mds: 1/1 daemons up, 1 hot standby
    osd: 12 osds: 12 up (since 3d), 12 in (since 3d)
    rgw: 2 daemons active (2 hosts, 1 zones)

  data:
    volumes: 1/1 healthy
    pools:   8 pools, 289 pgs
    objects: 1.24M objects, 3.8 TiB
    usage:   11 TiB used, 32 TiB / 43 TiB avail
    pgs:     289 active+clean
```

Read it top-down: **quorum** (are the MONs agreeing?), **osd up/in** (`up` = reachable, `in` = participating in data placement — a down OSD is still `in` until marked `out`), and the **pgs line** (every PG should be `active+clean`; anything else is the fault).

### 4.2 OSD topology and utilization

```
$ ceph osd tree
ID   CLASS  WEIGHT    TYPE NAME            STATUS  REWEIGHT  PRI-AFF
 -1         43.656    root default
-10         21.828        rack rack-a
 -3         10.914            host ceph-osd01
  0    hdd   3.638                osd.0        up   1.00000  1.00000
  1    hdd   3.638                osd.1        up   1.00000  1.00000
  2    hdd   3.638                osd.2        up   1.00000  1.00000
 -5         10.914            host ceph-osd02
  3    hdd   3.638                osd.3        up   1.00000  1.00000
  ...
-11         21.828        rack rack-b
  ...

$ ceph osd df
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     OMAP    META    AVAIL    %USE   VAR   PGS  STATUS
 0    hdd  3.63869   1.00000  3.6 TiB  957 GiB  951 GiB   12 MiB  5.4 GiB  2.7 TiB  25.68  1.01   74      up
 1    hdd  3.63869   1.00000  3.6 TiB  931 GiB  925 GiB   11 MiB  5.2 GiB  2.7 TiB  24.98  0.98   71      up
 ...
                       TOTAL   43 TiB   11 TiB   11 TiB  141 MiB   65 GiB   32 TiB  25.44
MIN/MAX VAR: 0.94/1.07  STDDEV: 0.71
```

`%USE` skew across OSDs is what the `balancer` mgr module and `reweight` exist to correct — CRUSH is pseudo-random, so utilization drifts; a `STDDEV` climbing above a few percent is your cue.

### 4.3 Capacity and pools

```
$ ceph df
--- RAW STORAGE ---
CLASS     SIZE    AVAIL     USED  RAW USED  %RAW USED
hdd     43 TiB   32 TiB   11 TiB    11 TiB      25.44
TOTAL   43 TiB   32 TiB   11 TiB    11 TiB      25.44

--- POOLS ---
POOL              ID  PGS   STORED   OBJECTS     USED  %USED  MAX AVAIL
.mgr               1    1   577 KiB        2  1.7 MiB      0     10 TiB
rbd                2  128   2.9 TiB   765.4k   8.7 TiB  22.29     10 TiB
cephfs_metadata    5   32   112 MiB    2.31k   337 MiB      0     10 TiB
cephfs_data        6  128   612 GiB   156.8k   1.8 TiB   5.68     10 TiB
rgw_data           7  128   380 GiB    98.2k   570 GiB   1.83     20 TiB
```

Note `USED` on the replicated `rbd` pool is 3× `STORED` (replication overhead); on the EC `rgw_data` pool it is 1.5× (`k=4,m=2`). `MAX AVAIL` is what a pool can still absorb given its replication rule and the fullest OSD — the number that actually matters for capacity planning.

### 4.4 Placement groups and the autoscaler

```
$ ceph pg stat
289 pgs: 289 active+clean; 3.8 TiB data, 11 TiB used, 32 TiB / 43 TiB avail

$ ceph osd pool autoscale-status
POOL             SIZE  TARGET SIZE  RATE  RAW CAPACITY  RATIO  TARGET RATIO  BIAS  PG_NUM  NEW PG_NUM  AUTOSCALE  BULK
.mgr             577k                3.0        43776G  0.0000                1.0       1              on         False
rbd             2979G                3.0        43776G  0.2042                1.0     128              on         False
cephfs_data      612G                3.0        43776G  0.0419                1.0     128              on         True
rgw_data         380G                1.5        43776G  0.0130                1.0     128              on         True

# Turn the autoscaler on/off per pool, or set an expected size to pre-size PGs
$ ceph osd pool set rbd pg_autoscale_mode on
$ ceph osd pool set rgw_data target_size_ratio 0.4
```

### 4.5 RADOS at the object level (below RBD/CephFS/RGW)

```bash
# Write, list, read a raw object directly into a pool — proves RADOS independent of any gateway
$ echo "durability test" | rados -p rbd put testobj -
$ rados -p rbd ls | grep testobj
testobj
$ rados -p rbd get testobj -
durability test

# Which PG and which OSDs hold it? (CRUSH computed, no lookup table)
$ ceph osd map rbd testobj
osdmap e412 pool 'rbd' (2) object 'testobj' -> pg 2.4d7ac59f (2.1f) ->
  up ([5,1,9], p5) acting ([5,1,9], p5)

$ rados -p rbd df
POOL_NAME   USED  OBJECTS  CLONES  COPIES  MISSING_ON_PRIMARY  UNFOUND  DEGRADED  RD_OPS   RD      WR_OPS   WR
rbd      8.7 TiB   765400       0  2296200                  0        0         0  4.2M   112 GiB  9.8M    3.1 TiB
```

`up` is the CRUSH-desired set; `acting` is who is actually serving right now — when they differ, the PG is `remapped` and data is migrating.

### 4.6 Orchestration inventory

```
$ ceph orch ls
NAME                     PORTS   RUNNING  REFRESHED  AGE  PLACEMENT
mgr                                  2/2  5m ago     3d   count:2
mon                                  3/3  5m ago     3d   label:mon;count:3
osd.hdd_data_nvme_db                12/12 5m ago     3d   label:osd
mds.cephfs                           2/2  5m ago     3d   label:mon;count:2
rgw.default              ?:8080      2/2  5m ago     3d   label:mon;count:2

$ ceph orch ps ceph-osd01
NAME        HOST        PORTS  STATUS         REFRESHED  AGE  MEM USE  MEM LIM  VERSION  IMAGE ID
osd.0       ceph-osd01         running (3d)   5m ago     3d   1834M    4096M    18.2.4   2bc0b0f4375d
osd.1       ceph-osd01         running (3d)   5m ago     3d   1791M    4096M    18.2.4   2bc0b0f4375d
osd.2       ceph-osd01         running (3d)   5m ago     3d   1802M    4096M    18.2.4   2bc0b0f4375d
```

---

## 5. Verification and failure-diagnosis guide

The diagnostic loop is always the same: **`ceph health detail` → identify the subsystem → drill into that subsystem's status → act → re-verify with `ceph -s`.**

### 5.1 The health ladder

```
$ ceph health detail
HEALTH_WARN 1 osds down; Degraded data redundancy: 71/2296200 objects degraded (0.003%), 12 pgs degraded
[WRN] OSD_DOWN: 1 osds down
    osd.7 (root=default,rack=rack-b,host=ceph-osd03) is down
[WRN] PG_DEGRADED: Degraded data redundancy: 71/2296200 objects degraded (0.003%), 12 pgs degraded
    pg 2.a is active+undersized+degraded, acting [3,11]
    pg 6.1c is active+undersized+degraded, acting [5,2]
    ...
```

### 5.2 Diagnosing a down OSD

```bash
# Is it the disk, the daemon, or the host?
$ ceph osd tree down
ID  CLASS  WEIGHT   TYPE NAME          STATUS  REWEIGHT  PRI-AFF
 7    hdd  3.638         osd.7           down   1.00000  1.00000

# Inspect the daemon on its host
$ ceph orch ps --daemon-type osd --daemon-id 7
NAME   HOST        STATUS              MEM USE  VERSION  IMAGE ID
osd.7  ceph-osd03  error (5m ago)      -        18.2.4   2bc0b0f4375d

$ cephadm logs --name osd.7 --fsid a7f64266-... | tail -20
... bluestore(/var/lib/ceph/osd/ceph-7) _open_db erroring opening db:
... _txc_add_transaction error (2) No such file or directory
... ** ERROR: osd init failed: (5) Input/output error   # <-- disk-level I/O error

# Confirm at the kernel level
$ dmesg | grep -i 'sd\|I/O error' | tail
[924831.10] blk_update_request: I/O error, dev sde, sector 1902847488
```

Decision: transient? `ceph orch daemon restart osd.7`. Dead disk? Mark it out, let CRUSH heal, then replace:

```bash
$ ceph osd out osd.7                       # trigger rebalancing away from it
$ ceph osd safe-to-destroy osd.7           # wait until this returns safe
OSD(s) 7 are safe to destroy without reducing data durability.
$ ceph orch osd rm 7 --replace --zap       # remove, keep the ID for the replacement disk
$ ceph orch osd rm status
OSD  HOST        STATE      PGS  REPLACE  FORCE  ZAP
7    ceph-osd03  draining   34   True     False  True
# insert new disk; the drive-group spec auto-provisions a new osd.7 on it
```

### 5.3 Reading PG states (the vocabulary the exam tests)

| PG state | Meaning | Typical cause | Action |
|---|---|---|---|
| `active+clean` | Healthy, all replicas present | — | none |
| `degraded` | Fewer than `size` copies exist | OSD down/out | wait for recovery |
| `undersized` | Fewer OSDs than pool `size` available | Not enough hosts up | add capacity / fix hosts |
| `remapped` | `acting` ≠ `up` — data migrating | rebalance, reweight, CRUSH change | wait for backfill |
| `backfilling`/`recovering` | Data being copied | after failure/rebalance | throttle if impacting clients |
| `peering` | OSDs agreeing on PG contents | transient | wait; if stuck, investigate |
| `stale` | No report from the acting primary | primary OSD down or flapping | restart/replace the OSD |
| `incomplete` | Not enough surviving copies to be safe | lost too many OSDs; `min_size` unmet | recover OSDs or accept loss |
| `inconsistent` | Scrub found a replica mismatch | bit-rot, bad disk | `ceph pg repair` |
| `down` | An OSD holding needed data is down and its data is required for peering | lost the only up-to-date copy | bring that OSD back |

```bash
$ ceph pg dump_stuck
PG_STAT  STATE                          UP       ACTING
2.a      active+undersized+degraded  [3,11]     [3,11]

$ ceph pg 2.a query | jq '.recovery_state[0].name'
"Started/Primary/Active"
```

### 5.4 Inconsistent PGs (silent corruption caught by scrub)

BlueStore checksums catch bit-rot on read; **scrubbing** proactively compares replicas. An `inconsistent` PG is a data-integrity event:

```bash
$ ceph health detail
HEALTH_ERR 1 scrub errors; Possible data damage: 1 pg inconsistent
[ERR] PG_DAMAGED: Possible data damage: 1 pg inconsistent
    pg 6.4b is active+clean+inconsistent, acting [2,7,11]

# Find which object and which OSD disagrees
$ rados list-inconsistent-obj 6.4b --format=json-pretty | jq '.inconsistents[].shards'
[
  {"osd":2,"errors":[],"size":4194304,"data_digest":"0x2d4a1e3f"},
  {"osd":7,"errors":["data_digest_mismatch_info"],"size":4194304,"data_digest":"0x00000000"},
  {"osd":11,"errors":[],"size":4194304,"data_digest":"0x2d4a1e3f"}
]

# osd.7 is the outlier -> repair copies a good replica over the bad shard
$ ceph pg repair 6.4b
instructing pg 6.4b on osd.2 to repair
```

### 5.5 MON quorum and clock skew (the control-plane failure)

Lose quorum and the whole cluster stops — clients can no longer get an authoritative map. The most common non-hardware cause is **clock skew** across MONs.

```bash
$ ceph health detail
HEALTH_WARN clock skew detected on mon.ceph-mon03
[WRN] MON_CLOCK_SKEW: clock skew detected on mon.ceph-mon03
    mon.ceph-mon03 clock skew 0.612s > max 0.05s

$ ceph quorum_status --format json-pretty | jq '.quorum_names'
["ceph-mon01","ceph-mon02","ceph-mon03"]

# Fix: verify chrony is synced everywhere
$ chronyc tracking | grep -E 'Reference|System time'
Reference ID    : C0A80001 (ntp.internal)
System time     : 0.000031 seconds fast of NTP time
```

MON store growth (`mon.X is using a lot of disk space`) is the other classic MON alert — usually because the cluster has been in a non-`HEALTH_OK` state for a long time, so the MONs cannot trim old maps. The fix is to *return the cluster to health*, not to delete the store.

### 5.6 The "full" cascade — the most dangerous production state

Ceph refuses writes before an OSD physically fills, because a 100%-full OSD cannot even record its own recovery bookkeeping. Three ratios gate this:

| Ratio | Default | Effect when crossed |
|---|---|---|
| `mon_osd_nearfull_ratio` | 0.85 | `HEALTH_WARN`, plan capacity |
| `mon_osd_backfillfull_ratio` | 0.90 | Backfill/recovery to that OSD **stops** |
| `mon_osd_full_ratio` | 0.95 | **All writes to any pool using that OSD block** |

```bash
$ ceph health detail
HEALTH_ERR 1 full osd(s); 2 nearfull osd(s)
[ERR] OSD_FULL: 1 full osd(s)
    osd.4 is full at 95%
[WRN] OSD_NEARFULL: 2 nearfull osd(s)
    osd.1 is near full at 87%
    osd.9 is near full at 86%

# EMERGENCY relief only — nudge the ratio to unblock writes long enough to add capacity
$ ceph osd set-full-ratio 0.96
# Real fix: add OSDs, or reweight to move data off the hot OSD
$ ceph osd reweight-by-utilization 110       # reweight OSDs above 110% of average down
```

A full cluster is genuinely hard to recover from because *deleting* data also needs writes. Prevention — the autoscaler, the balancer, and alerting at `nearfull` — is the entire strategy.

### 5.7 Slow ops / performance regression

```bash
$ ceph health detail
HEALTH_WARN 2 slow ops, oldest one blocked for 34 sec, osd.9 has slow ops
[WRN] SLOW_OPS: 2 slow ops, oldest one blocked for 34 sec, daemons [osd.9] have slow ops.

# Dump the in-flight ops on the offending OSD
$ ceph daemon osd.9 dump_historic_ops | jq '.ops[0].description'
"osd_op(client.44123.0:98213 6.1c 6:38...rbd_data... [write 0~4194304])"

# Per-OSD latency — apply/commit latency spikes point at a dying disk or spilled RocksDB
$ ceph osd perf
osd  commit_latency(ms)  apply_latency(ms)
  9                 214                214    <-- outlier, investigate the device
  3                   2                  2
  ...
```

### 5.8 Standard verification checklist after any change

```bash
$ ceph -s                          # quorum, osd up/in, all pgs active+clean
$ ceph health detail               # zero warnings/errors
$ ceph osd tree                    # every OSD up + in, correct CRUSH placement
$ ceph df                          # MAX AVAIL sane, no pool over nearfull
$ ceph osd pool autoscale-status   # PG counts converged
$ ceph fs status <fs>              # 1 active MDS + standby per filesystem
$ ceph orch ls                     # every service RUNNING at desired count
```

The single acceptance criterion for "the cluster is healthy": **`HEALTH_OK` and every PG `active+clean`.** Any other PG state means data is either at reduced redundancy or migrating, and no maintenance (reboot, OSD removal, upgrade) should proceed until it clears.

---

## 6. References

- LPI — Exam 306 Objectives (306-300, v3.0), Topic 363.2 Ceph Storage Clusters: https://www.lpi.org/our-certifications/exam-306-objectives/
- Ceph Documentation — Intro & Architecture: https://docs.ceph.com/en/reef/architecture/
- Ceph — RADOS / Cluster Operations: https://docs.ceph.com/en/reef/rados/
- Ceph — CRUSH Maps: https://docs.ceph.com/en/reef/rados/operations/crush-map/
- Ceph — Pools: https://docs.ceph.com/en/reef/rados/operations/pools/
- Ceph — Placement Groups & Autoscaler: https://docs.ceph.com/en/reef/rados/operations/placement-groups/
- Ceph — Erasure Code: https://docs.ceph.com/en/reef/rados/operations/erasure-code/
- Ceph — BlueStore configuration & sizing: https://docs.ceph.com/en/reef/rados/configuration/bluestore-config-ref/
- Ceph — cephadm (install & host/service management): https://docs.ceph.com/en/reef/cephadm/
- Ceph — Service Specifications & OSD drive groups: https://docs.ceph.com/en/reef/cephadm/services/osd/
- Ceph — Monitor configuration & troubleshooting: https://docs.ceph.com/en/reef/rados/configuration/mon-config-ref/ and https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-mon/
- Ceph — Troubleshooting OSDs & PGs: https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-osd/ and https://docs.ceph.com/en/reef/rados/troubleshooting/troubleshooting-pg/
- Ceph — RBD (block device): https://docs.ceph.com/en/reef/rbd/
- Ceph — CephFS (filesystem & MDS): https://docs.ceph.com/en/reef/cephfs/
- Ceph — RADOS Gateway (RGW): https://docs.ceph.com/en/reef/radosgw/
- Ceph — Health checks reference: https://docs.ceph.com/en/reef/rados/operations/health-checks/
- CRUSH: Controlled, Scalable, Decentralized Placement of Replicated Data — Weil et al., SC '06: https://ceph.io/assets/pdfs/weil-crush-sc06.pdf