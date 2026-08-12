# 364.2 Advanced RAID — Guided Exercises

> **Scope.** These exercises go beyond array creation (364.1) into the operations that keep a single node's storage highly available: write-intent bitmaps, online reshaping, RAID-level migration, write-behind mirrors, the RAID5 write hole and its mitigations (PPL / write-journal), hot device replacement, spare groups, and monitoring. Everything is driven by `mdadm(8)` and the kernel `md` driver.
>
> **Safety.** Every step operates on **loopback devices backed by image files**, never on real disks. You can run the whole thing inside a throwaway VM or container with `root`. Reshape and resync are destructive to whatever they touch — do not point these commands at a `/dev/sdX` you care about.
>
> **A note on the outputs.** Block counts, data offsets, resync speeds and bitmap chunk sizes vary with the `mdadm` version, kernel and device geometry. The listings below are representative; verify the *shape* of the output on your system, not the exact digits.

---

## Lab environment setup

**1.** Create a working directory and six 512 MiB backing files:

```bash
mkdir -p /root/raidlab && cd /root/raidlab
for i in 0 1 2 3 4 5; do truncate -s 512M disk$i.img; done
ls -lh disk*.img
```

**2.** Attach each image to a loop device and confirm:

```bash
for i in 0 1 2 3 4 5; do losetup --find --show disk$i.img; done
```

```
/dev/loop0
/dev/loop1
/dev/loop2
/dev/loop3
/dev/loop4
/dev/loop5
```

```bash
losetup -a | sort
```

**3.** Confirm the `md` personalities the kernel can load and that no arrays exist yet:

```bash
cat /proc/mdstat
```

```
Personalities : [raid6] [raid5] [raid4] [raid1] [raid10]
unused devices: <none>
```

> If a personality you need is missing, `modprobe raid456` / `raid1` / `raid10` loads it. `mdadm --create` normally triggers this automatically.

**Comprehension check**

- **Q1.** Why are loop devices a legitimate stand‑in for `/dev/sdX` when practising `mdadm`, and what class of real‑world behaviour will they *not* reproduce faithfully?
- **Q2.** The `Personalities` line lists `[raid6] [raid5] [raid4]` together. What does that grouping tell you about how the kernel implements those three levels?

---

## Exercise 1 — Write-intent bitmaps

A write-intent bitmap records which regions of the array *may* be out of sync. After an unclean shutdown or a transient device drop, `md` only resyncs the dirty regions instead of the whole array — turning a multi-hour full resync into seconds.

**1.** Create a 3-device RAID5 with an **internal** bitmap:

```bash
mdadm --create /dev/md0 --level=5 --raid-devices=3 \
      --bitmap=internal --assume-clean \
      /dev/loop0 /dev/loop1 /dev/loop2
```

> `--assume-clean` skips the initial parity resync. It is legitimate here because the devices are empty; **never** use it on devices with real data you intend to keep, because parity would be wrong.

**2.** Inspect the array and locate the bitmap:

```bash
cat /proc/mdstat
```

```
Personalities : [raid6] [raid5] [raid4]
md0 : active raid5 loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      bitmap: 0/1 pages [0KB], 65536KB chunk

unused devices: <none>
```

```bash
mdadm --detail /dev/md0 | grep -Ei 'bitmap|state|consistency'
```

**3.** Simulate a transient failure and watch the bitmap-accelerated recovery. Fail and remove one leg, then re-add the *same* device:

```bash
mdadm /dev/md0 --fail /dev/loop2 --remove /dev/loop2
mdadm /dev/md0 --re-add /dev/loop2
cat /proc/mdstat
```

```
md0 : active raid5 loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/2] [UU_]
      [============>........]  recovery = 61.2% (...) finish=0.0min speed=...
      bitmap: 1/1 pages [4KB], 65536KB chunk
```

Because the bitmap was clean (no writes happened while the leg was out), recovery completes almost instantly.

**4.** Convert the bitmap from internal to **external** (a file on another filesystem — useful when bitmap updates would otherwise contend with array I/O):

```bash
mdadm --grow /dev/md0 --bitmap=none
mdadm --grow /dev/md0 --bitmap=/root/raidlab/md0-bitmap
mdadm --detail /dev/md0 | grep -i bitmap
```

