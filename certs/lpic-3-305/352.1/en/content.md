# 352.1 Container Virtualization Concepts

> **Exam:** LPIC-3 305-300 (version 3.0) · **Topic weight:** 11.67
> **Profile:** SRE / Platform Architect — production-grade internal mechanics, trade-offs, and diagnostics.

---

## 1. The production problem: what "container virtualization" actually virtualizes

A container is **not a lightweight VM**. That mental model breaks the moment you have to debug a shared-kernel failure at 03:00. The precise statement is:

> A container is a **process (or process tree) whose view of the system is restricted** by kernel features — namespaces, control groups, capabilities, and mandatory access control — while it continues to run **directly on the host kernel**, with no hardware emulation and no guest kernel.

Everything in this topic is a consequence of that single sentence. There is no hypervisor, no guest OS, no vCPU. `docker run`, `podman run`, `lxc-start`, and a Kubernetes Pod all ultimately call the same kernel syscalls: `clone()`/`unshare()` (namespaces), `write()` into a cgroup filesystem, `capset()` (capabilities), `prctl(PR_SET_SECCOMP, …)` (seccomp), and an LSM hook (SELinux/AppArmor).

### 1.1 The isolation spectrum

```
weaker isolation ──────────────────────────────────────────► stronger isolation
 process        chroot          namespaces+cgroups        gVisor / Kata        full VM (KVM)
 (shared FS,    (FS root only)  ("the container")         (userspace kernel /  (separate guest
  shared PID)                                              microVM)             kernel + vCPUs)
```

The architectural decision the platform team makes is *where on this spectrum a workload sits*, and that decision is driven by the **threat model and the density target**, not by fashion.

### 1.2 Containers vs virtual machines — the trade-off that defines the topic

| Dimension | Containers (shared kernel) | Virtual machines (KVM/Xen) |
|---|---|---|
| Isolation boundary | Kernel syscall surface (~350 syscalls) | Hardware virtualization (VT-x/AMD-V), narrow hypercall surface |
| Kernel | **Shared** with host — one kernel CVE = shared blast radius | Independent guest kernel per VM |
| Boot / start time | 10–100 ms (fork + namespace setup) | seconds to tens of seconds (firmware → bootloader → kernel → init) |
| Memory overhead | ~MB (no guest kernel, page cache shared) | ~100s MB per guest (guest kernel + page cache duplication) |
| Density (per host) | Hundreds to thousands | Tens |
| Live migration | Immature (CRIU, checkpoint/restore) | Mature (KVM live migration) |
| Kernel version per workload | **Impossible** — all share host kernel | Each VM picks its own kernel |
| Attack surface for escape | Entire kernel syscall + `/proc` + `/sys` + driver surface | VMM device model + hypercall ABI |
| Right when… | Density, fast scaling, homogeneous kernel needs, 12-factor apps | Hard multi-tenant isolation, different kernels, untrusted code |

**The production consequence:** A container escape is a **kernel privilege escalation**. Dirty COW (CVE-2016-5195), `runc`'s CVE-2019-5736 (overwriting the host `runc` binary via `/proc/self/exe`), and the `waitid()` CVE-2017-5123 all let a container reach the host precisely because there is one kernel. This is *why* the rest of this topic exists — namespaces alone are not a security boundary; the security posture is the **layered combination** of namespaces + dropped capabilities + seccomp + an LSM. Sandboxed runtimes (gVisor, Kata Containers) exist specifically to re-introduce a stronger boundary for untrusted tenants while keeping the container UX.

---

## 2. The kernel primitives

### 2.1 Namespaces — *what a process can see*

A namespace wraps a global system resource in an abstraction so that processes inside the namespace have their own isolated instance. There are **eight** namespace types as of modern kernels (5.6+):

| Namespace | `clone`/`unshare` flag | Isolates | Introduced | Container relevance |
|---|---|---|---|---|
| **Mount** (`mnt`) | `CLONE_NEWNS` | Filesystem mount points | 2.4.19 | Private rootfs, `/proc`, `/sys`, tmpfs |
| **UTS** | `CLONE_NEWUTS` | Hostname, NIS domain | 2.6.19 | Per-container `hostname` |
| **IPC** | `CLONE_NEWIPC` | System V IPC, POSIX message queues | 2.6.19 | Isolated shared memory / semaphores |
| **PID** | `CLONE_NEWPID` | Process IDs | 2.6.24 | Container has its own PID 1; can't see host PIDs |
| **Network** (`net`) | `CLONE_NEWNET` | Interfaces, routing, `iptables`, ports, `/proc/net` | 2.6.29 | Per-container network stack (veth, loopback) |
| **User** | `CLONE_NEWUSER` | UID/GID mappings, capabilities | 3.8 | **Rootless containers** — UID 0 inside maps to unprivileged UID outside |
| **Cgroup** | `CLONE_NEWCGROUP` | Cgroup root directory view | 4.6 | Hides host cgroup paths from container |
| **Time** | `CLONE_NEWTIME` | `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME` offsets | 5.6 | Per-container clock offset (CRIU restore, testing) |

The **user namespace** is the linchpin of modern container security. It is the only namespace an unprivileged user can create, and it is what makes UID 0 inside a container map to, say, UID 100000 on the host — so a container "root" that escapes owns nothing.

