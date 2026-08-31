# LPIC-1 · Topic 102.2 — Install a Boot Manager

**Exam:** 101-500 (LPIC-1 v5.0) · **Weight:** 3.13 · **Level:** Production / SRE / Platform Architect

**Objective coverage:**
- Providing alternative boot locations and backup boot options
- Install and configure a boot loader such as GRUB Legacy
- Perform basic configuration changes for GRUB 2
- Interact with the boot loader

**Key files, terms and utilities:** `menu.lst`, `grub.cfg`, `grub.conf`, `grub-install`, `grub-mkconfig`, MBR

---

## 1. Motivation: the architectural problem

The boot loader is the only component of a Linux system that **you cannot fix over SSH**. Every other failure mode in a fleet — a wedged container runtime, a corrupted package database, a full disk — leaves you a shell. A broken boot loader leaves you a serial console, a KVM-over-IP session, or a datacenter ticket.

This asymmetry defines the whole engineering problem:

| Layer | Failure blast radius | Remediation channel | MTTR at fleet scale |
|---|---|---|---|
| Application | 1 pod / 1 process | Orchestrator restart | seconds |
| Kernel / initramfs | 1 node | reboot into previous kernel | ~1 min (if a fallback entry exists) |
| Boot loader config (`grub.cfg`) | 1 node | rescue media, chroot | 15–60 min |
| Boot loader stage 1 / core image (MBR / ESP) | 1 node, **unreachable** | physical or OOB console | hours |
| Boot loader config pushed by config management | **entire fleet, simultaneously** | per-node OOB console | days |

That last row is the one that ends careers. A single Ansible play that runs `grub-mkconfig` with a bad `GRUB_CMDLINE_LINUX` across 800 nodes and then triggers a rolling reboot converts a software change into a hardware-access problem. The lesson embedded in every practice below: **boot loader changes are one-way doors unless you explicitly build the door back.**

Three concrete production incidents that this topic exists to prevent:

1. **The BootHole aftermath (CVE-2020-10713, July 2020).** Distros shipped new `grub2` packages. The GRUB *modules* under `/boot/grub/i386-pc/` were updated on disk, but the *core image* embedded in the post-MBR gap was **not** re-installed, because `grub-install` is not automatically run by the package hook on every distro. On next reboot: `error: symbol 'grub_calloc' not found` and a `grub rescue>` prompt. Thousands of hosts, worldwide, offline at once.
2. **The unmirrored MBR.** A RAID1 root array survives the loss of `/dev/sda`. The bootstrap code in `/dev/sda`'s MBR does not — because it was never written to `/dev/sdb`. The array is healthy; the machine will not POST into it.
3. **The kernel argument that only fails after reboot.** `GRUB_CMDLINE_LINUX="... root=/dev/sda2"` baked into a golden image. The image is later deployed on NVMe hardware where the device is `/dev/nvme0n1p2`. `dracut` drops to an emergency shell on every node in the new rack.

Everything in this document is organised around making these three classes of failure *detectable before reboot* and *recoverable without physical access*.

---

## 2. The boot chain: what the loader actually does

### 2.1 BIOS / MBR path (legacy, `i386-pc` target)

```
Power on
  └─ BIOS POST
      └─ reads sector 0 (LBA 0) of the boot device — 512 bytes: the MBR
          ├─ bytes 0..445    : bootstrap code   ← GRUB boot.img / GRUB Legacy stage1
          ├─ bytes 446..509  : 4 × 16-byte partition table entries
          └─ bytes 510..511  : 0x55 0xAA signature
              └─ boot.img (446 bytes!) knows ONE thing: the LBA of core.img
                  └─ core.img lives in the "post-MBR gap" (LBA 1 .. 2047)
                     or in a BIOS Boot Partition (GPT, type EF02)
                      └─ core.img contains: diskboot + filesystem drivers
                                            + the `prefix` (e.g. (hd0,msdos1)/boot/grub)
                          └─ loads normal.mod, reads grub.cfg
                              └─ loads vmlinuz + initramfs into RAM
                                  └─ jumps to the kernel entry point
```

The 446-byte budget is why the chain has so many stages: there is not enough room in the MBR for a filesystem driver. GRUB Legacy solved this with **stage1 → stage1_5 (filesystem-specific, in the gap) → stage2 (in `/boot/grub`)**. GRUB 2 collapses stage1_5 and stage2 into a single generated `core.img` whose module set is chosen at install time by `grub-install`.

**Critical consequence:** `core.img` contains a hard-coded sector list. Defragmenting `/boot`, restoring it from backup, or changing the filesystem under it can invalidate that list. This is why `grub-install` must be re-run after any operation that moves `/boot/grub`.

### 2.2 UEFI path (`x86_64-efi` target)

```
Power on
  └─ UEFI firmware initialises
      └─ reads NVRAM variables: BootOrder, Boot0000..Bootxxxx, BootNext
          └─ each Bootxxxx = device path + file path, e.g.
             HD(1,GPT,<part-uuid>,...)/File(\EFI\debian\shimx64.efi)
              └─ mounts the EFI System Partition (ESP): FAT32, type EF00
                  └─ executes the PE/COFF binary directly — no MBR involved
                      ├─ Secure Boot ON : shimx64.efi → grubx64.efi → vmlinuz
                      └─ Secure Boot OFF: grubx64.efi → vmlinuz
```

There is **no MBR bootstrap** on a UEFI system. `grub-install` on UEFI copies an EFI binary into the ESP and calls `efibootmgr` to write an NVRAM entry. If the firmware finds no valid `Bootxxxx` entry, it falls back to the **removable media path**: `\EFI\BOOT\BOOTX64.EFI`.

### 2.3 The boundary you must be able to draw

| Responsibility | Owner | Fix without reboot? |
|---|---|---|
| Find the kernel file | boot loader | no |
| Pass the kernel command line | boot loader | no |
| Load `initramfs` into memory | boot loader | no |
| Assemble RAID / unlock LUKS / activate LVM | **initramfs** (`dracut`, `initramfs-tools`) | no |
| Mount the real root filesystem | initramfs | no |
| `switch_root` and exec PID 1 | initramfs | no |
| Everything after | systemd | yes |

A large fraction of "GRUB is broken" tickets are actually initramfs failures. The diagnostic is positional: if you see a GRUB menu, GRUB works. If you see `dracut:/#` or `(initramfs)`, GRUB did its job and handed off correctly.

---

## 3. Comparative analysis: which boot manager, and why

### 3.1 Feature / trade-off matrix

| | **GRUB Legacy** (0.9x) | **GRUB 2** (2.xx) | **systemd-boot** | **SYSLINUX / EXTLINUX** | **rEFInd** | **U-Boot** |
|---|---|---|---|---|---|---|
| Firmware support | BIOS only | BIOS, UEFI, coreboot, IEEE1275, ARM | **UEFI only** | BIOS (`syslinux`/`isolinux`), UEFI (limited) | UEFI only | embedded/ARM |
| Reads Linux filesystems | ext2/3, ReiserFS, XFS, JFS, FAT | ext2/3/4, XFS, Btrfs, ZFS, F2FS, LVM, mdraid, LUKS1/2, HFS+, NTFS… | **FAT only** (ESP) | ext2/3/4, Btrfs, FAT | FAT + ext (driver) | many |
| Config format | static, hand-edited `menu.lst` | **generated** `grub.cfg` + scripting language | declarative `.conf` files (BLS) | static `syslinux.cfg` | auto-discovery + `refind.conf` | scripted env |
| Scripting (`if`, loops, functions) | no | **yes** | no | no | no | yes |
| Boots from LVM / RAID / encrypted `/boot` | no | **yes** | no | no (needs plain partition) | no | no |
| Secure Boot chain (shim-signed) | no | **yes** | yes | rarely | yes | n/a |
| Network boot | limited | `grub-mknetdir`, TFTP/HTTP | no | **PXELINUX — the classic** | no | yes |
| Boot counting / auto-rollback | `fallback` directive | `grubenv` + scripting | `+N-M` counting in entry filename | no | no | `bootcount` |
| Config complexity | low | **high** | **very low** | low | very low | high |
| Attack surface / CVE history | frozen (EOL) | large (BootHole, SBAT) | small | small | small | large |
| Typical 2020s use | RHEL/CentOS ≤ 6, legacy appliances | **default nearly everywhere** | Arch, Pop!_OS, immutable/UKI hosts, cloud | ISOs, PXE, embedded | multiboot workstations | ARM SBCs |

### 3.2 Architect's decision guide

| Requirement | Choose | Rationale |
|---|---|---|
| Heterogeneous fleet, BIOS + UEFI, one config management codebase | **GRUB 2** | single tool, single config generator, both targets |
| `/boot` on LVM, mdraid, Btrfs subvolume, or LUKS | **GRUB 2** | only loader with the filesystem drivers |
| Immutable / image-based OS with UKIs (Unified Kernel Images) | **systemd-boot** | no config generation step, no scripting, tiny attack surface |
| Serial-console-only rack, needs interactive edit at boot | **GRUB 2** | mature `GRUB_TERMINAL=serial` support and an editable menu |
| PXE-booting an installer or a rescue environment | **PXELINUX** or **GRUB 2 netboot** | PXELINUX is simpler; GRUB 2 handles UEFI HTTP boot |
| Maintaining RHEL 6 / legacy appliance | **GRUB Legacy** | it is what is installed; do not migrate a system you cannot reinstall |
| Boot with automatic rollback on failed boot | **GRUB 2** + `grubenv` counting, or **systemd-boot** counting | needs persistent, loader-writable state |

**The honest position:** on a general-purpose Linux fleet in 2026, GRUB 2 is the default and the correct choice, not because it is elegant — it is not; it is a small operating system with a shell language — but because it is the only loader that can read the storage stack you actually run.

### 3.3 GRUB Legacy vs GRUB 2 — the differences the exam and production both care about

| Aspect | GRUB Legacy | GRUB 2 |
|---|---|---|
| Config file | `/boot/grub/menu.lst` (Debian) · `/boot/grub/grub.conf` + symlink (Red Hat) | `/boot/grub/grub.cfg` (Debian) · `/boot/grub2/grub.cfg` (Red Hat) |
| Config is edited by | **you, directly** | **never directly** — regenerated by `grub-mkconfig` |
| Config inputs | n/a | `/etc/default/grub` + `/etc/grub.d/*` |
| **Partition numbering** | **from 0** — `(hd0,0)` is the first partition | **from 1** — `(hd0,1)` is the first partition |
| Partition table in device name | no | yes — `(hd0,msdos1)`, `(hd0,gpt2)` |
| Disk numbering | from 0 — `(hd0)` is the first disk | from 0 — unchanged |
| Menu item keyword | `title <free text>` | `menuentry '<text>' --id <stable-id> { … }` |
| Default selection | `default 0` (index) or `default saved` | `GRUB_DEFAULT=0` / `"menu>submenu"` / `saved` |
| Fallback entry | `fallback 1` | `set fallback=…` in generated script / `grubenv` |
| Stages on disk | stage1, stage1_5, stage2 | `boot.img`, `core.img` (generated), modules `*.mod` |
| Modules | compiled in | loadable `.mod` files, `insmod` at runtime |
| Install command | `grub-install` or interactive `root`/`setup` | `grub-install` only |
| Password | `password --md5 <hash>` | `set superusers` + `password_pbkdf2` |
| Interactive rescue | `grub>` shell | `grub>` (full) and `grub rescue>` (minimal) |

> **Exam trap, stated plainly:** the off-by-one in partition numbering is the single most-tested fact in this objective. GRUB Legacy `(hd0,0)` and GRUB 2 `(hd0,1)` refer to **the same partition** — the first one on the first disk, conventionally `/dev/sda1`.

---

## 4. Inspecting the current boot topology

Before touching anything, establish ground truth. Never assume the firmware mode.

### 4.1 Am I on UEFI or BIOS?

```console
$ [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
UEFI

$ cat /sys/firmware/efi/fw_platform_size
64
```

`/sys/firmware/efi` exists **only** if the kernel was booted by UEFI firmware. A UEFI-capable machine booted in CSM/legacy mode will report BIOS — which is correct, because that is how it must be re-installed.

### 4.2 Disk and partition layout

```console
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,LABEL,MOUNTPOINTS
NAME        SIZE TYPE FSTYPE PARTTYPENAME              LABEL  MOUNTPOINTS
sda       465.8G disk
├─sda1        1M part                BIOS boot
├─sda2      512M part  vfat          EFI System                /boot/efi
├─sda3        1G part  ext4          Linux filesystem   boot   /boot
└─sda4    464.3G part  LVM2_member   Linux LVM
  ├─vg0-root  50G lvm  xfs                                     /
  └─vg0-data 400G lvm  xfs                                     /srv
sdb       465.8G disk
├─sdb1        1M part                BIOS boot
├─sdb2      512M part  vfat          EFI System
├─sdb3        1G part  ext4          Linux filesystem   boot2
└─sdb4    464.3G part  LVM2_member   Linux LVM
```

