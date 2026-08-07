# LPI BSD Specialist (Exam 702-100) — Topic 712.2: Create File Systems and Maintain their Integrity

**Exam Topic Weight:** 1.67  
**Target Level:** Senior SRE / Principal Platform Architect  
**Primary Reference:** [LPI BSD Specialist Certification Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## 1. Architectural Foundations & Internal Mechanics

Modern BSD systems (FreeBSD, OpenBSD, NetBSD) rely on two core file system architectures: the traditional **Unix File System (UFS/UFS2)** and the modern **Zettabyte File System (ZFS)**. Understanding the low-level disk layouts, integrity maintenance models, and trade-offs of both is essential for production operations.

```
+-----------------------------------------------------------------------------------+
|                                 UFS2 Architecture                                 |
+-----------------------------------------------------------------------------------+
|  Boot Block | Superblock | Cylinder Group 0 | Cylinder Group 1 | ... | CG (n)      |
|             | (Backup 1) | Inodes | Data    | Inodes | Data    |     | Inodes | Data|
+-----------------------------------------------------------------------------------+
  - Structural metadata fixed at creation (Inodes, Block/Frag ratio).
  - Synchronous or Soft Updates (SU / SU+J) dependency ordering.
  - Offline repair required for structural inconsistencies (fsck_ffs).

+-----------------------------------------------------------------------------------+
|                                 ZFS Architecture                                  |
+-----------------------------------------------------------------------------------+
|  zpool (VDEV 1: Mirror / RAIDZ)  <--->  zpool (VDEV 2: Mirror / RAIDZ)            |
|  +-----------------------------------------------------------------------------+  |
|  | Merkle Tree Architecture (Root Uberblock -> Indirect Blocks -> Data Blocks) |  |
|  | - Copy-on-Write (CoW): Writes never overwrite existing active data blocks.   |  |
|  | - End-to-End Checksumming: Stored in parent block pointer (Self-Healing).   |  |
|  | - Dynamic Allocation: Inodes allocated dynamically; no fixed limits.       |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### UFS2 (Unix File System 2) Mechanics
- **Layout & Metadata Structure**: UFS2 organizes disk slices into **Cylinder Groups**. Each cylinder group contains a backup superblock, block headers, an inode table, and data blocks. 
- **Block & Fragment Sizes**: UFS splits file system blocks into smaller units called **fragments** (typically 32KB block / 4KB fragment or 16KB / 2KB) to minimize internal fragmentation for small files.
- **Inode Allocation**: Inodes are statically allocated during file system creation via `newfs`. Exhausting inodes results in an `ENOSPC` (No space left on device) error even if raw disk bytes remain free.
- **Consistency Models**:
  - **Async Writes**: High performance, extreme risk of corrupted file system states upon ungraceful panic or outage.
  - **Soft Updates (SU)**: Tracks block dependencies in RAM to guarantee that on-disk structure invariant rules are met (e.g., directory entry pointing to an inode only after inode initialization). Eliminates the need for synchronous metadata writes without compromising structural integrity.
  - **Soft Updates with Journaling (SU+J)**: Logs metadata changes to an intent journal within the file system, reducing reboot fsck repair times from hours to seconds.

### ZFS (Zettabyte File System) Mechanics
- **Pooled Storage Model**: Decouples physical disk management from dataset management. Physical disks form Storage Pools (`zpools`) using Virtual Devices (`vdevs` like mirror, raidz1, raidz2). Datasets share the pooled capacity dynamically.
- **Copy-on-Write (CoW)**: ZFS never mutates data in-place. Modifying a block allocates a new block, writes updated data, and updates the parent block pointer up to the root **Uberblock**.
- **Merkle Tree & Self-Healing**: Every parent block pointer contains a cryptographic checksum (Fletcher4, SHA-256, or xxHash) of its child blocks. During reads or background **scrubs**, ZFS validates data against the checksum. If corruption (bit rot) is detected on a redundant pool (Mirror/RAIDZ), ZFS fetches the correct copy from the mirror/parity, repairs the corrupt block on disk, and returns valid data to the application transparently.
- **Metaslabs & Space Allocation**: ZFS splits pool space into metaslabs. When pool capacity exceeds 80–90%, ZFS switches allocation algorithms from first-fit to best-fit, resulting in massive write latency spikes and severe fragmentation.

---

## 2. Hands-on Guided Lab Exercises

### System Environment Assumptions
- **Host**: FreeBSD 14.x / OpenBSD 7.x
- **Target Disks**: Unpartitioned block devices `/dev/da1` and `/dev/da2` (or `sd1`, `sd2` on OpenBSD).

---

### Exercise 1: UFS2 File System Provisioning, Tuning, and Corruption Diagnostics

#### Objective
Provision a customized UFS2 file system, configure performance tuning parameters (`tunefs`), inspect raw disk metadata (`dumpfs`), simulate an ungraceful shutdown, and perform offline structural repair (`fsck_ffs`).

#### Execution Steps

1. **Partition the target disk and create a GPT partition table.**
   ```bash
   gpart create -s gpt /dev/da1
   gpart add -t freebsd-ufs -l ufs_data -a 4k /dev/da1
   ```
   *Expected Output:*
   ```text
   da1 created
   da1p1 added
   ```

2. **Format the partition using `newfs` with customized block (32KB) and fragment (4KB) sizes, disabling default Soft Updates initially.**
   ```bash
   newfs -U -b 32768 -f 4096 -L PRODUCTION_UFS /dev/da1p1
   ```
   *Expected Output:*
   ```text
   /dev/da1p1: 10240.0MB (20971520 sectors) block size 32768, fragment size 4096
           using 17 cylinder groups of 602.41MB, 19277 blks, 77312 inodes.
           with Soft Updates
   super-block backups (for fsck_ffs -b #) at:
    192, 1233920, 2467648, 3701376, 4935104, 6168832, 7402560, 8636288,
    9870016, 11103744, 12337472, 13571200, 14804928, 16038656, 17272384
   ```

3. **Inspect file system flags and superblock metadata using `tunefs` and `dumpfs`.**
   ```bash
   tunefs -p /dev/da1p1
   ```
   *Expected Output:*
   ```text
   tunefs: POSIX.1e ACLs: (-a)                                disabled
   tunefs: NFSv4 ACLs: (-N)                                  disabled
   tunefs: MAC multi-label: (-l)                             disabled
   tunefs: soft updates: (-U)                                 enabled
   tunefs: soft updates journaling: (-j)                      disabled
   tunefs: gjournal: (-J)                                    disabled
   tunefs: trim: (-t)                                        disabled
   tunefs: maximum contiguous blks: (-maxb)                   16
   tunefs: space hold back: (-m)                             8%
   tunefs: optimization preference: (-o)                     time
   ```

4. **Enable Soft Updates with Journaling (SU+J) to accelerate crash recovery.**
   ```bash
   tunefs -j enable /dev/da1p1
   ```
   *Expected Output:*
   ```text
   tunefs: Soft Updates Journaling set to enabled
   tunefs: /dev/da1p1: file system is clean; journal initialized
   ```

5. **Configure `/etc/fstab` entry for production mount with trim enabled for SSD efficiency.**
   ```bash
   echo "/dev/ufs/PRODUCTION_UFS /mnt/ufs_production ufs rw,noatime 2 2" >> /etc/fstab
   mkdir -p /mnt/ufs_production
   mount /mnt/ufs_production
   ```

6. **Simulate file system structural state analysis using `dumpfs` to identify cylinder group 0 metadata locations.**
   ```bash
   dumpfs /dev/da1p1 | head -n 25
   ```
   *Expected Output:*
   ```text
   magic   19540119 (UFS2) format  dynamic time    Thu Aug  6 20:28:29 2026
   sblkno  24      cblkno  32      iblkno  56      dblkno  2456
   sbsize  28672   cgsize  32768   csaddr  2456    cssize  4096
   cgmask  0xffffffff      size    2621440 blocks  2621440
   fsbtodb 3       ipg     77312   fpg     154217
   bsize   32768   fsize   4096    frag    8
   ...
   ```

7. **Simulate a forced non-clean unmount and execute interactive/non-interactive `fsck_ffs` verification.**
   ```bash
   umount /mnt/ufs_production
   fsck_ffs -fy /dev/da1p1
   ```
   *Expected Output:*
   ```text
   ** /dev/da1p1
   ** File system is already clean
   ** Last Mounted on /mnt/ufs_production
   ** Phase 1 - Check Blocks and Sizes
   ** Phase 2 - Check Pathnames
   ** Phase 3 - Check Connectivity
   ** Phase 4 - Check Reference Counts
   ** Phase 5 - Check Cyl groups
   0 files, 4 used, 2552835 free (0 frags, 319104 blocks, 0.0% fragmentation)
   
   ***** FILE SYSTEM MARKED CLEAN *****
   ```

---

#### Verification Questions (Exercise 1)

**Question 1.1**: What is the architectural purpose of preserving the 8% default minimum free space reserve (`tunefs -m 8%`) in UFS2, and what happens to non-root user write operations when disk usage crosses 92%?  
**Question 1.2**: If the primary superblock at block 24 becomes physically unreadable due to bad sectors, which utility and command syntax must be executed to repair the file system using a redundant backup superblock identified during `newfs`?  
**Question 1.3**: How does Soft Updates with Journaling (SU+J) differ structurally from standard Soft Updates (SU) during system crash recovery?

---

### Exercise 2: ZFS Pool Architecture, Dataset Provisioning, and Integrity Scrubbing

#### Objective
Build a mirrored ZFS pool, configure production dataset properties (compression, quotas, reservations, checksums), simulate silent data corruption directly on the underlying storage layer using `dd`, and demonstrate ZFS end-to-end self-healing via `zpool scrub`.

#### Execution Steps

1. **Construct a mirrored ZFS storage pool named `tank` using two dedicated block devices.**
   ```bash
   zpool create -f -o ashift=12 tank mirror /dev/da1 /dev/da2
   ```
   *Expected Output:*
   ```text
   (Command completes silently on success)
   ```

2. **Verify pool status and topology.**
   ```bash
   zpool status tank
   ```
   *Expected Output:*
   ```text
     pool: tank
    state: ONLINE
     scan: none requested
   config:

           NAME        STATE     READ WRITE CKSUM
           tank        ONLINE       0     0     0
             mirror-0  ONLINE       0     0     0
               da1     ONLINE       0     0     0
               da2     ONLINE       0     0     0

   errors: No known data errors
   ```

3. **Provision a secure multi-tenant production dataset hierarchy with enforced performance and safety properties.**
   ```bash
   zfs create tank/dbdata
   zfs set compression=lz4 tank/dbdata
   zfs set atime=off tank/dbdata
   zfs set recordsize=16k tank/dbdata
   zfs set quota=50G tank/dbdata
   zfs set reservation=10G tank/dbdata
   zfs set redundant_metadata=most tank/dbdata
   ```

4. **Verify dataset properties configuration.**
   ```bash
   zfs get compression,atime,recordsize,quota,reservation tank/dbdata
   ```
   *Expected Output:*
   ```text
   NAME         PROPERTY     VALUE    SOURCE
   tank/dbdata  compression  lz4      local
   tank/dbdata  atime        off      local
   tank/dbdata  recordsize   16k      local
   tank/dbdata  quota        50G      local
   tank/dbdata  reservation  10G      local
   ```

5. **Generate a test file containing random data inside the ZFS dataset.**
   ```bash
   dd if=/dev/urandom of=/tank/dbdata/critical_payload.bin bs=1M count=100
   sha256 /tank/dbdata/critical_payload.bin
   ```
   *Expected Output:*
   ```text
   100+0 records in
   100+0 records out
   104857600 bytes transferred in 0.421054 secs (249035989 bytes/sec)
   SHA256 (/tank/dbdata/critical_payload.bin) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   ```

6. **Simulate raw physical bit rot by injecting zero-byte corruption directly into the underlying `/dev/da1` drive bypassing the ZFS driver stack.**
   ```bash
   dd if=/dev/zero of=/dev/da1 bs=1M seek=50 count=10 conv=notrunc
   ```
   *Expected Output:*
   ```text
   10+0 records in
   10+0 records out
   10485760MB transferred...
   ```

7. **Initiate an asynchronous ZFS scrub to detect and automatically repair the injected corruption.**
   ```bash
   zpool scrub tank
   ```

8. **Monitor scrub execution status and inspect the self-healing telemetry output.**
   ```bash
   zpool status -v tank
   ```
   *Expected Output:*
   ```text
     pool: tank
    state: ONLINE
   status: One or more devices repaired corrupt data. The log contains
           exceptions.
   action: No known repair errors.
     scan: scrub repaired 10.0M in 00:00:02 with 0 errors on Thu Aug  6 20:28:34 2026
   config:

           NAME        STATE     READ WRITE CKSUM
           tank        ONLINE       0     0     0
             mirror-0  ONLINE       0     0     0
               da1     ONLINE       0     0     128
               da2     ONLINE       0     0     0

   errors: No known data errors
   ```

9. **Verify file integrity post-healing to confirm application-level consistency.**
   ```bash
   sha256 /tank/dbdata/critical_payload.bin
   ```
   *Expected Output:*
   ```text
   SHA256 (/tank/dbdata/critical_payload.bin) = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
   ```

---

#### Verification Questions (Exercise 2)

**Question 2.1**: Why is `-o ashift=12` specified during `zpool create`, and what performance impact occurs if a pool is created with the default `ashift=9` on modern Advanced Format (4Kn / 512e) NVMe/SATA drives?  
**Question 2.2**: How was ZFS able to repair the corrupted 10MB of blocks on `/dev/da1` without reporting data loss or throwing an I/O error to the application reading `/tank/dbdata/critical_payload.bin`?  
**Question 2.3**: What is the key functional difference between setting a dataset `quota` versus a dataset `reservation`?

---

### Exercise 3: Capacity Planning, Space Allocation Monitoring, and Emergency Recovery

#### Objective
Diagnose file system exhaustion scenarios across UFS2 and ZFS, analyze inode vs block consumption, manage ZFS snapshots, and resolve ZFS pool capacity saturation conditions.

#### Execution Steps

1. **Check overall volume space and inode utilization across UFS and ZFS mount points.**
   ```bash
   df -h
   df -i
   ```
   *Expected Output (`df -i` truncated snippet):*
   ```text
   Filesystem           Inodes   Used  Avail Capacity iused Mounted on
   /dev/gpt/rootfs     1548286 120400 1427886     8%   120400  /
   /dev/da1p1            77312      4  77308     0%        4  /mnt/ufs_production
   tank/dbdata         3275912     15 3275897     0%       15  /tank/dbdata
   ```

2. **Diagnose directory space consumption hotspots using `du`.**
   ```bash
   du -hd 1 /var
   ```
   *Expected Output:*
   ```text
   2.1M    /var/audit
   512K    /var/backups
   1.2G    /var/log
   4.8G    /var/db
   6.0G    /var
   ```

3. **Take a point-in-time ZFS snapshot before executing administrative changes.**
   ```bash
   zfs snapshot tank/dbdata@pre_maintenance_20260806
   zfs list -t snapshot
   ```
   *Expected Output:*
   ```text
   NAME                                          USED  AVAIL  REFER  MOUNTPOINT
   tank/dbdata@pre_maintenance_20260806            0B      -   100M  -
   ```

4. **Simulate accidental file deletion within the ZFS dataset.**
   ```bash
   rm /tank/dbdata/critical_payload.bin
   ls -la /tank/dbdata/
   ```
   *Expected Output:*
   ```text
   total 2
   drwxr-xr-x  2 root  wheel  2 Aug  6 20:28 .
   drwxr-xr-x  3 root  wheel  3 Aug  6 20:28 ..
   ```

5. **Instantaneously roll back the dataset to the snapshot state.**
   ```bash
   zfs rollback tank/dbdata@pre_maintenance_20260806
   ls -la /tank/dbdata/
   ```
   *Expected Output:*
   ```text
   total 102410
   drwxr-xr-x  2 root  wheel     3 Aug  6 20:28 .
   drwxr-xr-x  3 root  wheel     3 Aug  6 20:28 ..
   -rw-r--r--  1 root  wheel 104857600 Aug  6 20:28 critical_payload.bin
   ```

6. **Monitor ZFS snapshot space usage overhead.**
   ```bash
   zfs get space tank/dbdata
   ```
   *Expected Output:*
   ```text
   NAME         PROPERTY              VALUE  SOURCE
   tank/dbdata  name                  tank/dbdata  -
   tank/dbdata  avail                 49.9G  -
   tank/dbdata  used                  100M   -
   tank/dbdata  usedbysnapshots       0B     -
   tank/dbdata  usedbydataset         100M   -
   tank/dbdata  usedbyrefreservations 0B     -
   tank/dbdata  usedbychildren        0B     -
   ```

---

#### Verification Questions (Exercise 3)

**Question 3.1**: An administrator runs `df -h` on a UFS2 filesystem and sees 40% free space available, yet application processes fail with `No space left on device` (ENOSPC) when attempting to create small files. Which command output pinpoints the exact failure cause, and why does ZFS not suffer from this specific structural limitation?  
**Question 3.2**: A ZFS storage pool reaches 96% capacity. An engineer attempts to run `zfs destroy` on unnecessary snapshots or create a file to free up space, but commands stall or return error space messages. Why does ZFS fail to process write/deletion operations when a pool is 100% full, and what architectural remedy (e.g., `zpool add` or dummy reservation files) prevents this deadlock?

---

## 3. Verification Answers & Detailed Explanations

<details>
<summary>Click to expand Exercise Answers & Detailed Technical Explanations</summary>

### Exercise 1 Answers

**1.1 Answer:**  
- **Architectural Purpose**: The 8% reserve (minfree) prevents UFS cylinder groups from suffering extreme block allocation fragmentation. UFS allocation algorithms rely on contiguous block availability within cylinder groups to maintain high sequential I/O performance.  
- **Impact when crossing 92%**: Non-root processes are blocked from writing further data once disk usage hits the 92% threshold (`100% - minfree`), failing with `ENOSPC`. Only `root` superuser processes are permitted to consume the final 8% space to perform critical system log writing and maintenance/recovery operations.

**1.2 Answer:**  
- **Command Syntax**:  
  ```bash
  fsck_ffs -b 1233920 /dev/da1p1
  ```  
- **Mechanism**: The `fsck_ffs` utility reads a secondary copy of the superblock located at block offset `1233920` (as printed by `newfs`), copies its contents back over the damaged primary superblock at block 24, recalculates cylinder group summary information, and restores system readability.

**1.3 Answer:**  
- **Standard Soft Updates (SU)**: Enforces dependency ordering in RAM for metadata operations (inodes, directory entries, free lists). In the event of a crash, structural consistency is guaranteed (no dangling pointers), but unreferenced blocks/inodes may leak. A full background scan (`fsck_ffs -p`) must walk all cylinder groups to reclaim lost blocks.  
- **Soft Updates with Journaling (SU+J)**: Writes metadata intent operations into an inline circular journal. Upon reboot after an ungraceful crash, `fsck_ffs` reads the small journal log, replays or unwinds uncommitted transactions in a few seconds, and marks the file system clean without needing to scan millions of unreferenced disk blocks.

---

### Exercise 2 Answers

**2.1 Answer:**  
- **Purpose**: `-o ashift=12` sets the vdev block size alignment to $2^{12} = 4096\text{ bytes}$ (4KB sectors).  
- **Performance Impact**: Modern disks physically use 4KB sectors. If created with `ashift=9` ($2^9 = 512\text{ bytes}$), every single 4KB write by ZFS causes a read-modify-write penalty across physical 4KB boundaries, degrading disk I/O performance by up to 800% and accelerating physical drive wear. `ashift` cannot be modified after pool creation.

**2.2 Answer:**  
- **Mechanism**:  
  1. When `/tank/dbdata/critical_payload.bin` was read or scanned during `zpool scrub`, ZFS computed the live checksum of the incoming data blocks from `/dev/da1`.  
  2. The computed checksum failed to match the Fletcher4/SHA256 checksum stored securely in the parent block pointer within the Merkle tree.  
  3. ZFS detected block corruption on `/dev/da1` (incrementing the `CKSUM` error counter to 128).  
  4. Because the pool topology was a **Mirror**, ZFS automatically read the correct matching data block from `/dev/da2`.  
  5. ZFS returned valid data transparently to the calling process, while asynchronously issuing a CoW write to re-write the healthy block onto `/dev/da1`, self-healing the corrupt sector without application interruption.

**2.3 Answer:**  
- **`quota`**: Defines a strict **hard upper limit** on the maximum space a dataset and its descendants can consume. Once reached, writes fail.  
- **`reservation`**: Defines a **guaranteed minimal disk space allocation** reserved exclusively for that dataset. No other dataset in the pool can consume this reserved pool capacity, guaranteeing that critical databases or system logs will never fail due to noisy neighbors filling shared pool capacity.

---

### Exercise 3 Answers

**3.1 Answer:**  
- **Diagnostic Command**: Running `df -i` reveals 100% inode utilization (`iused` = 100%), meaning all fixed static inodes allocated during `newfs` creation have been consumed, even if raw data block capacity (`df -h`) remains free.  
- **Why ZFS differs**: ZFS does not use static inode tables. Inodes (ZFS File Nodes, or `znodes`) are dynamically allocated on demand as objects within the ZFS SPA (Storage Pool Allocator) layout from the general pool space. An inode limit does not exist in ZFS until the entire pool runs out of raw storage bytes.

**3.2 Answer:**  
- **Why full pools lock up**: ZFS is a Copy-on-Write (CoW) file system. To delete a file or snapshot, ZFS must first write new block pointers and update metadata trees on disk. If a pool reaches 100% raw capacity, ZFS cannot allocate new space to perform the deletion write operations, causing a catastrophic operational deadlock.  
- **Architectural Remedies**:  
  1. Maintain a pre-allocated dummy file (e.g., a 2GB file created via `dd if=/dev/zero of=/tank/reservation.mem bs=1M count=2000`) on critical pools. When 100% full, unlinking this dummy file frees up space instantly without requiring allocation writes.  
  2. Temporarily attach a raw disk or sparse file to the pool using `zpool add tank /dev/da3` to inject fresh block space, allow metadata updates/deletions to complete, and clear pool capacity.

</details>

---

## 4. Official Documentation & References

- **FreeBSD Handbook — Storage & File Systems**: [https://docs.freebsd.org/en/books/handbook/filesystems/](https://docs.freebsd.org/en/books/handbook/filesystems/)
- **FreeBSD Handbook — The Zettabyte File System (ZFS)**: [https://docs.freebsd.org/en/books/handbook/zfs/](https://docs.freebsd.org/en/books/handbook/zfs/)
- **OpenBSD Manual Pages — `newfs(8)`**: [https://man.openbsd.org/newfs.8](https://man.openbsd.org/newfs.8)
- **OpenBSD Manual Pages — `fsck_ffs(8)`**: [https://man.openbsd.org/fsck_ffs.8](https://man.openbsd.org/fsck_ffs.8)
- **OpenBSD Manual Pages — `tunefs(8)`**: [https://man.openbsd.org/tunefs.8](https://man.openbsd.org/tunefs.8)
- **LPI BSD Specialist Objective Map**: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)