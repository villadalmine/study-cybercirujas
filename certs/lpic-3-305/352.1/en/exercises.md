# 352.1 Container Virtualization Concepts — Guided Exercises

> **Exam:** LPIC-3 305-300, version 3.0 · **Topic weight:** 11.67
> **Objective source:** <https://www.lpi.org/our-certifications/exam-305-objectives/>
>
> These exercises build container isolation *by hand*, using the same primitives a runtime like `runc`, `crun` or LXC uses under the hood: **namespaces**, **cgroups**, **capabilities**, and the kernel security modules **seccomp / SELinux / AppArmor**. You will not use Docker to *create* isolation here — you will use the kernel tools directly so you can see where a container actually lives.

## Prerequisites

- A Linux host with **cgroup v2** (default on Fedora, RHEL 9+, Debian 11+, Ubuntu 22.04+). Verify with `stat -fc %T /sys/fs/cgroup` → must print `cgroup2fs`.
- Root or `sudo`.
- Packages: `util-linux` (`unshare`, `nsenter`, `lsns`), `iproute2` (`ip`), `libcap` / `libcap2-bin` (`capsh`, `getpcaps`), and `runc`. On Fedora: `sudo dnf install -y util-linux iproute libcap runc`.
- A `containers` runtime only for exporting a root filesystem later (`docker` or `podman`).

> ⚠️ Run these in a throwaway VM or a machine you can reboot. You will create network namespaces, cgroups and mounts. Nothing here is destructive if you follow the cleanup steps, but namespace experiments can strand processes.

---

## Exercise 1 — A namespace is just an inode: prove it

The kernel exposes every namespace a process belongs to as a magic symlink under `/proc/<pid>/ns/`. Two processes share a namespace **if and only if** those symlinks point to the same inode number. This is the ground truth of "same container / different container".

1. Look at your own shell's namespaces:

   ```bash
   ls -l /proc/$$/ns
   ```

   Expected (inode numbers will differ on your host):

   ```
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 cgroup -> 'cgroup:[4026531835]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 ipc -> 'ipc:[4026531839]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 mnt -> 'mnt:[4026531841]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 net -> 'net:[4026531840]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 pid -> 'pid:[4026531836]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 time -> 'time:[4026531834]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 user -> 'user:[4026531837]'
   lrwxrwxrwx 1 user user 0 Aug 11 10:02 uts -> 'uts:[4026531838]'
   ```

2. Note the eight namespace types: `cgroup`, `ipc`, `mnt`, `net`, `pid`, `time`, `user`, `uts`. Record the **`uts`** inode number.

3. In a *second* terminal, run the same command and compare the `uts` inode. On a normal system every process shares the host's initial namespaces, so the numbers match.

4. List every namespace on the system and how many processes are in each:

   ```bash
   sudo lsns --type uts
   ```

   Expected (one row — the host UTS namespace holds everything):

   ```
           NS TYPE NPROCS   PID USER COMMAND
   4026531838 uts     214     1 root /usr/lib/systemd/systemd ...
   ```

**Comprehension check 1**

1. What is the mechanism that decides whether two processes are "in the same container" for a given resource dimension?
2. There are eight namespace types in step 2. Which one is **not** an isolation boundary in the classic sense but instead changes what `/proc/self/cgroup` *reports*?
3. Why does `lsns` currently show only one UTS namespace with PID 1 as owner?

---

## Exercise 2 — Create isolation with `unshare`

`unshare` runs a program with fresh namespaces. You will build a minimal container's *hostname* and *PID* isolation without any container tooling.

1. Create a new **UTS** namespace and change the hostname inside it only:

   ```bash
   sudo unshare --uts bash
   hostname isolated-box
   hostname
   ```

   Inside: `isolated-box`. Now open another terminal on the host and run `hostname` — it still shows the host name. The change was contained.

2. Confirm the shell is in a *different* UTS namespace than the host by comparing inodes:

   ```bash
   # inside the unshared shell
   readlink /proc/$$/ns/uts
   ```

   The inode differs from the one you recorded in Exercise 1. Exit this shell (`exit`) before continuing.

