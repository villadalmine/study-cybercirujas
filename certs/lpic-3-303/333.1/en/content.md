# 333.1 — Discretionary Access Control

**LPIC-3 303 (Exam 303-300, v3.0.0) — Topic 333: Access Control**
Profile: Principal Platform Architect / Senior SRE. Weight: 5.0.

---

## 1. The architectural problem

Every other access-control layer you will deploy — SELinux, AppArmor, seccomp, Kubernetes PSA, OPA/Gatekeeper — is *conditional*. It can be disabled by a boot flag, absent from a container image, unsupported by a filesystem, or simply not compiled in. DAC is the only layer that is **always present, on every VFS object, in every kernel, inside every container, across every bind mount and every NFS export**. It is the substrate. If your DAC model is wrong, the rest is decoration over a hole.

DAC is also the layer that fails *silently and asymmetrically*:

- **Too tight** and you get a loud, immediate `EACCES`, a page, and a fix within minutes.
- **Too loose** and you get nothing. No log line, no alert, no failed request. The exposure lives until an audit, a breach, or a compliance scan finds it — typically years later.

That asymmetry is why production DAC drifts monotonically toward `777`. The on-call engineer at 03:00 has a broken deploy, a `Permission denied`, and a strong incentive to make the error go away. `chmod -R 777` always works. It is the single most common root cause behind "the artifact store was world-writable" post-mortems.

### 1.1 The canonical production scenario used throughout this topic

A multi-tenant build and artifact host, `build-01`, with four principals that must share the filesystem without trusting each other:

| Principal | Identity | Must be able to | Must **not** be able to |
|---|---|---|---|
| CI runner | `ci` (uid 1500), group `ci-runners` (gid 1500) | Create build directories, write artifacts | Read another tenant's build inputs; modify published artifacts |
| Release bot | `release` (uid 1501), group `deployers` (gid 1200) | Read every artifact, publish signed ones | Delete a completed build's evidence |
| Log shipper | `promtail` (uid 1502) | Read `/var/log/app/*.log`, owned by other services | Write anything under `/var/log` |
| Auditors | group `sec-audit` (gid 1300) | Read everything, forever | Write, delete, or hide anything |

Note the shape of the problem: **three read-only observers with different scopes, one writer, and an immutability requirement.** The classic Unix triad (`owner`, `group`, `other`) gives you *exactly one* named group. It cannot express this. You need ACLs, and you need to understand precisely how ACLs interact with the mode bits, because that interaction is where production systems break.

### 1.2 The definitional limit of DAC

"Discretionary" is a precise technical claim, not a marketing adjective: **the owner of an object has the discretion to grant access to it.** The consequences follow directly:

- A user who can read a secret can copy it to a world-readable location. DAC cannot stop information flow, only initial access.
- `chmod` is a right of ownership. The system administrator cannot centrally forbid an owner from loosening their own files — only detect it afterwards.
- This is the **confused deputy** and **information-flow** gap that Mandatory Access Control (topic 333.2) exists to close. MAC is not a replacement for DAC; it is a *second* check applied *after* DAC passes. **Both must permit.** A file denied by mode bits is denied regardless of a permissive SELinux policy, and vice-versa.

---

## 2. Where DAC actually happens: the kernel decision path

You cannot debug permissions from `ls -l` alone. You need the algorithm.

### 2.1 The inode's `st_mode`

Every VFS object carries a 16-bit `st_mode` in its inode:

```
 15 14 13 12 | 11 10  9 | 8  7  6 | 5  4  3 | 2  1  0
 [file type] | su sg st | r  w  x | r  w  x | r  w  x
             |          |  owner  |  group  |  other
```

- Bits 15–12: file type (`S_IFREG`, `S_IFDIR`, `S_IFLNK`, `S_IFCHR`, `S_IFBLK`, `S_IFIFO`, `S_IFSOCK`). **Not changeable** after creation.
- Bits 11–9: `S_ISUID` (04000), `S_ISGID` (02000), `S_ISVTX` (01000) — the "special" or "sticky/set-id" bits.
- Bits 8–0: the familiar nine permission bits.

This is why `chmod 755` and `chmod 0755` are identical, and why `chmod 4755` sets setuid — the leading digit is bits 11–9.

```
$ stat -c '%n  type=%F  mode=%a (%A)  uid=%u(%U)  gid=%g(%G)' /usr/bin/passwd /tmp /etc/shadow
/usr/bin/passwd  type=regular file  mode=4755 (-rwsr-xr-x)  uid=0(root)  gid=0(root)
/tmp  type=directory  mode=1777 (drwxrwxrwt)  uid=0(root)  gid=0(root)
/etc/shadow  type=regular file  mode=640 (-rw-r-----)  uid=0(root)  gid=42(shadow)
```

### 2.2 The algorithm: first match wins, and it does **not** accumulate

This is the single most misunderstood mechanic in Unix permissions. The kernel (`fs/namei.c:generic_permission()` → `fs/posix_acl.c:posix_acl_permission()`) evaluates classes **in strict order and stops at the first applicable one**:

```
1. if (fsuid == inode.i_uid)                     → use OWNER bits.        STOP.
2. if (an ACL_USER entry matches fsuid)          → use that entry & mask. STOP.
3. if (fsgid or any supplementary gid matches
       the owning group, or an ACL_GROUP entry)  → use the union of all
                                                    matching group-class
                                                    entries, & mask.      STOP.
4. otherwise                                     → use OTHER bits.        STOP.
```

Only step 3 unions multiple entries. Steps 1, 2 and 4 are terminal and exclusive.

**Demonstration — the "paradox" file.** Owner is denied while everyone else is allowed:

```
$ id
uid=1000(sre) gid=1000(sre) groups=1000(sre),27(sudo)

$ touch /tmp/paradox && chmod 0067 /tmp/paradox
$ ls -l /tmp/paradox
----rw-rwx 1 sre sre 0 Aug 24 09:41 /tmp/paradox

$ cat /tmp/paradox
cat: /tmp/paradox: Permission denied

$ sudo -u nobody cat /tmp/paradox     # 'nobody' is not sre, not in group sre → OTHER = rwx
$ echo $?
0
```

The owner matched at step 1, got `---`, and the evaluation stopped. Group `rw-` and other `rwx` were never consulted. Any monitoring or compliance tool that computes "effective access" by OR-ing the three triads reports this file as readable by `sre`. It is not.

**Corollary for the exam and for production:** tightening `other` never tightens access for the owner or the group; loosening `other` never loosens access for the owner. Mode `0640` and mode `0644` are identical *for the owner*.

### 2.3 The capability bypasses

Root is not special; **capabilities** are. On a kernel with file capabilities and user namespaces, "root" is shorthand for "holds the relevant capability in the current user namespace, and the inode's owner is mapped into it" (`capable_wrt_inode_uidgid()`).

| Capability | Bypasses |
|---|---|
| `CAP_DAC_OVERRIDE` | All read/write/execute checks — **except** execute on a regular file with *no* execute bit set at all |
| `CAP_DAC_READ_SEARCH` | Read on files, read+search on directories. No write bypass |
| `CAP_FOWNER` | Checks requiring `fsuid == i_uid`: `chmod`, `utimes`, sticky-directory deletion, setting `user.*` xattrs on someone else's file |
| `CAP_FSETID` | Prevents the kernel clearing setuid/setgid on `write()` and `chown()` |
| `CAP_CHOWN` | Arbitrary `chown`/`chgrp` |
| `CAP_LINUX_IMMUTABLE` | Setting/clearing the `i` (immutable) and `a` (append-only) attributes |

The `CAP_DAC_OVERRIDE` exception is real and catches people:

```
# chmod 000 /usr/local/bin/healthcheck
# ls -l /usr/local/bin/healthcheck
---------- 1 root root 812 Aug 24 09:52 /usr/local/bin/healthcheck

# cat /usr/local/bin/healthcheck          # read: allowed, CAP_DAC_OVERRIDE applies
#!/bin/sh
...

# /usr/local/bin/healthcheck              # execute: DENIED even for root
-bash: /usr/local/bin/healthcheck: Permission denied

# chmod 100 /usr/local/bin/healthcheck    # one x bit anywhere is enough for root
# /usr/local/bin/healthcheck
ok
```

The kernel's rule: `CAP_DAC_OVERRIDE` grants `MAY_EXEC` on a regular file only if `i_mode & S_IXUGO` is non-zero. Directories are always searchable with the capability.

### 2.4 `EACCES` vs `EPERM` — the fastest triage signal you have

These two errnos both print as human-readable "Permission denied" / "Operation not permitted", and they mean **completely different things**:

| errno | `strerror` | Meaning | Typical cause |
|---|---|---|---|
| `EACCES` (13) | Permission denied | The **mode bits / ACL** on this inode or a path component denied the operation | Wrong mode, wrong group, missing `x` on a parent directory |
| `EPERM` (1) | Operation not permitted | The operation is **privileged** or structurally forbidden, regardless of mode | `chown` by non-owner, `chattr +i` file, missing capability, `nosuid` mount, LSM denial |

`chmod 777` fixes `EACCES`. It never fixes `EPERM`. If you see `EPERM`, stop looking at permissions and start looking at attributes, capabilities, mount options, and MAC policy.

```
$ strace -f -e trace=openat,write,chown -o /tmp/t.log ./app ; grep -E 'EACCES|EPERM' /tmp/t.log
openat(AT_FDCWD, "/srv/deploy/artifacts/build-4711/manifest.json", O_WRONLY|O_CREAT|O_TRUNC, 0666) = -1 EACCES (Permission denied)
chown("/srv/deploy/artifacts/build-4711", 1501, 1200) = -1 EPERM (Operation not permitted)
```

Two failures, two entirely different root causes, in one trace.

---

## 3. Ownership: `chown`, `chgrp`, and the bits that vanish

### 3.1 Semantics

```
$ chown release:deployers /srv/deploy/artifacts/manifest.json   # user and group
$ chown release: /srv/deploy/artifacts/manifest.json            # user, group→user's login group
$ chown :deployers /srv/deploy/artifacts/manifest.json          # group only (== chgrp)
$ chown --reference=/srv/deploy/.template /srv/deploy/new       # copy ownership from another inode
$ chown -R --from=1500:1500 1501:1200 /srv/deploy/artifacts     # conditional: only change matching inodes
```

`--from=OLDUSER:OLDGROUP` is the safe recursive idiom during a uid migration: it is idempotent and will not touch inodes that already carry the target ownership or that belong to a third party.

**Symlinks.** `chown` dereferences by default. `-h` / `--no-dereference` acts on the link itself. With `-R`, the default is `-P` (do not traverse symlinks); `-L` follows every symlink encountered (dangerous — a symlink to `/` will rewrite your system), `-H` follows only command-line arguments. There is no `lchmod(2)` on Linux: **symlink modes are always `lrwxrwxrwx` and are meaningless**; traversal is governed entirely by the target and by the directories in the path.

### 3.2 Who may `chown`

On Linux, **only `CAP_CHOWN` may change a file's owner** — there is no "give-away chown" as on some traditional Unixes. An unprivileged user may change the *group* to any group of which they are a member, provided they own the file.

```
$ id -Gn
sre sudo deployers

$ chgrp deployers /home/sre/report.txt         # member of deployers → OK
$ chgrp sec-audit /home/sre/report.txt         # not a member
chgrp: changing group of '/home/sre/report.txt': Operation not permitted   ← EPERM
```

### 3.3 The set-id bits are cleared behind your back

This is a security feature and a frequent source of "it worked yesterday" incidents:

- **`chown`/`chgrp` clears `S_ISUID` and `S_ISGID`** when performed by a process without `CAP_FSETID`. Since Linux 2.2.13, **root is treated like everyone else here** — `chown` from root also clears them. Exception: if the file is *not* group-executable, `S_ISGID` had a different historical meaning (mandatory locking) and is not cleared.
- **`write(2)` to a set-id file clears them**, again unless the writer holds `CAP_FSETID`.
- **`chmod g+s` by a non-privileged user is silently dropped** if the file's group is not in the caller's group set.

