# LPIC-2 (Exam 201-450) Topic 201: Linux Kernel Subsystem & Production Runtime Architecture

## Official References & Source Documentation
* [LPI LPIC-2 Exam 201-450 Objectives](https://www.lpi.org/our-certifications/lpic-2-overview/)
* [The Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/)
* [Linux Kernel Source Tree Repository](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git)
* [Linux Kernel Module Management (modprobe.d man page)](https://man7.org/linux/man-pages/man5/modprobe.d.5.html)
* [Kernel Parameter Infrastructure (sysctl.d man page)](https://man7.org/linux/man-pages/man5/sysctl.d.5.html)
* [udev Device Manager Architecture (udevadm man page)](https://man7.org/linux/man-pages/man8/udevadm.8.html)
* [dracut Initramfs Infrastructure (dracut man page)](https://man7.org/linux/man-pages/man8/dracut.8.html)

---

## Exercise 1: Kernel Architecture Inspection, Module Lifecycle, and Runtime Diagnostics

### Objective
Examine the monolithic Linux kernel layout, inspect virtual file systems (`/proc` and `/sys`), analyze driver dependency graphs with `depmod`/`lsmod`, perform kernel module parameter manipulation, and configure persistent module configurations via `/etc/modprobe.d/`.

### Step-by-Step Execution Plan

1. **Query the live kernel version, release parameters, and ring buffer.**
   Run `uname` with detailed flags to inspect kernel release, machine architecture, and build timestamps, followed by inspecting the runtime ring buffer with `dmesg`.

   ```bash
   uname -a
   dmesg --level=err,warn | head -n 15
   ```

   **Expected Output:**
   ```text
   Linux node-prod-sre-01 5.15.0-107-generic #117-Ubuntu SMP Fri Apr 26 13:28:16 UTC 2024 x86_64 x86_64 x86_64 GNU/Linux
   [    0.000000] Linux version 5.15.0-107-generic (buildd@lcy02-amd64-071) (gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0, GNU ld (GNU Binutils for Ubuntu) 2.38) #117-Ubuntu SMP Fri Apr 26 13:28:16 UTC 2024
   [    0.214811] x86/fpu: Supporting XSAVE feature 0x001: 'x87 floating point registers'
   [    0.214812] x86/fpu: Supporting XSAVE feature 0x002: 'SSE registers'
   [    0.214813] x86/fpu: Supporting XSAVE feature 0x004: 'AVX registers'
   ```

2. **Inspect kernel module metadata and module dependency database.**
   Locate module binaries inside `/lib/modules/$(uname -r)/` and execute `modinfo` against the `overlay` storage driver to analyze module metadata, parameters, and licensing.

   ```bash
   modinfo overlay
   ```

   **Expected Output:**
   ```text
   filename:       /lib/modules/5.15.0-107-generic/kernel/fs/overlayfs/overlay.ko
   alias:          fs-overlay
   license:        GPL
   description:    Overlay filesystem back-end stuff
   author:         Miklos Szeredi <mszeredi@suse.cz>
   srcversion:     A5D80907FF8B39B7C72B9C8
   depends:        
   retpoline:      Y
   intree:         Y
   vermagic:       5.15.0-107-generic SMP mod_unload modversions 
   sig_id:         PKCS#7
   signer:         Build daemon digital signature
   sig_key:        5C:DC:8A:2B:EE:7C:...
   sig_hash:       sha512
   parm:           redirect_dir:bool Enable redirectdir feature by default (bool)
   parm:           metacopy:bool Enable metacopy feature by default (bool)
   ```

3. **Analyze active kernel modules and low-level dynamic loading (`insmod` vs `modprobe`).**
   Use `lsmod` combined with `grep` to trace module usage counts and dependencies. Compare high-level module loading via `modprobe` against raw binary insertion via `insmod`.

   ```bash
   lsmod | grep -E "^(dummy|bonding|overlay|e1000e)"
   ```

   **Expected Output:** *(Empty if `dummy` is not loaded)*

   Now, load the virtual network interface module `dummy` with custom parameter options using `modprobe`, then confirm its presence:

   ```bash
   sudo modprobe dummy numdummies=2
   lsmod | grep dummy
   ```

   **Expected Output:**
   ```text
   dummy                  16384  0
   ```

   Inspect the instantiated devices in sysfs:
   ```bash
   ls -l /sys/class/net/dummy*
   ```

   **Expected Output:**
   ```text
   lrwxrwxrwx 1 root root 0 Aug 06 10:15 /sys/class/net/dummy0 -> ../../devices/virtual/net/dummy0
   lrwxrwxrwx 1 root root 0 Aug 06 10:15 /sys/class/net/dummy1 -> ../../devices/virtual/net/dummy1
   ```

4. **Simulate manual dependency resolution failure with `insmod` and unloading with `rmmod`.**
   Attempt loading a kernel object file directly using `insmod` without satisfying dependencies, observe the error, then cleanly unload the `dummy` module using `rmmod`.

   ```bash
   sudo rmmod dummy
   ```

   Identify a target binary module requiring a dependency (e.g., `vxlan` requiring `udp_tunnel`):
   ```bash
   modinfo -F depends vxlan
   ```

   **Expected Output:**
   ```text
   udp_tunnel,ip6_udp_tunnel
   ```

   Attempting to directly `insmod` `vxlan.ko` without loading `udp_tunnel.ko` first:
   ```bash
   VXLAN_PATH=$(find /lib/modules/$(uname -r) -name "vxlan.ko*")
   sudo insmod $VXLAN_PATH
   ```

   **Expected Output:**
   ```text
   insmod: ERROR: could not insert module /lib/modules/5.15.0-107-generic/kernel/drivers/net/vxlan/vxlan.ko: Unknown symbol in module
   ```

5. **Establish persistent module blacklisting and parameter assignment in `/etc/modprobe.d/`.**
   Create a syntactically complete configuration file inside `/etc/modprobe.d/` to enforce module aliases, parameter overrides, and driver blacklisting.

   ```bash
   cat << 'EOF' | sudo tee /etc/modprobe.d/sre-kernel-hardening.conf
   # Hardening and Custom Parameter Configuration
   # Prevents auto-loading of legacy block filesystem drivers
   blacklist cramfs
   blacklist freevxfs
   blacklist hfs
   blacklist hfsplus
   blacklist jffs2

   # Configure parameter defaults for dummy networking module
   options dummy numdummies=4

   # Assign custom alias for hardware abstraction
   alias virtual-net4 dummy
   EOF
   ```

   Re-generate the module dependency lookup file `modules.dep` and binary indices using `depmod`:

   ```bash
   sudo depmod -a
   grep "dummy.ko" /lib/modules/$(uname -r)/modules.dep
   ```

   **Expected Output:**
   ```text
   kernel/drivers/net/dummy.ko:
   ```

---

### Verification Questions (Exercise 1)

1. What is the fundamental functional difference between `insmod` and `modprobe` when handling kernel driver initialization in a production environment?
2. How does the kernel expose runtime driver parameters to user space, and where in `/sys` or `/proc` can you verify the active value of `numdummies` after `modprobe dummy` is executed?

---

## Exercise 2: Production Kernel Compilation, Optimization, and DKMS Integration

### Objective
Acquire kernel source code, configure kernel build parameters using target configuration rules (`make menuconfig`, `make oldconfig`, `make localmodconfig`), compile kernel images (`bzImage`) and modules, install modules, and manage out-of-tree drivers with Dynamic Kernel Module Support (DKMS).

### Step-by-Step Execution Plan

1. **Prepare source code layout and inspect standard kernel directory structure.**
   Kernel sources reside under `/usr/src/linux-$(uname -r)` or dedicated build trees. Inspect the main Makefile and directory structure.

   ```bash
   cd /usr/src/
   ls -la
   ```

   **Expected Output:**
   ```text
   drwxr-xr-x  24 root root 4096 Aug  6 10:00 linux-headers-5.15.0-107
   drwxr-xr-x  12 root root 4096 Aug  6 10:00 linux-headers-5.15.0-107-generic
   ```

   Assuming a full kernel source tree resides in `/usr/src/linux`:
   ```bash
   cd /usr/src/linux
   ls -F
   ```
   **Expected Output:**
   ```text
   arch/   certs/    Documentation/  fs/      init/  Kconfig  lib/       Makefile  net/     scripts/  tools/
   block/  crypto/   drivers/        include/ ipc/   kernel/  LICENSES/  mm/       README   security/ virt/
   ```

2. **Configure kernel build parameters with target optimization strategies.**
   Copy the existing running node's kernel configuration from `/boot/config-$(uname -r)` or `/proc/config.gz` to `.config`.

   ```bash
   sudo cp /boot/config-$(uname -r) .config
   ```

   Apply `make localmodconfig` to trim unnecessary modules based on currently loaded drivers in `lsmod`, drastically reducing build surface and compilation time:

   ```bash
   yes "" | sudo make localmodconfig
   ```

   **Expected Output:**
   ```text
   *
   * Restart config...
   *
   *
   * System Capabilities
   *
   Using loaded modules from /tmp/modlist
   ...
   #
   # configuration written to .config
   #
   ```

3. **Execute selective target compilation (`bzImage` and `modules`).**
   Compile the compressed kernel image (`bzImage`) and hardware modules using multi-threaded jobs (`-j$(nproc)`).

   ```bash
   sudo make -j$(nproc) bzImage
   sudo make -j$(nproc) modules
   ```

   **Expected Output:**
   ```text
   ...
   Kernel: arch/x86/boot/bzImage is ready  (#1)
   ```

4. **Install kernel modules and system boot files.**
   Deploy the compiled driver modules into `/lib/modules/$(uname -r)-custom/` and copy the bootable kernel image to `/boot/`.

   ```bash
   sudo make modules_install
   sudo make install
   ```

   **Expected Output:**
   ```text
   INSTALL arch/x86/boot/bzImage
   sh ./arch/x86/boot/install.sh 5.15.0-custom arch/x86/boot/bzImage \
           System.map "/boot"
   ```

5. **Manage out-of-tree drivers using DKMS.**
   Inspect DKMS tree status to ensure third-party modules (e.g., ZFS, NVIDIA, or custom network drivers) automatically rebuild when kernel headers update.

   ```bash
   dkms status
   ```

   **Expected Output:**
   ```text
   wireguard/1.0.20210219, 5.15.0-107-generic, x86_64: installed
   ```

   To manually add, build, and install a module under DKMS management:
   ```bash
   # Conceptual workflow for DKMS registration
   sudo dkms add -m custom-driver -v 1.0.0
   sudo dkms build -m custom-driver -v 1.0.0
   sudo dkms install -m custom-driver -v 1.0.0
   ```

---

### Verification Questions (Exercise 2)

1. What specific operational problem does `make localmodconfig` solve in production CI/CD kernel building pipelines, and what risk does it introduce if run inside a minimal container environment?
2. Explain the purpose of DKMS (`dkms`) and how it interacts with kernel upgrades on production Linux systems.

---

## Exercise 3: Kernel Patch Management, Rejection Analysis, and Source Maintenance

### Objective
Apply official kernel patch sets (`patch`), handle compressed patch streams (`zcat`, `bzcat`, `xzcat`), evaluate strip levels (`-p`), and analyze/resolve merge rejection files (`.rej`).

### Step-by-Step Execution Plan

1. **Understand kernel patch naming conventions and strip level mechanisms.**
   Review standard patch header format:

   ```diff
   --- a/drivers/net/dummy.c	2024-08-06 10:00:00.000000000 +0000
   +++ b/drivers/net/dummy.c	2024-08-06 10:05:00.000000000 +0000
   @@ -42,6 +42,7 @@
    static void dummy_setup(struct net_device *dev)
    {
        ether_setup(dev);
   +    /* Custom SRE Optimization Patch */
        dev->priv_flags |= IFF_LIVE_ADDR_CHANGE;
    }
   ```

2. **Simulate patch application dry-run using xzcat and patch.**
   Download/create a unified diff patch and perform a non-destructive test using `--dry-run` with `-p1` strip level.

   ```bash
   cat << 'EOF' > /tmp/example-kernel-fix.patch
   --- a/drivers/net/dummy.c
   +++ b/drivers/net/dummy.c
   @@ -42,3 +42,4 @@ static void dummy_setup(struct net_device *dev)
        ether_setup(dev);
   +    /* SRE Enterprise patch */
        dev->flags |= IFF_NOARP;
   EOF
   ```

   Compress the patch to emulate standard kernel distribution formats (`.patch.xz`):
   ```bash
   xz -k /tmp/example-kernel-fix.patch
   ```

   Apply the patch in dry-run mode from within the kernel source directory:
   ```bash
   cd /usr/src/linux
   xzcat /tmp/example-kernel-fix.patch.xz | patch -p1 --dry-run
   ```

   **Expected Output:**
   ```text
   checking file drivers/net/dummy.c
   Hunk #1 succeeded at 42.
   ```

3. **Simulate and analyze patch rejection files (`.rej`).**
   Intentionally apply a conflicting patch to observe rejection file generation.

   ```bash
   cat << 'EOF' > /tmp/conflicting.patch
   --- a/drivers/net/dummy.c
   +++ b/drivers/net/dummy.c
   @@ -999,3 +999,4 @@
    NON_EXISTENT_FUNCTION_TRIGGER_REJECT();
   EOF
   ```

   Apply the patch without `--dry-run`:
   ```bash
   patch -p1 < /tmp/conflicting.patch
   ```

   **Expected Output:**
   ```text
   can't find file to patch at input line 3
   Perhaps you used the wrong -p or --strip option?
   The text leading up to this was:
   --------------------------
   |--- a/drivers/net/dummy.c
   |+++ b/drivers/net/dummy.c
   --------------------------
   File to patch: drivers/net/dummy.c
   patching file drivers/net/dummy.c
   Hunk #1 FAILED at 999.
   1 out of 1 hunk FAILED -- saving rejects to file drivers/net/dummy.c.rej
   ```

   Inspect the resulting rejection log:
   ```bash
   cat drivers/net/dummy.c.rej
   ```

   **Expected Output:**
   ```text
   --- drivers/net/dummy.c
   +++ drivers/net/dummy.c
   @@ -999,3 +999,4 @@
    NON_EXISTENT_FUNCTION_TRIGGER_REJECT();
   ```

4. **Revert a previously applied patch.**
   Use the `-R` flag to cleanly reverse an applied patch:

   ```bash
   patch -p1 -R < /tmp/example-kernel-fix.patch
   ```

   **Expected Output:**
   ```text
   patching file drivers/net/dummy.c
   ```

---

### Verification Questions (Exercise 3)

1. What does the `-p1` parameter signify when executing `patch -p1 < diff.patch` inside the root of a Linux kernel source tree?
2. If a patch application fails and generates a `.rej` file, what steps must a Systems Engineer take to complete the kernel build safely?

---

## Exercise 4: Dynamic Kernel Tuning, Initramfs Reconstruction, and Udev Event Tracing

### Objective
Configure dynamic kernel parameters via `/proc/sys/` and persistent `/etc/sysctl.d/` manifests, extract and rebuild initial RAM disk images using `dracut`/`lsinitrd`, and trace live hardware events using `udevadm`.

### Step-by-Step Execution Plan

1. **Perform dynamic runtime kernel parameter tuning (`sysctl`).**
   Inspect active IP forwarding and virtual memory swappiness parameters:

   ```bash
   sysctl net.ipv4.ip_forward
   sysctl vm.swappiness
   ```

   **Expected Output:**
   ```text
   net.ipv4.ip_forward = 0
   vm.swappiness = 60
   ```

   Deploy a production-grade Kubernetes/SRE networking and memory tuning profile under `/etc/sysctl.d/`:

   ```bash
   cat << 'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-production.conf
   # Network Forwarding & Bridge Filtering Requirements
   net.ipv4.ip_forward = 1
   net.bridge.bridge-nf-call-iptables = 1
   net.bridge.bridge-nf-call-ip6tables = 1

   # SRE Memory & Socket Optimizations
   vm.swappiness = 10
   vm.overcommit_memory = 1
   net.core.somaxconn = 32768
   EOF
   ```

   Load parameters dynamically without rebooting:
   ```bash
   sudo sysctl --system
   ```

   **Expected Output:**
   ```text
   * Applying /etc/sysctl.d/99-kubernetes-production.conf ...
   net.ipv4.ip_forward = 1
   net.bridge.bridge-nf-call-iptables = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   vm.swappiness = 10
   vm.overcommit_memory = 1
   net.core.somaxconn = 32768
   ```

2. **Inspect and reconstruct the Initial RAM Disk (`initramfs` / `initrd`).**
   List modules stored inside the current boot initramfs using `lsinitrd` (or `lsinitcpio` on Arch-based distributions):

   ```bash
   sudo lsinitrd /boot/initramfs-$(uname -r).img | grep -E "(virtio|scsi|ext4)"
   ```

   **Expected Output:**
   ```text
   -rw-r--r--   1 root     root        34816 Apr 26 13:28 usr/lib/modules/5.15.0-107-generic/kernel/drivers/net/virtio_net.ko
   -rw-r--r--   1 root     root        28672 Apr 26 13:28 usr/lib/modules/5.15.0-107-generic/kernel/drivers/scsi/scsi_mod.ko
   ```

   Rebuild the initramfs image for the running kernel using `dracut` (or `update-initramfs -u` on Debian/Ubuntu systems), ensuring new drivers or storage configuration are included at boot time:

   ```bash
   # Using dracut (RedHat/SUSE family)
   sudo dracut --force --verbose /boot/initramfs-$(uname -r).img $(uname -r)
   ```

   **Expected Output:**
   ```text
   *** Creating image file '/boot/initramfs-5.15.0-107-generic.img' ***
   *** Creating initramfs image file '/boot/initramfs-5.15.0-107-generic.img' done ***
   ```

3. **Trace device discovery and rules processing with `udevadm`.**
   Monitor kernel uevents and udev events in real time:

   ```bash
   sudo udevadm monitor --kernel --udev --subsystem-match=net
   ```

   *(In a second terminal, trigger an interface state change or modprobe dummy to observe events)*

   **Expected Output:**
   ```text
   KERNEL[12345.6789] add      /devices/virtual/net/dummy0 (net)
   UDEV  [12345.6812] add      /devices/virtual/net/dummy0 (net)
   ```

   Query udev database properties for a target disk device (`/dev/sda` or `/dev/vda`):
   ```bash
   udevadm info --query=all --name=/dev/sda
   ```

   **Expected Output:**
   ```text
   P: /devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0/block/sda
   N: sda
   L: 0
   E: DEVPATH=/devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0/block/sda
   E: DEVNAME=/dev/sda
   E: DEVTYPE=disk
   E: DISK_SEQ=1
   E: SUBSYSTEM=block
   E: ID_BUS=ata
   E: ID_MODEL=SATA_SSD_500GB
   E: ID_SERIAL_SHORT=S432NY0N123456
   ```

4. **Author a custom persistent udev rule for predictable device naming.**
   Write a syntactically valid udev rule file inside `/etc/udev/rules.d/` to enforce network interface renaming based on MAC address matching.

   ```bash
   cat << 'EOF' | sudo tee /etc/udev/rules.d/70-persistent-sre-net.rules
   # /etc/udev/rules.d/70-persistent-sre-net.rules
   # Enforce predictable naming for primary interface
   SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="52:54:00:12:34:56", NAME="sre0"
   EOF
   ```

   Test rule evaluation without rebooting using `udevadm test`:
   ```bash
   sudo udevadm control --reload-rules
   sudo udevadm trigger --subsystem-match=net
   ```

---

### Verification Questions (Exercise 4)

1. What critical role does `initramfs` play during the boot sequence of a Linux system before the root filesystem is mounted?
2. Explain the execution precedence of udev rules files located across `/lib/udev/rules.d/`, `/etc/udev/rules.d/`, and `/run/udev/rules.d/`.

---

<details>
<summary>Verification Answers & Detailed Architectural Analysis</summary>

### Exercise 1 Solutions & Mechanical Deep-Dive

**Answer 1.1:**
`modprobe` is an intelligent, high-level module management utility that resolves module dependencies automatically by referencing the binary dependency index (`/lib/modules/$(uname -r)/modules.dep.bin` generated by `depmod`). When loading a driver, `modprobe` recursively loads all required prerequisite modules first. Conversely, `insmod` is a low-level utility that executes the `finit_module()` or `init_module()` system call directly on a raw `.ko` file binary provided via absolute path. `insmod` performs no dependency resolution; if any underlying kernel symbol required by the binary is unexported or missing from memory, `insmod` immediately fails with `Unknown symbol in module`.

**Answer 1.2:**
The Linux kernel exposes runtime driver parameters via the `/sys` (sysfs) pseudo-filesystem under `/sys/module/<module_name>/parameters/`. After executing `sudo modprobe dummy numdummies=2`, the active value of `numdummies` can be verified directly by reading the corresponding sysfs entry:
```bash
cat /sys/module/dummy/parameters/numdummies
# Output: 2
```
Additionally, global kernel operational flags are exposed under `/proc/sys/`.

---

### Exercise 2 Solutions & Mechanical Deep-Dive

**Answer 2.1:**
`make localmodconfig` analyzes the currently loaded modules (obtained by reading `/proc/modules` or `lsmod`) and updates `.config` so that only the drivers actively running on the system are selected for compilation. In production CI/CD pipelines, this dramatically reduces kernel source compilation time from hours to minutes and minimizes the memory footprint of the built artifacts. 
*Risk:* If `make localmodconfig` is executed inside a bare-bones virtual machine, container, or build worker where storage drivers (e.g., `nvme`, `mpt3sas`), network cards, or USB drivers for production physical hardware are not currently loaded into memory, the generated `.config` will strip those drivers. The resulting custom kernel will panic (`unable to mount root fs`) when booted on target bare-metal host platforms.

**Answer 2.2:**
Dynamic Kernel Module Support (DKMS) is a framework designed to enable out-of-tree kernel driver modules (drivers whose source code is not included in the mainline Linux kernel tree, such as proprietary GPU drivers, ZFS storage modules, or specialized network drivers) to be automatically re-compiled and re-linked whenever a new kernel version or kernel header package is installed. Without DKMS, upgrading a production kernel from version `5.15.0-106` to `5.15.0-107` would cause all out-of-tree binary modules to fail loading due to kernel module symbol magic (`vermagic`) mismatches.

---

### Exercise 3 Solutions & Mechanical Deep-Dive

**Answer 3.1:**
The `-p1` flag instructs the `patch` utility to strip **one** leading slash and all preceding directory names from the pathnames specified inside the patch file headers. Patch headers generated by source control tools like Git contain pseudo-paths like `a/drivers/net/dummy.c` and `b/drivers/net/dummy.c`. Running `patch -p1` strips `a/` and `b/`, mapping the diff target relative to the current working directory (`drivers/net/dummy.c`), allowing successful execution from the root of the kernel tree.

**Answer 3.2:**
When a patch hunk fails to apply cleanly, `patch` outputs a `.rej` (rejection) file containing only the unapplied diff hunks and creates a `.orig` backup file of the unpatched source file. To safely complete the build, an SRE must:
1. Open the `.rej` file to inspect the exact lines of code and contextual line numbers that failed.
2. Inspect the corresponding source file to understand why context matching failed (e.g., upstream code refactoring, structural edits, or missing intermediate patches).
3. Manually edit the source file to insert the intended changes safely.
4. Remove the remaining `.rej` and `.orig` files before starting compilation (`make`) to prevent unversioned artifacts from interfering with source control or build targets.

---

### Exercise 4 Solutions & Mechanical Deep-Dive

**Answer 4.1:**
`initramfs` (Initial RAM File System) is a root-filesystem image packaged as a compressed `cpio` archive loaded into memory by the bootloader (GRUB) alongside the kernel image (`bzImage`). Its core role is to provide an early user-space environment containing essential drivers, kernel modules (such as RAID controllers, NVMe/SCSI storage drivers, LVM modules, or LUKS encryption helpers), and setup utilities (`udev`, `systemd-udevd`, `init`) necessary to discover, unlock, mount, and pivot to (`pivot_root` / `switch_root`) the actual production root filesystem on storage hardware.

**Answer 4.2:**
Udev rules files are parsed in strict lexical directory priority order based on file basename matching across three system paths:
1. `/etc/udev/rules.d/` (Highest Priority - reserved for local system administrator overrides).
2. `/run/udev/rules.d/` (Intermediate Priority - runtime generated dynamic rules).
3. `/lib/udev/rules.d/` or `/usr/lib/udev/rules.d/` (Lowest Priority - system-installed package defaults).

If a rule file with the exact same name (e.g., `70-persistent-net.rules`) exists in both `/etc/udev/rules.d/` and `/lib/udev/rules.d/`, the file in `/etc/udev/rules.d/` completely overrides the file in `/lib/udev/rules.d/`. Within any given directory, rules are processed in alphabetical order (e.g., `10-local.rules` executes before `99-local.rules`).

</details>