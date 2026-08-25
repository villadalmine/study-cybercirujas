# 333.2 — Mandatory Access Control

**LPIC-3 303 (Security), exam 303-300, version 3.0.0**
**Topic weight: 4 → 8.33 % of the exam**
**Scope: TE / RBAC / MAC / DAC concepts · SELinux in depth · AppArmor and Smack at operational level**

---

## 1. The architectural problem: why DAC is insufficient in production

### 1.1 The failure mode nobody designs for

Classic UNIX access control is **Discretionary**: the *owner* of an object decides who may access it, and any process running as that owner inherits the owner's full authority. Three structural consequences make this model unusable as the only defence in a production estate:

1. **Ambient authority.** A process is not a security principal — its UID is. `nginx` running as `root` for the first 100 ms of its life, or `postgres` running as UID 26, can touch *every* object that UID can touch, not just the objects its job requires. A remote code execution in `nginx` therefore yields "everything `nginx` could ever have done", not "everything `nginx` was doing".
2. **Discretion is delegable.** `chmod 777` is a legitimate DAC operation. Any compromised process can widen permissions on objects it owns; policy that a human wrote can be undone by code the attacker controls.
3. **`root` is the model's terminator.** UID 0 bypasses DAC entirely. Capabilities (`CAP_DAC_OVERRIDE`, `CAP_SETUID`, …) subdivide root but do not *scope* it: `CAP_DAC_OVERRIDE` is "ignore all file permissions", not "ignore file permissions under `/var/lib/myapp`".

The concrete production scenario that motivates MAC:

> A public-facing web server is compromised via an application-level flaw. Under DAC alone, the attacker's shell — running as `apache` — can read `/home/*/`, world-readable `/etc` files, connect outbound to any host and port, write to any `apache`-owned directory including the document root (persistence), and read every backup file whose permissions were relaxed for a migration three years ago. Nothing in the system distinguishes "the web server doing web-server things" from "the web server doing attacker things", because both are UID 48.

### 1.2 What MAC changes

**Mandatory Access Control** moves the decision out of the object owner's hands and into a **system-wide policy** enforced by the kernel:

- The policy is loaded by the administrator/vendor, not by processes.
- The decision is made on **security labels** attached to subjects (processes) and objects (files, sockets, ports, IPC, keys, capabilities…), not on ownership.
- **MAC is additive to DAC, never a replacement.** Every access must pass DAC *and* MAC. If DAC denies, MAC is never consulted (and no denial is audited by the MAC layer) — a fact that trips up 90 % of first-time troubleshooting.

The same compromise under a MAC policy: the shell runs as `httpd_t`. It may read `httpd_sys_content_t`, append to `httpd_log_t`, bind `http_port_t`. Reading `/etc/shadow` (`shadow_t`), writing to the document root (unless `httpd_sys_rw_content_t`), or connecting to an arbitrary TCP port are all denied — regardless of UID, regardless of `root`, regardless of file permissions.

### 1.3 Model taxonomy

| Model | Decision owner | Attached to | Revocable by compromised process | Typical Linux implementation |
|---|---|---|---|---|
| **DAC** — Discretionary | Object owner | UID/GID + mode bits, POSIX ACLs | Yes (`chmod`, `chown`, `setfacl`) | VFS permission checks, `CAP_DAC_OVERRIDE` |
| **MAC** — Mandatory | System policy | Security labels on subject and object | No | SELinux, Smack, (AppArmor: path-based MAC) |
| **TE** — Type Enforcement | System policy | *Type* of subject domain and object type | No | SELinux `allow` rules — the workhorse of the targeted policy |
| **RBAC** — Role-Based | System policy | Roles bound to users, roles authorised for types | No | SELinux users/roles + `newrole`; constrained by TE |
| **MLS/MCS** — Multi-Level / Multi-Category | System policy | Sensitivity levels + categories (Bell–LaPadula) | No | SELinux MLS policy; MCS is the single-sensitivity subset used for container isolation |

**How they compose in SELinux (order matters):**

```
DAC check  ──► passes ──►  TE check (allow rules)  ──►  RBAC/constraint check  ──►  MLS/MCS check  ──►  ACCESS
   │                              │                             │                          │
   └─ EACCES, no AVC              └─ AVC denied                 └─ AVC denied (constraint)  └─ AVC denied
```

TE is evaluated first and is where essentially all real policy lives. RBAC in SELinux is not a standalone model — roles restrict which *types* a user may enter, and the TE rules then decide what those types may do. MCS is a *lattice* check applied last: two container processes labelled `s0:c12,c803` and `s0:c44,c91` share the type `container_t` and are still mutually isolated because neither category set dominates the other.

### 1.4 Label-based vs path-based enforcement

| Dimension | Label-based (SELinux, Smack) | Path-based (AppArmor) |
|---|---|---|
| Where the security attribute lives | Extended attribute on the inode (`security.selinux`, `security.SMACK64`) | Nowhere — the profile matches the pathname used at open time |
| Survives `mv`, hardlink, bind mount | Yes (label travels with the inode) | No — a different path is a different rule match; hardlinks can bypass intent |
| Survives filesystem restore / `rsync` without `-X` | **No** — this is the #1 operational incident | N/A |
| Filesystem support required | xattr support (`ext4`, `xfs`, `btrfs`); otherwise `context=` mount option | None |
| Covers non-file objects (ports, IPC, keys, capabilities, netlink) | Yes, comprehensively | Partially (network coarse-grained, capabilities, signals, dbus, mount, unix sockets) |
| Policy authoring effort | High (refpolicy, macros, module build) | Low (readable per-binary profiles) |
| Failure mode when policy is wrong | Denial, auditable, granular | Denial, auditable, but path aliasing can silently under-enforce |
| Multi-tenant isolation of identical binaries | Native (MCS categories) | Requires profile-per-instance or `change_profile` |

**Architect's rule of thumb:** if the threat model includes *containers or tenants running the same image*, you need label + category isolation (SELinux/MCS) or you need a distinct profile per tenant. Path-based MAC does not natively express "these two identical processes must not see each other's data".

---

## 2. Where MAC lives in the kernel: the LSM framework

SELinux, AppArmor and Smack are not independent subsystems — all three are **Linux Security Modules**. The LSM framework places hooks at every security-relevant kernel decision point, *after* the standard DAC checks.

```
  syscall (open, connect, execve, ptrace, ...)
        │
        ▼
  ┌──────────────────────┐
  │ capability + DAC      │  ── denies ──► EACCES / EPERM  (no MAC audit record!)
  └──────────┬───────────┘
             │ allows
             ▼
  ┌──────────────────────┐
  │ security_file_open()  │   LSM hook
  │  → call chain          │
  └──────────┬───────────┘
             │
   ┌─────────┴──────────┬─────────────┬──────────────┐
   ▼                    ▼             ▼              ▼
capability          landlock        yama         selinux  ◄── "major" LSM (exclusive)
  (stacked minor LSMs run in CONFIG_LSM order)
             │
             ▼
     AVC cache hit? ── yes ──► decision
             │ no
             ▼
     Security Server evaluates loaded policy → cache → decision + optional audit
```

Verify what is actually active — never assume from the distribution:

```console
$ cat /sys/kernel/security/lsm
capability,landlock,lockdown,yama,integrity,selinux,bpf

$ cat /proc/cmdline
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.11.5-300.fc41.x86_64 root=/dev/mapper/vg0-root ro rhgb quiet

$ zgrep -E 'CONFIG_(LSM|SECURITY_SELINUX|SECURITY_APPARMOR|SECURITY_SMACK)=' /proc/config.gz
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SMACK=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"
```

**Critical operational fact:** SELinux, AppArmor and Smack are *exclusive* major LSMs — the kernel activates at most one of them. Minor LSMs (`capability`, `yama`, `lockdown`, `landlock`, `bpf`, `integrity`) stack freely alongside. Selection at boot:

```console
# Boot with a specific LSM set (overrides CONFIG_LSM):
lsm=capability,landlock,yama,bpf,apparmor

# Legacy per-module switches still honoured:
selinux=0        # SELinux off entirely (recommended way to disable on RHEL 9+)
apparmor=0
security=smack   # legacy exclusive selector
```

| Kernel parameter | Effect | Notes |
|---|---|---|
| `selinux=0` / `selinux=1` | Disable/enable SELinux in the kernel | The **only** clean way to fully disable on RHEL 9+ |
| `enforcing=0` | Boot SELinux in permissive mode | The recovery lever; keep it in your GRUB rescue notes |
| `autorelabel=1` (or `touch /.autorelabel`) | Relabel the whole filesystem on next boot | Reboots once more automatically |
| `apparmor=0` / `apparmor=1` | Disable/enable AppArmor | |
| `lsm=...` | Explicit ordered LSM list | Replaces `CONFIG_LSM` wholesale — omit an LSM and it is off |

---

## 3. SELinux architecture

### 3.1 Components

| Component | Lives in | Responsibility |
|---|---|---|
| **Security Server** | Kernel | Evaluates the loaded binary policy; answers "may `scontext` do `perm` on `tcontext:tclass`?" |
| **AVC (Access Vector Cache)** | Kernel | Caches decisions; hit ratio > 99.99 % in steady state — this is why SELinux overhead is negligible |
| **Object Managers** | Kernel (VFS, net, IPC) and userspace | Label objects and ask the Security Server. Userspace OMs: `systemd`, `dbus-daemon`, `sshd`, `xorg`, `postgresql` (via `sepgsql`), container runtimes |
| **selinuxfs** | `/sys/fs/selinux` | Kernel↔userspace interface: mode, policy load, booleans, AVC stats |
| **Policy store** | `/etc/selinux/<type>/` | Source-of-truth modules, plus the compiled `policy.<ver>` and the `file_contexts` databases |
| **libselinux / libsemanage / libsepol** | Userspace | The API behind every tool you will type |

```console
$ ls /sys/fs/selinux/
access     class            context           disable      enforce
avc        commit_pending_bools  create       deny_unknown  initial_contexts
booleans   checkreqprot     member            mls          null
policy     policy_capabilities   policyvers   reject_unknown  relabel
status     user             validatetrans

$ cat /sys/fs/selinux/enforce
1
$ cat /sys/fs/selinux/policyvers
33
```

### 3.2 The security context

Every subject and object carries a context with four fields:

```
   user       role        type            level (sensitivity[:categories])
     │          │           │                 │
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
system_u    :system_r    :httpd_t      :s0
system_u    :object_r    :httpd_sys_content_t:s0
system_u    :system_r    :container_t  :s0:c214,c802
```

- **SELinux user** (`_u`): a policy-level identity, *not* a UNIX user. Mapped from POSIX logins via `semanage login`.
- **Role** (`_r`): a set of types a user may enter. Files always carry `object_r` (roles are meaningless for objects).
- **Type** (`_t`): the field that carries ~all of the enforcement. On a subject it is called a **domain**.
- **Level**: `s0` (sensitivity) plus optional categories `c0,c15` or ranges `c0.c1023`. In the targeted policy only MCS is used; MLS policy uses the full sensitivity lattice `s0`–`s15`.

Read contexts everywhere with `-Z`:

```console
$ ps -eZ | grep -E 'httpd|sshd'
system_u:system_r:sshd_t:s0-s0:c0.c1023    1187 ?  00:00:00 sshd
system_u:system_r:httpd_t:s0               2914 ?  00:00:03 httpd
system_u:system_r:httpd_t:s0               2915 ?  00:00:00 httpd

$ ls -Z /var/www/html/
unconfined_u:object_r:httpd_sys_content_t:s0 index.html
system_u:object_r:httpd_sys_rw_content_t:s0  uploads

$ id -Z
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

$ ss -ltnZ | head -3
State  Recv-Q Send-Q Local:Port  Peer:Port  Process
LISTEN 0      511    *:80        *:*        users:(("httpd",pid=2914,proc_ctx=system_u:system_r:httpd_t:s0))

$ cat /proc/self/attr/current
unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

$ getfattr -n security.selinux -d /etc/shadow
# file: etc/shadow
security.selinux="system_u:object_r:shadow_t:s0"
```

### 3.3 Modes and configuration

