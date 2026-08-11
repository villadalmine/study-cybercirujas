# 351.2 Xen — Guided Exercises

> **Exam:** LPIC-3 305-300 (v3.0) · **Topic 351.2 Xen** · **Weight 5**
> **Focus:** Xen 4.x, the `xl`/libxenlight toolstack, PV and HVM domains, virtual devices, XenStore, boot parameters, and awareness of `xm`/XAPI.

**Lab prerequisites**

- A physical host (or nested-virt-capable VM with `hvm` support) running a Xen 4.x hypervisor with a Linux **Dom0** (Debian 12 + `xen-hypervisor-amd64` and `xen-utils-4.17` is assumed in the sample outputs).
- Root privileges in Dom0. All `xl`/`xenstore-*` commands below run **inside Dom0**.
- A bridge named `xenbr0` and an LVM volume group `vg0` for guest disks.
- Outputs shown are representative; hostnames, IDs, UUIDs and timings will differ on your system.

Sources are cited inline and consolidated at the end.

---

## Exercise 1 — Confirm Dom0 and read the hypervisor's view of the machine

Xen is a **type-1 (bare-metal) hypervisor**: it boots first, then starts a privileged control domain, **Domain-0 (Dom0)**, which owns the drivers and the toolstack. Unprivileged guests are **DomU**. Your first job on any Xen host is to prove you are actually *in* Dom0 and to read the hypervisor's inventory.

1. Confirm the running kernel sees a Xen hypervisor underneath it:

   ```bash
   cat /sys/hypervisor/type
   ```
   ```
   xen
   ```

2. Confirm this is the **control domain** (Dom0 is always domain ID 0):

   ```bash
   ls -d /proc/xen && cat /sys/hypervisor/properties/capabilities
   ```
   ```
   /proc/xen
   control_d
   ```
   The string `control_d` is present only in Dom0.

3. Ask the hypervisor to describe the physical host and itself:

   ```bash
   xl info
   ```
   ```
   host                   : xen-node01
   release                : 6.1.0-18-amd64
   version                : #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1
   machine                : x86_64
   nr_cpus                : 8
   cores_per_socket       : 4
   threads_per_core       : 2
   cpu_mhz                : 3600.000
   virt_caps              : hvm hvm_directio
   total_memory           : 32611
   free_memory            : 27890
   xen_major              : 4
   xen_minor              : 17
   xen_version            : 4.17.3
   xen_caps               : xen-3.0-x86_64 hvm-3.0-x86_32 hvm-3.0-x86_32p hvm-3.0-x86_64
   xen_scheduler          : credit2
   xen_commandline        : placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 ...
   ```

4. List the running domains:

   ```bash
   xl list
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     124.5
   ```

5. Read the hypervisor's own boot ring buffer (distinct from the Dom0 kernel's `dmesg`):

   ```bash
   xl dmesg | head -n 20
   ```
   ```
   (XEN) Xen version 4.17.3 (Debian 4.17.3+10-...) ...
   (XEN) Latest ChangeSet: ...
   (XEN) Command line: placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 ...
   (XEN) Xen is relinquishing VGA console.
   ```

**Comprehension check**

- **Q1.1** How do you tell, from `/sys/hypervisor/`, that you are in Dom0 and not an ordinary DomU?
- **Q1.2** In `xl info`, what does the `xen_caps` line tell you about which guest *types* this host can run, and why does it matter before you try to start an HVM guest?
- **Q1.3** Why is `xl dmesg` different information from the Linux `dmesg` command, and when would you reach for it?
- **Q1.4** In `xl list`, decode the State column entry `r-----` and name three other state flags you might see.

---

## Exercise 2 — Xen boot parameters (hypervisor vs. Dom0 kernel)

On a Xen system the bootloader loads **two** things: `xen.gz` (the hypervisor) and the Dom0 `vmlinuz` (a normal Linux kernel). They take **separate** command lines. Confusing them is a classic exam trap: `dom0_mem` is a *hypervisor* argument, not a kernel argument.

