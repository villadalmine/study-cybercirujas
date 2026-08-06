# LPIC-3 305 (Exam 305-300) - Topic 1.1: Full Virtualization

---

## 1. Production Architecture Motivation & Core Mechanics

### 1.1 The Bare-Metal Underutilization & Isolation Problem
In production enterprise architectures, running single workloads directly on physical hardware introduces three key operational vulnerabilities:
1. **Low Compute Efficiency**: Workloads rarely utilize $100\%$ of CPU, RAM, and I/O capacity simultaneously, leading to severe resource underutilization ($10\% - 15\%$ average CPU utilization on bare metal).
2. **Hard Multi-Tenancy Failure**: Modern operating systems share a single kernel space across user processes. A kernel panic triggered by a single process halts the entire bare-metal host.
3. **Hardware Coupling & Migration Inflexibility**: Applications bound to physical hardware require specific driver stacks, preventing seamless live relocation between heterogeneous physical hardware nodes.

Full virtualization solves these challenges by interposing a **Virtual Machine Monitor (VMM)** / Hypervisor between hardware and un-modified Guest Operating Systems, creating strict isolation boundaries enforced at the CPU hardware level.

```
+-----------------------------------------------------------------------+
|                         GUEST OS (Unmodified)                         |
|   +--------------------------+     +-------------------------------+  |
|   |   User Space Processes   |     |   Guest Kernel (Ring 0/1)     |  |
|   +--------------------------+     +-------------------------------+  |
+-----------------------------------------------------------------------+
                                  |
                   Hardware Emulation & Hypercalls
                                  v
+-----------------------------------------------------------------------+
|                           QEMU (Userspace)                            |
|        [Device Emulation | VirtIO Backends | QMP API | Storage]        |
+-----------------------------------------------------------------------+
                                  |  ioctl(/dev/kvm)
                                  v
+-----------------------------------------------------------------------+
|                    KVM Kernel Module (kvm.ko)                         |
|     [VCPU Execution Loop | EPT/NPT Paging | Interrupt Controller]     |
+-----------------------------------------------------------------------+
                                  |  Hardware Virtualization Extensions
                                  v
+-----------------------------------------------------------------------+
|                       PHYSICAL HARDWARE (Host)                        |
|        [Intel VT-x / AMD-V CPU | Hardware EPT | IOMMU VT-d]           |
+-----------------------------------------------------------------------+
```

---

### 1.2 CPU Hardware-Assisted Virtualization Mechanics
Modern x86_64 Full Virtualization relies on hardware extensions: **Intel VT-x** (Virtualization Technology) and **AMD-V**.

#### VMX Privileged Execution Modes
Intel VT-x introduces two operating modes to the CPU execution ring model:
* **VMX Root Operation**: Fully privileged mode used by the Host Kernel / Hypervisor (KVM). The host has unrestricted access to hardware instructions and physical memory.
* **VMX Non-Root Operation**: Restricted privilege mode where Guest OS instances execute. Privileged instructions issued by the Guest Kernel trigger a **VM-Exit**, suspending guest execution and yielding control back to the Host Hypervisor in VMX Root mode.

```
       +-------------------------------------------------------+
       |                  VMX Root Operation                   |
       |                (Host Kernel / KVM)                    |
       +-------------------------------------------------------+
                                |             ^
                       VMXON /  |             |  VM-Exit
                      VMLAUNCH  |             |  (Page Fault, IO,
                                v             |   Hypercall)
       +-------------------------------------------------------+
       |                VMX Non-Root Operation                 |
       |                 (Guest OS Execution)                  |
       +-------------------------------------------------------+
```

#### The KVM VCPU Loop Mechanics
When a guest virtual CPU (vCPU) runs, KVM executes a low-overhead hardware loop via the `ioctl(vcpu_fd, KVM_RUN, ...)` system call issued by QEMU:

1. **Initialization (`VMLAUNCH` / `VMRESUME`)**: The Host Kernel writes initial context (registers, control registers, execution pointers) into the **VMCS (Virtual Machine Control Structure)** in physical memory and issues `VMRESUME`.
2. **Guest Execution**: The CPU enters **VMX Non-Root mode** and natively executes guest instructions at hardware speed without software binary translation.
3. **Trap / VM-Exit**: When the Guest OS performs an instruction requiring hypervisor intervention (e.g., accessing CR3 register, executing `IN`/`OUT` assembly instructions, MMIO reads/writes, or triggering an EPT Violation), the hardware traps the instruction and forces a **VM-Exit**.
4. **Exit Handling**:
   * **In-Kernel Handling**: If the exit can be handled directly by `kvm.ko` (e.g., LAPIC timer interrupt, EPT page allocation), KVM handles it in ring 0 and immediately issues `VMRESUME`.
   * **Userspace Exit**: If the exit requires complex device emulation (e.g., emulated legacy IDE controller or PCI device access), `ioctl(KVM_RUN)` returns to QEMU userspace. QEMU processes the I/O operation and re-invokes `ioctl(KVM_RUN)`.

---

### 1.3 Memory Virtualization: EPT / NPT vs. Shadow Page Tables
In full virtualization, there are two levels of address translation:
$$\text{Guest Virtual Address (GVA)} \longrightarrow \text{Guest Physical Address (GPA)} \longrightarrow \text{Host Physical Address (HPA)}$$

```
+-------------------+       +-------------------+       +-------------------+
| Guest VA (GVA)    | ----> | Guest PA (GPA)    | ----> | Host PA (HPA)     |
+-------------------+       +-------------------+       +-------------------+
  (Managed by Guest OS         (Emulated RAM         (Actual Physical 
   Page Tables)                 Address Space)        DRAM Modules)
```

#### Legacy Shadow Page Tables (Software Emulation)
* The hypervisor maintains a single mapping table directly linking GVA to HPA.
* **Overhead**: Any modification to the Guest Page Table by the Guest OS must be write-protected. Every page table modification causes a VM-Exit, introducing massive CPU latency ($30\% - 400\%$ performance penalty during heavy memory allocation).

#### Hardware-Assisted Paging (Intel EPT / AMD NPT)
* The CPU Memory Management Unit (MMU) maintains a secondary hardware translation table: **Extended Page Tables (EPT)** on Intel or **Nested Page Tables (NPT)** on AMD.
* The hardware MMU translates GVA to GPA via Guest CR3, then automatically walks the hardware EPT to translate GPA to HPA.
* **EPT Violation**: If a GPA is not mapped in the host EPT table, an EPT Violation VM-Exit occurs. `kvm.ko` allocates host physical memory, updates the EPT entry, and resumes guest execution seamlessly.

---

### 1.4 Device I/O Virtualization Strategies

```
+-----------------------------------------------------------------------------------+
|                               I/O VIRTUALIZATION MODES                            |
+-----------------------+----------------------------------+------------------------+
| 1. Full Emulation     | 2. Paravirtualized (VirtIO)      | 3. Direct Pass-through |
| (e.g., Intel e1000)   | (vring / virtqueue / vhost-net)  | (VFIO / SR-IOV)        |
+-----------------------+----------------------------------+------------------------+
| High VM-Exit overhead | Shared memory ring buffer        | Zero hypervisor exit   |
| Traps every register  | Minimal traps via doorbell/irq   | Near bare-metal speed  |
| Full compatibility    | Requires virtio guest drivers    | Requires dedicated HW  |
+-----------------------+----------------------------------+------------------------+
```

1. **Full Emulation (e.g., e1000, IDE, Cirrus Logic)**:
   QEMU intercepts every register access via MMIO/PIO exit traps. High CPU overhead due to thousands of VM-Exits per second during network or storage bursts.
