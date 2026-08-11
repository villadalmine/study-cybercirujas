# 351.1 — Virtualization Concepts and Theory

> Exam 305-300, version 3.0 · Objective weight: 10 · Track: Virtualization

---

## 1. The production problem: why a hypervisor exists at all

A physical server is a poor unit of allocation. A dual-socket box with 128 logical CPUs, 1 TiB of RAM and NVMe measured in millions of IOPS spends most of its life idle, because the workloads mapped onto it were sized for peak, not average, and because the operator wants **fault isolation** between tenants that a single kernel cannot give. The classic pre-virtualization data center ran at 5–15% average CPU utilization while paying 100% of the power, cooling, rack and depreciation cost. That gap — capacity purchased vs. capacity used — is the economic engine of the entire field.

Virtualization is the technique of interposing a software (and, since 2005–2006, hardware-assisted) layer that multiplexes one set of physical resources into many **isolated, independently-schedulable execution environments**, each convinced it owns the machine. The architectural properties an SRE actually cares about:

| Property | What it buys you in production |
|---|---|
| **Consolidation** | Pack N guests per host; drive utilization from ~10% toward 60–80% |
| **Isolation** | A kernel panic, fork bomb or CVE in one guest does not take down its neighbors |
| **Encapsulation** | The entire machine state is a set of files → snapshot, clone, template, migrate |
| **Hardware independence** | The guest sees a stable virtual chipset; the physical host underneath can change |
| **Live migration** | Move a running workload off a host for maintenance with sub-second downtime |
| **Programmability** | The machine is now an API call; this is the precondition for IaaS and for cloud |

The three formal requirements a virtualizable architecture must satisfy were stated by **Popek and Goldberg (1974)**: *equivalence* (a program runs identically, modulo timing), *resource control* (the VMM has complete control of resources), and *efficiency* (a statistically dominant fraction of instructions execute directly on the CPU, not emulated). Their central theorem: a machine is efficiently virtualizable if every **sensitive** instruction (one that changes or depends on privileged state) is a subset of the **privileged** instructions (one that traps when executed outside ring 0). x86 famously *violated* this until VT-x/AMD-V — 17 instructions (e.g. `SGDT`, `SIDT`, `SMSW`, `POPF`) read or write privileged state without trapping in user mode. That single fact explains why early x86 virtualization needed binary translation or paravirtualization, and why the whole industry pivoted to hardware assist.

---

## 2. Taxonomy: hypervisor types and virtualization techniques

### 2.1 Type 1 vs Type 2 hypervisors (Popek/Goldberg VMM placement)

```
   TYPE 1 (bare-metal / native)              TYPE 2 (hosted)
 ┌───────┐ ┌───────┐ ┌───────┐        ┌───────┐ ┌───────┐
 │ Guest │ │ Guest │ │ Guest │        │ Guest │ │ Guest │
 └───┬───┘ └───┬───┘ └───┬───┘        └───┬───┘ └───┬───┘
     └─────────┼─────────┘                └────┬────┘
        ┌──────┴──────┐                   ┌────┴──────┐
        │  Hypervisor │                   │ Hypervisor│  (a process)
        └──────┬──────┘                   ├───────────┤
        ┌──────┴──────┐                   │  Host OS  │
        │   Hardware  │                   ├───────────┤
        └─────────────┘                   │  Hardware │
                                          └───────────┘
```

| | Type 1 (native/bare-metal) | Type 2 (hosted) |
|---|---|---|
| Runs on | Bare hardware, owns ring −1/0 | On top of a general-purpose OS |
| Examples | Xen, VMware ESXi, Microsoft Hyper-V, KVM* | VMware Workstation/Fusion, VirtualBox, QEMU (userspace only) |
| Overhead | Lower; thin scheduler | Higher; two schedulers stacked |
| Use case | Data center, cloud IaaS | Developer laptops, labs, nested testing |
| Failure domain | Hypervisor is the TCB | Host OS + hypervisor is the TCB |

**\*KVM is the classic taxonomy edge case.** `kvm.ko` is a Linux kernel module that turns the *host Linux kernel itself* into a Type 1 hypervisor — the kernel becomes the VMM and schedules VMs as ordinary processes (`vhost`/vCPU threads). Because it needs a full Linux running alongside, some texts call it Type 2. LPI-wise: **KVM converts the Linux kernel into a Type 1 hypervisor**; each guest is a QEMU process, each vCPU a thread scheduled by CFS/EEVDF like any other.

### 2.2 Virtualization techniques compared

