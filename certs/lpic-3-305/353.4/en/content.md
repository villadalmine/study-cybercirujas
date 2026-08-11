# Topic 353.4 — Vagrant

**LPIC-3 305-300 (Exam version 3.0) · Objective weight: 5**

> Key knowledge areas assessed: Vagrant architecture and concepts (box, provider, Vagrantfile); retrieving boxes from Vagrant Cloud; managing a project and its `Vagrantfile` (provisioning + networking); the machine lifecycle; multi-machine environments. Utilities: `Vagrantfile`, `vagrant` (`init`, `up`, `halt`, `destroy`, `suspend`, `resume`, `provision`, `reload`, `status`, `global-status`, `box`, `ssh`, `ssh-config`), Vagrant box, providers (**libvirt** and VirtualBox), provisioners (**file** and **shell**).

---

## 1. The production problem: environment drift as a first-class failure mode

The failure this objective addresses is not "how do I boot a VM" — it is **environment non-determinism**. Three concrete production incidents map to it:

1. **Onboarding latency.** A new SRE spends a day hand-assembling a local replica of a service's dependencies (a specific kernel, a `libvirt` bridge, three data services on fixed IPs). The replica is subtly wrong, so the first bug they file is a phantom.
2. **"Works on my machine."** A change passes locally and fails in CI because the local box had a package the base image lacks. The delta is invisible because the local environment was never *described*, only *accumulated*.
3. **Test-topology reproducibility.** You need to reproduce a 3-node cluster split-brain. Doing it by clicking through a hypervisor GUI is not reproducible and not reviewable.

Vagrant's answer is to make the **development/test environment a versioned artifact**: a single `Vagrantfile` (a Ruby DSL, but usually read declaratively) that a hypervisor **provider** materializes from an immutable **box**, then brings to a known state with **provisioners**. `git clone && vagrant up` replaces the day of hand-assembly, and the diff of a `Vagrantfile` is a reviewable statement of "the environment changed."

### Where Vagrant sits in the toolchain

Vagrant is an **orchestration layer for ephemeral, local/CI virtual machines**. It is deliberately *not* a machine-image builder, *not* a cloud provisioner, and *not* an in-guest configuration engine — it delegates each of those:

```
         author (Packer)                run/CI (Vagrant)              deploy (Terraform)
   ┌───────────────────────┐     ┌──────────────────────────┐   ┌──────────────────────┐
   │ golden image / box    │ ──► │ ephemeral dev/test VMs    │   │ long-lived cloud infra│
   │ metadata.json + img   │     │ Vagrantfile + provider    │   │ *.tf + state         │
   └───────────────────────┘     └──────────────────────────┘   └──────────────────────┘
                                          │ provisioner (shell/file/ansible)
                                          ▼
                                  cloud-init / Ansible / scripts (in-guest state)
```

**Mental model:** *Packer bakes, Vagrant runs, Terraform deploys, cloud-init/Ansible converge.* Packer (Objective 353.2) and Vagrant share the box concept from opposite ends — Packer emits boxes, Vagrant consumes them.

### Architecture: the five moving parts

| Component | What it is | Where it lives |
|---|---|---|
| **Vagrantfile** | Ruby DSL describing the environment; found by walking up the directory tree | project root |
| **Box** | Immutable, provider-specific base image + metadata, versioned | `~/.vagrant.d/boxes/` |
| **Provider** | Plugin that translates the abstract machine into a hypervisor call | `libvirt`, `virtualbox`, `docker`, … |
| **Provisioner** | Runs *after* boot to converge the guest to a desired state | `shell`, `file`, `ansible`, … |
| **Synced folder** | Host↔guest directory share (default `.` → `/vagrant`) | NFS / rsync / virtiofs / 9p / VirtualBox |

