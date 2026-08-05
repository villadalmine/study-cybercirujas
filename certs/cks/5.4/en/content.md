# 5.4 — Appropriately use kernel hardening tools such as AppArmor, seccomp

> **CKS v1.34 · Domain 5: Microservice Vulnerability Minimization · Weight 2.5**

---

## 1. The architectural problem: one kernel, N tenants

A Kubernetes worker node running 110 pods runs **one** Linux kernel. Namespaces virtualise the *view* a process has of the system (PIDs, mounts, network, UTS, IPC, users, cgroups); cgroups meter *how much* it consumes. Neither of them narrows the **kernel ABI** — the ~350 syscalls on `x86_64` plus every `ioctl`, `netlink` message, `/proc` write and `/sys` attribute reachable through them. That ABI is the shared, un-namespaced attack surface, and it is where every container escape of the last decade has landed:

| CVE | Entry point | What namespaces did about it |
|---|---|---|
| CVE-2016-5195 (Dirty COW) | `madvise` + `/proc/self/mem` race | Nothing — both are namespace-agnostic |
| CVE-2019-5736 (runc `/proc/self/exe`) | `open`/`write` on the runtime binary via `/proc` | Nothing |
| CVE-2021-22555 (netfilter heap OOB) | `setsockopt` on `IPT_SO_SET_REPLACE` inside a user namespace | Nothing |
| CVE-2022-0185 (fs context heap overflow) | `fsconfig`/`unshare(CLONE_NEWUSER)` | Nothing |
| CVE-2022-0847 (Dirty Pipe) | `splice` + pipe flags | Nothing |
| CVE-2024-1086 (nf_tables UAF) | `unshare(CLONE_NEWUSER|CLONE_NEWNET)` + `nftables` netlink | Nothing |

Every one of those was mitigated *pre-patch* by either (a) a seccomp filter that returned `EPERM` for the syscall, or (b) an AppArmor/SELinux policy that denied the object access, or (c) both. That is the entire architectural argument for this topic: **patching is reactive and node-wide; syscall and object-level policy is proactive and per-workload.** The right mental model is a ratchet — you reduce the reachable kernel surface once, per workload, and it stays reduced through every subsequent CVE that happens to live behind a syscall you already removed.

### 1.1 Where these tools sit in the isolation stack

```
┌─────────────────────────────────────────────────────────────────────┐
│ container process                                                   │
├─────────────────────────────────────────────────────────────────────┤
│ glibc / musl                                                        │
├──────────────────────────── syscall boundary ───────────────────────┤
│ ① seccomp-BPF        → runs FIRST, on syscall entry, before the     │
│                        kernel resolves any argument pointer         │
├─────────────────────────────────────────────────────────────────────┤
│ ② capability check   → CAP_SYS_ADMIN, CAP_NET_RAW, …                │
├─────────────────────────────────────────────────────────────────────┤
│ ③ DAC (uid/gid/mode) → classic UNIX permissions                     │
├─────────────────────────────────────────────────────────────────────┤
│ ④ LSM hooks (MAC)    → AppArmor **or** SELinux; ~250 hook points    │
│                        on files, caps, mount, ptrace, signal, net   │
├─────────────────────────────────────────────────────────────────────┤
│ kernel object (inode, socket, task, …)                              │
└─────────────────────────────────────────────────────────────────────┘
```

Ordering matters operationally. seccomp fires **before** the LSM hooks and before capability checks, so a seccomp-denied syscall never reaches AppArmor and never produces an AppArmor audit record. When you are debugging "it fails but AppArmor logs nothing", that ordering is usually the answer.

### 1.2 The two tools answer different questions

| | seccomp | AppArmor |
|---|---|---|
| Question answered | *Which syscalls may this process issue?* | *Which objects may this process touch, and how?* |
| Granularity | syscall number + **scalar** arguments | path, capability, mount, ptrace, signal, socket family/type |
| Argument pointers | **Cannot dereference** (TOCTOU-safe by design) | Fully resolves paths through the LSM hook |
| Enforcement point | syscall entry (`seccomp-BPF`, cBPF→eBPF) | LSM hooks deep inside each subsystem |
| Can it express "read `/etc/passwd` but not `/etc/shadow`"? | **No** — both are `openat`, and the path is a pointer | **Yes** |
| Can it express "no `unshare` at all, ever"? | **Yes** | Partially (`deny mount`, `deny pivot_root`, no direct `unshare` rule) |
| Portability | Any Linux ≥ 3.5, any distro | Debian/Ubuntu/SUSE by default; absent on RHEL/Fedora/Rocky (they ship SELinux) |

They are complementary, not alternatives. A production baseline uses **both**: seccomp to amputate the syscall surface, AppArmor to constrain what the surviving syscalls may reach.

---

## 2. seccomp: mechanics you must understand to debug it

### 2.1 Modes and installation

```c
/* Mode 1 — SECCOMP_MODE_STRICT: only read/write/_exit/sigreturn. Useless for containers. */
prctl(PR_SET_SECCOMP, SECCOMP_MODE_STRICT);

/* Mode 2 — SECCOMP_MODE_FILTER: a cBPF program decides per syscall. What Kubernetes uses. */
seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &prog);
```

An unprivileged process may only install a filter if it first sets `PR_SET_NO_NEW_PRIVS`, otherwise a setuid binary could be used to escape the filter. This is why:

* every container runtime sets `no_new_privs` when it applies a seccomp profile;
* `securityContext.allowPrivilegeEscalation: false` also sets it;
* **setuid binaries stop working** under seccomp — the classic symptom is `ping` failing with `socket: Operation not permitted` even though `/bin/ping` is `4755`.

### 2.2 What the filter can actually see

```c
struct seccomp_data {
    int   nr;                   /* syscall number                       */
    __u32 arch;                 /* AUDIT_ARCH_X86_64 = 0xc000003e       */
    __u64 instruction_pointer;
    __u64 args[6];              /* raw register values — NOT followed   */
};
```

`args[]` holds register values. If an argument is a pointer (a path, a `struct sockaddr`), the filter sees the address, not the contents. Dereferencing was deliberately excluded: the userspace page could be rewritten between the filter's read and the kernel's read (TOCTOU). **This is the single most important limitation to internalise**: seccomp can express "no `mount`", it cannot express "no `mount` of `/dev/sda1`".

