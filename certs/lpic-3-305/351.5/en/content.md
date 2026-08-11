# 351.5 Virtual Machine Disk Image Management

**LPIC-3 Virtualization and Containerization — Exam 305-300 (v3.0)**
**Topic 351: Full Virtualization · Objective 351.5 · Weight: 5**

> **Scope (per LPI objectives).** Create, copy, convert and manipulate virtual machine disk images; understand `qcow2` features (copy-on-write, internal/external snapshots, backing files); relate disk images to volume-based storage; access data inside images with loop devices, `kpartx`, network block devices and `libguestfs`; awareness of `raw` and `qed`. Utilities in scope: `qemu-img`, `qemu-nbd`, `kpartx`, `losetup`, `guestfish`, `guestmount`, `virt-cat`, `virt-copy-in`, `virt-copy-out`, `virt-diff`, `virt-df`, `virt-filesystems`, `virt-inspector`, `virt-ls`, `virt-rescue`, `virt-sparsify`.

---

## 1. The production problem: a disk image is a storage subsystem, not a file

An SRE inherits a fleet where "the VM disk" is treated as an opaque blob. That framing breaks in production the first time any of these happen:

- A golden image is cloned to 400 VMs and each clone appears to consume 20 GiB, so the platform is provisioned for **8 TiB** of storage that, in practice, holds ~120 GiB of *actual* divergent data. Someone sized the LUN wrong by a factor of 60.
- A "quick snapshot before the upgrade" is taken on a hypervisor with `qcow2` internal snapshots. Three months and 40 snapshots later, I/O latency on that guest is 10× baseline and nobody knows why.
- A backup job `cp`s a live `qcow2` file that has an in-memory metadata cache not yet flushed. The restore is silently corrupt; `qemu-img check` on the copy reports leaked clusters and an `l2` table pointing into a refcount block.
- A base image is `mv` d to a new datastore. Every overlay that referenced it by **absolute path** fails to boot with `Could not open backing file: No such file or directory`.

A disk image format is a **guest-block-address → host-storage-address translation layer** with its own allocator, its own metadata (reference counts, allocation tables), its own consistency model, and its own failure modes. Managing it competently means understanding that translation layer the way you'd understand a filesystem's on-disk format — because that is exactly what `qcow2` is: a log-structured-ish, copy-on-write, sparse container with a two-level page-table lookup.

The architectural axis this objective forces you to reason about:

| Concern | File-based image (`qcow2`/`raw` on a filesystem) | Volume-based (LVM LV, Ceph RBD, ZFS zvol, iSCSI LUN) |
|---|---|---|
| Format on media | Structured (`qcow2`) or `raw` | Almost always `raw` — the volume *is* the block device |
| Sparse/thin provisioning | `qcow2` native; `raw` via filesystem holes | Storage-layer thin pool (LVM-thin, RBD, ZFS) |
| Snapshots | In `qcow2` (internal) or overlay files (external) | Storage-native (LVM-thin snapshot, `rbd snap`, `zfs snapshot`) |
| Copy-on-write | `qcow2` refcount-driven COW; backing files | Storage-native COW |
| Portability | High — a file you can `scp`/`convert` | Low — tied to the storage system |
| Performance ceiling | Extra indirection (L2 lookup, host FS) | Near-bare-metal; no format overhead |
| Overcommit blast radius | Host filesystem full → *all* guests ENOSPC | Thin pool full → guests on that pool fail |

The rest of this material treats the image as the storage subsystem it is.

---

## 2. `qcow2` internals — the format you must be able to reason about

### 2.1 On-disk anatomy

`qcow2` ("QEMU Copy-On-Write v2", with the v3 feature set living inside a v2 container under `compat=1.1`) maps a **guest logical block address** to a **host file offset** through a two-level table, exactly like a CPU page table:

```
guest offset ─┬─ L1 index ──► L1 table ──► L2 table offset
              ├─ L2 index ──► L2 table ──► host cluster offset
              └─ intra-cluster offset ─────────────────────────► byte in cluster
```

- **Cluster** — the allocation unit (default 64 KiB, `cluster_bits = 16`). Everything is allocated in whole clusters: data, L2 tables, refcount blocks.
- **L1 table** — small, kept in memory, points to L2 tables.
- **L2 tables** — one L2 entry per guest cluster; the entry holds the host offset (or 0 = unallocated → read as zeros, or falls through to the backing file).
- **Refcount table + refcount blocks** — how many times each host cluster is referenced. **This is the mechanism that makes COW and internal snapshots possible.** A cluster with `refcount > 1` is shared; writing to it triggers allocate-copy-and-decrement.
- **Header** — magic `QFI\xfb`, version, `cluster_bits`, `size`, `l1_table_offset`, `refcount_table_offset`, `backing_file_offset`, `nb_snapshots`, `snapshots_offset`, and (v3) header extensions and feature bit fields (`incompatible/compatible/autoclear`).

