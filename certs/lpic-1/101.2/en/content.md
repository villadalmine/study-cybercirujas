# 101.2 — Boot the System

**Certification:** LPIC-1 (Exams 101-500 / 102-500, version 5.0)
**Objective:** Guide the system through the booting process
**Course weight:** 4.69

**Key knowledge areas covered here**

- Provide common commands to the boot loader and options to the kernel at boot time
- Demonstrate knowledge of the boot sequence from BIOS/UEFI to boot completion
- Understanding of SysVinit and systemd
- Awareness of Upstart
- Check boot events in the log files

**Terms and utilities:** `dmesg`, `journalctl`, BIOS, UEFI, bootloader, kernel, initramfs, init, SysVinit, systemd

---

## 1. The architectural problem: boot is the only code path you cannot SSH into

Every other failure in a Linux estate is debuggable with the tools you already run: `kubectl`, `ssh`, Prometheus, a shell. Boot is different. Between power-on and the moment `sshd` binds to `:22`, there is a window of five to ninety seconds in which **the machine is executing your configuration with no observability channel except a serial console you probably did not wire up**.

That asymmetry is what makes boot an SRE problem rather than a sysadmin trivia question.

### 1.1 Where this bites in production

| Scenario | What actually goes wrong | Blast radius |
|---|---|---|
| Unattended kernel patching (`kpatch`/`dnf-automatic` + reboot window) | New kernel's initramfs was built without the multipath or NVMe driver; node never mounts root | 1 node per reboot wave — until the wave is fleet-wide |
| Kubernetes node autoscaling | AMI/image has a kernel cmdline referencing a `root=UUID=` that no longer matches the cloned disk | 100% of newly-scaled nodes; the cluster silently stops scaling |
| Storage migration (SAN → NVMe-oF) | `dracut` never picked up `rd.nvmf.discover`, root device not present after 180 s `dracut-initqueue` timeout | Whole rack |
| `/etc/fstab` edit via configuration management | A device that does not exist makes systemd drop to `emergency.target`, which **requires a root password on the console** | Every host the playbook touched |
| Secure Boot enforced fleet-wide | Out-of-tree module (ZFS, NVIDIA, ipmi vendor driver) is unsigned; kernel refuses to load it, root or GPU never appears | Every host with that module in the initramfs |
| Boot storm after a power event | 400 nodes hit the same DHCP/PXE/iSCSI target simultaneously; timeouts cascade | Datacenter |

The common denominator: **a boot failure converts a software problem into a physical-access problem.** Mean time to repair stops being a function of your skill and becomes a function of whether IPMI/iDRAC/`aws ec2 get-console-output` works.

### 1.2 The design principle to internalise

> Every stage of the boot chain hands a **strictly larger capability set** to the next stage, and each hand-off is a place where state can be wrong. Debugging boot means identifying *which hand-off* failed, because the tools available to you differ completely at each one.

```
Power / reset vector
      │
      ▼
┌─────────────────┐  16-bit real mode (BIOS) or UEFI DXE environment
│ Firmware        │  Capability: read a block device, execute a blob
│ BIOS or UEFI    │  State handed on: pointer to bootloader
└────────┬────────┘
         ▼
┌─────────────────┐  GRUB2 / systemd-boot / syslinux / U-Boot
│ Boot loader     │  Capability: filesystem drivers, a menu, a scripting language
│                 │  State handed on: kernel image + initramfs + cmdline
└────────┬────────┘
         ▼
┌─────────────────┐  Self-decompress, set up MMU, mount initramfs on rootfs (tmpfs)
│ Kernel          │  Capability: everything compiled in; NOT modules on disk yet
│                 │  State handed on: exec /init from the initramfs
└────────┬────────┘
         ▼
┌─────────────────┐  dracut / initramfs-tools; udev, LVM, LUKS, mdraid, iSCSI, NFS
│ initramfs       │  Capability: userspace, but only what is inside the cpio archive
│ (PID 1, phase 1)│  State handed on: real root mounted at /sysroot, then switch_root
└────────┬────────┘
         ▼
┌─────────────────┐  systemd / SysVinit / Upstart
│ init (PID 1)    │  Capability: the real filesystem, all of userspace
│                 │  State handed on: default.target reached / runlevel N entered
└────────┬────────┘
         ▼
    getty, sshd, kubelet, containerd …
```

Memorise the four hand-off boundaries. Section 6 is organised around them, because **the first diagnostic question is always "how far did it get?"**

---

## 2. Stage 1 — Firmware: BIOS versus UEFI

### 2.1 Legacy BIOS / MBR

The firmware knows nothing about filesystems. It reads **LBA 0** — the first 512 bytes of the boot device — into memory at `0x7C00` and jumps there, provided the last two bytes are the signature `0x55AA`.

```
MBR layout (512 bytes)
┌────────────────────────────────────┬──────────────┬──────┐
│ Bootstrap code area (446 bytes)    │ Partition    │ 0x55 │
│ = GRUB stage 1 (boot.img)          │ table 4×16 B │ 0xAA │
└────────────────────────────────────┴──────────────┴──────┘
 offset 0                          446           510    512
```

446 bytes is not enough to implement ext4. So GRUB splits itself:

| Component | Location | Size | Job |
|---|---|---|---|
| `boot.img` (stage 1) | MBR bootstrap area | 446 B | Load the first sector of `core.img` |
| `core.img` (stage 1.5) | **MBR gap** — sectors 1–2047, the unused space before the first partition | ~25–30 KiB | Contains filesystem + LVM + RAID modules; can now *read files* |
| `/boot/grub2/` (stage 2) | Real filesystem | MBs | Menu, config, modules, fonts |

The MBR gap only exists because DOS-era partitioning aligned partition 1 at sector 63 (later 2048). **On a GPT disk there is no gap**, which is why a GPT + BIOS system needs a dedicated ~1 MiB partition of type `21686148-6449-6E6F-744E-656564454649` (`bios_grub` flag) for `core.img`. Forgetting it is a classic "installer succeeded, machine does not boot" failure.

```console
$ sudo fdisk -l /dev/sda | head -12
Disk /dev/sda: 100 GiB, 107374182400 bytes, 209715200 sectors
Disk model: QEMU HARDDISK
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
Disk identifier: 7C4A9B10-6F3E-4C21-9A55-1D2E8F0B3C77

Device       Start       End   Sectors  Size Type
/dev/sda1     2048      4095      2048    1M BIOS boot
/dev/sda2     4096   2101247   2097152    1G Linux filesystem
/dev/sda3  2101248 209713151 207611904   99G Linux LVM
```

```console
$ sudo dd if=/dev/sda bs=512 count=1 2>/dev/null | xxd | tail -3
000001c0: 0100 ee7f 3ac2 0100 0000 ffff ffff 0000  ....:...........
000001d0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000001e0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
000001f0: 0000 0000 0000 0000 0000 0000 0000 55aa  ..............U.
```

That trailing `55aa` is the boot signature. Its absence is the single most common cause of `No bootable device`.

### 2.2 UEFI

UEFI firmware **implements a FAT driver and a PE32+ loader**. It reads the **EFI System Partition** (ESP, GPT type `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`, FAT32) and executes a `.efi` binary. There is no MBR gap, no stage 1.5, no embedded blob.

Boot entries live in **NVRAM on the motherboard**, not on the disk. This is the single largest conceptual difference and the source of most UEFI incidents: *you can restore a disk image perfectly and still not boot, because the NVRAM entry points at a path that is not there.*

```console
$ ls /sys/firmware/efi
config_table  efivars  esrt  fw_platform_size  fw_vendor  runtime  runtime-map  systab
```

> **The canonical one-liner:** if `/sys/firmware/efi` exists, you booted in UEFI mode. If it does not, you booted in legacy/CSM mode. This matters because installers and `grub2-install` behave completely differently, and an image built in one mode will not boot in the other.

```console
$ cat /sys/firmware/efi/fw_platform_size
64

$ sudo efibootmgr -v
BootCurrent: 0002
Timeout: 1 seconds
BootOrder: 0002,0001,0000,0003
Boot0000* UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0001* UEFI QEMU DVD-ROM QM00003 	PciRoot(0x0)/Pci(0x1,0x1)/Ata(1,0,0){auto_created_boot_option}
Boot0002* Fedora	HD(1,GPT,9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21,0x800,0x12c000)/File(\EFI\FEDORA\SHIMX64.EFI)
Boot0003* UEFI PXEv4 (MAC:525400123456)	PciRoot(0x0)/Pci(0x2,0x0)/MAC(525400123456,1)/IPv4(0.0.0.00.0.0.0,0,0)
```

Read `Boot0002` carefully — it is the whole UEFI model in one line: *partition GUID* + *file path inside the ESP*.

```console
$ sudo mount | grep efi
/dev/sda1 on /boot/efi type vfat (rw,relatime,fmask=0077,dmask=0077,codepage=437,iocharset=ascii,shortname=winnt,errors=remount-ro)

$ sudo find /boot/efi -type f | sort
/boot/efi/EFI/BOOT/BOOTX64.EFI
/boot/efi/EFI/BOOT/fbx64.efi
/boot/efi/EFI/fedora/BOOTX64.CSV
/boot/efi/EFI/fedora/grub.cfg
/boot/efi/EFI/fedora/grubx64.efi
/boot/efi/EFI/fedora/mmx64.efi
/boot/efi/EFI/fedora/shim.efi
/boot/efi/EFI/fedora/shimx64.efi
```

**Creating an entry by hand** — the recovery command you want in your runbook:

```console
$ sudo efibootmgr --create \
    --disk /dev/sda --part 1 \
    --label "Fedora" \
    --loader '\EFI\fedora\shimx64.efi' --verbose
BootCurrent: 0002
Timeout: 1 seconds
BootOrder: 0004,0002,0001,0000,0003
Boot0004* Fedora	HD(1,GPT,9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21,0x800,0x12c000)/File(\EFI\fedora\shimx64.efi)
```

Note the **backslashes**: the loader path is an EFI path, not a POSIX path, and `--part 1` is the partition number *within* `--disk`.

`\EFI\BOOT\BOOTX64.EFI` is the **removable-media fallback path**. Firmware executes it when no NVRAM entry matches. Cloud images and USB installers rely on it; so should any golden image you build, because you cannot pre-seed a VM's NVRAM from inside the image.

### 2.3 Secure Boot and the shim

With Secure Boot enabled, firmware verifies each binary's signature against keys in the `db` variable. Distributions do not have their keys in every vendor's firmware, so they ship **shim**: a small loader signed by Microsoft's UEFI CA, which in turn verifies GRUB with the distribution's own key, and supports a **MOK** (Machine Owner Key) database for locally-signed modules.

```
firmware db  →  shimx64.efi  →  grubx64.efi  →  vmlinuz  →  kernel modules
   (MS CA)      (distro key)     (distro key)    (MOK for out-of-tree)
```

```console
$ mokutil --sb-state
SecureBoot enabled

$ sudo bootctl status | head -14
System:
      Firmware: UEFI 2.70 (EDK II 1.00)
 Firmware Arch: x64
   Secure Boot: enabled (user)
  TPM2 Support: yes
  Measured UKI: no
  Boot into FW: supported

Current Boot Loader:
      Product: GRUB 2.06
     Features: ✗ Boot counting
               ✗ Menu timeout control
               ✓ Boot loader sets ESP information
          ESP: /dev/disk/by-partuuid/9a3b1e77-2c44-4d0a-b1f5-0c8e3d7a5b21
```

```console
$ sudo dmesg | grep -iE 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.010214] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7
```

**Production consequence of lockdown mode:** `kexec` of an unsigned image, `/dev/mem` access, raw MSR writes and unsigned module loads all fail. If your kdump or your live-patching tooling breaks the day Secure Boot is enforced, this line in `dmesg` is why.

### 2.4 BIOS vs UEFI — the trade-off table you should be able to reproduce

| Dimension | Legacy BIOS | UEFI |
|---|---|---|
| CPU mode at hand-off | 16-bit real mode | 64-bit long mode (or 32-bit) |
| Partition scheme | MBR (GPT possible with `bios_grub`) | GPT (MBR possible, rarely) |
| Max addressable disk | 2 TiB (32-bit LBA × 512 B) | 8 ZiB (64-bit LBA) |
| Max primary partitions | 4 (+ extended/logical) | 128 by default, header-defined |
| Bootloader location | Embedded blob in MBR + MBR gap | Regular file on a FAT32 ESP |
| Boot entry storage | Implicit — "first bootable disk" | Explicit — NVRAM variables |
| Filesystem awareness | None | FAT12/16/32 |
| Signature verification | None | Secure Boot (`db`/`dbx`/`MOK`) |
| Network boot | PXE via option ROM | Built-in PXE, HTTP Boot, iSCSI, IPv6 |
| Recovery ergonomics | `dd` the MBR back; disk is self-contained | Must also restore the NVRAM entry or use `\EFI\BOOT\BOOTX64.EFI` |
| Disaster case | Overwritten MBR gap by a foreign installer | Firmware NVRAM cleared / CMOS battery |
| **Choose for** | Ancient hardware, some hypervisor defaults | Anything ≥2 TiB, Secure Boot, TPM measured boot, HTTP boot at scale |

