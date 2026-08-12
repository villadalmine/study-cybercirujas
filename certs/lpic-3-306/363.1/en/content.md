# LPIC-3 306 — Topic 363.1: GlusterFS Storage Clusters

**Exam:** 306-300 (v3.0) · **Objective weight:** 8.33 · **Profile:** Principal Platform Architect / SRE

---

## 1. The production problem: scale-out POSIX storage without a metadata bottleneck

You run a fleet of application servers that need a **shared, POSIX-compliant filesystem** — user uploads, CI artifacts, container image layers, VM disk images, WORM-ish log archives. The naïve answer is a single NFS filer. That answer has three failure modes that show up at scale, and every one of them eventually pages you:

1. **Capacity ceiling.** A single NAS head scales *up* (bigger box) but not *out*. When the volume fills, you are migrating data, not adding a node.
2. **The metadata server is a SPOF and a hotspot.** Lustre, older CephFS, and HDFS route every `open()`/`lookup()`/`create()` through a metadata service. Under a `find`-heavy or small-file workload the MDS saturates long before the data path does, and if it dies the whole namespace stalls.
3. **Availability is bolted on.** NFS + DRBD + Pacemaker gives you an active/passive pair, not a scale-out cluster. Failover is measured in seconds of I/O freeze and the standby capacity is dead weight.

**GlusterFS attacks all three by deleting the metadata server entirely.** There is no metadata service and no central catalog of "which node holds file X." Instead, the location of a file is *computed* from its name via a consistent-hash algorithm (the **DHT** — Distributed Hash Table — translator, historically called *elastic hashing*). Any client can independently derive the brick that owns a file with zero lookups against a coordinator. This is the single most important architectural fact about Gluster, and it drives every trade-off below: no metadata server means near-linear scale-out and no metadata hotspot, but it also means Gluster is weak exactly where metadata servers are strong — massive small-file and deep-directory-listing workloads, where the hash-and-fan-out-to-every-brick lookup pattern gets expensive.

> **Reality check (2024–2025):** Red Hat sunset *Red Hat Gluster Storage* (RHGS) and steered customers toward Ceph/ODF; upstream GlusterFS remains community-maintained. It is still a **v3.0 exam objective** and still deployed widely (legacy RHGS estates, oVirt/RHV hyperconverged, and countless self-managed clusters), so you must know it cold. Where it is being displaced, the replacement is Ceph — Topic 364 — and this study guide flags those boundaries explicitly.

### The translator stack — Gluster's core abstraction

GlusterFS is not a monolith; it is a **graph of stackable translators** (`.so` modules), each exposing and consuming the same POSIX-like interface (`FOP`s — File OPerations). A "volume" is really a *volfile* — a graph description — compiled by `glusterd` and shipped to clients and bricks. This is what makes features composable: replication, distribution, erasure coding, caching, quotas, and sharding are all just translators inserted at the right layer.

```
   FUSE mount (application)
        │
   ┌────┴─────────────────────────── CLIENT-SIDE GRAPH ────────────┐
   │ io-stats                                                       │
   │ meta / quick-read / md-cache / io-cache / read-ahead          │  performance
   │ write-behind                                                   │  translators
   │ DHT (distribute)        ← computes brick from filename hash    │
   │   ├── AFR (replicate)   ← replica sets, self-heal, quorum      │
   │   └── EC  (disperse)    ← erasure coding (alt. to AFR)         │
   │ client (protocol/client, one per brick, TCP/RDMA)             │
   └───────────────────────────────────────────────────────────────┘
        │  network (port 24007 mgmt, 49152+ per brick)
   ┌────┴─────────────────────────── SERVER-SIDE GRAPH ────────────┐
   │ protocol/server                                                │
   │ io-threads / index / locks / access-control / marker          │
   │ changelog / bitrot-stub / quota / trash                        │
   │ posix  ← reads/writes the underlying brick filesystem (XFS)    │
   └───────────────────────────────────────────────────────────────┘
        │
   Brick = XFS-on-LVM-thin directory, e.g. gluster1:/data/brick1/gv0
```

**Key insight that trips up operators:** with the native FUSE client, *replication and distribution happen client-side*. The client connects to **all** bricks directly and writes each replica itself. There is no server-side fan-out. That is why (a) a FUSE client must have network reachability and firewall access to *every* brick, and (b) write bandwidth is divided by the replica count *at the client's NIC*. NFS/SMB/libgfapi access re-introduce a server-side proxy that changes this calculus (Section 2, access-method table).

### Component and daemon inventory (exam-critical vocabulary)

| Component | What it is | Where it runs | Port(s) |
|---|---|---|---|
| **`glusterd`** | Management daemon. Owns the trusted storage pool, the config store (`/var/lib/glusterd`), volfile generation, and spawns brick processes. This is the only service you `systemctl enable`. | Every node | **24007** (mgmt), 24008 (RDMA) |
| **`glusterfsd`** | The **brick** process. One per brick, or many-per-process with *brick multiplexing*. Runs the server-side translator graph down to `posix`. | Every node with bricks | **49152–49251** (one per brick, TCP) |
| **`glusterfs`** | Multi-purpose client binary. Backs the FUSE mount, the self-heal daemon (`glustershd`), the (deprecated) gluster-NFS server, quota daemon, snapshot daemon. | Clients + servers | — (FUSE), 38465–38467 (gNFS) |
| **`gluster`** | The CLI. Talks to local `glusterd` over a UNIX socket; `glusterd` gossips changes cluster-wide. | Any pool member | — |
| **`glustershd`** | Self-heal daemon (an internal `glusterfs` client). Walks the AFR/EC index and repairs stale/missing replicas. | Every node with replicated/dispersed bricks | — |
| **Brick** | An export directory on a server-local filesystem. Format `host:/absolute/path`. **Recommended: a directory *inside* an XFS-on-LVM-thin mount**, never the mount root. | — | — |
| **Trusted Storage Pool** | The set of peered nodes (`gluster peer probe`). | — | — |
| **Volfile** | Auto-generated translator-graph file served by glusterd. | `/var/lib/glusterd/vols/<vol>/` | — |
| **libgfapi** | Userspace C library to access a volume **without FUSE** — used by QEMU (`gluster://`), NFS-Ganesha (`FSAL_GLUSTER`), Samba (`vfs_glusterfs`). Skips the FUSE context switch and double copy. | Linked into app | — |

