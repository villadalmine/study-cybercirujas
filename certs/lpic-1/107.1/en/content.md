# LPIC-1 · Topic 107.1 — Manage user and group accounts and related system files

**Exam:** 102-500 · **Objective weight:** 5 (the exam-blueprint value; treat the `0.0` in the generation metadata as unset)
**Key files:** `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow`, `/etc/skel`, `/etc/login.defs`, `/etc/default/useradd`, `/etc/subuid`, `/etc/subgid`
**Key commands:** `useradd`, `usermod`, `userdel`, `groupadd`, `groupmod`, `groupdel`, `passwd`, `gpasswd`, `chage`, `getent`, `id`, `pwck`, `grpck`, `vipw`, `vigr`, `newgrp`, `sg`

---

## 1. Motivation: the architectural problem this objective actually solves

At LPIC-1 level this topic reads like "how to add a user". In production it is the **identity substrate that every other access-control mechanism resolves against**. Three failure classes in real fleets trace directly back to it:

### 1.1 The UID is the only thing the kernel knows

The Linux kernel does not know user *names*. It knows a `struct cred` containing `uid`, `gid`, `euid`, `egid`, `fsuid`, `fsgid`, and a `group_info` array of supplementary GIDs. Filesystem inodes store a 32-bit UID and a 32-bit GID — never a string. `/etc/passwd` is a *presentation* layer consulted by userspace libraries to render `1000` as `deploy`.

Consequences you will meet in an incident:

- Deleting a user does not un-own their files. A later account that lands on the same UID silently inherits every one of them.
- A container image whose `USER app` maps to UID 1000, mounted over a `hostPath` owned by host UID 1000 (`alice`), grants the container full write access to Alice's data. The container has no idea, and neither does Alice.
- An NFS export shared between a node whose `postgres` is GID 26 (RHEL) and one whose `postgres` is GID 999 (Debian) produces permission failures that no `ls -l` explains, because `ls -l` is lying to you on at least one of the two boxes (`ls -ln` is not).

### 1.2 `/etc/passwd` is one NSS source among many

`getpwnam(3)` does not read `/etc/passwd`. It asks the **Name Service Switch**, which consults, in order, the modules listed in `/etc/nsswitch.conf`. `files` is merely the first and most common entry. On a modern node the same lookup may be answered by `sss` (SSSD → LDAP/AD/IPA), `systemd` (`nss-systemd`, which synthesises `DynamicUser=` service identities and `systemd-homed` users), or `ldap`.

This is why "the user is not in `/etc/passwd`, so it does not exist" is a false inference, and why `getent passwd` — which goes through NSS — is the only correct way to answer "does this account resolve on this host?".

### 1.3 Deprovisioning is an *authorization* problem, not a password problem

The single most common security finding in access reviews: an offboarded engineer whose password was locked with `passwd -l` but who still has a working SSH key. Password locking mutates the hash field in `/etc/shadow`; public-key authentication never consults that field. The correct lever is **account expiry**, enforced by the PAM *account* stack, which every authentication method must pass. Section 5 covers this in detail; it is also a favourite exam distinction.

### 1.4 Architecture of a single `id alice`

```
       id(1) / login(1) / sshd(8)
                 │
                 ▼
      glibc: getpwnam_r(3), getgrouplist(3)
                 │
                 ▼
    /etc/nsswitch.conf   passwd: files systemd sss
                 │
      ┌──────────┼───────────────┬───────────────┐
      ▼          ▼               ▼               ▼
 libnss_files  libnss_systemd  libnss_sss   (nscd/sssd cache)
   /etc/passwd   varlink IPC     UNIX socket
   /etc/group                    /var/lib/sss/pipes/nss
      │
      ▼
  struct passwd { pw_name, pw_uid, pw_gid, pw_dir, pw_shell }
      │
      ▼
  setgroups(2) / setgid(2) / setuid(2)  ← credentials frozen into the process here
      │
      ▼
  kernel struct cred  ← the ONLY thing checked at open(2)/exec(2)
```

The last arrow is the one people forget: credentials are copied into the process at login and are **immutable for that process's lifetime**. Adding a user to a group does not affect any already-running shell, systemd user session, or long-lived daemon. This is the mechanism behind "I added myself to `docker` and it still says permission denied".

---

## 2. The four account databases, field by field

### 2.1 `/etc/passwd` — 7 colon-separated fields

```
$ getent passwd deploy
deploy:x:1001:1001:Deploy Automation,,,,ticket=OPS-4412:/home/deploy:/bin/bash
```

| # | Field | Content | Production notes |
|---|---|---|---|
| 1 | `pw_name` | Login name | POSIX portable set: `[a-z_][a-z0-9_-]*[$]?`. `useradd` rejects names with `.`, uppercase, or leading digits unless `--badname` (shadow ≥ 4.13). Max length is `UT_NAMESIZE-1` = 31 for `utmp` correctness. |
| 2 | `pw_passwd` | Legacy hash slot | `x` = "look in `/etc/shadow`". An empty field means **passwordless login**. A literal hash here means shadowing is off (`pwunconv`) — a finding, not a configuration. |
| 3 | `pw_uid` | 32-bit UID | `0` = root by convention only; *any* account with UID 0 is root. Multiple UID-0 entries are legal and are a classic backdoor. |
| 4 | `pw_gid` | Primary GID | Exactly one. Applied as the `gid` of new files unless the parent dir is setgid. |
| 5 | `pw_gecos` | Comment | Comma-separated subfields: *Full Name, Room, Work Phone, Home Phone, Other*. Written by `chfn`. A colon here corrupts the file; a comma silently truncates what `finger` shows. Useful for ticket/owner tagging. |
| 6 | `pw_dir` | Home directory | Not required to exist. If it does not, `login` places you in `/` (or fails, per `pam_lastlog`/`pam_mkhomedir` config). |
| 7 | `pw_shell` | Login shell | Empty ⇒ `/bin/sh`. `/usr/sbin/nologin` and `/bin/false` are *not* equivalent (§5.3). |

Permissions: `0644 root:root`. It must be world-readable — every `ls -l` in the system depends on it.

### 2.2 `/etc/shadow` — 9 fields

```
# getent shadow deploy
deploy:$y$j9T$Ck2mQ8yUqz1Vd0Xn3Wb4B/$3JqO7pL2mR9sT1uV5wX8yZ0aB3cD6eF9gH2iJ5kL8mN:20692:1:90:14:30:20908:
```

| # | Field | Name | Meaning |
|---|---|---|---|
| 1 | `sp_namp` | Login name | Join key to `/etc/passwd`. An orphan here is what `pwck` reports. |
| 2 | `sp_pwdp` | Hash | `$id$[params]$salt$hash`. `!`/`*` prefixes and sentinels: see §3. |
| 3 | `sp_lstchg` | Last change | **Days since 1970-01-01**, not a timestamp. `0` = "must change at next login". Empty = ageing disabled. |
| 4 | `sp_min` | MIN | Days before the password *may* be changed again. Anti-cycling control; blocks the "change it 5 times to get my old one back" trick when combined with `pam_pwhistory`. |
| 5 | `sp_max` | MAX | Days before the password *must* be changed. |
| 6 | `sp_warn` | WARN | Days of warning before MAX expiry. |
| 7 | `sp_inact` | INACTIVE | Grace days **after** password expiry during which login still works but forces a change. Empty = no grace; the account dies the moment the password expires. |
| 8 | `sp_expire` | EXPIRE | Absolute account death, in days since epoch. **Independent of the password.** This is the offboarding field. |
| 9 | — | Reserved | Unused. |

Compute the epoch-day values rather than guessing:

```
$ date -u -d "2026-08-27" +%s | awk '{print int($1/86400)}'
20692
$ date -u -d "@$((20908*86400))" +%F
2027-03-31
```

Permissions differ by distribution, and both are correct:

```
$ stat -c '%A %U:%G %n' /etc/shadow          # Debian/Ubuntu
-rw-r----- root:shadow /etc/shadow

$ stat -c '%A %U:%G %n' /etc/shadow          # RHEL/Fedora/SUSE
---------- root:root /etc/shadow
```

Mode `0000` is not a bug: root bypasses DAC via `CAP_DAC_OVERRIDE`, and the file becomes unreadable to *everything* else, including a compromised process that gained a non-root capability set. Debian instead grants read to group `shadow` so that setgid helpers (`unix_chkpwd`) can verify passwords without being setuid-root.

### 2.3 `/etc/group` — 4 fields

```
$ getent group platform
platform:x:4200:deploy,alice,bob
```

| # | Field | Meaning |
|---|---|---|
| 1 | Group name | |
| 2 | Password | `x` ⇒ `/etc/gshadow`. Used only by `newgrp`/`sg` to let a non-member join. Almost always unset. |
| 3 | GID | |
| 4 | Member list | Comma-separated, **supplementary members only**. |

**The critical asymmetry:** a user's *primary* group membership lives in `/etc/passwd` field 4 and is **not** repeated in field 4 of `/etc/group`. So this is normal and complete:

```
$ getent passwd alice
alice:x:1000:1000:Alice Ng:/home/alice:/bin/bash
$ getent group alice
alice:x:1000:                     ← empty member list, yet alice IS in group alice
$ id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),4200(platform),27(sudo)
```

Any script that determines membership by parsing `/etc/group` alone is wrong. Use `id -nG` or `getent initgroups`.

### 2.4 `/etc/gshadow` — 4 fields

```
# getent gshadow platform
platform:!:alice:deploy,alice,bob
```

Fields: *name : encrypted group password : group administrators : members*. The administrators list (field 3) is what `gpasswd -A` sets — a delegated user who can add and remove members with `gpasswd` without holding root. The member list is kept in sync with `/etc/group` by `gpasswd`; hand-editing one and not the other is exactly what `grpck` catches. On systems without gshadow support the file is absent and `gpasswd -A` fails.

---

## 3. Password hashes: format, algorithms, sentinels

### 3.1 Modular Crypt Format

```
$y$j9T$Ck2mQ8yUqz1Vd0Xn3Wb4B/$3JqO7pL2mR9sT1uV5wX8yZ0aB3cD6eF9gH2iJ5kL8mN
 │  │            │                              │
 │  │            └── salt                       └── hash
 │  └── algorithm parameters (yescrypt cost)
 └── algorithm id
```

| Prefix | Algorithm | Tunable | Status | Notes |
|---|---|---|---|---|
| *(none)* | DES-crypt | — | **Broken** | 8-char password truncation, 12-bit salt. Only in fossils. |
| `$1$` | MD5-crypt | none | **Broken** | 1000 fixed iterations. Still the default on some appliances. |
| `$2a$ $2b$ $2y$` | bcrypt | cost 4–31 | Acceptable | 72-byte input truncation. `$2a$` has a legacy 8-bit-char bug; `$2b$` is the fixed variant. |
| `$5$` | SHA-256-crypt | `rounds=` | Acceptable | Default 5000 rounds. GPU-friendly. |
| `$6$` | SHA-512-crypt | `rounds=` | **Common default** | Default 5000 rounds; raise via `SHA_CRYPT_MIN_ROUNDS`. Still cheap on GPUs. |
| `$7$` | scrypt | N, r, p | Good | Memory-hard. Rare as a login default. |
| `$y$` | **yescrypt** | cost class | **Preferred** | Memory-hard; default on Debian 11+, Fedora 35+, RHEL 9. Requires libxcrypt. |
| `$gy$` | gost-yescrypt | cost class | Regional | Russian GOST R 34.11-2012 core. |

Setting the fleet default:

```
# grep -E '^(ENCRYPT_METHOD|SHA_CRYPT|YESCRYPT)' /etc/login.defs
ENCRYPT_METHOD YESCRYPT
YESCRYPT_COST_FACTOR 5
SHA_CRYPT_MIN_ROUNDS 100000
SHA_CRYPT_MAX_ROUNDS 100000
```

Changing this **does not rehash existing passwords**. Hashes are upgraded lazily on the next `passwd` run. Force the migration with an expiry sweep (§7.4).

### 3.2 Sentinel values in field 2 — memorise this table

| Value | Meaning | Password auth | SSH pubkey auth |
|---|---|---|---|
| `$y$...` | Valid hash | ✅ | ✅ |
| `` (empty) | **No password required** | ✅ *logs in with no password* | ✅ |
| `*` | No valid password, never had one | ❌ | ✅ |
| `!` | Locked (`usermod -L`, `passwd -l`) | ❌ | ✅ **← the offboarding trap** |
| `!!` | Locked, never set (RHEL `useradd` default) | ❌ | ✅ |
| `!$y$...` | Locked, hash preserved for later unlock | ❌ | ✅ |
| `*LK*` | Locked (Solaris heritage; some appliances) | ❌ | ✅ |

The whole right-hand column is why §5.3 exists.

---

## 4. Policy: `login.defs`, `/etc/default/useradd`, `/etc/skel`

### 4.1 `/etc/login.defs` — the fleet-wide policy file

```
# grep -Ev '^\s*(#|$)' /etc/login.defs
MAIL_DIR        /var/spool/mail
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
SUB_UID_MIN            100000
SUB_UID_MAX         600100000
SUB_UID_COUNT           65536
GID_MIN                  1000
GID_MAX                 60000
SYS_GID_MIN               201
SYS_GID_MAX               999
SUB_GID_MIN            100000
SUB_GID_MAX         600100000
SUB_GID_COUNT           65536
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14
ENCRYPT_METHOD YESCRYPT
UMASK           077
HOME_MODE       0700
USERGROUPS_ENAB yes
CREATE_HOME     yes
```

Ranges that matter architecturally:

| Range | Purpose | Allocation |
|---|---|---|
| `0` | root | Fixed |
| `1–200` | Statically assigned system accounts (`bin`, `daemon`, `mail`, `lp`) | Distribution-controlled, ABI-stable across hosts |
| `201–999` | Dynamically assigned system accounts (`SYS_UID_MIN..SYS_UID_MAX`) | `useradd -r` picks top-down. **Host-specific — never assume it matches across nodes.** |
| `1000–60000` | Human/regular accounts | `useradd` picks bottom-up |
| `65534` | `nobody`/`nogroup` | NFS `root_squash` target |
| `100000–600100000` | Sub-UID ranges for user namespaces | `/etc/subuid` |

The 201–999 dynamic band is a real fleet hazard: `useradd -r postgres` on two freshly installed nodes can yield different UIDs depending on package installation order. Any shared storage between those nodes then mismatches. **Pin system UIDs explicitly in configuration management** (§6.3).

`USERGROUPS_ENAB yes` is the **User Private Group** scheme: every user gets a same-named group as their primary, letting `UMASK 002` be safe for collaborative setgid directories. Note the coupled behaviour — with `USERGROUPS_ENAB yes`, `userdel` also removes the user's primary group if no one else uses it.

`HOME_MODE` (shadow ≥ 4.7) sets home-directory permissions directly; without it the mode derives from `0777 & ~UMASK`.

### 4.2 `/etc/default/useradd` — `useradd`'s own defaults

```
$ useradd -D
GROUP=100
HOME=/home
INACTIVE=30
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes
```

Written non-interactively with `-D`:

```
# useradd -D --inactive 30 --shell /bin/bash --base-dir /home
# grep -E '^(INACTIVE|SHELL)' /etc/default/useradd
SHELL=/bin/bash
INACTIVE=30
```

`GROUP=100` (`users`) applies only when `USERGROUPS_ENAB` is `no` and no `-g` is given.

### 4.3 `/etc/skel`

