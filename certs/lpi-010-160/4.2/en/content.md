# 4.2 Understanding Computer Hardware

**Exam weight: 2** — expect a couple of questions on identifying the main hardware components (CPU, RAM, storage, motherboard, power supply, peripherals), how Linux names and exposes them (`/dev`, `/proc`, `/sys`), and the basic commands to inspect them (`lscpu`, `free`, `lsblk`, `lspci`, `lsusb`).

---

## 1. Why Hardware Matters to a Linux User

Linux runs on almost any hardware — from a Raspberry Pi to a mainframe — but you still need to understand what the machine is made of: to choose the right distribution image (64-bit vs. ARM), to size memory and disk, to troubleshoot a device that is not detected, and to read what the kernel reports about the system. A key Linux idea to keep in mind throughout this topic: **the kernel represents hardware as files**, mostly under `/dev`, `/proc`, and `/sys`.

## 2. Motherboard, CPU, and Firmware

### 2.1 Motherboard

The **motherboard** (mainboard) is the circuit board that connects everything: the CPU socket, RAM slots, storage connectors (SATA, M.2/NVMe), expansion slots (PCIe), and external ports (USB, network, video). Many functions that used to require expansion cards — sound, Ethernet, basic graphics — are now **onboard** (integrated into the motherboard).

### 2.2 Firmware: BIOS and UEFI

When the machine powers on, firmware stored on the motherboard initializes the hardware and starts the boot process:

- **BIOS** (Basic Input/Output System) — the legacy firmware; boots from a disk's Master Boot Record (MBR).
- **UEFI** (Unified Extensible Firmware Interface) — the modern replacement; boots EFI applications from a dedicated FAT-formatted **EFI System Partition (ESP)** and normally uses GPT-partitioned disks.

The firmware hands control to a **bootloader** (on Linux, typically GRUB 2), which loads the kernel.

### 2.3 CPU

The **CPU** (Central Processing Unit, or processor) executes instructions. Concepts the exam cares about:

- **Architecture / instruction set**: `x86_64` (also called `amd64`, the standard 64-bit PC architecture), legacy 32-bit `i386`/`i686`, and **ARM** (`aarch64`), common in phones, single-board computers like the Raspberry Pi, and increasingly in servers and laptops. A distribution image must match the CPU architecture.
- **Cores and threads**: modern CPUs contain several **cores** (independent execution units); with simultaneous multithreading (Intel's Hyper-Threading), each core can run two threads.
- **64-bit vs. 32-bit**: a 64-bit CPU can address far more RAM and runs 64-bit operating systems; 32-bit systems are effectively limited to about 4 GiB of address space.

Inspecting the CPU:

```bash
$ lscpu
Architecture:        x86_64
CPU op-mode(s):      32-bit, 64-bit
CPU(s):              8
Thread(s) per core:  2
Core(s) per socket:  4
Model name:          Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

The same information comes from the kernel's process filesystem:

```bash
$ cat /proc/cpuinfo | grep 'model name' | head -1
model name  : Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz
```

`uname -m` prints the machine architecture (`x86_64`, `aarch64`, …).

## 3. Memory

**RAM** (Random Access Memory) is the fast, **volatile** working memory: its contents are lost when power is removed. Programs and the kernel live in RAM while running. Do not confuse RAM ("memory") with disk ("storage").

When RAM runs low, Linux can move inactive memory pages to **swap** — a dedicated partition or file on disk. Swap prevents out-of-memory failures but is much slower than RAM.

```bash
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            15Gi       4.2Gi       6.1Gi       310Mi       5.0Gi        10Gi
Swap:          2.0Gi          0B       2.0Gi
```

Notes on reading `free`:

- `-h` prints human-readable sizes.
- **buff/cache** is RAM the kernel uses to cache disk data; it is released automatically when applications need it, which is why **available** (not `free`) is the realistic measure of usable memory.
- Detailed counters live in `/proc/meminfo`.

## 4. Storage

### 4.1 Device types

Unlike RAM, storage is **non-volatile** — data persists across power cycles:

- **HDD** (Hard Disk Drive): spinning magnetic platters; cheap per gigabyte, mechanically fragile, slower.
- **SSD** (Solid State Drive): flash memory, no moving parts; much faster and more shock-resistant. Connected via SATA or, for the fastest models, via **NVMe** over PCIe.
- **Removable / optical media**: USB flash drives, SD cards, CD/DVD.
- **Network storage**: NAS (file-level, e.g. NFS/SMB shares) and SAN (block-level) — storage served over the network rather than attached locally.

### 4.2 How Linux names storage devices

Devices appear as **block device** files under `/dev`:

| Device | Naming pattern | Example |
|---|---|---|
| SATA/SCSI/USB disks | `/dev/sdX` | `/dev/sda`, `/dev/sdb` |
| NVMe SSDs | `/dev/nvmeXnY` | `/dev/nvme0n1` |
| SD/MMC cards | `/dev/mmcblkX` | `/dev/mmcblk0` |
| Optical drives | `/dev/srX` | `/dev/sr0` |

### 4.3 Partitions

A disk is normally split into **partitions** — independent sections that each hold a filesystem (or swap). The partition layout is described by a **partition table** on the disk:

- **MBR** — legacy scheme; at most 4 primary partitions, disks up to 2 TiB.
- **GPT** — modern scheme used with UEFI; up to 128 partitions and very large disks.

Partitions are numbered after the device name: `/dev/sda1`, `/dev/sda2`; NVMe adds a `p`: `/dev/nvme0n1p1`. To use a filesystem, Linux **mounts** the partition onto a directory in the single unified tree (there are no drive letters).

```bash
$ lsblk
NAME          MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda             8:0    0 465.8G  0 disk
├─sda1          8:1    0   512M  0 part /boot/efi
├─sda2          8:2    0 457.3G  0 part /
└─sda3          8:3    0     8G  0 part [SWAP]
sr0            11:0    1  1024M  0 rom
```

`lsblk` lists block devices and their partitions; `df -h` shows mounted filesystems and their free space.

## 5. Power Supply, Peripherals, and Buses

### 5.1 Power supply

The **PSU** (Power Supply Unit) converts wall AC into the DC voltages the components need. It is sized in watts; an underpowered or failing PSU causes random reboots and instability. Laptops add a battery; servers often use **redundant** hot-swappable PSUs. On Linux, battery and AC status are exposed under `/sys/class/power_supply/`.

### 5.2 Peripherals and how to list them

Peripherals are devices attached to the system: keyboard, mouse, display, printer, webcam, network adapters. They connect through **buses**, mainly:

- **USB** — external hot-pluggable devices. List them with `lsusb`:

```bash
$ lsusb
Bus 002 Device 003: ID 8087:0025 Intel Corp. Wireless-AC 9260 Bluetooth
Bus 001 Device 004: ID 046d:c52b Logitech, Inc. Unifying Receiver
```

- **PCI / PCI Express** — internal devices: graphics cards, network interfaces, NVMe controllers. List them with `lspci`:

```bash
$ lspci | grep -i -e vga -e ethernet
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection I219-LM
```

A **GPU** (graphics card) may be integrated into the CPU or a discrete PCIe card; on servers GPUs are also used for computation (AI, scientific workloads).

## 6. Drivers, Kernel Modules, and the Virtual Filesystems

A **driver** is the kernel code that knows how to operate a specific device. On Linux most drivers are **kernel modules** — pieces of the kernel loaded on demand, so the kernel stays small and only loads what the hardware requires.

```bash
$ lsmod | head -4
Module                  Size  Used by
btusb                  65536  0
iwlwifi               372736  1 iwlmvm
e1000e                290816  0
```

`lsmod` lists loaded modules; administrators can load and unload them with `modprobe` (root required). `dmesg` shows kernel messages, useful to see whether a newly plugged device was detected (viewing it may require root on modern systems).

Where the kernel exposes hardware information as files:

| Location | Contents |
|---|---|
| `/dev` | Device files (block devices like `/dev/sda`, character devices like `/dev/tty1`) |
| `/proc` | Runtime kernel/process info: `/proc/cpuinfo`, `/proc/meminfo` |
| `/sys` | Structured device and driver tree used by the kernel (sysfs) |

These are **virtual filesystems**: the files exist only in memory, generated by the kernel on the fly.

## 7. Key Commands Summary

| Command | Shows |
|---|---|
| `lscpu` | CPU architecture, cores, threads, model |
| `free -h` | RAM and swap usage |
| `lsblk` | Block devices (disks) and partitions |
| `df -h` | Mounted filesystems and free space |
| `lspci` | PCI/PCIe devices |
| `lsusb` | USB devices |
| `lsmod` | Loaded kernel modules |
| `dmesg` | Kernel messages (device detection) |
| `uname -m` | Machine architecture |

## Referencias

- LPI Learning Materials, 010-160 Topic 4.2 — Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- LPI Linux Essentials exam objectives (version 1.6): https://www.lpi.org/our-certifications/exam-010-objectives/
- `lscpu(1)` and `lsblk(8)` man pages (util-linux): https://man7.org/linux/man-pages/man1/lscpu.1.html — https://man7.org/linux/man-pages/man8/lsblk.8.html
- `lspci(8)` and `lsusb(8)` man pages: https://man7.org/linux/man-pages/man8/lspci.8.html — https://man7.org/linux/man-pages/man8/lsusb.8.html
- `free(1)` man page: https://man7.org/linux/man-pages/man1/free.1.html
- The Linux Kernel documentation — sysfs: https://www.kernel.org/doc/html/latest/filesystems/sysfs.html