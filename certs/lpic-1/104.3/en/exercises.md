# LPIC-1 · 104.3 — Control mounting and unmounting of filesystems
## Guided Exercises (Exam 101-500, weight 4)

> **Scope of this lab.** Manual mount/umount, mount options and their kernel semantics, `/etc/fstab`, identification by `UUID`/`LABEL`/`PARTUUID`, user-mountable removable media, diagnosing busy filesystems, and systemd `.mount` / `.automount` units.
>
> **Prerequisites.** A Linux VM (or throwaway machine) with root access, `util-linux ≥ 2.30`, `e2fsprogs`, `dosfstools`, `lsof` and `psmisc`. **Do not run this on a machine you care about** — Exercise 9 deliberately breaks `/etc/fstab`. Everything is built on loop devices backed by regular files, so no real disk is touched.
>
> Outputs shown are representative (Debian 12 / RHEL 9 class systems); UUIDs and device names will differ on your machine — always re-read yours instead of copying the ones printed here.

---

## Exercise 1 — Read the mount table before you change it

The kernel, not `/etc/fstab`, is the authority on what is mounted right now.

1. List the mounted filesystems as a tree:

   ```bash
   findmnt
   ```

   ```
   TARGET                    SOURCE     FSTYPE     OPTIONS
   /                         /dev/vda2  ext4       rw,relatime,errors=remount-ro
   ├─/sys                    sysfs      sysfs      rw,nosuid,nodev,noexec,relatime
   │ ├─/sys/fs/cgroup        cgroup2    cgroup2    rw,nosuid,nodev,noexec,relatime,nsdelegate
   │ └─/sys/kernel/security  securityfs securityfs rw,nosuid,nodev,noexec,relatime
   ├─/proc                   proc       proc       rw,nosuid,nodev,noexec,relatime
   ├─/dev                    udev       devtmpfs   rw,nosuid,relatime,size=1980404k,...
   │ └─/dev/pts              devpts     devpts     rw,nosuid,noexec,relatime,gid=5,mode=620
   ├─/run                    tmpfs      tmpfs      rw,nosuid,nodev,noexec,relatime,size=402412k
   └─/boot/efi               /dev/vda1  vfat       rw,relatime,fmask=0077,dmask=0077,...
   ```

2. Ask the same question of the kernel directly, and compare with the legacy file:

   ```bash
   cat /proc/mounts | head -5
   ls -l /etc/mtab
   ```

   ```
   /dev/vda2 / ext4 rw,relatime,errors=remount-ro 0 0
   sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0
   proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
   udev /dev devtmpfs rw,nosuid,relatime,size=1980404k,nr_inodes=495101,mode=755 0 0
   devpts /dev/pts devpts rw,nosuid,noexec,relatime,gid=5,mode=620,ptmxmode=000 0 0

   lrwxrwxrwx 1 root root 19 Aug 26 09:14 /etc/mtab -> ../proc/self/mounts
   ```

3. Look at the richer, per-mount view the VFS exposes:

   ```bash
   grep ' / ' /proc/self/mountinfo
   ```

   ```
   26 1 254:2 / / rw,relatime shared:1 - ext4 /dev/vda2 rw,errors=remount-ro
   ```

   Everything **before** the ` - ` separator is per-mount (mount ID, parent ID, source subtree, mount point, VFS flags, propagation); everything **after** is filesystem type, source and **per-superblock** options.

4. Filter without grepping, using `findmnt`'s query interface:

   ```bash
   findmnt --types ext4 --output TARGET,SOURCE,UUID,OPTIONS --noheadings
   findmnt --mountpoint /boot/efi --json
   ```

5. Show what block devices exist and which carry a filesystem:

   ```bash
   lsblk -f
   ```

   ```
   NAME   FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
   vda
   ├─vda1 vfat   FAT32 EFI   9C1E-3F2A                             505.9M     1% /boot/efi
   └─vda2 ext4   1.0   root  6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33   18.2G    22% /
   ```

**Check your understanding**

- **Q1.1** — `/etc/mtab` is a symlink to `/proc/self/mounts`. What operational problem did that symlink solve, and what information is *lost* compared with the old writable `/etc/mtab` file?
- **Q1.2** — In the `mountinfo` line above, `nosuid` would appear before the ` - ` while `errors=remount-ro` appears after it. Why does that distinction matter when the *same block device* is mounted twice at two different paths?
- **Q1.3** — `findmnt` and `mount` (with no arguments) both list mounts. Which one is safe to parse in a script, and why?

---

## Exercise 2 — Build a disposable filesystem on a loop device

2. Create a 256 MiB sparse backing file and confirm it consumes almost no space yet:

   ```bash
   sudo -i
   truncate -s 256M /root/lab-ext4.img
   ls -lh /root/lab-ext4.img
   du -h  /root/lab-ext4.img
   ```

   ```
   -rw-r--r-- 1 root root 256M Aug 26 09:20 /root/lab-ext4.img
   0	/root/lab-ext4.img
   ```

2. Attach it to a free loop device and note the name that is printed:

   ```bash
   losetup --find --show /root/lab-ext4.img
   ```

   ```
   /dev/loop0
   ```

3. Inspect the association:

   ```bash
   losetup -a
   lsblk /dev/loop0
   ```

   ```
   /dev/loop0: [2049]:1049234 (/root/lab-ext4.img)
   NAME   MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
   loop0    7:0    0  256M  0 loop
   ```

4. Create an ext4 filesystem with a label:

   ```bash
   mkfs.ext4 -L LABDATA /dev/loop0
   ```

   ```
   mke2fs 1.47.0 (5-Feb-2023)
   Discarding device blocks: done
   Creating filesystem with 262144 1k blocks and 65536 inodes
   Filesystem UUID: 8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92
   Superblock backups stored on blocks:
   	8193, 24577, 40961, 57345, 73729, 204801, 221185

   Allocating group tables: done
   Writing inode tables: done
   Creating journal (8192 blocks): done
   Writing superblocks and filesystem accounting information: done
   ```

5. Create a second image, formatted `vfat`, that will play the part of a USB stick later:

   ```bash
   truncate -s 128M /root/lab-usb.img
   losetup --find --show /root/lab-usb.img
   mkfs.vfat -n LABUSB /dev/loop1
   ```

   ```
   /dev/loop1
   mkfs.fat 4.2 (2021-01-31)
   ```

6. Create the mount points:

   ```bash
   mkdir -p /mnt/lab /mnt/usb
   ```

**Check your understanding**

- **Q2.1** — Why does `du` report `0` while `ls -lh` reports `256M`? What risk does that introduce if the image lives on a nearly full filesystem?
- **Q2.2** — You could have skipped `losetup` entirely and run `mount -o loop /root/lab-ext4.img /mnt/lab`. What does `mount` do behind the scenes in that case, and what happens to the loop device on `umount`?
- **Q2.3** — `mkfs.ext4 /root/lab-ext4.img` (on the file, not on `/dev/loop0`) prompts `is not a block special device. Proceed anyway? (y,N)`. Is that prompt protecting you from anything real?

---

## Exercise 3 — Mount by hand, and prove what the options actually do

1. Mount the ext4 image read-write with the default options and verify the result:

   ```bash
   mount -t ext4 /dev/loop0 /mnt/lab
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE     FSTYPE OPTIONS
   /mnt/lab /dev/loop0 ext4   rw,relatime
   ```

2. Write something, then flip the mount to read-only **without unmounting**:

   ```bash
   echo "production data" > /mnt/lab/notes.txt
   mount -o remount,ro /mnt/lab
   findmnt -no OPTIONS /mnt/lab
   echo "more" >> /mnt/lab/notes.txt
   ```

   ```
   ro,relatime
   -bash: /mnt/lab/notes.txt: Read-only file system
   ```