```
# ls -l /usr/local/bin/spool-flush
-rwsr-xr-x 1 root root 22160 Aug 24 10:01 /usr/local/bin/spool-flush

# chown root:opsteam /usr/local/bin/spool-flush
# ls -l /usr/local/bin/spool-flush
-rwxr-xr-x 1 root opsteam 22160 Aug 24 10:01 /usr/local/bin/spool-flush   ← the 's' is gone
```

**Operational rule:** in any packaging, Ansible, or Dockerfile step, `chown` must come **before** `chmod`, never after. Half the "the setuid helper stopped working after the config-management run" tickets are this ordering bug.

---

## 4. The nine bits, with directory semantics stated exactly

For **regular files** the meanings are obvious. For **directories** they are not, and directory semantics are where real access-control designs live.

| Bit | On a regular file | On a **directory** |
|---|---|---|
| `r` | Read contents | **List the names** in it (`ls`, `readdir`) — names only, no metadata |
| `w` | Modify contents | **Create, delete, and rename entries** — *requires `x` as well*. This is permission over the *directory*, not over the files in it |
| `x` | Execute (`execve`) | **Traverse / resolve** a name inside it (`stat`, `open`, `cd`). Required on **every** component of a path |

Four consequences that drive production design:

1. **`w` on a directory lets you delete a file you cannot read and do not own.** File permissions are irrelevant to `unlink()`. This is exactly what the sticky bit exists to constrain.
2. **`--x` (mode `0111`, or `0711` for the owner) is the "access if you know the name" pattern.** You cannot enumerate, but you can traverse. This is how `/home` should be configured on a shared host, and how a per-tenant artifact root is exposed to a shared reader without leaking the tenant list.
3. **`r--` without `x` is nearly useless.** You get names and nothing else — `ls -l` returns `?` for every field:

```
$ ls -ld /srv/deploy/incoming
dr--r--r-- 2 ci ci-runners 4096 Aug 24 10:07 /srv/deploy/incoming

$ ls -l /srv/deploy/incoming
ls: cannot access '/srv/deploy/incoming/build-4711.tar.zst': Permission denied
total 0
-????????? ? ? ? ?            ? build-4711.tar.zst
```

4. **A missing `x` on a *parent* directory denies everything below it, no matter how permissive the leaf is.** This is the number-one cause of "but the file is 0644!" tickets, and the reason `namei -mo` (§12.1) is the first command you should run.

### 4.1 Symbolic mode, and the one operator you should be using

```
$ chmod u=rwX,g=rX,o= -R /srv/deploy/artifacts
```

`X` (capital) means "set execute **only if** the target is a directory, or already has execute set for at least one class". This is the correct recursive idiom: it sets `x` on directories so they remain traversable, without marking every `.json` and `.tar.zst` as executable. `chmod -R 755` is almost always a bug for the same reason.

The alternative, when you need different modes for files and directories:

```
$ find /srv/deploy/artifacts -type d -exec chmod 2750 {} +
$ find /srv/deploy/artifacts -type f -exec chmod 0640 {} +
```

