# LPIC-1 · Topic 110.2 — Setup Host Security

## Guided Exercises

> **Objective coverage (LPI 102-500, 110.2, weight 3):** shadow passwords and how they work; turning off network services not in use; the role of TCP wrappers.
> **Key files, terms and utilities:** `/etc/nologin`, `/etc/passwd`, `/etc/shadow`, `/etc/xinetd.d/`, `/etc/xinetd.conf`, `systemd.socket`, `/etc/inittab`, `/etc/init.d/`, `/etc/hosts.allow`, `/etc/hosts.deny`

---

### Lab environment and safety notes

These exercises modify authentication databases and stop network services. **Run them on a disposable VM or container, never on a machine you depend on.**

Requirements:

* A Linux system with `systemd` (Debian 12+, Ubuntu 22.04+, Rocky/AlmaLinux 9, openSUSE Leap 15+, Fedora 39+).
* `root` access via `sudo`.
* Two terminals open as `root`, or at least one root shell that stays open for the whole session. Several steps can lock you out of new logins; an already-open root shell is your escape hatch.
* Packages: `shadow-utils` / `passwd`, `iproute2`, `procps`, `lsof`. Optional: `tcpd` / `tcp_wrappers` (Debian/Ubuntu only on current releases), `xinetd`.

Take a snapshot before starting:

```bash
sudo tar czf /root/pre-lab-backup.tar.gz \
  /etc/passwd /etc/shadow /etc/group /etc/gshadow \
  /etc/hosts.allow /etc/hosts.deny 2>/dev/null
sudo ls -lh /root/pre-lab-backup.tar.gz
```

```
-rw-r--r--. 1 root root 3.1K Aug 31 10:02 /root/pre-lab-backup.tar.gz
```

---

## Exercise 1 — Anatomy of the shadow password suite

**Goal:** prove to yourself *why* shadow passwords exist, by looking at the permissions and the field layout of both databases.

1. Create two test users. One gets a password, the other does not.

   ```bash
   sudo useradd -m -c "Shadow lab user" alice
   sudo useradd -m -c "Never logs in" svcbot
   echo 'alice:Lab-Passw0rd!' | sudo chpasswd
   ```

2. Look at how `/etc/passwd` and `/etc/shadow` differ in ownership and mode.

   ```bash
   ls -l /etc/passwd /etc/shadow
   ```

   ```
   -rw-r--r--. 1 root root  2841 Aug 31 10:04 /etc/passwd
   ----------. 1 root root  1523 Aug 31 10:04 /etc/shadow
   ```

   On Debian/Ubuntu you will see `-rw-r----- 1 root shadow` instead — mode `0640`, group `shadow`.

3. Compare the two records for `alice`.

   ```bash
   grep '^alice:' /etc/passwd
   sudo grep '^alice:' /etc/shadow
   ```

   ```
   alice:x:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```
   ```
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:0:99999:7:::
   ```

4. Confirm that the `x` in the second field of `/etc/passwd` is a *placeholder*, not a hash, by counting the fields in each file.

   ```bash
   awk -F: '$1=="alice"{print NF" fields in passwd"}' /etc/passwd
   sudo awk -F: '$1=="alice"{print NF" fields in shadow"}' /etc/shadow
   ```

   ```
   7 fields in passwd
   9 fields in shadow
   ```

5. Decode the third field of the shadow record — it is *not* a Unix timestamp.

   ```bash
   sudo awk -F: '$1=="alice"{print $3}' /etc/shadow
   date -u -d "1970-01-01 UTC + 20696 days" +%F
   echo "today is day $(( $(date -u +%s) / 86400 ))"
   ```

   ```
   20696
   2026-08-31
   today is day 20696
   ```

6. Inspect the account that never received a password.

   ```bash
   sudo grep '^svcbot:' /etc/shadow
   sudo passwd -S svcbot
   sudo passwd -S alice
   ```

   ```
   svcbot:!:20696:0:99999:7:::
   svcbot L 2026-08-31 0 99999 7 -1
   alice P 2026-08-31 0 99999 7 -1
   ```

7. Look at the hash prefix to identify the algorithm in use, and at the system-wide default.

   ```bash
   sudo awk -F: '$1=="alice"{split($2,a,"$"); print "prefix: $"a[2]"$"}' /etc/shadow
   grep -E '^\s*(ENCRYPT_METHOD|SHA_CRYPT|YESCRYPT)' /etc/login.defs
   ```

   ```
   prefix: $y$
   ENCRYPT_METHOD YESCRYPT
   ```

   On RHEL-family systems you will typically see `$6$` and `ENCRYPT_METHOD SHA512`.

8. Run the consistency checkers.

   ```bash
   sudo pwck -r
   sudo grpck -r
   echo "exit status: $?"
   ```

   ```
   user 'lp': directory '/var/spool/lpd' does not exist
   pwck: no changes
   exit status: 0
   ```

**Check your understanding**

* **Q1.1** `/etc/passwd` is world-readable and `/etc/shadow` is not. Name two pieces of information that *must* stay world-readable, and explain what breaks if you `chmod 600 /etc/passwd`.
* **Q1.2** List the nine fields of `/etc/shadow` in order, with the unit or meaning of each.
* **Q1.3** In the shadow password field, what is the difference in effect between `!`, `!!`, `*`, and an empty field?
* **Q1.4** `passwd -S alice` printed `P` and `passwd -S svcbot` printed `L`. What third letter can appear there, and why is it dangerous?
* **Q1.5** The date field held `20696`, not `1788148800`. What is the epoch and unit of that field, and what does a value of `0` mean?

---

## Exercise 2 — Migrating between shadowed and unshadowed databases

**Goal:** understand `pwconv` / `pwunconv` by watching a hash move between files. **Do this in a container or throwaway VM.**

1. Take a fresh backup you can restore from a root shell without any authentication.

   ```bash
   sudo cp -a /etc/passwd /root/passwd.bak
   sudo cp -a /etc/shadow /root/shadow.bak
   ```

2. Un-shadow the system and observe what happens to the hashes.

   ```bash
   sudo pwunconv
   ls -l /etc/shadow
   grep '^alice:' /etc/passwd
   ```

   ```
   ls: cannot access '/etc/shadow': No such file or directory
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```

3. Confirm the exposure. As an **unprivileged** user, read the hash you were never supposed to see.

   ```bash
   su - svcbot -s /bin/bash -c "grep '^alice:' /etc/passwd | cut -d: -f2"
   ```

   ```
   $y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...
   ```

4. Re-shadow immediately and verify the aging metadata was rebuilt.

   ```bash
   sudo pwconv
   ls -l /etc/shadow
   sudo grep '^alice:' /etc/shadow
   grep '^alice:' /etc/passwd
   ```

   ```
   ----------. 1 root root 1523 Aug 31 10:19 /etc/shadow
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:0:99999:7:::
   alice:x:1001:1001:Shadow lab user:/home/alice:/bin/bash
   ```

5. Do the same for groups and note the analogous file.

   ```bash
   sudo grpconv
   ls -l /etc/gshadow
   sudo grep -c . /etc/gshadow
   ```

   ```
   ----------. 1 root root 923 Aug 31 10:20 /etc/gshadow
   62
   ```

**Check your understanding**

* **Q2.1** After `pwunconv`, which two shadow fields survive in `/etc/passwd`, and which seven are lost?
* **Q2.2** Where do `pwconv` and `pwunconv` get the default values for `PASS_MIN_DAYS`, `PASS_MAX_DAYS` and `PASS_WARN_AGE` when rebuilding `/etc/shadow`?
* **Q2.3** Why must you never edit `/etc/passwd` or `/etc/shadow` with a plain `vi /etc/shadow`, and which two commands should you use instead?
* **Q2.4** `/etc/gshadow` stores a group password. Under what circumstance is it actually used, and which command consumes it?

---

## Exercise 3 — Password aging and account locking as a hardening control

**Goal:** use `chage`, `usermod` and `passwd` to enforce lifecycle policy, and distinguish *locked* from *expired* from *no-login shell*.

