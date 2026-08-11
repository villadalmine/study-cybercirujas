# Guided Exercises — Topic 351.4: Libvirt Virtual Machine Management

**Certification:** LPIC-3 Virtualization and Containerization — Exam 305-300 (v3.0)
**Objective weight:** 15
**Reference objectives:** https://www.lpi.org/our-certifications/exam-305-objectives/

> **Lab prerequisites.** A Linux host with hardware virtualization enabled (`egrep -c '(vmx|svm)' /proc/cpuinfo` returns > 0), the packages `libvirt-daemon-system`/`libvirt`, `qemu-kvm`/`qemu-system-x86`, `virtinst`, and `libvirt-client` installed, and your user in the `libvirt` group (log out/in after adding). All commands assume the privileged system connection `qemu:///system` unless noted. Where a command downloads or boots a real guest, a small cloud image (e.g. Alpine or a Debian netboot) is enough; every exercise is designed to be runnable on a laptop.
>
> Official references used throughout:
> - libvirt architecture & daemons — https://libvirt.org/daemons.html
> - `virsh` manual — https://libvirt.org/manpages/virsh.html
> - Domain XML — https://libvirt.org/formatdomain.html
> - Storage XML — https://libvirt.org/formatstorage.html
> - Network XML — https://libvirt.org/formatnetwork.html
> - `virt-install` manual — https://libvirt.org/manpages/virt-install.html

---

## Exercise 1 — Architecture, daemons and the connection URI

**Goal:** Distinguish the monolithic `libvirtd` from the modular daemons, and understand what a connection URI selects.

1. Identify which daemon model your host runs. First check the legacy monolithic daemon, then the modular per-driver daemons:

   ```console
   $ systemctl is-active libvirtd
   inactive

   $ systemctl list-units --type=service 'virt*d.service' --state=active
   UNIT                LOAD   ACTIVE SUB     DESCRIPTION
   virtqemud.service   loaded active running Virtualization qemu daemon
   virtnetworkd.service loaded active running Virtualization network daemon
   virtstoraged.service loaded active running Virtualization storage daemon
   virtnodedevd.service loaded active running Virtualization nodedev daemon
   ```

2. Inspect the sockets. Modern libvirt uses **systemd socket activation** — the daemon may be started on first connection:

   ```console
   $ systemctl list-sockets 'virt*'
   LISTEN                             UNIT                     ACTIVATES
   /run/libvirt/virtqemud-sock        virtqemud.socket         virtqemud.service
   /run/libvirt/virtqemud-sock-ro     virtqemud-ro.socket      virtqemud.service
   /run/libvirt/virtnetworkd-sock     virtnetworkd.socket      virtnetworkd.service
   ```

3. Ask the client which hypervisor and connection it is talking to:

   ```console
   $ virsh uri
   qemu:///system

   $ virsh version
   Compiled against library: libvirt 9.0.0
   Using library: libvirt 9.0.0
   Using API: QEMU 9.0.0
   Running hypervisor: QEMU 8.2.2
   ```

4. Contrast the two standard QEMU connections without changing anything yet:

   ```console
   $ virsh -c qemu:///system list --all      # privileged, host-wide VMs, run by libvirt-qemu
   $ virsh -c qemu:///session list --all      # per-user, unprivileged, no host bridging by default
   ```

5. Look at where configuration lives:

   ```console
   $ ls /etc/libvirt/
   libvirt.conf   qemu/          storage/       virtqemud.conf
   networkxml/    qemu.conf      nwfilter/      ...
   $ ls /etc/libvirt/qemu/         # persistent domain XML definitions
   $ ls /etc/libvirt/storage/      # persistent storage pool definitions
   ```

**Comprehension check 1**

