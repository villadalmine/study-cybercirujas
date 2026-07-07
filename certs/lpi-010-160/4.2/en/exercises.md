# Guided Exercises — Topic 4.2: Understanding Computer Hardware

**Certification:** LPI Linux Essentials (010-160, v1.6) · **Exam weight:** 2

Work through each block in a terminal. Type every command yourself — don't copy-paste — and observe the output before answering the questions. None of these commands modify your system; they only read hardware information the kernel exposes.

Reference: LPI Learning Materials, Topic 4.2 — https://learning.lpi.org/en/learning-materials/010-160/4/4.2/

---

## Exercise 1: The processor (CPU)

The CPU executes every instruction on the machine. Linux exposes detailed information about it through the `/proc` pseudo-filesystem and the `lscpu` command.

1. Ask the kernel which hardware architecture it is running on:
   ```bash
   uname -m
   ```
   Typical answers are `x86_64` (64-bit Intel/AMD) or `aarch64` (64-bit ARM, e.g. on a Raspberry Pi 4/5).
2. Get a structured summary of the processor:
   ```bash
   lscpu
   ```
   Locate these lines in the output: `Architecture`, `CPU(s)`, `Thread(s) per core`, `Core(s) per socket`, `Model name`, and the cache lines (`L1d`, `L2`, `L3`).
3. Look at the raw source of much of that information:
   ```bash
   cat /proc/cpuinfo
   ```
   Scroll through it. Notice that the whole block (`processor`, `model name`, `flags`, ...) repeats once per logical CPU.
4. Count the logical CPUs directly:
   ```bash
   grep -c '^processor' /proc/cpuinfo
   ```
5. Check whether the CPU supports 64-bit mode by searching the flags:
   ```bash
   grep -o 'lm' /proc/cpuinfo | head -1
   ```
   On x86, the `lm` flag ("long mode") means the CPU is 64-bit capable.

**Questions**

- **1a.** Your `lscpu` output says `Core(s) per socket: 4` and `Thread(s) per core: 2`. How many *logical* CPUs does Linux see on that single-socket machine, and what is the technology that makes one core appear as two threads usually called?
- **1b.** `/proc/cpuinfo` looks like an ordinary text file, but it occupies no space on disk. Where does its content actually come from?
- **1c.** What is the difference between a 32-bit and a 64-bit CPU architecture, and why does it matter which one you pick when downloading a Linux distribution image?
- **1d.** Order these from *fastest/smallest* to *slowest/largest*: RAM, L1 cache, L3 cache, CPU registers.

---

## Exercise 2: Memory (RAM) vs. swap

RAM is fast, volatile working memory: its contents disappear when the power goes off. Swap is disk space the kernel uses as an overflow area when RAM runs low.

1. Show memory usage in human-readable units:
   ```bash
   free -h
   ```
   Identify the `total`, `used`, `free`, `buff/cache`, and `available` columns, and the separate `Swap:` row.
2. Look at the kernel's own detailed accounting:
   ```bash
   head -5 /proc/meminfo
   ```
3. Find out what your system uses as swap space (a partition, a file, or possibly nothing):
   ```bash
   cat /proc/swaps
   ```
   Alternatively: `swapon --show`.
4. Run `free -h` again after opening a large application (or a few browser tabs) and compare the `available` column with the earlier reading.

**Questions**

- **2a.** After booting, `free -h` shows only a small number under `free` but a large number under `available`. Users often panic: "Linux ate my RAM!" What is the kernel actually doing with that memory, and why is `available` the column that matters?
- **2b.** Why is data in RAM lost on power-off, while data on an SSD or hard disk is not? Which single word describes this property of RAM?
- **2c.** Your laptop has 8 GiB of RAM and a 8 GiB swap partition. A program suddenly needs 10 GiB. What does the kernel do, and what do you notice about the machine's performance while it happens?
- **2d.** Is swap space a substitute for buying more RAM? Give one reason why or why not.

