# 110.2 — Setup host security

**Track:** LPIC-1 (Exams 101-500 / 102-500, syllabus version 5.0) · **Topic 110: Security** · **Objective 110.2**

**What this objective actually asks you to be able to do:** understand how credentials are stored on a Unix host and why they were moved out of `/etc/passwd`; find and switch off every network service the host does not need; and know what TCP wrappers are, how their access-control files are evaluated, and where they still apply.

**Files and utilities in scope:** `/etc/passwd`, `/etc/shadow`, `/etc/nologin`, `/etc/inittab`, `/etc/init.d/*`, `/etc/xinetd.conf`, `/etc/xinetd.d/*`, `systemd.socket` units, `/etc/hosts.allow`, `/etc/hosts.deny`.

---

## 1. Motivation: the host as a unit of blast radius

In a platform team, "host security" is not a checklist you run once at build time. It is the property that determines **how far an incident travels**. Every managed host in a fleet exposes exactly three classes of surface, and this objective covers all three:

| Surface | What an attacker gets | Control in this objective |
|---|---|---|
| **Credentials at rest** | Offline cracking of every password on the box; lateral movement into hosts where the same password is reused | Shadow passwords, hash algorithm and cost, file permissions, aging policy |
| **Listening sockets** | Remote code execution or information disclosure without any credential at all | Service inventory, `systemd` disable/mask, socket activation, `xinetd`/`inetd` legacy, bind-address narrowing |
| **Connection admission** | Reachability from networks that have no business talking to the daemon | TCP wrappers (`hosts.allow`/`hosts.deny`), and their modern replacements: `nftables`, `systemd` `IPAddressAllow=`, application-level ACLs |

### 1.1 Why `/etc/passwd` had to be split

Original Unix stored the password hash in field 2 of `/etc/passwd`. That file is **world-readable by design** — it is the name service database. `ls -l`, `ps`, `finger`, `find -user`, and every library that resolves a UID to a name needs it. So every unprivileged user, every CGI script, every compromised low-privilege daemon could read the hash of `root`.

That was survivable when a DES `crypt(3)` hash took real wall-clock time to test. It stopped being survivable the moment commodity hardware could test billions of candidates per second. The fix was structural, not algorithmic: **separate the public identity record from the secret**.

```
/etc/passwd   0644 root:root   ← identity: name, UID, GID, GECOS, home, shell
/etc/shadow   0640 root:shadow ← secret: hash, salt, aging metadata
```

The second-order consequence is the one that matters operationally: **anything that needs to verify a password now needs privilege**. That is why `passwd`, `su`, `chage`, `chsh`, and `chfn` are SUID or SGID, why `unix_chkpwd` exists as a separate helper for PAM, and why a "read-only" bug in a daemon running as `nobody` no longer hands over the fleet.

### 1.2 The production failure mode this prevents

A concrete incident shape you will see: a web application with a directory-traversal bug serves `../../../../etc/passwd`. On a host that never ran `pwconv`, or where a badly written config-management task reset `/etc/shadow` to `0644`, that single read is a full credential dump. On a correctly configured host it yields a list of usernames and shells — useful for reconnaissance, worthless for authentication.

The lesson is that shadow passwords are not "a legacy detail LPI still asks about". They are the reason a read primitive is not an authentication bypass.

---

## 2. Shadow passwords: mechanics

### 2.1 `/etc/passwd` field layout

```
$ getent passwd deploy
deploy:x:1002:1002:Deployment robot,,,:/srv/deploy:/bin/bash
```

| # | Field | Value above | Notes |
|---|---|---|---|
| 1 | Login name | `deploy` | Must be unique; the UID is what the kernel enforces, not this |
| 2 | Password placeholder | `x` | `x` = "look in `/etc/shadow`". A literal hash here means shadowing is **off**. Empty means **no password required** |
| 3 | UID | `1002` | `0` is root by definition — a second UID-0 account is a backdoor |
| 4 | GID | `1002` | Primary group |
| 5 | GECOS | `Deployment robot,,,` | Comma-separated: full name, room, work phone, home phone |
| 6 | Home directory | `/srv/deploy` | |
| 7 | Login shell | `/bin/bash` | `/usr/sbin/nologin` or `/bin/false` to deny interactive login |

The `x` in field 2 is a sentinel, not a hash. If you see `deploy:$6$...:1002:...` you are on an unshadowed system and the hash is world-readable.

### 2.2 `/etc/shadow` field layout

```
$ sudo getent shadow deploy
deploy:$y$j9T$Qs4mEo1hK3rV8dLpN2Xa7.$k9tPz0YwR6cM1sB4jHnQx2FvD8LgT5aUeI3oWm7yZs2:20330:1:90:14:30:20575:
```

| # | Field | Value | Meaning |
|---|---|---|---|
| 1 | Login name | `deploy` | Join key to `/etc/passwd` |
| 2 | Encrypted password | `$y$j9T$...` | Modular Crypt Format — see §2.3 |
| 3 | Last change | `20330` | Days since 1970-01-01. `0` forces a change at next login |
| 4 | Minimum age | `1` | Days before the password may be changed again — blocks a user cycling back to the old password |
| 5 | Maximum age | `90` | Days until expiry |
| 6 | Warning period | `14` | Days of warning before expiry |
| 7 | Inactivity | `30` | Grace days after expiry before the account is disabled |
| 8 | Expiration date | `20575` | Absolute account expiry, days since epoch. Independent of the password |
| 9 | Reserved | *(empty)* | Unused |

Converting the date fields is a routine diagnostic step:

```
$ date -u -d "1970-01-01 UTC + 20330 days" +%F
2025-08-14
$ date -u -d @$(( 20575 * 86400 )) +%F
2026-04-16
```

### 2.3 The password field is a small language

The field is Modular Crypt Format: `$<id>$<params>$<salt>$<hash>`. But it also carries **states** that are not hashes at all — and confusing them is the single most common operational mistake in this area.

| Field content | State | How it got there |
|---|---|---|
| `$y$j9T$salt$hash` | Usable yescrypt password | `passwd` on Debian 11+/Fedora 35+ |
| `$6$rounds=100000$salt$hash` | Usable sha512crypt password | `passwd` with `ENCRYPT_METHOD SHA512` |
| `$2b$12$salt+hash` | Usable bcrypt password | `libxcrypt` with `ENCRYPT_METHOD BCRYPT` |
| `!$y$j9T$salt$hash` | **Locked**, hash preserved | `passwd -l` / `usermod -L` — reversible with `-u` |
| `!!` | No password ever set, locked | `useradd` default on RHEL |
| `!` | No password ever set, locked | `useradd` default on Debian |
| `*` | Password login impossible, not "locked" | System accounts shipped by packages |
| `*LK*`, `*NP*` | Vendor-specific locked markers | Solaris heritage; seen in migrated images |
| *(empty)* | **Passwordless login** | Misconfiguration or `passwd -d`. Treat as a finding |

Algorithm identifiers you must recognise:

| Prefix | Algorithm | Status |
|---|---|---|
| `$1$` | MD5-crypt | Broken. Do not use |
| `$2a$`/`$2b$`/`$2y$` | bcrypt | Acceptable; 72-byte password truncation |
| `$5$` | sha256crypt | Acceptable; weak GPU resistance |
| `$6$` | sha512crypt | Long-standing default; CPU-hard only |
| `$7$` | scrypt | Memory-hard |
| `$y$` | yescrypt | Current default on Debian/Fedora; memory-hard |
| `$gy$` | gost-yescrypt | Russian GOST variant |
| *(13 chars, no `$`)* | Traditional DES `crypt` | Broken, 8-char limit. A red flag in any audit |

**Why memory-hardness matters at fleet scale:** sha512crypt is CPU-hard but cheap in memory, so a GPU with thousands of cores parallelises it almost perfectly. yescrypt and scrypt force each guess to allocate a working set, which collapses GPU throughput. On the same hardware, moving from `$6$` to `$y$` typically costs a few extra milliseconds per legitimate login and reduces offline cracking rate by two to three orders of magnitude.

### 2.4 Policy lives in `/etc/login.defs`

`/etc/login.defs` is read by the shadow-utils tools (`useradd`, `passwd`, `chage`, `login`). It sets **defaults for new accounts**; it does not retroactively change existing ones.

```ini
# /etc/login.defs — hardened excerpt

# --- Password hashing -------------------------------------------------
ENCRYPT_METHOD          YESCRYPT
YESCRYPT_COST_FACTOR    7
# Fallback when the platform's libcrypt lacks yescrypt:
#ENCRYPT_METHOD         SHA512
#SHA_CRYPT_MIN_ROUNDS   100000
#SHA_CRYPT_MAX_ROUNDS   200000

# --- Aging defaults for NEW accounts ----------------------------------
PASS_MAX_DAYS   90
PASS_MIN_DAYS   1
PASS_WARN_AGE   14

# --- UID/GID allocation ranges ----------------------------------------
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
GID_MIN                  1000
GID_MAX                 60000

# --- Home directory and umask -----------------------------------------
UMASK                    077
HOME_MODE                0700
CREATE_HOME              yes

# --- Login hardening ---------------------------------------------------
FAILLOG_ENAB            yes
LOG_UNKFAIL_ENAB        no
LOGIN_RETRIES             3
LOGIN_TIMEOUT            60
DEFAULT_HOME             no
USERGROUPS_ENAB         yes
```

Two subtleties that bite in production:

- `LOG_UNKFAIL_ENAB yes` writes the *typed username* to the log on failure. Users who mistype and enter their password at the login prompt then have their password in `journalctl`. Keep it `no`.
- `DEFAULT_HOME no` refuses login when the home directory is missing rather than silently dropping the user into `/`. On an NFS-home fleet this converts a silent, confusing state into a clear failure.

**Applying the new hash algorithm is not automatic.** Changing `ENCRYPT_METHOD` affects only passwords set *after* the change. Existing `$6$` hashes stay `$6$` until each user runs `passwd`. Force the rotation:

```
$ sudo awk -F: '$2 ~ /^\$6\$/ {print $1}' /etc/shadow
alice
bob
deploy
$ sudo chage -d 0 alice
$ sudo chage -l alice | head -3
Last password change                                    : password must be changed
Password expires                                        : password must be changed
Password inactive                                       : password must be changed
```

### 2.5 Consistency and conversion tools

| Command | Purpose | Notes |
|---|---|---|
| `pwconv` | Move hashes from `/etc/passwd` → `/etc/shadow` | Idempotent; adds missing shadow entries |
| `pwunconv` | Reverse — merge hashes back into `/etc/passwd` | Destroys aging metadata. Diagnostic use only |
| `grpconv` / `grpunconv` | Same pair for `/etc/group` ↔ `/etc/gshadow` | |
| `pwck` | Verify `passwd`/`shadow` integrity | `-r` = read-only, correct for cron and CI |
| `grpck` | Verify `group`/`gshadow` integrity | `-r` likewise |
| `vipw` / `vigr` | Edit under a lock | `-s` edits the shadow file. **Always** use these instead of a bare editor |

`vipw` and `vigr` exist because `passwd`, `useradd` and PAM take `/etc/.pwd.lock`. Editing `/etc/shadow` directly with `vim` while a `useradd` runs is how you get a truncated shadow file and a host nobody can log into.

```
$ sudo pwck -r
user 'ftp': directory '/srv/ftp' does not exist
user 'lp': directory '/var/spool/lpd' does not exist
pwck: no changes
$ echo $?
2
```

Exit code 2 means "one or more bad entries". In CI, treat non-zero as a build failure only after whitelisting the vendor system accounts your base image ships with — otherwise the check is noise and gets disabled, which is worse.

