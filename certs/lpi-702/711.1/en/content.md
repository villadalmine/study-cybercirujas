# LPI BSD Specialist (702-100) Study Guide
## Topic 711.1: BSD Operating System Installation
**Exam Weight:** 5  
**Target Role:** Principal Platform Architect / Senior SRE  

---

## 1. Motivation and Production Architectural Problem

### 1.1 Production Context: Automated Infrastructure Provisioning at Scale
In modern cloud-native and bare-metal enterprise environments, provisioning operating systems manually via interactive installer wizards is unacceptable. Site Reliability Engineering (SRE) demands idempotent, reproducible, and fully automated deployment pipelines capable of bootstrapping hundreds of physical nodes or hypervisors via Preboot Execution Environment (PXE) or custom installation media.

Operating system installation across the major BSD flavors—**FreeBSD**, **OpenBSD**, and **NetBSD**—presents unique architectural challenges that differ significantly from GNU/Linux distributions (e.g., Anaconda, Cloud-Init, or Preseed):

1. **Bootloader & Console Topology**: Bare-metal enterprise servers in modern datacenters run headlessly without VGA consoles. Bootstrapping requires serial console redirection (`comconsole` / `tty00` / `ttyC0`) over IPMI/iDRAC/iLO Serial-over-LAN (SoL) combined with UEFI/BIOS fallback configurations.
2. **Storage Subsystem Initialization**: SRE architects must decide between legacy FFS/UFS2 layouts and advanced storage pools such as FreeBSD ZFS on Root (`zroot`). Enterprise-grade storage requires programmatic partitioning (GPT vs. BSD Disklabel), storage encryption (GELI / `softraid`), and raid topology layout (mirror vs. raidz2) during the initial installation phase.
3. **Unattended Installer Mechanics**: Each BSD variant exposes a distinct unattended automation interface:
   - **FreeBSD**: `bsdinstall` driven by shell-based `installerconfig` scripts executed inside a chrooted post-installation hook.
   - **OpenBSD**: `autoinstall(8)` driven by a plain-text response file (`install.conf`) served via HTTP/TFTP during `bsd.rd` RAM disk execution.
   - **NetBSD**: `sysinst(8)` automated using scripted configuration manifests or non-interactive flag options.

```
                      +------------------------------------------+
                      |         Enterprise PXE / DHCP Server     |
                      |  DHCP Opt 66 (Next-Server) / Opt 67    |
                      +--------------------+---------------------+
                                           |
                                 iPXE / PXE Boot Request
                                           |
    +--------------------------------------+--------------------------------------+
    |                                      |                                      |
    v                                      v                                      v
+-----------------------+      +-----------------------+      +-----------------------+
|  FreeBSD boot/loader  |      |   OpenBSD bsd.rd      |      |   NetBSD pxeboot      |
| Downloads kernel      |      | Mounts RAM Disk       |      | Mounts NFS / HTTP     |
| Reads installerconfig |      | Fetches install.conf  |      | Runs sysinst script   |
+-----------+-----------+      +-----------+-----------+      +-----------+-----------+
            |                              |                              |
            v                              v                              v
+-----------------------+      +-----------------------+      +-----------------------+
| ZFS Root Pool (zroot) |      | FFS2 + softraid Encrypt|     | FFSv2 / LFS Partition |
| GPT + EFI System Part |      | MBR/GPT + Disklabel   |      | GPT + Wedge Layout    |
+-----------------------+      +-----------------------+      +-----------------------+
```

---

## 2. Technical Comparisons & Trade-off Matrices

### 2.1 Installation Tooling Architecture

