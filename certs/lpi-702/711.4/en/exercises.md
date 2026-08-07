# LPI-702 BSD Specialist: Objective 711.4 — Hardware Configuration

**Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Topic 711.4:** Hardware Configuration  
**Exam Weight:** 3.33 (Weight: 2 out of 60 total exam weight units)  
**Official Reference:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Technical Architecture & Low-Level Mechanics

In BSD operating systems (FreeBSD, NetBSD, OpenBSD), hardware abstraction and device discovery rely on a combination of bus enumeration drivers, static and dynamic device trees, and subsystem-specific management utilities. Understanding these internal mechanics is critical for enterprise SREs managing bare-metal hypervisors, storage nodes, and high-throughput network appliances.

```
+-------------------------------------------------------------------------+
|                          User Space Utilities                           |
|  (pciconf, camcontrol, devinfo, kldload/modload, atactl, scsictl, dmesg)|
+-------------------------------------------------------------------------+
                                    |
                                    v [ioctl() / sysctl / devfs]
+-------------------------------------------------------------------------+
|                             BSD Kernel                                  |
|  +---------------------+   +-------------------+   +-----------------+  |
|  |     Newbus / Autoconf|   |  CAM Subsystem    |   | KLD / Module    |  |
|  |     (Device Tree)   |   | (Common Access)   |   | Subsystem       |  |
|  +---------------------+   +-------------------+   +-----------------+  |
+-------------------------------------------------------------------------+
                                    |
                                    v
+-------------------------------------------------------------------------+
|                          Hardware Controller                            |
|       (PCIe Root Complex, NVMe Controller, AHCI SATA, SAS HBA)          |
+-------------------------------------------------------------------------+
```

### 1. Device Tree & Bus Enumeration Mechanics
* **FreeBSD Newbus Framework:** FreeBSD utilizes the `Newbus` architecture to represent hardware hierarchy as a tree of devices (`device_t`). When the system boots, the kernel initializes root buses (such as `nexus0` or `acpi0`), which recursively probe child buses (PCI, ISA, USB). Drivers match hardware identifiers against vendor and device PCI IDs exposed by the PCIe Configuration Space.
* **NetBSD/OpenBSD Autoconf:** NetBSD and OpenBSD use an `autoconf(9)` match-and-attach framework (`cfattach`). Hardware discovery occurs via driver matching functions evaluating capability structures passed by parent bus drivers during system initialization.

### 2. FreeBSD CAM (Common Access Method) Subsystem
FreeBSD routes all disk and tape storage transactions through the CAM architecture (`cam(4)`). CAM decouples physical transport layers (SATA, SAS, NVMe, USB mass storage) from logical SCSI execution engines. Peripheral drivers (e.g., `da` for Direct Access disks, `ada` for ATA disks, `nda` for NVM Express devices) communicate with SIM (Subsystem Interface Module) drivers via CCBs (CAM Control Blocks).

### 3. Kernel Module (KLD / LKM) Subsystem & Security Controls
Dynamic loading allows loading kernel object files (`.ko` in FreeBSD, `.kmod` in NetBSD) without rebooting.
* **FreeBSD `kld` Subsystem:** Uses `kldload(2)` system calls to map ELF binaries directly into kernel space, resolving kernel symbols dynamically.
* **Security Boundaries (`kern.securelevel`):** At `securelevel = 1` or higher, dynamic kernel module loading is disabled kernel-wide to prevent arbitrary code execution and rootkits. Loading modules via `/boot/loader.conf` occurs during the boot loader stage *before* the kernel initializes userland and enforces `securelevel`.

---

## Guided Exercise 1: Low-Level Hardware Discovery and PCI Bus Probing

### Scenario
You are troubleshooting a newly racked FreeBSD 14-RELEASE enterprise storage server. The OS fails to attach a high-performance 100GbE network interface card (NIC). You must inspect the system message ring buffer, inspect the PCI bus configuration space, verify hardware vendor/device IDs, and determine driver attachment status.

### Execution Steps

