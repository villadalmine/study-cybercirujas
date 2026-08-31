# 102.1 — Design Hard Disk Layout

**LPIC-1 v5.0 · Exam 102-500 · Weight 3.13**
**Profile: Principal Platform Architect / SRE — production depth**

---

## 1. The architectural problem

A disk layout is the only design decision in a Linux system that is **effectively immutable after installation** and **globally blast-radius-shaped**. Everything else — packages, kernels, network, workloads — can be re-rolled at runtime. The partition table and the mount-point topology cannot, not without downtime, not without a maintenance window, and on XFS not at all in the shrinking direction.

Three failure classes drive the entire discipline:

**1.1 — Namespace exhaustion is a single-writer denial of service.**
On a single-root system every writer shares one free-space pool. A runaway application log, an unrotated `journald` ring, a container image pull, a core dump, or a `mysqldump` to `/tmp` all consume the *same* extents that `sshd` needs to write its PID file, that `systemd` needs for `/run` overflow, and that the package manager needs to stage an emergency patch. When `/` reaches 100 %:

- `sshd` may still accept connections but PAM `pam_systemd` fails to create the session slice;
- `journald` switches to volatile storage and you lose the forensic trail of the very incident;
- `dnf`/`apt` cannot download the fix;
- SELinux/AppArmor cannot write audit records, and with `-f` panic settings the box halts.

You have lost the machine *and* the ability to repair it remotely. The mitigation is not monitoring. Monitoring tells you it happened. The mitigation is **structural**: put the unbounded-growth directories on their own block devices so that exhaustion is contained to the tenant that caused it.

**1.2 — Mount options are a security control surface, and they are per-filesystem.**
`nosuid`, `nodev`, `noexec`, `ro` are properties of a *mount*, not of a directory. If `/tmp`, `/var/tmp`, `/home` and `/dev/shm` live inside `/`, you cannot apply `noexec` to them without applying it to `/usr/bin`. Every hardening baseline (CIS, DISA STIG, PCI-DSS §2.2) therefore mandates separate filesystems for those paths — the control is unimplementable otherwise. This is the single most common reason a "simple" server design gets rejected in a compliance review.

**1.3 — The boot chain has hard, architecture-specific constraints that the rest of the layout must yield to.**
The firmware can read a very small subset of what the kernel can read. If `/boot` (or the ESP) is placed somewhere the firmware or the bootloader's pre-kernel stage cannot parse, the system is unbootable and no amount of correct design elsewhere matters. Boot requirements are computed **first**; everything else is fitted around them.

> **Exam framing.** LPI 102.1 asks you to (a) allocate filesystems and swap to separate partitions or disks, (b) tailor the design to the system's intended use, (c) ensure `/boot` conforms to the hardware architecture's boot requirements, and (d) know the basic features of LVM. Everything below is that, at production depth.

---

## 2. Boot requirements come first

### 2.1 The two firmware regimes

| Aspect | BIOS / CSM (legacy) | UEFI |
|---|---|---|
| Firmware reads | Raw sectors only (MBR bootstrap, 440 bytes) | FAT12/16/32 filesystem natively |
| Partition table | MBR (msdos) usually; GPT possible with a helper partition | GPT (MBR is out-of-spec but often tolerated) |
| Bootloader staging | MBR bootstrap → `core.img` → `/boot/grub2` | `\EFI\<vendor>\grubx64.efi` (or `shimx64.efi`) on the ESP |
| Required helper partition | **BIOS boot partition** (~1 MiB, type `ef02`) *only if the table is GPT* | **EFI System Partition (ESP)**, FAT32, type `ef00` |
| Boot entry storage | None — order is firmware disk order | NVRAM variables (`efibootmgr`), `\EFI\BOOT\BOOTX64.EFI` fallback |
| Secure Boot | Not available | `shim` → GRUB → signed kernel; affects module loading and hibernation |
| Max bootable disk | 2 TiB with 512 B sectors | 8 ZiB (GPT, 64-bit LBA) |
| Typical `/boot` layout | Separate ext4/xfs `/boot`, or inside `/` | ESP at `/boot/efi` + separate `/boot` |

**Why the BIOS boot partition exists.** On MBR, GRUB stashes `core.img` in the ~31 KiB "MBR gap" between sector 0 and the first partition at sector 2048. GPT has no such gap — the primary GPT header and partition array occupy LBA 1–33. So GPT+BIOS requires an explicit unformatted 1 MiB partition with GUID `21686148-6449-6E6F-744E-656564454649` for `core.img`. It is **never mounted** and **never formatted**. Forgetting it is the classic "installed fine, boots to `grub rescue>`" failure.

**ESP sizing.** The UEFI specification's minimum is 100 MiB, but that number is obsolete in practice:

- A FAT32 volume needs enough clusters to be valid FAT32 — on 4Kn media the practical floor is **260 MiB**.
- `shim` + `grub` + `fwupd` capsules + vendor firmware updates + (on Fedora/`systemd-boot`/UKI layouts) **the kernels themselves as Unified Kernel Images** all live there. A UKI is 40–120 MiB each.
- **Recommendation: 512 MiB minimum, 1 GiB for any system that will use UKIs, Secure Boot enrolment, or `fwupd`.**

**`/boot` sizing.** Each kernel costs roughly:

| Component | Typical size |
|---|---|
| `vmlinuz` | 12–15 MiB |
| `initramfs` (host-only, `dracut`) | 30–50 MiB |
| `initramfs` (generic / `dracut --no-hostonly`) | 90–140 MiB |
| `System.map`, `config`, `symvers` | 8–12 MiB |
| **Total per kernel** | **~60 MiB host-only, ~180 MiB generic** |

RHEL retains 3 kernels (`installonly_limit=3` in `/etc/dnf/dnf.conf`); Debian/Ubuntu retain 2 plus the current. With rescue images and a generic initramfs, 500 MiB overflows in under a year.

> **Recommendation: `/boot` = 1 GiB.** RHEL 9 and Ubuntu 22.04+ installers default here for exactly this reason. A full `/boot` during a kernel upgrade produces a **truncated initramfs** — the package transaction "succeeds", the next reboot lands in `dracut` emergency shell, and the root cause is three weeks in the past.

### 2.2 What the bootloader can actually read

This is the constraint that kills clever layouts.

| Placement of `/boot` | GRUB2 (BIOS or UEFI) | `systemd-boot` | Verdict |
|---|---|---|---|
| Plain partition, ext4 / xfs / btrfs | ✅ | ❌ (needs FAT ESP) | Safe |
| LVM **linear** or **mirror** LV | ✅ (`insmod lvm`) | ❌ | Works, adds fragility |
| LVM **thin** LV | ❌ | ❌ | **Unbootable** |
| Btrfs subvolume | ✅ | ❌ | Works; RAID5/6 profiles not supported |
| MD RAID **1** (metadata 1.0 or 0.90) | ✅ | ❌ | Works — 1.0 puts metadata at the *end*, so each leg is readable as a plain FS |
| MD RAID 1 (metadata **1.2**, default) | ✅ (`insmod mdraid1x`) | ❌ | Works via GRUB module; firmware still cannot |
| MD RAID **5/6/10** | ⚠️ partial | ❌ | Avoid |
| LUKS**1** | ✅ | ❌ | Works |
| LUKS**2**, PBKDF2 | ✅ (GRUB ≥ 2.06) | ❌ | Works |
| LUKS2, **Argon2id** (cryptsetup default) | ❌ | ❌ | **Unbootable** — the classic |
| ZFS pool | ⚠️ feature-flag dependent | ❌ | Fragile across upgrades |

**Two production rules that fall out of this table:**

1. **Keep `/boot` as a plain, unencrypted, non-thin partition on a simple filesystem.** The 1 GiB you "save" by folding it into LVM buys you an entire class of upgrade-time bricking.
2. If you must encrypt root, either leave `/boot` in the clear or, when converting an existing LUKS2 volume, force the bootloader-compatible KDF:

```bash
$ sudo cryptsetup luksConvertKey --pbkdf pbkdf2 /dev/nvme0n1p3
Enter passphrase for keyslot to be converted:
```

### 2.3 Filesystem feature drift — a real, recurring outage

`mkfs.xfs` enables new on-disk features by default as `xfsprogs` advances (`bigtime`, `inobtcount`, `nrext64`). GRUB's XFS driver is a re-implementation and lags. Creating `/boot` with a newer `mkfs.xfs` than the installed GRUB understands yields `error: unknown filesystem` at boot — *after* the install succeeded.

Defensive `mkfs` for `/boot`, pinning the feature set:

```bash
$ sudo mkfs.xfs -m bigtime=0,inobtcount=0 -i nrext64=0 -L boot /dev/nvme0n1p3
```

Or sidestep the whole class of problem — **ext4 for `/boot`** is the most conservative choice on every distribution, and `/boot` gains nothing from XFS's scalability.

---

## 3. Partition tables: MBR vs GPT

| Property | MBR (`msdos`) | GPT |
|---|---|---|
| Addressing | 32-bit LBA | 64-bit LBA |
| Max disk (512 B sectors) | **2 TiB** | 8 ZiB |
| Max disk (4 KiB sectors) | 16 TiB | — |
| Partition count | 4 primary; more via extended + logical chain | 128 entries by default (array is resizable) |
| Redundancy | None — sector 0 is a single point of failure | Primary header at LBA 1 + **backup at last LBA** |
| Integrity | None | CRC32 over header and partition array |
| Partition identity | 1-byte type code (`0x83`, `0x82`, `0x8e`) | 16-byte type **GUID** + unique per-partition GUID + 36-char UTF-16 name |
| Alignment metadata | Legacy CHS baggage | Clean LBA |
| Legacy interop | Universal | Protective MBR (`0xEE`) prevents old tools from clobbering it |

**Use GPT unconditionally on new builds**, including sub-2 TiB disks and including BIOS machines (add the `ef02` partition). The reasons are the backup header, the CRC, and stable type GUIDs — not the capacity.

### Partition type GUIDs worth memorising