1. Inspect how GRUB assembles the two command lines on Debian/Ubuntu:

   ```bash
   grep -R "GRUB_CMDLINE_XEN\|GRUB_CMDLINE_LINUX" /etc/default/grub /etc/default/grub.d/ 2>/dev/null
   ```
   ```
   /etc/default/grub.d/xen.cfg:GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin"
   /etc/default/grub:GRUB_CMDLINE_LINUX_DEFAULT="quiet"
   ```
   - `GRUB_CMDLINE_XEN*` → arguments to **`xen.gz`** (the hypervisor).
   - `GRUB_CMDLINE_LINUX*` → arguments to the **Dom0 kernel**.

2. Pin Dom0 to a fixed memory size and CPU count (prevents Dom0 memory from ballooning, which is best practice on a hypervisor). Edit `/etc/default/grub.d/xen.cfg`:

   ```
   GRUB_CMDLINE_XEN_DEFAULT="dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all"
   ```

3. Regenerate the boot configuration and inspect the generated `multiboot` stanza:

   ```bash
   update-grub
   grep -A3 "multiboot" /boot/grub/grub.cfg | head -n 8
   ```
   ```
   multiboot   /boot/xen-4.17.gz placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all
   module      /boot/vmlinuz-6.1.0-18-amd64 placeholder root=/dev/mapper/vg0-root ro quiet
   module      /boot/initrd.img-6.1.0-18-amd64
   ```
   Note the layout: `multiboot` = hypervisor, first `module` = Dom0 kernel, second `module` = initrd.

4. After a reboot, verify the hypervisor actually received your arguments (without trusting the config file):

   ```bash
   xl info -n | grep xen_commandline
   grep -i "command line\|dom0_max_vcpus\|NR_CPUS" /var/log/xen/*.log 2>/dev/null
   ```
   ```
   xen_commandline        : placeholder dom0_mem=4096M,max:4096M dom0_max_vcpus=4 dom0_vcpus_pin loglvl=all guest_loglvl=all
   ```

**Comprehension check**

- **Q2.1** A colleague adds `dom0_mem=2G` to `GRUB_CMDLINE_LINUX_DEFAULT` and reboots, but Dom0 still balloons. Explain the mistake.
- **Q2.2** What is the practical purpose of pinning Dom0 with `dom0_mem=…,max:…` and `dom0_max_vcpus` + `dom0_vcpus_pin` on a production hypervisor?
- **Q2.3** Which single command proves, at runtime, exactly which parameters the *hypervisor* booted with?
- **Q2.4** On the `multiboot`/`module` lines, which entry is the hypervisor and which is the Dom0 kernel?

---

## Exercise 3 — Define and boot a PV DomU with `xl.cfg`

A **PV (paravirtualized) DomU** has no emulated BIOS or hardware: the guest kernel is Xen-aware and talks to the hypervisor through hypercalls and split (front-end/back-end) drivers. Its disks appear as `xvdX` and its console is `hvc0`.

1. Create an LVM backing disk for the guest:

   ```bash
   lvcreate -L 8G -n pv-guest01 vg0
   ```
   ```
   Logical volume "pv-guest01" created.
   ```

2. Write the domain configuration `/etc/xen/pv-guest01.cfg`. This uses `pygrub` so the *guest's own* kernel is booted from inside its disk image:

   ```python
   # /etc/xen/pv-guest01.cfg
   name        = "pv-guest01"
   type        = "pvh"                     # Xen 4.x: "pv", "pvh", or "hvm"
   memory      = 1024
   maxmem      = 2048
   vcpus       = 2

   # Boot the kernel that lives inside the guest filesystem:
   bootloader  = "pygrub"

   vif  = [ 'bridge=xenbr0, mac=00:16:3e:1a:2b:01' ]
   disk = [ 'phy:/dev/vg0/pv-guest01,xvda,w' ]

   on_poweroff = "destroy"
   on_reboot   = "restart"
   on_crash    = "restart"
   ```

   > For a truly classic PV guest whose kernel lives in **Dom0**, you would instead use `kernel=`, `ramdisk=`, and `extra="root=/dev/xvda1 ro console=hvc0"` and drop `bootloader`.

