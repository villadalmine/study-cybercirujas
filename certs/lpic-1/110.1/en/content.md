# LPIC-1 · Topic 110.1 — Perform Security Administration Tasks

**Exam:** 102-500 · **Objective:** 110.1 · **Version:** 5.0

**Key knowledge areas:** audit a system to find files with the SUID/SGID bit set · set or change user passwords and password aging information · be able to use `nmap` and `netstat` to discover open ports on a system · set up limits on user logins, processes and memory usage · determine which users have logged in to the system or are currently logged in · basic sudo configuration and usage.

**Terms and utilities:** `find`, `passwd`, `fuser`, `lsof`, `nmap`, `chage`, `netstat`, `sudo`, `/etc/sudoers`, `su`, `usermod`, `ulimit`, `who`, `w`, `last`

---

## 1. Motivation: the architectural problem

Every objective in 110.1 is a facet of one question: **on a machine you operate, who can become root, and how do you find out after the fact?**

On a single laptop that question is trivial. On a fleet — 400 nodes, 12 teams, an on-call rotation, a compliance auditor asking for evidence — it becomes an architecture problem with three properties that make it hard:

1. **Privilege on Linux is ambient, not scoped.** A process that reaches UID 0 does not get "permission to restart nginx". It gets the whole machine: every namespace, every file, the kernel keyring, `/dev/mem` if it is not locked down, and the ability to rewrite the audit trail that would have recorded what it did. There is no intermediate blast radius unless you construct one.
2. **The paths to UID 0 are numerous and mostly invisible.** `sudo` is the one you provision. SUID binaries, file capabilities, group memberships (`docker`, `disk`, `wheel`), writable systemd unit directories, and a `NOPASSWD` entry someone added during an incident three quarters ago are the ones you inherit. The set of paths grows on every `apt upgrade` and shrinks only when someone measures it.
3. **Ambient privilege is invisible in a diff.** Your infrastructure-as-code repository shows what you *intended*. It does not show the `chmod u+s` that a debugging session left behind at 03:40, or the fact that a vendor RPM ships a SUID helper. The gap between intent and reality is exactly where post-incident forensics lives.

The production posture that follows from this is not "harden the host once". It is a **control loop**:

```
      declare baseline           observe reality            reconcile / alert
   ┌──────────────────────┐   ┌────────────────────────┐   ┌──────────────────┐
   │ sudoers.d/*          │   │ find -perm -4000       │   │ drift metric     │
   │ limits.d/*.conf      │──▶│ getcap -r /            │──▶│ Prometheus alert │
   │ login.defs, faillock │   │ ss -tulpn / nmap       │   │ Ansible --check  │
   │ systemd unit hardening│   │ last / lastb / journal │   │ auditd -k events │
   └──────────────────────┘   └────────────────────────┘   └──────────────────┘
             ▲                                                       │
             └───────────────────────────────────────────────────────┘
```

The LPIC-1 objective lists the observation tools. This document treats them as the instrumentation half of that loop and shows the declaration half alongside them, because a `find` command whose output nobody compares against a baseline is a shell command, not a control.

A note on scope: the exam tests `netstat`, `ulimit`, and `/etc/security/limits.conf`. Production in 2026 uses `ss`, systemd unit directives, and cgroup v2. Both are covered, and every section states plainly which is which — that divergence is itself one of the most useful things to internalize, because a `limits.conf` entry that silently does nothing to a systemd service is one of the most common false-confidence failures on modern Linux.

---

## 2. The privilege surface: SUID, SGID, and file capabilities

### 2.1 Mechanics

When the kernel executes a file (`execve(2)`), it normally keeps the caller's credentials. Two mode bits change that:

| Bit | Octal | Symbolic | Effect on a regular file | Effect on a directory |
|---|---|---|---|---|
| SUID | `4000` | `s` in the user-execute position | The new process's **effective UID** becomes the file's owner | *(no effect on execution)* |
| SGID | `2000` | `s` in the group-execute position | The new process's **effective GID** becomes the file's group | New entries inherit the directory's group (BSD semantics) |
| Sticky | `1000` | `t` in the other-execute position | *(no effect on modern Linux)* | Only the owner of a file (or of the dir, or root) may unlink it — this is what makes `/tmp` safe |

Two details that trip people up:

- **The bit is displayed as `S` (uppercase) when the corresponding execute bit is missing.** `-rwSr--r--` is a SUID file that nobody can execute — almost always a mistake, and worth flagging in an audit.
- **SUID is ignored on filesystems mounted `nosuid`.** This is a mount-level kill switch, not a per-file one, and it is the correct hardening for `/tmp`, `/var/tmp`, `/home`, and any filesystem holding user-writable data.

```
$ ls -l /usr/bin/passwd /usr/bin/wall /usr/bin/mount
-rwsr-xr-x. 1 root root  32712 Jul 18 2026 /usr/bin/passwd
-rwxr-sr-x. 1 root tty   35048 Jun 02 2026 /usr/bin/wall
-rwsr-xr-x. 1 root root  59976 Jun 27 2026 /usr/bin/mount
```

`passwd` is SUID root because it must write `/etc/shadow` (mode `0000`, owner root). `wall` is SGID `tty` because it must write to other users' terminal devices. Neither is gratuitous; both are also, historically, sources of local privilege escalation. That is the trade-off in one line: **SUID converts a file permission problem into a code-correctness problem.**

### 2.2 File capabilities — the modern, finer-grained alternative

Since Linux 2.6.24, a binary can carry a subset of root's powers instead of all of them, stored in the `security.capability` extended attribute:

```
$ getcap -r / 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/usr/sbin/arping cap_net_raw=ep
/usr/bin/mtr-packet cap_net_raw=ep
```

`ping` used to be SUID root. It now carries only `CAP_NET_RAW` (`e`ffective + `p`ermitted), so a bug in `ping` yields the ability to craft raw packets, not the machine. This is the same reasoning that produces `CapabilityBoundingSet=` in systemd units and `securityContext.capabilities.drop: [ALL]` in a Pod spec — the argument scales from a single binary to a container runtime unchanged.

> **Audit implication:** `find -perm -4000` does **not** find capability-bearing binaries. An audit that only looks for SUID has a blind spot exactly the size of your distribution's modernization effort. Always run both.

### 2.3 Auditing the surface

The canonical exam-form command, and the production-form command:

```bash
# Exam form — SUID files anywhere on the root filesystem
$ sudo find / -perm -4000 -type f

# SUID or SGID, staying on one filesystem, with useful columns
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
      -printf '%M %6m %-8u %-8g %10s %p\n' | sort -k6
```

```
-rwxr-sr-x   2755 root     shadow        38912 /usr/bin/chage
-rwsr-xr-x   4755 root     root          72056 /usr/bin/chfn
-rwsr-xr-x   4755 root     root          44808 /usr/bin/chsh
-rwsr-xr-x   4755 root     root          88304 /usr/bin/gpasswd
-rwsr-xr-x   4755 root     root          55672 /usr/bin/mount
-rwsr-xr-x   4755 root     root          68208 /usr/bin/newgrp
-rwsr-xr-x   4755 root     root          32712 /usr/bin/passwd
-rwsr-xr-x   4755 root     root          72056 /usr/bin/su
-rwsr-xr-x   4755 root     root          39144 /usr/bin/umount
-rwsr-xr-x   4755 root     root         166056 /usr/bin/sudo
-rwxr-sr-x   2755 root     tty           35048 /usr/bin/wall
-rwsr-xr-x   4755 root     root          85064 /usr/lib/openssh/ssh-keysign
-rwxr-sr-x   2755 root     ssh          362640 /usr/bin/ssh-agent
```

Anatomy of the `find` predicates — this is exam-critical and the source of most wrong answers:

| Predicate | Meaning |
|---|---|
| `-perm 4000` | Mode is **exactly** `4000` — no read, no write, no execute bits. Almost never what you want. |
| `-perm -4000` | **All** of the bits in `4000` are set; other bits are ignored. **This is the SUID audit form.** |
| `-perm /4000` | **Any** of the bits in `4000` are set. Identical to `-4000` for a single bit; differs for masks like `/6000`. |
| `-perm -u+s` | Symbolic equivalent of `-perm -4000`. |
| `-perm /6000` | SUID **or** SGID — one pass instead of an `-o` group. |

Operational flags that matter at fleet scale:

| Flag | Why you need it |
|---|---|
| `-xdev` | Do not descend into other filesystems. Without it you walk NFS mounts, `/proc`, container overlay layers, and bind-mounted volumes — slow, noisy, and it can hang on a dead NFS server. |
| `-type f` | Exclude directories, so SGID directories (legitimate, e.g. `/var/mail`) do not pollute the SUID report. |
| `2>/dev/null` | Suppress `Permission denied` when run unprivileged — but note that an unprivileged scan is **incomplete** and must not be used as an audit of record. |
| `-newer /var/lib/suid.stamp` | Incremental scan: only files whose inode changed since the last baseline. |

Package-manager cross-check — this is the step that turns "a list of SUID files" into "a list of *unexpected* SUID files":

```
$ rpm -Va 2>/dev/null | awk '$1 ~ /M/ {print}'
.M.......  /usr/bin/find
```
```
$ dpkg --verify 2>/dev/null | grep '^..5\|^.M'
??5?????? c /etc/sudoers.d/90-cloud-init-users
```

`M` means the mode differs from what the package declared. A SUID binary that the package manager did **not** ship with the SUID bit is the highest-signal finding an audit can produce.

### 2.4 Trade-offs: mechanisms for delegating privilege

| Mechanism | Granularity | Who authenticates | Audit trail | Blast radius on compromise | Revocation | Exam relevance |
|---|---|---|---|---|---|---|
| **SUID root binary** | Whole binary; all of root | Nobody (implicit) | None (the binary must log itself) | Full root | `chmod u-s`, requires touching every node | **High** — `find -perm -4000` |
| **File capabilities** | One or more `CAP_*` | Nobody | None | Only that capability's reach | `setcap -r` | Low (LPIC-2/3) |
| **`su`** | All of the target user | Target account's password | `/var/log/secure`, `journalctl -u ...`; the shell's own history is not recorded | Full target user; password is shared knowledge | Change the shared password everywhere | **High** |
| **`sudo`** | Per command, per host, per runas-target | The **invoking** user's own password | `journald`/syslog per invocation, optional full I/O log | Bounded by the sudoers rule — *if the rule is written correctly* | Delete one line in `sudoers.d/`, config-managed | **High** |
| **polkit** | Per D-Bus action | Invoking user, per policy | `journalctl -u polkit` | Bounded by the action | Rule file | Low |
| **systemd unit + socket/`systemctl` grant** | One service operation | Handled by sudo/polkit at the boundary | journald | Bounded by the service | Unit or sudoers change | Medium |
| **SSH `command=` in `authorized_keys`** | One command, per key | SSH key | `sshd` log | Bounded by the forced command | Remove the key line | Medium |

**The design rule this table encodes:** prefer the mechanism whose failure mode is smallest and whose grant is a line in a file you can diff. That is `sudo` for interactive humans and forced commands or capabilities for machines. SUID is a legacy of a design that predates all of these; treat every SUID binary outside the distribution's baseline as debt.

### 2.5 Removing a SUID bit safely

```
$ sudo chmod u-s /usr/bin/legacy-helper
$ ls -l /usr/bin/legacy-helper
-rwxr-xr-x. 1 root root 24576 Aug 14 2026 /usr/bin/legacy-helper
```

Do **not** blanket-strip the distribution's SUID set. Removing `su` breaks nothing on a sudo-only host; removing `mount` breaks `/etc/fstab` `user` entries; removing `pkexec` breaks desktop authentication; removing `ssh-keysign` breaks host-based SSH authentication. The correct workflow is: enumerate → subtract the vendor baseline → justify or remove each remainder → record the decision → alert on drift from the new baseline. Sections 8 and 9 implement exactly that.

The system-wide kill switch, for workloads that never need it:

```ini
# /etc/systemd/system/myapp.service.d/10-hardening.conf
[Service]
NoNewPrivileges=yes      # execve() can never gain privileges — SUID becomes inert
RestrictSUIDSGID=yes     # the process cannot even create SUID/SGID files (implies NoNewPrivileges)
```

---

## 3. `sudo`: delegated, authenticated, audited privilege

### 3.1 `su` versus `sudo`

```
$ su -
Password:
# whoami
root
```

```
$ sudo -i
[sudo] password for alice:
# whoami
root
```

They look equivalent from the terminal and are architecturally opposite:

| Dimension | `su -` | `sudo` |
|---|---|---|
| Credential presented | The **root** password | The **invoking user's** password |
| Shared secret? | Yes — everyone with root access knows the same string | No |
| Offboarding one engineer | Rotate the root password on every host, notify everyone | Delete their sudoers grant / disable their account |
| Scope of grant | All of root, indefinitely | Per command, per host, per target user, per rule |
| Per-action log record | One "session opened" line; individual commands unlogged | One line per invocation, with the exact argv |
| Session recording | No | `Defaults log_output` → `sudoreplay` |
| MFA / per-user policy | Root's PAM stack only | Per-user PAM stack, `pam_u2f`, `pam_sss`, etc. |
| Correct production default | Root password locked (`!` in shadow), no direct root login | The only path to UID 0 |

`su` variants worth knowing precisely, because the difference is examined:

| Command | UID | Environment | Working directory |
|---|---|---|---|
| `su` | root | **Inherits** the caller's environment (except `PATH`/`IFS` per PAM) | Unchanged |
| `su -` / `su -l` / `su --login` | root | **Login shell**: full reset, reads root's `~/.bash_profile`, sets root's `PATH` | `/root` |
| `su - alice` | alice | Login shell as alice | `/home/alice` |
| `su -c 'cmd' alice` | alice | Non-login | Unchanged |
| `sudo -s` | root | Runs `$SHELL` as root, **non**-login (subject to `env_reset`) | Unchanged |
| `sudo -i` | root | Simulated **initial login**: root's environment and `PATH`, runs root's profile | `/root` |
| `sudo -u www-data cmd` | www-data | `env_reset` applies | Unchanged |

The classic operational symptom: a script works under `su -` and fails under `su`, because `su` kept the caller's `PATH` and `/usr/sbin` is not on it. Always use `su -` (or `sudo -i`) when you want root's environment.

### 3.2 The sudoers grammar

`/etc/sudoers` is parsed by `sudo`'s policy plugin. The rule line has a fixed shape:

