# LPIC-1 · 104.5 — Manage file permissions and ownership

**Exam:** 101-500 / 102-500 (v5.0) · **Objective 104.5** · **Weight: 4.69**
**Key commands:** `chmod`, `umask`, `chown`, `chgrp`
**Adjacent, exam-relevant:** `stat`, `namei`, `find -perm`, `install`, `getfacl`/`setfacl`, `getcap`

---

## 1. The production problem: the mode word is the last enforcement boundary

Every access decision a Linux kernel makes about a file ends at 16 bits stored in the inode: `st_mode`. Filesystem ACLs, capabilities, LSMs (SELinux/AppArmor), namespaces and mount options all layer around it, but none of them *replace* it — they only add further denials or narrow exemptions. If those 16 bits are wrong, every layer above is decoration.

Three failure archetypes drive most real incidents:

**Archetype A — the recursive widening.** An operator debugging a 403 runs `chmod -R 777 /srv/app`. The application starts. Three weeks later an auditor finds that `/srv/app/config/db.yaml` is world-readable, and that every directory under `/srv/app` lost its sticky bit and gained world-write, so any local process can replace any file with a symlink. The fix is not "put it back": the correct modes were never recorded anywhere, and package-managed files have to be recovered with `rpm -Va` / `dpkg --verify`.

**Archetype B — the collaboration drift.** A shared directory `/srv/data/reports` is owned by group `data`. Two service accounts write to it. Because each process runs with `umask 022` and the directory is not setgid, every file lands as `user:user 0644`. The second service can read but not overwrite. The pipeline half-works — the worst failure mode, because it is intermittent and depends on which node produced the file.

**Archetype C — the privilege island.** A container image is built as root, `COPY`ed files land as `root:root 0644`, and the runtime enforces `runAsNonRoot: true` with `runAsUser: 10001`. The container starts, then dies on the first write with `EACCES`. In Kubernetes the symptom is `CrashLoopBackOff` with a one-line stack trace and no obvious owner.

All three are the same engineering failure: **permissions were treated as a runtime fix rather than as declared, version-controlled state**. The rest of this material treats the mode word as infrastructure — declared in tmpfiles.d, systemd units, Ansible, Dockerfiles and pod securityContexts, then verified.

---

## 2. The mode word: exactly what is stored

`st_mode` is a 16-bit field. The low 12 bits are the permission and special bits; the high 4 encode the file type (`S_IFMT`), which is **not** settable by `chmod`.

```
 bit:  15 14 13 12 | 11 10  9 |  8  7  6 |  5  4  3 |  2  1  0
       [ file type]| su sg vtx| r  w  x  | r  w  x  | r  w  x
                   |  special |   owner  |   group  |  other
octal:             |    4 2 1 |  4 2 1   |  4 2 1   |  4 2 1
```

| Symbol | Octal | C macro | Meaning on a **regular file** | Meaning on a **directory** |
|---|---|---|---|---|
| `s` (user) | `4000` | `S_ISUID` | Execute with the file owner's EUID | **Ignored on Linux** |
| `s` (group) | `2000` | `S_ISGID` | Execute with the file group's EGID; if `g-x`, historically flagged mandatory locking | New entries inherit the directory's GID; new subdirs inherit the bit |
| `t` | `1000` | `S_ISVTX` | Ignored on Linux (historically "save text image") | **Restricted deletion**: only the file owner, the dir owner, or `CAP_FOWNER` may unlink/rename |
| `r` | `400/40/4` | `S_IRUSR`… | Read file contents | `readdir()` — list entry *names* only |
| `w` | `200/20/2` | `S_IWUSR`… | Modify contents | Create / delete / rename entries (**requires `x` as well**) |
| `x` | `100/10/1` | `S_IXUSR`… | `execve()` the file | **Search/traverse**: resolve this component of a path, `stat()` a known name |

### 2.1 The `r` vs `x` asymmetry on directories — memorise this

This is the single most tested and most misunderstood pair in the objective.

```console
$ sudo install -d -m 0444 -o root -g root /tmp/r-only
$ sudo touch /tmp/r-only/secret.txt
$ ls /tmp/r-only
secret.txt
$ ls -l /tmp/r-only
ls: cannot access '/tmp/r-only/secret.txt': Permission denied
total 0
-????????? ? ? ? ?            ? secret.txt
$ cat /tmp/r-only/secret.txt
cat: /tmp/r-only/secret.txt: Permission denied
```

`r` without `x` gives you the *catalogue* but not the *shelf*. The reverse is far more useful in production:

```console
$ sudo install -d -m 0711 -o root -g root /tmp/x-only
$ sudo install -m 0644 /dev/null /tmp/x-only/known.txt
$ ls /tmp/x-only
ls: cannot open directory '/tmp/x-only': Permission denied
$ cat /tmp/x-only/known.txt        # works: name is known, traversal permitted
$ stat -c '%a %n' /tmp/x-only/known.txt
644 /tmp/x-only/known.txt
```

Mode `0711` on a directory is the classic **"you may enter if you know the name"** pattern — it is why `/home` is `0755` but well-hardened `/home/<user>` is `0700`, and why web-server document roots that must not be listable are `0711` rather than `0755`.

| Directory mode | `readdir` | Traverse | Create/delete | Typical production use |
|---|---|---|---|---|
| `0700` | owner | owner | owner | Private state (`/run/<svc>`, `~/.ssh`) |
| `0711` | owner only | everyone | owner | Non-listable drop point, `/home/<user>` on shared hosts |
| `0750` | owner+group | owner+group | owner | Service data readable by an ops group |
| `2770` | owner+group | owner+group | owner+group | Shared collaboration dir (setgid) |
| `0755` | everyone | everyone | owner | Public read paths (`/usr`, `/srv/www`) |
| `1777` | everyone | everyone | everyone (sticky) | `/tmp`, `/var/tmp`, `/dev/shm` — **only** with sticky |
| `0777` | everyone | everyone | everyone | Never. Always a bug. |

---

## 3. The access-check algorithm: first match wins, no fallthrough

The kernel's `generic_permission()` evaluates in a fixed order and **stops at the first class that matches**:

1. If `fsuid == inode.i_uid` → use the **owner** triad. Done.
2. Else if the inode's GID is the process's fsgid or in its supplementary groups → use the **group** triad. Done.
3. Else → use the **other** triad.

There is no "accumulate the best of all three". This produces the canonical paradox:

```console
$ sudo install -o alice -g devs -m 0407 /dev/null /tmp/paradox
$ ls -l /tmp/paradox
-r-----rwx 1 alice devs 0 Aug 26 09:20 /tmp/paradox

$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ sudo -u alice bash -c 'echo x >> /tmp/paradox'
bash: line 1: /tmp/paradox: Permission denied

$ id bob
uid=1002(bob) gid=1002(bob) groups=1002(bob)
$ sudo -u bob bash -c 'echo x >> /tmp/paradox'   # succeeds — bob falls to "other"
$ cat /tmp/paradox
x
```

The owner is the **most** restricted party. Any audit rule that flags "world-writable" must therefore also flag "other more permissive than group or owner" — the second is rarer and worse, because it inverts the intent.

### 3.1 Root exemptions are capabilities, not magic

| Capability | What it bypasses |
|---|---|
| `CAP_DAC_OVERRIDE` | All read/write/search checks. For `execve()` on a regular file it still requires **at least one** `x` bit to be set. |
| `CAP_DAC_READ_SEARCH` | Read and directory-search checks only (no write). |
| `CAP_FOWNER` | Checks normally requiring `fsuid == i_uid`: `chmod`, `utime`, sticky-bit deletion. |
| `CAP_CHOWN` | Arbitrary `chown()` to any UID/GID. |
| `CAP_FSETID` | Prevents automatic clearing of setuid/setgid on write and on `chmod` to a foreign group. |

```console
$ sudo install -m 0000 -o root /dev/null /tmp/nomode
$ sudo cat /tmp/nomode        # fine: CAP_DAC_OVERRIDE
$ sudo /tmp/nomode
sudo: /tmp/nomode: command not found
$ sudo chmod 0100 /tmp/nomode && sudo /tmp/nomode; echo "exit=$?"
exit=0                        # one x bit is enough for root
```

In a container with `capabilities: drop: ["ALL"]`, UID 0 is **not** exempt from anything. This is why "the image runs as root so permissions don't matter" is false on any modern platform.

---

## 4. `chmod` — symbolic vs octal, and the recursion trap

### 4.1 Two grammars, different guarantees

