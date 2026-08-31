# 101.1 — Determine and Configure Hardware Settings

**LPIC-1 · Exam 101-500 · Topic 101: System Architecture · Weight 3.13**

> **Scope of this objective.** Enable and disable integrated peripherals; differentiate mass storage device types; determine hardware resources for devices; use the tools that list hardware information; manipulate USB devices; hold a conceptual understanding of `sysfs`, `udev` and `dbus`.
> **Terms and utilities:** `/sys/`, `/proc/`, `/dev/`, `modprobe`, `lsmod`, `lspci`, `lsusb`.

---

## 1. Motivation: the production problem this objective actually solves

On a laptop, "hardware settings" is a curiosity. On a fleet, it is the root cause bucket that nobody owns.

Consider a concrete incident shape that recurs across every platform team:

> A 400-node Kubernetes cluster runs a latency-sensitive ingress tier. After a rolling kernel upgrade, p99 latency on **11 nodes** goes from 800 µs to 45 ms. The pods are identical. The images are identical. The Deployment is identical. `kubectl describe node` shows nothing.
>
> The 11 nodes were racked six months later than the rest and shipped with a different NIC stepping. The new kernel autoloads a different driver variant, the NIC lands on a **different IOMMU group**, its `numa_node` is reported as `-1`, so every interrupt is serviced by a CPU on the wrong socket and every DMA buffer crosses the UPI link.

Nothing in that paragraph is a Kubernetes problem. It is `lspci`, `/proc/interrupts`, `/sys/devices/system/node/`, and a `udev` rule. The architectural point:

**Hardware is not a constant in a distributed system — it is an unversioned, undeclared input that varies across your fleet and changes under you at every firmware and kernel upgrade.**

The mature response is a three-layer discipline:

| Layer | Question | Mechanism | Failure if absent |
|---|---|---|---|
| **Discovery** | What hardware is actually present, and how is the kernel modelling it? | `sysfs`, `procfs`, `lspci`, `lsusb`, `dmidecode`, `lsblk` | Debugging by superstition; "works on node 7" |
| **Declaration** | What configuration must hold, regardless of enumeration order? | `udev` rules, `modprobe.d`, `.link` files, kernel cmdline, Ansible | Non-deterministic device names, boot-order-dependent behaviour |
| **Exposure** | How do schedulers and operators *see* hardware as a first-class resource? | Node labels (NFD), device plugins, Topology Manager, `dbus` services | Workloads placed on nodes that cannot serve them |

This document walks the ladder from firmware enumeration up to a Kubernetes node that advertises `platform.example.com/nic=x710` and `hugepages-1Gi: 16Gi`.

---

## 2. The enumeration chain: firmware → kernel → `sysfs` → `/dev`

Before any tool, understand the pipeline. Every `/dev` node is the terminal output of a five-stage process.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 1. FIRMWARE (UEFI/BIOS + ACPI tables, or Device Tree on ARM/RISC-V)       │
│    Trains DRAM, enumerates PCI, assigns BARs/IRQ routing, publishes:      │
│      x86 : ACPI (DSDT, SSDT, MADT, SRAT, SLIT, DMAR) + SMBIOS            │
│      ARM : Flattened Device Tree (.dtb) or ACPI                          │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 2. KERNEL BUS DRIVERS  (pci, usb, acpi, platform, virtio, i2c, scsi…)    │
│    Re-walks the buses, may reassign resources, creates `struct device`   │
│    objects, computes a MODALIAS string per device.                       │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 3. SYSFS  (/sys)  — the in-memory export of the kernel device model      │
│    kobject tree → directories; attributes → files. THE source of truth.  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 4. UEVENT over netlink (NETLINK_KOBJECT_UEVENT)  →  systemd-udevd        │
│    Kernel says "add /devices/pci0000:00/…, MODALIAS=pci:v8086d1572…"     │
│    udevd: matches rules, calls modprobe, sets names/symlinks/perms/tags  │
└───────────────────────────────┬──────────────────────────────────────────┘
                                v
┌──────────────────────────────────────────────────────────────────────────┐
│ 5. DEVTMPFS (/dev) + D-BUS                                               │
│    Kernel creates the raw node in devtmpfs; udev fixes ownership and     │
│    adds /dev/disk/by-*, /dev/serial/by-id/* symlinks. Higher-level       │
│    daemons (udisks2, UPower, NetworkManager) re-publish on D-Bus.        │
└──────────────────────────────────────────────────────────────────────────┘
```

Two consequences that decide most debugging sessions:

1. **If it is not in `/sys`, `udev` cannot fix it.** A missing `/dev/sdb` when `/sys/block/sdb` also does not exist is a *driver/firmware* problem, not a `udev` problem. Diagnose in the opposite direction of the arrow.
2. **`udev` runs asynchronously.** The kernel node in `devtmpfs` appears *before* udev has processed the event. Scripts that `sleep 2` after plugging a disk are papering over a missing `udevadm settle`.

### 2.1 The three pseudo-filesystems — comparative trade-offs

| Property | `procfs` (`/proc`) | `sysfs` (`/sys`) | `devtmpfs` (`/dev`) |
|---|---|---|---|
| Introduced | Linux 0.98 (1992) | 2.6 (2002) | 2.6.32 (2009) |
| Models | Processes + a historical grab-bag of kernel state | The kernel **device model** (buses, devices, drivers, classes) | Device **special files** (char/block nodes) |
| Structure | Ad-hoc, mixed formats, multi-value files | Strict: **one value per file**, tree mirrors kobject topology | Flat-ish namespace of nodes + udev symlink hierarchies |
| Stable ABI? | Legacy paths frozen by necessity | Documented under `Documentation/ABI/{stable,testing}`; **paths are not stable — traverse, don't hardcode** | Names via udev rules are the stability contract |
| Writable? | Some (`/proc/sys` = sysctl, `/proc/irq/*/smp_affinity`) | Yes, extensively (`sriov_numvfs`, `bind`/`unbind`, `nr_hugepages`) | Node creation only |
| Typical use | CPU/memory/interrupt census, legacy resource maps | Per-device attributes, driver binding, tuning knobs | `open()` targets for userspace |
| Where new kernel features go | Almost never | **Always** | — |

**Rule of thumb for new automation:** read from `sysfs`, treat `procfs` as legacy-but-required for `/proc/interrupts`, `/proc/cpuinfo`, `/proc/iomem`, `/proc/ioports`, `/proc/dma`, `/proc/cmdline`, `/proc/modules`.

The kernel's own guidance (`Documentation/admin-guide/sysfs-rules.rst`) is blunt: never assume a device's `sysfs` path. Find devices by walking `/sys/subsystem/<bus>/devices/` or `/sys/class/<class>/`, then read the attributes you need.

---

## 3. Determining hardware resources: IRQ, DMA, I/O ports, MMIO

The four classical "resources" the exam names. On modern hardware three of them have quietly changed meaning — knowing *how* is the senior-level differentiator.

### 3.1 Interrupts — `/proc/interrupts`

```console
$ head -12 /proc/interrupts
            CPU0       CPU1       CPU2       CPU3     ...    CPU127
   0:         17          0          0          0     ...         0   IO-APIC    2-edge      timer
   8:          0          0          1          0     ...         0   IO-APIC    8-edge      rtc0
   9:          0          0          0          0     ...         0   IO-APIC    9-fasteoi   acpi
  16:          0          0          0          0     ...         0   IO-APIC   16-fasteoi   i801_smbus
 120:          0          0          0          0     ...         0   PCI-MSI 1572864-edge   nvme0q0
 121:    8934120          0          0          0     ...         0   PCI-MSI 1572865-edge   nvme0q1
 122:          0    8801994          0          0     ...         0   PCI-MSI 1572866-edge   nvme0q2
 145:          0          0          0          0     ...         0   PCI-MSI 524288-edge    enp129s0f0-TxRx-0
 146:  411920338          0          0          0     ...         0   PCI-MSI 524289-edge    enp129s0f0-TxRx-1
 NMI:       1204       1198       1201       1199     ...      1188   Non-maskable interrupts
 LOC:  982340112  981223401  983001229  982119844     ...  980112239   Local timer interrupts
```

Read it as five columns: **IRQ number**, per-CPU counters, **controller** (`IO-APIC`, `PCI-MSI`, `GICv3` on ARM), **trigger type**, **device name(s)**.

Interpretation notes that matter in production:

- `IO-APIC` lines are the legacy, shareable, pin-routed interrupts — these are the only ones where IRQ *sharing* is still a real concept.
- `PCI-MSI` / `PCI-MSIX` are message-signalled: the device DMAs a write to a magic address. They are **not shared**, are allocated per queue, and are why a modern NIC has one IRQ per RX/TX queue (`enp129s0f0-TxRx-N`).
- **A single non-zero column is the smoking gun.** Above, `nvme0q1` and `enp129s0f0-TxRx-1` are both pinned to CPU0/CPU1. That is either intentional pinning or a broken affinity setup collapsing all interrupt work onto one core.

**Affinity control** (a hex bitmask, or the friendlier list form):

```console
$ cat /proc/irq/146/smp_affinity_list
1
$ cat /proc/irq/146/smp_affinity
00000000,00000000,00000000,00000002
$ echo 34 | sudo tee /proc/irq/146/smp_affinity_list
34
$ cat /proc/irq/146/effective_affinity_list
34
```

Three traps:

1. `smp_affinity` is a *request*; `effective_affinity` is what the interrupt controller actually programmed. Always verify the `effective_` file.
2. Writing to some IRQs returns `EIO` — those are flagged `IRQF_NOBALANCING` (timer, cascade) and cannot be moved.
3. **`irqbalance` will overwrite you.** Either stop it, or ban CPUs from it:

```ini
# /etc/sysconfig/irqbalance   (RHEL family)  |  /etc/default/irqbalance (Debian family)
IRQBALANCE_BANNED_CPULIST=0-3,64-67
IRQBALANCE_ARGS="--policyscript=/usr/local/libexec/irq-policy.sh"
```

### 3.2 DMA — `/proc/dma`

```console
$ cat /proc/dma
 4: cascade
