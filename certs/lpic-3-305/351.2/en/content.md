# 351.2 Xen

> **LPIC-3 Virtualization and Containerization — Exam 305-300, v3.0**
> Objective weight: **5**. Focus: Xen **4.x**, the `xl`/libxenlight toolstack.
> Key knowledge areas: Xen architecture (networking + storage), basic Dom0/DomU configuration, domain manipulation and analysis, troubleshooting.

---

## 1. Motivation: the architectural problem Xen solves

Every hypervisor answers one question: **who owns the privileged instructions?** On bare metal, the OS kernel runs in ring 0 and executes `HLT`, `INVLPG`, page-table writes, I/O port access and interrupt masking directly. Put two kernels on one machine and they both want ring 0. That is the collision a hypervisor arbitrates.

Xen is a **Type-1 (bare-metal) hypervisor**: a small (~1 MB) piece of code that boots *before* any Linux kernel, takes ring 0 (or the VMX/SVM root mode on modern CPUs), and then boots a first, privileged Linux instance — **Dom0** — as an ordinary guest. This inverts the mental model most people bring from KVM:

- With **KVM**, Linux *is* the hypervisor; `kvm.ko` turns the host kernel into a VMM and guests are `qemu` processes scheduled by the host scheduler.
- With **Xen**, the hypervisor is *not* Linux. Linux (Dom0) is a client of the hypervisor, exactly like every guest, distinguished only by privilege: it drives the physical hardware and runs the toolstack.

### The production problems this shape is good at

1. **Isolation of the control plane from the data plane.** The scheduler, memory allocator and CPU arbitration live in the hypervisor, not in a 30-million-line Linux kernel. A Dom0 kernel panic can be survivable; the hypervisor keeps running and (with driver domains) guests keep executing. This is why Xen underpins clouds that value blast-radius containment (historically AWS EC2's first decade; QubesOS's security model; XCP-ng/Citrix Hypervisor).

2. **Paravirtualization for CPUs without virtualization extensions.** Xen predates Intel VT-x/AMD-V. Its **PV** mode runs a *modified* guest that never issues privileged instructions — it makes **hypercalls** instead. That legacy is now mostly a liability (see §2), but it produced the split-driver architecture that still gives Xen its I/O performance.

3. **Deterministic scheduling and CPU partitioning.** `cpupools`, hard/soft vCPU affinity, NUMA-aware placement and the Credit2/RTDS/`null` schedulers let you carve a machine into partitions with latency guarantees — the reason Xen shows up in telco NFV and real-time embedded (automotive, avionics via ARINC653).

4. **Driver domains and stub domains.** The device model and even physical device drivers can be pushed *out* of Dom0 into deprivileged domains. A compromised NIC driver compromises a disposable domain, not the whole host.

### The mechanism you must hold in your head

A guest never touches hardware. Instead:

```
   DomU (unprivileged guest)                 Dom0 (privileged)
  ┌───────────────────────┐               ┌───────────────────────┐
  │  frontend driver       │  XenStore     │  backend driver        │
  │  (netfront / blkfront) │◄────bus──────►│  (netback / blkback)   │
  │        │  ▲            │               │        │  ▲            │
  └────────┼──┼────────────┘               └────────┼──┼────────────┘
           │  │ event channel (virtual IRQ)         │  │
           ▼  │ grant table (shared memory pages)   ▼  │
      ┌───────────────────────── Xen hypervisor ──────────────────┐
      │  hypercalls · scheduler · MMU · event channels · grants    │
      └────────────────────────────────────────────────────────────┘
                              physical hardware
```

Four primitives make this work — **memorize them, they are examinable and they are what you debug**:

| Primitive | What it is | Analogy |
|---|---|---|
| **Hypercall** | Synchronous guest→hypervisor call (via `syscall`-like trap) | A syscall, but crossing into the hypervisor |
| **Event channel** | Asynchronous notification / virtual interrupt between domains and the hypervisor | A software IRQ line |
| **Grant table** | Per-domain table authorizing another domain to map or transfer specific memory pages | Memory `mmap` permission slip |
| **XenStore** | Hierarchical key/value database (`/local/domain/<id>/...`) for config and device negotiation | A shared `/proc` + D-Bus |

Backend and frontend drivers find each other by *writing to XenStore* (the "xenbus" handshake), then exchange data over a shared **ring buffer** whose pages are shared via **grant tables** and whose "you've got mail" signal is an **event channel**. When a `vif` won't come up or a disk won't attach, this handshake is exactly where you look.

---

## 2. Technical comparisons and trade-offs

