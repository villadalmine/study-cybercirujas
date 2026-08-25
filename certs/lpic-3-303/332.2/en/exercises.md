# 332.2 — Host Intrusion Detection · Guided Exercises

**Exam:** LPIC-3 303 Security (303-300, v3.0.0) · **Topic weight:** 8.33
**Objective coverage:** Linux Audit framework (`auditd`, `auditctl`, `ausearch`, `aureport`, `auditd.conf`, `audit.rules`), `chkrootkit`, `rkhunter` (incl. updates), Linux Malware Detect (`maldet`), AIDE (incl. rule management), OpenSCAP (`oscap`), and automation of host scans with cron/systemd timers.

**Reference:** <https://www.lpi.org/our-certifications/exam-303-objectives/>

---

## Lab environment

These exercises are **destructive by design**: you will add a UID 0 account, drop a setuid binary, weaken `sshd_config` and write an antivirus test file. Run them only on a disposable VM you own.

| Requirement | Value |
|---|---|
| Host | Disposable VM, 2 vCPU / 2 GB RAM / 20 GB disk |
| Distribution | Debian 12 (*primary*) **and/or** RHEL 9 clone — AlmaLinux/Rocky 9 (*RPM variants shown*) |
| Access | `root` (all commands assume root unless prefixed with `sudo -u`) |
| Snapshot | **Take a VM snapshot before Exercise 1.** AIDE and rkhunter baselines are worthless once you have polluted the filesystem |
| Network | Outbound HTTPS (rkhunter/maldet/ClamAV signature updates, SSG content) |

Working directory for all reports:

```bash
install -d -m 0750 /var/log/hids-lab
cd /var/log/hids-lab
```

---

## Exercise 1 — The Linux Audit framework: architecture and runtime state

*The kernel audit subsystem is not `auditd`. Learning where the boundary sits is what makes the rest of the topic tractable.*

1. Confirm the kernel was built with audit support and check whether auditing was enabled at boot:

   ```bash
   grep -E 'CONFIG_AUDIT(SYSCALL)?=' /boot/config-$(uname -r)
   cat /proc/cmdline
   ```

   ```
   CONFIG_AUDIT=y
   CONFIG_AUDITSYSCALL=y
   BOOT_IMAGE=/vmlinuz-6.1.0-18-amd64 root=/dev/mapper/vg0-root ro quiet
   ```

2. Install and start the userspace daemon:

   ```bash
   # Debian
   apt-get install -y auditd audispd-plugins
   # RHEL 9 (audit is normally installed already)
   dnf install -y audit audispd-plugins

   systemctl enable --now auditd
   ```

3. Query the **kernel's** audit state — not the daemon's:

   ```bash
   auditctl -s
   ```

   ```
   enabled 1
   failure 1
   pid 812
   rate_limit 0
   backlog_limit 8192
   lost 0
   backlog 0
   backlog_wait_time 60000
   backlog_wait_time_actual 0
   ```

4. Stop the daemon and re-read the state. On RHEL, note the refusal:

   ```bash
   systemctl stop auditd
   ```

   ```
   Failed to stop auditd.service: Operation refused, unit auditd.service may be requested by dependency only.
   ```

   ```bash
   service auditd stop        # the supported path on RHEL
   auditctl -s | head -3
   ```

   ```
   enabled 0
   failure 1
   pid 0
   ```

5. Restart it and deliberately generate backlog pressure to see loss accounting:

   ```bash
   service auditd start
   auditctl -b 64                       # absurdly small on purpose
   auditctl -w /etc -p wa -k noisy
   find /etc -type f -exec touch -a {} + >/dev/null 2>&1
   auditctl -s | grep -E 'lost|backlog'
   ```

   ```
   backlog_limit 64
   lost 1473
   backlog 0
   ```

6. Restore a sane backlog and set the failure mode explicitly:

   ```bash
   auditctl -D
   auditctl -b 8192
   auditctl -f 1
   ```

7. Make the boot-time configuration permanent (kernel side, not `auditd.conf`):

   ```bash
   # Debian
   sed -i 's/^GRUB_CMDLINE_LINUX="/&audit=1 audit_backlog_limit=8192 /' /etc/default/grub
   update-grub
   # RHEL 9
   grubby --update-kernel=ALL --args="audit=1 audit_backlog_limit=8192"
   ```

**Verify your understanding**

- **Q1.1** — `auditctl -s` reports `enabled 0` while `auditd` is stopped, yet `CONFIG_AUDITSYSCALL=y`. Where do audit records go in that state, and what does the `audit=1` kernel parameter actually change?
- **Q1.2** — What is the operational meaning of a non-zero `lost` counter, and why is `lost` reported by the *kernel* rather than found in `/var/log/audit/audit.log`?
- **Q1.3** — A security standard requires that the system must not continue running if audit records cannot be recorded. Which `auditctl` flag implements that, with which value, and what is the production risk of choosing it?
- **Q1.4** — Why does `audit_backlog_limit=8192` on the kernel command line matter even though `/etc/audit/rules.d/` already contains `-b 8192`?

---

## Exercise 2 — Audit rules: watches, syscall rules, `auid`, and immutability

1. Add a file watch and a syscall rule at runtime:

   ```bash
   auditctl -w /etc/shadow -p wa -k identity
   auditctl -a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k rootcmd
   auditctl -l
   ```

   ```
   -w /etc/shadow -p wa -k identity
   -a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=-1 -F euid=0 -k rootcmd
   ```

2. Generate events from a real login session (`auid` is only set by `pam_loginuid` at login — `su -` from an existing root shell will *not* produce a meaningful `auid`):

   ```bash
   useradd -m -s /bin/bash alice && echo 'alice:Lab-Pass-303' | chpasswd
   usermod -aG sudo alice 2>/dev/null || usermod -aG wheel alice
   ssh alice@localhost 'sudo id; sudo cp /etc/shadow /tmp/s'
   ```

3. Retrieve the events by key, uninterpreted first, then interpreted:

   ```bash
   ausearch -k identity --start recent
   ```

   ```
   type=SYSCALL msg=audit(1756029120.441:912): arch=c000003e syscall=257 success=yes exit=3
   a0=ffffff9c a1=55c1f0a2b2e0 a2=0 a3=0 items=1 ppid=2211 pid=2214 auid=1000 uid=0 gid=0
   euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=4 comm="cp" exe="/usr/bin/cp"
   subj=unconfined key="identity"
   type=CWD msg=audit(1756029120.441:912): cwd="/home/alice"
   type=PATH msg=audit(1756029120.441:912): item=0 name="/etc/shadow" inode=131076 dev=fd:00
   mode=0100640 ouid=0 ogid=42 rdev=00:00 nametype=NORMAL
   type=PROCTITLE msg=audit(1756029120.441:912): proctitle=6370002F6574632F736861646F77002F746D702F73
   ```

   ```bash
   ausearch -k identity --start recent -i | tail -6
   ausearch -k rootcmd --start recent --format text | head -3
   ```

   ```
   At 09:52:00 08/24/2026 alice, acting as root, successfully executed /usr/bin/id
   ```

4. Translate raw fields by hand — you will need this without `-i` on the exam and in forensics:

   ```bash
   ausyscall x86_64 257
   ausyscall --dump | grep -w execve
   ```

   ```
   openat
   59	execve
   ```

5. Aggregate with `aureport`:

   ```bash
   aureport -k --summary
   aureport -au --summary -i
   aureport --failed --summary -i
   aureport -f -i --start today | head
   ```

   ```
   Key Summary Report
   ===========================
   total  key
   ===========================
   37  identity
   12  rootcmd
   ```

6. Persist the rules. Runtime rules die at reboot; `augenrules` compiles `/etc/audit/rules.d/*.rules` in lexical filename order into `/etc/audit/audit.rules`:

   ```bash
   cat > /etc/audit/rules.d/50-lab.rules <<'EOF'
   ## Identity and privilege escalation
   -w /etc/passwd  -p wa -k identity
   -w /etc/shadow  -p wa -k identity
   -w /etc/group   -p wa -k identity
   -w /etc/sudoers -p wa -k identity
   -w /etc/sudoers.d/ -p wa -k identity

   ## Any root-privileged execution originating from a real login session
   -a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k rootcmd
   -a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k rootcmd

   ## setuid/setgid execution by unprivileged users (classic privesc primitive)
   -a always,exit -F arch=b64 -C uid!=euid -F euid=0 -S execve -k setuid_exec
   -a always,exit -F arch=b32 -C uid!=euid -F euid=0 -S execve -k setuid_exec

   ## Kernel module lifecycle
   -a always,exit -F arch=b64 -S init_module,finit_module,delete_module -F auid!=unset -k modules
   -w /usr/bin/kmod -p x -k modules

   ## Time changes (anti-anti-forensics)
   -a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time_change

   ## Noise reduction: drop CWD records entirely
   -a never,exclude -F msgtype=CWD
   EOF

   cat > /etc/audit/rules.d/99-finalize.rules <<'EOF'
   -e 2
   EOF

   augenrules --load
   auditctl -s | head -1
   ```

   ```
   enabled 2
   ```

7. Prove immutability, then verify the attempt was itself recorded:

   ```bash
   auditctl -w /tmp -p wa -k test
   ```

   ```
   Error sending add rule data request (Operation not permitted)
   ```

   ```bash
   ausearch -m CONFIG_CHANGE --start recent -i | tail -2
   ```