```

This is the honest state of the world: `/proc/dma` lists **ISA DMA channels only**. Since PCI, devices are **bus masters** — they perform DMA themselves, and the arbitration the ISA DMA controller used to do no longer exists. Expect one line (`4: cascade`) on any server built after ~2005; sound cards and floppy controllers were the last real occupants.

The modern equivalent of "which device can DMA where" is the **IOMMU**:

```console
$ ls /sys/kernel/iommu_groups/ | wc -l
143
$ for d in /sys/kernel/iommu_groups/47/devices/*; do echo "grp47: $(basename $d)"; done
grp47: 0000:81:00.0
grp47: 0000:81:00.1
$ lspci -s 81:00.0
81:00.0 Ethernet controller: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ (rev 02)
```

The IOMMU group is the **granularity of device assignment**. Both X710 ports share group 47, so you cannot pass one to a VM and keep the other on the host — you pass the whole group or nothing. This is a hard architectural constraint on any VFIO/PCI-passthrough design.

### 3.3 I/O ports and MMIO — `/proc/ioports`, `/proc/iomem`

```console
$ sudo cat /proc/ioports | head -8
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0064-0064 : keyboard
  0070-0071 : rtc0
  02f8-02ff : serial

$ sudo cat /proc/iomem | grep -A2 '81:00.0'
  38fff8000000-38fff8ffffff : 0000:81:00.0
    38fff8000000-38fff8ffffff : i40e
  38fff9000000-38fff900ffff : 0000:81:00.0
    38fff9000000-38fff900ffff : i40e
```

Two teaching points:

- Without `sudo`, both files show all-zero addresses. That is **kernel address hardening** (`kptr_restrict`), not a broken system. A very common false alarm.
- The nesting shows resource *ownership*: `0000:81:00.0` owns the BAR region, and the `i40e` driver has claimed it. A BAR with **no nested driver line** is an unclaimed device — the single fastest way to spot a missing driver.

### 3.4 Resource summary per device, straight from `sysfs`

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/resource | head -4
0x000038fff8000000 0x000038fff8ffffff 0x000000000014220c
0x0000000000000000 0x0000000000000000 0x0000000000000000
0x000038fff9000000 0x000038fff900ffff 0x000000000014220c
0x0000000000000000 0x0000000000000000 0x0000000000000000

$ cat /sys/bus/pci/devices/0000:81:00.0/{numa_node,irq,local_cpulist,current_link_speed,current_link_width}
1
0
32-63,96-127
16.0 GT/s PCIe
8
```

`numa_node: 1` and `local_cpulist: 32-63,96-127` are the two values that decide the incident from §1. `current_link_speed`/`current_link_width` catch the other classic: a x8 card negotiated down to x4 because it is in the wrong slot.

---

## 4. The PCI subsystem in depth — `lspci`

### 4.1 Addressing: the BDF (Bus:Device.Function) and the domain

`0000:81:00.1` = `domain:bus:device.function`. Domain (segment) is almost always `0000` on commodity x86; large systems and some ARM SoCs use multiple segments.

### 4.2 The one invocation to memorise

```console
$ lspci -nnk -s 81:00.
81:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0000]
	Kernel driver in use: i40e
	Kernel modules: i40e
81:00.1 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0000]
	Kernel driver in use: vfio-pci
	Kernel modules: i40e
```

- `-n` prints numeric **vendor:device** IDs — `[8086:1572]`. **Automate on these, never on the marketing name**, which changes with your `pci.ids` database version.
- `-k` prints the bound driver. The distinction between the two lines is doctrine:
  - **`Kernel driver in use:`** — what is bound *right now*.
  - **`Kernel modules:`** — what *could* bind, per `modules.alias`.
  - Function `.1` above is bound to `vfio-pci`, i.e. it has been handed to a VM or DPDK application.
  - **A device with a `Kernel modules:` line but no `Kernel driver in use:` line is your bug.** The module exists but did not bind — check `dmesg` for probe failure, firmware load failure, or a `blacklist`.

### 4.3 Topology and detail

```console
$ lspci -tv | head -12
-+-[0000:80]-+-00.0  Intel Corporation Device 0998
 |           +-01.0-[81]--+-00.0  Intel Corporation Ethernet Controller X710 for 10GbE SFP+
 |           |            \-00.1  Intel Corporation Ethernet Controller X710 for 10GbE SFP+
 |           \-04.0-[82]----00.0  Samsung Electronics Co Ltd NVMe SSD Controller PM9A3
 \-[0000:00]-+-00.0  Intel Corporation Device 0998
             +-1f.0  Intel Corporation C620 Series Chipset LPC Controller
             \-1f.4  Intel Corporation C620 Series Chipset SMBus

$ sudo lspci -vvv -s 81:00.0 | grep -E 'LnkCap|LnkSta|MaxPayload|NUMA|SR-IOV|Capabilities: .*(MSI|Vital)'
	Capabilities: [70] MSI-X: Enable+ Count=129 Masked-
		LnkCap:	Port #0, Speed 16GT/s, Width x8, ASPM not supported
		LnkSta:	Speed 16GT/s, Width x8
			MaxPayload 256 bytes, MaxReadReq 512 bytes
	Capabilities: [160] Single Root I/O Virtualization (SR-IOV)
```

The `[80]` root complex hosting bus `81` tells you this card is behind the **second socket's** PCIe root — consistent with `numa_node: 1`.

### 4.4 Enabling and disabling integrated peripherals — the Linux-side toolkit

The exam phrase "enable and disable integrated peripherals" is usually taught as "go into the BIOS". At fleet scale you cannot reboot 400 nodes into a firmware menu. The runtime equivalents:

| Goal | Mechanism | Command | Persistence |
|---|---|---|---|
| Detach driver, keep device | Driver `unbind` | `echo 0000:81:00.1 > /sys/bus/pci/drivers/i40e/unbind` | Runtime only |
| Attach a specific driver | Driver `bind` + `driver_override` | see below | Runtime only |
| Remove device from the bus | PCI hot-remove | `echo 1 > /sys/bus/pci/devices/0000:81:00.1/remove` | Until `rescan` |
| Bring devices back | Bus rescan | `echo 1 > /sys/bus/pci/rescan` | — |
| Prevent driver at boot | `modprobe.d` blacklist / `install` | `/etc/modprobe.d/*.conf` | **Persistent** |
| Prevent driver from cmdline | `module_blacklist=` | GRUB kernel line | **Persistent** |
| Persistent driver override | `driverctl` | `driverctl set-override 0000:81:00.1 vfio-pci` | **Persistent (udev-backed)** |
| Toggle firmware-level device | UEFI variable / vendor tool | `fwupdmgr`, `efivar`, vendor `smbios` driver | **Persistent** |
| USB port/device authorization | `authorized` attribute / USBGuard | `echo 0 > .../authorized` | Runtime (policy = persistent) |

```console
$ echo vfio-pci | sudo tee /sys/bus/pci/devices/0000:81:00.1/driver_override
vfio-pci
$ echo 0000:81:00.1 | sudo tee /sys/bus/pci/drivers/i40e/unbind
0000:81:00.1
$ echo 0000:81:00.1 | sudo tee /sys/bus/pci/drivers_probe
0000:81:00.1
$ lspci -nnk -s 81:00.1 | grep 'driver in use'
	Kernel driver in use: vfio-pci
```

`driverctl` wraps exactly this sequence and writes a udev rule under `/etc/udev/rules.d/80-driverctl.rules`, so the override survives reboot. Prefer it over hand-rolled `rc.local` hacks.

### 4.5 SR-IOV: turning one NIC into many

```console
$ cat /sys/class/net/enp129s0f0/device/sriov_totalvfs
64
$ cat /sys/class/net/enp129s0f0/device/sriov_numvfs
0
$ echo 8 | sudo tee /sys/class/net/enp129s0f0/device/sriov_numvfs
8
$ lspci -nn | grep -c 'Virtual Function'
8
$ ip link show enp129s0f0
6: enp129s0f0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc mq state UP mode DEFAULT group default qlen 1000
    link/ether 3c:fd:fe:a1:b2:c0 brd ff:ff:ff:ff:ff:ff
    vf 0     link/ether 00:00:00:00:00:00, spoof checking on, link-state auto, trust off
    vf 1     link/ether 00:00:00:00:00:00, spoof checking on, link-state auto, trust off
```

Hard rules: `sriov_numvfs` can only go `N → 0 → M`, never `N → M` directly (`EBUSY`); the platform must have `intel_iommu=on` (or `amd_iommu=on`) plus SR-IOV enabled in firmware; and VF MAC addresses of `00:00:00:00:00:00` are randomised per guest boot unless the PF explicitly assigns them (`ip link set enp129s0f0 vf 0 mac 52:54:00:aa:00:01`).

---

## 5. The USB subsystem — `lsusb` and device manipulation

### 5.1 Topology first

```console
$ lsusb -t
/:  Bus 04.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/2p, 10000M
/:  Bus 03.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 2: Dev 3, If 0, Class=Mass Storage, Driver=uas, 5000M
/:  Bus 02.Port 1: Dev 1, Class=root_hub, Driver=ehci-pci/2p, 480M
/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/12p, 480M
    |__ Port 5: Dev 2, If 0, Class=Human Interface Device, Driver=usbhid, 12M
    |__ Port 7: Dev 4, If 0, Class=Vendor Specific Class, Driver=ftdi_sio, 12M
```

- The trailing `5000M` / `480M` / `12M` is the **negotiated** speed, not the port's capability. `480M` on a device you bought as USB 3.x means it enumerated on the companion USB 2 controller — a bad cable, or the physical port is wired to the EHCI root hub.
- `Driver=uas` vs `Driver=usb-storage`: UAS (USB Attached SCSI) supports command queueing and is much faster, but a well-known list of bridge chipsets corrupts data under UAS. The mitigation is a **quirk**, covered in §6.4.

### 5.2 Identity and detail

```console
$ lsusb
Bus 003 Device 003: ID 0781:5583 SanDisk Corp. Ultra Fit
Bus 001 Device 004: ID 0403:6001 Future Technology Devices International, Ltd FT232 Serial (UART) IC
Bus 001 Device 002: ID 046d:c52b Logitech, Inc. Unifying Receiver

$ lsusb -v -d 0781:5583 2>/dev/null | grep -E 'idVendor|idProduct|iSerial|bcdUSB|bMaxPower'
  bcdUSB               3.00
  idVendor           0x0781 SanDisk Corp.
  idProduct          0x5583 Ultra Fit
  iSerial                 3 4C530001180919103454
  bMaxPower             504mA
```

`ID vvvv:pppp` is the USB analogue of the PCI `[8086:1572]`. `iSerial` is what makes a **per-device** udev rule possible (§7).

An underrated alternative that needs no `pci.ids`/`usb.ids` database and prints the raw descriptor set:

```console
$ usb-devices | sed -n '/SanDisk/,+3p'
S:  Manufacturer=USB
S:  Product=SanDisk 3.2Gen1
S:  SerialNumber=4C530001180919103454
C:  #Ifs= 1 Cfg#= 1 Atr=80 MxPwr=504mA
```

### 5.3 Manipulating USB devices at runtime

```console
# Power management: stop a flaky device from autosuspending
$ echo on | sudo tee /sys/bus/usb/devices/1-7/power/control
$ cat /sys/bus/usb/devices/1-7/power/autosuspend_delay_ms
2000

# Force a re-enumeration without physically unplugging
$ echo 0 | sudo tee /sys/bus/usb/devices/1-7/authorized
$ echo 1 | sudo tee /sys/bus/usb/devices/1-7/authorized

# Deny-by-default for a hardened host: nothing enumerates unless a rule allows it
$ echo 0 | sudo tee /sys/bus/usb/devices/usb1/authorized_default

# Unbind a single interface from its driver (note the "bus-port:config.interface" form)
$ echo 1-7:1.0 | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind
```

For an actual policy engine rather than one-off writes, `usbguard` consumes the same `authorized` mechanism and expresses it as rules:

```
# /etc/usbguard/rules.conf
allow id 046d:c52b serial "" name "USB Receiver" with-interface { 03:01:01 03:01:02 }
allow id 0781:5583 serial "4C530001180919103454"
reject with-interface all-of { 03:*:* 08:*:* }   # reject HID+storage combos (BadUSB shape)
block
```

---

## 6. Kernel modules — `lsmod`, `modinfo`, `modprobe`

### 6.1 What is loaded

```console
$ lsmod | head -6
Module                  Size  Used by
i40e                  569344  0
nvme                   61440  4
nvme_core             180224  5 nvme
vfio_pci               16384  1
mlx5_core            2039808  1 mlx5_ib
```

`lsmod` is a formatter for `/proc/modules`. **Column 3 (`Used by`) is a reference count** — a non-zero value is exactly why `modprobe -r` will refuse:

```console
$ sudo modprobe -r nvme_core
modprobe: FATAL: Module nvme_core is in use.
```

### 6.2 What a module *is*, before you load it

```console
$ modinfo i40e | head -14
filename:       /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.zst
version:        2.24.6
license:        GPL v2
description:    Intel(R) Ethernet Connection XL710 Network Driver
firmware:       i40e/i40e-e2-7.13.1.0.fw
srcversion:     6F3F1A9A6D5A0F1B0F0AA1C
alias:          pci:v00008086d0000158Bsv*sd*bc*sc*i*
alias:          pci:v00008086d00001572sv*sd*bc*sc*i*
depends:
retpoline:      Y
intree:         Y
name:           i40e
vermagic:       6.8.0-45-generic SMP preempt mod_unload modversions
sig_id:         PKCS#7
parm:           debug:Debug level (0=none,...,16=all), Debug mask (0x8XXXXXXX) (uint)
```

Line by line, the fields a platform engineer reads:

| Field | Why it matters |
|---|---|
| `filename` | `.ko.zst`/`.ko.xz` — compressed modules need matching `kmod` support |
| `firmware:` | The module needs a **blob from `/lib/firmware`**. Missing → probe fails silently at boot (§9.3) |
| `alias:` | The MODALIAS patterns that trigger autoload. `d00001572` ↔ `lspci -n` `[8086:1572]` |
| `depends:` | Dependency chain resolved by `modules.dep` |
| `vermagic:` | Must match `uname -r` exactly, or `insmod` fails with `Invalid module format` |
| `sig_id` | Under Secure Boot, an unsigned module gives `Required key not available` |
| `parm:` | The tunables you can set via `modprobe.d` or `/sys/module/<m>/parameters/` |

### 6.3 Autoload: how a PCI ID becomes a loaded driver

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/modalias
pci:v00008086d00001572sv00008086sd00000000bc02sc00i00

$ grep -m1 'd00001572' /lib/modules/$(uname -r)/modules.alias
alias pci:v00008086d00001572sv*sd*bc*sc*i* i40e

$ modprobe --show-depends i40e
insmod /lib/modules/6.8.0-45-generic/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.zst
```

The chain: kernel computes `MODALIAS` → uevent → `udev` rule `ENV{MODALIAS}=="?*", IMPORT{builtin}="kmod load $env{MODALIAS}"` → `modprobe` matches `modules.alias` → module loads → driver `probe()` binds.

`modules.alias` and `modules.dep` are **generated files**. After dropping in an out-of-tree `.ko`:

```console
$ sudo depmod -a
$ sudo modprobe my_driver
```

### 6.4 Persistent module configuration — `/etc/modprobe.d/`

```ini
# /etc/modprobe.d/10-platform-nic.conf
# Intel X710: hold interrupt coalescing constant across the fleet; the driver
# default varies by version and silently changes p99 latency after upgrades.
options i40e  debug=0

# Mellanox CX-5: pre-allocate the ODP/steering pool used by the CNI.
options mlx5_core  probe_vf=0

# Blacklist: prevents *alias-based autoload* only. It does NOT stop an
# explicit `modprobe nouveau`, nor a load pulled in as a dependency.
blacklist nouveau
blacklist nvidiafb

# The only reliable "never load this" for a module something else may depend on:
install nouveau /bin/false

# Load-order dependency: guarantee vfio_iommu_type1 has allow_unsafe_interrupts
# before vfio-pci grabs anything.
options vfio_iommu_type1 allow_unsafe_interrupts=0
softdep vfio-pci pre: vfio_iommu_type1

# UAS quirk for a known-bad USB bridge (vendor:product:flags, u = ignore UAS)
options usb-storage quirks=174c:55aa:u
```

```ini
# /etc/modules-load.d/platform.conf — load at boot even with no matching device
br_netfilter
overlay
nf_conntrack
vfio-pci
```

Two more persistence layers, in increasing order of "applies earlier":

```console
# 3. Kernel command line (applies before initramfs userspace):
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.8.0-45-generic root=UUID=... ro intel_iommu=on iommu=pt \
  module_blacklist=nouveau default_hugepagesz=1G hugepagesz=1G hugepages=16 \
  isolcpus=4-31,68-95 nohz_full=4-31,68-95 rcu_nocbs=4-31,68-95

# 4. Rebuild the initramfs after ANY modprobe.d change that affects boot-time drivers:
$ sudo dracut --force                    # RHEL/Fedora/SUSE
$ sudo update-initramfs -u -k all        # Debian/Ubuntu
```

> **The single most common "my `modprobe.d` change did nothing" cause:** the module is loaded from the **initramfs**, which has its own frozen copy of `/etc/modprobe.d`. Change the file, forget the rebuild, and the setting only applies to modules loaded after pivot-root.

### 6.5 Runtime parameter inspection

```console
$ ls /sys/module/nvme_core/parameters/
admin_timeout  apst_primary_latency_tol_us  default_ps_max_latency_us  io_timeout  multipath  shutdown_timeout
$ cat /sys/module/nvme_core/parameters/io_timeout
30
$ cat /sys/module/nvme_core/parameters/multipath
Y
```

Parameters with mode `0644` are writable at runtime; `0444` ones require unload/reload or a kernel cmdline entry.

---

## 7. `udev` — making non-deterministic hardware deterministic

### 7.1 The architectural role

`systemd-udevd` is the userspace half of the device model. It receives kernel uevents over netlink and, per rule set, does five things: **load modules, name interfaces, create symlinks, set ownership/permissions, and tag devices** (which is how systemd device units like `dev-disk-by\x2duuid-....device` come to exist).

Rules live in three directories, **merged and processed in lexical order of filename across all three**:

| Directory | Owner | Precedence |
|---|---|---|
| `/usr/lib/udev/rules.d/` | distribution packages | lowest |
| `/run/udev/rules.d/` | runtime/volatile | middle |
| `/etc/udev/rules.d/` | **you** | highest — a same-named file here *masks* the vendor one entirely |

### 7.2 Rule grammar

```
<match-key><op><value>, ... , <assign-key><op><value>, ...
```

| Operator | Meaning |
|---|---|
| `==` | match, equal |
| `!=` | match, not equal |
| `=` | assign |
| `+=` | append to a list (`SYMLINK`, `TAG`, `RUN`) |
| `-=` | remove from a list |
| `:=` | assign **final** — later rules cannot change it |

| Key | Matches |
|---|---|
| `ACTION` | `add`, `remove`, `change`, `bind`, `unbind` |
| `SUBSYSTEM` / `SUBSYSTEMS` | this device's / any ancestor's subsystem |
| `KERNEL` / `KERNELS` | this device's / any ancestor's kernel name |
| `DRIVER` / `DRIVERS` | this device's / any ancestor's driver |
| `ATTR{x}` / `ATTRS{x}` | this device's / any ancestor's sysfs attribute |
| `ENV{x}` | uevent/imported environment variable |
| `TAG` / `TAGS` | udev tag |
| `PROGRAM`, `IMPORT{program|builtin|db|file}` | run a helper, import its output |

| Assignment | Effect |
|---|---|
| `NAME` | **Network interfaces only.** Renaming block devices via `NAME` is unsupported and breaks systems |
| `SYMLINK+=` | Extra `/dev/...` path — the correct way to give a disk a stable name |
| `OWNER`, `GROUP`, `MODE` | Node permissions |
| `RUN{program}+=` | Run a **short, non-blocking** program (udev kills long-running children) |
| `TAG+=`, `ENV{x}=` | Metadata for systemd/consumers |

### 7.3 A complete, production-shaped rule set

```bash
# /etc/udev/rules.d/70-platform-hardware.rules
#
# Fleet-wide deterministic hardware policy for cn-* nodes.
# Filename prefix 70 = after the distro's persistent-naming rules (60-*),
# before systemd's device-tagging rules (99-*).

# ---------------------------------------------------------------------------
# 1. Stable symlink for the dedicated etcd NVMe, identified by its serial.
#    /dev/nvme0n1 vs /dev/nvme1n1 flips with PCIe enumeration order after a
#    firmware update; the serial does not.
# ---------------------------------------------------------------------------
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme*n1", \
  ATTRS{serial}=="S6EUNJ0R500123", \
  SYMLINK+="disk/by-role/etcd-data", \
  ENV{PLATFORM_ROLE}="etcd"

# ---------------------------------------------------------------------------
# 2. I/O scheduler + read-ahead per media type. Rotational disks get bfq,
#    NVMe gets none (the device does its own queueing).
# ---------------------------------------------------------------------------
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", \
  ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", \
  ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023"

# ---------------------------------------------------------------------------
# 3. Data-plane NIC: jumbo frames + ring sizes at enumeration time, so the
#    setting exists before the CNI or DPDK app opens the interface.
#    RUN executes in udev's context: keep it fast, absolute paths only.
# ---------------------------------------------------------------------------
ACTION=="add", SUBSYSTEM=="net", ATTRS{vendor}=="0x8086", ATTRS{device}=="0x1572", \
  ENV{PLATFORM_NIC}="x710", \
  RUN+="/usr/sbin/ip link set %k mtu 9000", \
  RUN+="/usr/local/libexec/nic-ring-tune %k"

# ---------------------------------------------------------------------------
# 4. FTDI serial console adapters: stable path per physical USB port, so a
#    rack's console cabling survives a reboot. by-path, not by-serial —
#    adapters are replaced, the port is not.
# ---------------------------------------------------------------------------
SUBSYSTEM=="tty", SUBSYSTEMS=="usb", DRIVERS=="ftdi_sio", \
  ATTRS{devpath}=="7", SYMLINK+="console/rack-a-tor", \
  GROUP="dialout", MODE="0660"

# ---------------------------------------------------------------------------
# 5. Hand the second X710 port to vfio-pci as soon as it binds. Uses the
#    'bind' action so it fires on hotplug and rescan too, not just boot.
# ---------------------------------------------------------------------------
ACTION=="bind", SUBSYSTEM=="pci", KERNEL=="0000:81:00.1", \
  RUN+="/usr/bin/driverctl --nosave set-override 0000:81:00.1 vfio-pci"

# ---------------------------------------------------------------------------
# 6. Expose GPUs to the container runtime's supplementary group, no 0666.
# ---------------------------------------------------------------------------
SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0660", TAG+="uaccess"

# ---------------------------------------------------------------------------
# 7. Security: any newly attached USB mass-storage device on a control-plane
#    node is left unauthorized; an operator must authorize it explicitly.
# ---------------------------------------------------------------------------
ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:08????:*", \
  ATTR{authorized}="0", \
  RUN+="/usr/bin/logger -t udev-policy -p auth.warning USB storage %k blocked: $env{ID_VENDOR_ID}:$env{ID_MODEL_ID}"
```

### 7.4 Predictable network interface names — the `.link` layer

Interface naming is **not** a plain udev rule any more; it is the `net_setup_link` builtin driven by `systemd.link` files.

```console
$ udevadm info /sys/class/net/enp129s0f0 | grep -E 'ID_NET_NAME'
E: ID_NET_NAME_MAC=enx3cfdfea1b2c0
E: ID_NET_NAME_PATH=enp129s0f0
E: ID_NET_NAME_SLOT=ens2f0
```

The naming scheme picks the first available of: `ID_NET_NAME_FROM_DATABASE` → `ONBOARD` → `SLOT` → `PATH` → `MAC`. To override:

```ini
# /etc/systemd/network/10-dataplane0.link
[Match]
MACAddress=3c:fd:fe:a1:b2:c0

[Link]
Name=dataplane0
MTUBytes=9000
```

> **Naming trap:** never assign a name in the kernel's own namespace (`eth0`, `wlan0`). The kernel may create a device with that name concurrently and the rename races, leaving the interface stuck as `rename3`. Use a prefix the kernel never generates.

To disable predictable naming entirely (legacy appliance images only): add `net.ifnames=0 biosdevname=0` to the kernel cmdline.

### 7.5 The `udevadm` debugging workflow — the exam's real content

```console
# (a) What does udev believe about this device, right now?
$ udevadm info --query=all --name=/dev/nvme0n1
P: /devices/pci0000:80/0000:80:04.0/0000:82:00.0/nvme/nvme0/nvme0n1
N: nvme0n1
L: 0
S: disk/by-id/nvme-SAMSUNG_MZQL21T9HCJR-00A07_S6EUNJ0R500123
S: disk/by-role/etcd-data
E: DEVLINKS=/dev/disk/by-id/nvme-... /dev/disk/by-role/etcd-data
E: DEVNAME=/dev/nvme0n1
E: ID_SERIAL_SHORT=S6EUNJ0R500123
E: PLATFORM_ROLE=etcd

# (b) Which ATTRS{} can I match on, and at which level of the parent chain?
$ udevadm info -a -n /dev/nvme0n1 | head -22
  looking at device '/devices/pci0000:80/.../nvme/nvme0/nvme0n1':
    KERNEL=="nvme0n1"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{queue/rotational}=="0"
    ATTR{size}=="3750748848"

  looking at parent device '/devices/pci0000:80/.../nvme/nvme0':
    KERNELS=="nvme0"
    SUBSYSTEMS=="nvme"
    ATTRS{model}=="SAMSUNG MZQL21T9HCJR-00A07"
    ATTRS{serial}=="S6EUNJ0R500123"
    ATTRS{firmware_rev}=="GDC5302Q"
```
> **The rule that catches everyone:** all `ATTRS{}` in a single rule must match **one single parent device**. You cannot combine `ATTRS{serial}` from the NVMe controller with `ATTRS{vendor}` from the PCI bridge in the same rule.

```console
# (c) Dry-run the rule set against an existing device — no reboot, no replug.
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E '70-platform|DEVLINK'
Reading rules file: /etc/udev/rules.d/70-platform-hardware.rules
/etc/udev/rules.d/70-platform-hardware.rules:14 Adding link 'disk/by-role/etcd-data'
DEVLINKS=/dev/disk/by-id/nvme-... /dev/disk/by-role/etcd-data

# (d) Watch events live. KERNEL: = raw netlink. UDEV: = after rules ran.
#     A KERNEL line with no matching UDEV line = udevd failed or timed out.
$ udevadm monitor --udev --property --subsystem-match=block
monitor will print the received events for:
UDEV - the event which udev sends out after rule processing

UDEV  [18244.512901] add      /devices/pci0000:00/.../block/sdb (block)
ACTION=add
DEVNAME=/dev/sdb
ID_BUS=usb
ID_SERIAL=SanDisk_Ultra_Fit_4C530001180919103454-0:0

# (e) Reload rules and re-apply to devices already present (coldplug).
$ sudo udevadm control --reload
$ sudo udevadm trigger --action=change --subsystem-match=block
$ sudo udevadm settle --timeout=30

# (f) Verbose logging while reproducing a failure.
$ sudo udevadm control --log-priority=debug
$ journalctl -u systemd-udevd -f
$ sudo udevadm control --log-priority=info
```

`udevadm trigger` is how you replay the boot-time coldplug without rebooting. `udevadm settle` is the correct synchronisation primitive in provisioning scripts — never `sleep`.

### 7.6 `dbus` — where the device model meets applications

`udev` talks **netlink**; it does not use D-Bus. D-Bus enters one layer above: daemons consume udev events and re-publish device state on the **system bus** as objects with introspectable interfaces, so unprivileged applications get a policy-mediated, high-level view instead of raw `/sys` access.

| Layer | Transport | Consumer | Example |
|---|---|---|---|
| Kernel → udevd | netlink uevent | `systemd-udevd` | `add /devices/.../block/sdb` |
| udevd → libudev clients | `/run/udev` database + netlink | `udisksd`, `NetworkManager`, `upowerd` | `ID_FS_UUID=...` |
| Daemon → applications | **D-Bus system bus** | file managers, desktops, `virt-manager`, monitoring agents | `org.freedesktop.UDisks2.Filesystem.Mount()` |

```console
$ busctl --system list | grep -E 'UDisks2|UPower|NetworkManager'
org.freedesktop.NetworkManager   1184 NetworkManager  root  :1.11  ...
org.freedesktop.UDisks2          1402 udisksd         root  :1.31  ...
org.freedesktop.UPower           1455 upowerd         root  :1.38  ...

$ busctl --system introspect org.freedesktop.UDisks2 \
    /org/freedesktop/UDisks2/block_devices/nvme0n1 org.freedesktop.UDisks2.Block \
  | grep -E 'Size|IdUUID|IdType'
.IdType         property  s   "xfs"          emits-change
.IdUUID         property  s   "8f3c...e21a"  emits-change
.Size           property  t   1920383410176  emits-change

$ gdbus call --system --dest org.freedesktop.UPower \
    --object-path /org/freedesktop/UPower \
    --method org.freedesktop.DBus.Properties.Get org.freedesktop.UPower OnBattery
(<false>,)
```

Conceptually for the exam: **`sysfs` is the kernel's device model; `udev` is the userspace policy engine that reacts to it; `dbus` is the IPC bus over which higher-level services expose that hardware to applications.**

---

## 8. Mass storage device types — differentiating them correctly

```console
$ lsblk -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL,SERIAL,MOUNTPOINTS
NAME        TYPE  SIZE ROTA TRAN   MODEL                     SERIAL           MOUNTPOINTS
nvme0n1     disk  1.8T    0 nvme   SAMSUNG MZQL21T9HCJR-00A07 S6EUNJ0R500123
├─nvme0n1p1 part  512M    0                                                   /boot/efi
└─nvme0n1p2 part  1.7T    0
  └─vg0-root lvm  200G    0                                                   /
sda         disk  7.3T    1 sas    ST8000NM0055-1RM112       ZA1FG7HX
sdb         disk   28G    0 usb    Ultra Fit                 4C530001180919103454
vda         disk   40G    0                                                   
```

| Type | Kernel names | Driver stack | Distinguishing traits |
|---|---|---|---|
| **PATA/IDE (legacy)** | historically `/dev/hd[a-d]` | `ide-*` (removed) → **`libata`** | Modern kernels present PATA disks as `/dev/sd*`. `/dev/hd*` on a current system means an emulated legacy controller |
| **SATA/AHCI** | `/dev/sd[a-z]` | `ahci` → `libata` → SCSI midlayer | Appears as SCSI because libata translates ATA into SCSI commands. `TRAN=sata` |
| **SAS / parallel SCSI** | `/dev/sd*` | `mpt3sas`, `megaraid_sas`, `smartpqi` | Dual-ported, expander topologies; `lsscsi -t` shows `sas:0x5000...` |
| **NVMe (PCIe)** | `/dev/nvme<ctrl>n<ns>p<part>` | `nvme` + `nvme_core` — **no SCSI layer** | Namespaces, not LUNs. Multiple queues, one per CPU. Never `/dev/sd*` |
| **NVMe over Fabrics** | same naming | `nvme_tcp`, `nvme_rdma`, `nvme_fc` | `nvme list-subsys` shows the transport; behaves as local NVMe |
| **USB mass storage** | `/dev/sd*` | `usb-storage` (BOT) or `uas` (queued) | `TRAN=usb`. UAS is faster but quirk-prone |
| **virtio-blk** | `/dev/vd[a-z]` | `virtio_blk` | Paravirtual; no SCSI translation, minimal overhead |
| **virtio-scsi** | `/dev/sd*` | `virtio_scsi` | Paravirtual but SCSI-compatible: supports passthrough, >26 devices, TRIM |
| **MMC/SD/eMMC** | `/dev/mmcblk<N>p<M>`, `/dev/mmcblk<N>boot0` | `mmc_block` | Dominant on ARM/embedded; separate boot partitions |
| **Device mapper** | `/dev/dm-<N>` + `/dev/mapper/<name>` | `dm-*` | LVM, LUKS, multipath — **virtual**; `/dev/dm-N` numbering is unstable, always use `/dev/mapper/` |
| **MD RAID** | `/dev/md<N>` | `md` | `/proc/mdstat` is the status file |
| **Loop / zram / nbd** | `/dev/loop<N>`, `/dev/zram<N>`, `/dev/nbd<N>` | `loop`, `zram`, `nbd` | Backed by files, RAM or network |

The stability contract:

```console
$ ls -l /dev/disk/
by-diskseq  by-id  by-label  by-partlabel  by-partuuid  by-path  by-uuid

$ ls -l /dev/disk/by-id/ | grep nvme0n1$
lrwxrwxrwx 1 root root 13 Aug 25 09:14 nvme-SAMSUNG_MZQL21T9HCJR-00A07_S6EUNJ0R500123 -> ../../nvme0n1
lrwxrwxrwx 1 root root 13 Aug 25 09:14 nvme-eui.343550304d3001230025384500000001 -> ../../nvme0n1

$ blkid /dev/nvme0n1p2
/dev/nvme0n1p2: UUID="8f3c1c0e-1a2b-4c3d-9e8f-0a1b2c3d4e5f" TYPE="LVM2_member" PARTUUID="a1b2c3d4-02"
```

| Identifier | Stable across | Breaks when |
|---|---|---|
| `/dev/sdX` | **nothing** | any enumeration change |
| `by-path` | drive replacement (identifies the **slot**) | recabling, controller change |
| `by-id` | recabling, reboot (identifies the **drive**) | drive replacement |
| `by-uuid` / `by-label` | everything on that filesystem | reformat, `dd` clone (duplicate UUIDs!) |
| `by-partuuid` | filesystem recreation | repartitioning |

**Use `by-uuid` in `/etc/fstab`, `by-path` for slot-based hot-swap automation, `by-id` for role-pinned devices.** Never `/dev/sdX` in persistent configuration.

---

## 9. Inventory tooling: CPU, memory, firmware, virtualization

### 9.1 CPU and NUMA

```console
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         46 bits physical, 57 bits virtual
  Byte Order:            Little Endian
CPU(s):                  128
  On-line CPU(s) list:   0-127
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
    CPU family:          6
    Model:               106
    Thread(s) per core:  2
    Core(s) per socket:  32
    Socket(s):           2
    Stepping:            6
    CPU max MHz:         3200.0000
    CPU min MHz:         800.0000
Caches (sum of all):
  L1d:                   3 MiB (64 instances)
  L1i:                   2 MiB (64 instances)
  L2:                    80 MiB (64 instances)
  L3:                    96 MiB (2 instances)
NUMA:
  NUMA node(s):          2
  NUMA node0 CPU(s):     0-31,64-95
  NUMA node1 CPU(s):     32-63,96-127
Vulnerabilities:
  Spectre v2:            Mitigation; Enhanced / Automatic IBRS; IBPB conditional; ...

$ numactl -H
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 ... 95
node 0 size: 257698 MB
node 0 free: 198334 MB
node 1 cpus: 32 33 ... 127
node 1 size: 257981 MB
node 1 free: 201002 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10
```

`node distances` of `21` means a cross-socket access costs ~2.1× a local one. That number is the entire justification for NUMA-aware pinning.

```console
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
performance
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
intel_pstate
$ cat /sys/devices/system/cpu/vulnerabilities/spectre_v2
Mitigation: Enhanced / Automatic IBRS; IBPB: conditional; RSB filling; PBRSB-eIBRS: SW sequence
$ cat /sys/devices/system/cpu/smt/active
1
```

### 9.2 Firmware inventory — SMBIOS/DMI

```console
$ sudo dmidecode -s system-manufacturer
Dell Inc.
$ sudo dmidecode -s system-product-name
PowerEdge R750
$ sudo dmidecode -s system-serial-number
7QK4XM3
$ sudo dmidecode -s bios-version
1.13.2

$ sudo dmidecode -t 17 | grep -A6 'Memory Device' | head -12
Memory Device
	Array Handle: 0x1000
	Size: 32 GB
	Form Factor: DIMM
	Locator: A1
	Bank Locator: Not Specified
	Type: DDR4
	Speed: 3200 MT/s
	Manufacturer: Samsung
	Serial Number: 4A2C81F0
	Rank: 2
	Configured Memory Speed: 3200 MT/s
```

`Configured Memory Speed` below `Speed` means the memory controller downclocked the DIMMs — a mixed-DIMM population or an under-provisioned voltage regulator. It costs measurable bandwidth and never shows up in application metrics.

For unprivileged access to the same identity data (safe in containers and for monitoring agents):

```console
$ cat /sys/class/dmi/id/{sys_vendor,product_name,board_name,bios_version,chassis_asset_tag}
Dell Inc.
PowerEdge R750
0PJ80M
1.13.2
RACK-A-U14
```

### 9.3 Am I on real hardware?

```console
$ systemd-detect-virt
none
$ sudo virt-what
$ # (empty output = bare metal)

# On a guest:
$ systemd-detect-virt
kvm
$ sudo virt-what
kvm
$ sudo dmidecode -s system-product-name
KVM
```

Any provisioning role that touches IRQ affinity, hugepages or SR-IOV must gate on this. Those knobs are meaningless or harmful in a guest.

### 9.4 Whole-machine views

```console
$ sudo lshw -class network -businfo
Bus info          Device      Class          Description
========================================================
pci@0000:81:00.0  enp129s0f0  network        Ethernet Controller X710 for 10GbE SFP+
pci@0000:81:00.1              network        Ethernet Controller X710 for 10GbE SFP+
pci@0000:01:00.0  eno1        network        NetXtreme BCM5720 Gigabit Ethernet PCIe

$ sudo lshw -short -class memory -class processor
H/W path        Device  Class       Description
===============================================
/0/0                    memory      64KiB BIOS
/0/400                  processor   Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
/0/1000                 memory      512GiB System Memory
```

`hwinfo --short` (SUSE-centric) and `inxi -Fxz` (desktop-centric) cover the same ground; `lshw` is the portable choice for scripting because of `lshw -json`.

---

## 10. Infrastructure as code: making hardware settings reproducible

Everything above is a one-off `echo` into `sysfs` — which survives exactly until the next reboot. Below is the persistence layer.

### 10.1 Ansible role — baseline hardware configuration

```yaml
---
# roles/hardware-baseline/tasks/main.yml
# Applies the fleet's hardware contract. Idempotent; safe to re-run.

- name: Collect virtualization type
  ansible.builtin.command: systemd-detect-virt
  register: virt_type
  changed_when: false
  failed_when: false

- name: Set bare-metal fact
  ansible.builtin.set_fact:
    is_bare_metal: "{{ virt_type.stdout | trim == 'none' }}"

- name: Assert the node matches the expected hardware SKU
  ansible.builtin.assert:
    that:
      - ansible_facts['product_name'] in allowed_skus
      - ansible_facts['processor_count'] | int == expected_sockets
    fail_msg: >-
      Node {{ inventory_hostname }} reports SKU '{{ ansible_facts['product_name'] }}'
      with {{ ansible_facts['processor_count'] }} socket(s); the platform contract
      requires one of {{ allowed_skus }} with {{ expected_sockets }} socket(s).
    quiet: true

# ---------------------------------------------------------------------------
# Kernel modules
# ---------------------------------------------------------------------------
- name: Install modprobe.d policy
  ansible.builtin.copy:
    dest: /etc/modprobe.d/10-platform.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - roles/hardware-baseline. Do not edit by hand.
      options i40e debug=0
      softdep vfio-pci pre: vfio_iommu_type1
      install nouveau /bin/false
      blacklist nvidiafb
  notify:
    - Rebuild initramfs

- name: Load platform modules at boot
  ansible.builtin.copy:
    dest: /etc/modules-load.d/platform.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      br_netfilter
      overlay
      nf_conntrack
      {{ 'vfio-pci' if is_bare_metal else '' }}
  notify:
    - Reload systemd-modules-load

- name: Ensure modules are loaded now
  community.general.modprobe:
    name: "{{ item }}"
    state: present
    persistent: present
  loop:
    - br_netfilter
    - overlay
    - nf_conntrack

# ---------------------------------------------------------------------------
# udev rules
# ---------------------------------------------------------------------------
- name: Install udev hardware policy
  ansible.builtin.template:
    src: 70-platform-hardware.rules.j2
    dest: /etc/udev/rules.d/70-platform-hardware.rules
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/udevadm verify %s"
  notify:
    - Reload udev rules

# ---------------------------------------------------------------------------
# Kernel command line (GRUB2)
# ---------------------------------------------------------------------------
- name: Configure kernel command line
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: >-
      GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt
      default_hugepagesz=1G hugepagesz=1G hugepages={{ hugepages_1g }}
      module_blacklist=nouveau
      isolcpus={{ isolated_cpus }} nohz_full={{ isolated_cpus }} rcu_nocbs={{ isolated_cpus }}"
    backup: true
  when: is_bare_metal
  notify:
    - Regenerate grub config

# ---------------------------------------------------------------------------
# SR-IOV: declarative, applied at every boot by a systemd unit
# ---------------------------------------------------------------------------
- name: Install SR-IOV VF provisioning unit
  ansible.builtin.template:
    src: sriov-vfs@.service.j2
    dest: /etc/systemd/system/sriov-vfs@.service
    owner: root
    group: root
    mode: "0644"
  when: is_bare_metal and sriov_pfs | length > 0
  notify:
    - Reload systemd

- name: Enable SR-IOV provisioning per PF
  ansible.builtin.systemd_service:
    name: "sriov-vfs@{{ item.pf }}.service"
    enabled: true
    state: started
    daemon_reload: true
  loop: "{{ sriov_pfs }}"
  when: is_bare_metal

# ---------------------------------------------------------------------------
# Verification: prove the contract holds, do not assume it
# ---------------------------------------------------------------------------
- name: Verify IOMMU is active
  ansible.builtin.stat:
    path: /sys/kernel/iommu_groups/0
  register: iommu_grp
  when: is_bare_metal

- name: Fail if IOMMU is inactive despite the kernel parameter
  ansible.builtin.fail:
    msg: >-
      intel_iommu=on is on the kernel cmdline but /sys/kernel/iommu_groups is
      empty. VT-d is disabled in firmware on {{ inventory_hostname }}.
  when:
    - is_bare_metal
    - not iommu_grp.stat.exists
    - "'intel_iommu=on' in ansible_facts['cmdline'] | default({}) | string"

- name: Verify hugepage reservation actually succeeded
  ansible.builtin.slurp:
    src: /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
  register: hp
  when: is_bare_metal

- name: Fail on partial hugepage reservation
  ansible.builtin.fail:
    msg: >-
      Requested {{ hugepages_1g }} x 1GiB hugepages, kernel reserved
      {{ hp.content | b64decode | trim }}. Memory is too fragmented, or the
      cmdline change has not been applied (reboot pending).
  when:
    - is_bare_metal
    - (hp.content | b64decode | trim | int) != (hugepages_1g | int)
```

```yaml
---
# roles/hardware-baseline/handlers/main.yml
- name: Rebuild initramfs
  ansible.builtin.command: >-
    {{ 'dracut --force --regenerate-all'
       if ansible_facts['os_family'] in ['RedHat', 'Suse']
       else 'update-initramfs -u -k all' }}
  changed_when: true

- name: Reload systemd-modules-load
  ansible.builtin.systemd_service:
    name: systemd-modules-load.service
    state: restarted

- name: Reload udev rules
  ansible.builtin.shell: |
    set -euo pipefail
    udevadm control --reload
    udevadm trigger --action=change --subsystem-match=block --subsystem-match=net
    udevadm settle --timeout=60
  args:
    executable: /bin/bash
  changed_when: true

- name: Regenerate grub config
  ansible.builtin.command: >-
    {{ 'grub2-mkconfig -o /boot/grub2/grub.cfg'
       if ansible_facts['os_family'] == 'RedHat'
       else 'update-grub' }}
  changed_when: true

- name: Reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```yaml
---
# roles/hardware-baseline/defaults/main.yml
allowed_skus:
  - PowerEdge R750
  - PowerEdge R650
expected_sockets: 2
hugepages_1g: 16
isolated_cpus: "4-31,68-95"
sriov_pfs:
  - pf: enp129s0f0
    numvfs: 8
```

```ini
# roles/hardware-baseline/templates/sriov-vfs@.service.j2
# Declarative SR-IOV VF creation. Instance name = the PF interface.
[Unit]
Description=Create SR-IOV VFs on %i
After=sys-subsystem-net-devices-%i.device network-pre.target
Wants=sys-subsystem-net-devices-%i.device
Before=network.target kubelet.service
ConditionPathExists=/sys/class/net/%i/device/sriov_totalvfs

[Service]
Type=oneshot
RemainAfterExit=yes
# numvfs can only transition N -> 0 -> M; always drain first.
ExecStart=/bin/sh -c 'echo 0 > /sys/class/net/%i/device/sriov_numvfs'
ExecStart=/bin/sh -c 'echo {{ sriov_pfs | selectattr("pf", "equalto", "%i") | map(attribute="numvfs") | first | default(0) }} > /sys/class/net/%i/device/sriov_numvfs'
ExecStart=/bin/sh -c 'for i in $(seq 0 7); do /usr/sbin/ip link set %i vf $i spoofchk on trust off state auto || true; done'
ExecStop=/bin/sh -c 'echo 0 > /sys/class/net/%i/device/sriov_numvfs'

[Install]
WantedBy=multi-user.target
```

### 10.2 `cloud-init` — the same contract at first boot

```yaml
#cloud-config
# Applied at first boot on cn-* worker nodes.

write_files:
  - path: /etc/modprobe.d/10-platform.conf
    owner: root:root
    permissions: "0644"
    content: |
      options i40e debug=0
      softdep vfio-pci pre: vfio_iommu_type1
      install nouveau /bin/false

  - path: /etc/modules-load.d/platform.conf
    owner: root:root
    permissions: "0644"
    content: |
      br_netfilter
      overlay
      vfio-pci

  - path: /etc/udev/rules.d/70-platform-hardware.rules
    owner: root:root
    permissions: "0644"
    content: |
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", \
        ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023"
      ACTION=="add", SUBSYSTEM=="net", ATTRS{vendor}=="0x8086", ATTRS{device}=="0x1572", \
        RUN+="/usr/sbin/ip link set %k mtu 9000"

  - path: /etc/systemd/network/10-dataplane0.link
    owner: root:root
    permissions: "0644"
    content: |
      [Match]
      Property=ID_NET_NAME_PATH=enp129s0f0

      [Link]
      Name=dataplane0
      MTUBytes=9000

bootcmd:
  # bootcmd runs on EVERY boot, before the network comes up.
  - [ sh, -c, "echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor || true" ]

runcmd:
  - [ udevadm, control, --reload ]
  - [ udevadm, trigger, --action=change ]
  - [ udevadm, settle, --timeout=60 ]
  - [ dracut, --force ]
  - [ sh, -c, "sed -i 's/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=16 /' /etc/default/grub" ]
  - [ grub2-mkconfig, -o, /boot/grub2/grub.cfg ]

power_state:
  mode: reboot
  message: "Rebooting to apply hardware baseline (IOMMU + hugepages)"
  condition: true
```

### 10.3 Exposing hardware to Kubernetes

Once the node is configured, the scheduler still knows nothing. Three manifests close that gap.

**(a) Node Feature Discovery — turn PCI IDs into node labels:**

```yaml
---
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: platform-hardware-baseline
spec:
  rules:
    # Label nodes carrying an Intel X710 data-plane NIC.
    - name: "intel-x710-nic"
      labels:
        platform.example.com/nic: "x710"
        platform.example.com/dataplane: "true"
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["8086"]}
            device: {op: In, value: ["1572", "1583", "1584", "1581"]}

    # Label nodes whose CPUs expose the instruction sets our runtime needs.
    - name: "avx512-capable"
      labels:
        platform.example.com/simd: "avx512"
      matchFeatures:
        - feature: cpu.cpuid
          matchExpressions:
            AVX512F: {op: Exists}
            AVX512DQ: {op: Exists}

    # Taint-driver pairing: nodes with an active IOMMU can host VFIO workloads.
    - name: "iommu-enabled"
      labels:
        platform.example.com/iommu: "enabled"
      matchFeatures:
        - feature: kernel.config
          matchExpressions:
            INTEL_IOMMU: {op: In, value: ["y"]}
        - feature: system.osrelease
          matchExpressions:
            ID: {op: In, value: ["rhel", "centos", "rocky", "ubuntu"]}

    # Composite rule: only nodes that have BOTH the NIC and 1GiB hugepages.
    - name: "dpdk-ready"
      labels:
        platform.example.com/dpdk: "ready"
      matchFeatures:
        - feature: pci.device
          matchExpressions:
            vendor: {op: In, value: ["8086"]}
            class: {op: In, value: ["0200"]}
        - feature: memory.nv
          matchExpressions:
            devtype: {op: Exists}
      matchAny:
        - matchFeatures:
            - feature: kernel.version
              matchExpressions:
                major: {op: Gt, value: ["5"]}
```

**(b) SR-IOV device plugin — turn VFs into a schedulable resource:**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriovdp-config
  namespace: kube-system
data:
  config.json: |
    {
      "resourceList": [
        {
          "resourceName": "intel_sriov_netdevice",
          "resourcePrefix": "platform.example.com",
          "selectors": {
            "vendors": ["8086"],
            "devices": ["154c", "1889"],
            "drivers": ["iavf", "i40evf"],
            "pfNames": ["enp129s0f0#0-7"],
            "isRdma": false
          }
        },
        {
          "resourceName": "intel_sriov_dpdk",
          "resourcePrefix": "platform.example.com",
          "selectors": {
            "vendors": ["8086"],
            "devices": ["154c"],
            "drivers": ["vfio-pci"],
            "pfNames": ["enp129s0f1#0-7"]
          }
        }
      ]
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sriov-device-plugin
  namespace: kube-system
  labels:
    app.kubernetes.io/name: sriov-device-plugin
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sriov-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sriov-device-plugin
    spec:
      # Only land on nodes NFD has already confirmed carry the hardware.
      nodeSelector:
        platform.example.com/nic: "x710"
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
          effect: NoSchedule
      serviceAccountName: sriov-device-plugin
      containers:
        - name: kube-sriovdp
          image: ghcr.io/k8snetworkplumbingwg/sriov-network-device-plugin:v3.7.0
          imagePullPolicy: IfNotPresent
          args:
            - --log-dir=sriovdp
            - --log-level=10
            - --resource-prefix=platform.example.com
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          volumeMounts:
            - name: devicesock
              mountPath: /var/lib/kubelet/device-plugins
            - name: plugins-registry
              mountPath: /var/lib/kubelet/plugins_registry
            - name: log
              mountPath: /var/log
            - name: config-volume
              mountPath: /etc/pcidp
              readOnly: true
            - name: device-info
              mountPath: /var/run/k8s.cni.cncf.io/devinfo/dp
      volumes:
        - name: devicesock
          hostPath:
            path: /var/lib/kubelet/device-plugins
            type: Directory
        - name: plugins-registry
          hostPath:
            path: /var/lib/kubelet/plugins_registry
            type: Directory
        - name: log
          hostPath:
            path: /var/log
            type: Directory
        - name: device-info
          hostPath:
            path: /var/run/k8s.cni.cncf.io/devinfo/dp
            type: DirectoryOrCreate
        - name: config-volume
          configMap:
            name: sriovdp-config
            items:
              - key: config.json
                path: config.json
```

**(c) Kubelet configuration + a workload that consumes the hardware:**

```yaml
---
# /var/lib/kubelet/config.yaml  (fragment)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# Exclusive CPUs for Guaranteed pods with integral CPU requests.
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
# Refuse to admit a pod whose CPU, memory and devices cannot all be
# satisfied from one NUMA node. Without this, the §1 incident is unfixable.
topologyManagerPolicy: single-numa-node
topologyManagerScope: pod
memoryManagerPolicy: Static
reservedSystemCPUs: "0-3,64-67"
systemReserved:
  cpu: "2"
  memory: "4Gi"
kubeReserved:
  cpu: "2"
  memory: "4Gi"
reservedMemory:
  - numaNode: 0
    limits:
      memory: 4Gi
  - numaNode: 1
    limits:
      memory: 4Gi
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
featureGates:
  MemoryManager: true
```

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: packet-gateway
  namespace: dataplane
spec:
  replicas: 4
  selector:
    matchLabels:
      app: packet-gateway
  template:
    metadata:
      labels:
        app: packet-gateway
      annotations:
        k8s.v1.cni.cncf.io/networks: sriov-dataplane
    spec:
      nodeSelector:
        platform.example.com/dpdk: "ready"
        platform.example.com/simd: "avx512"
      runtimeClassName: runc
      containers:
        - name: gateway
          image: registry.example.com/dataplane/packet-gateway:2.14.0
          securityContext:
            capabilities:
              add: ["IPC_LOCK", "NET_RAW"]
              drop: ["ALL"]
            allowPrivilegeEscalation: false
          resources:
            # Guaranteed QoS + integral CPU => exclusive cores from CPU Manager.
            # Topology Manager then forces devices + memory onto the same NUMA node.
            requests:
              cpu: "8"
              memory: "16Gi"
              hugepages-1Gi: "8Gi"
              platform.example.com/intel_sriov_dpdk: "1"
            limits:
              cpu: "8"
              memory: "16Gi"
              hugepages-1Gi: "8Gi"
              platform.example.com/intel_sriov_dpdk: "1"
          volumeMounts:
            - name: hugepage-1gi
              mountPath: /dev/hugepages
            - name: vfio
              mountPath: /dev/vfio
      volumes:
        - name: hugepage-1gi
          emptyDir:
            medium: HugePages-1Gi
        - name: vfio
          hostPath:
            path: /dev/vfio
            type: Directory
```

```console
$ kubectl get node cn-fra1-042 -o jsonpath='{.status.allocatable}' | jq
{
  "cpu": "124",
  "ephemeral-storage": "1798451234Ki",
  "hugepages-1Gi": "16Gi",
  "memory": "519438336Ki",
  "platform.example.com/intel_sriov_dpdk": "8",
  "platform.example.com/intel_sriov_netdevice": "8",
  "pods": "250"
}
$ kubectl get node cn-fra1-042 -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key|startswith("platform")))'
{
  "platform.example.com/dataplane": "true",
  "platform.example.com/dpdk": "ready",
  "platform.example.com/iommu": "enabled",
  "platform.example.com/nic": "x710",
  "platform.example.com/simd": "avx512"
}
```

The full chain is now closed: **firmware → `sysfs` → `udev` → node label → scheduler decision.**

---

## 11. Verification and failure diagnosis

### 11.1 Baseline verification script

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-hardware-baseline
# Exits non-zero on the first contract violation. Run from CI, from Ansible,
# and from the node-problem-detector.
set -euo pipefail

fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m OK \033[0m %s\n' "$*"; }

# --- 1. Every PCI device that has a driver available has it bound -----------
unbound=$(lspci -nnk | awk '
  /^[0-9a-f]{2}:/ { dev=$0; drv=""; mods="" }
  /Kernel driver in use/ { drv=$0 }
  /Kernel modules/ { mods=$0; if (drv == "") print dev }')
[[ -z "$unbound" ]] || fail "PCI devices with an available but unbound driver:
$unbound"
ok "all PCI devices with an available driver are bound"

# --- 2. No firmware load failures in the current boot -----------------------
if journalctl -kb --no-pager | grep -qE 'Direct firmware load for .* failed'; then
  journalctl -kb --no-pager | grep -E 'Direct firmware load for .* failed' | head -5
  fail "missing firmware blobs (install linux-firmware / vendor package)"
fi
ok "no firmware load failures this boot"

# --- 3. IOMMU active if the cmdline asked for it ----------------------------
if grep -qE '(intel|amd)_iommu=on' /proc/cmdline; then
  [[ -d /sys/kernel/iommu_groups/0 ]] \
    || fail "IOMMU requested on cmdline but no groups exist -> VT-d/AMD-Vi off in firmware"
  ok "IOMMU active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
fi

# --- 4. Hugepages actually reserved -----------------------------------------
want=$(sed -n 's/.*hugepages=\([0-9]*\).*/\1/p' /proc/cmdline)
if [[ -n "${want:-}" ]]; then
  got=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
  [[ "$want" == "$got" ]] || fail "hugepages requested=$want reserved=$got (fragmentation)"
  ok "hugepages reserved: $got x 1GiB"
