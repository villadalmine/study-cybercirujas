# Topic 364.2 — Advanced RAID

> **LPIC-3 306 (Exam 306-300, v3.0) · Topic 364: Single-Node High Availability · Objective weight 3.33**
> Linux Software RAID with `mdadm` / the `md` subsystem — nested levels, metadata, reshaping, write-intent bitmaps, journaling/PPL, and failure recovery from an SRE/Platform-Architect perspective.

---

## 1. The production problem: RAID is the durability floor, not the durability ceiling

In a modern stack you almost always have a distributed layer above the disk — Ceph, GlusterFS, DRBD, a database with its own replication. So why does single-node RAID still earn a full exam objective and a place in every serious storage design?

Because **RAID and distributed replication solve different failure domains at different latencies, and they compose.**

- A **single device failure** (a spindle that dies, a flash chip that wears out, a cable that drops) is the single most common storage fault in a fleet. Handling it *locally*, in the kernel `md` layer, means **zero network traffic, microsecond-scale failover, and no rebuild storm crossing your east-west fabric.** If every disk failure forced a full-object re-replication across the cluster network, a routine drive swap would generate terabytes of cross-rack traffic and contend with production I/O.
- The **distributed layer** handles the failure domains RAID *cannot*: a whole node dying, a rack losing power, a datacenter partition. It is coarse-grained and network-bound by design.

The architectural rule: **RAID gives you a durable local brick; the distributed system replicates bricks.** Ceph OSDs on top of a per-node RAID, DRBD backed by a RAID array, or a PostgreSQL primary on RAID-10 are all the same pattern — cheap, fast, local redundancy underneath expensive, slow, global redundancy.

### 1.1 The two failure models that drive every advanced-RAID decision

**(a) The rebuild window vs. UBER.** Drive capacities grew ~1000× while the **Unrecoverable Bit Error Rate (UBER)** of consumer/nearline SATA stayed at ~1 in 10¹⁴ bits read. A 4 TB drive is 3.2×10¹³ bits. To rebuild a degraded **RAID 5** you must read *every* surviving block; the probability of hitting one URE mid-rebuild — and thereby losing the whole array — is no longer negligible. This is the mathematical reason RAID 5 is considered unsafe on large nearline drives and why **RAID 6 (dual parity)** became the production default for capacity arrays: it survives a URE *during* a single-disk rebuild.

**(b) The RAID 5/6 write hole.** A stripe write is not atomic across devices. If power is lost after the data blocks are written but before parity is updated (or vice-versa), the stripe is now **internally inconsistent**. On the next unclean-boot resync, `md` recomputes parity from whatever data it finds — but if a disk *also* failed, it will reconstruct that disk's block from *stale parity*, silently returning corrupt data. `md` closes this hole with a **journal** (dedicated device) or **PPL — Partial Parity Log** (in-metadata, RAID 5 only).

Everything advanced about `md` — bitmaps, journals, PPL, `--replace`, spare groups, reshape — exists to shrink one of these two windows or to survive events inside them.

---

## 2. Comparative analysis and trade-offs

### 2.1 RAID levels — the decision matrix

| Level | Min dev | Usable capacity (n disks) | Survives | Read | Write | Rebuild cost | Production role |
|---|---|---|---|---|---|---|---|
| **0** | 2 | n | **nothing** | ⭑⭑⭑ | ⭑⭑⭑ | N/A (data lost) | Scratch / ephemeral / cache tier only |
| **1** | 2 | n/2 (typ. size of 1) | n−1 disks (all but 1) | ⭑⭑⭑ | ⭑⭑ | cheap (full copy) | Boot/OS disks, small critical volumes |
| **4** | 3 | n−1 | 1 disk | ⭑⭑ | ⭑ (parity-disk bottleneck) | full read | Rare; dedicated parity disk is a hotspot |
| **5** | 3 | n−1 | 1 disk | ⭑⭑⭑ | ⭑ (RMW penalty) | full read (**URE risk**) | Legacy; avoid on large nearline drives |
| **6** | 4 | n−2 | **2 disks** | ⭑⭑⭑ | ⭑ (2× parity RMW) | full read (survives URE) | **Capacity default** for archive/bulk |
| **10 (1+0)** | 4 | n/2 | ≥1 per mirror set | ⭑⭑⭑ | ⭑⭑⭑ | cheap (mirror copy) | **Performance default** for DBs/latency |