#### Inspecting namespaces on a live system

Every process exposes its namespace membership as magic symlinks under `/proc/<pid>/ns/`. Two processes in the same namespace share the same inode number.

```console
$ ls -l /proc/self/ns/
total 0
lrwxrwxrwx 1 user user 0 Jun 14 10:22 cgroup -> 'cgroup:[4026531835]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 ipc -> 'ipc:[4026531839]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 mnt -> 'mnt:[4026531841]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 net -> 'net:[4026531840]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 pid -> 'pid:[4026531836]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 time -> 'time:[4026531834]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 user -> 'user:[4026531837]'
lrwxrwxrwx 1 user user 0 Jun 14 10:22 uts -> 'uts:[4026531838]'
```

The `lsns` tool enumerates namespaces and the processes bound to them:

```console
$ sudo lsns --type net
        NS TYPE NPROCS   PID USER   NETNSID NSFS                           COMMAND
4026531840 net     241     1 root unassigned                                /sbin/init
4026532297 net       3  8912 root         0 /run/docker/netns/1a2b3c4d5e6f /pause
```

Create a container "by hand" with `unshare` to prove there is no magic — this is what a runtime does under the covers:

```console
$ sudo unshare --pid --fork --mount-proc --uts --net --ipc --mount /bin/bash
root@host:/# hostname isolated-demo
root@host:/# hostname
isolated-demo
root@host:/# ps aux
USER   PID %CPU %MEM    VSZ   RSS TTY  STAT START  TIME COMMAND
root     1  0.0  0.0  10236  3200 pts/0 S   10:31 0:00 /bin/bash
root     9  0.0  0.0  11container 3400 pts/0 R+  10:31 0:00 ps aux
root@host:/# ip addr
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
```

Note: PID 1 is `bash`, the hostname is private, and the network namespace has *only* a down loopback — no interfaces, no routes. That empty net namespace is exactly what a CNI plugin later populates.

Enter an existing container's namespaces with `nsenter` — the canonical "I need a debugging shell inside a running container that has no shell" trick:

```console
$ CPID=$(docker inspect --format '{{.State.Pid}}' web)
$ sudo nsenter --target "$CPID" --mount --uts --ipc --net --pid --cgroup /bin/sh
/ # ip -br addr
lo               UNKNOWN        127.0.0.1/8
eth0@if12        UP             172.17.0.2/16
```

### 2.2 Control groups (cgroups) — *what a process can consume*

Namespaces control *visibility*; **cgroups control resource accounting and limits** — CPU, memory, block I/O, PIDs, devices. Without cgroups a container could fork-bomb or OOM the entire host; namespaces would happily isolate its *view* while it consumed every last page of RAM.

#### cgroup v1 vs cgroup v2 — a real migration decision

| Aspect | cgroup v1 | cgroup v2 (unified) |
|---|---|---|
| Hierarchy | **Multiple** hierarchies, one per controller (`/sys/fs/cgroup/memory`, `/cpu`, …) | **Single unified** hierarchy (`/sys/fs/cgroup`) |
| A process can be in… | Different cgroups for different controllers (incoherent) | Exactly one cgroup, all controllers | 
| Controller enablement | Implicit | Explicit via `cgroup.subtree_control` |
| Memory+swap accounting | `memory.memsw.limit_in_bytes` | `memory.max` + `memory.swap.max` (separate) |
| Pressure stall info (PSI) | ✗ | ✓ (`cpu.pressure`, `memory.pressure`, `io.pressure`) |
| rootless / delegation | Poor | Designed for safe delegation to unprivileged users |
| Default on | Legacy distros | Fedora 31+, RHEL 9, Debian 11+, Ubuntu 22.04+ |

Modern platforms should be on **cgroup v2**. Kubernetes requires it for several features (e.g. `MemoryQoS`, proper OOM behavior), and rootless Podman needs it for CPU/memory delegation.

Verify which version a host runs:

```console
$ stat -fc %T /sys/fs/cgroup/
cgroup2fs           # cgroup v2 unified hierarchy
# ("tmpfs" would indicate cgroup v1 or hybrid)

$ mount | grep cgroup
cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot)
```

Inspect the cgroup a Docker container lives in (cgroup v2 + systemd driver):

```console
$ systemd-cgls --no-pager | grep -A3 docker
│ └─docker-1a2b3c4d5e6f7890abcdef.scope …
│   ├─8912 /pause
│   └─8977 nginx: master process nginx -g daemon off;

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/memory.max
536870912          # 512 MiB hard limit (from `docker run -m 512m`)

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/memory.current
41947136           # ~40 MiB currently in use

$ cat /sys/fs/cgroup/system.slice/docker-1a2b3c4d5e6f7890abcdef.scope/cpu.max
50000 100000       # 50 ms quota per 100 ms period → 0.5 CPU
```

**Diagnostic that matters in production — the OOM kill.** When a container exceeds `memory.max`, the kernel OOM-killer terminates a process *inside that cgroup*, not host-wide. The workload sees exit code 137 (128 + SIGKILL 9):

