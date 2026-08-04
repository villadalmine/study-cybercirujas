# 5.1 Minimize host OS footprint (reduce attack surface)

> **CKS v1.34 — Domain: System Hardening — Weight 2.5**
> Prerequisite reading: node components (kubelet, container runtime, kube-proxy), Linux namespaces/cgroups, systemd unit model.
> Adjacent topics: 5.2 (minimize IAM roles), 5.3 (minimize external network access), 5.4 (AppArmor/seccomp), 6.x (runtime detection).

---

## 1. The architectural problem

### 1.1 The node is the last isolation boundary, and it is a shared one

A Kubernetes worker node is not "a server that happens to run containers". It is a **multi-tenant kernel** where every workload scheduled onto it shares one `struct task_struct` tree, one page cache, one network stack, one set of syscall entry points, and one set of loaded kernel modules. Namespaces and cgroups partition *views* of that kernel; they do not partition the kernel itself.

That has one consequence that drives this entire topic: **anything reachable from inside a container that lives outside the container's namespaces is host attack surface**, and anything an attacker can reach after a container escape is *node* attack surface. Reducing the host OS footprint is not distro hygiene — it is the difference between "one compromised pod" and "one compromised cluster".

### 1.2 What an attacker actually gets from a node

Enumerate the blast radius precisely, because it justifies the cost of the work:

| Asset present on a stock worker node | Path | What it unlocks |
|---|---|---|
| Kubelet client cert | `/var/lib/kubelet/pki/kubelet-client-current.pem` | Identity `system:node:<name>` in group `system:nodes`. With `NodeRestriction` + Node authorizer: read **every Secret, ConfigMap, PVC and SA token referenced by pods scheduled to that node**. |
| Kubelet bootstrap/kubeconfig | `/etc/kubernetes/kubelet.conf`, `/etc/kubernetes/bootstrap-kubelet.conf` | Same, plus CSR self-issuance if bootstrap token is still valid. |
| Projected SA tokens of *every* pod on the node | `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~projected/.../token` | The union of RBAC of all co-tenant workloads. This is usually the fattest prize on the box. |
| Container runtime socket | `/run/containerd/containerd.sock` | Start a privileged container with `/` bind-mounted → full root, bypassing all admission control. |
| Cloud instance credentials | `169.254.169.254` (IMDS) | IAM role of the node group: often `ec2:*` read, ECR pull, sometimes S3 or Secrets Manager. |
| Static pod directory (control plane) | `/etc/kubernetes/manifests/` | Write access = arbitrary privileged pod executed by kubelet, no API server involved, no audit event for creation. |
| etcd data (control plane) | `/var/lib/etcd` | The entire cluster, in cleartext unless encryption-at-rest is configured. |

### 1.3 Why "just patch it" is the wrong model

A stock general-purpose server image is optimised for *someone else's* problem: interactive administration, arbitrary workloads, broad hardware support, backwards compatibility. On a Kubernetes node, essentially none of that is needed, yet you inherit the whole liability:

- **Package surface.** Every installed package is a CVE feed you have subscribed to and an upgrade you must schedule. A stock Ubuntu Server cloud image is ~600 packages; a node needs perhaps 150 of them.
- **Privilege-escalation primitives.** `pkexec` (CVE-2021-4034, instant root from any local shell), `polkit`, `snapd` (CVE-2019-7304 "dirty_sock"), `at`, `chsh`. None are needed to run containers, all are SUID-root or root-daemon reachable *after* an escape — and an escape that lands you as UID 0 in a user namespace still needs a local privesc to become real root on some configurations.
- **Kernel surface.** A generic kernel autoloads modules on demand. `CONFIG_*` for DCCP, SCTP, TIPC, RDS, AX.25, and a dozen legacy filesystems ship enabled; a single `socket(AF_TIPC, ...)` from an unprivileged container autoloads code that has never been reviewed for hostile input (CVE-2021-43267, TIPC, remote root; CVE-2022-0435, TIPC again; CVE-2021-3715, `sch_route`).
- **Time-to-patch.** Mutable nodes drift. Node #47 was built in March, patched in May, and has a manually-installed debugging package nobody remembers. Configuration management converges *some* of the state; the host image converges *all* of it.

The production answer is therefore not a longer patch cycle but **a smaller, immutable, rebuildable node**:

```
mutable node model:      build once → drift → patch → drift → patch → forensic mystery
immutable node model:    build image (signed, versioned) → boot → drain → replace → repeat
```

