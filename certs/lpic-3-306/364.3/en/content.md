# Topic 364.3: Advanced LVM

**LPIC-3 306 (exam 306-300, v3.0) — Single Node High Availability · Weight: 5.0**

---

## 1. The production problem: storage as a control plane

A partition table is a static contract. You decide, at provisioning time, that `/var` is 40 GiB and `/data` is 200 GiB, and that decision is frozen onto the disk geometry. In a single-node HA context — a database primary, a stateful broker, a hypervisor host that must survive a disk failure without a maintenance window — that rigidity is the enemy. Three failure modes recur in production:

1. **The 3 a.m. full-filesystem page.** `/var/lib/postgresql` fills. With static partitions your only move is a migration to a bigger disk. With LVM you `lvextend` and `resize2fs`/`xfs_growfs` **online**, in seconds, with the service running.
2. **The capacity-planning tax.** If you must size every volume up-front, you over-provision every volume, and you buy storage you never use. Thin provisioning decouples *allocated* from *consumed* so a 10-tenant host can present 10×500 GiB volumes on a 2 TiB pool, allocating real extents only on first write.
3. **The single-disk blast radius.** One spindle or one NVMe device fails and the node is down. Software RAID *inside* LVM lets a single logical volume span redundant physical volumes, survive a device loss, and be repaired online — without a second layer of `mdadm` to coordinate.

Advanced LVM turns the storage stack into a **software-defined control plane**: a thin layer of metadata over `device-mapper` (`dm`) targets in the kernel, where redundancy, snapshots, tiering (SSD cache in front of HDD), and live data migration are all `lvconvert`/`lvextend` operations against the same object model — Physical Volume → Volume Group → Logical Volume — rather than four unrelated tools.

The mental model to carry through this topic:

```
   filesystem (xfs / ext4 / btrfs)
        │
   Logical Volume (LV)      ← what the OS mounts
        │  logical extents (LE)
   Volume Group (VG)        ← the allocation pool
        │  physical extents (PE), default 4 MiB
   Physical Volume (PV)     ← a disk, partition, mdraid, iSCSI LUN, LUKS device
        │
   device-mapper targets:  linear · thin · cache · writecache · raid · mirror
        │
   block devices (/dev/sd*, /dev/nvme*)
```

Every "advanced" feature is a `dm` target the LV metadata wires up. Understanding *which target* backs a feature is what lets you diagnose it — because `dmsetup` sees the truth that `lvs` summarizes.

---

## 2. Architecture internals you must be able to reason about

### 2.1 Extents, metadata, and the device-mapper table

A VG carves every member PV into fixed-size **physical extents** (PE, default 4 MiB, set at `vgcreate --physicalextentsize`). An LV is an ordered list of **logical extents** (LE) mapped to PEs. That mapping — plus every property of every PV/VG/LV — lives as **plain-text LVM2 metadata** in a ring buffer at the head of each PV (the metadata area), and is snapshotted on every change into `/etc/lvm/archive/` (history) and `/etc/lvm/backup/` (current). This text-metadata design is why LVM is *recoverable*: a corrupted VG can be restored from a human-readable file with `vgcfgrestore`.

The kernel never reads that metadata. Userspace (`lvm`) parses it and pushes a **device-mapper table** into the kernel. Inspect the truth:

```console
$ sudo dmsetup ls --tree
vg_data-lv_app (253:6)
 └─vg_data-tp_data-tpool (253:5)
    ├─vg_data-tp_data_tdata (253:3)
    │  └─ (8:16)
    └─vg_data-tp_data_tmeta (253:2)
       └─ (8:32)

$ sudo dmsetup table vg_data-lv_app
0 1048576000 thin 253:5 1
```

`lvs -a` shows the same stack with hidden sub-LVs in brackets (`[tp_data_tdata]`). **Rule: when `lvs` and reality disagree, `dmsetup table`/`dmsetup status` is the source of truth**, because it reflects what the kernel is actually running, not what the metadata *wants*.

### 2.2 The `lv_attr` field is a 10-character diagnostic

Every `lvs` line carries a positional attribute string. Memorize the first, fifth, and ninth positions — they answer "what is it, is it live, is it healthy":