### 2.1 Virtualization modes — the single most important table in this objective

| | **PV** (Paravirtual) | **HVM** (Hardware VM) | **PVHVM** (PV-on-HVM) | **PVH** (modern PV) |
|---|---|---|---|---|
| CPU virt extensions | Not required | **Required** (VT-x/AMD-V) | Required | Required |
| Guest kernel | Must be Xen-aware | Unmodified (any OS) | Unmodified + PV drivers | Must be PVH-aware |
| Emulated device model (QEMU) | None | **Full** (qemu-dm) | Present but bypassed for I/O | **None** |
| Emulated BIOS/UEFI | None | SeaBIOS / OVMF | SeaBIOS / OVMF | None (direct kernel/PVH boot) |
| Boot path | pygrub / PV-GRUB / direct kernel | Firmware → bootloader | Firmware → bootloader | Direct kernel or Xen boot ABI |
| Privileged ops | Hypercalls | Hardware traps (VMEXIT) | Hardware traps | Hardware traps |
| Page tables | Software (hypercall-mediated, or shadow) | **HAP** (EPT/NPT) hardware | HAP | HAP |
| I/O path | Split PV drivers | Emulated (slow) → PV drivers | PV drivers (fast) | PV drivers (fast) |
| Interrupts | Event channels | Emulated APIC | vAPIC + event channels | Event channels |
| Attack surface | Small (no QEMU) | **Large** (QEMU device model) | Large (QEMU present) | **Small** (no QEMU) |
| Boot Windows? | No | **Yes** | Yes | No |
| Typical use in 2020s | **Deprecated / avoid** | Windows, appliances needing firmware | Legacy Linux HVM | **Recommended for Linux** |

**The trade-off in one sentence:** PV avoids QEMU but pays a syscall/pagefault tax and is a security liability on 64-bit (Meltdown/XPTI, the retired PV32); HVM runs anything but drags a large QEMU attack surface; **PVH is the modern sweet spot for Linux** — hardware virtualization for the CPU and MMU, split PV drivers for I/O, and *no QEMU and no firmware at all*. Since Xen 4.10 PVH DomU is stable; treat it as the default for new Linux guests and reserve HVM for Windows or anything that insists on a BIOS.

> **Historical trap for the exam and for real hosts:** classic 64-bit PV guests were the vector that forced **XPTI (Xen Page Table Isolation)** after Meltdown, with a real throughput cost. This is a large part of *why* the project pushed everyone toward PVH. If you inherit a fleet of PV guests, migrating them to PVH is a security posture improvement, not just a cleanup.

### 2.2 Xen vs. KVM — choosing the platform

| Dimension | **Xen** | **KVM** |
|---|---|---|
| Type | Type-1, hypervisor boots first | Type-1-in-Linux (kernel module) |
| Control-plane isolation | Strong (Dom0 separable, driver domains) | Weak (host kernel = hypervisor) |
| Dom0/host crash blast radius | Guests can survive with driver domains | Host crash kills all guests |
| Device model | External QEMU (HVM), optional stub-domain isolation | QEMU per guest as host process |
| Live migration | `xl migrate` (shared storage) / `xl save`/`restore` | `virsh migrate` |
| CPU partitioning | cpupools, RTDS/null schedulers, ARINC653 | cgroups/CFS, `isolcpus` |
| Ecosystem toolstack | `xl` (libxl), XAPI (XCP-ng) | libvirt, oVirt, Proxmox |
| Kernel driver reuse | Needs Xen-aware backends in Dom0 | Any Linux driver works instantly |
| Security research pedigree | QubesOS, AWS (historic), embedded/RT | Cloud default (GCP, most OpenStack) |

**Guidance:** choose Xen when control-plane isolation, deterministic scheduling, or driver-domain security is the requirement; choose KVM when you want the entire Linux driver and tooling ecosystem with zero friction. For this exam, you must know Xen's shape well enough to *justify* that choice.

### 2.3 Storage backend trade-offs

| Backend spec | Mechanism | Formats | Performance | When to use |
|---|---|---|---|---|
| `phy:` | Direct block device (LVM LV, partition, iSCSI LUN, DRBD) | raw only | **Highest** | Production; the default choice |
| `file:` | Loopback-mounted image | raw | Poor (loop overhead, double caching) | Never in production |
| `qdisk` (`format=qcow2`) | QEMU block backend | raw, qcow2, vhd | Medium; snapshots & thin-prov | Images that need snapshots |
| `tap:aio` / blktap2 | Userspace `tapdisk` | raw, vhd | High; snapshot chains (vhd) | Where blktap is available |

