# LPIC-1 — Topic 108.3: Mail Transfer Agent (MTA) Basics
## Guided Exercises (Exam 102-500, version 5.0)

**Official objective reference:** <https://www.lpi.org/our-certifications/exam-102-objectives/> (topic 108.3 lives in the 102-500 exam; the 101-500 objective list is at <https://www.lpi.org/our-certifications/exam-101-objectives/>).

The objective's own scope note says *"no configuration of MTAs is required"* — what is examined is **aliases**, **forwarding**, the **sendmail-compatible command layer**, and **awareness of the four classic MTAs**. These exercises cover that examinable core and then push into the production diagnostics an SRE actually needs: queue anatomy, deferral reasons, loop detection, and delivery-agent evidence in the logs.

---

## Lab Environment

> **Safety notice.** An MTA listening on a public interface without recipient restrictions is an **open relay** and will be abused within hours. Every exercise below binds Postfix to loopback only (`inet_interfaces = loopback-only`). Do not change that in the lab, and do not expose TCP/25 from your workstation.

Use a disposable VM or container (Debian 12 / Ubuntu 24.04 assumed; RHEL/Fedora differences are called out inline). You need `root`.

```bash
# Debian/Ubuntu
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils

# RHEL/Rocky/Fedora
sudo dnf install -y postfix s-nail
sudo systemctl enable --now postfix
```

On Debian the installer runs `debconf`. If it prompts interactively, choose **"Local only"** and accept the default system mail name. To force that non-interactively:

```bash
sudo debconf-set-selections <<'EOF'
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string mail.lab.example
EOF
```

Create two unprivileged users used throughout:

```bash
sudo useradd -m -s /bin/bash alice
sudo useradd -m -s /bin/bash bob
```

---

## Exercise 1 — Identify the installed MTA and the sendmail compatibility layer

**Why it matters.** In an incident you inherit a host, not a decision. Before you touch anything you must answer: *which* MTA is running, and *is `/usr/sbin/sendmail` really Sendmail?* On virtually every modern Linux system it is not — it is a compatibility binary shipped by Postfix or Exim that implements Sendmail's command-line interface. Scripts, cron, PHP's `mail()`, and monitoring agents all call that path.

1. Find which MTA packages are installed.

   ```bash
   # Debian/Ubuntu
   dpkg -l | grep -E 'postfix|exim|sendmail|qmail'
   # RHEL family
   rpm -qa | grep -E 'postfix|exim|sendmail|qmail'
   ```

   Expected (Debian, Postfix installed):

   ```
   ii  postfix   3.7.11-0+deb12u1  amd64  High-performance mail transport agent
   ```

2. Resolve what `/usr/sbin/sendmail` actually points to.

   ```bash
   ls -l /usr/sbin/sendmail /usr/bin/mailq /usr/bin/newaliases
   readlink -f /usr/sbin/sendmail
   ```

   Typical Debian result — the three names are one binary:

   ```
   lrwxrwxrwx 1 root root 26 Aug 20 10:11 /usr/sbin/sendmail -> ../sbin/postfix-sendmail
   lrwxrwxrwx 1 root root 21 Aug 20 10:11 /usr/bin/mailq -> ../sbin/sendmail
   lrwxrwxrwx 1 root root 21 Aug 20 10:11 /usr/bin/newaliases -> ../sbin/sendmail
   ```

   On RHEL the same job is done by the `alternatives` system under the `mta` family:

   ```bash
   alternatives --display mta
   ```

   ```
   mta - status is auto.
    link currently points to /usr/sbin/sendmail.postfix
   /usr/sbin/sendmail.postfix - priority 30
   ```

3. Ask the binary itself which implementation it is.

   ```bash
   /usr/sbin/sendmail -bv root 2>&1 | head -n 3   # generic: validate an address
   postconf mail_version                          # Postfix-specific
   ```

   ```
   mail_version = 3.7.11
   ```

4. Confirm what is actually listening, and on which interface.

   ```bash
   sudo ss -lntp '( sport = :25 )'
   postconf -n inet_interfaces mydestination myorigin
   ```

   ```
   State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
   LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=812,fd=13))

   inet_interfaces = loopback-only
   mydestination = $myhostname, mail.lab.example, localhost.localdomain, localhost
   ```

5. Inspect the running process tree — Postfix is a set of cooperating daemons under one supervisor.

   ```bash
   ps -eo pid,ppid,user,comm | grep -E 'master|qmgr|pickup'
   ```

   ```
    812     1 root     master
    815   812 postfix  qmgr
    819   812 postfix  pickup
   ```

**Checkpoint questions**

- **Q1.1** — Why do `mailq` and `newaliases` exist as symlinks to the Sendmail-compatible binary rather than as independent programs?
- **Q1.2** — A legacy backup script calls `/usr/sbin/sendmail -t`. Postfix is installed, Sendmail is not. Does the script work? Explain what `-t` does.
- **Q1.3** — `postconf -n` prints far fewer parameters than `postconf -d`. What is the difference, and why is `postconf -n` the right thing to paste into a ticket?
- **Q1.4** — `mydestination` and `myorigin` are both set. Which one decides *"this mail is for me, deliver it locally"* and which one decides *"this is the domain I stamp on outgoing local mail"*?
- **Q1.5** — Two MTA packages on Debian both want to own `/usr/sbin/sendmail`. What packaging mechanism prevents them from being installed at the same time?

---

## Exercise 2 — Send a message and read the delivery evidence in the log

**Why it matters.** "The mail was not delivered" is never a diagnosis. The log tells you the **queue ID**, the **delivery agent** (`relay=local`, `relay=smtp`), the **DSN code**, and the **status verb** (`sent`, `deferred`, `bounced`). Learn to read one full transaction end to end.

1. Open a follower on the mail log in a second terminal.

   ```bash
   # Debian/Ubuntu
   sudo tail -F /var/log/mail.log
   # RHEL family
   sudo tail -F /var/log/maillog
   # systemd-only hosts (no rsyslog)
   sudo journalctl -u postfix@- -f
   ```

2. Send a message from `root` to `alice`.

   ```bash
   echo "First lab message body." | mail -s "Lab 108.3 test" alice
   ```

3. Read the five log lines the transaction produced.

   ```
   Aug 26 09:20:11 mail postfix/pickup[819]:  A1B2C3D4E5: uid=0 from=<root>
   Aug 26 09:20:11 mail postfix/cleanup[830]: A1B2C3D4E5: message-id=<20260826092011.A1B2C3D4E5@mail.lab.example>
   Aug 26 09:20:11 mail postfix/qmgr[815]:    A1B2C3D4E5: from=<root@mail.lab.example>, size=438, nrcpt=1 (queue active)
   Aug 26 09:20:11 mail postfix/local[832]:   A1B2C3D4E5: to=<alice@mail.lab.example>, relay=local, delay=0.05, delays=0.03/0.01/0/0.01, dsn=2.0.0, status=sent (delivered to mailbox)
   Aug 26 09:20:11 mail postfix/qmgr[815]:    A1B2C3D4E5: removed
   ```

