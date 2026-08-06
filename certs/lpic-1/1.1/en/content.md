# LPIC-1 · Topic 1.1 — System Architecture

**Exam:** 101-500 (LPIC-1 v5.0) · **Objectives covered:** 101.1, 101.2, 101.3 · **Weight:** 10

---

## 1. Motivation: the architectural problem

Every other subsystem you will ever operate — the container runtime, the kubelet, the database, the service mesh — runs *inside* a machine that something else had to bring to life. That "something else" is the only code path in the stack with **no supervisor, no retry loop, and no observability plane**. If `containerd` crashes, systemd restarts it and Prometheus tells you. If the initramfs cannot find the root filesystem, there is no systemd, no journal, no metrics endpoint, no SSH — there is a `dracut:/#` prompt on a serial console you may not have wired.

The concrete production failure this topic exists to prevent looks like this:

> A 240-node bare-metal Kubernetes cluster runs unattended `dnf upgrade` via a maintenance window. The new kernel package regenerates the initramfs. On 19 nodes the multipath module was blacklisted years ago by a since-departed engineer via `/etc/modprobe.d/local.conf`, so the new initramfs is built *without* `dm-multipath`. Those nodes reboot, cannot assemble the SAN-backed root LV, and drop to the dracut emergency shell. The cluster loses 8 % of capacity, the pods reschedule, the remaining nodes hit memory pressure, and the incident is now a cascading outage. Nothing in the boot path emitted a single metric.

Three architectural properties fall out of that story, and they are exactly what objectives 101.1–101.3 encode:

| Property | Question it answers | Objective |
|---|---|---|
| **Hardware enumeration is dynamic** | How does the kernel learn a device exists, and how do you deterministically name/configure it? | 101.1 |
| **The boot chain is a hand-off sequence with no rollback** | Which component owns the machine at time *t*, what does it hand over, and where does it log? | 101.2 |
| **State transitions must be intentional and drainable** | How do you move a running machine between service levels, or take it down, without corrupting state? | 101.3 |

The rest of this document treats the boot path as a **distributed system of five sequential owners**, each with its own configuration store, its own failure surface, and its own debug channel.

---

## 2. The boot chain, end to end

```
┌──────────┐   ┌──────────────┐   ┌────────┐   ┌───────────┐   ┌────────┐
│ Firmware │──▶│ Boot loader  │──▶│ Kernel │──▶│ initramfs │──▶│ PID 1  │
│ BIOS/UEFI│   │ GRUB2/sd-boot│   │ vmlinuz│   │  (dracut) │   │systemd │
└──────────┘   └──────────────┘   └────────┘   └───────────┘   └────────┘
  NVRAM /        grub.cfg /         cmdline      /init,          units,
  CMOS           loader/entries     modules      switch_root     targets

  ▲ no logs      ▲ no logs          ▲ dmesg      ▲ dmesg+rdsosreport  ▲ journald
```

Each arrow is an **irreversible hand-off**. The predecessor's state (memory map, device tree, command line) is passed forward; the predecessor itself is discarded. This is why you cannot "restart the boot loader" — you can only reboot.

### 2.1 Phase 1 — Firmware

The firmware performs POST, initializes the memory controller, and then must find executable code on persistent storage. There are two fundamentally different contracts for that.

**Legacy BIOS.** The firmware reads **LBA 0** (the first 512 bytes) of the boot device into memory at `0x7C00` and jumps to it in 16-bit real mode. That 512-byte MBR is laid out as:

| Offset | Size | Content |
|---|---|---|
| `0x000` | 446 B | Bootstrap code (GRUB `boot.img`) |
| `0x1BE` | 64 B | Partition table — 4 primary entries × 16 B |
| `0x1FE` | 2 B | Boot signature `0x55 0xAA` |

446 bytes is not enough for a filesystem driver, so GRUB stores `core.img` elsewhere: in the **post-MBR gap** (MBR-partitioned disks) or in a dedicated **BIOS Boot Partition** (`ef02`, GUID `21686148-6449-6E6F-744E-656564454649`) on GPT disks. Forgetting that partition is the single most common cause of "GPT disk installs fine, then `Missing operating system`".