**Rule of thumb:** LVM logical volumes over `phy:` for anything you care about; `qcow2` over `qdisk` only when you need copy-on-write snapshots and accept the throughput cost.

### 2.4 Scheduler trade-offs

| Scheduler | Model | Latency | Fairness | Use case |
|---|---|---|---|---|
| **credit** | Proportional-share, weight+cap | Fair, not low-latency | Good | Legacy default |
| **credit2** | Redesigned proportional-share | Better latency + fairness | **Good** | **Current default** |
| **rtds** | Real-Time Deferrable Server (period/budget) | **Deterministic** | Reservation | Real-time / NFV |
| **null** | Static 1:1 vCPU↔pCPU, no scheduling | **Minimal** | None | Max performance, partitioned hosts |
| **arinc653** | Time-partitioned (avionics) | Deterministic | Partition-bound | Safety-critical |

---

## 3. Complete infrastructure and configuration files (unabridged)

Xen predates the YAML era; `xl` uses a **key/value config syntax** (`xl.cfg(5)`). What follows are complete, syntactically valid files for a production node. Version paths assume Debian 12 with Xen 4.17 — adjust `xen-4.17` to your installed version.

### 3.1 Dom0 boot: hand the machine to the hypervisor

The kernel does **not** boot first — Xen does, then chainloads the Dom0 kernel as a multiboot module. On Debian, `/etc/default/grub` drives this:

```sh
# /etc/default/grub  — Dom0 hypervisor parameters
# The Xen *hypervisor* command line (NOT the Linux command line):
GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=8192M,max:8192M \
dom0_max_vcpus=4 dom0_vcpus_pin \
gnttab_max_frames=256 \
cpufreq=xen \
com1=115200,8n1 console=com1,vga \
sched=credit2"

# The Dom0 *Linux kernel* command line:
GRUB_CMDLINE_LINUX="console=hvc0 earlyprintk=xen"

# Prefer the Xen menuentry as default:
GRUB_DEFAULT="Debian GNU/Linux, with Xen hypervisor"
```

**Why these matter in production (and on the exam):**

- `dom0_mem=8192M,max:8192M` — **pin Dom0's memory**. Without a `max:`, autoballooning shrinks Dom0 to make room for guests and then Dom0 OOM-kills your toolstack under pressure. Setting current == max disables ballooning of Dom0.
- `dom0_max_vcpus=4 dom0_vcpus_pin` — give Dom0 a fixed, pinned set of pCPUs so guest load never starves the control plane (and vice versa).
- `gnttab_max_frames` — grant-table pressure from many/high-throughput `vif`/`vbd` frontends; raise it on dense hosts (you will see "grant table" errors in `xl dmesg` when it is too low).
- `com1=... console=com1` — serial console. On a real hypervisor host this is non-negotiable: Dom0 graphics may be gone and `xl` may be wedged; the serial line is how you reach `xl dmesg`.

Regenerate and reboot:

```
$ sudo update-grub
Generating grub configuration file ...
Found Xen hypervisor version: 4.17.3
...
$ sudo systemctl reboot
```

The equivalent **manual GRUB stanza** (know how to read it):

```
menuentry 'Debian GNU/Linux, with Xen hypervisor' {
    insmod multiboot2
    multiboot2  /boot/xen-4.17.gz placeholder dom0_mem=8192M,max:8192M \
                dom0_max_vcpus=4 dom0_vcpus_pin sched=credit2 \
                com1=115200,8n1 console=com1,vga
    module2     /boot/vmlinuz-6.1.0-18-amd64 placeholder \
                root=/dev/mapper/vg0-root ro console=hvc0 earlyprintk=xen
    module2     /boot/initrd.img-6.1.0-18-amd64
}
```

### 3.2 Global toolstack config — `/etc/xen/xl.conf`

```sh
## /etc/xen/xl.conf — libxl / xl toolstack defaults (xl.conf(5))

# Do NOT autoballoon Dom0 to satisfy new domains. We pinned dom0_mem above;
# leave this off and manage memory explicitly. This is the #1 stability setting.
autoballoon="off"

# Serialize concurrent xl operations against this lock.
lockfile="/var/lock/xl"

# Default networking script + bridge for any vif that omits them.
vif.default.script="vif-bridge"
vif.default.bridge="xenbr0"

# First virtual disk letter when a config uses positional vdevs.
blkdev_start="xvda"

# Machine-readable output for scripting (xl list -l, etc.).
output_format="json"

# Keep a domain's config with the running domain so `xl migrate` / reboot
# re-reads the *effective* config, not the on-disk one.
claim_mode="1"
```