### 2.6 Verifying that shadowing is actually in effect

```
$ sudo awk -F: 'length($2) > 1 {print "UNSHADOWED: " $1}' /etc/passwd
$ stat -c '%n %a %U:%G' /etc/passwd /etc/shadow /etc/group /etc/gshadow
/etc/passwd 644 root:root
/etc/shadow 640 root:shadow
/etc/group 644 root:root
/etc/gshadow 640 root:shadow
```

Expected permissions differ by distribution and both are correct:

| File | Debian/Ubuntu | RHEL/Fedora/SUSE |
|---|---|---|
| `/etc/passwd` | `0644 root:root` | `0644 root:root` |
| `/etc/shadow` | `0640 root:shadow` | `0000 root:root` |
| `/etc/group` | `0644 root:root` | `0644 root:root` |
| `/etc/gshadow` | `0640 root:shadow` | `0000 root:root` |

RHEL's `0000` works because root bypasses permission checks; the SGID `unix_chkpwd` helper is what lets PAM verify a password without opening the file as the calling user. Debian's `0640 root:shadow` grants the same via group membership. **Anything more permissive than these is a finding.** A `/etc/shadow` at `0644` is a full credential disclosure to any local process.

### 2.7 Where the password check actually happens

Reading `/etc/shadow` is only the last hop. The resolution path is:

```
login / sshd / su
      │
      ├─ NSS  ──> /etc/nsswitch.conf  ──> files | sss | ldap | systemd
      │            (identity: UID, GID, home, shell)
      │
      └─ PAM  ──> /etc/pam.d/<service>
                   auth     pam_unix.so    ──> unix_chkpwd ──> /etc/shadow
                   account  pam_unix.so    ──> aging fields 3–8
                   account  pam_nologin.so ──> /etc/nologin
                   account  pam_access.so  ──> /etc/security/access.conf
```

This split explains a class of confusing incidents: `getent passwd alice` succeeds (NSS found the identity) while login fails (PAM rejected the credential or the account state). Always test both halves.

```
$ getent passwd alice && echo "identity OK"
alice:x:1001:1001:Alice,,,:/home/alice:/bin/bash
identity OK
$ sudo chage -l alice
Last password change                                    : Aug 14, 2025
Password expires                                        : Nov 12, 2025
Password inactive                                       : Dec 12, 2025
Account expires                                         : never
Minimum number of days between password change          : 1
Maximum number of days between password change          : 90
Number of days of warning before password expires       : 14
```

With today at 2026-08-31, that password expired and passed its inactivity window: the account is disabled by aging even though nothing is "locked".

```
$ sudo passwd -S alice
alice P 08/14/2025 1 90 14 30
```

The second field is the state: `P` = usable password, `L` = locked, `NP` = no password.

### 2.8 Locking is not one thing

| Goal | Command | Effect | Does it stop SSH keys? |
|---|---|---|---|
| Block password auth, keep hash | `passwd -l user` / `usermod -L user` | Prefix `!` on the hash | **No** |
| Restore | `passwd -u user` / `usermod -U user` | Strip `!` | — |
| Delete the password entirely | `passwd -d user` | Empty field — **passwordless login** | No |
| Block interactive shell | `usermod -s /usr/sbin/nologin user` | Shell refuses | Stops shells; **not** `ssh user@host command` or port forwarding |
| Disable the account wholesale | `chage -E 0 user` | Field 8 = 0 → expired since epoch; PAM `account` fails | **Yes** |
| Set an end date | `chage -E 2026-12-31 user` | Absolute expiry | Yes, after that date |

**The trap:** `passwd -l` alone does not stop key-based SSH. A contractor whose password you locked can still log in with their authorized key. The complete offboarding sequence is:

```
$ sudo usermod -L contractor
$ sudo chage -E 0 contractor
$ sudo usermod -s /usr/sbin/nologin contractor
$ sudo install -m 0000 /dev/null /home/contractor/.ssh/authorized_keys
$ sudo pkill -KILL -u contractor
$ sudo loginctl terminate-user contractor 2>/dev/null || true
```

The `pkill`/`loginctl` step matters: locking an account does nothing to sessions already open.

---

## 3. Turning off network services

### 3.1 Build the inventory first

You cannot disable what you have not enumerated. The canonical modern tool is `ss`:

```
$ sudo ss -tulpnH
udp   UNCONN 0  0     127.0.0.53%lo:53     0.0.0.0:*  users:(("systemd-resolve",pid=612,fd=14))
udp   UNCONN 0  0           0.0.0.0:68     0.0.0.0:*  users:(("dhclient",pid=901,fd=6))
tcp   LISTEN 0  4096  127.0.0.53%lo:53     0.0.0.0:*  users:(("systemd-resolve",pid=612,fd=15))
tcp   LISTEN 0  128         0.0.0.0:22     0.0.0.0:*  users:(("sshd",pid=1043,fd=3))
tcp   LISTEN 0  128            [::]:22        [::]:*  users:(("sshd",pid=1043,fd=4))
tcp   LISTEN 0  511         0.0.0.0:80      0.0.0.0:* users:(("nginx",pid=1188,fd=6),("nginx",pid=1187,fd=6))
tcp   LISTEN 0  70       127.0.0.1:33060    0.0.0.0:* users:(("mysqld",pid=1402,fd=21))
tcp   LISTEN 0  151      127.0.0.1:3306     0.0.0.0:* users:(("mysqld",pid=1402,fd=23))
tcp   LISTEN 0  4096        0.0.0.0:111     0.0.0.0:* users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))
tcp   LISTEN 0  4096           [::]:111       [::]:*  users:(("rpcbind",pid=598,fd=6),("systemd",pid=1,fd=40))
tcp   LISTEN 0  100      127.0.0.1:25       0.0.0.0:* users:(("exim4",pid=1290,fd=3))
```

Flags: `-t` TCP, `-u` UDP, `-l` listening, `-p` process, `-n` numeric, `-H` no header.

Read this like an auditor:

- `127.0.0.53%lo:53`, `127.0.0.1:3306`, `127.0.0.1:25` — loopback only, **not remotely reachable**. Not attack surface from the network.
- `0.0.0.0:22`, `[::]:22` — intended.
- `0.0.0.0:80` — intended for a web node.
- `0.0.0.0:111` (`rpcbind`) — **almost never intended.** It is a UDP/TCP amplification vector and an NFS prerequisite this host does not need.

Note that `rpcbind`'s socket is held by **both** `rpcbind` and `systemd` (pid 1). That is the signature of **socket activation**: `systemd` owns the listening file descriptor and hands it over. Stopping `rpcbind.service` will not close the port — `systemd` re-opens it and restarts the daemon on the next connection. You must disable `rpcbind.socket`.

Complementary tools:

```
$ sudo lsof -nP -iTCP -sTCP:LISTEN
COMMAND   PID  USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
systemd     1  root  38u  IPv4  18921      0t0  TCP *:111 (LISTEN)
rpcbind   598   _rpc  4u  IPv4  18921      0t0  TCP *:111 (LISTEN)
sshd     1043  root   3u  IPv4  21044      0t0  TCP *:22 (LISTEN)
nginx    1187  root   6u  IPv4  22310      0t0  TCP *:80 (LISTEN)

$ sudo netstat -tulpn        # deprecated; net-tools. Same data, older format
$ systemctl list-sockets --all
LISTEN                          UNIT                        ACTIVATES
/run/dbus/system_bus_socket     dbus.socket                 dbus.service
/run/systemd/journal/stdout     systemd-journald.socket     systemd-journald.service
0.0.0.0:111                     rpcbind.socket              rpcbind.service
[::]:111                        rpcbind.socket              rpcbind.service
```

### 3.2 Socket → process → unit → package

The full attribution chain, which is what you need before you dare disable anything:

```
$ sudo ss -tlpn 'sport = :111'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:111       0.0.0.0:*     users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))

$ systemctl status rpcbind.socket --no-pager
● rpcbind.socket - RPCbind Server Activation Socket
     Loaded: loaded (/lib/systemd/system/rpcbind.socket; enabled; preset: enabled)
     Active: active (running) since Mon 2026-08-31 08:12:04 UTC; 3h 21min ago
   Triggers: ● rpcbind.service
     Listen: /run/rpcbind.sock (Stream)
             0.0.0.0:111 (Stream)
             [::]:111 (Stream)

$ dpkg -S /lib/systemd/system/rpcbind.socket
rpcbind: /lib/systemd/system/rpcbind.socket

$ apt-cache rdepends --installed rpcbind
rpcbind
Reverse Depends:
  nfs-common
```

Now you know: nothing but `nfs-common` wants it, and this host does not mount NFS. It is safe to remove.

### 3.3 Stop vs disable vs mask — the three-state model

This is the highest-value distinction in the whole objective.

| Action | Command | Runs now? | Survives reboot? | Can another unit pull it in? | Use when |
|---|---|---|---|---|---|
| **Stop** | `systemctl stop foo.service` | No | **Yes — it comes back** | Yes | Temporary, during maintenance |
| **Disable** | `systemctl disable foo.service` | Yes, still running | No autostart | **Yes** — a `Wants=`/`Requires=` from another unit still starts it | Normal "turn this off" |
| **Disable + stop** | `systemctl disable --now foo.service` | No | No autostart | Yes | The usual correct action |
| **Mask** | `systemctl mask foo.service` | Only if already up | Cannot start at all | **No** — symlinked to `/dev/null` | Must never run, even as a dependency |
| **Mask + stop** | `systemctl mask --now foo.service` | No | Cannot start at all | No | Hard guarantee |
| **Remove** | `apt purge` / `dnf remove` | No | Gone | No | Best of all — code not on disk cannot be exploited |

The failure everyone hits once:

```
$ sudo systemctl disable --now rpcbind.service
Removed "/etc/systemd/system/multi-user.target.wants/rpcbind.service".
$ sudo ss -tlpn 'sport = :111'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:111       0.0.0.0:*     users:(("systemd",pid=1,fd=38))
```

The port is still open. `systemd` holds the socket and will spawn `rpcbind` on the first connection. The service was disabled; the **socket** was not.

```
$ sudo systemctl disable --now rpcbind.socket rpcbind.service
Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".
$ sudo ss -tlpn 'sport = :111'
$ echo "port 111 closed: $?"
port 111 closed: 1
```

For a socket-activated service, **always operate on the `.socket` unit and the `.service` unit together.**

Verifying a mask:

```
$ sudo systemctl mask --now rpcbind.socket rpcbind.service
Created symlink /etc/systemd/system/rpcbind.socket → /dev/null.
Created symlink /etc/systemd/system/rpcbind.service → /dev/null.
$ sudo systemctl start rpcbind.service
Failed to start rpcbind.service: Unit rpcbind.service is masked.
$ systemctl list-unit-files --state=masked
UNIT FILE        STATE  PRESET
rpcbind.service  masked enabled
rpcbind.socket   masked enabled
2 unit files listed.
```

Enumerating everything enabled, which is your real change surface:

```
$ systemctl list-unit-files --type=service --state=enabled --no-pager
UNIT FILE                   STATE   PRESET
cron.service                enabled enabled
dbus.service                static  -
nginx.service               enabled enabled
ssh.service                 enabled enabled
systemd-journald.service    static  -
systemd-timesyncd.service   enabled enabled
unattended-upgrades.service enabled enabled
```

### 3.4 Narrow the bind address instead of removing

Frequently the service is needed but must not be reachable from the network. Binding to loopback is stronger than any firewall rule, because it is enforced by the kernel's socket layer and cannot be bypassed by a firewall flush.