---

## Exercise 3: Storage devices and partitions

Mass storage keeps data permanently. Disks are divided into *partitions*, and Linux names devices with files under `/dev`.

1. List all block devices as a tree:
   ```bash
   lsblk
   ```
   Note the device names (`sda`, `nvme0n1`, `vda`, `mmcblk0`, ...), their sizes, the `TYPE` column (`disk`, `part`), and the `MOUNTPOINTS` column.
2. Look at the same devices as files:
   ```bash
   ls -l /dev/sd* /dev/nvme* 2>/dev/null
   ```
   Notice the file type letter `b` (block device) at the start of each permission string.
3. Check whether each disk is rotational (a spinning hard disk) or not (an SSD). Replace `sda` with a disk name from step 1:
   ```bash
   cat /sys/block/sda/queue/rotational
   ```
   `1` means a rotating HDD; `0` means an SSD (or other non-rotating device).
4. If you have root access, print the partition table, including its type (GPT or MBR/dos):
   ```bash
   sudo fdisk -l /dev/sda
   ```
   Look for the `Disklabel type:` line.
5. See which partitions are mounted where, and how full they are:
   ```bash
   df -h
   ```

**Questions**

- **3a.** On one machine `lsblk` shows `sda` with children `sda1` and `sda2`; on another it shows `nvme0n1` with children `nvme0n1p1` and `nvme0n1p2`. What kind of device/interface does each naming pattern indicate?
- **3b.** What is the purpose of dividing a disk into partitions? Name two things commonly placed on separate partitions of a Linux system disk.
- **3c.** Give two practical differences between an HDD and an SSD (think moving parts, speed, noise, shock resistance).
- **3d.** Name the two common partition table formats, and state one advantage the newer one has over the older one (disk size limit or number of primary partitions).
- **3e.** SATA, SAS and NVMe are all ways to attach storage. Which one connects drives directly over PCI Express, and why does that make it fast?

---

## Exercise 4: Expansion cards and the PCI bus

The motherboard ties everything together: CPU socket, RAM slots, chipset, and PCI/PCIe slots for expansion cards (graphics, network, sound, ...).

1. List every device on the PCI bus:
   ```bash
   lspci
   ```
   Read through the list and try to spot: a VGA/display controller (the GPU), a network controller (Ethernet and/or Wi-Fi), an audio device, and one or more SATA/NVMe storage controllers.
2. Narrow the list down to the graphics hardware:
   ```bash
   lspci | grep -i -e vga -e 3d -e display
   ```
3. Pick one device from the list and show more detail about it, including which kernel driver is bound to it. Replace `00:02.0` with an address from your own output:
   ```bash
   lspci -s 00:02.0 -k
   ```
   Look for the line `Kernel driver in use:`.

**Questions**

- **4a.** `lspci` shows devices even if no driver is loaded for them. Why is that useful when troubleshooting, say, a Wi-Fi card that "doesn't exist" according to the network settings?
- **4b.** In the output of `lspci -k`, what does the line `Kernel driver in use:` tell you, and what problem should you suspect when it is missing for a device?
- **4c.** Many desktop CPUs include an *integrated* GPU, while gamers add a *dedicated* GPU card. Name one advantage of each approach.

---

## Exercise 5: USB peripherals

Peripherals — keyboards, mice, webcams, printers, external drives — most commonly attach over USB, a hot-pluggable bus.

1. List the USB devices currently attached:
   ```bash
   lsusb
   ```
   Each line shows a bus number, a device number, and an `ID vendor:product` pair.
2. Watch the kernel react to hardware in real time. Start following the kernel log:
   ```bash
   sudo dmesg --follow
   ```
   (If `--follow` is unavailable, run plain `sudo dmesg` before and after the next step and compare the tail.)