**Do not mix.** A disk installed in UEFI mode will not boot on a machine set to Legacy/CSM, and vice versa. In a mixed fleet, standardise the firmware setting in your provisioning templates *before* you standardise the image.

---

## 3. Stage 2 — The boot loader

### 3.1 Comparative landscape

| Loader | Config model | Filesystem support | Secure Boot | Chainload other OS | Typical home | Trade-off |
|---|---|---|---|---|---|---|
| **GRUB2** | Generated `grub.cfg` from `/etc/default/grub` + `/etc/grub.d/`, or BLS snippets | Enormous (ext*, xfs, btrfs, zfs, LVM, mdraid, LUKS, NFS, iSCSI…) | Yes, via shim | Yes | RHEL, Fedora, Debian, Ubuntu, SUSE | Powerful and scriptable; large attack surface, slow, config is generated so hand edits are lost |
| **systemd-boot** (`sd-boot`) | Drop-in `.conf` per entry on the ESP, no generator | **ESP/FAT only** — kernel + initramfs must live on the ESP | Yes | Only other EFI binaries | Arch, Pop!\_OS, Flatcar, some CoreOS derivatives | Tiny, fast, trivially auditable; UEFI-only, no LVM/LUKS `/boot` |
| **syslinux / extlinux** | Static `syslinux.cfg` | FAT, ext2/3/4, btrfs (limited) | Weak | Limited | PXE, rescue media, embedded | Minimal and predictable; effectively BIOS-era |
| **U-Boot** | Environment variables + boot scripts | Many, plus network protocols | Board-dependent | n/a | ARM SBCs, embedded, network appliances | It *is* the firmware on ARM; per-board, non-portable |
| **UKI + sd-stub** | Kernel, initramfs and cmdline in **one signed PE binary** | n/a — self-contained | Strongest (whole cmdline is signed) | n/a | Immutable / confidential-computing fleets | Best security and TPM-measurement story; **you must rebuild the image to change a kernel argument** |

> **Architect's note.** The UKI (Unified Kernel Image) trade-off is the one that matters strategically. Because the kernel command line is inside the signed binary, an attacker with disk access cannot append `init=/bin/bash` — but neither can your on-call engineer at 03:00. Fleets that adopt UKIs must invest in out-of-band recovery *first*.

### 3.2 GRUB2, the two configuration models

This is the most common source of confusion in the field, and it is examinable.

**Model A — classic generated `grub.cfg`** (Debian, Ubuntu, SUSE, RHEL ≤ 8 in some layouts)

```
/etc/default/grub          ← key=value knobs you edit
/etc/grub.d/00_header      ← executable scripts, run in name order
/etc/grub.d/10_linux
/etc/grub.d/30_os-prober
/etc/grub.d/40_custom      ← hand-written entries go here
        │
        │  grub2-mkconfig / update-grub
        ▼
/boot/grub2/grub.cfg       ← GENERATED. NEVER EDIT.
(Debian/Ubuntu: /boot/grub/grub.cfg)
```

**Model B — Boot Loader Specification (BLS)** (Fedora, RHEL 8+, CentOS Stream)

```
/etc/default/grub          ← still the source of GRUB_CMDLINE_LINUX
/boot/loader/entries/*.conf ← one small file PER KERNEL, edited by `grubby`
/boot/grub2/grub.cfg       ← a thin stub that just iterates the entries
```

`/etc/default/grub` — the complete, production-oriented version:

```bash
# /etc/default/grub — annotated production baseline
# Applied with: grub2-mkconfig -o /boot/grub2/grub.cfg  (BIOS)
#           or: grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg  (UEFI, non-BLS)

# Which menu entry is selected by default.
#   a number (0-based), "saved" (use GRUB_SAVEDEFAULT), or an entry title
GRUB_DEFAULT=saved

# Remember the last booted entry. Requires GRUB_DEFAULT=saved.
GRUB_SAVEDEFAULT=true

# Seconds before the default entry boots. 0 = no menu (dangerous on servers:
# you lose the ability to pick an older kernel without a console keypress).
# -1 = wait forever.
GRUB_TIMEOUT=5

# "menu"   -> show the menu for GRUB_TIMEOUT
# "hidden" -> hide it, but honour a keypress (ESC/Shift)
# "countdown" -> show a counter only
GRUB_TIMEOUT_STYLE=menu

# Prefix used to build menu entry titles.
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"

# "console" = text on the primary console. "gfxterm" = graphical.
# Servers: keep console. It works over serial and IPMI SOL.
GRUB_TERMINAL_OUTPUT="console"
GRUB_TERMINAL_INPUT="console serial"

# Serial console for out-of-band access. THIS is what saves you at 03:00.
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# Appended to EVERY entry, including the rescue entry.
GRUB_CMDLINE_LINUX="resume=/dev/mapper/vg0-swap rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap \
console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M \
systemd.unified_cgroup_hierarchy=1 audit=1"

# Appended only to the DEFAULT (non-recovery) entries.
# Deliberately EMPTY: no "quiet", no "rhgb". On a server you want the boot log.
GRUB_CMDLINE_LINUX_DEFAULT=""

# Do not probe for other operating systems. On a server it is pure risk:
# os-prober can mount foreign filesystems, including guest disks on a hypervisor.
GRUB_DISABLE_OS_PROBER=true

# Keep the recovery/rescue entry. Removing it to "clean up the menu" has ended
# more than one incident badly.
GRUB_DISABLE_RECOVERY=false

# Generate entries only for the running kernel? No — you want fallbacks.
GRUB_DISABLE_SUBMENU=true

# Fedora/RHEL BLS integration. true = use /boot/loader/entries, do not inline
# menu entries into grub.cfg.
GRUB_ENABLE_BLSCFG=true
```

Regenerating — **and the paths differ by distribution and firmware mode**:

```console
# Fedora / RHEL / CentOS, BIOS
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Fedora / RHEL / CentOS, UEFI
$ sudo grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg

# Debian / Ubuntu (wrapper handles both cases)
$ sudo update-grub
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-45-generic
Found initrd image: /boot/initrd.img-6.8.0-45-generic
Found linux image: /boot/vmlinuz-6.8.0-41-generic
Found initrd image: /boot/initrd.img-6.8.0-41-generic
Warning: os-prober will not be executed to detect other bootable partitions.
done
```

Reinstalling the loader itself (after replacing a disk, or after Windows clobbered the MBR):

```console
# BIOS: write boot.img to the MBR of sda and core.img into the gap
$ sudo grub2-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.

# UEFI: install the EFI binaries and create the NVRAM entry
$ sudo grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora
Installing for x86_64-efi platform.
Installation finished. No error reported.
```

### 3.3 BLS entries and `grubby`

```console
$ ls -1 /boot/loader/entries/
9c8f2e1a5b3d4f6789ab0123cdef4567-0-rescue.conf
9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64.conf
9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.3-200.fc40.x86_64.conf

$ cat /boot/loader/entries/9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64.conf
title Fedora Linux (6.10.6-200.fc40.x86_64) 40 (Server Edition)
version 6.10.6-200.fc40.x86_64
linux /vmlinuz-6.10.6-200.fc40.x86_64
initrd /initramfs-6.10.6-200.fc40.x86_64.img
options root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
grub_users $grub_users
grub_arg --unrestricted
grub_class fedora
```

That file *is* the menu entry. Six lines. Compare it to the 200-line generated `grub.cfg` it replaces — this is why BLS exists.

```console
$ sudo grubby --info=ALL
index=0
kernel="/boot/vmlinuz-6.10.6-200.fc40.x86_64"
args="ro rd.lvm.lv=vg0/root rd.lvm.lv=vg0/swap console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"
root="/dev/mapper/vg0-root"
initrd="/boot/initramfs-6.10.6-200.fc40.x86_64.img"
title="Fedora Linux (6.10.6-200.fc40.x86_64) 40 (Server Edition)"
id="9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.6-200.fc40.x86_64"

$ sudo grubby --default-kernel
/boot/vmlinuz-6.10.6-200.fc40.x86_64

$ sudo grubby --default-index
0
```

**Changing kernel arguments across all installed kernels — idempotent, scriptable, no regeneration step:**

```console
$ sudo grubby --update-kernel=ALL --args="transparent_hugepage=never intel_iommu=on iommu=pt"

$ sudo grubby --update-kernel=ALL --remove-args="quiet rhgb"

$ sudo grubby --update-kernel=/boot/vmlinuz-6.10.6-200.fc40.x86_64 --args="systemd.log_level=debug"

$ sudo grubby --set-default=/boot/vmlinuz-6.10.3-200.fc40.x86_64
The default is /boot/loader/entries/9c8f2e1a5b3d4f6789ab0123cdef4567-6.10.3-200.fc40.x86_64.conf with index 1 and kernel /boot/vmlinuz-6.10.3-200.fc40.x86_64
```

> **Fleet pattern.** `grubby --update-kernel=ALL --args=...` is safe to run repeatedly — it replaces an existing `key=value` rather than appending a duplicate. This makes it the correct primitive for configuration management. `sed`-ing `/etc/default/grub` and regenerating is not idempotent and does not touch already-installed BLS entries.

### 3.4 Interacting with GRUB at boot time — the exam's core skill

At the menu, press **`e`** to edit the highlighted entry, **`c`** for a full GRUB shell, **`Esc`** to go back.

A typical entry in the editor:

```
        load_video
        set gfxpayload=keep
        insmod gzio
        insmod part_gpt
        insmod ext2
        set root='hd0,gpt2'
        linux ($root)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro \
              rd.lvm.lv=vg0/root console=ttyS0,115200n8
        initrd ($root)/initramfs-6.10.6-200.fc40.x86_64.img
```

Move to the end of the `linux` line, append your parameter, then **`Ctrl-x`** (or **F10**) to boot. **The edit is volatile** — it applies to this boot only. That is exactly what you want during an incident.

Booting **entirely by hand** from the `grub>` prompt, which is what you do when `grub.cfg` is corrupt or missing:

```
grub> ls
(hd0) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (lvm/vg0-root) (lvm/vg0-swap)

grub> ls (hd0,gpt2)/
efi/  grub2/  loader/  vmlinuz-6.10.6-200.fc40.x86_64  initramfs-6.10.6-200.fc40.x86_64.img
System.map-6.10.6-200.fc40.x86_64  config-6.10.6-200.fc40.x86_64

grub> ls (hd0,gpt2)
Partition hd0,gpt2: Filesystem type ext2, UUID 3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33 - Partition start at 2048KiB - Total size 1048576KiB

grub> set root=(hd0,gpt2)

grub> linux /vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=ttyS0,115200n8

grub> initrd /initramfs-6.10.6-200.fc40.x86_64.img

grub> boot
```

Key details that trip people up:

- GRUB disk numbering is **0-based** (`hd0`), partition numbering is **1-based** (`gpt1`). `(hd0,gpt2)` = second partition of the first disk.
- If `/boot` is a **separate partition**, paths are relative to it: `/vmlinuz-…`, not `/boot/vmlinuz-…`. If `/boot` is on the root filesystem, it is `/boot/vmlinuz-…`. `ls` tells you which.
- `grub rescue>` is a *more* degraded prompt than `grub>` — it means `core.img` loaded but could not find `/boot/grub2`. Recover with `insmod`:

```
grub rescue> set prefix=(hd0,gpt2)/grub2
grub rescue> set root=(hd0,gpt2)
grub rescue> insmod normal
grub rescue> normal
```

### 3.5 Password-protecting the menu

Anyone with console access and an unprotected GRUB menu can append `init=/bin/bash` and get an unauthenticated root shell. On any machine that is not physically controlled by you, this is a real finding.

```console
$ grub2-mkpasswd-pbkdf2
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8
```

```bash
# /etc/grub.d/01_users  (chmod 755)
#!/bin/sh
cat <<'EOF'
set superusers="bootadmin"
password_pbkdf2 bootadmin grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8
EOF
```

With `grub_arg --unrestricted` in a BLS entry (or `--unrestricted` on a `menuentry`), that entry still *boots* without a password, but **editing it with `e` requires authentication**. That is usually the right balance: unattended reboots keep working, interactive tampering does not.

### 3.6 systemd-boot, for contrast

```console
$ sudo bootctl install
Created "/boot/EFI/systemd".
Copied "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" to "/boot/EFI/systemd/systemd-bootx64.efi".
Created EFI boot entry "Linux Boot Manager".
```

```ini
# /boot/loader/loader.conf
default  fedora-*.conf
timeout  4
console-mode keep
editor   no
```

```ini
# /boot/loader/entries/fedora-6.10.6.conf
title    Fedora Linux
version  6.10.6-200.fc40.x86_64
linux    /vmlinuz-6.10.6-200.fc40.x86_64
initrd   /initramfs-6.10.6-200.fc40.x86_64.img
options  root=UUID=8c1f0e2a-3b7d-4c95-a2e6-90f4d1b78c05 ro quiet
```

`editor no` is the systemd-boot equivalent of GRUB password protection: it disables interactive cmdline editing entirely.

---

## 4. Stage 3 — Kernel and initramfs

### 4.1 What `vmlinuz` actually is

`vmlinuz` is not a raw kernel. It is a **self-extracting image**: a small real-mode setup header plus a compressed payload (gzip, LZ4, ZSTD, XZ). The bootloader loads it, jumps to the setup code, which decompresses the real kernel and enters it. The first thing you see is the version banner.

