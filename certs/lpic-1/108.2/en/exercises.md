# LPIC-1 — Topic 108.2: System Logging
## Guided Exercises

**Target objective:** LPI 102-500, objective 108.2 — *System logging* (`journalctl`, `systemd-cat`, `/etc/systemd/journald.conf`, `/var/log/journal/`, `systemd-journald`, `/etc/rsyslog.conf`, `logger`, `/var/log/`, and log rotation).

---

## Lab prerequisites

You need a **systemd-based VM with root access** and network reachability to a second host if you want to complete Exercise 6. Snapshot the VM before you start — several steps intentionally break logging so that you can repair it.

The exercises are written to work on both major families. Where they differ:

| | Debian / Ubuntu | RHEL / Rocky / Alma / Fedora |
|---|---|---|
| Catch-all log | `/var/log/syslog` | `/var/log/messages` |
| Authentication log | `/var/log/auth.log` | `/var/log/secure` |
| rsyslog input from journal | `imuxsock` (forwarding socket) | `imjournal` |
| logrotate state file | `/var/lib/logrotate/status` | `/var/lib/logrotate/logrotate.status` |

Confirm your baseline before starting:

```bash
systemctl is-active systemd-journald
systemctl is-active rsyslog 2>/dev/null || echo "rsyslog not installed"
journalctl --version | head -1
```

If `rsyslog` is absent, install it (`apt install rsyslog` / `dnf install rsyslog`) — Exercises 4–6 depend on it.

---

## Exercise 1 — The journal as a structured database

`systemd-journald` is **not** a text-log writer. It stores indexed, binary, key-value records. Understanding that changes how you query it.

### Block 1.1 — Where the journal actually lives

1. Determine the storage mode currently in effect, including every distribution drop-in:

   ```bash
   systemd-analyze cat-config systemd/journald.conf | grep -vE '^\s*(#|$)'
   ```

   Expected output on a stock system (only the section header, i.e. every value is a compiled-in default):

   ```
   [Journal]
   ```

2. Check which of the two possible journal directories exists:

   ```bash
   ls -ld /run/log/journal /var/log/journal 2>&1
   ```

   Typical output on a system with a **volatile** journal:

   ```
   ls: cannot access '/var/log/journal': No such file or directory
   drwxr-sr-x+ 3 root systemd-journal 60 Aug 27 08:41 /run/log/journal
   ```

3. Look at the actual journal files and their ownership:

   ```bash
   ls -lh /run/log/journal/*/ 2>/dev/null || ls -lh /var/log/journal/*/
   ```

   ```
   -rw-r-----+ 1 root systemd-journal 8.0M Aug 27 09:03 system.journal
   -rw-r-----+ 1 root systemd-journal 8.0M Aug 27 08:41 user-1000.journal
   ```

4. Confirm the on-disk footprint reported by journald itself:

   ```bash
   journalctl --disk-usage
   ```

   ```
   Archived and active journals take up 40.0M in the file system.
   ```

> **Check your understanding — Block 1.1**
>
> **Q1.1** The directory `/var/log/journal` does not exist and `Storage=` is unset. Where are log records being written, and what happens to them at the next reboot?
> **Q1.2** `system.journal` is mode `0640`, owner `root`, group `systemd-journal`, and the `+` in the mode string indicates an ACL. Which non-root users can read the *system* journal, and by what mechanism?
> **Q1.3** Why does `du -sh /var/log/journal` sometimes report *less* than `journalctl --disk-usage`?

---

### Block 1.2 — Filtering: the four axes

Every journal query filters on one of four axes: **time**, **unit/identity**, **priority**, or **boot**. Combining them is an AND.

5. Time windows — absolute and relative:

   ```bash
   journalctl --since "2026-08-27 08:00:00" --until "2026-08-27 09:00:00" | wc -l
   journalctl --since "-15min" --no-pager | tail -5
   journalctl --since yesterday --until "today 06:00" -n 20
   ```

6. Identity — a unit, a binary, a PID, a UID:

   ```bash
   journalctl -u sshd.service -n 20 --no-pager
   journalctl _COMM=sudo -n 10 --no-pager
   journalctl _PID=1 -n 5 --no-pager
   journalctl _UID=$(id -u nobody) -n 5 --no-pager
   ```

7. Priority — a threshold, or an explicit range:

   ```bash
   journalctl -p err -b --no-pager        # err(3) and MORE severe: 3,2,1,0
   journalctl -p warning..err -b --no-pager   # exactly 4,3
   journalctl -p 2 -b --no-pager          # crit and above
   ```

8. Boot — the current boot, a previous one, the kernel ring buffer:

   ```bash
   journalctl --list-boots
   journalctl -b -1 -p err --no-pager
   journalctl -k -b --no-pager | head
   ```

   `--list-boots` output:

   ```
   IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
    -1 3f2b1c9a4d7e4f10a2b3c4d5e6f70819 Tue 2026-08-26 07:14:22 UTC Tue 2026-08-26 22:03:57 UTC
     0 a1b2c3d4e5f6470819a2b3c4d5e6f708 Wed 2026-08-27 08:41:09 UTC Wed 2026-08-27 09:12:44 UTC
   ```

9. Discover what is filterable rather than guessing:

   ```bash
   journalctl -N | head -30            # all field names present
   journalctl -F _SYSTEMD_UNIT | sort  # all values seen for that field
   journalctl -F PRIORITY
   ```

> **Check your understanding — Block 1.2**
>
> **Q1.4** `journalctl -p warning` returns entries with `PRIORITY` values 0 through 4. Explain why "warning and above" means *numerically lower*.
> **Q1.5** What is the difference between `journalctl -b -1` and `journalctl --since yesterday`? Give a scenario where they return completely different sets.
> **Q1.6** `journalctl --list-boots` shows only index `0`. What does that tell you about the system's journald configuration?
> **Q1.7** You want every message from the `sshd` binary, including those emitted before `sshd.service` was the owning unit (e.g. during an install script). Would you use `-u sshd` or `_COMM=sshd`? Why?

---

### Block 1.3 — Output formats and trusted fields

10. Inspect one entry in full:

    ```bash
    journalctl -u systemd-logind.service -n 1 -o verbose --no-pager
    ```

    Abridged output:

    ```
    Wed 2026-08-27 08:41:11.238412 UTC [s=9c1e...;i=1a4;b=a1b2...;m=4e21;t=63a1;x=8f2c]
        _BOOT_ID=a1b2c3d4e5f6470819a2b3c4d5e6f708
        _MACHINE_ID=7d0c8e1f2a3b4c5d6e7f8091a2b3c4d5
        _HOSTNAME=lab01
        PRIORITY=6
        SYSLOG_FACILITY=4
        SYSLOG_IDENTIFIER=systemd-logind
        _TRANSPORT=journal
        _UID=0
        _GID=0
        _COMM=systemd-logind
        _EXE=/usr/lib/systemd/systemd-logind
        _CMDLINE=/usr/lib/systemd/systemd-logind
        _SYSTEMD_UNIT=systemd-logind.service
        _SYSTEMD_CGROUP=/system.slice/systemd-logind.service
        _PID=612
        MESSAGE=New session 3 of user root.
    ```

11. Compare the formats you will actually use in scripts and in an incident:

    ```bash
    journalctl -u sshd -n 3 -o cat          # message text only
    journalctl -u sshd -n 3 -o short-iso    # ISO-8601 timestamps
    journalctl -u sshd -n 1 -o json-pretty  # machine-parseable
    journalctl -u sshd -n 3 -o short-precise
    ```

12. Follow a unit live and open the catalog explanations:

    ```bash
    journalctl -u sshd.service -f
    # in a second terminal: systemctl restart sshd ; ssh localhost true
    # Ctrl-C to stop
    journalctl -xb -p err --no-pager
    ```

