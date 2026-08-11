# LPIC-3 305-300 · Topic 352.2: LXC — Guided Exercises

> **Exam objective 352.2 (weight 10).** Candidates should be able to use system containers using LXC and LXD. The version of LXD covered is 3.0 or later.
> Key knowledge areas exercised below: the LXC/LXD architecture and their relationship, managing containers from existing images (networking and storage), configuring container properties, limiting resource usage, LXD profiles, LXC images, and the `/etc/subuid` · `/etc/subgid` id-mapping model.
> **Terms & utilities:** `lxd`, `lxc`, `/etc/subuid`, `/etc/subgid`.
> Source: LPI, *Exam 305 Objectives*, objective 352.2 — https://www.lpi.org/our-certifications/exam-305-objectives/

**Lab prerequisites.** A single Linux host with a modern kernel (user namespaces, cgroup v2, and overlay/ZFS available), `sudo`/root, and outbound HTTPS to fetch images. Examples use the LXD **snap** (`sudo snap install lxd`) or a distribution package. Add your user to the `lxd` group and re-login so you can run `lxc` without `sudo`:

```bash
sudo usermod -aG lxd "$USER"
newgrp lxd    # or log out/in
```

> **Naming warning that the exam tests.** The client you drive LXD with is called `lxc` (no hyphen). The *original*, low-level LXC userspace tools are the hyphenated `lxc-*` commands (`lxc-create`, `lxc-start`, `lxc-ls`…). `lxc list` talks to the LXD daemon; `lxc-ls` reads `/var/lib/lxc`. They are different programs.

---

## Exercise 1 — Architecture: the daemon, the client, and liblxc

**Goal:** distinguish `lxd` (the daemon) from `lxc` (the client) and locate liblxc underneath both.

1. Confirm the daemon is running and inspect the server it exposes:

   ```bash
   lxc info | head -n 20
   ```

   Expected (abridged):

   ```
   config: {}
   api_extensions:
   - storage_zfs_remove_snapshots
   - container_host_shutdown_timeout
   ...
   environment:
     addresses: []
     architectures:
     - x86_64
     - i686
     driver: lxc | qemu
     driver_version: 6.0.0 | ...
     kernel: Linux
     server: lxd
     server_version: "5.21"
   ```

2. Ask the client where it is pointing — this is a *remote*, and by default it is the local Unix socket:

   ```bash
   lxc remote get-default
   lxc remote list
   ```

   Expected (abridged):

   ```
   local
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   |      NAME       |                   URL                    |   PROTOCOL    |  AUTH TYPE  | PUBLIC | GLOBAL |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   | images          | https://images.linuxcontainers.org      | simplestreams |             | YES    | NO     |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   | local (current) | unix://                                  | lxd           | file access | NO     | NO     |
   +-----------------+------------------------------------------+---------------+-------------+--------+--------+
   ```

3. Show that LXD drives the same kernel primitives as raw LXC. Look at the storage/driver backends and note the `driver: lxc`:

   ```bash
   lxc info | grep -A1 "driver:"
   ```

4. (If the classic tools are installed — `apt install lxc` on Debian/Ubuntu) contrast the two stacks. The low-level tools store per-container state as flat config files:

   ```bash
   ls /usr/share/lxc/templates/     # download, oci, busybox, local, ...
   sudo lxc-ls --fancy 2>/dev/null  # empty unless you created lxc-* containers
   cat /etc/lxc/default.conf        # default network + idmap for lxc-* tooling
   ```

**Comprehension**

- **1.1** Which component is a long-running background service, and which is a command-line front end that can also talk to *remote* servers over HTTPS?
- **1.2** What does the `driver: lxc` line tell you about the relationship between LXD and the LXC project?
- **1.3** A colleague runs `lxc-ls` and sees nothing, but `lxc list` shows five running containers. Explain, without assuming a bug.
- **1.4** Name two protocols shown in `lxc remote list` and say what each remote is used for.

