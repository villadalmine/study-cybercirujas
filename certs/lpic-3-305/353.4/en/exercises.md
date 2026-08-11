# Topic 353.4: Vagrant — Guided Exercises

> **Exam context** — LPIC-3 305 (exam 305-300, v3.0), objective **353.4 "Vagrant"**, weight **5**.
> Objective coverage: Vagrant architecture (provider/provisioner), box management incl. the public registry, building environments from a `Vagrantfile`, environment configuration (networking, synced folders, provider-specific settings), and provisioning (file & shell).
> Primary sources: LPI objectives <https://www.lpi.org/our-certifications/exam-305-objectives/> · Vagrant docs <https://developer.hashicorp.com/vagrant/docs> · `vagrant-libvirt` <https://vagrant-libvirt.github.io/vagrant-libvirt/>

These labs are written for a Linux workstation using the **libvirt/KVM** provider (the provider most relevant to LPIC-3 305), with VirtualBox contrasts where the exam expects you to know the difference. Everything is runnable; the outputs shown are representative, not literal — versions and hashes will differ on your host.

---

## Prerequisites

You need a working KVM/libvirt stack and Vagrant. Run the checks below before starting; do not proceed if any command fails.

```bash
# 1. CPU virtualization extensions present and enabled in firmware
grep -Eoc '(vmx|svm)' /proc/cpuinfo        # any number > 0 is fine

# 2. KVM kernel modules loaded
lsmod | grep -E 'kvm_(intel|amd)'

# 3. libvirt daemon running and you are in the libvirt group
systemctl is-active libvirtd
id -nG | tr ' ' '\n' | grep -x libvirt

# 4. Vagrant and the libvirt plugin
vagrant --version
vagrant plugin list | grep vagrant-libvirt || vagrant plugin install vagrant-libvirt
```

Expected shape of the output:

```
2
kvm_intel             487424  0
active
libvirt
Vagrant 2.4.1
vagrant-libvirt (0.12.2, global)
```

**Comprehension**

1. `vagrant up` fails immediately with `Call to virConnectOpen failed: ... Permission denied`. Which two of the four checks above are the first you would re-examine, and why?
2. Why does the `vagrant-libvirt` plugin have to be installed *per Vagrant installation* rather than declared inside the `Vagrantfile`?

---

## Exercise 1 — Architecture: the four moving parts in one `up`

**Goal:** see how *box → provider → machine → provisioner* compose during a single lifecycle.

1. Create and enter a clean project directory:

   ```bash
   mkdir -p ~/vagrant-labs/e1 && cd ~/vagrant-labs/e1
   ```