Copied into the new home directory at creation time — **once**. It is not a template that stays in sync; editing `/etc/skel/.bashrc` afterwards changes nothing for existing users. Dotfiles are copied preserving mode but re-owned to the new user.

```
# ls -la /etc/skel
total 24
drwxr-xr-x   3 root root 4096 Aug 27 09:12 .
drwxr-xr-x 142 root root 8192 Aug 27 09:10 ..
-rw-r--r--   1 root root  220 Mar 31 03:41 .bash_logout
-rw-r--r--   1 root root 3771 Mar 31 03:41 .bashrc
-rw-r--r--   1 root root  807 Mar 31 03:41 .profile
drwx------   2 root root 4096 Aug 27 09:12 .ssh
```

Do **not** put a private key or a shared `authorized_keys` in `/etc/skel/.ssh` — every account created afterwards receives it, and rotating it is impossible retroactively.

---

## 5. Command reference with production semantics

### 5.1 Creating accounts

```
# useradd --uid 4310 \
          --gid platform \
          --groups docker,adm \
          --comment "Deploy Automation,,,,ticket=OPS-4412" \
          --home-dir /srv/deploy \
          --create-home \
          --shell /bin/bash \
          --expiredate 2027-03-31 \
          --inactive 30 \
          deploy

# getent passwd deploy
deploy:x:4310:4200:Deploy Automation,,,,ticket=OPS-4412:/srv/deploy:/bin/bash
# getent shadow deploy
deploy:!:20692:0:99999:7:30:20908:
```

Note the hash is `!` — **`useradd` never sets a password**. The account exists and cannot authenticate by password. Set one non-interactively:

```
# printf 'deploy:%s\n' "$(openssl rand -base64 24)" | chpasswd
# passwd --expire deploy          # force change at first login (sets sp_lstchg=0)
# getent shadow deploy
deploy:$y$j9T$Ck2mQ8y...$3JqO7pL...:0:0:99999:7:30:20908:
```

Never pass a plaintext password on a command line (`useradd -p` expects a *hash*, not plaintext — a very common and dangerous mistake; `useradd -p hunter2` stores `hunter2` literally as the "hash" and makes the account unloginnable while looking configured). Both `useradd -p` and any plaintext argument land in shell history and in `/proc/<pid>/cmdline`, readable fleet-wide for the lifetime of the process.

**System accounts:**

```
# useradd --system --uid 480 --gid 480 \
          --home-dir /var/lib/exporter --no-create-home \
          --shell /usr/sbin/nologin \
          --comment "node_exporter service account" node_exporter
```

`--system` implies: allocate from `SYS_UID_MIN..SYS_UID_MAX`, no home creation, no password ageing (`sp_max` empty), and — crucially — the account is **never expired** by default.

### 5.2 Modifying accounts — the `-a` trap and other footguns

```
# id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo),4200(platform)

# usermod -G docker alice          ### WRONG — replaces the entire supplementary list
# id alice
uid=1000(alice) gid=1000(alice) groups=1000(alice),135(docker)
                                            ↑ sudo and platform silently destroyed

# usermod -aG docker alice         ### CORRECT — append
```

`-a` is only valid with `-G`. There is no confirmation, no warning, and no undo. This is the single highest-frequency production incident in this objective.

| Operation | Command | Touches existing files? |
|---|---|---|
| Change UID | `usermod -u 4311 deploy` | Auto-chowns files **inside the home directory** only. Everything else (`/srv`, `/var/log`, NFS) must be fixed manually. |
| Change primary GID | `usermod -g newgrp deploy` | Same rule: home tree only. |
| Change GID of a group | `groupmod -g 4201 platform` | **Nothing.** Every file with the old GID is orphaned. |
| Rename user | `usermod -l newname old` | Does **not** rename the home directory, the mail spool, or the user's private group. |
| Move home | `usermod -d /srv/new -m deploy` | `-m` moves contents; without `-m` only the field changes and the old dir is left behind. |

Correct UID migration, with the full-filesystem sweep:

```
# OLD=1001 NEW=4311
# systemctl stop deploy.service
# loginctl terminate-user deploy 2>/dev/null; pkill -KILL -u "$OLD"
# usermod -u "$NEW" deploy
# find / -xdev \( -path /proc -o -path /sys \) -prune -o \
       -uid "$OLD" -print0 | xargs -0 --no-run-if-empty chown -h "$NEW"
# find / -xdev -uid "$OLD" -print | head
# systemctl start deploy.service
```

`-xdev` per filesystem, `-h` to catch symlinks, `-print0`/`-0` for pathological filenames.

### 5.3 Disabling access — the four levers are not interchangeable

| Mechanism | Command | Blocks password login | Blocks SSH **key** login | Blocks `su`/`sudo -u` | Reversible | Enforced by |
|---|---|---|---|---|---|---|
| Lock password | `passwd -l u` / `usermod -L u` | ✅ | ❌ | ❌ | `passwd -u` / `usermod -U` | `pam_unix` (auth) |
| Delete password | `passwd -d u` | ⚠️ **grants passwordless login** | ❌ | ❌ | — | `pam_unix` (auth) |
| **Expire account** | `chage -E 0 u` / `usermod -e 1 u` | ✅ | ✅ | ✅ | `chage -E -1 u` | `pam_unix` (**account**) |
| No-login shell | `usermod -s /usr/sbin/nologin u` | ⚠️ partial | ⚠️ partial | ✅ interactive | restore shell | `sshd`/`login` exec |

Demonstration of the trap:

```
# usermod -L bob
# getent shadow bob
bob:!$y$j9T$Xk1...:20655:1:90:14:30::
$ ssh bob@node01
Enter passphrase for key '/home/bob/.ssh/id_ed25519':
bob@node01:~$ id
uid=1002(bob) gid=1002(bob) groups=1002(bob),27(sudo)      ← still in, still sudo
```

The correct offboarding primitive:

```
# chage -E 0 bob
# chage -l bob
Last password change                                    : Jul 21, 2026
Password expires                                        : Oct 19, 2026
Password inactive                                       : Nov 18, 2026
Account expires                                         : Aug 26, 2026
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14

$ ssh bob@node01
Enter passphrase for key '/home/bob/.ssh/id_ed25519':
Your account has expired; please contact your system administrator
Connection closed by 10.20.0.11 port 22
```

`chage -E 0` means "expired on 1970-01-02" (day 0 is treated as "no expiry" by some tools, hence `usermod -e 1` as the unambiguous equivalent). The check happens in the PAM **account** phase, which runs after *every* authentication method succeeds — password, key, GSSAPI, certificate. That is why it is the only complete lever.

The `nologin` shell caveat: it stops interactive shells and `ssh host command`, but a session that never needs a shell still works:

```
$ ssh -N -L 8443:127.0.0.1:8443 svcacct@node01     # tunnel established: no shell is exec'd
```

So `nologin` is a UX/ergonomics control for service accounts, not a security boundary. Use `chage -E`, and additionally strip `authorized_keys` and revoke any SSH CA certificate.

Full offboarding runbook:

```
# U=bob
# chage -E 0 "$U"                                   # 1. authorization revoked (all methods)
# usermod -L "$U"                                   # 2. defence in depth
# gpasswd -d "$U" sudo; gpasswd -d "$U" wheel       # 3. drop privilege groups
# install -m 0600 -o root -g root /dev/null /home/$U/.ssh/authorized_keys   # 4. keys
# loginctl terminate-user "$U"                      # 5. kill live sessions
# pkill -KILL -u "$U"
# crontab -r -u "$U" 2>/dev/null; rm -f /var/spool/cron/atjobs/*"$U"*
# find / -xdev -user "$U" -perm /4000 -o -user "$U" -perm /2000 | tee /tmp/$U-setxid.txt
# last -F "$U" | head                               # 6. evidence for the ticket
```

Delete the account only after the data-retention window closes (§5.4).

### 5.4 Deletion

