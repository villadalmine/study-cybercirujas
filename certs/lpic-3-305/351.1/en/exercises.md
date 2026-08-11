# 351.1 Virtualization Concepts and Theory — Guided Exercises

> **Exam:** LPIC-3 305-300 (Virtualization and Containerization), version 3.0 — Topic 351.1 (weight 10)
> **Objective source:** LPI Exam 305 Objectives — https://www.lpi.org/our-certifications/exam-305-objectives/
>
> **What you need.** A Linux host (Debian/Ubuntu or a RHEL-family distro) with `sudo`. Most steps are read-only inspection and are safe to run on any machine, including a laptop or an existing VM. Steps that create a guest, snapshot or migrate need `qemu-kvm`, `libvirt` and `virtinst` installed and are clearly marked; run them on a lab host, not production.
> **Package hints.** Debian/Ubuntu: `sudo apt install qemu-kvm libvirt-daemon-system virtinst libguestfs-tools cpu-checker virt-what open-vswitch-switch`. RHEL/Fedora: `sudo dnf install qemu-kvm libvirt virt-install libguestfs-tools-c virt-what openvswitch`.
> **Convention.** Output blocks are labelled *example output* — exact values (core counts, UUIDs, addresses) will differ on your machine. Read them to learn what a field *means*, not to match them byte-for-byte.

---

## Exercise 1 — Detect hardware virtualization support with CPU flags and `/proc/cpuinfo`

**Goal:** determine whether the physical CPU offers hardware-assisted virtualization (Intel VT-x / AMD-V), and whether the extras that make it fast (SLAT) are present.

1. Look at the raw per-core flags exported by the kernel. Every logical CPU is a stanza in `/proc/cpuinfo`; the `flags` line lists CPUID feature bits:

   ```bash
   grep -m1 -o -E 'vmx|svm' /proc/cpuinfo
   ```

   *Example output (Intel):*
   ```
   vmx
   ```
   `vmx` = Intel VT-x. On an AMD CPU you would instead see `svm` (AMD-V, "Secure Virtual Machine").

2. Count how many logical CPUs expose the extension (should equal your CPU thread count if support is enabled in firmware):

   ```bash
   grep -c -E 'vmx|svm' /proc/cpuinfo
   ```
   *Example output:*
   ```
   8
   ```

3. Check for **Second Level Address Translation (SLAT)** — hardware MMU virtualization that removes the shadow-page-table overhead. Intel calls it EPT, AMD calls it NPT (`npt`) / RVI:

   ```bash
   grep -m1 -o -E 'ept|npt' /proc/cpuinfo
   ```
   *Example output (Intel):*
   ```
   ept
   ```

4. Get the same information pre-digested by `lscpu`, which reads CPUID for you:

   ```bash
   lscpu | grep -Ei 'virtual|hypervisor|model name'
   ```
   *Example output on bare metal:*
   ```
   Model name:            Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz
   Virtualization:        VT-x
   ```

5. On Debian/Ubuntu, confirm KVM usability directly (from the `cpu-checker` package):

   ```bash
   sudo kvm-ok
   ```
   *Example output when usable:*
   ```
   INFO: /dev/kvm exists
   KVM acceleration can be used
   ```
   *Example output when the flag is missing or firmware-disabled:*
   ```
   INFO: Your CPU does not support KVM extensions
   KVM acceleration can NOT be used
   ```

> **Checkpoint 1**
> - **Q1.1** A colleague runs `grep -c vmx /proc/cpuinfo` on an AMD EPYC server and gets `0`, then concludes the server "can't do virtualization." Why is the conclusion wrong, and what should they grep for instead?
> - **Q1.2** `lscpu` reports `Virtualization: VT-x`, but `kvm-ok` says KVM can *not* be used and `/proc/cpuinfo` shows **no** `vmx` flag. What single, most likely cause explains all three observations at once, and where do you fix it?
> - **Q1.3** What does the presence of `ept` (or `npt`) buy you at runtime, and which slower software mechanism does it replace?

---

## Exercise 2 — Identify whether *you* are a guest, and under which hypervisor

**Goal:** from inside a running system, decide whether it is bare metal or a VM, and name the hypervisor. This is a routine SRE triage step.

1. The fastest signal: a guest CPU almost always carries the `hypervisor` feature flag, which bare-metal CPUs do **not** set:

   ```bash
   grep -o hypervisor /proc/cpuinfo | head -1
   ```
   *Example output inside a VM:*
   ```
   hypervisor
   ```
   No output → very likely bare metal.

