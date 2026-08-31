# LPIC-1 · Topic 104.2 — Maintain the Integrity of Filesystems

**Exam:** 101-500 (LPIC-1 v5.0) · **Weight:** 3.12
**Command surface:** `du`, `df`, `fsck`, `e2fsck`, `mke2fs`, `tune2fs`, `dumpe2fs`, `debugfs`, `badblocks`, `xfs_info`, `xfs_repair`, `xfs_db`, `xfs_fsr`, `xfs_admin`

---

## Lab prerequisites and safety contract

Every command below runs against **loop devices backed by sparse files**. Nothing in this lab touches a real block device. Read this once and then never deviate: `e2fsck -y`, `debugfs -w`, `badblocks -w` and `xfs_repair -L` are all capable of destroying a production filesystem in under a second, and none of them ask twice.

```bash
# Debian/Ubuntu
sudo apt-get install -y e2fsprogs xfsprogs util-linux lsof

# RHEL/Fedora/openSUSE
sudo dnf install -y e2fsprogs xfsprogs util-linux lsof
```

You need `root` (all examples assume you are `root`, or prefix with `sudo`).

**The single rule that governs this entire objective:**

> A filesystem checker requires exclusive access to the block device. Running `e2fsck` or `xfs_repair` on a **mounted, writable** filesystem corrupts it, because the kernel holds cached metadata that the checker cannot see and will happily overwrite. The only exception is a read-only-mounted filesystem inspected with `e2fsck -n`, and even that is a diagnostic, not a repair.

---

## Exercise 1 — Building the disposable lab, and the first `du`/`df` trap

### Steps

1. Create a working directory and two sparse backing files:

   ```bash
   mkdir -p /lab && cd /lab
   truncate -s 512M ext4.img
   truncate -s 1G   xfs.img
   ls -lh /lab
   ```

2. Compare what the directory entry claims against what is actually allocated:

   ```bash
   du -h ext4.img
   du -h --apparent-size ext4.img
   du -h --block-size=1 ext4.img
   ```

   Expected:

   ```
   0       ext4.img
   512M    ext4.img
   0       ext4.img
   ```

3. Attach both images to loop devices and confirm:

   ```bash
   losetup -fP --show /lab/ext4.img     # -> /dev/loop0
   losetup -fP --show /lab/xfs.img      # -> /dev/loop1
   losetup -a
   ```

   > If your device numbers differ, substitute them everywhere below. Export them so the rest of the lab is copy-paste safe:
   > ```bash
   > export EXT4DEV=/dev/loop0 XFSDEV=/dev/loop1
   > ```

4. Create the filesystems. The block size is forced on ext4 **on purpose** — read the question afterwards:

   ```bash
   mkfs.ext4 -b 4096 -L LAB-EXT4 $EXT4DEV
   mkfs.xfs  -f -L LAB-XFS $XFSDEV
   ```

5. Mount them:

   ```bash
   mkdir -p /mnt/ext4 /mnt/xfs
   mount $EXT4DEV /mnt/ext4
   mount $XFSDEV  /mnt/xfs
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /mnt/ext4 /mnt/xfs
   lsblk -f /dev/loop0 /dev/loop1
   ```

6. Look at the same filesystem through three different lenses:

   ```bash
   df -hT /mnt/ext4
   df -i  /mnt/ext4
   df --output=source,fstype,size,used,avail,pcent,iused,ipcent,target /mnt/ext4
   ```

   Expected (numbers vary by `e2fsprogs` version):

   ```
   Filesystem     Type  Size  Used Avail Use% Mounted on
   /dev/loop0     ext4  486M   24K  452M   1% /mnt/ext4

   Filesystem      Inodes IUsed  IFree IUse% Mounted on
   /dev/loop0       32768    11  32757    1% /mnt/ext4
   ```

7. Re-check the host allocation of the backing file now that a filesystem exists on it:

   ```bash
   du -h /lab/ext4.img
   ```

### Comprehension questions — Block 1

- **Q1.1** — `truncate -s 512M` produced a file that `du` reports as `0` but `ls -lh` reports as `512M`. Explain the mechanism, and state which of `du` and `ls` is telling you about *consumed storage*.
- **Q1.2** — The device is 512 MiB, but `df -h` reports a total size of `486M`. Where did the missing ~26 MiB go? Name **two** distinct consumers.
- **Q1.3** — `df -h` says `Avail 452M` while `Size 486M` and `Used 24K`. `486 - 452 ≠ 0.024`. Account for the difference precisely.
- **Q1.4** — You created the ext4 filesystem with `-b 4096`. Had you omitted it, `mke2fs` would have chosen 1024-byte blocks for a 512 MiB device. Name one operation later in this lab that would break if you assumed 4096 and the filesystem actually used 1024.
- **Q1.5** — Which of these three is safe to run against a mounted, actively written filesystem: `df -i`, `e2fsck -n`, `xfs_repair -n`?

---

## Exercise 2 — Free space accounting: `df` vs `du`, and why they disagree

This is the single most common production incident in this objective: *"the disk is full but nothing is on it."* There are four distinct root causes. You will manufacture three of them.

### Steps — Cause A: deleted-but-still-open files

1. Fill the ext4 filesystem substantially:

   ```bash
   dd if=/dev/urandom of=/mnt/ext4/payload.bin bs=1M count=300 status=progress
   sync
   df -h /mnt/ext4
   du -sh /mnt/ext4
   ```

   Both should agree at roughly 300 MiB.

2. Have a process hold the file open, then unlink it. The shell itself will be the offending process:

   ```bash
   exec 9< /mnt/ext4/payload.bin     # fd 9 now references the inode
   rm /mnt/ext4/payload.bin
   ```

3. Ask the two tools again:

   ```bash
   df -h  /mnt/ext4
   du -sh /mnt/ext4
   ls -la /mnt/ext4
   ```

   Expected: `df` still reports ~300 MiB used; `du` reports ~16 KiB; `ls` shows nothing.

4. Find the culprit without guessing:

   ```bash
   lsof +L1 /mnt/ext4
   lsof -n /mnt/ext4 | grep -i deleted
   ls -l /proc/$$/fd/9
   ```

   Expected `lsof` output:

   ```
   COMMAND  PID USER  FD  TYPE DEVICE  SIZE/OFF NLINK    NODE NAME
   bash    4711 root   9r  REG    7,0 314572800     0      12 /mnt/ext4/payload.bin (deleted)
   ```

5. Release the descriptor and watch the space return **instantly** — no reboot, no remount:

   ```bash
   exec 9<&-
   df -h /mnt/ext4
   ```

### Steps — Cause B: a mount point hiding data underneath it

6. Unmount, plant a file in the empty mount point, and remount over it:

   ```bash
   umount /mnt/ext4
   dd if=/dev/zero of=/mnt/ext4/hidden-50m.bin bs=1M count=50
   du -sh /mnt/ext4                      # 50M — this is on the ROOT filesystem
   mount $EXT4DEV /mnt/ext4
   du -sh /mnt/ext4                      # ~16K — the 50M is now unreachable
   df -h /               # the 50M is still charged to /
   ```

7. Reveal the shadowed data without unmounting anything:

   ```bash
   mkdir -p /mnt/rootview
   mount --bind / /mnt/rootview
   ls -lh /mnt/rootview/mnt/ext4/
   du -sh /mnt/rootview/mnt/ext4/
   ```

8. Clean up that cause:

   ```bash
   rm -f /mnt/rootview/mnt/ext4/hidden-50m.bin
   umount /mnt/rootview && rmdir /mnt/rootview
   ```

### Steps — Cause C: reserved blocks for the superuser

9. Inspect and then change the reservation:

   ```bash
   tune2fs -l $EXT4DEV | grep -Ei 'block count|reserved block'
   df -h /mnt/ext4
   tune2fs -m 0 $EXT4DEV
   df -h /mnt/ext4                       # Avail jumps by ~24 MiB
   tune2fs -m 5 $EXT4DEV                 # restore the default
   ```

### Steps — Cause D (measurement only): crossing filesystem boundaries

10. Contrast a boundary-crossing walk with a contained one:

    ```bash
    du -sh  /mnt        # descends into /mnt/ext4 and /mnt/xfs
    du -shx /mnt        # stays on the filesystem holding /mnt
    du -h --max-depth=1 /mnt
    ```

11. A realistic "who ate the disk" one-liner:

    ```bash
    du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -15
    ```

### Comprehension questions — Block 2

- **Q2.1** — In step 3, `df` and `du` disagreed by 300 MiB. Explain *architecturally* why each tool gives the answer it does. Which data structure does each one consult?
- **Q2.2** — In the `lsof +L1` output the `NLINK` column reads `0`. What does that column mean, and what exactly does `+L1` select?
- **Q2.3** — A junior engineer proposes rebooting the server to reclaim the space from a deleted-but-open 40 GB log. Give a correct, non-disruptive alternative and explain what it does to the running process.
- **Q2.4** — After step 6, does the 50 MiB hidden file consume space on the ext4 filesystem, on the root filesystem, or on neither? Which `df` line changes when you delete it?
- **Q2.5** — `df` shows `Use% 100%` but `Avail` is not `0` and non-root writes fail with `ENOSPC`, while root can still write. Diagnose, and give the command that both explains and fixes it.
- **Q2.6** — Why is `du -x` mandatory in a monitoring script that walks `/`, and what would happen without it on a host with an NFS mount and a 2 TB data volume?

---

## Exercise 3 — Inode exhaustion: full filesystem with 99 % free space

### Steps

1. Build a deliberately inode-starved filesystem on a second partition of the same image. Simpler: create a small dedicated image.

   ```bash
   truncate -s 64M /lab/inodes.img
   INODEDEV=$(losetup -fP --show /lab/inodes.img)
   echo $INODEDEV
   mkfs.ext4 -b 1024 -i 65536 -F $INODEDEV
   mkdir -p /mnt/inodes && mount $INODEDEV /mnt/inodes
   ```

   `-i 65536` means *one inode per 65536 bytes of filesystem*, so 64 MiB / 64 KiB = **1024 inodes**.