Other symbolic forms worth knowing: `chmod a-w`, `chmod g=u` (copy owner's bits to group), `chmod --reference=template file`, `chmod =rwx,g+s`.

---

## 5. The three special bits

### 5.1 `S_ISUID` (4000) — setuid

On an **executable regular file**: `execve()` sets the new process's *effective* and *saved-set* UID to the file's owner. This is the only mechanism in classic Unix by which an unprivileged user gains privilege, and it is the reason `/usr/bin/passwd` can write `/etc/shadow`.

Critical facts:

- **Setuid is ignored on shell scripts on Linux.** The kernel refuses to honour set-id bits on files handled by a `#!` interpreter, because the window between `execve()` and the interpreter opening the script is exploitable. A `#!/bin/sh` file with mode `4755` runs with your own UID, always. This is not configurable.
- **Setuid is meaningless on directories on Linux.** (Some traditional Unixes used it for ownership inheritance; Linux does not.)
- **`nosuid` mount option kills it.** A setuid binary on a `nosuid` filesystem executes with no privilege change and, for a `nosuid` mount, `execve` of a set-id file silently drops the bits.
- **`no_new_privs` kills it.** `prctl(PR_SET_NO_NEW_PRIVS, 1)` is irreversible and inherited across `execve`. Every `setuid` bit and every file capability is neutralised for that process tree. This is exactly what `allowPrivilegeEscalation: false` sets in a Kubernetes `securityContext`, and what `NoNewPrivileges=yes` sets in a systemd unit.

Display: `s` in the owner-execute position; **`S` if the underlying `x` bit is absent** — a setuid file that is not executable, which is always a mistake.

```
$ ls -l /usr/bin/sudo /usr/bin/chsh
-rwsr-xr-x 1 root root 277936 Jun 11 12:19 /usr/bin/sudo
-rwsr-xr-x 1 root root  72040 Mar 23  2025 /usr/bin/chsh
```

### 5.2 `S_ISGID` (2000) — setgid

Two entirely unrelated meanings, distinguished by file type:

**On an executable file:** `execve()` sets the effective GID to the file's group. Same `nosuid`/`no_new_privs` caveats apply.

**On a directory — this is the important one.** It switches the directory from System V group-inheritance semantics to **BSD semantics**:

- A new file created inside inherits the **directory's** group, not the creator's effective GID.
- A new **subdirectory** inherits the group **and the setgid bit itself**, so the property propagates down the whole tree automatically.

This is the foundation of every shared-workspace design in Unix:

```
# groupadd -g 1200 deployers
# install -d -o root -g deployers -m 2775 /srv/deploy/artifacts
# ls -ld /srv/deploy/artifacts
drwxrwsr-x 2 root deployers 4096 Aug 24 10:14 /srv/deploy/artifacts

# sudo -u ci sh -c 'umask 002; mkdir /srv/deploy/artifacts/build-4711; \
                    touch /srv/deploy/artifacts/build-4711/manifest.json'

# ls -lR /srv/deploy/artifacts
/srv/deploy/artifacts:
total 4
drwxrwsr-x 2 ci deployers 4096 Aug 24 10:15 build-4711     ← group inherited, s propagated

/srv/deploy/artifacts/build-4711:
total 0
-rw-rw-r-- 1 ci deployers 0 Aug 24 10:15 manifest.json      ← group inherited
```

Without the setgid bit, `manifest.json` would have been `ci:ci-runners` and the release bot in `deployers` could not read it.

**Note carefully what setgid does *not* do:** it controls the **group**, not the **mode**. The `rw-rw-r--` above came from the creating process's `umask 002`, not from the directory. If `ci` runs with `umask 022`, the file is `rw-r--r--` and the group loses write access despite the perfect setgid setup. **Setgid + a matching umask are a pair; deploying one without the other is the most common half-done shared-directory configuration.** The only way to make inheritance independent of the writer's umask is a **default ACL** (§7.3).

Display: `s` in group-execute; `S` if group-`x` is absent. On a *file*, `-rw-r-Sr--` historically signalled **mandatory locking** — a feature removed from the kernel in Linux 5.15. On a modern kernel it is inert, but `chown` still declines to clear it in that configuration.

### 5.3 `S_ISVTX` (1000) — the sticky bit / restricted deletion flag

On a **directory**, it restricts `unlink()` and `rename()` of entries: a user may remove or rename an entry only if they own the entry, own the directory, or hold `CAP_FOWNER` — *even when they have write permission on the directory*. On a **file** it is the vestigial "save text image" bit and has **no effect on Linux**.

```
$ ls -ld /tmp /var/tmp /dev/shm
drwxrwxrwt 18 root root  520 Aug 24 10:20 /tmp
drwxrwxrwt  6 root root 4096 Aug 24 04:02 /var/tmp
drwxrwxrwt  2 root root   40 Aug 24 03:58 /dev/shm

$ sudo -u ci touch /tmp/ci-scratch
$ sudo -u release rm /tmp/ci-scratch
rm: cannot remove '/tmp/ci-scratch': Operation not permitted     ← EPERM, not EACCES
```

Display: `t` in the other-execute position; `T` if other-`x` is absent.

**The sticky bit alone is not sufficient hardening for a world-writable directory.** It stops deletion, not the classic symlink/hardlink races. Four sysctls close those, and they belong in every hardened build:

```
# /etc/sysctl.d/60-fs-hardening.conf
# Do not follow symlinks in world-writable sticky dirs when the symlink owner
# differs from the directory owner and the following process.
fs.protected_symlinks = 1
# Do not allow hardlinks to files the linking user does not own and cannot read+write.
fs.protected_hardlinks = 1
# Do not allow O_CREAT open of a FIFO/regular file in a world-writable sticky dir
# owned by someone else, unless the opener owns it.
fs.protected_fifos = 2
fs.protected_regular = 2
# Restrict access to kernel pointers and dmesg while we are here.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
```

```
# sysctl --system
* Applying /etc/sysctl.d/60-fs-hardening.conf ...
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
```

Blocked attempts land in the kernel log, which makes them alertable:

```
$ dmesg -T | grep -i protected
[Sun Aug 24 10:26:03 2026] non-matching-uid symlink following attempted in a sticky world-writable directory by cat (fsuid 1500 != 1502)
```

---

## 6. Creation-time mode: `umask` and where it really comes from

Neither `open(2)` nor `mkdir(2)` sets the mode you asked for. The kernel computes:

```
final_mode = requested_mode & ~umask
```

`umask` is a **per-process attribute**, inherited across `fork` and `execve`, expressed as the bits to *remove*. It is applied at creation only; it has **no effect on `chmod`**, and no effect on files that already exist.

| `umask` | Files (`0666` requested) | Directories (`0777` requested) | Use case |
|---|---|---|---|
| `022` | `644` `-rw-r--r--` | `755` `drwxr-xr-x` | Historical default; world-readable |
| `002` | `664` `-rw-rw-r--` | `775` `drwxrwxr-x` | Per-user private groups (UPG); shared-group writing |
| `027` | `640` `-rw-r-----` | `750` `drwxr-x---` | **The correct baseline for a server.** Group readable, world blind |
| `007` | `660` `-rw-rw----` | `770` `drwxrwx---` | UPG + shared group, world blind |
| `077` | `600` `-rw-------` | `700` `drwx------` | Secrets, key material, per-user state |

Note that files never get `x` from the umask: userland requests `0666` for data files, so `umask 022` yields `644`, not `755`. Compilers and `install` explicitly request `0777`, which is why binaries come out executable.

```
$ umask
0022
$ umask -S
u=rwx,g=rx,o=rx

$ ( umask 027; mkdir -p /tmp/u027/sub; : > /tmp/u027/sub/data.json ) \
    && ls -ld /tmp/u027 /tmp/u027/sub /tmp/u027/sub/data.json
drwxr-x--- 3 sre sre 4096 Aug 24 10:33 /tmp/u027
drwxr-x--- 2 sre sre 4096 Aug 24 10:33 /tmp/u027/sub
-rw-r----- 1 sre sre    0 Aug 24 10:33 /tmp/u027/sub/data.json
```

### 6.1 Where a daemon's umask actually comes from

Debugging "my service writes world-readable files" requires knowing the source of truth. In order of specificity:

| Layer | Mechanism | Applies to |
|---|---|---|
| Kernel default | `0022` at PID 1 | Everything not overridden |
| systemd system manager | `DefaultUMask=` in `/etc/systemd/system.conf` (default `0022`) | All system services |
| systemd unit | `UMask=` in `[Service]` | That unit only — **authoritative, use this** |
| PAM | `pam_umask.so` + `UMASK` in `/etc/login.defs` + `USERGROUPS_ENAB` | Interactive logins, `su`, `sshd` |
| Shell | `umask` in `/etc/profile`, `~/.bashrc` | Interactive/login shells only |
| Per-user | `UMASK=` field in `/etc/default/useradd`, GECOS-based `pam_umask` | Per account |

**A `umask` in `/etc/profile` has no effect whatsoever on a systemd service.** Services do not source profile scripts. This is the single most common misdiagnosis in this area.

Verify what a *running* process actually has — the truth is in `/proc`:

```
$ grep -i umask /proc/$(pidof payments-api)/status
Umask:	0027
```

`USERGROUPS_ENAB yes` in `/etc/login.defs` makes `pam_umask` relax a `022` umask to `002` when the user's primary group name equals their username (User Private Groups). This is why the same command produces `664` on Debian/Ubuntu and `644` on a system without UPG.

---

## 7. POSIX ACLs

### 7.1 Why they exist, and the model

Mode bits express exactly three subjects. Our §1.1 scenario needs five. POSIX 1003.1e draft 17 ACLs (the draft was withdrawn; the implementation is universal on Linux) extend the model with named users and named groups.

An **access ACL** is an ordered set of entries:

| Entry | Syntax | Cardinality | Relationship to mode bits |
|---|---|---|---|
| Owner | `user::rwx` | Exactly 1, mandatory | **Is** the owner triad |
| Named user | `user:NAME:rwx` | 0..n | Additional; subject to mask |
| Owning group | `group::rwx` | Exactly 1, mandatory | Subject to mask |
| Named group | `group:NAME:rwx` | 0..n | Additional; subject to mask |
| **Mask** | `mask::rwx` | 1 if any named entry exists | **Is** the group triad in `ls -l` |
| Other | `other::rwx` | Exactly 1, mandatory | **Is** the other triad |

An ACL containing only the three mandatory entries is a **minimal ACL** and is exactly equivalent to the mode bits — it consumes no extra storage and `ls -l` shows no `+`.

**The mask is the whole design.** It is an upper bound applied to *every* entry in the group class: all named users, all named groups, and the owning group. Effective permission = entry ∩ mask. The owner and other entries are never masked.

`setfacl` recalculates the mask automatically on every `-m`/`-x` to the union of the group class, unless you pass `-n` (`--no-mask`) or specify a `mask::` entry explicitly in the same command.

### 7.2 Working with ACLs — the full command set

```
$ getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
group::rwx
other::r-x
```

The `# flags:` line is `setuid/setgid/sticky` — here `-s-` reflects the `2775` mode from §5.2.

Now grant the four principals from §1.1 what they actually need:

```
# setfacl -m u:ci:rwx \
          -m g:deployers:r-x \
          -m u:promtail:--- \
          -m g:sec-audit:r-x \
          -m o::--- \
          /srv/deploy/artifacts

# getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
user:ci:rwx
group::rwx
group:deployers:r-x
group:sec-audit:r-x
mask::rwx
other::---

# ls -ld /srv/deploy/artifacts
drwxrws---+ 3 root deployers 4096 Aug 24 10:41 /srv/deploy/artifacts
```

The trailing **`+`** is the only signal `ls -l` gives that an ACL exists. Any audit tooling that parses `ls -l` output and ignores the `+` is reporting fiction.

Full operator reference:

| Command | Effect |
|---|---|
| `setfacl -m u:NAME:rwx F` | Modify/add a named-user entry |
| `setfacl -m g:NAME:rX F` | Named group; `X` = execute only if dir or already-executable |
| `setfacl -x u:NAME F` | Remove one entry (no permission field) |
| `setfacl -b F` | Remove **all** extended entries → back to a minimal ACL |
| `setfacl -k F` | Remove the **default** ACL only |
| `setfacl -n -m ... F` | Do not recalculate the mask |
| `setfacl -d -m u:NAME:rX D` | Operate on the **default** ACL of a directory |
| `setfacl -R -m ... D` | Recurse |
| `setfacl --set 'u::rw,g::r,o::-' F` | Replace the entire ACL (mandatory entries required) |
| `setfacl -M spec.acl F` | Read modifications from a file (`-` for stdin) |
| `setfacl --restore=backup.acl` | Restore ACLs **plus owner, group and mode** from a `getfacl -R` dump |
| `getfacl -R --absolute-names D` | Recursive dump suitable for `--restore` |
| `getfacl -c F` | Omit the `# file/owner/group` header |
| `getfacl -e F` | Always print the `#effective:` comment |
| `getfacl -s F` | Skip files that have only a minimal ACL |
| `getfacl -t F` | Tabular output |
| `getfacl -n F` | Numeric UIDs/GIDs — **use this in backups**, names are not portable |

Backup and restore, the operation everyone forgets until a restore fails:

```
# getfacl -R -n --absolute-names /srv/deploy > /var/backups/srv-deploy-2026-08-24.acl
# head -12 /var/backups/srv-deploy-2026-08-24.acl
# file: /srv/deploy
# owner: 0
# group: 0
user::rwx
group::r-x
other::r-x

# file: /srv/deploy/artifacts
# owner: 0
# group: 1200
# flags: -s-

# setfacl --restore=/var/backups/srv-deploy-2026-08-24.acl
```

### 7.3 Default ACLs: real inheritance, and they override the umask

A **default ACL** exists only on directories, is never used for access decisions, and serves purely as the template for newly created children:

- A new **file** gets an access ACL derived from the parent's default ACL.
- A new **subdirectory** gets both an access ACL **and a copy of the default ACL**, so the policy propagates automatically down the tree.

The crucial fact, stated in `acl(5)` and constantly missed: **if the parent directory has a default ACL, the process umask is ignored entirely.** Instead, the mode argument passed to `open(2)`/`mkdir(2)` clips the owner, mask and other entries of the resulting ACL.

```
# setfacl -d -m u::rwx,g::r-x,o::---,u:ci:rwx,g:deployers:r-x,g:sec-audit:r-x \
          /srv/deploy/artifacts

# getfacl /srv/deploy/artifacts
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
# owner: root
# group: deployers
# flags: -s-
user::rwx
user:ci:rwx
group::rwx
group:deployers:r-x
group:sec-audit:r-x
mask::rwx
other::---
default:user::rwx
default:user:ci:rwx
default:group::r-x
default:group:deployers:r-x
default:group:sec-audit:r-x
default:mask::rwx
default:other::---

# sudo -u ci sh -c 'umask 077; mkdir /srv/deploy/artifacts/build-4712; \
                    touch /srv/deploy/artifacts/build-4712/manifest.json'

# getfacl /srv/deploy/artifacts/build-4712/manifest.json
getfacl: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
# owner: ci
# group: deployers
user::rw-
user:ci:rwx			#effective:rw-
group::r-x			#effective:r--
group:deployers:r-x		#effective:r--
group:sec-audit:r-x		#effective:r--
mask::rw-
other::---
```

Read that output carefully — it is the whole model in one screen:

- The writer's `umask 077` was **completely ignored**. Under mode bits alone the file would have been `-rw-------` and every reader would have been broken.
- `touch` calls `open(..., 0666)`. The `0666` clipped the mask from `rwx` down to `rw-`, which is why every group-class entry shows `#effective:r--` — no `x` on a data file, correctly.
- The `x` in `default:group:deployers:r-x` was not wasted: on a *subdirectory*, `mkdir` requests `0777`, the mask stays `rwx`, and directories remain traversable. That is precisely what `r-x`/`rwx` in a default ACL buys you, and why you should write `rX` when using `setfacl` interactively.

**Default ACLs are strictly stronger than setgid directories** for shared workspaces: setgid controls only the *group*, and remains hostage to the writer's umask. A default ACL controls *the entire permission set*, immune to umask, and can express more than one named group. In practice you deploy **both**: setgid for group ownership consistency (which some tools and quota systems depend on), and a default ACL for the mode.

### 7.4 The `chmod` trap — the highest-severity ACL failure mode in production

**When a file has an extended ACL, the group triad shown by `ls -l` is the mask, not `group::`.** Therefore `chmod g-w` does not modify the owning group's entry — **it lowers the mask, silently clipping every named user and named group at once.**

```
$ getfacl -c /var/log/app/app.log
user::rw-
user:promtail:r--
group::r--
mask::r--
other::---

$ ls -l /var/log/app/app.log
-rw-r-----+ 1 appsvc appsvc 918273 Aug 24 10:52 /var/log/app/app.log
#     ^^^ this 'r' is mask::r--, NOT group::r--

$ sudo chmod 600 /var/log/app/app.log     # "hardening": remove group read

$ getfacl -c /var/log/app/app.log
user::rw-
user:promtail:r--		#effective:---
group::r--			#effective:---
mask::---
other::---
```

The log shipper is now silently blind. Nothing was deleted, `getfacl` still shows `promtail:r--`, and any grep-based verification (`getfacl file | grep promtail`) still passes. Only the `#effective:` comment reveals the outage.

**Mitigations, in order of preference:**

1. Any configuration-management or hardening step that runs `chmod` on a path must first assert the path has a minimal ACL. Treat "`chmod` on an ACL'd file" as a policy violation.
2. Repair by restoring the mask explicitly: `setfacl -m m::rw- FILE`, or let `setfacl` recompute it by re-applying any `-m`.
3. Audit continuously with `getfacl -R -e`, alerting on any `#effective:` line whose value differs from the entry.

```
# find /srv /var/log -type f -exec getfacl -c -e --skip-base {} + 2>/dev/null \
  | awk '/^# file:/{f=$3} /#effective:/{print f": "$0}'
/var/log/app/app.log: user:promtail:r--		#effective:---
/var/log/app/app.log: group::r--		#effective:---
```

### 7.5 Storage, limits, and the tools that silently destroy ACLs

ACLs are stored in two extended attributes in the `system` namespace:

```
$ getfattr -m '^system\.' -d /srv/deploy/artifacts
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts
system.posix_acl_access=0sAgAAAAEABwD/////AgAHANwFAAAEAAcA/////wgABQCwBAAACAAFABQFAAAQAAcA/////yAAAAD/////
system.posix_acl_default=0sAgAAAAEABwD/////AgAHANwFAAAEAAUA/////wgABQCwBAAACAAFABQFAAAQAAcA/////yAAAAD/////
```

You never edit these directly — the value is a packed binary structure (`struct posix_acl_xattr_header` + 8-byte entries). Their existence matters for three reasons:

**Storage limit.** The whole ACL must fit in a single extended attribute. On ext4 that means the in-inode xattr space (only with 256-byte-or-larger inodes) plus at most one filesystem block. The practical ceiling is on the order of a few hundred entries on a 4 KiB block size. Measure it on your own filesystem rather than trusting a number:

```
$ f=$(mktemp -p /srv/deploy) ; n=0
$ while setfacl -m "u:#$((10000+n)):r--" "$f" 2>/dev/null; do n=$((n+1)); done
$ echo "max named entries on this filesystem: $n"
max named entries on this filesystem: 507
$ setfacl -m u:#20000:r-- "$f"
setfacl: /srv/deploy/tmp.9kZq1: No space left on device      ← ENOSPC, not EACCES
$ rm -f "$f"
```

**Design implication: never enumerate users in an ACL.** Grant to groups. An ACL with 400 named users is unauditable, hits the filesystem ceiling, and must be rewritten on every joiner/leaver. An ACL with four named groups is a one-line policy and delegates membership to your identity system.

**Mount options.** ext2/3/4 require the `acl` option (compiled in and default since Linux 2.6.39 / e2fsprogs; `noacl` disables). XFS and Btrfs always support ACLs. Verify, never assume:

```
$ findmnt -no SOURCE,FSTYPE,OPTIONS /srv
/dev/mapper/vg0-srv ext4 rw,relatime,seclabel,nosuid,nodev,acl,data=ordered

$ findmnt -no TARGET,OPTIONS -t ext4,xfs,btrfs | grep -E 'noacl|nouser_xattr'
/mnt/legacy rw,relatime,noacl,nouser_xattr        ← ACLs will fail here with EOPNOTSUPP
```

**Tools that preserve, and tools that destroy.** This table is worth memorising; the right-hand column is a list of real incidents.

| Operation | Mode | Owner | POSIX ACL | `user.*` xattr | SELinux label |
|---|---|---|---|---|---|
| `cp file dst` | ✗ (umask) | ✗ | ✗ | ✗ | ✗ (type transition) |
| `cp -p` | ✓ | ✓ (root) | ✗ | ✗ | ✗ |
| `cp -a` / `cp --preserve=all` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `mv` (same filesystem) | ✓ | ✓ | ✓ | ✓ | ✓ (pure `rename(2)`) |
| `mv` (across filesystems) | ✓ | ✓ | ✓ best-effort | ✓ best-effort | ✓ best-effort |
| `rsync -a` | ✓ | ✓ | **✗** | **✗** | ✗ |
| `rsync -aAX --numeric-ids` | ✓ | ✓ | ✓ | ✓ | ✓ (with `-X`) |
| `tar -cf` | ✓ | ✓ | **✗** | **✗** | ✗ |
| `tar --acls --xattrs --selinux` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `install -m` | set explicitly | set explicitly | **✗** | **✗** | ✗ |
| `> file` (truncate) | ✓ | ✓ | ✓ | ✓ | ✓ (same inode) |
| **`sed -i`** | ✓ copied | ✓ (root) | **✗** | **✗** | **✗** |
| **Editor write-and-rename** (`vim` default, `emacs`) | ✓ copied | varies | **✗** | **✗** | **✗** |
| `dd`, `cat >` into a new file | ✗ | ✗ | ✗ | ✗ | ✗ |

The last two rows are the ones that bite. `sed -i` does **not** edit in place: it writes a temporary file and `rename(2)`s it over the target. The result is a **new inode** with fresh permissions — every ACL, every extended attribute, and the SELinux label are gone. A "harmless" `sed -i 's/debug/info/' /var/log/app/logrotate.conf` on an ACL'd file removes the log shipper's access.

```
$ getfacl -c /etc/app/app.conf | grep promtail
user:promtail:r--
$ stat -c %i /etc/app/app.conf
1443122
$ sudo sed -i 's/^level=.*/level=info/' /etc/app/app.conf
$ stat -c %i /etc/app/app.conf
1443198                                       ← different inode
$ getfacl -c /etc/app/app.conf | grep promtail
$ ls -l /etc/app/app.conf
-rw-r--r-- 1 root root 412 Aug 24 11:04 /etc/app/app.conf     ← no '+', ACL destroyed
```

**Rule:** after any in-place edit of a file carrying an ACL, re-apply from a stored spec and run `restorecon`. Configuration management, not `sed`, should own such files.

### 7.6 POSIX ACLs vs NFSv4 ACLs

Two incompatible ACL models exist in the Linux ecosystem. Knowing which one you are on determines which toolchain works.

| | POSIX draft ACL | NFSv4 / NFSv4.1 ACL |
|---|---|---|
| Model | Allow-only, ordered by class | **Ordered ACEs, ALLOW *and* DENY** |
| Evaluation | First matching *class*, mask applied | Sequential ACE scan; first decisive match; order is semantic |
| Permission granularity | 3 bits (`rwx`) | ~14 bits: `read_data`, `write_data`, `append_data`, `read_attributes`, `write_acl`, `delete`, `delete_child`, `write_owner`, … |
| Inheritance | `default:` ACL on a directory | Per-ACE flags: `fi` (file_inherit), `di` (dir_inherit), `ni` (no_propagate), `oi` (inherit_only) |
| Mask concept | Yes — the source of §7.4's trap | No mask |
| Linux native support | ext2/3/4, XFS, Btrfs, tmpfs, JFS, ReiserFS, OpenZFS (`acltype=posix`) | OpenZFS (`acltype=nfsv4`), NFSv4 mounts. `richacl` was never merged into mainline |
| Tooling | `getfacl` / `setfacl` (`acl` package) | `nfs4_getfacl` / `nfs4_setfacl` (`nfs4-acl-tools`) |
| Windows/SMB fidelity | Lossy | High — maps closely to NTFS DACLs |

On a Linux NFSv4 server exporting ext4/XFS, `nfsd` **translates** POSIX ACLs into NFSv4 ACLs on the wire. The translation is lossy in both directions; a `DENY` ACE set from a Windows client cannot be represented on the server's POSIX ACL. Symptoms of this mismatch — permissions that "reset" or "won't stick" — are a translation artefact, not a bug.

Legacy NFSv3 uses a separate `NFSACL` sideband RPC program; `mount -o noacl` disables it on the client. And `root_squash` (the export default) maps the client's uid 0 to `nobody`, so `chown`, `chmod` on files you do not own, and `chattr +i` all fail with `EPERM` from an NFS client regardless of local privilege.

---

## 8. Extended attributes

ACLs are one consumer of a general mechanism: arbitrary `name=value` pairs attached to an inode, partitioned into four namespaces with different access rules.

| Namespace | Who may **read** | Who may **write** | Purpose | Preserved by |
|---|---|---|---|---|
| `user.*` | Anyone with `r` on the file | Anyone with `w` on the file; requires a regular file or directory (**not** symlinks or device nodes); on a sticky directory, only the owner or `CAP_FOWNER` | Application metadata: MIME type, checksums, provenance, build IDs | `cp -a`, `rsync -X`, `tar --xattrs` |
| `trusted.*` | `CAP_SYS_ADMIN` only — **invisible** to unprivileged processes, even the file owner | `CAP_SYS_ADMIN` | Kernel subsystems: `trusted.overlay.*` for overlayfs; out-of-band provenance an application must not be able to forge | Only when copied as root with `--xattrs` |
| `system.*` | Governed by the owning kernel subsystem | Same | `system.posix_acl_access`, `system.posix_acl_default`, `system.nfs4_acl` | Via the ACL-aware flags |
| `security.*` | Governed by the LSM / IMA | Governed by the LSM | `security.selinux`, `security.SMACK64`, `security.capability` (file capabilities), `security.ima`, `security.evm` | `tar --selinux`, `rsync -X`, `cp -a` |

The `user.*` restriction on symlinks and device nodes is deliberate: those inodes' permission bits are not meaningful access controls, so allowing user xattrs on them would be an unbounded, unaccounted storage channel.

```
$ setfattr -n user.build.commit -v 9f3a17d2c /srv/deploy/artifacts/build-4712/manifest.json
$ setfattr -n user.build.pipeline -v 'gitlab/platform#4712' /srv/deploy/artifacts/build-4712/manifest.json
$ setfattr -n user.build.sbom.sha256 \
           -v 4f1a...c9 /srv/deploy/artifacts/build-4712/manifest.json

$ getfattr -d /srv/deploy/artifacts/build-4712/manifest.json
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
user.build.commit="9f3a17d2c"
user.build.pipeline="gitlab/platform#4712"
user.build.sbom.sha256="4f1a...c9"
```

`getfattr` defaults to `-m '^user\.'`. To see everything you must ask, and you must be root:

```
# getfattr -d -m - /srv/deploy/artifacts/build-4712/manifest.json
getfattr: Removing leading '/' from absolute path names
# file: srv/deploy/artifacts/build-4712/manifest.json
security.selinux="system_u:object_r:var_t:s0"
system.posix_acl_access=0sAgAAAAEABgD/////BAAEAP////8QAAQA/////yAAAAD/////
user.build.commit="9f3a17d2c"
user.build.pipeline="gitlab/platform#4712"
user.build.sbom.sha256="4f1a...c9"
```

Encoding and removal:

```
$ getfattr -n user.build.commit -e hex FILE     # -e text|hex|base64 (base64 is the default for binary)
$ setfattr -x user.build.pipeline FILE          # remove one
$ setfattr -h -n user.foo -v bar SYMLINK        # act on the symlink itself (will fail: EPERM)
setfattr: SYMLINK: Operation not permitted
```

### 8.1 `security.capability` — the modern replacement for setuid

File capabilities live in the `security.*` namespace and are the correct way to grant a binary one specific privilege instead of all of them.

```
# getcap -r /usr/bin /usr/sbin 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/bin/mtr-packet cap_net_raw=ep

# setcap 'cap_net_bind_service=+ep' /usr/local/bin/edge-proxy
# getcap /usr/local/bin/edge-proxy
/usr/local/bin/edge-proxy cap_net_bind_service=ep

# getfattr -n security.capability -e hex /usr/local/bin/edge-proxy
getfattr: Removing leading '/' from absolute path names
# file: usr/local/bin/edge-proxy
security.capability=0x01000002000004000000000000000400000000000000000000000000

# ls -l /usr/local/bin/edge-proxy
-rwxr-xr-x 1 root root 8412160 Aug 24 11:18 /usr/local/bin/edge-proxy
```

Note the last line: **`ls -l` shows nothing.** A binary with `cap_sys_admin=ep` — effectively equivalent to root — is indistinguishable from an ordinary executable in a directory listing. Any hardening audit that greps for `find / -perm -4000` and stops there has a blind spot the size of the entire capability system. Both sweeps are mandatory (§13).

The suffix letters are the capability sets: `e` = effective (raised automatically at exec), `p` = permitted (may be raised by the program itself), `i` = inheritable. `cap_x=ep` is "always on"; `cap_x=p` requires a capability-aware program that raises it deliberately and drops it after use — strictly better, and what `edge-proxy` should do around its `bind()`.

`security.capability`, like setuid, is defeated by `nosuid` mounts and by `no_new_privs`.

### 8.2 Extended attribute support matrix

| Filesystem | Mode bits | POSIX ACL | `user.*` | `trusted.*`/`security.*` | Notes |
|---|---|---|---|---|---|
| ext4 | ✓ | ✓ (`acl`, default) | ✓ (`user_xattr`, default) | ✓ | Inline in inode ≥256 B, else one block |
| XFS | ✓ | ✓ always | ✓ always | ✓ | Attribute fork; much larger capacity |
| Btrfs | ✓ | ✓ | ✓ | ✓ | Per-subvolume; snapshots preserve |
| OpenZFS | ✓ | `acltype=posix` or `nfsv4` | ✓ (`xattr=sa` recommended) | ✓ | `xattr=dir` is slow — one hidden directory per file |
| tmpfs | ✓ | ✓ | ✓ **only on Linux ≥ 6.6** | ✓ | Older kernels support `trusted.`/`security.` only |
| overlayfs | ✓ | ✓ | ✓ | ✓ | Uses `trusted.overlay.*` internally (`user.overlay.*` when unprivileged) |
| vfat / exfat | ✗ | ✗ | ✗ | ✗ | Ownership synthesised at mount: `uid=`, `gid=`, `umask=`, `fmask=`, `dmask=` |
| NTFS3 | partial | ✗ | ✓ | partial | Via `system.ntfs_*`; `uid=`/`gid=` mapping typical |
| NFSv3 | ✓ | ✓ (NFSACL sideband) | ✗ | ✗ | `noacl` to disable |
| NFSv4 | ✓ | translated ↔ NFSv4 ACL | ✗ | limited | See §7.6 |
| virtiofs | ✓ | ✓ | ✓ (with `-o xattr`) | ✓ | Depends on daemon configuration |
| 9p | ✓ | limited | limited | ✗ | Avoid for permission-sensitive workloads |

The `vfat` row explains a recurring incident class: **a USB stick or EFI partition cannot hold Unix ownership.** Every file appears as `root:root 0755` (or whatever the mount options say). Copying a private key onto one and back destroys its `0600`. The mount options are the only control you have:

```
# mount -o uid=1000,gid=1000,fmask=0177,dmask=0077,noexec,nosuid,nodev \
        /dev/sdb1 /mnt/transfer
$ ls -l /mnt/transfer
-rw------- 1 sre sre 3243 Aug 24 11:26 id_ed25519
```

Note `fmask`/`dmask` are umasks, not modes: `fmask=0177` yields `0600` files, `dmask=0077` yields `0700` directories.

---

## 9. File attributes: `chattr` / `lsattr`

Extended attributes are data *about* an inode. File attributes are flags that change how the **filesystem itself** treats the inode. They are enforced by the kernel *before* the DAC check, which is why they are the only way to constrain root without a MAC policy.

```
$ lsattr /etc/passwd /etc/shadow /var/log/audit/audit.log
--------------e------- /etc/passwd
----i---------e------- /etc/shadow
-----a--------e------- /var/log/audit/audit.log

$ lsattr -d /srv/deploy/artifacts       # -d: the directory itself, not its contents
--------------e------- /srv/deploy/artifacts
```

| Flag | Name | Semantics | Requires | Filesystems |
|---|---|---|---|---|
| `i` | Immutable | No write, no rename, no unlink, no new hardlink, no metadata change — **including by root** | `CAP_LINUX_IMMUTABLE` | ext2/3/4, XFS, Btrfs, F2FS |
| `a` | Append-only | `open()` permitted only with `O_APPEND`; no truncate, no unlink | `CAP_LINUX_IMMUTABLE` | ext2/3/4, XFS, Btrfs |
| `A` | No atime | Suppress atime updates for this inode | owner | ext2/3/4, XFS, Btrfs |
| `d` | No dump | Skipped by `dump(8)` | owner | ext2/3/4, Btrfs |
| `S` | Synchronous writes | Data written synchronously, as if `O_SYNC` | owner | ext2/3/4 |
| `D` | Synchronous dirs | Directory changes written synchronously | owner | ext2/3/4, Btrfs |
| `j` | Data journalling | Journal data as well as metadata | `CAP_SYS_RESOURCE` | ext3/4 (`data=ordered`/`writeback`) |
| `t` | No tail-merge | Disable tail packing | owner | ext4 (`bigalloc`), ReiserFS |
| `u` | Undeletable | Preserve contents on delete for undeletion | owner | not implemented in mainline |
| `c` | Compressed | Transparent compression | owner | Btrfs (**not** ext4 — ext4 rejects it) |
| `C` | No copy-on-write | Disable CoW — **only settable on a zero-length file or an empty directory** | owner | Btrfs |
| `P` | Project hierarchy | Propagate the project ID to children (quota) | owner | ext4, XFS |
| `V` | Verity | fs-verity enabled — read-only indicator | — | ext4, F2FS, Btrfs |
| `e` | Extents | Uses extent mapping — **read-only**, cannot be set or cleared | — | ext4 |
| `E` / `I` / `N` | Encrypted / Indexed dir / Inline data | Read-only status indicators | — | ext4 |

### 9.1 `+i` and `+a` in production: what they actually buy, and what they cost

```
# chattr +i /etc/shadow
# lsattr /etc/shadow
----i---------e------- /etc/shadow

# echo x >> /etc/shadow
-bash: /etc/shadow: Operation not permitted            ← EPERM, as root

# rm -f /etc/shadow
rm: cannot remove '/etc/shadow': Operation not permitted

# chattr -i /etc/shadow && echo x >> /etc/shadow && chattr +i /etc/shadow
```

**The value:** a kernel-enforced tripwire. An attacker who has achieved root but not `CAP_LINUX_IMMUTABLE` (a container without it, a MAC-confined process, a `no_new_privs` service) cannot modify the file. Even with the capability, the required `chattr -i` is a distinctive, cheap-to-audit syscall (`ioctl(FS_IOC_SETFLAGS)`) that almost no legitimate process makes.

**The cost, and it is real:**

| Trade-off | Detail |
|---|---|
| Package upgrades break | `rpm`/`dpkg` write config files and fail with `EPERM` mid-transaction, leaving a half-upgraded system |
| `passwd`, `usermod`, `useradd` break | `+i` on `/etc/shadow` makes password changes fail |
| Config management breaks | Ansible/Puppet report a failure they cannot remediate |
| Backups can fail to restore | Restoring over an immutable file fails; the flag itself is preserved only by `tar` builds with attribute support, or must be reapplied by config management |
| Not preserved on copy | `cp` does not copy attributes; `rsync` does not either. The flag must be part of your configuration, not your data |
| Defeated by `CAP_LINUX_IMMUTABLE` | It is a speed bump and a detection signal, **not a containment boundary** |

**Correct usage pattern:** apply `+i` to a small, explicitly enumerated set of files that legitimately never change between maintenance windows, and make the removal/reapplication an explicit, audited step in your patching runbook — not something an engineer discovers at 03:00.

`+a` (append-only) is the better fit for logs, because it permits the one operation a log needs while forbidding truncation and deletion — exactly the two things an intruder wants:

```
# chattr +a /var/log/audit/audit.log
# : > /var/log/audit/audit.log
-bash: /var/log/audit/audit.log: Operation not permitted
# echo 'test entry' >> /var/log/audit/audit.log
# echo $?
0
```

Note this conflicts with rotation: `logrotate` must be configured with `copytruncate` disabled and a `prerotate`/`postrotate` pair that clears and reapplies the flag, or the rotation will fail every night.

Recursion has an important asymmetry: `chattr -R +i /dir` sets the flag on the directory **and** every file below it. An immutable *directory* prevents creating, deleting, or renaming entries but does not prevent modifying existing files' contents.

---

## 10. Consolidated trade-off analysis

### 10.1 Choosing a mechanism for a shared directory

| Mechanism | Expresses | umask-independent | Multi-group | Inherits to subdirs | Portable | Cost |
|---|---|---|---|---|---|---|
| Mode bits only | 1 group | ✗ | ✗ | ✗ | Universal | Zero |
| setgid directory | 1 group (ownership only) | ✗ — mode still from umask | ✗ | ✓ (bit propagates) | Universal | Zero |
| setgid + enforced `UMask=` in the unit | 1 group | ✓ per-service | ✗ | ✓ | Universal | Zero; brittle if any other writer exists |
| **Default ACL** | n groups + n users, full mode | **✓** | **✓** | **✓** | Linux/Unix with ACL support | 1 xattr block |
| **setgid + default ACL** | n groups, consistent ownership | ✓ | ✓ | ✓ | Linux | 1 xattr block |
| SELinux type + transition | Type-based, orthogonal to identity | ✓ | n/a | ✓ | SELinux only | Policy authorship |

**Recommendation for §1.1: setgid + default ACL.** It is the only combination that survives an arbitrary writer's umask, expresses more than one reader group, and propagates automatically to build directories created months later.

### 10.2 Granting a privileged capability to a program

| Mechanism | Granularity | Auditable via `ls -l` | Survives `nosuid` | Survives `no_new_privs` | Logged | Revocation |
|---|---|---|---|---|---|---|
| setuid root binary | **All** privileges | ✓ (`s`) | ✗ | ✗ | ✗ | `chmod u-s` |
| File capability (`security.capability`) | One capability | **✗ (invisible)** | ✗ | ✗ | ✗ | `setcap -r` |
| `sudo` rule | One command line, per-user | n/a | n/a | n/a | **✓ (syslog)** | Edit sudoers |
| systemd unit + `AmbientCapabilities=` | One capability, one service | n/a | n/a | ✓ (set by the manager) | ✓ (journal) | Edit the unit |
| Privileged helper over a UNIX socket (Polkit/D-Bus) | Arbitrary, application-defined | n/a | n/a | ✓ | ✓ | Policy file |

**Ranking for new work:** systemd `AmbientCapabilities=` > privileged helper > `sudo` > file capability > setuid. Setuid root should be treated as legacy; every one on your system is an unaudited privilege-escalation primitive that you are choosing to keep.

### 10.3 The layered picture

| Layer | Type | Granularity | Overridable by the owner | Survives filesystem move | Bypassed by |
|---|---|---|---|---|---|
| Mode bits | DAC | 3 subjects × 3 ops | **Yes** | ✓ | `CAP_DAC_OVERRIDE` |
| POSIX ACL | DAC | n subjects × 3 ops | **Yes** | Only with `cp -a`/`rsync -A` | `CAP_DAC_OVERRIDE` |
| File attributes (`+i`) | Neither — fs-level | Per-inode | No | ✗ (not copied) | `CAP_LINUX_IMMUTABLE` |
| Capabilities | Privilege model | Per-capability | No | Only with `--xattrs` | `nosuid`, `no_new_privs` |
| SELinux / AppArmor | **MAC** | Type/label × operation | **No** | Relabelled on move | Permissive mode, `setenforce 0` |
| Namespaces / seccomp | Isolation | Per-syscall / per-resource | No | n/a | Kernel bug |

The rows compose with **AND**: every one must permit. The debugging consequence is that "check the permissions" is never a complete answer — `EACCES` from DAC and `EACCES` from SELinux look identical to the application. §12 shows how to tell them apart in one command.

---

## 11. Production infrastructure

Everything below is complete and deployable, not excerpted.

### 11.1 `systemd-tmpfiles` — the declarative, idempotent source of truth

This is the correct place to express filesystem access policy on a systemd host. It runs at boot, on demand, and is fully idempotent.

```
# /etc/tmpfiles.d/50-build-artifacts.conf
#
# Discretionary access control for the build/artifact host.
# Type  Path                          Mode UID   GID        Age  Argument
#
# 'd'  create directory (and adjust mode/ownership if it exists)
# 'a+' merge POSIX ACL entries; 'd:' prefix = default (inherited) ACL
# 'A+' same as a+ but applied recursively to existing contents
# 'h'  set file attributes (chattr)
# 'z'  restore SELinux/SMACK label on the path itself
# 'Z'  restore label recursively

# --- Artifact root: setgid so group ownership is consistent, --------------
# --- default ACL so the mode is independent of every writer's umask. ------
d     /srv/deploy                     0755 root  root       -    -
d     /srv/deploy/artifacts           2770 root  deployers  -    -
a+    /srv/deploy/artifacts           -    -     -          -    user:ci:rwx,group:deployers:rwx,group:sec-audit:r-x
a+    /srv/deploy/artifacts           -    -     -          -    d:user::rwx,d:group::rwx,d:other::---,d:user:ci:rwx,d:group:deployers:rwx,d:group:sec-audit:r-X

# --- Published artifacts: writable only by the release bot, ---------------
# --- readable by everything that deploys. ---------------------------------
d     /srv/deploy/published           2750 release deployers -   -
a+    /srv/deploy/published           -    -     -          -    group:sec-audit:r-x,d:group:sec-audit:r-X,d:user::rwx,d:group::r-x,d:other::---

# --- Build scratch: sticky so tenants cannot delete each other's work. ----
d     /srv/deploy/scratch             1770 root  ci-runners 3d   -

# --- Incoming drop box: --wx, write-only. Uploaders can deposit but -------
# --- cannot enumerate or read back what is already there. -----------------
d     /srv/deploy/incoming            1733 root  root       7d   -

# --- Application logs: the shipper reads, nobody else sees them. ----------
d     /var/log/app                    2750 appsvc appsvc    -    -
a+    /var/log/app                    -    -     -          -    user:promtail:r-x,d:user:promtail:r--,d:user::rw-,d:group::r--,d:other::---

# --- Secrets: no group, no other, no inheritance surprises. ---------------
d     /etc/app/secrets                0700 appsvc appsvc    -    -
z     /etc/app/secrets/*              0400 appsvc appsvc    -    -

# --- Audit log: append-only at the filesystem level. ----------------------
h     /var/log/audit/audit.log        -    -     -          -    +a

# --- Relabel everything we just created (no-op on non-SELinux systems). ---
Z     /srv/deploy                     -    -     -          -    -
Z     /var/log/app                    -    -     -          -    -
```

Apply and verify:

```
# systemd-tmpfiles --create /etc/tmpfiles.d/50-build-artifacts.conf
# systemd-tmpfiles --create --dry-run /etc/tmpfiles.d/50-build-artifacts.conf   # idempotency check
# echo $?
0

# getfacl -c /srv/deploy/artifacts
user::rwx
user:ci:rwx
group::rwx
group:deployers:rwx
group:sec-audit:r-x
mask::rwx
other::---
default:user::rwx
default:user:ci:rwx
default:group::rwx
default:group:deployers:rwx
default:group:sec-audit:r-x
default:mask::rwx
default:other::---
```

The `1733` on `/srv/deploy/incoming` (`drwx-wx-wt`) deserves attention: **write-only drop box**. Uploaders may create files but cannot `readdir` (no `r`), cannot read back what they wrote, and cannot delete anything (sticky). It is the correct mode for an ingest path that must not double as an exfiltration channel.

### 11.2 systemd unit — DAC enforced by the service manager

```ini
# /etc/systemd/system/payments-api.service
[Unit]
Description=Payments API
Documentation=https://internal.example.com/runbooks/payments-api
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/payments-api --config /etc/payments-api/config.yaml

# ---- Identity --------------------------------------------------------------
User=payments
Group=payments
# Read the shared TLS bundle and write to the shared artifact group.
SupplementaryGroups=tls-readers deployers

# ---- Creation-time mode ----------------------------------------------------
# Authoritative for this service. /etc/profile is NOT consulted by systemd.
UMask=0027

# ---- Managed directories: systemd creates, chowns and chmods these ---------
# and removes them on 'systemctl clean'. Paths are relative to /var/lib,
# /var/log, /run and /var/cache respectively.
StateDirectory=payments-api
StateDirectoryMode=0750
LogsDirectory=payments-api
LogsDirectoryMode=0750
RuntimeDirectory=payments-api
RuntimeDirectoryMode=0750
CacheDirectory=payments-api
CacheDirectoryMode=0700
ConfigurationDirectory=payments-api
ConfigurationDirectoryMode=0750

# ---- Privilege boundary ----------------------------------------------------
# NoNewPrivileges sets PR_SET_NO_NEW_PRIVS: every setuid bit and every
# file capability below this process is permanently neutralised.
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
RestrictSUIDSGID=yes
RemoveIPC=yes

# ---- Filesystem namespace --------------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectProc=invisible
ProcSubset=pid
ReadOnlyPaths=/etc/payments-api /etc/ssl/private
ReadWritePaths=/srv/deploy/artifacts
InaccessiblePaths=/srv/deploy/published /etc/app/secrets

# ---- Syscall and network surface ------------------------------------------
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete @mount
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
```

`RestrictSUIDSGID=yes` is the complement to `NoNewPrivileges`: the first stops the service from *gaining* privilege via a set-id binary, the second stops it from *creating* one. Together they close both directions.

Verify against the running process rather than the file:

```
# systemctl daemon-reload && systemctl restart payments-api
# systemd-analyze security payments-api | head -14
  NAME                                                        DESCRIPTION                             EXPOSURE
✓ PrivateNetwork=                                             Service has access to the host's netw…       0.5
✓ User=/DynamicUser=                                          Service runs under a static non-root …       0.0
✓ CapabilityBoundingSet=~CAP_SET(UID|GID|PCAP)                Service cannot change UID/GID identit…       0.0
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN                        Service has no administrator privileg…       0.0
✓ RestrictSUIDSGID=                                           SUID/SGID file creation is not restri…       0.0
✓ NoNewPrivileges=                                            Service processes cannot acquire new …       0.0

→ Overall exposure level for payments-api.service: 1.9 OK 🙂

# P=$(systemctl show -p MainPID --value payments-api)
# grep -E 'Umask|Uid|Gid|Groups|NoNewPrivs|CapEff' /proc/$P/status
Umask:	0027
Uid:	997	997	997	997
Gid:	997	997	997	997
Groups:	1200 1401
NoNewPrivs:	1
CapEff:	0000000000000400
# capsh --decode=0000000000000400
0x0000000000000400=cap_net_bind_service
```

### 11.3 Ansible — reproducible, idempotent DAC

```yaml
---
# roles/build-host-dac/tasks/main.yml
# Discretionary access control baseline for the build/artifact host.
# Requires: acl, attr, e2fsprogs on the target; `setfacl` for the acl module.

- name: Ensure DAC tooling is present
  ansible.builtin.package:
    name:
      - acl
      - attr
      - e2fsprogs
      - libcap
    state: present

- name: Assert the target filesystem supports ACLs
  ansible.builtin.command:
    cmd: findmnt -no OPTIONS --target /srv
  register: srv_mount_opts
  changed_when: false

- name: Fail loudly if ACLs are disabled on /srv
  ansible.builtin.assert:
    that:
      - "'noacl' not in srv_mount_opts.stdout"
      - "'nouser_xattr' not in srv_mount_opts.stdout"
    fail_msg: >-
      /srv is mounted with noacl and/or nouser_xattr ({{ srv_mount_opts.stdout }}).
      Every setfacl below would fail with EOPNOTSUPP. Fix /etc/fstab and remount
      before continuing.

- name: Create service groups
  ansible.builtin.group:
    name: "{{ item.name }}"
    gid: "{{ item.gid }}"
    system: true
    state: present
  loop:
    - { name: deployers,   gid: 1200 }
    - { name: sec-audit,   gid: 1300 }
    - { name: ci-runners,  gid: 1500 }

- name: Create service accounts
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ item.uid }}"
    group: "{{ item.group }}"
    groups: "{{ item.extra | default(omit) }}"
    shell: /usr/sbin/nologin
    home: "{{ item.home }}"
    create_home: true
    system: true
    state: present
  loop:
    - { name: ci,       uid: 1500, group: ci-runners, home: /var/lib/ci }
    - { name: release,  uid: 1501, group: deployers,  home: /var/lib/release }
    - { name: promtail, uid: 1502, group: promtail,   home: /var/lib/promtail }

# --- Ordering matters: owner/group FIRST, then mode. A chown after a chmod
# --- silently strips setuid/setgid. See chown(2).
- name: Create the artifact tree with ownership and setgid
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    owner: "{{ item.owner }}"
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: /srv/deploy,            owner: root,    group: root,       mode: "0755" }
    - { path: /srv/deploy/artifacts,  owner: root,    group: deployers,  mode: "2770" }
    - { path: /srv/deploy/published,  owner: release, group: deployers,  mode: "2750" }
    - { path: /srv/deploy/scratch,    owner: root,    group: ci-runners, mode: "1770" }
    - { path: /srv/deploy/incoming,   owner: root,    group: root,       mode: "1733" }
    - { path: /var/log/app,           owner: appsvc,  group: appsvc,     mode: "2750" }

- name: Apply access ACLs on the artifact root
  ansible.posix.acl:
    path: /srv/deploy/artifacts
    entity: "{{ item.entity }}"
    etype: "{{ item.etype }}"
    permissions: "{{ item.perms }}"
    default: false
    state: present
  loop:
    - { entity: ci,        etype: user,  perms: rwx }
    - { entity: deployers, etype: group, perms: rwx }
    - { entity: sec-audit, etype: group, perms: rx  }

# --- Default ACLs make the resulting mode independent of the writer's umask.
# --- Without these, a runner with `umask 077` produces unreadable artifacts.
- name: Apply default (inherited) ACLs on the artifact root
  ansible.posix.acl:
    path: /srv/deploy/artifacts
    entity: "{{ item.entity | default(omit) }}"
    etype: "{{ item.etype }}"
    permissions: "{{ item.perms }}"
    default: true
    state: present
  loop:
    - { etype: user,                     perms: rwx }   # default:user::
    - { etype: group,                    perms: rwx }   # default:group::
    - { etype: other,                    perms: "-"  }  # default:other::
    - { etype: user,  entity: ci,        perms: rwx }
    - { etype: group, entity: deployers, perms: rwx }
    - { etype: group, entity: sec-audit, perms: rx  }

- name: Log shipper reads application logs, writes nothing
  ansible.posix.acl:
    path: "{{ item.path }}"
    entity: promtail
    etype: user
    permissions: "{{ item.perms }}"
    default: "{{ item.default }}"
    state: present
  loop:
    - { path: /var/log/app, perms: rx, default: false }
    - { path: /var/log/app, perms: r,  default: true  }

- name: Record build provenance in user extended attributes
  ansible.builtin.command:
    cmd: >-
      setfattr -n user.dac.policy_version -v "{{ dac_policy_version }}"
      /srv/deploy/artifacts
  changed_when: true

- name: Filesystem hardening sysctls
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/60-fs-hardening.conf
    state: present
    reload: true
  loop:
    - { key: fs.protected_symlinks,  value: "1" }
    - { key: fs.protected_hardlinks, value: "1" }
    - { key: fs.protected_fifos,     value: "2" }
    - { key: fs.protected_regular,   value: "2" }

- name: Make the audit log append-only
  ansible.builtin.command:
    cmd: chattr +a /var/log/audit/audit.log
  register: chattr_a
  changed_when: chattr_a.rc == 0
  failed_when:
    - chattr_a.rc != 0
    - "'Operation not supported' not in chattr_a.stderr"

# --- Verification is part of the play, not a separate manual step. ----------
- name: Verify no unexpected setuid/setgid binaries exist
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort
  args:
    executable: /bin/bash
  register: setid_found
  changed_when: false

- name: Report drift from the approved set-id baseline
  ansible.builtin.assert:
    that:
      - (setid_found.stdout_lines | difference(approved_setid_binaries)) | length == 0
    fail_msg: >-
      Unapproved set-id binaries present:
      {{ setid_found.stdout_lines | difference(approved_setid_binaries) | join(', ') }}
    success_msg: "Set-id baseline clean ({{ setid_found.stdout_lines | length }} approved entries)."
```

```yaml
# roles/build-host-dac/defaults/main.yml
dac_policy_version: "2026.08.24"

# The approved setuid/setgid baseline. Anything not on this list is drift and
# must be justified or removed. Regenerate deliberately, never automatically.
approved_setid_binaries:
  - /usr/bin/chage
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/crontab
  - /usr/bin/expiry
  - /usr/bin/gpasswd
  - /usr/bin/mount
  - /usr/bin/newgrp
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/umount
  - /usr/bin/wall
  - /usr/bin/write
  - /usr/libexec/openssh/ssh-keysign
  - /usr/sbin/pam_timestamp_check
  - /usr/sbin/unix_chkpwd
```

### 11.4 Kubernetes — how DAC reaches into a pod

Container filesystem permissions are still DAC; the only difference is that UIDs are numbers with no `/etc/passwd` entry, and volumes arrive with whatever ownership the storage layer gave them.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-build
  labels:
    # Pod Security Admission blocks privileged containers, privilege
    # escalation, and non-root violations at admission time — a policy layer
    # ABOVE the DAC we configure inside the pod, not a replacement for it.
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: artifact-store
  namespace: platform-build
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: nfs-csi
  resources:
    requests:
      storage: 200Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: artifact-writer
  namespace: platform-build
  labels:
    app.kubernetes.io/name: artifact-writer
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: artifact-writer
  template:
    metadata:
      labels:
        app.kubernetes.io/name: artifact-writer
    spec:
      automountServiceAccountToken: false

      securityContext:
        # ---- Process identity: DAC subject ---------------------------------
        runAsNonRoot: true
        runAsUser: 1500          # ci
        runAsGroup: 1500         # ci-runners
        # Supplementary GIDs. These are the group-class entries the kernel
        # will match against POSIX ACLs on the mounted volume.
        supplementalGroups: [1200, 1300]   # deployers, sec-audit

        # ---- Volume ownership: DAC object ----------------------------------
        # fsGroup makes the kubelet chgrp the volume to 1200 and set g+s on
        # its root, so every file the container creates inherits gid 1200.
        # This is exactly the setgid-directory mechanism from section 5.2,
        # applied by the kubelet at mount time.
        fsGroup: 1200
        # OnRootMismatch skips the recursive chown when the volume root
        # already has the right gid+setgid. On a 200Gi volume with millions
        # of inodes, "Always" adds minutes to every pod start. This is the
        # single most impactful DAC-related startup-latency setting in K8s.
        fsGroupChangePolicy: OnRootMismatch

        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: writer
          image: registry.internal.example.com/platform/artifact-writer:1.14.2
          imagePullPolicy: IfNotPresent

          securityContext:
            # PR_SET_NO_NEW_PRIVS. Neutralises every setuid bit and every
            # file capability inside the image, permanently and irreversibly.
            allowPrivilegeEscalation: false
            # The image's root filesystem is immutable. Anything that needs
            # to be writable is an explicit emptyDir below.
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            runAsUser: 1500
            runAsGroup: 1500
            runAsNonRoot: true

          env:
            # The process umask. There is no Kubernetes field for this; the
            # entrypoint must apply it, or the image must be built with it.
            - name: WRITER_UMASK
              value: "0007"

          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              umask "${WRITER_UMASK}"
              exec /usr/local/bin/artifact-writer --root /srv/artifacts

          volumeMounts:
            - name: artifacts
              mountPath: /srv/artifacts
            - name: tmp
              mountPath: /tmp
            - name: run
              mountPath: /run/artifact-writer

          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { cpu: "2",  memory: 1Gi }

        # ---- Sidecar: reads what the writer produces, writes nothing -------
        - name: shipper
          image: registry.internal.example.com/platform/promtail:3.4.1
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
            runAsUser: 1502        # promtail
            runAsGroup: 1502
            runAsNonRoot: true
          volumeMounts:
            - name: artifacts
              mountPath: /srv/artifacts
              # Kubernetes-level read-only mount (MS_RDONLY on the bind).
              # This is a SECOND, independent control: even if the on-disk
              # ACL granted write, the mount would return EROFS.
              # Defence in depth — the ACL is still required, because a
              # read-only mount does not grant read access.
              readOnly: true
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }

      volumes:
        - name: artifacts
          persistentVolumeClaim:
            claimName: artifact-store
        # readOnlyRootFilesystem forces every writable path to be explicit.
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: run
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

