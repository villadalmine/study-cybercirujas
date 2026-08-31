# LPIC-1 · Topic 110.1 — Perform security administration tasks

> **Exam:** 101-500 + 102-500 (LPIC-1, version 5.0) · **Objective 110.1**
> **Scope of this objective:** audit SUID/SGID files, manage passwords and password aging, discover open ports (`nmap`, `netstat`/`ss`), set login/process/memory limits, determine who is (or was) logged in, and basic `sudo`.
> **Key utilities:** `find`, `passwd`, `fuser`, `lsof`, `nmap`, `chage`, `netstat`/`ss`, `sudo`, `su`, `usermod`, `ulimit`, `who`, `w`, `last`.

**Lab safety.** Run every destructive step in a throwaway VM or container you own (a Debian/Ubuntu or a RHEL-family box is fine). Where a step changes accounts or `sudoers`, a rollback command is given. Commands prefixed with `#` require root; `$` are unprivileged. Official reference for the objective: <https://www.lpi.org/our-certifications/exam-101-objectives/> and the linked man pages (`man 1 find`, `man 5 sudoers`, `man 1 chage`, `man 5 limits.conf`).

---

## Exercise 1 — Audit the filesystem for SUID / SGID binaries

The SUID bit (`u+s`) makes an executable run with the file **owner's** privileges instead of the caller's; SGID (`g+s`) uses the group. Attackers add SUID-root binaries as a persistence/escalation mechanism, so a security audit means *knowing your baseline* and detecting drift from it.

1. Set up a controlled test artifact and a legitimate reference:

   ```bash
   # cp /bin/cp /tmp/rogue-cp          # a copy we will deliberately mark SUID
   # chmod 4755 /tmp/rogue-cp          # 4 = setuid; 755 = rwxr-xr-x
   ```

2. List the permission string and confirm the bit is present:

   ```bash
   $ ls -l /tmp/rogue-cp
   -rwsr-xr-x 1 root root 153976 Aug 31 12:04 /tmp/rogue-cp
   ```

   Note the `s` where the owner's `x` would be.