| Purpose | `sgdisk` code | Type GUID |
|---|---|---|
| EFI System Partition | `ef00` | `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| BIOS boot partition | `ef02` | `21686148-6449-6E6F-744E-656564454649` |
| Linux filesystem | `8300` | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` |
| Linux swap | `8200` | `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F` |
| Linux LVM | `8e00` | `E6D6D379-F507-44C2-A23C-238F2A3DF928` |
| Linux LUKS | `8309` | `CA7D7CCB-63ED-4C53-861C-1742536059CC` |
| Root, x86-64 (DPS) | `8304` | `4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709` |
| `/home` (DPS) | `8302` | `933AC7E1-2EB4-4F13-B844-0E14E2AEF915` |

The last two belong to the **Discoverable Partitions Specification**. When those GUIDs are used, `systemd-gpt-auto-generator` mounts `/`, `/home`, `/srv`, `/var` and activates swap **with no `/etc/fstab` entries at all** — the partition table *is* the mount configuration. This is how modern image-based systems (Fedora CoreOS, `systemd`-native appliances) avoid `fstab` drift entirely.

---

## 4. Mount-point taxonomy: what to split and why

The FHS defines the semantics; production defines the split. The decision rule is: **separate a path when it has an independent growth profile, an independent security posture, or an independent durability requirement.**

| Mount point | Growth driver | Bounded? | Split? | Recommended options |
|---|---|---|---|---|
| `/` | Packages only | Yes (~10–20 GiB) | — | `defaults` |
| `/boot` | Kernel retention | Yes (~1 GiB) | **Always** | `nodev,nosuid,noexec` |
| `/boot/efi` | Firmware + UKIs | Yes | **UEFI: always** | `umask=0077,shortname=winnt` |
| `/home` | Users | **No** | Multi-user: yes | `nodev,nosuid` |
| `/var` | Logs, spool, DBs, containers | **No** | **Always on servers** | `nodev,nosuid` |
| `/var/log` | Application + system logging | **No** | Always on servers | `nodev,nosuid,noexec` |
| `/var/log/audit` | auditd — may be configured to **panic on full** | No | Hardened builds | `nodev,nosuid,noexec` |
| `/var/tmp` | Persistent temp | No | Hardened builds | `nodev,nosuid,noexec` |
| `/tmp` | Transient temp | No | Always | `nodev,nosuid,noexec` (or `tmpfs`) |
| `/srv`, `/opt`, `/data` | Payload | No | Per workload | Workload-specific |
| `/usr` | Packages | Yes | Rarely (image-based systems mount it `ro`) | `ro` where supported |

### Why `/var/log/audit` gets its own filesystem

`auditd` can be configured with `disk_full_action = halt` (a STIG requirement). If `/var/log/audit` shares a filesystem with application logs, **any** log flood halts the machine. Isolating audit means the audit subsystem's own guarantee cannot be triggered by an unrelated tenant.

### `noexec` on `/tmp`: what it does and does not buy

It blocks `execve()` of files on that filesystem. It does **not** block `bash /tmp/x.sh` (the interpreter reads, it does not exec) nor `ld.so /tmp/x`. It is a real speed bump against dropper-style payloads and a compliance requirement, not a boundary. Note that some package post-install scripts and older installers (Oracle, certain JVM native-library extractions) break under it; those need `TMPDIR` redirected rather than the option removed.

### The `tmpfs`-for-`/tmp` trade-off

| | Disk-backed `/tmp` | `tmpfs` `/tmp` |
|---|---|---|
| Speed | Device-bound | RAM-speed |
| Capacity | Partition size | 50 % of RAM by default, swap-backed |
| Reboot semantics | Needs `systemd-tmpfiles` cleanup | Empty by definition |
| Risk | Fills the disk | **Consumes RAM and pushes the system toward OOM** |
| Large-file workloads | Fine | A 20 GiB build artefact in `/tmp` becomes 20 GiB of memory pressure |

Enable `tmpfs` `/tmp` (`systemctl enable tmp.mount`) on stateless nodes; keep it disk-backed on build agents, database hosts, and anything that stages large files.

---

## 5. Allocation strategies compared

| Strategy | Isolation | Flexibility | Complexity | Boot risk | Best fit |
|---|---|---|---|---|---|
| **Single root** | None | None (grow only the last partition) | Minimal | Lowest | Containers, immutable images, throwaway VMs |
| **Fixed multi-partition** | Strong | **Poor** — resizing means downtime and repartitioning | Low | Low | Appliances with a known-fixed profile |
| **LVM on one PV** | Strong | **High** — online grow, snapshots, LV add | Medium | Low if `/boot` is outside | **Default for physical and long-lived VMs** |
| **LVM thin pool** | Strong | Highest — overcommit, cheap snapshots | High | Medium — pool exhaustion is a hard failure | Dense virtualisation, CI ephemera |
| **Btrfs subvolumes** | Quota-based (qgroups) | High — no fixed sizes, online shrink, snapshots | Medium | Medium | Workstations, `snapper` rollback, SUSE |
| **ZFS datasets** | Strong (per-dataset quota/reservation) | High | High (out-of-tree) | High | Storage servers where ZFS is the point |
| **Image-based / OSTree** | Structural — `/usr` is read-only | N/A by design | Low to operate | Lowest | Fleet-managed nodes, CoreOS, RHEL Image Mode |

### LVM vs Btrfs: the honest comparison

| Dimension | LVM + XFS/ext4 | Btrfs subvolumes |
|---|---|---|
| Space model | **Fixed** per LV; free space is idle until assigned | **Shared** pool; no pre-allocation decision |
| Grow | Online, both layers | N/A (no fixed size) |
| **Shrink** | ext4: offline only. **XFS: impossible.** | Online |
| Snapshots | Block-level CoW, size-capped, **invalidates when full** | Native, cheap, no capacity cliff |
| Checksums | None (relies on device) | Data + metadata checksums |
| Enforcing a per-path limit | Free — it's the LV size | Requires qgroups (historically expensive) |
| Database workloads | XFS is the reference platform | Needs `nodatacow` — which disables checksums for those files |
| Operational familiarity | Universal | Distribution-dependent |

**Practical guidance:** LVM + XFS for servers and databases; Btrfs where rollback of the OS itself is the requirement.

### The XFS-cannot-shrink rule

This is the most consequential asymmetry in Linux storage design and it directly shapes how you allocate.

```
                grow            shrink
ext4      online (resize2fs)    offline only (umount, e2fsck, resize2fs)
XFS       online (xfs_growfs)   NOT SUPPORTED — ever
Btrfs     online                online
```

**Corollary: on XFS, over-allocation is permanent.** Under LVM, therefore, **allocate conservatively and leave free extents in the VG.** Growing is a 10-second online operation; reclaiming is a backup/restore.

```
VG capacity 400 GiB
  ├── assigned to LVs        ~150 GiB   ← conservative
  └── unassigned free extents ~250 GiB  ← your entire flexibility budget
```

---

## 6. LVM: the model

```
   /dev/nvme0n1p4   /dev/nvme1n1        ← block devices
        │                │
    ┌───▼────────────────▼───┐
    │  Physical Volumes (PV) │   pvcreate — writes an LVM2 label at sector 1
    └───────────┬────────────┘             + metadata area, data starts at 1 MiB
                │
    ┌───────────▼────────────┐
    │   Volume Group (VG)    │   vgcreate — a pool of Physical Extents (PE, 4 MiB default)
    └───────────┬────────────┘
                │
    ┌───────────▼────────────┐
    │  Logical Volumes (LV)  │   lvcreate — a mapping of Logical Extents → Physical Extents
    └───────────┬────────────┘             exposed as /dev/<vg>/<lv> via device-mapper
                │
    ┌───────────▼────────────┐
    │      Filesystem        │   mkfs.xfs / mkfs.ext4
    └────────────────────────┘
```

| Term | Meaning | Operational note |
|---|---|---|
| **PV** | A block device (whole disk or partition) given to LVM | `pvcreate`. Metadata is redundant within the PV. |
| **PE** | Physical Extent — the allocation quantum | Default 4 MiB. `vgcreate -s 16M` for very large VGs (extent count drives metadata size and command latency). |
| **VG** | Named pool of PVs | Extents can be allocated from any member PV. |
| **LV** | Extent mapping presented as a device | Types: `linear`, `striped`, `mirror`, `raid1/5/6/10`, `thin`, `cache`, `snapshot`. |
| **Allocation policy** | `normal`, `contiguous`, `cling`, `anywhere` | `cling` keeps an extension on the same PV — critical for striped LVs. |

### Capabilities that justify the complexity

- **Online growth** — `lvextend -r` resizes the LV *and* the filesystem in one step.
- **Cross-device volumes** — an LV can exceed any single disk.
- **Snapshots** — a point-in-time CoW view for consistent backups.
- **Striping** — `lvcreate -i 4 -I 256k` for parallel throughput across devices.
- **Online PV migration** — `pvmove` relocates extents off a failing disk with the filesystem mounted.
- **Named, stable devices** — `/dev/sysvg/var` never changes because the SAN rescanned.

### Snapshots: the capacity cliff

An LVM (thick) snapshot is a fixed-size CoW area. Every write to the origin copies the original extent into the snapshot. **When the snapshot fills, it is dropped and becomes unreadable** — silently, from the application's point of view.

```bash
$ sudo lvcreate -L 20G -s -n var_snap /dev/sysvg/var
  Logical volume "var_snap" created.

$ sudo lvs -o lv_name,lv_size,data_percent,snap_percent sysvg
  LV        LSize   Data%  Snap%
  var        40.00g
  var_snap   20.00g        6.14
```

Size the snapshot for the *write* volume during the backup window, not the origin size, and monitor `snap_percent`. `/etc/lvm/lvm.conf` has `snapshot_autoextend_threshold` / `snapshot_autoextend_percent` — set them:

```ini
# /etc/lvm/lvm.conf
activation {
    snapshot_autoextend_threshold = 70
    snapshot_autoextend_percent   = 20
    thin_pool_autoextend_threshold = 70
    thin_pool_autoextend_percent   = 20
}
```

### Thin provisioning: overcommit is a liability, not a feature