```console
$ file /boot/vmlinuz-6.10.6-200.fc40.x86_64
/boot/vmlinuz-6.10.6-200.fc40.x86_64: Linux kernel x86 boot executable bzImage, version 6.10.6-200.fc40.x86_64 (mockbuild@...) #1 SMP PREEMPT_DYNAMIC, RO-rootFS, swap_dev 0x8, Normal VGA

$ sudo dmesg | head -20
[    0.000000] Linux version 6.10.6-200.fc40.x86_64 (mockbuild@d7f2...) (gcc (GCC) 14.2.1, GNU ld 2.41) #1 SMP PREEMPT_DYNAMIC Tue Aug 20 14:02:11 UTC 2026
[    0.000000] Command line: BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M
[    0.000000] BIOS-provided physical RAM map:
[    0.000000] BIOS-e820: [mem 0x0000000000000000-0x000000000009fbff] usable
[    0.000000] BIOS-e820: [mem 0x000000000009fc00-0x000000000009ffff] reserved
[    0.000000] BIOS-e820: [mem 0x00000000000f0000-0x00000000000fffff] reserved
[    0.000000] BIOS-e820: [mem 0x0000000000100000-0x00000000bffdffff] usable
[    0.000000] efi: EFI v2.70 by EDK II
[    0.000000] efi: ACPI=0xbfbfe000 ACPI 2.0=0xbfbfe014 SMBIOS=0xbf9ba000 MEMATTR=0xbe4b7018
[    0.000000] SMBIOS 2.8 present.
[    0.000000] DMI: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 1.16.3-2.fc40 04/01/2014
[    0.001834] Secure boot enabled
[    0.005112] Hypervisor detected: KVM
[    0.010988] KVM setup pv remote TLB flush
[    0.021344] Booting paravirtualized kernel on KVM
[    0.033921] setup_percpu: NR_CPUS:8192 nr_cpumask_bits:4 nr_cpu_ids:4
[    0.098776] Memory: 3902144K/4193848K available (18432K kernel code, 3086K rwdata, 12288K rodata)
[    0.121403] SLUB: HWalign=64, Order=0-3, MinObjects=0, CPUs=4, Nodes=1
[    0.155210] rcu: Hierarchical RCU implementation.
```

`dmesg` line 2 is `/proc/cmdline` before `/proc` exists. It is the **first thing to read in any boot incident**: it proves what the bootloader actually passed, as opposed to what you believe you configured.

### 4.2 Why initramfs exists

A distribution kernel is **modular** — the ext4, xfs, LVM, dm-crypt, NVMe and megaraid drivers are `.ko` files on the root filesystem. To mount the root filesystem you need the driver for the root filesystem. That circular dependency is broken by the **initramfs**: a cpio archive that the bootloader loads into RAM alongside the kernel, which the kernel unpacks into a tmpfs and uses as a temporary root.

| | initrd (legacy) | initramfs (current) |
|---|---|---|
| Format | Compressed **filesystem image** (ext2, romfs) | Compressed **cpio archive** |
| Mounted as | A block device (`/dev/ram0`) via a ramdisk driver | Unpacked directly into `rootfs` (tmpfs) |
| Fixed size | Yes — allocated up front | No — grows/shrinks with content |
| Transition to real root | `pivot_root` + unmount | `switch_root` — delete contents, chroot, exec new init |
| Page-cache duplication | Yes (double memory cost) | No |
| Kernel entry point | `/linuxrc` | `/init` |

Both terms are still used interchangeably in filenames (`initrd.img-*` on Debian is an initramfs).

The initramfs is where the *hard* parts of storage live: assembling mdraid arrays, activating LVM volume groups, unlocking LUKS, logging into iSCSI targets, bringing up a network for NFS root, and resuming from hibernation.

### 4.3 Inspecting and rebuilding

```console
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | head -30
Image: /boot/initramfs-6.10.6-200.fc40.x86_64.img: 41M
========================================================================
Early CPIO image
========================================================================
drwxr-xr-x   3 root     root            0 Aug 20 14:03 .
-rw-r--r--   1 root     root            2 Aug 20 14:03 early_cpio
drwxr-xr-x   3 root     root            0 Aug 20 14:03 kernel
drwxr-xr-x   2 root     root            0 Aug 20 14:03 kernel/x86
drwxr-xr-x   2 root     root            0 Aug 20 14:03 kernel/x86/microcode
-rw-r--r--   1 root     root       126976 Aug 20 14:03 kernel/x86/microcode/AuthenticAMD.bin
========================================================================
Version: dracut-060-3.fc40

Arguments: -f

dracut modules:
bash systemd systemd-initrd i18n drm prefixdevname kernel-modules kernel-modules-extra
lvm dm rootfs-block terminfo udev-rules dracut-systemd usrmount base fs-lib shutdown
========================================================================
drwxr-xr-x  12 root     root            0 Aug 20 14:03 .
crw-r--r--   1 root     root       5,   1 Aug 20 14:03 dev/console
crw-r--r--   1 root     root       1,  11 Aug 20 14:03 dev/kmsg
crw-r--r--   1 root     root       1,   3 Aug 20 14:03 dev/null
lrwxrwxrwx   1 root     root            7 Aug 20 14:03 bin -> usr/bin
```

Note the **Early CPIO image**: an *uncompressed* cpio prepended to the real one, containing CPU microcode. The kernel reads it before anything else so microcode is applied as early as possible.

```console
# Which modules made it in? The single most useful initramfs query.
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | grep -E '\.ko' | grep -E 'nvme|megaraid|dm-|multipath'
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/md/dm-mod.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/md/dm-snapshot.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/nvme/host/nvme.ko.xz
usr/lib/modules/6.10.6-200.fc40.x86_64/kernel/drivers/nvme/host/nvme-core.ko.xz

# Extract a single file to stdout — verify what fstab the initramfs will see
$ lsinitrd -f /etc/fstab /boot/initramfs-6.10.6-200.fc40.x86_64.img

# Fully unpack for forensics
$ mkdir /tmp/initrd && cd /tmp/initrd
$ sudo lsinitrd --unpack /boot/initramfs-6.10.6-200.fc40.x86_64.img
$ ls
bin  dev  etc  init  lib  lib64  proc  root  run  sbin  shutdown  sys  sysroot  tmp  usr  var
$ readlink init
usr/lib/systemd/systemd
```

On modern dracut, `/init` is **systemd itself**, running in the initramfs with a different unit set (`initrd.target`). This is why `journalctl -b` shows systemd units from before `switch_root`.

**Rebuilding — the command every SRE needs muscle memory for:**

```console
# Rebuild for the running kernel, overwrite
$ sudo dracut --force

# Rebuild for a specific kernel
$ sudo dracut --force /boot/initramfs-6.10.3-200.fc40.x86_64.img 6.10.3-200.fc40.x86_64

# Rebuild EVERY installed kernel — do this after a storage-stack change
$ sudo dracut --force --regenerate-all
dracut[I]: *** Creating initramfs image file '/boot/initramfs-6.10.6-200.fc40.x86_64.img' done ***
dracut[I]: *** Creating initramfs image file '/boot/initramfs-6.10.3-200.fc40.x86_64.img' done ***

# Force-include a driver the auto-detection missed
$ sudo dracut --force --add-drivers "megaraid_sas nvme-tcp" --regenerate-all

# Host-only (small, fast, fragile) vs generic (large, portable)
$ sudo dracut --force --no-hostonly      # generic: survives hardware/disk changes
$ sudo dracut --force --hostonly         # only this machine's drivers
```

```bash
# /etc/dracut.conf.d/50-platform.conf — persistent, config-managed
# Generic image: this fleet clones disks between hardware generations,
# so host-only would produce an image that fails on the next SKU.
hostonly="no"

# Storage stack we require in early boot
add_dracutmodules+=" lvm dm multipath nvmf "
add_drivers+=" nvme nvme-tcp nvme-fabrics megaraid_sas dm-multipath "

# ZSTD: ~2x faster decompression than XZ at similar size. Boot-time win.
compress="zstd"

# Serial console must work from the initramfs, not just from systemd
kernel_cmdline+=" console=ttyS0,115200n8 "

# Never silently omit these
omit_dracutmodules+=" plymouth "
```

Debian/Ubuntu equivalent:

```console
$ sudo update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.8.0-45-generic
update-initramfs: Generating /boot/initrd.img-6.8.0-41-generic

$ sudo update-initramfs -c -k 6.8.0-45-generic   # create (new kernel)
$ lsinitramfs /boot/initrd.img-6.8.0-45-generic | grep nvme
```

```
# /etc/initramfs-tools/initramfs.conf
MODULES=most          # "most" = generic; "dep" = host-only equivalent
BUSYBOX=auto
COMPRESS=zstd
DEVICE=
NFSROOT=auto
RUNSIZE=10%
```

```
# /etc/initramfs-tools/modules — one module name per line, force-included
nvme
nvme_tcp
megaraid_sas
dm_multipath
```

### 4.4 The kernel command line — production reference

```console
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root console=tty0 console=ttyS0,115200n8 crashkernel=1G-4G:192M
```

**Root and early-boot**

| Parameter | Meaning | Production note |
|---|---|---|
| `root=UUID=<uuid>` | Root device by filesystem UUID | **The only form you should ship.** Survives device renaming |
| `root=/dev/mapper/vg-lv` | Root on LVM | Requires matching `rd.lvm.lv=` |
| `root=LABEL=<label>` | Root by filesystem label | Labels collide; UUIDs do not |
| `ro` / `rw` | Mount root read-only/read-write initially | `ro` is correct: `fsck` needs it, systemd remounts `rw` |
| `rootflags=<opts>` | Mount options for root | e.g. `rootflags=subvol=@` for btrfs |
| `rootfstype=ext4` | Skip filesystem probing | Marginal speed win; a footgun if you convert the fs |
| `rd.lvm.lv=vg/lv` | Activate only this LV in the initramfs | Faster than scanning all VGs; **must list root and swap** |
| `rd.luks.uuid=<uuid>` | Unlock this LUKS device early | Pair with `rd.luks.key=` or a TPM/clevis binding |
| `rd.md.uuid=<uuid>` | Assemble this mdraid array early | |
| `rd.driver.pre=<mod>` | Load module before anything else | The fix for "disk controller not detected" |
| `rd.driver.blacklist=<mod>` | Never load this module in the initramfs | For a driver that hangs the boot |
| `resume=<dev>` / `noresume` | Hibernation image device / skip it | `noresume` fixes "waiting for resume device" hangs |

**Init selection and degraded modes**

| Parameter | Effect |
|---|---|
| `init=/bin/bash` | Kernel execs bash as PID 1. **No systemd, no mounts, no networking.** The universal password-reset path |
| `systemd.unit=rescue.target` | Single-user-like: root filesystem mounted, minimal services, root password required |
| `systemd.unit=emergency.target` | Root mounted **read-only**, essentially nothing else started |
| `systemd.unit=multi-user.target` | Force text-only boot even when the default is graphical |
| `1`, `s`, `single` | SysV compatibility — systemd maps these to `rescue.target` |
| `3`, `5` | Mapped to `multi-user.target` / `graphical.target` |
| `emergency` | Shorthand for `systemd.unit=emergency.target` |
| `rd.break[=stage]` | Drop to a shell **inside the initramfs**. Stages: `cmdline`, `pre-udev`, `pre-trigger`, `initqueue`, `pre-mount`, `mount`, `pre-pivot`, `cleanup` |
| `rd.shell` | Give a shell if the initramfs fails, instead of rebooting |
| `rd.debug` | Verbose `set -x` tracing of dracut scripts |

**Observability**

| Parameter | Effect |
|---|---|
| `console=ttyS0,115200n8` | Serial console. **Can be repeated**; the *last* one gets `/dev/console` |
| `console=tty0` | Video console |
| `quiet` | Suppress most kernel messages. Remove it on servers |
| `loglevel=7` | Show everything up to and including debug |
| `ignore_loglevel` | Print all messages regardless of level |
| `earlyprintk=serial,ttyS0,115200` | Output *before* the real console driver initialises — for panics at second 0 |
| `systemd.log_level=debug` | Full systemd tracing |
| `systemd.log_target=console` | Send systemd's own log to the console, not the journal |
| `systemd.show_status=1` | Per-unit `[ OK ]` lines |
| `printk.devkmsg=on` | Allow userspace writes to `/dev/kmsg` |
| `panic=30` | Reboot 30 s after a panic instead of hanging forever. **Set this in a fleet** |
| `oops=panic` | Convert any oops into a panic — so kdump captures it |
| `crashkernel=1G-4G:192M,4G-:256M` | Reserve memory for the kdump capture kernel |

**Hardware and behaviour**

| Parameter | Effect |
|---|---|
| `nomodeset` | Disable kernel mode setting — the classic "black screen after install" fix |
| `net.ifnames=0 biosdevname=0` | Revert to `eth0`-style names. **Changes every interface name — will break your network config** |
| `selinux=0` | Disable SELinux entirely (requires relabel later) |
| `enforcing=0` | SELinux permissive for this boot. Prefer this over `selinux=0` |
| `intel_iommu=on iommu=pt` | Enable IOMMU with passthrough — required for VFIO/SR-IOV |
| `mitigations=off` | Disable all CPU speculative-execution mitigations. Real throughput gain, real security regression — a decision for a security review, not an engineer |
| `transparent_hugepage=never` | Frequently required by databases (MongoDB, Redis, Oracle) |
| `isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7` | CPU isolation for low-latency / DPDK workloads |
| `systemd.unified_cgroup_hierarchy=1` | cgroup v2 only — required by modern container runtimes |