3. Start the domain and attach to its console in one step (`-c`):

   ```bash
   xl create -c /etc/xen/pv-guest01.cfg
   ```
   ```
   Parsing config from /etc/xen/pv-guest01.cfg
   [    0.000000] Linux version 6.1.0-18-amd64 ...
   ...
   pv-guest01 login:
   ```
   Detach from the console with **`Ctrl-]`** (this leaves the guest running).

4. Confirm the guest is up and inspect it from Dom0:

   ```bash
   xl list
   xl uptime pv-guest01
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     210.7
   pv-guest01                       1  1024     2     -b----      14.2

   Name                                ID   Uptime
   pv-guest01                           1   0 days,  0:02:41
   ```

5. Re-attach to the console later, then perform a clean ACPI-style shutdown:

   ```bash
   xl console pv-guest01      # Ctrl-] to leave again
   xl shutdown pv-guest01     # graceful; xl destroy would be the hard power-off
   ```

**Comprehension check**

- **Q3.1** Why do PV guest disks appear as `xvda` and the console as `hvc0` instead of `sda`/`ttyS0`?
- **Q3.2** What is the difference between using `bootloader = "pygrub"` and specifying `kernel=`/`ramdisk=` directly in the config? Where does the kernel come from in each case?
- **Q3.3** In the `disk` line `'phy:/dev/vg0/pv-guest01,xvda,w'`, identify the three fields and the meaning of `w`.
- **Q3.4** What is the operational difference between `xl shutdown` and `xl destroy`, and which one risks filesystem corruption?

---

## Exercise 4 — Define and boot an HVM DomU

An **HVM (hardware-virtualized) DomU** uses CPU virtualization extensions (Intel VT-x / AMD-V) plus an emulated platform (QEMU device model) so it can run **unmodified** operating systems — a stock Windows or a distro kernel with no Xen support. It sees an emulated BIOS, IDE/SATA disks (`hda`/`sda`), and a VGA display you reach over VNC.

1. Create the disk and drop an install ISO in place:

   ```bash
   lvcreate -L 20G -n hvm-guest01 vg0
   ```

2. Write `/etc/xen/hvm-guest01.cfg`:

   ```python
   # /etc/xen/hvm-guest01.cfg
   name        = "hvm-guest01"
   type        = "hvm"                     # legacy syntax: builder = "hvm"
   memory      = 2048
   vcpus       = 2

   # Emulated NIC model + PV-aware NIC both work; e1000 is broadly compatible:
   vif  = [ 'bridge=xenbr0, model=e1000, mac=00:16:3e:1a:2b:02' ]
   disk = [ 'phy:/dev/vg0/hvm-guest01,hda,w',
            'file:/srv/iso/debian-12-netinst.iso,hdc:cdrom,r' ]

   boot        = "dc"                      # try disk (d) then CD-ROM (c)
   vnc         = 1
   vnclisten   = "127.0.0.1"
   vncdisplay  = 0                         # → TCP 5900
   serial      = "pty"
   ```

3. Start it (no `-c`: HVM guests boot a graphical console, not a serial one by default):

   ```bash
   xl create /etc/xen/hvm-guest01.cfg
   xl list
   ```
   ```
   Name                            ID   Mem VCPUs      State   Time(s)
   Domain-0                         0  4096     4     r-----     305.1
   pv-guest01                       1  1024     2     -b----      45.0
   hvm-guest01                      2  2048     2     r-----       6.4
   ```

4. Find and connect to its VNC console. Xen also records the VNC port in XenStore:

   ```bash
   xl vncviewer hvm-guest01            # or: vncviewer 127.0.0.1:0
   xenstore-read /local/domain/2/console/vnc-port
   ```
   ```
   5900
   ```