The consequence you must internalize: **a `qcow2` file's byte layout is not the guest's byte layout.** You cannot `grep` a guest's `/etc/hostname` out of the raw `qcow2` bytes at a predictable offset, and you cannot safely `dd` a region of it. Every access has to go through the translation layer — which is why `libguestfs`, `qemu-nbd` and `guestmount` exist.

### 2.2 The knobs that decide production behavior

| Option (`-o`) | Values | What it changes | Production guidance |
|---|---|---|---|
| `compat` | `0.10` / `1.1` | Feature set. `1.1` = zero-cluster support, lazy refcounts, zstd, LUKS, persistent bitmaps | Always `1.1` unless a museum-grade hypervisor needs `0.10` |
| `cluster_size` | 512 B – 2 MiB (default 64 KiB) | Allocation granularity; L2 table size | Small clusters → less COW waste, more metadata & smaller L2 reach. Large clusters → fewer allocations, worse COW amplification |
| `preallocation` | `off`/`metadata`/`falloc`/`full` | How much host space is reserved up front | See §2.3 |
| `lazy_refcounts` | on/off | Defer refcount updates → fewer writes, faster; needs `qemu-img check` after crash | On for perf, off if you can't tolerate post-crash repair |
| `extended_l2` | on/off | Subcluster allocation (32 subclusters/cluster) → COW at finer granularity | Reduces COW write amplification on 64 KiB clusters dramatically |
| `compression_type` | `zlib`/`zstd` | Codec for compressed clusters (`convert -c`) | `zstd` — faster and better ratio; requires `compat=1.1` |
| `encrypt.format` | `luks` | Full-image LUKS encryption inside the container | The only supported encryption; the old `aes` is broken, do not use |
| `refcount_bits` | 1–64 (default 16) | Max simultaneous references to a cluster | 16 is fine; lower only to shave metadata on huge images |

### 2.3 Preallocation — the single most misconfigured knob

```
off       → allocate nothing but the essential header; fully thin. Slowest steady-state
             (metadata clusters allocated on demand, causing fragmentation).
metadata  → allocate ALL L1/L2/refcount metadata now; data stays sparse. File shows full
             virtual size in `ls -l` but is sparse on disk. Avoids runtime metadata churn.
falloc    → posix_fallocate(): reserve host blocks without writing them. Fast, guarantees
             space (no surprise ENOSPC mid-flight), image is no longer sparse.
full      → write zeros over the whole image. Slow, guarantees space AND contiguity.
```

The trap: `preallocation=metadata` makes `ls -l` report 20 GiB while `du` reports 4 MiB. Monitoring that alerts on apparent (`ls`) size will page you at 3 a.m. for a disk that is 0.02% full. Monitoring must read **allocated** blocks (`du`, `stat -c %b`, `qemu-img info` "disk size").

### 2.4 Backing files & the copy-on-write chain

An **overlay** is a `qcow2` whose *unallocated* clusters fall through to a **backing file**. Reads hit the overlay first; on a miss they read the backing image. Writes always land in the overlay (COW). This is how you get 400 near-free clones of one golden image:

```
base-fedora40.qcow2  (read-only, 1.8 GiB actual)
   ▲            ▲            ▲
   │            │            │
web-01.qcow2  web-02.qcow2  db-01.qcow2   ← overlays, ~40–800 MiB each of divergence
```

Two facts that cause outages:

1. **The backing path is stored inside the overlay** (relative or absolute). Move/rename the base and every overlay breaks. Fix the pointer with `qemu-img rebase -u` — never by editing bytes.
2. **A base must never be written to while overlays reference it.** One byte changed in the base corrupts the guest-visible content of *every* overlay, because their unallocated regions now read different data than they were built on. Keep bases read-only (`chmod 0444`, or immutable via storage policy).

---

## 3. `qemu-img` — the primary tool, subcommand by subcommand

### 3.1 Create

```console
$ qemu-img create -f qcow2 -o cluster_size=64k,compat=1.1,lazy_refcounts=on base.qcow2 20G
Formatting 'base.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 lazy_refcounts=on refcount_bits=16

$ qemu-img create -f qcow2 -o preallocation=falloc,extended_l2=on data.qcow2 100G
Formatting 'data.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=on preallocation=falloc compression_type=zlib size=107374182400 lazy_refcounts=off refcount_bits=16
```