```
who      where = (as-whom : as-which-group)   TAGS: what
alice    ALL   = (root)                       NOPASSWD: /bin/systemctl restart nginx.service
```

| Field | Meaning | Example values |
|---|---|---|
| `who` | User, `%group`, `#uid`, `%#gid`, `+netgroup`, or a `User_Alias` | `alice`, `%wheel`, `%sudo`, `#1001` |
| `where` | Host the rule applies on, or a `Host_Alias` | `ALL`, `web01`, `10.20.4.0/24` |
| `(runas)` | Target user, optionally `:group` | `(root)`, `(ALL:ALL)`, `(postgres)` |
| `TAGS` | `NOPASSWD:`, `PASSWD:`, `NOEXEC:`, `SETENV:`, `LOG_INPUT:`, `LOG_OUTPUT:` | |
| `what` | Absolute command path(s) with optional arguments, or a `Cmnd_Alias` | `ALL`, `/usr/bin/systemctl status *` |

Aliases give the file structure:

```sudoers
User_Alias   SRE          = alice, bob, carol
User_Alias   DBA          = dave, erin
Runas_Alias  APPUSERS     = www-data, appsvc
Host_Alias   WEBTIER      = web01, web02, web03
Cmnd_Alias   SVC_READ     = /usr/bin/systemctl status *, \
                            /usr/bin/systemctl is-active *, \
                            /usr/bin/journalctl
Cmnd_Alias   SVC_RESTART  = /usr/bin/systemctl restart nginx.service, \
                            /usr/bin/systemctl reload nginx.service
```

**Order matters: the last matching rule wins.** This is the opposite of a firewall's first-match and is a frequent source of accidental grants.

```sudoers
alice ALL = (ALL) ALL
alice ALL = (ALL) /bin/ls        # alice can now ONLY run /bin/ls — the second line wins
```

### 3.3 A complete, production-grade sudoers layout

Never edit `/etc/sudoers` for policy. Ship drop-in files into `/etc/sudoers.d/`; the main file includes the directory:

```sudoers
# /etc/sudoers  — vendor file, edited only via `visudo`
Defaults   env_reset
Defaults   mail_badpass
Defaults   secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

root       ALL=(ALL:ALL) ALL
%sudo      ALL=(ALL:ALL) ALL

@includedir /etc/sudoers.d
```

> `@includedir` is the syntax from sudo 1.9.1 onward. `#includedir` is the historical spelling and is still accepted — note that despite starting with `#` it is **not** a comment. Files in the directory are skipped if they contain a `.` or end in `~`, which is how `foo.bak` silently stops applying.

```sudoers
# /etc/sudoers.d/00-defaults        mode 0440, root:root
#
# Hardening defaults applied before any grant. Numeric prefix fixes ordering:
# sudo reads sudoers.d entries in lexical order and the last match wins.

Defaults    env_reset
Defaults    secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults    env_keep += "LANG LC_* http_proxy https_proxy no_proxy"

# Credential caching: per-TTY, 5 minutes. `tty` prevents one terminal's
# authentication from silently authorising a command in another.
Defaults    timestamp_type=tty
Defaults    timestamp_timeout=5
Defaults    passwd_timeout=1

# Allocate a pty for the command. Without this, a backgrounded child of a sudo
# command keeps running on the caller's terminal after sudo exits and can inject
# input into it (TIOCSTI-class attacks). Default since sudo 1.9.14; assert it.
Defaults    use_pty

# Structured logging to journald in addition to syslog.
Defaults    syslog=authpriv
Defaults    log_year, log_host
Defaults    logfile="/var/log/sudo.log"

# Lockout hygiene: three tries, then a distinctive message that greps well.
Defaults    passwd_tries=3
Defaults    badpass_message="Authentication failure — this attempt has been logged."

# Do not let sudo hang for 5–30 s resolving an unqualified hostname.
Defaults    !fqdn
```

```sudoers
# /etc/sudoers.d/20-sre-oncall      mode 0440, root:root
#
# On-call SRE grant. Scoped to service lifecycle operations on the web tier.
# Deliberately NOT `(ALL) ALL`: see the escape-hatch analysis in 3.6.

User_Alias   SRE_ONCALL  = alice, bob, carol
Host_Alias   WEBTIER     = web01, web02, web03, web04

Cmnd_Alias   SVC_READ    = /usr/bin/systemctl status *,       \
                           /usr/bin/systemctl is-active *,    \
                           /usr/bin/systemctl is-enabled *,   \
                           /usr/bin/systemctl list-units *,   \
                           /usr/bin/journalctl

Cmnd_Alias   SVC_WRITE   = /usr/bin/systemctl start nginx.service,   \
                           /usr/bin/systemctl stop nginx.service,    \
                           /usr/bin/systemctl restart nginx.service, \
                           /usr/bin/systemctl reload nginx.service

Cmnd_Alias   DIAG        = /usr/bin/ss, /usr/sbin/ss,               \
                           /usr/bin/lsof, /usr/bin/dmesg,           \
                           /usr/bin/tcpdump -i * -w /var/tmp/*.pcap

# Read-only diagnostics: no password, so a pager alert can be triaged in seconds.
SRE_ONCALL   WEBTIER = (root) NOPASSWD: SVC_READ, DIAG

# State-changing operations: password required, full I/O session recorded.
SRE_ONCALL   WEBTIER = (root) PASSWD: LOG_INPUT: LOG_OUTPUT: SVC_WRITE

# Application-user shell for debugging, recorded. NOEXEC blocks the LD_PRELOAD
# exec() shim that lets a permitted program spawn an unpermitted child.
SRE_ONCALL   WEBTIER = (www-data) NOEXEC: /usr/bin/php -r *

Defaults:SRE_ONCALL  iolog_dir=/var/log/sudo-io/%{user}
Defaults:SRE_ONCALL  iolog_file=%{seq}
```

```sudoers
# /etc/sudoers.d/30-deploy-automation   mode 0440, root:root
#
# Machine identity used by the deployment agent. No TTY (it runs from a systemd
# unit), so requiretty must be off for this user; the grant is a single exact
# command with no wildcard in a position that could be abused.

Defaults:deploy    !requiretty
Defaults:deploy    !syslog          # this unit already logs to journald under its own name
Defaults:deploy    log_output

deploy  ALL = (root) NOPASSWD: /usr/local/sbin/deploy-release.sh
deploy  ALL = (root) NOPASSWD: /usr/bin/systemctl daemon-reload
```

### 3.4 Editing safely

**Never open `/etc/sudoers` in a plain editor.** A syntax error makes `sudo` refuse to run *at all*, and on a host with no root password and no console you have locked yourself out.

```
$ sudo visudo
```

`visudo` takes a lock, opens `$SUDO_EDITOR`/`$VISUAL`/`$EDITOR`, and refuses to install a file that fails the parser:

```
>>> /etc/sudoers: syntax error near line 22 <<<
What now?
Options are:
  (e)dit sudoers file again
  e(x)it without saving changes to sudoers file
  (Q)uit and save changes to sudoers file (DANGER!)

What now? e
```

For drop-ins and for CI:

```
$ sudo visudo -cf /etc/sudoers.d/20-sre-oncall
/etc/sudoers.d/20-sre-oncall: parsed OK

$ sudo visudo -f /etc/sudoers.d/20-sre-oncall     # edit a specific file, locked and validated

$ sudo visudo -c                                   # validate the whole tree
/etc/sudoers: parsed OK
/etc/sudoers.d/00-defaults: parsed OK
/etc/sudoers.d/20-sre-oncall: parsed OK
/etc/sudoers.d/30-deploy-automation: parsed OK
```

Permissions are enforced by sudo itself — `0440`, owned `root:root`. A world-writable sudoers file is refused:

```
$ sudo -l
sudo: /etc/sudoers.d/20-sre-oncall is mode 0640, should be 0440
sudo: no valid sudoers sources found, quitting
```

### 3.5 Using and inspecting sudo

```
$ sudo -l
Matching Defaults entries for alice on web01:
    env_reset, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin,
    timestamp_type=tty, timestamp_timeout=5, use_pty, !fqdn,
    iolog_dir=/var/log/sudo-io/alice

User alice may run the following commands on web01:
    (root) NOPASSWD: /usr/bin/systemctl status *, /usr/bin/systemctl is-active *,
        /usr/bin/journalctl, /usr/bin/ss, /usr/bin/lsof, /usr/bin/dmesg
    (root) LOG_INPUT: LOG_OUTPUT: /usr/bin/systemctl start nginx.service,
        /usr/bin/systemctl stop nginx.service, /usr/bin/systemctl restart nginx.service
    (www-data) NOEXEC: /usr/bin/php -r *
```

```
$ sudo -l -U bob            # what may *bob* do? (requires privilege yourself)
$ sudo -ll                  # long form, one rule per stanza with source file
$ sudo -v                   # refresh the credential cache without running anything
$ sudo -k                   # invalidate the cache (next sudo will prompt)
$ sudo -K                   # remove the timestamp record entirely
$ sudo -u postgres psql     # run as another user
$ sudo -g docker id         # run with another primary group
$ sudo -H -u www-data env | grep HOME
HOME=/var/www
$ sudo -b /usr/local/sbin/long-job.sh    # detach into the background
$ sudoedit /etc/nginx/nginx.conf         # edit as root with YOUR editor, safely (see 3.6)
```

A denial, and what it writes:

```
$ sudo systemctl restart postgresql
[sudo] password for alice:
Sorry, user alice is not allowed to execute '/usr/bin/systemctl restart postgresql'
as root on web01.
```

```
$ sudo journalctl -t sudo -n 3 -o cat
alice : TTY=pts/1 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/systemctl restart nginx.service
alice : command not allowed ; TTY=pts/1 ; PWD=/home/alice ; USER=root ;
    COMMAND=/usr/bin/systemctl restart postgresql
alice : 3 incorrect password attempts ; TTY=pts/1 ; PWD=/home/alice ; USER=root ;
    COMMAND=/bin/bash
```

Session replay, when `log_output` is set:

```
$ sudo sudoreplay -l user alice
Aug 31 12:04:11 2026 : alice : TTY=/dev/pts/1 ; CWD=/home/alice ; USER=root ;
    TSID=000004 ; COMMAND=/usr/bin/systemctl restart nginx.service

$ sudo sudoreplay -s 4 000004      # replay at 4x speed
```

### 3.6 The failure modes that matter

**Escape hatches.** A sudoers rule grants a *program*, but many programs grant a *shell*. Every entry below is a full root shell for a user who was only given one command:

| Granted command | Escape |
|---|---|
| `/usr/bin/vi`, `vim`, `less`, `more`, `man` | `:!/bin/sh` or `!/bin/sh` from the pager |
| `/usr/bin/find` | `sudo find . -exec /bin/sh \; -quit` |
| `/usr/bin/tar` | `sudo tar -cf /dev/null /dev/null --checkpoint=1 --checkpoint-action=exec=/bin/sh` |
| `/usr/bin/awk`, `perl`, `python3`, `ruby` | `system("/bin/sh")` |
| `/usr/bin/systemctl` (unrestricted) | Write a unit with `ExecStart=/bin/sh`, `systemctl link` + `start` |
| `/usr/bin/journalctl` without a pager env reset | pager escape (`!sh`) — mitigate with `SYSTEMD_PAGER=cat` or `--no-pager` |
| `/bin/cp`, `/usr/bin/dd`, `/usr/bin/tee` | Overwrite `/etc/shadow` or `/etc/sudoers` |

Catalogue: **GTFOBins** (`https://gtfobins.github.io/`) is the reference; treat it as the adversary's copy of your sudoers file. The mitigations are `NOEXEC:` (blocks `exec()` from the permitted program via an `LD_PRELOAD` shim — effective only for dynamically linked binaries), `sudoedit` instead of granting an editor, and preferring purpose-built wrapper scripts over general-purpose tools.

**Wildcards do not do what they look like they do.** `sudo`'s command matching uses `fnmatch(3)`-style globs where `*` matches `/` as well:

```sudoers
# BROKEN — intends "restart any service"
alice ALL = (root) NOPASSWD: /usr/bin/systemctl restart *
```
```
$ sudo systemctl restart ../../../home/alice/evil.service   # matched by `*`
```

```sudoers
# BROKEN — intends "edit files under /etc/nginx"
alice ALL = (root) NOPASSWD: /usr/bin/vim /etc/nginx/*
```
```
$ sudo vim /etc/nginx/../../etc/shadow                       # matched
```

Enumerate exact commands, or validate arguments inside a root-owned wrapper script that the user cannot modify. If you must glob, keep the wildcard out of any position where `..` or `/` changes the target.

**A writable wrapper is a root shell.** If `deploy-release.sh` is granted `NOPASSWD` and is writable by the `deploy` user, the grant is `(root) ALL`. Wrapper scripts must be `root:root 0755` and live outside any user-writable directory.

**`Defaults targetpw` / `runaspw` inverts the credential model** — it makes sudo prompt for the *target* user's password. Combined with `%users ALL=(ALL) ALL` this is how some distributions historically emulated `su`. Know it exists; it is rarely what you want, because it reintroduces the shared secret.

**Known high-severity sudo CVEs** (all fixed; the lesson is that sudo is privileged parsing code and must be patched promptly):

| CVE | Class | Effect |
|---|---|---|
| CVE-2019-14287 | Runas UID parsing | With a `(ALL, !root)` rule, `sudo -u#-1 <cmd>` executed as UID 0 anyway |
| CVE-2021-3156 ("Baron Samedit") | Heap overflow in `sudoedit` argv unescaping | Local root **for any local user**, no sudoers entry required. Affected 1.8.2–1.8.31p2 and 1.9.0–1.9.5p1 |
| CVE-2023-22809 | `sudoedit` `EDITOR` handling | `EDITOR='vi -- /etc/sudoers'` wrote to an arbitrary file; fixed in 1.9.12p2 |

```
$ sudo --version | head -1
Sudo version 1.9.15p5
```

Track advisories at `https://www.sudo.ws/security/advisories/`. Pin a minimum version in your compliance baseline and alert on nodes below it.

---

## 4. Account and password lifecycle

### 4.1 `/etc/shadow` — the record behind every command in this section

`/etc/passwd` is world-readable and holds no secret (field 2 is `x`). `/etc/shadow` is mode `0000` or `0640 root:shadow` and holds nine colon-separated fields:

```
$ sudo getent shadow alice
alice:$y$j9T$Xn2cW1qL8vB4mR7pKdZ0e.$Qv3...:20678:1:90:14:14::
```