---

## Exercise 2 — LXC images and remotes

**Goal:** understand image remotes, fingerprints, and aliases, and cache an image locally.

1. Browse the community image server (the `images:` remote) filtered to one distro:

   ```bash
   lxc image list images: ubuntu/22.04 architecture=x86_64
   ```

   Expected (abridged):

   ```
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   |            ALIAS            | FINGERPRINT  | PUBLIC |             DESCRIPTION             | ARCHITECTURE |   TYPE    |   SIZE   |          UPLOAD DATE           |
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   | ubuntu/22.04 (3 more)       | 4d3f8e2b9c1a | yes    | Ubuntu jammy amd64 (20260810_07:42) | x86_64       | CONTAINER | 118.24MB | 2026/08/10 07:42 UTC          |
   +-----------------------------+--------------+--------+-------------------------------------+--------------+-----------+----------+-------------------------------+
   ```

2. Launch a container from that image (this pulls and caches the image, then creates and starts an instance):

   ```bash
   lxc launch images:ubuntu/22.04 web01
   ```

   Expected:

   ```
   Creating web01
   Starting web01
   ```

3. Look at what was cached locally. The image now lives in the `local:` remote, keyed by its **fingerprint** (a SHA-256), not by its upstream alias:

   ```bash
   lxc image list
   lxc image info 4d3f8e2b9c1a | head -n 15
   ```

4. Give the cached image a stable local alias and prove `launch` can use it offline:

   ```bash
   lxc image alias create jammy-base 4d3f8e2b9c1a
   lxc launch local:jammy-base web02
   ```

**Comprehension**

- **2.1** What is an image *fingerprint*, and why does LXD key the local cache on it rather than on the alias?
- **2.2** Distinguish the `images:`, `ubuntu:`, and `local:` remotes.
- **2.3** After step 2, you never explicitly downloaded anything with an "image import" command. Where did the image come from and where is it now?
- **2.4** Would `lxc launch local:jammy-base web03` work with the network unplugged? Why or why not?

---

## Exercise 3 — Container lifecycle and interaction

**Goal:** drive the full lifecycle and move data in and out without SSH.

1. List, inspect, and enter the running container:

   ```bash
   lxc list
   lxc info web01 | head -n 20
   lxc exec web01 -- bash
   ```

   Inside the container run `cat /etc/os-release && exit`.

2. Run a one-shot command (no interactive shell) and capture its output on the host:

   ```bash
   lxc exec web01 -- ps -eo pid,user,comm --no-headers | head
   ```

3. Push a file in and pull one out (note the `<instance>/<path>` addressing):

   ```bash
   echo "hello from host" > /tmp/msg.txt
   lxc file push /tmp/msg.txt web01/root/msg.txt
   lxc file pull web01/etc/hostname /tmp/web01-hostname
   cat /tmp/web01-hostname
   ```

4. Exercise stop/start/restart and a clean delete of the second container:

   ```bash
   lxc stop web02
   lxc list web02
   lxc delete web02            # refuses if running; add --force to stop+delete
   ```

**Comprehension**

- **3.1** `lxc exec web01 -- bash` versus `lxc exec web01 bash` — is there a difference, and what does `--` protect against?
- **3.2** In step 4, `lxc delete web02` succeeded because the container was stopped. What single flag would let you delete a *running* container in one command?
- **3.3** `lxc file push`/`pull` needs no SSH daemon in the container. Which component actually performs the copy?

---

## Exercise 4 — Networking: the managed bridge and static addressing

**Goal:** understand `lxdbr0`, create a second managed network, and pin a static IP via a device.

1. Inspect the default managed bridge that new instances attach to:

   ```bash
   lxc network list
   lxc network show lxdbr0
   ```

   Expected (abridged):

   ```
   config:
     ipv4.address: 10.10.10.1/24
     ipv4.nat: "true"
     ipv6.address: fd42:aaaa:bbbb:cccc::1/64
     ipv6.nat: "true"
   name: lxdbr0
   type: bridge
   managed: true
   used_by:
   - /1.0/instances/web01
   ```