2. Scaffold a minimal `Vagrantfile` bound to a specific box:

   ```bash
   vagrant init --minimal generic/debian12
   ```

   This writes a two-line `Vagrantfile`. Inspect it:

   ```bash
   cat Vagrantfile
   ```

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"
   end
   ```

3. Bring the machine up on libvirt explicitly:

   ```bash
   vagrant up --provider=libvirt
   ```

   Representative output (trimmed):

   ```
   Bringing machine 'default' up with 'libvirt' provider...
   ==> default: Box 'generic/debian12' could not be found. Attempting to find and install...
       default: Box Provider: libvirt
       default: Box Version: >= 0
   ==> default: Loading metadata for box 'generic/debian12'
       default: URL: https://vagrantcloud.com/api/v2/vagrant/generic/debian12
   ==> default: Adding box 'generic/debian12' (v4.3.12) for provider: libvirt
   ==> default: Creating image (snapshot of base box volume).
   ==> default: Creating domain with the following settings...
       default:  -- Name:              e1_default
       default:  -- Domain type:       kvm
       default:  -- Cpus:              1
       default:  -- Memory:            512M
   ==> default: Waiting for domain to get an IP address...
   ==> default: Machine booted and ready!
   ==> default: Rsyncing folder: /home/you/vagrant-labs/e1/ => /vagrant
   ```

4. Confirm the machine's state and the libvirt objects it created:

   ```bash
   vagrant status
   virsh --connect qemu:///system list
   virsh --connect qemu:///system vol-list default          # the storage pool
   ```

5. Open a shell inside the guest, look around, then leave:

   ```bash
   vagrant ssh -c 'hostname; id; ls -la /vagrant'
   ```

**Comprehension**

3. In step 3, three of the four architectural parts are visible in the log and one is absent. Name each part, quote the log line that proves it ran, and say which part did not appear and why.
4. `vagrant status` reports `running (libvirt)` while `virsh list` shows the domain as `running`. What does the parenthesized `(libvirt)` add that `virsh` cannot tell you, and where does Vagrant persist that fact?
5. You never typed a username, password, or IP, yet `vagrant ssh` connected. Trace how Vagrant knew *where* and *as whom* to connect.

---

## Exercise 2 — Provider-specific settings and portability

**Goal:** size a machine through provider blocks and understand why the same `Vagrantfile` can target two providers.

1. Replace the `Vagrantfile` in `~/vagrant-labs/e1` with:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     # Provider-agnostic hints (best-effort mapped by each provider)
     config.vm.provider "libvirt" do |lv|
       lv.memory = 2048
       lv.cpus   = 2
       lv.cpu_mode = "host-passthrough"
       lv.machine_virtual_size = 20   # GiB, grows the backing volume
     end

     # The same box, sized for VirtualBox — used only if you --provider=virtualbox
     config.vm.provider "virtualbox" do |vb|
       vb.memory = 2048
       vb.cpus   = 2
       vb.gui    = false
     end
   end
   ```

2. Validate the syntax *without* booting anything:

   ```bash
   vagrant validate
   ```

   ```
   Vagrant validated the configuration successfully.
   ```

3. Apply the new sizing to the already-running machine:

   ```bash
   vagrant reload
   ```

4. Confirm the guest now sees 2 vCPUs and ~2 GiB RAM:

   ```bash
   vagrant ssh -c 'nproc; free -m | awk "/Mem:/ {print \$2\" MiB\"}"'
   ```

5. Show that the provider choice can also be pinned by environment instead of a flag:

   ```bash
   VAGRANT_DEFAULT_PROVIDER=libvirt vagrant up          # no --provider needed
   ```

**Comprehension**

6. The box `generic/debian12` ships *separate images* for libvirt and VirtualBox under one name. What does this tell you about what a "box" actually is, and how does Vagrant pick the right image at `up` time?
7. `lv.cpu_mode = "host-passthrough"` improves guest performance but reduces one specific operational capability of the VM. Which one, and why does it matter for a fleet you intend to live-migrate?
8. You changed `lv.memory` but ran `vagrant reload` instead of `vagrant provision`. Why is `reload` the correct verb here, and what would `vagrant provision` have done instead?

---

## Exercise 3 — Box management and the public registry

**Goal:** manage the local box cache and understand versioned boxes from the registry (formerly "Vagrant Cloud").

1. List what is cached locally and where:

   ```bash
   vagrant box list
   ```

   ```
   generic/debian12 (libvirt, 4.3.12)
   ```

2. Add a second, pinned box version directly from the registry:

   ```bash
   vagrant box add almalinux/9 --provider libvirt --box-version 9.5.20241120
   ```

   ```
   ==> box: Loading metadata for box 'almalinux/9'
   ==> box: Adding box 'almalinux/9' (v9.5.20241120) for provider: libvirt
       box: Downloading: https://vagrantcloud.com/almalinux/boxes/9/versions/9.5.20241120/providers/libvirt/amd64/vagrant.box
   ==> box: Successfully added box 'almalinux/9' (v9.5.20241120) for 'libvirt'!
   ```

3. Check whether any cached box has a newer upstream release:

   ```bash
   vagrant box outdated --global
   ```

