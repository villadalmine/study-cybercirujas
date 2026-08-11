# 352.2 — System Containers with LXC and LXD

> **Exam:** LPIC-3 305-300 (v3.0) · **Objective 352.2** · **Weight 10**
> **Scope:** Architecture of LXC and LXD; managing image-based containers with LXD (networking + storage); CPU/memory/storage limits; security features including nesting. Version covered: LXC/LXD **3.0 or later**.

---

## 1. Motivation and the production architecture problem

There are two fundamentally different things the industry calls a "container", and conflating them is the root cause of most bad architecture decisions in this space.

- **Application containers** (Docker/OCI) run *a single process tree around one payload*. The contract is "one image, one entrypoint, ephemeral, immutable, orchestrated." State is externalized. The container *is* the process.
- **System containers** (LXC/LXD) run *a full init system and a userspace that looks like a machine*: `systemd` as PID 1, `sshd`, `cron`, multiple services, package managers, persistent filesystems, syslog. The container behaves like a lightweight, long-lived VM — but shares the host kernel, so there is no hypervisor tax, no guest kernel to patch, and boot time is measured in hundreds of milliseconds.

The production problem LXC/LXD solves is the **"I need a machine, not a process" workload at VM density that KVM can't reach**:

- Multi-tenant build/CI runners where each tenant needs `apt`, mounts, a real `/etc`, and their own daemons.
- Legacy or stateful services (LDAP directories, mail stacks, monitoring appliances, university lab environments) that assume they own an OS and cannot be refactored into 12-factor apps.
- Dense hosting: 200–400 system containers on a host where the same box tops out around 30–40 KVM guests, because you are not paying for N guest kernels, N page-cache copies, and N sets of emulated devices.
- **Live-migratable, snapshottable, network-modelled "instances"** with a declarative API — the operational ergonomics of a cloud (`lxc launch`, profiles, projects, clustering, REST) without a hypervisor.

The architectural trap is using system containers as though they were VMs with a *security* boundary equivalent to KVM. They are not: a shared kernel means the kernel's attack surface is the tenant boundary. The entire security discipline of this objective — **unprivileged containers, user-namespace idmaps, AppArmor, seccomp, and controlled nesting** — exists to make that shared-kernel boundary defensible. Treating it as a strong boundary without those controls is the #1 production incident source here.

```
                     Density  ↑
   ┌───────────────────────────────────────────────┐
   │  LXC/LXD system containers                     │  shared kernel,
   │  (full OS userspace, init, multi-service)      │  ~ms boot, high density
   ├───────────────────────────────────────────────┤
   │  Docker/OCI application containers             │  shared kernel,
   │  (single process, immutable, ephemeral)        │  one payload
   ├───────────────────────────────────────────────┤
   │  KVM / QEMU virtual machines                   │  guest kernel,
   │  (hardware-level isolation, own kernel)        │  strong boundary, heavier
   └───────────────────────────────────────────────┘
                   Isolation strength  ↑
```

---

## 2. Architecture of LXC and LXD

### 2.1 The two layers

LXC is a **layered** system, and the exam expects you to distinguish the layers precisely — including the fact that the LXD client is *also* called `lxc`, which is a notorious source of confusion.

| Layer | Component | Role |
|---|---|---|
| Kernel | namespaces, cgroups, capabilities, seccomp, LSM (AppArmor/SELinux) | The actual isolation primitives. LXC/LXD *configure* these; they do not implement them. |
| Low-level userspace | **liblxc** + `lxc-*` tools | The container runtime. Creates namespaces, applies the config, spawns the container's init. Imperative, per-container config files. |
| High-level control plane | **LXD** (`lxd` daemon + `lxc` client) | A privileged daemon exposing a **REST API** over a Unix socket (and optionally HTTPS). Manages images, storage pools, networks, profiles, projects, snapshots, remotes, clustering, and live migration. Uses liblxc underneath. |