2. Ask systemd, which inspects CPUID, DMI/SMBIOS and other cues and prints a canonical id:

   ```bash
   systemd-detect-virt
   ```
   *Example outputs:* `kvm`, `qemu`, `xen`, `microsoft` (Hyper-V), `vmware`, `oracle` (VirtualBox), or `none` on bare metal.
   Its exit status is `0` when virtualization is detected and non-zero when it prints `none`, so it scripts cleanly:

   ```bash
   systemd-detect-virt -q && echo "This is virtualized" || echo "Bare metal"
   ```

3. Distinguish a full VM from a container with the same tool:

   ```bash
   systemd-detect-virt --vm
   systemd-detect-virt --container
   ```
   Inside a KVM guest the first prints `kvm` and the second prints `none`; inside a Docker/LXC container it is the reverse.

4. Cross-check with `virt-what`, which can report **several** true facts at once (it may print both the hypervisor and the platform):

   ```bash
   sudo virt-what
   ```
   *Example output inside a KVM guest on a Red Hat host:*
   ```
   kvm
   ```

5. Look at the emulated firmware identity, which betrays the hypervisor's device model:

   ```bash
   sudo dmidecode -s system-manufacturer
   sudo dmidecode -s system-product-name
   ```
   *Example output under QEMU/KVM:*
   ```
   QEMU
   Standard PC (Q35 + ICH9, 2009)
   ```
   VirtualBox reports `innotek GmbH` / `VirtualBox`; VMware reports `VMware, Inc.`.

> **Checkpoint 2**
> - **Q2.1** On one host `systemd-detect-virt` prints `none` but `virt-what` prints two lines: `xen` and `xen-dom0`. Is this machine a guest? Explain what `xen-dom0` means.
> - **Q2.2** You are inside an LXC container running on a KVM VM running on a physical host. What will `systemd-detect-virt` (no flags) report, and why does it report only one thing?
> - **Q2.3** Why is the `hypervisor` CPU flag a *heuristic* rather than proof — give one case where it can be absent inside a VM and one where relying on it alone would still leave you unsure.

---

## Exercise 3 — Hypervisor taxonomy and the KVM / QEMU / libvirt stack

**Goal:** map the Type-1 vs Type-2 distinction onto the Linux tooling, and inspect the modules that turn a Linux kernel into a hypervisor.

1. Confirm the KVM kernel modules are loaded. `kvm` is the architecture-neutral core; `kvm_intel` or `kvm_amd` is the vendor backend:

   ```bash
   lsmod | grep -E '^kvm'
   ```
   *Example output:*
   ```
   kvm_intel             380928  0
   kvm                  1146880  1 kvm_intel
   ```

2. Verify the control device the hypervisor exposes to userspace:

   ```bash
   ls -l /dev/kvm
   ```
   *Example output:*
   ```
   crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm
   ```
   QEMU (userspace) opens this character device and issues `ioctl()`s to run guest vCPUs on the physical CPU via KVM (kernel). That division is the whole architecture: **QEMU provides the device model and I/O; KVM provides CPU/memory virtualization.**

3. Check whether **nested virtualization** (running a hypervisor inside a guest) is enabled:

   ```bash
   cat /sys/module/kvm_intel/parameters/nested   # or kvm_amd
   ```
   *Example output:* `Y` (or `1`). To enable it persistently you would set `options kvm_intel nested=1` under `/etc/modprobe.d/` and reload the module.

4. Ask libvirt what this host can run. `virsh capabilities` returns an XML description of host arch and supported guest domain types:

   ```bash
   sudo virsh capabilities | grep -E "<arch|domain type" | head
   ```
   *Example output:*
   ```
     <arch name='x86_64'>
       <domain type='qemu'/>
       <domain type='kvm'/>
   ```
   `domain type='kvm'` present ⇒ hardware acceleration is available; `qemu` alone ⇒ you would fall back to pure emulation.

5. Inspect one concrete guest capability set (accelerator, machine types, firmware):

   ```bash
   sudo virsh domcapabilities | grep -E "domain|machine|path" | head
   ```