3. Audit the whole filesystem for SUID **or** SGID files, but stay on local disks (don't chase into `/proc`, NFS, etc.):

   ```bash
   # find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %g %p\n' 2>/dev/null
   4755 root root /tmp/rogue-cp
   4755 root root /usr/bin/passwd
   4755 root root /usr/bin/chsh
   4755 root root /usr/bin/sudo
   2755 root tty  /usr/bin/wall
   6755 root root /usr/bin/su
   ...
   ```

4. Distinguish the two modes of `-perm`. Run all three and compare the result counts:

   ```bash
   # find /usr/bin -perm -4000  -type f | wc -l   # SUID set (ignoring other bits)
   # find /usr/bin -perm /4000  -type f | wc -l   # SUID set (same as -4000 for a single bit)
   # find /usr/bin -perm 4755   -type f | wc -l   # mode EXACTLY 4755, nothing else
   ```

5. Save a signed baseline and diff against it later:

   ```bash
   # find / -xdev -perm -4000 -type f 2>/dev/null | sort > /root/suid.baseline
   # sha256sum /root/suid.baseline
   # find / -xdev -perm -4000 -type f 2>/dev/null | sort | diff /root/suid.baseline -
   ```

6. Remediate the rogue file and verify:

   ```bash
   # chmod u-s /tmp/rogue-cp
   $ ls -l /tmp/rogue-cp        # the 's' is now 'x'
   # rm /tmp/rogue-cp
   ```

**Comprehension check**

1. In `ls -l` output, what is the difference between `-rwsr-xr-x` and `-rwSr-xr-x` (capital `S`)?
2. Why does `find / -perm -4000` return files that `find / -perm 4755` misses?
3. What does `-xdev` do, and why does an auditor want it?
4. `su` shows mode `6755`. Which special bits are set, and what does that string mean numerically?
5. Why is removing the SUID bit safer as a first response than deleting an unexpected SUID binary outright?

---

## Exercise 2 — Find who is using a file, a mount, or a port: `fuser` and `lsof`

Before you can change a password policy, kill a runaway login, or unmount a device, you often need to know *which process holds it open*. `lsof` lists open files (and sockets); `fuser` maps a file/mount/port to the PIDs using it.

1. Open a file handle you can observe. In one terminal:

   ```bash
   $ sleep 600 > /tmp/held.log &
   [1] 4821
   ```

2. Identify the processes with that file open:

   ```bash
   $ fuser -v /tmp/held.log
                        USER        PID ACCESS COMMAND
   /tmp/held.log:       student    4821 F....  sleep
   $ lsof /tmp/held.log
   COMMAND  PID    USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
   sleep   4821 student    1w   REG  254,1        0  131 /tmp/held.log
   ```

   In the `lsof` `FD` column, `1w` means file descriptor 1 (stdout) opened for **write**.

3. Find every process a user has, and every file open under a directory:

   ```bash
   $ lsof -u student            # all files opened by user 'student'
   $ lsof +D /var/log           # recurse a directory tree
   # fuser -vm /home            # every process using the /home mount (needed before umount)
   ```

4. Map a network port to its owning process (both tools can do it):

   ```bash
   # lsof -i :22 -nP
   COMMAND PID USER   FD  TYPE DEVICE SIZE/OFF NODE NAME
   sshd    712 root    3u IPv4  18234      0t0  TCP *:22 (LISTEN)
   # fuser -v -n tcp 22
                        USER        PID ACCESS COMMAND
   22/tcp:              root        712 F....  sshd
   ```

5. Terminate everything holding a resource (careful — this sends signals):

   ```bash
   # fuser -k -TERM /tmp/held.log   # SIGTERM every PID using the file
   $ jobs                           # the background sleep should be gone
   ```

**Comprehension check**

1. What does the `-m` flag change about `fuser`'s argument — a file versus what?
2. In `lsof`, why do you pass `-nP` when investigating network sockets?
3. You must `umount /home` but it reports "target is busy." Which single command lists the offenders, and which flag would forcibly signal them?
4. `lsof -u student` and `fuser -u` overlap in intent but differ in output. What does `fuser -u` actually add to its listing?
5. Name one reason `fuser -k` on a mount is dangerous on a production host.

---

## Exercise 3 — Discover open ports: `ss`/`netstat` locally, `nmap` from outside

Two complementary viewpoints: `ss` (or the older `netstat`) shows sockets *from inside* the host with process attribution; `nmap` probes *from the network* and sees only what a remote attacker would.

1. Enumerate listening TCP and UDP sockets with owning processes (run as root to see PIDs):

   ```bash
   # ss -tulpn
   Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   tcp   LISTEN 0      128          0.0.0.0:22        0.0.0.0:*     users:(("sshd",pid=712,fd=3))
   tcp   LISTEN 0      4096       127.0.0.1:5432      0.0.0.0:*     users:(("postgres",pid=980,fd=6))
   udp   UNCONN 0      0          127.0.0.1:323       0.0.0.0:*     users:(("chronyd",pid=640,fd=5))
   ```

   Flags: `-t` TCP, `-u` UDP, `-l` listening, `-p` process, `-n` numeric (no DNS/`/etc/services` lookups).

2. The historical equivalent (from `net-tools`), for the exam and for older systems:

   ```bash
   # netstat -tulpn
   Proto Recv-Q Send-Q Local Address   Foreign Address State   PID/Program name
   tcp        0      0 0.0.0.0:22       0.0.0.0:*       LISTEN  712/sshd
   tcp        0      0 127.0.0.1:5432   0.0.0.0:*       LISTEN  980/postgres
   ```

3. Note *which interface* each service binds to. `0.0.0.0:22` is reachable from any network; `127.0.0.1:5432` is loopback-only. This distinction is the whole point of the audit.

4. Now scan the same host from the network's perspective. From a **second** machine (or use the host's own routable IP):

   ```bash
   $ nmap -sT 192.0.2.10
   PORT   STATE SERVICE
   22/tcp open  ssh
   Nmap done: 1 IP address (1 host up) scanned in 0.24 seconds
   ```

   `postgres` on `127.0.0.1` does **not** appear — nmap confirms it is not externally exposed.

