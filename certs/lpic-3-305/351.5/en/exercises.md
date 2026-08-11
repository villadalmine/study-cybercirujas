# 351.5 Virtual Machine Disk Image Management — Guided Exercises

> **Scope.** These labs cover the full 351.5 objective: image formats (`raw`, `qcow2`, `VMDK`), `qemu-img` management, copy-on-write (backing files, internal/external snapshots), resizing, offline access via `qemu-nbd`/`losetup`/`kpartx`, content manipulation with the **libguestfs** toolchain, and OVF awareness.
>
> **Environment.** A Linux host with `qemu-utils` (or `qemu-img`), `libguestfs-tools`, `kpartx`, and `util-linux`. Steps that touch `/dev/nbd*`, loop devices, or `mount` require **root**; the libguestfs `virt-*` tools do **not**. Work in a scratch directory: `mkdir -p ~/lab-351.5 && cd ~/lab-351.5`.
>
> **Safety.** Everything here operates on throwaway images you create. Nothing targets a running guest's live disk — never open a disk image that a running VM has open for writing (you will corrupt it).

---

## Exercise 1 — Image formats and `qemu-img` inspection

**Goal:** create the three formats named in the objective, read their metadata, and see how *virtual size* differs from *disk size* (sparse allocation).

1. Create a **raw** image of 2 GiB and inspect it:

   ```bash
   qemu-img create -f raw disk-raw.img 2G
   ```
   ```
   Formatting 'disk-raw.img', fmt=raw size=2147483648
   ```

2. Compare the *apparent* size against the *allocated* size on disk:

   ```bash
   ls -lh disk-raw.img
   du -h --apparent-size disk-raw.img
   du -h disk-raw.img
   ```
   ```
   -rw-r--r-- 1 root root 2.0G Aug 11 12:00 disk-raw.img
   2.0G    disk-raw.img
   0       disk-raw.img
   ```

3. Create a **qcow2** image and read its format-specific metadata:

   ```bash
   qemu-img create -f qcow2 disk.qcow2 10G
   qemu-img info disk.qcow2
   ```
   ```
   Formatting 'disk.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=10737418240 lazy_refcounts=off refcount_bits=16

   image: disk.qcow2
   file format: qcow2
   virtual size: 10 GiB (10737418240 bytes)
   disk size: 196 KiB
   cluster_size: 65536
   Format specific information:
       compat: 1.1
       compression type: zlib
       lazy refcounts: false
       refcount bits: 16
       corrupt: false
       extended l2: false
   ```

4. Create a **VMDK** (VMware) image, then convert it to `qcow2`:

   ```bash
   qemu-img create -f vmdk disk.vmdk 4G
   qemu-img convert -p -f vmdk -O qcow2 disk.vmdk disk-from-vmdk.qcow2
   qemu-img info disk-from-vmdk.qcow2 | grep -E 'file format|virtual size'
   ```
   ```
   file format: qcow2
   virtual size: 4 GiB (4294967296 bytes)
   ```

5. List every output format `qemu-img` understands on this build:

   ```bash
   qemu-img --help | sed -n '/Supported formats/p'
   ```
   ```
   Supported formats: blkdebug blklogwrites blkverify bochs cloop ... qcow qcow2 qed raw vdi vhdx vmdk vpc ...
   ```

> **Q1.1** A `raw` file and a fresh `qcow2` both report a 10 GiB *virtual size*, yet `du` shows the qcow2 uses only ~200 KiB while the raw shows 0. Why is the raw file 0 too, and what host-side feature makes both "thin"?
>
> **Q1.2** Name two capabilities `qcow2` has that a `raw` image structurally cannot provide.
>
> **Q1.3** What does `qemu-img convert` do to sparse/unallocated regions by default, and which flag preserves sparseness in the destination?

---

## Exercise 2 — Copy-on-write: backing files and backing chains

**Goal:** build a base image, layer read-only overlays on top of it, and manipulate the chain with `rebase` and `commit`. This is the mechanism behind linked clones and golden images.

1. Create a base image and write an identifiable byte into it so we can later prove data flows through the chain:

   ```bash
   qemu-img create -f qcow2 base.qcow2 5G
   # (we'll treat base.qcow2 as our immutable "golden" image)
   ```