> The external bitmap file must **not** live on the array it protects. Put it on independent, reliable storage.

**Comprehension check**

- **Q3.** What is the operational trade-off of a write-intent bitmap, and how does the **bitmap chunk size** (e.g. `65536KB chunk`) sit at the centre of that trade-off?
- **Q4.** After the transient failure in step 3, why was `--re-add` almost instantaneous whereas `--add` of a brand-new device would trigger a full rebuild?
- **Q5.** Give one concrete scenario where an **external** bitmap is preferable to an internal one — and one hard constraint on where that external file may live.

---

## Exercise 2 — Growing an array (reshape by adding devices)

**1.** Put a filesystem on the array and mount it so you can prove data survives the reshape:

```bash
mkfs.ext4 -q /dev/md0
mkdir -p /mnt/md0 && mount /dev/md0 /mnt/md0
echo "before reshape $(date -u +%s)" > /mnt/md0/marker.txt
df -h /mnt/md0
```

**2.** Add a fourth device and grow the array from 3 to 4 members. A reshape rewrites every stripe, so supply a **backup file** on separate storage to protect the critical region during the operation:

```bash
mdadm --add /dev/md0 /dev/loop3
mdadm --grow /dev/md0 --raid-devices=4 \
      --backup-file=/root/raidlab/reshape.bak
```

**3.** Watch the reshape progress:

```bash
cat /proc/mdstat
```

```
md0 : active raid5 loop3[3] loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [4/4] [UUUU]
      [=====>...............]  reshape = 27.8% (145280/522240) finish=0.4min speed=...
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

You may throttle the reshape to protect foreground I/O:

```bash
echo 20000 > /proc/sys/dev/raid/speed_limit_max   # KiB/s ceiling per device
```

**4.** When the reshape finishes, the *array* is bigger but the *filesystem* is not. Grow the filesystem online:

```bash
mdadm --wait /dev/md0
mdadm --detail /dev/md0 | grep -i 'array size'
resize2fs /dev/md0
df -h /mnt/md0
cat /mnt/md0/marker.txt
```

**Comprehension check**

- **Q6.** A reshape must temporarily hold data that is being relocated between the old and new stripe layout. What is the `--backup-file` for, when is it *critical* (which phase of the reshape), and where must it **not** be placed?
- **Q7.** Enlarging the array did not enlarge the mounted `ext4`. Why are these two independent steps, and what is the ordering constraint between them (grow the array first vs. the filesystem first)?
- **Q8.** What is the difference between `dev/raid/speed_limit_min` and `speed_limit_max`, and why might you *raise* the minimum during a degraded rebuild but *lower* the maximum during a routine reshape?

---

## Exercise 3 — RAID-level migration (RAID5 → RAID6)

Reshaping can change the redundancy level, not just the device count. Migrating RAID5 to RAID6 adds a second parity block per stripe, so it requires one additional member.

**1.** Add a fifth device and migrate the level in one command:

```bash
mdadm --add /dev/md0 /dev/loop4
mdadm --grow /dev/md0 --level=6 --raid-devices=5 \
      --backup-file=/root/raidlab/reshape.bak
cat /proc/mdstat
```

```
md0 : active raid6 loop4[4] loop3[3] loop2[2] loop1[1] loop0[0]
      1566720 blocks super 1.2 level 6, 512k chunk, algorithm 2 [5/5] [UUUUU]
      [==>..................]  reshape = 12.1% (...) finish=... speed=...
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

**2.** Confirm the new layout and that data is intact:

```bash
mdadm --wait /dev/md0
mdadm --detail /dev/md0 | grep -Ei 'raid level|layout|raid devices'
md5sum /mnt/md0/marker.txt
```

**3.** Observe the RAID6 layout / parity-rotation algorithm reported by `mdadm`:

```bash
mdadm --detail /dev/md0 | grep -i layout
```

> RAID6's default `layout` is `left-symmetric` (`algorithm 2`). The layout determines how the P and Q parity blocks rotate across devices; it is metadata you rarely change, but `mdadm --grow --layout=...` can reshape it.