The `arch` check is mandatory in any hand-written profile. On `x86_64` a process can issue `x32` syscalls (`nr | 0x40000000`), and the syscall *numbers differ* between ABIs — a filter that allows `nr == 2` on `x86_64` (`open`) allows something else entirely on `i386`. `libseccomp` and the OCI runtimes handle this for you; the `architectures` field in a Kubernetes seccomp JSON profile is what drives it.

### 2.3 Filter actions and precedence

| Action | Value | Effect on the caller | Audit record |
|---|---|---|---|
| `SCMP_ACT_KILL_PROCESS` | `0x80000000` | Whole thread group dies, `SIGSYS` | `type=SECCOMP sig=31` |
| `SCMP_ACT_KILL` / `KILL_THREAD` | `0x00000000` | Calling thread dies, `SIGSYS` | `type=SECCOMP sig=31` |
| `SCMP_ACT_TRAP` | `0x00030000` | `SIGSYS` delivered — handler can catch it | yes |
| `SCMP_ACT_ERRNO(n)` | `0x0005xxxx` | Syscall returns `-n` (default `EPERM`) | no (unless `SCMP_ACT_LOG` elsewhere) |
| `SCMP_ACT_NOTIFY` | `0x7fc00000` | Handed to a userspace supervisor via a notify fd | no |
| `SCMP_ACT_TRACE(n)` | `0x7ff00000` | `ptrace` supervisor decides | no |
| `SCMP_ACT_LOG` | `0x7ffc0000` | **Allowed**, but logged. The profiling action. | `type=SECCOMP code=0x7ffc0000` |
| `SCMP_ACT_ALLOW` | `0x7fff0000` | Permitted, silent | no |

Filters **stack**: a process can install several, and every one runs on every syscall. The kernel returns the **most restrictive** result (`KILL_PROCESS` first, then ascending numeric value). A filter can therefore never widen what a previously installed filter denied — relevant when a sidecar injector, a runtime default and a workload profile all apply.

Since kernel 5.11 the kernel keeps a per-filter **bitmap cache** for syscalls whose action is constant regardless of arguments, so the common case costs no BPF execution at all. With `CONFIG_SECCOMP_CACHE_DEBUG` you can inspect it:

```
$ sudo cat /proc/24518/seccomp_cache | head -5
x86_64 0 ALLOW
x86_64 1 ALLOW
x86_64 2 FILTER
x86_64 3 ALLOW
x86_64 4 ALLOW
```

Practical overhead on a syscall-heavy workload with a modern kernel is ~1–3 %; anyone rejecting seccomp on performance grounds is usually quoting pre-5.11 numbers.

### 2.4 The `RuntimeDefault` profile — what it actually blocks

`RuntimeDefault` is not defined by Kubernetes. It is whatever the CRI runtime ships: containerd compiles it in (`contrib/seccomp/seccomp_default.go`, itself derived from Docker's `profiles/seccomp/default.json`), CRI-O has an equivalent. Its shape is:

```json
{ "defaultAction": "SCMP_ACT_ERRNO", "defaultErrnoRet": 1, "architectures": [...], "syscalls": [ ...~350 allowed... ] }
```

Roughly 50–60 syscalls are denied. The ones that matter for the exam and for real threat modelling:

| Denied syscall(s) | Attack it removes |
|---|---|
| `mount`, `umount2`, `pivot_root`, `move_mount`, `fsopen`, `fsconfig` | Mount-based escapes, CVE-2022-0185 |
| `unshare`, `setns`, `clone` with `CLONE_NEW*` | Namespace pivot, CVE-2024-1086, CVE-2021-22555 (all need a fresh userns) |
| `bpf` | Loading eBPF into the host kernel |
| `init_module`, `finit_module`, `delete_module` | Kernel module rootkits |
| `kexec_load`, `kexec_file_load`, `reboot` | Host takeover / DoS |
| `add_key`, `keyctl`, `request_key` | Kernel keyring escapes (CVE-2016-0728) |
| `open_by_handle_at`, `name_to_handle_at` | "Shocker" — file access outside the rootfs |
| `perf_event_open` | Historically a huge LPE surface |
| `ptrace` (< 4.8 kernels), `process_vm_readv/writev` | Cross-process memory access |
| `userfaultfd` | Heap-grooming primitive used in many LPE chains |
| `settimeofday`, `clock_settime`, `adjtimex` | Host clock manipulation |
| `swapon`, `swapoff`, `ioperm`, `iopl`, `vm86` | Direct hardware / memory abuse |

Several of these are conditionally allowed *if the container holds `CAP_SYS_ADMIN`* (the profile carries `"includes": {"caps": ["CAP_SYS_ADMIN"]}` blocks). Consequence worth memorising: **`privileged: true` or `CAP_SYS_ADMIN` re-opens `mount`, `unshare` and `setns` even with `RuntimeDefault` applied.** Hardening seccomp without dropping capabilities is theatre.

`RuntimeDefault` is *not* the default. Unless the kubelet is configured otherwise, a pod with no `seccompProfile` runs **`Unconfined`**.

### 2.5 Turning `RuntimeDefault` into the cluster default

```yaml
# /var/lib/kubelet/config.yaml  (KubeletConfiguration, GA since v1.27)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
seccompDefault: true
```

or `kubelet --seccomp-default=true`.

```
$ sudo systemctl restart kubelet
$ kubectl run probe --image=busybox:1.36 --restart=Never -- sleep 3600
pod/probe created
$ kubectl exec probe -- grep -E '^(NoNewPrivs|Seccomp)' /proc/1/status
NoNewPrivs:	0
Seccomp:	2
Seccomp_filters:	1
```

`Seccomp: 2` means `SECCOMP_MODE_FILTER`. `0` = disabled, `1` = strict.

**Roll-out discipline**: this flips every pod without an explicit profile from unconfined to filtered. Do it on a canary node pool first, taint it, move representative workloads there, and watch for `EPERM` in application logs for at least one full business cycle. The failure mode is not a crash — it is a syscall silently returning `-EPERM` inside a library that swallows the error.

### 2.6 Writing a custom profile

Profiles are OCI-format JSON placed under the kubelet seccomp root, which is `<kubelet --root-dir>/seccomp` and defaults to `/var/lib/kubelet/seccomp`. `localhostProfile` is a **path relative to that directory**; absolute paths and `..` are rejected.

**Audit profile — the one you always write first.** Allows everything, logs everything, so you can harvest the real syscall set of a workload:

```json
{
  "defaultAction": "SCMP_ACT_LOG"
}
```

**Deny-list profile — surgical, low blast radius:**

```json
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": [
        "mount", "umount2", "pivot_root", "move_mount", "fsopen", "fsconfig",
        "fsmount", "open_tree", "unshare", "setns", "bpf", "perf_event_open",
        "init_module", "finit_module", "delete_module", "kexec_load",
        "kexec_file_load", "open_by_handle_at", "name_to_handle_at",
        "userfaultfd", "process_vm_readv", "process_vm_writev", "ptrace",
        "add_key", "keyctl", "request_key", "reboot", "swapon", "swapoff"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1,
      "comment": "EPERM. Escape and post-exploitation primitives."
    }
  ]
}
```

**Allow-list profile with argument filtering — the production shape.** This is a complete, working profile for a statically linked Go HTTP service; note the `args` block that permits `clone` for threads while refusing any flag that creates a namespace:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": [
        "accept4", "arch_prctl", "bind", "brk", "clock_gettime", "close",
        "connect", "epoll_create1", "epoll_ctl", "epoll_pwait", "eventfd2",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getrandom", "getsockname", "getsockopt",
        "gettid", "listen", "madvise", "mmap", "mprotect", "munmap",
        "nanosleep", "newfstatat", "openat", "pread64", "prlimit64",
        "read", "readlinkat", "recvfrom", "rseq", "rt_sigaction",
        "rt_sigprocmask", "rt_sigreturn", "sched_getaffinity", "sched_yield",
        "sendto", "set_robust_list", "set_tid_address", "setsockopt",
        "shutdown", "sigaltstack", "socket", "tgkill", "uname", "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["clone"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {
          "index": 0,
          "value": 2114060288,
          "valueTwo": 0,
          "op": "SCMP_CMP_MASKED_EQ",
          "comment": "0x7E020000 = CLONE_NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET|NEWTIME. Must be zero."
        }
      ]
    },
    {
      "names": ["socket"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 22,
      "args": [
        { "index": 0, "value": 16, "op": "SCMP_CMP_EQ", "comment": "AF_NETLINK → EINVAL" }
      ]
    }
  ]
}
```

Comparison operators available in `args`: `SCMP_CMP_NE`, `SCMP_CMP_LT`, `SCMP_CMP_LE`, `SCMP_CMP_EQ`, `SCMP_CMP_GE`, `SCMP_CMP_GT`, `SCMP_CMP_MASKED_EQ` (`(arg & value) == valueTwo`). Multiple `args` entries on one rule are **AND**ed.

### 2.7 Deriving the allow-list from a running workload

Three practical methods, in increasing order of fidelity:

```
# ① strace on a short-lived run — misses rare paths, but zero infrastructure
$ sudo strace -f -c -U name -p $(pgrep -f checkout-api) -o /tmp/syscalls.txt
$ sort -u /tmp/syscalls.txt | awk '{print $NF}' | paste -sd'","' -
"accept4","arch_prctl","bind","brk",...