5. Deepen the scan: version detection and a specific port range:

   ```bash
   $ nmap -sV -p 1-1000 192.0.2.10
   PORT   STATE SERVICE VERSION
   22/tcp open  ssh     OpenSSH 9.6p1 Ubuntu 3ubuntu13 (Ubuntu Linux; protocol 2.0)
   ```

6. Compare a TCP connect scan (`-sT`, no privileges) with a SYN "half-open" scan (`-sS`, needs root):

   ```bash
   # nmap -sS -p 22,80,443 192.0.2.10
   ```

**Comprehension check**

1. Explain, in one sentence each, why you'd use `ss -tulpn` *and* `nmap` rather than either alone.
2. What is the practical security difference between a service bound to `0.0.0.0:5432` and one bound to `127.0.0.1:5432`?
3. Which `ss`/`netstat` flag suppresses name resolution, and why does an auditor want that on?
4. Why does `nmap -sS` require root while `nmap -sT` does not?
5. A port shows `STATE filtered` in nmap output. What does that tell you that `closed` does not?

---

## Exercise 4 — Passwords and password aging: `passwd`, `chage`, `usermod`

Aging policy lives in `/etc/shadow` fields; `chage` is the front end for them, `passwd` sets the secret and can also toggle a few aging attributes.

1. Create a disposable user and inspect its shadow entry:

   ```bash
   # useradd -m -s /bin/bash alice
   # passwd alice
   New password: ********
   Retype new password: ********
   passwd: password updated successfully
   # getent shadow alice
   alice:$y$j9T$....hash....:20000:0:99999:7:::
   ```

   The colon-separated fields are: `name : hash : last-change : min : max : warn : inactive : expire :`. Dates are **days since 1970-01-01**.

2. Read the same data in human-readable form:

   ```bash
   # chage -l alice
   Last password change                                    : Aug 31, 2026
   Password expires                                        : never
   Password inactive                                       : never
   Account expires                                         : never
   Minimum number of days between password change          : 0
   Maximum number of days between password change          : 99999
   Number of days of warning before password expires       : 7
   ```

3. Apply a real policy: at least 1 day between changes, force change every 90 days, warn 7 days ahead, lock the account 14 days after expiry, and set a hard account-expiry date:

   ```bash
   # chage -m 1 -M 90 -W 7 -I 14 -E 2026-12-31 alice
   # chage -l alice
   Maximum number of days between password change          : 90
   Password expires                                        : Nov 29, 2026
   Account expires                                         : Dec 31, 2026
   ```

4. Force a password change at next login without waiting for expiry:

   ```bash
   # chage -d 0 alice          # sets "last change" to epoch day 0 → expired now
   # passwd --expire alice     # equivalent effect via passwd
   ```

5. Lock and unlock the password (note: locking ≠ expiring the account):

   ```bash
   # passwd -l alice           # prepends '!' to the hash — login by password refused
   # getent shadow alice       # observe the leading '!'
   # passwd -u alice           # unlock
   # usermod -L alice / -U alice   # usermod's equivalent lock/unlock
   ```

6. Clean up:

   ```bash
   # userdel -r alice
   ```

**Comprehension check**

1. In `/etc/shadow`, what unit are the *last change*, *max*, and *expire* fields measured in?
2. What is the difference in effect between `chage -E 2026-12-31 alice` and `chage -M 90 alice`?
3. `chage -d 0 alice` forces a change at next login. Mechanically, *why* does setting last-change to 0 do that?
4. What is the difference between `passwd -l` (lock) and `chage -E 0` (expire) for a user who logs in only via SSH **public key**?
5. Which command shows aging fields in plain English without editing `/etc/shadow` by hand?

---

## Exercise 5 — Limit logins, processes, and memory: `ulimit` and `limits.conf`

`ulimit` sets per-shell resource limits enforced by the kernel; `/etc/security/limits.conf` (via the PAM module `pam_limits.so`) sets them per user/group at login. Soft limits can be raised by the user up to the hard limit; hard limits need root to raise.