**Comprehension check**

- **Q9.** Why does migrating RAID5 → RAID6 require adding a device, while RAID5 → RAID5-with-more-disks also adds a device but for a *different* reason? Distinguish "more capacity" from "more redundancy".
- **Q10.** RAID6 tolerates two simultaneous device failures where RAID5 tolerates one. Beyond "two disks can die," name the specific *degraded-mode* failure mode RAID6 protects against that makes it the default choice for large SATA arrays. (Hint: what can happen to a second disk *during* a RAID5 rebuild?)
- **Q11.** RAID1 → RAID5 is also a supported migration (`mdadm --grow --level=5`). Sketch how a 2-device RAID1 can become a RAID5 without a full data rewrite of the first two members.

---

## Exercise 4 — Write-mostly legs and write-behind (RAID1)

For an asymmetric mirror — e.g. a fast local disk mirrored to a slow or high-latency device (network block device, an SSD mirrored to an HDD) — you can mark the slow leg `write-mostly` so reads avoid it, and enable `write-behind` so writes to it are acknowledged asynchronously. `write-behind` **requires** a bitmap.

**1.** Build a 2-device RAID1 with an internal bitmap, marking `/dev/loop6`'s stand-in as the slow leg. (Reuse `loop5` as the slow leg here.)

```bash
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
      --bitmap=internal --assume-clean \
      /dev/loop0 --write-mostly /dev/loop5
```

> In the real world `loop0` is already in `md0`; for this isolated exercise, first stop `md0` (`umount /mnt/md0 && mdadm --stop /dev/md0`) or substitute two free loop devices. The point is the flags, not the specific members.

**2.** Enable write-behind with a bounded outstanding-write queue:

```bash
mdadm --grow /dev/md1 --write-behind=256
mdadm --detail /dev/md1 | grep -Ei 'state|write'
```

**3.** Verify the flags on the slow member:

```bash
mdadm --examine /dev/loop5 | grep -Ei 'flags|state'
cat /proc/mdstat
```

```
md1 : active raid1 loop5[1](W) loop0[0]
      523264 blocks super 1.2 [2/2] [UU]
      bitmap: 0/1 pages [0KB], 65536KB chunk
```

The `(W)` marker next to `loop5[1]` denotes a `write-mostly` member.

**Comprehension check**

- **Q12.** Explain the read-path and write-path behaviour of a `write-mostly` mirror leg. What does the array gain, and what durability caveat does `write-behind` introduce?
- **Q13.** Why is a write-intent bitmap a hard prerequisite for `write-behind`? (Think about what must be tracked while a write to the slow leg is still outstanding.)
- **Q14.** What does the `256` in `--write-behind=256` bound, and what is the risk of setting it too high on a genuinely slow leg?

---

## Exercise 5 — The RAID5/6 write hole: PPL and write-journal

A power loss during a stripe write can leave data and parity inconsistent (the "write hole"): the array looks clean on reboot but a later single-disk failure reconstructs corrupt data. `md` offers two mitigations.

- **PPL (Partial Parity Log)** — metadata-resident, no extra device, small write-throughput cost. Default-capable for RAID5.
- **Write-journal** — a dedicated (ideally power-loss-protected) journal device that closes the hole fully, at higher cost.

**1.** Rebuild a RAID5 and set its consistency policy to `ppl`:

```bash
mdadm --stop /dev/md1 2>/dev/null
mdadm --create /dev/md0 --level=5 --raid-devices=3 \
      --consistency-policy=ppl --assume-clean \
      /dev/loop0 /dev/loop1 /dev/loop2
mdadm --detail /dev/md0 | grep -i 'consistency policy'
```

```
   Consistency Policy : ppl
```

**2.** Switch policy at runtime (PPL ⇄ resync):

```bash
mdadm --grow /dev/md0 --consistency-policy=resync
mdadm --grow /dev/md0 --consistency-policy=ppl
```

**3.** (Reference) Creating a journalled array uses a dedicated device — you cannot add a journal to an existing array, only at creation:

```bash
# Illustrative — needs a spare device dedicated to the journal:
mdadm --create /dev/md2 --level=5 --raid-devices=3 \
      --write-journal /dev/loop5 \
      /dev/loop3 /dev/loop4 /dev/loop0
mdadm --detail /dev/md2 | grep -Ei 'journal|consistency'
```

**Comprehension check**

- **Q15.** In your own words, describe the RAID5 write hole: what is inconsistent after a crash, why does the array *not* notice at reboot, and when does the inconsistency actually bite the user?
- **Q16.** Compare PPL and a write-journal on three axes: extra hardware, performance cost, and completeness of write-hole closure. When would you pick each?
- **Q17.** Why does a bitmap *not* solve the write hole, even though it also tracks in-flight writes?

---

## Exercise 6 — Hot replacement (`--replace`) and spare groups

**1.** Proactively replace a member that is throwing errors *without* first dropping to a degraded state. `--replace` builds the new member while the old one still participates, preserving redundancy throughout:

```bash
mdadm /dev/md0 --add /dev/loop4              # provide the incoming device as a spare
mdadm /dev/md0 --replace /dev/loop2 --with /dev/loop4
cat /proc/mdstat
```

```
md0 : active raid5 loop4[3](R) loop2[2] loop1[1] loop0[0]
      1044480 blocks super 1.2 level 5, 512k chunk, algorithm 2 [3/3] [UUU]
      [=======>.............]  recovery = 38.0% (...) finish=... speed=...
```

The `(R)` marks the replacement target. When it finishes, `loop2` is dropped automatically.

**2.** Define **spare groups** so `mdadm --monitor` can move a spare from one array to another that has lost redundancy. Write `/etc/mdadm/mdadm.conf` (path is `/etc/mdadm.conf` on some distros):

```bash
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
```

Then edit each `ARRAY` line to add a shared `spare-group` and set the alert address:

```
MAILADDR root@localhost
ARRAY /dev/md0 metadata=1.2 spare-group=lab UUID=...
ARRAY /dev/md2 metadata=1.2 spare-group=lab UUID=...
```

**3.** Verify the config parses and the arrays assemble from it:

```bash
mdadm --assemble --scan --config=/etc/mdadm/mdadm.conf --verbose 2>&1 | tail
```

**Comprehension check**

- **Q18.** Contrast `--replace` with the classic `--fail` → `--remove` → `--add` sequence. During which window is the array vulnerable in each approach, and why is `--replace` the production-preferred move for a *predicted* failure (e.g. rising SMART reallocated-sector count)?
- **Q19.** For a shared spare to migrate between two arrays via `spare-group`, two conditions must hold. Name both — one about the daemon, one about the spare's size.
- **Q20.** Why is it important that `mdadm.conf` pins arrays by **UUID** rather than by kernel device name (`/dev/md0`)?

---

## Exercise 7 — Monitoring and alerting

`mdadm --monitor` polls array state and fires events (`Fail`, `FailSpare`, `DegradedArray`, `SpareActive`, `RebuildFinished`, `MoveSpare`, …) to email, syslog, and an optional program.

**1.** Run a one-shot test that generates a synthetic `TestMessage` for every array (proves mail delivery without breaking anything):

```bash
mdadm --monitor --scan --oneshot --test
```

**2.** Start the monitor as a daemon (in production this is the packaged `mdmonitor.service`):

```bash
mdadm --monitor --scan --daemonise --syslog \
      --mail=root@localhost --delay=300
```

**3.** Trigger a real `Fail`/`DegradedArray` event and read it back from syslog:

```bash
mdadm /dev/md0 --fail /dev/loop1
journalctl -t mdadm --since "5 min ago" | tail
mdadm /dev/md0 --remove /dev/loop1 --re-add /dev/loop1
```

**4.** (Reference) Route events to a custom handler with `--program` / `PROGRAM` in `mdadm.conf`; the script receives the event, the md device, and the related component as `$1 $2 $3`.

**Comprehension check**

- **Q21.** Which event does `mdadm --monitor` treat as *urgent* (mailed immediately regardless of `--delay`), and why is that class special?
- **Q22.** `mdmonitor.service` is normally socket/`ONLYDEGRADED`-aware and started by the packaging, not by hand. What is the risk of running *two* `mdadm --monitor` daemons against the same arrays?
- **Q23.** You configured `MAILADDR` but receive no mail on failure, while `--oneshot --test` also produced nothing. Before blaming `mdadm`, what is the most likely culprit and how would you isolate it?