| Service | Directive | Value |
|---|---|---|
| OpenSSH | `ListenAddress` | `10.20.0.15` (management interface only) |
| MySQL/MariaDB | `bind-address` | `127.0.0.1` |
| PostgreSQL | `listen_addresses` | `'localhost'` |
| Redis | `bind` | `127.0.0.1 -::1` |
| nginx | `listen` | `127.0.0.1:8080` |
| Exim/Postfix | `dc_local_interfaces` / `inet_interfaces` | `127.0.0.1 ; ::1` / `loopback-only` |

`systemd` can enforce this from the outside, independent of the daemon's own configuration:

```ini
# /etc/systemd/system/redis-server.service.d/10-network-lockdown.conf
[Service]
IPAddressDeny=any
IPAddressAllow=localhost
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
PrivateNetwork=no
```

```
$ sudo systemctl daemon-reload && sudo systemctl restart redis-server
$ systemd-analyze security redis-server.service | tail -5
→ Overall exposure level for redis-server.service: 3.4 OK 🙂
```

`IPAddressDeny=` is implemented with eBPF cgroup socket filters. It applies to the process regardless of what its config file says — useful when the daemon is configured by a package you do not control.

### 3.5 The legacy layers you still must recognise

#### SysV init and `/etc/inittab`

On a pure `sysvinit` system, `/etc/inittab` sets the default runlevel and the per-runlevel actions:

```
# /etc/inittab (sysvinit)
id:3:initdefault:

si::sysinit:/etc/init.d/rcS

l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6

ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now

1:2345:respawn:/sbin/getty 38400 tty1
2:23:respawn:/sbin/getty 38400 tty2
```

Line format: `id:runlevels:action:process`. Setting `id:3:initdefault:` boots to multi-user text mode; `id:5:` boots to graphical. A classic hardening step was removing the `ctrlaltdel` line so a console keystroke could not reboot a server.

Enabling and disabling per-runlevel start scripts:

```
$ sudo update-rc.d rsync defaults        # Debian: create symlinks
$ sudo update-rc.d rsync disable         # Debian: switch S→K links
$ sudo chkconfig --list sshd             # RHEL 6
sshd  0:off  1:off  2:on  3:on  4:on  5:on  6:off
$ sudo chkconfig sshd off                # RHEL 6
$ ls /etc/rc3.d/
K01rsync  S01cron  S01ssh  S02nginx
```

`S` = start, `K` = kill, the number is ordering. `/etc/init.d/<name> {start|stop|status|restart}` is the direct interface.

Under `systemd` all of this is a compatibility shim: `systemd-sysv-generator` synthesises a unit from each `/etc/init.d/` script, and runlevels are aliases for targets.

| Runlevel | systemd target | Meaning |
|---|---|---|
| 0 | `poweroff.target` | Halt |
| 1 / S | `rescue.target` | Single-user |
| 2, 3, 4 | `multi-user.target` | Multi-user, no GUI |
| 5 | `graphical.target` | Multi-user + GUI |
| 6 | `reboot.target` | Reboot |

```
$ systemctl get-default
multi-user.target
$ sudo systemctl set-default multi-user.target
Removed "/etc/systemd/system/default.target".
Created symlink /etc/systemd/system/default.target → /lib/systemd/system/multi-user.target.
$ runlevel
N 5
```

#### `inetd` / `xinetd`

The super-server model: one daemon listens on many ports and forks the real service on demand. This saved memory in 1990 and is the direct ancestor of `systemd` socket activation.

`inetd`'s `/etc/inetd.conf`, one line per service:

```
# service  socket  proto  wait/nowait  user   server           args
ftp        stream  tcp    nowait       root   /usr/sbin/tcpd   in.ftpd -l -a
telnet     stream  tcp    nowait       root   /usr/sbin/tcpd   in.telnetd
```

Note `/usr/sbin/tcpd` in the server column — that is TCP wrappers being inserted as a shim (§4). Disabling a service means commenting the line and reloading `inetd`.

`xinetd` replaced it with a structured configuration:

```
# /etc/xinetd.conf
defaults
{
        instances               = 60
        log_type                = SYSLOG authpriv
        log_on_success          = HOST PID DURATION
        log_on_failure          = HOST ATTEMPT
        cps                     = 25 30
        per_source              = 10
        v6only                  = no
        groups                  = yes
        umask                   = 022
}

includedir /etc/xinetd.d
```

A complete, production-shaped service definition:

```
# /etc/xinetd.d/rsync
service rsync
{
        disable         = no
        flags           = IPv6
        socket_type     = stream
        wait            = no
        user            = root
        server          = /usr/bin/rsync
        server_args     = --daemon --config=/etc/rsyncd.conf
        log_on_failure  += USERID
        log_on_success  += USERID EXIT

        # --- access control -------------------------------------------
        only_from       = 10.20.0.0/24 192.0.2.7
        no_access       = 10.20.0.99
        access_times    = 06:00-22:00

        # --- resource limits ------------------------------------------
        instances       = 20
        per_source      = 4
        cps             = 10 30
        rlimit_as       = 256M
        rlimit_cpu      = 30

        # --- binding ---------------------------------------------------
        bind            = 10.20.0.15
        nice            = 10
}
```

| Attribute | Meaning |
|---|---|
| `disable` | `yes` switches the service off. **This is the exam answer** for turning off an `xinetd` service |
| `socket_type` | `stream` (TCP), `dgram` (UDP), `raw` |
| `wait` | `no` = multi-threaded, `xinetd` keeps listening (typical for `stream`); `yes` = single-threaded, the server takes over the socket (typical for `dgram`) |
| `user` / `group` | Identity the server runs as |
| `server` / `server_args` | Binary and its arguments |
| `only_from` | Allow list — IPs, CIDR, hostnames, `0.0.0.0/0` |
| `no_access` | Deny list. **More specific match wins** between the two, not first-match |
| `access_times` | Time-of-day window |
| `instances` | Global concurrency cap |
| `per_source` | Concurrency cap per client IP |
| `cps` | Rate limit: `<connections-per-second> <seconds-to-sleep-when-exceeded>` |
| `bind` / `interface` | Bind to one address instead of all |
| `redirect` | Proxy to another host:port |
| `flags` | `REUSE`, `IPv4`, `IPv6`, `NAMEINARGS` (required when `server = /usr/sbin/tcpd`) |

```
$ sudo sed -i 's/^\(\s*disable\s*=\s*\).*/\1yes/' /etc/xinetd.d/rsync
$ sudo systemctl reload xinetd
$ sudo grep -H disable /etc/xinetd.d/*
/etc/xinetd.d/chargen:  disable = yes
/etc/xinetd.d/daytime:  disable = yes
/etc/xinetd.d/echo:     disable = yes
/etc/xinetd.d/rsync:    disable = yes
```

On RHEL-family systems, `chkconfig` edits the `disable` line for you:

```
$ sudo chkconfig rsync off
$ sudo chkconfig --list | sed -n '/xinetd based/,$p'
xinetd based services:
        chargen-dgram:  off
        chargen-stream: off
        rsync:          off
```

**Status:** `xinetd` is legacy. It remains packaged in Debian; on RHEL 8 and later it is not in the base repositories. Do not deploy new services on it — but you must be able to read and disable it on inherited hosts, and LPI tests it.

#### `systemd` socket activation — the modern equivalent

Two modes, and the difference is the single most useful thing to understand here.

**`Accept=no`** (the default, and the right choice): `systemd` opens the listening socket, starts the service **once**, and passes the listening file descriptor. The daemon does its own `accept()` loop. Environment: `LISTEN_FDS`, `LISTEN_PID`, `LISTEN_FDNAMES`; first fd is number 3.

**`Accept=yes`** (inetd compatibility): `systemd` does the `accept()` itself and starts **one instance of a templated unit per connection**, with the connected socket on stdin/stdout. Simple, and expensive under load.

Complete, deployable pair — a per-connection service with a hard network allow-list:

```ini
# /etc/systemd/system/metrics-collector.socket
[Unit]
Description=Metrics collector socket (per-connection)
Documentation=man:systemd.socket(5)
PartOf=metrics-collector.service

[Socket]
ListenStream=10.20.0.15:9110
Accept=yes
MaxConnections=64
MaxConnectionsPerSource=4
Backlog=128
NoDelay=yes
KeepAlive=yes
SocketUser=root
SocketGroup=root
SocketMode=0660
IPAddressDeny=any
IPAddressAllow=10.20.0.0/24
IPAddressAllow=localhost

[Install]
WantedBy=sockets.target
```

```ini
# /etc/systemd/system/metrics-collector@.service
[Unit]
Description=Metrics collector connection %i
Documentation=man:systemd.exec(5)
Requires=metrics-collector.socket
After=metrics-collector.socket

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/metrics-collector
StandardInput=socket
StandardOutput=socket
StandardError=journal

User=metrics
Group=metrics
DynamicUser=no

# --- sandboxing -------------------------------------------------------
NoNewPrivileges=yes
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077

# --- resource limits --------------------------------------------------
LimitNOFILE=256
LimitNPROC=32
MemoryMax=128M
TasksMax=16
TimeoutStartSec=30s
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now metrics-collector.socket
Created symlink /etc/systemd/system/sockets.target.wants/metrics-collector.socket → /etc/systemd/system/metrics-collector.socket.
$ systemctl list-sockets --no-pager | grep metrics
10.20.0.15:9110   metrics-collector.socket   metrics-collector@.service

$ systemd-analyze security metrics-collector@.service | tail -3
→ Overall exposure level for metrics-collector@.service: 1.2 OK 🙂
```

Testing the allow-list from a denied source:

```
$ ssh jump-box 'timeout 3 nc -vz 10.20.0.15 9110'    # 10.30.0.4 — outside the allow-list
nc: connect to 10.20.0.15 port 9110 (tcp) failed: Connection timed out
$ sudo journalctl -u metrics-collector.socket -n 5 --no-pager
Aug 31 11:42:03 web01 systemd[1]: metrics-collector.socket: Refused new connection from 10.30.0.4:51422 (IP address deny list).
```

You can prototype socket activation without writing units at all:

```
$ sudo systemd-socket-activate -l 9110 --inetd /usr/local/libexec/metrics-collector
Listening on [::]:9110 as 3.
Communication attempt on fd 3.
Spawned /usr/local/libexec/metrics-collector (metrics-collector) as PID 20431.
```

### 3.6 Comparative table: the four generations

