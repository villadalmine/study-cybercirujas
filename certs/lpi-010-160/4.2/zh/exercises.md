# 4.2 理解计算机硬件（Understanding Computer Hardware）— 引导式练习

> 参考来源：https://learning.lpi.org/en/learning-materials/010-160/4/4.2/
> 以下内容为原创讲解和练习设计，仅将上述资料作为主题范围参考。

---

## 练习 1：查看 CPU 信息

1. 打开终端，执行以下命令，查看格式化后的 CPU 摘要信息：
   ```bash
   lscpu
   ```
2. 再执行以下命令，查看内核直接暴露的原始 CPU 信息：
   ```bash
   cat /proc/cpuinfo
   ```
3. 使用 `grep` 过滤出 CPU 的型号名称（model name）和核心数量（core 相关字段）：
   ```bash
   grep "model name" /proc/cpuinfo
   grep -c "^processor" /proc/cpuinfo
   ```

**思考题：**
- `lscpu` 命令输出的信息和 `/proc/cpuinfo` 的内容来源是否相同？两者之间是什么关系？
- 如果一台机器有 4 个物理核心并开启了超线程（hyper-threading），`grep -c "^processor"` 的结果大概率会是多少？为什么？

---

## 练习 2：查看内存（RAM）使用情况

1. 执行以下命令，以人类可读的方式查看内存和 swap 空间的使用情况：
   ```bash
   free -h
   ```
2. 查看内核提供的原始内存信息文件：
   ```bash
   cat /proc/meminfo
   ```
3. 对比 `free -h` 输出中的 `available` 列和 `/proc/meminfo` 中的 `MemAvailable` 字段。

**思考题：**
- `free -h` 输出中的 `buff/cache` 列代表什么？为什么它通常不能简单地算作"已占用且不可用"的内存？
- `total`、`used`、`free`、`available` 这几列分别回答了什么问题？

---

## 练习 3：列出 PCI 设备

1. 执行以下命令，列出系统上所有的 PCI 设备（如显卡、网卡、控制器等）：
   ```bash
   lspci
   ```
2. 加上 `-v` 参数，查看每个设备的详细信息（包括所使用的 kernel driver）：
   ```bash
   lspci -v | less
   ```
3. 只筛选出显卡（VGA compatible controller）相关的设备：
   ```bash
   lspci | grep -i vga
   ```

**思考题：**
- `lspci` 显示的设备地址（例如 `00:1f.2`）中，各部分分别代表什么（bus、device、function）？
- 为什么在排查硬件驱动问题时，`lspci -v` 中的 `Kernel driver in use` 字段很有用？

---

## 练习 4：列出 USB 设备

1. 插入一个 USB 设备（如 U 盘或鼠标），然后执行：
   ```bash
   lsusb
   ```
2. 加上 `-v` 参数查看某个设备的详细描述符信息（可能需要 root 权限）：
   ```bash
   sudo lsusb -v -d <vendor>:<product>
   ```
3. 拔出该设备后重新执行 `lsusb`，对比输出的变化。

**思考题：**
- `lsusb` 输出中的 `ID xxxx:yyyy` 分别代表什么？
- 如果一个 USB 设备插入后没有出现在 `lsusb` 的输出中，你会怀疑是硬件层面还是驱动/内核层面的问题？为什么？

---

## 练习 5：查看存储设备与分区

1. 列出系统上所有的块设备（block device）及其分区结构：
   ```bash
   lsblk
   ```
2. 加上 `-f` 参数，查看每个分区的文件系统类型和挂载点：
   ```bash
   lsblk -f
   ```
3. 查看磁盘的详细分区表信息（需要 root 权限）：
   ```bash
   sudo fdisk -l
   ```
4. 对比一块传统机械硬盘（HDD）、固态硬盘（SSD）与 NVMe 设备在 `lsblk` 输出中设备名前缀的不同（例如 `/dev/sda` 与 `/dev/nvme0n1`）。