```
# userdel deploy                       # entry removed; home and files remain
# userdel -r deploy                    # also removes home dir + mail spool
# userdel -rf deploy                   # -f: proceed even if logged in / home shared
```

`userdel` refuses if the user is currently logged in (unless `-f`), but it does **not** check for running processes not attached to a session, nor for files outside the home directory. Two mandatory follow-ups:

```
# find / -xdev -nouser -o -xdev -nogroup 2>/dev/null | head -20
/srv/deploy/artifacts/build-4412.tar.gz
/var/log/deploy/agent.log
/var/spool/cron/crontabs/deploy
```

```
# grep -rn '\bdeploy\b' /etc/sudoers /etc/sudoers.d/ /etc/ssh/sshd_config \
       /etc/ssh/sshd_config.d/ /etc/cron.d/ /etc/systemd/system/ 2>/dev/null
/etc/sudoers.d/10-deploy:1:deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart app
/etc/systemd/system/app.service:8:User=deploy
```

A `sudoers` line referencing a deleted user is inert *until* a new account is created with that name — at which point it becomes an unintentional privilege grant. Clean sudoers in the same change window.

`-f` also forces removal of the user's group even when it is another user's primary group, which corrupts that user. Use `-f` deliberately.

### 5.5 Groups

```
# groupadd --gid 4200 --system platform
# groupmod --new-name platform-eng platform
# gpasswd --add alice platform-eng
Adding user alice to group platform-eng
# gpasswd --delete bob platform-eng
Removing user bob from group platform-eng
# gpasswd --administrators alice platform-eng      # delegate membership control
# gpasswd --members alice,carol,dan platform-eng   # replace member list wholesale
# groupdel platform-eng
groupdel: cannot remove the primary group of user 'svcapp'
```

| Task | `usermod` | `gpasswd` |
|---|---|---|
| Add one member | `usermod -aG grp user` | `gpasswd -a user grp` |
| Remove one member | *(no direct form)* | `gpasswd -d user grp` |
| Replace all groups of a **user** | `usermod -G g1,g2 user` | — |
| Replace all members of a **group** | — | `gpasswd -M u1,u2 grp` |
| Needs root | yes | yes, or be a group admin |

`gpasswd -d` is the reason `gpasswd` is worth learning: removing a single group from a user with `usermod` requires reconstructing the full `-G` list, which is exactly how the §5.2 accident happens.

**Group changes and running processes:**

```
$ id -nG
alice platform-eng
# gpasswd -a alice docker
$ id -nG                        # ← NSS lookup: shows the NEW state
alice platform-eng docker
$ docker ps
permission denied while trying to connect to the Docker daemon socket
$ id -nG -- < /dev/null; grep ^Groups /proc/$$/status   # ← the process's ACTUAL creds
Groups:	4200
```

`id` without arguments in some shells re-queries NSS; `/proc/self/status` shows the truth the kernel enforces. Fixes, in order of preference: log out and back in; `loginctl terminate-user alice`; or start a new credential set in-place:

```
$ exec newgrp docker           # new shell, docker becomes the PRIMARY group
$ sg docker -c 'docker ps'     # run one command with docker added
```

`newgrp` changes the *primary* GID for the new shell (affecting the group ownership of files it creates); `sg` runs a single command. Neither can grant a group the user is not actually a member of — unless the group has a password in `/etc/gshadow`, which is the only remaining use of that field.

### 5.6 Ageing with `chage`

```
# chage -m 1 -M 90 -W 14 -I 30 -E 2027-03-31 deploy
# chage -l deploy
Last password change                                    : Aug 27, 2026
Password expires                                        : Nov 25, 2026
Password inactive                                       : Dec 25, 2026
Account expires                                         : Mar 31, 2027
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

Two-axis mental model:

```
 password axis:  lstchg ──MIN──┤ may change  ──────MAX─────▶ expired ──INACT──▶ dead
 account  axis:  ─────────────────────────────────────────────────────▶ EXPIRE ▶ dead
                                                             (independent, absolute)
```

- `PASS_MAX_DAYS` in `login.defs` applies only to accounts created *after* it is set. Existing accounts keep their `/etc/shadow` values — hence the sweep in §7.4.
- `chage -d 0 user` forces a change at next login (identical to `passwd -e`). Note `chage -d 0` on a *service* account with `nologin` bricks it: `sshd` will try to run the password-change dialogue, fail, and deny the connection.
- Ageing fields are ignored entirely when the account resolves via SSSD/LDAP; the directory's own policy applies. Setting `chage` values on an AD user silently does nothing.

### 5.7 `getent` — the only correct query tool

```
$ getent passwd 4310                       # by UID
deploy:x:4310:4200:Deploy Automation,,,,ticket=OPS-4412:/srv/deploy:/bin/bash

$ getent group docker
docker:x:135:alice,deploy

$ getent initgroups alice                  # the authoritative supplementary list
alice 1000 4200 27 135

$ getent -s files passwd deploy            # bypass NSS order, query files only
deploy:x:4310:4200:...

$ getent -s sss passwd svc-ci              # query SSSD only
svc-ci:*:1802400513:1802400513:CI Service:/home/svc-ci:/bin/bash

$ getent passwd | wc -l
64
```

That last count is a trap on directory-backed hosts: **`getent passwd` with no key does not enumerate LDAP/AD users** unless `enumerate = True` is set in `sssd.conf` (it is off by default, for good reason — enumerating a 200 000-user AD domain on every `ls -l` is a self-inflicted outage). So a domain user can be fully functional and invisible in `getent passwd`. Always query by key.

---

## 6. Infrastructure as code — complete manifests

### 6.1 Ansible: full account and group provisioning role

```yaml
---
# roles/identity/defaults/main.yml
identity_password_policy:
  pass_max_days: 90
  pass_min_days: 1
  pass_warn_age: 14
  encrypt_method: YESCRYPT
  umask: "077"
  home_mode: "0700"

identity_groups:
  - name: platform-eng
    gid: 4200
    system: false
  - name: sre-oncall
    gid: 4201
    system: false
  - name: node_exporter
    gid: 480
    system: true

identity_users:
  - name: alice
    uid: 4001
    comment: "Alice Ng,SRE,+34-600-000-001,,ticket=IDM-1001"
    primary_group: alice
    groups: [platform-eng, sre-oncall, sudo]
    shell: /bin/bash
    home: /home/alice
    create_home: true
    expires_on: ""                 # empty string => never
    ssh_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB2n+5m7Qy8vT0aXcZ1oL4pW9sR3fH6kJ2dM8gN1bV0c alice@corp"
    state: present

  - name: bob
    uid: 4002
    comment: "Bob Reyes,SRE,,,ticket=IDM-1002"
    primary_group: bob
    groups: [platform-eng]
    shell: /bin/bash
    home: /home/bob
    create_home: true
    expires_on: "2026-08-26"       # offboarded
    ssh_keys: []
    state: present

  - name: node_exporter
    uid: 480
    comment: "Prometheus node_exporter service account"
    primary_group: node_exporter
    groups: []
    shell: /usr/sbin/nologin
    home: /var/lib/node_exporter
    create_home: false
    system: true
    expires_on: ""
    ssh_keys: []
    state: present
```

```yaml
---
# roles/identity/tasks/main.yml
- name: Enforce fleet-wide password and UID policy in /etc/login.defs
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*{{ item.key }}\\b"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    owner: root
    group: root
    mode: "0644"
    validate: "/usr/bin/test -r %s"
  loop:
    - { key: PASS_MAX_DAYS, value: "{{ identity_password_policy.pass_max_days }}" }
    - { key: PASS_MIN_DAYS, value: "{{ identity_password_policy.pass_min_days }}" }
    - { key: PASS_WARN_AGE, value: "{{ identity_password_policy.pass_warn_age }}" }
    - { key: ENCRYPT_METHOD, value: "{{ identity_password_policy.encrypt_method }}" }
    - { key: UMASK, value: "{{ identity_password_policy.umask }}" }
    - { key: HOME_MODE, value: "{{ identity_password_policy.home_mode }}" }
    - { key: USERGROUPS_ENAB, value: "yes" }
  loop_control:
    label: "{{ item.key }}"
  tags: [identity, policy]