4. Inspect the on-disk box metadata that Vagrant keeps:

   ```bash
   ls ~/.vagrant.d/boxes/
   cat ~/.vagrant.d/boxes/almalinux-VAGRANTSLASH-9/metadata_url
   ```

5. Remove a specific version, then prune obsolete versions across all boxes:

   ```bash
   vagrant box remove almalinux/9 --provider libvirt --box-version 9.5.20241120
   vagrant box prune --dry-run
   ```

**Comprehension**

9. In `vagrant box list`, each entry carries a *provider* and a *version*. Why is the triple `(name, provider, version)` — not just the name — the real identity of a cached box?
10. A colleague writes `config.vm.box = "almalinux/9"` with no version constraint; you write `config.vm.box_version = "~> 9.5"`. Six months later your two `up` runs produce different guests. Explain the mechanism and name the config directive that makes the build reproducible.
11. What is the difference between `vagrant box remove` and `vagrant box prune`, and which one is safe to run on a shared CI host with many active projects?

---

## Exercise 4 — Networking: forwarded ports, private and public networks

**Goal:** expose a guest service three different ways and understand the reachability of each.

1. New project:

   ```bash
   mkdir -p ~/vagrant-labs/e4 && cd ~/vagrant-labs/e4
   ```

2. Write a `Vagrantfile` that runs a web server and wires all three network types:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"
     config.vm.hostname = "web01"

     # (a) Port forwarding: host:8080 -> guest:80
     config.vm.network "forwarded_port", guest: 80, host: 8080,
                       host_ip: "127.0.0.1", id: "http"

     # (b) Private (host-only) network with a static address
     config.vm.network "private_network", ip: "192.168.121.50"

     # (c) Public (bridged) network onto the LAN
     config.vm.network "public_network", dev: "virbr0", type: "bridge"

     config.vm.provision "shell", inline: <<-SHELL
       apt-get update -qq
       apt-get install -y -qq nginx
       echo "served by $(hostname) at $(date)" > /var/www/html/index.html
     SHELL
   end
   ```

3. Boot and read back the network wiring Vagrant applied:

   ```bash
   vagrant up
   vagrant port                 # show the actual forwarded-port table
   ```

   ```
   The forwarded ports for the machine are listed below. ...
        80 (guest) => 8080 (host)
        22 (guest) => 2222 (host)
   ```

4. Test each path from the **host**:

   ```bash
   curl -s http://127.0.0.1:8080/          # (a) via forwarded port
   curl -s http://192.168.121.50/          # (b) via private network
   ```

5. From inside the guest, confirm the interfaces exist and note their order:

   ```bash
   vagrant ssh -c 'ip -brief addr show'
   ```

   ```
   lo               UNKNOWN        127.0.0.1/8 ::1/128
   eth0             UP             192.168.121.10/24 ...    # management/NAT
   eth1             UP             192.168.121.50/24 ...    # private_network
   eth2             UP             192.168.1.87/24 ...      # public_network (DHCP from LAN)
   ```

**Comprehension**

12. `curl http://127.0.0.1:8080` works from the host but a laptop on the same office Wi‑Fi cannot reach it, whereas it *can* reach the address from step 4(b)-style bridging. Explain the reachability of each of the three network types from (i) the host, (ii) another guest on the same private network, (iii) a separate machine on the LAN.
13. In step 5 the *first* interface `eth0` is not any of the three you declared. What is it, why does every libvirt Vagrant box get it, and what breaks if you try to reconfigure or remove it?
14. Two projects both request `config.vm.network "forwarded_port", guest: 80, host: 8080`. You `vagrant up` the second while the first is running. What does Vagrant do by default, and which option controls that behavior?

---

## Exercise 5 — Synced folders and their transport types

**Goal:** compare the synced-folder mechanisms and see the default `/vagrant` mount.

1. In `~/vagrant-labs/e4`, add a data directory on the host:

   ```bash
   mkdir -p share && echo "host-authored" > share/note.txt
   ```