1. **Inspect System Message Ring Buffer and Probing Logs:**
   Examine the kernel boot messages to locate PCI bus enumeration and unmapped hardware devices.

   ```bash
   dmesg | grep -i pci
   ```
   *Expected Output:*
   ```text
   pci0: <PCI bus> on pcib0
   pci0: <network, ethernet> at device 0.0 (no driver attached)
   pci0: <storage, flash> at device 1.0 (driver attached as nda0)
   ```

2. **Examine the Complete Hardware Device Tree:**
   Query the kernel device tree to analyze parent-child bus relationships.

   ```bash
   devinfo -v | head -n 25
   ```
   *Expected Output:*
   ```text
   nexus0
     cryptosoft0
     acpi0
       pcib0 pnpinfo _HID=PNP0A08 _UID=0 on acpi0
         pci0 on pcib0
           isab0 pnpinfo vendor=0x8086 device=0x1d41 subvendor=0x15d9 subdevice=0x0600 class=0x060100 at slot 31 function 0 on pci0
           ixgbe0 pnpinfo vendor=0x8086 device=0x1572 subvendor=0x15d9 subdevice=0x0600 class=0x020000 at slot 0 function 0 on pci0
   ```

3. **Query PCI Configuration Space and Vendor/Device IDs:**
   Use FreeBSD's `pciconf` to list detailed hardware descriptors, selector strings, and PCI header registers.

   ```bash
   pciconf -lv
   ```
   *Expected Output:*
   ```text
   none0@pci0:0:0:0:	class=0x020000 rev=0x00 hdr=0x00 vendor=0x15b3 device=0x101d subvendor=0x15b3 subdevice=0x0003
       vendor     = 'Mellanox Technologies'
       device     = 'MT2892 Family [ConnectX-6 Dx]'
       class      = network
       subclass   = ethernet
   ```

4. **Inspect PCI Device Capabilities and Power Management Status:**
   Perform a detailed read of the PCI configuration registers for selector `pci0:0:0:0`.

   ```bash
   pciconf -bc pci0:0:0:0
   ```
   *Expected Output:*
   ```text
   none0@pci0:0:0:0: class=0x020000 rev=0x00 hdr=0x00 vendor=0x15b3 device=0x101d subvendor=0x15b3 subdevice=0x0003
       bar   [10] type Memory 64-bit length 33554432 alloc base 0xfb000000 enabled
       cap 01[40] powerspec 3  supports D1 D2 D3  current D0
       cap 10[60] PCI-Express 2 endpoint max data 256(512) ro
       cap 11[9c] MSI-X max 64 vectors enabled
   ```

5. **Cross-Platform Verification (NetBSD Alternative):**
   *Note:* If executing on NetBSD, inspect PCI devices using `pcictl`.

   ```bash
   # NetBSD equivalent
   pcictl /dev/pci0 list
   ```

---

### Verification Questions

#### Question 1.1
In the output of `pciconf -lv`, what does the device identifier `none0@pci0:0:0:0:` indicate to a System Administrator?
- A) The device is physically malfunctioning and generating PCI bus parity errors.
- B) The device is recognized on PCI domain 0, bus 0, slot 0, function 0, but no loaded kernel driver has claimed it.
- C) The device is a dummy virtual placeholder allocated by `devfs`.
- D) The PCI slot is unpowered and operating in low-power D3 state.