> **Rule for the fleet:** treat `/proc/cmdline` as **declared configuration** and alert on drift. A node whose cmdline diverges from the class template is a node whose boot behaviour you cannot predict. Export it as a Prometheus metric via node_exporter's textfile collector and diff it against the template.

---

## 5. Stage 4 — init: SysVinit, Upstart, systemd

### 5.1 Comparative table

| Dimension | SysVinit | Upstart | systemd |
|---|---|---|---|
| Era / origin | 1983, AT&T System V | 2006, Canonical | 2010, Red Hat |
| Model | **Sequential**, ordered by numeric symlink prefix | **Event-driven** (`started`, `stopped`, `net-device-up`) | **Dependency graph**, resolved and parallelised |
| PID 1 config | `/etc/inittab` | `/etc/init/*.conf` | `/etc/systemd/system/*`, `/usr/lib/systemd/system/*` |
| Service definition | Shell script with LSB header in `/etc/init.d/` | Declarative-ish `.conf` job file | Declarative `.service` unit |
| State abstraction | **Runlevel** (0–6, S) | Runlevel-compatible via events | **Target** (a unit that groups other units) |
| Parallelism | None (bounded by `&` hacks) | Partial, event-driven | Full, via socket/D-Bus/path/timer activation |
| Service supervision | None — a crashed daemon stays dead | Yes (`respawn`) | Yes (`Restart=`), plus rate limiting |
| Process tracking | PID files — **unreliable**, double-forks escape | PID guessing (`expect fork`/`daemon`) | **cgroups** — a process cannot escape its unit |
| Resource control | `ulimit` in the script | `limit` stanza | Full cgroup v2: `MemoryMax=`, `CPUQuota=`, `IOWeight=` |
| Logging | Whatever the script redirects | `/var/log/upstart/*.log` | `journald`, structured and indexed |
| Boot timing data | None | None | `systemd-analyze blame` / `critical-chain` / `plot` |
| Sandboxing | None | None | `PrivateTmp=`, `ProtectSystem=`, `NoNewPrivileges=`, seccomp |
| On-demand start | `inetd`/`xinetd`, separate daemon | Limited | Socket, path, device, timer, D-Bus activation |
| Boot time (typical server) | 60–120 s | 40–80 s | 5–25 s |
| Complexity / attack surface | Minimal | Moderate | Large — PID 1 does a great deal |
| Debuggability | Read the shell script | Read the job file | Read units + `systemctl`; opaque without the tooling |
| Status **today** | Devuan, Slackware, Alpine (OpenRC-adjacent), containers | **Deprecated everywhere** | Default on RHEL 7+, Debian 8+, Ubuntu 15.04+, SUSE 12+, Arch, Fedora |
| **Exam expectation** | **Understand** | **Be aware of** | **Understand** |

### 5.2 SysVinit in the depth the exam wants

`/etc/inittab` — the whole configuration of PID 1, one line per entry, colon-separated:

```
# /etc/inittab — classic SysVinit
# Format: id:runlevels:action:process

# Default runlevel. 3 = multi-user + networking, no X. 5 = with a display manager.
# NEVER set this to 0 (halt) or 6 (reboot): the machine loops forever.
id:3:initdefault:

# System initialisation, run once before anything else.
si::sysinit:/etc/rc.d/rc.sysinit

# One line per runlevel: run the rc script with the runlevel as argument.
l0:0:wait:/etc/rc.d/rc 0
l1:1:wait:/etc/rc.d/rc 1
l2:2:wait:/etc/rc.d/rc 2
l3:3:wait:/etc/rc.d/rc 3
l4:4:wait:/etc/rc.d/rc 4
l5:5:wait:/etc/rc.d/rc 5
l6:6:wait:/etc/rc.d/rc 6

# Trap Ctrl-Alt-Del. On a server, replace with a logger call: an accidental
# three-finger salute on a KVM should not reboot a production host.
ca::ctrlaltdel:/sbin/shutdown -t3 -r now

# UPS integration
pf::powerfail:/sbin/shutdown -f -h +2 "Power Failure; System Shutting Down"
pr:12345:powerokwait:/sbin/shutdown -c "Power Restored; Shutdown Cancelled"

# Six virtual consoles in runlevels 2-5. "respawn" = restart when it exits.
1:2345:respawn:/sbin/mingetty tty1
2:2345:respawn:/sbin/mingetty tty2
3:2345:respawn:/sbin/mingetty tty3
4:2345:respawn:/sbin/mingetty tty4
5:2345:respawn:/sbin/mingetty tty5
6:2345:respawn:/sbin/mingetty tty6

# Serial console — out-of-band access
s0:2345:respawn:/sbin/agetty -h -L 115200 ttyS0 vt100

# Display manager in runlevel 5 only
x:5:respawn:/etc/X11/prefdm -nodaemon
```

The `action` field values worth knowing: `initdefault`, `sysinit`, `wait`, `once`, `respawn`, `boot`, `bootwait`, `ctrlaltdel`, `powerfail`, `powerokwait`, `off`.

**Runlevels** — note the two conflicting conventions, which is exactly the kind of detail LPI asks about:

| Runlevel | Red Hat / Fedora / SUSE | Debian / Ubuntu (pre-systemd) |
|---|---|---|
| 0 | Halt | Halt |
| 1 / S / s | Single user | Single user |
| 2 | Multi-user, no NFS | **Full multi-user with GUI (default)** |
| 3 | Full multi-user, text | Same as 2 (site-defined) |
| 4 | Unused / site-defined | Same as 2 |
| 5 | Multi-user + X11 (GUI) | Same as 2 |
| 6 | Reboot | Reboot |

The rc directory structure:

```console
$ ls -l /etc/rc.d/rc3.d/ | head
lrwxrwxrwx 1 root root 17 K01certmonger -> ../init.d/certmonger
lrwxrwxrwx 1 root root 16 K05wdaemon -> ../init.d/wdaemon
lrwxrwxrwx 1 root root 19 K10psacct -> ../init.d/psacct
lrwxrwxrwx 1 root root 15 S10network -> ../init.d/network
lrwxrwxrwx 1 root root 16 S12rsyslog -> ../init.d/rsyslog
lrwxrwxrwx 1 root root 16 S55sshd -> ../init.d/sshd
lrwxrwxrwx 1 root root 15 S80postfix -> ../init.d/postfix
lrwxrwxrwx 1 root root 14 S90crond -> ../init.d/crond
```

`/etc/rc.d/rc N` walks the directory in **lexical order**: first every `K*` script with `stop`, then every `S*` script with `start`. The two-digit number *is* the entire dependency system — `S10network` before `S55sshd` because 10 sorts before 55. There is no expression of "sshd requires the network"; there is only a number a human chose.

**That is the architectural limitation.** Ordering is implicit, global, and unverifiable. Add a service and you must guess a number that does not collide and does not invert an ordering nobody documented.

LSB headers were the attempt to fix it:

```bash
#!/bin/bash
#
# myapp   Start/stop the myapp daemon
#
### BEGIN INIT INFO
# Provides:          myapp
# Required-Start:    $network $remote_fs $syslog
# Required-Stop:     $network $remote_fs $syslog
# Should-Start:      postgresql
# Should-Stop:       postgresql
# Default-Start:     3 4 5
# Default-Stop:      0 1 2 6
# Short-Description: myapp application server
# Description:       Starts the myapp application server, which serves the
#                    internal ordering API on port 8080.
### END INIT INFO

. /etc/rc.d/init.d/functions

prog="myapp"
exec="/usr/local/bin/myapp"
pidfile="/var/run/${prog}.pid"
lockfile="/var/lock/subsys/${prog}"
[ -e /etc/sysconfig/$prog ] && . /etc/sysconfig/$prog

start() {
    [ -x $exec ] || exit 5
    echo -n $"Starting $prog: "
    daemon --pidfile=$pidfile "$exec --daemon --pidfile=$pidfile $MYAPP_OPTS"
    retval=$?
    echo
    [ $retval -eq 0 ] && touch $lockfile
    return $retval
}

stop() {
    echo -n $"Stopping $prog: "
    killproc -p $pidfile $prog
    retval=$?
    echo
    [ $retval -eq 0 ] && rm -f $lockfile
    return $retval
}

restart()  { stop; start; }
reload()   { echo -n $"Reloading $prog: "; killproc -p $pidfile $prog -HUP; echo; }
rh_status() { status -p $pidfile $prog; }
rh_status_q() { rh_status >/dev/null 2>&1; }

case "$1" in
    start)   rh_status_q && exit 0; start ;;
    stop)    rh_status_q || exit 0; stop ;;
    restart) restart ;;
    reload)  rh_status_q || exit 7; reload ;;
    status)  rh_status ;;
    condrestart|try-restart) rh_status_q || exit 0; restart ;;
    *)
        echo $"Usage: $0 {start|stop|status|restart|condrestart|try-restart|reload}"
        exit 2
esac
exit $?
```

Classic SysVinit commands:

```console
$ runlevel
N 3
```

`N` means "no previous runlevel" (booted straight into 3). After a change it shows the previous one:

```console
$ sudo telinit 5
$ runlevel
3 5

$ sudo init 6        # reboot
$ sudo telinit q     # re-read /etc/inittab without changing runlevel

$ sudo service sshd status
openssh-daemon (pid  1247) is running...

$ sudo chkconfig --list sshd
sshd            0:off   1:off   2:on    3:on    4:on    5:on    6:off

$ sudo chkconfig --level 345 myapp on
$ sudo chkconfig --add myapp        # reads the LSB header, creates the symlinks

# Debian equivalent
$ sudo update-rc.d myapp defaults
$ sudo update-rc.d myapp disable
```

### 5.3 Upstart — awareness level

Upstart replaced sequential runlevels with **events**. A job declares what it reacts to; Upstart maintains no global ordering.

```
# /etc/init/myapp.conf
description "myapp application server"
author      "platform-team@example.com"

# Start when the filesystem is ready AND we are in a multi-user runlevel
start on (local-filesystems and net-device-up IFACE!=lo and runlevel [2345])
stop  on runlevel [016]

# Upstart's PID-tracking heuristic. Getting this wrong is the classic Upstart bug:
# it tracks the wrong PID and "stop" kills nothing.
expect fork

respawn
respawn limit 10 5          # 10 restarts in 5 seconds, then give up

console log
env MYAPP_ENV=production

pre-start script
    mkdir -p /var/run/myapp
    chown myapp:myapp /var/run/myapp
end script

exec /usr/local/bin/myapp --daemon

post-stop script
    rm -f /var/run/myapp/myapp.pid
end script
```

```console
$ initctl list | head -5
mountall-net stop/waiting
rsyslog start/running, process 682
tty4 start/running, process 1147
udev start/running, process 405
myapp start/running, process 2891

$ sudo initctl start myapp
myapp start/running, process 2891

$ sudo initctl status myapp
myapp start/running, process 2891

$ sudo initctl emit some-custom-event
```

**Why it lost:** `expect fork` / `expect daemon` is a *guess* about how many times a daemon forks. Guess wrong and Upstart tracks a PID that has already exited — the job appears running when it is dead, or `stop` hangs. systemd solved the same problem definitively by putting the service in a cgroup, where process identity is not a guess. Shipped in Ubuntu 6.10–14.10 and RHEL 6; replaced by systemd in Ubuntu 15.04 and RHEL 7. Know what it is; you will not be asked to configure it.

### 5.4 systemd

**Unit types** — the vocabulary:

| Suffix | Purpose |
|---|---|
| `.service` | A process or set of processes |
| `.target` | A synchronisation point grouping other units — the runlevel replacement |
| `.socket` | A socket; activates its `.service` on first connection |
| `.mount` | A mount point; **auto-generated from `/etc/fstab`** |
| `.automount` | On-demand mounting |
| `.swap` | A swap device or file |
| `.device` | A udev device exposed as a unit |
| `.path` | Filesystem-change trigger |
| `.timer` | Time-based trigger (cron replacement) |
| `.slice` | A cgroup node for resource management |
| `.scope` | Externally-created processes grouped into a cgroup |

**Unit search path, in ascending priority** — the second-most-important systemd fact after cgroups:

| Path | Owner | Purpose |
|---|---|---|
| `/usr/lib/systemd/system/` | The package manager | Vendor units. **Never edit** — an update overwrites you |
| `/run/systemd/system/` | Runtime | Volatile, gone on reboot |
| `/etc/systemd/system/` | **You** | Local overrides and custom units. Wins |

Override without editing the vendor file:

```console
$ sudo systemctl edit nginx.service
```

which creates `/etc/systemd/system/nginx.service.d/override.conf` — merged on top of the vendor unit. `systemctl edit --full nginx.service` copies the whole unit to `/etc/` instead. `systemctl revert nginx.service` deletes the overrides.

**Runlevel ↔ target mapping** — memorise this table:

| SysV runlevel | systemd target | Symlink |
|---|---|---|
| 0 | `poweroff.target` | `runlevel0.target` |
| 1, s, single | `rescue.target` | `runlevel1.target` |
| 2 | `multi-user.target` | `runlevel2.target` |
| 3 | `multi-user.target` | `runlevel3.target` |
| 4 | `multi-user.target` | `runlevel4.target` |
| 5 | `graphical.target` | `runlevel5.target` |
| 6 | `reboot.target` | `runlevel6.target` |
| — | `emergency.target` | (no runlevel equivalent) |

```console
$ ls -l /usr/lib/systemd/system/runlevel*.target
lrwxrwxrwx 1 root root 15 runlevel0.target -> poweroff.target
lrwxrwxrwx 1 root root 13 runlevel1.target -> rescue.target
lrwxrwxrwx 1 root root 17 runlevel2.target -> multi-user.target
lrwxrwxrwx 1 root root 17 runlevel3.target -> multi-user.target
lrwxrwxrwx 1 root root 17 runlevel4.target -> multi-user.target
lrwxrwxrwx 1 root root 16 runlevel5.target -> graphical.target
lrwxrwxrwx 1 root root 13 runlevel6.target -> reboot.target
```

```console
$ systemctl get-default
multi-user.target

$ sudo systemctl set-default graphical.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/graphical.target.

$ sudo systemctl isolate multi-user.target     # ≈ telinit 3
$ sudo systemctl rescue                        # ≈ telinit 1
$ sudo systemctl emergency
$ sudo systemctl reboot
$ sudo systemctl poweroff
$ sudo systemctl kexec                         # reboot without firmware re-init
```

The boot target chain:

```
                              default.target  (symlink)
                                     │
                              graphical.target
                                     │  Requires=
                             multi-user.target
                                     │  Requires=
                               basic.target
                            ┌────────┼────────┐
                    sysinit.target  sockets.target  paths.target  slices.target
                            │
          ┌─────────────────┼─────────────────┐
   local-fs.target    swap.target      cryptsetup.target
          │
   local-fs-pre.target
          │
   (systemd-fstab-generator output: *.mount units)
```

A complete, production-grade service unit:

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=myapp application server
Documentation=https://example.internal/runbooks/myapp

# Ordering: "After" is ONLY ordering. It does NOT pull the unit in.
After=network-online.target postgresql.service
# "Wants" pulls it in but tolerates failure. "Requires" fails us if it fails.
Wants=network-online.target
Requires=postgresql.service

# If postgresql is stopped or restarted, restart us too.
PartOf=postgresql.service

# Do not enter a restart storm during a dependency outage.
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=notify
NotifyAccess=main

User=myapp
Group=myapp
WorkingDirectory=/var/lib/myapp

EnvironmentFile=-/etc/sysconfig/myapp
Environment=MYAPP_ENV=production

ExecStartPre=/usr/local/bin/myapp migrate --check
ExecStart=/usr/local/bin/myapp serve --config /etc/myapp/config.yaml
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=5s
TimeoutStartSec=90s
TimeoutStopSec=30s
KillMode=mixed
KillSignal=SIGTERM

# Resource control — enforced by cgroup v2, not advisory
MemoryMax=2G
MemoryHigh=1500M
CPUQuota=200%
TasksMax=512
IOWeight=100

# Sandboxing. Each line removes a capability the service does not need.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/myapp /var/log/myapp
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=

StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemd-analyze verify /etc/systemd/system/myapp.service
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now myapp.service
Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service → /etc/systemd/system/myapp.service.
```

That symlink **is** what `enable` means: `WantedBy=multi-user.target` causes a symlink into `multi-user.target.wants/`. It is the direct descendant of `S55sshd`, with the ordering made explicit instead of numeric.

A custom target — the modern equivalent of "runlevel 4 is ours":

```ini
# /etc/systemd/system/platform-node.target
[Unit]
Description=Platform node fully in service
Documentation=https://example.internal/runbooks/node-lifecycle
Requires=multi-user.target
After=multi-user.target
AllowIsolate=yes
```

```ini
# /etc/systemd/system/node-ready.service — gate that fires only when the node
# is genuinely serving traffic, so the health checker has a single unit to watch.
[Unit]
Description=Mark node ready for traffic
After=kubelet.service containerd.service
Requires=kubelet.service containerd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/node-ready --register
ExecStop=/usr/local/bin/node-ready --drain
TimeoutStartSec=300

[Install]
WantedBy=platform-node.target
```

---

## 6. Verification and failure diagnosis

### 6.1 `dmesg` — the kernel ring buffer

```console
$ sudo dmesg --level=err,crit,alert,emerg
[    3.821004] EXT4-fs (sda2): mounted filesystem with ordered data mode. Quota mode: none.
[   12.443219] i40e 0000:3b:00.1: Error I40E_AQ_RC_EINVAL adding RX filters
[   14.902117] mpt3sas_cm0: log_info(0x31120303): originator(PL), code(0x12), sub_code(0x0303)

$ sudo dmesg -T | tail -5
[Mon Aug 25 09:14:02 2026] nvme nvme0: I/O 452 QID 3 timeout, aborting
[Mon Aug 25 09:14:02 2026] nvme nvme0: Abort status: 0x0
[Mon Aug 25 09:14:32 2026] nvme nvme0: I/O 452 QID 3 timeout, reset controller
[Mon Aug 25 09:14:33 2026] nvme nvme0: 32/0/0 default/read/poll queues
[Mon Aug 25 09:14:33 2026] EXT4-fs warning (device nvme0n1p2): ext4_end_bio:343: I/O error 10 writing to inode 262148

$ sudo dmesg -w                 # follow, like tail -f
$ sudo dmesg -H                 # human-readable pager, colour, relative times
$ sudo dmesg --facility=kern --level=warn
$ sudo dmesg -c                 # print AND CLEAR the buffer — destructive
```

Two constraints that matter:

- The ring buffer is **finite** (`CONFIG_LOG_BUF_SHIFT`, resizable with `log_buf_len=8M`). On a noisy machine, early boot messages are **overwritten within minutes**. If you need boot-time kernel messages hours later, you need the journal, not `dmesg`.
- Since kernel 4.10, `dmesg` requires root unless `kernel.dmesg_restrict=0`.

```console
$ sysctl kernel.dmesg_restrict
kernel.dmesg_restrict = 1

$ cat /proc/sys/kernel/printk
7	4	1	7
#  ^   ^   ^   ^
#  |   |   |   default console loglevel for new consoles
#  |   |   minimum console loglevel
#  |   default message loglevel (for printk without a level)
#  current console loglevel — messages below this number are shown
```

### 6.2 `journalctl` — the authoritative boot log

**Persistence is the first thing to check.** By default on many systems the journal is in `/run/log/journal`, which is a tmpfs — *it does not survive the reboot you want to investigate*.

```console
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 4f2a91c7d8b34e0e9a15b6c2d7e3f804 Fri 2026-08-22 08:12:44 -03 Fri 2026-08-22 19:03:11 -03
 -2 a71b3e05c9f24d6b8e0a2c4f6d81b593 Sat 2026-08-23 09:01:02 -03 Sun 2026-08-24 22:40:57 -03
 -1 c05d8f1a2b674e39a8c1d0e5f7b32a46 Mon 2026-08-25 07:55:19 -03 Mon 2026-08-25 09:12:03 -03
  0 e93c4a2b1d5f48079b6e2a8c0d13f57e Mon 2026-08-25 09:14:41 -03 Mon 2026-08-25 11:38:20 -03
```

If that command shows only index `0`, the journal is volatile. Fix it — this is a one-line change that pays for itself the first time a node reboots unexpectedly:

```bash
# /etc/systemd/journald.conf.d/50-persistent.conf
[Journal]
Storage=persistent
Compress=yes
Seal=yes                    # FSS cryptographic sealing (needs journalctl --setup-keys)
SystemMaxUse=2G
SystemKeepFree=1G
SystemMaxFileSize=128M
MaxRetentionSec=1month
MaxFileSec=1day
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
```

```console
$ sudo mkdir -p /var/log/journal
$ sudo systemd-tmpfiles --create --prefix /var/log/journal
$ sudo systemctl restart systemd-journald
$ journalctl --disk-usage
Archived and active journals take up 1.4G in the file system.
```

**The queries you actually use:**

```console
$ journalctl -b                       # this boot
$ journalctl -b -1                    # the PREVIOUS boot — for post-mortem
$ journalctl -b c05d8f1a2b674e39a8c1d0e5f7b32a46
$ journalctl -b -1 -p err             # errors only, previous boot
$ journalctl -k -b -1                 # kernel messages only, previous boot
$ journalctl -u kubelet -b --no-pager
$ journalctl -u myapp.service -f      # follow
$ journalctl --since "2026-08-25 09:00" --until "2026-08-25 09:30"
$ journalctl --since "-15min"
$ journalctl -o json-pretty -n 1
$ journalctl _PID=1 -b                # everything PID 1 logged
$ journalctl _TRANSPORT=kernel -b
$ journalctl -b _SYSTEMD_UNIT=sshd.service + _COMM=sshd
$ journalctl -b -g 'timeout|failed to mount'   # grep, PCRE
```

Priority levels, `-p`: `0 emerg`, `1 alert`, `2 crit`, `3 err`, `4 warning`, `5 notice`, `6 info`, `7 debug`. `-p err` means "err **and more severe**".

```console
$ journalctl -b -p err --no-pager
Aug 25 09:14:52 node07 kernel: nvme nvme0: I/O 452 QID 3 timeout, reset controller
Aug 25 09:15:03 node07 systemd[1]: Failed to mount /srv/data.
Aug 25 09:15:03 node07 systemd[1]: Dependency failed for Local File Systems.
Aug 25 09:15:03 node07 systemd[1]: Dependency failed for Mark node ready for traffic.
```

Read that stack bottom-up: a mount failure cascaded into `local-fs.target`, which everything else depends on. **In systemd, always find the *first* failure — the rest are dependency fallout.**

The pre-systemd files still exist on many systems and are examinable:

| File | Content |
|---|---|
| `/var/log/dmesg` | A snapshot of the ring buffer taken once at boot (`rsyslog`/`bootlogd`) |
| `/var/log/boot.log` | The `[ OK ]`/`[FAILED]` console output of the boot |
| `/var/log/messages` | Red Hat catch-all syslog |
| `/var/log/syslog` | Debian catch-all syslog |

### 6.3 systemd boot analysis

```console
$ systemd-analyze
Startup finished in 3.221s (firmware) + 2.104s (loader) + 1.842s (kernel) + 4.117s (initrd) + 12.398s (userspace) = 23.683s
multi-user.target reached after 12.301s in userspace.
```

That single line **localises the problem to one hand-off**. 3.2 s of firmware is a BIOS setting; 4.1 s of initrd is a storage/udev problem; 12.4 s of userspace is a service.

```console
$ systemd-analyze blame | head -12
         6.482s kdump.service
         4.117s NetworkManager-wait-online.service
         2.109s dracut-initqueue.service
         1.884s systemd-udev-settle.service
         1.203s containerd.service
          981ms lvm2-monitor.service
          702ms sssd.service
          611ms firewalld.service
          448ms systemd-logind.service
          312ms auditd.service
          204ms polkit.service
          188ms chronyd.service
```

**`blame` is misleading on its own** — it sorts by individual duration, ignoring parallelism. A 6 s service running concurrently with others costs you nothing. Use `critical-chain`, which follows the actual dependency path:

```console
$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

graphical.target @12.398s
└─multi-user.target @12.396s
  └─node-ready.service @12.201s +194ms
    └─kubelet.service @8.033s +4.166s
      └─containerd.service @6.822s +1.203s
        └─network-online.target @6.818s
          └─NetworkManager-wait-online.service @2.700s +4.117s
            └─NetworkManager.service @2.401s +295ms
              └─dbus-broker.service @2.388s
                └─basic.target @2.381s
                  └─sysinit.target @2.377s
                    └─systemd-udev-settle.service @493ms +1.884s
                      └─systemd-udev-trigger.service @441ms +49ms
                        └─systemd-udevd-control.socket @437ms
                          └─-.mount @420ms
                            └─system.slice @420ms
                              └─-.slice @420ms
```

Now the analysis is concrete: 4.1 s waiting for `NetworkManager-wait-online` plus 1.9 s in `systemd-udev-settle` are 6 s of pure serial latency on the critical path. `systemd-udev-settle` is deprecated — any unit still pulling it in is a bug worth chasing.

```console
$ systemd-analyze critical-chain kubelet.service
$ systemd-analyze plot > /tmp/boot.svg          # full parallel timeline
$ systemd-analyze dot --to-pattern='*.target' | dot -Tsvg > /tmp/deps.svg
$ systemd-analyze security sshd.service | tail -3
→ Overall exposure level for sshd.service: 9.6 UNSAFE 😨
$ systemd-analyze dump --no-pager | less        # complete PID 1 state
```

**Fleet practice:** export `systemd-analyze` output as a metric and alert on regression. A node whose boot time doubled after an image update is telling you something changed on the critical path — usually a new `network-online.target` dependency — before it costs you a maintenance window.

```console
$ systemctl list-units --type=target --state=active
UNIT                   LOAD   ACTIVE SUB    DESCRIPTION
basic.target           loaded active active Basic System
cryptsetup.target      loaded active active Local Encrypted Volumes
getty.target           loaded active active Login Prompts
local-fs-pre.target    loaded active active Local File Systems (Pre)
local-fs.target        loaded active active Local File Systems
multi-user.target      loaded active active Multi-User System
network-online.target  loaded active active Network is Online
network.target         loaded active active Network
paths.target           loaded active active Path Units
remote-fs.target       loaded active active Remote File Systems
slices.target          loaded active active Slice Units
sockets.target         loaded active active Socket Units
sysinit.target         loaded active active System Initialization
swap.target            loaded active active Swaps
timers.target          loaded active active Timer Units