- name: Create groups with pinned GIDs
  ansible.builtin.group:
    name: "{{ item.name }}"
    gid: "{{ item.gid }}"
    system: "{{ item.system | default(false) }}"
    state: present
  loop: "{{ identity_groups }}"
  loop_control:
    label: "{{ item.name }} (gid={{ item.gid }})"
  tags: [identity, groups]

- name: Create user private groups with pinned GIDs
  ansible.builtin.group:
    name: "{{ item.primary_group }}"
    gid: "{{ item.uid }}"
    system: "{{ item.system | default(false) }}"
    state: present
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - item.primary_group == item.name
  loop_control:
    label: "{{ item.primary_group }}"
  tags: [identity, groups]

- name: Create and configure accounts with pinned UIDs
  ansible.builtin.user:
    name: "{{ item.name }}"
    uid: "{{ item.uid }}"
    group: "{{ item.primary_group }}"
    groups: "{{ item.groups | join(',') }}"
    append: false                       # declarative: the manifest is the truth
    comment: "{{ item.comment }}"
    shell: "{{ item.shell }}"
    home: "{{ item.home }}"
    create_home: "{{ item.create_home }}"
    system: "{{ item.system | default(false) }}"
    expires: >-
      {{ (item.expires_on | to_datetime('%Y-%m-%d')).timestamp()
         if item.expires_on | length > 0 else -1 }}
    password_lock: "{{ item.expires_on | length > 0 }}"
    state: "{{ item.state }}"
    remove: false                       # never auto-delete home data
  loop: "{{ identity_users }}"
  loop_control:
    label: "{{ item.name }} (uid={{ item.uid }})"
  tags: [identity, users]

- name: Install authorized_keys declaratively
  ansible.posix.authorized_key:
    user: "{{ item.name }}"
    key: "{{ item.ssh_keys | join('\n') }}"
    exclusive: true                     # removes any key not in the manifest
    manage_dir: true
    state: present
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - item.create_home | bool
  loop_control:
    label: "{{ item.name }} ({{ item.ssh_keys | length }} keys)"
  tags: [identity, ssh]

- name: Enforce password ageing on existing accounts
  ansible.builtin.command:
    argv:
      - /usr/bin/chage
      - --mindays
      - "{{ identity_password_policy.pass_min_days }}"
      - --maxdays
      - "{{ identity_password_policy.pass_max_days }}"
      - --warndays
      - "{{ identity_password_policy.pass_warn_age }}"
      - "{{ item.name }}"
  loop: "{{ identity_users }}"
  when:
    - item.state == 'present'
    - not (item.system | default(false))
  changed_when: false
  loop_control:
    label: "{{ item.name }}"
  tags: [identity, ageing]

- name: Verify account database consistency
  ansible.builtin.command:
    argv: [/usr/sbin/pwck, --read-only, --quiet]
  register: identity_pwck
  changed_when: false
  failed_when: identity_pwck.rc not in [0, 2]
  tags: [identity, verify]

- name: Verify group database consistency
  ansible.builtin.command:
    argv: [/usr/sbin/grpck, --read-only]
  register: identity_grpck
  changed_when: false
  failed_when: identity_grpck.rc != 0
  tags: [identity, verify]

- name: Assert no unauthorised UID 0 accounts exist
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      getent passwd | awk -F: '$3 == 0 { print $1 }' | sort
    executable: /bin/bash
  register: identity_uid0
  changed_when: false
  failed_when: identity_uid0.stdout_lines | reject('eq', 'root') | list | length > 0
  tags: [identity, verify]
```

Run and output:

```
$ ansible-playbook -i inventories/prod site.yml --tags identity --diff

PLAY [nodes] *******************************************************************

TASK [identity : Create groups with pinned GIDs] *******************************
ok: [node01] => (item=platform-eng (gid=4200))
ok: [node01] => (item=sre-oncall (gid=4201))
changed: [node01] => (item=node_exporter (gid=480))

TASK [identity : Create and configure accounts with pinned UIDs] ****************
ok: [node01] => (item=alice (uid=4001))
changed: [node01] => (item=bob (uid=4002))
changed: [node01] => (item=node_exporter (uid=480))

TASK [identity : Install authorized_keys declaratively] ************************
ok: [node01] => (item=alice (1 keys))
changed: [node01] => (item=bob (0 keys))

TASK [identity : Assert no unauthorised UID 0 accounts exist] ******************
ok: [node01]

PLAY RECAP *********************************************************************
node01   : ok=9    changed=4    unreachable=0    failed=0    skipped=1
```

Note `append: false` in the user task. It makes the manifest authoritative: a group added by hand on the node is removed on the next converge. That is the point of declarative identity — but it means the §5.2 destructive `-G` behaviour is now a *feature* you must be aware of.

### 6.2 cloud-init: first-boot identity for immutable images

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
users:
  - name: root
    lock_passwd: true

  - name: ops
    uid: 4000
    primary_group: ops
    groups: [adm, systemd-journal, sudo]
    gecos: "Break-glass operator,,,,ticket=IDM-0001"
    shell: /bin/bash
    homedir: /home/ops
    create_groups: true
    lock_passwd: true                  # no password auth; keys only
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHq4vN2wS8xY0bR7tK5mL9cP3fJ6dG1nZ4aQ8sW2eU5v ops@bastion"
    ssh_redirect_user: false

  - name: node_exporter
    uid: 480
    primary_group: node_exporter
    gecos: "Prometheus node_exporter"
    shell: /usr/sbin/nologin
    homedir: /var/lib/node_exporter
    system: true
    no_create_home: true
    lock_passwd: true

groups:
  - ops: []
  - platform-eng: [ops]

write_files:
  - path: /etc/login.defs.d/00-fleet-policy.conf
    owner: root:root
    permissions: "0644"
    content: |
      PASS_MAX_DAYS   90
      PASS_MIN_DAYS   1
      PASS_WARN_AGE   14
      ENCRYPT_METHOD  YESCRYPT
      UMASK           077
      HOME_MODE       0700
      SYS_UID_MIN     201
      SYS_UID_MAX     999
      UID_MIN         1000
      UID_MAX         60000

  - path: /etc/subuid
    owner: root:root
    permissions: "0644"
    content: |
      ops:100000:65536

  - path: /etc/subgid
    owner: root:root
    permissions: "0644"
    content: |
      ops:100000:65536

  - path: /etc/sudoers.d/10-platform-eng
    owner: root:root
    permissions: "0440"
    content: |
      %platform-eng ALL=(ALL) PASSWD: /usr/bin/systemctl, /usr/bin/journalctl

ssh_pwauth: false
disable_root: true

runcmd:
  - [ /usr/sbin/pwck,  --read-only, --quiet ]
  - [ /usr/sbin/grpck, --read-only ]
  - [ /usr/bin/getent, passwd, "4000" ]
  - [ /usr/sbin/visudo, -c, -f, /etc/sudoers.d/10-platform-eng ]
```

`lock_passwd: true` is cloud-init's default and produces `!` in `/etc/shadow` — combined with `ssh_pwauth: false` this is correct for key-only fleets, but recall §5.3: it is not a deprovisioning mechanism.

### 6.3 `systemd-sysusers`: packaged, idempotent, declarative system accounts

Packages should not run `useradd` in a `%post` script. `sysusers.d` is the declarative equivalent, executed by `systemd-sysusers.service` before any unit that needs the account.

```
# /usr/lib/sysusers.d/node_exporter.conf
#Type Name           ID       GECOS                          Home                    Shell
u     node_exporter  480:480  "Prometheus node_exporter"     /var/lib/node_exporter  /usr/sbin/nologin
g     metrics-read   481      -                              -                       -
m     node_exporter  metrics-read
r     -              60000-60999
```