```console
$ dmesg | tail -3
[91234.5] Memory cgroup out of memory: Killed process 8977 (nginx) total-vm:...
[91234.5] oom_reaper: reaped process 8977 (nginx), now anon-rss:0kB...

$ docker inspect web --format '{{.State.OOMKilled}} {{.State.ExitCode}}'
true 137
```

### 2.3 Capabilities — *dividing the monolithic root*

Traditional UNIX has a binary privilege model: UID 0 (root) bypasses all kernel permission checks, everyone else does not. **Capabilities** shatter that monolith into ~40 distinct privileges (`CAP_*`) that can be granted or dropped independently. This is central to container hardening: a container should run with the **minimum capability set**, not full root.

The capabilities most relevant to containers:

| Capability | Grants | Container risk if kept |
|---|---|---|
| `CAP_SYS_ADMIN` | The "new root" — mount, `setns`, `pivot_root`, many others | Near-total escape vector; **drop it** |
| `CAP_NET_ADMIN` | Configure interfaces, routing, `iptables` | Manipulate host networking if `net` ns shared |
| `CAP_NET_RAW` | Raw/packet sockets (`ping`, ARP spoofing) | L2 spoofing on shared networks |
| `CAP_SYS_PTRACE` | `ptrace()` other processes | Inspect/inject into host processes if `pid` ns shared |
| `CAP_SYS_MODULE` | `init_module()` — load kernel modules | Immediate host compromise; **never grant** |
| `CAP_DAC_OVERRIDE` | Bypass file read/write/execute permission checks | Read any host file if mounts leak |
| `CAP_SETUID`/`CAP_SETGID` | Arbitrary UID/GID changes | Privilege pivots |
| `CAP_MKNOD` | Create device nodes | Craft device access to host disks |
| `CAP_CHOWN` | Change file ownership | — |
| `CAP_KILL` | Signal any process | — |

Docker's **default drops** most dangerous capabilities and retains a small bounded set (`CAP_CHOWN`, `CAP_NET_BIND_SERVICE`, `CAP_SETUID`, `CAP_SETGID`, `CAP_NET_RAW`, etc.). It notably drops `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, and `CAP_SYS_PTRACE`.

Inspect and manipulate a container's capabilities:

```console
$ docker run --rm alpine grep Cap /proc/self/status
CapInh: 0000000000000000
CapPrm: 00000000a80425fb
CapEff: 00000000a80425fb
CapBnd: 00000000a80425fb     # bounding set — the ceiling of what can ever be held
CapAmb: 0000000000000000

$ capsh --decode=00000000a80425fb
0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,
cap_mknod,cap_audit_write,cap_setfcap
```

Hardening pattern — **drop everything, add back only what is needed**:

```console
$ docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE alpine \
    grep CapEff /proc/self/status
CapEff: 0000000000000400     # only CAP_NET_BIND_SERVICE (bit 10)
```

Kubernetes expresses the same intent declaratively in a Pod's `securityContext` (see §7 manifest).

### 2.4 seccomp — *restricting the syscall surface*

Namespaces, cgroups, and capabilities restrict *what resources* a process touches. **seccomp** (secure computing mode) restricts *which system calls it may issue at all*, filtering by syscall number and argument values via a BPF program (`SECCOMP_MODE_FILTER`). This is the single largest reduction of the kernel attack surface available to a container.

The Linux kernel exposes ~350 syscalls. Docker's **default seccomp profile** blocks ~44 dangerous ones (`reboot`, `swapon`, `mount`, `init_module`, `kexec_load`, `bpf`, `ptrace` under some configs, keyring ops, etc.) and allows the rest — a deny-by-exception model tuned for compatibility.

Verify seccomp is active on a container (`Seccomp: 2` = filter mode; `0` = disabled):

```console
$ docker run --rm alpine grep Seccomp /proc/self/status
Seccomp:	2
Seccomp_filters:	1

$ docker run --rm --security-opt seccomp=unconfined alpine grep Seccomp /proc/self/status
Seccomp:	0            # DANGER: no syscall filtering
```

A minimal custom profile (OCI seccomp JSON) with a default-deny posture:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "brk", "capget", "capset", "chdir",
        "clock_gettime", "close", "connect", "epoll_create1", "epoll_ctl",
        "epoll_pwait", "execve", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "listen", "mmap", "mprotect",
        "munmap", "nanosleep", "openat", "read", "recvfrom", "rt_sigaction",
        "rt_sigprocmask", "sendto", "set_robust_list", "set_tid_address",
        "setgid", "setgroups", "setuid", "socket", "stat", "write"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

```console
$ docker run --rm --security-opt seccomp=./minimal.json myapp:latest
# any syscall not in the allowlist returns EPERM (errno 1) to the workload
```

**Diagnostic:** a workload that mysteriously fails with `Operation not permitted` on an innocuous-looking operation is frequently a seccomp denial. Trace it:

```console
$ strace -f -e trace=all myapp 2>&1 | grep EPERM
mount("/dev/sdb", "/mnt", ...) = -1 EPERM (Operation not permitted)
```

### 2.5 Mandatory Access Control — SELinux and AppArmor (LSM)