```console
$ getenforce
Enforcing

$ selinuxenabled; echo "exit=$?"
exit=0                       # 0 = SELinux is enabled in the kernel (scriptable predicate)

$ sudo setenforce 0          # or: setenforce Permissive  — runtime only, NOT persistent
$ getenforce
Permissive

$ sudo sestatus -v
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   permissive
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actual (secure)
Max kernel policy version:      33

Process contexts:
Current context:                unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
Init context:                   system_u:system_r:init_t:s0
/usr/sbin/sshd                  system_u:system_r:sshd_t:s0-s0:c0.c1023

File contexts:
Controlling terminal:           unconfined_u:object_r:user_devpts_t:s0
/etc/passwd                     system_u:object_r:passwd_file_t:s0
/etc/shadow                     system_u:object_r:shadow_t:s0
/bin/bash                       system_u:object_r:shell_exec_t:s0
/bin/login                      system_u:object_r:login_exec_t:s0
/sbin/init                      system_u:object_r:bin_t:s0 -> system_u:object_r:init_exec_t:s0
/usr/sbin/sshd                  system_u:object_r:sshd_exec_t:s0
```

`/etc/selinux/config` — the persistent setting:

```ini
# /etc/selinux/config
#
# This file controls the state of SELinux on the system.
# SELINUX= can take one of these three values:
#     enforcing  - SELinux security policy is enforced.
#     permissive - SELinux prints warnings instead of enforcing.
#     disabled   - No SELinux policy is loaded.
# NOTE: On RHEL 9 / Fedora, disabling via this file is deprecated;
#       use selinux=0 on the kernel command line instead.
SELINUX=enforcing
#
# SELINUXTYPE= can take one of these values:
#     targeted - Targeted processes are protected,
#     minimum  - Modification of targeted policy. Only selected processes are protected.
#     mls      - Multi Level Security protection.
SELINUXTYPE=targeted
```

| Mode | Kernel enforces? | Denials audited? | Use case |
|---|---|---|---|
| **enforcing** | Yes | Yes | Production. Non-negotiable for regulated workloads |
| **permissive** | No | Yes (all of them, not just the first) | Policy development, migration, incident triage |
| **disabled** | No | No | Only with `selinux=0`; requires a full relabel to re-enable |

**The permissive-mode subtlety that costs people a second outage:** in enforcing mode, an operation that would trigger five denials often aborts at the first one, so you only see one AVC. In permissive mode the operation continues and *all five* are logged. Never declare a policy complete after a single enforcing-mode denial — run permissive, exercise the full workload, then collect.

**The disable/re-enable trap:** while SELinux is disabled, new and modified files get **no** `security.selinux` xattr. Re-enabling without a full relabel produces a system where `init` cannot transition and the boot hangs. The safe sequence:

```console
$ sudo touch /.autorelabel && sudo reboot
# ... boot shows: *** Warning -- SELinux targeted policy relabel is required.
# ... *** Relabeling could take a very long time, depending on file
# ... system size and speed of hard drives.
```

The directory layout that the objectives reference as `/etc/selinux/*`:

```console
$ tree -L 2 /etc/selinux
/etc/selinux
├── config
├── semanage.conf
├── targeted
│   ├── active            # the compiled, active policy store (do not edit by hand)
│   ├── contexts          # userspace object-manager context mappings
│   ├── policy            # policy.33 — the binary policy the kernel loads
│   ├── setrans.conf      # MLS/MCS label ↔ human-readable translation (mcstransd)
│   └── tmp
└── final

$ ls /etc/selinux/targeted/contexts/
customizable_types  dbus_contexts  default_contexts  default_type  failsafe_context
files/              lxc_contexts   openssh_contexts  removable_context  securetty_types
sepgsql_contexts    snapperd_contexts  userhelper_context  users/  virtual_domain_context

$ ls /etc/selinux/targeted/contexts/files/
file_contexts            file_contexts.homedirs      file_contexts.local
file_contexts.bin        file_contexts.homedirs.bin  file_contexts.local.bin
media
```

| Path | What it is | Edit it? |
|---|---|---|
| `/etc/selinux/config` | Mode + policy type at boot | **Yes**, by hand |
| `/etc/selinux/semanage.conf` | `semanage` behaviour: store root, module compiler, `bzip` compression, `expand-check` | Rarely |
| `/etc/selinux/targeted/policy/policy.33` | Binary policy loaded into the kernel | **Never** — generated |
| `/etc/selinux/targeted/contexts/files/file_contexts` | Vendor default file-context regexes | **Never** — package-owned |
| `/etc/selinux/targeted/contexts/files/file_contexts.local` | Your `semanage fcontext -a` entries | Never by hand — use `semanage` |
| `/etc/selinux/targeted/active/modules/<priority>/` | Installed policy modules by priority (100 = vendor, 400 = local override) | Never by hand |
| `/etc/selinux/targeted/setrans.conf` | Maps `s0:c1,c2` → `Internal`, etc. | Yes, for MLS deployments |

---

## 4. Type Enforcement in depth

### 4.1 Rule anatomy

```
allow  httpd_t  httpd_sys_content_t : file  { getattr open read ioctl lock map } ;
  │       │              │             │              │
  │       │              │             │              └── permission set (access vector)
  │       │              │             └── object class
  │       │              └── target type
  │       └── source type (domain)
  └── rule kind: allow | dontaudit | auditallow | neverallow
```

| Rule kind | Grants access | Writes audit record | Purpose |
|---|---|---|---|
| `allow` | Yes | No (unless `auditallow`) | The default: whitelist |
| `dontaudit` | No | **No** — suppresses the denial log | Silence known-harmless noise (e.g. probing `getattr`) |
| `auditallow` | Yes | Yes | Log a permitted but sensitive action |
| `neverallow` | Compile-time assertion | — | Fails the policy build if a module would grant it |

`dontaudit` is the single biggest source of "the tool works but there is no denial in the log". Turn it off during triage:

```console
$ sudo semodule -DB                   # rebuild policy with all dontaudit rules DISABLED
$ # ... reproduce the failure, collect AVCs ...
$ sudo semodule -B                    # rebuild, dontaudit restored
```

### 4.2 Querying the loaded policy (SETools)

`seinfo` and `sesearch` come from `setools-console`; the graphical policy-analysis tool `apol` from `setools-gui` / `setools-console-analyses`.

```console
$ sudo dnf install -y setools-console setools-gui policycoreutils-devel

$ seinfo

Statistics for policy file: /sys/fs/selinux/policy
Policy Version:             33 (MLS enabled)
Target Policy:              selinux
Handle unknown classes:     allow

  Classes:             135    Permissions:         463
  Sensitivities:         1    Categories:         1024
  Types:              5203    Attributes:          256
  Users:                 8    Roles:                15
  Booleans:            343    Cond. Expr.:         387
  Allow:            121846    Neverallow:            0
  Auditallow:          166    Dontaudit:          9843
  Type_trans:        22071    Type_change:          38
  Role allow:           40    Role_trans:          451
  Constraints:         101    Validatetrans:         0

$ seinfo -t | grep -c .
5204

$ seinfo -rsystem_r -x
  system_r
    Dominated Roles:
       system_r
    Types:
       abrt_t
       accountsd_t
       ...
       httpd_t
       sshd_t

$ seinfo --user -x
  users: 8
    system_u
      default level: s0
      range: s0 - s0:c0.c1023
      roles:
         object_r
         system_r
    unconfined_u
      default level: s0
      range: s0 - s0:c0.c1023
      roles:
         object_r
         system_r
         unconfined_r
    ...

$ seinfo -b | grep httpd | head -5
   httpd_anon_write
   httpd_builtin_scripting
   httpd_can_check_spam
   httpd_can_connect_ftp
   httpd_can_connect_ldap
```

**`sesearch` is how you answer "is this actually allowed?" without trial and error:**

```console
$ sesearch -A -s httpd_t -t httpd_sys_content_t -c file
allow httpd_t httpd_sys_content_t:file { getattr ioctl lock map open read };
allow httpd_t httpdcontent:file { append create ... }; [ httpd_unified ]:True

$ sesearch -A -s httpd_t -t shadow_t
# (no output) -> httpd_t has NO access to shadow_t. That is the point.

$ sesearch -A -s httpd_t -c tcp_socket -p name_connect
allow httpd_t http_cache_port_t:tcp_socket name_connect; [ httpd_can_network_relay ]:False
allow httpd_t port_type:tcp_socket name_connect; [ httpd_can_network_connect ]:False
allow httpd_t postgresql_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:False

# Domain transitions: which domains can httpd_t enter, and via which entrypoint?
$ sesearch -T -s httpd_t -c process
type_transition httpd_t httpd_sys_script_exec_t:process httpd_sys_script_t;
type_transition httpd_t httpd_php_exec_t:process httpd_php_t;
```

The bracketed suffix `[ boolean ]:False` is the crucial detail: the rule exists but is **conditional** and currently inactive.

### 4.3 Domain transitions

A domain transition is the mechanism by which `init_t` becomes `httpd_t` when it executes `/usr/sbin/httpd`. Three permissions must all be granted, or the process silently keeps its parent's domain (and then fails in confusing ways later):

```
allow init_t     httpd_exec_t : file    { getattr open read execute };   # 1. may execute the file
allow init_t     httpd_t      : process transition;                      # 2. may transition to the domain
allow httpd_t    httpd_exec_t : file    entrypoint;                      # 3. the file is a valid entrypoint
type_transition  init_t httpd_exec_t : process httpd_t;                  # 4. do it automatically
```

Analyse a transition path without reading policy source:

```console
$ sepolicy transition -s init_t -t httpd_t
init_t @ httpd_exec_t --> httpd_t

$ sepolicy transition -s httpd_t
httpd_t @ abrt_helper_exec_t --> abrt_helper_t
httpd_t @ antivirus_exec_t --> antivirus_t
httpd_t @ httpd_php_exec_t --> httpd_php_t
httpd_t @ httpd_suexec_exec_t --> httpd_suexec_t
httpd_t @ httpd_sys_script_exec_t --> httpd_sys_script_t
...

$ sepolicy network -d httpd_t
httpd_t: tcp name_connect to 80,81,443,488,8008,8009,8443,9000
httpd_t: tcp name_bind to 80,81,443,488,8008,8009,8443,9000
httpd_t: udp name_bind to 0

$ sepolicy network -p 9713
9713: tcp unreserved_port_t 9713
```

**The `NoNewPrivileges` interaction** — a real production gotcha when SELinux meets systemd hardening. Under `no_new_privs`, the kernel refuses SELinux domain transitions unless the policy grants the `process2` class permissions explicitly:

```console
$ sesearch -A -s init_t -t metricsd_t -c process2
allow init_t metricsd_t:process2 { nnp_transition nosuid_transition };
```

If a service with `NoNewPrivileges=yes` in its unit stays in `init_t` instead of entering its own domain, this is why. The fix is a policy rule (`init_nnp_daemon_domain(metricsd_t, metricsd_exec_t)` in refpolicy), not disabling the hardening.

---

## 5. Labels: assigning, fixing, and the three ways to get them wrong

### 5.1 The tool matrix

| Tool | Persistence | Scope | When to use |
|---|---|---|---|
| `chcon` | **Temporary** — lost on relabel | One path | Never in production. Debugging only |
| `semanage fcontext -a` + `restorecon` | Permanent (stored in `file_contexts.local`) | Regex over paths | **The correct way**, always |
| `restorecon` | Applies the stored default | Path/tree | After creating files, after `mv`, after restore |
| `setfiles` | Applies contexts from a *specified* spec file | Path/tree | Scripted/offline relabel; what `restorecon` wraps |
| `fixfiles` | Applies stored defaults | Whole FS, RPM package, or diff | Bulk repair, package repair, boot relabel |
| Mount options (`context=`) | Per-mount, no xattrs written | Whole mount | NFS, vfat, and read-only images |

### 5.2 The canonical workflow