| | `inetd` | `xinetd` | SysV `/etc/init.d` | `systemd` socket units |
|---|---|---|---|---|
| Config | `/etc/inetd.conf`, one line | `/etc/xinetd.d/<svc>` blocks | Shell scripts + `rcN.d` symlinks | `.socket` + `.service` INI |
| Model | One process per connection | One process per connection | One long-lived daemon | Either mode (`Accept=`) |
| Disable | Comment the line, reload | `disable = yes`, reload | `update-rc.d`/`chkconfig` off | `systemctl disable --now` |
| Cannot-run guarantee | Remove the line | Remove the file | Remove the script | `systemctl mask` |
| Access control | via `tcpd` wrapper | `only_from`, `no_access`, `access_times` | None (daemon's own) | `IPAddressAllow/Deny` (eBPF) |
| Rate limiting | None | `cps`, `per_source`, `instances` | None | `MaxConnections`, `MaxConnectionsPerSource`, `StartLimitBurst` |
| Sandboxing | None | `rlimit_*`, `nice`, `umask` | None | Full namespace/seccomp/capability set |
| Parallel boot | N/A | N/A | Sequential, ordered by number | Parallel; sockets open before daemons start |
| Logging | syslog | syslog, `log_on_success/failure` | Whatever the script does | `journald`, structured, per-unit |
| Status | Obsolete | Legacy; not in RHEL 8+ base | Compatibility shim only | Current |

**Why socket activation also solves a dependency problem:** because `systemd` opens all listening sockets *before* starting any daemon, service A can connect to service B's socket while B is still initialising — the connection simply queues in the backlog. This removes most boot-ordering constraints and is why `systemd` boots in parallel where SysV could not.

### 3.7 A defensible disable procedure

Never disable in bulk on a live host. The order that keeps you employed:

```
# 1. Snapshot the current state so you can prove and revert what changed
$ sudo ss -tulpnH | sort > /root/sockets-before.txt
$ systemctl list-unit-files --state=enabled > /root/units-before.txt

# 2. Attribute the socket to a package before touching it
$ dpkg -S "$(readlink -f /lib/systemd/system/rpcbind.socket)"
rpcbind: /lib/systemd/system/rpcbind.socket

# 3. Check what would break
$ apt-cache rdepends --installed rpcbind
rpcbind
Reverse Depends:
  nfs-common

# 4. Stop first, observe, then make it permanent
$ sudo systemctl stop rpcbind.socket rpcbind.service
$ sleep 300 && sudo journalctl -p warning --since "5 min ago" --no-pager | head

# 5. Make it permanent and unstartable
$ sudo systemctl mask --now rpcbind.socket rpcbind.service

# 6. Prove the delta
$ sudo ss -tulpnH | sort > /root/sockets-after.txt
$ diff /root/sockets-before.txt /root/sockets-after.txt
2,3d1
< tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=598,fd=4),("systemd",pid=1,fd=38))
< tcp LISTEN 0 4096    [::]:111    [::]:* users:(("rpcbind",pid=598,fd=6),("systemd",pid=1,fd=40))
```

Step 4 — stop, wait, read the log — is what separates a change from an outage. Masking immediately hides the symptom of a dependency you did not know about.

---

## 4. TCP wrappers

### 4.1 What they actually are

TCP wrappers are **not a firewall**. There is no kernel component. They are a userspace library, `libwrap`, whose `hosts_access(3)` function consults `/etc/hosts.allow` and `/etc/hosts.deny` and returns allow or deny. The daemon calls it **after** `accept()` — the TCP handshake has already completed and the client has already reached the process.

Two integration paths:

1. **`tcpd` shim** — `inetd`/`xinetd` execs `/usr/sbin/tcpd` instead of the real server. `tcpd` checks the rules, logs, then `exec`s the real binary.
2. **Linked directly** — the daemon links `libwrap` and calls `hosts_access()` itself.

The **first question** in any TCP wrappers investigation is which of these applies, or whether either does:

```
$ ldd /usr/sbin/vsftpd | grep -i wrap
        libwrap.so.0 => /lib/x86_64-linux-gnu/libwrap.so.0 (0x00007f2c9a1e4000)

$ ldd /usr/sbin/sshd | grep -i wrap
$ echo "exit=$?  → sshd is NOT wrapped"
exit=1  → sshd is NOT wrapped
```

That second result is not a broken system. **OpenSSH removed `libwrap` support in release 6.7 (October 2014).** Writing `sshd: ALL` in `/etc/hosts.deny` on any modern distribution does exactly nothing, and people lock themselves out — or, far worse, believe they are protected when they are not.

### 4.2 Evaluation order

The algorithm is short and has no negation and no explicit precedence beyond order:

```
1. Read /etc/hosts.allow top to bottom.
   First matching rule  →  ACCESS GRANTED. Stop.
2. Read /etc/hosts.deny top to bottom.
   First matching rule  →  ACCESS DENIED. Stop.
3. No match in either file  →  ACCESS GRANTED.
```

Consequences to internalise:

- **`hosts.allow` always wins.** A permissive line there cannot be overridden by `hosts.deny`.
- **The default is permit.** An empty `hosts.deny` means everything is allowed. The classic default-deny posture is `ALL: ALL` in `hosts.deny`, then explicit exceptions in `hosts.allow`.
- **Both files missing = everything allowed.** No error, no warning.

### 4.3 Rule syntax

```
daemon_list : client_list [ : option : option ... ]
```

`daemon_list` matches the **process name as `argv[0]` basename** — `sshd`, `vsftpd`, `in.telnetd`, `rpcbind` — not the port number and not the service name in `/etc/services`.

| Wildcard | Matches |
|---|---|
| `ALL` | Everything, in either field |
| `LOCAL` | Any hostname without a dot (same domain) |
| `UNKNOWN` | Client whose name or address cannot be determined |
| `KNOWN` | Client whose name **and** address are known |
| `PARANOID` | Forward and reverse DNS disagree. Matched *before* rule processing |
| `EXCEPT` | Set subtraction: `list1 EXCEPT list2` |

Client patterns:

| Pattern | Matches |
|---|---|
| `192.0.2.7` | One IPv4 address |
| `192.0.2.` | Trailing dot — prefix match on `192.0.2.0/24` |
| `192.0.2.0/255.255.255.0` | Address/netmask |
| `192.0.2.0/24` | CIDR (newer `libwrap`) |
| `.example.com` | Leading dot — domain suffix match |
| `[2001:db8::1]` | One IPv6 address — brackets are mandatory |
| `[2001:db8::]/64` | IPv6 prefix |
| `@engineering` | NIS netgroup |
| `/etc/wrappers/admins.list` | Absolute path — read patterns from a file |

Complete, deployable pair:

```
# /etc/hosts.deny — default-deny posture.
# Evaluated ONLY if no rule in /etc/hosts.allow matched first.
#
# WARNING: this file is consulted only by daemons that link libwrap.
# Verify with: ldd $(command -v <daemon>) | grep libwrap
# OpenSSH >= 6.7 does NOT link libwrap. See /etc/nftables.conf instead.

ALL: ALL : severity auth.warning

# Log every refusal with the client address, then deny.
# The spawn command must not block: tcpd waits for it.
ALL: ALL : spawn (/usr/bin/logger -p auth.warning -t tcpwrap \
        "DENY %d from %h (%a) user=%u client-info=%c") & : deny
```

```
# /etc/hosts.allow — explicit exceptions. First match wins, then STOP.
#
# Format:  daemon_list : client_list [ : option : option ... ]

# --- Always allow the host to talk to itself ---------------------------
ALL: 127.0.0.1 [::1] LOCAL

# --- Management network: everything except the guest VLAN ---------------
ALL: 10.20.0.0/255.255.255.0 EXCEPT 10.20.0.99

# --- FTP: office network and one partner address ------------------------
vsftpd: 10.20.0.0/24 192.0.2.7 [2001:db8:10::]/64 : \
        severity auth.info

# --- Portmapper: NFS clients only. rpcbind resolves no hostnames, so
#     these MUST be numeric addresses.
rpcbind: 10.20.0.10 10.20.0.11 10.20.0.12

# --- Time-limited contractor access, patterns kept in a separate file ---
vsftpd: /etc/wrappers/contractors.list

# --- Reject anything whose forward and reverse DNS disagree -------------
ALL: PARANOID : deny
```

### 4.4 Options: `hosts_options(5)`

The extended syntax (compiled with `PROCESS_OPTIONS`, standard on Linux) adds a third field:

| Option | Effect |
|---|---|
| `allow` / `deny` | Explicit verdict — lets you write both decisions in one file |
| `spawn <shell cmd>` | Run a command as root, in the background. Access proceeds |
| `twist <shell cmd>` | **Replace** the service with this command. Used for banners and tarpits |
| `severity <facility.level>` | Syslog facility/priority for this match |
| `banners <dir>` | Send `<dir>/<daemon>` to the client before the service starts |
| `nice <n>` | Renice the spawned server |
| `umask <mask>` | Set umask for the server |
| `setenv <name> <value>` | Inject an environment variable |
| `rfc931 [timeout]` | Query the client's `identd`. **Adds latency; avoid** |
| `keepalive` | Enable TCP keepalives |
| `linger <sec>` | `SO_LINGER` timeout |

Expansion characters usable inside `spawn`/`twist`/`banners`:

| Code | Expands to |
|---|---|
| `%a` / `%A` | Client / server address |
| `%c` | Client info: `user@host`, `user@address`, hostname, or address |
| `%d` | Daemon process name (`argv[0]`) |
| `%h` / `%H` | Client / server hostname or address |
| `%n` / `%N` | Client / server hostname, or `unknown` / `paranoid` |
| `%p` | Daemon PID |
| `%s` | Server info: `daemon@host`, `daemon@address`, or `daemon` |
| `%u` | Client username, or `unknown` |
| `%%` | A literal `%` |

A tarpit for scanners — `twist` replaces the service entirely:

```
# /etc/hosts.allow
in.telnetd: ALL : twist /bin/echo "554 Access from %a is logged and denied."
```

**Security note on `spawn`:** the command runs **as root** with client-controlled data (`%h`, `%u`) in its arguments. Never interpolate those into a shell construct that re-parses them. Passing them as separate `logger` arguments, as in the `hosts.deny` above, is safe; embedding them in a backtick or `eval` is a root-level command-injection hole.

### 4.5 Testing without touching the daemon

The wrappers package ships two purpose-built testers. Use them — do not test by trying to connect from production.

```
$ sudo tcpdchk -v
Using network configuration file: /etc/inetd.conf

>>> Rule /etc/hosts.allow line 12:
daemons:  vsftpd
clients:  10.20.0.0/24 192.0.2.7 [2001:db8:10::]/64
option:   severity auth.info
access:   granted

>>> Rule /etc/hosts.deny line 8:
daemons:  ALL
clients:  ALL
option:   severity auth.warning
access:   denied

warning: /etc/hosts.allow, line 21: rpcbind: no such process name in /etc/inetd.conf
```

That warning is expected and harmless for a directly-linked daemon such as `rpcbind`; `tcpdchk` only knows about `inetd.conf` entries. What it catches reliably are typos, unreachable rules, and syntax errors.

`tcpdmatch` answers "what would happen if this client connected right now":

```
$ tcpdmatch vsftpd 10.20.0.42
client:   hostname build01.corp.example.com
client:   address  10.20.0.42
server:   process  vsftpd
matched:  /etc/hosts.allow line 9
option:   severity auth.info
access:   granted

$ tcpdmatch vsftpd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  vsftpd
matched:  /etc/hosts.deny line 8
option:   severity auth.warning
access:   denied

$ tcpdmatch sshd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  sshd
matched:  /etc/hosts.deny line 8
access:   denied
```

**Read that last result carefully.** `tcpdmatch` says "denied" — but `sshd` does not link `libwrap`, so it never asks. `tcpdmatch` evaluates the rule files in isolation; it does not know which daemons consult them. This is exactly the false sense of security that makes TCP wrappers dangerous today.

Observing a real denial in the log:

```
$ sudo journalctl -t vsftpd -t tcpwrap --since "10 min ago" --no-pager
Aug 31 12:14:07 ftp01 vsftpd[24188]: refused connect from 203.0.113.9 (203.0.113.9)
Aug 31 12:14:07 ftp01 tcpwrap: DENY vsftpd from 203.0.113.9 (203.0.113.9) user=unknown client-info=203.0.113.9
```

### 4.6 Status, and what to use instead

| Component | libwrap support |
|---|---|
| OpenSSH | **Removed in 6.7** (2014) |
| `systemd` | **Removed in v212** (2014); `.socket` units never had it |
| RHEL / CentOS 8+ | `tcp_wrappers` package **removed** from the distribution |
| Fedora 29+ | Removed |
| Debian / Ubuntu | `libwrap0` and `tcpd` still packaged; individual daemons vary |
| `vsftpd` | Supported when built with it and `tcp_wrappers=YES` is set |
| `rpcbind`, `nfs-utils` | Supported in Debian builds; varies elsewhere |
| `xinetd`, `inetd` | Supported via the `tcpd` shim |

Trade-off table for what should actually enforce your admission policy:

| Mechanism | Layer | Enforced by | TCP handshake completes? | Per-daemon granularity | Survives daemon rebuild | Best for |
|---|---|---|---|---|---|---|
| `hosts.allow`/`hosts.deny` | Userspace library | The daemon, voluntarily | **Yes** | Yes, by process name | **No** — silently stops working | Legacy `xinetd`/`vsftpd` hosts only |
| `nftables` / `iptables` | Kernel netfilter | Kernel, mandatory | **No** (`drop`) | By port, not process | Yes | Network-edge admission — **the default choice** |
| `firewalld` rich rules | Kernel (nft backend) | Kernel, mandatory | No | By service definition | Yes | RHEL-family hosts with zone semantics |
| `systemd` `IPAddressAllow=` | eBPF cgroup filter | Kernel, mandatory | Handshake completes, `accept()` refused | **Per unit** — exact | Yes | Locking one service without touching global firewall |
| `sshd` `Match Address` + `AllowUsers` | Application | The daemon | Yes | Per user + address | Config is versioned with the daemon | SSH specifically |
| `pam_access` (`access.conf`) | PAM, at login | PAM stack | Yes | Per user + origin | Yes | Who may log in, not who may connect |

**Recommendation:** treat TCP wrappers as a read-and-recognise skill. Enforce with `nftables` at the network boundary, `systemd` `IPAddressAllow=` per unit, and the application's own ACL as the innermost layer. Keep `hosts.deny: ALL: ALL` in place on legacy hosts as cheap defence in depth — but never as the only control.

The `nftables` equivalent of the policy expressed above, complete and loadable:

```
#!/usr/sbin/nft -f
# /etc/nftables.conf — mandatory, kernel-enforced admission control.
# Load: sudo nft -f /etc/nftables.conf
# Persist: sudo systemctl enable --now nftables

flush ruleset

table inet filter {
    set admin_v4 {
        type ipv4_addr
        flags interval
        comment "management network + jump host"
        elements = { 10.20.0.0/24, 192.0.2.7 }
    }

    set admin_v6 {
        type ipv6_addr
        flags interval
        elements = { 2001:db8:10::/64 }
    }

    set ssh_bruteforce {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept comment "loopback is trusted"
        ct state established,related accept
        ct state invalid drop comment "no conntrack entry: malformed or spoofed"

        ip protocol icmp icmp type { echo-request, destination-unreachable, \
            time-exceeded, parameter-problem } accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, \
            packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, \
            nd-neighbor-advert, nd-router-advert } accept

        # SSH: management sources only, rate limited, offenders quarantined 1h.
        tcp dport 22 ip saddr @ssh_bruteforce drop
        tcp dport 22 ip saddr @admin_v4 ct state new \
            add @ssh_bruteforce { ip saddr timeout 1h limit rate over 10/minute } drop
        tcp dport 22 ip saddr @admin_v4 accept
        tcp dport 22 ip6 saddr @admin_v6 accept

        # Public HTTP/HTTPS.
        tcp dport { 80, 443 } ct state new accept

        # Everything else is dropped by policy. Sample the drops.
        limit rate 5/minute burst 10 packets \
            log prefix "nft-input-drop: " level info flags all
        counter comment "unmatched input"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        counter comment "this host is not a router"
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
```

```
$ sudo nft -c -f /etc/nftables.conf && echo "syntax OK"
syntax OK
$ sudo nft -f /etc/nftables.conf
$ sudo nft list chain inet filter input | head -8
table inet filter {
        chain input {
                type filter hook input priority filter; policy drop;
                iif "lo" accept comment "loopback is trusted"
                ct state established,related accept
                ct state invalid drop comment "no conntrack entry: malformed or spoofed"
                ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept
$ sudo nft list set inet filter ssh_bruteforce
table inet filter {
        set ssh_bruteforce {
                type ipv4_addr
                size 65535
                flags dynamic,timeout
                timeout 1h
                elements = { 203.0.113.9 expires 58m12s344ms }
        }
}
```

---

## 5. `/etc/nologin` and login admission

### 5.1 The file

If `/etc/nologin` exists, `pam_nologin.so` denies login to **every user except root** and prints the file's contents as the reason. Zero-length is legal — the user then gets a generic refusal.

```
$ sudo tee /etc/nologin <<'EOF'
================================================================
  MAINTENANCE WINDOW — CHG-2026-0831-014
  Storage controller firmware upgrade.
  Logins disabled until 2026-08-31 16:00 UTC.
  Escalation: #sre-oncall  /  oncall@corp.example.com
================================================================
EOF
$ sudo chmod 0644 /etc/nologin
```

```
$ ssh alice@web01
================================================================
  MAINTENANCE WINDOW — CHG-2026-0831-014
  Storage controller firmware upgrade.
  Logins disabled until 2026-08-31 16:00 UTC.
  Escalation: #sre-oncall  /  oncall@corp.example.com
================================================================
Connection closed by 10.20.0.15 port 22

$ ssh root@web01
Linux web01 6.1.0-23-amd64 #1 SMP Debian 6.1.99-1 x86_64
root@web01:~#
```

Removing it re-enables login immediately — no daemon restart:

```
$ sudo rm -f /etc/nologin
```

`systemd` uses this mechanism for scheduled shutdowns: it writes `/run/nologin` and symlinks `/etc/nologin` to it, so the block clears automatically on reboot.

```
$ sudo shutdown -h +30 "Storage firmware upgrade"
Shutdown scheduled for Mon 2026-08-31 12:55:00 UTC, use 'shutdown -c' to cancel.
$ ls -l /etc/nologin /run/nologin
lrwxrwxrwx 1 root root  12 Aug 31 12:25 /etc/nologin -> /run/nologin
-rw-r--r-- 1 root root  62 Aug 31 12:25 /run/nologin
$ cat /run/nologin
System is going down. Unprivileged users are not permitted to log in anymore. For technical details, see pam_nologin(8).
$ sudo shutdown -c
$ ls -l /etc/nologin
ls: cannot access '/etc/nologin': No such file or directory
```

For `pam_nologin` to work, the module must be in the PAM stack for the service:

```
$ grep -rn nologin /etc/pam.d/
/etc/pam.d/login:account  requisite  pam_nologin.so
/etc/pam.d/sshd:account   required   pam_nologin.so
```

If `/etc/pam.d/sshd` lacks that line, creating `/etc/nologin` will block console logins and do nothing to SSH. Verify per service, not globally.

### 5.2 `/etc/nologin` vs `/sbin/nologin` — different things, similar names

| | `/etc/nologin` | `/usr/sbin/nologin` (`/sbin/nologin`) |
|---|---|---|
| Kind | A **file whose existence** is a flag | An **executable** used as a login shell |
| Scope | **All non-root users**, host-wide | **One account** |
| Mechanism | `pam_nologin.so` | Field 7 of `/etc/passwd` |
| Persistence | Until the file is deleted | Until the shell is changed |
| Message source | Contents of `/etc/nologin` | Contents of `/etc/nologin.txt`, else built-in text |
| Typical use | Maintenance windows | Service accounts |

```
$ sudo usermod -s /usr/sbin/nologin backupsvc
$ su - backupsvc
This account is currently not available.
$ echo $?
1

$ echo "Service account. Interactive login is not permitted." | sudo tee /etc/nologin.txt
$ su - backupsvc
Service account. Interactive login is not permitted.
```

`/bin/false` achieves the same denial but prints nothing, which makes user reports harder to triage. Prefer `nologin`.

Neither shell blocks non-interactive SSH by itself in every configuration, so for service accounts also ensure there is no usable `authorized_keys` and the password field is `*` or `!`.

### 5.3 `pam_access` — the fine-grained layer

`/etc/security/access.conf` controls *who* may log in *from where*, evaluated first-match:

```
# /etc/security/access.conf
# permission : users/groups : origins
#   +  = allow      -  = deny
# First matching line wins. Terminate with a catch-all deny.

+ : root       : 10.20.0.0/24 LOCAL
+ : sre        : 10.20.0.0/24 2001:db8:10::/64
+ : deploy     : 10.20.0.10 10.20.0.11
+ : (wheel)    : LOCAL
- : ALL        : ALL
```

Enable it for the relevant service:

```
$ grep -n pam_access /etc/pam.d/sshd
44:account  required  pam_access.so
```

### 5.4 Complete lockdown checklist

```
# Prevent NEW logins host-wide (reversible in one command)
$ sudo systemctl stop sshd.socket 2>/dev/null; sudo touch /etc/nologin

# Per-account, permanent
$ sudo usermod -L        contractor          # lock password
$ sudo chage  -E 0       contractor          # expire the account (also blocks keys)
$ sudo usermod -s /usr/sbin/nologin contractor
$ sudo crontab -r -u     contractor 2>/dev/null || true
$ sudo pkill -KILL -u    contractor

# Verify
$ sudo passwd -S contractor
contractor L 08/31/2026 1 90 14 30
$ sudo chage -l contractor | grep -i 'account expires'
Account expires                                         : Jan 01, 1970
```

---

## 6. Full infrastructure manifests

### 6.1 Ansible role — the complete objective, enforced

```yaml
---
# roles/host_security/defaults/main.yml
host_security_encrypt_method: YESCRYPT
host_security_yescrypt_cost: 7
host_security_pass_max_days: 90
host_security_pass_min_days: 1
host_security_pass_warn_age: 14
host_security_umask: "077"

host_security_masked_units:
  - rpcbind.socket
  - rpcbind.service
  - avahi-daemon.socket
  - avahi-daemon.service
  - cups.socket
  - cups.service
  - bluetooth.service

host_security_removed_packages:
  - telnetd
  - rsh-server
  - rsh-client
  - nis
  - talk
  - talkd
  - xinetd

host_security_allowed_listen_ports:
  - 22
  - 80
  - 443

host_security_wrappers_allow:
  - "10.20.0.0/255.255.255.0"
  - "192.0.2.7"

host_security_manage_wrappers: true
```

```yaml
---
# roles/host_security/tasks/main.yml
- name: Gather package facts
  ansible.builtin.package_facts:
    manager: auto

# ---------------------------------------------------------------------
# 1. Shadow passwords
# ---------------------------------------------------------------------
- name: Ensure shadow passwords are enabled
  ansible.builtin.command:
    cmd: pwconv
  changed_when: false
  check_mode: false

- name: Ensure group shadow file is enabled
  ansible.builtin.command:
    cmd: grpconv
  changed_when: false
  check_mode: false

- name: Assert that no hash remains in /etc/passwd
  ansible.builtin.shell:
    cmd: "awk -F: 'length($2) > 1 {print $1}' /etc/passwd"
  register: hs_unshadowed
  changed_when: false
  failed_when: hs_unshadowed.stdout | length > 0

- name: Enforce permissions on the account databases
  ansible.builtin.file:
    path: "{{ item.path }}"
    owner: root
    group: "{{ item.group }}"
    mode: "{{ item.mode }}"
  loop:
    - { path: /etc/passwd,  group: root,   mode: "0644" }
    - { path: /etc/group,   group: root,   mode: "0644" }
    - { path: /etc/shadow,  group: "{{ 'shadow' if ansible_os_family == 'Debian' else 'root' }}",
        mode: "{{ '0640' if ansible_os_family == 'Debian' else '0000' }}" }
    - { path: /etc/gshadow, group: "{{ 'shadow' if ansible_os_family == 'Debian' else 'root' }}",
        mode: "{{ '0640' if ansible_os_family == 'Debian' else '0000' }}" }

- name: Configure password policy in /etc/login.defs
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^\\s*#?\\s*{{ item.key }}\\s+"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
    create: false
    backup: true
  loop:
    - { key: ENCRYPT_METHOD,       value: "{{ host_security_encrypt_method }}" }
    - { key: YESCRYPT_COST_FACTOR, value: "{{ host_security_yescrypt_cost }}" }
    - { key: PASS_MAX_DAYS,        value: "{{ host_security_pass_max_days }}" }
    - { key: PASS_MIN_DAYS,        value: "{{ host_security_pass_min_days }}" }
    - { key: PASS_WARN_AGE,        value: "{{ host_security_pass_warn_age }}" }
    - { key: UMASK,                value: "{{ host_security_umask }}" }
    - { key: HOME_MODE,            value: "0700" }
    - { key: LOG_UNKFAIL_ENAB,     value: "no" }
    - { key: DEFAULT_HOME,         value: "no" }
    - { key: LOGIN_RETRIES,        value: "3" }

- name: Report accounts still using a legacy hash
  ansible.builtin.shell:
    cmd: "awk -F: '$2 ~ /^\\$(1|5)\\$/ {print $1}' /etc/shadow"
  register: hs_legacy_hashes
  changed_when: false
  become: true

- name: Warn about legacy hashes
  ansible.builtin.debug:
    msg: >-
      Accounts still on md5crypt/sha256crypt: {{ hs_legacy_hashes.stdout_lines | join(', ') }}.
      Force rotation with: chage -d 0 <user>
  when: hs_legacy_hashes.stdout_lines | length > 0

- name: Find UID 0 accounts other than root
  ansible.builtin.shell:
    cmd: "awk -F: '$3 == 0 && $1 != \"root\" {print $1}' /etc/passwd"
  register: hs_uid0
  changed_when: false
  failed_when: hs_uid0.stdout | length > 0

- name: Find accounts with an empty password field
  ansible.builtin.shell:
    cmd: "awk -F: '$2 == \"\" {print $1}' /etc/shadow"
  register: hs_empty_pw
  changed_when: false
  become: true
  failed_when: hs_empty_pw.stdout | length > 0

- name: Run pwck and grpck in read-only mode
  ansible.builtin.command:
    cmd: "{{ item }} -r"
  loop:
    - pwck
    - grpck
  register: hs_ck
  changed_when: false
  failed_when: hs_ck.rc not in [0, 2]

# ---------------------------------------------------------------------
# 2. Network services
# ---------------------------------------------------------------------
- name: Remove obsolete cleartext network services
  ansible.builtin.package:
    name: "{{ host_security_removed_packages }}"
    state: absent
    purge: "{{ true if ansible_pkg_mgr == 'apt' else omit }}"

- name: Mask units that must never start
  ansible.builtin.systemd_service:
    name: "{{ item }}"
    state: stopped
    enabled: false
    masked: true
    daemon_reload: true
  loop: "{{ host_security_masked_units }}"
  failed_when: false

- name: Collect the current listening sockets
  ansible.builtin.command:
    cmd: ss -tlnH
  register: hs_listen
  changed_when: false

- name: Compute non-loopback listening ports
  ansible.builtin.set_fact:
    hs_public_ports: >-
      {{ hs_listen.stdout_lines
         | map('regex_replace', '^\\S+\\s+\\d+\\s+\\d+\\s+(\\S+)\\s+.*$', '\\1')
         | reject('search', '^127\\.')
         | reject('search', '^\\[::1\\]')
         | map('regex_replace', '^.*:(\\d+)$', '\\1')
         | map('int')
         | unique | sort }}

- name: Fail on any unexpected public listener
  ansible.builtin.assert:
    that:
      - hs_public_ports | difference(host_security_allowed_listen_ports) | length == 0
    fail_msg: >-
      Unexpected public listeners: {{ hs_public_ports | difference(host_security_allowed_listen_ports) }}.
      Allowed: {{ host_security_allowed_listen_ports }}
    success_msg: "Listening sockets match policy: {{ hs_public_ports }}"

- name: Disable every xinetd service present on the host
  ansible.builtin.replace:
    path: "{{ item }}"
    regexp: '^(\s*disable\s*=\s*).*$'
    replace: '\1yes'
  loop: "{{ query('fileglob', '/etc/xinetd.d/*') }}"
  when: "'xinetd' in ansible_facts.packages"
  notify: reload xinetd

# ---------------------------------------------------------------------
# 3. TCP wrappers (legacy defence in depth)
# ---------------------------------------------------------------------
- name: Deploy /etc/hosts.deny
  ansible.builtin.copy:
    dest: /etc/hosts.deny
    owner: root
    group: root
    mode: "0644"
    backup: true
    content: |
      # Managed by Ansible - role host_security. Do not edit by hand.
      # Consulted only by daemons linked against libwrap.
      # Verify: ldd $(command -v <daemon>) | grep libwrap
      ALL: ALL : severity auth.warning
  when: host_security_manage_wrappers | bool

- name: Deploy /etc/hosts.allow
  ansible.builtin.copy:
    dest: /etc/hosts.allow
    owner: root
    group: root
    mode: "0644"
    backup: true
    content: |
      # Managed by Ansible - role host_security. Do not edit by hand.
      # First match wins, then evaluation stops.
      ALL: 127.0.0.1 [::1] LOCAL
      {% for net in host_security_allowed_wrappers_nets | default(host_security_wrappers_allow) %}
      ALL: {{ net }}
      {% endfor %}
  when: host_security_manage_wrappers | bool

- name: Validate the wrapper rule files
  ansible.builtin.command:
    cmd: tcpdchk
  register: hs_tcpdchk
  changed_when: false
  failed_when: "'error' in hs_tcpdchk.stderr | lower"
  when:
    - host_security_manage_wrappers | bool
    - "'tcpd' in ansible_facts.packages"

# ---------------------------------------------------------------------
# 4. Login admission
# ---------------------------------------------------------------------
- name: Ensure /etc/nologin is absent during normal operation
  ansible.builtin.file:
    path: /etc/nologin
    state: absent

- name: Ensure pam_nologin is in the sshd account stack
  ansible.builtin.lineinfile:
    path: /etc/pam.d/sshd
    line: "account    required     pam_nologin.so"
    regexp: '^account\s+\S+\s+pam_nologin\.so'
    insertafter: '^account'
    state: present

- name: Give every system account a non-interactive shell
  ansible.builtin.user:
    name: "{{ item }}"
    shell: /usr/sbin/nologin
  loop: "{{ ansible_facts.getent_passwd | default({}) | dict2items
            | selectattr('value.1', 'defined')
            | selectattr('value.1', 'match', '^[0-9]+$')
            | selectattr('value.1', 'int', '<', 1000)
            | map(attribute='key') | reject('equalto', 'root')
            | reject('equalto', 'sync') | list }}"
  when: ansible_facts.getent_passwd is defined
  failed_when: false
```

```yaml
---
# roles/host_security/handlers/main.yml
- name: reload xinetd
  ansible.builtin.systemd_service:
    name: xinetd
    state: reloaded
```

```yaml
---
# site.yml
- name: Apply host security baseline
  hosts: linux_fleet
  become: true
  gather_facts: true
  vars:
    host_security_allowed_listen_ports: [22, 80, 443]
  roles:
    - role: host_security
  post_tasks:
    - name: Emit the final listening socket inventory
      ansible.builtin.command:
        cmd: ss -tulpnH
      register: hs_final
      changed_when: false
    - name: Show it
      ansible.builtin.debug:
        var: hs_final.stdout_lines
```

```
$ ansible-playbook -i inventory/prod site.yml --limit web01 --diff

PLAY [Apply host security baseline] ********************************************

TASK [host_security : Assert that no hash remains in /etc/passwd] **************
ok: [web01]

TASK [host_security : Enforce permissions on the account databases] ************
changed: [web01] => (item={'path': '/etc/shadow', 'group': 'shadow', 'mode': '0640'})
--- before
+++ after
@@ -1,4 +1,4 @@
 {
-    "mode": "0644",
+    "mode": "0640",
     "path": "/etc/shadow"
 }

TASK [host_security : Configure password policy in /etc/login.defs] ************
changed: [web01] => (item={'key': 'ENCRYPT_METHOD', 'value': 'YESCRYPT'})
ok: [web01] => (item={'key': 'PASS_MAX_DAYS', 'value': 90})

TASK [host_security : Mask units that must never start] ***********************
changed: [web01] => (item=rpcbind.socket)
changed: [web01] => (item=rpcbind.service)
ok: [web01] => (item=cups.socket)

TASK [host_security : Fail on any unexpected public listener] *****************
ok: [web01] => {
    "changed": false,
    "msg": "Listening sockets match policy: [22, 80, 443]"
}

PLAY RECAP *********************************************************************
web01  : ok=19  changed=4  unreachable=0  failed=0  skipped=2  rescued=0  ignored=0
```

### 6.2 cloud-init — the baseline at first boot

```yaml
#cloud-config
# Applied at first boot. Everything here is enforced before the instance
# is reachable, which closes the window between provisioning and hardening.

hostname: web02
fqdn: web02.corp.example.com
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys: []
  - name: sre
    gecos: SRE on-call
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    lock_passwd: true
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq9F3n2sT8vX1oB7dYzR4mWpQ0jH6cLeN5aVuG8kTsP sre@bastion"
  - name: metrics
    system: true
    shell: /usr/sbin/nologin
    lock_passwd: true

write_files:
  - path: /etc/login.defs.d/99-hardening.conf
    permissions: "0644"
    owner: root:root
    content: |
      ENCRYPT_METHOD          YESCRYPT
      YESCRYPT_COST_FACTOR    7
      PASS_MAX_DAYS           90
      PASS_MIN_DAYS           1
      PASS_WARN_AGE           14
      UMASK                   077
      HOME_MODE               0700
      LOG_UNKFAIL_ENAB        no
      DEFAULT_HOME            no

  - path: /etc/hosts.deny
    permissions: "0644"
    owner: root:root
    content: |
      # Default deny for libwrap-linked daemons only.
      ALL: ALL : severity auth.warning

  - path: /etc/hosts.allow
    permissions: "0644"
    owner: root:root
    content: |
      ALL: 127.0.0.1 [::1] LOCAL
      ALL: 10.20.0.0/255.255.255.0

  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    permissions: "0600"
    owner: root:root
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitEmptyPasswords no
      AuthenticationMethods publickey
      AllowGroups sudo
      ListenAddress 10.20.0.16
      MaxAuthTries 3
      MaxSessions 4
      LoginGraceTime 30
      ClientAliveInterval 300
      ClientAliveCountMax 2
      X11Forwarding no
      AllowAgentForwarding no
      AllowTcpForwarding no
      UsePAM yes

  - path: /etc/systemd/system/metrics-collector.socket
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Metrics collector socket

      [Socket]
      ListenStream=10.20.0.16:9110
      Accept=yes
      MaxConnectionsPerSource=4
      IPAddressDeny=any
      IPAddressAllow=10.20.0.0/24
      IPAddressAllow=localhost

      [Install]
      WantedBy=sockets.target

packages:
  - nftables
  - auditd
  - libpam-pwquality

package_update: true
package_upgrade: true

runcmd:
  - [ pwconv ]
  - [ grpconv ]
  - [ chmod, "0640", /etc/shadow ]
  - [ chgrp, shadow, /etc/shadow ]
  - [ systemctl, mask, --now, rpcbind.socket, rpcbind.service ]
  - [ systemctl, mask, --now, avahi-daemon.socket, avahi-daemon.service ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, nftables.service ]
  - [ systemctl, enable, --now, metrics-collector.socket ]
  - [ systemctl, restart, ssh ]
  - [ sh, -c, "ss -tulpnH > /var/log/first-boot-sockets.txt" ]

power_state:
  mode: reboot
  message: "Rebooting after security baseline"
  timeout: 60
  condition: true
```

### 6.3 CI gate — fail the build, not the incident review

```bash
#!/usr/bin/env bash
# scripts/verify-host-security.sh
# Exit 0 = compliant. Any non-zero = a specific, named violation.
set -euo pipefail

fail=0
report() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
pass()   { printf 'ok  : %s\n' "$1"; }

# --- 1. Shadow passwords ----------------------------------------------
if awk -F: 'length($2) > 1 {exit 1}' /etc/passwd; then
    pass "no password hash in /etc/passwd"
else
    report "/etc/passwd contains hashes - run pwconv"
fi

shadow_mode=$(stat -c '%a' /etc/shadow)
case "$shadow_mode" in
    0|000|400|600|640) pass "/etc/shadow mode $shadow_mode" ;;
    *) report "/etc/shadow is mode $shadow_mode (expected 0000, 0400, 0600 or 0640)" ;;
esac

if [ "$(awk -F: '$3 == 0 && $1 != "root"' /etc/passwd | wc -l)" -eq 0 ]; then
    pass "root is the only UID 0"
else
    report "extra UID 0 account(s): $(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')"
fi

if [ "$(awk -F: '$2 == ""' /etc/shadow | wc -l)" -eq 0 ]; then
    pass "no empty password fields"
else
    report "empty password field: $(awk -F: '$2==""{print $1}' /etc/shadow | tr '\n' ' ')"
fi

legacy=$(awk -F: '$2 ~ /^\$(1|5)\$/ {print $1}' /etc/shadow | tr '\n' ' ')
[ -z "$legacy" ] && pass "no md5crypt/sha256crypt hashes" \
                 || report "legacy hashes: $legacy"

grep -qE '^\s*ENCRYPT_METHOD\s+(YESCRYPT|SHA512|BCRYPT)\b' /etc/login.defs \
    && pass "ENCRYPT_METHOD is modern" \
    || report "ENCRYPT_METHOD is weak or unset in /etc/login.defs"

pwck -r >/dev/null 2>&1 && pass "pwck clean" || echo "warn: pwck reported issues"

# --- 2. Listening sockets ---------------------------------------------
allowed_ports="22 80 443"
public=$(ss -tlnH \
    | awk '{print $4}' \
    | grep -Ev '^(127\.|\[::1\])' \
    | sed -E 's/.*:([0-9]+)$/\1/' \
    | sort -un)

for p in $public; do
    case " $allowed_ports " in
        *" $p "*) pass "listener on $p is expected" ;;
        *)        report "unexpected public listener on port $p" ;;
    esac
done

if systemctl is-enabled rpcbind.socket >/dev/null 2>&1; then
    report "rpcbind.socket is enabled"
else
    pass "rpcbind.socket not enabled"
fi

# --- 3. xinetd ---------------------------------------------------------
if [ -d /etc/xinetd.d ]; then
    enabled=$(grep -lE '^\s*disable\s*=\s*no' /etc/xinetd.d/* 2>/dev/null || true)
    [ -z "$enabled" ] && pass "no xinetd service enabled" \
                      || report "xinetd services enabled: $enabled"
else
    pass "xinetd not installed"
fi

# --- 4. TCP wrappers ---------------------------------------------------
if [ -f /etc/hosts.deny ]; then
    grep -qE '^\s*ALL\s*:\s*ALL' /etc/hosts.deny \
        && pass "hosts.deny has a default-deny rule" \
        || report "hosts.deny lacks 'ALL: ALL'"
else
    report "/etc/hosts.deny missing (wrappers default to permit)"
fi

command -v tcpdchk >/dev/null 2>&1 && { tcpdchk 2>&1 | grep -i '^error' && report "tcpdchk reported errors" || pass "tcpdchk clean"; }

# --- 5. Login admission ------------------------------------------------
[ -e /etc/nologin ] && report "/etc/nologin present - logins are blocked" \
                    || pass "/etc/nologin absent"

grep -q 'pam_nologin.so' /etc/pam.d/sshd \
    && pass "pam_nologin in sshd stack" \
    || report "pam_nologin missing from /etc/pam.d/sshd"

exit "$fail"
```

```
$ sudo ./scripts/verify-host-security.sh
ok  : no password hash in /etc/passwd
ok  : /etc/shadow mode 640
ok  : root is the only UID 0
ok  : no empty password fields
ok  : no md5crypt/sha256crypt hashes
ok  : ENCRYPT_METHOD is modern
ok  : pwck clean
ok  : listener on 22 is expected
ok  : listener on 80 is expected
ok  : listener on 443 is expected
ok  : rpcbind.socket not enabled
ok  : no xinetd service enabled
ok  : hosts.deny has a default-deny rule
ok  : tcpdchk clean
ok  : /etc/nologin absent
ok  : pam_nologin in sshd stack
$ echo $?
0
```

---

## 7. Verification and failure diagnosis

### 7.1 Symptom → cause → command

| Symptom | Probable cause | Confirm with |
|---|---|---|
| A user cannot log in, no message | Shell is `/bin/false` | `getent passwd user \| cut -d: -f7` |
| "This account is currently not available." | Shell is `/usr/sbin/nologin` | `getent passwd user \| cut -d: -f7` |
| "Your account has expired" | Field 8 of `/etc/shadow` is past | `chage -l user` |
| "You are required to change your password immediately" | Field 3 is `0`, or max age exceeded | `chage -l user` |
| Password rejected, but it is correct | Account locked (`!` prefix) | `passwd -S user` |
| Everyone but root is refused | `/etc/nologin` exists | `ls -l /etc/nologin; cat /etc/nologin` |
| Console login works, SSH does not | `pam_nologin`/`pam_access` only in one stack | `grep -rn 'pam_nologin\|pam_access' /etc/pam.d/` |
| Port still open after `systemctl disable` | Socket-activated | `systemctl list-sockets \| grep <port>` |
| Service restarts after `stop` | Another unit `Wants=` it | `systemctl list-dependencies --reverse <unit>` |
| `hosts.deny` seems ignored | Daemon does not link `libwrap` | `ldd $(command -v <daemon>) \| grep libwrap` |
| `hosts.deny` ignored despite `libwrap` | A `hosts.allow` rule matched first | `tcpdmatch <daemon> <client>` |
| Wrapper rule matches nothing | Wrong daemon name — needs `argv[0]`, not the port | `ps -eo comm,args \| grep <svc>` |
| Locked user still logs in via SSH | Key auth ignores the password lock | `chage -E 0 user`, empty `authorized_keys` |
| Password change refused: "must wait" | `PASS_MIN_DAYS` not elapsed | `chage -l user` |
| `useradd` still makes `$6$` hashes | `ENCRYPT_METHOD` not applied, or `libcrypt` lacks yescrypt | `grep ENCRYPT /etc/login.defs; ldd $(which login) \| grep crypt` |
| `hosts.allow` edit takes no effect | Only new connections are checked | Reconnect; `libwrap` reads the files per connection |

### 7.2 Walkthrough: "I put `sshd: ALL` in hosts.deny and nothing happened"

```
$ sudo grep -n sshd /etc/hosts.deny
3:sshd: ALL

$ tcpdmatch sshd 203.0.113.9
client:   hostname unknown
client:   address  203.0.113.9
server:   process  sshd
matched:  /etc/hosts.deny line 3
access:   denied

$ ssh -o ConnectTimeout=5 test@10.20.0.15 'echo CONNECTED'
CONNECTED
```

`tcpdmatch` says denied; the connection succeeds. Resolve the contradiction by asking whether `sshd` ever consults the rules:

```
$ ldd "$(command -v sshd)" | grep -ci wrap
0
$ sshd -V 2>&1 | head -1
OpenSSH_9.2p1 Debian-2+deb12u3, OpenSSL 3.0.14 4 Jun 2024
$ dpkg -s openssh-server | grep -i '^Version'
Version: 1:9.2p1-2+deb12u3
```

OpenSSH 9.2 ≫ 6.7, so `libwrap` support is gone. The rule is inert. Enforce in the kernel instead:

```
$ sudo nft add rule inet filter input tcp dport 22 ip saddr != @admin_v4 counter drop
$ sudo nft list ruleset | grep -A1 'dport 22'
                tcp dport 22 ip saddr != @admin_v4 counter packets 0 bytes 0 drop
$ ssh -o ConnectTimeout=5 test@10.20.0.15 'echo CONNECTED'
ssh: connect to host 10.20.0.15 port 22: Connection timed out
```

**Before adding any SSH firewall rule, open a second session and keep it alive.** A safety net that has saved many people:

```
$ sudo systemd-run --on-active=300 --timer-property=AccuracySec=1s \
      /usr/sbin/nft flush ruleset
Running timer as unit: run-r7f3c1b2a.timer
Will run service as unit: run-r7f3c1b2a.service
```

If you lock yourself out, the ruleset is flushed in five minutes. If the change is good, cancel it:

```
$ sudo systemctl stop run-r7f3c1b2a.timer
```

### 7.3 Walkthrough: "the port keeps reopening"

```
$ sudo systemctl stop cups.service
$ sudo ss -tlpn 'sport = :631'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:631       0.0.0.0:*     users:(("systemd",pid=1,fd=51))

$ systemctl list-sockets --all | grep 631
127.0.0.1:631   cups.socket   cups.service

$ systemctl list-dependencies --reverse cups.socket
cups.socket
● └─sockets.target
●   └─basic.target

$ sudo systemctl disable --now cups.socket cups.path cups.service
Removed "/etc/systemd/system/sockets.target.wants/cups.socket".
Removed "/etc/systemd/system/multi-user.target.wants/cups.path".
$ sudo ss -tlpn 'sport = :631'
$ echo "closed"
closed
```

`cups` ships **three** units — `.service`, `.socket` and `.path`. Any one of them can restart the daemon. `systemctl list-unit-files 'cups*'` shows the full set before you decide.

### 7.4 Walkthrough: "which package opened this port?"

```
$ sudo ss -tlpn 'sport = :8125'
LISTEN 0 4096 0.0.0.0:8125 0.0.0.0:* users:(("statsd-proxy",pid=3311,fd=7))

$ readlink -f /proc/3311/exe
/opt/observability/bin/statsd-proxy
$ dpkg -S /opt/observability/bin/statsd-proxy 2>/dev/null || echo "not from a package"
not from a package

$ cat /proc/3311/cgroup
0::/system.slice/statsd-proxy.service
$ systemctl cat statsd-proxy.service | head -12
# /etc/systemd/system/statsd-proxy.service
[Unit]
Description=StatsD UDP/TCP proxy
After=network-online.target

[Service]
ExecStart=/opt/observability/bin/statsd-proxy --listen 0.0.0.0:8125
User=statsd
$ stat -c '%y %U' /etc/systemd/system/statsd-proxy.service
2026-07-19 14:03:22.114 root
```

Not packaged, hand-installed, listening on all interfaces. The correct remediation is not to mask it — it is presumably needed — but to narrow its exposure without editing a file someone else owns:

```
$ sudo systemctl edit statsd-proxy.service
```
```ini
# /etc/systemd/system/statsd-proxy.service.d/override.conf
[Service]
IPAddressDeny=any
IPAddressAllow=10.20.0.0/24
IPAddressAllow=localhost
```
```
$ sudo systemctl daemon-reload && sudo systemctl restart statsd-proxy
$ systemd-analyze security statsd-proxy.service | grep -E 'IPAddress|Overall'
✓ IPAddressDeny=                                       Service blocks all IP address ranges
→ Overall exposure level for statsd-proxy.service: 6.1 MEDIUM 🙁
```

### 7.5 Continuous verification

```
$ sudo lynis audit system --tests-from-group authentication,networking --quiet
[+] Authentication
  - Checking presence /etc/shadow                             [ OK ]
  - Checking password hashing methods                         [ OK ]
  - Checking PASS_MAX_DAYS option in /etc/login.defs          [ OK ]
  - Checking accounts with UID zero                           [ OK ]
[+] Networking
  - Checking listening ports (TCP/UDP)                        [ DONE ]
      * 0.0.0.0:22 (sshd)
      * 0.0.0.0:80 (nginx)
      * 0.0.0.0:443 (nginx)

$ sudo aureport --auth --summary -i --start today
Authentication Summary Report
=============================
total  acct
88     sre
14     root
7      unknown(203.0.113.9)

$ sudo journalctl -p warning --facility=auth,authpriv --since today --no-pager | tail -5
Aug 31 12:14:07 ftp01 vsftpd[24188]: refused connect from 203.0.113.9
Aug 31 12:31:52 web01 sshd[24310]: Invalid user admin from 203.0.113.9 port 51992
Aug 31 12:31:52 web01 sshd[24310]: Connection closed by invalid user admin 203.0.113.9 port 51992 [preauth]
```

Wire the CI script from §6.3 into a timer so drift is caught between audits:

```ini
# /etc/systemd/system/host-security-audit.service
[Unit]
Description=Host security baseline audit
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/verify-host-security.sh
StandardOutput=journal
StandardError=journal
```
```ini
# /etc/systemd/system/host-security-audit.timer
[Unit]
Description=Daily host security baseline audit
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
```
```
$ sudo systemctl enable --now host-security-audit.timer
$ systemctl list-timers host-security-audit.timer --no-pager
NEXT                        LEFT     LAST                       PASSED  UNIT                       ACTIVATES
Tue 2026-09-01 00:17:41 UTC 11h left Mon 2026-08-31 00:22:09 UTC 12h ago host-security-audit.timer  host-security-audit.service
```

---

## 8. Exam-focused summary

| File | Purpose | The thing you will be asked |
|---|---|---|
| `/etc/passwd` | Identity; world-readable | `x` in field 2 = shadowing on. 7 fields, `:` separated |
| `/etc/shadow` | Hashes + aging; root-only | 9 fields. Field 3, 5 and 8 are **days since 1970-01-01** |
| `/etc/group`, `/etc/gshadow` | Group identity and secrets | `grpconv`/`grpunconv`, `gpasswd` |
| `/etc/login.defs` | Defaults for **new** accounts | `PASS_MAX_DAYS`, `PASS_MIN_DAYS`, `PASS_WARN_AGE`, `ENCRYPT_METHOD`, `UMASK` |
| `/etc/nologin` | Blocks all non-root logins while it exists | Root is exempt; contents shown to the user |
| `/etc/inittab` | SysV default runlevel and actions | `id:3:initdefault:` |
| `/etc/init.d/*` | SysV service scripts | `update-rc.d` (Debian), `chkconfig` (RHEL), `rcN.d` `S`/`K` links |
| `/etc/inetd.conf` | Legacy super-server | Comment the line to disable |
| `/etc/xinetd.conf` | `defaults { }` + `includedir /etc/xinetd.d` | Global limits |
| `/etc/xinetd.d/*` | One file per service | **`disable = yes`** disables. `only_from`, `no_access` |
| `systemd.socket` units | Modern socket activation | Disable the **`.socket`**, not just the `.service` |
| `/etc/hosts.allow` | Wrapper allow rules | Read **first**; first match grants and stops |
| `/etc/hosts.deny` | Wrapper deny rules | Read **second**; `ALL: ALL` for default-deny |

Command reference:

| Command | Use |
|---|---|
| `pwconv` / `pwunconv` | Enable / disable shadow passwords |
| `grpconv` / `grpunconv` | Same for groups |
| `pwck -r` / `grpck -r` | Verify database consistency |
| `vipw` / `vigr` (`-s`) | Edit account files under lock |
| `chage -l user` | Show aging; `-E 0` disables the account; `-d 0` forces a change |
| `passwd -S user` | State: `P` usable, `L` locked, `NP` none |
| `passwd -l` / `-u` / `-d` | Lock / unlock / **delete** the password |
| `usermod -L` / `-U` / `-s` | Lock / unlock / change shell |
| `getent passwd\|shadow\|group` | Query through NSS, not just the flat file |
| `ss -tulpn` | Listening sockets with owning process |
| `lsof -nP -iTCP -sTCP:LISTEN` | Same, alternative view |
| `systemctl list-sockets --all` | Socket units and what they activate |
| `systemctl disable --now` / `mask --now` | Turn off / make unstartable |
| `systemctl list-unit-files --state=enabled` | Everything that autostarts |
| `chkconfig` / `update-rc.d` | SysV and `xinetd` enable/disable |
| `tcpdchk [-v]` | Validate wrapper rule syntax |
| `tcpdmatch <daemon> <client>` | Simulate an access decision |
| `ldd $(command -v d) \| grep libwrap` | **Does this daemon use wrappers at all?** |
| `systemd-analyze security <unit>` | Score a unit's sandboxing |
| `nft -c -f file` / `nft list ruleset` | Check / show the firewall |

Three facts most often missed:

1. **`hosts.allow` is evaluated first and first match wins.** No `hosts.deny` rule can override it.
2. **Disabling a `.service` does not close a socket-activated port.** Disable the `.socket`.
3. **The shadow date fields are days since the epoch, not timestamps.** `date -d "1970-01-01 + N days"`.

---

## 9. Referencias

**LPI certification objectives**
- LPIC-1 Exam 101-500 objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPIC-1 Exam 102-500 objectives (Topic 110 lives here) — https://www.lpi.org/our-certifications/exam-102-objectives/
- LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Accounts, shadow passwords and aging**
- `shadow(5)` — https://man7.org/linux/man-pages/man5/shadow.5.html
- `passwd(5)` — https://man7.org/linux/man-pages/man5/passwd.5.html
- `gshadow(5)` — https://man7.org/linux/man-pages/man5/gshadow.5.html
- `login.defs(5)` — https://man7.org/linux/man-pages/man5/login.defs.5.html
- `crypt(5)` — hash format identifiers — https://man7.org/linux/man-pages/man5/crypt.5.html
- `chage(1)` — https://man7.org/linux/man-pages/man1/chage.1.html
- `passwd(1)` — https://man7.org/linux/man-pages/man1/passwd.1.html
- `pwconv(8)` / `pwunconv(8)` / `grpconv(8)` — https://man7.org/linux/man-pages/man8/pwconv.8.html
- `pwck(8)` — https://man7.org/linux/man-pages/man8/pwck.8.html
- `vipw(8)` / `vigr(8)` — https://man7.org/linux/man-pages/man8/vipw.8.html
- shadow-utils upstream — https://github.com/shadow-maint/shadow
- libxcrypt (the `libcrypt` implementation on modern Linux) — https://github.com/besser82/libxcrypt
- yescrypt specification — https://www.openwall.com/yescrypt/
- NIST SP 800-63B, Digital Identity Guidelines: Authenticators — https://pages.nist.gov/800-63-3/sp800-63b.html

**Login admission**
- `nologin(5)` — the `/etc/nologin` file — https://man7.org/linux/man-pages/man5/nologin.5.html
- `nologin(8)` — the shell — https://man7.org/linux/man-pages/man8/nologin.8.html
- `pam_nologin(8)` — https://man7.org/linux/man-pages/man8/pam_nologin.8.html
- `pam_access(8)` and `access.conf(5)` — https://man7.org/linux/man-pages/man8/pam_access.8.html
- Linux-PAM system administrators' guide — https://github.com/linux-pam/linux-pam/blob/master/doc/sag/Linux-PAM_SAG.xml

**Services, init and socket activation**
- `systemd.socket(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html
- `systemd.service(5)` — https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.exec(5)` — sandboxing directives — https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemctl(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemctl.html
- `daemon(7)`, "Socket-Based Activation" — https://www.freedesktop.org/software/systemd/man/latest/daemon.html
- `sd_listen_fds(3)` — the `LISTEN_FDS` protocol — https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html
- `systemd-socket-activate(1)` — https://www.freedesktop.org/software/systemd/man/latest/systemd-socket-activate.html
- `systemd-analyze(1)` — the `security` verb — https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- `inittab(5)` — https://man7.org/linux/man-pages/man5/inittab.5.html
- `init(8)` (sysvinit) — https://man7.org/linux/man-pages/man8/init.8.html
- `xinetd.conf(5)` — https://linux.die.net/man/5/xinetd.conf
- `xinetd(8)` — https://linux.die.net/man/8/xinetd
- `inetd.conf(5)` — https://man7.org/linux/man-pages/man5/inetd.conf.5.html
- `update-rc.d(8)` (Debian) — https://manpages.debian.org/stable/init-system-helpers/update-rc.d.8.en.html
- `chkconfig(8)` — https://linux.die.net/man/8/chkconfig
- `ss(8)` — https://man7.org/linux/man-pages/man8/ss.8.html
- `lsof(8)` — https://man7.org/linux/man-pages/man8/lsof.8.html

**TCP wrappers and their replacements**
- `hosts_access(5)` — rule syntax — https://man7.org/linux/man-pages/man5/hosts_access.5.html
- `hosts_options(5)` — the option field — https://man7.org/linux/man-pages/man5/hosts_options.5.html
- `tcpd(8)` — https://man7.org/linux/man-pages/man8/tcpd.8.html
- `tcpdchk(8)` — https://man7.org/linux/man-pages/man8/tcpdchk.8.html
- `tcpdmatch(8)` — https://man7.org/linux/man-pages/man8/tcpdmatch.8.html
- OpenSSH 6.7 release notes — removal of `libwrap` support — https://www.openssh.com/txt/release-6.7
- `systemd` NEWS, v212 — removal of tcpwrap support — https://github.com/systemd/systemd/blob/main/NEWS
- Considerations in adopting RHEL 8 — removal of `tcp_wrappers` — https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/considerations_in_adopting_rhel_8/
- Debian `tcpd` package — https://packages.debian.org/stable/tcpd
- nftables wiki — https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- `nft(8)` — https://www.netfilter.org/projects/nftables/manpage.html
- firewalld documentation — https://firewalld.org/documentation/
- `sshd_config(5)` — `Match`, `AllowGroups`, `ListenAddress` — https://man.openbsd.org/sshd_config

**Automation and auditing**
- Ansible `systemd_service` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/systemd_service_module.html
- Ansible `user` module — https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- cloud-init module reference — https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Linux Audit (`auditd`, `aureport`) — https://github.com/linux-audit/audit-userspace
- Lynis — https://cisofy.com/documentation/lynis/
- CIS Benchmarks — https://www.cisecurity.org/cis-benchmarks