> **Check your understanding — Block 1.3**
>
> **Q1.8** Fields in the `-o verbose` output split into two classes: those starting with `_` and those that do not. What is the security-relevant difference, and why does it matter when you investigate a suspicious log line?
> **Q1.9** The entry above shows `SYSLOG_FACILITY=4` and `PRIORITY=6`. Translate both into their syslog names, and state what a classic syslog selector matching this message would look like.
> **Q1.10** What does the `-x` in `journalctl -xb` add, and where does that extra text come from?
> **Q1.11** You need to feed journal messages into a text-processing pipeline that expects only the message body. Which output format do you choose, and what information do you lose?

---

## Exercise 2 — Making the journal persistent and bounded

A volatile journal is a production incident waiting to happen: the evidence of the crash dies with the crash.

### Block 2.1 — Switch to persistent storage

1. Create the persistent directory and hand it to journald. **Both methods below are correct; use exactly one.**

   Method A — create the directory (works because the default `Storage=auto` means "persistent *if* `/var/log/journal` exists"):

   ```bash
   mkdir -p /var/log/journal
   systemd-tmpfiles --create --prefix /var/log/journal
   ```

   Method B — declare it explicitly with a drop-in:

   ```bash
   mkdir -p /etc/systemd/journald.conf.d
   cat > /etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
   [Journal]
   Storage=persistent
   EOF
   ```

2. Apply it and force the runtime journal to be migrated to disk:

   ```bash
   systemctl restart systemd-journald
   journalctl --flush
   ls -ld /var/log/journal/$(cat /etc/machine-id)
   ```

   ```
   drwxr-sr-x+ 2 root systemd-journal 4096 Aug 27 09:20 /var/log/journal/7d0c8e1f2a3b4c5d6e7f8091a2b3c4d5
   ```

3. Verify permissions were set correctly by `systemd-tmpfiles` (this is the step people skip, and then journald silently refuses to write):

   ```bash
   getfacl /var/log/journal/$(cat /etc/machine-id) | grep -E 'group:(adm|wheel)'
   ```

   ```
   group:adm:r-x
   default:group:adm:r-x
   ```

4. Reboot and prove persistence:

   ```bash
   systemctl reboot
   # after login:
   journalctl --list-boots
   ```

> **Check your understanding — Block 2.1**
>
> **Q2.1** `Storage=` accepts `volatile`, `persistent`, `auto`, and `none`. Describe the behaviour of each, and say which one makes `/var/log/journal` mandatory rather than optional.
> **Q2.2** You created `/var/log/journal` with a plain `mkdir` and restarted journald, but `journalctl --list-boots` still shows only the current boot after a reboot. Name two independent causes and the command that distinguishes them.
> **Q2.3** What is the functional difference between `journalctl --flush`, `journalctl --sync`, and `journalctl --rotate`?
> **Q2.4** Why does `Storage=none` still leave `journalctl -f` producing output for some messages?

---

### Block 2.2 — Bound the journal so it cannot fill `/var`

5. Set explicit limits. Note that **size limits and time limits are independent ceilings — whichever triggers first wins**:

   ```bash
   cat > /etc/systemd/journald.conf.d/20-limits.conf <<'EOF'
   [Journal]
   SystemMaxUse=500M
   SystemKeepFree=1G
   SystemMaxFileSize=50M
   SystemMaxFiles=20
   MaxRetentionSec=1month
   MaxFileSec=1day
   Compress=yes
   EOF
   systemctl restart systemd-journald
   ```

6. Watch journald report the effective ceiling it computed:

   ```bash
   journalctl -u systemd-journald -b -n 20 --no-pager | grep -i 'journal.*limit\|space'
   ```

   ```
   systemd-journald[318]: System journal (/var/log/journal/7d0c…) is currently using 48.0M.
   Maximum allowed usage is set to 500.0M.
   Leaving at least 1.0G free (of currently available 12.4G of disk space).
   Enforced usage limit is 500.0M, of which 452.0M are still available.
   ```

7. Reclaim space manually — the three vacuum modes:

   ```bash
   journalctl --vacuum-size=200M
   journalctl --vacuum-time=7d
   journalctl --vacuum-files=5
   ```

   ```
   Deleted archived journal /var/log/journal/7d0c…/system@0005e1….journal (8.0M).
   Vacuuming done, freed 24.0M of archived journals from /var/log/journal/7d0c….
   ```

8. Control rate limiting, which is a very common cause of "my log lines are missing":

   ```bash
   journalctl -b | grep -i 'suppressed'
   ```

   ```
   systemd-journald[318]: Suppressed 4213 messages from /system.slice/noisy-app.service
   ```

   ```bash
   cat > /etc/systemd/journald.conf.d/30-ratelimit.conf <<'EOF'
   [Journal]
   RateLimitIntervalSec=30s
   RateLimitBurst=20000
   EOF
   systemctl restart systemd-journald
   ```

9. Verify integrity of the stored journals:

   ```bash
   journalctl --verify
   ```

   ```
   PASS: /var/log/journal/7d0c…/user-1000.journal
   PASS: /var/log/journal/7d0c…/system.journal
   ```

> **Check your understanding — Block 2.2**
>
> **Q2.5** `SystemMaxUse=500M` and `SystemKeepFree=1G` are both set, and `/var` has 800 MB free. How much journal data will journald retain?
> **Q2.6** Why does journald never truncate an existing journal file to reclaim space? What does it do instead, and what does that imply about `SystemMaxFileSize` relative to `SystemMaxUse`?
> **Q2.7** A service logs 50 000 lines in 10 seconds and most never appear. Which two settings would you change, and what is the risk of disabling the mechanism entirely?
> **Q2.8** `journalctl --vacuum-time=7d` deletes nothing even though you have 30 days of logs. What is the most likely explanation?

---

## Exercise 3 — Injecting messages: `logger` and `systemd-cat`

### Block 3.1 — `logger`, the syslog client

1. The default facility/priority pair when you specify none:

   ```bash
   logger "plain test message from $USER"
   journalctl -n 1 -o verbose --no-pager | grep -E 'PRIORITY|SYSLOG_FACILITY|SYSLOG_IDENTIFIER|MESSAGE='
   ```

   ```
   PRIORITY=5
   SYSLOG_FACILITY=1
   SYSLOG_IDENTIFIER=root
   MESSAGE=plain test message from root
   ```

2. Set facility, priority and tag explicitly, and echo to stderr:

   ```bash
   logger -p local3.err -t backup-job -s "snapshot failed: rc=17"
   ```

   ```
   backup-job: snapshot failed: rc=17
   ```

   ```bash
   journalctl -t backup-job -n 1 -o verbose --no-pager | grep -E 'PRIORITY|SYSLOG_FACILITY|MESSAGE='
   ```

   ```
   PRIORITY=3
   SYSLOG_FACILITY=19
   MESSAGE=snapshot failed: rc=17
   ```

3. Cover the remaining flags that appear in real scripts:

   ```bash
   logger -p cron.info --id=$$ -t healthcheck "started"
   echo -e "line one\nline two" | logger -t multiline -p local0.notice
   logger -p local0.debug -t sizetest "$(head -c 300 /dev/zero | tr '\0' 'x')"
   journalctl -t multiline -n 2 -o cat --no-pager
   ```

4. Emit one message at every priority and watch the threshold behaviour:

   ```bash
   for p in emerg alert crit err warning notice info debug; do
     logger -p local5."$p" -t priotest "message at priority $p"
   done
   journalctl -t priotest -p err --no-pager -o short-iso
   ```

   Only four lines return — `emerg`, `alert`, `crit`, `err`.

> **Check your understanding — Block 3.1**
>
> **Q3.1** `logger` wrote `SYSLOG_FACILITY=19`. Which facility is that, and what is the numeric range of the `localN` facilities?
> **Q3.2** Why is `local0`–`local7` the correct choice for your own applications instead of reusing `daemon` or `user`?
> **Q3.3** In step 1, `SYSLOG_IDENTIFIER` was `root` even though no `-t` was given. Where did that value come from, and why is relying on it fragile in a cron job?
> **Q3.4** What does `-s` do, and why would you use it inside a systemd unit's `ExecStart` script?