| Pos | Meaning | Values you will see |
|----|---------|---------------------|
| 1 | Volume type | `t` thin-pool, `T` thin-pool-data, `V` thin volume, `r` raid, `i` raid image, `C` cache, `s` snapshot, `o` origin, `p` pvmove, `-` linear |
| 2 | Permissions | `w` writeable, `r` read-only |
| 3 | Allocation policy | `i` inherited, `c` contiguous, `n` normal (uppercase = locked) |
| 4 | Fixed minor | `m` / `-` |
| 5 | **State** | `a` active, `s` suspended, `i` inactive, `d` no table, `-` |
| 6 | Device open | `o` open (mounted/in-use), `-` |
| 7 | Target type | `t` thin, `r` raid, `C` cache, `s` snapshot, `-` |
| 8 | Newly-allocated zeroed | `z` / `-` |
| 9 | **Health** | `p` partial (missing PV), `r` refresh needed, `m` mismatches found, `F` thin-pool failed, `D` thin data lost |
| 10 | Skip activation | `k` / `-` |

`twi-aotz--` = thin-pool, active, open, thin target, zeroing on. `Vwi-a-tz--` = thin volume, active. `rwi-a-r-p-` at position 9 = **a RAID LV with a missing device** — that `p` is your page.

---

## 3. Thin provisioning and thin snapshots

### 3.1 What the `dm-thin` target actually does

A **thin pool** is two hidden LVs presented as one target: `_tdata` (the data blocks) and `_tmeta` (a B-tree mapping *(thin-device, logical-block) → pool-chunk*). A **thin volume** is a device that reports a large virtual size but occupies zero data chunks until written; on first write to a chunk, the pool allocates one **chunk** (default 64 KiB, power-of-two, 64 KiB–1 GiB) and records it in the metadata B-tree.

**Thin snapshots** are the killer feature: a snapshot is just another thin device whose B-tree initially *shares* the origin's chunk mappings. On write to either origin or snapshot, only the touched chunk is copied (redirect-on-write). Cost is O(changed data), not O(volume size), and — unlike classic LVM snapshots — **snapshots of snapshots are free and there is no separate CoW exception store to overflow**.

### 3.2 Thin vs. thick (classic) — the trade-off that bites in production

| Dimension | Thick (linear) LV | Thin LV (dm-thin) |
|---|---|---|
| Allocation | Eager, at create time | Lazy, on first write |
| Overcommit | Impossible | Possible (and dangerous) |
| Snapshot cost | Sized CoW store, per-snapshot | Shared pool, near-zero |
| Snapshot chains | Degrades fast | Cheap, arbitrary depth |
| Pool-full failure | N/A | **All thin LVs I/O-error or go read-only** |
| Read/write path | Direct PE map | Extra B-tree lookup + copy-on-write |
| `fstrim`/discard | Frees VG? No | Returns chunks to pool (if `discards=passdown`) |
| Metadata risk | Minimal | `_tmeta` corruption/exhaustion loses the whole pool |
| Best for | Predictable, latency-critical single volumes | Many volumes, snapshots, VM/container backing store |

**The overcommit hazard is the single most important operational fact in this objective.** If you present 10×500 GiB thin volumes on a 2 TiB pool and consumption crosses 100%, the pool has no chunks to hand out. Depending on `--errorwhenfull`, writes either **queue for 60 s then error** (default, `n`) or **fail immediately** (`y`). Either way, filesystems on those thin LVs typically remount read-only. **You cannot thin-provision without automatic pool extension + monitoring.**

### 3.3 Building it — full CLI walkthrough with real output

```console
$ sudo pvcreate /dev/sdb /dev/sdc
  Physical volume "/dev/sdb" successfully created.
  Physical volume "/dev/sdc" successfully created.

$ sudo vgcreate vg_data /dev/sdb /dev/sdc
  Volume group "vg_data" successfully created

# Create the thin pool. Put metadata on a separate PV for durability,
# size metadata deliberately (default heuristics under-size it for snapshot-heavy pools).
$ sudo lvcreate --type thin-pool -L 100G --poolmetadatasize 1G \
      --chunksize 128k --poolmetadataspare y -n tp_data vg_data
  Thin pool volume with chunk size 128.00 KiB can address at most 31.62 TiB of data.
  Logical volume "tp_data" created.

# Present a 500G virtual volume backed by the 100G pool (5x overcommit).
$ sudo lvcreate --thin --virtualsize 500G -n lv_app vg_data/tp_data
  Logical volume "lv_app" created.

$ sudo lvs -a -o name,attr,size,pool_lv,data_percent,metadata_percent,chunksize,devices vg_data
  LV               Attr       LSize   Pool    Data%  Meta%  Chunk   Devices
  lv_app           Vwi-a-tz-- 500.00g tp_data 0.00                  0
  tp_data          twi-aotz-- 100.00g               0.00   0.98    128.00k tp_data_tdata(0)
  [tp_data_tdata]  Twi-ao---- 100.00g                              0       /dev/sdb(1)
  [tp_data_tmeta]  ewi-ao----   1.00g                              0       /dev/sdc(0)
  [lvol0_pmspare]  ewi-------   1.00g                              0       /dev/sdb(0)
```