fi

# --- 5. Data-plane NICs are NUMA-local and at full link width ----------------
for pf in /sys/class/net/*/device; do
  iface=$(basename "$(dirname "$pf")")
  [[ -e "$pf/numa_node" ]] || continue
  node=$(cat "$pf/numa_node")
  [[ "$node" != "-1" ]] || fail "$iface reports numa_node=-1 (broken ACPI SRAT; check BIOS)"
  if [[ -e "$pf/current_link_width" && -e "$pf/max_link_width" ]]; then
    cur=$(cat "$pf/current_link_width"); max=$(cat "$pf/max_link_width")
    [[ "$cur" == "$max" ]] || fail "$iface negotiated x$cur of x$max (wrong slot / bad riser)"
  fi
done
ok "all NICs report a valid NUMA node and full link width"

# --- 6. No IRQ collapsed onto a single CPU ----------------------------------
hot=$(awk 'NR>1 && $NF ~ /TxRx|nvme[0-9]+q[1-9]/ {
             max=0; sum=0
             for (i=2; i<=NF-3; i++) { sum+=$i; if ($i>max) max=$i }
             if (sum > 1000000 && max > 0.95*sum) print $NF
           }' /proc/interrupts)
[[ -z "$hot" ]] || fail "IRQs with >95% of events on one CPU: $hot"
ok "interrupt distribution is spread"

# --- 7. Persistent device symlinks resolve ----------------------------------
for link in /dev/disk/by-role/*; do
  [[ -e "$link" ]] || fail "stale role symlink: $link (udev rule matched nothing)"
done
ok "all by-role symlinks resolve"

printf '\n\033[32mhardware baseline verified\033[0m on %s\n' "$(hostname -f)"
```

```console
$ sudo /usr/local/sbin/verify-hardware-baseline
 OK  all PCI devices with an available driver are bound
 OK  no firmware load failures this boot
 OK  IOMMU active (143 groups)
 OK  hugepages reserved: 16 x 1GiB
 OK  all NICs report a valid NUMA node and full link width
 OK  interrupt distribution is spread
 OK  all by-role symlinks resolve

hardware baseline verified on cn-fra1-042.example.com
```

### 11.2 Failure playbooks

#### Failure A — the device does not appear in `/dev` at all

Walk the enumeration chain **in order**. Stop at the first stage that fails; everything downstream is a symptom.

```console
# Stage 1: does the bus see it?
$ lspci -nn | grep -i 81:00
81:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 [8086:1572]
#   -> Nothing here? Bus-level problem: disabled in firmware, dead slot,
#      unseated card, or the parent bridge did not train. Check `dmesg | grep -i pci`.

# Stage 2: is a driver bound?
$ lspci -nnk -s 81:00.0 | grep -E 'driver|modules'
	Kernel modules: i40e
#   -> "Kernel modules" present but no "Kernel driver in use" = probe failed.

# Stage 3: why did probe fail?
$ sudo dmesg | grep -iE 'i40e|firmware|8086:1572'
[   12.114553] i40e: Intel(R) Ethernet Connection XL710 Network Driver
[   12.331902] i40e 0000:81:00.0: Direct firmware load for i40e/i40e-e2-7.13.1.0.fw failed with error -2
[   12.331910] i40e 0000:81:00.0: Failed to init adminq: -19
[   12.342118] i40e: probe of 0000:81:00.0 failed with error -19

# Stage 4: is the module even loadable?
$ modinfo i40e >/dev/null && echo present || echo missing
present
$ sudo modprobe i40e; echo "exit=$?"
exit=0

# Stage 5: is it blacklisted?
$ grep -rE '^(blacklist|install).*i40e' /etc/modprobe.d/ /usr/lib/modprobe.d/
$ grep -oE 'module_blacklist=[^ ]*|modprobe.blacklist=[^ ]*' /proc/cmdline

# Stage 6: does sysfs have the class device?
$ ls -d /sys/class/net/* 2>/dev/null
#   -> Present in /sys but missing in /dev => udev problem. Go to Failure C.
```

**Resolution for the above:** the firmware blob is missing.

```console
$ ls /lib/firmware/i40e/ 2>/dev/null
$ sudo dnf install -y linux-firmware        # or: apt install firmware-misc-nonfree
$ echo 1 | sudo tee /sys/bus/pci/devices/0000:81:00.0/remove
$ echo 1 | sudo tee /sys/bus/pci/rescan
$ lspci -nnk -s 81:00.0 | grep 'driver in use'
	Kernel driver in use: i40e
```

> If the firmware lives in the initramfs path (root filesystem drivers), reinstalling the package is not enough — rebuild the initramfs.

#### Failure B — module refuses to load

| `dmesg` / `modprobe` message | Root cause | Fix |
|---|---|---|
| `Invalid module format` | `vermagic` mismatch: module built for another kernel | Rebuild against `uname -r`; check DKMS status |
| `Required key not available` | Secure Boot rejecting an unsigned module | Sign with the MOK, or `mokutil --disable-validation` (understand the security cost) |
| `Unknown symbol X (err -2)` | Dependency not loaded or symbol removed | `modprobe` (not `insmod`); run `depmod -a` |
| `Module X is in use` on `-r` | Non-zero refcount | `lsmod \| grep X` column 3; stop consumers first |
| `No such device` after a clean load | Module loaded, no matching hardware, or alias mismatch | Compare `cat .../modalias` with `modinfo -F alias` |
| `modprobe: FATAL: Module X not found` | Not built/installed for this kernel | `find /lib/modules/$(uname -r) -name 'X.ko*'`; `depmod -a` |
| Silently does nothing | `install X /bin/false` in `modprobe.d` | `modprobe --show-depends X` reveals the override |

```console
$ sudo insmod ./my_driver.ko
insmod: ERROR: could not insert module ./my_driver.ko: Invalid module format
$ modinfo -F vermagic ./my_driver.ko
6.5.0-21-generic SMP preempt mod_unload modversions
$ uname -r
6.8.0-45-generic
#   ^ Mismatch confirmed. Rebuild, or install the DKMS package.

$ dkms status
my_driver/1.4.2, 6.5.0-21-generic, x86_64: installed
$ sudo dkms install my_driver/1.4.2 -k 6.8.0-45-generic
```

#### Failure C — a `udev` rule does not fire

```console
# 1. Syntax. udevadm silently ignores malformed rules; verify explicitly.
$ sudo udevadm verify /etc/udev/rules.d/70-platform-hardware.rules
/etc/udev/rules.d/70-platform-hardware.rules: udev rules check failed
  :12 Invalid key 'ATTRS{seriall}'

# 2. Did you reload? Editing the file changes nothing on its own.
$ sudo udevadm control --reload

# 3. Dry-run against the real device and read which rules matched.
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E 'Reading rules|70-platform|no matching'

# 4. Confirm the attribute you matched exists at the level you matched it.
$ udevadm info -a -n /dev/nvme0n1 | grep -n 'serial'
     19:    ATTRS{serial}=="S6EUNJ0R500123"
#   ^ This is under "looking at parent device .../nvme/nvme0". ATTRS{} is
#     correct here; ATTR{} would NOT match, because the attribute belongs to
#     the parent, not to nvme0n1 itself.

# 5. Rule ordering: an earlier :=  assignment cannot be overridden.
$ grep -rn 'SYMLINK' /usr/lib/udev/rules.d/ /etc/udev/rules.d/ | grep ':='

# 6. Was the event delivered at all?
$ udevadm monitor --kernel --udev &
$ sudo udevadm trigger --action=change --sysname-match=nvme0n1
KERNEL[19022.4] change /devices/.../nvme0n1 (block)
UDEV  [19022.5] change /devices/.../nvme0n1 (block)
#   ^ KERNEL with no UDEV counterpart = udevd crashed, is stuck, or the
#     event timed out. Check: journalctl -u systemd-udevd -b

# 7. Worker exhaustion under mass hotplug (200-disk JBOD enumeration):
$ journalctl -u systemd-udevd -b | grep -i 'timeout\|worker'
systemd-udevd[812]: nvme0n1: Worker [1093] processing SEQNUM=8241 killed
#   -> A RUN+= program is blocking. Move slow work into a systemd unit
#      triggered by TAG+="systemd", ENV{SYSTEMD_WANTS}="myjob@%k.service"
```

The correct pattern for slow work in a rule:

```bash
# WRONG: udev kills the worker after event_timeout (default 180s), and blocks
#        the whole worker pool meanwhile.
ACTION=="add", SUBSYSTEM=="block", RUN+="/usr/local/bin/full-disk-scan %k"

# RIGHT: hand off to systemd, return immediately.
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z]", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="disk-scan@%k.service"
```

#### Failure D — interface renamed after a kernel or hardware change

```console
$ ip link show
3: rename3: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN mode DEFAULT
#   ^ classic symptom: a rename raced with the kernel's own name

$ udevadm info /sys/class/net/rename3 | grep ID_NET_NAME
E: ID_NET_NAME_MAC=enx3cfdfea1b2c0
E: ID_NET_NAME_PATH=enp129s0f0
E: ID_NET_NAME_SLOT=ens2f0

$ journalctl -b -u systemd-udevd | grep -i 'rename\|Could not'
systemd-udevd[794]: eth0: Failed to rename network interface 3 from 'eth0' to 'eth0': File exists
```

Fix: choose a name outside the kernel's namespace and pin it by MAC.

```ini
# /etc/systemd/network/10-dataplane0.link
[Match]
MACAddress=3c:fd:fe:a1:b2:c0

[Link]
Name=dataplane0
```

```console
$ sudo udevadm control --reload
$ sudo udevadm trigger --action=add --subsystem-match=net
$ ip -br link show dataplane0
dataplane0       UP             3c:fd:fe:a1:b2:c0 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

> **Root-cause note for containers/VMs:** if `ID_NET_NAME_SLOT` and `ID_NET_NAME_PATH` both change after a hypervisor migration, the PCI topology changed. Pin on `MACAddress` or `Property=ID_NET_NAME_MAC=`, never on the slot.

#### Failure E — `numa_node = -1`

```console
$ cat /sys/bus/pci/devices/0000:81:00.0/numa_node
-1
$ dmesg | grep -i 'SRAT\|no numa node'
[    0.000000] ACPI: SRAT not present
[    2.410332] pci 0000:81:00.0: [8086:1572] type 00 ... has invalid NUMA node -1, changing to 0
```

The firmware's ACPI SRAT table is absent or wrong. The scheduler will place interrupt handlers arbitrarily. Options, in order of preference:

1. **Fix the firmware** — update BIOS; check that "NUMA / Node Interleaving" is set to *NUMA enabled* (node interleaving **disabled**).
2. **Override at runtime** — only valid if you can prove the correct node from the PCI root bridge:
   ```console
   $ echo 1 | sudo tee /sys/bus/pci/devices/0000:81:00.0/numa_node
   ```
   Persist via a udev rule with `ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:81:00.0", ATTR{numa_node}="1"`.
3. **Disable `topologyManagerPolicy: single-numa-node`** — otherwise every pod requesting that device is admission-rejected with `TopologyAffinityError`.

#### Failure F — device present but wildly slow

```console
$ sudo lspci -vv -s 81:00.0 | grep -E 'LnkCap|LnkSta'
		LnkCap:	Port #0, Speed 16GT/s, Width x8, ASPM L1
		LnkSta:	Speed 2.5GT/s (downgraded), Width x4 (downgraded)
```

`(downgraded)` on either field is definitive. Causes, ranked by frequency: wrong physical slot (x4 electrical in an x8 mechanical connector), a riser card, bifurcation misconfigured in firmware, ASPM aggressively parking the link, or a marginal signal integrity fault forcing retraining.

```console
# Rule out ASPM first — it is free to test.
$ sudo lspci -vv -s 81:00.0 | grep -i 'LnkCtl'
		LnkCtl:	ASPM L1 Enabled; RCB 64 bytes, Disabled- CommClk+
# Persistent test: add pcie_aspm=off to the kernel cmdline and re-measure.

# Then check the correctable-error counters — a retraining link logs here.
$ sudo lspci -vv -s 81:00.0 | grep -A3 'Correctable Error'
$ sudo dmesg | grep -i 'aer\|corrected'
[  118.442901] pcieport 0000:80:01.0: AER: Corrected error received: 0000:81:00.0
[  118.442918] i40e 0000:81:00.0: PCIe Bus Error: severity=Corrected, type=Physical Layer
```

Corrected AER storms mean a physical problem: reseat the card, replace the riser, clean the connector.

---

## 12. Command and file reference — exam consolidation

| Command | Reads / writes | Use it for |
|---|---|---|
| `lspci -nnk`, `-tv`, `-vvv` | PCI config space | Devices, IDs, bound drivers, link status |
| `lsusb`, `lsusb -t`, `lsusb -v` | USB descriptors | USB topology, speeds, serial numbers |
| `lsmod` | `/proc/modules` | Loaded modules and refcounts |
| `modprobe [-r] [-v] [--show-depends]` | `modules.dep`, `modprobe.d` | Load/unload with dependency resolution |
| `insmod` / `rmmod` | direct syscall | Single-file load — **no dependency handling** |
| `modinfo` | module ELF sections | Params, aliases, firmware, vermagic, deps |
| `depmod -a` | `/lib/modules/$(uname -r)/` | Rebuild `modules.dep` / `modules.alias` |
| `udevadm info \| test \| monitor \| trigger \| settle \| control` | udev db + rules | The entire udev debugging surface |
| `lsblk`, `blkid`, `lsscsi`, `nvme list` | block layer | Storage topology and identity |
| `lscpu`, `numactl -H` | `/sys/devices/system/{cpu,node}` | CPU/NUMA topology |
| `dmidecode -t <n> \| -s <str>` | SMBIOS tables | Chassis, BIOS, DIMM inventory |
| `lshw`, `hwinfo`, `inxi` | aggregate | Whole-machine snapshot |
| `systemd-detect-virt`, `virt-what` | DMI/CPUID | Bare metal vs guest |
| `busctl`, `gdbus`, `dbus-send` | D-Bus system bus | Device state exposed by udisks2/UPower/NM |
| `setpci` | raw PCI config | Last-resort register poking — **can hang the machine** |

| Path | Contents |
|---|---|
| `/proc/cpuinfo`, `/proc/meminfo` | CPU flags; memory totals including `HugePages_*` |
| `/proc/interrupts`, `/proc/irq/N/smp_affinity` | Interrupt census and affinity |
| `/proc/ioports`, `/proc/iomem`, `/proc/dma` | I/O port, MMIO and legacy ISA DMA maps |
| `/proc/modules`, `/proc/cmdline`, `/proc/mdstat` | Modules, boot parameters, MD RAID |
| `/sys/bus/<bus>/devices/`, `/sys/bus/<bus>/drivers/*/{bind,unbind}` | Device model and driver binding |
| `/sys/class/<class>/`, `/sys/devices/`, `/sys/module/<m>/parameters/` | Class view, topology view, live params |
| `/sys/kernel/iommu_groups/`, `/sys/kernel/mm/hugepages/` | IOMMU grouping, hugepage pools |
| `/sys/class/dmi/id/*`, `/sys/firmware/{acpi,devicetree}/` | Unprivileged DMI; ACPI tables / Device Tree |
| `/dev/disk/by-{id,uuid,path,partuuid}/`, `/dev/mapper/` | Stable storage identifiers |
| `/etc/modprobe.d/`, `/etc/modules-load.d/` | Module options, blacklists, boot-time loads |
| `/etc/udev/rules.d/` (overrides `/usr/lib/udev/rules.d/`) | udev policy |
| `/etc/systemd/network/*.link` | Interface naming and link-level settings |
| `/lib/firmware/`, `/lib/modules/$(uname -r)/` | Device firmware blobs; kernel modules |

---

## 13. Referencias

**Objetivos oficiales de la certificación**
- LPI — Exam 101-500 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 Certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Kernel de Linux (documentación oficial)**
- The `sysfs` Filesystem: https://docs.kernel.org/filesystems/sysfs.html
- Rules on how to access information in sysfs: https://docs.kernel.org/admin-guide/sysfs-rules.html
- The `/proc` Filesystem: https://docs.kernel.org/filesystems/proc.html
- The kernel's command-line parameters: https://docs.kernel.org/admin-guide/kernel-parameters.html
- Linux Device Drivers / Device Model: https://docs.kernel.org/driver-api/driver-model/index.html
- PCI Bus Subsystem: https://docs.kernel.org/PCI/index.html
- PCI Express I/O Virtualization (SR-IOV) HOWTO: https://docs.kernel.org/PCI/pci-iov-howto.html
- VFIO — "Virtual Function I/O": https://docs.kernel.org/driver-api/vfio.html
- USB Device Drivers / USB core API: https://docs.kernel.org/driver-api/usb/index.html
- Firmware loading (`request_firmware` API): https://docs.kernel.org/driver-api/firmware/index.html
- HugeTLB Pages: https://docs.kernel.org/admin-guide/mm/hugetlbpage.html
- SMP IRQ affinity: https://docs.kernel.org/core-api/irq/irq-affinity.html
- Linux allocated devices (major/minor registry): https://docs.kernel.org/admin-guide/devices.html
- Kernel ABI documentation index: https://docs.kernel.org/admin-guide/abi.html

**systemd / udev / D-Bus (freedesktop.org)**
- `udev` — Dynamic device management: https://www.freedesktop.org/software/systemd/man/latest/udev.html
- `udevadm(8)`: https://www.freedesktop.org/software/systemd/man/latest/udevadm.html
- `systemd-udevd.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-udevd.service.html
- `systemd.link(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- `modules-load.d(5)`: https://www.freedesktop.org/software/systemd/man/latest/modules-load.d.html
- Predictable Network Interface Names: https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- D-Bus Specification: https://dbus.freedesktop.org/doc/dbus-specification.html
- UDisks2 Reference Manual: https://storaged.org/doc/udisks2-api/latest/
- UPower Reference Manual: https://upower.freedesktop.org/docs/

**Páginas de manual (man7.org)**
- `modprobe(8)`: https://man7.org/linux/man-pages/man8/modprobe.8.html
- `modprobe.d(5)`: https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- `modinfo(8)`: https://man7.org/linux/man-pages/man8/modinfo.8.html
- `depmod(8)`: https://man7.org/linux/man-pages/man8/depmod.8.html
- `lsmod(8)`: https://man7.org/linux/man-pages/man8/lsmod.8.html
- `lspci(8)`: https://man7.org/linux/man-pages/man8/lspci.8.html
- `lsusb(8)`: https://man7.org/linux/man-pages/man8/lsusb.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `dmidecode(8)`: https://man7.org/linux/man-pages/man8/dmidecode.8.html
- `udev(7)`: https://man7.org/linux/man-pages/man7/udev.7.html

**Estándares e identificadores de hardware**
- DMTF — System Management BIOS (SMBIOS) Reference Specification: https://www.dmtf.org/standards/smbios
- UEFI Forum — UEFI and ACPI Specifications: https://uefi.org/specifications
- PCI ID Repository: https://pci-ids.ucw.cz/
- Linux USB ID Repository: http://www.linux-usb.org/usb-ids.html
- devicetree.org — Devicetree Specification: https://www.devicetree.org/specifications/
- Filesystem Hierarchy Standard 3.0 (`/dev`, `/proc`, `/sys`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**Exposición de hardware en Kubernetes**
- Device Plugins: https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/
- Control Topology Management Policies on a node: https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/
- CPU Management Policies: https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- Memory Manager: https://kubernetes.io/docs/tasks/administer-cluster/memory-manager/
- Managing HugePages: https://kubernetes.io/docs/tasks/manage-hugepages/scheduling-hugepages/
- Node Feature Discovery (SIG): https://kubernetes-sigs.github.io/node-feature-discovery/stable/get-started/
- SR-IOV Network Device Plugin: https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin

**Herramientas de aprovisionamiento**
- `dracut(8)`: https://man7.org/linux/man-pages/man8/dracut.8.html
- cloud-init — Module reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible — `community.general.modprobe` module: https://docs.ansible.com/ansible/latest/collections/community/general/modprobe_module.html