---

### Block 3.2 — `systemd-cat` and the transport distinction

5. Run a command with its entire output captured into the journal:

   ```bash
   systemd-cat -t diskcheck -p warning df -h /
   journalctl -t diskcheck -n 5 -o cat --no-pager
   ```

   ```
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/vda2        14G  2.1G   12G  16% /
   ```

6. Pipe into it instead:

   ```bash
   echo "config reload requested" | systemd-cat -t reloader -p notice
   ```

7. Now compare the **transport** of a `logger` message and a `systemd-cat` message — this is the key architectural difference:

   ```bash
   logger -t transport-a "via syslog socket"
   echo "via native protocol" | systemd-cat -t transport-b

   journalctl -t transport-a -n 1 -o verbose --no-pager | grep _TRANSPORT
   journalctl -t transport-b -n 1 -o verbose --no-pager | grep _TRANSPORT
   ```

   ```
   _TRANSPORT=syslog
   _TRANSPORT=journal
   ```

8. Enumerate every transport present on the running system:

   ```bash
   journalctl -F _TRANSPORT
   ```

   ```
   audit
   driver
   journal
   kernel
   stdout
   syslog
   ```

> **Check your understanding — Block 3.2**
>
> **Q3.5** Explain the meaning of each value returned in step 8: `kernel`, `stdout`, `syslog`, `journal`, `driver`, `audit`.
> **Q3.6** A message sent with `systemd-cat` has `_TRANSPORT=journal` and no `SYSLOG_FACILITY` unless you set one. What practical consequence does that have for an rsyslog rule such as `local0.* /var/log/app.log`?
> **Q3.7** Your service writes to stdout and is started by systemd with `StandardOutput=journal`. Which transport will those lines carry, and how do you filter for only that service's stdout?
> **Q3.8** Give one situation where `systemd-cat` is clearly the right tool and one where `logger` is.

---

## Exercise 4 — rsyslog: selectors, actions, and rule order

rsyslog rules are `SELECTOR ACTION` pairs. A selector is `facility.priority`; **the priority means "this severity and everything more severe"** unless you qualify it.

### Block 4.1 — Read the shipped configuration

1. Read the main file and the drop-in directory:

   ```bash
   grep -vE '^\s*(#|$)' /etc/rsyslog.conf
   ls /etc/rsyslog.d/
   grep -vE '^\s*(#|$)' /etc/rsyslog.d/*.conf
   ```

   Representative Debian rules:

   ```
   auth,authpriv.*                 /var/log/auth.log
   *.*;auth,authpriv.none          -/var/log/syslog
   kern.*                          -/var/log/kern.log
   mail.*                          -/var/log/mail.log
   *.emerg                         :omusrmsg:*
   ```

   Representative RHEL rules:

   ```
   *.info;mail.none;authpriv.none;cron.none    /var/log/messages
   authpriv.*                                  /var/log/secure
   mail.*                                      -/var/log/maillog
   cron.*                                      /var/log/cron
   *.emerg                                     :omusrmsg:*
   ```

2. Identify which input modules are loaded — this determines *where rsyslog gets its messages from*:

   ```bash
   grep -hE '^\s*(module|\$ModLoad)' /etc/rsyslog.conf /etc/rsyslog.d/*.conf
   ```

   ```
   module(load="imuxsock")
   module(load="imklog")
   ```

   or, on RHEL:

   ```
   module(load="imuxsock")
   module(load="imjournal" StateFile="imjournal.state")
   ```

3. Validate syntax without restarting anything:

   ```bash
   rsyslogd -N1
   ```

   ```
   rsyslogd: version 8.2302.0, config validation run (level 1), master config /etc/rsyslog.conf
   rsyslogd: End of config validation run. Bye.
   ```

> **Check your understanding — Block 4.1**
>
> **Q4.1** Decode `*.*;auth,authpriv.none    -/var/log/syslog` completely: every token, including the leading `-` on the path.
> **Q4.2** Why do both distributions route `authpriv` to a separate file with restrictive permissions instead of into the catch-all?
> **Q4.3** What is the difference in message source between a system running `imjournal` and one running only `imuxsock`? Which one can lose the journal's trusted metadata?
> **Q4.4** `*.info` and `*.*` — under what circumstances do these two selectors produce different files?

---

### Block 4.2 — Write your own rules

4. Create a rule set that exercises every selector qualifier:

   ```bash
   cat > /etc/rsyslog.d/60-lab.conf <<'EOF'
   # 1) local4, all priorities, into a dedicated file
   local4.*                        /var/log/lab-all.log

   # 2) exactly "err", nothing more and nothing less severe
   local4.=err                     /var/log/lab-err-only.log

   # 3) everything from local4 EXCEPT debug
   local4.!debug                   /var/log/lab-nodebug.log

   # 4) two facilities, one threshold
   local5,local6.warning           /var/log/lab-warn.log

   # 5) property-based filter: message content
   :msg, contains, "TOKEN_LEAK"    /var/log/lab-security.log

   # 6) stop processing after a match so it does not also hit the catch-all
   :programname, isequal, "chatty"  /var/log/lab-chatty.log
   & stop
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   ```

5. Generate traffic that hits each rule:

   ```bash
   for p in debug info notice warning err crit; do
     logger -p local4."$p" -t labtest "local4 $p"
   done
   logger -p local5.warning -t labtest "local5 warning"
   logger -p local6.info    -t labtest "local6 info (should NOT appear in lab-warn)"
   logger -p local0.notice  -t labtest "TOKEN_LEAK detected in build output"
   logger -p local0.info    -t chatty  "noise line"
   ```

6. Inspect the results:

   ```bash
   wc -l /var/log/lab-*.log
   cat /var/log/lab-err-only.log
   grep -c . /var/log/lab-nodebug.log
   tail -1 /var/log/lab-security.log
   grep -c chatty /var/log/syslog /var/log/messages 2>/dev/null
   ```

   ```
     6 /var/log/lab-all.log
     1 /var/log/lab-err-only.log
     5 /var/log/lab-nodebug.log
     1 /var/log/lab-security.log
     1 /var/log/lab-warn.log
   ```

7. Add a custom template so the file format is yours, not the default:

   ```bash
   cat > /etc/rsyslog.d/61-lab-template.conf <<'EOF'
   template(name="LabFormat" type="string"
            string="%TIMESTAMP:::date-rfc3339% %HOSTNAME% %syslogfacility-text%.%syslogseverity-text% [%syslogtag%] %msg%\n")

   local7.*   action(type="omfile" file="/var/log/lab-template.log" template="LabFormat")
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   logger -p local7.notice -t formatted "templated line"
   cat /var/log/lab-template.log
   ```

   ```
   2026-08-27T09:47:12.104883+00:00 lab01 local7.notice [formatted] templated line
   ```

> **Check your understanding — Block 4.2**
>
> **Q4.5** `local4.*` produced 6 lines and `local4.!debug` produced 5. Explain precisely what `!` did, and what `local4.!=err` would have matched.
> **Q4.6** In rule 4, `local5,local6.warning` — does the `warning` threshold apply to `local5`, to `local6`, or to both? What is the syntax rule?
> **Q4.7** What did `& stop` accomplish, and what would have happened to the `chatty` messages without it?
> **Q4.8** rsyslog evaluates rules top to bottom and a message can match many. Given that, why is `& stop` a *performance* tool as well as a routing tool?
> **Q4.9** Name three actions other than "write to a file" that a selector can be paired with, and give the syntax for each.

---

## Exercise 5 — journald ↔ rsyslog: who feeds whom

### Block 5.1 — Trace the message path

1. Identify the sockets involved:

   ```bash
   ls -l /dev/log
   systemctl list-sockets | grep -i journal
   ```

   ```
   lrwxrwxrwx 1 root root 28 Aug 27 08:41 /dev/log -> /run/systemd/journal/dev-log
   /run/systemd/journal/dev-log    systemd-journald-dev-log.socket   systemd-journald.service
   /run/systemd/journal/socket     systemd-journald.socket           systemd-journald.service
   /run/systemd/journal/stdout     systemd-journald.service          systemd-journald.service
   ```