Capabilities and seccomp are DAC-adjacent kernel controls. **SELinux** and **AppArmor** are **Linux Security Modules (LSM)** implementing *mandatory* access control: policy the process cannot override even as root. They are the outermost containment layer and the difference between "the container escaped namespaces" and "the escape hit a `avc: denied` wall."

| | SELinux | AppArmor |
|---|---|---|
| Model | **Label/type enforcement** — every process, file, port carries a security context | **Path-based** profiles |
| Config | Complex policy language; type transitions | Simpler per-binary profiles |
| Default distro | RHEL/Fedora/CentOS Stream | Ubuntu/Debian/SUSE |
| Container integration | `container_t` type, MCS categories (`s0:c123,c456`) per container | `docker-default` profile |
| Granularity | Very fine (types, categories, booleans) | Path/capability oriented |
| Failure signature | `avc: denied` in audit log | `apparmor="DENIED"` in dmesg |

**SELinux for containers** uses Multi-Category Security (MCS): each container gets a unique category pair, so container A (`s0:c1,c2`) cannot touch container B's files (`s0:c3,c4`) even if a mount leaks — the labels don't match.

```console
$ ps -eZ | grep -i container
system_u:system_r:container_t:s0:c123,c456  8977 ?  00:00:01 nginx

$ ls -Z /var/lib/docker/volumes/data/_data
system_u:object_r:container_file_t:s0:c123,c456  index.html

# Diagnose a denial (the classic "permission denied despite correct UNIX perms"):
$ sudo ausearch -m avc -ts recent
type=AVC msg=audit(...): avc:  denied  { read } for  pid=8977 comm="nginx"
  name="secret.txt" dev="dm-0" ino=12345
  scontext=system_u:system_r:container_t:s0:c123,c456
  tcontext=unconfined_u:object_r:admin_home_t:s0 tclass=file permissive=0
```

That `tcontext=admin_home_t` mismatch is why a bind-mounted host file returns "Permission denied" inside a container even with `chmod 777` — the fix is `:Z`/`:z` (relabel) on the mount or an explicit `chcon`, **not** `chmod`.

**AppArmor** equivalent:

```console
$ docker run --rm --security-opt apparmor=docker-default alpine touch /etc/x
touch: /etc/x: Permission denied
$ dmesg | grep apparmor | tail -1
audit: apparmor="DENIED" operation="mknod" profile="docker-default"
  name="/etc/x" pid=9123 comm="touch" requested_mask="c" denied_mask="c"
```

**Layered defense summary** — a hardened container is the *intersection* of all five controls:

```
        ┌─────────────── Host kernel (shared) ───────────────┐
Namespaces │  restrict what the process SEES                  │
Cgroups    │  restrict what the process CONSUMES              │
Capabilities│ restrict which ROOT PRIVILEGES it holds         │
Seccomp    │  restrict which SYSCALLS it may issue            │
SELinux/AA │  restrict via MANDATORY policy (cannot override) │
        └─────────────────────────────────────────────────────┘
```

---

## 3. System containers vs application containers

The exam explicitly distinguishes the two container *philosophies*. They use identical kernel primitives but present opposite abstractions.

| | **Application container** | **System container** |
|---|---|---|
| Runs | A single service/process (PID 1 = the app) | A full userspace / init system (systemd/OpenRC) — behaves like a lightweight VM |
| Init | Usually none (or a minimal `tini`/`dumb-init` reaper) | Real init managing many services |
| Lifecycle | Ephemeral, immutable, rebuilt not patched | Long-lived, "pet"-like, updated in place |
| Image | Layered (OCI image), minimal (`scratch`, `alpine`, `distroless`) | Full distro rootfs |
| Canonical tools | **Docker, Podman**, containerd | **LXC, LXD/Incus**, systemd-nspawn |
| Filesystem | OverlayFS layered image | Often a full directory tree or block device |
| Mental model | "A process with a private view" | "A machine without its own kernel" |
| Fits | 12-factor microservices, CI, functions | Legacy multi-service apps, dev sandboxes, CI runners needing systemd |

**How each leverages the kernel primitives:**

- **LXC** (system) creates all namespaces, applies a cgroup, drops capabilities, and boots the distro's init inside. `lxc.conf` directly exposes `lxc.cgroup2.*`, `lxc.cap.drop`, `lxc.seccomp.profile`, `lxc.apparmor.profile` — you configure the primitives one-to-one.
- **Docker/Podman** (application) do the same but wrap it behind an image + layered filesystem + a single-process entrypoint, and add the OCI image/distribution formats on top.

```console
# System container (LXC) — a whole Debian userspace
$ sudo lxc-create -n sysbox -t download -- -d debian -r bookworm -a amd64
$ sudo lxc-start -n sysbox
$ sudo lxc-attach -n sysbox -- ps aux | head
USER  PID  … COMMAND
root    1  … /sbin/init                    # <-- real systemd as PID 1
root  142  … /lib/systemd/systemd-journald
root  178  … /usr/sbin/sshd -D
message+ 201 … /usr/bin/dbus-daemon --system
$ sudo lxc-ls -f
NAME    STATE   AUTOSTART GROUPS IPV4       IPV6
sysbox  RUNNING 0         -      10.0.3.42  -

# Application container (Docker) — one process
$ docker run -d --name web nginx:1.27-alpine
$ docker top web
UID   PID    CMD
root  9101   nginx: master process nginx -g daemon off;   # <-- app is PID 1
101   9140   nginx: worker process
```