8. Trace a single process without touching the ruleset (`autrace` requires an empty ruleset):

   ```bash
   auditctl -e 1 && auditctl -D
   autrace /bin/ls /tmp
   ```

   ```
   Waiting to execute: /bin/ls
   ...
   Cleaning up...
   Trace complete. You can locate the records with 'ausearch -i -p 3312'
   ```

   ```bash
   augenrules --load        # restore the real ruleset
   ```

**Verify your understanding**

- **Q2.1** — `-w /etc/shadow -p wa -k identity` and a `-a always,exit -F path=/etc/shadow` rule: are these two different mechanisms? What happens to a watch when the watched file is deleted and recreated by an editor that writes a temp file and renames it?
- **Q2.2** — Explain `-F auid>=1000 -F auid!=unset`. What is `auid=4294967295` and which component sets `auid` in the first place?
- **Q2.3** — Why is every syscall rule written twice, once with `arch=b64` and once with `arch=b32`, on an x86_64 host?
- **Q2.4** — The ruleset contains `-a never,exclude -F msgtype=CWD` placed *last* in `50-lab.rules`. Given that audit evaluates rules first-match-wins within a list, is that placement a problem? Where *would* placement bite you?
- **Q2.5** — After `-e 2` you discover a rule is wrong. What are your options, and why is `-e 2` still the right setting for a production host?
- **Q2.6** — `-C uid!=euid -F euid=0` — describe in one sentence the concrete attacker behaviour this rule is designed to catch.

---

## Exercise 3 — `auditd.conf`: retention, disk exhaustion, and off-host shipping

1. Inspect the daemon configuration and set production values:

   ```bash
   cp /etc/audit/auditd.conf /etc/audit/auditd.conf.orig
   ```

   ```bash
   sed -i \
     -e 's/^log_format = .*/log_format = ENRICHED/' \
     -e 's/^max_log_file = .*/max_log_file = 64/' \
     -e 's/^num_logs = .*/num_logs = 10/' \
     -e 's/^max_log_file_action = .*/max_log_file_action = ROTATE/' \
     -e 's/^space_left = .*/space_left = 500/' \
     -e 's/^space_left_action = .*/space_left_action = EMAIL/' \
     -e 's/^admin_space_left = .*/admin_space_left = 200/' \
     -e 's/^admin_space_left_action = .*/admin_space_left_action = SINGLE/' \
     -e 's/^disk_full_action = .*/disk_full_action = SUSPEND/' \
     -e 's/^name_format = .*/name_format = HOSTNAME/' \
     /etc/audit/auditd.conf
   service auditd restart
   ```

2. Observe what `ENRICHED` changes in the on-disk record:

   ```bash
   id alice
   ausearch -k identity --start recent | tail -1
   ```

   ```
   type=SYSCALL msg=audit(1756030001.117:1044): ... auid=1000 uid=0 gid=0 euid=0 ...
   ARCH=x86_64 SYSCALL=openat AUID="alice" UID="root" GID="root" EUID="root" ...
   ```

3. Confirm rotation and retention arithmetic:

   ```bash
   ls -l /var/log/audit/
   df -Pm /var/log/audit | tail -1
   ```

   ```
   -rw-------. 1 root root 8388608 Aug 24 10:05 audit.log
   -rw-------. 1 root root 67108864 Aug 24 09:41 audit.log.1
   ```

4. Configure off-host shipping through the audit dispatcher (audit ≥ 3.0 keeps plugins in `/etc/audit/plugins.d/`):

   ```bash
   ls /etc/audit/plugins.d/
   ```

   ```
   af_unix.conf  au-remote.conf  syslog.conf
   ```

   ```bash
   sed -i 's/^active = .*/active = yes/' /etc/audit/plugins.d/au-remote.conf
   sed -i -e 's/^remote_server = .*/remote_server = 10.0.0.20/' \
          -e 's/^port = .*/port = 60/' \
          -e 's/^network_failure_action = .*/network_failure_action = syslog/' \
          -e 's/^disk_low_action = .*/disk_low_action = ignore/' \
          /etc/audit/audisp-remote.conf
   service auditd restart
   ```

5. Extract a machine-readable slice for a SIEM ingest test:

   ```bash
   ausearch --start today -k rootcmd --format csv > /var/log/hids-lab/rootcmd-$(date +%F).csv
   head -2 /var/log/hids-lab/rootcmd-*.csv
   ```

**Verify your understanding**

- **Q3.1** — Why is `log_format = ENRICHED` effectively mandatory once you ship audit logs to a central collector or a container-based SIEM?
- **Q3.2** — Distinguish `space_left_action`, `admin_space_left_action` and `disk_full_action`. Which of the three can leave you with a machine that is up, reachable, and silently no longer auditing?
- **Q3.3** — With `max_log_file = 64`, `num_logs = 10` and `max_log_file_action = ROTATE`, what is the worst-case disk consumption, and what happens to the oldest data? Which value of `max_log_file_action` would you use instead if an external process rotates and archives the logs?
- **Q3.4** — `auditd` writes `/var/log/audit/audit.log` directly instead of going through rsyslog/journald. Name two security properties that design choice buys you.

---

## Exercise 4 — AIDE: baseline, rule groups, and detection

1. Install and locate the configuration:

   ```bash
   # Debian: config is assembled from /etc/aide/aide.conf + /etc/aide/aide.conf.d/
   apt-get install -y aide aide-common
   # RHEL 9: single file /etc/aide.conf
   dnf install -y aide
   ```

2. Read the attribute vocabulary before writing a rule. Add a custom rule group and apply it:

   ```bash
   # Debian
   cat > /etc/aide/aide.conf.d/99_lab_binaries <<'EOF'
   # Immutable system binaries: everything except access time
   Binlib = p+i+n+u+g+s+b+m+c+sha512+acl+selinux+xattrs

   /usr/bin/       Binlib
   /usr/sbin/      Binlib
   /usr/local/bin/ Binlib
   /usr/local/sbin/ Binlib

   # Config: content + ownership, ignore atime
   /etc/           p+i+u+g+s+m+c+sha256

   # Growing logs: only ever allowed to get bigger
   /var/log/       p+u+g+i+n+S

   # Volatile, exclude outright
   !/var/log/journal
   !/var/lib/aide
   !/etc/mtab$
   EOF
   update-aide.conf
   aide --config-check -c /var/lib/aide/aide.conf.autogenerated && echo "config OK"
   ```

   ```bash
   # RHEL 9 equivalent — append to /etc/aide.conf, then:
   aide --config-check && echo "config OK"
   ```

3. Build the baseline **immediately after installation, before anything else has touched the host**:

   ```bash
   # Debian
   time aideinit -y -f
   # RHEL 9
   time aide --init && mv -v /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
   ```

   ```
   Start timestamp: 2026-08-24 10:20:11 +0000 (AIDE 0.17.4)
   Number of entries:	48211
   ...
   The attributes of the (uncompressed) database(s):
     /var/lib/aide/aide.db.new
       SHA512   : 1nK6P2q0m5G9zX8...==
   real	1m52.331s
   ```

4. Record the baseline's own fingerprint somewhere the host cannot reach:

   ```bash
   sha256sum /var/lib/aide/aide.db* | tee /var/log/hids-lab/aide-db.sha256
   # then copy it OFF the host — print it, mail it, write it to a WORM bucket
   ```

5. Perturb the filesystem and detect it:

   ```bash
   cp /bin/dash /usr/local/sbin/netcheck
   echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
   touch -d '2024-01-01' /usr/bin/curl
   aide --check
   echo "exit=$?"
   ```

   ```
   Start timestamp: 2026-08-24 10:31:44 +0000 (AIDE 0.17.4)
   AIDE found differences between database and filesystem!!

   Summary:
     Total number of entries:	48212
     Added entries:		1
     Removed entries:		0
     Changed entries:		2

   ---------------------------------------------------
   Added entries:
   ---------------------------------------------------

   f+++++++++++++++++: /usr/local/sbin/netcheck

   ---------------------------------------------------
   Changed entries:
   ---------------------------------------------------

   f ...    .C... : /etc/ssh/sshd_config
   f ....    .C.. : /usr/bin/curl

   ---------------------------------------------------
   Detailed information about changes:
   ---------------------------------------------------

   File: /etc/ssh/sshd_config
    Size     : 3264                         | 3285
    Mtime    : 2026-08-24 10:20:03 +0000    | 2026-08-24 10:31:02 +0000
    Ctime    : 2026-08-24 10:20:03 +0000    | 2026-08-24 10:31:02 +0000
    SHA256   : rP1c8m...                    | 9Kd0Va...

   File: /usr/bin/curl
    Mtime    : 2026-05-14 06:11:20 +0000    | 2024-01-01 00:00:00 +0000
    Ctime    : 2026-05-14 06:11:20 +0000    | 2026-08-24 10:31:02 +0000
   exit=7
   ```

6. Scope a check to a subtree — the difference between a 2-minute full scan and a 3-second targeted one during an incident:

   ```bash
   time aide --check --limit '^/usr/local/(s)?bin'
   ```

