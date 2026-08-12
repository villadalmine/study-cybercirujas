# 364.3 Advanced LVM — Guided Exercises

> **Exam objective 364.3 — Advanced LVM (weight 5).** These exercises drill the operational skills the objective lists: LVM RAID (levels 0/1/4/5/6/10), RAID integrity and automatic repair, the relationship to `mdadm`/`dmraid`, thin provisioning, thin snapshots, and LVM cache — plus the diagnostic reflexes you need when any of them degrades.
>
> **Safety.** Run everything on **loop devices**, never on a disk that holds data. Every command that mutates state is prefixed with `sudo`. Expected outputs are **illustrative** — UUIDs, loop numbers, extent counts and percentages will differ on your machine. Confirm the *shape* of the output, not the exact digits.
>
> **Prerequisites.** A Linux host with `lvm2` installed and the kernel modules `dm-raid`, `dm-integrity`, `dm-thin-pool` and `dm-cache` available (they load on demand). Verify with `sudo modinfo dm-raid dm-integrity >/dev/null && echo ok`.

---

## Exercise 0 — Build a disposable backing store

You need several independent "disks". We fabricate them from sparse files attached to loop devices.

**Steps**

1. Create six 1 GiB sparse image files:

   ```bash
   for i in 1 2 3 4 5 6; do
     truncate -s 1G /var/tmp/lvmlab-pv$i.img
   done
   ```

2. Attach each to a loop device and print the assigned node:

   ```bash
   for i in 1 2 3 4 5 6; do
     sudo losetup --find --show /var/tmp/lvmlab-pv$i.img
   done
   ```

   ```
   /dev/loop0
   /dev/loop1
   /dev/loop2
   /dev/loop3
   /dev/loop4
   /dev/loop5
   ```

3. Confirm the mapping (numbers on **your** system may differ — always re-check here before copy-pasting later commands):

   ```bash
   losetup -a | grep lvmlab
   ```

   ```
   /dev/loop0: [...] (/var/tmp/lvmlab-pv1.img)
   /dev/loop1: [...] (/var/tmp/lvmlab-pv2.img)
   ...
   ```

> Throughout, substitute the loop nodes you actually got. The text assumes `/dev/loop0`–`/dev/loop5`.

**Check your understanding**

- **Q1.** Why does `truncate -s 1G` return instantly and consume almost no disk, and what risk does that sparseness create if you later fill an LVM thin pool built on top of it?
- **Q2.** A loop device is a block device backed by a file. Which layer of the LVM stack (PV, VG, LV) will you place directly on `/dev/loop0`?

---

## Exercise 1 — The three layers: PV → VG → LV

Before anything "advanced", cement the base vocabulary the tooling reports back at you.

**Steps**

1. Initialise four loop devices as **physical volumes**:

   ```bash
   sudo pvcreate /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3
   ```

   ```
   Physical volume "/dev/loop0" successfully created.
   ...
   ```

2. Create a **volume group** `vg_lab` from them:

   ```bash
   sudo vgcreate vg_lab /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3
   ```

   ```
   Volume group "vg_lab" successfully created
   ```

3. Inspect the three layers with the summary reporters:

   ```bash
   sudo pvs
   sudo vgs
   sudo lvs
   ```

   ```
     PV         VG      Fmt  Attr PSize   PFree
     /dev/loop0 vg_lab  lvm2 a--  1020.00m 1020.00m
     ...
     VG      #PV #LV #SN Attr   VSize  VFree
     vg_lab    4   0   0 wz--n- <3.98g <3.98g
   ```

4. Look at the physical extent (PE) size — the allocation quantum LVM carves everything from:

   ```bash
   sudo vgdisplay vg_lab | grep -E 'PE Size|Total PE|Free  PE'
   ```

   ```
     PE Size               4.00 MiB
     Total PE              1020
     Free  PE / Size       1020 / <3.98 GiB
   ```

5. Create a plain **linear** logical volume so you have a baseline to contrast against RAID:

   ```bash
   sudo lvcreate -L 400M -n lv_linear vg_lab
   sudo lvs -o name,size,segtype,devices vg_lab
   ```

   ```
     LV        LSize   Type   Devices
     lv_linear 400.00m linear /dev/loop0(0)
   ```

**Check your understanding**

- **Q3.** From step 4, how many 4 MiB extents does a 400 MiB logical volume consume, and why is the LV size always a multiple of the PE size?
- **Q4.** In `pvs`, the `Attr` field shows `a--`. What does the first `a` mean, and which two conditions must hold for an LV to be usable data?
- **Q5.** The `segtype` of `lv_linear` is `linear`, mapped to a single PV. What single command reporting field will you keep coming back to in every later exercise to see *how* an LV is laid out across devices?