Config lives in two places you must memorize:
- **`/etc/glusterfs/glusterd.vol`** — the *glusterd* daemon's own config (base-port, brick-multiplex, RPC auth, transport). Rarely edited.
- **`/var/lib/glusterd/`** — the runtime config store: `glusterd.info` (this node's UUID), `peers/` (pool membership), `vols/` (volume definitions, volfiles, brick metadata), `snaps/`, `geo-replication/`. **This directory is the source of truth; back it up.** Never hand-edit it on a running cluster.

---

## 2. Technical comparisons and trade-off tables

### 2.1 Volume types — the decision that determines your durability and cost

A Gluster volume composes two orthogonal axes: **distribution** (spread capacity across bricks, via DHT) and **redundancy** (survive brick loss, via AFR replication *or* EC dispersal). You pick one redundancy scheme and optionally distribute over N copies of it.

| Volume type | Layout notation | Min bricks | Usable capacity | Survives | Write amplification | Best for |
|---|---|---|---|---|---|---|
| **Distributed** | `N × 1` | 1 | 100% | **nothing** — lose a brick, lose those files | 1× | Scratch / reconstructable data only |
| **Replicated** | `1 × R` | R (usu. 3) | 1/R | R−1 brick failures | R× | Small clusters, VM stores, HA namespace |
| **Distributed-Replicated** | `N × R` | N·R | 1/R | R−1 per replica set | R× | The workhorse: HA **and** scale-out |
| **Dispersed (EC)** | `1 × (K+M)` | K+M | K/(K+M) | M brick failures | ~(K+M)/K | Capacity-efficient cold/warm bulk |
| **Distributed-Dispersed** | `N × (K+M)` | N·(K+M) | K/(K+M) | M per disperse set | ~(K+M)/K | Large archives, media, backups |
| **Arbiter** | `1 × (2+A)` | 3 | 1/2 (data on 2) | 1 data brick, no split-brain | 2× data + metadata | replica-3 durability at ~replica-2 cost |
| ~~Striped~~ / ~~Striped-Replicated~~ | — | — | — | — | — | **REMOVED.** Use `features.shard` instead |

**Reading the notation.** `gluster volume info` prints `Number of Bricks: N x R = total` (replicated) or `N x (K + M) = total` (dispersed). Example: `2 x (4 + 2) = 12` is a distributed-dispersed volume — two erasure-coded sets, each 4 data + 2 redundancy fragments, 12 bricks total, ~66% usable, survives any 2 brick failures *per set*.

**EC capacity vs. replication, concretely.** For 100 TB usable:
- replica-3 → 300 TB raw (33% efficiency)
- disperse 4+2 → 150 TB raw (66% efficiency)
- disperse 8+3 → ~137 TB raw (72% efficiency), survives 3 failures

EC wins on $/TB dramatically but costs CPU (Reed-Solomon encode/decode on every I/O) and has a brutal small-file and partial-write penalty (read-modify-write across all fragments). **Rule of thumb: AFR for hot/small/random and VM images; EC for large-file, sequential, capacity-bound bulk.**

### 2.2 replica 2 vs replica 3 vs arbiter — the split-brain problem

`replica 2` is a **trap** and the exam expects you to know why. With two copies and a network partition, both sides can accept writes; when the partition heals, AFR sees each replica claiming the other is stale (each holds pending `trusted.afr.*` xattrs pointing at the other) → **split-brain**, and self-heal *refuses* to pick a winner because doing so silently discards data.

| Scheme | Bricks | Data copies | Metadata copies | Split-brain possible? | Cost | Quorum behavior |
|---|---|---|---|---|---|---|
| **replica 2** | 2 | 2 | 2 | **Yes** — avoid in production | 2× | No majority possible; client-quorum blocks writes on any single-brick loss (defeats HA) |
| **replica 3** | 3 | 3 | 3 | No (majority arbitrates) | 3× | `quorum-type auto` → writes allowed while ≥2 up |
| **replica 3 arbiter 1** | 3 | **2** | 3 | No (arbiter breaks ties) | ~2× + tiny | Arbiter votes on metadata; blocks write if it can't establish which data brick is current |

The **arbiter** brick stores only file metadata (names, `gfid`, AFR xattrs, sizes) — **zero file data** — so it costs a few GB, not a third data copy. It exists solely to be the third quorum vote that prevents split-brain. The catch: an arbiter volume can **refuse writes** when only the arbiter plus one data brick are up but the arbiter's metadata says that surviving data brick is stale (correctly preferring `EIO`/`ENOTCONN` over serving stale data). That is the intended safety behavior, not a bug.

**Server-side vs client-side quorum — you need both, they do different jobs:**

| Quorum | Option | Enforced by | Prevents |
|---|---|---|---|
| **Client-side** | `cluster.quorum-type auto\|fixed`, `cluster.quorum-count` | The mount/client (AFR) | Split-brain: client refuses *writes* when its replica set lacks quorum |
| **Server-side** | `cluster.server-quorum-type server`, `cluster.server-quorum-ratio 51%` | `glusterd` | Split-brain of the *management plane*: glusterd kills local bricks when the pool loses majority, so a minority partition can't serve I/O at all |

### 2.3 GlusterFS vs. the alternatives

| Dimension | **GlusterFS** | **Ceph (RADOS/CephFS)** — Topic 364 | **NFS (+DRBD/Pacemaker)** | **Lustre** |
|---|---|---|---|---|
| Data placement | Algorithmic hash (DHT), **no metadata server** | Algorithmic (CRUSH) + MON/OSD map; CephFS adds MDS | Central export, single namespace | Central MDS/MDT |
| Object vs file | **File-native** (POSIX FUSE) | Object-native; file (CephFS) & block (RBD) on top | File | File (HPC) |
| Scale-out | Add bricks/nodes, rebalance | Add OSDs, auto-rebalance | Scale-**up** only | Scale-out (HPC) |
| Redundancy | AFR replica / EC disperse | replica / EC pools | DRBD block mirror | RAID + failover |
| Metadata hotspot | **None** (strength) | MDS for CephFS | Single head | MDS |
| Small-file / `ls -R` | **Weak** (fan-out lookup) | Moderate (MDS caches) | Strong (local) | Strong |
| Operational complexity | **Low** (one daemon, dir bricks) | High (MON/MGR/OSD/MDS) | Low | High |
| Self-healing | `glustershd`, changelog xattrs | Autonomous scrub/recovery | Manual after failover | Manual |
| Snapshots | LVM-thin backed | RADOS native | LVM/DRBD | Limited |
| Sweet spot | Medium clusters, VM/media/backup, simple ops | Large multi-protocol clouds, k8s | Small shared mounts | HPC scratch |

**The honest one-liner:** Gluster is *simpler to operate* than Ceph and needs no metadata tier, at the cost of weaker small-file/metadata-heavy performance and a smaller future. If you're greenfield at large scale, the industry has moved to Ceph. If you have an existing estate or want the lowest-ops scale-out NAS, Gluster is still a rational, well-understood choice.

### 2.4 Access methods — the FUSE-vs-the-rest trade-off

| Method | Path | Server-side fan-out? | Pros | Cons |
|---|---|---|---|---|
| **Native FUSE** (`mount -t glusterfs`) | client → all bricks | **No** — client replicates | HA (`backup-volfile-servers`), no proxy SPOF, full feature set | FUSE context-switch cost; client needs reachability + firewall to every brick; write ÷ replica at client NIC |
| **NFS-Ganesha** (libgfapi FSAL) | client → Ganesha → bricks | Yes (Ganesha proxies) | NFSv3/v4, standard clients, no FUSE; pair with CTDB/VIP for HA | Ganesha node is a hop/SPOF unless clustered |
| **SMB / Samba** (`vfs_glusterfs`, libgfapi) | client → smbd → bricks | Yes | Windows/macOS clients; CTDB for HA + failover | Samba tuning; extra hop |
| **libgfapi** (QEMU `gluster://`, apps) | app → bricks | No | Zero FUSE overhead, best for VM images | App must link the library |
| ~~gluster-NFS (gnfs)~~ | — | — | **Deprecated & off by default** (`nfs.disable: on`) | Use NFS-Ganesha |

---

## 3. Complete infrastructure and manifests (uncut)

### 3.1 Brick preparation — XFS on LVM thin (required for snapshots)

Bricks **must** be on thin-provisioned LVM if you want `gluster snapshot` (snapshots are LVM thin snapshots under the hood). XFS with 512-byte inodes is the documented, tested backing filesystem — the large inode holds Gluster's extended attributes inline.

```bash
#!/usr/bin/env bash
# prepare-brick.sh — run on each storage node. Idempotent-ish; guards included.
set -euo pipefail

DISK=/dev/sdb
VG=vg_bricks
POOL=thinpool
LV=brick1
POOL_SIZE=500G          # physical pool
LV_VSIZE=480G           # virtual (thin) size, leave headroom for snapshots
MNT=/data/brick1

# 1. PV/VG
pvs "$DISK" >/dev/null 2>&1 || pvcreate "$DISK"
vgs "$VG"   >/dev/null 2>&1 || vgcreate "$VG" "$DISK"

# 2. Thin pool + thin LV
lvs "$VG/$POOL" >/dev/null 2>&1 || lvcreate -L "$POOL_SIZE" -T "$VG/$POOL"
lvs "$VG/$LV"   >/dev/null 2>&1 || lvcreate -V "$LV_VSIZE" -T "$VG/$POOL" -n "$LV"

# 3. XFS with 512-byte inodes (room for xattrs), no discard on the FS layer
blkid "/dev/$VG/$LV" >/dev/null 2>&1 || mkfs.xfs -f -i size=512 "/dev/$VG/$LV"

# 4. Mount with recommended flags, persist in fstab
mkdir -p "$MNT"
grep -q "$MNT" /etc/fstab || \
  echo "/dev/$VG/$LV  $MNT  xfs  rw,inode64,noatime,nodiratime,logbsize=256k  0 0" >> /etc/fstab
mountpoint -q "$MNT" || mount "$MNT"

# 5. CRITICAL: the brick is a *subdirectory*, never the mount root.
#    (Prevents accidental brick creation on the root fs if the mount is missing.)
mkdir -p "$MNT/gv0"
echo "Brick ready: $(hostname):$MNT/gv0"
```

### 3.2 Full 3-node cluster provisioning — Ansible

```yaml
# site.yml — Provision a 3-node GlusterFS trusted pool + replica-3 volume.
# Inventory groups: [gluster_nodes] gluster1 gluster2 gluster3
---
- name: GlusterFS storage cluster
  hosts: gluster_nodes
  become: true
  vars:
    gluster_version: "11"          # LTS-ish community release train
    brick_mount: /data/brick1
    brick_path: /data/brick1/gv0
    volume_name: gv0
    replica_count: 3
    # Peer probe & volume create only from the first node to keep it idempotent
    primary_node: "{{ groups['gluster_nodes'][0] }}"
  tasks:

    - name: Install GlusterFS server + xfsprogs + lvm2
      ansible.builtin.package:
        name:
          - "glusterfs-server"
          - xfsprogs
          - lvm2
        state: present

    - name: Ensure glusterd is enabled and running
      ansible.builtin.systemd:
        name: glusterd
        enabled: true
        state: started

    # --- Firewall (firewalld). Gluster ships a service definition. ---
    - name: Open GlusterFS firewalld service
      ansible.posix.firewalld:
        service: glusterfs
        permanent: true
        immediate: true
        state: enabled
      when: ansible_facts.services['firewalld.service'] is defined

    - name: Open brick port range explicitly (belt & suspenders)
      ansible.posix.firewalld:
        port: "49152-49251/tcp"
        permanent: true
        immediate: true
        state: enabled
      when: ansible_facts.services['firewalld.service'] is defined

    # --- /etc/hosts so peers resolve by name (or use real DNS) ---
    - name: Static host entries for all peers
      ansible.builtin.lineinfile:
        path: /etc/hosts
        line: "{{ hostvars[item].ansible_host | default(item) }} {{ item }}"
        state: present
      loop: "{{ groups['gluster_nodes'] }}"

    - name: Ensure brick directory exists
      ansible.builtin.file:
        path: "{{ brick_path }}"
        state: directory
        mode: "0755"

    # --- Build the trusted storage pool from the primary only ---
    - name: Probe peers into the pool
      ansible.builtin.command: "gluster peer probe {{ item }}"
      loop: "{{ groups['gluster_nodes'] }}"
      when:
        - inventory_hostname == primary_node
        - item != primary_node
      register: probe
      changed_when: "'already in peer list' not in probe.stdout"
      failed_when:
        - probe.rc != 0
        - "'already in peer list' not in probe.stdout"

    - name: Wait for all peers Connected
      ansible.builtin.command: gluster peer status
      when: inventory_hostname == primary_node
      register: peerstat
      until: peerstat.stdout.count('Peer in Cluster (Connected)') == (groups['gluster_nodes'] | length) - 1
      retries: 12
      delay: 5
      changed_when: false

    # --- Create + start the volume (idempotent guard on 'already exists') ---
    - name: Create replica-{{ replica_count }} volume
      ansible.builtin.command: >
        gluster volume create {{ volume_name }} replica {{ replica_count }}
        {% for h in groups['gluster_nodes'] %}{{ h }}:{{ brick_path }} {% endfor %}
        force
      when: inventory_hostname == primary_node
      register: vcreate
      changed_when: "'success' in vcreate.stdout"
      failed_when:
        - vcreate.rc != 0
        - "'already exists' not in vcreate.stderr"

    - name: Start the volume
      ansible.builtin.command: "gluster volume start {{ volume_name }}"
      when: inventory_hostname == primary_node
      register: vstart
      changed_when: "'success' in vstart.stdout"
      failed_when:
        - vstart.rc != 0
        - "'already started' not in vstart.stderr"

    # --- Production-hardening volume options ---
    - name: Apply recommended volume options
      ansible.builtin.command: "gluster volume set {{ volume_name }} {{ item.k }} {{ item.v }}"
      loop:
        - { k: "cluster.quorum-type",          v: "auto" }    # client-side quorum
        - { k: "cluster.server-quorum-type",   v: "server" }  # mgmt-plane quorum
        - { k: "cluster.server-quorum-ratio",  v: "51%" }
        - { k: "network.ping-timeout",         v: "20" }      # default 42s; tune with care
        - { k: "cluster.self-heal-daemon",     v: "on" }
        - { k: "cluster.data-self-heal-algorithm", v: "full" }
        - { k: "performance.client-io-threads", v: "on" }
        - { k: "features.bitrot",              v: "on" }      # scrub against silent corruption
        - { k: "features.scrub",               v: "Active" }
      when: inventory_hostname == primary_node
      changed_when: true
```

> **`network.ping-timeout` warning:** the default is **42 seconds** by design. If a brick's TCP goes silent, the client waits this long before tearing down and re-establishing connections — and reconnection is *expensive* (re-fetch volfile, re-open fds). Lowering it makes failover snappier but risks flapping bricks offline during transient load spikes, triggering unnecessary self-heals. 20s is a reasonable compromise; do not go near 1–5s in production.

### 3.3 Client mount — fstab with failover

The mount host in `gluster1:/gv0` is used **only to fetch the volfile**; it is not a data proxy. If it's down at mount time, the mount fails — so always set `backup-volfile-servers`.

```
# /etc/fstab on the client
gluster1:/gv0  /mnt/gv0  glusterfs  defaults,_netdev,backup-volfile-servers=gluster2:gluster3,fetch-attempts=3,log-level=WARNING  0  0
```

`_netdev` defers the mount until the network is up. `backup-volfile-servers` lets the client fetch the graph from gluster2/gluster3 if gluster1 is unreachable. Once mounted, the FUSE client talks to **all** bricks regardless of which server served the volfile.

### 3.4 Kubernetes — static PV against an existing Gluster volume

For a pre-existing cluster you don't need dynamic provisioning; you bind a PV directly. Note: the in-tree `glusterfs` volume plugin and Heketi-based dynamic provisioning are **deprecated/archived** — for new k8s work prefer CSI (Ceph-CSI, or `gluster-block`/`glusterfs-csi` where still maintained). Shown here because it remains exam-relevant and common in legacy estates.

```yaml
# glusterfs-endpoints.yaml — the brick server IPs the kubelet mounts against
apiVersion: v1
kind: Endpoints
metadata:
  name: glusterfs-cluster
  namespace: default
subsets:
  - addresses:
      - { ip: 10.0.0.11 }   # gluster1
      - { ip: 10.0.0.12 }   # gluster2
      - { ip: 10.0.0.13 }   # gluster3
    ports:
      - { port: 24007 }     # dummy; required by the plugin, not actually used for data
---
apiVersion: v1
kind: Service            # headless service keeps the Endpoints object alive
metadata:
  name: glusterfs-cluster
  namespace: default
spec:
  ports:
    - { port: 24007 }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-gv0
spec:
  capacity: { storage: 100Gi }
  accessModes: [ "ReadWriteMany" ]        # RWX is Gluster's whole point
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - backup-volfile-servers=gluster2:gluster3
    - log-level=WARNING
  glusterfs:
    endpoints: glusterfs-cluster
    path: gv0                              # the Gluster volume name
    readOnly: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-gv0
spec:
  accessModes: [ "ReadWriteMany" ]
  resources: { requests: { storage: 100Gi } }
  volumeName: pv-gv0
```

### 3.5 NFS-Ganesha export via libgfapi (for non-FUSE clients)

```ini
# /etc/ganesha/ganesha.conf  — export gv0 over NFSv4 using the Gluster FSAL
EXPORT {
    Export_Id = 10;
    Path = "/gv0";
    Pseudo = "/gv0";                 # NFSv4 pseudo-fs path
    Access_Type = RW;
    Squash = "No_root_squash";
    Disable_ACL = FALSE;
    Protocols = "4";
    Transports = "TCP";
    SecType = "sys";
    FSAL {
        Name = "GLUSTER";            # libgfapi — no FUSE hop on the Ganesha host
        Hostname = "localhost";
        Volume = "gv0";
    }
}
NFS_Core_Param { Enable_NLM = false; }
```

Pair Ganesha nodes with **CTDB** and a floating VIP for HA; a single Ganesha host is a proxy SPOF.

---

## 4. Real CLI walkthrough with terminal output

### 4.1 Build the trusted storage pool

```console
[root@gluster1 ~]# gluster peer probe gluster2
peer probe: success
[root@gluster1 ~]# gluster peer probe gluster3
peer probe: success

[root@gluster1 ~]# gluster peer status
Number of Peers: 2

Hostname: gluster2
Uuid: 7f3a1c9e-2b4d-4e88-9a01-2c6f1e0b7d33
State: Peer in Cluster (Connected)

Hostname: gluster3
Uuid: c1b8e4a7-9d33-4f21-8e6b-05a3f2d19c40
State: Peer in Cluster (Connected)

[root@gluster1 ~]# gluster pool list
UUID					Hostname 	State
7f3a1c9e-2b4d-4e88-9a01-2c6f1e0b7d33	gluster2 	Connected
c1b8e4a7-9d33-4f21-8e6b-05a3f2d19c40	gluster3 	Connected
d0e2a5b1-6c77-4a90-b3d2-8f11c4e6a2b9	localhost	Connected
```

> **Gotcha:** always `peer probe` by the **same name** you'll use in brick paths (all hostnames or all IPs — don't mix). The first probe is asymmetric: gluster2 will initially list gluster1 by *IP* until you `peer probe gluster1` back from gluster2, or use consistent DNS. Verify the name resolves both ways before creating volumes, or brick paths won't match the peer identity.