7. Accept the *legitimate* changes only, and understand what `--update` does:

   ```bash
   rm -f /usr/local/sbin/netcheck
   aide --update
   # Debian
   mv -v /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   # RHEL
   mv -v /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
   ```

8. Wire up automation:

   ```bash
   # Debian — /etc/cron.daily/aide ships with aide-common
   grep -vE '^\s*(#|$)' /etc/default/aide
   ```

   ```
   CRON_DAILY_RUN=yes
   COPYNEWDB=no
   MAILSUBJ="Daily AIDE report"
   MAILTO=root
   ```

   ```bash
   # RHEL 9 — systemd timer shipped by the aide package
   systemctl enable --now dailyaidecheck.timer
   systemctl list-timers dailyaidecheck.timer
   ```

**Verify your understanding**

- **Q4.1** — `/var/log/` uses the group `p+u+g+i+n+S`. What does `S` mean, and what class of attack does it catch that a plain size check (`s`) would not?
- **Q4.2** — In the report, `/usr/bin/curl` shows a changed `Mtime` *and* `Ctime`, while only `Mtime` was tampered with. Why did `Ctime` change too, and why does that make `ctime` more valuable than `mtime` for integrity monitoring?
- **Q4.3** — `aide --check` returned exit code 7. Decompose it. Why does this matter for a cron wrapper that pipes AIDE into a monitoring system?
- **Q4.4** — Debian's `/etc/default/aide` offers `COPYNEWDB=yes`. What does enabling it do to your detection capability, and under what narrow circumstance is it acceptable?
- **Q4.5** — Your AIDE database lives at `/var/lib/aide/aide.db.gz` on the host it protects. Describe the attack this permits and two practical mitigations.
- **Q4.6** — Why does the *order* `Binlib = ...+sha512` matter more than the choice between `sha256` and `sha512`? What is the cost trade-off of adding more hash algorithms to a rule group?

---

## Exercise 5 — rkhunter: baselines, updates, and false positives

1. Install and validate the configuration before running anything:

   ```bash
   apt-get install -y rkhunter unhide     # Debian
   dnf install -y rkhunter               # RHEL (EPEL)
   rkhunter -C
   ```

   ```
   Checking configuration file and command-line options...
   Info: Starting Version 1.4.6
   ```

2. Fix the update path. Debian ships `WEB_CMD="/bin/false"` and disabled mirrors, which makes `--update` fail:

   ```bash
   rkhunter --update
   ```

   ```
   Invalid WEB_CMD configuration option: Relative pathname: "/bin/false"
   ```

   ```bash
   cat > /etc/rkhunter.conf.local <<'EOF'
   WEB_CMD=""
   UPDATE_MIRRORS=1
   MIRRORS_MODE=0
   PKGMGR=DPKG
   MAIL-ON-WARNING=root@localhost
   EOF
   rkhunter --update
   ```

   ```
   Checking rkhunter data files...
     Checking file mirrors.dat                                  [ Updated ]
     Checking file programs_bad.dat                             [ No update ]
     Checking file backdoorports.dat                            [ No update ]
     Checking file suspscan.dat                                 [ Updated ]
     Checking file i18n versions                                [ Updated ]
   ```

3. Build the file-properties baseline — **only on a host you believe is clean**:

   ```bash
   rkhunter --propupd
   ls -l /var/lib/rkhunter/db/rkhunter.dat
   ```

   ```
   [ Rootkit Hunter version 1.4.6 ]
   File updated: searched for 180 files, found 143
   ```

4. Run a full check:

   ```bash
   rkhunter --check --sk --rwo
   echo "exit=$?"
   ```

   ```
   Warning: The file properties have changed:
            File: /usr/bin/curl
            Current inode: 262159    Stored inode: 262143
   Warning: Checking for passwd file changes                    [ Warning ]
            User 'svcops' has been added to the passwd file.
   Warning: Suspicious file types found in /dev:
            /dev/shm/.x: ASCII text
   exit=1
   ```

5. Inspect what a full run covers and how to prune it:

   ```bash
   rkhunter --list tests | head -20
   rkhunter --list rootkits | wc -l
   rkhunter --check --sk --enable rootkits,malware --disable suspscan
   ```

6. Whitelist a *justified* finding — never a mysterious one:

   ```bash
   cat >> /etc/rkhunter.conf.local <<'EOF'
   # Justification: shipped by the monitoring agent package, verified against dpkg
   SCRIPTWHITELIST=/usr/bin/lwp-request
   ALLOWHIDDENDIR=/etc/.java
   ALLOWHIDDENFILE=/usr/share/man/man1/..1.gz
   ALLOW_SSH_ROOT_USER=no
   EOF
   rkhunter -C && rkhunter --check --sk --rwo
   ```

7. Review the log and enable the daily job:

   ```bash
   grep -E '^\[.*\] (Warning|Info: Test)' /var/log/rkhunter.log | tail
   # Debian
   sed -i -e 's/^CRON_DAILY_RUN=.*/CRON_DAILY_RUN="yes"/' \
          -e 's/^CRON_DB_UPDATE=.*/CRON_DB_UPDATE="yes"/' \
          -e 's/^APT_AUTOGEN=.*/APT_AUTOGEN="no"/' /etc/default/rkhunter
   run-parts --test /etc/cron.daily | grep rkhunter
   ```

**Verify your understanding**

- **Q5.1** — Explain precisely what `rkhunter --propupd` does. Why is running it on a host you have not verified the single most damaging mistake in this exercise?
- **Q5.2** — Debian's `APT_AUTOGEN="yes"` runs `--propupd` after every `apt` transaction. State the convenience it buys and the detection gap it opens. Which `PKGMGR` setting is a better answer to the same problem, and what is *its* limitation?
- **Q5.3** — `rkhunter --update` and `rkhunter --propupd` both "update" something. Contrast the two: what data, from where, and what breaks if you confuse them?
- **Q5.4** — Your run reports `Warning: Checking for passwd file changes — User 'svcops' has been added`. rkhunter cannot tell you whether this is an intrusion. What other tool in this topic *can*, and what would you query?
- **Q5.5** — Why does rkhunter check `LD_PRELOAD` / `/etc/ld.so.preload` and compare `strings` output of system binaries? What rootkit class is that aimed at, and what class does it structurally fail to detect?

---

## Exercise 6 — chkrootkit: second opinion from a different angle

1. Install and run:

   ```bash
   apt-get install -y chkrootkit      # Debian
   # RHEL: build from https://www.chkrootkit.org/ or use EPEL where available
   chkrootkit -q
   ```

   ```
   /usr/lib/xfce4/xfconf/xfconfd
   eth0: PACKET SNIFFER(/usr/sbin/NetworkManager[721])
   Searching for Suckit rootkit... Warning: /sbin/init INFECTED
   chkutmp: nothing deleted
   ```

2. Run in expert mode to see the raw evidence rather than the verdict:

   ```bash
   chkrootkit -x lkm 2>&1 | head -20
   chkrootkit -x aliens 2>&1 | head -20
   ```

3. Run against a *mounted, offline* filesystem — the way you use it during response:

   ```bash
   # from rescue media, with the suspect root mounted at /mnt
   chkrootkit -r /mnt -p /bin:/usr/bin
   ```

4. Compare tool overlap on the same box:

   ```bash
   chkrootkit -q | tee /var/log/hids-lab/chkrootkit-$(date +%F).txt | wc -l
   rkhunter --check --sk --rwo | tee /var/log/hids-lab/rkhunter-$(date +%F).txt | wc -l
   ```

5. Schedule it, suppressing the known-benign lines rather than the whole test:

   ```bash
   cat > /etc/cron.daily/chkrootkit-lab <<'EOF'
   #!/bin/sh
   set -u
   OUT=$(/usr/sbin/chkrootkit -q 2>&1 | grep -vE 'PACKET SNIFFER\(/usr/sbin/NetworkManager|^chkutmp: nothing deleted$')
   [ -n "$OUT" ] && printf '%s\n' "$OUT" | logger -t chkrootkit -p auth.warning
   exit 0
   EOF
   chmod 0700 /etc/cron.daily/chkrootkit-lab
   ```

**Verify your understanding**

- **Q6.1** — `Searching for Suckit rootkit... Warning: /sbin/init INFECTED` on a stock systemd host. Why is this a well-known false positive, and what is the general lesson about signature-based rootkit scanners on modern distributions?
- **Q6.2** — `chkrootkit -p /bin:/usr/bin` and `chkrootkit -r /mnt`. Describe the threat model each of these flags exists for, and why running chkrootkit on a live, suspected-compromised host with its own `PATH` is close to meaningless.
- **Q6.3** — `eth0: PACKET SNIFFER(...)` is reported because an interface is in promiscuous mode. Name two legitimate causes on a normal server.
- **Q6.4** — chkrootkit and rkhunter overlap heavily. Give one concrete reason to run both anyway.

---

## Exercise 7 — Linux Malware Detect (maldet) with the ClamAV engine

1. Install ClamAV first — LMD uses `clamscan` as its scanning engine when available, which is dramatically faster than its own:

   ```bash
   apt-get install -y clamav clamav-daemon    # Debian
   dnf install -y clamav clamav-update        # RHEL/EPEL
   systemctl stop clamav-freshclam 2>/dev/null
   freshclam
   systemctl start clamav-freshclam 2>/dev/null
   ```