1. Inspect the current shell's limits:

   ```bash
   $ ulimit -a
   open files                          (-n) 1024
   max user processes                  (-u) 15122
   virtual memory              (kbytes, -v) unlimited
   core file size              (blocks, -c) 0
   $ ulimit -Sn        # soft open-files limit
   1024
   $ ulimit -Hn        # hard open-files limit
   524288
   ```

2. Raise a soft limit within the hard ceiling (affects this shell and its children only):

   ```bash
   $ ulimit -Sn 4096
   $ ulimit -Sn        # 4096
   $ ulimit -Sn 600000 # fails: exceeds hard limit
   bash: ulimit: open files: cannot modify limit: Operation not permitted
   ```

3. Demonstrate a limit biting. Set a tiny process cap in a subshell and fork-bomb-safely test it:

   ```bash
   $ bash -c 'ulimit -u 20; for i in $(seq 1 40); do sleep 5 & done; wait' 2>&1 | tail -3
   bash: fork: retry: Resource temporarily unavailable
   ```

4. Make a limit persistent and system-enforced. Edit `/etc/security/limits.conf` (or a drop-in under `/etc/security/limits.d/`):

   ```bash
   # cat >> /etc/security/limits.d/90-lab.conf <<'EOF'
   @developers   soft   nproc    200
   @developers   hard   nproc    400
   alice         hard   nofile   8192
   *             hard   core     0
   EOF
   ```

   Columns are `<domain> <type> <item> <value>`: domain = user, `@group`, or `*`; type = `soft`/`hard`; item = `nproc`, `nofile`, `core`, `as` (address space / memory), etc.

5. Verify the login-time enforcement (requires a fresh login session so PAM re-reads it):

   ```bash
   $ su - alice -c 'ulimit -Hn'
   8192
   ```

6. Note the `maxlogins` item for capping concurrent sessions:

   ```bash
   # echo 'alice   -   maxlogins   2' >> /etc/security/limits.d/90-lab.conf
   ```

**Comprehension check**

1. What is the relationship between a *soft* and a *hard* `ulimit`, and who can raise each?
2. Why does a `ulimit` change in one terminal not affect a program already running in another terminal?
3. Which file makes limits apply automatically at login, and which PAM module enforces it?
4. In `limits.conf`, what does the `nproc` item cap, and what does `as` cap?
5. A developer says "I set `ulimit -n 100000` and it still fails at 30000 open files." Give two distinct causes.

---

## Exercise 6 — Who is logged in, and who was: `who`, `w`, `last`, `lastlog`

These read three different databases: `who`/`w` read `/var/run/utmp` (current sessions), `last` reads `/var/log/wtmp` (login/logout history), and `lastlog` reads `/var/log/lastlog` (each account's most recent login).

1. See current sessions and what they're doing:

   ```bash
   $ who
   root     tty1         2026-08-31 09:12
   student  pts/0        2026-08-31 12:01 (192.0.2.55)
   $ w
    12:40:31 up  3:28,  2 users,  load average: 0.10, 0.06, 0.01
   USER     TTY      FROM        LOGIN@   IDLE   JCPU   PCPU WHAT
   student  pts/0    192.0.2.55  12:01    0.00s  0.30s  0.02s w
   ```

   `w` adds idle time, CPU usage, and the current command versus `who`'s bare list.

2. Report just yourself and the run level:

   ```bash
   $ whoami
   student
   $ who -r        # current runlevel / systemd target transition
   $ who -b        # last system boot time
   ```

3. Review login history and reboots:

   ```bash
   $ last -a | head
   student  pts/0        Mon Aug 31 12:01   still logged in     192.0.2.55
   reboot   system boot  Mon Aug 31 09:10   still running       6.8.0-generic
   root     tty1         Mon Aug 31 09:12 - 09:40  (00:28)       0.0.0.0
   $ last -x | grep -E 'shutdown|reboot' | head
   ```

4. Investigate a specific account and failed logins:

   ```bash
   $ last student           # every session for one user
   # lastb | head           # BAD login attempts (from /var/log/btmp; root-only)
   ```

5. See the most-recent login per account, and spot accounts that have *never* logged in:

   ```bash
   $ lastlog
   Username     Port     From             Latest
   root         tty1                      Mon Aug 31 09:12:00 +0000 2026
   student      pts/0    192.0.2.55       Mon Aug 31 12:01:10 +0000 2026
   backup                                 **Never logged in**
   $ lastlog -b 30          # accounts with no login in the last 30 days
   ```

**Comprehension check**

1. Which file does `who` read, and which file does `last` read? Why does that make them answer different questions?
2. What three columns does `w` show that `who` (without flags) does not?
3. Where do *failed* login attempts appear, and which command reads them?
4. What does `lastlog` show that `last` cannot, and vice versa?
5. An account shows `**Never logged in**` in `lastlog` but you see it in `last`. Give a plausible explanation.

---

## Exercise 7 — Delegate privilege safely: `sudo`, `/etc/sudoers`, and `su`

`su` swaps identity by asking for the *target's* password (usually root's). `sudo` runs a command as another user according to a policy in `/etc/sudoers`, authenticating with the *caller's own* password, and it logs every invocation. Prefer `sudo` for delegation and auditability.