4. Confirm the mailbox on disk and its format.

   ```bash
   ls -l /var/mail/alice
   sudo head -n 1 /var/mail/alice
   postconf -n mail_spool_directory home_mailbox
   ```

   ```
   -rw-rw---- 1 alice mail 526 Aug 26 09:20 /var/mail/alice
   From root@mail.lab.example  Wed Aug 26 09:20:11 2026
   ```

   An empty `postconf -n home_mailbox` output means the parameter is at its default (unset) and delivery is **mbox** into `$mail_spool_directory`.

5. Read the mail as the user.

   ```bash
   sudo -u alice mail
   ```

   ```
   "/var/mail/alice": 1 message 1 new
   >N   1 root               Wed Aug 26 09:20  14/526   Lab 108.3 test
   ? 1
   ? q
   ```

6. Hand-drive an SMTP transaction against the local listener — this is the single most useful MTA diagnostic technique, because it separates *"the MTA rejects it"* from *"the client is broken"*.

   ```bash
   nc 127.0.0.1 25
   ```

   ```
   220 mail.lab.example ESMTP Postfix (Debian/GNU)
   EHLO test.local
   250-mail.lab.example
   250-PIPELINING
   250-SIZE 10240000
   250-ENHANCEDSTATUSCODES
   250-8BITMIME
   250 SMTPUTF8
   MAIL FROM:<root@mail.lab.example>
   250 2.1.0 Ok
   RCPT TO:<bob@mail.lab.example>
   250 2.1.5 Ok
   DATA
   354 End data with <CR><LF>.<CR><LF>
   Subject: Hand-typed SMTP

   Envelope and header recipients differ on purpose.
   .
   250 2.0.0 Ok: queued as F1E2D3C4B5
   QUIT
   221 2.0.0 Bye
   ```

**Checkpoint questions**

- **Q2.1** — In the `local` log line, what do `dsn=2.0.0` and `status=sent` mean, and how would the same line look if the recipient did not exist?
- **Q2.2** — The message you typed by hand in step 6 has **no `To:` header** yet it was delivered to `bob`. Which recipient did Postfix obey — the envelope or the header — and why does that distinction matter for aliases and mailing lists?
- **Q2.3** — Which process handed the locally-submitted message to the queue in step 3, and which one performed final delivery? Name both and state what `relay=local` tells you.
- **Q2.4** — What distinguishes **mbox** from **Maildir** delivery on disk, and which Postfix parameter switches a host to Maildir? Why does the value need a trailing character?
- **Q2.5** — The `delays=0.03/0.01/0/0.01` field has four numbers. What is the operational value of the last one being large while the first three are near zero?

---

## Exercise 3 — System-wide aliases: `/etc/aliases` and `newaliases`

**Why it matters.** `/etc/aliases` is the administrator-controlled redirection table for **local** recipients. Its most important production role is making `root`'s mail — cron failures, RAID degradation, `logwatch`, `smartd` — land in a human's inbox instead of rotting in `/var/mail/root`.

1. Inspect the current alias table and locate it authoritatively.

   ```bash
   postconf alias_maps alias_database
   sudo grep -vE '^\s*#|^\s*$' /etc/aliases
   ```

   ```
   alias_maps = hash:/etc/aliases
   alias_database = hash:/etc/aliases

   mailer-daemon: postmaster
   postmaster: root
   nobody: root
   hostmaster: root
   webmaster: root
   abuse: root
   ```

2. Add alias entries covering all four target types the format supports.

   ```bash
   sudo tee -a /etc/aliases >/dev/null <<'EOF'

   # --- lab 108.3 ---
   root:        alice
   sre-oncall:  alice, bob
   archive:     /var/mail/archive-drop
   tickets:     |/usr/local/bin/ticket-intake
   platform:    :include:/etc/mail/platform-team
   EOF

   sudo install -d -m 0755 /etc/mail
   printf 'alice\nbob\n' | sudo tee /etc/mail/platform-team >/dev/null
   ```

3. Try to use the new alias **before** rebuilding the database, and observe that nothing changes.

   ```bash
   echo "before newaliases" | mail -s "stale db" sre-oncall
   ```

   ```
   postfix/local[861]: C4D5E6F7A8: to=<sre-oncall@mail.lab.example>, relay=local, delay=0.04,
     dsn=5.1.1, status=bounced (unknown user: "sre-oncall")
   ```

4. Rebuild the indexed database and compare timestamps.

   ```bash
   ls -l /etc/aliases /etc/aliases.db
   sudo newaliases
   ls -l /etc/aliases /etc/aliases.db
   ```

   ```
   -rw-r--r-- 1 root root   765 Aug 26 09:41 /etc/aliases
   -rw-r--r-- 1 root root 12288 Aug 20 10:11 /etc/aliases.db      <-- older than the source
   ...
   -rw-r--r-- 1 root root 12288 Aug 26 09:42 /etc/aliases.db      <-- rebuilt
   ```

5. Verify the entry is genuinely in the compiled map, not just in the text file.

   ```bash
   postmap -q sre-oncall hash:/etc/aliases
   postmap -q nosuchalias hash:/etc/aliases; echo "exit=$?"
   ```

   ```
   alice, bob
   exit=1
   ```