3. Now create a **PID + mount** namespace so the isolated shell sees its own process tree. `--fork` and `--mount-proc` are required so PID 1 semantics work and `/proc` reflects the new PID namespace:

   ```bash
   sudo unshare --pid --fork --mount-proc bash
   ps -ef
   ```

   Expected — the shell is **PID 1** and sees almost nothing else:

   ```
   UID          PID    PPID  C STIME TTY          TIME CMD
   root           1       0  0 10:10 pts/0    00:00:00 bash
   root          10       1  0 10:10 pts/0    00:00:00 ps -ef
   ```

4. From a host terminal, find that same `bash` and note it has a large, ordinary PID:

   ```bash
   ps -ef | grep '[b]ash' | tail -1
   ```

   Same process, two different PIDs. Exit the unshared shell afterward.

5. Build a **user namespace** as an *unprivileged* user and become root inside it — no `sudo`:

   ```bash
   unshare --user --map-root-user --uts bash
   id
   ```

   Expected: `uid=0(root) gid=0(root) groups=0(root)`. You are "root" — but only inside this namespace.

6. Test the boundary. Try something that requires real host privilege:

   ```bash
   hostname newname     # succeeds: you also unshared UTS
   cat /etc/shadow      # fails: Permission denied
   ```

**Comprehension check 2**

1. Why are `--fork` and `--mount-proc` both needed for PID-namespace isolation to look right in `ps`?
2. In step 5 you became UID 0 with no `sudo`. What real, host-level privileges does that root *not* have, and what feature maps your outside UID to inside-UID 0?
3. A user namespace is the only namespace an unprivileged user can create on most distros. Why is that both the enabling feature for **rootless containers** and, historically, a large kernel attack surface?

---

## Exercise 3 — Join an existing container with `nsenter`

`nsenter` is the debugging tool for containers: it enters the namespaces of a *running* process. This is how you "get a shell inside a container" without the container runtime.

1. Start a long-lived isolated process and keep its PID. In terminal A:

   ```bash
   sudo unshare --uts --net --pid --fork --mount-proc sleep 3000 &
   echo $!        # note this PID (the unshare wrapper); find the child sleep:
   sudo lsns --type net | tail -1
   ```

   Find the PID of the process holding the *new* net namespace (the `sleep`/`unshare` tree).

2. From terminal B, enter that process's UTS + NET + PID namespaces and run a shell as if you were inside the "container":

   ```bash
   TARGET=<pid-from-step-1>
   sudo nsenter --target "$TARGET" --uts --net --pid ip addr
   ```

   Expected — you see the *container's* network view, which is just a loopback with no addresses configured:

   ```
   1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
       link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   ```

   Contrast: the same `ip addr` on the host shows all your real interfaces.

3. Enter *all* of the target's namespaces at once (the common "exec into container" pattern):

   ```bash
   sudo nsenter --target "$TARGET" --all bash
   ```

4. Clean up: `sudo kill "$TARGET"` (or `kill %1` in terminal A).

**Comprehension check 3**

1. `docker exec -it <c> sh` and `sudo nsenter -t <pid> -a sh` produce nearly the same result. In terms of the objective's primitives, what is `docker exec` actually doing?
2. In step 2 the container had only a down `lo` interface. What would you have to build for it to reach the network, and which namespace type owns that view?
3. Why can `nsenter` require joining the **mount** namespace *before* it can execute a binary that only exists inside the container's root filesystem?

---

## Exercise 4 — Network namespaces with `ip netns` and a `veth` pair

The `ip netns` subcommand manages *named* network namespaces (persisted as bind-mounts under `/var/run/netns/`). You will wire a namespace to the host with a virtual ethernet pair — the exact mechanism behind a container bridge.

1. Create a named network namespace and inspect it:

   ```bash
   sudo ip netns add ctr1
   sudo ip netns list
   sudo ip netns exec ctr1 ip addr
   ```

   Inside `ctr1` there is only `lo`, and it is `DOWN`.