```
chmod [OPTION]... MODE[,MODE]... FILE...
chmod [OPTION]... OCTAL-MODE FILE...
chmod [OPTION]... --reference=RFILE FILE...

MODE := [ugoa...][[-+=][perms...]...]
perms := r w x X s t   |   u g o
```

| Aspect | Octal (`chmod 2750`) | Symbolic (`chmod g+rwX,o-rwx`) |
|---|---|---|
| Semantics | **Absolute** — sets all 12 bits | **Relative** — modifies only named bits (`=` is absolute per-class) |
| Special bits | Must be stated or they are **cleared** (3-digit `750` clears setuid/setgid/sticky) | Untouched unless named |
| `umask` interaction | None — `chmod` never consults the umask | None, **except** a bare `+x`/`+w` with no class, which *is* umask-filtered |
| Idempotent / declarative | Yes — safe in config management | No — outcome depends on prior state |
| Recursion safety | Dangerous: same mode for files and dirs | Safe with `X`: `chmod -R a+rX` |
| Readability in review | High for standard patterns (`0640`, `2770`, `1777`) | High for intent-expressing deltas |

**Rule of thumb:** declare with octal (Ansible, tmpfiles.d, `install -m`); repair with symbolic (`+X`, `-s`, `+t`).

The bare-`+x` umask interaction surprises people:

```console
$ umask
0022
$ install -m 0600 /dev/null /tmp/u1 && chmod +x /tmp/u1 && stat -c %a /tmp/u1
711
$ install -m 0600 /dev/null /tmp/u2 && chmod a+x /tmp/u2 && stat -c %a /tmp/u2
711
$ install -m 0600 /dev/null /tmp/u3 && chmod ugo+x /tmp/u3 && stat -c %a /tmp/u3
711
```

With no class letter, `+x` means "`a+x` filtered by the umask" per POSIX — with `umask 022` it still yields all three here because `chmod` applies the *complement*; change the umask and the result changes:

```console
$ (umask 077; install -m 0600 /dev/null /tmp/u4; chmod +x /tmp/u4; stat -c %a /tmp/u4)
700
```

Always write the class explicitly (`u+x`, `a+x`) in scripts.

### 4.2 `X` — the only safe recursive execute

`X` sets `x` **only** if the target is a directory, or if any execute bit is already set on a regular file.

```console
$ sudo install -d -m 0700 /tmp/tree/bin && sudo install -m 0755 /bin/true /tmp/tree/bin/tool \
    && sudo install -m 0600 /dev/null /tmp/tree/bin/config.ini
$ sudo chmod -R 0755 /tmp/tree            # WRONG
$ find /tmp/tree -printf '%M %p\n'
drwxr-xr-x /tmp/tree
drwxr-xr-x /tmp/tree/bin
-rwxr-xr-x /tmp/tree/bin/tool
-rwxr-xr-x /tmp/tree/bin/config.ini       <-- config is now executable and world-readable

$ sudo chmod -R u=rwX,g=rX,o= /tmp/tree   # RIGHT
$ find /tmp/tree -printf '%M %p\n'
drwxr-x--- /tmp/tree
drwxr-x--- /tmp/tree/bin
-rwxr-x--- /tmp/tree/bin/tool
-rw-r----- /tmp/tree/bin/config.ini
```

The `find`-based equivalent, for when you need different absolute modes:

```console
$ sudo find /srv/app -type d -exec chmod 2750 {} +
$ sudo find /srv/app -type f -exec chmod 0640 {} +
$ sudo find /srv/app -type f -name '*.sh' -exec chmod 0750 {} +
```

`-exec ... +` batches arguments (one `chmod` per ~2000 paths) instead of one process per file — on a 400k-file tree this is the difference between 6 seconds and 20 minutes.

### 4.3 `chmod` never follows to a symlink's own mode

Symlink modes are `lrwxrwxrwx` on Linux and are not used in any access decision. `chmod` has no `-h`; it always dereferences.

```console
$ ln -s /etc/hostname /tmp/link
$ ls -l /tmp/link
lrwxrwxrwx 1 alice alice 13 Aug 26 10:02 /tmp/link -> /etc/hostname
$ chmod 600 /tmp/link
chmod: changing permissions of '/tmp/link': Operation not permitted   # target is root-owned
```

For a recursive `chmod -R` over a tree containing symlinks, GNU `chmod` skips symlinks encountered during the walk but **follows** ones named on the command line — the source of accidental `chmod` on `/etc` via a stray link.

### 4.4 Useful flags

```console
$ chmod -c 0640 /srv/data/reports/q3.csv
mode of '/srv/data/reports/q3.csv' changed from 0644 (rw-r--r--) to 0640 (rw-r-----)

$ chmod -v 0640 /srv/data/reports/q3.csv
mode of '/srv/data/reports/q3.csv' retained as 0640 (rw-r-----)

$ chmod --reference=/etc/shadow /srv/secrets/token
$ stat -c '%A %a' /srv/secrets/token
-rw-r----- 640
```

`-c` (changes only) is the right verbosity for automation: silent when converged, loud when it drifted.

---

## 5. `chown` / `chgrp` — ownership and its silent side effects

### 5.1 Syntax surface

```
chown [OPTION]... [OWNER][:[GROUP]] FILE...
chown [OPTION]... --reference=RFILE FILE...
chgrp [OPTION]... GROUP FILE...
```

| Form | Effect |
|---|---|
| `chown alice file` | UID only; GID untouched |
| `chown alice:devs file` | UID and GID |
| `chown alice: file` | UID, and GID set to **alice's login group** |
| `chown :devs file` | GID only — identical to `chgrp devs file` |
| `chown alice.devs file` | Legacy SysV separator; ambiguous when usernames contain `.` — avoid |
| `chown 1001:1500 file` | Numeric — required when the name does not resolve (containers, NFS, rescue) |
| `chown --from=root:root alice:devs file` | Conditional: change only if it currently matches |
| `chown -h alice link` | Change the **symlink itself** (`lchown`), not the target |
| `chown -R -h ...` | Recursive, not dereferencing symlinks |
| `chown -R -L ...` | Recursive, **following** symlinked directories — dangerous |

```console
$ sudo chown -c --from=root:root svc-etl:data /srv/data/reports/q3.csv
changed ownership of '/srv/data/reports/q3.csv' from root:root to svc-etl:data
$ sudo chown -c --from=root:root svc-etl:data /srv/data/reports/q3.csv
$                                     # no output: already converged
```

### 5.2 Who may chown

An unprivileged user may **never give a file away** (no `chown` to another UID — Linux has no `_POSIX_CHOWN_RESTRICTED` off switch). A user *may* `chgrp` a file they own to any group they are a member of:

```console
$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ touch /tmp/mine
$ chgrp devs /tmp/mine ; echo "exit=$?"
exit=0
$ chgrp ops /tmp/mine
chgrp: changing group of '/tmp/mine': Operation not permitted
$ chown bob /tmp/mine
chown: changing ownership of '/tmp/mine': Operation not permitted
```

### 5.3 The two silent-clearing rules (high-yield, frequently missed)

**Rule 1 — `chown`/`chgrp` clears setuid and setgid.** Since Linux 2.2.13 this applies to root as well:

```console
$ sudo install -m 4755 -o root -g root /bin/true /tmp/probe
$ stat -c '%a %A %U:%G' /tmp/probe
4755 -rwsr-xr-x root:root
$ sudo chown alice /tmp/probe
$ stat -c '%a %A %U:%G' /tmp/probe
755 -rwxr-xr-x alice:root
```

**Consequence:** in any provisioning script, `chown` must come **before** `chmod`, never after. Reversing the order silently produces a non-setuid binary and a service that fails only under load, when the privileged path is first exercised.

```bash
# WRONG — chown wipes the bits chmod just set
chmod 4755 /usr/local/bin/helper
chown root:root /usr/local/bin/helper

# RIGHT
chown root:root /usr/local/bin/helper
chmod 4755 /usr/local/bin/helper

# BEST — atomic, single syscall sequence, no window
install -o root -g root -m 4755 helper /usr/local/bin/helper
```

**Rule 2 — writing to a file clears setuid, and clears setgid when `g+x` is set.** (`should_remove_suid()` in the VFS; skipped for `CAP_FSETID`.)

```console
$ install -m 6777 /bin/true /tmp/probe2        # owned by alice
$ stat -c '%a %A' /tmp/probe2
6777 -rwsrwsrwx
$ dd if=/dev/zero of=/tmp/probe2 bs=1 count=1 seek=0 conv=notrunc status=none
$ stat -c '%a %A' /tmp/probe2
777 -rwxrwxrwx
```