3. Go back to read-write and prove `noexec`:

   ```bash
   mount -o remount,rw /mnt/lab
   printf '#!/bin/sh\necho "I ran"\n' > /mnt/lab/hello.sh
   chmod +x /mnt/lab/hello.sh
   /mnt/lab/hello.sh                 # works
   mount -o remount,noexec /mnt/lab
   /mnt/lab/hello.sh                 # now blocked
   sh /mnt/lab/hello.sh              # and this?
   ```

   ```
   I ran
   -bash: /mnt/lab/hello.sh: Permission denied
   I ran
   ```

4. Prove `nosuid` with a real setuid binary:

   ```bash
   cp /usr/bin/id /mnt/lab/id-suid
   chown root:root /mnt/lab/id-suid
   chmod 4755 /mnt/lab/id-suid
   mount -o remount,exec,suid /mnt/lab
   su - nobody -s /bin/sh -c '/mnt/lab/id-suid'
   mount -o remount,nosuid /mnt/lab
   su - nobody -s /bin/sh -c '/mnt/lab/id-suid'
   ```

   ```
   uid=65534(nobody) gid=65534(nogroup) euid=0(root) groups=65534(nogroup)
   uid=65534(nobody) gid=65534(nogroup) groups=65534(nogroup)
   ```

5. Compare the two categories of options in `mountinfo`:

   ```bash
   mount -o remount,nosuid,nodev,noexec /mnt/lab
   grep /mnt/lab /proc/self/mountinfo
   ```

   ```
   112 26 7:0 / /mnt/lab rw,nosuid,nodev,noexec,relatime shared:74 - ext4 /dev/loop0 rw
   ```

6. Mount the *same* filesystem a second time, read-only, somewhere else:

   ```bash
   mkdir -p /mnt/lab-ro
   mount -o ro /dev/loop0 /mnt/lab-ro
   findmnt --source /dev/loop0
   ```

   ```
   TARGET      SOURCE     FSTYPE OPTIONS
   /mnt/lab    /dev/loop0 ext4   rw,nosuid,nodev,noexec,relatime
   /mnt/lab-ro /dev/loop0 ext4   ro,relatime
   ```

7. Bind-mount a subtree — no new filesystem is involved:

   ```bash
   mkdir -p /mnt/lab/sub /srv/exported
   mount --bind /mnt/lab/sub /srv/exported
   findmnt /srv/exported
   mount -o remount,bind,ro /srv/exported     # note: bind + remount, in that order
   findmnt -no OPTIONS /srv/exported
   ```

   ```
   TARGET       SOURCE               FSTYPE OPTIONS
   /srv/exported /dev/loop0[/sub]    ext4   rw,nosuid,nodev,noexec,relatime
   ro,nosuid,nodev,noexec,relatime
   ```

8. Undo the extra mounts:

   ```bash
   umount /srv/exported /mnt/lab-ro
   ```

**Check your understanding**

- **Q3.1** — In step 3, `/mnt/lab/hello.sh` was denied but `sh /mnt/lab/hello.sh` still ran. Explain precisely why, and what that means for `noexec` as a security control.
- **Q3.2** — In step 6, one mount is `rw` and the other `ro` on the same device. Which of `ro`, `nosuid`, `relatime`, `errors=remount-ro` can genuinely differ between the two, and which cannot?
- **Q3.3** — Why does `mount -o remount,ro /srv/exported` (without `bind`) not do what you want on a bind mount?
- **Q3.4** — `mount -o remount,ro /` succeeds on a busy root filesystem, but `mount -o remount,ro /home` may fail with `device is busy`. What is the difference?

---

## Exercise 4 — Identify filesystems: UUID, LABEL, PARTUUID

1. Read the identifiers from the superblocks:

   ```bash
   blkid /dev/loop0 /dev/loop1
   ```

   ```
   /dev/loop0: LABEL="LABDATA" UUID="8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92" BLOCK_SIZE="1024" TYPE="ext4"
   /dev/loop1: SEC_TYPE="msdos" LABEL_FATBOOT="LABUSB" LABEL="LABUSB" UUID="A1B2-C3D4" TYPE="vfat"
   ```

2. Mount by `UUID=` and by `LABEL=` instead of by device node:

   ```bash
   umount /mnt/lab
   mount UUID=8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92 /mnt/lab
   findmnt -no SOURCE /mnt/lab
   umount /mnt/lab
   mount LABEL=LABDATA /mnt/lab
   findmnt -no SOURCE /mnt/lab
   ```

   ```
   /dev/loop0
   /dev/loop0
   ```

3. See how the resolution actually happens — udev-maintained symlink farms:

   ```bash
   ls -l /dev/disk/by-uuid/ | grep -i 8f0c6b1a
   ls -l /dev/disk/by-label/
   ls /dev/disk/
   ```

   ```
   lrwxrwxrwx 1 root root 11 Aug 26 09:31 8f0c6b1a-2d47-4a9e-9c53-1b7e4d0a6f92 -> ../../loop0
   lrwxrwxrwx 1 root root 11 Aug 26 09:31 LABDATA -> ../../loop0
   lrwxrwxrwx 1 root root 10 Aug 26 09:14 EFI -> ../../vda1
   by-diskseq  by-id  by-label  by-partuuid  by-path  by-uuid
   ```

4. Change the label online, and change the UUID:

   ```bash
   e2label /dev/loop0 LABDATA2         # equivalent to: tune2fs -L LABDATA2 /dev/loop0
   blkid -o value -s LABEL /dev/loop0
   umount /mnt/lab
   tune2fs -U random /dev/loop0
   blkid -o value -s UUID /dev/loop0
   ```

   ```
   LABDATA2
   tune2fs 1.47.0 (5-Feb-2023)
   d34c7b95-1e6a-4f02-b8c9-77a1e5b0c246
   ```

5. Flush the cache and re-read, so you learn the failure mode of stale data:

   ```bash
   blkid -c /dev/null /dev/loop0
   udevadm settle
   ls -l /dev/disk/by-label/
   ```

6. Compare filesystem identifiers with *partition* identifiers on the real disk:

   ```bash
   blkid /dev/vda1
   lsblk -o NAME,FSTYPE,LABEL,UUID,PARTUUID,PARTLABEL /dev/vda
   ```

   ```
   /dev/vda1: LABEL="EFI" UUID="9C1E-3F2A" BLOCK_SIZE="512" TYPE="vfat" PARTUUID="a3f1c2d1-01"
   NAME   FSTYPE LABEL UUID                                 PARTUUID     PARTLABEL
   vda
   ├─vda1 vfat   EFI   9C1E-3F2A                            a3f1c2d1-01
   └─vda2 ext4   root  6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33 a3f1c2d1-02
   ```

**Check your understanding**

- **Q4.1** — `/dev/sdb1` on Monday can be `/dev/sdc1` on Tuesday. Name the two mechanisms that cause that, and explain why `UUID=` in `/etc/fstab` is the standard mitigation.
- **Q4.2** — `LABEL=` is more readable than `UUID=`. Give a concrete scenario where mounting by label boots the *wrong* filesystem while mounting by UUID would not.
- **Q4.3** — What is the practical difference between `UUID=`, `PARTUUID=` and `PARTLABEL=`? Which one survives `mkfs`, and which one survives repartitioning?
- **Q4.4** — After `dd if=/dev/sda1 of=/dev/sdb1` (a raw clone of a partition), what breaks, and which command repairs it?