# ② SCMP_ACT_LOG profile + auditd — captures everything the kernel sees
$ sudo ausearch -m SECCOMP -ts recent --format raw \
    | grep -oP 'syscall=\K[0-9]+' | sort -un | while read n; do scmp_sys_resolver "$n"; done
openat
read
write
...

# ③ Security Profiles Operator eBPF recorder — the only one safe for long production soaks
```

Always union the traces from **at least** startup, steady state, a config reload (`SIGHUP`), a graceful shutdown, and any rarely-exercised path (TLS renegotiation, core dump, panic handler). Profiles derived from a five-minute happy-path trace are the #1 source of 03:00 incidents.

---

## 3. AppArmor: mechanics

### 3.1 Model

AppArmor is a **path-based** LSM. Policy is attached to a program by profile name; the profile enumerates permitted accesses in classes (`file`, `capability`, `network`, `mount`, `ptrace`, `signal`, `unix`, `dbus`). Any class you mention becomes default-deny for everything you did not permit; a class you never mention is unmediated. Explicit `deny` rules take precedence over allows and are permanently subtracted, even across profile stacking.

Contrast with SELinux, which is **label-based**: policy is on inode labels (`xattr`) rather than pathnames. AppArmor is dramatically easier to author and reason about; the price is that a hard link or bind mount to a different path is a different policy subject.

### 3.2 Profile modes

| Mode | Behaviour | How to set |
|---|---|---|
| `enforce` | Deny + log | `aa-enforce <profile>` or default |
| `complain` | Allow + log (learning mode) | `aa-complain`, or `flags=(complain)` |
| `kill` | Deny + `SIGKILL` the process (AppArmor 3.x) | `flags=(kill)` |
| `unconfined` | No mediation, profile loaded but inert | `flags=(unconfined)` |

### 3.3 Kubernetes integration

The container runtime applies the profile via the OCI `process.apparmorProfile` field, executing a profile transition at container start. `RuntimeDefault` under containerd is a generated profile named `cri-containerd.apparmor.d`; under Docker it is `docker-default`.

**The API field (GA since v1.31; available since v1.30):**

```
$ kubectl explain pod.spec.securityContext.appArmorProfile
GROUP:
KIND:       Pod
VERSION:    v1

FIELD: appArmorProfile <AppArmorProfile>

DESCRIPTION:
    appArmorProfile is the AppArmor options to use by the containers in this pod.
    Note that this field cannot be set when spec.os.name is windows.

FIELDS:
  localhostProfile	<string>
    localhostProfile indicates a profile loaded on the node that should be used.
    The profile must be preconfigured on the node to work. Must match the loaded
    name of the profile. Must be set if and only if type is "Localhost".

  type	<string> -required-
    type indicates which kind of AppArmor profile will be applied. Valid options are:
      Localhost - a profile pre-loaded on the node.
      RuntimeDefault - the container runtime's default profile.
      Unconfined - no AppArmor enforcement.