- **1a.** Your host shows `libvirtd` as `inactive` but VMs still run. How is that possible, and what replaced it?
- **1b.** You connect and get an error: `failed to connect to the hypervisor ... No such file or directory`. Nothing is running as a service. What mechanism normally would have started the daemon, and what single action tests it?
- **1c.** A colleague runs `virsh list` as their normal user and sees an empty list, but as root they see three running VMs. They swear the VMs are up. What is the most likely cause — and it is *not* permissions on a file?
- **1d.** Which directory holds the *persistent* on-disk XML for a defined domain, and why should you never hand-edit files there directly?

---

## Exercise 2 — Storage pools and volumes

**Goal:** Define a `dir` storage pool, build it, and carve volumes from it — the substrate every disk-backed VM needs.

1. List existing pools. A fresh install usually has a `default` pool at `/var/lib/libvirt/images`:

   ```console
   $ virsh pool-list --all
    Name       State    Autostart
   ---------------------------------
    default    active   yes
   ```

2. Define a new directory pool from XML. Create `lab-pool.xml`:

   ```xml
   <pool type='dir'>
     <name>lab-images</name>
     <target>
       <path>/srv/libvirt/lab-images</path>
       <permissions>
         <mode>0711</mode>
         <owner>0</owner>
         <group>0</group>
       </permissions>
     </target>
   </pool>
   ```

3. Register, build (create the backing directory), start it, and set it to auto-start on boot:

   ```console
   $ virsh pool-define lab-pool.xml
   Pool lab-images defined from lab-pool.xml

   $ virsh pool-build   lab-images
   Pool lab-images built

   $ virsh pool-start   lab-images
   Pool lab-images started

   $ virsh pool-autostart lab-images
   Pool lab-images marked as autostarted
   ```

4. Confirm capacity accounting:

   ```console
   $ virsh pool-info lab-images
   Name:           lab-images
   UUID:           b3f2...-...-...
   State:          running
   Persistent:     yes
   Autostart:      yes
   Capacity:       457.39 GiB
   Allocation:     12.11 GiB
   Available:      445.28 GiB
   ```

5. Create two volumes — a thin qcow2 and a raw one — with `vol-create-as`, then inspect the qcow2:

   ```console
   $ virsh vol-create-as lab-images node1.qcow2 20G --format qcow2
   Vol node1.qcow2 created

   $ virsh vol-create-as lab-images swap.raw 2G --format raw --allocation 2G
   Vol swap.raw created

   $ virsh vol-list lab-images
    Name          Path
   ------------------------------------------------------------
    node1.qcow2   /srv/libvirt/lab-images/node1.qcow2
    swap.raw      /srv/libvirt/lab-images/swap.raw

   $ virsh vol-info --pool lab-images node1.qcow2
   Name:           node1.qcow2
   Type:           file
   Capacity:       20.00 GiB
   Allocation:     196.00 KiB
   ```

6. Grow the qcow2 volume and re-read pool state:

   ```console
   $ virsh vol-resize --pool lab-images node1.qcow2 30G
   Size of volume 'node1.qcow2' successfully changed to 30 GiB

   $ virsh pool-refresh lab-images
   Pool lab-images refreshed
   ```

**Comprehension check 2**

- **2a.** Immediately after `pool-define`, `pool-list` (without `--all`) does not show `lab-images`. Why, and which two subcommands make it appear as active?
- **2b.** What does `pool-build` actually do for a `dir` pool, and why is it a separate step from `pool-define`?
- **2c.** `node1.qcow2` has capacity 20 GiB but allocation 196 KiB. Explain the mechanism and name the one format flag that would have forced full up-front allocation instead.
- **2d.** You copied a new `.qcow2` file into `/srv/libvirt/lab-images` by hand with `cp`. `virsh vol-list lab-images` doesn't show it. Which single command fixes the discrepancy, and why is it needed?
- **2e.** Name the pool *type* you would choose to back volumes on an existing LVM volume group, and the type for an NFS export.

---

## Exercise 3 — Virtual networks

**Goal:** Understand the `default` NAT network, then define an isolated network, using the `net-*` family.