2. Create a `veth` pair — one end stays on the host, the other moves into `ctr1`:

   ```bash
   sudo ip link add veth-host type veth peer name veth-ctr
   sudo ip link set veth-ctr netns ctr1
   ```

3. Address and bring up both ends:

   ```bash
   sudo ip addr add 10.10.0.1/24 dev veth-host
   sudo ip link set veth-host up

   sudo ip netns exec ctr1 ip addr add 10.10.0.2/24 dev veth-ctr
   sudo ip netns exec ctr1 ip link set veth-ctr up
   sudo ip netns exec ctr1 ip link set lo up
   ```

4. Prove connectivity across the namespace boundary:

   ```bash
   sudo ip netns exec ctr1 ping -c2 10.10.0.1
   ```

   Expected:

   ```
   64 bytes from 10.10.0.1: icmp_seq=1 ttl=64 time=0.045 ms
   64 bytes from 10.10.0.1: icmp_seq=2 ttl=64 time=0.039 ms
   ```

5. Confirm the isolation is real — the namespace has its own routing table and firewall:

   ```bash
   sudo ip netns exec ctr1 ip route
   # 10.10.0.0/24 dev veth-ctr proto kernel scope link src 10.10.0.2
   ```

6. Clean up:

   ```bash
   sudo ip netns del ctr1        # deleting the netns also destroys veth-ctr
   sudo ip link del veth-host 2>/dev/null || true
   ```

**Comprehension check 4**

1. When you moved `veth-ctr` into `ctr1`, its peer `veth-host` stayed behind. Why is a `veth` pair the natural building block for connecting a container to a host bridge?
2. `ip netns` namespaces persist even with no process inside them. Where does the kernel keep them alive, and how does that differ from the *anonymous* namespaces made by `unshare`?
3. Your container could ping `10.10.0.1` but could not reach the internet. What two host-side pieces (one routing, one packet-rewriting) would a real CNI plugin add to fix that?

---

## Exercise 5 — Control groups v2: limit memory and CPU

Namespaces control *what a process sees*; cgroups control *how much it can consume*. You will place a process in a cgroup, cap its memory, and watch the kernel OOM-kill it inside that cgroup only.

1. Confirm the hierarchy and enable the controllers you need in the root's subtree:

   ```bash
   stat -fc %T /sys/fs/cgroup            # -> cgroup2fs
   cat /sys/fs/cgroup/cgroup.controllers # available controllers
   echo "+memory +cpu" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
   ```

2. Create a leaf cgroup and cap its memory at 20 MiB:

   ```bash
   sudo mkdir /sys/fs/cgroup/demo
   echo "20M" | sudo tee /sys/fs/cgroup/demo/memory.max
   ```

3. Cap CPU to 20% of one core (`quota period`; 20000 µs of every 100000 µs):

   ```bash
   echo "20000 100000" | sudo tee /sys/fs/cgroup/demo/cpu.max
   ```

4. Launch a shell and move it into the cgroup by writing its PID:

   ```bash
   sudo bash -c 'echo $$ > /sys/fs/cgroup/demo/cgroup.procs; exec bash'
   cat /sys/fs/cgroup/demo/cgroup.procs   # your shell PID is listed
   ```

5. From another terminal, watch the cgroup while you trigger the memory limit. In the **capped** shell, allocate more than 20 MiB:

   ```bash
   python3 -c 'a = bytearray(50 * 1024 * 1024); print("allocated"); input()'
   ```

   Expected: the process is **Killed** before printing `allocated`.

6. Read the accounting the kernel kept for that cgroup:

   ```bash
   cat /sys/fs/cgroup/demo/memory.current   # current usage in bytes
   cat /sys/fs/cgroup/demo/memory.events    # look for oom_kill 1
   ```

   Expected `memory.events` includes:

   ```
   oom 1
   oom_kill 1
   ```

7. Clean up (a cgroup directory can only be removed when empty of processes):

   ```bash
   exit                                     # leave the capped shell
   sudo rmdir /sys/fs/cgroup/demo
   ```

**Comprehension check 5**