6. Send again and watch the fan-out to two recipients.

   ```bash
   echo "paging the on-call rotation" | mail -s "after newaliases" sre-oncall
   ```

   ```
   postfix/qmgr[815]:  D5E6F7A8B9: from=<root@mail.lab.example>, size=445, nrcpt=2 (queue active)
   postfix/local[874]: D5E6F7A8B9: to=<alice@mail.lab.example>, orig_to=<sre-oncall@mail.lab.example>,
     relay=local, delay=0.06, dsn=2.0.0, status=sent (delivered to mailbox)
   postfix/local[875]: D5E6F7A8B9: to=<bob@mail.lab.example>, orig_to=<sre-oncall@mail.lab.example>,
     relay=local, delay=0.07, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

7. Prove that `root`'s mail now reaches `alice`.

   ```bash
   echo "simulated cron failure" | mail -s "cron output" root
   sudo grep -E 'orig_to=<root@' /var/log/mail.log | tail -n 1
   ```

8. Two equivalent ways to rebuild — know both.

   ```bash
   sudo newaliases                 # sendmail-compatible name
   sudo /usr/sbin/sendmail -bi     # the exact same operation, classic flag
   sudo postalias /etc/aliases     # Postfix-native equivalent
   ```

**Checkpoint questions**

- **Q3.1** — Why is editing `/etc/aliases` insufficient, and what exactly does `newaliases` produce? Give the two non-`newaliases` commands that do the same job.
- **Q3.2** — What is the difference between `alias_maps` and `alias_database`? Which one does `newaliases` act on, and what breaks if an administrator sets only one of them?
- **Q3.3** — The alias `tickets: |/usr/local/bin/ticket-intake` pipes mail into a program. Under which UID does that program run by default, and why is this entry a security-sensitive one? Name one safer alternative.
- **Q3.4** — Explain the `:include:` target type and why it is preferable to a long comma-separated list for a team distribution address.
- **Q3.5** — In step 6 the log shows `orig_to=`. What does that field prove, and how does it help you distinguish an `/etc/aliases` expansion from a plain misdirected send?
- **Q3.6** — An administrator writes `root: root@backup.example.net` in `/etc/aliases`. Is an alias target required to be a local user? What extra dependency does this introduce on a "local only" host?

---

## Exercise 4 — User-controlled forwarding: `~/.forward`

**Why it matters.** `/etc/aliases` needs root. `~/.forward` lets an unprivileged user redirect their own mail — and its **permission requirements are the number one reason it silently does nothing**. Postfix and Exim both refuse to honour a `.forward` that is group- or world-writable, or that lives in a home directory anyone else can write to. They fail *safely*, which means *quietly*.

1. Create a forward for `bob` pointing at `alice`.

   ```bash
   sudo -u bob bash -c 'echo "alice@mail.lab.example" > ~/.forward'
   sudo -u bob ls -l ~bob/.forward
   ```

   ```
   -rw-r--r-- 1 bob bob 25 Aug 26 10:02 /home/bob/.forward
   ```

2. Send to `bob` and confirm the redirect.

   ```bash
   echo "should land in alice's mailbox" | mail -s "forward test" bob
   ```

   ```
   postfix/local[901]: E6F7A8B9C0: to=<alice@mail.lab.example>, orig_to=<bob@mail.lab.example>,
     relay=local, delay=0.05, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

3. Keep a **local copy while forwarding** — the backslash form suppresses further `.forward` processing for that entry.

   ```bash
   sudo -u bob bash -c 'printf "\\\\bob\nalice@mail.lab.example\n" > ~/.forward'
   sudo -u bob cat ~bob/.forward
   ```

   ```
   \bob
   alice@mail.lab.example
   ```

   ```bash
   echo "copy plus forward" | mail -s "dual delivery" bob
   ```

   ```
   postfix/local[912]: F7A8B9C0D1: to=<bob@mail.lab.example>, relay=local, dsn=2.0.0, status=sent (delivered to mailbox)
   postfix/local[913]: F7A8B9C0D1: to=<alice@mail.lab.example>, orig_to=<bob@mail.lab.example>, relay=local, dsn=2.0.0, status=sent (delivered to mailbox)
   ```

4. **Break it deliberately** — make the file world-writable and observe the failure mode.

   ```bash
   sudo chmod 666 ~bob/.forward
   echo "insecure forward" | mail -s "perm test" bob
   ```

   ```
   postfix/local[925]: warning: not owner or unsafe permissions on /home/bob/.forward
   postfix/local[925]: A8B9C0D1E2: to=<bob@mail.lab.example>, relay=local, delay=0.06,
     dsn=2.0.0, status=sent (delivered to mailbox)
   ```

   Note carefully: the message was **delivered locally, not forwarded**, and the status is still `sent`. There is no bounce. Restore:

   ```bash
   sudo chmod 644 ~bob/.forward
   ```

5. Now build a **mail loop** and watch the MTA defend itself.

   ```bash
   sudo -u alice bash -c 'echo "bob@mail.lab.example" > ~/.forward'
   sudo -u bob   bash -c 'echo "alice@mail.lab.example" > ~/.forward'
   echo "loop probe" | mail -s "loop" alice
   ```

   ```
   postfix/local[940]: B9C0D1E2F3: to=<bob@mail.lab.example>, orig_to=<alice@mail.lab.example>,
     relay=local, delay=0.09, dsn=5.4.6, status=bounced (mail forwarding loop for bob@mail.lab.example)
   ```

6. Clean up before the next exercise.

   ```bash
   sudo rm -f ~alice/.forward ~bob/.forward
   ```

7. For contrast, note the equivalent mechanism on the other MTAs:

   | MTA | Per-user forwarding file | Notes |
   |---|---|---|
   | Postfix | `~/.forward` | Sendmail-compatible syntax; controlled by `forward_path` |
   | Sendmail | `~/.forward` | The original implementation |
   | Exim | `~/.forward` | Optional Sieve-style filter mode in the same file |
   | qmail | `~/.qmail` | Different syntax entirely; a dot-qmail file, not a `.forward` |

**Checkpoint questions**

- **Q4.1** — List the three ownership/permission conditions that must hold for `~/.forward` to be honoured, and state precisely what happens to a message when they do not.
- **Q4.2** — What does a leading backslash (`\bob`) mean inside `~/.forward`, and why is it *not* the same as writing `bob`?
- **Q4.3** — Compare `/etc/aliases` and `~/.forward` across four axes: who may edit it, whether a rebuild step is required, whose mail it affects, and where it is stored.
- **Q4.4** — Step 4's failure produced **no bounce and no error to the sender**. Explain why refusing to forward — rather than bouncing — is the correct security decision.
- **Q4.5** — `dsn=5.4.6` in step 5: what class of error is a 5.x.x code, and what would 4.x.x have implied instead?
- **Q4.6** — A user on a qmail host copies their working `~/.forward` from a Postfix host. What happens, and what should they have created instead?

---

## Exercise 5 — Queue anatomy, inspection, and deferral

**Why it matters.** The queue is where mail goes when it cannot be delivered *right now*. A growing `deferred` queue is a leading indicator of a downstream outage; a growing `active` queue is a capacity problem; a growing `hold` queue is usually someone's forgotten manual intervention. Reading `mailq` output fluently is table stakes.

1. Confirm the queue is empty, using both the compatible and native commands.

   ```bash
   mailq
   postqueue -p
   /usr/sbin/sendmail -bp
   ```

   ```
   Mail queue is empty
   ```

2. Look at the queue directory structure on disk.

   ```bash
   postconf queue_directory
   sudo ls -l /var/spool/postfix/
   ```

   ```
   queue_directory = /var/spool/postfix
   drwx------  2 postfix root  active
   drwx------ 18 postfix root  bounce
   drwx------ 18 postfix root  deferred
   drwx------  2 postfix root  hold
   drwx------  2 postfix root  incoming
   drwx-wx---  2 postfix postdrop maildrop
   ```

3. Force a deferral: address a message to a domain that cannot be reached from the lab.

   ```bash
   echo "bound for nowhere" | mail -s "deferred probe" someone@invalid.example.test
   sleep 5
   mailq
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   C0D1E2F3A4      438 Wed Aug 26 10:31:02  root@mail.lab.example
        (Host or domain name not found. Name service error for name=invalid.example.test
         type=A: Host not found)
                                            someone@invalid.example.test

   -- 0 Kbytes in 1 Request.
   ```