---

## Exercise 8 — Bad-block log and inspection

`md` keeps a per-device **bad block log**: sectors that failed are recorded so the array stops trusting them, reconstructing that data from parity/mirror instead of ejecting the whole disk on a single sector error.

**1.** Inspect metadata and any recorded bad blocks:

```bash
mdadm --examine /dev/loop0 | grep -Ei 'bad block|feature|data offset'
mdadm --examine-badblocks /dev/loop0
```

**2.** View the feature bitmap that shows whether bad-block-log and bitmap features are enabled:

```bash
mdadm --examine /dev/loop0 | sed -n '/Feature Map/,/Array UUID/p'
```

**Comprehension check**

- **Q24.** How does the bad-block log improve availability compared with the older behaviour of failing an entire disk on the first unreadable sector — and what is the danger if the bad-block list grows large on a *degraded* array?

---

## Teardown

```bash
umount /mnt/md0 2>/dev/null
for m in /dev/md0 /dev/md1 /dev/md2; do mdadm --stop $m 2>/dev/null; done
mdadm --zero-superblock /dev/loop{0..5} 2>/dev/null
losetup -D
rm -f /root/raidlab/*.img /root/raidlab/*.bak /root/raidlab/md0-bitmap
```

> Zeroing the superblock before detaching prevents a stale `md` signature from auto-assembling a phantom array on the next boot.

---

## Sources

- LPI — *Exam 306 Objectives* (306-300, v3.0), objective 364.2: <https://www.lpi.org/our-certifications/exam-306-objectives/>
- `mdadm(8)` — creation, `--grow`, `--replace`, `--monitor`, consistency policy, bitmaps: <https://man7.org/linux/man-pages/man8/mdadm.8.html>
- `md(4)` — kernel software-RAID driver, write-intent bitmap, write-behind, bad-block log: <https://man7.org/linux/man-pages/man4/md.4.html>
- Linux Kernel — *RAID (md)* admin guide (write hole, PPL, journal, reshape): <https://docs.kernel.org/admin-guide/md.html>
- Linux RAID Wiki (kernel.org) — reshaping, growing, recovery procedures: <https://raid.wiki.kernel.org/>

---

<details>
<summary><strong>Answers</strong></summary>

**Q1.** Loop devices expose the same block-device interface `md` consumes, so every `mdadm` command, superblock format, reshape and resync behaves identically — ideal for learning the control plane safely. What they will *not* reproduce: real disk latency/throughput asymmetry, mechanical/SMART failure semantics, sector-level read errors and media defects, controller/cabling faults, and the true cost of a rebuild. They are backed by one underlying file/filesystem, so "independent failure of independent spindles" is a fiction here.

**Q2.** RAID4, RAID5 and RAID6 share one kernel module (`raid456`) because they are the same parity engine with different parity placement: RAID4 = dedicated parity disk, RAID5 = single rotating parity, RAID6 = dual rotating parity (P and Q, the second computed with Reed–Solomon/Galois-field math). Grouping in `Personalities` reflects that shared implementation, which is also why migrating between them is a *reshape* rather than a rebuild from scratch.

**Q3.** Trade-off: a bitmap adds a write to bitmap metadata before/around array writes, costing some throughput and IOPS, in exchange for turning a full-array resync into a dirty-region-only resync after an unclean event. The **bitmap chunk** is the granularity: a *large* chunk (e.g. 64 MiB) means fewer bitmap updates (less overhead) but each dirty bit covers a big region, so recovery resyncs more than strictly necessary; a *small* chunk means finer, faster recovery but more bitmap-update overhead. You tune chunk size to sit between "cheap to maintain" and "cheap to recover".

**Q4.** `--re-add` reinserts the *same* member whose event counter and bitmap the array still recognises. Only the regions marked dirty in the bitmap since the drop are copied, so if nothing was written while it was out, recovery is near-instant. `--add` of a new/foreign device has no shared history — `md` cannot assume any region is in sync, so it performs a full rebuild.

