# LPIC-1 (101-500) — Topic 101: System Architecture
## Guided Laboratory Exercises

**Sub-objectives covered**

| ID | Objective | Weight |
|----|-----------|--------|
| 101.1 | Determine and configure hardware settings | 2 |
| 101.2 | Boot the system | 3 |
| 101.3 | Change runlevels / boot targets and shutdown or reboot the system | 3 |

**Reference sources**
- LPI, *LPIC-1 Exam 101 Objectives, Version 5.0* — https://www.lpi.org/our-certifications/lpic-1-overview/
- Linux kernel documentation, *procfs* and *sysfs* — https://docs.kernel.org/filesystems/proc.html and https://docs.kernel.org/filesystems/sysfs.html
- Linux kernel documentation, *The kernel's command-line parameters* — https://docs.kernel.org/admin-guide/kernel-parameters.html
- freedesktop.org, *systemd* manual pages — https://www.freedesktop.org/software/systemd/man/
- GNU GRUB Manual 2.x — https://www.gnu.org/software/grub/manual/grub/grub.html

---

## Lab environment

> **Run every exercise in a disposable virtual machine, not on a workstation you care about.**
> Exercises 3, 4, 8, 9 and 10 unload kernel modules, switch targets, kill user sessions and deliberately break the boot. On a production host these are outage-generating operations.

Requirements:

- A systemd-based distribution (Debian 12+, Ubuntu 22.04+, Rocky/Alma 9, openSUSE Leap 15+, Fedora 38+).
- `root` access (all commands below assume `sudo` where needed).
- A VM snapshot taken **before** starting Exercise 10.
- Packages: `pciutils`, `usbutils`, `kmod`, `udev`/`systemd-udev`, `dmidecode`, `efibootmgr` (UEFI guests only), plus `dracut`/`initramfs-tools` depending on the family.

```bash
# Debian / Ubuntu
sudo apt install -y pciutils usbutils kmod dmidecode efibootmgr initramfs-tools

# RHEL family
sudo dnf install -y pciutils usbutils kmod dmidecode efibootmgr dracut
```

Record your baseline once; several exercises refer back to it:

```bash
uname -r; uname -m; cat /etc/os-release | head -2
```

---

# Exercise 1 — The three kernel interfaces: `/proc`, `/sys` and `/dev`

**Goal:** distinguish *what the kernel reports* (`procfs`), *how the kernel models devices* (`sysfs`), and *how userspace talks to devices* (device nodes). This distinction is the backbone of objective 101.1 and it is where most candidates lose points.

### Steps

1. Prove that `/proc` and `/sys` are not on disk:

```bash
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /proc /sys /dev /run
```

Expected output (abridged):

```text
TARGET SOURCE   FSTYPE   OPTIONS
/proc  proc     proc     rw,nosuid,nodev,noexec,relatime
/sys   sysfs    sysfs    rw,nosuid,nodev,noexec,relatime
/dev   devtmpfs devtmpfs rw,nosuid,size=4096k,nr_inodes=1013210,mode=755
/run   tmpfs    tmpfs    rw,nosuid,nodev,size=812584k,mode=755
```

2. Read the classic 101.1 files. Note that all of them are **zero bytes on disk** and generated on read:

```bash
ls -l /proc/cpuinfo /proc/meminfo /proc/interrupts /proc/ioports /proc/dma
head -12 /proc/cpuinfo
grep -E '^(MemTotal|MemAvailable|SwapTotal)' /proc/meminfo
```

3. Inspect the legacy hardware-resource files. On modern x86 they are still the canonical answer to "which IRQ / I/O port / DMA channel is this device using?":

```bash
sudo cat /proc/interrupts | head -15
sudo cat /proc/ioports  | head -15
sudo cat /proc/iomem    | head -10
cat /proc/dma
```

Expected `/proc/interrupts` shape:

```text
           CPU0       CPU1
  0:         28          0   IO-APIC   2-edge      timer
  1:          0         10   IO-APIC   1-edge      i8042
  9:          0          0   IO-APIC   9-fasteoi   acpi
 11:          0      15522   IO-APIC  11-fasteoi   virtio0
 12:          0        154   IO-APIC  12-edge      i8042
NMI:          0          0   Non-maskable interrupts
```

4. Walk the sysfs device model for the boot disk. `sysfs` exposes the kernel object hierarchy: `devices/` is the physical topology, `bus/` and `class/` are index views onto it:

```bash
ls /sys
ls -l /sys/block/ | head
ls -l /sys/class/net/
readlink -f /sys/class/net/$(ls /sys/class/net | grep -v lo | head -1)
```

Expected `readlink` output:

```text
/sys/devices/pci0000:00/0000:00:03.0/virtio0/net/enp0s3
```

5. Read attributes instead of parsing command output — this is the production-grade habit:

```bash
DISK=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || echo sda)
cat /sys/block/$DISK/size            # size in 512-byte sectors, always
cat /sys/block/$DISK/queue/rotational # 1 = spinning disk, 0 = SSD/virtual
cat /sys/block/$DISK/queue/scheduler
cat /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor
```

6. Contrast with `/dev`. Device nodes are *not* data — they are (type, major, minor) triples that route `read()`/`write()` to a driver:

```bash
ls -l /dev/sda /dev/null /dev/tty0 /dev/random 2>/dev/null
grep -E ' (sd|nvme|tty|mem)$' /proc/devices
stat -c '%n %F major=%t minor=%T' /dev/null /dev/sda 2>/dev/null
```

Expected:

```text
brw-rw---- 1 root disk    8,  0 Aug  6 09:12 /dev/sda
crw-rw-rw- 1 root root    1,  3 Aug  6 09:12 /dev/null
crw--w---- 1 root tty     4,  0 Aug  6 09:12 /dev/tty0
```

> Note `/proc/devices` prints major numbers in hexadecimal? **No** — it prints them in decimal. `stat -c '%t'` is the one that prints hex. Verify both with `/dev/null` (major 1, minor 3).

### Comprehension check — block 1

- **Q1.1** `/proc/cpuinfo` reports `ls -l` size 0 but `wc -c` returns several thousand bytes. Explain the mechanism.
- **Q1.2** A colleague asks you to find the IRQ used by the NIC. Give two independent command paths — one through `/proc`, one through `/sys`.
- **Q1.3** `/dev` is mounted as `devtmpfs`, not `tmpfs`. What does the kernel do with `devtmpfs` that it does not do with `tmpfs`, and which component then adds permissions and symlinks?
- **Q1.4** Which of `/proc`, `/sys`, `/dev` survives if you boot with `init=/bin/bash` and nothing else? Why does that matter for rescue work?

---

# Exercise 2 — Bus enumeration: PCI, USB, and driver binding

**Goal:** go from "an unknown device is in this machine" to "this exact driver is bound to it", which is the diagnostic path for every "hardware not working" ticket.

### Steps

1. Enumerate PCI devices with numeric IDs **and** driver binding. `-nnk` is the single most useful invocation in the objective:

```bash
lspci -nnk | head -30
```

Expected (QEMU/KVM guest, abridged):