4. Inspect the queued message itself — headers, envelope, and body, without touching the spool files by hand.

   ```bash
   sudo postcat -q C0D1E2F3A4 | head -n 20
   ```

   ```
   *** ENVELOPE RECORDS deferred/C/C0D1E2F3A4 ***
   message_arrival_time: Wed Aug 26 10:31:02 2026
   named_attribute: rewrite_context=local
   sender: root@mail.lab.example
   *** MESSAGE CONTENTS deferred/C/C0D1E2F3A4 ***
   Received: by mail.lab.example (Postfix, from userid 0)
       id C0D1E2F3A4; Wed, 26 Aug 2026 10:31:02 +0000
   To: someone@invalid.example.test
   Subject: deferred probe
   ...
   *** HEADERS EXTRACTED deferred/C/C0D1E2F3A4 ***
   *** MESSAGE FILE END deferred/C/C0D1E2F3A4 ***
   ```

5. Ask for an immediate retry, then place the message on hold and release it.

   ```bash
   sudo postqueue -f              # flush: retry the whole deferred queue now
   sudo postsuper -h C0D1E2F3A4   # hold
   mailq | head -n 3
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   C0D1E2F3A4!     438 Wed Aug 26 10:31:02  root@mail.lab.example
   ```

   ```bash
   sudo postsuper -H C0D1E2F3A4   # release from hold
   sudo postsuper -r C0D1E2F3A4   # requeue (re-run through cleanup, new queue ID)
   ```

6. Summarise the queue the way you would during an incident, and then drain it.

   ```bash
   qshape deferred 2>/dev/null | head -n 5     # if postfix-doc/qshape is installed
   mailq | awk '/^[A-F0-9]/ {n++} END {print n+0, "queued"}'
   sudo postsuper -d ALL deferred              # delete every deferred message
   ```

   ```
   postsuper: Deleted: 1 message
   ```

7. Know the retry policy that governs how long a message survives.

   ```bash
   postconf -d maximal_queue_lifetime bounce_queue_lifetime \
               minimal_backoff_time maximal_backoff_time queue_run_delay
   ```

   ```
   maximal_queue_lifetime = 5d
   bounce_queue_lifetime = 5d
   minimal_backoff_time = 300s
   maximal_backoff_time = 4000s
   queue_run_delay = 300s
   ```

**Checkpoint questions**

- **Q5.1** — Name the three commands that print the mail queue on a Postfix host and explain why three names exist for one function.
- **Q5.2** — In `mailq` output, what do the suffixes `*` and `!` after a queue ID mean, and what does an entirely bare ID (no suffix) indicate?
- **Q5.3** — Distinguish the `incoming`, `active`, `deferred`, and `hold` queue directories by the condition that puts a message in each.
- **Q5.4** — A message shows `(connect to mx.example.net[203.0.113.25]:25: Connection timed out)`. Is this a permanent or a temporary failure, what will the MTA do next, and when does it finally give up?
- **Q5.5** — What is the operational difference between `postsuper -r` and `postqueue -f`? Which one changes the queue ID, and why would you ever want that?
- **Q5.6** — Why should you never edit or delete files in `/var/spool/postfix/deferred/` directly with `rm`?
- **Q5.7** — `/var/spool/postfix/maildrop` is mode `drwx-wx---` owned by `postfix:postdrop`. Explain how an unprivileged user can submit mail into a directory they cannot read.

---

## Exercise 6 — Recognise the four MTAs by their fingerprints

**Why it matters.** The objective explicitly names **postfix, sendmail, exim, and qmail**. You will not configure them in the exam, but you must recognise a host by its config paths, its native queue command, and its process names — often before you have shell history or documentation.

1. Build a recognition script that works regardless of which MTA is present.

   ```bash
   cat <<'EOF' | sudo tee /usr/local/bin/whichmta >/dev/null
   #!/bin/sh
   for p in /etc/postfix/main.cf /etc/mail/sendmail.cf /etc/exim4/exim4.conf.template \
            /etc/exim/exim.conf /var/qmail/control/me; do
       [ -e "$p" ] && echo "config present: $p"
   done
   command -v postconf   >/dev/null && echo "native: postconf (Postfix)"
   command -v exim       >/dev/null && echo "native: exim (Exim)"
   command -v qmail-qstat>/dev/null && echo "native: qmail-qstat (qmail)"
   [ -d /etc/mail/m4 ]   && echo "native: m4 macro tree (Sendmail)"
   EOF
   sudo chmod +x /usr/local/bin/whichmta
   whichmta
   ```

   ```
   config present: /etc/postfix/main.cf
   native: postconf (Postfix)
   ```

2. Memorise the fingerprint table.

   | | **Postfix** | **Sendmail** | **Exim** | **qmail** |
   |---|---|---|---|---|
   | Main config | `/etc/postfix/main.cf`, `master.cf` | `/etc/mail/sendmail.cf` (generated from `sendmail.mc` via `m4`) | `/etc/exim4/` (Debian split config) or `/etc/exim/exim.conf` | `/var/qmail/control/*` (one file per setting) |
   | Show queue | `postqueue -p` / `mailq` | `sendmail -bp` / `mailq` | `exim -bp` / `mailq` | `qmail-qstat`, `qmail-qread` |
   | Flush queue | `postqueue -f` | `sendmail -q` | `exim -qff` | `qmail-tcpok` + SIGALRM to `qmail-send` |
   | Delete one message | `postsuper -d <id>` | `rm` from `/var/spool/mqueue` | `exim -Mrm <id>` | `qmail-remove` (third-party) |
   | Test address routing | `postmap -q`, `sendmail -bv` | `sendmail -bt` | `exim -bt <addr>` | — |
   | Rebuild alias db | `newaliases` / `postalias` | `newaliases` / `makemap` | (Debian) `update-exim4.conf` | — (uses `~/.qmail`) |
   | Per-user forward | `~/.forward` | `~/.forward` | `~/.forward` | `~/.qmail` |
   | Architecture | multiple small least-privilege daemons | one large monolithic binary | one binary, many-phase router/transport config | multiple small daemons, `daemontools` supervision |
   | Version string | `postconf mail_version` | `sendmail -d0.1 -bt </dev/null` | `exim -bV` | `/var/qmail/bin/qmail-send` (no `--version`) |

3. Exercise the sendmail-compatible flags that **all** of them implement — these are the portable ones, and the ones worth memorising.

   ```bash
   /usr/sbin/sendmail -bp                       # print the queue
   printf 'To: alice\nSubject: via -t\n\nbody\n' | /usr/sbin/sendmail -t
   /usr/sbin/sendmail -f noreply@lab.example -- alice   # set the envelope sender
   /usr/sbin/sendmail -bv alice                 # verify without delivering
   ```

   ```
   Mail queue is empty
   ...
   alice... deliverable: mailer local, user alice
   ```

4. If you have Exim available in a second container, contrast one command directly:

   ```bash
   exim -bt bob@mail.lab.example
   ```

   ```
   bob@mail.lab.example
     router = localuser, transport = mail_spool
   ```

**Checkpoint questions**