---

## Exercise 2 — LVM RAID: a redundant mirror (raid1)

LVM RAID does not shell out to `mdadm`. It drives the kernel's **`dm-raid`** device-mapper target, which in turn reuses the MD RAID *personalities* (`raid1`, `raid456`, `raid10`). The array is described entirely by LVM metadata, not by an MD superblock.

**Steps**

1. Create a two-copy mirror (`-m 1` = 1 additional mirror image = 2 images total):

   ```bash
   sudo lvcreate --type raid1 -m 1 -L 300M -n lv_mirror vg_lab
   ```

   ```
     Logical volume "lv_mirror" created.
   ```

2. Reveal the hidden sub-LVs that make up the RAID LV:

   ```bash
   sudo lvs -a -o name,segtype,sync_percent,devices vg_lab
   ```

   ```
     LV                    Type   Cpy%Sync Devices
     lv_mirror             raid1  100.00   lv_mirror_rimage_0(0),lv_mirror_rimage_1(0)
     [lv_mirror_rimage_0]  linear          /dev/loop0(100)
     [lv_mirror_rimage_1]  linear          /dev/loop1(100)
     [lv_mirror_rmeta_0]   linear          /dev/loop0(0)
     [lv_mirror_rmeta_1]   linear          /dev/loop1(0)
   ```

3. Note the two structural roles: `_rimage_N` holds the data copy; `_rmeta_N` holds the small RAID metadata (bitmap of which regions are in sync). Watch a resync complete:

   ```bash
   sudo lvs -o name,sync_percent,raid_sync_action,lv_health_status -a vg_lab/lv_mirror
   ```

4. **Simulate a device replacement.** `/dev/loop4` is still free in the VG. First extend the VG so a spare exists, then swap one leg of the mirror onto it:

   ```bash
   sudo vgextend vg_lab /dev/loop4
   sudo lvconvert --replace /dev/loop1 vg_lab/lv_mirror /dev/loop4
   sudo lvs -a -o name,devices vg_lab/lv_mirror
   ```

   ```
     [lv_mirror_rimage_1]  ...  /dev/loop4(1)
   ```

5. **Understand the true-failure path.** When a PV genuinely dies, the LV attribute string shows a `p` (partial) in the health field and `lvs` reports it under `lv_health_status`. The recovery command is:

   ```bash
   # Only run against a genuinely failed device:
   sudo lvconvert --repair vg_lab/lv_mirror
   ```

**Check your understanding**

- **Q6.** A `raid1` LV with `-m 1` on two 300 MiB legs — how much *usable* capacity does it present, and how much raw VG space did it consume (ignore the tiny `_rmeta`)?
- **Q7.** What is the functional difference between `lvconvert --replace` (step 4) and `lvconvert --repair` (step 5)? When is each the correct tool?
- **Q8.** Why does the `raid1` line show `Cpy%Sync 100.00` while the `_rimage`/`_rmeta` sub-LVs show nothing in that column?

---

## Exercise 3 — Striping and parity: raid0, raid5, raid6, raid10

The objective calls out levels 0, 1, 4, 5, 6 and 10. The `-i` (stripes) flag controls the number of **data** devices; parity/mirror devices are added automatically by the level.

**Steps**

1. Clean the previous LV so the extents are free:

   ```bash
   sudo lvremove -y vg_lab/lv_mirror
   ```

2. Create a **raid5** LV with 3 data stripes (needs 3 + 1 parity = 4 PVs):

   ```bash
   sudo lvcreate --type raid5 -i 3 -L 300M -n lv_r5 vg_lab
   sudo lvs -a -o name,segtype,stripes,devices vg_lab/lv_r5
   ```

   ```
     LV       Type  #Str Devices
     lv_r5    raid5    4  lv_r5_rimage_0(0),lv_r5_rimage_1(0),lv_r5_rimage_2(0),lv_r5_rimage_3(0)
   ```

   Note `#Str` = 4: three data + one distributed parity. `-i` counts **data** stripes only.

3. Contrast the geometry across levels (run each, inspect, then remove before the next to stay within four PVs — or remove `lv_r5` first if you want to build raid10):

   | Level | Command | PVs required | Survives |
   |------|---------|--------------|----------|
   | raid0 | `lvcreate --type raid0 -i 3 -L 300M -n lv_r0 vg_lab` | 3 | no redundancy (striping only) |
   | raid5 | `lvcreate --type raid5 -i 3 -L 300M -n lv_r5 vg_lab` | 4 | 1 device |
   | raid6 | `lvcreate --type raid6 -i 3 -L 300M -n lv_r6 vg_lab` | 5 | 2 devices |
   | raid10 | `lvcreate --type raid10 -i 2 -m 1 -L 300M -n lv_r10 vg_lab` | 4 | 1 per mirror pair |

