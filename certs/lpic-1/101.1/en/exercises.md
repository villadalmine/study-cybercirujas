# 101.1 — Determine and Configure Hardware Settings
## Guided Exercises (LPIC-1, exam 101-500, syllabus v5.0 — weight 3.13)

**Source of the objective:** <https://www.lpi.org/our-certifications/exam-101-objectives/>

---

### Lab environment and safety notes

These exercises are written for a **disposable Linux machine** — a VM or a spare laptop. Several steps write into `sysfs` and will *deliberately disable a device*. Do not run them on a workstation you depend on, and never run the peripheral-disabling steps over an SSH session that traverses the NIC you are about to unbind.

Install the tooling first:

```bash
# Debian / Ubuntu
sudo apt install pciutils usbutils util-linux hdparm smartmontools lsscsi \
                 nvme-cli dmidecode lshw kmod

# RHEL / Fedora / openSUSE
sudo dnf install pciutils usbutils util-linux hdparm smartmontools lsscsi \
                 nvme-cli dmidecode lshw kmod
```

You will need: one USB device you can physically unplug (a flash drive or a mouse), and `root` via `sudo`.

**Every output shown below is an example.** Hardware differs; the *shape* of the output and the file you read it from are what the exam tests, not the specific IDs.

---

## Exercise 1 — Enumerate the PCI bus and map devices to drivers

The PCI (and PCI Express) bus is where the integrated peripherals of a machine live: the SATA controller, the USB host controllers, the NIC, the GPU, the audio codec. `lspci` is a formatter over `/sys/bus/pci/`.

**Step 1.** List every PCI function on the machine:

```bash
lspci
```

```
00:00.0 Host bridge: Intel Corporation Xeon E3-1200 v6/7th Gen Core Processor Host Bridge/DRAM Registers (rev 02)
00:02.0 VGA compatible controller: Intel Corporation HD Graphics 620 (rev 02)
00:14.0 USB controller: Intel Corporation Sunrise Point-LP USB 3.0 xHCI Controller (rev 21)
00:17.0 SATA controller: Intel Corporation Sunrise Point-LP SATA Controller [AHCI mode] (rev 21)
00:1f.3 Audio device: Intel Corporation Sunrise Point-LP HD Audio (rev 21)
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection (2) I219-V (rev 21)
02:00.0 Non-Volatile memory controller: Samsung Electronics Co Ltd NVMe SSD Controller SM981/PM981/PM983
```

**Step 2.** The left-hand column is the PCI address. Ask for the full form, which includes the domain:

```bash
lspci -D | head -3
```

```
0000:00:00.0 Host bridge: Intel Corporation ...
0000:00:02.0 VGA compatible controller: Intel Corporation ...
0000:00:14.0 USB controller: Intel Corporation ...
```

The format is `domain:bus:device.function` — `0000:00:14.0` is domain 0, bus 0, device `0x14`, function 0.

**Step 3.** Add the numeric vendor and device IDs, plus the driver bound to each function:

```bash
lspci -nnk -s 00:1f.6
```

```
00:1f.6 Ethernet controller [0200]: Intel Corporation Ethernet Connection (2) I219-V [8086:15b8] (rev 21)
	Subsystem: Dell Ethernet Connection (2) I219-V [1028:07a0]
	Kernel driver in use: e1000e
	Kernel modules: e1000e
```

`[0200]` is the PCI *class* code (02 = network controller, 00 = ethernet). `[8086:15b8]` is `vendor:device`. `8086` is Intel — the numbers are the truth on the wire; the human-readable strings come from a local database.

**Step 4.** Find that database and note that it can go stale:

```bash
ls -l /usr/share/hwdata/pci.ids 2>/dev/null || ls -l /usr/share/misc/pci.ids
# sudo update-pciids      # downloads a fresh copy from pci-ids.ucw.cz
```

**Step 5.** Show the bus topology as a tree, then the verbose view of a single function:

```bash
lspci -t
sudo lspci -vv -s 00:1f.6 | head -25
```

```
-[0000:00]-+-00.0
           +-02.0
           +-14.0
           +-17.0
           +-1f.3
           +-1f.6
           \-1c.0-[02]----00.0
```

```
00:1f.6 Ethernet controller: Intel Corporation Ethernet Connection (2) I219-V (rev 21)
	Subsystem: Dell Ethernet Connection (2) I219-V
	Control: I/O+ Mem+ BusMaster+ SpecCycle- MemWINV- VGASnoop- ParErr- Stepping- SERR- FastB2B- DisINTx+
	Status: Cap+ 66MHz- UDF- FastB2B- ParErr- DEVSEL=fast >TAbort- <TAbort- <MAbort- >SERR- <PERR- INTx-
	Latency: 0
	Interrupt: pin A routed to IRQ 130
	Region 0: Memory at df200000 (32-bit, non-prefetchable) [size=128K]
	Capabilities: [c8] Power Management version 3
	Capabilities: [d0] MSI: Enable+ Count=1/1 Maskable- 64bit+
	Kernel driver in use: e1000e
```

Run the same command **without** `sudo` and compare — you will see `Capabilities: <access denied>`. Reading PCI configuration space beyond the first 64 bytes requires privilege.

**Step 6.** Everything `lspci` printed came from `sysfs`. Read it raw:

```bash
cd /sys/bus/pci/devices/0000:00:1f.6
cat vendor device class irq
ls -l driver
cat resource | head -3
```

```
0x8086
0x15b8
0x020000
130
lrwxrwxrwx 1 root root 0 Aug 25 10:12 driver -> ../../../../bus/pci/drivers/e1000e
0x00000000df200000 0x00000000df21ffff 0x0000000000040200
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x0000000000000000 0x0000000000000000 0x0000000000000000
```

Each line of `resource` is `start end flags` for one BAR (Base Address Register); all-zero lines are unused BARs.

> ### Check your understanding — Exercise 1
>
> **Q1.** In `0000:00:1f.6`, what does each of the four fields mean, and why does a single physical chip sometimes occupy `1f.3` *and* `1f.6`?
>
> **Q2.** `lspci -nn` prints `[8086:15b8]`. Which number identifies the manufacturer, and where did the string "Intel Corporation" come from?
>
> **Q3.** You run `lspci -vv` as a normal user and see `Capabilities: <access denied>`. What exactly is being denied, and what is the fix?
>
> **Q4.** A device appears in `lspci` but the machine cannot use it. Which single line of `lspci -k` output tells you why, and what would that line look like in the failure case?
>
> **Q5.** Without running `lspci`, which file under `/sys/bus/pci/devices/<addr>/` gives you the interrupt line assigned to the device?

---

## Exercise 2 — The USB stack: topology, speeds and device manipulation

**Step 1.** List attached USB devices:

```bash
lsusb
```

```
Bus 002 Device 002: ID 0781:5567 SanDisk Corp. Cruzer Blade
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 001 Device 003: ID 046d:c52b Logitech, Inc. Unifying Receiver
Bus 001 Device 002: ID 8087:0a2b Intel Corp. Bluetooth wireless interface
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
```

Note the `1d6b:000x` entries: those are **virtual root hubs** exported by the kernel, one per host-controller bus, not physical hardware. `1d6b:0002` = USB 2.0 bus, `1d6b:0003` = USB 3.x bus.