| Type | Meaning |
|---|---|
| `u` | Create user (and matching group). `ID` may be `uid`, `uid:gid`, `uid:groupname`, or `-` for auto. |
| `g` | Create group only. |
| `m` | Add an existing user to an existing group. |
| `r` | Reserve a UID/GID range so automatic allocation skips it. |

```
# systemd-sysusers --dry-run /usr/lib/sysusers.d/node_exporter.conf
Creating group 'node_exporter' with GID 480.
Creating user 'node_exporter' (Prometheus node_exporter) with UID 480 and GID 480.
Creating group 'metrics-read' with GID 481.
Adding user 'node_exporter' to group 'metrics-read'.

# systemd-sysusers
# getent passwd node_exporter
node_exporter:x:480:480:Prometheus node_exporter:/var/lib/node_exporter:/usr/sbin/nologin
```

The file is idempotent by construction: it never modifies an account that already exists, so re-running it after a manual change does not clobber operator intent — the opposite trade-off from Ansible's `append: false`.

### 6.4 Where this collides with Kubernetes: UID as a cross-boundary contract

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-shipper
  namespace: observability
spec:
  replicas: 3
  selector:
    matchLabels: { app: log-shipper }
  template:
    metadata:
      labels: { app: log-shipper }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 480             # MUST equal the host UID that owns /var/log/pods
        runAsGroup: 480
        fsGroup: 481               # kubelet chowns emptyDir/PVC volumes to this GID
        fsGroupChangePolicy: OnRootMismatch
        supplementalGroups: [4]     # host 'adm' — grants read on /var/log on Debian
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: shipper
          image: registry.internal/log-shipper:2.14.0
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: state
              mountPath: /var/lib/shipper
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 256Mi }
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
            type: Directory
        - name: state
          emptyDir: {}
```

`runAsUser: 480` is a **numeric assertion about the host's `/etc/passwd`**. The container has its own `/etc/passwd` (often none at all), and the kernel resolves `open("/var/log/pods/...")` purely against UID 480 and the supplementary GID list. If node images are built by two different pipelines and one allocated `node_exporter` from the dynamic 201–999 band while the other pinned 480, the same manifest reads logs on half the fleet and gets `EACCES` on the other half. This is precisely why §4.1 insists on pinning system UIDs.

`supplementalGroups: [4]` is `adm` on Debian-family hosts and does not exist on RHEL — another reason `getent group` on the actual node is a deployment prerequisite, not a detail.

### 6.5 User namespaces: `/etc/subuid` and `/etc/subgid`

```
$ cat /etc/subuid
ops:100000:65536
alice:165536:65536
$ cat /etc/subgid
ops:100000:65536
alice:165536:65536
```

Format: `owner:first_subordinate_id:count`. This delegates a range of *unprivileged* IDs that the owner may map inside a user namespace — the mechanism behind rootless Podman and rootless Docker. Inside the namespace the process is UID 0; outside, the kernel sees UID 100000.

```
$ podman unshare cat /proc/self/uid_map
         0       4000          1
         1     100000      65536

$ podman run --rm -it alpine sh -c 'id; touch /tmp/f; stat -c %u /tmp/f'
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
0

$ podman unshare stat -c '%u %U' ~/.local/share/containers/storage/overlay
0 root
$ stat -c '%u %U' ~/.local/share/containers/storage/overlay
100000 UNKNOWN
```

`usermod --add-subuids 200000-265535 --add-subgids 200000-265535 alice` manages these ranges; `useradd` allocates them automatically when `SUB_UID_MIN`/`SUB_UID_COUNT` are set in `login.defs`. Ranges must not overlap between users — overlapping subuid ranges mean two "rootless" users can read each other's container filesystems, silently defeating the isolation.

---

## 7. Verification and failure diagnosis

### 7.1 Consistency checkers

```
# pwck --read-only
user 'lp': directory '/var/spool/lpd' does not exist
user 'news': directory '/var/spool/news' does not exist
user 'olduser': no group 4998
pwck: no changes

# echo $?
2
```

`pwck` exit codes: `0` ok · `1` cannot open · `2` **one or more bad entries** · `3` cannot lock · `4` cannot rewrite · `5` cannot sort. "directory does not exist" for system accounts is normal noise; "no group NNNN" is a real dangling reference — that user's primary GID resolves to nothing, and every file they create shows a bare number.

```
# grpck --read-only
'platform-eng' is a member of the 'ghostuser' group in /etc/gshadow but not in /etc/group
grpck: no changes
# echo $?
2
```

`pwck` and `grpck` also detect: duplicate names, duplicate UIDs/GIDs, wrong field counts, non-numeric UID fields, `/etc/shadow` entries with no `/etc/passwd` counterpart, and vice versa. Run both in CI on golden images and in the converge pipeline (§6.1).

Convert between shadowed and non-shadowed:

```
# pwconv     # /etc/passwd  → /etc/shadow   (moves hashes out, writes 'x')
# pwunconv   # /etc/shadow  → /etc/passwd   (DANGEROUS: hashes become world-readable)
# grpconv    # /etc/group   → /etc/gshadow
# grpunconv  # /etc/gshadow → /etc/group
```

### 7.2 Safe editing and the lock file

Never open `/etc/passwd` in an editor directly. `useradd`, `usermod` and `passwd` take an advisory lock via `/etc/.pwd.lock`; a plain editor does not, so a converge run and your `vim` session can interleave writes and truncate the file.

```
# vipw            # edits /etc/passwd  with locking, then offers /etc/shadow
# vipw -s         # edits /etc/shadow  with locking
# vigr            # edits /etc/group   with locking
# vigr -s         # edits /etc/gshadow with locking
```

`vipw` runs `pwck`-style validation on save and refuses to install a syntactically broken file. It also leaves `/etc/passwd-`, `/etc/shadow-` backups (mode `0600`) — which are themselves a finding if they end up world-readable:

```
# stat -c '%a %U:%G %n' /etc/shadow /etc/shadow- /etc/gshadow /etc/gshadow-
0 root:root /etc/shadow
0 root:root /etc/shadow-
0 root:root /etc/gshadow
0 root:root /etc/gshadow-
```

### 7.3 Diagnosing "the user does not exist"

**Step 1 — is it an NSS problem or a file problem?**

```
$ getent passwd svc-ci                    # full NSS chain
$ echo $?
2                                          # 2 = key not found