| # | Field | Value above | Meaning | `chage` flag | `passwd` flag |
|---|---|---|---|---|---|
| 1 | Login name | `alice` | — | — | — |
| 2 | Hash | `$y$...` | `$y$` yescrypt, `$6$` sha512crypt, `$2b$` bcrypt. `!`/`!!` prefix = locked, `*` = no password login ever, empty = **no password required** | — | `-l` / `-u` |
| 3 | Last change | `20678` | Days since 1970-01-01. `0` = must change at next login | `-d` | `-e` (expire now) |
| 4 | MIN | `1` | Days before the password *may* be changed again — stops a user cycling back to the old one immediately | `-m` | `-n` |
| 5 | MAX | `90` | Days after which the password *must* change | `-M` | `-x` |
| 6 | WARN | `14` | Days of warning before expiry | `-W` | `-w` |
| 7 | INACTIVE | `14` | Grace days after expiry during which login still works but forces a change; then the account is disabled | `-I` | `-i` |
| 8 | EXPIRE | *(empty)* | Absolute account expiry, days since epoch. Independent of the password | `-E` | — |
| 9 | Reserved | *(empty)* | Unused | — | — |

Date conversion, which you will need when reading a raw shadow entry:

```
$ date -d "1970-01-01 + 20678 days" +%F
2026-08-12
$ echo $(( ($(date +%s) / 86400) ))
20693
```

### 4.2 Setting and changing passwords

```
$ passwd                                   # change your own
Changing password for user alice.
Current password:
New password:
Retype new password:
passwd: all authentication tokens updated successfully.

$ sudo passwd bob                          # change another user's (root only)
$ sudo passwd -S bob                       # status
bob P 08/12/2026 1 90 14 14

$ sudo passwd -Sa | column -t              # every account
root    L  01/15/2026  0  99999  7  -1
daemon  L  01/15/2026  0  99999  7  -1
alice   P  08/12/2026  1  90     14 14
bob     P  08/12/2026  1  90     14 14
svc_app NP 07/03/2026  0  99999  7  -1
deploy  L  07/03/2026  0  99999  7  -1
```

The status column: `P` = usable password, `L` = locked, `NP` = **no password at all**. An `NP` on any account is a finding — that account logs in with an empty string.

Lifecycle operations:

```
$ sudo passwd -l bob          # lock: prepend '!' to the hash
$ sudo passwd -u bob          # unlock
$ sudo passwd -e bob          # force a change at next login (sets field 3 to 0)
$ sudo passwd -d bob          # DELETE the password — leaves an empty field. Never do this.
$ sudo usermod -L bob         # equivalent lock
$ sudo usermod -U bob         # equivalent unlock
```

Non-interactive setting, for provisioning:

```
$ echo 'bob:S0me-Long-Passphrase' | sudo chpasswd

# Preferred: never let a cleartext password reach a command line or a log.
$ HASH=$(openssl passwd -6 -stdin <<< 'S0me-Long-Passphrase')
$ echo "bob:${HASH}" | sudo chpasswd -e

$ mkpasswd --method=yescrypt        # from the whois/debian package; prompts, no argv leak
Password:
$y$j9T$K1sT9pQ.../...
```

> **The single most consequential gotcha in this objective:** `passwd -l` and `usermod -L` disable **password** authentication only. A user with an SSH public key in `~/.ssh/authorized_keys` still logs in. To actually disable an account:
>
> ```
> $ sudo usermod -L bob                                    # lock the password
> $ sudo chage -E "$(date -d yesterday +%F)" bob           # expire the account (PAM account phase)
> $ sudo usermod -s /usr/sbin/nologin bob                  # no shell
> $ sudo pkill -KILL -u bob                                # terminate live sessions
> ```
>
> Use an explicit past date with `-E`; the literal value `0` is ambiguous across shadow-utils versions (it can be read as "unset"). `chage -E -1` means *never expire*.

### 4.3 `chage` — password aging

```
$ sudo chage -l alice
Last password change                                    : Aug 12, 2026
Password expires                                        : Nov 10, 2026
Password inactive                                       : Nov 24, 2026
Account expires                                         : never
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

```
$ sudo chage -m 1 -M 90 -W 14 -I 14 alice          # the standard policy, non-interactively
$ sudo chage -E 2027-03-31 contractor              # hard account expiry for a fixed-term account
$ sudo chage -d 0 newhire                          # force a password change at first login
$ sudo chage -M -1 svc_app                         # disable aging (service account; see below)
$ sudo chage alice                                 # interactive form
Changing the aging information for alice
Enter the new value, or press ENTER for the default
        Minimum Password Age [1]:
        Maximum Password Age [90]:
        Last Password Change (YYYY-MM-DD) [2026-08-12]:
        Password Expiration Warning [14]:
        Password Inactive [14]:
        Account Expiration Date (YYYY-MM-DD) [-1]:
```

**Aging policy for service accounts is a real production trade-off:**

| Approach | Consequence |
|---|---|
| Apply the human policy (`-M 90`) to service accounts | Batch jobs fail silently at day 91 with no interactive prompt to answer. Classic 03:00 page. |
| `chage -M -1` (no aging) on service accounts | Correct — **provided** the account has no password at all (`!` in shadow) and authenticates by key or runs as a systemd `User=` with no login path. |
| Set the shell to `/usr/sbin/nologin` and lock the password | Correct and the standard: the account cannot log in, so aging is meaningless. |

The declarative check is: *does this account have an interactive login path?* If yes, age it. If no, lock it and disable aging.

### 4.4 Defaults for new accounts: `/etc/login.defs` and `/etc/default/useradd`

```ini
# /etc/login.defs  (excerpt — applies at useradd/passwd time)
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14

UID_MIN         1000
UID_MAX         60000
SYS_UID_MIN     201
SYS_UID_MAX     999

CREATE_HOME     yes
UMASK           027           # 0750 dirs / 0640 files — not the permissive 022 default
USERGROUPS_ENAB yes

ENCRYPT_METHOD  YESCRYPT
YESCRYPT_COST_FACTOR 7
# For SHA512 systems instead:
# ENCRYPT_METHOD SHA512
# SHA_CRYPT_MIN_ROUNDS 640000

LOGIN_RETRIES   3
LOGIN_TIMEOUT   60
FAILLOG_ENAB    yes
LOG_UNKFAIL_ENAB no          # do NOT log unknown usernames: mistyped passwords land in the log
```

```
$ useradd -D
GROUP=100
HOME=/home
INACTIVE=14
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=no

$ sudo useradd -D -f 14                    # set the default INACTIVE for new accounts
```

> **Gotcha:** `login.defs` values apply **only to accounts created after the change**. Editing `PASS_MAX_DAYS` does nothing to existing users. Remediating an existing fleet requires an explicit `chage` sweep — the Ansible task in §8 does this.

### 4.5 Password quality and lockout (PAM) — beyond the exam, required in production

`chage` controls *when* a password must change. It says nothing about *what* the new password may be, and nothing about brute force. Both live in PAM.

```ini
# /etc/security/pwquality.conf
minlen      = 14
minclass    = 3
maxrepeat   = 3
maxsequence = 4
dictcheck   = 1
usercheck   = 1
enforcing   = 1
retry       = 3
# Credit-based scoring is legacy; minclass expresses the intent more clearly.
dcredit     = 0
ucredit     = 0
lcredit     = 0
ocredit     = 0
```

```ini
# /etc/security/faillock.conf   (pam_faillock — replaces the removed pam_tally2)
deny             = 5
fail_interval    = 900
unlock_time      = 900
even_deny_root
root_unlock_time = 60
audit
silent
```

```
$ faillock --user alice
alice:
When                Type  Source                                           Valid
2026-08-31 12:11:04 RHOST 10.20.4.9                                            V
2026-08-31 12:11:09 RHOST 10.20.4.9                                            V