```
  Operator / automation
        │  (CLI, Terraform, Ansible)
        ▼
  ┌─────────────┐   HTTPS / REST (client cert auth)   ┌───────────────┐
  │ lxc client  │◀──────────────────────────────────▶│  Remote image │
  │ (LXD CLI)   │                                     │  servers      │
  └─────┬───────┘                                     └───────────────┘
        │ Unix socket /var/snap/lxd/common/lxd/unix.socket
        ▼
  ┌────────────────────────────────────────────────────────────────┐
  │                         lxd  (daemon)                           │
  │  REST API · auth (TLS/PKI/OIDC) · scheduler · DB (dqlite/Raft)  │
  │  ┌──────────┐ ┌───────────┐ ┌──────────┐ ┌───────────────────┐ │
  │  │ Images   │ │ Storage   │ │ Networks │ │ Profiles/Projects │ │
  │  └──────────┘ └────┬──────┘ └────┬─────┘ └───────────────────┘ │
  └────────────────────┼─────────────┼─────────────────────────────┘
                       │             │
                  ┌────▼────┐   ┌────▼────┐
                  │ liblxc  │   │ bridge/ │
                  │ (runtime)│   │ OVN/... │
                  └────┬─────┘   └─────────┘
                       ▼
        namespaces · cgroup v2 · seccomp · AppArmor · capabilities
                       ▼
                 host Linux kernel (shared)
```

**Key architectural facts for the exam:**

- LXD is a **daemon with a REST API**; the CLI is a thin client. Anything the CLI does, an HTTP call can do — this is why LXD integrates cleanly with Terraform/Ansible and clusters.
- LXD stores its state in an embedded **dqlite** database (Raft-replicated in a cluster). There is no external DB.
- **Remotes**: LXD talks to image servers and to other LXD daemons uniformly. `images:` is the LinuxContainers community image server; `ubuntu:` is Canonical's cloud-image server; `local:` is the default local daemon.
- **Clustering**: multiple LXD daemons form a single distributed control plane sharing one database and API; instances are scheduled across members and can live-migrate between them.

> **Production note (fork landscape).** LXD is maintained by Canonical. In 2023 the LinuxContainers project forked LXD into **Incus**, which is now the community-governed continuation (`incus` CLI, `incus-admin` socket). `liblxc` and the `lxc-*` tools remain under LinuxContainers. The 305-300 v3.0 objective is written around **LXC/LXD 3.0+**, so this study material uses LXD terminology; on modern community distros you will frequently see `incus` where this text shows `lxc`. The command surface is nearly identical (`incus launch images:...`), which is deliberate.

### 2.2 The kernel primitives, concretely

LXC/LXD is "just" a curated composition of kernel features:

- **Namespaces** (`man 7 namespaces`): `pid`, `net`, `mnt`, `uts`, `ipc`, `user`, `cgroup`, `time`. The **user namespace** is what makes *unprivileged* containers possible: container-root (uid 0) maps to an unprivileged host uid (e.g. 100000).
- **cgroup v2**: hierarchical resource accounting and limits (CPU, memory, io, pids). LXD writes to the unified hierarchy under `/sys/fs/cgroup/`.
- **Capabilities**: fine-grained slices of root. Unprivileged containers drop dangerous ones and, via user-ns mapping, hold capabilities that are only valid *inside* the container's namespace.
- **seccomp**: syscall filtering. LXD ships a default profile that blocks/virtualizes dangerous syscalls (e.g. it intercepts some to make containers safer without breaking them).
- **LSM — AppArmor** (Ubuntu/Debian) or **SELinux**: mandatory access control confining each container to its own profile.

### 2.3 Privileged vs unprivileged (the central security concept)

| | **Unprivileged (default, recommended)** | **Privileged** |
|---|---|---|
| Container `root` (uid 0) maps to | An unprivileged **host** uid (e.g. 100000) via user namespace | Real host **uid 0** |
| Kernel view of a container breakout | Attacker lands as an unprivileged host user | Attacker lands as host **root** |
| Config key | (default) or `security.privileged: false` | `security.privileged: true` |
| Requires | `/etc/subuid` + `/etc/subgid` idmap ranges | — |
| Use when | Almost always | Only when a workload genuinely needs real-root semantics on host resources and you accept the risk |

The idmap is declared in `/etc/subuid` / `/etc/subgid`. LXD's own map (for its root-owned daemon) is typically:

```
$ cat /etc/subuid
lxd:1000000:1000000000
root:1000000:1000000000
$ cat /etc/subgid
lxd:1000000:1000000000
root:1000000:1000000000
```

Every unprivileged container then gets a sub-range out of that pool, so a file owned by `root` inside the container is owned by `1000000` on the host filesystem.

---

## 3. Technical comparisons and trade-off tables

### 3.1 Runtimes