Note `lvol0_pmspare`: a reserved spare metadata LV that `thin_repair` restores into if `_tmeta` is damaged. Keep `--poolmetadataspare y`.

Now a **thin snapshot** — instant, regardless of origin size:

```console
$ sudo mkfs.xfs /dev/vg_data/lv_app && sudo mount /dev/vg_data/lv_app /srv/app
$ sudo lvcreate -s -n lv_app_snap_0800 vg_data/lv_app
  Logical volume "lv_app_snap_0800" created.

$ sudo lvs -o name,attr,origin,data_percent vg_data
  LV                 Attr       Origin  Data%
  lv_app             Vwi-aotz-- lv_app  1.20
  lv_app_snap_0800   Vwi---tz-k lv_app  1.20
  tp_data            twi-aotz--         1.20
```

The snapshot inherits `-k` (skip activation on boot) by default — thin snapshots are inactive until you `lvchange -ay -K`. Both share 1.20% of the pool; divergence is what consumes new chunks.

### 3.4 Sizing the metadata — the number people get wrong

Metadata consumption scales with **number of chunks and number of mappings** (every snapshot that diverges adds mappings). Under-sized `_tmeta` fills *before* `_tdata`, and a full metadata device is a harder failure than a full data device. Estimate before you build:

```console
$ sudo thin_metadata_size --block-size=128k --pool-size=100g --max-thins=1000 -u
thin_metadata_size - 8.14 mebibytes estimated metadata area size ...
# ...but snapshots multiply mappings. For snapshot-heavy pools, size _tmeta generously
# (1–16 GiB); 16 GiB is the hard maximum.
```

Extend metadata online when it approaches its ceiling:

```console
$ sudo lvextend --poolmetadatasize +512M vg_data/tp_data
  Size of logical volume vg_data/tp_data_tmeta changed from 1.00 GiB to 1.50 GiB.
```

### 3.5 Automatic extension — the config that keeps you paged-out

This is mandatory for any thin pool in production. `dmeventd` monitors pool fill and runs `lvextend --use-policies` when a threshold is crossed.

```ini
# /etc/lvm/lvm.conf  (only the relevant stanzas — do not paste the whole file)

activation {
    # dmeventd extends the pool by <percent> once fill crosses <threshold>%.
    # 100 = disabled. Set both data and (implicitly) metadata to extend at 70%.
    thin_pool_autoextend_threshold = 70
    thin_pool_autoextend_percent   = 20

    # Classic (non-thin) snapshots use the parallel keys:
    snapshot_autoextend_threshold  = 70
    snapshot_autoextend_percent    = 20

    # Register LVs with dmeventd automatically at activation. Without this,
    # autoextend never fires.
    monitoring = 1
}

allocation {
    # "performance" starts chunks at 512 KiB and grows with pool size,
    # trading metadata footprint for fewer CoW operations.
    thin_pool_chunk_size_policy = "generic"
    # Return freed chunks to the pool when the filesystem issues discards.
    # (Also controllable per-pool via lvcreate/lvchange --discards.)
}

global {
    # Offline metadata tooling LVM invokes at activation / repair time.
    thin_check_executable  = "/usr/sbin/thin_check"
    thin_check_options     = [ "-q", "--clear-needs-check-flag" ]
    thin_repair_executable = "/usr/sbin/thin_repair"
    use_lvmpolld = 1
}
```

Verify monitoring is actually live (a silently-unregistered pool is the classic "autoextend didn't fire" postmortem):

```console
$ sudo lvs -o name,attr,seg_monitor vg_data
  LV       Attr       Monitor
  lv_app   Vwi-aotz-- not monitored
  tp_data  twi-aotz-- monitored
$ systemctl is-active lvm2-monitor.service
active
```

Set failure behavior explicitly. For a database where silent read-only is worse than a fast, loud error:

```console
$ sudo lvchange --errorwhenfull y vg_data/tp_data
  Logical volume vg_data/tp_data changed.
```

---

## 4. LVM RAID — redundancy inside the volume manager

### 4.1 The `dm-raid` target and its sub-LVs

