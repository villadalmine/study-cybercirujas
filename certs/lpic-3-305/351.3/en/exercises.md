# 351.3 QEMU — Guided Exercises

> **Certification:** LPIC-3 305 (exam 305-300, version 3.0)
> **Topic:** 351.3 QEMU — *Understand the architecture of QEMU, its interaction with KVM and libvirt, start instances from the command line, drive the QEMU Monitor, and manage virtual/removable devices.*
> **Format:** Each exercise is a sequence of numbered steps you run on a Linux host with hardware virtualization, followed by comprehension questions. Model answers are in the collapsible section at the end.

**Prerequisites for the whole lab**

- A physical (or nested-enabled) x86-64 Linux host with an Intel VT-x or AMD-V capable CPU.
- Packages: `qemu-system-x86` (or `qemu-kvm`), `qemu-utils`, `cpu-checker` (Debian/Ubuntu) or `qemu-img`/`qemu-kvm` (RHEL family), and `libvirt-clients` for the final exercise.
- Your user in the `kvm` group (log out/in after adding), or run the boot commands with `sudo`.
- A small install ISO to boot, e.g. `debian-12.5.0-amd64-netinst.iso` (~630 MiB). Adapt the filename to whatever you download.
- Roughly 25 GiB of free disk for the images.

Work in a scratch directory:

```bash
mkdir -p ~/qemu-lab && cd ~/qemu-lab
```

---

## Exercise 1 — Confirm the KVM acceleration path

QEMU is a pure software emulator by default (TCG, the Tiny Code Generator). Near-native speed only happens when QEMU offloads guest CPU execution to the host CPU through the KVM kernel modules and `/dev/kvm`. Before anything else, prove that path exists on your host.

1. Check that the CPU exposes virtualization extensions. `vmx` is Intel VT-x, `svm` is AMD-V:

   ```bash
   egrep -c '(vmx|svm)' /proc/cpuinfo
   ```

   A non-zero number (usually equal to your logical CPU count) means the extensions are present and enabled in firmware.

2. Confirm the KVM modules are loaded:

   ```bash
   lsmod | grep kvm
   ```

   Expected (Intel host):

   ```
   kvm_intel             376832  0
   kvm                  1146880  1 kvm_intel
   irqbypass              16384  1 kvm
   ```

   On AMD you would see `kvm_amd` instead of `kvm_intel`. The generic `kvm` module is the architecture-independent core; `kvm-intel` / `kvm-amd` are the vendor back-ends.

3. If nothing loads, load the vendor module explicitly (it pulls in the core `kvm`):

   ```bash
   sudo modprobe kvm_intel     # or: sudo modprobe kvm_amd
   ```

4. Inspect the character device that userspace QEMU opens to talk to the hypervisor:

   ```bash
   ls -l /dev/kvm
   ```

   Expected:

   ```
   crw-rw----+ 1 root kvm 10, 232 Aug 11 09:14 /dev/kvm
   ```

   Note the group `kvm` and the `rw` group permission — this is why your user must be in the `kvm` group.

5. Run the convenience checker (Debian/Ubuntu `cpu-checker` package):

   ```bash
   kvm-ok
   ```

   Expected:

   ```
   INFO: /dev/kvm exists
   KVM acceleration can be used
   ```

6. Record the QEMU version and confirm the `x86_64` system emulator binary is installed:

   ```bash
   qemu-system-x86_64 --version
   ```

   Expected:

   ```
   QEMU emulator version 8.2.0 (Debian 1:8.2.0+ds-1)
   Copyright (c) 2003-2023 Fabrice Bellard and the QEMU Project developers
   ```

7. List the acceleration back-ends this binary was compiled with:

   ```bash
   qemu-system-x86_64 -accel help
   ```

   Expected (subset):

   ```
   Accelerators supported in QEMU binary:
   tcg
   kvm
   ```

**Questions**