#### Question 1.2
Which official documentation resource details the syntax and flags for FreeBSD PCI configuration space inspection?
- A) [FreeBSD pciconf(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=pciconf)
- B) [NetBSD devpubd(8) Manual Page](https://man.netbsd.org/devpubd.8)
- C) [OpenBSD sysctl(8) Manual Page](https://man.openbsd.org/sysctl.8)
- D) [FreeBSD camcontrol(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=camcontrol)

---

## Guided Exercise 2: Storage Bus Diagnostics and Control (CAM, SCSI, ATA)

### Scenario
An enterprise database node running FreeBSD is experiencing degraded IOPS. You suspect a failing SATA/SAS drive attached to the CAM subsystem. You must scan the CAM bus, issue raw SCSI Inquiry commands, manipulate bus topology at runtime, and compare storage management paradigms with NetBSD/OpenBSD utilities.

### Execution Steps

1. **List All Active Storage Devices in the FreeBSD CAM Subsystem:**
   Display device bindings, bus locations, target IDs, LUNs, and serial numbers.

   ```bash
   camcontrol devlist -v
   ```
   *Expected Output:*
   ```text
   <SAMSUNG MZ7LH960HAJR-00005 H2040003>  at scbus0 target 0 lun 0 (ada0,pass0)
   <SAMSUNG MZ7LH960HAJR-00005 H2040003>  at scbus0 target 1 lun 0 (ada1,pass1)
   <SEAGATE ST12000NM0007 E004>           at scbus1 target 4 lun 0 (da0,pass2)
   <LSI SAS3008 06.00.00.00>              at scbus1 target 8 lun 0 (xpt0,pass3)
   ```

2. **Issue Low-Level SCSI INQUIRY Page Request:**
   Query target drive `da0` directly through its pass-through device (`pass2`).

   ```bash
   camcontrol inquiry da0 -v
   ```
   *Expected Output:*
   ```text
   pass2: <SEAGATE ST12000NM0007 E004> Fixed Direct Access SCSI-6 device
   pass2: serial number ZVT0A1B2
   pass2: 300.000MB/s transfers, Variable Command Queueing Enabled
   protocol      SCSI-6
   device type   Direct Access
   capabilities  16-bit wide, Command Queueing
   ```

3. **Perform a Hot-Rescan of the Storage Bus:**
   After swapping a defective drive in drive bay 1 (target 1), trigger a bus rescan across all CAM controllers without rebooting.

   ```bash
   camcontrol rescan all
   ```
   *Expected Output:*
   ```text
   Re-scan of bus 0 was successful
   Re-scan of bus 1 was successful
   ```

4. **Request Smart and Bus Speed Attributes:**
   Inspect negotiated bus transfer parameters for physical disk `ada0`.

   ```bash
   camcontrol negotiate ada0
   ```
   *Expected Output:*
   ```text
   Current parameters for ada0:
   SATA transfer rate: 6.0Gb/s (SATA 3.x)
   Command Queueing:   Enabled (NCQ depth 32)
   ```

5. **Cross-Platform ATA/SCSI Diagnostics (NetBSD and OpenBSD):**
   Execute platform-specific utilities on NetBSD and OpenBSD to inspect ATA registers and issue SCSI commands.

   ```bash
   # NetBSD ATA device control
   atactl /dev/atabus0 device 0 identify

   # NetBSD SCSI bus inspection
   scsictl /dev/scsibus0 scan any any

   # OpenBSD ATA/IDE control
   atactl /dev/wd0c identify
   ```

---

### Verification Questions

#### Question 2.1
What is the primary role of the `pass` driver (e.g., `pass0`, `pass1`) in the FreeBSD CAM architecture?
- A) It provides high-performance asynchronous block caching for ZFS pools.
- B) It allows userland utilities (`camcontrol`, `smartctl`) to send raw SCSI/ATA Command Descriptor Blocks (CDBs) directly to hardware targets.
- C) It compresses block writes before transmitting over SAS HBAs.
- D) It handles legacy IDE fallback modes when ACPI is disabled in `/boot/loader.conf`.

#### Question 2.2
In OpenBSD and NetBSD, which utility is specifically designated for issuing low-level ATA identification commands directly to IDE/SATA controllers?
- A) `camcontrol`
- B) `atactl`
- C) `kldload`
- D) `pciconf`

---

## Guided Exercise 3: Kernel Module Runtime Management and Boot Persistence

### Scenario
To enable network hardware offloading for Mellanox high-speed NICs on FreeBSD, you must dynamically load the `mlx5en` network driver module, analyze kernel symbol dependencies, and configure system configuration files to ensure persistence across node reboots. You will also learn NetBSD module management syntax.

### Execution Steps

1. **Display Currently Loaded Kernel Modules:**
   Check currently active kernel modules, memory addresses, sizes, and module IDs on FreeBSD.

   ```bash
   kldstat
   ```
   *Expected Output:*
   ```text
   Id Refs Address            Size     Name
    1   18 0xffffffff80200000 1f3e000  kernel
    2    1 0xffffffff8213e000 3800     zfs.ko
    3    1 0xffffffff82142000 89a0     opensolaris.ko
   ```