2. **Paravirtualization (`VirtIO`)**:
   Guest OS uses specialized VirtIO drivers. Standardized memory structures (**Virtqueues** and **Available/Used Vrings**) allow direct shared-memory communication between Guest RAM and Host Kernel/QEMU, reducing VM-Exits by orders of magnitude.
   * `vhost-net`: Shifts virtio network packet processing out of QEMU userspace directly into a host kernel worker thread (`vhost-<pid>`), eliminating userspace context switches.
3. **Direct Hardware Pass-through (VFIO / SR-IOV)**:
   Peripherals (e.g., PCIe NICs, NVMe SSDs, GPUs) are directly mapped into the Guest address space using **Intel VT-d** or **AMD-Vi** IOMMU (Input-Output Memory Management Unit). The Guest OS communicates directly with hardware registers without Hypervisor interception.

---

## 2. Deep Technical Comparative & Trade-Off Matrix

### 2.1 Virtualization Paradigms Comparison

| Metric / Feature | Hardware-Assisted Full Virtualization (KVM/QEMU) | Paravirtualization (Xen PV) | OS-Level Virtualization (Containers / LXC / cgroups) |
| :--- | :--- | :--- | :--- |
| **Hypervisor / Engine Type** | Type-1 (via KVM kernel module) | Type-1 (Xen Hypervisor Hypercall interface) | N/A (Shared Host Kernel + namespaces/cgroups) |
| **Guest OS Modification** | None (Runs Windows, BSD, proprietary kernels unmodified) | Required (Guest kernel patched for hypercalls) | Cannot run distinct OS kernels (Linux guests only on Linux host) |
| **CPU Privilege Model** | VMX Root (Host) vs VMX Non-Root (Guest) | Ring 0 (Xen), Ring 1 (Guest Kernel), Ring 3 (Apps) | Shared Ring 0 (Host Kernel), Ring 3 (Container Apps) |
| **CPU Performance Overhead** | $< 2\%$ (Hardware accelerated via VT-x / AMD-V) | $< 3\%$ | $0\%$ (Direct native execution) |
| **Memory Isolation & Safety** | Absolute (Hardware EPT boundaries, isolated RAM pools) | High (Hypervisor hypercall interface boundaries) | Weak / Moderate (Software kernel namespace boundaries) |
| **I/O Latency (VirtIO / SR-IOV)**| Near Native ($< 5\%$ overhead with SR-IOV / `vhost`) | Near Native | Native direct kernel throughput |
| **Startup / Boot Latency** | Seconds to Minutes (Full POST/UEFI & OS initialization) | Seconds | Milliseconds (Process fork + namespace attachment) |
| **Live Migration Support** | Full support (Dirty memory tracking via EPT bit) | Full support | Limited / Complex (CRIU process checkpointing) |
| **Security Footprint** | Extremely high security boundary (Hardware enforced) | High security boundary | Higher attack surface (Shared Host Kernel vulnerabilities) |

---

### 2.2 Storage Backing Formats & Cache Modes Matrix

#### Storage Backing Formats

| Format | Disk Space Allocation | Snapshot Capability | Read Performance | Write Performance | Enterprise Production Recommendation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`raw`** | Pre-allocated (flat binary image) | External / LVM level only | Maximum (Direct LBA block offset mapping) | Maximum | High-performance DB workloads (SAN/NVMe backends) |
| **`qcow2` (v3)** | Sparse / Dynamic expansion | Native Copy-on-Write (Internal & External) | High (Minor lookup table overhead) | High (with `preallocation=metadata`) | Standard enterprise VMs, Cloud Image Templates |
| **Block / LVM** | Pre-allocated dedicated block device | LVM / SAN storage array snapshot | Native Bare-Metal Speed | Native Bare-Metal Speed | Mission-Critical IOPS-bound applications |

#### QEMU Cache Modes