### 3.3 Dom0 host networking — a bridge the `vif`s attach to

Guest `vif`s are one half of a veth-like pair whose Dom0 end (`vifX.Y`) is enslaved to a Linux bridge. Define that bridge on the host. Debian `ifupdown`:

```sh
# /etc/network/interfaces.d/xenbr0
auto xenbr0
iface xenbr0 inet static
    address        10.20.0.10/24
    gateway        10.20.0.1
    bridge_ports   eno1
    bridge_stp     off
    bridge_fd      0
    bridge_maxwait 0
    # Hardware offloads on the bridge port often break under high vif density:
    # up ethtool -K eno1 tx off rx off gso off tso off
```

`systemd-networkd` equivalent (two files):

```ini
# /etc/systemd/network/10-xenbr0.netdev
[NetDev]
Name=xenbr0
Kind=bridge

[Bridge]
STP=false
```
```ini
# /etc/systemd/network/20-xenbr0.network
[Match]
Name=xenbr0
[Network]
Address=10.20.0.10/24
Gateway=10.20.0.1
```
```ini
# /etc/systemd/network/15-eno1-bind.network
[Match]
Name=eno1
[Network]
Bridge=xenbr0
```

### 3.4 A production **PVH** Linux DomU — `/etc/xen/pvh-web01.cfg`

The modern default. No QEMU, no firmware, hardware MMU, PV I/O.

```sh
# ── /etc/xen/pvh-web01.cfg ─────────────────────────────────────────
# Modern paravirtualized-with-hardware guest. No QEMU device model.

name        = "pvh-web01"
type        = "pvh"                    # PVH builder (Xen ≥ 4.10)

# Memory: current allocation and ceiling. maxmem enables in-guest ballooning
# up to 4 GiB without a reboot.
memory      = 2048                     # MiB
maxmem      = 4096                     # MiB

# CPU: 2 online now, hot-pluggable up to 4. Soft-pin to NUMA node 0.
vcpus       = 2
maxvcpus    = 4
cpus        = "8-15"                   # hard affinity mask (node 0 cores)

# Boot a Dom0-hosted kernel directly (PVH boot ABI) — no bootloader needed.
kernel      = "/var/lib/xen/kernels/vmlinuz-6.1.0-18-amd64"
ramdisk     = "/var/lib/xen/kernels/initrd.img-6.1.0-18-amd64"
cmdline     = "root=/dev/xvda1 ro console=hvc0 net.ifnames=0"

# Storage: LVM logical volumes over the fast phy backend.
disk = [
    "phy:/dev/vg_xen/pvh-web01-root,xvda,w",
    "phy:/dev/vg_xen/pvh-web01-data,xvdb,w",
]

# Networking: one bridged vif with a stable, locally-administered MAC.
# The 00:16:3e OUI is Xen's registered range — always use it.
vif = [
    "mac=00:16:3e:2a:14:01,bridge=xenbr0,vifname=vif.web01",
]

# Power-event policy: guest halt destroys, guest reboot restarts,
# a crash restarts (flip to "preserve" when you need a post-mortem).
on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "restart"
```

### 3.5 A legacy **PV** DomU booting its own kernel via pygrub — `/etc/xen/pv-legacy01.cfg`

You will still meet these; know how they boot.

```sh
# ── /etc/xen/pv-legacy01.cfg ───────────────────────────────────────
name        = "pv-legacy01"
type        = "pv"                     # older syntax: builder="linux"
memory      = 1024
maxmem      = 2048
vcpus       = 2

# pygrub reads the guest's OWN /boot/grub/grub.cfg from inside its disk
# image and extracts the kernel/initrd — the guest controls its kernel.
bootloader  = "/usr/lib/xen-4.17/bin/pygrub"
# Alternative, fully Dom0-controlled boot (comment bootloader, use these):
#   kernel  = "/var/lib/xen/kernels/vmlinuz-6.1-amd64"
#   ramdisk = "/var/lib/xen/kernels/initrd.img-6.1-amd64"
#   extra   = "root=/dev/xvda1 ro console=hvc0"

disk = [
    "phy:/dev/vg_xen/pv-legacy01-root,xvda,w",
    "phy:/dev/vg_xen/pv-legacy01-swap,xvdb,w",
]
vif = [ "mac=00:16:3e:2a:14:05,bridge=xenbr0" ]

on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "restart"
```

### 3.6 A **HVM** DomU (Windows / firmware-dependent) — `/etc/xen/hvm-win01.cfg`