2. Check whether journald is forwarding to a syslog daemon:

   ```bash
   systemd-analyze cat-config systemd/journald.conf | grep -i forward
   ls -l /run/systemd/journal/syslog 2>&1
   ```

3. Enable forwarding explicitly and observe the effect:

   ```bash
   cat > /etc/systemd/journald.conf.d/40-forward.conf <<'EOF'
   [Journal]
   ForwardToSyslog=yes
   MaxLevelStore=debug
   MaxLevelSyslog=info
   EOF
   systemctl restart systemd-journald
   systemctl restart rsyslog

   logger -p local0.debug  -t fwdtest "debug line"
   logger -p local0.notice -t fwdtest "notice line"

   journalctl -t fwdtest -p debug --no-pager -o cat
   grep fwdtest /var/log/syslog /var/log/messages 2>/dev/null
   ```

   The journal holds **both** lines; the syslog file holds only the `notice` one.

> **Check your understanding — Block 5.1**
>
> **Q5.1** `/dev/log` is a symlink into `/run/systemd/journal/`. What does that prove about which daemon receives a `logger` message *first* on a systemd host?
> **Q5.2** Explain the difference between `MaxLevelStore` and `MaxLevelSyslog`, using the result of step 3 as evidence.
> **Q5.3** On a host using `imjournal`, is `ForwardToSyslog=yes` required for rsyslog to see journal messages? Justify your answer.
> **Q5.4** Name the four `ForwardTo*` settings and give a production scenario for each.
> **Q5.5** You enable `ForwardToSyslog=yes` on a busy host and CPU usage rises noticeably. Explain the mechanism and give one mitigation.

---

## Exercise 6 — Central log collection

### Block 6.1 — rsyslog receiver

Run this on the **collector** host (call it `logsrv`, `10.0.0.10`).

1. Enable a TCP listener:

   ```bash
   cat > /etc/rsyslog.d/10-remote-in.conf <<'EOF'
   module(load="imtcp" MaxSessions="500")
   input(type="imtcp" port="514")

   template(name="RemoteFile" type="string"
            string="/var/log/remote/%HOSTNAME%/%PROGRAMNAME%.log")

   # Only remote traffic goes to the per-host tree, and then stops.
   if ($fromhost-ip != "127.0.0.1") then {
       action(type="omfile" dynaFile="RemoteFile" dirCreateMode="0750" fileCreateMode="0640")
       stop
   }
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   ss -ltnp | grep :514
   ```

   ```
   LISTEN 0  25  0.0.0.0:514  0.0.0.0:*  users:(("rsyslogd",pid=1442,fd=7))
   ```

2. Open the firewall:

   ```bash
   firewall-cmd --add-port=514/tcp --permanent && firewall-cmd --reload   # RHEL
   # or
   ufw allow 514/tcp                                                      # Debian
   ```

### Block 6.2 — rsyslog sender

Run this on the **client**.

3. Forward everything, with a disk-assisted queue so a collector outage does not lose messages:

   ```bash
   cat > /etc/rsyslog.d/90-remote-out.conf <<'EOF'
   *.* action(type="omfwd"
              target="10.0.0.10" port="514" protocol="tcp"
              queue.type="LinkedList"
              queue.filename="fwd_logsrv"
              queue.spoolDirectory="/var/spool/rsyslog"
              queue.maxDiskSpace="1g"
              queue.saveOnShutdown="on"
              action.resumeRetryCount="-1")
   EOF

   rsyslogd -N1 && systemctl restart rsyslog
   logger -p local0.notice -t remotetest "hello from $(hostname)"
   ```

4. The legacy equivalent — you must be able to read it in an exam and in old configs:

   ```
   *.*    @@10.0.0.10:514      # TCP
   *.*    @10.0.0.10:514       # UDP
   ```

5. Verify on the collector:

   ```bash
   find /var/log/remote -type f
   tail -2 /var/log/remote/*/remotetest.log
   ```

6. Simulate an outage and confirm the queue works:

   ```bash
   # on collector:
   systemctl stop rsyslog
   # on client:
   logger -p local0.notice -t remotetest "sent while collector was down"
   ls -l /var/spool/rsyslog/
   # on collector:
   systemctl start rsyslog
   sleep 5 && tail -1 /var/log/remote/*/remotetest.log
   ```

> **Check your understanding — Block 6.1 / 6.2**
>
> **Q6.1** Translate `*.* @@10.0.0.10:514` and `*.* @10.0.0.10:514` into words. What single character distinguishes them, and what does it change about delivery guarantees?
> **Q6.2** Why is `stop` essential inside the `if` block on the collector?
> **Q6.3** Without `queue.filename`, what kind of queue does the action use, and what happens to the messages if rsyslog is restarted while the collector is unreachable?
> **Q6.4** `action.resumeRetryCount="-1"` — what does `-1` mean, and what is the failure mode of leaving it at the default?
> **Q6.5** Port 514/UDP and 514/TCP are both unencrypted and unauthenticated. Name the two systemd-native components that provide an HTTPS-based alternative, and one rsyslog-native alternative.

---

## Exercise 7 — Rotation: `logrotate`

The journal rotates itself. **Plain-text files written by rsyslog do not** — that is `logrotate`'s job.

### Block 7.1 — Read the existing policy

1. Global defaults and includes:

   ```bash
   grep -vE '^\s*(#|$)' /etc/logrotate.conf
   ls /etc/logrotate.d/
   ```

   ```
   weekly
   su root adm
   rotate 4
   create
   dateext
   include /etc/logrotate.d
   /var/log/wtmp {
       missingok
       monthly
       create 0664 root utmp
       rotate 1
   }
   ```

2. Inspect the state file — this is how logrotate knows when it last rotated each path:

   ```bash
   head -5 /var/lib/logrotate/status 2>/dev/null || head -5 /var/lib/logrotate/logrotate.status
   ```

   ```
   logrotate state -- version 2
   "/var/log/syslog" 2026-8-27-0:0:0
   "/var/log/auth.log" 2026-8-24-0:0:0
   ```

3. Find out *what* runs it:

   ```bash
   systemctl list-timers logrotate.timer
   ls -l /etc/cron.daily/logrotate 2>/dev/null
   ```

### Block 7.2 — Write and test a policy

4. Create a policy exercising the directives you must know:

   ```bash
   cat > /etc/logrotate.d/lab <<'EOF'
   /var/log/lab-*.log {
       daily
       rotate 7
       maxsize 10M
       compress
       delaycompress
       missingok
       notifempty
       dateext
       dateformat -%Y%m%d
       create 0640 root adm
       sharedscripts
       postrotate
           /usr/bin/systemctl kill -s HUP --kill-whom=main rsyslog.service 2>/dev/null || true
       endscript
   }
   EOF
   ```

5. Dry-run first — **`-d` implies `-v` and never touches the state file**:

   ```bash
   logrotate -d /etc/logrotate.d/lab
   ```

   ```
   reading config file /etc/logrotate.d/lab
   Handling 1 logs
   rotating pattern: /var/log/lab-*.log  after 1 days (7 rotations)
   empty log files are not rotated, log files >= 10485760 are rotated earlier, old logs are removed
   considering log /var/log/lab-all.log
     Now: 2026-08-27 09:58
     Last rotated at 2026-08-27 09:00
     log does not need rotating (log has already been rotated)
   ```

6. Force one rotation and inspect the result:

   ```bash
   logrotate -vf /etc/logrotate.d/lab
   ls -l /var/log/lab-all.log*
   ```

   ```
   -rw-r----- 1 root adm    0 Aug 27 10:01 /var/log/lab-all.log
   -rw-r----- 1 root adm  412 Aug 27 10:01 /var/log/lab-all.log-20260827
   ```

