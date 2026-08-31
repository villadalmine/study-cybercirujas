# 102.6 — Linux as a Virtualization Guest

**Certification:** LPIC-1 (Exams 101-500 / 102-500), version 5.0
**Objective weight:** 1.56 (normalized) — 1 point in the raw LPI weighting
**Scope (original paraphrase of the LPI objective):** understand what a virtual machine and a container are; know the building blocks of an IaaS cloud instance (compute, block storage, networking); know which properties of a Linux installation must be made unique before it is cloned or turned into a template; know how system images deploy VMs, cloud instances and containers; know the guest-side extensions that integrate Linux with a hypervisor; be aware of `cloud-init`.

> **Exam-day reality check.** LPI weights this objective at 1 point out of 60 — statistically ~1 question per exam form. The material below is deliberately deeper than that, because *every* production Linux system an SRE touches in 2026 is a guest of something, and the failure modes in this objective (duplicate `machine-id`, duplicate SSH host keys, missing `virtio` in the initramfs, `cloud-init` that silently never ran) are the ones that page you at 03:00. Learn the exam surface first (§13), then keep the rest as a runbook.

---

## 1. The production problem: the golden image that was not unique

A platform team builds one hardened Debian 12 image with Packer, publishes it as `base-deb12-2026.08`, and stamps out 40 VMs from it on a KVM/libvirt cluster. Within an hour:

- Three VMs fight over `10.20.4.117`. `arping -D` reports duplicate address detection. The DHCP server insists it handed out one lease.
- `journalctl` on the central log host interleaves entries from what looks like a single machine that teleports between racks.
- The SSH bastion's `known_hosts` matches every new host on the first try — nobody notices, because "it just works".
- The vulnerability scanner reports 1 asset instead of 40.

None of these are network bugs. They are all the same bug: **the image carried identity that should have been generated per instance.**

The DHCP collision is the sharpest one. `systemd-networkd` defaults to `ClientIdentifier=duid`, and its default DUID is a DUID-EN derived from `/etc/machine-id`. Clone `/etc/machine-id`, and every clone presents the *same* DHCPv4 client identifier. A conformant DHCP server keys the lease on the client identifier, not the MAC — so it happily returns the same IP to what it believes is one machine changing NICs. Three VMs, one lease, one IP, three angry Slack threads.

The architectural rule that follows:

> **An image is a template of *state*, never of *identity*.** Identity is minted at first boot, on the instance, by the instance. Anything in the image that uniquely names a host is a defect, and it is a defect that free tooling can detect before the image is published.

Everything else in this objective — `machine-id`, D-Bus IDs, SSH host keys, `cloud-init`, guest drivers — is machinery in service of that one rule, plus the performance rule that follows it: a guest that does not load paravirtualized drivers is paying an emulation tax it does not have to pay.

---

## 2. Taxonomy: what is actually running your workload

### 2.1 The isolation spectrum

Virtualization is not one thing. From strongest isolation to weakest:

| Technology | Kernel seen by workload | Isolation boundary | Boot time (typical) | Density (per 64 GiB host) | Overhead | Canonical use |
|---|---|---|---|---|---|---|
| Bare metal | Its own | Hardware | 60–300 s | 1 | 0% | Latency-critical, licensing, PCI passthrough |
| **Type-1 hypervisor** (KVM, Xen, ESXi, Hyper-V) | Guest kernel | CPU virt extensions (VT-x/AMD-V), IOMMU | 5–30 s | 20–60 | 2–10% | General IaaS, multi-tenant |
| Type-2 hypervisor (VirtualBox, VMware Workstation, QEMU/TCG) | Guest kernel | Host kernel + userspace VMM | 10–40 s | 5–15 | 5–40% | Development, labs |
| **microVM** (Firecracker, Cloud Hypervisor, QEMU microvm) | Guest kernel | Same as type-1, minimal device model | 100–250 ms | 100–1000 | 3–8% | FaaS, per-tenant sandboxes |
| Sandboxed container (Kata, gVisor) | Guest kernel (Kata) / userspace kernel (gVisor) | VM boundary / seccomp+ptrace syscall interception | 200 ms–1 s | 100–400 | 5–20% | Untrusted multi-tenant Kubernetes |
| **System container** (LXC/LXD, `systemd-nspawn`) | **Host kernel** | Namespaces + cgroups + LSM | 0.3–2 s | 200–800 | <2% | "A VM-shaped Linux without a VM" |
| **Application container** (Docker/Podman, OCI) | **Host kernel** | Namespaces + cgroups + seccomp + caps | 20–200 ms | 500–5000 | <2% | One process tree per image |

The load-bearing distinction for the exam and for incident response:

- **A virtual machine runs its own kernel.** It boots firmware, a bootloader, and a kernel; it has its own `/proc`, its own scheduler, its own page tables (shadowed or EPT/NPT-assisted). A kernel panic inside it does not touch the host.
- **A container shares the host kernel.** It is a *view* of the host — a set of namespaces (`mnt`, `pid`, `net`, `ipc`, `uts`, `user`, `cgroup`, `time`) plus cgroup limits plus a filtered syscall surface. There is no guest kernel, no bootloader, no BIOS. A container kernel panic *is* a host kernel panic.

### 2.2 System container vs application container

Both use the same kernel primitives; they differ in intent and therefore in contents.

| | System container | Application container |
|---|---|---|
| PID 1 | `systemd` / `init` | The application (`nginx`, `java`, …) |
| Filesystem | Full distro rootfs | Minimal layer set, often distroless |
| Lifetime | Long-lived, pets, upgraded in place | Ephemeral, cattle, replaced by new image |
| Mutability | Mutable; you `apt upgrade` inside | Immutable; rebuild the image |
| Typical tools | LXD, `systemd-nspawn`, `machinectl` | Docker, Podman, containerd, CRI-O |
| Networking | Usually a bridged veth with its own IP | Port mapping / CNI / service mesh |
| Cron, syslog, sshd inside? | Yes, normal | Anti-pattern |
| Image format | Distro rootfs tarball, LXD image | OCI image (layered, content-addressed) |
| Analogue | A lightweight VM | A statically linked process with a filesystem |

**Trade-off:** the system container gives you familiar operations (ssh in, run `systemctl`, keep state) at the cost of configuration drift and a fat rootfs. The application container gives you reproducibility and fast rollback at the cost of having to externalize *all* state and re-learn logging, secrets and lifecycle.

### 2.3 Paravirtualization vs full emulation

A hypervisor can present a device in three ways:

| Model | How it works | Guest driver | Exits per I/O | Throughput (4 KiB random read, NVMe backend) |
|---|---|---|---|---|
| **Full emulation** | VMM emulates real silicon (Intel e1000, IDE, AHCI) register by register | Stock hardware driver | Very high (one VM exit per MMIO register access) | ~40–60 kIOPS |
| **Paravirtualization** | Guest knows it is virtual; talks a ring-buffer protocol (`virtio`) | `virtio_blk`, `virtio_net`, … | Low (batched, notify-on-full) | ~250–400 kIOPS |
| **Passthrough / SR-IOV** | Physical function or VF assigned to the guest via IOMMU | Native driver for the real card | ~0 (DMA direct to guest memory) | Line rate; ~near bare metal |

Paravirtualization is the whole reason "guest extensions" exist as an exam topic. The performance delta is not marginal:

| Metric | Emulated `e1000` / IDE | `virtio-net` / `virtio-blk` | `vhost-net` | SR-IOV VF |
|---|---|---|---|---|
| 10 GbE TCP throughput | 2.1–3.5 Gb/s | 7–9 Gb/s | 9.4 Gb/s | 9.9 Gb/s |
| Small-packet PPS | ~180 k | ~700 k | ~1.4 M | ~14 M (DPDK) |
| Host CPU per Gb/s | High | Medium | Low | Near zero |
| Live migration | Yes | Yes | Yes | **No** (without VF failover bonding) |
| Guest driver required | No (stock) | **Yes** | Yes | Yes (vendor) |

**The trade-off you must be able to state:** paravirtualized and passthrough devices trade *portability* for *speed*. `virtio` needs a driver in the guest (fine on Linux, needs an injected driver on Windows). SR-IOV additionally forfeits live migration, memory overcommit and snapshotting. Emulated devices work on any OS ever written and cost you two thirds of your I/O.

---

## 3. Boundary mechanics: how the guest knows it is a guest

An SRE must be able to answer "what am I running on?" in one command, on a box with no cloud CLI installed.

### 3.1 The CPUID hypervisor leaf

The x86 architecture reserves CPUID leaves `0x40000000`–`0x400000FF` for hypervisors. Bit 31 of `ECX` from leaf `0x1` is the **hypervisor present bit**; the kernel exposes it as the `hypervisor` CPU flag.

```
$ grep -o ' hypervisor ' /proc/cpuinfo | head -1
 hypervisor 

$ lscpu | grep -Ei 'hypervisor|virtualization|model name'
Model name:                           Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz
Virtualization:                       VT-x
Hypervisor vendor:                    KVM
Virtualization type:                  full
```

Leaf `0x40000000` returns a 12-byte vendor signature in `EBX:ECX:EDX`:

```
# cpuid -1 -l 0x40000000
CPU:
   hypervisor_id (0x40000000):
      hypervisor_id = "KVMKVMKVM   "
```

| Signature | Hypervisor |
|---|---|
| `KVMKVMKVM` | KVM (QEMU/libvirt, OpenStack, Proxmox, oVirt) |
| `VMwareVMware` | VMware ESXi / Workstation / Fusion |
| `Microsoft Hv` | Hyper-V (and Azure, and WSL2) |
| `XenVMMXenVMM` | Xen HVM/PVH |
| `VBoxVBoxVBox` | VirtualBox (also reports `KVMKVMKVM` under some configs) |
| `bhyve bhyve` | FreeBSD bhyve |
| `TCGTCGTCGTCG` | QEMU with no hardware acceleration (pure emulation — you are about to have a bad time) |
| `ACRNACRNACRN` | ACRN (automotive/embedded) |
| `prl hyperv` | Parallels |

### 3.2 The one command to memorize

```
$ systemd-detect-virt
kvm

$ systemd-detect-virt --vm
kvm

$ systemd-detect-virt --container
none

$ echo $?
1
```

Exit status is **0 when virtualization is detected, 1 when running on bare metal** — which makes it directly usable in scripts and in `ConditionVirtualization=` in unit files. Representative return values:

| Class | Values |
|---|---|
| VM | `qemu`, `kvm`, `amazon`, `zvm`, `vmware`, `microsoft`, `oracle`, `powervm`, `xen`, `bochs`, `uml`, `parallels`, `bhyve`, `qnx`, `acrn`, `apple`, `sre` |
| Container | `openvz`, `lxc`, `lxc-libvirt`, `systemd-nspawn`, `docker`, `podman`, `rkt`, `wsl`, `proot`, `pouch` |
| Neither | `none` |

### 3.3 DMI/SMBIOS — the firmware's self-description

```
$ cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name
QEMU
Standard PC (Q35 + ICH9, 2009)

# dmidecode -s system-manufacturer
Amazon EC2
# dmidecode -s system-product-name
m6i.large
# cat /sys/devices/virtual/dmi/id/board_asset_tag
i-0abcd1234ef567890
```

The `/sys/class/dmi/id/*` files are world-readable for the non-sensitive fields, so you get platform identification **without root**. Two field-useful facts: on EC2 Nitro the **instance ID is in `board_asset_tag`**, and on Azure the chassis asset tag is the constant `7783-7084-3265-9085-8269-3286-77` — both let you identify a cloud instance when the metadata service is firewalled off.

| Platform | `sys_vendor` | `product_name` |
|---|---|---|
| KVM/QEMU | `QEMU` | `Standard PC (Q35 + ICH9, 2009)` |
| VMware | `VMware, Inc.` | `VMware Virtual Platform` / `VMware20,1` |
| Hyper-V / Azure | `Microsoft Corporation` | `Virtual Machine` |
| VirtualBox | `innotek GmbH` | `VirtualBox` |
| Xen HVM | `Xen` | `HVM domU` |
| AWS Nitro | `Amazon EC2` | instance type, e.g. `m6i.large` |
| Google Compute Engine | `Google` | `Google Compute Engine` |