| Dimension | **liblxc / `lxc-*`** | **LXD (`lxc` client)** | **Docker/OCI** | **KVM (libvirt)** |
|---|---|---|---|---|
| Container model | System (full init) | System (full init) | Application (1 process) | Full VM |
| Kernel | Shared | Shared | Shared | Own guest kernel |
| Control plane | None (config files) | REST API + daemon + DB | REST API + daemon | libvirtd + REST/RPC |
| Image ecosystem | `download` template | Image servers + publish/export | Registries (OCI) | Cloud images / ISOs |
| Storage abstraction | Manual (fstab/mounts) | **Storage pools** (zfs/btrfs/lvm/ceph/dir) | Volumes/overlay2 | Disk images (qcow2/LVM/RBD) |
| Networking abstraction | Manual | **Managed networks** (bridge/OVN/macvlan) | CNI/bridge | Managed bridges/OVN |
| Live migration | Limited (CRIU) | Yes (CRIU / stateful) | No (by design) | Yes |
| Clustering built-in | No | **Yes (dqlite/Raft)** | Needs Swarm/K8s | Needs oVirt/OpenStack |
| Best for | Embedding, minimal footprint, learning the primitives | Fleet of VM-like instances with cloud ergonomics | Immutable app delivery | Hard multi-tenant isolation |

**Rule of thumb:** use **liblxc** when you want the primitive and control everything yourself (or embed it); use **LXD** for a managed fleet; reach for **KVM** when the tenant boundary must survive a kernel bug.

### 3.2 LXD storage backends

| Driver | Snapshots | Copy-on-write clones | Quotas (root `size=`) | Notes / when to use |
|---|---|---|---|---|
| `dir` | No (full copy) | No | No | Simplest, portable, slow; dev/test only |
| `btrfs` | Yes | Yes (reflink) | Yes | Good default on a single disk; subvolume per instance |
| **`zfs`** | Yes | Yes | Yes | **Production default**: fast CoW clones, ARC cache, `send/recv` for migration, compression |
| `lvm` | Yes (thin) | Yes (thin) | Yes | Block-level; pairs well with existing LVM/thinpools |
| `ceph` (RBD) | Yes | Yes | Yes | Distributed/HA storage for clusters; shared backing across members |
| `cephfs` / `cephobject` | — | — | — | For custom storage volumes / object, not instance root |

### 3.3 LXD network modes

| Type | Isolation | Reachable from LAN directly | Typical use |
|---|---|---|---|
| `bridge` (`lxdbr0`) | NAT'd private subnet + DNS (dnsmasq) | No (SNAT/DNAT) | Default; self-contained host |
| `macvlan` NIC | Container gets a MAC on the physical LAN | Yes | Containers as first-class LAN hosts |
| `bridged` NIC to existing host bridge (`br0`) | L2 on host bridge | Yes | Integrate with host's own bridge/VLANs |
| `ovn` | Overlay (Geneve), virtual routers, ACLs | Via uplink | Multi-tenant, cluster-wide SDN with security groups |
| `sriov` NIC | Hardware VF | Yes | Low-latency/high-throughput NFV |
| `physical` / `ipvlan` | Direct/parent-based | Yes | Special-purpose |

---

## 4. Complete manifests and infrastructure (unabridged)

### 4.1 LXD non-interactive bootstrap (`lxd init --preseed`)

Feed this on stdin to initialize a host declaratively — the production alternative to the interactive wizard. This creates a ZFS pool, a NAT bridge, exposes the HTTPS API, and defines the `default` profile.

```yaml
# lxd-preseed.yaml — apply with:  cat lxd-preseed.yaml | lxd init --preseed
config:
  core.https_address: '[::]:8443'      # expose REST API on all interfaces, port 8443
  images.auto_update_interval: "6"      # hours between image auto-updates
networks:
  - name: lxdbr0
    type: bridge
    config:
      ipv4.address: 10.152.1.1/24
      ipv4.nat: "true"
      ipv4.dhcp: "true"
      ipv6.address: none                # keep it simple; disable IPv6 on this bridge
      dns.domain: lab.internal
storage_pools:
  - name: default
    driver: zfs
    config:
      source: tank/lxd                  # use an existing ZFS dataset; omit for a loop file
profiles:
  - name: default
    description: Default LXD profile (root on ZFS, NIC on lxdbr0)
    devices:
      root:
        path: /
        pool: default
        type: disk
      eth0:
        name: eth0
        network: lxdbr0
        type: nic
# 'projects' and 'cluster' keys can also appear here for multi-tenant / clustered bootstraps.
```