2. Create an **overlay** whose backing file is the base. Always pass `-F` (backing format) — omitting it is deprecated and prints a warning:

   ```bash
   qemu-img create -f qcow2 -b base.qcow2 -F qcow2 overlay1.qcow2
   ```
   ```
   Formatting 'overlay1.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=5368709120 backing_file=base.qcow2 backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
   ```

3. Inspect the full backing chain:

   ```bash
   qemu-img info --backing-chain overlay1.qcow2
   ```
   ```
   image: overlay1.qcow2
   file format: qcow2
   virtual size: 5 GiB (5368709120 bytes)
   disk size: 196 KiB
   backing file: base.qcow2
   backing file format: qcow2
   ...
   image: base.qcow2
   file format: qcow2
   virtual size: 5 GiB (5368709120 bytes)
   disk size: 196 KiB
   ```

4. Stack a second overlay on the first, forming a three-link chain `overlay2 → overlay1 → base`:

   ```bash
   qemu-img create -f qcow2 -b overlay1.qcow2 -F qcow2 overlay2.qcow2
   qemu-img info --backing-chain overlay2.qcow2 | grep -E 'image:|backing file:'
   ```
   ```
   image: overlay2.qcow2
   backing file: overlay1.qcow2
   image: overlay1.qcow2
   backing file: base.qcow2
   image: base.qcow2
   ```

5. **Commit** `overlay1` down into `base` (its writes are merged into the backing file):

   ```bash
   qemu-img commit overlay1.qcow2
   ```
   ```
   Image committed.
   ```

6. **Rebase** `overlay2` onto the base directly. Safe mode (default) reads both old and new backing files to keep guest-visible data identical:

   ```bash
   qemu-img rebase -b base.qcow2 -F qcow2 overlay2.qcow2
   qemu-img info --backing-chain overlay2.qcow2 | grep -E 'image:|backing file:'
   ```
   ```
   image: overlay2.qcow2
   backing file: base.qcow2
   image: base.qcow2
   ```

7. Contrast with **unsafe** rebase, which only rewrites the pointer and validates nothing:

   ```bash
   qemu-img rebase -u -b base.qcow2 -F qcow2 overlay2.qcow2
   ```
   *(No output. The `-u` form assumes you know the new backing content is byte-identical where the overlay is unallocated.)*

> **Q2.1** When a guest **reads** an unallocated cluster in `overlay2.qcow2`, describe the lookup path through the chain. When it **writes**, what happens to that cluster?
>
> **Q2.2** What is the practical difference between `qemu-img commit` and `qemu-img rebase`? Which one shortens (flattens) a chain by merging *upward* into the backing file?
>
> **Q2.3** You move `base.qcow2` to a new absolute path. `overlay2` now fails to open. What went wrong, and which two `rebase` invocations (safe vs `-u`) would you use to fix the reference — and when is each correct?
>
> **Q2.4** Why does QEMU now *require* `-F`/`backing_fmt`? What security/correctness problem did format probing of backing files historically cause?

---

## Exercise 3 — Internal vs external snapshots

**Goal:** distinguish qcow2 *internal* snapshots (stored inside the file) from *external* snapshots (a new overlay), and manage both offline.

1. Take two **internal** snapshots of a qcow2 image and list them:

   ```bash
   qemu-img snapshot -c clean-install disk.qcow2
   qemu-img snapshot -c after-updates disk.qcow2
   qemu-img snapshot -l disk.qcow2
   ```
   ```
   Snapshot list:
   ID        TAG               VM SIZE                DATE     VM CLOCK          ICOUNT
   1         clean-install         0 B 2026-08-11 12:05:11  0000:00:00.000000
   2         after-updates         0 B 2026-08-11 12:06:02  0000:00:00.000000
   ```

2. Revert the image to the first snapshot, then delete the second:

   ```bash
   qemu-img snapshot -a clean-install disk.qcow2   # apply/revert
   qemu-img snapshot -d after-updates disk.qcow2   # delete
   qemu-img snapshot -l disk.qcow2
   ```
   ```
   Snapshot list:
   ID        TAG               VM SIZE                DATE     VM CLOCK          ICOUNT
   1         clean-install         0 B 2026-08-11 12:05:11  0000:00:00.000000
   ```