```text
00:01.1 IDE interface [0101]: Intel Corporation 82371SB PIIX3 IDE [Natoma/Triton II] [8086:7010]
	Subsystem: Red Hat, Inc. QEMU Virtual Machine [1af4:1100]
	Kernel driver in use: ata_piix
	Kernel modules: ata_piix, pata_acpi, ata_generic
00:03.0 Ethernet controller [0200]: Red Hat, Inc. Virtio network device [1af4:1000]
	Subsystem: Red Hat, Inc. Device [1af4:0001]
	Kernel driver in use: virtio-pci
```

2. Decode the address notation and cross-check it in sysfs. `00:03.0` is `domain:bus:device.function` = `0000:00:03.0`:

```bash
lspci -s 00:03.0 -vv | head -20
ls -l /sys/bus/pci/devices/0000:00:03.0/driver
cat /sys/bus/pci/devices/0000:00:03.0/{vendor,device,class}
```

3. Do the same for USB. `lsusb -t` gives the physical tree with the driver per interface, which `lsusb` alone does not:

```bash
lsusb
lsusb -t
lsusb -v -d 1d6b:0002 2>/dev/null | head -20
```

Expected tree:

```text
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 5000M
/:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
    |__ Port 002: Dev 002, If 0, Class=Human Interface Device, Driver=usbhid, 12M
```

4. Locate the raw USB device files that `lsusb` actually reads:

```bash
ls -l /dev/bus/usb/001/
lsusb | awk '{print "Bus "$2" Device "$4}' | tr -d ':'
```

5. Query firmware-level inventory (DMI/SMBIOS) — the source of truth for "which motherboard / how many DIMM slots":

```bash
sudo dmidecode -t system | sed -n '1,15p'
sudo dmidecode -s bios-version
sudo dmidecode -t memory | grep -E 'Size|Locator' | head -8
```

### Comprehension check — block 2

- **Q2.1** `lspci -nnk` shows `Kernel modules: ata_piix, pata_acpi` but no `Kernel driver in use:` line. What is the operational meaning, and what are two plausible causes?
- **Q2.2** You must open a vendor bug report for a NIC. Which exact string identifies the hardware unambiguously, and which command prints it?
- **Q2.3** Why does `lsusb -t` show a `Driver=` per *interface* rather than per *device*? Give a concrete device that binds two different drivers at once.
- **Q2.4** `lsusb` on a minimal container prints nothing while `lspci` works. What is missing?

---

# Exercise 3 — Kernel modules: dependencies, parameters, blacklists

**Goal:** control which drivers the kernel loads. Objective 101.1 expects `lsmod`, `modprobe`, `modinfo`, `/etc/modprobe.d/`.

> **VM only.** Removing a module that backs your root filesystem or your only NIC will disconnect or hang the machine.

### Steps

1. Read the loaded-module table and prove where it comes from:

```bash
lsmod | head
head -3 /proc/modules
```

`lsmod` output columns are `Module | Size | Used by`:

```text
Module                  Size  Used by
vfat                   20480  1
fat                    86016  1 vfat
xfs                  1990656  1
libcrc32c              16384  1 xfs
```

2. Interrogate a module before touching it:

```bash
modinfo vfat | head -12
modinfo -F depends vfat
modinfo -p loop        # parameters this module accepts
modinfo -n loop        # absolute path of the .ko file
```

3. Load a harmless module and observe dependency resolution. `dm_mod` or `loop` are safe choices:

```bash
lsmod | grep -c '^loop' || true
sudo modprobe -v loop max_loop=8
lsmod | grep '^loop'
cat /sys/module/loop/parameters/max_loop
```

`modprobe -v` prints each `insmod` it performs, including dependencies:

```text
insmod /lib/modules/6.1.0-18-amd64/kernel/drivers/block/loop.ko max_loop=8
```

4. Show why `insmod` is not a substitute for `modprobe`:

```bash
sudo modprobe -r loop
sudo insmod $(modinfo -n vfat)      # fails: unknown symbol / unresolved deps
sudo modprobe -v vfat               # succeeds: pulls in fat first
lsmod | grep -E '^(vfat|fat)'
```

5. Make a parameter persistent, and blacklist a driver:

```bash
echo 'options loop max_loop=16' | sudo tee /etc/modprobe.d/loop.conf
echo -e 'blacklist pcspkr\ninstall pcspkr /bin/false' | sudo tee /etc/modprobe.d/blacklist-pcspkr.conf
sudo modprobe -r loop && sudo modprobe loop
cat /sys/module/loop/parameters/max_loop     # -> 16
```

6. Force a module to load **at boot** (the opposite direction), and rebuild the dependency database:

```bash
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo depmod -a
grep -m3 'loop.ko' /lib/modules/$(uname -r)/modules.dep
```

7. Clean up:

```bash
sudo modprobe -r loop
sudo rm -f /etc/modprobe.d/loop.conf /etc/modules-load.d/br_netfilter.conf
```

### Comprehension check — block 3

- **Q3.1** `lsmod` shows `fat 86016 1 vfat`. Write the exact command that will fail, and explain the kernel-level reason.
- **Q3.2** `blacklist foo` in `/etc/modprobe.d/foo.conf` does not stop `foo` from loading. Name two distinct reasons this happens in practice and the fix for each.
- **Q3.3** What is the difference in effect between `/etc/modprobe.d/x.conf` and `/etc/modules-load.d/x.conf`?
- **Q3.4** After copying a `.ko` into `/lib/modules/$(uname -r)/extra/`, `modprobe` still says "Module not found". What did you forget?

---

# Exercise 4 — udev: from uevent to device node

**Goal:** understand the chain *kernel uevent → udevd → device node + permissions + persistent symlinks*, and write a rule. Objective 101.1 names udev and D-Bus explicitly.

### Steps

1. Watch the event stream live. Open two terminals; in the first:

```bash
sudo udevadm monitor --udev --kernel --property
```

In the second, generate events (attach a USB device in the VM, or use a loop device):

```bash
sudo modprobe loop
truncate -s 64M /tmp/lab.img
sudo losetup -f --show /tmp/lab.img       # e.g. /dev/loop0
```

Expected in the monitor (abridged):

```text
KERNEL[812.114] add      /devices/virtual/block/loop0 (block)
ACTION=add
DEVNAME=/dev/loop0
DEVTYPE=disk
SUBSYSTEM=block
UDEV  [812.147] add      /devices/virtual/block/loop0 (block)
ID_FS_TYPE=
```

Note the two lines per event: `KERNEL[...]` is the raw uevent, `UDEV[...]` is after rule processing.

2. Read everything udev knows about a node, in both forms:

```bash
udevadm info -q property -n /dev/loop0
udevadm info -a -n /dev/loop0 | head -25     # attribute walk, parent by parent
```

The `-a` walk is what you copy `ATTR{}`/`ATTRS{}` keys from when writing rules:

```text
  looking at device '/devices/virtual/block/loop0':
    KERNEL=="loop0"
    SUBSYSTEM=="block"
    DRIVER==""
    ATTR{ro}=="0"
    ATTR{size}=="131072"
```