A thin pool lets the sum of LV sizes exceed physical capacity. When the **pool** hits 100 %, thin LVs go read-only or error out and filesystems on them corrupt. `df` on the guest shows free space right up to the failure. **Never thin-provision the OS filesystems of a production node.** Use it for CI scratch and dense test environments, always with `thin_pool_autoextend_*` configured and pool-level alerting.

---

## 7. Swap

### Sizing

Red Hat's published guidance, which is the de-facto industry reference:

| Installed RAM | Recommended swap | With hibernation |
|---|---|---|
| ≤ 2 GiB | 2 × RAM | 3 × RAM |
| 2 – 8 GiB | = RAM | 2 × RAM |
| 8 – 64 GiB | 4 GiB – 0.5 × RAM | 1.5 × RAM |
| > 64 GiB | ≥ 4 GiB | Not recommended |

**Hibernation requires `swap ≥ RAM`** because the entire image is written to swap; the kernel needs `resume=UUID=...` on the command line to find it. Servers do not hibernate — do not size for it.

### Why servers still want *some* swap

The common "servers should have zero swap" claim is wrong in a specific, measurable way. Under memory pressure with `swap = 0`, the kernel can only reclaim page cache and clean file-backed pages — including the executable text of running processes. The result is thrashing on `/usr/bin` reads and a hard OOM kill with no warning. A small swap area gives the reclaimer somewhere to put genuinely cold anonymous pages, converting a cliff into a gradient that monitoring can catch.

**Recommendation: 4–8 GiB on servers, `vm.swappiness=10`.** Not zero, not RAM-sized.

```ini
# /etc/sysctl.d/90-swap.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 262144
```

### Swap partition vs swap file vs zram

| | Swap partition | Swap file | zram |
|---|---|---|---|
| Resize | Repartition / `lvextend` | `fallocate` a new one — trivial | `systemctl restart` the generator |
| Performance | Baseline | Equivalent on modern kernels (extent map is cached) | Fastest — RAM, but costs CPU |
| Hibernation | Supported | Supported (needs `resume_offset=`) | **Not supported** |
| On Btrfs | N/A | Requires `nodatacow`, no compression, no snapshots of it | N/A |
| Encryption | Inherits LUKS if under it | Inherits parent FS | N/A (already volatile) |
| Best fit | Traditional servers | Cloud images, post-hoc additions | Laptops, memory-dense edge nodes |

Creating a swap file correctly (`fallocate` can produce an unusable file on some filesystems; `dd` is the safe form on Btrfs):

```bash
$ sudo fallocate -l 8G /swapfile
$ sudo chmod 600 /swapfile
$ sudo mkswap /swapfile
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
no label, UUID=6a3d1b3c-2f4e-4b7a-9c88-1f0a2b3c4d5e
$ sudo swapon /swapfile
$ swapon --show
NAME       TYPE      SIZE USED PRIO
/dev/dm-6  partition   8G   0B   -2
/swapfile  file        8G   0B   -3
```

### Kubernetes / container caveat

`cgroup v2` gives per-container swap accounting (`memory.swap.max`), and kubelet supports swap via `NodeSwap` — but latency-sensitive workloads regress badly when they swap. **On Kubernetes nodes: either disable swap entirely (the traditional requirement) or enable it with `memory.swap.max=0` on guaranteed-QoS pods.** Never leave the node with a large swap area and no per-pod policy.

---

## 8. Alignment and geometry

Misalignment causes **read-modify-write amplification**: a 4 KiB filesystem write that straddles two physical 4 KiB sectors (or two RAID stripe units, or two SSD erase blocks) forces the device to read, merge, and rewrite. The effect is 20–50 % throughput loss and, on flash, proportionally accelerated wear.

**The rule: start every partition on a 1 MiB (2048 × 512 B sectors) boundary.** 1 MiB is divisible by 512 B, 4 KiB, 8 KiB, 64 KiB, 128 KiB, 256 KiB and 512 KiB — so it satisfies 4Kn sectors, RAID stripe units and flash erase blocks simultaneously. All modern tools (`parted -a optimal`, `sgdisk`, `fdisk` ≥ 2.17) do this by default; `sfdisk` from a hand-written offset does not.

Inspecting geometry:

```bash
$ lsblk -o NAME,SIZE,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT,ROTA,DISC-GRAN
NAME          SIZE PHY-SEC LOG-SEC MIN-IO OPT-IO ALIGNMENT ROTA DISC-GRAN
nvme0n1     400G     512     512    512      0         0    0      512B
├─nvme0n1p1   1M     512     512    512      0         0    0      512B
├─nvme0n1p2   1G     512     512    512      0         0    0      512B
├─nvme0n1p3   1G     512     512    512      0         0    0      512B
└─nvme0n1p4 397G     512     512    512      0         0    0      512B
```

`ALIGNMENT 0` means aligned. A non-zero value is the byte offset of the misalignment.

```bash
$ sudo parted /dev/nvme0n1 align-check optimal 4
4 aligned

$ sudo pvs -o pv_name,pe_start,vg_name
  PV             1st PE  VG
  /dev/nvme0n1p4   1.00m  sysvg
```

`1st PE = 1.00m` confirms LVM's data area is itself 1 MiB-aligned. On a RAID array, also align the filesystem to the stripe:

```bash
# 4 data disks, 256 KiB chunk → su=256k, sw=4
$ sudo mkfs.xfs -d su=256k,sw=4 /dev/sysvg/data

# ext4 equivalent: stride = chunk/blocksize = 64, stripe-width = stride * data disks
$ sudo mkfs.ext4 -E stride=64,stripe-width=256 /dev/sysvg/data
```

---

## 9. Reference layouts

### 9.1 General-purpose UEFI server — 400 GiB NVMe, LVM

| # | Device | Size | Type | FS | Mount | Options |
|---|---|---|---|---|---|---|
| 1 | `nvme0n1p1` | 1 MiB | `ef02` | — | — | BIOS boot (dual-firmware insurance) |
| 2 | `nvme0n1p2` | 1 GiB | `ef00` | vfat | `/boot/efi` | `umask=0077,shortname=winnt` |
| 3 | `nvme0n1p3` | 1 GiB | `8300` | ext4 | `/boot` | `nodev,nosuid,noexec` |
| 4 | `nvme0n1p4` | rest | `8e00` | — | — | LVM PV → VG `sysvg` |

| LV | Size | FS | Mount | Options |
|---|---|---|---|---|
| `root` | 20 GiB | xfs | `/` | `defaults` |
| `var` | 30 GiB | xfs | `/var` | `nodev,nosuid` |
| `varlog` | 20 GiB | xfs | `/var/log` | `nodev,nosuid,noexec` |
| `varlogaudit` | 10 GiB | xfs | `/var/log/audit` | `nodev,nosuid,noexec` |
| `vartmp` | 10 GiB | xfs | `/var/tmp` | `nodev,nosuid,noexec` |
| `tmp` | 10 GiB | xfs | `/tmp` | `nodev,nosuid,noexec` |
| `home` | 20 GiB | xfs | `/home` | `nodev,nosuid` |
| `swap` | 8 GiB | swap | — | `pri=10` |
| *(free)* | **~270 GiB** | — | — | **The flexibility budget** |

### 9.2 Kubernetes worker node — two devices

The design intent is that **image and ephemeral-storage pressure can never evict the kubelet or the container runtime's own state**, and that node-level eviction thresholds map onto real, isolated devices.

| Device | Purpose |
|---|---|
| `nvme0n1` | OS: boot chain + `sysvg` (root, var, varlog, swap) |
| `nvme1n1` | `datavg`: `/var/lib/containerd` (imagefs) and `/var/lib/kubelet` (nodefs) |

`/var/lib/containerd` **must** be XFS with `ftype=1` (the default since 2016 — overlayfs refuses to mount otherwise) and `prjquota` if you want per-container ephemeral-storage limits enforced at the filesystem layer.

```bash
$ sudo mkfs.xfs -n ftype=1 -L containerd /dev/datavg/containerd
$ sudo mount -o noatime,prjquota /dev/datavg/containerd /var/lib/containerd
$ xfs_info /var/lib/containerd | grep -E 'ftype|naming'
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
```

### 9.3 Database node (PostgreSQL / MySQL)

| Path | Device | Rationale |
|---|---|---|
| `/` + `/var` | OS SSD | Unremarkable |
| `/var/lib/pgsql/data` | Dedicated NVMe, XFS, `noatime` | Random I/O, needs the whole queue depth |
| `/var/lib/pgsql/wal` (`pg_wal`) | **Separate device** | Sequential fsync-bound; contention here is latency, directly |
| `/backup` | Network or separate spindle | Never on the data device |

WAL/redo separation is not superstition: the WAL path is `fdatasync`-bound and serialised. Sharing a device with random data-file I/O turns every commit into a queue-wait. Measure with:

```bash
$ sudo fio --name=fsync --filename=/var/lib/pgsql/wal/testfile --size=1G \
      --rw=write --bs=8k --fdatasync=1 --numjobs=1 --iodepth=1 --runtime=60 \
      --time_based --group_reporting
...
  fsync/fdatasync/sync_file_range:
    sync (usec): min=112, max=8934, avg=289.44, stdev=143.21
```

An average `fdatasync` above ~1 ms will bound your commit rate regardless of CPU.

### 9.4 Cloud instance — deliberately simple

Cloud images use **a single growable root** because the instance is cattle: the disk is defined by the image, the volume is resized by the API, and `growpart` + `xfs_growfs` run at first boot. Adding LVM to a cloud image adds failure modes with no upside — you resize the EBS/PD volume instead. **Attach separate volumes for data**, never carve the root.

---

## 10. Infrastructure as code — complete manifests

### 10.1 Kickstart (RHEL 9 / Rocky / AlmaLinux) — full file