3. Try the same on a **raw** image and observe the failure:

   ```bash
   qemu-img snapshot -c test disk-raw.img
   ```
   ```
   qemu-img: Could not create snapshot 'test': -95 (Operation not supported)
   ```

4. Create an **external** snapshot manually — this is exactly the backing-file pattern from Exercise 2, used as a point-in-time freeze:

   ```bash
   # 'disk.qcow2' becomes the frozen, read-only base; new writes land in the overlay
   qemu-img create -f qcow2 -b disk.qcow2 -F qcow2 disk-snap-20260811.qcow2
   ```
   To later fold the changes back into the frozen base:
   ```bash
   qemu-img commit disk-snap-20260811.qcow2
   ```

> **Q3.1** An internal snapshot's `VM SIZE` reads `0 B`. What does the `VM SIZE` column actually measure, and why is it non-zero only for snapshots created by a *running* QEMU?
>
> **Q3.2** Give two concrete advantages of external snapshots over internal ones for backups.
>
> **Q3.3** Why did step 3 fail? Which single property of the `raw` format is responsible?
>
> **Q3.4** After an external snapshot, which file is safe to copy for backup while the guest keeps running, and which file must you **not** touch?

---

## Exercise 4 — Resizing disk images

**Goal:** grow and shrink the *container*, and understand why that is only half the job.

1. Grow the qcow2 by 5 GiB (relative), then set an absolute size:

   ```bash
   qemu-img resize disk.qcow2 +5G
   qemu-img info disk.qcow2 | grep 'virtual size'
   qemu-img resize disk.qcow2 20G
   qemu-img info disk.qcow2 | grep 'virtual size'
   ```
   ```
   virtual size: 15 GiB (16106127360 bytes)
   virtual size: 20 GiB (21474836480 bytes)
   ```

2. Attempt to **shrink** and read the guard rail:

   ```bash
   qemu-img resize disk.qcow2 5G
   ```
   ```
   qemu-img: Use the --shrink option to perform a shrink operation.
   qemu-img: warning: Shrinking an image will delete all data beyond the shrunk image size. Before performing such an operation, make sure there is no important data there.
   ```
   ```bash
   qemu-img resize --shrink disk.qcow2 5G
   ```

3. Understand the two-layer problem: `qemu-img resize` changes only the **block device size**. The guest's **partition table** and **filesystem** do not grow by themselves. The *content-aware* tool is `virt-resize`, which copies from a source image into a new, larger destination and expands a chosen partition in one pass:

   ```bash
   # Enlarge a real system image: grow /dev/sda2 to fill the new space
   qemu-img create -f qcow2 bigger.qcow2 30G
   virt-resize --expand /dev/sda2 guest.qcow2 bigger.qcow2
   ```
   ```
   Resize operation completed with no errors. Before deleting the old disk,
   carefully check that the resized disk boots and works correctly.
   ```

> **Q4.1** After `qemu-img resize disk.qcow2 +5G` on a disk holding a partitioned filesystem, the guest still reports the old capacity. List the ordered sequence of operations *inside the guest* needed to actually use the new space for an ext4 root on an LVM-less layout (partition table → filesystem).
>
> **Q4.2** Why is shrinking gated behind `--shrink` while growing is not?
>
> **Q4.3** `virt-resize` refuses to operate in place and always writes to a **new** destination image. Why is that design safer than an in-place resize?

---

## Exercise 5 — Offline access with `qemu-nbd`, `losetup`, and `kpartx`

**Goal:** mount partitions from inside an image using the host kernel. Build a small partitioned image first so the steps are reproducible.

### 5A — Build a test image with one partition and a filesystem

1. Create a raw image, partition it, and make an ext4 filesystem via a loop device:

   ```bash
   qemu-img create -f raw test.img 1G
   sudo losetup -fP --show test.img          # -P scans the partition table
   ```
   ```
   /dev/loop0
   ```
   ```bash
   sudo parted -s /dev/loop0 mklabel msdos mkpart primary ext4 1MiB 100%
   sudo partprobe /dev/loop0
   sudo mkfs.ext4 /dev/loop0p1
   sudo mount /dev/loop0p1 /mnt
   echo "hello from the guest disk" | sudo tee /mnt/README.txt
   sudo umount /mnt
   sudo losetup -d /dev/loop0
   ```