**思考题：**
- `lsblk` 输出中的树状缩进表示的是什么关系？
- 为什么 NVMe 设备的命名方式（`nvme0n1p1` 等）和传统 SATA 磁盘（`sda1` 等）不同？这与它们的连接总线有什么关系？

---

## 练习 6：查看硬件中断（IRQ）与 I/O 资源

1. 查看当前系统中各硬件设备使用的中断请求号（IRQ）：
   ```bash
   cat /proc/interrupts
   ```
2. 查看系统分配的 I/O 端口地址：
   ```bash
   cat /proc/ioports
   ```
3. 查看 DMA（Direct Memory Access）通道的分配情况：
   ```bash
   cat /proc/dma
   ```

**思考题：**
- 为什么现代 Linux 系统中很少再出现"设备之间抢占同一个 IRQ 导致冲突"的问题（提示：想想 PCI 与旧式 ISA 总线在中断处理机制上的差异）？
- `/proc/dma` 在一台没有软盘驱动器、且主要使用 PCIe/NVMe 存储的现代机器上，通常输出内容会很少甚至为空，为什么？

---

## 练习 7：通过内核日志确认硬件识别情况

1. 查看系统启动时内核检测硬件设备产生的日志：
   ```bash
   dmesg | less
   ```
2. 插入一个新的 USB 设备，然后立刻查看最新的内核日志：
   ```bash
   dmesg | tail -n 20
   ```
3. 使用 `grep` 过滤出与某个关键字（例如 `usb` 或 `sda`）相关的日志行：
   ```bash
   dmesg | grep -i usb
   ```

**思考题：**
- 当一个硬件设备物理连接正常，但操作系统似乎"没有反应"时，`dmesg` 能帮你判断问题出在硬件本身还是内核驱动层面吗？举例说明。
- `dmesg` 的输出和 `/var/log/kern.log`（或对应发行版的日志文件）之间有什么关系？

---

## 练习 8：查看主板与 BIOS/UEFI 固件信息

1. 使用 `dmidecode` 查看主板（motherboard）制造商和型号信息（需要 root 权限）：
   ```bash
   sudo dmidecode -t baseboard
   ```
2. 查看 BIOS/UEFI 固件版本信息：
   ```bash
   sudo dmidecode -t bios
   ```
3. 查看系统内核和硬件架构信息：
   ```bash
   uname -m
   uname -a
   ```

**思考题：**
- `uname -m` 返回的 `x86_64`、`aarch64` 等字符串代表什么？它和"系统安装的是 32 位还是 64 位操作系统"是同一个概念吗？
- 为什么读取 `dmidecode` 的输出通常需要 root 权限，而 `lscpu`、`lsblk` 这类命令一般不需要？

---

<details>
<summary><strong>点击展开参考答案</strong></summary>

**练习 1**
- `lscpu` 本质上是对 `/proc/cpuinfo`（以及部分 sysfs 中的信息）做了解析和汇总，以更易读的格式呈现；底层数据来源基本一致，`lscpu` 更适合快速查看摘要，`/proc/cpuinfo` 则会为每一个逻辑 CPU（logical processor）单独列出一条完整记录。
- 4 个物理核心开启超线程后，每个物理核心会呈现为 2 个逻辑处理器（logical processor），所以 `grep -c "^processor"` 大概率会返回 8。

**练习 2**
- `buff/cache` 是内核用于文件系统缓存（page cache）和缓冲区（buffers）的内存。这部分内存在需要时可以被内核迅速回收并分配给应用程序，因此不应被当作"不可用"的内存，这也是 `free` 单独提供 `available` 列的原因。
- `total` 表示物理内存总量；`used` 表示当前被进程实际占用的内存；`free` 表示完全未被使用的内存；`available` 是一个估算值，表示在不引起 swap 的前提下，新启动的应用程序大致还能使用多少内存（包含可回收的 buff/cache）。

