# 4.2 理解计算机硬件 (Understanding Computer Hardware)

## 概述

本主题考察对 PC 硬件基本组成的理解，以及在 Linux 系统中如何识别、查看这些硬件资源的相关工具。作为 System Administrator，即使不亲自组装硬件，也需要能够通过 command line 判断服务器或工作站的 CPU、memory、storage、PCI/USB 设备等信息，以便进行故障排查（troubleshooting）和容量规划。

---

## 1. PC 硬件的基本组成 (Form Factors)

常见的计算机 form factor（外形规格）包括：

- **Desktop**：传统台式机，ATX/Micro-ATX 主板，扩展性强。
- **Laptop**：便携式，硬件高度集成，电池供电。
- **Server**：机架式（rack-mounted）或塔式（tower），强调冗余（redundancy）和可靠性，常配备热插拔（hot-swap）硬盘和冗余电源。
- **Embedded / SoC (System on Chip)**：将 CPU、GPU、内存控制器等集成在同一块芯片上，常见于路由器、IoT 设备、树莓派（Raspberry Pi）等。
- **虚拟机 (Virtual Machine)** 与 **云实例 (Cloud Instance)**：硬件由 hypervisor（如 KVM、VMware）虚拟化，操作系统看到的是虚拟硬件（virtual hardware），而非物理硬件。

### 主要硬件部件

| 部件 | 作用 |
|---|---|
| Motherboard（主板） | 连接所有部件的电路板，包含 chipset、总线（bus）、扩展槽 |
| CPU（中央处理器） | 执行指令，核心运算单元 |
| RAM（内存） | 易失性存储，程序运行时的临时数据存放处 |
| Storage（存储设备） | HDD、SSD、NVMe，持久化数据存储 |
| PSU（电源） | 将市电转换为主板/部件所需的直流电压 |
| GPU（图形处理器） | 图形渲染，也可用于并行计算（如 machine learning） |
| USB Controller | 管理 USB 设备的即插即用（hot-plug） |

---

## 2. CPU 与内存层次结构 (Memory Hierarchy)

CPU 通过 **cache（缓存）** 分级来弥补 RAM 访问速度较慢的问题，典型层次从快到慢：

```
CPU Registers → L1 Cache → L2 Cache → L3 Cache → RAM → Disk (SSD/HDD)
```

越靠近 CPU 的存储器速度越快、容量越小、成本越高。

查看 CPU 信息可以使用 `lscpu` 命令：

```bash
$ lscpu
Architecture:            x86_64
CPU(s):                   8
On-line CPU(s) list:      0-7
Vendor ID:                GenuineIntel
Model name:               Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz
CPU MHz:                  3000.000
L1d cache:                256 KiB
L2 cache:                 2 MiB
L3 cache:                 12 MiB
```

也可以直接查看 `/proc/cpuinfo`：

```bash
$ cat /proc/cpuinfo | grep "model name" | head -1
model name : Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz
```

查看内存使用情况用 `free`：

```bash
$ free -h
              total        used        free      shared  buff/cache   available
Mem:           15Gi       3.2Gi       8.1Gi       256Mi       4.0Gi       11Gi
Swap:         2.0Gi          0B       2.0Gi
```

也可以直接查看 `/proc/meminfo` 获取更详细的数据。

---

## 3. 存储设备与分区

常见存储介质：

- **HDD (Hard Disk Drive)**：机械硬盘，通过磁头读写旋转磁盘。
- **SSD (Solid State Drive)**：基于闪存（flash memory），无机械部件，速度更快。
- **NVMe (Non-Volatile Memory Express)**：通过 PCIe 总线连接的高速 SSD 协议。

查看已识别的 block device（块设备）：

```bash
$ lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda           8:0    0 238.5G  0 disk
├─sda1        8:1    0   512M  0 part /boot/efi
└─sda2        8:2    0   238G  0 part /
nvme0n1     259:0    0 476.9G  0 disk
└─nvme0n1p1 259:1    0 476.9G  0 part /home
```

`lsblk` 显示设备名称（如 `sda`、`nvme0n1`）、大小、类型（disk/part）以及挂载点（mount point）。

---

## 4. 主板与启动过程 (Boot Process)

启动过程简要流程：

1. **PSU** 通电，主板开始供电。
2. **Firmware（固件）**：传统 **BIOS (Basic Input/Output System)** 或现代 **UEFI (Unified Extensible Firmware Interface)** 初始化硬件。
3. **POST (Power-On Self-Test)**：固件对硬件进行自检（CPU、RAM、显卡等）。
4. Firmware 根据 boot order（启动顺序）寻找 bootloader（如 GRUB）。
5. Bootloader 加载 Linux kernel 到内存并执行。
6. Kernel 初始化驱动，挂载根文件系统，启动 `init`/`systemd` 进程。

BIOS 与 UEFI 的主要区别：

| 特性 | BIOS | UEFI |
|---|---|---|
| 分区表支持 | MBR | GPT（也支持 MBR） |
| 启动速度 | 较慢 | 较快 |
| 图形界面 | 无（纯文本） | 支持鼠标、图形界面 |
| Secure Boot | 不支持 | 支持 |

---

## 5. 扩展总线与外设：PCI 与 USB

### PCI (Peripheral Component Interconnect)

主板上的扩展总线，用于连接显卡、网卡等设备。使用 `lspci` 查看：