**Step 2.** Show the physical topology, the driver bound to each interface, and the negotiated speed:

```bash
lsusb -t
```

```
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 002: Dev 002, If 0, Class=Mass Storage, Driver=usb-storage, 5000M
/:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/12p, 480M
    |__ Port 003: Dev 002, If 0, Class=Wireless, Driver=btusb, 12M
    |__ Port 003: Dev 002, If 1, Class=Wireless, Driver=btusb, 12M
    |__ Port 005: Dev 003, If 0, Class=Human Interface Device, Driver=usbhid, 12M
    |__ Port 005: Dev 003, If 1, Class=Human Interface Device, Driver=usbhid, 12M
```

The trailing number is the signalling rate: `1.5M` low-speed, `12M` full-speed, `480M` high-speed, `5000M` SuperSpeed, `10000M` SuperSpeed+.

**Step 3.** Dump the descriptors of one device. Restrict the dump — a full `lsusb -v` is thousands of lines:

```bash
sudo lsusb -v -d 0781:5567 | head -30
```

```
Bus 002 Device 002: ID 0781:5567 SanDisk Corp. Cruzer Blade
Device Descriptor:
  bLength                18
  bDescriptorType         1
  bcdUSB               3.00
  bDeviceClass            0
  bMaxPacketSize0         9
  idVendor           0x0781 SanDisk Corp.
  idProduct          0x5567 Cruzer Blade
  iSerial                 3 4C530001120830115202
  bNumConfigurations      1
  Configuration Descriptor:
    bmAttributes         0x80
      (Bus Powered)
    MaxPower              224mA
```

**Step 4.** Find the same device in `sysfs` and read the attributes directly:

```bash
grep -l 5567 /sys/bus/usb/devices/*/idProduct
```

```
/sys/bus/usb/devices/2-2/idProduct
```

```bash
cd /sys/bus/usb/devices/2-2
cat idVendor idProduct manufacturer product serial speed bMaxPower
```

```
0781
5567
SanDisk
Cruzer Blade
4C530001120830115202
5000
224mA
```

The directory name `2-2` is `bus-port`. A device behind an external hub gets a dotted path: `1-1.3` means bus 1, root port 1, hub port 3.

**Step 5.** Watch hot-plug in real time. In one terminal:

```bash
sudo udevadm monitor --kernel --udev
```

In another, unplug and replug the USB device. You will see paired `KERNEL[...]` and `UDEV[...]` lines for the same event, several hundred microseconds apart.

**Step 6.** Disable a USB device *in software*, without unplugging it:

```bash
echo 0 | sudo tee /sys/bus/usb/devices/2-2/authorized
lsusb -t          # the device is gone from the tree
echo 1 | sudo tee /sys/bus/usb/devices/2-2/authorized
```

The same switch exists per host controller as a default for newly attached devices:

```bash
cat /sys/bus/usb/devices/usb2/authorized_default
```

**Step 7.** Inspect the power-management policy that causes "my USB device disappears when idle":

```bash
cat /sys/bus/usb/devices/2-2/power/control            # auto | on
cat /sys/bus/usb/devices/2-2/power/autosuspend_delay_ms
echo on | sudo tee /sys/bus/usb/devices/2-2/power/control
```

> ### Check your understanding — Exercise 2
>
> **Q6.** `lsusb` lists `1d6b:0002 Linux Foundation 2.0 root hub`. Is there a chip on the motherboard with that ID? Explain.
>
> **Q7.** A USB 3.0 flash drive shows `480M` in `lsusb -t`. Give two plausible physical causes.
>
> **Q8.** In `lsusb -t`, one device shows two lines with `If 0` and `If 1` and the same `Dev` number. What does that mean, and what is the consequence for driver binding?
>
> **Q9.** Translate the sysfs path `/sys/bus/usb/devices/1-4.2.1` into plain English.
>
> **Q10.** You write `0` to a device's `authorized` file. From the point of view of the electrical bus and of the kernel, what changed, and what did *not* change?

---

## Exercise 3 — Kernel modules: the binding between hardware and driver

**Step 1.** List the loaded modules and identify the source of the data:

```bash
lsmod | head -8
head -3 /proc/modules
```

```
Module                  Size  Used by
nvme_core             172032  5 nvme
usb_storage            81920  1 uas
e1000e                311296  0
snd_hda_intel          61440  3
xhci_pci               24576  0
xhci_hcd              352256  1 xhci_pci
```

```
nvme_core 172032 5 nvme, Live 0xffffffffc0a41000
usb_storage 81920 1 uas, Live 0xffffffffc08d2000
e1000e 311296 0 - Live 0xffffffffc0b12000
```

`lsmod` is a formatter over `/proc/modules`. Column 3 is the **use count**, column 4 the modules that depend on it. A module with a non-zero use count cannot be removed.

**Step 2.** Interrogate a module without loading it:

```bash
modinfo e1000e | head -12
```

```
filename:       /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst
version:        3.8.4-NAPI
license:        GPL v2
description:    Intel(R) PRO/1000 Network Driver
alias:          pci:v00008086d000015B8sv*sd*bc*sc*i*
depends:
retpoline:      Y
parmtype:       debug:Debug level (0=none,...,16=all) (int)
parmtype:       InterruptThrottleRate:Interrupt Throttle Rate (array of int)
```

The `alias` line is the mechanism: `v00008086d000015B8` is exactly the `8086:15b8` you saw in `lspci -nn`. When the PCI core discovers a device it emits a `MODALIAS` uevent containing that string; `udev` calls `modprobe` with it; `modprobe` matches it against `/lib/modules/$(uname -r)/modules.alias`.

**Step 3.** See that alias where the kernel publishes it:

```bash
cat /sys/bus/pci/devices/0000:00:1f.6/modalias
```

```
pci:v00008086d000015B8sv00001028sd000007A0bc02sc00i00
```

**Step 4.** List the tunable parameters of a loaded module and their current values:

```bash
modinfo -p e1000e
ls /sys/module/e1000e/parameters/
cat /sys/module/usbcore/parameters/autosuspend
```

**Step 5.** Unload and reload a module safely. Pick something harmless — the PC speaker driver:

```bash
sudo modprobe pcspkr
lsmod | grep pcspkr
sudo modprobe -r pcspkr
```

`modprobe -r` removes the module *and* any now-unused dependencies; `rmmod` removes exactly one module and refuses if the use count is non-zero.

**Step 6.** Create a persistent configuration. Two directives matter for this objective:

```bash
sudo tee /etc/modprobe.d/99-lab.conf <<'EOF'
# Prevent udev from auto-loading this driver on device discovery
blacklist pcspkr

# Pass parameters at load time
options usbcore autosuspend=-1
EOF
```

**Step 7.** Prove the limit of `blacklist`:

```bash
sudo modprobe pcspkr        # this STILL loads it
lsmod | grep pcspkr
sudo modprobe -r pcspkr
```

`blacklist` only suppresses *alias-driven* automatic loading. To make a module genuinely unloadable, override the install command:

```bash
echo 'install pcspkr /bin/false' | sudo tee -a /etc/modprobe.d/99-lab.conf
sudo modprobe pcspkr ; echo "exit=$?"
```