### 4.2 Create, start, inspect a replica-3 volume

```console
[root@gluster1 ~]# gluster volume create gv0 replica 3 \
>   gluster1:/data/brick1/gv0 \
>   gluster2:/data/brick1/gv0 \
>   gluster3:/data/brick1/gv0
volume create: gv0: success: please start the volume to access data

[root@gluster1 ~]# gluster volume start gv0
volume start: gv0: success

[root@gluster1 ~]# gluster volume info gv0

Volume Name: gv0
Type: Replicate
Volume ID: 3d9b2f14-8a6c-4e2b-b0d1-6a4c7e91f238
Status: Started
Snapshot Count: 0
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: gluster1:/data/brick1/gv0
Brick2: gluster2:/data/brick1/gv0
Brick3: gluster3:/data/brick1/gv0
Options Reconfigured:
cluster.server-quorum-type: server
cluster.quorum-type: auto
storage.fips-mode-rchecksum: on
transport.address-family: inet
nfs.disable: on
performance.client-io-threads: on
```

### 4.3 Verify runtime status — the daily-driver command

```console
[root@gluster1 ~]# gluster volume status gv0
Status of volume: gv0
Gluster process                             TCP Port  RDMA Port  Online  Pid
------------------------------------------------------------------------------
Brick gluster1:/data/brick1/gv0             49152     0          Y       2841
Brick gluster2:/data/brick1/gv0             49152     0          Y       2799
Brick gluster3:/data/brick1/gv0             49152     0          Y       2765
Self-heal Daemon on localhost               N/A       N/A        Y       2862
Self-heal Daemon on gluster2                N/A       N/A        Y       2820
Self-heal Daemon on gluster3                N/A       N/A        Y       2786

Task Status of Volume gv0
------------------------------------------------------------------------------
There are no active volume tasks
```