2. Create a second isolated IPv4-only managed bridge with NAT:

   ```bash
   lxc network create lxdbr1 ipv4.address=10.20.20.1/24 ipv4.nat=true ipv6.address=none
   ```

3. The `eth0` NIC on `web01` comes from the **default profile**, so it is not defined on the instance. Override it at the instance level to attach a fixed address, then verify:

   ```bash
   lxc config device override web01 eth0 ipv4.address=10.10.10.50
   lxc restart web01
   lxc list web01
   ```

   Expected:

   ```
   +-------+---------+---------------------+------+-----------+-----------+
   | NAME  |  STATE  |        IPV4         | IPV6 |   TYPE    | SNAPSHOTS |
   +-------+---------+---------------------+------+-----------+-----------+
   | web01 | RUNNING | 10.10.10.50 (eth0)  | ...  | CONTAINER | 0         |
   +-------+---------+---------------------+------+-----------+-----------+
   ```

4. Attach `web01` to the second bridge as a *second* NIC:

   ```bash
   lxc network attach lxdbr1 web01 eth1
   lxc exec web01 -- ip -4 addr show
   ```

**Comprehension**

- **4.1** In step 3, why was `lxc config device override` needed instead of `lxc config device set`? Where was the `eth0` device actually defined?
- **4.2** A static `ipv4.address` on a NIC only works if the container is on a **managed** bridge with a DHCP range. Why does LXD require the managed bridge for this to take effect?
- **4.3** `ipv4.nat=true` on `lxdbr1` — what does it configure on the host, and what would break if you set it to `false` without further routing?

---

## Exercise 5 — Storage pools and volumes

**Goal:** understand the storage pool abstraction and attach a custom volume.

1. Inspect the default storage pool created by `lxd init`:

   ```bash
   lxc storage list
   lxc storage show default
   ```

   Expected (abridged, ZFS example):

   ```
   config:
     source: default
     zfs.pool_name: default
   driver: zfs
   name: default
   used_by:
   - /1.0/images/4d3f8e2b9c1a
   - /1.0/instances/web01
   ```

2. Create a second pool using the simplest driver (`dir` — a plain directory), then a custom volume on it:

   ```bash
   sudo mkdir -p /srv/lxd-extra
   lxc storage create extra dir source=/srv/lxd-extra
   lxc storage volume create extra shared-data
   ```

3. Attach the custom volume into `web01` at a mount path, write to it, and confirm persistence:

   ```bash
   lxc storage volume attach extra shared-data web01 /mnt/shared
   lxc exec web01 -- sh -c 'echo persisted > /mnt/shared/state && cat /mnt/shared/state'
   ```

4. Show that the volume is independent of the instance's root disk — the root disk is itself a device:

   ```bash
   lxc config device show web01
   lxc storage volume list extra
   ```

**Comprehension**

- **5.1** What is the difference between a storage **pool** and a storage **volume**?
- **5.2** The root filesystem of a container is a `disk` device backed by a pool. What are the practical consequences of deleting the container for its root volume versus for the `shared-data` custom volume?
- **5.3** Give one operational reason to prefer `zfs`/`btrfs` over the `dir` driver for the default pool.

---

## Exercise 6 — Container properties and resource limits (cgroups)

**Goal:** configure instance properties and cap CPU/memory through cgroups.

1. Read the full, profile-expanded configuration of a container:

   ```bash
   lxc config show web01              # instance-only keys
   lxc config show web01 --expanded   # profiles merged in
   ```

2. Apply hard resource limits and set an autostart property:

   ```bash
   lxc config set web01 limits.cpu 2
   lxc config set web01 limits.memory 512MB
   lxc config set web01 limits.memory.enforce hard
   lxc config set web01 boot.autostart true
   ```