```
exit=1
```

**Step 8.** If a module is loaded from the initramfs (storage, RAID, GPU), the config file above is not enough — the initramfs carries its own copy of `/etc/modprobe.d`:

```bash
# Debian/Ubuntu
sudo update-initramfs -u
# RHEL/Fedora/SUSE
sudo dracut -f
```

**Step 9.** Clean up:

```bash
sudo rm /etc/modprobe.d/99-lab.conf
```

> ### Check your understanding — Exercise 3
>
> **Q11.** Trace the complete chain from "a PCI card is plugged in" to "its driver is in `lsmod`". Name each component.
>
> **Q12.** `rmmod xhci_hcd` fails. `lsmod` shows `xhci_hcd 352256 1 xhci_pci`. Explain the failure and give the command that would work.
>
> **Q13.** You add `blacklist nouveau` and reboot; `lsmod` still shows `nouveau`. Give two independent explanations and the corresponding fix for each.
>
> **Q14.** What is the difference between `options <mod> <param>=<value>` in `/etc/modprobe.d/` and writing to `/sys/module/<mod>/parameters/<param>`?
>
> **Q15.** Which file does `modprobe` consult to resolve a `MODALIAS` string into a module name, and which command regenerates it?

---

## Exercise 4 — Hardware resources: IRQ, I/O ports, DMA and memory ranges

**Step 1.** Read the interrupt table:

```bash
cat /proc/interrupts
```

```
           CPU0       CPU1       CPU2       CPU3
  0:         12          0          0          0   IO-APIC    2-edge      timer
  1:          0          9          0          0   IO-APIC    1-edge      i8042
  8:          0          0          1          0   IO-APIC    8-edge      rtc0
  9:          0          0          0          0   IO-APIC    9-fasteoi   acpi
 12:          0          0        152          0   IO-APIC   12-edge      i8042
 16:          0          0          0         31   IO-APIC   16-fasteoi   i801_smbus
124:      12034          0          0          0   PCI-MSI 327680-edge      xhci_hcd
125:          0      45120          0          0   PCI-MSI 512000-edge      nvme0q0
130:          3          0          0          0   PCI-MSI 3145728-edge     enp0s31f6
NMI:         12         14         11         10   Non-maskable interrupts
LOC:    1204567    1198234    1187654    1176543   Local timer interrupts
ERR:          0
```

Column 1 is the IRQ number, then one counter **per CPU**, then the interrupt controller and trigger type, then the owning device or driver.

**Step 2.** Prove that the counters are live. Move the mouse, or generate disk I/O, and watch:

```bash
watch -n1 "grep -E 'i8042|nvme0q1|xhci' /proc/interrupts"
```

**Step 3.** Compare a legacy IRQ with an MSI one. Legacy PCI interrupts (`IO-APIC`, `fasteoi`) are *shared* — several devices on the same line. MSI/MSI-X interrupts are message-based, delivered over the PCI bus itself, and are not shared:

```bash
awk '$NF ~ /fasteoi/ {print}' /proc/interrupts
```

Any line with two or more device names at the end is a shared legacy IRQ.

**Step 4.** Read the I/O port map — the legacy x86 address space, separate from memory:

```bash
sudo cat /proc/ioports | head -20
```

```
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0064-0064 : keyboard
  0070-0077 : rtc0
  0080-008f : dma page reg
  00a0-00a1 : pic2
  00c0-00df : dma2
  02f8-02ff : serial
  03f8-03ff : serial
```

`03f8-03ff` is the classic `COM1` / `/dev/ttyS0` range; `0060`/`0064` is the PS/2 controller behind the `i8042` driver you saw at IRQ 1 and IRQ 12.

**Step 5.** Read the memory-mapped I/O map, and observe the privilege difference:

```bash
cat /proc/iomem | head -5          # as a normal user
sudo cat /proc/iomem | head -12    # as root
```

```
00000000-00000000 : Reserved
00000000-00000000 : System RAM
```

```
00000000-00000fff : Reserved
00001000-0009fbff : System RAM
000a0000-000bffff : PCI Bus 0000:00
00100000-bffdffff : System RAM
df200000-df21ffff : 0000:00:1f.6
  df200000-df21ffff : e1000e
fed00000-fed003ff : HPET 0
```

Addresses are zeroed for unprivileged readers on purpose: they are a kernel-ASLR oracle.

**Step 6.** Read the ISA DMA channel table:

```bash
cat /proc/dma
```

```
 4: cascade
```

On any modern machine this is nearly empty. Channel 4 is the cascade linking the two 8237 controllers. PCI devices do not use these channels — they perform **bus-master DMA**, which is why `lspci -vv` shows `BusMaster+` instead.

**Step 7.** Correlate: pick your NIC and confirm the same IRQ appears in three places.

```bash
DEV=0000:00:1f.6
cat /sys/bus/pci/devices/$DEV/irq
grep -E "$(cat /sys/bus/pci/devices/$DEV/irq):" /proc/interrupts
sudo lspci -vv -s ${DEV#0000:} | grep -E 'Interrupt|Region'
```

> ### Check your understanding — Exercise 4
>
> **Q16.** Why does `/proc/interrupts` have one column per CPU, and what does an interrupt count of 0 on three of four CPUs tell you?
>
> **Q17.** `/proc/dma` shows only `4: cascade` on a machine with an NVMe SSD and a gigabit NIC. Do those devices perform DMA? Explain.
>
> **Q18.** What is the difference between `/proc/ioports` and `/proc/iomem`, and why are the addresses in `/proc/iomem` zeroed for non-root users?
>
> **Q19.** Two devices share IRQ 16. Is this a misconfiguration? What does the answer depend on?
>
> **Q20.** A driver loads, the device appears in `lspci -k` with `Kernel driver in use`, but the device never responds. `/proc/interrupts` shows its IRQ line stuck at 0. What class of problem does that point to?

---

## Exercise 5 — `sysfs` and `udev`: from kernel object to `/dev` node

**Step 1.** Confirm the three filesystems involved are mounted:

```bash
findmnt -t sysfs,devtmpfs,proc -o TARGET,SOURCE,FSTYPE
```

```
TARGET  SOURCE   FSTYPE
/proc   proc     proc
/sys    sysfs    sysfs
/dev    devtmpfs devtmpfs
```

**Step 2.** Walk the same device from three different directions. `sysfs` is one object tree exposed through several views:

```bash
ls -l /sys/class/net/                       # by function
ls -l /sys/bus/pci/devices/                 # by bus
ls -ld /sys/devices/pci0000:00/0000:00:1f.6 # by physical topology
```

```
lrwxrwxrwx 1 root root 0 Aug 25 10:12 enp0s31f6 -> ../../devices/pci0000:00/0000:00:1f.6/net/enp0s31f6
```

`/sys/class/` and `/sys/bus/` contain **symlinks**; `/sys/devices/` holds the real hierarchy.

**Step 3.** Dump every udev property of a device:

```bash
udevadm info --query=property --name=/dev/sda
```