4. **Scrub** a redundant array — read every block, recompute parity, and count mismatches without correcting them yet:

   ```bash
   sudo lvchange --syncaction check vg_lab/lv_r5
   sudo lvs -o name,raid_sync_action,raid_mismatch_count vg_lab/lv_r5
   ```

   ```
     LV     SyncAction Mismatches
     lv_r5  idle                0
   ```

5. If a scrub reports mismatches, run a correcting pass:

   ```bash
   sudo lvchange --syncaction repair vg_lab/lv_r5
   ```

**Check your understanding**

- **Q9.** For `raid5 -i 3` you supplied `-L 300M`. Is 300 MiB the *usable* size or the *raw* size, and roughly how much raw VG space is consumed?
- **Q10.** Why does raid6 need at least five devices for `-i 3`, and what failure scenario justifies its extra parity block over raid5?
- **Q11.** What is the difference between `--syncaction check` and `--syncaction repair`, and why would you ever choose `check` first?

---

## Exercise 4 — RAID integrity and automatic repair (`--raidintegrity`)

Plain RAID detects a *missing* device, but not silent data corruption (bit rot) on a device that is still online — a scrub only tells you a mismatch exists, not *which* copy is wrong. `--raidintegrity` layers **`dm-integrity`** under each RAID image, storing a checksum per block. On read, a failed checksum is treated as a read error, so the RAID layer reconstructs the block from a good copy and **rewrites it — automatic repair.**

**Steps**

1. Remove any leftover LV to free extents, then create a mirror with integrity enabled:

   ```bash
   sudo lvcreate --type raid1 -m 1 --raidintegrity y -L 200M -n lv_int vg_lab
   sudo lvs -a -o name,segtype,devices vg_lab/lv_int
   ```

   ```
     LV                       Type       Devices
     lv_int                   raid1
     [lv_int_rimage_0]        integrity  lv_int_rimage_0_iorig(0)
     [lv_int_rimage_0_imeta]  linear     /dev/loop0(...)
     [lv_int_rimage_0_iorig]  linear     /dev/loop0(...)
     [lv_int_rimage_1]        integrity  lv_int_rimage_1_iorig(0)
     ...
   ```

   Each `_rimage_N` is now an `integrity` device wrapping the real data (`_iorig`) plus a checksum area (`_imeta`).

2. Choose the integrity **journaling mode**. The default is `bitmap` (fast, tracks dirty regions); `journal` is fully data-journaled (safer across a crash, slower):

   ```bash
   sudo lvs -a -o name,integritymismatches,raidintegritymode vg_lab/lv_int 2>/dev/null || \
   sudo lvs -a -o name,integritymismatches vg_lab/lv_int
   ```

3. Convert integrity **onto an existing** RAID LV, or off again, without recreating it:

   ```bash
   # Add integrity to an existing raid LV:
   #   sudo lvconvert --raidintegrity y vg_lab/<some_raid_lv>
   # Remove it:
   #   sudo lvconvert --raidintegrity n vg_lab/lv_int
   ```

4. Trigger a scrub and read the integrity mismatch counter — the count of blocks whose checksum failed and were repaired from the redundant copy:

   ```bash
   sudo lvchange --syncaction check vg_lab/lv_int
   sudo lvs -o name,integritymismatches vg_lab/lv_int
   ```

   ```
     LV      IntegMismatches
     lv_int                0
   ```

**Check your understanding**

- **Q12.** Plain `raid1` scrub already reports mismatches. What can `--raidintegrity` do that a plain-RAID scrub fundamentally cannot, and why is the per-block checksum the key?
- **Q13.** Why is `--raidintegrity` only available on **redundant** RAID types (raid1/4/5/6/10) and not on raid0 or a linear LV?
- **Q14.** Contrast `--raidintegritymode bitmap` vs `journal`. Which protects data written moments before a power loss, and what does it cost?

---

## Exercise 5 — LVM RAID vs `mdadm` vs `dmraid`

These three touch RAID but are **not** interchangeable. This exercise is observational — you'll confirm where LVM RAID actually lives in the kernel.

**Steps**

1. Confirm the kernel modules the LVM RAID LVs pulled in:

   ```bash
   lsmod | grep -E 'raid1|raid456|raid10|dm_raid|dm_integrity'
   ```

   ```
   dm_raid                ...
   raid456                ...
   raid1                  ...
   ...
   ```

   The `raid1`/`raid456` personalities are the **same code** `mdadm` uses. `dm_raid` is the device-mapper wrapper that lets LVM drive them.