2. **Dynamically Load Required Hardware Driver Module:**
   Load the Mellanox ConnectX-4/5/6 core and Ethernet driver module into the running kernel.

   ```bash
   kldload mlx5en
   ```
   *Verify module loading success:*
   ```bash
   kldstat | grep mlx5
   ```
   *Expected Output:*
   ```text
    4    2 0xffffffff8214b000 4a120    mlx5.ko
    5    1 0xffffffff82196000 1c890    mlx5en.ko
   ```

3. **Inspect Kernel Module Metadata and Exported Capabilities:**
   Examine module dependencies and exported version metadata.

   ```bash
   kldstat -v -i 5
   ```
   *Expected Output:*
   ```text
   Id: 5
   Name: mlx5en.ko
   Contains modules:
   	Id Path
   	 85 pci/mlx5en
   	 86 struct/mlx5en
   ```

4. **Configure Persistent Boot-Time Module Loading:**
   To persist hardware modules across reboots in FreeBSD, configure `/boot/loader.conf`. Create or update `/boot/loader.conf` with syntactically valid parameter directives.

   ```bash
   cat << 'EOF' > /boot/loader.conf
   # /boot/loader.conf - System Initialization Hardware Loader Config
   # Enable Mellanox ConnectX Core and Ethernet drivers
   mlx5_load="YES"
   mlx5en_load="YES"

   # Hardware Offloading and Memory Allocations
   hw.mlx5.num_comp_vectors="8"
   kern.ipc.nmbclusters="1048576"

   # Enable NVMe controller driver
   nvme_load="YES"
   EOF
   ```

5. **Configure Static Hardware Device Hints:**
   Configure static hardware resources (IRQ, IO Ports) for legacy or non-ACPI devices in `/boot/device.hints`.

   ```bash
   cat << 'EOF' >> /boot/device.hints
   hint.uart.0.at="isa"
   hint.uart.0.port="0x3F8"
   hint.uart.0.flags="0x10"
   hint.uart.0.irq="4"
   EOF
   ```

6. **Cross-Platform Kernel Module Control (NetBSD):**
   *Note:* NetBSD uses `modstat`, `modload`, and `modunload` for kernel module runtime operations.

   ```bash
   # NetBSD listing loaded modules
   modstat

   # NetBSD loading a driver module
   modload /usr/tests/sys/modules/kmod/kmod.kmod

   # NetBSD unloading a module
   modunload kmod
   ```

---

### Verification Questions

#### Question 3.1
In FreeBSD, what happens if an administrator executes `kldload mlx5en` when the system kernel is running at `kern.securelevel = 1`?
- A) The module loads successfully, but a warning is logged to syslog.
- B) The operation fails with "Operation not permitted" because dynamic kernel module loading is strictly forbidden at securelevel >= 1.
- C) The kernel reboots into single-user recovery mode (`bsd.rd`).
- D) The module is automatically staged to `/boot/loader.conf` for execution on the next boot cycle.

#### Question 3.2
Which FreeBSD configuration file is parsed by `loader(8)` prior to kernel initialization to load device drivers and set early kernel tunable parameters (`sysctl` hints)?
- A) `/etc/rc.conf`
- B) `/etc/sysctl.conf`
- C) `/boot/loader.conf`
- D) `/etc/devd.conf`

---

## Guided Exercise 4: Enterprise Hardware Troubleshooting and Kernel Security Trade-offs

### Scenario
An SRE security audit mandates enforcing strict kernel memory protection (`kern.securelevel = 2`) while dynamically tuning network ring buffers (`sysctl`) and preventing unauthorized driver unbinding on FreeBSD infrastructure.

### Execution Steps

1. **Query and Modify Active Kernel Parameters at Runtime:**
   Read and update live hardware tunables using `sysctl`.

   ```bash
   # Query current PCI and ACPI power parameters
   sysctl hw.pci
   ```
   *Expected Output:*
   ```text
   hw.pci.enable_io_modes: 1
   hw.pci.do_power_nodriver: 0
   hw.pci.enable_msix: 1
   ```