3. Inspect the persistent-name directories udev builds — these are why `/etc/fstab` should never say `/dev/sda1`:

```bash
ls -l /dev/disk/by-uuid/ /dev/disk/by-id/ /dev/disk/by-path/ 2>/dev/null | head -20
blkid
findmnt -no SOURCE,UUID /
```

4. Write your own rule. Create `/etc/udev/rules.d/99-lab.rules`:

```bash
sudo tee /etc/udev/rules.d/99-lab.rules >/dev/null <<'EOF'
# Give every loop device a stable alias and a lab-writable group
SUBSYSTEM=="block", KERNEL=="loop[0-9]*", SYMLINK+="lab/%k", GROUP="disk", MODE="0660"
EOF
```

5. Reload and re-trigger without rebooting, then verify:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block --action=add
ls -l /dev/lab/
udevadm test /sys/class/block/loop0 2>&1 | grep -E 'SYMLINK|MODE|GROUP'
```

6. Peek at D-Bus, the *other* IPC bus named in the objective (udev moves device events; D-Bus moves service messages):

```bash
busctl list | head -10
busctl introspect org.freedesktop.systemd1 /org/freedesktop/systemd1 | head -10
```

7. Clean up:

```bash
sudo losetup -d /dev/loop0; rm -f /tmp/lab.img
sudo rm /etc/udev/rules.d/99-lab.rules && sudo udevadm control --reload-rules
```

### Comprehension check — block 4

- **Q4.1** In a rule, when do you use `ATTR{...}` versus `ATTRS{...}`, and why does mixing parents in one rule fail?
- **Q4.2** Rules live in `/lib/udev/rules.d` (or `/usr/lib/udev/rules.d`) and `/etc/udev/rules.d`. Which wins, and how exactly do you override a vendor rule named `60-net.rules`?
- **Q4.3** Your rule works after `udevadm trigger` but the device is absent at boot. Name the most common cause.
- **Q4.4** Explain why `SYMLINK+=` is used instead of `NAME=` for disks on modern systemd.

---

# Exercise 5 — Firmware and bootloader: BIOS/MBR versus UEFI/ESP

**Goal:** determine which boot path the machine actually took, and inspect GRUB 2 configuration correctly. Objective 101.2.

### Steps

1. Determine the firmware mode **from the running system** — never from assumption:

```bash
[ -d /sys/firmware/efi ] && echo "Booted UEFI" || echo "Booted BIOS/CSM"
ls /sys/firmware/efi/efivars 2>/dev/null | head -5
mokutil --sb-state 2>/dev/null || echo "mokutil not installed"
```

2. **UEFI path.** Read the firmware boot manager entries — these live in NVRAM, not on disk:

```bash
sudo efibootmgr -v
findmnt /boot/efi
sudo find /boot/efi/EFI -maxdepth 2 -name '*.efi'
```

Expected:

```text
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0000
Boot0000* UiApp         FvVol(7cb8bdc9-...)/FvFile(462caa21-...)
Boot0001* debian        HD(1,GPT,7f3a...,0x800,0x100000)/File(\EFI\debian\shimx64.efi)
```

3. **BIOS path.** Inspect the MBR. The first 446 bytes are boot code, then 64 bytes of partition table, then the `55 AA` signature:

```bash
sudo dd if=/dev/sda bs=512 count=1 status=none | hexdump -C | head -4
sudo dd if=/dev/sda bs=512 count=1 status=none | tail -c 2 | hexdump -C
```

4. Read the GRUB 2 layout. Note the family split — **never hand-edit the generated file**:

```bash
ls -l /boot/grub/grub.cfg 2>/dev/null || ls -l /boot/grub2/grub.cfg
grep -v '^#' /etc/default/grub | grep -v '^$'
ls /etc/grub.d/
sudo awk '/^menuentry|^submenu/ {print NR": "$0}' /boot/grub/grub.cfg 2>/dev/null | head
```

Typical `/etc/default/grub`:

```text
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
```

5. Regenerate the configuration the supported way (safe — it reproduces the current file):

```bash
# Debian/Ubuntu
sudo update-grub          # wrapper for: grub-mkconfig -o /boot/grub/grub.cfg
# RHEL family
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

6. Identify the alternative bootloader named in the objective:

```bash
bootctl status 2>/dev/null | head -12    # systemd-boot; also reports firmware + ESP
```

### Comprehension check — block 5

- **Q5.1** How do you prove a running system booted in UEFI mode, with a single test that cannot be fooled by the presence of an ESP in `/etc/fstab`?
- **Q5.2** You edited `/boot/grub/grub.cfg` to add `nomodeset` and it worked. Two weeks later a kernel update removed it. What is the correct place, and which command applies it?
- **Q5.3** In BIOS mode, GRUB 2 does not fit in 446 bytes. Where does stage 1.5 live on an MSDOS-partitioned disk, and what is the equivalent on a GPT/BIOS disk?
- **Q5.4** `efibootmgr` fails with "EFI variables are not supported on this system". Give the two most likely explanations.

---

# Exercise 6 — Kernel command line and the initramfs

**Goal:** read and modify the parameters the kernel was started with, and explain why an initramfs exists at all. Objective 101.2.

### Steps

1. Read the exact command line of the running kernel:

```bash
cat /proc/cmdline
```

Expected:

```text
BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=6f1c-...-9ab2 ro quiet
```

2. Map each token to its consumer:

```bash
tr ' ' '\n' < /proc/cmdline | nl
findmnt -no SOURCE,UUID /       # confirm root= matches the real root
systemd-analyze cat-config systemd/system.conf | head -5
```

3. Confirm that unrecognised parameters are handed to PID 1 as environment/arguments:

```bash
sudo dmesg | grep -i 'command line' | head -2
sudo dmesg | grep -i 'unknown kernel command line' | head -5
```

4. Inspect the initramfs — this is where "cannot mount root filesystem" is diagnosed:

```bash
ls -lh /boot/initr*

# Debian / Ubuntu (initramfs-tools)
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'bin/(sh|init)$|/init$' | head
lsinitramfs /boot/initrd.img-$(uname -r) | grep -cE '\.ko(\.[a-z]+)?$'

# RHEL family (dracut)
sudo lsinitrd /boot/initramfs-$(uname -r).img | head -20
sudo lsinitrd -f etc/cmdline.d/*.conf /boot/initramfs-$(uname -r).img 2>/dev/null
```

5. Extract it fully and look at the entry point:

```bash
mkdir -p /tmp/initrd && cd /tmp/initrd
# Debian/Ubuntu:
unmkinitramfs /boot/initrd.img-$(uname -r) . 2>/dev/null && ls
# Generic fallback for a plain gzip+cpio image:
# zcat /boot/initrd.img-$(uname -r) | cpio -idmv 2>/dev/null | tail -3
head -20 main/init 2>/dev/null || head -20 init 2>/dev/null
```

6. Rebuild it (idempotent, safe) and note that this is mandatory after changing storage drivers or `/etc/crypttab`:

```bash
# Debian / Ubuntu
sudo update-initramfs -u -k $(uname -r)
# RHEL family
sudo dracut -f /boot/initramfs-$(uname -r).img $(uname -r)
```