1. Contrast the two identity-switch tools:

   ```bash
   $ su -              # full login shell as root; needs ROOT's password
   $ su - alice        # become alice; needs ALICE's password (or root can skip it)
   $ sudo -i           # root login shell; needs YOUR OWN password, and a policy grant
   $ sudo -u alice id  # run one command as alice
   ```

2. **Always** edit the policy with `visudo`, which syntax-checks before saving (a broken `sudoers` can lock everyone out):

   ```bash
   # visudo
   # visudo -c            # just validate the current file
   /etc/sudoers: parsed OK
   ```

3. Grant a user full sudo via a drop-in (the modern, upgrade-safe location):

   ```bash
   # visudo -f /etc/sudoers.d/10-alice
   ```
   ```
   alice   ALL=(ALL:ALL) ALL
   ```

   The fields are `user  HOST=(RUNAS_USER:RUNAS_GROUP)  COMMANDS`.

4. Grant a *scoped, passwordless* privilege — the least-privilege pattern you actually want in production. Let a monitoring user restart only one service, no password:

   ```bash
   # visudo -f /etc/sudoers.d/20-monitor
   ```
   ```
   Cmnd_Alias SVC = /usr/bin/systemctl restart nginx, /usr/bin/systemctl status nginx
   monitor    ALL=(root) NOPASSWD: SVC
   ```

5. Test as the target user and read the audit trail:

   ```bash
   $ sudo -l                      # what am I allowed to run?
   User monitor may run the following commands on host:
       (root) NOPASSWD: /usr/bin/systemctl restart nginx, /usr/bin/systemctl status nginx
   $ sudo systemctl restart nginx # allowed
   $ sudo systemctl restart sshd  # denied
   Sorry, user monitor is not allowed to execute '/usr/bin/systemctl restart sshd' as root ...
   # journalctl -t sudo | tail    # every attempt is logged (also /var/log/auth.log or /var/log/secure)
   ```

6. Understand group-based grants. On Debian the `sudo` group, on RHEL the `wheel` group, is granted by a default line:

   ```bash
   # grep -E '%(sudo|wheel)' /etc/sudoers
   %sudo   ALL=(ALL:ALL) ALL
   # usermod -aG sudo alice       # add alice to the admin group (Debian/Ubuntu)
   ```

7. Clean up the lab grants:

   ```bash
   # rm /etc/sudoers.d/10-alice /etc/sudoers.d/20-monitor
   # visudo -c
   ```

**Comprehension check**

1. Whose password does `su -` ask for, and whose does `sudo` ask for? Why does that matter for auditing and for shared root credentials?
2. Why must you edit `sudoers` with `visudo` rather than a plain editor?
3. Decode the grant `monitor ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx` field by field.
4. What does `sudo -l` report, and why is it the first thing to run when you inherit an unfamiliar account?
5. On a RHEL host, which group membership typically confers sudo, and where is that mapping defined?
6. Why is a `Cmnd_Alias` restricting `systemctl restart nginx` weaker than it looks if the user can also edit the nginx unit file or run an editor as root?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1 — SUID/SGID audit