2. Extend the `Vagrantfile` (keep the networking block from Exercise 4) with three synced-folder declarations:

   ```ruby
     # Default project share is /vagrant — make its transport explicit
     config.vm.synced_folder ".", "/vagrant", type: "rsync",
                             rsync__exclude: [".git/", "*.box"]

     # A 9p (libvirt-native) live share, read-write
     config.vm.synced_folder "./share", "/srv/share", type: "9p",
                             accessmode: "squash"

     # An NFS share, read-only
     config.vm.synced_folder "./share", "/srv/share-ro", type: "nfs",
                             mount_options: ["ro"]
   ```

3. Reload to apply the mounts:

   ```bash
   vagrant reload
   ```

4. Inspect the mounts and prove directionality of each type:

   ```bash
   vagrant ssh -c 'mount | grep -E "/vagrant|/srv/share"'
   vagrant ssh -c 'cat /srv/share/note.txt'                 # host -> guest
   vagrant ssh -c 'echo guest-authored >> /srv/share/note.txt'
   cat share/note.txt                                        # guest -> host (9p is live, rw)
   ```

5. Trigger a manual re-sync for the rsync folder after editing a host file:

   ```bash
   echo "changed on host" >> share/note.txt
   vagrant rsync                                             # push rsync folders now
   ```

**Comprehension**

15. `/vagrant` exists in the guest even if you never declare it. What is mounted there by default, and give one concrete reason a provisioning script relies on it.
16. You wrote a change on the host *after* `vagrant up` and it did **not** appear in the guest under the `rsync` folder until you ran `vagrant rsync`, yet the same edit appeared instantly under the `9p` folder. Explain the fundamental difference between an rsync synced folder and a 9p/NFS synced folder.
17. The NFS share required `sudo` privileges on the **host** the first time you brought the machine up (an `/etc/exports` edit). Why does NFS, but not 9p, need host-side root, and what is the security trade-off of `accessmode: "squash"`?

---

## Exercise 6 — Provisioning: shell (inline + script) and file provisioners

**Goal:** distinguish the two provisioners the objective names, and control *when* they run.

1. New project with a helper script and a config file to ship:

   ```bash
   mkdir -p ~/vagrant-labs/e6 && cd ~/vagrant-labs/e6
   vagrant init --minimal generic/debian12

   cat > bootstrap.sh <<'EOF'
   #!/usr/bin/env bash
   set -euo pipefail
   apt-get update -qq
   apt-get install -y -qq redis-server
   cp /tmp/redis-overlay.conf /etc/redis/redis.conf.d/overlay.conf 2>/dev/null || true
   systemctl restart redis-server
   redis-cli ping
   EOF

   cat > redis-overlay.conf <<'EOF'
   maxmemory 128mb
   maxmemory-policy allkeys-lru
   EOF
   ```