### 5B — Access a raw image with `losetup` + `kpartx`

2. Attach the image and expose its partitions as device-mapper nodes:

   ```bash
   sudo losetup -f --show test.img
   ```
   ```
   /dev/loop0
   ```
   ```bash
   sudo kpartx -av /dev/loop0
   ```
   ```
   add map loop0p1 (253:0): 0 2095104 linear 7:0 2048
   ```
   ```bash
   sudo mount /dev/mapper/loop0p1 /mnt
   cat /mnt/README.txt
   ```
   ```
   hello from the guest disk
   ```

3. Tear it down cleanly, in reverse order:

   ```bash
   sudo umount /mnt
   sudo kpartx -dv /dev/loop0
   sudo losetup -d /dev/loop0
   ```

### 5C — Access a qcow2 image with `qemu-nbd`

`losetup` speaks only `raw`. For `qcow2`/`vmdk` you need the **NBD** userspace driver, which decodes the format and presents a block device.

4. Load the `nbd` kernel module with room for partitions, then convert and connect:

   ```bash
   sudo modprobe nbd max_part=16
   qemu-img convert -f raw -O qcow2 test.img test.qcow2
   sudo qemu-nbd --connect=/dev/nbd0 test.qcow2
   sudo partprobe /dev/nbd0
   lsblk /dev/nbd0
   ```
   ```
   NAME    MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
   nbd0     43:0    0     1G  0 disk
   └─nbd0p1 43:1    0  1023M  0 part
   ```
   ```bash
   sudo mount /dev/nbd0p1 /mnt
   cat /mnt/README.txt
   ```
   ```
   hello from the guest disk
   ```

5. Disconnect cleanly:

   ```bash
   sudo umount /mnt
   sudo qemu-nbd --disconnect /dev/nbd0
   ```
   ```
   /dev/nbd0 disconnected
   ```
   ```bash
   sudo rmmod nbd
   ```

6. **Read-only** access — connect with `-r` when you must not risk any write to a suspect image:

   ```bash
   sudo qemu-nbd -r --connect=/dev/nbd0 test.qcow2
   ```

> **Q5.1** `losetup` mounted the `raw` image but cannot open `test.qcow2`. Why? What exactly does `qemu-nbd` add that `losetup` lacks?
>
> **Q5.2** What is the purpose of `max_part=16` on the `modprobe nbd` line, and what symptom appears if you forget it?
>
> **Q5.3** In 5B, `kpartx -av` created `/dev/mapper/loop0p1`. What would `losetup -fP` (as used in 5A) have created instead, and why might you still prefer `kpartx` on some systems?
>
> **Q5.4** You mount a partition from a disk that a VM is *currently running* with, read-write, on the host. Name the failure mode and state the rule that prevents it.

---

## Exercise 6 — Content manipulation with libguestfs (`guestfish`, `virt-*`)

**Goal:** inspect and edit image contents **without root and without mounting on the host**. libguestfs boots a tiny isolated appliance (its own kernel + `qemu`) that mounts the image internally, so the host kernel never parses untrusted filesystem metadata.

> If the tools hang or error about KVM/permissions on a workstation or CI runner, force the direct backend: `export LIBGUESTFS_BACKEND=direct`. Add `LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1` to diagnose appliance boot failures.