1. Inspect the built-in `default` network and its live XML:

   ```console
   $ virsh net-list --all
    Name      State    Autostart   Persistent
   ----------------------------------------------
    default   active   yes         yes

   $ virsh net-dumpxml default
   <network>
     <name>default</name>
     <uuid>...</uuid>
     <forward mode='nat'/>
     <bridge name='virbr0' stp='on' delay='0'/>
     <mac address='52:54:00:...'/>
     <ip address='192.168.122.1' netmask='255.255.255.0'>
       <dhcp>
         <range start='192.168.122.2' end='192.168.122.254'/>
       </dhcp>
     </ip>
   </network>
   ```

2. Observe the host-side plumbing libvirt created for it — a Linux bridge and a `dnsmasq` instance bound to it:

   ```console
   $ ip -br addr show virbr0
   virbr0   UP   192.168.122.1/24

   $ ps aux | grep -m1 dnsmasq
   ... /usr/sbin/dnsmasq --conf-file=/var/lib/libvirt/dnsmasq/default.conf ...
   ```

3. Define an **isolated** network (no `<forward>` element = no host/external routing, host-only). Create `lab-net.xml`:

   ```xml
   <network>
     <name>lab-isolated</name>
     <bridge name='virbr-lab' stp='on' delay='0'/>
     <ip address='10.10.0.1' netmask='255.255.255.0'>
       <dhcp>
         <range start='10.10.0.100' end='10.10.0.199'/>
         <host mac='52:54:00:aa:bb:cc' name='node1' ip='10.10.0.10'/>
       </dhcp>
     </ip>
   </network>
   ```

4. Define, start, and set autostart:

   ```console
   $ virsh net-define    lab-net.xml
   Network lab-isolated defined from lab-net.xml
   $ virsh net-start     lab-isolated
   Network lab-isolated started
   $ virsh net-autostart lab-isolated
   Network lab-isolated marked as autostarted
   ```

5. Once a guest is attached and leased, check active DHCP leases:

   ```console
   $ virsh net-dhcp-leases lab-isolated
    Expiry Time          MAC address         Protocol  IP address        Hostname
   ------------------------------------------------------------------------------
    2026-08-11 15:04:22  52:54:00:aa:bb:cc   ipv4      10.10.0.10/24     node1
   ```

**Comprehension check 3**

- **3a.** The `default` network uses `<forward mode='nat'/>`. A guest on it can reach the internet, but hosts on your LAN cannot initiate a connection *to* the guest. Explain why, in terms of what NAT forwarding sets up.
- **3b.** Your `lab-isolated` network has no `<forward>` element. What connectivity does a guest on it have, and what still provides it an IP address?
- **3c.** Name the two host-side objects libvirt creates for a NAT/isolated network, and which one serves DHCP and DNS.
- **3d.** You want a guest to appear as a first-class device directly on the physical LAN (its own DHCP lease from the office router). Which `<forward mode='...'>` value achieves this, and what host-side prerequisite does it usually require?
- **3e.** What is the practical difference between `virsh net-create lab-net.xml` and `virsh net-define lab-net.xml`?

---

## Exercise 4 — Defining a domain and driving its lifecycle

**Goal:** Author a minimal but valid domain XML, define it, and walk it through every lifecycle state with `virsh`.

1. Create `node1.xml`. This is a complete, syntactically valid KVM domain wired to the `lab-images` volume and the `lab-isolated` network:

   ```xml
   <domain type='kvm'>
     <name>node1</name>
     <memory unit='MiB'>1024</memory>
     <currentMemory unit='MiB'>1024</currentMemory>
     <vcpu placement='static'>2</vcpu>
     <os>
       <type arch='x86_64' machine='q35'>hvm</type>
       <boot dev='hd'/>
     </os>
     <features>
       <acpi/>
       <apic/>
     </features>
     <cpu mode='host-passthrough' check='none'/>
     <clock offset='utc'/>
     <on_poweroff>destroy</on_poweroff>
     <on_reboot>restart</on_reboot>
     <on_crash>restart</on_crash>
     <devices>
       <emulator>/usr/bin/qemu-system-x86_64</emulator>
       <disk type='file' device='disk'>
         <driver name='qemu' type='qcow2'/>
         <source file='/srv/libvirt/lab-images/node1.qcow2'/>
         <target dev='vda' bus='virtio'/>
       </disk>
       <interface type='network'>
         <mac address='52:54:00:aa:bb:cc'/>
         <source network='lab-isolated'/>
         <model type='virtio'/>
       </interface>
       <console type='pty'>
         <target type='serial' port='0'/>
       </console>
       <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>
       <video>
         <model type='virtio'/>
       </video>
       <memballoon model='virtio'/>
     </devices>
   </domain>
   ```