```
DEVNAME=/dev/sda
DEVPATH=/devices/pci0000:00/0000:00:14.0/usb2/2-2/2-2:1.0/host4/target4:0:0/4:0:0:0/block/sda
DEVTYPE=disk
ID_BUS=usb
ID_MODEL=Cruzer_Blade
ID_SERIAL=SanDisk_Cruzer_Blade_4C530001120830115202-0:0
ID_USB_DRIVER=usb-storage
ID_VENDOR=SanDisk
MAJOR=8
MINOR=0
SUBSYSTEM=block
```

**Step 4.** Dump the attribute walk — this is what you use to *write* a rule:

```bash
udevadm info --attribute-walk --name=/dev/sda | head -40
```

```
  looking at device '/devices/.../block/sda':
    KERNEL=="sda"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{removable}=="1"
    ATTR{size}=="60628992"

  looking at parent device '/devices/.../4:0:0:0':
    KERNELS=="4:0:0:0"
    SUBSYSTEMS=="scsi"
    DRIVERS=="sd"

  looking at parent device '/devices/.../usb2/2-2':
    KERNELS=="2-2"
    SUBSYSTEMS=="usb"
    DRIVERS=="usb"
    ATTRS{idVendor}=="0781"
    ATTRS{idProduct}=="5567"
    ATTRS{serial}=="4C530001120830115202"
```

Note the singular/plural distinction: `KERNEL`/`ATTR` match the device **itself**, `KERNELS`/`ATTRS`/`DRIVERS` match **any parent** in the chain. A rule may use `ATTR{}` from exactly one device but may combine `ATTRS{}` from several parents.

**Step 5.** Write a rule that gives your USB stick a stable symlink. Substitute your own IDs:

```bash
sudo tee /etc/udev/rules.d/99-lab-stick.rules <<'EOF'
SUBSYSTEM=="block", KERNEL=="sd?1", ATTRS{idVendor}=="0781", \
  ATTRS{idProduct}=="5567", SYMLINK+="labstick", MODE="0660", GROUP="disk"
EOF
```

Operators: `==` match, `!=` negated match, `=` assign, `+=` append to a list, `:=` assign and forbid later change.

**Step 6.** Reload and re-trigger without replugging:

```bash
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=block --action=add
ls -l /dev/labstick
```

```
lrwxrwxrwx 1 root root 4 Aug 25 10:31 /dev/labstick -> sda1
```

**Step 7.** Debug a rule that does not fire — `udevadm test` replays the rule set against a device and prints every decision:

```bash
sudo udevadm test /sys/class/block/sda1 2>&1 | grep -i -E 'lab-stick|SYMLINK'
```

**Step 8.** Understand precedence and clean up:

```bash
ls /usr/lib/udev/rules.d/ | head -5   # distribution-supplied
ls /etc/udev/rules.d/                 # administrator-supplied, WINS on same filename
sudo rm /etc/udev/rules.d/99-lab-stick.rules
sudo udevadm control --reload
```

Rules are processed in **lexical order of filename** across both directories merged; an identically-named file in `/etc/udev/rules.d/` completely masks the one in `/usr/lib/udev/rules.d/`.

> ### Check your understanding — Exercise 5
>
> **Q21.** Which component creates the device node `/dev/sda` — the kernel or `udev`? What, then, does `udev` contribute?
>
> **Q22.** Explain precisely when to use `ATTR{}` and when to use `ATTRS{}`.
>
> **Q23.** Your rule file is named `10-mystick.rules` and a distribution rule in `60-persistent-storage.rules` overwrites your `MODE`. What are two ways to fix this?
>
> **Q24.** Why is `udevadm trigger` needed after `udevadm control --reload`, and what does it actually do?
>
> **Q25.** `/sys/class/net/enp0s31f6` and `/sys/devices/pci0000:00/0000:00:1f.6/net/enp0s31f6` — what is the relationship between these two paths, and why does `sysfs` present both?

---

## Exercise 6 — Differentiate mass storage devices

**Step 1.** Get the full picture in one command:

```bash
lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,ROTA,TRAN,MODEL
```

```
NAME        MAJ:MIN RM   SIZE RO TYPE ROTA TRAN MODEL
nvme0n1     259:0    0 476.9G  0 disk    0 nvme Samsung SSD 970 EVO Plus 500GB
├─nvme0n1p1 259:1    0   512M  0 part    0
└─nvme0n1p2 259:2    0 476.4G  0 part    0
sda           8:0    0 931.5G  0 disk    1 sata WDC WD10EZEX-08WN4A0
└─sda1        8:1    0 931.5G  0 part    1
sdb           8:16   1  28.9G  0 disk    1 usb  Cruzer Blade
└─sdb1        8:17   1  28.9G  0 part    1
sr0          11:0    1  1024M  0 rom     1 sata DVD+-RW GU90N
```

`TRAN` is the transport — this is the field that answers "what kind of device is it". `RM` is the removable flag. `MAJ:MIN` is the device number pair: major 8 = SCSI disk, 11 = SCSI CD-ROM, 259 = block extended (NVMe and high-numbered partitions), 179 = MMC.

**Step 2.** Note the trap in the output above: `sdb` is a USB flash drive — solid state — yet `ROTA` says `1`.

```bash
cat /sys/block/sdb/queue/rotational
cat /sys/block/nvme0n1/queue/rotational
```

`rotational` is a *hint the kernel or the transport reports*, not a measurement. USB bridges routinely fail to report the non-rotational flag.

**Step 3.** See why so many different devices are called `sd*`:

```bash
lsscsi
cat /proc/scsi/scsi
```

```
[0:0:0:0]    disk    ATA      WDC WD10EZEX-08W 1A01  /dev/sda
[1:0:0:0]    cd/dvd  HL-DT-ST DVD+-RW GU90N    A1C2  /dev/sr0
[4:0:0:0]    disk    SanDisk  Cruzer Blade     1.00  /dev/sdb
```

The Linux SCSI subsystem is a *command-set layer*. SATA (via `libata`), SAS, USB mass storage (via `usb-storage`/`uas`), FC and iSCSI all speak SCSI commands, so all of them get `sd` names and `[host:channel:target:lun]` addresses. Genuine PATA/IDE `hdX` names disappeared when the old IDE drivers were replaced by `libata`.

**Step 4.** NVMe is the exception — it does *not* go through SCSI:

```bash
sudo nvme list
ls /sys/class/nvme/
```

```
Node          SN            Model                      Namespace Usage            FW Rev
------------- ------------- -------------------------- --------- ---------------- --------
/dev/nvme0n1  S4EVNF0M12345 Samsung SSD 970 EVO Plus    1         512.11 GB        2B2QEXM7
```

The naming is `nvme<controller>n<namespace>p<partition>`: `/dev/nvme0n1p2` is controller 0, namespace 1, partition 2. A namespace is not a partition — it is a controller-level division of the flash, closer to a LUN.

**Step 5.** Interrogate a real ATA device:

```bash
sudo hdparm -I /dev/sda | grep -E 'Model|Serial|Rotation|Nominal|LBA48|Transport'
```

```
	Model Number:       WDC WD10EZEX-08WN4A0
	Serial Number:      WD-WCC6Y1234567
	Transport:          Serial, ATA8-AST, SATA 1.0a, SATA II ...
	Nominal Media Rotation Rate: 7200
	LBA48  user addressable sectors:  1953525168
```

`Nominal Media Rotation Rate: 7200` is a spinning disk; an SSD reports `Solid State Device`.