- 1a. What is the functional difference between the `kvm` module and the `kvm-intel`/`kvm-amd` module, and why are both needed?
- 1b. `/dev/kvm` is present but a non-root user gets `Could not access KVM kernel module: Permission denied` when launching QEMU. What is the most likely cause and the fix?
- 1c. On a host where `egrep -c '(vmx|svm)' /proc/cpuinfo` returns `0`, name two distinct reasons this can happen even on a CPU that physically supports virtualization.
- 1d. If you launch QEMU without `accel=kvm` on this host, will the guest still run? What changes?

---

## Exercise 2 — Provision disk images with `qemu-img`

`qemu-img` is the offline image tool: it creates, inspects, converts, resizes, and snapshots virtual disks without a running VM. You will use `qcow2`, QEMU's native copy-on-write format.

1. Create a 20 GiB `qcow2` image. Because `qcow2` is sparse, this consumes only a few hundred KiB on disk initially:

   ```bash
   qemu-img create -f qcow2 disk.qcow2 20G
   ```

   Expected:

   ```
   Formatting 'disk.qcow2', fmt=qcow2 cluster_size=65536 extended_l2=off compression_type=zlib size=21474836480 lazy_refcounts=off refcount_bits=16
   ```

2. Inspect it. Compare *virtual size* (what the guest sees) with *disk size* (what the host filesystem actually uses):

   ```bash
   qemu-img info disk.qcow2
   ```

   Expected:

   ```
   image: disk.qcow2
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

3. Confirm the host-side sparseness with a standard tool. `-h` (apparent) vs `--apparent-size` shows the contrast:

   ```bash
   du -h disk.qcow2
   du -h --apparent-size disk.qcow2
   ```

   Expected: the first reports `~200K` (real blocks), the second `~193K` — both far below 20 GiB.

4. Create a thin *overlay* that keeps `disk.qcow2` read-only as its backing file. Writes land only in the overlay — this is the basis of golden images and linked clones:

   ```bash
   qemu-img create -f qcow2 -b disk.qcow2 -F qcow2 overlay.qcow2
   qemu-img info overlay.qcow2
   ```

   Expected (note the backing-file line):

   ```
   image: overlay.qcow2
   file format: qcow2
   virtual size: 20 GiB (21474836480 bytes)
   disk size: 196 KiB
   cluster_size: 65536
   backing file: disk.qcow2
   backing file format: qcow2
   ...
   ```

5. Check consistency of the image (safe on a stopped image only):

   ```bash
   qemu-img check disk.qcow2
   ```

   Expected:

   ```
   No errors were found on the image.
   0/327680 = 0.00% allocated, 0.00% fragmented, 0.00% compressed clusters
   Image end offset: 262144
   ```

6. Demonstrate a format conversion — produce a `raw` copy (fully allocated logical view) from the `qcow2` image:

   ```bash
   qemu-img convert -f qcow2 -O raw disk.qcow2 disk.raw
   qemu-img info disk.raw
   ```

   Expected `file format: raw`, `virtual size: 20 GiB`, and — because `raw` on a sparse-capable filesystem is still sparse — a small `disk size`.

**Questions**

- 2a. Explain the difference between *virtual size* and *disk size* in `qemu-img info`, and which one grows as the guest writes data.
- 2b. In step 4 you created `overlay.qcow2` on top of `disk.qcow2`. What happens to the running guest if you modify `disk.qcow2` directly while the overlay is in use? Why is this dangerous?
- 2c. You need to hand a colleague a VM disk to import into VMware. Which single `qemu-img convert` invocation produces a VMware-native image, and what does the `-O` flag control?
- 2d. Why should you never run `qemu-img check` or `qemu-img convert` against an image that is currently attached to a running VM?

---

## Exercise 3 — Boot a virtual machine from the command line

Now assemble a full `qemu-system-x86_64` invocation. Each flag maps to a piece of virtual hardware. You will boot the installer ISO against the empty `disk.qcow2`.

1. Launch the VM. Read every line before running it:

   ```bash
   qemu-system-x86_64 \
     -name lab-vm \
     -machine q35,accel=kvm \
     -cpu host \
     -m 2048 \
     -smp cores=2,threads=1,sockets=1 \
     -drive file=disk.qcow2,if=virtio,format=qcow2 \
     -cdrom debian-12.5.0-amd64-netinst.iso \
     -boot order=d,menu=on \
     -netdev user,id=net0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=net0 \
     -display gtk \
     -monitor stdio
   ```

   What each option does:
   - `-machine q35,accel=kvm` — modern PCIe chipset (`q35`) and force KVM acceleration; the launch fails loudly if KVM is unavailable instead of silently falling back to TCG.
   - `-cpu host` — expose the host CPU's feature set to the guest (best performance).
   - `-m 2048` — 2048 MiB of guest RAM.
   - `-smp cores=2,...` — 2 virtual CPUs.
   - `-drive ...,if=virtio` — attach the disk on the paravirtualized `virtio-blk` bus.
   - `-cdrom` — attach the ISO as a virtual optical drive (shorthand for `-drive ...,media=cdrom`).
   - `-boot order=d,menu=on` — boot device `d` = first CD-ROM; `menu=on` enables the interactive boot menu.
   - `-netdev user,...` + `-device virtio-net-pci` — a network *back-end* (user-mode SLIRP) bound to a network *front-end* (a virtio NIC); `hostfwd` forwards host port 2222 to guest port 22.
   - `-display gtk` — open a GTK window; switch to the monitor console with **Ctrl+Alt+2**, back to the guest with **Ctrl+Alt+1**.
   - `-monitor stdio` — additionally expose the QEMU Monitor on the terminal you launched from.

2. In the launching terminal you now have the `(qemu)` monitor prompt. Confirm the VM is running and KVM is truly active:

   ```
   (qemu) info status
   ```
   ```
   VM status: running
   ```
   ```
   (qemu) info kvm
   ```
   ```
   kvm support: enabled
   ```

3. Verify the emulated machine type and CPU count from the monitor:

   ```
   (qemu) info cpus
   ```

   Expected (two vCPUs):

   ```
   * CPU #0 [running] thread_id=12841
     CPU #1 [running] thread_id=12842
   ```

4. Proceed with (or just start) the guest installer in the GTK window to confirm the disk and NIC are detected. You do **not** need to finish the install — reaching the partitioner proves `virtio-blk` and the ISO are working.

5. (Optional, if the guest reaches a running SSH server later) From another host terminal, test the port-forward:

   ```bash
   ssh -p 2222 user@127.0.0.1
   ```

**Questions**

- 3a. `-cdrom` and `-drive ...,if=virtio` both attach storage. What is the boot-order consequence of `-boot order=d`, and how would you change it to boot from the hard disk instead?
- 3b. Distinguish the *network back-end* (`-netdev`) from the *device front-end* (`-device`). Which one is visible to the guest OS as a NIC, and which one determines how packets leave the host?
- 3c. Why does `-machine ...,accel=kvm` behave differently from `-enable-kvm` when KVM is missing, and which is preferable in an automated pipeline?
- 3d. You gave `-m 2048` and `-smp cores=2`. On the *host*, roughly how many threads does this QEMU process spawn for guest execution, and what does `info cpus` reveal about them?

---

## Exercise 4 — Drive the QEMU Monitor

The QEMU Monitor is the live control channel for a running instance: query state, hot-plug devices, swap media, pause/resume, and shut down cleanly. Keep the VM from Exercise 3 running.

1. From the `(qemu)` prompt, dump the block layer. This shows every drive and any inserted media:

   ```
   (qemu) info block
   ```

   Expected (abbreviated):

   ```
   virtio0 (#block123): /home/you/qemu-lab/disk.qcow2 (qcow2)
       Attached to:      /machine/peripheral-anon/device[0]/virtio-backend
       Cache mode:       writeback
   ide1-cd0: /home/you/qemu-lab/debian-12.5.0-amd64-netinst.iso (raw, read-only)
       Attached to:      ide1-cd0
       Removable device: not locked, tray closed
   ```

2. Inspect the network state:

   ```
   (qemu) info network
   ```
   ```
   net0:
    index=0,type=nic,model=virtio-net-pci,macaddr=52:54:00:12:34:56
    \ net0: index=0,type=user,net=10.0.2.0,restrict=off
   ```

   Note the MAC prefix `52:54:00` — QEMU's registered OUI, a giveaway that a NIC is virtual.

3. Eject the installation media *live* (as if removing a CD), then confirm the tray is open:

   ```
   (qemu) eject ide1-cd0
   (qemu) info block
   ```

   The `ide1-cd0` line now shows an empty tray.

4. Insert a different ISO into the same virtual drive without stopping the VM:

   ```
   (qemu) change ide1-cd0 /path/to/another.iso
   ```

5. Pause and resume guest execution. `stop` freezes all vCPUs; `cont` resumes:

   ```
   (qemu) stop
   (qemu) info status
   ```
   ```
   VM status: paused
   ```
   ```
   (qemu) cont
   ```

6. Hot-add a second virtio disk without rebooting. First create the image in another terminal:

   ```bash
   qemu-img create -f qcow2 data.qcow2 5G
   ```

   Then, from the monitor, add the back-end (`drive_add`) and the front-end device (`device_add`):

   ```
   (qemu) drive_add 0 file=/home/you/qemu-lab/data.qcow2,if=none,id=data0,format=qcow2
   (qemu) device_add virtio-blk-pci,drive=data0,id=vblk1
   ```

   Inside the guest, a new `/dev/vdb` appears (verify with `lsblk`).

7. Remove it again cleanly:

   ```
   (qemu) device_del vblk1
   ```

8. Request an ACPI shutdown — this is the graceful power button, equivalent to pressing power on physical hardware. The guest OS runs its shutdown sequence:

   ```
   (qemu) system_powerdown
   ```

   (`quit` by contrast kills the QEMU process immediately, like pulling the plug — the guest is not notified.)

**Questions**

- 4a. Give the two standard ways to reach the QEMU Monitor of a GTK/SDL session, and one way to expose it over the network for headless hosts.
- 4b. Contrast `system_powerdown`, `stop`, and `quit`. Which one risks guest filesystem corruption and why?
- 4c. Hot-plugging a disk in step 6 took two commands (`drive_add` then `device_add`). Explain the back-end/front-end split this reflects and why `device_del` alone is enough to remove it.
- 4d. Which single monitor command would you run to confirm the guest's virtual disk is being served with `writeback` cache mode, and why does cache mode matter for data safety?

---

## Exercise 5 — VM state snapshots via the monitor

`qcow2` supports *internal* snapshots that capture disk **and**, when taken from the monitor, live CPU/RAM state (`savevm`). These are distinct from the offline `qemu-img snapshot` command. Keep a VM (ideally with a finished install, but any running guest works) up.

1. From the monitor, save a full VM snapshot named `clean`:

   ```
   (qemu) savevm clean
   ```

   The command blocks briefly while RAM is written into the image, then returns to the prompt.

2. List snapshots stored in the image:

   ```
   (qemu) info snapshots
   ```

   Expected:

   ```
   List of snapshots present on all disks:
   ID        TAG          VM SIZE                DATE       VM CLOCK     ICOUNT
   1         clean       220 MiB 2026-08-11 10:32:11   00:04:12.325
   ```

   `VM SIZE` is non-zero — that is the captured RAM. A pure disk snapshot would show `0 B` here.

3. Make a visible change inside the guest (create a file, install a package — anything that alters disk/RAM).

4. Roll the entire machine back to the snapshot. Execution and memory jump back to the exact instant of the save:

   ```
   (qemu) loadvm clean
   ```

   Verify inside the guest that your change from step 3 is gone.

5. Cross-check the same snapshots from the *offline* tool (works even when the VM is off):

   ```bash
   qemu-img snapshot -l disk.qcow2
   ```

   Expected:

   ```
   Snapshot list:
   ID        TAG          VM SIZE                DATE       VM CLOCK
   1         clean       220 MiB 2026-08-11 10:32:11   00:04:12.325
   ```

6. Delete the snapshot from the monitor when done:

   ```
   (qemu) delvm clean
   (qemu) info snapshots
   ```

   The list is now empty (`There is no snapshot available.`).

**Questions**

- 5a. What extra data does a monitor `savevm` capture that an offline `qemu-img snapshot -c` does not, and how do you tell them apart in `info snapshots`?
- 5b. Why do internal `savevm` snapshots require the disk to be in `qcow2` (or another format that supports them) rather than `raw`?
- 5c. You have a VM whose disk uses an external *backing file* chain. What is the risk of taking an internal snapshot that also spans that shared backing image?
- 5d. `loadvm` reverted RAM and disk atomically. Why is that stronger than restoring a filesystem-level backup taken while the guest was running?

---

## Exercise 6 — Networking: user-mode vs bridged/TAP

QEMU separates *how the guest sees the NIC* (device front-end) from *how packets reach the world* (network back-end). You already used the simplest back-end (`user`/SLIRP). Now understand its limits and the TAP alternative.

1. Boot a throwaway guest with an explicit user-mode network and an SSH forward, headless:

   ```bash
   qemu-system-x86_64 \
     -machine q35,accel=kvm -cpu host -m 1024 -smp 1 \
     -drive file=overlay.qcow2,if=virtio,format=qcow2 \
     -netdev user,id=n0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=n0,mac=52:54:00:ab:cd:01 \
     -nographic
   ```

   `-nographic` sends the guest serial console to your terminal and *multiplexes* the monitor onto it — switch to the monitor with **Ctrl+a c**, and remember **Ctrl+a x** kills QEMU.

2. Once the guest is up, examine the addresses it received from SLIRP. Inside the guest:

   ```bash
   ip -4 addr show
   ip route
   cat /etc/resolv.conf
   ```

   You will see the guest on `10.0.2.15/24`, default gateway `10.0.2.2`, DNS `10.0.2.3`. These are fixed SLIRP conventions: `.2` is the host-facing gateway, `.3` the DNS proxy.

3. Prove outbound works but the host cannot freely reach *in*. From the guest, `ping 10.0.2.2` (the gateway) succeeds; note that ICMP to the wider internet through SLIRP is often unreliable, but TCP (e.g. `curl https://www.qemu.org`) works.

4. Demonstrate the inbound limitation and its workaround. From the *host*, a direct connection to the guest IP fails (the `10.0.2.0/24` net is private to this VM), but the `hostfwd` you set works:

   ```bash
   ssh -p 2222 user@127.0.0.1
   ```

5. Understand the TAP alternative (setup requires root and a host bridge; read and reason about it rather than necessarily running it). A TAP back-end plugs the guest onto a real Layer-2 host bridge so it becomes a first-class node on the physical LAN:

   ```bash
   # Host-side, one-time bridge (illustrative):
   #   ip link add br0 type bridge
   #   ip link set eth0 master br0
   #
   qemu-system-x86_64 \
     -machine q35,accel=kvm -cpu host -m 1024 -smp 1 \
     -drive file=overlay.qcow2,if=virtio,format=qcow2 \
     -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
     -device virtio-net-pci,netdev=n0,mac=52:54:00:ab:cd:02 \
     -nographic
   ```

   With TAP + bridge the guest gets an address from the LAN's DHCP and is reachable by any host on the network — no port-forwarding needed.

**Questions**

- 6a. In user-mode (SLIRP) networking, what are the addresses `10.0.2.2` and `10.0.2.3`, and why can two simultaneously running user-mode guests both use `10.0.2.15` without conflict?
- 6b. A student complains "my QEMU guest can browse the web but I can't SSH into it from my laptop." Explain the root cause and give the two different ways to fix it (one per back-end type).
- 6c. Why is `hostfwd` unnecessary with a TAP/bridge back-end?
- 6d. Both invocations set `mac=52:54:00:...`. Why is pinning an explicit MAC good practice, and what is the significance of the `52:54:00` prefix?

---

## Exercise 7 — Where libvirt fits over QEMU

In production you rarely type these long command lines. `libvirt` (the `qemu:///system` driver) stores each VM as XML and constructs the QEMU command line for you. This exercise shows the boundary between the two layers.

1. If a libvirt-managed guest exists (or create a trivial one via `virt-install`/`virsh define`), list it:

   ```bash
   virsh -c qemu:///system list --all
   ```

   Expected:

   ```
    Id   Name      State
   ---------------------------
    3    lab-vm    running
   ```

2. Reveal the *actual* QEMU command line libvirt generated for a defined domain — this connects everything you did by hand back to the managed layer:

   ```bash
   virsh -c qemu:///system domxml-to-native qemu-argv --domain lab-vm
   ```

   The output is a long `qemu-system-x86_64 ... -machine ... -accel kvm ... -drive ... -netdev ... -device ...` string — the same building blocks from Exercises 3 and 6, machine-generated.

3. Confirm libvirt drives the very same `qemu-system-x86_64` binary by finding the live process:

   ```bash
   pgrep -a qemu-system
   ```

   You will see one long `qemu-system-x86_64` line per running domain, launched by libvirt with `-accel kvm` and a Unix-socket monitor (`-mon ...,mode=control`).

4. Observe that libvirt talks to each guest's monitor over the QMP socket rather than `stdio` — that socket is how `virsh` implements commands like `virsh shutdown` (which issues the ACPI powerdown you saw as `system_powerdown`).

**Questions**

- 7a. In one sentence each, state what QEMU provides and what libvirt adds on top of it.
- 7b. `virsh shutdown lab-vm` and the monitor command `system_powerdown` produce the same effect on the guest. What does this tell you about how libvirt controls a running QEMU instance?
- 7c. Why does libvirt use a QMP control socket (`-mon ...,mode=control`) rather than the human-readable `-monitor stdio` you used in the lab?

---

## Cleanup

```bash
# Stop any running QEMU windows (or 'quit' from each monitor), then:
cd ~ && rm -rf ~/qemu-lab
```

---

<details>
<summary><strong>Answers — click to expand</strong></summary>

### Exercise 1

**1a.** The generic `kvm` module is the architecture-independent core of the KVM hypervisor: it exposes `/dev/kvm` and the ioctl interface userspace (QEMU) uses. `kvm-intel` and `kvm-amd` are the vendor-specific back-ends that program the actual hardware virtualization extensions (Intel VT-x / VMX or AMD-V / SVM). You need the core for the interface and exactly one vendor module for your CPU; loading the vendor module auto-loads the core as a dependency (seen in `lsmod` as `kvm ... 1 kvm_intel`).

**1b.** `/dev/kvm` is owned `root:kvm` with `rw` only for owner and group. The user is not in the `kvm` group. Fix: `sudo usermod -aG kvm <user>` and re-login (group membership is evaluated at session start), or run QEMU with `sudo`. Verify with `id` that `kvm` appears in the group list.

**1c.** Any two of: (1) virtualization is disabled in the BIOS/UEFI firmware (Intel VT-x / AMD SVM toggle off); (2) you are inside a VM/cloud instance where nested virtualization was not enabled by the host; (3) the CPU flags are hidden by a hypervisor `-cpu` model that doesn't pass `vmx`/`svm` through; (4) a security feature (e.g. some firmware "secure"/DEP modes) is masking the extensions.

**1d.** Yes — QEMU falls back to the TCG software emulator, so the guest still boots and runs correctly, but every guest instruction is dynamically translated by QEMU on the host CPU instead of executed natively. The result is roughly an order of magnitude slower and much higher host CPU usage. Functionality is the same; performance is not.

### Exercise 2

**2a.** *Virtual size* is the capacity the guest OS sees (e.g. 20 GiB) — the geometry advertised to the guest. *Disk size* is the number of host bytes the image file currently occupies. For a sparse/`qcow2` image, disk size starts near zero and **grows as the guest writes**, up to (but capped at) the virtual size. Virtual size is fixed until you `qemu-img resize`.

**2b.** A backing file must be treated as read-only for the life of any overlay that depends on it. `overlay.qcow2` stores only the *differences* against `disk.qcow2` by cluster; if you modify `disk.qcow2` directly, the overlay's unchanged clusters now point at data that no longer matches what the guest expects, silently corrupting the guest's view of the disk. Never write to a backing file while an overlay is live.

**2c.** `qemu-img convert -f qcow2 -O vmdk disk.qcow2 disk.vmdk`. The `-O` flag sets the *output* format (`-f` sets the input format). VMware's native format is `vmdk`; `qemu-img` can also produce `vpc` (Hyper-V VHD), `vhdx`, `raw`, `qcow2`, etc.

**2d.** Those commands assume the image is quiescent. A running VM is actively mutating the file, so `qemu-img check` may report false corruption and `qemu-img convert` will read an inconsistent, torn image — and any writes it makes race with QEMU's. Both operations require the VM stopped (or you must use the monitor/QMP for live operations). Online, use blockdev/QMP snapshot commands instead.

### Exercise 3

**3a.** `-boot order=d` makes the first CD-ROM the primary boot device, so the VM boots the ISO installer. Once the OS is installed you want to boot the disk: change to `-boot order=c` (first hard disk), or drop the `-cdrom`/set `menu=on` and pick manually. Letters: `a`/`b` = floppy, `c` = first hard disk, `d` = first CD-ROM, `n` = network/PXE.

**3b.** The `-netdev` back-end defines how packets actually enter/leave the host (user-mode SLIRP, TAP/bridge, socket, etc.) — it is invisible to the guest. The `-device` front-end (e.g. `virtio-net-pci`, `e1000`) is the emulated NIC the guest OS sees and loads a driver for. They are bound by matching `id`. The guest sees the *front-end*; the *back-end* decides the packets' fate.

**3c.** `-machine ...,accel=kvm` (and `-accel kvm`) makes KVM a hard requirement: if KVM is unavailable, QEMU **fails to start** with an error. `-enable-kvm` historically behaved the same but the modern, explicit, composable form is `-accel kvm`; the risky pattern is `-machine accel=kvm:tcg`, which *silently* falls back to slow TCG. In a pipeline you want the hard-fail form so a broken host is caught instead of shipping an accidentally-emulated, slow VM.

**3d.** QEMU runs one host thread per virtual CPU (here 2 vCPU threads), plus the main I/O/event-loop thread and helper threads. `info cpus` lists each vCPU with a host `thread_id`, letting you map guest CPUs to host threads (useful for pinning/`taskset` and diagnosing a single hot vCPU).

### Exercise 4

**4a.** (1) Switch consoles inside the GTK/SDL window with **Ctrl+Alt+2** (monitor) / **Ctrl+Alt+1** (guest). (2) Redirect it to your launching terminal with `-monitor stdio` (or multiplex onto the serial console under `-nographic` via **Ctrl+a c**). For headless/network access, expose it as a socket: `-monitor telnet:127.0.0.1:5555,server,nowait` and connect with `telnet 127.0.0.1 5555` (or use QMP: `-qmp`).

**4b.** `system_powerdown` sends an ACPI power event so the guest OS shuts down cleanly (flushes and unmounts). `stop` merely freezes the vCPUs (guest still resident, resume with `cont`). `quit` terminates the QEMU process instantly with no notice to the guest — the equivalent of pulling the power cord, which **risks filesystem corruption** because in-flight writes and dirty caches are lost.

**4c.** QEMU splits storage into a back-end (`drive_add` / the host-side file and I/O path, `if=none`) and a front-end device on a guest bus (`device_add virtio-blk-pci`). `drive_add` registers the media; `device_add` presents it to the guest. `device_del` removes the guest-visible device (triggering ACPI unplug), which is sufficient to detach it from the guest; the now-orphaned back-end can then be released. This mirrors the same front-end/back-end split as networking.

**4d.** `info block`. It shows the `Cache mode:` line per drive. Cache mode matters because `writeback` lets the host page cache acknowledge writes before they hit stable storage — fast, but a host crash/power loss can lose recently "written" guest data. `writethrough`/`none`+`O_DIRECT`/`directsync` trade throughput for stronger durability guarantees.

### Exercise 5

**5a.** A monitor `savevm` captures the live **VM state — CPU registers and RAM — plus the disk**, so `loadvm` resumes execution mid-flight. `qemu-img snapshot -c` (offline) captures only the disk. You tell them apart by the `VM SIZE` column in `info snapshots` / `qemu-img snapshot -l`: a non-zero `VM SIZE` (e.g. `220 MiB`) means saved RAM; `0 B` means a disk-only snapshot.

**5b.** Internal snapshots store multiple point-in-time versions of clusters plus the VM-state blob inside the image file itself, which requires format metadata that supports it (`qcow2`, `qed`, etc.). `raw` has no metadata layer — it is just the linear disk bytes — so it cannot hold snapshots; QEMU refuses `savevm` on a raw-only VM.

**5c.** An internal snapshot lives inside the specific image. If the snapshot machinery touches a *shared backing file*, or you snapshot only the overlay while the backing image is later modified/replaced, the snapshot can reference clusters that no longer mean what they did — inconsistent or unrecoverable state. Keep backing files immutable and prefer snapshotting the complete, self-contained image.

**5d.** `loadvm` restores CPU, RAM, and disk to the *same instant* atomically, so the guest resumes from a fully consistent point — no torn state. A filesystem backup taken from inside a running guest captures the disk at a moment when RAM held un-flushed data and files were mid-write, so restoring it can yield an inconsistent filesystem needing fsck/journal recovery, with no matching memory state.

### Exercise 6

**6a.** In SLIRP, `10.0.2.2` is the virtual gateway (also the host as seen by the guest) and `10.0.2.3` is the built-in DNS forwarder. Each user-mode guest gets its own private, isolated `10.0.2.0/24` NAT network emulated entirely inside its own QEMU process, so two guests can both be `10.0.2.15` with no conflict — the networks never touch each other or the LAN at Layer 2.

**6b.** User-mode SLIRP is outbound-NAT only: the guest reaches the internet, but its private `10.0.2.0/24` address is unreachable from outside that QEMU process. Fixes: (1) with user mode, add a `hostfwd` (e.g. `hostfwd=tcp::2222-:22`) and SSH to the host's port 2222; (2) switch the back-end to TAP on a bridge so the guest gets a real LAN address reachable directly.

**6c.** With TAP + a host bridge the guest is a first-class Layer-2 node on the physical LAN with its own routable address (typically via the LAN's DHCP). There is no NAT boundary to traverse, so any host on the network reaches it directly — port-forwarding only exists to punch through the SLIRP NAT that TAP doesn't have.

**6d.** Pinning a MAC makes the guest's identity stable across reboots and re-launches, so DHCP reservations, license bindings, and firewall rules keep working (a randomly generated MAC each boot would break them). `52:54:00` is QEMU/KVM's registered OUI prefix — seeing it on a network is a strong signal the interface belongs to a QEMU virtual machine.

### Exercise 7

**7a.** QEMU provides the actual machine emulation/virtualization: it creates the virtual hardware and, via KVM, runs the guest. libvirt adds a management layer on top — persistent XML domain definitions, a stable API/CLI (`virsh`), lifecycle and autostart, storage/network pools, and access control — while delegating the real work to QEMU.

**7b.** libvirt does not reimplement guest control; it drives the *same* QEMU instance through that instance's monitor/QMP control socket. `virsh shutdown` simply issues the ACPI powerdown request over QMP — exactly what `system_powerdown` does at the monitor. The managed and manual paths converge on one running `qemu-system-x86_64` process.

**7c.** QMP is a structured, machine-parseable JSON protocol designed for programmatic control, with well-defined commands, responses, and asynchronous events — robust for software to consume. The human `-monitor stdio` interface is free-form text meant for interactive typing and can change format between versions, making it unreliable to parse. libvirt therefore uses the QMP control socket (`mode=control`) for deterministic automation.

</details>

---

### Reference sources

- LPI — Exam 305 Objectives (305-300, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/
- QEMU — Invocation / command-line options: https://www.qemu.org/docs/master/system/invocation.html
- QEMU — QEMU Monitor: https://www.qemu.org/docs/master/system/monitor.html
- QEMU — `qemu-img` reference: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU — Disk images & snapshots: https://www.qemu.org/docs/master/system/images.html
- QEMU — Network emulation (user/TAP back-ends): https://www.qemu.org/docs/master/system/devices/net.html
- Linux KVM project: https://www.linux-kvm.org/page/Main_Page
- Kernel.org — KVM documentation: https://docs.kernel.org/virt/kvm/index.html
- libvirt — QEMU/KVM hypervisor driver: https://libvirt.org/drvqemu.html