2. Install LMD from the vendor (it is not packaged by the distributions):

   ```bash
   cd /usr/local/src
   curl -fsSLO https://www.rfxn.com/downloads/maldetect-current.tar.gz
   tar -xzf maldetect-current.tar.gz
   cd maldetect-*/ && ./install.sh
   maldet --version 2>/dev/null || /usr/local/sbin/maldet -V
   ```

   ```
   Linux Malware Detect v1.6.6
             (C) 2002-2023, R-fx Networks <proj@rfxn.com>
   installation completed to /usr/local/maldetect
   config file: /usr/local/maldetect/conf.maldet
   cron.daily: /etc/cron.daily/maldet
   ```

3. Configure it for a *detect-first, quarantine-never* posture — the correct default for a server you must forensically preserve:

   ```bash
   cd /usr/local/maldetect
   sed -i \
     -e 's/^email_alert=.*/email_alert="1"/' \
     -e 's/^email_addr=.*/email_addr="root@localhost"/' \
     -e 's/^quarantine_hits=.*/quarantine_hits="0"/' \
     -e 's/^quarantine_clean=.*/quarantine_clean="0"/' \
     -e 's/^quarantine_suspend_user=.*/quarantine_suspend_user="0"/' \
     -e 's/^scan_clamscan=.*/scan_clamscan="1"/' \
     -e 's/^scan_ignore_root=.*/scan_ignore_root="0"/' \
     conf.maldet
   grep -E '^(quarantine_hits|quarantine_clean|scan_clamscan|email_alert)=' conf.maldet
   ```

4. Update signatures and the tool itself:

   ```bash
   maldet -u        # signature update
   maldet -d        # LMD version update
   ```

   ```
   maldet(3410): {sigup} performing signature update check...
   maldet(3410): {sigup} signature set update completed
   maldet(3410): {sigup} 17262 signatures (14817 MD5 | 2168 HEX | 277 YARA | 0 USER)
   ```

5. Plant a harmless EICAR antivirus test file and scan:

   ```bash
   install -d -m 0755 /var/www/html/uploads
   printf '%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
     > /var/www/html/uploads/avatar.php
   maldet -a /var/www/html/
   ```

   ```
   maldet(3502): {scan} signatures loaded: 17262 (14817 MD5 | 2168 HEX | 277 YARA | 0 USER)
   maldet(3502): {scan} building file list for /var/www/html/, this might take awhile...
   maldet(3502): {scan} setting nice scheduler priorities for all operations: cpunice 19 , ionice 6
   maldet(3502): {scan} file list completed in 0s, found 14 files...
   maldet(3502): {scan} found clamav binary at /usr/bin/clamscan, using clamav scanner engine...
   maldet(3502): {scan} scan of /var/www/html/ (14 files) in progress...
   maldet(3502): {scan} scan completed on /var/www/html/: files 14, malware hits 1, cleaned hits 0, time 6s
   maldet(3502): {scan} scan report saved, to view run: maldet --report 260824-1041.3502
   ```

6. Read the report and the raw hit list:

   ```bash
   maldet --report 260824-1041.3502
   cat /usr/local/maldetect/sess/session.hits.260824-1041.3502
   ```

   ```
   HOST:      lab01
   SCAN ID:   260824-1041.3502
   TOTAL HITS:1
   TOTAL CLEANED: 0

   FILE HIT LIST:
   {CAV}Win.Test.EICAR_HDB-1 : /var/www/html/uploads/avatar.php => /usr/local/maldetect/quarantine/... (not quarantined)
   ```

7. Exercise the quarantine/restore cycle deliberately, then return to detect-only:

   ```bash
   maldet -q 260824-1041.3502          # quarantine the hits of that scan
   ls -l /usr/local/maldetect/quarantine/
   maldet -s 260824-1041.3502          # restore them
   ```

8. Enable inotify monitoring for an upload directory and check the daily job:

   ```bash
   maldet --monitor /var/www/html/uploads
   tail -3 /usr/local/maldetect/logs/inotify_log
   maldet --kill-monitor
   grep -vE '^\s*(#|$)' /etc/cron.daily/maldet | head -20
   ```

**Verify your understanding**

- **Q7.1** — The hit is tagged `{CAV}` rather than `{HEX}`. What do those prefixes tell you about which engine and which signature set produced the detection?
- **Q7.2** — Justify `quarantine_hits="0"` on a production web server that you suspect is compromised. Now give the scenario where `quarantine_hits="1"` plus `quarantine_clean="1"` is the correct setting instead.
- **Q7.3** — LMD's signature set is built largely from files captured at network edges and shared hosting environments. What does that tell you about its true positive profile compared with AIDE, and where in a defence-in-depth stack does maldet belong?
- **Q7.4** — `maldet --monitor /var/www/html/uploads` versus a nightly `maldet -a /var/www/html/`. What does the inotify mode add, and what resource limit will you hit on a large tree (name the kernel tunable)?
- **Q7.5** — Why does the scan log line `found clamav binary at /usr/bin/clamscan, using clamav scanner engine` matter for both performance *and* coverage?

---

## Exercise 8 — OpenSCAP: policy-driven host assessment

1. Install the scanner and the content. **The scanner and the policy content are separate packages** — this is the most common point of confusion:

   ```bash
   # Debian 12
   apt-get install -y openscap-scanner openscap-utils ssg-base ssg-debian ssg-debderived
   # RHEL 9
   dnf install -y openscap-scanner scap-security-guide

   find / -name 'ssg-*-ds.xml' 2>/dev/null
   ```

   ```
   /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
   /usr/share/scap-security-guide/ssg-debian12-ds.xml
   ```

2. Interrogate the content before you use it:

   ```bash
   oscap info /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
   ```

   ```
   Document type: Source Data Stream
   Imported: 2026-05-02T09:11:44

   Stream: scap_org.open-scap_datastream_from_xccdf_ssg-rhel9-xccdf.xml
   Generated: (null)
   Version: 1.3
   Checklists:
   	Ref-Id: scap_org.open-scap_cref_ssg-rhel9-xccdf.xml
   		Status: draft
   		Profiles:
   			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 2 - Server
   				Id: xccdf_org.ssgproject.content_profile_cis
   			Title: CIS Red Hat Enterprise Linux 9 Benchmark for Level 1 - Server
   				Id: xccdf_org.ssgproject.content_profile_cis_server_l1
   			Title: DISA STIG for Red Hat Enterprise Linux 9
   				Id: xccdf_org.ssgproject.content_profile_stig
   			Title: Australian Cyber Security Centre (ACSC) Essential Eight
   				Id: xccdf_org.ssgproject.content_profile_e8
   		Referenced check files:
   			ssg-rhel9-oval.xml
   				system: http://oval.mitre.org/XMLSchema/oval-definitions-5
   	Checks:
   		Ref-Id: scap_org.open-scap_cref_ssg-rhel9-oval.xml
   	Dictionaries:
   		Ref-Id: scap_org.open-scap_cref_ssg-rhel9-cpe-dictionary.xml
   ```

3. Evaluate a profile and produce both machine and human artefacts:

   ```bash
   DS=/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
   PROF=xccdf_org.ssgproject.content_profile_cis_server_l1

   oscap xccdf eval \
     --profile "$PROF" \
     --results-arf /var/log/hids-lab/arf-$(date +%F).xml \
     --report     /var/log/hids-lab/report-$(date +%F).html \
     "$DS"
   echo "exit=$?"
   ```

   ```
   Title   Ensure sshd PermitRootLogin is disabled
   Rule    xccdf_org.ssgproject.content_rule_sshd_disable_root_login
   Ident   CCE-90805-1
   Result  fail

   Title   Ensure auditd Collects Information on the Use of Privileged Commands
   Rule    xccdf_org.ssgproject.content_rule_audit_rules_privileged_commands
   Result  pass
   ...
   exit=2
   ```

4. Drill into a single rule during remediation work instead of re-running the whole benchmark:

   ```bash
   oscap xccdf eval --rule xccdf_org.ssgproject.content_rule_sshd_disable_root_login \
     --profile "$PROF" "$DS"
   ```

5. Generate remediation content — and read it before you ever run it:

   ```bash
   oscap xccdf generate fix --fix-type bash \
     --profile "$PROF" --output /var/log/hids-lab/remediate.sh "$DS"
   oscap xccdf generate fix --fix-type ansible \
     --profile "$PROF" --output /var/log/hids-lab/remediate.yml "$DS"

   # Fix only what actually failed, driven by the results file:
   oscap xccdf generate fix --fix-type bash \
     --result-id "" --output /var/log/hids-lab/remediate-failed.sh \
     /var/log/hids-lab/arf-$(date +%F).xml
   ```

6. Run a *vulnerability* assessment, which is a different question from a *configuration* assessment:

   ```bash
   # RHEL: patch-level OVAL feed published by the vendor
   curl -fsSLO https://security.access.redhat.com/data/oval/v2/RHEL9/rhel-9.oval.xml.bz2
   bunzip2 -f rhel-9.oval.xml.bz2
   oscap oval eval --results /var/log/hids-lab/oval-results.xml \
     --report /var/log/hids-lab/oval-report.html rhel-9.oval.xml | grep -c 'true$'
   ```