**Step 6.** Get vendor-independent health and identity via SMART:

```bash
sudo smartctl -i /dev/sda
sudo smartctl -H /dev/nvme0n1
```

**Step 7.** Add a SCSI/SATA device that was attached after boot without rebooting:

```bash
ls /sys/class/scsi_host/
for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee $h/scan; done
lsblk
```

The three dashes are wildcards for channel, target and LUN.

**Step 8.** Check the sector geometry — this is what alignment and `4Kn` vs `512e` mean:

```bash
cat /sys/block/sda/queue/hw_sector_size
cat /sys/block/sda/queue/physical_block_size
cat /sys/block/sda/queue/logical_block_size
```

> ### Check your understanding — Exercise 6
>
> **Q26.** A SATA disk, a SAS disk and a USB flash drive all appear as `/dev/sdX`. Why? Which subsystem is responsible?
>
> **Q27.** `/sys/block/sdb/queue/rotational` reports `1` for a USB flash drive. Is the kernel wrong? What is the practical consequence for I/O scheduling?
>
> **Q28.** Decompose `/dev/nvme0n1p3`. How does the meaning of `n1` differ from a partition?
>
> **Q29.** You hot-plug a SATA disk into a running server and it does not appear in `lsblk`. Give the command that makes the kernel look for it, and explain the `- - -`.
>
> **Q30.** Which two commands would you use to decide, on unknown hardware, whether `/dev/sda` is a spinning disk or an SSD — and which one do you trust more?

---

## Exercise 7 — Enable and disable integrated peripherals

There are four layers at which an integrated peripheral can be turned off. Work through them from the lowest to the highest.

**Step 1 — Layer 1: firmware.** Read what the firmware reports about the board:

```bash
sudo dmidecode -t bios -t baseboard | head -20
ls /sys/firmware/         # 'efi' present => UEFI boot; absent => legacy BIOS
```

```
BIOS Information
	Vendor: Dell Inc.
	Version: 1.27.0
	Release Date: 07/12/2023
Base Board Information
	Manufacturer: Dell Inc.
	Product Name: 0K1MDR
```

Disabling a controller in Setup makes the device vanish from `lspci` entirely — this is the only layer that removes the hardware from the OS's view. Nothing in Linux can re-enable it.

**Step 2 — Layer 2: kernel command line.** Inspect what the running kernel was told:

```bash
cat /proc/cmdline
```

```
BOOT_IMAGE=/vmlinuz-6.8.0-45-generic root=UUID=... ro quiet splash
```

To blacklist a driver at boot, add `modprobe.blacklist=<mod>`; to disable a whole class, options such as `nomodeset` (no kernel mode setting), `noapic`, `pci=noaer`, `usbcore.autosuspend=-1`. On GRUB systems:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&modprobe.blacklist=pcspkr /' /etc/default/grub
sudo update-grub    ||    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

**Step 3 — Layer 3: module policy.** As in Exercise 3 — `/etc/modprobe.d/*.conf` with `blacklist` plus `install <mod> /bin/false`, rebuilding the initramfs when the module is loaded early.

**Step 4 — Layer 4: runtime, via sysfs.** Unbind a driver from a device without unloading the module. **Do not do this to the disk controller or to the NIC you are connected through.**

Pick a safe target — the audio codec:

```bash
DEV=0000:00:1f.3
basename $(readlink /sys/bus/pci/devices/$DEV/driver)
```

```
snd_hda_intel
```

```bash
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/unbind
lspci -k -s ${DEV#0000:}          # 'Kernel driver in use' line is gone
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/bind
```

**Step 5.** Go further — remove the PCI function from the kernel's device tree, then bring it back:

```bash
echo 1 | sudo tee /sys/bus/pci/devices/$DEV/remove
lspci | grep 1f.3          # no output — the device is gone
echo 1 | sudo tee /sys/bus/pci/rescan
lspci -k | grep -A2 1f.3   # rediscovered and rebound
```

**Step 6.** Disable a peripheral by class using udev — for example, refuse to activate any USB mass storage device:

```bash
sudo tee /etc/udev/rules.d/99-no-usb-storage.rules <<'EOF'
ACTION=="add", SUBSYSTEMS=="usb", ATTRS{bInterfaceClass}=="08", \
  RUN+="/bin/sh -c 'echo 0 > /sys%p/../authorized'"
EOF
```

Then remove it again — this is a demonstration, not a hardening recipe:

```bash
sudo rm /etc/udev/rules.d/99-no-usb-storage.rules && sudo udevadm control --reload
```

**Step 7.** Verify the whole picture with a single inventory tool:

```bash
sudo lshw -short | head -25
```

```
H/W path            Device      Class       Description
=======================================================
                                system      Latitude 7480
/0                              bus         0K1MDR
/0/0                            memory      64KiB BIOS
/0/3a                           processor   Intel(R) Core(TM) i5-7300U CPU
/0/100/1f.3                     multimedia  Sunrise Point-LP HD Audio
/0/100/1f.6         enp0s31f6   network     Ethernet Connection (2) I219-V
```

> ### Check your understanding — Exercise 7
>
> **Q31.** Rank the four layers (firmware, kernel cmdline, modprobe, sysfs) by persistence across reboot and by whether the device still appears in `lspci`.
>
> **Q32.** You unbind `e1000e` from the NIC over SSH through that same NIC. What happens, and what is the recovery?
>
> **Q33.** What is the difference in effect between writing to `.../driver/unbind` and writing to `.../device/remove`?
>
> **Q34.** A device was disabled in the UEFI Setup. Which Linux command reveals this, and which Linux command re-enables it?
>
> **Q35.** Why must you rebuild the initramfs after blacklisting a storage driver, but not after blacklisting `pcspkr`?

---

## Exercise 8 — D-Bus, and diagnosing a device that will not appear

`sysfs` and `udev` are kernel-facing; **D-Bus** is the userspace IPC bus on which services such as `udisks2`, `NetworkManager` and `systemd-logind` publish hardware events and accept requests. This is the third leg of the "sysfs, udev, dbus" triad in the objective.

**Step 1.** Confirm the system bus is running and list its well-known names:

```bash
systemctl status dbus --no-pager | head -4
busctl list | head -12
```

```
NAME                             PID PROCESS         USER
org.freedesktop.NetworkManager   912 NetworkManager  root
org.freedesktop.UDisks2         1341 udisksd         root
org.freedesktop.login1           701 systemd-logind  root
org.freedesktop.systemd1           1 systemd         root
```

**Step 2.** Introspect a hardware-facing service. `udisks2` is the storage abstraction desktops use:

```bash
busctl tree org.freedesktop.UDisks2 | head -15
busctl introspect org.freedesktop.UDisks2 \
  /org/freedesktop/UDisks2/block_devices/sda1 \
  org.freedesktop.UDisks2.Block | head -12
```

```
NAME                       TYPE      SIGNATURE  RESULT/VALUE
.Device                    property  ay         5 47 100 101 118 ...
.IdLabel                   property  s          "DATA"
.IdType                    property  s          "ext4"
.IdUUID                    property  s          "9f3b-..."
.Size                      property  t          1000203091968
```

**Step 3.** Use the high-level client and compare it with the raw bus:

```bash
udisksctl status
udisksctl info -b /dev/sda1 | head -12
```

**Step 4.** Watch the bus while you plug in the USB device:

```bash
sudo busctl monitor org.freedesktop.UDisks2
```

Now trace the same physical event through all three layers by running these in three terminals simultaneously and replugging the device:

```bash
sudo dmesg -w                             # kernel
sudo udevadm monitor --kernel --udev      # uevents
sudo busctl monitor org.freedesktop.UDisks2   # userspace services
```

**Step 5.** Read the kernel ring buffer with human timestamps and a severity filter:

```bash
sudo dmesg -T --level=err,warn | tail -20
sudo journalctl -k -b -p warning --no-pager | tail -20
```

```
[Mon Aug 25 10:44:02 2026] usb 2-2: new SuperSpeed USB device number 4 using xhci_hcd
[Mon Aug 25 10:44:02 2026] usb 2-2: New USB device found, idVendor=0781, idProduct=5567
[Mon Aug 25 10:44:02 2026] usb-storage 2-2:1.0: USB Mass Storage device detected
[Mon Aug 25 10:44:03 2026] scsi 4:0:0:0: Direct-Access  SanDisk Cruzer Blade
[Mon Aug 25 10:44:03 2026] sd 4:0:0:0: [sdb] 60628992 512-byte logical blocks
```

**Step 6.** Apply the diagnostic ladder. A device does not work — walk *down* the stack, stopping at the first layer that fails:

| Layer | Question | Command |
|---|---|---|
| 1. Electrical / firmware | Does the bus see it at all? | `lspci -nn`, `lsusb`, `dmesg` |
| 2. Driver availability | Is a driver present for that ID? | `lspci -k`, `modinfo <mod>`, `modprobe <mod>` |
| 3. Driver binding | Is it bound? | `lspci -k`, `ls /sys/bus/*/devices/*/driver` |
| 4. Resources | Did it get an IRQ and BARs? | `/proc/interrupts`, `/proc/iomem`, `lspci -vv` |
| 5. Device node | Is `/dev/...` present with the right mode? | `udevadm info`, `ls -l /dev/...` |
| 6. Service | Did userspace pick it up? | `busctl`, `udisksctl`, `journalctl -u ...` |

**Step 7.** Practise it. Break the stack deliberately at layer 3 and diagnose it as if you did not know:

```bash
DEV=0000:00:1f.3
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/unbind
# now: lspci -nn (present), lspci -k (no driver), lsmod (module still loaded)
echo $DEV | sudo tee /sys/bus/pci/drivers/snd_hda_intel/bind
```

> ### Check your understanding — Exercise 8
>
> **Q36.** Place `sysfs`, `udev` and `D-Bus` on the path from a hardware interrupt to a desktop notification saying "USB drive mounted". Which runs in kernel space?
>
> **Q37.** A device is listed in `lspci -nn` but `lspci -k` shows no `Kernel driver in use` and no `Kernel modules`. What does the *absence of the second line* tell you specifically?
>
> **Q38.** Why is `dmesg -T` sometimes inaccurate on a machine that has been suspended, and what should you use instead?
>
> **Q39.** `udevadm monitor` prints a `KERNEL` line but no matching `UDEV` line for a device. Where is the problem?
>
> **Q40.** Name the one command from this whole topic that you would run first on an unknown machine to get a single-screen hardware inventory, and state its main limitation.

---

<details>
<summary><b>Answers — click to expand</b></summary>

### Exercise 1 — PCI

**A1.** `0000` = PCI *domain* (a separate address space / host bridge; almost always 0 on a desktop, non-zero on large servers and some ARM SoCs). `00` = *bus* number. `1f` = *device* (slot) number on that bus, hexadecimal. `6` = *function*. A single physical package may implement up to eight logically independent functions sharing one slot — the Intel PCH implements audio at `1f.3`, LPC at `1f.0`, SMBus at `1f.4` and the NIC at `1f.6`. Each function gets its own configuration space, its own driver and its own resources.

**A2.** `8086` is the vendor ID (Intel); `15b8` is the device ID assigned by that vendor. The strings come from the local `pci.ids` database (`/usr/share/hwdata/pci.ids` or `/usr/share/misc/pci.ids`), refreshed with `update-pciids`. If the file is stale, `lspci` prints `Device 15b8` — the hardware is fine, the *database* is out of date.

**A3.** PCI configuration space beyond the first 64 bytes — capability lists, extended capabilities, link status — is only readable by root, because `lspci` must access `/sys/bus/pci/devices/*/config` (or `/proc/bus/pci`) with elevated privileges. Fix: run `sudo lspci -vv`.

**A4.** `Kernel driver in use:`. In the failure case that line is **absent**. If `Kernel modules:` is present but `Kernel driver in use:` is missing, a suitable module exists but is not loaded or not bound. If *both* lines are missing, the running kernel has no driver for that ID at all.

**A5.** `/sys/bus/pci/devices/<domain:bus:dev.fn>/irq`.

### Exercise 2 — USB

**A6.** No. `1d6b` is the Linux Foundation's vendor ID and the "root hub" is a software construct: the kernel's USB core presents each host controller's ports as a virtual hub so the topology has a single root. One appears per bus per protocol generation — `1d6b:0002` for the USB 2.0 bus, `1d6b:0003` for the USB 3.x bus of the same xHCI controller.

**A7.** (a) It is plugged into a USB 2.0-only port — physically only the four USB 2.0 pins are wired. (b) A cable or hub without the extra SuperSpeed differential pairs (a USB 2.0 extension cable, or a 2.0 hub) sits in the path. A third cause: a marginal connection causing the SuperSpeed link to fail training and fall back.

**A8.** The device exposes two **interfaces** in its configuration — it is a composite device (e.g. a wireless receiver presenting a keyboard interface and a mouse interface, or Bluetooth presenting HCI and isochronous audio). Drivers in USB bind per *interface*, not per device, so two separate driver instances (or even two different modules) can be bound to the same physical device.

**A9.** Bus 1, root-hub port 4; a hub is attached there; on that hub, port 2; another hub is attached there; on *that* hub, port 1 — the device. The dotted chain is the physical path from the root controller.

**A10.** Electrically nothing changed: the device is still powered and still enumerated at the bus level. What changed is that the kernel de-authorizes it — it tears down the device's interfaces, unbinds their drivers and removes it from the USB device list, so `lsusb` no longer shows it and no driver can talk to it. It is the software equivalent of unplugging, and is the mechanism behind USB-device whitelisting.

### Exercise 3 — Modules

**A11.** The PCI core enumerates the device and creates a `struct device`, exposed in `sysfs` at `/sys/devices/...` with a `modalias` attribute → the kernel emits a `uevent` (netlink) containing `MODALIAS=pci:v0000...` → `systemd-udevd` receives it and matches the built-in rule that calls `modprobe $env{MODALIAS}` → `modprobe` resolves the alias against `/lib/modules/$(uname -r)/modules.alias`, loads dependencies from `modules.dep`, and inserts the `.ko` → the module's PCI driver registration matches the device's ID table and the driver's `probe()` binds it → the module now appears in `lsmod` and `Kernel driver in use` appears in `lspci -k`.