| Dimension | FreeBSD (`bsdinstall`) | OpenBSD (`autoinstall`) | NetBSD (`sysinst`) |
| :--- | :--- | :--- | :--- |
| **Execution Environment** | FreeBSD LiveCD / Installer ISO | `bsd.rd` (RAM Disk Kernel) | `netbsd-INSTALL` / Bootable Image |
| **Automation File** | `/etc/installerconfig` (Shell script) | `install.conf` (Key-Value responses) | `sysinst.cfg` / Menu responses |
| **Network Automation Fetch**| TFTP / HTTP pre-fetch to memory | HTTP / TFTP (DHCP option `bootfile`) | HTTP / NFS / Local File |
| **Default Root Filesystem**| ZFS (zroot) or UFS2 + SU/SUJ | FFS / FFS2 (Soft updates disabled by default)| FFSv2 (Fast File System v2) |
| **Post-Install Hooks** | Native shell code execution in script | `siteXX.tgz` archive execution | Custom shell script execution |

### 2.2 Storage Partitioning & File Systems Trade-offs

| Feature / Architecture | ZFS on Root (`zroot`) | UFS2 + Soft Updates (SU/SUJ) | OpenBSD FFS2 + `softraid` | NetBSD FFSv2 + Wedges |
| :--- | :--- | :--- | :--- | :--- |
| **Primary OS** | FreeBSD | FreeBSD / NetBSD | OpenBSD | NetBSD |
| **Volume Management** | Integrated (Pool/Datasets) | External (GEOM / `gpart`) | Integrated (`bioctl` / `softraid`) | Integrated (`dk` wedges) |
| **Data Integrity Verification**| End-to-end 256-bit checksums | Metadata journaling | FSCK-based filesystem verification | FSCK / WAPBL (Journaling) |
| **Native Encryption** | ZFS Native (AES-256-GCM) | GELI (`geli(8)`) | `softraid` (`crypto`) | `cgd(4)` (Crypto Graphic Disk) |
| **Memory Overhead** | High (Requires 4GB+ RAM) | Low (< 512MB RAM) | Low (< 512MB RAM) | Low (< 512MB RAM) |
| **Partition Scheme** | GPT (GUID Partition Table) | GPT or MBR | MBR/GPT + BSD Disklabel | GPT / BSD Disklabel / Wedges |

### 2.3 OS Release Maintenance & Upgrades

| OS Variant | Binary Upgrade Tool | Source Upgrade Method | Rolling/Release Cadence |
| :--- | :--- | :--- | :--- |
| **FreeBSD** | `freebsd-update(8)` / `pkg(8)` | `make buildworld && make installworld` | 6-month point releases, 5-year STABLE |
| **OpenBSD** | `sysupgrade(8)` / `pkg_add(8)` | `cvs` / `got` source checkout & `make` | 6-month release lifecycle (2 releases supported) |
| **NetBSD** | `sysinst(8)` / `pkgin(1)` | `./build.sh release` pipeline | 1-2 year major release lifecycle |

---

## 3. Complete Production Manifests & Infrastructural Configurations

### 3.1 FreeBSD Unattended `installerconfig` Script
This fully automated script configures a headless FreeBSD system with ZFS Mirror, GPT EFI boot, Serial Console, and SSH access.