3. Apply the limits (memory changes may need a restart) and verify from *inside* the container:

   ```bash
   lxc restart web01
   lxc exec web01 -- nproc
   lxc exec web01 -- sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes'
   ```

   Expected:

   ```
   2
   536870912
   ```

4. Switch from pinning whole CPUs to a time-based allowance and observe the difference:

   ```bash
   lxc config unset web01 limits.cpu
   lxc config set web01 limits.cpu.allowance 50%
   lxc config get web01 limits.cpu.allowance
   ```

**Comprehension**

- **6.1** `limits.cpu 2` versus `limits.cpu.allowance 50%` — what does each do, and which one still exposes all host CPUs to the container's scheduler?
- **6.2** With `limits.memory.enforce hard`, what happens to a process inside the container that exceeds `limits.memory`? What changes under `soft`?
- **6.3** In step 3 you read `/sys/fs/cgroup/memory.max` **from inside** the container and saw the limit. Which kernel subsystem makes the container see its own cgroup limits rather than the host's total RAM?
- **6.4** Which of the keys you set survives a full stop/start of the container, and where is that state stored?

---

## Exercise 7 — LXD profiles

**Goal:** treat configuration as reusable, composable profiles.

1. Read the `default` profile — the source of every instance's `eth0` and `root` devices:

   ```bash
   lxc profile show default
   ```

2. Create a reusable "small" profile that carries limits only (no devices):

   ```bash
   lxc profile create small
   lxc profile set small limits.cpu 1
   lxc profile set small limits.memory 256MB
   lxc profile show small
   ```

3. Compose profiles onto an instance. `add` appends; `assign` replaces the whole ordered list:

   ```bash
   lxc profile add web01 small           # web01 now: default, small
   lxc config show web01 --expanded | grep -A3 limits
   lxc profile assign web01 default,small
   ```

4. Launch a fresh container directly with a profile stack:

   ```bash
   lxc launch images:alpine/3.19 edge01 -p default -p small
   lxc config show edge01 --expanded | grep -E 'limits.(cpu|memory)'
   ```

**Comprehension**

- **7.1** Profiles are applied as an ordered list and merged. If `default` sets `limits.memory 1GB` and `small` (applied after it) sets `256MB`, what is the effective limit and why?
- **7.2** What is the practical risk of running `lxc profile assign web01 small` (note: **not** `default,small`) on a container that relies on `default` for its NIC and root disk?
- **7.3** You set `limits.cpu 2` directly on `web01` in Exercise 6 *and* it inherits `small`'s `limits.cpu 1`. Which wins, an instance-level key or a profile key?

---

## Exercise 8 — Unprivileged containers, `/etc/subuid` and `/etc/subgid`

**Goal:** understand the user-namespace id mapping that makes LXD containers unprivileged by default, and how the subordinate-id files feed it.

1. Inspect the subordinate id ranges the LXD daemon (running as `root`) is allowed to hand out:

   ```bash
   cat /etc/subuid
   cat /etc/subgid
   ```

   Expected (typical LXD default):

   ```
   root:1000000:1000000000
   ubuntu:100000:65536
   ```

   Read the `root:` line as: *the `root` user may map subordinate IDs starting at host UID `1000000`, for `1000000000` consecutive IDs.*

2. Confirm a container is unprivileged (the default) and find its host-side PID:

   ```bash
   lxc config get web01 security.privileged     # empty/false => unprivileged
   PID=$(lxc info web01 | awk '/Pid:/ {print $2}')
   echo "$PID"
   ```

3. Prove the mapping: **root (UID 0) inside** the container runs as an **unprivileged high UID on the host**:

   ```bash
   ps -o pid,user,uid,comm -p "$PID"
   ```

   Expected (uid mapped into the subordinate range):

   ```
     PID    USER     UID  COMMAND
   28412 1000000 1000000  systemd
   ```