- **RAID 5/6 write penalty:** a sub-stripe write is Read-Modify-Write — read old data + old parity, XOR, write new data + new parity. RAID 6 pays this **twice** (P and Q syndromes). This is why parity RAID is poor for random small writes (OLTP) and RAID 10 is preferred there.
- **Rebuild asymmetry:** RAID 10 rebuilds by copying *one* surviving mirror (fast, low array-wide I/O). RAID 5/6 must read *every* disk to recompute the lost member — slow, and it stresses the exact drives most likely to co-fail.

### 2.2 Nested / hybrid RAID — and why Linux `raid10` ≠ "RAID 1+0"

| Topology | Construction | Notes |
|---|---|---|
| **1+0 (10)** | stripe over mirrors | Loses array only if *both* members of *one* mirror die |
| **0+1** | mirror over stripes | Worse: one disk loss degrades a whole stripe leg; second loss on the *other* leg kills it |
| **md `raid10`** | single-level driver | Not a stack of `raid1`+`raid0`; native driver with **layouts** and **odd-disk / arbitrary-replica** support |

Linux `md`'s **`raid10` is a first-class personality**, not two stacked arrays. It supports **any number of drives ≥ 2** (even 3) and configurable copy placement via `--layout`:

| Layout | Flag | Behavior | Use when |
|---|---|---|---|
| **near** | `n2` | Copies on adjacent devices (classic 1+0-like) | General purpose, default |
| **far** | `f2` | Second copy shifted far down the devices | **Read throughput ≈ RAID 0**; writes seek more |
| **offset** | `o2` | Copy on next device, offset by one chunk | Balanced read/write compromise |

`f2` on spinning media gives near-striping read bandwidth because sequential reads pull the "far" copy contiguously — a common trick for read-heavy analytics on HDD.

### 2.3 Superblock metadata versions

| Version | Superblock location | Boot from it? | Max devices | Notes |
|---|---|---|---|---|
| **0.90** | End of device | Yes (legacy) | 28 | Fixed limits; auto-detect via partition type `0xFD`; **deprecated** |
| **1.0** | End of device | Yes | 1920+ | Data at start → bootloaders that ignore RAID can read it |
| **1.1** | Start of device (0 offset) | No (overwrites boot area) | 1920+ | Prevents accidental mount of a bare member |
| **1.2** | 4 KiB from start | Yes (with RAID-aware GRUB) | 1920+ | **Current default** |

**Default is `1.2`.** Choose `1.0` for a `/boot` array that a naive bootloader must read as if it were a plain disk. Never rely on `0.90` auto-assembly for new arrays.

### 2.4 Software `md` vs. LVM-RAID (dm-raid) vs. hardware RAID vs. fakeRAID

| Dimension | `md` (mdadm) | LVM RAID (dm-raid) | Hardware RAID (HBA) | fakeRAID (BIOS/IMSM) |
|---|---|---|---|---|
| Engine | Kernel `md` | Same kernel `md`/`dm` targets, LVM front-end | Vendor ASIC + BBU/flash cache | Firmware metadata, **CPU does the work** |
| Portability | Move disks to any Linux host | Same | Locked to controller family | Locked to chipset |
| Observability | `/proc/mdstat`, `sysfs` — fully transparent | `lvs -a -o +raid_sync_action` | Opaque; vendor CLI (`storcli`, `ssacli`) | Poor |
| Write cache | OS page cache / journal device | Same | **Battery-backed** — real advantage | None |
| Reshape/grow | Rich (`--grow`) | Rich (`lvconvert`) | Vendor-dependent | Limited |
| Recommendation | **Default for Linux** | When you want RAID + thin/snapshots in one tool | When BBU write cache is mandatory | **Avoid**; use `md` in AHCI mode instead |