**Rule 3 — `chmod g+s` on a foreign-group file fails *silently*.** Without `CAP_FSETID`, the kernel masks `S_ISGID` out of the requested mode and returns success:

```console
$ sudo install -o alice -g ops -m 0644 /dev/null /tmp/silent
$ sudo -u alice chmod g+s /tmp/silent ; echo "exit=$?"
exit=0
$ stat -c '%a' /tmp/silent
644
```

Exit status 0 is not proof the mode was applied. **Always re-`stat` after a privileged mode change in automation.**

### 5.4 Ownership across copy tools

| Tool | Mode | Owner/Group | setuid/setgid | ACLs | xattrs |
|---|---|---|---|---|---|
| `cp src dst` | umask-filtered `0666`/`0777` | copier | dropped | no | no |
| `cp -p` / `cp --preserve=mode,ownership,timestamps` | preserved | preserved **only if privileged** | preserved if privileged | no | no |
| `cp -a` (`-dR --preserve=all`) | preserved | preserved if privileged | preserved if privileged | yes | yes |
| `mv` (same filesystem) | unchanged — it is a `rename()` | unchanged | unchanged | unchanged | unchanged |
| `mv` (cross-filesystem) | behaves like `cp -p` + `unlink` | best effort | best effort | best effort | best effort |
| `install -m -o -g` | explicit | explicit | explicit | no | no |
| `tar -x` | umask-filtered unless `-p` | `--same-owner` (default for root) | with `-p` | `--acls` | `--xattrs` |
| `rsync -a` | `-p` preserved | `-o -g`, root only | preserved | `-A` | `-X` |

```console
$ sudo rsync -aAX --numeric-ids --chown=svc-etl:data /stage/reports/ /srv/data/reports/
$ sudo tar --acls --xattrs --same-owner -xpf backup.tar -C /srv
```

`--numeric-ids` is mandatory when source and destination do not share `/etc/passwd` — otherwise rsync remaps by name and quietly reassigns files to whatever UID happens to hold that name on the target.

---

## 6. Special bits in production

### 6.1 setuid — the audit surface you must minimise

```console
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68208 Mar 23  2025 /usr/bin/passwd
$ stat -c '%a %A %U:%G %n' /usr/bin/passwd
4755 -rwsr-xr-x root:root /usr/bin/passwd
```

Enumerate the entire setuid/setgid surface of a host — this belongs in your baseline:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %u:%g %10s %p\n' 2>/dev/null | sort -k4
-rwsr-xr-x root:root      55744 /usr/bin/chfn
-rwsr-xr-x root:root      44808 /usr/bin/chsh
-rwsr-xr-x root:root      88304 /usr/bin/gpasswd
-rwsr-xr-x root:root      72704 /usr/bin/mount
-rwsr-xr-x root:root      68208 /usr/bin/newgrp
-rwsr-xr-x root:root      68208 /usr/bin/passwd
-rwsr-xr-x root:root      52880 /usr/bin/su
-rwsr-xr-x root:root     277936 /usr/bin/sudo
-rwsr-xr-x root:root      52880 /usr/bin/umount
-rwxr-sr-x root:shadow    35200 /usr/bin/expiry
-rwxr-sr-x root:crontab   43568 /usr/bin/crontab
-rwxr-sr-x root:tty       35112 /usr/bin/wall
-rwxr-sr-x root:shadow    31376 /usr/sbin/unix_chkpwd
```

Store it and diff it on every boot:

```console
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u:%g %p\n' \
      2>/dev/null | sort > /var/lib/baseline/setuid.txt