2. Wire three provisioners with explicit ordering and run policy:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     # (1) file provisioner: copy config into the guest first
     config.vm.provision "ship-conf", type: "file",
                         source: "redis-overlay.conf",
                         destination: "/tmp/redis-overlay.conf"

     # (2) shell provisioner from a script: install & configure
     config.vm.provision "install", type: "shell", path: "bootstrap.sh"

     # (3) inline shell that runs on EVERY up/reload, not just the first
     config.vm.provision "healthcheck", type: "shell",
                         run: "always",
                         inline: "systemctl is-active redis-server"
   end
   ```

3. First boot runs all provisioners in declared order:

   ```bash
   vagrant up
   ```

   ```
   ==> default: Running provisioner: ship-conf (file)...
   ==> default: Running provisioner: install (shell)...
       default: PONG
   ==> default: Running provisioner: healthcheck (shell)...
       default: active
   ```

4. Reboot and observe which provisioners re-run:

   ```bash
   vagrant reload
   ```

5. Force *all* provisioners to run again on an already-provisioned machine:

   ```bash
   vagrant provision
   # or, during a reload:  vagrant reload --provision
   ```

**Comprehension**

18. On the plain `vagrant reload` in step 4, exactly one of the three provisioners re-ran. Which one, and state the general rule Vagrant uses to decide whether a provisioner runs.
19. Why is the file provisioner declared *before* the shell script even possible to reorder incorrectly — i.e., what would happen at first `up` if `install` were listed before `ship-conf`?
20. The file provisioner copies as the *unprivileged* `vagrant` user, so it cannot write to `/etc` directly — that is why the example stages into `/tmp` and the shell script does the `cp`. Contrast this with how the **shell** provisioner runs by default regarding privileges, and name the option that changes it.
21. You need a secret pulled from the host at provision time but must never bake it into the box. Which provisioner-plus-folder combination gives you host-side data inside the guest without persisting it in the image, and why does `run: "always"` matter for a rotating secret?

---

## Exercise 7 — Multi-machine environments

**Goal:** define more than one VM in a single `Vagrantfile` and target commands at named machines.

1. New project:

   ```bash
   mkdir -p ~/vagrant-labs/e7 && cd ~/vagrant-labs/e7
   ```

2. Define a two-node environment (a web node and a db node) on a shared private network:

   ```ruby
   Vagrant.configure("2") do |config|
     config.vm.box = "generic/debian12"

     config.vm.define "db" do |db|
       db.vm.hostname = "db01"
       db.vm.network "private_network", ip: "192.168.121.20"
       db.vm.provider "libvirt" { |lv| lv.memory = 1024 }
     end

     config.vm.define "web", primary: true do |web|
       web.vm.hostname = "web01"
       web.vm.network "private_network", ip: "192.168.121.10"
       web.vm.provision "shell", inline: "apt-get install -y -qq curl"
     end
   end
   ```

3. Bring up only the database node first, then the whole environment:

   ```bash
   vagrant up db
   vagrant status
   vagrant up                    # brings up the remaining 'web'
   ```

   ```
   Current machine states:

   db                        running (libvirt)
   web                       running (libvirt)
   ```

4. Target commands at one machine by name:

   ```bash
   vagrant ssh web -c 'ping -c1 192.168.121.20'    # web -> db over private net
   vagrant halt db
   ```

5. See every Vagrant environment on the host, across all project directories:

   ```bash
   vagrant global-status --prune
   ```

   ```
   id       name    provider state   directory
   -------------------------------------------------------------------
   9f3a1c2  db      libvirt  poweroff /home/you/vagrant-labs/e7
   1b7d5e0  web     libvirt  running  /home/you/vagrant-labs/e7
   ```

**Comprehension**

22. `vagrant ssh` with no machine name in this project connects to `web`, not `db`. Which directive causes that, and what happens to bare commands like `vagrant ssh` if you remove it?
23. Explain the difference between `vagrant status` and `vagrant global-status`, and why the latter needs `--prune`.
24. You want `web` to reach `db` by hostname, not IP. Given the environment above, what is the minimal, provisioner-based way to achieve that without external DNS, and why is ordering (`vagrant up db` before `web`) *not* enough on its own?

---

## Exercise 8 — Lifecycle, introspection and teardown

**Goal:** consolidate the state-machine verbs and the diagnostic commands.

1. Return to `~/vagrant-labs/e7` and walk the full state machine on `web`:

   ```bash
   vagrant up web
   vagrant suspend web && vagrant status web       # -> saved
   vagrant resume  web && vagrant status web       # -> running
   vagrant halt    web && vagrant status web       # -> poweroff
   ```

2. Emit an OpenSSH-compatible config block for direct `ssh` access:

   ```bash
   vagrant up web
   vagrant ssh-config web
   ```

   ```
   Host web
     HostName 192.168.121.10
     User vagrant
     Port 22
     IdentityFile /home/you/vagrant-labs/e7/.vagrant/machines/web/libvirt/private_key
     IdentitiesOnly yes
     StrictHostKeyChecking no
   ```

3. Use that block to connect without Vagrant in the loop:

   ```bash
   vagrant ssh-config web > /tmp/web.ssh
   ssh -F /tmp/web.ssh web hostname
   ```

4. Take and restore a snapshot (libvirt/VirtualBox both support this):

   ```bash
   vagrant snapshot save web clean
   vagrant ssh web -c 'sudo rm -rf /etc/nginx'      # break something
   vagrant snapshot restore web clean
   ```

5. Tear the whole environment down and confirm nothing is left behind:

   ```bash
   vagrant destroy -f
   vagrant global-status --prune
   virsh --connect qemu:///system list --all | grep e7_ || echo "no residual domains"
   ```

**Comprehension**

25. Distinguish `vagrant halt`, `vagrant suspend`, and `vagrant destroy` in terms of what happens to (i) guest RAM, (ii) the disk image, and (iii) how long the next `up` takes.
26. `vagrant ssh-config` embeds `StrictHostKeyChecking no` and a per-machine `private_key`. Why are both appropriate for ephemeral dev VMs but a red flag if copied into a production `~/.ssh/config`?
27. After `vagrant destroy`, `vagrant box list` still shows `generic/debian12`. Is that a bug? Explain the relationship between a *destroyed machine* and its *box*, and which command actually reclaims the box's disk space.

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

**Prerequisites**

1. Checks **3** and **4-adjacent**: `Permission denied` on `virConnectOpen` is an authorization problem, not a missing feature. Re-examine (3) — specifically your **group membership**: you must be in the `libvirt` group *and* have re-logged in so the group is active in your current session (`id -nG`); and confirm `libvirtd`/`virtqemud` is actually active. CPU/KVM-module checks (1–2) would produce a different error (domain creation failing with "KVM not available"), not an auth failure at connection time.
2. The plugin is a Ruby extension that hooks into Vagrant's *provider* API inside the Vagrant runtime itself; it must be present before any `Vagrantfile` is even evaluated, and it applies to every project run by that Vagrant install. The `Vagrantfile` can *require* a plugin (`config.vagrant.plugins`) but cannot *supply* one — installation is an act on the host, not a property of a single environment.

**Exercise 1**

3. **Box** — `Adding box 'generic/debian12' (v4.3.12) for provider: libvirt`; **Provider** — `Creating domain with the following settings... Domain type: kvm`; **Machine** — `Machine booted and ready!`. The **provisioner** did not appear in the log because this minimal `Vagrantfile` declares none (the only sync-like line is the automatic `/vagrant` folder, which is a synced folder, not a provisioner).
4. `(libvirt)` names the **provider** that owns the machine — Vagrant's state combines "the domain is running" with "and it is managed by the libvirt provider in this project." `virsh` only knows about the libvirt domain; it has no concept of the Vagrant project or provider abstraction. Vagrant persists this in the project's `.vagrant/machines/default/libvirt/` directory (id file, provider marker, private key).
5. On first `up`, libvirt reports the domain's DHCP-assigned IP; Vagrant injects a generated key pair (the box's `insecure` key is replaced on first boot) and records the private key under `.vagrant/machines/default/libvirt/private_key`. The default box user is `vagrant`. `vagrant ssh` reads the stored IP + key + user (the same data `vagrant ssh-config` prints) and calls `ssh` for you.

**Exercise 2**

6. A "box" is a **provider-specific packaged image plus metadata**, not a single file. `generic/debian12` is a box *name* whose registry metadata lists multiple providers, each with its own image (a qcow2 for libvirt, a VMDK/OVF for VirtualBox). At `up` time Vagrant resolves `name → version → provider` and downloads only the image matching the active provider; that is why `vagrant box list` keys on `(name, provider, version)`.
7. It loses **CPU model portability / live-migratability**. `host-passthrough` exposes the exact host CPU to the guest, so the guest can be migrated only to a destination with an identical (or superset) CPU. For a fleet you intend to live-migrate you would instead pin a named baseline model (`custom`/named `cpu_mode` with an explicit model) so every host presents the same virtual CPU.
8. Memory/CPU sizing is *domain definition*, applied when the VM is (re)created and booted — `reload` halts and re-`up`s the machine, re-reading the `Vagrantfile` and redefining the domain with the new size. `vagrant provision` only re-runs provisioners against the *already-running* machine; it never redefines hardware, so the new memory would not take effect.

**Exercise 3**

9. Two boxes can share a name but differ by provider (libvirt vs virtualbox image) and by version (weekly rebuilds). A `Vagrantfile` asking for `generic/debian12` under the libvirt provider must resolve to a specific image; only the triple uniquely identifies the cached artifact, so Vagrant stores and lists boxes by all three.
10. With no constraint, each `up` on a machine that has no box yet resolves to the *latest* registry version; the two of you added the box at different times, so you cached different versions. `~> 9.5` is a pessimistic constraint that still floats within the 9.5.x line. The directive that pins an exact, reproducible build is **`config.vm.box_version = "9.5.20241120"`** (an exact version), optionally combined with a checksum via `config.vm.box_download_checksum`.
11. `vagrant box remove` deletes one explicitly named `(name, version, provider)` from the cache. `vagrant box prune` deletes *all* box versions that are older than the newest cached one **and not currently in use** by any known environment. On a shared CI host, `prune` (ideally `--dry-run` first) is the safe one because it will not delete a version an active project still references; a blanket `remove` of a version could break a running build.

**Exercise 4**

12. (a) **forwarded_port** — a host-side listener (here bound to `127.0.0.1:8080`) that DNATs into the guest; reachable only from the host (and only via loopback since you set `host_ip: 127.0.0.1`), invisible to other guests and to the LAN. (b) **private_network** — a host-only/NAT libvirt network (`virbr*`); reachable from the host and from other guests on the *same* private network, but not from the wider LAN. (c) **public_network** — bridged onto a physical/`virbr0` LAN segment; the guest gets a LAN-routable address and is reachable from any machine on the LAN (subject to LAN firewalling), just like a physical host.
13. `eth0` is the **management interface** — the NAT network libvirt creates so Vagrant can reach the guest for SSH, synced folders and provisioning before any user-declared network exists. Every libvirt box gets it because Vagrant needs an out-of-band control path. Removing or renumbering it severs Vagrant's control channel: `ssh`, `rsync`, `provision`, and status all break. User networks are always *added* as `eth1`, `eth2`, …
14. By default Vagrant detects the host-port collision and **auto-corrects** it, remapping the second machine's host port to a free one (e.g. 8081) and printing a "Fixed port collision" message. The behavior is controlled by `auto_correct: true/false` on the `forwarded_port` entry; with `auto_correct: false` the second `up` fails instead of remapping.

**Exercise 5**

15. The **project directory is synced to `/vagrant`** by default (the folder containing the `Vagrantfile`). Provisioning scripts rely on it to reach files that live beside the `Vagrantfile` — e.g. a shell provisioner can `bash /vagrant/setup.sh` or read assets from `/vagrant/...` without a separate copy step.
16. An **rsync** synced folder is a **one-time, one-directional push** (host → guest) performed at `up`/`reload`/`vagrant rsync` (or continuously only if you run `vagrant rsync-auto`); the guest gets a plain local copy, so later host edits are invisible until the next sync. **9p** and **NFS** are **live network file systems**: the guest mounts the host directory, so reads and writes pass through in real time in both directions (subject to the mount's rw/ro flag).
17. NFS is served by the **host kernel's NFS daemon**, so Vagrant must edit `/etc/exports` and (re)start the export — a privileged host operation. 9p is served by **QEMU in userspace** as part of the VM's own device model, needing no host export table, hence no host root. `accessmode: "squash"` maps all guest file access to the invoking host user (like NFS `root_squash`): it prevents the guest from writing files owned by arbitrary host UIDs, but it also means every guest write lands as your host user, erasing in-guest ownership distinctions — convenient, but not a real multi-user permission boundary.

**Exercise 6**

18. The **`healthcheck`** provisioner re-ran, because it is declared `run: "always"`. General rule: a provisioner runs on the **first successful `up`/creation**, and thereafter only when you explicitly ask (`vagrant provision`, `vagrant up --provision`, `vagrant reload --provision`) — *unless* it is marked `run: "always"`, which runs it on every `up`/`reload` regardless.
19. On first `up` all provisioners run once in declared order. If `install` ran before `ship-conf`, the script's `cp /tmp/redis-overlay.conf ...` would find no file (it has not been shipped yet). The example guards it with `|| true`, so the copy would silently no-op and Redis would come up **without** the overlay config — a subtle "provisioned but misconfigured" result, not a hard failure. Declared order is the contract; the file provisioner must come first.
20. The **shell provisioner runs as root by default** (it is executed with elevated privileges in the guest), which is why `bootstrap.sh` can `apt-get install` and write `/etc`. To run it unprivileged you set `privileged: false` on the shell provisioner (it then runs as the `vagrant` user). The file provisioner is the opposite — always the SSH (`vagrant`) user, no privilege option — hence the stage-to-`/tmp`-then-`cp` idiom.
21. Put the secret in a host directory and expose it with a **live synced folder** (9p/NFS) or ship it with the **file provisioner**, then have a **`run: "always"` shell provisioner** read/apply it. Because the data lives on the host and is only mounted/copied at run time, it is never captured in the box image or a snapshot. `run: "always"` matters because a rotated secret changes between boots; a once-only provisioner would apply the stale value from first `up` and never pick up the new one.

**Exercise 7**

22. `config.vm.define "web", primary: true` marks `web` as the **primary machine**, so machine-less commands (`vagrant ssh`, `vagrant provision`) default to it. Remove `primary: true` and a bare `vagrant ssh` in a multi-machine environment errors out, demanding you name a machine, because there is no default target.
23. `vagrant status` reports only the machines defined by the **current project's** `Vagrantfile`. `vagrant global-status` lists **every** Vagrant environment known on the host, across all directories, from a global index. That index can drift when a project directory is deleted without `vagrant destroy`; `--prune` removes those stale/invalid entries so the listing reflects reality.
24. Add a **shell provisioner** (or a file provisioner writing `/etc/hosts`) on `web` that appends `192.168.121.20  db01`. Ordering alone is insufficient because bringing `db` up first only guarantees it *exists and has an IP*; it does nothing to teach `web`'s resolver that `db01` maps to `192.168.121.20`. Without host-side DNS you must inject the mapping into the guest (`/etc/hosts`) via provisioning.

**Exercise 8**

25. **`halt`** — graceful guest shutdown: RAM is discarded, disk image is preserved, next `up` is a **cold boot** (slowest, full OS start). **`suspend`** — the running machine's RAM state is written to disk (libvirt `managedsave`): disk preserved, next `up`/`resume` restores instantly to exactly where you left off (fast). **`destroy`** — the domain and its per-machine disk overlay are deleted: RAM gone, disk gone; next `up` re-creates the machine from the box and re-runs provisioners (slowest overall, a fresh build).
26. For ephemeral dev VMs the host key is regenerated on every rebuild and the machine is throwaway, so `StrictHostKeyChecking no` and a project-scoped `IdentityFile` just avoid known-hosts churn and keep the key next to the project. In production, disabling host-key checking removes your only defense against a man-in-the-middle/impersonated host, and a shared/loose private key with `IdentitiesOnly` pointing at a repo-adjacent file invites key leakage — both are exactly the controls you want *tight* on real infrastructure.
27. Not a bug. **Destroying a machine** deletes that VM instance (its domain and disk overlay); the **box** is the reusable base image cached under `~/.vagrant.d/boxes/`, shared by every project that references it, and is intentionally left in place so the next `up` need not re-download it. To actually reclaim the box's disk space you run **`vagrant box remove generic/debian12 --provider libvirt`** (or `vagrant box prune`).

</details>