**fakeRAID** (Intel IMSM / VROC, Adaptec HostRAID) has no offload — the CPU computes parity while the metadata format locks you to that chipset. `md` supports IMSM containers (`mdadm --detail-platform`, `AUTO +imsm`) precisely so you can *interoperate* with it, but for greenfield Linux, native `1.2` metadata is superior in every way except UEFI dual-boot with Windows.

### 2.5 Chunk size trade-offs

The **chunk** (a.k.a. stripe unit) is the contiguous run written to one device before moving to the next.

| Chunk | Favors | Cost |
|---|---|---|
| Small (64K) | Many parallel small I/Os spread across spindles | More seeks per large I/O; parity RMW overhead |
| Large (512K–1M) | Large sequential I/O, video, backups | A small write may still touch a full stripe (RMW) |

Default is **512 KiB**. Match it to the workload and *then align the filesystem to it* (§5.4). A mismatched chunk silently halves throughput.

---

## 3. Infrastructure manifests (complete, unabridged)

### 3.1 `/etc/mdadm/mdadm.conf` (Debian/Ubuntu path; `/etc/mdadm.conf` on RHEL)

```conf
# /etc/mdadm/mdadm.conf  — regenerate ARRAY lines with:  mdadm --detail --scan
# --------------------------------------------------------------------------

# Which block devices mdadm may scan when assembling by UUID.
DEVICE /dev/sd[b-z] /dev/nvme[0-9]n[0-9]

# Tag arrays created on this host so foreign arrays are not auto-assembled.
HOMEHOST <system>

# Where mdmonitor sends fault events (see §5.1).
MAILADDR storage-team@example.com
MAILFROM mdadm@storage01.prod.example.net

# Auto-assembly policy: accept IMSM containers and 1.x native, refuse the rest.
AUTO +imsm +1.x -all

# --- Managed arrays (identified by UUID, never by /dev name) ---------------
ARRAY /dev/md0  metadata=1.2 name=storage01:0 UUID=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b spare-group=bulk
ARRAY /dev/md1  metadata=1.2 name=storage01:1 UUID=aa11bb22:cc33dd44:ee55ff66:0011a2b3 spare-group=bulk

# --- Spare-migration policy: let a spare move to a same-slot replacement ----
POLICY domain=bulk path=pci-0000:03:00.0-* action=spare-same-slot
```

Two arrays sharing `spare-group=bulk` will **lend each other a hot spare**: if `md0` degrades and has no local spare, `mdmonitor` migrates an idle spare from `md1` into it.

### 3.2 systemd fault-monitoring unit (`mdmonitor.service`, shipped with mdadm)

```ini
# /usr/lib/systemd/system/mdmonitor.service
[Unit]
Description=MD array monitor
DefaultDependencies=no
Documentation=man:mdadm(8)
Conflicts=shutdown.target
Wants=local-fs.target
After=local-fs.target

[Service]
Environment= MDADM_MONITOR_ARGS=--scan
EnvironmentFile=-/run/sysconfig/mdadm
ExecStartPre=-/usr/lib/systemd/scripts/mdadm_env.sh
ExecStart=/sbin/mdadm --monitor $MDADM_MONITOR_ARGS
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl enable --now mdmonitor.service
$ systemctl status mdmonitor.service --no-pager
● mdmonitor.service - MD array monitor
     Loaded: loaded (/usr/lib/systemd/system/mdmonitor.service; enabled)
     Active: active (running) since Wed 2026-08-12 14:30:11 UTC; 3min ago
   Main PID: 1187 (mdadm)
      Tasks: 1 (limit: 38314)
```

### 3.3 Weekly scrub timer (data-scrubbing detects silent corruption)