$ diff <(sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %u:%g %p\n' 2>/dev/null | sort) /var/lib/baseline/setuid.txt
> -rwsr-xr-x root:root /usr/local/bin/backup-helper
```

**setuid is ignored on interpreted scripts.** The kernel refuses to honour it on `#!` files, because of the unwinnable race between opening the script and the interpreter re-opening it:

```console
$ printf '#!/bin/bash\nid -u\n' | sudo tee /tmp/who.sh >/dev/null
$ sudo chown root:root /tmp/who.sh && sudo chmod 4755 /tmp/who.sh
$ ls -l /tmp/who.sh
-rwsr-xr-x 1 root root 21 Aug 26 10:40 /tmp/who.sh
$ /tmp/who.sh
1001
```

The correct modern replacement for narrow-privilege binaries is **file capabilities**, not setuid:

```console
$ getcap /usr/bin/ping
/usr/bin/ping cap_net_raw=ep
$ ls -l /usr/bin/ping
-rwxr-xr-x 1 root root 76040 Mar 23  2025 /usr/bin/ping
$ sudo setcap cap_net_bind_service=+ep /usr/local/bin/edge-proxy
$ getcap /usr/local/bin/edge-proxy
/usr/local/bin/edge-proxy cap_net_bind_service=ep
```

| Mechanism | Privilege granted | Blast radius on compromise | Survives `cp` | Survives `chown` |
|---|---|---|---|---|
| setuid root | Full UID 0 | Entire host | No | No (cleared) |
| setgid to a service group | That group's file access | Files owned by that group | No | No (cleared) |
| File capability | One capability | That capability only | No (xattr lost) | Yes (xattr independent) |
| `sudo` rule | Whatever the rule allows | Audited, centrally declared | n/a | n/a |
| systemd `AmbientCapabilities=` | One capability, no on-disk marker | That capability, service-scoped | n/a | n/a |

### 6.2 setgid on directories — the group-collaboration primitive

Without setgid, a new file's group is the **process's effective GID**. With setgid, it is the **parent directory's GID**, and new subdirectories inherit the setgid bit itself.

```console
$ sudo groupadd -g 1500 devs 2>/dev/null; sudo usermod -aG devs alice; sudo usermod -aG devs carol
$ sudo install -d -o root -g devs -m 2770 /srv/build
$ ls -ld /srv/build
drwxrws--- 2 root devs 4096 Aug 26 10:55 /srv/build

$ sudo -u alice bash -c 'touch /srv/build/artifact.tar; mkdir /srv/build/stage'
$ find /srv/build -printf '%M %u:%g %p\n'
drwxrws--- root:devs /srv/build
-rw-r--r-- alice:devs /srv/build/artifact.tar
drwxr-sr-x alice:devs /srv/build/stage
```

The group is right, but the **mode** is still `0644`/`0755` because the umask is `022`. `carol` can read but cannot overwrite. setgid fixes *ownership inheritance*; it does not fix *permission inheritance*. That is the umask's job:

```console
$ sudo -u alice bash -c 'umask 007; touch /srv/build/artifact2.tar; mkdir /srv/build/stage2'
$ find /srv/build -newer /srv/build/artifact.tar -printf '%M %u:%g %p\n'
-rw-rw---- alice:devs /srv/build/artifact2.tar
drwxrws--- alice:devs /srv/build/stage2
```

Now `carol` can overwrite. **setgid + umask 007/002 is the complete shared-directory recipe.**

Three ways to get group inheritance, compared:

| Mechanism | Scope | Controls mode? | Persists across `mv`? | Failure mode |
|---|---|---|---|---|
| `chmod g+s <dir>` (setgid) | Per directory subtree | No — umask still governs | Bit is on the dir, so yes for new files | Silent: bit dropped by a later 3-digit `chmod 770` |
| Default POSIX ACL (`setfacl -d`) | Per directory subtree | **Yes** — and it **overrides the umask** | Yes | ACL-unaware tools (`cp` without `-a`, `tar` without `--acls`) drop it |
| `mount -o grpid` (`bsdgroups`) | Whole filesystem | No | Yes | Surprises anyone who assumes Linux defaults; must be in `/etc/fstab` |

Default ACLs are the strongest form because they defeat the umask entirely:

```console
$ sudo setfacl -d -m u::rwx -m g::rwx -m o::--- /srv/build
$ getfacl -p /srv/build
# file: /srv/build
# owner: root
# group: devs
# flags: -s-
user::rwx
group::rwx
other::---
default:user::rwx
default:group::rwx
default:other::---

$ sudo -u alice bash -c 'umask 077; touch /srv/build/acl-test'
$ getfacl -p /srv/build/acl-test
# file: /srv/build/acl-test
# owner: alice
# group: devs
user::rw-
group::rw-
other::---
```

`umask 077` was applied by the process, and the file is still group-writable: **when the parent directory carries a default ACL, `open()`/`mkdir()` ignore the umask.** This is the number-one cause of "our hardened umask is not taking effect".

### 6.3 Sticky bit — restricted deletion

Write permission on a directory normally allows deleting *any* entry in it, regardless of who owns the file. `S_ISVTX` restricts `unlink`/`rename` to the file's owner, the directory's owner, or `CAP_FOWNER`.

```console
$ ls -ld /tmp /var/tmp /dev/shm
drwxrwxrwt 18 root root  4096 Aug 26 11:02 /tmp
drwxrwxrwt  5 root root  4096 Aug 26 04:12 /var/tmp
drwxrwxrwt  2 root root    40 Aug 26 03:58 /dev/shm

$ sudo -u alice touch /tmp/alice.lock
$ sudo -u bob rm -f /tmp/alice.lock
rm: cannot remove '/tmp/alice.lock': Operation not permitted
$ sudo -u bob mv /tmp/alice.lock /tmp/stolen.lock
mv: cannot move '/tmp/alice.lock' to '/tmp/stolen.lock': Operation not permitted
```

Note the errno: **`EPERM` (Operation not permitted)**, not `EACCES` (Permission denied). Distinguishing them is a diagnostic shortcut — see §10.

Sticky is necessary but not sufficient for a shared temp directory. Pair it with the symlink/hardlink hardening sysctls (Linux ≥ 3.6 / ≥ 4.19):

```console
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_fifos fs.protected_regular
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2
```

These make the kernel refuse to follow a symlink in a world-writable sticky directory when the follower is not the link's owner — closing the classic `/tmp` symlink-race privilege escalation that mode bits alone cannot.

---

## 7. `umask` — the default that everything inherits

### 7.1 Mechanics

`umask` is a per-process 9-bit mask, inherited across `fork()` **and** `execve()`. `open(2)`, `mkdir(2)`, `mknod(2)` compute:

```
final_mode = requested_mode & ~umask
```

It can only **clear** bits, never set them, and it applies **only at creation time** — `chmod` is never filtered by it.

| Creator | `requested_mode` | With `umask 022` | With `umask 002` | With `umask 077` | With `umask 027` |
|---|---|---|---|---|---|
| `touch` / `open(O_CREAT)` in shells | `0666` | `0644` | `0664` | `0600` | `0640` |
| `mkdir` | `0777` | `0755` | `0775` | `0700` | `0750` |
| `gcc` output, `install` default | `0777`/explicit | `0755` | `0775` | `0700` | `0750` |
| `ssh-keygen` (explicit `0600`) | `0600` | `0600` | `0600` | `0600` | `0600` |

```console
$ umask
0022
$ umask -S
u=rwx,g=rx,o=rx
$ touch /tmp/f && mkdir /tmp/d && stat -c '%a %n' /tmp/f /tmp/d
644 /tmp/f
755 /tmp/d

$ (umask 027; touch /tmp/f27; mkdir /tmp/d27; stat -c '%a %n' /tmp/f27 /tmp/d27)
640 /tmp/f27
750 /tmp/d27

$ umask -S u=rwx,g=rx,o=      # symbolic form SETS the mask from the desired perms
$ umask
0027
```

Note the inversion: `umask 027` and `umask -S u=rwx,g=rx,o=` are the same mask expressed two ways. The octal form is what you *remove*; the symbolic form is what you *keep*. Exam questions exploit this.

Executable bits are never granted by `open()` — this is why `touch` can never produce a `0755` file regardless of umask, and why `umask 000` yields `0666`, not `0777`.

### 7.2 Where the umask actually comes from — precedence, top wins

| Source | Scope | File / directive |
|---|---|---|
| Explicit `umask` in the running script/shell | That process and children | inline |
| systemd unit `UMask=` | That service | `/etc/systemd/system/<unit>.d/*.conf` |
| systemd global default | All services (`0022`) | `/etc/systemd/system.conf` → `DefaultUMask=` |
| Shell rc files | Interactive/login shells | `~/.bashrc`, `~/.profile`, `/etc/profile`, `/etc/bashrc`, `/etc/profile.d/*.sh` |
| `pam_umask.so` | Any PAM-authenticated session | `/etc/pam.d/common-session`, `/etc/pam.d/login` |
| `UMASK` / `USERGROUPS_ENAB` / `HOME_MODE` | Login sessions and `useradd` | `/etc/login.defs` |
| PID 1 default | Everything else | `0022` |

```console
$ grep -E '^(UMASK|HOME_MODE|USERGROUPS_ENAB)' /etc/login.defs
UMASK           022
HOME_MODE       0700
USERGROUPS_ENAB yes

$ grep -rn pam_umask /etc/pam.d/
/etc/pam.d/common-session:26:session optional    pam_umask.so

$ grep -n '^DefaultUMask' /etc/systemd/system.conf
#DefaultUMask=0022
```

`USERGROUPS_ENAB yes` implements the **User Private Group** model: `useradd alice` creates group `alice` as the primary group, and `pam_umask` then relaxes the umask from `022` to `002` *because* the primary group contains only the user. That combination is what makes `002` safe on a multi-user host — and what makes it dangerous if you ever set a **shared** group as someone's primary group.

Verify what a service actually got, rather than what you configured:

```console
$ systemctl show report-exporter -p UMask
UMask=0027
$ pid=$(systemctl show -p MainPID --value report-exporter)
$ grep Umask /proc/$pid/status
Umask:	0027
```

`/proc/<pid>/status` is ground truth. Everything else is intent.

---

## 8. Group-based access: the field that actually grants access

### 8.1 Credentials are frozen at process creation

Adding a user to a group does **not** affect any process that already exists. This is the single most common "I already fixed it, why is it still broken" report.

```console
$ id alice
uid=1001(alice) gid=1001(alice) groups=1001(alice)
$ sudo usermod -aG devs alice
$ id alice                      # queries /etc/group — shows the NEW membership
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
$ sudo -u alice id              # a fresh process — also new
uid=1001(alice) gid=1001(alice) groups=1001(alice),1500(devs)
```

But alice's *existing* SSH session:

```console
alice@node-01:~$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice)
alice@node-01:~$ touch /srv/build/x
touch: cannot touch '/srv/build/x': Permission denied
```

`id` with no argument reads the **process's** credentials; `id alice` reads the **database**. When they disagree, the session is stale. Fixes, in order of preference:

```console
alice@node-01:~$ exec sg devs "$SHELL"     # new process with devs added
alice@node-01:~$ newgrp devs               # new shell with devs as the primary GID
alice@node-01:~$ id
uid=1001(alice) gid=1500(devs) groups=1500(devs),1001(alice)
```

For services: `systemctl restart <unit>` — a reload is not enough, because `SupplementaryGroups=` is applied at `execve()`.

**`usermod -G` without `-a` replaces the entire supplementary list.** `sudo usermod -G devs alice` removes alice from `sudo`, `docker`, `adm` and everything else. Always `-aG`.

### 8.2 Group limits that bite at scale

| Limit | Value | Where it hurts |
|---|---|---|
| `NGROUPS_MAX` (Linux) | 65536 | Effectively unbounded locally |
| RPC `AUTH_SYS` gid list | **16** | NFSv3/NFSv4 with `sec=sys`: groups 17+ are silently dropped, giving intermittent `EACCES` per-mount |
| `sudo`/PAM lookup cost | O(groups) per session | LDAP/SSSD hosts with 500+ groups: slow logins |

The NFS 16-group ceiling is resolved server-side by having the server resolve groups itself:

```console
$ grep RPCMOUNTDOPTS /etc/default/nfs-kernel-server
RPCMOUNTDOPTS="--manage-gids"
$ sudo systemctl restart nfs-server
```

With `--manage-gids` the server ignores the client's 16-entry list and looks the user's groups up in its own name service. Without it, a user in 20 groups gets non-deterministic access depending on list ordering — a genuinely brutal outage to diagnose.

### 8.3 Choosing between the models

| Model | Setup | Scales to | Weakness |
|---|---|---|---|
| Owner-only (`0600`/`0700`) | Nothing | 1 principal | No sharing at all |
| Single shared group (`2770` + umask `007`) | `groupadd`, `usermod -aG`, setgid dir | ~dozens of principals, one access class | One bit of granularity: in or out |
| Multiple groups per tree (POSIX ACL) | `setfacl -m g:x:rX -m g:y:rwX` | Many overlapping classes | Requires ACL-aware backup/copy tooling; `ls -l` shows only `+` |
| MAC labels (SELinux/AppArmor) | Policy modules | Type-enforced, process-scoped | Steep operational cost; orthogonal to DAC, not a replacement |
| Per-service UID (systemd `DynamicUser=`) | One unit directive | Perfect isolation per service | Cannot share data without explicit ACLs/`StateDirectory` |

---

## 9. Declaring permissions as infrastructure

The lesson from §1 is that permissions must live in version control, not in shell history. Below are complete, working artefacts for one service — `report-exporter`, running as `svc-etl:data`, writing to `/srv/data/reports`, shared read-only with group `analysts`.

### 9.1 `systemd-tmpfiles` — the declarative owner of paths

`/etc/tmpfiles.d/report-exporter.conf`:

```
# Type Path                       Mode UID       GID       Age Argument
#
# d = create directory if missing, then enforce mode/owner
# D = like d, but empty it on boot
# Z = recursively enforce mode/owner/SELinux label on an existing tree
# z = same as Z, non-recursive
# f = create file if missing
# x = exclude path from cleanup

d  /srv/data                      0755 root      root      -   -
d  /srv/data/reports              2770 svc-etl   data      -   -
d  /srv/data/reports/archive      2750 svc-etl   data      30d -
f  /srv/data/reports/.keep        0640 svc-etl   data      -   -
d  /var/log/report-exporter       0750 svc-etl   adm       -   -
d  /run/report-exporter           0700 svc-etl   data      -   -

# Enforce the whole tree on every boot: undoes any manual drift
Z  /srv/data/reports              -    svc-etl   data      -   -
```

```console
$ sudo systemd-tmpfiles --create --clean /etc/tmpfiles.d/report-exporter.conf
$ find /srv/data -maxdepth 2 -printf '%M %u:%g %p\n'
drwxr-xr-x root:root /srv/data
drwxrws--- svc-etl:data /srv/data/reports
drwxr-s--- svc-etl:data /srv/data/reports/archive
-rw-r----- svc-etl:data /srv/data/reports/.keep
```

The `Z` line is the reason drift self-heals: mode and ownership are re-asserted at boot, so an operator's emergency `chmod 777` has a bounded lifetime.

### 9.2 systemd unit — umask, groups and directory modes

`/etc/systemd/system/report-exporter.service`:

```ini
[Unit]
Description=Report exporter (writes CSV artefacts to /srv/data/reports)
Documentation=https://internal.example.com/runbooks/report-exporter
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/report-exporter --out /srv/data/reports

# --- Identity -------------------------------------------------------------
User=svc-etl
Group=data
SupplementaryGroups=analysts

# --- Creation defaults ----------------------------------------------------
# 0027 => files 0640, directories 0750. Group reads, other gets nothing.
UMask=0027

# --- Managed state directories (systemd creates, chowns and chmods these) --
StateDirectory=report-exporter
StateDirectoryMode=0750
RuntimeDirectory=report-exporter
RuntimeDirectoryMode=0700
LogsDirectory=report-exporter
LogsDirectoryMode=0750
ConfigurationDirectory=report-exporter
ConfigurationDirectoryMode=0750

# --- Filesystem confinement ----------------------------------------------
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/srv/data/reports
ReadOnlyPaths=/srv/data/reference

# --- Privilege confinement ------------------------------------------------
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallArchitectures=native

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

`RestrictSUIDSGID=yes` makes any attempt by the service to *create* a setuid or setgid file fail with `EPERM` — the cheapest possible defence against a compromised service planting a backdoor binary.

```console
$ sudo systemctl daemon-reload && sudo systemctl restart report-exporter
$ systemctl show report-exporter -p UMask -p User -p Group -p SupplementaryGroups
UMask=0027
User=svc-etl
Group=data
SupplementaryGroups=analysts
$ pid=$(systemctl show -p MainPID --value report-exporter)
$ grep -E '^(Uid|Gid|Groups|Umask|CapEff)' /proc/$pid/status
Umask:	0027
Uid:	998	998	998	998
Gid:	1500	1500	1500	1500
Groups:	1501 
CapEff:	0000000000000000
```

### 9.3 Ansible — the same state, idempotent

`roles/report-exporter/tasks/permissions.yml`:

```yaml
---
- name: Ensure the service group exists
  ansible.builtin.group:
    name: data
    gid: 1500
    state: present
    system: true

- name: Ensure the read-only consumer group exists
  ansible.builtin.group:
    name: analysts
    gid: 1501
    state: present
    system: true

- name: Ensure the service account exists
  ansible.builtin.user:
    name: svc-etl
    uid: 998
    group: data
    groups: []
    append: false
    system: true
    shell: /usr/sbin/nologin
    home: /var/lib/report-exporter
    create_home: false
    state: present

- name: Ensure the data root exists
  ansible.builtin.file:
    path: /srv/data
    state: directory
    owner: root
    group: root
    # QUOTED. Unquoted 0755 is parsed by YAML as decimal 755 == 0o1363.
    mode: "0755"

- name: Ensure the shared report directory is setgid and group-writable
  ansible.builtin.file:
    path: /srv/data/reports
    state: directory
    owner: svc-etl
    group: data
    mode: "2770"

- name: Ensure the archive directory is setgid and group-read-only
  ansible.builtin.file:
    path: /srv/data/reports/archive
    state: directory
    owner: svc-etl
    group: data
    mode: "2750"

- name: Grant analysts recursive read access via POSIX ACL (existing entries)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: analysts
    etype: group
    permissions: rx
    recursive: true
    state: present

- name: Grant analysts read access on future entries (default ACL)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: analysts
    etype: group
    permissions: rx
    default: true
    state: present

- name: Deny 'other' on future entries (default ACL overrides the umask)
  ansible.posix.acl:
    path: /srv/data/reports
    entity: ''
    etype: other
    permissions: '0'
    default: true
    state: present

- name: Install the exporter binary with an explicit mode
  ansible.builtin.copy:
    src: report-exporter
    dest: /usr/local/bin/report-exporter
    owner: root
    group: root
    mode: "0755"

- name: Install the credentials file with a restrictive mode
  ansible.builtin.template:
    src: exporter.env.j2
    dest: /etc/report-exporter/exporter.env
    owner: root
    group: data
    mode: "0640"
  notify: Restart report-exporter

- name: Assert no world-writable file exists under the data root
  ansible.builtin.command:
    cmd: find /srv/data -xdev -perm -0002 ! -type l -print
  register: ww
  changed_when: false
  failed_when: ww.stdout | length > 0
```

**The quoting trap is real and costs outages.** `mode: 0755` unquoted is YAML integer `755` (decimal), which Ansible interprets as octal `1363` → `drwxrw--wt`. Always quote, or use symbolic `mode: u=rwx,g=rx,o=rx`.

### 9.4 Container image — ownership at build time

`Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim AS build

WORKDIR /src
COPY --chmod=0755 build.sh .
RUN ./build.sh && install -m 0755 /src/out/report-exporter /out/report-exporter

FROM gcr.io/distroless/base-debian12:nonroot

# distroless "nonroot" is uid/gid 65532. Declare it numerically: the
# runtime has no /etc/passwd lookup guarantee, and Kubernetes'
# runAsNonRoot check cannot resolve names.
ARG APP_UID=65532
ARG APP_GID=65532

COPY --from=build --chown=${APP_UID}:${APP_GID} --chmod=0555 \
     /out/report-exporter /usr/local/bin/report-exporter

COPY --chown=${APP_UID}:${APP_GID} --chmod=0444 \
     config/defaults.yaml /etc/report-exporter/defaults.yaml

USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["/usr/local/bin/report-exporter"]
```

`--chmod=0555` (read+execute, no write) on the binary means a compromised process cannot rewrite its own executable even if the root filesystem is writable. Verify the built layers rather than trusting the Dockerfile:

```console
$ docker run --rm --entrypoint /busybox/sh gcr.io/distroless/base-debian12:debug \
    -c 'ls -ln /usr/local/bin/report-exporter'
-r-xr-xr-x 1 65532 65532 14680064 Aug 26 11:30 /usr/local/bin/report-exporter
```

### 9.5 Kubernetes — `runAsUser`, `fsGroup`, and volume modes

`deploy/report-exporter.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: data-platform
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: Secret
metadata:
  name: report-exporter-credentials
  namespace: data-platform
type: Opaque
stringData:
  DB_PASSWORD: "replace-me-via-external-secrets"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: report-exporter-data
  namespace: data-platform
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-exporter
  namespace: data-platform
  labels:
    app.kubernetes.io/name: report-exporter
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: report-exporter
  template:
    metadata:
      labels:
        app.kubernetes.io/name: report-exporter
    spec:
      automountServiceAccountToken: false
      securityContext:
        # Numeric only. runAsNonRoot cannot resolve a username.
        runAsUser: 65532
        runAsGroup: 65532
        runAsNonRoot: true
        # fsGroup: the kubelet recursively chgrp's the volume to this GID
        # and sets g+rw plus the setgid bit on its directories.
        fsGroup: 20001
        # OnRootMismatch: skip the recursive walk when the volume root
        # already has the right GID and setgid bit. On a 50Gi volume with
        # millions of inodes, "Always" adds minutes to every pod start and
        # is a documented cause of readiness-probe timeouts.
        fsGroupChangePolicy: OnRootMismatch
        supplementalGroups: [20002]
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: exporter
          image: registry.example.com/report-exporter:1.14.2
          imagePullPolicy: IfNotPresent
          args: ["--out", "/data/reports"]
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: report-exporter-credentials
                  key: DB_PASSWORD
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /etc/report-exporter
              readOnly: true
            - name: credentials
              mountPath: /var/run/secrets/report-exporter
              readOnly: true
            - name: tmp
              mountPath: /tmp
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 20
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: report-exporter-data
        - name: config
          configMap:
            name: report-exporter-config
            # 0444 in YAML 1.1 is octal -> 292 decimal -> mode 0444. Correct.
            # Writing 444 (no leading zero) means decimal 444 -> mode 0674. Wrong.
            defaultMode: 0444
        - name: credentials
          secret:
            secretName: report-exporter-credentials
            # Owner-read only. Combined with fsGroup, the kubelet sets the
            # mount's group so the container UID can traverse it.
            defaultMode: 0400
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
```

Verify inside the running pod — never assume the manifest was honoured:

```console
$ kubectl -n data-platform exec deploy/report-exporter -- id
uid=65532 gid=65532 groups=65532,20001,20002

$ kubectl -n data-platform exec deploy/report-exporter -- ls -ldn /data /data/reports
drwxrwsr-x 3 0     20001 4096 Aug 26 11:44 /data
drwxrwsr-x 2 65532 20001 4096 Aug 26 11:45 /data/reports

$ kubectl -n data-platform exec deploy/report-exporter -- ls -ln /var/run/secrets/report-exporter/
total 0
lrwxrwxrwx 1 0 0 15 Aug 26 11:44 DB_PASSWORD -> ..data/DB_PASSWORD

$ kubectl -n data-platform exec deploy/report-exporter -- stat -c '%a %U:%G %n' \
    /var/run/secrets/report-exporter/..data/DB_PASSWORD
400 root:20001 /var/run/secrets/report-exporter/..data/DB_PASSWORD
```

Note `/data` is `drwxrwsr-x` with GID `20001`: that `s` is the setgid bit the kubelet applied as part of `fsGroup`, which is precisely the §6.2 mechanism — Kubernetes did not invent anything, it automated `chgrp -R` + `chmod g+s`.

| Field | Layer it manipulates | Applies to |
|---|---|---|
| `runAsUser` / `runAsGroup` | Process UID/GID at `execve()` | The container process |
| `fsGroup` | Recursive `chgrp` + `g+rws` on volumes | `emptyDir`, PVCs whose CSI driver supports it; **not** `hostPath` |
| `fsGroupChangePolicy` | Whether the recursive walk runs | Volume mount latency |
| `supplementalGroups` | `setgroups()` list | Access to pre-existing GIDs on shared storage (NFS) |
| `defaultMode` / `items[].mode` | Mode of projected files | `secret`, `configMap`, `downwardAPI`, `projected` |
| `readOnlyRootFilesystem` | Mount flag `ro` | Everything outside declared volumes |

---

## 10. Verification and failure diagnosis

### 10.1 Read the errno first — it partitions the search space

| errno | Message | Meaning | First thing to check |
|---|---|---|---|
| `EACCES` (13) | `Permission denied` | The DAC check (mode/ACL) or an LSM said no | `namei -l`, `getfacl`, `ausearch -m AVC` |
| `EPERM` (1) | `Operation not permitted` | Ownership-class denial: sticky-bit unlink, `chown` by non-owner, `chattr +i`, missing capability | `ls -ld` parent, `lsattr`, `getpcaps` |
| `EROFS` (30) | `Read-only file system` | Mount flag, not permissions | `findmnt -no OPTIONS <path>` |
| `ETXTBSY` (26) | `Text file busy` | Writing to a currently-executing binary | `fuser -v <path>` |
| `EISDIR` / `ENOTDIR` (21/20) | | Path-type mismatch, not permission | `stat` the components |
| `ENOENT` (2) on an existing file | `No such file or directory` | A parent lacks `x` **and** the tool masks it, or `hidepid`/mount namespace | `namei -l`, `findmnt` |

### 10.2 The traversal ladder — `namei -l` is the fastest tool you own

Permission failures are almost never about the leaf file. `namei` walks every component:

```console
$ sudo -u analyst-01 cat /srv/data/reports/q3.csv
cat: /srv/data/reports/q3.csv: Permission denied

$ namei -l /srv/data/reports/q3.csv
f: /srv/data/reports/q3.csv
 dr-xr-xr-x root    root    /
 drwxr-xr-x root    root    srv
 drwxr-x--- root    data    data          <-- analyst-01 is not in 'data'
 drwxrws--- svc-etl data    reports
 -rw-rw-r-- svc-etl data    q3.csv        <-- leaf is world-readable!
```

The leaf is `rw-rw-r--`; anyone could read it *if they could reach it*. The block is at `/srv/data`, two levels up. Fixing the leaf would have changed nothing. This is the highest-value diagnostic habit in the whole objective.

```console
$ sudo chmod o+x /srv/data          # traversal only, no listing
$ namei -l /srv/data/reports/q3.csv | sed -n '4p'
 drwxr-x--x root    data    data
$ sudo -u analyst-01 cat /srv/data/reports/q3.csv | head -1
region,revenue,quarter
```

### 10.3 Test as the principal, not as yourself

```console
$ sudo -u analyst-01 test -r /srv/data/reports/q3.csv && echo READABLE || echo DENIED
READABLE
$ sudo -u analyst-01 test -w /srv/data/reports && echo WRITABLE || echo DENIED
DENIED
$ sudo -u analyst-01 test -x /srv/data && echo TRAVERSABLE || echo DENIED
TRAVERSABLE

# Exactly what the kernel would decide, including ACLs — no shell heuristics
$ sudo -u analyst-01 -- python3 -c \
  'import os,sys; print(os.access("/srv/data/reports", os.W_OK, effective_ids=True))'
False
```

For a service that has already started, simulate its real credential set:

```console
$ sudo setpriv --reuid=svc-etl --regid=data --groups=analysts --inh-caps=-all -- \
    sh -c 'id; touch /srv/data/reports/probe && echo WRITE_OK; rm -f /srv/data/reports/probe'
uid=998(svc-etl) gid=1500(data) groups=1501(analysts)
WRITE_OK
```

`setpriv` beats `sudo -u` here because it reproduces the *exact* supplementary-group list and capability set, rather than whatever `sudo` computes from `/etc/group`.

### 10.4 When the mode bits look right and it still fails

Work down this list in order — each step is cheap:

```console
# 1. ACLs — the '+' in ls -l is the only visible hint
$ ls -l /srv/data/reports/q3.csv
-rw-rw----+ 1 svc-etl data 481203 Aug 26 11:52 /srv/data/reports/q3.csv
$ getfacl -p /srv/data/reports/q3.csv
# file: /srv/data/reports/q3.csv
# owner: svc-etl
# group: data
user::rw-
user:analyst-01:rw-		#effective:r--
group::rw-			#effective:r--
mask::r--                       <-- THE MASK is capping everything at r--
other::---
$ sudo setfacl -m m::rw- /srv/data/reports/q3.csv     # raise the mask

# 2. Immutable / append-only attributes -> EPERM even for root
$ lsattr /srv/data/reports/q3.csv
----i---------e------- /srv/data/reports/q3.csv
$ sudo chattr -i /srv/data/reports/q3.csv

# 3. Mount options
$ findmnt -no TARGET,FSTYPE,OPTIONS /srv/data
/srv/data ext4 rw,nosuid,nodev,noexec,relatime
#                              ^^^^^^ explains "Permission denied" on execve

# 4. SELinux / AppArmor
$ getenforce
Enforcing
$ ls -Z /srv/data/reports/q3.csv
system_u:object_r:default_t:s0 /srv/data/reports/q3.csv
$ sudo ausearch -m AVC -ts recent | tail -5
type=AVC msg=audit(1756208134.881:412): avc:  denied  { read } for  pid=48122
  comm="report-exporter" name="q3.csv" dev="dm-0" ino=1180231
  scontext=system_u:system_r:etl_t:s0 tcontext=system_u:object_r:default_t:s0
  tclass=file permissive=0
$ sudo restorecon -Rv /srv/data/reports
Relabeled /srv/data/reports/q3.csv from system_u:object_r:default_t:s0
  to system_u:object_r:etl_data_t:s0

# 5. Capabilities of the failing process
$ pid=$(pgrep -f report-exporter | head -1)
$ getpcaps $pid
$pid: =
$ grep -E '^(Uid|Gid|Groups)' /proc/$pid/status
Uid:	998	998	998	998
Gid:	1500	1500	1500	1500
Groups:	1501
```

### 10.5 `strace` — the ground-truth escalation

When every hypothesis fails, watch the syscall:

```console
$ sudo strace -f -e trace=%file -y -s 200 -o /tmp/trace.log \
    setpriv --reuid=svc-etl --regid=data -- /usr/local/bin/report-exporter --out /srv/data/reports
$ grep -E 'EACCES|EPERM|EROFS' /tmp/trace.log
48311 openat(AT_FDCWD, "/srv/data/reports/q3.csv.tmp", O_WRONLY|O_CREAT|O_EXCL, 0600) = -1 EACCES (Permission denied)
48311 access("/srv/data/reference/schema.json", R_OK) = -1 EACCES (Permission denied)
```

The first line is the real one, and it names a `.tmp` file the application never logs — write-then-rename is invisible to log-level debugging but obvious in a trace.

### 10.6 Fleet-wide audits

```console
# World-writable regular files (excluding symlinks, which are always lrwxrwxrwx)
$ sudo find / -xdev -type f -perm -0002 -printf '%M %u:%g %p\n' 2>/dev/null
-rw-rw-rw- root:root /var/log/app/debug.log

# World-writable directories MISSING the sticky bit -- the real risk
$ sudo find / -xdev -type d -perm -0002 ! -perm -1000 -printf '%M %u:%g %p\n' 2>/dev/null
drwxrwxrwx root:root /var/spool/uploads

# Files with no valid owner (deleted account, restored backup, container UID leak)
$ sudo find / -xdev \( -nouser -o -nogroup \) -printf '%U:%G %M %p\n' 2>/dev/null
1004:1004 -rw-r--r-- /home/former-employee/notes.md

# Group-writable files under a system path
$ sudo find /usr /etc -xdev -type f -perm -0020 -printf '%M %u:%g %p\n' 2>/dev/null

# find -perm semantics -- the three forms are NOT interchangeable
$ find /tmp -maxdepth 1 -perm 0644   -printf '%M %p\n'   # EXACTLY 0644
$ find /tmp -maxdepth 1 -perm -0644  -printf '%M %p\n'   # ALL of these bits set
$ find /tmp -maxdepth 1 -perm /0644  -printf '%M %p\n'   # ANY of these bits set
```

Reconcile against the package database — the only authoritative record of "correct":

```console
$ sudo dpkg --verify | grep -v '^..5' | head
??5?????? c /etc/ssh/sshd_config
missing     /usr/share/doc/openssh-server/NEWS.Debian.gz

$ rpm -Va | awk '$1 ~ /M/ {print}'          # RHEL: M = mode differs
.M.......  g /var/log/wtmp
.M....G..    /usr/bin/ping
```

The `dpkg --verify` output columns are `?5?????? ` where position 1 is size, 2 is mode+type, 3 is checksum, 5 is user, 6 is group. `rpm -Va` uses `SM5DLUGTP`: `M` = mode, `U` = user, `G` = group. A `.M....G..` on `/usr/bin/ping` is exactly the setuid-to-capabilities migration and is expected; a `M` on anything under `/usr/bin` that you did not migrate is not.

### 10.7 A reusable diagnostic script

`/usr/local/sbin/whycant`:

```bash
#!/usr/bin/env bash
# whycant USER PATH [r|w|x] -- explain why USER cannot access PATH
set -euo pipefail

user="${1:?usage: whycant USER PATH [r|w|x]}"
target="${2:?usage: whycant USER PATH [r|w|x]}"
want="${3:-r}"

echo "== identity =="
id "$user"

echo
echo "== path traversal =="
namei -l "$target" 2>&1 || true

echo
echo "== leaf metadata =="
stat -c 'mode=%a (%A)  owner=%U:%G  inode=%i  links=%h  type=%F' "$target" 2>&1 || true

echo
echo "== ACLs =="
getfacl -p "$target" 2>/dev/null || echo "(no ACL support or path unreadable)"

echo
echo "== extended attributes =="
lsattr -d "$target" 2>/dev/null || echo "(not supported on this fs)"
getfattr -d -m - "$target" 2>/dev/null || true

echo
echo "== mount =="
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS -T "$target"

echo
echo "== effective access test as $user =="
if sudo -u "$user" test "-$want" "$target"; then
  echo "RESULT: '$want' IS permitted for $user"
else
  echo "RESULT: '$want' is DENIED for $user"
fi

echo
echo "== recent LSM denials =="
if command -v ausearch >/dev/null 2>&1; then
  sudo ausearch -m AVC -ts recent 2>/dev/null | tail -20 || echo "(none)"
else
  sudo dmesg 2>/dev/null | grep -iE 'apparmor|avc: denied' | tail -10 || echo "(none)"
fi
```

```console
$ sudo install -m 0750 -o root -g root whycant /usr/local/sbin/whycant
$ sudo /usr/local/sbin/whycant analyst-01 /srv/data/reports/q3.csv r
== identity ==
uid=1600(analyst-01) gid=1600(analyst-01) groups=1600(analyst-01),1501(analysts)

== path traversal ==
f: /srv/data/reports/q3.csv
 dr-xr-xr-x root    root    /
 drwxr-xr-x root    root    srv
 drwxr-x--x root    data    data
 drwxrws--- svc-etl data    reports
 -rw-rw-r-- svc-etl data    q3.csv

== leaf metadata ==
mode=664 (-rw-rw-r--)  owner=svc-etl:data  inode=1180231  links=1  type=regular file
...
== effective access test as analyst-01 ==
RESULT: 'r' is DENIED for analyst-01
```

The traversal block answers it: `/srv/data/reports` is `drwxrws---` with group `data`, and `analyst-01` is in `analysts`, not `data`. The correct fix is an ACL on the *directory*, not a `chmod o+r` on the file.

```console
$ sudo setfacl -m g:analysts:rx -m d:g:analysts:rx /srv/data/reports
$ sudo /usr/local/sbin/whycant analyst-01 /srv/data/reports/q3.csv r | tail -2
== effective access test as analyst-01 ==
RESULT: 'r' IS permitted for analyst-01
```

---

## 11. Failure catalogue — symptom to root cause

| Symptom | Likely root cause | Confirming command | Fix |
|---|---|---|---|
| `Permission denied` on a file whose mode is `0666` | A parent directory lacks `x` for the principal | `namei -l <path>` | `chmod o+x` (or ACL) on the blocking parent |
| Setuid binary runs unprivileged after deployment | `chown` ran **after** `chmod` | `stat -c %a <bin>` shows `755` not `4755` | Use `install -o -g -m`, or reorder |
| `chmod g+s` returns 0, bit not set | Caller not in the file's group, no `CAP_FSETID` | `stat -c %a` after the call | `chgrp` first, or run privileged |
| Hardened `umask 077` has no effect | Parent directory has a **default ACL** | `getfacl -p <dir>` shows `default:` lines | Fix the default ACL; the umask is bypassed by design |
| New files in a shared dir have the wrong group | Directory not setgid | `ls -ld` shows no `s` in the group triad | `chmod g+s <dir>` and re-`chgrp` existing files |
| New files in a shared dir have the right group but `0644` | umask is `022` | `grep Umask /proc/<pid>/status` | `UMask=0007` in the unit / `umask 007` in the wrapper |
| User added to a group, still denied | Existing session's credentials are frozen | `id` vs `id <user>` disagree | Re-login, `exec sg <grp> $SHELL`, or restart the service |
| Access works on some NFS clients, not others | >16 supplementary groups, `AUTH_SYS` truncation | `id <user> \| tr ',' '\n' \| wc -l` | `RPCMOUNTDOPTS="--manage-gids"` on the server |
| `rm` fails with `Operation not permitted` in a writable dir | Sticky bit, not the file owner | `ls -ld <dir>` shows `t` | Delete as the file owner, or as root |
| `chattr`-style `Operation not permitted` for root | Immutable attribute | `lsattr <file>` shows `i` | `chattr -i <file>` |
| `Text file busy` on binary replacement | Binary is executing | `fuser -v <path>` | `mv` new into place (rename is atomic), then restart |
| K8s pod `CrashLoopBackOff`, `EACCES` on volume | `fsGroup` missing, or CSI driver ignores it | `kubectl exec -- ls -ldn /data` | Add `fsGroup`, or an `initContainer` running `chown` |
| Pod start latency spikes on a large PVC | `fsGroupChangePolicy: Always` recursive walk | `kubectl describe pod` event timings | `fsGroupChangePolicy: OnRootMismatch` |
| Secret file unreadable by a non-root container | `defaultMode: 400` written as decimal, or no `fsGroup` | `kubectl exec -- stat -c %a <file>` shows `620` | Write `0400` with the leading zero |
| A tree lost all its ACLs after a restore | `cp`/`tar`/`rsync` without ACL flags | `getfacl -R` on source vs target | `rsync -aAX`, `tar --acls --xattrs` |
| `execve` fails with `EACCES` although `x` is set | `noexec` mount option | `findmnt -no OPTIONS -T <path>` | Remount, or relocate the binary |

---

## 12. Exam-grade quick reference and drills

### 12.1 Conversion table

| Octal | Symbolic | Common on |
|---|---|---|
| `0400` | `-r--------` | Kubernetes secrets, private keys read once |
| `0600` | `-rw-------` | `~/.ssh/id_ed25519`, `/etc/shadow` (RHEL) |
| `0640` | `-rw-r-----` | `/etc/shadow` (Debian, group `shadow`), service config |
| `0644` | `-rw-r--r--` | `/etc/passwd`, general readable data |
| `0700` | `drwx------` | `~/.ssh`, `/root` |
| `0711` | `drwx--x--x` | Non-listable but traversable |
| `0750` | `drwxr-x---` | Service data readable by an ops group |
| `0755` | `drwxr-xr-x` | `/usr/bin`, standard directories |
| `1777` | `drwxrwxrwt` | `/tmp`, `/var/tmp` |
| `2770` | `drwxrws---` | Shared group directory |
| `2755` | `drwxr-sr-x` | Shared, world-readable group directory |
| `4755` | `-rwsr-xr-x` | `/usr/bin/passwd`, `/usr/bin/sudo` |
| `2755` (file) | `-rwxr-sr-x` | `/usr/bin/wall`, `/usr/bin/crontab` |
| `6755` | `-rwsr-sr-x` | `/usr/bin/at` |

### 12.2 Drills — work them without a shell, then verify

1. `umask 026` is in effect. `touch a; mkdir b`. Modes?
   → `a` = `0666 & ~0026` = `0640`; `b` = `0777 & ~0026` = `0751`.
2. `/data` is `drwxrws---  root data`. `alice` (in `data`, umask `022`) runs `mkdir /data/x`. Owner, group, mode of `x`?
   → `alice:data`, mode `2755` — group inherited **and** the setgid bit propagates to the new directory.
3. A file is `-rwsr-sr-x root root`. `root` runs `chown daemon file`. New mode?
   → `0755`. Both special bits are cleared, even for root, since Linux 2.2.13.
4. `chmod 755 /shared` on a directory that was `2775`. What broke?
   → The setgid bit. Three-digit octal is absolute across all 12 bits and zeroes the special triad. Use `chmod 2755` or `chmod g+s`.
5. `-r--rw---- alice devs`. `alice` is in `devs`. Can she write?
   → No. She matches the **owner** class first; the group triad is never consulted.
6. Convert `u=rwx,g=rx,o=` to an octal umask.
   → Keep `750`; the umask is the complement of the *file* default in the removed sense: `umask 027`.
7. Which command sets group `devs` on `file` without touching the owner? Name two.
   → `chgrp devs file` and `chown :devs file`.
8. `/usr/local/bin/deploy.sh` is `-rwsr-xr-x root root`. Does it run as root?
   → No. Linux ignores setuid on `#!` scripts. Rewrite as a compiled binary, a `sudo` rule, or a file capability.

### 12.3 One-line invariants worth memorising

```
umask only clears bits; chmod is never umask-filtered (except a class-less +x).
chown/chgrp clear setuid and setgid — always chown before chmod.
Three-digit octal chmod clears the special bits. Four-digit or symbolic preserves intent.
On a directory: r = list names, x = use names, w = change the list (needs x).
Access class is chosen once — owner, then group, then other. No fallthrough.
setgid on a directory fixes the GROUP of new files; the umask fixes their MODE.
Sticky restricts deletion; it does not restrict writing to existing files.
A default ACL on the parent makes the umask irrelevant.
Group membership is applied at process creation, not at usermod time.
```

---

## References

- LPI — Exam 101 Objectives (v5.0), Topic 104.5: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Exam 102 Objectives (v5.0): https://www.lpi.org/our-certifications/exam-102-objectives/
- `chmod(1)` — GNU coreutils manual: https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html
- `chown(1)` — GNU coreutils manual: https://www.gnu.org/software/coreutils/manual/html_node/chown-invocation.html
- `chgrp(1)` — GNU coreutils manual: https://www.gnu.org/software/coreutils/manual/html_node/chgrp-invocation.html
- GNU coreutils — File permissions, symbolic and numeric modes, umask: https://www.gnu.org/software/coreutils/manual/html_node/File-permissions.html
- `chmod(2)` — Linux man-pages (setgid clearing, `CAP_FSETID`): https://man7.org/linux/man-pages/man2/chmod.2.html
- `chown(2)` — Linux man-pages (setuid/setgid clearing semantics): https://man7.org/linux/man-pages/man2/chown.2.html
- `umask(2)` — Linux man-pages: https://man7.org/linux/man-pages/man2/umask.2.html
- `stat(2)` — Linux man-pages (`st_mode`, `S_ISUID`, `S_ISGID`, `S_ISVTX`): https://man7.org/linux/man-pages/man2/stat.2.html
- `open(2)` — Linux man-pages (mode and umask interaction, default ACL exception): https://man7.org/linux/man-pages/man2/open.2.html
- `inode(7)` — Linux man-pages (mode bits reference): https://man7.org/linux/man-pages/man7/inode.7.html
- `path_resolution(7)` — Linux man-pages (traversal and search permission): https://man7.org/linux/man-pages/man7/path_resolution.7.html
- `capabilities(7)` — Linux man-pages (`CAP_DAC_OVERRIDE`, `CAP_FOWNER`, `CAP_CHOWN`, `CAP_FSETID`): https://man7.org/linux/man-pages/man7/capabilities.7.html
- `credentials(7)` — Linux man-pages (UID/GID/supplementary groups): https://man7.org/linux/man-pages/man7/credentials.7.html
- `acl(5)` — Linux man-pages (POSIX ACLs, mask, default ACLs): https://man7.org/linux/man-pages/man5/acl.5.html
- `setfacl(1)` / `getfacl(1)` — Linux man-pages: https://man7.org/linux/man-pages/man1/setfacl.1.html
- `find(1)` — GNU findutils manual (`-perm`, `-nouser`, `-printf`): https://www.gnu.org/software/findutils/manual/html_mono/find.html
- `namei(1)` — util-linux: https://man7.org/linux/man-pages/man1/namei.1.html
- `setpriv(1)` — util-linux: https://man7.org/linux/man-pages/man1/setpriv.1.html
- `login.defs(5)` — shadow-utils (`UMASK`, `HOME_MODE`, `USERGROUPS_ENAB`): https://man7.org/linux/man-pages/man5/login.defs.5.html
- `pam_umask(8)` — Linux-PAM: https://man7.org/linux/man-pages/man8/pam_umask.8.html
- `systemd.exec(5)` — `UMask=`, `StateDirectoryMode=`, `RestrictSUIDSGID=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `tmpfiles.d(5)` — declarative path modes and ownership: https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html
- POSIX.1-2024 — `chmod`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html
- POSIX.1-2024 — `umask`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html
- Filesystem Hierarchy Standard 3.0 (expected modes for `/tmp`, `/var/tmp`, `/srv`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Kubernetes — Configure a Security Context for a Pod or Container (`runAsUser`, `fsGroup`, `fsGroupChangePolicy`): https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes — Secrets, `defaultMode` and permission semantics: https://kubernetes.io/docs/concepts/configuration/secret/
- Docker — Dockerfile reference, `COPY --chown` / `--chmod`: https://docs.docker.com/reference/dockerfile/
- Ansible — `ansible.builtin.file` module (mode quoting): https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html
- Ansible — `ansible.posix.acl` module: https://docs.ansible.com/ansible/latest/collections/ansible/posix/acl_module.html