7. Scan a remote host without installing the scanner there:

   ```bash
   oscap-ssh root@10.0.0.31 22 xccdf eval --profile "$PROF" \
     --report /var/log/hids-lab/remote-report.html "$DS"
   ```

8. Tailor the profile instead of arguing with it — deviations belong in a tailoring file, under version control:

   ```bash
   oscap info --profile "$PROF" "$DS" | head -20
   # produce a tailoring file with SCAP Workbench or autotailor, then:
   oscap xccdf eval --tailoring-file /etc/scap/lab-tailoring.xml \
     --profile xccdf_org.ssgproject.content_profile_cis_server_l1_customized "$DS"
   ```

**Verify your understanding**

- **Q8.1** — Define XCCDF, OVAL, CPE and ARF, and state which one answers "*is this rule satisfied on this machine right now*" versus "*which rules make up this policy*".
- **Q8.2** — `oscap xccdf eval` returned `exit=2`. What does 2 mean, and how must a cron/CI wrapper treat exit codes 0, 1 and 2 differently?
- **Q8.3** — A rule reports `notapplicable`. What produced that verdict, and why is it *not* the same as `pass`? Name the other result values you must be able to distinguish.
- **Q8.4** — Contrast Step 3 (XCCDF profile eval) with Step 6 (OVAL feed eval). Both say "the host is non-compliant" — but they answer different questions. Which one would flag an unpatched CVE in `openssl`, and which would flag `PermitRootLogin yes`?
- **Q8.5** — Why is `oscap xccdf eval --remediate` dangerous on a running production host, and what is the safer three-step workflow using the same content?
- **Q8.6** — Your organisation cannot comply with 6 of 240 CIS rules. Why is a tailoring file the correct mechanism, rather than editing the SSG data stream or filtering the report?

---

## Exercise 9 — Capstone: simulated intrusion and cross-tool correlation

*All four baselines (audit rules, AIDE DB, rkhunter dat, ClamAV sigs) must be current and taken from a clean state before you start.*

1. Confirm you have a clean starting point:

   ```bash
   aide --check >/dev/null 2>&1; echo "aide=$?"
   rkhunter --check --sk --rwo >/dev/null 2>&1; echo "rkhunter=$?"
   auditctl -s | head -1
   ```

2. Introduce four artefacts, each of which is visible to a *different* subset of the tools:

   ```bash
   # A) hidden setuid-root shell
   install -m 4755 -o root -g root /bin/dash /usr/local/bin/.sysupd

   # B) second UID 0 account
   useradd -o -u 0 -g 0 -M -d /root -s /bin/bash svcops

   # C) EICAR test file disguised as an upload
   printf '%s\n' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
     > /var/www/html/uploads/thumb.php

   # D) weakened SSH policy
   sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

   # E) execute the planted binary from an unprivileged login session
   ssh alice@localhost '/usr/local/bin/.sysupd -c id'
   ```

3. Run every detector and capture the output:

   ```bash
   ausearch -k identity   --start recent -i | grep -E 'passwd|shadow|group' | tail -3
   ausearch -k setuid_exec --start recent -i | tail -3
   aide --check | sed -n '/Summary:/,/^$/p'
   rkhunter --check --sk --rwo
   chkrootkit -q
   maldet -a /var/www/html/
   oscap xccdf eval --rule xccdf_org.ssgproject.content_rule_sshd_disable_root_login \
     --profile "$PROF" "$DS" | grep -A1 '^Rule'
   awk -F: '$3==0 {print $1}' /etc/passwd
   ```

4. Build the correlation matrix yourself before reading the answer — for each artefact A–D, mark which tool detected it and *what evidence* it produced:

   | Artefact | audit | AIDE | rkhunter | chkrootkit | maldet | OpenSCAP |
   |---|---|---|---|---|---|---|
   | A. setuid `/usr/local/bin/.sysupd` | | | | | | |
   | B. UID 0 account `svcops` | | | | | | |
   | C. EICAR in web root | | | | | | |
   | D. `PermitRootLogin yes` | | | | | | |

5. Clean up and — critically — rebuild the baselines **in the right order**:

   ```bash
   userdel svcops
   rm -f /usr/local/bin/.sysupd /var/www/html/uploads/thumb.php /var/www/html/uploads/avatar.php
   sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
   systemctl reload ssh 2>/dev/null || systemctl reload sshd

   aide --check                       # MUST be clean-except-expected before the next line
   aide --update && mv -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db
   rkhunter --propupd
   ```

6. Assemble the nightly harness that turns all of this into one auditable artefact:

   ```bash
   cat > /usr/local/sbin/hids-nightly <<'EOF'
   #!/bin/bash
   # Nightly host intrusion detection sweep. Exit non-zero if any detector fires.
   set -u
   TS=$(date +%F_%H%M)
   OUT=/var/log/hids-lab/sweep-$TS
   install -d -m 0750 "$OUT"
   rc=0

   aide --check                > "$OUT/aide.txt"       2>&1; a=$?;  [ $a -ne 0 ] && rc=1
   rkhunter --check --sk --rwo > "$OUT/rkhunter.txt"   2>&1; r=$?;  [ $r -ne 0 ] && rc=1
   chkrootkit -q               > "$OUT/chkrootkit.txt" 2>&1
   [ -s "$OUT/chkrootkit.txt" ] && rc=1
   maldet -b -a /var/www/html/ > "$OUT/maldet.txt"     2>&1
   oscap xccdf eval --profile "$PROF" --results-arf "$OUT/arf.xml" \
         --report "$OUT/report.html" "$DS" > "$OUT/oscap.txt" 2>&1
   o=$?; [ $o -eq 2 ] && rc=1
   aureport -k --summary --start yesterday > "$OUT/audit-keys.txt" 2>&1

   printf 'aide=%s rkhunter=%s oscap=%s\n' "$a" "$r" "$o" | \
     logger -t hids-nightly -p auth.notice
   # Push the evidence off-host immediately; a local-only report is an attacker's edit target.
   rsync -a --remove-source-files "$OUT" evidence@10.0.0.20:/srv/hids/"$(hostname -s)"/
   exit $rc
   EOF
   chmod 0700 /usr/local/sbin/hids-nightly
   ```

   ```bash
   cat > /etc/systemd/system/hids-nightly.service <<'EOF'
   [Unit]
   Description=Nightly host intrusion detection sweep
   After=network-online.target auditd.service

   [Service]
   Type=oneshot
   ExecStart=/usr/local/sbin/hids-nightly
   Nice=19
   IOSchedulingClass=idle
   EOF

   cat > /etc/systemd/system/hids-nightly.timer <<'EOF'
   [Unit]
   Description=Run the HIDS sweep nightly

   [Timer]
   OnCalendar=*-*-* 02:30:00
   RandomizedDelaySec=1800
   Persistent=true

   [Install]
   WantedBy=timers.target
   EOF

   systemctl daemon-reload
   systemctl enable --now hids-nightly.timer
   systemctl list-timers hids-nightly.timer
   ```

**Verify your understanding**

- **Q9.1** — Fill in the matrix from Step 4 and, for each empty cell, state *why* that tool is structurally blind to that artefact.
- **Q9.2** — Artefact A was executed by `alice` via SSH. Which audit key fired, and which single field in the `SYSCALL` record ties the root-privileged execution back to the human account despite `uid=0`?
- **Q9.3** — In Step 5, why must `aide --check` be reviewed *before* `aide --update`, and `rkhunter --propupd` run only after you are satisfied the host is clean? What is the failure mode if you reverse it?
- **Q9.4** — The harness does `rsync --remove-source-files` to a remote evidence host. Give two distinct security reasons, and name the equivalent mechanism for the audit logs themselves.
- **Q9.5** — The timer sets `RandomizedDelaySec=1800` and `Nice=19`/`IOSchedulingClass=idle`. One of those is an operational concession and one has a security consequence. Which is which, and what is the consequence?
- **Q9.6** — Every tool here detects *state*, except one that detects *events*. Identify it and explain why an attacker who compromises the host at 03:00 and removes their tooling at 03:40 is invisible to the others but not to it — and what configuration would make even that one blind.

---

## Answers

<details>
<summary><strong>Click to expand — answers to all comprehension questions</strong></summary>

### Exercise 1

**A1.1** — With `enabled 0` the kernel does not evaluate audit rules at all, so no syscall records are produced; the few records the kernel still emits internally (e.g. `AUDIT_CONFIG_CHANGE`, early boot messages) go to the kernel ring buffer and end up in `dmesg`/journald via `printk`, not in `/var/log/audit/audit.log`. The `audit=1` kernel parameter turns the subsystem on **from the very first instruction of userspace**, closing the window between `init` starting and `auditd` starting — during which, without it, the kernel is in the "auditing disabled until a userspace daemon asks for it" state. `audit=0` is the reverse: it disables the subsystem so completely that `auditd` cannot enable it without a reboot.

**A1.2** — `lost` counts audit records the kernel generated but could **not** hand to userspace because the backlog queue was full. It is a silent detection gap: an attacker who can generate audit noise (a `find` over `/etc`, a fork bomb) can push their own actions out of the queue. It is a kernel counter because the records never reached `auditd` — by definition they cannot appear in `audit.log`. `lost` must be monitored and alerted on; a rising `lost` is itself an indicator of compromise.