**A12.** `xhci_hcd` has use count 1: `xhci_pci` depends on it. `rmmod` removes exactly one module and refuses when the use count is non-zero. `sudo modprobe -r xhci_hcd` walks the dependency graph and removes `xhci_pci` first. (In practice this also kills every USB device on that controller.)

**A13.** (1) `blacklist` only suppresses *alias-based automatic* loading; something is loading it explicitly — another module depends on it, it is listed in `/etc/modules-load.d/`, or a script calls `modprobe`. Fix: add `install nouveau /bin/false`. (2) The module is being loaded from the **initramfs**, which carries its own snapshot of `/etc/modprobe.d/`. Fix: `update-initramfs -u` or `dracut -f`, then reboot. A third possibility: it is built into the kernel rather than a module — check `grep NOUVEAU /boot/config-$(uname -r)`; `=y` cannot be blacklisted at all, only disabled with a kernel parameter.

**A14.** `options` in `/etc/modprobe.d/` is applied **at load time** and is persistent across reboots, but has no effect on an already-loaded module. Writing to `/sys/module/<mod>/parameters/<param>` changes a live value immediately but is not persistent, and only works for parameters the module declared writable (mode `0644` rather than `0444`); read-only parameters can only be set at load time.

**A15.** `/lib/modules/$(uname ‑r)/modules.alias` (with dependencies in `modules.dep`). Both are regenerated by `depmod -a`.

### Exercise 4 — Resources

**A16.** Because interrupts are delivered to a specific CPU, and the local APIC / IRQ affinity decides which. The per-CPU columns let you see the distribution. Counts concentrated on one CPU mean the IRQ has a pinned affinity (see `/proc/irq/<n>/smp_affinity`) — normal for a single-queue device, but on a high-throughput NIC or NVMe it means one core is doing all the interrupt work and is a real bottleneck; `irqbalance` or manual affinity spreads it.

**A17.** Yes, constantly — but not via the legacy ISA DMA controller. `/proc/dma` only tracks the 8237 ISA channels, which no modern peripheral uses. PCI/PCIe devices are **bus masters**: they initiate their own transfers to system memory across the PCI bus (visible as `BusMaster+` in `lspci -vv`), coordinated through the IOMMU where present. `/proc/dma` being nearly empty is the expected, healthy state.

**A18.** `/proc/ioports` maps the x86 **port I/O** address space (a separate 64 KiB space accessed with the `IN`/`OUT` instructions), a legacy mechanism used by the PIC, timers, serial ports and the PS/2 controller. `/proc/iomem` maps **memory-mapped I/O** and RAM within the physical address space — how essentially all modern devices are addressed. The addresses in `/proc/iomem` are zeroed for non-root because the layout leaks kernel physical addresses, which defeats KASLR; the file was hardened deliberately.

**A19.** Not necessarily. Legacy PCI interrupts (INTx, shown as `IO-APIC ... fasteoi`) are level-triggered and *designed* to be shared: the kernel calls each registered handler in turn and each checks whether its own device raised the line. It becomes a problem only when a badly written driver claims interrupts that were not its own, or when latency matters. MSI/MSI-X lines (`PCI-MSI`) are never shared — each is a distinct message.

**A20.** The device is not delivering interrupts. Typical causes: the IRQ was routed incorrectly by the firmware's ACPI tables, MSI is broken on that chipset (a classic fix is the `pci=nomsi` kernel parameter or a per-driver option), the interrupt is masked, or the device is in a low-power state. The driver bound and configured the device successfully — layer 3 is fine, layer 4 is broken.

### Exercise 5 — sysfs and udev

**A21.** The **kernel** creates the node, via `devtmpfs`: as soon as a character or block device is registered the kernel populates `/dev` with a node carrying the correct major:minor and a default root-owned mode. `udev` does everything *after* that: applying ownership, permissions and SELinux labels; creating persistent symlinks (`/dev/disk/by-uuid/...`, `/dev/labstick`); setting properties consumed by other services; running programs on device events. Before `devtmpfs`, `udev` created the nodes too — that is why older documentation says otherwise.

**A22.** `ATTR{}` matches an attribute file on **the device the event is about** — the one whose `KERNEL`/`SUBSYSTEM` you matched. `ATTRS{}` matches an attribute on the device **or any of its ancestors** in the `sysfs` tree. USB identity (`idVendor`, `idProduct`, `serial`) lives on the USB device node, several levels above the `block` device, so a rule targeting `/dev/sdb1` must use `ATTRS{idVendor}`. Caveat: all `ATTRS{}` in one rule must match on the *same* parent device.

**A23.** (a) Rename your file so it sorts **after** the distribution rule — e.g. `99-mystick.rules`; last assignment wins. (b) Use the `:=` operator (`MODE:="0660"`), which makes the value final and forbids later rules from changing it. (Renaming is the conventional answer; `:=` is the blunt instrument.)