$ sudo faillock --user alice --reset
```

Do not hand-edit the PAM stack; use the distribution's tool, or the change is reverted by the next `authselect`/`pam-auth-update` run:

```
$ sudo authselect select sssd with-faillock with-pwquality --force   # RHEL/Fedora
$ sudo pam-auth-update                                                # Debian/Ubuntu
```

---

## 5. Limits on logins, processes, and memory

### 5.1 The three enforcement layers

This is the section where the exam's model and production reality diverge most sharply.

| Layer | Configured in | Enforced by | Applies to | Granularity | Survives reboot |
|---|---|---|---|---|---|
| **`ulimit` (shell)** | `ulimit -n 4096` in a shell or profile script | `setrlimit(2)`, inherited by children | The current shell and its descendants only | Per process | No |
| **`/etc/security/limits.conf`, `limits.d/*.conf`** | Declarative file | `pam_limits.so` in the PAM session stack | Any process started through a **PAM session** (login, sshd, su, sudo, cron with `pam_limits`) | Per user / per group / per process | Yes |
| **systemd unit directives** | `LimitNOFILE=`, `TasksMax=`, `MemoryMax=` | systemd, via `setrlimit` + cgroup v2 | The service's cgroup, all its processes together | Per unit / per slice | Yes |
| **cgroup v2 directly** | `/sys/fs/cgroup/.../memory.max` | Kernel | The cgroup | Per cgroup, aggregate | No (unless via systemd) |

> **The failure that costs people a night:** `limits.conf` has **no effect whatsoever on a systemd service**. `pam_limits` runs during a PAM session; `systemd` starts services without one. Raising `nofile` in `limits.conf` and restarting PostgreSQL changes nothing. The service needs `LimitNOFILE=` in its unit. Every "I raised the limit and it didn't apply" ticket is this.

### 5.2 `ulimit`

`ulimit` is a **shell builtin** (`help ulimit`, not `man ulimit` — the man page you get is the `setrlimit(2)`/`bash` one). Each resource has a **soft** limit (the enforced value, raisable by the user up to the hard limit) and a **hard** limit (the ceiling; **an unprivileged process can only lower it, never raise it — irreversibly for that process tree**).

```
$ ulimit -a
real-time non-blocking time  (microseconds, -R) unlimited
core file size              (blocks, -c) 0
data seg size               (kbytes, -d) unlimited
scheduling priority                 (-e) 0
file size                   (blocks, -f) unlimited
pending signals                     (-i) 63256
max locked memory           (kbytes, -l) 8192
max memory size             (kbytes, -m) unlimited
open files                          (-n) 1024
pipe size                (512 bytes, -p) 8
POSIX message queues         (bytes, -q) 819200
real-time priority                  (-r) 0
stack size                  (kbytes, -s) 8192
cpu time                   (seconds, -t) unlimited
max user processes                  (-u) 63256
virtual memory              (kbytes, -v) unlimited
file locks                          (-x) unlimited
```

```
$ ulimit -Hn          # hard limit for open files
524288
$ ulimit -Sn          # soft limit
1024
$ ulimit -n 8192      # raise the SOFT limit (allowed: 8192 <= 524288)
$ ulimit -n
8192
$ ulimit -Hn 4096     # lower the HARD limit
$ ulimit -Hn 8192     # try to raise it back
bash: ulimit: open files: cannot modify limit: Operation not permitted
```

| Flag | Resource | `limits.conf` item | Typical production use |
|---|---|---|---|
| `-n` | Max open file descriptors | `nofile` | The one you will change most; sockets count as fds |
| `-u` | Max user processes (per **real UID**, system-wide) | `nproc` | Fork-bomb containment |
| `-v` | Max virtual address space (KiB) | `as` | Crude memory cap; hostile to JVMs and anything using large `mmap` reservations |
| `-m` | Max RSS (KiB) | `rss` | **Not enforced on modern Linux** — use cgroups |
| `-s` | Max stack size (KiB) | `stack` | Deep recursion; too large hurts thread-heavy processes |
| `-c` | Max core dump size (blocks) | `core` | `0` to prevent secrets from reaching disk; non-zero when you need the dump |
| `-f` | Max file size a process may create (blocks) | `fsize` | Runaway-log containment |
| `-l` | Max locked-in memory (KiB) | `memlock` | Required by databases using `mlock`, and by RDMA |
| `-t` | Max CPU seconds | `cpu` | Batch job guard; sends `SIGXCPU` |
| `-i` | Pending signals | `sigpending` | Rarely tuned |
| `-x` | File locks | `locks` | Rarely tuned |
| `-H` / `-S` | Operate on hard / soft | — | Default for *setting* is both; default for *reading* is soft |

### 5.3 `/etc/security/limits.conf`

Four whitespace-separated fields:

```
<domain>    <type>    <item>    <value>
```

| Field | Accepted values |
|---|---|
| `domain` | `username`, `@groupname`, `*` (default for everyone **not** otherwise matched), `%group` (maxlogins per group), `uid`, `@gid`, `uid_range` like `1000:2000` |
| `type` | `soft`, `hard`, `-` (both) |
| `item` | `core fsize data stack rss nofile nproc as maxlogins maxsyslogins priority locks sigpending msgqueue nice rtprio memlock` |
| `value` | A number, or `unlimited` / `infinity` / `-1` |

```ini
# /etc/security/limits.d/50-baseline.conf
#
# Matching is NOT last-wins and NOT first-wins uniformly: pam_limits applies the
# most specific matching domain. An explicit username beats @group, which beats *.
# Files in limits.d are read in lexical order AFTER limits.conf.

# Fleet default: contain a fork bomb, keep core dumps off disk.
*               soft    nproc           2048
*               hard    nproc           4096
*               soft    nofile          4096
*               hard    nofile          16384
*               -       core            0
*               hard    maxlogins       10

# Interactive engineers need headroom for tooling.
@sre            soft    nofile          16384
@sre            hard    nofile          65536
@sre            soft    nproc           8192
@sre            hard    nproc           16384

# Database service account: file descriptors and locked memory.
postgres        soft    nofile          65536
postgres        hard    nofile          131072
postgres        -       memlock         unlimited
postgres        -       nproc           unlimited

# Untrusted batch tenants: hard aggregate ceilings.
@batch          hard    nproc           256
@batch          hard    nofile          2048
@batch          hard    cpu             60
@batch          hard    as              4194304
@batch          -       maxlogins       2

# Shared shell host: one session per contractor, no lingering.
@contractors    -       maxlogins       1
```

Enforcement requires `pam_limits.so` in the session stack:

```
$ grep -r pam_limits /etc/pam.d/
/etc/pam.d/system-auth:session     required      pam_limits.so
/etc/pam.d/password-auth:session   required      pam_limits.so
/etc/pam.d/su:session              required      pam_limits.so
/etc/pam.d/runuser:session         required      pam_limits.so
```

If `pam_limits.so` is missing from the stack that a given entry path uses, that path gets no limits. `sshd` uses `password-auth`/`common-session`; `login` uses `system-auth`; `cron` uses `/etc/pam.d/crond`. Verify per path, not globally.

> **`nproc` counts by real UID across the whole system,** not per session. A user with `nproc 256` who is already running 250 processes in another SSH session will see the next `fork()` fail in *this* one. This asymmetry is why `TasksMax=` (a cgroup pids controller limit, scoped to the unit) is the better tool for services.

### 5.4 systemd — the layer that actually governs services

```ini
# /etc/systemd/system/api.service
[Unit]
Description=Public API
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=apiuser
Group=apiuser
ExecStart=/usr/local/bin/api --config /etc/api/config.yaml
Restart=on-failure
RestartSec=5s

# --- rlimits: the systemd equivalent of limits.conf, and the ONLY one that
#     applies to this process, because systemd does not open a PAM session.
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
LimitMEMLOCK=64M
LimitSTACK=8M

# --- cgroup v2 controls: aggregate, hierarchical, and observable.
TasksMax=512
MemoryHigh=1.5G          # soft: reclaim pressure begins here
MemoryMax=2G             # hard: the cgroup OOM killer fires here
MemorySwapMax=0
CPUQuota=200%            # two cores' worth
CPUWeight=100
IOWeight=100

# --- privilege containment: this is the SUID discussion from §2, per service.
NoNewPrivileges=yes
RestrictSUIDSGID=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/api /var/log/api
StateDirectory=api
LogsDirectory=api

[Install]
WantedBy=multi-user.target
```

Verification and measurement:

```
$ systemctl show api.service -p LimitNOFILE -p TasksMax -p MemoryMax
LimitNOFILE=65536
TasksMax=512
MemoryMax=2147483648

$ systemctl status api.service | head -12
● api.service - Public API
     Loaded: loaded (/etc/systemd/system/api.service; enabled; preset: disabled)
     Active: active (running) since Sun 2026-08-30 04:11:52 -03; 1 day 8h ago
   Main PID: 1841 (api)
      Tasks: 37 (limit: 512)
     Memory: 812.4M (high: 1.5G, max: 2.0G available: 1.2G)
        CPU: 4h 21min 8.114s
     CGroup: /system.slice/api.service
             └─1841 /usr/local/bin/api --config /etc/api/config.yaml

$ cat /proc/1841/limits | grep -E 'Max open|Max processes'
Max open files            65536                65536                files
Max processes             4096                 4096                 processes

$ systemd-cgtop -1 /system.slice/api.service
CGroup                    Tasks   %CPU   Memory  Input/s Output/s
/system.slice/api.service    37    12.4   812.4M        -        -

$ systemd-analyze security api.service | tail -3
→ Overall exposure level for api.service: 1.9 OK 🙂
```

Fleet-wide defaults, so you set the policy once rather than per unit:

```ini
# /etc/systemd/system.conf.d/10-limits.conf
[Manager]
DefaultLimitNOFILE=8192:524288      # soft:hard
DefaultLimitNPROC=4096:16384
DefaultLimitCORE=0
DefaultTasksMax=4096
```

```ini
# /etc/systemd/user.conf.d/10-limits.conf   — applies to user@UID.service sessions
[Manager]
DefaultLimitNOFILE=4096:65536
DefaultTasksMax=1024
```

```ini
# /etc/systemd/system/user-.slice.d/50-batch-tenant.conf
# Caps ALL processes of ANY logged-in user, aggregate, in one place.
[Slice]
TasksMax=1024
MemoryMax=8G
CPUQuota=400%
```

Kernel ceilings that bound everything above — you cannot set `nofile` higher than `fs.nr_open`:

```ini
# /etc/sysctl.d/60-limits.conf
fs.file-max = 2097152
fs.nr_open  = 1048576
kernel.pid_max = 4194304
kernel.threads-max = 512000
```

```
$ sudo sysctl --system
$ sysctl fs.nr_open fs.file-max
fs.nr_open = 1048576
fs.file-max = 2097152
$ cat /proc/sys/fs/file-nr
14208	0	2097152
```

### 5.5 Limiting logins themselves

```ini
# /etc/security/limits.d/60-logins.conf
@contractors    -    maxlogins       1      # concurrent sessions for one user
*               -    maxsyslogins    50     # concurrent logins on the whole system
```

```ini
# /etc/security/access.conf  — pam_access: WHO may log in, from WHERE
+ : root : LOCAL
+ : @sre : 10.20.0.0/16
+ : deploy : 10.20.9.14
- : ALL : ALL
```

```
# /etc/nologin — while this file exists, pam_nologin blocks all non-root logins
$ echo "Maintenance window until 04:00 UTC. Contact #sre-oncall." | sudo tee /etc/nologin
$ sudo rm /etc/nologin
```

```
$ sudo loginctl enable-linger alice     # allow alice's user services to persist after logout
$ sudo loginctl disable-linger alice    # and to be killed on logout (the hardened default)
```

---

## 6. Discovering open ports and network exposure

### 6.1 Local versus remote: two different questions

Two questions that people conflate, with different tools and different answers:

- **"What is this host listening on?"** — answered *on* the host, authoritatively, from the kernel: `ss`, `netstat`, `lsof`, `fuser`. Gives you the process, the user, and the bind address.
- **"What is reachable from over there?"** — answered *from* the network: `nmap`. This is what an attacker sees, and it differs from the first answer by exactly your firewall, your security group, and your NAT.

A service bound to `0.0.0.0:9100` that `nmap` reports as `filtered` from another subnet is correctly firewalled. A service bound to `127.0.0.1:9100` that `nmap` reports as `open` from another subnet means something is proxying it and you did not know. **You need both readings to have an exposure statement.**

### 6.2 Local enumeration

`netstat` (package `net-tools`) is deprecated and often absent on a minimal install; it parses `/proc/net/*` as text. `ss` (package `iproute2`) queries the kernel over the `sock_diag` netlink interface — orders of magnitude faster on a host with 100k sockets, and it exposes TCP internals `netstat` cannot see.

| Tool | Source | Shows PID | Speed at 100k sockets | Notes |
|---|---|---|---|---|
| `netstat -tulpn` | `/proc/net/*` text | Yes (as root) | Slow; O(n) text parsing per socket for the inode→PID map | **Exam-required.** Deprecated upstream |
| `ss -tulpn` | netlink `sock_diag` | Yes (as root) | Fast | Production default. Supports state filters and BPF-style expressions |
| `lsof -i` | `/proc/*/fd` walk | Yes | Slow; opens every process's fd table | Best when you want *files and sockets together* for a process |
| `fuser -n tcp 443` | `/proc` | Yes | Fast for one port | Answers "who has this port" and can `-k` kill them |
| `nmap localhost` | The network stack | No | — | Only sees what the loopback path allows; not an inventory tool |

```
$ sudo ss -tulpn
Netid State  Recv-Q Send-Q      Local Address:Port    Peer Address:Port  Process
udp   UNCONN 0      0           127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=612,fd=13))
udp   UNCONN 0      0                 0.0.0.0:68           0.0.0.0:*      users:(("dhclient",pid=744,fd=6))
tcp   LISTEN 0      4096        127.0.0.53%lo:53           0.0.0.0:*      users:(("systemd-resolve",pid=612,fd=14))
tcp   LISTEN 0      128               0.0.0.0:22           0.0.0.0:*      users:(("sshd",pid=812,fd=3))
tcp   LISTEN 0      511               0.0.0.0:80           0.0.0.0:*      users:(("nginx",pid=1102,fd=6),("nginx",pid=1101,fd=6))
tcp   LISTEN 0      511               0.0.0.0:443          0.0.0.0:*      users:(("nginx",pid=1102,fd=7),("nginx",pid=1101,fd=7))
tcp   LISTEN 0      244             127.0.0.1:5432         0.0.0.0:*      users:(("postgres",pid=1330,fd=5))
tcp   LISTEN 0      4096              0.0.0.0:9100         0.0.0.0:*      users:(("node_exporter",pid=1455,fd=3))
tcp   LISTEN 0      128                  [::]:22              [::]:*      users:(("sshd",pid=812,fd=4))
```

```
$ sudo netstat -tulpn        # exam form, identical intent
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address       Foreign Address   State    PID/Program name
tcp        0      0 0.0.0.0:22          0.0.0.0:*         LISTEN   812/sshd: /usr/sbin
tcp        0      0 0.0.0.0:80          0.0.0.0:*         LISTEN   1101/nginx: master
tcp        0      0 127.0.0.1:5432      0.0.0.0:*         LISTEN   1330/postgres
tcp6       0      0 :::22               :::*              LISTEN   812/sshd: /usr/sbin
udp        0      0 127.0.0.53:53       0.0.0.0:*                  612/systemd-resolve
```

The flag letters — memorize these, they are asked directly:

| Flag | `netstat` | `ss` | Meaning |
|---|---|---|---|
| `-t` | ✓ | ✓ | TCP |
| `-u` | ✓ | ✓ | UDP |
| `-x` | ✓ | ✓ | UNIX domain sockets |
| `-l` | ✓ | ✓ | Listening sockets only |
| `-a` | ✓ | ✓ | All sockets (listening **and** established) |
| `-p` | ✓ | ✓ | Show the owning process (needs root for other users' sockets) |
| `-n` | ✓ | ✓ | Numeric — no DNS or `/etc/services` lookup. **Always use it**; a reverse-DNS timeout will hang the command |
| `-r` | ✓ | — | Routing table (`ss` has no equivalent; use `ip route`) |
| `-i` | ✓ | — | Interface statistics (use `ip -s link`) |
| `-s` | ✓ | ✓ | Summary statistics |
| `-c` | ✓ | — | Continuous refresh |

`ss` capabilities with no `netstat` equivalent:

```
$ ss -tan state established '( dport = :443 or sport = :443 )'
$ ss -tn dst 10.20.4.0/24
$ ss -ti sport = :443 | head -4          # per-socket TCP internals: cwnd, rtt, retrans
$ ss -tlpn 'sport = :80'
$ ss -s
Total: 284
TCP:   47 (estab 21, closed 13, orphaned 0, timewait 12)

Transport Total     IP        IPv6
RAW       1         0         1
UDP       6         4         2
TCP       34        28        6
INET      41        32        9
FRAG      0         0         0
```

`lsof` and `fuser`, for the "who is holding this port" question:

```
$ sudo lsof -nP -i TCP -sTCP:LISTEN
COMMAND       PID          USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
systemd-r     612 systemd-resolve  14u IPv4  22104      0t0  TCP 127.0.0.53:53 (LISTEN)
sshd          812          root   3u IPv4  23117      0t0  TCP *:22 (LISTEN)
nginx        1101          root   6u IPv4  27441      0t0  TCP *:80 (LISTEN)
nginx        1102      www-data   6u IPv4  27441      0t0  TCP *:80 (LISTEN)
postgres     1330      postgres   5u IPv4  29005      0t0  TCP 127.0.0.1:5432 (LISTEN)

$ sudo lsof -nP -i :8080
COMMAND   PID   USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
java     3311 tomcat  42u IPv6  51882      0t0  TCP *:8080 (LISTEN)
java     3311 tomcat  63u IPv6  93117      0t0  TCP 10.20.4.11:8080->10.20.4.9:51244 (ESTABLISHED)

$ sudo lsof -u alice          # every file alice has open
$ sudo lsof +D /var/log       # everything open under a directory (slow but definitive)
$ sudo lsof /dev/sdb1         # who is preventing this unmount

$ sudo fuser -v -n tcp 8080
                     USER        PID ACCESS COMMAND
8080/tcp:            tomcat     3311 F.... java