Full emulation with an isolated device model and PV-on-HVM drivers.

```sh
# ── /etc/xen/hvm-win01.cfg ─────────────────────────────────────────
name        = "hvm-win01"
type        = "hvm"                    # older syntax: builder="hvm"
memory      = 8192
maxmem      = 8192                     # Windows dislikes ballooning; pin it
vcpus       = 4
maxvcpus    = 4

# Emulated platform firmware. "seabios" = legacy BIOS; "ovmf" = UEFI.
bios        = "ovmf"
boot        = "dc"                     # try disk, then cdrom (order = string)

# Device model: qemu-xen, isolated in its own stub domain so a QEMU
# compromise does not reach Dom0.
device_model_version               = "qemu-xen"
device_model_stubdomain_override   = 1

# Storage: qcow2 via the QEMU qdisk backend (snapshots), plus install ISO.
disk = [
    "format=qcow2, vdev=xvda, access=rw, target=/var/lib/xen/images/win01.qcow2",
    "file:/srv/iso/Win2022.iso, vdev=xvdc, devtype=cdrom, access=ro",
]

# PV-on-HVM: an emulated e1000 that Windows PV drivers later accelerate.
vif = [
    "mac=00:16:3e:2a:14:02,bridge=xenbr0,model=e1000",
]

# Graphical console over VNC, bound to loopback (reach it via SSH tunnel).
vnc         = 1
vnclisten   = "127.0.0.1"
vncdisplay  = 1
usbdevice   = "tablet"                 # absolute pointer, fixes VNC drift
serial      = "pty"

# PCI passthrough of a GPU (needs IOMMU/VT-d and the device stub-bound
# to xen-pciback in Dom0). Uncomment when the device is isolated:
# pci = [ "0000:04:00.0", "0000:04:00.1" ]

on_poweroff = "destroy"
on_reboot   = "restart"
on_crash    = "preserve"               # keep the corpse for forensics
```

---

## 4. CLI commands and real terminal output

### 4.1 Inspecting the host

```
$ sudo xl info
host                   : xen-node01
release                : 6.1.0-18-amd64
version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01)
machine                : x86_64
nr_cpus                : 32
max_cpu_id             : 63
nr_nodes               : 2
cores_per_socket       : 8
threads_per_core       : 2
cpu_mhz                : 2900.000
hw_caps                : bfebfbff:77fef3ff:2c100800:00000121:...
virt_caps              : pv hvm hvm_directio pv_directio hap shadow iommu
total_memory           : 262144
free_memory            : 245760
sharing_freed_memory   : 0
outstanding_claims     : 0
free_cpus              : 0
xen_major              : 4
xen_minor              : 17
xen_extra              : .3
xen_version            : 4.17.3
xen_caps               : xen-3.0-x86_64 hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
xen_scheduler          : credit2
xen_pagesize           : 4096
platform_params        : virt_start=0xffff800000000000
xen_commandline        : placeholder dom0_mem=8192M,max:8192M dom0_max_vcpus=4 dom0_vcpus_pin sched=credit2
cc_compiler            : gcc (Debian 12.2.0-14) 12.2.0
```

> **Read `virt_caps` first.** `hvm` means VT-x/AMD-V is present and enabled in firmware — no `hvm` here and you cannot run HVM/PVHVM/PVH guests. `hvm_directio` + `iommu` mean PCI passthrough is possible. `hap` means hardware page tables (EPT/NPT) are available. If `iommu` is absent, fix VT-d/IOMMU in BIOS before you attempt passthrough.

### 4.2 Listing and creating domains

```
$ sudo xl list
Name                                        ID   Mem VCPUs      State   Time(s)
Domain-0                                     0  8192     4     r-----   18423.4
pvh-web01                                    7  2048     2     -b----     942.1
hvm-win01                                    9  8192     4     -b----    5310.7
```

State flags (`xl list` legend — examinable): **r**=running, **b**=blocked (idle, waiting for I/O — *normal*), **p**=paused, **s**=shutdown, **c**=crashed, **d**=dying.

```
$ sudo xl create /etc/xen/pvh-web01.cfg
Parsing config from /etc/xen/pvh-web01.cfg

$ sudo xl create -c /etc/xen/pvh-web01.cfg          # -c attaches the console
Parsing config from /etc/xen/pvh-web01.cfg
[    0.000000] Linux version 6.1.0-18-amd64 ...
[    0.512300] Xen: PVH environment detected
...
Debian GNU/Linux 12 pvh-web01 hvc0
pvh-web01 login:                                    # Ctrl-] to detach

$ sudo xl create /etc/xen/pvh-web01.cfg pause=1     # create but leave paused
$ sudo xl create /etc/xen/pvh-web01.cfg 'memory=4096'  # override a key inline
```