1. Enumerate filesystems and partitions in an image (works even when the host can't mount them):

   ```bash
   virt-filesystems -a guest.qcow2 --long -h --all
   ```
   ```
   Name       Type        VFS   Label  Size  Parent
   /dev/sda1  filesystem  ext4  -      512M  -
   /dev/sda2  filesystem  ext4  -      19G   -
   /dev/sda1  partition   -     -      512M  /dev/sda
   /dev/sda2  partition   -     -      19G   /dev/sda
   /dev/sda   device      -     -      20G   -
   ```

2. Report per-filesystem usage *inside* the image:

   ```bash
   virt-df -a guest.qcow2 -h
   ```
   ```
   Filesystem                    Size    Used  Available  Use%
   guest.qcow2:/dev/sda1         488M     73M       380M   16%
   guest.qcow2:/dev/sda2          19G    3.1G        15G   17%
   ```

3. Read and list files without mounting:

   ```bash
   virt-cat -a guest.qcow2 /etc/hostname
   virt-ls -a guest.qcow2 /etc/ssh
   ```
   ```
   web01
   moduli
   ssh_config
   sshd_config
   ssh_host_ed25519_key
   ssh_host_ed25519_key.pub
   ```

4. Copy a file **in** and another **out**:

   ```bash
   echo "127.0.0.1 registry.internal" > extra-hosts.txt
   virt-copy-in -a guest.qcow2 extra-hosts.txt /root
   virt-copy-out -a guest.qcow2 /etc/fstab ./exported
   ```

5. Edit a file in place (opens `$EDITOR`, or use `-e` for a non-interactive sed-style expression):

   ```bash
   virt-edit -a guest.qcow2 /etc/default/grub -e 's/quiet splash//'
   ```

6. Auto-detect the OS and dump structured inventory:

   ```bash
   virt-inspector -a guest.qcow2 | head -n 20
   ```
   ```xml
   <?xml version="1.0"?>
   <operatingsystems>
     <operatingsystem>
       <root>/dev/sda2</root>
       <name>linux</name>
       <distro>debian</distro>
       <product_name>Debian GNU/Linux 12 (bookworm)</product_name>
       <major_version>12</major_version>
       <minor_version>0</minor_version>
       <package_format>deb</package_format>
       <package_management>apt</package_management>
       ...
   ```

7. **Interactive** exploration with `guestfish`. The `-i` flag auto-inspects and mounts the guest's filesystems at their real mountpoints:

   ```bash
   guestfish --rw -a guest.qcow2 -i
   ```
   ```
   Welcome to guestfish, the guest filesystem shell for
   editing virtual machine filesystems and disk images.

   ><fs> cat /etc/hostname
   web01
   ><fs> ll /var/log
   ...
   ><fs> download /etc/passwd /tmp/passwd.copy
   ><fs> exit
   ```
   The same, driven manually (no auto-inspection) — the explicit form the exam expects you to recognize:
   ```bash
   guestfish --rw -a guest.qcow2 <<'EOF'
   run
   list-filesystems
   mount /dev/sda2 /
   mount /dev/sda1 /boot
   cat /etc/os-release
   umount-all
   quit
   EOF
   ```

8. Reclaim unused space — make the image **sparse** again after deletions inside it:

   ```bash
   virt-sparsify --compress guest.qcow2 guest-slim.qcow2
   ```

9. Prepare a **golden template**: strip machine-specific identity (SSH host keys, machine-id, logs, shell history, DHCP leases) so cloned VMs don't collide:

   ```bash
   virt-sysprep -a guest.qcow2
   ```
   ```
   [   0.0] Examining the guest ...
   [   3.2] Performing "abrt-data" ...
   [   3.2] Performing "bash-history" ...
   [   3.3] Performing "machine-id" ...
   [   3.4] Performing "ssh-hostkeys" ...
   ...
   ```

> **Q6.1** State the single most important architectural reason libguestfs is safer than `qemu-nbd`+`mount` for inspecting an **untrusted** or corrupted image. (Hint: which kernel parses the filesystem?)
>
> **Q6.2** When would you reach for `guestfish` interactively instead of a one-shot `virt-cat`/`virt-edit`? Give one task each tool suits.
>
> **Q6.3** You clone a template five times with `qemu-img create -b`, boot all five, and they receive the **same** SSH host key and duplicate `machine-id`. Which single command in this exercise prevents that, and name two things it scrubs.
>
> **Q6.4** A guest's users deleted 8 GiB of files but the `qcow2` on the host didn't shrink at all. Which tool reclaims that space, and what must happen to the freed blocks for it to work?
>
> **Q6.5** Why can `virt-*` tools run as an unprivileged user while Exercise 5 required `sudo` throughout?

---

## Exercise 7 — Open Virtualization Format (OVF/OVA) awareness

**Goal:** recognize the packaging format the objective asks you to be *aware* of, and convert its embedded disk.

1. Inspect the members of an **OVA** (an OVF distributed as a tar archive):

   ```bash
   tar tvf appliance.ova
   ```
   ```
   -rw-r--r-- 0/0     8724 2026-01-15 09:00 appliance.ovf
   -rw-r--r-- 0/0      141 2026-01-15 09:00 appliance.mf
   -rw-r--r-- 0/0 1892352000 2026-01-15 09:00 appliance-disk1.vmdk
   ```

2. Read the descriptor. The `.ovf` is an XML document describing virtual hardware; the `.mf` (manifest) holds checksums; the disk is usually `VMDK`:

   ```bash
   tar xf appliance.ova appliance.ovf
   grep -E 'ovf:href|VirtualQuantity|ResourceType' appliance.ovf | head
   ```
   ```
   <File ovf:href="appliance-disk1.vmdk" ovf:id="file1" ovf:size="1892352000"/>
   <rasd:ResourceType>3</rasd:ResourceType>      <!-- 3 = virtual CPU -->
   <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
   <rasd:ResourceType>4</rasd:ResourceType>      <!-- 4 = memory -->
   ```

3. Extract and convert the embedded disk into a KVM-native format:

   ```bash
   tar xf appliance.ova appliance-disk1.vmdk
   qemu-img convert -p -O qcow2 appliance-disk1.vmdk appliance.qcow2
   ```

> **Q7.1** What is inside an `.ova` file, and what does the `.ovf` descriptor contribute that a bare `.vmdk` does not?
>
> **Q7.2** OVF is a *portable, vendor-neutral* packaging standard, yet `qemu-img` has no `-O ovf`. Explain why converting a disk is straightforward but re-packaging a full OVF appliance is not a `qemu-img` job.

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** Both are *sparse files*: the host filesystem (ext4/XFS/Btrfs) records the file's logical length in its inode without allocating data blocks for regions that were never written. `qemu-img create -f raw` only sets the length (a hole spanning the whole file → `du` shows 0), while `qcow2` writes a small header, L1/L2 metadata tables and refcount tables (~200 KiB), hence the tiny non-zero footprint. Sparse allocation is the host-side feature making both "thin." (Note: on a filesystem without sparse support, or after `fallocate`, the raw file would occupy the full 2 GiB.)

**A1.2** Any two of: internal snapshots; backing files / copy-on-write overlays; optional zlib/zstd compression; encryption (LUKS); extended L2 entries / subclusters; a compact on-disk representation that grows on demand. A `raw` image is just the linear byte image of the disk with no metadata layer, so it can offer none of these itself.

**A1.3** By default `qemu-img convert` writes the destination *sparsely* where the source reads as zero — it detects zero runs and leaves holes (for formats that support it), so a fresh 10 GiB image converts small. `-S <size>` tunes the sparse-detection granularity (`-S 0` disables it, producing a fully allocated destination). Compression on convert is `-c` (qcow2/qed only).

### Exercise 2

**A2.1** **Read of an unallocated cluster:** QEMU consults `overlay2`'s L2 table, finds the cluster unmapped, and walks *down* the chain — `overlay1`, then `base` — returning the first populated copy, or zeros if no layer has it. **Write:** copy-on-write allocates a fresh cluster *in `overlay2`* and writes there; the backing files are never modified (they are read-only from the overlay's perspective).