Every brick **Online = Y** and a **Self-heal Daemon** per replicated node is the healthy baseline. A brick showing `N` with no port is the first thing to chase in Section 5.

```console
[root@gluster1 ~]# gluster volume status gv0 detail     # capacity, inode, fs type per brick
Status of volume: gv0
------------------------------------------------------------------------------
Brick                : Brick gluster1:/data/brick1/gv0
TCP Port             : 49152
Online               : Y
Pid                  : 2841
File System          : xfs
Device               : /dev/mapper/vg_bricks-brick1
Mount Options        : rw,noatime,nodiratime,attr2,inode64,logbsize=256k,noquota
Inode Size           : 512
Disk Space Free      : 431.2GB
Total Disk Space     : 480.0GB
Inode Count          : 251658240
Free Inodes          : 251657001
...
```

### 4.4 Mount and prove replication

```console
[root@client ~]# mount -t glusterfs gluster1:/gv0 /mnt/gv0
[root@client ~]# echo "hello gluster" > /mnt/gv0/test01
[root@client ~]# ls -l /mnt/gv0
total 1
-rw-r--r-- 1 root root 14 Aug 12 14:22 test01

# The same file now exists on ALL three bricks (replica 3), verify server-side:
[root@gluster1 ~]# cat /data/brick1/gv0/test01
hello gluster
[root@gluster2 ~]# cat /data/brick1/gv0/test01
hello gluster
```