Create an **overlay** on a backing image (note: pin the backing format explicitly — format probing on backing files is a known attack/footgun surface):

```console
$ qemu-img create -f qcow2 -b base.qcow2 -F qcow2 web-01.qcow2
Formatting 'web-01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 backing_file=base.qcow2 backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
```

### 3.2 Info — read the translation layer's state

```console
$ qemu-img info web-01.qcow2
image: web-01.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 912 KiB
cluster_size: 65536
backing file: base.qcow2
backing file format: qcow2
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
Child node '/file':
    filename: web-01.qcow2
    protocol type: file
    file length: 960 KiB (983040 bytes)
    disk size: 912 KiB
```

Walk the whole chain and emit machine-readable JSON for automation:

```console
$ qemu-img info --backing-chain --output=json web-01.qcow2 | jq -r '.[] | "\(.filename)  virt=\(.["virtual-size"])  actual=\(.["actual-size"])  backing=\(.["backing-filename"] // "-")"'
web-01.qcow2  virt=21474836480  actual=933888  backing=base.qcow2
base.qcow2    virt=21474836480  actual=1932787712  backing=-
```

`corrupt: true` in that output is a **stop-the-line** signal — the image has an inconsistency the driver detected; do not boot it, run `qemu-img check` (§5).

### 3.3 Convert — format changes, flattening, compression, sparsification

`convert` reads the source through its format driver and writes the destination through the target driver. It **flattens backing chains** (the output is standalone unless you ask otherwise), skips zero/unallocated clusters (`-S` controls sparse-hole granularity), and is your safe copy primitive.

```console
# qcow2 (with a backing chain) → a single standalone, compressed qcow2 for archival
$ qemu-img convert -p -O qcow2 -c -o compression_type=zstd web-01.qcow2 web-01-archive.qcow2
    (100.00/100%)

# qcow2 → raw for a volume-based datastore (LVM/RBD want raw)
$ qemu-img convert -p -f qcow2 -O raw base.qcow2 /dev/vg_fast/lv_web01
    (100.00/100%)

# Import a cloud vendor image (VMware) → qcow2
$ qemu-img convert -p -O qcow2 appliance.vmdk appliance.qcow2
    (100.00/100%)

# Multithreaded, using host block-level copy offload where available
$ qemu-img convert -p -m 8 -W -O qcow2 src.qcow2 dst.qcow2
    (100.00/100%)
```

Format support matrix you must recall:

| Format | Read | Write | Snapshots | Backing chain | Notes / origin |
|---|---|---|---|---|---|
| `qcow2` | ✅ | ✅ | ✅ internal + external | ✅ | QEMU native; the default for file-based |
| `raw` | ✅ | ✅ | ❌ (use storage layer) | ❌ | Fastest; no metadata; sparse only via FS holes |
| `qed` | ✅ | ✅ | ❌ | ✅ | Deprecated QEMU COW format — **awareness only** |
| `vmdk` | ✅ | ✅ | limited | ✅ | VMware; many sub-variants (`subformat=`) |
| `vdi` | ✅ | ✅ | ❌ | ❌ | VirtualBox |
| `vhdx` | ✅ | ✅ | ❌ | ❌ | Hyper-V (modern); `vpc` = legacy VHD |
| `luks` | ✅ | ✅ | — | — | Raw LUKS container as an image format |

### 3.4 Snapshots — internal (in-file) vs external (overlay)

**Internal** snapshots live inside a single `qcow2` and are driven by the refcount machinery:

```console
$ qemu-img snapshot -c pre-upgrade base.qcow2          # create
$ qemu-img snapshot -l base.qcow2                       # list
Snapshot list:
ID        TAG                 VM_SIZE                DATE       VM_CLOCK     ICOUNT
1         pre-upgrade             0 B  2026-08-11 09:14:22  0000:00:00.000        0
$ qemu-img snapshot -a pre-upgrade base.qcow2           # apply/revert
$ qemu-img snapshot -d pre-upgrade base.qcow2           # delete
```

**External** snapshots create a fresh overlay and make the *previous* file the backing image — the live, low-latency path used by `virsh`/`libvirt` for online snapshots:

```console
$ qemu-img create -f qcow2 -b base.qcow2 -F qcow2 base.snap1.qcow2
# writes now go to base.snap1.qcow2; base.qcow2 becomes the read-only backing point-in-time.
```

The trade-off that shows up in real incidents:

| Aspect | Internal snapshot | External snapshot (overlay) |
|---|---|---|
| Storage layout | Single file | New file per snapshot (a chain) |
| Live VM state (RAM) | Can be embedded (`VM_SIZE`) | Disk-only unless RAM saved separately |
| Read amplification | Bounded, in one file | **Grows with chain depth** — every unallocated read walks the chain |
| Delete cost | Refcount update + cluster free (can be slow/fragmenting) | `block-commit`/`block-stream` merge |
| Portability | One file to move | Must move the whole chain, paths intact |
| Live-snapshot support | Weaker | The libvirt default for online snapshots |
| Failure blast radius | Corruption risks the whole image + all snapshots | A broken leaf loses only post-snapshot writes |

**Rule of thumb:** external snapshots for operational, time-bounded checkpoints (backup, upgrade windows) that you *commit or discard promptly*; never let a chain grow unbounded. Internal snapshots for portable, self-contained "labeled states" of an offline image.

### 3.5 Commit & rebase — collapsing and re-parenting chains

`commit` merges an overlay **down** into its backing file, then the overlay is empty:

```console
$ qemu-img commit -p web-01.qcow2
    (100.00/100%)
Image committed.
```

`rebase` changes an image's backing file. **Safe mode** (default) reads through both old and new chains and copies whatever is needed so guest-visible data is unchanged. **Unsafe mode** (`-u`) only rewrites the backing pointer — use it *only* when you moved/renamed a backing file and the data is byte-identical:

```console
# The base moved to /images/golden/. Fix the pointer without touching data:
$ qemu-img rebase -u -b /images/golden/base.qcow2 -F qcow2 web-01.qcow2

# Re-parent onto a different (but content-compatible) base, copying deltas safely:
$ qemu-img rebase -b new-base.qcow2 -F qcow2 web-01.qcow2

# Flatten to standalone (no backing file at all):
$ qemu-img rebase -b "" web-01.qcow2
```

### 3.6 Resize — and the guest-side other half

`qemu-img resize` only changes the *container's* declared size. The **partition table, LVM PV, and filesystem inside the guest do not move** — that is a separate, guest-side operation.

```console
$ qemu-img resize base.qcow2 +20G
Image resized.

# Shrink is dangerous and must be forced AND preceded by an in-guest FS shrink:
$ qemu-img resize --shrink base.qcow2 15G
Image resized.
```

Full grow procedure (offline, via `libguestfs` — see §6):

```console
$ qemu-img resize disk.qcow2 +20G
$ virt-filesystems --long --parts --blkdevs -a disk.qcow2
# then grow partition + PV + LV + FS inside, e.g. with virt-resize into a new image:
$ qemu-img create -f qcow2 disk-new.qcow2 40G
$ virt-resize --expand /dev/sda2 disk.qcow2 disk-new.qcow2
```

### 3.7 The diagnostic and accounting subcommands

```console
# Allocation map — exactly which guest ranges are allocated, zero, or in the backing file
$ qemu-img map --output=json web-01.qcow2 | jq -c '.[0:3][]'
{"start":0,"length":1048576,"depth":1,"present":true,"zero":false,"data":true,"offset":327680}
{"start":1048576,"length":65536,"depth":0,"present":true,"zero":false,"data":true,"offset":983040}
{"start":1114112,"length":21473722368,"depth":0,"present":false,"zero":true,"data":false}

# Measure the host space a conversion will actually need BEFORE you run it
$ qemu-img measure -O qcow2 base.qcow2
required size: 1969225728
fully allocated size: 21476933632

# Byte-compare two images (are these two clones actually identical?)
$ qemu-img compare base.qcow2 base-restored.qcow2
Images are identical.

# Change format options in place (e.g. upgrade compat 0.10 → 1.1)
$ qemu-img amend -o compat=1.1 legacy.qcow2

# Persistent dirty bitmaps for incremental backup (compat=1.1)
$ qemu-img bitmap --add --enable backup0 base.qcow2
```

---

## 4. Complete production manifests

### 4.1 libvirt domain — `qcow2` overlay, discard/TRIM, threaded I/O, blockdev

libvirt describes VM storage in XML (this is the authoritative, production representation of "how a VM uses a disk image"). Full, unabridged disk stanza:

```xml
<domain type='kvm'>
  <name>web-01</name>
  <memory unit='GiB'>4</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <!-- Overlay on a shared read-only golden image, thin + TRIM-capable -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'
              cache='none' io='native' discard='unmap' detect_zeroes='unmap'
              queues='4'/>
      <source file='/var/lib/libvirt/images/web-01.qcow2'>
        <backingStore type='file'>
          <format type='qcow2'/>
          <source file='/var/lib/libvirt/images/golden/base-fedora40.qcow2'/>
          <backingStore/>
        </backingStore>
      </source>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>

    <!-- A second, volume-based data disk living directly on an LVM LV as raw -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='/dev/vg_fast/lv_web01_data'/>
      <target dev='vdb' bus='virtio'/>
    </disk>

    <controller type='scsi' model='virtio-scsi'/>
    <memballoon model='virtio'/>
  </devices>
</domain>
```