```kickstart
#version=RHEL9
# Kickstart: hardened UEFI server, GPT + LVM, CIS-aligned filesystem separation.

text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock
user --name=sre --groups=wheel --iscrypted --password=$6$rounds=656000$REPLACEME

network --bootproto=dhcp --device=link --activate
firewall --enabled --service=ssh
selinux --enforcing

bootloader --location=mbr --timeout=5 \
           --append="crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M audit=1 audit_backlog_limit=8192"

# ---------------------------------------------------------------------------
# Disk layout
# ---------------------------------------------------------------------------
ignoredisk --only-use=nvme0n1
clearpart --all --initlabel --drives=nvme0n1 --disklabel=gpt
zerombr

# Boot chain. biosboot is harmless on UEFI and saves the system if the
# platform is ever re-provisioned in CSM mode.
part biosboot  --fstype=biosboot --size=1        --ondisk=nvme0n1
part /boot/efi --fstype=efi      --size=1024     --ondisk=nvme0n1 --fsoptions="umask=0077,shortname=winnt"
part /boot     --fstype=ext4     --size=1024     --ondisk=nvme0n1 --fsoptions="nodev,nosuid,noexec" --label=boot

# Everything else is LVM. Note: --grow on the PV, NOT on the logical volumes.
# Free extents in the VG are the flexibility budget; XFS cannot shrink.
part pv.01     --fstype=lvmpv    --size=10240 --grow --ondisk=nvme0n1
volgroup sysvg --pesize=4096 pv.01

logvol /                --vgname=sysvg --name=root         --fstype=xfs  --size=20480
logvol /home            --vgname=sysvg --name=home         --fstype=xfs  --size=20480 --fsoptions="nodev,nosuid"
logvol /var             --vgname=sysvg --name=var          --fstype=xfs  --size=30720 --fsoptions="nodev,nosuid"
logvol /var/log         --vgname=sysvg --name=varlog       --fstype=xfs  --size=20480 --fsoptions="nodev,nosuid,noexec"
logvol /var/log/audit   --vgname=sysvg --name=varlogaudit  --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol /var/tmp         --vgname=sysvg --name=vartmp       --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol /tmp             --vgname=sysvg --name=tmp          --fstype=xfs  --size=10240 --fsoptions="nodev,nosuid,noexec"
logvol swap             --vgname=sysvg --name=swap         --fstype=swap --size=8192

# ---------------------------------------------------------------------------
%packages
@^minimal-environment
lvm2
xfsprogs
gdisk
parted
cloud-utils-growpart
audit
chrony
-iwl*-firmware
%end

# ---------------------------------------------------------------------------
%post --log=/root/ks-post.log
set -euo pipefail

cat > /etc/sysctl.d/90-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

# /dev/shm hardening — it is a tmpfs mount, not a partition, but the same
# control surface applies.
cat >> /etc/fstab <<'EOF'
tmpfs  /dev/shm  tmpfs  defaults,nodev,nosuid,noexec  0 0
EOF

# Bound journald so /var/log cannot be filled by the journal alone.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-size.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=4G
SystemKeepFree=2G
SystemMaxFileSize=256M
EOF

# Retain exactly 3 kernels so a 1 GiB /boot is provably sufficient.
sed -i 's/^installonly_limit=.*/installonly_limit=3/' /etc/dnf/dnf.conf

# Prove the layout before first login.
findmnt --verify --verbose > /root/fstab-verify.txt 2>&1 || true
%end

reboot --eject
```

### 10.2 cloud-init — growable root plus attached data volumes (complete)

```yaml
#cloud-config
# cloud-init: grow the root volume, then build a dedicated LVM VG on the
# attached data disks for container and kubelet state.
#
# Ordering guarantee: cloud-init runs growpart/resizefs in cc_growpart and
# cc_resizefs (init stage), then disk_setup/fs_setup, then mounts, then
# runcmd (final stage). The LVM work therefore belongs in bootcmd/runcmd.

growpart:
  mode: auto
  devices:
    - /
    - /dev/nvme0n1p4
  ignore_growroot_disabled: false

resize_rootfs: true

# Partition the data disks with a single GPT partition covering the whole
# device. `overwrite: false` makes this idempotent across reboots.
disk_setup:
  /dev/nvme1n1:
    table_type: gpt
    layout: true
    overwrite: false
  /dev/nvme2n1:
    table_type: gpt
    layout: true
    overwrite: false

fs_setup:
  - label: pgwal
    filesystem: xfs
    device: /dev/nvme2n1
    partition: 1
    overwrite: false
    extra_opts:
      - "-n"
      - "ftype=1"

mounts:
  # Field order is the fstab order: device, mountpoint, type, options, dump, pass.
  # nofail + x-systemd.device-timeout prevent a missing volume from dropping
  # the node into the emergency shell on boot.
  - [ "LABEL=pgwal", "/var/lib/pgsql/wal", "xfs",
      "defaults,noatime,nodev,nosuid,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "/dev/datavg/containerd", "/var/lib/containerd", "xfs",
      "defaults,noatime,nodev,nosuid,prjquota,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "/dev/datavg/kubelet", "/var/lib/kubelet", "xfs",
      "defaults,noatime,nodev,nosuid,nofail,x-systemd.device-timeout=15s", "0", "2" ]
  - [ "tmpfs", "/dev/shm", "tmpfs", "defaults,nodev,nosuid,noexec", "0", "0" ]

mount_default_fields: [ None, None, "auto", "defaults,nofail", "0", "2" ]

swap:
  filename: /swapfile
  size: 8589934592          # 8 GiB, in bytes
  maxsize: 8589934592

packages:
  - lvm2
  - xfsprogs
  - gdisk
  - cloud-utils-growpart

write_files:
  - path: /etc/sysctl.d/90-swap.conf
    permissions: "0644"
    content: |
      vm.swappiness = 10
      vm.vfs_cache_pressure = 50

  - path: /etc/systemd/journald.conf.d/00-size.conf
    permissions: "0644"
    content: |
      [Journal]
      Storage=persistent
      SystemMaxUse=4G
      SystemKeepFree=2G

  - path: /usr/local/sbin/setup-datavg.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      # Idempotent construction of the container/kubelet volume group.
      set -euo pipefail

      DISK=/dev/nvme1n1p1
      VG=datavg

      # Bail out cleanly if the VG already exists — this script runs on every
      # boot via runcmd and must be safe to repeat.
      if vgs "${VG}" >/dev/null 2>&1; then
        echo "VG ${VG} already present; nothing to do."
        exit 0
      fi

      [ -b "${DISK}" ] || { echo "FATAL: ${DISK} is not a block device"; exit 1; }

      # 1 MiB data alignment; explicit, not inherited from defaults.
      pvcreate --dataalignment 1m "${DISK}"
      vgcreate --physicalextentsize 4m "${VG}" "${DISK}"

      # Allocate conservatively: 40 % containerd, 20 % kubelet, 40 % held back.
      lvcreate --name containerd --extents 40%VG "${VG}"
      lvcreate --name kubelet    --extents 20%VG "${VG}"

      # ftype=1 is mandatory for overlayfs; prjquota enables per-container
      # ephemeral-storage enforcement.
      mkfs.xfs -n ftype=1 -L containerd "/dev/${VG}/containerd"
      mkfs.xfs -n ftype=1 -L kubelet    "/dev/${VG}/kubelet"

      echo "Volume group ${VG} created:"
      vgs "${VG}"
      lvs "${VG}"

bootcmd:
  # Ensure device-mapper nodes exist before anything references them.
  - [ modprobe, dm_mod ]

runcmd:
  - [ /usr/local/sbin/setup-datavg.sh ]
  - [ systemctl, daemon-reload ]
  - [ mkdir, -p, /var/lib/containerd, /var/lib/kubelet, /var/lib/pgsql/wal ]
  - [ mount, -a ]
  - [ sysctl, --system ]
  # Fail the boot loudly rather than silently if fstab is inconsistent.
  - [ findmnt, --verify, --verbose ]

final_message: "Disk layout converged after $UPTIME seconds."
```

### 10.3 Butane (Fedora CoreOS / RHEL CoreOS) — compiled to Ignition

Ignition runs in the initramfs, **before** the root filesystem is mounted — it is the only mechanism that can repartition the boot disk of an image-based system.

```yaml
variant: fcos
version: 1.5.0

storage:
  disks:
    # Repartition the boot disk: shrink the image's root partition to 20 GiB
    # and carve dedicated partitions from the remainder.
    - device: /dev/disk/by-id/coreos-boot-disk
      wipe_table: false
      partitions:
        - label: root
          number: 4
          size_mib: 20480
          resize: true
        - label: var
          size_mib: 40960
          start_mib: 0            # 0 = "immediately after the previous partition"
          type_guid: 4D21B016-B534-45C2-A9FB-5C16E091FD2D   # DPS: /var
        - label: varlog
          size_mib: 20480
          start_mib: 0
        - label: containers
          size_mib: 0             # 0 = "use all remaining space"
          start_mib: 0

  filesystems:
    - device: /dev/disk/by-partlabel/var
      format: xfs
      label: var
      wipe_filesystem: false
      with_mount_unit: true
      path: /var
      options:
        - -n
        - ftype=1

    - device: /dev/disk/by-partlabel/varlog
      format: xfs
      label: varlog
      wipe_filesystem: false
      with_mount_unit: true
      path: /var/log

    - device: /dev/disk/by-partlabel/containers
      format: xfs
      label: containers
      wipe_filesystem: false
      with_mount_unit: false      # mounted by the explicit unit below
      options:
        - -n
        - ftype=1

  files:
    - path: /etc/sysctl.d/90-swap.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          vm.swappiness = 10
          vm.vfs_cache_pressure = 50

    - path: /etc/systemd/journald.conf.d/00-size.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [Journal]
          Storage=persistent
          SystemMaxUse=4G
          SystemKeepFree=2G

systemd:
  units:
    # prjquota must be set at mount time; it cannot be enabled on a
    # mounted XFS filesystem.
    - name: var-lib-containers.mount
      enabled: true
      contents: |
        [Unit]
        Description=Container storage (XFS with project quota)
        Before=local-fs.target
        Requires=systemd-fsck@dev-disk-by\x2dpartlabel-containers.service
        After=systemd-fsck@dev-disk-by\x2dpartlabel-containers.service

        [Mount]
        What=/dev/disk/by-partlabel/containers
        Where=/var/lib/containers
        Type=xfs
        Options=defaults,noatime,nodev,nosuid,prjquota

        [Install]
        WantedBy=local-fs.target

    - name: swap-on-zram.service
      enabled: true
      contents: |
        [Unit]
        Description=Enable zram-backed swap
        After=local-fs.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/modprobe zram num_devices=1
        ExecStart=/usr/bin/sh -c 'echo zstd > /sys/block/zram0/comp_algorithm'
        ExecStart=/usr/bin/sh -c 'echo 8G > /sys/block/zram0/disksize'
        ExecStart=/usr/sbin/mkswap /dev/zram0
        ExecStart=/usr/sbin/swapon --priority 100 /dev/zram0
        ExecStop=/usr/sbin/swapoff /dev/zram0

        [Install]
        WantedBy=multi-user.target
```