1. Read `alice`'s current aging policy.

   ```bash
   sudo chage -l alice
   ```

   ```
   Last password change                                    : Aug 31, 2026
   Password expires                                        : never
   Password inactive                                       : never
   Account expires                                         : never
   Minimum number of days between password change          : 0
   Maximum number of days between password change          : 99999
   Number of days of warning before password expires       : 7
   ```

2. Apply a production-style policy: minimum 1 day, maximum 90 days, 14 days of warning, 7 days of inactivity grace, and a hard account expiry.

   ```bash
   sudo chage -m 1 -M 90 -W 14 -I 7 -E 2027-01-31 alice
   sudo chage -l alice
   ```

   ```
   Last password change                                    : Aug 31, 2026
   Password expires                                        : Nov 29, 2026
   Password inactive                                       : Dec 06, 2026
   Account expires                                         : Jan 31, 2027
   Minimum number of days between password change          : 1
   Maximum number of days between password change          : 90
   Number of days of warning before password expires       : 14
   Number of days of warning before password expires       : 14
   ```

   ```bash
   sudo awk -F: '$1=="alice"{print}' /etc/shadow
   ```

   ```
   alice:$y$j9T$3rW0hQ2mB.QkzX8oS1fV0/$KcNQ3s...:20696:1:90:14:7:20849:
   ```

3. Force a password change at next login without knowing the current password.

   ```bash
   sudo chage -d 0 alice
   sudo awk -F: '$1=="alice"{print $3}' /etc/shadow
   ```

   ```
   0
   ```

   Undo it so the rest of the lab still works:

   ```bash
   sudo chage -d $(date -u +%F) alice
   ```

4. Lock the account and inspect the mechanism.

   ```bash
   sudo usermod -L alice          # equivalent: passwd -l alice
   sudo awk -F: '$1=="alice"{print substr($2,1,4)}' /etc/shadow
   sudo passwd -S alice
   ```

   ```
   !$y$
   alice L 2026-08-31 1 90 14 7
   ```

5. Prove that locking the *password* does not disable *all* access paths.

   ```bash
   sudo mkdir -p /home/alice/.ssh
   sudo -u alice ssh-keygen -t ed25519 -N '' -f /home/alice/.ssh/id_ed25519 >/dev/null
   sudo -u alice sh -c 'cat /home/alice/.ssh/id_ed25519.pub >> /home/alice/.ssh/authorized_keys'
   sudo -u alice id
   ```

   ```
   uid=1001(alice) gid=1001(alice) groups=1001(alice)
   ```

   The account is "locked", yet `sudo -u alice`, `su - alice` from root, cron jobs and SSH public-key authentication all still work.

6. Apply the two controls that *do* stop those paths, and compare them.

   ```bash
   sudo usermod -e 1 alice                  # account expiry: day 1 = 1970-01-02
   sudo su - alice
   ```

   ```
   Your account has expired; please contact your system administrator
   su: User account has expired
   ```

   ```bash
   sudo usermod -s /usr/sbin/nologin svcbot   # /sbin/nologin on RHEL-family
   sudo su - svcbot
   ```

   ```
   This account is currently not available.
   ```

7. Restore `alice` for later exercises.

   ```bash
   sudo usermod -U alice
   sudo chage -E -1 alice
   sudo passwd -S alice
   ```

   ```
   alice P 2026-08-31 1 90 14 7
   ```

8. Audit the whole system for accounts that can log in with a password.

   ```bash
   sudo awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow
   awk -F: '$3 >= 1000 && $3 < 65534 {print $1" -> "$7}' /etc/passwd
   awk -F: '$2 == "" {print "EMPTY PASSWORD FIELD: "$1}' /etc/shadow
   ```

   ```
   root
   alice
   alice -> /bin/bash
   svcbot -> /usr/sbin/nologin
   ```

**Check your understanding**

* **Q3.1** What exactly does `usermod -L` write into `/etc/shadow`, and why does that single character make every password fail?
* **Q3.2** Give three access paths that survive `passwd -l`. Which command closes all of them at once?
* **Q3.3** `chage -d 0 alice` sets the last-change field to zero. What is the user-visible effect at next login, and why is `0` not interpreted as "1 January 1970"?
* **Q3.4** Explain the difference between the `-M` (max) and `-I` (inactive) fields when a password expires.
* **Q3.5** `/usr/sbin/nologin` and `/bin/false` both prevent an interactive shell. What does `nologin` do that `false` does not, and which file customises it?

---

## Exercise 4 — Discovering every network service that is listening

**Goal:** build the inventory before deciding what to turn off. You cannot disable what you have not enumerated.

1. List every listening TCP and UDP socket with the owning process.

   ```bash
   sudo ss -tulpen
   ```

   ```
   Netid State  Recv-Q Send-Q  Local Address:Port  Peer Address:Port Process
   udp   UNCONN 0      0       127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=680,fd=13)) uid:193 ino:18994
   udp   UNCONN 0      0             0.0.0.0:68         0.0.0.0:*     users:(("dhclient",pid=712,fd=6))         uid:0   ino:19240
   tcp   LISTEN 0      4096    127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=680,fd=14)) uid:193 ino:18995
   tcp   LISTEN 0      128           0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=901,fd=3))            uid:0   ino:20115
   tcp   LISTEN 0      511                 *:80               *:*     users:(("nginx",pid=1042,fd=6))          uid:0   ino:21330
   tcp   LISTEN 0      4096          0.0.0.0:111        0.0.0.0:*     users:(("rpcbind",pid=655,fd=4))         uid:0   ino:18321
   tcp   LISTEN 0      100         127.0.0.1:25         0.0.0.0:*     users:(("master",pid=1180,fd=13))        uid:0   ino:22004
   ```

   Decode the flags: `-t` TCP, `-u` UDP, `-l` listening only, `-p` process, `-e` extended (uid, inode), `-n` numeric ports.

2. Cross-check with `lsof` and with the legacy `netstat` command the exam still mentions.

   ```bash
   sudo lsof -nP -i -sTCP:LISTEN
   sudo netstat -tulpn 2>/dev/null | head -n 8
   ```

   ```
   COMMAND   PID  USER  FD  TYPE DEVICE SIZE/OFF NODE NAME
   rpcbind   655  rpc    4u IPv4  18321      0t0  TCP *:111 (LISTEN)
   sshd      901  root   3u IPv4  20115      0t0  TCP *:22 (LISTEN)
   nginx    1042  root   6u IPv6  21330      0t0  TCP *:80 (LISTEN)
   master   1180  root  13u IPv4  22004      0t0  TCP 127.0.0.1:25 (LISTEN)
   ```

3. Translate a port number to its conventional service name.

   ```bash
   grep -wE '^(ssh|smtp|sunrpc|http)' /etc/services
   getent services 111
   ```

   ```
   ssh    22/tcp
   smtp   25/tcp
   sunrpc 111/tcp   portmapper rpcbind
   http   80/tcp    www www-http
   sunrpc 111/tcp
   ```

4. Map each listening socket back to the systemd unit that owns it.

   ```bash
   for p in 655 901 1042 1180; do
     printf '%-6s %s\n' "$p" "$(ps -o unit= -p $p)"
   done
   ```

   ```
   655    rpcbind.service
   901    sshd.service
   1042   nginx.service
   1180   postfix.service
   ```

5. List enabled units and socket-activated units separately — a *stopped* service can still be reachable.

   ```bash
   systemctl list-unit-files --type=service --state=enabled --no-pager
   systemctl list-sockets --no-pager
   ```

   ```
   UNIT FILE                  STATE   PRESET
   nginx.service              enabled disabled
   rpcbind.service            enabled enabled
   sshd.service               enabled enabled
   ...

   LISTEN            UNIT                        ACTIVATES
   /run/dbus/system_bus_socket dbus.socket        dbus.service
   /run/rpcbind.sock rpcbind.socket               rpcbind.service
   [::]:22           sshd.socket                  sshd.service
   ```