---

## Exercise 5 — `/etc/fstab`: persistent mounts, done safely

1. Read the existing table and identify the six fields:

   ```bash
   grep -v '^\s*#' /etc/fstab | column -t
   ```

   ```
   UUID=6f8a5c3e-4b21-4c9a-9f0e-2b7d1a5c8e33  /          ext4  errors=remount-ro   0  1
   UUID=9C1E-3F2A                             /boot/efi  vfat  umask=0077          0  1
   /dev/vda3                                  none       swap  sw                  0  0
   tmpfs                                      /tmp       tmpfs defaults,nosuid,nodev,size=2G  0  0
   ```

   | # | Field | Meaning |
   |---|---|---|
   | 1 | `fs_spec` | Source: device node, `UUID=`, `LABEL=`, `PARTUUID=`, network share, or pseudo-source (`tmpfs`, `none`) |
   | 2 | `fs_file` | Mount point (`none` for swap; `swap` is also accepted) |
   | 3 | `fs_vfstype` | Filesystem type, or `auto` to let `blkid` decide, or `swap` |
   | 4 | `fs_mntops` | Comma-separated options, no spaces |
   | 5 | `fs_freq` | `dump(8)` flag — `0` in practice |
   | 6 | `fs_passno` | `fsck` order at boot: `1` for root, `2` for others, `0` to skip |

2. Back up the file before touching it. This is not optional:

   ```bash
   cp -a /etc/fstab /etc/fstab.bak
   ```

3. Append entries for the lab filesystems, using the current UUID:

   ```bash
   LABUUID=$(blkid -o value -s UUID /dev/loop0)
   cat >> /etc/fstab <<EOF

   # --- LPIC-1 104.3 lab ---
   UUID=$LABUUID  /mnt/lab  ext4  defaults,nosuid,nodev,noatime,nofail  0  2
   EOF
   tail -3 /etc/fstab
   ```

4. **Validate before trusting it:**

   ```bash
   findmnt --verify --verbose
   ```

   ```
   /
      [ ] target exists
      [ ] UUID=6f8a5c3e-... translated to /dev/vda2
      [ ] FS type is ext4
   ...
   /mnt/lab
      [ ] target exists
      [ ] UUID=d34c7b95-... translated to /dev/loop0
      [ ] FS type is ext4
      [ ] recommended root FS passno is 1 (current is 2)

   Success, no errors or warnings detected
   ```

5. Mount everything declared in `fstab` that is not yet mounted:

   ```bash
   mount -a
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE     FSTYPE OPTIONS
   /mnt/lab /dev/loop0 ext4   rw,nosuid,nodev,noatime
   ```

6. With the entry present, the short form now works, and options come from `fstab`:

   ```bash
   umount /mnt/lab
   mount /mnt/lab
   findmnt -no OPTIONS /mnt/lab
   mount -o ro /mnt/lab && findmnt -no OPTIONS /mnt/lab    # fstab options + your override
   ```

   ```
   rw,nosuid,nodev,noatime
   ro,nosuid,nodev,noatime
   ```

7. Tell systemd that `fstab` changed (it is compiled into units at boot — see Exercise 8):

   ```bash
   systemctl daemon-reload
   systemctl status mnt-lab.mount --no-pager | head -6
   ```

   ```
   ● mnt-lab.mount - /mnt/lab
        Loaded: loaded (/etc/fstab; generated)
        Active: active (mounted) since Wed 2026-08-26 09:44:11 UTC; 12s ago
         Where: /mnt/lab
          What: /dev/loop0
          Docs: man:fstab(5)
   ```

**Check your understanding**

- **Q5.1** — What exactly does `mount -a` skip, and which single option would you add to the lab entry so that `mount -a` ignores it?
- **Q5.2** — Explain `nofail` and `_netdev`. If a removable USB disk is listed in `fstab` and is unplugged at boot, which of the two prevents the boot from failing, and what does the other one do?
- **Q5.3** — Why is `defaults,ro` different from `ro,defaults`? (Think about how `mount` parses the option string.) And what does `defaults` actually expand to?
- **Q5.4** — Field 6 (`fs_passno`) is `1` for `/` and `2` for the rest. What does the number control, and why is `0` correct for an NFS share, a `tmpfs` and a Btrfs volume?
- **Q5.5** — You edited `fstab` and ran `mount -a` successfully, but did **not** run `systemctl daemon-reload`. Name a concrete situation where that omission bites you later.

---

## Exercise 6 — User-mountable removable filesystems

1. Create an unprivileged test user:

   ```bash
   useradd -m -s /bin/bash student
   ```

2. Add an `fstab` entry for the "USB stick" that a normal user may mount:

   ```bash
   cat >> /etc/fstab <<'EOF'
   LABEL=LABUSB  /mnt/usb  vfat  user,noauto,noatime,uid=student,gid=student,umask=077,shortname=mixed  0  0
   EOF
   systemctl daemon-reload
   ```

3. Confirm root is *not* required:

   ```bash
   su - student -c 'mount /mnt/usb'
   su - student -c 'findmnt -no SOURCE,OPTIONS /mnt/usb'
   ```

   ```
   /dev/loop1 rw,nosuid,nodev,noexec,relatime,uid=1001,gid=1001,fmask=0077,dmask=0077,...
   ```

   Note the options the kernel reports: `nosuid`, `nodev` and `noexec` are there even though you never typed them.

4. Verify who is allowed to unmount:

   ```bash
   su - student -c 'umount /mnt/usb'      # succeeds: student mounted it
   su - student -c 'mount /mnt/usb'
   useradd -m -s /bin/bash student2
   su - student2 -c 'umount /mnt/usb'
   ```

   ```
   umount: /mnt/usb: umount failed: Operation not permitted
   ```

5. Swap `user` for `users` and repeat:

   ```bash
   sed -i 's|LABEL=LABUSB  /mnt/usb  vfat  user,|LABEL=LABUSB  /mnt/usb  vfat  users,|' /etc/fstab
   su - student2 -c 'umount /mnt/usb'     # now allowed
   grep LABUSB /etc/fstab
   ```

6. Restore the *executable* bit semantics deliberately, and observe the ordering rule:

   ```bash
   sed -i 's|users,noauto,|users,noauto,exec,|' /etc/fstab
   su - student -c 'mount /mnt/usb'
   findmnt -no OPTIONS /mnt/usb
   ```

   ```
   rw,nosuid,nodev,relatime,uid=1001,gid=1001,fmask=0077,dmask=0077,...
   ```

7. Look at the mechanism that permits all this:

   ```bash
   ls -l /usr/bin/mount /usr/bin/umount
   ```

   ```
   -rwsr-xr-x 1 root root 59704 Mar 23  2023 /usr/bin/mount
   -rwsr-xr-x 1 root root 39760 Mar 23  2023 /usr/bin/umount
   ```

8. For comparison, see what a desktop session does instead (if `udisks2` is installed):

   ```bash
   command -v udisksctl && su - student -c 'udisksctl info -b /dev/loop1 | head -8'
   ```

**Check your understanding**

- **Q6.1** — Compare `user`, `users`, `owner` and `group`. For each, state exactly *who* may mount and *who* may unmount.
- **Q6.2** — `user` implicitly enables `noexec,nosuid,nodev`. Why is that the correct default for removable media, and what is the attack it prevents?
- **Q6.3** — In step 6, `exec` had to be written *after* `users` to take effect. What is the general parsing rule, and what would `exec,users` have produced?
- **Q6.4** — `vfat` has no UNIX ownership. Explain `uid=`, `gid=`, `umask=`, `fmask=` and `dmask=`, and give the `fmask`/`dmask` pair equivalent to `umask=022`.
- **Q6.5** — On a modern desktop, plugging in a USB stick mounts it at `/run/media/<user>/<label>` with no `fstab` entry at all. Which component does that, and why is it considered safer than the setuid `mount` binary?