5. Confirm the guest uses the QEMU device model (a per-HVM-domain user-space process in Dom0):

   ```bash
   pgrep -af "qemu.*hvm-guest01"
   ```
   ```
   4821 /usr/lib/xen-4.17/bin/qemu-system-i386 -xen-domid 2 -name hvm-guest01 ...
   ```

**Comprehension check**

- **Q4.1** Name two `xl info` fields you would check *before* attempting to run an HVM guest, and what values you need.
- **Q4.2** Why does an HVM guest need a per-domain QEMU process in Dom0 while a pure PV guest does not?
- **Q4.3** In the HVM config, why is the disk exposed as `hda` (not `xvda`), and what does `boot = "dc"` do?
- **Q4.4** What is a "PV-on-HVM" (or PVHVM) guest, and why is it usually preferred over plain HVM for a modern Linux guest?

---

## Exercise 5 — Virtual network and storage devices (inspect and hot-plug)

Xen presents guests with **virtual network devices (`vif`)** and **virtual block/storage devices (`vbd`)** implemented as split drivers: a back-end in Dom0 and a front-end in the guest, communicating over shared memory rings advertised in XenStore.

1. Enumerate a running guest's virtual devices from Dom0:

   ```bash
   xl network-list pv-guest01
   xl block-list   pv-guest01
   ```
   ```
   Idx BE Mac Addr.          handle state evt-ch   tx-/rx-ring-ref BE-path
   0   0  00:16:3e:1a:2b:01  0      4     14       768/769         /local/domain/0/backend/vif/1/0

   Vdev  BE  handle state evt-ch ring-ref BE-path
   51712 0   1      4     11     8        /local/domain/0/backend/vbd/1/51712
   ```
   `Vdev 51712` is the encoded number for `xvda` (see Q5.2).

2. Confirm the Dom0 back-end interface exists and is enslaved to the bridge:

   ```bash
   ip link show | grep -i "vif1\|xenbr0"
   bridge link
   ```
   ```
   7: vif1.0@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> master xenbr0 state UP ...
   ```

3. **Hot-attach** a second network interface to the running guest, verify, then detach:

   ```bash
   xl network-attach pv-guest01 'bridge=xenbr0, mac=00:16:3e:1a:2b:99'
   xl network-list  pv-guest01
   xl network-detach pv-guest01 1        # detach vif idx 1
   ```

4. **Hot-attach** an extra disk to the running guest and detach it:

   ```bash
   lvcreate -L 4G -n pv-guest01-data vg0
   xl block-attach pv-guest01 'phy:/dev/vg0/pv-guest01-data,xvdb,w'
   xl block-list   pv-guest01
   xl block-detach pv-guest01 xvdb
   ```

5. Live-tune the guest's resources (balloon memory, add/remove a vCPU) — all online, no reboot:

   ```bash
   xl mem-set  pv-guest01 1536m      # within maxmem set in the config
   xl vcpu-set pv-guest01 3
   xl vcpu-list pv-guest01
   ```
   ```
   Name          ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)
   pv-guest01     1     0     4   -b-      20.1  all / all
   pv-guest01     1     1     6   -b-      18.7  all / all
   pv-guest01     1     2     0   --p       0.0  all / all
   ```

**Comprehension check**

- **Q5.1** In the split-driver model, where does the *back-end* of a `vif` live and where does the *front-end* live?
- **Q5.2** `xl block-list` shows `Vdev 51712` for `xvda`. Using the encoding `(202 << 8) + minor` for the `xvd` major 202, verify that 51712 corresponds to `xvda`. What would `xvdb` be?
- **Q5.3** Why can `xl mem-set pv-guest01 1536m` succeed while `xl mem-set pv-guest01 4096m` fails, given the config in Exercise 3?
- **Q5.4** After `xl network-attach`, the Dom0 side shows an interface like `vif1.1`. Decode that name.