7. Rotate a second time and observe what `delaycompress` did:

   ```bash
   logger -p local4.info -t labtest "post-rotation line"
   logrotate -vf /etc/logrotate.d/lab
   ls -l /var/log/lab-all.log*
   ```

   ```
   -rw-r----- 1 root adm    0 /var/log/lab-all.log
   -rw-r----- 1 root adm   58 /var/log/lab-all.log-20260827
   -rw-r----- 1 root adm  198 /var/log/lab-all.log-20260826.gz
   ```

8. Confirm the log is still being written after rotation (the point of the `postrotate` HUP):

   ```bash
   logger -p local4.info -t labtest "still alive"
   sleep 1 && cat /var/log/lab-all.log
   ```

9. Test against an isolated state file so you do not corrupt the system's:

   ```bash
   logrotate -v -s /tmp/lab.status /etc/logrotate.d/lab
   ```

> **Check your understanding — Block 7.2**
>
> **Q7.1** `daily` and `maxsize 10M` are both present. Under what condition does each trigger, and how does `maxsize` differ from `size`?
> **Q7.2** Explain `delaycompress` using the output of step 7. What class of problem does it solve?
> **Q7.3** What exactly does `create 0640 root adm` do, and in what order relative to the rename?
> **Q7.4** Contrast `create` + `postrotate`-HUP with `copytruncate`. Give the specific failure each one avoids and the specific failure each one introduces.
> **Q7.5** Why is `sharedscripts` needed here, and what would happen without it given the `lab-*.log` glob?
> **Q7.6** `missingok` and `notifempty` — what does each suppress, and why is `missingok` almost mandatory in a package-shipped policy?
> **Q7.7** `logrotate -d` reports "log does not need rotating" for a file that is clearly 2 GB. Name three distinct causes.
> **Q7.8** Why does `logrotate.conf` need `su root adm` on Debian, and what error appears without it?

---

## Exercise 8 — Diagnostics under pressure

### Block 8.1 — "The disk is full and it's `/var/log`"

1. Establish where the space went, journal versus text logs:

   ```bash
   df -h /var/log
   journalctl --disk-usage
   du -xh --max-depth=1 /var/log | sort -h | tail
   du -xh --max-depth=1 /var/log --exclude=journal | sort -h | tail -5
   ```

2. Find the loudest producer:

   ```bash
   journalctl -b -o cat | awk '{print $1}' | sort | uniq -c | sort -rn | head
   journalctl -b -F _SYSTEMD_UNIT | while read -r u; do
     printf '%8d %s\n' "$(journalctl -b -u "$u" --no-pager -o cat | wc -l)" "$u"
   done | sort -rn | head
   ```

3. Reclaim, then cap so it cannot recur:

   ```bash
   journalctl --vacuum-size=200M
   # then set SystemMaxUse as in Exercise 2, and restart journald
   ```

4. Find deleted-but-still-open log files, the classic reason `df` and `du` disagree:

   ```bash
   lsof +L1 2>/dev/null | grep -i '/var/log'
   ```

   ```
   rsyslogd 1442 root 8w REG 253,2 4831838208 0 262151 /var/log/huge.log (deleted)
   ```

### Block 8.2 — "Nothing is being logged"

5. Work down the chain, in this order:

   ```bash
   systemctl status systemd-journald --no-pager
   systemctl status rsyslog --no-pager
   ls -l /dev/log
   logger -p local0.emerg -t chaintest "chain probe"
   journalctl -t chaintest -n 1 --no-pager
   grep chaintest /var/log/syslog /var/log/messages 2>/dev/null
   rsyslogd -N1
   ```

6. Check for a corrupted journal file:

   ```bash
   journalctl --verify 2>&1 | grep -v '^PASS'
   ```

   ```
   FAIL: /var/log/journal/7d0c…/system@0006a2….journal (Bad message)
   ```

   ```bash
   journalctl --rotate
   mv /var/log/journal/*/system@0006a2*.journal /root/
   systemctl restart systemd-journald
   ```

7. Check for SELinux or AppArmor denials blocking a custom log path:

   ```bash
   ausearch -m avc -ts recent 2>/dev/null | tail -20
   journalctl -t audit -b -p warning --no-pager | tail
   ls -Z /var/log/lab-all.log 2>/dev/null
   ```

8. Confirm the binary accounting logs, which are **not** journald's and **not** plain text:

   ```bash
   last -n 5
   lastb -n 5
   lastlog | head -5
   ls -l /var/log/wtmp /var/log/btmp /var/log/lastlog
   ```

> **Check your understanding — Block 8.1 / 8.2**
>
> **Q8.1** `df` reports `/var` at 100 % but `du -sh /var/log` accounts for only 2 GB on a 40 GB filesystem. What is happening, and what is the correct remediation — and the incorrect but tempting one?
> **Q8.2** You deleted files under `/var/log/journal/` with `rm` while journald was running. Why is `journalctl --rotate` before removal the safer sequence?
> **Q8.3** `logger -p local0.emerg` produces a journal entry but nothing in `/var/log/messages`, and `rsyslogd -N1` is clean. Give the two most likely causes.
> **Q8.4** `/var/log/wtmp`, `/var/log/btmp` and `/var/log/lastlog` cannot be read with `less`. Name the reading tool for each and state which one records *failed* logins.
> **Q8.5** A journal file fails `--verify` with "Bad message". Can `journalctl` still read the other files? What does that tell you about journal file granularity?

---

## Reference summary

| Task | Command |
|---|---|
| Last 50 lines of a unit, follow | `journalctl -u NAME -n 50 -f` |
| Errors this boot, with explanations | `journalctl -xb -p err` |
| Kernel messages, previous boot | `journalctl -k -b -1` |
| Time window | `journalctl --since "-1h" --until now` |
| Machine-readable | `journalctl -o json-pretty` |
| Disk usage / reclaim | `journalctl --disk-usage` / `--vacuum-size=1G` |
| Integrity | `journalctl --verify` |
| Make persistent | `mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal` |
| Send a syslog message | `logger -p local3.err -t TAG "text"` |
| Capture a command | `systemd-cat -t TAG -p warning CMD` |
| Validate rsyslog config | `rsyslogd -N1` |
| Forward via TCP (legacy) | `*.*  @@host:514` |
| Rotation dry-run / force | `logrotate -d FILE` / `logrotate -vf FILE` |

**Facilities:** `kern(0) user(1) mail(2) daemon(3) auth(4) syslog(5) lpr(6) news(7) uucp(8) cron(9) authpriv(10) ftp(11)` … `local0(16)`–`local7(23)`
**Priorities (severity):** `emerg(0) alert(1) crit(2) err(3) warning(4) notice(5) info(6) debug(7)`

---

## Sources

- LPI — Exam 102-500 Objectives (topic 108.2): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI — Exam 101-500 Objectives: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- `journalctl(1)`: <https://www.freedesktop.org/software/systemd/man/latest/journalctl.html>
- `journald.conf(5)`: <https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html>
- `systemd-journald.service(8)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-journald.service.html>
- `systemd-cat(1)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd-cat.html>
- `systemd.journal-fields(7)`: <https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html>
- rsyslog configuration reference: <https://www.rsyslog.com/doc/configuration/index.html>
- rsyslog `omfwd` module: <https://www.rsyslog.com/doc/configuration/modules/omfwd.html>
- rsyslog queue parameters: <https://www.rsyslog.com/doc/rainerscript/queue_parameters.html>
- `logger(1)`: <https://man7.org/linux/man-pages/man1/logger.1.html>
- `logrotate(8)`: <https://man7.org/linux/man-pages/man8/logrotate.8.html>
- `syslog(3)` — facility and priority constants: <https://man7.org/linux/man-pages/man3/syslog.3.html>
- RFC 5424, *The Syslog Protocol*: <https://datatracker.ietf.org/doc/html/rfc5424>
- RFC 3164, *The BSD syslog Protocol*: <https://datatracker.ietf.org/doc/html/rfc3164>