| Cache Mode | Host Page Cache | Guest Cache | Flush/Sync Handling (`fsync`) | Data Safety on Host Crash | Recommended Use Case |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`none`** | **Disabled** (`O_DIRECT`) | Enabled (Writeback) | Passed directly to physical disk | **Safe** (Guaranteed on physical storage write) | **Production Enterprise Standard** (SAN/Ceph/Direct NVMe) |
| **`writeback`** | **Enabled** | Enabled (Writeback) | Deferred until guest requests explicit sync | Risk of data loss during host kernel panic | General purpose non-critical workloads |
| **`writethrough`** | **Enabled** | **Disabled** | Host flushes every write to disk before returning | **Safe** | Legacy applications lacking proper `fsync` logic |
| **`directsync`** | **Disabled** (`O_DIRECT`) | **Disabled** | Direct synchronous write to host storage | **Safe** | High-reliability logs, non-cached sequential writes |
| **`unsafe`** | **Enabled** | Enabled | Ignores guest flush requests entirely | **Catastrophic** (Guaranteed corruption on host crash) | Build nodes, temporary ephemeral testing |

---

### 2.3 Network Architecture Trade-Off Matrix

| Architecture | Setup Complexity | Host CPU Utilization | Inter-VM Switching Speed | SR-IOV Hardware Dependency | Live Migration Compatibility |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Linux Bridge + `virtio-net`** | Low | Moderate | High (Software bridge switching) | No | **Seamless** |
| **Linux Bridge + `vhost-net`** | Low | **Low** (Kernel in-place vring processing) | Very High | No | **Seamless** |
| **Macvtap (Bridge/VEPA)** | Low | Low | High (Bypasses host bridge, direct NIC bridge) | No | Restricts Host-to-Guest communication on same NIC |
| **Open vSwitch (OVS) + DPDK** | High | Low (Poll Mode Drivers) | Extremely High (10G/40G/100G wire speed) | No | Supported with OVS configuration parity |
| **VFIO PCIe Passthrough / SR-IOV** | High | **Near Zero** | Physical Switch / NIC HW Wire Speed | **Yes** (Intel/Mellanox SR-IOV NIC required) | Requires complex bond failover setup |

---

## 3. Complete Production-Ready Manifestos & Infrastructure Specs

### 3.1 Enterprise Production Domain XML (`/etc/libvirt/qemu/prod-app-vm01.xml`)
This domain XML manifest implements NUMA node pinning, vCPU affinity, 1GiB Hugepages backing, `virtio-scsi` with multi-queue support, `vhost-net` networking, and QEMU guest agent integration.