---

## Exercise 6 — XenStore: the shared configuration and status database

**XenStore** is a small hierarchical, transactional key/value database maintained by the hypervisor/Dom0 (`xenstored`) and shared with every domain. Toolstack, back-end and front-end drivers, and management tools all rendezvous through it. It is *not* a general datastore — it holds device configuration, run-state, and control keys.

1. List the top-level tree and the per-domain subtree:

   ```bash
   xenstore-ls /local/domain
   ```
   ```
   0 = ""
    name = "Domain-0"
    domid = "0"
    backend = ""
     vif = ""
      1 = ""
       0 = "..."
   1 = ""
    name = "pv-guest01"
    domid = "1"
    vm = "/vm/6f9a...-..."
    device = ""
     vbd = ""
      51712 = "..."
     vif = ""
      0 = "..."
   ```

2. Read individual keys (note: paths use the domain **ID**, not the name):

   ```bash
   xenstore-read /local/domain/1/name
   xenstore-read /local/domain/1/memory/target
   xenstore-list /local/domain/1/device
   ```
   ```
   pv-guest01
   1572864
   vbd
   vif
   ```
   `memory/target` is in KiB → 1572864 KiB = 1536 MiB, matching the `xl mem-set` from Exercise 5.

3. Follow a guest's front-end/back-end handshake. The **state** key is an integer from the XenBus state machine (`1=Initialising`, `4=Connected`, `6=Closed`):

   ```bash
   xenstore-read /local/domain/1/device/vbd/51712/state
   xenstore-read /local/domain/0/backend/vbd/1/51712/state
   ```
   ```
   4
   4
   ```
   Both `4` (Connected) means the split driver is fully wired up.

4. Write and remove a scratch key (understand it is a live control plane, so tread carefully on real keys):

   ```bash
   xenstore-write   /local/domain/1/data/note "lab-6-marker"
   xenstore-read    /local/domain/1/data/note
   xenstore-rm      /local/domain/1/data/note
   ```

**Comprehension check**

- **Q6.1** Name three distinct *kinds* of information Xen keeps in XenStore. What is it explicitly *not* meant to store?
- **Q6.2** A `vif` shows front-end state `4` but back-end state `2`. What does that mismatch tell you about the device, and what is state `4` called?
- **Q6.3** XenStore paths are keyed by numeric domain ID. Why is that a subtle hazard when scripting against a guest across a reboot/migration?
- **Q6.4** Which daemon serves XenStore, and how does a freshly booted DomU access it without a network?

---

## Exercise 7 — Toolstack awareness: `xl` vs. `xm`, XAPI/`xe`, `xl.conf`, and migration

Xen has had several toolstacks. The exam expects you to **recognize** each and know the current default.

1. Inspect the **global** `xl` configuration (defaults applied to every domain), `/etc/xen/xl.conf`:

   ```bash
   grep -vE '^\s*#|^\s*$' /etc/xen/xl.conf
   ```
   ```
   autoballoon="auto"
   vif.default.script="vif-bridge"
   vif.default.bridge="xenbr0"
   ```
   > Contrast the three config layers: `xl.conf` = toolstack-wide defaults; `xl.cfg` = a single domain's definition; `xen-command-line` = the hypervisor's own boot parameters (Exercise 2).

2. Recognize the **deprecated** `xm`/`xend` toolstack. On a modern host it is gone; the man page still describes the migration:

   ```bash
   which xm xl xe 2>/dev/null
   ```
   ```
   /usr/sbin/xl
   ```
   `xm` (the old Python `xend`-based toolstack) was **deprecated in Xen 4.1 and removed after 4.4**; `xl` (libxenlight/libxl, daemonless) is the default today. Commands map almost 1:1 (`xm list` → `xl list`, `xm create` → `xl create`).