- **Q6.1** — You land on an unknown host. `mailq` works, `postconf` is not found, and `/etc/exim4/` exists. Which MTA is it, and which native command shows its queue?
- **Q6.2** — Which of the four MTAs does *not* use `~/.forward`, and what does it use instead?
- **Q6.3** — Why does a `sendmail.cf` file exist alongside a `sendmail.mc` file, and which of the two should an administrator edit?
- **Q6.4** — Name the sendmail-compatible flags for: print queue, read recipients from the message headers, set the envelope sender, run as a daemon, and rebuild the alias database.
- **Q6.5** — Postfix and qmail are both described as "multiple cooperating daemons" while Sendmail is a single `setuid root` binary. State the security argument this architecture makes.

---

## Exercise 7 — Diagnostic scenarios (no hints)

**Why it matters.** Each of these is a real failure shape. Reproduce it, then explain it before reading the answer.

1. **The alias that does nothing.**

   ```bash
   sudo sed -i 's/^root:.*/root: bob/' /etc/aliases
   echo "scenario 1" | mail -s "s1" root
   sudo grep -E 'orig_to' /var/log/mail.log | tail -n 1
   ```

   Mail still arrives for `alice`, not `bob`. **Why?**

2. **The forward that vanished.**

   ```bash
   sudo -u alice bash -c 'echo "bob@mail.lab.example" > ~/.forward'
   sudo chmod 777 /home/alice
   echo "scenario 2" | mail -s "s2" alice
   sudo grep -iE 'warning.*forward' /var/log/mail.log | tail -n 1
   ```

   The file is mode `0644` and owned by `alice`, yet forwarding is ignored. **Why?**
   (Restore afterwards: `sudo chmod 755 /home/alice; sudo rm -f ~alice/.forward`)

3. **The queue that never drains.**

   ```bash
   mailq
   ```

   ```
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   D1E2F3A4B5!    1204 Mon Aug 24 03:12:41  monitoring@mail.lab.example
                                            pager@example.net
   ```

   `postqueue -f` has no effect on this entry. **Why, and what is the fix?**

4. **The application that cannot send.** A PHP app calls `mail()`; nothing is queued and the log is silent. `ls -l /usr/sbin/sendmail` returns *No such file or directory*, but Exim is installed and running. **What is the diagnosis and the fix?**

5. **The bounce storm.** Root's mail is aliased to `oncall@corp.example`, whose MX is unreachable for six hours. `mailq` shows 900 deferred messages from `cron`. **What are the two competing risks, and which knob would you touch first?**

**Checkpoint questions**

- **Q7.1** through **Q7.5** — one per scenario above.

---

## Cleanup

```bash
sudo postsuper -d ALL
sudo sed -i '/# --- lab 108.3 ---/,$d' /etc/aliases
sudo newaliases
sudo rm -f ~alice/.forward ~bob/.forward /etc/mail/platform-team /usr/local/bin/whichmta
sudo userdel -r alice; sudo userdel -r bob
```

---

<details>
<summary><strong>Answer key — click to expand</strong></summary>

### Exercise 1 — MTA identification

**A1.1** — Sendmail defined the de-facto UNIX mail submission interface long before Postfix or Exim existed, and thousands of programs (cron, `logrotate`, `smartd`, PHP, monitoring agents, shell scripts) hard-code `/usr/sbin/sendmail`, `mailq`, and `newaliases`. Every modern MTA therefore ships a **compatibility layer** implementing those command names and their classic flags. In Postfix the three names are the *same binary*, which selects its behaviour from `argv[0]`: invoked as `mailq` it does `sendmail -bp`; invoked as `newaliases` it does `sendmail -bi`. One binary, three entry points.

**A1.2** — Yes, it works. `-t` tells the submission program to **read the recipient list from the message's own headers** (`To:`, `Cc:`, `Bcc:`) instead of from the command line, and to strip `Bcc:` before queueing. Postfix's compat binary implements `-t` identically, so the legacy script is unaffected by the MTA swap. This portability is exactly the point of the compatibility layer.

**A1.3** — `postconf -d` prints the **built-in defaults** (hundreds of parameters); `postconf -n` prints only the parameters whose values **differ from the default**, i.e. what is actually in `main.cf`. `postconf -n` is the right thing to paste into a ticket because it is short, it is the complete set of local decisions, and it cannot mislead a reader into thinking a default value was deliberately chosen. `postconf -n` is also the standard artefact requested on the postfix-users mailing list.

**A1.4** — `mydestination` is the **inbound** decision: a list of domains for which this host considers itself the final destination and performs local delivery (via the `local` delivery agent and `/etc/aliases`). `myorigin` is the **outbound** decision: the domain appended to locally-submitted addresses that have no domain part, so `root` becomes `root@mail.lab.example`. Putting a domain in `mydestination` that you do not actually serve makes you black-hole its mail; putting a domain there that also appears in `relay_domains` or `virtual_mailbox_domains` is a classic misconfiguration.

**A1.5** — Debian's virtual package mechanism. Each MTA package declares `Provides: mail-transport-agent, default-mta` together with `Conflicts: mail-transport-agent` and `Replaces: mail-transport-agent`. The mutual `Conflicts` on the virtual package guarantees at most one MTA is installed at a time, so ownership of `/usr/sbin/sendmail` is unambiguous. The RHEL family solves the same problem differently, allowing coexistence and arbitrating with `alternatives --config mta`.

---

### Exercise 2 — Delivery evidence

**A2.1** — `dsn=` is the **Delivery Status Notification** enhanced status code (RFC 3463): `2.0.0` = success, class 2 = positive completion. `status=sent` is Postfix's verdict for the recipient, and the parenthetical `(delivered to mailbox)` names the mechanism. For a non-existent recipient the same line becomes:

```
dsn=5.1.1, status=bounced (unknown user: "nosuchuser")
```

`5.1.1` is *permanent failure, addressing, bad destination mailbox address*. The three status verbs to know are **sent**, **deferred** (temporary, will retry), and **bounced** (permanent, non-delivery report generated).

**A2.2** — Postfix obeyed the **envelope** recipient, given in `RCPT TO:`. The `To:`/`Cc:` headers are message *content* and have no bearing on routing. This distinction is fundamental:

- It is why **Bcc** works at all — envelope recipients that appear in no header.
- It is why **aliases and mailing lists** function: the envelope recipient is rewritten to the expansion while the headers still read `sre-oncall@…`, which is exactly what the human reader should see.
- It is why bounces go to the **envelope sender** (`MAIL FROM`, the `Return-Path`), not to the `From:` header.

**A2.3** — `postfix/pickup` collected the locally-submitted message from the `maildrop` directory and handed it to `cleanup`, which normalised headers and wrote it into `incoming`; `qmgr` moved it to `active` and dispatched it; the `postfix/local` delivery agent performed final delivery. `relay=local` tells you the **local delivery agent** handled it — no SMTP conversation with any remote host took place, so the message never left the machine. (A remote delivery would read `relay=mx.example.net[203.0.113.25]:25`.)