```xml
<domain type='kvm'>
  <name>prod-app-vm01</name>
  <uuid>c7a5a8e2-893d-4c31-b6d8-912f2c8d76e4</uuid>
  <metadata>
    <app:metadata xmlns:app="https://schemas.enterprise.io/libvirt/app/1.0">
      <app:environment>production</app:environment>
      <app:owner>sre-platform-team</app:owner>
    </app:metadata>
  </metadata>
  <memory unit='GiB'>16</memory>
  <currentMemory unit='GiB'>16</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='1048576' unit='KiB' nodeset='0'/>
    </hugepages>
    <nosharepages/>
    <locked/>
  </memoryBacking>
  <vcpu placement='static'>8</vcpu>
  <iothreads>2</iothreads>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
    <vcpupin vcpu='4' cpuset='6'/>
    <vcpupin vcpu='5' cpuset='7'/>
    <vcpupin vcpu='6' cpuset='8'/>
    <vcpupin vcpu='7' cpuset='9'/>
    <iothreadpin iothread='1' cpuset='0'/>
    <iothreadpin iothread='2' cpuset='1'/>
    <emulatorpin cpuset='0-1'/>
  </cputune>
  <numatune>
    <memory mode='strict' nodeset='0'/>
  </numatune>
  <sysinfo type='smbios'>
    <system>
      <entry name='manufacturer'>Enterprise SRE Cloud</entry>
      <entry name='product'>Virtual Production Node</entry>
    </system>
  </sysinfo>
  <os>
    <type arch='x86_64' machine='pc-q35-8.1'>hvm</type>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='8' threads='1'/>
    <cache mode='passthrough'/>
    <feature policy='require' name='topoext'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='kvmclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>

    <!-- Storage Controller: VirtIO SCSI with IOThread -->
    <controller type='scsi' index='0' model='virtio-scsi'>
      <driver queues='8' iothread='1'/>
      <address type='pci' domain='0x0000' bus='0x03' slot='0x00' function='0x0'/>
    </controller>

    <!-- Operating System Disk: Raw or QCow2 using VirtIO SCSI -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap' error_policy='stop'/>
      <source file='/var/lib/libvirt/images/prod-app-vm01-root.qcow2'/>
      <target dev='sda' bus='scsi'/>
      <address type='drive' controller='0' bus='0' target='0' unit='0'/>
    </disk>

    <!-- Network Interface: VirtIO with vhost-net multi-queue -->
    <interface type='bridge'>
      <mac address='52:54:00:1a:3b:4c'/>
      <source bridge='br0'/>
      <target dev='vnet0'/>
      <model type='virtio'/>
      <driver name='vhost' queues='8' rx_queue_size='1024' tx_queue_size='1024'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- QEMU Guest Agent Channel -->
    <channel type='unix'>
      <source mode='bind' path='/var/lib/libvirt/qemu/channel/target/domain-prod-app-vm01/org.qemu.guest_agent.0'/>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
      <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
    </channel>

    <!-- Serial Console for Headless Management -->
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <memballoon model='virtio'>
      <stats period='10'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </memballoon>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
```

---

### 3.2 Enterprise Libvirt Storage Pool & Network Pool XMLs

#### Storage Pool XML (`/etc/libvirt/storage/production-pool.xml`)
```xml
<pool type='dir'>
  <name>production-pool</name>
  <uuid>a8e2b1c4-3d91-4e78-bc02-123456789abc</uuid>
  <capacity unit='GiB'>2000</capacity>
  <allocation unit='GiB'>450</allocation>
  <available unit='GiB'>1550</available>
  <source>
  </source>
  <target>
    <path>/var/lib/libvirt/images</path>
    <permissions>
      <mode>0711</mode>
      <owner>0</owner>
      <group>0</group>
      <label>system_u:object_r:virt_image_t:s0</label>
    </permissions>
  </target>
</pool>
```

#### Isolated Production Network Pool XML (`/etc/libvirt/qemu/networks/prod-isolated-net.xml`)
```xml
<network>
  <name>prod-isolated-net</name>
  <uuid>e91a2b3c-4d5e-6f7a-8b9c-0123456789de</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mac address='52:54:00:ee:11:22'/>
  <domain name='internal.production.local'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.100' end='192.168.100.254'/>
      <host mac='52:54:00:1a:3b:4c' name='prod-app-vm01' ip='192.168.100.10'/>
    </dhcp>
  </ip>
</network>
```

---

### 3.3 Host System Performance & Kernel Tuning Manifest (`/etc/sysctl.d/99-kvm-sre-performance.conf`)
```ini
# Production KVM Host System Tuning Parameters

# Disable Transparent Huge Pages (THP) allocation stalling (handled via explicit hugepages)
vm.transparent_hugepage = never

# Maximize memory availability for KVM guests and prevent excessive swapping
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.vfs_cache_pressure = 50

# Network Core performance for high-throughput bridge & vhost handling
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096

# Enable ARP filtering and bypass unnecessary bridge netfilter evaluation
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0

# Prevent low-memory allocation deadlocks
vm.min_free_kbytes = 1048576
```

---

## 4. Real Terminal CLI Commands and Realistic Outputs ($)

### 4.1 Hardware Virtualization Capability Audit
Verify CPU hardware support, kernel module status, and hypervisor capabilities.

