# LPIC-2 Exam 201-450 (v4.5) — Topic 201.3: System Startup

**Weight:** 3  
**Target Audience:** Senior SREs, Platform Engineers, and Systems Engineers preparing for LPIC-2 Certification.  
**Official Reference Sources:**
* [LPI LPIC-2 Objectives v4.5](https://www.lpi.org/our-certifications/lpic-2-overview/)
* [GNU GRUB Manual v2.06](https://www.gnu.org/software/grub/manual/grub/grub.html)
* [Linux Kernel Boot Protocol Documentation](https://www.kernel.org/doc/html/latest/x86/boot.html)
* [freedesktop.org systemd Boot Process & Bootup Specification](https://www.freedesktop.org/software/systemd/man/latest/bootup.html)

---

## 1. Deep Dive Mechanics: GRUB2 Architecture, Stage 1/1.5/2, & Initramfs Internals

### Architectural Overview
The x86/x86_64 Linux boot sequence transfers execution through distinct hardware, bootloader, kernel space, and user space boundaries:

```
[ BIOS / UEFI ] 
       │
       ▼
[ GRUB2 Stage 1 (MBR / EFI App) ] ──> Loads core.img (Stage 1.5 - Filesystem Drivers)
       │
       ▼
[ GRUB2 Stage 2 (`/boot/grub/grub.cfg`) ] ──> Loads VMLINUZ + INITRAMFS into Memory
       │
       ▼
[ Linux Kernel Initialization ] ──> Mounts initramfs as temporary rootfs (`/`)
       │
       ▼
[ initramfs `/init` script ] ──> Loads storage/NVMe/RAID drivers, mounts real root (`/sysroot`)
       │
       ▼
[ `pivot_root` / `switch_root` ] ──> Hands control over to systemd (`/sbin/init` PID 1)
```

1. **BIOS/MBR Legacy Boot:** BIOS reads Sector 0 (512 bytes) of the boot disk into RAM (`0x7C00`). MBR contains Stage 1 (`boot.img`, 446 bytes). Stage 1 loads `core.img` (Stage 1.5) stored in the post-MBR gap (sectors 1–2047) or partitioned space, which contains file system drivers (e.g., ext4, xfs) to read `/boot/grub`.
2. **UEFI Boot:** Firmware executes `grubx64.efi` directly from the EFI System Partition (ESP formatted as FAT32, mounted at `/boot/efi`). Stage 1/1.5 gaps are bypassed.
3. **Stage 2:** Loads menu visual modules and parses `/boot/grub/grub.cfg` (or `/boot/grub2/grub.cfg` on RHEL-based systems).
4. **Initramfs Execution:** The initramfs is a compressed cpio archive loaded into RAM alongside `vmlinuz`. The kernel executes `/init` inside initramfs, which detects block devices, executes storage stack activation (LVM, LUKS, RAID), mounts the persistent root filesystem read-only to `/sysroot`, and executes `switch_root` to transition to systemd (`PID 1`).

---

### Hands-on Exercise 1.1: GRUB2 Configuration Architecture and Binary Inspection

In this exercise, you will analyze the physical layout of GRUB2 on an MBR/GPT disk, modify GRUB2 defaults via `/etc/default/grub` and `/etc/grub.d/`, and generate a syntactically valid `/boot/grub/grub.cfg`.

#### Step 1: Inspect the MBR/Boot Sector Header
Run `dd` and `file` to verify bootloader signature placement on your system disk (`/dev/sda` or `/dev/vda`).

```bash
sudo dd if=/dev/vda bs=512 count=1 2>/dev/null | hexdump -C -n 512
```

*Expected Output snippet:*
```text
000001b0  00 00 00 00 00 00 00 00  5b 3f c1 2a 00 00 80 04  |........[?.*....|
000001c0  01 04 83 fe c2 ff 00 08  00 00 00 00 20 04 00 00  |............ ...|
...
000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 55 aa  |..............U.|
```
*Note:* The signature `55 aa` at offset `0x01FE` confirms a bootable MBR sector.

#### Step 2: Edit GRUB2 Defaults `/etc/default/grub`
Open `/etc/default/grub` in an editor and modify/add parameters to configure serial logging, kernel parameters, and menu timeout:

```bash
sudo cat << 'EOF' | sudo tee /etc/default/grub
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(lsb_release -i -s 2>/dev/null || echo Debian)"
GRUB_DEFAULT=0
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash systemd.unified_cgroup_hierarchy=1"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
EOF
```

#### Step 3: Create a Custom GRUB Script in `/etc/grub.d/`
Create an executable custom script `/etc/grub.d/41_custom_rescue` to add a dedicated memory diagnostic or custom boot entry.

```bash
sudo cat << 'EOF' | sudo tee /etc/grub.d/41_custom_rescue
#!/bin/sh
exec tail -n +3 $0
# Custom Boot Entry for Standalone Emergency Kernel
menuentry 'SRE Emergency Debug Kernel' --class linux --class os {
    insmod gzio
    insmod part_msdos
    insmod ext2
    set root='hd0,msdos1'
    linux /vmlinuz-custom root=/dev/vda1 ro single console=ttyS0,115200
    initrd /initrd.img-custom
}
EOF

sudo chmod +x /etc/grub.d/41_custom_rescue
```

#### Step 4: Recompile `/boot/grub/grub.cfg`
Rebuild the active configuration file using distro-agnostic path checking.

```bash
# On Debian/Ubuntu systems:
sudo grub-mkconfig -o /boot/grub/grub.cfg

# On RHEL/CentOS/Rocky systems (Legacy MBR vs UEFI):
# MBR: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
# UEFI: sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
```

*Expected Output:*
```text
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-40-generic
Found initrd image: /boot/initrd.img-6.8.0-40-generic
Adding boot menu entry for UEFI Firmware Settings ...
done
```

---

### Hands-on Exercise 1.2: Initramfs Inspection, Extraction, and Custom Hook Injection

In this exercise, you will unpack an active `initramfs`/`initrd` cpio archive, inspect its internal root filesystem, modify `/init`, and rebuild the image manually using `cpio` and `dracut` / `update-initramfs`.

#### Step 1: Locate and Determine Compression of Current Initramfs
Determine the compression format of your current boot image.

```bash
ls -lh /boot/initrd.img-$(uname -r) || ls -lh /boot/initramfs-$(uname -r).img
file /boot/initrd.img-$(uname -r)
```

*Expected Output:*
```text
/boot/initrd.img-6.8.0-40-generic: ASCII cpio archive (SVR4 with no CRC)
```
*Note:* Modern initramfs files often consist of early uncompressed microcode (AMD/Intel CPU) appended before a compressed main cpio archive (Zstandard, gzip, or xz).

#### Step 2: Unpack Early Microcode and Main Archive
Create a temporary workspace in `/tmp/initramfs_inspect` and unpack the archive using `lsinitramfs`, `uncompress`, or `unpk`.

```bash
mkdir -p /tmp/initramfs_inspect && cd /tmp/initramfs_inspect

# Using unmkinitramfs (Debian/Ubuntu tool that extracts microcode + main tree):
unmkinitramfs /boot/initrd.img-$(uname -r) .

ls -la
```

*Expected Output:*
```text
drwxr-xr-x 3 root root 4096 Aug  6 10:15 early
drwxr-xr-x 8 root root 4096 Aug  6 10:15 main
```

#### Step 3: Inspect `/init` and Embedded Binary Drivers inside `main/`
Explore the generated root filesystem of initramfs.

```bash
cd /tmp/initramfs_inspect/main
ls -la init
head -n 25 init
```

*Expected Output snippet:*
```bash
#!/bin/sh
[ -d /dev ] || mkdir -p /dev
[ -d /sys ] || mkdir -p /sys
[ -d /proc ] || mkdir -p /proc
mount -t sysfs -o nosuid,noexec,nodev sysfs /sys
mount -t proc -o nosuid,noexec,nodev proc /proc
...
```

#### Step 4: Rebuild Initramfs Image using Distribution Native Tooling
Re-generate the default initramfs file for the currently running kernel.

```bash
# On Debian / Ubuntu:
sudo update-initramfs -u -k $(uname -r)

# On RHEL / Fedora / Rocky Linux:
sudo dracut --force /boot/initramfs-$(uname -r).img $(uname -r)
```

*Expected Output:*
```text
update-initramfs: Generating /boot/initrd.img-6.8.0-40-generic
```

---

### Verification Questions — Section 1

1. **Question 1.1:** During an MBR legacy boot, what is the exact physical role of `core.img` (Stage 1.5), where is it stored when using a standard GPT or MBR disk layout, and why is it necessary before reading `/boot/grub/grub.cfg`?
2. **Question 1.2:** If `update-initramfs` or `dracut` is executed without including storage controller modules (e.g., `nvme`, `ahci`, or `virtio_blk`), at what exact phase of the boot process will the system fail, and what kernel panic error message will be printed on the console?

---

## 2. Advanced Kernel Boot Parameters & Diagnostic Recovery

### Architectural Mechanics of Kernel Command Line Injection
The GRUB2 bootloader passes kernel command-line options via memory registers specified by the x86 Linux Boot Protocol (`struct setup_header`). The kernel parses these parameters during `setup_arch()` and `start_kernel()` prior to initializing hardware subsystems.

```
+-----------------------------------------------------------------------------+
|                                GRUB2 Engine                                 |
+-----------------------------------------------------------------------------+
                                       |
                   Appends text parameters from grub.cfg
                                       |
                                       v
+-----------------------------------------------------------------------------+
| Linux Kernel (`vmlinuz`) Command Line Parameters                             |
| E.g.: `root=/dev/mapper/vg0-root ro init=/bin/bash systemd.unit=emergency`  |
+-----------------------------------------------------------------------------+
                                       |
                     Parsed during kernel `start_kernel()`
                                       |
            +--------------------------+--------------------------+
            |                                                     |
            v                                                     v
+-----------------------+                             +-----------------------+
|  Initramfs `/init`    |                             | Systemd (`PID 1`)     |
|  Interprets `rd.*`    |                             | Interprets `systemd.*`|
+-----------------------+                             +-----------------------+
```

Key diagnostic parameters:
* `init=/bin/bash`: Bypasses `systemd` completely. Kernel executes raw `/bin/bash` as PID 1 directly from the root filesystem.
* `rd.break`: Halts execution inside the `initramfs` environment right before handing off control to the real root file system (`/sysroot`).
* `systemd.unit=rescue.target` / `systemd.unit=emergency.target`: Tells systemd to boot into isolated minimal targets (single-user modes).
* `systemd.debug_shell=1`: Spawns an unauthenticated root shell on `tty9` (`Ctrl+Alt+F9`) during systemd boot sequence execution.

---

### Hands-on Exercise 2.1: Simulating Root Password Recovery via `rd.break` and `init=/bin/bash`

In this exercise, you will learn the exact steps executed during emergency root filesystem maintenance and password reset procedures.

#### Step 1: Simulate `rd.break` Execution Workflow (RHEL/Dracut Style)
1. Reboot the target node and interrupt GRUB2 at the selection menu by pressing `e`.
2. Locate the line starting with `linux` or `linux16` or `linuxefi`.
3. Append `rd.break` to the end of the `linux` command line.
4. Press `Ctrl+X` or `F10` to boot.

*Simulated Shell execution upon reaching emergency initramfs prompt:*
```bash
# 1. System drops into switch_root breakpoint
switch_root:/# 

# 2. Remount /sysroot with read-write permissions
switch_root:/# mount -o remount,rw /sysroot

# 3. Chroot into the actual operating system target root
switch_root:/# chroot /sysroot

# 4. Perform administration (e.g., reset root password)
sh-5.1# passwd root
Enter new UNIX password:
Retype new UNIX password:
passwd: password updated successfully

# 5. Relabel SELinux context if SELinux is active
sh-5.1# touch /.autorelabel

# 6. Exit chroot and exit initramfs to resume normal boot
sh-5.1# exit
switch_root:/# exit
```

#### Step 2: Simulate Direct Shell Override `init=/bin/bash` (Debian/Ubuntu/SysV Style)
1. Reboot and press `e` at the GRUB2 menu.
2. Replace `ro quiet splash` with `rw init=/bin/bash`.
3. Press `Ctrl+X` to boot.

*Simulated Execution:*
```bash
# System boots directly to PID 1 bash shell without mounting secondary filesystems
root@node:(none):/# id
uid=0(root) gid=0(root) groups=0(root)

root@node:(none):/# ps -ef
UID          PID PPID  C STIME TTY          TIME CMD
root           1    0  0 10:16 ?        00:00:00 /bin/bash

# Remount / read-write if booted in ro mode:
root@node:(none):/# mount -o remount,rw /

# Update password
root@node:(none):/# passwd

# Flush changes to disk before forced powercycle
root@node:(none):/# sync
root@node:(none):/# exec /sbin/reboot -f
```

---

### Hands-on Exercise 2.2: Advanced Boot Performance Analysis and Service Failure Tracing

In this exercise, you will analyze system boot performance, locate boot bottlenecks, and isolate failing units using `systemd-analyze` and `journalctl`.

#### Step 1: Measure Boot Time Breakdown
Run `systemd-analyze` to measure time spent in Firmware, Loader, Kernel, Initrd, and Userspace.

```bash
systemd-analyze
```

*Expected Output:*
```text
Startup finished in 1.412s (firmware) + 2.105s (loader) + 1.844s (kernel) + 4.120s (initrd) + 6.311s (userspace) = 15.794s 
graphical.target reached after 6.280s in userspace.
```

#### Step 2: Identify Slowest Initialization Services
Determine which services are causing initialization delays.

```bash
systemd-analyze blame | head -n 10
```

*Expected Output:*
```text
2.410s NetworkManager-wait-online.service
1.105s dev-vda1.device
0.844s snapd.service
0.612s systemd-logind.service
0.410s ebtables.service
```

#### Step 3: Plot the Critical Chain of Boot Services
Examine the exact dependency chain delaying the final target state.

```bash
systemd-analyze critical-chain graphical.target
```

*Expected Output:*
```text
graphical.target @6.280s
└─multi-user.target @6.279s
  └─docker.service @4.810s +1.468s
    └─network.target @4.801s
      └─NetworkManager.service @3.210s +1.589s
        └─dbus.service @3.190s
          └─basic.target @3.150s
```

#### Step 4: Inspect System Boot Logs for Specific Reboots
Query logs from the current vs. previous boot runs using `journalctl`.

```bash
# List recorded boot sessions
journalctl --list-boots

# View logs from the current boot for priority level Error or critical
journalctl -b 0 -p err..emerg

# Trace boot logs for unit failures from the prior boot session (-1)
journalctl -b -1 -u systemd-modules-load.service
```

---

### Verification Questions — Section 2

1. **Question 2.1:** What is the fundamental difference between booting with `rd.break` versus booting with `init=/bin/bash` regarding the environment, PID 1 execution, and filesystem structure?
2. **Question 2.2:** If a server hangs indefinitely at boot with `NetworkManager-wait-online.service` stalling the initialization sequence, what systemd command can be executed to disable this specific blocking behavior without breaking standard `NetworkManager` networking?

---

## 3. Customizing Boot Loaders & Init Mechanisms Comparison (SysVinit vs. systemd vs. Upstart vs. OpenRC)

### Comparative Analysis Matrix

| Feature / Subsystem | SysVinit | Upstart | systemd | OpenRC |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Configuration** | `/etc/inittab`, `/etc/init.d/` | `/etc/init/` (`.conf` jobs) | `/etc/systemd/system/`, `/lib/systemd/system/` | `/etc/conf.d/`, `/etc/init.d/` |
| **Concurrency / Parallelism**| Sequential (Shell scripts based on runlevels) | Event-driven (Asynchronous job start) | Concurrent (Socket & D-Bus activation, dynamic cgroups) | Parallel dependency-based startup |
| **Process Tracking** | PID files (fragile, subject to PID re-use) | PTRACE tracing (`expect fork/daemon`) | Control Groups (`cgroups`) | Linux cgroups / PID tracking |
| **Target / State Equivalent**| Runlevels (`0` to `6`) | Runlevels / Event signals | Targets (`.target` units) | Runlevels (`default`, `boot`, `nonetwork`) |
| **Service Status Query** | `/sbin/service <name> status` | `status <job>` | `systemctl status <name>` | `rc-service <name> status` |

---

### Runlevel to systemd Target Mapping

```
+-------------------+--------------------------------+----------------------------------------+
| SysVinit Runlevel | systemd Target Unit            | Description                            |
+-------------------+--------------------------------+----------------------------------------+
| Runlevel 0        | `poweroff.target`              | Shuts down and powers off the system.  |
| Runlevel 1 / S    | `rescue.target`                | Single-user mode (minimal maintenance).|
| Runlevel 2        | `multi-user.target`            | Multi-user text mode (without networking|
|                   |                                | on SysV Debian; standard on systemd).  |
| Runlevel 3        | `multi-user.target`            | Multi-user non-graphical networking mode|
| Runlevel 4        | `multi-user.target`            | User-defined / Custom.                 |
| Runlevel 5        | `graphical.target`             | Multi-user graphical UI mode (X11/Wayland)|
| Runlevel 6        | `reboot.target`                | Reboots the machine.                   |
+-------------------+--------------------------------+----------------------------------------+
```

---

### Hands-on Exercise 3.1: SysVinit Runlevel Manipulation vs. systemd Target Management

In this exercise, you will set system default boot targets, switch targets at runtime, and write a native custom systemd boot hook service.

#### Step 1: Check and Change the Default System Boot Target
Inspect the default boot target symlink `/etc/systemd/system/default.target`.

```bash
# Query active default target
systemctl get-default

# Change default boot mode to Multi-User Non-Graphical (Runlevel 3 equivalent)
sudo systemctl set-default multi-user.target

# Verify symlink target path
ls -l /etc/systemd/system/default.target
```

*Expected Output:*
```text
multi-user.target
lrwxrwxrwx 1 root root 36 Aug  6 10:16 /etc/systemd/system/default.target -> /lib/systemd/system/multi-user.target
```

#### Step 2: Switch Execution Targets Dynamically
Switch the running system state to rescue mode without rebooting.

```bash
# Isolate rescue target (terminates non-essential services and drops to single-user shell)
sudo systemctl isolate rescue.target
```

To switch back to multi-user mode:
```bash
sudo systemctl isolate multi-user.target
```

#### Step 3: Build a Complete Native systemd Boot Hook Service Manifest
Create a custom service unit `/etc/systemd/system/sre-boot-audit.service` that executes early during the boot phase before network activation.

```bash
sudo cat << 'EOF' | sudo tee /etc/systemd/system/sre-boot-audit.service
[Unit]
Description=SRE Boot Validation & Telemetry Collector
Documentation=https://internal.wiki.sre/boot-audit
DefaultDependencies=no
Before=sysinit.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/sre-boot-audit.sh

[Install]
WantedBy=sysinit.target
EOF
```

Create the corresponding ExecStart payload script:

```bash
sudo cat << 'EOF' | sudo tee /usr/local/bin/sre-boot-audit.sh
#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/sre-boot-audit.log"

echo "[$(date -u +'%Y-%m-%d %H:%M:%SZ')] SRE Boot Audit Triggered" >> "$LOGFILE"
echo "Booted Kernel: $(uname -r)" >> "$LOGFILE"
echo "Root Storage State:" >> "$LOGFILE"
df -h / >> "$LOGFILE"
EOF

sudo chmod +x /usr/local/bin/sre-boot-audit.sh
```

Enable the service unit for boot execution:

```bash
sudo systemctl daemon-reload
sudo systemctl enable sre-boot-audit.service
```

*Expected Output:*
```text
Created symlink /etc/systemd/system/sysinit.target.wants/sre-boot-audit.service → /etc/systemd/system/sre-boot-audit.service.
```

---

### Hands-on Exercise 3.2: Bootloader Installation & Initrd Rebuilding Workflows across Distro Families

In this exercise, you will master the low-level installation commands required to write GRUB2 binaries to disk structures and rebuild ramdisks.

#### Step 1: Re-install GRUB2 Boot Sector (MBR/GPT Legacy)
Write GRUB2 binaries directly to disk device structures (`/dev/vda` or `/dev/sda`).

```bash
# On Debian/Ubuntu:
sudo grub-install /dev/vda

# On RHEL/Rocky Linux:
sudo grub2-install /dev/vda
```

*Expected Output:*
```text
Installing for i386-pc platform.
Installation finished. No error reported.
```

#### Step 2: Install GRUB2 to UEFI System Partition (ESP)
Re-install GRUB2 UEFI binaries targeting a mounted ESP directory (`/boot/efi`).

```bash
sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
```

*Expected Output:*
```text
Installing for x86_64-efi platform.
Installation finished. No error reported.
```

---

### Verification Questions — Section 3

1. **Question 3.1:** In SysVinit, running `init 6` triggers a system reboot. What exact systemd command isolates the reboot target, and what file controls legacy `/etc/inittab` compatibility mapping under systemd?
2. **Question 3.2:** What is the technical function of `DefaultDependencies=no` in a custom systemd service unit file created for early-stage boot initialization?

---

## 4. Comprehensive Hands-on Troubleshooting Scenario

### Production Incident Scenario
You are tasked with recovering an enterprise Linux server that fails to complete its boot sequence after a kernel and storage driver upgrade. The machine hangs during startup displaying the following console output:

```text
[   4.120591] dracut-initqueue[482]: Warning: dracut-initqueue timeout - starting timeout scripts
[   4.121102] dracut-initqueue[482]: Warning: Could not boot.
[   4.122001] dracut-initqueue[482]: Warning: /dev/mapper/rhel-root does not exist
Starting Dracut Emergency Shell...
Warning: /dev/mapper/rhel-root does not exist

Generating "/run/initramfs/rdsosreport.txt"

Entering emergency mode. Exit the shell to continue.
Type "journalctl" to view system logs.
dracut:/#
```

### Diagnostic and Resolution Tasks
1. Execute diagnostic commands inside the Dracut emergency shell to inspect available block devices and LVM volume groups.
2. Determine why `/dev/mapper/rhel-root` was not activated by the initramfs.
3. Manually activate the LVM volume group and complete the boot handoff to the real root system.
4. Permanently repair the system inside the running OS to ensure future boots succeed automatically.

#### Task 1 execution steps:
```bash
# Check loaded block storage drivers and existing block devices
dracut:/# lsblk
dracut:/# lvm pvscan
dracut:/# lvm vgscan
dracut:/# lvm lvscan
```

#### Task 2 execution steps:
```bash
# If volume groups are inactive (showing 'inactive'):
dracut:/# lvm vgchange -ay rhel
  2 logical volume(s) in volume group "rhel" now active

# Verify device node creation:
dracut:/# ls -l /dev/mapper/rhel-root
lrwxrwxrwx 1 root root 7 Aug  6 10:16 /dev/mapper/rhel-root -> ../dm-0
```

#### Task 3 execution steps:
```bash
# Resume initramfs execution sequence
dracut:/# exit
```

#### Task 4 execution steps (Inside recovered OS):
Rebuild the initramfs to include required storage/LVM modules.

```bash
sudo dracut --add "lvm" --force /boot/initramfs-$(uname -r).img $(uname -r)
```

---

<details>
<summary><b>Click to Expand: Answers & Detailed Technical Explanations</b></summary>

### Section 1 Answers

* **Answer 1.1:**
  * **Role:** `core.img` (Stage 1.5) contains the filesystem drivers (e.g., `ext4`, `xfs`, `btrfs`, `lvm`, `mdraid`) necessary to access `/boot/grub/` on the root partition. Stage 1 (`boot.img`) is limited to 446 bytes in the MBR and can only execute hardcoded sector reads.
  * **Storage Location:** On MBR partitioned disks, `core.img` is stored raw in the **post-MBR gap** (unpartitioned sectors between Sector 1 and Sector 2047, preceding the first partition starting at Sector 2048). On GPT disks, it resides inside a dedicated **BIOS Boot Partition** (flagged with GUID `21686148-64C4-4665-870D-14D575017F0E` or `bios_grub` flag, typically 1MB in size).
  * **Why Necessary:** Stage 1 lacks filesystem abstraction code. Without `core.img` parsing the underlying disk format, GRUB cannot find or open `/boot/grub/grub.cfg` to render the boot menu.

* **Answer 1.2:**
  * **Phase:** The failure occurs during the **initramfs phase** immediately after the kernel transfers control to `/init` in RAM, when `/init` attempts to discover block devices and mount the real persistent root filesystem to `/sysroot`.
  * **Error Message:** The kernel/initramfs will emit:  
    `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`  
    or a Dracut emergency shell error:  
    `Warning: Could not boot. /dev/mapper/... does not exist`.

---

### Section 2 Answers

* **Answer 2.1:**
  * **`rd.break`:** Interrupts execution **inside the initramfs** before the switch to the real root file system occurs. The root filesystem is located at `/sysroot` and is mounted **read-only**. You must run `mount -o remount,rw /sysroot` and `chroot /sysroot` to interact with system files. The initramfs shell executes under an ephemeral ramdisk environment.
  * **`init=/bin/bash`:** Bypasses `systemd` completely and instructs the kernel to launch `/bin/bash` directly from the **real root filesystem** as **PID 1**. Initramfs execution has completed, `/` is the actual disk root (typically mounted read-only initially), and no systemd services, socket listeners, logging daemons, or secondary mounts (like `/var` or `/home`) are started.

* **Answer 2.2:**
  * To prevent `NetworkManager-wait-online.service` from delaying system boot, run:
    ```bash
    sudo systemctl disable NetworkManager-wait-online.service
    # Or mask it entirely:
    sudo systemctl mask NetworkManager-wait-online.service
    ```
    This removes it from the dependency path of `network-online.target` without stopping the primary `NetworkManager.service` daemon.

---

### Section 3 Answers

* **Answer 3.1:**
  * **Systemd Command:** `systemctl isolate reboot.target` (or standard alias `systemctl reboot`).
  * **Compatibility Mapping File:** `/lib/systemd/system/runlevelX.target` symlinks (e.g., `runlevel3.target` -> `multi-user.target`) alongside `/etc/systemd/system/default.target`. Legacy commands like `init 3` or `telinit 5` are intercepted by systemd and translated internally into `systemctl isolate runlevelX.target`.

* **Answer 3.2:**
  * By default, every systemd unit implicitly includes dependencies like `After=basic.target`, `Requires=basic.target`, `Wants=systemd-journald.socket`, etc.
  * Setting `DefaultDependencies=no` **disables these automatic default ordering and requirement dependencies**. This is strictly required for early boot services (such as those running before `sysinit.target` or during file system mounting) to prevent dependency loops (deadlocks) during system initialization.

---

### Section 4 Scenario Solution

* **Root Cause Analysis:** The issue was caused by a missing LVM kernel module or storage host bus adapter driver inside the cpio image of the initramfs following an update, preventing initramfs from scanning block storage and discovering the Volume Group containing the logical volume `/dev/mapper/rhel-root`.
* **Resolution Verification:** Manually activating the volume group via `lvm vgchange -ay` made `/dev/mapper/rhel-root` available in `/dev/mapper/`, allowing `/init` to complete mounting `/sysroot`. Rebuilding the image using `dracut --add "lvm" --force` permanently updated the boot cpio archive with the necessary auto-activation hooks.

</details>