---

<details>
<summary><strong>Answers</strong></summary>

### Exercise 1

**Q1.1** With `Storage=auto` (the default) and no `/var/log/journal`, journald writes to `/run/log/journal`, which is a **tmpfs**. Everything is lost at reboot — including the logs from the crash that caused the reboot. This is precisely the case Exercise 2 fixes.

**Q1.2** Mode `0640 root:systemd-journal` lets members of `systemd-journal` read it. The `+` marks an **ACL** installed by `systemd-tmpfiles` from `/usr/lib/tmpfiles.d/systemd.conf`, granting `r-x` to `adm` (Debian) or `wheel` (RHEL). So an administrator in `adm`/`wheel` reads the system journal without `sudo`; anyone else sees only their own user journal.

**Q1.3** Two reasons. First, `journalctl --disk-usage` sums **both** `/var/log/journal` and `/run/log/journal` when both exist. Second, journald pre-allocates journal files to `SystemMaxFileSize` and `du` on a sparse file reports allocated blocks, not the nominal size — so the numbers can differ in either direction depending on the filesystem.

**Q1.4** The `PRIORITY` field carries the syslog **severity** number, where `0 = emerg` is the most severe and `7 = debug` the least. "Warning and above" therefore means severity ≤ 4. `-p` sets a *maximum numeric value*, which reads as a *minimum severity*.

**Q1.5** `-b -1` selects by `_BOOT_ID` — the entire previous boot, whether it lasted 3 minutes or 3 months. `--since yesterday` selects by wall-clock timestamp and can span several boots or none. Scenario: a box up for 90 days, rebooted an hour ago. `-b -1` returns 90 days of logs; `--since yesterday` returns ~24 hours crossing the boot boundary.

**Q1.6** The journal is volatile — no `/var/log/journal`, or `Storage=volatile`/`none`. Records from previous boots did not survive, so only the current boot ID exists in the index.

**Q1.7** `_COMM=sshd`. `-u sshd` is shorthand for `_SYSTEMD_UNIT=sshd.service` plus related matches, so it only returns messages attributed to that unit's cgroup. A `sshd` binary invoked from an install script runs in a different cgroup and would carry a different `_SYSTEMD_UNIT`, so `-u` would miss it while `_COMM` catches it.

**Q1.8** Fields beginning with `_` are **trusted fields**: journald derives them itself from the sending process's credentials over the socket (`_PID`, `_UID`, `_COMM`, `_EXE`, `_CMDLINE`, `_SYSTEMD_UNIT`, `_SELINUX_CONTEXT`) and a client cannot forge them. Fields without the underscore (`MESSAGE`, `PRIORITY`, `SYSLOG_IDENTIFIER`) come from the client and are entirely under its control. During an investigation, a suspicious `SYSLOG_IDENTIFIER=sshd` proves nothing; `_EXE=/usr/sbin/sshd` and `_UID=0` are evidence.

**Q1.9** `SYSLOG_FACILITY=4` is `auth`; `PRIORITY=6` is `info`. A classic selector matching it is `auth.info` (which also matches everything more severe), or `auth.=info` in rsyslog for that severity alone.

**Q1.10** `-x` augments entries with explanatory text from the **message catalog** (`/usr/lib/systemd/catalog/*.catalog`, indexed into `catalog` by `journalctl --update-catalog`). Entries carrying a `MESSAGE_ID=` are matched against the catalog and get a paragraph explaining cause and typical remedy.

**Q1.11** `-o cat`. You lose the timestamp, hostname, identifier, PID and priority — everything except `MESSAGE`. Use it only when the surrounding pipeline supplies that context itself.

### Exercise 2

**Q2.1**
- `volatile` — memory only, in `/run/log/journal`; never touches disk.
- `persistent` — `/var/log/journal`, **created by journald if missing**; falls back to `/run` only while `/var` is not yet mounted.
- `auto` (default) — behaves as `persistent` if `/var/log/journal` already exists, otherwise as `volatile`. It will **not** create the directory.
- `none` — nothing is stored at all; journald still forwards (syslog, kmsg, console, wall) and still serves `journalctl -f` for the live stream, but nothing is retained.

`Storage=auto` is the one that makes the directory's existence the deciding factor; `Storage=persistent` makes the directory mandatory but creates it for you.

**Q2.2** (a) The setting never took effect — journald was not restarted, or a later drop-in overrides it. (b) The directory exists but has wrong ownership/permissions/ACL so journald cannot write there and silently stayed volatile. Distinguish with `systemd-analyze cat-config systemd/journald.conf` (shows the *effective* merged config) and then `journalctl -u systemd-journald -b | grep -i 'permanent\|runtime\|journal'`, which logs which directory it opened.

**Q2.3**
- `--flush` — asks journald to move everything currently in `/run/log/journal` into `/var/log/journal` and stop writing to `/run`. Meaningful only once persistent storage is active.
- `--sync` — blocks until all queued messages are committed to their backing files (`fsync`). Use before a hard power-off or before archiving the journal.
- `--rotate` — closes the active journal files, marks them archived, and starts new ones. Use before copying or deleting journal files.

**Q2.4** `Storage=none` disables *storage*, not *reception*. journald still accepts messages, applies `ForwardTo*`, and serves them on the live bus, so `journalctl -f` shows the stream as it arrives. Nothing is queryable afterwards.

**Q2.5** `SystemKeepFree` wins because it is the stricter of the two at that moment: journald keeps whichever limit leaves less data. With 800 MB free and a 1 GB free-space floor, journald is already over budget and will vacuum aggressively — retaining effectively nothing beyond the active file until 1 GB is free again. The rule is: the enforced limit is `min(SystemMaxUse, currently_available − SystemKeepFree)`.

**Q2.6** Journal files are append-only and integrity-hashed; truncating them would break the hash chain and the index. journald instead rotates (seals the active file, opens a new one) and then **deletes whole archived files**. Consequence: `SystemMaxFileSize` must be meaningfully smaller than `SystemMaxUse` — the defaults use 1/8 — otherwise the smallest unit of reclamation is a large fraction of the whole budget and retention becomes coarse and unpredictable.

**Q2.7** `RateLimitBurst` (raise it) and `RateLimitIntervalSec` (shorten the window). Setting `RateLimitIntervalSec=0` disables limiting entirely, which removes the only defence against a looping service filling the disk or starving journald's CPU — a single misbehaving process can then push out every other service's logs. Prefer a raised burst, or set per-unit `LogRateLimitBurst=`/`LogRateLimitIntervalSec=` on the noisy unit only.

**Q2.8** Vacuuming only ever removes **archived** journal files, never the active one, and it works at whole-file granularity. If all 30 days live inside one still-active `system.journal` (because `SystemMaxFileSize`/`MaxFileSec` never forced a rotation), there is nothing to delete. Run `journalctl --rotate` first, then vacuum.

### Exercise 3

**Q3.1** Facility 19 is `local3`. The `localN` facilities are 16–23, i.e. `local0`=16 … `local7`=23.

**Q3.2** The standard facilities have defined meanings and the distribution's shipped rsyslog rules already route them: writing to `daemon` mixes your application into `/var/log/syslog`/`messages` alongside system daemons, and writing to `auth`/`authpriv` pollutes the security log that auditors read. `local0`–`local7` are explicitly reserved for site-local use, so you can give your application its own selector, its own file, its own rotation policy and its own retention without touching any existing rule.

**Q3.3** With no `-t`, `logger` uses the login name from `getlogin()`/`LOGNAME` as the tag. In a cron job or a systemd unit there may be no controlling terminal and `LOGNAME` may be unset or generic, so the tag becomes useless for filtering — and worse, it becomes *inconsistent*, so a rule like `:programname, isequal, "backup"` silently stops matching. Always pass `-t` explicitly in non-interactive contexts.