$ sudo fuser -k -n tcp 8080   # SIGKILL whatever holds it — destructive, confirm first
$ sudo fuser -k -TERM -n tcp 8080     # SIGTERM instead, the humane form
$ sudo fuser -vm /var/lib/data        # who is using this MOUNT POINT (before umount)
```

Reading a bind address correctly is where exposure judgments are made or missed:

| Local Address | Reachable from |
|---|---|
| `127.0.0.1:5432` | This host only (loopback) |
| `0.0.0.0:80` | Every IPv4 address on every interface |
| `[::]:22` | Every IPv6 address; **also IPv4** if `net.ipv6.bindv6only=0` (the default) |
| `10.20.4.11:9100` | Only via that specific interface address |
| `*:8080` (lsof) | All addresses, both families |

### 6.3 `nmap` — the external view

> **Authorization.** Port scanning a host you do not operate is, in many jurisdictions, unauthorized access. Scan only assets you own or have written authorization to test, and record that authorization. In an internal fleet the scan target list should come from the same inventory that drives your configuration management, so the scope is auditable.

```
$ sudo nmap -sS -p- -T4 --open -oA scans/web01-$(date +%F) 10.20.4.11
Starting Nmap 7.94 ( https://nmap.org ) at 2026-08-31 12:04 -03
Nmap scan report for web01.internal (10.20.4.11)
Host is up (0.00042s latency).
Not shown: 65530 closed tcp ports (reset)

PORT     STATE SERVICE
22/tcp   open  ssh
80/tcp   open  http
443/tcp  open  https
9100/tcp open  jetdirect
9200/tcp open  wap-wsp

Nmap done: 1 IP address (1 host up) scanned in 4.71 seconds
```

That output is a finding, not a report. `9100` is `node_exporter` (nmap guessed "jetdirect" from `/usr/share/nmap/nmap-services`, which maps port numbers to *conventional* names and is frequently wrong). `9200` is an Elasticsearch that nobody knew was listening on a routable address. Confirm with version detection:

```
$ sudo nmap -sV -p 9100,9200 --version-intensity 5 10.20.4.11
PORT     STATE SERVICE VERSION
9100/tcp open  http    Prometheus node_exporter
9200/tcp open  http    Elasticsearch REST API 8.13.2 (name: web01; cluster: logs-prod)

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
```

**Scan types and what each is for:**

| Flag | Name | Privilege | Mechanism | When to use |
|---|---|---|---|---|
| `-sS` | SYN / half-open | **root** (raw sockets) | SYN → SYN/ACK → RST; never completes the handshake | Default for a privileged scan. Fast, and does not appear in the application's connection log |
| `-sT` | TCP connect | any user | Full `connect(2)` handshake | The only option unprivileged. Slower, logged by the target application |
| `-sU` | UDP | **root** | Empty datagram or protocol payload; infers from ICMP port-unreachable | Slow and ambiguous (`open\|filtered`) but the only way to see DNS, NTP, SNMP, syslog |
| `-sN` `-sF` `-sX` | Null / FIN / Xmas | **root** | Malformed flag combinations; RFC 793 says closed ports must RST | Firewall-rule inference. Useless against Windows and many stacks |
| `-sA` | ACK | **root** | Maps firewall filtering, not port state | Distinguishing stateful from stateless filtering |
| `-sn` | Ping scan | any | Host discovery only, **no port scan** | Inventory sweep of a subnet |
| `-Pn` | *(modifier)* | any | Skip host discovery, assume up | Hosts that drop ICMP — otherwise nmap reports "host down" and scans nothing |
| `-sV` | Version detection | any | Probes and matches banner signatures | Turning a port number into an actual service identity |
| `-O` | OS detection | **root** | TCP/IP stack fingerprinting | Inventory reconciliation |
| `-A` | Aggressive | **root** | `-sV -O -sC --traceroute` | Interactive investigation. **Never** on a schedule against production |

**Port states — the distinction the exam and production both care about:**

| State | Observed | Means |
|---|---|---|
| `open` | SYN/ACK received | Something is listening and accepting |
| `closed` | RST received | Host reachable, nothing listening. **The host answered** — so it is not firewalled |
| `filtered` | No response, or ICMP unreachable | A firewall dropped the probe. Cannot tell whether anything listens |
| `unfiltered` | Reachable but state undetermined (`-sA` only) | Passes the filter; listening state unknown |
| `open\|filtered` | No response (`-sU`, `-sN/-sF/-sX`) | Either open-and-silent or dropped |
| `closed\|filtered` | Idle scan only | Ambiguous |

The `closed` vs `filtered` distinction is the whole point of a scan review: `Not shown: 65530 closed tcp ports (reset)` means your host is answering with RST on 65530 ports — the firewall is not dropping, it is only that nothing listens. A properly firewalled host reports `filtered`, and a scan of it looks like this:

```
$ sudo nmap -sS -p 22,80,443,5432,9200 10.20.4.12
Nmap scan report for db01.internal (10.20.4.12)
Host is up (0.00061s latency).

PORT     STATE    SERVICE
22/tcp   open     ssh
80/tcp   filtered http
443/tcp  filtered https
5432/tcp open     postgresql
9200/tcp filtered wap-wsp
```

Practical invocations:

```
$ nmap -sn 10.20.4.0/24                          # who is alive on this subnet
$ nmap --top-ports 1000 -T4 10.20.4.11           # the default: 1000 most common
$ sudo nmap -sU --top-ports 50 10.20.4.11        # UDP is slow: bound the port set
$ nmap -p 22,80,443 -iL targets.txt -oG - | grep '/open/'
$ sudo nmap -sS -p- --exclude-ports 9100 -oX scan.xml 10.20.4.0/24
$ nmap --script ssl-enum-ciphers -p 443 web01    # NSE: TLS configuration audit
$ nmap --script vuln -p 443 web01                # NSE vuln category — noisy, authorize first
$ ndiff scans/web01-2026-08-24.xml scans/web01-2026-08-31.xml   # DIFF two scans
```

`ndiff` is the piece that turns scanning into a control:

```
$ ndiff scans/web01-2026-08-24.xml scans/web01-2026-08-31.xml
-web01.internal (10.20.4.11):
+web01.internal (10.20.4.11):
 Host is up.
 Not shown: 65531 closed ports
 PORT     STATE SERVICE VERSION
 22/tcp   open  ssh     OpenSSH 9.6p1
 80/tcp   open  http    nginx 1.26.0
 443/tcp  open  http    nginx 1.26.0
+9200/tcp open  http    Elasticsearch REST API 8.13.2
```

Output formats: `-oN` normal, `-oX` XML (machine-readable, what `ndiff` consumes), `-oG` greppable (deprecated but convenient in a shell pipeline), `-oA <base>` writes all three at once. Always `-oA` on scheduled scans — the XML is your evidence.

---

## 7. Who is logged in, and who has logged in

### 7.1 The record files

Four binary databases, historically the whole story:

| File | Written by | Read by | Contents |
|---|---|---|---|
| `/run/utmp` (`/var/run/utmp`) | `login`, `sshd`, `systemd-logind`, terminal emulators | `who`, `w`, `users`, `pinky` | **Currently** open sessions. Volatile — cleared on reboot |
| `/var/log/wtmp` | Same, plus `shutdown`/`reboot` | `last` | **Historical** logins and logouts, plus boot records |
| `/var/log/btmp` | `login`, `sshd` | `lastb` (**root only**) | **Failed** login attempts |
| `/var/lib/lastlog/lastlog` or `/var/log/lastlog` | PAM (`pam_lastlog`) | `lastlog` | The **most recent** login per user, one fixed-size record indexed by UID |

> **These are not authoritative and never were.** They are ordinary files written by userland processes; a root-level intruder edits them. They are also **being deprecated**: systemd 254+ and util-linux 2.40+ move to `systemd-logind` plus `wtmpdb`/`lastlog2` (SQLite), and several distributions now ship with `utmp` disabled. On such a host `last` prints nothing and the answer lives in the journal. Treat these files as an operational convenience and a **remote log sink or the audit subsystem** as the record of truth.

### 7.2 Currently logged in

```
$ who
alice    pts/0        2026-08-31 11:58 (10.20.4.9)
bob      pts/1        2026-08-31 12:03 (10.20.4.22)
root     tty1         2026-08-30 09:14

$ who -a
           system boot  2026-08-10 08:52
           run-level 5  2026-08-10 08:52
LOGIN      tty1         2026-08-10 08:52              621 id=tty1
alice    + pts/0        2026-08-31 11:58   .          3401 (10.20.4.9)
bob      + pts/1        2026-08-31 12:03  00:03       3512 (10.20.4.22)

$ who -b                      # last boot
         system boot  2026-08-10 08:52
$ who -r                      # runlevel
         run-level 5  2026-08-10 08:52
$ who -H -u                   # header + idle time + PID
$ who am i
alice    pts/0        2026-08-31 11:58 (10.20.4.9)

$ users
alice bob root

$ w
 12:41:03 up 21 days,  3:49,  3 users,  load average: 0.42, 0.31, 0.28
USER     TTY      FROM             LOGIN@   IDLE   JCPU   PCPU WHAT
alice    pts/0    10.20.4.9        11:58    0.00s  0.31s  0.02s w
bob      pts/1    10.20.4.22       12:03    3:41   0.09s  0.09s -bash
root     tty1     -                30Aug26  1days  0.04s  0.04s -bash

$ w -h alice                  # no header, one user
$ w -s                        # short: drop JCPU/PCPU
```

Reading `w`: `IDLE` is time since the terminal saw input — the `3:41` on bob is an abandoned session. `JCPU` is CPU time of all processes attached to that TTY; `PCPU` is CPU time of the process in `WHAT`. A session with a large `JCPU` and an idle terminal is running something detached.

The commands are related but distinct: `who` reads `utmp` and reports sessions; `w` reads `utmp` **and** `/proc` and reports sessions plus what they are doing plus system load; `id` reports the *current process's* credentials, not sessions:

```
$ id
uid=1001(alice) gid=1001(alice) groups=1001(alice),10(wheel),992(docker) context=unconfined_u:...
$ id -u; id -g; id -nG
1001
1001
alice wheel docker
$ whoami          # effective username only
alice
$ logname         # the ORIGINAL login name, unchanged by su/sudo
alice
```

`logname` versus `whoami` is the audit question in miniature: after `sudo -i`, `whoami` says `root` and `logname` says `alice`. Inside a sudo-invoked command, `$SUDO_USER` carries the same information.

The systemd-native view, which works when `utmp` does not:

```
$ loginctl list-sessions
SESSION  UID USER  SEAT  TTY
      3 1001 alice       pts/0
      7 1002 bob         pts/1
      1    0 root  seat0 tty1

3 sessions listed.

$ loginctl session-status 3
3 - alice (1001)
           Since: Sun 2026-08-31 11:58:12 -03; 42min ago
          Leader: 3401 (sshd-session)
          Remote: 10.20.4.9
         Service: sshd; type tty; class user
           State: active
            Unit: session-3.scope
                  ├─3401 "sshd-session: alice [priv]"
                  ├─3409 -bash
                  └─3702 w

$ loginctl list-users
 UID USER  LINGER STATE
1001 alice no     active
1002 bob   no     active

$ sudo loginctl terminate-session 7      # end bob's session
$ sudo loginctl kill-user bob            # end everything bob is running
```

### 7.3 Historical logins

```
$ last -n 8
bob      pts/1        10.20.4.22       Sun Aug 31 12:03   still logged in
alice    pts/0        10.20.4.9        Sun Aug 31 11:58   still logged in
alice    pts/0        10.20.4.9        Sun Aug 31 09:12 - 10:44  (01:32)
deploy   pts/2        10.20.9.14       Sat Aug 30 22:00 - 22:01  (00:00)
root     tty1                          Sat Aug 30 09:14   still logged in
reboot   system boot  6.9.7-200.fc40   Mon Aug 10 08:52   still running
carol    pts/0        10.20.4.31       Sun Aug  9 17:40 - down   (00:22)
shutdown system down  6.9.7-200.fc40   Sun Aug  9 18:02 - 08:52  (14:50)

wtmp begins Sat Aug  1 00:00:01 2026
```

```
$ last -F alice                    # full timestamps with seconds and year
$ last -a                          # hostname in the LAST column (not truncated)
$ last -i                          # numeric IP instead of hostname
$ last -d                          # resolve stored IPs back to names
$ last -x                          # include runlevel and shutdown entries
$ last reboot                      # boot history only
$ last -s yesterday -t today       # time-bounded
$ last -s '2026-08-30 00:00' -t '2026-08-31 00:00' -F
$ last -p 2026-08-30               # who was logged in AT that moment
$ last -f /var/log/wtmp.1          # read a rotated file
$ last pts/0                       # by terminal
```

Failed attempts — root only, because the file leaks mistyped passwords entered in the username field:

```
$ sudo lastb -n 6 -F -a
admin    ssh:notty    Sun Aug 31 03:14:02 2026 - Sun Aug 31 03:14:02 2026  (00:00)   203.0.113.44
root     ssh:notty    Sun Aug 31 03:14:01 2026 - Sun Aug 31 03:14:01 2026  (00:00)   203.0.113.44
oracle   ssh:notty    Sun Aug 31 03:13:59 2026 - Sun Aug 31 03:13:59 2026  (00:00)   203.0.113.44
alice    pts/1        Sat Aug 30 17:22:10 2026 - Sat Aug 30 17:22:10 2026  (00:00)   10.20.4.9
ubuntu   ssh:notty    Sat Aug 30 02:01:44 2026 - Sat Aug 30 02:01:44 2026  (00:00)   198.51.100.7

btmp begins Sat Aug  1 00:00:03 2026

$ sudo lastb -i | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5
   4471 203.0.113.44
    881 198.51.100.7
     12 10.20.4.9
```

Stale-account detection — the highest-value use of `lastlog`:

```
$ lastlog
Username         Port     From             Latest
root             tty1                      Sat Aug 30 09:14:22 -0300 2026
alice            pts/0    10.20.4.9        Sun Aug 31 11:58:12 -0300 2026
bob              pts/1    10.20.4.22       Sun Aug 31 12:03:41 -0300 2026
carol            pts/0    10.20.4.31       Sun Aug  9 17:40:03 -0300 2026
dave                                       **Never logged in**
svc_backup                                 **Never logged in**

$ lastlog -t 7                     # logged in within the last 7 days
$ lastlog -b 90                    # NOT logged in for 90+ days — the offboarding candidates
$ lastlog -u alice
```

> `lastlog` is a **sparse** file indexed by UID. `ls -l` shows a huge apparent size; `du` shows the real one. Never `cat` it, and never copy it without `--sparse=always`.

On a modern utmp-less host, the same questions answered from the journal and the new databases:

```
$ journalctl _COMM=sshd --since "24 hours ago" | grep -E 'Accepted|Failed' | tail -5
Aug 31 11:58:12 web01 sshd[3401]: Accepted publickey for alice from 10.20.4.9 port 51244 ssh2: ED25519 SHA256:8Ky...
Aug 31 03:14:02 web01 sshd[2988]: Failed password for invalid user admin from 203.0.113.44 port 39114 ssh2

$ journalctl -u systemd-logind --since today -o cat
New session 3 of user alice.
New session 7 of user bob.
Removed session 5.

$ wtmpdb last -n 5              # util-linux 2.40+ replacement for `last`
$ lastlog2 -b 90                # replacement for `lastlog -b`
```

### 7.4 The authoritative trail: auditd

`who`/`last` answer "who had a session". They do not answer "who ran what". `auditd` does, at the syscall level, and its records are written by a kernel-fed daemon rather than by the logging-in process.

```
# /etc/audit/rules.d/50-privilege.rules
## Every privileged (SUID/SGID) execution — the runtime counterpart of §2's find
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k suid_exec
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k suid_exec
-a always,exit -F arch=b64 -S execve -C gid!=egid -k sgid_exec

## Changes to the privilege configuration itself
-w /etc/sudoers    -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/passwd     -p wa -k identity
-w /etc/shadow     -p wa -k identity
-w /etc/group      -p wa -k identity
-w /etc/gshadow    -p wa -k identity
-w /etc/security/limits.conf   -p wa -k limits
-w /etc/security/limits.d/     -p wa -k limits

## Privilege-changing syscalls
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -F auid>=1000 -F auid!=unset -k privchange

## The login records themselves
-w /var/log/wtmp  -p wa -k session
-w /var/log/btmp  -p wa -k session
-w /run/utmp      -p wa -k session

## Make the ruleset immutable until reboot. Put this LAST.
-e 2
```

```
$ sudo augenrules --load
$ sudo auditctl -s
enabled 2
failure 1
pid 1044
rate_limit 0
backlog_limit 8192
lost 0
backlog 0

$ sudo ausearch -k scope -ts today -i | tail -6
type=CONFIG_CHANGE msg=audit(08/31/2026 10:22:41.117:8891) : op=updated_rules ...
type=SYSCALL msg=audit(08/31/2026 10:22:41.117:8892) : arch=x86_64 syscall=openat
    success=yes exit=3 a0=0xffffff9c ... uid=root auid=alice ses=3 comm=vi
    exe=/usr/bin/vi key=scope

$ sudo aureport --auth --summary -ts this-week
Authentication Report
=====================================
total  acct
=====================================
4471   admin
881    root
14     alice
```

The `auid` (audit login UID) field is the reason this is the authoritative record: it is set at login, is immutable for the process tree (with `--loginuid-immutable`), and **survives `su` and `sudo`**. `uid=root auid=alice` is the sentence "alice did this as root", and no amount of `su` in between erases it.

---

## 8. Complete infrastructure manifests

### 8.1 Ansible role — the declarative half of the control loop

```yaml
# roles/host_security/defaults/main.yml
---
sec_password_max_days: 90
sec_password_min_days: 1
sec_password_warn_age: 14
sec_password_inactive: 14
sec_umask: "027"
sec_encrypt_method: "YESCRYPT"

sec_pwquality:
  minlen: 14
  minclass: 3
  maxrepeat: 3
  dictcheck: 1
  usercheck: 1
  enforcing: 1
  retry: 3

sec_faillock:
  deny: 5
  fail_interval: 900
  unlock_time: 900
  even_deny_root: true
  root_unlock_time: 60

sec_limits:
  - { domain: "*",     type: "soft", item: "nproc",     value: "2048" }
  - { domain: "*",     type: "hard", item: "nproc",     value: "4096" }
  - { domain: "*",     type: "soft", item: "nofile",    value: "4096" }
  - { domain: "*",     type: "hard", item: "nofile",    value: "16384" }
  - { domain: "*",     type: "-",    item: "core",      value: "0" }
  - { domain: "*",     type: "hard", item: "maxlogins", value: "10" }
  - { domain: "@sre",  type: "soft", item: "nofile",    value: "16384" }
  - { domain: "@sre",  type: "hard", item: "nofile",    value: "65536" }
  - { domain: "@sre",  type: "soft", item: "nproc",     value: "8192" }
  - { domain: "@sre",  type: "hard", item: "nproc",     value: "16384" }

sec_systemd_default_limits:
  DefaultLimitNOFILE: "8192:524288"
  DefaultLimitNPROC: "4096:16384"
  DefaultLimitCORE: "0"
  DefaultTasksMax: "4096"

# Vendor-approved SUID/SGID set. Anything on the host and not in this list is drift.
sec_suid_baseline:
  - /usr/bin/chage
  - /usr/bin/chfn
  - /usr/bin/chsh
  - /usr/bin/gpasswd
  - /usr/bin/mount
  - /usr/bin/newgrp
  - /usr/bin/passwd
  - /usr/bin/su
  - /usr/bin/sudo
  - /usr/bin/umount
  - /usr/bin/wall
  - /usr/bin/write
  - /usr/bin/ssh-agent
  - /usr/lib/openssh/ssh-keysign
  - /usr/libexec/openssh/ssh-keysign
  - /usr/bin/pkexec
  - /usr/bin/crontab
  - /usr/bin/at

sec_suid_remove: []          # explicit removals, reviewed and approved
sec_scan_schedule: "*-*-* 03:17:00"
```

```yaml
# roles/host_security/tasks/main.yml
---
- name: Gather package facts for provenance checks
  ansible.builtin.package_facts:
    manager: auto
  tags: [always]

# ---------------------------------------------------------------- password policy
- name: Enforce password aging defaults for NEW accounts (login.defs)
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*#?\\s*{{ item.key }}\\s+"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    owner: root
    group: root
    mode: "0644"
  loop:
    - { key: "PASS_MAX_DAYS",  value: "{{ sec_password_max_days }}" }
    - { key: "PASS_MIN_DAYS",  value: "{{ sec_password_min_days }}" }
    - { key: "PASS_WARN_AGE",  value: "{{ sec_password_warn_age }}" }
    - { key: "UMASK",          value: "{{ sec_umask }}" }
    - { key: "ENCRYPT_METHOD", value: "{{ sec_encrypt_method }}" }
    - { key: "LOG_UNKFAIL_ENAB", value: "no" }
  tags: [passwords]

- name: Set the default INACTIVE period for new accounts
  ansible.builtin.command:
    cmd: "useradd -D -f {{ sec_password_inactive }}"
  register: sec_useradd_d
  changed_when: sec_useradd_d.rc == 0
  check_mode: false
  tags: [passwords]

# login.defs does NOT retroactively age existing accounts. Sweep them explicitly,
# skipping system accounts and any account with no usable password.
- name: Enumerate human accounts with an interactive shell
  ansible.builtin.shell:
    cmd: >-
      set -o pipefail;
      awk -F: -v min="{{ sec_uid_min | default(1000) }}"
        '$3 >= min && $3 < 65534 && $7 !~ /(nologin|false|sync)$/ {print $1}'
        /etc/passwd
    executable: /bin/bash
  register: sec_human_accounts
  changed_when: false
  check_mode: false
  tags: [passwords]

- name: Apply password aging to existing human accounts
  ansible.builtin.user:
    name: "{{ item }}"
    password_expire_max: "{{ sec_password_max_days }}"
    password_expire_min: "{{ sec_password_min_days }}"
    password_expire_warn: "{{ sec_password_warn_age }}"
  loop: "{{ sec_human_accounts.stdout_lines }}"
  tags: [passwords]

- name: Report accounts with an EMPTY password (finding, not auto-remediated)
  ansible.builtin.shell:
    cmd: "awk -F: '($2 == \"\") {print $1}' /etc/shadow"
    executable: /bin/bash
  register: sec_empty_passwords
  changed_when: false
  check_mode: false
  become: true
  tags: [passwords, audit]

- name: Fail when any account has an empty password
  ansible.builtin.assert:
    that: sec_empty_passwords.stdout_lines | length == 0
    fail_msg: >-
      Accounts with EMPTY passwords on {{ inventory_hostname }}:
      {{ sec_empty_passwords.stdout_lines | join(', ') }}
    success_msg: "No accounts with empty passwords."
  tags: [passwords, audit]

- name: Report non-root accounts with UID 0 (finding)
  ansible.builtin.shell:
    cmd: "awk -F: '($3 == 0 && $1 != \"root\") {print $1}' /etc/passwd"
    executable: /bin/bash
  register: sec_uid0
  changed_when: false
  check_mode: false
  tags: [passwords, audit]

- name: Fail when a non-root UID 0 account exists
  ansible.builtin.assert:
    that: sec_uid0.stdout_lines | length == 0
    fail_msg: "UID 0 aliases found: {{ sec_uid0.stdout_lines | join(', ') }}"
  tags: [passwords, audit]

- name: Deploy password quality policy
  ansible.builtin.template:
    src: pwquality.conf.j2
    dest: /etc/security/pwquality.conf
    owner: root
    group: root
    mode: "0644"
  tags: [passwords]

- name: Deploy account lockout policy
  ansible.builtin.template:
    src: faillock.conf.j2
    dest: /etc/security/faillock.conf
    owner: root
    group: root
    mode: "0644"
  tags: [passwords]

# ---------------------------------------------------------------- resource limits
- name: Deploy PAM resource limits
  ansible.builtin.template:
    src: limits.conf.j2
    dest: /etc/security/limits.d/50-baseline.conf
    owner: root
    group: root
    mode: "0644"
  tags: [limits]

- name: Ensure pam_limits is present in the session stacks that matter
  ansible.builtin.lineinfile:
    path: "{{ item }}"
    regexp: '^session\s+required\s+pam_limits\.so'
    line: "session     required      pam_limits.so"
    state: present
  loop: "{{ sec_pam_session_files }}"
  when: sec_pam_session_files is defined
  tags: [limits]

- name: Deploy systemd manager default limits (services do NOT read limits.conf)
  ansible.builtin.copy:
    dest: /etc/systemd/system.conf.d/10-limits.conf
    owner: root
    group: root
    mode: "0644"
    content: |
      # Managed by Ansible - roles/host_security
      # systemd starts services without a PAM session, so /etc/security/limits.conf
      # has no effect on them. These are the limits that actually apply.
      [Manager]
      {% for k, v in sec_systemd_default_limits.items() %}
      {{ k }}={{ v }}
      {% endfor %}
  notify: reexec systemd
  tags: [limits]

- name: Deploy kernel-level ceilings
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/60-limits.conf
    sysctl_set: true
    reload: true
  loop:
    - { key: "fs.file-max",        value: "2097152" }
    - { key: "fs.nr_open",         value: "1048576" }
    - { key: "kernel.pid_max",     value: "4194304" }
    - { key: "fs.suid_dumpable",   value: "0" }
    - { key: "kernel.dmesg_restrict", value: "1" }
  tags: [limits]

# ---------------------------------------------------------------- sudo
- name: Install sudo
  ansible.builtin.package:
    name: sudo
    state: present
  tags: [sudo]

- name: Deploy sudoers drop-ins (validated BEFORE installation)
  ansible.builtin.template:
    src: "sudoers/{{ item }}.j2"
    dest: "/etc/sudoers.d/{{ item }}"
    owner: root
    group: root
    mode: "0440"
    validate: "/usr/sbin/visudo -cf %s"
  loop:
    - 00-defaults
    - 20-sre-oncall
    - 30-deploy-automation
  tags: [sudo]

- name: Remove sudoers drop-ins that are no longer declared
  ansible.builtin.file:
    path: "/etc/sudoers.d/{{ item }}"
    state: absent
  loop: "{{ sec_sudoers_absent | default([]) }}"
  tags: [sudo]

- name: Create the sudo I/O log directory
  ansible.builtin.file:
    path: /var/log/sudo-io
    state: directory
    owner: root
    group: root
    mode: "0700"
  tags: [sudo]

- name: Validate the ENTIRE sudoers tree after any change
  ansible.builtin.command:
    cmd: /usr/sbin/visudo -c
  register: sec_visudo
  changed_when: false
  failed_when: sec_visudo.rc != 0
  tags: [sudo]

# ---------------------------------------------------------------- SUID/SGID drift
- name: Scan for SUID and SGID files
  ansible.builtin.shell:
    cmd: >-
      find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort
    executable: /bin/bash
  register: sec_suid_found
  changed_when: false
  check_mode: false
  tags: [suid, audit]

- name: Compute SUID/SGID drift against the approved baseline
  ansible.builtin.set_fact:
    sec_suid_drift: "{{ sec_suid_found.stdout_lines | difference(sec_suid_baseline) }}"
    sec_suid_missing: "{{ sec_suid_baseline | difference(sec_suid_found.stdout_lines) }}"
  tags: [suid, audit]

- name: Report SUID/SGID drift
  ansible.builtin.debug:
    msg:
      - "UNEXPECTED SUID/SGID on {{ inventory_hostname }}: {{ sec_suid_drift | default([]) }}"
      - "Baseline entries ABSENT (may be fine, distro-dependent): {{ sec_suid_missing | default([]) }}"
  when: sec_suid_drift | length > 0 or sec_suid_missing | length > 0
  tags: [suid, audit]

- name: Remove explicitly approved SUID bits
  ansible.builtin.file:
    path: "{{ item }}"
    mode: "u-s"
  loop: "{{ sec_suid_remove }}"
  when: item in sec_suid_found.stdout_lines
  tags: [suid]

- name: Scan for file capabilities (invisible to find -perm)
  ansible.builtin.command:
    cmd: getcap -r /
  register: sec_caps
  changed_when: false
  failed_when: false
  check_mode: false
  tags: [suid, audit]

- name: Report file capabilities
  ansible.builtin.debug:
    var: sec_caps.stdout_lines
  tags: [suid, audit]

# ---------------------------------------------------------------- scheduled scan
- name: Install the drift scanner
  ansible.builtin.template:
    src: suid-scan.sh.j2
    dest: /usr/local/sbin/suid-scan.sh
    owner: root
    group: root
    mode: "0755"
  tags: [suid]

- name: Install the drift scanner unit and timer
  ansible.builtin.template:
    src: "{{ item }}.j2"
    dest: "/etc/systemd/system/{{ item }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - suid-scan.service
    - suid-scan.timer
  notify: reload systemd
  tags: [suid]

- name: Enable the drift scanner timer
  ansible.builtin.systemd_service:
    name: suid-scan.timer
    enabled: true
    state: started
    daemon_reload: true
  tags: [suid]

# ---------------------------------------------------------------- audit trail
- name: Install auditd
  ansible.builtin.package:
    name: "{{ sec_auditd_package | default('audit') }}"
    state: present
  tags: [audit]

- name: Deploy audit rules
  ansible.builtin.copy:
    src: 50-privilege.rules
    dest: /etc/audit/rules.d/50-privilege.rules
    owner: root
    group: root
    mode: "0640"
  notify: reload audit rules
  tags: [audit]

- name: Enable auditd
  ansible.builtin.systemd_service:
    name: auditd
    enabled: true
    state: started
  tags: [audit]
```

```yaml
# roles/host_security/handlers/main.yml
---
- name: reload systemd
  ansible.builtin.systemd_service:
    daemon_reload: true

- name: reexec systemd
  ansible.builtin.command:
    cmd: systemctl daemon-reexec
  changed_when: true

- name: reload audit rules
  ansible.builtin.command:
    cmd: augenrules --load
  changed_when: true
```

```jinja
{# roles/host_security/templates/limits.conf.j2 #}
# Managed by Ansible - roles/host_security. Local edits will be overwritten.
#
# NOTE: pam_limits applies these ONLY to processes started through a PAM session
# (login, sshd, su, sudo, cron-with-pam). systemd services are NOT covered — see
# /etc/systemd/system.conf.d/10-limits.conf and per-unit Limit*= directives.
#
#<domain>      <type>  <item>          <value>
{% for l in sec_limits %}
{{ '%-14s' | format(l.domain) }}{{ '%-8s' | format(l.type) }}{{ '%-16s' | format(l.item) }}{{ l.value }}
{% endfor %}
```

```jinja
{# roles/host_security/templates/suid-scan.sh.j2 #}
#!/usr/bin/env bash
# Managed by Ansible. Emits SUID/SGID drift as node_exporter textfile metrics.
set -Eeuo pipefail

BASELINE=/var/lib/host-security/suid.baseline
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
OUT="${TEXTFILE_DIR}/suid_drift.prom"
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT

install -d -m 0755 "$(dirname "${BASELINE}")" "${TEXTFILE_DIR}"

CURRENT="$(mktemp)"; trap 'rm -f "${TMP}" "${CURRENT}"' EXIT
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -print 2>/dev/null | sort > "${CURRENT}"

if [[ ! -f "${BASELINE}" ]]; then
    cp "${CURRENT}" "${BASELINE}"
    logger -t suid-scan "baseline created with $(wc -l < "${BASELINE}") entries"
fi

added=$(comm -13 "${BASELINE}" "${CURRENT}" | wc -l)
removed=$(comm -23 "${BASELINE}" "${CURRENT}" | wc -l)
total=$(wc -l < "${CURRENT}")
caps=$(getcap -r / 2>/dev/null | wc -l)

comm -13 "${BASELINE}" "${CURRENT}" | while read -r f; do
    logger -t suid-scan -p auth.warning "UNEXPECTED setuid/setgid file: ${f}"
done

cat > "${TMP}" <<EOF
# HELP node_suid_files_total Number of SUID/SGID files on local filesystems.
# TYPE node_suid_files_total gauge
node_suid_files_total ${total}
# HELP node_suid_files_added Files with SUID/SGID not present in the baseline.
# TYPE node_suid_files_added gauge
node_suid_files_added ${added}
# HELP node_suid_files_removed Baseline SUID/SGID files no longer present.
# TYPE node_suid_files_removed gauge
node_suid_files_removed ${removed}
# HELP node_file_capabilities_total Binaries carrying file capabilities.
# TYPE node_file_capabilities_total gauge
node_file_capabilities_total ${caps}
EOF

chmod 0644 "${TMP}"
mv "${TMP}" "${OUT}"     # atomic: node_exporter never reads a partial file
```

```ini
# roles/host_security/templates/suid-scan.service.j2
[Unit]
Description=SUID/SGID drift scan
Documentation=man:find(1) man:getcap(8)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/suid-scan.sh
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
TimeoutStartSec=15min

# The scan must read the whole filesystem, so ProtectSystem=strict is wrong here;
# it is still confined to no new privileges and a read-only view except the output.
NoNewPrivileges=yes
ProtectHome=read-only
ProtectSystem=full
ReadWritePaths=/var/lib/host-security /var/lib/node_exporter/textfile_collector
PrivateTmp=yes
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYS_ADMIN
```

```ini
# roles/host_security/templates/suid-scan.timer.j2
[Unit]
Description=Nightly SUID/SGID drift scan

[Timer]
OnCalendar={{ sec_scan_schedule }}
RandomizedDelaySec=30min      # do not stampede the fleet's I/O at the same second
Persistent=true               # run on boot if the host was down at the scheduled time
AccuracySec=1min

[Install]
WantedBy=timers.target
```

### 8.2 Prometheus alerting rules

```yaml
# prometheus/rules/host-security.yml
---
groups:
  - name: host-security
    interval: 60s
    rules:
      - alert: SuidBinaryDrift
        expr: node_suid_files_added > 0
        for: 10m
        labels:
          severity: critical
          category: privilege-escalation
        annotations:
          summary: "Unapproved SUID/SGID binary on {{ $labels.instance }}"
          description: >-
            {{ $value }} setuid/setgid file(s) present that are not in the approved
            baseline. Each is a potential unaudited path to root.
          runbook_url: "https://runbooks.internal/security/suid-drift"
          query: 'journalctl -t suid-scan -p warning --since "24 hours ago"'

      - alert: SuidScanStale
        expr: time() - node_textfile_mtime_seconds{file="suid_drift.prom"} > 172800
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "SUID drift scan has not run for 48h on {{ $labels.instance }}"
          description: "The control is silent, which is indistinguishable from clean."

      - alert: UnexpectedListeningPort
        expr: |
          count by (instance) (
            node_network_listening_port_info
            unless on (instance, port) approved_listening_port
          ) > 0
        for: 15m
        labels:
          severity: warning
          category: exposure
        annotations:
          summary: "Unapproved listening port on {{ $labels.instance }}"
          query: 'ss -tulpn'

      - alert: FileDescriptorExhaustionImminent
        expr: |
          process_open_fds / process_max_fds > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.job }} on {{ $labels.instance }} at {{ $value | humanizePercentage }} of its fd limit"
          description: >-
            Raise LimitNOFILE= in the unit — /etc/security/limits.conf does NOT
            apply to systemd services.

      - alert: CgroupTasksNearLimit
        expr: |
          node_systemd_unit_tasks_current / node_systemd_unit_tasks_max > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.name }} approaching TasksMax on {{ $labels.instance }}"

      - alert: BruteForceLoginAttempts
        expr: rate(node_failed_logins_total[15m]) * 900 > 50
        for: 5m
        labels:
          severity: warning
          category: authentication
        annotations:
          summary: "{{ $value | printf \"%.0f\" }} failed logins in 15m on {{ $labels.instance }}"
          query: 'lastb -i | awk "{print \$NF}" | sort | uniq -c | sort -rn | head'

      - alert: AccountWithEmptyPassword
        expr: node_accounts_empty_password > 0
        labels:
          severity: critical
        annotations:
          summary: "Account with an empty password on {{ $labels.instance }}"