3. Recognize the **XAPI** toolstack and its `xe` CLI (used by XenServer / XCP-ng, *not* installed on a plain Debian Xen host). Its awareness-level facts:
   - `xapi` is a daemon with its own PostgreSQL-like metadata DB and pool concept.
   - You manage VMs with `xe`, e.g. `xe vm-list`, `xe host-list`, `xe vm-start uuid=<uuid>`.
   - It layers a resource pool + storage-repository model on top of the same Xen hypervisor.

4. Practice the operations that move or checkpoint a domain with `xl` (requires shared storage for live migration; save/restore is local):

   ```bash
   # Local checkpoint to a file, then restore:
   xl save    pv-guest01 /var/lib/xen/save/pv-guest01.chk
   xl list                                   # pv-guest01 no longer listed
   xl restore /var/lib/xen/save/pv-guest01.chk

   # Live migration to a peer node (shared LVM/iSCSI + xl on both ends):
   xl migrate pv-guest01 xen-node02
   ```
   ```
   Saving to /var/lib/xen/save/pv-guest01.chk new xl format (info 0x3/0x0/1300)
   ...
   migration target: Ready to receive domain.
   Loading new save file ... done
   Domain 1 has shut off, reason code 3
   Migration successful.
   ```

**Comprehension check**

- **Q7.1** Put the three configuration scopes in order and state which file controls which: hypervisor boot options, per-domain definition, toolstack-wide defaults.
- **Q7.2** What replaced `xm`/`xend`, and what is the single biggest architectural difference (hint: a daemon)?
- **Q7.3** `xe` and `xl` both start VMs on Xen. What layer does `xe` belong to, and on which product family would you actually find it?
- **Q7.4** What must be true of the *storage* for `xl migrate <dom> <host>` to be a live migration rather than a failure?

---

## Answers

<details>
<summary>Click to reveal answers for all exercises</summary>

### Exercise 1
- **A1.1** `/sys/hypervisor/type` returns `xen` on any domain, PV or HVM; what proves you are in **Dom0** is `/sys/hypervisor/properties/capabilities` containing `control_d` (and the presence of `/proc/xen` with the toolstack). Only the control domain carries the `control_d` capability and can drive `xl`. `xl list` also always shows Dom0 as `ID 0`.
- **A1.2** `xen_caps` enumerates the guest ABIs the hypervisor was built for: `xen-3.0-x86_64` (PV guests) and the `hvm-3.0-*` entries (HVM guests). If no `hvm-*` capability were present — or `virt_caps` lacked `hvm` — the CPU/hypervisor could not run HVM guests, and `xl create` on an HVM config would fail. So you check it before Exercise 4.
- **A1.3** `xl dmesg` prints the **hypervisor's** (`xen.gz`) ring buffer — CPU/microcode/IOMMU/scheduler messages emitted before and beneath Linux — prefixed `(XEN)`. The plain `dmesg` command shows only the **Dom0 Linux kernel** log. You reach for `xl dmesg` to debug hardware passthrough, IOMMU, boot-parameter parsing, or hypervisor panics.
- **A1.4** `r-----` = **running**. The six flag positions are `r` running, `b` blocked (idle/waiting for I/O — normal for a mostly-idle guest), `p` paused, `s` shutdown, `c` crashed, `d` dying. (Any three of blocked/paused/shutdown/crashed/dying is correct.)

### Exercise 2
- **A2.1** `dom0_mem` is a **hypervisor** parameter and must go in `GRUB_CMDLINE_XEN*` (the `multiboot`/`xen.gz` line). Placing it in `GRUB_CMDLINE_LINUX*` passes it to the Dom0 *kernel*, which ignores it, so the hypervisor still auto-balloons Dom0.
- **A2.2** It gives Dom0 a **fixed, predictable** footprint. `dom0_mem=X,max:X` disables Dom0 auto-ballooning so guest memory pressure can't shrink/grow the control domain (which hurts driver/back-end latency and can deadlock). `dom0_max_vcpus` + `dom0_vcpus_pin` reserve/pin CPUs for Dom0 so back-end I/O isn't starved by busy guests — standard production hygiene.
- **A2.3** `xl info` → the `xen_commandline` field (equivalently `xl dmesg | grep "Command line"`). It reports what the hypervisor *actually* booted with, independent of what the GRUB config now says.
- **A2.4** `multiboot /boot/xen-4.17.gz …` = the **hypervisor**; the first `module /boot/vmlinuz-… …` = the **Dom0 kernel**; the second `module /boot/initrd.img-…` = the Dom0 initrd.