---

## Exercise 7 — Unmounting: busy filesystems and how to diagnose them

1. Make the filesystem busy in three different ways, from a second shell if you prefer:

   ```bash
   mount /mnt/lab 2>/dev/null
   sleep 900 > /mnt/lab/held.log &          # (a) an open file descriptor
   cd /mnt/lab                              # (b) a process CWD inside the mount
   ```

2. Try to unmount and read the error carefully:

   ```bash
   umount /mnt/lab
   ```

   ```
   umount: /mnt/lab: target is busy.
   ```

3. Find the culprits — two complementary tools:

   ```bash
   lsof +f -- /mnt/lab
   ```

   ```
   COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
   bash     4127 root  cwd    DIR    7,0     1024    2 /mnt/lab
   sleep    4162 root    1w   REG    7,0        0   14 /mnt/lab/held.log
   ```

   ```bash
   fuser -vm /mnt/lab
   ```

   ```
                        USER        PID ACCESS COMMAND
   /mnt/lab:            root       4127 ..c.. bash
                        root       4162 ...e. sleep
   ```

   `ACCESS` letters: `c` = current directory, `e` = executable running, `f` = open file, `r` = root directory, `m` = mmap'ed file.

4. Resolve it properly — release the references rather than forcing the kernel:

   ```bash
   cd /
   kill 4162          # use the PID that fuser reported
   umount /mnt/lab && echo "clean unmount"
   ```

   ```
   clean unmount
   ```

5. Now study the escape hatches. Re-create the busy condition and use a lazy unmount:

   ```bash
   mount /mnt/lab
   sleep 900 > /mnt/lab/held.log &
   umount --lazy /mnt/lab
   findmnt /mnt/lab ; echo "findmnt rc=$?"
   grep -c /mnt/lab /proc/self/mountinfo
   lsof +f -- /mnt/lab 2>/dev/null | wc -l
   ```

   ```
   findmnt rc=1
   0
   0
   ```

   The mount point is detached from the namespace immediately, but the filesystem stays alive until the last reference is dropped. Confirm the device is still held:

   ```bash
   losetup -d /dev/loop0
   ```

   ```
   losetup: /dev/loop0: detach failed: Device or resource busy
   ```

6. Clean it up for real, and learn the difference between `-l` and `-f`:

   ```bash
   pkill -f 'sleep 900'
   sleep 2
   losetup -d /dev/loop0 && echo "loop freed"
   losetup --find --show /root/lab-ext4.img       # re-attach for the rest of the lab
   ```

7. Ensure data is on stable storage before pulling a device:

   ```bash
   mount /mnt/lab 2>/dev/null || mount /dev/loop0 /mnt/lab
   dd if=/dev/zero of=/mnt/lab/big.bin bs=1M count=64 status=none
   sync -f /mnt/lab/big.bin        # or: sync ; or: umount, which flushes implicitly
   rm -f /mnt/lab/big.bin
   ```

**Check your understanding**

- **Q7.1** — Explain the difference between `umount -l` (lazy) and `umount -f` (force). For which filesystem type was `-f` primarily designed, and why is it nearly useless on local ext4?
- **Q7.2** — After `umount -l`, `findmnt` shows nothing but `losetup -d` still fails. Reconcile those two facts in terms of the VFS.
- **Q7.3** — `fuser -km /mnt/lab` is a popular one-liner. State two concrete reasons it is dangerous in production.
- **Q7.4** — A process has an open FD on a **deleted** file inside the mount. `lsof` shows it with `(deleted)`. Can you unmount? Can you reclaim the disk space?
- **Q7.5** — Why is `umount` on a read-write mount not instantaneous, and what would happen to the filesystem if you physically removed the device instead?

---

## Exercise 8 — systemd `.mount` and `.automount` units

1. Observe that `fstab` entries are already systemd units, generated at boot:

   ```bash
   systemctl list-units --type=mount --no-pager | head
   ls /run/systemd/generator/ | head
   ls -l /usr/lib/systemd/system-generators/systemd-fstab-generator
   ```

   ```
   UNIT           LOAD   ACTIVE SUB     DESCRIPTION
   -.mount        loaded active mounted Root Mount
   boot-efi.mount loaded active mounted /boot/efi
   mnt-lab.mount  loaded active mounted /mnt/lab
   proc.mount     loaded active mounted /proc
   ```

2. Derive a unit name from a path — the escaping rule is not optional:

   ```bash
   systemd-escape -p --suffix=mount /mnt/lab
   systemd-escape -p --suffix=mount /srv/data-01/backups
   systemd-escape -u -p mnt-lab.mount
   ```

   ```
   mnt-lab.mount
   srv-data\x2d01-backups.mount
   /mnt/lab
   ```

3. Remove the `fstab` entry and replace it with a native unit:

   ```bash
   umount /mnt/lab
   sed -i '/LPIC-1 104.3 lab/,+1d' /etc/fstab
   LABUUID=$(blkid -o value -s UUID /dev/loop0)
   cat > /etc/systemd/system/mnt-lab.mount <<EOF
   [Unit]
   Description=LPIC-1 104.3 lab filesystem
   Documentation=man:systemd.mount(5)

   [Mount]
   What=/dev/disk/by-uuid/$LABUUID
   Where=/mnt/lab
   Type=ext4
   Options=defaults,nosuid,nodev,noatime
   TimeoutSec=30

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start mnt-lab.mount
   systemctl status mnt-lab.mount --no-pager | head -8
   ```

   ```
   ● mnt-lab.mount - LPIC-1 104.3 lab filesystem
        Loaded: loaded (/etc/systemd/system/mnt-lab.mount; disabled; preset: enabled)
        Active: active (mounted) since Wed 2026-08-26 10:02:44 UTC; 1s ago
         Where: /mnt/lab
          What: /dev/loop0
          Docs: man:systemd.mount(5)
         Tasks: 0 (limit: 4653)
   ```

4. Confirm that stopping the unit really unmounts:

   ```bash
   systemctl stop mnt-lab.mount
   findmnt /mnt/lab ; echo "rc=$?"
   ```

   ```
   rc=1
   ```

5. Add on-demand mounting with a companion `.automount` unit:

   ```bash
   cat > /etc/systemd/system/mnt-lab.automount <<'EOF'
   [Unit]
   Description=Automount for the LPIC-1 104.3 lab filesystem

   [Automount]
   Where=/mnt/lab
   TimeoutIdleSec=30

   [Install]
   WantedBy=multi-user.target
   EOF
   systemctl daemon-reload
   systemctl start mnt-lab.automount
   findmnt /mnt/lab
   ```

   ```
   TARGET   SOURCE   FSTYPE    OPTIONS
   /mnt/lab systemd-1 autofs   rw,relatime,fd=53,pgrp=1,timeout=30,minproto=5,maxproto=5,direct
   ```

6. Trigger the mount just by touching the path, then let it idle out:

   ```bash
   ls /mnt/lab
   findmnt -no FSTYPE,SOURCE /mnt/lab
   sleep 45
   findmnt -no FSTYPE,SOURCE /mnt/lab
   ```

   ```
   lost+found  notes.txt  hello.sh  id-suid  sub
   ext4 /dev/loop0
   autofs systemd-1
   ```