```

### 8.3 CI pipeline: validate policy before it ships, scan after it lands

```yaml
# .gitlab-ci.yml
---
stages: [validate, dry-run, deploy, verify]

variables:
  ANSIBLE_FORCE_COLOR: "1"
  ANSIBLE_HOST_KEY_CHECKING: "False"

# ---- Every sudoers template must parse. A syntax error here locks out a fleet.
sudoers:syntax:
  stage: validate
  image: alpine:3.20
  before_script:
    - apk add --no-cache sudo python3 py3-jinja2
  script:
    - |
      rc=0
      for tpl in roles/host_security/templates/sudoers/*.j2; do
        out="/tmp/$(basename "${tpl}" .j2)"
        python3 ci/render_template.py "${tpl}" > "${out}"
        chown root:root "${out}"; chmod 0440 "${out}"
        if visudo -cf "${out}"; then
          echo "OK   ${tpl}"
        else
          echo "FAIL ${tpl}"; rc=1
        fi
      done
      exit "${rc}"

# ---- Reject grants that are shell escapes in disguise.
sudoers:dangerous-grants:
  stage: validate
  image: alpine:3.20
  script:
    - |
      set -euo pipefail
      DANGEROUS='/(vi|vim|nano|emacs|less|more|man|find|tar|awk|perl|python[0-9.]*|ruby|nmap|ed|env|nice|xargs)([[:space:]]|$)'
      if grep -nEH "NOPASSWD.*${DANGEROUS}" roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: NOPASSWD grant on a program with a documented shell escape."
        echo "See https://gtfobins.github.io/ — use a root-owned wrapper instead."
        exit 1
      fi
      if grep -nEH '=\s*\(ALL(:ALL)?\)\s*NOPASSWD:\s*ALL' roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: unrestricted NOPASSWD: ALL grant."
        exit 1
      fi
      if grep -nEH '^[^#]*\*/\.\.' roles/host_security/templates/sudoers/*.j2; then
        echo "ERROR: path traversal reachable through a wildcard."
        exit 1
      fi
      echo "No dangerous grant patterns found."