$ getent -s files passwd svc-ci           # files only
$ getent -s sss   passwd svc-ci           # SSSD only
svc-ci:*:1802400513:1802400513:CI Service:/home/svc-ci:/bin/bash
```

If `-s sss` answers and the unqualified query does not, the NSS order or the module is broken.

```
$ cat /etc/nsswitch.conf | grep -E '^(passwd|group|shadow)'
passwd:     files systemd sss
group:      files systemd sss
shadow:     files sss
```

**Step 2 — trace the actual syscalls:**

```
# strace -f -e trace=openat,connect,read -o /tmp/getent.trace getent passwd svc-ci
# grep -E 'nss|sss|passwd' /tmp/getent.trace
openat(AT_FDCWD, "/etc/nsswitch.conf", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libnss_files.so.2", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/etc/passwd", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libnss_sss.so.2", O_RDONLY|O_CLOEXEC) = 3
connect(3, {sa_family=AF_UNIX, sun_path="/var/lib/sss/pipes/nss"}, 110) = -1 ENOENT
```

`ENOENT` on the SSSD socket: the module is configured but the daemon is down. `systemctl status sssd`.

**Step 3 — cache staleness.** Both `nscd` and `sssd` cache negative lookups:

```
# sss_cache -u svc-ci          # invalidate one user
# sss_cache -E                 # invalidate everything
# nscd -i passwd; nscd -i group
# systemctl restart nscd
```

A negative cache entry is the standard explanation for "I created the account and it still says no such user" on a directory-joined host.

### 7.4 Failure catalogue

| Symptom | Probable cause | Diagnosis | Fix |
|---|---|---|---|
| `ls -l` shows bare numbers instead of names | UID/GID has no NSS entry | `ls -ln`; `getent passwd <n>` | Restore the entry, or accept for foreign-namespace files |
| User lost `sudo` after a group change | `usermod -G` without `-a` | `id -nG user`; `getent group sudo` | `usermod -aG sudo user`; audit git history of the converge |
| New group membership "does not apply" | Credentials frozen in running processes | `grep ^Groups /proc/$$/status` vs `id -nG` | Re-login, `loginctl terminate-user`, or `exec newgrp` |
| Locked user still logs in over SSH | `passwd -l` does not affect key auth | `getent shadow u`; `ls -l ~u/.ssh/authorized_keys` | `chage -E 0 u` + truncate `authorized_keys` |
| `Your account has expired` for a working user | `sp_expire` in the past | `chage -l u` | `chage -E -1 u` |
| `useradd: UID 480 is not unique` | UID already allocated | `getent passwd 480` | Choose another, or `--non-unique` (deliberately, rarely) |
| `useradd: cannot lock /etc/passwd; try again later` | Stale `/etc/.pwd.lock` after a kill | `fuser /etc/.pwd.lock`; `ls -l /etc/*.lock` | Kill the holder; if none, remove `/etc/passwd.lock`, `/etc/.pwd.lock` |
| `groupdel: cannot remove the primary group of user 'x'` | Group is someone's `pw_gid` | `awk -F: -v g=$GID '$4==g{print $1}' /etc/passwd` | Reassign with `usermod -g`, then delete |
| Home directory missing after login | `CREATE_HOME no` or no `pam_mkhomedir` | `grep pam_mkhomedir /etc/pam.d/*` | Add `session optional pam_mkhomedir.so skel=/etc/skel umask=0077` |
| Files after deletion owned by nobody | Orphaned inodes | `find / -xdev -nouser -o -nogroup` | Chown to an archive account or delete per retention policy |
| New user can read another's home | `HOME_MODE`/`UMASK` too permissive | `stat -c %a /home/*` | Set `HOME_MODE 0700`; `chmod 700` retroactively |
| `passwd: Authentication token manipulation error` for root | `/etc/shadow` immutable or FS read-only | `lsattr /etc/shadow`; `mount | grep ' / '` | `chattr -i /etc/shadow`; remount rw |
| Password change rejected: "must wait" | `sp_min` not elapsed | `chage -l u` | `chage -m 0 u` (temporarily) |
| Ageing policy not applied to old accounts | `login.defs` affects new accounts only | Sweep below | Batch `chage` |

Batch ageing sweep for pre-existing accounts:

```
# getent passwd \
  | awk -F: -v min="$(awk '/^UID_MIN/{print $2}' /etc/login.defs)" \
            -v max="$(awk '/^UID_MAX/{print $2}' /etc/login.defs)" \
        '$3 >= min && $3 <= max && $7 !~ /(nologin|false)$/ { print $1 }' \
  | while read -r u; do
      chage --mindays 1 --maxdays 90 --warndays 14 "$u"
      printf '%-16s %s\n' "$u" "$(chage -l "$u" | awk -F': *' '/Password expires/{print $2}')"
    done
alice            Nov 25, 2026
carol            Nov 25, 2026
deploy           Nov 25, 2026
```

### 7.5 Standing audit queries

```
# --- UID 0 accounts other than root -------------------------------------
$ getent passwd | awk -F: '$3 == 0 && $1 != "root" { print "UID0: " $0 }'

# --- Accounts with an empty password field ------------------------------
# getent shadow | awk -F: '$2 == "" { print "EMPTY-PASSWD: " $1 }'

# --- Duplicate UIDs ------------------------------------------------------
$ getent passwd | cut -d: -f3 | sort -n | uniq -d

# --- Duplicate login names ----------------------------------------------
$ cut -d: -f1 /etc/passwd | sort | uniq -d

# --- Interactive shells among system accounts (UID < 1000) ---------------
$ getent passwd | awk -F: '$3 < 1000 && $7 !~ /(nologin|false|sync)$/ { print $1 " -> " $7 }'
root -> /bin/bash
sync -> /bin/sync

# --- Passwords older than the policy maximum ----------------------------
# today=$(( $(date -u +%s) / 86400 ))
# getent shadow | awk -F: -v t="$today" \
      '$3 != "" && $5 != "" && $5 != 99999 && (t - $3) > $5 { print $1, "overdue by", (t-$3-$5), "days" }'

# --- Accounts with no expiry that are not system accounts ---------------
# join -t: -1 1 -2 1 \
       <(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1}' | sort) \
       <(getent shadow | awk -F: '$8=="" {print $1}' | sort)

# --- Group membership drift vs the manifest ------------------------------
$ for g in sudo wheel docker platform-eng; do
    printf '%-14s %s\n' "$g" "$(getent group "$g" | cut -d: -f4)"
  done
sudo           alice,ops
wheel
docker         alice,deploy
platform-eng   alice,bob,carol

# --- Who is actually logged in, and from where ---------------------------
$ who -H
NAME     LINE         TIME             COMMENT
alice    pts/0        2026-08-27 09:14 (10.20.4.88)
deploy   pts/1        2026-08-27 09:31 (10.20.0.5)

$ last -F -n 5 alice
alice    pts/0   10.20.4.88   Thu Aug 27 09:14:02 2026   still logged in
alice    pts/2   10.20.4.88   Wed Aug 26 17:02:41 2026 - Wed Aug 26 18:44:12 2026 (01:41)

$ lastb -n 5                    # failed attempts, from /var/log/btmp (root only)
root     ssh:notty  203.0.113.9  Thu Aug 27 04:11:07 2026 - Thu Aug 27 04:11:07 2026 (00:00)

$ lastlog | awk 'NR==1 || $0 !~ /Never logged in/'
Username         Port     From             Latest
root             pts/0    10.20.4.88       Mon Aug 24 08:02:11 +0000 2026
alice            pts/0    10.20.4.88       Thu Aug 27 09:14:02 +0000 2026
```

### 7.6 Group-count limits — an NFS-era landmine

```
$ getconf NGROUPS_MAX
65536
$ id -G alice | wc -w
17
```

The kernel allows 65 536 supplementary groups, but **NFSv3 with `AUTH_SYS` transmits at most 16 GIDs** in the RPC credential. A user in 17 groups will have one silently dropped on every NFS access, producing permission errors that depend on which groups happen to be sent. Mitigations: keep users under 16 groups, enable `rpc.mountd --manage-gids` (the server looks up groups locally instead of trusting the wire), or move to NFSv4 with Kerberos.

---

## 8. Consolidated command matrix

| Task | Command |
|---|---|
| Create regular user with home | `useradd -m -s /bin/bash -c "Name" alice` |
| Create system account | `useradd -r -s /usr/sbin/nologin -d /var/lib/svc -M svc` |
| Show `useradd` defaults | `useradd -D` |
| Change `useradd` defaults | `useradd -D -s /bin/bash -f 30` |
| Set password interactively | `passwd alice` |
| Set password from a pipe | `echo 'alice:S3cr3t' \| chpasswd` |
| Force change at next login | `passwd -e alice` / `chage -d 0 alice` |
| Lock / unlock password | `passwd -l alice` / `passwd -u alice` |
| Delete password (**dangerous**) | `passwd -d alice` |
| Show password status | `passwd -S alice` |
| Expire the account | `chage -E 0 alice` / `usermod -e 1 alice` |
| Un-expire the account | `chage -E -1 alice` |
| Show ageing | `chage -l alice` |
| Set ageing | `chage -m 1 -M 90 -W 14 -I 30 alice` |
| Append supplementary groups | `usermod -aG docker,adm alice` |
| Replace supplementary groups | `usermod -G docker alice` |
| Change primary group | `usermod -g platform alice` |
| Change UID | `usermod -u 4311 alice` |
| Rename login | `usermod -l bob alice` |
| Move home | `usermod -d /srv/alice -m alice` |
| Change shell | `usermod -s /usr/sbin/nologin alice` / `chsh -s ... alice` |
| Change GECOS | `chfn -f "Alice Ng" -r "Room 4" alice` |
| Delete user | `userdel alice` |
| Delete user + home + mail | `userdel -r alice` |
| Create group | `groupadd -g 4200 platform` |
| Rename group | `groupmod -n platform-eng platform` |
| Change GID | `groupmod -g 4201 platform-eng` |
| Delete group | `groupdel platform-eng` |
| Add to group | `gpasswd -a alice platform-eng` |
| Remove from group | `gpasswd -d alice platform-eng` |
| Set group members | `gpasswd -M alice,bob platform-eng` |
| Set group admins | `gpasswd -A alice platform-eng` |
| Show identity | `id alice`, `id -nG alice`, `groups alice` |
| Query NSS | `getent passwd\|group\|shadow\|gshadow\|initgroups <key>` |
| Switch primary group | `newgrp docker` |
| Run one command with a group | `sg docker -c 'docker ps'` |
| Validate databases | `pwck`, `grpck` |
| Edit safely | `vipw`, `vipw -s`, `vigr`, `vigr -s` |
| Shadow conversion | `pwconv`, `pwunconv`, `grpconv`, `grpunconv` |
| Sub-ID ranges | `usermod --add-subuids 200000-265535 alice` |

---

## 9. Exam-focused distinctions worth over-learning

1. **`useradd` vs `adduser`.** `useradd` is the low-level, POSIX-ish, distribution-neutral binary from shadow-utils and is what the exam tests. `adduser` is a Debian Perl wrapper (interactive, reads `/etc/adduser.conf`); on RHEL it is merely a symlink to `useradd`, so the same command behaves completely differently across families. Same for `groupadd`/`addgroup`, `userdel`/`deluser`.
2. **`/etc/passwd` field 2 = `x`** means shadowing is enabled. Empty means passwordless.
3. **`/etc/shadow` field 3 is days since 1970-01-01**, not seconds and not a date string.
4. **A user's primary group is not listed in `/etc/group`'s member field.**
5. **`usermod -aG`** — `-a` only with `-G`, and forgetting it is destructive.
6. **`chage -E` ≠ `passwd -l`.** Account expiry vs password lock; only the former stops key-based SSH.
7. **`userdel` without `-r`** leaves the home directory behind.
8. **`useradd -p`** takes a *hash*, never plaintext.
9. **`gpasswd -d`** is the only single-user group-removal command.
10. **`getent`, not `cat /etc/passwd`**, is how you answer whether an account resolves.

---

## 10. Referencias

**LPI**
- Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- Exam 102-500 objectives (Topic 107 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**shadow-utils (upstream project and manual pages)**
- Project — https://github.com/shadow-maint/shadow
- `useradd(8)` — https://man7.org/linux/man-pages/man8/useradd.8.html
- `usermod(8)` — https://man7.org/linux/man-pages/man8/usermod.8.html
- `userdel(8)` — https://man7.org/linux/man-pages/man8/userdel.8.html
- `groupadd(8)` — https://man7.org/linux/man-pages/man8/groupadd.8.html
- `groupmod(8)` — https://man7.org/linux/man-pages/man8/groupmod.8.html
- `groupdel(8)` — https://man7.org/linux/man-pages/man8/groupdel.8.html
- `passwd(1)` — https://man7.org/linux/man-pages/man1/passwd.1.html
- `gpasswd(1)` — https://man7.org/linux/man-pages/man1/gpasswd.1.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `chpasswd(8)` — https://man7.org/linux/man-pages/man8/chpasswd.8.html
- `newgrp(1)` — https://man7.org/linux/man-pages/man1/newgrp.1.html
- `sg(1)` — https://man7.org/linux/man-pages/man1/sg.1.html
- `pwck(8)` — https://man7.org/linux/man-pages/man8/pwck.8.html
- `grpck(8)` — https://man7.org/linux/man-pages/man8/grpck.8.html
- `vipw(8)` / `vigr(8)` — https://man7.org/linux/man-pages/man8/vipw.8.html
- `pwconv(8)` — https://man7.org/linux/man-pages/man8/pwconv.8.html

**File formats**
- `passwd(5)` — https://man7.org/linux/man-pages/man5/passwd.5.html
- `shadow(5)` — https://man7.org/linux/man-pages/man5/shadow.5.html
- `group(5)` — https://man7.org/linux/man-pages/man5/group.5.html
- `gshadow(5)` — https://man7.org/linux/man-pages/man5/gshadow.5.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `subuid(5)` — https://man7.org/linux/man-pages/man5/subuid.5.html
- `subgid(5)` — https://man7.org/linux/man-pages/man5/subgid.5.html
- `nsswitch.conf(5)` — https://man7.org/linux/man-pages/man5/nsswitch.conf.5.html
- `crypt(5)` (Modular Crypt Format, libxcrypt) — https://man7.org/linux/man-pages/man5/crypt.5.html

**Libraries and lookups**
- `getent(1)` — https://man7.org/linux/man-pages/man1/getent.1.html
- `getpwnam(3)` — https://man7.org/linux/man-pages/man3/getpwnam.3.html
- `getgrouplist(3)` — https://man7.org/linux/man-pages/man3/getgrouplist.3.html
- `setgroups(2)` — https://man7.org/linux/man-pages/man2/setgroups.2.html
- `credentials(7)` — https://man7.org/linux/man-pages/man7/credentials.7.html
- `user_namespaces(7)` — https://man7.org/linux/man-pages/man7/user_namespaces.7.html
- GNU C Library, *Users and Groups* — https://www.gnu.org/software/libc/manual/html_node/Users-and-Groups.html
- libxcrypt (yescrypt, bcrypt, SHA-crypt) — https://github.com/besser82/libxcrypt

**systemd**
- `sysusers.d(5)` — https://www.freedesktop.org/software/systemd/man/latest/sysusers.d.html
- `systemd-sysusers(8)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-sysusers.html
- Users, Groups, UIDs and GIDs on systemd systems — https://systemd.io/UIDS-GIDS/
- `nss-systemd(8)` — https://www.freedesktop.org/software/systemd/man/latest/nss-systemd.html
- `loginctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/loginctl.html

**PAM**
- Linux-PAM System Administrators' Guide — http://www.linux-pam.org/Linux-PAM-html/Linux-PAM_SAG.html
- `pam_unix(8)` — https://man7.org/linux/man-pages/man8/pam_unix.8.html
- `pam_mkhomedir(8)` — https://man7.org/linux/man-pages/man8/pam_mkhomedir.8.html
- `pam_nologin(8)` — https://man7.org/linux/man-pages/man8/pam_nologin.8.html

**Automation and platform**
- Ansible `ansible.builtin.user` — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- Ansible `ansible.builtin.group` — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/group_module.html
- Ansible `ansible.posix.authorized_key` — https://docs.ansible.com/ansible/latest/collections/ansible/posix/authorized_key_module.html
- cloud-init `users_groups` module — https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups
- Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Podman rootless setup (subuid/subgid) — https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- SSSD `sssd.conf(5)` (including `enumerate`) — https://man.sssd.io/latest/man/sssd.conf.5.html

**Standards**
- POSIX.1-2024 (Open Group Base Specifications), *Base Definitions §3, User Database* — https://pubs.opengroup.org/onlinepubs/9799919799/
- Filesystem Hierarchy Standard 3.0 (`/home`, `/etc`, `/var/spool`) — https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html