### 3.4 `virt-what` and Xen-specific paths

```
# virt-what
kvm

# for Xen PV:
$ cat /sys/hypervisor/type /sys/hypervisor/version/major
xen
4
$ ls /proc/xen
capabilities  privcmd  xenbus  xsd_kva  xsd_port
```

`virt-what` (from `libguestfs`) is a shell script that stacks CPUID, DMI, `/proc` and module heuristics; it can print **more than one line** (e.g. `xen` and `xen-hvm`, or `kvm` and `openstack`). `systemd-detect-virt` prints exactly one and prefers the innermost technology — relevant when you have containers inside VMs.

### 3.5 One-shot platform fingerprint

```bash
#!/usr/bin/env bash
# /usr/local/sbin/whereami — identify the virtualization substrate. No root required.
set -euo pipefail

printf '%-22s %s\n' 'hostname:'    "$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
printf '%-22s %s\n' 'virt (systemd):' "$(systemd-detect-virt || true)"
printf '%-22s %s\n' 'container:'   "$(systemd-detect-virt --container || true)"
printf '%-22s %s\n' 'dmi vendor:'  "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'dmi product:' "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'asset tag:'   "$(cat /sys/class/dmi/id/board_asset_tag 2>/dev/null || echo n/a)"
printf '%-22s %s\n' 'cpu hypervisor:' "$(grep -qw hypervisor /proc/cpuinfo && echo present || echo absent)"
printf '%-22s %s\n' 'clocksource:' "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
printf '%-22s %s\n' 'machine-id:'  "$(cat /etc/machine-id)"
printf '%-22s %s\n' 'virtio mods:' "$(lsmod | awk '/^virtio/{printf "%s ", $1}')"
printf '%-22s %s\n' 'guest agent:' "$(systemctl is-active qemu-guest-agent vmtoolsd hv_kvp_daemon 2>/dev/null | tr '\n' ' ')"
```

```
$ whereami
hostname:              web-01
virt (systemd):        kvm
container:             none
dmi vendor:            QEMU
dmi product:           Standard PC (Q35 + ICH9, 2009)
asset tag:             n/a
cpu hypervisor:        present
clocksource:           kvm-clock
machine-id:            5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
virtio mods:           virtio_net virtio_blk virtio_console virtio_balloon virtio_rng virtio_pci virtio_ring virtio 
guest agent:           active inactive inactive
```

---

## 4. Guest drivers and integration extensions

### 4.1 The `virtio` family (KVM, and increasingly everything else)

`virtio` is a **standardized paravirtual device transport** (OASIS spec). The guest driver and the host device share a set of *virtqueues* — ring buffers in guest memory — so a batch of I/O costs one notification instead of dozens of trapped MMIO writes.

| Module | Device | What it gives you | Failure if missing |
|---|---|---|---|
| `virtio_pci` | Transport | Binds virtio devices on the PCI bus | Nothing else works |
| `virtio_blk` | `/dev/vda` | Fast block I/O | Root device not found → kernel panic |
| `virtio_scsi` | `/dev/sda` via `virtio-scsi` | SCSI semantics, `DISCARD`/UNMAP, >28 disks, multipath | Same panic |
| `virtio_net` | `eth0`/`ens3` | Fast networking, offloads, multiqueue | No network at all |
| `virtio_balloon` | — | Host reclaims guest RAM on demand | No memory overcommit |
| `virtio_rng` | `/dev/hwrng` | Entropy from the host | Boot stalls on entropy, slow TLS key gen |
| `virtio_console` | `/dev/hvc0`, `/dev/virtio-ports/*` | Serial console, guest agent channel | Guest agent dead |
| `virtio_gpu` | DRM device | Accelerated framebuffer | Text console only |
| `virtiofs` | `virtiofs` mount type | Host directory shared with near-native semantics | No shared FS |
| `net_failover` | — | Pairs a VF with `virtio-net` for migratable SR-IOV | No live migration with SR-IOV |

```
$ lspci -k
00:01.1 IDE interface: Intel Corporation 82371SB PIIX3 IDE [Natoma/Triton II]
	Kernel driver in use: ata_piix
00:03.0 Ethernet controller: Red Hat, Inc. Virtio network device
	Subsystem: Red Hat, Inc. Device 0001
	Kernel driver in use: virtio-pci
00:04.0 SCSI storage controller: Red Hat, Inc. Virtio block device
	Subsystem: Red Hat, Inc. Device 0002
	Kernel driver in use: virtio-pci

$ ls -l /sys/bus/virtio/devices/*/driver
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio0/driver -> ../../../../bus/virtio/drivers/virtio_net
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio1/driver -> ../../../../bus/virtio/drivers/virtio_blk
lrwxrwxrwx 1 root root 0 Aug 26 09:12 /sys/bus/virtio/devices/virtio2/driver -> ../../../../bus/virtio/drivers/virtio_balloon
```

Note the two-level binding: the **PCI** driver is `virtio-pci`; the **function** driver (`virtio_net`, `virtio_blk`) binds on the synthetic `virtio` bus. Reading only `lspci -k` and concluding "the virtio_net driver is missing" is a classic misdiagnosis.

PCI IDs worth recognizing: vendor `1af4` is "Red Hat, Inc." (the virtio vendor ID); `1af4:1000` legacy net, `1af4:1001` legacy block, `1af4:1041`–`1af4:1049` modern (virtio 1.0) devices.

### 4.2 Integration packages per platform

Every hypervisor ships a guest-side package that goes beyond drivers: it provides an out-of-band control channel for graceful shutdown, IP reporting, filesystem freeze for consistent snapshots, time sync and clipboard/display integration.

| Platform | Package (RHEL / Debian) | Daemon(s) | Kernel modules | What breaks without it |
|---|---|---|---|---|
| **KVM/QEMU/libvirt** | `qemu-guest-agent` | `qemu-ga` | `virtio_console` | `virsh shutdown` falls back to ACPI; no `domifaddr --source agent`; **snapshots are crash-consistent, not filesystem-consistent** |
| **VMware ESXi** | `open-vm-tools` / `open-vm-tools` | `vmtoolsd` | `vmxnet3`, `vmw_pvscsi`, `vmw_balloon`, `vmwgfx`, `vmw_vsock_vmci_transport` | No graceful shutdown, no IP in vCenter, no quiesced snapshots, slow NIC/HBA |
| **Hyper-V / Azure** | `hyperv-daemons` / `linux-cloud-tools-virtual` | `hv_kvp_daemon`, `hv_vss_daemon`, `hv_fcopy_daemon` | `hv_vmbus`, `hv_netvsc`, `hv_storvsc`, `hv_utils`, `hv_balloon` | No IP injection, no VSS-consistent backups, no host→guest file copy |
| **Xen (PV/PVHVM)** | in-kernel + `xe-guest-utilities` (XenServer) | `xe-daemon` | `xen_blkfront`, `xen_netfront`, `xen-pcifront`, `xenbus` | No guest metrics in XenCenter |
| **VirtualBox** | Guest Additions (out-of-tree) | `VBoxService`, `VBoxClient` | `vboxguest`, `vboxsf`, `vboxvideo` | No shared folders, no seamless display, no time sync |
| **AWS Nitro** | (in-kernel) `ena`, `nvme` | — | `ena`, `nvme` | Instance will not boot on modern instance types |

QEMU guest agent in practice — this is the piece that turns a snapshot from "equivalent to yanking the power cord" into a consistent backup:

```
# guest side
$ systemctl enable --now qemu-guest-agent
$ ls -l /dev/virtio-ports/
lrwxrwxrwx 1 root root 12 Aug 26 09:12 org.qemu.guest_agent.0 -> ../vport1p1
```

```
# host side
# virsh domifaddr web-01 --source agent
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 lo         00:00:00:00:00:00    ipv4         127.0.0.1/8
 enp1s0     52:54:00:6f:2a:11    ipv4         10.20.4.117/24

# virsh qemu-agent-command web-01 '{"execute":"guest-fsfreeze-freeze"}'
{"return":3}
# virsh snapshot-create-as web-01 --disk-only --atomic pre-upgrade
Domain snapshot pre-upgrade created
# virsh qemu-agent-command web-01 '{"execute":"guest-fsfreeze-thaw"}'
{"return":3}
```

`{"return":3}` is the number of frozen filesystems, not an error code.

### 4.3 Time, entropy and memory — the three silent guest problems

**Time.** A guest's TSC is not reliable across host migrations and vCPU descheduling. KVM exposes a paravirtual clocksource:

```
$ cat /sys/devices/system/clocksource/clocksource0/available_clocksource
kvm-clock tsc acpi_pm
$ cat /sys/devices/system/clocksource/clocksource0/current_clocksource
kvm-clock
```

For sub-microsecond accuracy, load `ptp_kvm` and feed `chrony` a PTP hardware clock reference tied to the host — no network NTP involved:

```ini
# /etc/chrony/conf.d/ptp-kvm.conf
refclock PHC /dev/ptp0 poll 2 dpoll -2 offset 0 stratum 2
makestep 1.0 3
```

```
$ chronyc sources -v
MS Name/IP address         Stratum Poll Reach LastRx Last sample               
===============================================================================
#* PHC0                          2   2   377     3    -12ns[  -18ns] +/-  103ns
```

**Entropy.** Guests have almost no hardware interrupt jitter. Without `virtio_rng`, first boot can stall for minutes generating SSH host keys.

```
$ cat /sys/class/misc/hw_random/rng_available
virtio_rng.0
$ cat /proc/sys/kernel/random/entropy_avail
256
```

(Since Linux 5.6 `getrandom(2)` blocks only until the CRNG is seeded, and 5.18+ reports `entropy_avail` as 256 once ready — an old runbook telling you to panic below 1000 is obsolete.)

**Memory.** `virtio_balloon` lets the host reclaim guest RAM. From the guest's perspective, memory silently disappears:

```
# host
# virsh setmem web-01 2G --live
# guest
$ free -m
               total        used        free      shared  buff/cache   available
Mem:            1987         412        1103           4         471        1421
```

The trade-off: ballooning enables overcommit and higher density, but a guest under ballooning can be OOM-killed for reasons entirely outside its own control, and the guest's `total` no longer matches the VM's configured size — which breaks any autoscaler or JVM heap sizing that reads `MemTotal`. In Kubernetes-on-VMs, disable ballooning on worker nodes or pin `--reserve`.

---

## 5. IaaS building blocks: compute, block storage, networking

An "instance" in any IaaS is a composition of three independently-lifecycled resources plus an identity channel.

| Element | What it is | Lifecycle | Linux-side artifact | Failure mode |
|---|---|---|---|---|
| **Compute instance** | vCPU + RAM + a flavor/instance-type, scheduled onto a hypervisor | Ephemeral; can be stopped, resized, destroyed | The running kernel; `lscpu`, `/proc/meminfo` | Host failure = instance loss unless the workload is replicated |
| **Ephemeral / instance store** | Disk local to the hypervisor host | Dies with the instance (including on stop/start) | `/dev/nvme1n1`, mounted `/mnt` | Data loss on stop; never put a database here |
| **Block storage volume** | Network-attached virtual disk (Cinder, EBS, PD, VMDK on SAN) | Independent of the instance; snapshot-able, re-attachable | `/dev/vdb`, `/dev/nvme1n1` | Detach without unmount = filesystem corruption |
| **Object storage** | HTTP key/value store | Independent, effectively infinite | `s3fs`, `rclone`, or the SDK — **not a filesystem** | Treating it as POSIX; no atomic rename, no locks |
| **Networking** | Virtual L2/L3: VPC/tenant network, subnet, port, security group, floating/elastic IP, load balancer | Independent | `ens3`, routes, `nftables` | Security group vs host firewall confusion |
| **Metadata service** | Link-local HTTP endpoint at `169.254.169.254` serving instance identity and user-data | Per-instance | Consumed by `cloud-init` | SSRF exposure; blocked by an over-eager firewall → no `cloud-init` |
| **Image** | The bootable template | Versioned artifact | `/` at first boot | The subject of §6 |