```sh
#!/bin/sh
# /etc/installerconfig - FreeBSD Automated Unattended Installation Script
# Target Architecture: x86_64 UEFI / Serial Console / Dual-Disk ZFS Mirror

# 1. Environment & Non-interactive Variables
export INTERACTIVE=0
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# 2. Network Configuration
hostname="bsd-node-01.production.internal"
DISTRIBUTIONS="base.txz kernel.txz src.txz"

# 3. Target Disks Setup
PRIMARY_DISK="da0"
SECONDARY_DISK="da1"

# 4. Clear existing partition tables
gpart destroy -F ${PRIMARY_DISK} || true
gpart destroy -F ${SECONDARY_DISK} || true

# 5. Automated ZFS Root Partitioning via bsdinstall zfsboot
export ZFSBOOT_VDEV_TYPE="mirror"
export ZFSBOOT_DISKS="${PRIMARY_DISK} ${SECONDARY_DISK}"
export ZFSBOOT_POOL_NAME="zroot"
export ZFSBOOT_CONFIRM_ZPOOL=1
export ZFSBOOT_SWAP_SIZE="8g"
export ZFSBOOT_SWAP_ENCRYPTION=1
export ZFSBOOT_GELI_ENCRYPTION=0
export ZFSBOOT_BOOT_TYPE="UEFI"

# Trigger automated ZFS setup
bsdinstall zfsboot

# Extract base distributions into /mnt
bsdinstall distextract

# 6. Post-Installation Configuration Hook (Inside target chroot /mnt)
cat << 'EOF' > /mnt/etc/rc.conf
# Network Configuration
hostname="bsd-node-01.production.internal"
ifconfig_vtnet0="DHCP"
ifconfig_vtnet0_ipv6="inet6 accept_rtadv"

# Base Services
sshd_enable="YES"
ntpdate_enable="YES"
ntpdate_flags="-b pool.ntp.org"
ntpd_enable="YES"
powerd_enable="YES"

# Security & Auditing
clear_tmp_enable="YES"
syslogd_flags="-s -s"
sendmail_enable="NONE"
EOF

# 7. Bootloader & Kernel Options (/boot/loader.conf)
cat << 'EOF' > /mnt/boot/loader.conf
# ZFS Module Settings
zfs_load="YES"
vfs.root.mountfrom="zfs:zroot/ROOT/default"

# Serial Console Redirection over IPMI / SoL
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"

# Performance Tuning
kern.maxproc="65536"
net.inet.tcp.soreceive_stream="1"
EOF

# 8. User Accounts & SSH Key Provisioning
chroot /mnt pw useradd -n admin -c "SRE Admin" -m -s /bin/csh -g wheel
mkdir -p /mnt/home/admin/.ssh
cat << 'EOF' > /mnt/home/admin/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGx8Z5qY7K1vN9+P3nQ0X9JmKxR3Yv8L7N2W1Q8Z0X1Y sre-deployer@production
EOF
chmod 700 /mnt/home/admin/.ssh
chmod 600 /mnt/home/admin/.ssh/authorized_keys
chown -R 1001:0 /mnt/home/admin

# 9. Sudoers Configuration
echo "admin ALL=(ALL) NOPASSWD: ALL" > /mnt/usr/local/etc/sudoers.d/admin
chmod 440 /mnt/usr/local/etc/sudoers.d/admin

# Complete Installation
bsdinstall config
```

---

### 3.2 OpenBSD Unattended `install.conf` Manifest
This `install.conf` file is served via HTTP (`http://pxe.internal/install.conf`) for OpenBSD `autoinstall(8)`.

```ini
# OpenBSD autoinstall(8) Response File - install.conf
# Production Headless Bare-Metal / Hypervisor Profile

System hostname = bsd-node-02
Password for root = $6$vL8zP9xK$E5fR1T2Y3U4I5O6P7Q8R9S0T1U2V3W4X5Y6Z7a8b9c0d1e2f3g4h5i6j7k8l9m0
Change the default console to com0 = yes
Which speed should com0 use = 115200
Setup a user = sreuser
Full name for user sreuser = SRE Automation User
Password for user sreuser = $6$k8L9m0N1$P2Q3R4S5T6U7V8W9X0Y1Z2a3b4c5d6e7f8g9h0i1j2k3l4m5n6o7p8q9
Public ssh key for user sreuser = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9P4K2vN8+X1mQ0R9JmKxR3Yv8L7N2W1Q8Z0X1Y sre-key
What timezone are you in = UTC
Location of sets = http
HTTP proxy = none
HTTP Server = cdn.openbsd.org
Server directory = pub/OpenBSD/7.5/amd64
Set name(s) = +* -game* -x*
Use (A)uto layout, (E)dit or use (C)ustom layout = auto
Which disk is the root disk = sd0
Encrypt the root disk = no
Perform auto-installation = yes
URL to site-specific customization notes = none
```

---

### 3.3 NetBSD Unattended `sysinst.cfg` Response File
This scriptable configuration drives NetBSD's `sysinst(8)` utility during automated PXE deployments.