Compile and validate before deploying — a bad Ignition config bricks the first boot with no shell:

```bash
$ butane --pretty --strict layout.bu --output layout.ign
$ ignition-validate layout.ign
$ echo $?
0
```

### 10.4 Ansible — converge and verify an existing fleet (complete playbook)

```yaml
---
- name: Converge disk layout on application nodes
  hosts: app_nodes
  become: true

  vars:
    sysvg_name: sysvg
    data_disk: /dev/nvme1n1
    datavg_name: datavg
    # Conservative allocations. XFS cannot shrink, so the unassigned
    # remainder of the VG is the only flexibility we will ever have.
    logical_volumes:
      - { name: containerd, size: 40%VG, fs: xfs, mount: /var/lib/containerd,
          opts: "defaults,noatime,nodev,nosuid,prjquota" }
      - { name: kubelet,    size: 20%VG, fs: xfs, mount: /var/lib/kubelet,
          opts: "defaults,noatime,nodev,nosuid" }

  tasks:
    - name: Install storage tooling
      ansible.builtin.package:
        name:
          - lvm2
          - xfsprogs
          - gdisk
          - parted
        state: present

    - name: Gather block device facts
      ansible.builtin.setup:
        gather_subset:
          - hardware

    - name: Refuse to run if the data disk is absent
      ansible.builtin.assert:
        that:
          - data_disk | basename in ansible_devices
        fail_msg: >-
          {{ data_disk }} is not present on {{ inventory_hostname }}.
          Attach the volume before running this play.

    - name: Create a single GPT partition spanning the data disk
      community.general.parted:
        device: "{{ data_disk }}"
        label: gpt
        number: 1
        part_start: 1MiB          # explicit 1 MiB alignment
        part_end: 100%
        flags: [ lvm ]
        state: present

    - name: Create the physical volume and volume group
      community.general.lvg:
        vg: "{{ datavg_name }}"
        pvs: "{{ data_disk }}1"
        pesize: 4
        state: present

    - name: Create logical volumes
      community.general.lvol:
        vg: "{{ datavg_name }}"
        lv: "{{ item.name }}"
        size: "{{ item.size }}"
        state: present
        # shrink: false is a safety interlock — never let a play shrink an LV
        # out from under a mounted XFS filesystem.
        shrink: false
      loop: "{{ logical_volumes }}"

    - name: Create filesystems
      community.general.filesystem:
        fstype: "{{ item.fs }}"
        dev: "/dev/{{ datavg_name }}/{{ item.name }}"
        # ftype=1 is required by overlayfs; it is the default but we assert it.
        opts: "{{ '-n ftype=1' if item.fs == 'xfs' else omit }}"
        resizefs: true
      loop: "{{ logical_volumes }}"

    - name: Mount filesystems and persist them in fstab
      ansible.posix.mount:
        path: "{{ item.mount }}"
        src: "/dev/{{ datavg_name }}/{{ item.name }}"
        fstype: "{{ item.fs }}"
        opts: "{{ item.opts }},nofail,x-systemd.device-timeout=15s"
        dump: "0"
        passno: "2"
        state: mounted
      loop: "{{ logical_volumes }}"

    - name: Harden /dev/shm
      ansible.posix.mount:
        path: /dev/shm
        src: tmpfs
        fstype: tmpfs
        opts: defaults,nodev,nosuid,noexec
        state: mounted

    - name: Bound the journal so /var/log cannot self-fill
      ansible.builtin.copy:
        dest: /etc/systemd/journald.conf.d/00-size.conf
        mode: "0644"
        content: |
          [Journal]
          Storage=persistent
          SystemMaxUse=4G
          SystemKeepFree=2G
      notify: Restart journald

    - name: Apply swap tuning
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.d/90-swap.conf
        reload: true
      loop:
        - { key: vm.swappiness, value: "10" }
        - { key: vm.vfs_cache_pressure, value: "50" }

    # -----------------------------------------------------------------------
    # Verification — a converge that is not verified is a hope, not a change.
    # -----------------------------------------------------------------------
    - name: Verify fstab is internally consistent
      ansible.builtin.command: findmnt --verify --verbose
      register: fstab_verify
      changed_when: false
      failed_when: fstab_verify.rc != 0

    - name: Verify every partition is optimally aligned
      ansible.builtin.command: "parted {{ data_disk }} align-check optimal 1"
      register: align
      changed_when: false
      failed_when: "'aligned' not in align.stdout"

    - name: Verify XFS ftype is enabled on container storage
      ansible.builtin.command: xfs_info /var/lib/containerd
      register: xfsinfo
      changed_when: false
      failed_when: "'ftype=1' not in xfsinfo.stdout"

    - name: Verify /boot has headroom for at least two more kernels
      ansible.builtin.shell: >-
        set -o pipefail;
        df --output=avail -m /boot | tail -n1
      args:
        executable: /bin/bash
      register: boot_avail
      changed_when: false
      failed_when: (boot_avail.stdout | trim | int) < 400

    - name: Report the converged layout
      ansible.builtin.debug:
        msg: "{{ fstab_verify.stdout_lines }}"

  handlers:
    - name: Restart journald
      ansible.builtin.systemd:
        name: systemd-journald
        state: restarted
```

### 10.5 Kubernetes — surfacing the layout to the scheduler

The node's disk design only pays off if the control plane knows about it. A dedicated device becomes a `local` PersistentVolume with node affinity, and eviction thresholds are set against the real filesystems.

```yaml
---
# The storage class that binds local volumes lazily, so the scheduler picks
# the node first and the volume second.
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: false
---
# One PV per physical device per node. The path must be a mount point, not a
# directory inside another filesystem, or capacity accounting is a fiction.
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-node01-pgdata
  labels:
    topology.kubernetes.io/zone: rack-a
spec:
  capacity:
    storage: 1600Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    path: /mnt/disks/nvme3n1
    fsType: xfs
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - node01
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgdata
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-nvme
  resources:
    requests:
      storage: 1600Gi
---
# Kubelet configuration. imagefs.* refers to the container runtime's
# filesystem (/var/lib/containerd); nodefs.* to the kubelet's
# (/var/lib/kubelet). Separating those devices is what makes these two sets
# of thresholds independently meaningful.
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
  imagefs.inodesFree: "5%"
evictionSoft:
  nodefs.available: "15%"
  imagefs.available: "20%"
evictionSoftGracePeriod:
  nodefs.available: "2m"
  imagefs.available: "2m"
evictionMinimumReclaim:
  nodefs.available: "5%"
  imagefs.available: "5%"
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
# Requires XFS with prjquota on the kubelet and containerd filesystems.
featureGates:
  LocalStorageCapacityIsolationFSQuotaMonitoring: true
```

---

## 11. CLI walkthrough — building the layout by hand

### 11.1 Survey before you touch anything

```bash
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
NAME        SIZE TYPE FSTYPE LABEL MOUNTPOINTS MODEL
nvme0n1     400G disk                          SAMSUNG MZQL2400HCJR
nvme1n1     800G disk                          SAMSUNG MZQL2800HCJR

$ sudo lsblk -f
NAME    FSTYPE FSVER LABEL UUID FSAVAIL FSUSE% MOUNTPOINTS
nvme0n1
nvme1n1

$ sudo fdisk -l /dev/nvme0n1
Disk /dev/nvme0n1: 400 GiB, 429496729600 bytes, 838860800 sectors
Disk model: SAMSUNG MZQL2400HCJR
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
```

Confirm the firmware mode — this decides the whole boot section:

```bash
$ [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS/CSM"
UEFI

$ cat /sys/firmware/efi/fw_platform_size
64
```

### 11.2 Partition with `sgdisk` (scriptable, idempotent, exact)

```bash
# Destroy any existing table, both primary and backup GPT headers.
$ sudo sgdisk --zap-all /dev/nvme0n1
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.

# Clear filesystem signatures that would otherwise confuse blkid/udev.
$ sudo wipefs -a /dev/nvme0n1

# Build the table. -a 2048 sets 1 MiB alignment explicitly.
$ sudo sgdisk -a 2048 \
    -n 1:0:+1M     -t 1:ef02 -c 1:"BIOS boot"  \
    -n 2:0:+1G     -t 2:ef00 -c 2:"EFI System" \
    -n 3:0:+1G     -t 3:8300 -c 3:"boot"       \
    -n 4:0:0       -t 4:8e00 -c 4:"LVM PV"     \
    /dev/nvme0n1
Setting name!
partNum is 0
Setting name!
partNum is 1
Setting name!
partNum is 2
Setting name!
partNum is 3
The operation has completed successfully.

$ sudo partprobe /dev/nvme0n1

$ sudo sgdisk -p /dev/nvme0n1
Disk /dev/nvme0n1: 838860800 sectors, 400.0 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 3F2A9C41-7B8E-4D5F-A1C3-9E0B4D6F8A2C
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 838860766
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048            4095   1024.0 KiB  EF02  BIOS boot
   2            4096         2101247   1024.0 MiB  EF00  EFI System
   3         2101248         4198399   1024.0 MiB  8300  boot
   4         4198400       838860766   398.0 GiB   8E00  LVM PV

$ sudo parted /dev/nvme0n1 align-check optimal 4
4 aligned
```

### 11.3 Filesystems for the boot chain