```console
# Symptom: a web app served from a non-default document root returns 403.
$ ls -Zd /srv/www/app
unconfined_u:object_r:var_t:s0 /srv/www/app          # <- wrong type

# 1. Record the intended context in the policy store (persistent, regex-based)
$ sudo semanage fcontext -a -t httpd_sys_content_t "/srv/www(/.*)?"
$ sudo semanage fcontext -a -t httpd_sys_rw_content_t "/srv/www/app/var/uploads(/.*)?"

# 2. Verify what WOULD be applied before touching anything
$ sudo restorecon -Rvn /srv/www
Would relabel /srv/www from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Would relabel /srv/www/app from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Would relabel /srv/www/app/var/uploads from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_rw_content_t:s0

# 3. Apply
$ sudo restorecon -Rv /srv/www
Relabeled /srv/www from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
Relabeled /srv/www/app from unconfined_u:object_r:var_t:s0 to system_u:object_r:httpd_sys_content_t:s0
...

# 4. Confirm
$ ls -Z /srv/www/app | head -3
system_u:object_r:httpd_sys_content_t:s0 index.php
system_u:object_r:httpd_sys_content_t:s0 lib
system_u:object_r:httpd_sys_rw_content_t:s0 var

# Inspect / remove local entries
$ sudo semanage fcontext -l -C
SELinux fcontext                       type       Context

/srv/www(/.*)?                         all files  system_u:object_r:httpd_sys_content_t:s0
/srv/www/app/var/uploads(/.*)?         all files  system_u:object_r:httpd_sys_rw_content_t:s0

$ sudo semanage fcontext -d "/srv/www(/.*)?"
```

**Ordering rule:** `semanage fcontext` entries are matched **most-specific-regex-first** within `file_contexts.local`, and local entries take precedence over vendor entries. Always add the broad rule *and* the narrow exception; do not rely on insertion order.

### 5.3 `fixfiles` and `setfiles`

```console
# Repair every file owned by an RPM (surgical, fast)
$ sudo fixfiles -R httpd restore
$ sudo fixfiles -R httpd,mod_ssl check          # report only, do not change

# Repair a directory tree
$ sudo fixfiles -R '' restore /var/lib/pgsql

# Relabel only files whose context differs from the policy default,
# using a diff against the previous policy (fast post-upgrade repair)
$ sudo fixfiles -C /var/lib/selinux/targeted/active/commit_num restore

# Schedule a full relabel at next boot (equivalent to touch /.autorelabel)
$ sudo fixfiles onboot
System will relabel on next boot

# Full immediate relabel (expensive: hours on large filesystems)
$ sudo fixfiles -f relabel

# setfiles: apply an explicit spec file — used by fixfiles and by image builders
$ sudo setfiles -v /etc/selinux/targeted/contexts/files/file_contexts /srv/www
$ sudo setfiles -n -v /etc/selinux/targeted/contexts/files/file_contexts /srv/www   # dry run
$ sudo setfiles -r /mnt/rootfs /etc/selinux/targeted/contexts/files/file_contexts /mnt/rootfs
```

The `-r <root>` form is what you use to relabel an image or a rescue-mounted root: it strips the alternate root prefix before matching regexes.

### 5.4 Ports, network, and other object classes via `semanage`

```console
$ sudo semanage port -l | grep -E '^(http|ssh)_port_t'
http_port_t                    tcp      80, 81, 443, 488, 8008, 8009, 8443, 9000
ssh_port_t                     tcp      22

# Let httpd bind an extra port
$ sudo semanage port -a -t http_port_t -p tcp 8081
$ sudo semanage port -m -t http_port_t -p tcp 8081     # modify an existing definition
$ sudo semanage port -d -t http_port_t -p tcp 8081

$ sudo semanage port -l -C                              # local modifications only
SELinux Port Type              Proto    Port Number
http_port_t                    tcp      8081

# Other manageable object classes
$ sudo semanage interface -l
$ sudo semanage node -l
$ sudo semanage login -l
Login Name           SELinux User         MLS/MCS Range        Service
__default__          unconfined_u         s0-s0:c0.c1023       *
root                 unconfined_u         s0-s0:c0.c1023       *

$ sudo semanage user -l
SELinux User    Prefix    MCS Level  MCS Range           SELinux Roles
guest_u         user      s0         s0                  guest_r
staff_u         user      s0         s0-s0:c0.c1023      staff_r sysadm_r system_r unconfined_r
sysadm_u        user      s0         s0-s0:c0.c1023      sysadm_r
unconfined_u    user      s0         s0-s0:c0.c1023      system_r unconfined_r
user_u          user      s0         s0                  user_r
xguest_u        user      s0         s0                  xguest_r

# Export every local customisation — this is your reproducible configuration artifact
$ sudo semanage export -f /root/selinux-local.txt
$ cat /root/selinux-local.txt
boolean -D
login -D
port -D
fcontext -D
boolean -m -1 httpd_can_network_connect_db
port -a -t http_port_t -p tcp 8081
fcontext -a -f a -t httpd_sys_content_t -r 's0' '/srv/www(/.*)?'

# Re-import on a rebuilt host
$ sudo semanage import -f /root/selinux-local.txt
```

`semanage export | import` is the correct way to carry SELinux customisation into golden images and disaster recovery — not hand-copying `file_contexts.local`.

### 5.5 Mount-time labelling (filesystems without xattrs)

| Option | Effect |
|---|---|
| `context=CTX` | **Every** file on the mount presents `CTX`. Overrides on-disk xattrs. For NFS/vfat/iso9660 |
| `fscontext=CTX` | Labels the *filesystem object itself*; individual files keep their own labels |
| `defcontext=CTX` | Default label for newly created files that have no policy-derived default |
| `rootcontext=CTX` | Label of the mount's root inode only (used heavily by container runtimes) |

```console
$ sudo mount -t nfs -o context="system_u:object_r:httpd_sys_content_t:s0" \
      nfs01.prod:/export/web /srv/www

$ grep /srv/www /proc/mounts
nfs01.prod:/export/web /srv/www nfs4 rw,relatime,context=system_u:object_r:httpd_sys_content_t:s0,... 0 0
```

`/etc/fstab` equivalent:

```
nfs01.prod:/export/web  /srv/www  nfs4  rw,_netdev,context="system_u:object_r:httpd_sys_content_t:s0",hard,noatime  0 0
```

---

## 6. Booleans: policy switches without policy compilation

Booleans are `if` statements pre-compiled into the policy. They are the *first* thing to check for any denial, because a supported use case usually already has a switch.

```console
$ getsebool -a | wc -l
343

$ getsebool -a | grep httpd_can_network
httpd_can_network_connect --> off
httpd_can_network_connect_cobbler --> off
httpd_can_network_connect_db --> off
httpd_can_network_memcache --> off
httpd_can_network_relay --> off

$ getsebool httpd_can_network_connect_db
httpd_can_network_connect_db --> off

# Runtime only (lost on reboot) — good for testing
$ sudo setsebool httpd_can_network_connect_db on

# Persistent: -P rewrites the policy store. Slow (seconds), survives reboot.
$ sudo setsebool -P httpd_can_network_connect_db on

# Multiple at once — -P applies to all of them, one policy rebuild
$ sudo setsebool -P httpd_can_network_connect_db=1 httpd_use_nfs=1

# togglesebool: flip runtime state, print the result (policycoreutils)
$ sudo togglesebool httpd_enable_homedirs
httpd_enable_homedirs: active

# Descriptions and default vs current state
$ sudo semanage boolean -l | grep httpd_can_network_connect_db
httpd_can_network_connect_db   (off  ,  on)  Allow httpd to can network connect db
                                ^      ^
                             default  current

$ sudo semanage boolean -l -C            # only booleans changed from default
SELinux boolean                State  Default Description

httpd_can_network_connect_db   (on   ,   on)  Allow httpd to can network connect db

# Which rules does a boolean actually gate?
$ sesearch -A -b httpd_can_network_connect_db
allow httpd_t mysqld_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:True
allow httpd_t postgresql_port_t:tcp_socket name_connect; [ httpd_can_network_connect_db ]:True
```

| Approach | Blast radius | Correct when |
|---|---|---|
| `setsebool -P <specific>` | Exactly the rules gated by that boolean | A vendor-supported use case exists — **prefer this** |
| Custom module from `audit2allow` | Exactly the reviewed rules | No boolean covers it and the access is legitimate |
| `semanage permissive -a <domain>` | That domain is unconfined | Temporary, time-boxed, during migration only |
| `setenforce 0` | The entire system | Incident recovery only, never a steady state |
| `SELINUX=disabled` | Everything, forever | Never |

**Beware the wide boolean.** `httpd_can_network_connect=on` grants `name_connect` to *every* port type. If the requirement is "reach PostgreSQL", `httpd_can_network_connect_db` is one order of magnitude narrower, and a custom module naming `postgresql_port_t` is two.

---

## 7. RBAC in SELinux: users, roles, `newrole`, `runcon`

The targeted policy leaves interactive logins in `unconfined_t` by default. RBAC becomes real when you map logins to confined SELinux users.

```console
# Map a POSIX login to a confined SELinux user
$ sudo semanage login -a -s staff_u -r s0-s0:c0.c1023 alice
$ sudo semanage login -a -s user_u  -r s0 contractor
$ sudo semanage login -l
Login Name    SELinux User    MLS/MCS Range     Service
__default__   unconfined_u    s0-s0:c0.c1023    *
alice         staff_u         s0-s0:c0.c1023    *
contractor    user_u          s0                *
root          unconfined_u    s0-s0:c0.c1023    *

# Relabel the home directory to match the new user identity
$ sudo genhomedircon
$ sudo restorecon -R -F /home/alice

# alice logs in:
alice$ id -Z
staff_u:staff_r:staff_t:s0-s0:c0.c1023

alice$ sudo systemctl restart httpd     # DAC allows via sudoers, but staff_t cannot manage services
sudo: PERM_SUDOERS: setresuid(-1, 1, -1): Operation not permitted
```

`newrole` performs an authenticated **role transition** within the same login session (it re-authenticates the user and re-executes the shell in the new context):

```console
alice$ newrole -r sysadm_r -t sysadm_t
Password:
alice$ id -Z
staff_u:sysadm_r:sysadm_t:s0-s0:c0.c1023

# Full four-field form, including a level
alice$ newrole -r sysadm_r -t sysadm_t -l s0:c0.c1023

# Which role transitions are legal?
$ seinfo --role_allow | grep staff_r
   allow staff_r sysadm_r;
   allow staff_r unconfined_r;
   allow staff_r system_r;
```

`runcon` executes **one command** in a specified context (no re-authentication — the transition must already be permitted by policy, otherwise `execve` fails):

```console
$ runcon -t container_t -l s0:c42,c917 -- /usr/bin/id -Z
system_u:system_r:container_t:s0:c42,c917

$ runcon -u system_u -r system_r -t httpd_t /usr/sbin/httpd -DFOREGROUND

$ runcon system_u:system_r:httpd_t:s0 /bin/bash
runcon: /bin/bash: Permission denied     # policy has no entrypoint for bash into httpd_t

# Test an MCS-isolated read
$ runcon -l s0:c1,c2 cat /srv/tenant-a/data.db
cat: /srv/tenant-a/data.db: Permission denied      # file is s0:c3,c4 — categories do not dominate
```

| Tool | Re-authenticates | Changes | Typical use |
|---|---|---|---|
| `newrole` | Yes (password) | Role and/or type/level of the *session* | Administrative escalation under RBAC |
| `runcon` | No | Context of *one* exec'd command | Scripted/testing; MCS category assignment |
| `sudo -r <role> -t <type>` | Yes (sudo policy) | Role/type for the sudo'd command | The modern replacement for `newrole` in most estates |

---

## 8. Writing and shipping policy

### 8.1 From denial to module — the safe loop

```console
# 1. Reproduce with dontaudit disabled and the domain permissive
$ sudo semodule -DB
$ sudo semanage permissive -a metricsd_t
$ sudo systemctl restart metricsd && sleep 60 && curl -s localhost:9713/metrics >/dev/null

# 2. Explain WHY, before deciding what to allow
$ sudo ausearch -m AVC -c metricsd -ts recent -i | audit2why
type=AVC msg=audit(08/24/2026 11:23:19.441:1907) : avc:  denied  { name_connect } for
  pid=48117 comm=metricsd dest=5432
  scontext=system_u:system_r:metricsd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0 tclass=tcp_socket permissive=1

	Was caused by:
	Missing type enforcement (TE) allow rule.

	You can use audit2allow to generate a loadable module to allow this access.

# 3. Generate a REVIEWABLE module (never pipe blindly into semodule)
$ sudo ausearch -m AVC -c metricsd -ts recent -r > /tmp/metricsd.avc
$ audit2allow -i /tmp/metricsd.avc

#============= metricsd_t ==============
allow metricsd_t postgresql_port_t:tcp_socket name_connect;
allow metricsd_t proc_net_t:file { getattr open read };
allow metricsd_t self:capability dac_read_search;

# 4. Review each line. Reject anything that looks like a symptom of a mislabel.
#    'dac_read_search' here means the daemon is reading something it should not —
#    fix the label, do not grant the capability.

# 5. Build and install the reviewed module
$ audit2allow -i /tmp/metricsd.avc -M metricsd_local
******************** IMPORTANT ***********************
To make this policy package active, execute:

semodule -i metricsd_local.pp

$ cat metricsd_local.te
module metricsd_local 1.0;

require {
	type metricsd_t;
	type postgresql_port_t;
	type proc_net_t;
	class tcp_socket name_connect;
	class file { getattr open read };
}

#============= metricsd_t ==============
allow metricsd_t postgresql_port_t:tcp_socket name_connect;
allow metricsd_t proc_net_t:file { getattr open read };

$ sudo semodule -i metricsd_local.pp

# 6. Undo the temporary loosening and re-verify in enforcing
$ sudo semanage permissive -d metricsd_t
$ sudo semodule -B
$ sudo semanage permissive -l
Builtin Permissive Types

Customized Permissive Types
(none)
```