```ini
# NetBSD sysinst(8) Unattended Installation Configuration
# File: /usr/share/sysinst/sysinst.cfg

VERSION=10.0
DISTRIBDIR=/pub/NetBSD/NetBSD-10.0/amd64
DISK=ld0
PARTITION_SCHEME=gpt

# Disk Partitioning Specifications (Megabytes)
BOOT_SIZE=512
SWAP_SIZE=4096
ROOT_SIZE=32768
VAR_SIZE=10240
USR_SIZE=0

# Filesystem Types
FS_TYPE=ffsv2
MOUNT_OPTIONS=log

# Networking Configuration
NET_INTERFACE=vioif0
NET_DHCP=yes
HOST_NAME=bsd-node-03.production.internal

# Base Distribution Sets Selection
SET_base=yes
SET_etc=yes
SET_comp=yes
SET_games=no
SET_man=yes
SET_misc=yes
SET_modules=yes
SET_tests=no
SET_text=yes
SET_xbase=no
SET_xcomp=no
SET_etcserv=yes

# Post-Install Shell Hook Commands
POST_INSTALL_CMD=/bin/sh -c "echo 'rc_configured=YES' >> /target/etc/rc.conf && echo 'sshd=YES' >> /target/etc/rc.conf && echo 'tty00 \"/usr/libexec/getty std.115200\" vt100 on secure' >> /target/etc/ttys"
```

---

## 4. CLI Execution & Real Terminal Outputs

### 4.1 FreeBSD Installation and Post-Boot System Verification

#### Command: Querying System Architecture and Kernel Metadata
```console
$ uname -a
FreeBSD bsd-node-01.production.internal 14.0-RELEASE FreeBSD 14.0-RELEASE releng/14.0-n265380-f3518167086d GENERIC amd64
```

#### Command: Inspecting Disk Partitioning (GPT Layout)
```console
$ gpart show -p
=>       40  1000215136  da0  GPT  (476G)
         40        1024       - free -  (512K)
       1064      1048576  da0p1  efi  (512M)
    1049640         2048  da0p2  freebsd-boot  (1.0M)
    1051688     16777216  da0p3  freebsd-swap  (8.0G)
   17828904    982386272  da0p4  freebsd-zfs  (468G)

=>       40  1000215136  da1  GPT  (476G)
         40        1024       - free -  (512K)
       1064      1048576  da1p1  efi  (512M)
    1049640         2048  da1p2  freebsd-boot  (1.0M)
    1051688     16777216  da1p3  freebsd-swap  (8.0G)
   17828904    982386272  da1p4  freebsd-zfs  (468G)
```

#### Command: Inspecting ZFS Storage Pool Health & Mirror Configuration
```console
$ zpool status zroot
  pool: zroot
 state: ONLINE
  scan: scrub repaired 0B in 00:01:23 with 0 errors on Thu Aug  6 18:30:11 2026
config:

	NAME        STATE     READ WRITE CKSUM
	zroot       ONLINE       0     0     0
	  mirror-0  ONLINE       0     0     0
	    da0p4   ONLINE       0     0     0
	    da1p4   ONLINE       0     0     0

errors: No known data errors
```

#### Command: Performing a Base System Upgrade via `freebsd-update`
```console
# freebsd-update fetch
src component not installed, skipped
Looking up update.FreeBSD.org mirrors... 3 mirrors found.
Fetching public key from update.FreeBSD.org... done.
Fetching metadata signature for 14.0-RELEASE from update.FreeBSD.org... done.
Fetching metadata index... done.
Inspecting system... done.
Preparing to download files... done.
The following files will be updated as part of updating to 14.0-RELEASE-p5:
/bin/freebsd-version
/lib/libc.so.7
/usr/sbin/sshd

# freebsd-update install
Installing updates...
Kernel updates have been installed. Please reboot the system.
Completing the upgrade... done.
```

---