### 4.2 A hardened, resource-capped profile

Profiles are the declarative unit LXD applies to instances (an instance can stack several). This one enforces limits, forbids privilege escalation, and confines the container.

```yaml
# apply with:  lxc profile create webtier ; lxc profile edit webtier < webtier.yaml
name: webtier
description: Unprivileged web tier — 2 vCPU, 2 GiB RAM, 10 GiB disk, confined
config:
  limits.cpu: "2"                       # 2 logical CPUs
  limits.cpu.allowance: 50%             # ...but throttled to 50% of that (1 CPU-equivalent)
  limits.memory: 2GiB
  limits.memory.enforce: hard           # OOM-kill inside the container, don't spill to host
  limits.memory.swap: "false"
  limits.processes: "512"               # pids cgroup cap
  security.privileged: "false"          # explicit: unprivileged
  security.nesting: "false"             # no nested containers here
  security.syscalls.intercept.mknod: "false"
  boot.autostart: "true"
  boot.autostart.priority: "10"
  user.team: platform                   # free-form metadata (user.* keys)
devices:
  root:
    path: /
    pool: default
    type: disk
    size: 10GiB                         # per-instance disk quota (needs zfs/btrfs/lvm)
  eth0:
    name: eth0
    network: lxdbr0
    type: nic
```

### 4.3 cloud-init user-data via a profile

LXD images from `images:`/`ubuntu:` support cloud-init. Ship first-boot config declaratively — this is how you provision system containers at scale without golden images.

```yaml
# provisioning profile carrying cloud-init
name: provisioned
description: cloud-init bootstrap (packages, user, nginx)
config:
  user.user-data: |
    #cloud-config
    package_update: true
    packages:
      - nginx
      - htop
    users:
      - name: deploy
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... deploy@bastion
    write_files:
      - path: /var/www/html/index.html
        content: "<h1>Provisioned by cloud-init inside LXD</h1>\n"
    runcmd:
      - systemctl enable --now nginx
devices: {}
```

### 4.4 Low-level liblxc unprivileged container config

When you drop below LXD to raw liblxc, the container is defined by a plain config file. Unprivileged (rootless) containers live under `~/.local/share/lxc/<name>/config`:

```ini
# ~/.local/share/lxc/web1/config  (unprivileged, run as a normal user)
lxc.uts.name = web1

# --- User-namespace idmap: container 0..65535 -> host 100000..165535 ---
lxc.idmap = u 0 100000 65536
lxc.idmap = g 0 100000 65536

# --- Root filesystem ---
lxc.rootfs.path = dir:/home/dev/.local/share/lxc/web1/rootfs

# --- Networking: veth into the host's lxcbr0 ---
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx

# --- Confinement ---
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 0
lxc.seccomp.profile = /usr/share/lxc/config/common.seccomp

# --- Common includes shipped by the distro ---
lxc.include = /usr/share/lxc/config/common.conf
lxc.include = /usr/share/lxc/config/userns.conf

# --- cgroup limits (cgroup v2 keys) ---
lxc.cgroup2.memory.max = 536870912          # 512 MiB
lxc.cgroup2.pids.max = 256
```

The matching `/etc/subuid` / `/etc/subgid` grant for the user `dev` must exist:

```
$ grep dev /etc/subuid /etc/subgid
/etc/subuid:dev:100000:65536
/etc/subgid:dev:100000:65536
```

---

## 5. Real CLI commands and terminal output

### 5.1 Install and initialize LXD

```bash
$ sudo snap install lxd
lxd 5.21/stable installed
$ sudo usermod -aG lxd "$USER"    # log out/in so group membership applies
$ newgrp lxd
$ lxd init --minimal              # quick default: dir pool + lxdbr0 + default profile
```

Verify the daemon and its view of the world:

```bash
$ lxc version
Client version: 5.21
Server version: 5.21
$ lxc info | head -n 12
config:
  core.https_address: '[::]:8443'
api_extensions:
- storage_zfs_remove_snapshots
- container_host_shutdown_timeout
...
environment:
  addresses:
  - 10.152.1.1:8443
  kernel: Linux
  kernel_version: 6.8.0-40-generic
  server: lxd
  server_version: "5.21"
```