2. Define it persistently and confirm it exists but is shut off:

   ```console
   $ virsh define node1.xml
   Domain 'node1' defined from node1.xml

   $ virsh list --all
    Id   Name    State
   -------------------------
    -    node1   shut off

   $ virsh domstate node1
   shut off
   ```

3. Start it, then read its runtime identity and info:

   ```console
   $ virsh start node1
   Domain 'node1' started

   $ virsh list
    Id   Name    State
   ------------------------
    3    node1   running

   $ virsh dominfo node1
   Id:             3
   Name:           node1
   UUID:           7c1a...-...-...
   OS Type:        hvm
   State:          running
   CPU(s):         2
   Max memory:     1048576 KiB
   Used memory:    1048576 KiB
   Persistent:     yes
   Autostart:      disable
   Managed save:   no
   ```

4. Exercise the pause/resume path — note `suspend` freezes CPU but keeps RAM resident:

   ```console
   $ virsh suspend node1
   Domain 'node1' suspended
   $ virsh domstate node1
   paused
   $ virsh resume node1
   Domain 'node1' resumed
   ```

5. Exercise the graceful vs forceful stop paths:

   ```console
   $ virsh shutdown node1        # sends ACPI event; guest OS must cooperate
   Domain 'node1' is being shutdown

   $ virsh start node1
   $ virsh destroy node1         # immediate power-off, no clean shutdown
   Domain 'node1' destroyed
   ```

6. Exercise save/restore (hibernate to a file) and managed save:

   ```console
   $ virsh start node1
   $ virsh save node1 /var/tmp/node1.save
   Domain 'node1' saved to /var/tmp/node1.save
   $ virsh restore /var/tmp/node1.save
   Domain 'node1' restored from /var/tmp/node1.save

   $ virsh managedsave node1     # save state; auto-restored on next 'start'
   ```

7. Set autostart, then remove the domain definition (leaving disks intact):

   ```console
   $ virsh autostart node1
   Domain 'node1' marked as autostarted

   $ virsh destroy node1
   $ virsh undefine node1
   Domain 'node1' has been undefined
   ```

**Comprehension check 4**

- **4a.** Put these in order from "least destructive to guest state" to "most": `suspend`, `destroy`, `shutdown`, `save`. For each, state whether the guest OS has to cooperate.
- **4b.** `virsh shutdown node1` prints success but the VM is still running two minutes later. Give two independent reasons this happens.
- **4c.** What is the difference between `virsh save` + `virsh restore` and `virsh managedsave`? Where does the memory image live in each case, and what triggers the restore?
- **4d.** After `virsh undefine node1`, the qcow2 disk is still on disk. Which single flag to `undefine` would have deleted the storage too, and why is it off by default?
- **4e.** A domain started with `virsh create foo.xml` disappears entirely after `virsh destroy`. One started with `virsh define foo.xml` + `virsh start` survives it as `shut off`. What is the term for these two kinds of domain?

---

## Exercise 5 — Live-editing domain XML and hot-plugging devices

**Goal:** Modify a defined domain safely with `virsh edit`, and understand persistent vs live changes.

1. Dump the *inactive* (persistent) definition and the *live* one, and note libvirt fills in defaults you did not write:

   ```console
   $ virsh dumpxml --inactive node1 | head -n 5
   $ virsh dumpxml node1 > node1-live.xml       # running domain: includes assigned ports, seclabels
   ```