> **Checkpoint 3**
> - **Q3.1** KVM is a kernel module inside a general-purpose Linux OS, yet it is usually classified as a *Type-1 (bare-metal)* hypervisor, while VirtualBox on the same Linux is *Type-2 (hosted)*. Justify the classification of each.
> - **Q3.2** In the KVM model, which component executes guest ring-0 instructions on the physical CPU, and which component emulates the guest's disk and network cards? Name both.
> - **Q3.3** You must run a KVM guest *inside* an existing cloud VM. Which one file/parameter must read `Y`, on which layer (guest or host), for that to be possible?

---

## Exercise 4 — Full virtualization (HVM), paravirtualization (PV) and `virtio`

**Goal:** understand the HVM vs PV distinction, map Xen's vocabulary, and see paravirtualized I/O (`virtio`) in action from inside a guest.

1. *(Run inside a KVM/QEMU guest.)* List the PCI devices and notice the paravirtualized ones. `virtio` devices identify as vendor **Red Hat, Inc.**:

   ```bash
   lspci | grep -i virtio
   ```
   *Example output:*
   ```
   00:04.0 SCSI storage controller: Red Hat, Inc. Virtio block device
   00:05.0 Ethernet controller: Red Hat, Inc. Virtio network device
   00:06.0 Unclassified device: Red Hat, Inc. Virtio memory balloon
   ```

2. Confirm the guest kernel bound the paravirtual drivers:

   ```bash
   lsmod | grep -E 'virtio'
   ```
   *Example output:*
   ```
   virtio_net             57344  0
   virtio_blk             20480  3
   virtio_balloon         24576  0
   virtio_pci             28672  0
   ```
   Contrast this with a **fully emulated** device such as an `e1000` NIC or an IDE disk: those imitate real silicon so an *unmodified* OS works, but every register access traps to the host. `virtio` instead uses a shared-memory ring buffer (`virtqueue`) that the guest driver and host cooperate on — that is paravirtualized I/O, and it is far faster.

3. Map the concepts to **Xen** terminology (reference only; run `xl` commands only on a Xen host):

   | Concept | Xen term / command |
   |---|---|
   | Privileged control domain with hardware + toolstack | **dom0** |
   | Unprivileged guest | **domU** |
   | Modified guest, hypercalls, no VT-x/AMD-V needed | **PV** (paravirtualization) |
   | Unmodified guest, needs VT-x/AMD-V + emulated devices | **HVM** (Hardware Virtual Machine) |
   | HVM guest that adds PV drivers for fast I/O | **PVHVM** |
   | Lightweight: HW virt for CPU/MMU, PV boot & I/O, no QEMU emulation | **PVH** |

   On a Xen host you would enumerate domains with:
   ```bash
   sudo xl list
   ```
   *Example output:*
   ```
   Name          ID   Mem VCPUs      State   Time(s)
   Domain-0       0  4096     4     r-----   1523.4
   web01          3  2048     2     -b----     87.1
   ```

4. See the analogous distinction inside the guest CPU: a **PV** guest never issues real privileged instructions (it makes *hypercalls*), whereas an **HVM** guest runs them natively and traps into the hypervisor via VT-x/AMD-V. The `hypervisor` flag from Exercise 2 is what an HVM guest sees; a classic Xen PV guest's `/proc/cpuinfo` looks different because it runs a Xen-aware kernel.

> **Checkpoint 4**
> - **Q4.1** State the defining difference between *full virtualization (HVM)* and *paravirtualization (PV)* in one sentence each, and say which one can boot an unmodified, off-the-shelf OS image.
> - **Q4.2** `virtio-net` is used inside an HVM/KVM guest that already has hardware virtualization. If HVM can run unmodified drivers, why bother installing a paravirtualized `virtio` driver at all?
> - **Q4.3** Match each Xen term to its role: `dom0`, `domU`, `PVH`. Which one has direct access to physical hardware?

---

## Exercise 5 — Emulation vs. virtualization vs. simulation, demonstrated with QEMU

**Goal:** feel the difference between *running guest instructions on the real CPU* (virtualization) and *translating them in software* (emulation), and pin down where "simulation" sits.

1. Start a tiny guest with **hardware acceleration** and time how fast it reaches firmware. `-accel kvm` runs guest instructions natively:

   ```bash
   qemu-system-x86_64 -accel kvm -m 512 -nographic -serial mon:stdio -kernel /boot/vmlinuz-$(uname -r) -append "console=ttyS0" 2>&1 | head
   ```
   (Press `Ctrl-a x` to quit.) This is **virtualization**: same architecture, native CPU execution, only sensitive operations trap.