4. Contrast with a privileged container (root-in equals root-on-host — avoid in production):

   ```bash
   lxc launch images:alpine/3.19 priv01 -c security.privileged=true
   PPID=$(lxc info priv01 | awk '/Pid:/ {print $2}')
   ps -o pid,user,uid,comm -p "$PPID"      # USER root, UID 0
   lxc delete --force priv01
   ```

**Comprehension**

- **8.1** In `/etc/subuid`, decode `root:1000000:1000000000` field by field.
- **8.2** Why does the LXD daemon consult the **`root`** line specifically, rather than your login user's line?
- **8.3** In step 3, container UID 0 showed as host UID 1000000. If a process escaped the container as "root", what host privileges would it actually hold, and why is that the central security benefit of unprivileged containers?
- **8.4** What does `security.privileged=true` change about the id mapping, and name one reason you might still (reluctantly) need it.
- **8.5** If `/etc/subuid`/`/etc/subgid` were empty or the `root` range were too small, what would happen when you try to start an unprivileged container?

---

## Exercise 9 — Snapshots and publishing a golden image

**Goal:** capture state, roll back, and turn a known-good container into a reusable image — closing the loop back to Exercise 2.

1. Take a snapshot of a clean container, then make a destructive change:

   ```bash
   lxc snapshot web01 clean-base
   lxc info web01 | sed -n '/Snapshots:/,$p'
   lxc exec web01 -- rm -rf /etc/nginx        # simulate breakage
   ```

2. Roll back and confirm restoration:

   ```bash
   lxc restore web01 clean-base
   lxc exec web01 -- ls -d /etc/nginx 2>/dev/null && echo "restored"
   ```

3. Publish the snapshot as a local image with an alias (the container must be stopped to publish, or publish the snapshot directly):

   ```bash
   lxc publish web01/clean-base --alias web-gold
   lxc image list web-gold
   ```

4. Launch a brand-new container from your golden image — no upstream fetch:

   ```bash
   lxc launch local:web-gold web03
   lxc list web03
   ```

**Comprehension**

- **9.1** What is the difference between a **snapshot** and a **published image**? When would you reach for each?
- **9.2** `lxc restore web01 clean-base` — is this reversible? What happens to changes made after the snapshot was taken?
- **9.3** After publishing, `web-gold` shows up in `lxc image list` with its own fingerprint. Relate this back to Exercise 2: what remote does `local:web-gold` resolve to, and why can `web03` launch without network access?

---

<details>
<summary><strong>Answer key (all exercises)</strong></summary>

### Exercise 1 — Architecture

- **1.1** `lxd` is the long-running daemon (the REST API server that owns instances, images, storage and networks). `lxc` is the command-line **client**; it speaks the LXD REST protocol either to the local Unix socket or, over HTTPS, to remote LXD servers.
- **1.2** `driver: lxc` means the LXD daemon uses **liblxc** (the LXC project's C library) to actually create and run system containers. LXD is a **management layer** (API, images, clustering, storage/network abstractions) built *on top of* LXC; LXC provides the low-level container runtime. That is the core of "the relationship between LXC and LXD."
- **1.3** No bug. `lxc-ls` is the classic **LXC** tool and reads `/var/lib/lxc`; `lxc list` is the **LXD** client and lists instances owned by the LXD daemon. The five containers were created through LXD, so they are invisible to the `lxc-*` tools. The two stacks keep separate state.
- **1.4** `simplestreams` — used by public **image** servers (e.g. `images:`) to advertise available images. `lxd` (with `unix://` for the local socket, or an HTTPS URL for a remote) — used to manage instances/storage/networks on an LXD server. `local` is the current default remote pointing at the local daemon.

### Exercise 2 — Images

- **2.1** A fingerprint is the **SHA-256 hash of the image contents**. Keying the cache on it makes storage content-addressable and deduplicated: identical image contents map to one cached object regardless of which alias(es) point at it, and integrity is verifiable.
- **2.2** `images:` → the community LinuxContainers image server (many distros/versions). `ubuntu:` → Canonical's official Ubuntu release cloud images. `local:` → images cached in *your* LXD daemon. (In real deployments note that Canonical's LXD and the community fork **Incus** now use different default image servers; the exam predates that split and treats `images:` as the community server.)
- **2.3** `lxc launch` pulled the image from the `images:` remote on demand, stored it in the **local image cache** (visible via `lxc image list`), then created and started the instance from it. Launch = fetch-if-needed + init + start.
- **2.4** Yes. `local:jammy-base` resolves to the already-cached local image, so no upstream fetch is required. Only a *cache miss* (an alias/fingerprint not present locally) needs the network.