Podman's rootless daemonless model is the modern application-container answer to Docker's root daemon: it runs entirely in a **user namespace**, needs no privileged daemon, and integrates with systemd via Quadlet — important for the "reduce the root attack surface" architectural goal.

---

## 4. The OCI runtime stack — from `docker run` to a running process

This is the heart of 352.1's "principle of runc / CRI-O / containerd / OCI" objectives. Modern container platforms are **layered**, and each layer is a spec-defined, swappable component.

### 4.1 The Open Container Initiative (OCI)

The OCI is a Linux Foundation project that standardizes container formats so the ecosystem is not locked to Docker. Three specifications:

| OCI spec | Defines | Concretely |
|---|---|---|
| **runtime-spec** | The on-disk **bundle** (a `config.json` + a `rootfs/`) and the lifecycle a runtime must implement (`create`, `start`, `kill`, `delete`) | What `runc` consumes |
| **image-spec** | The **image** format: layered tarballs, the manifest, the config, content-addressable digests (`sha256:…`) | What `docker build` produces, what registries store |
| **distribution-spec** | The **registry HTTP API** for push/pull (`/v2/…`) | How `docker pull` talks to Docker Hub / Quay / ECR |

An OCI **runtime bundle** is startlingly simple — this is what all the tooling ultimately manufactures:

```console
$ mkdir -p bundle/rootfs && cd bundle
$ docker export $(docker create alpine) | tar -C rootfs -xf -
$ runc spec                    # generates a default config.json
$ ls
config.json  rootfs
```

Excerpt of the generated `config.json` (the runtime-spec object) showing the primitives from §2 encoded declaratively:

```json
{
  "ociVersion": "1.2.0",
  "process": {
    "terminal": true,
    "user": { "uid": 0, "gid": 0 },
    "args": ["sh"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/",
    "capabilities": {
      "bounding":  ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"],
      "effective": ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"],
      "permitted": ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_AUDIT_WRITE"]
    },
    "noNewPrivileges": true
  },
  "root": { "path": "rootfs", "readonly": true },
  "hostname": "runc-demo",
  "linux": {
    "namespaces": [
      { "type": "pid" }, { "type": "network" }, { "type": "ipc" },
      { "type": "uts" }, { "type": "mount" }, { "type": "cgroup" }
    ],
    "maskedPaths":   ["/proc/kcore", "/proc/keys", "/sys/firmware"],
    "readonlyPaths": ["/proc/sys", "/proc/sysrq-trigger", "/proc/irq"],
    "resources": {
      "memory": { "limit": 536870912 },
      "cpu": { "quota": 50000, "period": 100000 }
    },
    "seccomp": { "defaultAction": "SCMP_ACT_ERRNO", "syscalls": [ /* … */ ] }
  }
}
```

### 4.2 runc — the reference OCI runtime

`runc` is the small Go binary (extracted from Docker in 2015) that turns a bundle into a running process by making the actual kernel calls. It is **the reference implementation of the runtime-spec**. It does *one* thing: create, start, and reap a container from a bundle, then exit — it is not a daemon.

```console
$ sudo runc run mycontainer
/ # cat /etc/hostname
runc-demo
/ # exit

# Lifecycle can be driven explicitly:
$ sudo runc create mycontainer
$ sudo runc list
ID            PID    STATUS   BUNDLE          CREATED             OWNER
mycontainer   9312   created  /root/bundle    2026-06-14T…Z       root
$ sudo runc start mycontainer
$ sudo runc ps mycontainer
UID   PID    CMD
0     9312   sh
$ sudo runc kill mycontainer KILL
$ sudo runc delete mycontainer
```

**crun** is a faster C implementation of the same runtime-spec (default in Podman/CRI-O on many distros) — lower memory and startup latency, and better cgroup v2 support. Because both honor the OCI runtime-spec, they are **drop-in interchangeable** — this is the entire point of the OCI.

### 4.3 containerd and CRI-O — the high-level runtimes

`runc` is too low-level to build a platform on: it has no image management, no pull, no snapshots, no API, no networking. That is the job of a **high-level runtime**:

| | **containerd** | **CRI-O** |
|---|---|---|
| Origin | CNCF (graduated), extracted from Docker | Red Hat, purpose-built for Kubernetes |
| Scope | General-purpose: images, snapshots, content store, gRPC API; used by Docker, Kubernetes, cloud runtimes | **Kubernetes-only** — implements exactly the CRI, nothing more |
| Image mgmt | Yes (pull/push, content store, snapshotters) | Yes (via containers/image + containers/storage) |
| Low-level runtime | `runc` (default), shim per container | `runc`/`crun` via OCI |
| CRI | Via built-in CRI plugin | Is *only* a CRI implementation |
| Extra CLI | `ctr` (debug), `nerdctl` (Docker-like) | `crictl` (CRI debug) |

Both sit **between** the orchestrator and `runc`, and both use a **shim** process (`containerd-shim-runc-v2`) per container so the container's lifetime is decoupled from the daemon's — you can restart containerd without killing running containers (this is precisely the architecture that fixed the old Docker "restart the daemon, kill every container" problem).