### 4.5 Inspect the AFR / DHT extended attributes (deep diagnostics)

This is where senior operators live. The `trusted.afr.*` xattrs are AFR's changelog: 3× 32-bit counters (data, metadata, entry pending ops). All zeros = clean. Non-zero on brick A pointing at brick B = "B has un-replicated writes A is missing."

```console
[root@gluster1 ~]# getfattr -d -m . -e hex /data/brick1/gv0/test01
getfattr: Removing leading '/' from absolute pathnames
# file: data/brick1/gv0/test01
trusted.afr.dirty=0x000000000000000000000000
trusted.gfid=0x9c1f4b6a7e8d4f20a1b3c5d6e7f80912
trusted.gfid2path.<hash>="00000000-0000-0000-0000-000000000001/test01"

# A directory carries the DHT hash-range layout (this is the "no metadata server" magic):
[root@gluster1 ~]# getfattr -d -m . -e hex /data/brick1/gv0
# file: data/brick1/gv0
trusted.glusterfs.dht=0x000000010000000000000000ffffffff   # this subvol owns hash 0x0..0xffffffff
trusted.glusterfs.volume-id=0x3d9b2f148a6c4e2bb0d16a4c7e91f238
```

### 4.6 Expand the volume and rebalance

```console
# Grow from 3 to 6 bricks (must add a full replica set: replica 3 → add 3 bricks)
[root@gluster1 ~]# gluster volume add-brick gv0 \
>   gluster4:/data/brick1/gv0 gluster5:/data/brick1/gv0 gluster6:/data/brick1/gv0
volume add-brick: success

[root@gluster1 ~]# gluster volume info gv0 | grep 'Number of Bricks'
Number of Bricks: 2 x 3 = 6          # now Distributed-Replicate

# Existing files still hash to the old layout — rebalance to spread them:
[root@gluster1 ~]# gluster volume rebalance gv0 start
volume rebalance: gv0: success: Rebalance on gv0 has been started successfully...
Rebalance ID: a7c3e1f0-4b52-49d8-9c1a-6e2f3d80b514

[root@gluster1 ~]# gluster volume rebalance gv0 status
                                    Node Rebalanced-files  size  scanned failures skipped status  run time
                               ---------  ---------------  ----  ------- -------- ------- ------  --------
                               localhost              128 512MB     4096        0       3 completed  00:01:12
                                gluster2               96 384MB     4096        0       1 completed  00:01:09
                                gluster4              140 560MB     4096        0       0 completed  00:01:15
volume rebalance: gv0: success
```