```bash
$ sudo mkfs.vfat -F 32 -n EFI /dev/nvme0n1p2
mkfs.fat 4.2 (2021-01-31)

$ sudo mkfs.ext4 -L boot /dev/nvme0n1p3
mke2fs 1.46.5 (30-Dec-2021)
Creating filesystem with 262144 4k blocks and 65536 inodes
Filesystem UUID: 8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a
Superblock backups stored on blocks:
	32768, 98304, 163840, 229376

Allocating group tables: done
Writing inode tables: done
Creating journal (8192 blocks): done
Writing superblocks and filesystem accounting information: done
```

### 11.4 LVM stack

```bash
$ sudo pvcreate --dataalignment 1m /dev/nvme0n1p4
  Physical volume "/dev/nvme0n1p4" successfully created.

$ sudo vgcreate --physicalextentsize 4m sysvg /dev/nvme0n1p4
  Volume group "sysvg" successfully created

$ sudo vgdisplay sysvg
  --- Volume group ---
  VG Name               sysvg
  System ID
  Format                lvm2
  Metadata Areas        1
  Metadata Sequence No  1
  VG Access             read/write
  VG Status             resizable
  MAX LV                0
  Cur LV                0
  Open LV               0
  Max PV                0
  Cur PV                1
  Act PV                1
  VG Size               <398.00 GiB
  PE Size               4.00 MiB
  Total PE              101887
  Alloc PE / Size       0 / 0
  Free  PE / Size       101887 / <398.00 GiB
  VG UUID               kTf2Yq-9dZa-Lm4X-p1Bs-7RnC-vE8H-3jQwPl
```

Create the logical volumes — deliberately small, leaving the bulk unassigned:

```bash
$ sudo lvcreate -L 20G  -n root        sysvg
  Logical volume "root" created.
$ sudo lvcreate -L 30G  -n var         sysvg
  Logical volume "var" created.
$ sudo lvcreate -L 20G  -n varlog      sysvg
  Logical volume "varlog" created.
$ sudo lvcreate -L 10G  -n varlogaudit sysvg
  Logical volume "varlogaudit" created.
$ sudo lvcreate -L 10G  -n vartmp      sysvg
  Logical volume "vartmp" created.
$ sudo lvcreate -L 10G  -n tmp         sysvg
  Logical volume "tmp" created.
$ sudo lvcreate -L 20G  -n home        sysvg
  Logical volume "home" created.
$ sudo lvcreate -L 8G   -n swap        sysvg
  Logical volume "swap" created.

$ sudo lvs -o lv_name,lv_size,vg_name,devices sysvg
  LV          LSize  VG    Devices
  home        20.00g sysvg /dev/nvme0n1p4(20480)
  root        20.00g sysvg /dev/nvme0n1p4(0)
  swap         8.00g sysvg /dev/nvme0n1p4(25600)
  tmp         10.00g sysvg /dev/nvme0n1p4(17920)
  var         30.00g sysvg /dev/nvme0n1p4(5120)
  varlog      20.00g sysvg /dev/nvme0n1p4(12800)
  varlogaudit 10.00g sysvg /dev/nvme0n1p4(15360)
  vartmp      10.00g sysvg /dev/nvme0n1p4(15360)

$ sudo vgs sysvg
  VG    #PV #LV #SN Attr   VSize    VFree
  sysvg   1   8   0 wz--n- <398.00g <270.00g
```

`VFree <270.00g` is the number that matters. That is how much you can hand to whichever filesystem turns out to need it, online, with no downtime.

```bash
$ for lv in root var varlog varlogaudit vartmp tmp home; do
    sudo mkfs.xfs -f -L "$lv" "/dev/sysvg/$lv"
  done
meta-data=/dev/sysvg/root        isize=512    agcount=4, agsize=1310720 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=1, rmapbt=0
         =                       reflink=1    bigtime=1 inobtcount=1 nrext64=0
data     =                       bsize=4096   blocks=5242880, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0, ftype=1
log      =internal log           bsize=4096   blocks=16384, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
...

$ sudo mkswap -L swap /dev/sysvg/swap
Setting up swapspace version 1, size = 8 GiB (8589930496 bytes)
LABEL=swap, UUID=b4e7d219-6c3a-4f81-9d02-7a5e1c8b3f46
```

### 11.5 The resulting `/etc/fstab`

Always mount by UUID or LV device path — never by kernel name (`/dev/sda3`), which is enumeration-order dependent and will silently swap under you after a controller change.

```bash
$ sudo blkid
/dev/nvme0n1p2: SEC_TYPE="msdos" LABEL_FATBOOT="EFI" LABEL="EFI" UUID="A1B2-C3D4" BLOCK_SIZE="512" TYPE="vfat" PARTLABEL="EFI System" PARTUUID="7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41"
/dev/nvme0n1p3: LABEL="boot" UUID="8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a" BLOCK_SIZE="4096" TYPE="ext4" PARTLABEL="boot" PARTUUID="e5a92c7b-1d64-4837-b0f2-9c3e8a1d5b60"
/dev/nvme0n1p4: UUID="P3xK9m-2Vqa-Lc7T-8sYn-4Bde-1WfR-6jHgZo" TYPE="LVM2_member" PARTLABEL="LVM PV" PARTUUID="c8f14b23-9e05-4a7d-8b36-1f2c9d5e7a04"
```

```fstab
# /etc/fstab
#
# <device>                      <mount point>      <type>  <options>                                        <dump> <pass>

/dev/mapper/sysvg-root          /                  xfs     defaults                                              0  0
UUID=8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a  /boot   ext4    defaults,nodev,nosuid,noexec                          0  2
UUID=A1B2-C3D4                  /boot/efi          vfat    umask=0077,shortname=winnt,nodev,nosuid,noexec        0  2

/dev/mapper/sysvg-home          /home              xfs     defaults,nodev,nosuid                                 0  0
/dev/mapper/sysvg-var           /var               xfs     defaults,nodev,nosuid                                 0  0
/dev/mapper/sysvg-varlog        /var/log           xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-varlogaudit   /var/log/audit     xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-vartmp        /var/tmp           xfs     defaults,nodev,nosuid,noexec                          0  0
/dev/mapper/sysvg-tmp           /tmp               xfs     defaults,nodev,nosuid,noexec                          0  0

/dev/mapper/sysvg-swap          none               swap    defaults,pri=10                                       0  0
tmpfs                           /dev/shm           tmpfs   defaults,nodev,nosuid,noexec                          0  0
```

**Field semantics — the two columns candidates get wrong:**

| Field | Meaning |
|---|---|
| `<dump>` | Legacy `dump(8)` flag. **Always `0`** on modern systems. |
| `<pass>` | `fsck` order at boot: `0` = never check, `1` = the root filesystem only, `2` = everything else, checked in parallel across devices. **XFS ignores this** (it journals and repairs at mount); ext4 honours it. Non-zero on `/` for any non-ext filesystem is meaningless but harmless. |

**Ordering does not matter for correctness on `systemd`** — `systemd-fstab-generator` builds `.mount` units and derives dependencies from the path hierarchy, so `/var/log` is ordered after `/var` automatically. Keep the file hierarchically ordered anyway; a human reads it during an incident.

### 11.6 Growing a filesystem online — the payoff

```bash
$ df -h /var/log
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog        20G   17G  3.1G  85% /var/log

# -r (--resizefs) extends the LV and then the filesystem in one atomic step.
$ sudo lvextend -L +30G -r /dev/sysvg/varlog
  Size of logical volume sysvg/varlog changed from 20.00 GiB (5120 extents) to 50.00 GiB (12800 extents).
  Logical volume sysvg/varlog successfully resized.
meta-data=/dev/mapper/sysvg-varlog isize=512    agcount=4, agsize=1310720 blks
data     =                       bsize=4096   blocks=5242880, imaxpct=25
...
data blocks changed from 5242880 to 13107200

$ df -h /var/log
Filesystem                     Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog        50G   17G   33G  35% /var/log
```

Zero downtime, zero unmounts, one command. This is the entire argument for LVM.

Adding a whole new disk to an existing VG:

```bash
$ sudo pvcreate /dev/nvme1n1
  Physical volume "/dev/nvme1n1" successfully created.
$ sudo vgextend sysvg /dev/nvme1n1
  Volume group "sysvg" successfully extended.
$ sudo vgs sysvg
  VG    #PV #LV #SN Attr   VSize   VFree
  sysvg   2   8   0 wz--n-  <1.17t <1.01t
```

Evacuating a failing disk with everything mounted:

```bash
$ sudo pvmove /dev/nvme0n1p4 /dev/nvme1n1
  /dev/nvme0n1p4: Moved: 0.02%
  /dev/nvme0n1p4: Moved: 14.37%
  /dev/nvme0n1p4: Moved: 61.88%
  /dev/nvme0n1p4: Moved: 100.00%
$ sudo vgreduce sysvg /dev/nvme0n1p4
  Removed "/dev/nvme0n1p4" from volume group "sysvg"
```

### 11.7 Growing a cloud root volume after an API-side resize

```bash
$ lsblk /dev/nvme0n1
NAME        MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0 200G  0 disk
├─nvme0n1p1 259:1    0   1M  0 part
├─nvme0n1p2 259:2    0 200M  0 part /boot/efi
└─nvme0n1p3 259:3    0  50G  0 part /

# The partition table still describes the old size. growpart rewrites it.
$ sudo growpart /dev/nvme0n1 3
CHANGED: partition=3 start=411648 old: size=104445952 end=104857599 new: size=418942943 end=419354590

$ sudo xfs_growfs /
meta-data=/dev/nvme0n1p3         isize=512    agcount=4, agsize=3276800 blks
data     =                       bsize=4096   blocks=13107200, imaxpct=25
data blocks changed from 13107200 to 52367867

$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  200G  4.1G  196G   3% /
```

For ext4 the second step is `sudo resize2fs /dev/nvme0n1p3`. Note the asymmetry in tool naming: **`xfs_growfs` takes a mount point, `resize2fs` takes a device.**

---

## 12. Verification and failure diagnosis

### 12.1 The pre-reboot checklist

**A layout is not correct until it has survived a reboot. Verify before you take that risk.**