### Exercise 3
- **A3.1** A PV guest uses Xen **para­virtual front-end drivers**, not emulated hardware. The Xen block front-end registers disks under the `xvd` block major (202) → `xvda`, and the console front-end registers a hypervisor virtual console → `hvc0`. There is no emulated IDE/SATA controller or 8250 UART to produce `sda`/`ttyS0`.
- **A3.2** With `kernel=`/`ramdisk=`, the kernel and initrd are files in **Dom0** and the hypervisor loads them directly — Dom0 controls the guest kernel. With `bootloader = "pygrub"`, Xen runs a bootloader emulation that reads the **guest's own** `/boot` (and grub config) from inside its disk image and boots the kernel found there — the guest controls its kernel, like a normal machine.
- **A3.3** Format `<protocol>:<path>,<vdev>,<mode>`: `phy` = a physical block device back-end, `/dev/vg0/pv-guest01` = the backing device in Dom0, `xvda` = the virtual device name seen by the guest, `w` = read-write (`r` would be read-only).
- **A3.4** `xl shutdown` sends a graceful power-off request (PV control / ACPI for HVM), letting the guest OS unmount and sync — safe. `xl destroy` immediately deallocates the domain (equivalent to yanking the power cord), which **can corrupt** the guest filesystem. Use `destroy` only when the guest is hung.

### Exercise 4
- **A4.1** `virt_caps` must contain `hvm` (CPU VT-x/AMD-V enabled in firmware and exposed to Xen) and `xen_caps` must list an `hvm-3.0-*` ABI. (For device passthrough you would additionally want `hvm_directio` / IOMMU.)
- **A4.2** An HVM guest runs an **unmodified** OS that expects real hardware — a BIOS/UEFI, IDE/SATA, VGA, timers, NICs. Xen emulates that platform with a **QEMU device model** running as a user-space process in Dom0, one per HVM domain. A pure PV guest is Xen-aware and uses only hypercalls + split drivers, so no emulated platform (and no QEMU) is required.
- **A4.3** HVM firmware boots like a physical PC, so disks are presented through an emulated IDE/SATA controller → `hda`/`sda`, not the PV `xvd` node. `boot = "dc"` sets the BIOS boot order to try **d**isk first, then **c**D-ROM (`"cd"` would reverse it, handy during OS install).
- **A4.4** A **PVHVM** (PV-on-HVM) guest boots as HVM (so it needs no special kernel and gets fast HVM CPU virtualization) but then loads Xen **PV drivers** for disk and network, bypassing slow QEMU emulation for I/O. It combines HVM compatibility with near-PV I/O performance — the usual best choice for modern Linux.

### Exercise 5
- **A5.1** The **back-end** driver lives in **Dom0** (e.g. `xen-blkback`/`xen-netback`, exposing `vifX.Y` interfaces and connecting them to the bridge/storage). The **front-end** driver (`xen-blkfront`/`xen-netfront`) lives in the **guest**, presenting `xvdX`/`ethX`. They share memory rings advertised via XenStore.
- **A5.2** `xvd` uses block major 202. `202 << 8 = 51712`; add minor `0` for the whole disk `xvda` → `51712`. So `Vdev 51712` = `xvda`. `xvdb` = minor 16 → `51712 + 16 = 51728`.
- **A5.3** The config set `maxmem = 2048`. `xl mem-set` can balloon the guest **up to `maxmem`** but not beyond, because the guest's page tables were sized for `maxmem` at boot. `1536m` ≤ 2048, so it succeeds; `4096m` > 2048, so it fails.
- **A5.4** `vif1.1` = the Dom0 back-end interface for **domain ID 1**, virtual NIC **index 1** (the second `vif`). General form `vif<domid>.<devid>`.