Rebalance runs in two phases: **fix-layout** (recompute DHT hash ranges to include the new bricks — cheap) and **migrate-data** (physically move files whose hash now maps elsewhere — expensive I/O). You can `fix-layout start` alone if you only want new files spread and can't afford the data-move I/O yet.

### 4.7 Snapshots (LVM-thin backed)

```console
[root@gluster1 ~]# gluster snapshot create snap-2026-08-12 gv0 no-timestamp
snapshot create: success: Snap snap-2026-08-12 created successfully

[root@gluster1 ~]# gluster snapshot list
snap-2026-08-12

[root@gluster1 ~]# gluster snapshot info snap-2026-08-12
Snapshot                  : snap-2026-08-12
Snap UUID                 : e5a1...
Created                   : 2026-08-12 14:40:03
Snap Volumes:
	Snap Volume Name          : b12c...
	Origin Volume name        : gv0
	Snaps taken for gv0       : 1
	Snaps available for gv0   : 255
	Status                    : Stopped

# Activate to browse it, or restore (volume must be STOPPED to restore):
[root@gluster1 ~]# gluster snapshot activate snap-2026-08-12
Snapshot activate: snap-2026-08-12: Snap activated successfully
[root@gluster1 ~]# gluster volume stop gv0
[root@gluster1 ~]# gluster snapshot restore snap-2026-08-12
Restore operation successful
```

### 4.8 Geo-replication (async DR to a remote site, over SSH)

```console
# One-time: push the primary's pubkey to the secondary and set up the session
[root@gluster1 ~]# gluster volume geo-replication gv0 \
>   drsite1::gv0-dr create push-pem
Creating geo-replication session between gv0 & drsite1::gv0-dr has been successful

[root@gluster1 ~]# gluster volume geo-replication gv0 drsite1::gv0-dr start
Starting geo-replication session between gv0 & drsite1::gv0-dr has been successful

[root@gluster1 ~]# gluster volume geo-replication gv0 drsite1::gv0-dr status

MASTER NODE   MASTER VOL   MASTER BRICK          SLAVE USER  SLAVE           SLAVE NODE  STATUS     CRAWL STATUS       LAST_SYNCED
---------------------------------------------------------------------------------------------------------------------------------
gluster1      gv0          /data/brick1/gv0      root        drsite1::gv0-dr drsite1     Active     Changelog Crawl    2026-08-12 14:52:10
gluster2      gv0          /data/brick1/gv0      root        drsite1::gv0-dr drsite2     Passive    N/A                N/A
```

`Active`/`Passive` reflects which replica brick per set is doing the sync (the other stands by). `Changelog Crawl` (incremental, journal-driven) is the steady state; `Hybrid/History Crawl` appears during initial sync or after a long gap.