Verify inside the running pod — the numbers must match the manifest:

```
$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- id
uid=1500 gid=1500 groups=1500,1200,1300

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- \
    sh -c 'ls -ld /srv/artifacts; grep Umask /proc/self/status'
drwxrwsr-x 4 root 1200 4096 Aug 24 11:47 /srv/artifacts
Umask:	0007

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- \
    sh -c 'touch /srv/artifacts/probe && ls -l /srv/artifacts/probe'
-rw-rw---- 1 1500 1200 0 Aug 24 11:48 /srv/artifacts/probe

$ kubectl -n platform-build exec deploy/artifact-writer -c writer -- touch /etc/probe
touch: /etc/probe: Read-only file system
command terminated with exit code 1

$ kubectl -n platform-build exec deploy/artifact-writer -c shipper -- \
    touch /srv/artifacts/evil
touch: /srv/artifacts/evil: Read-only file system
command terminated with exit code 1
```

Note `drwxrwsr-x` on the volume root — the `s` was set by the kubelet as a direct consequence of `fsGroup: 1200`. `fsGroup` is setgid-directory inheritance with a YAML field name.

**Three Kubernetes-specific DAC failure modes:**

1. **`fsGroup` is ignored by most network filesystems.** NFS and CIFS CSI drivers cannot `chown` on the server (`root_squash`). `fsGroup` silently does nothing, the pod starts, and every write fails with `EACCES`. Ownership must be set server-side, and the ACL from §11.1 is what makes it work.
2. **`fsGroupChangePolicy: Always` on a large volume** recursively `chown`s every inode on every pod start. On a multi-million-inode PVC this adds minutes to startup and can push the pod past its liveness probe into a crash loop. `OnRootMismatch` is almost always what you want.
3. **`runAsUser` with a UID absent from the image's `/etc/passwd`** makes `getpwuid()` fail. Programs that call `os.UserHomeDir()`, `$HOME` expansion, or `getlogin()` break in confusing ways. Add the account to the image, or set `HOME` explicitly.