$ systemctl --failed
  UNIT                LOAD   ACTIVE SUB    DESCRIPTION
● srv-data.mount      loaded failed failed /srv/data
● node-ready.service  loaded failed failed Mark node ready for traffic

$ systemctl list-jobs
JOB UNIT                              TYPE  STATE
142 systemd-networkd-wait-online.serv start running
 87 network-online.target             start waiting
```

`systemctl list-jobs` during a **hung** boot is the highest-value command in this section: it shows exactly which unit systemd is still waiting on right now.

```console
$ systemctl list-dependencies multi-user.target --before
$ systemctl show sshd.service -p After -p Before -p Requires -p Wants
After=network.target sshd-keygen.target systemd-journald.socket basic.target system.slice auditd.service
Before=multi-user.target shutdown.target
Requires=sysinit.target system.slice
Wants=sshd-keygen.target
```

### 6.4 Failure playbook

| Symptom on console | Failed hand-off | Most likely cause | First command |
|---|---|---|---|
| `No bootable device` / `Operating System not found` | Firmware → loader | MBR signature gone, wrong boot order, UEFI NVRAM entry lost | `efibootmgr -v`; boot rescue media, `grub2-install` |
| `error: unknown filesystem` → `grub rescue>` | Loader stage 1.5 → stage 2 | `/boot` moved, filesystem converted, `core.img` stale after a disk clone | `set prefix=`, `insmod normal`, `normal` |
| `error: file '/vmlinuz-…' not found` | Loader → kernel | Kernel removed but `grub.cfg`/BLS entry left behind | Boot an older entry; `grubby --info=ALL` |
| Menu appears, nothing after `Loading initial ramdisk` | Kernel decompression | Corrupt/truncated initramfs (full `/boot`) | `df -h /boot`; `dracut -f --regenerate-all` |
| `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)` | initramfs → real root | `root=` wrong, or the storage driver is not in the initramfs | Boot with `rd.break`, inspect `/dev`; rebuild with `--add-drivers` |
| `dracut-initqueue[…]: Warning: dracut-initqueue timeout - starting timeout scripts` (repeating), then `dracut:/#` | initramfs → real root | Root device never appeared: wrong UUID, LVM not activated, iSCSI/SAN not reachable | At the dracut shell: `blkid`, `lvm lvs`, `cat /proc/cmdline` |
| `You are in emergency mode … Give root password for maintenance` | init, `local-fs.target` | A bad `/etc/fstab` entry — the number one cause | `journalctl -xb -p err`; `mount -o remount,rw /`; fix `fstab`; `systemctl daemon-reload` |
| Boot hangs on `A start job is running for …` (counter climbing) | init | A unit with a long/infinite `TimeoutStartSec` — usually `*-wait-online` or a network mount | `Ctrl-Alt-Del` to the console, then `systemctl list-jobs` after boot; add `_netdev,nofail` to the fstab entry |
| Boots, but network interfaces are absent | init | `net.ifnames=0` added/removed → interface renamed, config no longer matches | `ip -br link`; `dmesg \| grep -i rename` |
| Boots to a black screen after the GRUB menu | Kernel, KMS | GPU driver mode-setting failure | Append `nomodeset` at the GRUB `e` prompt |
| Everything is `Permission denied` after boot | init, SELinux | Filesystem relabel needed after `selinux=0` was used | Boot with `enforcing=0`, `touch /.autorelabel`, reboot |
| Node reboots in a loop, no logs | — | Journal is volatile; kernel panics before flush | `Storage=persistent`; add `panic=30`, `crashkernel=`, configure kdump; capture the serial console |

### 6.5 The four recovery techniques, with real transcripts

**A. `rd.break` — a shell inside the initramfs**

The most powerful recovery path on a systemd machine: it works even when `/etc/fstab`, the root password, SELinux and PAM are all broken, because none of them has been used yet.

Append at the GRUB `e` prompt:

```
rd.break enforcing=0
```

```
Generating "/run/initramfs/rdsosreport.txt"

Entering emergency mode. Exit the shell to continue.
Type "journalctl" to view system logs.

dracut:/# cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.10.6-200.fc40.x86_64 root=/dev/mapper/vg0-root ro rd.lvm.lv=vg0/root rd.break enforcing=0

dracut:/# blkid
/dev/sda1: SEC_TYPE="msdos" UUID="A1B2-C3D4" TYPE="vfat" PARTUUID="9a3b1e77-..."
/dev/sda2: UUID="3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33" TYPE="ext4" PARTUUID="..."
/dev/sda3: UUID="Wf3kLp-2xYt-9Bqv-Nm4R-7dSc-Ue1A-gH8jKl" TYPE="LVM2_member" PARTUUID="..."

dracut:/# lvm vgs
  VG   #PV #LV #SN Attr   VSize   VFree
  vg0    1   2   0 wz--n- <99.00g    0

dracut:/# ls /sysroot
bin  boot  dev  etc  home  lib  lib64  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var

dracut:/# mount -o remount,rw /sysroot

dracut:/# chroot /sysroot

sh-5.2# passwd root
Changing password for user root.
New password:
Retype new password:
passwd: all authentication tokens updated successfully.

sh-5.2# vi /etc/fstab            # remove the bad entry

sh-5.2# touch /.autorelabel      # MANDATORY if SELinux is enforcing:
                                 # /etc/shadow was written with the wrong context

sh-5.2# exit
dracut:/# exit
[  OK  ] Reached target Basic System.
...
```

The `/.autorelabel` step is the one everybody forgets. Without it, on an SELinux-enforcing system, the file you just wrote has the initramfs's context and `sshd`/`login` cannot read it — you have "fixed" the machine into a different failure.

**B. Emergency mode via the kernel cmdline**

```
systemd.unit=emergency.target
```

Root is mounted **read-only**, nothing else is running:

```
Welcome to emergency mode! After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, "systemctl default" or "exit"
to boot into default mode.
Give root password for maintenance
(or press Control-D to continue):

[root@node07 ~]# journalctl -xb -p err --no-pager
Aug 25 09:15:03 node07 systemd[1[]: Mounting /srv/data...
Aug 25 09:15:03 node07 mount[612]: mount: /srv/data: special device /dev/mapper/vg1-data does not exist.
Aug 25 09:15:03 node07 systemd[1]: srv-data.mount: Mount process exited, code=exited, status=32/n/a
Aug 25 09:15:03 node07 systemd[1]: Failed to mount /srv/data.

[root@node07 ~]# mount -o remount,rw /
[root@node07 ~]# vi /etc/fstab
[root@node07 ~]# systemctl daemon-reload      # re-run the fstab generator
[root@node07 ~]# systemctl default
```

`systemctl daemon-reload` after editing `/etc/fstab` is not optional: the `.mount` units are **generated** from `fstab` by `systemd-fstab-generator` at boot and cached. Without a reload, systemd is still working from the broken version.

**The fstab hardening that prevents this class of incident entirely:**

```
# /etc/fstab
# <device>                                  <mount>     <type> <options>                        <dump> <pass>
UUID=3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33   /boot       ext4   defaults                          1 2
UUID=A1B2-C3D4                              /boot/efi   vfat   umask=0077,shortname=winnt        0 2
/dev/mapper/vg0-root                        /           xfs    defaults                          0 0
/dev/mapper/vg0-swap                        none        swap   defaults                          0 0

# nofail  -> boot continues if the device is missing (no emergency mode)
# _netdev -> ordered after network-online.target
# x-systemd.device-timeout -> bounded wait instead of a 90 s stall per device
# x-systemd.mount-timeout  -> bounded mount attempt
10.20.30.40:/exports/data  /srv/data  nfs4  rw,nofail,_netdev,x-systemd.device-timeout=10,x-systemd.mount-timeout=30,noatime  0 0
```

`nofail` on every non-essential mount is a one-word change that converts "the whole fleet is in emergency mode" into "a directory is empty and an alert fired". Apply it to every mount that is not `/`, `/usr`, or `/boot`.

**C. `init=/bin/bash` — the nuclear option**

```
init=/bin/bash rw
```

The kernel execs bash as PID 1. There is no systemd, no `/proc` guarantees, no networking, no signal handling, no clean shutdown.

```
bash-5.2# mount -o remount,rw /
bash-5.2# mount -t proc proc /proc
bash-5.2# passwd root
bash-5.2# touch /.autorelabel
bash-5.2# sync
bash-5.2# exec /sbin/init          # hand over to systemd, or:
bash-5.2# echo b > /proc/sysrq-trigger   # immediate reboot, no unmount
```

Do **not** use `reboot` or `shutdown` here — without PID 1 running systemd they will not work correctly. `sync` then SysRq, or `exec /sbin/init`.

This also demonstrates why an unprotected GRUB menu on a physically accessible machine is equivalent to handing out the root password, and why full-disk encryption is the actual mitigation — not a GRUB password.

**D. Rescue-media chroot — when the disk will not boot at all**

```console
# Boot the distribution's ISO in rescue mode, then:
$ sudo vgchange -ay
  2 logical volume(s) in volume group "vg0" now active

$ sudo mount /dev/mapper/vg0-root /mnt/sysroot
$ sudo mount /dev/sda2 /mnt/sysroot/boot
$ sudo mount /dev/sda1 /mnt/sysroot/boot/efi
$ for d in /dev /dev/pts /proc /sys /run; do sudo mount --bind $d /mnt/sysroot$d; done
$ sudo chroot /mnt/sysroot /bin/bash

# Now you are on the real system. Repair:
sh-5.2# dracut --force --regenerate-all
sh-5.2# grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
sh-5.2# grub2-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fedora
sh-5.2# efibootmgr -v
sh-5.2# exit

$ sudo umount -R /mnt/sysroot
$ sudo reboot
```

The bind mounts are mandatory: `dracut` and `grub2-install` need `/dev` for device nodes, `/sys` to detect the firmware mode, and `/proc` for mount information. A chroot without them produces an initramfs that appears to build and then does not work.

### 6.6 Pre-flight verification checklist

Run this **before** the reboot, not after. Every line is free.

```console
# 1. Is /boot full? A truncated initramfs is silent until it is fatal.
$ df -h /boot /boot/efi
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       974M  412M  495M  46% /boot
/dev/sda1       599M   18M  582M   3% /boot/efi

# 2. Does an initramfs exist for every installed kernel, and is it fresh?
$ ls -la --time-style=long-iso /boot/vmlinuz-* /boot/initramfs-*
-rw-------. 1 root root 41291776 2026-08-20 14:03 /boot/initramfs-6.10.6-200.fc40.x86_64.img
-rw-------. 1 root root 41108992 2026-07-30 08:12 /boot/initramfs-6.10.3-200.fc40.x86_64.img
-rwxr-xr-x. 1 root root 14962176 2026-08-20 14:01 /boot/vmlinuz-6.10.6-200.fc40.x86_64
-rwxr-xr-x. 1 root root 14958080 2026-07-30 08:10 /boot/vmlinuz-6.10.3-200.fc40.x86_64

# 3. Does the initramfs contain the driver for the root device?
$ lsblk -no NAME,TYPE,MOUNTPOINT /dev/sda
$ lsinitrd /boot/initramfs-6.10.6-200.fc40.x86_64.img | grep -cE 'nvme|megaraid|dm-mod'
7

# 4. Do the UUIDs in fstab actually resolve?
$ sudo findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS options: defaults
/boot
   [ ] target exists
   [ ] UUID=3f9a1c04-77b2-4e18-9c5a-2d6e8b0f1a33 translated to /dev/sda2
   [ ] source /dev/sda2 exists
Success, no errors or warnings detected

# 5. Is the default boot entry the one you think it is?
$ sudo grubby --default-kernel
/boot/vmlinuz-6.10.6-200.fc40.x86_64

# 6. Do all unit files parse?
$ sudo systemd-analyze verify default.target

# 7. Is anything already failed? Do not reboot into a known-broken state.
$ systemctl --failed
0 loaded units listed.

# 8. Will the journal survive the reboot?
$ journalctl --list-boots | wc -l
4

# 9. Is the serial console configured on BOTH the kernel and GRUB?
$ grep -E 'console=' /proc/cmdline /etc/default/grub

# 10. Only now:
$ sudo systemctl reboot
```

---

## 7. Complete infrastructure artifacts

### 7.1 Butane / Ignition — kernel arguments in an immutable OS

Fedora CoreOS and Flatcar run Ignition **inside the initramfs**, before `switch_root`. This is the modern answer to "configure the boot without a mutable filesystem".