The security value of immutability is not that the disk is read-only. It is that **persistence becomes hard** (there is nowhere to write a rootkit that survives), **drift becomes impossible** (node #47 is byte-identical to node #1), and **patching becomes a deploy** (the same tested, reviewable pipeline you already use for applications).

### 1.4 The four surfaces, and the order to attack them

| Surface | Question | Primary control | Payoff |
|---|---|---|---|
| **Network-reachable** | What accepts bytes from off-box? | Port inventory + host firewall + bind-address | Highest — remote pre-auth |
| **Local privesc** | What turns "shell as nobody after escape" into root? | SUID/SGID purge, sudo policy, no interactive users | High — this is what converts an escape into node ownership |
| **Kernel API** | What kernel code can an unprivileged container reach? | Module blacklist, `sysctl`, lockdown, seccomp default | High — container escapes are almost always kernel bugs |
| **Persistence/supply chain** | What survives a reboot, and who put it there? | Immutable rootfs, dm-verity, Secure Boot, signed images | Medium now, decisive during incident response |

Work top-down. Do not start with `sysctl` tuning while `sshd` accepts passwords from the internet.

---

## 2. Baseline: measure before you cut

You cannot minimize what you have not inventoried. Run this on a representative node **before** any change and store the output as an artifact — it is your diff base and your evidence for the auditor.

```bash
$ cat /etc/os-release | head -2
PRETTY_NAME="Ubuntu 24.04.3 LTS"
NAME="Ubuntu"

$ uname -r
6.8.0-79-generic

$ dpkg-query -f '${binary:Package}\n' -W | wc -l
612

$ systemctl list-units --type=service --state=running --no-legend --no-pager | wc -l
27

$ systemctl list-units --type=service --state=running --no-legend --no-pager
  containerd.service       loaded active running containerd container runtime
  cron.service             loaded active running Regular background program processing daemon
  dbus.service             loaded active running D-Bus System Message Bus
  getty@tty1.service       loaded active running Getty on tty1
  irqbalance.service       loaded active running irqbalance daemon
  kubelet.service          loaded active running kubelet: The Kubernetes Node Agent
  ModemManager.service     loaded active running Modem Manager
  multipathd.service       loaded active running Device-Mapper Multipath Device Controller
  networkd-dispatcher.se.. loaded active running Dispatcher daemon for systemd-networkd
  polkit.service           loaded active running Authorization Manager
  rsyslog.service          loaded active running System Logging Service
  snapd.service            loaded active running Snap Daemon
  ssh.service              loaded active running OpenBSD Secure Shell server
  systemd-journald.service loaded active running Journal Service
  systemd-logind.service   loaded active running User Login Management
  systemd-networkd.service loaded active running Network Configuration
  systemd-resolved.service loaded active running Network Name Resolution
  systemd-timesyncd.serv.. loaded active running Network Time Synchronization
  systemd-udevd.service    loaded active running Rule-based Manager for Device Events and Files
  udisks2.service          loaded active running Disk Manager
  unattended-upgrades.ser. loaded active running Unattended Upgrades Shutdown
  ...
```

`ModemManager`, `udisks2`, `multipathd` (if no FC/iSCSI multipath), `snapd`, `polkit` on a headless Kubernetes node in 2026 are pure liability.

**Listening sockets** — the only inventory that matters for remote surface:

```bash
$ ss -tulpnH | column -t
udp  UNCONN  0  0  127.0.0.54:53      0.0.0.0:*  users:(("systemd-resolve",pid=712,fd=17))
udp  UNCONN  0  0  127.0.0.53%lo:53   0.0.0.0:*  users:(("systemd-resolve",pid=712,fd=15))
udp  UNCONN  0  0  0.0.0.0:8472       0.0.0.0:*
tcp  LISTEN  0  4096  127.0.0.1:10248 0.0.0.0:*  users:(("kubelet",pid=1544,fd=25))
tcp  LISTEN  0  4096  127.0.0.1:10249 0.0.0.0:*  users:(("kube-proxy",pid=2210,fd=14))
tcp  LISTEN  0  4096  0.0.0.0:10250   0.0.0.0:*  users:(("kubelet",pid=1544,fd=27))
tcp  LISTEN  0  4096  0.0.0.0:10255   0.0.0.0:*  users:(("kubelet",pid=1544,fd=26))
tcp  LISTEN  0  4096  0.0.0.0:10256   0.0.0.0:*  users:(("kube-proxy",pid=2210,fd=16))
tcp  LISTEN  0  128   0.0.0.0:22      0.0.0.0:*  users:(("sshd",pid=1102,fd=3))
tcp  LISTEN  0  4096  127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=712,fd=16))
```

`0.0.0.0:10255` is the kubelet **read-only port**: unauthenticated, and `GET /pods` on it returns every pod spec on the node, including env vars and the names of every mounted Secret. That single line is the most common real finding in a first-time CKS-style node audit.

**SUID/SGID inventory:**

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
    -printf '%04m %u:%g %p\n' 2>/dev/null | sort
2755 root:shadow /usr/bin/chage
2755 root:crontab /usr/bin/crontab
2755 root:shadow /usr/bin/expiry
4755 root:root /usr/bin/chfn
4755 root:root /usr/bin/chsh
4755 root:root /usr/bin/fusermount3
4755 root:root /usr/bin/gpasswd
4755 root:root /usr/bin/mount
4755 root:root /usr/bin/newgrp
4755 root:root /usr/bin/passwd
4755 root:root /usr/bin/su
4755 root:root /usr/bin/umount
4755 root:root /usr/lib/openssh/ssh-keysign
4755 root:root /usr/lib/polkit-1/polkit-agent-helper-1
4755 root:root /usr/bin/pkexec
4755 root:root /usr/bin/sudo
2755 root:tty /usr/bin/wall
2755 root:tty /usr/bin/write
...
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l
26
```

**Loaded modules and autoload capability:**

```bash
$ lsmod | wc -l
119

$ cat /proc/sys/kernel/modules_disabled
0

$ cat /sys/kernel/security/lockdown
[none] integrity confidentiality
```

**systemd exposure scoring** — a fast, ranked "what should I sandbox or delete" list:

```bash
$ systemd-analyze security --no-pager | head -20
UNIT                                  EXPOSURE PREDICATE HAPPY
containerd.service                         9.6 UNSAFE    😨
kubelet.service                            9.6 UNSAFE    😨
snapd.service                              9.5 UNSAFE    😨
ssh.service                                9.6 UNSAFE    😨
udisks2.service                            9.4 UNSAFE    😨
ModemManager.service                       8.3 EXPOSED   🙁
polkit.service                             8.2 EXPOSED   🙁
rsyslog.service                            8.0 EXPOSED   🙁
irqbalance.service                         6.6 MEDIUM    😐
systemd-journald.service                   4.9 OK        🙂
systemd-udevd.service                      3.9 OK        🙂
systemd-resolved.service                   2.2 OK        🙂
```

Read this correctly: `kubelet` and `containerd` score 9.6 **and that is unavoidable** — they must mount filesystems, enter namespaces, write cgroups and manage devices. You do not fix them with `ProtectSystem=strict`; you fix them by *not adding a 27th service next to them*. The score is actionable for the accessory daemons, not for the runtime.

### 2.1 Reference footprint comparison

Numbers below are one reference build each (node images built 2026-07, x86-64, kubelet 1.34, containerd 2.x), measured with the commands above. Treat them as orders of magnitude, not constants.

| Node image | Packages / installed units | Running services | Listening `0.0.0.0` ports | SUID/SGID files | Root FS writable | Package manager on box |
|---|---|---|---|---|---|---|
| Ubuntu 24.04 Server (stock cloud image) | ~612 | 27 | 22, 10250, 10255, 10256, 8472 | 26 | yes | apt + snap |
| Ubuntu 24.04 minimized (this document) | ~430 | 12 | 10250, 10256, 8472 | 6 | yes | apt (offline) |
| Flatcar Container Linux | n/a (image-based) | 11 | 22, 10250, 10256 | 5 | `/usr` read-only, `/etc` writable | none |
| Bottlerocket | n/a (image-based) | 9 | 10250 | 0 (no general userland) | dm-verity, RO | none |
| Talos Linux | n/a (single squashfs) | n/a (no systemd, no shell) | 50000/tcp (apid), 10250 | 0 | RO, no `/bin/sh` | none |

The step from column 2 to column 3 is a *migration*; the step from column 1 to column 2 is a *weekend*. Both are worth doing; do the second one first.

---

## 3. Choosing the host OS: trade-offs

| Criterion | General-purpose (Ubuntu/RHEL/Debian) | Flatcar Container Linux | Bottlerocket | Talos Linux | RHCOS (OpenShift) |
|---|---|---|---|---|---|
| Update model | package-by-package, in place | A/B partition, atomic, auto-reboot via `locksmithd`/Kured | A/B partition, atomic, `apiclient update` | A/B image, atomic, `talosctl upgrade` | rpm-ostree, atomic |
| Root filesystem | read-write | `/usr` read-only, `/etc` writable | dm-verity protected, read-only | read-only squashfs | read-only, ostree |
| Shell on node | full | full (`core` user, SSH) | **none by default**; `admin` host-container only if enabled | **none, ever** — no `/bin/sh`, no SSH | full (`core`, SSH) |
| Package manager | yes (huge liability) | no | no | no | rpm-ostree only |
| Config interface | anything (Ansible, cloud-init, manual) | Ignition (boot-time only) | TOML API (`apiclient set`) | machine config YAML via gRPC API | Ignition + MachineConfig operator |
| Kernel module control | full, manual | full, via Ignition | curated set | curated + declarative extensions | full |
| Debuggability | trivial | easy | `enter-admin-container` | `talosctl` subcommands only (`logs`, `dmesg`, `read`) | easy |
| SUID binaries | ~26 | ~5 | none applicable | none | ~20 |
| Blast radius of an escape | root on a full Linux box | root on a box with no compiler, RO `/usr` | root inside a container; host has no tools | attacker has no shell to run | root on a full box |
| Ecosystem friction | none | low | AWS/EKS-centric (also bare metal via `bottlerocket-bootstrap`) | high: no node-agent DaemonSets that expect `nsenter`+shell | OpenShift only |
| Fit | brownfield, on-prem heterogeneity | good general-purpose immutable | AWS-first fleets | greenfield, highest assurance | you already bought OpenShift |

**Architectural guidance.** If you can choose, choose an image-based OS; the security win is structural rather than configuration-dependent. If you cannot — regulated environments with mandated agents (EDR, vulnerability scanners, backup) frequently rule out Talos and Bottlerocket, because those agents assume a shell and a package manager — then commit to the minimization program in §4–§11 *and* enforce it by building the node image in CI (Packer / `kubernetes-sigs/image-builder`) rather than converging it with configuration management at runtime.

The single most under-appreciated cost line: **Talos and Bottlerocket break every DaemonSet that shells into the host**. Audit your `hostPID: true` + `nsenter` DaemonSets before committing.

---

## 4. Remove services: `disable` vs `mask` vs `purge`

### 4.1 The three levels

| Action | Command | Effect | Can it come back? |
|---|---|---|---|
| Stop | `systemctl stop X` | Running instance killed | Yes — on reboot, on socket activation, on `Wants=` from any other unit |
| Disable | `systemctl disable --now X` | Removes `[Install]` symlinks | **Yes** — a dependency (`Wants=`/`Requires=`) from another unit still pulls it in, and D-Bus/socket activation still starts it |
| Mask | `systemctl mask --now X` | Symlinks the unit to `/dev/null` | No — start attempts fail hard, including dependency pulls |
| Purge | `apt-get purge X` / not in the image | The code is not on disk | No |

**Prefer `purge` at image-build time, `mask` at runtime.** `disable` alone is the classic incomplete fix: `ModemManager` and `udisks2` are D-Bus-activated and will restart themselves; `snapd` is socket-activated via `snapd.socket`.

```bash
# WRONG — snapd comes back on the next snap-related D-Bus/socket event
$ sudo systemctl disable --now snapd.service
Removed "/etc/systemd/system/multi-user.target.wants/snapd.service".
$ sudo systemctl is-active snapd.socket
active

# RIGHT
$ sudo systemctl mask --now snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service
Created symlink /etc/systemd/system/snapd.service → /dev/null.
Created symlink /etc/systemd/system/snapd.socket → /dev/null.
Created symlink /etc/systemd/system/snapd.seeded.service → /dev/null.
Created symlink /etc/systemd/system/snapd.apparmor.service → /dev/null.
```

### 4.2 What to remove on a Kubernetes node

| Unit / package | Why it exists | Safe to remove on a node? | Caveat |
|---|---|---|---|
| `ModemManager` | Cellular modems | **Yes** | — |
| `udisks2` | Desktop removable-media automount | **Yes** | — |
| `snapd` (+ `snapd.socket`) | Ubuntu snaps | **Yes**, unless a cloud agent is a snap | `amazon-ssm-agent`, `google-guest-agent` ship as snaps on some Ubuntu cloud images — check first |
| `polkit` + `pkexec` | Desktop privilege brokering | **Yes** | Removes a proven local-root primitive (CVE-2021-4034) |
| `cups*`, `avahi-daemon`, `bluetooth` | Printing, mDNS, BT | **Yes** | Avahi opens UDP/5353 to the LAN |
| `rpcbind`, `nfs-common` | NFS client | Only if no NFS CSI/`nfs` volumes | `rpcbind` listens on 111/tcp+udp |
| `multipathd` | FC/iSCSI multipath | Yes if no such storage | Required by several block CSI drivers — verify |
| `whoopsie`, `apport` | Crash reporting to vendor | **Yes** | `apport` also rewrites `kernel.core_pattern`; see §7.4 |
| `unattended-upgrades` | Auto-patching | **Depends** | On mutable nodes: keep, security pocket only. On immutable/image-built nodes: **mask** — patching happens by replacing the node, and surprise in-place restarts of `containerd` cause node-level incidents |
| `cron` / `atd` | Scheduled jobs | Mask `atd`; keep `cron` only if something uses it | `at` is a SUID persistence primitive |
| `getty@tty*`, `serial-getty@*` | Console login | Keep **one** for break-glass on bare metal; mask on cloud VMs where console access is out-of-band | Losing all consoles on bare metal is a truck-roll |
| `rsyslog` | Local syslog | Usually **yes** — `journald` + a log shipper DaemonSet is enough | If your SIEM pulls syslog from the host, keep |
| `sshd` | Administration | **Ideally yes** on immutable fleets; otherwise harden hard (§9.3) | Removing it before you have out-of-band access is how you lose a fleet |

```bash
$ sudo systemctl mask --now \
    ModemManager.service udisks2.service \
    avahi-daemon.service avahi-daemon.socket \
    bluetooth.service cups.service cups.socket \
    atd.service whoopsie.service apport.service \
    rpcbind.service rpcbind.socket
Created symlink /etc/systemd/system/ModemManager.service → /dev/null.
Created symlink /etc/systemd/system/udisks2.service → /dev/null.
...

$ sudo apt-get purge -y --autoremove \
    policykit-1 pkexec snapd modemmanager udisks2 \
    avahi-daemon bluez cups-common apport whoopsie \
    telnet ftp rsh-client talk finger \
    gcc g++ make binutils cpp perl-modules-5.38
Reading package lists... Done
The following packages will be REMOVED:
  apport* avahi-daemon* binutils* bluez* cpp* g++* gcc* make* modemmanager*
  pkexec* policykit-1* snapd* udisks2* whoopsie* ...
0 upgraded, 0 newly installed, 214 to remove and 0 not upgraded.
After this operation, 486 MB disk space will be freed.
```

> **The compiler rule.** A node with `gcc`, `make` and kernel headers is a node where a kernel exploit can be compiled *in place* against the exact running kernel. Build DKMS modules (GPU drivers, in-tree-absent NICs) in the image pipeline, never on the node.

### 4.3 Hardening the services you must keep

For the few remaining non-runtime daemons, use systemd sandboxing rather than trust. Example for a host `node_exporter` (the archetype of "small daemon that must stay"):

```ini
# /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --no-collector.wifi \
  --no-collector.hwmon \
  --collector.filesystem.mount-points-exclude='^/(dev|proc|sys|var/lib/kubelet/.+|run/containerd/.+)($|/)'

# --- identity -------------------------------------------------------------
DynamicUser=yes
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=

# --- filesystem -----------------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/
InaccessiblePaths=/etc/kubernetes /var/lib/kubelet /var/lib/etcd /root
ProtectProc=invisible
ProcSubset=pid

# --- kernel ---------------------------------------------------------------
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount @debug

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl daemon-reload && sudo systemctl restart node_exporter
$ systemd-analyze security node_exporter.service --no-pager | tail -3
→ Overall exposure level for node_exporter.service: 1.4 OK 🙂
```

> **Do not try this on `kubelet.service` or `containerd.service`.** `ProtectKernelModules=yes` prevents `modprobe`; `RestrictNamespaces=` breaks container creation; `ProtectKernelTunables=yes` breaks `--protect-kernel-defaults` reconciliation and CNI sysctl writes; `MountFlags=`/`ProtectSystem=` break the shared mount propagation kubelet needs for CSI. The only sandboxing directives that are consistently safe on kubelet are `ProtectHome=read-only` and `OOMScoreAdjust=-999` (the latter for availability, not security).

---

## 5. Package and image minimization

### 5.1 Runtime, not interactive-admin

Target set for a worker node: kernel + init + container runtime + kubelet + CNI binaries + a network stack + a log agent hook. Explicitly *not*: compilers, interpreters beyond what init needs, `tcpdump`/`strace`/`gdb` (ship them in an ephemeral debug container instead — see §12.3), mail transport agents, X libraries, documentation.

```bash
# Biggest offenders, by installed size — a good place to look for surprises
$ dpkg-query -W -f='${Installed-Size}\t${binary:Package}\n' | sort -rn | head -12
187432  linux-image-6.8.0-79-generic
 92140  linux-modules-6.8.0-79-generic
 43188  containerd.io
 41022  kubelet
 28104  snapd
 21556  perl-modules-5.38
 18744  git
 12882  python3.12
 11930  linux-firmware
  9840  gcc-13
  ...
```

`linux-firmware` on a cloud VM is ~1 GB of firmware blobs for hardware that does not exist; `linux-modules-extra-*` likewise. On bare metal, prune carefully — you will hit a NIC that needs exactly the blob you deleted.

### 5.2 Prevent recommends from re-inflating the image

```conf
# /etc/apt/apt.conf.d/99-minimal
APT::Install-Recommends "false";
APT::Install-Suggests   "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant   "false";
Acquire::Languages "none";
```

```conf
# /etc/dpkg/dpkg.cfg.d/01-nodoc  — no man pages, no docs, no locales
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/en*
```

### 5.3 Pin the versions that matter, then stop drifting

```bash
$ sudo apt-mark hold kubelet kubeadm kubectl containerd.io
kubelet set on hold.
kubeadm set on hold.
kubectl set on hold.
containerd.io set on hold.

$ apt-mark showhold
containerd.io
kubeadm
kubectl
kubelet
```

If you keep `unattended-upgrades` on mutable nodes, restrict it to the security pocket and forbid reboots:

```conf
# /etc/apt/apt.conf.d/52-node-unattended
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "kubelet"; "kubeadm"; "kubectl"; "containerd.io"; "runc"; "linux-image-.*";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MinimalSteps "true";
```

Kernel and runtime upgrades must go through drain → replace, never through a surprise 06:00 `apt` transaction on 300 nodes.

---

## 6. Filesystem layout and mount options

Separate mounts exist for two reasons: **capacity isolation** (a log flood must not fill `/`) and **`nodev,nosuid,noexec` enforcement**.

```
# /etc/fstab  — worker node reference layout
# <device>                                  <mount>          <fs>    <options>                                   <dump> <pass>
UUID=6a1a0e0e-6bd1-4b19-9f10-2c9f0e1f2b30   /                ext4    defaults,relatime                            0      1
UUID=8b2c1c14-b5b6-4a09-a2fd-4d8d2e3a11aa   /boot            ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=1f7d90a0-3f60-4f18-bb2d-91c1a2f4d012   /boot/efi        vfat    defaults,nodev,nosuid,noexec,umask=0077      0      2
UUID=9c33ab2d-2a51-4a7f-9a1c-7c2b8d5f5a41   /home            ext4    defaults,nodev,nosuid,relatime               0      2
UUID=b0f1e5c9-8f7c-4b76-9c3a-2f5d2a7b9c02   /var             ext4    defaults,relatime                            0      2
UUID=c7e2d1b8-1a44-4dbb-8e2e-6f0a1c4b3d55   /var/log         ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=d81a6c33-52ef-4a1e-9c98-51f0a2f5c7b6   /var/log/audit   ext4    defaults,nodev,nosuid,noexec,relatime        0      2
UUID=e4b0f2a7-77ad-4a4d-b0b6-9f0d3c1e7a88   /var/tmp         ext4    defaults,nodev,nosuid,noexec,relatime        0      2
tmpfs                                       /tmp             tmpfs   defaults,nodev,nosuid,noexec,size=2G,mode=1777 0    0
tmpfs                                       /dev/shm         tmpfs   defaults,nodev,nosuid,noexec,size=1G          0    0
```

> ### The `/var` trap — read this twice
>
> **`/var` must keep `exec` and `suid`.** Container root filesystems are `overlayfs` mounts whose lower/upper dirs live under `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/`. The `noexec`/`nosuid` flags of the *backing* mount propagate to the overlay. Mount `/var` `noexec` and **every container on the node fails to start**; mount it `nosuid` and any image that relies on a setuid binary breaks in confusing ways.
>
> The same applies to `/var/lib/kubelet` if you split it out (CSI drivers place executables under it) and to `/run` (containerd shim sockets and some runtime helpers).
>
> Put the restrictive flags on `/tmp`, `/var/tmp`, `/var/log`, `/dev/shm`, `/home`, `/boot` — never on `/var` or `/var/lib/containerd`.

Verify what is actually in effect (not what `fstab` claims):

```bash
$ findmnt -no TARGET,OPTIONS /tmp /var /var/log /dev/shm /var/lib/containerd
/tmp             rw,nosuid,nodev,noexec,relatime,size=2097152k,mode=755
/var             rw,relatime
/var/log         rw,nosuid,nodev,noexec,relatime
/dev/shm         rw,nosuid,nodev,noexec
/var/lib/containerd  rw,relatime            # inherits /var — correct
```

Sanity check that containers still exec after any mount change:

```bash
$ sudo ctr -n k8s.io run --rm docker.io/library/busybox:1.36 mounttest /bin/echo ok
ok
```

---

## 7. Kernel surface reduction

### 7.1 Module blacklisting — the highest-value, highest-risk change

Autoloading is the mechanism: an unprivileged process calling `socket(AF_TIPC, SOCK_STREAM, 0)` causes the kernel to `request_module("net-pf-30")` and load TIPC. Blacklisting alone is **not enough** — `blacklist` only stops *alias-based* autoload for that name in some paths; the reliable pattern is `install <mod> /bin/false`.

```conf
# /etc/modprobe.d/99-cks-hardening.conf
# Rationale: none of these are used by the container runtime, the CNI, or the
# CSI drivers deployed in this cluster. Each has a history of memory-safety CVEs
# reachable from an unprivileged local process via module autoload.
# Verify against your CSI/CNI before rolling out — see the KEEP list below.

# --- legacy / rarely used filesystems ------------------------------------
install cramfs    /bin/false
install freevxfs  /bin/false
install jffs2     /bin/false
install hfs       /bin/false
install hfsplus   /bin/false
install udf       /bin/false
install gfs2      /bin/false
install ksmbd     /bin/false

# --- exotic network protocols (all have had remote/local root CVEs) ------
install dccp      /bin/false
install sctp      /bin/false
install rds       /bin/false
install tipc      /bin/false
install n-hdlc    /bin/false
install ax25      /bin/false
install netrom    /bin/false
install x25       /bin/false
install rose      /bin/false
install decnet    /bin/false
install econet    /bin/false
install af_802154 /bin/false
install ipx       /bin/false
install appletalk /bin/false
install psnap     /bin/false
install p8023     /bin/false
install p8022     /bin/false
install can       /bin/false
install atm       /bin/false

# --- physical interfaces that do not exist on a server -------------------
install usb-storage   /bin/false
install firewire-core /bin/false
install thunderbolt   /bin/false
install floppy        /bin/false
install bluetooth     /bin/false
install btusb         /bin/false
install uvcvideo      /bin/false
install vivid         /bin/false          # CVE-2019-18683, test driver, never needed
install joydev        /bin/false
install pcspkr        /bin/false

# --- keep as blacklist-only: needed by snapd/CSI on some fleets ----------
# squashfs: REQUIRED by snapd and by several CSI drivers that ship squashfs
#           images. Do NOT `install ... /bin/false` on Ubuntu with snaps.
# blacklist squashfs
```

**The KEEP list — blacklisting any of these breaks the cluster:**

| Module | Needed by | Symptom if blocked |
|---|---|---|
| `overlay` | containerd overlayfs snapshotter | containerd falls back or fails: `skip plugin "io.containerd.snapshotter.v1.overlayfs"` and every pod stays `ContainerCreating` |
| `br_netfilter` | kube-proxy iptables/ipvs, Calico, Flannel | `sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory`; Service traffic from pods to pods on the same node silently drops |
| `nf_conntrack`, `nf_nat`, `iptable_nat`, `iptable_filter`, `xt_*` | kube-proxy | `iptables-restore: line N failed`; NodePort/ClusterIP dead |
| `ip_vs`, `ip_vs_rr`, `ip_vs_wrr`, `ip_vs_sh` | kube-proxy IPVS mode | kube-proxy CrashLoop: `can't use the IPVS proxier: IPVS proxier will not be used because the following required kernel modules are not loaded` |
| `vxlan` | Flannel VXLAN, Calico VXLAN, Cilium VXLAN | Cross-node pod traffic dead |
| `wireguard` | Cilium/Calico encryption | Encrypted overlay fails to come up |
| `dm_mod`, `dm_thin_pool`, `nbd`, `rbd`, `iscsi_tcp`, `nfsv4` | Block/file CSI drivers | Volume attach hangs, pod stuck in `ContainerCreating` |
| `configs`, `ebtables` | some CNI plugins, kube-router | Varies |

Declare the required set explicitly so autoload is never on the critical path:

```conf
# /etc/modules-load.d/kubernetes.conf
overlay
br_netfilter
nf_conntrack
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
vxlan
```

Apply and verify:

```bash
$ sudo systemctl restart systemd-modules-load.service
$ sudo depmod -a && sudo update-initramfs -u
update-initramfs: Generating /boot/initrd.img-6.8.0-79-generic

$ modprobe -n -v tipc
install /bin/false

$ sudo modprobe tipc; echo "exit=$?"
exit=1

$ lsmod | grep -E '^(overlay|br_netfilter|vxlan)'
overlay               212992  59
br_netfilter           32768  0
vxlan                 143360  0
```

### 7.2 Sealing module loading entirely (advanced, gated)

```bash
$ sudo sysctl -w kernel.modules_disabled=1
kernel.modules_disabled = 1
```

This is a **one-way door until reboot**: no module can ever be loaded again. It is the strongest single anti-rootkit control available on a mutable node, and it is also the fastest way to break a cluster.

- kube-proxy in `iptables` mode autoloads `xt_*` modules the first time a new match type appears in a rule; if `modules_disabled=1` was set before that happened, `iptables-restore` fails and Services stop being programmed.
- CSI drivers autoload `iscsi_tcp`/`rbd`/`nfsv4` on first volume attach.
- Some CNIs load modules on config change, not at startup.

Only deploy it on nodes whose module set is fully characterised, and only *after* the runtime, CNI and CSI have converged:

```ini
# /etc/systemd/system/seal-modules.service
[Unit]
Description=Seal kernel module loading after the node is Ready
# Order after everything that autoloads modules.
After=kubelet.service containerd.service systemd-modules-load.service
Requires=kubelet.service
ConditionPathExists=/etc/kubernetes/kubelet.conf

[Service]
Type=oneshot
RemainAfterExit=yes
# Give CNI/CSI DaemonSets time to land and load their modules.
ExecStartPre=/bin/sleep 300
ExecStartPre=/usr/local/sbin/verify-required-modules.sh
ExecStart=/sbin/sysctl -w kernel.modules_disabled=1

[Install]
WantedBy=multi-user.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-required-modules.sh
# Refuse to seal the kernel unless every module this node needs is already loaded.
set -euo pipefail

REQUIRED=(overlay br_netfilter nf_conntrack vxlan ip_tables iptable_nat iptable_filter)
missing=()

for m in "${REQUIRED[@]}"; do
    lsmod | awk '{print $1}' | grep -qx "${m//-/_}" || missing+=("$m")
done

if ((${#missing[@]})); then
    echo "refusing to seal module loading; missing: ${missing[*]}" >&2
    exit 1
fi
echo "all ${#REQUIRED[@]} required modules present; sealing"
```

> **Recommendation.** On mutable fleets, ship the module blacklist (§7.1) but leave `modules_disabled=0`, and detect unexpected module loads with runtime security tooling instead (domain 6). Reserve `modules_disabled=1` for immutable images where you control the entire module set. Talos and Bottlerocket give you the equivalent guarantee for free.

### 7.3 Kernel lockdown and Secure Boot

```bash
$ cat /sys/kernel/security/lockdown
[none] integrity confidentiality

$ mokutil --sb-state
SecureBoot enabled
```

| Mode | Blocks | Breaks |
|---|---|---|
| `none` | nothing | nothing |
| `integrity` | unsigned module load, `/dev/mem`, `kexec` of unsigned images, direct PCI/IO port access, hibernation, unsigned firmware update | out-of-tree unsigned modules (NVIDIA/DKMS unless you sign them), `kexec`-based fast reboot tooling |
| `confidentiality` | everything in `integrity` **plus** reading kernel memory: `kprobes`, `bpf_probe_read_kernel`, `perf` kernel samples, `/proc/kcore` | **eBPF-based observability and security tooling** — Cilium's kernel-memory-reading features, Falco's modern-eBPF probe, Pixie, `bpftrace`, `perf top` |

Enable via kernel command line:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="lockdown=integrity module.sig_enforce=1 init_on_alloc=1 init_on_free=1 slab_nomerge pti=on vsyscall=none randomize_kstack_offset=on"
```

```bash
$ sudo update-grub && sudo reboot
Sourcing file `/etc/default/grub'
Generating grub configuration file ...
done

# after reboot
$ cat /sys/kernel/security/lockdown
none [integrity] confidentiality
```

> **Trade-off to state explicitly in your design doc:** `lockdown=confidentiality` and "we run Falco/Cilium/Tetragon for runtime detection" (domain 6) are largely mutually exclusive. In practice most fleets pick `integrity` + Secure Boot + signed modules, and keep eBPF-based detection. Choosing `confidentiality` means accepting that you lose the sensor that would tell you an escape happened.

### 7.4 `sysctl` hardening

```conf
# /etc/sysctl.d/99-cks-hardening.conf
# ---------------------------------------------------------------------------
# Kernel information leaks and privesc primitives
# ---------------------------------------------------------------------------
kernel.dmesg_restrict           = 1     # non-root cannot read the ring buffer (KASLR leaks)
kernel.kptr_restrict            = 2     # hide kernel pointers from /proc even for root
kernel.perf_event_paranoid      = 3     # no unprivileged perf; set to 2 if you need profiling
kernel.kexec_load_disabled      = 1     # no live kernel replacement (one-way until reboot)
kernel.sysrq                    = 0     # no magic SysRq from a compromised console
kernel.unprivileged_bpf_disabled = 1    # only CAP_BPF/root may load BPF; Cilium is root, so OK
net.core.bpf_jit_harden         = 2     # blind JIT constants (small perf cost on high-pps nodes)
kernel.yama.ptrace_scope        = 1     # only parents may ptrace; 2 = admin-only, 3 = never
kernel.randomize_va_space       = 2
fs.suid_dumpable                = 0
kernel.core_pattern             = |/bin/false   # see note below — escape primitive
kernel.panic_on_oops            = 1
kernel.panic                    = 10

# ---------------------------------------------------------------------------
# Filesystem link/FIFO hardening (classic /tmp race exploits)
# ---------------------------------------------------------------------------
fs.protected_hardlinks          = 1
fs.protected_symlinks           = 1
fs.protected_fifos              = 2
fs.protected_regular            = 2

# ---------------------------------------------------------------------------
# Network — DO NOT disable ip_forward, Kubernetes requires it
# ---------------------------------------------------------------------------
net.ipv4.ip_forward                     = 1
net.bridge.bridge-nf-call-iptables      = 1
net.bridge.bridge-nf-call-ip6tables     = 1
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv4.conf.all.secure_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.default.send_redirects    = 0
net.ipv4.conf.all.accept_source_route   = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians          = 1
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                 = 1
net.ipv6.conf.all.accept_redirects      = 0
net.ipv6.conf.all.accept_ra             = 0
net.ipv6.conf.all.accept_source_route   = 0

# ---------------------------------------------------------------------------
# Values the kubelet expects when --protect-kernel-defaults=true.
# Omitting these makes the kubelet refuse to start. See §11.2.
# ---------------------------------------------------------------------------
vm.overcommit_memory     = 1
vm.panic_on_oom          = 0
kernel.keys.root_maxbytes = 25000000
kernel.keys.root_maxkeys  = 1000000

# ---------------------------------------------------------------------------
# Capacity — a busy node exhausts these long before it exhausts CPU
# ---------------------------------------------------------------------------
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 524288
fs.file-max                   = 2097152
net.netfilter.nf_conntrack_max = 1048576
```

```bash
$ sudo sysctl --system 2>&1 | tail -8
* Applying /etc/sysctl.d/99-cks-hardening.conf ...
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
...
* Applying /etc/sysctl.conf ...

$ sysctl kernel.dmesg_restrict kernel.kptr_restrict net.ipv4.ip_forward
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.ip_forward = 1
```

Three trade-offs you must decide consciously, not copy:

| Setting | Aggressive value | Cost |
|---|---|---|
| `kernel.yama.ptrace_scope` | `2` or `3` | `3` breaks `gdb`, `strace`, `delve`, and any debug sidecar — including ephemeral debug containers targeting a process. `1` is the sane default. |
| `net.ipv4.conf.all.rp_filter` | `1` (strict) | **Breaks several CNI datapaths** (Cilium and some Calico modes need `0` or loose `2` on specific interfaces). Do not set `1` globally without testing pod egress and Service return paths. |
| `user.max_user_namespaces` | `0` | Historically recommended (user namespaces are a large privesc surface). **But** Kubernetes pod-level user namespaces (`spec.hostUsers: false`) require unprivileged user namespaces, and that feature is one of the strongest container-escape mitigations available. Keep them enabled (e.g. `16384`) and use them. |

> **`kernel.core_pattern` is a container-escape primitive.** It is a *global* kernel setting, not namespaced. A process with `CAP_SYS_ADMIN` in a container that can write `/proc/sys/kernel/core_pattern` sets it to `|/path/to/payload`, then deliberately segfaults — and the kernel executes the payload **on the host, as root, outside all namespaces**. Two defences: never grant `CAP_SYS_ADMIN` with a writable `/proc/sys` (domain 4), and set a non-pipe pattern here so an accidental host-side write is inert.

---

## 8. Network exposure

### 8.1 Port inventory

| Port | Proto | Component | Auth | Who legitimately connects |
|---|---|---|---|---|
| 6443 | TCP | kube-apiserver | mTLS/OIDC/token | everything |
| 2379–2380 | TCP | etcd client/peer | mTLS | apiserver, etcd peers |
| 10250 | TCP | kubelet API (HTTPS) | mTLS + webhook authz | apiserver (`exec`, `logs`, `portforward`), metrics-server |
| **10255** | TCP | kubelet **read-only** | **NONE** | nothing — **disable** |
| 10248 | TCP | kubelet healthz | none | localhost only (bind `127.0.0.1`) |
| 10256 | TCP | kube-proxy healthz | none | cloud LB health checks |
| 10249 | TCP | kube-proxy metrics | none | localhost / Prometheus |
| 10257 | TCP | kube-controller-manager | mTLS | localhost (kubeadm binds `127.0.0.1`) |
| 10259 | TCP | kube-scheduler | mTLS | localhost (kubeadm binds `127.0.0.1`) |
| 30000–32767 | TCP/UDP | NodePort range | workload-defined | LB / clients |
| 8472 | UDP | Flannel/Cilium VXLAN | none (encrypt separately) | other nodes |
| 4789 | UDP | Calico VXLAN | none | other nodes |
| 179 | TCP | Calico/kube-router BGP | optional MD5 | other nodes / ToR |
| 51820/51871 | UDP | WireGuard (Calico/Cilium) | crypto | other nodes |
| 9153 | TCP | CoreDNS metrics | none | Prometheus |

### 8.2 Host firewall with nftables

> ### The `flush ruleset` catastrophe
>
> On modern distributions `iptables` is `iptables-nft`: kube-proxy's rules **live in the nftables ruleset** (tables `ip filter`, `ip nat`, `ip mangle`), and kube-proxy in `nftables` proxy mode uses `ip kube-proxy` / `ip6 kube-proxy`. Cilium and Calico add their own tables too.
>
> A firewall script that begins with `flush ruleset` — which is what nearly every nftables tutorial shows — **deletes all of kube-proxy's and the CNI's rules**. Services stop working instantly; kube-proxy re-syncs on its period (default 30 s for `iptablesSyncPeriod`), so you get an intermittent, self-healing, maddening outage that looks like a network problem. Cilium's BPF datapath does not resync from netfilter at all, so parts of it never come back until the agent restarts.
>
> Use the idempotent create-then-delete-then-define pattern below. Never `flush ruleset` on a Kubernetes node.

```nft
#!/usr/sbin/nft -f
# /etc/nftables.conf — host firewall for a Kubernetes worker node.
#
# NOTE: no `flush ruleset`. We only ever touch our own table.
# The two lines below are the idempotent pattern: `table` creates it if absent,
# `delete table` then removes it cleanly, and the definition recreates it.

table inet k8s_host
delete table inet k8s_host

table inet k8s_host {

    # ---- inventory -------------------------------------------------------
    set nodes_v4 {
        type ipv4_addr
        flags interval
        comment "every node in the cluster (control plane + workers)"
        elements = { 10.20.0.0/22 }
    }

    set pods_v4 {
        type ipv4_addr
        flags interval
        comment "cluster podCIDR"
        elements = { 10.244.0.0/16 }
    }

    set admin_v4 {
        type ipv4_addr
        flags interval
        comment "bastion / jump hosts only — never 0.0.0.0/0"
        elements = { 10.20.250.10/32, 10.20.250.11/32 }
    }

    set lb_v4 {
        type ipv4_addr
        flags interval
        comment "load balancer / health-check sources for NodePort"
        elements = { 10.20.240.0/24 }
    }

    set overlay_ifaces {
        type ifname
        elements = { "cni0", "flannel.1", "cilium_host", "cilium_net", "cilium_vxlan" }
    }

    # ---- INPUT -----------------------------------------------------------
    chain input {
        type filter hook input priority filter; policy drop;

        ct state vmap { established : accept, related : accept, invalid : drop }

        iif "lo" accept comment "loopback: kubelet healthz, kube-proxy metrics, CM/scheduler"

        # Pod and overlay traffic terminating on the host (kube-proxy hairpin,
        # hostNetwork services, CNI health checks).
        iifname @overlay_ifaces accept
        iifname "lxc*" accept comment "Cilium veth host side"
        iifname "cali*" accept comment "Calico veth host side"
        ip saddr @pods_v4 accept

        # ICMP: keep PMTU discovery working or you will chase phantom TCP hangs.
        ip  protocol icmp   icmp  type { destination-unreachable, time-exceeded, parameter-problem } accept
        ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } accept
        icmp type echo-request limit rate 10/second accept

        # --- administration ---
        ip saddr @admin_v4 tcp dport 22 accept comment "SSH from bastions only"

        # --- Kubernetes control-plane-to-node ---
        ip saddr @nodes_v4 tcp dport 10250 accept comment "kubelet API: exec/logs/metrics"

        # --- CNI (adjust to the CNI actually deployed) ---
        ip saddr @nodes_v4 udp dport 8472  accept comment "VXLAN (Flannel/Cilium)"
        ip saddr @nodes_v4 udp dport 4789  accept comment "VXLAN (Calico)"
        ip saddr @nodes_v4 tcp dport 179   accept comment "BGP (Calico/kube-router)"
        ip saddr @nodes_v4 udp dport 51871 accept comment "WireGuard (Cilium)"
        ip saddr @nodes_v4 tcp dport 4240  accept comment "Cilium health checks"

        # --- load balancer ---
        ip saddr @lb_v4 tcp dport 10256          accept comment "kube-proxy healthz"
        ip saddr @lb_v4 tcp dport 30000-32767    accept comment "NodePort"
        ip saddr @lb_v4 udp dport 30000-32767    accept

        # Everything else is dropped by policy. Log a sample for forensics.
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop " level warn flags all
        counter comment "input drops"
    }

    # ---- FORWARD ---------------------------------------------------------
    # Deliberately policy accept: kube-proxy and the CNI program pod-to-pod and
    # Service forwarding in the `ip filter`/`ip kube-proxy` tables. A `drop`
    # policy here blackholes all pod traffic even though those rules accept it,
    # because a drop in ANY chain at this hook is final.
    chain forward {
        type filter hook forward priority filter; policy accept;
        counter comment "forward — governed by kube-proxy/CNI, not here"
    }

    # ---- OUTPUT ----------------------------------------------------------
    chain output {
        type filter hook output priority filter; policy accept;

        # Egress filtering on a node breaks image pulls, IMDS, DNS and the
        # apiserver connection in non-obvious ways. Do it at the cloud SG /
        # network layer, not here. Kept as an explicit design decision.
        counter comment "output"
    }
}
```

Deploy it the way that does not lock you out:

```bash
# 1. Syntax check without applying
$ sudo nft -c -f /etc/nftables.conf && echo "syntax ok"
syntax ok

# 2. Arm a rollback BEFORE applying — 5 minutes to prove you still have access
$ sudo systemd-run --on-active=5min --unit=fw-rollback \
    /usr/sbin/nft delete table inet k8s_host
Running timer as unit: fw-rollback.timer
Will run service as unit: fw-rollback.service

# 3. Apply
$ sudo nft -f /etc/nftables.conf

# 4. Prove the cluster still works from a SECOND terminal, then cancel rollback
$ kubectl get --raw='/readyz'
ok
$ kubectl -n kube-system get pods --field-selector spec.nodeName=worker-03 -o name | head -3
pod/cilium-9x4kq
pod/kube-proxy-7m2vd
pod/node-exporter-lp8rn
$ sudo systemctl stop fw-rollback.timer

# 5. Persist
$ sudo systemctl enable --now nftables.service
Created symlink /etc/systemd/system/multi-user.target.wants/nftables.service → /usr/lib/systemd/system/nftables.service.
```

Verify the rules and — critically — that kube-proxy's tables survived:

```bash
$ sudo nft list tables
table ip nat
table ip filter
table ip mangle
table ip kube-proxy
table ip6 kube-proxy
table inet k8s_host
table ip cilium_post_nat_node        # (present only with Cilium's netfilter integration)

$ sudo nft list chain inet k8s_host input | head -12
table inet k8s_host {
	chain input {
		type filter hook input priority filter; policy drop;
		ct state vmap { established : accept, related : accept, invalid : drop }
		iif "lo" accept comment "loopback: kubelet healthz, kube-proxy metrics, CM/scheduler"
		iifname @overlay_ifaces accept
		iifname "lxc*" accept comment "Cilium veth host side"
		ip saddr @pods_v4 accept
		...

$ sudo nft list counters table inet k8s_host
table inet k8s_host {
	counter  {
		packets 143 bytes 8964
		comment "input drops"
	}
}
```

### 8.3 Defence in depth: the firewall you should trust more

Host firewalls on Kubernetes nodes are fragile — every CNI upgrade can change interface names, and a bad rule causes a cluster-wide incident. In cloud environments the security group / NSG / firewall policy is enforced *outside* the compromised host and cannot be flushed by a root attacker on the node. Prefer:

1. **Cloud SG / physical ACL** as the primary boundary (attacker on the node cannot edit it).
2. **Host nftables** as a second layer, kept deliberately simple.
3. **NetworkPolicy / CiliumNetworkPolicy** for pod-level segmentation (topic 5.3).

Blocking the instance metadata service from pods belongs to 5.3 but is worth naming here because it is the most common node-adjacent escalation path:

```bash
# Block pod CIDR → IMDS at the host, so a compromised pod cannot steal the node's IAM role
$ sudo nft add table inet imds_guard
$ sudo nft add chain inet imds_guard fwd '{ type filter hook forward priority -10 ; }'
$ sudo nft add rule inet imds_guard fwd ip saddr 10.244.0.0/16 ip daddr 169.254.169.254 \
    counter log prefix "imds-block " drop
```

---

## 9. Users, SUID, and local privilege escalation

### 9.1 Accounts

```bash
# Interactive accounts (UID >= 1000 with a real shell)
$ awk -F: '($3>=1000)&&($3!=65534)&&($7!~/(nologin|false|sync)$/){print $1" uid="$3" shell="$7}' /etc/passwd
ubuntu uid=1000 shell=/bin/bash

# Accounts with an empty password field — must be zero
$ sudo awk -F: '($2==""){print "EMPTY PASSWORD: "$1}' /etc/shadow

# Non-root UID 0 accounts — must be exactly one line
$ awk -F: '($3==0){print $1}' /etc/passwd
root

# Lock the root password entirely; access is via SSH key to a sudo account,
# or via cloud console. `!` in field 2 = locked.
$ sudo passwd -l root
passwd: password expiry information changed.
$ sudo awk -F: '$1=="root"{print $2}' /etc/shadow
!*
```

On an immutable fleet, the correct number of interactive accounts is **zero**; nodes are replaced, not fixed. On a mutable fleet, exactly one break-glass account with an SSH key held in a secrets manager and audited on use.

### 9.2 SUID/SGID reduction

| Binary | Purpose | Node needs it? | Action |
|---|---|---|---|
| `pkexec` | polkit privilege escalation | No | **Purge** (`policykit-1`) — CVE-2021-4034 |
| `at` | one-shot jobs | No | Purge |
| `chfn`, `chsh`, `newgrp`, `gpasswd`, `expiry`, `chage` | account metadata for interactive users | No | `chmod u-s,g-s` or purge |
| `wall`, `write` | terminal messaging | No | `chmod g-s` |
| `mount`, `umount` | unprivileged mounting | No (kubelet is root) | `chmod u-s` — **verify no fuse-based CSI on the node** |
| `ping` | ICMP | Convenient | Replace SUID with `cap_net_raw`: `setcap cap_net_raw+ep /usr/bin/ping` |
| `su` | switch user | Break-glass | Keep, restrict to `wheel`/`sudo` group via PAM |
| `sudo` | privilege delegation | Yes, if humans log in | Keep, restrict (§9.4) |
| `passwd` | password change | Only with local accounts | Keep if any local password exists |
| `ssh-keysign` | host-based SSH auth | No | `chmod u-s` |
| `fusermount3` | FUSE | Only with FUSE CSI (e.g. `s3fs`, `gcsfuse`, `rclone`) | Check before removing |

```bash
$ sudo chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp /usr/bin/umount /usr/bin/mount /usr/lib/openssh/ssh-keysign
$ sudo chmod g-s /usr/bin/wall /usr/bin/write /usr/bin/expiry /usr/bin/chage
$ sudo setcap cap_net_raw+ep /usr/bin/ping && sudo chmod u-s /usr/bin/ping

$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort
2755 /usr/bin/crontab
4755 /usr/bin/passwd
4755 /usr/bin/su
4755 /usr/bin/sudo
4755 /usr/bin/fusermount3
4755 /usr/lib/dbus-1.0/dbus-daemon-launch-helper

$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l
6
```

From 26 to 6. Persist this list as a baseline file and alert on any diff — a new SUID binary appearing on a node is a high-signal indicator of compromise.

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null \
    | sort | sudo tee /var/lib/node-baseline/suid.txt >/dev/null
```

### 9.3 SSH

```conf
# /etc/ssh/sshd_config.d/10-hardening.conf   (drop-in wins over the main file)
Port 22
AddressFamily inet
ListenAddress 10.20.1.13

# --- authentication -------------------------------------------------------
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30

# --- who -----------------------------------------------------------------
AllowGroups node-admins

# --- reduce feature surface ----------------------------------------------
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
GatewayPorts no
Compression no

# --- session hygiene ------------------------------------------------------
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
LogLevel VERBOSE
Banner /etc/issue.net

# --- crypto ---------------------------------------------------------------
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512
```

```bash
$ sudo sshd -t && echo "config ok"
config ok
$ sudo systemctl reload ssh
$ sudo ss -tlpn 'sport = :22'
State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
LISTEN 0      128       10.20.1.13:22          0.0.0.0:*     users:(("sshd",pid=1102,fd=3))
```

Note `AllowTcpForwarding no`: without it, an SSH-capable attacker tunnels straight to `127.0.0.1:10248`, `127.0.0.1:10257` and the container runtime socket, bypassing the host firewall entirely.

### 9.4 `sudo`

```conf
# /etc/sudoers.d/10-node-admins   (install with visudo -c -f, mode 0440)
Defaults    use_pty
Defaults    logfile="/var/log/sudo.log"
Defaults    log_input, log_output
Defaults    iolog_dir="/var/log/sudo-io/%{user}"
Defaults    timestamp_timeout=5
Defaults    passwd_timeout=1
Defaults    requiretty
Defaults    !visiblepw
Defaults    env_reset
Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

%node-admins ALL=(ALL:ALL) ALL
```

```bash
$ sudo visudo -c -f /etc/sudoers.d/10-node-admins
/etc/sudoers.d/10-node-admins: parsed OK

# NOPASSWD ALL is equivalent to handing out root; find it before an auditor does
$ sudo grep -rE 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d/ ; echo "exit=$?"
exit=1
```

---

## 10. Kubernetes-specific host surface

### 10.1 File permissions (the CIS section-4 checks, and why)

| Path | Mode | Owner | Why |
|---|---|---|---|
| `/etc/kubernetes/manifests/*.yaml` | `600` | `root:root` | Write = arbitrary privileged pod, no API server, no admission control |
| `/etc/kubernetes/pki/*.key` | `600` | `root:root` | Cluster CA private keys — read = mint any identity |
| `/etc/kubernetes/pki/*.crt` | `644` | `root:root` | Public |
| `/etc/kubernetes/pki/etcd` (dir) | `700` | `root:root` | etcd CA |
| `/etc/kubernetes/admin.conf` | `600` | `root:root` | `cluster-admin`. Should not exist on workers at all |
| `/etc/kubernetes/kubelet.conf` | `600` | `root:root` | Node identity |
| `/var/lib/kubelet/config.yaml` | `600` | `root:root` | Write = disable kubelet authn |
| `/var/lib/kubelet/pki` (dir) | `700` | `root:root` | Node client cert |
| `/var/lib/etcd` | `700` | `etcd`/`root` | The whole cluster state |
| `/etc/containerd/config.toml` | `600` | `root:root` | Write = swap runtime, disable seccomp default |
| `/run/containerd/containerd.sock` | `660` | `root:root` | Direct root-equivalent |
| `/etc/systemd/system/kubelet.service.d/*.conf` | `600` | `root:root` | Kubelet flags |
| `/opt/cni/bin/*` | `755` | `root:root` | Executed as root by kubelet on every pod sandbox |

```bash
$ sudo stat -c '%a %U:%G %n' \
    /etc/kubernetes/manifests/*.yaml \
    /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf \
    /var/lib/kubelet/config.yaml /etc/containerd/config.toml \
    /var/lib/etcd /var/lib/kubelet/pki 2>/dev/null
644 root:root /etc/kubernetes/manifests/etcd.yaml
644 root:root /etc/kubernetes/manifests/kube-apiserver.yaml
644 root:root /etc/kubernetes/manifests/kube-controller-manager.yaml
644 root:root /etc/kubernetes/manifests/kube-scheduler.yaml
600 root:root /etc/kubernetes/admin.conf
600 root:root /etc/kubernetes/kubelet.conf
600 root:root /var/lib/kubelet/config.yaml
664 root:root /etc/containerd/config.toml
700 root:root /var/lib/etcd
700 root:root /var/lib/kubelet/pki

$ sudo chmod 600 /etc/kubernetes/manifests/*.yaml /etc/containerd/config.toml
$ sudo chown -R root:root /etc/kubernetes /var/lib/kubelet
$ sudo find /etc/kubernetes/pki -name '*.key' -exec chmod 600 {} +
$ sudo find /etc/kubernetes/pki -name '*.crt' -exec chmod 644 {} +
$ sudo chmod 700 /etc/kubernetes/pki/etcd

$ sudo stat -c '%a %U:%G %n' /etc/kubernetes/manifests/*.yaml
600 root:root /etc/kubernetes/manifests/etcd.yaml
600 root:root /etc/kubernetes/manifests/kube-apiserver.yaml
600 root:root /etc/kubernetes/manifests/kube-controller-manager.yaml
600 root:root /etc/kubernetes/manifests/kube-scheduler.yaml
```

### 10.2 Hardened `KubeletConfiguration`

```yaml
# /var/lib/kubelet/config.yaml   (mode 0600, root:root)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

# --- identity / transport -------------------------------------------------
tlsCertFile: /var/lib/kubelet/pki/kubelet.crt
tlsPrivateKeyFile: /var/lib/kubelet/pki/kubelet.key
tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
tlsMinVersion: VersionTLS12

# --- authentication: no anonymous, no unauthenticated read-only port ------
authentication:
  anonymous:
    enabled: false                 # CIS 4.2.1
  webhook:
    enabled: true
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # CIS 4.2.3
authorization:
  mode: Webhook                    # CIS 4.2.2 — never AlwaysAllow
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

readOnlyPort: 0                    # CIS 4.2.4 — kills the unauthenticated :10255
healthzBindAddress: 127.0.0.1
healthzPort: 10248

# --- certificate lifecycle ------------------------------------------------
rotateCertificates: true                    # CIS 4.2.11
serverTLSBootstrap: true                    # CIS 4.2.12 — requires CSR approval

# --- host hardening -------------------------------------------------------
protectKernelDefaults: true                 # kubelet refuses to start on sysctl drift
makeIPTablesUtilChains: true                # CIS 4.2.6
seccompDefault: true                        # RuntimeDefault seccomp for every pod
streamingConnectionIdleTimeout: 5m0s        # CIS 4.2.5 — never 0
eventRecordQPS: 5
podPidsLimit: 4096                          # fork-bomb containment
failSwapOn: true

# --- what the kubelet is allowed to run -----------------------------------
staticPodPath: ""                           # workers: no static pods at all
allowedUnsafeSysctls: []                    # do not widen without a written case
featureGates: {}

# --- resource protection --------------------------------------------------
cgroupDriver: systemd
enforceNodeAllocatable: ["pods", "kube-reserved", "system-reserved"]
kubeReserved:
  cpu: "200m"
  memory: "512Mi"
  ephemeral-storage: "2Gi"
systemReserved:
  cpu: "200m"
  memory: "512Mi"
  ephemeral-storage: "2Gi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"

# --- cluster wiring -------------------------------------------------------
clusterDomain: cluster.local
clusterDNS:
  - 10.96.0.10
runtimeRequestTimeout: 2m0s
containerLogMaxSize: 50Mi
containerLogMaxFiles: 5
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 70
```

Note `staticPodPath: ""` on workers. A worker with a static pod directory is a worker where filesystem write access equals unaudited privileged pod execution.

### 10.3 containerd surface

```toml
# /etc/containerd/config.toml   (mode 0600, root:root) — containerd 2.x
version = 3

[plugins.'io.containerd.cri.v1.runtime']
  # Do not let a pod ask for a host-level userns/PID share it should not have.
  enable_selinux = false
  disable_apparmor = false
  restrict_oom_score_adj = true
  # Never enable: allows arbitrary host paths as volumes without validation.
  # device_ownership_from_security_context = false

  [plugins.'io.containerd.cri.v1.runtime'.containerd]
    default_runtime_name = 'runc'
    # Uncomment once gVisor/Kata is deployed for untrusted tenants (domain 4).
    # default_runtime_name = 'runsc'

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
      runtime_type = 'io.containerd.runc.v2'
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
        SystemdCgroup = true

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'

[plugins.'io.containerd.cri.v1.images']
  # Force credential checks on every pull; prevents a pod on this node from
  # using an image another tenant already pulled without proving entitlement.
  [plugins.'io.containerd.cri.v1.images'.pinned_images]
    sandbox = 'registry.k8s.io/pause:3.10'
```

Remove Docker leftovers if the node was ever migrated from dockershim:

```bash
$ sudo apt-get purge -y docker-ce docker-ce-cli docker.io containerd 2>/dev/null
$ ls -l /var/run/docker.sock 2>&1
ls: cannot access '/var/run/docker.sock': No such file or directory
$ command -v docker || echo "docker CLI absent — good"
docker CLI absent — good
```

A `docker` group on a node is a root-equivalent group. `getent group docker` must return nothing.

### 10.4 Swap

```bash
$ swapon --show
$ free -h | awk '/Swap/{print}'
Swap:            0B          0B          0B

$ sudo swapoff -a
$ sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
$ sudo systemctl mask swap.target
```

Swap support in kubelet has been beta for several releases with `LimitedSwap` behaviour, and `failSwapOn: true` remains the kubelet default. From a hardening standpoint the calculus is unchanged: **swap writes memory to disk**, and pod memory contains Secrets, TLS private keys and SA tokens. If you must run with swap for memory-overcommit reasons, put it on an encrypted device:

```bash
$ sudo cryptsetup open --type plain --key-file /dev/urandom /dev/nvme0n1p3 cryptswap
$ sudo mkswap /dev/mapper/cryptswap && sudo swapon /dev/mapper/cryptswap
```

---

## 11. Complete node bootstrap: infrastructure manifests

### 11.1 cloud-init for a minimized Ubuntu node

```yaml
#cloud-config
# user-data for a hardened Kubernetes worker (Ubuntu 24.04).
# Everything here is also expressible in the image build; keeping it in
# cloud-init makes the intent reviewable in the Terraform/Pulumi diff.

hostname: worker-03
fqdn: worker-03.prod.internal
manage_etc_hosts: true

ssh_pwauth: false
disable_root: true

users:
  - name: nodeadmin
    groups: [node-admins]
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0Q0m9k9m8nJk0f1c2R3t4Y5u6I7o8P9a0S1d2F3g4H bastion@prod

groups:
  - node-admins

write_files:
  - path: /etc/modules-load.d/kubernetes.conf
    permissions: "0644"
    content: |
      overlay
      br_netfilter
      nf_conntrack
      vxlan

  - path: /etc/modprobe.d/99-cks-hardening.conf
    permissions: "0644"
    content: |
      install cramfs /bin/false
      install freevxfs /bin/false
      install jffs2 /bin/false
      install hfs /bin/false
      install hfsplus /bin/false
      install udf /bin/false
      install dccp /bin/false
      install sctp /bin/false
      install rds /bin/false
      install tipc /bin/false
      install n-hdlc /bin/false
      install ax25 /bin/false
      install netrom /bin/false
      install x25 /bin/false
      install rose /bin/false
      install decnet /bin/false
      install econet /bin/false
      install af_802154 /bin/false
      install ipx /bin/false
      install appletalk /bin/false
      install psnap /bin/false
      install p8023 /bin/false
      install p8022 /bin/false
      install can /bin/false
      install atm /bin/false
      install usb-storage /bin/false
      install firewire-core /bin/false
      install thunderbolt /bin/false
      install floppy /bin/false
      install bluetooth /bin/false
      install uvcvideo /bin/false
      install vivid /bin/false
      install joydev /bin/false

  - path: /etc/sysctl.d/99-cks-hardening.conf
    permissions: "0644"
    content: |
      kernel.dmesg_restrict = 1
      kernel.kptr_restrict = 2
      kernel.perf_event_paranoid = 3
      kernel.kexec_load_disabled = 1
      kernel.sysrq = 0
      kernel.unprivileged_bpf_disabled = 1
      kernel.yama.ptrace_scope = 1
      kernel.randomize_va_space = 2
      kernel.core_pattern = |/bin/false
      kernel.panic_on_oops = 1
      kernel.panic = 10
      net.core.bpf_jit_harden = 2
      fs.suid_dumpable = 0
      fs.protected_hardlinks = 1
      fs.protected_symlinks = 1
      fs.protected_fifos = 2
      fs.protected_regular = 2
      net.ipv4.ip_forward = 1
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.conf.all.accept_redirects = 0
      net.ipv4.conf.all.send_redirects = 0
      net.ipv4.conf.all.accept_source_route = 0
      net.ipv4.conf.all.log_martians = 1
      net.ipv4.tcp_syncookies = 1
      net.ipv6.conf.all.accept_redirects = 0
      net.ipv6.conf.all.accept_ra = 0
      vm.overcommit_memory = 1
      vm.panic_on_oom = 0
      kernel.keys.root_maxbytes = 25000000
      kernel.keys.root_maxkeys = 1000000
      fs.inotify.max_user_instances = 8192
      fs.inotify.max_user_watches = 524288
      net.netfilter.nf_conntrack_max = 1048576

  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: "0600"
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthenticationMethods publickey
      AllowGroups node-admins
      AllowTcpForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTunnel no
      MaxAuthTries 3
      LoginGraceTime 30
      ClientAliveInterval 300
      ClientAliveCountMax 2
      LogLevel VERBOSE

  - path: /etc/apt/apt.conf.d/99-minimal
    permissions: "0644"
    content: |
      APT::Install-Recommends "false";
      APT::Install-Suggests "false";
      Acquire::Languages "none";

  - path: /etc/issue.net
    permissions: "0644"
    content: |
      Authorized access only. All sessions are logged and monitored.

bootcmd:
  - [ cloud-init-per, once, swapoff, swapoff, -a ]

runcmd:
  # --- service surface ---
  - systemctl mask --now snapd.service snapd.socket snapd.seeded.service
  - systemctl mask --now ModemManager.service udisks2.service avahi-daemon.service
      avahi-daemon.socket bluetooth.service atd.service whoopsie.service apport.service
      rpcbind.service rpcbind.socket
  - DEBIAN_FRONTEND=noninteractive apt-get purge -y --autoremove
      policykit-1 snapd modemmanager udisks2 avahi-daemon bluez apport whoopsie
      telnet ftp rsh-client talk finger gcc g++ make binutils
  # --- SUID surface ---
  - chmod u-s /usr/bin/chfn /usr/bin/chsh /usr/bin/newgrp /usr/bin/mount /usr/bin/umount /usr/lib/openssh/ssh-keysign
  - chmod g-s /usr/bin/wall /usr/bin/write /usr/bin/chage /usr/bin/expiry
  - setcap cap_net_raw+ep /usr/bin/ping && chmod u-s /usr/bin/ping
  # --- swap ---
  - sed -i '/\sswap\s/s/^/#/' /etc/fstab
  - systemctl mask swap.target
  # --- apply ---
  - systemctl restart systemd-modules-load.service
  - sysctl --system
  - depmod -a && update-initramfs -u
  - passwd -l root
  - sshd -t && systemctl reload ssh
  # --- baseline snapshot for drift detection ---
  - mkdir -p /var/lib/node-baseline
  - sh -c "find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort > /var/lib/node-baseline/suid.txt"
  - sh -c "ss -tulpnH | awk '{print \$1, \$5}' | sort > /var/lib/node-baseline/listen.txt"
  - sh -c "dpkg-query -f '\${binary:Package}\n' -W | sort > /var/lib/node-baseline/packages.txt"

package_update: true
package_upgrade: true

power_state:
  mode: reboot
  message: "rebooting to apply kernel cmdline and module changes"
  condition: true
```

### 11.2 Flatcar (Butane → Ignition)

```yaml
variant: flatcar
version: 1.1.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB0Q0m9k9m8nJk0f1c2R3t4Y5u6I7o8P9a0S1d2F3g4H bastion@prod

storage:
  files:
    - path: /etc/sysctl.d/99-cks-hardening.conf
      mode: 0644
      contents:
        inline: |
          kernel.dmesg_restrict = 1
          kernel.kptr_restrict = 2
          kernel.kexec_load_disabled = 1
          kernel.sysrq = 0
          kernel.unprivileged_bpf_disabled = 1
          kernel.yama.ptrace_scope = 1
          kernel.core_pattern = |/bin/false
          fs.protected_hardlinks = 1
          fs.protected_symlinks = 1
          fs.suid_dumpable = 0
          net.ipv4.ip_forward = 1
          net.bridge.bridge-nf-call-iptables = 1

    - path: /etc/modprobe.d/99-cks-hardening.conf
      mode: 0644
      contents:
        inline: |
          install dccp /bin/false
          install sctp /bin/false
          install rds /bin/false
          install tipc /bin/false
          install usb-storage /bin/false
          install firewire-core /bin/false
          install cramfs /bin/false
          install udf /bin/false

    - path: /etc/ssh/sshd_config.d/10-hardening.conf
      mode: 0600
      contents:
        inline: |
          PermitRootLogin no
          PasswordAuthentication no
          AuthenticationMethods publickey
          AllowTcpForwarding no
          X11Forwarding no
          MaxAuthTries 3

  directories:
    - path: /var/lib/node-baseline
      mode: 0700

systemd:
  units:
    # Flatcar auto-updates: keep them, but coordinate reboots through Kured so
    # nodes drain first. Uncomment the mask only if an external controller
    # (e.g. FluxCD + node image bump) owns the lifecycle instead.
    - name: locksmithd.service
      mask: false
      enabled: true
      dropins:
        - name: 10-reboot-strategy.conf
          contents: |
            [Service]
            Environment=REBOOT_STRATEGY=off

    - name: kubelet.service
      enabled: true
      contents: |
        [Unit]
        Description=kubelet
        After=containerd.service
        Requires=containerd.service

        [Service]
        ExecStart=/opt/bin/kubelet --config=/var/lib/kubelet/config.yaml \
          --kubeconfig=/etc/kubernetes/kubelet.conf \
          --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
          --container-runtime-endpoint=unix:///run/containerd/containerd.sock
        Restart=always
        RestartSec=5
        ProtectHome=read-only
        OOMScoreAdjust=-999

        [Install]
        WantedBy=multi-user.target
```

```bash
$ butane --strict --files-dir . node.bu -o node.ign
$ ignition-validate node.ign && echo "ignition ok"
ignition ok
```

### 11.3 Bottlerocket (TOML user data)

```toml
[settings.kubernetes]
cluster-name = "prod-eu-1"
api-server = "https://api.prod-eu-1.internal:6443"
cluster-dns-ip = "10.96.0.10"
cluster-certificate = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t..."
authentication-mode = "tls"
seccomp-default = true                       # RuntimeDefault for every pod
allowed-unsafe-sysctls = []
pod-pids-limit = 4096
server-tls-bootstrap = true

[settings.kubernetes.node-labels]
"node.kubernetes.io/instance-type" = "m6i.4xlarge"

[settings.kernel]
lockdown = "integrity"                       # "confidentiality" breaks eBPF tooling

[settings.kernel.sysctl]
"kernel.dmesg_restrict"           = "1"
"kernel.kptr_restrict"            = "2"
"kernel.unprivileged_bpf_disabled" = "1"
"net.core.bpf_jit_harden"         = "2"
"user.max_user_namespaces"        = "16384"  # keep pod userns available
"fs.inotify.max_user_watches"     = "524288"

# The admin container is a full shell on the host. Off by default; keep it off.
[settings.host-containers.admin]
enabled = false

# The control container exposes only the Bottlerocket API over SSM.
[settings.host-containers.control]
enabled = true

[settings.oci-defaults.capabilities]
sys-module = false
net-admin  = false
```

### 11.4 Talos (machine config)

```yaml
version: v1alpha1
debug: false
persist: true
machine:
  type: worker
  token: 9dh1q2.9k4hs8dj3ks92kd7
  ca:
    crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...
  certSANs: []

  kubelet:
    image: ghcr.io/siderolabs/kubelet:v1.34.0
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true          # no static pods on workers
    extraConfig:
      readOnlyPort: 0
      protectKernelDefaults: true
      streamingConnectionIdleTimeout: 5m
      podPidsLimit: 4096
      serverTLSBootstrap: true

  install:
    disk: /dev/nvme0n1
    image: ghcr.io/siderolabs/installer:v1.11.0
    wipe: false
    extraKernelArgs:
      - lockdown=integrity
      - init_on_alloc=1
      - init_on_free=1
      - slab_nomerge
      - randomize_kstack_offset=on
      - vsyscall=none

  sysctls:
    kernel.dmesg_restrict: "1"
    kernel.kptr_restrict: "2"
    kernel.unprivileged_bpf_disabled: "1"
    net.core.bpf_jit_harden: "2"

  features:
    rbac: true
    stableHostname: true
    apidCheckExtKeyUsage: true
    kubePrism:
      enabled: true
      port: 7445

  # Talos has no shell, no SSH and no package manager. There is nothing to
  # minimize — the footprint is the design. Administration is talosctl only.
  network:
    interfaces:
      - interface: eth0
        dhcp: true
```

---

## 12. Verification and failure diagnosis

### 12.1 Automated node benchmarking with `kube-bench`

```yaml
# kube-bench-node.yaml — runs the CIS section-4 (worker node) checks on every node
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-node
  namespace: security
spec:
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      restartPolicy: Never
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.11.2
          args: ["run", "--targets", "node", "--benchmark", "cis-1.11"]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsUser: 0
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: usr-bin
              mountPath: /usr/local/mount-from-host/bin
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath: { path: /var/lib/kubelet }
        - name: etc-systemd
          hostPath: { path: /etc/systemd }
        - name: etc-kubernetes
          hostPath: { path: /etc/kubernetes }
        - name: usr-bin
          hostPath: { path: /usr/bin }
```

```bash
$ kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
namespace/security created
$ kubectl apply -f kube-bench-node.yaml
job.batch/kube-bench-node created

$ kubectl -n security wait --for=condition=complete job/kube-bench-node --timeout=120s
job.batch/kube-bench-node condition met

$ kubectl -n security logs job/kube-bench-node | sed -n '1,40p'
[INFO] 4 Worker Node Security Configuration
[INFO] 4.1 Worker Node Configuration Files
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive
[PASS] 4.1.2 Ensure that the kubelet service file ownership is set to root:root
[PASS] 4.1.3 If proxy kubeconfig file exists ensure permissions are set to 600 or more restrictive
[PASS] 4.1.4 If proxy kubeconfig file exists ensure ownership is set to root:root
[PASS] 4.1.5 Ensure that the --kubeconfig kubelet.conf file permissions are set to 600 or more restrictive
[PASS] 4.1.6 Ensure that the --kubeconfig kubelet.conf file ownership is set to root:root
[PASS] 4.1.7 Ensure that the certificate authorities file permissions are set to 600 or more restrictive
[PASS] 4.1.8 Ensure that the client certificate authorities file ownership is set to root:root
[PASS] 4.1.9 If the kubelet config.yaml configuration file is being used validate permissions set to 600
[PASS] 4.1.10 If the kubelet config.yaml configuration file is being used validate file ownership set to root:root
[INFO] 4.2 Kubelet
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate
[PASS] 4.2.4 Verify that the --read-only-port argument is set to 0
[PASS] 4.2.5 Ensure that the --streaming-connection-idle-timeout argument is not set to 0
[PASS] 4.2.6 Ensure that the --make-iptables-util-chains argument is set to true
[PASS] 4.2.7 Ensure that the --hostname-override argument is not set
[WARN] 4.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture
[PASS] 4.2.9 Ensure that the --tls-cert-file and --tls-private-key-file arguments are set as appropriate
[PASS] 4.2.10 Ensure that the --rotate-certificates argument is not set to false
[PASS] 4.2.11 Verify that the RotateKubeletServerCertificate argument is set to true
[PASS] 4.2.12 Ensure that the Kubelet only makes use of Strong Cryptographic Ciphers
[PASS] 4.2.13 Ensure that a limit is set on pod PIDs

== Summary node ==
23 checks PASS
0 checks FAIL
1 checks WARN
0 checks INFO
```

### 12.2 Host-level benchmarking

```bash
$ sudo lynis audit system --quick --quiet 2>&1 | tail -22
  Hardening
  ------------------------------------
  - Installed compiler(s)                                     [ NOT FOUND ]
  - Installed malware scanner                                 [ NOT FOUND ]
  - Non-native binary formats                                 [ NOT FOUND ]

  Lynis security scan details:

  Hardening index : 78 [###############     ]
  Tests performed : 254
  Plugins enabled : 0

  Components:
  - Firewall               [V]
  - Malware scanner        [X]

  Suggestions (7):
  ----------------------------
  - Consider hardening system services [BOOT-5264]
  - Install a file integrity tool to monitor changes [FINT-4350]
  - Harden compilers like restricting access to root user only [HRDN-7222]
  ...

# Compare a node against its own build-time baseline — this is the drift check
# that actually catches an intruder, not the benchmark score.
$ diff <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%04m %p\n' 2>/dev/null | sort) \
       /var/lib/node-baseline/suid.txt
> 4755 /usr/bin/sudo
< 4755 /usr/bin/sudo
< 4755 /tmp/.cache/systemd-helper        # <-- investigate immediately
```

### 12.3 Debugging without reinstalling tools on the node

The reflex "let me `apt install tcpdump` on the node" undoes the work. Use an ephemeral debug container in the host's namespaces instead — the tools live in an image, are removed when the process exits, and leave an audit trail:

```bash
$ kubectl debug node/worker-03 -it --image=nicolaka/netshoot:v0.13 --profile=sysadmin -- bash
Creating debugging pod node-debugger-worker-03-6xk2p with container debugger on node worker-03.
If you don't see a command prompt, try pressing enter.

worker-03:~# nsenter -t 1 -n -- ss -tulpn | head -5
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN 0      4096   127.0.0.1:10248    0.0.0.0:*
tcp   LISTEN 0      4096   0.0.0.0:10250      0.0.0.0:*

worker-03:~# exit
$ kubectl delete pod node-debugger-worker-03-6xk2p
pod "node-debugger-worker-03-6xk2p" deleted
```

### 12.4 Failure catalogue

Every entry below is a real consequence of one of the changes in this document.

| Symptom | Diagnostic | Root cause | Fix |
|---|---|---|---|
| kubelet fails at startup: `Failed to start ContainerManager invalid kernel flag: vm/overcommit_memory, expected value: 1, actual value: 0` | `journalctl -u kubelet -p err -n 30`; `sysctl vm.overcommit_memory` | `protectKernelDefaults: true` with sysctls not matching kubelet's expectations | Set `vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`, `kernel.panic_on_oops=1`, `kernel.keys.root_maxkeys=1000000`, `kernel.keys.root_maxbytes=25000000` in `/etc/sysctl.d/`, then `sysctl --system` |
| kubelet: `running with swap on is not supported, please disable swap` | `swapon --show` | `failSwapOn: true` (default) with swap active | `swapoff -a` + comment the `fstab` entry |
| All pods stuck `ContainerCreating`; containerd log: `skip plugin "io.containerd.snapshotter.v1.overlayfs"` | `journalctl -u containerd -n 50`; `lsmod \| grep overlay` | `overlay` module blacklisted or unavailable | Remove from blacklist, `modprobe overlay`, add to `/etc/modules-load.d/` |
| Pods can reach pods, but never Service ClusterIPs on the same node | `sysctl net.bridge.bridge-nf-call-iptables` → `cannot stat` | `br_netfilter` not loaded/blacklisted | `modprobe br_netfilter` + `/etc/modules-load.d/kubernetes.conf` + re-apply sysctl |
| kube-proxy CrashLoopBackOff: `can't use the IPVS proxier ... required kernel modules are not loaded` | `kubectl -n kube-system logs ds/kube-proxy` | `ip_vs*` blacklisted or absent | Load `ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack` |
| Every container exits instantly: `exec /usr/local/bin/app: permission denied` | `findmnt -no OPTIONS /var` shows `noexec` | `noexec` applied to `/var` (or `/var/lib/containerd`) | Remount without `noexec`; fix `fstab`. **Never** `noexec` on `/var` |
| Inside containers: `sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option set?` | `findmnt -no OPTIONS /var` | `nosuid` on the snapshotter backing store | Same as above — drop `nosuid` from `/var` |
| Services intermittently break, self-heal ~30 s later | `nft list tables` shows `ip kube-proxy` missing right after the firewall runs | The firewall script used `flush ruleset`, wiping kube-proxy's nftables tables | Remove `flush ruleset`; use `table X` + `delete table X` + redefine |
| NodePort unreachable from the LB; pod-to-pod fine | `nft list counters table inet k8s_host`; `nft monitor trace` | Input chain policy `drop` without a NodePort accept, or `forward` chain set to `drop` | Add the `30000-32767` rule; set `forward` policy `accept` |
| Cluster DNS times out after applying "hardening" sysctls | `sysctl net.ipv4.conf.all.rp_filter`; `dmesg \| grep martian` | Strict reverse-path filtering (`rp_filter=1`) breaks the CNI's asymmetric return path | Use `0` or loose `2` per the CNI's documentation |
| kube-proxy: `iptables-restore: line 12 failed`, no new Services programmed | `dmesg \| grep 'Operation not permitted'`; `sysctl kernel.modules_disabled` | `kernel.modules_disabled=1` set before kube-proxy autoloaded an `xt_*` module | Reboot; preload all needed modules via `/etc/modules-load.d/` and only seal after the verification script passes |
| Falco/Cilium/Tetragon: `bpf: Operation not permitted`, probe fails to load | `cat /sys/kernel/security/lockdown` shows `[confidentiality]` | Lockdown confidentiality blocks kernel-memory reads used by eBPF probes | Downgrade to `lockdown=integrity`, or accept losing the runtime sensor |
| Node reboots and never comes back; console shows `mount: unknown filesystem type 'squashfs'` | Serial console | `squashfs` blacklisted while `snapd` mounts snaps at boot | Do not `install squashfs /bin/false` on Ubuntu with snaps; remove snapd instead |
| Cloud agent (SSM/guest-agent) stops reporting after minimization | `systemctl status amazon-ssm-agent` → `Unit not found` | The agent shipped as a snap and was removed with `snapd` | Reinstall the agent as a `.deb`/`.rpm`, or keep `snapd` for that fleet |
| Locked out of all nodes after an SSH or firewall change | — | No rollback armed | Always `systemd-run --on-active=5min` a revert before applying; validate from a *second* session before cancelling |
| Volume attach hangs, pod `ContainerCreating` for minutes | `kubectl describe pod`; `dmesg \| grep -i iscsi`; `journalctl -u kubelet \| grep -i mount` | A storage module (`iscsi_tcp`, `rbd`, `nfsv4`, `dm_*`) was blacklisted or `modules_disabled=1` | Whitelist and preload the CSI driver's module set |

### 12.5 A single verification script

```bash
#!/usr/bin/env bash
# /usr/local/sbin/node-hardening-check.sh
# Non-destructive posture check. Exit 0 = all assertions hold.
set -uo pipefail
fail=0

check() {  # check <description> <command...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '[ PASS ] %s\n' "$desc"
    else
        printf '[ FAIL ] %s\n' "$desc"; fail=1
    fi
}

echo "== network surface =="
check "kubelet read-only port 10255 closed" \
    bash -c '! ss -tlnH | grep -q ":10255 "'
check "no unexpected 0.0.0.0 listeners" \
    bash -c '! ss -tlnH | awk "{print \$4}" | grep -E "^0\.0\.0\.0:" | grep -vE ":(10250|10256|22)$" | grep -q .'
check "nftables k8s_host table present" \
    nft list table inet k8s_host
check "kube-proxy nftables/iptables tables intact" \
    bash -c 'nft list tables | grep -qE "kube-proxy|^table ip filter"'

echo "== kernel surface =="
check "dmesg restricted"          bash -c '[ "$(sysctl -n kernel.dmesg_restrict)" = 1 ]'
check "kptr restricted"           bash -c '[ "$(sysctl -n kernel.kptr_restrict)" = 2 ]'
check "kexec disabled"            bash -c '[ "$(sysctl -n kernel.kexec_load_disabled)" = 1 ]'
check "core_pattern is not a pipe" bash -c '! grep -q "^|" /proc/sys/kernel/core_pattern || [ "$(cat /proc/sys/kernel/core_pattern)" = "|/bin/false" ]'
check "tipc autoload blocked"     bash -c 'modprobe -n -v tipc 2>&1 | grep -q "/bin/false"'
check "dccp autoload blocked"     bash -c 'modprobe -n -v dccp 2>&1 | grep -q "/bin/false"'
check "ip_forward enabled (k8s requirement)" bash -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
check "br_netfilter loaded"       bash -c 'lsmod | grep -q "^br_netfilter"'
check "overlay loaded"            bash -c 'lsmod | grep -q "^overlay"'

echo "== local privesc surface =="
check "pkexec absent"             bash -c '[ ! -e /usr/bin/pkexec ]'
check "no compiler on node"       bash -c '! command -v gcc && ! command -v cc'
check "SUID count <= 8"           bash -c '[ "$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | wc -l)" -le 8 ]'
check "SUID set matches baseline" bash -c 'diff -q <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf "%04m %p\n" 2>/dev/null | sort) /var/lib/node-baseline/suid.txt'
check "root password locked"      bash -c 'awk -F: "\$1==\"root\"{print \$2}" /etc/shadow | grep -q "^[!*]"'
check "no NOPASSWD sudo rules"    bash -c '! grep -rq NOPASSWD /etc/sudoers /etc/sudoers.d/'
check "no empty passwords"        bash -c '! awk -F: "(\$2==\"\")" /etc/shadow | grep -q .'
check "no docker group"           bash -c '! getent group docker'

echo "== filesystem =="
check "/tmp nodev,nosuid,noexec"  bash -c 'findmnt -no OPTIONS /tmp | grep -q nodev && findmnt -no OPTIONS /tmp | grep -q nosuid && findmnt -no OPTIONS /tmp | grep -q noexec'
check "/var IS exec (containers need it)" bash -c '! findmnt -no OPTIONS /var | grep -q noexec'
check "swap off"                  bash -c '[ -z "$(swapon --show --noheadings)" ]'

echo "== kubernetes files =="
check "kubelet config 600"        bash -c '[ "$(stat -c %a /var/lib/kubelet/config.yaml)" = 600 ]'
check "kubelet.conf 600"          bash -c '[ "$(stat -c %a /etc/kubernetes/kubelet.conf)" = 600 ]'
check "no admin.conf on worker"   bash -c '[ ! -e /etc/kubernetes/admin.conf ] || [ -d /etc/kubernetes/manifests ]'
check "containerd config 600"     bash -c '[ "$(stat -c %a /etc/containerd/config.toml)" = 600 ]'
check "kubelet anonymous auth off" bash -c 'grep -A2 "^authentication:" /var/lib/kubelet/config.yaml | grep -A1 anonymous | grep -q "enabled: false"'
check "kubelet authz webhook"     bash -c 'grep -A1 "^authorization:" /var/lib/kubelet/config.yaml | grep -q "mode: Webhook"'
check "seccompDefault on"         bash -c 'grep -q "seccompDefault: true" /var/lib/kubelet/config.yaml'

echo
[ $fail -eq 0 ] && echo "RESULT: node hardening baseline OK" || echo "RESULT: FAILURES PRESENT"
exit $fail
```

```bash
$ sudo /usr/local/sbin/node-hardening-check.sh
== network surface ==
[ PASS ] kubelet read-only port 10255 closed
[ PASS ] no unexpected 0.0.0.0 listeners
[ PASS ] nftables k8s_host table present
[ PASS ] kube-proxy nftables/iptables tables intact
== kernel surface ==
[ PASS ] dmesg restricted
[ PASS ] kptr restricted
[ PASS ] kexec disabled
[ PASS ] core_pattern is not a pipe
[ PASS ] tipc autoload blocked
[ PASS ] dccp autoload blocked
[ PASS ] ip_forward enabled (k8s requirement)
[ PASS ] br_netfilter loaded
[ PASS ] overlay loaded
== local privesc surface ==
[ PASS ] pkexec absent
[ PASS ] no compiler on node
[ PASS ] SUID count <= 8
[ PASS ] SUID set matches baseline
[ PASS ] root password locked
[ PASS ] no NOPASSWD sudo rules
[ PASS ] no empty passwords
[ PASS ] no docker group
== filesystem ==
[ PASS ] /tmp nodev,nosuid,noexec
[ PASS ] /var IS exec (containers need it)
[ PASS ] swap off
== kubernetes files ==
[ PASS ] kubelet config 600
[ PASS ] kubelet.conf 600
[ PASS ] no admin.conf on worker
[ PASS ] containerd config 600
[ PASS ] kubelet anonymous auth off
[ PASS ] kubelet authz webhook
[ PASS ] seccompDefault on

RESULT: node hardening baseline OK
```

---

## 13. Rollout strategy

Node hardening is a *fleet* change with cluster-wide blast radius. Treat it like a schema migration:

1. **Baseline every node** and commit the artifacts (`suid.txt`, `listen.txt`, `packages.txt`) to the infra repo.
2. **Change the image, not the node.** Every item in §4–§11 belongs in the Packer/`image-builder` template. Runtime configuration management is the fallback for brownfield, not the design.
3. **Canary one node per failure domain**, cordoned, running a synthetic workload that exercises exec, volumes, DNS, NodePort and image pull.
4. **Bake for a full business cycle** — 24 h minimum. Module blacklists break on the *first CSI attach* or the *first new Service type*, which may be hours after boot.
5. **Roll by node group**, with `PodDisruptionBudget`s honoured and an automated rollback to the previous AMI/image on a Ready-condition regression.
6. **Enforce continuously.** `kube-bench` as a `CronJob`, the §12.5 script as a node-exporter textfile collector, and an alert on any diff against `/var/lib/node-baseline/`.

### CKS exam notes

Under time pressure, the highest-yield actions on a node task are, in order:

1. `grep -E 'readOnlyPort|anonymous|authorization|protectKernelDefaults|seccompDefault' /var/lib/kubelet/config.yaml` — most node questions are here.
2. `systemctl list-units --type=service --state=running` → `systemctl mask --now <service>` for anything obviously unnecessary. **Use `mask`, not `disable`** — graders check that it cannot restart.
3. `ss -tulpn` → close what should not listen.
4. `find / -xdev -perm -4000 -type f` → `chmod u-s` the obviously unnecessary ones.
5. `systemctl restart kubelet && systemctl is-active kubelet` — **always verify the node comes back Ready**; a hardened node that does not run pods scores zero.

---

## References

- CNCF — *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes — *Ports and Protocols*: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubernetes — *Kubelet Configuration (v1beta1) reference*: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes — *Set Kubelet Parameters Via A Configuration File*: https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- Kubernetes — *Securing a Cluster*: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubernetes — *Kubelet authentication/authorization*: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes — *Using Node Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Kubernetes — *Swap memory management on nodes*: https://kubernetes.io/docs/concepts/architecture/nodes/#swap-memory
- Kubernetes — *User Namespaces*: https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/
- Kubernetes — *Restrict a Container's Syscalls with seccomp*: https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes — *Debugging with an ephemeral debug container / `kubectl debug node`*: https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- CIS — *Kubernetes Benchmark*: https://www.cisecurity.org/benchmark/kubernetes
- Aqua Security — *kube-bench*: https://github.com/aquasecurity/kube-bench
- Kubernetes SIGs — *image-builder*: https://github.com/kubernetes-sigs/image-builder
- systemd — *`systemd-analyze security`*: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- systemd — *`systemd.exec` sandboxing directives*: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — *`modules-load.d`*: https://www.freedesktop.org/software/systemd/man/latest/modules-load.d.html
- Linux kernel — *`kernel_lockdown(7)`*: https://man7.org/linux/man-pages/man7/kernel_lockdown.7.html
- Linux kernel — *sysctl `/proc/sys/kernel` documentation*: https://docs.kernel.org/admin-guide/sysctl/kernel.html
- Linux kernel — *sysctl `/proc/sys/net` documentation*: https://docs.kernel.org/admin-guide/sysctl/net.html
- Linux kernel — *Yama LSM (`ptrace_scope`)*: https://docs.kernel.org/admin-guide/LSM/Yama.html
- `modprobe.d(5)` manual page: https://man7.org/linux/man-pages/man5/modprobe.d.5.html
- netfilter — *nftables wiki*: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- OpenSSH — *`sshd_config(5)`*: https://man.openbsd.org/sshd_config
- CISOfy — *Lynis*: https://cisofy.com/lynis/
- OpenSCAP — *ComplianceAsCode security guides*: https://github.com/ComplianceAsCode/content
- Flatcar Container Linux — *Documentation*: https://www.flatcar.org/docs/latest/
- Butane / Ignition — *Configuration specification*: https://coreos.github.io/butane/specs/
- Bottlerocket OS — *Settings reference*: https://bottlerocket.dev/en/os/latest/#/api/settings/
- Bottlerocket OS — *Security features*: https://github.com/bottlerocket-os/bottlerocket/blob/develop/SECURITY_FEATURES.md
- Talos Linux — *Documentation*: https://www.talos.dev/latest/
- Talos Linux — *Machine configuration reference*: https://www.talos.dev/latest/reference/configuration/
- containerd — *CRI plugin configuration*: https://github.com/containerd/containerd/blob/main/docs/cri/config.md
- NIST — *SP 800-190, Application Container Security Guide*: https://csrc.nist.gov/pubs/sp/800/190/final
- CVE-2021-4034 (`pkexec` local root, "PwnKit"): https://nvd.nist.gov/vuln/detail/CVE-2021-4034
- CVE-2021-43267 (TIPC remote heap overflow): https://nvd.nist.gov/vuln/detail/CVE-2021-43267
- CVE-2019-18683 (`vivid` driver local root): https://nvd.nist.gov/vuln/detail/CVE-2019-18683