**A2.4** — **mbox** is a single flat file per user (`/var/mail/alice`) containing all messages concatenated, each starting with a `From ` separator line; it requires file locking and a concurrent writer can corrupt it. **Maildir** is a directory tree (`~/Maildir/{new,cur,tmp}/`) with **one file per message** and unique filenames, so delivery is lock-free and NFS-safe. Postfix switches with `home_mailbox = Maildir/`. The **trailing slash is mandatory** — it is precisely how Postfix distinguishes "deliver in Maildir format into this directory" from "append to this mbox file". Same rule for `mail_spool_directory`.

**A2.5** — The four numbers are: time in **before-queue-manager** stages (`pickup`/`cleanup`), time in the **queue manager** before handoff, time **connecting/sending** to the next hop, and time for the **transmission plus remote acknowledgement**. A large fourth value with near-zero first three means the local host was fast and the **remote/destination side was slow to accept and acknowledge** the data — a downstream problem (slow content scanner, overloaded mailstore, throttling receiver), not a local one. This one field routes an escalation correctly in seconds.

---

### Exercise 3 — `/etc/aliases`

**A3.1** — `/etc/aliases` is a plain-text source file; the delivery agent never reads it at runtime. `newaliases` compiles it into an **indexed database** — `/etc/aliases.db` (Berkeley DB hash) on Debian/RHEL, `/etc/aliases.lmdb` where LMDB is the default map type — so lookups are O(1) rather than a linear scan of a file that may hold thousands of entries. Equivalent commands: `sendmail -bi` (the classic flag `newaliases` is a shorthand for) and `postalias /etc/aliases` (Postfix-native). Forgetting this rebuild is the single most common `/etc/aliases` error, and it fails as `status=bounced (unknown user: …)`.

**A3.2** — `alias_maps` is the list of lookup tables the **`local` delivery agent consults at delivery time**. `alias_database` is the list of tables **`newaliases` rebuilds**. They are separate because a site may consult maps it does not own (LDAP, NIS, a shared read-only hash) and must not attempt to rebuild them. Failure modes: set only `alias_maps` and `newaliases` rebuilds nothing, so edits never take effect; set only `alias_database` and the rebuild succeeds but the map is never consulted, so aliases are ignored entirely. On a normal host both should reference the same `hash:/etc/aliases`.

**A3.3** — The command runs as the **`default_privs` user** (`nobody` by default in Postfix), *not* as root — Postfix deliberately refuses to run alias-piped commands with privilege. It is security-sensitive because it makes an arbitrary program **reachable by anyone who can send mail to that address**, with attacker-controlled data on stdin: shell metacharacters, unbounded message size, and crafted headers all become an injection surface. Safer alternatives: deliver to a mailbox and have a **polling** consumer read it out-of-band; or use a purpose-built, sandboxed local delivery transport in `master.cf` with an explicit unprivileged UID and `flags=` restrictions. Note also that a pipe target's **exit code** matters — `EX_TEMPFAIL` (75) causes a retry, non-zero others cause a bounce.

**A3.4** — `:include:/path/to/file` tells the alias expansion to read the **recipient list from an external file**, one address per line. It is preferable for a team address because: the member list can be edited by a delegated owner with write access to only that file (no root, no `/etc/aliases` access); it needs **no `newaliases` run** after a change, since the file is read at delivery time; it keeps `/etc/aliases` readable instead of holding 200-character lines; and it can be generated by configuration management or exported from an HR system independently of the MTA config.

**A3.5** — `orig_to=` records the **recipient address as it was before alias or `.forward` expansion**, while `to=` shows the final resolved recipient. Its presence is direct proof that a **redirection mechanism fired**. If mail for `sre-oncall@` lands in Alice's mailbox with `orig_to=<sre-oncall@…>`, the alias worked. If it lands there with **no `orig_to` field at all**, no expansion happened — the sender simply addressed Alice, or a mail client rewrote the address. This single field separates "the alias is misconfigured" from "the sender is confused".

**A3.6** — No, an alias target need not be local; it may be any valid address, a file path, a pipe, or an `:include:`. Pointing `root` at a remote address introduces a hard **outbound-delivery dependency on exactly the mail that reports the host is broken**: if DNS is down, the network is partitioned, or the relay is unreachable, the RAID-failure notification defers in the local queue and nobody is paged. The resilient pattern is dual delivery — `root: \root, oncall@corp.example` — keeping a local copy that survives any network failure while still forwarding to a human.

---

### Exercise 4 — `~/.forward`

**A4.1** — All three must hold:
1. The file is **owned by the user** whose mail is being delivered (or by root).
2. The file is **not group- or world-writable** (mode `0644`/`0600`, never `g+w`/`o+w`).
3. The **home directory itself** is not group- or world-writable, and neither is any parent directory in the path.

When any condition fails, the MTA **logs a warning and silently ignores the file**, delivering to the user's normal local mailbox instead. There is **no bounce and no notification to the sender or the user** — the delivery reports `status=sent`. This is why "my forward stopped working" investigations must start with `ls -ld ~ ~/.forward`, not with the file's contents.

**A4.2** — A leading backslash means **"deliver to this local user's mailbox directly, and do not expand this address any further"** — alias and `.forward` processing is suppressed for that entry. Writing plain `bob` inside `bob`'s own `~/.forward` would re-enter forward processing for `bob`, read the same file again, and produce an infinite loop that the MTA aborts with `dsn=5.4.6, status=bounced (mail forwarding loop)`. `\bob` is therefore the **only** correct way to express "keep a local copy while also forwarding elsewhere". The same backslash convention works in `/etc/aliases` (`root: \root, oncall@corp.example`).

**A4.3** —

| Axis | `/etc/aliases` | `~/.forward` |
|---|---|---|
| Who may edit | root only | the mailbox owner, unprivileged |
| Rebuild required | **yes** — `newaliases` / `postalias` / `sendmail -bi` | **no** — read at delivery time |
| Scope | any local recipient name on the host, including names with no matching UNIX account | exactly one user: the file's owner |
| Storage | one system file, compiled to an indexed `.db` | one plain-text file per home directory |
| Extra target types | `:include:`, files, pipes, multiple recipients | files, pipes, multiple recipients (no `:include:`) |

**A4.4** — Because the permission check is an **authorisation** check, not a syntax check. A group- or world-writable `.forward` (or home directory) means *someone other than the owner can decide where this user's mail goes* — an attacker with write access could exfiltrate a colleague's mail to an external address, or point the file at a `|command` pipe and obtain code execution on every incoming message. Bouncing would leak the existence of the misconfiguration to any external sender who probes for it, and would break delivery for a condition the *sender* cannot fix. Ignoring the file **fails closed on the redirection while still delivering the mail**: no data is lost, no data is disclosed, and the evidence is in the log for the administrator.