```yaml
# platform-node.bu — compile with:
#   butane --pretty --strict platform-node.bu -o platform-node.ign
variant: fcos
version: 1.5.0

kernel_arguments:
  should_exist:
    - console=tty0
    - console=ttyS0,115200n8
    - systemd.unified_cgroup_hierarchy=1
    - transparent_hugepage=never
    - intel_iommu=on
    - iommu=pt
    - panic=30
    - oops=panic
    - crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
    - audit=1
  should_not_exist:
    - quiet
    - rhgb
    - mitigations=off

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction platform-team

storage:
  disks:
    - device: /dev/disk/by-id/coreos-boot-disk
      wipe_table: false
      partitions:
        - number: 4
          label: root
          size_mib: 16384
          resize: true
        - label: containers
          size_mib: 0            # 0 = use the remainder of the disk
  filesystems:
    - device: /dev/disk/by-partlabel/containers
      path: /var/lib/containers
      format: xfs
      wipe_filesystem: false
      label: CONTAINERS
      with_mount_unit: true
      mount_options:
        - prjquota
        - noatime

  files:
    - path: /etc/systemd/journald.conf.d/50-persistent.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [Journal]
          Storage=persistent
          Compress=yes
          SystemMaxUse=2G
          MaxRetentionSec=1month
          ForwardToSyslog=no

    - path: /etc/sysctl.d/90-platform.conf
      mode: 0644
      contents:
        inline: |
          kernel.panic = 30
          kernel.panic_on_oops = 1
          vm.swappiness = 1
          net.ipv4.ip_forward = 1
          fs.inotify.max_user_instances = 8192

    - path: /usr/local/bin/boot-report
      mode: 0755
      contents:
        inline: |
          #!/usr/bin/bash
          # Emit boot timing to the node_exporter textfile collector so that a
          # boot-time regression shows up on a dashboard, not in an incident.
          set -euo pipefail
          OUT=/var/lib/node_exporter/textfile_collector/boot.prom
          TMP="${OUT}.$$"
          install -d -m 0755 "$(dirname "$OUT")"
          parse() { systemd-analyze time 2>/dev/null || systemd-analyze; }
          line="$(parse | head -1)"
          get() { grep -oP "[0-9.]+(?=s \($1\))" <<<"$line" || echo 0; }
          {
            echo "# HELP node_boot_stage_seconds Duration of each boot stage."
            echo "# TYPE node_boot_stage_seconds gauge"
            for stage in firmware loader kernel initrd userspace; do
              printf 'node_boot_stage_seconds{stage="%s"} %s\n' "$stage" "$(get "$stage")"
            done
            echo "# HELP node_boot_id_info Boot ID of the current boot."
            echo "# TYPE node_boot_id_info gauge"
            printf 'node_boot_id_info{boot_id="%s"} 1\n' "$(cat /proc/sys/kernel/random/boot_id)"
          } > "$TMP"
          mv -f "$TMP" "$OUT"

systemd:
  units:
    - name: boot-report.service
      enabled: true
      contents: |
        [Unit]
        Description=Export boot timing metrics
        After=multi-user.target
        ConditionPathExists=/usr/local/bin/boot-report

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/boot-report

        [Install]
        WantedBy=multi-user.target

    - name: zincati.service
      # Disable automatic reboots for updates: reboot scheduling belongs to the
      # cluster drain controller, not to the node.
      mask: true
```

```console
$ butane --pretty --strict platform-node.bu -o platform-node.ign
$ coreos-installer install /dev/sda --ignition-file platform-node.ign
Installing Fedora CoreOS 40.20260815.3.0 x86_64 (512-byte sectors)
> Read disk 1.1 GiB/1.1 GiB (100%)
Writing Ignition config
Install complete.
```

### 7.2 cloud-init — kernel arguments and boot config on a mutable OS

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
hostname: node07
fqdn: node07.platform.example.internal
manage_etc_hosts: true

users:
  - name: platform
    groups: [wheel, systemd-journal]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDoNotUseInProduction platform-team

write_files:
  - path: /etc/systemd/journald.conf.d/50-persistent.conf
    permissions: "0644"
    owner: root:root
    content: |
      [Journal]
      Storage=persistent
      Compress=yes
      SystemMaxUse=2G
      MaxRetentionSec=1month

  - path: /etc/dracut.conf.d/50-platform.conf
    permissions: "0644"
    content: |
      hostonly="no"
      compress="zstd"
      add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
      add_dracutmodules+=" lvm dm multipath "
      omit_dracutmodules+=" plymouth "

  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
    permissions: "0644"
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 %I $TERM

bootcmd:
  # bootcmd runs on EVERY boot, very early — before write_files and runcmd.
  - [ cloud-init-per, once, disable_thp, sh, -c,
      "echo never > /sys/kernel/mm/transparent_hugepage/enabled" ]

runcmd:
  # 1. Persist the kernel command line across every installed kernel.
  - [ grubby, --update-kernel=ALL, --args=
      "console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic systemd.unified_cgroup_hierarchy=1" ]
  - [ grubby, --update-kernel=ALL, --remove-args, "quiet rhgb" ]

  # 2. Rebuild every initramfs with the platform dracut config above.
  - [ dracut, --force, --regenerate-all ]

  # 3. Make the journal persistent for THIS boot too, not just the next one.
  - [ mkdir, -p, /var/log/journal ]
  - [ systemd-tmpfiles, --create, --prefix, /var/log/journal ]
  - [ systemctl, restart, systemd-journald ]

  # 4. Verify before declaring the node ready. Fail loudly if the cmdline
  #    did not take — a silent miss here becomes a boot incident later.
  - [ sh, -c, "grubby --info=ALL | grep -q 'panic=30' || { echo 'FATAL: kernel args not applied' >&2; exit 1; }" ]
  - [ systemd-analyze, verify, default.target ]

power_state:
  mode: reboot
  message: "Rebooting to apply kernel arguments and new initramfs"
  timeout: 60
  condition: true

final_message: "Node ready after $UPTIME seconds, boot id $INSTANCE_ID"
```

### 7.3 Ansible — idempotent kernel-cmdline management across distributions

```yaml
---
# playbooks/boot-baseline.yml
# Enforces the boot-time baseline. Idempotent: safe to run on every pass.
# Reboots are gated behind an explicit -e allow_reboot=true.
- name: Boot baseline
  hosts: platform_nodes
  become: true
  serial: "10%"                    # never touch the whole fleet at once
  max_fail_percentage: 0

  vars:
    allow_reboot: false
    required_kargs:
      - "console=tty0"
      - "console=ttyS0,115200n8"
      - "transparent_hugepage=never"
      - "panic=30"
      - "oops=panic"
      - "systemd.unified_cgroup_hierarchy=1"
      - "audit=1"
    forbidden_kargs:
      - "quiet"
      - "rhgb"
      - "mitigations=off"
      - "selinux=0"

  tasks:
    - name: Determine firmware mode
      ansible.builtin.stat:
        path: /sys/firmware/efi
      register: efi_dir

    - name: Record firmware mode
      ansible.builtin.set_fact:
        firmware_mode: "{{ 'uefi' if efi_dir.stat.exists else 'bios' }}"

    - name: Show current kernel command line
      ansible.builtin.slurp:
        src: /proc/cmdline
      register: current_cmdline

    - name: Report drift before changing anything
      ansible.builtin.debug:
        msg: >-
          {{ inventory_hostname }} ({{ firmware_mode }}):
          {{ (current_cmdline.content | b64decode) | trim }}

    # ---------- Red Hat family: grubby is the idempotent primitive ----------
    - name: Apply required kernel arguments (RHEL family)
      ansible.builtin.command:
        argv:
          - grubby
          - --update-kernel=ALL
          - "--args={{ required_kargs | join(' ') }}"
      when: ansible_os_family == "RedHat"
      register: grubby_add
      changed_when: true
      notify: rebuild initramfs

    - name: Remove forbidden kernel arguments (RHEL family)
      ansible.builtin.command:
        argv:
          - grubby
          - --update-kernel=ALL
          - "--remove-args={{ forbidden_kargs | join(' ') }}"
      when: ansible_os_family == "RedHat"
      changed_when: true

    # ---------- Debian family: edit /etc/default/grub, then regenerate ----------
    - name: Set GRUB_CMDLINE_LINUX_DEFAULT (Debian family)
      ansible.builtin.lineinfile:
        path: /etc/default/grub
        regexp: '^GRUB_CMDLINE_LINUX_DEFAULT='
        line: 'GRUB_CMDLINE_LINUX_DEFAULT="{{ required_kargs | join('' '') }}"'
        create: false
        backup: true
      when: ansible_os_family == "Debian"
      notify:
        - update grub
        - rebuild initramfs

    - name: Enable the serial console in GRUB itself (both families)
      ansible.builtin.blockinfile:
        path: /etc/default/grub
        marker: "# {mark} ANSIBLE MANAGED serial console"
        backup: true
        block: |
          GRUB_TERMINAL_INPUT="console serial"
          GRUB_TERMINAL_OUTPUT="console serial"
          GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
          GRUB_TIMEOUT=5
          GRUB_TIMEOUT_STYLE=menu
          GRUB_DISABLE_OS_PROBER=true
      notify:
        - update grub
      when: ansible_os_family in ["RedHat", "Debian"]

    - name: Ship the platform dracut configuration
      ansible.builtin.copy:
        dest: /etc/dracut.conf.d/50-platform.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          hostonly="no"
          compress="zstd"
          add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
          add_dracutmodules+=" lvm dm multipath "
          omit_dracutmodules+=" plymouth "
      when: ansible_os_family == "RedHat"
      notify: rebuild initramfs

    - name: Make the journal persistent
      ansible.builtin.copy:
        dest: /etc/systemd/journald.conf.d/50-persistent.conf
        owner: root
        group: root
        mode: "0644"
        content: |
          [Journal]
          Storage=persistent
          Compress=yes
          SystemMaxUse=2G
          MaxRetentionSec=1month
          ForwardToSyslog=no
      notify: restart journald

    - name: Ensure the journal directory exists
      ansible.builtin.file:
        path: /var/log/journal
        state: directory
        owner: root
        group: systemd-journal
        mode: "2755"
      notify: restart journald

    - name: Enable the serial getty
      ansible.builtin.systemd:
        name: serial-getty@ttyS0.service
        enabled: true
        state: started
        daemon_reload: true

    - name: Flush handlers before the verification gate
      ansible.builtin.meta: flush_handlers

    # ---------- Verification: refuse to leave a node in an unbootable state ----------
    - name: Verify an initramfs exists for every installed kernel
      ansible.builtin.shell: |
        set -euo pipefail
        rc=0
        for k in /boot/vmlinuz-*; do
          [ "$k" = "/boot/vmlinuz-*" ] && continue
          v="${k#/boot/vmlinuz-}"
          if [ ! -s "/boot/initramfs-${v}.img" ] && [ ! -s "/boot/initrd.img-${v}" ]; then
            echo "MISSING initramfs for ${v}" >&2
            rc=1
          fi
        done
        exit "$rc"
      args:
        executable: /bin/bash
      changed_when: false

    - name: Verify /boot has headroom
      ansible.builtin.shell: |
        set -euo pipefail
        avail=$(df -Pm /boot | awk 'NR==2 {print $4}')
        [ "$avail" -ge 200 ] || { echo "/boot has only ${avail}MB free" >&2; exit 1; }
      args:
        executable: /bin/bash
      changed_when: false

    - name: Verify every fstab entry resolves
      ansible.builtin.command: findmnt --verify
      changed_when: false

    - name: Verify all unit files parse
      ansible.builtin.command: systemd-analyze verify default.target
      changed_when: false

    - name: Verify no unit is currently failed
      ansible.builtin.command: systemctl is-system-running
      register: sysrun
      changed_when: false
      failed_when: sysrun.stdout not in ["running", "degraded", "starting"]

    # ---------- Reboot, explicitly opted into ----------
    - name: Reboot to apply the new command line
      ansible.builtin.reboot:
        reboot_timeout: 900
        post_reboot_delay: 30
        test_command: systemctl is-system-running --wait
      when: allow_reboot | bool

    - name: Confirm the new command line is live
      ansible.builtin.slurp:
        src: /proc/cmdline
      register: post_cmdline
      when: allow_reboot | bool

    - name: Fail if any required argument did not survive the reboot
      ansible.builtin.assert:
        that:
          - "item in (post_cmdline.content | b64decode)"
        fail_msg: "Kernel argument '{{ item }}' is missing from /proc/cmdline after reboot"
        success_msg: "Kernel argument '{{ item }}' is active"
      loop: "{{ required_kargs }}"
      when: allow_reboot | bool

    - name: Report boot timing
      ansible.builtin.command: systemd-analyze time
      register: boot_time
      changed_when: false
      when: allow_reboot | bool

    - name: Show boot timing
      ansible.builtin.debug:
        var: boot_time.stdout_lines
      when: allow_reboot | bool

  handlers:
    - name: update grub
      ansible.builtin.command: >-
        {{ 'update-grub' if ansible_os_family == 'Debian'
           else ('grub2-mkconfig -o /boot/efi/EFI/' ~ ansible_distribution | lower ~ '/grub.cfg'
                 if firmware_mode == 'uefi'
                 else 'grub2-mkconfig -o /boot/grub2/grub.cfg') }}
      listen: update grub

    - name: rebuild initramfs
      ansible.builtin.command: >-
        {{ 'update-initramfs -u -k all' if ansible_os_family == 'Debian'
           else 'dracut --force --regenerate-all' }}
      listen: rebuild initramfs

    - name: restart journald
      ansible.builtin.systemd:
        name: systemd-journald
        state: restarted
      listen: restart journald