```ini
# /etc/systemd/system/mdcheck.timer
[Unit]
Description=Weekly MD RAID consistency scrub

[Timer]
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/mdcheck.service
[Unit]
Description=Trigger MD RAID scrub (check action)
After=local-fs.target

[Service]
Type=oneshot
# Throttle so the scrub does not starve production I/O.
ExecStartPre=/usr/bin/bash -c 'echo 50000 > /proc/sys/dev/raid/speed_limit_max'
ExecStart=/usr/bin/bash -c 'for m in /sys/block/md*/md/sync_action; do echo check > "$m"; done'
```

> On Debian, the `mdadm` package already ships `/usr/share/mdadm/checkarray` plus a cron/timer — prefer that over hand-rolling if present.

### 3.4 Declarative provisioning — Ansible role (idempotent, production-grade)

```yaml
# roles/md_array/tasks/main.yml
---
- name: Ensure mdadm is installed
  ansible.builtin.package:
    name: mdadm
    state: present

- name: Create RAID 6 capacity array (idempotent — module no-ops if UUID exists)
  community.general.mdadm:                      # or ansible.posix on some collections
    name: /dev/md0
    level: 6
    devices:
      - /dev/sdb
      - /dev/sdc
      - /dev/sdd
      - /dev/sde
      - /dev/sdf
      - /dev/sdg
    chunk: 512
    metadata: "1.2"
    bitmap: internal
    state: present
  register: md0

- name: Persist array definition to mdadm.conf
  ansible.builtin.shell: |
    set -o pipefail
    mdadm --detail --scan /dev/md0 >> /etc/mdadm/mdadm.conf
  args:
    executable: /bin/bash
  when: md0.changed

- name: Rebuild initramfs so the array assembles at boot
  ansible.builtin.command: update-initramfs -u        # dracut -f on RHEL
  when: md0.changed

- name: Create XFS aligned to the RAID geometry (su=chunk, sw=data disks)
  community.general.filesystem:
    fstype: xfs
    dev: /dev/md0
    opts: "-d su=512k,sw=4"                            # RAID6 of 6 disks → 4 data disks
    state: present
```

### 3.5 cloud-init: RAID at first boot

```yaml
#cloud-config
# Build a mirrored root-data volume on ephemeral/attached disks at first boot.
disk_setup:
  /dev/nvme1n1: {table_type: gpt, layout: true, overwrite: true}
  /dev/nvme2n1: {table_type: gpt, layout: true, overwrite: true}

bootcmd:
  - [ cloud-init-per, once, mkmd,
      mdadm, --create, /dev/md0, --level=1, --raid-devices=2, --metadata=1.2,
      --bitmap=internal, /dev/nvme1n1, /dev/nvme2n1, --run ]

runcmd:
  - mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
  - mkfs.ext4 -F -b 4096 -E stride=128,stripe-width=128 /dev/md0
  - mkdir -p /data && mount /dev/md0 /data
  - echo "/dev/md0 /data ext4 defaults,nofail 0 2" >> /etc/fstab
```

---

## 4. Command reference with real terminal output

### 4.1 Create a RAID 6 array with an internal write-intent bitmap

```console
$ sudo mdadm --create /dev/md0 --level=6 --raid-devices=6 --chunk=512 \
    --metadata=1.2 --bitmap=internal /dev/sd{b,c,d,e,f,g}
mdadm: layout defaults to left-symmetric
mdadm: chunk size defaults to 512K
mdadm: size set to 3906886656K
mdadm: automatically enabling write-intent bitmap on large array
mdadm: array /dev/md0 started.
```

```console
$ cat /proc/mdstat
Personalities : [raid6] [raid5] [raid4]
md0 : active raid6 sdg[5] sdf[4] sde[3] sdd[2] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/6] [UUUUUU]
      [>....................]  resync =  0.4% (17821440/3906886656) finish=343.2min speed=188901K/sec
      bitmap: 30/30 pages [120KB], 65536KB chunk

unused devices: <none>
```