Why these attributes matter in production:

| Attribute | Value | Effect |
|---|---|---|
| `cache` | `none` | Bypass host page cache → correct crash consistency, avoids double-caching |
| `io` | `native` | Linux AIO; lower latency than the default threadpool for O_DIRECT |
| `discard` | `unmap` | Guest `fstrim` propagates to `qemu-img` → clusters are freed, image re-thins |
| `detect_zeroes` | `unmap` | Zero writes become deallocations instead of stored zero clusters |
| `<backingStore>` | explicit | Pin the backing format so QEMU never *probes* format (security) |

### 4.2 Online external snapshot + block-commit, via `virsh`

```console
# Take a disk-only external snapshot of a running guest (no downtime)
$ virsh snapshot-create-as --domain web-01 \
      --name backup-2026-08-11 --no-metadata \
      --disk-only --atomic \
      --diskspec vda,snapshot=external,file=/var/lib/libvirt/images/web-01.backup.qcow2
Domain snapshot backup-2026-08-11 created

# ... back up the now-frozen backing file safely while the guest writes to the overlay ...
$ qemu-img convert -O qcow2 -c -o compression_type=zstd \
      /var/lib/libvirt/images/web-01.qcow2 /backup/web-01-2026-08-11.qcow2

# Live-merge the overlay back down and pivot the guest onto the base (no downtime)
$ virsh blockcommit web-01 vda --active --pivot --verbose
Block commit: [100 %]
Successfully pivoted
```

### 4.3 KubeVirt / CDI DataVolume — image management in a cluster

In Kubernetes with KubeVirt, disk-image lifecycle is declarative. CDI (Containerized Data Importer) **imports and converts** a `qcow2` into a PVC, auto-converting to `raw` on `Block` volumes:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora40-golden
  namespace: vm-workloads
spec:
  source:
    http:
      url: "https://mirror.internal/images/Fedora-Cloud-Base-40.qcow2"
      # CDI verifies the checksum and converts qcow2 → the storage's native format
  storage:
    accessModes: ["ReadWriteMany"]
    volumeMode: Block          # → CDI writes a raw image directly to the block device
    resources:
      requests:
        storage: 20Gi
    storageClassName: ceph-rbd
---
# A per-VM thin clone of the golden PVC (COW at the storage layer, not qcow2)
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: web-01-rootdisk
  namespace: vm-workloads
spec:
  source:
    pvc:
      name: fedora40-golden
      namespace: vm-workloads
  storage:
    accessModes: ["ReadWriteOnce"]
    volumeMode: Block
    resources:
      requests:
        storage: 20Gi
    storageClassName: ceph-rbd     # smart-clone → rbd snapshot+clone, near-instant
```

This is the production face of "disk images relate to volume-based storage": in-cluster, the `qcow2`'s COW/backing-chain features are **replaced** by the storage layer's native snapshot/clone (Ceph RBD here). CDI's job is the *conversion* at the boundary.

---

## 5. Verification and failure diagnosis

### 5.1 Consistency check and repair

`qemu-img check` validates the refcount tables and L1/L2 consistency — the on-disk equivalent of `fsck`:

```console
$ qemu-img check base.qcow2
No errors were found on the image.
Image end offset: 1969881088

# A corrupted / leaked-cluster image:
$ qemu-img check dirty.qcow2
Leaked cluster 5348 refcount=1 reference=0
Leaked cluster 5349 refcount=1 reference=0
2 leaked clusters were found on the image.
This means waste of disk space, but no harm to data.

# Repair leaks (safe) and, if needed, all errors (aggressive):
$ qemu-img check -r leaks dirty.qcow2
$ qemu-img check -r all   dirty.qcow2
```

Decision guide:

| `qemu-img check` says | Meaning | Action |
|---|---|---|
| `No errors were found` | Clean | Proceed |
| `N leaked clusters ... no harm to data` | Allocated-but-unreferenced clusters (often after a crash with `lazy_refcounts`) | `check -r leaks`; investigate why (unclean shutdown) |
| `ERROR ... refcount ... reference` | Structural inconsistency | Copy the file first, then `check -r all`; if the guest is up, snapshot data out with `libguestfs` before touching it |
| `corrupt: true` in `info` | Driver flagged the image at runtime | **Do not boot.** `check`, then restore from backup if repair fails |

### 5.2 The sparse / apparent-size discrepancy — how to read it correctly

```console
$ ls -lh base.qcow2
-rw-r--r--. 1 qemu qemu 21G Aug 11 09:20 base.qcow2      # APPARENT (virtual) size — misleading