**Q3.4** `-s` writes the message to **stderr** in addition to the syslog socket. Inside a unit's `ExecStart` wrapper this is useful because stderr is captured by systemd and lands in the journal attributed to the *unit* (`_TRANSPORT=stdout`, correct `_SYSTEMD_UNIT`), while the syslog copy carries your chosen facility for rsyslog routing — you get both the unit attribution and the routing.

**Q3.5**
- `kernel` — read from `/dev/kmsg`, the kernel ring buffer (`journalctl -k`).
- `stdout` — a service's stdout/stderr captured through `/run/systemd/journal/stdout`.
- `syslog` — arrived on the classic `/dev/log` datagram socket (what `logger` uses).
- `journal` — arrived via journald's **native** protocol on `/run/systemd/journal/socket` (`sd_journal_send`, `systemd-cat`), which is the only transport that carries arbitrary structured fields.
- `driver` — generated by journald itself (rotation notices, "Suppressed N messages").
- `audit` — read from the kernel audit netlink socket.

**Q3.6** A native-transport message has no `SYSLOG_FACILITY` field, so it cannot match a facility-based rsyslog selector — `local0.*` will never see it. To route `systemd-cat` output with rsyslog you must either set the facility explicitly (`systemd-cat` only sets priority via `-p`, so use `logger` instead), or filter on a property rsyslog *can* see, such as `:programname, isequal, "yourtag"` — and even then only if journald is forwarding to syslog and the tag survives the conversion.

**Q3.7** `_TRANSPORT=stdout`. Filter with `journalctl -u myapp.service _TRANSPORT=stdout`. Note that `journalctl` ANDs matches on different fields and ORs matches on the same field, so this combination is an AND as intended.

**Q3.8** `systemd-cat` is right when you want a command's full stdout **and** stderr captured verbatim with correct process metadata and no per-line escaping — e.g. `systemd-cat -t backup /usr/local/bin/backup.sh` inside a unit. `logger` is right when the message must reach a **classic syslog facility** so that rsyslog rules can route it — e.g. shipping application events to a central collector by `local4`.

### Exercise 4

**Q4.1**
- `*.*` — every facility, every priority.
- `;` — separates selectors that are combined for the same action.
- `auth,authpriv.none` — the facilities `auth` and `authpriv` at priority `none`, i.e. **exclude** them entirely.
- Together: "everything except `auth` and `authpriv`".
- `-/var/log/syslog` — the leading `-` means **do not `fsync()` after each write**. It trades durability on a crash for a large reduction in I/O.

**Q4.2** `authpriv` carries authentication detail — usernames, source addresses, sudo invocations, PAM failures. Splitting it into `/var/log/auth.log` / `/var/log/secure` with `0640 root:adm` keeps it out of the world-readable-ish catch-all, gives it an independent retention policy, and gives auditors a single file to read. Merging it into `syslog` would both leak it more widely and bury it in noise.

**Q4.3** With `imjournal`, rsyslog reads directly from the journal database and can access journal fields (including trusted `_`-prefixed ones) as rsyslog properties, at the cost of higher CPU and a state file (`imjournal.state`) that can desynchronise. With only `imuxsock`, rsyslog reads a plain syslog datagram stream from `/run/systemd/journal/syslog` — that stream is a lossy RFC-3164-style rendering, so the **trusted metadata is lost**; you get tag, PID, facility and priority and nothing more.

**Q4.4** `*.*` matches all eight severities; `*.info` matches severities 0–6 and drops `debug`. They differ exactly when something logs at `debug` — which, once you turn debug logging on for a service to troubleshoot it, is the moment you most need it. This is a routine surprise: the messages are in the journal but absent from `/var/log/messages`.

**Q4.5** `!` negates the priority match: `local4.!debug` means "all `local4` priorities **except** severity 7", so it caught `info` through `crit` — 5 of the 6 generated lines. `local4.!=err` would mean "all `local4` priorities except *exactly* `err`" — note that `!` and `=` compose, `!` alone negates a threshold and `!=` negates a single level.

**Q4.6** The priority applies to **both**. The syntax is `facility[,facility...].priority` — a comma-separated facility list shares one trailing priority specification. To give each facility a different threshold you need two separate selectors joined by `;`, e.g. `local5.warning;local6.err`.

**Q4.7** `&` repeats the previous selector, and `stop` (legacy `~`) discards the message so that no later rule can act on it. Without it, the `chatty` messages would match `lab-chatty.log` *and then continue* to the catch-all `*.*` rule and be written a second time into `/var/log/syslog` / `/var/log/messages`.

**Q4.8** Every rule after a match still has its selector evaluated, and — more expensively — every matching action performs I/O. On a host receiving tens of thousands of messages per second, an early `stop` on high-volume, well-classified traffic removes both the remaining rule evaluations and the duplicate writes. Placement matters: put the highest-volume `stop`ping rule first.

**Q4.9**
- Forward to a remote host: `*.*  @@10.0.0.10:514` (TCP) or `action(type="omfwd" target="…" protocol="tcp")`.
- Write to all logged-in users' terminals: `*.emerg  :omusrmsg:*` (or a user list, `*.emerg  root,operator`).
- Pipe to a named pipe / program: `*.*  |/var/run/mypipe`, or `action(type="omprog" binary="/usr/local/bin/handler")`.
- (Also valid: a database via `ommysql`, or `:omfile:` with a dynamic filename template as in step 7.)

### Exercise 5

**Q5.1** It proves that **journald receives it first**, unconditionally. On a systemd host the `/dev/log` socket is owned by `systemd-journald-dev-log.socket`, so even a program using the plain `syslog(3)` API talks to journald. rsyslog is downstream — it gets a copy only if journald forwards it (`ForwardToSyslog=yes` + `/run/systemd/journal/syslog`) or reads it back out (`imjournal`).

**Q5.2** `MaxLevelStore` is the severity threshold for what journald **keeps in its own database**; `MaxLevelSyslog` is the threshold for what it **forwards to the syslog daemon**. With `MaxLevelStore=debug` and `MaxLevelSyslog=info`, the `debug` line was stored but not forwarded, which is exactly what step 3 showed: `journalctl` has both lines, `/var/log/syslog` has only the `notice` one. The same pattern applies to `MaxLevelKMsg`, `MaxLevelConsole` and `MaxLevelWall`.

**Q5.3** No. `imjournal` reads the journal database directly through the journal API, bypassing the forwarding socket entirely. `ForwardToSyslog=yes` is required only for the `imuxsock`-based path. Enabling both on a RHEL-style host produces **duplicate** log lines.

**Q5.4**
- `ForwardToSyslog` — a syslog daemon must see the messages, typically because rsyslog ships them to a central collector or a SIEM.
- `ForwardToKMsg` — write into the kernel ring buffer, so that early-boot or crash-dump tooling that only reads `dmesg` captures userspace context. Rarely appropriate; the ring buffer is small.
- `ForwardToConsole` — mirror to `TTYPath=` (default `/dev/console`). Used on headless appliances and serial-console-managed hardware where the console is the only diagnostic channel.
- `ForwardToWall` — broadcast to logged-in terminals (default `yes`, gated by `MaxLevelWall=emerg`). This is why `emerg` messages appear on everyone's terminal.

**Q5.5** Every message is now processed twice: journald writes and indexes it, then serialises it to the forwarding socket, and rsyslog parses it again, re-evaluates its whole rule set, and writes it a second time — often to a second `fsync`ing file. On a high-volume host this roughly doubles logging CPU and disk I/O. Mitigations: raise the forwarding threshold (`MaxLevelSyslog=notice`), narrow rsyslog's rules and `stop` early, use `-` prefixes on file actions to skip `fsync`, or drop rsyslog entirely and forward with `systemd-journal-upload`.

### Exercise 6

**Q6.1** `*.* @@10.0.0.10:514` = "send every message of every facility and priority to 10.0.0.10 port 514 over **TCP**". `*.* @10.0.0.10:514` = the same over **UDP**. The distinguishing character is the doubled `@`. TCP gives connection-oriented delivery with retransmission and back-pressure, so a message either gets acknowledged by the transport or the sender knows it failed; UDP is fire-and-forget — a silent drop under load, MTU fragmentation, or a restarting collector loses messages with no indication at either end. Note that even TCP only guarantees delivery to the collector's socket, not that rsyslog wrote it to disk; that requires RELP.