Read the status line carefully: `[6/6]` = devices expected/present; `[UUUUUU]` = per-device state (`U`=up, `_`=missing). `algorithm 2` = left-symmetric parity layout.

### 4.2 Full detail and per-device examine

```console
$ sudo mdadm --detail /dev/md0
/dev/md0:
           Version : 1.2
     Creation Time : Wed Aug 12 14:22:31 2026
        Raid Level : raid6
        Array Size : 15627546624 (14.55 TiB 16.00 TB)
     Used Dev Size : 3906886656 (3.64 TiB 4.00 TB)
      Raid Devices : 6
     Total Devices : 6
       Persistence : Superblock is persistent

     Intent Bitmap : Internal

             State : clean, resyncing
    Active Devices : 6
   Working Devices : 6
    Failed Devices : 0
     Spare Devices : 0

            Layout : left-symmetric
        Chunk Size : 512K
Consistency Policy : bitmap

              Name : storage01:0  (local to host storage01)
              UUID : 3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
            Events : 42

    Number   Major   Minor   RaidDevice State
       0       8       16        0      active sync   /dev/sdb
       1       8       32        1      active sync   /dev/sdc
       2       8       48        2      active sync   /dev/sdd
       3       8       64        3      active sync   /dev/sde
       4       8       80        4      active sync   /dev/sdf
       5       8       96        5      active sync   /dev/sdg
```

```console
$ sudo mdadm --examine /dev/sdb          # reads the on-disk superblock of ONE member
/dev/sdb:
          Magic : a92b4efc
        Version : 1.2
    Feature Map : 0x1
     Array UUID : 3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
           Name : storage01:0
  Creation Time : Wed Aug 12 14:22:31 2026
     Raid Level : raid6
   Raid Devices : 6
    Data Offset : 264192 sectors
   Super Offset : 8 sectors
   Unused Space : before=264104 sectors, after=0 sectors
          State : clean
    Device UUID : d1e2f3a4:...:...
Internal Bitmap : 8 sectors from superblock
    Update Time : Wed Aug 12 14:25:03 2026
       Checksum : 5f3a1c2e - correct
         Events : 42
         Layout : left-symmetric
     Chunk Size : 512K
   Device Role : Active device 0
   Array State : AAAAAA ('A' == active, '.' == missing, 'R' == replacing)
```

> **`--detail` inspects the running array via `md`; `--examine` reads the raw superblock off a member.** When an array won't assemble, `--examine` is your source of truth — compare `Events` counters across members to find the stale disk.

### 4.3 Grow: convert RAID 5 → RAID 6, and add capacity by reshape

```console
$ sudo mdadm --grow /dev/md0 --level=6 --raid-devices=7 \
    --add /dev/sdh --backup-file=/root/md0-reshape.backup
mdadm: level of /dev/md0 changed to raid6
mdadm: added /dev/sdh
mdadm: Need to backup 15360K of critical section..

$ cat /proc/mdstat
md0 : active raid6 sdh[6] sdg[5] sdf[4] sde[3] sdd[2] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 18 [7/7] [UUUUUUU]
      [===>.................]  reshape = 18.7% (730812416/3906886656) finish=612.4min speed=86420K/sec
```

The `--backup-file` protects the **critical section** — the stripes being relocated during the reshape — against a crash mid-reshape. Keep it on a *different* device. After the reshape finishes, extend the filesystem:

```console
$ sudo mdadm --grow /dev/md0 --size=max        # if member disks were also enlarged
$ sudo xfs_growfs /data                        # or: resize2fs /dev/md0  (ext4)
```

### 4.4 Simulate, remove, and rebuild a failed device