**A2.2** `commit` merges an overlay's changes *downward* into its backing file, then the overlay can be discarded — it flattens by pushing writes into the base. `rebase` changes *which* backing file an image points at (and in safe mode copies whatever clusters are needed so guest-visible data stays identical). Neither merges "upward into the backing file" as a shorten operation the way the question's phrasing tempts — the one that folds an overlay into its backing file is **`commit`**.

**A2.3** The overlay stores a reference to its backing file (relative or absolute path); moving `base.qcow2` broke it. To repair: with the base actually present at the new location, `qemu-img rebase -u -b <new/path/base.qcow2> -F qcow2 overlay2.qcow2` — **unsafe** mode is *correct here* because the backing content is byte-identical, you only need to rewrite the pointer. Use **safe** `rebase` (no `-u`) when the new backing file has *different* content and you need QEMU to copy clusters so the guest sees the same data.

**A2.4** Historically QEMU *probed* a backing file's format from its contents. Attacker- or guest-controlled data at the start of a raw backing file could be crafted to look like a qcow2 header, redirecting reads or exposing host files — a real CVE class. Requiring an explicit `backing_fmt`/`-F` removes the guesswork: the format is declared, not inferred.

### Exercise 3

**A3.1** `VM SIZE` measures the saved **VM RAM/device state** stored with the snapshot — only a *running* QEMU (via `savevm`/`loadvm` or `virsh snapshot`) captures live memory, producing a non-zero size. A `qemu-img snapshot -c` on an offline image saves only the disk state, so `VM SIZE` is `0 B`.