7. Practise a temporary parameter change **without persisting it**: reboot, press `e` at the GRUB menu, append `systemd.unit=rescue.target` to the `linux` line, press `Ctrl+X`. Log in as root, then:

```bash
cat /proc/cmdline
systemctl get-default
systemctl default        # leave rescue, continue to the default target
```

### Comprehension check — block 6

- **Q6.1** Why can the kernel not simply mount `root=UUID=...` directly and skip the initramfs? Give two concrete configurations that make the initramfs mandatory.
- **Q6.2** What is the final action the initramfs `/init` performs before real userspace starts, and what happens to the initramfs contents afterwards?
- **Q6.3** `/proc/cmdline` contains `quiet splash single`. Which component consumes each of the three, and what is the modern systemd spelling of `single`?
- **Q6.4** You added a storage driver to `/etc/modprobe.d/` and rebooted into a kernel panic "VFS: Unable to mount root fs". What step was skipped?

---

# Exercise 7 — Reading the boot: `dmesg`, `journalctl`, `systemd-analyze`

**Goal:** perform boot forensics on a machine that already rebooted. Objective 101.2 names `dmesg`, `journalctl -k` and the `/var/log/` files.

### Steps

1. Read the kernel ring buffer with human timestamps and severity filtering:

```bash
sudo dmesg -T | head -20
sudo dmesg --level=err,warn -T
sudo dmesg -H --facility=kern | tail -20
```

2. Understand why `dmesg` may refuse to run as a normal user:

```bash
sysctl kernel.dmesg_restrict
dmesg 2>&1 | head -2       # as non-root
```

3. Compare the ring buffer with the journal. The ring buffer is a fixed-size circular buffer in kernel memory; the journal can be persistent:

```bash
journalctl -k | head -5
journalctl -k -b | wc -l
journalctl --list-boots | tail -5
journalctl -b -1 -p err --no-pager | head -20   # previous boot, errors only
```

Expected `--list-boots`:

```text
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 3a0f9f1c...                      Mon 2026-08-04 08:12:03 UTC Mon 2026-08-04 19:44:51 UTC
 -1 91b2c7de...                      Tue 2026-08-05 08:03:12 UTC Tue 2026-08-05 18:20:07 UTC
  0 c44e1a02...                      Wed 2026-08-06 09:11:44 UTC Wed 2026-08-06 09:39:02 UTC
```

4. If `journalctl --list-boots` shows only boot `0`, the journal is volatile. Make it persistent:

```bash
grep -E '^#?Storage' /etc/systemd/journald.conf
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

5. Check the classic text logs still named in the objective (present on non-systemd and on systems running rsyslog):

```bash
ls -l /var/log/dmesg /var/log/boot.log /var/log/messages /var/log/syslog 2>/dev/null
sudo tail -5 /var/log/boot.log 2>/dev/null
```

6. Quantify the boot instead of describing it:

```bash
systemd-analyze time
systemd-analyze blame | head -10
systemd-analyze critical-chain
systemd-analyze critical-chain multi-user.target
```

Expected:

```text
Startup finished in 3.412s (firmware) + 231ms (loader) + 1.905s (kernel) + 4.117s (userspace) = 9.666s
graphical.target reached after 4.081s in userspace.
```

```text
graphical.target @4.081s
└─multi-user.target @4.080s
  └─nginx.service @3.902s +176ms
    └─network-online.target @3.898s
```

7. Identify units that failed during boot:

```bash
systemctl --failed
systemctl list-units --state=failed --no-legend
journalctl -b -u systemd-udev-settle.service --no-pager | tail -5
```

### Comprehension check — block 7

- **Q7.1** `dmesg` shows nothing about a disk error that a colleague saw yesterday, but `journalctl` finds it. Explain both behaviours.
- **Q7.2** `dmesg` timestamps default to seconds-since-boot. Why is `dmesg -T` approximate on a machine that suspended, and what is exact instead?
- **Q7.3** Distinguish `systemd-analyze blame` from `systemd-analyze critical-chain`. Which one do you use to shorten boot time, and why is the other one misleading?
- **Q7.4** Which single command shows only kernel messages of priority `err` or worse from the previous boot?

---

# Exercise 8 — Targets, runlevels and the SysVinit equivalence

**Goal:** query and switch the system state, and translate confidently between SysVinit runlevels and systemd targets. Objective 101.3.

> **VM only.** Step 4 terminates graphical and SSH sessions.

### Steps

1. Establish the current and default state:

```bash
systemctl get-default
systemctl list-units --type=target --state=active --no-pager
runlevel
who -r
```

Expected:

```text
graphical.target
N 5
         run-level 5  2026-08-06 09:11
```

2. Prove the mapping is implemented as symlinks, not as translation code:

```bash
ls -l /usr/lib/systemd/system/runlevel?.target
systemctl cat runlevel3.target | head -5
```

Expected:

```text
lrwxrwxrwx 1 root root 15 ... /usr/lib/systemd/system/runlevel0.target -> poweroff.target
lrwxrwxrwx 1 root root 13 ... /usr/lib/systemd/system/runlevel1.target -> rescue.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel2.target -> multi-user.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel3.target -> multi-user.target
lrwxrwxrwx 1 root root 17 ... /usr/lib/systemd/system/runlevel4.target -> multi-user.target
lrwxrwxrwx 1 root root 16 ... /usr/lib/systemd/system/runlevel5.target -> graphical.target
lrwxrwxrwx 1 root root 13 ... /usr/lib/systemd/system/runlevel6.target -> reboot.target
```

3. Inspect what a target actually pulls in:

```bash
systemctl list-dependencies multi-user.target | head -20
systemctl show -p Wants,Requires,AllowIsolate multi-user.target
```

4. Switch state at runtime (**console access required**):

```bash
sudo systemctl isolate multi-user.target
runlevel                     # -> 5 3
systemctl get-default        # unchanged: isolate is not persistent
sudo systemctl isolate graphical.target
```

5. Change the state that persists across reboots:

```bash
sudo systemctl set-default multi-user.target
ls -l /etc/systemd/system/default.target
sudo systemctl set-default graphical.target      # restore
```

6. Exercise the SysVinit compatibility commands the exam still tests:

```bash
sudo telinit 3               # accepted by systemd, equivalent to isolate runlevel3.target
runlevel
sudo init 5
ls -l /etc/inittab 2>/dev/null || echo "no /etc/inittab — systemd system"
```

7. Reach the two rescue states and note the difference:

```bash
systemctl cat rescue.target    | grep -E 'Requires|After|Description'
systemctl cat emergency.target | grep -E 'Requires|After|Description'
```

`rescue.target` requires `sysinit.target` (filesystems mounted, basic services up, single-user shell). `emergency.target` requires almost nothing: root mounted read-only, a shell, nothing else.

### Comprehension check — block 8

- **Q8.1** `runlevel` prints `N 3`. What do the two fields mean, and what would `3 5` mean?
- **Q8.2** Give the systemd equivalent of each SysVinit runlevel 0–6, and explain why 2, 3 and 4 all collapse to one target.
- **Q8.3** `systemctl isolate` fails on some units with "Operation refused, unit may not be isolated". Which unit property governs this, and why does it exist?
- **Q8.4** Distinguish `rescue.target` from `emergency.target` in terms of what is mounted and what is running. When do you need the second one?
- **Q8.5** After `systemctl set-default multi-user.target`, which file changed, and what is it?

---

# Exercise 9 — Shutdown, reboot, notification and inhibitors

**Goal:** stop a machine correctly, warn its users, cancel a mistake, and understand what can veto a shutdown. Objective 101.3 names `shutdown`, `wall`, `acpid`.

> **VM only, and use a second terminal**, since some steps schedule an actual poweroff.

### Steps

1. Schedule a shutdown with a delay and a message, then observe the two side effects:

```bash
sudo shutdown -h +10 "Kernel maintenance — save your work"
ls -l /run/systemd/shutdown/scheduled 2>/dev/null
cat /run/nologin 2>/dev/null
who
```

Expected broadcast on every terminal:

```text
Broadcast message from root@lab01 (Wed 2026-08-06 09:44:02 UTC):