3. Plug in any USB device — a memory stick or a mouse — and watch the new log lines appear. Then unplug it and watch again. Press `Ctrl+C` to stop following.
4. Run `lsusb` again and identify the line that appeared (or disappeared).

**Questions**

- **5a.** What does "hot-pluggable" mean, and how did steps 2–3 demonstrate it?
- **5b.** In `lsusb`, what do the two hexadecimal numbers in `ID 8087:0026` identify?
- **5c.** You plug in a USB flash drive and `dmesg` shows it was detected as `sdb` with one partition `sdb1`. Before you can read files from it, what must happen to `sdb1`? (One word is enough.)

---

## Exercise 6: Drivers and kernel modules

A driver is the piece of kernel code that knows how to talk to a specific device. In Linux, most drivers are loadable *kernel modules* — the kernel loads them on demand instead of carrying every driver at all times.

1. List the modules currently loaded in the kernel:
   ```bash
   lsmod | head -20
   ```
   The columns are: module name, memory size, and how many things use it (plus their names).
2. Count how many modules are loaded:
   ```bash
   lsmod | wc -l
   ```
3. Show detailed information about one common module (pick another from step 1 if this one is missing):
   ```bash
   modinfo usb_storage
   ```
   Find the `description:` and `license:` lines.
4. Explore the two pseudo-filesystems the kernel uses to expose hardware state:
   ```bash
   ls /proc | head -20
   ls /sys/class
   ```
   Note that `/sys/class` groups devices by function: `net`, `block`, `power_supply`, and so on.
5. If you are on a laptop, read the battery level straight from `/sys`:
   ```bash
   cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "No battery found"
   ```

**Questions**

- **6a.** Why does the module design load drivers *on demand* instead of building every driver permanently into the kernel? Give one benefit.
- **6b.** Tools like `lscpu`, `lsblk` and `free` do not talk to the hardware directly. Where do they get their information? Name the two pseudo-filesystems involved.
- **6c.** A brand-new Wi-Fi adapter shows up in `lspci` but has no `Kernel driver in use:` line and no interface appears. In one sentence, what is the most likely explanation?
- **6d.** What is *firmware*, and how does it differ from a driver? Where does the very first firmware run when you power on a PC (two common names for it)?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1: The processor

- **1a.** 4 cores × 2 threads = **8 logical CPUs**. The technology is **simultaneous multithreading (SMT)**, marketed by Intel as **Hyper-Threading**.
- **1b.** `/proc` is a **pseudo-filesystem**: the files are generated by the **kernel in memory, on the fly, when read**. They are a window into kernel data structures, not data stored on disk — which is why they show a size of 0.
- **1c.** The bit width describes the size of the CPU's registers and memory addresses. A 32-bit CPU can directly address only about 4 GiB of RAM, while a 64-bit CPU can address vastly more and can run both 64-bit and (usually) 32-bit programs. You must download an image matching your architecture: a 64-bit (`x86_64`) image will not boot on a 32-bit-only CPU, and an ARM image will not run on an Intel/AMD PC.
- **1d.** Fastest/smallest → slowest/largest: **CPU registers → L1 cache → L3 cache → RAM**. Each level trades speed for capacity.

### Exercise 2: Memory vs. swap

- **2a.** Linux uses otherwise-idle RAM as **disk cache** (`buff/cache`), which speeds up file access. That memory is reclaimed instantly when applications need it, so **`available`** — an estimate of memory obtainable without swapping — is the realistic "free memory" figure, not `free`.
- **2b.** RAM is **volatile**: it needs constant power to retain data, so its contents vanish at power-off. SSDs (flash) and HDDs (magnetic platters) are **persistent/non-volatile** storage.
- **2c.** The kernel starts **swapping**: it moves less-used memory pages from RAM to the swap partition to free RAM for the demanding program. Because disk is orders of magnitude slower than RAM, the machine becomes noticeably sluggish ("thrashing" in extreme cases).
- **2d.** No. Swap is a **safety overflow**, not a performance substitute — even an NVMe SSD is far slower than RAM, so a system that constantly relies on swap will crawl. (Swap remains useful for hibernation and for absorbing rare memory spikes.)