```bash
$ lscpu | grep -E "(Virtualization|Vendor ID|NUMA node\(s\))"
Vendor ID:               GenuineIntel
Virtualization:          VT-x
NUMA node(s):            2

$ egrep -c "(vmx|svm)" /proc/cpuinfo
64

$ lsmod | grep kvm
kvm_intel             368640  32
kvm                  1048576  1 kvm_intel

$ virsh domcapabilities --virttype kvm --arch x86_64 --machine pc-q35-8.1 | grep -A 8 "<domain>"
<domain>kvm</domain>
<machine>pc-q35-8.1</machine>
<arch>x86_64</arch>
<vcpu max='288'/>
<iothreads supported='yes'/>
<os supported='yes'>
  <enum name='firmware'/>
  <loader supported='yes'>
    <value>/usr/share/OVMF/OVMF_CODE.fd</value>
```

---

### 4.2 Storage Operations with `qemu-img`
Create, inspect, rebase, and snapshot virtual disk images.

#### Creating a Pre-allocated QCow2 Image
```bash
$ qemu-img create -f qcow2 -o cluster_size=64k,preallocation=metadata /var/lib/libvirt/images/prod-app-vm01-root.qcow2 100G
Formatting '/var/lib/libvirt/images/prod-app-vm01-root.qcow2', fmt=qcow2 cluster_size=648576 preallocation=metadata size=107374182400 lazy_refcounts=off refcount_bits=16
```

#### Detailed Image Inspection
```bash
$ qemu-img info --backing-chain /var/lib/libvirt/images/prod-app-vm01-root.qcow2
image: /var/lib/libvirt/images/prod-app-vm01-root.qcow2
file format: qcow2
virtual size: 100 GiB (107374182400 bytes)
disk size: 1.25 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    corrupt: false
    extended l2: false
```

#### Live External Snapshot Creation via `virsh`
```bash
$ virsh snapshot-create-as --domain prod-app-vm01 \
    --name "snap-pre-kernel-upgrade" \
    --description "Snapshot before Linux kernel 6.6 patch" \
    --atomic --disk-only
Domain snapshot snap-pre-kernel-upgrade created
```

---

### 4.3 Domain Lifecycle and Affinity Tuning via `virsh`

#### Defining and Starting the VM
```bash
$ virsh define /etc/libvirt/qemu/prod-app-vm01.xml
Domain 'prod-app-vm01' defined from /etc/libvirt/qemu/prod-app-vm01.xml

$ virsh start prod-app-vm01
Domain 'prod-app-vm01' started

$ virsh list --all
 Id   Name             State
--------------------------------
 1    prod-app-vm01    running
```

#### Verifying Real-Time vCPU Pinning & Affinity
```bash
$ virsh vcpupin prod-app-vm01
VCPU   CPU Affinity
----------------------
 0      2
 1      3
 2      4
 3      5
 4      6
 5      7
 6      8
 7      9
```

#### Fetching Real-Time Virtual Machine Statistics
```bash
$ virsh domstats prod-app-vm01 --cpu-total --balloon --block --net
Domain: 'prod-app-vm01'
  cpu.time=458291048291
  cpu.user=12049182390
  cpu.system=34019284102
  balloon.current=16777216
  balloon.maximum=16777216
  block.count=1
  block.0.name=sda
  block.0.path=/var/lib/libvirt/images/prod-app-vm01-root.qcow2
  block.0.rd.reqs=124091
  block.0.rd.bytes=4912048128
  block.0.wr.reqs=981240
  block.0.wr.bytes=18491024896
  net.count=1
  net.0.name=vnet0
  net.0.rx.bytes=9812490182
  net.0.rx.pkts=4192041
  net.0.tx.bytes=490128401
  net.0.tx.pkts=2094012
```

---

## 5. Production Verification & Diagnostic / Fault-Troubleshooting Guide