$ du -h --apparent-size base.qcow2
21G     base.qcow2

$ du -h base.qcow2                                        # ALLOCATED size — the truth
1.9G    base.qcow2

$ qemu-img info base.qcow2 | grep -E 'virtual|disk size'
virtual size: 20 GiB (21474836480 bytes)
disk size: 1.9 GiB
```

**Diagnostic rule:** capacity alerting and billing must key off `du` / `qemu-img` *disk size*, never `ls`. A guest that keeps growing its image despite `fstrim` inside it points to a broken discard path (missing `discard='unmap'`, or a filesystem/queue that doesn't issue TRIM).

### 5.3 Backing-chain breakage

```console
$ qemu-img info web-01.qcow2
qemu-img: Could not open 'web-01.qcow2': Could not open backing file: Could not open '/old/path/base.qcow2': No such file or directory
```

Diagnose the recorded pointer and repair it *without copying data*:

```console
$ qemu-img info --output=json web-01.qcow2 2>/dev/null | jq -r '."full-backing-filename"'
/old/path/base.qcow2

$ qemu-img rebase -u -b /images/golden/base.qcow2 -F qcow2 web-01.qcow2
$ qemu-img info web-01.qcow2 | grep backing
backing file: /images/golden/base.qcow2
backing file format: qcow2
```

### 5.4 Snapshot-chain latency creep

Symptom: a guest's random-read latency degrades over weeks. Confirm chain depth and collapse it:

```console
$ qemu-img info --backing-chain web-01.qcow2 | grep -c 'file format'
7                                   # 7-deep chain → every backing-store read walks 7 files

$ virsh blockcommit web-01 vda --active --pivot --verbose   # merge back to base
Block commit: [100 %]
Successfully pivoted
```

### 5.5 Never copy a live image with `cp`

A running guest holds in-memory `qcow2` metadata not yet on disk. A raw `cp`/`rsync` of the file yields an inconsistent snapshot. **Always** either (a) take an external snapshot first and copy the now-frozen backing file, or (b) use `virsh blockcopy` / `qemu-img convert` against a quiesced source. Verify a restore with `qemu-img check` and `qemu-img compare`.

---

## 6. Accessing data inside images — loop devices, NBD, `kpartx`, `libguestfs`

There are two families of access. Understand *why* one is dangerous and one is safe.

| Mechanism | Formats | Root? | Runs guest FS drivers in host kernel? | Safe on untrusted images? | Use when |
|---|---|---|---|---|---|
| `losetup` + `kpartx` | `raw` only | yes | **yes** (host mounts it) | ❌ no | Quick `raw` edits on trusted images |
| `qemu-nbd` | any (`qcow2`, `vmdk`, …) | yes | **yes** | ❌ no | Need block-device semantics for any format |
| `libguestfs` (`guestfish`, `guestmount`, `virt-*`) | any | **no** | **no** — isolated appliance VM | ✅ yes | Everything else; scripting; untrusted images |

The security point (a real CVE surface): `losetup`/`kpartx`/`qemu-nbd` mount the guest's filesystem with the **host kernel's** filesystem driver. A malicious guest image can carry a crafted filesystem that exploits an ext4/xfs kernel bug and compromise the host. `libguestfs` runs the same access inside a throwaway KVM appliance — a hostile image only crashes the sandbox. **Prefer `libguestfs` for anything you did not build yourself.**

### 6.1 `losetup` + `kpartx` — raw images only

```console
$ sudo losetup -fP --show disk.raw
/dev/loop3

$ lsblk /dev/loop3
NAME      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
loop3       7:3    0   20G  0 loop
├─loop3p1   259:0  0    1G  0 part
└─loop3p2   259:1  0   19G  0 part