### Exercise 3 — Lifecycle

- **3.1** Functionally similar here, but `--` marks the end of `lxc`'s own options: everything after it is passed verbatim to the command in the container. It protects against a container command whose arguments (e.g. `-e`, `--config`) would otherwise be parsed by `lxc` itself.
- **3.2** `lxc delete --force web02` stops the running container and deletes it in one step.
- **3.3** The **LXD daemon** performs the copy through its API (the `lxc` client streams the file over the LXD socket/REST connection); it reads/writes the container's filesystem directly. No in-container SSH or agent is required.

### Exercise 4 — Networking

- **4.1** `eth0` was **not defined on the instance** — it was inherited from the `default` profile. `lxc config device set` edits an existing *instance-level* device, which did not exist yet. `lxc config device override` **copies** the profile-provided device onto the instance and then applies the change, so the instance now owns an `eth0` device that shadows the profile's.
- **4.2** A managed bridge is one LXD controls, including its built-in **dnsmasq/DHCP** range. A static NIC address is enforced by pinning the DHCP lease/DNS entry for that instance; on an unmanaged bridge LXD has no DHCP server to pin, so the `ipv4.address` key has nothing to act on.
- **4.3** `ipv4.nat=true` makes LXD install a **source-NAT (masquerade) firewall rule** on the host so container traffic egresses using the host's IP. With `false` and no manual routing, containers on `10.20.20.0/24` could reach the host but their return path from the outside world would be unrouted, so external connectivity would break unless you add routes/NAT yourself.

### Exercise 5 — Storage

- **5.1** A **pool** is the backing store (a ZFS zpool, btrfs filesystem, LVM VG, or plain directory) with a driver; a **volume** is an allocation *within* a pool (an instance root disk, an image, or a custom data volume). Pools are the capacity; volumes are the slices.
- **5.2** Deleting the container deletes its **root** volume (its filesystem is gone). The **custom** `shared-data` volume is an independent object in the pool and **survives**; it can be re-attached to another instance. That independence is exactly why custom volumes are used for data that must outlive an instance.
- **5.3** `zfs`/`btrfs` provide copy-on-write, so image→instance creation and **snapshots** are near-instant and space-efficient (and enable fast `lxc copy`/`restore`); `dir` copies bytes and stores snapshots as full copies, which is slower and larger.

### Exercise 6 — Limits

- **6.1** `limits.cpu 2` **pins** the container to 2 CPU cores (CPU-set affinity). `limits.cpu.allowance 50%` leaves all host CPUs visible to the scheduler but caps total CPU **time** to 50% via cgroup CPU quota. Allowance still exposes every host CPU; pinning restricts which cores are usable.
- **6.2** `hard`: exceeding `limits.memory` triggers the cgroup memory controller — allocations fail and the in-container **OOM killer** reaps processes; the container cannot exceed the cap. `soft`: the value becomes a *soft* reclaim target — under host memory pressure the container is pushed back toward it, but it may temporarily exceed the limit when memory is free.
- **6.3** **cgroups** (v2) provide the accounting/limit values, and LXD (via **lxcfs**) overlays a per-container view of `/proc` and `/sys/fs/cgroup` so tools inside the container see their own limit (`memory.max`) and CPU counts instead of the host totals.
- **6.4** All of the `limits.*` and `boot.autostart` keys are **persistent instance configuration** stored in the LXD database (part of `lxc config show web01`); they survive stop/start and daemon restarts. Only the live cgroup state is transient and is re-applied on start.