1. What is the "no internal process" rule of cgroup v2, and why did you have to enable controllers via `cgroup.subtree_control` in the *parent* rather than on `demo` itself?
2. The memory limit was enforced by an OOM kill *scoped to the cgroup*. How does that differ from a global system OOM, and why does that matter for multi-tenant nodes?
3. `cpu.max` of `20000 100000` throttles but does not "reserve." Which cgroup file would you use to give a workload a *guaranteed weight* under contention, and how does that map to Kubernetes CPU **requests** vs **limits**?

---

## Exercise 6 — Capabilities: split root into pieces

A container "root" is not full root. The kernel splits privilege into ~40 **capabilities**, and runtimes drop most of them. You will inspect and manipulate the capability sets directly.

1. See the capabilities of your current shell:

   ```bash
   capsh --print
   ```

   As a normal user, `Current:` is empty. As root, `Current:` is the full set.

2. Read the raw sets from `/proc`:

   ```bash
   grep Cap /proc/$$/status
   ```

   Expected (unprivileged user — all zero effective):

   ```
   CapInh: 0000000000000000
   CapPrm: 0000000000000000
   CapEff: 0000000000000000
   CapBnd: 000001ffffffffff
   CapAmb: 0000000000000000
   ```

3. Decode a bitmask into capability names:

   ```bash
   capsh --decode=000001ffffffffff     # the full bounding set
   ```

4. Now decode the mask a **default Docker container** runs with — a deliberately reduced set of 14 capabilities:

   ```bash
   capsh --decode=00000000a80425fb
   ```

   Expected:

   ```
   0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
   cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,
   cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
   ```

5. Drop a capability from the **bounding set** and prove it cannot come back. Start a root shell that has dropped `CAP_NET_RAW`:

   ```bash
   sudo capsh --drop=cap_net_raw --print | grep -i bounding
   ```

   `cap_net_raw` is absent from the Bounding set. A process here can never use raw sockets — this is exactly how a runtime prevents `ping`-via-raw-socket or ARP spoofing from inside a container.

6. Inspect a running process's *effective* capabilities by PID:

   ```bash
   getpcaps 1        # PID 1 / systemd
   ```

**Comprehension check 6**

1. Name the five capability sets in `/proc/<pid>/status` (Inh, Prm, Eff, Bnd, Amb) and state, in one line each, what each controls.
2. A container runs as UID 0 but with the reduced Docker set from step 4. Which single capability, if added back, would most directly let a process load a kernel module or otherwise break out — and why is `CAP_SYS_ADMIN` nicknamed "the new root"?
3. The **bounding set** is a ceiling that a process cannot raise, even by execve of a file with file-capabilities. Why is dropping capabilities from the bounding set (not just the effective set) the security-relevant action for a container?

---

## Exercise 7 — seccomp, SELinux and AppArmor: the second wall

Capabilities gate *which* privileged operations are allowed; **seccomp** gates *which syscalls* are reachable at all, and **SELinux/AppArmor** apply mandatory access control (MAC) labels/profiles regardless of UID. Every real container stacks these.

1. Check the seccomp mode of your own shell and of a container process:

   ```bash
   grep Seccomp /proc/$$/status
   ```

   Expected on the host: `Seccomp:	0` (0 = disabled, 1 = SECCOMP_MODE_STRICT, 2 = SECCOMP_MODE_FILTER).

2. Start a container and inspect the syscall filter the runtime installed:

   ```bash
   podman run --rm -d --name secdemo busybox sleep 1000   # or docker
   PID=$(podman inspect -f '{{.State.Pid}}' secdemo)
   grep -E 'Seccomp|Seccomp_filters' /proc/$PID/status
   ```

   Expected — the runtime applied a filter:

   ```
   Seccomp:	2
   Seccomp_filters:	1
   ```

3. Prove the filter blocks dangerous syscalls. The default profile denies `unshare`/`mount` and similar. From inside a *default-profile* container, a `mount` attempt returns `Operation not permitted` even though you appear to be root. Compare against running the same container with `--security-opt seccomp=unconfined` (do this only to observe the difference, then stop it).