```

The legacy annotation `container.apparmor.security.beta.kubernetes.io/<container-name>` has been **deprecated since v1.30**. The API server still converts a lone annotation into the field for backward compatibility, but setting **both** with conflicting values is a validation error, and the annotation will be removed. Write the field; recognise the annotation when you inherit an old manifest.

### 3.4 A critical asymmetry between the two `localhostProfile` fields

| | `seccompProfile.localhostProfile` | `appArmorProfile.localhostProfile` |
|---|---|---|
| Semantics | **Filesystem path**, relative to `/var/lib/kubelet/seccomp` | **Profile name** as loaded into the kernel |
| Example value | `operator/prod/checkout-v3.json` | `k8s-checkout-api-v3` |
| Where it must exist | as a file on the node | in `/sys/kernel/security/apparmor/profiles` |
| Verify with | `ls /var/lib/kubelet/seccomp/...` | `sudo aa-status \| grep <name>` |

Getting this backwards — putting `/etc/apparmor.d/k8s-deny-write` in the AppArmor field — is a standard exam trap and a standard production outage. The value must match the `profile <name>` declared inside the profile file, which need not equal the filename.

### 3.5 Complete profiles

**Deny all writes** — the canonical teaching profile, hardened for containers:

```apparmor
# /etc/apparmor.d/k8s-deny-write
abi <abi/3.0>,
include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  file,
  network,
  capability,

  deny /** w,
  deny /** l,
  deny /** k,

  audit deny /etc/shadow rwklx,
  audit deny /root/.ssh/** rwklx,
}
```

`flags=(attach_disconnected)` is not optional in containers. Container rootfs are built with `pivot_root` over overlayfs, and the kernel frequently cannot resolve a path back to the namespace root. Without this flag you get a flood of `apparmor="DENIED" ... info="Failed name lookup - disconnected path"` for accesses your profile explicitly permits. `mediate_deleted` keeps mediation on unlinked-but-open files.

**Anti-escape profile** — this is the one worth deploying to real workloads:

```apparmor
# /etc/apparmor.d/k8s-no-escape
abi <abi/3.0>,
include <tunables/global>

profile k8s-no-escape flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>

  # ---- filesystem -----------------------------------------------------
  file,                                   # start permissive, subtract below
  deny /proc/sys/** w,                    # sysctl writes
  deny /proc/sysrq-trigger rwklx,         # host reboot / SysRq
  deny /proc/kcore rklx,                  # host physical memory
  deny /proc/kallsyms rklx,               # KASLR leak for exploit chains
  deny @{PROC}/@{pid}/mem rw,             # Dirty COW style writes
  deny /sys/kernel/security/** rwklx,     # securityfs: unload our own policy
  deny /sys/fs/cgroup/**/release_agent w, # classic cgroup-v1 escape
  deny /sys/firmware/** rwklx,
  deny /dev/kmsg rwklx,
  deny /dev/mem rwklx,
  deny /dev/kmem rwklx,
  deny /**/docker.sock rwklx,             # mounted-socket escape
  deny /**/containerd.sock rwklx,

  # ---- mount namespace ------------------------------------------------
  deny mount,
  deny umount,
  deny pivot_root,

  # ---- process interaction --------------------------------------------
  deny ptrace (trace, read, tracedby, readby) peer=**,
  signal (send, receive) peer=k8s-no-escape,   # only siblings under this profile
  deny signal peer=unconfined,

  # ---- capabilities ----------------------------------------------------
  capability chown,
  capability dac_override,
  capability setuid,
  capability setgid,
  deny capability sys_admin,
  deny capability sys_module,
  deny capability sys_ptrace,
  deny capability sys_rawio,
  deny capability sys_boot,
  deny capability net_raw,
  deny capability mac_admin,
  deny capability mac_override,

  # ---- network ---------------------------------------------------------
  network inet stream,
  network inet dgram,
  network inet6 stream,
  network inet6 dgram,
  network unix stream,
  network unix dgram,
  network netlink raw,          # required by many runtimes/CNI-aware libs
  deny network raw,             # AF_PACKET / raw sockets → no sniffing
  deny network packet,
}
```

**Least-privilege profile for a specific binary** — nginx, exhaustively enumerated:

```apparmor
# /etc/apparmor.d/k8s-nginx
abi <abi/3.0>,
include <tunables/global>

profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/openssl>

  # binaries
  /usr/sbin/nginx           mr,
  /docker-entrypoint.sh     rix,
  /bin/dash                 rix,
  /usr/bin/{env,sed,find,touch,mkdir} rix,

  # configuration and content: read-only
  /etc/nginx/**             r,
  /usr/share/nginx/html/**  r,
  /etc/ssl/private/*.key    r,

  # writable state: exactly three paths
  /var/cache/nginx/**       rw,
  /var/run/nginx.pid        rw,
  /var/log/nginx/*.log      w,
  /dev/stdout               w,
  /dev/stderr               w,

  # ports < 1024 need this; drop it if you listen on 8080
  capability net_bind_service,
  capability setuid,
  capability setgid,

  network inet stream,
  network inet6 stream,
  network unix stream,

  deny network raw,
  deny mount,
  deny ptrace (trace, read) peer=**,
  deny /** wl,                    # anything not explicitly writable above
  deny /proc/sys/** w,
}
```

Note `rix` on the shell and helpers: `i` = inherit the current profile across `exec`, so the child stays confined by `k8s-nginx`. The alternatives are `Px` (transition to a named profile), `Cx` (transition to a child profile defined inline), and `Ux` (**unconfined — an escape hatch, treat any `Ux` in a reviewed profile as a finding**).

### 3.6 Loading and lifecycle

```
$ sudo apparmor_parser -q -r /etc/apparmor.d/k8s-no-escape     # -r = replace (idempotent)
$ sudo aa-status
apparmor module is loaded.
41 profiles are loaded.
39 profiles are in enforce mode.
   /snap/snapd/21759/usr/lib/snapd/snap-confine
   /usr/bin/man
   cri-containerd.apparmor.d
   k8s-deny-write
   k8s-nginx
   k8s-no-escape
   ...
2 profiles are in complain mode.
   k8s-audit-candidate
0 profiles are in kill mode.
0 profiles are in unconfined mode.
23 processes have profiles defined.
23 processes are in enforce mode.
   /usr/sbin/chronyd (912)
   cri-containerd.apparmor.d (24518)
   k8s-nginx (25107)
   ...
0 processes are in complain mode.
0 processes are unconfined but have a profile defined.
```

Operational nuances that bite:

* `apparmor_parser -r` takes effect **immediately for already-running processes**. That is a hotfix superpower and a footgun — replacing a profile with a stricter one can break running pods with no pod-level event.
* `apparmor_parser -R` (remove) leaves running containers **unconfined**, silently. Never remove a profile that pods still reference.
* You cannot attach a profile to a running container. The transition happens at `exec` time; changing the field requires recreating the pod.
* Profiles are kernel state, not files. A node reboot reloads whatever is in `/etc/apparmor.d` via the `apparmor.service`; a profile you loaded from `/tmp` is gone.

---

## 4. Trade-off analysis

### 4.1 Choosing a mechanism

| Mechanism | Stops syscalls | Stops object access | Node prerequisite | Perf cost | Effort to author | Blast radius when wrong |
|---|---|---|---|---|---|---|
| Drop capabilities | indirectly | indirectly | none | ~0 | trivial | low, fails loudly (`EPERM`) |
| seccomp `RuntimeDefault` | yes (~55) | no | none | ~1 % | zero | low |
| seccomp `Localhost` allow-list | yes (~300) | no | file on every node | 1–3 % | **high** | **high** — one missed syscall = crash loop |
| AppArmor `RuntimeDefault` | no | minimal | AppArmor-enabled node | ~1 % | zero | low |
| AppArmor `Localhost` | no | yes | profile loaded on every node | 1–4 % | medium | medium, `EACCES` |
| SELinux (`seLinuxOptions`) | no | yes | SELinux distro + policy | 2–5 % | high | high |
| User namespaces (`hostUsers: false`) | no | remaps uid 0 | kernel ≥ 6.3 + idmapped mounts | low | trivial | medium (fs ownership) |
| gVisor (`runsc`) | reimplements them | yes | RuntimeClass | 10–50 % on syscall-heavy | zero | medium (compat gaps) |
| Kata Containers | separate kernel | yes | nested virt / bare metal | 5–15 %, +150 MB/pod | zero | low |

Architectural guidance: **`RuntimeDefault` for both, everywhere, as a floor, enforced by admission control.** Escalate to `Localhost` allow-lists only for workloads that are internet-facing, process untrusted input, or handle regulated data — the operational cost of a bespoke profile is recurring (every image bump can change the syscall set), so spend it where the risk justifies it.

### 4.2 Pod Security Standards interaction

| Control | `privileged` | `baseline` | `restricted` |
|---|---|---|---|
| `seccompProfile.type` | any | any (incl. `Unconfined`) | must be `RuntimeDefault` or `Localhost`; `Unconfined` **forbidden**; must be set on the pod or on every container + ephemeral/init container |
| `appArmorProfile.type` | any | `RuntimeDefault` or `Localhost` only | same as baseline |

So `restricted` gets you seccomp, and *neither* level forces a non-default AppArmor profile. If your compliance narrative says "MAC enforced per workload", PSS alone does not deliver it — you need admission policy.

---

## 5. Production manifests

### 5.1 Namespace with enforced baseline

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.34
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 5.2 Node-side profile distribution (AppArmor)

Profiles are node-local state. Kubernetes will not ship them for you. This DaemonSet loads them, then labels the node so pods can require a node that has them.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: kube-system
  labels:
    app.kubernetes.io/name: apparmor-loader
data:
  k8s-no-escape: |
    abi <abi/3.0>,
    include <tunables/global>

    profile k8s-no-escape flags=(attach_disconnected,mediate_deleted) {
      include <abstractions/base>
      file,
      network inet stream,
      network inet6 stream,
      network unix stream,
      deny network raw,
      deny mount,
      deny umount,
      deny pivot_root,
      deny ptrace (trace, read) peer=**,
      deny /proc/sys/** w,
      deny /proc/sysrq-trigger rwklx,
      deny /sys/kernel/security/** rwklx,
      deny /sys/fs/cgroup/**/release_agent w,
      deny /dev/kmsg rwklx,
      deny capability sys_admin,
      deny capability sys_module,
      deny capability sys_ptrace,
      deny capability net_raw,
    }
  k8s-nginx: |
    abi <abi/3.0>,
    include <tunables/global>

    profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
      include <abstractions/base>
      include <abstractions/nameservice>
      /usr/sbin/nginx           mr,
      /docker-entrypoint.sh     rix,
      /bin/dash                 rix,
      /etc/nginx/**             r,
      /usr/share/nginx/html/**  r,
      /var/cache/nginx/**       rw,
      /var/run/nginx.pid        rw,
      /dev/std{out,err}         w,
      capability net_bind_service,
      capability setuid,
      capability setgid,
      network inet stream,
      network inet6 stream,
      deny network raw,
      deny mount,
      deny /** wl,
    }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: apparmor-loader
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: apparmor-loader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: apparmor-loader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: apparmor-loader
subjects:
  - kind: ServiceAccount
    name: apparmor-loader
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: apparmor-loader
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: apparmor-loader
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: apparmor-loader
      annotations:
        checksum/profiles: "sha256-REPLACED-BY-CI"   # forces a roll when profiles change
    spec:
      serviceAccountName: apparmor-loader
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      hostPID: true
      priorityClassName: system-node-critical
      terminationGracePeriodSeconds: 5
      containers:
        - name: loader
          image: ubuntu:24.04
          securityContext:
            privileged: true          # required: writes kernel policy via securityfs
            appArmorProfile:
              type: Unconfined        # a confined loader cannot load policy
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              apt-get update -qq && apt-get install -y -qq apparmor-utils curl >/dev/null

              install -d /host/etc/apparmor.d
              cp /profiles/* /host/etc/apparmor.d/

              for p in /profiles/*; do
                name="$(basename "$p")"
                nsenter --mount=/proc/1/ns/mnt -- \
                  apparmor_parser -q -r "/etc/apparmor.d/${name}"
                echo "loaded ${name}"
              done

              # label the node so workloads can require the profile set
              TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
              CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              curl -sS --cacert "$CA" \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/strategic-merge-patch+json" \
                -X PATCH \
                --data '{"metadata":{"labels":{"security.example.com/apparmor-profiles":"v3"}}}' \
                "https://kubernetes.default.svc/api/v1/nodes/${NODE_NAME}" >/dev/null
              echo "node ${NODE_NAME} labelled"

              sleep infinity
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits:   { memory: 192Mi }
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: host-apparmor-d
              mountPath: /host/etc/apparmor.d
            - name: host-proc
              mountPath: /proc
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: host-apparmor-d
          hostPath:
            path: /etc/apparmor.d
            type: Directory
        - name: host-proc
          hostPath:
            path: /proc
            type: Directory
```

The same pattern, minus `nsenter`, distributes seccomp JSON to `/var/lib/kubelet/seccomp/`. The node label is the important part: it closes the race where a pod is scheduled onto a node whose loader has not finished, which otherwise manifests as an intermittent `CreateContainerError` during cluster scale-up.

### 5.3 Workload consuming both

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: prod
  labels:
    app.kubernetes.io/name: checkout-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: checkout-api
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: security.example.com/apparmor-profiles
                    operator: In
                    values: ["v3"]
      automountServiceAccountToken: false
      # ---- pod-level defaults, inherited by every container ----
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: Localhost
          localhostProfile: operator/prod/checkout-api-v3.json
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-no-escape
      initContainers:
        - name: migrate
          image: registry.example.com/checkout-migrate:1.9.3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
            # init containers inherit the pod profiles; override only if the
            # migration tool needs a syscall the API profile omits
            seccompProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 256Mi }
      containers:
        - name: api
          image: registry.example.com/checkout-api:1.9.3
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http }
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits:   { memory: 512Mi }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
        - name: metrics-sidecar
          image: registry.example.com/otel-collector:0.108.0
          # ---- container-level override: sidecar keeps the loose defaults ----
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
            seccompProfile:
              type: RuntimeDefault
            appArmorProfile:
              type: RuntimeDefault
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 128Mi }
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
```

### 5.4 Admission enforcement with `ValidatingAdmissionPolicy`

PSS `restricted` does not forbid `appArmorProfile: Unconfined` on its own path, and many clusters cannot run `restricted` everywhere yet. Native CEL policy closes the gap without a webhook dependency:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-kernel-hardening
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: allContainers
      expression: >-
        object.spec.containers +
        (has(object.spec.initContainers) ? object.spec.initContainers : []) +
        (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
    - name: podSeccomp
      expression: >-
        has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile)
          ? object.spec.securityContext.seccompProfile.type : ""
    - name: podAppArmor
      expression: >-
        has(object.spec.securityContext) && has(object.spec.securityContext.appArmorProfile)
          ? object.spec.securityContext.appArmorProfile.type : ""
  validations:
    - expression: >-
        variables.allContainers.all(c,
          (has(c.securityContext) && has(c.securityContext.seccompProfile)
            ? c.securityContext.seccompProfile.type
            : variables.podSeccomp) in ['RuntimeDefault', 'Localhost'])
      message: "every container must resolve to seccompProfile RuntimeDefault or Localhost"
      reason: Forbidden
    - expression: >-
        variables.allContainers.all(c,
          (has(c.securityContext) && has(c.securityContext.appArmorProfile)
            ? c.securityContext.appArmorProfile.type
            : variables.podAppArmor) in ['RuntimeDefault', 'Localhost'])
      message: "every container must resolve to appArmorProfile RuntimeDefault or Localhost"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: require-kernel-hardening
spec:
  policyName: require-kernel-hardening
  validationActions: ["Deny", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-node-lease"]
```

```
$ kubectl apply -f unconfined-pod.yaml
Error from server (Forbidden): error when creating "unconfined-pod.yaml": pods "debug" is
forbidden: ValidatingAdmissionPolicy 'require-kernel-hardening' with binding
'require-kernel-hardening' denied request: every container must resolve to seccompProfile
RuntimeDefault or Localhost
```

### 5.5 Security Profiles Operator (recording and distribution at scale)

```
$ kubectl apply -f https://github.com/kubernetes-sigs/security-profiles-operator/releases/download/v0.8.6/operator.yaml
$ kubectl -n security-profiles-operator get pods
NAME                                         READY   STATUS    RESTARTS   AGE
security-profiles-operator-7f9c8d5b6-2xk4l   1/1     Running   0          51s
spod-4nq9x                                   3/3     Running   0          38s
spod-hb7zz                                   3/3     Running   0          38s
```

Enable the eBPF recorder, then record a live workload:

```yaml
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: SecurityProfilesOperatorDaemon
metadata:
  name: spod
  namespace: security-profiles-operator
spec:
  enableBpfRecorder: true
  enableAppArmor: true
---
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: checkout-api-recording
  namespace: prod
spec:
  kind: SeccompProfile
  recorder: bpf
  mergeStrategy: containers      # union across all replicas
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout-api
```

```
$ kubectl -n prod delete deploy checkout-api        # recording is finalised on pod exit
$ kubectl -n prod get seccompprofiles
NAME                              STATUS      AGE
checkout-api-recording-api        Installed   12s
checkout-api-recording-metrics    Installed   12s

$ kubectl -n prod get seccompprofile checkout-api-recording-api -o jsonpath='{.status.localhostProfile}'
operator/prod/checkout-api-recording-api.json
```

That `status.localhostProfile` value is exactly what goes into `seccompProfile.localhostProfile`; SPO handles writing the file to every node and reconciling it. The equivalent AppArmor CRD (`AppArmorProfile`, alpha — verify the schema against the release you install) covers profile distribution without the DaemonSet above.

---

## 6. Verification and failure diagnosis

### 6.1 Positive verification, from inside out

```
# ---- 1. Is the policy visible to the process? ----
$ kubectl -n prod exec deploy/checkout-api -c api -- cat /proc/1/attr/current
k8s-no-escape (enforce)

$ kubectl -n prod exec deploy/checkout-api -c api -- grep -E '^(NoNewPrivs|Seccomp)' /proc/1/status
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1

$ kubectl -n prod exec deploy/checkout-api -c api -- grep -E '^Cap(Prm|Eff|Bnd)' /proc/1/status
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000000

# ---- 2. Does the policy actually deny? Test, do not assume. ----
$ kubectl -n prod exec deploy/checkout-api -c api -- touch /etc/probe
touch: cannot touch '/etc/probe': Permission denied
command terminated with exit code 1

$ kubectl -n prod exec deploy/checkout-api -c api -- unshare -Urn /bin/true
unshare: unshare failed: Operation not permitted
command terminated with exit code 1

$ kubectl -n prod exec deploy/checkout-api -c api -- mount -t proc proc /mnt
mount: /mnt: permission denied.
command terminated with exit code 32

# ---- 3. What did the runtime actually receive? Ground truth on the node. ----
$ CID=$(sudo crictl ps --name '^api$' -q | head -1)
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.process.apparmorProfile'
k8s-no-escape
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.linux.seccomp.defaultAction'
SCMP_ACT_ERRNO
$ sudo crictl inspect "$CID" | jq '[.info.runtimeSpec.linux.seccomp.syscalls[].names[]] | length'
54
$ sudo crictl inspect "$CID" | jq -r '.info.runtimeSpec.process.noNewPrivileges'
true
```

`crictl inspect` is the authoritative check. `kubectl get pod -o yaml` shows *intent*; only the runtime spec shows what was applied. If the two disagree, suspect a mutating webhook or a stale kubelet.

### 6.2 Node prerequisites

```
$ cat /sys/module/apparmor/parameters/enabled
Y
$ cat /sys/kernel/security/lsm
lockdown,capability,landlock,yama,apparmor,bpf
$ grep -c . /sys/kernel/security/apparmor/profiles
41
$ grep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /boot/config-$(uname -r)
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion
NAME       OS                   KERNEL
node-01    Ubuntu 24.04.1 LTS   6.8.0-45-generic
node-02    Ubuntu 24.04.1 LTS   6.8.0-45-generic
```

If `/sys/module/apparmor/parameters/enabled` is missing or `N`, AppArmor is not usable on that node — a `Localhost` or even `RuntimeDefault` AppArmor pod will fail there. On RHEL-family nodes this is expected: use SELinux (`seLinuxOptions`) instead, and keep seccomp as the portable half of the strategy.

### 6.3 Failure catalogue

| Symptom | Root cause | Confirm with | Fix |
|---|---|---|---|
| `CreateContainerError`, event: `apparmor profile not loaded` / `apparmor failed to apply profile` | Profile absent on the scheduled node | `sudo aa-status \| grep <name>` on that node | Run the loader DaemonSet; add node affinity on the loader's label |
| Pod `Blocked`, `Reason: AppArmor`, `Cannot enforce AppArmor: ...` | Older kubelet's admission handler (pre-GA behaviour) | `kubectl describe pod` | Same fix; note modern kubelets defer this to the runtime, so the message differs by version |
| `Error: failed to generate spec: cannot load seccomp profile ".../x.json": no such file` | seccomp file missing under `/var/lib/kubelet/seccomp` | `ls -l /var/lib/kubelet/seccomp/<path>` | Distribute the file; check `localhostProfile` is **relative** |
| `field is immutable` on pod update | `securityContext` cannot be patched in place | — | Recreate the pod / roll the Deployment |
| Container exits **159** repeatedly | `SIGSYS` (128+31) from `SCMP_ACT_KILL` | `dmesg \| grep -i seccomp`; `kubectl get pod -o jsonpath='{..exitCode}'` | Identify the syscall in the audit record, add it, or switch the profile to `SCMP_ACT_ERRNO` while debugging |
| App logs `Operation not permitted` (`EPERM`), nothing in `dmesg` | seccomp `SCMP_ACT_ERRNO` — silent by design | Temporarily swap to a `SCMP_ACT_LOG` profile | Add the syscall to the allow-list |
| App logs `Permission denied` (`EACCES`) **and** `dmesg` shows `apparmor="DENIED"` | AppArmor object denial | `dmesg \| grep DENIED` | Add the rule; check `requested_mask` |
| Flood of `info="Failed name lookup - disconnected path"` | Missing `flags=(attach_disconnected)` | inspect the profile header | Add the flag, `apparmor_parser -r` |
| `ping` fails with `Operation not permitted` as root | `no_new_privs` set by seccomp/`allowPrivilegeEscalation:false` broke the setuid binary | `grep NoNewPrivs /proc/1/status` → `1` | Use a `cap_net_raw`-file-capability image, or accept the loss |
| DNS breaks after applying a custom profile | Missing `network netlink raw` or `abstractions/nameservice` | `dmesg \| grep DENIED \| grep netlink` | Add the rule |
| Policy works on node-01, fails on node-03 | Profile set drifted across nodes | `for n in $(...); do ssh $n aa-status; done` | Node label + affinity; move to SPO |
| `RuntimeDefault` seccomp applied but container still mounts filesystems | Container has `CAP_SYS_ADMIN` / is privileged; the default profile allows those syscalls when the capability is held | `grep CapEff /proc/1/status` | Drop `ALL` capabilities — seccomp is not a substitute |

### 6.4 Reading the kernel's audit output

**AppArmor denial:**

```
$ sudo dmesg -T | grep -i apparmor | tail -3
[Mon Aug  4 14:26:52 2026] audit: type=1400 audit(1754317612.884:212): apparmor="DENIED" \
  operation="mknod" class="file" profile="k8s-no-escape" name="/etc/probe" pid=25811 \
  comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
[Mon Aug  4 14:27:03 2026] audit: type=1400 audit(1754317623.117:213): apparmor="DENIED" \
  operation="mount" class="mount" profile="k8s-no-escape" name="/mnt/" pid=25840 \
  comm="mount" fstype="proc" srcname="proc"
[Mon Aug  4 14:27:19 2026] audit: type=1400 audit(1754317639.552:214): apparmor="DENIED" \
  operation="capable" class="cap" profile="k8s-no-escape" pid=25871 comm="ip" \
  capability=12  capname="net_admin"
```

Field decoding:

| Field | Meaning |
|---|---|
| `operation` | The LSM hook (`open`, `mknod`, `mount`, `capable`, `ptrace`, `signal`, `exec`) |
| `profile` | Which profile denied it — confirms the right one is attached |
| `requested_mask` / `denied_mask` | `r` read, `w` write, `a` append, `x` exec, `m` mmap-exec, `k` lock, `l` link, `c` create, `d` delete |
| `comm` | The binary — tells you *which* process in the container |
| `capname` | For `operation="capable"`, the missing capability |

Turn denials into rules mechanically:

```
$ sudo aa-logprof -f /var/log/audit/audit.log
Reading log entries from /var/log/audit/audit.log.
Updating AppArmor profiles in /etc/apparmor.d.

Profile:  k8s-nginx
Path:     /var/lib/nginx/tmp/client_body
New Mode: owner rw
Severity: 4

 [1 - owner /var/lib/nginx/tmp/client_body rw,]
  2 - owner /var/lib/nginx/tmp/* rw,
  3 - owner /var/lib/nginx/tmp/** rw,
(A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xtension / (N)ew / ...
```

**seccomp audit record:**

```
$ sudo ausearch -m SECCOMP -ts recent -i | tail -6
type=SECCOMP msg=audit(08/04/2026 14:31:02.221:318) : auid=unset uid=root gid=root ses=unset \
  pid=26011 comm=chmod exe=/usr/bin/chmod sig=SIGSYS arch=x86_64 syscall=fchmodat compat=0 \
  ip=0x7f2c1d0a4b47 code=kill_thread
```

Raw form when `-i` interpretation is unavailable:

```
type=SECCOMP msg=audit(1754317862.221:318): auid=4294967295 uid=0 gid=0 ses=4294967295 \
  pid=26011 comm="chmod" exe="/usr/bin/chmod" sig=31 arch=c000003e syscall=268 compat=0 \
  ip=0x7f2c1d0a4b47 code=0x0
```

Decode it:

```
$ scmp_sys_resolver 268
fchmodat
$ ausyscall x86_64 268
fchmodat
$ printf 'arch=c000003e is AUDIT_ARCH_X86_64\n'
arch=c000003e is AUDIT_ARCH_X86_64
```

`code=0x0` → `SECCOMP_RET_KILL_THREAD`. `code=0x7ffc0000` → `SECCOMP_RET_LOG` (permitted, audit-only). `code=0x00050001` → `SECCOMP_RET_ERRNO(EPERM)`.

### 6.5 The diagnostic decision tree

```
Container fails to START (CreateContainerError / Blocked)
├─ event mentions "apparmor" → profile not loaded on the node
│    → aa-status on THAT node; check the loader DaemonSet; check node affinity
├─ event mentions "seccomp profile" → file missing under /var/lib/kubelet/seccomp
│    → ls the path; check localhostProfile is relative, no leading "/", no ".."
└─ event mentions "no such file or directory: unknown" on /proc/self/attr
     → AppArmor not enabled on the node kernel

Container STARTS then dies
├─ exitCode 159 → SIGSYS → seccomp KILL. ausearch -m SECCOMP → scmp_sys_resolver
└─ exitCode 1/2 with app error → read the errno:
     ├─ EPERM  and dmesg silent            → seccomp SCMP_ACT_ERRNO
     ├─ EACCES and dmesg apparmor="DENIED" → AppArmor
     ├─ EPERM  and CapEff missing the bit  → capability drop, not MAC
     └─ EACCES and dmesg silent            → plain DAC (uid/gid/mode) or readOnlyRootFilesystem

Container RUNS but a feature silently misbehaves
└─ swap to SCMP_ACT_LOG + apparmor complain mode, exercise the feature,
   diff the audit log against the profile, then re-enforce
```

### 6.6 The safe iteration loop for a new profile

```
1. Deploy with defaultAction: SCMP_ACT_LOG and AppArmor flags=(complain)
2. Run the workload through: startup, steady state, SIGHUP reload,
   TLS handshake, backup path, graceful shutdown, OOM/panic path
3. Harvest:
     ausearch -m SECCOMP -ts today --format raw | grep -oP 'syscall=\K[0-9]+' | sort -un
     aa-logprof -f /var/log/audit/audit.log
4. Generate the allow-list; keep a diff against the previous version in git
5. Re-deploy to ONE canary replica in enforce mode; soak ≥ 24 h
6. Promote. Version the profile name (…-v3), never mutate in place —
   `apparmor_parser -r` changes behaviour of running pods with no rollout event
```

Rule of thumb: never regenerate a profile from a trace shorter than the workload's slowest periodic job.

---

## 7. Exam-focused checklist

* `securityContext.seccompProfile` and `securityContext.appArmorProfile` exist at **pod** level and at **container** level; container wins.
* seccomp `localhostProfile` = **path** under `/var/lib/kubelet/seccomp`. AppArmor `localhostProfile` = **profile name**. Do not swap them.
* Load a profile: `sudo apparmor_parser -q -r /etc/apparmor.d/<file>` on the node the pod will land on. Verify: `sudo aa-status`.
* Verify from inside: `cat /proc/1/attr/current` and `grep Seccomp /proc/1/status`.
* If a task says "AppArmor annotation", recognise `container.apparmor.security.beta.kubernetes.io/<container>` as the deprecated form and prefer the field.
* `RuntimeDefault` seccomp does **not** exist unless you set it — the default is `Unconfined`.
* Dropping capabilities is a prerequisite, not an alternative: `CAP_SYS_ADMIN` re-enables syscalls the default profile otherwise blocks.
* `kubectl describe pod` events tell you which of the two mechanisms failed; `crictl inspect` tells you what was really applied.

---

## 8. References

* CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
* Kubernetes — Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
* Kubernetes — Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
* Kubernetes — Security Context / `SecurityContext` API reference — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
* Kubernetes — Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
* Kubernetes — Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
* Kubernetes — Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
* Kubernetes — Kubelet configuration (`seccompDefault`) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
* KEP-24 — AppArmor Support — https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/24-apparmor
* KEP-2413 — Seccomp by Default — https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/2413-seccomp-by-default
* Linux kernel — Seccomp BPF (SECure COMPuting with filters) — https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html
* `seccomp(2)` man page — https://man7.org/linux/man-pages/man2/seccomp.2.html
* `seccomp_unotify(2)` man page — https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html
* `prctl(2)` — `PR_SET_NO_NEW_PRIVS` — https://man7.org/linux/man-pages/man2/prctl.2.html
* `capabilities(7)` man page — https://man7.org/linux/man-pages/man7/capabilities.7.html
* OCI Runtime Specification — Linux seccomp and AppArmor — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp
* containerd — default seccomp profile source — https://github.com/containerd/containerd/blob/main/contrib/seccomp/seccomp_default.go
* Moby — `profiles/seccomp/default.json` — https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
* AppArmor project wiki — https://gitlab.com/apparmor/apparmor/-/wikis/home
* `apparmor.d(5)` — profile language reference — https://manpages.ubuntu.com/manpages/noble/en/man5/apparmor.d.5.html
* `apparmor_parser(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/apparmor_parser.8.html
* `aa-status(8)`, `aa-logprof(8)`, `aa-complain(8)` — https://manpages.ubuntu.com/manpages/noble/en/man8/aa-status.8.html
* Linux LSM framework — https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html
* Security Profiles Operator — https://github.com/kubernetes-sigs/security-profiles-operator
* Security Profiles Operator — installation and usage — https://kubernetes-sigs.github.io/security-profiles-operator/
* CRI-O — seccomp and AppArmor support — https://github.com/cri-o/cri-o/blob/main/tutorials/decoupling.md
* Ubuntu — restricted unprivileged user namespaces — https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
* NIST SP 800-190 — Application Container Security Guide — https://csrc.nist.gov/publications/detail/sp/800-190/final