1. Lowercase `s` means the SUID bit **and** the owner's execute bit are both set (`rws`). Uppercase `S` means the SUID bit is set but the execute bit is **not** (`rwS`) — usually a mistake, since a non-executable SUID file does nothing useful and signals a misconfiguration.
2. `-perm -4000` matches any file where *at least* the SUID bit is set, regardless of the other 11 permission bits. `-perm 4755` matches only files whose mode is **exactly** `4755` — a stricter, rarely-what-you-want test. There is also `-perm /4000` ("any of these bits"), which for a single bit is equivalent to `-4000`.
3. `-xdev` (a.k.a. `-mount`) tells `find` not to descend into other filesystems. An auditor wants it so the scan stays on local disk and doesn't crawl `/proc`, `/sys`, network mounts, or bind mounts — faster, and it avoids double-counting and false positives.
4. `6755` = SUID (4000) + SGID (2000) + `rwxr-xr-x` (0755). So both the setuid and setgid bits are set. (`su` legitimately carries both.)
5. Removing the bit (`chmod u-s`) neutralizes the escalation risk immediately and reversibly while you investigate; deleting could destroy a *legitimate* system binary you misjudged, or wipe evidence needed for incident analysis.

### Exercise 2 — `fuser` / `lsof`

1. Without `-m`, the argument is a file/socket. With `-m`, `fuser` treats the argument as a **mount point (filesystem)** and reports every process with any file open on that filesystem — the form you need before `umount`.
2. `-n` disables host-name (DNS) resolution and `-P` disables port-name (`/etc/services`) resolution, so `lsof` prints raw IPs and numeric ports quickly and doesn't hang on slow reverse-DNS.
3. `fuser -vm /home` lists the processes holding the mount; `fuser -km /home` (add `-TERM`/`-KILL` to choose the signal) forcibly signals them. (`lsof +D /home` or `lsof /home` is the read-only equivalent for just listing.)
4. `fuser -u` appends the **owning username** of each process in parentheses to the PID listing, so you see who to contact/blame without a second `ps` lookup.
5. On production, `fuser -k` on a mount signals *every* process touching that filesystem at once — which can include critical daemons, sshd, or your own shell — potentially causing an outage or cutting off your access. Prefer identifying and stopping services gracefully first.

### Exercise 3 — `ss`/`netstat`/`nmap`

1. `ss`/`netstat` show the ground truth from inside, including loopback-only and process ownership; `nmap` shows only what is reachable across the network. Together they reveal both what is running and what is actually exposed — a service can be running yet firewalled, or bound only to loopback.
2. `0.0.0.0:5432` is reachable from any interface/network (remote exposure); `127.0.0.1:5432` is reachable only from the host itself (loopback), so no remote client can connect regardless of firewall — dramatically smaller attack surface.
3. `-n` (numeric). Auditors want it so output is unambiguous (raw IP:port), fast (no DNS/`/etc/services` lookups), and not spoofable by a poisoned resolver.
4. `-sS` crafts raw SYN packets directly, which requires `CAP_NET_RAW`/root. `-sT` uses the OS's normal `connect()` syscall (a full TCP handshake), which any user can do.
5. `filtered` means nmap got **no response** (or an ICMP unreachable) — typically a firewall is dropping the probe, so nmap can't tell if a service is there. `closed` means the host actively replied (RST) that nothing is listening — the port is reachable but has no service.

### Exercise 4 — passwords & aging

1. **Days since the Unix epoch (1970-01-01)** for last-change and expire; a **count of days** for the max/min/warn/inactive intervals.
2. `-E 2026-12-31` sets a hard **account** expiry — after that date the account is disabled entirely regardless of the password. `-M 90` sets the **password** maximum age — the user must *change* the password every 90 days but the account stays usable.
3. Password expiry is computed as `last-change + max`. Setting last-change to day 0 (1970) makes `0 + max` a date decades in the past, so the password is already expired and the user is forced to change it at next login.
4. `passwd -l` locks only the *password* by invalidating the hash — it does **not** block key-based SSH, so a pubkey user still logs in. `chage -E 0` expires the whole *account*, which PAM's account phase rejects, blocking **all** login methods including SSH keys.
5. `chage -l <user>` (list mode).