7. The same behaviour is available straight from `fstab`. For reference (do not add it now, the native unit is active):

   ```
   UUID=<uuid>  /mnt/lab  ext4  noauto,x-systemd.automount,x-systemd.idle-timeout=30,x-systemd.device-timeout=10s,nofail  0  2
   ```

8. Inspect ordering and dependencies:

   ```bash
   systemctl show mnt-lab.mount -p After -p Requires -p Wants
   systemctl list-dependencies local-fs.target --no-pager | head
   ```

**Check your understanding**

- **Q8.1** — `/srv/data-01/backups` becomes `srv-data\x2d01-backups.mount`. State the three escaping rules that produce that name, and explain why a unit whose `Where=` disagrees with its filename refuses to load.
- **Q8.2** — You have both an `fstab` line and `/etc/systemd/system/mnt-lab.mount` for `/mnt/lab`. Which wins, and why (name the directory precedence)?
- **Q8.3** — What does `x-systemd.automount` buy you over a plain `auto` entry for an NFS server that is sometimes unreachable? Which two options bound the waiting?
- **Q8.4** — Options beginning with `x-` are ignored by `mount(8)`. Why is that prefix significant, and what reads them instead?
- **Q8.5** — After `systemctl stop mnt-lab.automount`, does `/mnt/lab` remain mounted if it was mounted at that moment? Justify.

---

## Exercise 9 — Failure lab: a broken `fstab`, and how not to lose the boot

> This exercise intentionally creates a boot-blocking condition. Run it on a VM you can snapshot or discard.

1. Snapshot the VM (or at least confirm `/etc/fstab.bak` from Exercise 5 exists):

   ```bash
   ls -l /etc/fstab.bak
   ```

2. Introduce the classic mistake — a wrong UUID, without `nofail`:

   ```bash
   cat >> /etc/fstab <<'EOF'
   UUID=00000000-dead-beef-0000-000000000000  /mnt/broken  ext4  defaults  0  2
   EOF
   mkdir -p /mnt/broken
   ```

3. Catch it **before** rebooting:

   ```bash
   findmnt --verify --verbose
   ```

   ```
   /mnt/broken
      [ ] target exists
      [W] cannot find UUID=00000000-dead-beef-0000-000000000000
      [ ] FS type is ext4

   0 parse errors, 0 errors, 1 warning
   ```

   ```bash
   mount -a ; echo "mount -a rc=$?"
   ```

   ```
   mount: /mnt/broken: can't find UUID=00000000-dead-beef-0000-000000000000.
          dmesg(1) may have more information after failed mount system call.
   mount -a rc=32
   ```

4. See how systemd would treat it at boot:

   ```bash
   systemctl daemon-reload
   systemctl start mnt-broken.mount ; echo "rc=$?"
   systemctl status mnt-broken.mount --no-pager | head -5
   journalctl -u mnt-broken.mount --no-pager | tail -3
   ```

   ```
   Job for mnt-broken.mount failed.
   See "systemctl status mnt-broken.mount" and "journalctl -xeu mnt-broken.mount" for details.
   rc=1
   ● mnt-broken.mount - /mnt/broken
        Loaded: loaded (/etc/fstab; generated)
        Active: failed (Result: exit-code) since Wed 2026-08-26 10:15:02 UTC
   ```

5. Now introduce a *syntax* error (a space inside the options field) and watch a different class of failure:

   ```bash
   sed -i 's|/mnt/broken  ext4  defaults|/mnt/broken  ext4  defaults, noatime|' /etc/fstab
   findmnt --verify
   ```

   ```
   /etc/fstab: parse error at line 12 -- ignored
   1 parse error, 0 errors, 0 warnings
   ```

6. Repair the file and re-verify:

   ```bash
   sed -i '/00000000-dead-beef/d' /etc/fstab
   findmnt --verify && mount -a && systemctl daemon-reload
   ```

   ```
   Success, no errors or warnings detected
   ```

7. Memorise the recovery path for when this *does* reach a reboot:

   - systemd drops to **emergency mode** and asks for the root password. Then:
     ```bash
     journalctl -xb -p err
     mount -o remount,rw /
     vi /etc/fstab            # fix or comment out the offending line
     systemctl daemon-reload
     mount -a
     systemctl default
     ```
   - If the root password is unavailable, append `systemd.unit=emergency.target` — or, for a table-free boot, `rd.break` / `init=/bin/bash` — to the kernel command line from the GRUB menu, then remount `/` read-write and edit.

**Check your understanding**

- **Q9.1** — `mount -a` returned exit status `32`. Why does checking that status matter more than reading the message, and what does a non-zero status mean for a provisioning script?
- **Q9.2** — What single option in the broken entry would have turned a failed boot into a logged warning? What is the trade-off of applying it everywhere?
- **Q9.3** — Steps 3 and 5 produced a *warning* and a *parse error*. Which of the two is more dangerous in practice, and why?
- **Q9.4** — Explain the exact chain of events, from `systemd-fstab-generator` to `local-fs.target` to `emergency.target`, that ends in a password prompt at boot.
- **Q9.5** — Give a three-command pre-flight checklist you would run on every host after editing `/etc/fstab`, in order.

---

## Exercise 10 — Cleanup

1. Stop the systemd units and remove them:

   ```bash
   systemctl stop mnt-lab.automount mnt-lab.mount
   rm -f /etc/systemd/system/mnt-lab.mount /etc/systemd/system/mnt-lab.automount
   systemctl daemon-reload
   systemctl reset-failed
   ```

2. Unmount everything from the lab and confirm nothing remains:

   ```bash
   umount /mnt/usb /mnt/lab /mnt/lab-ro /srv/exported 2>/dev/null
   findmnt --source /dev/loop0 --source /dev/loop1 ; echo "rc=$?"
   ```

3. Restore `/etc/fstab` from the backup and validate:

   ```bash
   cp -a /etc/fstab.bak /etc/fstab
   findmnt --verify
   systemctl daemon-reload
   ```

4. Detach the loop devices and delete the images:

   ```bash
   losetup -D
   losetup -a
   rm -f /root/lab-ext4.img /root/lab-usb.img
   rmdir /mnt/lab /mnt/lab-ro /mnt/usb /mnt/broken /srv/exported 2>/dev/null
   ```

5. Remove the test users:

   ```bash
   userdel -r student ; userdel -r student2
   ```

6. Final sanity check — a reboot must be uneventful:

   ```bash
   findmnt --verify --verbose && mount -a && echo "fstab is consistent"
   ```

---

<details>
<summary><strong>Answers</strong> — click to expand</summary>

### Exercise 1

**A1.1** — The old `/etc/mtab` was a *userspace* file written by `mount(8)`. It desynchronised from reality whenever the filesystem holding it was read-only (early boot, rescue mode), whenever a mount happened without `mount(8)` (kernel-initiated, containers, `mount(2)` calls), and inside chroots and mount namespaces, where it described the host rather than the caller. Symlinking it to `/proc/self/mounts` makes the kernel the single source of truth and makes it namespace-aware.

What is lost: `/proc/self/mounts` shows the *canonical* source (`/dev/loop0`, `/dev/vda2`) and the *effective* options, not what the administrator typed. Specifically, the original `fstab`-style spec (`UUID=…`, `LABEL=…`) and userspace-only options (`user`, `users`, `loop=`, `x-*`, `_netdev`) are not in the kernel's table. `util-linux` keeps them in `/run/mount/utab`, which is why `umount` still knows *who* mounted a `user` filesystem, and why `findmnt` can print a `UUID` source while `/proc/mounts` prints a device node.