**A4.5** — `5.x.x` is a **permanent** failure (RFC 3463 class 5): the MTA will not retry, the message leaves the queue, and a non-delivery report goes to the envelope sender. `4.x.x` would have been a **transient** failure — the message stays in the `deferred` queue and is retried on the backoff schedule until `maximal_queue_lifetime` expires. The sub-parts of `5.4.6` are *class 5 = permanent, subject 4 = network/routing, detail 6 = routing loop detected*. The practical rule: 4.x.x means wait, 5.x.x means fix something.

**A4.6** — Nothing happens — qmail does not read `~/.forward` at all, so the mail is delivered normally to the user's local mailbox and the forward is silently inert. qmail uses **`~/.qmail`** (and `~/.qmail-extension` files for address extensions), with a different syntax: a bare line beginning with `&` forwards to an address (`&alice@example.net`), a line beginning with `|` pipes to a program, a line beginning with `/` or `.` delivers to a file or Maildir, and an **empty `~/.qmail` file** means "discard". The concept maps across; the file name and syntax do not.

---

### Exercise 5 — The queue

**A5.1** — `mailq`, `postqueue -p`, and `sendmail -bp`. All three produce identical output because `mailq` is a symlink to the Sendmail-compat binary, which translates `-bp` into a `postqueue -p` request. Three names exist for compatibility reasons: `mailq` and `sendmail -bp` are the historic Sendmail interfaces that scripts and administrators already know, while `postqueue` is Postfix's own command with additional native options (`-f` flush, `-s <site>`, `-j` JSON output). Note that `postqueue` is `setgid postdrop`, which is how an unprivileged user is allowed to read the queue at all.

**A5.2** — `*` marks a message in the **active** queue — the queue manager has it in hand and delivery is in progress or imminent. `!` marks a message **on hold** — an administrator ran `postsuper -h`, and it will not be delivered until explicitly released with `postsuper -H`. A bare ID with no suffix means the message is **deferred**: a previous attempt failed temporarily and it is waiting for its next scheduled retry. On a healthy host, `mailq` is empty or shows a handful of `*` entries; a long list of bare IDs is a deferral problem, and `!` entries that nobody remembers creating are stuck mail.

**A5.3** —
- **`incoming`** — messages that `cleanup` has fully written but the queue manager has not yet picked up. Normal transient state.
- **`active`** — messages the queue manager is currently working on. This queue is deliberately **bounded** (`qmgr_message_active_limit`, default 20 000) so memory use stays flat regardless of how much mail is backlogged.
- **`deferred`** — messages whose delivery failed with a **transient** (4.x.x) error, awaiting retry on an exponential backoff between `minimal_backoff_time` and `maximal_backoff_time`.
- **`hold`** — messages an administrator or a policy rule has frozen. Nothing in `hold` is ever attempted, and nothing ages out of it; it is a manual-intervention queue.

(Also present: `maildrop` for local submissions awaiting `pickup`, `bounce`/`defer` holding per-message failure logs, and `corrupt` for unreadable files.)

**A5.4** — **Temporary.** A connection timeout is a 4.x.x-class condition: the destination may simply be down or throttling, so declaring the address permanently undeliverable would destroy legitimate mail. The MTA leaves the message in the `deferred` queue and retries with **exponential backoff**, starting at `minimal_backoff_time` (300 s) and doubling up to `maximal_backoff_time` (4000 s). After `maximal_queue_lifetime` (default **5 days**) it gives up and returns a permanent non-delivery report to the envelope sender. A separate `bounce_queue_lifetime` governs how long the MTA keeps retrying delivery of the *bounce message itself*.

**A5.5** — `postqueue -f` (**flush**) asks the queue manager to **retry every deferred message immediately**, ignoring the backoff timers. The messages are untouched — same queue IDs, same content, same headers. `postsuper -r` (**requeue**) pulls a message back through `cleanup`, which means header rewriting, `canonical`/`virtual` address mapping, and `header_checks` are **re-applied**, and the message receives a **new queue ID** (plus an extra `Received:` header). You want the requeue path when the deferral was caused by a *configuration* error you have now fixed — a wrong `relayhost`, a bad canonical map, a header_checks rule — because a plain flush would re-deliver the message with the old, wrong rewriting still baked in.

**A5.6** — Because the queue is a **live, transactional data structure** owned by running daemons, not a directory of inert files. A message consists of envelope records, content, and extracted headers written in a specific format, and its presence is coordinated with the queue manager's in-memory state and with per-message `defer`/`bounce` logbooks in sibling directories. Removing files underneath a running `qmgr` can leave orphaned bounce logs, trigger "file not found" errors mid-delivery, or move a message to the `corrupt` queue. Additionally the hashed subdirectory layout (`deferred/C/C0D1E2F3A4`) means a naive `rm` in the top directory finds nothing. Always use `postsuper` (`-d`, `-h`, `-H`, `-r`), which is written to manipulate the queue safely against a live daemon.

**A5.7** — The directory is mode `drwx-wx---`, owner `postfix`, group `postdrop`. The `-wx` for group grants **write and execute (traverse) but not read**: a member of `postdrop` may *create* a file in the directory and traverse into it, but cannot `ls` it or enumerate other users' submissions. The `postdrop` command is installed **`setgid postdrop`**, so any user running it temporarily gains that group and can drop a message in. This is the least-privilege submission path — no `setuid root` anywhere, no ability to read other people's queued mail, and the Postfix daemons themselves never run with the submitting user's privileges. It is the concrete expression of the architectural argument in A6.5.

---

### Exercise 6 — The four MTAs

**A6.1** — **Exim.** `mailq` works because Exim also ships a Sendmail-compatibility layer; `postconf` being absent rules out Postfix; `/etc/exim4/` is Debian's split-configuration directory for Exim 4. The native queue command is **`exim -bp`** (with `exiqgrep` for filtering, `exim -bpc` for a bare count, `exim -M <id>` to force one message, and `exim -Mrm <id>` to remove one).

**A6.2** — **qmail**. It uses **`~/.qmail`** with its own syntax: `&address` to forward, `|command` to pipe, `/path/` or `./Maildir/` to deliver to a file or Maildir, and an empty file to discard. Address extensions are supported by additional files (`~/.qmail-lists`, matching `user-lists@…`), which is qmail's distinctive per-user routing feature.

**A6.3** — `sendmail.cf` is Sendmail's actual runtime configuration: a dense rule-set language of `S`/`R` lines and rewriting rulesets that is famously difficult to write correctly by hand. `sendmail.mc` is the **`m4` macro source** — a short, readable file of `define()`/`FEATURE()`/`MAILER()` directives — from which `sendmail.cf` is generated (`m4 /etc/mail/sendmail.mc > /etc/mail/sendmail.cf`, or `make -C /etc/mail`). An administrator edits **`sendmail.mc`** and regenerates; hand-editing `sendmail.cf` produces changes that are lost on the next regeneration and that are very easy to get subtly wrong.