### 5.1 The metadata service, per cloud

```
# AWS — IMDSv2 (session-oriented, mandatory on hardened accounts)
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id
i-0abcd1234ef567890

# OpenStack
$ curl -s http://169.254.169.254/openstack/latest/meta_data.json | jq -r .uuid
c0ffee00-dead-4bee-9001-0123456789ab

# Google Compute Engine (header is mandatory — that is the SSRF defence)
$ curl -s -H 'Metadata-Flavor: Google' \
      http://metadata.google.internal/computeMetadata/v1/instance/id
4098723641098345670

# Azure
$ curl -s -H 'Metadata: true' \
      'http://169.254.169.254/metadata/instance?api-version=2021-02-01' | jq -r .compute.vmId
6a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d
```

| | AWS IMDSv1 | AWS IMDSv2 | GCP | Azure | OpenStack |
|---|---|---|---|---|---|
| Auth | none | PUT-issued token | required header | required header | none |
| Hop limit | n/a | configurable (default 1) | n/a | n/a | n/a |
| SSRF-safe | **No** | Yes | Yes | Yes | No |
| Reachable from a container? | Yes (host network) | Only if hop limit ≥ 2 | Yes | Yes | Yes |

**Architectural note for platform engineers:** the metadata service is the instance's *ambient credential*. On Kubernetes nodes, block pod egress to `169.254.169.254` (NetworkPolicy, or `iptables`/`nftables` on the node) unless you are using IRSA/Workload Identity — otherwise any pod that can make an HTTP request inherits the node's IAM role. This is the single most exploited cloud misconfiguration, and it lives exactly at the boundary this objective describes.

### 5.2 Growing a root disk after a resize

Resizing the volume in the IaaS API does nothing inside the guest. Three layers must each be told:

```
# 1. The kernel must see the new size (usually automatic for virtio-blk)
# echo 1 > /sys/class/block/vda/device/rescan   # for SCSI: .../device/rescan

# 2. The partition table
# growpart /dev/vda 1
CHANGED: partition=1 start=2048 old: size=41940992 end=41943040 new: size=209713119 end=209715167

# 3. The filesystem
# resize2fs /dev/vda1        # ext4
# xfs_growfs /                # XFS (mount point, not device)
meta-data=/dev/vda1              isize=512    agcount=4, agsize=1310720 blks
data     =                       bsize=4096   blocks=5242880, imaxpct=25
...
data blocks changed from 5242880 to 26214139
```

`cloud-init` automates steps 2 and 3 via the `growpart` and `resizefs` modules — which is why they run in the *network* stage, before anything tries to write to a full disk.

---

## 6. Images, templates and the de-identification problem

### 6.1 Image formats

| Format | Platform | Sparse | Snapshots | Compression | Notes |
|---|---|---|---|---|---|
| `raw` | any | via filesystem holes | no | no | Fastest; the baseline |
| `qcow2` | QEMU/KVM | yes | internal + external | yes (zlib/zstd) | Backing files enable copy-on-write templates |
| `vmdk` | VMware | yes | yes | yes | Many sub-flavours; `monolithicSparse` vs `streamOptimized` |
| `vhd` / `vhdx` | Hyper-V, Azure | yes | yes | yes | **Azure requires fixed-size VHD with an aligned 1 MiB size** |
| `AMI` (EBS-backed) | AWS | yes | yes (EBS snapshot) | n/a | A snapshot + metadata, not a file you download |
| OCI image | containers | n/a | layers are the snapshots | gzip/zstd | Content-addressed, manifest + config + layer tarballs |

```
$ qemu-img info base-deb12-2026.08.qcow2
image: base-deb12-2026.08.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 1.21 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false

# Copy-on-write clone: 200 KiB on disk, not 1.2 GiB
$ qemu-img create -f qcow2 -F qcow2 -b base-deb12-2026.08.qcow2 web-01.qcow2 40G
Formatting 'web-01.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off
  compression_type=zlib size=42949672960 backing_file=base-deb12-2026.08.qcow2
  backing_fmt=qcow2 lazy_refcounts=off refcount_bits=16
```

### 6.2 What must be unique — the de-identification table

This is the heart of the objective. Everything below is host identity that a naive `dd`/`qemu-img convert` clone will duplicate.

| Artifact | Path | Consequence of duplication | Correct reset |
|---|---|---|---|
| **systemd machine ID** | `/etc/machine-id` | Duplicate DHCP client-ID → **duplicate IP leases**; merged journal namespaces; duplicated asset inventory | `rm /etc/machine-id && systemd-machine-id-setup` (or truncate to empty) |
| **D-Bus machine ID** | `/var/lib/dbus/machine-id` | Apps keyed on the D-Bus UUID collide; on split-brain vs `/etc/machine-id`, some services fail to start | Symlink to `/etc/machine-id`, or `rm` + `dbus-uuidgen --ensure` |
| **SSH host keys** | `/etc/ssh/ssh_host_{rsa,ecdsa,ed25519}_key[.pub]` | Any clone can impersonate any other; `known_hosts` gives a false sense of authenticity — **a MITM is indistinguishable from a legitimate host** | `rm -f /etc/ssh/ssh_host_*` (regenerated by `ssh-keygen -A` or the unit at boot) |
| Hostname | `/etc/hostname`, `/etc/hosts` | Log attribution, Kerberos, TLS SANs | Set per-instance (`cloud-init` `set_hostname`) |
| NetworkManager secret key | `/var/lib/NetworkManager/secret_key` | Identical stable-privacy IPv6 interface IDs | `rm` (regenerated) |
| DHCP leases & DUIDs | `/var/lib/dhclient/*`, `/var/lib/NetworkManager/*.lease`, `/etc/machine-id`-derived DUID | Stale/duplicate lease claims | `rm` lease files; see §7.3 |
| Random seed | `/var/lib/systemd/random-seed`, `/var/lib/urandom/random-seed` | Every clone seeds its CRNG identically on first boot | `rm` |
| iSCSI initiator name | `/etc/iscsi/initiatorname.iscsi` | Two hosts claim the same IQN → **LUN corruption** | `echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi` |
| Persistent NIC rules | `/etc/udev/rules.d/70-persistent-net.rules` | MAC baked in; new NIC becomes `eth1`, network dead | `rm` |
| Filesystem / LVM UUIDs | `blkid`, `pvs -o+uuid` | Attach two clones to one host and the wrong root may be mounted; `vgimportclone` needed | `tune2fs -U random` / `xfs_admin -U generate` / `vgimportclone` |
| `cloud-init` state | `/var/lib/cloud/` | `cloud-init` believes it already ran; **user-data ignored** | `cloud-init clean --logs --seed` |
| Subscription / agent identity | `/etc/rhsm/`, `/var/lib/rhsm/`, `/etc/salt/minion_id`, `/etc/puppetlabs/puppet/ssl/`, `/var/lib/zabbix/`, `/etc/telegraf/` | Config-management and monitoring agents fight over one identity; the last to register wins | Per-agent unregister/clean |
| Kerberos keytab | `/etc/krb5.keytab` | Clone can decrypt the original's service tickets | `rm` |
| User SSH material & history | `/root/.ssh/`, `/home/*/.ssh/`, `~/.bash_history` | Credential leak in the published image | `rm` |
| Logs | `/var/log/**` | Leak of build-time secrets and prior-host identity | Truncate |

### 6.3 Automating it: `virt-sysprep` (offline) and a first-boot unit (online)

`virt-sysprep` operates on the image file **while the guest is shut down**, using `libguestfs` — no need to boot it.

```
# virt-sysprep --list-operations | head -20
abrt-data * Remove the crash data generated by ABRT
backup-files * Remove editor backup files from the guest
bash-history * Remove the bash history in the guest
blkid-tab * Remove blkid tab in the guest
ca-certificates Remove CA certificates in the guest
crash-data * Remove the crash data generated by kexec-tools
cron-spool * Remove user at-jobs and cron-jobs
customize * Customize the guest
dhcp-client-state * Remove DHCP client leases
dhcp-server-state * Remove DHCP server leases
dovecot-data * Remove Dovecot (mail server) data
firewall-rules Remove the firewall rules
flag-reconfiguration Flag the system for reconfiguration
fs-uuids Change filesystem UUIDs
ipa-client * Remove the IPA files
kerberos-data Remove Kerberos data in the guest
kerberos-hostkeytab * Remove the Kerberos host keytab file in guest
logfiles * Remove many log files from the guest
machine-id * Remove the local machine ID
mail-spool * Remove email from the local mail spool directory

# virt-sysprep -a base-deb12-2026.08.qcow2 \
    --enable machine-id,ssh-hostkeys,ssh-userdir,logfiles,bash-history,\
dhcp-client-state,udev-persistent-net,random-seed,net-hostname,tmp-files \
    --firstboot-command 'systemctl enable --now qemu-guest-agent'
[   0.0] Examining the guest ...
[   4.3] Performing "machine-id" ...
[   4.3] Performing "ssh-hostkeys" ...
[   4.3] Performing "ssh-userdir" ...
[   4.4] Performing "logfiles" ...
[   4.6] Performing "bash-history" ...
[   4.6] Performing "dhcp-client-state" ...
[   4.6] Performing "udev-persistent-net" ...
[   4.6] Performing "random-seed" ...
[   4.6] Performing "net-hostname" ...
[   4.7] Performing "tmp-files" ...
[   4.9] Performing "firstboot-command" ...
[   5.1] SELinux relabelling
```

Operations marked `*` are enabled by default; `virt-sysprep -a img.qcow2` with no flags already removes `machine-id` and `ssh-hostkeys`. **Always operate on a copy** — `virt-sysprep` modifies the image in place and there is no undo.

The belt-and-braces companion: a first-boot unit that regenerates identity even if the image was cloned by someone who never heard of `virt-sysprep`.

```ini
# /etc/systemd/system/regenerate-host-identity.service
[Unit]
Description=Regenerate per-host identity after cloning
Documentation=man:machine-id(5) man:ssh-keygen(1)
DefaultDependencies=no
After=systemd-remount-fs.service
Before=network-pre.target sshd.service cloud-init-local.service
Wants=network-pre.target
ConditionPathExists=/var/lib/host-identity-stale
ConditionVirtualization=vm

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/regenerate-host-identity
ExecStartPost=/bin/rm -f /var/lib/host-identity-stale
StandardOutput=journal+console

[Install]
WantedBy=sysinit.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/regenerate-host-identity
# Mint fresh per-host identity. Idempotent: guarded by /var/lib/host-identity-stale.
set -euo pipefail
log() { printf '[identity] %s\n' "$*"; }

# 1. systemd machine ID -----------------------------------------------------
log "resetting /etc/machine-id"
rm -f /etc/machine-id
systemd-machine-id-setup            # writes a fresh 32-hex-digit ID

# 2. D-Bus machine ID -------------------------------------------------------
log "aligning D-Bus machine ID with /etc/machine-id"
rm -f /var/lib/dbus/machine-id
install -d -m 0755 /var/lib/dbus
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# 3. SSH host keys ----------------------------------------------------------
log "regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
ssh-keygen -A                       # one key per supported algorithm

# 4. Entropy seed -----------------------------------------------------------
rm -f /var/lib/systemd/random-seed /var/lib/urandom/random-seed

# 5. Network identity -------------------------------------------------------
rm -f /var/lib/NetworkManager/secret_key
rm -f /var/lib/NetworkManager/*.lease /var/lib/NetworkManager/*.state
rm -rf /var/lib/dhclient/* /var/lib/dhcp/*
rm -f /etc/udev/rules.d/70-persistent-net.rules

# 6. Storage identity -------------------------------------------------------
if [ -w /etc/iscsi/initiatorname.iscsi ] && command -v iscsi-iname >/dev/null; then
    echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
fi

# 7. Provisioning state -----------------------------------------------------
command -v cloud-init >/dev/null && cloud-init clean --logs --seed || true

log "done; new machine-id=$(cat /etc/machine-id)"
```