### 4.3 Console, lifecycle, live inspection

```
$ sudo xl console pvh-web01          # attach; Ctrl-] to exit
$ sudo xl pause pvh-web01
$ sudo xl unpause pvh-web01
$ sudo xl shutdown pvh-web01         # ACPI/PV clean shutdown (graceful)
$ sudo xl shutdown -w pvh-web01      # ...and wait for it to complete
$ sudo xl reboot pvh-web01
$ sudo xl destroy pvh-web01          # HARD kill — like pulling power
$ sudo xl uptime pvh-web01
Name                                ID Uptime
pvh-web01                            7 0 days,  3:27:41
```

### 4.4 CPU: affinity, pinning, hot-plug

```
$ sudo xl vcpu-list pvh-web01
Name              ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)
pvh-web01          7     0    10   -b-      512.3  8-15 / all
pvh-web01          7     1    12   r--      429.8  8-15 / all

$ sudo xl vcpu-pin pvh-web01 0 8         # hard-pin vCPU0 to pCPU8
$ sudo xl vcpu-pin pvh-web01 1 9
$ sudo xl vcpu-set pvh-web01 4           # hot-add vCPUs up to maxvcpus
```

### 4.5 Memory ballooning

```
$ sudo xl mem-max pvh-web01 4096         # raise the ceiling (MiB)
$ sudo xl mem-set pvh-web01 1024         # balloon the guest down to 1 GiB now
```

> `mem-set` above `mem-max` silently clamps. Ballooning a guest below what its workload needs induces in-guest OOM — the balloon driver returns pages to the hypervisor, and the guest sees them as *gone*, not *swapped*.

### 4.6 Real-time monitoring — `xentop`

```
$ sudo xentop
xentop - 14:32:07   Xen 4.17.3
3 domains: 1 running, 2 blocked, 0 paused, 0 crashed, 0 dying, 0 shutdown
Mem: 268435456k total, 22675456k used, 245760000k free    CPUs: 32 @ 2900MHz
      NAME  STATE  CPU(sec) CPU(%)     MEM(k) MEM(%)  MAXMEM(k) MAXMEM(%) VCPUS NETS NETTX(k) NETRX(k) VBDS VBD_OO VBD_RD VBD_WR
  Domain-0 -----r    18423    3.1    8388608    3.1    8388608       3.1     4    0        0        0    0      0      0      0
 hvm-win01 --b---     5310    2.4    8388608    3.1    8388608       3.1     4    1   142033   983221    2      0 1204553  442019
 pvh-web01 --b---      942    0.6    2097152    0.8    4194304       1.6     2    1    50127   118904    2      0  330218   90441
```

Watch **VBD_OO** (block "out of order"/queue-full events): non-zero and climbing means the storage backend is saturated. **NETTX/NETRX** localize noisy-neighbour network guests.

### 4.7 Save / restore (suspend-to-disk) and live migration

```
$ sudo xl save pvh-web01 /var/lib/xen/save/pvh-web01.chk
Saving to /var/lib/xen/save/pvh-web01.chk new xl format (info 0x3/0x0/1274)
xc: info: Saving domain 7, type x86 PV
xc: Frames: 524288/524288  100%
xc: End of stream: 0/0    0%

$ sudo xl restore /var/lib/xen/save/pvh-web01.chk
Loading new save file /var/lib/xen/save/pvh-web01.chk (new xl fmt info 0x3/0x0/1274)
 Savefile contains xl domain config in JSON format
Parsing config from <saved>
xc: info: Restoring domain, type x86 PV
xc: Frames: 524288/524288  100%
```

```
$ sudo xl migrate --live hvm-win01 xen-node02
migration target: Ready to receive domain.
Saving to migration stream new xl format (info 0x3/0x0/1483)
Loading new save file <incoming migration stream> (new xl fmt info 0x3/0x0/1483)
 Savefile contains xl domain config in JSON format
Parsing config from <saved>
xc: info: Saving domain 9, type x86 HVM
xc: Frames: 2097152/2097152  100%
xc: End of stream: 0/0    0%
migration sender: Target reports successful startup.
Migration successful.
```

> **Precondition:** the guest's disk must be reachable identically on both hosts (shared iSCSI/NFS/DRBD/Ceph, or identical `phy:` targets). `xl migrate` moves *memory and CPU state*, not storage. Passwordless SSH `root@xen-node02` and matching Xen versions are also required.