6. Distinguish "listening on loopback" from "listening on the world".

   ```bash
   sudo ss -tlpn | awk 'NR>1 {print $4"\t"$6}' | sed 's/users:(//;s/)$//'
   ```

   ```
   127.0.0.53%lo:53   "systemd-resolve",pid=680,fd=14
   0.0.0.0:22         "sshd",pid=901,fd=3
   *:80               "nginx",pid=1042,fd=6
   0.0.0.0:111        "rpcbind",pid=655,fd=4
   127.0.0.1:25       "master",pid=1180,fd=13
   ```

**Check your understanding**

* **Q4.1** Why must `ss -tulpen` be run as `root` to be useful? What is missing from the output when a normal user runs it?
* **Q4.2** In the output above, which two listeners are *not* reachable from another host, and how can you tell from the `Local Address:Port` column alone?
* **Q4.3** `systemctl list-sockets` showed `sshd.socket` activating `sshd.service`. If you run `systemctl stop sshd.service` and nothing else, is TCP 22 still reachable? Explain.
* **Q4.4** `/etc/services` maps 111/tcp to `sunrpc`. Does editing that file change which port `rpcbind` binds to? Why or why not?
* **Q4.5** A port shows `LISTEN` with an empty `Process` column even under `sudo`. Give one plausible explanation.

---

## Exercise 5 — Turning off services you do not need

**Goal:** the difference between `stop`, `disable`, `mask`, and removing the package — and the socket-unit trap.

1. Pick a genuinely unnecessary service. On most systems `rpcbind` is a good candidate unless you use NFS.

   ```bash
   systemctl is-active rpcbind.service
   systemctl is-enabled rpcbind.service
   systemctl is-enabled rpcbind.socket
   ```

   ```
   active
   enabled
   enabled
   ```

2. Stop it and immediately re-test the port.

   ```bash
   sudo systemctl stop rpcbind.service
   sudo ss -tlpn | grep ':111' || echo "111 closed"
   ```

   ```
   tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("systemd",pid=1,fd=42))
   ```

   The port is *still open* — `systemd` (PID 1) holds it on behalf of `rpcbind.socket`.

3. Stop and disable the socket unit as well, then re-test.

   ```bash
   sudo systemctl disable --now rpcbind.socket rpcbind.service
   sudo ss -tlpn | grep ':111' || echo "111 closed"
   ```

   ```
   Removed "/etc/systemd/system/sockets.target.wants/rpcbind.socket".
   Removed "/etc/systemd/system/multi-user.target.wants/rpcbind.service".
   111 closed
   ```

4. Verify it does not come back across a reboot-equivalent state change.

   ```bash
   systemctl is-enabled rpcbind.service rpcbind.socket
   ```

   ```
   disabled
   disabled
   ```

5. Make the service impossible to start, even as a dependency of something else.

   ```bash
   sudo systemctl mask rpcbind.socket
   ls -l /etc/systemd/system/rpcbind.socket
   sudo systemctl start rpcbind.socket
   ```

   ```
   lrwxrwxrwx. 1 root root 9 Aug 31 10:41 /etc/systemd/system/rpcbind.socket -> /dev/null
   Failed to start rpcbind.socket: Unit rpcbind.socket is masked.
   ```

6. Read a socket unit to see where the port number actually comes from.

   ```bash
   systemctl cat rpcbind.socket | head -n 20
   ```

   ```
   # /usr/lib/systemd/system/rpcbind.socket
   [Unit]
   Description=RPCbind Server Activation Socket

   [Socket]
   ListenStream=/run/rpcbind.sock
   ListenStream=0.0.0.0:111
   ListenDatagram=0.0.0.0:111
   BindIPv6Only=ipv6-only

   [Install]
   WantedBy=sockets.target
   ```