### 11.5 auditd — detecting DAC changes

DAC gives you no logging. auditd is where you get it.

```
# /etc/audit/rules.d/50-dac.rules
#
# Discretionary access control change detection.
# -F auid>=1000 -F auid!=unset limits to human-initiated changes; drop those
# two predicates to also catch daemons (higher volume, higher fidelity).

# --- Permission changes -----------------------------------------------------
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k dac_perm
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k dac_perm

# --- Ownership changes ------------------------------------------------------
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k dac_own
-a always,exit -F arch=b32 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=unset -k dac_own

# --- ACL, xattr and file-capability changes ---------------------------------
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k dac_xattr
-a always,exit -F arch=b32 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=unset -k dac_xattr

# --- Every use of a privileged set-id binary --------------------------------
-a always,exit -F path=/usr/bin/sudo   -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/su     -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid!=unset -k dac_privcmd
-a always,exit -F path=/usr/bin/newgrp -F perm=x -F auid!=unset -k dac_privcmd

# --- Attribute manipulation (chattr uses ioctl, not a dedicated syscall) ----
-a always,exit -F arch=b64 -S ioctl -F auid>=1000 -F auid!=unset -F dir=/etc -k dac_attr

# --- Unauthorised access attempts -------------------------------------------
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate,creat -F exit=-EACCES -F auid>=1000 -F auid!=unset -k dac_denied
-a always,exit -F arch=b64 -S open,openat,openat2,truncate,ftruncate,creat -F exit=-EPERM  -F auid>=1000 -F auid!=unset -k dac_denied

# --- Watch the identity database itself -------------------------------------
-w /etc/passwd  -p wa -k identity
-w /etc/shadow  -p wa -k identity
-w /etc/group   -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
-w /etc/sudoers.d/ -p wa -k identity

# --- Make the ruleset immutable until reboot. MUST be the last line. --------
-e 2
```