Kernel maintenance — save your work
The system is going down for poweroff at Wed 2026-08-06 09:54:02 UTC!
```

2. Cancel it — the single most useful flag in this objective:

```bash
sudo shutdown -c
ls /run/nologin 2>/dev/null || echo "nologin removed"
```

3. Compare the notification-only mode and manual broadcast:

```bash
sudo shutdown -k +5 "Drill only — no shutdown will occur"
sudo shutdown -c
echo "Maintenance window opens in 15 minutes" | sudo wall
sudo wall -n "No banner header on this one"
```

4. Learn the equivalences precisely:

```bash
# All of the following halt/power off:
#   shutdown -h now        systemctl poweroff        init 0        poweroff
# All of the following reboot:
#   shutdown -r now        systemctl reboot          init 6        reboot
systemctl cat poweroff.target | grep -E 'Description|Requires'
```

5. Inspect inhibitors — the mechanism by which a package manager or a user session delays or blocks a shutdown:

```bash
systemd-inhibit --list
sudo systemd-inhibit --what=shutdown --who="lab" --why="demo" sleep 30 &
sleep 2; systemd-inhibit --list
kill %1
```

Expected:

```text
WHO           UID USER PID  COMM            WHAT                          WHY                       MODE
ModemManager  0   root 712  ModemManager    sleep                         ModemManager needs to...  delay
lab           0   root 4411 sleep           shutdown                      demo                      block
```

6. Configure hardware power-button behaviour — the modern replacement for `acpid` handling on a systemd system:

```bash
grep -E '^#?Handle(PowerKey|LidSwitch|SuspendKey)' /etc/systemd/logind.conf
systemctl status acpid 2>/dev/null | head -5
# Legacy path, still present on non-systemd systems:
ls /etc/acpi/events/ 2>/dev/null && cat /etc/acpi/events/powerbtn 2>/dev/null
```

7. Show the escalation ladder for a machine that will not stop cleanly (know it, use it last):

```bash
# 1. clean:      systemctl poweroff
# 2. skip units: systemctl poweroff --force          (equivalent to two Ctrl+Alt+Del)
# 3. immediate:  systemctl poweroff --force --force  (no unmount, no sync — data loss risk)
sysctl kernel.sysrq
```

### Comprehension check — block 9

- **Q9.1** What exactly does `shutdown -k` do, and how does it differ from `wall`?
- **Q9.2** A scheduled shutdown must be aborted. Give the command, and name the file whose removal proves it worked.
- **Q9.3** `systemctl poweroff` hangs for 90 seconds and then continues. Which mechanism produced the delay, and which two commands would you run *before* rebooting next time?
- **Q9.4** Explain the difference between an inhibitor in `block` mode and one in `delay` mode, and which one a laptop's `ModemManager` uses.
- **Q9.5** Why is `systemctl poweroff --force --force` dangerous, and what is the one legitimate use case?

---

# Exercise 10 — Capstone: diagnose and repair a broken boot

**Goal:** combine 101.2 and 101.3 under failure conditions. **Take a VM snapshot before starting.**

### Steps

1. Break it deliberately. Set a default target that cannot be reached because a required unit will fail:

```bash
sudo systemctl set-default graphical.target
sudo tee /etc/systemd/system/lab-broken.service >/dev/null <<'EOF'
[Unit]
Description=Deliberately failing lab unit
Before=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/false
RemainAfterExit=yes
[Install]
RequiredBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable lab-broken.service
sudo reboot
```

2. The machine stops short of a login prompt. Recover **without** the disk: at the GRUB menu press `e`, append to the `linux` line:

```text
systemd.unit=emergency.target
```

Press `Ctrl+X`. At the emergency shell:

```bash
mount -o remount,rw /
systemctl --failed
journalctl -b -p err --no-pager | tail -20
journalctl -b -u lab-broken.service --no-pager
```

3. Repair, verify, and return to normal operation without rebooting blind:

```bash
systemctl disable lab-broken.service
rm /etc/systemd/system/lab-broken.service
systemctl daemon-reload
systemctl default
systemctl --failed
```

4. Second failure mode — an unreachable root device. Simulate by editing the GRUB entry at boot to `root=UUID=00000000-0000-0000-0000-000000000000`. Observe:

```text
Gave up waiting for root file system device.
ALERT!  UUID=00000000-... does not exist.  Dropping to a shell!
(initramfs)
```

At the `(initramfs)` prompt, diagnose from inside the initramfs:

```text
(initramfs) cat /proc/cmdline
(initramfs) blkid
(initramfs) ls /dev/sd* /dev/vd* /dev/nvme*
(initramfs) exit
```

Reboot and correct the `root=` value from the GRUB editor; then make it permanent:

```bash
findmnt -no UUID /
sudo grep -n 'root=UUID' /boot/grub/grub.cfg | head -3
sudo update-grub        # or: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

5. Confirm the system is genuinely healthy, not merely booted:

```bash
systemctl is-system-running
systemctl --failed
systemd-analyze time
journalctl -b -p warning --no-pager | wc -l
```

`systemctl is-system-running` returns `running`, `degraded`, `maintenance`, `starting` or `stopping` — and sets the exit code accordingly, which makes it the correct check inside automation.

### Comprehension check — block 10

- **Q10.1** Why is `systemd.unit=emergency.target` the right first move here rather than `init=/bin/bash`? Name one thing each gives you that the other does not.
- **Q10.2** In emergency mode, why must you run `mount -o remount,rw /` before editing anything?
- **Q10.3** You reached an `(initramfs)` prompt. State definitively which stages of the boot chain succeeded and which one failed.
- **Q10.4** `systemctl is-system-running` returns `degraded` although you can log in normally. What does that mean, and what is the follow-up command?
- **Q10.5** A unit declared `RequiredBy=multi-user.target` blocked the boot; a unit declared `WantedBy=multi-user.target` would not have. Explain the dependency semantics.

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

## Exercise 1 — `/proc`, `/sys`, `/dev`