2. Now force **pure emulation** with the Tiny Code Generator (no KVM):

   ```bash
   qemu-system-x86_64 -accel tcg -m 512 -nographic ...
   ```
   Same guest, but every guest instruction is binary-translated in software. It boots noticeably slower. TCG needs no VT-x/AMD-V — which is exactly why it also lets you run a *foreign* architecture.

3. Demonstrate cross-architecture **emulation**: run an ARM or RISC-V machine on your x86 host — impossible with virtualization, routine with emulation:

   ```bash
   qemu-system-aarch64 -M virt -cpu cortex-a57 -m 256 -nographic 2>&1 | head
   ```
   The x86 CPU has no ARM mode; QEMU *emulates* the entire ARM machine so real ARM software runs.

4. Fix the three terms in your head:
   - **Virtualization** — guest instructions execute directly on the physical CPU (KVM/VT-x/AMD-V); only privileged/sensitive ops trap. Same ISA, near-native speed.
   - **Emulation** — software imitates hardware (including a possibly *different* CPU ISA) so unmodified guest software runs where the real hardware is absent. Architecture-independent, slow (QEMU + TCG).
   - **Simulation** — a model that *reproduces the behaviour* of a system for analysis, testing or teaching, not necessarily to run the production binaries at fidelity or speed (e.g. a cycle-accurate CPU model, a network simulator). The intent is study/prediction, not to *be* the machine.

> **Checkpoint 5**
> - **Q5.1** You need to run an unmodified `ppc64le` distro image on your x86_64 laptop. Can KVM do it? Emulation? Explain why in terms of the CPU's instruction set.
> - **Q5.2** In one sentence each, what is the *purpose* difference between emulation and simulation, even though both "model" hardware?
> - **Q5.3** Two guests run on the same x86 host: one with `-accel kvm`, one with `-accel tcg` (x86 guest, no foreign arch). Which is faster and why — and which one would still work if VT-x were disabled in firmware?

---

## Exercise 6 — VM lifecycle features: snapshot, pause, clone, resource limits

**Goal:** exercise the operational features LPI lists — snapshotting, pausing, cloning and resource limits — with `libvirt`/`virsh`. *Do these on a throwaway guest.* We assume a stopped guest named `lab01` backed by a **qcow2** disk (internal snapshots require qcow2, not raw).

1. Create the lab guest if you do not have one (imports an existing qcow2, does not boot an installer):

   ```bash
   sudo virt-install --name lab01 --memory 1024 --vcpus 2 \
     --disk /var/lib/libvirt/images/lab01.qcow2,format=qcow2 \
     --import --os-variant generic --noautoconsole
   sudo virsh list --all
   ```

2. **Snapshot** the running guest (captures disk *and* live RAM by default with an internal qcow2 snapshot):

   ```bash
   sudo virsh snapshot-create-as --domain lab01 --name clean-base \
     --description "fresh install, before changes"
   sudo virsh snapshot-list lab01
   ```
   *Example output:*
   ```
    Name         Creation Time               State
   ------------------------------------------------------
    clean-base   2026-08-11 09:40:12 -0300   running
   ```
   Break something in the guest, then roll back:
   ```bash
   sudo virsh snapshot-revert lab01 clean-base
   ```
   Inspect the snapshot as stored inside the disk image itself:
   ```bash
   sudo qemu-img snapshot -l /var/lib/libvirt/images/lab01.qcow2
   ```

3. **Pause** vs **save**. `suspend` freezes the vCPUs but keeps the whole guest in host RAM (state becomes `paused`); `save` serialises RAM to a file and stops the guest, freeing that memory:

   ```bash
   sudo virsh suspend lab01     # vCPUs frozen, RAM still resident; state = paused
   sudo virsh domstate lab01
   sudo virsh resume lab01      # continues exactly where it stopped

   sudo virsh save lab01 /var/lib/libvirt/save/lab01.save   # RAM -> disk, guest stops
   sudo virsh restore /var/lib/libvirt/save/lab01.save      # reload state
   ```

4. **Clone** the guest — copies the disk and regenerates identity (new UUID and NIC MAC) so the two can coexist:

   ```bash
   sudo virsh shutdown lab01
   sudo virt-clone --original lab01 --name lab02 --auto-clone
   sudo virsh domiflist lab02   # note the new MAC address
   ```