```
# augenrules --load
# auditctl -s
enabled 2
failure 1
pid 1184
rate_limit 0
backlog_limit 8192
lost 0
backlog 0
backlog_wait_time 60000
loginuid_immutable 1 locked

# ausearch -k dac_perm -ts today -i | tail -8
type=PROCTITLE msg=audit(08/24/2026 11:52:17.443:8812) : proctitle=chmod 777 /srv/deploy/published
type=PATH msg=audit(08/24/2026 11:52:17.443:8812) : item=0 name=/srv/deploy/published inode=1443301 dev=fd:00 mode=dir,sgid,750 ouid=release ogid=deployers rdev=00:00 nametype=NORMAL
type=CWD msg=audit(08/24/2026 11:52:17.443:8812) : cwd=/home/sre
type=SYSCALL msg=audit(08/24/2026 11:52:17.443:8812) : arch=x86_64 syscall=fchmodat success=yes exit=0 a0=0xffffff9c a1=0x7ffd2c1b3a41 a2=0x1ff a3=0x0 items=1 ppid=4412 pid=4419 auid=sre uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=41 comm=chmod exe=/usr/bin/chmod key=dac_perm
```

`a2=0x1ff` is `0777` — the exact mode requested, recoverable from the raw event. `auid=sre` survives `sudo`, which is why the accountable human is identifiable even though `uid=root`.