This is a **hybrid-bootable, dual-ESP layout** — bootable under both firmware modes, from either disk. Section 8 shows how to build and maintain it.

```console
$ sudo parted /dev/sda print
Model: ATA Samsung SSD 870 (scsi)
Disk /dev/sda: 500GB
Sector size (logical/physical): 512B/512B
Partition Table: gpt
Disk Flags:

Number  Start   End     Size    File system  Name                  Flags
 1      1049kB  2097kB  1049kB               BIOS boot partition   bios_grub
 2      2097kB  539MB   537MB   fat32        EFI System Partition  boot, esp
 3      539MB   1613MB  1074MB  ext4         boot
 4      1613MB  500GB   498GB                data                  lvm
```

> **`bios_grub` is not optional.** On a GPT disk booted via BIOS there is no reliable post-MBR gap (GPT's primary header occupies LBA 1 and the partition array LBA 2–33). Without a ~1 MiB partition of type `EF02` flagged `bios_grub`, `grub-install --target=i386-pc` fails with:
> `grub-install: error: will not proceed with blocklists`.

### 4.3 What the firmware currently intends to boot

```console
$ sudo efibootmgr -v
BootCurrent: 0005
Timeout: 2 seconds
BootOrder: 0005,0006,0002,0001,0003
Boot0001  UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0002* UEFI Shell	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(7c04a583-9e3e-4f1c-ad65-e05268d0b4d1)
Boot0003* UEFI PXEv4 (MAC:52540012A4E7)	PciRoot(0x0)/Pci(0x3,0x0)/MAC(52540012a4e7,1)/IPv4(0.0.0.00.0.0.0,0,0)
Boot0005* debian	HD(2,GPT,9f4a1c2e-6b30-4a51-9c88-1d2e3f4a5b6c,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)
Boot0006* debian-mirror	HD(2,GPT,c7d8e9f0-1a2b-3c4d-5e6f-708192a3b4c5,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)
```

Read this carefully — it encodes the *entire* UEFI boot policy:

- `BootCurrent: 0005` — the entry the firmware actually used this boot.
- `BootOrder` — the try-in-sequence list. `0006` (the mirror ESP on `/dev/sdb2`) is second: if `/dev/sda` dies, the firmware falls through to it automatically. **That is the "backup boot option" the objective asks for, implemented in NVRAM.**
- The `HD(2,GPT,<uuid>,...)` device path references the **partition GUID**, not `/dev/sdX`. Cloning a disk with `dd` duplicates the GUID and produces two devices the firmware cannot distinguish — always `sgdisk -G` a clone.
- `Boot0003` PXE last: a network rescue path when both disks fail.

### 4.4 Which loader is actually installed

```console
$ grub-install --version
grub-install (GRUB) 2.06-13+deb12u1

$ sudo dd if=/dev/sda bs=512 count=1 status=none | strings | head -5
ZRr=
`|f
\|f1
GRUB
Geom

$ sudo grub-probe --target=device /boot
/dev/sda3
$ sudo grub-probe --target=fs /boot
ext2
$ sudo grub-probe --target=partmap /boot
gpt
$ sudo grub-probe --target=abstraction /
lvm
```

`grub-probe` is the introspection engine `grub-install` and `grub-mkconfig` use internally. `--target=abstraction` telling you `lvm` means `core.img` **must** contain the `lvm` module or the system will not boot.

---

## 5. GRUB 2 — configuration and installation

### 5.1 The generation pipeline

```
/etc/default/grub        (shell-sourced key=value — the knobs you turn)
        +
/etc/grub.d/*            (executable scripts, run in lexical order)
        │  00_header     ← timeout, default, gfx, serial, grubenv loading
        │  05_debian_theme
        │  10_linux      ← scans /boot for vmlinuz-* and initrd*, emits menuentries
        │  20_linux_xen
        │  30_os-prober  ← scans other partitions for foreign OSes
        │  30_uefi-firmware ← "System setup" entry (fwsetup)
        │  40_custom     ← YOUR hand-written entries go here
        │  41_custom     ← sources /boot/grub/custom.cfg if present
        ▼
   grub-mkconfig  (Debian wrapper: update-grub · Red Hat: grub2-mkconfig)
        ▼
/boot/grub/grub.cfg      ← GENERATED. Never edit. Overwritten without warning.
```

The header of the generated file says so explicitly:

```console
$ head -6 /boot/grub/grub.cfg
#
# DO NOT EDIT THIS FILE
#
# It is automatically generated by grub-mkconfig using templates
# from /etc/grub.d and settings from /etc/default/grub
#
```

**The discipline:** every persistent change goes into `/etc/default/grub` or `/etc/grub.d/40_custom`, both of which are version-controllable and idempotent. `grub.cfg` is build output, exactly like a compiled binary.

### 5.2 A complete, production-annotated `/etc/default/grub`

```bash
# /etc/default/grub — managed by Ansible role: platform.bootloader
# Regenerate with: update-grub  (Debian) | grub2-mkconfig -o /boot/grub2/grub.cfg (RHEL)

# --- Selection ------------------------------------------------------------
# 'saved' makes GRUB read saved_entry from /boot/grub/grubenv, which is what
# grub-reboot / grub-set-default write. This is the prerequisite for the
# one-shot-kernel-test pattern (section 8.3).
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false          # do NOT auto-persist the last manual choice:
                                # it silently pins a node to an old kernel.
                                # Also incompatible with /boot on mdraid/LVM
                                # ("error: diskfilter writes are not supported").

# --- Timing ---------------------------------------------------------------
GRUB_TIMEOUT=5                  # servers: never 0. 5s is the cost of being able
                                # to intervene on a console during an incident.
GRUB_TIMEOUT_STYLE=menu         # menu | countdown | hidden
GRUB_RECORDFAIL_TIMEOUT=30      # Debian/Ubuntu: timeout used after a failed boot,
                                # so a headless box does not hang forever.

# --- Identity -------------------------------------------------------------
GRUB_DISTRIBUTOR="$(lsb_release -i -s 2>/dev/null || echo Debian)"

# --- Kernel command line --------------------------------------------------
# GRUB_CMDLINE_LINUX          -> applied to ALL entries, including recovery
# GRUB_CMDLINE_LINUX_DEFAULT  -> applied to normal entries only
#
# Never put root= here. It is derived by grub-mkconfig from the running
# system via grub-probe and is emitted per-entry with a UUID.
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 systemd.show_status=auto \
audit=1 slub_debug=- transparent_hugepage=madvise \
crashkernel=512M-2G:64M,2G-:256M"

# Ordering note: the LAST console= wins as /dev/console for userspace.
# ttyS0 last => systemd's console output goes to serial => OOB debuggable.

# --- Console --------------------------------------------------------------
GRUB_TERMINAL="console serial"  # render the menu on BOTH VGA and serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"

# --- Modules that must be inside core.img ---------------------------------
# If /boot (or the prefix path) lives on these abstractions, core.img cannot
# read grub.cfg without them. grub-install usually infers this via grub-probe;
# declaring it explicitly makes the requirement auditable.
GRUB_PRELOAD_MODULES="part_gpt part_msdos lvm mdraid1x ext2"

# --- Menu shape -----------------------------------------------------------
GRUB_DISABLE_SUBMENU=y          # flatten "Advanced options >" so that every
                                # kernel is a top-level entry. Required for
                                # GRUB_DEFAULT to be addressable by index and
                                # for serial navigation to stay sane.
GRUB_DISABLE_RECOVERY=false     # keep the single-user entries. On a server the
                                # recovery entry is the cheapest rollback there is.
GRUB_DISABLE_OS_PROBER=true     # servers: do not scan other partitions. On a
                                # SAN/iSCSI host os-prober can mount foreign
                                # filesystems and hang grub-mkconfig for minutes.

# --- Graphics -------------------------------------------------------------
GRUB_GFXMODE=1024x768x32
GRUB_GFXPAYLOAD_LINUX=keep

# --- Red Hat family only --------------------------------------------------
# GRUB_ENABLE_BLSCFG=true       # emit BootLoaderSpec entries into
                                # /boot/loader/entries/*.conf instead of
                                # inlining menuentries into grub.cfg
```

Regenerate and observe:

```console
$ sudo update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
Found linux image: /boot/vmlinuz-6.1.0-17-amd64
Found initrd image: /boot/initrd.img-6.1.0-17-amd64
Warning: os-prober will not be executed to detect other bootable partitions.
Systems on them will not be added to the GRUB boot configuration.
Check GRUB_DISABLE_OS_PROBER documentation entry.
done
```

`update-grub` is a two-line Debian shell wrapper. The portable, exam-correct invocation is:

```console
$ sudo grub-mkconfig -o /boot/grub/grub.cfg          # Debian/SUSE/Arch
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg        # RHEL/Fedora/CentOS
```

> **Red Hat path caveat.** On RHEL 8 and earlier, a UEFI system's config lived at `/boot/efi/EFI/redhat/grub.cfg` and the BIOS one at `/boot/grub2/grub.cfg`. RHEL 9 / Fedora 34+ unified both on `/boot/grub2/grub.cfg`, leaving a small stub in the ESP that chains to it. Always confirm with `readlink -f /etc/grub2.cfg` and `readlink -f /etc/grub2-efi.cfg` rather than assuming.

```console
$ readlink -f /etc/grub2.cfg
/boot/grub2/grub.cfg
$ readlink -f /etc/grub2-efi.cfg
/boot/efi/EFI/redhat/grub.cfg
```

### 5.3 Reading a generated `menuentry`

```bash
menuentry 'Debian GNU/Linux, with Linux 6.1.0-18-amd64' --class debian \
          --class gnu-linux --class gnu --class os \
          $menuentry_id_option 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...' {
	load_video
	insmod gzio
	if [ x$grub_platform = xxen ]; then insmod xzio; insmod lzopio; fi
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
	echo	'Loading Linux 6.1.0-18-amd64 ...'
	linux	/vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro \
		console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 \
		quiet loglevel=3 crashkernel=512M-2G:64M,2G-:256M
	echo	'Loading initial ramdisk ...'
	initrd	/initrd.img-6.1.0-18-amd64
}
```

Line-by-line, the four things that matter operationally:

| Line | Meaning | Failure if wrong |
|---|---|---|
| `insmod part_gpt` / `insmod ext2` | load the modules needed to read `/boot` | `error: unknown filesystem` |
| `search --fs-uuid --set=root <uuid>` | locate the **`/boot` filesystem** by UUID and bind it to `$root`. Device-name-independent. | `error: no such partition` → rescue |
| `linux /vmlinuz-… root=UUID=…` | path is **relative to `$root`**. If `/boot` is a separate partition, the path has no `/boot` prefix. `root=` is the **kernel's** root, a different thing entirely. | wrong path → `error: file not found`; wrong `root=` → initramfs emergency shell |
| `initrd /initrd.img-…` | must match the kernel version exactly | mismatch → kernel panic, `VFS: Unable to mount root fs` |

> **The two `root`s.** `$root` (a GRUB variable) = where GRUB reads files from. `root=` (a kernel parameter) = where the kernel mounts `/`. They are frequently different partitions. Conflating them is the classic mis-edit at a `grub>` prompt.

### 5.4 Adding a permanent custom entry — `/etc/grub.d/40_custom`

```bash
#!/bin/sh
exec tail -n +3 $0
# Everything below this line is copied verbatim into grub.cfg.
# File must be chmod 0755 or grub-mkconfig silently ignores it.

# ---------------------------------------------------------------------------
# Pinned known-good kernel. Survives kernel package removal only if the files
# are protected; see /etc/apt/apt.conf.d/01autoremove-kernels.
# ---------------------------------------------------------------------------
menuentry 'RESCUE: known-good 6.1.0-17 (single user)' --id rescue-known-good {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
	echo 'Loading known-good kernel 6.1.0-17 ...'
	linux /vmlinuz-6.1.0-17-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro \
	      console=ttyS0,115200n8 systemd.unit=rescue.target nomodeset
	initrd /initrd.img-6.1.0-17-amd64
}

# ---------------------------------------------------------------------------
# Chainload the mirror disk's boot sector (BIOS) — "alternative boot location"
# ---------------------------------------------------------------------------
menuentry 'RECOVERY: chainload second disk (hd1)' --id chain-hd1 {
	insmod chain
	insmod part_gpt
	set root=(hd1)
	chainloader +1
}

# ---------------------------------------------------------------------------
# Chainload the mirror ESP (UEFI)
# ---------------------------------------------------------------------------
menuentry 'RECOVERY: mirror ESP on /dev/sdb2' --id chain-esp2 {
	insmod chain
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root A1B2-C3D4
	chainloader /EFI/debian/shimx64.efi
}

# ---------------------------------------------------------------------------
# Memory test and firmware setup — diagnostics without external media
# ---------------------------------------------------------------------------
menuentry 'DIAG: UEFI firmware setup' --id fwsetup {
	fwsetup
}

menuentry 'DIAG: iPXE network rescue' --id ipxe {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root A1B2-C3D4
	chainloader /EFI/ipxe/ipxe.efi
}
```

```console
$ sudo chmod 0755 /etc/grub.d/40_custom
$ sudo update-grub && grep -c '^menuentry' /boot/grub/grub.cfg
Generating grub configuration file ...
done
6
```

### 5.5 Installing GRUB 2 — BIOS target

```console
$ sudo grub-install --target=i386-pc --recheck --boot-directory=/boot /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
```

| Flag | Effect | When to use |
|---|---|---|
| `--target=i386-pc` | BIOS/legacy | always state it explicitly in automation; never rely on autodetect |
| `--recheck` | rebuild `/boot/grub/device.map` before installing | after adding/removing/reordering disks |
| `--boot-directory=DIR` | where `grub/` lives (default `/boot`) | rescue chroots, alternate `/boot` |
| `--root-directory=DIR` | legacy alias, implies `DIR/boot` | rescue from live media |
| `--modules="lvm mdraid1x"` | force these into `core.img` | when `grub-probe` under-detects |
| `--force` | install to a **partition** boot sector, using blocklists | almost never — fragile, breaks on any `/boot` write |
| `--no-nvram` | UEFI: skip writing NVRAM variables | golden images, chroots, cloud templates |
| `--removable` | UEFI: write `\EFI\BOOT\BOOTX64.EFI` | USB media, firmware that ignores NVRAM |

**Write the target device, not a partition.** `grub-install /dev/sda` installs `boot.img` into the MBR. `grub-install /dev/sda1` requires `--force`, uses blocklists, and will break the next time `/boot` is written to.

Verify the artefacts:

```console
$ ls /boot/grub/i386-pc/ | head -8
acpi.mod
adler32.mod
affs.mod
afs.mod
ahci.mod
all_video.mod
biosdisk.mod
boot.img

$ ls -l /boot/grub/i386-pc/core.img
-rw-r--r-- 1 root root 30720 Aug 25 09:41 /boot/grub/i386-pc/core.img

$ cat /boot/grub/device.map
(hd0)	/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A
(hd1)	/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B
```

> `device.map` maps GRUB's `(hdN)` names to Linux devices. Use `/dev/disk/by-id/` paths — kernel `sdX` names are not stable across reboots, and a `device.map` that points at the wrong disk produces a `core.img` that reads the wrong `/boot`.

### 5.6 Installing GRUB 2 — UEFI target

```console
$ sudo grub-install --target=x86_64-efi \
                    --efi-directory=/boot/efi \
                    --bootloader-id=debian \
                    --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

$ sudo find /boot/efi -type f | sort
/boot/efi/EFI/BOOT/BOOTX64.EFI
/boot/efi/EFI/BOOT/fbx64.efi
/boot/efi/EFI/debian/BOOTX64.CSV
/boot/efi/EFI/debian/fbx64.efi
/boot/efi/EFI/debian/grub.cfg
/boot/efi/EFI/debian/grubx64.efi
/boot/efi/EFI/debian/mmx64.efi
/boot/efi/EFI/debian/shimx64.efi
```

The ESP stub that chains to the real config:

```console
$ cat /boot/efi/EFI/debian/grub.cfg
search.fs_uuid 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10 root hd0,gpt3 
set prefix=($root)'/grub'
configfile $prefix/grub.cfg
```

`grub-install` also wrote NVRAM. Confirm and set an order:

```console
$ sudo efibootmgr -v | grep -i debian
Boot0005* debian	HD(2,GPT,9f4a1c2e-...,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)

$ sudo efibootmgr -o 0005,0006,0003
BootOrder: 0005,0006,0003
```

Creating an NVRAM entry by hand (when `grub-install --no-nvram` was used, or the firmware dropped it):

```console
$ sudo efibootmgr --create \
                  --disk /dev/sda --part 2 \
                  --label "debian" \
                  --loader '\EFI\debian\shimx64.efi' \
                  --verbose
```

| `efibootmgr` operation | Command |
|---|---|
| list entries verbosely | `efibootmgr -v` |
| create an entry | `efibootmgr -c -d /dev/sda -p 2 -L "debian" -l '\EFI\debian\shimx64.efi'` |
| set the persistent order | `efibootmgr -o 0005,0006,0003` |
| **boot once from a different entry** | `efibootmgr -n 0006` (`BootNext`) |
| cancel the one-shot | `efibootmgr -N` |
| delete an entry | `efibootmgr -b 0006 -B` |
| deactivate without deleting | `efibootmgr -b 0006 -A` |
| set firmware timeout | `efibootmgr -t 2` |

`BootNext` is the UEFI-level equivalent of `grub-reboot`: **a one-shot that self-clears**, so a failed test reverts to `BootOrder` automatically. It is the correct primitive for validating a new loader remotely.

**Red Hat + UEFI:** do **not** run `grub2-install` on a UEFI system. The signed binaries come from packages, and running the installer can overwrite a shim-signed chain with an unsigned one, breaking Secure Boot. The supported repair is:

```console
$ sudo dnf reinstall grub2-efi-x64 grub2-efi-x64-modules shim-x64
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

### 5.7 Secure Boot: the chain and its verification

```
UEFI db (Microsoft UEFI CA)
   └─ verifies shimx64.efi          ← Microsoft-signed, distro-supplied
        └─ shim's embedded vendor cert (or MOK db)
             └─ verifies grubx64.efi     ← distro-signed
                  └─ GRUB calls shim_lock verifier
                       └─ verifies vmlinuz  ← distro-signed
                            └─ kernel enters "lockdown: integrity" mode
```

```console
$ mokutil --sb-state
SecureBoot enabled

$ sudo dmesg | grep -i -E 'secure boot|lockdown'
[    0.000000] secureboot: Secure boot enabled
[    0.000000] Kernel is locked down from EFI Secure Boot mode; see man kernel_lockdown.7

$ mokutil --list-enrolled | head -12
[key 1]
SHA1 Fingerprint: 34:2a:...
Certificate:
    Data:
        Version: 3 (0x2)
        Serial Number: ...
        Issuer: CN = Debian Secure Boot CA
```

Operational consequences on a locked-down node — these surprise SREs, not students:
- unsigned out-of-tree modules (DKMS: NVIDIA, VirtualBox, ZFS) fail to load until signed and the key enrolled via `mokutil --import`;
- `/dev/mem`, `kexec` with an unsigned image, and hibernation to swap are blocked;
- `GRUB_CMDLINE_LINUX` additions are still honoured — the command line is **not** measured by shim, which is precisely why Secure Boot alone is not attestation. Use TPM 2.0 measured boot (`systemd-pcrphase`, PCR 8/9) if you need the command line covered.

---

## 6. GRUB Legacy — install and configure

You will meet GRUB Legacy on RHEL/CentOS 6, on embedded appliances, and in the exam. Its virtue is that it is a static file you can read and repair with `vi`.

### 6.1 Complete annotated `menu.lst` / `grub.conf`

```bash
# /boot/grub/grub.conf   (Red Hat; /boot/grub/menu.lst is a symlink to it)
# NOTICE: You do not have a /boot partition. This means that all kernel and
#         initrd paths are relative to /, e.g.  root (hd0,0)  /boot/vmlinuz-...

default=0                 # index of the entry to boot, counting from 0
fallback=1                # if entry 0 fails to load, try entry 1
timeout=5                 # seconds; 0 = boot immediately, -1 = wait forever
hiddenmenu                # suppress the menu unless a key is pressed
splashimage=(hd0,0)/boot/grub/splash.xpm.gz
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal --timeout=10 serial console
password --md5 $1$Kf9dQ1$8Zx6vQpLm3nR7sT2yU4wB.

title CentOS (2.6.32-754.35.1.el6.x86_64)
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-754.35.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c \
	       rd_NO_LUKS rd_NO_DM LANG=en_US.UTF-8 \
	       console=tty0 console=ttyS0,115200n8 crashkernel=auto
	initrd /boot/initramfs-2.6.32-754.35.1.el6.x86_64.img
	savedefault

title CentOS (2.6.32-696.30.1.el6.x86_64)  [KNOWN GOOD]
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-696.30.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c \
	       console=ttyS0,115200n8
	initrd /boot/initramfs-2.6.32-696.30.1.el6.x86_64.img

title CentOS single-user (rescue)
	lock                      # requires the password above
	root (hd0,0)
	kernel /boot/vmlinuz-2.6.32-754.35.1.el6.x86_64 ro \
	       root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c single
	initrd /boot/initramfs-2.6.32-754.35.1.el6.x86_64.img

title Windows Server 2008 R2 (second disk)
	rootnoverify (hd1,0)      # do NOT try to read the filesystem
	map (hd0) (hd1)           # lie to Windows: make it think it is the 1st disk
	map (hd1) (hd0)
	chainloader +1            # load 1 sector from the partition boot record

title Boot from mirror disk (hd1) — RECOVERY
	root (hd1,0)
	chainloader +1
	makeactive
```

### 6.2 GRUB Legacy directive reference

| Directive | Scope | Meaning |
|---|---|---|
| `default N` / `default saved` | global | entry index (from **0**), or the value stored by `savedefault` |
| `fallback N` | global | entry to try if the default fails to *load* |
| `timeout N` | global | seconds before auto-boot; `-1` waits indefinitely |
| `hiddenmenu` | global | hide the menu; any keypress reveals it |
| `password --md5 <hash>` | global | lock the interactive editor and `lock`ed entries |
| `serial` / `terminal` | global | serial console configuration |
| `title <text>` | entry | starts a new entry; free-form text |
| `root (hdD,P)` | entry | set the boot device **and probe its filesystem** |
| `rootnoverify (hdD,P)` | entry | set it **without** probing — for filesystems GRUB cannot read |
| `kernel <path> <args>` | entry | load kernel; path relative to `root` |
| `initrd <path>` | entry | load initrd |
| `chainloader +1` | entry | load the first sector of `root` and jump to it |
| `makeactive` | entry | set the DOS "active" flag on the partition |
| `map (hdX) (hdY)` | entry | swap BIOS drive numbers (needed by Windows) |
| `savedefault` | entry | write this entry's index as the new `saved` default |
| `lock` | entry | require the global password before booting this entry |

Generate the MD5 password hash:

```console
$ grub-md5-crypt
Password:
Retype password:
$1$Kf9dQ1$8Zx6vQpLm3nR7sT2yU4wB.
```

### 6.3 Installing GRUB Legacy

Two equivalent routes. The non-interactive one:

```console
# grub-install --root-directory=/ /dev/sda
Installation finished. No error reported.
This is the contents of the device map /boot/grub/device.map.
Check if this is correct or not. If any of the lines is incorrect,
fix it and re-run the script `grub-install'.

(fd0)	/dev/fd0
(hd0)	/dev/sda
(hd1)	/dev/sdb
```

And the interactive GRUB shell, which is what the exam expects you to recognise — and what you use from rescue media when `grub-install` misdetects the geometry:

```console
# grub
    GNU GRUB  version 0.97  (640K lower / 3072K upper memory)

 [ Minimal BASH-like line editing is supported.  For the first word, TAB
   lists possible command completions.  Anywhere else TAB lists the possible
   completions of a device/filename. ]

grub> find /boot/grub/stage1
 (hd0,0)
 (hd1,0)

grub> root (hd0,0)
 Filesystem type is ext2fs, partition type 0x83

grub> setup (hd0)
 Checking if "/boot/grub/stage1" exists... yes
 Checking if "/boot/grub/stage2" exists... yes
 Checking if "/boot/grub/e2fs_stage1_5" exists... yes
 Running "embed /boot/grub/e2fs_stage1_5 (hd0)"...  27 sectors are embedded.
succeeded
 Running "install /boot/grub/stage1 (hd0) (hd0)1+27 p (hd0,0)/boot/grub/stage2 /boot/grub/menu.lst"... succeeded
Done.

grub> root (hd1,0)
 Filesystem type is ext2fs, partition type 0x83

grub> setup (hd1)
 Checking if "/boot/grub/stage1" exists... yes
 ...
Done.

grub> quit
```

Read the semantics precisely, because they are exam-critical:

- `root (hd0,0)` — the partition where `/boot/grub/` **lives** (source of stage2).
- `setup (hd0)` — the device whose **boot sector receives stage1** (destination).
- `setup (hd0)` writes to the **MBR**; `setup (hd0,0)` writes to that **partition's** boot record.
- Running `setup (hd1)` after `root (hd1,0)` is exactly how you mirror the bootstrap to the second disk. Do it in the same maintenance window as building the RAID array, or you have a half-redundant system.

---

## 7. Interacting with the boot loader

### 7.1 GRUB 2 menu — interactive keys

| Key | Effect |
|---|---|
| `↑` `↓` | move selection (pauses the countdown) |
| `e` | **edit the selected entry** — temporary, in memory, lost on reboot |
| `c` | drop to the full `grub>` command shell |
| `Ctrl-x` or `F10` | boot the edited entry |
| `Ctrl-c` | from the editor, go to the command shell |
| `Esc` | discard edits, return to the menu |
| `Ctrl-a` / `Ctrl-e` | start / end of line (emacs bindings in the editor) |
| `Ctrl-k` / `Ctrl-y` | kill to end of line / yank |

The single most valuable operational skill in this objective: press `e`, navigate to the `linux` line, append a parameter, press `Ctrl-x`.

### 7.2 The kernel parameters worth memorising

| Parameter | Effect | Use case |
|---|---|---|
| `systemd.unit=rescue.target` (or `1`, `s`, `single`) | single-user, root filesystem mounted rw, root password required | routine recovery |
| `systemd.unit=emergency.target` (or `emergency`) | minimal shell, `/` read-only, **no** other units | broken `/etc/fstab` |
| `init=/bin/bash` | replace PID 1 entirely — no systemd, no password prompt | **root password reset**; remount with `mount -o remount,rw /` |
| `rd.break` (dracut) / `break=premount` (initramfs-tools) | shell **inside the initramfs**, before `switch_root` | LUKS/LVM/root-mount debugging |
| `rd.shell rd.debug` | verbose initramfs with a shell on failure | "cannot find root device" |
| `systemd.debug-shell=1` | root shell on tty9 during boot | hangs mid-boot |
| `nomodeset` | disable kernel mode setting | black screen after GRUB |
| `console=ttyS0,115200n8` | direct kernel output to serial | headless / OOB |
| `selinux=0` or `enforcing=0` | disable / permissive SELinux | mislabeled filesystem after restore |
| `systemd.mask=<unit>` | mask a unit for this boot only | a service that hangs boot |
| `ro` / `rw` | mount root read-only / read-write | pairs with `init=/bin/bash` |
| `panic=30` | reboot 30 s after a panic | **fleet default** — turns a hang into a retry |
| `mem=4G`, `maxcpus=1` | constrain resources | hardware bisection |

> **Security note that follows directly:** `init=/bin/bash` at the GRUB prompt is a complete authentication bypass for anyone with console access. Physical/OOB console access **is** root access unless you set a GRUB password *and* full-disk encryption. Section 7.5.

### 7.3 The `grub>` full shell

Reached with `c`, or when `grub.cfg` is missing but `core.img` loaded correctly.

```
grub> ls
(hd0) (hd0,gpt4) (hd0,gpt3) (hd0,gpt2) (hd0,gpt1) (hd1) (hd1,gpt4) (hd1,gpt3) (hd1,gpt2) (hd1,gpt1)

grub> ls (hd0,gpt3)/
lost+found/ vmlinuz-6.1.0-18-amd64 initrd.img-6.1.0-18-amd64 vmlinuz-6.1.0-17-amd64 initrd.img-6.1.0-17-amd64 config-6.1.0-18-amd64 System.map-6.1.0-18-amd64 grub/ efi/

grub> ls -l (hd0,gpt3)
Partition hd0,gpt3: Filesystem type ext* — Last modification time 2026-08-25 09:41:12 Tuesday, UUID 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10 - Partition start at 526336KiB - Total size 1048576KiB

grub> set
prefix=(hd0,gpt3)/grub
root=hd0,gpt3
cmdpath=(hd0,gpt2)/EFI/debian

grub> search --no-floppy --fs-uuid --set=root 8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10

grub> linux /vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro console=ttyS0,115200n8

grub> initrd /initrd.img-6.1.0-18-amd64

grub> boot
```

Essential shell commands:

| Command | Purpose |
|---|---|
| `ls` | list devices; `ls (hdX,Y)/` lists files; `ls -l (hdX,Y)` shows fs type and UUID |
| `set` / `set var=value` | show / set variables (`root`, `prefix`) |
| `search --fs-uuid --set=root <uuid>` | find a filesystem by UUID and bind it |
| `search --file --set=root /vmlinuz-6.1.0-18-amd64` | find by the presence of a file |
| `insmod <module>` | load a GRUB module (`ext2`, `lvm`, `part_gpt`, `normal`) |
| `linux` / `initrd` | stage the kernel and initrd |
| `configfile (hdX,Y)/grub/grub.cfg` | load a config file and show its menu |
| `chainloader +1` / `chainloader /EFI/…/x.efi` | hand off to another loader |
| `cat (hdX,Y)/etc/fstab` | read a text file — invaluable for finding UUIDs |
| `lsmod` | list loaded GRUB modules |
| `normal` | leave rescue mode and enter the normal menu |
| `boot` | execute the staged kernel |
| `halt` / `reboot` | power off / reset |

### 7.4 `grub rescue>` — the minimal prompt

`grub rescue>` means **`core.img` ran but could not find its `prefix`** — i.e. `/boot/grub` is missing, moved, or on an unreadable filesystem. Only `ls`, `set`, `unset`, `insmod` and `normal` exist.

```
error: file '/boot/grub/i386-pc/normal.mod' not found.
Entering rescue mode...
grub rescue> ls
(hd0) (hd0,msdos1) (hd0,msdos5)

grub rescue> ls (hd0,msdos1)/
lost+found/ boot/ etc/ bin/ sbin/ usr/ var/ home/

grub rescue> set prefix=(hd0,msdos1)/boot/grub
grub rescue> set root=(hd0,msdos1)
grub rescue> insmod normal
grub rescue> normal
```

You are now at a normal GRUB menu — **in memory only**. Boot the system, then make it permanent:

```console
$ sudo grub-install /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
$ sudo update-grub
```

### 7.5 Hardening the interactive path

```bash
$ grub-mkpasswd-pbkdf2
Enter password:
Reenter password:
PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1
```

`/etc/grub.d/01_password` (mode `0755`):

```bash
#!/bin/sh
exec tail -n +3 $0
# Superuser 'gadmin' may edit entries and use the GRUB shell.
set superusers="gadmin"
password_pbkdf2 gadmin grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1
```

Then mark the ordinary entries `--unrestricted` so an unattended reboot still works:

```bash
menuentry 'Debian GNU/Linux' --unrestricted --id normal { ... }
menuentry 'RESCUE: single user' --users gadmin --id rescue { ... }
```

| Setting | Result |
|---|---|
| `set superusers` only | **every** entry requires authentication — a reboot needs a human. Wrong for servers. |
| `--unrestricted` on normal entries | boot freely; editing (`e`) and the shell (`c`) require the password. **Correct for servers.** |
| `--users gadmin` on rescue entries | only that user may select them |

`grub.cfg` mode 0600 prevents hash disclosure, but the hash also lands in `/etc/grub.d/01_password` — protect both:

```console
$ sudo chmod 0600 /boot/grub/grub.cfg /etc/grub.d/01_password
```

**A GRUB password protects the boot loader, not the data.** An attacker with the disk boots their own media and reads it. The full control set is: GRUB password + firmware/BIOS password + boot order locked to internal disk + **LUKS full-disk encryption** + Secure Boot + TPM-sealed keys. Anything less is a speed bump.

---

## 8. Alternative boot locations and backup boot options

This is the objective bullet that maps directly to SRE practice.

### 8.1 Mirroring the bootstrap across disks (BIOS + mdraid)

The array survives a disk failure; the MBR must be told to.

```console
$ sudo grub-install --target=i386-pc --recheck /dev/sda
Installing for i386-pc platform.
Installation finished. No error reported.
$ sudo grub-install --target=i386-pc --recheck /dev/sdb
Installing for i386-pc platform.
Installation finished. No error reported.
```

On Debian, make this survive package upgrades by recording both devices in debconf — otherwise the next `grub-pc` upgrade re-installs to only one:

```console
$ echo 'grub-pc grub-pc/install_devices multiselect \
  /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A, \
  /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B' \
  | sudo debconf-set-selections
$ sudo dpkg-reconfigure -f noninteractive grub-pc
```

Verify both MBRs carry a bootstrap:

```console
$ for d in /dev/sda /dev/sdb; do
>   printf '%s: ' "$d"
>   sudo dd if="$d" bs=512 count=1 status=none | strings | grep -q GRUB \
>     && echo "GRUB present" || echo "NO BOOTSTRAP"
> done
/dev/sda: GRUB present
/dev/sdb: GRUB present
```

### 8.2 Mirroring the ESP (UEFI)

The ESP is FAT32 and firmware reads it directly, so it cannot be a normal mdraid member. Two workable strategies:

| Strategy | How | Trade-off |
|---|---|---|
| **Two independent ESPs + sync** | separate `EF00` partitions; `grub-install --efi-directory` to each; `rsync` on a systemd path/timer unit | simple, transparent, firmware-agnostic. Requires an explicit sync step. **Recommended.** |
| **mdraid metadata 1.0 RAID1** | superblock at the **end** of the device, so firmware sees a plain FAT32 at offset 0 | firmware may write to one member out of band and silently desync the mirror; `fsck.vfat` on a degraded array can corrupt both |

Independent-ESP procedure:

```console
$ sudo mkdir -p /boot/efi2
$ sudo mkfs.vfat -F32 -n ESP2 /dev/sdb2
mkfs.fat 4.2 (2021-01-31)

$ sudo blkid /dev/sdb2
/dev/sdb2: LABEL_FATBOOT="ESP2" LABEL="ESP2" UUID="A1B2-C3D4" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System Partition" PARTUUID="c7d8e9f0-..."

$ echo 'UUID=A1B2-C3D4  /boot/efi2  vfat  umask=0077,noauto  0 0' | sudo tee -a /etc/fstab
$ sudo mount /boot/efi2

$ sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
                    --bootloader-id=debian-mirror --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

$ sudo efibootmgr -v | grep -i mirror
Boot0006* debian-mirror	HD(2,GPT,c7d8e9f0-...,0x800,0x100000)/File(\EFI\DEBIAN-MIRROR\SHIMX64.EFI)

$ sudo efibootmgr -o 0005,0006,0003
BootOrder: 0005,0006,0003
```

Keep them in sync automatically:

```ini
# /etc/systemd/system/esp-sync.service
[Unit]
Description=Synchronise the backup EFI System Partition
Documentation=man:grub-install(8)
RequiresMountsFor=/boot/efi

[Service]
Type=oneshot
ExecStartPre=/usr/bin/mountpoint -q /boot/efi2 || /usr/bin/mount /boot/efi2
ExecStart=/usr/bin/rsync -a --delete --exclude 'EFI/debian-mirror/' /boot/efi/ /boot/efi2/
ExecStartPost=/usr/bin/umount /boot/efi2
```

```ini
# /etc/systemd/system/esp-sync.path
[Unit]
Description=Watch the primary ESP for changes

[Path]
PathChanged=/boot/efi/EFI
Unit=esp-sync.service

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl enable --now esp-sync.path
Created symlink /etc/systemd/system/multi-user.target.wants/esp-sync.path → /etc/systemd/system/esp-sync.path.
```

### 8.3 One-shot boot: test a kernel without betting the node

The single most valuable backup-boot technique. `GRUB_DEFAULT=saved` must be set (section 5.2).

```console
$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-...
boot_success=1

$ sudo grub-reboot 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...'

$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-...
next_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
boot_success=1

$ sudo systemctl reboot
```

`next_entry` is consumed and cleared by GRUB at boot. If the new kernel panics and the watchdog (`panic=30`) resets the box, the **next** boot uses `saved_entry` — the known-good kernel. Zero human intervention.

Compare the three persistence primitives:

| Command | Writes | Persistence | Use |
|---|---|---|---|
| `grub-reboot <entry>` | `next_entry` in `grubenv` | **one boot** | test a kernel, validate a new loader |
| `grub-set-default <entry>` | `saved_entry` in `grubenv` | permanent | promote a kernel after validation |
| `efibootmgr -n <hex>` | `BootNext` NVRAM | **one boot** | test a whole loader / another disk |
| `efibootmgr -o <list>` | `BootOrder` NVRAM | permanent | promote a loader |

Promote after a successful soak:

```console
$ sudo grub-set-default 'gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...'
$ sudo grub-editenv list | grep saved_entry
saved_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
```

Entry IDs come from `--id` or `$menuentry_id_option`. Enumerate them reliably:

```console
$ awk -F"'" '/^menuentry |^submenu /{print NR": "$2" ==> "$4}' /boot/grub/grub.cfg
6: Debian GNU/Linux ==> gnulinux-simple-c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c
17: Debian GNU/Linux, with Linux 6.1.0-18-amd64 ==> gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
33: Debian GNU/Linux, with Linux 6.1.0-17-amd64 ==> gnulinux-6.1.0-17-amd64-advanced-8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
49: RESCUE: known-good 6.1.0-17 (single user) ==> rescue-known-good
57: RECOVERY: chainload second disk (hd1) ==> chain-hd1
```

### 8.4 Automatic rollback: boot counting in `grubenv`

Turn "one-shot test" into "self-healing fleet". Add `/etc/grub.d/09_boot_counting` (mode `0755`):

```bash
#!/bin/sh
exec tail -n +3 $0
# Boot-attempt counting with automatic rollback.
# Requires: grub-boot-success.service (below) writing boot_success=1 after a
# successful multi-user boot, and GRUB_DEFAULT=saved.

if [ -s "${prefix}/grubenv" ]; then
  load_env
fi

# Normalise on first ever boot.
if [ -z "${boot_attempts}" ]; then set boot_attempts=0; fi

if [ "${boot_success}" = "1" ]; then
    # Previous boot reached multi-user.target: reset the counter.
    set boot_attempts=0
else
    # Previous boot did not confirm success: count this attempt.
    set boot_attempts=$((boot_attempts + 1))
fi

# Clear the flag; userspace must set it again to prove this boot worked.
set boot_success=0
save_env boot_success boot_attempts

if [ "${boot_attempts}" -ge 3 ]; then
    echo "*** ${boot_attempts} failed boot attempts — falling back to the known-good entry ***"
    sleep 5
    set default="rescue-known-good"
    set timeout=30
    set timeout_style=menu
fi
```

The userspace half:

```ini
# /etc/systemd/system/grub-boot-success.service
[Unit]
Description=Mark this boot as successful in the GRUB environment block
Documentation=man:grub-editenv(1)
After=multi-user.target network-online.target
Requires=multi-user.target
ConditionPathExists=/boot/grub/grubenv

[Service]
Type=oneshot
RemainAfterExit=yes
# Delay so that a node that crashes shortly after multi-user is NOT marked good.
ExecStartPre=/bin/sleep 120
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_success=1
ExecStart=/usr/bin/grub-editenv /boot/grub/grubenv set boot_attempts=0

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl enable --now grub-boot-success.service
$ sudo grub-editenv list
saved_entry=gnulinux-6.1.0-18-amd64-advanced-8f3c1a92-...
boot_success=1
boot_attempts=0
```

> **`grubenv` constraint.** It is a fixed **1024-byte** file that GRUB rewrites **in place** — it cannot grow, and GRUB cannot write to it through LVM, mdraid or Btrfs (`error: sparse file not allowed` / `error: diskfilter writes are not supported`). Boot counting therefore requires `/boot` on a **plain partition**. This is a strong architectural argument for keeping `/boot` simple.

### 8.5 Recovery media that lives outside the disk

```console
$ sudo grub-mkrescue -o /srv/images/grub-rescue-$(date +%F).iso /tmp/empty-root
xorriso 1.5.4 : RockRidge filesystem manipulator, libburnia project.
Drive current: -outdev 'stdio:/srv/images/grub-rescue-2026-08-25.iso'
...
ISO image produced: 25984 sectors
Written to medium : 25984 sectors at LBA 0
Writing to 'stdio:/srv/images/grub-rescue-2026-08-25.iso' completed successfully.

$ file /srv/images/grub-rescue-2026-08-25.iso
/srv/images/grub-rescue-2026-08-25.iso: ISO 9660 CD-ROM filesystem data 'GRUB2 rescue disk' (DOS/MBR boot sector) (bootable)
```

This ISO boots to a `grub>` prompt on both BIOS and UEFI. Mount it through your BMC's virtual media and you can `configfile (hd0,gpt3)/grub/grub.cfg` your way back into a system whose on-disk loader is destroyed — **without a datacenter visit**. Keep a current copy on every BMC-reachable share.

Network variant, for a rack-wide fallback:

```console
$ sudo grub-mknetdir --net-directory=/srv/tftp --subdir=/boot/grub
Netboot directory for i386-pc created. Configure your DHCP server to point to /boot/grub/i386-pc/core.0
Netboot directory for x86_64-efi created. Configure your DHCP server to point to /boot/grub/x86_64-efi/core.efi
```

### 8.6 The full backup-and-restore procedure for boot metadata

```bash
#!/usr/bin/env bash
# /usr/local/sbin/backup-boot-metadata — run before ANY bootloader change.
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="/var/backups/boot/${STAMP}"
mkdir -p "${DEST}"

for disk in /dev/sda /dev/sdb; do
    name="$(basename "${disk}")"
    # First 2048 sectors = MBR + post-MBR gap (core.img lives here on BIOS).
    dd if="${disk}" of="${DEST}/${name}.boot-area.bin" bs=512 count=2048 status=none
    # Partition table (GPT primary + backup, or MBR).
    sgdisk --backup="${DEST}/${name}.gpt" "${disk}" >/dev/null 2>&1 \
        || sfdisk --dump "${disk}" > "${DEST}/${name}.sfdisk"
done

# ESP contents.
[ -d /boot/efi ] && tar -C /boot/efi -czf "${DEST}/esp.tar.gz" .

# NVRAM boot entries (informational — restore is manual via efibootmgr).
command -v efibootmgr >/dev/null && efibootmgr -v > "${DEST}/efibootmgr.txt"

# Generated and source configuration.
tar -czf "${DEST}/grub-config.tar.gz" \
    /etc/default/grub /etc/grub.d /boot/grub/grub.cfg /boot/grub/grubenv \
    /boot/grub2/grub.cfg /boot/loader/entries 2>/dev/null || true

# Kernel inventory, so you know what "known good" meant.
{ uname -r; ls -l /boot/vmlinuz-* /boot/init*; } > "${DEST}/kernels.txt"

sha256sum "${DEST}"/* > "${DEST}/SHA256SUMS"
echo "Boot metadata saved to ${DEST}"
```

```console
$ sudo /usr/local/sbin/backup-boot-metadata
Boot metadata saved to /var/backups/boot/20260825T121804Z

$ sudo ls -lh /var/backups/boot/20260825T121804Z/
total 3.4M
-rw-r--r-- 1 root root  512 Aug 25 12:18 SHA256SUMS
-rw-r--r-- 1 root root  17K Aug 25 12:18 esp.tar.gz
-rw-r--r-- 1 root root 1.1K Aug 25 12:18 efibootmgr.txt
-rw-r--r-- 1 root root  38K Aug 25 12:18 grub-config.tar.gz
-rw-r--r-- 1 root root  892 Aug 25 12:18 kernels.txt
-rw-r--r-- 1 root root 1.0M Aug 25 12:18 sda.boot-area.bin
-rw-r--r-- 1 root root  17K Aug 25 12:18 sda.gpt
-rw-r--r-- 1 root root 1.0M Aug 25 12:18 sdb.boot-area.bin
-rw-r--r-- 1 root root  17K Aug 25 12:18 sdb.gpt
```

**Restoring the bootstrap only** (preserving the current partition table — the difference between recovery and data loss):

```console
# Restore ONLY the 446 bytes of bootstrap code. Bytes 446..511 hold the
# partition table and the signature: overwriting them destroys the layout.
$ sudo dd if=sda.boot-area.bin of=/dev/sda bs=446 count=1 conv=notrunc
1+0 records in
1+0 records out
446 bytes copied, 0.000371 s, 1.2 MB/s

# Then the post-MBR gap where core.img lives (sectors 1..2047).
$ sudo dd if=sda.boot-area.bin of=/dev/sda bs=512 skip=1 seek=1 count=2047 conv=notrunc
2047+0 records in
2047+0 records out
1048064 bytes (1.0 MB, 1023 KiB) copied, 0.00612 s, 171 MB/s
```

---

## 9. Infrastructure as code

### 9.1 Ansible role — idempotent, verified, dual-disk

```yaml
---
# roles/bootloader/defaults/main.yml
bootloader_timeout: 5
bootloader_default: saved
bootloader_console_args: "console=tty0 console=ttyS0,115200n8"
bootloader_extra_args: "net.ifnames=0 biosdevname=0 panic=30"
bootloader_default_args: "quiet loglevel=3 crashkernel=512M-2G:64M,2G-:256M"
bootloader_disable_os_prober: true
bootloader_preload_modules: "part_gpt part_msdos lvm mdraid1x ext2"
# Explicit list of disks whose MBR must carry the bootstrap (BIOS only).
bootloader_bios_devices: []
# Explicit list of {esp_device, mountpoint, bootloader_id} (UEFI only).
bootloader_esps: []
bootloader_reboot_after: false
```

```yaml
---
# roles/bootloader/vars/Debian.yml
bootloader_pkg_bios: [grub-pc, grub-common]
bootloader_pkg_efi: [grub-efi-amd64, grub-efi-amd64-signed, shim-signed, efibootmgr]
bootloader_mkconfig: /usr/sbin/grub-mkconfig
bootloader_install: /usr/sbin/grub-install
bootloader_cfg_bios: /boot/grub/grub.cfg
bootloader_editenv: /usr/bin/grub-editenv
bootloader_grubenv: /boot/grub/grubenv
```

```yaml
---
# roles/bootloader/vars/RedHat.yml
bootloader_pkg_bios: [grub2-pc, grub2-tools]
bootloader_pkg_efi: [grub2-efi-x64, grub2-efi-x64-modules, shim-x64, efibootmgr]
bootloader_mkconfig: /usr/sbin/grub2-mkconfig
bootloader_install: /usr/sbin/grub2-install
bootloader_cfg_bios: /boot/grub2/grub.cfg
bootloader_editenv: /usr/bin/grub2-editenv
bootloader_grubenv: /boot/grub2/grubenv
```

```yaml
---
# roles/bootloader/tasks/main.yml
- name: Load distribution-specific variables
  ansible.builtin.include_vars: "{{ ansible_facts['os_family'] }}.yml"

- name: Detect firmware mode
  ansible.builtin.stat:
    path: /sys/firmware/efi
  register: efi_dir

- name: Record firmware mode as a fact
  ansible.builtin.set_fact:
    bootloader_firmware: "{{ 'uefi' if efi_dir.stat.isdir | default(false) else 'bios' }}"

- name: Refuse to run without an explicit device list
  ansible.builtin.assert:
    that:
      - (bootloader_firmware == 'bios' and bootloader_bios_devices | length > 0)
        or (bootloader_firmware == 'uefi' and bootloader_esps | length > 0)
    fail_msg: >-
      Set bootloader_bios_devices (BIOS) or bootloader_esps (UEFI) explicitly.
      Autodetecting the boot device is how fleets lose their MBR mirror.

- name: Install boot loader packages
  ansible.builtin.package:
    name: "{{ bootloader_pkg_efi if bootloader_firmware == 'uefi' else bootloader_pkg_bios }}"
    state: present

# ---- Back up before touching anything -------------------------------------
- name: Ship the boot metadata backup script
  ansible.builtin.copy:
    src: backup-boot-metadata
    dest: /usr/local/sbin/backup-boot-metadata
    owner: root
    group: root
    mode: "0750"

- name: Back up boot metadata
  ansible.builtin.command: /usr/local/sbin/backup-boot-metadata
  register: boot_backup
  changed_when: true

# ---- Configuration ---------------------------------------------------------
- name: Deploy /etc/default/grub
  ansible.builtin.template:
    src: default-grub.j2
    dest: /etc/default/grub
    owner: root
    group: root
    mode: "0644"
    backup: true
    validate: /bin/sh -n %s          # catch shell syntax errors BEFORE reboot
  notify: regenerate grub config

- name: Deploy custom menu entries
  ansible.builtin.template:
    src: 40_custom.j2
    dest: /etc/grub.d/40_custom
    owner: root
    group: root
    mode: "0755"
  notify: regenerate grub config

- name: Deploy boot-counting script
  ansible.builtin.copy:
    src: 09_boot_counting
    dest: /etc/grub.d/09_boot_counting
    owner: root
    group: root
    mode: "0755"
  notify: regenerate grub config

- name: Deploy the boot-success marker unit
  ansible.builtin.template:
    src: grub-boot-success.service.j2
    dest: /etc/systemd/system/grub-boot-success.service
    owner: root
    group: root
    mode: "0644"
  notify: reload systemd

- name: Enable the boot-success marker
  ansible.builtin.systemd_service:
    name: grub-boot-success.service
    enabled: true
    daemon_reload: true

# ---- Installation: BIOS ----------------------------------------------------
- name: Install the GRUB bootstrap to every BIOS boot device
  ansible.builtin.command:
    cmd: "{{ bootloader_install }} --target=i386-pc --recheck {{ item }}"
  loop: "{{ bootloader_bios_devices }}"
  when: bootloader_firmware == 'bios'
  register: grub_bios_install
  changed_when: "'Installation finished' in grub_bios_install.stdout"
  notify: regenerate grub config

- name: Record all BIOS boot devices in debconf (Debian, survives upgrades)
  ansible.builtin.debconf:
    name: grub-pc
    question: grub-pc/install_devices
    vtype: multiselect
    value: "{{ bootloader_bios_devices | join(', ') }}"
  when:
    - bootloader_firmware == 'bios'
    - ansible_facts['os_family'] == 'Debian'

# ---- Installation: UEFI ----------------------------------------------------
- name: Ensure every ESP mountpoint exists
  ansible.builtin.file:
    path: "{{ item.mountpoint }}"
    state: directory
    mode: "0700"
  loop: "{{ bootloader_esps }}"
  when: bootloader_firmware == 'uefi'

- name: Mount every ESP
  ansible.posix.mount:
    path: "{{ item.mountpoint }}"
    src: "UUID={{ item.uuid }}"
    fstype: vfat
    opts: "umask=0077{{ ',noauto' if item.get('backup', false) else '' }}"
    state: "{{ 'present' if item.get('backup', false) else 'mounted' }}"
  loop: "{{ bootloader_esps }}"
  when: bootloader_firmware == 'uefi'

- name: Install GRUB to every ESP
  ansible.builtin.command:
    cmd: >-
      {{ bootloader_install }} --target=x86_64-efi
      --efi-directory={{ item.mountpoint }}
      --bootloader-id={{ item.bootloader_id }}
      --recheck
  loop: "{{ bootloader_esps }}"
  when:
    - bootloader_firmware == 'uefi'
    - ansible_facts['os_family'] != 'RedHat'   # RHEL+UEFI: reinstall packages instead
  register: grub_efi_install
  changed_when: "'Installation finished' in grub_efi_install.stdout"
  notify: regenerate grub config

- name: Read the current UEFI boot order
  ansible.builtin.command: efibootmgr
  when: bootloader_firmware == 'uefi'
  changed_when: false
  register: efi_state

- name: Show the resulting UEFI boot order
  ansible.builtin.debug:
    msg: "{{ efi_state.stdout_lines | select('match', '^BootOrder') | list }}"
  when: bootloader_firmware == 'uefi'

# ---- Verification (always runs, even with no changes) ----------------------
- name: Flush handlers so verification sees the regenerated config
  ansible.builtin.meta: flush_handlers

- name: Read the generated configuration
  ansible.builtin.slurp:
    src: "{{ bootloader_cfg_bios }}"
  register: grub_cfg_raw

- name: Assert the generated configuration is sane
  vars:
    cfg: "{{ grub_cfg_raw.content | b64decode }}"
  ansible.builtin.assert:
    that:
      - cfg is search('^menuentry ', multiline=True)
      - cfg is search('\\s+linux\\s+/')
      - cfg is search('\\s+initrd\\s+/')
      - cfg is search('root=UUID=')
      - cfg is not search('root=/dev/[sh]d[a-z][0-9]')   # unstable device names
    fail_msg: >-
      Generated grub.cfg failed validation. DO NOT REBOOT this host.
      Restore from {{ boot_backup.stdout | default('the last backup') }}.
    success_msg: "grub.cfg validated: menuentry, linux, initrd and root=UUID present."

- name: Confirm the current kernel has a matching menu entry
  vars:
    cfg: "{{ grub_cfg_raw.content | b64decode }}"
  ansible.builtin.assert:
    that:
      - cfg is search(ansible_facts['kernel'] | regex_escape)
    fail_msg: "Running kernel {{ ansible_facts['kernel'] }} has no menu entry."

- name: Confirm every BIOS device carries a bootstrap
  ansible.builtin.shell:
    cmd: "set -o pipefail; dd if={{ item }} bs=512 count=1 status=none | strings | grep -q GRUB"
    executable: /bin/bash
  loop: "{{ bootloader_bios_devices }}"
  when: bootloader_firmware == 'bios'
  changed_when: false
  failed_when: false
  register: mbr_check

- name: Fail if any BIOS device lacks a bootstrap
  ansible.builtin.assert:
    that: "mbr_check.results | rejectattr('rc', 'equalto', 0) | list | length == 0"
    fail_msg: >-
      Missing GRUB bootstrap on:
      {{ mbr_check.results | rejectattr('rc','equalto',0) | map(attribute='item') | list }}
  when: bootloader_firmware == 'bios'
```

```yaml
---
# roles/bootloader/handlers/main.yml
- name: regenerate grub config
  ansible.builtin.command:
    cmd: "{{ bootloader_mkconfig }} -o {{ bootloader_cfg_bios }}"
  register: mkconfig
  changed_when: true
  failed_when: mkconfig.rc != 0 or 'error' in (mkconfig.stderr | lower)

- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true
```

```jinja
{# roles/bootloader/templates/default-grub.j2 #}
# ANSIBLE MANAGED — role platform.bootloader. Local edits will be overwritten.
GRUB_DEFAULT={{ bootloader_default }}
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT={{ bootloader_timeout }}
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="{{ ansible_facts['distribution'] }}"
GRUB_CMDLINE_LINUX="{{ bootloader_console_args }} {{ bootloader_extra_args }}"
GRUB_CMDLINE_LINUX_DEFAULT="{{ bootloader_default_args }}"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_PRELOAD_MODULES="{{ bootloader_preload_modules }}"
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_RECOVERY=false
GRUB_DISABLE_OS_PROBER={{ 'true' if bootloader_disable_os_prober else 'false' }}
{% if ansible_facts['os_family'] == 'RedHat' %}
GRUB_ENABLE_BLSCFG=true
{% endif %}
```

```yaml
---
# playbooks/bootloader.yml — serial rollout with an in-band health gate
- name: Configure the boot loader fleet-wide
  hosts: linux_servers
  become: true
  serial: "10%"                       # never touch the whole fleet at once
  max_fail_percentage: 0              # stop the entire rollout on the first failure
  roles:
    - role: bootloader
      bootloader_bios_devices:
        - /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T101234A
        - /dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNZ0T105678B
  post_tasks:
    - name: Arm a one-shot boot into the new default
      ansible.builtin.command: "grub-reboot '{{ bootloader_target_entry }}'"
      when: bootloader_target_entry is defined

    - name: Reboot and wait for the host to come back
      ansible.builtin.reboot:
        reboot_timeout: 600
        test_command: systemctl is-system-running --wait
      when: bootloader_reboot_after | bool

    - name: Confirm the intended kernel is running
      ansible.builtin.assert:
        that: ansible_facts['kernel'] == bootloader_expected_kernel
        fail_msg: >-
          Host booted {{ ansible_facts['kernel'] }},
          expected {{ bootloader_expected_kernel }}. Rollback triggered.
      when: bootloader_expected_kernel is defined
```

### 9.2 cloud-init — kernel arguments at first boot

```yaml
#cloud-config
# Applied by cloud-init on first boot; a reboot is required for kernel args.
write_files:
  - path: /etc/default/grub.d/99-platform.cfg
    owner: root:root
    permissions: "0644"
    content: |
      # Debian/Ubuntu source /etc/default/grub.d/*.cfg after /etc/default/grub,
      # so a drop-in composes with the distro defaults instead of replacing them.
      GRUB_TIMEOUT=5
      GRUB_TIMEOUT_STYLE=menu
      GRUB_TERMINAL="console serial"
      GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
      GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 nvme_core.io_timeout=4294967295"
      GRUB_DISABLE_OS_PROBER=true
      GRUB_RECORDFAIL_TIMEOUT=30

runcmd:
  - [ update-grub ]
  # Fail loudly at provisioning time rather than silently at reboot time.
  - [ sh, -c, "grep -q 'console=ttyS0' /boot/grub/grub.cfg || { echo 'FATAL: serial console arg missing from grub.cfg'; exit 1; }" ]
  - [ sh, -c, "grep -q 'root=UUID=' /boot/grub/grub.cfg || { echo 'FATAL: no UUID-based root='; exit 1; }" ]

power_state:
  mode: reboot
  message: "Rebooting to apply boot loader configuration"
  timeout: 60
  condition: true
```

### 9.3 Butane → Ignition — immutable hosts (Fedora CoreOS / Flatcar / OKD)

On image-based systems the loader is not configured by editing files; kernel arguments are a declarative property of the machine.

```yaml
variant: fcos
version: 1.5.0

kernel_arguments:
  should_exist:
    - console=tty0
    - console=ttyS0,115200n8
    - panic=30
    - systemd.unified_cgroup_hierarchy=1
    - mitigations=auto,nosmt
  should_not_exist:
    - quiet
    - rhgb

storage:
  files:
    # Bootloader timeout on an immutable host: still needed for console rescue.
    - path: /boot/loader/loader.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          timeout 5
          console-mode keep
          editor no

    - path: /usr/local/bin/verify-boot-chain.sh
      mode: 0755
      contents:
        inline: |
          #!/usr/bin/bash
          set -euo pipefail
          echo "firmware: $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS)"
          echo "cmdline : $(cat /proc/cmdline)"
          echo "kernel  : $(uname -r)"
          rpm-ostree status --json | jq -r '.deployments[] | "\(.booted) \(.checksum[0:12]) \(.version)"'

systemd:
  units:
    # greenboot: health-check driven automatic rollback on rpm-ostree systems.
    - name: greenboot-healthcheck.service
      enabled: true
    - name: platform-boot-healthcheck.service
      enabled: true
      contents: |
        [Unit]
        Description=Platform boot health check for greenboot
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/systemctl is-system-running --wait
        ExecStart=/usr/bin/systemctl is-active kubelet.service
        RemainAfterExit=yes

        [Install]
        RequiredBy=greenboot-healthcheck.service
```

```console
$ butane --pretty --strict node.bu --output node.ign
$ jq -r '.kernelArguments.shouldExist[]' node.ign
console=tty0
console=ttyS0,115200n8
panic=30
systemd.unified_cgroup_hierarchy=1
mitigations=auto,nosmt

$ sudo rpm-ostree kargs
console=tty0 console=ttyS0,115200n8 panic=30 systemd.unified_cgroup_hierarchy=1 mitigations=auto,nosmt

$ sudo rpm-ostree status
State: idle
Deployments:
● fedora:fedora/x86_64/coreos/stable
                  Version: 39.20260812.3.0 (2026-08-12T14:22:41Z)
                   Commit: 8f2a...c19
             GPGSignature: Valid signature by ...

  fedora:fedora/x86_64/coreos/stable
                  Version: 39.20260729.3.0 (2026-07-29T11:04:07Z)
                   Commit: 3b7e...a02
```

The second deployment **is** the backup boot option: `rpm-ostree rollback` promotes it, and greenboot promotes it automatically if the health check fails.

### 9.4 Kickstart — provisioning-time boot loader policy

```
# ks.cfg — RHEL / Rocky / AlmaLinux unattended install
text
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Wipe and lay out for hybrid BIOS/UEFI bootability
ignoredisk --only-use=sda,sdb
clearpart --all --initlabel --drives=sda,sdb
part biosboot --fstype=biosboot --size=1     --ondisk=sda
part /boot/efi --fstype=efi     --size=512   --ondisk=sda --fsoptions="umask=0077,shortname=winnt"
part raid.11   --size=1024      --ondisk=sda
part raid.12   --size=1024      --ondisk=sdb
part raid.21   --size=1         --grow --ondisk=sda
part raid.22   --size=1         --grow --ondisk=sdb
raid /boot     --level=1 --device=md0 --fstype=xfs --metadata=1.0 raid.11 raid.12
raid pv.01     --level=1 --device=md1 --metadata=1.2 raid.21 raid.22
volgroup vg0 pv.01
logvol /       --vgname=vg0 --size=51200 --name=root --fstype=xfs
logvol swap    --vgname=vg0 --size=8192  --name=swap

# Boot loader policy: MBR of the first disk, explicit arguments, GRUB password.
bootloader --location=mbr --boot-drive=sda --timeout=5 \
           --append="console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 crashkernel=auto" \
           --iscrypted --password=grub.pbkdf2.sha512.10000.C4A9B1F2E8...D3E1

rootpw --iscrypted $6$rounds=656000$...
authselect select sssd with-mkhomedir --force
firewall --enabled --service=ssh
selinux --enforcing
reboot

%packages
@core
efibootmgr
grub2-tools
grub2-pc
mdadm
%end

%post --log=/root/ks-post-boot.log
set -x
# /boot is mdraid metadata 1.0, so the bootstrap must be written to BOTH disks.
grub2-install --target=i386-pc --recheck /dev/sda
grub2-install --target=i386-pc --recheck /dev/sdb
grub2-mkconfig -o /boot/grub2/grub.cfg

# Persist the array so the initramfs can assemble it.
mdadm --detail --scan >> /etc/mdadm.conf
dracut --force --regenerate-all

# Provisioning-time gate: fail the build rather than ship an unbootable image.
grep -q 'root=' /boot/grub2/grub.cfg || { echo "FATAL: no root= in grub.cfg"; exit 1; }
for d in /dev/sda /dev/sdb; do
    dd if=$d bs=512 count=1 status=none | strings | grep -q GRUB \
      || { echo "FATAL: no bootstrap on $d"; exit 1; }
done
%end
```

---

## 10. Verification and failure diagnosis

### 10.1 Pre-reboot verification script — run this before every reboot

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-boot-chain — exit non-zero if this host may not boot.
set -uo pipefail

FAIL=0
ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }

if [ -d /sys/firmware/efi ]; then FW=uefi; else FW=bios; fi
echo "== Boot chain verification ($(hostname -s), firmware: ${FW}) =="

# --- 1. Generated configuration exists and is not truncated ---------------
CFG=$(ls /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null | head -1)
if [ -z "${CFG}" ]; then
    bad "no grub.cfg found"
else
    ok "config: ${CFG}"
    N=$(grep -c '^[[:space:]]*menuentry ' "${CFG}")
    [ "${N}" -ge 1 ] && ok "${N} menu entries" || bad "zero menu entries"
    grep -q 'root=UUID=\|root=/dev/mapper/\|BOOT_IMAGE' "${CFG}" \
        && ok "root= present" || bad "no root= in any entry"
    grep -qE 'root=/dev/[sh]d[a-z][0-9]' "${CFG}" \
        && warn "unstable device name in root= — will break on hardware change"
fi

# --- 2. Every referenced kernel and initrd actually exists ----------------
BOOTDIR=$(findmnt -no TARGET /boot 2>/dev/null || echo /)
MISSING=0
while read -r f; do
    [ -e "${BOOTDIR}/${f}" ] || [ -e "/boot/${f}" ] || { bad "referenced file missing: ${f}"; MISSING=1; }
done < <(grep -hoP '^\s*(linux|initrd)\s+\K\S+' "${CFG}" 2>/dev/null | sort -u)
[ "${MISSING}" -eq 0 ] && ok "all referenced kernel/initrd files present"

# --- 3. The running kernel has an entry -----------------------------------
grep -q "$(uname -r)" "${CFG}" 2>/dev/null \
    && ok "running kernel $(uname -r) has a menu entry" \
    || bad "running kernel $(uname -r) has NO menu entry"

# --- 4. At least two bootable kernels (a fallback exists) ------------------
K=$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
[ "${K}" -ge 2 ] && ok "${K} kernels installed (fallback available)" \
                 || warn "only ${K} kernel installed — no rollback target"

# --- 5. initramfs matches every kernel ------------------------------------
for k in /boot/vmlinuz-*; do
    v=${k#/boot/vmlinuz-}
    [ -e "/boot/initrd.img-${v}" ] || [ -e "/boot/initramfs-${v}.img" ] \
        && ok "initramfs present for ${v}" \
        || bad "NO initramfs for kernel ${v}"
done

# --- 6. Bootstrap present on disk -----------------------------------------
if [ "${FW}" = bios ]; then
    for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'); do
        if dd if="$d" bs=512 count=1 status=none 2>/dev/null | strings | grep -q GRUB; then
            ok "GRUB bootstrap in MBR of $d"
        else
            warn "no GRUB bootstrap on $d (intentional if it is not a boot device)"
        fi
    done
else
    for esp in $(findmnt -rno TARGET -t vfat | grep -E '/boot/efi|/efi'); do
        if find "$esp" -iname '*.efi' -print -quit | grep -q .; then
            ok "EFI binaries present in ${esp}"
        else
            bad "${esp} contains no EFI binary"
        fi
    done
    if command -v efibootmgr >/dev/null; then
        ORDER=$(efibootmgr | awk -F': ' '/^BootOrder/{print $2}')
        [ -n "${ORDER}" ] && ok "BootOrder: ${ORDER}" || bad "BootOrder is empty"
        CNT=$(efibootmgr | grep -c '^Boot[0-9A-F]\{4\}')
        [ "${CNT}" -ge 2 ] && ok "${CNT} NVRAM entries (fallback available)" \
                           || warn "only ${CNT} NVRAM entry — no firmware-level fallback"
    fi
fi

# --- 7. /boot free space (a full /boot silently breaks kernel installs) ----
USE=$(df --output=pcent /boot 2>/dev/null | tail -1 | tr -dc '0-9')
[ -n "${USE}" ] && { [ "${USE}" -lt 80 ] && ok "/boot ${USE}% used" || bad "/boot ${USE}% used — kernel updates will fail"; }

# --- 8. grubenv sanity ----------------------------------------------------
GE=$(ls /boot/grub/grubenv /boot/grub2/grubenv 2>/dev/null | head -1)
if [ -n "${GE}" ]; then
    SZ=$(stat -c %s "${GE}")
    [ "${SZ}" -eq 1024 ] && ok "grubenv is 1024 bytes" || bad "grubenv is ${SZ} bytes (must be 1024)"
fi

echo
[ "${FAIL}" -eq 0 ] && echo "RESULT: safe to reboot." || echo "RESULT: DO NOT REBOOT."
exit "${FAIL}"
```

```console
$ sudo /usr/local/sbin/verify-boot-chain
== Boot chain verification (node-a17, firmware: uefi) ==
  [ OK ] config: /boot/grub/grub.cfg
  [ OK ] 6 menu entries
  [ OK ] root= present
  [ OK ] all referenced kernel/initrd files present
  [ OK ] running kernel 6.1.0-18-amd64 has a menu entry
  [ OK ] 2 kernels installed (fallback available)
  [ OK ] initramfs present for 6.1.0-17-amd64
  [ OK ] initramfs present for 6.1.0-18-amd64
  [ OK ] EFI binaries present in /boot/efi
  [ OK ] BootOrder: 0005,0006,0003
  [ OK ] 5 NVRAM entries (fallback available)
  [ OK ] /boot 34% used
  [ OK ] grubenv is 1024 bytes

RESULT: safe to reboot.
```

### 10.2 Failure catalogue — symptom → cause → fix

| Symptom on console | Root cause | Immediate action | Permanent fix |
|---|---|---|---|
| Nothing; "No bootable device" | No bootstrap in MBR / no valid NVRAM entry / firmware set to the wrong disk | boot rescue media | `grub-install /dev/sda`; `efibootmgr -c …`; fix firmware boot order |
| `GRUB _` and it stops | `core.img` cannot be read — gap overwritten, or blocklists invalidated | rescue media | `grub-install --recheck /dev/sda` |
| `error: no such partition` → `grub rescue>` | `/boot` partition moved, resized, UUID changed, or disk reordered | `ls`, `set prefix=…`, `set root=…`, `insmod normal`, `normal` | `grub-install` + `grub-mkconfig` after boot |
| `error: file '/boot/grub/i386-pc/normal.mod' not found` | prefix points at a path that no longer holds the modules | same rescue sequence as above | `grub-install` |
| `error: symbol 'grub_calloc' not found` | **BootHole class**: modules on disk upgraded, `core.img` not re-installed | boot from rescue ISO, chroot | `grub-install` in the **same transaction** as every `grub2` package upgrade |
| `error: unknown filesystem` | required fs module absent from `core.img` (Btrfs, LVM, mdraid) | rescue media | `grub-install --modules="lvm mdraid1x btrfs"` / set `GRUB_PRELOAD_MODULES` |
| `error: diskfilter writes are not supported` | GRUB tried to write `grubenv` on LVM/mdraid | ignore — it is a warning at boot | set `GRUB_SAVEDEFAULT=false`; put `/boot` on a plain partition |
| Menu appears, entry selected, then blank screen | video mode / KMS failure — GRUB worked | press `e`, add `nomodeset`, `Ctrl-x` | correct driver, or pin `nomodeset` in `GRUB_CMDLINE_LINUX` |
| `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)` | initrd missing/mismatched, or `root=` wrong | boot the previous kernel from the menu | `update-initramfs -u -k all` / `dracut -f --regenerate-all`; fix `root=` |
| Drops to `(initramfs)` or `dracut:/#` | GRUB succeeded; initramfs cannot find/assemble root (RAID, LVM, LUKS, missing driver) | `cat /proc/cmdline`, `blkid`, `lvm vgchange -ay` | regenerate initramfs with the right modules; fix `/etc/mdadm.conf`, `/etc/crypttab` |
| Boots into an **old** kernel every time | `GRUB_DEFAULT=saved` + a stale `saved_entry` | `grub-set-default 0` | audit `grub-editenv list` in monitoring |
| Menu shows no kernels after an upgrade | `/boot` full — kernel package installed but files truncated | free space, reinstall the kernel package | size `/boot` ≥ 1 GiB; enforce autoremove of old kernels |
| Secure Boot: `Verification failed: (0x1A) Security Violation` | unsigned or wrongly-signed `grubx64.efi`/`vmlinuz` (often after `grub-install` on RHEL UEFI) | disable Secure Boot to get in | reinstall `shim-x64`/`grub2-efi-x64` packages; never `grub2-install` on RHEL UEFI |
| Firmware boot entry vanishes after every reboot | buggy firmware pruning NVRAM, or NVRAM full | re-add with `efibootmgr -c` | install to the **removable path** as a fallback: `grub-install --removable` |
| Password prompt on every unattended reboot | `set superusers` without `--unrestricted` on normal entries | boot manually | add `--unrestricted` to the normal entries |
| Works on `/dev/sda`, dead when `sda` fails | bootstrap never mirrored to `sdb` | boot from `sdb` via firmware menu | `grub-install /dev/sdb`; add the mirror to `install_devices` |

### 10.3 The canonical chroot repair

Applies to almost every row above. Boot any live/rescue image of a matching architecture.

```console
# 1. Identify the layout.
$ sudo lsblk -f
NAME        FSTYPE      LABEL UUID                                 MOUNTPOINTS
sda
├─sda1
├─sda2      vfat        ESP   9F4A-1C2E
├─sda3      ext4        boot  8f3c1a92-4b7e-4c31-a0f2-9d5e6b7c8a10
└─sda4      LVM2_member       kQ2xYz-...
  ├─vg0-root xfs              c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c
  └─vg0-data xfs              e7f8a9b0-...

# 2. Activate the storage stack the initramfs would have activated.
$ sudo vgchange -ay
  2 logical volume(s) in volume group "vg0" now active
$ sudo mdadm --assemble --scan          # if mdraid is in play

# 3. Mount root, then everything below it, in order.
$ sudo mount /dev/vg0/root /mnt
$ sudo mount /dev/sda3     /mnt/boot
$ sudo mount /dev/sda2     /mnt/boot/efi        # UEFI only

# 4. Bind the kernel interfaces the tools need.
$ for d in /dev /dev/pts /proc /sys /run; do sudo mount --bind "$d" "/mnt$d"; done
$ sudo mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars   # UEFI only
# efivars is MANDATORY: without it, efibootmgr cannot write NVRAM and
# grub-install silently produces a system with no boot entry.

# 5. Enter.
$ sudo chroot /mnt /bin/bash

# 6. Repair.
root@rescue:/# grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                            --bootloader-id=debian --recheck
Installing for x86_64-efi platform.
Installation finished. No error reported.

root@rescue:/# update-grub
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.1.0-18-amd64
Found initrd image: /boot/initrd.img-6.1.0-18-amd64
done

root@rescue:/# update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
update-initramfs: Generating /boot/initrd.img-6.1.0-17-amd64

root@rescue:/# efibootmgr -v | grep -i debian
Boot0005* debian	HD(2,GPT,9f4a1c2e-...,0x800,0x100000)/File(\EFI\DEBIAN\SHIMX64.EFI)

root@rescue:/# exit

# 7. Unmount in reverse and reboot.
$ sudo umount -R /mnt
$ sudo reboot
```

> **The single most common chroot mistake:** forgetting `--bind /sys/firmware/efi/efivars`. `grub-install` reports "Installation finished. No error reported." and the machine still will not boot, because no NVRAM entry was created. Always verify with `efibootmgr -v` **inside** the chroot.

### 10.4 Post-boot forensics

```console
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=UUID=c4e2d1b0-a9f8-4e37-b6c5-2d1a0f9e8b7c ro console=tty0 console=ttyS0,115200n8 net.ifnames=0 panic=30 quiet loglevel=3

$ systemd-analyze
Startup finished in 3.412s (firmware) + 2.187s (loader) + 1.043s (kernel) + 9.876s (userspace) = 16.519s
graphical.target reached after 9.871s in userspace.

$ systemd-analyze blame | head -5
5.812s NetworkManager-wait-online.service
1.204s systemd-udev-settle.service
 903ms dracut-initqueue.service
 441ms lvm2-monitor.service
 312ms systemd-journal-flush.service

$ journalctl -b -1 -p err --no-pager | head
-- Journal begins at Mon 2026-08-11 06:02:15 UTC, ends at Tue 2026-08-25 12:44:03 UTC. --
Aug 25 12:38:41 node-a17 kernel: EXT4-fs (sda3): mounted filesystem without journal

$ journalctl --list-boots | head -4
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 3f9a...c1                        Mon 2026-08-11 06:02:15 UTC Fri 2026-08-22 09:14:33 UTC
 -1 7b2e...4d                        Fri 2026-08-22 09:15:02 UTC Tue 2026-08-25 12:37:58 UTC
  0 c8d1...9f                        Tue 2026-08-25 12:38:40 UTC Tue 2026-08-25 12:44:03 UTC
```

`systemd-analyze`'s **`loader`** figure is the boot loader's own wall-clock contribution (UEFI only, from firmware performance data). A jump there usually means `os-prober` scanning at boot, a network-boot attempt timing out, or a very large `GRUB_TIMEOUT`.

`journalctl --list-boots` is the audit trail for the boot-counting design in section 8.4: gaps between `LAST ENTRY` of one boot and `FIRST ENTRY` of the next are unclean shutdowns — exactly the events that should be incrementing `boot_attempts`.

### 10.5 Red Hat BootLoaderSpec (BLS) — a different config surface

On RHEL 8+/Fedora, `grub.cfg` is mostly a loop over `/boot/loader/entries/*.conf`. Editing `grub.cfg` there does almost nothing.

```console
$ ls /boot/loader/entries/
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64.conf
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-362.24.1.el9_3.x86_64.conf
6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-0-rescue.conf

$ cat /boot/loader/entries/6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64.conf
title Red Hat Enterprise Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Plow)
version 5.14.0-427.13.1.el9_4.x86_64
linux /vmlinuz-5.14.0-427.13.1.el9_4.x86_64
initrd /initramfs-5.14.0-427.13.1.el9_4.x86_64.img
options root=/dev/mapper/vg0-root ro crashkernel=1G-4G:192M,4G-64G:256M rd.lvm.lv=vg0/root console=ttyS0,115200n8
grub_users $grub_users
grub_arg --unrestricted
grub_class rhel

$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.13.1.el9_4.x86_64"
args="ro crashkernel=1G-4G:192M,4G-64G:256M rd.lvm.lv=vg0/root console=ttyS0,115200n8"
root="/dev/mapper/vg0-root"
initrd="/boot/initramfs-5.14.0-427.13.1.el9_4.x86_64.img"
title="Red Hat Enterprise Linux (5.14.0-427.13.1.el9_4.x86_64) 9.4 (Plow)"
id="6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-427.13.1.el9_4.x86_64"

# Add an argument to EVERY entry, including future kernels:
$ sudo grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=8192"
$ sudo grubby --update-kernel=ALL --remove-args="quiet rhgb"

# Change the default kernel:
$ sudo grubby --set-default /boot/vmlinuz-5.14.0-362.24.1.el9_3.x86_64
The default is /boot/loader/entries/6b3f2a1c9d8e4f5a0b1c2d3e4f5a6b7c-5.14.0-362.24.1.el9_3.x86_64.conf with index 1 and kernel /boot/vmlinuz-5.14.0-362.24.1.el9_3.x86_64
```

> **Future kernels matter.** `grubby --update-kernel=ALL` writes to existing entries **and** to `/etc/kernel/cmdline`, so `kernel-install` applies the same arguments to kernels installed later. Editing the `.conf` files by hand does not.

---

## 11. Practical command summary

### GRUB 2

```console
$ sudo grub-mkconfig -o /boot/grub/grub.cfg     # generate config (portable form)
$ sudo update-grub                              # Debian wrapper for the above
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg   # Red Hat form
$ sudo grub-install --target=i386-pc /dev/sda   # BIOS install to the MBR
$ sudo grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian
$ sudo grub-install --removable --efi-directory=/boot/efi   # \EFI\BOOT\BOOTX64.EFI
$ sudo grub-mkpasswd-pbkdf2                     # generate a menu password hash
$ sudo grub-set-default 'entry-id'              # permanent default
$ sudo grub-reboot 'entry-id'                   # ONE-SHOT default
$ sudo grub-editenv list                        # read grubenv
$ sudo grub-editenv /boot/grub/grubenv unset next_entry
$ grub-probe --target=fs /boot                  # what grub-install sees
$ sudo grub-mkrescue -o rescue.iso /tmp/empty   # bootable rescue ISO
$ sudo grub-mknetdir --net-directory=/srv/tftp  # netboot tree
```

### GRUB Legacy

```console
# grub-install --root-directory=/ /dev/sda       # non-interactive install
# grub                                           # interactive shell
grub> find /boot/grub/stage1                     # which partitions hold GRUB
grub> root (hd0,0)                               # partition holding /boot/grub
grub> setup (hd0)                                # write stage1 to the MBR of hd0
grub> quit
# grub-md5-crypt                                 # menu.lst password hash
```

### UEFI

```console
$ sudo efibootmgr -v                             # list entries, order, current
$ sudo efibootmgr -c -d /dev/sda -p 2 -L "debian" -l '\EFI\debian\shimx64.efi'
$ sudo efibootmgr -o 0005,0006,0003              # persistent order
$ sudo efibootmgr -n 0006                        # BootNext — one shot
$ sudo efibootmgr -b 0006 -B                     # delete entry 0006
$ mokutil --sb-state                             # Secure Boot on/off
$ bootctl status                                 # systemd view of the ESP
```

### Diagnosis

```console
$ [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
$ cat /proc/cmdline
$ lsblk -f
$ sudo blkid
$ findmnt /boot /boot/efi
$ sudo dd if=/dev/sda bs=512 count=1 status=none | strings | grep -c GRUB
$ awk -F"'" '/^menuentry /{print $2" ==> "$4}' /boot/grub/grub.cfg
$ sudo grubby --info=ALL            # Red Hat BLS
$ systemd-analyze
$ journalctl -b -1 -p err
```

---

## 12. Exam-focused points that production practice can obscure

1. **Partition numbering.** GRUB Legacy counts partitions from **0**; GRUB 2 from **1**. Disks count from **0** in both. `(hd0,0)` ≡ `(hd0,1)` ≡ `/dev/sda1`.
2. **`menu.lst` is edited; `grub.cfg` is generated.** The GRUB 2 sources are `/etc/default/grub` and `/etc/grub.d/`; the generator is `grub-mkconfig`.
3. **`grub.conf`** is the Red Hat name for GRUB Legacy's config; `menu.lst` is a symlink to it on those systems.
4. **`grub-install` writes the boot code; `grub-mkconfig` writes the menu.** They are independent, and a change to one usually needs the other re-run.
5. **`setup (hdN)` writes the MBR; `root (hdN,M)` selects where stage2 is read from.** Source and destination are separate arguments.
6. **The MBR is 512 bytes:** 446 bootstrap + 64 partition table + 2 signature.
7. **`chainloader +1`** loads one sector from the current `root` device and jumps to it — the mechanism for booting another loader or another disk.
8. **`fallback`** (Legacy) and `GRUB_DEFAULT=saved` + `grub-reboot` (GRUB 2) are the objective's "backup boot options".
9. **UEFI has no MBR.** `grub-install` on UEFI writes a `.efi` binary into the ESP and an NVRAM entry via `efibootmgr`; `\EFI\BOOT\BOOTX64.EFI` is the fallback path.
10. **Editing an entry with `e` is temporary.** It survives exactly one boot and is never written to disk.

---

## 13. Referencias

**Certification objectives**
- LPI — Exam 101-500 Objectives (LPIC-1 v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**GNU GRUB**
- GNU GRUB Manual 2.x (official): https://www.gnu.org/software/grub/manual/grub/grub.html
- GRUB 2 — `grub-install` invocation: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dinstall
- GRUB 2 — `grub-mkconfig` invocation: https://www.gnu.org/software/grub/manual/grub/grub.html#Invoking-grub_002dmkconfig
- GRUB 2 — Simple configuration handling (`/etc/default/grub`): https://www.gnu.org/software/grub/manual/grub/grub.html#Simple-configuration
- GRUB 2 — Command-line and menu-entry commands: https://www.gnu.org/software/grub/manual/grub/grub.html#Commands
- GRUB 2 — Naming convention (device syntax): https://www.gnu.org/software/grub/manual/grub/grub.html#Naming-convention
- GRUB 2 — Authentication and authorisation: https://www.gnu.org/software/grub/manual/grub/grub.html#Security
- GRUB 2 — Environment block (`grubenv`): https://www.gnu.org/software/grub/manual/grub/grub.html#Environment-block
- GNU GRUB Legacy Manual 0.97: https://www.gnu.org/software/grub/manual/legacy/grub.html
- GRUB Legacy — `menu.lst` and menu-specific commands: https://www.gnu.org/software/grub/manual/legacy/Menu_002dspecific-commands.html
- GRUB Legacy — Installing GRUB natively (`root` / `setup`): https://www.gnu.org/software/grub/manual/legacy/Installing-GRUB-natively.html
- GRUB project home: https://www.gnu.org/software/grub/

**Distribution documentation**
- Debian Wiki — GRUB 2: https://wiki.debian.org/Grub2
- Debian Wiki — UEFI: https://wiki.debian.org/UEFI
- Ubuntu Community Help — Grub2: https://help.ubuntu.com/community/Grub2
- Red Hat Enterprise Linux 9 — Managing the GRUB boot loader: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/assembly_configuring-kernel-command-line-parameters_managing-monitoring-and-updating-the-kernel
- Red Hat Enterprise Linux 9 — Configuring kernel command-line parameters: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/configuring-kernel-command-line-parameters_managing-monitoring-and-updating-the-kernel
- SUSE Linux Enterprise Server — The boot loader GRUB 2: https://documentation.suse.com/sles/15-SP5/html/SLES-all/cha-grub2.html
- Arch Wiki — GRUB: https://wiki.archlinux.org/title/GRUB
- Arch Wiki — Unified Extensible Firmware Interface: https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface
- Arch Wiki — EFI system partition: https://wiki.archlinux.org/title/EFI_system_partition
- Arch Wiki — systemd-boot: https://wiki.archlinux.org/title/Systemd-boot

**Specifications and firmware**
- UEFI Specification (UEFI Forum): https://uefi.org/specifications
- Boot Loader Specification (systemd / UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification: https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- systemd — `bootctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html
- systemd — `systemd-boot(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html
- Linux kernel — The kernel's command-line parameters: https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Linux kernel — Boot process (x86): https://www.kernel.org/doc/html/latest/arch/x86/boot.html

**Tools**
- `efibootmgr` (rhboot): https://github.com/rhboot/efibootmgr
- `shim` — the Secure Boot first-stage loader: https://github.com/rhboot/shim
- `dracut` documentation: https://man7.org/linux/man-pages/man8/dracut.8.html
- `grubby(8)` — Red Hat BLS entry manipulation: https://man7.org/linux/man-pages/man8/grubby.8.html
- SYSLINUX project: https://wiki.syslinux.org/wiki/index.php?title=The_Syslinux_Project
- rEFInd boot manager: https://www.rodsbooks.com/refind/

**Security advisories**
- CVE-2020-10713 "BootHole" (Red Hat): https://access.redhat.com/security/cve/CVE-2020-10713
- GRUB2 SBAT (Secure Boot Advanced Targeting): https://github.com/rhboot/shim/blob/main/SBAT.md