LVM RAID does **not** shell out to `mdadm`; it drives the same in-kernel `md`/`dm-raid` personality directly. A `raid1` LV is built from paired hidden sub-LVs: `_rimage_N` (a data leg) and `_rmeta_N` (that leg's RAID superblock/bitmap). A `raid5` LV has N+1 rimage/rmeta pairs. This is why one `lvs -a` shows the whole array *and* every leg, and why you can place legs on chosen PVs for fault-domain control.

### 4.2 RAID level trade-offs

| Level | Min devices | Usable (n data + p parity) | Survives | Write penalty | Use case |
|---|---|---|---|---|---|
| `raid0` | 2 | 100% | 0 disks | none (fastest) | Scratch, reproducible data |
| `raid1` | 2 | 1/mirrors | m−1 disks | 2× write | OS/boot, latency-sensitive |
| `raid10` | 4 | 50% | ≥1 per mirror | 2× write | DB data — best random-write redundancy |
| `raid5` | 3 | (n−1)/n | 1 disk | read-modify-write (4 I/O) | Capacity-biased, read-heavy |
| `raid6` | 4 | (n−2)/n | 2 disks | 6 I/O per write | Large HDD arrays (long rebuilds) |

### 4.3 LVM RAID vs. mdraid vs. hardware RAID

| Aspect | LVM RAID (`dm-raid`) | `mdadm` (`md`) | Hardware RAID |
|---|---|---|---|
| Management model | Unified with volumes/snapshots/thin/cache | Separate array layer under LVM | Opaque BIOS/CLI (`storcli`) |
| Per-LV RAID level | **Yes** — different levels per LV in one VG | No — whole array | No — whole controller LUN |
| Online reshape/takeover | `lvconvert` (raid1→raid5, add stripes) | `mdadm --grow` | Vendor-dependent |
| Scrub / consistency | `lvchange --syncaction check/repair` | `echo check > .../sync_action` | Controller-scheduled |
| Rebuild visibility | `lvs` Cpy%Sync, `SyncAction` | `/proc/mdstat` | Out-of-band only |
| Battery-backed write cache | No (use `dm-writecache`) | No | **Yes** (BBU/flash) |
| Portability | Metadata travels with the PVs | Same | Locked to controller family |

**Architectural guidance:** for a single-node HA host with commodity disks, LVM RAID gives you per-LV redundancy, snapshots, and caching in one object model — no `mdadm` layer to coordinate. Keep hardware RAID only where you specifically need a battery-backed write cache and can accept controller lock-in.

### 4.4 Building and operating a RAID5 LV

```console
# -i 3  → 3 data stripes; raid5 adds 1 parity → 4 PVs consumed. -L is USABLE size.
$ sudo lvcreate --type raid5 -i 3 -L 300G -n lv_r5 vg_data
  Using default stripesize 64.00 KiB.
  Logical volume "lv_r5" created.

$ sudo lvs -a -o name,attr,size,segtype,sync_percent,raid_sync_action,region_size,devices vg_data
  LV                Attr       LSize   Type   Cpy%Sync SyncAction Region  Devices
  lv_r5             rwi-a-r--- 300.00g raid5  14.06    idle       2.00m   lv_r5_rimage_0(0),lv_r5_rimage_1(0),...
  [lv_r5_rimage_0]  iwi-aor--- 100.00g linear                            /dev/sdb(1)
  [lv_r5_rmeta_0]   ewi-aor---   4.00m linear                            /dev/sdb(0)
  [lv_r5_rimage_1]  iwi-aor--- 100.00g linear                            /dev/sdc(1)
  ...
```

**Scrubbing** (detect and, separately, repair silent corruption / parity mismatch). Run `check` on a schedule; only run `repair` when you know which copy is authoritative:

```console
$ sudo lvchange --syncaction check vg_data/lv_r5
$ sudo lvs -o name,raid_sync_action,raid_mismatch_count,sync_percent vg_data/lv_r5
  LV     SyncAction Mismatches Cpy%Sync
  lv_r5  check      0          100.00
# Non-zero Mismatches on raid1/10 means the legs disagree → investigate hardware.
$ sudo lvchange --syncaction repair vg_data/lv_r5
```

**Device failure and repair.** Health position 9 flips to `p`, `SyncAction`/`Health` show the problem:

```console
$ sudo lvs -o name,attr,health_status,raid_sync_action vg_data/lv_r5
  LV     Attr       Health          SyncAction
  lv_r5  rwi-a-r-p- partial         idle
# Replace the dead PV's legs onto a spare PV, rebuild online:
$ sudo lvconvert --repair vg_data/lv_r5
  Faulty devices in vg_data/lv_r5 successfully replaced.
# Or target a specific failing device without waiting for total loss:
$ sudo lvconvert --replace /dev/sdc vg_data/lv_r5 /dev/sde
```

**Takeover / reshape** — convert a mirror to parity RAID, or add stripes, online:

```console
$ sudo lvconvert --type raid5 vg_data/lv_mirror      # raid1 → raid5 takeover
$ sudo lvconvert --stripes 4 vg_data/lv_r5 /dev/sdf  # reshape: add a data stripe
```

Write-intent bitmap and rebuild-throttling knobs matter on big arrays: `--regionsize` (bitmap granularity; larger = less metadata, coarser resync), and `lvchange --minrecoveryrate/--maxrecoveryrate` to cap rebuild I/O so a resync doesn't starve production.

---

## 5. Tiering: `dm-cache` (lvmcache) vs. `dm-writecache`

### 5.1 Two different targets for two different problems

- **`dm-cache` (lvmcache):** a hotspot cache. A fast device (NVMe/SSD) fronts a slow origin LV; the `smq` policy promotes frequently-accessed blocks. Caches **reads and writes**. Modes: `writethrough` (write hits both — survives cache loss), `writeback` (write to cache, lazy flush — faster, **cache loss = data loss**).
- **`dm-writecache`:** a pure **write** buffer. It caches *only* writes on a fast, ideally power-loss-protected device (NVMe or PMEM), coalescing them to hide the latency of the slow backing store. It does **not** cache reads and has no eviction policy — it's a write-latency shim, not a hotspot cache.

| Dimension | `dm-cache` (lvmcache) | `dm-writecache` |
|---|---|---|
| Caches | Reads **and** writes | Writes only |
| Policy / eviction | `smq` (hotspot promotion) | None (FIFO flush) |
| Metadata LV | Yes (cache pool: data+meta) | Minimal |
| Read-latency win | Yes | No |
| Ideal fast device | SSD/NVMe | Power-loss-protected NVMe / PMEM |
| Data-loss on fast-dev failure | Only in `writeback` | Yes (unflushed writes) |
| Best for | Mixed read/write hot sets | Write-bursty, fsync-heavy (DB WAL, journals) |

### 5.2 Attaching a cache — modern `--cachevol` flow

```console
# One fast LV holds both cache data and metadata (simpler than the legacy cache-pool).
$ sudo lvcreate -n cvol_fast -L 32G vg_data /dev/nvme0n1
$ sudo lvconvert --type cache --cachevol cvol_fast \
      --cachemode writethrough vg_data/lv_r5
  Logical volume vg_data/lv_r5 is now cached.

$ sudo lvs -a -o name,attr,size,cache_mode,cache_policy,chunksize vg_data
  LV                Attr       LSize   CacheMode    Policy Chunk
  lv_r5             Cwi-a-C--- 300.00g writethrough smq    128.00k
  [cvol_fast_cvol]  Cwi-aoC---  32.00g
  [lv_r5_corig]     owi-aoC--- 300.00g

# Monitor hit ratio via dmsetup status (read hits / read misses / write hits / write misses):
$ sudo dmsetup status vg_data-lv_r5
0 629145600 cache 8 1024/262144 128 45678/262144 20345 118 88456 3120 0 0 0 1 writethrough 2 migration_threshold 2048 smq 0 rw -

# Flip to writeback once you accept the durability trade-off; detach cleanly to flush:
$ sudo lvchange --cachemode writeback vg_data/lv_r5
$ sudo lvconvert --splitcache vg_data/lv_r5     # flush dirty blocks, keep both LVs
$ sudo lvconvert --uncache vg_data/lv_r5        # flush and DELETE the cache vol
```

### 5.3 Attaching a writecache (DB-journal pattern)

```console
$ sudo lvcreate -n wcache -L 16G vg_data /dev/nvme0n1
$ sudo lvconvert --type writecache --cachevol wcache \
      --cachesettings 'high_watermark=50 low_watermark=45' vg_data/lv_wal
  Logical volume vg_data/lv_wal now has write cache.
$ sudo lvs -o name,attr,segtype vg_data/lv_wal
  LV      Attr       Type
  lv_wal  Cwi-aoC--- writecache
```

---

## 6. Online data migration: `pvmove`

`pvmove` relocates the extents of one or more LVs off a PV — to evacuate a failing disk, rebalance onto faster storage, or drain a LUN before decommission — **with the LV mounted and serving I/O**. It builds a temporary mirror, syncs, then atomically switches the mapping. `lvmpolld` tracks progress so it survives a terminal close.

```console
# Evacuate an entire PV (moves every LV segment on /dev/sdb to free space elsewhere):
$ sudo pvmove /dev/sdb
  /dev/sdb: Moved: 0.00%
  /dev/sdb: Moved: 33.41%
  /dev/sdb: Moved: 78.02%
  /dev/sdb: Moved: 100.00%

# Move just one LV, onto a specific destination PV, in the background:
$ sudo pvmove -n lv_app -b /dev/sdb /dev/sdd
$ sudo lvs -o name,move_pv,copy_percent -a vg_data     # watch progress
  LV      Move    Cpy%Sync
  lv_app  /dev/sdb 61.55

# Interrupt-safe: resume or abort a running move
$ sudo pvmove          # resume any in-flight move
$ sudo pvmove --abort  # cancel, leaving data in a consistent place

# Once empty, remove the PV from the VG and wipe its label:
$ sudo vgreduce vg_data /dev/sdb
  Removed "/dev/sdb" from volume group "vg_data"
$ sudo pvremove /dev/sdb
  Labels on physical volume "/dev/sdb" successfully wiped.
```

`pvmove` on thin-pool or cache sub-LVs has constraints; move the whole pool/origin, and prefer `--atomic` for all-or-nothing semantics on multi-segment moves.

---

## 7. Full infrastructure manifests (uncut)

### 7.1 Ansible — declarative build of the whole stack

```yaml
---
# playbooks/advanced_lvm.yml — idempotent build of a thin+RAID+cache host
# Requires: community.general collection (lvg, lvol modules)
- name: Provision advanced LVM storage on a single-node HA host
  hosts: storage_nodes
  become: true
  vars:
    vg_name: vg_data
    pvs:
      - /dev/sdb
      - /dev/sdc
      - /dev/sdd
      - /dev/sde
    thin_pool_size: 100g
    thin_pool_meta_size: 1g
    thin_vol_size: 500g          # overcommitted virtual size
  tasks:
    - name: Ensure LVM userspace + dm-persistent tooling present
      ansible.builtin.package:
        name:
          - lvm2
          - device-mapper-persistent-data   # thin_check / cache_check / *_repair
        state: present

    - name: Create the volume group across all PVs
      community.general.lvg:
        vg: "{{ vg_name }}"
        pvs: "{{ pvs | join(',') }}"
        pesize: "4"                          # 4 MiB physical extents

    - name: Create the thin pool with explicit metadata + chunk size
      community.general.lvol:
        vg: "{{ vg_name }}"
        thinpool: tp_data
        size: "{{ thin_pool_size }}"
        opts: >-
          --poolmetadatasize {{ thin_pool_meta_size }}
          --chunksize 128k --poolmetadataspare y

    - name: Create the overcommitted thin volume
      community.general.lvol:
        vg: "{{ vg_name }}"
        lv: lv_app
        thinpool: tp_data
        size: "{{ thin_vol_size }}"

    - name: Fail loudly instead of blocking when the pool fills
      ansible.builtin.command:
        cmd: lvchange --errorwhenfull y {{ vg_name }}/tp_data
      changed_when: false

    - name: Format and mount the thin volume
      ansible.builtin.filesystem:
        fstype: xfs
        dev: "/dev/{{ vg_name }}/lv_app"
    - name: Mount with discard so freed chunks return to the pool
      ansible.posix.mount:
        path: /srv/app
        src: "/dev/{{ vg_name }}/lv_app"
        fstype: xfs
        opts: defaults,discard
        state: mounted

    - name: Enforce autoextend policy in lvm.conf
      ansible.builtin.blockinfile:
        path: /etc/lvm/lvm.conf
        marker: "# {mark} ANSIBLE MANAGED THIN AUTOEXTEND"
        insertafter: '^activation \{'
        block: |
          thin_pool_autoextend_threshold = 70
          thin_pool_autoextend_percent   = 20
          snapshot_autoextend_threshold  = 70
          monitoring = 1
      notify: reload lvm monitor

    - name: Ensure the monitor service is enabled and running
      ansible.builtin.systemd:
        name: lvm2-monitor.service
        enabled: true
        state: started

  handlers:
    - name: reload lvm monitor
      ansible.builtin.command: vgchange --monitor y {{ vg_name }}
      changed_when: false
```

### 7.2 cloud-init — provision at first boot

```yaml
#cloud-config
# First-boot LVM: thin pool on two attached data disks, autoextend on.
packages:
  - lvm2
  - device-mapper-persistent-data

bootcmd:
  - [ cloud-init-per, once, pvcreate, pvcreate, -y, /dev/vdb, /dev/vdc ]
  - [ cloud-init-per, once, vgcreate, vgcreate, vg_data, /dev/vdb, /dev/vdc ]
  - [ cloud-init-per, once, thinpool, lvcreate, --type, thin-pool, -l, "95%FREE",
      --poolmetadatasize, 1g, --chunksize, 128k, -n, tp_data, vg_data ]
  - [ cloud-init-per, once, thinlv, lvcreate, --thin, --virtualsize, 500G,
      -n, lv_app, vg_data/tp_data ]

write_files:
  - path: /etc/lvm/lvm.conf.d/99-autoextend.conf
    content: |
      activation {
          thin_pool_autoextend_threshold = 70
          thin_pool_autoextend_percent   = 20
          monitoring = 1
      }

runcmd:
  - [ mkfs.xfs, /dev/vg_data/lv_app ]
  - [ systemctl, enable, --now, lvm2-monitor.service ]
```

### 7.3 systemd mount unit with a pool-fill guard

```ini
# /etc/systemd/system/srv-app.mount
[Unit]
Description=Application data on thin LV
Requires=lvm2-monitor.service
After=lvm2-monitor.service

[Mount]
What=/dev/vg_data/lv_app
Where=/srv/app
Type=xfs
Options=defaults,discard,nofail

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/thinpool-guard.service — page before the pool wedges
[Unit]
Description=Alert when thin pool crosses 85% data or metadata
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thinpool_guard.sh vg_data/tp_data 85
```

```ini
# /etc/systemd/system/thinpool-guard.timer
[Unit]
Description=Run thin pool guard every 5 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/thinpool_guard.sh — proportional-to-weight-5.0 vigilance.
set -euo pipefail
pool="$1"; threshold="$2"
read -r data meta < <(lvs --noheadings -o data_percent,metadata_percent "$pool" \
                        | tr -d ' ' | awk -F'|' '{print $1, $2}' OFS=' ' \
                        | awk '{printf "%d %d", $1, $2}')
if (( data >= threshold || meta >= threshold )); then
    logger -p daemon.crit "THINPOOL ${pool} at data=${data}% meta=${meta}% (>=${threshold}%)"
    exit 2
fi
```

---

## 8. Verification and failure diagnosis

### 8.1 The standing health query

Run this before believing any storage is healthy. It surfaces fill, sync, and health in one line each:

```console
$ sudo lvs -a -o name,attr,size,pool_lv,data_percent,metadata_percent,\
copy_percent,raid_sync_action,health_status,seg_monitor
  LV               Attr       LSize   Pool    Data% Meta% Cpy%Sync SyncAction Health  Monitor
  lv_app           Vwi-aotz-- 500.00g tp_data 62.10                                   
  lv_r5            rwi-a-r--- 300.00g               100.00   idle              monitored
  tp_data          twi-aotz-- 100.00g         62.10 3.44                              monitored
```

Cross-check the kernel view when anything looks off:

```console
$ sudo dmsetup status                # per-target live state
$ sudo dmsetup info -c               # open counts, suspended flags
$ sudo journalctl -k | grep -Ei 'dm-thin|dm-cache|dm-raid|device-mapper'
```

### 8.2 Failure playbooks

**A) Thin pool data 100% full.** Symptom: thin LVs remount read-only or throw `EIO`; `lvs` shows `Data% 100.00`, `lv_attr` pos-9 `F` if the pool itself failed.
```console
# 1. Fastest mitigation — extend the pool from free VG space:
$ sudo lvextend -L +50G vg_data/tp_data
# 2. No free space? Add a PV first, then extend:
$ sudo vgextend vg_data /dev/sdf && sudo lvextend -L +50G vg_data/tp_data
# 3. Reclaim from the filesystem side:
$ sudo fstrim -v /srv/app
# 4. If the pool is flagged needs_check, LVM ran thin_check at activation;
#    force-activate and inspect:
$ sudo lvchange -ay vg_data/tp_data
$ sudo journalctl -u lvm2-monitor -n 50
```