### 4.2 OpenBSD Boot, Verification, and Upgrade Workflow

#### Command: Verifying Kernel and OS Version
```console
$ uname -a
OpenBSD bsd-node-02 7.5 GENERIC.MP#82 amd64
```

#### Command: Inspecting OpenBSD Disk Architecture (`disklabel`)
```console
$ disklabel sd0
# /dev/rsd0c:
type: SCSI
disk: SCSI disk
label: VBOX HARDDISK
flags:
bytes/sector: 512
sectors/track: 63
tracks/cylinder: 255
sectors/cylinder: 16065
cylinders: 10443
total sectors: 167772160

16 partitions:
#                size        offset    fstype [fsize bsize cpg]
  a:         41943040      10485760    4.2BSD   4096 32768   16 # /
  b:          8388608       2097152      swap                   # swap
  i:          2048000            64   MSDOS                     # EFI System Partition
  k:        114696192      52428800    4.2BSD   4096 32768   16 # /usr/local
```

#### Command: Automated OS Upgrade via `sysupgrade`
```console
# sysupgrade -r
Fetching https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/SHA256
Fetching https://cdn.openbsd.org/pub/OpenBSD/7.6/amd64/bsd.rd
Verifying SHA256.sig... Signature Verified
Upgrading system from 7.5 to 7.6...
Copying /bsd.rd to /bsd.upgrade... done.
Rebooting system into /bsd.upgrade to apply update...
```

---

### 4.3 NetBSD System Diagnostics

#### Command: System Identification and Kernel Configuration
```console
$ uname -a
NetBSD bsd-node-03 10.0 NetBSD 10.0 (GENERIC) #0: Thu Mar 28 08:33:37 UTC 2024  builduser@netbsd.org:/usr/obj/sys/arch/amd64/compile/GENERIC amd64
```

#### Command: Inspecting NetBSD Kernel Storage Wedges (`dk`)
```console
$ dkctl ld0 listwedges
4 wedges created for ld0:
dk0: EFI System Partition, 1048576 blocks at 2048, type: msdos
dk1: netbsd-swap, 8388608 blocks at 1050624, type: swap
dk2: netbsd-root, 67108864 blocks at 9439232, type: ffs
dk3: netbsd-usr, 91224031 blocks at 76548096, type: ffs
```

---

## 5. Failure Diagnosis & Emergency Recovery Guide

```
                         [ Boot Failure Event ]
                                    |
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
 [ Storage / Pool Corrupted ]                    [ Bootloader / Console Failure ]
            |                                               |
  1. Boot live installer media                     1. Intercept bootloader menu
  2. FreeBSD: zpool import -f -R /mnt zroot        2. FreeBSD: set console="comconsole"
  3. OpenBSD: fsck_ffs -y /dev/rsd0a               3. OpenBSD: boot hd0a:/bsd.rd
  4. NetBSD: fsck_ffs -y /dev/rdk2                 4. Force kernel load & boot
```

### 5.1 Scenario 1: ZFS Root Pool Import Failure (FreeBSD)

#### Root Cause Analysis
Unclean node shutdowns or mismatched host IDs during hardware replacement prevent `zroot` from mounting automatically, dropping the system into the bootloader prompt (`OK`).

#### Diagnostic Commands at Loader Prompt
```console
OK lsdev
Block devices:
  disk0:   GPT Array
    disk0p1: EFI System
    disk0p2: FreeBSD Boot
    disk0p3: FreeBSD Swap
    disk0p4: FreeBSD ZFS
OK set currdev="zfs:zroot/ROOT/default:"
OK load /boot/kernel/kernel
OK load /boot/kernel/zfs.ko
OK boot
```

#### Recovery Procedure via Live Media
Boot into FreeBSD Rescue Shell and force-import the pool using an alternate mount point root (`-R`):