```
+-----------------------------------------------------------------------------------+
|                        SRE VM TROUBLESHOOTING FLOWCHART                           |
+-----------------------------------------------------------------------------------+
| Issue Detected: Performance degradation, high latency, or unresponsive guest     |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
                         +---------------------------------+
                         | Check Host CPU & VM-Exit Rates  |
                         | Command: kvm_stat -1            |
                         +---------------------------------+
                                          |
                     +--------------------+--------------------+
                     |                                         |
                     v                                         v
        High Exit Rate (>50k/sec)                   Normal Exit Rate (<5k/sec)
         (EPT Violations / IO)                                 |
                     |                                         v
                     v                        +----------------------------------+
        +--------------------------+          | Check Storage I/O Latency        |
        | Check Memory Allocation  |          | Command: virsh domblkstat        |
        | & Hugepages Backing      |          +----------------------------------+
        +--------------------------+                           |
                                                  +------------+------------+
                                                  |                         |
                                                  v                         v
                                       High Block Wait Times      Low Block Wait Times
                                       (I/O Thread contention)              |
                                                  |                         v
                                                  v            +--------------------------+
                                     +----------------------+  | Check VirtIO Network     |
                                     | Switch cache mode to |  | Drops & Ring Starvation  |
                                     | 'none' (O_DIRECT)    |  | Command: ethtool -S vnet0|
                                     +----------------------+  +--------------------------+
```

---

### 5.1 Issue 1: High CPU Steal Time & VM-Exit Storms
* **Symptom**: Guest OS reports high CPU `%steal` time in `top`/`htop` ($> 15\%$), and host experiences elevated CPU utilization with low guest application throughput.
* **Root Cause**: Excessive VM-Exits caused by unaccelerated page faults (lack of EPT/NPT or misalignment), hypervisor lock contention, or unpinned vCPU scheduling across NUMA nodes.

#### Diagnostic Command & Output Analysis
Run `kvm_stat` to isolate exit events:

```bash
$ sudo kvm_stat -1
Event                                   Total      %CurAvg/s
 ept_violation                          891240        45210
 irq_exits                              412090        12040
 io_instruction                          98240          410
 kvm_entry                             1401570        57660
 kvm_exit                              1401560        57650
```

> **Analysis**: `ept_violation` at $45,210/\text{sec}$ indicates the guest is continuously triggering hardware page fault exits.

#### Mitigation Step
Verify and allocate **Explicit 1GiB Hugepages** on host and bind memory to local NUMA node:

```bash
# Check current Hugepages allocation on host
$ cat /proc/meminfo | grep -i hugepages
HugePages_Total:      16
HugePages_Free:        0
Hugepagesize:    1048576 kB

# Dynamically allocate 16x 1GiB Hugepages on NUMA Node 0
$ echo 16 | sudo tee /sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages
```

---

### 5.2 Issue 2: Storage I/O Latency & Thread Contention Stalls
* **Symptom**: High guest I/O wait (`iowait` $> 30\%$) during heavy write operations, disk throughput bottlenecks, and occasional QEMU VM freezing.
* **Root Cause**: Using host page caching (`cache='writeback'`) causing host write buffer flushes, or running storage single-threaded on the QEMU main event loop instead of dedicated `iothreads`.

#### Diagnostic Command & Output Analysis
Check disk execution statistics via `virsh`:

```bash
$ virsh domblkstat prod-app-vm01 sda --extended
Device: sda
  rd_req: 140912
  rd_bytes: 4912048128
  rd_total_times: 120491823
  wr_req: 981240
  wr_bytes: 18491024896
  wr_total_times: 981240918241
  flush_req: 12401
  flush_total_times: 891240182
```

Calculate write latency:
$$\text{Average Write Latency} = \frac{\text{wr\_total\_times}}{\text{wr\_req}} = \frac{981240918241 \text{ ns}}{981240} \approx 1.0 \text{ ms (High for local NVMe)}$$