### Exercise 6
- **A6.1** Any three of: **device configuration** (front/back-end ring refs, event channels, MACs, disk params), **run-state / control** (`memory/target`, `control/shutdown`, device `state` machine values), **domain metadata** (`name`, `domid`, `vm` UUID path), and **guest↔tools messaging** (e.g. balloon targets, VNC port). It is **not** a general-purpose or large-data store — only small control/status keys belong there.
- **A6.2** The device is **not fully connected**: front-end reports `4` (**Connected**) but back-end `2` (**InitWait**), so the back-end is still waiting/initialising — the split driver handshake is incomplete, which surfaces as a guest device that never appears or hangs. State `4` is *Connected* in the XenBus state machine.
- **A6.3** The domain **ID changes** every time a domain is created (each `xl create`, and after save/restore or migration the domain gets a new ID). A script that hard-codes `/local/domain/1/...` will silently read the wrong (or a nonexistent) domain after a reboot/migration; you should resolve the current ID by name first.
- **A6.4** `xenstored` (running in Dom0, or `oxenstored`) serves it. A booting DomU reaches XenStore over a **shared memory page + event channel** set up by the toolstack at domain creation — no network, no filesystem needed; the front-end drivers use it to discover their back-ends.

### Exercise 7
- **A7.1** From lowest/earliest to per-VM: **(1) hypervisor boot options** → the `xen-command-line` on the GRUB `multiboot` line (`GRUB_CMDLINE_XEN`); **(2) toolstack-wide defaults** → `/etc/xen/xl.conf`; **(3) per-domain definition** → the individual `/etc/xen/<name>.cfg` (`xl.cfg` format). Narrower scopes override broader defaults.
- **A7.2** `xl` (libxenlight/`libxl`) replaced `xm`. The biggest difference: `xm` required a persistent management **daemon, `xend`** (Python), whereas `xl` is **daemonless** — it links `libxl` and talks to the hypervisor/XenStore directly, which is simpler and more robust.
- **A7.3** `xe` is the CLI of the **XAPI** toolstack (a higher-level management layer with a daemon, metadata DB, resource pools, and storage repositories). You find it on **XenServer / Citrix Hypervisor / XCP-ng**, not on a plain upstream Debian Xen host, which ships `xl`.
- **A7.4** The guest's disk(s) must be on **storage reachable from both hosts** (shared LVM over iSCSI/FC, NFS, etc.) so the destination can access the exact same backing device. `xl` migrates CPU/memory state, not the disk contents; without shared storage the destination has no disk and the migration fails (or requires a separate storage-copy/`--live` with mirroring).

</details>

---

### Sources

- LPI — Exam 305-300 Objectives, Topic 351.2: <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Xen Project Wiki — *Xen Project Software Overview* / architecture (Dom0, DomU, PV/HVM/PVH): <https://wiki.xenproject.org/wiki/Xen_Project_Software_Overview>
- `xl(1)` manual (toolstack commands): <https://xenbits.xen.org/docs/unstable/man/xl.1.html>
- `xl.cfg(5)` manual (domain configuration syntax): <https://xenbits.xen.org/docs/unstable/man/xl.cfg.5.html>
- `xl.conf(5)` manual (global toolstack config): <https://xenbits.xen.org/docs/unstable/man/xl.conf.5.html>
- Xen hypervisor boot parameters (`xen-command-line`): <https://xenbits.xen.org/docs/unstable/misc/xen-command-line.html>
- Xen Project Wiki — *XenStore* (structure and XenBus device states): <https://wiki.xenproject.org/wiki/XenStore>
- Xen Project Wiki — *XL* (and the deprecation of `xm`/`xend`): <https://wiki.xenproject.org/wiki/XL>