```console
$ sudo mdadm --manage /dev/md0 --fail /dev/sdd
mdadm: set /dev/sdd faulty in /dev/md0

$ cat /proc/mdstat
md0 : active raid6 sdg[5] sdf[4] sde[3] sdd[2](F) sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/5] [UUU_UU]

$ sudo mdadm --manage /dev/md0 --remove /dev/sdd
mdadm: hot removed /dev/sdd from /dev/md0

$ sudo mdadm --manage /dev/md0 --add /dev/sdi
mdadm: added /dev/sdi

$ cat /proc/mdstat
md0 : active raid6 sdi[6] sdg[5] sdf[4] sde[3] sdc[1] sdb[0]
      15627546624 blocks super 1.2 level 6, 512k chunk, algorithm 2 [6/5] [UUU_UU]
      [>....................]  recovery =  0.9% (35651584/3906886656) finish=289.7min speed=222549K/sec
      bitmap: 4/30 pages [16KB], 65536KB chunk
```

**`--replace` is superior when the disk is *dying but not dead*:** it rebuilds onto a spare while keeping the failing disk in the array as a redundancy source — so the array stays *fully* redundant throughout, instead of running degraded:

```console
$ sudo mdadm /dev/md0 --add-spare /dev/sdi
$ sudo mdadm /dev/md0 --replace /dev/sde --with /dev/sdi
mdadm: Marked /dev/sde (device 3) for replacement
mdadm: Marked /dev/sdi as replacement for device 3
```

### 4.5 Write-intent bitmap: add, tune, remove online

A **write-intent bitmap** records which regions have in-flight writes. After a crash or transient disk drop, resync touches **only dirty regions** instead of the whole array — turning a 6-hour full resync into seconds.

```console
$ sudo mdadm --grow /dev/md0 --bitmap=internal --bitmap-chunk=128M
$ sudo mdadm --grow /dev/md0 --bitmap=none     # remove (e.g. before a reshape that forbids it)
```

Trade-off: a bitmap adds a small write-latency tax (every dirty-bit set is an extra I/O). Use a **larger `--bitmap-chunk`** to reduce that tax at the cost of coarser resync granularity. For very write-heavy low-latency arrays, an **external bitmap** on a fast separate device avoids the seek back to the data disks.

### 4.6 Closing the write hole: journal (any parity level) vs. PPL (RAID 5)

```console
# Dedicated write-journal on NVMe — closes the write hole for RAID 5 AND 6,
# at the cost of every write also hitting the journal device first.
$ sudo mdadm --create /dev/md1 --level=6 --raid-devices=6 \
    --write-journal=/dev/nvme0n1 /dev/sd{b,c,d,e,f,g}

$ sudo mdadm --detail /dev/md1 | grep -i journal
     Journal Device : /dev/nvme0n1
 Consistency Policy : journal
```

```console
# PPL (Partial Parity Log) — RAID 5 ONLY, stored inside the metadata area.
# Far lower overhead than a journal; closes the specific write-hole reconstruction bug.
$ sudo mdadm --create /dev/md2 --level=5 --raid-devices=4 \
    --consistency-policy=ppl /dev/sd{h,i,j,k}

$ cat /sys/block/md2/md/consistency_policy
ppl
```

| Mechanism | Levels | Storage | Write cost | Closes write hole? |
|---|---|---|---|---|
| `resync` (default) | 5, 6 | none | none | **No** — resync assumes clean survivors |
| `bitmap` | all | in-meta/external | low | No (speeds *resync*, not the hole) |
| `ppl` | **5 only** | metadata area | low | **Yes** (Partial Parity Log) |
| `journal` | 5, 6 | dedicated device | high (double write) | **Yes** (also gives write-back cache) |

### 4.7 Assemble, scan, and persist

```console
$ sudo mdadm --assemble --scan                 # assemble everything in mdadm.conf
$ sudo mdadm --assemble /dev/md0 --uuid=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
$ sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
ARRAY /dev/md0 metadata=1.2 name=storage01:0 UUID=3b8f6a21:9c4d0e77:1a2b3c4d:5e6f7a8b
$ sudo update-initramfs -u                      # dracut -f --regenerate-all on RHEL
```

---