### 4.8 Hypervisor ring buffer and per-guest logs

```
$ sudo xl dmesg | tail -n 8
(XEN) [  18423.114] grant_table.c:1234: Increased maptrack size to 2048 frames
(XEN) [  18500.882] d9v2 Triple fault - invoking HVM shutdown action
(XEN) [  18501.010] HVM9 save: CPU
(XEN) [  18501.140] HVM9 restore: CPU 0

$ sudo tail -f /var/log/xen/xl-hvm-win01.log        # per-domain xl toolstack log
$ sudo tail -f /var/log/xen/qemu-dm-hvm-win01.log   # per-HVM-domain QEMU log
```

### 4.9 XenStore — the device-negotiation database

```
$ sudo xenstore-ls /local/domain/7
name = "pvh-web01"
domid = "7"
device = ""
 vif = ""
  0 = ""
   backend = "/local/domain/0/backend/vif/7/0"
   backend-id = "0"
   state = "4"                    # 4 = "Connected"; anything <4 = handshake stuck
   mac = "00:16:3e:2a:14:01"
 vbd = ""
  51712 = ""                      # 51712 = xvda (major/minor encoded)
   backend = "/local/domain/0/backend/vbd/7/51712"
   state = "4"
control = ""
 shutdown = ""

$ sudo xenstore-read /local/domain/7/name
pvh-web01

$ sudo xenstore-list /local/domain/7/device
vif
vbd

$ sudo xenstore-watch /local/domain/7/control/shutdown   # block until a value change
```

> **`state`** is the xenbus state machine (`XenbusStateConnected = 4`). A `vif` or `vbd` stuck at `state = "1"` (Initialising) or `"3"` (Connecting) is a **handshake that never completed** — the backend driver isn't loaded, the bridge doesn't exist, or the backend hit an error. This is the ground truth when `xl` reports a device but the guest can't see it.

---

## 5. Verification and failure-diagnosis guide

### 5.1 Post-install verification ladder (run top to bottom)

```
# 1. Is the hypervisor actually running? (not just a Xen-flavoured kernel)
$ sudo xl info | grep -E 'xen_version|xen_caps|virt_caps'
xen_version : 4.17.3
xen_caps    : xen-3.0-x86_64 hvm-3.0-x86_64
virt_caps   : pv hvm hvm_directio hap iommu

# 2. Confirm you booted UNDER Xen as Dom0, not on bare metal:
$ cat /sys/hypervisor/type
xen
$ cat /sys/hypervisor/properties/capabilities
control_d                             # this string == "I am Dom0"

# 3. Are the toolstack daemons up?
$ systemctl is-active xen-qemu-dom0-disk-backend.service xenconsoled.service \
                      xen-init-dom0.service xendomains.service
active
active
active
active

# 4. Is XenStore answering?
$ sudo xenstore-read /local/domain/0/name
Domain-0

# 5. Does the guest bridge exist and carry vifs?
$ ip -br link show master xenbr0
eno1        UP  bc:24:11:aa:bb:cc
vif7.0      UP  fe:ff:ff:ff:ff:ff
```

### 5.2 Failure mode → diagnosis matrix

| Symptom | Likely cause | Diagnostic command | Fix |
|---|---|---|---|
| `xl create` → `libxl: error: ... unable to add disk devices` | Backend `phy:` target missing, or already open by another domain | `xl dmesg`, `xenstore-read .../vbd/.../state` | Verify the LV/LUN path; ensure no other domain holds it |
| HVM guest boots to black VNC, no OS | Wrong `boot=` order, missing/unreadable ISO, `bios` mismatch (OVMF vs SeaBIOS) | `tail /var/log/xen/qemu-dm-<dom>.log` | Fix `boot=`, ISO path perms; match firmware to the OS |
| PV guest: `pygrub: ... no menu entries` | pygrub can't parse the guest's grub.cfg, or disk order wrong | `xl create -c` (watch pygrub) | Fix guest `/boot/grub/grub.cfg`; check first `disk=` is root |
| Guest has no network | Bridge missing, vif script failed, MAC collision | `ip link show master xenbr0`; `xenstore-read .../vif/0/state` | Create `xenbr0`; check `vif.default.bridge`; unique 00:16:3e MAC |
| Dom0 gets OOM-killed under load | Autoballooning shrank Dom0 | `xl info \| grep free_memory`; `grep autoballoon /etc/xen/xl.conf` | Pin `dom0_mem=X,max:X`; set `autoballoon="off"` |
| `xl migrate` fails at target | Version mismatch, no shared storage, SSH auth, CPU feature gap | Read both sides' stderr; `xl info` on each | Match Xen versions; shared storage; `cpuid` masking |
| `xl dmesg`: `grant table ... exhausted` | Too many high-throughput frontends | `xl dmesg \| grep grant` | Raise `gnttab_max_frames=` on the Xen cmdline |
| PCI passthrough: guest sees no device | IOMMU off, device not bound to `xen-pciback` | `xl info \| grep iommu`; `xl pci-assignable-list` | Enable VT-d; `xl pci-assignable-add 0000:04:00.0` |
| vif/vbd `state` stuck < 4 in XenStore | Backend driver not loaded in Dom0 | `xenstore-ls /local/domain/<id>/device` | `modprobe xen-netback xen-blkback` |