**A1.3** — `auditctl -f 2` (`failure = 2`, panic). Values are `0` silent, `1` printk (default), `2` kernel panic. It is what STIG/CIS profiles require for high-assurance systems, and the production risk is exactly what it says: a full disk or a misconfigured rule that overwhelms the queue takes the machine down hard. It converts a confidentiality/accountability problem into an availability problem — which is the correct trade only when the policy explicitly demands it.

**A1.4** — `-b 8192` in `audit.rules` is applied when `auditd`/`augenrules` runs, i.e. late in boot. The kernel's default backlog before that point is tiny (64 entries), so with `audit=1` enabled at boot every early-boot syscall event competes for 64 slots and the excess is lost. `audit_backlog_limit=8192` on the kernel command line raises the limit for the boot window itself.

### Exercise 2

**A2.1** — They are the *same* mechanism: `auditctl` translates `-w path -p perms -k key` into an `always,exit` syscall rule with a `path`/`dir` field. The watch is on the **inode**, not the name (a directory watch is on the subtree). So an editor that writes `/etc/shadow.tmp` and `rename()`s it over `/etc/shadow` replaces the inode, and the watch now points at an inode that no longer has that name — the audit subsystem re-resolves watches on directory operations, but the reliable way to survive this is to watch the *parent directory* (`-w /etc/ -p wa`) or use an explicit `-F dir=/etc/` rule rather than relying on the single-file watch.

**A2.2** — `auid` (loginuid) is the identity of the human who originally logged in, propagated to every descendant process and **not** changed by `su`/`sudo`. It is set by the `pam_loginuid` PAM module at login time; on kernels with `CONFIG_AUDIT_LOGINUID_IMMUTABLE` (or when `auditctl -s` shows `loginuid_immutable 1 locked`) it can never be reset once set. `auid=4294967295` is `(uid_t)-1`, "unset" — processes started by the init system or by daemons with no login session. `-F auid>=1000 -F auid!=unset` therefore means "actions traceable to a real, non-system human login", excluding both system accounts and daemons. Writing only `-F auid>=1000` would match the unset value too, since `4294967295 >= 1000`.

**A2.3** — On x86_64 the kernel supports 32-bit compat syscalls, and the syscall *numbers differ between the two ABIs* (`execve` is 59 on b64 and 11 on b32). A rule written only for `arch=b64` is trivially bypassed by invoking a 32-bit binary. Writing both is mandatory unless 32-bit emulation is compiled out, in which case the b32 rules are simply rejected at load time.

**A2.4** — Not a problem here: `exclude` is a **separate filter list** from `exit`, and rules are matched first-match-wins *within* a list, so an `exclude`-list rule never competes with `exit`-list rules regardless of file position. Placement bites you within a single list — e.g. an `-a never,exit` suppression rule placed *after* a broad `-a always,exit` rule never fires, because the `always` rule matched first. Ordering also matters across files: `augenrules` concatenates `/etc/audit/rules.d/*.rules` in lexical order, which is why `-e 2` lives in `99-finalize.rules`.

**A2.5** — With `enabled 2` the ruleset is locked in the kernel until reboot; `auditctl` add/delete/`-e` operations return `EPERM`, and each attempt generates a `CONFIG_CHANGE` audit record — so the tampering attempt is itself evidence. Your options are: fix the file in `/etc/audit/rules.d/` and **reboot**. That is precisely the point: an attacker who reaches root cannot quietly disable auditing to cover the rest of the intrusion; they must reboot the box, which is loud. Note that read operations (`auditctl -l`, `auditctl -s`) still work.

**A2.6** — It catches a process whose real UID differs from its effective UID of 0 calling `execve` — i.e. an unprivileged user executing something through a setuid-root binary, the standard privilege-escalation primitive (a vulnerable setuid helper, or a planted setuid shell as in Exercise 9).

### Exercise 3

**A3.1** — `RAW` records store numeric UIDs, GIDs and syscall numbers, which are only meaningful relative to the `/etc/passwd`, `/etc/group` and kernel ABI **of the machine that produced them**. Once shipped to a collector — or read from a container image with a different user database, or read after the account was deleted — `uid=1000` cannot be resolved. `ENRICHED` appends the resolved names (`UID="root"`, `AUID="alice"`, `SYSCALL=openat`, `ARCH=x86_64`) at the moment of logging, when the mapping is still authoritative.

**A3.2** — `space_left_action` fires at the *warning* threshold (`space_left`, in MB) — normally `EMAIL` or `SYSLOG`, a heads-up. `admin_space_left_action` fires at the *critical* threshold and is the last chance to act — `SINGLE` (drop to single-user mode) or `HALT` for high-assurance systems. `disk_full_action` fires when the partition is actually full. The dangerous one is any of them set to `IGNORE` or `SYSLOG`: the machine keeps running and serving traffic while audit records are being dropped — up, reachable, and blind. `SUSPEND` stops the daemon writing but leaves the system running, which is the same failure with extra steps unless you alert on it.

**A3.3** — Worst case is `num_logs × max_log_file` = 10 × 64 MB = 640 MB, plus the active file. With `ROTATE`, when `audit.log.10` would be created the oldest is **deleted** — data loss by design. If an external archiver rotates and ships the logs, set `max_log_file_action = KEEP_LOGS`, which rotates without ever deleting and lets the external process own retention (at the cost of unbounded growth if that process fails, so pair it with `space_left_action`).

**A3.4** — (1) Fewer moving parts in the trust path: no syslog daemon to compromise, restart, or misconfigure between the kernel and the file, and the file is `0600 root:root` in a dedicated directory that can be a separate partition. (2) Guaranteed delivery semantics and back-pressure: `auditd` can be told (via `flush`/`freq` and the `failure`/`disk_full_action` settings) to panic, halt, or suspend rather than drop a record — syslog's UDP/best-effort path has no such guarantee, and rsyslog would silently discard on queue overflow. A third: audit records have their own format and sequence numbers (`msg=audit(ts:serial)`) that let `ausearch` reassemble a multi-record event, which a syslog line-oriented pipeline mangles.

### Exercise 4

**A4.1** — `S` checks for a *growing* size: it flags the file only if it **shrank** (or otherwise changed inconsistently with append-only behaviour), and tolerates growth. Log files legitimately grow every minute, so a plain `s` (exact size) rule would produce a report full of noise, which trains the operator to ignore it. What `S` catches is **log truncation or selective deletion** — the classic anti-forensic step after an intrusion.

**A4.2** — `mtime` is the last content-modification time and is freely settable by any process that owns the file (`touch -d`, `utimensat`). `ctime` is the inode-change time and is maintained by the kernel; it is updated whenever the inode changes — including when `mtime` itself is set. There is no portable syscall to backdate `ctime` short of writing to the raw device. So `ctime` changing while `mtime` moved *backwards* is a signature of deliberate timestamp forgery, and `c` belongs in every integrity rule group.

**A4.3** — AIDE's exit status is a bitmask: bit 0 (1) = new files, bit 1 (2) = removed files, bit 2 (4) = changed files. 7 = 1+2+4 — but here only "added" and "changed" were reported, so on this version the value reflects the bits that were set for the categories present; the operational rule is **decode bits, never test for a specific number**. Larger values (14–18) are *errors*, not findings: 14 write error, 15 usage/command-line error, 16 config error, 17 I/O error, 18 version mismatch. A cron wrapper that treats "non-zero" as "intrusion detected" will page you for a typo in the config, and — worse — a wrapper that tests `[ $? -eq 7 ]` will report "clean" when AIDE failed to run at all.

**A4.4** — `COPYNEWDB=yes` makes the daily job overwrite the reference database with the newly-observed state after each run. Every change is therefore accepted automatically and reported exactly once, so a slow, patient attacker who modifies one file per night is baselined into legitimacy. It is acceptable only on a host where a separate, trusted change-management pipeline is the source of truth and the AIDE report is genuinely read by a human every single day — in practice, treat it as off.

**A4.5** — An attacker with root can simply run `aide --update` (or edit/replace the DB) after planting their files; the next check reports clean. Mitigations: **(1)** keep the database off-host — on read-only media, an NFS export mounted read-only, or fetched at check time from a management server — and record the DB's own SHA-512 somewhere out of band (Step 4). **(2)** Run the check itself from outside the running system: boot rescue media or take a storage-level snapshot and run AIDE against the mounted filesystem, so a kernel-level rootkit cannot lie to the scanner about what is on disk. A third: sign the database with GPG and verify the signature with a key that is not on the host.

**A4.6** — The order matters because rule groups are evaluated per-path and AIDE applies the **most specific matching rule**; a broad `/usr` rule declared after a specific `/usr/bin/` rule does not silently override it, but a misordered `!` exclusion or an over-broad `=` (non-recursive) rule can exclude a subtree you believed was covered — hence `aide --config-check` and spot-verification of coverage. Between `sha256` and `sha512` the security difference is negligible for this purpose; each additional algorithm is another full read and hash of every file in the tree, multiplying scan wall-time and I/O on a large filesystem. One strong hash plus the metadata attributes is the right configuration.

### Exercise 5