5. **Resource limits.** Adjust CPU and memory live, and cap CPU time through cgroups:

   ```bash
   # vCPUs (must be <= the domain's maximum)
   sudo virsh setvcpus lab01 1 --live

   # Memory via the balloon driver (up to the configured maximum)
   sudo virsh setmem lab01 512M --live

   # CPU scheduling caps enforced by cgroups: quota/period in microseconds.
   # 50000/100000 = at most 50% of one physical CPU-second per vCPU.
   sudo virsh schedinfo lab01
   sudo virsh schedinfo lab01 --set vcpu_quota=50000 --set vcpu_period=100000 --live

   # A hard ceiling on RSS (khz/KiB); the kernel will not let the guest exceed it
   sudo virsh memtune lab01 --hard-limit 1048576 --live
   ```
   *Example `schedinfo` output:*
   ```
   Scheduler      : posix
   cpu_shares     : 1024
   vcpu_period    : 100000
   vcpu_quota     : 50000
   ```

> **Checkpoint 6**
> - **Q6.1** You take an *internal* snapshot of a running guest with the default `virsh snapshot-create-as`. Two things are captured — what are they? And why does this command fail if the disk is a `raw` image?
> - **Q6.2** Distinguish `virsh suspend` from `virsh save`. After each, what has happened to (a) the guest's vCPUs and (b) the host RAM the guest was using?
> - **Q6.3** After `virt-clone`, why must the MAC address and UUID be regenerated rather than copied? Give the concrete failure that a straight byte-copy would cause on the network.
> - **Q6.4** `vcpu_quota=50000` with `vcpu_period=100000` — express the resulting CPU cap in plain terms, and name the Linux kernel subsystem that actually enforces it.

---

## Exercise 7 — Migration: P2V and V2V, offline and live

**Goal:** understand the major aspects of moving workloads *into* virtualization (P2V), *between* hypervisors (V2V), and *between hosts* (live migration), plus their prerequisites.

1. **V2V** — convert a guest from a foreign hypervisor into KVM/libvirt. `virt-v2v` imports the disk, then installs the `virtio` drivers so the result runs efficiently under KVM (dry-run inspection shown):

   ```bash
   # From a VMware OVA export into the local libvirt/KVM
   sudo virt-v2v -i ova exported-vm.ova -o libvirt -os default
   ```
   *Example tail of output:*
   ```
   [  62.0] Converting Ubuntu 22.04 to run on KVM
   [ 140.4] Installing virtio drivers
   [ 155.9] Creating output metadata
   [ 156.2] Finishing off
   ```

2. **P2V** — a running *physical* machine has no export file, so `virt-p2v` boots that machine from a small live image and streams its disks over the network to a conversion server that runs `virt-v2v`. Conceptually: **boot the physical host from the virt-p2v ISO → point it at a conversion server → it lands as a KVM guest.** (No command to run here unless you have spare hardware; know the flow.)

3. **Live migration between hosts** — move a *running* guest to another host with minimal downtime. libvirt copies the guest's RAM in iterative passes while it keeps running, then does a final brief pause to transfer the last dirty pages:

   ```bash
   sudo virsh migrate --live --verbose lab01 qemu+ssh://root@host-b/system
   ```
   *Example output:*
   ```
   Migration: [100 %]
   ```