**A3.2** Any two: (1) external snapshots freeze the base file, so you can back it up (or its clusters) while the guest keeps writing to the overlay; (2) they work on any format the overlay supports and are easy to discard by deleting the overlay; (3) they don't bloat/rewrite the original file the way internal snapshots do; (4) simpler, incremental backup workflows (copy the overlay, then `commit` or keep as a chain).

**A3.3** `raw` has **no metadata layer** — it is only the disk's bytes, with nowhere to store snapshot tables. Internal snapshots require a container format (qcow2/qed); hence "Operation not supported."

**A3.4** After the external snapshot, the **base** (`disk.qcow2`) is frozen read-only and is the safe file to copy for backup. The **overlay** (`disk-snap-...qcow2`) is being actively written by the running guest — copying or altering it out from under the VM risks a torn/corrupt backup.

### Exercise 4

**A4.1** For an ext4 root on `/dev/sda2` (MBR/GPT, no LVM): (1) rewrite the partition table so `sda2` extends into the new space — `growpart /dev/sda 2`, or delete+recreate the partition with the same start via `fdisk`/`parted`, then `partprobe`; (2) grow the filesystem online — `resize2fs /dev/sda2` (for XFS it would be `xfs_growfs <mountpoint>`). Container → partition table → filesystem, in that order.

**A4.2** Growing only appends unused space and never destroys data, so it's safe by default. Shrinking discards every byte beyond the new boundary; if a filesystem/partition still lives there you lose data irrecoverably. `--shrink` is a deliberate "I understand" acknowledgment. (And you must shrink the *filesystem then partition* inside the guest **before** shrinking the container, never after.)

**A4.3** `virt-resize` copies content into a fresh destination, leaving the source image untouched. If anything goes wrong — a bad partition selection, an interrupted run, an unbootable result — the original is still intact to retry or fall back to. An in-place resize that fails mid-operation could leave the only copy corrupt.

### Exercise 5

**A5.1** `losetup` maps a *raw byte range* of a file to a block device; it does not understand container formats, so it can't decode qcow2's cluster indirection, compression, or backing chains. `qemu-nbd` runs the full QEMU block layer in userspace and exports the *decoded* virtual disk over NBD, so `/dev/nbd0` presents the guest's raw disk regardless of on-disk format (qcow2, vmdk, vdi, …).

**A5.2** `max_part=N` tells the `nbd` driver to create `N` partition device nodes per NBD device (e.g. `/dev/nbd0p1`, `/dev/nbd0p2`, …). Without it the module defaults to 0 partitions per device: you get `/dev/nbd0` but **no** `/dev/nbd0pX` nodes appear, so you can't mount an individual partition (you'd have to use `kpartx`/`partx` on the NBD device instead).

**A5.3** `losetup -fP` would have created kernel partition nodes directly under the loop device: `/dev/loop0p1`, `/dev/loop0p2`. `kpartx` instead creates device-mapper nodes under `/dev/mapper/` (`loop0p1`). `kpartx` is useful when the kernel's automatic partition scanning is unavailable or when you want DM-managed nodes (e.g. older kernels, or images attached without `-P`); it's also the classic tool for partitions inside multipath/LVM stacks.

**A5.4** Mounting a disk read-write while a VM writes to the same disk causes **filesystem corruption / cache incoherency** — two independent writers with separate page caches and journals clobber each other. Rule: **never** attach or mount an image that a running guest has open for writing. If you must peek, at minimum use read-only (`qemu-nbd -r`) — and even then results can be inconsistent for a live filesystem.

### Exercise 6