---

## 12. Verification and failure diagnosis

### 12.1 `namei` — always your first command

99% of "the file is 0644 but I get Permission denied" tickets are a missing `x` on a parent directory. `namei -mo` (`-m` mode, `-o` owner) resolves the entire path and prints every component:

```
$ sudo -u promtail namei -mo /srv/deploy/artifacts/build-4712/manifest.json
f: /srv/deploy/artifacts/build-4712/manifest.json
 drwxr-xr-x root  root      /
 drwxr-xr-x root  root      srv
 drwxr-x--- root  deploy    deploy         ← promtail is neither root nor in 'deploy'
 drwxrws--- root  deployers artifacts
 drwxrws--- ci    deployers build-4712
 -rw-rw---- ci    deployers manifest.json
```

The leaf is irrelevant. `promtail` cannot traverse `/srv/deploy`, so nothing below it is reachable. Grant `--x` on the intermediate directory (or a `u:promtail:--x` ACL entry) and the problem is gone.

`namei -l` gives a slightly different long format; `namei -x` marks the failing component. Both are in `util-linux` and present on every distribution.

### 12.2 Test as the actual principal — never as root

```
# The definitive test: run the check as the failing identity.
$ sudo -u promtail -- test -r /var/log/app/app.log && echo READABLE || echo DENIED
DENIED

# Batch-test a whole permission matrix.
$ for u in ci release promtail; do
    for op in "-r:read" "-w:write" "-x:exec"; do
      flag=${op%%:*}; name=${op##*:}
      if sudo -u "$u" -- test "$flag" /srv/deploy/artifacts; then r=ALLOW; else r=DENY; fi
      printf '%-10s %-6s %s\n' "$u" "$name" "$r"
    done
  done
ci         read   ALLOW
ci         write  ALLOW
ci         exec   ALLOW
release    read   ALLOW
release    write  ALLOW
release    exec   ALLOW
promtail   read   DENY
promtail   write  DENY
promtail   exec   DENY
```

Caveat: `test -r` uses `access(2)`, which checks against the **real** UID and, historically, honours `CAP_DAC_OVERRIDE` — so as root it reports success for everything. `sudo -u` fixes this by actually changing identity. This is also why `access(2)` must never be used for security decisions in application code (TOCTOU + real-vs-effective UID mismatch); the correct pattern is to `open()` and handle the error.

### 12.3 `strace` — the ground truth

When the application's error message is useless, the syscall is not:

```
$ sudo -u promtail strace -f -y -e trace=%file -o /tmp/pt.log promtail -config.file=/etc/promtail/config.yaml
$ grep -E 'EACCES|EPERM|ENOENT' /tmp/pt.log | head
openat(AT_FDCWD, "/var/log/app", O_RDONLY|O_CLOEXEC|O_DIRECTORY) = -1 EACCES (Permission denied)
```

`-y` prints the resolved path for every file descriptor, which turns opaque `read(7, ...)` lines into readable ones. `-e trace=%file` covers every syscall that takes a path argument.

### 12.4 Distinguishing a DAC denial from a MAC denial

Both surface as `EACCES`. The audit log tells them apart in one command:

```
# ausearch -m AVC -ts recent
<no matches>
```

No AVC → SELinux is not involved; the denial is DAC. Confirm the other way:

```
# ausearch -m AVC -ts recent | audit2why
type=AVC msg=audit(1756029841.117:9021): avc:  denied  { read } for  pid=5581 comm="promtail" name="app.log" dev="dm-0" ino=1443377 scontext=system_u:system_r:promtail_t:s0 tcontext=system_u:object_r:httpd_log_t:s0 tclass=file permissive=0

	Was caused by:
	Missing type enforcement (TE) allow rule.

	You can use audit2allow to generate a loadable module to allow this access.
```

Here the mode bits and ACL are correct and the denial is entirely SELinux — `chmod` would have been the wrong fix. Note also that a **wrong SELinux label** is the standard aftermath of §7.5's `sed -i` problem, and `restorecon -Rv PATH` is the fix.

The decisive test: if `setenforce 0` makes the problem disappear, it was MAC. Set it back immediately (`setenforce 1`) and fix the label or the policy — never leave a host permissive.

### 12.5 The complete diagnostic decision tree

```
"Permission denied"
│
├─ Is the errno EPERM (not EACCES)?  →  strace -e trace=%file
│    ├─ chattr -i / +a on the target?          →  lsattr FILE
│    ├─ Mount is read-only or nosuid?          →  findmnt -no OPTIONS --target FILE
│    ├─ Sticky directory, not the owner?       →  ls -ld DIR
│    ├─ NFS root_squash?                       →  findmnt -t nfs4; exportfs -v on the server
│    └─ Missing capability?                    →  grep CapEff /proc/PID/status; capsh --decode=...
│
├─ EACCES, and an AVC exists?  →  ausearch -m AVC -ts recent
│    └─ Fix the SELinux label or policy. restorecon -Rv PATH. NOT chmod.
│
└─ EACCES, no AVC → it is genuine DAC:
     │
     ├─ 1. Path traversal:      namei -mo /full/path
     │        Missing x on ANY component ⇒ everything below is unreachable.
     │
     ├─ 2. Identity:            id USER        (is the group actually present?)
     │        Group added but the process not restarted ⇒ stale credentials.
     │        Confirm with: grep Groups /proc/PID/status
     │
     ├─ 3. First-match-wins:    ls -l FILE
     │        Owner with '---' is denied even if other is 'rwx'. See 2.2.
     │
     ├─ 4. ACL present ('+')?   getfacl -e FILE
     │        Look for '#effective:' lines: the mask is clipping. See 7.4.
     │        Fix: setfacl -m m::rwx FILE   (NOT chmod)
     │
     ├─ 5. Filesystem support:  findmnt -no FSTYPE,OPTIONS --target FILE
     │        noacl / nouser_xattr / vfat ⇒ ACLs do not exist here.
     │
     └─ 6. Creation-time issue (files appear with the wrong mode):
              grep Umask /proc/PID/status        ← the truth
              getfacl DIR | grep '^default:'     ← overrides umask entirely
              ls -ld DIR                          ← setgid for group inheritance
```

### 12.6 A reusable audit script