### 5.2 Remotes and images

```bash
$ lxc remote list
+-----------------+------------------------------------------+---------------+-------------+--------+--------+
|      NAME       |                   URL                    |   PROTOCOL    |  AUTH TYPE  | PUBLIC | STATIC |
+-----------------+------------------------------------------+---------------+-------------+--------+--------+
| images          | https://images.linuxcontainers.org       | simplestreams | none        | YES    | NO     |
| local (current) | unix://                                  | lxd           | file access | NO     | YES    |
| ubuntu          | https://cloud-images.ubuntu.com/releases | simplestreams | none        | YES    | YES    |
+-----------------+------------------------------------------+---------------+-------------+--------+--------+

$ lxc image list images: ubuntu/22.04 amd64 | head
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
|             ALIAS             | FINGERPRINT  | PUBLIC |          DESCRIPTION           | ARCHITECTURE |   TYPE    |   SIZE   |
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
| ubuntu/22.04 (7 more)         | c9f6f3a4d1e2 | yes    | Ubuntu jammy amd64 (2026...)  | x86_64       | CONTAINER | 118.44MB |
+-------------------------------+--------------+--------+-------------------------------+--------------+-----------+----------+
```

### 5.3 Launch, list, inspect, exec

```bash
$ lxc launch images:ubuntu/22.04 web1
Creating web1
Starting web1

$ lxc list
+------+---------+---------------------+------------------------------------------------+-----------+-----------+
| NAME |  STATE  |         IPV4        |                     IPV6                       |   TYPE    | SNAPSHOTS |
+------+---------+---------------------+------------------------------------------------+-----------+-----------+
| web1 | RUNNING | 10.152.1.113 (eth0) | fd42:...:1:216:3eff:fe8a:1c2d (eth0)           | CONTAINER | 0         |
+------+---------+---------------------+------------------------------------------------+-----------+-----------+

$ lxc info web1 | head -n 14
Name: web1
Status: RUNNING
Type: container
Architecture: x86_64
PID: 24817
Created: 2026/08/11 14:03 UTC
Last Used: 2026/08/11 14:03 UTC
Resources:
  Processes: 21
  CPU usage:
    CPU usage (in seconds): 3
  Memory usage:
    Memory (current): 78.44MiB
  Network usage: ...

$ lxc exec web1 -- bash
root@web1:~# ps -p 1 -o comm=
systemd                       # PID 1 is a full init — this is a *system* container
root@web1:~# exit

$ lxc exec web1 -- systemctl is-system-running
running
```

### 5.4 Files, config, snapshots, images

```bash
$ echo "hello" > note.txt
$ lxc file push note.txt web1/root/note.txt
$ lxc file pull web1/etc/hostname -
web1

$ lxc config set web1 limits.memory 1GiB
$ lxc config device override web1 root size=8GiB     # per-instance disk quota
$ lxc config show web1 | sed -n '1,18p'
architecture: x86_64
config:
  image.description: Ubuntu jammy amd64
  limits.memory: 1GiB
  volatile.eth0.hwaddr: 00:16:3e:8a:1c:2d
devices:
  root:
    path: /
    pool: default
    size: 8GiB
    type: disk
ephemeral: false
profiles:
- default

$ lxc snapshot web1 pre-upgrade
$ lxc info web1 | grep -A3 Snapshots
Snapshots:
  pre-upgrade (taken at 2026/08/11 14:07 UTC) (stateless)

$ lxc restore web1 pre-upgrade            # roll back
$ lxc publish web1/pre-upgrade --alias web-golden
Publishing instance: Instance published with fingerprint: 3b1f...e07a
$ lxc launch web-golden web2              # clone from your own image
```

### 5.5 Applying profiles and resource limits

```bash
$ lxc profile create webtier
$ lxc profile edit webtier < webtier.yaml       # (§4.2)
$ lxc profile add web1 webtier                   # stack it on top of default
$ lxc profile assign web1 default,webtier        # or set the exact ordered list

# Verify limits actually landed in the cgroup:
$ lxc exec web1 -- cat /sys/fs/cgroup/memory.max
1073741824
$ lxc exec web1 -- nproc
2
```

### 5.6 Networking and storage management