ansible:lint:
  stage: validate
  image: python:3.12-slim
  script:
    - pip install --no-cache-dir ansible-lint ansible-core
    - ansible-lint roles/host_security/
    - ansible-playbook --syntax-check site.yml

ansible:check:
  stage: dry-run
  image: python:3.12-slim
  script:
    - pip install --no-cache-dir ansible-core
    - ansible-playbook -i inventories/prod site.yml --check --diff --limit canary
  artifacts:
    paths: [ansible-check.log]
    expire_in: 1 week

ansible:apply:
  stage: deploy
  image: python:3.12-slim
  when: manual
  environment:
    name: production
  script:
    - pip install --no-cache-dir ansible-core
    - ansible-playbook -i inventories/prod site.yml --limit canary
    - ansible-playbook -i inventories/prod site.yml --limit '!canary' --forks 20

# ---- The external view. Runs from a host on the same L3 segment as production,
#      against an inventory-derived target list. Compares to last week's scan.
nmap:exposure-diff:
  stage: verify
  image: instrumentisto/nmap:7.94
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
  script:
    - mkdir -p scans
    - nmap -sS -Pn -p- -T4 --open -oA "scans/current" -iL inventories/prod/scan-targets.txt
    - |
      if [ -f baseline/exposure.xml ]; then
        ndiff baseline/exposure.xml scans/current.xml > scans/diff.txt || true
        if [ -s scans/diff.txt ]; then
          echo "=== EXPOSURE CHANGED ==="
          cat scans/diff.txt
          exit 1
        fi
        echo "No exposure change since the approved baseline."
      else
        echo "No baseline yet; promoting the current scan after review."
      fi
  artifacts:
    when: always
    paths: [scans/]
    expire_in: 90 days