```console
# containerd's low-level debug CLI (namespace-scoped)
$ sudo ctr --namespace k8s.io containers list
CONTAINER       IMAGE                              RUNTIME
1a2b3c...       docker.io/library/nginx:1.27       io.containerd.runc.v2

$ sudo ctr --namespace k8s.io tasks list
TASK        PID     STATUS
1a2b3c...   9887    RUNNING

# The shim, per container, reparented to PID 1 — survives containerd restarts:
$ ps -ef | grep containerd-shim
root  9860  1  containerd-shim-runc-v2 -namespace k8s.io -id 1a2b3c... -address /run/...
```

### 4.4 The Container Runtime Interface (CRI)

Kubernetes does **not** talk to `runc` or even to Docker directly. The **kubelet** speaks the **CRI** — a gRPC API (`RuntimeService` + `ImageService`) — to whatever runtime implements it (containerd via its CRI plugin, or CRI-O). This is why **"Dockershim" was removed in Kubernetes 1.24**: Docker never spoke CRI natively, so the kubelet needed a shim; once containerd (which Docker itself uses) spoke CRI directly, the shim was redundant.

```
┌────────────┐   CRI (gRPC)   ┌───────────────┐   OCI runtime-spec   ┌──────┐   syscalls   ┌────────┐
│  kubelet   │───────────────►│ containerd /  │─────────────────────►│ runc │─────────────►│ kernel │
│ (K8s node) │                │    CRI-O      │  (shim per container) │/crun │  namespaces  │ (host) │
└────────────┘                └───────────────┘                       └──────┘  cgroups…    └────────┘
                                     │
                                     ▼ pulls via OCI distribution-spec, unpacks OCI image-spec
                               ┌───────────┐
                               │ registry  │
                               └───────────┘
```

`crictl` is the CRI-level debugging tool — vendor-neutral across containerd and CRI-O:

```console
$ sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps
CONTAINER     IMAGE          CREATED         STATE    NAME    POD ID        POD
7f3a9b2c1d…   nginx:1.27     3 minutes ago   Running  web     a1b2c3d4e5…   web-pod
$ sudo crictl pods
POD ID        CREATED         STATE    NAME       NAMESPACE   ATTEMPT   RUNTIME
a1b2c3d4e5…   3 minutes ago   Ready    web-pod    default     0         (default)
$ sudo crictl inspect 7f3a9b2c1d | jq '.info.runtimeSpec.linux.namespaces'
```

---

## 5. Container networking — CNI awareness

The exam requires *awareness* of the **Container Network Interface (CNI)** — a CNCF spec that decouples the runtime from the network implementation. A CNI plugin is an executable that the runtime invokes with `ADD`/`DEL`/`CHECK` commands and a JSON config, and whose job is to wire the container's (empty) network namespace into a network.

The default docker `bridge` model illustrates the primitives; CNI generalizes it:

```
Container netns                Host
┌──────────────┐              ┌────────────────────────────────┐
│ eth0         │──veth pair──►│ vethXXXX ── docker0 (bridge) ──►│── NAT (iptables MASQUERADE) ──► uplink
│ 172.17.0.2/16│              │              172.17.0.1/16      │
└──────────────┘              └────────────────────────────────┘
```

```console
$ docker run -d --name web nginx:alpine
$ docker exec web ip -br addr
lo        UNKNOWN 127.0.0.1/8
eth0@if14 UP      172.17.0.2/16
$ ip -br link | grep veth
veth9a1b2c@if13 UP  ...      # host end of the veth pair
$ bridge link | grep veth
14: veth9a1b2c … master docker0 state forwarding

# The host-side NAT rule that gives the container egress:
$ sudo iptables -t nat -L POSTROUTING -n | grep 172.17
MASQUERADE  all  --  172.17.0.0/16   0.0.0.0/0
```

**CNI network models — awareness table:**

| Model | Mechanism | Example plugins |
|---|---|---|
| **Bridge / veth** | L2 bridge + veth pairs (single host) | `bridge`, Docker default |
| **Overlay (encapsulation)** | VXLAN/Geneve tunnels across hosts | Flannel (VXLAN), Cilium (VXLAN/Geneve) |
| **Routed / BGP (L3)** | Pod subnets advertised via BGP, no encap | Calico |
| **eBPF datapath** | Kernel eBPF replaces iptables for routing/policy/LB | Cilium |
| **macvlan/ipvlan** | Container gets an address directly on the physical L2 | `macvlan`, `ipvlan` |

A minimal CNI config (the JSON the runtime hands the plugin):

```json
{
  "cniVersion": "1.0.0",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.22.0.0/16",
    "routes": [{ "dst": "0.0.0.0/0" }]
  }
}
```

Kubernetes also layers **NetworkPolicy** on top of CNI (enforced by policy-aware plugins like Calico/Cilium) to segment east-west traffic — the container equivalent of a firewall.

---

## 6. Orchestration and service mesh — awareness

**Orchestration** solves the problem that raw containers do not: scheduling across a fleet, self-healing, rolling updates, service discovery, declarative desired state, and horizontal scaling. Kubernetes is the de-facto standard; the smallest deployable unit is a **Pod** (one or more containers sharing net + IPC + UTS namespaces via a `pause` container that holds the namespaces open).