**A1.1** `/proc` is a *virtual* filesystem (`procfs`) backed by kernel functions, not by blocks on a device. `stat()` reports size 0 because the kernel has no cheap way to know the length before generating the content; the content is produced by a `seq_file` handler at `read()` time. `wc -c` actually reads the file, so it counts the bytes the handler emitted. Corollary: `/proc` files must be read, never `stat`ed, and a snapshot of one is only valid for the instant it was read.

**A1.2**
- procfs: `grep -i <ifname_driver> /proc/interrupts` — e.g. `grep virtio0 /proc/interrupts`; the first column is the IRQ.
- sysfs: `cat /sys/class/net/enp0s3/device/irq`, or via the PCI address `cat /sys/bus/pci/devices/0000:00:03.0/irq`.
(A third path exists for PCI hardware: `lspci -vv -s 00:03.0 | grep IRQ`.)

**A1.3** `devtmpfs` is populated *by the kernel itself*: as soon as a driver registers a device, the kernel creates the corresponding node with default ownership `root:root` and a default mode. This guarantees `/dev/console`, `/dev/null` and the root disk node exist before userspace runs — which is precisely what the initramfs needs. `tmpfs` would start empty. `udevd` then runs on top of `devtmpfs`, applying ownership, group, mode and the persistent `SYMLINK+=` aliases from the rules. Kernel = existence; udev = policy.

**A1.4** All three, as long as they are mounted. In practice with `init=/bin/bash` the kernel has mounted the real root but has *not* run the normal mount units, so you typically get `/dev` (devtmpfs, mounted by the kernel or the initramfs) but must mount the others yourself:

```bash
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -o remount,rw /
```

This matters because without `/proc` mounted, `ps`, `mount` (which reads `/proc/self/mounts`), `free` and `uname -a` behave incorrectly or fail — the first thing to do in that shell is mount them.

## Exercise 2 — PCI and USB

**A2.1** It means the hardware is present and enumerated, but **no driver is bound**, so the device is non-functional. The `Kernel modules:` line is `modprobe`'s *candidate* list from `modules.alias`, not evidence of binding. Common causes: (a) the module is blacklisted or missing from the initramfs/installed kernel package; (b) the module refused to bind — check `dmesg | grep -i <module>` for a probe failure, firmware missing (`/lib/firmware`), or the device is claimed by `vfio-pci` for passthrough. Verify with `ls -l /sys/bus/pci/devices/<addr>/driver` — the symlink is absent when unbound.

**A2.2** The numeric `vendor:device` ID pair (plus subsystem ID and revision), e.g. `[1af4:1000] (rev 01)`, subsystem `[1af4:0001]`. Command: `lspci -nn -s <addr>`, or machine-readable `lspci -nn -mm -s <addr>`. Human names come from `/usr/share/hwdata/pci.ids` and change between distro versions — the numeric ID does not.

**A2.3** USB is an interface-oriented bus: one physical device exposes one or more *interfaces*, each with its own class, and the kernel binds a driver **per interface**. A USB headset is the standard example — one interface binds `snd-usb-audio` (Audio class) and another binds `usbhid` (HID class, for the volume buttons). A USB Wi-Fi dongle with a built-in card reader is another: `rtl8xxxu` plus `usb-storage`.

**A2.4** `/dev/bus/usb` is not present. `lsusb` reads the usbfs nodes under `/dev/bus/usb/<bus>/<dev>` (and `/sys/bus/usb`), which a container normally does not receive; `lspci` can fall back to `/proc/bus/pci` and `/sys/bus/pci`, which are usually visible. Fix in a container: run privileged or bind-mount `/dev/bus/usb`.

## Exercise 3 — Kernel modules

**A3.1** `sudo modprobe -r fat` (or `rmmod fat`) fails with `FATAL: Module fat is in use by: vfat`. The "Used by" column is the module's *reference count* plus the list of holders. The kernel refuses to unload a module whose symbols are still referenced by another loaded module, because doing so would leave dangling function pointers in the loaded `vfat` code. Correct order: `modprobe -r vfat` first — or simply `modprobe -r vfat`, which with `-r` removes unused dependencies automatically.

**A3.2**
1. **The module is in the initramfs and loads before `/etc/modprobe.d/` on the real root is readable** — or the initramfs contains a stale copy of the config. Fix: rebuild the initramfs (`update-initramfs -u` / `dracut -f`).
2. **Something loads it explicitly rather than by alias.** `blacklist` only suppresses *alias-based* automatic loading; a direct `modprobe foo`, a `/etc/modules-load.d/` entry, or another module listing it as a dependency still loads it. Fix: `install foo /bin/false` (or `/bin/true`) in `/etc/modprobe.d/`, which overrides the install command itself. Add `modprobe.blacklist=foo` on the kernel command line to cover the initramfs stage too.

**A3.3** `/etc/modprobe.d/*.conf` configures **how** a module behaves *if and when* it is loaded — `options`, `alias`, `blacklist`, `install`, `softdep`. It never loads anything by itself. `/etc/modules-load.d/*.conf` (read by `systemd-modules-load.service`) is a plain list of module names to load **unconditionally at boot**. The Debian legacy equivalent of the latter is `/etc/modules`.

**A3.4** `sudo depmod -a`. `modprobe` resolves names and dependencies through `/lib/modules/$(uname -r)/modules.dep` and `modules.alias`, which are generated files. Until `depmod` regenerates them, a newly copied `.ko` is invisible to `modprobe` (though `insmod /full/path/foo.ko` would still work, without dependency resolution).

## Exercise 4 — udev

**A4.1** `ATTR{...}` matches an attribute of **the device the event is about**; `ATTRS{...}` matches an attribute of **that device or any of its ancestors**, walking up the chain. The trap: all `ATTRS{}` keys in a single rule must match on **the same parent device** — udev does not combine attributes from different ancestors. Writing `ATTRS{idVendor}=="8086", ATTRS{serial}=="ABC"` fails if `idVendor` lives on the USB device and `serial` on the SCSI disk. Use `udevadm info -a` and take all your `ATTRS{}` keys from one "looking at parent device" block.

**A4.2** `/etc/udev/rules.d` wins. udev merges all rule directories into a **single namespace sorted by filename**, and a file in `/etc` shadows a same-named file in `/lib` (or `/usr/lib`) entirely. To override `60-net.rules`: create `/etc/udev/rules.d/60-net.rules` (same name — replaces it completely, including with an empty file or a symlink to `/dev/null` to disable it), or create a higher-numbered file such as `/etc/udev/rules.d/99-my-net.rules` to run *after* it and change the outcome. Numbering matters more than location for ordering; location decides shadowing.

**A4.3** The rule file is not in the initramfs, or the matched attribute is not yet populated at the time the boot-time event fires. The common practical cause is rules needed for the root device (multipath, crypt, custom storage) that were added to `/etc/udev/rules.d` without rebuilding the initramfs — `update-initramfs -u` / `dracut -f` fixes it. A second cause is a rule that depends on a program (`PROGRAM=`/`IMPORT{program}=`) whose binary is not present in the initramfs.