$ sudo mount /dev/loop3p2 /mnt && ls /mnt
bin  boot  dev  etc  home  lib  ...
$ sudo umount /mnt && sudo losetup -d /dev/loop3
```

If your `losetup` lacks `-P`, use `kpartx` to expose partitions explicitly:

```console
$ sudo losetup -f --show disk.raw
/dev/loop4
$ sudo kpartx -av /dev/loop4
add map loop4p1 (253:5): 0 2097152 linear 7:4 2048
add map loop4p2 (253:6): 0 39843840 linear 7:4 2099200
$ sudo mount /dev/mapper/loop4p2 /mnt
...
$ sudo umount /mnt
$ sudo kpartx -d /dev/loop4 && sudo losetup -d /dev/loop4
```

### 6.2 `qemu-nbd` — expose any format as a block device

```console
$ sudo modprobe nbd max_part=16
$ sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 base.qcow2   # ALWAYS pin --format
$ sudo partprobe /dev/nbd0
$ lsblk /dev/nbd0
NAME      MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
nbd0       43:0    0  20G  0 disk
├─nbd0p1   43:1    0   1G  0 part
└─nbd0p2   43:2    0  19G  0 part

$ sudo mount -o ro /dev/nbd0p2 /mnt        # mount read-only for inspection
$ sudo umount /mnt
$ sudo qemu-nbd --disconnect /dev/nbd0
/dev/nbd0 disconnected
```

Read-only export, or serve over TCP for a remote consumer:

```console
$ sudo qemu-nbd --read-only --connect=/dev/nbd1 --format=qcow2 base.qcow2
$ qemu-nbd --format=qcow2 --port=10809 --persistent base.qcow2   # network block device server
```

> Forgetting `--format=` lets QEMU *probe* the format; a guest can craft an image that probes as a different type — pin it every time.

### 6.3 `libguestfs` — the safe, scriptable, format-agnostic path

The libguestfs toolset boots a minimal KVM appliance, hands it the image, and exposes the guest's filesystems over an API — **no root, no host kernel exposure, works on `qcow2` with backing chains, LVM, LUKS, any of it.**

`guestfish` — interactive/scripted:

```console
$ guestfish --ro -a base.qcow2 -i
Welcome to guestfish, the guest filesystem shell for
editing virtual machine filesystems and disk images.

><fs> cat /etc/os-release | head -1
NAME="Fedora Linux"
><fs> ll /etc/ssh/sshd_config
-rw-------. 1 root root 3669 Aug  1 12:04 /etc/ssh/sshd_config
><fs> exit

# One-liner form (great in CI):
$ guestfish --ro -a base.qcow2 -i cat /etc/hostname
web-golden
```

`guestmount` — FUSE mount, unprivileged, **always `--ro` unless you truly intend to write**:

```console
$ guestmount -a base.qcow2 -i --ro /mnt/inspect
$ cat /mnt/inspect/etc/os-release | head -2
NAME="Fedora Linux"
VERSION="40 (Cloud Edition)"
$ guestunmount /mnt/inspect
```

The `virt-*` tool family — targeted operations, no mount ceremony:

```console
# What partitions/filesystems/LVM does this image contain?
$ virt-filesystems --long --parts --blkdevs --logical-volumes --extra -a base.qcow2 -h
Name       Type       VFS   Label  Size  Parent
/dev/sda1  filesystem vfat  -      600M  -
/dev/sda2  filesystem xfs   root   19G   -
/dev/sda1  partition  -     -      600M  /dev/sda
/dev/sda2  partition  -     -      19G   /dev/sda
/dev/sda   device     -     -      20G   -

# Filesystem usage INSIDE the guest, without booting it
$ virt-df -h -a base.qcow2
Filesystem                    Size    Used  Available  Use%
base.qcow2:/dev/sda1          599M     14M       585M    3%
base.qcow2:/dev/sda2           19G    1.6G        17G    9%

# Full OS/inventory report as XML (drivers, apps, mountpoints)
$ virt-inspector -a base.qcow2 | xmllint --xpath '//product_name/text()' -
Fedora Linux 40 (Cloud Edition)

# Read a single file / list a directory without mounting
$ virt-cat -a base.qcow2 /etc/redhat-release
Fedora release 40 (Forty)
$ virt-ls -a base.qcow2 -l /var/log
total 40
drwxr-xr-x.  8 root   root   4096 Aug  1 12:10 .
-rw-r--r--.  1 root   root   1092 Aug  1 12:10 dnf.log

# Push files into / pull files out of an offline image (customization without boot)
$ virt-copy-in -a base.qcow2 ./resolv.conf /etc/
$ virt-copy-out -a base.qcow2 /var/log/messages ./forensics/

# What changed between two images / a golden and a drifted clone?
$ virt-diff -a base.qcow2 -A web-01-flat.qcow2 | head
- 0644       1234 /etc/motd
+ 0644       1450 /etc/motd
+ 0644        220 /etc/cron.d/telemetry-agent