```bash
# 1. Is fstab internally consistent? Every UUID resolvable, every mount point
#    present, every option parseable? This is the single highest-value check.
$ findmnt --verify --verbose
/
   [ ] target exists
   [ ] FS options: defaults
/boot
   [ ] target exists
   [ ] UUID=8c1f4a2e-3b7d-4e69-9a05-2f8c1d4b6e3a translated to /dev/nvme0n1p3
   [ ] FS options: defaults,nodev,nosuid,noexec
...
Success, no errors or warnings detected

# 2. Do the generated systemd mount units parse?
$ systemd-analyze verify default.target
$ sudo systemctl daemon-reload && systemctl --failed
0 loaded units listed.

# 3. Are all mounts actually up right now, matching fstab?
$ findmnt --fstab --evaluate
$ mount -a && echo "mount -a clean"
mount -a clean

# 4. Is the boot chain intact?
$ bootctl status
System:
      Firmware: UEFI 2.70 (American Megatrends 5.19)
 Firmware Arch: x64
   Secure Boot: enabled (user)
  TPM2 Support: yes
  Measured UKI: no
  Boot into FW: supported

Current Boot Loader:
      Product: GRUB 2.06
     Features: ✗ Boot counting
   ESP: /dev/disk/by-partuuid/7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41
  File: └─/EFI/rocky/shimx64.efi

$ efibootmgr -v
BootCurrent: 0000
Timeout: 5 seconds
BootOrder: 0000,0001
Boot0000* Rocky Linux	HD(2,GPT,7d3e1f92-4a8b-4c65-9e10-2b7f5a3c8d41,0x1000,0x200000)/File(\EFI\rocky\shimx64.efi)
Boot0001* UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x4)/...

# 5. Does /boot actually have the kernels it claims?
$ ls -lh /boot/vmlinuz-* /boot/initramfs-*
-rw-------. 1 root root  48M Aug 12 09:14 /boot/initramfs-5.14.0-427.el9.x86_64.img
-rw-------. 1 root root  48M Aug 19 11:02 /boot/initramfs-5.14.0-503.el9.x86_64.img
-rwxr-xr-x. 1 root root  13M Aug 12 09:11 /boot/vmlinuz-5.14.0-427.el9.x86_64
-rwxr-xr-x. 1 root root  13M Aug 19 10:58 /boot/vmlinuz-5.14.0-503.el9.x86_64

$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  974M  283M  624M  32% /boot
```

### 12.2 Failure catalogue

---

**Symptom: boot hangs ~90 s, then drops to `emergency mode`.**

```
[  *** ] A start job is running for /dev/disk/by-uuid/8c1f4a2e-... (1min 29s / 1min 30s)
[DEPEND] Dependency failed for /var/log.
[DEPEND] Dependency failed for Local File Systems.
You are in emergency mode. After logging in, type "journalctl -xb" to view
system logs, "systemctl reboot" to reboot, or "exit" to continue to boot.
Give root password for maintenance:
```

**Cause.** An `/etc/fstab` entry references a device that does not exist — a typo'd UUID, a filesystem recreated (`mkfs` assigns a *new* UUID), or a volume not attached. `systemd` waits `DefaultTimeoutStartSec` (90 s) for the device, then fails `local-fs.target`.

**Diagnosis and repair.**

```bash
# Root filesystem is mounted read-only at this point.
$ mount -o remount,rw /
$ journalctl -xb -p err
$ systemctl list-units --failed
  UNIT                  LOAD   ACTIVE SUB    DESCRIPTION
● var-log.mount         loaded failed failed /var/log

$ systemctl status var-log.mount
$ blkid | grep -i varlog      # the actual, current UUID
$ vi /etc/fstab               # correct it
$ systemctl daemon-reload
$ mount -a
$ findmnt --verify
$ systemctl default
```

**Prevention.** Add `nofail,x-systemd.device-timeout=15s` to every non-essential mount. A data volume must never be able to prevent the node from booting and being reachable over SSH — you cannot fix what you cannot log into.

---

**Symptom: `/boot` is full; a kernel upgrade "succeeded" but the system will not boot.**

```
$ sudo dnf install kernel
...
Error: Transaction test error:
  installing package kernel-core-5.14.0-503.el9.x86_64 needs 92MB on the /boot filesystem
```

Or worse — it *appears* to succeed and `dracut` writes a truncated initramfs. At boot:

```
dracut-initqueue[521]: Warning: dracut-initqueue: timeout, still waiting for following initqueue hooks:
dracut-initqueue[521]: Warning: /lib/dracut/hooks/initqueue/finished/devexists-...sh
Generating "/run/initramfs/rdsosreport.txt"
dracut:/#
```

**Diagnosis.**

```bash
$ df -h /boot
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  488M  461M   -3M 101% /boot

$ ls -1 /boot/vmlinuz-*
/boot/vmlinuz-5.14.0-284.el9.x86_64
/boot/vmlinuz-5.14.0-362.el9.x86_64
/boot/vmlinuz-5.14.0-427.el9.x86_64
/boot/vmlinuz-5.14.0-503.el9.x86_64
/boot/vmlinuz-5.14.0-570.el9.x86_64
```

**Repair.**

```bash
# Remove old kernels — RHEL family
$ sudo dnf remove --oldinstallonly --setopt installonly_limit=2 kernel

# Debian/Ubuntu
$ sudo apt-get --purge autoremove

# Rebuild the current initramfs to be sure it is complete
$ sudo dracut --force --verbose /boot/initramfs-$(uname -r).img $(uname -r)
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg     # RHEL BIOS
$ sudo update-grub                                 # Debian/Ubuntu
```

**Prevention.** 1 GiB `/boot`, `installonly_limit=3`, and a monitoring alert at 70 % on `/boot` specifically — not just on `/`.

---

**Symptom: "No space left on device" but `df` shows free space.**

```bash
$ df -h /var/lib/kubelet
Filesystem                  Size  Used Avail Use% Mounted on
/dev/mapper/datavg-kubelet  160G   58G  103G  36% /var/lib/kubelet

$ touch /var/lib/kubelet/x
touch: cannot touch '/var/lib/kubelet/x': No space left on device
```

**Cause: inode exhaustion.** Millions of small files (container layers, emptyDir volumes, per-pod log files) consumed every inode while barely touching the block count.

```bash
$ df -i /var/lib/kubelet
Filesystem                    Inodes   IUsed IFree IUse% Mounted on
/dev/mapper/datavg-kubelet  83886080 83886080     0  100% /var/lib/kubelet
```

**Why XFS makes this less common but not impossible.** XFS allocates inodes dynamically, so it rarely exhausts them — *unless* `imaxpct` (default 25 %) caps inode space, or the filesystem is 32-bit-inode constrained. ext4 allocates inodes **statically at `mkfs` time** and cannot add more, ever.

```bash
# ext4: choose the ratio at creation. Default bytes-per-inode is 16384.
$ sudo mkfs.ext4 -i 4096 -L manyfiles /dev/datavg/kubelet   # 4x the inodes

# XFS: raise the inode percentage cap online
$ sudo xfs_growfs -m 50 /var/lib/kubelet
```

**Prevention.** Alert on `df -i` alongside `df -h`. Use XFS for any path holding container layers or mail spools.

---

**Symptom: `df` says 95 % full; `du` accounts for only 40 %.**

```bash
$ df -h /var/log
Filesystem                Size  Used Avail Use% Mounted on
/dev/mapper/sysvg-varlog   20G   19G  1.1G  95% /var/log

$ sudo du -sh /var/log
7.8G	/var/log
```

**Cause: deleted-but-still-open files.** A log rotation removed a file that a process still holds open. The directory entry is gone (`du` cannot see it), but the inode and its extents persist until the last descriptor closes.

```bash
$ sudo lsof +L1 /var/log
COMMAND     PID USER   FD   TYPE DEVICE   SIZE/OFF NLINK  NODE NAME
java     284917  app    3w   REG  253,3 11274289152     0 17301504 /var/log/app/application.log (deleted)

# Reclaim without a restart, if you must:
$ sudo truncate -s 0 /proc/284917/fd/3

# Correct fix: make logrotate signal the process.
```

```
# /etc/logrotate.d/app
/var/log/app/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate      # or: postrotate <signal the process> endscript
    su root app
}
```

---

**Symptom: "I need to shrink `/home` and give the space to `/var`." XFS.**

There is no shrink. The procedure is backup → destroy → recreate → restore:

```bash
$ sudo systemctl isolate rescue.target
$ sudo xfsdump -l 0 -f /mnt/backup/home.dump /home
$ sudo umount /home
$ sudo lvremove /dev/sysvg/home
$ sudo lvcreate -L 10G -n home sysvg
$ sudo mkfs.xfs -L home /dev/sysvg/home
$ sudo mount /home
$ sudo xfsrestore -f /mnt/backup/home.dump /home
$ sudo lvextend -L +10G -r /dev/sysvg/var
```

Downtime for `/home`, a full restore, and risk — all to reclaim 10 GiB. **This is why you allocate conservatively and leave free extents.** The mistake was made at install time, not today.

---

**Symptom: sequential throughput is roughly half of what the device is rated for.**

```bash
$ lsblk -o NAME,ALIGNMENT,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO /dev/sdb
NAME ALIGNMENT PHY-SEC LOG-SEC MIN-IO OPT-IO
sdb          0    4096     512   4096      0
└─sdb1    3584    4096     512   4096      0     ← misaligned by 3584 bytes
```

**Cause.** The partition starts at sector 63 (legacy CHS alignment) on a 4Kn/512e device. Every filesystem block straddles two physical sectors, forcing read-modify-write.

**Repair.** There is no in-place fix — the partition start must move, which means data movement. Back up, repartition with `sgdisk -a 2048`, restore. On a RAID array also verify the filesystem's stripe geometry:

```bash
$ xfs_info /data | grep -E 'sunit|swidth'
data     =                       bsize=4096   blocks=524288000, imaxpct=5
         =                       sunit=64     swidth=256 blks
```

`sunit=0 swidth=0` on a RAID array means the filesystem is unaware of the stripe. Correct at mount time as a partial mitigation:

```bash
$ sudo mount -o remount,sunit=128,swidth=512 /data
```

---

**Symptom: an LVM thin pool reached 100 %.**