### 5.3 Passthrough verification (when `pci=` is in play)

```
$ sudo xl info | grep -o iommu
iommu
$ sudo xl pci-assignable-list           # devices bound to xen-pciback, ready to pass
0000:04:00.0
$ sudo xl pci-assignable-add 0000:04:00.0    # deprivilege a device
$ sudo xl pci-attach hvm-win01 0000:04:00.0  # hot-attach to a running guest
$ sudo xl pci-list hvm-win01
Vdev Device
04.0 0000:04:00.0
```

If `pci-assignable-add` fails, the device is still owned by a Dom0 driver — bind it to `xen-pciback` at boot (`xen-pciback.hide=(04:00.0)` on the Dom0 Linux cmdline) or unbind/rebind by hand via `/sys/bus/pci/drivers/`.

### 5.4 The disciplined debugging loop

1. **`xl dmesg`** — hypervisor-level truth (grant tables, triple faults, IOMMU faults, scheduler warnings).
2. **`/var/log/xen/xl-<domain>.log`** — what the toolstack tried and how it failed.
3. **`/var/log/xen/qemu-dm-<domain>.log`** — HVM device-model failures (disk, NIC, firmware).
4. **`xenstore-ls /local/domain/<id>`** — did the frontend/backend handshake reach `state=4`? This distinguishes "device never offered" from "device offered but guest driver missing."
5. **`xl create -c`** — re-create with the console attached and watch the guest boot in real time; catches pygrub, root-device and initrd failures instantly.
6. **`xentop`** — once running, is a neighbour saturating CPU/disk/net? `VBD_OO` and `NETTX/NETRX` localize it.

---

## 6. References

- **LPI — Exam 305-300 Objectives (v3.0), Topic 351.2 Xen** — https://www.lpi.org/our-certifications/exam-305-objectives/
- **Xen Project — Official Documentation Hub** — https://xenproject.org/help/documentation/
- **Xen Project Wiki — Xen Project Software Overview (architecture, PV/HVM/PVH)** — https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview
- **Xen Project Wiki — `xl` (toolstack)** — https://wiki.xenproject.org/wiki/XL
- **Xen Project Wiki — PVH (DomU) design** — https://wiki.xenproject.org/wiki/PVH_(Domain_0)  and  https://wiki.xenproject.org/wiki/Understanding_the_Virtualization_Spectrum
- **Xen Project Wiki — Xen Networking (bridging, routing, NAT)** — https://wiki.xenproject.org/wiki/Xen_Networking
- **Xen Project Wiki — Storage options** — https://wiki.xenproject.org/wiki/Storage_options
- **`xl(1)` man page** — https://xenbits.xen.org/docs/unstable/man/xl.1.html
- **`xl.cfg(5)` — domain configuration syntax** — https://xenbits.xen.org/docs/unstable/man/xl.cfg.5.html
- **`xl.conf(5)` — global toolstack configuration** — https://xenbits.xen.org/docs/unstable/man/xl.conf.5.html
- **`xentop(1)`** — https://xenbits.xen.org/docs/unstable/man/xentop.1.html
- **Xen Project — Xen Hypervisor Command Line Options** — https://xenbits.xen.org/docs/unstable/misc/xen-command-line.html
- **Xen Project Wiki — PCI Passthrough (VT-d / xen-pciback)** — https://wiki.xenproject.org/wiki/Xen_PCI_Passthrough
- **Xen Project Wiki — Xen Project Schedulers (Credit2, RTDS, null)** — https://wiki.xenproject.org/wiki/Xen_Project_Schedulers
- **Xen Project Wiki — Live Migration** — https://wiki.xenproject.org/wiki/Migration
- **Xen Project Wiki — XenStore** — https://wiki.xenproject.org/wiki/XenStore
- **Debian Wiki — Xen** — https://wiki.debian.org/Xen