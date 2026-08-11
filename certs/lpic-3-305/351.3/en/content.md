# 351.3 QEMU

> **LPIC-3 305-300 · Topic 351: Full Virtualization**
> Objective weight: **6.67** — the single heaviest objective of the *Full Virtualization* topic. QEMU is the reference type-2/type-1-hybrid emulator on Linux and the engine underneath libvirt, oVirt, OpenStack Nova, Proxmox, KubeVirt and cloud-hypervisor deployments. Master it at the CLI level and the higher-level tools become transparent.

---

## 1. Motivation and the production architectural problem

### 1.1 What QEMU actually is

QEMU (Quick EMUlator) is two things fused into one code base, and conflating them is the root of most operational confusion:

1. **A full-system emulator.** `qemu-system-x86_64` builds a *complete virtual machine* in user space: a virtual CPU, a chipset (i440FX or Q35), an interrupt controller, a PCI/PCIe bus, disks, NICs, a VGA adapter, a real-time clock, firmware (SeaBIOS or OVMF), and so on. Every guest instruction and every device access is mediated by a process on the host.

2. **A dynamic binary translator.** When no hardware acceleration is used, the guest's instruction stream is JIT-compiled by the **TCG (Tiny Code Generator)** into host instructions. This is what lets `qemu-system-aarch64` run an ARM guest on an x86 host — *cross-ISA* emulation. It is correct but slow (often 5–20× slowdown).

The production insight: **you almost never want pure emulation for same-architecture workloads.** You want QEMU as the *device model and control plane* while the CPU runs natively through **KVM**. QEMU + KVM is the canonical Linux hypervisor.

```
        ┌───────────────────────────────────────────────────────────┐
        │                        Guest OS                            │
        │        (unmodified kernel + userspace, ring 0/3)           │
        └───────────────────────────────────────────────────────────┘
              │ privileged instr,      │ MMIO / PIO / virtio
              │ VM exits (VMX/SVM)      │ (device access)
              ▼                         ▼
   ┌──────────────────────┐   ┌───────────────────────────────────┐
   │   KVM (kvm.ko +      │   │   QEMU process (user space)       │
   │   kvm-intel/amd.ko)  │◄──┤   - device model (virtio, PCI)    │
   │   in-kernel:         │   │   - main loop / vCPU threads      │
   │   - vCPU scheduling  │   │   - migration, snapshots          │
   │   - EPT/NPT (MMU)    │   │   - QEMU Monitor (HMP/QMP)        │
   │   - local APIC, PIT  │   │   - block & net backends          │
   └──────────┬───────────┘   └────────────────┬──────────────────┘
              │ ioctl(/dev/kvm)                 │ syscalls, threads
              ▼                                 ▼
   ┌───────────────────────────────────────────────────────────────┐
   │         Host Linux kernel  +  Intel VT-x (VMX) / AMD-V (SVM)   │
   └───────────────────────────────────────────────────────────────┘
```

### 1.2 The architectural problem this solves

Before hardware virtualization extensions, running an unmodified guest OS at native speed on a shared host was impossible without either:

- **Trap-and-emulate** every privileged instruction (unworkable on x86, whose ISA had ~17 "sensitive but unprivileged" instructions that don't trap), or
- **Binary translation** of the entire guest kernel (VMware's original approach — complex and slow), or
- **Paravirtualization** — modifying the guest (Xen's original approach — needs guest cooperation).

Intel **VT-x (VMX)** and AMD **AMD-V (SVM)** introduced a new CPU execution mode (root vs non-root / guest mode) plus hardware-assisted MMU (**EPT** on Intel, **NPT/RVI** on AMD) that lets the guest run privileged code directly, generating a *VM exit* back to the hypervisor only on events that genuinely need mediation (I/O to an emulated device, certain MSR writes, etc.). KVM is the thin Linux kernel module that drives this hardware; QEMU is the user-space process that owns the device model and lifecycle.

The **production problem statement** an SRE actually faces:

> "I need to run unmodified guest operating systems at near-native CPU/memory speed, with live-migratable state, snapshot-able disks, and network/storage I/O that doesn't collapse under load — reproducibly, from a scriptable interface, on commodity Linux hosts."

QEMU + KVM is the answer, and this objective is about controlling it directly rather than through an abstraction.

---

## 2. Technical comparisons and trade-offs

### 2.1 Accelerator back-ends (`-accel` / `-machine accel=`)

| Accelerator | Host requirement | Guest arch vs host | Speed | Primary use |
|---|---|---|---|---|
| **kvm** | Linux + VT-x/AMD-V, `/dev/kvm` | Same ISA only | Near-native | **Production on Linux** |
| **tcg** | None (pure software) | **Any** (cross-ISA) | 5–20× slower | Cross-arch, CI on unaccelerated hosts, embedded dev |
| **hvf** | macOS Hypervisor.framework | Same ISA | Near-native | QEMU on macOS hosts |
| **whpx** | Windows Hypervisor Platform | Same ISA | Near-native | QEMU on Windows hosts |
| **xen** | Xen dom0 | Same ISA | Near-native | QEMU as Xen device model (qemu-dm) |
| **nvmm** | NetBSD | Same ISA | Near-native | QEMU on NetBSD |

> On Linux, for the LPIC-3 exam and for production, the two you must know cold are **kvm** (hardware-accelerated, same-arch) and **tcg** (software, cross-arch). `-accel kvm:tcg` means "use KVM, fall back to TCG if unavailable" — useful in portable scripts and CI.

### 2.2 Machine types (chipset)

| Machine (`-machine`) | Chipset | Bus | Firmware default | PCIe / hotplug | When to use |
|---|---|---|---|---|---|
| **pc / pc-i440fx-\*** | Intel 440FX (1996) | PCI | SeaBIOS | PCI only | Legacy guests, maximum compatibility, older Windows |
| **q35 / pc-q35-\*** | Intel Q35 (2007) | PCIe | SeaBIOS (or OVMF) | Native PCIe, better hotplug, IOMMU/VT-d, PCIe passthrough | **Default for modern guests, GPU/NIC passthrough** |
| **microvm** | minimal, no PCI | MMIO virtio | none (direct kernel) | limited | Fast-boot sandboxes, Firecracker-style workloads |
| **virt** (aarch64) | ARM virt board | PCIe (GICv3) | OVMF/edk2 | yes | ARM64 guests |

Pin the *versioned* variant (`pc-q35-8.2`) in production, not the moving alias `q35` — the alias changes across QEMU releases and silently alters guest-visible hardware, which breaks live migration between hosts running different QEMU versions.

### 2.3 Disk interface + image format

| Dimension | Options | Trade-off |
|---|---|---|
| **Bus** | `virtio-blk`, `virtio-scsi`, `ide`, `ahci/sata`, `nvme` | virtio = paravirtualized, fastest, needs guest drivers. `virtio-scsi` supports many disks + discard/TRIM + SCSI passthrough. `ide`/`ahci` = universal but slow, use only for install media / ancient guests. |
| **Format** | `raw`, `qcow2` | `raw` = max performance, no features. `qcow2` = thin provisioning, internal snapshots, backing files, compression, encryption — small overhead. |
| **cache** | `none`, `writeback`, `writethrough`, `directsync`, `unsafe` | `none` (O_DIRECT, bypass host page cache) is the production default for correctness + predictable performance. `writeback` faster but relies on guest flushes. `unsafe` ignores flushes — benchmarks/throwaway only. |
| **aio** | `threads`, `native`, `io_uring` | `native` (Linux AIO) with `cache=none`; `io_uring` (QEMU 5.0+, kernel 5.1+) is the modern best for high IOPS. `threads` is the portable fallback. |

### 2.4 Networking back-ends

| Back-end (`-netdev`) | Host privilege | Performance | Guest reachable from LAN? | Typical use |
|---|---|---|---|---|
| **user** (SLIRP) | none (unprivileged) | Low (userspace TCP/IP) | No (NAT, needs hostfwd) | Laptops, quick tests, no root |
| **tap** | root / CAP_NET_ADMIN | High (esp. with vhost) | Yes (via host bridge) | **Production** |
| **bridge** (helper) | setuid helper | High | Yes | tap without full root, via `qemu-bridge-helper` |
| **macvtap** | root | Very high (bypasses bridge) | Yes | Dense hosts, low-latency; guests can't talk to host by default |
| **socket / l2tpv3** | none | medium | inter-QEMU | VM-to-VM meshes, testbeds |

**vhost-net** (`vhost=on`) moves the virtio-net data path into the kernel, eliminating per-packet exits into the QEMU user process — mandatory for line-rate networking. **Multiqueue** (`queues=N` + `mq=on`) scales a single NIC across vCPUs.

---

## 3. Verifying the platform (do this before anything else)

### 3.1 Are the virtualization extensions present and enabled?

```console
$ egrep -c '(vmx|svm)' /proc/cpuinfo
16
```

A non-zero count means the CPU *supports* VT-x (`vmx`, Intel) or AMD-V (`svm`, AMD). Zero means either an old CPU **or** the extensions are disabled in firmware/BIOS (most common cause on fresh servers).

```console
$ lscpu | grep -i virtual
Virtualization:                  VT-x
Virtualization type:             full
```

### 3.2 Are the KVM kernel modules loaded?

```console
$ lsmod | grep kvm
kvm_intel             389120  6
kvm                  1339392  1 kvm_intel
irqbypass              16384  1 kvm
```

The generic `kvm` module is architecture-neutral; the vendor module is **`kvm_intel`** (loads via `kvm-intel`) or **`kvm_amd`** (loads via `kvm-amd`). If missing:

```console
$ sudo modprobe kvm-intel
$ dmesg | tail -3
[  512.004311] kvm: Nested Virtualization enabled
[  512.004556] SVM: kvm: Nested Paging enabled
[  512.010992] kvm_intel: VMX enabled
```

Common failure — extensions disabled in BIOS:

```console
$ sudo modprobe kvm-intel
modprobe: ERROR: could not insert 'kvm_intel': Operation not supported
$ dmesg | tail -2
[  318.117733] kvm: disabled by bios
[  318.117740] kvm_intel: VMX not supported by CPU 0
```

→ Reboot, enable **Intel VT-x / "Intel Virtualization Technology"** or **AMD SVM / "SVM Mode"** in firmware setup.

### 3.3 Does `/dev/kvm` exist and is it accessible?

`/dev/kvm` is the character device through which QEMU issues `ioctl()` calls to create VMs, vCPUs and memory regions. Its presence is the definitive proof KVM is usable.

```console
$ ls -l /dev/kvm
crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm

$ getent group kvm
kvm:x:36:libvirt-qemu,sre

$ id -nG | tr ' ' '\n' | grep -x kvm
kvm
```

A user needs membership in the **`kvm`** group (or equivalent ACL) to run accelerated VMs without root:

```console
$ sudo usermod -aG kvm "$USER"      # re-login for the group to take effect
```

### 3.4 The one-shot sanity check: `kvm-ok`

```console
$ sudo kvm-ok
INFO: /dev/kvm exists
KVM acceleration can be used
```

Failure form:

```console
$ sudo kvm-ok
INFO: Your CPU does not support KVM extensions
INFO: For more detailed results, you should run this as root
HINT:   sudo /usr/sbin/kvm-ok
KVM acceleration can NOT be used
```

`kvm-ok` ships in the `cpu-checker` package (Debian/Ubuntu). On RHEL-family hosts, use `virt-host-validate`:

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking if device /dev/vhost-net exists                             : PASS
  QEMU: Checking if IOMMU is enabled by kernel                               : PASS
  QEMU: Checking for cgroup 'cpu' controller support                         : PASS
  QEMU: Checking for cgroup 'memory' controller support                      : PASS
```

### 3.5 Prove QEMU itself sees KVM

```console
$ qemu-system-x86_64 --version
QEMU emulator version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1)
Copyright (c) 2003-2023 Fabrice Bellard and the QEMU Project developers

$ qemu-system-x86_64 -accel help
Accelerators supported in QEMU binary:
tcg
kvm

$ qemu-system-x86_64 -M q35 -accel kvm -cpu host -display none -monitor stdio \
    -S -m 256 <<< 'info kvm'
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info kvm
kvm support: enabled
(qemu) quit
```

`kvm support: enabled` inside the monitor is the ultimate confirmation. If it reads `disabled`, QEMU fell back to TCG.

---

## 4. Starting virtual machines from the command line

### 4.1 The absolute minimum, then a production invocation

**Minimal, understand-it-first:**

```console
$ qemu-system-x86_64 -accel kvm -m 2048 -cdrom debian-12-netinst.iso
```

That boots the ISO with defaults (i440FX, one vCPU, an emulated e1000 NIC on user networking, Cirrus VGA). Fine to learn; wrong for production. Below is a **complete, production-shaped** command you can paste, annotated line by line.

```console
$ qemu-system-x86_64 \
    -name guest=web01,debug-threads=on \
    -machine type=q35,accel=kvm \
    -cpu host,migratable=on \
    -smp cpus=4,sockets=1,cores=4,threads=1 \
    -m size=4096,slots=4,maxmem=16384 \
    -object memory-backend-memfd,id=mem0,size=4096M,hugetlb=on,hugetlbsize=2M,share=on \
    -numa node,memdev=mem0 \
    -drive if=none,id=root,file=/var/lib/vm/web01.qcow2,format=qcow2,cache=none,aio=io_uring,discard=unmap \
    -device virtio-blk-pci,drive=root,bootindex=1,iommu_platform=on \
    -blockdev '{"driver":"file","filename":"/isos/seed.iso","node-name":"seed"}' \
    -device virtio-scsi-pci,id=scsi0 \
    -device scsi-cd,drive=seed \
    -netdev tap,id=net0,ifname=tap-web01,script=no,downscript=no,vhost=on,queues=4 \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,mq=on,vectors=10 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=/var/lib/vm/web01_VARS.fd \
    -rtc base=utc,driftfix=slew \
    -boot order=c,menu=on,strict=on \
    -serial mon:stdio \
    -qmp unix:/var/run/qemu/web01.qmp,server=on,wait=off \
    -device virtio-balloon-pci \
    -device virtio-rng-pci,rng=rng0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -display none \
    -daemonize
```

**Key parameter families you must know for the exam** (`-boot`, `-drive`, `-cdrom`, `-smp`, `-m`, `-net`/`-nic`/`-netdev`/`-device`):

| Parameter | Purpose | Exam-critical detail |
|---|---|---|
| `-m size,slots,maxmem` | Guest RAM + hotplug envelope | `-m 4096` = 4 GiB; `slots`/`maxmem` enable memory hotplug |
| `-smp cpus,sockets,cores,threads` | vCPU topology | `-smp 4` ≡ `cpus=4`; explicit topology matters for NUMA/licensing |
| `-cpu` | CPU model exposed to guest | `host` = pass through all host features (fastest, non-portable); named models (`Skylake-Server`, `EPYC`) for migration compatibility |
| `-drive` / `-blockdev` | Block back-end | `if=none`+`-device` is the modern split; `if=virtio` the legacy shortcut |
| `-cdrom file.iso` | Shortcut for a read-only IDE CD-ROM | Equivalent to `-drive file=file.iso,media=cdrom` |
| `-boot order=,menu=,once=` | Boot device order | `order=dc` = CD then disk; `once=d` = CD this boot only |
| `-netdev` + `-device` | Modern NIC (back-end + front-end split) | Preferred; decouples host plumbing from guest NIC model |
| `-nic` | Convenience: netdev+device in one | `-nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22` |
| `-net` | **Legacy** hub-based syntax | Deprecated; know it exists (`-net nic`/`-net tap`/`-net user`) but prefer `-netdev`/`-nic` |

### 4.2 `-drive` vs `-blockdev` vs `-device` — the modern split

The old `-drive if=virtio` couples *what the disk is* with *how the guest sees it*. Modern QEMU separates them:

- **Back-end** (`-blockdev` / `-drive if=none`): the image, format, cache, aio, backing file.
- **Front-end** (`-device virtio-blk-pci,drive=...`): the virtual controller the guest driver binds to.

This split is what makes **block hotplug, live snapshots, and disk mirroring** (`blockdev-mirror`, used for storage live migration) possible.

### 4.3 Networking: the three shapes you must be able to write by hand

**(a) User networking (SLIRP), no root, with port forwarding:**

```console
$ qemu-system-x86_64 -accel kvm -m 2048 \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
    -drive file=guest.qcow2,if=virtio,cache=none,aio=io_uring
# then from the host:  ssh -p 2222 user@127.0.0.1
```

**(b) TAP on a Linux bridge (production):** first build the host plumbing (Section 5), then:

```console
$ sudo qemu-system-x86_64 -accel kvm -m 4096 -cpu host -smp 4 \
    -drive if=none,id=d0,file=web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -device virtio-blk-pci,drive=d0 \
    -netdev tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:aa:bb:cc \
    -display none -serial mon:stdio
```

**(c) The unprivileged bridge helper** (avoids full root; uses the setuid `qemu-bridge-helper` governed by `/etc/qemu/bridge.conf`):

```console
$ cat /etc/qemu/bridge.conf
allow br0

$ qemu-system-x86_64 -accel kvm -m 2048 \
    -netdev bridge,id=n0,br=br0 \
    -device virtio-net-pci,netdev=n0 \
    -drive file=guest.qcow2,if=virtio
```

> **MAC address rule:** the `52:54:00` OUI prefix is QEMU/KVM's locally-administered range. Always pin the MAC in production so DHCP leases and live migration stay stable; a random MAC per boot breaks reservations and confuses the fabric.

### 4.4 Preparing disk images with `qemu-img`

```console
$ qemu-img create -f qcow2 web01.qcow2 40G
Formatting 'web01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=42949672960 lazy_refcounts=off refcount_bits=16

$ qemu-img info web01.qcow2
image: web01.qcow2
file format: qcow2
virtual size: 40 GiB (42949672960 bytes)
disk size: 196 KiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
```

Thin *golden image* + per-VM overlay (copy-on-write backing chain — how cloud images fan out fast):

```console
$ qemu-img create -f qcow2 -F qcow2 -b /golden/debian12.qcow2 web01.qcow2
Formatting 'web01.qcow2', fmt=qcow2 ... backing_file=/golden/debian12.qcow2 backing_fmt=qcow2 ...

$ qemu-img info --backing-chain web01.qcow2 | grep -E 'image|backing file:'
image: web01.qcow2
backing file: /golden/debian12.qcow2
image: /golden/debian12.qcow2
```

Convert / compress / re-format:

```console
$ qemu-img convert -p -O qcow2 -c disk.raw disk-compressed.qcow2
    (100.00/100%)

$ qemu-img check web01.qcow2
No errors were found on the image.
655360/655360 = 100.00% allocated, 0.00% fragmented, 0.00% compressed clusters
Image end offset: 43150802944
```

---

## 5. Host network infrastructure — bridges, TAP, and the modern `ip` replacements

The exam explicitly lists **`ip`**, **`brctl`/`bridge`**, and **`tunctl`/`ip tuntap`**. `brctl` (from `bridge-utils`) and `tunctl` (from `uml-utilities`) are the legacy tools; `ip` from `iproute2` is their modern, single-binary replacement. Know both — legacy scripts still use the old ones.

### 5.1 Create a bridge — old vs new

**Legacy (`brctl`):**

```console
$ sudo brctl addbr br0
$ sudo brctl addif br0 eno1
$ sudo brctl show
bridge name     bridge id               STP enabled     interfaces
br0             8000.3cecef1a2b3c       no              eno1
$ sudo ip link set br0 up
```

**Modern (`ip` / `bridge`):**

```console
$ sudo ip link add name br0 type bridge
$ sudo ip link set eno1 master br0
$ sudo ip link set br0 up
$ sudo ip link set eno1 up

$ bridge link show
3: eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding priority 32 cost 4

$ ip -brief link show type bridge
br0              UP             3c:ec:ef:1a:2b:3c <BROADCAST,MULTICAST,UP,LOWER_UP>
```

### 5.2 Create a persistent TAP device — old vs new

**Legacy (`tunctl`):**

```console
$ sudo tunctl -t tap0 -u sre
Set 'tap0' persistent and owned by uid 1000
```

**Modern (`ip tuntap`):**

```console
$ sudo ip tuntap add dev tap0 mode tap user sre
$ sudo ip link set tap0 master br0
$ sudo ip link set tap0 up

$ ip -details link show tap0
7: tap0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc fq_codel master br0 state DOWN mode DEFAULT group default qlen 1000
    link/ether f2:9a:1c:44:aa:01 brd ff:ff:ff:ff:ff:ff promiscuity 1 minmtu 68 maxmtu 65521
    tun type tap pi off vnet_hdr on persist on user sre
    bridge_slave state disabled priority 32 cost 100 ...
```

> `NO-CARRIER`/`state DOWN` on a fresh TAP is **normal** — a TAP goes "up" (carrier appears) only when a process (QEMU) opens `/dev/net/tun` and attaches to it. Diagnosing "my tap0 is down" as a fault is the classic false alarm.

### 5.3 A complete, idempotent host-networking systemd unit

`/etc/systemd/system/qemu-br0.service` — declarative bridge + persistent TAP pool for a hypervisor host:

```ini
[Unit]
Description=QEMU bridge br0 and TAP pool
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
# --- bring up bridge (idempotent) ---
ExecStart=/bin/sh -c 'ip link show br0   >/dev/null 2>&1 || ip link add name br0 type bridge'
ExecStart=/bin/sh -c 'ip link set br0 up'
ExecStart=/bin/sh -c 'ip link show eno1 | grep -q "master br0" || ip link set eno1 master br0'
# --- pre-create a pool of TAPs owned by the qemu user ---
ExecStart=/bin/sh -c 'for i in 0 1 2 3; do \
    ip tuntap show dev tap$i >/dev/null 2>&1 || ip tuntap add dev tap$i mode tap user libvirt-qemu; \
    ip link set tap$i master br0; \
    ip link set tap$i up; \
  done'
# --- teardown ---
ExecStop=/bin/sh -c 'for i in 0 1 2 3; do ip link del tap$i 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl enable --now qemu-br0.service
$ systemctl is-active qemu-br0.service
active
```

### 5.4 Wrap a manual QEMU guest as a managed service

`/etc/systemd/system/qemu-web01.service`:

```ini
[Unit]
Description=QEMU guest web01
After=qemu-br0.service network-online.target
Requires=qemu-br0.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
User=libvirt-qemu
Group=kvm
ExecStart=/usr/bin/qemu-system-x86_64 \
    -name web01 \
    -machine type=pc-q35-8.2,accel=kvm \
    -cpu host -smp 4 -m 4096 \
    -drive if=none,id=root,file=/var/lib/vm/web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -device virtio-blk-pci,drive=root,bootindex=1 \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56 \
    -qmp unix:/run/qemu/web01.qmp,server=on,wait=off \
    -serial file:/var/log/qemu/web01.console.log \
    -nographic \
    -no-shutdown
ExecStop=/usr/bin/qmp-shell -v /run/qemu/web01.qmp <<< 'system_powerdown'
TimeoutStopSec=60
RuntimeDirectory=qemu
LogsDirectory=qemu

[Install]
WantedBy=multi-user.target
```

### 5.5 Cloud-init seed for hands-off provisioning (the YAML the exam-adjacent world runs on)

QEMU boots a bare cloud image; **cloud-init** inside the guest reads a NoCloud seed ISO to configure itself. `user-data`:

```yaml
#cloud-config
hostname: web01
fqdn: web01.leloir.internal
manage_etc_hosts: true

users:
  - name: sre
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILq...replace-me... sre@leloir

ssh_pwauth: false

packages:
  - qemu-guest-agent
  - nginx

write_files:
  - path: /etc/nginx/conf.d/health.conf
    permissions: '0644'
    content: |
      server {
        listen 8080;
        location = /healthz { return 200 "ok\n"; }
      }

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, restart, nginx ]

power_state:
  mode: reboot
  condition: true
```

`meta-data`:

```yaml
instance-id: web01-0001
local-hostname: web01
```

Build the seed ISO and boot the cloud image against it:

```console
$ cloud-localds seed.iso user-data meta-data
$ qemu-img create -f qcow2 -F qcow2 -b /golden/debian-12-genericcloud-amd64.qcow2 web01.qcow2
$ qemu-img resize web01.qcow2 40G
Image resized.
$ qemu-system-x86_64 -accel kvm -cpu host -smp 4 -m 4096 \
    -drive if=virtio,file=web01.qcow2,format=qcow2,cache=none,aio=io_uring \
    -drive if=virtio,file=seed.iso,format=raw \
    -netdev tap,id=n0,ifname=tap0,script=no,downscript=no,vhost=on \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic
```

### 5.6 Ansible task that renders the same host plumbing (reproducible infra)

```yaml
- name: Configure QEMU/KVM host networking
  hosts: hypervisors
  become: true
  vars:
    bridge: br0
    uplink: eno1
    tap_count: 4
    qemu_user: libvirt-qemu
  tasks:
    - name: Ensure the bridge exists
      ansible.builtin.command:
        cmd: "ip link add name {{ bridge }} type bridge"
      register: br_add
      changed_when: br_add.rc == 0
      failed_when: br_add.rc != 0 and 'File exists' not in br_add.stderr

    - name: Bring the bridge up
      ansible.builtin.command: "ip link set {{ bridge }} up"
      changed_when: false

    - name: Enslave the uplink
      ansible.builtin.command: "ip link set {{ uplink }} master {{ bridge }}"
      changed_when: false

    - name: Create persistent TAP pool
      ansible.builtin.command:
        cmd: "ip tuntap add dev tap{{ item }} mode tap user {{ qemu_user }}"
      loop: "{{ range(0, tap_count) | list }}"
      register: tap_add
      changed_when: tap_add.rc == 0
      failed_when: tap_add.rc != 0 and 'File exists' not in tap_add.stderr

    - name: Enslave and raise each TAP
      ansible.builtin.shell: |
        ip link set tap{{ item }} master {{ bridge }}
        ip link set tap{{ item }} up
      loop: "{{ range(0, tap_count) | list }}"
      changed_when: false
```

### 5.7 The libvirt bridge on the same idea (for teams that use virsh)

Even when QEMU is driven by hand, the libvirt XML representation is worth reading — it is the canonical serialization of a QEMU domain. Minimal domain XML:

```xml
<domain type='kvm'>
  <name>web01</name>
  <memory unit='MiB'>4096</memory>
  <vcpu placement='static'>4</vcpu>
  <os>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'/>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='io_uring' discard='unmap'/>
      <source file='/var/lib/vm/web01.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:12:34:56'/>
      <source bridge='br0'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
    </interface>
    <console type='pty'/>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <memballoon model='virtio'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
```

```console
$ virsh define web01.xml && virsh start web01
Domain 'web01' defined from web01.xml
Domain 'web01' started
```

---

## 6. The QEMU Monitor — HMP and QMP

The **QEMU Monitor** is the runtime control plane of a live VM. There are two dialects:

- **HMP (Human Monitor Protocol)** — the interactive `(qemu)` prompt: `info`, `system_powerdown`, `device_add`, `savevm`.
- **QMP (QEMU Machine Protocol)** — a **JSON**, machine-facing protocol on a socket. This is what libvirt/OpenStack speak. Everything programmatic goes through QMP.

### 6.1 Reaching the monitor

| Flag | Effect |
|---|---|
| `-monitor stdio` | HMP on the terminal |
| `-monitor telnet:127.0.0.1:4444,server,nowait` | HMP over TCP (localhost only!) |
| `-monitor unix:/run/qemu/mon.sock,server,nowait` | HMP over a Unix socket |
| `-qmp unix:/run/qemu/qmp.sock,server=on,wait=off` | QMP over a Unix socket (production) |
| `-serial mon:stdio` | Multiplex serial console **and** monitor on stdio (`Ctrl-a c` toggles) |

### 6.2 HMP session — the `info` commands you will lean on

```console
$ qemu-system-x86_64 -accel kvm -m 2048 -smp 2 \
    -drive file=web01.qcow2,if=virtio -monitor stdio -display none
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info status
VM status: running

(qemu) info kvm
kvm support: enabled

(qemu) info cpus
* CPU #0: thread_id=20344
  CPU #1: thread_id=20345

(qemu) info block
root (#block182): web01.qcow2 (qcow2)
    Attached to:      /machine/peripheral-anon/device[0]/virtio-backend
    Cache mode:       writeback, direct

(qemu) info network
net0:
 \ #net058: index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
  \ hub0port0: user.0: index=0,type=user,net=10.0.2.0,restrict=off

(qemu) info registers
CPU#0
RAX=0000000000000000 RBX=ffff9b8c00c1a000 RCX=0000000000000000 ...
RIP=ffffffff8a4f27e6 RFL=00000246 [---Z-P-] ...

(qemu) info mem
0000000000000000-0000000000200000 0000000000200000 -rw
...

(qemu) info migrate
globals: store-global-state=on, only-migratable=off, send-configuration=on ...
```

Full HMP command reference:

```console
(qemu) help info
info version  -- show the version of QEMU
info network  -- show the network state
info chardev  -- show the character devices
info block    -- show info of one block device or all block devices
info blockstats -- show block device statistics
info registers  -- show the cpu registers
info cpus     -- show info of all guest CPUs
info kvm      -- show KVM information
info numa     -- show NUMA information
info usb      -- show guest USB devices
info pci      -- show PCI info
info mtree    -- show memory tree
info qtree    -- show device tree
info snapshots -- show the currently saved VM snapshots
info migrate  -- show migration status
info balloon  -- show balloon information
...
```

### 6.3 Live operations from HMP

**Graceful shutdown (sends ACPI power button) vs hard reset:**

```console
(qemu) system_powerdown        # ACPI → guest OS shuts down cleanly
(qemu) system_reset            # hard reset (like the reset button)
(qemu) stop                    # pause vCPUs (freeze)
(qemu) cont                    # resume
```

**PCI device hotplug** (add a second NIC to a running guest):

```console
(qemu) netdev_add tap,id=net1,ifname=tap1,script=no,downscript=no
(qemu) device_add virtio-net-pci,netdev=net1,id=nic1,mac=52:54:00:99:88:77
(qemu) info pci
  Bus  0, device   4, function 0:
    Ethernet controller: PCI device 1af4:1000
      PCI subsystem 1af4:0001
      virtio-net-pci
(qemu) device_del nic1         # requests guest-cooperative unplug
```

**Internal snapshots (VM state + disk, qcow2 only):**

```console
(qemu) savevm checkpoint-preupgrade
(qemu) info snapshots
List of snapshots present on all disks:
 ID        TAG                  VM SIZE                DATE     VM CLOCK      ICOUNT
 1         checkpoint-preupgrade  198 MiB 2026-08-11 09:40:12  00:03:11.120
(qemu) loadvm checkpoint-preupgrade
(qemu) delvm checkpoint-preupgrade
```

**Screendump / console capture and CPU model introspection are also here** — but the two you must not confuse are `system_powerdown` (polite, guest may refuse) and `quit`/`q` (kills the QEMU process immediately, guest state lost).

### 6.4 QMP — the programmatic path

QMP greets you with a capabilities banner; you must send `qmp_capabilities` before any command.

```console
$ socat - UNIX-CONNECT:/run/qemu/web01.qmp
{"QMP": {"version": {"qemu": {"micro": 2, "minor": 2, "major": 8}, "package": "Debian 1:8.2.2+ds-0ubuntu1"}, "capabilities": ["oob"]}}
{"execute": "qmp_capabilities"}
{"return": {}}
{"execute": "query-status"}
{"return": {"status": "running", "singlestep": false, "running": true}}
{"execute": "query-kvm"}
{"return": {"enabled": true, "present": true}}
{"execute": "query-block", "arguments": {}}
{"return": [{"device": "", "qdev": "/machine/peripheral-anon/device[0]/virtio-backend", "inserted": {"file": "web01.qcow2", "cache": {"direct": true, "writeback": true, "no-flush": false}, "node-name": "root", "drv": "qcow2", ...}}]}
{"execute": "system_powerdown"}
{"return": {}}
{"timestamp": {"seconds": 1755938495, "microseconds": 111233}, "event": "POWERDOWN"}
{"timestamp": {"seconds": 1755938499, "microseconds": 882910}, "event": "SHUTDOWN", "data": {"guest": true, "reason": "guest-shutdown"}}
```

The friendlier `qmp-shell` wrapper (ships with QEMU) translates key=value to JSON:

```console
$ qmp-shell /run/qemu/web01.qmp
Welcome to the QMP low-level shell!
Connected to QEMU 8.2.2

(QEMU) query-name
{"return": {"name": "web01"}}
(QEMU) device_add driver=virtio-net-pci netdev=net1 id=nic1 mac=52:54:00:99:88:77
{"return": {}}
(QEMU) query-migrate
{"return": {"status": "none"}}
```

### 6.5 Live migration through QMP (the payoff of a stable device model)

On the **destination** host, start QEMU with the identical hardware definition plus `-incoming`:

```console
dst$ qemu-system-x86_64 -machine pc-q35-8.2,accel=kvm -cpu host -smp 4 -m 4096 \
     -drive if=none,id=root,file=/shared/web01.qcow2,format=qcow2,cache=none \
     -device virtio-blk-pci,drive=root \
     -qmp unix:/run/qemu/web01.qmp,server=on,wait=off \
     -incoming tcp:0:4444
```

On the **source**, drive the migration over QMP:

```console
src$ qmp-shell /run/qemu/web01.qmp
(QEMU) migrate_set_parameter max-bandwidth=8589934592
{"return": {}}
(QEMU) migrate uri=tcp:dst.leloir.internal:4444
{"return": {}}
(QEMU) query-migrate
{"return": {"status": "active", "ram": {"transferred": 1073741824, "remaining": 2147483648, "total": 4294967296, "dirty-pages-rate": 512, ...}, ...}}
(QEMU) query-migrate
{"return": {"status": "completed", "ram": {"transferred": 4311744512, "total": 4294967296, ...}, "total-time": 6120, "downtime": 84}}
```

`downtime: 84` ms — the guest paused for 84 ms during the final dirty-page sync. This only works because both sides declared **byte-for-byte identical virtual hardware** — the reason you pin versioned machine types and named/`host` CPU models with `migratable=on`.

---

## 7. Diagnosis and troubleshooting playbook

### 7.1 "The VM is slow" — is KVM actually engaged?

The number-one performance regression: QEMU silently ran on TCG because `/dev/kvm` was inaccessible or `-accel kvm` was omitted.

```console
$ ps -o pid,pcpu,comm,args -C qemu-system-x86_64 | grep -o 'accel=[^ ,]*'
accel=tcg                       # ← smoking gun: emulation, not acceleration

# Confirm from inside the running guest via the monitor:
(qemu) info kvm
kvm support: disabled           # ← definitive

# Force KVM and fail loudly instead of silently degrading:
$ qemu-system-x86_64 -accel accel=kvm,kernel-irqchip=on ...
# or the hard-require form:
$ qemu-system-x86_64 -machine q35,accel=kvm -cpu host ...
qemu-system-x86_64: -machine q35,accel=kvm: could not open /dev/kvm: Permission denied
```

`Permission denied` on `/dev/kvm` → user not in the `kvm` group (Section 3.3). `No such file or directory` → module not loaded (Section 3.2).

### 7.2 Guest hangs at boot / `-accel kvm` refused mid-run

```console
$ dmesg | grep -iE 'kvm|vmx|svm' | tail
[  918.442310] kvm: disabled by bios
```

Also check that another hypervisor isn't holding the extensions:

```console
$ lsmod | grep -E 'kvm|vbox|vmmon'
vboxdrv               663552  3    # ← VirtualBox owns VT-x; unload it or don't run both
$ sudo modprobe -r vboxdrv
```

### 7.3 Networking: guest has a link but no traffic

Verify the layers bottom-up. TAP attached to bridge?

```console
$ bridge link
7: tap0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding
$ ip -brief addr show br0
br0              UP             192.168.178.10/24

# Is the guest's virtio NIC even up? (from monitor)
(qemu) info network
net0: index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
 \ tap0: index=0,type=tap,ifname=tap0,script=no,downscript=no,vhost=on
```

Common causes, in order of frequency:

| Symptom | Likely cause | Check / fix |
|---|---|---|
| No IP in guest | TAP not enslaved to bridge | `bridge link` shows no `master br0` → `ip link set tap0 master br0` |
| No LAN reachability | Host IP still on the physical NIC, not the bridge | Move the L3 config onto `br0`, not `eno1` |
| Traffic dropped | `br_netfilter` + iptables FORWARD policy | `sysctl net.bridge.bridge-nf-call-iptables=0` or open FORWARD |
| Terrible throughput | `vhost=off` (data path in userspace) | add `vhost=on`; verify `/dev/vhost-net` exists |
| Guest can't reach host (macvtap) | macvtap isolates guest↔host by design | use a bridge, or a second macvlan on the host |

```console
$ ls -l /dev/vhost-net
crw------- 1 root root 10, 238 Aug 11 09:14 /dev/vhost-net
$ cat /sys/class/net/tap0/tun_flags
0x1002                          # IFF_TAP | IFF_VNET_HDR set → vhost-capable
```

### 7.4 Disk / image corruption and cache-related data loss

```console
$ qemu-img check web01.qcow2
Leaked cluster 12934 refcount=1 reference=0
...
8 leaked clusters were found on the image.
This means waste of disk space, but no harm to data.

$ qemu-img check -r all web01.qcow2       # attempt repair
Repairing cluster 12934 refcount=1 reference=0
The following inconsistencies were found and repaired:
    8 leaked clusters
Double checking the fixed image now...
No errors were found on the image.
```

> **Correctness rule:** `cache=unsafe` ignores the guest's flush requests — a host crash **will** corrupt the image. Use it only for throwaway/CI. Production is `cache=none` (O_DIRECT, honours flushes, bypasses double-caching). If a guest reports fsync latency spikes, check `aio=` — switch `threads`→`native`/`io_uring`.

### 7.5 Nested virtualization (running QEMU/KVM inside a guest)

```console
$ cat /sys/module/kvm_intel/parameters/nested
Y                               # (N or 0 = disabled)

# Enable persistently:
$ echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm.conf
$ sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
# AMD equivalent: options kvm_amd nested=1
```

For the L1 guest to expose VMX/SVM to L2, its CPU must pass the flag through: `-cpu host` or `-cpu <model>,vmx=on` (Intel) / `svm=on` (AMD).

### 7.6 Introspecting a running QEMU process from the host

```console
$ pgrep -a qemu-system-x86_64
20344 /usr/bin/qemu-system-x86_64 -name web01 -machine pc-q35-8.2,accel=kvm ...

# vCPU threads and their host CPU affinity:
$ ps -T -p 20344 -o spid,comm,psr | head
   SPID COMMAND         PSR
  20344 qemu-system-x86  2
  20348 CPU 0/KVM         4
  20349 CPU 1/KVM         6
  20350 CPU 2/KVM         8
  20351 CPU 3/KVM        10

# KVM exit statistics — the single best signal for "why is my guest burning CPU":
$ sudo perf kvm stat live -p 20344
Analyze events for pgid(20344), all VCPUs:

     VM-EXIT    Samples  Samples%     Time%    Min Time    Max Time     Avg time
    HLT           41233    58.11%    92.44%      0.55us  40122.10us   1902.44us
    MSR_WRITE      9821    13.84%     0.42%      0.34us     12.09us      1.31us
    EXTERNAL_INT   7104    10.01%     0.60%      0.41us     23.88us      2.60us
    IO_INSTRUCTION 4512     6.36%     4.10%      1.02us    301.44us     27.80us
    EPT_MISCONFIG  1120     1.58%     0.90%      2.10us     88.30us     24.60us
```

A high rate of `IO_INSTRUCTION` or `EPT_VIOLATION` exits usually means an *emulated* device on a hot path (e.g. `e1000` instead of `virtio-net`, or `ide` instead of `virtio-blk`) — switch the guest to virtio.

### 7.7 Structured host-side validation, one command

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking if device /dev/vhost-net exists                             : PASS
  QEMU: Checking if IOMMU is enabled by kernel                               : WARN (Add intel_iommu=on to kernel cmdline for PCI passthrough)
  QEMU: Checking for secure guest support                                    : WARN (Unknown if this platform has Secure Guest support)
```

`intel_iommu=on` / `amd_iommu=on` on the kernel command line is the prerequisite for VFIO device passthrough (GPUs, NICs) into a QEMU guest — a `WARN` here, not a `FAIL`, unless you need passthrough.

---

## 8. Consolidated command / parameter reference

**Modules & device:** `modprobe kvm-intel|kvm-amd`, `lsmod | grep kvm`, `/dev/kvm`, `/dev/vhost-net`, `/dev/net/tun`
**Sanity:** `kvm-ok`, `virt-host-validate qemu`, `egrep -c '(vmx|svm)' /proc/cpuinfo`
**Launch:** `qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp -m -drive -device -netdev -boot -cdrom -serial -qmp`
**Images:** `qemu-img create|info|convert|check|resize|snapshot|rebase`
**Bridges:** `brctl addbr|addif|show` ↔ `ip link add … type bridge`, `bridge link show`
**TAP:** `tunctl -t … -u …` ↔ `ip tuntap add dev … mode tap user …`
**Monitor:** HMP `info kvm|cpus|block|network|pci|qtree|migrate`, `system_powerdown`, `device_add`, `savevm/loadvm`, `migrate`; QMP `qmp_capabilities`, `query-status`, `query-kvm`, `migrate`

---

## 9. References

- **LPI — Exam 305 (305-300) Objectives, Topic 351.3 QEMU** — https://www.lpi.org/our-certifications/exam-305-objectives/
- **QEMU — System Emulation User's Guide** — https://www.qemu.org/docs/master/system/index.html
- **QEMU — Invocation & command-line options (`qemu-system` reference)** — https://www.qemu.org/docs/master/system/invocation.html
- **QEMU — KVM acceleration** — https://www.qemu.org/docs/master/system/i386/kvm.html
- **QEMU — QEMU Monitor (HMP)** — https://www.qemu.org/docs/master/system/monitor.html
- **QEMU — QMP (QEMU Machine Protocol) reference** — https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html
- **QEMU — Network emulation (`-netdev`, tap, bridge, user)** — https://wiki.qemu.org/Documentation/Networking
- **QEMU — `qemu-img` manual** — https://www.qemu.org/docs/master/tools/qemu-img.html
- **QEMU — Live migration** — https://www.qemu.org/docs/master/devel/migration/index.html
- **Linux kernel — KVM API documentation (`/dev/kvm`, ioctls)** — https://docs.kernel.org/virt/kvm/api.html
- **Linux kernel — Nested virtualization (`kvm-intel`/`kvm-amd` `nested`)** — https://docs.kernel.org/virt/kvm/x86/nested-vmx.html
- **libvirt — Domain XML format** — https://libvirt.org/formatdomain.html
- **libvirt — `virt-host-validate`** — https://www.libvirt.org/manpages/virt-host-validate.html
- **iproute2 — `ip-link(8)`, `ip-tuntap`, `bridge(8)`** — https://man7.org/linux/man-pages/man8/ip-link.8.html · https://man7.org/linux/man-pages/man8/bridge.8.html
- **cloud-init — NoCloud datasource & modules** — https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html