### Exercise 3: Storage and partitions

- **3a.** `sdX` names come from the **SCSI disk driver**, used today for **SATA, SAS and USB** drives. `nvme0n1` (with partitions `p1`, `p2`, ...) indicates an **NVMe SSD attached via PCI Express**.
- **3b.** Partitions divide one physical disk into independent sections so different data can be isolated and managed separately. Common examples on a Linux disk: the **EFI system partition (`/boot/efi`)**, the **root filesystem (`/`)**, a **swap partition**, and often a separate **`/home`**.
- **3c.** An HDD has **spinning magnetic platters and a moving read/write head**: cheaper per gigabyte but slower (especially for random access), noisier, and vulnerable to shocks. An SSD has **no moving parts** (flash memory): much faster, silent, more shock-resistant, and lighter, but historically more expensive per gigabyte.
- **3d.** **MBR** (msdos) and **GPT**. GPT supports disks **larger than 2 TiB** and allows **many partitions** (typically 128) instead of MBR's limit of 4 primary partitions; it also keeps a backup copy of the partition table.
- **3e.** **NVMe** connects flash storage directly over **PCI Express**, skipping the older SATA controller path and its ~600 MB/s ceiling, so it achieves much higher throughput and lower latency.

### Exercise 4: PCI devices

- **4a.** `lspci` reads what the hardware itself reports on the bus, independent of drivers. If the card appears in `lspci` but not in the network settings, the hardware is present and detected — so the problem is almost certainly a **missing/unloaded driver or firmware**, not a dead or unseated card.
- **4b.** It names the **kernel module currently bound to and operating that device**. If the line is absent, no driver has claimed the device — expect it to be non-functional until the right module (and possibly firmware) is installed or loaded.
- **4c.** Integrated GPU: cheaper, lower power consumption, less heat — fine for desktop/office use. Dedicated GPU: its own processor and video RAM, so far higher performance for gaming, video editing, or GPU computing.

### Exercise 5: USB peripherals

- **5a.** Hot-pluggable means devices can be **connected and disconnected while the system is running**, with the kernel detecting the change immediately. The live `dmesg --follow` output showed the kernel enumerating the device at plug-in and releasing it at unplug — no reboot involved.
- **5b.** The **vendor ID** (`8087` = Intel) and the **product ID** (`0026`, a specific device model). Together they let the kernel pick the correct driver.
- **5c.** It must be **mounted** — attached to a directory in the filesystem tree (on desktops this usually happens automatically).

### Exercise 6: Drivers and kernel modules

- **6a.** Loading on demand keeps the running kernel **small and efficient**: only drivers for hardware actually present consume memory, new hardware can be supported by loading a module **without rebooting**, and a buggy module can often be unloaded rather than taking the whole kernel down.
- **6b.** From the kernel's pseudo-filesystems: **`/proc`** (process and general system info, e.g. `/proc/cpuinfo`, `/proc/meminfo`) and **`/sys`** (the sysfs device tree, e.g. `/sys/block`, `/sys/class`). Both are generated in memory by the kernel.
- **6c.** The kernel sees the hardware but has **no driver (or required firmware) for it yet** — you need to install or load the appropriate kernel module/firmware package.
- **6d.** Firmware is software **stored on or loaded into the device itself** that controls its internal operation; a driver is **kernel code on the host** that communicates with the device. The first firmware to run at power-on lives on the motherboard: the **BIOS**, or on modern machines its successor **UEFI**; it initializes the hardware and starts the boot loader.

</details>

---

*Source consulted: LPI Learning Materials for exam 010-160, Topic 4.2 — https://learning.lpi.org/en/learning-materials/010-160/4/4.2/*