2. **Configure Persistent Runtime Kernel Parameters in `/etc/sysctl.conf`:**
   Add hardware tuning variables to `/etc/sysctl.conf`.

   ```bash
   cat << 'EOF' >> /etc/sysctl.conf
   # /etc/sysctl.conf - Runtime Kernel System Control Configuration
   # Disable automatic power-down of PCI devices without attached drivers
   hw.pci.do_power_nodriver=0

   # Expand maximum network device queue length
   net.route.netisr_maxqlen=4096
   EOF
   ```

3. **Analyze Security Trade-offs of Monolithic Kernels vs. Dynamic Module Loading:**
   Review security levels and verify securelevel protection against runtime kernel modifications.

   ```bash
   sysctl kern.securelevel
   ```
   *Expected Output:*
   ```text
   kern.securelevel: 0
   ```

   *Architectural Trade-off Analysis:*
   * **Dynamic Modules:** Provide operational flexibility; drivers can be loaded/unloaded on demand without downtime. *Risk:* Exposes an attack vector where compromised root accounts can inject kernel-level rootkits via `kldload` or `modload`.
   * **Monolithic/Static Kernels (`securelevel >= 1`):** Compiling all required hardware drivers directly into the kernel binary (`/boot/kernel/kernel`) and setting `kern.securelevel=1` in `/etc/sysctl.conf` guarantees kernel code integrity. *Trade-off:* Requires a full system reboot to upgrade drivers or add hardware.

---

### Verification Questions

#### Question 4.1
What is the crucial operational difference between setting hardware tunables in `/boot/loader.conf` versus setting kernel variables in `/etc/sysctl.conf`?
- A) `/etc/sysctl.conf` is evaluated by the bootloader before kernel execution; `/boot/loader.conf` is parsed after `init(8)` starts.
- B) `/boot/loader.conf` tunes read-only kernel parameters before device probing; `/etc/sysctl.conf` tunes read-write kernel parameters after userland boot completes.
- C) Parameters in `/boot/loader.conf` apply only to NetBSD, whereas `/etc/sysctl.conf` applies strictly to OpenBSD.
- D) `/etc/sysctl.conf` enables dynamic PCI bus hot-plugging; `/boot/loader.conf` disables system power management.

#### Question 4.2
Refer to official BSD documentation resources. Which URL provides authoritative information regarding FreeBSD kernel module utilities and configuration files?
- A) [FreeBSD Handbook: Kernel Configuration](https://docs.freebsd.org/en/books/handbook/kernelconfig/)
- B) [FreeBSD kldload(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=kldload)
- C) [FreeBSD loader.conf(5) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=loader.conf)
- D) All of the above.

---

## Solutions & Explanation Key

<details>
<summary><strong>Click to expand Answer Key and Complete Technical Explanations</strong></summary>

### Exercise 1 Solutions

* **Question 1.1: Correct Answer: B**
  * **Explanation:** In FreeBSD's `pciconf -lv` utility output, `none0@pci0:0:0:0:` designates a physical device discovered on the PCI bus (Domain 0, Bus 0, Slot 0, Function 0) for which no loaded kernel driver module has claimed or attached to the device (`none` class).
  * **Incorrect Options Analysis:**
    * A is incorrect: Hardware malfunction errors are logged in `dmesg` or machine check exceptions (MCE), not denoted by the `none` class tag.
    * C is incorrect: `devfs` manages virtual `/dev` nodes for attached drivers; unattached devices do not create character/block nodes in `/dev`.
    * D is incorrect: D3 low-power states are power management flags shown in capability registers (`cap 01`), not indicated by `none0`.