> **`audit2allow` is a code generator, not an oracle.** It converts "this was denied" into "allow this". If the denial is caused by a wrong label, a wrong port assignment, or an actual intrusion, `audit2allow` will faithfully write a rule legitimising it. The mandatory review step is: *for each rule, is the target type the one this service is supposed to touch?*

### 8.2 A complete, production-shaped policy module

Three source files plus a build. This is the shape of policy that ships with a product, not a patch on top of denials.

**`metricsd.te`**

```
policy_module(metricsd, 1.0.0)

########################################
#
# Declarations
#

## <desc>
##	<p>
##	Allow metricsd to connect to any network port.
##	</p>
## </desc>
gen_tunable(metricsd_connect_any, false)

type metricsd_t;
type metricsd_exec_t;
init_daemon_domain(metricsd_t, metricsd_exec_t)

type metricsd_conf_t;
files_config_file(metricsd_conf_t)

type metricsd_var_lib_t;
files_type(metricsd_var_lib_t)

type metricsd_log_t;
logging_log_file(metricsd_log_t)

type metricsd_runtime_t alias metricsd_var_run_t;
files_runtime_file(metricsd_runtime_t)

type metricsd_unit_t;
systemd_unit_file(metricsd_unit_t)

type metricsd_port_t;
corenet_port(metricsd_port_t)

########################################
#
# Local policy
#

allow metricsd_t self:capability { setgid setuid };
allow metricsd_t self:process { getsched setsched signal signull };
allow metricsd_t self:fifo_file rw_fifo_file_perms;
allow metricsd_t self:tcp_socket { create_stream_socket_perms accept listen };
allow metricsd_t self:unix_dgram_socket create_socket_perms;
allow metricsd_t self:netlink_route_socket r_netlink_socket_perms;

# Configuration: read-only
read_files_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)
read_lnk_files_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)
list_dirs_pattern(metricsd_t, metricsd_conf_t, metricsd_conf_t)

# State directory: read/write, with automatic labelling of new objects
manage_dirs_pattern(metricsd_t, metricsd_var_lib_t, metricsd_var_lib_t)
manage_files_pattern(metricsd_t, metricsd_var_lib_t, metricsd_var_lib_t)
files_var_lib_filetrans(metricsd_t, metricsd_var_lib_t, { dir file })

# Logs: append-only from the daemon's point of view
create_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
append_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
setattr_files_pattern(metricsd_t, metricsd_log_t, metricsd_log_t)
logging_log_filetrans(metricsd_t, metricsd_log_t, file)

# Runtime directory (/run/metricsd)
manage_dirs_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
manage_files_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
manage_sock_files_pattern(metricsd_t, metricsd_runtime_t, metricsd_runtime_t)
files_runtime_filetrans(metricsd_t, metricsd_runtime_t, { dir file sock_file })

# Network: bind only the assigned port
corenet_all_recvfrom_netlabel(metricsd_t)
corenet_tcp_sendrecv_generic_if(metricsd_t)
corenet_tcp_sendrecv_generic_node(metricsd_t)
corenet_tcp_bind_generic_node(metricsd_t)
allow metricsd_t metricsd_port_t:tcp_socket name_bind;

# Minimum viable system access
kernel_read_system_state(metricsd_t)
kernel_read_network_state(metricsd_t)
files_read_etc_files(metricsd_t)
files_read_usr_files(metricsd_t)
miscfiles_read_localization(metricsd_t)
miscfiles_read_generic_certs(metricsd_t)
sysnet_dns_name_resolve(metricsd_t)
auth_use_nsswitch(metricsd_t)

optional_policy(`
	systemd_read_fifo_file_passwd_run(metricsd_t)
	systemd_use_fds_logind(metricsd_t)
')