**UEFI.** The firmware contains a FAT driver, reads the **EFI System Partition** (ESP, type `ef00`, GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`), and executes a PE/COFF binary in 64-bit mode. Which binary is chosen comes from **NVRAM boot variables**, not from the disk — a stateful, per-machine configuration that survives disk replacement and is *lost* on motherboard replacement.

```console
$ ls /sys/firmware/efi
config_table  efivars  esrt  fw_platform_size  fw_vendor  runtime  runtime-map  systab
```

> **Diagnostic rule:** the existence of `/sys/firmware/efi` is the authoritative test for "am I running under UEFI". `dmidecode` will not tell you; `efibootmgr` will simply fail.

```console
$ efibootmgr -v
BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0003,0000
Boot0000* UiApp	FvVol(7cb8bdc9-f8eb-4f34-aaea-3ee4af6516a1)/FvFile(462caa21-7614-4503-836e-8ab6f4662331)
Boot0001* rocky	HD(1,GPT,3f2a9c11-7b04-4f7e-9a1d-2c8f5b0e11aa,0x800,0x12c000)/File(\EFI\rocky\shimx64.efi)
Boot0003* UEFI PXEv4 (MAC:5254001a2b3c)	PciRoot(0x0)/Pci(0x2,0x0)/MAC(5254001a2b3c,1)/IPv4(0.0.0.0,0,0)
```

Secure Boot inserts a signature-verification link: firmware → `shimx64.efi` (signed by Microsoft's UEFI CA) → `grubx64.efi` (signed by the distro) → kernel (signed by the distro). Out-of-tree modules (NVIDIA, DKMS, some CNI datapath modules) must then be signed by a **Machine Owner Key** enrolled with `mokutil`.

```console
$ mokutil --sb-state
SecureBoot enabled

$ mokutil --list-enrolled | head -n 5
[key 1]
SHA1 Fingerprint: 5d:c8:9f:...:2a
Certificate:
    Data:
        Version: 3 (0x2)
```

**Trade-offs:**

| Dimension | Legacy BIOS + MBR | UEFI + GPT |
|---|---|---|
| Max addressable disk | 2 TiB (32-bit LBA) | 8 ZiB (64-bit LBA) |
| Primary partitions | 4 (extended/logical hack beyond) | 128 by default, no extended concept |
| Boot code location | 446 B MBR + gap/`ef02` partition | Files on a FAT32 ESP |
| Boot entry state | Disk-resident only | Disk **and** NVRAM (`efibootmgr`) |
| Chain of trust | None | Secure Boot (shim → MOK) |
| Multi-OS coexistence | Bootloader must chainload | Firmware menu selects natively |
| Partition table redundancy | None | Primary + backup GPT header/CRC32 |
| Recovery complexity | Rewrite 446 B | Restore ESP files **and** NVRAM vars |
| Network boot | PXE via option ROM | HTTP(S) Boot, PXE, native driver stack |
| Typical fleet role | Legacy/edge appliances | Everything current; required for Secure Boot |

**Architect's call:** for any fleet you expect to run >3 years, UEFI + GPT is not optional — Secure Boot and >2 TiB boot devices are both hard requirements. Budget for the operational cost: NVRAM is per-chassis state that your provisioning automation must be able to rebuild (`efibootmgr -c`), or an RMA'd motherboard becomes an unbootable node.

### 2.2 Phase 2 — Boot loader

The boot loader's job is narrow: load `vmlinuz` and `initramfs` into RAM, assemble the **kernel command line**, populate the boot protocol structure, and jump to the kernel entry point.

**GRUB2** is the universal default. Its critical architectural property is that **`grub.cfg` is generated, never hand-edited**:

| Distribution family | Generator | Template inputs | Output |
|---|---|---|---|
| Debian/Ubuntu | `update-grub` (wrapper for `grub-mkconfig`) | `/etc/default/grub`, `/etc/grub.d/*` | `/boot/grub/grub.cfg` |
| RHEL/Rocky/Alma/Fedora | `grub2-mkconfig` | `/etc/default/grub`, `/etc/grub.d/*` | `/boot/grub2/grub.cfg` |
| RHEL 8+/Fedora (per-kernel) | `grubby` | — | `/boot/loader/entries/*.conf` (BLS) |
| SUSE | `grub2-mkconfig` | `/etc/default/grub` | `/boot/grub2/grub.cfg` |

Red Hat-family systems since RHEL 8 use the **Boot Loader Specification (BLS)**: one small file per installed kernel under `/boot/loader/entries/`, so installing a kernel no longer rewrites the whole `grub.cfg`.

```console
$ cat /boot/loader/entries/3f2a9c117b044f7e9a1d2c8f5b0e11aa-5.14.0-427.el9.x86_64.conf
title Rocky Linux (5.14.0-427.el9.x86_64) 9.4 (Blue Onyx)
version 5.14.0-427.el9.x86_64
linux /vmlinuz-5.14.0-427.el9.x86_64
initrd /initramfs-5.14.0-427.el9.x86_64.img
options root=/dev/mapper/rl-root ro crashkernel=1G-4G:192M rd.lvm.lv=rl/root rd.lvm.lv=rl/swap
grub_users $grub_users
grub_arg --unrestricted
grub_class rocky
```

Changing the command line fleet-wide, correctly, on each family:

```console
# RHEL family — updates every BLS entry, no full regeneration
$ sudo grubby --update-kernel=ALL --args="net.ifnames=0 transparent_hugepage=never"
$ sudo grubby --info=DEFAULT
index=0
kernel="/boot/vmlinuz-5.14.0-427.el9.x86_64"
args="ro crashkernel=1G-4G:192M rd.lvm.lv=rl/root net.ifnames=0 transparent_hugepage=never"
root="/dev/mapper/rl-root"
initrd="/boot/initramfs-5.14.0-427.el9.x86_64.img"
title="Rocky Linux (5.14.0-427.el9.x86_64) 9.4 (Blue Onyx)"
id="3f2a9c117b044f7e9a1d2c8f5b0e11aa-5.14.0-427.el9.x86_64"
```

```console
# Debian family — edit the template, then regenerate
$ sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet net.ifnames=0"/' /etc/default/grub
$ sudo update-grub
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.8.0-45-generic
Found initrd image: /boot/initrd.img-6.8.0-45-generic
done
```

Key `/etc/default/grub` directives:

| Directive | Effect | Production note |
|---|---|---|
| `GRUB_TIMEOUT` | Menu wait in seconds | `0` on cloud, `5` on bare metal — you need the menu when there is no other console |
| `GRUB_DEFAULT` | Index, title, or `saved` | Use `saved` + `grub-set-default` for atomic A/B kernel promotion |
| `GRUB_CMDLINE_LINUX` | Args for **all** entries, including recovery | Put persistent tuning here |
| `GRUB_CMDLINE_LINUX_DEFAULT` | Args for normal entries only | Put `quiet`/`splash` here |
| `GRUB_DISABLE_RECOVERY` | Suppress single-user entries | Never `true` on bare metal |
| `GRUB_TERMINAL` | `console`, `serial`, or both | `serial` is mandatory for headless fleets |
| `GRUB_SERIAL_COMMAND` | Serial line parameters | Must match your BMC/SOL settings exactly |
| `GRUB_ENABLE_BLSCFG` | Use BLS entries (RH family) | Leave `true`; `false` reverts to monolithic `grub.cfg` |

Boot loader comparison:

| | GRUB2 | systemd-boot | EFI stub (direct) | U-Boot |
|---|---|---|---|---|
| Firmware support | BIOS + UEFI + others | UEFI only | UEFI only | Embedded/ARM |
| Config format | Generated shell-like script | `.conf` per entry, BLS | NVRAM entry only | Env vars / FIT image |
| Filesystem drivers | Extensive (ext, XFS, Btrfs, LVM, LUKS, ZFS) | ESP FAT only | ESP FAT only | Several |
| Encrypted `/boot` | Yes (LUKS1, LUKS2 partial) | No | No | No |
| Complexity / attack surface | High | Low | Minimal | Medium |
| Interactive rescue shell | Yes (`grub>`) | Limited | No | Yes |
| Typical use | General purpose, all distros | Minimal/immutable UEFI hosts | Unified Kernel Images, confidential VMs | SBCs, appliances |

**Architect's call:** GRUB2 unless you are building an immutable, UEFI-only, measured-boot image — in which case a **Unified Kernel Image** (kernel + initramfs + cmdline in one signed PE binary, booted by the EFI stub) eliminates the "unsigned command line" attack and removes an entire component from the chain.

### 2.3 Phase 3 — Kernel

The kernel decompresses itself, sets up paging, initializes built-in drivers, and mounts the initramfs as a `tmpfs` root. Everything it was told is in one place:

```console
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro \
crashkernel=1G-4G:192M rd.lvm.lv=rl/root net.ifnames=0 transparent_hugepage=never
```

> `/proc/cmdline` is ground truth. If a `sysctl`-style tunable "isn't applying", check here before checking anything else — a `grubby`/`update-grub` run that was never followed by a reboot is the most common cause.

Essential command-line parameters for operations:

| Parameter | Purpose |
|---|---|
| `root=UUID=… \| /dev/mapper/…` | Real root device for `switch_root` |
| `ro` / `rw` | Initial mount mode of root (fsck runs on `ro`) |
| `init=/bin/bash` | Replace PID 1 — the last-resort password/`fstab` recovery |
| `systemd.unit=rescue.target` | Boot to a specific target |
| `rd.break[=pre-mount\|mount\|pre-pivot]` | Drop to a shell *inside* dracut at a chosen stage |
| `rd.debug` / `debug` | Verbose initramfs and kernel logging |
| `nomodeset` | Disable KMS — GPU/console troubleshooting |
| `net.ifnames=0 biosdevname=0` | Revert to `eth0`-style names |
| `console=ttyS0,115200n8 console=tty0` | Serial console; **last** `console=` gets `/dev/console` |
| `systemd.log_level=debug` | Verbose PID 1 |
| `crashkernel=…` | Reserve memory for the kdump capture kernel |

The early kernel log is the only diagnostic channel in this phase:

```console
$ sudo dmesg -T --level=err,warn | head
[Wed Aug  5 09:14:02 2026] ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PCI0.SAT0], AE_NOT_FOUND
[Wed Aug  5 09:14:03 2026] i40e 0000:3b:00.0: Error I40E_AQ_RC_ENOSPC adding RX filters
[Wed Aug  5 09:14:05 2026] EXT4-fs (sda3): mounted filesystem with ordered data mode
```

### 2.4 Phase 4 — initramfs

The initramfs is a **compressed cpio archive** containing a minimal userspace whose sole purpose is to make the real root filesystem mountable: load storage drivers, assemble MD/LVM/multipath, unlock LUKS, bring up the network for NFS/iSCSI root. It ends with `switch_root`, which replaces the tmpfs root with the real one and `exec`s `/sbin/init`.

| | dracut (RHEL, SUSE, Fedora, Arch) | initramfs-tools (Debian, Ubuntu) |
|---|---|---|
| Config | `/etc/dracut.conf`, `/etc/dracut.conf.d/*.conf` | `/etc/initramfs-tools/initramfs.conf`, `conf.d/`, `modules` |
| Rebuild | `dracut -f`, `dracut -f --regenerate-all` | `update-initramfs -u -k all` |
| Inspect | `lsinitrd /boot/initramfs-$(uname -r).img` | `lsinitramfs /boot/initrd.img-$(uname -r)` |
| Content policy | `hostonly=yes` (default) — only this host's drivers | Governed by `MODULES=most\|dep\|list\|netboot` |
| Extensibility | Modules under `/usr/lib/dracut/modules.d/` | Hooks in `/etc/initramfs-tools/{hooks,scripts}/` |
| Debug break | `rd.break=<stage>`, `rd.debug` | `break=<stage>`, `debug` |
| Size (typical) | 30–45 MB host-only, 90 MB+ generic | 40–80 MB |

`hostonly=yes` is the trap in the opening scenario: an image built on one hardware profile will not boot on another. Golden images and any host that might change storage controllers need `hostonly=no`.

```console
$ lsinitrd /boot/initramfs-5.14.0-427.el9.x86_64.img | grep -E 'multipath|dm-mod|nvme'
drwxr-xr-x   2 root     root            0 Aug  5 09:02 usr/lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/md/dm-multipath.ko.xz
-rw-r--r--   1 root     root        41236 Aug  5 09:02 usr/lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/nvme/host/nvme.ko.xz

$ lsinitrd -f /etc/cmdline.d/90lvm.conf /boot/initramfs-5.14.0-427.el9.x86_64.img
rd.lvm.lv=rl/root rd.lvm.lv=rl/swap
```

```console
# Force inclusion regardless of host-only detection, then rebuild every kernel
$ printf 'add_drivers+=" dm-multipath dm-round-robin nvme_tcp "\n' | sudo tee /etc/dracut.conf.d/99-storage.conf
$ sudo dracut -f --regenerate-all -v
dracut: Executing: /usr/bin/dracut -f --regenerate-all -v
dracut: *** Including module: dm ***
dracut: *** Including module: multipath ***
dracut: *** Creating image file '/boot/initramfs-5.14.0-427.el9.x86_64.img' ***
dracut: *** Creating initramfs image file '/boot/initramfs-5.14.0-427.el9.x86_64.img' done ***
```

### 2.5 Phase 5 — PID 1

`switch_root` `exec`s PID 1, which owns the machine for the rest of its uptime.

| | SysVinit | Upstart | systemd |
|---|---|---|---|
| Model | Sequential shell scripts | Event-driven | Dependency graph, parallel |
| Config | `/etc/inittab`, `/etc/init.d/`, `rc?.d/` | `/etc/init/*.conf` | Unit files (`.service`, `.target`, …) |
| Ordering | Numeric prefixes `S20`, `K80` | Event emission | `Before=`/`After=`/`Requires=`/`Wants=` |
| Service state model | PID files, best-effort | PID tracking | cgroup-based — **authoritative** |
| Boot time (typical server) | 60–120 s | 30–60 s | 8–25 s |
| Logging | syslog only | syslog | journald, structured, indexed |
| Socket/D-Bus activation | No | Partial | Yes |
| Resource control | External `ulimit` | External | Native cgroup v2 delegation |
| Status | Legacy, still on some appliances | Effectively dead | Universal default |

cgroup-based tracking is the property that matters operationally: SysVinit could lose a double-forking daemon and leave orphans behind; systemd cannot, because every process spawned by a unit stays in that unit's cgroup and `KillMode` reaps the whole slice.

```console
$ systemd-analyze
Startup finished in 2.114s (kernel) + 5.882s (initrd) + 10.446s (userspace) = 18.442s
graphical.target reached after 10.398s in userspace.

$ systemd-analyze critical-chain
The time when unit became active or started is printed after the "@" character.
The time the unit took to start is printed after the "+" character.

graphical.target @10.398s
└─multi-user.target @10.397s
  └─kubelet.service @9.204s +1.190s
    └─containerd.service @8.771s +425ms
      └─network-online.target @8.766s
        └─NetworkManager-wait-online.service @2.910s +5.854s
          └─NetworkManager.service @2.611s +291ms
            └─basic.target @2.600s
```

That output is a real finding: `NetworkManager-wait-online.service` is 5.85 s of the 10.4 s userspace boot. On a fleet doing rolling reboots, that is minutes of aggregate unavailability, fixable by scoping the wait to the interfaces that actually matter.

---

## 3. Runlevels, targets, and controlled shutdown (101.3)

### 3.1 The mapping you must know cold

| SysV runlevel | systemd target | Meaning |
|---|---|---|
| 0 | `poweroff.target` | Halt and power off |
| 1, `s`, `S` | `rescue.target` | Single-user, local FS mounted, no network |
| 2 | `multi-user.target` | Debian: multi-user w/o network (historical) |
| 3 | `multi-user.target` | Multi-user, networked, text — **the server target** |
| 4 | `multi-user.target` | Unused / site-defined |
| 5 | `graphical.target` | Multi-user + display manager |
| 6 | `reboot.target` | Reboot |
| — | `emergency.target` | Root FS mounted **read-only**, only `/bin/sh`; below rescue |
| — | `default.target` | Symlink to whichever target boots by default |

Under SysVinit the default lives in `/etc/inittab` (`id:3:initdefault:`); under systemd it is a symlink.

```console
$ systemctl get-default
multi-user.target

$ ls -l /etc/systemd/system/default.target
lrwxrwxrwx. 1 root root 41 Jul 12 16:20 /etc/systemd/system/default.target -> /usr/lib/systemd/system/multi-user.target

$ sudo systemctl set-default multi-user.target
Removed /etc/systemd/system/default.target.
Created symlink /etc/systemd/system/default.target → /usr/lib/systemd/system/multi-user.target
```

The legacy commands still work and are still examinable:

```console
$ runlevel
N 3
$ who -r
         run-level 3  2026-08-05 09:14
```

`N` means "no previous runlevel" — the system booted straight into 3 and never transitioned.

`systemctl isolate` is the modern `telinit N`: it starts the named target and **stops every unit not required by it**.

```console
$ sudo systemctl isolate rescue.target      # equivalent to: telinit 1
$ sudo systemctl isolate multi-user.target  # equivalent to: telinit 3
```

> **Production warning:** `isolate` on a live node stops units the target does not pull in. Running `systemctl isolate multi-user.target` on a graphical workstation kills the session; on a Kubernetes node with a hand-started unit outside the dependency graph, it kills that too. Only units with `AllowIsolate=yes` may be isolate targets — this is why `systemctl isolate sshd.service` fails.

### 3.2 Shutdown semantics

```console
$ sudo shutdown -h +10 "Kernel maintenance — draining now, back at 03:20 UTC"

Broadcast message from root@node-17 (Wed 2026-08-05 03:05:00 UTC):

Kernel maintenance — draining now, back at 03:20 UTC
The system is going down for poweroff at Wed 2026-08-05 03:15:00 UTC!
```

Two side effects of a scheduled `shutdown` that matter operationally:

1. `/run/nologin` is created ~5 minutes before the deadline, blocking new non-root logins via PAM.
2. A shutdown **job** is queued and is cancellable.

```console
$ sudo shutdown -c
Broadcast message from root@node-17 (Wed 2026-08-05 03:07:41 UTC):

The system shutdown has been cancelled at Wed 2026-08-05 03:08:41 UTC!
```

| Command | Effect | Sync/unmount? | Notes |
|---|---|---|---|
| `shutdown -h now` | Halt (usually power off) | Yes | Canonical form; supports time specs and messages |
| `shutdown -r +5` | Reboot in 5 min | Yes | Broadcasts a `wall` message |
| `shutdown -c` | Cancel pending shutdown | — | Only for scheduled jobs |
| `halt` | Stop CPU, may leave power on | Yes | `-p` to power off |
| `poweroff` | Power off via ACPI | Yes | `systemctl poweroff` |
| `reboot` | Warm reboot | Yes | `systemctl reboot` |
| `reboot -f` / `--force --force` | Immediate `reboot(2)` syscall | **No** | Data loss risk; last resort |
| `systemctl kexec` | Jump to a pre-loaded kernel | Yes | Skips firmware/POST — seconds instead of minutes |
| `telinit 6` | Legacy reboot | Yes | Compatibility shim to systemd |

**kexec** is the fleet-scale lever: on servers where POST + option ROM init takes 3–5 minutes, `kexec` reboots into a new kernel in under 20 seconds. The cost is that firmware and hardware are *not* reinitialized, so it cannot recover a wedged HBA and cannot apply firmware updates.

```console
$ sudo kexec -l /boot/vmlinuz-5.14.0-427.el9.x86_64 \
      --initrd=/boot/initramfs-5.14.0-427.el9.x86_64.img --reuse-cmdline
$ sudo systemctl kexec
```

### 3.3 Inhibitors — how to make a shutdown wait

`systemd-inhibit` is the supported mechanism for "do not reboot while I am mid-transaction". Anything that must finish before power loss should hold a lock rather than rely on unit ordering alone.

```console
$ systemd-inhibit --list
WHO                          UID  USER  PID   COMM            WHAT                                   WHY                                MODE
NetworkManager               0    root  1204  NetworkManager  sleep                                  NetworkManager needs to turn off…  delay
etcd-defrag.sh               0    root  88231 systemd-inhibi  shutdown:sleep:idle                    etcd compaction in progress        block

2 inhibitors listed.
```

```console
$ sudo systemd-inhibit --what=shutdown --who="etcd-defrag" \
      --why="etcd compaction in progress" --mode=block \
      /usr/local/bin/etcd-defrag.sh
```

Physical power/lid events are policy, not hardware destiny — they are routed through `logind`:

```console
$ grep -E '^Handle|^Idle' /etc/systemd/logind.conf
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleLidSwitch=ignore
IdleAction=ignore
```

Setting `HandlePowerKey=ignore` on servers prevents an accidental front-panel press — or a spurious ACPI event from a flaky BMC — from taking down a node.

---

## 4. Hardware enumeration and configuration (101.1)

### 4.1 The three kernel-exported namespaces

| Path | Backing | Semantics | Use for |
|---|---|---|---|
| `/proc` | `procfs` | Process + legacy kernel interfaces | `cmdline`, `interrupts`, `cpuinfo`, `modules`, `ioports`, `dma` |
| `/sys` | `sysfs` | Object model of the device tree | Modern device attributes, driver binding, tunables |
| `/dev` | `devtmpfs` + `udev` | Device nodes and symlinks | Actual I/O, persistent naming |
| `/run` | `tmpfs` | Volatile runtime state | Sockets, PID files, `nologin` |

```console
$ head -n 8 /proc/interrupts
           CPU0       CPU1       CPU2       CPU3
  0:         17          0          0          0   IO-APIC    2-edge      timer
  1:          0          0          9          0   IO-APIC    1-edge      i8042
  8:          0          0          0          1   IO-APIC    8-edge      rtc0
  9:          0          0          0          0   IO-APIC    9-fasteoi   acpi
 24:          0    1284471          0          0   PCI-MSI 1572864-edge   nvme0q0
 25:     882110          0          0          0   PCI-MSI 3670016-edge   i40e-eth0-TxRx-0
```

That last block is an interrupt-affinity finding: `nvme0q0` and `i40e-eth0-TxRx-0` are pinned to different CPUs. On a latency-sensitive node you would verify this against your `irqbalance` policy and the NUMA locality of the PCIe root port.

```console
$ cat /proc/ioports | head -n 6
0000-0cf7 : PCI Bus 0000:00
  0000-001f : dma1
  0020-0021 : pic1
  0040-0043 : timer0
  0060-0060 : keyboard
  0070-0071 : rtc0
```

`/proc/ioports` and `/proc/dma` are the modern remnants of the ISA era, and they remain examinable: I/O ports are a 16-bit address space for port-mapped I/O, and legacy DMA channels are a scarce, statically assigned resource. On PCIe hardware, MSI/MSI-X and bus-mastering DMA have replaced both, which is why `/proc/dma` is nearly empty on any current server.

### 4.2 The enumeration toolkit

```console
$ lscpu
Architecture:            x86_64
  CPU op-mode(s):        32-bit, 64-bit
  Address sizes:         46 bits physical, 48 bits virtual
  Byte Order:            Little Endian
CPU(s):                  64
  On-line CPU(s) list:   0-63
Vendor ID:               GenuineIntel
  Model name:            Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz
    Thread(s) per core:  2
    Core(s) per socket:  16
    Socket(s):           2
NUMA:
  NUMA node(s):          2
  NUMA node0 CPU(s):     0-15,32-47
  NUMA node1 CPU(s):     16-31,48-63
Vulnerabilities:
  Mds:                   Not affected
  Spectre v2:            Mitigation; Enhanced IBRS, IBPB conditional, RSB filling
```

```console
$ lspci -nnk | grep -A3 -i ethernet
3b:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Controller X710 for 10GbE SFP+ [8086:1572] (rev 02)
	Subsystem: Intel Corporation Ethernet Converged Network Adapter X710-DA2 [8086:0007]
	Kernel driver in use: i40e
	Kernel modules: i40e
```

The `[8086:1572]` vendor:device pair is the primary key of the whole driver-binding problem: it is what `modprobe` matches against module aliases, what you search vendor firmware matrices with, and what you file bugs against.

```console
$ lsusb -t
/:  Bus 02.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 5000M
    |__ Port 2: Dev 2, If 0, Class=Mass Storage, Driver=usb-storage, 5000M
/:  Bus 01.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/16p, 480M
    |__ Port 5: Dev 3, If 0, Class=Human Interface Device, Driver=usbhid, 1.5M

$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
NAME          SIZE TYPE FSTYPE      MOUNTPOINTS       MODEL
nvme0n1     894.3G disk                               SAMSUNG MZQL2960HCJR-00A07
├─nvme0n1p1     1G part vfat        /boot/efi
├─nvme0n1p2     1G part xfs         /boot
└─nvme0n1p3   892G part LVM2_member
  ├─rl-root    70G lvm  xfs         /
  ├─rl-swap     4G lvm  swap        [SWAP]
  └─rl-var    818G lvm  xfs         /var

$ sudo dmidecode -t system | sed -n '4,12p'
System Information
	Manufacturer: Dell Inc.
	Product Name: PowerEdge R650
	Version: Not Specified
	Serial Number: J7K2M93
	UUID: 4c4c4544-0037-4b10-8032-b7c04f4d3933
	Wake-up Type: Power Switch
	SKU Number: SKU=NotProvided;ModelName=PowerEdge R650
	Family: PowerEdge
```

`dmidecode` reads SMBIOS tables from firmware — it is how automation learns chassis serial and model without an inventory API, and how `systemd` derives the machine's `Hardware Vendor`/`Model` in `hostnamectl`.

### 4.3 Kernel modules: the binding layer

```console
$ lsmod | head -n 6
Module                  Size  Used by
nf_conntrack          200704  4 xt_conntrack,nf_nat,xt_MASQUERADE,nf_conntrack_netlink
overlay               172032  86
i40e                  581632  0
dm_multipath           45056  2 dm_service_time
nvme                   61440  3
nvme_core             204800  5 nvme

$ modinfo i40e | head -n 8
filename:       /lib/modules/5.14.0-427.el9.x86_64/kernel/drivers/net/ethernet/intel/i40e/i40e.ko.xz
version:        2.22.20
license:        GPL v2
description:    Intel(R) Ethernet Connection XL710 Network Driver
alias:          pci:v00008086d00001572sv*sd*bc*sc*i*
depends:        
retpoline:      Y
parms:          debug:Debug level (0=none,...,16=all), Debug mask (0x8XXXXXXX) (uint)
```

Module management surface:

| File / directory | Purpose | Applied by |
|---|---|---|
| `/etc/modules-load.d/*.conf` | Load these modules at boot (one per line) | `systemd-modules-load.service` |
| `/etc/modprobe.d/*.conf` | `options`, `alias`, `blacklist`, `install` | `modprobe` at load time |
| `/lib/modules/$(uname -r)/modules.dep` | Dependency graph | Generated by `depmod` |
| `/etc/modules` (Debian) | Legacy load-at-boot list | `kmod` init script |

The **blacklist trap**, worth memorizing because it produces "I blacklisted it and it loaded anyway":

```console
# blacklist: prevents ALIAS-based autoload only.
# The module still loads on explicit `modprobe` or as another module's dependency.
$ cat /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0

# install <mod> /bin/false: the hard block. modprobe runs this command instead of loading.
$ cat /etc/modprobe.d/hard-block-firewire.conf
install firewire_ohci /bin/false
install firewire_core /bin/false
```

Because `/etc/modprobe.d` is consumed when the initramfs is *built*, any change there requires an initramfs rebuild to affect early boot:

```console
$ sudo dracut -f --regenerate-all          # RHEL family
$ sudo update-initramfs -u -k all          # Debian family
```

This is precisely the failure in §1: a `blacklist` line changed the set of drivers dracut baked into the host-only image.

### 4.4 udev: from kernel uevent to stable name

The kernel emits a `uevent` on device discovery; `systemd-udevd` receives it over netlink, matches rules, and creates nodes, symlinks, and properties in `/dev`.

Rule precedence: `/etc/udev/rules.d/` **overrides** `/run/udev/rules.d/`, which overrides `/usr/lib/udev/rules.d/` (same filename wins). Files are processed in lexical order across all directories.

```console
$ udevadm info --query=all --name=/dev/nvme0n1 | head -n 12
P: /devices/pci0000:00/0000:00:1d.0/0000:65:00.0/nvme/nvme0/nvme0n1
N: nvme0n1
L: 0
S: disk/by-id/nvme-SAMSUNG_MZQL2960HCJR-00A07_S64HNE0R500123
S: disk/by-path/pci-0000:65:00.0-nvme-1
E: DEVPATH=/devices/pci0000:00/0000:00:1d.0/0000:65:00.0/nvme/nvme0/nvme0n1
E: DEVNAME=/dev/nvme0n1
E: DEVTYPE=disk
E: ID_SERIAL=SAMSUNG_MZQL2960HCJR-00A07_S64HNE0R500123
E: ID_MODEL=SAMSUNG MZQL2960HCJR-00A07
E: ID_WWN=eui.34483045523030313233
E: SUBSYSTEM=block
```

```console
$ udevadm monitor --udev --property --subsystem-match=block
monitor will print the received events for:
UDEV - the event which udev sends out after rule processing

UDEV  [184213.005112] add      /devices/pci0000:00/.../block/sdb (block)
ACTION=add
DEVNAME=/dev/sdb
DEVTYPE=disk
ID_BUS=scsi
ID_SERIAL=36001405f2a9c1170b044f7e9
SUBSYSTEM=block
```

Writing and testing a rule without touching hardware:

```console
$ sudo tee /etc/udev/rules.d/70-storage-tuning.rules >/dev/null <<'EOF'
# Stable symlink + I/O scheduler + queue depth for the SAN data LUN
SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_SERIAL}=="36001405f2a9c1170b044f7e9", \
  SYMLINK+="san/data0", OWNER="root", GROUP="disk", MODE="0660"

# NVMe: no I/O scheduler, deep queue — the device reorders better than we do
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", \
  ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023", \
  ATTR{queue/read_ahead_kb}="128"

# Rotational SAS behind multipath: deadline-style scheduler
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", \
  ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF

$ sudo udevadm control --reload-rules
$ sudo udevadm test /sys/class/block/nvme0n1 2>&1 | grep -E 'ATTR|SYMLINK|Reading rules'
Reading rules file: /etc/udev/rules.d/70-storage-tuning.rules
ATTR '/sys/devices/.../nvme0n1/queue/scheduler' writing 'none'
ATTR '/sys/devices/.../nvme0n1/queue/nr_requests' writing '1023'

$ sudo udevadm trigger --subsystem-match=block --action=change
$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline kyber bfq
```

**Predictable network interface names** are udev's most visible product. `systemd-udevd` derives names from firmware/topology instead of probe order, eliminating the classic "`eth0` and `eth1` swapped after reboot" outage:

| Prefix | Derivation | Example |
|---|---|---|
| `eno` | On-board index from firmware (SMBIOS/ACPI) | `eno1` |
| `ens` | PCI hotplug slot index | `ens3` |
| `enp` | PCI bus/slot/function geometry | `enp59s0f0` |
| `enx` | MAC address | `enx5254001a2b3c` |
| `eth` | Kernel probe order — **non-deterministic** | `eth0` |

```console
$ udevadm test-builtin net_id /sys/class/net/enp59s0f0 2>/dev/null
ID_NET_NAMING_SCHEME=v252
ID_NET_NAME_MAC=enx3cecef1a2b3c
ID_NET_NAME_PATH=enp59s0f0
ID_NET_NAME_SLOT=ens1f0
```

Disabling predictable naming (only ever do this to satisfy legacy configuration you cannot change) requires **both** `net.ifnames=0` on the command line and masking the generator rule:

```console
$ sudo ln -sf /dev/null /etc/systemd/network/99-default.link
$ sudo grubby --update-kernel=ALL --args="net.ifnames=0 biosdevname=0"
$ sudo dracut -f --regenerate-all
```

### 4.5 Hot-plug rescan without reboot

```console
# Rescan every SCSI/SAS host for new LUNs — "channel target lun", '-' = wildcard
$ for h in /sys/class/scsi_host/host*; do echo "- - -" | sudo tee "$h/scan" >/dev/null; done
$ sudo rescan-scsi-bus.sh -a          # sg3_utils, does the same plus resize handling

# Pick up a LUN that grew on the array side
$ echo 1 | sudo tee /sys/class/block/sdb/device/rescan

# Remove a device cleanly before the storage team unmaps it
$ echo 1 | sudo tee /sys/class/block/sdb/device/delete

$ sudo nvme list
Node          SN              Model                        Namespace Usage                      Format           FW Rev
------------- --------------- ---------------------------- --------- -------------------------- ---------------- --------
/dev/nvme0n1  S64HNE0R500123  SAMSUNG MZQL2960HCJR-00A07   1         960.20  GB / 960.20  GB    512   B +  0 B   GDC5302Q
```

---

## 5. Complete infrastructure manifests

These are the artifacts that make everything above reproducible across a fleet. They are complete and syntactically valid as written.

### 5.1 `cloud-init` — node bootstrap with boot-path configuration

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
# Provisions kernel cmdline, module policy, udev rules and boot targets on first boot.
hostname: node-17
fqdn: node-17.rack04.dc-mad.example.net
prefer_fqdn_over_hostname: true

write_files:
  # ---- Kernel module policy -------------------------------------------------
  - path: /etc/modules-load.d/10-platform.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Loaded unconditionally at boot by systemd-modules-load.service
      br_netfilter
      overlay
      nf_conntrack
      dm_multipath
      dm_round_robin
      nvme_tcp

  - path: /etc/modprobe.d/10-platform-options.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Connection tracking table sized for a busy node (~512k flows)
      options nf_conntrack hashsize=131072
      # Bond in 802.3ad; miimon in ms
      options bonding max_bonds=0 miimon=100
      # Hard-block legacy DMA-capable buses (physical attack surface)
      install firewire_ohci /bin/false
      install firewire_core /bin/false
      install thunderbolt /bin/false
      # Prevent the open GPU driver from binding before the vendor module
      blacklist nouveau
      options nouveau modeset=0

  # ---- Storage naming and queue tuning --------------------------------------
  - path: /etc/udev/rules.d/70-storage-tuning.rules
    permissions: '0644'
    owner: root:root
    content: |
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", \
        ATTR{queue/scheduler}="none", ATTR{queue/nr_requests}="1023", \
        ATTR{queue/read_ahead_kb}="128", ATTR{queue/rq_affinity}="2"
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="dm-*", \
        ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"

  # ---- initramfs content policy ---------------------------------------------
  - path: /etc/dracut.conf.d/99-platform.conf
    permissions: '0644'
    owner: root:root
    content: |
      # Golden image: never host-only, the image must boot on any SKU in the fleet
      hostonly="no"
      add_drivers+=" dm_multipath dm_round_robin nvme_tcp i40e ixgbe mlx5_core "
      add_dracutmodules+=" multipath network-legacy "
      compress="zstd"

  # ---- Power-button and idle policy -----------------------------------------
  - path: /etc/systemd/logind.conf.d/10-server.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Login]
      HandlePowerKey=ignore
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
      HandleLidSwitch=ignore
      IdleAction=ignore

  # ---- Bounded shutdown ------------------------------------------------------
  - path: /etc/systemd/system.conf.d/10-timeouts.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Manager]
      DefaultTimeoutStartSec=90s
      DefaultTimeoutStopSec=45s
      # Never let one hung unit hold a rolling reboot hostage
      DefaultRestartSec=2s

bootcmd:
  - [ cloud-init-per, once, grubby-args, /usr/sbin/grubby, --update-kernel=ALL,
      --args=net.ifnames=0 transparent_hugepage=never intel_iommu=on iommu=pt console=ttyS0,115200n8 ]

runcmd:
  - [ systemctl, set-default, multi-user.target ]
  - [ udevadm, control, --reload-rules ]
  - [ udevadm, trigger, --subsystem-match=block, --action=change ]
  - [ dracut, -f, --regenerate-all ]
  - [ systemctl, enable, --now, node-boot-audit.service ]

power_state:
  mode: reboot
  message: "cloud-init: applying kernel cmdline and initramfs policy"
  timeout: 60
  condition: true
```

### 5.2 Ansible role — idempotent boot-path enforcement across the fleet

```yaml
---
# roles/boot_architecture/tasks/main.yml
- name: Detect firmware type
  ansible.builtin.stat:
    path: /sys/firmware/efi
  register: efi_dir

- name: Record firmware facts
  ansible.builtin.set_fact:
    boot_firmware: "{{ 'uefi' if efi_dir.stat.isdir | default(false) else 'bios' }}"
    grub_cfg_path: >-
      {{ '/boot/grub2/grub.cfg'
         if ansible_facts['os_family'] == 'RedHat'
         else '/boot/grub/grub.cfg' }}

- name: Assert Secure Boot state matches policy
  ansible.builtin.command: mokutil --sb-state
  register: sb_state
  changed_when: false
  failed_when: false
  when: boot_firmware == 'uefi'

- name: Fail when Secure Boot is disabled on a node that requires it
  ansible.builtin.assert:
    that:
      - "'SecureBoot enabled' in sb_state.stdout"
    fail_msg: >-
      Secure Boot is disabled on {{ inventory_hostname }} but boot_require_secureboot
      is true. Enrol the platform key via the BMC before continuing.
  when:
    - boot_firmware == 'uefi'
    - boot_require_secureboot | bool

- name: Deploy kernel module load list
  ansible.builtin.copy:
    dest: /etc/modules-load.d/10-platform.conf
    owner: root
    group: root
    mode: '0644'
    content: |
      {% for m in boot_required_modules %}
      {{ m }}
      {% endfor %}
  notify:
    - Rebuild initramfs
    - Reload modules-load

- name: Deploy modprobe options and hard blocks
  ansible.builtin.template:
    src: modprobe-platform.conf.j2
    dest: /etc/modprobe.d/10-platform-options.conf
    owner: root
    group: root
    mode: '0644'
    validate: '/usr/bin/test -r %s'
  notify: Rebuild initramfs

- name: Deploy dracut content policy (RedHat family)
  ansible.builtin.copy:
    dest: /etc/dracut.conf.d/99-platform.conf
    owner: root
    group: root
    mode: '0644'
    content: |
      hostonly="{{ 'yes' if boot_initramfs_hostonly else 'no' }}"
      add_drivers+=" {{ boot_initramfs_drivers | join(' ') }} "
      compress="zstd"
  when: ansible_facts['os_family'] == 'RedHat'
  notify: Rebuild initramfs

- name: Set kernel command line (RedHat family, BLS-aware)
  ansible.builtin.command:
    argv:
      - /usr/sbin/grubby
      - --update-kernel=ALL
      - "--args={{ boot_kernel_args | join(' ') }}"
  register: grubby_result
  changed_when: true
  when: ansible_facts['os_family'] == 'RedHat'

- name: Set kernel command line (Debian family)
  ansible.builtin.lineinfile:
    path: /etc/default/grub
    regexp: '^GRUB_CMDLINE_LINUX='
    line: 'GRUB_CMDLINE_LINUX="{{ boot_kernel_args | join(" ") }}"'
    owner: root
    group: root
    mode: '0644'
  when: ansible_facts['os_family'] == 'Debian'
  notify: Regenerate grub config

- name: Deploy udev storage rules
  ansible.builtin.copy:
    src: 70-storage-tuning.rules
    dest: /etc/udev/rules.d/70-storage-tuning.rules
    owner: root
    group: root
    mode: '0644'
  notify: Reload udev rules

- name: Enforce the default boot target
  ansible.builtin.file:
    src: "/usr/lib/systemd/system/{{ boot_default_target }}"
    dest: /etc/systemd/system/default.target
    state: link
    force: true

- name: Verify the running command line already carries the policy
  ansible.builtin.slurp:
    src: /proc/cmdline
  register: live_cmdline

- name: Report nodes whose running kernel predates the policy
  ansible.builtin.debug:
    msg: >-
      {{ inventory_hostname }} needs a reboot: missing
      {{ boot_kernel_args | reject('in', live_cmdline.content | b64decode) | list }}
  when: >-
    boot_kernel_args
    | reject('in', live_cmdline.content | b64decode)
    | list | length > 0
```

```yaml
---
# roles/boot_architecture/handlers/main.yml
- name: Reload modules-load
  ansible.builtin.systemd:
    name: systemd-modules-load.service
    state: restarted

- name: Reload udev rules
  ansible.builtin.shell:
    cmd: udevadm control --reload-rules && udevadm trigger --subsystem-match=block --action=change
  changed_when: true

- name: Rebuild initramfs
  ansible.builtin.command:
    argv: "{{ ['/usr/bin/dracut', '-f', '--regenerate-all']
              if ansible_facts['os_family'] == 'RedHat'
              else ['/usr/sbin/update-initramfs', '-u', '-k', 'all'] }}"
  changed_when: true

- name: Regenerate grub config
  ansible.builtin.command:
    argv:
      - "{{ '/usr/sbin/grub2-mkconfig' if ansible_facts['os_family'] == 'RedHat' else '/usr/sbin/grub-mkconfig' }}"
      - -o
      - "{{ grub_cfg_path }}"
  changed_when: true
```

```yaml
---
# roles/boot_architecture/defaults/main.yml
boot_require_secureboot: true
boot_default_target: multi-user.target
boot_initramfs_hostonly: false
boot_required_modules:
  - br_netfilter
  - overlay
  - nf_conntrack
  - dm_multipath
  - dm_round_robin
boot_initramfs_drivers:
  - dm_multipath
  - dm_round_robin
  - nvme_tcp
  - i40e
  - mlx5_core
boot_kernel_args:
  - net.ifnames=0
  - transparent_hugepage=never
  - intel_iommu=on
  - iommu=pt
  - console=ttyS0,115200n8
  - console=tty0
```

### 5.3 systemd units — a boot-path auditor with a hard failure mode

```ini
# /etc/systemd/system/node-boot-audit.service
[Unit]
Description=Assert node boot-path invariants (cmdline, modules, initramfs, target)
Documentation=man:systemd.service(5)
DefaultDependencies=no
After=sysinit.target systemd-modules-load.service local-fs.target
Before=multi-user.target
Wants=systemd-modules-load.service
# Do not let a failed audit take down an in-service node silently
OnFailure=node-boot-audit-alert.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/boot-audit.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=boot-audit
TimeoutStartSec=60s

# Hardening — this unit reads state, it never needs to write outside /run
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
RuntimeDirectory=boot-audit
ReadWritePaths=/run/boot-audit
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_READ_SEARCH
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/node-boot-audit-alert.service
[Unit]
Description=Report a failed boot-path audit to the fleet alerting endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/boot-audit-alert.sh
TimeoutStartSec=30s
```

```ini
# /etc/systemd/system/kubelet.service.d/10-boot-ordering.conf
# Drop-in: never start the kubelet before the boot-path invariants are proven.
[Unit]
After=node-boot-audit.service containerd.service
Requires=node-boot-audit.service

[Service]
# Bound the drain window during a rolling reboot
TimeoutStopSec=120s
KillMode=mixed
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/boot-audit.sh — invariants that must hold on every booted node.
set -euo pipefail

fail=0
note() { printf '%-6s %s\n' "$1" "$2"; }

required_args=(net.ifnames=0 transparent_hugepage=never intel_iommu=on)
cmdline="$(</proc/cmdline)"
for arg in "${required_args[@]}"; do
    if [[ $cmdline == *"$arg"* ]]; then
        note "OK" "cmdline carries ${arg}"
    else
        note "FAIL" "cmdline missing ${arg} — grubby/update-grub ran without a reboot?"
        fail=1
    fi
done

required_modules=(br_netfilter overlay dm_multipath)
for mod in "${required_modules[@]}"; do
    if lsmod | awk '{print $1}' | grep -qx "$mod"; then
        note "OK" "module ${mod} loaded"
    else
        note "FAIL" "module ${mod} not loaded — check /etc/modules-load.d and modprobe.d blocks"
        fail=1
    fi
done

# The initramfs must be newer than the modprobe policy that shapes it
initrd="/boot/initramfs-$(uname -r).img"
[[ -f $initrd ]] || initrd="/boot/initrd.img-$(uname -r)"
newest_policy="$(find /etc/modprobe.d /etc/dracut.conf.d -type f -newer "$initrd" 2>/dev/null | head -n1 || true)"
if [[ -n $newest_policy ]]; then
    note "FAIL" "initramfs older than ${newest_policy} — rebuild required before next reboot"
    fail=1
else
    note "OK" "initramfs newer than module policy"
fi

want_target="multi-user.target"
have_target="$(systemctl get-default)"
if [[ $have_target == "$want_target" ]]; then
    note "OK" "default target is ${want_target}"
else
    note "FAIL" "default target is ${have_target}, expected ${want_target}"
    fail=1
fi

printf '%s\n' "$fail" > /run/boot-audit/status
exit "$fail"
```

### 5.4 Kubernetes DaemonSet — node boot-path tuning applied cluster-wide

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: node-tuning
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-boot-tuner
  namespace: node-tuning
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-boot-tuner
  namespace: node-tuning
data:
  tune.sh: |
    #!/usr/bin/env bash
    set -euo pipefail

    echo "[tuner] kernel: $(uname -r)"
    echo "[tuner] cmdline: $(cat /host/proc/cmdline)"

    # 1. Kernel modules the CNI and CSI datapaths require.
    for mod in br_netfilter overlay nf_conntrack dm_multipath; do
      if ! grep -qx "$mod" /host/proc/modules 2>/dev/null \
         && ! awk '{print $1}' /host/proc/modules | grep -qx "$mod"; then
        echo "[tuner] loading ${mod}"
        chroot /host /sbin/modprobe "$mod"
      fi
    done

    # 2. Persist the module list so it survives a reboot.
    cat > /host/etc/modules-load.d/20-k8s-datapath.conf <<'EOF'
    br_netfilter
    overlay
    nf_conntrack
    dm_multipath
    EOF

    # 3. Block-layer tuning for every NVMe namespace on the node.
    for q in /host/sys/block/nvme*/queue; do
      [ -e "$q/scheduler" ] || continue
      echo none  > "$q/scheduler"      || true
      echo 1023  > "$q/nr_requests"    || true
      echo 2     > "$q/rq_affinity"    || true
      echo "[tuner] tuned $(dirname "$q")"
    done

    # 4. Report the boot-path facts this node actually has.
    echo "[tuner] firmware: $([ -d /host/sys/firmware/efi ] && echo uefi || echo bios)"
    echo "[tuner] default target: $(chroot /host /usr/bin/systemctl get-default)"
    echo "[tuner] uptime: $(cut -d' ' -f1 /host/proc/uptime)s"
    echo "[tuner] done; sleeping"
    exec sleep infinity
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-boot-tuner
  namespace: node-tuning
  labels:
    app.kubernetes.io/name: node-boot-tuner
    app.kubernetes.io/component: node-tuning
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: node-boot-tuner
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 10%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: node-boot-tuner
    spec:
      serviceAccountName: node-boot-tuner
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      priorityClassName: system-node-critical
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      containers:
        - name: tuner
          image: registry.example.net/platform/node-tuner:1.7.2
          command: ["/bin/bash", "/scripts/tune.sh"]
          securityContext:
            privileged: true
            readOnlyRootFilesystem: true
            capabilities:
              add: ["SYS_ADMIN", "SYS_MODULE"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: host
              mountPath: /host
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: modules
              mountPath: /lib/modules
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: host
          hostPath:
            path: /
            type: Directory
        - name: modules
          hostPath:
            path: /lib/modules
            type: Directory
        - name: scripts
          configMap:
            name: node-boot-tuner
            defaultMode: 0755
        - name: tmp
          emptyDir: {}
```

---

## 6. Verification and failure diagnosis

### 6.1 Standing verification battery

Run this on any node whose boot path you do not personally trust:

```console
$ cat /proc/cmdline                                   # what the kernel was actually told
$ systemd-analyze                                     # phase timing
$ systemd-analyze blame | head -n 10                  # slowest units
$ systemd-analyze critical-chain                      # the serialized path, not just totals
$ systemctl --failed                                  # anything that did not come up
$ systemctl get-default                               # intended service level
$ journalctl --list-boots                             # boot history
$ journalctl -b -1 -p err                             # errors from the previous boot
$ sudo dmesg --level=err,warn -T                      # hardware/driver complaints
$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS          # storage topology as mounted
$ findmnt --verify --verbose                          # validate /etc/fstab BEFORE rebooting
$ sudo systemd-analyze verify multi-user.target       # unit-graph sanity check
```

```console
$ systemctl --failed
  UNIT                       LOAD   ACTIVE SUB    DESCRIPTION
● multipathd.service         loaded failed failed Device-Mapper Multipath Device Controller

LOAD   = Reflects whether the unit definition was properly loaded.
ACTIVE = The high-level unit activation state, i.e. generalization of SUB.
SUB    = The low-level unit activation state, values depend on unit type.
1 loaded units listed.

$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -2 8f21c9a4d1b34e6f8a2c5d7e91b04f33 Mon 2026-08-03 14:02:11 UTC Wed 2026-08-05 02:58:40 UTC
 -1 b30e77c25a9f4d1e8c66a4f2b7d19e01 Wed 2026-08-05 03:16:02 UTC Wed 2026-08-05 03:16:44 UTC
  0 c9d4e1f8a2b74c3e95a1d6b0f8e27c14 Wed 2026-08-05 03:20:09 UTC Wed 2026-08-05 09:41:22 UTC
```

Boot `-1` lasted 42 seconds — that is a failed boot followed by a manual recovery. It is the first thing to read.

> **Persistent journals are a prerequisite.** By default on many distributions the journal lives in `/run/log/journal` and evaporates on reboot, which is exactly the data you need after a boot failure. Fix it once, fleet-wide:
> ```console
> $ sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
> $ sudo systemctl restart systemd-journald
> ```

### 6.2 Failure decision tree

```
Node does not come up
│
├─ No POST output / no firmware splash ───────────▶ Hardware, PSU, BMC. Not a Linux problem.
│
├─ Firmware splash, then "No bootable device" ────▶ Boot ENTRY problem
│    ├─ UEFI: efibootmgr -v from a live ISO — is the entry present? Is the ESP mounted?
│    └─ BIOS: is the ef02 BIOS boot partition present? Rerun grub2-install /dev/sdX.
│
├─ "grub rescue>" or "grub>" ─────────────────────▶ Boot LOADER can't find its config/modules
│    └─ set prefix=(hd0,gpt2)/grub2 ; set root=(hd0,gpt2) ; insmod normal ; normal
│
├─ GRUB menu appears, kernel panics immediately ──▶ KERNEL/initramfs mismatch
│    └─ "VFS: Unable to mount root fs on unknown-block(0,0)" = initramfs lacks the storage driver
│
├─ "dracut:/#" or "(initramfs)" prompt ───────────▶ initramfs can't assemble the real root
│    └─ Root device missing, LUKS unlocked, LVM not activated, multipath absent
│
├─ "Give root password for maintenance" ──────────▶ Root mounted, but a local-fs unit failed
│    └─ Almost always /etc/fstab: bad UUID, missing device, no `nofail`
│
├─ Login prompt but a service is missing ─────────▶ Userspace unit failure — systemctl --failed
│
└─ Boots, but takes minutes ──────────────────────▶ systemd-analyze critical-chain
     └─ Usually *-wait-online.service or a device unit hitting its 90 s timeout
```

### 6.3 Symptom → cause → fix

| Symptom | Most likely cause | Diagnosis | Fix |
|---|---|---|---|
| `VFS: Unable to mount root fs on unknown-block(0,0)` | initramfs lacks the storage driver (host-only build on new hardware) | `lsinitrd $img \| grep <driver>` | Boot old kernel, add `add_drivers+=`, `dracut -f --regenerate-all` |
| `dracut-initqueue timeout — starting timeout scripts` | `root=` device never appeared: wrong UUID, LVM/multipath not activated | `rd.break=pre-mount` then `lvs`, `blkid`, `dmsetup ls` | Correct `root=`/`rd.lvm.lv=`, include the module, rebuild |
| Boot stalls exactly 90 s then drops to emergency | A `/etc/fstab` entry whose device is absent | `journalctl -b -p err`, `systemctl list-units --type=mount --failed` | Add `nofail,x-systemd.device-timeout=10` or remove the entry |
| `grub rescue>` after a disk clone | `prefix`/UUID points at the old disk | `ls` at the rescue prompt to find the partition | `set prefix=…`, `insmod normal`, `normal`, then `grub2-install` + `grub2-mkconfig` |
| UEFI machine boots to firmware setup after motherboard swap | NVRAM boot variables lost with the board | `efibootmgr -v` from a live image | `efibootmgr -c -d /dev/nvme0n1 -p 1 -L rocky -l '\EFI\rocky\shimx64.efi'` |
| Out-of-tree module fails to load, `Required key not available` | Secure Boot rejecting an unsigned module | `mokutil --sb-state`, `dmesg \| grep -i 'key'` | Sign with a MOK and `mokutil --import`, or disable Secure Boot |
| NIC renamed after a kernel upgrade; network dead | Predictable-naming scheme version changed | `udevadm test-builtin net_id /sys/class/net/<if>` | Pin with a `.link` file matching on MAC, or set `net.ifnames=0` fleet-wide |
| Blacklisted module still loads | `blacklist` blocks alias autoload only | `modprobe --show-depends <mod>`, `lsmod \| grep <mod>` | Use `install <mod> /bin/false`, then rebuild the initramfs |
| Kernel arg "doesn't apply" | Config changed but never regenerated, or never rebooted | Compare `/proc/cmdline` with `grubby --info=DEFAULT` | Regenerate (`grubby`/`update-grub`) **and** reboot |
| Node reboots on its own at night | ACPI power-key event, or a BMC/watchdog action | `journalctl -b -1 -u systemd-logind`, `last -x reboot shutdown` | `HandlePowerKey=ignore`, audit BMC power policy |
| `systemctl isolate` killed unrelated services | Isolate stops everything outside the target's dependency graph | `systemctl list-dependencies <target>` | Use `systemctl start/stop` for individual units, never `isolate` on a live node |
| Shutdown hangs at "A stop job is running (1min 30s)" | Unit ignoring SIGTERM; `DefaultTimeoutStopSec` at 90 s | `systemd-analyze blame` on shutdown, `journalctl -b -1 -e` | Set unit `TimeoutStopSec=`, fix signal handling, lower the default |

### 6.4 The four recovery entry points, ordered by severity

```
1. systemd.unit=rescue.target      ← root mounted rw, all local FS, no network. Password required.
2. systemd.unit=emergency.target   ← root mounted RO, /bin/sh only. Password required.
3. rd.break=pre-mount              ← inside dracut, real root NOT yet mounted, at /sysroot.
4. init=/bin/bash                  ← no init at all. Root mounted RO. Nothing else runs.
```

**Recovering from a broken `/etc/fstab` — the single most common boot failure:**

```console
# At the GRUB menu: press 'e', append to the linux line, Ctrl-X to boot
linux ($root)/vmlinuz-5.14.0-427.el9.x86_64 root=/dev/mapper/rl-root ro systemd.unit=emergency.target

Give root password for maintenance
(or press Control-D to continue):

[root@node-17 ~]# mount -o remount,rw /
[root@node-17 ~]# findmnt --verify --verbose
/mnt/data
   [W] unreachable source: UUID=deadbeef-0000-4000-8000-000000000000: No such file or directory
   [W] non-bind mount source UUID=deadbeef-… is a directory or regular file
1 parse error, 2 errors, 0 warnings

[root@node-17 ~]# sed -i '/deadbeef/s/defaults/nofail,x-systemd.device-timeout=10/' /etc/fstab
[root@node-17 ~]# findmnt --verify
Success, no errors or warnings detected
[root@node-17 ~]# systemctl daemon-reload
[root@node-17 ~]# systemctl default
```

**Recovering an unmountable root from inside dracut:**

```console
# Append to the kernel line: rd.break=pre-mount rd.debug

Entering emergency mode. Exit the shell to continue.

dracut:/# lsblk
NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1     259:0    0 894.3G  0 disk
├─nvme0n1p1 259:1    0     1G  0 part
├─nvme0n1p2 259:2    0     1G  0 part
└─nvme0n1p3 259:3    0   892G  0 part

dracut:/# lvm vgscan
  Found volume group "rl" using metadata type lvm2
dracut:/# lvm vgchange -ay rl
  3 logical volume(s) in volume group "rl" now active
dracut:/# lsblk /dev/mapper/rl-root
NAME    MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS
rl-root 253:0    0  70G  0 lvm
dracut:/# mount -o ro /dev/mapper/rl-root /sysroot && echo MOUNT-OK
MOUNT-OK
dracut:/# rdsosreport                # writes a full diagnostic bundle to /run/initramfs
dracut:/# exit                       # continue the boot
```

The lesson from that transcript: the root LV was fine; LVM autoactivation inside the initramfs was not. The fix is `rd.lvm.lv=rl/root` on the command line plus an initramfs rebuild — not a reinstall.

**Recovering a lost root password (physical/console access implied):**

```console
# Append to the kernel line: rw init=/bin/bash
bash-5.1# mount -o remount,rw /
bash-5.1# passwd root
Changing password for user root.
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
bash-5.1# touch /.autorelabel        # required when SELinux is enforcing
bash-5.1# exec /sbin/init            # or: reboot -f
```

> `init=/bin/bash` is precisely why unattended physical access equals root, and why GRUB password protection (`grub2-setpassword`) plus a BIOS/BMC password are baseline controls on any machine outside a locked cage.

### 6.5 Pre-reboot checklist — the discipline that prevents §1

Before rebooting any node whose boot path you changed:

```console
$ findmnt --verify                                    # fstab is parseable and reachable
$ sudo grub2-mkconfig -o /boot/grub2/grub.cfg         # (or update-grub) — config regenerated
$ grubby --info=DEFAULT                               # the entry says what you think it says
$ sudo dracut -f --regenerate-all                     # initramfs matches current module policy
$ lsinitrd /boot/initramfs-$(uname -r).img | grep -c . # non-empty, plausible size
$ ls -l --time-style=full-iso /boot/initramfs-*.img /etc/modprobe.d/*  # initramfs is NEWER
$ sudo systemd-analyze verify default.target          # no dangling unit references
$ df -h /boot                                         # a full /boot silently truncates the initramfs
```

The last one deserves emphasis: a `/boot` at 100 % causes `dracut` to write a **truncated** initramfs, and on many distributions the package scriptlet still exits 0. The node then boots into dracut emergency mode with no prior warning. Check free space on `/boot` before every kernel operation, and alert on it in your fleet monitoring.

---

## 7. Command and file reference

| Area | Commands | Key files |
|---|---|---|
| Firmware | `efibootmgr`, `mokutil`, `bootctl`, `dmidecode` | `/sys/firmware/efi/`, `/boot/efi/EFI/` |
| Boot loader | `grub2-mkconfig`, `update-grub`, `grubby`, `grub2-install`, `grub2-setpassword` | `/etc/default/grub`, `/etc/grub.d/`, `/boot/grub2/grub.cfg`, `/boot/loader/entries/` |
| Kernel | `uname -r`, `dmesg`, `sysctl` | `/proc/cmdline`, `/proc/version`, `/boot/config-$(uname -r)` |
| initramfs | `dracut`, `lsinitrd`, `update-initramfs`, `lsinitramfs` | `/etc/dracut.conf.d/`, `/etc/initramfs-tools/` |
| Modules | `lsmod`, `modinfo`, `modprobe`, `insmod`, `rmmod`, `depmod` | `/etc/modprobe.d/`, `/etc/modules-load.d/`, `/lib/modules/$(uname -r)/modules.dep`, `/proc/modules` |
| Hardware | `lspci`, `lsusb`, `lscpu`, `lsblk`, `lsdev`, `hwinfo` | `/proc/interrupts`, `/proc/ioports`, `/proc/dma`, `/proc/cpuinfo`, `/sys/bus/`, `/sys/class/` |
| udev | `udevadm info\|monitor\|trigger\|test\|control` | `/etc/udev/rules.d/`, `/usr/lib/udev/rules.d/`, `/dev/disk/by-*/` |
| init / targets | `systemctl`, `systemd-analyze`, `runlevel`, `who -r`, `telinit` | `/etc/systemd/system/default.target`, `/usr/lib/systemd/system/`, `/etc/inittab` (SysV) |
| Shutdown | `shutdown`, `halt`, `poweroff`, `reboot`, `wall`, `kexec`, `systemd-inhibit` | `/run/nologin`, `/etc/systemd/logind.conf` |
| Logs | `journalctl`, `dmesg`, `rdsosreport` | `/var/log/journal/`, `/run/log/journal/`, `/var/log/boot.log` |

---

## 8. References

**Certification and objectives**
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/
- LPIC-1 Exam 101 objectives, version 5.0 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102 objectives, version 5.0 — https://www.lpi.org/our-certifications/exam-102-objectives/

**Kernel and boot process**
- The kernel's command-line parameters — https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Kernel module signing facility — https://www.kernel.org/doc/html/latest/admin-guide/module-signing.html
- Linux Filesystem Hierarchy Standard 3.0 — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- sysfs — the filesystem for exporting kernel objects — https://www.kernel.org/doc/html/latest/filesystems/sysfs.html
- initramfs / early userspace — https://www.kernel.org/doc/html/latest/driver-api/early-userspace/early_userspace_support.html

**Boot loader and firmware**
- GNU GRUB Manual 2.12 — https://www.gnu.org/software/grub/manual/grub/grub.html
- Boot Loader Specification — https://uapi-group.org/specifications/specs/boot_loader_specification/
- Discoverable Partitions Specification — https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
- UEFI Specification (current release) — https://uefi.org/specifications
- `efibootmgr` — https://github.com/rhboot/efibootmgr
- `shim` (Secure Boot first-stage loader) — https://github.com/rhboot/shim

**init system**
- systemd manual pages index — https://www.freedesktop.org/software/systemd/man/latest/
- `systemd.unit(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.target(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
- `systemctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `systemd-analyze(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `bootup(7)` — the boot process — https://www.freedesktop.org/software/systemd/man/latest/bootup.html
- `systemd-inhibit(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-inhibit.html
- `logind.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html
- `kernel-command-line(7)` — https://www.freedesktop.org/software/systemd/man/latest/kernel-command-line.html

**Device management**
- `udev(7)` — https://www.freedesktop.org/software/systemd/man/latest/udev.html
- `udevadm(8)` — https://www.freedesktop.org/software/systemd/man/latest/udevadm.html
- `systemd.link(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.link.html
- Predictable Network Interface Names — https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
- `modprobe.d(5)` — https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- `modprobe(8)` — https://man7.org/linux/man-pages/man8/modprobe.8.html

**Distribution documentation**
- Red Hat Enterprise Linux 9 — Managing, monitoring and updating the kernel — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_monitoring_and_updating_the_kernel/index
- Red Hat Enterprise Linux 9 — Configuring basic system settings (targets, boot) — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/index
- `dracut.conf(5)` — https://man7.org/linux/man-pages/man5/dracut.conf.5.html
- `dracut(8)` — https://man7.org/linux/man-pages/man8/dracut.8.html
- Debian Administrator's Handbook — Booting and init — https://debian-handbook.info/browse/stable/sect.system-boot.html
- `initramfs-tools(8)` — https://manpages.debian.org/stable/initramfs-tools-core/initramfs-tools.8.en.html
- SUSE Linux Enterprise Server — Booting a Linux system — https://documentation.suse.com/sles/15-SP6/html/SLES-all/cha-boot.html

**Automation tooling**
- cloud-init module reference — https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Ansible `ansible.builtin` module index — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/index.html
- Kubernetes DaemonSet — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/