2. Edit the persistent definition. `virsh edit` opens `$EDITOR`, then **validates the XML against the RNG schema before saving** — a syntax error is rejected and you are offered a re-edit:

   ```console
   $ virsh edit node1
   # change <vcpu ...>2</vcpu> to 4, save, quit
   Domain 'node1' XML configuration edited.
   ```

3. Prove the change is persistent-only while the domain runs — attach a second disk *live* and *persistently* with `attach-device`:

   Create `extra-disk.xml`:

   ```xml
   <disk type='file' device='disk'>
     <driver name='qemu' type='raw'/>
     <source file='/srv/libvirt/lab-images/swap.raw'/>
     <target dev='vdb' bus='virtio'/>
   </disk>
   ```

   ```console
   $ virsh start node1
   $ virsh attach-device node1 extra-disk.xml --live --config
   Device attached successfully

   $ virsh domblklist node1
    Target   Source
   ---------------------------------------------------
    vda      /srv/libvirt/lab-images/node1.qcow2
    vdb      /srv/libvirt/lab-images/swap.raw
   ```

4. Detach it again, live and from config:

   ```console
   $ virsh detach-device node1 extra-disk.xml --live --config
   Device detached successfully
   ```

5. Adjust running memory within the configured maximum, and list interfaces:

   ```console
   $ virsh setmem node1 768M --live
   $ virsh domiflist node1
    Interface   Type      Source         Model    MAC
   -----------------------------------------------------------------------
    vnet0       network   lab-isolated   virtio   52:54:00:aa:bb:cc
   ```

**Comprehension check 5**

- **5a.** You raised `<vcpu>` to 4 with `virsh edit` while `node1` was running, but `virsh dominfo` still shows `CPU(s): 2`. Why, and when will the 4 take effect?
- **5b.** Explain the roles of the `--live`, `--config`, and `--current` flags on `attach-device`. Which combination changes a running VM *and* survives a full power cycle?
- **5c.** Why does `virsh dumpxml node1` (running) show more elements than the `node1.xml` you originally wrote — name two categories libvirt injected.
- **5d.** A hand-edit via `virsh edit` fails to save with a schema error. Did libvirt corrupt your existing definition? What does the tool do on invalid input?

---

## Exercise 6 — Provisioning a guest end-to-end with `virt-install`

**Goal:** Use `virt-install` to build, define and boot a guest in one command, plus the `--import` path for an existing disk.

1. Discover the OS-variant identifiers `virt-install` understands (used to apply optimal defaults):

   ```console
   $ virt-install --osinfo list | grep -i alpine
   alpinelinux3.19
   alpinelinux3.20
   ...
   ```

2. Full install from a network location into a fresh volume, with a serial console and no graphics (headless):

   ```console
   $ virt-install \
       --name web1 \
       --memory 2048 \
       --vcpus 2 \
       --os-variant debian12 \
       --disk pool=lab-images,size=10,format=qcow2 \
       --network network=lab-isolated,model=virtio \
       --location https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/ \
       --graphics none \
       --console pty,target_type=serial \
       --extra-args 'console=ttyS0,115200n8'
   ```

   `virt-install` provisions the disk in the pool, defines the domain, starts it, and drops you onto the serial console of the installer.

3. **Import** an existing, already-installed disk image instead of running an installer (`--import` skips the install phase, boots the disk directly):

   ```console
   $ virt-install \
       --name node2 \
       --memory 1024 --vcpus 1 \
       --os-variant alpinelinux3.20 \
       --disk /srv/libvirt/lab-images/node1.qcow2,bus=virtio \
       --network network=lab-isolated \
       --import \
       --graphics none --console pty,target_type=serial
   ```

4. Verify the domain `virt-install` created is a normal libvirt domain like any other:

   ```console
   $ virsh list --all | grep node2
    -    node2   shut off
   $ virsh dumpxml node2 | grep -A2 '<os>'
   ```