**Q6.2** Without `stop`, remote messages continue down the rule chain and also match the collector's own local rules (`*.info … /var/log/messages`, `authpriv.* /var/log/secure`). Every client's `authpriv` traffic would be merged into the collector's own security log, making it impossible to distinguish a local sudo from a remote one — an outright forensic hazard, on top of doubling disk usage.

**Q6.3** Without `queue.filename` the action uses an **in-memory** queue only (`queue.type="LinkedList"` still means RAM). If rsyslog restarts, or the machine reboots, everything queued is lost; and once the queue reaches `queue.maxSize` it starts discarding. `queue.filename` + `queue.spoolDirectory` promotes it to a **disk-assisted** queue that spills to disk under pressure, and `queue.saveOnShutdown="on"` persists the remainder across a restart.

**Q6.4** `-1` means **retry forever**. The default is `0`: on the first failure the action is marked suspended, and rsyslog will retry on its own suspension schedule but the action can be permanently disabled after repeated failures — the effect being that a collector outage that outlasts the retry budget silently stops forwarding, and nobody notices until an audit. `-1` combined with a disk-assisted queue is the configuration that actually survives a collector maintenance window.

**Q6.5** systemd-native: **`systemd-journal-upload`** (client, pushes to an HTTPS endpoint) and **`systemd-journal-remote`** (server, receives; often paired with `systemd-journal-gatewayd`, which serves the journal over HTTPS for pull-based collection). rsyslog-native: **RELP** (`omrelp`/`imrelp`) for reliable delivery, optionally with TLS, or plain `omfwd` with `StreamDriver="gtls"` and `StreamDriverAuthMode="x509/name"` for TLS-encrypted, certificate-authenticated syslog.

### Exercise 7

**Q7.1** `daily` triggers when the state file shows the last rotation was on an earlier day. `maxsize 10M` triggers when the file exceeds 10 MB **and** the time interval has not yet elapsed — i.e. it rotates *earlier* than scheduled. The contrast:
- `size 10M` — rotate on size **alone**, ignoring any time directive.
- `maxsize 10M` — rotate on the time interval **or** on size, whichever comes first.
- `minsize 10M` — rotate on the time interval, but only if the file has reached 10 MB.

**Q7.2** With `delaycompress`, the most recently rotated file is left uncompressed for one cycle and only gets gzipped at the *next* rotation — which is why step 7 showed `lab-all.log-20260827` plain and `lab-all.log-20260826.gz` compressed. It solves the case where the writing process still holds an open file descriptor on the just-rotated file (because it has not yet been signalled, or reopens lazily): compressing it immediately would produce a truncated archive and lose the lines written in the gap.

**Q7.3** After renaming the old log out of the way, logrotate immediately creates a new empty file at the original path with mode `0640`, owner `root`, group `adm`. Order matters: rename first, create second, and the inode number changes — which is exactly why a daemon holding the old file descriptor must be told to reopen.

**Q7.4**
- **`create` + `postrotate` HUP** — the file is renamed and a new inode created; the daemon is signalled and reopens the path. No data is lost, but if the signal fails or the daemon ignores it, the daemon keeps writing to the *rotated* (now invisible) file forever and the new log stays at zero bytes.
- **`copytruncate`** — the file is copied and then truncated in place, so the inode never changes and no signal is needed. It works with daemons that cannot be signalled or that hold the descriptor with `O_APPEND` and no reopen logic. But there is an unavoidable race between the copy and the truncate: anything written in that window is lost. It also doubles I/O and briefly doubles disk usage.

Rule of thumb: `create` + signal for anything you control (rsyslog, nginx, most daemons); `copytruncate` only as a last resort for third-party software that cannot reopen.

**Q7.5** The glob `/var/log/lab-*.log` matches several files. Without `sharedscripts`, `prerotate`/`postrotate` run **once per matched file** — so rsyslog would be HUPed five or six times in a row for one rotation cycle. `sharedscripts` collapses that into a single execution after all matching files have been rotated. (`nosharedscripts` is the default.)

**Q7.6** `missingok` suppresses the error when the log file does not exist; `notifempty` suppresses rotation when the file exists but is zero bytes. `missingok` is effectively mandatory in a package-shipped policy because the package's config is installed before the service has ever run — without it, logrotate emits an error every single day, which is mailed to root, until someone starts the service.

**Q7.7** (a) The state file already records a rotation for the current period — check `/var/lib/logrotate/status`. (b) The file is matched by a *different*, earlier policy stanza; logrotate applies the first match and warns about duplicates (`error: ... duplicate log entry`). (c) The size condition is `minsize`/`size` semantics you misread, or the time directive has not elapsed and no `maxsize` is set — 2 GB with `weekly` and no `maxsize` genuinely does not need rotating until the week is up.

**Q7.8** Debian's `/var/log` contains files owned by non-root groups (notably `adm`, and directories writable by other users), and logrotate refuses to rotate files in a directory it does not own without being told which user/group to `setuid`/`setgid` to — this is a deliberate symlink/privilege-escalation defence. `su root adm` grants that. Without it: `error: skipping "/var/log/syslog" because parent directory has insecure permissions (It's world writable or writable by group which is not "root") Set "su" directive in config file to tell logrotate which user/group should be used for rotation.`

### Exercise 8

**Q8.1** A process is holding an open file descriptor on a log file that has already been unlinked. The space is not released until the descriptor is closed, so `du` (which walks directory entries) cannot see it while `df` (which reads the superblock) does. `lsof +L1` finds it — a file with link count 0.

The correct remediation is to make the holder release it: `systemctl restart rsyslog`, or signal it to reopen (`systemctl kill -s HUP rsyslog`). The tempting-but-wrong move is to reboot, or to keep hunting for large files with `du` — and the actively harmful one is `rm`-ing more files, which does nothing because the space was never in a directory entry to begin with. (A safe stopgap when you cannot restart the process: `: > /proc/PID/fd/N` truncates the deleted file through its descriptor and frees the space immediately.)

**Q8.2** journald keeps journal files mmap'd and maintains an internal index. `rm`-ing the file it is actively writing leaves journald appending to an unlinked inode — the space is not freed (see Q8.1) and the records are unreachable. `journalctl --rotate` first makes journald close the active file, seal it, and open a fresh one; only then are the old files inert and safe to remove. Better still, use `journalctl --vacuum-*`, which does the whole sequence correctly.

**Q8.3** (a) journald is not forwarding — `ForwardToSyslog` is `no`, so rsyslog's `imuxsock` never receives the message. (b) rsyslog is running but reading from the wrong source, or `imjournal`'s state file is stale/corrupt (`/var/lib/rsyslog/imjournal.state`) and it is waiting at a cursor position that no longer exists. `rsyslogd -N1` validates *syntax* only; it says nothing about inputs actually delivering. Confirm with `journalctl -u rsyslog -b` and `ss -xlp | grep journal`.

**Q8.4**
- `/var/log/wtmp` — successful logins/logouts and reboots. Read with **`last`**.
- `/var/log/btmp` — **failed** login attempts. Read with **`lastb`** (root only).
- `/var/log/lastlog` — the most recent login per user, a sparse indexed file. Read with **`lastlog`**.

All three are binary `utmp`-format records written directly by PAM/login, not by journald or rsyslog — which is why they survive a journald outage and why they need their own logrotate stanza.

**Q8.5** Yes. Each journal file is independently sealed and hash-chained, and `journalctl` opens the set of files, skipping any it cannot parse (it prints the failure and continues). A corrupt file costs you the records in that file only. This is the practical argument for a moderate `SystemMaxFileSize`: it bounds the blast radius of a single corruption event as well as the granularity of vacuuming.

</details>