```bash
$ lspci
00:00.0 Host bridge: Intel Corporation 8th Gen Core Processor
00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 630
02:00.0 Ethernet controller: Realtek Semiconductor Co., Ltd. RTL8111
03:00.0 Non-Volatile memory controller: Samsung Electronics Co Ltd NVMe SSD
```

添加 `-v` 参数可查看更详细信息（如 IRQ、内存地址范围）：

```bash
$ lspci -v
```

### USB (Universal Serial Bus)

支持 **hot-pluggable（热插拔）**，即设备可以在系统运行时插入或拔出而无需重启。使用 `lsusb` 查看已连接的 USB 设备：

```bash
$ lsusb
Bus 001 Device 002: ID 8087:0aaa Intel Corp. Bluetooth
Bus 002 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 003 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
```

当插入 USB 设备时，可以通过 `dmesg` 实时查看内核识别设备的日志：

```bash
$ dmesg | tail -5
[12345.678901] usb 2-1: new high-speed USB device number 5 using xhci_hcd
[12345.789012] usb 2-1: New USB device found, idVendor=0781, idProduct=5567
[12345.790000] sd 6:0:0:0: [sdb] Attached SCSI removable disk
```

---

## 6. SoC、嵌入式系统与 IoT

**SoC (System on Chip)** 将 CPU、GPU、内存控制器、I/O 接口集成到单一芯片，广泛用于：

- 智能手机
- Raspberry Pi 等开发板
- IoT (Internet of Things) 设备，如智能传感器、智能家居网关

嵌入式系统通常资源受限（低功耗、低内存），常运行精简版 Linux（如 Buildroot、Yocto 构建的系统）。

---

## 7. GPU 与并行计算

**GPU (Graphics Processing Unit)** 除了图形渲染外，也常用于通用计算（**GPGPU**），例如 machine learning 训练、科学计算。相较 CPU 少量强大的核心，GPU 拥有大量简单核心，擅长大规模并行运算。

查看显卡信息（NVIDIA 显卡示例）：

```bash
$ nvidia-smi
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 535.104.05   Driver Version: 535.104.05   CUDA Version: 12.2     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf  Pwr:Usage/Cap|         Memory-Usage | GPU-Util  Compute M. |
|===============================+======================+======================|
|   0  NVIDIA GeForce RTX 3060  |   00000000:01:00.0  On|                  N/A |
+-----------------------------------------------------------------------------+
```

---

## 8. 硬件信息汇总：/proc 与 /sys

Linux 将大量硬件与内核运行时信息以虚拟文件系统（virtual filesystem）形式暴露：

- `/proc`：进程与内核运行状态信息，如 `/proc/cpuinfo`、`/proc/meminfo`、`/proc/interrupts`。
- `/sys`：设备与驱动模型信息（device driver model），如 `/sys/class/net/`、`/sys/block/`。

```bash
$ cat /proc/interrupts | head -3
           CPU0       CPU1
  0:         34          0   IO-APIC   2-edge      timer
  1:        120          5   IO-APIC   1-edge      i8042
```

还可以使用 `dmidecode` 读取主板 BIOS/UEFI 提供的硬件信息（DMI/SMBIOS 数据），例如查看内存插槽信息：

```bash
$ sudo dmidecode -t memory | grep -A2 "Memory Device"
Memory Device
	Size: 8192 MB
	Type: DDR4
	Speed: 3200 MT/s
```

---

## 9. 虚拟化与云环境中的硬件

在 **cloud/virtual machine** 环境中，操作系统看到的往往是 hypervisor 提供的 **virtual hardware**（虚拟硬件），而非物理硬件本身。例如：

```bash
$ lscpu | grep Hypervisor
Hypervisor vendor:   KVM
Virtualization type: full
```

在虚拟机中，`lspci` 可能会显示类似 `Virtio` 的虚拟设备，而非真实物理网卡/显卡型号，这是判断是否运行在虚拟化环境的一个常见线索。

---

## 常见考点提示

- 区分 **RAM（易失性）** 与 **storage（持久化）**。
- 记住常用命令与其用途：`lspci`（PCI 设备）、`lsusb`（USB 设备）、`lsblk`（块设备）、`lscpu`（CPU）、`free`（内存）、`dmidecode`（DMI/BIOS 硬件信息）、`dmesg`（内核日志，含硬件识别记录）。
- 理解 **hot-pluggable** 概念：USB、部分 SATA/NVMe 硬盘支持热插拔，而传统 IDE 硬盘、内存、CPU 通常不支持。
- 了解 BIOS 与 UEFI 的区别，尤其是 GPT vs MBR、Secure Boot。

---

## Referencias

- LPI Learning Materials — 4.2 Understanding Computer Hardware: https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
- `lspci(8)` man page: https://man7.org/linux/man-pages/man8/lspci.8.html
- `lsusb(8)` man page: https://man7.org/linux/man-pages/man8/lsusb.8.html
- `lsblk(8)` man page: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `lscpu(1)` man page: https://man7.org/linux/man-pages/man1/lscpu.1.html
- `dmidecode(8)` man page: https://man7.org/linux/man-pages/man8/dmidecode.8.html
- `free(1)` man page: https://man7.org/linux/man-pages/man1/free.1.html
- Linux Kernel `/proc` filesystem documentation: https://www.kernel.org/doc/html/latest/filesystems/proc.html