2. Confirm the inode budget before doing anything:

   ```bash
   df -i /mnt/inodes
   tune2fs -l $INODEDEV | grep -Ei 'inode count|free inodes|inode size|blocks per group|inodes per group'
   ```

3. Consume the inodes with zero-byte files:

   ```bash
   for i in $(seq 1 2000); do : > /mnt/inodes/f$i 2>/dev/null || { echo "FAILED at $i: $(: > /mnt/inodes/f$i 2>&1)"; break; }; done
   ```

   Or, to see the real error text:

   ```bash
   touch /mnt/inodes/one-more
   # touch: cannot touch '/mnt/inodes/one-more': No space left on device
   ```

4. Look at both dimensions side by side — this is the diagnostic signature:

   ```bash
   df -h /mnt/inodes
   df -i /mnt/inodes
   ```

   Expected:

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/loop2       58M  1.1M   53M   2% /mnt/inodes      <-- 2% blocks used

   Filesystem     Inodes IUsed IFree IUse% Mounted on
   /dev/loop2       1024  1024     0  100% /mnt/inodes      <-- 100% inodes used
   ```

5. Locate the directories responsible, the way you would in production:

   ```bash
   du -a --inodes /mnt/inodes 2>/dev/null | sort -rn | head
   # portable fallback, no --inodes support:
   find /mnt/inodes -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head
   ```

6. Note the one thing you **cannot** do:

   ```bash
   # There is no "grow the inode table" for a mounted ext4 filesystem.
   # resize2fs changes block count, never inode count.
   resize2fs $INODEDEV 60000        # observe: inode count is unchanged
   df -i /mnt/inodes
   ```

7. Reclaim and tear this one down:

   ```bash
   rm -f /mnt/inodes/f*
   df -i /mnt/inodes
   umount /mnt/inodes && losetup -d $INODEDEV && rm -f /lab/inodes.img && rmdir /mnt/inodes
   ```

### Comprehension questions — Block 3

- **Q3.1** — `write(2)` returned `ENOSPC` while `df -h` showed 2 % block usage. Explain why the same errno covers two structurally different exhaustion conditions.
- **Q3.2** — The ext4 inode count is fixed at `mke2fs` time. State the two `mke2fs` options that control it and the difference between them.
- **Q3.3** — Your mail spool host runs out of inodes every quarter. `resize2fs` cannot help. List the two real remediations, and state which one requires a backup/restore cycle.
- **Q3.4** — Does XFS have this failure mode? Justify your answer in terms of how XFS allocates inodes, and name the `mkfs.xfs`/`mount` knob that can still cause an inode-related `ENOSPC`.
- **Q3.5** — Why is `find /mnt -printf '%h\n' | sort | uniq -c | sort -rn` a better first move than `du -sh` when you suspect inode exhaustion?

---

## Exercise 4 — Reading ext filesystem metadata: `dumpe2fs` and `tune2fs`

### Steps

1. Dump the superblock only (never dump the group descriptors on a large filesystem without a pager):

   ```bash
   dumpe2fs -h $EXT4DEV
   ```

   Abridged expected output:

   ```
   dumpe2fs 1.47.0 (5-Feb-2023)
   Filesystem volume name:   LAB-EXT4
   Last mounted on:          /mnt/ext4
   Filesystem UUID:          6b1f0c9a-...-...
   Filesystem magic number:  0xEF53
   Filesystem revision #:    1 (dynamic)
   Filesystem features:      has_journal ext_attr resize_inode dir_index filetype
                             extent 64bit flex_bg sparse_super large_file huge_file
                             dir_nlink extra_isize metadata_csum
   Filesystem state:         clean
   Errors behavior:          Continue
   Inode count:              32768
   Block count:              131072
   Reserved block count:     6553
   Free blocks:              120184
   Free inodes:              32757
   First block:              0
   Block size:               4096
   Blocks per group:         32768
   Inodes per group:         8192
   Inode size:               256
   Mount count:              3
   Maximum mount count:      -1
   Last checked:             Tue Aug 25 10:11:12 2026
   Check interval:           0 (<none>)
   Journal inode:            8
   Checksum type:            crc32c
   ```

2. Get the same superblock through the other tool and diff the two views:

   ```bash
   tune2fs -l $EXT4DEV | head -40
   diff <(dumpe2fs -h $EXT4DEV 2>/dev/null) <(tune2fs -l $EXT4DEV 2>/dev/null)
   ```

3. Now dump the block group layout, which `tune2fs` cannot show you:

   ```bash
   dumpe2fs $EXT4DEV | grep -E '^Group|Backup superblock|Block bitmap|Inode table' | head -30
   ```

   Expected:

   ```
   Group 0: (Blocks 0-32767) csum 0x1a2b [ITABLE_ZEROED]
     Primary superblock at 0, Group descriptors at 1-1
     Block bitmap at 65 (+65)
     Inode table at 69-580 (+69)
   Group 1: (Blocks 32768-65535) csum 0x3c4d [INODE_UNINIT, ...]
     Backup superblock at 32768, Group descriptors at 32769-32769
   ...
   Group 3: (Blocks 98304-131071) csum 0x5e6f [...]
     Backup superblock at 98304, Group descriptors at 98305-98305
   ```

4. Ask `mke2fs` where the backups *would* be, without writing anything. Memorise this trick — it is the fastest way to recover a destroyed superblock:

   ```bash
   mke2fs -n -b 4096 $EXT4DEV
   ```

   ```
   Creating filesystem with 131072 4k blocks and 32768 inodes
   Superblock backups stored on blocks:
           32768, 98304
   ```

5. Change tunables and observe each one in `dumpe2fs -h`:

   ```bash
   tune2fs -L PROD-DATA          $EXT4DEV
   tune2fs -c 25 -i 1m           $EXT4DEV      # 25 mounts OR 1 month
   tune2fs -e remount-ro         $EXT4DEV      # panic | remount-ro | continue
   tune2fs -m 1                  $EXT4DEV
   dumpe2fs -h $EXT4DEV | grep -Ei 'volume name|maximum mount|check interval|errors behavior|reserved block count'
   ```

6. Simulate an overdue check without waiting a month:

   ```bash
   tune2fs -C 26 $EXT4DEV                      # set the mount counter past the max
   dumpe2fs -h $EXT4DEV | grep -i 'mount count'
   umount /mnt/ext4
   fsck -a $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   fsck from util-linux 2.38.1
   PROD-DATA has gone 26 mounts without being checked, check forced.
   PROD-DATA: 11/32768 files (0.0% non-contiguous), 12345/131072 blocks
   exit=0
   ```

7. Restore the distro-default behaviour and re-mount:

   ```bash
   tune2fs -c -1 -i 0 -C 0 -T now -e continue -m 5 -L LAB-EXT4 $EXT4DEV
   dumpe2fs -h $EXT4DEV | grep -Ei 'maximum mount|check interval|last checked|state'
   mount $EXT4DEV /mnt/ext4
   ```

### Comprehension questions — Block 4

- **Q4.1** — `dumpe2fs -h` and `tune2fs -l` print nearly identical output. State the design difference between the two commands and the one thing `dumpe2fs` shows that `tune2fs` never will.
- **Q4.2** — Backup superblocks appear at blocks 32768 and 98304, not at 32768 / 65536 / 98304 / 131072. Which filesystem feature causes that, and what is the trade-off it buys?
- **Q4.3** — Convert "backup superblock at block 32768" into a byte offset for a 4096-byte-block filesystem, and then for a 1024-byte-block filesystem. Why does this arithmetic matter to `e2fsck`?
- **Q4.4** — Most enterprise distributions ship with `Maximum mount count: -1` and `Check interval: 0`. Argue both sides: what risk does that disable, and what operational problem does it prevent?
- **Q4.5** — `Errors behavior` is set to `remount-ro`. Describe what the kernel does on detecting metadata corruption under this setting, and why `panic` is sometimes the correct choice for a clustered node.
- **Q4.6** — `tune2fs -C 26` forced a check on the next `fsck -a`. Which superblock fields does a successful `e2fsck` reset when it finishes cleanly?

---

## Exercise 5 — `fsck` and `e2fsck`: checking, repairing, exit codes

### Steps — the front end vs the back end

1. Establish who actually does the work:

   ```bash
   umount /mnt/ext4
   fsck -N $EXT4DEV
   ```

   Expected — note that nothing is executed:

   ```
   fsck from util-linux 2.38.1
   [/usr/sbin/fsck.ext4 (1) -- /dev/loop0] fsck.ext4 /dev/loop0
   ```

   ```bash
   ls -l /usr/sbin/fsck.ext4 /usr/sbin/e2fsck
   ```

2. Run a genuine, forced check on a clean filesystem and capture the exit code:

   ```bash
   e2fsck -f -v $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   Pass 1: Checking inodes, blocks, and sizes
   Pass 2: Checking directory structure
   Pass 3: Checking directory connectivity
   Pass 4: Checking reference counts
   Pass 5: Checking group summary information

            11 inodes used (0.03%, out of 32768)
             0 non-contiguous files (0.0%)
             ...
   exit=0
   ```

3. Prove that the checker refuses (or should refuse) a mounted target:

   ```bash
   mount $EXT4DEV /mnt/ext4
   e2fsck -f $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   /dev/loop0 is mounted.
   e2fsck: Cannot continue, aborting.
   exit=8
   ```

4. The only mounted-filesystem inspection that is defensible:

   ```bash
   mount -o remount,ro /mnt/ext4
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   mount -o remount,rw /mnt/ext4
   ```

### Steps — manufacture and repair real corruption

5. Create identifiable content, then unmount:

   ```bash
   mkdir -p /mnt/ext4/docs
   dd if=/dev/urandom of=/mnt/ext4/docs/report.bin bs=1M count=8
   echo "quarterly numbers" > /mnt/ext4/docs/notes.txt
   ls -i /mnt/ext4/docs/report.bin /mnt/ext4/docs/notes.txt
   sync && umount /mnt/ext4
   ```

   Record the inode numbers printed by `ls -i` (example: `13` and `14`).

6. **Corruption A — unattached inode.** Remove the directory entry but leave the inode allocated:

   ```bash
   debugfs -w -R "unlink /docs/report.bin" $EXT4DEV
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   Pass 4: Checking reference counts
   Unattached inode 13
   Connect to /lost+found? no

   Inode 13 ref count is 1, should be 0.  Fix? no
   /dev/loop0: ********** WARNING: Filesystem still has errors **********
   exit=4
   ```

7. Repair it and inspect the result:

   ```bash
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   mount $EXT4DEV /mnt/ext4
   ls -li /mnt/ext4/lost+found/
   ls -lh /mnt/ext4/lost+found/
   file /mnt/ext4/lost+found/*
   ```

   Expected: a file named `#13` of exactly 8 MiB — the data survived, the *name* did not.

8. **Corruption B — inode bitmap divergence.** Mark a live inode as free:

   ```bash
   NOTES_INO=$(ls -i /mnt/ext4/docs/notes.txt | awk '{print $1}')
   echo "notes.txt inode = $NOTES_INO"
   umount /mnt/ext4
   debugfs -w -R "freei <$NOTES_INO>" $EXT4DEV
   e2fsck -fn $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   Pass 5: Checking group summary information
   Inode bitmap differences:  +14
   Fix? no
   exit=4
   ```

   ```bash
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   e2fsck -f  $EXT4DEV ; echo "exit=$?"      # second run must be silent, exit=0
   ```

9. **Corruption C — bad link count.** Lie about how many names point at an inode:

   ```bash
   debugfs -w -R "sif /docs/notes.txt links_count 7" $EXT4DEV
   e2fsck -fy $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   Pass 4: Checking reference counts
   Inode 14 ref count is 7, should be 1.  Fix? yes
   exit=1
   ```

10. Memorise the exit-code bitmask — it is directly examinable and it is what init systems branch on:

    ```bash
    man 8 fsck | sed -n '/EXIT CODE/,/AUTHOR/p'
    ```

    | Value | Meaning |
    |---|---|
    | `0` | No errors |
    | `1` | Filesystem errors corrected |
    | `2` | Errors corrected, **system should be rebooted** |
    | `4` | Filesystem errors left **uncorrected** |
    | `8` | Operational error |
    | `16` | Usage or syntax error |
    | `32` | Check canceled by user request |
    | `128`| Shared-library error |

    Values are **added** when `fsck` checks several filesystems, e.g. `5 = 1 + 4`.

### Comprehension questions — Block 5

- **Q5.1** — Distinguish `fsck -N` from `e2fsck -n`. Both "don't change anything" — what is the actual difference in what each one does?
- **Q5.2** — `e2fsck -fn` returned `4` and `e2fsck -fy` returned `1`. Interpret both, and say which one an automation script should treat as a paging incident.
- **Q5.3** — A boot-time `fsck` returns `5`. Decompose it and describe the operator action required.
- **Q5.4** — Why does `e2fsck` need `-f` on a filesystem marked `clean`, and what does "clean" actually assert about the on-disk data?
- **Q5.5** — In step 7 the recovered file appeared as `/lost+found/#13`. Explain, in terms of the inode/dentry split, why the content survived but the filename did not — and why `lost+found` must be preallocated at `mke2fs` time.
- **Q5.6** — `-p` (preen) is what init systems use, not `-y`. State the behavioural difference and why `-y` at boot is considered dangerous.
- **Q5.7** — In step 8, `e2fsck -fy` was immediately followed by a second `e2fsck -f`. Why is that second run non-optional after any repair?

---

## Exercise 6 — Superblock destruction and recovery from a backup

This is the highest-value drill in the objective. Do it slowly.

### Steps

1. Record the current state so you can verify recovery objectively:

   ```bash
   mount $EXT4DEV /mnt/ext4
   mkdir -p /mnt/ext4/critical
   echo "do not lose this" > /mnt/ext4/critical/canary.txt
   md5sum /mnt/ext4/critical/canary.txt
   sync && umount /mnt/ext4
   dumpe2fs -h $EXT4DEV | grep -Ei 'uuid|block size|inode count'
   ```

2. Destroy the primary superblock. It lives at **byte offset 1024**, is 1024 bytes long, and is independent of the filesystem block size:

   ```bash
   dd if=/dev/zero of=$EXT4DEV bs=1024 seek=1 count=1 conv=notrunc
   sync
   ```

3. Observe the failure exactly as a user would report it:

   ```bash
   mount $EXT4DEV /mnt/ext4
   ```

   ```
   mount: /mnt/ext4: wrong fs type, bad option, bad superblock on /dev/loop0,
          missing codepage or helper program, or other error.
   ```

   ```bash
   dmesg | tail -5
   blkid $EXT4DEV        # returns nothing — the identifying magic is gone
   file -s $EXT4DEV
   ```

4. Confirm the metadata reader is equally blind:

   ```bash
   dumpe2fs -h $EXT4DEV ; echo "exit=$?"
   ```

   ```
   dumpe2fs: Bad magic number in super-block while trying to open /dev/loop0
   Couldn't find valid filesystem superblock.
   ```

5. Find the backup superblock locations. The device is unreadable, so `dumpe2fs` cannot tell you — use the dry-run trick from Exercise 4:

   ```bash
   mke2fs -n -b 4096 $EXT4DEV
   ```

   > **Critical:** `-b` must match the original block size. Guess wrong and `mke2fs -n` prints the wrong backup locations. If you do not know it, try 4096 first, then 1024 (`mke2fs -n -b 1024` → backups at 8193, 24577, 40961, 57345, 73729).

6. Inspect read-only through the backup **before** you write anything:

   ```bash
   e2fsck -fn -b 32768 -B 4096 $EXT4DEV ; echo "exit=$?"
   ```

   Expected — a wall of differences it declines to fix, ending in:

   ```
   /dev/loop0: ********** WARNING: Filesystem still has errors **********
   exit=4
   ```

7. Repair using the backup. `e2fsck` writes the repaired superblock back to the primary location automatically:

   ```bash
   e2fsck -fy -b 32768 -B 4096 $EXT4DEV ; echo "exit=$?"
   ```

   Expected:

   ```
   e2fsck 1.47.0 (5-Feb-2023)
   /dev/loop0 was not cleanly unmounted, check forced.
   Pass 1: Checking inodes, blocks, and sizes
   Pass 2: Checking directory structure
   Pass 3: Checking directory connectivity
   Pass 4: Checking reference counts
   Pass 5: Checking group summary information
   Free blocks count wrong for group #0 (...). Fix? yes
   ...
   /dev/loop0: ***** FILE SYSTEM WAS MODIFIED *****
   exit=1
   ```

8. Verify the repair objectively — three independent confirmations:

   ```bash
   e2fsck -f $EXT4DEV ; echo "exit=$?"          # must be 0
   dumpe2fs -h $EXT4DEV | grep -Ei 'state|uuid'
   blkid $EXT4DEV
   mount $EXT4DEV /mnt/ext4
   md5sum /mnt/ext4/critical/canary.txt         # must match step 1
   ls -l /mnt/ext4/lost+found/
   ```

9. Note the omission-that-is-not: `e2fsck` did **not** need `-b` on the second run, because the primary superblock is valid again.

### Comprehension questions — Block 6

- **Q6.1** — Why is the primary superblock at byte offset 1024 rather than offset 0, on every ext2/3/4 filesystem regardless of block size?
- **Q6.2** — You are handed a failed device and do not know its block size. Describe a decision procedure using only `mke2fs -n` and `e2fsck -n` that finds a usable backup superblock without risking further damage.
- **Q6.3** — What does `-B 4096` do that `-b 32768` does not, and when is `-B` genuinely required?
- **Q6.4** — After recovering from a backup superblock, `e2fsck` reported free-block counts wrong for several groups. Explain why that is expected rather than alarming.
- **Q6.5** — In step 6 you ran `-fn` before `-fy`. In a real incident with no backups, name one additional step you should take between those two, and give the command.
- **Q6.6** — `blkid` returned nothing in step 3 but works in step 8. Which field is `blkid` reading, and what does its absence imply for `/etc/fstab` entries written as `UUID=...`?

---

## Exercise 7 — XFS: a different repair model entirely

### Steps

1. Read the geometry. This is XFS's equivalent of `dumpe2fs -h`:

   ```bash
   xfs_info /mnt/xfs
   ```

   Expected:

   ```
   meta-data=/dev/loop1             isize=512    agcount=4, agsize=65536 blks
            =                       sectsz=512   attr=2, projid32bit=1
            =                       crc=1        finobt=1, sparse=1, rmapbt=0
            =                       reflink=1    bigtime=1 inobtcount=1
   data     =                       bsize=4096   blocks=262144, imaxpct=25
            =                       sunit=0      swidth=0 blks
   naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
   log      =internal log           bsize=4096   blocks=2560, version=2
            =                       sectsz=512   sunit=0 blks, lazy-count=1
   realtime =none                   extsz=4096   blocks=0, rtextents=0
   ```

2. Discover the most important cultural difference in this objective:

   ```bash
   ls -l /usr/sbin/fsck.xfs
   file /usr/sbin/fsck.xfs
   cat /usr/sbin/fsck.xfs
   fsck.xfs $XFSDEV ; echo "exit=$?"
   ```

   `fsck.xfs` is a **shell script that does nothing and exits 0**.

3. Try to repair a mounted XFS filesystem and read the refusal carefully:

   ```bash
   xfs_repair $XFSDEV ; echo "exit=$?"
   ```

   ```
   xfs_repair: /dev/loop1 contains a mounted filesystem
   xfs_repair: /dev/loop1 contains a mounted and writable filesystem

   fatal error -- couldn't initialize XFS library
   exit=1
   ```

4. Populate it, then check it properly — offline:

   ```bash
   mkdir -p /mnt/xfs/data
   dd if=/dev/urandom of=/mnt/xfs/data/blob.bin bs=1M count=64
   echo "xfs canary" > /mnt/xfs/data/canary.txt
   md5sum /mnt/xfs/data/canary.txt
   sync && umount /mnt/xfs

   xfs_repair -n $XFSDEV ; echo "exit=$?"
   ```

   Expected — seven named phases, ending in:

   ```
   Phase 1 - find and verify superblock...
   Phase 2 - using internal log
           - zero log...
           - scan filesystem freespace and inode maps...
           - found root inode chunk
   Phase 3 - for each AG...
           - scan (but don't clear) agi unlinked lists...
           - process known inodes and perform inode discovery...
   Phase 4 - check for duplicate blocks...
   Phase 5 - No modify flag set, skipping phase.
   Phase 6 - check inode connectivity...
   Phase 7 - verify link counts...
   No modify flag set, skipping filesystem flush and exiting.
   exit=0
   ```

5. Read the on-disk superblock directly:

   ```bash
   xfs_db -r -c "sb 0" -c "print" $XFSDEV | head -25
   xfs_db -r -c "sb 0" -c "print magicnum blocksize dblocks agcount agblocks rootino uuid" $XFSDEV
   xfs_db -r -c "sb 1" -c "print magicnum agcount" $XFSDEV     # a secondary superblock
   ```

   The XFS magic number is `0x58465342` — ASCII `XFSB`.

6. **Destroy the primary superblock** (XFS puts it at offset 0, unlike ext4):

   ```bash
   dd if=/dev/zero of=$XFSDEV bs=512 count=1 conv=notrunc
   sync
   mount $XFSDEV /mnt/xfs        # fails
   dmesg | tail -3
   blkid $XFSDEV
   ```

7. Recover. `xfs_repair` walks the allocation groups looking for a secondary superblock, entirely on its own — no `-b` equivalent needed:

   ```bash
   xfs_repair $XFSDEV ; echo "exit=$?"
   ```

   Expected:

   ```
   Phase 1 - find and verify superblock...
   bad primary superblock - bad magic number !!!

   attempting to find secondary superblock...
   ...found candidate secondary superblock...
   verified secondary superblock...
   writing modified primary superblock
   Phase 2 - using internal log
   ...
   Phase 7 - verify link counts...
   done
   exit=0
   ```

8. Verify:

   ```bash
   xfs_repair -n $XFSDEV ; echo "exit=$?"
   mount $XFSDEV /mnt/xfs
   md5sum /mnt/xfs/data/canary.txt
   ls -l /mnt/xfs/lost+found 2>/dev/null || echo "no lost+found — XFS creates it only when needed"
   ```

9. Labels and UUIDs — `xfs_admin` requires the filesystem **unmounted**:

   ```bash
   umount /mnt/xfs
   xfs_admin -l $XFSDEV            # print label
   xfs_admin -u $XFSDEV            # print UUID
   xfs_admin -L PROD-XFS $XFSDEV
   xfs_admin -U generate $XFSDEV   # new UUID — required after a block-level clone
   xfs_admin -l -u $XFSDEV
   mount $XFSDEV /mnt/xfs
   ```

10. Fragmentation: measure, then reorganise. `xfs_fsr` is the opposite of `xfs_repair` — it requires the filesystem **mounted**:

    ```bash
    # Manufacture fragmentation: many interleaved appends
    for i in $(seq 1 40); do
      for f in a b c d; do dd if=/dev/zero of=/mnt/xfs/frag_$f bs=64k count=1 \
        seek=$i conv=notrunc oflag=append status=none 2>/dev/null; done
    done
    sync

    xfs_bmap -vp /mnt/xfs/frag_a          # per-file extent map
    umount /mnt/xfs
    xfs_db -r -c "frag" $XFSDEV
    mount $XFSDEV /mnt/xfs
    xfs_fsr -v /mnt/xfs
    xfs_bmap -vp /mnt/xfs/frag_a          # fewer extents
    ```

    `xfs_db -c frag` output — note the last line, which is printed verbatim by the tool:

    ```
    actual 187, ideal 44, fragmentation factor 76.47%
    Note, this number is largely meaningless.
    Files on this filesystem average 4.25 extents per file
    ```

11. Two commands worth knowing exist, and one you must fear:

    ```bash
    xfs_freeze -f /mnt/xfs        # quiesce for a consistent snapshot
    xfs_freeze -u /mnt/xfs        # thaw — ALWAYS pair these

    umount /mnt/xfs
    xfs_metadump -o $XFSDEV /lab/xfs-meta.dump    # metadata-only image for support
    ls -lh /lab/xfs-meta.dump

    # xfs_repair -L  <-- ZEROES THE JOURNAL. Unreplayed transactions are lost
    #                    forever. Last resort only, after xfs_metadump, and only
    #                    when mount+umount cannot replay the log.
    mount $XFSDEV /mnt/xfs
    ```

12. Compare the two ecosystems side by side:

    ```bash
    xfs_growfs /mnt/xfs -D 300000   # XFS grows online...
    # ...and can never shrink. There is no xfs_shrinkfs.
    resize2fs $EXT4DEV 100000       # ext4 shrinks — but only when unmounted
    ```

### Comprehension questions — Block 7

- **Q7.1** — `fsck.xfs` exits 0 without doing anything. Given that, what value must the sixth field (`fs_passno`) of an XFS entry in `/etc/fstab` have, and what does the XFS design rely on instead of a boot-time check?
- **Q7.2** — `xfs_repair` refuses a mounted filesystem, while `xfs_fsr` requires one. Explain why each constraint is the correct design for that tool.
- **Q7.3** — XFS recovered from a wiped superblock with no `-b`-style argument, but ext4 needed `-b 32768 -B 4096`. What structural property of XFS makes the search automatic?
- **Q7.4** — Your XFS filesystem will not mount and `dmesg` reports a corrupt log. Give the **correct ordered procedure**, and say precisely at which step `xfs_repair -L` becomes acceptable.
- **Q7.5** — `xfs_db -c frag` prints "Note, this number is largely meaningless." Why do the XFS developers say that, and what should you measure instead before deciding to run `xfs_fsr`?
- **Q7.6** — You `dd`-cloned an XFS volume to a second LUN and both are visible to the same host. Name the failure you will hit and the exact command that prevents it.
- **Q7.7** — Contrast `xfs_growfs` and `resize2fs` on: online vs offline, grow vs shrink. Which of the four combinations is impossible?

---

## Exercise 8 — Boot-time checking, `/etc/fstab`, and `badblocks`

### Steps — the `fs_passno` field

1. Read the current policy on the running system:

   ```bash
   findmnt --fstab -o SOURCE,TARGET,FSTYPE,OPTIONS,PASSNO
   awk '!/^#/ && NF {printf "%-28s %-16s %-8s pass=%s\n", $1, $2, $3, $6}' /etc/fstab
   ```

2. Add the lab devices to `/etc/fstab` with `noauto` so a mistake cannot break your boot:

   ```bash
   cp /etc/fstab /etc/fstab.bak.$(date +%s)
   cat >> /etc/fstab <<'EOF'
   # --- LPIC-1 104.2 lab (remove after the exercise) ---
   /dev/loop0  /mnt/ext4  ext4  defaults,noauto  0 2
   /dev/loop1  /mnt/xfs   xfs   defaults,noauto  0 0
   EOF
   findmnt --verify --verbose
   ```

3. See the ordering `fsck -A` would use, without executing anything:

   ```bash
   fsck -A -N
   fsck -A -N -t ext4
   ```

4. Inspect the systemd machinery that replaced the old `/forcefsck` file:

   ```bash
   systemctl list-units 'systemd-fsck*' --all
   systemctl cat systemd-fsck-root.service | head -25
   cat /proc/cmdline
   ```

   The relevant kernel command-line parameters:

   | Parameter | Effect |
   |---|---|
   | `fsck.mode=auto` | Default: check per superblock/passno policy |
   | `fsck.mode=force` | Force a full check of every filesystem |
   | `fsck.mode=skip` | Skip all checking |
   | `fsck.repair=preen` | Default: `-a`, fix only unambiguous errors |
   | `fsck.repair=yes` | `-y`, answer yes to everything |
   | `fsck.repair=no` | `-n`, report only |

5. Remove the lab entries when finished:

   ```bash
   sed -i '/LPIC-1 104.2 lab/,+2d' /etc/fstab
   findmnt --verify
   ```

### Steps — `badblocks`

6. Run the **safe, read-only** surface scan:

   ```bash
   badblocks -sv -b 4096 $EXT4DEV
   ```

   ```
   Checking blocks 0 to 131071
   Checking for bad blocks (read-only test): done
   Pass completed, 0 bad blocks found. (0/0/0 errors)
   ```

7. The non-destructive read-write test — requires the filesystem **unmounted**:

   ```bash
   umount /mnt/ext4
   badblocks -nsv -b 4096 -o /lab/badblocks.txt $EXT4DEV
   wc -l /lab/badblocks.txt
   ```

8. Feed a bad-block list into the filesystem's bad-block inode, and then let `e2fsck` do it for you:

   ```bash
   e2fsck -l /lab/badblocks.txt $EXT4DEV      # ADD the list
   # e2fsck -L /lab/badblocks.txt $EXT4DEV    # REPLACE the list
   e2fsck -cc $EXT4DEV                        # run badblocks -n internally, then record
   dumpe2fs -b $EXT4DEV                       # print the recorded bad blocks
   mount $EXT4DEV /mnt/ext4
   ```

9. The destructive form — **never** on a device holding data:

   ```bash
   # badblocks -wsv /dev/sdX      <-- writes patterns over EVERY block. Data is gone.
   ```

10. The modern counter-argument. Check what the drive itself thinks:

    ```bash
    smartctl -a /dev/sda 2>/dev/null | grep -Ei 'reallocated|pending|uncorrectable|media_wearout|health'
    ```

### Comprehension questions — Block 8

- **Q8.1** — Give the meaning of `0`, `1` and `2` in the sixth `fstab` field, and state how many filesystems on a host should carry `1`.
- **Q8.2** — Two ext4 data volumes on **separate physical disks** both carry `pass=2`. What does `fsck -A` do with them, and what changes if they are on the same disk?
- **Q8.3** — Someone sets `fsck.repair=yes fsck.mode=force` permanently in GRUB "to be safe". Give two concrete reasons this is a bad standing configuration.
- **Q8.4** — Compare `badblocks -n` and `badblocks -w`: what each does, which one destroys data, and which one requires the filesystem unmounted.
- **Q8.5** — You ran `badblocks -b 1024` and passed the output to `e2fsck -l` on a filesystem with 4096-byte blocks. What is the consequence?
- **Q8.6** — Explain why `badblocks` is largely obsolete on modern SSDs and enterprise SAS/SATA drives, and name what replaced it as the primary media-health signal.
- **Q8.7** — Distinguish `e2fsck -l` from `e2fsck -L`. Which one would you use to clear a stale bad-block list inherited from a previous drive?

---

## Teardown

```bash
umount /mnt/ext4 /mnt/xfs 2>/dev/null
losetup -d /dev/loop0 /dev/loop1 2>/dev/null
losetup -a
rm -f /lab/ext4.img /lab/xfs.img /lab/badblocks.txt /lab/xfs-meta.dump
rmdir /mnt/ext4 /mnt/xfs /lab 2>/dev/null
grep -n 'LPIC-1 104.2 lab' /etc/fstab   # must return nothing
```

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Block 1 — Lab construction and sparse files

**A1.1** — `truncate` sets the inode's *size* attribute without allocating any data blocks; the file is **sparse**. `ls -l` prints `i_size` (the logical end of file, what a reader would see). `du` prints `st_blocks × 512` (the blocks actually allocated). **`du` is the tool that reports consumed storage.** `du --apparent-size` switches `du` to the `ls` semantics, which is why it printed 512M. Reads of an unallocated range return zeros from the kernel without touching the disk.

**A1.2** — At least two consumers, both allocated by `mke2fs` before any user data exists:
1. **Static metadata**: the inode table (32768 inodes × 256 bytes ≈ 8 MiB), block and inode bitmaps, group descriptors, and the superblock plus its backups.
2. **The journal**: `has_journal` allocates a dedicated journal inode, typically 4–128 MiB depending on filesystem size (on this 512 MiB filesystem, roughly 16 MiB).
Additionally the `resize_inode` feature reserves group descriptor blocks for future online growth.

**A1.3** — `Size − Used − Avail = 486 − 452 − 0.024 ≈ 34 MiB`, but `Size` already excludes the metadata from A1.2. The remaining gap is the **reserved block count**: 5 % of the block count (6553 blocks × 4 KiB ≈ 25.6 MiB) is reserved for UID 0 and is subtracted from `Avail` but not from `Size`. `df` deliberately reports `Avail` from the *unprivileged* point of view.

**A1.4** — Backup-superblock recovery. `e2fsck -b 32768` is only correct for a 4096-byte-block filesystem. With 1024-byte blocks the first backup is at block **8193**, and passing 32768 either fails outright or — worse — lands on unrelated data. `mke2fs -n -b <size>` must be run with the *actual* block size to enumerate the right backups.

**A1.5** — Only **`df -i`** is unconditionally safe; it is a `statfs(2)` call served by the kernel from the in-memory superblock. `e2fsck -n` opens the raw device read-only and will report spurious inconsistencies on a mounted, actively-written filesystem because the kernel's dirty metadata is not yet on disk — it is safe in the sense of not writing, but its output is unreliable unless the mount is read-only. `xfs_repair -n` **refuses to run** on a mounted filesystem at all.

---

### Block 2 — `df` vs `du`

**A2.1** — They consult different structures.
- `df` calls `statfs(2)`. The kernel answers from the **superblock / allocation-group free-space counters** — the filesystem's own authoritative accounting of allocated blocks.
- `du` walks the **directory tree**, `stat(2)`-ing each reachable entry and summing `st_blocks`.
An inode with `i_links_count == 0` but a non-zero open-file-descriptor reference count is still allocated (so `df` counts it) but is reachable from no directory entry (so `du` cannot see it). The blocks are freed only when the last descriptor closes and the inode's reference count reaches zero.

**A2.2** — `NLINK` is the inode's hard-link count, `i_links_count`. `0` means no directory entry anywhere on the filesystem points at this inode; it survives only because a process holds it open. `lsof +L1` selects **open files whose link count is less than 1**, i.e. exactly the deleted-but-open set. That is the canonical one-command diagnosis.

**A2.3** — Close the descriptor without killing the process. Identify it with `lsof +L1 /path`, note PID and FD, then either:
- **Truncate through `/proc`** (space is reclaimed immediately, process keeps running): `: > /proc/<PID>/fd/<N>` or `truncate -s 0 /proc/<PID>/fd/<N>`.
- Or signal the process to reopen its logs: `kill -HUP <PID>`, or `systemctl reload <unit>`.
Truncating through `/proc/<PID>/fd/N` writes to the same open file description, so the inode's data blocks are released while the fd stays valid. A process appending with `O_APPEND` continues correctly; one that tracks its own offset will produce a sparse file afterwards — harmless. Rebooting is never required.

**A2.4** — It consumes space on the **root filesystem**. The file was written into the `/mnt/ext4` directory of `/` while nothing was mounted there; mounting the loop device over that directory hides the entry but does not move or free it. `df -h /` is the line that changes when you delete it — and you can only delete it after unmounting or via a bind mount of `/` elsewhere. This is why `df`-based monitoring on `/` can climb with no visible cause.

**A2.5** — **Reserved blocks.** `df` computes `Use%` as `used / (used + avail)`, and `avail` excludes the root reservation — so the percentage saturates at 100 % while `Avail` still shows a value in the reserved range and only UID 0 can allocate.
Diagnose and fix with the same tool:
```bash
tune2fs -l /dev/sdaN | grep -Ei 'block count|reserved block count'
tune2fs -m 1 /dev/sdaN        # or: tune2fs -r <blocks>
```
On a dedicated data volume 1 % (or 0) is appropriate; on `/` and `/var` keep a few percent so root can still log in and syslog can still write during an incident.

**A2.6** — `du -x` (`--one-file-system`) stops the walk at mount boundaries. Without it, a walk of `/` descends into every mounted filesystem: the 2 TB data volume is summed into the total (making the output useless for finding what filled `/`), and the NFS mount is traversed over the network — which stalls indefinitely if the server is unreachable, hangs the monitoring script in uninterruptible sleep, and can generate enormous NFS metadata traffic.

---

### Block 3 — Inode exhaustion

**A3.1** — `ENOSPC` means "the allocator could not satisfy the request", and an ext4 file needs **two** independent resources: a free entry in the inode table, and free data blocks. `mke2fs` fixes the inode table size permanently at format time; the two pools deplete independently. A workload of millions of tiny files (mail queues, session caches, Git object stores, container layers) exhausts inodes long before blocks. `ENOSPC` does not distinguish them — only `df -i` does. **The rule: whenever you see `ENOSPC`, run both `df -h` and `df -i`.**

**A3.2** —
- `-N <count>`: set the absolute number of inodes explicitly.
- `-i <bytes-per-inode>`: set the *ratio*; `mke2fs` computes `inode_count = fs_size / bytes_per_inode`. A **smaller** `-i` yields **more** inodes.
`-i` is the usual choice because it scales with the device; `-N` is used when you know the exact file count. Both are permanent — the inode table is a static array laid down at format time, and its size is baked into the group descriptors.

**A3.3** —
1. **Reformat** with a lower bytes-per-inode ratio (`mkfs.ext4 -i 8192` or `-N`). This **requires a backup/restore cycle** — the filesystem is destroyed.
2. **Migrate to XFS** (or move the workload to a filesystem with dynamic inode allocation), which also requires backup/restore for the volume itself but removes the failure class permanently.
A partial third option that avoids downtime: relocate the small-file workload onto a separate, appropriately-formatted volume and bind-mount or symlink it into place. `resize2fs` is *not* a remediation — it changes block count only.

**A3.4** — **No, not in this form.** XFS allocates inodes **dynamically** from free space in the allocation groups as files are created, so there is no fixed inode table to exhaust; inode capacity is bounded only by free space. The knob that can still bite you is **`imaxpct`** (visible in `xfs_info` as `imaxpct=25`), which caps the percentage of the filesystem that inodes may occupy — exceed it and inode allocation fails while blocks remain free. It is tunable online with `xfs_growfs -m <pct>`. Historically, 32-bit inode numbers on very large filesystems caused a related `ENOSPC` when inodes could not be placed below 1 TiB; the `inode64` mount option (default since Linux 3.7) resolved that.

**A3.5** — `du -sh` sums **bytes**, which is precisely the dimension that is *not* exhausted — the offending directory may total a few megabytes across a million files and rank last in a `du -sh | sort -rh`. Counting directory entries with `find -printf '%h\n' | sort | uniq -c | sort -rn` (or `du --inodes` where supported) measures the dimension that actually ran out and points straight at the offending directory.

---

### Block 4 — `dumpe2fs` and `tune2fs`

**A4.1** — `dumpe2fs` is a **read-only reporting** tool: it dumps superblock *and* block-group metadata and never modifies the filesystem. `tune2fs` is a **modification** tool whose `-l` flag happens to print the superblock as a convenience. The thing only `dumpe2fs` shows is the **per-block-group layout** — for each group: block range, checksum, backup superblock and group-descriptor locations, block bitmap, inode bitmap, inode table extent, free block/inode counts, and directory count. `tune2fs -l` never descends below the superblock. (Also `dumpe2fs -b` prints the bad-block list, and `dumpe2fs -f` forces display despite feature flags it does not recognise.)

**A4.2** — The **`sparse_super`** feature. Without it, every block group carries a superblock and group-descriptor copy. With it, backups are stored only in group 0 and in groups that are a power of 3, 5 or 7 (1, 3, 5, 7, 9, 25, 27, 49, 81, 125, 343, …). The trade-off: **fewer redundant copies** (marginally lower resilience if many groups are lost) in exchange for **substantially more usable space** — on a multi-terabyte filesystem the group-descriptor table alone is megabytes per group, and replicating it into thousands of groups would waste gigabytes. It is enabled by default on every modern ext2/3/4 filesystem.

**A4.3** —
- 4096-byte blocks: `32768 × 4096 = 134,217,728` → byte offset **128 MiB**.
- 1024-byte blocks: `8193 × 1024 = 8,389,632` → byte offset **~8.0 MiB**.
It matters because `e2fsck -b <n>` interprets `<n>` as a **block number**, and the block size it assumes comes either from the (now destroyed) primary superblock or from `-B`. If `e2fsck` guesses 1024 while the filesystem is 4096, block 32768 resolves to byte offset 32 MiB — arbitrary file data, not a superblock. Getting this pair wrong is the classic way to turn a recoverable filesystem into an unrecoverable one, which is exactly why you run `-n` first.

**A4.4** —
- **The risk it disables:** periodic, unconditional full verification. Silent metadata corruption from firmware bugs, controller faults, bad RAM or cosmic-ray bitflips accumulates undetected until it becomes catastrophic. Journalling protects **crash consistency**, not **correctness** — a journal replays a consistent set of transactions but cannot notice that a block was written to the wrong LBA.
- **The problem it prevents:** an unpredictable, unbounded-duration full `fsck` at boot on a filesystem that mounted cleanly. On a multi-terabyte filesystem this can add tens of minutes to a boot, and it triggers at the worst possible time — during the emergency reboot everyone is already watching. In a fleet, mount-count-based checks also cause a "thundering herd" as machines built from the same image cross the threshold together.
The modern posture: disable time/count triggers, and get the assurance from checksummed metadata (`metadata_csum`), end-to-end verification at a higher layer, RAID scrubs, and monitored SMART data.

**A4.5** — With `remount-ro`, on detecting a metadata inconsistency the kernel calls `ext4_error()`, logs to `dmesg`, sets the `EXT2_ERROR_FS` bit in the superblock (so the next boot forces `fsck`), increments `s_error_count` / records first and last error details, and **remounts the filesystem read-only in place**. Running processes get `EROFS` on writes; reads continue. This contains the damage while keeping the machine reachable for diagnosis.
`panic` is correct for a **clustered node** because it converts a partial, ambiguous failure into an unambiguous one. A node whose storage is read-only may still hold cluster locks, answer health checks, and serve stale reads — a *split-brain* hazard. Panicking makes the node instantly and visibly dead, which is precisely what fencing and failover logic are built to handle. The same reasoning underpins `kernel.panic_on_oops` and hardware watchdogs in HA clusters.

**A4.6** — A clean `e2fsck` run resets:
- `s_lastcheck` → current time (this is what `tune2fs -T now` sets manually)
- `s_mnt_count` → `0` (equivalently `tune2fs -C 0`)
- `s_state` → `EXT2_VALID_FS`, clearing the `EXT2_ERROR_FS` bit
- `s_last_orphan` → cleared, once the orphan inode list is processed
It also rewrites the free block/inode counters and the block/inode bitmaps to match reality, and updates the backup superblocks.

---

### Block 5 — `fsck` / `e2fsck`

**A5.1** —
- **`fsck -N`** (`--dry-run`) is a flag of the *front end*. `fsck` does its `/etc/fstab` parsing and ordering, then **prints the checker command lines it would execute and exits**. No checker process is ever started; the device is never opened.
- **`e2fsck -n`** actually **runs the check**, opening the device read-only and answering "no" to every repair prompt. It reads the entire filesystem and produces a full damage report.
Both are non-destructive, but only `-n` tells you the filesystem's condition. Use `fsck -N` to audit boot policy; use `e2fsck -fn` to assess damage.

**A5.2** —
- `4` = "filesystem errors left uncorrected" — expected from `-n`, which declines every fix by design.
- `1` = "filesystem errors corrected" — the repair succeeded and the filesystem was modified.
**`4` is the paging incident.** It means a filesystem is currently inconsistent and nothing has fixed it — the system may be running on a damaged or read-only mount. `1` warrants a ticket and a root-cause investigation (corruption should not happen), but the immediate condition is resolved. Note that neither is `0`, so a script written as `if fsck ...; then` treats both as failure — always compare against the bitmask.

**A5.3** — `5 = 1 + 4`. Across the set of filesystems checked, **at least one was successfully repaired** and **at least one still has uncorrected errors**. The operator must not proceed with a normal boot: identify which device failed (from the boot log or by re-running `e2fsck -fn` per device), then run `e2fsck -f` **interactively** on that device with the filesystem unmounted — from an emergency shell or rescue media if it is the root filesystem. Take a block-level image first (`dd`/`ddrescue`) if the data is irreplaceable. Only after a subsequent `e2fsck -f` returns `0` should the system be returned to service.

**A5.4** — `-f` **forces** the check. Without it, `e2fsck` sees the `EXT2_VALID_FS` bit in `s_state`, concludes there is nothing to do, and exits `0` immediately.
"Clean" asserts exactly one thing: **the filesystem was unmounted in an orderly fashion, so the journal contains no unreplayed transactions.** It says nothing whatsoever about whether the metadata is *correct*. A filesystem with a corrupt inode bitmap, a cross-linked block, or a wrong link count is still marked "clean" if it was unmounted properly. Every corruption you injected in this exercise left the flag clean — which is why an audit or a post-incident verification must always pass `-f`.

**A5.5** — Unix separates **name** from **content**. A directory entry (dentry) is a `(name → inode number)` pair stored in the parent directory's data blocks; the **inode** holds the metadata and the pointers/extents to the data blocks, and it has **no back-pointer to any name**. `debugfs unlink` deleted the dentry only. `e2fsck` Pass 4 then found an inode with a positive link count that no directory references — an "unattached inode" — and reconnected it. Since the name existed only in the destroyed dentry, `e2fsck` has nothing to restore it from and synthesises `#<inode-number>`.
`lost+found` must be preallocated by `mke2fs` because `e2fsck` runs against a filesystem it already knows to be **inconsistent**: creating a directory would require allocating an inode and blocks and updating bitmaps that are themselves suspect. Having the directory (and its data blocks) already present lets `e2fsck` reconnect inodes by writing directory entries into space it knows is valid. This is also why `lost+found` should never be deleted, and why recovery tooling (`file`, `md5sum`, `strings`, application-level identification) is required to work out what the `#N` files actually are.

**A5.6** —
- **`-p` (preen)** repairs only errors that can be fixed with **no possible data loss and no operator judgement** — free-count mismatches, bitmap divergence, orphan-inode list processing. On encountering anything ambiguous (unattached inodes, cross-linked blocks, duplicate blocks) it **stops immediately and exits 4**, deferring to a human.
- **`-y`** answers yes to **every** prompt, including destructive ones: clearing inodes, truncating files, deleting directory entries, rebuilding the root directory.
`-y` at boot is dangerous because it is unattended and unbounded. A filesystem damaged by a **failing disk or a flaky controller** presents as arbitrary garbage; `-y` will "repair" it by clearing thousands of inodes, and you discover the extent of the data loss after the fact with no chance to image the device first. Preen's job is precisely to draw the line between "safe to automate" and "wake someone up".

**A5.7** — Because `e2fsck` makes **multiple passes over interdependent structures**, and a repair in a late pass can invalidate an assumption from an earlier one. Reconnecting an inode to `lost+found` in Pass 4, for example, allocates a directory entry and changes link counts that Pass 1's block accounting and Pass 5's bitmap summary were computed against. `e2fsck` itself prints `***** FILE SYSTEM WAS MODIFIED *****` and, when it deems it necessary, `***** REBOOT SYSTEM *****`. **The completion criterion is not "the repair ran" — it is "a subsequent `e2fsck -f` finds nothing and exits 0."** A second run that still reports errors means either the damage is beyond a single pass, or the underlying device is actively failing.

---

### Block 6 — Superblock recovery

**A6.1** — The first 1024 bytes of the device are reserved for the **boot sector / MBR** (partition table, boot code). Placing the superblock at offset 1024 lets a filesystem occupy a whole raw device or a partition whose start coincides with a boot record without the two overwriting each other. The offset is a **fixed byte constant**, independent of block size — with 1024-byte blocks the superblock is block 1; with 4096-byte blocks it lives *inside* block 0, at byte 1024 of that block. This is why `dd bs=1024 seek=1 count=1` destroys the superblock without touching the group descriptors (which start at block 1 = offset 4096 on a 4 KiB filesystem).

**A6.2** — A safe procedure, entirely read-only until the last step:
1. Gather evidence first: `file -s /dev/sdX`, `dmesg`, any historical `dumpe2fs -h` output, and `/etc/fstab` (which may record the type). If a partition table exists, `blkid`/`lsblk -f` may still identify neighbours.
2. Enumerate candidates for the most likely size: `mke2fs -n -b 4096 /dev/sdX` → backups at 32768, 98304, …
3. **Test read-only**: `e2fsck -fn -b 32768 -B 4096 /dev/sdX`. If the block size is wrong, `e2fsck` reports another bad magic number or nonsensical geometry; if right, you get a coherent damage report with plausible inode/block counts.
4. If it fails, repeat with `-b 1024`: `mke2fs -n -b 1024 /dev/sdX` → 8193, 24577, 40961, 57345, 73729; then `e2fsck -fn -b 8193 -B 1024`.
5. Try successive backups (`98304`, then `24577`, …) if the first candidate is itself damaged.
6. Only once a `-n` run produces a coherent report do you run the same command with `-y`.
Since every step through 5 is read-only, a wrong guess costs nothing but time. On a device you cannot afford to lose, image it first (`ddrescue`) and work on the copy.

**A6.3** — `-b <n>` names the **block number** of the superblock to use. `-B <size>` declares the **block size in bytes** that `e2fsck` should assume when converting that block number to a byte offset.
`-B` is required when `e2fsck` **cannot infer the block size**, which is exactly the case when the primary superblock — the structure that records it — has been destroyed. Without `-B`, `e2fsck` probes plausible sizes, and a wrong inference makes `-b 32768` point at unrelated data. Supplying both removes the guesswork. On a filesystem whose primary superblock is intact, neither flag is needed.

**A6.4** — The **free block and inode counters, and the bitmaps, are not part of the superblock's critical identity** — they are frequently-updated accounting fields, and the backup superblock is a snapshot taken at `mke2fs` time that has never been refreshed since. Every allocation and free since format time is absent from it. So after adopting the backup, `e2fsck` finds its free counts wildly disagree with what Pass 1 computed by actually walking the inodes and extents. Pass 5 then rewrites the summaries from the authoritative walk. This is normal and is precisely what the check is for. What would be alarming is the opposite class of message — cross-linked blocks, "inode has illegal block", or thousands of cleared inodes — which indicates damage well beyond the superblock.

**A6.5** — **Take a block-level image before writing anything.** A repair is irreversible; if `e2fsck -y` makes the wrong call you cannot undo it, and forensic recovery tools work far better on the pre-repair state.
```bash
ddrescue -f -n /dev/sdX /mnt/rescue/sdX.img /mnt/rescue/sdX.map   # preferred: tolerates read errors
# or, when the device reads cleanly:
dd if=/dev/sdX of=/mnt/rescue/sdX.img bs=4M conv=noerror,sync status=progress
```
Then run the repair against the image (`losetup` it) or, if you must repair in place, keep the image as the fallback. `e2fsck` also offers an undo file: `e2fsck -z /mnt/rescue/undo.e2undo -fy /dev/sdX`, replayable with `e2undo` — cheaper than a full image but only covers `e2fsck`'s own writes.

**A6.6** — `blkid` reads the filesystem's **magic number and the identifying superblock fields** (UUID, LABEL, TYPE, and for ext4 also `BLOCK_SIZE` and `UUID_SUB`). It probes a set of known offsets — offset 1024 for ext2/3/4 (`0xEF53`), offset 0 for XFS (`XFSB`) — and with the superblock zeroed there is no magic number, so it reports nothing.
The implication is severe: an `/etc/fstab` entry written as `UUID=...` **cannot be resolved**, because `/dev/disk/by-uuid/<uuid>` is a udev symlink created from exactly this probe. At boot the device node simply does not exist, systemd's generated `.mount` unit waits on a device that never appears, and the boot drops into emergency mode after the timeout — with an error about the *UUID*, not about a bad superblock, which sends people looking in the wrong place. The same applies to `LABEL=` and to `/dev/disk/by-label/`. It also explains why `xfs_admin -U generate` matters after cloning: two devices exposing the same UUID make the `by-uuid` symlink ambiguous.

---

### Block 7 — XFS

**A7.1** — The `fs_passno` field must be **`0`** for XFS. (A non-zero value merely invokes the no-op `fsck.xfs`, so it is harmless but misleading — set it to `0` so the fstab documents the actual policy.)
Instead of a boot-time consistency scan, XFS relies on **metadata journalling with log replay at mount time**: the kernel replays the internal log during `mount(2)`, restoring transactional consistency in bounded time proportional to log size rather than filesystem size. That property — **mount time independent of filesystem size** — is a core XFS design goal and the reason it is chosen for multi-petabyte volumes, where an ext-style full check would take days. `xfs_repair` exists for damage the log cannot fix, and it is an explicit, offline, operator-invoked action, never automatic.

**A7.2** —
- **`xfs_repair` must be offline** because it rebuilds metadata by reading and writing the raw device directly. A mounted filesystem has dirty metadata in the page cache and in-flight transactions in the log that `xfs_repair` cannot see; it would repair a stale on-disk image, and the kernel would then flush its cached (now divergent) metadata over the repairs. Both views are self-consistent and mutually incompatible — guaranteed corruption. It also needs a quiescent log to interpret.
- **`xfs_fsr` must be online** because it is not a repair tool at all: it defragments by allocating a new, contiguous temporary inode, copying the extents, and then performing an **atomic extent swap** via the `XFS_IOC_SWAPEXT` ioctl. That ioctl is a kernel service — it needs the live filesystem to guarantee atomicity against concurrent writers, maintain the file's identity (inode number, links, open descriptors), and journal the swap. There is no way to do that from userspace against a raw device.

**A7.3** — XFS divides the device into **allocation groups** (`agcount=4`, `agblocks=65536` here), and **each AG begins with a complete superblock copy** — not a sparse subset as in ext4, and not at locations that depend on a block size you can no longer read. AG 0's superblock is the primary; AGs 1..n-1 hold secondaries. Because every secondary superblock **records the geometry** (blocksize, agblocks, agcount, dblocks, UUID), `xfs_repair` can scan the device for the `XFSB` magic number, validate a candidate against its own self-describing fields and the surrounding AG headers, and reconstruct everything — including the block size — without operator input. ext4's backup superblocks are also self-describing, but you must *find* one first, and their locations are a function of the block size that the destroyed superblock recorded. Hence `-b`/`-B`.

**A7.4** — Ordered procedure:
1. **Stop writing to it.** Do not retry the mount repeatedly; check `dmesg` for the actual error and confirm the hardware path is healthy (`smartctl`, multipath state, controller logs). Repairing on top of a failing device destroys data.
2. **Take a metadata backup**, and a full image if the data is irreplaceable:
   ```bash
   xfs_metadump -o /dev/sdX /rescue/sdX.metadump      # small, for analysis and for vendor support
   ddrescue -f -n /dev/sdX /rescue/sdX.img /rescue/sdX.map   # full image, if you can afford the space
   ```
3. **Attempt a normal log replay** — this is the step people skip. Mounting and unmounting cleanly replays the log and is the *only* mechanism that preserves the transactions in it:
   ```bash
   mount /dev/sdX /mnt/x && umount /mnt/x
   ```
   If it mounts, unmount and go to step 5.
4. **Diagnose read-only**: `xfs_repair -n /dev/sdX`. If it completes with only ordinary inconsistencies, go to step 5.
5. **Repair**: `xfs_repair /dev/sdX`, then verify with `xfs_repair -n` (must be clean) before remounting.
6. **`xfs_repair -L` becomes acceptable only here**: after steps 1–3 have failed — the filesystem will not mount, and `xfs_repair` itself refuses to proceed and explicitly tells you the log is corrupt and cannot be replayed — and only once the backups from step 2 exist. `-L` **zeroes the log**, permanently discarding every transaction it held: recently written files, renames and metadata updates are lost, and files may be left truncated or with stale contents. After `-L` you must run `xfs_repair` again, and afterwards audit the filesystem (and `lost+found`) against your application's expectations. Never reach for `-L` first because "the repair didn't work".

**A7.5** — The number is a ratio of **actual extents to the theoretical ideal (one extent per file)**, and that ideal is meaningless for most real workloads. Files that are genuinely sparse, preallocated with `fallocate`, written by databases in fixed-size chunks, or subject to `reflink`/CoW sharing legitimately have many extents — and XFS's delayed allocation and extent-based allocator already produce large, well-placed extents. A high "fragmentation factor" on such a filesystem indicates nothing about performance, which is why `xfs_db` prints the disclaimer itself.
What to measure instead, before deciding to run `xfs_fsr`:
- **Actual I/O behaviour**: latency and IOPS from `iostat -x`, `blktrace`/`blkparse`, or application-level p99 latency. Fragmentation only matters if it is causing seeks that hurt.
- **Per-file extent counts for the files that matter**: `xfs_bmap -vp <file>`, or `filefrag -v <file>`. A 200 GB database file in 4 extents is fine; the same file in 400,000 extents is not.
- **Free-space fragmentation**, which is the real driver of future fragmentation: `xfs_db -r -c "freesp -s" /dev/sdX`.
And note the medium: on **SSD and NVMe there is no seek penalty**, so `xfs_fsr` mostly buys write amplification and wear for no gain. It is rarely worth running on modern storage.

**A7.6** — **Duplicate UUIDs.** XFS refuses to mount a filesystem whose UUID matches one already mounted, failing with `wrong fs type, bad option, bad superblock` and a `dmesg` line reading roughly *"Filesystem has duplicate UUID … can't mount"*. Beyond the mount failure, `/dev/disk/by-uuid/<uuid>` becomes ambiguous — udev creates one symlink for two devices — so `UUID=`-based `fstab` entries can silently mount the *wrong* volume across reboots. The fix, on the clone, unmounted:
```bash
xfs_admin -U generate /dev/sdY     # assign a fresh UUID
```
(`-U nil` clears it, useful for a filesystem that must be mountable alongside its original with `-o nouuid` as a temporary measure; `mount -o nouuid` bypasses the check but does **not** fix the `by-uuid` ambiguity, so treat it as a rescue option only.) The same class of problem applies to LVM (`vgimportclone`) and to ext4 (`tune2fs -U random`).

**A7.7** —

| | Grow | Shrink |
|---|---|---|
| **XFS** (`xfs_growfs`) | **Online only** — the filesystem *must* be mounted | **Impossible** |
| **ext4** (`resize2fs`) | **Online** (mounted) or offline | **Offline only** — must be unmounted |

The impossible combination is **shrinking XFS** — there is no `xfs_shrinkfs` and never has been; the only way to reduce an XFS volume is backup, `mkfs.xfs` at the smaller size, restore. This is a deliberate design decision (relocating data out of the high allocation groups and rewriting the AG structures is complex and risky for a filesystem whose primary use case is very large volumes), and it is a genuine consideration when choosing a filesystem for a volume that may need to be reduced. Note the asymmetry in the "grow" row: `xfs_growfs` operates on a **mount point** and requires the filesystem mounted, whereas `resize2fs` operates on a **device** and works either way — a common exam trap.

---

### Block 8 — Boot-time checking and `badblocks`

**A8.1** —
- **`0`** — do not check this filesystem at boot. Correct for XFS, btrfs, ZFS, swap, network filesystems, `tmpfs`, and any filesystem whose checker is not meaningful at boot.
- **`1`** — check **first**, before anything else is mounted. Reserved for the **root filesystem**.
- **`2`** — check after all pass-1 filesystems, in a second phase.
**Exactly one filesystem per host should carry `1`** — the root filesystem. Assigning `1` to more than one serialises them unnecessarily and misrepresents the boot ordering.

**A8.2** — `fsck -A` checks all pass-1 entries first, then processes pass-2 entries. Within the same pass number, it **parallelises across distinct physical devices** — it inspects the device paths and runs one checker per spindle concurrently (this is the `-P`/parallel behaviour; `fsck` deliberately does not run two checkers on the same disk at once). So two volumes on **separate disks** are checked **simultaneously**, roughly halving the wall-clock time.
If they are on the **same disk** (two partitions of one device), `fsck` **serialises** them. That is intentional: two full metadata scans competing for one set of heads produce pathological seek thrashing and are slower than running them back to back. On SSDs the penalty largely disappears, but `fsck` retains the conservative behaviour. (`fsck -s` forces serialisation everywhere; useful when checkers are interactive so their prompts do not interleave.)

**A8.3** — Two concrete reasons:
1. **`fsck.mode=force` makes boot time unbounded and unpredictable.** Every filesystem gets a full metadata scan on every boot regardless of whether it was cleanly unmounted. On a host with multi-terabyte ext4 volumes this turns a 40-second boot into tens of minutes — during an outage, when the recovery-time objective is what everyone is measuring. It also defeats the entire purpose of journalling, whose value proposition is precisely that a clean journal makes the scan unnecessary.
2. **`fsck.repair=yes` removes the human from destructive decisions, permanently.** It is `-y`: every prompt answered yes, including "clear this inode", "truncate this file", "delete this directory entry". When the underlying cause is a **failing disk or flaky controller** rather than a clean crash, the filesystem presents as arbitrary garbage and `-y` will silently destroy large amounts of recoverable data before anyone sees a console. There is then no pre-repair image to fall back on. The default `fsck.repair=preen` exists exactly to stop at the point where judgement is required.
Both flags are legitimate as **one-shot** interventions — edit the GRUB entry with `e` for a single boot, or use `systemd`'s `fsck.mode=force` once after suspected corruption. As standing configuration they trade a real, frequent cost against a rare, hypothetical benefit.

**A8.4** —

| | `badblocks -n` | `badblocks -w` |
|---|---|---|
| Name | non-destructive read-write test | destructive write-mode test |
| Method | for each block: read original → write pattern → read back and compare → **write the original data back** | writes patterns `0xaa`, `0x55`, `0xff`, `0x00` over every block and reads each back |
| Data | **preserved** (barring a crash mid-test) | **destroyed, entirely and irrecoverably** |
| Mount | **must be unmounted** | must be unmounted |
| Speed | slow (4 I/Os per block) | slower still (4 full passes) |

`-w` destroys data. Both require the filesystem unmounted, because both write to the raw device behind the kernel's back — `badblocks` refuses by default if it detects the device is mounted, and `-f` overrides that check (do not use `-f` on a mounted filesystem). The read-only default mode (`badblocks` with no `-n`/`-w`) is the only one safe on a mounted filesystem, and even it competes for I/O.

**A8.5** — `badblocks` output is a list of **block numbers in whatever unit `-b` specified**. `e2fsck -l` interprets that list in the **filesystem's** block size. With `-b 1024` output fed to a 4096-byte-block filesystem, every number is off by a factor of four: block 8192 in the list means byte offset 8 MiB, but `e2fsck` records it as filesystem block 8192 = byte offset 32 MiB.
The consequence is doubly wrong: the **actually bad sectors are left in service** (so the filesystem will keep hitting I/O errors on them), and **four times as much perfectly good space is marked unusable** at the wrong offsets — and if those offsets currently hold live data, `e2fsck` will report the blocks as in-use-and-bad and offer to clone or clear the affected inodes, i.e. data loss. This is why the man page insists the `-b` passed to `badblocks` match the filesystem block size, and why `e2fsck -c` (which invokes `badblocks` itself with the correct parameters) is the safer route.

**A8.6** — Modern drives — SSD/NVMe, and enterprise SAS/SATA HDDs alike — **remap defective sectors internally and transparently**. The drive maintains a reserve pool; on detecting a write failure or an unrecoverable read, its firmware retires the physical sector and redirects that LBA elsewhere. By the time an LBA returns an error to the host, the drive has already exhausted its own recovery. Consequently:
- A `badblocks` list is a snapshot of **LBAs**, not physical media, and goes stale the moment the drive remaps anything.
- On SSDs, the FTL means an LBA has no fixed physical location at all; the mapping changes on every write. Marking LBAs bad is meaningless.
- Recording bad blocks in the filesystem's bad-block inode papers over a symptom while the drive continues degrading — and on SSDs, `badblocks -w` burns a full program/erase cycle across the entire device for no diagnostic gain.

What replaced it: **SMART attributes and self-tests**, read via `smartctl` (smartmontools) and monitored by `smartd`. The signals that matter:
- `Reallocated_Sector_Ct` / `Reallocated_Event_Count` — sectors already retired
- `Current_Pending_Sector` — sectors that failed to read and are awaiting reallocation; the strongest single predictor of imminent failure
- `Offline_Uncorrectable` / `Reported_Uncorrect`
- SSD-specific: `Media_Wearout_Indicator`, `Percentage_Used`, `Available_Spare` (NVMe), `Wear_Leveling_Count`
- `smartctl -t long /dev/sdX` for a full surface self-test performed **by the drive itself**, plus `smartctl -l selftest` and `-l error` for history.
Alongside SMART, the modern answers to media integrity are **checksummed metadata** (`metadata_csum` on ext4, CRC on XFS), **full-data checksumming** filesystems (btrfs, ZFS), and **RAID scrubs** — all of which detect corruption that a read-error scan cannot, because they catch data that comes back *successfully but wrong*.

**A8.7** —
- **`e2fsck -l <file>`** — **add** the blocks listed in `<file>` to the filesystem's existing bad-block inode (inode 1). The old list is preserved and the new entries are merged in.
- **`e2fsck -L <file>`** — **replace** the bad-block list entirely with the contents of `<file>`. The previous list is discarded.
To clear a **stale bad-block list inherited from a previous drive** (for example after restoring an image onto new hardware, or after a controller replacement), use **`-L` with an empty file**:
```bash
: > /tmp/empty
e2fsck -L /tmp/empty /dev/sdX
dumpe2fs -b /dev/sdX          # verify: the list is now empty
```
Leaving a stale list in place permanently withholds those blocks from the allocator on media where they are perfectly good — a small but real capacity loss, and a source of confusion for anyone later diagnosing the volume. Mnemonic: **lowercase `-l` = add to the list, uppercase `-L` = Lay down a new list.**

</details>

---

## Official sources

- LPI — Exam 101-500 Objectives, Topic 104.2: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Linux kernel — ext4 filesystem documentation: <https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html>
- Linux kernel — ext4 administration guide: <https://docs.kernel.org/admin-guide/ext4.html>
- Linux kernel — XFS filesystem documentation: <https://www.kernel.org/doc/html/latest/admin-guide/xfs.html>
- `e2fsck(8)`: <https://man7.org/linux/man-pages/man8/e2fsck.8.html>
- `fsck(8)`: <https://man7.org/linux/man-pages/man8/fsck.8.html>
- `mke2fs(8)`: <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- `tune2fs(8)`: <https://man7.org/linux/man-pages/man8/tune2fs.8.html>
- `dumpe2fs(8)`: <https://man7.org/linux/man-pages/man8/dumpe2fs.8.html>
- `debugfs(8)`: <https://man7.org/linux/man-pages/man8/debugfs.8.html>
- `badblocks(8)`: <https://man7.org/linux/man-pages/man8/badblocks.8.html>
- `df(1)`: <https://man7.org/linux/man-pages/man1/df.1.html>
- `du(1)`: <https://man7.org/linux/man-pages/man1/du.1.html>
- `fstab(5)`: <https://man7.org/linux/man-pages/man5/fstab.5.html>
- `systemd-fsck@.service(8)`: <https://man7.org/linux/man-pages/man8/systemd-fsck@.service.8.html>
- `xfs(5)`: <https://man7.org/linux/man-pages/man5/xfs.5.html>
- `mkfs.xfs(8)`: <https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html>
- `xfs_repair(8)`: <https://man7.org/linux/man-pages/man8/xfs_repair.8.html>
- `xfs_db(8)`: <https://man7.org/linux/man-pages/man8/xfs_db.8.html>
- `xfs_info(8)`: <https://man7.org/linux/man-pages/man8/xfs_info.8.html>
- `xfs_admin(8)`: <https://man7.org/linux/man-pages/man8/xfs_admin.8.html>
- `xfs_fsr(8)`: <https://man7.org/linux/man-pages/man8/xfs_fsr.8.html>
- `xfs_freeze(8)`: <https://man7.org/linux/man-pages/man8/xfs_freeze.8.html>
- e2fsprogs project: <https://e2fsprogs.sourceforge.net/>
- smartmontools project: <https://www.smartmontools.org/>