## 5. Verification and failure-diagnosis playbook

### 5.1 Continuous monitoring

```console
$ sudo mdadm --monitor --scan --oneshot --test         # fire a TestMessage to MAILADDR now
$ sudo mdadm --monitor --scan --daemonise --mail=storage-team@example.com \
    --program=/usr/local/sbin/md-alert.sh
```

`--monitor` emits events (`Fail`, `FailSpare`, `DegradedArray`, `SpareActive`, `RebuildFinished`, `TestMessage`). Wire `--program` to your alerting (PagerDuty/Prometheus pushgateway). **A degraded array that nobody is paged about is a second failure waiting to become data loss.**

Prometheus users already export this via **`node_exporter`**:

```console
$ curl -s localhost:9100/metrics | grep node_md_
node_md_disks{device="md0",state="active"} 5
node_md_disks{device="md0",state="failed"} 1
node_md_disks_required{device="md0"} 6
node_md_state{device="md0",state="active"} 1
```
Alert rule: `node_md_disks{state="active"} < node_md_disks_required` → degraded.

### 5.2 Data scrubbing — catching *silent* corruption (bit rot)

RAID protects against *disk failure*, not against a block that reads back wrong without an error. A periodic scrub reads every stripe and verifies parity:

```console
$ echo check | sudo tee /sys/block/md0/md/sync_action     # verify only, no writes
$ cat /sys/block/md0/md/sync_action
check
$ watch -n5 cat /sys/block/md0/md/mismatch_cnt
$ cat /sys/block/md0/md/mismatch_cnt
0                                                          # 0 = healthy
```

If `mismatch_cnt` is **non-zero after a `check`**, a stripe is inconsistent. Force a rewrite of parity from data:

```console
$ echo repair | sudo tee /sys/block/md0/md/sync_action
```

> **Caveat:** on RAID 1/10, `md` cannot know *which* mirror copy is correct — `repair` picks the first and overwrites the other. A non-zero count that recurs points at a specific dying drive or a controller/cable fault; investigate `smartctl -a` and kernel logs before trusting `repair`. On swap-backed arrays, transient non-zero counts are normal (the kernel may write pages that are freed mid-flight).

### 5.3 Recovering an array that will not assemble

**Step 1 — compare event counters** across all members:

```console
$ sudo mdadm --examine /dev/sd[b-g] | egrep 'Events|/dev/sd'
/dev/sdb:
         Events : 20418
/dev/sdc:
         Events : 20418
/dev/sdd:
         Events : 20411          # <- stale: dropped out 7 events ago
/dev/sde:
         Events : 20418
/dev/sdf:
         Events : 20418
/dev/sdg:
         Events : 20418
```

**Step 2 — force-assemble from the drives with the highest, consistent event count.** `--force` rewrites the stale member's superblock so the array will start (it will then resync that member):

```console
$ sudo mdadm --assemble --force /dev/md0 /dev/sd{b,c,d,e,f,g}
mdadm: forcing event count in /dev/sdd(2) from 20411 up to 20418
mdadm: /dev/md0 has been started with 6 drives.
```

**Step 3 — last resort: re-create with `--assume-clean`.** Only if the superblocks are destroyed and you *know* the exact original geometry (level, chunk, disk order, data-offset, metadata version — get them from `--examine` output you saved earlier). `--assume-clean` skips the initial resync so it does **not** overwrite data — but a single wrong parameter permanently scrambles the array:

```console
$ sudo mdadm --create /dev/md0 --assume-clean --level=6 --raid-devices=6 \
    --chunk=512 --metadata=1.2 --data-offset=264192s \
    /dev/sdb /dev/sdc missing /dev/sde /dev/sdf /dev/sdg
```

Immediately mount **read-only** and `fsck -n` to confirm the layout is right before writing anything.

### 5.4 Filesystem alignment verification

A correctly aligned filesystem lets one logical write map to whole stripes, avoiding read-modify-write.