---

## 7. `/etc/machine-id` in depth

### 7.1 What it is

A **32-character lowercase hexadecimal string** (128 bits, newline-terminated, no dashes) that identifies the installed operating system for the lifetime of that installation. It is *not* a UUID in canonical dashed form, it is *not* the SMBIOS system UUID, and it does *not* change across reboots (unlike the boot ID in `/proc/sys/kernel/random/boot_id`).

```
$ cat /etc/machine-id
5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
$ wc -c /etc/machine-id
33 /etc/machine-id
$ cat /proc/sys/kernel/random/boot_id
0f3d4b2a-9c1e-4f8a-9b2c-3d4e5f6a7b8c        # changes every boot
```

`machine-id(5)` states plainly that the value **should be considered confidential and must not be exposed on untrusted networks** — it is a stable, unauthenticated global identifier. When a service needs a per-application identifier, the correct call is `sd_id128_get_machine_app_specific()`, which HMACs the machine ID with an application UUID so the raw value never leaks.

### 7.2 First-boot semantics (systemd ≥ 247)

The state of `/etc/machine-id` in the image decides whether systemd treats the boot as a *first boot*:

| State of `/etc/machine-id` in the image | Boot classified as | Behaviour |
|---|---|---|
| **File does not exist** | **First boot** | systemd writes `uninitialized\n`, over-mounts a tmpfs file with the real ID, commits it to disk after `first-boot-complete.target`. `ConditionFirstBoot=yes` units run (`systemd-firstboot.service` may prompt for locale/root password) |
| **Contains `uninitialized`** | **First boot** | Same as above |
| **Exists but is empty (0 bytes)** | **Not** a first boot | A fresh ID is still generated and committed, but `ConditionFirstBoot=` units do **not** run |
| Contains a valid ID | Not a first boot | Nothing happens — this is the clone bug |

**The practical consequence for image building:** choose deliberately.

- **Empty file** → each clone gets a unique ID, silently, with no first-boot interactive setup. This is what you want for cloud images that are provisioned by `cloud-init`.
- **Absent file** → each clone gets a unique ID *and* first-boot units fire. Use this when you rely on `systemd-firstboot` or on `ConditionFirstBoot=yes` units.

Do **not** leave a valid ID in a published image, and do not confuse "empty" with "absent".

```
# Build an image for cloud provisioning (no interactive first boot):
# truncate -s 0 /etc/machine-id
# ls -l /etc/machine-id
-rw-r--r-- 1 root root 0 Aug 26 09:40 /etc/machine-id

# On a running machine, mint a new one immediately:
# rm -f /etc/machine-id
# systemd-machine-id-setup
Initializing machine ID from random generator.
# cat /etc/machine-id
b71c9e04ad2f4e1c8a3d6f5b2c9e0d47
```

