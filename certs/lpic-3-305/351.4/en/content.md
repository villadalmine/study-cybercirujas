# Topic 351.4 — Libvirt Virtual Machine Management

> LPIC-3 305-300 · Objective 351.4 · Exam weight 15
> Level: Principal Platform Architect / Senior SRE — production-grade depth

---

## 1. Motivation: the architectural problem libvirt solves

When you run a single QEMU/KVM guest by hand, the command line is the entire "API":

```console
$ qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 \
    -drive file=/var/lib/vm/db01.qcow2,if=virtio,cache=none \
    -netdev tap,id=n0,ifname=tap0,script=no -device virtio-net,netdev=n0 \
    -vnc :0 -daemonize
```

This does not scale to a fleet. There is no persistent identity for the guest, no lifecycle state machine (it is either a running PID or nothing), no inventory, no access control, no consistent way to attach a disk on a Xen host versus a KVM host versus an LXC container, and no stable interface a config-management tool (Ansible, Terraform's `libvirt` provider, OpenStack Nova) can target. Every operational primitive — start, stop, migrate, snapshot, hot-plug a NIC — becomes a bespoke shell script wrapping a hypervisor-specific mechanism.

**Libvirt is the abstraction layer that turns "a running QEMU process" into "a managed object with a lifecycle, an identity (UUID), a declarative definition, and a uniform API."** It is the substrate underneath oVirt/RHV, OpenStack Nova, `virt-manager`, KubeVirt, and Vagrant's libvirt provider. Understanding it is understanding the control plane that every serious Linux virtualization stack builds on.

The core production problems it addresses:

| Problem without libvirt | What libvirt provides |
|---|---|
| Hypervisor-specific tooling (Xen `xl`, QEMU CLI, LXC) | One API + `virsh` across all drivers |
| No persistent guest identity | Domain UUID + name + declarative XML in `/etc/libvirt/qemu/` |
| No lifecycle state machine | `defined → running → paused → shut off`, with autostart |
| Ad-hoc host networking (manual `brctl`, `iptables`) | Managed virtual networks (NAT/routed/isolated) + dnsmasq |
| Storage sprawl, manual `qcow2` bookkeeping | Storage pools/volumes with drivers (dir, LVM, iSCSI, RBD, ZFS) |
| No remote control / RBAC | Remote transports (TLS, SSH), Polkit access control |
| No live migration primitive | `virsh migrate` with a defined protocol |

The key mental model: **libvirt is stateless glue over stateful hypervisors.** It stores *definitions*, delegates *execution* to a hypervisor driver, and reflects live state back. Restarting `libvirtd` does not kill your running guests — the QEMU processes survive; libvirt re-attaches to them.

---

## 2. Architecture: daemons, drivers, and the connection model

### 2.1 The daemon topology

Historically there was **one monolithic `libvirtd`**. Since libvirt 5.6+ (default in RHEL 9, Debian 12, Ubuntu 22.04+) it is split into **modular per-driver daemons**, each socket-activated by systemd. This matters in production for blast-radius isolation and restart granularity.

```
                        ┌─────────────────────────────────────────┐
  virsh / API client    │              libvirt library            │
  (local or remote) ───▶│         (libvirt.so, RPC client)        │
                        └───────────────────┬─────────────────────┘
                                            │ RPC over Unix socket / TLS / SSH
        ┌───────────────────────────────────┼───────────────────────────────────┐
        ▼                   ▼                ▼                ▼                    ▼
  ┌───────────┐      ┌───────────┐    ┌───────────┐   ┌───────────┐       ┌───────────┐
  │ virtqemud │      │ virtnetwork│    │ virtstora │   │ virtnodedev│      │ virtlxcd  │
  │ (QEMU/KVM)│      │ d (nets)   │    │ gedd(pools)│  │ d (host dev)│     │ (LXC)     │
  └─────┬─────┘      └─────┬─────┘    └───────────┘   └───────────┘       └───────────┘
        │                  │
        ▼                  ▼
   QEMU processes     dnsmasq + Linux bridge + nftables/iptables
```

**Monolithic vs. modular — the trade-off:**

| Dimension | Monolithic `libvirtd` | Modular `virt*d` daemons |
|---|---|---|
| Restart blast radius | Restarting cycles *all* subsystems | Restart only `virtnetworkd` without touching `virtqemud` |
| Socket activation | Single socket | Per-driver, lazy-started on first use |
| Failure isolation | One crash affects everything | Storage driver crash does not down the QEMU driver |
| Compatibility shim | — | `libvirtd.service` proxies to modular daemons for old tooling |
| Config files | `/etc/libvirt/libvirtd.conf` | `/etc/libvirt/virtqemud.conf`, `virtnetworkd.conf`, … |

To check which model your host runs:

```console
$ systemctl list-unit-files 'virt*d.service' 'libvirtd.service'
UNIT FILE              STATE     PRESET
libvirtd.service       disabled  disabled
virtqemud.service      static    disabled
virtnetworkd.service   static    disabled
virtstoraged.service   static    disabled
virtnodedevd.service   static    disabled
...

$ systemctl status virtqemud.socket
● virtqemud.socket - Libvirt qemu local socket
     Loaded: loaded (/usr/lib/systemd/system/virtqemud.socket; enabled)
     Active: active (listening) since Tue 2026-08-11 09:14:22 UTC; 3h ago
   Triggers: ● virtqemud.service
     Listen: /run/libvirt/virtqemud-sock (Stream)
```

The `.socket` unit is what you enable; the `.service` is socket-activated on first connection. This is why `virsh list` "just works" after a fresh boot without `libvirtd` being explicitly `active`.

### 2.2 Connection URIs — the addressing scheme

Every libvirt client opens a **connection URI** that names *which driver* and *which host*. This is the single most important operational concept and a frequent exam item.

```
driver[+transport]://[user@][host][:port]/[path][?extraparameters]
```

| URI | Meaning |
|---|---|
| `qemu:///system` | Local QEMU/KVM, **system** instance (root-owned, privileged, the production one) |
| `qemu:///session` | Local QEMU/KVM, **per-user session** instance (unprivileged, user-owned guests) |
| `qemu+ssh://root@kvm01/system` | Remote KVM host over SSH tunnel |
| `qemu+tls://kvm01/system` | Remote KVM host over mutual TLS (x509 certs) |
| `xen:///system` | Local Xen |
| `lxc:///system` | Local libvirt-LXC container driver |
| `test:///default` | In-memory mock driver for testing tooling |

The **system vs. session distinction is a production security boundary**, not a convenience:

| | `qemu:///system` | `qemu:///session` |
|---|---|---|
| Runs as | `libvirt-qemu` / root-managed | The invoking user |
| Networking | Managed bridges, `virbr0`, macvtap | User-mode SLIRP (`-netdev user`) only, no bridge without helper |
| Storage default | `/var/lib/libvirt/images` | `~/.local/share/libvirt/images` |
| Autostart on boot | Yes (host daemon) | No (needs a user session/lingering) |
| Use case | Servers, shared hosts | Developer laptops, CI, rootless |

Set the default so you stop typing it:

```console
$ export LIBVIRT_DEFAULT_URI='qemu:///system'
# or persist in ~/.config/libvirt/libvirt.conf:
$ cat ~/.config/libvirt/libvirt.conf
uri_default = "qemu:///system"
```

Verify what you are actually connected to — a classic source of "my VM disappeared" tickets is a user accidentally on `qemu:///session`:

```console
$ virsh uri
qemu:///system

$ virsh -c qemu:///session list --all
 Id   Name   State
--------------------
# empty — different namespace entirely
```

---

## 3. The domain XML: libvirt's declarative unit

> **Format note:** libvirt's configuration is **XML**, not YAML. There is no YAML form; higher layers (KubeVirt, OpenStack) wrap the XML in their own YAML/JSON, but the libvirt-native manifest — which the exam tests and which `virsh define` consumes — is XML. Every manifest below is the real, syntactically valid libvirt schema.

A **domain** is a VM (or container). Its definition lives in `/etc/libvirt/qemu/<name>.xml` for the QEMU driver. **Never edit that file directly** — libvirt owns it and rewrites it. Use `virsh edit`, which validates against the RNG schema and reloads atomically.

### 3.1 Anatomy of the directory layout

```console
$ tree /etc/libvirt/
/etc/libvirt/
├── qemu/
│   ├── db01.xml              # domain definition (persistent config)
│   ├── networks/
│   │   ├── default.xml       # network definitions
│   │   └── autostart/        # symlinks -> ../default.xml for autostart
│   └── autostart/
│       └── db01.xml -> ../db01.xml   # symlink = "start on boot"
├── storage/
│   ├── default.xml           # storage pool: /var/lib/libvirt/images
│   └── autostart/
├── nwfilter/                 # network filter (firewall) rules
├── qemu.conf                 # QEMU driver config (security, user, TLS)
├── virtqemud.conf
└── libvirt.conf
```

`autostart` is **implemented as a symlink**, not a flag in the XML — a detail that trips people up. `virsh autostart <dom>` creates the symlink; `virsh autostart --disable <dom>` removes it.

### 3.2 A complete, production-grade KVM domain (full manifest, unabridged)

This is a realistic database-server guest: virtio everywhere, host-passthrough CPU, hugepages, a bridged NIC, a serial console, a guest agent channel, and a RNG device. Save as `db01.xml` and `virsh define db01.xml`.

```xml
<domain type='kvm'>
  <name>db01</name>
  <uuid>7b8f4c2e-1a3d-4f6b-9e0c-2d5a8b1f3c7e</uuid>
  <title>PostgreSQL primary — prod</title>
  <description>Managed by IaC. Do not edit by hand.</description>

  <!-- Memory: 8 GiB, backed by 1 GiB hugepages for TLB efficiency -->
  <memory unit='GiB'>8</memory>
  <currentMemory unit='GiB'>8</currentMemory>
  <memoryBacking>
    <hugepages>
      <page size='1' unit='GiB'/>
    </hugepages>
    <locked/>            <!-- prevent host from swapping guest RAM -->
  </memoryBacking>

  <!-- 4 vCPUs pinned for NUMA locality and predictable latency -->
  <vcpu placement='static'>4</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='3'/>
    <vcpupin vcpu='2' cpuset='4'/>
    <vcpupin vcpu='3' cpuset='5'/>
    <emulatorpin cpuset='0-1'/>   <!-- keep QEMU I/O threads off vCPU cores -->
  </cputune>

  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' secure='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE.secboot.fd</loader>
    <nvram>/var/lib/libvirt/qemu/nvram/db01_VARS.fd</nvram>
    <boot dev='hd'/>
    <bootmenu enable='no'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <smm state='on'/>          <!-- required for UEFI Secure Boot -->
  </features>

  <!-- Expose host CPU model verbatim: max performance, breaks live migration
       to non-identical hardware. Use 'host-model' if you need portability. -->
  <cpu mode='host-passthrough' check='none'>
    <topology sockets='1' dies='1' cores='4' threads='1'/>
    <feature policy='require' name='vmx'/>
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

    <!-- Primary disk: qcow2 on virtio-blk, native AIO, no host cache
         (cache=none is mandatory for safe live migration + O_DIRECT) -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'
              discard='unmap' detect_zeroes='unmap'/>
      <source file='/var/lib/libvirt/images/db01.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
    </disk>

    <!-- Dedicated data disk from an LVM pool -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native'/>
      <source dev='/dev/vg_data/db01_data'/>
      <target dev='vdb' bus='virtio'/>
    </disk>

    <controller type='scsi' model='virtio-scsi' index='0'/>
    <controller type='usb' model='qemu-xhci'/>
    <controller type='pci' model='pcie-root'/>

    <!-- Bridged NIC on the host's br0: guest is a first-class L2 citizen -->
    <interface type='bridge'>
      <mac address='52:54:00:6b:3a:1f'/>
      <source bridge='br0'/>
      <model type='virtio'/>
      <driver name='vhost' queues='4'/>   <!-- multiqueue = 1 queue per vCPU -->
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0'/>
    </interface>

    <!-- Serial console: the ONLY console you can `virsh console` into -->
    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <!-- QEMU guest agent: enables `virsh shutdown` graceful, fsfreeze,
         guest IP reporting, and consistent snapshots -->
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>

    <!-- Entropy source: avoids guest RNG starvation -->
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>

    <!-- Balloon for memory reclaim -->
    <memballoon model='virtio'/>

    <!-- Headless server: VNC bound to localhost, reach via SSH tunnel only -->
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='virtio' heads='1'/>
    </video>
  </devices>

  <!-- SELinux/sVirt confinement: each guest gets a unique MCS category -->
  <seclabel type='dynamic' model='selinux' relabel='yes'/>
</domain>
```

**Every one of these choices is a trade-off.** The block that most often causes production incidents:

| Setting | Chosen value | Alternative | Consequence of the choice |
|---|---|---|---|
| `<cpu mode>` | `host-passthrough` | `host-model` / named model | Max perf, but **live migration fails** to different CPUs |
| `cache` | `none` | `writeback` | Migration-safe + crash-safe; slightly lower throughput than `writeback` |
| `<disk driver io>` | `native` | `threads` | `native` needs `cache=none`; lower CPU overhead |
| `machine` | `q35` (PCIe) | `pc` (i440FX) | Modern, needed for PCIe passthrough; `pc` is legacy but universally compatible |
| firmware | UEFI (OVMF) | SeaBIOS | Secure Boot + >2 TB boot disks; BIOS is simpler, faster boot |

### 3.3 Reading the live vs. persistent config

A subtle but critical distinction for troubleshooting: `virsh dumpxml` shows **live (running) state** including runtime-allocated PCI addresses and VNC ports; `virsh dumpxml --inactive` shows the **persistent on-disk definition**. Hot-plugged devices appear in live but not inactive until you also persist with `--config`.

```console
$ virsh dumpxml db01 | grep -A1 '<graphics'
    <graphics type='vnc' port='5900' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
# note: port is now resolved to 5900 (was -1/autoport in the definition)

$ virsh dumpxml --inactive db01 | grep '<graphics'
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'>
```

---

## 4. Domain lifecycle management with `virsh`

`virsh` is the reference CLI. It works one-shot or **interactive** (a REPL — an explicit exam knowledge area).

```console
$ virsh
Welcome to virsh, the virtualization interactive terminal.

Type:  'help' for help with commands
       'quit' to quit

virsh # list --all
 Id   Name    State
------------------------
 1    db01    running
 -    web01   shut off

virsh # domstate db01 --reason
running (booted)

virsh # quit
$
```

### 4.1 The state machine

```
                virsh define
   (nothing) ─────────────────▶  [ shut off / defined ]
        ▲                              │  virsh start
        │ virsh undefine               ▼
        │                        [ running ]
        │                          │      ▲
        │            virsh suspend │      │ virsh resume
        │                          ▼      │
        │                        [ paused ]
        │  virsh destroy (hard)          │  virsh shutdown (ACPI/agent, graceful)
        └────────────────────────────────┘
```

Key operational commands and what they *actually do*:

| Command | Mechanism | When to use |
|---|---|---|
| `virsh define x.xml` | Writes persistent config, does **not** start | Provisioning |
| `virsh create x.xml` | Starts a **transient** domain (no persistent config; vanishes on stop) | Ephemeral/CI guests |
| `virsh start db01` | Boots a defined domain | Normal start |
| `virsh shutdown db01` | Sends ACPI event / uses guest agent — **graceful** | Normal stop |
| `virsh shutdown db01 --mode agent` | Forces the guest-agent path | When ACPI is ignored |
| `virsh destroy db01` | **Kills** the QEMU process (like pulling power) | Hung guest only |
| `virsh reboot db01` | Graceful reboot (ACPI/agent) | Normal reboot |
| `virsh reset db01` | Hard reset (no clean shutdown) | Wedged guest |
| `virsh undefine db01` | Removes persistent config | Decommission |
| `virsh managedsave db01` | Saves RAM state to disk, stops guest; restored on next start | Host maintenance |

Worked decommission that avoids the classic footgun (`undefine` leaving orphaned NVRAM/storage):

```console
$ virsh shutdown db01
Domain 'db01' is being shutdown

$ virsh undefine db01 --nvram --remove-all-storage
Domain 'db01' has been undefined
Volume 'vda'(/var/lib/libvirt/images/db01.qcow2) removed.
```

Without `--nvram` on a UEFI guest, `undefine` refuses:

```console
$ virsh undefine db01
error: Requested operation is not valid: cannot undefine domain with nvram
```

### 4.2 Hot-plug: attach a disk to a running guest, live

```console
$ qemu-img create -f qcow2 /var/lib/libvirt/images/db01-logs.qcow2 50G
Formatting '/var/lib/libvirt/images/db01-logs.qcow2', fmt=qcow2 size=53687091200

$ virsh attach-disk db01 /var/lib/libvirt/images/db01-logs.qcow2 vdc \
    --driver qemu --subdriver qcow2 --cache none --persistent --live
Disk attached successfully

# Verify the guest saw it (via guest agent):
$ virsh qemu-agent-command db01 \
    '{"execute":"guest-exec","arguments":{"path":"/usr/bin/lsblk","capture-output":true}}'
```

`--live` applies to the running domain; `--persistent` also writes it into the on-disk XML so it survives a reboot. Omitting one is a frequent "the disk vanished after reboot" cause.

---

## 5. Libvirt networking

Libvirt networks are managed L2 domains. The `default` network is created by most distros and is a **NAT network on the `virbr0` bridge** with a built-in **dnsmasq** providing DHCP + DNS for `192.168.122.0/24`.

### 5.1 The four forwarding modes — trade-off table

| Mode | `<forward>` | Guest reachability | Host bridge | Typical use |
|---|---|---|---|---|
| **NAT** | `mode='nat'` | Outbound only; inbound needs port-forward | `virbr0` + nftables MASQUERADE | Default; dev/test, guests need internet but not inbound |
| **Routed** | `mode='route'` | Bidirectional if host routes the subnet | `virbr0`, no NAT | Guests as routable hosts on a managed subnet |
| **Isolated** | *(no `<forward>`)* | Guest↔guest only, no host/external | `virbr0`, no forwarding | Air-gapped east-west, heartbeat nets |
| **Bridged** | `mode='bridge'` to `br0` | Full L2 peer on the physical LAN | Your own `br0` (not managed by libvirt) | Production servers that must be first-class LAN citizens |
| **Open** | `mode='open'` | Like routed but libvirt adds **no** firewall rules | `virbr0` | You manage firewalling yourself |

**The NAT-vs-bridged decision is the single biggest production networking choice.** NAT is self-contained (works on a laptop with one flaky Wi-Fi NIC) but hides guests behind the host. Bridged makes each guest a real host on the LAN (own IP from the LAN's DHCP, reachable inbound) but requires you to pre-build the host bridge and the physical network to tolerate many MACs per port.

### 5.2 Complete network manifest — a routed network with DHCP + static leases

```xml
<network>
  <name>prod-app</name>
  <uuid>c5f3d8a1-9b2e-4c7d-8f1a-6e3b0d5c2a9f</uuid>
  <forward mode='route'/>
  <bridge name='virbr10' stp='on' delay='0'/>
  <mac address='52:54:00:aa:bb:cc'/>
  <domain name='prod-app.internal' localOnly='yes'/>
  <dns>
    <host ip='10.20.0.10'>
      <hostname>db01</hostname>
    </host>
    <forwarder addr='10.0.0.53'/>
  </dns>
  <ip address='10.20.0.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.20.0.100' end='10.20.0.200'/>
      <!-- Pin critical guests to stable IPs by MAC -->
      <host mac='52:54:00:6b:3a:1f' name='db01' ip='10.20.0.10'/>
      <host mac='52:54:00:6b:3a:20' name='db02' ip='10.20.0.11'/>
    </dhcp>
  </ip>
</network>
```

Define, autostart, and start it:

```console
$ virsh net-define prod-app.xml
Network prod-app defined from prod-app.xml

$ virsh net-autostart prod-app
Network prod-app marked as autostarted

$ virsh net-start prod-app
Network prod-app started

$ virsh net-list --all
 Name       State    Autostart   Persistent
----------------------------------------------
 default    active   yes         yes
 prod-app   active   yes         yes
```

Inspect the underlying plumbing libvirt built for you:

```console
$ ip -br addr show virbr10
virbr10          UP             10.20.0.1/24

$ ps aux | grep -m1 'dnsmasq.*virbr10'
libvirt+   4821  0.0  0.0  ... /usr/sbin/dnsmasq
  --conf-file=/var/lib/libvirt/dnsmasq/prod-app.conf
  --leasefile-ro --dhcp-script=/usr/libexec/libvirt_leaseshelper

$ virsh net-dhcp-leases prod-app
 Expiry Time           MAC address         Protocol   IP address       Hostname   Client ID
--------------------------------------------------------------------------------------------
 2026-08-11 15:22:10   52:54:00:6b:3a:1f   ipv4       10.20.0.10/24    db01       -
```

**libvirt writes host firewall rules.** On modern hosts it uses the `nftables` backend (configurable via `firewall_backend` in `network.conf`); older ones use `iptables`. Inspect what NAT is doing:

```console
$ nft list table ip libvirt_network | grep -A3 'chain forward'
        chain forward {
                type filter hook forward priority filter; policy accept;
                iifname "virbr0" ip saddr 192.168.122.0/24 accept
                oifname "virbr0" ip daddr 192.168.122.0/24 ct state established,related accept
```

---

## 6. Storage pools and volumes

A **pool** is a source of storage (a directory, an LVM VG, an iSCSI target, a Ceph RBD pool, a ZFS dataset). A **volume** is an allocatable chunk (a file, an LV, a LUN). This decouples the domain XML from *where* the bytes physically live.

### 6.1 Pool type trade-offs

| Pool `type` | Backing | Thin provision | Snapshots | Live migration | Best for |
|---|---|---|---|---|---|
| `dir` | Filesystem directory (qcow2/raw files) | qcow2 yes | qcow2 internal/external | Needs shared FS (NFS) | Default, simple hosts |
| `logical` | LVM volume group | LVM thin pool | LVM snapshots | Shared storage needed | Bare-metal perf, no qcow2 overhead |
| `netfs` | NFS/GlusterFS mount | via qcow2 | qcow2 | **Yes** (shared) | Small clusters, live migration |
| `iscsi` / `iscsi-direct` | iSCSI LUNs | Array-dependent | Array-dependent | Yes | SAN-backed |
| `rbd` | Ceph RADOS block | Yes | Native Ceph | **Yes** | Scale-out cloud (OpenStack) |
| `zfs` | ZFS zvols | Yes | Native ZFS | Local only | Data-integrity-focused hosts |

### 6.2 Complete LVM-thin pool manifest + volume lifecycle

```xml
<pool type='logical'>
  <name>vg_data</name>
  <source>
    <name>vg_data</name>
    <format type='lvm2'/>
  </source>
  <target>
    <path>/dev/vg_data</path>
  </target>
</pool>
```

```console
$ virsh pool-define vg_data.xml
Pool vg_data defined from vg_data.xml

$ virsh pool-autostart vg_data
Pool vg_data marked as autostarted

$ virsh pool-start vg_data
Pool vg_data started

$ virsh pool-list --all --details
 Name       State    Autostart   Persistent   Capacity    Allocation   Available
---------------------------------------------------------------------------------
 default    running  yes         yes          457.20 GiB  120.14 GiB   337.06 GiB
 vg_data    running  yes         yes          931.51 GiB  200.00 GiB   731.51 GiB

# Carve a volume and it becomes a real LV:
$ virsh vol-create-as vg_data db01_data 100G
Vol db01_data created

$ virsh vol-list vg_data
 Name        Path
--------------------------------------
 db01_data   /dev/vg_data/db01_data

$ lvs vg_data
  LV         VG       Attr       LSize    Pool  Origin Data%
  db01_data  vg_data  -wi-a----- 100.00g
```

For a directory pool with qcow2, the equivalent volume creation:

```console
$ virsh vol-create-as default web01.qcow2 40G --format qcow2
Vol web01.qcow2 created

$ virsh vol-info --pool default web01.qcow2
Name:           web01.qcow2
Type:           file
Capacity:       40.00 GiB
Allocation:     196.00 KiB       <-- thin: allocated grows on write
```

---

## 7. Container-based domains (the libvirt-LXC driver)

An explicit exam knowledge area: libvirt manages **both hypervisor and container domains** through the same API. The LXC driver (`lxc:///system`) runs an OS container as a `<domain type='lxc'>` — same `virsh` verbs, different `<os>`/`<devices>` semantics (an `init` binary instead of a kernel/BIOS). This is *libvirt-LXC*, distinct from the LXD/`lxc` userspace tool.

```xml
<domain type='lxc'>
  <name>ct-web01</name>
  <memory unit='MiB'>512</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='x86_64'>exe</type>
    <init>/sbin/init</init>       <!-- container PID 1, not a kernel -->
  </os>
  <features>
    <privnet/>                    <!-- private network namespace -->
  </features>
  <on_poweroff>destroy</on_poweroff>
  <devices>
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='/srv/containers/web01/rootfs'/>
      <target dir='/'/>
    </filesystem>
    <interface type='network'>
      <source network='default'/>
    </interface>
    <console type='pty'/>
    <!-- Cgroup memory/CPU limits are enforced by the LXC driver -->
  </devices>
</domain>
```

```console
$ virsh -c lxc:///system define ct-web01.xml
Domain 'ct-web01' defined from ct-web01.xml

$ virsh -c lxc:///system start ct-web01
Domain 'ct-web01' started

$ virsh -c lxc:///system list
 Id   Name       State
--------------------------
 3    ct-web01   running

$ virsh -c lxc:///system console ct-web01
Connected to domain 'ct-web01'
Escape character is ^]
```

**Trade-off note:** libvirt-LXC gives you a *uniform control plane* over VMs and containers, but it is far less used than KVM and offers weaker isolation than a real VM. For production container workloads, Kubernetes/Podman are the mainstream choice; libvirt-LXC exists to demonstrate driver uniformity and for niche "manage everything through one API" cases.

---

## 8. Provisioning and consoles: virt-install, virt-viewer, virt-manager

The exam expects *awareness* of these; here is the operational reality.

| Tool | Layer | Role |
|---|---|---|
| `virt-install` | CLI (part of `virt-manager` pkg) | Scripts the *creation* of a domain — generates the XML and kicks off the install |
| `virt-viewer` | GUI client | Attaches a SPICE/VNC display to one existing guest |
| `virt-manager` | GUI (GTK) | Full desktop management console (inventory, wizards, console) |
| `virsh` | CLI | The scriptable reference tool for everything |
| `virt-clone` | CLI | Clone a domain (rewrites MAC/UUID/disk paths) |

A headless, fully-scripted install with `virt-install` (the production-friendly path — no GUI, reproducible):

```console
$ virt-install \
    --name web02 \
    --memory 4096 \
    --vcpus 2 \
    --cpu host-model \
    --os-variant debian12 \
    --disk pool=default,size=40,format=qcow2,bus=virtio,cache=none \
    --network network=prod-app,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --location 'https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/' \
    --extra-args 'console=ttyS0,115200n8 auto=true priority=critical' \
    --noautoconsole

Starting install...
Retrieving 'linux'                                       | 8.0 MB  00:00:01
Retrieving 'initrd.gz'                                   |  30 MB  00:00:03
Allocating 'web02.qcow2'                                 |  40 GB  00:00:00
Domain installation still in progress. Waiting for it to complete.
```

`--os-variant` is not cosmetic: it drives `osinfo-db` to pick optimal defaults (virtio drivers, clock, disk bus). Query valid values:

```console
$ virt-install --os-variant list | grep -i debian12
debian12  : Debian 12
```

Clone for a fleet, letting libvirt regenerate identity to avoid MAC/UUID collisions:

```console
$ virt-clone --original web02 --name web03 --auto-clone
Allocating 'web03.qcow2'                                 |  40 GB  00:00:12
Clone 'web03' created successfully.
```

Then reach a graphical console from a workstation over SSH transport, no VPN, no open VNC port:

```console
$ virt-viewer --connect qemu+ssh://root@kvm01/system web02
```

---

## 9. Verification and failure-diagnosis playbook

This is where SRE value concentrates. Below are the failure classes I actually see in production and the exact commands to isolate them.

### 9.1 First-response health check

```console
$ virsh version
Compiled against library: libvirt 10.0.0
Using library: libvirt 10.0.0
Using API: QEMU 10.0.0
Running hypervisor: QEMU 8.2.2

$ virsh nodeinfo
CPU model:           x86_64
CPU(s):              16
CPU frequency:       3200 MHz
CPU socket(s):       1
Core(s) per socket:  8
Thread(s) per core:  2
NUMA cell(s):        1
Memory size:         65536000 KiB

$ virsh capabilities | xmllint --xpath '//host/cpu/model/text()' -
Skylake-Server-IBRS
```

### 9.2 "KVM is not available / VM is slow" — is hardware virt actually on?

```console
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                    : PASS
  QEMU: Checking if device /dev/kvm exists                      : PASS
  QEMU: Checking if device /dev/kvm is accessible               : PASS
  QEMU: Checking for cgroup 'cpu' controller support            : PASS
  QEMU: Checking for cgroup 'memory' controller support         : PASS
  QEMU: Checking for hardware virtualization                    : PASS

# If FAIL on hardware virtualization:
$ grep -Eoc '(vmx|svm)' /proc/cpuinfo
0                          # 0 = disabled in BIOS/firmware, or nested off
$ lsmod | grep kvm
kvm_intel             376832  0
kvm                  1146880  1 kvm_intel
```

If `kvm_intel` is absent, VT-x is disabled in firmware and QEMU silently falls back to TCG emulation — the guest boots but at ~1/20th speed. This is the #1 "why is my VM so slow" ticket.

### 9.3 Guest failed to start — read the per-domain QEMU log

libvirt's own error is often generic; the *real* error is in the QEMU log:

```console
$ virsh start db01
error: Failed to start domain 'db01'
error: internal error: process exited while connecting to monitor: ...

$ tail -n 20 /var/log/libvirt/qemu/db01.log
2026-08-11T12:04:11.882Z qemu-system-x86_64: -object memory-backend-file,...:
  unable to map backing store for guest RAM: Cannot allocate memory
# --> hugepages requested but the host pool is empty
```

Fix and verify hugepages backing:

```console
$ cat /proc/meminfo | grep -i huge
HugePages_Total:       0
HugePages_Free:        0
Hugepagesize:    1048576 kB

$ echo 8 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
$ grep HugePages_Total /proc/meminfo
HugePages_Total:       8
```

### 9.4 sVirt / SELinux permission denial (the silent killer)

A guest that references a disk outside the labeled pool fails with a confusing permissions error even though Unix perms look fine:

```console
$ tail /var/log/libvirt/qemu/db01.log
qemu-system-x86_64: Could not open '/data/extra.qcow2': Permission denied

$ ls -Z /data/extra.qcow2
unconfined_u:object_r:default_t:s0 /data/extra.qcow2   # wrong label

# sVirt expects svirt_image_t; either relabel or let libvirt manage it:
$ semanage fcontext -a -t svirt_image_t '/data(/.*)?'
$ restorecon -Rv /data
$ ls -Z /data/extra.qcow2
system_u:object_r:svirt_image_t:s0 /data/extra.qcow2

$ ausearch -m avc -ts recent | grep qemu     # confirm no fresh denials
<no matches>
```

### 9.5 Guest has no network / no DHCP lease

Systematic bottom-up isolation:

```console
$ virsh domiflist db01
 Interface   Type      Source     Model     MAC
-------------------------------------------------------------
 vnet3       network   prod-app   virtio    52:54:00:6b:3a:1f

$ virsh net-info prod-app
Name:           prod-app
Active:         yes
Persistent:     yes
Autostart:      yes
Bridge:         virbr10

$ bridge link show | grep virbr10
7: vnet3@virbr10: <BROADCAST,MULTICAST,UP,LOWER_UP> ... master virbr10 state forwarding

$ virsh net-dhcp-leases prod-app        # is dnsmasq handing out a lease?
 Expiry Time   MAC address   Protocol   IP address   Hostname   Client ID
 (empty)  <-- guest never DHCP'd: check guest-side, or a MAC filter/nwfilter

# Confirm the guest's own view via the agent:
$ virsh domifaddr db01 --source agent
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------
 enp1s0     52:54:00:6b:3a:1f    ipv4         10.20.0.10/24
 lo         00:00:00:00:00:00    ipv4         127.0.0.1/8
```

`--source agent` requires the QEMU guest agent (the `<channel org.qemu.guest_agent.0>` from §3.2). Without it, `virsh domifaddr` falls back to `--source lease`, which only knows what dnsmasq leased — blind to static-configured guests.

### 9.6 Snapshot and consistency — the guest-agent-driven quiesce

An unquiesced disk snapshot of a running database is crash-consistent at best. With the guest agent, libvirt can `fsfreeze` the guest filesystems for an application-consistent snapshot:

```console
$ virsh snapshot-create-as db01 pre-upgrade \
    --diskspec vda,file=/var/lib/libvirt/images/db01-pre.qcow2 \
    --disk-only --atomic --quiesce
Domain snapshot pre-upgrade created

$ virsh snapshot-list db01
 Name          Creation Time               State
------------------------------------------------------------
 pre-upgrade   2026-08-11 12:31:07 +0000   disk-snapshot
```

`--quiesce` fails loudly if the agent is missing — which is the correct behavior; a *silently* crash-consistent snapshot is worse than a failed one because you discover the corruption only at restore time.

### 9.7 Live-migration readiness check

```console
$ virsh migrate --live --verbose db01 qemu+ssh://kvm02/system
error: Unsafe migration: Migration without shared storage is unsafe

# Root cause: cache != none, or storage not shared. Either add --unsafe
# (dangerous) or fix the actual precondition:
$ virsh dumpxml db01 | grep 'driver name'
      <driver name='qemu' type='qcow2' cache='writeback' io='native'/>
#                                       ^^^^^^^^^ must be 'none' for safe migration

$ virsh migrate --live --verbose --persistent --undefinesource \
    db01 qemu+ssh://kvm02/system
Migration: [100 %]
```

### 9.8 Event stream — watch state transitions in real time

For diagnosing flapping guests or watchdog-triggered reboots:

```console
$ virsh event --domain db01 --event lifecycle --loop
event 'lifecycle' for domain 'db01': Suspended Migrated
event 'lifecycle' for domain 'db01': Resumed Migrated
event 'lifecycle' for domain 'db01': Stopped Migrated
```

---

## 10. Access control and remote operation (production hardening)

`qemu:///system` is root-equivalent — anyone who can open that socket can run arbitrary code as the guest. Two enforcement points:

1. **Unix socket group** — membership in `libvirt` grants read-write access (`unix_sock_rw_perms` / `access_drivers` in `virtqemud.conf`).
2. **Polkit** — fine-grained action authorization (e.g., allow start/stop but not `undefine`).

```console
$ getent group libvirt
libvirt:x:964:alice,ops-oncall

$ cat /etc/libvirt/virtqemud.conf | grep -E '^(auth_unix_rw|access_drivers)'
auth_unix_rw = "polkit"
access_drivers = [ "polkit" ]
```

A Polkit rule granting the `ops` group read-only `virsh list`/`dumpxml` but denying mutating actions:

```javascript
// /etc/polkit-1/rules.d/60-libvirt-ops-readonly.rules
polkit.addRule(function(action, subject) {
    if (action.id == "org.libvirt.api.domain.getattr" &&
        subject.isInGroup("ops")) {
        return polkit.Result.YES;
    }
    if (action.id.indexOf("org.libvirt.api.domain.write") === 0 &&
        subject.isInGroup("ops")) {
        return polkit.Result.NO;
    }
});
```

For remote management, **prefer `qemu+tls://` with x509 mutual auth** for automated control planes (no interactive SSH keys, revocable certs) and `qemu+ssh://` for human admins. Never expose the raw `tcp://` transport (unauthenticated) on anything but an isolated management VLAN.

---

## 11. References (official sources)

- LPI — Exam 305-300 Objectives (Topic 351.4): https://www.lpi.org/our-certifications/exam-305-objectives/
- libvirt — Project documentation home: https://libvirt.org/docs.html
- libvirt — Domain XML format reference: https://libvirt.org/formatdomain.html
- libvirt — Network XML format reference: https://libvirt.org/formatnetwork.html
- libvirt — Storage pool & volume XML format: https://libvirt.org/formatstorage.html
- libvirt — Storage management drivers: https://libvirt.org/storage.html
- libvirt — Connection URIs and remote transports: https://libvirt.org/uri.html
- libvirt — Remote support (TLS/SSH): https://libvirt.org/remote.html
- libvirt — Modular daemons (`virtqemud`, `virtnetworkd`, …): https://libvirt.org/daemons.html
- libvirt — Access control (Polkit): https://libvirt.org/aclpolkit.html
- libvirt — sVirt / SELinux confinement: https://libvirt.org/drvqemu.html#security
- libvirt — LXC container driver: https://libvirt.org/drvlxc.html
- libvirt — Networking (virtual networks, NAT/routed/bridged): https://wiki.libvirt.org/Networking.html
- libvirt — `virsh` command reference: https://libvirt.org/manpages/virsh.html
- virt-install / virt-clone man pages: https://virt-manager.org/
- QEMU — System emulation & KVM: https://www.qemu.org/docs/master/system/introduction.html
- Linux KVM — Kernel virtualization: https://linux-kvm.org/page/Documents
- OVMF / UEFI firmware for guests: https://github.com/tianocore/tianocore.github.io/wiki/OVMF
- osinfo-db (`--os-variant` data): https://gitlab.com/libosinfo/osinfo-db