**A4.4** `NAME=` *renames* the kernel's device node, which breaks every other consumer that expects the kernel name (`/proc/partitions`, `lsblk`, `dmesg` correlation) and is refused outright for block devices by modern systemd-udev. `SYMLINK+=` adds an *additional* stable path while leaving the kernel node intact, and `+=` appends instead of replacing, so multiple rules can contribute aliases. This is exactly how `/dev/disk/by-uuid/…` and `/dev/disk/by-id/…` are built.

## Exercise 5 — Firmware and bootloader

**A5.1** `[ -d /sys/firmware/efi ]`. That directory is created by the kernel **only** when it was handed an EFI system table by the firmware at boot. An ESP can be partitioned, formatted and mounted on a BIOS-booted machine, so `/etc/fstab`, `findmnt /boot/efi` and the presence of `\EFI\...\*.efi` files prove nothing about the boot mode. `bootctl status` reports the same fact in words.

**A5.2** `/boot/grub/grub.cfg` is generated by `grub-mkconfig` and is overwritten whenever a kernel package runs the hook. The correct place is `GRUB_CMDLINE_LINUX_DEFAULT` (applies to normal entries only) or `GRUB_CMDLINE_LINUX` (applies to normal **and** recovery entries) in `/etc/default/grub`. Apply with `update-grub` on Debian/Ubuntu or `grub2-mkconfig -o /boot/grub2/grub.cfg` on the RHEL family. Per-entry customisation that must survive regeneration goes in `/etc/grub.d/40_custom`.

**A5.3** On an MSDOS-partitioned BIOS disk, GRUB 2's `core.img` is written to the **MBR gap** — the unused sectors between the MBR (LBA 0) and the first partition (traditionally LBA 63, modernly LBA 2048). On a GPT disk booted via BIOS, that gap does not reliably exist, so GRUB requires a dedicated **BIOS Boot Partition** with GUID type `21686148-6449-6E6F-744E-656564454649` (`ef02` in `gdisk`), typically 1 MiB, holding `core.img`. Under UEFI there is no stage 1.5 at all: `grubx64.efi` is a complete EFI application loaded from the ESP by the firmware.

**A5.4** (a) The system booted in BIOS/legacy/CSM mode, so no EFI runtime services and no `/sys/firmware/efi/efivars` exist. (b) The system did boot UEFI but `efivarfs` is not mounted, or the kernel was booted with `noefi`/`efi=noruntime`, or you are inside a container/chroot without `/sys/firmware/efi/efivars` bind-mounted. Check with `ls /sys/firmware/efi/efivars` and `mount | grep efivarfs`.

## Exercise 6 — Kernel command line and initramfs

**A6.1** The kernel must mount the root filesystem, but the drivers to reach it may not be built into the vmlinuz — a generic distribution kernel is modular by design. Configurations that make the initramfs mandatory: (a) **root on LVM, RAID or LUKS** — the block device does not exist until `lvm`/`mdadm`/`cryptsetup` has assembled or unlocked it in userspace; (b) **root filesystem or storage controller driver built as a module** (e.g. XFS, Btrfs, NVMe or a vendor RAID HBA), since the module lives on the very filesystem that cannot yet be mounted; (c) **root over the network** (iSCSI, NFS) requiring NIC drivers and DHCP first; (d) **`root=UUID=`/`LABEL=` resolution**, which needs `blkid`-style scanning in userspace.

**A6.2** The initramfs `/init` mounts the real root at `/root` (or `/sysroot`), then calls **`switch_root`** (`pivot_root` in older schemes): it moves the new root to `/`, deletes the contents of the initramfs from RAM to free that memory, and `exec`s the real `/sbin/init` — which is why the new init keeps **PID 1**. Afterwards nothing of the initramfs remains in memory; this is why you cannot inspect it from the running system and must use `lsinitrd`/`lsinitramfs` against the image file.

**A6.3**
- `quiet` — consumed by the **kernel**: raises the console log level so only errors reach the screen (the messages still go to the ring buffer).
- `splash` — consumed by the **initramfs/userspace plymouth** boot-splash, not by the kernel.
- `single` — consumed by **init/PID 1**. Under systemd the modern spelling is `systemd.unit=rescue.target`; `single`, `s` and `1` are still honoured as compatibility aliases mapping to `rescue.target`.

**A6.4** The initramfs was not rebuilt. `/etc/modprobe.d/` on the real root is invisible to the initramfs, and the driver itself may need to be *included* in the image. Run `update-initramfs -u -k all` (Debian/Ubuntu) or `dracut -f --regenerate-all` (RHEL family). Recovery in the meantime: boot the previous kernel from the GRUB "Advanced options" submenu.

## Exercise 7 — Boot forensics

**A7.1** The kernel ring buffer is a **fixed-size circular buffer in kernel memory** (`CONFIG_LOG_BUF_SHIFT`, commonly 128 KiB–1 MiB) that is (a) wiped by a reboot and (b) overwritten by newer messages once full — a chatty driver can evict yesterday's disk error within minutes. `journalctl` reads the same messages from `systemd-journald`, which copies them out of `/dev/kmsg` and, if `/var/log/journal/` exists, stores them **persistently across reboots**. Correct habit: use `journalctl -k -b -1` for anything older than the current boot.

**A7.2** `dmesg` timestamps are recorded as the **monotonic clock** (seconds since boot). `dmesg -T` renders them as wall-clock by subtracting the monotonic offset from the current time — but the monotonic clock does not advance across suspend on some configurations, and the wall clock may have been stepped by NTP after boot, so the two drift and the rendered dates are wrong by the drift amount. What is exact: `journalctl -k`, because journald stamps each message with both `_SOURCE_MONOTONIC_TIMESTAMP` and a realtime timestamp at receipt.

**A7.3** `systemd-analyze blame` lists every unit sorted by its own initialization time — but a slow unit that nothing waits for costs zero wall-clock, so optimizing the top of `blame` often changes nothing. `critical-chain` shows the **dependency chain that actually determined when the target was reached**, with `@` = time the unit became active and `+` = time it took. Use `critical-chain` to shorten boot time; treat `blame` as a candidate list only after confirming the unit appears in the chain.

**A7.4** `journalctl -k -b -1 -p err` (add `--no-pager` for scripting). `-k` = kernel messages only, `-b -1` = previous boot, `-p err` = priority `err` (3) and more severe.

## Exercise 8 — Targets and runlevels

**A8.1** The output is `<previous> <current>`. `N` means "None" — there was no previous runlevel, i.e. this is the first state since boot. `3 5` means the system was in runlevel 3 and is now in runlevel 5 (someone ran `systemctl isolate graphical.target` or `init 5`). The data comes from the `utmp` record written at each transition, which is why `who -r` shows the same information.

**A8.2**

| Runlevel | systemd target | Meaning |
|---|---|---|
| 0 | `poweroff.target` | halt/power off |
| 1, `s`, `single` | `rescue.target` | single-user, root shell |
| 2 | `multi-user.target` | multi-user (Debian: with network) |
| 3 | `multi-user.target` | multi-user, text, networked |
| 4 | `multi-user.target` | undefined / site-specific |
| 5 | `graphical.target` | multi-user + display manager |
| 6 | `reboot.target` | reboot |