2. Now check `/proc/mdstat` — the classic `mdadm` status file:

   ```bash
   cat /proc/mdstat
   ```

   ```
   Personalities : [raid1] [raid6] [raid5] [raid4]
   unused devices: <none>
   ```

   Your LVM RAID LVs are **absent** here, even though the personalities are loaded. LVM RAID arrays are device-mapper devices, not `md` arrays — they have no `/dev/mdN` node and no MD superblock.

3. See where they *do* appear — the device-mapper table:

   ```bash
   sudo dmsetup ls --target raid
   sudo dmsetup status vg_lab-lv_int
   ```

4. Fix the mental model with a table:

   | Tool | What it manages | Metadata format | Status source |
   |------|-----------------|-----------------|---------------|
   | `mdadm` | Native Linux MD arrays (`/dev/md*`) | MD superblock on-disk | `/proc/mdstat`, `mdadm --detail` |
   | **LVM RAID** | RAID *inside* an LV via `dm-raid` | LVM metadata (VG) | `lvs -a`, `dmsetup status` |
   | `dmraid` | **Firmware/BIOS "fake RAID"** (Intel IMSM, etc.) | vendor on-disk format | `dmraid -s` (legacy; largely superseded by `mdadm`) |

**Check your understanding**

- **Q15.** LVM RAID and `mdadm` load the *same* kernel personalities, yet `/proc/mdstat` shows nothing for your LVM mirror. Why — where does each store its array definition?
- **Q16.** A colleague plugs in a disk from a machine that used motherboard "RAID". Which of the three tools was historically designed to assemble that, and why is it a different category from the other two?
- **Q17.** Given the same two disks, name one operational advantage of building a `raid1` **through LVM** rather than building an `md` device with `mdadm` and putting a PV on top of it.

---

## Exercise 6 — Thin provisioning (thin pool + thin volumes)

A thin pool allocates blocks **on write**, so the sum of thin volume virtual sizes can exceed the pool's physical size (over-provisioning). The pool tracks two separate resources you must monitor: **data** and **metadata**.

**Steps**

1. Free extents from earlier LVs if needed, then create a 500 MiB thin **pool**:

   ```bash
   sudo lvcreate -L 500M --thinpool tpool vg_lab
   sudo lvs -a -o name,segtype,size,data_percent,metadata_percent vg_lab
   ```

   ```
     LV               Type       LSize   Data%  Meta%
     tpool            thin-pool  500.00m 0.00   10.02
     [tpool_tdata]    linear     500.00m
     [tpool_tmeta]    linear       ...
   ```

   Note the hidden `_tdata` (block store) and `_tmeta` (block-address map) sub-LVs.

2. Create two thin volumes, each with a **virtual size larger than the pool** — deliberate over-provisioning:

   ```bash
   sudo lvcreate -V 800M --thin -n thin_a vg_lab/tpool
   sudo lvcreate -V 800M --thin -n thin_b vg_lab/tpool
   sudo lvs -o name,size,pool_lv,data_percent vg_lab
   ```

   ```
     LV     LSize   Pool  Data%
     thin_a 800.00m tpool 0.00
     thin_b 800.00m tpool 0.00
     tpool  500.00m       0.00
   ```

   Two 800 MiB volumes advertise 1.6 GiB from a 500 MiB pool.