**A6.4** —
- **`-bp`** — print the mail queue (what `mailq` invokes).
- **`-t`** — read the recipient list from the message's own `To:`/`Cc:`/`Bcc:` headers, stripping `Bcc:`.
- **`-f <address>`** — set the **envelope** sender (`MAIL FROM`, the `Return-Path` that bounces go to). Not to be confused with `-F`, which sets the full *name* in the `From:` header.
- **`-bd`** — run as a background daemon listening on SMTP.
- **`-bi`** — rebuild the alias database (what `newaliases` invokes).

Also worth knowing: **`-q`** to flush the queue, **`-bs`** to speak SMTP on stdin/stdout, **`-bv`** to verify an address without delivering, and **`-v`** for verbose transcript.

**A6.5** — The argument is **privilege separation and least privilege**. Sendmail historically ran as a single large `setuid root` binary that parsed untrusted, attacker-supplied network input (SMTP commands, headers, addresses) in the same address space that held root privilege — so any parsing bug was directly a remote root compromise, which is exactly the history that produced its CVE record. Postfix and qmail decompose the same job into many small single-purpose programs (`smtpd`, `cleanup`, `qmgr`, `local`, `smtp`, `pickup`, `trivial-rewrite`), each running **unprivileged**, each doing one thing, communicating over well-defined internal interfaces, and supervised by a small `master` process. The components that touch the network hold no privilege, the components that hold privilege never touch the network, and the queue is reached only through the `setgid postdrop` submission path (A5.7). A compromise of one component therefore yields the privileges of that component alone, not of the machine.

---

### Exercise 7 — Diagnostics

**A7.1** — `/etc/aliases` was edited but **`newaliases` was never run**, so `/etc/aliases.db` still contains the old `root: alice` mapping. The delivery agent reads the compiled database, not the text file, so the edit had no effect. Confirm the diagnosis without guessing: `ls -l /etc/aliases /etc/aliases.db` shows the `.db` older than the source, and `postmap -q root hash:/etc/aliases` returns the *stale* value. Fix: `sudo newaliases`. (Postfix's `local` agent also caches alias map handles, so on a busy host `postfix reload` after the rebuild removes any doubt.)

**A7.2** — The `.forward` file's own permissions are fine, but `/home/alice` is mode `0777` — **world-writable**. Any user on the system could replace or rewrite the `.forward` inside it, so the MTA treats the whole path as untrusted and refuses to honour the file, logging `warning: not owner or unsafe permissions on /home/alice/.forward` (or `unsafe directory`) and delivering locally instead. **The check covers the directory chain, not just the file.** Fix: `chmod 755 /home/alice`. Real-world cause: an application installer or a careless `chmod -R 777` on a home directory.

**A7.3** — The `!` suffix means the message is **on hold**. Held messages are excluded from queue runs by definition, so `postqueue -f` — which only retries *deferred* mail — cannot touch it. Someone ran `postsuper -h` (or a `header_checks`/`smtpd` policy action returned `HOLD`) and never released it; the four-day-old arrival time is consistent with that. Fix: inspect it first with `postcat -q D1E2F3A4B5` to see whether it should still go out, then either `sudo postsuper -H D1E2F3A4B5` to release it into the deferred queue, or `sudo postsuper -d D1E2F3A4B5` to discard it. Then find *why* it was held — check `header_checks`/`body_checks` for a `HOLD` action, or you will be back tomorrow.

**A7.4** — PHP's `mail()` executes the program named by the `sendmail_path` ini setting, which defaults to `/usr/sbin/sendmail -t -i`. That path does not exist, so the exec fails inside PHP; the message never reaches the MTA, which is precisely why the **mail log is silent** — an empty mail log with a complaining application is the signature of a *submission* failure, not a delivery failure. The Exim installation is incomplete or the compatibility symlink was removed. Fix: install the compatibility package (`exim4-daemon-light` provides `/usr/sbin/sendmail`; on Debian confirm with `dpkg -S /usr/sbin/sendmail`), or restore the symlink to `/usr/sbin/exim4`. Verify independently of PHP: `printf 'To: root\nSubject: t\n\nx\n' | /usr/sbin/sendmail -t` and check the log. Check PHP's error log too — the exec failure is usually recorded there.

**A7.5** — The two competing risks are **losing the notifications** and **amplifying the failure**. If you shorten the retry window or delete the queue, six hours of cron and monitoring output — potentially including the alert explaining the original outage — is destroyed. If you leave 900 messages retrying, each queue run consumes DNS lookups, connection slots and `active`-queue capacity, and when the MX returns, 900 messages arrive at once and may trip the receiver's rate limits or a spam filter, delaying the very alerts you need. Additionally, if any of them eventually expire, the bounces are generated **back into the local queue** and can double the problem.

First knob: **`postsuper -h` the affected recipient's messages** to take them out of the retry rotation without deleting anything (`mailq | grep -B1 oncall@corp.example` to identify them, or `postsuper -h ALL deferred` if the queue is homogeneous), then release them in controlled batches once the MX is confirmed healthy. That stops the amplification, preserves every message, and is fully reversible — the three properties you want under time pressure. Do **not** start by raising `maximal_queue_lifetime` or by deleting the queue.

The durable fix is structural and belongs in the post-incident review: make root's alias dual-delivery — `root: \root, oncall@corp.example` — so a local copy always survives regardless of any network condition (see A3.6), and route paging through a channel that does not depend on the mail path being healthy.

</details>

---

## Official Sources

- LPI, *Exam 102-500 Objectives* (LPIC-1 v5.0), topic 108.3 — <https://www.lpi.org/our-certifications/exam-102-objectives/>
- LPI, *Exam 101-500 Objectives* (LPIC-1 v5.0) — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Postfix, *Postfix Basic Configuration Readme* — <https://www.postfix.org/BASIC_CONFIGURATION_README.html>
- Postfix, *`aliases(5)` manual page* — <https://www.postfix.org/aliases.5.html>
- Postfix, *`local(8)` delivery agent manual page* (`.forward` handling and permission rules) — <https://www.postfix.org/local.8.html>
- Postfix, *`postsuper(1)`* and *`postqueue(1)`* manual pages — <https://www.postfix.org/postsuper.1.html> · <https://www.postfix.org/postqueue.1.html>
- Postfix, *Queue Scheduler* — <https://www.postfix.org/QSHAPE_README.html>
- Postfix, *Architecture Overview* — <https://www.postfix.org/OVERVIEW.html>
- Exim, *The Exim Specification, chapter 5: The Exim command line* — <https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_exim_command_line.html>
- Sendmail Consortium, *Sendmail Operations Guide* — <https://www.sendmail.org/>
- qmail, *`dot-qmail(5)` manual page* — <https://cr.yp.to/qmail/man/dot-qmail.5.html>
- IETF, *RFC 5321 — Simple Mail Transfer Protocol* — <https://www.rfc-editor.org/rfc/rfc5321>
- IETF, *RFC 3463 — Enhanced Mail System Status Codes* — <https://www.rfc-editor.org/rfc/rfc3463>