| Technique | Guest kernel modified? | Mechanism | CPU support needed | Perf | Isolation | Canonical impl |
|---|---|---|---|---|---|---|
| **Emulation** | No | Interpret/JIT every instruction (dynamic binary translation) | None (cross-ISA OK) | Very low | Full | QEMU **TCG**, Bochs |
| **Full virtualization (BT)** | No | Trap-and-emulate + binary translation of sensitive user-mode instructions | None (pre-VT era) | Medium | Full | VMware ESX (pre-2006) |
| **Hardware-assisted full virt (HVM)** | No | CPU adds VMX root/non-root (ring −1); sensitive ops VM-exit to hypervisor | Intel **VT-x** / AMD **AMD-V (SVM)** | High | Full | KVM, Xen HVM, ESXi, Hyper-V |
| **Paravirtualization (PV)** | **Yes** | Guest replaces privileged ops with **hypercalls** to the VMM | None (that's the point) | High | Full | Xen PV, virtio drivers |
| **PVHVM / PVH** | Partial | HVM container + PV drivers (disk/net) and PV boot/IRQ | VT-x/AMD-V | Highest | Full | Xen PVH, modern Xen guests |
| **OS-level / containers** | Shared kernel | Namespaces + cgroups partition one kernel | None | Native | Weaker (shared kernel) | LXC, Docker/runc, systemd-nspawn |

Two distinctions the exam probes:

- **Emulation vs. Virtualization.** Emulation *reproduces the behavior* of hardware the host may not physically have (run ARM on x86 via QEMU TCG); it is slow because every instruction is translated. Virtualization *runs guest instructions natively on the physical CPU* and only traps the sensitive ones. QEMU can do both: `-accel tcg` (emulation) vs. `-accel kvm` (hardware virtualization). **Simulation** goes further still — it models behavior for analysis (e.g. a network simulator) without any promise of faithful execution.

- **Full virt vs. Paravirt.** Full virt gives an **unmodified** guest a complete illusion (BIOS, virtual chipset, everything) — the guest doesn't know it's virtual. Paravirt requires a **modified, virtualization-aware** guest kernel that cooperates with the hypervisor via hypercalls; it trades transparency for speed. The modern middle ground — **virtio** — keeps an unmodified HVM guest but installs paravirtualized *drivers* for the hot paths (disk, network), getting near-native I/O without a fully modified kernel.

### 2.3 The x86 ring model and where VMX inserts itself

```
Classic protection rings          With VT-x / AMD-V
┌─────────────────────┐           ┌─────────────────────┐  VMX non-root
│ Ring 3  user apps    │          │ Ring 3 user apps     │  (guest world)
│ Ring 2  (unused)     │          │ Ring 0 guest kernel  │  ← runs "as if" ring 0
│ Ring 1  (unused)     │          └──────────┬──────────┘
│ Ring 0  kernel/VMM   │              VM-exit │ VM-entry
└─────────────────────┘           ┌──────────┴──────────┐  VMX root
                                   │ Ring 0 hypervisor    │  (host world, "ring −1")
                                   └─────────────────────┘
```

Hardware assist adds a **root/non-root** orthogonal to rings. The guest kernel truly runs in ring 0 *of non-root mode*; sensitive events cause a **VM-exit** into the hypervisor (root mode), which handles them and issues **VM-entry** to resume. The per-vCPU control block is the **VMCS** (Intel) / **VMCB** (AMD). Two hardware features matter enormously for performance:

- **SLAT / nested paging** — Intel **EPT** (Extended Page Tables) / AMD **NPT/RVI** (Nested/Rapid Virtualization Indexing). Without it, the hypervisor maintains **shadow page tables** and takes a VM-exit on every guest page-table edit — brutal for fork-heavy workloads. SLAT lets the MMU walk guest-virtual → guest-physical → host-physical in hardware.
- **Tagged TLBs** — **VPID** (Intel) / **ASID** (AMD) tag TLB entries per-VM so a world switch doesn't flush the whole TLB.

---

## 3. The concrete stacks: Xen, QEMU, KVM, libvirt

### 3.1 Xen architecture

Xen is a **Type 1 microkernel-style hypervisor** that boots *before* Linux. It runs a privileged control domain, **Dom0**, which owns the physical device drivers and the toolstack; unprivileged guests are **DomU**. I/O flows through a **split driver model**: a *backend* (`netback`, `blkback`) in Dom0 talks to a *frontend* (`netfront`, `blkfront`) in the guest over **shared-memory ring buffers** and **event channels** (Xen's virtual IRQs), coordinated through the **XenStore** and **grant tables** (controlled memory sharing).

```
        ┌──────────┐   ┌──────────┐   ┌──────────┐
        │  Dom0    │   │  DomU    │   │  DomU    │
        │ (Linux)  │   │ PV/HVM   │   │ PVH      │
        │ drivers, │   │ guest    │   │ guest    │
        │ toolstack│   │          │   │          │
        └────┬─────┘   └────┬─────┘   └────┬─────┘
             └───────event channels / grant tables───────┐
        ┌──────────────────────────────────────────────┐ │
        │                 Xen Hypervisor                │◄┘
        └──────────────────────────────────────────────┘
        ┌──────────────────────────────────────────────┐
        │  CPU · RAM · NICs · storage (owned via Dom0)  │
        └──────────────────────────────────────────────┘
```

**Xen guest modes** (the historical progression):

| Mode | Boot | Privileged ops | I/O | Notes |
|---|---|---|---|---|
| **PV** | PV bootloader (pygrub/pvgrub), no BIOS | Hypercalls (modified kernel) | PV front/backend | No VT-x needed; can't run Windows; Meltdown-era security concerns |
| **HVM** | Emulated BIOS + QEMU device model | VT-x/AMD-V VM-exits | Emulated *or* PV (PVHVM) | Runs unmodified OSes incl. Windows |
| **PVHVM** | HVM container | HVM | PV drivers | HVM boot, PV I/O — common sweet spot |
| **PVH** | Lightweight PV boot, no QEMU/BIOS | HVM (hardware) | PV | Modern default: thinnest, smallest attack surface |

Toolstack CLI is **`xl`** (the old `xm`/xend is removed). `xl list`, `xl create domU.cfg`, `xl migrate`, `xl console`.

### 3.2 QEMU + KVM

**QEMU** is a userspace machine emulator and *device model*: it emulates the chipset, PCI bus, disks, NICs, VGA, etc. On its own (TCG) it's a slow emulator. **KVM** is the kernel accel: `/dev/kvm` exposes `ioctl`s (`KVM_CREATE_VM`, `KVM_CREATE_VCPU`, `KVM_RUN`) that let QEMU execute guest code natively via VT-x/AMD-V. **QEMU provides the virtual hardware; KVM provides the fast CPU/MMU virtualization.** Together: near-native compute, virtio for near-native I/O.

```
  ┌─────────────────────────────┐
  │ QEMU process (userspace)     │  device emulation, migration,
  │  ├ vCPU thread → ioctl(KVM_RUN)  live-migration dirty tracking
  │  ├ vCPU thread → ioctl(KVM_RUN)
  │  └ vhost/iothread (virtio)   │
  └──────────────┬──────────────┘
        /dev/kvm  │ ioctl
  ┌──────────────┴──────────────┐
  │ kvm.ko + kvm_intel/kvm_amd   │  VM-entry/exit, EPT/NPT, VPID
  │ (host Linux kernel = VMM)     │
  └─────────────────────────────┘
```

### 3.3 libvirt — the vendor-neutral management layer

**libvirt** is a management API, daemon (`libvirtd` / modular `virtqemud`, `virtnetworkd`, …) and toolset that abstracts *over* hypervisors (QEMU/KVM, Xen, LXC, bhyve, ESXi, Hyper-V) through **drivers** addressed by connection URI. It defines domains, networks, storage pools and secrets as **XML**, and is what tools like `virsh`, `virt-manager`, `virt-install`, Terraform, OpenStack Nova and oVirt speak to. Note the split of responsibility that trips people up: **libvirt domains are described in XML, not YAML** — YAML shows up one level up (cloud-init, Ansible, Kubernetes/KubeVirt), never in the domain definition itself.

Connection URIs (the `-c/--connect` you'll type constantly):

```
qemu:///system      # system-wide QEMU/KVM (root/privileged libvirtd)
qemu:///session     # per-user session instance
xen:///system       # Xen
lxc:///             # libvirt LXC
qemu+ssh://root@host/system   # remote over SSH — the migration transport
```

---

## 4. Complete, valid infrastructure definitions

### 4.1 A production libvirt/KVM domain (full XML, nothing trimmed)

This is a realistic HVM guest: host-passthrough CPU, virtio disk/net/rng/balloon, UEFI (OVMF) firmware, qcow2 backing, hugepages, NUMA pinning and a serial console.

```xml
<domain type='kvm'>
  <name>web-prod-01</name>
  <uuid>4f8a1c2e-9b7d-4e3a-8f21-0c9a6b5d4e3f</uuid>
  <metadata>
    <role xmlns="urn:example:tags">frontend</role>
  </metadata>
  <memory unit='GiB'>8</memory>
  <currentMemory unit='GiB'>8</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='2' unit='MiB'/>
    </hugepages>
    <locked/>
  </memoryBacking>
  <vcpu placement='static' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/web-prod-01_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='vmx'/>  <!-- expose VT-x for nested -->
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
      <source file='/var/lib/libvirt/images/web-prod-01.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <interface type='network'>
      <mac address='52:54:00:6b:3c:9a'/>
      <source network='ovs-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
</domain>
```

Define and start it:

```console
$ sudo virsh define web-prod-01.xml
Domain 'web-prod-01' defined from web-prod-01.xml

$ sudo virsh start web-prod-01
Domain 'web-prod-01' started

$ sudo virsh list --all
 Id   Name          State
------------------------------
 7    web-prod-01   running
 -    db-prod-02    shut off
```

### 4.2 cloud-init — where YAML actually lives (NoCloud datasource)

**cloud-init** is the de-facto first-boot provisioning engine for cloud images. It reads **meta-data** (identity/network) and **user-data** (config) from a *datasource* (EC2 IMDS, OpenStack, Azure IMDS, or the local **NoCloud** seed ISO used for KVM). The user-data below is a valid `#cloud-config`:

```yaml
#cloud-config
hostname: web-prod-01
fqdn: web-prod-01.prod.example.com
manage_etc_hosts: true

users:
  - name: sre
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIByT+example+key sre@bastion

package_update: true
package_upgrade: true
packages:
  - nginx
  - qemu-guest-agent
  - chrony

write_files:
  - path: /etc/nginx/conf.d/health.conf
    content: |
      server {
        listen 8080;
        location = /healthz { return 200 "ok\n"; }
      }
    permissions: '0644'

runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ systemctl, restart, nginx ]

power_state:
  mode: reboot
  condition: true
```

And the matching `meta-data`:

```yaml
instance-id: web-prod-01
local-hostname: web-prod-01
```

Build the NoCloud seed and attach it, then let cloud-init provision on first boot:

```console
$ cloud-localds seed.iso user-data meta-data
$ virt-install --name web-prod-01 --ram 8192 --vcpus 4 \
    --disk /var/lib/libvirt/images/web-prod-01.qcow2,bus=virtio \
    --disk seed.iso,device=cdrom \
    --os-variant debian12 --import --noautoconsole

$ virsh console web-prod-01
[   6.13] cloud-init[812]: Cloud-init v. 23.4.4 running 'modules:final'
[  11.02] cloud-init[812]: Cloud-init v. 23.4.4 finished at ... Up 11.0 seconds
```

### 4.3 Vagrant (libvirt provider) — reproducible dev topology

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "generic/debian12"
  config.vm.define "kvm-lab" do |node|
    node.vm.hostname = "kvm-lab"
    node.vm.provider :libvirt do |lv|
      lv.driver          = "kvm"
      lv.memory          = 4096
      lv.cpus            = 2
      lv.cpu_mode        = "host-passthrough"
      lv.nested          = true          # expose vmx/svm to the guest
      lv.machine_type    = "q35"
    end
  end
end
```

### 4.4 OVF descriptor — the portable appliance format

**OVF (Open Virtualization Format, DMTF)** is a hypervisor-neutral packaging standard. An OVF *package* is: a `.ovf` XML descriptor (virtual hardware, resource requirements), an optional `.mf` **manifest** (SHA checksums), a `.cert` (signature), and one or more disk images (`.vmdk`, `.vhd`, `.qcow2`). An **OVA** is simply that whole set bundled into a single **`tar`** archive (the `.ovf` must be the first member). Minimal, valid descriptor skeleton:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="web-prod-01-disk1.vmdk" ovf:id="file1" ovf:size="4294967296"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"/>
  </References>
  <DiskSection>
    <Info>Virtual disks</Info>
    <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="20"
          ovf:capacityAllocationUnits="byte * 2^30"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"/>
  </DiskSection>
  <VirtualSystem ovf:id="web-prod-01" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1">
    <Info>A single-VM appliance</Info>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <Item>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>4 virtual CPU(s)</rasd:ElementName>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>8192 MB of memory</rasd:ElementName>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>8192</rasd:VirtualQuantity>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
```

Package to an OVA and validate/deploy:

```console
$ tar -cf web-prod-01.ova web-prod-01.ovf web-prod-01.mf web-prod-01-disk1.vmdk
$ tar -tvf web-prod-01.ova         # .ovf MUST be first
-rw-r--r-- 0/0   2841 web-prod-01.ovf
-rw-r--r-- 0/0    140 web-prod-01.mf
-rw-r--r-- 0/0  ...   web-prod-01-disk1.vmdk

# Convert an OVA for KVM/libvirt with virt-v2v (see §6)
$ virt-v2v -i ova web-prod-01.ova -o libvirt -os default
```

---

## 5. CPU capability, nested virtualization, and host readiness

### 5.1 Is the host virtualization-capable? (`/proc/cpuinfo`, `lscpu`)

The pivotal CPU flags: **`vmx`** = Intel VT-x, **`svm`** = AMD-V. Their presence (and BIOS enablement) is the precondition for KVM/Xen HVM.

```console
$ egrep -o '(vmx|svm)' /proc/cpuinfo | sort -u
vmx

$ lscpu | grep -i virtual
Virtualization:                  VT-x
Virtualization type:             full

$ grep -E -c '(vmx|svm)' /proc/cpuinfo
16                     # nonzero → CPU supports HW virtualization on 16 logical CPUs
```

The Debian/Ubuntu convenience check:

```console
$ kvm-ok
INFO: /dev/kvm exists
KVM acceleration can be used
```

If it reports **"KVM acceleration can NOT be used"** with the flag present, virtualization is disabled in firmware — reboot into UEFI/BIOS and enable *Intel VT-x* / *AMD SVM Mode* (and IOMMU/VT-d if you want PCI passthrough).

The libvirt-native, thorough preflight:

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                     : PASS
  QEMU: Checking if device /dev/kvm exists                       : PASS
  QEMU: Checking if device /dev/kvm is accessible                : PASS
  QEMU: Checking if device /dev/vhost-net exists                 : PASS
  QEMU: Checking for cgroup 'cpu' controller support             : PASS
  QEMU: Checking for cgroup 'memory' controller support          : PASS
  QEMU: Checking for secure guest support                        : WARN (Unknown if this platform has Secure Guest support)
```

### 5.2 Nested virtualization

**Nested virtualization** runs a hypervisor *inside* a guest — the L1 guest is itself an HVM host for L2 guests. Essential for: CI that tests hypervisors/KVM, running minikube/kind with a nested KVM driver, virtualization training labs, and cloud instances that need to run their own VMs. The mechanism: the physical CPU exposes **`vmx`/`svm` to L1**, and L0 (the real hypervisor) *emulates* the VMX/SVM instructions L1 issues, shadowing L1's VMCS into a real hardware VMCS. It works but costs extra VM-exits — L2 is measurably slower than L1.

```
 L2 guest  (nested VM)
   ▲  vmx/svm emulated by L0
 L1 guest  (acts as a hypervisor; sees vmx via cpu mode=host-passthrough)
   ▲  real VT-x/AMD-V
 L0 host   (physical hypervisor, kvm_intel nested=1)
```

Enable and verify on the **L0 host** (Intel shown; AMD is `kvm_amd`):

```console
$ cat /sys/module/kvm_intel/parameters/nested
N

$ sudo modprobe -r kvm_intel        # free the module (all VMs must be off)
$ echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm.conf
$ sudo modprobe kvm_intel
$ cat /sys/module/kvm_intel/parameters/nested
Y
```

The L1 domain must forward the CPU flag (`<cpu mode='host-passthrough'/>` or explicit `<feature name='vmx'/>` as in §4.1). Then, **inside L1**:

```console
l1$ egrep -o 'vmx' /proc/cpuinfo | head -1
vmx
l1$ virt-host-validate qemu | grep 'hardware virtualization'
  QEMU: Checking for hardware virtualization                     : PASS
```

---

## 6. Migration: P2V, V2V, and live migration

### 6.1 Terminology

| Term | Meaning | Tooling |
|---|---|---|
| **P2V** | Physical-to-Virtual: convert a running/imaged bare-metal box into a VM image | `virt-p2v` (boots a helper ISO on the physical host), VMware vCenter Converter |
| **V2V** | Virtual-to-Virtual: convert a VM between hypervisor formats (VMDK↔qcow2, VMX/OVA→libvirt) | `virt-v2v` |
| **Cold (offline) migration** | Move a *powered-off* VM's files to another host | `scp`/`rsync` + `virsh define`, `virsh migrate --offline` |
| **Live (online) migration** | Move a *running* VM between hosts with negligible downtime | `virsh migrate --live`, `xl migrate`, vMotion |
| **Storage migration** | Move the VM's disks (with or without the running state) | `virsh migrate --copy-storage-all`, `blockcopy` |

### 6.2 P2V / V2V in practice

```console
# V2V: import a VMware OVA into KVM/libvirt, converting VMDK→qcow2 and
# injecting virtio drivers so the guest boots on the new virtual hardware.
$ virt-v2v -i ova legacy-app.ova -o libvirt -os default -of qcow2
[   0.0] Setting up the source: -i ova legacy-app.ova
[   2.4] Opening the source
[  15.1] Inspecting the source
[  27.8] Converting Debian GNU/Linux to run on KVM
        virt-v2v: This guest has virtio drivers installed.
[ 148.6] Copying disk 1/1
[ 401.2] Creating output metadata
[ 402.0] Finished output to libvirt
```

The critical, non-obvious P2V/V2V failure mode: the guest was tied to *emulated* hardware (IDE disk, e1000 NIC) and its kernel lacks virtio drivers or its `/etc/fstab`/GRUB references old device names → **boots to an initramfs shell or `dracut` timeout**. `virt-v2v` injects drivers and rewrites configs precisely to prevent this; a hand-rolled `qemu-img convert` does not.

Format conversion by hand:

```console
$ qemu-img convert -p -O qcow2 legacy-app-disk1.vmdk legacy-app.qcow2
    (100.00/100%)
$ qemu-img info legacy-app.qcow2
image: legacy-app.qcow2
file format: qcow2
virtual size: 40 GiB (42949672960 bytes)
disk size: 12.3 GiB
cluster_size: 65536
```

### 6.3 Live migration — the mechanics

Live migration works by iteratively copying memory while the guest keeps running (**pre-copy**), tracking pages the guest dirties, re-sending them each round until the remaining dirty set is small enough to transfer during a brief **stop-and-copy** pause (typically < 300 ms). The alternative, **post-copy**, transfers minimal state, resumes the VM on the destination immediately, and demand-pages the rest over the network (faster convergence, but a network failure mid-migration can lose the VM).

| | Pre-copy (default) | Post-copy |
|---|---|---|
| VM runs on | Source until final switch | Destination almost immediately |
| Convergence risk | May not converge if guest dirties memory faster than link bandwidth | Always converges |
| Failure impact | Source still intact → safe to abort | Destination network fail → VM lost |
| Mitigations | `auto-converge` (throttle vCPU), post-copy fallback | Combine with pre-copy warm-up |

Prerequisites the exam expects you to state: (1) **shared or replicated storage** (NFS/iSCSI/Ceph) *or* `--copy-storage-all` to also move disks; (2) **CPU compatibility** between hosts (identical or a common baseline model — this is why `host-model` is safer than `host-passthrough` across heterogeneous hosts); (3) matching machine types and reachable libvirt transport.

```console
# Live-migrate a running domain to another KVM host over SSH, keeping it
# defined persistently on the destination.
$ virsh migrate --live --verbose --persistent --undefinesource \
      web-prod-01 qemu+ssh://root@host-b/system
Migration: [100 %]

# For hosts WITHOUT shared storage, also stream the disks:
$ virsh migrate --live --copy-storage-all --verbose \
      web-prod-01 qemu+ssh://root@host-b/system

# Throttle the guest if it dirties memory too fast to converge:
$ virsh migrate-setmaxdowntime web-prod-01 500     # ms
$ virsh migrate --live --auto-converge web-prod-01 qemu+ssh://root@host-b/system
```

Xen equivalent:

```console
$ xl migrate web-prod-01 host-b
Migration successful.
```

---

## 7. Cloud service models and the container tier

Virtualization is the substrate; the cloud is the business model layered on top. The **XaaS** ladder classifies who manages what:

| Model | You manage | Provider manages | Unit delivered | Example |
|---|---|---|---|---|
| **IaaS** | OS, runtime, app, data | Virtualization, servers, storage, network | Virtual machines, block storage, virtual networks | EC2, OpenStack Nova, GCP Compute Engine |
| **PaaS** | App, data | Runtime, OS, and all infra | Deploy-your-code platform | Heroku, App Engine, Cloud Foundry |
| **SaaS** | Configuration/data only | Everything | Finished application | Gmail, Salesforce, Microsoft 365 |
| **CaaS** | Containers, images | Orchestration, nodes, infra | Container runtime/orchestration | GKE, EKS, AKS, OpenShift |

```
 more control ◄─────────────────────────────────────► less to manage
 IaaS ───────────► CaaS ───────────► PaaS ───────────► SaaS
 (you run the OS)  (you ship images) (you push code)   (you just use it)
```

**Container / OS-level virtualization** (LXC, Docker/runc, `systemd-nspawn`) is the technique underneath CaaS: instead of virtualizing hardware, it partitions a **single shared kernel** using **namespaces** (pid, net, mnt, uts, ipc, user, cgroup — isolate *what a process sees*) and **cgroups** (limit *what it can use*: CPU, memory, IO, pids). The trade-off versus VMs is stark and worth stating precisely:

| | VM (hardware virtualization) | Container (OS-level) |
|---|---|---|
| Kernel | One per guest | Shared host kernel |
| Isolation boundary | Hardware/VMX — strong | Kernel namespaces — weaker (kernel is shared attack surface) |
| Boot / start time | Seconds (full OS boot) | Milliseconds |
| Density | Tens per host | Hundreds–thousands per host |
| Guest OS diversity | Any OS (Windows on Linux host) | Same-kernel only (Linux on Linux) |
| Overhead | Memory + CPU per guest OS | Near-native |
| Live migration | Mature (vMotion, `virsh migrate`) | Immature (CRIU checkpoint/restore) |

The convergence point the exam nods to is **KubeVirt** — running full VMs *as* Kubernetes pods — and **Kata Containers / Firecracker microVMs**, which wrap each container in a stripped-down VM to regain hardware-grade isolation at container-like startup cost. That's the reconciliation of the two columns above.

---

## 8. Verification and failure-diagnosis playbook

### 8.1 Confirm what is actually running (paravirt vs. HVM vs. bare metal)

```console
# Am I inside a VM, and which hypervisor? (systemd)
$ systemd-detect-virt
kvm

# Broader detector
$ virt-what
kvm

# The CPU tells you too: hypervisor flag present ⇒ virtualized
$ grep -o hypervisor /proc/cpuinfo | head -1
hypervisor

$ lscpu | grep -E 'Hypervisor|Virtualization'
Hypervisor vendor:               KVM
Virtualization type:             full
```

### 8.2 Structured triage table

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| `virsh start` → *"KVM: Permission denied"* / *"failed to initialize KVM: Device or resource busy"* | Another hypervisor holds `/dev/kvm` (e.g. VirtualBox), or user not in `kvm`/`libvirt` group | `lsof /dev/kvm`; `ls -l /dev/kvm`; `groups` | Stop the other VMM; `usermod -aG libvirt,kvm $USER` |
| VM created but *dog-slow*, `qemu` at 100% CPU on one thread | Falling back to **TCG emulation**, not KVM | `virsh dumpxml NAME \| grep '<domain type'` shows `type='qemu'` not `'kvm'` | Enable VT-x/AMD-V in firmware; `domain type='kvm'`; check `virt-host-validate` |
| Nested guest (L2) won't get hardware virt | L0 `nested=0` or L1 CPU doesn't expose `vmx/svm` | `cat /sys/module/kvm_intel/parameters/nested`; `grep vmx /proc/cpuinfo` in L1 | Set `nested=1`; use `cpu mode='host-passthrough'` on L1 |
| Live migration aborts: *"Unsafe migration: Migration without shared storage is unsafe"* | Disks are local, not on shared storage | `virsh domblklist NAME` | Add `--copy-storage-all`, or place disks on NFS/Ceph |
| Live migration: *"unable to find any master var store for loader"* or CPU feature error | Destination lacks matching OVMF/nvram or CPU model | Compare `virsh capabilities` / CPU on both hosts | Use `cpu mode='host-model'`; install matching OVMF |
| Migration *never converges*, stuck at 99% | Guest dirties memory faster than link bandwidth | `virsh domjobinfo NAME` shows growing "Memory remaining" | `--auto-converge`, raise max downtime, or switch to post-copy |
| Post-V2V guest boots to `dracut`/initramfs shell | Missing virtio drivers, stale `fstab`/GRUB device names | Boot rescue; inspect `/etc/fstab`, initramfs modules | Re-run with `virt-v2v` (injects drivers), rebuild initramfs |
| `virt-host-validate` → IOMMU checks WARN, PCI passthrough fails | VT-d/AMD-Vi disabled or `intel_iommu=on` missing | `dmesg \| grep -i -e DMAR -e IOMMU` | Enable IOMMU in BIOS; add `intel_iommu=on iommu=pt` to kernel cmdline |

### 8.3 Live-inspecting a running domain

```console
$ virsh dominfo web-prod-01
Id:             7
Name:           web-prod-01
UUID:           4f8a1c2e-9b7d-4e3a-8f21-0c9a6b5d4e3f
OS Type:        hvm
State:          running
CPU(s):         4
CPU time:       182.3s
Max memory:     8388608 KiB
Used memory:    8388608 KiB
Persistent:     yes
Autostart:      disable
Managed save:   no

$ virsh domblklist web-prod-01
 Target   Source
--------------------------------------------------
 vda      /var/lib/libvirt/images/web-prod-01.qcow2

$ virsh domjobinfo web-prod-01           # during migration
Job type:         Unbounded
Operation:        Outgoing migration
Data processed:   3.412 GiB
Data remaining:   248.512 MiB
Memory processed: 3.402 GiB
Memory remaining: 248.512 MiB
Dirty rate:       12894 pages/s

# Verify the domain is truly KVM-accelerated, not emulated:
$ virsh dumpxml web-prod-01 | head -1
<domain type='kvm' id='7'>
```

### 8.4 Verify the offered virtual CPU and confirm nested capability end-to-end

```console
# What CPU models can this host offer guests?
$ virsh cpu-models x86_64 | head
Skylake-Client-IBRS
Cascadelake-Server
EPYC-Rome
host-passthrough

# Inside the L1 guest, prove nesting works by launching a throwaway L2:
l1$ qemu-system-x86_64 -accel kvm -m 512 -nographic -kernel /boot/vmlinuz-$(uname -r) \
      -append "console=ttyS0" 2>&1 | head -2
    # If this starts under KVM (not "KVM not supported"), nesting is live.
```

---

## 9. Key terms — quick reference

- **Hypervisor / VMM** — the layer that creates and runs VMs; Type 1 (bare-metal) or Type 2 (hosted).
- **HVM** — Hardware Virtual Machine; full virtualization accelerated by VT-x/AMD-V, unmodified guest.
- **PV / Paravirtualization** — modified, virtualization-aware guest using hypercalls; no HW assist required.
- **PVH / PVHVM** — hybrid Xen modes combining HVM containers with PV drivers/boot for a minimal surface.
- **Emulation vs. Virtualization** — emulation translates instructions (cross-ISA, slow, QEMU TCG); virtualization runs them natively and traps only the sensitive ones.
- **SLAT** — Second-Level Address Translation: Intel **EPT** / AMD **NPT/RVI**; hardware two-stage paging.
- **VMCS / VMCB** — per-vCPU control structures for VT-x / AMD-V.
- **Dom0 / DomU** — Xen's privileged control domain / unprivileged guest.
- **virtio** — paravirtualized device interface (net/blk/scsi/rng/balloon) for near-native I/O in HVM guests.
- **libvirt / virsh** — vendor-neutral virtualization management API/daemon and its CLI; **domains are XML**.
- **OVF / OVA** — DMTF portable appliance format (`.ovf` XML + disks + `.mf` manifest); OVA = that set as a single `tar`.
- **cloud-init** — first-boot provisioning from a datasource; `#cloud-config` **user-data** is YAML.
- **P2V / V2V** — physical-to-virtual / virtual-to-virtual conversion (`virt-p2v`, `virt-v2v`).
- **Live migration** — moving a running VM between hosts; **pre-copy** (iterative dirty-page) vs. **post-copy** (demand paging).
- **Nested virtualization** — running a hypervisor inside a guest (`kvm_intel nested=1`).
- **IaaS / PaaS / SaaS / CaaS** — cloud service models by division of management responsibility.

---

## 10. References

- LPI — Exam 305-300 Objectives (LPIC-3 Virtualization and Containerization): https://www.lpi.org/our-certifications/exam-305-objectives/
- Popek, G. J.; Goldberg, R. P. — "Formal Requirements for Virtualizable Third Generation Architectures" (CACM, 1974): https://dl.acm.org/doi/10.1145/361011.361073
- Xen Project — Understanding the Virtualization Spectrum (PV, HVM, PVH): https://wiki.xenproject.org/wiki/Understanding_the_Virtualization_Spectrum
- Xen Project — `xl` toolstack documentation: https://xenbits.xen.org/docs/unstable/man/xl.1.html
- Linux KVM — main site and API documentation: https://linux-kvm.org/page/Main_Page
- Linux kernel — KVM `Documentation/virt/kvm/api`: https://www.kernel.org/doc/html/latest/virt/kvm/api.html
- Linux kernel — Nested VMX: https://www.kernel.org/doc/html/latest/virt/kvm/x86/nested-vmx.html
- QEMU — System Emulation documentation: https://www.qemu.org/docs/master/system/
- libvirt — Domain XML format reference: https://libvirt.org/formatdomain.html
- libvirt — Connection URIs / remote & migration: https://libvirt.org/uri.html and https://libvirt.org/migration.html
- libvirt — `virsh` manual: https://libvirt.org/manpages/virsh.html
- Intel — 64 and IA-32 Architectures Software Developer's Manual, Vol. 3C (VMX): https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
- AMD64 Architecture Programmer's Manual, Vol. 2 (Secure Virtual Machine, SVM): https://www.amd.com/en/support/tech-docs/amd64-architecture-programmers-manual-volumes-1-5
- DMTF — Open Virtualization Format (OVF) Specification (DSP0243): https://www.dmtf.org/standards/ovf
- cloud-init — official documentation: https://cloudinit.readthedocs.io/en/latest/
- libguestfs — `virt-v2v` and `virt-p2v` manuals: https://libguestfs.org/virt-v2v.1.html and https://libguestfs.org/virt-p2v.1.html
- NIST SP 800-145 — The NIST Definition of Cloud Computing (IaaS/PaaS/SaaS): https://csrc.nist.gov/publications/detail/sp/800-145/final