**A5.1** — `--propupd` reads the current on-disk properties (permissions, ownership, size, timestamps, inode, hashes) of every file in `rkhunter`'s list and writes them to `/var/lib/rkhunter/db/rkhunter.dat` as the *reference* baseline. Running it on a compromised host records the attacker's trojaned binaries as the known-good state — you have not merely failed to detect the intrusion, you have permanently certified it. This is the same class of mistake as `aide --update` on a dirty host, and it is why both must be gated on a reviewed, clean check.

**A5.2** — `APT_AUTOGEN="yes"` prevents the flood of "file properties have changed" warnings after every legitimate package upgrade. The gap it opens: any file change made *during the same window* as a package transaction — or by an attacker who simply triggers an `apt` operation — is silently absorbed into the baseline. The better answer is `PKGMGR=DPKG` (or `RPM`): rkhunter then validates file properties against the **package manager's own database** of hashes rather than a snapshot it took itself, so a legitimately upgraded file verifies automatically while a tampered one does not. Its limitation is that it only covers files that belong to a package — locally installed binaries, `/usr/local`, and the package database itself are outside its reach (and a root-level attacker can tamper with the dpkg/rpm DB too).

**A5.3** — `--update` fetches **rkhunter's own data files** (`mirrors.dat`, `programs_bad.dat`, `backdoorports.dat`, `suspscan.dat`, i18n) from the project mirrors — this is the signature/knowledge update, analogous to an AV definition update. `--propupd` regenerates the **local file-properties baseline** from this host's current filesystem. Confusing them is destructive in one direction: running `--propupd` when you meant `--update` overwrites your baseline with current (possibly compromised) state; running `--update` when you meant `--propupd` is harmless but leaves you with a warning flood after upgrades.

**A5.4** — The Linux Audit framework. rkhunter reports the *state* ("this user exists now"); audit holds the *event*. Query it by the identity key and by the account-management syscalls:
`ausearch -k identity -i --start yesterday`, `ausearch -m ADD_USER,USER_MGMT -i`, or `ausearch -x /usr/sbin/useradd -i`. The `auid` and `ses` fields in the returned record tell you which human login session created the account, and `PROCTITLE`/`EXECVE` records give the exact command line.

**A5.5** — Both check for **userland** hijacking of dynamic linking: `/etc/ld.so.preload` and `LD_PRELOAD` are the standard mechanism for LD_PRELOAD rootkits (Azazel, Jynx, bedevil) that interpose on `readdir`, `open`, `accept` and friends to hide files, processes and connections; `strings` comparison catches trojaned system binaries carrying known rootkit artefacts. What this structurally fails to detect is a **kernel-mode rootkit** (LKM or one loaded via `/dev/kmem`/eBPF) that hooks syscalls below the libc layer: such a rootkit lies to `rkhunter` itself about what files exist and what their contents are, so every userland check returns a clean, forged answer. That is the argument for offline scanning, kernel module lockdown (`kernel.modules_disabled=1`, Secure Boot + signed modules), and the `-w`/`init_module` audit rules from Exercise 2.

### Exercise 6

**A6.1** — chkrootkit's SucKIT test looks for characteristics of that rootkit in `/sbin/init` (an unusual inode/size relationship and byte patterns). systemd's `/sbin/init` is a symlink into a large, very different binary from the sysvinit it was written against, so the heuristic fires. The general lesson: chkrootkit's signature and heuristic set targets rootkits from the 1999–2010 era and its tests were calibrated against the distributions of that time. On a modern system its output is dominated by false positives, which makes it useful as a **corroborating** second opinion but useless as a primary alerting source — hence the targeted `grep -v` suppression in the cron wrapper rather than blanket trust.

**A6.2** — `-p` supplies an alternative `PATH` for the external binaries chkrootkit itself calls (`awk`, `sed`, `head`, `ls`, `ps`, `strings`, `netstat`). `-r` points the scan at a different root, typically a suspect filesystem mounted read-only under `/mnt`. The threat model is that a rootkit trojans exactly those utilities: if chkrootkit runs `ps` and `ls` from the compromised `PATH`, the rootkit's replacements simply omit the attacker's processes and files, and chkrootkit dutifully reports "not infected" based on forged input. Running it live against its own `PATH` is therefore asking the suspect to testify. The rigorous form is: boot known-good media, mount the suspect FS read-only, and run `chkrootkit -r /mnt -p <trusted bin dirs>` with statically linked trusted binaries.

**A6.3** — (1) A packet-capture or IDS process is legitimately running (`tcpdump`, `wireshark`, Suricata/Snort/Zeek on a monitoring host). (2) The interface is enslaved to a bridge or bond, or is the underlying NIC of a virtualisation host (`virbr0`, Open vSwitch, macvtap) — bridging requires promiscuous mode. NetworkManager and libvirt commonly trigger this on hypervisors and workstations.

**A6.4** — They fail differently. chkrootkit uses hard-coded signature/heuristic tests plus its own `chkproc`/`chkdirs`/`chkutmp` binaries that compare `/proc` against `ps` output and `utmp` against `who` — detecting *hidden processes and hidden login sessions* by cross-checking two sources. rkhunter is primarily a file-properties/configuration auditor with a much larger and actively-updated rootkit name list. A rootkit that hides a running process but leaves file properties intact is chkrootkit's case; a trojaned binary with no running component is rkhunter's. Independent implementations also mean an evasion tuned against one does not automatically defeat the other.

### Exercise 7

**A7.1** — `{CAV}` means the detection came from the **ClamAV** engine using ClamAV's signature database (`Win.Test.EICAR_HDB-1` is a ClamAV signature name). `{HEX}` marks a hit from LMD's own hex-pattern signature set, and `{MD5}` from its MD5 known-malware list; `{YARA}` from its YARA rules. The prefix tells you which database to consult when triaging a false positive and which update command (`freshclam` vs `maldet -u`) refreshes it.

**A7.2** — On a suspected-compromised production server, quarantine **destroys evidence in place**: it moves the file, changing its path and timestamps, and `quarantine_clean` rewrites the file contents to strip the injected payload — obliterating the attacker's code before you have imaged it, hashed it, or determined the initial access vector. Detect-first preserves the crime scene and lets you decide. The opposite setting is correct on **shared hosting or a multi-tenant upload endpoint at scale**, where you have hundreds of user-writable webroots, cannot triage each hit by hand, and the priority is stopping active PHP shells now; there `quarantine_hits=1`, `quarantine_clean=1` and `quarantine_suspend_user=1` are the intended operating mode LMD was written for.

**A7.3** — LMD's signatures come from real-world captures at network edges and shared hosting, so it is strongest precisely where AIDE is weakest: **user-writable content that has no baseline** — uploaded PHP web shells, injected JavaScript, obfuscated backdoors in `/var/www`, `/tmp`, `/home`. AIDE can only tell you that a file it already knows about changed, or that a file appeared in a monitored path; it says nothing about whether a *new, expected-to-be-new* file is malicious. maldet therefore belongs on the content tier — web roots, upload directories, mail spools — while AIDE covers the immutable system tier, and the two should never be pointed at the same paths.

**A7.4** — `--monitor` uses inotify to scan files **at the moment they are created or modified**, closing the window between an upload and the nightly scan; a shell uploaded at 09:00 is caught at 09:00 instead of at 02:30 the next morning. The limit is `fs.inotify.max_user_watches` (and `max_user_instances`): inotify needs one watch per directory, so a deep tree with tens of thousands of directories exhausts the default (often 8192 or 65536) and monitoring silently degrades. Raise it via `sysctl fs.inotify.max_user_watches=524288` in `/etc/sysctl.d/`, and monitor only the directories that actually accept untrusted writes.

**A7.5** — Performance: `clamscan` is a compiled C engine that loads the signature database once and streams files past it, whereas LMD's native scanner shells out per-file — the difference on a large webroot is minutes versus hours, which is what determines whether the scan finishes inside its cron window at all. Coverage: with the ClamAV engine active you get ClamAV's full database (~8.7 million signatures, updated multiple times daily by `freshclam`) **in addition to** LMD's own set, rather than LMD's ~17,000 alone.

### Exercise 8

**A8.1** — **XCCDF** (eXtensible Configuration Checklist Description Format) is the *policy* language: benchmarks, profiles, rules, titles, rationale, severity, and which check to invoke — it answers "which rules make up this policy". **OVAL** (Open Vulnerability and Assessment Language) is the *check* language: the machine-readable logic that inspects the system state (does this file contain this regex, is this RPM at this version) — it answers "is this rule satisfied on this machine right now". **CPE** (Common Platform Enumeration) is a naming scheme for platforms, used for applicability: it tells the scanner "this rule applies only to RHEL 9" so an inapplicable rule is reported as `notapplicable` rather than `fail`. **ARF** (Asset Reporting Format) is the *results* container that bundles the assessed asset's identity, the evaluated content, and the results — the artefact you archive and feed to a compliance system.

**A8.2** — `oscap xccdf eval` exit codes: **0** = the scan ran and *all* selected rules passed; **1** = the scanner itself errored (bad profile ID, unreadable content, XML error) — no verdict was reached; **2** = the scan ran successfully and *at least one rule failed*. A wrapper must treat them as three distinct states: 0 → compliant; 2 → non-compliant, parse the ARF and report findings; 1 → **operational alarm**, because a naive `if [ $? -ne 0 ]; then alert "non-compliant"` masks a scanner that has not run for weeks behind a "non-compliant" ticket nobody investigates, and `if [ $? -eq 2 ]` alone reports nothing at all when the scanner is broken.

