# Hands-On Exercises: Devices and Filesystems

These exercises will familiarize you with identifying block devices, inspecting UUIDs, and safely modifying the system's mount configuration. You will need a lab environment with `root` or `sudo` privileges. 

> **Warning:** Be extremely careful when editing `/etc/fstab`. A malformed entry can render your lab VM unbootable.

## Exercise 1: Device Identification and Filesystem Inspection

Before mounting a new volume, an SRE must identify its device name, UUID, and format.

### Steps:
1. List all block devices attached to your VM, including their filesystems and mount points.
   ```bash
   $ lsblk -f
   ```
2. Locate the primary root partition (usually mounted at `/`). Use the `blkid` command on that specific device (e.g., `/dev/sda1` or `/dev/nvme0n1p1`) to find its UUID.
   ```bash
   $ sudo blkid /dev/<your_root_partition>
   ```
3. Use the `df` command to check how much space is available on the root filesystem in human-readable format.
   ```bash
   $ df -h /
   ```
4. Now, check the **inode** usage of the root filesystem to see how many files can still be created.
   ```bash
   $ df -i /
   ```

**Questions for Verification:**
- Q1.1: Why is it best practice in modern Linux systems to mount filesystems using their `UUID` rather than their device name (like `/dev/sdb1`)?
- Q1.2: What is an inode, and why might a disk run out of inodes even if it has plenty of free block space?

---

## Exercise 2: Managing Mounts and /etc/fstab

In this exercise, we will create a temporary in-memory filesystem (tmpfs), mount it manually, and then configure it to persist across reboots via `/etc/fstab`.

### Steps:
1. Create a directory to serve as the mount point.
   ```bash
   $ sudo mkdir -p /mnt/ramdisk
   ```
2. Manually mount a 100MB `tmpfs` (in-memory filesystem) to that directory.
   ```bash
   $ sudo mount -t tmpfs -o size=100M tmpfs /mnt/ramdisk
   ```
3. Verify that it is mounted and check its size.
   ```bash
   $ df -h /mnt/ramdisk
   ```
4. Edit the `/etc/fstab` file using `nano` or `vi`. Add the following line to the end of the file to make the mount persistent:
   ```text
   tmpfs    /mnt/ramdisk    tmpfs    size=100M    0  0
   ```
5. Unmount the directory manually to simulate a fresh boot state.
   ```bash
   $ sudo umount /mnt/ramdisk
   ```
6. Test your `/etc/fstab` configuration by telling the system to mount all filesystems defined in the file. **(Always do this before rebooting after editing fstab!)**
   ```bash
   $ sudo mount -a
   ```
7. Verify it mounted successfully again.
   ```bash
   $ df -h /mnt/ramdisk
   ```

**Questions for Verification:**
- Q2.1: What would happen if you made a syntax error in `/etc/fstab` and rebooted the server without running `mount -a` first?
- Q2.2: In the `/etc/fstab` entry `tmpfs /mnt/ramdisk tmpfs size=100M 0 0`, what do the last two numbers (`0 0`) represent?

<details>
<summary>Click here to reveal the answers</summary>

### Answers

- **A1.1**: Device names (like `/dev/sda` or `/dev/nvme1n1`) are assigned dynamically by the kernel at boot time depending on the order devices respond. If you add a new disk, `/dev/sda` might become `/dev/sdb`, breaking your mounts. The UUID is a cryptographic hash embedded in the filesystem itself and never changes regardless of the port or order the disk is attached.
- **A1.2**: An inode is a data structure on a filesystem that stores metadata about a file (permissions, owner, block locations), but not the file's name or its actual data. Every file requires exactly one inode. If you create millions of tiny files (like a web session cache), you will exhaust the fixed number of inodes assigned when the filesystem was formatted, resulting in a "No space left on device" error, even if the disk is empty in terms of gigabytes.
- **A2.1**: The boot sequence would fail when systemd attempts to process the malformed `fstab` entry. The server would drop into "Emergency Mode," requiring a physical console or hypervisor serial access to manually fix the file, resulting in critical downtime. Running `sudo mount -a` tests the configuration safely while the system is still running.
- **A2.2**: The first `0` is for the `dump` utility (determining if the filesystem should be backed up, usually obsolete now). The second `0` is the `fsck` pass order. The root filesystem (`/`) should be `1` (checked first), other critical filesystems `2`, and `0` means the filesystem should not be checked for errors at boot (which makes sense for an in-memory `tmpfs`).

</details>