optional_policy(`
	# Scrape the local PostgreSQL exporter socket
	postgresql_stream_connect(metricsd_t)
')

tunable_policy(`metricsd_connect_any',`
	corenet_tcp_connect_all_ports(metricsd_t)
	corenet_tcp_sendrecv_all_ports(metricsd_t)
')
```

**`metricsd.fc`**

```
/usr/bin/metricsd                            --  gen_context(system_u:object_r:metricsd_exec_t,s0)
/usr/lib/systemd/system/metricsd\.service    --  gen_context(system_u:object_r:metricsd_unit_t,s0)
/etc/metricsd(/.*)?                              gen_context(system_u:object_r:metricsd_conf_t,s0)
/var/lib/metricsd(/.*)?                          gen_context(system_u:object_r:metricsd_var_lib_t,s0)
/var/log/metricsd(/.*)?                          gen_context(system_u:object_r:metricsd_log_t,s0)
/run/metricsd(/.*)?                              gen_context(system_u:object_r:metricsd_runtime_t,s0)
```

**`metricsd.if`** — the interface file other modules will call

```
## <summary>Prometheus-compatible metrics exporter.</summary>

########################################
## <summary>
##	Allow the specified domain to read metricsd state files.
## </summary>
## <param name="domain">
##	<summary>Domain allowed access.</summary>
## </param>
#
interface(`metricsd_read_state_files',`
	gen_require(`
		type metricsd_var_lib_t;
	')

	files_search_var_lib($1)
	read_files_pattern($1, metricsd_var_lib_t, metricsd_var_lib_t)
')

########################################
## <summary>
##	Connect to metricsd over its TCP port.
## </summary>
## <param name="domain">
##	<summary>Domain allowed access.</summary>
## </param>
#
interface(`metricsd_tcp_connect',`
	gen_require(`
		type metricsd_port_t;
	')

	allow $1 metricsd_port_t:tcp_socket name_connect;
')
```

**Build, install, verify:**

```console
$ sudo dnf install -y selinux-policy-devel policycoreutils-devel

$ make -f /usr/share/selinux/devel/Makefile metricsd.pp
Compiling targeted metricsd module
Creating targeted metricsd.pp policy package
rm tmp/metricsd.mod.fc tmp/metricsd.mod

# Or the low-level path the Makefile wraps:
$ checkmodule -M -m -o metricsd.mod metricsd.te
$ semodule_package -o metricsd.pp -m metricsd.mod -f metricsd.fc

$ sudo semodule -i metricsd.pp
$ sudo semodule -l | grep metricsd
metricsd

$ sudo semodule --list-modules=full | grep -E 'metricsd|^400'
400 metricsd          pp
100 metricsd          pp

$ sudo semanage port -a -t metricsd_port_t -p tcp 9713
$ sudo restorecon -RvF /usr/bin/metricsd /etc/metricsd /var/lib/metricsd /var/log/metricsd
$ sudo systemctl restart metricsd

$ ps -eZ | grep metricsd
system_u:system_r:metricsd_t:s0   48302 ?  00:00:00 metricsd

$ sepolicy manpage -d metricsd_t -p /usr/share/man/man8
/usr/share/man/man8/metricsd_selinux.8

# Bootstrapping a skeleton for a new daemon (generates .te/.fc/.if/.sh)
$ sepolicy generate --init /usr/bin/metricsd
Created the following files:
/root/policy/metricsd.te     # Type Enforcement file
/root/policy/metricsd.if     # Interface file
/root/policy/metricsd.fc     # File Contexts file
/root/policy/metricsd_selinux.spec  # Spec file
/root/policy/metricsd.sh     # Setup Script
```

### 8.3 Module priorities and CIL

`semodule` supports priorities: higher priority wins for identically named modules. Priority **100** is the distribution default; **400** is the conventional local-override slot.

```console
# Override a vendor module without editing it
$ sudo semodule -X 400 -i my-httpd-override.pp

# Ship a tiny CIL module (no compilation toolchain needed — semodule ingests CIL directly)
$ cat > local_metricsd.cil <<'EOF'
(allow metricsd_t postgresql_port_t (tcp_socket (name_connect)))
(allow metricsd_t node_t (tcp_socket (node_bind)))
EOF
$ sudo semodule -X 400 -i local_metricsd.cil

$ sudo semodule -d unconfineduser          # disable a module
$ sudo semodule -e unconfineduser          # enable it again
$ sudo semodule -r metricsd                # remove (from priority 400 if -X 400 given)
$ sudo semodule -B                         # rebuild + reload policy from the store
$ sudo semodule --checksum metricsd
metricsd sha256:5f1c...c2a9
```

For containers, `udica` generates a tailored CIL policy from a running container's inspect output — the pragmatic path to per-workload confinement:

```console
$ sudo podman inspect metrics-exporter > /tmp/ctr.json
$ udica -j /tmp/ctr.json metrics_exporter
Policy metrics_exporter created!

Please load these modules using:
# semodule -i metrics_exporter.cil /usr/share/udica/templates/{base_container.cil,net_container.cil}

Restart the container with: "--security-opt label=type:metrics_exporter.process"
```

---

## 9. Diagnostics: reading denials like a systems engineer

### 9.1 Anatomy of an AVC record

```
type=AVC msg=audit(1755980412.317:1043): avc:  denied  { name_connect } for
  pid=2914 comm="httpd" dest=5432
  scontext=system_u:system_r:httpd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0
  tclass=tcp_socket permissive=0
```

| Field | Meaning | What to do with it |
|---|---|---|
| `audit(1755980412.317:1043)` | epoch.ms : serial | Correlate with the rest of the event group (`SYSCALL`, `PATH`, `CWD`) by serial |
| `denied { name_connect }` | The permission(s) refused | Feed into `sesearch -p` to check whether a boolean gates it |
| `pid` / `comm` | Offending process | Confirm it is the process you think it is |
| `scontext` | Subject (process) context | If this is `unconfined_t`, your daemon never transitioned — that is the real bug |
| `tcontext` | Object context | If this is `default_t`, `var_t` or `admin_home_t`, you have a **mislabel**, not a missing rule |
| `tclass` | Object class | `file` vs `dir` vs `lnk_file` vs `tcp_socket` — the class is part of the rule |
| `permissive=0/1` | Was it enforced | `1` means the operation succeeded and this is informational |

**The decision rule that prevents 80 % of bad policy:**

```
tcontext is a *_t belonging to another service, or default_t / var_t / admin_home_t / user_home_t
        └──► MISLABEL. Fix with semanage fcontext + restorecon. Do NOT audit2allow.

tcontext is the correct type, and sesearch shows a rule gated by [ boolean ]:False
        └──► setsebool -P <boolean> on

tcontext is correct, no boolean exists, access is genuinely required
        └──► custom module (reviewed)

scontext is unconfined_t / init_t for a daemon that should be confined
        └──► the binary has the wrong label, or NoNewPrivileges blocks the transition
```

### 9.2 The toolchain

```console
# Full event group: AVC + SYSCALL + PATH + PROCTITLE, human-readable
$ sudo ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts recent -i
----
type=PROCTITLE msg=audit(08/24/2026 11:23:19.441:1907) : proctitle=/usr/sbin/httpd -DFOREGROUND
type=SOCKADDR msg=audit(08/24/2026 11:23:19.441:1907) : saddr={ saddr_fam=inet laddr=10.42.0.7 lport=5432 }
type=SYSCALL msg=audit(08/24/2026 11:23:19.441:1907) : arch=x86_64 syscall=connect
  success=no exit=EACCES(Permission denied) a0=0xd a1=0x7ffd2f1c a2=0x10 a3=0x0 items=0
  ppid=1 pid=2914 auid=unset uid=apache gid=apache euid=apache suid=apache fsuid=apache
  egid=apache sgid=apache fsgid=apache tty=(none) ses=unset comm=httpd exe=/usr/sbin/httpd
  subj=system_u:system_r:httpd_t:s0 key=(null)
type=AVC msg=audit(08/24/2026 11:23:19.441:1907) : avc:  denied  { name_connect } for
  pid=2914 comm=httpd dest=5432 scontext=system_u:system_r:httpd_t:s0
  tcontext=system_u:object_r:postgresql_port_t:s0 tclass=tcp_socket permissive=0

# Narrow by time, process, or subject context
$ sudo ausearch -m AVC -ts today -c nginx -i
$ sudo ausearch -m AVC -ts 11:00 -te 11:30 -i
$ sudo ausearch -m AVC --subject system_u:system_r:httpd_t:s0 -i
$ sudo ausearch -m AVC -ts boot -i | grep -c denied

# Aggregate: what is actually noisy?
$ sudo aureport -a --summary

AVC Summary Report
===================================
total  comm
===================================
   412  httpd
    37  metricsd
     4  sshd

# journald path (when auditd is not running, AVCs land in the journal via kaudit)
$ sudo journalctl -t setroubleshoot --since "-1h"
$ sudo journalctl _TRANSPORT=audit --since today | grep AVC

# Human-readable analysis with remediation hints (setroubleshoot-server)
$ sudo sealert -a /var/log/audit/audit.log
SELinux is preventing /usr/sbin/httpd from name_connect access on the tcp_socket port 5432.

*****  Plugin catchall_boolean (89.3 confidence) suggests  ********************

If you want to allow httpd to can network connect db
Then you must tell SELinux about this by enabling the 'httpd_can_network_connect_db' boolean.

Do
setsebool -P httpd_can_network_connect_db 1

*****  Plugin catchall (11.6 confidence) suggests  ***************************

If you believe that httpd should be allowed name_connect access on the port 5432
  tcp_socket by default.
Then you should report this as a bug.
...

Additional Information:
Source Context                system_u:system_r:httpd_t:s0
Target Context                system_u:object_r:postgresql_port_t:s0
Target Objects                port 5432 [ tcp_socket ]
Source                        httpd
Source Path                   /usr/sbin/httpd
Policy RPM                    selinux-policy-40.13.13-1.fc41.noarch
Enforcing Mode                Enforcing
Local ID                      3a9b71c2-1c88-4b1c-9a41-3c02a2f6f101

# Per-alert detail
$ sudo sealert -l 3a9b71c2-1c88-4b1c-9a41-3c02a2f6f101

# AVC cache health — a low hit ratio means the cache is thrashing (rare; usually a policy bug)
$ sudo avcstat 5
   lookups       hits     misses     allocs    reclaims      frees
  73282516   73280109       2407       2407        1728       1789
      5187       5187          0          0           0          0
      4903       4903          0          0           0          0
```

**`seaudit` note.** The exam objectives list `seaudit` (and `seaudit-report`), the SETools 3 GUI for browsing audit logs against a policy. **SETools 4 removed `seaudit`, `seaudit-report`, `sediffx` and `sechecker`.** On any current distribution the equivalent workflow is `ausearch` + `audit2why`/`audit2allow` + `sealert`, with `apol` remaining as the graphical *policy* analysis tool. Know the name and its purpose for the exam; use the modern tools in production.

```console
$ apol /sys/fs/selinux/policy &        # Qt GUI: type/attribute queries, information-flow and
                                        # domain-transition analysis, TE/RBAC/MLS rule browsing
$ apol /etc/selinux/targeted/policy/policy.33 &
```

### 9.3 Failure catalogue

| Symptom | Likely cause | Diagnostic | Fix |
|---|---|---|---|
| Service returns 403/EACCES, **no AVC in the log** | DAC denied first, or a `dontaudit` rule | `ls -l`, then `semodule -DB` and retry | Fix POSIX permissions; or read the newly visible AVC |
| Works after `setenforce 0` | Genuine MAC denial | `ausearch -m AVC -ts recent` | Boolean, or reviewed module |
| Files became inaccessible after a restore/`rsync` | xattrs not preserved | `ls -Z`, `restorecon -Rvn` | `restorecon -Rv`; use `rsync -aAX` / `tar --xattrs --selinux` |
| Daemon runs as `unconfined_t` or `init_t` | Binary has the wrong label, or `NoNewPrivileges` blocks the transition | `ls -Z /usr/bin/x`; `ps -eZ` | `restorecon` the binary; add `process2 { nnp_transition }` |
| Service fails to bind a non-standard port | Port not in the policy's port type | `semanage port -l \| grep <n>` | `semanage port -a -t <type> -p tcp <n>` |
| Boot hangs after re-enabling SELinux | Unlabelled filesystem | Boot with `enforcing=0` | `touch /.autorelabel && reboot` |
| Systemd unit fails with `Failed at step SELINUX` | `SELinuxContext=` names a context the policy will not permit | `journalctl -u <unit> -b` | Correct the context, or remove the directive and rely on `type_transition` |
| Container cannot read a bind-mounted host directory | Host dir is not `container_file_t` | `ls -Zd <dir>` | `podman run -v /data:/data:Z`, or `semanage fcontext -a -t container_file_t` |
| Two containers can see each other's mounted data | MCS categories disabled or identical | `ps -eZ \| grep container_t` | Ensure the runtime assigns distinct `s0:cX,cY`; do not use `label=disable` |
| `setsebool -P` takes 30 s and spikes CPU | Full policy-store rebuild | expected | Batch multiple booleans into one `-P` invocation |
| `semanage` fails: `SELinux policy is not managed or store cannot be accessed` | Running against a store the tool cannot write, or SELinux disabled at boot | `sestatus`, `ls /etc/selinux/targeted/active` | Re-enable SELinux; check `/etc/selinux/semanage.conf` `store-root` |

### 9.4 The recovery lever you must memorise

```
# At the GRUB menu, press 'e', append to the linux line:
enforcing=0

# After boot, from a shell:
$ sudo ausearch -m AVC -ts boot -i > /root/boot-avcs.txt
$ sudo restorecon -Rv /etc /var /usr        # or: touch /.autorelabel && reboot
$ sudo setenforce 1
```

Never `selinux=0` as a first response: it stops xattr maintenance and converts a five-minute fix into a full-filesystem relabel.

---

## 10. Production integration

### 10.1 systemd

```ini
# /etc/systemd/system/metricsd.service
[Unit]
Description=Prometheus metrics exporter
Documentation=https://example.internal/docs/metricsd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/metricsd --config /etc/metricsd/metricsd.yaml --listen 0.0.0.0:9713
User=metricsd
Group=metricsd

# --- MAC ---------------------------------------------------------------
# SELinux: normally omit this and let the policy's type_transition do the work.
# Set it explicitly only when the unit must run in a non-default domain.
SELinuxContext=system_u:system_r:metricsd_t:s0
# AppArmor equivalent (ignored on SELinux systems, and vice versa):
#AppArmorProfile=metricsd
# Smack equivalent:
#SmackProcessLabel=Metrics

# --- Classic hardening (composes with, does not replace, MAC) -----------
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

StateDirectory=metricsd
LogsDirectory=metricsd
RuntimeDirectory=metricsd
ReadWritePaths=/var/lib/metricsd /var/log/metricsd

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```console
$ sudo systemctl daemon-reload && sudo systemctl restart metricsd
$ systemctl show metricsd -p SELinuxContext -p NoNewPrivileges
SELinuxContext=system_u:system_r:metricsd_t:s0
NoNewPrivileges=yes

$ sudo systemd-analyze security metricsd
NAME                                          DESCRIPTION                            EXPOSURE
✓ SELinuxContext=                             Service has an SELinux label
✓ NoNewPrivileges=                            Service processes cannot acquire new privileges
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN        Service has no administrator privileges
...
→ Overall exposure level for metricsd.service: 1.8 OK 🙂
```

**Pitfall:** `AppArmorProfile=` combined with `NoNewPrivileges=yes` breaks exec-triggered profile transitions inside the service, because the kernel refuses transitions that could grant privilege to a `no_new_privs` task. If a helper binary inside the service must run under a different profile, the profile must stack (`px -> child` with `Cx`/`stack`) rather than transition, or `NoNewPrivileges=` must be relaxed for that unit.

### 10.2 Containers (Podman / CRI-O)

```console
$ sudo podman run -d --name web -p 8080:80 \
    -v /srv/www:/usr/share/nginx/html:ro,Z \
    docker.io/library/nginx:1.27

$ ps -eZ | grep nginx
system_u:system_r:container_t:s0:c214,c802  51234 ?  00:00:00 nginx

$ ls -Zd /srv/www
system_u:object_r:container_file_t:s0:c214,c802 /srv/www
```

| Volume flag | Effect | Use when |
|---|---|---|
| `:z` | Relabel to `container_file_t` with **no** MCS categories — shared by all containers | Multiple containers must share the volume |
| `:Z` | Relabel to `container_file_t` with **this container's private** categories | Single-container private data — **prefer this** |
| *(none)* | No relabel; container gets a denial unless the host label already matches | Host label is already correct |

```console
# Run in a custom, udica-generated domain
$ sudo podman run --security-opt label=type:metrics_exporter.process ...

# Pin the MCS level explicitly (stable across restarts — needed for shared PVs)
$ sudo podman run --security-opt label=level:s0:c100,c200 ...

# The escape hatch — audit any use of it
$ sudo podman run --security-opt label=disable ...
$ ps -eZ | grep nginx
system_u:system_r:spc_t:s0   51999 ?  00:00:00 nginx        # spc_t = "super privileged container": unconfined
```

**`:z` vs `:Z` is a real multi-tenancy control.** `:z` strips categories, which means every `container_t` process on the host can read that volume. On a shared node this silently converts per-container isolation into host-wide sharing.

### 10.3 Kubernetes: SELinux-confined workload

```yaml
# selinux-confined-workload.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-exporter
  namespace: tenant-a
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: metricsd-config
  namespace: tenant-a
data:
  metricsd.yaml: |
    listen: 0.0.0.0:9713
    scrape_interval: 15s
    targets:
      - name: postgres
        dsn: postgresql://exporter@db.tenant-a.svc:5432/appdb?sslmode=verify-full
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-exporter
  namespace: tenant-a
  labels:
    app.kubernetes.io/name: metrics-exporter
    app.kubernetes.io/part-of: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: metrics-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: metrics-exporter
    spec:
      serviceAccountName: metrics-exporter
      automountServiceAccountToken: false
      # Pod-level security context: SELinux label applies to the whole pod
      # (all containers AND the volumes the kubelet relabels for it).
      securityContext:
        runAsNonRoot: true
        runAsUser: 10113
        runAsGroup: 10113
        fsGroup: 10113
        seccompProfile:
          type: RuntimeDefault
        seLinuxOptions:
          # user/role are normally left to the runtime defaults (system_u:system_r).
          # 'type' selects the confinement domain; 'level' provides MCS isolation.
          type: container_t
          level: "s0:c101,c201"
      containers:
        - name: metricsd
          image: registry.internal/observability/metricsd:1.8.2
          imagePullPolicy: IfNotPresent
          args:
            - --config=/etc/metricsd/metricsd.yaml
          ports:
            - name: metrics
              containerPort: 9713
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            # Container-level seLinuxOptions override the pod-level value
            # for this container's process (but not for volume relabelling).
            seLinuxOptions:
              type: container_t
              level: "s0:c101,c201"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - name: config
              mountPath: /etc/metricsd
              readOnly: true
            - name: state
              mountPath: /var/lib/metricsd
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /-/healthy
              port: metrics
            initialDelaySeconds: 10
            periodSeconds: 20
          readinessProbe:
            httpGet:
              path: /-/ready
              port: metrics
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: metricsd-config
            defaultMode: 0444
        - name: state
          emptyDir:
            sizeLimit: 128Mi
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-exporter
  namespace: tenant-a
spec:
  selector:
    app.kubernetes.io/name: metrics-exporter
  ports:
    - name: metrics
      port: 9713
      targetPort: metrics
      protocol: TCP
```

Verification on the node:

```console
$ kubectl -n tenant-a get pod -o jsonpath='{.items[*].spec.securityContext.seLinuxOptions}' | jq
{
  "level": "s0:c101,c201",
  "type": "container_t"
}

$ kubectl -n tenant-a exec deploy/metrics-exporter -- cat /proc/self/attr/current
system_u:system_r:container_t:s0:c101,c201

# On the node itself:
[node]$ sudo crictl ps --name metricsd -q | xargs -I{} sudo crictl inspect {} \
          | jq -r '.info.runtimeSpec.linux.mountLabel, .status.labels'
system_u:object_r:container_file_t:s0:c101,c201

[node]$ ps -eZ | grep metricsd
system_u:system_r:container_t:s0:c101,c201  84211 ?  00:00:01 metricsd
```

> **Note on volume relabelling.** Historically the kubelet performed a *recursive* `chcon` on volumes with a pod-specific label, which is O(files) and can stall pod startup for minutes on large PVs. Recent Kubernetes versions pass the label as a `-o context=` mount option instead (feature gates around `SELinuxMountReadWriteOncePod` / `SELinuxMount`, plus the `spec.securityContext.seLinuxChangePolicy` field with values `MountOption` and `Recursive`). Check `kubectl explain pod.spec.securityContext.seLinuxChangePolicy` on your cluster version before relying on either behaviour.

### 10.4 Kubernetes: AppArmor-confined workload

```yaml
# apparmor-confined-workload.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-nginx
  namespace: tenant-a
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: nginx
      image: registry.internal/base/nginx:1.27
      securityContext:
        # GA field since Kubernetes 1.30. Replaces the deprecated annotation
        # container.apparmor.security.beta.kubernetes.io/<container>: localhost/<profile>
        appArmorProfile:
          type: Localhost              # RuntimeDefault | Localhost | Unconfined
          localhostProfile: k8s-nginx-hardened
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
      ports:
        - containerPort: 80
```

Profiles must exist on every node before the pod schedules. The standard distribution mechanism:

```yaml
# apparmor-loader-daemonset.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: kube-system
data:
  k8s-nginx-hardened: |
    #include <tunables/global>

    profile k8s-nginx-hardened flags=(attach_disconnected,mediate_deleted) {
      #include <abstractions/base>
      #include <abstractions/nameservice>
      #include <abstractions/openssl>

      capability net_bind_service,
      capability setuid,
      capability setgid,

      network inet  stream,
      network inet6 stream,

      /usr/sbin/nginx        mr,
      /etc/nginx/**          r,
      /usr/share/nginx/**    r,
      /var/log/nginx/*.log   w,
      /var/cache/nginx/**    rw,
      /run/nginx.pid         rw,
      /dev/urandom           r,
      /proc/sys/kernel/ngroups_max r,

      # Explicit denials: audited even though nothing would have granted them
      deny /etc/shadow             rwklx,
      deny /root/**                rwklx,
      deny /home/**                rwklx,
      deny /var/run/secrets/**     rwklx,
      deny /**                     wl,
      deny /bin/**                 x,
      deny /usr/bin/**             x,
      deny mount,
      deny ptrace,
    }
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
  template:
    metadata:
      labels:
        app.kubernetes.io/name: apparmor-loader
    spec:
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: loader
          image: registry.internal/base/apparmor-loader:1.2.0
          args: ["-poll", "60s", "/profiles"]
          securityContext:
            privileged: true              # apparmor_parser requires CAP_MAC_ADMIN on the host
          volumeMounts:
            - name: profiles
              mountPath: /profiles
              readOnly: true
            - name: apparmorfs
              mountPath: /sys/kernel/security
            - name: apparmor-includes
              mountPath: /etc/apparmor.d
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 128Mi }
      volumes:
        - name: profiles
          configMap:
            name: apparmor-profiles
        - name: apparmorfs
          hostPath:
            path: /sys/kernel/security
            type: Directory
        - name: apparmor-includes
          hostPath:
            path: /etc/apparmor.d
            type: Directory
```

### 10.5 Ansible baseline (idempotent SELinux configuration)

```yaml
# roles/selinux-baseline/tasks/main.yml
---
- name: Ensure SELinux tooling is present
  ansible.builtin.package:
    name:
      - policycoreutils
      - policycoreutils-python-utils
      - selinux-policy-targeted
      - setools-console
      - setroubleshoot-server
      - libselinux-python3
    state: present

- name: Enforce targeted policy at boot
  ansible.posix.selinux:
    policy: targeted
    state: enforcing
  register: selinux_state

- name: Report that a reboot is required to reach the configured state
  ansible.builtin.debug:
    msg: "SELinux state change requires reboot: {{ selinux_state.reboot_required }}"
  when: selinux_state.reboot_required | default(false)

- name: Set required booleans persistently
  ansible.posix.seboolean:
    name: "{{ item }}"
    state: true
    persistent: true
  loop:
    - httpd_can_network_connect_db
    - httpd_use_nfs
    - nis_enabled

- name: Declare file contexts for application data
  community.general.sefcontext:
    target: "{{ item.target }}"
    setype: "{{ item.setype }}"
    ftype: a
    state: present
  loop:
    - { target: '/srv/www(/.*)?',                 setype: httpd_sys_content_t }
    - { target: '/srv/www/app/var/uploads(/.*)?', setype: httpd_sys_rw_content_t }
    - { target: '/var/lib/metricsd(/.*)?',        setype: metricsd_var_lib_t }
  notify: restore application contexts

- name: Assign non-standard ports
  community.general.seport:
    ports: "{{ item.port }}"
    proto: tcp
    setype: "{{ item.setype }}"
    state: present
  loop:
    - { port: '8081', setype: http_port_t }
    - { port: '9713', setype: metricsd_port_t }

- name: Assert no permissive domains remain in production
  ansible.builtin.command: semanage permissive -l -n
  register: permissive_domains
  changed_when: false
  failed_when: permissive_domains.stdout | trim | length > 0

# roles/selinux-baseline/handlers/main.yml
---
- name: restore application contexts
  ansible.builtin.command: restorecon -Rv /srv/www /var/lib/metricsd
```

---

## 11. AppArmor

### 11.1 Architecture and posture

AppArmor is **path-based MAC**: profiles are attached to executables by pathname, and rules mediate access by pathname pattern. No filesystem metadata is involved, which makes it dramatically easier to author and dramatically weaker at expressing object identity.

Default on Debian, Ubuntu and SUSE. Profiles live in `/etc/apparmor.d/`, named by escaping the binary path (`/usr/sbin/nginx` → `usr.sbin.nginx`).

```console
$ sudo aa-status
apparmor module is loaded.
57 profiles are loaded.
49 profiles are in enforce mode.
   /usr/bin/man
   /usr/lib/NetworkManager/nm-dhcp-client.action
   /usr/sbin/nginx
   /usr/sbin/sshd
   docker-default
   lsb_release
   man_filter
   man_groff
   ...
6 profiles are in complain mode.
   /usr/bin/metricsd
   ...
2 profiles are in kill mode.
0 profiles are in unconfined mode.
9 processes have profiles defined.
7 processes are in enforce mode.
   /usr/sbin/nginx (1204)
   /usr/sbin/nginx (1205)
   /usr/sbin/sshd (988)
   ...
2 processes are in complain mode.
   /usr/bin/metricsd (48302)
0 processes are unconfined but have a profile defined.
0 processes are in mixed mode.
0 processes are in kill mode.

$ sudo aa-status --json | jq '.profiles | to_entries | group_by(.value) | map({mode: .[0].value, count: length})'
[
  { "mode": "complain", "count": 6 },
  { "mode": "enforce",  "count": 49 },
  { "mode": "kill",     "count": 2 }
]

$ sudo aa-unconfined --paranoid
988 /usr/sbin/sshd confined by '/usr/sbin/sshd (enforce)'
1204 /usr/sbin/nginx confined by '/usr/sbin/nginx (enforce)'
2311 /usr/bin/redis-server not confined
2450 /usr/local/bin/legacy-agent not confined

$ cat /proc/1204/attr/current
/usr/sbin/nginx (enforce)

$ sudo cat /sys/kernel/security/apparmor/profiles | head -5
/usr/bin/man (enforce)
/usr/sbin/nginx (enforce)
/usr/sbin/sshd (enforce)
docker-default (enforce)
/usr/bin/metricsd (complain)
```

`aa-unconfined` scans listening network processes and reports which are unprofiled — the single most useful "what is my coverage gap?" command in an AppArmor estate.

### 11.2 Profile modes and lifecycle

| Mode | Behaviour | Command |
|---|---|---|
| **enforce** | Deny and log | `aa-enforce /etc/apparmor.d/usr.sbin.nginx` |
| **complain** | Allow and log (learning mode) | `aa-complain /etc/apparmor.d/usr.sbin.nginx` |
| **kill** | Deny and `SIGKILL` the task | `flags=(kill)` in the profile |
| **unconfined** | Profile loaded but inert | `flags=(unconfined)` |
| **disabled** | Profile not loaded; symlink in `disable/` | `aa-disable /etc/apparmor.d/usr.sbin.nginx` |

```console
$ sudo aa-complain /usr/sbin/nginx
Setting /etc/apparmor.d/usr.sbin.nginx to complain mode.

$ sudo aa-enforce /usr/sbin/nginx
Setting /etc/apparmor.d/usr.sbin.nginx to enforce mode.

$ sudo aa-disable /usr/sbin/nginx
Disabling /etc/apparmor.d/usr.sbin.nginx.
$ ls -l /etc/apparmor.d/disable/
lrwxrwxrwx 1 root root 31 Aug 24 11:42 usr.sbin.nginx -> /etc/apparmor.d/usr.sbin.nginx

# Low-level parser operations
$ sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx     # replace (reload)
$ sudo apparmor_parser -R /etc/apparmor.d/usr.sbin.nginx     # remove from kernel
$ sudo apparmor_parser -Q /etc/apparmor.d/usr.sbin.nginx     # syntax check only, do not load
$ sudo apparmor_parser -a /etc/apparmor.d/usr.sbin.nginx     # add
$ sudo systemctl reload apparmor                             # reload every profile

# Run a command under a chosen profile without a systemd unit
$ aa-exec -p /usr/bin/metricsd -- /usr/bin/metricsd --config /etc/metricsd/metricsd.yaml
```

### 11.3 Profile syntax — a complete, production-grade profile

```
# /etc/apparmor.d/usr.sbin.nginx
abi <abi/3.0>,

include <tunables/global>

@{NGINX_PREFIX}=/usr/share/nginx
@{NGINX_DATA}=/srv/www

profile nginx /usr/sbin/nginx flags=(attach_disconnected,mediate_deleted) {
  include <abstractions/base>
  include <abstractions/nameservice>
  include <abstractions/openssl>
  include <abstractions/ssl_certs>

  # ---- Capabilities: exactly what the master process needs ----------------
  capability net_bind_service,
  capability setuid,
  capability setgid,
  capability dac_override,
  capability chown,

  # ---- Network ------------------------------------------------------------
  network inet  stream,
  network inet6 stream,
  network inet  dgram,
  network inet6 dgram,
  network netlink raw,
  deny network inet  raw,
  deny network packet,

  # ---- Executables --------------------------------------------------------
  /usr/sbin/nginx                       mr,
  /usr/lib/nginx/modules/*.so           mr,

  # ---- Configuration: read-only ------------------------------------------
  /etc/nginx/                           r,
  /etc/nginx/**                         r,
  /etc/ssl/private/nginx-*.key          r,

  # ---- Content ------------------------------------------------------------
  @{NGINX_PREFIX}/**                    r,
  @{NGINX_DATA}/                        r,
  @{NGINX_DATA}/**                      r,
  @{NGINX_DATA}/uploads/**              rw,

  # ---- Runtime state ------------------------------------------------------
  /var/log/nginx/                       r,
  /var/log/nginx/*.log                  w,
  /var/lib/nginx/**                     rw,
  /var/cache/nginx/**                   rwk,
  /run/nginx.pid                        rw,
  /run/nginx/**                         rw,
  owner /tmp/nginx-*                    rw,

  # ---- /proc and /sys: minimum viable -------------------------------------
  @{PROC}/@{pid}/status                 r,
  @{PROC}/sys/kernel/ngroups_max        r,
  @{PROC}/sys/kernel/random/boot_id     r,
  /sys/devices/system/cpu/online        r,

  # ---- Signals and IPC ----------------------------------------------------
  signal (send,receive) peer=nginx,
  signal (receive) peer=unconfined,
  unix (bind,listen,accept,send,receive) type=stream,

  # ---- Child execution: transition, never inherit -------------------------
  /usr/bin/openssl                      Px -> nginx//openssl,
  /bin/dash                             ix,

  # ---- Explicit denials (audited, and they win over any allow) ------------
  deny /etc/shadow                      rwklx,
  deny /etc/gshadow                     rwklx,
  deny /root/**                         rwklx,
  deny /home/**                         rwklx,
  deny @{PROC}/*/mem                    rwklx,
  deny /sys/kernel/security/**          rwklx,
  audit deny /etc/nginx/**              w,

  # ---- Child profile ------------------------------------------------------
  profile openssl /usr/bin/openssl {
    include <abstractions/base>
    include <abstractions/openssl>

    /usr/bin/openssl        mr,
    /etc/ssl/**             r,
    /etc/nginx/**           r,
    owner /tmp/**           rw,
  }
}
```

**File permission characters:**

| Char | Meaning | Char | Meaning |
|---|---|---|---|
| `r` | read | `w` | write (implies delete/create in the dir) |
| `a` | append only (mutually exclusive with `w`) | `k` | file locking |
| `l` | link | `m` | memory-map executable (`PROT_EXEC`) |
| `ix` | execute, **i**nherit current profile | `px` | execute under the target's own **p**rofile (fails if none) |
| `Px` | like `px`, with environment scrubbing | `cx` | execute under a **c**hild profile |
| `ux` | execute **u**nconfined (dangerous) | `Ux` | `ux` with environment scrubbing | 
| `Cx` | `cx` with environment scrubbing | `pix`/`cix` | try profile/child, fall back to inherit |

**Rule of thumb:** never write `ux`. It hands the child full ambient authority and is the standard AppArmor escape. `Px` with a proper child profile, or `Cx` with an inline `profile {}` block, is the correct construction.

Path globbing:

| Pattern | Matches |
|---|---|
| `*` | Any characters **except** `/` |
| `**` | Any characters **including** `/` (recursive) |
| `?` | One character except `/` |
| `[abc]` / `[a-z]` | Character class |
| `{one,two}` | Alternation |
| `owner` prefix | Only if the task's fsuid matches the file owner |
| `@{VAR}` | Tunable expansion from `/etc/apparmor.d/tunables/` |

`/etc/apparmor.d/` layout (the objectives' `/etc/apparmor/*`):

```console
$ ls /etc/apparmor.d/
abi/                     local/                   usr.bin.man
abstractions/            lsb_release              usr.sbin.nginx
apache2.d/               nvidia_modprobe          usr.sbin.sshd
disable/                 samba/                   tunables/
force-complain/          sbin.dhclient            
$ ls /etc/apparmor.d/tunables/
alias  apparmorfs  dovecot  etc  global  home  home.d/  kernelvars  multiarch
multiarch.d/  ntpd  proc  run  securityfs  share  sys  xdg-user-dirs  xdg-user-dirs.d/
$ ls /etc/apparmor/
logprof.conf  notify.conf  parser.conf  severity.db  subdomain.conf
```

| Path | Purpose |
|---|---|
| `/etc/apparmor.d/<escaped.path>` | Profile files (loaded at boot by `apparmor.service`) |
| `/etc/apparmor.d/abstractions/` | Reusable rule fragments (`base`, `nameservice`, `python`, `ssl_certs`) |
| `/etc/apparmor.d/tunables/` | `@{VARIABLE}` definitions — override here, not in the profile |
| `/etc/apparmor.d/local/<profile>` | Site-local additions, `include`d by vendor profiles — **the upgrade-safe place to add rules** |
| `/etc/apparmor.d/disable/` | Symlinks to profiles that must not load |
| `/etc/apparmor.d/force-complain/` | Symlinks to profiles forced into complain mode |
| `/etc/apparmor/parser.conf` | `apparmor_parser` defaults (cache dir, optimisations) |
| `/etc/apparmor/logprof.conf` | `aa-logprof` behaviour and profile-directory search paths |
| `/etc/apparmor/severity.db` | Severity ranking used by `aa-logprof` when ordering suggestions |

### 11.4 Profile development loop

```console
$ sudo apt install -y apparmor-utils apparmor-profiles apparmor-notify

# 1. Interactive generation while exercising the application
$ sudo aa-genprof /usr/bin/metricsd
Writing updated profile for /usr/bin/metricsd.
Setting /usr/bin/metricsd to complain mode.

Before you begin, you may wish to check if a
profile already exists for the application you
wish to confine. See the following wiki page for
more information:
https://gitlab.com/apparmor/apparmor/wikis/Profiles

Please start the application to be profiled in
another window and exercise its functionality now.
...
Profiling: /usr/bin/metricsd

[(S)can system log for AppArmor events] / (F)inish
S

Reading log entries from /var/log/audit/audit.log.

Profile:  /usr/bin/metricsd
Path:     /etc/metricsd/metricsd.yaml
New Mode: owner r
Severity: 3

 [1 - #include <abstractions/base>]
  2 - owner /etc/metricsd/metricsd.yaml r,
  3 - owner /etc/metricsd/*.yaml r,
  4 - owner /etc/metricsd/** r,

(A)llow / [(D)eny] / (I)gnore / (G)lob / Glob with (E)xtension / (N)ew /
Audi(t) / (O)wner permissions off / Abo(r)t / (F)inish
A

Adding /etc/metricsd/** r, to profile.
...
= Changed Local Profiles =
The following local profiles were changed. Would you like to save them?
 [1 - /usr/bin/metricsd]
(S)ave Changes / Save Selec(t)ed Profile / [(V)iew Changes] / Abo(r)t
S
Writing updated profile for /usr/bin/metricsd.

# 2. Iterate: re-scan the log after more exercise
$ sudo aa-logprof
Reading log entries from /var/log/audit/audit.log.
Updating AppArmor profiles in /etc/apparmor.d.
...

# 3. Promote to enforce, then verify
$ sudo aa-enforce /usr/bin/metricsd
Setting /etc/apparmor.d/usr.bin.metricsd to enforce mode.
$ sudo aa-status | grep -A1 'enforce mode'
```

### 11.5 Reading AppArmor denials

```console
$ sudo ausearch -m AVC -ts recent -i | grep apparmor
type=AVC msg=audit(08/24/2026 12:07:52.883:2214) : apparmor="DENIED" operation="open"
  profile="/usr/sbin/nginx" name="/srv/secrets/db.pass" pid=4471 comm="nginx"
  requested_mask="r" denied_mask="r" fsuid=33 ouid=0

$ sudo dmesg | grep -i apparmor | tail -3
[ 8712.331245] audit: type=1400 audit(1755993272.883:2214): apparmor="DENIED"
  operation="open" profile="/usr/sbin/nginx" name="/srv/secrets/db.pass" pid=4471
  comm="nginx" requested_mask="r" denied_mask="r" fsuid=33 ouid=0

$ sudo journalctl -k --since "-10m" | grep apparmor=

# Desktop/interactive notifier
$ aa-notify -s 1 -v
Profile: /usr/sbin/nginx
Operation: open
Name: /srv/secrets/db.pass
Denied: r
Logfile: /var/log/audit/audit.log
```

| AppArmor field | SELinux equivalent | Meaning |
|---|---|---|
| `apparmor="DENIED"` | `avc: denied` | The verdict |
| `profile=` | `scontext=` | Confining profile / subject context |
| `name=` | `path=` + `tcontext=` | Object — path only, no label |
| `requested_mask` / `denied_mask` | `{ perms }` | Requested vs refused permission bits |
| `operation=` | syscall + `tclass` | Coarse operation name |
| `apparmor="ALLOWED"` | `permissive=1` | Complain-mode learning record |

---

## 12. Smack (Simplified Mandatory Access Control Kernel)

Smack is a label-based MAC LSM designed for simplicity and for embedded/IoT (it is the MAC layer of Tizen and AGL). Rules are triples: `subject-label object-label access`.

### 12.1 Model

- Every process and object carries a single **label**: an arbitrary string up to 255 characters.
- Access is denied unless a rule (or a built-in short-circuit) allows it.
- The default label for everything unlabelled is `_` (floor).

**Built-in labels and their short-circuits:**

| Label | Name | Semantics |
|---|---|---|
| `_` | floor | Everything may **read** and **execute** it; only `^`/privileged may write |
| `^` | hat | May **read** everything; may write nothing |
| `*` | star | Everyone may access it (read/write) — used for `/tmp`, `/dev/null` |
| `?` | huh | Nobody may access it except via explicit rules; write-only to `_` |
| `@` | web | Unrestricted network label (CIPSO wildcard) |

**Access modes:** `r` read, `w` write, `x` execute, `a` append, `t` transmute, `l` lock, `b` bring-up. `-` means "not granted" in the fixed-width form.

`t` (transmute) is the distinguishing feature: a new object created in a transmuting directory inherits the *directory's* label instead of the creating process's label — the mechanism for shared drop-boxes.

### 12.2 Interfaces and tooling

```console
$ mount | grep smack
smackfs on /sys/fs/smackfs type smackfs (rw,nosuid,nodev,noexec,relatime)

$ ls /sys/fs/smackfs/
access        change-rule  direct       load          logging      onlycap
access2       cipso        doi          load2         netlabel     ptrace
ambient       cipso2       ipv6host     load-self     nltype       relabel-self
                                        load-self2                 revoke-subject
                                                                   syslog
                                                                   unconfined

$ cat /sys/fs/smackfs/ambient
_
$ cat /proc/self/attr/current
_

# Label a file (smack-utils / libsmack-utils)
$ sudo chsmack -a Web /srv/www/index.html
$ chsmack /srv/www/index.html
/srv/www/index.html access="Web"

$ sudo chsmack -a Metrics -e Metrics -t /var/lib/metricsd
$ chsmack -r /var/lib/metricsd
/var/lib/metricsd access="Metrics" execute="Metrics" transmute="TRUE"

$ getfattr -d -m security /srv/www/index.html
# file: srv/www/index.html
security.SMACK64="Web"
```

| xattr | Meaning |
|---|---|
| `security.SMACK64` | The object's access label |
| `security.SMACK64EXEC` | Label a process takes when it execs this file (domain transition) |
| `security.SMACK64MMAP` | Label required to `mmap` this file |
| `security.SMACK64TRANSMUTE` | `TRUE` on a directory → new children inherit the directory label |
| `security.SMACK64IPIN` / `IPOUT` | Labels applied to inbound/outbound network traffic on a socket |

Loading rules:

```console
# Rule format:  <subject-label> <object-label> <access-string>
$ cat > /etc/smack/accesses.d/metrics <<'EOF'
Metrics  System   r--
Metrics  Web      r--
Metrics  Metrics  rwxat
Web      Metrics  ---
System   Metrics  rw--
EOF

$ sudo smackload < /etc/smack/accesses.d/metrics
# equivalently:
$ echo -n "Metrics System r" | sudo tee /sys/fs/smackfs/load2

$ sudo cat /sys/fs/smackfs/load2 | grep Metrics
Metrics System rx---
Metrics Web rx---
Metrics Metrics rwxat
System Metrics rw---

# Query a single decision without triggering it
$ echo -n "Metrics System r" | sudo tee /sys/fs/smackfs/access2 >/dev/null
$ sudo cat /sys/fs/smackfs/access2
1                            # 1 = permitted, 0 = denied

# Apply / manage the ruleset at boot
$ sudo smackctl apply
$ sudo smackctl status

# Run a process under a label
$ echo -n "Metrics" | sudo tee /proc/self/attr/current
$ sudo smackenable
```

Smack denials appear in the audit log with `lsm=SMACK`:

```
type=AVC msg=audit(1755993901.117:2291): lsm=SMACK fn=smack_inode_permission
  action=denied subject="Web" object="Metrics" requested=r
  pid=5140 comm="nginx" name="state.db" dev="dm-0" ino=1180213
```

### 12.3 Where Smack fits

| | SELinux | AppArmor | Smack |
|---|---|---|---|
| Enforcement basis | Labels (4-field context) | Pathnames | Labels (single string) |
| Policy size (typical) | ~120 000 rules, ~5 000 types | Tens of rules per profile | Tens to hundreds of triples |
| Learning curve | Steep | Gentle | Gentle |
| Expressiveness | Very high (TE + RBAC + MLS/MCS + constraints) | Medium | Low–medium (plus CIPSO labelling for networks) |
| Multi-tenant isolation of identical binaries | Native (MCS) | Profile-per-instance | Label-per-tenant (native) |
| Network labelling | Peer labels, NetLabel/CIPSO, `secmark` | Coarse `network` rules | CIPSO/NetLabel first-class |
| Default in | RHEL/Fedora/CentOS Stream, Android | Debian/Ubuntu/SUSE | Tizen, AGL, embedded |
| Container runtime support | Podman, CRI-O, containerd, Docker | Docker, containerd, CRI-O, K8s | Rare |
| Memory footprint | Largest | Medium | Smallest |
| Verdict | Choose for regulated, multi-tenant, container hosts | Choose for fast time-to-confinement on single-tenant services | Choose for embedded/IoT with a small, closed set of subjects |

Complementary (stackable) mechanisms — know that these are *not* alternatives to MAC:

| Mechanism | Enforces | Composes with MAC |
|---|---|---|
| `seccomp-bpf` | Which syscalls a process may issue | Yes — orthogonal axis |
| **Landlock** | Unprivileged, per-process filesystem/network sandbox declared by the app itself | Yes — stacks as a minor LSM |
| **Capabilities** | Subdivision of root | Yes — MAC can further restrict `capability` class |
| **Namespaces / cgroups** | Visibility and resource limits, not authorisation | Yes |
| **IMA/EVM** | File integrity and xattr integrity (protects SELinux labels from offline tampering) | Yes — the correct answer to "labels can be edited offline" |

---

## 13. Verification playbook

### 13.1 Pre-production gate

```bash
#!/usr/bin/env bash
# selinux-gate.sh — fail the pipeline if the host's MAC posture regresses.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'OK:   %s\n' "$*"; }

# 1. SELinux enabled and enforcing, both at runtime and in the config file
selinuxenabled || fail "SELinux is not enabled in the kernel"
[[ "$(getenforce)" == "Enforcing" ]] || fail "runtime mode is $(getenforce), expected Enforcing"
grep -qE '^SELINUX=enforcing$' /etc/selinux/config \
  || fail "/etc/selinux/config would not boot into enforcing"
ok "SELinux enforcing at runtime and at boot"

# 2. No permissive domains
if [[ -n "$(semanage permissive -l -n 2>/dev/null | tr -d '[:space:]')" ]]; then
  fail "permissive domains present: $(semanage permissive -l -n | tr '\n' ' ')"
fi
ok "no customised permissive domains"

# 3. No label drift anywhere that matters
drift="$(restorecon -Rn -v /etc /usr /var/www /srv /var/lib 2>/dev/null | wc -l)"
[[ "$drift" -eq 0 ]] || fail "$drift path(s) have contexts that differ from policy"
ok "no file-context drift"

# 4. No denials since boot
denials="$(ausearch -m AVC,USER_AVC,SELINUX_ERR -ts boot 2>/dev/null | grep -c 'denied' || true)"
[[ "$denials" -eq 0 ]] || fail "$denials denial(s) since boot; run: ausearch -m AVC -ts boot -i"
ok "zero denials since boot"

# 5. Every listening service runs in a confined domain
while read -r ctx; do
  [[ "$ctx" == *:unconfined_t:* ]] && fail "a listening process runs unconfined: $ctx"
done < <(ss -ltnpZ | grep -oP 'proc_ctx=\K[^,)]+' | sort -u)
ok "all listening processes are confined"

# 6. Local customisation is captured and reproducible
semanage export -f /dev/stdout | grep -q . \
  && ok "local customisation exported (capture this in configuration management)"
```

### 13.2 Post-incident triage sequence

```console
# 1. Is MAC actually the cause?
$ getenforce
Enforcing
$ sudo setenforce 0 && <retry the failing operation>     # if it now works, MAC is involved
$ sudo setenforce 1                                       # restore IMMEDIATELY

# 2. Make everything visible
$ sudo semodule -DB
$ sudo semanage permissive -a <domain_t>

# 3. Reproduce and collect the full picture
$ sudo ausearch -m AVC,USER_AVC,SELINUX_ERR -ts recent -i | tee /tmp/avc.txt

# 4. Classify: mislabel, boolean, or missing rule
$ grep -oP 'tcontext=\K\S+' /tmp/avc.txt | sort | uniq -c | sort -rn
     11 system_u:object_r:default_t:s0            # <- mislabel; fix labels
      3 system_u:object_r:postgresql_port_t:s0    # <- check booleans
$ audit2why < /tmp/avc.txt

# 5. Apply the narrowest correct remedy, then revert every loosening
$ sudo semanage permissive -d <domain_t>
$ sudo semodule -B
$ sudo setenforce 1

# 6. Prove it
$ sudo ausearch -m AVC -ts recent | grep -c denied
0
```

---

## 14. Command reference for the exam

| Command | Purpose | Persistent? |
|---|---|---|
| `getenforce` | Print current mode | — |
| `setenforce 0\|1` | Change mode at runtime | No |
| `selinuxenabled` | Exit 0 if SELinux is enabled | — |
| `sestatus [-v] [-b]` | Full status, contexts, boolean states | — |
| `getsebool [-a] <bool>` | Read boolean state | — |
| `setsebool [-P] <bool> on\|off` | Set boolean (`-P` = persistent) | With `-P` |
| `togglesebool <bool>` | Flip a boolean at runtime | No |
| `restorecon [-Rvn] <path>` | Apply stored default contexts | Yes (xattrs) |
| `setfiles [-nrv] <spec> <path>` | Apply contexts from a named spec file | Yes |
| `fixfiles {check\|restore\|relabel\|onboot} [-R pkg]` | Bulk relabel / verify | Yes |
| `chcon [-Rt type] <path>` | Change context directly (temporary) | Until relabel |
| `matchpathcon <path>` | Show the policy's default context for a path (deprecated → `restorecon -n -v`) | — |
| `semanage {fcontext,port,login,user,boolean,permissive,module,export,import}` | Manage policy configuration | Yes |
| `semodule {-i,-r,-l,-B,-D,-e,-d,-X}` | Manage policy modules | Yes |
| `runcon [-u -r -t -l] CMD` | Execute one command in a context | No |
| `newrole -r ROLE [-t TYPE] [-l LEVEL]` | Authenticated role transition | Session |
| `seinfo [-t -r -b --user -x]` | Policy statistics and component queries | — |
| `sesearch {-A,-T,-D} [-s -t -c -p -b]` | Query policy rules | — |
| `apol [policy]` | Graphical policy analysis (SETools) | — |
| `seaudit` | SETools 3 audit-log browser (**removed in SETools 4**) | — |
| `audit2why` | Explain why a denial happened | — |
| `audit2allow [-i F] [-M name] [-R]` | Generate policy from denials | — |
| `sealert -a <log>` / `-l <id>` | setroubleshoot analysis with remediation | — |
| `ausearch -m AVC -ts recent -i` | Search audit records | — |
| `sepolicy {generate,transition,network,manpage}` | Policy authoring/analysis helpers | — |
| `avcstat [interval]` | AVC cache statistics | — |
| `aa-status [--json]` | AppArmor profile and process state | — |
| `aa-enforce <profile>` | Set enforce mode | Yes |
| `aa-complain <profile>` | Set complain (learning) mode | Yes |
| `aa-disable <profile>` | Unload and symlink into `disable/` | Yes |
| `aa-unconfined [--paranoid]` | List network processes without a profile | — |
| `aa-genprof <binary>` | Interactive profile generation | Yes |
| `aa-logprof` | Update profiles from logged events | Yes |
| `aa-exec -p <profile> -- CMD` | Run a command under a profile | No |
| `apparmor_parser {-r,-R,-a,-Q}` | Load / remove / verify a profile | Yes |
| `chsmack [-a L] [-e L] [-t] <path>` | Read/set Smack labels | Yes (xattrs) |
| `smackload` | Load Smack rules into `/sys/fs/smackfs/load2` | No (until re-applied) |
| `smackctl {apply,status}` | Apply the persistent Smack ruleset | Yes |

---

## Referencias

**Certification**
- LPI — Exam 303 Objectives (303-300, version 3.0.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- LPI — LPIC-3 Security certification overview: https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Kernel and LSM framework**
- Linux Kernel — Linux Security Modules admin guide: https://www.kernel.org/doc/html/latest/admin-guide/LSM/index.html
- Linux Kernel — SELinux: https://www.kernel.org/doc/html/latest/admin-guide/LSM/SELinux.html
- Linux Kernel — AppArmor: https://www.kernel.org/doc/html/latest/admin-guide/LSM/apparmor.html
- Linux Kernel — Smack: https://www.kernel.org/doc/html/latest/admin-guide/LSM/Smack.html
- Linux Kernel — Landlock (userspace API): https://www.kernel.org/doc/html/latest/userspace-api/landlock.html
- Linux Kernel — Kernel parameters (`lsm=`, `selinux=`, `apparmor=`): https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html

**SELinux**
- The SELinux Project: https://selinuxproject.org/page/Main_Page
- SELinux Notebook (the reference text for policy language and internals): https://github.com/SELinuxProject/selinux-notebook
- SELinux userspace tools and libraries: https://github.com/SELinuxProject/selinux
- Reference Policy (refpolicy) source and interface documentation: https://github.com/SELinuxProject/refpolicy
- SETools (`seinfo`, `sesearch`, `apol`, `sediff`): https://github.com/SELinuxProject/setools
- Red Hat Enterprise Linux 9 — Using SELinux: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_selinux/index
- Fedora Documentation — SELinux: https://docs.fedoraproject.org/en-US/quick-docs/selinux-getting-started/
- Gentoo Wiki — SELinux (distribution-neutral policy administration): https://wiki.gentoo.org/wiki/SELinux
- `man 5 selinux_config`: https://man7.org/linux/man-pages/man5/selinux_config.5.html
- `man 8 semanage`: https://man7.org/linux/man-pages/man8/semanage.8.html
- `man 8 semodule`: https://man7.org/linux/man-pages/man8/semodule.8.html
- `man 8 restorecon`: https://man7.org/linux/man-pages/man8/restorecon.8.html
- `man 8 setfiles`: https://man7.org/linux/man-pages/man8/setfiles.8.html
- `man 8 fixfiles`: https://man7.org/linux/man-pages/man8/fixfiles.8.html
- `man 1 runcon`: https://man7.org/linux/man-pages/man1/runcon.1.html
- `man 1 newrole`: https://man7.org/linux/man-pages/man1/newrole.1.html
- `man 1 audit2allow`: https://man7.org/linux/man-pages/man1/audit2allow.1.html

**AppArmor**
- AppArmor project wiki (documentation index): https://gitlab.com/apparmor/apparmor/-/wikis/home
- AppArmor — Documentation and profile language: https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- AppArmor source repository: https://gitlab.com/apparmor/apparmor
- Ubuntu Server documentation — AppArmor: https://documentation.ubuntu.com/server/how-to/security/apparmor/
- Debian Wiki — AppArmor: https://wiki.debian.org/AppArmor
- `man 8 aa-status`: https://man7.org/linux/man-pages/man8/aa-status.8.html
- `man 8 apparmor_parser`: https://man7.org/linux/man-pages/man8/apparmor_parser.8.html
- `man 5 apparmor.d`: https://man7.org/linux/man-pages/man5/apparmor.d.5.html

**Smack**
- Smack project (kernel documentation): https://docs.kernel.org/admin-guide/LSM/Smack.html
- Smack userspace utilities (`libsmack`, `chsmack`, `smackload`): https://github.com/smack-team/smack
- Tizen — Security architecture and Smack usage: https://docs.tizen.org/platform/porting/security/

**Audit subsystem**
- Linux Audit userspace (`ausearch`, `aureport`, `auditctl`): https://github.com/linux-audit/audit-userspace
- `man 8 ausearch`: https://man7.org/linux/man-pages/man8/ausearch.8.html
- Red Hat Enterprise Linux 9 — Auditing the system: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening

**Containers and Kubernetes**
- Kubernetes — Configure a Security Context for a Pod or Container (`seLinuxOptions`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Restrict a Container's Access to Resources with AppArmor: https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Podman — `podman-run(1)`, `--security-opt` and volume `:z`/`:Z` flags: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- `container-selinux` policy module: https://github.com/containers/container-selinux
- `udica` — generate SELinux policies for containers: https://github.com/containers/udica

**systemd**
- `man 5 systemd.exec` (`SELinuxContext=`, `AppArmorProfile=`, `SmackProcessLabel=`, `NoNewPrivileges=`): https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-analyze security`: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html