5. Detach the console with `Ctrl+]`. Re-enter any running guest's console later with:

   ```console
   $ virsh console node2
   ```

**Comprehension check 6**

- **6a.** What does `--os-variant`/`--osinfo` change about the resulting domain XML? Give two concrete examples of what libosinfo picks for you.
- **6b.** Contrast `--location`, `--cdrom`, and `--import`. Which one does *not* run an OS installer, and what must already be true of the disk for it to work?
- **6c.** You ran `virt-install` with `--graphics none --console pty,target_type=serial` but `--extra-args 'console=ttyS0,...'`. Why is that `--extra-args` piece needed for `--location` installs, and why is it *not* needed once the OS is installed?
- **6d.** After `virt-install` finishes, is the resulting VM transient or persistent? How would you confirm, and where does its XML live?

---

## Exercise 7 — Snapshots and diagnostics

**Goal:** Take an internal snapshot, roll back, and use core diagnostic subcommands.

1. Create a disk+memory snapshot of a running domain (internal, stored inside the qcow2):

   ```console
   $ virsh snapshot-create-as node1 --name clean-base \
         --description "pristine after first boot"
   Domain snapshot clean-base created

   $ virsh snapshot-list node1
    Name         Creation Time               State
   ------------------------------------------------------------
    clean-base   2026-08-11 14:41:07 +0000   running
   ```

2. After making a mess in the guest, revert to it:

   ```console
   $ virsh snapshot-revert node1 clean-base
   $ virsh snapshot-current node1 | grep '<name>'
   ```

3. Core diagnostics — capabilities of the host, of a domain type, and live block/interface stats:

   ```console
   $ virsh nodeinfo
   $ virsh domcapabilities --machine q35 --arch x86_64 | grep -i sev
   $ virsh domblkstat  node1 vda
   $ virsh domifstat   node1 vnet0
   $ virsh domstats    node1 --cpu-total --balloon --vcpu
   ```

4. Delete the snapshot metadata and (for internal snapshots) its data when done:

   ```console
   $ virsh snapshot-delete node1 clean-base
   Domain snapshot clean-base deleted
   ```

**Comprehension check 7**

- **7a.** `snapshot-create-as` on a *running* domain captured `State: running`. What extra data, beyond disk contents, did it store, and what would `--disk-only` have changed?
- **7b.** Which subcommand reports host-level CPU/NUMA facts (`nodeinfo`), and which reports what a *given machine type* can do (`domcapabilities`)? Give one thing you'd only learn from the second.
- **7c.** `virsh capabilities` vs `virsh domcapabilities` — what is the audience of each?

---

## Answers

<details>
<summary>Click to reveal answers to all comprehension checks</summary>

### Exercise 1