**A24.** `udevadm control --reload` tells the running `systemd-udevd` to re-read its rule files — but rules only execute on events, and the device was added before the new rules existed. `udevadm trigger` asks the kernel to **re-emit synthetic uevents** for devices already present in `sysfs` (it writes to each device's `uevent` file), so the new rules are evaluated against existing hardware without replugging it.

**A25.** They are the same kernel object seen through two views. `/sys/devices/...` is the real hierarchy, organised by physical topology (host bridge → PCI bus → function → net device). `/sys/class/net/enp0s31f6` is a **symlink** into that tree, organising devices by *function* instead. `sysfs` provides both because the two questions — "what is attached to this bus?" and "what network interfaces exist?" — are both legitimate, and a purely topological tree makes the second one impossible to answer without a full walk. `/sys/bus/` is a third view, by bus type.

### Exercise 6 — Mass storage

**A26.** Because the Linux **SCSI subsystem** is a command-set abstraction, not a cable standard. `libata` translates ATA/SATA into SCSI commands; SAS is natively SCSI; `usb-storage` and `uas` transport SCSI commands over USB (Bulk-Only Transport / UAS); iSCSI and FC do the same over a network. All of them register with the SCSI mid-layer, so the `sd` upper-level driver names them `sdX` and gives them `[host:channel:target:lun]` addresses. NVMe is the notable exception — it bypasses SCSI entirely.

**A27.** The kernel is reporting what it was told. `rotational` is derived from what the transport advertises (ATA `Nominal Media Rotation Rate`, SCSI VPD page `B1h`); USB-to-SATA bridges frequently do not pass that through, so the kernel defaults to `1`. Consequence: the block layer applies rotational assumptions — heavier I/O merging and seek-avoiding elevator behaviour with schedulers such as `bfq`/`mq-deadline` — which is merely suboptimal, not harmful. You can override it: `echo 0 > /sys/block/sdb/queue/rotational`.

**A28.** `nvme0` = NVMe **controller** 0. `n1` = **namespace** 1 on that controller. `p3` = partition 3 of that namespace. A namespace is a controller-level division of the flash with its own LBA range, block size and formatting — created and destroyed by the controller itself (`nvme create-ns`), invisible to the partition table. Partitions are an OS-level construct written *inside* a namespace. One controller can present several namespaces, each of which looks like an independent block device.

**A29.** `for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee $h/scan; done`. The three fields are **channel, target (SCSI ID), LUN**; `-` is a wildcard meaning "scan all values", so `- - -` means "rescan everything on this host adapter". Naming specific numbers scans only that address.

**A30.** `lsblk -o NAME,ROTA,TRAN` for the quick answer, and `sudo hdparm -I /dev/sda | grep Rotation` (or `sudo smartctl -i /dev/sda`) for the authoritative one. Trust `hdparm`/`smartctl`: they ask the *device* directly via an ATA IDENTIFY / SCSI INQUIRY command, whereas `ROTA` is a kernel-side flag that a bridge chip can misreport (see A27).

### Exercise 7 — Enabling and disabling peripherals

**A31.**

| Layer | Persists across reboot? | Still visible in `lspci`? |
|---|---|---|
| Firmware (BIOS/UEFI Setup) | Yes | **No** — the device is not presented to the OS at all |
| Kernel command line (GRUB) | Yes | Yes (unless the parameter suppresses the whole bus) |
| `/etc/modprobe.d/` | Yes | Yes, with no `Kernel driver in use` |
| `sysfs` unbind/remove | **No** — lost at reboot | `unbind`: yes, driverless. `remove`: no, until rescan |

**A32.** The interface goes down instantly, the TCP connection stalls and the session is dead — you cannot type the `bind` command, because the command you would type has to travel over the interface you just disabled. Recovery requires out-of-band access: physical console, serial/IPMI/iDRAC, or another NIC. This is why the exercise uses the audio codec. The professional habit is to wrap such operations so they self-revert: `sudo sh -c 'echo $DEV > .../unbind; sleep 30; echo $DEV > .../bind'`, run under `nohup`/`systemd-run` so it survives the dropped session.

**A33.** `unbind` detaches the **driver** from the device: the driver's `remove()` runs, the device stops functioning, but the `struct device` remains in the kernel's tree and the device is still listed in `lspci` and under `/sys/bus/pci/devices/`. You can rebind it by writing the address to the driver's `bind` file, or bind a *different* driver (this is how `vfio-pci` is attached for PCI passthrough). `remove` deletes the device object from the kernel entirely — it disappears from `lspci` and from `sysfs`, and only a bus rescan (`echo 1 > /sys/bus/pci/rescan`) brings it back.

**A34.** `lspci`/`lsusb` reveal it by **omission**: the device is simply absent, and `dmesg` never mentions it. Cross-check with `dmidecode` or the vendor's slot list to confirm the hardware exists. No Linux command re-enables it — the firmware never presents the device to the OS, so there is nothing for the kernel to enumerate. You must reboot into Setup. (Vendor tools such as Dell's `racadm` or HPE's `conrep` can edit firmware settings from within Linux, but they are writing firmware configuration, not enabling the device at runtime.)

**A35.** Because the initramfs must be able to mount the root filesystem before `/etc` is available, so it carries its own copy of `/etc/modprobe.d/` and loads storage, RAID and root-critical drivers itself. A blacklist added only to the real root filesystem is read too late — the module is already loaded. `pcspkr` is never in the initramfs; it is loaded from the real root by udev after `switch_root`, so the file on disk is consulted in time.

### Exercise 8 — D-Bus and diagnostics

**A36.** Interrupt → the **kernel** driver handles it and updates its device model, exported through **`sysfs`** (kernel space) → the kernel emits a `uevent` over netlink → **`udev`** (`systemd-udevd`, *user* space) processes rules, sets permissions, creates symlinks → services listening for those events (`udisks2`) publish signals on **D-Bus** (user space) → the desktop, subscribed to `org.freedesktop.UDisks2`, shows the notification. Only `sysfs` and the uevent generation are kernel space; `udev` and D-Bus are both ordinary userspace daemons.

**A37.** `Kernel modules:` lists modules whose alias table matches this device's ID, whether or not they are loaded. Its absence means **no module available to this kernel claims this vendor:device ID** — the driver is not merely unloaded, it does not exist in `/lib/modules/$(uname -r)`. The remedies are different: a missing `Kernel driver in use` alone means `modprobe` it; a missing `Kernel modules` means install a newer kernel, a DKMS/out-of-tree driver, or a firmware/linux-firmware package.

**A38.** The kernel ring buffer stores a monotonic timestamp measured from boot. `dmesg -T` converts it by subtracting from the current wall-clock time — but the monotonic clock does not advance while the machine is suspended, so after any suspend/resume cycle every converted timestamp drifts by the total suspended duration. Use `journalctl -k`, which records a real wall-clock timestamp at the moment each message is read, or `dmesg --time-format=iso` on kernels where the clock source is reliable.

**A39.** In userspace, between the kernel and `udev`. The kernel emitted the uevent correctly (the `KERNEL` line proves it), but `systemd-udevd` did not finish processing it — the daemon is not running or is wedged, a rule matched and hung (a `RUN+=` program that blocks; `udev` kills these after a timeout and logs it), or a `RUN+=` failed. Check `systemctl status systemd-udevd`, `journalctl -u systemd-udevd -b`, and re-run the rule set with `udevadm test <syspath>`.

**A40.** `sudo lshw -short` — one screen, every subsystem, with the `sysfs` path, the device node and the class for each entry. Limitation: it is a *synthesiser*. It merges DMI, PCI, USB, SCSI and `sysfs` data into a single tree and can therefore be wrong or out of date in ways the primary tools are not — DMI strings in particular are whatever the board vendor typed. Confirm anything that matters with the authoritative tool for that bus: `lspci -nnk`, `lsusb -t`, `lsblk -o …,TRAN`, `/proc/interrupts`. (`inxi -Fxz` is a friendlier alternative with the same caveat.)

</details>

---

## References

- LPI, *Exam 101 Objectives, version 5.0* — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Linux kernel documentation, *sysfs — The filesystem for exporting kernel objects* — <https://docs.kernel.org/filesystems/sysfs.html>
- Linux kernel documentation, *Rules on how to access information in sysfs* — <https://docs.kernel.org/admin-guide/sysfs-rules.html>
- Linux kernel documentation, *The /proc Filesystem* — <https://docs.kernel.org/filesystems/proc.html>
- Linux kernel documentation, *USB device authorization* — <https://docs.kernel.org/usb/authorization.html>
- Linux kernel documentation, *NVMe subsystem* — <https://docs.kernel.org/admin-guide/nvme-multipath.html>
- `udev(7)` — <https://man7.org/linux/man-pages/man7/udev.7.html>
- `udevadm(8)` — <https://man7.org/linux/man-pages/man8/udevadm.8.html>
- `modprobe.d(5)` — <https://man7.org/linux/man-pages/man5/modprobe.d.5.html>
- `lspci(8)` — <https://man7.org/linux/man-pages/man8/lspci.8.html>
- `lsusb(8)` — <https://man7.org/linux/man-pages/man8/lsusb.8.html>
- `lsblk(8)` — <https://man7.org/linux/man-pages/man8/lsblk.8.html>
- freedesktop.org, *D-Bus Specification* — <https://dbus.freedesktop.org/doc/dbus-specification.html>
- freedesktop.org, *UDisks2 Reference Manual* — <https://storaged.org/doc/udisks2-api/latest/>
- The Linux Kernel Archives, *The USB Device Filesystem and usbutils* — <http://www.linux-usb.org/>