`systemd-machine-id-setup` derives the ID, in order of preference, from: the D-Bus machine ID, the KVM/container-supplied ID (`/sys/class/dmi/id/product_uuid` on KVM, or the container manager's value), or `/dev/urandom`. `--commit` writes a transient (over-mounted) ID to disk once `/etc` becomes writable — the path used when the rootfs was read-only at boot.

### 7.3 What actually reads `/etc/machine-id`

This is why duplication is not cosmetic:

| Consumer | Use | Symptom of duplication |
|---|---|---|
| `systemd-journald` | Journal file path `/var/log/journal/<machine-id>/system.journal` | Remote journals from several hosts merge into one namespace |
| `systemd-networkd` | Default DUID-EN (PEN 43793) and, with `ClientIdentifier=duid`, the **DHCPv4 client ID** | **Duplicate IP leases** |
| `systemd-resolved` | LLMNR/mDNS conflict resolution | Name conflicts on the local link |
| D-Bus | Machine identity for bus addressing | Session bus confusion, app misbehaviour |
| Kubernetes kubelet | `node.status.nodeInfo.machineID` | Node correlation, some CSI drivers, node-problem-detector |
| Asset inventory / Red Hat Insights / Landscape / Salt | Primary host key | 40 servers appear as 1 |
| Licensing and telemetry | Installation identity | Under-counted or rejected licences |

```
$ kubectl get nodes -o custom-columns='NODE:.metadata.name,MACHINE-ID:.status.nodeInfo.machineID'
NODE       MACHINE-ID
worker-1   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
worker-2   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10     # <-- cloned template, not de-identified
worker-3   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
```

**The `systemd-networkd` fix**, when you cannot re-image immediately:

```ini
# /etc/systemd/network/10-dhcp.network
[Match]
Name=en*

[Network]
DHCP=ipv4

[DHCPv4]
# Use the MAC address instead of a machine-id-derived DUID.
ClientIdentifier=mac
```

```
# networkctl reload && networkctl reconfigure enp1s0
# journalctl -u systemd-networkd -b --no-pager | tail -4
Aug 26 09:52:11 web-01 systemd-networkd[612]: enp1s0: DHCPv4 address 10.20.4.131/24 via 10.20.4.1
```

### 7.4 D-Bus machine ID

Historically D-Bus kept its own UUID in `/var/lib/dbus/machine-id`, generated by `dbus-uuidgen`. On systemd distributions it is now a **symlink to `/etc/machine-id`**, and the two must agree.

```
$ ls -l /var/lib/dbus/machine-id
lrwxrwxrwx 1 root root 15 Jul  4  2025 /var/lib/dbus/machine-id -> /etc/machine-id
$ dbus-uuidgen --get
5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
$ [ "$(dbus-uuidgen --get)" = "$(cat /etc/machine-id)" ] && echo consistent || echo SPLIT-BRAIN
consistent
```

If they diverge (a real regular occurrence on images built from a mix of eras), fix it with:

```
# rm -f /var/lib/dbus/machine-id
# ln -s /etc/machine-id /var/lib/dbus/machine-id
# # or, if you deliberately want a standalone file:
# dbus-uuidgen --ensure=/var/lib/dbus/machine-id
```

---

## 8. SSH host keys: the security half of de-identification

### 8.1 Why duplication is a security incident, not an annoyance

The SSH host key is the *only* thing that authenticates the server to the client. If 40 hosts share one Ed25519 host key, then:

1. Any operator (or attacker) with root on **one** of them can read `/etc/ssh/ssh_host_ed25519_key` and transparently impersonate **all forty**, with `known_hosts` and `StrictHostKeyChecking=yes` raising no objection whatsoever.
2. Host-key rotation on one machine breaks trust for the whole fleet.
3. If the image was ever published (a public AMI, a shared qcow2, a Docker image), the private key is public.

```
$ for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
3072 SHA256:9k1Uh0V6M+7NfLK2s8Q0mYq3nRPxJ2dW8cZfB1tA5vE root@web-01 (RSA)
256 SHA256:Q3nT9pR1xK7mB2vC5dF8gH0jL4nP6sU9wY2aE5iO7uM root@web-01 (ECDSA)
256 SHA256:Xy8Kd2Lm9Np4Qr6St1Uv3Wx5Yz7Ab0Cd2Ef4Gh6Ij8 root@web-01 (ED25519)
```

Run that across the fleet and count distinct fingerprints. If the count is 1, you have an incident.

### 8.2 Regeneration

```
# rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
# ssh-keygen -A
ssh-keygen: generating new host keys: RSA ECDSA ED25519
# systemctl restart ssh    # sshd on RHEL
```

`ssh-keygen -A` generates **only the missing** key types, using default parameters and an empty passphrase — which is exactly the idempotent behaviour a boot-time unit needs. Distributions wire this into the boot path differently:

| Distribution | Mechanism |
|---|---|
| Debian/Ubuntu | `/lib/systemd/system/ssh.service` `ExecStartPre`, plus the `openssh-server` postinst; cloud images rely on `cloud-init`'s `ssh` module |
| RHEL/Fedora/CentOS Stream | `sshd-keygen@.service` templated units (`sshd-keygen@rsa.service`, `@ecdsa`, `@ed25519`) pulled in by `sshd-keygen.target` |
| SUSE | `sshd.service` `ExecStartPre=/usr/sbin/sshd-gen-keys-start` |
| Cloud images (any) | `cloud-init` `ssh` module — see §9 |

### 8.3 Making the new key trustworthy

Regeneration solves impersonation but creates a bootstrapping problem: how does the client learn the *correct* new fingerprint? Three production answers:

**(a) Console fingerprint printing** — `cloud-init`'s `keys_to_console` module writes host key fingerprints to the serial console, which the IaaS API exposes:

```
# openstack console log show web-01 | grep -A6 'BEGIN SSH HOST KEY'
ci-info: ++++++++Authorized keys from /home/deploy/.ssh/authorized_keys++++++++
-----BEGIN SSH HOST KEY FINGERPRINTS-----
256 SHA256:Xy8Kd2Lm9Np4Qr6St1Uv3Wx5Yz7Ab0Cd2Ef4Gh6Ij8 root@web-01 (ED25519)
3072 SHA256:9k1Uh0V6M+7NfLK2s8Q0mYq3nRPxJ2dW8cZfB1tA5vE root@web-01 (RSA)
-----END SSH HOST KEY FINGERPRINTS-----
```

**(b) SSHFP DNS records** signed with DNSSEC:

```
$ ssh-keygen -r web-01.prod.example.net -f /etc/ssh/ssh_host_ed25519_key.pub
web-01.prod.example.net IN SSHFP 4 1 9f2c1a8b7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a
web-01.prod.example.net IN SSHFP 4 2 3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c
```
```
$ ssh -o VerifyHostKeyDNS=yes web-01.prod.example.net
```

**(c) An SSH certificate authority** — the fleet's host keys are signed by a CA key that clients trust once. This is the correct answer at scale: rotation becomes a non-event.

```
# On the CA host:
# ssh-keygen -s /etc/ssh/ca_host_key -I web-01 -h -n web-01.prod.example.net \
      -V +52w /etc/ssh/ssh_host_ed25519_key.pub
Signed host key /etc/ssh/ssh_host_ed25519_key-cert.pub: id "web-01" serial 0 for web-01.prod.example.net valid from 2026-08-26T00:00:00 to 2027-08-25T00:00:00
```
```
# /etc/ssh/sshd_config.d/60-hostcert.conf
HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
```
```
# ~/.ssh/known_hosts on every client — one line for the whole fleet
@cert-authority *.prod.example.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
```

| Approach | Client change | Rotation cost | DNSSEC/PKI needed | Verdict |
|---|---|---|---|---|
| Manual `known_hosts` | High | O(hosts × clients) | no | Does not scale |
| Console fingerprint | Manual read | O(hosts) | no | Fine for a handful of VMs |
| SSHFP + DNSSEC | `VerifyHostKeyDNS=yes` | O(hosts), automatable | DNSSEC | Good if you already run DNSSEC |
| **SSH host CA** | One `@cert-authority` line | **O(1)** | CA key custody | **Best at fleet scale** |
| `UpdateHostKeys=yes` (OpenSSH ≥ 8.5, default `yes` since 8.5 when the key is already trusted) | none | automatic for *additional* keys | no | Useful complement, not a bootstrap |

---

## 9. `cloud-init`: the industry-standard guest provisioning agent

### 9.1 Architecture

`cloud-init` runs early in boot, discovers a **datasource**, reads **meta-data** (identity supplied by the platform) and **user-data** (configuration supplied by you), and executes a pipeline of **modules** across four systemd services.

| Stage | systemd unit | Command | `cloud.cfg` module list | What runs here |
|---|---|---|---|---|
| Generator | `cloud-init-generator` | — | — | Decides whether to enable `cloud-init.target` at all |
| **Local** | `cloud-init-local.service` | `cloud-init init --local` | — | Find a *local* datasource (ConfigDrive, NoCloud); write network configuration. Runs **before** the network is up |
| **Network** | `cloud-init-network.service` (was `cloud-init.service` before 24.3) | `cloud-init init` | `cloud_init_modules` | Network is up; fetch from IMDS; `disk_setup`, `mounts`, `growpart`, `resizefs`, `set_hostname`, `update_etc_hosts`, `ssh` |
| **Config** | `cloud-config.service` | `cloud-init modules --mode=config` | `cloud_config_modules` | `ssh_import_id`, `locale`, `set_passwords`, `apt`/`yum` config, `package_update_upgrade_install`, `timezone` |
| **Final** | `cloud-final.service` | `cloud-init modules --mode=final` | `cloud_final_modules` | `runcmd`, `scripts_user`, `ssh_authkey_fingerprints`, `keys_to_console`, `phone_home`, `final_message`, `power_state_change` |

State lives under `/var/lib/cloud`:

```
$ sudo tree -L 2 /var/lib/cloud
/var/lib/cloud
├── data
│   ├── instance-id
│   ├── previous-instance-id
│   ├── result.json
│   └── status.json
├── handlers
├── instance -> /var/lib/cloud/instances/i-0abcd1234ef567890
├── instances
│   └── i-0abcd1234ef567890
│       ├── boot-finished
│       ├── cloud-config.txt
│       ├── datasource
│       ├── obj.pkl
│       ├── sem                       # per-instance semaphores
│       ├── user-data.txt
│       ├── user-data.txt.i
│       └── vendor-data.txt
├── scripts
│   ├── per-boot
│   ├── per-instance
│   ├── per-once
│   └── vendor
├── seed
└── sem                               # per-once semaphores
```

**The `instance-id` is the re-run trigger.** `cloud-init` compares the datasource's `instance-id` against `/var/lib/cloud/data/instance-id`. If they differ, it treats the boot as a *new instance*: `per-instance` modules run again. If they match, only `per-boot` modules run. This is why cloning a VM that already booted, without `cloud-init clean`, results in user-data being silently ignored — the semaphores in `/var/lib/cloud/instances/<old-id>/sem/` say "already done".

| Module frequency | Runs when | Semaphore location |
|---|---|---|
| `once-per-instance` (default) | `instance-id` changed | `/var/lib/cloud/instances/<id>/sem/` |
| `always` (per-boot) | Every boot | not recorded |
| `once` (per-once) | Ever, on this machine | `/var/lib/cloud/sem/` |

### 9.2 `/etc/cloud/cloud.cfg` — the full, annotated configuration

```yaml
# /etc/cloud/cloud.cfg — Debian 12 cloud image, annotated.
# Drop-in overrides go in /etc/cloud/cloud.cfg.d/*.cfg (merged in lexical order).

# --- Identity and users --------------------------------------------------
users:
  - default

# Create the default user from the distro definition below; do not lock root's
# password to "!" only — disable_root is what actually blocks root SSH login.
disable_root: true
disable_root_opts: "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command=\"echo 'Please login as the user \\\"debian\\\" rather than the user \\\"root\\\".';echo;sleep 10;exit 142\""

# --- Filesystem ----------------------------------------------------------
# Grow the root partition and filesystem to fill the (possibly resized) disk.
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false

resize_rootfs: true

mount_default_fields: [~, ~, 'auto', 'defaults,nofail,x-systemd.after=cloud-init-network.service', '0', '2']

# --- SSH -----------------------------------------------------------------
# THE de-identification switch: delete the image's host keys and regenerate.
ssh_deletekeys: true
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
ssh_pwauth: false
ssh_svcname: ssh

# --- Hostname ------------------------------------------------------------
preserve_hostname: false
prefer_fqdn_over_hostname: false

# --- Network -------------------------------------------------------------
network:
  config: disabled          # set by the image builder when the platform manages
                            # networking itself; remove this to let cloud-init
                            # render /etc/netplan/50-cloud-init.yaml

# --- Datasource discovery ------------------------------------------------
# Order matters: the first datasource that self-identifies wins. Pinning this
# list on a known platform cuts 10-30 s off boot, because cloud-init stops
# probing endpoints that will never answer.
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, Azure, GCE, Hetzner,
                   Oracle, Exoscale, CloudStack, OVF, LXD, None ]

datasource:
  Ec2:
    timeout: 10             # seconds per HTTP attempt against 169.254.169.254
    max_wait: 60            # give up on the IMDS after this many seconds
    metadata_urls: [ 'http://169.254.169.254' ]
  NoCloud:
    seedfrom: null
  OpenStack:
    max_wait: 60
    timeout: 10

# --- Module pipeline -----------------------------------------------------
# Stage 2: network is up. Anything that must exist before packages/services.
cloud_init_modules:
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts
  - ca_certs
  - rsyslog
  - users_groups
  - ssh

# Stage 3: configuration proper.
cloud_config_modules:
  - wireguard
  - snap
  - ssh_import_id
  - keyboard
  - locale
  - set_passwords
  - grub_dpkg
  - apt_pipelining
  - apt_configure
  - ubuntu_pro
  - ntp
  - timezone
  - disable_ec2_metadata
  - runcmd
  - byobu

# Stage 4: last, and user-visible.
cloud_final_modules:
  - package_update_upgrade_install
  - fan
  - landscape
  - lxd
  - ubuntu_drivers
  - write_files_deferred
  - puppet
  - chef
  - ansible
  - mcollective
  - salt_minion
  - reset_rmc
  - refresh_rmc_and_interface
  - rightscale_userdata
  - scripts_vendor
  - scripts_per_once
  - scripts_per_boot
  - scripts_per_instance
  - scripts_user
  - ssh_authkey_fingerprints
  - keys_to_console
  - install_hotplug
  - phone_home
  - final_message
  - power_state_change

# --- Distro definition ---------------------------------------------------
system_info:
  distro: debian
  default_user:
    name: debian
    lock_passwd: true
    gecos: Debian
    groups: [adm, audio, cdrom, dialout, dip, floppy, netdev, plugdev, sudo, video]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
  network:
    renderers: ['netplan', 'eni', 'sysconfig', 'networkd']
    activators: ['netplan', 'eni', 'network-manager', 'networkd']
  ntp_client: chrony
  paths:
    cloud_dir: /var/lib/cloud/
    templates_dir: /etc/cloud/templates/
  package_mirrors:
    - arches: [default]
      failsafe:
        primary: http://deb.debian.org/debian
        security: http://security.debian.org/debian-security
  ssh_svcname: ssh
```

### 9.3 A complete production `user-data`

```yaml
#cloud-config
# ---------------------------------------------------------------------------
# Production user-data for a Kubernetes worker node on OpenStack / NoCloud.
# Validate BEFORE booting:  cloud-init schema --config-file user-data --annotate
# ---------------------------------------------------------------------------

hostname: k8s-worker-04
fqdn: k8s-worker-04.prod.example.net
prefer_fqdn_over_hostname: true
manage_etc_hosts: true

timezone: UTC
locale: en_US.UTF-8

# --- Identity: SSH keys only, never passwords ------------------------------
users:
  - name: sre
    gecos: Platform SRE
    primary_group: sre
    groups: [adm, sudo, systemd-journal]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH8kL2mN9pQ4rS6tU1vW3xY5zA7bC0dE2fG4hI6jK8lM sre@bastion
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1cD3eF5gH7iJ9kL0mN2oP4qR6sT8uV0wX2yZ4aB6cD ci@runner

# --- De-identification -----------------------------------------------------
ssh_deletekeys: true
ssh_genkeytypes: [ed25519, rsa]
ssh_pwauth: false
disable_root: true

# --- Storage ---------------------------------------------------------------
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout: true
    overwrite: false

fs_setup:
  - label: containerd
    filesystem: xfs
    device: /dev/vdb
    partition: 1
    overwrite: false
    extra_opts: ['-n', 'ftype=1']

mounts:
  - [ LABEL=containerd, /var/lib/containerd, xfs,
      "defaults,noatime,nodiratime,pquota,nofail,x-systemd.device-timeout=30", "0", "2" ]

growpart:
  mode: auto
  devices: ['/']

resize_rootfs: true

# --- Packages --------------------------------------------------------------
package_update: true
package_upgrade: false          # deliberate: upgrades belong to the image build,
                                # not to instance boot; boot must be deterministic
packages:
  - qemu-guest-agent
  - chrony
  - nftables
  - jq
  - curl
  - conntrack
  - socat
  - ipvsadm

# --- Time ------------------------------------------------------------------
ntp:
  enabled: true
  ntp_client: chrony
  servers:
    - ntp1.prod.example.net
    - ntp2.prod.example.net

# --- Files -----------------------------------------------------------------
write_files:
  - path: /etc/modules-load.d/k8s.conf
    owner: root:root
    permissions: '0644'
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/99-kubernetes.conf
    owner: root:root
    permissions: '0644'
    content: |
      net.bridge.bridge-nf-call-iptables  = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward                 = 1
      net.ipv4.conf.all.rp_filter         = 0
      fs.inotify.max_user_instances       = 8192
      fs.inotify.max_user_watches         = 524288
      vm.max_map_count                    = 262144
      vm.overcommit_memory                = 1
      kernel.panic                        = 10
      kernel.panic_on_oops                = 1

  - path: /etc/systemd/network/10-dhcp.network
    owner: root:root
    permissions: '0644'
    content: |
      [Match]
      Name=en*

      [Network]
      DHCP=ipv4
      IPv6AcceptRA=no

      [DHCPv4]
      # Never derive the DHCP client-ID from /etc/machine-id: a cloned image
      # would then claim a lease already held by its sibling.
      ClientIdentifier=mac
      UseDomains=true

  - path: /etc/chrony/conf.d/ptp-kvm.conf
    owner: root:root
    permissions: '0644'
    content: |
      # Host-provided PTP clock; ~100 ns accuracy without touching the network.
      refclock PHC /dev/ptp0 poll 2 dpoll -2 offset 0 stratum 2 prefer

  - path: /etc/sysconfig/kubelet
    owner: root:root
    permissions: '0644'
    defer: true               # written in the FINAL stage, after packages exist
    content: |
      KUBELET_EXTRA_ARGS=--node-labels=topology.kubernetes.io/zone=az-a

# --- Early commands (run in the network stage, before packages) ------------
bootcmd:
  - [ cloud-init-per, once, disable-swap, sh, -c,
      'swapoff -a && sed -i "/\\sswap\\s/s/^/#/" /etc/fstab' ]

# --- Late commands (run last, in the final stage) --------------------------
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, enable, --now, chrony ]
  - [ modprobe, ptp_kvm ]
  - [ sysctl, --system ]
  - [ sh, -c, 'systemd-detect-virt > /etc/platform-type' ]
  - [ sh, -c, 'echo "provisioned $(date -Is) on $(systemd-detect-virt)" >> /var/log/provision.log' ]

# --- Console output: makes host keys verifiable from the IaaS console log ---
ssh_authkey_fingerprints: true
keys_to_console: true
ssh_fp_console_blacklist: []
ssh_key_console_blacklist: [ssh-dss]

# --- Completion signals ----------------------------------------------------
phone_home:
  url: https://provisioning.prod.example.net/api/v1/phone-home/$INSTANCE_ID
  post:
    - instance_id
    - hostname
    - fqdn
    - pub_key_ed25519
  tries: 5

final_message: |
  cloud-init v. $version finished at $timestamp.
  Datasource: $datasource. Up $uptime seconds.
  machine-id: this node is ready for kubeadm join.

power_state:
  mode: reboot
  message: Rebooting after first-boot provisioning
  timeout: 60
  condition: test -f /etc/sysctl.d/99-kubernetes.conf
```

### 9.4 `meta-data` and `network-config` for a NoCloud seed

```yaml
# meta-data — identity supplied by the "platform". For NoCloud you supply it.
# instance-id is the re-run trigger: change it and per-instance modules re-run.
instance-id: iid-k8s-worker-04-20260826
local-hostname: k8s-worker-04
```

```yaml
# network-config — cloud-init network config v2. NOTE: as a standalone
# NoCloud file it starts at "version:", with NO top-level "network:" key.
# Inside /etc/cloud/cloud.cfg.d/*.cfg it MUST be nested under "network:".
version: 2
ethernets:
  id0:
    match:
      macaddress: '52:54:00:6f:2a:11'
    set-name: eth0
    addresses:
      - 10.20.4.131/24
      - 'fd00:20:4::131/64'
    routes:
      - to: default
        via: 10.20.4.1
        metric: 100
      - to: '10.99.0.0/16'
        via: 10.20.4.254
        metric: 200
    nameservers:
      addresses: [10.20.1.10, 10.20.1.11]
      search: [prod.example.net, example.net]
    mtu: 9000
bonds: {}
vlans:
  storage:
    id: 42
    link: eth0
    addresses: [172.16.42.31/24]
    mtu: 9000
```

That nesting difference is one of the most common `cloud-init` mistakes in the field: the same YAML is valid in one place and silently ignored in the other.

The rendered result on a netplan distro:

```
$ cat /etc/netplan/50-cloud-init.yaml
# This file is generated from information provided by the datasource. Changes
# to it will not persist across an instance reboot.
network:
    version: 2
    ethernets:
        id0:
            addresses:
            - 10.20.4.131/24
            - fd00:20:4::131/64
            match:
                macaddress: 52:54:00:6f:2a:11
            mtu: 9000
            nameservers:
                addresses:
                - 10.20.1.10
                - 10.20.1.11
                search:
                - prod.example.net
                - example.net
            routes:
            -   metric: 100
                to: default
                via: 10.20.4.1
            set-name: eth0
```

### 9.5 Building the seed and booting the VM

```
$ ls -l
-rw-r--r-- 1 sre sre  4218 Aug 26 10:02 user-data
-rw-r--r-- 1 sre sre    92 Aug 26 10:02 meta-data
-rw-r--r-- 1 sre sre   712 Aug 26 10:02 network-config

# Validate before you waste a boot:
$ cloud-init schema --config-file user-data --annotate
Valid schema user-data

# Option A: cloud-localds (package: cloud-image-utils)
$ cloud-localds --network-config=network-config seed.iso user-data meta-data

# Option B: plain ISO tooling. The volume label MUST be cidata (or CIDATA).
$ genisoimage -output seed.iso -volid cidata -joliet -rock \
      user-data meta-data network-config
I: -input-charset not specified, using utf-8 (detected in locale settings)
Total translation table size: 0
Total rockridge attributes bytes: 1543
Total directory bytes: 0
Path table size(bytes): 10
Max brk space used 0
183 extents written (0 MB)

$ isoinfo -d -i seed.iso | grep -i 'volume id'
Volume id: cidata
```

```
# Provision the VM: COW disk from the golden image + the seed as a CDROM
$ qemu-img create -f qcow2 -F qcow2 -b /var/lib/libvirt/images/base-deb12-2026.08.qcow2 \
      /var/lib/libvirt/images/k8s-worker-04.qcow2 60G

$ virt-install \
    --name k8s-worker-04 \
    --memory 8192 --vcpus 4 --cpu host-passthrough \
    --disk path=/var/lib/libvirt/images/k8s-worker-04.qcow2,bus=virtio,cache=none,discard=unmap \
    --disk path=/var/lib/libvirt/images/k8s-worker-04-data.qcow2,size=200,bus=virtio,cache=none,discard=unmap \
    --disk path=seed.iso,device=cdrom,readonly=on \
    --network bridge=br-prod,model=virtio,mac=52:54:00:6f:2a:11 \
    --os-variant debian12 \
    --graphics none --console pty,target_type=serial \
    --import --noautoconsole

Starting install...
Domain creation completed.
```

### 9.6 The complete libvirt domain XML

Everything a well-configured KVM guest needs, uncut:

```xml
<domain type='kvm'>
  <name>k8s-worker-04</name>
  <uuid>c0ffee00-dead-4bee-9001-0123456789ab</uuid>
  <title>Kubernetes worker, prod, az-a</title>
  <memory unit='KiB'>8388608</memory>
  <currentMemory unit='KiB'>8388608</currentMemory>
  <vcpu placement='static'>4</vcpu>

  <os firmware='efi'>
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
    <boot dev='hd'/>
    <!-- SMBIOS identity: makes the guest self-describing to inventory tools -->
    <smbios mode='sysinfo'/>
  </os>

  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Example Platform Engineering</entry>
      <entry name='product'>k8s-worker</entry>
      <entry name='version'>base-deb12-2026.08</entry>
      <entry name='serial'>ds=nocloud-net;s=http://10.20.1.5/seed/k8s-worker-04/</entry>
      <entry name='uuid'>c0ffee00-dead-4bee-9001-0123456789ab</entry>
    </system>
  </sysinfo>

  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
    <smm state='on'/>
  </features>

  <!-- host-passthrough: best performance; forfeits migration to dissimilar CPUs -->
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='invtsc'/>
  </cpu>

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <!-- kvmclock is what makes the guest's clocksource kvm-clock -->
    <timer name='kvmclock' present='yes'/>
  </clock>

  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>

  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>

  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Root disk: virtio-blk, host page cache bypassed, TRIM passed through -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'
              discard='unmap' detect_zeroes='unmap' queues='4'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>

    <!-- Data disk for containerd -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04-data.qcow2'/>
      <target dev='vdb' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
    </disk>

    <!-- cloud-init NoCloud seed, label cidata -->
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='/var/lib/libvirt/images/k8s-worker-04-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='sata' index='0'/>
    <controller type='virtio-serial' index='0'/>

    <!-- virtio-net with vhost offload and multiqueue matching the vCPU count -->
    <interface type='bridge'>
      <mac address='52:54:00:6f:2a:11'/>
      <source bridge='br-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4' rx_queue_size='1024' tx_queue_size='1024'/>
      <mtu size='9000'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- Serial console: the only way in when the network config is wrong -->
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <!-- QEMU guest agent channel: graceful shutdown, IP reporting, fsfreeze -->
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>

    <!-- Entropy from the host: without this, first-boot key generation stalls -->
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </rng>

    <!-- Ballooning: disabled on Kubernetes nodes; the kubelet must trust MemTotal -->
    <memballoon model='none'/>

    <!-- Watchdog: reset the guest if the kernel wedges -->
    <watchdog model='i6300esb' action='reset'>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </watchdog>

    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
  </devices>
</domain>
```

Note `<entry name='serial'>ds=nocloud-net;s=http://...</entry>` — `cloud-init`'s NoCloud datasource reads the SMBIOS system serial number, so you can point a guest at an HTTP seed **without attaching any ISO at all**. The same string works as a kernel command-line parameter: `ds=nocloud-net;s=http://10.20.1.5/seed/k8s-worker-04/`.

### 9.7 Packer: building the golden image reproducibly

```hcl
# base-deb12.pkr.hcl — build a de-identified golden image.
packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "version" {
  type        = string
  description = "Image version tag, e.g. 2026.08"
}

source "qemu" "debian12" {
  iso_url          = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  iso_checksum     = "file:https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
  disk_image       = true
  disk_size        = "20G"
  format           = "qcow2"
  accelerator      = "kvm"
  cpus             = 4
  memory           = 4096
  machine_type     = "q35"
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  headless         = true
  cd_files         = ["./http/user-data", "./http/meta-data"]
  cd_label         = "cidata"
  ssh_username     = "packer"
  ssh_private_key_file = "./keys/packer_ed25519"
  ssh_timeout      = "20m"
  shutdown_command = "sudo systemctl poweroff"
  output_directory = "output/base-deb12-${var.version}"
  vm_name          = "base-deb12-${var.version}.qcow2"
}

build {
  sources = ["source.qemu.debian12"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get -y install qemu-guest-agent chrony nftables jq",
      "sudo systemctl enable qemu-guest-agent chrony",
    ]
  }

  # De-identification MUST be the last provisioner, after every package that
  # might have generated host-unique state.
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed /var/lib/NetworkManager/secret_key",
      "sudo rm -rf /var/lib/dhcp/* /var/lib/dhclient/*",
      "sudo rm -f /etc/udev/rules.d/70-persistent-net.rules",
      "sudo find /var/log -type f -exec truncate -s 0 {} +",
      "sudo rm -f /root/.bash_history /home/packer/.bash_history",
      "sudo rm -rf /home/packer/.ssh",
      "sudo fstrim -av || true",
    ]
  }

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "output/base-deb12-${var.version}.{{.ChecksumType}}"
  }
}
```

### 9.8 Provisioning systems compared

| | `cloud-init` | Ignition | Kickstart / preseed / AutoYaST | `virt-sysprep --firstboot` | Windows Sysprep |
|---|---|---|---|---|---|
| Language | YAML (+ shell, MIME multipart, Jinja) | JSON (authored as Butane YAML) | Distro-specific directive file | Shell | XML unattend |
| When it runs | Every boot, staged | **Once, in the initramfs, before the real root is mounted** | During OS installation | First boot | First boot |
| Re-runs on later boots | Yes (`per-boot` modules) | **Never** | No | No | No |
| Can it install packages? | Yes | No (by design — declarative only) | Yes | Yes | n/a |
| Idempotent | Per-instance semaphores | Trivially (runs once) | n/a | Guarded manually | n/a |
| Distros | Nearly all Linux, FreeBSD, NetBSD | Fedora CoreOS, RHCOS, Flatcar | RHEL / Debian / SUSE | Any (libguestfs) | Windows |
| Failure visibility | `cloud-init status --long` | Emergency shell in initramfs | Installer log | Journal | Setup log |
| Best for | General IaaS, mixed fleets | Immutable, container-optimized OS | Bare-metal installs | Retrofitting an image you cannot rebuild | Windows guests |

The design difference worth internalizing: **Ignition runs exactly once, before the OS is up, and cannot install packages.** That makes the resulting node bit-for-bit predictable and makes "configuration drift at boot" impossible — at the cost of forcing everything variable into the image build or into containers. `cloud-init` is the pragmatic opposite: enormously flexible, and correspondingly easy to make non-deterministic.

---

## 10. Containers as guests: what changes

### 10.1 Detection and boundaries

```
$ systemd-detect-virt --container
docker
$ cat /proc/1/cgroup
0::/
$ ls /run/.containerenv 2>/dev/null && echo "podman"
$ ls /.dockerenv 2>/dev/null && echo "docker"
/.dockerenv
docker

$ lsns
        NS TYPE   NPROCS PID USER COMMAND
4026531834 time        1   1 root /bin/bash
4026532200 mnt         1   1 root /bin/bash
4026532201 uts         1   1 root /bin/bash
4026532202 ipc         1   1 root /bin/bash
4026532203 pid         1   1 root /bin/bash
4026532205 net         1   1 root /bin/bash
4026532270 cgroup      1   1 root /bin/bash

$ capsh --print | head -2
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap=ep
Bounding set =cap_chown,cap_dac_override,...
```

Note what is *shared* with the host and therefore lies about being containerized:

```
$ uname -r
6.1.0-18-amd64            # the HOST kernel — there is no container kernel
$ nproc
64                        # all host CPUs, ignoring the cgroup quota
$ free -m | head -2
               total        used        free      shared  buff/cache   available
Mem:          257842       81204      112331        2841       64307     172408
                          # host memory, NOT the container limit

# The truth is in cgroup v2:
$ cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
2147483648
200000 100000            # 2 CPUs worth of quota
```

This is the single most common container performance bug: runtimes that size thread pools from `nproc` and heaps from `MemTotal` will over-provision by an order of magnitude and then get OOM-killed. Modern JVMs (`UseContainerSupport`, on by default), .NET and Go 1.19+ (`GOMEMLIMIT`) read the cgroup instead — older software does not.

### 10.2 `machine-id` inside containers

Because the container's `/etc/machine-id` comes from the **image**, every container from that image shares it. Container runtimes paper over this differently:

| Runtime | `/etc/machine-id` behaviour |
|---|---|
| Docker | Inherited verbatim from the image. If the image ships a valid ID, every container has it |
| Podman | Generates a unique one per container when the image has none |
| `systemd-nspawn` / `machinectl` | Generates a fresh ID per machine; can be pinned with `--uuid` |
| LXC/LXD | Template hooks clear it on clone |
| Kubernetes | Nothing; whatever the image has. Some charts bind-mount the **host's** `/etc/machine-id` for journald |

The correct image-build rule is the same as for VMs: **ship an empty or absent `/etc/machine-id`.** Concretely, in a Containerfile:

```dockerfile
FROM debian:12-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && truncate -s 0 /etc/machine-id \
 && rm -f /var/lib/dbus/machine-id \
 && ln -sf /etc/machine-id /var/lib/dbus/machine-id
```

A DaemonSet that audits the *host* machine-id uniqueness across a cluster — the Kubernetes-shaped version of the §1 incident:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: machine-id-audit
  namespace: platform-audit
  labels:
    app.kubernetes.io/name: machine-id-audit
    app.kubernetes.io/component: compliance
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: machine-id-audit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 100%
  template:
    metadata:
      labels:
        app.kubernetes.io/name: machine-id-audit
    spec:
      hostPID: false
      hostNetwork: false
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: audit
          image: registry.example.net/platform/busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              MID="$(cat /host/etc/machine-id)"
              PID="$(cat /host/sys/class/dmi/id/product_uuid 2>/dev/null || echo unavailable)"
              echo "node=${NODE_NAME} machine_id=${MID} product_uuid=${PID}"
              # Expose as a Prometheus metric on a plain TCP socket
              while true; do
                printf '# HELP node_machine_id Host machine identity as a label.\n'
                printf '# TYPE node_machine_id gauge\n'
                printf 'node_machine_id{node="%s",machine_id="%s"} 1\n' "${NODE_NAME}" "${MID}"
                sleep 300
              done
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: host-machine-id
              mountPath: /host/etc/machine-id
              readOnly: true
            - name: host-dmi
              mountPath: /host/sys/class/dmi/id
              readOnly: true
      volumes:
        - name: host-machine-id
          hostPath:
            path: /etc/machine-id
            type: File
        - name: host-dmi
          hostPath:
            path: /sys/class/dmi/id
            type: Directory
```

```
$ kubectl -n platform-audit logs -l app.kubernetes.io/name=machine-id-audit --tail=1 \
    | awk '{print $2}' | sort | uniq -c | sort -rn
      3 machine_id=5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
      1 machine_id=b71c9e04ad2f4e1c8a3d6f5b2c9e0d47
```

Any count greater than 1 is a de-identification failure in the node image.

---

## 11. Verification: the pre-publish gate

Every image build should fail closed on this check. It is free, it is fast, and it is the difference between §1 happening and not happening.

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-image-identity
# Verify a mounted image root (default /) carries NO host-unique identity.
# Exit 0 = clean and publishable; exit 1 = identity leak.
set -uo pipefail
ROOT="${1:-/}"
fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

echo "Auditing image root: ${ROOT}"

# --- 1. systemd machine ID -------------------------------------------------
mid="${ROOT%/}/etc/machine-id"
if [ ! -e "$mid" ]; then
    ok "machine-id absent (first-boot semantics will apply)"
elif [ ! -s "$mid" ]; then
    ok "machine-id present and empty (fresh ID generated at boot)"
elif [ "$(tr -d '\n' < "$mid")" = "uninitialized" ]; then
    ok "machine-id is 'uninitialized' (first-boot semantics will apply)"
else
    bad "machine-id contains a committed value: $(cat "$mid")"
fi

# --- 2. D-Bus machine ID ---------------------------------------------------
dbid="${ROOT%/}/var/lib/dbus/machine-id"
if [ -L "$dbid" ] || [ ! -e "$dbid" ] || [ ! -s "$dbid" ]; then
    ok "D-Bus machine-id is a symlink, absent or empty"
else
    bad "D-Bus machine-id is a standalone file with content: $(cat "$dbid")"
fi

# --- 3. SSH host keys ------------------------------------------------------
if compgen -G "${ROOT%/}/etc/ssh/ssh_host_*_key" > /dev/null; then
    bad "SSH host private keys present in the image:"
    ls -1 "${ROOT%/}"/etc/ssh/ssh_host_*_key | sed 's/^/          /'
else
    ok "no SSH host private keys in the image"
fi

# --- 4. cloud-init state ---------------------------------------------------
if [ -d "${ROOT%/}/var/lib/cloud/instances" ] && \
   [ -n "$(ls -A "${ROOT%/}/var/lib/cloud/instances" 2>/dev/null)" ]; then
    bad "stale cloud-init instance state (user-data will be ignored on clones)"
else
    ok "cloud-init state clean"
fi

# --- 5. Entropy and network seeds -----------------------------------------
for f in /var/lib/systemd/random-seed \
         /var/lib/urandom/random-seed \
         /var/lib/NetworkManager/secret_key \
         /etc/udev/rules.d/70-persistent-net.rules; do
    if [ -e "${ROOT%/}${f}" ]; then bad "stale unique file: ${f}"; else ok "absent: ${f}"; fi
done

# --- 6. iSCSI initiator ----------------------------------------------------
iqn="${ROOT%/}/etc/iscsi/initiatorname.iscsi"
if [ -s "$iqn" ] && ! grep -q 'GENERATE' "$iqn"; then
    bad "static iSCSI IQN: $(grep -h InitiatorName "$iqn")"
else
    ok "no static iSCSI IQN"
fi

# --- 7. Credential residue -------------------------------------------------
for f in /root/.ssh/authorized_keys /root/.bash_history /etc/krb5.keytab; do
    [ -e "${ROOT%/}${f}" ] && bad "credential residue: ${f}" || ok "absent: ${f}"
done

echo
[ "$fail" -eq 0 ] && echo "RESULT: image is de-identified and publishable." \
                  || echo "RESULT: image carries host identity — DO NOT PUBLISH."
exit "$fail"
```

Run it against an unmounted image with `guestmount`, so you never have to boot the artifact you are auditing:

```
# guestmount -a output/base-deb12-2026.08/base-deb12-2026.08.qcow2 -i --ro /mnt/img
# verify-image-identity /mnt/img
Auditing image root: /mnt/img
  PASS  machine-id present and empty (fresh ID generated at boot)
  PASS  D-Bus machine-id is a symlink, absent or empty
  PASS  no SSH host private keys in the image
  PASS  cloud-init state clean
  PASS  absent: /var/lib/systemd/random-seed
  PASS  absent: /var/lib/urandom/random-seed
  PASS  absent: /var/lib/NetworkManager/secret_key
  PASS  absent: /etc/udev/rules.d/70-persistent-net.rules
  PASS  no static iSCSI IQN
  PASS  absent: /root/.ssh/authorized_keys
  PASS  absent: /root/.bash_history
  PASS  absent: /etc/krb5.keytab

RESULT: image is de-identified and publishable.
# guestunmount /mnt/img
```

---

## 12. Failure diagnosis runbooks

### 12.1 Two VMs, one IP

**Symptom.** Intermittent connection resets; `arping -D` finds a duplicate; the DHCP server shows one lease.

```
# arping -D -I enp1s0 -c 3 10.20.4.117
ARPING 10.20.4.117 from 0.0.0.0 enp1s0
Unicast reply from 10.20.4.117 [52:54:00:6F:2A:11]  0.712ms
Unicast reply from 10.20.4.117 [52:54:00:AB:CD:EF]  0.905ms   <-- two MACs, one IP
Sent 3 probes (3 broadcast(s))
Received 2 response(s)
```

**Diagnosis.**

```
$ for h in web-01 web-02 web-03; do
>   printf '%-8s %s\n' "$h" "$(ssh $h cat /etc/machine-id)"
> done
web-01   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
web-02   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10
web-03   5a5b0d3f1f9c4a1f8e2b7c6d4e3f2a10

$ networkctl status enp1s0 | grep -i 'DHCP4 Client ID'
     DHCP4 Client ID: DUID
```

**Fix (per host, immediate).**

```
# rm -f /etc/machine-id && systemd-machine-id-setup
Initializing machine ID from random generator.
# rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
# rm -f /var/lib/dhcp/* /run/systemd/netif/leases/*
# printf '[Match]\nName=en*\n\n[Network]\nDHCP=ipv4\n\n[DHCPv4]\nClientIdentifier=mac\n' \
      > /etc/systemd/network/10-dhcp.network
# networkctl reload && networkctl reconfigure enp1s0
# systemctl restart systemd-journald   # journal path contains the machine-id
```

**Fix (permanent).** Truncate `/etc/machine-id` in the image and gate publication on §11.

### 12.2 Guest panics: `unknown-block(0,0)`

**Symptom.** After converting a physical or VMware machine to KVM, the guest never reaches userspace.

```
[    2.451236] VFS: Cannot open root device "vda2" or unknown-block(0,0): error -6
[    2.451240] Please append a correct "root=" boot option; here are the available partitions:
[    2.451245] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
[    2.451251] CPU: 0 PID: 1 Comm: swapper/0 Not tainted 6.1.0-18-amd64 #1
```

**Diagnosis.** The initramfs has no `virtio_blk`/`virtio_pci`, so the root device does not exist at pivot time. Check offline:

```
# guestmount -a disk.qcow2 -i --ro /mnt/img
# lsinitrd /mnt/img/boot/initramfs-$(uname -r).img | grep -c virtio
0
```

**Fix.** Rebuild the initramfs with the drivers forced in.

```
# RHEL family:
# dracut --force --add-drivers "virtio_blk virtio_scsi virtio_net virtio_pci virtio_ring virtio" \
      /boot/initramfs-$(uname -r).img $(uname -r)
# lsinitrd /boot/initramfs-$(uname -r).img | grep virtio | head -4
-rw-r--r--   1 root     root        20480 Aug 26 10:41 usr/lib/modules/6.1.0/kernel/drivers/block/virtio_blk.ko.xz
-rw-r--r--   1 root     root        57344 Aug 26 10:41 usr/lib/modules/6.1.0/kernel/drivers/net/virtio_net.ko.xz

# Debian family:
# printf 'virtio_pci\nvirtio_blk\nvirtio_scsi\nvirtio_net\nvirtio_ring\n' \
      >> /etc/initramfs-tools/modules
# update-initramfs -u -k all
update-initramfs: Generating /boot/initrd.img-6.1.0-18-amd64
```

For an image you cannot boot, `virt-v2v` does all of this — driver injection, bootloader fixups, device renaming — in one pass.

### 12.3 `cloud-init` did nothing

**Symptom.** Instance boots, but no users, no packages, no network config.

```
$ cloud-init status --long
status: error
extended_status: error
boot_status_code: enabled-by-generator
last_update: Tue, 26 Aug 2026 10:52:04 +0000
detail: DataSourceNone
errors:
  - 'Used fallback datasource'
recoverable_errors: {}
```

`DataSourceNone` is the tell: no datasource was found. Walk it back.

```
# 1. Did the units even run?
$ systemctl list-units --all 'cloud-*' --no-pager
  UNIT                        LOAD   ACTIVE SUB    DESCRIPTION
  cloud-config.service        loaded active exited Apply the settings specified in cloud-config
  cloud-final.service         loaded active exited Execute cloud user/final scripts
  cloud-init-local.service    loaded active exited Initial cloud-init job (pre-networking)
  cloud-init-network.service  loaded active exited Initial cloud-init job (metadata service crawler)

# 2. Which datasources were tried, and why did each fail?
$ sudo grep -E 'Datasource|DataSource|not found|failed' /var/log/cloud-init.log | tail -12
2026-08-26 10:51:31,204 - handlers.py[DEBUG]: finish: init-local/search-NoCloud: FAIL: no local data found from DataSourceNoCloud
2026-08-26 10:51:48,881 - url_helper.py[DEBUG]: Calling 'http://169.254.169.254/2009-04-04/meta-data/instance-id' failed [50/60s]: request error [HTTPConnectionPool(host='169.254.169.254', port=80): Max retries exceeded]
2026-08-26 10:52:04,110 - DataSourceEc2.py[CRITICAL]: Giving up on md from ['http://169.254.169.254/2009-04-04/meta-data/instance-id'] after 60 seconds

# 3. Is the seed device actually attached and labelled?
$ lsblk -o NAME,LABEL,FSTYPE,SIZE,MOUNTPOINT
NAME   LABEL      FSTYPE   SIZE MOUNTPOINT
sr0    cidata-x   iso9660  366K              <-- label is wrong: must be "cidata"
vda                         60G 
└─vda1 cloudimg-rootfs ext4  60G /

# 4. Is the metadata service reachable at all?
$ curl -s --connect-timeout 3 http://169.254.169.254/ || echo "IMDS unreachable"
IMDS unreachable
$ ip route get 169.254.169.254
RTNETLINK answers: Network is unreachable        <-- no link-local route
```

**Root causes, in descending order of frequency:**

| Cause | Evidence | Fix |
|---|---|---|
| Seed ISO volume label is not `cidata`/`CIDATA` | `lsblk -o LABEL` | Rebuild with `-volid cidata` |
| `/var/lib/cloud` was cloned along with the image | `/var/lib/cloud/data/instance-id` matches the old instance | `cloud-init clean --logs --seed` and reboot |
| Host firewall blocks link-local 169.254.0.0/16 | `ip route get 169.254.169.254` | Allow the route; check `nftables`/security groups |
| `datasource_list` pinned to a datasource that is not present | `/etc/cloud/cloud.cfg.d/90_*.cfg` | Correct the list |
| `cloud-init` disabled | `/etc/cloud/cloud-init.disabled` exists, or `cloud-init=disabled` on the kernel cmdline | Remove it |
| Invalid YAML in user-data | `cloud-init schema --system --annotate` | Fix and re-seed |
| AWS IMDSv2 hop limit is 1 and you are calling from a container | 401/403 from IMDS | Raise the hop limit, or use IRSA |

Validating user-data against the schema *before* boot is the highest-value habit here:

```
$ cloud-init schema --config-file user-data --annotate
Cloud config schema errors: runcmd.0: 'systemctl enable qemu-guest-agent' is not of type 'array'

user-data:
---
...
27  runcmd:
28    - systemctl enable qemu-guest-agent		# E1
...
---
# E1: runcmd.0: 'systemctl enable qemu-guest-agent' is not of type 'array'
```

And re-running provisioning cleanly on a test instance:

```
# cloud-init clean --logs --seed --machine-id
# reboot
```

`--machine-id` (cloud-init ≥ 23.2) resets `/etc/machine-id` to `uninitialized`, making the next boot a true first boot. `--configs` additionally removes rendered network configuration.

Timing analysis, when `cloud-init` works but boot is slow:

```
$ cloud-init analyze blame | head -12
-- Boot Record 01 --
     31.24500s (init-network/check-for-datasource)
     12.09100s (modules-final/config-package-update-upgrade-install)
      2.88400s (modules-config/config-apt-configure)
      0.94700s (init-network/config-growpart)
      0.51200s (init-network/config-resizefs)
      0.23100s (init-network/config-ssh)
      0.04300s (modules-final/config-runcmd)

1 boot records analyzed

$ cloud-init analyze show | head -8
-- Boot Record 01 --
The total time elapsed since completing an event is printed after the "@" character.
The time the event takes is printed after the "+" character.

Starting stage: init-local
|`->no cache found @00.24700s +00.00100s
|`->found local data from DataSourceNoCloud @00.25000s +00.51100s
Finished stage: (init-local) 00.79800s
```

31 seconds in `check-for-datasource` means the IMDS probe timed out before falling through — pin `datasource_list` to the datasource you actually have.

### 12.4 Guest clock drifts after live migration

```
$ chronyc tracking
Reference ID    : 50484330 (PHC0)
Stratum         : 2
System time     : 0.000000012 seconds fast of NTP time
Last offset     : -0.000000018 seconds
RMS offset      : 0.000000031 seconds
Frequency       : 12.045 ppm slow
Skew            : 0.004 ppm
Root delay      : 0.000000001 seconds
Root dispersion : 0.000001832 seconds
Update interval : 4.0 seconds
Leap status     : Normal
```

If `current_clocksource` is `tsc` rather than `kvm-clock`, the guest is trusting a TSC that live migration can jump. Verify the hypervisor exposes `kvmclock` (`<timer name='kvmclock' present='yes'/>` in the domain XML) and that the guest is not overriding it with `clocksource=tsc` on the kernel command line.

### 12.5 Boot with no network and no console

The universal escape hatch is the serial console. Configure it in the image before you need it:

```
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8 net.ifnames=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
```
```
# update-grub          # grub2-mkconfig -o /boot/grub2/grub.cfg on RHEL
# systemctl enable serial-getty@ttyS0.service
```
```
$ virsh console k8s-worker-04
Connected to domain 'k8s-worker-04'
Escape character is ^] (Ctrl + ])

Debian GNU/Linux 12 k8s-worker-04 ttyS0

k8s-worker-04 login:
```

The last `console=` argument wins for `/dev/console`, so put `ttyS0` last. On cloud platforms this same configuration is what makes `openstack console log show` / `aws ec2 get-console-output` produce anything at all — including the SSH host key fingerprints from §8.3.

---

## 13. Exam-focused summary

The facts LPI is likely to test, stated flatly:

- **A VM runs its own kernel; a container shares the host's.** That single sentence answers most conceptual questions in this objective.
- **`/etc/machine-id`** — 32 hex characters, set once per installation, survives reboots, must be **unique per host**. Reset with `rm /etc/machine-id && systemd-machine-id-setup`, or ship it **empty** in a template. Missing or containing `uninitialized` ⇒ systemd treats the boot as a **first boot**; empty ⇒ a new ID is generated but it is **not** a first boot.
- **`/var/lib/dbus/machine-id`** — the D-Bus machine ID; normally a symlink to `/etc/machine-id`; generated by `dbus-uuidgen`.
- **SSH host keys** live in `/etc/ssh/ssh_host_*_key` (+ `.pub`), must be deleted before templating, and are regenerated by `ssh-keygen -A`.
- **`cloud-init`** — the standard guest provisioning agent. Config file `/etc/cloud/cloud.cfg` (+ `/etc/cloud/cloud.cfg.d/`). It consumes **`meta-data`** (platform-supplied identity, includes `instance-id`) and **`user-data`** (your configuration; a `#cloud-config` YAML document, or a script starting with `#!`). It reads the metadata service at **`169.254.169.254`**. State lives in `/var/lib/cloud`. Stages: local → network → config → final.
- **Guest drivers**: `virtio_*` for KVM/QEMU; `open-vm-tools` for VMware; `hyperv-daemons` (`hv_kvp_daemon`, `hv_vss_daemon`, `hv_fcopy_daemon`) for Hyper-V; Guest Additions for VirtualBox; `qemu-guest-agent` for libvirt integration.
- **IaaS elements**: compute instance, block storage (persistent, re-attachable) vs ephemeral/instance store (dies with the instance), object storage, and virtual networking (subnets, security groups, floating IPs).
- **Detect virtualization**: `systemd-detect-virt` (exit 0 = virtualized), `virt-what`, `lscpu`, `dmidecode`, the `hypervisor` flag in `/proc/cpuinfo`.
- **Also unique per host**: hostname, SSH host keys, `machine-id`, D-Bus machine ID, iSCSI initiator name, random seeds, DHCP leases, persistent NIC udev rules.

---

## 14. References

**LPI — certification objectives**
- LPIC-1 Exam 101 objectives (version 5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPIC-1 Exam 102 objectives (version 5.0) — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPIC-1 certification overview — <https://www.lpi.org/our-certifications/lpic-1-overview/>

**systemd — machine identity and virtualization detection**
- `machine-id(5)` — <https://www.freedesktop.org/software/systemd/man/latest/machine-id.html>
- `systemd-machine-id-setup(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html>
- `systemd-detect-virt(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html>
- `systemd-firstboot(1)` and first-boot semantics — <https://www.freedesktop.org/software/systemd/man/latest/systemd-firstboot.html>
- `systemd.network(5)` (`ClientIdentifier=`, `DUIDType=`) — <https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html>
- `sd_id128_get_machine_app_specific(3)` — <https://www.freedesktop.org/software/systemd/man/latest/sd_id128_get_machine.html>
- `systemd-nspawn(1)` — <https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html>

**cloud-init**
- Documentation index — <https://cloudinit.readthedocs.io/en/latest/>
- Boot stages — <https://cloudinit.readthedocs.io/en/latest/explanation/boot.html>
- Module reference — <https://cloudinit.readthedocs.io/en/latest/reference/modules.html>
- Datasources (incl. NoCloud, ConfigDrive, EC2, OpenStack) — <https://cloudinit.readthedocs.io/en/latest/reference/datasources.html>
- NoCloud datasource — <https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html>
- User-data formats — <https://cloudinit.readthedocs.io/en/latest/explanation/format.html>
- Network configuration (v1 and v2) — <https://cloudinit.readthedocs.io/en/latest/reference/network-config.html>
- CLI reference (`status`, `clean`, `schema`, `query`, `analyze`) — <https://cloudinit.readthedocs.io/en/latest/reference/cli.html>
- Example cloud-config documents — <https://cloudinit.readthedocs.io/en/latest/reference/examples.html>

**OpenSSH**
- `ssh-keygen(1)` — <https://man.openbsd.org/ssh-keygen.1>
- `sshd_config(5)` (`HostCertificate`, `TrustedUserCAKeys`) — <https://man.openbsd.org/sshd_config.5>
- `ssh_config(5)` (`VerifyHostKeyDNS`, `UpdateHostKeys`) — <https://man.openbsd.org/ssh_config.5>
- OpenSSH certificate authentication — <https://man.openbsd.org/ssh-keygen.1#CERTIFICATES>

**Virtualization platforms and guest integration**
- Virtio specification (OASIS) — <https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html>
- Linux KVM — <https://linux-kvm.org/page/Main_Page>
- QEMU documentation — <https://www.qemu.org/docs/master/>
- QEMU guest agent — <https://qemu.readthedocs.io/en/latest/interop/qemu-ga.html>
- libvirt domain XML format — <https://libvirt.org/formatdomain.html>
- `virt-sysprep(1)` — <https://libguestfs.org/virt-sysprep.1.html>
- `virt-v2v(1)` — <https://libguestfs.org/virt-v2v.1.html>
- `virt-what(1)` — <https://people.redhat.com/~rjones/virt-what/>
- open-vm-tools — <https://github.com/vmware/open-vm-tools>
- Linux on Hyper-V (integration services) — <https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-linux-support>
- Xen Project documentation — <https://xenbits.xen.org/docs/>
- Xen PV drivers / PVHVM — <https://wiki.xenproject.org/wiki/PV_on_HVM>
- Firecracker microVM — <https://firecracker-microvm.github.io/>
- Kata Containers — <https://katacontainers.io/docs/>

**Containers**
- `namespaces(7)` — <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- `cgroups(7)` — <https://man7.org/linux/man-pages/man7/cgroups.7.html>
- Control Group v2 (kernel) — <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- OCI Image Specification — <https://github.com/opencontainers/image-spec/blob/main/spec.md>
- OCI Runtime Specification — <https://github.com/opencontainers/runtime-spec/blob/main/spec.md>
- Podman documentation — <https://docs.podman.io/en/latest/>
- LXD documentation — <https://documentation.ubuntu.com/lxd/en/latest/>

**Cloud metadata services**
- AWS instance metadata (IMDSv2) — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html>
- Google Cloud VM metadata — <https://cloud.google.com/compute/docs/metadata/overview>
- Azure Instance Metadata Service — <https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service>
- OpenStack metadata service — <https://docs.openstack.org/nova/latest/user/metadata.html>

**Image building**
- HashiCorp Packer — <https://developer.hashicorp.com/packer/docs>
- Debian official cloud images — <https://cloud.debian.org/images/cloud/>
- Ignition (Fedora CoreOS) — <https://coreos.github.io/ignition/>
- Butane configuration specification — <https://coreos.github.io/butane/>