- **1a.** Modern libvirt (default on current Debian/Fedora/RHEL) splits the old monolithic `libvirtd` into **modular per-driver daemons**: `virtqemud` (QEMU/KVM domains), `virtnetworkd` (virtual networks), `virtstoraged` (pools/volumes), `virtnodedevd`, `virtnwfilterd`, `virtsecretd`, etc. Each has its own socket and can be started/restarted independently. `libvirtd` being inactive is expected — its work is done by the modular daemons. (https://libvirt.org/daemons.html)
- **1b.** **systemd socket activation.** The `.socket` unit (e.g. `virtqemud.socket`) listens on `/run/libvirt/virtqemud-sock` and starts the service on the first client connection. The single test is simply to connect — `virsh uri` (or `virsh list`) triggers activation. If it still fails, check `systemctl status virtqemud.socket` and that the socket unit is enabled.
- **1c.** The two users are connecting to **different hypervisor URIs**. The normal user's client defaulted to `qemu:///session` (a private, per-user instance with its own set of domains), while root/`virsh` reached `qemu:///system` (the host-wide instance). It is a connection-scope issue, not file permissions. Fix by setting `LIBVIRT_DEFAULT_URI=qemu:///system` or passing `-c qemu:///system`.
- **1d.** `/etc/libvirt/qemu/` holds the persistent domain XML. You never hand-edit it because libvirt caches definitions in memory and rewrites those files; direct edits can be overwritten and bypass RNG validation. Use `virsh edit <domain>` (or `virsh define`) instead.

### Exercise 2

- **2a.** `pool-define` only registers a **persistent, inactive** definition; a plain `pool-list` shows active pools only. `pool-build` (creates the target dir) then `pool-start` (activates it) make it appear. `pool-list --all` shows it in the meantime.
- **2b.** For a `dir` pool, `pool-build` creates the target directory (and sets permissions/ownership from the XML). It is separate because "build" is type-specific and sometimes destructive — for a `logical` (LVM) pool it runs `vgcreate`, for `fs`/`disk` it can format/partition. Keeping it distinct from `define` prevents accidental initialization of the backing store.
- **2c.** **Thin (sparse) provisioning**: qcow2 allocates blocks lazily, so a 20 GiB image occupies only metadata (~196 KiB) until data is written. `--allocation 20G` (equal to capacity), or `--prealloc`/`preallocation=full`, forces full up-front allocation.
- **2d.** `virsh pool-refresh lab-images`. libvirt caches the volume list; refresh re-scans the target path so out-of-band files (copied in with `cp`) are picked up.
- **2e.** LVM VG → pool type **`logical`**; NFS export → pool type **`netfs`**. (https://libvirt.org/formatstorage.html)

### Exercise 3

- **3a.** `mode='nat'` programs the host firewall (iptables/nftables masquerade rules via libvirt) so guest→outside traffic is source-NATed behind the host IP. There is no inbound DNAT, so LAN hosts have no route/port mapping back to the private `192.168.122.0/24` guest — connections must be initiated by the guest. Inbound access requires explicit port-forwarding/hook rules.
- **3b.** With no `<forward>`, it is an **isolated/host-only** network: guests can talk to each other and to the host (`10.10.0.1`) but have **no route off the host**. The bridge's `dnsmasq` still hands out DHCP leases and answers DNS for local names.
- **3c.** A **Linux bridge** (`virbr0` / `virbr-lab`) and a dedicated **`dnsmasq`** process bound to that bridge. `dnsmasq` provides both DHCP and DNS.
- **3d.** `<forward mode='bridge'/>` pointing the network/interface at a **pre-existing host bridge** (e.g. `br0`) that is enslaved to the physical NIC. The prerequisite is that host bridge configured at the OS/network layer — libvirt does not create it for you. (`route` and `open` are alternatives with different firewall behavior; `bridge` is the classic "on the LAN" answer.)
- **3e.** `net-create` starts a **transient** network from the XML — it runs until stopped or host reboot and then vanishes. `net-define` stores a **persistent** definition that survives reboot (and must then be `net-start`ed / set `net-autostart`).

### Exercise 4

- **4a.** Least → most destructive to guest state:
  1. **`save`** — full RAM+CPU state written to a file; fully restorable. No guest cooperation needed.
  2. **`suspend`** — CPU paused, RAM stays resident; instantly resumable. No guest cooperation.
  3. **`shutdown`** — requests a clean OS shutdown via ACPI. **Requires guest cooperation.**
  4. **`destroy`** — immediate forced power-off (like pulling the plug); risks data loss. No guest cooperation.
- **4b.** (1) `shutdown` sends an **ACPI power-button event** and returns immediately; if the guest OS ignores/handles it slowly (no ACPI daemon, or a prompt "are you sure?"), nothing happens. (2) The guest may lack ACPI support entirely (missing `<acpi/>` feature or no in-guest handler), so the event is never acted on. Force with `virsh destroy` or `virsh shutdown --mode acpi|agent`.
- **4c.** `save`/`restore` writes the memory image to a **path you specify** and you must explicitly `restore` that file. `managedsave` stores the image in a **libvirt-managed location** (`/var/lib/libvirt/qemu/save/…`) and it is **automatically restored on the next `virsh start`** — a transparent hibernate.
- **4d.** `virsh undefine node1 --remove-all-storage` (optionally `--nvram` for UEFI vars). It is off by default because deleting a domain definition should not silently destroy potentially shared or valuable disk images — removal of data must be opt-in.
- **4e.** `create`-only domains are **transient** (exist only while running, no persistent config). `define` + `start` domains are **persistent** (survive `destroy`/reboot as `shut off`).

### Exercise 5

- **5a.** `virsh edit` changed the **persistent (inactive) config only**; a running domain keeps its live definition. The 4 vCPUs take effect on the next full stop→start (a reboot from inside the guest is not enough — the QEMU process must be recreated). For live change you'd use `virsh setvcpus node1 4 --live` within the configured maximum.
- **5b.** `--live` affects the **running** domain immediately (this-boot only). `--config` affects the **persistent** definition (next boot). `--current` targets whatever the domain currently is (live if running, else config). **`--live --config` together** changes the running VM *and* persists across a power cycle.
- **5c.** libvirt fills in defaults and runtime data: e.g. **PCI/device addresses**, **assigned VNC/SPICE ports** (`autoport`), **security labels** (`<seclabel>`), default controllers (USB, PCIe root), and a generated UUID/MAC if omitted. Two categories: auto-assigned addresses/ports and injected default devices/controllers.
- **5d.** No — `virsh edit` **validates the new XML against the RNG schema and refuses to save on error**, leaving the previous good definition intact, and re-opens the editor so you can fix it. Your existing definition is untouched.

### Exercise 6

- **6a.** `--os-variant`/`--osinfo` feeds **libosinfo**, which selects hardware defaults tuned for that OS. Examples: it may pick **`virtio`** disk/NIC models (vs emulated IDE/e1000) when the OS supports them, choose the right **machine type / firmware / clock** tweaks, and set sensible RAM/CPU minimums. Getting it right materially affects performance and driver availability.
- **6b.** `--location` points at an installable tree/URL and **runs the installer** (can inject kernel/initrd + `--extra-args`). `--cdrom` boots an ISO and **runs the installer** from it. `--import` **does not run any installer** — it defines a domain that boots an **already-installed** disk directly; the disk must contain a bootable, provisioned OS.
- **6c.** For a `--location` install, libvirt boots the installer's kernel/initrd directly, so `console=ttyS0,115200n8` in `--extra-args` tells *that installer kernel* to use the emulated serial port — otherwise its output goes to a graphics console you disabled. Once installed, the guest's own bootloader/OS config drives the console, so the transient `--extra-args` is no longer applied (you'd configure the console persistently inside the guest instead).
- **6d.** **Persistent.** `virt-install` calls `define` + `start`, so the domain survives reboot. Confirm with `virsh list --all` (it shows even when off) and `virsh dominfo <name>` → `Persistent: yes`; its XML lives in `/etc/libvirt/qemu/<name>.xml`. (Use `--transient` to get a transient one instead.)

### Exercise 7

- **7a.** On a running domain, `snapshot-create-as` captured **both the disk state and the live VM memory/CPU state** (hence `State: running`), so reverting resumes exactly where it was. `--disk-only` would have taken a **disk-only** snapshot (no RAM), typically as an external snapshot — faster, but reverting boots the guest cold from that disk point rather than resuming.
- **7b.** `virsh nodeinfo` reports **host hardware facts** — CPU model, sockets/cores/threads, NUMA cells, total memory. `virsh domcapabilities` reports **what a specific (machine type, arch, emulator) combination can offer** — e.g. supported firmware/UEFI paths, available CPU modes/features, whether **SEV** memory encryption or particular disk buses are usable. SEV support is something only `domcapabilities` tells you.
- **7c.** `virsh capabilities` describes the **host and hypervisor** as a whole (guest arch/machine types the host can run, host CPU, NUMA topology). `virsh domcapabilities` is **scoped to one guest configuration** (given arch/machine/emulator), telling you the concrete options valid for *that* domain. Host-wide inventory vs per-domain option set.

</details>