**A1.2** — VFS flags (`ro`, `nosuid`, `nodev`, `noexec`, `noatime`/`relatime`, `nodiratime`) are **per-mount**: they belong to the mount object, so the same superblock exposed at two paths can carry different ones. Filesystem-specific options (`errors=remount-ro`, `data=ordered`, `commit=`, `discard`, `journal_checksum`) are **per-superblock**: there is exactly one superblock, so changing them at one mount point changes them everywhere. This is exactly why a "read-only bind mount for the web server" works, but a "read-only-for-this-container, read-write-for-the-host" *superblock* option does not.

**A1.3** — `findmnt`. It has a defined output contract (`-o`/`--output`), machine-readable modes (`--json`, `--pairs`, `--raw`), predictable exit codes (`1` = not found), and it handles paths containing spaces (encoded as `\040` in `/proc/mounts`) correctly. Parsing `mount` with no arguments means parsing human prose (`/dev/vda2 on / type ext4 (rw,relatime)`) whose format is not guaranteed and breaks on unusual mount points.

---

### Exercise 2

**A2.1** — `truncate` creates a **sparse** file: the size metadata is 256 MiB but no blocks are allocated until written. `ls -lh` reports the apparent size; `du` reports allocated blocks. The risk: the backing filesystem can run out of space *while the guest filesystem believes it has free space*, producing `EIO`/`ENOSPC` from inside the mounted image and, on ext4, a `remount-ro` event. For anything other than a lab, use `fallocate -l 256M` (real allocation) instead.

**A2.2** — `mount -o loop` calls the same `loop` ioctls internally: it finds a free `/dev/loopN`, associates the file, and mounts it. It also sets the loop device's **autoclear** flag, so the association is torn down automatically when the filesystem is unmounted — you never need `losetup -d`. Doing it manually is worth knowing because it lets you inspect (`blkid`, `fsck`, `mkfs`, partition scanning with `losetup -P`) the image *before* mounting it.

**A2.3** — Yes, genuinely. `mkfs` on a non-block-device is legitimate for images, but the same code path would happily reformat an arbitrary regular file you named by mistake — a typo in a path is the common case. Since the intent cannot be inferred, `mke2fs` asks; `-F` suppresses it, and should only be typed when the target has been re-read.

---

### Exercise 3

**A3.1** — `noexec` makes the kernel refuse `execve(2)` on files under that mount, which is what happens when the shell executes `/mnt/lab/hello.sh` directly (the kernel loads the interpreter via the `#!` line only *after* deciding the file is executable). `sh /mnt/lab/hello.sh` never calls `execve` on that file: `/bin/sh` — which lives on an `exec`-permitted filesystem — merely `open()`s and `read()`s it as data. The same hole applies to `python script.py`, `perl`, `bash -c "$(cat …)"`, and `ld.so /path/to/binary`.

Conclusion: `noexec` is a **hardening measure that raises cost**, not a boundary. It stops dropped ELF binaries and casual `chmod +x` payloads; it does not stop an interpreter. Treat it as one layer alongside `nosuid`, `nodev` and mandatory access control.

**A3.2** — `ro`, `nosuid` and `relatime` are per-mount VFS flags and **can** differ between the two mounts. `errors=remount-ro` is an ext4 superblock option and **cannot**: it is a property of the single superblock. Attempting to set a conflicting superblock option on the second mount is silently ignored (older kernels) or rejected; only the first mount's values are in effect.

**A3.3** — A bind mount has no superblock of its own to remount; `mount -o remount,ro /srv/exported` without `bind` is interpreted as a request against the underlying filesystem's superblock, so on old kernels it silently changed the *whole* ext4 mount and on current `util-linux` it errors out. The bind mount's own VFS flags are changed with `mount -o remount,bind,ro <target>` (`util-linux ≥ 2.37` also accepts the clearer `mount -o bind,ro src tgt` in one step by doing the two operations for you).

**A3.4** — `remount,ro` only requires that no file is open **for writing**; the kernel flushes and flips the superblock. `/` is full of processes with open *read* descriptors and running executables, which do not block it. `/home`, by contrast, typically has editors, browsers or a shell with an open write descriptor or an in-progress write, and each of those returns `EBUSY`. `umount` is stricter still: it needs *zero* references of any kind, including a CWD.

---

### Exercise 4

**A4.1** — (1) **Enumeration order is not deterministic**: SCSI/SATA/NVMe/USB discovery is asynchronous and parallel across kernel threads, so which disk claims `sdb` versus `sdc` can change per boot. (2) **Topology changes**: adding, removing or reordering a controller, a disk or a USB device shifts every later letter.

`UUID=` binds the entry to the *filesystem*, not to the enumeration slot. udev creates `/dev/disk/by-uuid/<uuid>` when the device appears, `mount` resolves through it, and the mapping is correct no matter what node the kernel assigned.

**A4.2** — Labels are **not unique and not enforced**. Plug in a USB disk cloned from the same golden image (or two vendor recovery sticks both labelled `DATA`), and `LABEL=DATA` resolves to whichever device udev linked last — `/dev/disk/by-label/DATA` is a single symlink that gets overwritten. The system may then mount the USB stick where the internal data volume belongs. A `mkfs` UUID is a random 128-bit value and does not collide accidentally.

**A4.3** —
- `UUID=` — identifier written **inside the filesystem superblock** by `mkfs`. Survives repartitioning of *other* partitions and moving the disk to another controller; destroyed by a new `mkfs`; duplicated by a raw clone.
- `PARTUUID=` — identifier in the **partition table** (native for GPT; for MBR it is a synthetic `<disk-signature>-<NN>`). Survives `mkfs` (you can reformat the partition and the `PARTUUID` is unchanged); destroyed by repartitioning.
- `PARTLABEL=` — human-readable **GPT partition name** (GPT only; MBR has no such field). Same lifetime as `PARTUUID`, same non-uniqueness caveat as `LABEL`.

So: `PARTUUID` survives `mkfs`; `UUID` survives repartitioning of the rest of the disk but not a reformat of its own partition; neither survives having its own container recreated.

**A4.4** — The clone carries the *same* filesystem UUID (and label) as the source. `/dev/disk/by-uuid/<uuid>` can now point at either device, `blkid` reports the ambiguity, `mount UUID=…` becomes non-deterministic, and on a root filesystem the initramfs may mount the wrong disk. Repair by generating a new one on the copy:

```bash
tune2fs -U random /dev/sdb1        # ext2/3/4
xfs_admin -U generate /dev/sdb1    # XFS
btrfstune -u /dev/sdb1             # Btrfs (unmounted)
swaplabel -U $(uuidgen) /dev/sdb2  # swap
```
and update `/etc/fstab` (and, for a root filesystem, the bootloader and initramfs) to the new value.

---

### Exercise 5