**A6.1** libguestfs mounts the target inside an **isolated appliance kernel** (a throwaway QEMU/KVM VM), so a malicious or corrupted filesystem is parsed by *that* disposable kernel, never the host's. `qemu-nbd`+`mount` parses the untrusted filesystem with the **host kernel**, exposing the host to filesystem-driver bugs and privilege escalation. Isolation of the parsing kernel is the key safety property.

**A6.2** Use `guestfish` interactively for exploratory or multi-step work in one appliance boot — poke around, list filesystems, chain several reads/writes/uploads, debug an unknown layout. Use one-shot `virt-cat` (dump one file) or `virt-edit` (change one file non-interactively, scriptable in a pipeline). Rule of thumb: many operations on one image → `guestfish`; a single scripted operation → the focused `virt-*` tool.

**A6.3** `virt-sysprep -a <image>` (run on the template *before* cloning). It scrubs, among others: SSH host keys, `/etc/machine-id`, persistent net rules, DHCP leases, logs, shell history, cron/at spool, mail spool — any two of these are acceptable. This is what stops cloned VMs from sharing identity.

**A6.4** `virt-sparsify` reclaims the space. It works by discarding/zeroing the *free* blocks the guest filesystem no longer references and then writing a sparse (hole-punched, optionally compressed) destination — so the freed blocks must be discoverable as free/zero. In practice you either let `virt-sparsify` zero free space itself, or `fstrim`/zero-fill inside the guest first so the unused blocks are actually zeroed before sparsifying.

**A6.5** `virt-*` tools never touch host block devices or `mount(2)`; they hand the image to an unprivileged QEMU appliance that does all mounting internally, so no elevated host privilege is needed. Exercise 5 manipulated real host kernel objects — loop devices, the `nbd` module, device-mapper nodes, and `mount` — all of which are privileged operations, hence `sudo`.

### Exercise 7

**A7.1** An `.ova` is simply a (uncompressed) **tar** archive bundling the OVF package: the `.ovf` XML descriptor, an optional `.mf` manifest of SHA checksums (and possibly a `.cert`), plus one or more virtual disks (commonly `VMDK`). The `.ovf` descriptor adds the *virtual hardware and metadata* a bare disk lacks — CPU/memory sizing, NICs, disk controllers, boot order, product/EULA info, network mappings — everything a hypervisor needs to instantiate the VM, not just its bytes.

**A7.2** Converting the disk is one well-defined operation on a single container format, which `qemu-img` does natively. A full OVF appliance is a *multi-file package plus an XML hardware description and checksum manifest* — repackaging means regenerating the descriptor, recomputing the manifest, mapping virtual hardware to the target, and re-tarring. That is orchestration/packaging work owned by tools like `ovftool`, `virt-v2v`, or `virt-install --import`, not by a single-image converter like `qemu-img`. The objective only asks for *awareness* of OVF for this reason.

</details>

---

### Sources

- LPI — *Exam 305-300 Objectives*, objective 351.5: <https://www.lpi.org/our-certifications/exam-305-objectives/>
- QEMU — *qemu-img* invocation reference (formats, `convert`, `snapshot`, `rebase`, `commit`, `resize`): <https://www.qemu.org/docs/master/tools/qemu-img.html>
- QEMU — *qemu-nbd* manual and the `nbd` kernel module: <https://www.qemu.org/docs/master/tools/qemu-nbd.html>
- QEMU — *Live/external snapshots and backing files* (block layer): <https://www.qemu.org/docs/master/interop/live-block-operations.html>
- libguestfs — tool index (`guestfish`, `virt-filesystems`, `virt-df`, `virt-cat`, `virt-ls`, `virt-copy-in/out`, `virt-edit`, `virt-inspector`, `virt-resize`, `virt-sparsify`, `virt-sysprep`): <https://libguestfs.org/>
- `kpartx(8)` and `losetup(8)`: util-linux / device-mapper-multipath manpages — <https://man7.org/linux/man-pages/man8/losetup.8.html>, <https://man7.org/linux/man-pages/man8/kpartx.8.html>
- DMTF — *Open Virtualization Format (OVF) Specification* (DSP0243): <https://www.dmtf.org/standards/ovf>