```

### 7.4 Kickstart — the bootloader stanza in full

```
# ks/platform-node.ks — unattended install, boot-relevant sections
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate --onboot=on
rootpw --iscrypted --lock
sshpw --username=install --lock
selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd,chronyd,auditd --disabled=kdump

# --- Boot loader -------------------------------------------------------------
# --location=mbr : BIOS -> MBR of the first disk. On UEFI, anaconda writes to
#                  the ESP regardless and this is effectively ignored.
# --boot-drive   : which disk gets the loader when several are present.
# --append       : appended to every generated boot entry.
# --iscrypted    : the PBKDF2 hash from grub2-mkpasswd-pbkdf2.
bootloader --location=mbr --boot-drive=sda --timeout=5 \
  --append="console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M audit=1 systemd.unified_cgroup_hierarchy=1" \
  --iscrypted --password=grub.pbkdf2.sha512.10000.C4E08A1B7D2F...9E3A.5B7C11D2...F0A8

# --- Partitioning ------------------------------------------------------------
zerombr
clearpart --all --initlabel --drives=sda
# biosboot is REQUIRED for GPT + legacy BIOS. Omitting it produces an
# installation that completes successfully and then does not boot.
part biosboot --fstype=biosboot --size=1  --ondisk=sda
part /boot/efi --fstype=efi     --size=600 --ondisk=sda --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=ext4    --size=1024 --ondisk=sda --label=BOOT
part pv.01     --size=1 --grow  --ondisk=sda
volgroup vg0 pv.01
logvol /     --vgname=vg0 --name=root --fstype=xfs  --size=20480
logvol swap  --vgname=vg0 --name=swap --fstype=swap --size=8192
logvol /var  --vgname=vg0 --name=var  --fstype=xfs  --size=1 --grow --fsoptions="noatime,nodev"

reboot --eject

%packages
@^minimal-environment
dracut-config-generic
grubby
efibootmgr
-plymouth
-plymouth-scripts
%end

%post --log=/root/ks-post.log
set -euxo pipefail

# Generic (not host-only) initramfs: this image is cloned across hardware SKUs.
cat > /etc/dracut.conf.d/50-platform.conf <<'EOF'
hostonly="no"
compress="zstd"
add_drivers+=" nvme nvme-tcp megaraid_sas dm-multipath "
add_dracutmodules+=" lvm dm multipath "
omit_dracutmodules+=" plymouth "
EOF
dracut --force --regenerate-all

# Persistent journal from the very first boot.
mkdir -p /var/log/journal
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-persistent.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
MaxRetentionSec=1month
EOF

# Serial console login.
systemctl enable serial-getty@ttyS0.service

# Prove the boot configuration before the machine ever reboots.
grubby --info=ALL | grep -q 'panic=30' || { echo 'FATAL: kernel args missing'; exit 1; }
%end
```

### 7.5 Kubernetes — node kernel arguments as declarative state

On OpenShift / OKD, the Machine Config Operator renders `kernelArguments` into the nodes' bootloader configuration and performs a **rolling, drain-aware reboot**. This is the correct pattern to imitate anywhere: a kernel-argument change is a *node lifecycle event*, not a config file edit.

```yaml
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-boot-baseline
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - console=tty0
    - console=ttyS0,115200n8
    - transparent_hugepage=never
    - panic=30
    - oops=panic
    - intel_iommu=on
    - iommu=pt
    - crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
        - path: /etc/systemd/journald.conf.d/50-persistent.conf
          mode: 420          # 0644 in decimal — Ignition uses decimal file modes
          overwrite: true
          contents:
            source: >-
              data:text/plain;charset=utf-8;base64,W0pvdXJuYWxdClN0b3JhZ2U9cGVyc2lzdGVudApDb21wcmVzcz15ZXMKU3lzdGVtTWF4VXNlPTJHCg==
        - path: /etc/sysctl.d/90-boot-baseline.conf
          mode: 420
          overwrite: true
          contents:
            source: >-
              data:text/plain;charset=utf-8;base64,a2VybmVsLnBhbmljID0gMzAKa2VybmVsLnBhbmljX29uX29vcHMgPSAxCg==
    systemd:
      units:
        - name: boot-report.service
          enabled: true
          contents: |
            [Unit]
            Description=Export boot timing metrics
            After=multi-user.target

            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/local/bin/boot-report

            [Install]
            WantedBy=multi-user.target
---
# Bound the blast radius: one node at a time, and never reboot outside the window.
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: worker-shutdown-grace
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    shutdownGracePeriod: 180s
    shutdownGracePeriodCriticalPods: 60s
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: worker
spec:
  maxUnavailable: 1
  paused: false
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: worker
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
```

```console
$ kubectl apply -f 99-worker-boot-baseline.yaml
machineconfig.machineconfiguration.openshift.io/99-worker-boot-baseline created

$ kubectl get mcp worker -w
NAME     CONFIG                        UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT
worker   rendered-worker-a4f1c2d8b9e0  False     True       False      6              5
worker   rendered-worker-7b3e9f10c2a5  True      False      False      6              6

$ kubectl debug node/worker-03 -it --image=registry.access.redhat.com/ubi9/ubi -- chroot /host cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt3)/ostree/rhcos-.../vmlinuz-5.14.0-427.el9.x86_64 root=UUID=... rw console=tty0 console=ttyS0,115200n8 transparent_hugepage=never panic=30 oops=panic intel_iommu=on iommu=pt crashkernel=1G-4G:192M
```

`maxUnavailable: 1` is the whole point. A kernel argument that makes nodes unbootable is a fleet-ending change if it rolls out in parallel; with a rolling pool it costs you exactly one node, and the pool stops.

---

## 8. Exam-focused quick reference

**The boot chain in one line, in order:** firmware (BIOS/UEFI) → boot loader (GRUB2) → kernel (`vmlinuz`) → initramfs (`/init`) → `switch_root` → init (systemd/SysVinit) → default target / runlevel.

| Question | Command |
|---|---|
| UEFI or BIOS? | `ls /sys/firmware/efi` |
| What did the bootloader pass to the kernel? | `cat /proc/cmdline` |
| Kernel messages, this boot | `dmesg` / `journalctl -k -b` |
| Kernel messages, previous boot | `journalctl -k -b -1` |
| Errors only, previous boot | `journalctl -b -1 -p err` |
| List all recorded boots | `journalctl --list-boots` |
| What is the default target? | `systemctl get-default` |
| Change the default target | `systemctl set-default multi-user.target` |
| Switch target now | `systemctl isolate rescue.target` |
| Which units failed? | `systemctl --failed` |
| What is systemd waiting on right now? | `systemctl list-jobs` |
| How long did the boot take, by stage? | `systemd-analyze` |
| What is on the boot critical path? | `systemd-analyze critical-chain` |
| Current runlevel (SysV) | `runlevel` |
| Change runlevel (SysV) | `telinit 3` / `init 3` |
| Which runlevels start this service? | `chkconfig --list sshd` |
| Rebuild the initramfs | `dracut -f --regenerate-all` / `update-initramfs -u -k all` |
| Regenerate GRUB config | `grub2-mkconfig -o <path>` / `update-grub` |
| Change kernel args persistently | `grubby --update-kernel=ALL --args="..."` |
| List/create UEFI boot entries | `efibootmgr -v` |

**Kernel parameters most likely to be asked:** `root=`, `ro`/`rw`, `init=/bin/bash`, `single`/`1`, `systemd.unit=rescue.target`, `systemd.unit=emergency.target`, `quiet`, `nomodeset`, `rd.break`, `console=ttyS0,115200n8`.

**Distinctions worth being precise about:**

- `initrd` is a **block-device image**; `initramfs` is a **cpio archive unpacked into tmpfs**. The kernel entry point is `/linuxrc` vs `/init`.
- `rescue.target` mounts the root filesystem and starts basic services; `emergency.target` gives you a shell on a **read-only** root with essentially nothing started.
- **`After=` is only ordering**; `Requires=`/`Wants=` are what actually pull a unit into the transaction. Both are usually needed.
- `dmesg` reads the **kernel ring buffer** — kernel messages only, wiped on reboot, finite. `journalctl` reads the **journal** — kernel *and* userspace, persistent if `Storage=persistent`, queryable across boots.
- **`--lang`-style regeneration vs editing:** `grub.cfg` is generated. Editing it directly works until the next `grub2-mkconfig`, package update or kernel install silently discards your change. Edit `/etc/default/grub`, `/etc/grub.d/`, or the BLS entry via `grubby`.

---

## 9. Referencias

**Exam objectives**

- LPI — Exam 101 Objectives (LPIC-1 version 5.0), objective 101.2 *Boot the system*: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Boot loaders and firmware**

- GNU GRUB Manual 2.06: https://www.gnu.org/software/grub/manual/grub/grub.html
- GRUB — Booting and command-line interface: https://www.gnu.org/software/grub/manual/grub/grub.html#Command_002dline-and-menu-entry-commands
- UEFI Specification (UEFI Forum): https://uefi.org/specifications
- The Boot Loader Specification (systemd/UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- `efibootmgr` project: https://github.com/rhboot/efibootmgr
- `shim` — the Secure Boot first-stage loader: https://github.com/rhboot/shim
- `systemd-boot` manual: https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html
- `bootctl` manual: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html

**Kernel, command line and initramfs**

- The kernel's command-line parameters (kernel.org): https://docs.kernel.org/admin-guide/kernel-parameters.html
- initrd / initramfs documentation (kernel.org): https://docs.kernel.org/admin-guide/initrd.html
- ramfs, rootfs and initramfs (kernel.org): https://docs.kernel.org/filesystems/ramfs-rootfs-initramfs.html
- Booting the kernel (x86 boot protocol): https://docs.kernel.org/arch/x86/boot.html
- Kernel lockdown and Secure Boot (`kernel_lockdown.7`): https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- `dracut` manual: https://man7.org/linux/man-pages/man8/dracut.8.html
- `dracut.cmdline` — dracut kernel parameters: https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html
- `dracut.conf` manual: https://man7.org/linux/man-pages/man5/dracut.conf.5.html
- `initramfs-tools` (Debian): https://manpages.debian.org/stable/initramfs-tools-core/initramfs-tools.7.en.html
- `update-initramfs` (Debian): https://manpages.debian.org/stable/initramfs-tools-core/update-initramfs.8.en.html

**init systems**

- systemd — index of manual pages: https://www.freedesktop.org/software/systemd/man/latest/
- `systemd(1)` — including kernel command-line options: https://www.freedesktop.org/software/systemd/man/latest/systemd.html
- `systemd.unit(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.service(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.target(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
- `bootup(7)` — the systemd boot process: https://www.freedesktop.org/software/systemd/man/latest/bootup.html
- `systemd-analyze(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd.mount(5)` — including `nofail`, `_netdev`, `x-systemd.*`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- `init(8)` / SysVinit: https://man7.org/linux/man-pages/man8/init.8.html
- `inittab(5)`: https://man7.org/linux/man-pages/man5/inittab.5.html
- `runlevel(8)`: https://man7.org/linux/man-pages/man8/runlevel.8.html
- `telinit(8)`: https://man7.org/linux/man-pages/man8/telinit.8.html
- SysVinit project: https://github.com/slicer69/sysvinit
- Upstart — Getting Started and cookbook: https://upstart.ubuntu.com/getting-started.html and https://upstart.ubuntu.com/cookbook/
- Linux Standard Base — init script actions and LSB headers: https://refspecs.linuxfoundation.org/LSB_5.0.0/LSB-Core-generic/LSB-Core-generic/iniscrptact.html

**Logging and diagnostics**

- `dmesg(1)` (util-linux): https://man7.org/linux/man-pages/man1/dmesg.1.html
- `journalctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/journalctl.html
- `systemd-journald.service(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html
- `journald.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- `systemd.journal-fields(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html
- `proc(5)` — `/proc/cmdline`, `/proc/sys/kernel/printk`: https://man7.org/linux/man-pages/man5/proc.5.html

**Distribution and platform documentation**

- Red Hat Enterprise Linux 9 — Managing, monitoring and updating the kernel (kernel command line, `grubby`, BLS): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- `grubby(8)`: https://man7.org/linux/man-pages/man8/grubby.8.html
- Fedora — Working with the GRUB 2 Boot Loader: https://docs.fedoraproject.org/en-US/fedora/latest/system-administrators-guide/kernel-module-driver-configuration/Working_with_the_GRUB_2_Boot_Loader/
- Debian Wiki — GRUB: https://wiki.debian.org/Grub
- Ubuntu — Kernel boot parameters / GRUB2: https://help.ubuntu.com/community/Grub2
- Fedora CoreOS — Butane configuration specification v1.5.0: https://coreos.github.io/butane/config-fcos-v1_5/
- Ignition specification v3.4.0: https://coreos.github.io/ignition/configuration-v3_4/
- Fedora CoreOS — Adding kernel arguments: https://docs.fedoraproject.org/en-US/fedora-coreos/kernel-args/
- cloud-init — modules reference (`bootcmd`, `runcmd`, `write_files`, `power_state`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible — `ansible.builtin.reboot` module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/reboot_module.html
- Anaconda — Kickstart `bootloader` command reference: https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
- OpenShift — Adding kernel arguments to nodes with MachineConfig: https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/machine_configuration/index