4. Detect the active MAC system.

   - **SELinux** (Fedora/RHEL):

     ```bash
     getenforce                 # Enforcing
     ps -eZ | grep -i container # container_t label on container processes
     ```

     Expected label form: `system_u:system_r:container_t:s0:c123,c456`. The unique `c123,c456` **MCS category pair** is what keeps two containers from touching each other's files even as root.

   - **AppArmor** (Debian/Ubuntu/SUSE):

     ```bash
     sudo aa-status
     ```

     Expected includes a container profile in enforce mode, e.g. `containers-default-0.<version>` or `docker-default`.

5. Stop the demo: `podman rm -f secdemo`.

**Comprehension check 7**

1. A container runs as UID 0 with `CAP_SYS_ADMIN` granted, but its seccomp profile denies the `mount` syscall. Can it mount a filesystem? Explain why capabilities and seccomp are *independent* gates.
2. SELinux labels container processes `container_t` with a unique MCS category pair per container. How does that stop a container that has read access to a host path from reading *another* container's files, even though both run as root?
3. The three mechanisms — seccomp, capabilities, MAC (SELinux/AppArmor) — are often described as "defense in depth." Give one attack that each layer independently blocks that the other two would not.

---

## Exercise 8 — The OCI runtime spec: run a container from a bundle with `runc`

Docker and Podman are high-level engines. Underneath, they hand a low-level **OCI runtime** (`runc`, `crun`) a *bundle*: a directory containing a root filesystem plus a `config.json` written to the **OCI Runtime Specification**. You will assemble that bundle yourself.

1. Create a bundle directory and generate the default `config.json`:

   ```bash
   mkdir -p ~/oci-bundle/rootfs
   cd ~/oci-bundle
   runc spec                 # writes ./config.json
   ls
   # config.json  rootfs
   ```

2. Populate `rootfs` with a real root filesystem by exporting a busybox image:

   ```bash
   CID=$(podman create busybox)         # or: docker create busybox
   podman export "$CID" | tar -C rootfs -xf -
   podman rm "$CID"
   ls rootfs                            # bin dev etc proc sys tmp usr var ...
   ```

3. Inspect the spec. Note how the isolation you built by hand is now *declared* as data:

   ```bash
   grep -A2 '"namespaces"' config.json | head
   grep -A5 'capabilities' config.json | head
   grep -A3 'linux' config.json | head
   ```

   The `config.json` lists a `namespaces` array (pid, network, ipc, uts, mount), a reduced `capabilities` block, a seccomp section, and cgroup `resources`. Everything from Exercises 1–7 is here as a manifest.

4. Set the process to a shell and disable the terminal for a non-interactive run by editing `config.json` (`.process.args` → `["sh"]`, `.process.terminal` → `false`), then run it:

   ```bash
   sudo runc run demo-oci
   ```

   You get a `sh` prompt inside the bundle. Verify the isolation `runc` set up for you:

   ```bash
   hostname                  # runc (the spec's default hostname)
   ps -ef                    # PID 1 is your sh
   id                        # uid=0, but reduced capabilities
   exit
   ```

5. From a second terminal, list running OCI containers and their state:

   ```bash
   sudo runc list
   # ID         PID    STATUS    BUNDLE                  ...
   # demo-oci   12345  running   /root/oci-bundle        ...
   ```

6. Relate this to the **image spec**. The busybox layer you exported came from an OCI *image* (a manifest + config + gzipped layer tarballs, content-addressed by SHA-256 digest). The runtime does not consume images directly — an engine *unpacks* image layers into the bundle's `rootfs` and *synthesizes* `config.json`.

**Comprehension check 8**

1. Distinguish the **OCI Image Specification** from the **OCI Runtime Specification**. What artifact does each one describe, and what component sits between them?
2. In step 3, `config.json` declared namespaces, capabilities, seccomp and cgroup limits as data. Why is this separation — declarative bundle vs. runtime that enforces it — what makes runtimes interchangeable (`runc` ↔ `crun` ↔ `youki`)?
3. OCI images are content-addressed by digest and built from stacked layers. What two operational properties (one about caching/transfer, one about integrity) does content-addressing give you for free?