**Q5.** External bitmap is preferable when bitmap-update I/O contends with array I/O on the same spindles, or when the array's own devices are the bottleneck — putting the bitmap on a separate fast, reliable device removes that contention (also useful for very large arrays where you want the bitmap on independent storage). Hard constraint: the external bitmap file must **not** reside on the array it protects (and ideally not on any device that fails together with it), or a failure could take out both data and the recovery metadata simultaneously.

**Q6.** During reshape, stripes are read in the old layout and written in the new layout; there is a "critical section" (typically the start of the array) where old and new data regions overlap, so an interruption mid-write could corrupt data that has no other copy. The `--backup-file` holds that critical region so the operation is restartable/rollback-safe across a crash or reboot. It is critical mainly at the **beginning** of the reshape (and whenever old/new regions overlap). It must **not** live on the array being reshaped — put it on independent storage.

**Q7.** `md` and the filesystem are separate layers: growing the array enlarges the block device, but the filesystem only uses the size it was created/last-resized to. Ordering constraint: you must **grow the array first**, then grow the filesystem into the new space (`resize2fs`, `xfs_growfs`, etc.). Doing it the other way is meaningless — you cannot grow a filesystem past the device it lives on.

**Q8.** `speed_limit_min` is the floor `md` tries to guarantee for resync/rebuild/reshape even under foreground load; `speed_limit_max` is the ceiling it won't exceed when the array is otherwise idle (both in KiB/s, per device). Raise the **min** during a *degraded* rebuild to shrink the vulnerable window (get back to redundancy faster, accepting foreground slowdown). Lower the **max** during a routine reshape on a live system to protect application latency, since there is no urgent redundancy risk.

**Q9.** Adding a device to grow a RAID5's device count buys **capacity** — more data disks, same single-parity redundancy. Migrating RAID5 → RAID6 also adds a device but to buy **redundancy** — the extra member holds the second (Q) parity, tolerating a second failure. Same action (`--add` then `--grow`), different intent: one widens the stripe's data portion, the other widens its parity portion.

**Q10.** RAID6 protects against the **second failure during a RAID5 rebuild**: when one disk dies, a RAID5 rebuild reads *every* sector of *every* surviving disk to reconstruct parity — exactly the workload most likely to surface a latent unrecoverable read error (URE) on a second disk. On large SATA arrays the probability of hitting a URE across a full-array read is non-trivial, so RAID5 rebuilds can fail. RAID6's second parity survives that second fault, which is why it's the default for big arrays.

**Q11.** A 2-device RAID1 already holds two full copies. Converting to RAID5 reinterprets the two members as a degenerate 2-disk RAID5 (one data + one parity, where parity of a single data block equals the data itself), so no data rewrite of the existing content is required for the level change. You then `--add` further members and `--grow --raid-devices=N`, and *that* step reshapes to distribute data and parity across all disks.

**Q12.** A `write-mostly` leg is avoided for **reads** (the array serves reads from the fast leg whenever possible) but still receives all **writes** to stay a valid mirror. Gain: read latency/throughput isn't dragged down by the slow leg. Caveat from `write-behind`: writes to the slow leg are acknowledged to the upper layer *before* they've durably landed there, so a crash can leave the slow leg momentarily behind — the bitmap is what lets the array recover consistency, but the slow leg alone is not guaranteed current at the instant of ack.

**Q13.** `write-behind` acknowledges a write once the fast leg has it, while the slow leg's copy is still in flight. Something must remember that the slow leg has outstanding, not-yet-durable regions so they can be resynced after a crash — that is exactly the write-intent bitmap's job. Without a bitmap there'd be no record of which regions the slow leg still owes, so async writes couldn't be made safe.

**Q14.** `256` bounds the maximum number of outstanding write-behind requests queued to the slow leg. Too high on a genuinely slow leg lets a large backlog of unacknowledged-on-slow-leg writes accumulate, which enlarges the data-loss window if the fast leg dies before the backlog drains, and can consume significant memory. It's a depth/latency-vs-safety knob.