**练习 3**
- PCI 设备地址格式一般为 `bus:device.function`，例如 `00:1f.2` 表示 bus 00、device 1f、function 2；一个物理插槽（device）上可能存在多个 function（多功能设备）。
- `Kernel driver in use` 直接告诉你当前该硬件正在被哪个内核模块驱动，如果这一字段为空或显示的驱动不是预期的驱动，通常就是硬件未被正确识别或驱动未加载/不匹配的信号。

**练习 4**
- `ID xxxx:yyyy` 中前四位是厂商 ID（vendor ID），后四位是产品 ID（product ID），共同唯一标识一款 USB 设备型号（不是序列号，同型号的不同设备该 ID 相同）。
- 如果设备插入后完全没有出现在 `lsusb` 输出中，问题更可能出在硬件层面（如物理连接、USB 控制器、线缆），因为 `lsusb` 读取的是 USB 总线枚举（enumeration）阶段的信息，这一步发生在具体设备驱动加载之前；如果设备出现在 `lsusb` 中但功能不正常（例如鼠标无法移动光标），则更可能是驱动或内核模块层面的问题。

**练习 5**
- 树状缩进表示磁盘（disk）与其分区（partition）之间的从属关系，例如 `sda` 下缩进的 `sda1`、`sda2` 表示这两个分区都位于 `sda` 这块物理磁盘上。
- SATA 磁盘通过 AHCI/SCSI 子系统识别，命名为 `sdX`；NVMe 设备直接通过 PCIe 总线与 NVMe 协议通信，不经过传统的 SCSI 层，因此使用独立的命名空间（namespace）风格命名，如 `nvme0n1`（控制器 0、命名空间 1）、`nvme0n1p1`（该命名空间上的分区 1）。

**练习 6**
- 现代硬件普遍使用 PCI/PCIe 总线提供的中断机制（如 MSI/MSI-X，Message Signaled Interrupts），每个设备可以获得独立的中断向量，不再需要像旧式 ISA 总线那样共享有限数量的物理 IRQ 线，因此冲突大大减少。
- 现代机器已不再配备软盘控制器（floppy disk controller），且主流存储和外设都通过 PCIe/USB 而非传统 ISA DMA 通道传输数据，因此传统意义上的 8237 DMA 控制器基本闲置，`/proc/dma` 里几乎没有条目。

**练习 7**
- 可以。如果设备在 `dmesg` 中完全没有留下任何记录（既没有识别为某个 USB 设备，也没有报错），问题更可能出在硬件/物理连接层面；如果 `dmesg` 中出现了设备被识别的日志，但随后报出驱动加载失败或某个子系统报错，则问题出在内核驱动层面。
- `dmesg` 直接读取的是内核环形缓冲区（kernel ring buffer）中的实时日志，是易失性的（重启后清空）；而 `/var/log/kern.log` 这类文件通常是由日志服务（如 `rsyslog`、`journald`）持久化保存的内核日志副本，二者内容来源相同，但保存方式和生命周期不同。

**练习 8**
- `uname -m` 返回的是内核/硬件的指令集架构（instruction set architecture），如 `x86_64` 表示 CPU 支持 64 位 x86 指令集。这和"当前安装的操作系统是 32 位还是 64 位"并不完全等价：一台 64 位架构（`x86_64`）的机器完全可以安装 32 位的操作系统，此时 `uname -m` 在该系统下可能显示为 `i686`。
- `dmidecode` 读取的是主板厂商写入的 SMBIOS/DMI 固件数据表，这类底层固件信息被系统视为相对敏感（例如可能包含序列号等信息），因此默认需要 root 权限读取；而 `lscpu`、`lsblk` 主要读取的是内核在 `/proc`、`/sys` 下已经处理并对普通用户开放只读权限的信息，不涉及直接访问底层固件数据。

</details>