3. Write real data into one thin volume and watch the **pool** `Data%` climb (the pool fills, not the individual volume's advertised size):

   ```bash
   sudo mkfs.ext4 /dev/vg_lab/thin_a
   sudo mkdir -p /mnt/thin_a && sudo mount /dev/vg_lab/thin_a /mnt/thin_a
   sudo dd if=/dev/zero of=/mnt/thin_a/fill bs=1M count=200 conv=fsync
   sudo lvs -o name,data_percent,metadata_percent vg_lab/tpool
   ```

   ```
     LV    Data%  Meta%
     tpool 40.xx  10.xx
   ```

4. Inspect the **autoextend safety valve** in the config — the pool can grow itself before it fills:

   ```bash
   sudo lvmconfig --type default activation/thin_pool_autoextend_threshold \
                                 activation/thin_pool_autoextend_percent
   grep -nE 'thin_pool_autoextend' /etc/lvm/lvm.conf
   ```

   ```
   activation/thin_pool_autoextend_threshold=70
   activation/thin_pool_autoextend_percent=20
   ```

   With a threshold of 70, once the pool crosses 70 % full, `lvm` (via `dmeventd`) grows it by 20 %.

**Check your understanding**

- **Q18.** You have two 800 MiB thin volumes on a 500 MiB pool. What happens to writes when the *pool's* `Data%` reaches 100 % — and what does a filesystem on `thin_b` experience even if `thin_b` looks 90 % empty?
- **Q19.** The pool has both `Data%` and `Meta%`. Why is running out of **metadata** at least as dangerous as running out of data space, and what is the failure symptom?
- **Q20.** With `thin_pool_autoextend_threshold = 100`, autoextend is effectively disabled. Why does the LVM documentation warn against leaving it at 100 on an over-provisioned pool, and what daemon must be running for autoextend to fire?

---

## Exercise 7 — Thin snapshots vs classic snapshots

A classic (thick) snapshot needs a pre-sized copy-on-write area and degrades as it fills. A **thin snapshot** lives in the same pool as its origin, shares unchanged blocks, needs no size argument, and can itself be snapshotted.

**Steps**

1. Take a **thin snapshot** of `thin_a` (no `-L` — it draws from the pool on demand):

   ```bash
   sudo lvcreate --snapshot --name thin_a_snap vg_lab/thin_a
   sudo lvs -o name,origin,pool_lv,lv_attr vg_lab
   ```

   ```
     LV          Origin Pool  Attr
     thin_a      thin_a tpool Vwi-aotz--
     thin_a_snap thin_a tpool Vwi---tz-k
   ```

   Note the snapshot's attr ends in `k` — **skip activation**. Thin snapshots are created inactive by default.

2. Activate it explicitly, overriding the skip flag with `-K`:

   ```bash
   sudo lvchange -ay -K vg_lab/thin_a_snap
   sudo lvs -o name,lv_attr vg_lab/thin_a_snap
   ```

   ```
     LV          Attr
     thin_a_snap Vwi-a-tz--
   ```

3. Prove the snapshot is independent — mount it read-only and confirm it holds the origin's data at snapshot time, then keep writing to the origin:

   ```bash
   sudo mkdir -p /mnt/snap && sudo mount -o ro /dev/vg_lab/thin_a_snap /mnt/snap
   ls -l /mnt/snap/fill
   sudo dd if=/dev/zero of=/mnt/thin_a/more bs=1M count=50 conv=fsync
   sudo lvs -o name,data_percent vg_lab/tpool
   ```

4. Contrast with a **classic** snapshot on a thick LV. This one *requires* a size and lives outside any pool:

   ```bash
   sudo lvcreate -L 100M -s -n lin_snap vg_lab/lv_linear
   sudo lvs -o name,origin,lv_size,data_percent vg_lab/lin_snap
   ```

   ```
     LV       Origin    LSize   Data%
     lin_snap lv_linear 100.00m 0.00
   ```

   If writes to `lv_linear` overflow this 100 MiB CoW area, the classic snapshot is **dropped (invalidated)**.

**Check your understanding**

- **Q21.** Why does a thin snapshot take **no** size argument while a classic snapshot demands `-L`, and where do a thin snapshot's changed blocks come from?
- **Q22.** What is the practical consequence of the `k` (skip-activation) attribute on a thin snapshot, and which flag re-activates it?
- **Q23.** A classic snapshot silently becomes "Invalid" under heavy origin writes. Which thin-pool resource plays the analogous "run dry" role for thin snapshots, and how do you observe it?

---

## Exercise 8 — LVM cache (fast device fronting a slow LV)

LVM cache places hot blocks of a slow "origin" LV onto a fast device (SSD/NVMe). We simulate the fast device with `/dev/loop5` (pretend it's SSD).

**Steps**

1. Make sure `/dev/loop5` is a PV in the VG (add it if not):

   ```bash
   sudo vgextend vg_lab /dev/loop5 2>/dev/null; sudo pvs -o pv_name,vg_name /dev/loop5
   ```

2. **Single-step cache with a cache volume** (`--cachevol`, the modern form). Attach a 300 MiB fast cache to `lv_linear`:

   ```bash
   sudo lvcreate -L 300M -n fastcache vg_lab /dev/loop5
   sudo lvconvert --type cache --cachevol fastcache vg_lab/lv_linear
   sudo lvs -a -o name,segtype,cachemode,devices vg_lab/lv_linear
   ```

   ```
     LV        Type  CacheMode    Devices
     lv_linear cache writethrough lv_linear_corig(0)
   ```

3. Read the live cache statistics (hits, misses, dirty blocks) from device-mapper:

   ```bash
   sudo dmsetup status vg_lab-lv_linear
   ```

   ```
   0 819200 cache 8 74/1024 128 ... <read_hits> <read_misses> <write_hits> <write_misses> ... writethrough ...
   ```

4. **Switch cache mode** to `writeback` (acknowledges writes once they hit the cache — faster, but data is at risk if the cache device dies before flushing):

   ```bash
   sudo lvchange --cachemode writeback vg_lab/lv_linear
   sudo lvs -o name,cachemode vg_lab/lv_linear
   ```

   ```
     LV        CacheMode
     lv_linear writeback
   ```

5. **Detach the cache cleanly.** `--uncache` flushes dirty blocks back to the origin, then removes the cache:

   ```bash
   sudo lvconvert --uncache vg_lab/lv_linear
   sudo lvs -o name,segtype vg_lab/lv_linear
   ```

   ```
     LV        Type
     lv_linear linear
   ```

6. *(Reference)* The older two-object form uses a **cache pool** (a fast data LV + separate metadata LV) attached with `--cachepool`:

   ```bash
   # sudo lvcreate --type cache-pool -L 300M -n cpool vg_lab /dev/loop5
   # sudo lvconvert --type cache --cachepool vg_lab/cpool vg_lab/lv_linear
   ```

**Check your understanding**

- **Q24.** What is the difference between `--cachevol` and `--cachepool`, and which one keeps cache metadata in a *separate* hidden LV?
- **Q25.** Under `writethrough`, is any data ever lost if the cache device fails outright? Answer the same for `writeback`, and explain the acknowledgement difference that causes it.
- **Q26.** Why is `lvconvert --uncache` the correct teardown for a `writeback` cache rather than just `lvremove` on the cache volume, and what does it flush?

---

## Exercise 9 — Diagnostics, repair reflexes, and teardown

The one report string you should be able to write from memory, plus the repair paths for a corrupt thin pool — then clean up completely.

**Steps**

1. The "everything about layout and health" one-liner:

   ```bash
   sudo lvs -a -o +devices,segtype,sync_percent,raid_sync_action,lv_health_status,data_percent,metadata_percent vg_lab
   ```

2. Decode an LV attribute string. For a thin volume `Vwi-aotz--`, walk the positions: `V`=thin volume, `w`=writeable, `i`=inherited allocation, `a`=active, `o`=open (mounted), `t`=thin-pool-related target, `z`=zeroing:

   ```bash
   sudo lvs -o name,lv_attr vg_lab
   ```

3. **Offline thin-pool metadata check/repair** (the pool must be inactive). `thin_check` validates the metadata; `lvconvert --repair` rebuilds a corrupt pool's metadata into spare space:

   ```bash
   # Validate (read-only):
   #   sudo thin_check /dev/mapper/vg_lab-tpool_tmeta
   # Repair a damaged pool:
   #   sudo lvconvert --repair vg_lab/tpool
   ```

4. **Full teardown.** Unmount, remove LVs, drop the VG, wipe PVs, detach loop devices, delete images:

   ```bash
   sudo umount /mnt/thin_a /mnt/snap 2>/dev/null
   sudo vgchange -an vg_lab
   sudo vgremove -y vg_lab
   sudo pvremove -y /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5
   for d in /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5; do
     sudo losetup -d "$d" 2>/dev/null
   done
   rm -f /var/tmp/lvmlab-pv*.img
   ```

5. Confirm the machine is clean:

   ```bash
   sudo vgs; sudo pvs; losetup -a | grep lvmlab || echo "no loop images left"
   ```

**Check your understanding**

- **Q27.** In the attribute string, what does an `p` in the health/state position tell you about the underlying devices, and which command from Exercise 2 addresses it?
- **Q28.** Why must a thin pool be **inactive** before `lvconvert --repair` or `thin_check` operate on it, and where does `--repair` write the rebuilt metadata?
- **Q29.** Teardown does `vgchange -an` before `vgremove`. Why deactivate first, and what error would you hit if a thin volume were still mounted?

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** `truncate` only sets the file's *logical* length in the inode; no data blocks are allocated until something writes to them, so it is instant and near-zero cost. The risk: a thin pool trusts that its backing store is real. If the sparse images collectively demand more blocks than the underlying filesystem has, the *host* filesystem fills up, writes into the pool fail with `ENOSPC`, and the thin pool goes read-only or errors — data loss that LVM cannot foresee because the shortage is a layer below it.

**Q2.** The **PV**. `pvcreate /dev/loop0` writes LVM label/metadata onto the loop block device, making it a physical volume. VGs are logical containers over a set of PVs; LVs are carved from the VG — neither is placed on a raw device directly.

**Q3.** 100 extents (400 MiB ÷ 4 MiB). LVM allocates space only in whole physical extents, so any LV size is rounded up to a multiple of the PE size; you cannot allocate a fraction of an extent.

**Q4.** The first `a` means **allocatable** — LVM may place extents on this PV. For an LV to serve data it must be (1) **active** (`a` in its own attr, mapped by device-mapper) and (2) have all its underlying PVs present; a missing PV leaves it partial/inactive.

**Q5.** `lvs -a -o +devices` (adding `segtype`, `sync_percent`, etc. as needed). The `-a` exposes hidden sub-LVs and `+devices` shows the physical placement — the field you consult in every RAID/thin/cache exercise.

**Q6.** Usable: **300 MiB** (a 2-way mirror shows one copy's worth). Raw consumed: **~600 MiB** (two full data images), plus a couple of extents for the two `_rmeta` sub-LVs. A mirror trades half the raw capacity for a full second copy.

**Q7.** `--replace` swaps a *working but unwanted* device (e.g. migrating off a disk you plan to retire) — the source is still healthy. `--repair` reconstructs redundancy after a device has *actually failed*, allocating a fresh image on a spare PV and resyncing from the survivors. Use `--replace` for planned moves, `--repair` for failures.

**Q8.** The top-level `raid1` LV is the RAID target and owns the sync state, so it reports the aggregate `Cpy%Sync`. The `_rimage`/`_rmeta` sub-LVs are plain `linear` mappings that merely provide storage to the RAID target; they have no independent sync concept, so the column is blank for them.

**Q9.** `-L 300M` is the **usable** size. raid5 stores usable data across N−1 of N devices (one device's worth is parity), so with 3 data stripes the raw consumption is roughly 300 MiB × 4/3 ≈ **400 MiB** plus small metadata — i.e. one extra stripe's worth for parity.

**Q10.** raid6 keeps **two** independent parity blocks (P and Q), so it needs two devices beyond the data stripes: 3 data + 2 parity = 5. Its justification is surviving a **second** disk failure — especially a failure that occurs *during* the rebuild of a first failure, when a raid5 array has no remaining redundancy.

**Q11.** `check` reads all blocks and *counts* mismatches without changing anything (safe, diagnostic). `repair` reads, then *rewrites* the correct data/parity to eliminate mismatches. You run `check` first to learn whether the array is silently diverging before deciding to mutate data, and to schedule periodic scrubs cheaply.

**Q12.** Plain RAID scrub can tell that two copies *differ* but not *which one is correct* — it has no ground truth, so on raid1 it typically just overwrites one with the other. `--raidintegrity` stores a checksum per block, so a corrupt block **fails its checksum on read** and is reported as an I/O error; the RAID layer then knows that copy is bad and reconstructs from the verified-good copy, rewriting it. The checksum is the missing ground truth that turns "they differ" into "this one is wrong."

**Q13.** Automatic repair depends on having a *redundant* copy to reconstruct from. raid0 and linear have no redundancy — detecting a bad block via checksum would let you *report* corruption but never *repair* it — so LVM only offers `--raidintegrity` on the redundant levels (1/4/5/6/10).

**Q14.** `bitmap` (default) records which regions are dirty and is fast, but a block being written across a crash may be left inconsistent. `journal` writes data to a journal first and then to the final location, so a write that was in flight at power loss is recoverable — at the cost of writing the data twice, roughly halving write throughput.

**Q15.** `mdadm` writes an **MD superblock** onto the member disks and the array appears as `/dev/mdN` in `/proc/mdstat`. LVM RAID stores the array definition inside the **VG's LVM metadata** and instantiates it as a **device-mapper** device via the `dm-raid` target — it never registers an `md` array, so `/proc/mdstat` (which only lists MD arrays) shows nothing. Look in `dmsetup`/`lvs` instead.

**Q16.** `dmraid` (and today usually `mdadm` with the appropriate metadata handler) assembles **firmware/BIOS "fake RAID"** — arrays defined by a vendor on-disk format (Intel IMSM, etc.) so the BIOS can boot from them. It is a different category because the RAID layout is dictated by an external firmware standard, not created and owned by Linux (`mdadm`) or by LVM.

**Q17.** LVM RAID keeps everything in one management domain: you can grow, snapshot, cache, add/remove integrity, and move the RAID LV with the same `lvconvert`/`lvresize` tooling and one metadata store — no separate `md` device to assemble, and RAID + volume management stay in sync. (Trade-off: `mdadm` exposes some tuning and `/proc/mdstat` monitoring that LVM abstracts away.)

**Q18.** When the *pool* hits 100 % data, any write that needs a new block fails — the thin pool errors or goes read-only (per its configured behaviour). A filesystem on `thin_b` sees write failures / I/O errors **even though `thin_b` itself looks 90 % empty**, because "empty" refers to its virtual address space, while the physical blocks come from the shared, now-exhausted pool.

**Q19.** Thin metadata maps every logical block to its physical location; if metadata space is exhausted the pool can no longer record *where* new (or even remapped) blocks go, so the whole pool goes read-only/faulted regardless of free data space. Symptom: the pool flips to read-only, `Meta%` at ~100 %, kernel logs about metadata being full — and recovery may require offline `thin_check`/`--repair`.

**Q20.** At threshold 100 the pool never auto-grows, so an over-provisioned pool will silently run to 100 % and start failing writes with no safety margin. LVM recommends a threshold well under 100 (default 70) so it extends *before* exhaustion. Autoextend is driven by monitoring — the **`dmeventd`** daemon (with the thin monitoring plugin) must be running for the extend to fire.

**Q21.** A thin snapshot shares the origin's blocks and only allocates *new* blocks (for changed data) from the **shared pool** on demand — there is no fixed CoW area to size. A classic snapshot has a dedicated, pre-allocated CoW region outside any pool, so you must state its size with `-L`; that region is finite and fills.

**Q22.** The `k` (skip-activation) attribute means the volume is **not** auto-activated on `vgchange -ay` or at boot — a guard so many snapshots don't all activate accidentally. You re-activate it explicitly with `lvchange -ay -K <lv>` (the `-K` overrides the skip flag).

**Q23.** The thin **pool's data (and metadata) space** is the shared resource. If the pool runs dry, snapshots and origins alike can no longer allocate changed blocks and the pool faults. Observe it with `lvs -o data_percent,metadata_percent` on the pool — the analogue of watching a classic snapshot's `Data%` approach 100 %.

**Q24.** `--cachevol` uses a **single** fast LV that holds both cache data and its metadata internally (simpler, newer). `--cachepool` is the older model: a `cache-pool` object composed of a separate data LV **and** a separate hidden metadata LV. The cachepool form is the one that keeps metadata in a distinct hidden LV.

**Q25.** `writethrough`: **no** data loss if the cache device fails — every write is committed to the slow origin *before* being acknowledged, so the origin is always current; you only lose the performance benefit. `writeback`: writes are acknowledged as soon as they land in the cache, so blocks marked "dirty" that haven't been flushed to the origin are **lost** if the cache device dies. The difference is *when* the write is acknowledged relative to reaching the origin.

**Q26.** `--uncache` first **flushes all dirty (writeback) blocks back to the origin**, guaranteeing the origin is consistent, and only then removes the cache — the safe, data-preserving teardown. Just `lvremove`-ing the cache volume would discard un-flushed dirty blocks and corrupt the origin.

**Q27.** A `p` means the LV is **partial** — one or more underlying PVs are missing/failed, so not all of the LV's data is present. For a redundant RAID LV the fix is `lvconvert --repair` (reconstruct onto a spare); for a non-redundant LV it signals unrecoverable missing data and you restore from backup / `vgreduce --removemissing`.

**Q28.** `--repair`/`thin_check` need a stable, unchanging view of the metadata; an active pool has the kernel target reading and mutating that metadata concurrently, which the offline tools cannot safely operate against. `lvconvert --repair` writes a **rebuilt copy** of the metadata into spare pool metadata space (it does not overwrite the suspect metadata in place), so you can inspect before committing.

**Q29.** `vgchange -an` deactivates (unmaps) all LVs so device-mapper releases them; `vgremove` refuses to delete a VG whose LVs are still active/open. If a thin volume were still mounted, deactivation (and thus removal) fails with a "logical volume in use" / "contains a filesystem in use" error — you must `umount` first.

</details>

---

### Sources

- LPI — Exam 306 Objectives (364.3 Advanced LVM): https://www.lpi.org/our-certifications/exam-306-objectives/
- `lvmraid(7)` — LVM RAID, integrity and scrubbing: https://man7.org/linux/man-pages/man7/lvmraid.7.html
- `lvmthin(7)` — thin provisioning and thin snapshots: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- `lvmcache(7)` — cache volumes, cache pools and modes: https://man7.org/linux/man-pages/man7/lvmcache.7.html
- `lvcreate(8)` / `lvconvert(8)` / `lvchange(8)`: https://man7.org/linux/man-pages/man8/lvcreate.8.html · https://man7.org/linux/man-pages/man8/lvconvert.8.html · https://man7.org/linux/man-pages/man8/lvchange.8.html
- `lvm.conf(5)` — `thin_pool_autoextend_threshold`/`_percent` and activation settings: https://man7.org/linux/man-pages/man5/lvm.conf.5.html
- `dmsetup(8)` — inspecting device-mapper targets (`status`, `table`, `ls`): https://man7.org/linux/man-pages/man8/dmsetup.8.html