# Emergency rescue shell against a broken guest (no host risk)
$ virt-rescue --ro -a broken.qcow2
><rescue> mount /dev/sda2 /sysroot && chroot /sysroot journalctl -xb --no-pager | tail
```

### 6.4 `virt-sparsify` — reclaim space, re-thin an image

Over time a `qcow2`/`raw` image bloats: deleted guest data still occupies host clusters because the free space was never zeroed/discarded. `virt-sparsify` zeroes guest free space and writes a thin output:

```console
$ du -h fat.qcow2
14G     fat.qcow2

$ virt-sparsify --compress fat.qcow2 slim.qcow2
[   0.0] Create overlay file in /tmp to protect source disk
[   2.1] Examine source disk
[   5.4] Fill free space in /dev/sda2 with zero
 100% ⟦▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉▉⟧ --:--
[  47.9] Copy to destination and make sparse
[  71.2] Sparsify operation completed with no errors.

$ du -h slim.qcow2
2.3G    slim.qcow2

# In-place variant (careful — mutates the source):
$ virt-sparsify --in-place fat.qcow2
```

The zero-detection step is what lets the sparse write happen — which is exactly why `detect_zeroes=unmap` and guest `fstrim` matter for keeping images thin *without* an offline sparsify pass.

---

## 7. Operational decision summary

- **Format choice:** `qcow2` for portable, file-based images that need snapshots/backing/compression/encryption. `raw` on top of volume-based storage (LVM/RBD/zvol), and let the storage layer own snapshots/clones. `qed` is dead — awareness only.
- **Thin from the top to the bottom:** `discard='unmap'` + `detect_zeroes='unmap'` in the domain, guest `fstrim`/`fstrim.timer`, `virt-sparsify` for offline reclaim. Alert on **allocated** size, never apparent size.
- **Snapshots are debt:** external overlays for time-bounded operational checkpoints, commit/pivot them promptly, keep chains shallow. Never grow an unbounded chain; never write a base that overlays depend on.
- **Copy safely:** never `cp` a live image; snapshot-then-copy or `qemu-img convert` a quiesced source; verify with `qemu-img check` + `qemu-img compare`.
- **Access safely:** `libguestfs` (`guestfish`/`guestmount`/`virt-*`) by default — no root, no host-kernel exposure, any format. Reserve `losetup`/`kpartx`/`qemu-nbd` for `raw`/block-device needs on images you trust, and always pin `--format`.

---

## Referencias

- LPI — Exam 305-300 Objectives (objective 351.5): https://www.lpi.org/our-certifications/exam-305-objectives/
- LPIC-3 Virtualization and Containerization certification overview: https://www.lpi.org/our-certifications/lpic-3-305/
- QEMU — `qemu-img` manual: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU — `qemu-nbd` manual: https://www.qemu.org/docs/master/tools/qemu-nbd.html
- QEMU — qcow2 on-disk format specification: https://gitlab.com/qemu-project/qemu/-/blob/master/docs/interop/qcow2.txt
- QEMU — Disk image file formats: https://www.qemu.org/docs/master/system/images.html
- QEMU — Live block operations (commit, stream, mirror): https://www.qemu.org/docs/master/interop/live-block-operations.html
- QEMU — qcow2 cache / `l2-cache-size` configuration: https://www.qemu.org/docs/master/system/qemu-block-drivers.html
- libvirt — Domain XML format (disk devices): https://libvirt.org/formatdomain.html#hard-drives-floppy-disks-cdroms
- libvirt — Snapshot XML format: https://libvirt.org/formatsnapshot.html
- libvirt — `virsh` command reference: https://libvirt.org/manpages/virsh.html
- libguestfs — Tools and API home: https://libguestfs.org/
- libguestfs — `guestfish` manual: https://libguestfs.org/guestfish.1.html
- libguestfs — `guestmount` manual: https://libguestfs.org/guestmount.1.html
- libguestfs — `virt-sparsify` manual: https://libguestfs.org/virt-sparsify.1.html
- libguestfs — `virt-inspector` manual: https://libguestfs.org/virt-inspector.1.html
- libguestfs — `virt-filesystems` manual: https://libguestfs.org/virt-filesystems.1.html
- Linux — `losetup(8)`: https://man7.org/linux/man-pages/man8/losetup.8.html
- Linux — `kpartx(8)`: https://man7.org/linux/man-pages/man8/kpartx.8.html
- KubeVirt CDI — DataVolumes / disk image import: https://kubevirt.io/user-guide/storage/disks_and_volumes/
- Containerized Data Importer (CDI) documentation: https://github.com/kubevirt/containerized-data-importer/blob/main/doc/datavolumes.md