---

## 5. Verification and failure diagnosis

### 5.1 The health ladder — run top to bottom

```console
gluster peer status                 # pool intact? all "Peer in Cluster (Connected)"
gluster volume status gv0           # every brick Online=Y with a TCP port? shd running?
gluster volume heal gv0 info        # any entries pending heal? (should be 0)
gluster volume heal gv0 info split-brain   # any files unresolvable? (MUST be 0)
gluster volume status gv0 detail    # capacity + inode headroom per brick
```

### 5.2 Split-brain — detect, inspect, resolve

Split-brain is the failure that data-loses you if you guess wrong. Detection:

```console
[root@gluster1 ~]# gluster volume heal gv0 info split-brain
Brick gluster1:/data/brick1/gv0
/reports/q3.db
Status: Connected
Number of entries in split-brain: 1

Brick gluster2:/data/brick1/gv0
/reports/q3.db
Status: Connected
Number of entries in split-brain: 1
```

Diagnose which copy is authoritative by reading AFR xattrs on each brick. The counters are `trusted.afr.<volume>-client-<N>` = 24 hex chars = **[data(8)][metadata(8)][entry(8)]**. A brick that "blames" another (non-zero counter pointing at that peer's client index) with the peer blaming *back* is the split-brain signature:

```console
[root@gluster1 ~]# getfattr -d -m . -e hex /data/brick1/gv0/reports/q3.db
trusted.afr.gv0-client-1=0x000000050000000000000000   # brick0 says brick1 is 5 data-ops behind
[root@gluster2 ~]# getfattr -d -m . -e hex /data/brick1/gv0/reports/q3.db
trusted.afr.gv0-client-0=0x000000030000000000000000   # brick1 says brick0 is 3 data-ops behind
# Each blames the other → classic data split-brain.
```

Resolve with an explicit policy (never let self-heal guess):

```console
# Option A: pick a specific brick as the source of truth
[root@gluster1 ~]# gluster volume heal gv0 split-brain source-brick \
>   gluster1:/data/brick1/gv0 /reports/q3.db
Healed /reports/q3.db

# Option B: heuristic — keep the copy with the latest mtime
[root@gluster1 ~]# gluster volume heal gv0 split-brain latest-mtime /reports/q3.db

# Option C: keep the largest file
[root@gluster1 ~]# gluster volume heal gv0 split-brain bigger-file /reports/q3.db
```

**Prevention beats cure:** run `replica 3` or `replica 3 arbiter 1` with `cluster.quorum-type auto` + server-side quorum. Split-brain is essentially impossible under a working majority quorum because the minority side refuses writes.

### 5.3 A brick won't come Online

```console
[root@gluster1 ~]# gluster volume status gv0
Brick gluster2:/data/brick1/gv0             N/A       N/A        N       N/A   ← dead
```

Triage order:

1. **Is the backing mount present?** The #1 cause. If `/data/brick1` isn't mounted, `glusterfsd` refuses to start on an empty/wrong dir (the `volume-id` xattr check fails — a deliberate guard against writing into the root fs).
   ```console
   [root@gluster2 ~]# mountpoint /data/brick1 || echo "BRICK FS NOT MOUNTED"
   [root@gluster2 ~]# getfattr -n trusted.glusterfs.volume-id -e hex /data/brick1/gv0
   ```
2. **Read the brick log** — the authoritative error:
   ```console
   [root@gluster2 ~]# tail -n 40 /var/log/glusterfs/bricks/data-brick1-gv0.log
   ... [posix.c] ... Extended attribute trusted.glusterfs.volume-id is absent
   ... [glusterfsd-mgmt.c] ... failed to initialize brick, exiting
   ```
3. **Force-restart the brick processes** (safe; re-reads volfile, re-spawns `glusterfsd`):
   ```console
   [root@gluster2 ~]# gluster volume start gv0 force
   volume start: gv0: success
   ```
4. **Port/firewall:** confirm the brick can bind and peers can reach 24007 + 49152+.
   ```console
   [root@gluster2 ~]# ss -tlnp | grep -E '24007|4915'
   LISTEN 0  1024  0.0.0.0:24007  ...  users:(("glusterd",pid=1201,...))
   LISTEN 0  1024  0.0.0.0:49152  ...  users:(("glusterfsd",pid=2799,...))
   ```

### 5.4 "Peer Rejected" — config divergence

```console
[root@gluster1 ~]# gluster peer status
Hostname: gluster2
State: Peer Rejected (Connected)
```

Cause: the volume config checksum (`cksum` in `/var/lib/glusterd/vols/<vol>/info`) diverged between nodes — usually after a botched manual edit or a version mismatch. Recovery on the **rejected** node:

```console
[root@gluster2 ~]# systemctl stop glusterd
[root@gluster2 ~]# cp /var/lib/glusterd/glusterd.info /root/glusterd.info.bak   # keep this node's UUID
# wipe everything EXCEPT glusterd.info and the peers/ dir, then let it resync from a good peer:
[root@gluster2 ~]# find /var/lib/glusterd -mindepth 1 -maxdepth 1 \
>   ! -name glusterd.info ! -name peers -exec rm -rf {} +
[root@gluster2 ~]# systemctl start glusterd
[root@gluster1 ~]# gluster peer probe gluster2      # re-probe from a healthy node to trigger sync
[root@gluster2 ~]# systemctl restart glusterd
[root@gluster1 ~]# gluster peer status              # should now read "Peer in Cluster (Connected)"
```

### 5.5 Monitor and force self-heal

```console
[root@gluster1 ~]# gluster volume heal gv0 info summary
Brick gluster1:/data/brick1/gv0
Status: Connected
Total Number of entries: 12
Number of entries in heal pending: 12
Number of entries in split-brain: 0
Number of entries possibly healing: 0
...
[root@gluster1 ~]# gluster volume heal gv0 full     # kick a full crawl (expensive)
Launching heal operation to perform full self heal ... has been successful
[root@gluster1 ~]# gluster volume heal gv0 statistics heal-count
Gathering count of entries to be healed on volume gv0 has been successful
Brick gluster1:/data/brick1/gv0   Number of entries: 0
```

### 5.6 Performance diagnosis — profile, top, statedump

```console
# Enable server-side profiling, generate load, then read per-FOP latency
[root@gluster1 ~]# gluster volume profile gv0 start
[root@gluster1 ~]# gluster volume profile gv0 info
Brick: gluster1:/data/brick1/gv0
      Block Size:         4096b+          65536b+
 No. of Reads:            1024             204
No. of Writes:            8192             512
     %-latency   Avg-latency   Min   Max   No. of calls   Fop
     ---------   -----------   ---   ---   ------------   ----
        41.20      120.44 us   22    980         8704    WRITE
        18.75       88.10 us   15    420         1228    LOOKUP
        ...

# Hot files/dirs and open-fd counts
[root@gluster1 ~]# gluster volume top gv0 write list-cnt 10
[root@gluster1 ~]# gluster volume top gv0 open

# Deep memory/lock/fd dump (writes to /var/run/gluster/), for stuck-I/O or leak analysis
[root@gluster1 ~]# gluster volume statedump gv0
```

**Where to look when it's slow:**

| Symptom | Likely cause | Lever |
|---|---|---|
| Small-file / `ls -R` crawl slow | DHT lookup fans out to every brick | `cluster.lookup-optimize on`, `performance.readdir-ahead on`, `cluster.readdir-optimize on`, md-cache tuning |
| VM image / large-file heal takes hours | Whole-file heal granularity | `features.shard on` + `features.shard-block-size 64MB` (heal per-shard) |
| Write throughput = 1/N of link | FUSE client replicates to all bricks over one NIC | Bond/25GbE, or offload to libgfapi/Ganesha; consider EC for capacity |
| Bricks flap offline under load | `network.ping-timeout` too low | raise toward default 42s |
| Silent corruption suspected | No scrubbing | `features.bitrot on`, `features.scrub Active`, check `gluster volume bitrot gv0 scrub status` |

### 5.7 Log map (memorize the paths)

| Log | Path |
|---|---|
| Management daemon | `/var/log/glusterfs/glusterd.log` |
| Per-brick | `/var/log/glusterfs/bricks/<brick-path-with-dashes>.log` |
| Self-heal daemon | `/var/log/glusterfs/glustershd.log` |
| FUSE client mount | `/var/log/glusterfs/<mount-point-with-dashes>.log` |
| Rebalance | `/var/log/glusterfs/<vol>-rebalance.log` |
| Geo-replication | `/var/log/glusterfs/geo-replication/<vol>/*.log` |
| CLI history | `/var/log/glusterfs/cli.log` |

---

## 6. References

- LPI Exam 306-300 Objectives (v3.0), Topic 363.1 — https://www.lpi.org/our-certifications/exam-306-objectives/
- GlusterFS Documentation — Architecture — https://docs.gluster.org/en/latest/Administrator-Guide/Architecture/
- GlusterFS Administrator Guide — Setting Up Volumes — https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/
- GlusterFS Administrator Guide — Managing Volumes (expand/shrink/rebalance) — https://docs.gluster.org/en/latest/Administrator-Guide/Managing-Volumes/
- GlusterFS Administrator Guide — Arbiter volumes and quorum — https://docs.gluster.org/en/latest/Administrator-Guide/arbiter-volumes-and-quorum/
- GlusterFS Administrator Guide — Split-brain and self-heal (`heal ... split-brain`) — https://docs.gluster.org/en/latest/Administrator-Guide/Split-brain-and-ways-to-deal-with-it/
- GlusterFS Administrator Guide — Managing Snapshots — https://docs.gluster.org/en/latest/Administrator-Guide/Managing-Snapshots/
- GlusterFS Administrator Guide — Geo Replication — https://docs.gluster.org/en/latest/Administrator-Guide/Geo-Replication/
- GlusterFS Administrator Guide — Directory Quota — https://docs.gluster.org/en/latest/Administrator-Guide/Directory-Quota/
- GlusterFS Administrator Guide — Erasure-coded (dispersed) volumes — https://docs.gluster.org/en/latest/Administrator-Guide/Setting-Up-Volumes/#creating-dispersed-volumes
- GlusterFS Developer Guide — Translators — https://docs.gluster.org/en/latest/Developer-guide/Translator-development/
- GlusterFS — Network configuration & firewall ports — https://docs.gluster.org/en/latest/Install-Guide/Configure/
- libgfapi — https://docs.gluster.org/en/latest/Developer-guide/gfapi-symbol-versions/
- NFS-Ganesha with GlusterFS (FSAL_GLUSTER) — https://docs.gluster.org/en/latest/Administrator-Guide/NFS-Ganesha-GlusterFS-Integration/
- Bitrot detection — https://docs.gluster.org/en/latest/Administrator-Guide/Bitrot-Detection/
- Kubernetes — GlusterFS in-tree volume (deprecated) — https://kubernetes.io/docs/concepts/storage/volumes/#glusterfs
- `mount.glusterfs(8)` / `gluster(8)` man pages — https://docs.gluster.org/en/latest/manpages/

---

*Note: this session has no filesystem-write tools loaded, so the material is delivered inline above rather than written to `certs/lpic-3-306/363.1/en/`. Say the word and I can restructure it into the repo's `content.md` / `exercises.md` / `meta.yaml` layout if you re-enable file access, or I can proceed to the exercises and lab break-fix scenarios for this topic.*