# LPIC-3 Exam 305-300 (v3.0) — Topic 351: Full Virtualization

**Exam Topic:** 351: Full Virtualization  
**Weight:** 33.33 (Comprehensive coverage across objectives 351.1–351.5)  
**Target Level:** Senior SRE / Principal Platform Architect  
**Official Reference Documentation:**
*   [LPI LPIC-3 305 Objectives](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
*   [KVM Kernel Documentation](https://www.kernel.org/doc/html/latest/virt/kvm/index.html)
*   [QEMU Official Documentation](https://www.qemu.org/documentation/)
*   [Libvirt Architecture & XML Format](https://libvirt.org/formatdomain.html)
*   [Xen Project Official Documentation](https://xenproject.org/help/documentation/)
*   [Libguestfs Documentation](https://libguestfs.org/)

---

## Technical Architecture Overview

Full virtualization relies on hardware-assisted virtualization extensions introduced by CPU vendors (Intel VT-x / AMD-V) to trap privileged CPU operations without binary translation.

```
+-----------------------------------------------------------------------+
|                         GUEST OS (User / Kernel)                       |
|                   Executes in Ring 0/3 (VMX Non-Root Mode)            |
+-----------------------------------------------------------------------+
                                    |
                            VM-Exit | VM-Resume
                                    v
+-----------------------------------------------------------------------+
|                            HOST KERNEL (KVM)                          |
|    Executes in Ring 0 (VMX Root Mode) - Manages EPT/NPT, vCPU Scheduling |
+-----------------------------------------------------------------------+
                                    ^
                                    | /dev/kvm ioctl()
                                    v
+-----------------------------------------------------------------------+
|                                QEMU CLI / Process                     |
|           User-space device emulation (VirtIO, ACPI, PCI Bus)         |
+-----------------------------------------------------------------------+
                                    ^
                                    | RPC / UNIX Domain Socket
                                    v
+-----------------------------------------------------------------------+
|                                LIBVIRTD                               |
|        Domain XML translation, Cgroups allocation, Network Bridges   |
+-----------------------------------------------------------------------+
```

---

## Lab Block 1: Hardware Virtualization Extensions & Hypervisor Theory (Objective 351.1)

### Execution Steps

1. Execute a low-level check on the host CPU flags to verify hardware-assisted virtualization extensions and Second Level Address Translation (SLAT / Intel EPT or AMD NPT) capabilities:

```bash
lscpu | grep -E "Virtualization|Hypervisor|flags"
```

*Expected Output:*
```text
Virtualization:                  VT-x
Hypervisor vendor:               KVM
Virtualization type:             full
Flags:                           fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cdp_l3 invpcid_single intel_pt ssbd mba ibrs ibpb stibp tpr_shadow vnmi flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid rtm cqm mpx rdt_a avx512f avx512dq rdseed adx smap clflushopt clwb avx512cd avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local dtherm ida arat pln pts md_clear flush_l1d arch_capabilities
```

2. Confirm that the kernel module `/dev/kvm` is loaded and inspect nested virtualization status:

```bash
ls -l /dev/kvm
cat /sys/module/kvm_intel/parameters/nested
```

*Expected Output:*
```text
crw-rw----+ 1 root kvm 10, 232 Aug  6 14:22 /dev/kvm
Y
```

3. Interrogate the host memory management subsystem to verify HugeTLB support used by Hypervisors to eliminate EPT/NPT page table walk latency:

```bash
grep -i Huge /proc/meminfo
```

*Expected Output:*
```text
AnonHugePages:         0 kB
ShmemHugePages:        0 kB
FileHugePages:         0 kB
HugePages_Total:    4096
HugePages_Free:     4096
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
Hugetlb:         8388608 kB
```

---

### Comprehension Questions — Block 1

**Question 1.1:** What physical transition occurs at the CPU hardware level when a guest virtual machine operating under Intel VT-x executes an unprivileged kernel instruction that requires hypervisor intervention (such as modifying Control Register `CR3` or triggering an I/O port read)?  
**Question 1.2:** In a high-throughput production environment, what architectural trade-off occurs when choosing between Para-Virtualization (PV) and Full Virtualization with Hardware Assist (HVM)?

---

## Lab Block 2: Low-Level QEMU Invocation & Monitor Control (Objective 351.3)

### Execution Steps

1. Launch an isolated QEMU process directly from the CLI using explicit hardware acceleration, modern VirtIO devices, and exposing a QEMU Monitor UNIX socket interface:

```bash
qemu-system-x86_64 \
  -name production-node-01,process=qemu:prod-node-01 \
  -machine q35,accel=kvm \
  -cpu host \
  -m 2048 \
  -smp 2,sockets=1,cores=2,threads=1 \
  -drive file=/var/lib/libvirt/images/prod-node-01.qcow2,if=virtio,format=qcow2,aio=native,cache=none \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:fa:12:34 \
  -monitor unix:/var/run/qemu-prod-node-01.sock,server,nowait \
  -nographic \
  -daemonize
```

2. Confirm the running process, observing thread allocation and CPU pin affinity:

```bash
ps aux | grep qemu-system-x86_64
```

*Expected Output:*
```text
root     14209  3.2  4.1 3241052 684200 ?      Ssl  14:30   0:12 qemu-system-x86_64 -name production-node-01,process=qemu:prod-node-01 -machine q35,accel=kvm -cpu host -m 2048 -smp 2,sockets=1,cores=2,threads=1 -drive file=/var/lib/libvirt/images/prod-node-01.qcow2,if=virtio,format=qcow2,aio=native,cache=none -netdev tap,id=net0,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=net0,mac=52:54:00:fa:12:34 -monitor unix:/var/run/qemu-prod-node-01.sock,server,nowait -nographic -daemonize
```

3. Connect to the runtime QEMU Human Monitor Interface (HMP) via `socat` to inspect live guest runtime hardware state:

```bash
echo "info kvm" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
echo "info cpus" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
echo "info block" | socat - UNIX-CONNECT:/var/run/qemu-prod-node-01.sock
```

*Expected Output:*
```text
QEMU 8.2.2 monitor - type 'help' for more information
(qemu) info kvm
kvm support: enabled
(qemu) info cpus
* CPU #0: thread_id=14211 core_id=0 smp_thread_id=0 (halted)
  CPU #1: thread_id=14212 core_id=1 smp_thread_id=0 (halted)
(qemu) info block
virtio0 (#block104): /var/lib/libvirt/images/prod-node-01.qcow2 (qcow2)
    Attached to:      /machine/peripheral-anon/device[0]
    Cache mode:       writeback, direct
```

---

### Comprehension Questions — Block 2

**Question 2.1:** What is the precise performance implication of setting `-drive cache=none,aio=native` versus `-drive cache=writeback,aio=threads` in a production database workload hosted on QEMU/KVM?  
**Question 2.2:** Why is `-device virtio-net-pci` superior in throughput and CPU overhead compared to `-device e1000`? Explain the interaction between guest drivers and host ring buffers.

---

## Lab Block 3: Xen Architecture, Dom0 & DomU Management (Objective 351.2)

### Execution Steps

1. Inspect the Xen Hypervisor status from Domain 0 (Dom0) using the Xen management tool `xl`:

```bash
xl info
```

*Expected Output:*
```text
host                   : xen-hypervisor-node01
release                : 6.1.0-18-amd64
version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1
machine                : x86_64
nr_cpus                : 16
max_cpu_id             : 15
nr_nodes               : 1
cores_per_socket       : 8
threads_per_core       : 2
cpu_mhz                : 2994.120
hw_caps                : bfebfbff:77faf3bf:2c100800:00000001:00000001:00000000:00000000:00000000
virt_caps              : hvm hvm_directio pv
total_memory           : 65536
free_memory            : 49152
sharing_freed_memory   : 0
outstanding_claims     : 0
xen_major              : 4
xen_minor              : 17
xen_extra              : .2
xen_caps               : xen-3.0-x86_64 xen-3.0-x86_32p hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
xen_scheduler          : credit2
xen_pagesize           : 4096
platform_params        : virt_start=0xffff800000000000
xen_changeset          : 
xen_commandline        : placeholder dom0_mem=16384M,max:16384M dom0_max_vcpus=4 loglvl=all guest_loglvl=all
cc_compiler            : gcc (Debian 12.2.0-14) 12.2.0
cc_date                : Wed Feb  7 12:00:00 UTC 2024
build_by               : pkg-xen-devel@lists.alioth.debian.org
build_date             : Wed Feb  7 12:00:00 UTC 2024
```

2. Synthesize a production-ready Xen Domain U (DomU) fully virtualized (HVM) configuration file `/etc/xen/domu-srv01.cfg`:

```bash
cat << 'EOF' > /etc/xen/domu-srv01.cfg
# Xen DomU Configuration File — LPIC-3 Production Standard
type = "hvm"
name = "domu-srv01"
uuid = "a4c28f32-7b89-4e12-b91c-99d82e11fa02"
memory = 4096
maxmem = 8192
vcpus = 4
maxvcpus = 8

# Hardware Acceleration & Nesting Settings
builder = "hvm"
hap = 1
nestedhvm = 1

# Storage Interfaces
disk = [
    'format=qcow2, vdev=xvda, access=rw, target=/var/lib/xen/images/domu-srv01.qcow2',
    'format=raw, vdev=xvdb, access=rw, target=/dev/vg_xen/lv_domu_data'
]

# Networking Configuration
vif = [
    'mac=00:16:3e:54:1a:8b, bridge=xenbr0, script=vif-bridge, model=e1000'
]

# Boot Behavior & Console
boot = "c"
sdl = 0
vnc = 1
vnclisten = "127.0.0.1"
vncpasswd = "SecureClusterPasscode123!"

on_poweroff = "destroy"
on_reboot = "restart"
on_crash = "restart"
EOF
```

3. Provision and monitor the live Xen DomU instance:

```bash
xl create /etc/xen/domu-srv01.cfg
xl list
xl top -b -n 1
```

*Expected Output:*
```text
Parsing config file /etc/xen/domu-srv01.cfg
Name                                        ID   Mem VCPUs	State	Time(s)
Domain-0                                     0 16384     4     r-----     142.5
domu-srv01                                   1  4096     4     -b----       0.8

xentop - 14:35:02 Xen 4.17.2
2 domains: 1 running, 1 blocked, 0 paused, 0 crashed, 0 dying, 0 shutdown
Mem: 67108864k total, 41943040k used, 25165824k free    CPUs: 16 @ 2994MHz
NAME      STATE   CPU(sec) CPU(%)  MEM(k) MEM(%)  MAXMEM(k) MAXMEM(%) VCPUS NETS NETCNT VBD VBD_OO   REQ-1  WR-1 RD-1
Domain-0  rb----       143    2.1 16777216   25.0   16777216      25.0     4    1      0   0      0       0     0    0
domu-srv01 --b---         1    0.2  4194304    6.2    8388608      12.5     4    1      0   2      0     120    85   35
```

---

### Comprehension Questions — Block 3

**Question 3.1:** Why is it imperative in Xen production deployment to restrict Domain 0 memory via the GRUB command line parameter `dom0_mem=16384M,max:16384M`? What happens if this constraint is omitted?  
**Question 3.2:** Differentiate between PV-on-HVM drivers and pure Paravirtualization (PV) in Xen. How does the guest kernel communicate with the Xen Hypervisor when executing block device I/O under PV-on-HVM?

---

## Lab Block 4: Libvirt Domain XML Architecture & Advanced Lifecycle Operations (Objective 351.4)

### Execution Steps

1. Create a production Libvirt XML manifest `/tmp/database-vm.xml` specifying NUMA pinning, dedicated memory backing, and VirtIO devices:

```bash
cat << 'EOF' > /tmp/database-vm.xml
<domain type='kvm'>
  <name>database-vm</name>
  <uuid>f310bda4-1cfa-4680-9286-63d1fbb59821</uuid>
  <memory unit='KiB'>8388608</memory>
  <currentMemory unit='KiB'>8388608</currentMemory>
  <memoryBacking>
    <hugepages/>
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
    <type arch='x86_64' machine='pc-q35-8.2'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <kvm>
      <hidden state='on'/>
    </kvm>
  </features>
  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='tsc' mode='native'/>
  </clock>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='/var/lib/libvirt/images/database-vm.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>
    <interface type='bridge'>
      <mac address='52:54:00:22:99:aa'/>
      <source bridge='br-prod'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'>
      <stats period='10'/>
    </memballoon>
  </devices>
</domain>
EOF
```

2. Define, start, and perform live runtime modifications using `virsh`:

```bash
virsh define /tmp/database-vm.xml
virsh start database-vm
virsh setvcpus database-vm 2 --live
virsh vcpupin database-vm
```

*Expected Output:*
```text
Domain 'database-vm' defined from /tmp/database-vm.xml
Domain 'database-vm' started

VCPU   CPU Affinity
-----------------------------------------------------------
   0   2
   1   3
   2   4
   3   5
```

3. Compare runtime volatile XML state vs persistent XML file state:

```bash
virsh dumpxml database-vm | grep -A 5 "<vcpu"
virsh dumpxml database-vm --inactive | grep -A 5 "<vcpu"
```

*Expected Output:*
```text
  <vcpu placement='static' current='2' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
--
  <vcpu placement='static' cpuset='2-5'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
  </cputune>
```

---

### Comprehension Questions — Block 4

**Question 4.1:** What is the technical function of `<driver name='vhost' queues='4'/>` defined inside the Libvirt domain XML network interface block?  
**Question 4.2:** Explain the outcome when issuing `virsh edit database-vm` while the VM is running versus applying `virsh attach-device database-vm device.xml --config --live`. What happens if the host reboots without passing `--config`?

---

## Lab Block 5: Disk Image Engineering, Snapshot Chains & Libguestfs Diagnostics (Objective 351.5)

### Execution Steps

1. Create a golden base image and build a copy-on-write snapshot overlay chain using `qemu-img`:

```bash
qemu-img create -f qcow2 /var/lib/libvirt/images/base-gold.qcow2 20G
qemu-img create -f qcow2 -b /var/lib/libvirt/images/base-gold.qcow2 -F qcow2 /var/lib/libvirt/images/overlay-snap1.qcow2
qemu-img info --backing-chain /var/lib/libvirt/images/overlay-snap1.qcow2
```

*Expected Output:*
```text
image: /var/lib/libvirt/images/overlay-snap1.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 196 KiB
cluster_size: 65536
backing file: /var/lib/libvirt/images/base-gold.qcow2
backing file format: qcow2
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false

image: /var/lib/libvirt/images/base-gold.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
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

2. Perform non-destructive offline inspection of the VM disk filesystem layout using `libguestfs` utilities (`virt-filesystems`, `virt-df`):

```bash
virt-filesystems --long -h --all -a /var/lib/libvirt/images/base-gold.qcow2
virt-df -h -a /var/lib/libvirt/images/base-gold.qcow2
```

*Expected Output:*
```text
Name       Type        VFS   Label  MBR  Size  Parent
/dev/sda1  filesystem  ext4  -      -    19G   -
/dev/sda2  filesystem  swap  -      -    1.0G  -
/dev/sda   device      -     -      -    20G   -

Filesystem                               Size       Used  Available  Use%
base-gold.qcow2:/dev/sda1                 19G       2.1G        16G   12%
```

3. Execute surgical offline modifications directly inside the qcow2 disk without booting a virtual machine using `guestfish`:

```bash
guestfish --rw -a /var/lib/libvirt/images/overlay-snap1.qcow2 << 'EOF'
run
mount /dev/sda1 /
cat /etc/hostname
touch /root/sre_audit_flag.txt
write /etc/motd "Authorized SRE System Access Only\n"
umount /
exit
EOF
```

4. Perform an online rebase to consolidate backing stores, collapsing the snapshot overlay into a standalone target:

```bash
qemu-img rebase -b "" /var/lib/libvirt/images/overlay-snap1.qcow2
qemu-img info /var/lib/libvirt/images/overlay-snap1.qcow2
```

*Expected Output:*
```text
image: /var/lib/libvirt/images/overlay-snap1.qcow2
file format: qcow2
virtual size: 20 GiB (21474836480 bytes)
disk size: 2.1 GiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
    corrupt: false
    extended l2: false
```

---

### Comprehension Questions — Block 5

**Question 5.1:** What severe data corruption risk is introduced when running `guestfish --rw` or `virt-customize` on a QEMU/KVM disk image file while the corresponding domain is actively running?  
**Question 5.2:** Explain the structural difference between `qemu-img rebase -b` (unsafe mode without specifying backing format verification) and `qemu-img commit`. When should an SRE use `commit` vs `rebase`?

---

<details>
<summary>Solutions and Architectural Deep-Dives</summary>

### Answers — Lab Block 1

**Answer 1.1:**  
When an unprivileged guest instruction requires hypervisor intervention, the CPU undergoes a hardware-level transition known as a **VM-Exit**. Under Intel VT-x:
1. The hardware saves the guest processor state (Control Registers, Instruction Pointer `RIP`, Stack Pointer `RSP`, Segment Registers) into the VMCS (Virtual Machine Control Structure) Guest-State Area.
2. The CPU mode transitions from **VMX Non-Root Mode** (where guest code runs directly on bare metal at Ring 0/3) to **VMX Root Mode** (where the Host Kernel / KVM executes at Ring 0).
3. The hardware loads host register states from the VMCS Host-State Area and transfers execution to the KVM VM-Exit handler defined in `kvm_intel.ko`.
4. Once KVM/QEMU emulates the operation (e.g., updating virtual CR3 or servicing guest I/O), KVM issues the `VMLAUNCH` or `VMRESUME` instruction, triggering a **VM-Entry** that switches execution back to VMX Non-Root mode.

**Answer 1.2:**  
*   **Para-Virtualization (PV):** Modifies the guest OS kernel to use hypercalls (explicit software calls) instead of executing sensitive hardware instructions.
    *   *Trade-off:* Highest I/O efficiency and lower instruction trap overhead on older hardware lacking SLAT/VT-x; however, it breaks kernel portability (requires modified hypervisor-aware guest kernels) and cannot run proprietary unmodifiable operating systems.
*   **Full Virtualization with Hardware Assist (HVM):** Relies on hardware extensions (VT-x/AMD-V) and nested page tables (EPT/NPT) to run unmodified guest operating systems.
    *   *Trade-off:* Complete OS compatibility and isolation; however, initial CPU architectures suffered performance penalties due to frequent VM-Exits. Modern CPUs mitigate this via EPT/NPT, VPID (Virtual Processor ID, preventing TLB flushes on VM-Exit), and SR-IOV/vhost-net.

---

### Answers — Lab Block 2

**Answer 2.1:**  
*   `-drive cache=none,aio=native`: Bypasses the host page cache completely using `O_DIRECT` open flags and routes Linux kernel asynchronous I/O (`io_submit`) directly to host storage hardware.
    *   *SRE Impact:* Essential for production databases (PostgreSQL/MySQL/Oracle). Prevents double caching (consuming host RAM for data already cached in the guest buffer pool), eliminates host page eviction latency spikes, and ensures data durability by guaranteeing writes reach non-volatile media when `fsync` is issued.
*   `-drive cache=writeback,aio=threads`: Routes writes through the host page cache and uses a POSIX thread pool inside QEMU to emulate asynchronous I/O.
    *   *SRE Impact:* Higher risk of data loss on host power failure unless backed by battery-backed write caches; subjects host memory to memory pressure and cache eviction overhead.

**Answer 2.2:**  
*   `-device e1000` emulates an Intel 82545EM Gigabit Ethernet controller in software. Every packet transmitted or received requires QEMU to emulate individual PCI register reads/writes, interrupt lines, and memory mapped I/O (MMIO), causing massive CPU consumption and high VM-Exit counts per packet.
*   `-device virtio-net-pci` implements the VirtIO standardized paravirtualized I/O framework. It uses shared memory lockless ring buffers (**Virtqueues** consisting of Available Rings and Used Rings) between guest RAM and host RAM. Packets are transferred via DMA without emulating physical hardware registers, reducing VM-Exits to a minimum and enabling vhost-net kernel-level processing.

---

### Answers — Lab Block 3

**Answer 3.1:**  
Domain 0 (Dom0) is the privileged control domain in Xen responsible for running hardware drivers, handling control stack tools (`xl`, `xenstore`), and routing I/O for unprivileged Domain U (DomU) guests.
*   If `dom0_mem` is not fixed, Dom0 will dynamically claim all physical host RAM upon boot. When DomU guests are subsequently spawned, Xen attempts to balloon down Dom0 memory on the fly.
*   *Production Impact:* Memory ballooning under heavy load causes Dom0 memory exhaustion, triggering the Linux Kernel Out-Of-Memory (OOM) Killer inside Dom0, killing `xenstored` or `xl` processes, host kernel panics, and hypervisor-wide outages.

**Answer 3.2:**  
*   **PV-on-HVM:** Uses hardware acceleration (VT-x/AMD-V) for CPU and memory execution (avoiding PV kernel modifications), but installs paravirtualized VirtIO/Xen-PV storage (`xen-blkfront`) and network (`xen-netfront`) drivers inside the guest OS.
*   *Communication Mechanism:* When executing block I/O, `xen-blkfront` in DomU writes request descriptors into a shared memory ring buffer (**Grant Tables**) allocated between DomU and Dom0. DomU then signals the Xen Hypervisor via an **Event Channel** (lightweight virtual interrupt). The host backend driver (`xen-blkback` in Dom0) reads the Grant Table reference, performs the physical disk I/O, and signals completion back via the Event Channel, bypassing slow QEMU hardware emulation entirely.

---

### Answers — Lab Block 4

**Answer 4.1:**  
`<driver name='vhost' queues='4'/>` moves the virtio-net data path out of the user-space QEMU process directly into the Linux host kernel module `vhost-net.ko`.
*   Setting `queues='4'` enables **Multi-Queue VirtIO-Net**. It instantiates 4 separate transmit/receive virtqueues mapped to 4 vhost kernel threads bound to 4 dedicated vCPUs.
*   *Production Benefit:* Eliminates single-thread CPU bottlenecks on high-speed network interfaces (10GbE/40GbE/100GbE), allowing network packet processing to scale linearly across multiple host CPU cores.

**Answer 4.2:**  
*   Executing `virsh edit database-vm` edits the **persistent configuration XML file** stored on disk (`/etc/libvirt/qemu/database-vm.xml`). The changes do **not** take effect on the currently running domain instance; they apply only after the domain is completely shut down and restarted.
*   Applying `virsh attach-device ... --config --live` updates both the running hypervisor instance state (volatile RAM) AND updates the persistent XML file on disk.
*   *Reboot Risk:* If `--config` is omitted and only `--live` is used, the device is hot-plugged into the running VM immediately, but the change is lost as soon as the VM is stopped or the host hypervisor reboots, causing configuration drift.

---

### Answers — Lab Block 5

**Answer 5.1:**  
Running `guestfish --rw` or any modification tool on a live, active virtual machine disk image leads to immediate and catastrophic **filesystem metadata corruption**.
*   *Reason:* The guest OS kernel maintains page cache buffers, inode locks, and block allocation bitmaps in its own memory. When `guestfish` mounts the same underlying block device concurrently, it reads stale block layouts and writes raw sectors directly to disk. The guest OS remains unaware of these external block modifications, resulting in conflicting journal writes, orphan inodes, cross-linked clusters, and destroyed filesystems.

**Answer 5.2:**  
*   `qemu-img commit`: Merges all modifications written to an overlay image directly back into its designated backing file (moves changes *down* the chain: `overlay-snap1.qcow2` -> `base-gold.qcow2`).
*   `qemu-img rebase -b <new_base>`: Changes the backing store pointer of a qcow2 file (moves *across* or *flattens* the chain).
    *   *Safe Rebase (Default):* QEMU compares clusters between the old backing file and new backing file, copying any missing differences into the target file so data integrity is preserved.
    *   *Unsafe Rebase (`-u`):* Only updates the internal backing file header string without inspecting block contents.
*   *SRE Operational Rule:* Use `commit` when flattening temporary snapshot files back into a golden base image during maintenance windows. Use `rebase` when repointing VMs to updated base templates or severing backing chains entirely (`qemu-img rebase -b ""`) to create independent standalone images for migration.

</details>