#### Mitigation Step
1. Edit Domain XML (`virsh edit prod-app-vm01`).
2. Ensure `<driver name='qemu' type='qcow2' cache='none' io='native'/>` is configured to bypass host page cache and use Linux native AIO (`io='native'`).
3. Bind disk controllers to isolated IOThreads:

```xml
<iothreads>2</iothreads>
<cputune>
  <iothreadpin iothread='1' cpuset='0'/>
  <iothreadpin iothread='2' cpuset='1'/>
</cputune>
```

---

### 5.3 Issue 3: Cross-NUMA Node Memory Latency Degradation
* **Symptom**: Unexplained random compute performance degradation of $20\% - 40\%$ on multi-socket system hosts.
* **Root Cause**: vCPU threads are scheduled on CPU Socket 0, while guest memory allocations are assigned to RAM DIMMs attached to NUMA Node 1 (UPI/QPI interconnect bottleneck).

#### Diagnostic Command & Output Analysis
Check host NUMA topology and VM thread placement using `numactl`:

```bash
$ numactl --hardware
available: 2 nodes (0-1)
node 0 cpus: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
node 0 size: 128842 MB
node 1 cpus: 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31
node 1 size: 129012 MB
node distances:
node   0   1
  0:  10  21
  1:  21  10

# Check process memory allocation across nodes for QEMU PID
$ numastat -c qemu-system-x86_64

Per-node process memory usage (in MBs):
Node 0          Node 1           Total
--------------  --------------  --------------
  2048.12        14335.88        16384.00
```

> **Analysis**: Memory is split across Node 0 and Node 1, causing cross-node remote memory access over high-latency UPI interconnects.

#### Mitigation Step
Enforce strict NUMA memory allocation matching the vCPU pinning in libvirt:

```xml
<cputune>
  <vcpupin vcpu='0' cpuset='0'/>
  <vcpupin vcpu='1' cpuset='1'/>
  <vcpupin vcpu='2' cpuset='2'/>
  <vcpupin vcpu='3' cpuset='3'/>
  <emulatorpin cpuset='0-1'/>
</cputune>
<numatune>
  <memory mode='strict' nodeset='0'/>
</numatune>
```

---

### 5.4 Issue 4: VirtIO Network Packet Drops & Ring Buffer Starvation
* **Symptom**: High network packet loss under heavy load, high TCP retransmissions, degraded throughput on 10G/40G interfaces.
* **Root Cause**: VirtIO ring buffer exhaustion (`rx_queue_size` default of 256 is too small) or lack of `vhost-net` multi-queue scaling.

#### Diagnostic Command & Output Analysis
Inspect `vnet` interface packet drops on host:

```bash
$ ethtool -S vnet0
NIC statistics:
     rx_packets: 4192041
     rx_bytes: 9812490182
     rx_drop: 142091
     rx_errors: 0
     tx_packets: 2094012
     tx_bytes: 490128401
     tx_drop: 0
```

#### Mitigation Step
Increase ring buffer limits and enable multi-queue matching vCPU count in domain XML:

```xml
<interface type='bridge'>
  <source bridge='br0'/>
  <model type='virtio'/>
  <driver name='vhost' queues='4' rx_queue_size='1024' tx_queue_size='1024'/>
</interface>
```

Inside Guest OS, enable multi-queue packet processing on interface:
```bash
$ sudo ethtool -L eth0 combined 4
```

---

## 6. References

* **Linux Professional Institute LPIC-3 305 Overview**:  
  https://www.lpi.org/our-certifications/lpic-3-305-overview/
* **QEMU Documentation & Architecture**:  
  https://www.qemu.org/documentation/
* **Libvirt Domain XML Format Reference**:  
  https://libvirt.org/formatdomain.html
* **Kernel-based Virtual Machine (KVM) Architecture Documentation**:  
  https://www.kernel.org/doc/html/latest/virt/kvm/index.html
* **Red Hat Enterprise Linux 9 Virtualization Management & Tuning Guide**:  
  https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/