```
$ dmesg | tail
[92841.221] device-mapper: thin: 253:5: reached low water mark for data device: sending event.
[92903.774] device-mapper: thin: 253:5: switching pool to out-of-data-space mode
[93083.918] device-mapper: thin: 253:5: switching pool to read-only mode
[93083.921] EXT4-fs error (device dm-7): ext4_journal_check_start: Detected aborted journal
```

**Diagnosis and immediate action.**

```bash
$ sudo lvs -o lv_name,lv_size,data_percent,metadata_percent,pool_lv
  LV        LSize    Data%  Meta%  Pool
  thinpool  500.00g  100.00 62.14
  vm01       200.00g  99.87        thinpool
  vm02       200.00g  98.02        thinpool
  vm03       200.00g  97.55        thinpool

# Add physical capacity to the pool NOW.
$ sudo lvextend -L +200G /dev/vg0/thinpool
$ sudo lvchange -ay vg0/vm01
$ sudo fsck -y /dev/vg0/vm01
```

Note `Meta% 62.14` — the **metadata** LV can exhaust independently of the data LV and is the harder failure. Extend it separately with `lvextend --poolmetadatasize`.

**Prevention.** `thin_pool_autoextend_threshold = 70` in `lvm.conf`, monitoring on `data_percent` **and** `metadata_percent`, and never thin-provisioning a production OS filesystem.

---

**Symptom: `Invalid partition table` / GPT header corruption.**

```bash
$ sudo gdisk /dev/sdb
GPT fdisk (gdisk) version 1.0.9

Caution: invalid main GPT header, but valid backup; regenerating main header
from backup!

Warning: Invalid CRC on main header data; loaded backup partition table.
Proceed? (Y/N):
```

This is GPT's redundancy earning its keep — the backup header at the last LBA reconstructs the primary. Repair:

```bash
$ sudo sgdisk --verify /dev/sdb
Problem: The secondary header's self-pointer indicates that it doesn't reside
at the end of the disk. Using -e to fix.

# Move the backup header to the true end (needed after a device grows)
$ sudo sgdisk -e /dev/sdb
Warning: The kernel is still using the old partition table.
The new table will be used at the next reboot or after you run partprobe(8).
The operation has completed successfully.

$ sudo partprobe /dev/sdb
```

---

### 12.3 Diagnostic command reference

| Question | Command |
|---|---|
| Device tree, sizes, filesystems, mounts | `lsblk -f` / `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS` |
| Sector sizes, alignment, I/O hints | `lsblk -o NAME,PHY-SEC,LOG-SEC,MIN-IO,OPT-IO,ALIGNMENT` |
| UUIDs, labels, filesystem types | `blkid` / `lsblk -o NAME,UUID,LABEL` |
| Partition table contents | `sgdisk -p <dev>` / `parted <dev> print` / `fdisk -l <dev>` |
| Is a partition aligned? | `parted <dev> align-check optimal <n>` |
| Space used | `df -h` (blocks) and `df -i` (inodes) — **both** |
| Where the space went | `du -xh --max-depth=1 /var \| sort -h` (`-x` stays on one filesystem) |
| Deleted-but-open files | `lsof +L1` |
| Mounts as the kernel sees them | `findmnt` / `findmnt -D` / `cat /proc/mounts` |
| Is fstab valid? | `findmnt --verify --verbose` |
| LVM state | `pvs` / `vgs` / `lvs` (add `-a` for hidden LVs, `-o +devices`) |
| LVM verbose detail | `pvdisplay` / `vgdisplay` / `lvdisplay -m` (segment map) |
| LVM change history | `journalctl -u lvm2-monitor` and `/etc/lvm/archive/` |
| XFS geometry | `xfs_info <mountpoint>` |
| ext4 superblock | `tune2fs -l <device>` |
| Swap in use | `swapon --show` / `free -h` / `cat /proc/swaps` |
| Firmware mode | `[ -d /sys/firmware/efi ] && echo UEFI \|\| echo BIOS` |
| Boot loader state | `bootctl status` / `efibootmgr -v` |
| Per-device I/O pressure | `iostat -xz 1` / `cat /proc/pressure/io` |
| Re-read a modified partition table | `partprobe <dev>` / `partx -u <dev>` / `blockdev --rereadpt <dev>` |

---

## 13. Design decision checklist

Run this before every install. It is the whole objective in operational form.

1. **Firmware mode?** UEFI → GPT + ESP (≥ 512 MiB, 1 GiB with UKIs). BIOS + GPT → add the 1 MiB `ef02` partition. BIOS + MBR → mind the 2 TiB ceiling.
2. **`/boot` separate, 1 GiB, plain partition, ext4 or feature-pinned XFS.** Not thin, not LUKS2/Argon2id, not RAID5.
3. **What grows without bound on this system?** Logs → `/var/log`. Containers → `/var/lib/containerd`. Users → `/home`. Databases → their own device. Each gets a filesystem.
4. **What must be `noexec`/`nosuid`/`nodev`?** `/tmp`, `/var/tmp`, `/home`, `/dev/shm`, `/boot`. Each needs to be a separate mount for the option to exist.
5. **What has an independent durability or latency requirement?** WAL/redo, etcd, audit logs. Separate physical devices, not just separate LVs.
6. **LVM, yes or no?** Long-lived and physical → yes. Cloud cattle → no, use volume APIs.
7. **Allocate conservatively.** Leave ≥ 50 % of the VG unassigned. XFS cannot shrink; free extents are the only flexibility you will have.
8. **Swap: 4–8 GiB, `vm.swappiness=10`.** RAM-sized only if hibernation is a genuine requirement. Kubernetes nodes need an explicit policy either way.
9. **1 MiB alignment everywhere.** Verify with `parted align-check`, not by assumption.
10. **Mount by UUID or `/dev/mapper/` path.** Never by `/dev/sdX`.
11. **`nofail,x-systemd.device-timeout=15s` on every non-essential mount.** A missing data volume must never cost you SSH access.
12. **`findmnt --verify` before the first reboot.** Always.

---

## 14. Referencias

**Certification objectives**
- LPI — Exam 101-500 objectives: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102-500 objectives (topic 102.1 lives here): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — LPIC-1 certification overview: https://www.lpi.org/our-certifications/lpic-1-overview/

**Standards and specifications**
- Filesystem Hierarchy Standard 3.0 (Linux Foundation): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- UEFI Specification (UEFI Forum): https://uefi.org/specifications
- Discoverable Partitions Specification (systemd/UAPI Group): https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- Boot Loader Specification (UAPI Group): https://uapi-group.org/specifications/specs/boot_loader_specification/

**Manual pages and tool documentation**
- `fstab(5)`: https://man7.org/linux/man-pages/man5/fstab.5.html
- `mount(8)` — filesystem-independent and per-filesystem options: https://man7.org/linux/man-pages/man8/mount.8.html
- `lsblk(8)`: https://man7.org/linux/man-pages/man8/lsblk.8.html
- `parted(8)`: https://www.gnu.org/software/parted/manual/parted.html
- `sgdisk(8)` / GPT fdisk documentation: https://www.rodsbooks.com/gdisk/
- `mkswap(8)`: https://man7.org/linux/man-pages/man8/mkswap.8.html
- `swapon(8)`: https://man7.org/linux/man-pages/man8/swapon.8.html
- `findmnt(8)`: https://man7.org/linux/man-pages/man8/findmnt.8.html
- util-linux project documentation: https://github.com/util-linux/util-linux

**LVM**
- LVM2 project (sourceware.org): https://sourceware.org/lvm2/
- `lvm(8)`: https://man7.org/linux/man-pages/man8/lvm.8.html
- `lvmthin(7)` — thin provisioning: https://man7.org/linux/man-pages/man7/lvmthin.7.html
- Red Hat — Configuring and managing logical volumes (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_logical_volumes/index

**Filesystems**
- XFS documentation (kernel.org): https://docs.kernel.org/filesystems/xfs/index.html
- `mkfs.xfs(8)`: https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html
- ext4 documentation (kernel.org): https://docs.kernel.org/filesystems/ext4/index.html
- Btrfs documentation: https://btrfs.readthedocs.io/en/latest/
- `tmpfs` documentation (kernel.org): https://docs.kernel.org/filesystems/tmpfs.html

**Boot chain**
- GNU GRUB manual: https://www.gnu.org/software/grub/manual/grub/grub.html
- `systemd-boot(7)` / `bootctl(1)`: https://www.freedesktop.org/software/systemd/man/latest/bootctl.html
- `systemd-fstab-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
- `systemd-gpt-auto-generator(8)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-gpt-auto-generator.html
- `systemd.mount(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.mount.html
- `dracut` documentation: https://man7.org/linux/man-pages/man8/dracut.8.html

**Distribution installation and layout guidance**
- Red Hat — Recommended partitioning scheme (RHEL 9): https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/performing_a_standard_rhel_9_installation/
- Red Hat — Recommended system swap space: https://access.redhat.com/solutions/15244
- Kickstart reference (Anaconda / Fedora): https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html
- cloud-init module reference (`growpart`, `disk_setup`, `mounts`, `swap`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Butane configuration specification (Fedora CoreOS): https://coreos.github.io/butane/config-fcos-v1_5/
- Ignition specification: https://coreos.github.io/ignition/configuration-v3_4/
- Debian — Recommended partitioning scheme: https://www.debian.org/releases/stable/amd64/apcs03.en.html
- Ubuntu Server documentation: https://documentation.ubuntu.com/server/

**Kernel tunables and container/orchestrator integration**
- Kernel `sysctl/vm.rst` (`swappiness`, `vfs_cache_pressure`, `min_free_kbytes`): https://docs.kernel.org/admin-guide/sysctl/vm.html
- Kernel `zram` documentation: https://docs.kernel.org/admin-guide/blockdev/zram.html
- Kubernetes — Node-pressure eviction: https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes — Local volumes and storage: https://kubernetes.io/docs/concepts/storage/volumes/#local
- Kubernetes — Swap memory management on nodes: https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory

**Hardening baselines**
- CIS Benchmarks (filesystem partitioning and mount-option controls): https://www.cisecurity.org/cis-benchmarks
- DISA STIGs for Linux: https://public.cyber.mil/stigs/