- **stride** = chunk ÷ fs-block = 512 KiB ÷ 4 KiB = **128**
- **stripe-width** = stride × *data* disks. RAID 6 over 6 disks = 4 data disks → 128 × 4 = **512**

```console
$ sudo mkfs.ext4 -b 4096 -E stride=128,stripe-width=512 /dev/md0
$ sudo mkfs.xfs -d su=512k,sw=4 /dev/md0        # su=chunk, sw=data-disk count

$ sudo tune2fs -l /dev/md0 | grep -iE 'stride|stripe'
RAID stride:              128
RAID stripe width:        512
```

For RAID 5/6 write throughput, raise the stripe cache (RAM traded for fewer RMW cycles):

```console
$ echo 8192 | sudo tee /sys/block/md0/md/stripe_cache_size    # pages; 8192 = 32 MiB/disk
```

### 5.5 Throttling and un-sticking resync/reshape

```console
$ cat /proc/sys/dev/raid/speed_limit_min      # floor even when array is busy (KB/s/disk)
1000
$ cat /proc/sys/dev/raid/speed_limit_max      # ceiling when array is idle
200000

# Slow a rebuild so it stops starving production I/O:
$ echo 30000 | sudo tee /proc/sys/dev/raid/speed_limit_max

# A resync stuck at "DELAYED" (another array holds the disks) — let it proceed:
$ echo idle  | sudo tee /sys/block/md1/md/sync_action    # pause the other array's sync
```

### 5.6 Rapid triage decision table

| Symptom in `/proc/mdstat` / logs | Likely cause | First action |
|---|---|---|
| `[N/N-1]` with `_` in one slot | One disk failed/dropped | Check `smartctl`, `--remove` faulty, `--add` replacement |
| `(F)` next to a device | Kernel marked it faulty | Inspect `dmesg` for I/O errors before trusting the disk |
| Array won't assemble, `possibly out of date` | Split-brain event counts | `--examine` all, `--assemble --force` from newest |
| `mismatch_cnt` > 0 after scrub | Silent corruption / dying drive | `smartctl -a`; investigate before `repair` |
| Rebuild extremely slow (`speed=`) | `speed_limit_max` throttle or busy array | Check `/proc/sys/dev/raid/*`, raise ceiling |
| `resync=DELAYED` | Another array holds the same disks | Sequence syncs via `sync_action` |
| `inactive` array, no personalities | RAID module/personality not loaded | `modprobe raid456`; check initramfs |
| Reshape frozen after crash | Missing/rotated backup-file | `--assemble --update=revert-reshape --backup-file=…` |

---

## 6. References

- LPI — Exam 306 Objectives (Topic 364.2, Advanced RAID): <https://www.lpi.org/our-certifications/exam-306-objectives/>
- Linux Kernel — `md` administration guide: <https://www.kernel.org/doc/html/latest/admin-guide/md.html>
- Linux RAID Wiki (kernel.org) — RAID setup, recovery, superblock formats: <https://raid.wiki.kernel.org/index.php/Linux_Raid>
- `mdadm(8)` man page: <https://man7.org/linux/man-pages/man8/mdadm.8.html>
- `md(4)` man page (personalities, `sysfs`, layouts): <https://man7.org/linux/man-pages/man4/md.4.html>
- `mdadm.conf(5)` man page: <https://man7.org/linux/man-pages/man5/mdadm.conf.5.html>
- Kernel docs — RAID 5 PPL (Partial Parity Log): <https://www.kernel.org/doc/html/latest/driver-api/md/raid5-ppl.html>
- Kernel docs — RAID 5 cache / write journal: <https://www.kernel.org/doc/html/latest/driver-api/md/raid5-cache.html>
- Linux RAID Wiki — write-intent bitmap: <https://raid.wiki.kernel.org/index.php/Write-intent_bitmap>
- Linux RAID Wiki — RAID recovery / reshaping: <https://raid.wiki.kernel.org/index.php/RAID_Recovery>