Per-project runtime state (the machine's provider, its ID, the generated SSH key) lives in `.vagrant/` next to the `Vagrantfile`. That directory is disposable and belongs in `.gitignore`; the `Vagrantfile` is the source of truth.

The lifecycle is a small state machine:

```
   not_created ──vagrant up──► running ──vagrant halt──► poweroff
        ▲                        │  ▲                        │
        │                  suspend│  │resume            up   │
        │                        ▼  │                        │
        └────vagrant destroy──── saved ◄────────────────────┘
                    (from any state)     vagrant reload = halt + up (re-reads Vagrantfile)
```

---

## 2. Provider architecture: libvirt vs VirtualBox (the exam's two focus providers)

A **provider** is a plugin exposing a uniform contract (`create`, `up`, `halt`, `destroy`, SSH info, synced-folder wiring) so the *same* `Vagrantfile` runs on different hypervisors. The exam names **libvirt** and **VirtualBox** specifically; on a Linux platform these are architecturally very different.

**VirtualBox** is a Type-2 hypervisor: userspace process (`VBoxHeadless`) plus kernel modules (`vboxdrv`), managed via the `VBoxManage` CLI. It is cross-platform and the historical Vagrant default, but is proprietary, slow relative to KVM, and awkward on modern secure-boot Linux (unsigned modules).

**libvirt** (via `vagrant-libvirt`) drives **QEMU/KVM** — hardware-accelerated Type-1-style virtualization through `/dev/kvm`. It is the production-grade choice on Linux: near-native performance, `virtio` paravirtualized devices, integration with the same `libvirt` stack you use in Objective 351.4, and no third-party kernel modules. Its cost is Linux-only and a heavier setup (plugin compilation, `libvirt` group/polkit, networking).

### 2.1 Provider trade-off matrix

| Dimension | **libvirt (KVM/QEMU)** | **VirtualBox** | **docker** | **vmware_desktop** |
|---|---|---|---|---|
| Hypervisor type | Type-1-ish (KVM in kernel) | Type-2 | Container (not a VM) | Type-2 |
| Performance | Near-native, `virtio` | Moderate | Native (shared kernel) | High |
| Host OS | Linux only | Linux/macOS/Windows | Linux (or via VM) | Linux/macOS/Windows |
| Kernel modules | `kvm`, `kvm_intel/amd` (in-tree) | `vboxdrv` (out-of-tree, DKMS) | none | proprietary |
| Nested virt | `cpu_mode=host-passthrough` + `nested=true` | limited | n/a | supported |
| Networking | libvirt networks, bridges, `virtio-net` | NAT + host-only | container nets | vmnet |
| Default synced folder | NFS/rsync/virtiofs/9p (must choose) | VirtualBox shared folders | bind mount | HGFS |
| Licensing | Open source (LGPL/GPL) | GPLv3 base, proprietary Ext Pack | Apache 2.0 | commercial |
| Cost of setup | High (plugin build, polkit) | Low | Low | License |
| Production fidelity to real KVM/cloud | **High** | Low | Medium | Medium |

**Rule of thumb for this cert:** on a Linux SRE workstation, use **libvirt**; reserve VirtualBox for cross-platform boxes or when a box only ships a `virtualbox` provider.

### 2.2 Boxes are provider-specific

A box is built *for* a provider. `generic/ubuntu2204` ships both `libvirt` and `virtualbox` images; `ubuntu/jammy64` (Canonical) ships **only** `virtualbox`. Asking for a provider a box doesn't publish is the single most common first-`up` failure:

```
$ vagrant up --provider=libvirt
==> default: Box 'ubuntu/jammy64' could not be found. Attempting to find and install...
The box you're attempting to add doesn't support the provider you requested.
Name: ubuntu/jammy64
Address: https://vagrantcloud.com/ubuntu/jammy64
Requested provider: ["libvirt"]
```

For libvirt, prefer the multi-provider `generic/*` boxes (by *roboxes*, built with Packer) or official `debian/*` boxes. To reuse a VirtualBox-only box under libvirt, convert it with the `vagrant-mutate` plugin.

---

## 3. Host setup for the libvirt provider (Debian/Ubuntu and Fedora)

The `vagrant-libvirt` plugin links against `libvirt` headers. On Linux the *reliable* path is the **distro-packaged** plugin, because the HashiCorp binary vendors its own `curl`/OpenSSL and frequently collides with the system libraries when compiling native gems (the classic `libcurl`/`Gem::Ext::BuildError` failures).

**Debian / Ubuntu — distro packages (recommended):**

```bash
$ sudo apt update
$ sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst dnsmasq-base ebtables nfs-kernel-server \
    vagrant vagrant-libvirt
$ sudo adduser "$USER" libvirt
$ sudo adduser "$USER" kvm
# log out/in (or: newgrp libvirt) so the group takes effect
```

**Fedora / RHEL:**

```bash
$ sudo dnf install -y @virtualization vagrant vagrant-libvirt \
    libvirt-devel ruby-devel gcc make nfs-utils
$ sudo systemctl enable --now libvirtd
$ sudo usermod -aG libvirt "$USER"
```

**HashiCorp binary + gem plugin (only if you cannot use distro packages):**

```bash
$ sudo apt install -y libvirt-dev ruby-dev gcc make pkg-config
$ vagrant plugin install vagrant-libvirt
Installing the 'vagrant-libvirt' plugin. This can take a few minutes...
Fetching vagrant-libvirt-0.12.2.gem
Installed the plugin 'vagrant-libvirt (0.12.2)'!
$ vagrant plugin list
vagrant-libvirt (0.12.2, global)
```

Verify KVM acceleration is actually available (without it QEMU silently falls back to TCG emulation — 10–50× slower):

```bash
$ lscpu | grep -E 'vmx|svm' -o | head -1
vmx
$ ls -l /dev/kvm
crw-rw----+ 1 root kvm 10, 232 Aug 11 09:04 /dev/kvm
$ virt-host-validate qemu
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if device /dev/kvm exists                                   : PASS
  QEMU: Checking if device /dev/kvm is accessible                            : PASS
  QEMU: Checking for cgroup 'cpu' controller support                         : PASS
  ...
```

---

## 4. Complete manifests (no elisions)

### 4.1 Minimal, provider-agnostic

```ruby
# Vagrantfile — the smallest useful environment
Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
end
```

`vagrant init generic/ubuntu2204` scaffolds a commented version of this. `"2"` is the configuration-schema version (v1 is Vagrant 1.0-era; always use `"2"`).

### 4.2 Production-grade single machine on libvirt (fully tuned)

```ruby
# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Single KVM/QEMU VM via vagrant-libvirt: pinned box version, virtio disks,
# host-passthrough CPU with nested virt, a private network on a fixed IP,
# an explicit rsync synced folder, and file + shell provisioning.

Vagrant.configure("2") do |config|
  config.vm.box         = "generic/ubuntu2204"
  config.vm.box_version = "4.3.12"          # pin: never let a box float in CI
  config.vm.hostname    = "web01"

  # --- Networking ---------------------------------------------------------
  # A dedicated libvirt network; vagrant-libvirt also always attaches a
  # management NIC on 192.168.121.0/24 for SSH.
  config.vm.network "private_network", ip: "192.168.50.10"

  # --- Synced folders -----------------------------------------------------
  # libvirt does NOT support VirtualBox shared folders. Disable the default
  # /vagrant NFS share and use rsync (zero host daemons, one-way host->guest).
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.synced_folder "./app", "/srv/app",
    type: "rsync",
    rsync__exclude: [".git/", "node_modules/"],
    rsync__args: ["--verbose", "--archive", "--delete", "-z"]

  # --- Provider tuning ----------------------------------------------------
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver             = "kvm"
    libvirt.memory             = 4096
    libvirt.cpus               = 2
    libvirt.cpu_mode           = "host-passthrough"  # expose real CPU flags
    libvirt.nested             = true                # allow nested KVM
    libvirt.machine_virtual_size = 40                # grow root disk to 40G
    libvirt.disk_bus           = "virtio"
    libvirt.nic_model_type     = "virtio"
    libvirt.volume_cache       = "none"              # safe + fast for dev
    libvirt.storage_pool_name  = "default"
    libvirt.default_prefix     = "web"               # domain name = web_web01
    libvirt.graphics_type      = "none"              # headless
    # Extra data disk (qcow2, virtio):
    libvirt.storage :file, size: "20G", type: "qcow2", bus: "virtio"
  end

  # --- Provisioning: file first, then shell ------------------------------
  # 1) file provisioner: copy an artifact into the guest (as the vagrant user)
  config.vm.provision "config-file", type: "file",
    source: "./files/nginx.conf",
    destination: "/tmp/nginx.conf"

  # 2) shell provisioner: idempotent inline bootstrap
  config.vm.provision "bootstrap", type: "shell", privileged: true,
    inline: <<-SHELL
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq nginx
      install -m 0644 /tmp/nginx.conf /etc/nginx/nginx.conf
      systemctl enable --now nginx
      echo "web01 provisioned on $(date -u +%FT%TZ)"
    SHELL

  # 3) shell provisioner from an external script, with arguments
  config.vm.provision "app", type: "shell",
    path: "./scripts/deploy.sh",
    args: ["v1.4.0", "production"]
end
```

Key libvirt semantics an SRE must know:
- `cpu_mode = "host-passthrough"` passes the physical CPU model straight through — required for nested virtualization and for reproducing CPU-flag-dependent behavior; it makes the box non-portable across dissimilar hosts.
- `volume_cache = "none"` uses `O_DIRECT`, avoiding double-caching in host page cache; `writeback` is faster but unsafe on host crash.
- The first synced folder is disabled and replaced, because for libvirt the default `/vagrant` share attempts **NFS**, which needs `nfs-kernel-server` + open firewall on the host — a frequent silent `up` hang.

### 4.3 Multi-machine cluster (1 control + 2 workers)

This is the "multi-machine" knowledge area. A single `Vagrantfile` defines several named machines; a Ruby loop keeps it DRY. Vagrant applies operations in definition order (and reverse order on `destroy`/`halt`).

```ruby
# Vagrantfile — reproducible 3-node lab on libvirt
#   control : 192.168.60.10  (2 vCPU / 2G)
#   worker1 : 192.168.60.21  (1 vCPU / 1G)
#   worker2 : 192.168.60.22  (1 vCPU / 1G)

WORKERS       = 2
BOX           = "generic/debian12"
NET_PREFIX    = "192.168.60"
DOMAIN        = "lab.local"

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # Shared provider defaults (overridable per machine below)
  config.vm.provider :libvirt do |v|
    v.cpu_mode     = "host-passthrough"
    v.graphics_type = "none"
    v.default_prefix = "lab"
  end

  # Push a common /etc/hosts to every node so names resolve cluster-wide
  hosts_entries = "#{NET_PREFIX}.10 control.#{DOMAIN} control\n"
  (1..WORKERS).each do |i|
    hosts_entries += "#{NET_PREFIX}.#{20 + i} worker#{i}.#{DOMAIN} worker#{i}\n"
  end

  # ---- control node ----
  config.vm.define "control", primary: true do |node|
    node.vm.hostname = "control"
    node.vm.network "private_network", ip: "#{NET_PREFIX}.10"
    node.vm.provider :libvirt do |v|
      v.memory = 2048
      v.cpus   = 2
    end
    node.vm.provision "hosts", type: "shell",
      inline: "grep -q lab.local /etc/hosts || printf '%s' \"#{hosts_entries}\" >> /etc/hosts"
    node.vm.provision "role", type: "shell",
      inline: "echo 'control-plane bootstrap here'"
  end

  # ---- worker nodes ----
  (1..WORKERS).each do |i|
    config.vm.define "worker#{i}" do |node|
      node.vm.hostname = "worker#{i}"
      node.vm.network "private_network", ip: "#{NET_PREFIX}.#{20 + i}"
      node.vm.provider :libvirt do |v|
        v.memory = 1024
        v.cpus   = 1
      end
      node.vm.provision "hosts", type: "shell",
        inline: "grep -q lab.local /etc/hosts || printf '%s' \"#{hosts_entries}\" >> /etc/hosts"
      node.vm.provision "role", type: "shell",
        inline: "echo 'joining worker#{i} to control'"
    end
  end
end
```

Targeting individual machines is by name (or a regex): `vagrant up control`, `vagrant provision worker2`, `vagrant ssh worker1`, `vagrant destroy -f /worker[12]/`.

### 4.4 Building and distributing a box

**VirtualBox** boxes can be captured from a running machine:

```bash
$ vagrant package --output web01.box
==> web01: Attempting to graceful shutdown VM...
==> web01: Exporting VM...
==> web01: Compressing package to: /home/sre/web01.box
$ vagrant box add mycompany/web01 ./web01.box
```

**libvirt** has no single-command `package`; you assemble the box tarball yourself from a sysprepped qcow2 plus a `metadata.json`:

```bash
$ sudo cp /var/lib/libvirt/images/web01.img box.img
$ sudo virt-sysprep -a box.img            # strip machine-id, SSH host keys, logs
$ qemu-img info box.img | grep 'virtual size'
virtual size: 40 GiB (42949672960 bytes)
```

```json
// metadata.json for a libvirt box
{
  "provider": "libvirt",
  "format": "qcow2",
  "virtual_size": 40
}
```

```bash
$ tar czf web01-libvirt.box ./metadata.json ./Vagrantfile ./box.img
$ vagrant box add mycompany/web01 ./web01-libvirt.box --provider libvirt
```

For repeatable box production, generate it with **Packer** (`qemu` builder + `vagrant` post-processor) rather than by hand — that is the intended Packer↔Vagrant handoff.

---

## 5. The lifecycle on the CLI (real invocations and outputs)

### 5.1 Bring-up

```bash
$ vagrant init generic/ubuntu2204
A `Vagrantfile` has been placed in this directory. You are now
ready to `vagrant up` your first virtual environment!

$ vagrant up --provider=libvirt
Bringing machine 'default' up with 'libvirt' provider...
==> default: Checking if box 'generic/ubuntu2204' version '4.3.12' is up to date...
==> default: Creating image (snapshot of base box volume).
==> default: Creating domain with the following settings...
==> default:  -- Name:              demo_default
==> default:  -- Domain type:       kvm
==> default:  -- Cpus:              2
==> default:  -- Memory:            4096M
==> default:  -- Base box:          generic/ubuntu2204
==> default:  -- Storage pool:      default
==> default:  -- Image(vda):        /var/lib/libvirt/images/demo_default.img, virtio, 40G
==> default:  -- Graphics Type:     none
==> default:  -- Management MAC:
==> default:  -- Boot device:       hd
==> default: Starting domain.
==> default: Waiting for domain to get an IP address...
==> default: Waiting for SSH to become available...
    default:
    default: Vagrant insecure key detected. Vagrant will automatically replace
    default: this with a newly generated keypair for better security.
    default: Inserting generated public key within guest...
    default: Removing insecure key from the guest if it's present...
    default: Key inserted! Disconnecting and reconnecting using new SSH key...
==> default: Setting hostname...
==> default: Configuring and enabling network interfaces...
==> default: Rsyncing folder: /home/sre/demo/app/ => /srv/app
==> default: Running provisioner: config-file (file)...
==> default: Running provisioner: bootstrap (shell)...
    default: web01 provisioned on 2026-08-11T12:31:07Z
```

Notice the **insecure key rotation**: boxes ship with a well-known keypair (`vagrant.pub`); on first boot Vagrant replaces it with a per-machine key stored in `.vagrant/machines/<name>/<provider>/private_key`.

### 5.2 Inspection

```bash
$ vagrant status
Current machine states:

default                   running (libvirt)

The Libvirt domain is running. To stop this machine, you can run
`vagrant halt`. To destroy the machine, you can run `vagrant destroy`.

$ vagrant global-status
id       name    provider state   directory
------------------------------------------------------------------------
a1b2c3d  default libvirt running /home/sre/demo

The above shows information about all known Vagrant environments
on this machine. This data is cached and may not be completely
up-to-date. Use "vagrant global-status --prune" to remove stale entries.
```

Cross-check against libvirt directly — this is the verification habit that catches state Vagrant's cache has lost:

```bash
$ virsh -c qemu:///system list
 Id   Name           State
------------------------------
 4    demo_default   running

$ virsh -c qemu:///system net-list
 Name                State    Autostart   Persistent
-------------------------------------------------------
 vagrant-libvirt     active   no          yes
 vagrant-private     active   no          yes
```

### 5.3 SSH access

```bash
$ vagrant ssh
Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 5.15.0-101-generic x86_64)
vagrant@web01:~$ ip -brief addr
lo               UNKNOWN        127.0.0.1/8
eth0             UP             192.168.121.34/24
eth1             UP             192.168.50.10/24
vagrant@web01:~$ logout

$ vagrant ssh-config
Host default
  HostName 192.168.121.34
  User vagrant
  Port 22
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile /home/sre/demo/.vagrant/machines/default/libvirt/private_key
  IdentitiesOnly yes
  LogLevel FATAL
```

`ssh-config` is what you feed to external tooling (raw `ssh`, `scp`, Ansible, an IDE remote):

```bash
$ vagrant ssh-config > .ssh-config
$ ssh -F .ssh-config default 'uname -r'
5.15.0-101-generic
$ ansible all -i "192.168.50.10," --private-key \
    .vagrant/machines/default/libvirt/private_key -u vagrant -m ping
192.168.50.10 | SUCCESS => { "ping": "pong" }
```

### 5.4 Re-provisioning, reload, and shutdown states

```bash
# Re-run only provisioners (guest stays up)
$ vagrant provision
==> default: Running provisioner: bootstrap (shell)...

# Re-read the Vagrantfile: halt + up, re-applies config changes
$ vagrant reload --provision
==> default: Attempting graceful shutdown of VM...
==> default: Starting domain.
...

# Graceful power off (disk preserved)
$ vagrant halt
==> default: Attempting graceful shutdown of VM...

# Suspend = save RAM state to disk (fast resume, consumes disk)
$ vagrant suspend
==> default: Saving VM state and suspending execution...
$ vagrant resume
==> default: Resuming suspended VM...
==> default: Waiting for domain to get an IP address...

# Tear down completely
$ vagrant destroy -f
==> default: Removing domain...
==> default: Deleting the machine folder
```

**`halt` vs `suspend` vs `destroy`** — the distinction is tested:

| Command | Guest process | Disk | RAM state | Re-`up` cost | Re-provisions? |
|---|---|---|---|---|---|
| `halt` | stopped (ACPI shutdown) | kept | discarded | full boot | no (unless `--provision`) |
| `suspend` | frozen | kept | saved to host disk | fast resume | no |
| `destroy` | removed | **deleted** | discarded | full create + provision | yes (fresh machine) |
| `reload` | halt + up | kept | discarded | full boot, re-reads Vagrantfile | only with `--provision` |

### 5.5 Box management and Vagrant Cloud

```bash
$ vagrant box list
generic/debian12   (libvirt, 4.3.12)
generic/ubuntu2204 (libvirt, 4.3.12)

$ vagrant box add generic/rocky9 --provider libvirt
==> box: Loading metadata for box 'generic/rocky9'
    box: URL: https://vagrantcloud.com/api/v2/vagrant/generic/rocky9
==> box: Adding box 'generic/rocky9' (v4.3.12) for provider: libvirt
    box: Downloading: https://vagrantcloud.com/generic/boxes/rocky9/.../libvirt.box
    box: Calculating and comparing box checksum...

$ vagrant box outdated --global
* 'generic/ubuntu2204' for 'libvirt' is outdated! Current: 4.3.12. Latest: 4.3.14
$ vagrant box update
$ vagrant box prune            # drop old versions no environment references
```

Boxes are retrieved from **Vagrant Cloud** (`app.vagrantup.com` / `vagrantcloud.com`, formerly *Atlas*). The short form `owner/box` resolves to that catalog; boxes are versioned, and `--box-version` / `config.vm.box_version` pin them. You can also point `config.vm.box_url` at a self-hosted `.box` or a private catalog for air-gapped shops.

---

## 6. Verification and failure diagnosis

The single most valuable tool is the debug log; every real diagnosis starts here:

```bash
$ VAGRANT_LOG=debug vagrant up 2>&1 | tee vagrant-debug.log
```

### 6.1 Diagnosis matrix

| Symptom (observed output) | Root cause | Remedy |
|---|---|---|
| `Call to virConnectOpen failed: authentication failed` / `Failed to connect socket to '/var/run/libvirt/libvirt-sock'` | user not in `libvirt` group / polkit denies | `sudo usermod -aG libvirt $USER` then `newgrp libvirt`; confirm `systemctl status libvirtd` |
| `The box ... doesn't support the provider you requested` | box has no image for that provider | choose a `generic/*` box, or `vagrant plugin install vagrant-mutate` |
| `Timed out while waiting for the machine to boot` (stuck at *Waiting for SSH*) | wrong/missing SSH key, no DHCP lease, no KVM accel (TCG too slow) | `virsh console <domain>` to watch boot; verify `/dev/kvm`; check management net lease |
| Hang at *Waiting for domain to get an IP address* | management network inactive or firewall drops DHCP | `virsh net-list --all`; `virsh net-start vagrant-libvirt`; allow `dnsmasq` |
| `mount.nfs: Connection timed out` / `exportfs: ... does not support NFS export` | host `nfs-kernel-server` missing or firewalled | install/start NFS, open ports; or switch to `type: "rsync"` |
| `Error while creating domain: ... Permission denied` on the image | qcow2 SELinux/AppArmor label or pool perms | check `storage_pool_name`; `restorecon` / AppArmor; verify pool dir ownership |
| `uncaught throw :port_check` / port already in use | `forwarded_port` collides on host | change host port or use `auto_correct: true` |
| KVM absent, VM crawls | virtualization disabled in firmware, or nested KVM off on host | enable VT-x/AMD-V in BIOS; `modprobe kvm_intel nested=1` |
| `default: Warning: Authentication failure. Retrying...` loops | stale insecure key vs rotated key | `vagrant destroy -f && vagrant up`, or remove stale key from guest |
| `global-status` lists a machine that no longer exists | stale metadata cache | `vagrant global-status --prune` |

### 6.2 Worked failure #1 — NFS synced-folder timeout

```bash
$ vagrant up
...
==> default: Exporting NFS shared folders...
==> default: Preparing to edit /etc/exports. Administrator privileges will be required...
==> default: Mounting NFS shared folders...
The following SSH command responded with a non-zero exit status.
mount -o vers=3,udp 192.168.121.1:/home/sre/demo /vagrant
Stdout: mount.nfs: Connection timed out
```

Diagnose from the host, then decide between fixing NFS or eliminating it:

```bash
$ systemctl is-active nfs-server
inactive
$ sudo systemctl enable --now nfs-server
$ exportfs -v                       # confirm the share was actually exported
/home/sre/demo  192.168.121.0/24(rw,sync,no_subtree_check,...)
# Firewall must allow the NFS/mountd/rpcbind ports on the libvirt subnet.
```

Preferred production fix — remove the daemon dependency entirely:

```ruby
config.vm.synced_folder ".", "/vagrant", type: "rsync"
# then:  vagrant reload
```

### 6.3 Worked failure #2 — SSH boot timeout with no accel

```bash
$ vagrant up
==> default: Waiting for SSH to become available...
Timed out while waiting for the machine to boot.
```

```bash
$ virsh -c qemu:///system list
 Id   Name           State
------------------------------
 5    demo_default   running
$ virsh -c qemu:///system domstats demo_default | grep -i cpu
  cpu.time=482300000000     # climbing painfully slowly → software emulation
$ virt-host-validate qemu | grep -i kvm
  QEMU: Checking if device /dev/kvm exists : FAIL (Check that CPU and firmware support virtualization and it is enabled in the BIOS)
```

Root cause: KVM unavailable, so QEMU ran under TCG and the guest never reached SSH in time. Fix at the firmware/module level, then pin `driver = "kvm"` so a silent fallback fails loudly instead. Watch the actual boot to confirm:

```bash
$ virsh -c qemu:///system console demo_default
Connected to domain 'demo_default'
Escape character is ^]
[  OK  ] Reached target Multi-User System.
web01 login:
```

### 6.4 Standard verification checklist after `up`

```bash
$ vagrant status                       # Vagrant's view
$ virsh -c qemu:///system list         # hypervisor's view (must agree)
$ vagrant ssh -c 'hostname -f; ip -brief addr; systemctl is-system-running'
$ vagrant ssh -c 'ls -la /srv/app'     # synced folder present + populated
$ vagrant provision                    # provisioners are idempotent (re-run is clean)
```

The principle: **never trust Vagrant's cached `status` alone** — reconcile it against `virsh` (or `VBoxManage list runningvms`). Divergence between the orchestrator's state and the hypervisor's state is the source of most "phantom" Vagrant bugs.

---

## Referencias

- Vagrant — Documentation (concepts, provisioning, multi-machine, networking): https://developer.hashicorp.com/vagrant/docs
- Vagrant — CLI command reference (`up`, `halt`, `destroy`, `suspend`, `resume`, `provision`, `reload`, `status`, `global-status`, `ssh`, `ssh-config`, `box`): https://developer.hashicorp.com/vagrant/docs/cli
- Vagrant — Boxes and box format: https://developer.hashicorp.com/vagrant/docs/boxes and https://developer.hashicorp.com/vagrant/docs/boxes/format
- Vagrant — Providers overview: https://developer.hashicorp.com/vagrant/docs/providers
- Vagrant — Provisioning (shell and file provisioners): https://developer.hashicorp.com/vagrant/docs/provisioning/shell and https://developer.hashicorp.com/vagrant/docs/provisioning/file
- Vagrant — Multi-Machine environments: https://developer.hashicorp.com/vagrant/docs/multi-machine
- Vagrant — Synced folders (NFS, rsync): https://developer.hashicorp.com/vagrant/docs/synced-folders
- Vagrant Cloud (box catalog, formerly Atlas): https://developer.hashicorp.com/vagrant/vagrant-cloud and https://app.vagrantup.com/boxes/search
- vagrant-libvirt provider (configuration, networking, storage, synced folders): https://vagrant-libvirt.github.io/vagrant-libvirt/ and https://github.com/vagrant-libvirt/vagrant-libvirt
- libvirt / QEMU / KVM reference: https://libvirt.org/docs.html
- LPI — Exam 305-300 Objectives (LPIC-3 Virtualization and Containerization, v3.0): https://www.lpi.org/our-certifications/exam-305-objectives/