2, 3 and 4 collapse because the SysVinit distinction between them was **never standardised** — Debian used 2 as its normal multi-user level with networking, Red Hat used 3 for text and reserved 2 for "multi-user without NFS" and 4 for local use. systemd replaced the numeric ordering with an explicit dependency graph, so a single `multi-user.target` plus per-unit `Wants=`/`After=` expresses everything the three levels did, without the ambiguity.

**A8.3** `AllowIsolate=`. `systemctl isolate X` starts `X` and **stops every unit not required by X**, so it is only meaningful for units that describe a complete system state (targets). Allowing it on an arbitrary service would let `systemctl isolate sshd.service` tear down the entire system. Targets intended as isolation points set `AllowIsolate=yes`; check with `systemctl show -p AllowIsolate <unit>`.

**A8.4**
- `rescue.target` pulls in `sysinit.target` and `local-fs.target`: **all local filesystems are mounted**, `systemd-journald`, udev and basic system initialization have run, swap is on, and you get a single root shell. Network and multi-user services are not started.
- `emergency.target` pulls in essentially nothing: **only the root filesystem, mounted read-only**, plus a shell on the console. No other filesystems, no journald flush guarantee, no udev-driven setup.

You need `emergency.target` when the failure is in the mounting itself — a bad `/etc/fstab` entry, a corrupt `/var`, a missing LVM volume — because `rescue.target` would itself fail trying to mount those filesystems. First actions there: `mount -o remount,rw /`, then repair `/etc/fstab`, then `systemctl default`.

**A8.5** `/etc/systemd/system/default.target` — a **symlink** pointing to `/usr/lib/systemd/system/multi-user.target`. `set-default` does nothing more than replace that symlink; `get-default` reads it. This is why the change persists across reboots while `isolate` does not.

## Exercise 9 — Shutdown and notification

**A9.1** `shutdown -k` sends the shutdown warning wall message and creates `/run/nologin` (blocking new non-root logins) **but never actually shuts down** — it is the "drill" mode. `wall` only broadcasts an arbitrary message to all logged-in terminals: no schedule, no `/run/nologin`, no shutdown semantics. Use `wall` for announcements, `shutdown -k` to test the notification path of your maintenance procedure.

**A9.2** `sudo shutdown -c` (equivalently `systemctl cancel-shutdown` on recent systemd). Proof: `/run/nologin` is removed, and `/run/systemd/shutdown/scheduled` no longer exists. `shutdown -c` can also carry its own wall message: `shutdown -c "Maintenance postponed"`.

**A9.3** A unit failed to stop within its `TimeoutStopSec` (default 90 s in `DefaultTimeoutStopSec=`), so systemd waited, then sent `SIGKILL`. Before the next reboot: `systemctl list-jobs` during the stall to see what is pending, and afterwards `journalctl -b -1 | grep -iE 'timed out|killing|stop'` to name the unit. Then fix the unit's `ExecStop`/`KillMode`, or lower its `TimeoutStopSec=`. A frequent real cause is an NFS mount whose server is unreachable — check `systemd-analyze blame --order` and the `*.mount` units.

**A9.4** A `block` inhibitor **prevents** the operation entirely until it is released — `systemctl poweroff` will refuse (root can override with `--force` or `-i`/`--ignore-inhibitors`). A `delay` inhibitor does not prevent the operation; it postpones it for at most `InhibitDelayMaxSec` (default 5 s, in `/etc/systemd/logind.conf`) so the holder can finish critical work such as saving state. `ModemManager` takes a **`delay`** inhibitor on `sleep`, so it can cleanly disconnect the modem before suspend without ever being able to block a suspend indefinitely.

**A9.5** A single `--force` skips stopping units and unmounting cleanly but still tries to sync; a doubled `--force` invokes the reboot/poweroff syscall **immediately** — no unit shutdown, no filesystem unmount, no `sync()`. Any dirty page cache is lost, which means filesystem corruption and lost data on the next boot (a journalling filesystem will recover its metadata, not your application's writes). Legitimate use: a machine that is already so wedged that a clean shutdown cannot proceed and you have console access only — the alternative being a physical power cut, which is strictly worse because it also skips the syscall's own barriers. The `SysRq` sequence `R E I S U B` is the more controlled variant of the same idea, because `S` syncs and `U` remounts read-only before `B` reboots.

## Exercise 10 — Capstone

**A10.1** `systemd.unit=emergency.target` keeps **systemd as PID 1**, so `systemctl`, `journalctl -b`, `systemctl --failed` and unit manipulation all work — which is exactly what you need to diagnose a *unit* failure, and it lets you leave with `systemctl default` instead of rebooting. `init=/bin/bash` replaces PID 1 with a shell: systemd never runs, so no journal from this boot and no `systemctl` — but that is precisely what you want when **systemd itself or its configuration is the thing that is broken** (corrupt `/etc/systemd`, a broken `systemd` package, or a root password reset with SELinux relabel). Rule of thumb: unit failure → `emergency.target`; PID 1 or filesystem failure → `init=/bin/bash`.

**A10.2** `emergency.target` mounts the root filesystem **read-only** (and under `init=/bin/bash` the kernel honours the `ro` flag from `/proc/cmdline`). Any repair — editing `/etc/fstab`, deleting a bad unit, running `passwd`, `systemctl disable` — writes to `/etc` and will fail with `Read-only file system` until you remount. `systemctl daemon-reload` after the edit is equally necessary for unit changes to be seen.

**A10.3** Succeeded: firmware POST and boot-device selection; the bootloader (GRUB) located and loaded both the kernel and the initramfs; the kernel decompressed, initialized, unpacked the initramfs into a tmpfs and executed its `/init`. Failed: the initramfs could not find or mount the device named by `root=`, so it never reached `switch_root` and never executed the real `/sbin/init`. That narrows the fault to exactly three candidates: a wrong `root=` value, a missing storage/filesystem driver in the initramfs, or a device that genuinely does not exist (unassembled RAID/LVM, locked LUKS, absent disk).

**A10.4** `degraded` means the boot completed and the default target was reached, but **at least one unit is in the `failed` state**. The system is usable; something on it is not. Follow up with `systemctl --failed` to list them, then `journalctl -b -u <unit>` for each. It returns a non-zero exit status, which makes `systemctl is-system-running --wait` the correct health gate in provisioning scripts and CI images — a plain "did it boot?" check would pass a silently broken machine.

**A10.5** `WantedBy=` creates a **`Wants=`** dependency from the target to your unit: the target *tries* to start it, and if the unit fails, the target still reaches `active`. `RequiredBy=` creates a **`Requires=`** dependency: if your unit fails to start, the target is considered failed and is not activated, so the boot stops short of a login prompt. Both only take effect after `systemctl enable` (they live in the `[Install]` section and are realised as symlinks in `.wants/` or `.requires/` directories). Practical guidance: use `WantedBy=multi-user.target` for essentially every ordinary service; reserve `RequiredBy=`/`Requires=` for genuine hard prerequisites, and pair it with `After=` — `Requires=` alone specifies *whether*, not *when*, and without ordering both units start in parallel.

</details>