---

## Exercise 9 — Containers vs full virtualization: gather the evidence

The objective asks you to explain how container virtualization *differs* from full virtualization and the security implications. Instead of memorizing it, collect the observable facts.

1. Confirm a container shares the **host kernel**. Inside any container:

   ```bash
   podman run --rm busybox uname -r
   uname -r     # on the host
   ```

   The two kernel versions are **identical** — a container cannot run a different kernel.

2. Confirm a VM does **not** share the kernel: a `libvirt`/KVM guest reports its *own* `uname -r`, independent of the host. (Conceptual — compare against a VM if you have one from Topic 351.)

3. Measure the boundary. A container's "PID 1" is a normal host process (Exercise 2); a VM's processes are invisible to the host kernel — the hypervisor only sees `vCPU` threads. Confirm the container side:

   ```bash
   podman run --rm -d --name cmp busybox sleep 300
   PID=$(podman inspect -f '{{.State.Pid}}' cmp)
   ps -o pid,comm -p "$PID"      # visible on the host!
   podman rm -f cmp
   ```

4. Reason about the attack surface. A container talks directly to the host kernel's full syscall interface (~350 syscalls), constrained only by seccomp/capabilities/MAC. A VM talks to a narrow virtual hardware interface (virtio) and a small hypervisor. This is why a kernel privilege-escalation bug is a **container escape** but usually not a **VM escape**.

**Comprehension check 9**

1. Fill in the trade-off: containers win on **_______** and **_______**; full VMs win on **_______** (isolation strength) because of **_______** (shared vs. separate kernel).
2. A zero-day in a Linux syscall handler is disclosed. Explain why every container on a node is potentially exposed, while VM guests on the same node likely are not.
3. "A container is a process, a VM is a machine." Using the facts you gathered in steps 1 and 3, justify that slogan precisely — name the kernel feature that makes a container *a process with a restricted view* rather than a separate machine.

---

<details>
<summary><strong>Answers</strong> (click to expand)</summary>

### Exercise 1

1. Shared inode of the namespace symlink under `/proc/<pid>/ns/`. Two processes are in the same namespace for a dimension iff `/proc/<pidA>/ns/<type>` and `/proc/<pidB>/ns/<type>` resolve to the **same inode number** (`ns:[<inode>]`). "Container membership" is per-dimension, not global.
2. The **`cgroup`** namespace. It does not isolate resources (cgroups themselves do that); it *virtualizes the view of the cgroup hierarchy* so a process sees its own cgroup as the root in `/proc/self/cgroup`, hiding the host's absolute paths.
3. Because on an unmodified host every process is a descendant of PID 1 (systemd/init) and inherits the *initial* namespaces. No one has called `unshare`/`clone(CLONE_NEW*)` yet, so there is exactly one namespace of each type, owned by PID 1.

### Exercise 2

1. Creating a PID namespace does not, by itself, remount `/proc`. `--fork` makes `unshare` fork a child that becomes **PID 1** of the new namespace (the first process placed in a PID namespace *is* its init); the parent stays outside. `--mount-proc` also creates a mount namespace and mounts a fresh `procfs`, so `/proc` reflects the *new* PID namespace rather than the host's — otherwise `ps` would still read the host's `/proc` and show every process.
2. You are UID 0 **only inside the user namespace**. The kernel maps inside-UID 0 to your real outside UID (via `/proc/<pid>/uid_map`, which `--map-root-user` writes). You have full capabilities *within that namespace's owned resources*, but no authority over host-owned objects: you cannot read `/etc/shadow`, load modules, or affect processes/files outside the namespaces you own. `CAP_*` checks against host resources fail.
3. User namespaces let an unprivileged user gain capabilities *inside* a new namespace, which is exactly what enables **rootless containers** (Podman rootless, unprivileged runc). But that same code path historically let unprivileged users reach kernel code that previously required root, so many namespace/privilege-escalation CVEs were reachable only through user namespaces — hence some distros restrict `unprivileged_userns_clone` / `user.max_user_namespaces`.

### Exercise 3