```console
# zpool import
   pool: zroot
     id: 1478204918239012389
  state: ONLINE
 status: The pool was last accessed by another system.
 action: The pool can be imported using its name or numeric identifier.
 config:

	zroot       ONLINE
	  mirror-0  ONLINE
	    da0p4   ONLINE
	    da1p4   ONLINE

# Force import pool with alternate root
# zpool import -f -R /mnt zroot

# Verify filesystems are mounted
# df -h /mnt
Filesystem             Size    Used   Avail Capacity  Mounted on
zroot/ROOT/default     450G    4.2G    4458G     1%    /mnt

# Regenerate zpool cache file
# zpool set cachefile=/mnt/boot/zfs/zpool.cache zroot
# zpool export zroot
# reboot
```

---

### 5.2 Scenario 2: Serial Console Blackout / Misconfigured TTYs

#### Root Cause Analysis
The kernel boots, but output stops after `Booting...`. The system is configured for VGA video (`vidconsole`), whereas the IPMI environment expects Serial-over-LAN (`comconsole` / `tty00` at 115200 bps).

#### Remediation Matrix Across BSD Variants

##### FreeBSD Fix (`/boot/loader.conf` & `/etc/ttys`)
```sh
# Mount root filesystem read-write
mount -u -w /

# Enforce comconsole in loader configuration
cat << 'EOF' >> /boot/loader.conf
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole"
EOF

# Enable getty on serial port in /etc/ttys
sed -i '' 's/ttyu0.*off/ttyu0 "/usr/libexec/getty 3wire.115200" vt100 on secure/' /etc/ttys
```

##### OpenBSD Fix (`/etc/boot.conf` & `/etc/ttys`)
```sh
# Mount root filesystem read-write
mount -u -w /

# Configure bootloader for com0
cat << 'EOF' > /etc/boot.conf
set tty com0
stty com0 115200
EOF

# Enable console getty on tty00
sed -i 's/tty00.*off/tty00 "/usr/libexec/getty std.115200" vt220 on secure/' /etc/ttys
```

---

### 5.3 Scenario 3: FFS / UFS Metadata Corruption Recovery

#### Root Cause Analysis
Power interruption during disk writes breaks superblocks or inode tables on OpenBSD / NetBSD FFS filesystems, resulting in a forced read-only emergency shell.

#### Emergency Terminal Diagnosis & FSCK Repair
```console
# Identify corrupt partition via dmesg
$ dmesg | grep "bad super block"
sd0a: bad super block magic number

# Run fsck in interactive or force mode
# fsck_ffs -b 32 -y /dev/rsd0a
** /dev/rsd0a
** File System: ffs (cg 0, cgp 0x0, maxblks 16)
** Last Mounted on /
** Phase 1 - Check Blocks and Sizes
** Phase 2 - Check Pathnames
** Phase 3 - Check Connectivity
** Phase 4 - Check Reference Counts
** Phase 5 - Check Cyl groups
FREE BLK COUNT(S) INCORRECT IN SILO
FIX? yes

MARK FILE SYSTEM CLEAN? yes

***** FILE SYSTEM WAS MODIFIED *****
***** PLEASE REBOOT SYSTEM *****
```

---

## 6. References

- **LPI BSD Specialist Certification Objectives Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **FreeBSD Handbook: Chapter 2. Installing FreeBSD (`bsdinstall`)**:  
  https://docs.freebsd.org/en/books/handbook/bsdinstall/
- **FreeBSD Manual Pages: `installerconfig` & `bsdinstall(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=bsdinstall
- **OpenBSD Manual Pages: Automated System Installation (`autoinstall(8)`)**:  
  https://man.openbsd.org/autoinstall.8
- **OpenBSD Handbook: System Installation (`bsd.rd`)**:  
  https://www.openbsd.org/faq/faq4.html
- **NetBSD Automated Installation Guide (`sysinst`)**:  
  https://wiki.netbsd.org/tutorials/how_to_install_netbsd_automating/
- **NetBSD Architecture Documentation & Bootloaders**:  
  https://www.netbsd.org/docs/guide/en/chap-install.html