4. Know the **prerequisites**, because migration fails loudly without them:
   - **Storage** must be reachable identically on both hosts — shared storage (NFS/iSCSI/Ceph). Without it, add `--copy-storage-all` to also stream the disk (much slower).
   - **CPU compatibility** — the destination CPU must expose at least the features the guest was started with; otherwise use a common baseline CPU model (e.g. libvirt's `host-model`/named models). Migrating from a newer to an older micro-architecture without a compatible model is the classic failure.
   - **Connectivity/auth** between hosts (here `qemu+ssh`), and the same emulator/machine type available on both.
   - Use `--offline` to migrate only the *configuration* of a **stopped** guest (no RAM transfer).

> **Checkpoint 7**
> - **Q7.1** Define **P2V** and **V2V** in one line each, and explain why P2V needs an extra step (a boot medium) that V2V from an OVA does not.
> - **Q7.2** During a `--live` migration, the guest keeps running while its memory is copied. What problem does that create for pages the guest keeps writing, and how does the iterative pre-copy algorithm converge to a final, very short pause?
> - **Q7.3** A live migration aborts with a CPU-feature error. The guest was started on an Intel Ice Lake host and the destination is an older Haswell host. What is the root cause, and what is the standard fix that lets the guest migrate across both?
> - **Q7.4** You have no shared storage. Which single flag lets `virsh migrate` still succeed, and what is the cost you accept by using it?

---

## Exercise 8 — Awareness: oVirt, Proxmox, systemd-machined, VirtualBox, Open vSwitch

**Goal:** recognise the ecosystem tools LPI expects you to be *aware of* — what each is, and the one command that fronts it.

1. **systemd-machined** registers and tracks local VMs and containers. List and inspect them:

   ```bash
   machinectl list
   machinectl status <name>
   ```
   *Example output:*
   ```
   MACHINE   CLASS     SERVICE        OS       VERSION  ADDRESSES
   web-ct    container systemd-nspawn debian   12       10.0.0.5
   ```
   `machined` is a registry/coordinator (login, shell, status), *not* a hypervisor — it sits above `systemd-nspawn` containers and VMs that register with it.

2. **Open vSwitch (OVS)** — a programmable multilayer virtual switch used to connect VMs, with VLANs, tunnels (VXLAN/GRE) and OpenFlow. Build a bridge and inspect it:

   ```bash
   sudo ovs-vsctl add-br br0
   sudo ovs-vsctl add-port br0 eth1
   sudo ovs-vsctl show
   sudo ovs-ofctl dump-flows br0
   ```
   libvirt attaches a guest to OVS via `<virtualport type='openvswitch'/>` in the domain XML; OpenStack Neutron is a heavy OVS consumer.

3. **Proxmox VE** — a Debian-based platform that manages **KVM VMs** with `qm` and **LXC containers** with `pct`, plus clustering with `pvecm` (commands shown for recognition; run only on a Proxmox node):

   ```bash
   qm list            # KVM VMs
   pct list           # LXC containers
   qm migrate 100 pve-node2 --online
   ```

4. **oVirt** — an open-source datacenter virtualization *management platform* on top of KVM/libvirt. A central **engine** drives many hosts; each host runs the **VDSM** agent that talks to libvirt. It manages clusters, storage domains and live migration centrally (the upstream of Red Hat Virtualization).

5. **VirtualBox** — a **Type-2 (hosted)** hypervisor for the desktop, scripted with `VBoxManage`:

   ```bash
   VBoxManage list vms
   VBoxManage list runningvms
   VBoxManage modifyvm "lab01" --memory 2048 --cpus 2
   ```
   `systemd-detect-virt` reports a VirtualBox guest as `oracle`.

> **Checkpoint 8**
> - **Q8.1** Both oVirt and Proxmox ultimately run guests on KVM/libvirt. What layer do they add on top, and what is the practical difference in scope between `virsh` on a single host and an oVirt engine?
> - **Q8.2** Is `systemd-machined` a hypervisor? If not, what is its actual job, and name one backend whose instances it tracks.
> - **Q8.3** Why would you reach for Open vSwitch instead of a plain Linux bridge (`brctl`/`ip link`) when wiring up VMs — name two capabilities OVS adds.
> - **Q8.4** On the Type-1 / Type-2 axis, where do KVM and VirtualBox each fall, and which one is the natural choice for a developer's laptop versus a datacenter host?

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 1
- **Q1.1** `vmx` is the *Intel* VT-x flag; AMD exposes its equivalent as **`svm`** (AMD-V). Grepping only for `vmx` on an AMD CPU returns 0 even though virtualization is fully supported. The portable check is `grep -E 'vmx|svm' /proc/cpuinfo`.
- **Q1.2** The extension is **disabled in firmware (BIOS/UEFI)**. The CPU is *capable* (so `lscpu`, reading CPUID capability bits, still prints `VT-x`), but because it is switched off, the kernel does not expose the `vmx` flag in `/proc/cpuinfo` and `kvm-ok` reports it unusable. Fix: reboot into UEFI/BIOS and enable "Intel Virtualization Technology / VT-x" (or "SVM Mode" on AMD).
- **Q1.3** `ept`/`npt` provide **SLAT (Second Level Address Translation)** — the CPU translates guest-physical to host-physical addresses in hardware. It replaces software-maintained **shadow page tables**, eliminating the expensive VM exits the hypervisor previously took on every guest page-table change, so memory-heavy workloads run much closer to native speed.

### Exercise 2
- **Q2.1** No — it is the **host**. `xen-dom0` is the privileged control domain of a Xen hypervisor. Even though Xen (a Type-1 hypervisor) runs beneath it, dom0 *is* the management OS with direct hardware access, so `systemd-detect-virt` treats it as "not a guest" and prints `none`, while `virt-what` more precisely reports the Xen context and the dom0 role.
- **Q2.2** It reports **`lxc`** (the container technology), because with no flag `systemd-detect-virt` reports the **innermost / closest** virtualization layer, and it detects containerization before VM-level virtualization. To see the VM layer you would ask explicitly with `--vm`.
- **Q2.3** The `hypervisor` flag is set by the hypervisor's CPUID emulation, which it is free not to set — e.g. a classic **Xen PV** guest runs a Xen-aware kernel and does not present a standard emulated CPUID with the flag, and some hypervisors can be configured to hide it (to defeat anti-VM checks). And its *absence* is inconclusive on its own, so you corroborate with DMI strings, `systemd-detect-virt` and `virt-what`.

### Exercise 3
- **Q3.1** KVM turns the Linux kernel itself into the hypervisor: guest vCPUs are scheduled straight onto the physical CPU through VT-x/AMD-V with no host OS mediating instruction execution — that is the Type-1 (bare-metal) property, and the fact that the kernel is also a general-purpose OS does not change it. VirtualBox is **Type-2 (hosted)**: it runs as an ordinary application/driver *on top of* the host OS, which owns the hardware and schedules it.
- **Q3.2** **KVM** (the kernel module, via VT-x/AMD-V) executes the guest's privileged ring-0 instructions on the physical CPU. **QEMU** (userspace) provides the device model — it emulates the disk controller, NIC, and other peripherals.
- **Q3.3** Nested virtualization must be enabled on the **host's** hypervisor module: `/sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) must read `Y`/`1`. Only then does the outer guest get to use VT-x/AMD-V for its own inner guests.

### Exercise 4
- **Q4.1** *Full virtualization (HVM):* the guest OS runs **unmodified**; sensitive/privileged instructions are trapped and handled by the hypervisor using hardware extensions (VT-x/AMD-V) plus emulated devices. *Paravirtualization (PV):* the guest OS is **modified/aware** it is virtualized and cooperates via **hypercalls** instead of trapping, needing no CPU virtualization extensions. HVM can boot an unmodified, off-the-shelf OS image.
- **Q4.2** Because unmodified/emulated devices (e.g. an `e1000` NIC, IDE disk) are correct but slow — every register access causes a trap into the host. `virtio` is a **paravirtualized I/O** path: the guest driver and host share ring buffers (`virtqueues`), batching I/O and slashing the number of exits. So HVM gives you CPU virtualization; `virtio` adds fast *device* virtualization on top. (This combination is PVHVM.)
- **Q4.3** `dom0` = the privileged control domain that owns the hardware and runs the toolstack; **it has direct hardware access.** `domU` = an unprivileged guest domain. `PVH` = a lightweight guest mode using hardware virtualization for CPU/MMU but paravirtual interfaces for boot and I/O, with no QEMU device emulation.

### Exercise 5
- **Q5.1** KVM **cannot** — it runs guest instructions directly on the physical CPU, which only understands x86_64; a `ppc64le` binary is a different instruction set with no native execution path. **Emulation can** — QEMU with TCG translates each `ppc64le` instruction into x86 instructions at runtime, so the foreign image runs (slowly) regardless of the host ISA.
- **Q5.2** *Emulation:* imitate real hardware faithfully enough to **run the actual production software** in place of the real machine. *Simulation:* model a system's behaviour to **study, test or predict** it — the goal is analysis, not being a drop-in replacement that runs the real binaries at fidelity/speed.
- **Q5.3** The `-accel kvm` guest is faster because its instructions run natively on the CPU; the `-accel tcg` guest pays for software binary translation of every instruction. Only the **TCG** guest would still work with VT-x disabled — emulation needs no hardware virtualization extensions, whereas KVM refuses to start without them.

### Exercise 6
- **Q6.1** It captures the **disk state** *and* the **live RAM/CPU state** (a running-VM snapshot you can revert to as if the machine never stopped). It fails on a `raw` disk because **internal snapshots are a qcow2 feature** — the snapshot data and metadata live *inside* the qcow2 file; raw has no such container (you would need an *external* snapshot instead).
- **Q6.2** `suspend`: vCPUs are **frozen** (state `paused`) but the guest's memory **stays resident in host RAM** — instant resume, no memory freed. `save`: vCPUs are **stopped** and the guest's RAM is **serialised to a file on disk**, so the host memory *is* freed; you must `restore` from the file to continue.
- **Q6.3** UUID and MAC are unique identifiers. Two live guests with the **same MAC** on one L2 segment cause an address collision — ARP/switch confusion, dropped or misdirected frames, and (if DHCP keys on MAC) both machines fighting over one lease. `virt-clone` regenerates them so the clone is a distinct network entity.
- **Q6.4** The guest is capped at **50% of one physical CPU** per vCPU (50000 µs of runtime per 100000 µs period). It is enforced by the Linux **cgroups** CPU controller (CFS bandwidth control: `cpu.cfs_quota_us` / `cpu.cfs_period_us`), which libvirt configures.

### Exercise 7
- **Q7.1** **P2V** = migrate a *physical* machine's OS/data into a virtual machine. **V2V** = convert a *virtual* machine from one hypervisor/format into another (e.g. VMware → KVM). P2V needs a boot medium because a running physical host has no export file and can't image its own live root filesystem cleanly, so `virt-p2v` boots it from a helper image to stream the disks out; a V2V from an OVA already has a self-contained exported disk to read.
- **Q7.2** While RAM is being copied the guest keeps **dirtying pages** that were already sent, so those must be re-sent. Pre-copy iterates: send all pages, then send only the pages dirtied since the last pass, each pass smaller than the last. When the remaining dirty set is small enough to transfer within the downtime target, the guest is **briefly paused**, the last pages and CPU state are copied, and it resumes on the destination — a sub-second stop for a converging workload.
- **Q7.3** The guest was started exposing Ice Lake CPU features that **do not exist on the older Haswell destination**, so the destination cannot honour the guest's CPU model. Fix: start guests with a **common baseline CPU model** both hosts support (a named model at the lowest common denominator, or a cluster-wide `custom`/`host-model` policy) so the feature set is portable across the fleet.
- **Q7.4** `--copy-storage-all` (or `--copy-storage-inc`) makes `virsh migrate` also stream the disk image to the destination. The cost is a much larger data transfer and longer migration time, since you are moving the whole disk over the network in addition to RAM.

### Exercise 8
- **Q8.1** They add a **management/orchestration layer** (web UI, API, clustering, centralized storage and scheduling) above KVM/libvirt. `virsh` manages guests on a **single host**; an oVirt engine manages **many hosts as a datacenter** — pools, shared storage domains, HA, and centrally driven live migration.
- **Q8.2** No. `systemd-machined` is a **registry/coordinator** that tracks and provides access (list, status, login, shell) to local virtual machines and containers; it does not execute guests. One backend it tracks: **`systemd-nspawn`** containers (it also tracks registered VMs).
- **Q8.3** OVS adds programmability and features a plain bridge lacks — for example: **OpenFlow-based flow control**, native **VLAN tagging/trunking**, overlay **tunnels (VXLAN/GRE)**, per-port QoS, and centralized SDN control (any two of these). A Linux bridge is a simple L2 learning switch by comparison.
- **Q8.4** **KVM = Type-1 (bare-metal)**, the natural choice for a datacenter host; **VirtualBox = Type-2 (hosted)**, the natural choice for a developer's laptop where it runs as an app on top of the desktop OS.

</details>

---

**Sources**
- LPI — Exam 305 Objectives (351.1): https://www.lpi.org/our-certifications/exam-305-objectives/
- KVM project documentation: https://linux-kvm.org/page/Documentation
- QEMU documentation (accelerators, `virtio`, system emulation): https://www.qemu.org/docs/master/
- libvirt — domain lifecycle, snapshots, migration: https://libvirt.org/docs.html and https://libvirt.org/migration.html
- Linux kernel `virtio` and nested virtualization docs: https://docs.kernel.org/ and https://www.kernel.org/doc/html/latest/virt/kvm/
- Xen Project — PV/HVM/PVH and dom0/domU: https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview
- `systemd-detect-virt` / `systemd-machined` / `machinectl`: https://www.freedesktop.org/software/systemd/man/latest/systemd-detect-virt.html and https://www.freedesktop.org/software/systemd/man/latest/machinectl.html
- `virt-v2v` / `virt-p2v`: https://libguestfs.org/virt-v2v.1.html and https://libguestfs.org/virt-p2v.1.html
- Open vSwitch documentation: https://docs.openvswitch.org/
- Proxmox VE administration guide: https://pve.proxmox.com/pve-docs/
- oVirt documentation: https://www.ovirt.org/documentation/
- Oracle VM VirtualBox manual (`VBoxManage`): https://www.virtualbox.org/manual/