| Concern | Raw container | Orchestrator (Kubernetes) |
|---|---|---|
| Scheduling | Manual, one host | Bin-packing across nodes (scheduler) |
| Healing | None | Restart, reschedule on node loss |
| Scaling | Manual | HPA / replicas, declarative |
| Networking | Per-host | Cluster-wide flat network + Services + DNS |
| Config/secrets | Env/files | ConfigMap / Secret objects |
| Desired state | Imperative | Declarative reconciliation loop |

A **service mesh** (Istio, Linkerd, Cilium Service Mesh) addresses *service-to-service* concerns that orchestration leaves open: mutual-TLS encryption, L7 traffic management (canary, retries, timeouts, circuit breaking), and deep observability. Classic meshes inject a **sidecar proxy** (Envoy) into each Pod; the proxy intercepts all traffic transparently. Newer designs (Istio ambient, Cilium) move the datapath to a per-node eBPF/proxy layer to avoid the per-Pod sidecar tax.

```
Pod A                          Pod B
┌───────────────┐              ┌───────────────┐
│ app ─► sidecar│◄─── mTLS ───►│sidecar ◄─ app │      control plane (istiod) programs the sidecars:
│      (Envoy)  │   (L7: retry,│ (Envoy)       │      routing, mTLS certs, policy, telemetry
└───────────────┘    canary,   └───────────────┘
                     circuit-break)
```

Trade-off to internalize: a mesh buys uniform mTLS/observability/traffic-shaping **but** adds latency (extra hops), memory (a proxy per Pod), and operational complexity. Adopt it when you have enough services that solving these concerns per-app stops scaling — not before.

---

## 7. Verification & failure diagnostics

A worked, production-representative manifest that exercises the primitives, followed by a diagnostic playbook.

### 7.1 A hardened Kubernetes Pod (all primitives, declaratively)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-web
  namespace: prod
  labels:
    app: web
    tier: frontend
  annotations:
    container.apparmor.security.beta.kubernetes.io/web: runtime/default
spec:
  # ---- Pod-level security posture ----
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault          # apply the runtime's default seccomp filter
    supplementalGroups: [10001]
  automountServiceAccountToken: false
  containers:
    - name: web
      image: registry.example.com/web@sha256:9f2c...e1  # pin by digest (OCI image-spec)
      imagePullPolicy: IfNotPresent
      ports:
        - containerPort: 8080
          name: http
      # ---- Container-level hardening ----
      securityContext:
        allowPrivilegeEscalation: false     # sets no_new_privs — blocks setuid escalation
        readOnlyRootFilesystem: true        # immutable rootfs; writes go to tmpfs volumes
        privileged: false
        capabilities:
          drop: ["ALL"]                     # drop the monolithic root
          add:  ["NET_BIND_SERVICE"]        # add back only what's needed (bind :80/:443)
      # ---- cgroup limits (map to memory.max / cpu.max) ----
      resources:
        requests:
          cpu: "250m"
          memory: "128Mi"
        limits:
          cpu: "500m"                       # → cpu.max 50000 100000
          memory: "512Mi"                   # → memory.max 536870912; exceed => OOMKilled (137)
      livenessProbe:
        httpGet: { path: /healthz, port: http }
        initialDelaySeconds: 5
        periodSeconds: 10
      readinessProbe:
        httpGet: { path: /ready, port: http }
        periodSeconds: 5
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
  volumes:
    - name: tmp
      emptyDir: { medium: Memory, sizeLimit: 64Mi }
    - name: cache
      emptyDir: { sizeLimit: 128Mi }
```

Companion `NetworkPolicy` (default-deny, then allow) — the CNI-enforced firewall:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow
  namespace: prod
spec:
  podSelector:
    matchLabels: { app: web }
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - podSelector: { matchLabels: { tier: gateway } }
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      ports:
        - protocol: UDP
          port: 53                  # DNS only
```

### 7.2 Verification ladder

```console
# 1. Confirm the security posture actually took effect (don't trust the manifest — verify the process)
$ kubectl exec -n prod hardened-web -- grep -E 'Cap(Eff|Bnd)|Seccomp|NoNewPrivs' /proc/1/status
CapEff:   0000000000000400          # only CAP_NET_BIND_SERVICE
CapBnd:   0000000000000400
NoNewPrivs: 1
Seccomp:  2                         # filter mode active

# 2. Confirm the effective UID and read-only rootfs
$ kubectl exec -n prod hardened-web -- id
uid=10001 gid=10001 groups=10001
$ kubectl exec -n prod hardened-web -- touch /etc/x
touch: /etc/x: Read-only file system

# 3. Confirm the cgroup limits landed
$ kubectl exec -n prod hardened-web -- cat /sys/fs/cgroup/memory.max
536870912

# 4. Confirm namespaces are distinct from the host
$ NODE_PID=$(crictl inspect $(crictl ps -q --name web) | jq .info.pid)
$ sudo readlink /proc/$NODE_PID/ns/net /proc/1/ns/net
net:[4026532501]        # container
net:[4026531840]        # host  → different inode ⇒ isolated
```