**B) Thin metadata full or corrupt** (harder than data-full). `Meta% 100.00`, or activation refuses with a `needs_check` flag.
```console
# Deactivate, dump/repair metadata into the spare using the persistent-data tools:
$ sudo lvchange -an vg_data/tp_data
$ sudo lvconvert --repair vg_data/tp_data        # invokes thin_repair into pmspare
# Manual inspection when you distrust the automatic repair:
$ sudo thin_dump /dev/mapper/vg_data-tp_data_tmeta | less
$ sudo thin_check /dev/mapper/vg_data-tp_data_tmeta
```

**C) RAID LV degraded / missing PV.** `lv_attr` pos-9 `p` (partial), `Health = partial`.
```console
$ sudo vgs -o vg_name,pv_count,vg_missing_pv_count vg_data
$ sudo lvconvert --repair vg_data/lv_r5          # rebuild onto spare PVs
$ sudo lvs -o name,copy_percent,raid_sync_action vg_data/lv_r5   # watch resync
# If a PV was only transiently absent (SAN blip), refresh instead of rebuild:
$ sudo lvchange --refresh vg_data/lv_r5
```

**D) Whole VG metadata damaged.** Restore from the text archive LVM writes on every change:
```console
$ sudo ls -t /etc/lvm/archive/vg_data_*.vg | head
$ sudo vgcfgrestore -l vg_data                   # list restore points
$ sudo vgcfgrestore -f /etc/lvm/archive/vg_data_00042-....vg vg_data
```