### Exercise 5 — limits

1. The soft limit is the currently enforced value; the hard limit is the ceiling the soft limit may be raised to. An unprivileged user can lower/raise the soft limit up to the hard limit and can only *lower* the hard limit; only root can raise the hard limit.
2. `ulimit` limits are per-process and inherited by children at fork/exec time. Changing a shell's limit affects only that shell and processes it starts afterwards — an already-running process in another terminal keeps the limits it inherited when it started.
3. `/etc/security/limits.conf` (plus drop-ins in `/etc/security/limits.d/`), enforced at login by the PAM module `pam_limits.so`.
4. `nproc` caps the maximum number of processes for the user; `as` caps the process **address space** (virtual memory, i.e. maximum memory it can map).
5. Two of: (a) the value exceeds the **hard** limit, so the soft-limit raise is refused/capped; (b) a **system-wide** kernel limit is hit — `fs.file-max` (sysctl) or the per-user `nofile` from `limits.conf`; (c) the process was started **before** the change and inherited the old limit; (d) a systemd service's `LimitNOFILE=` overrides shell `ulimit` entirely for daemons.

### Exercise 6 — who's logged in

1. `who` reads `/var/run/utmp` (the *current* sessions table); `last` reads `/var/log/wtmp` (the *historical* login/logout log). That's why `who` answers "who is on now" and `last` answers "who logged in and when, including past sessions and reboots."
2. `w` adds **IDLE** time, CPU columns (**JCPU/PCPU**), and **WHAT** (the current foreground command), plus a header with uptime and load average.
3. Failed login attempts are recorded in `/var/log/btmp`, read with `lastb` (root-only).
4. `lastlog` shows the single *most recent* login timestamp for **every** account (including ones that never logged in), reading `/var/log/lastlog`. `last` shows the full *history* of sessions (multiple per user) and reboots but doesn't enumerate never-logged-in accounts.
5. `lastlog` reads `/var/log/lastlog`, which can be sparse/reset, may not be updated for certain login types (e.g. some non-PAM or cron/su paths), or was truncated/rotated — so a session recorded in `wtmp` (seen by `last`) can be absent from `lastlog`. Clock changes or a login method that bypasses `pam_lastlog` also cause this.

### Exercise 7 — `sudo` / `su`

1. `su -` asks for the **target** account's password (typically root's shared password). `sudo` asks for the **caller's own** password. This matters because `sudo` avoids sharing the root password, ties each privileged action to a named human, and logs every command — far better accountability.
2. `visudo` locks the file against concurrent edits and, crucially, **syntax-checks** it before saving. A malformed `sudoers` is refused by `sudo` entirely, which can lock every administrator out of privilege; `visudo` prevents saving a broken file.
3. `monitor` = the user the rule applies to; `ALL=` = on all hosts; `(root)` = may run the command as user root; `NOPASSWD:` = without being prompted for a password; `/usr/bin/systemctl restart nginx` = the *only* command permitted (exact path and arguments).
4. `sudo -l` lists exactly which commands the current user may run via sudo (and as whom, with/without password). It's the first thing to run on an unfamiliar account because it reveals your actual privilege footprint without trial and error.
5. On RHEL/Fedora the **`wheel`** group typically confers sudo, defined by the `%wheel ALL=(ALL) ALL` line in `/etc/sudoers`.
6. Because the restriction only limits *which binary* runs, not what that access ultimately grants. If the user can edit the nginx unit file (or run any editor/`systemctl edit` as root), they can make "restart nginx" execute arbitrary commands as root via `ExecStart`/`ExecStartPre` — so the narrow-looking `Cmnd_Alias` is effectively full root. Least privilege must consider the *transitive* capability, not just the command string.

</details>