```bash
$ lxc network list
+--------+----------+---------+----------------+------+-------------+---------+
|  NAME  |   TYPE   | MANAGED |      IPV4       | ...  | DESCRIPTION | USED BY |
+--------+----------+---------+----------------+------+-------------+---------+
| eth0   | physical | NO      |                |      |             | 0       |
| lxdbr0 | bridge   | YES     | 10.152.1.1/24  |      |             | 2       |
+--------+----------+---------+----------------+------+-------------+---------+

# Give a container a real LAN presence via macvlan (overrides the profile NIC):
$ lxc config device add web1 eth0 nic nictype=macvlan parent=eth0
$ lxc restart web1

$ lxc storage list
+---------+--------+--------------------------------------+-------------+---------+---------+
|  NAME   | DRIVER |               SOURCE                 | DESCRIPTION | USED BY |  STATE  |
+---------+--------+--------------------------------------+-------------+---------+---------+
| default | zfs    | tank/lxd                             |             | 4       | CREATED |
+---------+--------+--------------------------------------+-------------+---------+---------+

$ lxc storage create fast btrfs source=/dev/nvme1n1
$ lxc launch images:alpine/3.20 cache1 --storage fast
```

### 5.7 Nesting (running containers inside containers)

Nesting is explicitly on the exam. It is required to run Docker or a nested LXD/systemd-in-container that itself creates namespaces.

```bash
$ lxc launch images:ubuntu/22.04 ci-runner -c security.nesting=true
Creating ci-runner
Starting ci-runner

$ lxc exec ci-runner -- bash -c '
    apt-get update -qq && apt-get install -y -qq docker.io >/dev/null
    systemctl start docker
    docker run --rm hello-world | grep "Hello from Docker"'
Hello from Docker!
```

Without `security.nesting=true`, the inner runtime cannot create user/mount namespaces and fails. Combine with `security.syscalls.intercept.mknod=true` / `security.syscalls.intercept.mount=*` for specific inner workloads that need device nodes or mounts.

### 5.8 Low-level liblxc lifecycle (no LXD)

```bash
$ lxc-create -n legacy -t download -- -d debian -r bookworm -a amd64
Using image from local cache
Unpacking the rootfs
...
$ lxc-start -n legacy -d
$ lxc-ls -f
NAME   STATE   AUTOSTART GROUPS IPV4        IPV6 UNPRIVILEGED
legacy RUNNING 0         -      10.0.3.42   -    true
$ lxc-info -n legacy
Name:           legacy
State:          RUNNING
PID:            30122
IP:             10.0.3.42
CPU use:        0.44 seconds
Memory use:     22.10 MiB
$ lxc-attach -n legacy -- cat /etc/debian_version
12.6
$ lxc-stop -n legacy && lxc-destroy -n legacy
```

---

## 6. Verification and failure diagnosis

### 6.1 First-line triage: the container log

`lxc info --show-log` is the single most valuable command when an instance won't start or dies immediately. It surfaces the liblxc log the daemon captured.

```bash
$ lxc start web1
Error: Failed to run: ... : exit status 1
Try `lxc info --show-log web1` for more info

$ lxc info --show-log web1
Name: web1
Status: STOPPED
...
Log:
lxc web1 ERROR    conf - conf.c:lxc_map_ids: newuidmap failed to write mapping
lxc web1 ERROR    start - start.c:lxc_spawn: failed to set up id mapping
```

That signature means the **idmap is broken** → check `/etc/subuid` and `/etc/subgid` for the `root`/`lxd` ranges and that `newuidmap`/`newgidmap` are installed setuid (`uidmap` package).

### 6.2 Live event and API-error stream

```bash
$ lxc monitor --type=lifecycle,logging
metadata:
  action: instance-started
  source: /1.0/instances/web1
timestamp: "2026-08-11T14:31:07Z"
type: lifecycle
```

Raise daemon verbosity when the REST layer itself is suspect:

```bash
$ sudo snap set lxd daemon.debug=true && sudo systemctl reload snap.lxd.daemon
$ sudo journalctl -u snap.lxd.daemon -f --no-hostname
```

### 6.3 Diagnostic checklist by symptom