**A8.3** — `notapplicable` means the rule's CPE applicability test did not match this platform — e.g. an SELinux rule on a Debian host, or an `nftables` rule on a system where the package is absent. It is not `pass`: nothing was verified, and the underlying risk may be present by some other route or the platform check may be wrong. The other values you must distinguish: `pass`, `fail`, `error` (the check could not execute — a broken probe, a permission problem), `unknown` (the check ran but could not determine a result), `notchecked` (the rule has no check attached), `notselected` (the rule exists in the benchmark but is not part of the chosen profile), `informational` (reported for context, never fails), and `fixed` (failed, then successfully remediated in a `--remediate` run). Compliance percentages that lump `notapplicable`/`notchecked` in with `pass` are how a 40%-compliant host reports 95%.

**A8.4** — Step 6, the OVAL feed from the vendor (`rhel-9.oval.xml`), flags the unpatched `openssl` CVE: it is a definition set that maps CVE/RHSA identifiers to "package X is installed at a version lower than Y". Step 3, the XCCDF profile evaluation, flags `PermitRootLogin yes`: it is a *configuration hardening* checklist. A host can be fully patched and catastrophically misconfigured, or perfectly hardened and running a vulnerable library — you need both scans, and they use different content from different publishers on different update cadences.

**A8.5** — `--remediate` executes the remediation scripts embedded in the content immediately, in bulk, as root, with no review and no ordering guarantees relative to your configuration management. On a running production host that means restarted services, rewritten `sshd_config` (potentially locking you out), changed `pam` stacks, tightened `mount` options, and package removals — some of which will break the application the host exists to run. The safer workflow: **(1)** `oscap xccdf eval --results-arf` to assess and record; **(2)** `oscap xccdf generate fix --fix-type bash|ansible --result-id ...` from that ARF, so you generate remediation for *only the rules that actually failed*; **(3)** review the generated content, put it under version control, and apply it through your normal change process on a staging host first — then re-scan to confirm `fixed`.

**A8.6** — A tailoring file is a separate XCCDF document that derives a new profile from the upstream one, recording exactly which rules are deselected or which variable values are changed, **with the original content left untouched**. That gives you: an auditable, diffable record of every deviation and its justification; upstream SSG updates that you can consume without re-applying local edits; and reproducibility across hosts. Editing the data stream forks the content — the next `dnf update scap-security-guide` silently discards your changes, or worse, doesn't and you drift. Filtering the report is not a control at all: the rule still fails, you have simply stopped looking at it, and the next auditor who runs the unmodified profile finds all six.

### Exercise 9

**A9.1** —

| Artefact | audit | AIDE | rkhunter | chkrootkit | maldet | OpenSCAP |
|---|---|---|---|---|---|---|
| A. setuid `/usr/local/bin/.sysupd` | ✔ `setuid_exec` / `rootcmd` key on execution | ✔ added entry under `/usr/local/bin/` | ✔ hidden file + suspicious file properties | ~ only if it matched a signature | ✘ | ~ only if a "no unauthorised setuid files" rule is in the profile |
| B. UID 0 account `svcops` | ✔ `identity` key, `ADD_USER`/`USER_MGMT` | ✔ `/etc/passwd`, `/etc/shadow` changed | ✔ "passwd file changes" + UID 0 account test | ✘ | ✘ | ✔ "no duplicate/unauthorised UID 0 accounts" rule |
| C. EICAR in web root | ~ only if a watch covers `/var/www` | ✘ (webroot is deliberately not baselined) | ✘ | ✘ | ✔ `{CAV}` hit | ✘ |
| D. `PermitRootLogin yes` | ✔ if `/etc/ssh/` is watched | ✔ `/etc/ssh/sshd_config` changed | ✔ `ALLOW_SSH_ROOT_USER=no` test | ✘ | ✘ | ✔ `sshd_disable_root_login` → fail |

The blind spots are structural, not accidental: **maldet** only sees files matching malware signatures, so a legitimate binary (`dash`) copied to a new path is invisible to it. **AIDE** only sees paths it baselined, and web roots are excluded precisely because they change constantly — so C is outside its universe. **chkrootkit** looks for named rootkits and hidden processes/sessions, none of which these artefacts are. **OpenSCAP** evaluates policy, not novelty: it will never tell you a *new* file appeared, only that a state it has a rule about is wrong. **audit** sees only what its rules cover, and only at the moment the action occurs. This is the entire argument for running all of them: each tool's blind spot is another tool's core competency.

**A9.2** — The `setuid_exec` key fired (real UID `alice` ≠ effective UID 0 on `execve`), and `rootcmd` fired for the same reason (`euid=0`, `auid>=1000`). The field that ties it back is **`auid`** (loginuid): the record shows `uid=1000 euid=0 auid=1000 ses=N`, so even though the process ran as root, `auid=1000` names the human login that started the chain, and `ses` groups every action from that same login session. This is the whole reason `auid` exists and why `pam_loginuid` plus immutable loginuid matter — without them the record would read `uid=0` and tell you nothing.

**A9.3** — `aide --update` and `rkhunter --propupd` both mean "**everything I see right now is correct**". If you run them before reviewing the check output, you promote whatever is currently on disk — including anything the attacker left behind that you have not yet found — into the trusted baseline, permanently. The correct sequence is: run the check → read every difference → account for each one (package upgrade, your own cleanup, expected config change) → only then update. Reverse it and you have destroyed your own detection capability for that artefact forever; the tool will report clean on every subsequent run and you will never know why.

**A9.4** — (1) **Integrity of the evidence**: a report stored on the host it describes can be edited or deleted by the same root-level attacker the report describes. Off-host storage with append-only or WORM semantics means the attacker must also compromise the evidence server to hide. (2) **Availability of the evidence**: if the incident ends with the host being wiped, reimaged, or simply crashing, locally-stored reports go with it — and `--remove-source-files` additionally means a failed transfer leaves the data visibly stuck rather than silently duplicated. The equivalent mechanism for audit logs is the **`au-remote` audisp plugin / `audisp-remote`** shipping records over the network to a central `auditd` (Exercise 3, Step 4), with `network_failure_action` deciding what happens when the collector is unreachable.

**A9.5** — `Nice=19` / `IOSchedulingClass=idle` is the **operational concession**: a full AIDE + rkhunter + OpenSCAP sweep is I/O-brutal, and de-prioritising it keeps it from degrading the service the host actually runs (at the cost of a longer scan). `RandomizedDelaySec=1800` has the **security consequence**: its purpose is to avoid a thundering herd of hundreds of hosts hammering the evidence server and signature mirrors at exactly 02:30 — but a *predictable* scan time is also something an attacker can work around, doing their work at 03:00 and cleaning up before the next window. Randomisation narrows that planning window; it does not close it, which is why event-based detection (audit, inotify) is not optional.

**A9.6** — The **Linux Audit framework** is the only event-based detector here; AIDE, rkhunter, chkrootkit, maldet and OpenSCAP all compare *current state* against a reference, so anything created and removed between two runs leaves no state to compare and is invisible to every one of them. Audit records the `execve`, the `open`, the `unlink` and the `useradd` at the instant they happen, and those records are already on disk (or already shipped off-host) before the attacker cleans up. What would blind even audit: **(a)** no rule covering the relevant syscall or path — audit only sees what you told it to watch; **(b)** `enabled 0` / a stopped daemon, or a mutable ruleset the attacker can flush with `auditctl -D` — which is exactly what `-e 2` in `99-finalize.rules` prevents; **(c)** a full backlog queue driving `lost` upward, so records are dropped before they are written; and **(d)** logs written only locally, where root can truncate `audit.log` — which is what `audisp-remote` and `-w /var/log/audit/ -p wa` are for.

</details>

---

## Sources

- LPI — Exam 303 Objectives (303-300, v3.0.0): <https://www.lpi.org/our-certifications/exam-303-objectives/>
- Linux Audit userspace (`auditd`, `auditctl`, `ausearch`, `aureport`): <https://github.com/linux-audit/audit-userspace>
- Linux Audit documentation wiki: <https://github.com/linux-audit/audit-documentation/wiki>
- Red Hat Enterprise Linux 9 — Security hardening: auditing the system: <https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/security_hardening/auditing-the-system_security-hardening>
- AIDE — Advanced Intrusion Detection Environment: <https://aide.github.io/> · manual: <https://aide.github.io/doc/>
- Rootkit Hunter (rkhunter): <https://rkhunter.sourceforge.net/>
- chkrootkit: <https://www.chkrootkit.org/>
- Linux Malware Detect (LMD/maldet), R-fx Networks: <https://www.rfxn.com/projects/linux-malware-detect/>
- ClamAV documentation: <https://docs.clamav.net/>
- OpenSCAP user manual (`oscap`): <https://static.open-scap.org/openscap-1.3/oscap_user_manual.html>
- ComplianceAsCode / SCAP Security Guide content: <https://github.com/ComplianceAsCode/content>
- Local manual pages: `auditctl(8)`, `auditd.conf(5)`, `audit.rules(7)`, `ausearch(8)`, `aureport(8)`, `autrace(8)`, `aide(1)`, `aide.conf(5)`, `rkhunter(8)`, `chkrootkit(8)`, `oscap(8)`