```bash
#!/usr/bin/env bash
# /usr/local/sbin/dac-audit — report the effective DAC posture of a path tree.
# Exits non-zero if any world-writable non-sticky object or masked ACL is found.
set -euo pipefail

TARGET="${1:?usage: dac-audit PATH}"
rc=0

printf '=== Mount and filesystem capability ===\n'
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS --target "$TARGET"
if findmnt -no OPTIONS --target "$TARGET" | grep -qE '\bnoacl\b|\bnouser_xattr\b'; then
    printf 'WARN: ACLs or user xattrs are DISABLED on this mount.\n'
    rc=1
fi

printf '\n=== World-writable objects without the sticky bit ===\n'
if find "$TARGET" -xdev \( -type f -o -type d \) -perm -0002 \
        ! \( -type d -perm -1000 \) -printf '%M %u:%g %p\n' | grep . ; then
    rc=1
else
    printf 'none\n'
fi

printf '\n=== set-uid / set-gid files ===\n'
find "$TARGET" -xdev -type f \( -perm -4000 -o -perm -2000 \) \
     -printf '%M %u:%g %p\n' | sort || printf 'none\n'

printf '\n=== File capabilities (invisible to ls -l) ===\n'
getcap -r "$TARGET" 2>/dev/null || printf 'none\n'

printf '\n=== Unowned objects (orphaned uid/gid) ===\n'
find "$TARGET" -xdev \( -nouser -o -nogroup \) -printf '%M %U:%G %p\n' || printf 'none\n'

printf '\n=== ACL entries neutralised by the mask ===\n'
if find "$TARGET" -xdev -exec getfacl -c -e --skip-base {} + 2>/dev/null \
     | awk '/^# file:/{f=$3} /#effective:/{print f": "$0; found=1} END{exit !found}'; then
    printf 'ABOVE ENTRIES ARE INEFFECTIVE — a chmod has clipped the mask.\n'
    rc=1
else
    printf 'none\n'
fi

printf '\n=== Immutable / append-only objects ===\n'
find "$TARGET" -xdev -type f -exec lsattr {} + 2>/dev/null \
  | grep -E '^[^ ]*[ia]' || printf 'none\n'

printf '\n=== Directories missing the sticky bit but group/world writable ===\n'
find "$TARGET" -xdev -type d -perm -0020 ! -perm -1000 \
     -printf '%M %u:%g %p\n' || printf 'none\n'

exit "$rc"
```

```
# /usr/local/sbin/dac-audit /srv/deploy
=== Mount and filesystem capability ===
SOURCE              TARGET FSTYPE OPTIONS
/dev/mapper/vg0-srv /srv   ext4   rw,nosuid,nodev,relatime,seclabel

=== World-writable objects without the sticky bit ===
none

=== set-uid / set-gid files ===
none

=== File capabilities (invisible to ls -l) ===
none

=== Unowned objects (orphaned uid/gid) ===
none

=== ACL entries neutralised by the mask ===
/srv/deploy/published/manifest-4701.json: user:sec-audit:r--		#effective:---
ABOVE ENTRIES ARE INEFFECTIVE — a chmod has clipped the mask.

=== Immutable / append-only objects ===
none

=== Directories missing the sticky bit but group/world writable ===
none

# echo $?
1
```

---

## 13. Hardening sweeps

Two searches, both mandatory, because neither one finds what the other finds.

```
# --- Every set-id binary on local filesystems ---
# -xdev keeps the scan off NFS/procfs/sysfs and out of a 40-minute stall.
# -perm -4000 means "these bits at minimum"; -perm /4000 means "any of these".
# ! -type l excludes symlinks, whose modes are meaningless.
# -exec ... + batches rather than forking per file.
# find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec ls -lb {} +

# find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '%M %u %g %p\n' | sort -k4
-rwsr-xr-x root root /usr/bin/chage
-rwsr-xr-x root root /usr/bin/chfn
-rwsr-xr-x root root /usr/bin/chsh
-rwxr-sr-x root tty  /usr/bin/wall
-rwsr-xr-x root root /usr/bin/gpasswd
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/newgrp
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/umount
-rwxr-sr-x root shadow /usr/sbin/unix_chkpwd

# --- Every file capability. NOT covered by the search above. ---
# find / -xdev -type f -exec getcap {} + 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep

# --- World-writable objects that are not sticky directories ---
# find / -xdev \( -type f -o -type d \) -perm -0002 ! \( -type d -perm -1000 \) -ls
(no output — good)

# --- Files with no valid owner (a uid/gid removed while files remained) ---
# find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %p\n'
(no output — good)

# --- Home directories readable by the world ---
# find /home -maxdepth 1 -type d -perm /0007 -printf '%M %u %p\n'

# --- Filesystems that should never carry set-id binaries or devices ---
# findmnt -no TARGET,OPTIONS /tmp /var/tmp /dev/shm /home
/tmp     rw,nosuid,nodev,noexec,relatime
/var/tmp rw,nosuid,nodev,noexec,relatime
/dev/shm rw,nosuid,nodev,noexec,relatime
/home    rw,nosuid,nodev,relatime
```

The corresponding `/etc/fstab` — `nosuid,nodev` on every filesystem that holds user-controlled data is the cheapest and most durable mitigation for the entire setuid attack class:

```
# /etc/fstab
# <device>                <mount>   <fs>  <options>                                     <dump> <pass>
UUID=8f2a...              /         ext4  defaults                                       0 1
UUID=b71c...              /srv      ext4  defaults,nosuid,nodev,acl                      0 2
UUID=c93d...              /home     ext4  defaults,nosuid,nodev,acl                      0 2
UUID=d15e...              /var      ext4  defaults,nosuid,nodev                          0 2
UUID=e02f...              /var/log  ext4  defaults,nosuid,nodev,noexec                   0 2
UUID=f338...              /var/tmp  ext4  defaults,nosuid,nodev,noexec                   0 2
tmpfs                     /tmp      tmpfs defaults,nosuid,nodev,noexec,mode=1777,size=4G 0 0
tmpfs                     /dev/shm  tmpfs defaults,nosuid,nodev,noexec,size=2G           0 0
```

Note `mode=1777` on the `/tmp` tmpfs — the sticky bit is a mount option there, not something you `chmod` after the fact (a `chmod` would be lost at the next boot).

---

## 14. Exam traps and production traps that overlap

1. **First match wins.** Owner `---` denies the owner regardless of group and other bits. Permissions do not accumulate across classes.
2. **`w` on a directory permits deleting files you cannot read.** File permissions are irrelevant to `unlink()`; only the directory's `w`+`x` and the sticky bit matter.
3. **`x` is required on every path component.** A `0644` file inside a `0700` directory is unreachable.
4. **Setuid is ignored on shell scripts and on directories on Linux.**
5. **Setgid on a directory controls the *group*, not the *mode*.** The mode still comes from the creator's umask — unless a default ACL exists.
6. **A default ACL makes the umask irrelevant.** This is the single most exam-worthy interaction in the topic.
7. **The group triad in `ls -l` is the ACL mask when a `+` is present.** `chmod g-w` therefore clips every named entry.
8. **`chown` clears setuid and setgid**, for root too, since Linux 2.2.13. Always `chown` before `chmod`.
9. **`EACCES` ≠ `EPERM`.** `chmod` never fixes `EPERM`.
10. **Root cannot execute a file with mode `000`** — the one hole in `CAP_DAC_OVERRIDE`.
11. **`chattr +i` blocks root** and is enforced before the DAC check; only `CAP_LINUX_IMMUTABLE` can clear it.
12. **`trusted.*` extended attributes are invisible** to any process without `CAP_SYS_ADMIN` — including the file's owner.
13. **`getfattr` defaults to `-m '^user\.'`.** Without `-m -` you will not see ACLs, SELinux labels, or capabilities.
14. **`rsync -a` does not copy ACLs or xattrs.** You need `-aAX`. `tar` needs `--acls --xattrs`. `cp -a` does copy them.
15. **`sed -i` and most editors replace the inode**, destroying ACLs, xattrs and SELinux labels.
16. **`chmod -R 755` marks every data file executable.** Use `chmod -R u=rwX,g=rX,o=`.
17. **File capabilities are invisible to `ls -l`.** A `find -perm -4000` sweep alone is an incomplete audit.
18. **`umask` in `/etc/profile` does not affect systemd services.** Use `UMask=` in the unit; verify in `/proc/PID/status`.
19. **Symlink permissions (`lrwxrwxrwx`) are always meaningless on Linux.** There is no `lchmod(2)`.
20. **The sticky bit on a file does nothing on Linux.** Only on directories.

---

## 15. References

**LPI official**

- LPIC-3 Exam 303 (303-300) objectives — https://www.lpi.org/our-certifications/exam-303-objectives/
- LPIC-3 Security certification overview — https://www.lpi.org/our-certifications/lpic-3-security-overview/

**Kernel and POSIX interfaces (man-pages project)**

- `acl(5)` — POSIX ACL model, mask semantics, default ACLs and umask interaction — https://man7.org/linux/man-pages/man5/acl.5.html
- `xattr(7)` — extended attribute namespaces and their access rules — https://man7.org/linux/man-pages/man7/xattr.7.html
- `capabilities(7)` — `CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_FSETID`, `CAP_LINUX_IMMUTABLE`, file capabilities — https://man7.org/linux/man-pages/man7/capabilities.7.html
- `path_resolution(7)` — why `x` on every path component is required — https://man7.org/linux/man-pages/man7/path_resolution.7.html
- `inode(7)` — `st_mode` layout and file-type bits — https://man7.org/linux/man-pages/man7/inode.7.html
- `chmod(2)` — set-id clearing rules and `CAP_FSETID` — https://man7.org/linux/man-pages/man2/chmod.2.html
- `chown(2)` — set-id clearing on ownership change — https://man7.org/linux/man-pages/man2/chown.2.html
- `umask(2)` — https://man7.org/linux/man-pages/man2/umask.2.html
- `open(2)` — mode argument, `O_TMPFILE`, `O_NOFOLLOW` — https://man7.org/linux/man-pages/man2/open.2.html
- `access(2)` — real-vs-effective UID and the TOCTOU warning — https://man7.org/linux/man-pages/man2/access.2.html
- `setfacl(1)` — https://man7.org/linux/man-pages/man1/setfacl.1.html
- `getfacl(1)` — https://man7.org/linux/man-pages/man1/getfacl.1.html
- `setfattr(1)` — https://man7.org/linux/man-pages/man1/setfattr.1.html
- `getfattr(1)` — https://man7.org/linux/man-pages/man1/getfattr.1.html
- `chattr(1)` — https://man7.org/linux/man-pages/man1/chattr.1.html
- `lsattr(1)` — https://man7.org/linux/man-pages/man1/lsattr.1.html
- `setcap(8)` / `getcap(8)` — https://man7.org/linux/man-pages/man8/setcap.8.html
- `namei(1)` — https://man7.org/linux/man-pages/man1/namei.1.html

**Kernel documentation**

- Filesystem-level protection sysctls (`fs.protected_symlinks`, `protected_hardlinks`, `protected_fifos`, `protected_regular`) — https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- ext4 filesystem documentation, including xattr and ACL storage — https://www.kernel.org/doc/html/latest/filesystems/ext4/
- Idmapped mounts — https://www.kernel.org/doc/html/latest/filesystems/idmappings.html
- overlayfs and `trusted.overlay.*` — https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html
- `no_new_privs` — https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html

**Filesystem projects**

- XFS documentation — https://xfs.wiki.kernel.org/
- Btrfs — filesystem features and attributes — https://btrfs.readthedocs.io/en/latest/
- OpenZFS `acltype`, `aclmode`, `aclinherit` properties — https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html

**systemd**

- `tmpfiles.d(5)` — declarative modes, ACLs and file attributes — https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- `systemd.exec(5)` — `UMask=`, `StateDirectory=`, `NoNewPrivileges=`, `RestrictSUIDSGID=` — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-analyze(1)` — the `security` verb — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html

**Kubernetes**

- Configure a Security Context for a Pod or Container (`runAsUser`, `fsGroup`, `fsGroupChangePolicy`, `supplementalGroups`) — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/

**Standards, benchmarks and tooling**

- Ansible `ansible.posix.acl` module — https://docs.ansible.com/ansible/latest/collections/ansible/posix/acl_module.html
- Ansible `ansible.builtin.file` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html
- `auditd` / `audit.rules(7)` — https://man7.org/linux/man-pages/man7/audit.rules.7.html
- CIS Benchmarks (Linux filesystem permission controls) — https://www.cisecurity.org/cis-benchmarks
- NIST SP 800-53 Rev. 5, AC-3 Access Enforcement — https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final
- `acl` and `attr` upstream (Linux ACL/xattr userspace) — https://savannah.nongnu.org/projects/acl/
- RFC 8881 — NFS version 4 minor version 1, §6 (ACLs) — https://www.rfc-editor.org/rfc/rfc8881.html