```

---

## 9. Verification and failure diagnosis

### 9.1 The verification pass

Run this after any change in this domain. Each line is a question with a definite answer.

```bash
#!/usr/bin/env bash
# verify-security-baseline.sh — read-only. Exit non-zero on any finding.
set -uo pipefail
fail=0
chk() { if eval "$2"; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

echo "== sudo =="
chk "sudoers tree parses"            'visudo -c >/dev/null 2>&1'
chk "sudoers is mode 0440"           '[ "$(stat -c %a /etc/sudoers)" = 440 ]'
chk "no NOPASSWD: ALL grant"         '! grep -rhE "NOPASSWD:\s*ALL" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -qv "^#"'
chk "env_reset is set"               'grep -rqE "^Defaults[[:space:]]+.*env_reset" /etc/sudoers /etc/sudoers.d/'
chk "secure_path is set"             'grep -rqE "^Defaults[[:space:]]+.*secure_path" /etc/sudoers /etc/sudoers.d/'

echo "== accounts =="
chk "root password is locked"        '[ "$(passwd -S root | awk "{print \$2}")" = "L" ]'
chk "no empty passwords"             '[ -z "$(awk -F: "\$2==\"\"{print \$1}" /etc/shadow)" ]'
chk "no non-root UID 0"              '[ -z "$(awk -F: "\$3==0 && \$1!=\"root\"{print \$1}" /etc/passwd)" ]'
chk "PASS_MAX_DAYS <= 90"            '[ "$(awk "/^PASS_MAX_DAYS/{print \$2}" /etc/login.defs)" -le 90 ]'
chk "shadow is not world-readable"   '[ "$(stat -c %a /etc/shadow)" -le 640 ]'

echo "== limits =="
chk "pam_limits in system-auth"      'grep -rqE "^session.*pam_limits\.so" /etc/pam.d/'
chk "systemd default limits present" '[ -f /etc/systemd/system.conf.d/10-limits.conf ]'
chk "core dumps disabled"            '[ "$(sysctl -n fs.suid_dumpable)" = 0 ]'

echo "== privilege surface =="
chk "no SUID drift"                  'diff -q <(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort) /var/lib/host-security/suid.baseline >/dev/null'
chk "no SUID on user-writable fs"    '[ -z "$(find /home /tmp /var/tmp -xdev -perm /6000 -type f 2>/dev/null)" ]'
chk "/tmp mounted nosuid"            'findmnt -no OPTIONS /tmp 2>/dev/null | grep -q nosuid || ! findmnt -no TARGET /tmp >/dev/null 2>&1'

echo "== audit =="
chk "auditd running"                 'systemctl is-active --quiet auditd'
chk "audit rules loaded"             '[ "$(auditctl -l 2>/dev/null | wc -l)" -gt 5 ]'
chk "btmp exists and is 0600"        '[ "$(stat -c %a /var/log/btmp 2>/dev/null)" = 600 ]'

exit "${fail}"
```

```
$ sudo ./verify-security-baseline.sh
== sudo ==
PASS  sudoers tree parses
PASS  sudoers is mode 0440
PASS  no NOPASSWD: ALL grant
PASS  env_reset is set
PASS  secure_path is set
== accounts ==
PASS  root password is locked
PASS  no empty passwords
PASS  no non-root UID 0
PASS  PASS_MAX_DAYS <= 90
PASS  shadow is not world-readable
== limits ==
PASS  pam_limits in system-auth
PASS  systemd default limits present
PASS  core dumps disabled
== privilege surface ==
FAIL  no SUID drift
PASS  no SUID on user-writable fs
PASS  /tmp mounted nosuid
== audit ==
PASS  auditd running
PASS  audit rules loaded
PASS  btmp exists and is 0600
$ echo $?
1
```

### 9.2 Failure catalogue

**"I raised `nofile` in `limits.conf` but the service still hits 1024."**

```
$ grep nofile /etc/security/limits.d/50-baseline.conf
*    hard    nofile    16384
$ cat /proc/$(pgrep -f api)/limits | grep 'Max open'
Max open files            1024                 4096                 files
```
Cause: `pam_limits` runs during a PAM session; systemd starts services without one. Fix in the unit, not in PAM:
```
$ sudo systemctl edit api.service
### add: [Service] / LimitNOFILE=65536
$ sudo systemctl daemon-reload && sudo systemctl restart api.service
$ systemctl show api.service -p LimitNOFILE
LimitNOFILE=65536
```
The same applies for an interactive shell where the limit did not take: check that `pam_limits.so` is in the stack that your entry path actually uses (`/etc/pam.d/sshd` → `password-auth`/`common-session`), and that you re-logged in — the limit is set at session creation, not read live.

**"`ulimit -n` says `Operation not permitted` and I am not even near the ceiling."**
```
$ ulimit -Hn
4096
$ ulimit -n 65536
bash: ulimit: open files: cannot modify limit: Operation not permitted
```
An unprivileged process can only *lower* a hard limit, and the change is irreversible for that process tree. Something earlier in the chain (a profile script, a wrapper, a container runtime) lowered it. Raise the hard limit in `limits.conf`/the unit and start a **new** session. Also check the kernel ceiling: `nofile` cannot exceed `fs.nr_open`.

**"I locked the account but the user still logs in."**
```
$ sudo passwd -S bob
bob L 08/12/2026 1 90 14 14
$ sudo journalctl -u sshd | tail -1
Accepted publickey for bob from 10.20.4.22 port 51992 ssh2: ED25519 SHA256:1Kx...
```
`passwd -l` disables the *password*. Public-key authentication does not consult it. Full disable: `usermod -L bob && chage -E "$(date -d yesterday +%F)" bob && usermod -s /usr/sbin/nologin bob && pkill -KILL -u bob`, and remove or rename `~bob/.ssh/authorized_keys`.

**"`sudo` takes 10 seconds before prompting."**
```
$ time sudo -n true
sudo: a password is required
real    0m10.021s
```
`sudo` is resolving the local hostname and timing out. Confirm the host's own name is in `/etc/hosts` on the `127.0.0.1` line, and set `Defaults !fqdn`. The same symptom with `ss`/`netstat`/`last` comes from reverse DNS — use `-n` / `-i`.

**"`sudo` works but my script cannot find its binaries."**
```
$ sudo /opt/tool/run.sh
/opt/tool/run.sh: line 4: kubectl: command not found
$ sudo env | grep -E '^(PATH|HOME)'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
```
`Defaults secure_path` replaces `PATH` and `env_reset` discards the caller's environment. Either use absolute paths in the script (correct), or add the directory to `secure_path`, or whitelist a variable with `Defaults env_keep += "VAR"`. Do **not** disable `env_reset`; it exists to stop `LD_PRELOAD`-class attacks.

**"I broke `/etc/sudoers` and there is no root password."**
```
$ sudo -l
sudo: /etc/sudoers:22:14: syntax error
sudo: no valid sudoers sources found, quitting
```
Recovery, in order of preference: (1) another already-open root shell on the box — use it immediately, do not close it; (2) `pkexec visudo` if polkit is configured; (3) a machine-account SSH key with a forced command; (4) console access and boot with `systemd.debug-shell=1` or `rd.break`/`init=/bin/bash` and remount `/` read-write. The preventive control is the CI `visudo -cf` gate in §8.3, plus never editing sudoers outside `visudo`.

**"`nmap` says the host is down but I can SSH to it."**
```
$ nmap -p 22 10.20.4.11
Note: Host seems down. If it is really up, but blocking our ping probes, try -Pn
```
Host discovery (ICMP echo + TCP ACK to 80 + TCP SYN to 443 + ICMP timestamp) was filtered. Add `-Pn`. Note the cost: with `-Pn`, nmap scans every address in the range whether or not anything is there, which makes a `/16` sweep very slow.

**"`ss -tulpn` shows no process names."**
```
$ ss -tulpn | head -2
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*
```
You are not root. Reading another user's socket→PID mapping requires `CAP_NET_ADMIN`/root. Re-run with `sudo`.

**"`last` prints nothing on a new distribution release."**
```
$ last
wtmp begins Sun Aug 31 00:00:01 2026
$ ls -l /var/log/wtmp
-rw-rw-r--. 1 root utmp 0 Aug 31 00:00 /var/log/wtmp
```
`utmp` support has been disabled in favour of `systemd-logind` + `wtmpdb`. Use `wtmpdb last`, `lastlog2`, or `journalctl -u systemd-logind` / `journalctl _COMM=sshd`. Update your log-collection queries accordingly — this is a silent monitoring gap, not an empty history.

**"A user cannot start any new process."**
```
$ ssh alice@web01
alice@web01:~$ ls
-bash: fork: retry: Resource temporarily unavailable
```
`nproc` is exhausted. It counts by **real UID across the entire system**, so another session or a leaking daemon owned by the same UID is consuming it:
```
$ ps -eo user= | sort | uniq -c | sort -rn | head -3
    247 alice
     92 root
     14 www-data
$ ulimit -u
256
```
Raise the limit, or better, move the workload under a systemd unit with `TasksMax=` so the containment is per-service instead of per-UID.

**"An unexpected port appeared and I need to know who opened it, right now."**
```
$ sudo ss -tulpn 'sport = :9200'
tcp LISTEN 0 4096 0.0.0.0:9200 0.0.0.0:* users:(("java",pid=4188,fd=412))
$ sudo lsof -nP -p 4188 | head -3
COMMAND  PID          USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
java    4188 elasticsearch  cwd    DIR  253,1     4096  1179842 /usr/share/elasticsearch
java    4188 elasticsearch  txt    REG  253,1 12583744  1180991 /usr/share/elasticsearch/jdk/bin/java
$ ps -o pid,ppid,user,lstart,cmd -p 4188 --no-headers
4188  1 elasticsearch Sat Aug 30 22:01:14 2026 /usr/share/elasticsearch/jdk/bin/java -Xms2g ...
$ systemctl status 4188 | head -3
● elasticsearch.service - Elasticsearch
     Loaded: loaded (/usr/lib/systemd/system/elasticsearch.service; enabled)
     Active: active (running) since Sat 2026-08-30 22:01:14 -03; 14h ago
$ sudo ausearch -ts recent -k scope -i | grep -i elastic | tail -2
$ sudo last -F -s '2026-08-30 21:00' -t '2026-08-30 23:00'
deploy   pts/2  10.20.9.14  Sat Aug 30 22:00:02 2026 - Sat Aug 30 22:01:47 2026  (00:01)
```
The chain is: port → PID → user → unit → who was logged in when it started. That last step is why §7 exists.

---

## 10. Command summary for the exam

```bash
# --- SUID / SGID audit
find / -perm -4000 -type f                       # SUID files
find / -perm -2000 -type f                       # SGID files
find / -perm /6000 -type f                       # either
find / -xdev -perm -u+s -type f 2>/dev/null      # symbolic, one filesystem, quiet
chmod u-s FILE ; chmod g-s FILE                  # remove the bits
getcap -r / 2>/dev/null                          # file capabilities (the blind spot)

# --- passwords and aging
passwd [USER]            # change a password
passwd -S USER           # status: P / L / NP
passwd -Sa               # all accounts
passwd -l / -u USER      # lock / unlock
passwd -e USER           # force a change at next login
passwd -n 1 -x 90 -w 14 -i 14 USER    # min / max / warn / inactive
chage -l USER            # list aging
chage -M 90 -m 1 -W 14 -I 14 USER
chage -E 2027-03-31 USER # account expiry date
chage -d 0 USER          # force a change at next login
usermod -L / -U USER     # lock / unlock
usermod -e 2027-03-31 USER
usermod -s /usr/sbin/nologin USER

# --- limits
ulimit -a                # all current limits
ulimit -Hn / -Sn         # hard / soft open files
ulimit -n 8192           # set the soft limit
ulimit -u 512            # max user processes
ulimit -v 2097152        # virtual memory, KiB
cat /proc/PID/limits     # what a RUNNING process actually has
# /etc/security/limits.conf:  <domain> <type> <item> <value>

# --- open ports
netstat -tulpn           # TCP/UDP listening, numeric, with PID  [exam]
netstat -an              # every socket, numeric
ss -tulpn                # the modern equivalent           [production]
lsof -i :80              # who owns port 80
lsof -i TCP -sTCP:LISTEN
fuser -v -n tcp 80       # who is on the port
fuser -k -n tcp 80       # kill them
nmap -sT HOST            # connect scan, no root required
nmap -sS -p- HOST        # SYN scan, all 65535 ports, root
nmap -sU --top-ports 50 HOST
nmap -sV -p 22,80 HOST   # service versions
nmap -sn 10.0.0.0/24     # host discovery only

# --- who is / was logged in
who ; who -a ; who -b ; who am i
w ; w -h USER
users
last ; last -F ; last -a ; last -n 10 ; last reboot ; last USER
lastb                    # failed attempts (root)
lastlog ; lastlog -b 90 ; lastlog -u USER
loginctl list-sessions ; loginctl session-status N

# --- sudo / su
visudo                   # ALWAYS edit sudoers this way
visudo -c                # validate the tree
visudo -cf FILE          # validate one drop-in
sudo -l                  # what may I run?
sudo -l -U USER          # what may they run?
sudo -u USER CMD         # run as another user
sudo -i                  # root login shell
sudo -s                  # root shell, non-login
sudo -k / -K             # invalidate / remove the credential cache
sudo -v                  # refresh it
sudoedit FILE            # edit as root, safely
su - ; su - USER ; su -c 'CMD' USER
id ; whoami ; logname ; groups
```

**Highest-yield facts, condensed:**

- `-perm -4000` (all listed bits set) is the SUID audit form; `-perm 4000` (exact match) is almost always wrong.
- `/etc/shadow` field order: `name : hash : lastchange : min : max : warn : inactive : expire : reserved`. Fields 4–8 are `chage -m -M -W -I -E`.
- `passwd -l` locks the password, **not the account**; key-based SSH still works.
- `limits.conf` is enforced by `pam_limits.so` and therefore does **not** apply to systemd services.
- A hard limit can only be lowered by an unprivileged process, and never raised back.
- Only root reads `/var/log/btmp` (`lastb`).
- `utmp` = now, `wtmp` = history, `btmp` = failures, `lastlog` = last login per user.
- `nmap -sS` needs root; `-sT` does not. `closed` means the host answered; `filtered` means a firewall dropped the probe.
- In sudoers the **last matching rule wins**, and `#includedir` is a directive, not a comment.
- `visudo` is the only safe editor for sudoers; `visudo -c` is the only safe pre-flight.

---

## 11. References

**Certification objectives**
- LPI Exam 101-500 Objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI Exam 102-500 Objectives (Topic 110, Security) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 Certification Overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Manual pages and core tooling**
- `find(1)` — https://man7.org/linux/man-pages/man1/find.1.html
- `chmod(1)` and `chmod(2)` — https://man7.org/linux/man-pages/man1/chmod.1.html · https://man7.org/linux/man-pages/man2/chmod.2.html
- `passwd(1)`, `passwd(5)`, `shadow(5)` — https://man7.org/linux/man-pages/man1/passwd.1.html · https://man7.org/linux/man-pages/man5/shadow.5.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `usermod(8)`, `useradd(8)` — https://man7.org/linux/man-pages/man8/usermod.8.html · https://man7.org/linux/man-pages/man8/useradd.8.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `su(1)` — https://man7.org/linux/man-pages/man1/su.1.html
- `who(1)`, `w(1)`, `last(1)`, `lastlog(8)` — https://man7.org/linux/man-pages/man1/who.1.html · https://man7.org/linux/man-pages/man1/w.1.html · https://man7.org/linux/man-pages/man1/last.1.html · https://man7.org/linux/man-pages/man8/lastlog.8.html
- `utmp(5)` — https://man7.org/linux/man-pages/man5/utmp.5.html
- `lsof(8)` — https://man7.org/linux/man-pages/man8/lsof.8.html
- `fuser(1)` — https://man7.org/linux/man-pages/man1/fuser.1.html
- `netstat(8)`, `ss(8)` — https://man7.org/linux/man-pages/man8/netstat.8.html · https://man7.org/linux/man-pages/man8/ss.8.html
- `getrlimit(2)` / `setrlimit(2)` — https://man7.org/linux/man-pages/man2/getrlimit.2.html
- `credentials(7)` and `capabilities(7)` — https://man7.org/linux/man-pages/man7/credentials.7.html · https://man7.org/linux/man-pages/man7/capabilities.7.html
- `getcap(8)` / `setcap(8)` — https://man7.org/linux/man-pages/man8/setcap.8.html
- `execve(2)` (set-user-ID semantics) — https://man7.org/linux/man-pages/man2/execve.2.html

**sudo**
- Sudo project home — https://www.sudo.ws/
- `sudoers(5)` manual — https://www.sudo.ws/docs/man/sudoers.man/
- `sudo(8)` manual — https://www.sudo.ws/docs/man/sudo.man/
- `visudo(8)` manual — https://www.sudo.ws/docs/man/visudo.man/
- `sudoreplay(8)` manual — https://www.sudo.ws/docs/man/sudoreplay.man/
- Sudo security advisories — https://www.sudo.ws/security/advisories/
- CVE-2021-3156 (`sudoedit` heap overflow) — https://www.sudo.ws/security/advisories/unescape_overflow/
- CVE-2019-14287 (runas UID `-1` bypass) — https://www.sudo.ws/security/advisories/minus_1_uid/
- CVE-2023-22809 (`sudoedit` arbitrary file write) — https://www.sudo.ws/security/advisories/sudoedit_any/

**PAM, limits, and account policy**
- Linux-PAM documentation — https://github.com/linux-pam/linux-pam/blob/master/doc/adg/Linux-PAM_ADG.xml
- `pam_limits(8)` — https://man7.org/linux/man-pages/man8/pam_limits.8.html
- `limits.conf(5)` — https://man7.org/linux/man-pages/man5/limits.conf.5.html
- `pam_faillock(8)` — https://man7.org/linux/man-pages/man8/pam_faillock.8.html
- `pam_pwquality(8)` and `pwquality.conf(5)` — https://man7.org/linux/man-pages/man8/pam_pwquality.8.html
- `pam_access(8)` and `access.conf(5)` — https://man7.org/linux/man-pages/man5/access.conf.5.html
- shadow-utils project — https://github.com/shadow-maint/shadow

**systemd, cgroups, and resource control**
- `systemd.exec(5)` — sandboxing and rlimit directives — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.resource-control(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- `systemd-system.conf(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `loginctl(1)` and `systemd-logind.service(8)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html
- `systemd-analyze(1)` (`security` verb) — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- Kernel cgroup v2 documentation — https://docs.kernel.org/admin-guide/cgroup-v2.html
- Kernel filesystem sysctl reference (`fs.nr_open`, `fs.file-max`) — https://docs.kernel.org/admin-guide/sysctl/fs.html

**Network discovery**
- Nmap Reference Guide — https://nmap.org/book/man.html
- Nmap port scanning techniques — https://nmap.org/book/man-port-scanning-techniques.html
- Nmap port states explained — https://nmap.org/book/man-port-scanning-basics.html
- Nmap legal issues — https://nmap.org/book/legal-issues.html
- `ndiff(1)` — https://nmap.org/ndiff/
- iproute2 project — https://wiki.linuxfoundation.org/networking/iproute2

**Audit and hardening baselines**
- Linux Audit (`auditd`) project — https://github.com/linux-audit/audit-userspace
- `auditctl(8)` and `audit.rules(7)` — https://man7.org/linux/man-pages/man8/auditctl.8.html
- CIS Benchmarks (Linux) — https://www.cisecurity.org/cis-benchmarks
- DISA STIGs — https://public.cyber.mil/stigs/
- NIST SP 800-63B, Digital Identity Guidelines (authenticator and password policy) — https://pages.nist.gov/800-63-3/sp800-63b.html
- GTFOBins (sudo escape catalogue) — https://gtfobins.github.io/

**Ansible and monitoring**
- `ansible.builtin.template` (`validate:`) — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html
- `ansible.builtin.user` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- Prometheus node_exporter textfile collector — https://github.com/prometheus/node_exporter#textfile-collector
- Prometheus alerting rules — https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/