7. Restrict a service you *do* need instead of removing it. Bind `sshd` to one address with a drop-in override rather than editing the shipped unit.

   ```bash
   sudo systemctl edit --force sshd.socket
   ```

   ```ini
   ### /etc/systemd/system/sshd.socket.d/override.conf
   [Socket]
   ListenStream=
   ListenStream=192.168.178.20:22
   ```

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart sshd.socket
   sudo ss -tlpn | grep ':22'
   ```

   ```
   tcp LISTEN 0 4096 192.168.178.20:22 0.0.0.0:* users:(("systemd",pid=1,fd=44))
   ```

8. Inspect the SysV-era mechanisms the objective still lists, so you can read a legacy box.

   ```bash
   ls /etc/init.d/ 2>/dev/null | head
   ls /etc/rc3.d/ 2>/dev/null | head -n 5
   cat /etc/inittab 2>/dev/null || echo "/etc/inittab absent — systemd system"
   systemctl get-default
   ```

   ```
   README
   S01rsyslog
   S02ssh
   /etc/inittab absent — systemd system
   multi-user.target
   ```

9. Undo the changes that would affect later exercises.

   ```bash
   sudo systemctl unmask rpcbind.socket
   sudo rm -f /etc/systemd/system/sshd.socket.d/override.conf
   sudo systemctl daemon-reload
   ```

**Check your understanding**

* **Q5.1** Order these from weakest to strongest, and state precisely what each one prevents: `systemctl stop`, `systemctl disable`, `systemctl mask`, package removal.
* **Q5.2** In step 2, the port stayed open after stopping the service and the process shown was `systemd` with PID 1. Explain the mechanism in one sentence.
* **Q5.3** Why does `systemctl disable` alone leave a currently-running service running, and which flag fixes that in one command?
* **Q5.4** You masked a unit. `systemctl cat` still shows the original file content. Where does the mask live, and what is it a symlink to?
* **Q5.5** On a SysV-init system, what is the equivalent of `systemctl disable sshd`, expressed in terms of `/etc/init.d/` and the runlevel directories?
* **Q5.6** `systemctl get-default` returned `multi-user.target`. Which `/etc/inittab` directive did that replace, and what was the corresponding numeric runlevel?

---

## Exercise 6 — The legacy super-server: `inetd` and `xinetd`

**Goal:** read and reason about super-server configuration. Most current distributions no longer install `xinetd`; the exam still tests the file layout, so the exercise is written to work with or without the package.

1. Check whether a super-server exists on your system.

   ```bash
   command -v xinetd inetd 2>/dev/null || echo "no super-server installed"
   ls -d /etc/xinetd.conf /etc/xinetd.d /etc/inetd.conf 2>/dev/null || echo "no super-server config"
   ```

   ```
   no super-server installed
   no super-server config
   ```

2. Reconstruct the main configuration file and read it as documentation.

   ```bash
   sudo mkdir -p /etc/xinetd.d
   sudo tee /etc/xinetd.conf >/dev/null <<'EOF'
   defaults
   {
       instances      = 60
       log_type       = SYSLOG authpriv
       log_on_success = HOST PID
       log_on_failure = HOST
       cps            = 25 30
       per_source     = 10
   }

   includedir /etc/xinetd.d
   EOF
   sudo cat /etc/xinetd.conf
   ```

3. Write a per-service file that is deliberately disabled and access-restricted.

   ```bash
   sudo tee /etc/xinetd.d/telnet >/dev/null <<'EOF'
   service telnet
   {
       disable         = yes
       socket_type     = stream
       protocol        = tcp
       wait            = no
       user            = root
       server          = /usr/sbin/in.telnetd
       only_from       = 192.168.178.0/24
       no_access       = 192.168.178.99
       access_times    = 08:00-18:00
       bind            = 192.168.178.20
       log_on_failure += USERID
   }
   EOF
   sudo cat /etc/xinetd.d/telnet
   ```

4. Reason about each directive without running the daemon.

   ```bash
   grep -E 'disable|only_from|no_access|access_times|bind|wait|instances|cps|per_source' \
     /etc/xinetd.conf /etc/xinetd.d/telnet
   ```

   ```
   /etc/xinetd.conf:    instances      = 60
   /etc/xinetd.conf:    cps            = 25 30
   /etc/xinetd.conf:    per_source     = 10
   /etc/xinetd.d/telnet:    disable         = yes
   /etc/xinetd.d/telnet:    only_from       = 192.168.178.0/24
   /etc/xinetd.d/telnet:    no_access       = 192.168.178.99
   /etc/xinetd.d/telnet:    access_times    = 08:00-18:00
   /etc/xinetd.d/telnet:    bind            = 192.168.178.20
   ```

5. Compare with the older single-file `inetd` syntax.

   ```bash
   sudo tee /etc/inetd.conf.example >/dev/null <<'EOF'
   # <service> <socket> <proto> <flags> <user> <server_path>      <args>
   ftp        stream    tcp     nowait  root   /usr/sbin/tcpd     in.ftpd -l -a
   telnet     stream    tcp     nowait  root   /usr/sbin/tcpd     in.telnetd
   #tftp      dgram     udp     wait    root   /usr/sbin/tcpd     in.tftpd -s /srv/tftp
   EOF
   awk '!/^#/ && NF {print $1"\t"$4"\t"$6"\t"$7}' /etc/inetd.conf.example
   ```

   ```
   ftp     nowait  /usr/sbin/tcpd  in.ftpd
   telnet  nowait  /usr/sbin/tcpd  in.ftpd
   ```

6. Note how a running `xinetd` is reloaded (do not run this if the daemon is absent).

   ```bash
   # Soft reconfigure: re-read config, keep existing connections
   # sudo kill -HUP $(pidof xinetd)
   # Hard reconfigure: also kill running child servers
   # sudo kill -USR2 $(pidof xinetd)
   echo "SIGHUP = reconfigure; SIGUSR2 = hard reconfigure; SIGTERM = quit"
   ```

7. Clean up the reconstructed files.

   ```bash
   sudo rm -f /etc/xinetd.conf /etc/xinetd.d/telnet /etc/inetd.conf.example
   sudo rmdir /etc/xinetd.d 2>/dev/null
   ```

**Check your understanding**

* **Q6.1** What problem was the super-server designed to solve, and what is its modern systemd equivalent?
* **Q6.2** In `/etc/xinetd.d/telnet`, what is the effect of `disable = yes` versus deleting the file? Which is preferable for an audited system?
* **Q6.3** `only_from` and `no_access` both appear. Which one wins when an address matches both, and why?
* **Q6.4** Explain `wait = no` for a `stream` service and `wait = yes` for a `dgram` service. What would break if you swapped them?
* **Q6.5** In `/etc/inetd.conf`, the server field is `/usr/sbin/tcpd` and the real daemon appears in the arguments. What is `tcpd` doing there?
* **Q6.6** `cps = 25 30` in the `defaults` block. Interpret both numbers and name the attack class it mitigates.

---

## Exercise 7 — TCP wrappers: `/etc/hosts.allow` and `/etc/hosts.deny`

**Goal:** determine whether a binary is wrapper-aware, write correct rules, and test them *without* locking yourself out.

1. Determine whether TCP wrappers exist at all on this system.

   ```bash
   ls -l /etc/hosts.allow /etc/hosts.deny 2>/dev/null
   ls -l /lib/*/libwrap.so* /usr/lib64/libwrap.so* 2>/dev/null
   command -v tcpdchk tcpdmatch 2>/dev/null || echo "tcpd utilities not installed"
   ```

   Debian/Ubuntu:
   ```
   -rw-r--r-- 1 root root 411 Aug 31 10:55 /etc/hosts.allow
   -rw-r--r-- 1 root root 711 Aug 31 10:55 /etc/hosts.deny
   -rw-r--r-- 1 root root 42280 /lib/x86_64-linux-gnu/libwrap.so.0.7.6
   ```
   Fedora / RHEL 8+:
   ```
   ls: cannot access '/etc/hosts.allow': No such file or directory
   tcpd utilities not installed
   ```

2. Test whether a specific daemon is actually linked against `libwrap`. **This is the decisive check** — the files are inert for any binary that does not link it.

   ```bash
   ldd "$(command -v sshd || echo /usr/sbin/sshd)" | grep -i libwrap || echo "sshd: NOT wrapper-aware"
   ldd /usr/sbin/rpcbind 2>/dev/null | grep -i libwrap || echo "rpcbind: NOT wrapper-aware"
   ```

   ```
   sshd: NOT wrapper-aware
   rpcbind: NOT wrapper-aware
   ```

   OpenSSH removed `libwrap` support in version 6.7 (2014). Verify your version:

   ```bash
   sshd -V 2>&1 | head -n 1 || ssh -V
   ```

   ```
   OpenSSH_9.6p1, OpenSSL 3.0.13 30 Jan 2024
   ```

3. Write the classic default-deny pair. Order matters: create the `allow` rules **first**.

   ```bash
   sudo tee /etc/hosts.allow >/dev/null <<'EOF'
   # <daemon list> : <client list> [: <shell command>]
   sshd, in.telnetd : 192.168.178.0/255.255.255.0
   vsftpd           : .example.com EXCEPT ftp-guest.example.com
   ALL              : LOCAL
   EOF

   sudo tee /etc/hosts.deny >/dev/null <<'EOF'
   ALL : ALL : spawn /bin/echo "$(date) denied %d from %h (%a)" >> /var/log/tcpwrap.log
   EOF

   sudo cat /etc/hosts.allow /etc/hosts.deny
   ```

4. Check the syntax with the wrapper's own linter (Debian/Ubuntu, package `tcpd`).

   ```bash
   sudo tcpdchk -v
   ```

   ```
   Using network configuration file: /etc/inetd.conf

   >>> Rule /etc/hosts.allow line 2:
   daemons:  sshd in.telnetd
   clients:  192.168.178.0/255.255.255.0
   access:   granted

   >>> Rule /etc/hosts.deny line 1:
   daemons:  ALL
   clients:  ALL
   option:   spawn /bin/echo ...
   access:   denied
   ```

5. Simulate a decision for a specific daemon/client pair — no packets required.

   ```bash
   tcpdmatch sshd 192.168.178.50
   tcpdmatch sshd 203.0.113.9
   tcpdmatch vsftpd ftp-guest.example.com
   ```

   ```
   client:   address 192.168.178.50
   server:   process sshd
   access:   granted

   client:   address 203.0.113.9
   server:   process sshd
   access:   denied

   client:   hostname ftp-guest.example.com
   server:   process vsftpd
   access:   denied
   ```

6. Trace the evaluation order deliberately by adding a contradictory rule.

   ```bash
   printf 'sshd : 203.0.113.9\n' | sudo tee -a /etc/hosts.allow >/dev/null
   tcpdmatch sshd 203.0.113.9
   ```

   ```
   access:   granted
   ```

   `hosts.allow` was consulted first and matched, so `hosts.deny` was never reached.

7. Learn the address-pattern forms by testing each.

   ```bash
   for pat in '192.168.178.' '192.168.178.0/24' '192.168.178.0/255.255.255.0' '.example.com' 'LOCAL' 'PARANOID'; do
     printf '%-32s ' "$pat"
     echo "sshd : $pat" | sudo tee /tmp/pattern-test >/dev/null && echo "syntax ok"
   done
   ```

   ```
   192.168.178.                     syntax ok
   192.168.178.0/24                 syntax ok
   192.168.178.0/255.255.255.0      syntax ok
   .example.com                     syntax ok
   LOCAL                            syntax ok
   PARANOID                         syntax ok
   ```

   Note: the `/24` prefix-length form is supported by recent `libwrap` builds; the netmask form `0/255.255.255.0` is the portable, exam-correct one.

8. Restore the originals.

   ```bash
   sudo tar xzf /root/pre-lab-backup.tar.gz -C / etc/hosts.allow etc/hosts.deny 2>/dev/null \
     || sudo rm -f /etc/hosts.allow /etc/hosts.deny
   ```

**Check your understanding**

* **Q7.1** State the full three-step evaluation algorithm of TCP wrappers, including what happens when neither file matches.
* **Q7.2** `ldd $(which sshd)` printed nothing for `libwrap`. What does that mean for the two rules you wrote for `sshd`, and what should you use instead on a current system?
* **Q7.3** Which name does the daemon list match — the path in `/etc/inetd.conf`, the process name, or the systemd unit? Why does the difference matter for `in.telnetd` versus `telnetd`?
* **Q7.4** Explain `LOCAL`, `KNOWN`, `UNKNOWN` and `PARANOID`. Which two depend on working reverse DNS, and what is the operational risk of relying on them?
* **Q7.5** Write a single line that denies everything except the 10.0.0.0/8 network, using only `/etc/hosts.deny`. Then explain why the two-file form is still preferred.
* **Q7.6** What is the difference between `spawn` and `twist` in the optional third field?

---

## Exercise 8 — `/etc/nologin`: blocking logins during maintenance

**Goal:** use the standard maintenance lock, understand that root is exempt, and find where PAM enforces it.

1. Create the lock file with an operator-facing message.

   ```bash
   sudo tee /etc/nologin >/dev/null <<'EOF'
   System is down for scheduled maintenance until 12:00 UTC.
   Contact ops@example.com for emergencies.
   EOF
   sudo chmod 644 /etc/nologin
   ```

2. Attempt a non-root login and observe the message.

   ```bash
   sudo login -f alice < /dev/null
   ```

   ```
   System is down for scheduled maintenance until 12:00 UTC.
   Contact ops@example.com for emergencies.
   ```

3. Verify root is still admitted.

   ```bash
   sudo login -f root < /dev/null && echo "root login permitted"
   ```

   ```
   root login permitted
   ```

4. Find the PAM module that enforces this, and see which services include it.

   ```bash
   grep -rl pam_nologin /etc/pam.d/
   grep -h pam_nologin /etc/pam.d/* | sort -u
   ```

   ```
   /etc/pam.d/login
   /etc/pam.d/sshd
   /etc/pam.d/postlogin
   account required pam_nologin.so
   auth  required pam_nologin.so
   ```

5. Note the second file that PAM consults, and the systemd unit that manages it.

   ```bash
   ls -l /run/nologin 2>/dev/null || echo "/run/nologin absent"
   systemctl cat systemd-user-sessions.service | grep -A3 '\[Service\]'
   man 8 pam_nologin | grep -A4 'nologin file'
   ```

   ```
   /run/nologin absent
   [Service]
   Type=oneshot
   RemainAfterExit=yes
   ExecStart=/usr/lib/systemd/systemd-user-sessions start
   ExecStop=/usr/lib/systemd/systemd-user-sessions stop
   ```

6. Prove that `/etc/nologin` does not stop everything.

   ```bash
   sudo -u alice id            # sudo does not include pam_nologin in most defaults
   sudo crontab -u alice -l 2>/dev/null || echo "no crontab for alice"
   sudo systemctl is-active cron 2>/dev/null || systemctl is-active crond
   ```

   ```
   uid=1001(alice) gid=1001(alice) groups=1001(alice)
   no crontab for alice
   active
   ```

7. Release the lock — and make releasing it part of your procedure, not an afterthought.

   ```bash
   sudo rm -f /etc/nologin
   sudo login -f alice < /dev/null && echo "logins restored"
   ```

   ```
   logins restored
   ```

**Check your understanding**

* **Q8.1** Which user is exempt from `/etc/nologin`, and where is that exemption implemented — in `login`, in PAM, or in the kernel?
* **Q8.2** PAM checks two paths. Name both, state the order, and explain why a systemd system prefers the one under `/run`.
* **Q8.3** `/etc/nologin` (the file) and `/usr/sbin/nologin` (the shell) have confusingly similar names. State the purpose of each and the third related file, `/etc/nologin.txt`.
* **Q8.4** Name two access paths that `/etc/nologin` does **not** block, and give one additional control for each.
* **Q8.5** After a `shutdown -h +30`, users report they cannot log in even though the machine is still up. What happened, and how do you cancel it?

---

## Exercise 9 — Consolidation: a repeatable host-security audit

**Goal:** turn everything above into one script you can run before and after hardening.

1. Write the audit script.

   ```bash
   sudo tee /usr/local/sbin/host-security-audit >/dev/null <<'EOF'
   #!/bin/bash
   # Minimal LPIC-1 110.2 host security audit. Read-only; prints findings.
   set -u

   echo "=== 1. Shadow suite ==="
   [ -f /etc/shadow ] && echo "OK   /etc/shadow present" || echo "FAIL passwords are not shadowed"
   stat -c '%a %U:%G %n' /etc/passwd /etc/shadow
   awk -F: '$2 == "" {print "FAIL empty password: "$1}' /etc/shadow
   awk -F: '$3 == 0 && $1 != "root" {print "WARN extra uid-0 account: "$1}' /etc/passwd

   echo
   echo "=== 2. Password aging on human accounts ==="
   awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | while read -r u; do
     max=$(awk -F: -v u="$u" '$1==u{print $5}' /etc/shadow)
     [ "${max:-99999}" -ge 99999 ] && echo "WARN $u: password never expires"
   done

   echo
   echo "=== 3. Listening sockets ==="
   ss -tulpnH | awk '{print $1, $5, $7}'

   echo
   echo "=== 4. Externally reachable listeners ==="
   ss -tlpnH | awk '$4 !~ /^(127\.|\[::1\])/ {print "REVIEW "$4"  "$6}'

   echo
   echo "=== 5. Enabled units and socket activation ==="
   systemctl list-unit-files --type=service --state=enabled --no-legend | wc -l | \
     xargs printf 'INFO %s enabled service units\n'
   systemctl list-sockets --no-legend --no-pager | wc -l | \
     xargs printf 'INFO %s active socket units\n'

   echo
   echo "=== 6. Super-server ==="
   [ -d /etc/xinetd.d ] && grep -L 'disable\s*=\s*yes' /etc/xinetd.d/* 2>/dev/null \
     | sed 's/^/WARN enabled xinetd service: /' || echo "OK   no xinetd configuration"

   echo
   echo "=== 7. TCP wrappers ==="
   if [ -f /etc/hosts.deny ]; then
     grep -q '^ALL\s*:\s*ALL' /etc/hosts.deny && echo "OK   default-deny present" \
       || echo "WARN /etc/hosts.deny has no ALL:ALL default"
   else
     echo "INFO tcp_wrappers not configured on this system"
   fi

   echo
   echo "=== 8. Maintenance lock ==="
   for f in /etc/nologin /run/nologin; do
     [ -f "$f" ] && echo "WARN $f present — non-root logins are blocked"
   done
   exit 0
   EOF
   sudo chmod 750 /usr/local/sbin/host-security-audit
   ```

2. Run it and read the findings.

   ```bash
   sudo /usr/local/sbin/host-security-audit
   ```

   ```
   === 1. Shadow suite ===
   OK   /etc/shadow present
   644 root:root /etc/passwd
   640 root:shadow /etc/shadow

   === 2. Password aging on human accounts ===
   WARN svcbot: password never expires

   === 3. Listening sockets ===
   udp 127.0.0.53%lo:53 users:(("systemd-resolve",pid=680,fd=13))
   tcp 0.0.0.0:22 users:(("sshd",pid=901,fd=3))
   tcp 127.0.0.1:25 users:(("master",pid=1180,fd=13))

   === 4. Externally reachable listeners ===
   REVIEW 0.0.0.0:22  users:(("sshd",pid=901,fd=3))

   === 5. Enabled units and socket activation ===
   INFO 18 enabled service units
   INFO 9 active socket units

   === 6. Super-server ===
   OK   no xinetd configuration

   === 7. TCP wrappers ===
   INFO tcp_wrappers not configured on this system

   === 8. Maintenance lock ===
   ```

3. Remediate one finding and re-run to confirm the delta.

   ```bash
   sudo chage -M 90 -W 14 svcbot
   sudo /usr/local/sbin/host-security-audit | sed -n '/=== 2/,/=== 3/p'
   ```

   ```
   === 2. Password aging on human accounts ===

   === 3. Listening sockets ===
   ```

4. Tear down the lab users.

   ```bash
   sudo userdel -r alice
   sudo userdel -r svcbot
   sudo rm -f /usr/local/sbin/host-security-audit /root/pre-lab-backup.tar.gz
   ```

**Check your understanding**

* **Q9.1** Section 4 of the script filters out addresses starting with `127.` — but the filter is incomplete for a dual-stack host. What does it miss, and how would you fix the pattern?
* **Q9.2** Section 1 warns about extra UID-0 accounts. Why is a second UID-0 account a host-security finding even if it has a strong password?
* **Q9.3** The script is read-only by design. Give two reasons an audit tool should not remediate automatically.
* **Q9.4** Which of the three objective areas (shadow passwords / unused services / TCP wrappers) does this script cover *least* well, and what would you add?

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**A1.1** `/etc/passwd` must stay world-readable because it is the system's UID→name and GID→name mapping and the source of home directory and login shell. `ls -l`, `ps`, `find -user`, and any program calling `getpwuid()` need it. If you `chmod 600 /etc/passwd`, `ls -l` prints raw numeric UIDs instead of names, `ps` output degrades, many daemons that drop privileges by name fail to start, and `su`/`sudo` may break. The shadow design exists precisely so the *hash* can be removed from that world-readable file rather than making the whole file secret.

**A1.2** In order, colon-separated:

| # | Field | Meaning |
|---|-------|---------|
| 1 | Login name | Must match `/etc/passwd` field 1 |
| 2 | Encrypted password | `$id$salt$hash`, or `!`/`*`/empty |
| 3 | Last change | Days since 1970-01-01 (UTC) |
| 4 | Minimum age | Days that must pass before the password may be changed again |
| 5 | Maximum age | Days after which the password must be changed |
| 6 | Warning period | Days of warning before expiry |
| 7 | Inactivity period | Days of grace *after* expiry before the account is disabled |
| 8 | Expiration date | Absolute account expiry, days since 1970-01-01 |
| 9 | Reserved | Unused |

**A1.3**
* `!` — the account is **locked**. The `!` is prepended to the existing hash by `usermod -L`/`passwd -l`, so no supplied password can ever produce a matching string; removing the `!` restores the original password.
* `!!` — used by RHEL-family `useradd` to mean "a password was never set". Functionally also unusable.
* `*` — conventionally used for system/service accounts that must never authenticate with a password. Like `!`, it is not a valid hash; the practical difference is only convention and the fact that it destroys no prior hash.
* **Empty** — **no password required**. Depending on PAM configuration (`nullok`), the account may log in with no credentials at all. This is always a finding.

**A1.4** The three states are `P` (usable password), `L` (locked), and `NP` (**no password** — the field is empty). `NP` is dangerous because the account may authenticate with an empty string wherever PAM allows null passwords, which is functionally an unauthenticated login.

**A1.5** The epoch is 1970-01-01 UTC and the unit is **days**, not seconds. A value of `0` is a special case: it does *not* mean 1 January 1970 but "the password must be changed at the next login" — this is what `chage -d 0` and `passwd -e` set. An **empty** field means aging is disabled for that account.

### Exercise 2

**A2.1** Only the **login name** and the **encrypted password** survive; the password moves back into field 2 of `/etc/passwd`, replacing the `x`. All seven aging fields — last change, min, max, warn, inactive, expire, reserved — are discarded, because `/etc/passwd` has no place to store them. This is why `pwunconv` is a lossy operation.

**A2.2** From `/etc/login.defs` — `PASS_MIN_DAYS`, `PASS_MAX_DAYS` and `PASS_WARN_AGE`. `pwconv` also sets the last-change field to today for every account it migrates, which is itself a subtle side effect.

**A2.3** Direct editing risks corrupting the file and, worse, races with a concurrent `passwd`, `useradd` or `chage` that holds `/etc/passwd.lock` — the two writers can clobber each other and leave accounts unusable. Use **`vipw`** for `/etc/passwd` (and `vipw -s` for `/etc/shadow`) and **`vigr`** for `/etc/group` (`vigr -s` for `/etc/gshadow`). These take the correct lock, invoke `$EDITOR`, and validate on exit.

**A2.4** The group password in `/etc/gshadow` is consumed by **`newgrp`** (and `sg`): a user who is *not* a member of the group can join it for the duration of a new shell by supplying that password. It is rarely used and generally considered obsolete; most sites leave it as `!` or `*` and manage membership explicitly.

### Exercise 3

**A3.1** It prepends a single `!` character to the existing hash string in field 2. Password verification works by re-hashing the supplied password with the stored salt and comparing the result to the stored string; a string beginning with `!` is not a valid hash of anything, so the comparison can never succeed. The original hash is preserved intact behind the `!`, which is why `usermod -U` restores the previous password exactly.

**A3.2** Surviving paths include: SSH **public-key** authentication, `su - user` executed by root, `sudo -u user`, cron and systemd timer jobs running as that user, and any service that authenticates the user by a non-password mechanism (Kerberos, LDAP with a different bind, PAM modules that skip `pam_unix`). The control that closes all of them at once is **account expiry**: `usermod -e 1 user` or `chage -E 1970-01-02 user`, which makes PAM's account phase reject the user regardless of the authentication method.

**A3.3** At next login the user is authenticated normally and then immediately forced through a password change before getting a shell (`passwd -e` does the same). `0` is not read as a date because `shadow` reserves it as a sentinel meaning "expired, change now"; a genuine 1970-01-01 would be indistinguishable, which is an accepted historical wart.

**A3.4** `-M` (max) is when the password **expires** — after that many days the user is forced to change it at next login, but can still log in to do so. `-I` (inactive) is the **grace window after** expiry: once max + inactive days have passed with no change, the account is disabled entirely and the user can no longer log in to fix it. `-I -1` disables the grace window (unlimited grace); `-I 0` disables the account the moment the password expires.

**A3.5** `/bin/false` exits immediately with status 1 and prints nothing — the user sees a silent disconnect. `/usr/sbin/nologin` prints a polite refusal message and then exits, and it also logs the attempt via syslog. The message is customised by creating **`/etc/nologin.txt`**; if that file exists, `nologin` prints its contents instead of the built-in "This account is currently not available."

### Exercise 4

**A4.1** Reading the `/proc/<pid>/fd` entries needed to map a socket inode to a process requires privileges over that process. Without root, the `Process` column is empty for every socket you do not own, so you get ports without owners — enough to see *that* something listens, not *what*. The `uid:` and `ino:` fields from `-e` are likewise incomplete.

**A4.2** `127.0.0.53%lo:53` and `127.0.0.1:25`. Both are bound to loopback addresses, so the kernel will not accept packets for them arriving on a physical interface. `0.0.0.0:*` (or `*:*`) in the local-address column means "all IPv4 addresses"; `[::]` means all IPv6 addresses; anything in `127.0.0.0/8` or `[::1]` is loopback-only.

**A4.3** **Yes, port 22 is still reachable.** With socket activation, `systemd` (PID 1) holds the listening socket. Stopping the service only kills the daemon; the next incoming connection causes systemd to start `sshd.service` again. You must stop *and disable* the socket unit as well: `systemctl disable --now sshd.socket sshd.service`.

**A4.4** **No.** `/etc/services` is a name↔number lookup table consulted by `getservbyname()`/`getaddrinfo()` and by display tools. A daemon binds whatever port its own configuration specifies (`Port` in `sshd_config`, `ListenStream=` in a socket unit, a hard-coded default). Some daemons *do* look up their name in `/etc/services` for their default, but changing the file does not retroactively move an already-bound socket, and most modern daemons ignore it.

**A4.5** Most likely the socket belongs to a process inside a different **network or PID namespace** — a container, or a `systemd-nspawn`/VM guest — so the inode is not resolvable from your namespace. Other possibilities: the socket is held by a kernel thread (e.g. NFS server, `kernel_tcp` listeners), or the process exited between the socket enumeration and the `/proc` walk.

### Exercise 5

**A5.1** Weakest to strongest:
1. **`systemctl stop`** — kills the running instance now. Nothing prevents it from starting again at boot or on demand.
2. **`systemctl disable`** — removes the `.wants/` symlinks so it will not start at boot. It can still be started manually or pulled in as a dependency of another unit.
3. **`systemctl mask`** — symlinks the unit to `/dev/null`, so it cannot be started by *any* means, including as a dependency. Reversible with `unmask`.
4. **Package removal** — the binary is gone; nothing can be started and no future update reinstates the unit. Strongest, and the correct answer for anything you are sure you never need.

**A5.2** `rpcbind.socket` is a **socket-activation** unit: PID 1 itself opens and holds the listening socket, and only starts `rpcbind.service` when a connection arrives, passing the already-open file descriptor. Stopping the service therefore leaves the port open under systemd's ownership.

**A5.3** `disable` only manipulates the `[Install]` symlinks — it is a boot-time statement, not a runtime one, and systemd deliberately keeps the two separate so you can stage a change without an outage. Use **`systemctl disable --now <unit>`**, which is exactly `disable` + `stop`. (`enable --now` is the symmetric form.)

**A5.4** The mask lives in `/etc/systemd/system/<unit>` (or `/run/systemd/system/<unit>` for a runtime mask, created by `mask --runtime`), as a **symlink to `/dev/null`**. Because `/etc/systemd/system` has higher precedence than `/usr/lib/systemd/system`, the null unit shadows the vendor unit. `systemctl cat` shows the vendor file for reference but `systemctl status` reports `masked`.

**A5.5** Remove the start symlinks from the runlevel directories — classically `update-rc.d ssh disable` / `update-rc.d -f ssh remove` on Debian, or `chkconfig sshd off` on Red Hat. Mechanically, this deletes `/etc/rc<N>.d/S??ssh` for the runlevels where it started (and usually leaves or adds a `K??ssh` kill link). The script itself, `/etc/init.d/ssh`, stays in place and can still be invoked manually.

**A5.6** It replaced the **`initdefault`** line, written as `id:3:initdefault:` in `/etc/inittab`. Runlevel **3** (multi-user with networking, no graphical login) corresponds to `multi-user.target`; runlevel 5 corresponds to `graphical.target`.

### Exercise 6

**A6.1** The super-server solves the resource cost of keeping many rarely-used daemons resident: one process listens on all their ports and forks the real daemon only when a connection arrives, and it provides *centralised* logging, access control and rate limiting for services that lack them. The modern equivalent is **systemd socket activation** (`systemd.socket` units with `Accept=yes` for the per-connection, inetd-style model).

**A6.2** `disable = yes` keeps the service definition, its access-control rules and its documentation in the tree while making `xinetd` refuse to listen for it. Deleting the file removes the definition entirely. **`disable = yes` is preferable on an audited system**: the file remains as evidence of a deliberate decision, is visible to configuration management and to a reviewer, and can be re-enabled without reconstructing the rules from memory. (`enable =` in `xinetd.conf` is the whitelist counterpart.)

**A6.3** **`no_access` wins.** `xinetd` compares the specificity of the matching rules: the rule with the longest matching prefix decides, and where they are equally specific, `no_access` denies. `192.168.178.99` is a more specific match than `192.168.178.0/24`, so the host is denied. The general principle is that deny is evaluated to be able to carve exceptions out of a permitted range.

**A6.4** `wait` tells `xinetd` whether it should **wait for the child to finish** before listening again.
* `wait = no` (multi-threaded) for `stream`/TCP: `xinetd` accepts the connection, forks a server for that connection, and returns to `accept()` immediately, so many clients are served concurrently.
* `wait = yes` (single-threaded) for `dgram`/UDP: there is no `accept()`; `xinetd` hands the *socket itself* to the server, which reads the datagrams, and `xinetd` must not touch the socket until that server exits.

Swapping them breaks both: a TCP service with `wait = yes` serializes to one client at a time and stalls; a UDP service with `wait = no` has `xinetd` and the child racing to read the same socket, producing lost or duplicated datagrams and a fork storm.

**A6.5** `tcpd` is the **TCP wrappers** front-end. `inetd` executes `tcpd` in place of the real daemon; `tcpd` looks up the request in `/etc/hosts.allow` and `/etc/hosts.deny`, logs it via syslog, and only then `exec()`s the real daemon named in the argument list — or drops the connection. This is how access control and logging were retrofitted onto daemons that had neither, without recompiling them.

**A6.6** `cps = 25 30` means: accept at most **25 connections per second**; if that rate is exceeded, **disable the service for 30 seconds** before listening again. It mitigates **connection-flood denial of service** (and, combined with `instances` and `per_source`, fork-bomb style resource exhaustion). `instances = 60` caps total concurrent servers for the service; `per_source = 10` caps concurrent connections from any single source address.

### Exercise 7

**A7.1**
1. Read `/etc/hosts.allow` top to bottom. On the **first** matching `daemon : client` rule, **grant** access and stop.
2. Otherwise read `/etc/hosts.deny` top to bottom. On the first matching rule, **deny** access and stop.
3. If neither file matches (including if the files are missing or empty), **grant** access.

The default is therefore permissive, which is why the classic hardened configuration puts `ALL : ALL` in `hosts.deny` and enumerates exceptions in `hosts.allow`.

**A7.2** The rules are **inert** for `sshd`. Access control by `libwrap` only happens if the binary is linked against it (or is invoked through `tcpd`); OpenSSH dropped `libwrap` in 6.7, and RHEL/Fedora removed the `tcp_wrappers` library from the distribution entirely. On a current system use **`nftables`/`firewalld`** for network-layer filtering, and `sshd_config`'s `AllowUsers`/`DenyUsers`/`AllowGroups` plus a `Match Address` block for application-layer restriction. The wrapper files remain exam material and remain relevant to a handful of Debian-packaged daemons that still link `libwrap`.

**A7.3** The daemon list matches the **basename of the process as it was invoked** — `argv[0]` — not the unit name and not the full path. That is why `in.telnetd` and `telnetd` are different patterns: on a system where `inetd` runs `/usr/sbin/tcpd in.telnetd`, the wrapper sees `in.telnetd`, and a rule written for `telnetd` never matches. When a daemon calls `libwrap` internally, the name is whatever the daemon passes to `request_init()`, which is usually its own short name (`sshd`, `vsftpd`, `rpcbind`). `tcpdchk` and `tcpdmatch` exist to catch exactly this class of typo.

**A7.4**
* **`LOCAL`** — any host whose name contains no dot, i.e. on the local domain.
* **`KNOWN`** — both the hostname *and* the address are known: forward and reverse lookups resolve and the user lookup succeeded.
* **`UNKNOWN`** — the name or the address could not be determined.
* **`PARANOID`** — the hostname does not match the address: forward-confirmed reverse DNS fails. When `tcpd` is compiled with `-DPARANOID` these hosts are dropped before the rules are even consulted.

**`KNOWN`, `UNKNOWN` and `PARANOID` all depend on DNS** (`LOCAL` depends only on the resolved name's shape). The operational risk is that DNS is controlled by a third party and can fail or be poisoned: a transient resolver outage can flip every client to `UNKNOWN` and lock everyone out, while an attacker who controls reverse DNS for their own address range can influence `KNOWN`. Address-based rules are more trustworthy.

**A7.5**

```
ALL : ALL EXCEPT 10.0.0.0/255.0.0.0
```

The two-file form is preferred because `hosts.allow` is evaluated first and short-circuits: putting the exceptions there keeps the deny rule a simple, auditable `ALL : ALL`, and lets you add or remove exceptions without editing a compound expression whose `EXCEPT` precedence (it is left-associative, and `a EXCEPT b EXCEPT c` parses as `a EXCEPT (b EXCEPT c)`) is easy to get wrong.

**A7.6** Both take a shell command in the optional third field.
* **`spawn`** runs the command as a **background child**, detached from the connection; stdin/stdout/stderr are `/dev/null`. The access decision (grant/deny) is unaffected. Use it for logging, alerting, or triggering a firewall rule.
* **`twist`** **replaces** the requested service with the command — the command's stdin/stdout are wired to the client socket, and the client talks to it instead of the real daemon. Use it to return a banner or a canned rejection message. `twist` cannot be used in a rule that also grants access to the real service, since it consumes the connection.

Both support the `%` expansions: `%a` client address, `%h` client hostname, `%d` daemon name, `%u` client user, `%c` client info, `%p` server PID.

### Exercise 8

**A8.1** **root (UID 0) is exempt.** The exemption is implemented in **PAM**, in `pam_nologin.so`: the module returns `PAM_SUCCESS` when the authenticating user's UID is 0, and `PAM_AUTH_ERR` (after printing the file) otherwise. `login(1)` historically implemented the check itself, which is why it also honours the file when built without PAM, but on a modern distribution the enforcement point is the PAM stack — which is also why a service whose `/etc/pam.d/` file omits `pam_nologin` (commonly `sudo`) is unaffected.

**A8.2** `pam_nologin` checks **`/var/run/nologin` first**, and only if that does not exist falls back to **`/etc/nologin`**. (`/var/run` is a symlink to `/run` on current systems.) The `/run` path is preferred under systemd because `/run` is a tmpfs cleared at every boot: the lock cannot survive a reboot by accident. `systemd-user-sessions.service` creates `/run/nologin` early in shutdown (and during boot until the system is ready) and removes it when multi-user login should be permitted. `/etc/nologin` persists across reboots, which is what you want for a deliberate maintenance lock — and exactly the trap that leaves a machine unloginable after an unplanned restart.

**A8.3**
* **`/etc/nologin`** — a *flag file*. If it exists, PAM denies non-root logins and displays its contents to the user. Maintenance lock; delete it to restore logins.
* **`/usr/sbin/nologin`** (`/sbin/nologin` on RHEL-family) — an *executable*, used as a login **shell** in `/etc/passwd` field 7 to prevent a specific account from getting an interactive shell. Affects one account, permanently, regardless of the system state.
* **`/etc/nologin.txt`** — the *message file* read by the `/usr/sbin/nologin` **program**. If present, its contents replace the default "This account is currently not available." It has nothing to do with `/etc/nologin`.

**A8.4** Examples:
* **SSH public-key sessions to a service that omits `pam_nologin`** or has `UsePAM no` — fix by setting `UsePAM yes` and confirming `account required pam_nologin.so` is in `/etc/pam.d/sshd`, or by stopping `sshd` outright during the window.
* **cron / systemd timers** running as the user — stop `cron`/`crond` or mask the relevant timers for the window; `/etc/nologin` is a *login* control and cron jobs are not logins.
* **`sudo -u user` and `su - user` from root** — root is exempt by design; restrict with `sudoers` if that matters.
* **Already-established sessions** — `/etc/nologin` blocks *new* logins only; existing shells keep running. Use `pkill -u <user>` or `loginctl terminate-user` to clear them.

**A8.5** `shutdown` with a delay creates **`/run/nologin`** (historically `/etc/nologin`) as soon as it is scheduled, to stop users from logging into a machine that is about to go down; the message contains the shutdown time. Cancel with **`shutdown -c`**, which removes the file and aborts the pending shutdown. If the file was left behind by a crashed or killed `shutdown`, remove it manually: `rm -f /run/nologin /etc/nologin`.

### Exercise 9

**A9.1** It misses the IPv6 loopback in its non-bracketed forms and the IPv6 wildcard is not the issue — the concrete gaps are `[::1]:port` (the awk pattern anchors `^\[::1\]` but `ss` may print `[::1]:25`, which the pattern does catch) and, more importantly, **any other address in `127.0.0.0/8`** is caught, while a listener bound to a specific private address such as `192.168.178.20:22` is reported as REVIEW even though it is not world-reachable, and `*:80` (IPv6-any) is correctly flagged. The realistic fix is to filter on the full loopback set and to be explicit about the wildcard:

```bash
ss -tlpnH | awk '$4 !~ /^(127\.[0-9.]+|\[::1\]|localhost)/ {print "REVIEW "$4"  "$6}'
```

The deeper point: "bound to a routable address" is not the same as "reachable" — the firewall is the other half of the answer, and a socket audit alone cannot tell you.

**A9.2** UID 0 *is* the privilege check on Linux — the kernel authorises by numeric UID, not by name. A second account with UID 0 is a full root account with a separate credential, separate password aging, and separate SSH keys, and it is easy to miss in an audit that only looks at the `root` line. It multiplies the credentials that must be protected and rotated, it usually escapes `sudo` logging entirely, and it is a classic persistence mechanism after a compromise. Strong password or not, it is a finding.

**A9.3** Reasons include:
* **Availability.** Automatically disabling a listener or expiring an account can take down a production service; the audit tool has no way to know that port 8080 is the payment gateway. Remediation must be a human decision with a change window.
* **Auditability and reproducibility.** A read-only tool can be run by anyone, on any host, at any time, including by an auditor who is not authorised to change anything. Once it mutates state, its output is no longer a description of the host but a description of what it did to the host, and running it twice gives different results.
* **Blast radius on false positives.** Detection heuristics are approximate; auto-remediation converts every false positive into an outage.

**A9.4** **TCP wrappers** is covered least well, and deliberately so — the script only checks for a default-deny line in `/etc/hosts.deny`, which proves nothing about whether any daemon on the host actually consults it. A better check runs `ldd` against each listening binary to report which ones are genuinely `libwrap`-linked, runs `tcpdchk` when the `tcpd` utilities are present, and — since the honest answer on most current systems is "wrappers are not the control here" — reports the state of `nftables`/`firewalld` instead. Secondarily, the shadow section checks aging but not hash strength: adding a check that every hash uses `$6$` or `$y$` (rejecting `$1$` MD5 and DES-style 13-character hashes) would close a real gap.

</details>

---

## Sources

* LPI — *Exam 102-500 Objectives*, topic 110.2 "Setup host security": <https://www.lpi.org/our-certifications/exam-102-objectives/>
* LPI — *Exam 101-500 Objectives*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
* shadow-utils upstream project (`passwd`, `chage`, `pwconv`, `vipw`, `shadow(5)`, `login.defs(5)`): <https://github.com/shadow-maint/shadow>
* `shadow(5)` manual page: <https://man7.org/linux/man-pages/man5/shadow.5.html>
* `chage(1)` manual page: <https://man7.org/linux/man-pages/man1/chage.1.html>
* `nologin(5)` and `nologin(8)` manual pages: <https://man7.org/linux/man-pages/man5/nologin.5.html> · <https://man7.org/linux/man-pages/man8/nologin.8.html>
* Linux-PAM — `pam_nologin` System Administrators' Guide: <https://www.man7.org/linux/man-pages/man8/pam_nologin.8.html>
* systemd — `systemd.socket(5)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html>
* systemd — `systemctl(1)`, including `mask`/`disable --now`: <https://www.freedesktop.org/software/systemd/man/latest/systemctl.html>
* systemd — `systemd-user-sessions.service(8)` and `/run/nologin`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-user-sessions.service.html>
* `hosts_access(5)` — TCP wrappers access control language: <https://man7.org/linux/man-pages/man5/hosts_access.5.html>
* `hosts_options(5)` — `spawn`, `twist` and the extended language: <https://man7.org/linux/man-pages/man5/hosts_options.5.html>
* `tcpd(8)`, `tcpdchk(8)`, `tcpdmatch(8)`: <https://man7.org/linux/man-pages/man8/tcpd.8.html>
* Fedora Project — *Deprecate TCP wrappers* change proposal: <https://fedoraproject.org/wiki/Changes/Deprecate_TCP_wrappers>
* OpenSSH release notes, 6.7 (removal of TCP wrappers support): <https://www.openssh.com/txt/release-6.7>
* xinetd upstream project and `xinetd.conf(5)`: <https://github.com/xinetd-org/xinetd> · <https://linux.die.net/man/5/xinetd.conf>
* iproute2 — `ss(8)`: <https://man7.org/linux/man-pages/man8/ss.8.html>