| Symptom | First checks | Likely cause / fix |
|---|---|---|
| Container won't start, `newuidmap failed` | `cat /etc/subuid /etc/subgid`; `dpkg -l uidmap` | Missing/too-small idmap range; install `uidmap`; ensure `root:1000000:...` present |
| Unprivileged container starts but files "owned by nobody/65534" | `lxc config get c1 raw.idmap`; host `ls -n` on rootfs | idmap mismatch between host FS ownership and container map; align `raw.idmap` |
| Nested Docker/LXD fails inside a container | `lxc config get c1 security.nesting` | Set `security.nesting=true`; may also need `security.syscalls.intercept.*` |
| Memory limit "ignored", host OOM instead | `lxc exec c1 -- cat /sys/fs/cgroup/memory.max`; `limits.memory.enforce` | cgroup v1 vs v2; set `limits.memory.enforce=hard`; confirm host on cgroup v2 |
| No IPv4 on container | `lxc network show lxdbr0`; `lxc exec c1 -- ip a` | dnsmasq/DHCP off or `ipv4.dhcp=false`; NIC not attached; conflicting host firewall |
| `size=` disk quota rejected | `lxc storage show default` | Quotas need zfs/btrfs/lvm; `dir` pool cannot enforce size |
| Container has no LAN reachability but has IP | bridge NAT vs macvlan | Bridge is NAT'd (expected); switch to `macvlan`/`bridged` for L2 LAN presence |

### 6.4 Verify isolation and limits are real (not just configured)

```bash
# cgroup v2 must be the host's hierarchy for modern limit keys:
$ stat -fc %T /sys/fs/cgroup
cgroup2fs

# Prove the memory cap is enforced in-kernel, not just declared:
$ lxc config get web1 limits.memory
1GiB
$ lxc exec web1 -- cat /sys/fs/cgroup/memory.max
1073741824

# Prove unprivileged mapping: container root is an unprivileged host uid:
$ lxc exec web1 -- id -u          # inside: 0
0
$ ps -o uid,pid,comm -p $(lxc info web1 | awk '/PID:/{print $2}')
  UID     PID COMMAND
1000000  24817 systemd            # on the host: mapped, unprivileged

# Confirm AppArmor confinement is active for the instance:
$ sudo aa-status | grep lxd | head
   lxd-web1_</var/snap/lxd/common/lxd> (enforce)
```

### 6.5 Storage and network cross-checks

```bash
$ lxc storage info default
info:
  description: ""
  driver: zfs
  name: default
  space used: 1.84GiB
  total space: 30.00GiB
used by:
  instances:
  - web1
  - web2

$ lxc network show lxdbr0 | sed -n '1,10p'
config:
  ipv4.address: 10.152.1.1/24
  ipv4.nat: "true"
  ipv6.address: none
name: lxdbr0
type: bridge
used_by:
- /1.0/instances/web1
```

If DNS resolution between containers fails, confirm the managed bridge's dnsmasq is serving the `dns.domain` and that `resolv.conf` inside the container points at the bridge gateway (`10.152.1.1`).

---

## 7. References

- LPI — Exam 305-300 Objectives (Topic 352.2 LXC): https://www.lpi.org/our-certifications/exam-305-objectives/
- LinuxContainers — LXC documentation (liblxc, `lxc-*` tools, configuration): https://linuxcontainers.org/lxc/documentation/
- LinuxContainers — LXC container configuration reference (`lxc.container.conf`): https://linuxcontainers.org/lxc/manpages/man5/lxc.container.conf.5.html
- Canonical — LXD documentation (architecture, REST API, instances): https://documentation.ubuntu.com/lxd/
- Canonical LXD — Instance configuration and limits (`limits.cpu`, `limits.memory`, devices): https://documentation.ubuntu.com/lxd/en/latest/reference/instance_options/
- Canonical LXD — Security, unprivileged containers, idmaps and nesting: https://documentation.ubuntu.com/lxd/en/latest/explanation/security/
- Canonical LXD — Storage pools and drivers: https://documentation.ubuntu.com/lxd/en/latest/explanation/storage/
- Canonical LXD — Networking and managed networks: https://documentation.ubuntu.com/lxd/en/latest/explanation/networks/
- LinuxContainers — Incus (community fork of LXD) documentation: https://linuxcontainers.org/incus/docs/main/
- Linux kernel — namespaces overview: https://man7.org/linux/man-pages/man7/namespaces.7.html
- Linux kernel — cgroups v2: https://docs.kernel.org/admin-guide/cgroup-v2.html
- `subuid(5)` / `subgid(5)` — subordinate uid/gid ranges: https://man7.org/linux/man-pages/man5/subuid.5.html