### 7.3 Failure-mode diagnostic table

| Symptom | Likely cause | Confirm with | Fix |
|---|---|---|---|
| Exit code **137**, `OOMKilled: true` | Memory limit exceeded | `dmesg \| grep -i oom`, `kubectl describe pod` | Raise `memory.limit`, fix leak |
| Exit **125** (Docker) | Docker CLI/runtime error before container start | `docker run` stderr, `journalctl -u docker` | Bad flag / image / runtime |
| Exit **126** | Command found but not executable | `docker inspect` entrypoint; check `+x` | Fix perms / shebang |
| Exit **127** | Command not found in image | `docker run --rm img ls -l /path` | Wrong path / missing binary |
| `Operation not permitted` on a syscall | seccomp denial or dropped capability | `strace -f … \| grep EPERM`; `grep Seccomp /proc/…/status` | Add cap / adjust seccomp profile |
| `Permission denied` on a bind-mount despite `chmod 777` | SELinux label mismatch | `ausearch -m avc -ts recent` | Mount with `:Z`/`:z`, or `chcon -Rt container_file_t` |
| `apparmor="DENIED"` in dmesg | AppArmor profile blocked operation | `dmesg \| grep apparmor` | Adjust/loosen profile |
| Container starts, then restarts in a loop | Failing liveness probe / PID 1 not reaping | `kubectl logs --previous`, `crictl logs` | Fix probe, add `tini` as init |
| `pull access denied` / `manifest unknown` | Registry auth / wrong tag (distribution-spec) | `crictl pull`, `docker pull` verbose | Fix creds / tag / digest |
| Pod stuck `ContainerCreating` | CNI plugin failed to wire netns | `kubectl describe pod`, `/var/log/cni`, `journalctl -u kubelet` | Fix CNI config / plugin binary |
| `fork/exec … no space left` under memory | PID cgroup limit hit (`pids.max`) | `cat /sys/fs/cgroup/…/pids.current` | Raise `pids.limit` |
| Container can't `mount`/`modprobe` | Missing `CAP_SYS_ADMIN`/`CAP_SYS_MODULE` (by design) | `capsh --print` inside | Re-architect; do **not** grant blindly |

### 7.4 Namespace/cgroup live-forensics one-liners

```console
# Which container owns host PID 9887?
$ sudo grep -l 9887 /sys/fs/cgroup/**/cgroup.procs 2>/dev/null | head
# → path reveals the docker-<id>.scope or kubepods slice

# What is a container's per-controller cgroup path?
$ cat /proc/9887/cgroup
0::/system.slice/docker-1a2b3c….scope

# Compare two containers' user-namespace UID mappings (rootless verification)
$ cat /proc/9887/uid_map
         0     100000      65536      # container UID 0 → host UID 100000

# Enumerate every namespace and the process count in each
$ sudo lsns
```

---

## 8. References

- LPI — Exam 305 Objectives (305-300, v3.0): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- Linux `namespaces(7)` man page: <https://man7.org/linux/man-pages/man7/namespaces.7.html>
- Linux `cgroups(7)` man page: <https://man7.org/linux/man-pages/man7/cgroups.7.html>
- Linux `capabilities(7)` man page: <https://man7.org/linux/man-pages/man7/capabilities.7.html>
- Linux `seccomp(2)` man page: <https://man7.org/linux/man-pages/man2/seccomp.2.html>
- Linux `user_namespaces(7)` man page: <https://man7.org/linux/man-pages/man7/user_namespaces.7.html>
- Kernel cgroup v2 documentation: <https://docs.kernel.org/admin-guide/cgroup-v2.html>
- SELinux Project — container policy: <https://github.com/containers/container-selinux>
- AppArmor documentation: <https://gitlab.com/apparmor/apparmor/-/wikis/Documentation>
- Open Container Initiative (OCI): <https://opencontainers.org/>
- OCI Runtime Specification: <https://github.com/opencontainers/runtime-spec>
- OCI Image Specification: <https://github.com/opencontainers/image-spec>
- OCI Distribution Specification: <https://github.com/opencontainers/distribution-spec>
- runc: <https://github.com/opencontainers/runc>
- crun: <https://github.com/containers/crun>
- containerd: <https://containerd.io/> · docs: <https://github.com/containerd/containerd/tree/main/docs>
- CRI-O: <https://cri-o.io/>
- Kubernetes Container Runtime Interface (CRI): <https://kubernetes.io/docs/concepts/architecture/cri/>
- Kubernetes — Dockershim removal: <https://kubernetes.io/dockershim/>
- Container Network Interface (CNI): <https://www.cni.dev/> · spec: <https://github.com/containernetworking/cni/blob/main/SPEC.md>
- LXC / LXD documentation: <https://linuxcontainers.org/lxc/documentation/>
- Docker seccomp security profiles: <https://docs.docker.com/engine/security/seccomp/>
- Docker runtime privilege and Linux capabilities: <https://docs.docker.com/engine/containers/run/#runtime-privilege-and-linux-capabilities>
- Kubernetes — Configure a Security Context for a Pod: <https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>
- Istio service mesh architecture: <https://istio.io/latest/docs/ops/deployment/architecture/>