1. `docker exec` finds the container's PID 1, then calls `setns(2)` on each of that process's namespace file descriptors (`/proc/<pid>/ns/*`) — precisely what `nsenter` does — and executes your command inside them, optionally re-applying the container's cgroup, capabilities and seccomp profile.
2. You would create a `veth` pair, move one end into the container's **net** namespace, address both ends, and attach the host end to a bridge with NAT/routing (Exercise 4). The **network (`net`)** namespace owns the interface list, routing table, and firewall rules.
3. Executables inside the container often exist only in the container's **mount** namespace root filesystem (its image), not on the host. If you enter `--pid`/`--net` but not `--mount`, `nsenter` still sees the host's filesystem and the container-only binary is `No such file or directory`. Joining `--mount` (or using the container's rootfs) is required to run in-image tools.

### Exercise 4

1. A `veth` pair is a virtual "patch cable": two interfaces where a frame sent into one comes out the other. Put one end in the container's net namespace and the other on the host (attached to a bridge), and you have a point-to-point link crossing the namespace boundary — the canonical container↔host connection.
2. Named netns are kept alive by a **bind-mount** of the namespace file under `/var/run/netns/<name>` (a file reference holds the namespace even with no process). Anonymous namespaces from `unshare` exist only as long as a process (or an open fd / bind-mount) references them; when the last member exits, the kernel reaps the namespace.
3. (a) A **route** so the container's default gateway is the host (`ip route add default via 10.10.0.1` inside the ns) plus host IP forwarding (`net.ipv4.ip_forward=1`); (b) **source NAT / masquerade** on the host (`iptables/nftables ... MASQUERADE`) so the container's private `10.10.0.2` is rewritten to the host's routable address for return traffic. That is the essence of a CNI plugin like bridge+portmap.

### Exercise 5

1. The **no-internal-process rule**: a cgroup v2 node that has controllers enabled for its children may not simultaneously hold processes *and* have child cgroups competing for the same controller — non-root cgroups must be either a leaf holding processes or an inner node distributing controllers, not both. Controllers are made available to children by writing `+<ctrl>` to the **parent's** `cgroup.subtree_control`; that is why you enabled `+memory +cpu` at the root, then created `demo` as a leaf.
2. A cgroup-scoped OOM kill targets only processes *within that cgroup* when it exceeds `memory.max`, leaving the rest of the system untouched. A global OOM fires when the whole node is out of memory and the kernel picks a victim across everything. Per-cgroup limits give predictable, tenant-local failure instead of a random neighbor being killed — essential for multi-tenant nodes.
3. **`cpu.weight`** (default 100, range 1–10000) sets a *proportional share* under contention — a guarantee relative to siblings — whereas `cpu.max` sets a hard *ceiling*. In Kubernetes, a CPU **request** maps to `cpu.weight` (guaranteed share / scheduling), and a CPU **limit** maps to `cpu.max` (throttling ceiling).

### Exercise 6

1. **Inheritable (Inh)** — caps preserved across `execve` to a program that also marks them inheritable; **Permitted (Prm)** — the superset a process *may* enable; **Effective (Eff)** — the caps actually used for permission checks *right now*; **Bounding (Bnd)** — a ceiling that caps can never exceed and can only shrink; **Ambient (Amb)** — caps preserved across `execve` of non-privileged (non-file-cap) binaries, subject to Prm∩Inh.
2. **`CAP_SYS_MODULE`** most directly loads kernel modules; but the classic escape enabler is **`CAP_SYS_ADMIN`**, nicknamed "the new root" because it gates an enormous, ill-defined set of operations (mount, pivot_root, BPF, namespace/quota/keyring administration, etc.), so granting it effectively hands over most of root's real power and is a common breakout vector.
3. The bounding set is a hard ceiling the process cannot raise — not even a setuid/file-capability binary launched via `execve` can grant a capability absent from Bnd. Dropping from Bnd therefore makes the capability *permanently unreachable* for that process and all its children, which is the durable security property; dropping only from Eff can be re-raised from Prm.

### Exercise 7

1. **No.** With `CAP_SYS_ADMIN` the *capability* check for `mount(2)` passes, but the **seccomp** filter rejects the syscall before it executes, returning `EPERM`/killing the thread. Capabilities and seccomp are checked at different points: seccomp filters the syscall *entry* by number/arguments regardless of privilege; capabilities are checked *inside* the syscall handler. A deny at either gate stops the operation.
2. SELinux enforces **Mandatory Access Control** by label, independent of UID. Each container gets a unique **MCS** category pair (e.g. `s0:c123,c456`); a process labeled with one category set cannot access files labeled with a different set, so even root-in-container-A (`c123,c456`) is denied access to container-B's files (`c789,c012`). DAC UID checks are irrelevant to the MAC decision.
3. Examples: **seccomp** blocks reaching a vulnerable/obscure syscall (e.g. `keyctl`, `userfaultfd`) even if UID and caps allow it. **Capabilities** block a privileged operation like binding a raw socket (`CAP_NET_RAW`) even if the syscall is allowed. **MAC (SELinux/AppArmor)** blocks access to a specific file/path/port by label/profile even when UID 0 and all caps and syscalls are permitted — e.g. reading a host file the container's type isn't allowed to touch.

### Exercise 8

1. The **Image Spec** describes a *container image at rest*: a manifest, a config (env, entrypoint, layer order), and content-addressed layer blobs — the distributable, cacheable artifact. The **Runtime Spec** describes a *filesystem bundle* (`config.json` + `rootfs`) and how to *run* it (namespaces, caps, cgroups, seccomp). The component between them is the **container engine** (Docker/Podman/containerd), which unpacks image layers into a `rootfs` and synthesizes `config.json`.
2. Because the bundle is pure declarative data, any runtime that implements the Runtime Spec can consume the same `config.json`+`rootfs` and produce the same container. The engine doesn't care whether `runc` (Go), `crun` (C) or `youki` (Rust) enforces it — they are drop-in interchangeable, which is the whole point of the standard.
3. (a) **Deduplication & efficient transfer**: identical layers/blobs share the same digest, so they are stored and pulled once and cached across images. (b) **Integrity / tamper-evidence**: the digest *is* the SHA-256 of the content, so any change alters the digest — you can verify a pulled blob matches what the manifest references, enabling signing and reproducible references (`@sha256:...`).

### Exercise 9

1. Containers win on **startup speed / density (low overhead)** and **resource efficiency (shared kernel, no guest OS)**; full VMs win on **isolation strength** because of **a separate guest kernel and a narrow hypervisor/virtual-hardware boundary** (vs. the container's shared host kernel).
2. Every container issues syscalls directly against the *same* host kernel; a kernel syscall zero-day is reachable from inside any container whose seccomp/caps profile doesn't happen to block that path — a potential container escape. VM guests reach the host only through the hypervisor's narrow virtual-hardware interface, so a *guest-kernel* bug stays inside the guest and does not touch the host kernel or its neighbors.
3. Steps 1 (identical `uname -r`) and 3 (container PID 1 is a visible host process) show a container is not a separate machine: it runs on the host kernel and its "init" is an ordinary host-scheduled process. **Namespaces** (with cgroups + caps/seccomp/MAC) give that process a *restricted view and resource budget*, but it is still a host process — "a process with a restricted view," whereas a VM boots its own kernel behind a hardware boundary and is "a machine."

</details>

---

### Sources

- LPI Exam 305-300 Objectives (v3.0), Topic 352.1 — <https://www.lpi.org/our-certifications/exam-305-objectives/>
- `namespaces(7)`, `cgroups(7)`, `capabilities(7)`, `user_namespaces(7)`, `seccomp(2)`, `unshare(1)`, `nsenter(1)`, `ip-netns(8)` — Linux man-pages project: <https://man7.org/linux/man-pages/>
- Control Group v2 — Linux kernel documentation: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- OCI Runtime Specification — <https://github.com/opencontainers/runtime-spec/blob/main/spec.md>
- OCI Image Specification — <https://github.com/opencontainers/image-spec/blob/main/spec.md>