**E) A PV reappears with stale metadata / duplicate UUID** (cloned disk, snapshot restore):
```console
$ sudo pvs -o pv_name,pv_uuid,vg_name              # spot the duplicate UUID
$ sudo vgimportclone --basevgname vg_data_clone /dev/sdX   # re-stamp the clone
# Scope which devices LVM scans to avoid the ambiguity entirely:
#   /etc/lvm/lvm.conf → devices { filter = [ "a|/dev/sd[b-e]|", "r|.*|" ] }
$ sudo pvscan --cache        # refresh the udev/lvmetad-style scan cache
```

### 8.3 Post-change acceptance checks

After any `lvextend`/`lvconvert`/`pvmove`, prove the outcome — don't assume:

```console
$ sudo vgcfgbackup && echo "metadata backed up to /etc/lvm/backup/"
$ sudo lvs -a -o +devices vg_data          # confirm segment placement
$ df -h /srv/app                            # confirm the filesystem saw the growth
$ sudo xfs_growfs /srv/app                  # xfs: grow FS after lvextend (ext4: resize2fs)
$ sudo lvchange --syncaction check vg_data/lv_r5   # RAID: re-verify consistency
```

`lvextend -r` (`--resizefs`) does the LV grow **and** the filesystem grow atomically, and is the safer default for online expansion:

```console
$ sudo lvextend -r -L +20G vg_data/lv_app
  Size of logical volume vg_data/lv_app changed from 500.00 GiB to 520.00 GiB.
  meta-data=/dev/mapper/vg_data-lv_app ... data blocks changed ...
```

---

## 9. References

- LPI — *LPIC-3 Exam 306 Objectives (306-300, v3.0)*: https://www.lpi.org/our-certifications/exam-306-objectives/
- `lvmthin(7)` — thin provisioning and thin snapshots: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- `lvmraid(7)` — LVM RAID types, scrubbing, repair, reshape: https://man7.org/linux/man-pages/man7/lvmraid.7.html
- `lvmcache(7)` — dm-cache and dm-writecache attachment: https://man7.org/linux/man-pages/man7/lvmcache.7.html
- `lvm.conf(5)` — configuration keys (`activation`, `allocation`, `global`): https://man7.org/linux/man-pages/man5/lvm.conf.5.html
- `pvmove(8)` — online extent migration: https://man7.org/linux/man-pages/man8/pvmove.8.html
- `lvconvert(8)` / `lvcreate(8)` / `lvextend(8)`: https://man7.org/linux/man-pages/man8/lvconvert.8.html
- Linux kernel — Device Mapper thin-provisioning target: https://docs.kernel.org/admin-guide/device-mapper/thin-provisioning.html
- Linux kernel — dm-cache target: https://docs.kernel.org/admin-guide/device-mapper/cache.html
- Linux kernel — dm-writecache target: https://docs.kernel.org/admin-guide/device-mapper/writecache.html
- Linux kernel — dm-raid target: https://docs.kernel.org/admin-guide/device-mapper/dm-raid.html
- LVM2 project (sources, metadata format, persistent-data tools): https://sourceware.org/lvm2/
- Red Hat — *Configuring and managing logical volumes* (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index
- `thin_check(8)` / `thin_repair(8)` / `cache_check(8)` (device-mapper-persistent-data): https://man7.org/linux/man-pages/man8/thin_check.8.html