**Q15.** In a RAID5 stripe write, data block(s) and the parity block must be updated together. A crash between those writes leaves parity that no longer matches the data (the "hole"). At reboot the array is marked clean and looks fine — nothing reads parity during normal operation, so the mismatch is invisible. It bites later: when a disk fails and `md` reconstructs the lost block from the *stale/incorrect* parity, it returns silently corrupt data.

**Q16.** 
- **Extra hardware:** PPL needs none (lives in array metadata); a write-journal needs a dedicated device (ideally with power-loss protection, e.g. NVRAM/SSD).
- **Performance cost:** PPL adds a modest write cost; a journal adds a full extra write of journalled data (higher cost, mitigated by a fast journal device).
- **Completeness:** PPL closes the hole for the parity-consistency case but is a *partial* parity log (it doesn't fully journal data); a write-journal closes the hole completely by logging the stripe before committing.
Pick PPL when you want write-hole protection with no extra device and low overhead; pick a write-journal when you need the strongest guarantee and can dedicate a fast, power-safe journal device.

**Q17.** A bitmap only records *which regions may be dirty* so they can be resynced faster — it does **not** store the correct data or parity contents. After a crash it can tell `md` "re-sync this stripe," but re-syncing recomputes parity from whatever data is now on disk, which may already be the half-written, inconsistent state. It accelerates recovery of *known-consistent* data; it cannot reconstruct the atomicity that was lost mid-write.

**Q18.** Classic `--fail`/`--remove`/`--add` drops the array to **degraded** the moment you fail the disk and keeps it degraded for the entire rebuild onto the new disk — a long window with reduced (or zero further) fault tolerance. `--replace` keeps the outgoing disk in service and syncs the incoming one *alongside* it, so redundancy is preserved throughout; only when the replacement is fully in sync is the old disk dropped. For a *predicted* failure (rising SMART reallocated/pending sectors, but the disk still reads) `--replace` is preferred because you never voluntarily give up redundancy.

**Q19.** (1) `mdadm --monitor` must be running as a daemon — it is the component that actually moves spares; the kernel does not do this on its own. (2) The spare must be **at least as large** as the failed member of the target array (and both arrays must share the same `spare-group` name in `mdadm.conf`).

**Q20.** Kernel device names (`/dev/md0`, and underlying `/dev/sdX`) are not stable — they depend on probe order, hotplug, and added/removed controllers, so `md0` today may be different hardware tomorrow. Pinning by **UUID** binds the config to the actual array/member identity in the superblock, so assembly is deterministic and you never accidentally assemble the wrong disks into the wrong array.

**Q21.** `Fail` (and by extension a device failure that degrades or destroys the array) is treated as urgent and is mailed immediately, bypassing the `--delay` batching. It's special because a failed device is time-critical: every minute of delay in alerting is a minute the operator isn't replacing hardware while the array runs without its normal redundancy.

**Q22.** Two monitors polling the same arrays can produce **duplicate alerts** and, worse, **race on spare migration** — both may try to move the same spare or move spares between arrays inconsistently, and both may act on `MoveSpare`/rebuild events simultaneously. Production systems run exactly one instance (the packaged `mdmonitor.service`); starting a second by hand invites conflicting actions.

**Q23.** The most likely culprit is **mail delivery**, not `mdadm`: `--test`/`--oneshot` generates the event and hands it to the local MTA (sendmail/`/usr/sbin/sendmail`), so if no MTA is installed/configured or aliases don't resolve `root`, nothing arrives. Isolate by sending a test mail directly (`echo test | mail -s x root@localhost`), checking the MTA logs, and confirming `MAILADDR`/`--mail` is set — or add a `--program`/`PROGRAM` handler to prove `mdadm` is firing events independently of email.

**Q24.** With a bad-block log, a single unreadable sector is recorded and that sector's data is served/rebuilt from the mirror or parity, keeping the whole disk in service instead of ejecting it on the first error — this avoids needless degradation and cascading rebuilds. The danger on a *degraded* array: there is no second copy/parity margin left to reconstruct a newly logged bad block, so bad blocks accumulating on the *surviving* members during a rebuild can turn into unrecoverable data loss — which is exactly the RAID5-rebuild-URE risk and the argument for RAID6 / proactive `--replace`.

</details>