* **Question 1.2: Correct Answer: A**
  * **Explanation:** The official manual page for `pciconf` is maintained at [FreeBSD pciconf(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=pciconf).

---

### Exercise 2 Solutions

* **Question 2.1: Correct Answer: B**
  * **Explanation:** The `pass(4)` peripheral driver in the FreeBSD CAM subsystem exposes raw pass-through control character devices (`/dev/passX`). This interface permits userland utilities such as `camcontrol`, `smartctl`, and `cdrecord` to send direct SCSI Command Descriptor Blocks (CDBs) and ATA Pass-Through commands to storage hardware without going through higher-level block layers.
  * **Incorrect Options Analysis:**
    * A is incorrect: ZFS manages its own SPA/ARC caching layer directly over block devices (`da`, `ada`, `nda`).
    * C is incorrect: Hardware HBAs perform bus compression, not the software pass-through device driver.
    * D is incorrect: ACPI power states are handled by `acpi(4)`, not CAM `pass`.

* **Question 2.2: Correct Answer: B**
  * **Explanation:** `atactl` is the native utility in NetBSD and OpenBSD used to inspect ATA controller channels, query SMART attributes, and issue ATA identification commands (refer to [OpenBSD atactl(8) Manual Page](https://man.openbsd.org/atactl.8)).
  * **Incorrect Options Analysis:**
    * A is incorrect: `camcontrol` is specific to FreeBSD's CAM subsystem.
    * C is incorrect: `kldload` manages FreeBSD kernel modules.
    * D is incorrect: `pciconf` is used for PCI bus configuration inspection in FreeBSD.

---

### Exercise 3 Solutions

* **Question 3.1: Correct Answer: B**
  * **Explanation:** FreeBSD enforces security boundaries via `kern.securelevel`. At `securelevel = 1` (Secure mode) or `securelevel = 2` (Highly secure mode), unloading or loading kernel modules using `kldload(2)` / `kldunload(2)` is explicitly denied by the system security policy to prevent rootkit injection.
  * **Incorrect Options Analysis:**
    * A is incorrect: The system call fails outright; it does not execute with a warning.
    * C is incorrect: The kernel does not panic or reboot into RAMDISK mode (`bsd.rd`).
    * D is incorrect: Userland utilities cannot modify `/boot/loader.conf` automatically upon failed execution.

* **Question 3.2: Correct Answer: C**
  * **Explanation:** `/boot/loader.conf` is read by stage 3 of the FreeBSD bootloader (`loader(8)`). It instructs the bootloader to load specific kernel modules into memory and set low-level kernel tunables prior to loading and launching `/boot/kernel/kernel`.
  * **Incorrect Options Analysis:**
    * A is incorrect: `/etc/rc.conf` configures system services and network interfaces after userland initializes.
    * B is incorrect: `/etc/sysctl.conf` is parsed by `sysctl(8)` during userland boot startup (`rc.sysctl`), after the kernel is running.
    * D is incorrect: `/etc/devd.conf` configures event rules for userland device daemon hot-plug events (`devd`).

---

### Exercise 4 Solutions

* **Question 4.1: Correct Answer: B**
  * **Explanation:** `/boot/loader.conf` is processed early in the boot sequence by the bootloader (`loader(8)`), enabling it to set read-only kernel parameters, memory allocation limits, and load storage/network drivers necessary for probing devices. `/etc/sysctl.conf` is processed much later in the boot cycle by userland init scripts (`rc`), modifying writable kernel parameters (`sysctl` nodes) while the system is operational.
  * **Incorrect Options Analysis:**
    * A is incorrect: Reversed sequence; `loader.conf` is evaluated *before* `init(8)`.
    * C is incorrect: `/boot/loader.conf` and `/etc/sysctl.conf` are core FreeBSD configuration files (`sysctl.conf` is shared across NetBSD/OpenBSD as well).
    * D is incorrect: `/etc/sysctl.conf` does not control physical PCI hot-plug hardware signals.

* **Question 4.2: Correct Answer: D**
  * **Explanation:** All cited URLs provide official, authoritative documentation covering FreeBSD kernel configuration, module loading utilities, and boot loader parameters:
    * [FreeBSD Handbook: Kernel Configuration](https://docs.freebsd.org/en/books/handbook/kernelconfig/)
    * [FreeBSD kldload(8) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=kldload)
    * [FreeBSD loader.conf(5) Manual Page](https://man.freebsd.org/cgi/man.cgi?query=loader.conf)

</details>