### Exercise 7 — Profiles

- **7.1** Effective limit is **256MB**. Profiles are merged in list order and **later profiles override earlier ones** for the same key; `small` is applied after `default`, so its value wins.
- **7.2** `assign small` **replaces the entire profile list**, dropping `default`. The container would lose the `eth0` NIC and the `root` disk that `default` provided — leaving it with no network and, critically, **no root filesystem device**, so it would fail to start. Use `assign default,small` (or `profile add`) to keep `default`.
- **7.3** The **instance-level** key wins. Precedence is: profiles merged in order, then **instance configuration overrides all profiles**. So `web01`'s directly-set `limits.cpu 2` beats `small`'s `limits.cpu 1`.

### Exercise 8 — Unprivileged containers & `/etc/subuid`/`/etc/subgid`

- **8.1** `root:1000000:1000000000` = `<owner>:<start>:<count>`. The **`root`** user is allowed to use subordinate IDs beginning at host UID **1000000**, for **1000000000** consecutive IDs (host UIDs 1000000 … 1000999999).
- **8.2** The **LXD daemon runs as `root`**, so when it sets up the user namespace it draws from `root`'s subordinate ranges. Your login user's `/etc/subuid` line matters only for *rootless*/user-owned container tooling, not for system LXD.
- **8.3** It would hold only the privileges of an **ordinary unprivileged host UID (1000000)** — it owns no host files, cannot act on host resources it doesn't own, and has no host `CAP_*` outside its namespace. Because container "root" (UID 0) is mapped to a non-privileged host UID via user namespaces, a container escape does **not** yield host root. That mapping is the central security benefit.
- **8.4** `security.privileged=true` **disables the UID/GID remap**: container UID 0 equals host UID 0 (real root). You might still need it for workloads that genuinely require host-level privileges or unsupported operations (certain nested/hardware or legacy cases) — accepting the much larger blast radius of an escape.
- **8.5** Start would **fail**: without a usable `root` subordinate range LXD cannot allocate the id map for the user namespace, so it cannot create the unprivileged container. (LXD needs a range large enough — typically 65536+ — to map the container's uids/gids.)

### Exercise 9 — Snapshots & publishing

- **9.1** A **snapshot** is a point-in-time copy of a *single* container (state + filesystem) used for rollback of that same instance. A **published image** is a reusable, content-addressed image (with a fingerprint/alias) from which you can create *many new* containers or share/export. Snapshot = restore this one; image = template for new ones.
- **9.2** `restore` is **not automatically reversible**: any changes made *after* the snapshot are discarded when you roll back. To keep the current state before restoring, take a new snapshot first (or LXD can be configured to auto-snapshot on stateful restore).
- **9.3** `local:web-gold` resolves to the **`local:` remote** — your own daemon's image cache (the same store filled in Exercise 2). Because the image already exists locally with its own fingerprint, `web03` is created from the cache with **no upstream fetch**, hence no network needed.

</details>

---

### References (official sources)

- LPI — *Exam 305 Objectives* (objective 352.2): https://www.lpi.org/our-certifications/exam-305-objectives/
- Canonical — *LXD documentation* (instances, profiles, storage, networking, security/idmaps): https://documentation.ubuntu.com/lxd/
- LinuxContainers — *LXC documentation* (liblxc, `lxc-*` tools, templates): https://linuxcontainers.org/lxc/documentation/
- LinuxContainers — *Incus* (community fork of LXD; relevant for current deployments): https://linuxcontainers.org/incus/docs/main/
- man pages: `lxc(1)` (LXD client), `lxd(1)`, `subuid(5)`, `subgid(5)`, `lxc.container.conf(5)`