**A5.1** — `mount -a` skips: entries with `noauto`; entries already mounted; entries whose type is excluded by `-t`/`-O` filters; and swap entries (those are `swapon -a`'s job). `noauto` is the option that keeps the lab entry in `fstab` — so `mount /mnt/lab` still works with the recorded options — while excluding it from `mount -a` and from boot.

**A5.2** —
- `nofail` — if the device is absent or the mount fails, do **not** treat it as a fatal error; boot continues and the failure is logged. This is the option that saves the boot for a missing USB disk.
- `_netdev` — declares that the filesystem needs the network. `systemd-fstab-generator` then orders the unit after `network-online.target` and places it in `remote-fs.target` instead of `local-fs.target`, and on shutdown it is unmounted before the network goes down. It says nothing about failure tolerance.

For removable media you generally want both `noauto,nofail` (plus `x-systemd.automount` if it should mount on access); for iSCSI/NFS/CIFS you want `_netdev,nofail` (`nofail` alone would still hang until the device timeout).

**A5.3** — `mount` parses the option list **left to right**, and later options override earlier ones. `defaults` expands to `rw,suid,dev,exec,auto,nouser,async`. Therefore `defaults,ro` ends read-only (the `ro` overrides `defaults`' `rw`), while `ro,defaults` ends **read-write**, because `defaults` re-asserts `rw` afterwards — a silent and dangerous typo.

**A5.4** — `fs_passno` is the pass order for `fsck` at boot (`fsck -A`). `1` means "check first, alone" and is reserved for the root filesystem; `2` means "check in the second pass", where all `2`s on *different* physical disks are checked in parallel; `0` means "do not check".

`0` is right for NFS (the check is the server's business, not the client's), for `tmpfs` and other pseudo-filesystems (nothing on disk to check), and for Btrfs (there is no meaningful boot-time `fsck.btrfs` — it is a no-op script by design; integrity is handled by scrub and by the mount-time tree checks).

**A5.5** — Concrete cases: (1) `systemctl start mnt-lab.mount` or `systemctl daemon-reload`-dependent ordering will use the *stale* generated unit, so a dependency you added (`x-systemd.requires=`, `_netdev`) is not honoured; (2) a unit you removed from `fstab` is still known to systemd, and a later `systemctl stop`/`start` cycle or a shutdown ordering decision references a mount that no longer exists; (3) worst case, an entry you *deleted* is still in the generated units, and something in the dependency graph pulls it in and fails. The rule is mechanical: **edit `fstab` → `findmnt --verify` → `mount -a` → `systemctl daemon-reload`.**

---

### Exercise 6

**A6.1** —

| Option | Who may mount | Who may unmount |
|---|---|---|
| `user` | any user | **only the user who mounted it** (tracked in `/run/mount/utab`), plus root |
| `users` | any user | **any user**, plus root |
| `owner` | the user who **owns the device node** (`/dev/sdb1`) | that same owner, plus root |
| `group` | any user in the **group owning the device node** | that same group, plus root |

All four imply `noexec,nosuid,nodev` and (in `fstab` usage) require the entry to exist in `/etc/fstab` — a user cannot mount an arbitrary device at an arbitrary path.

**A6.2** — Removable media is attacker-supplied storage: its content is chosen by whoever handed you the stick. Without `nosuid`, an image containing a root-owned `setuid` shell (`chmod 4755 /bin/bash` written on the attacker's own machine) gives an unprivileged user an instant root shell simply by plugging it in and running it — the kernel honours the on-disk mode bits, and the attacker controls those bits. `nodev` blocks the parallel trick with a character device node such as `/dev/mem` or `/dev/sda` with permissive modes. `noexec` raises the cost of running dropped binaries. This is the classic "USB drop" privilege escalation, and it is why the kernel/`mount` pair forces these flags rather than trusting the administrator to type them.

**A6.3** — The rule is the same left-to-right override as `defaults`: the last occurrence of an option wins, and `user`/`users` **set** `noexec,nosuid,nodev` at the position where they appear. So `users,noauto,exec` yields `exec` (the explicit `exec` comes after and overrides), while `exec,users` yields `noexec` — the `users` keyword re-imposes it. Note the asymmetry in the output of step 6: `exec` was restored but `nosuid` and `nodev` remain, because only `exec` was overridden. Overriding these on user-mountable media should be a deliberate, justified decision.

**A6.4** — `vfat`/`exfat`/`ntfs` store no UNIX uid/gid/mode, so the driver **synthesises** them for every file at mount time:
- `uid=` / `gid=` — the numeric owner and group presented for *all* files on the mount.
- `umask=` — bits to **clear** from the default permissions (`0777`), applied to both files and directories.
- `fmask=` — same, but for regular **files** only.
- `dmask=` — same, but for **directories** only.

`umask=022` is equivalent to `fmask=0022,dmask=0022` — but the usual intent (files `rw-r--r--`, directories `rwxr-xr-x`) is better written as `fmask=0133,dmask=0022`, because directories need the execute bit and files usually should not have it. `fmask`/`dmask` override `umask` when both are given.

**A6.5** — `udisks2` (via D-Bus, authorised by `polkit`), driven by the desktop's file manager or `udisksctl`. It is safer because the privileged operation runs in a **separate, auditable daemon** with a policy engine in front of it (rules can depend on the user's session being local and active), instead of relying on a setuid-root binary that parses a text file and untrusted filesystem metadata inside the caller's own process. It also fixes the mount point and options itself (`/run/media/<user>/<label>`, `nosuid,nodev`), so there is no administrator-typed option string to get wrong, and it requires no `fstab` entry per device.

---

### Exercise 7

**A7.1** —
- `umount -l` (**lazy**, `MNT_DETACH`): detaches the mount from the namespace *immediately* so the path becomes unusable, but leaves the filesystem and superblock alive until the last open file, CWD and mmap is released. It always "succeeds" and never loses data — it defers.
- `umount -f` (**force**, `MNT_FORCE`): asks the filesystem driver to abort pending requests and unmount now. It was designed for **NFS**, where a hung server leaves processes blocked in uninterruptible I/O forever and there is no way to release the references; forcing lets the kernel fail those RPCs. On local ext4 it is nearly useless because the "busy" condition is *userspace references*, not stuck I/O — and forcing risks discarding not-yet-written data.

The correct default is neither: find the references with `lsof`/`fuser` and release them.

**A7.2** — Unmounting removes the mount from the **mount namespace** (so `findmnt` and `/proc/self/mountinfo` no longer list it, and the path resolves to the underlying directory), but it does not drop the **superblock**. As long as a process holds an open file descriptor, a CWD, or an mmap on an inode of that filesystem, the superblock stays active and the block device remains claimed by it — hence `EBUSY` from `losetup -d`. The device is freed the moment the refcount hits zero, which is why killing the `sleep` fixed it without any further unmount.

**A7.3** — (1) It sends `SIGKILL` to **every** process touching the mount, including ones you did not intend to hit: if the mount is `/` or `/var` — or if you fat-fingered the path — that is the entire system, killed with no chance to flush or shut down cleanly. (2) `SIGKILL` gives databases, message brokers and editors no opportunity to commit, so it converts a "can't unmount" annoyance into data loss or a crash-recovery cycle. Safer sequence: identify with `fuser -vm`, ask the owning service to stop (`systemctl stop`), escalate to `SIGTERM` (`fuser -m -k -TERM`), and only then consider `umount -l`.

**A7.4** — **No**, you cannot unmount: a deleted-but-open file still has an inode with a positive reference count on that superblock, so the mount is busy. And **no**, you cannot reclaim the space: the blocks are freed only when the last descriptor closes (this is the classic "`df` says full, `du` says empty" situation, typically a log file rotated out from under a daemon). Fix by closing the descriptor — restart or `HUP` the owning process, or in emergencies truncate through `/proc/<pid>/fd/<n>`.

**A7.5** — `umount` must write back dirty page-cache pages, commit the journal and mark the superblock clean before it returns; on a filesystem with a large dirty writeback backlog that takes real time. Physically removing the device instead leaves the on-disk state inconsistent: the superblock stays flagged "not cleanly unmounted", buffered writes are lost, and the next mount triggers journal recovery (ext4/XFS) or a full `fsck` (`vfat`, which has no journal — this is why yanking a USB stick corrupts it). Always `umount` (or at least `sync`) first; `umount` implies the flush, which is why it is not instantaneous.

---

### Exercise 8

**A8.1** — The rules used by `systemd-escape -p`:
1. The leading `/` is dropped, and remaining `/` separators become `-`.
2. Any character outside `[0-9a-zA-Z:_.]` is replaced by `\x` plus its two-digit lowercase hex code — so the literal `-` in `data-01` becomes `\x2d` (otherwise it would be read back as a path separator).
3. The suffix `.mount` is appended (`--suffix=mount`); a leading digit or `.` would additionally be escaped.

A `.mount` unit's filename **is** the mount point — systemd derives `Where=` from the name and refuses to load a unit whose explicit `Where=` disagrees, because the two would identify different mounts and the dependency graph (`RequiresMountsFor=`, ordering into `local-fs.target`) is keyed off the escaped path. The correct name is always what `systemd-escape -p --suffix=mount <path>` prints.

**A8.2** — The native unit in `/etc/systemd/system/` wins. Unit lookup precedence, highest first, includes: `/etc/systemd/system` → `/run/systemd/system` → `/run/systemd/generator` → `/usr/lib/systemd/system` → `/run/systemd/generator.late`. `systemd-fstab-generator` writes into `/run/systemd/generator`, which sits **below** `/etc/systemd/system`, so an administrator-authored unit shadows the `fstab`-generated one entirely. (Note the `Loaded:` line in `systemctl status` changed from `(/etc/fstab; generated)` to `(/etc/systemd/system/mnt-lab.mount; disabled)` — that line is how you confirm which one is in force.)

**A8.3** — With a plain `auto` entry, boot *blocks* on `local-fs.target`/`remote-fs.target` while the mount is attempted, and an unreachable NFS server turns into a multi-minute hang or a drop into emergency mode. With `noauto,x-systemd.automount`, systemd installs an autofs placeholder at boot — instantly, with no network I/O — and performs the real mount only when a process first touches the path; the cost of an unreachable server is paid by that process, not by the boot.

The two bounding options are `x-systemd.device-timeout=` (how long to wait for the backing device/`What=` to appear before failing) and `x-systemd.mount-timeout=` (how long the mount operation itself may take); `x-systemd.idle-timeout=` is the complementary one that unmounts after a period of inactivity.

**A8.4** — `mount(8)` deliberately ignores unrecognised options beginning with `x-` rather than erroring, which reserves that namespace for userspace consumers. That is what makes them safe to put in `fstab`: the entry still works with plain `mount -a` on a non-systemd system. They are read by **`systemd-fstab-generator`**, which translates them into unit properties (dependencies, timeouts, automount units). Related: options starting with `x-` are stored in `/run/mount/utab` and are *not* passed to the kernel, unlike `X-mount.mkdir`/`X-mount.owner` which `mount` itself acts on.

**A8.5** — Yes, it stays mounted. `.automount` and `.mount` are **separate units**: the automount unit only owns the autofs trigger point that *causes* the mount unit to start on access. Stopping the automount removes the trigger; the already-active `mnt-lab.mount` is untouched. To end up with nothing mounted you must stop both (`systemctl stop mnt-lab.automount mnt-lab.mount`) — which is exactly the order used in Exercise 10, because stopping the mount first would let a subsequent access re-trigger it through the still-active automount.

---

### Exercise 9

**A9.1** — Because scripts and configuration-management runs branch on exit status, not on prose, and a message on stderr is invisible to `set -e`, to Ansible's `failed_when`, and to a CI gate unless the status is non-zero. `mount` returns a bitmask (`1` permission/usage, `2` system error, `4` internal error, `8` user interrupt, **16** problems writing/locking `mtab`, **32** mount failure, `64` some mounts succeeded and some failed); `32` means *this mount failed*. `mount -a` returning `32` in a provisioning script must abort the run — otherwise the host is declared "converged" while a data volume is missing and the application starts writing into the empty mount-point directory on the root filesystem.

**A9.2** — `nofail`. The trade-off: it converts a hard failure into a *silent* one. The boot succeeds and the application starts, but the mount point is an ordinary empty directory on `/`, so writes land on the root filesystem instead of the intended volume — filling `/` and scattering data that a later successful mount will hide. Applying `nofail` everywhere is therefore wrong; use it where availability beats correctness (removable media, optional scratch volumes) and pair it with monitoring on the mount, or with `x-systemd.automount` so the failure surfaces at first access.

**A9.3** — The **parse error** is more dangerous. `findmnt --verify` reports the missing UUID as a warning, but the entry is still *understood*: `mount -a` fails loudly, systemd creates a failing unit, and the problem is visible. A parse error means the line is **silently ignored** — no mount is attempted, no unit is generated, no error is raised at boot. The filesystem simply is not there, and the first symptom is an application writing to the wrong place. A stray space inside the options field (field 4 is whitespace-delimited, so `defaults, noatime` becomes seven fields) is the classic instance.

**A9.4** — At boot, `systemd-fstab-generator` runs before the transaction is computed, reads `/etc/fstab`, and writes one `.mount` unit per entry into `/run/systemd/generator/`. Entries without `noauto` get `WantedBy`/`RequiredBy` on `local-fs.target` (or `remote-fs.target` for `_netdev`) — **required**, not merely wanted, unless `nofail` is present, in which case the dependency is downgraded to `Wants=` and ordering only. `local-fs.target` is a hard requirement of `sysinit.target`, which `basic.target` and hence `multi-user.target` depend on. When the mount unit fails, `local-fs.target` fails; the failure propagates up, the transaction for `default.target` cannot complete, and systemd starts `emergency.target` instead — which runs `emergency.service`, i.e. `sulogin`, hence the root-password prompt. `nofail` breaks the chain at the first link; that is the entire mechanism.

**A9.5** — In order:

```bash
findmnt --verify --verbose     # 1. syntax, targets, sources, filesystem types
mount -a ; echo $?             # 2. actually mount everything; demand status 0
systemctl daemon-reload        # 3. regenerate the systemd units from the new fstab
```

A fourth step is worth adding on any host you cannot easily reach: `systemctl list-units --type=mount --failed` (or `findmnt --verify` again after the reload) before you reboot.

</details>

---

## Official sources

- **LPI, Exam 101-500 Objectives — 104.3 Control mounting and unmounting of filesystems** — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `mount(8)`, `umount(8)`, `fstab(5)`, `findmnt(8)`, `blkid(8)`, `lsblk(8)`, `losetup(8)`, `fuser(1)` — util-linux manual pages: <https://man7.org/linux/man-pages/man8/mount.8.html>, <https://man7.org/linux/man-pages/man5/fstab.5.html>, <https://man7.org/linux/man-pages/man8/findmnt.8.html>
- **util-linux project documentation** — <https://github.com/util-linux/util-linux/blob/master/Documentation/>
- **Linux kernel — filesystem mount options and `proc` interfaces** — <https://docs.kernel.org/filesystems/proc.html>, <https://docs.kernel.org/filesystems/sharedsubtree.html>, <https://docs.kernel.org/admin-guide/ext4.html>, <https://docs.kernel.org/filesystems/vfat.html>
- **systemd — `systemd.mount(5)`, `systemd.automount(5)`, `systemd-fstab-generator(8)`, `systemd-escape(1)`** — <https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html>, <https://www.freedesktop.org/software/systemd/man/latest/systemd.automount.html>, <https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html>
- **e2fsprogs — `tune2fs(8)`, `e2label(8)`, `mke2fs(8)`** — <https://e2fsprogs.sourceforge.net/>
- **UDisks2 reference (removable media without `fstab`)** — <https://storaged.org/doc/udisks2-api/latest/>