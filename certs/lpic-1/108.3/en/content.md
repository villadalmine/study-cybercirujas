# 108.3 — Mail Transfer Agent (MTA) Basics

**LPIC-1, Exam 102-500 (version 5.0)**
Objective coverage: create e-mail aliases · configure e-mail forwarding · knowledge of commonly available MTA programs (postfix, sendmail, qmail, exim) — *no configuration required by the exam, but required by production*.
Key files and utilities: `~/.forward`, sendmail emulation layer commands, `newaliases`, `mail`, `mailq`, `postfix`, `sendmail`, `exim`, `qmail`.

---

## 1. Motivation: the architectural problem behind a "boring" objective

### 1.1 Why every Linux box still ships a mail path

E-mail is the oldest still-running store-and-forward bus in UNIX, and a large amount of infrastructure signalling still rides on it, whether or not anyone reads a mailbox:

| Producer | Delivery mechanism | What breaks silently if the local mail path is dead |
|---|---|---|
| `cron`/`anacron` | writes job stdout/stderr to `sendmail -t` when `MAILTO` is set | Failing nightly jobs produce **no** signal at all — cron logs the run, not the output |
| `systemd` `OnFailure=` + `systemd-cron` / custom units | pipes journal excerpt into `sendmail` | Unit failures never leave the node |
| `smartd`, `mdadm --monitor`, `zed` (ZFS Event Daemon) | `/usr/sbin/sendmail -i -t` | Disk pre-failure and array degradation go unreported |
| `logwatch`, `rkhunter`, `aide`, `unattended-upgrades` | local sendmail | Compliance/integrity reports vanish |
| `sudo` `mail_badpass`, PAM, `libpam-abl` | local sendmail | Security events lost |
| Application code (`mail()`, `msmtp`, `sendmail` shim) | local sendmail | Password resets, invoices, alerts lost |
| Alertmanager, Zabbix, Nagios | SMTP over TCP to a relay | Paging fails at exactly the moment the platform is degraded |

The failure mode is the dangerous part: **the absence of mail is indistinguishable from the absence of problems.** A node whose MTA has been dead for six months looks identical, from the operator's chair, to a node that has had no failures for six months. This is why `mailq` returning a non-empty queue is a first-class SRE signal and why "is the alias database newer than `/etc/aliases`?" belongs in your node-level monitoring, not in a runbook nobody reads.

### 1.2 The five-role model — know which role you are debugging

RFC 5598 (*Internet Mail Architecture*) splits what users call "e-mail" into distinct agents. Nearly every production mail incident is a misattribution of a fault to the wrong role.

```
  ┌─────────┐   submission    ┌─────────┐   relay (SMTP/25)   ┌─────────┐
  │   MUA   │ ──────────────► │   MSA   │ ──────────────────► │   MTA   │
  │ mail(1) │  SMTP/587,465   │ smtpd   │   MX lookup, TLS    │  remote │
  │ mutt    │  or sendmail(1) │         │                     │         │
  └─────────┘   local pipe    └─────────┘                     └────┬────┘
                                                                   │ final delivery
                                                                   ▼
                                                             ┌─────────┐
                                                             │   MDA   │  local(8), procmail,
                                                             │         │  maildrop, dovecot-lda
                                                             └────┬────┘
                                                                  │ writes mbox / Maildir
                                                                  ▼
   ┌─────────┐    IMAP/143,993     ┌─────────┐            /var/mail/sre
   │   MUA   │ ◄────────────────── │   MRA   │ ◄───────────  ~/Maildir/
   │         │    POP3/110,995     │ dovecot │
   └─────────┘                     └─────────┘
```

| Role | Full name | Typical implementation | Ports | LPIC-1 108.3 scope |
|---|---|---|---|---|
| MUA | Mail User Agent | `mail`/`mailx`/`s-nail`, `mutt`, Thunderbird | — | yes (`mail`) |
| MSA | Mail Submission Agent | `postfix` `submission` service | 587 (STARTTLS), 465 (implicit TLS) | peripheral |
| MTA | Mail Transfer Agent | postfix, sendmail, exim, qmail | 25 | **yes** |
| MDA | Mail Delivery Agent | `local(8)`, `procmail`, `maildrop`, `dovecot-lda` | — | **yes** (aliases/`.forward` are MDA-time) |
| MRA | Mail Retrieval Agent | dovecot, courier | 110/143/993/995 | no (that is 108.3's sibling territory) |

**The single most useful fact in this objective:** aliases and `~/.forward` are evaluated by the **MDA at final-delivery time**, not by the MTA at relay time. An alias on host A has no effect whatsoever on mail that host A merely relays. That one sentence explains most "my alias doesn't work" tickets.

### 1.3 Egress-25 and why the local MTA is a *buffer*, not a mail server

Modern constraints make the naive design — "each app opens an SMTP connection to the internet" — unworkable:

* AWS EC2, GCP, Azure, Hetzner and most hosters block or throttle outbound TCP/25 by default.
* Deliverability requires SPF, DKIM and DMARC alignment, which requires a *small, stable* set of source IPs with correct PTR records. Fifty pods with fifty ephemeral egress IPs cannot be authorised.
* SMTP is a *retrying* protocol. An application that does `connect()` + `send()` synchronously has no retry semantics, no queue, and blocks a request thread for the TCP timeout (typically 130 s with default `tcp_syn_retries=6`).

The classic answer is the **null client / satellite** pattern: a local MTA on every host that accepts mail only from `127.0.0.1`, does no local delivery, does no DNS MX resolution, and forwards everything to a smarthost. It exists to give you a *durable, retrying, on-disk queue* one syscall away from the application.

| Design | Queue durability | Retry logic | Blast radius of relay outage | Deliverability surface | Operational cost |
|---|---|---|---|---|---|
| App → internet MX directly | none | in app code (usually absent) | app-wide | every app IP must be in SPF | low config, high risk |
| App → central relay directly (no local MTA) | none | in app code | app blocks/errors during relay outage | 1 IP set | low |
| **Null-client MTA per host → relay** | **on disk, per host** | **MTA-native, exponential backoff** | **none — mail queues locally** | 1 IP set | medium (an MTA per host) |
| Sidecar MTA per pod | on disk *if* volume is persistent | MTA-native | none | 1 IP set | high (N containers, N queues to observe) |
| DaemonSet MTA per node + `hostPort` | on disk (node PVC/hostPath) | MTA-native | none | 1 IP set | medium |
| Central relay cluster only, apps use HTTP API (SES/SendGrid) | provider-side | provider-side | app-visible | provider-managed | lowest, but not SMTP and not LPIC-1 |

The null-client MTA is the design LPIC-1 is implicitly teaching. Everything in this objective — the sendmail shim, aliases, `.forward`, `mailq` — is the interface to that buffer.

---

## 2. The MTA landscape

### 2.1 Comparative table

| | **Postfix** | **sendmail** | **Exim** | **qmail** |
|---|---|---|---|---|
| Original author | Wietse Venema (IBM, 1998, as "VMailer"/"IBM Secure Mailer") | Eric Allman (1981, from `delivermail`, 4.1cBSD) | Philip Hazel (University of Cambridge, 1995) | D. J. Bernstein (1996) |
| Current upstream | postfix.org | proofpoint/sendmail.org | exim.org | public domain since Nov 2007; `netqmail` patchset |
| Licence | IBM Public License 1.0 / Eclipse Public License 2.0 | Sendmail License (OSI-ish, BSD-derived) | GPLv2 | Public domain |
| Process model | **Multi-process, one job per program**, supervised by `master(8)`; most components `chroot`ed and unprivileged | Historically a single large `setuid root` binary; modern versions split into MSP/MTA | Single monolithic binary, forks per delivery, re-`exec`s itself | Multi-process, many tiny programs, privilege split across several UIDs |
| Privilege design | least privilege by construction; only `master`, `pickup`→`postdrop` boundary and `local(8)` touch root | large historical CVE surface (the reason Postfix and qmail exist) | runs as `exim` user, some root retained for delivery | least privilege, "no setuid root binary" claim (`qmail-queue` is setgid) |
| Configuration | `main.cf` + `master.cf`, flat `key = value`, queried with `postconf` | `sendmail.mc` (m4) → **generated** `sendmail.cf`; the raw `.cf` is famously unreadable | Single `exim.conf` with **ACL-driven** rule blocks; Debian splits it under `/etc/exim4/conf.d/` | Dozens of one-line files under `/var/qmail/control/` |
| Config validation | `postfix check`, `postconf -n` | `make -C /etc/mail` | `exim -bV` (parses config, reports errors) | none (files are trivially small) |
| Spool | `/var/spool/postfix/{maildrop,incoming,active,deferred,hold,corrupt}` | `/var/spool/mqueue` (`qf*` control, `df*` data) | `/var/spool/exim4/input` (`-H` header, `-D` data) | `/var/qmail/queue/{mess,todo,intd,info,local,remote,bounce}` |
| Default local mailbox | `mbox` `/var/mail/$USER` | `mbox` | `mbox` | **Maildir** (qmail invented it) |
| Per-user forwarding file | `~/.forward` (path from `forward_path`) | `~/.forward` | `~/.forward` (via `userforward` router) | **`~/.qmail`** — *not* `.forward` |
| Alias file | `/etc/aliases` + `alias_maps` | `/etc/aliases` + `/etc/mail/aliases` | `/etc/aliases` via `system_aliases` router | `/var/qmail/alias/.qmail-<name>` |
| Loop protection | `Delivered-To:` header + `hopcount_limit` (default 50) | hop count from `Received:` lines, `MaxHopCount` (25) | `Received:` count, `received_headers_max` (30) | `Delivered-To:` |
| Filtering language | external (`header_checks`, milter, `smtpd_*_restrictions`) | milter API (invented here), `access` map | **built-in Exim filter + ACLs** — most expressive of the four | external (`qmail-queue` wrappers) |
| Default MTA on | RHEL/CentOS/Rocky/Alma 8–9, Fedora, Ubuntu Server, SUSE | almost nowhere by default now; still shipped by RHEL as an alternative | **Debian** (`exim4-daemon-light`) | nowhere by default |
| Best fit | general purpose, high volume, relays, null clients | legacy estates, environments contractually bound to it | complex per-message policy in a single host | historical/ideological; unmaintained core |

### 2.2 What the process models actually mean when you are on call

**Postfix** — `ps` on a Postfix host is a map of the mail path, which makes it uniquely debuggable:

```
$ ps -eo user,pid,ppid,args --sort=ppid | grep -E 'postfix|master' | grep -v grep
root         918      1 /usr/libexec/postfix/master -w
postfix      921    918 pickup -l -t unix -u
postfix      922    918 qmgr -l -t unix -u
postfix     1740    918 tlsmgr -l -t unix -u
postfix     4412    918 smtp -t unix -u
postfix     4413    918 error -n error -t unix -u
```

Each of `pickup`, `cleanup`, `qmgr`, `smtp`, `smtpd`, `local`, `pipe`, `virtual`, `lmtp`, `bounce`, `trivial-rewrite` is a separate short-lived program with a separate log prefix. A log line `postfix/smtp[4412]:` tells you the fault is in outbound delivery; `postfix/local[2114]:` tells you it is in final delivery, i.e. aliases/`.forward` territory. **Read the program name in the log prefix before reading anything else.**

**sendmail** — the reason Postfix and qmail were written: a single `setuid root` binary parsing untrusted input. Modern sendmail splits the *Mail Submission Program* (`sendmail -Ac`, `submit.cf`, setgid `smmsp`) from the daemon, but the configuration is still generated:

```
$ ls -l /etc/mail/sendmail.mc /etc/mail/sendmail.cf
-rw-r--r--. 1 root root   6110 Aug 26 08:41 /etc/mail/sendmail.cf
-rw-r--r--. 1 root root   1962 Aug 26 08:40 /etc/mail/sendmail.mc
$ grep -c . /etc/mail/sendmail.cf
1783
```

You edit the 1962-byte `.mc`, then regenerate. **Never edit `sendmail.cf` by hand** — the next `make` overwrites it.

**Exim** — a single binary whose behaviour is a rule pipeline: `ACLs` (accept/reject at SMTP time) → `routers` (decide *where*) → `transports` (decide *how*). Aliases and `.forward` are implemented as *routers* (`system_aliases`, `userforward`), which is why `exim -bt` (address test) is such an effective diagnostic: it replays the router chain and prints the decision.

**qmail** — architecturally elegant, and the origin of Maildir and of `Delivered-To:`-based loop detection, but the core has not been maintained upstream since 1998; production use today means `netqmail` plus a patch stack. For the exam: *recognise it, know it uses `~/.qmail` and Maildir, know `qmail-qstat`/`qmail-qread`.*

### 2.3 The sendmail emulation layer — the actual interoperability contract

Thirty years of software calls `/usr/sbin/sendmail`. Every MTA therefore ships a binary at that path that speaks a subset of sendmail's CLI. **This is why `mailq` works identically on a Postfix box and an Exim box.**

| Flag | Meaning | Postfix | sendmail | Exim | Notes |
|---|---|---|---|---|---|
| `-t` | read recipients from `To:`/`Cc:`/`Bcc:` headers | ✔ | ✔ | ✔ | how cron/smartd/apps submit |
| `-f addr` | set the **envelope** sender (`MAIL FROM`) | ✔ | ✔ | ✔ | bounces go here, not to `From:` |
| `-F name` | set full name of sender | ✔ | ✔ | ✔ | |
| `-i` | do **not** treat a lone `.` as end-of-input | ✔ | ✔ | ✔ | always use with `-t` on generated bodies |
| `-bp` | print the mail queue | ✔ | ✔ | ✔ | `mailq` is a synonym |
| `-bi` | (re)build the alias database | ✔ | ✔ | ✔ | `newaliases` is a synonym |
| `-bs` | speak SMTP on stdin/stdout | ✔ | ✔ | ✔ | scriptable submission without a socket |
| `-bv` | verify/expand addresses, do not deliver | ✔ | ✔ | ✔ | *alias expansion test* |
| `-bd` | run as daemon | ✖ (use `postfix start`) | ✔ | ✔ | |
| `-bt` | interactive address-test mode | ✖ | ✔ | ✖ (`-bt` = address test in Exim too, different output) | |
| `-q[time]` | flush/run the queue | partial (`-q` only) | ✔ | ✔ | Postfix: prefer `postqueue -f` |
| `-v` | verbose | ✔ | ✔ | ✔ | |

Three universally-present symlinks form the contract: **`sendmail`, `mailq`, `newaliases`**.

### 2.4 Which MTA is actually installed? (do this first, every time)

**Red Hat family — the `alternatives` system, `mta` family:**

```
$ alternatives --display mta
mta - status is auto.
 link currently points to /usr/sbin/sendmail.postfix
/usr/sbin/sendmail.postfix - priority 30
 slave mta-mailq: /usr/bin/mailq.postfix
 slave mta-newaliases: /usr/bin/newaliases.postfix
 slave mta-rmail: /usr/bin/rmail.postfix
 slave mta-pam: /etc/pam.d/smtp.postfix
 slave mta-mailqman: /usr/share/man/man1/mailq.postfix.1.gz
 slave mta-newaliasesman: /usr/share/man/man1/newaliases.postfix.1.gz
 slave mta-sendmailman: /usr/share/man/man1/sendmail.postfix.1.gz
 slave mta-aliasesman: /usr/share/man/man5/aliases.postfix.5.gz
Current `best' version is /usr/sbin/sendmail.postfix.

$ ls -l /usr/sbin/sendmail /usr/bin/mailq /usr/bin/newaliases
lrwxrwxrwx. 1 root root 21 Aug 26 08:12 /usr/bin/mailq -> /etc/alternatives/mta-mailq
lrwxrwxrwx. 1 root root 26 Aug 26 08:12 /usr/bin/newaliases -> /etc/alternatives/mta-newaliases
lrwxrwxrwx. 1 root root 21 Aug 26 08:12 /usr/sbin/sendmail -> /etc/alternatives/mta

$ readlink -f /usr/sbin/sendmail
/usr/sbin/sendmail.postfix
```

Switching MTA on RHEL is therefore a two-step operation — the package and the alternatives link — and forgetting the second step is a classic post-migration outage:

```
$ sudo alternatives --set mta /usr/sbin/sendmail.sendmail
$ sudo systemctl disable --now postfix && sudo systemctl enable --now sendmail
```

**Debian family — no alternatives; the `mail-transport-agent` virtual package plus `Conflicts:`.** Exactly one MTA package may be installed, and it owns `/usr/sbin/sendmail` directly:

```
$ dpkg -S /usr/sbin/sendmail
exim4-daemon-light: /usr/sbin/sendmail

$ dpkg -l | awk '/mail-transport|postfix|exim4-daemon|nullmailer|msmtp-mta/ {print $2, $3}'
exim4-daemon-light 4.96-15+deb12u6

$ apt-cache showpkg mail-transport-agent | sed -n '/Reverse Provides/,+8p'
Reverse Provides:
postfix 3.7.11-0+deb12u2
exim4-daemon-light 4.96-15+deb12u6
exim4-daemon-heavy 4.96-15+deb12u6
nullmailer 1:2.2-3
msmtp-mta 1.8.23-1
ssmtp 2.64-11
```

Replacing Exim with Postfix on Debian is a single transaction, because the `Conflicts:` forces the swap:

```
$ sudo apt-get install -y postfix
The following packages will be REMOVED:
  exim4-config exim4-daemon-light
The following NEW packages will be installed:
  postfix ssl-cert
...
Postfix is now set up with a default configuration.
```

**MTA-agnostic identification, works everywhere** — the SMTP banner and the queue tool never lie:

```
$ /usr/sbin/sendmail -bv nonexistent-probe@localhost 2>&1 | head -1
sendmail: fatal: nonexistent-probe@localhost: Recipient address rejected: User unknown in local recipient table

$ ss -lntp 'sport = :25'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=918,fd=13))

$ printf 'QUIT\r\n' | nc -q1 127.0.0.1 25
220 edge-01.internal ESMTP Postfix
221 2.0.0 Bye
```

`master` in `ss` output ⇒ Postfix. `exim4` ⇒ Exim. `sendmail-mta: accepting connections` in the banner ⇒ sendmail. `qmail-smtpd` (usually under `tcpserver`/`supervise`) ⇒ qmail.

---

## 3. Aliases

### 3.1 `/etc/aliases` — syntax and the five right-hand-side types

The format is defined by `aliases(5)` and is identical across Postfix, sendmail and Exim:

```
name: value[, value ...]
```

* `name` is a **local part only** — no `@domain`. `/etc/aliases` is not a virtual-domain map; that is `virtual_alias_maps` (Postfix) / `virtusertable` (sendmail).
* Lookups are **case-insensitive** on the left-hand side.
* Continuation lines start with whitespace.
* `#` starts a comment; blank lines are ignored.
* Expansion is **recursive** — an alias may point at another alias.

The five legal right-hand-side forms:

| Form | Example | Delivered by | Notes |
|---|---|---|---|
| Local user | `oncall: sre` | MDA to that user's mailbox | the user's own `~/.forward` is then consulted |
| Remote address | `oncall: sre-team@example.net` | re-injected into the queue | crosses the network — SPF/DMARC implications, see §3.7 |
| List of both | `oncall: sre, sre-team@example.net` | fan-out | duplicates are suppressed per message |
| **File** | `logs: /var/mail/archive/logs` | appended (mbox format) | requires `allow_mail_to_files` |
| **Pipe to command** | `bugs: \|/usr/local/bin/file-ticket` | executed by `pipe(8)` | **remote-code-execution surface**, see §3.6 |
| `:include:` file | `sre-team: :include:/etc/mail/lists/sre-team` | reads recipients from a file at delivery time | edit without `newaliases` |
| Suppress further expansion | `sre: \sre, backup@example.net` | deliver locally to `sre` *without* re-running aliases/`.forward` | the loop breaker |

A production `/etc/aliases` for a fleet node:

```
# /etc/aliases — managed by Ansible, do not edit by hand.
# After any change: newaliases (or postalias /etc/aliases)
#
# RFC 2142 mandatory role accounts ------------------------------------------
postmaster:     root
mailer-daemon:  postmaster
abuse:          root
hostmaster:     root
webmaster:      root
security:       root

# System accounts — never leave these delivering into unread local mboxes ----
bin:            root
daemon:         root
adm:            root
lp:             root
sync:           root
shutdown:       root
halt:           root
mail:           root
operator:       root
games:          root
ftp:            root
nobody:         root
systemd-network: root
dbus:           root
sshd:           root
chrony:         root
postfix:        root
nginx:          root
prometheus:     root

# The single funnel: everything above ends here -----------------------------
# Fan out to a real, monitored destination AND keep a local copy for forensics
root:           sre-oncall, \root

# Team lists ----------------------------------------------------------------
sre-oncall:     :include:/etc/mail/lists/sre-oncall
platform:       :include:/etc/mail/lists/platform
owner-sre-oncall: sre-alias-owner@example.net

# Machine-consumed destinations ---------------------------------------------
cron-archive:   /var/log/mail-archive/cron.mbox
ticket:         |/usr/local/libexec/mail2ticket --queue=infra
```

```
$ cat /etc/mail/lists/sre-oncall
# One address per line; :include: is re-read at delivery time,
# so adding a person here needs NO newaliases run.
sre-team@example.net
pagerduty+infra@example.net
```

Note `root: sre-oncall, \root`. Without the `\root` term you lose the local copy; with a bare `root` term you create an infinite loop. The backslash means *deliver to this local user and stop expanding*.

### 3.2 The database: `newaliases` and friends

`/etc/aliases` is a **text source file**. The MDA never reads it at delivery time — it reads an indexed database built from it. Forgetting to rebuild is *the* number-one alias bug.

```
$ sudo tee -a /etc/aliases >/dev/null <<'EOF'
noc: sre-oncall
EOF

$ sudo newaliases
$ ls -l /etc/aliases /etc/aliases.db
-rw-r--r--. 1 root root  1487 Aug 26 11:02 /etc/aliases
-rw-r--r--. 1 root root 12288 Aug 26 11:02 /etc/aliases.db
```

`newaliases` is exactly `sendmail -bi`:

```
$ readlink -f "$(command -v newaliases)"
/usr/bin/newaliases.postfix
$ sudo /usr/sbin/sendmail -bi          # identical effect
```

Postfix's native tool, which lets you name the database type explicitly:

```
$ sudo postalias hash:/etc/aliases
$ postalias -q noc hash:/etc/aliases
sre-oncall
$ postalias -q nonexistent hash:/etc/aliases; echo "exit=$?"
exit=1
```

Database back-ends differ by distribution and matter when you copy a `.db` between hosts (**you cannot** — the format is architecture- and library-version-specific; always ship the text file and rebuild):

| Type | Command to build | Produces | Where it is the default |
|---|---|---|---|
| `hash` | `postalias hash:/etc/aliases` | `/etc/aliases.db` (Berkeley DB) | Debian/Ubuntu Postfix, sendmail |
| `lmdb` | `postalias lmdb:/etc/aliases` | `/etc/aliases.lmdb` | Fedora / RHEL 9 Postfix builds |
| `btree` | `postalias btree:/etc/aliases` | `/etc/aliases.db` | rare |
| `cdb` | `postalias cdb:/etc/aliases` | `/etc/aliases.cdb` | qmail-style, immutable-friendly |
| `texthash` | *(none — read at process start)* | nothing on disk | read-only containers |
| `dbm`/`sdbm` | `makemap dbm` | `/etc/aliases.pag`, `.dir` | legacy sendmail |

```
$ postconf -d default_database_type          # Fedora / RHEL 9
default_database_type = lmdb

$ postconf -d default_database_type          # Debian 12
default_database_type = hash
```

sendmail uses `makemap` for its other maps (`access`, `virtusertable`, `mailertable`) but `newaliases` for aliases:

```
$ sudo makemap hash /etc/mail/access < /etc/mail/access
$ sudo make -C /etc/mail
```

Exim does **not** require a database at all — the `system_aliases` router reads the plain text file. `newaliases` on Debian/Exim is therefore a near-no-op script that exists purely to satisfy the sendmail contract:

```
$ readlink -f "$(command -v newaliases)"
/usr/sbin/exim4
$ sudo newaliases           # succeeds silently; Exim reads /etc/aliases directly
```

### 3.3 `alias_maps` vs `alias_database` — the distinction that bites

Postfix splits one concept into two parameters, and mixing them up produces "the alias exists but is never used":

| Parameter | Consulted by | Meaning |
|---|---|---|
| `alias_maps` | `local(8)` **at delivery time** | which databases to *look up* |
| `alias_database` | `newaliases` / `sendmail -bi` | which databases to *rebuild* |

```
$ postconf alias_maps alias_database
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
```

If you add a second alias file, you must extend **both**:

```
$ sudo postconf -e 'alias_maps = hash:/etc/aliases, hash:/etc/postfix/aliases-team'
$ sudo postconf -e 'alias_database = hash:/etc/aliases, hash:/etc/postfix/aliases-team'
$ sudo newaliases
$ sudo postfix reload
```

Set `alias_maps` in `alias_database` only and you get a perfectly-built database nobody reads. Set it in `alias_maps` only and `newaliases` silently ignores your new file, so the database is missing at delivery and the mail defers with `alias database unavailable`.

### 3.4 Mailing lists, `:include:` and the `owner-` convention

`:include:` is a run-time indirection: the file is read on every delivery, so membership changes take effect immediately with no `newaliases`. This is the correct mechanism for lists managed by a config-management system or by a self-service tool.

The `owner-<listname>` convention rewrites the **envelope sender** of expanded messages so that bounces from list members go to the list owner instead of to the original poster:

```
sre-oncall:       :include:/etc/mail/lists/sre-oncall
owner-sre-oncall: sre-alias-owner@example.net
```

```
$ postconf owner_request_special expand_owner_alias
owner_request_special = yes
expand_owner_alias = no
```

Without `owner-`, a single dead address in a 200-person list bombards whoever sent the message with 200 bounces. This is not cosmetic: it is how alias fan-out gets an entire sending IP blocklisted.

### 3.5 Loop protection

Aliases are recursive, and recursion plus a network round trip is a mail loop that can saturate a relay in minutes.

| MTA | Mechanism | Tunable | Default |
|---|---|---|---|
| Postfix | inserts `Delivered-To:` on local delivery; refuses to redeliver to an address already present | `hopcount_limit` | 50 |
| Postfix | counts `Received:` headers | `hopcount_limit` | 50 |
| sendmail | counts `Received:` headers | `MaxHopCount` | 25 |
| Exim | counts `Received:` headers | `received_headers_max` | 30 |
| qmail | `Delivered-To:` | `-` | — |

What a loop looks like in the log — recognise this instantly:

```
Aug 26 11:14:07 edge-01 postfix/local[7714]: 8C2F41A0D91: to=<noc@edge-01.internal>,
  orig_to=<root@edge-01.internal>, relay=local, delay=0.04, delays=0.02/0/0/0.02,
  dsn=5.4.6, status=bounced (mail forwarding loop for noc@edge-01.internal)
```

and the *other* loop, the MX one, which is a configuration fault rather than an alias fault:

```
Aug 26 11:20:31 edge-01 postfix/smtp[7801]: 91AB41A0E02: to=<sre@example.net>,
  relay=none, delay=0.09, dsn=5.4.6, status=bounced
  (mail for example.net loops back to myself)
```

`loops back to myself` means the MX for a domain resolves to this host, but the host does not list that domain in `mydestination`/`virtual_alias_domains`/`relay_domains`. It is not an alias problem; do not go looking in `/etc/aliases`.

### 3.6 Security: `|command` aliases are an RCE primitive

An alias of the form `name: |/path/to/program` causes the MDA to execute a program with attacker-influenced stdin, triggered by an unauthenticated remote SMTP transaction. Historic incidents (`decode:` aliases, `|/bin/sh`) are the reason for the guard rails below.

**Postfix guard rails:**

```
$ postconf allow_mail_to_commands allow_mail_to_files default_privs \
           command_execution_directory command_time_limit
allow_mail_to_commands = alias,forward
allow_mail_to_files = alias,forward
default_privs = nobody
command_execution_directory =
command_time_limit = 1000s
```

* `allow_mail_to_commands` / `allow_mail_to_files` accept `alias`, `forward`, `include`. Removing `include` (the default) blocks the `:include:`-file-contains-a-pipe escalation, in which a user who can write an included file gains command execution.
* `default_privs = nobody` is the UID used when the pipe is reached via `/etc/aliases` (root-owned, so no natural UID). Pipes reached via a user's `~/.forward` run as **that user**.

**sendmail guard rail — `smrsh(8)`, the restricted shell:** sendmail runs pipe commands through `/usr/sbin/smrsh`, which only executes programs explicitly symlinked into its directory:

```
$ grep -n 'FEATURE(.smrsh' /etc/mail/sendmail.mc
14:FEATURE(`smrsh', `/usr/sbin/smrsh')dnl

$ ls -l /etc/smrsh/
total 0
lrwxrwxrwx. 1 root root 16 Aug 26 09:03 procmail -> /usr/bin/procmail
lrwxrwxrwx. 1 root root 39 Aug 26 09:03 mail2ticket -> /usr/local/libexec/mail2ticket
```

Anything not symlinked there is refused, so `bugs: |/bin/sh -c '...'` fails closed.

**Platform rule of thumb:** in an immutable/containerised estate, set `allow_mail_to_commands = ` (empty) and `allow_mail_to_files = ` (empty) on every host that is a pure relay. A null client has no legitimate reason to execute anything, and the check costs nothing:

```
$ sudo postconf -e 'allow_mail_to_commands =' -e 'allow_mail_to_files ='
$ sudo postfix reload
```

### 3.7 The deliverability trap in alias forwarding

An alias that forwards `alerts@example.net` → `person@gmail.com` **re-sends** the message from *your* IP while preserving the original `From:` header. The receiving side evaluates SPF against your IP and the original sender's domain, and it fails. DKIM survives only if you changed nothing — and alias forwarding through most MTAs adds headers, so it often does not.

| Symptom at destination | Cause | Mitigation |
|---|---|---|
| `550 5.7.23 SPF validation failed` | forwarded, `MAIL FROM` still the original domain | **SRS** (Sender Rewriting Scheme) — rewrite envelope sender to your domain |
| `550 5.7.26 DMARC policy` | SPF fails and DKIM broken by header rewriting | SRS + do not modify headers/body |
| Bounces to the *original sender*, not you | no `owner-` alias | add `owner-<list>` |

```
$ sudo postconf -e 'sender_canonical_maps = tcp:127.0.0.1:10001' \
                -e 'sender_canonical_classes = envelope_sender' \
                -e 'recipient_canonical_maps = tcp:127.0.0.1:10002' \
                -e 'recipient_canonical_classes = envelope_recipient,header_recipient'
$ sudo systemctl enable --now postsrsd
$ sudo postfix reload
```

This is beyond LPIC-1, but it is the difference between an alias that "works" in a lab and one that works in production.

---

## 4. `~/.forward` — user-controlled forwarding

### 4.1 Syntax

`~/.forward` is the *right-hand side of an alias entry, without the `name:` part*, held in the recipient's home directory. It requires no root privilege and no database rebuild — it is read as plain text at delivery time. Every RHS form from §3.1 is legal.

```
$ cat ~/.forward
sre-team@example.net
```

```
$ cat ~/.forward          # fan-out plus a local copy — note the backslash
\sre, sre-team@example.net
```

```
$ cat ~/.forward          # deliver through procmail (classic)
"|IFS=' ' && exec /usr/bin/procmail -f- || exit 75 #sre"
```

That baroque one-liner is the canonical sendmail-safe procmail recipe: it resets `IFS` against environment attacks, exits `75` (`EX_TEMPFAIL`) so mail is retried rather than bounced if procmail is missing, and appends `#sre` because sendmail keys its duplicate-suppression on the literal string — two users with byte-identical `.forward` pipes would otherwise collide.

```
$ cat ~/.forward          # append to a file, no forwarding
/home/sre/mail/archive
```

### 4.2 The permission rules — where 90 % of `.forward` tickets die

Because `.forward` grants a user the ability to make the MDA execute code, the MDA refuses to honour a file that anyone else could have written. **The checks include the home directory itself.**

| Requirement | Enforced by |
|---|---|
| `~/.forward` owned by the recipient (or root) | postfix `local(8)`, sendmail, exim |
| `~/.forward` **not** group-writable, **not** world-writable | all |
| `$HOME` **not** group-writable, **not** world-writable | sendmail (strictest), exim |
| `$HOME` and `.forward` on a non-`nosuid`, non-`nodev` path, readable by the MDA | all |
| Home directory reachable (no root-squashed NFS, no SELinux denial) | all |

The correct state:

```
$ ls -ld ~ ~/.forward
drwx------. 14 sre sre 4096 Aug 26 11:31 /home/sre
-rw-r--r--.  1 sre sre   22 Aug 26 11:31 /home/sre/.forward
```

The broken state and its log signature:

```
$ chmod 775 ~ ; ls -ld ~
drwxrwxr-x. 14 sre sre 4096 Aug 26 11:33 /home/sre
```

sendmail:

```
Aug 26 11:34:02 edge-01 sendmail[8812]: 27QEY2sd008812: SYSERR(root):
  forward /home/sre/.forward: Group writable directory
```

Postfix (less chatty; it simply skips the file and delivers to the mailbox — **the mail is not lost, it is merely not forwarded**, which is worse for diagnosis):

```
Aug 26 11:34:02 edge-01 postfix/local[8814]: warning: not owner or unsafe permissions
  on /home/sre/.forward
Aug 26 11:34:02 edge-01 postfix/local[8814]: A17441A0F03: to=<sre@edge-01.internal>,
  relay=local, delay=0.03, dsn=2.0.0, status=sent (delivered to mailbox)
```

Fix:

```
$ chmod 700 ~ && chmod 600 ~/.forward
$ ls -ld ~ ~/.forward
drwx------. 14 sre sre 4096 Aug 26 11:35 /home/sre
-rw-------.  1 sre sre   22 Aug 26 11:31 /home/sre/.forward
```

sendmail's escape hatch is the `DontBlameSendmail` option (`ForwardFileInUnsafeDirPath`, `GroupWritableForwardFile`, …). Its name is deliberate and its use is a finding in any security review. Fix the permissions instead.

Under SELinux, the MDA needs the right label on the file; a correct-looking `.forward` that is still ignored is often an AVC:

```
$ ls -Z ~/.forward
unconfined_u:object_r:mail_home_t:s0 /home/sre/.forward
$ sudo ausearch -m AVC -ts recent | grep -i forward
$ restorecon -Rv ~/.forward
```

### 4.3 `forward_path` and address extensions

Postfix does not hard-code `~/.forward`; it evaluates `forward_path`, which supports per-extension files:

```
$ postconf forward_path recipient_delimiter
forward_path = $home/.forward${recipient_delimiter}${extension}, $home/.forward
recipient_delimiter =
```

Enable the delimiter and you get sub-addressing with independent forwarding rules per tag:

```
$ sudo postconf -e 'recipient_delimiter = +'
$ sudo postfix reload
$ printf 'pagerduty+infra@example.net\n' > ~/.forward+alerts
$ chmod 600 ~/.forward+alerts
```

Now `sre+alerts@edge-01.internal` is routed by `~/.forward+alerts`, while everything else uses `~/.forward`. If neither exists, the delimiter is stripped and delivery falls back to the base mailbox — so `+tag` addresses never bounce. Exim's equivalent is the `local_part_suffix` router option; sendmail's is `FEATURE(subplus)` / `plussed_user`.

### 4.4 `.forward` vs `/etc/aliases` — choosing correctly

| | `/etc/aliases` | `~/.forward` |
|---|---|---|
| Who may edit | root only | the user |
| Applies to | any local part, including non-users (`postmaster`, `ticket`) | only that user's own address |
| Requires DB rebuild | **yes** (`newaliases`) — except Exim | no |
| Requires MTA reload | no (DB is re-read) | no |
| Evaluated | before `.forward` | after alias expansion resolves to a local user |
| Survives user deletion | yes (it's a file in `/etc`) | no (home dir goes with the user) |
| Config-management friendly | yes | awkward (lives in `$HOME`, often on NFS) |
| Audit trail | in Git with the rest of `/etc` | invisible to the platform team |
| Right tool for | role accounts, system mail funnelling, lists | one person redirecting their own mail temporarily |

**Order of evaluation** — memorise this chain, it is examinable and it is the debugging order:

```
envelope recipient  →  virtual_alias_maps        (Postfix: address@domain rewriting)
                    →  canonical_maps            (rewriting)
                    →  /etc/aliases (alias_maps)  ← recursive, root-controlled
                    →  local user resolved
                    →  ~/.forward                 ← user-controlled
                    →  mailbox_command / mailbox / home_mailbox
                    →  /var/mail/$USER  or  ~/Maildir/
```

An alias pointing at a user whose `.forward` points back at the alias is a loop; the `\user` form on either side breaks it.

### 4.5 qmail is the exception

qmail ignores `~/.forward` entirely. Its per-user control file is `~/.qmail`, with extension files `~/.qmail-alerts` for `user-alerts@host`:

```
$ cat ~/.qmail
&sre-team@example.net
./Maildir/
```

`&address` forwards, `./Maildir/` delivers to a Maildir, `|command` pipes, a bare path appends to an mbox. System-wide aliases live as `/var/qmail/alias/.qmail-<name>`:

```
$ ls -l /var/qmail/alias/
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-postmaster
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-root
-rw-r--r-- 1 alias qmail 22 Aug 26 09:11 .qmail-mailer-daemon
$ cat /var/qmail/alias/.qmail-root
&sre-team@example.net
```

---

## 5. The queue: `mailq` and its per-MTA reality

### 5.1 Postfix queue anatomy

```
$ sudo ls -1 /var/spool/postfix/
active
bounce
corrupt
defer
deferred
flush
hold
incoming
maildrop
pid
private
public
saved
trace
```

| Directory | Contents | Who writes | SRE meaning |
|---|---|---|---|
| `maildrop` | locally submitted mail from `sendmail(1)`/`postdrop` | setgid `postdrop` | growth ⇒ `pickup(8)` is not running |
| `incoming` | messages accepted, awaiting `qmgr` | `cleanup(8)` | transient |
| `active` | messages `qmgr` is delivering **now** | `qmgr(8)` | bounded by `qmgr_message_active_limit` (20000) |
| `deferred` | temporary failure, will be retried | `qmgr(8)` | **the number you alert on** |
| `hold` | manually or policy-frozen; never retried | `postsuper -h` | quarantine |
| `corrupt` | unreadable queue files | any | never empty on a healthy host |
| `defer`, `bounce`, `trace` | per-message logs of *why* | `bounce(8)` | source of DSN text |

### 5.2 Reading the queue

```
$ mailq
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
3F2A41A0C4B     1274 Wed Aug 26 09:14:02  alerts@edge-01.internal
(connect to mx1.example.net[203.0.113.25]:25: Connection timed out)
                                         oncall@example.net

8C2F41A0D91*    2148 Wed Aug 26 11:02:44  root@edge-01.internal
                                         sre-team@example.net

91AB41A0E02!    1902 Wed Aug 26 11:20:31  cron@edge-01.internal
(host mx1.example.net[203.0.113.25] refused to talk to me:
 554 5.7.1 Service unavailable; Client host [198.51.100.7] blocked)
                                         sre-team@example.net

-- 5 Kbytes in 3 Requests.
```

The suffix on the queue ID is the state, and it is the first thing to read:

| Suffix | State |
|---|---|
| *(none)* | deferred — will be retried |
| `*` | **active** — being delivered right now |
| `!` | **on hold** — will *never* be retried until released |

Machine-readable output (Postfix ≥ 3.1) — this is what you scrape for metrics:

```
$ postqueue -j | jq -c '{id: .queue_id, q: .queue_name, r: .recipients[0].address, why: .recipients[0].delay_reason}'
{"id":"3F2A41A0C4B","q":"deferred","r":"oncall@example.net","why":"connect to mx1.example.net[203.0.113.25]:25: Connection timed out"}
{"id":"8C2F41A0D91","q":"active","r":"sre-team@example.net","why":null}
{"id":"91AB41A0E02","q":"hold","r":"sre-team@example.net","why":"host mx1.example.net[203.0.113.25] refused to talk to me: 554 5.7.1 Service unavailable"}
```

Queue-age distribution — `qshape` is the single best triage tool Postfix ships (package `postfix-perl-scripts`):

```
$ sudo qshape deferred
                        T  5 10 20 40 80 160 320 640 1280 1280+
                 TOTAL 47  0  0  2  6 11  14   9   5    0     0
       example.net     41  0  0  1  5 10  13   7   5    0     0
     partner.example    6  0  0  1  1  1   1   2   0    0     0

$ sudo qshape -s deferred          # by sender instead of recipient domain
                        T  5 10 20 40 80 160 320 640 1280 1280+
                 TOTAL 47  0  0  2  6 11  14   9   5    0     0
   edge-01.internal    47  0  0  2  6 11  14   9   5    0     0
```

Columns are age buckets in minutes. **One domain dominating** ⇒ that domain's MX is down or is rejecting you. **All domains rising uniformly** ⇒ your own egress is broken (blocked port 25, dead default route, DNS failure).

Inspect a single message, envelope and headers included:

```
$ sudo postcat -vq 3F2A41A0C4B | head -30
postcat: name_mask: all
*** ENVELOPE RECORDS deferred/3/3F2A41A0C4B ***
message_size:            1274             274               1               0            1274               0
message_arrival_time: Wed Aug 26 09:14:02 2026
create_time: Wed Aug 26 09:14:02 2026
named_attribute: rewrite_context=local
sender_fullname: Alerting
sender: alerts@edge-01.internal
*** MESSAGE CONTENTS deferred/3/3F2A41A0C4B ***
Received: by edge-01.internal (Postfix, from userid 0)
	id 3F2A41A0C4B; Wed, 26 Aug 2026 09:14:02 +0000 (UTC)
Subject: [FIRING:2] NodeFilesystemAlmostOutOfSpace
To: oncall@example.net
Date: Wed, 26 Aug 2026 09:14:02 +0000
From: Alerting <alerts@edge-01.internal>
Message-Id: <20260826091402.3F2A41A0C4B@edge-01.internal>
...
*** HEADER EXTRACTED deferred/3/3F2A41A0C4B ***
*** MESSAGE FILE END deferred/3/3F2A41A0C4B ***
```

Queue surgery — `postsuper` is the only safe way to touch the spool. **Never `rm` a queue file**; the queue manager caches state and you will corrupt it.

```
$ sudo postqueue -f                            # flush the whole deferred queue now
$ sudo postqueue -i 3F2A41A0C4B                # flush one message
$ sudo postqueue -s example.net                # flush one destination

$ sudo postsuper -h 91AB41A0E02                # put on hold (stop retrying)
$ sudo postsuper -H 91AB41A0E02                # release from hold
$ sudo postsuper -r 8C2F41A0D91                # requeue: re-run cleanup, re-apply aliases
$ sudo postsuper -d 3F2A41A0C4B                # delete one
$ sudo postsuper -d ALL deferred               # delete every deferred message
postsuper: Deleted: 41 messages
$ sudo postsuper -r ALL                        # requeue everything (after fixing aliases!)
postsuper: Requeued: 47 messages
```

`postsuper -r ALL` is the correct action after fixing `/etc/aliases`: requeueing re-runs `cleanup(8)`, which re-applies address rewriting and alias expansion. `postqueue -f` merely retries delivery with the *old* expansion and will fail again.

### 5.3 Queue lifetime — how long before mail is given up on

```
$ postconf maximal_queue_lifetime bounce_queue_lifetime queue_run_delay \
           minimal_backoff_time maximal_backoff_time delay_warning_time
maximal_queue_lifetime = 5d
bounce_queue_lifetime = 5d
queue_run_delay = 300s
minimal_backoff_time = 300s
maximal_backoff_time = 4000s
delay_warning_time = 0h
```

For alerting mail, five days of retries is wrong — a page that arrives four days late is noise. Production values for a null client carrying alerts:

```
$ sudo postconf -e 'maximal_queue_lifetime = 4h' \
                -e 'bounce_queue_lifetime = 1h' \
                -e 'delay_warning_time = 15m' \
                -e 'minimal_backoff_time = 60s' \
                -e 'maximal_backoff_time = 900s'
$ sudo postfix reload
postfix/postfix-script: refreshing the Postfix mail system
```

`delay_warning_time = 15m` makes the MTA itself tell you it is stuck, 15 minutes in, rather than 4 hours later when the message is discarded.

### 5.4 Queue commands across the four MTAs

| Task | Postfix | sendmail | Exim | qmail |
|---|---|---|---|---|
| List queue | `mailq` / `postqueue -p` | `mailq` / `sendmail -bp` | `exim -bp` / `mailq` | `qmail-qread` |
| Queue summary | `qshape` | `mailq \| tail -1` | `exim -bp \| exiqsumm` | `qmail-qstat` |
| Count messages | `postqueue -p \| tail -1` | `mailq \| tail -1` | `exim -bpc` | `qmail-qstat` |
| Flush queue | `postqueue -f` | `sendmail -q -v` | `exim -qff` | `svc -a /service/qmail-send` |
| Deliver one msg | `postqueue -i ID` | `sendmail -qI<ID>` | `exim -M ID` | — |
| Delete one msg | `postsuper -d ID` | `rm /var/spool/mqueue/{q,d}f<ID>` | `exim -Mrm ID` | `rm`, then `qmail-send` restart |
| Delete all | `postsuper -d ALL` | `rm -f /var/spool/mqueue/*` | `exim -bp \| exiqgrep -i \| xargs exim -Mrm` | — |
| Freeze / thaw | `postsuper -h` / `-H` | — | `exim -Mf` / `-Mt` | — |
| Show one message | `postcat -q ID` | `cat /var/spool/mqueue/df<ID>` | `exim -Mvb ID` / `-Mvh ID` | `cat /var/qmail/queue/mess/...` |
| Filter queue | `postqueue -j \| jq` | — | `exiqgrep -f '@old\.example$' -i` | — |

```
$ exim -bp
26h  2.4K 1rTqLm-000ABc-1H <alerts@edge-01.internal>
          oncall@example.net

 3h  1.9K 1rTuZp-000C1d-9K <root@edge-01.internal>
          *** frozen ***
          sre-team@example.net

$ exim -bpc
2
$ exiqgrep -f '^root@' -i
1rTuZp-000C1d-9K
$ exiqgrep -z -i | xargs -r exim -Mrm      # remove all frozen messages
Message 1rTuZp-000C1d-9K has been removed
```

```
$ qmail-qstat
messages in queue: 3
messages in queue but not yet preprocessed: 0
$ qmail-qread
26 Aug 2026 09:14:02 GMT  #2318921  1274  <alerts@edge-01.internal>
 remote  oncall@example.net
```

---

## 6. Production build-out — complete, unabridged configurations

### 6.1 Bare-metal / VM null client (Postfix satellite)

`/etc/postfix/main.cf` — a complete null-client configuration. Every non-default parameter is present and commented; nothing is elided.

```ini
# =============================================================================
# /etc/postfix/main.cf — NULL CLIENT (satellite) profile
# Role: accept mail from this host only, deliver nothing locally,
#       forward everything to the smarthost, queue durably on failure.
# Managed by Ansible: roles/mta/templates/main.cf.j2 — do not edit in place.
# =============================================================================

# --- Paths (distribution defaults; keep explicit for reproducibility) --------
queue_directory        = /var/spool/postfix
command_directory      = /usr/sbin
daemon_directory       = /usr/libexec/postfix
data_directory         = /var/lib/postfix
mail_owner             = postfix
setgid_group           = postdrop

# --- Identity ----------------------------------------------------------------
# myhostname MUST be a FQDN with a matching PTR record on the egress IP,
# otherwise many receivers reject with 450 4.7.1 / 550 5.7.1.
myhostname             = edge-01.internal.example.net
mydomain               = example.net
# Rewrite bare local addresses (root, cron) to @example.net so replies work.
myorigin               = $mydomain
append_dot_mydomain    = no
append_at_myorigin     = yes

# --- Listening ---------------------------------------------------------------
# A null client accepts submissions from loopback ONLY. Nothing on the wire.
inet_interfaces        = loopback-only
inet_protocols         = ipv4
mynetworks             = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mynetworks_style       = host

# --- No local delivery -------------------------------------------------------
# Empty mydestination + error transport = this host is not a mail destination.
# Any attempt to deliver locally fails loudly rather than filling /var/mail.
mydestination          =
local_transport        = error:5.1.1 Mailbox unavailable — this host is a null client
local_recipient_maps   =
alias_maps             = hash:/etc/aliases
alias_database         = hash:/etc/aliases
# Hard-disable the code-execution surface: a relay never pipes to a program.
allow_mail_to_commands =
allow_mail_to_files    =
default_privs          = nobody

# --- Relay -------------------------------------------------------------------
# Square brackets suppress the MX lookup: connect to this A/AAAA record directly.
relayhost              = [mail-relay.observability.svc.cluster.local]:587
# Never accept relaying from anyone: this host originates, it does not forward.
smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination, reject

# --- Outbound authentication -------------------------------------------------
smtp_sasl_auth_enable         = yes
smtp_sasl_password_maps       = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options    = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_sender_dependent_authentication = no

# --- Outbound TLS: mandatory, verified. `may` is silent-downgrade bait. -------
smtp_tls_security_level       = verify
smtp_tls_mandatory_protocols  = >=TLSv1.2
smtp_tls_protocols            = >=TLSv1.2
smtp_tls_mandatory_ciphers    = high
smtp_tls_CAfile               = /etc/pki/tls/certs/ca-bundle.crt
smtp_tls_loglevel             = 1
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

# --- Queue behaviour: alert mail must fail fast, not linger for days ----------
maximal_queue_lifetime = 4h
bounce_queue_lifetime  = 1h
delay_warning_time     = 15m
minimal_backoff_time   = 60s
maximal_backoff_time   = 900s
queue_run_delay        = 60s
# One concurrent connection to the relay is plenty for a single node and
# avoids tripping the relay's per-client concurrency limits.
default_destination_concurrency_limit = 2
smtp_connect_timeout   = 10s
smtp_helo_timeout      = 10s
smtp_data_done_timeout = 120s

# --- Size and hygiene --------------------------------------------------------
message_size_limit     = 20480000
mailbox_size_limit     = 0
biff                   = no
readme_directory       = no
html_directory         = no
compatibility_level    = 3.6
# Strip the internal hostname and local usernames from outbound headers.
smtp_header_checks     = regexp:/etc/postfix/header_checks_out
masquerade_domains     = $mydomain
masquerade_classes     = envelope_sender, header_sender
```

```
$ sudo cat /etc/postfix/header_checks_out
# Remove headers that leak internal topology to external recipients.
/^Received:.*edge-[0-9]+\.internal/    IGNORE
/^X-Originating-IP:/                   IGNORE
/^User-Agent:/                         IGNORE
```

```
$ sudo install -m 0600 /dev/stdin /etc/postfix/sasl_passwd <<'EOF'
[mail-relay.observability.svc.cluster.local]:587    edge-01:S3cr3tFromVault
EOF
$ sudo postmap hash:/etc/postfix/sasl_passwd
$ sudo chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
$ ls -l /etc/postfix/sasl_passwd*
-rw-------. 1 root root    76 Aug 26 12:02 /etc/postfix/sasl_passwd
-rw-------. 1 root root 12288 Aug 26 12:02 /etc/postfix/sasl_passwd.db
```

The systemd drop-in that makes the null client observable and self-healing:

```ini
# /etc/systemd/system/postfix.service.d/10-hardening.conf
[Unit]
# The relay lives in the cluster; do not start before the network is truly up.
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=5s
# Refuse to start on a broken config rather than starting half-deaf.
ExecStartPre=/usr/sbin/postfix check
ExecStartPre=/usr/sbin/postconf -e "myhostname=%H.internal.example.net"
# Filesystem hardening: Postfix needs root, so constrain what root can reach.
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=false
ReadWritePaths=/var/spool/postfix /var/lib/postfix /etc/postfix
```

A queue-depth watchdog as a timer — this is the piece most estates are missing:

```ini
# /etc/systemd/system/mailq-watch.service
[Unit]
Description=Alert when the local mail queue is not draining
After=postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/mailq-watch
```

```ini
# /etc/systemd/system/mailq-watch.timer
[Unit]
Description=Run the mail queue watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/libexec/mailq-watch — export queue depth for node_exporter textfile collector.
set -euo pipefail

OUT=/var/lib/node_exporter/textfile_collector/postfix_queue.prom
TMP="${OUT}.$$"

count_queue() {
    local q=$1
    find "/var/spool/postfix/${q}" -type f 2>/dev/null | wc -l
}

{
    echo '# HELP postfix_queue_length Number of messages per Postfix queue directory.'
    echo '# TYPE postfix_queue_length gauge'
    for q in maildrop incoming active deferred hold corrupt; do
        printf 'postfix_queue_length{queue="%s"} %d\n' "$q" "$(count_queue "$q")"
    done

    echo '# HELP postfix_aliases_db_stale 1 if /etc/aliases is newer than its database.'
    echo '# TYPE postfix_aliases_db_stale gauge'
    stale=0
    for db in /etc/aliases.db /etc/aliases.lmdb; do
        [ -e "$db" ] || continue
        [ /etc/aliases -nt "$db" ] && stale=1
    done
    printf 'postfix_aliases_db_stale %d\n' "$stale"

    echo '# HELP postfix_up 1 if the Postfix master process is running.'
    echo '# TYPE postfix_up gauge'
    if postfix status >/dev/null 2>&1; then echo 'postfix_up 1'; else echo 'postfix_up 0'; fi
} > "$TMP"

mv -f "$TMP" "$OUT"
```

### 6.2 Kubernetes central relay — complete manifest set

The counterpart to the null clients: one durable, observable SMTP relay for the whole cluster.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    kubernetes.io/metadata.name: observability
    pod-security.kubernetes.io/enforce: baseline
    # Postfix's master(8) must start as root to spawn its unprivileged
    # children under distinct UIDs; `restricted` is therefore not achievable
    # without a rootless rebuild. `baseline` + a tight capability set is the
    # honest trade-off, documented rather than silently worked around.
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: postfix-relay-config
  namespace: observability
data:
  main.cf: |
    # =========================================================================
    # Central SMTP relay — accepts from in-cluster null clients, authenticates
    # to the upstream provider, owns the only IP that appears in our SPF record.
    # =========================================================================
    compatibility_level    = 3.6
    queue_directory        = /var/spool/postfix
    command_directory      = /usr/sbin
    daemon_directory       = /usr/libexec/postfix
    data_directory         = /var/lib/postfix
    mail_owner             = postfix
    setgid_group           = postdrop

    # --- Identity ---------------------------------------------------------
    myhostname             = mail-relay.example.net
    mydomain               = example.net
    myorigin               = $mydomain
    append_dot_mydomain    = no

    # --- Listening: cluster-wide, on all interfaces inside the pod ---------
    inet_interfaces        = all
    inet_protocols         = ipv4
    # The cluster pod CIDR. Ingress is additionally constrained by
    # NetworkPolicy — defence in depth, because mynetworks alone is a
    # source-IP ACL and pod IPs are recycled.
    mynetworks             = 10.42.0.0/16 127.0.0.0/8

    # --- No local delivery: this is a relay, full stop ---------------------
    mydestination          =
    local_transport        = error:5.1.1 No local delivery on the relay
    local_recipient_maps   =
    alias_maps             = texthash:/etc/postfix/aliases
    # texthash is read into memory at process start and needs NO postalias
    # run and NO writable filesystem — the correct map type for a container
    # whose /etc/postfix is a read-only ConfigMap mount.
    alias_database         =
    allow_mail_to_commands =
    allow_mail_to_files    =

    # --- Relay policy: authenticated cluster senders only ------------------
    smtpd_relay_restrictions =
        permit_mynetworks,
        reject_unauth_destination
    smtpd_recipient_restrictions =
        permit_mynetworks,
        reject_unauth_destination,
        reject_non_fqdn_recipient,
        reject_unknown_recipient_domain,
        reject
    smtpd_client_restrictions   = permit_mynetworks, reject
    smtpd_helo_required         = yes
    smtpd_helo_restrictions     = permit_mynetworks, reject_invalid_helo_hostname
    smtpd_sender_restrictions   = permit_mynetworks, reject_non_fqdn_sender
    disable_vrfy_command        = yes
    smtpd_discard_ehlo_keywords = chunking

    # --- Rate limits: one runaway CronJob must not exhaust the provider ----
    smtpd_client_connection_count_limit    = 20
    smtpd_client_connection_rate_limit     = 60
    smtpd_client_message_rate_limit        = 300
    smtpd_error_sleep_time                 = 5s
    smtpd_soft_error_limit                 = 10
    smtpd_hard_error_limit                 = 20
    anvil_rate_time_unit                   = 60s

    # --- Upstream ---------------------------------------------------------
    relayhost                     = [smtp.provider.example]:587
    smtp_sasl_auth_enable         = yes
    smtp_sasl_password_maps       = texthash:/etc/postfix/sasl/sasl_passwd
    smtp_sasl_security_options    = noanonymous
    smtp_tls_security_level       = verify
    smtp_tls_mandatory_protocols  = >=TLSv1.2
    smtp_tls_CAfile               = /etc/ssl/certs/ca-certificates.crt
    smtp_tls_loglevel             = 1

    # --- Envelope hygiene: every message leaves as our domain -------------
    sender_canonical_maps    = texthash:/etc/postfix/sender_canonical
    sender_canonical_classes = envelope_sender
    smtp_header_checks       = regexp:/etc/postfix/header_checks_out

    # --- Queue: alerting SLO, not archival ---------------------------------
    maximal_queue_lifetime = 6h
    bounce_queue_lifetime  = 2h
    delay_warning_time     = 20m
    minimal_backoff_time   = 60s
    maximal_backoff_time   = 1200s
    queue_run_delay        = 60s
    default_destination_concurrency_limit = 10
    message_size_limit     = 26214400

    # --- Logging to stdout so kubectl logs / Loki see it -------------------
    maillog_file           = /dev/stdout
    maillog_file_permissions = 0644

  master.cf: |
    # service  type  private unpriv  chroot  wakeup  maxproc  command + args
    smtp       inet  n       -       n       -       -        smtpd
    pickup     unix  n       -       n       60      1        pickup
    cleanup    unix  n       -       n       -       0        cleanup
    qmgr       unix  n       -       n       300     1        qmgr
    tlsmgr     unix  -       -       n       1000?   1        tlsmgr
    rewrite    unix  -       -       n       -       -        trivial-rewrite
    bounce     unix  -       -       n       -       0        bounce
    defer      unix  -       -       n       -       0        bounce
    trace      unix  -       -       n       -       0        bounce
    verify     unix  -       -       n       -       1        verify
    flush      unix  n       -       n       1000?   0        flush
    proxymap   unix  -       -       n       -       -        proxymap
    proxywrite unix  -       -       n       -       1        proxymap
    smtp       unix  -       -       n       -       -        smtp
    relay      unix  -       -       n       -       -        smtp
    showq      unix  n       -       n       -       -        showq
    error      unix  -       -       n       -       -        error
    retry      unix  -       -       n       -       -        error
    discard    unix  -       -       n       -       -        discard
    anvil      unix  -       -       n       -       1        anvil
    scache     unix  -       -       n       -       1        scache
    postlog    unix-dgram n  -       n       -       1        postlogd

  aliases: |
    # texthash: no database, read at process start. `postfix reload` re-reads.
    postmaster:      sre-team@example.net
    mailer-daemon:   postmaster
    abuse:           security@example.net
    root:            sre-team@example.net

  sender_canonical: |
    # Everything leaving the cluster claims a single, SPF-authorised domain.
    /^root@.*/                      noreply@example.net
    /^alerts@.*\.internal$/         alerts@example.net
    /^cron@.*\.internal$/           cron-reports@example.net
    /^.*@.*\.svc\.cluster\.local$/  noreply@example.net

  header_checks_out: |
    /^Received:.*\.svc\.cluster\.local/   IGNORE
    /^Received:.*\[10\.42\./              IGNORE
    /^X-Originating-IP:/                 IGNORE
---
apiVersion: v1
kind: Secret
metadata:
  name: postfix-relay-sasl
  namespace: observability
type: Opaque
stringData:
  # Rendered by External Secrets Operator from Vault at kv/observability/smtp.
  # texthash reads this plain file directly — no postmap, no writable mount.
  sasl_passwd: |
    [smtp.provider.example]:587    apikey:REPLACED_BY_EXTERNAL_SECRETS
---
apiVersion: v1
kind: Service
metadata:
  name: mail-relay
  namespace: observability
  labels:
    app.kubernetes.io/name: postfix-relay
spec:
  type: ClusterIP
  # Headless is required for stable per-pod DNS so a null client can be
  # pinned to one relay pod and its queue for the duration of an incident.
  clusterIP: None
  selector:
    app.kubernetes.io/name: postfix-relay
  ports:
    - name: smtp
      port: 25
      targetPort: smtp
      protocol: TCP
    - name: metrics
      port: 9154
      targetPort: metrics
      protocol: TCP
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    app.kubernetes.io/name: postfix-relay
spec:
  serviceName: mail-relay
  replicas: 2
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postfix-relay
      annotations:
        # Force a rollout when main.cf changes; Postfix does not watch files.
        checksum/config: "REPLACED_BY_HELM_SHA256SUM"
    spec:
      terminationGracePeriodSeconds: 120   # let the active queue drain
      securityContext:
        fsGroup: 89                        # postfix group; makes the PVC writable
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: postfix-relay
      containers:
        - name: postfix
          image: registry.example.net/platform/postfix:3.8.6-r2
          imagePullPolicy: IfNotPresent
          # start-fg (Postfix >= 3.0) runs master(8) in the foreground:
          # PID 1 semantics without a supervisor, correct SIGTERM handling.
          command: ["/usr/sbin/postfix", "start-fg"]
          lifecycle:
            preStop:
              exec:
                # Attempt one queue flush before the pod goes away, so the
                # deferred backlog is not stranded on a PVC nobody watches.
                command: ["/bin/sh", "-c", "postqueue -f; sleep 10"]
          ports:
            - name: smtp
              containerPort: 25
              protocol: TCP
          securityContext:
            # master(8) needs root to bind :25 and to fork children as the
            # postfix/nobody UIDs. Everything else is dropped.
            runAsUser: 0
            runAsNonRoot: false
            allowPrivilegeEscalation: true
            readOnlyRootFilesystem: false
            capabilities:
              drop: ["ALL"]
              add:
                - CHOWN            # postfix set-permissions on the queue
                - DAC_OVERRIDE     # queue file access across UIDs
                - FOWNER
                - SETGID           # spawn smtpd as postfix
                - SETUID
                - NET_BIND_SERVICE # bind TCP/25
                - KILL             # master reaping its children
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
          startupProbe:
            exec:
              command: ["/bin/sh", "-c", "postfix status"]
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 12
          livenessProbe:
            exec:
              command: ["/bin/sh", "-c", "postfix status"]
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          readinessProbe:
            # A real SMTP handshake, not a bare tcpSocket: master(8) can be
            # listening while smtpd is wedged, and tcpSocket cannot tell.
            exec:
              command:
                - /bin/sh
                - -c
                - "printf 'QUIT\\r\\n' | timeout 5 nc 127.0.0.1 25 | grep -q '^220 '"
            periodSeconds: 10
            timeoutSeconds: 6
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /etc/postfix/main.cf
              subPath: main.cf
              readOnly: true
            - name: config
              mountPath: /etc/postfix/master.cf
              subPath: master.cf
              readOnly: true
            - name: config
              mountPath: /etc/postfix/aliases
              subPath: aliases
              readOnly: true
            - name: config
              mountPath: /etc/postfix/sender_canonical
              subPath: sender_canonical
              readOnly: true
            - name: config
              mountPath: /etc/postfix/header_checks_out
              subPath: header_checks_out
              readOnly: true
            - name: sasl
              mountPath: /etc/postfix/sasl
              readOnly: true
            - name: spool
              mountPath: /var/spool/postfix
            - name: lib
              mountPath: /var/lib/postfix

        - name: exporter
          image: registry.example.net/platform/postfix-exporter:0.4.0
          args:
            - --postfix.showq_path=/var/spool/postfix/public/showq
            - --web.listen-address=:9154
            - --systemd.enable=false
          ports:
            - name: metrics
              containerPort: 9154
          securityContext:
            runAsUser: 89                 # postfix uid: enough to read showq
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: 10m, memory: 24Mi}
            limits:   {cpu: 100m, memory: 64Mi}
          volumeMounts:
            - name: spool
              mountPath: /var/spool/postfix
              readOnly: true

      volumes:
        - name: config
          configMap:
            name: postfix-relay-config
            defaultMode: 0644
        - name: sasl
          secret:
            secretName: postfix-relay-sasl
            defaultMode: 0600
        - name: lib
          emptyDir: {}

  volumeClaimTemplates:
    - metadata:
        name: spool
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-nvme
        resources:
          requests:
            storage: 5Gi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postfix-relay
  namespace: observability
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postfix-relay
  namespace: observability
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  policyTypes: [Ingress, Egress]
  ingress:
    # Only namespaces explicitly labelled as mail senders may submit.
    - from:
        - namespaceSelector:
            matchLabels:
              example.net/may-send-mail: "true"
      ports:
        - protocol: TCP
          port: 25
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9154
  egress:
    # DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    # Upstream submission only. Note: NOT port 25 outbound — the relay
    # authenticates on 587 and never speaks to arbitrary MX hosts.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 169.254.0.0/16
      ports:
        - {protocol: TCP, port: 587}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: postfix-relay
  endpoints:
    - port: metrics
      interval: 30s
      scrapeTimeout: 10s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postfix-relay
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: mta.rules
      rules:
        - alert: PostfixDeferredQueueGrowing
          expr: postfix_showq_message_size_bytes_count{queue="deferred"} > 50
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Postfix deferred queue on {{ $labels.pod }} above 50 messages"
            description: >-
              Mail is not leaving the cluster. Run `kubectl exec -n observability
              {{ $labels.pod }} -c postfix -- qshape deferred` to see which
              destination domain is failing.
            runbook_url: https://runbooks.example.net/mta/deferred-queue

        - alert: PostfixQueueStalled
          # Age of the oldest message, not its count: 5 messages stuck for an
          # hour is a worse signal than 500 that drain in 30 seconds.
          expr: postfix_showq_message_age_seconds{quantile="0.99"} > 1800
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Oldest queued message on {{ $labels.pod }} exceeds 30 minutes"
            runbook_url: https://runbooks.example.net/mta/queue-stalled

        - alert: PostfixDown
          expr: up{job="postfix-relay"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Postfix relay {{ $labels.pod }} is not scraping"

        - alert: PostfixNoMailDelivered
          # The dead-man's switch: silence is the failure mode of an MTA.
          expr: rate(postfix_smtp_delivery_delay_seconds_count[30m]) == 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "No mail delivered by {{ $labels.pod }} in the last hour"
            description: >-
              Either genuinely no traffic, or the submission path is broken
              upstream. Verify with a synthetic probe before dismissing.
```

**Why `StatefulSet` and not `Deployment`** — this is the design decision worth defending in a review:

| | Deployment + `emptyDir` | Deployment + shared RWX PVC | **StatefulSet + per-pod RWO PVC** |
|---|---|---|---|
| Deferred queue survives pod restart | **no — silently discarded** | yes | **yes** |
| Two Postfix instances on one spool | n/a | **corruption: `qmgr` assumes exclusive ownership** | never happens |
| Stable per-pod DNS to inspect *this* pod's queue | no | no | **yes** (`postfix-relay-0.mail-relay`) |
| Storage cost | zero | one volume | one volume per replica |
| Correct choice | only if mail loss is acceptable and alerting is idempotent | **never** | default |

The shared-RWX option is the trap: `qmgr(8)` maintains in-memory state about `active/` and holds no cross-host lock. Two pods on one NFS spool will double-deliver and corrupt queue files. Postfix's own documentation is explicit that a queue directory belongs to exactly one running instance.

### 6.3 Wiring Alertmanager to the relay

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      # The in-cluster relay. No auth needed: NetworkPolicy + mynetworks
      # already constrain who may submit.
      smtp_smarthost: 'mail-relay.observability.svc.cluster.local:25'
      smtp_from: 'alerts@example.net'
      smtp_require_tls: false
      resolve_timeout: 5m

    route:
      receiver: sre-email
      group_by: ['alertname', 'cluster', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h

    receivers:
      - name: sre-email
        email_configs:
          - to: 'oncall@example.net'
            send_resolved: true
            headers:
              Subject: '[{{ .Status | toUpper }}:{{ .Alerts.Firing | len }}] {{ .CommonLabels.alertname }}'
```

Note `smtp_require_tls: false` on the *internal* hop: the traffic never leaves the cluster network, the NetworkPolicy restricts submitters, and the relay enforces `smtp_tls_security_level = verify` on the hop that actually crosses the internet. Terminating TLS twice inside the same node's veth pair buys nothing and adds a certificate-rotation failure mode to your paging path.

---

## 7. Verification and failure diagnosis

### 7.1 The verification ladder — cheapest test first

Run these in order. Each rung isolates one layer; stopping at the first failure saves you from debugging layer 5 when layer 1 is broken.

```
$ # ── Rung 1: is an MTA installed, and which one? ────────────────────────────
$ readlink -f "$(command -v sendmail)"
/usr/sbin/sendmail.postfix

$ # ── Rung 2: is it running and listening? ───────────────────────────────────
$ systemctl is-active postfix && postfix status
active
postfix/postfix-script: the Postfix mail system is running: PID: 918

$ ss -lntp 'sport = :25'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      100        127.0.0.1:25        0.0.0.0:*     users:(("master",pid=918,fd=13))

$ # ── Rung 3: does the configuration parse? ──────────────────────────────────
$ sudo postfix check; echo "exit=$?"
exit=0

$ postconf -n | head -12
alias_database = hash:/etc/aliases
alias_maps = hash:/etc/aliases
allow_mail_to_commands =
allow_mail_to_files =
bounce_queue_lifetime = 1h
compatibility_level = 3.6
delay_warning_time = 15m
inet_interfaces = loopback-only
inet_protocols = ipv4
local_recipient_maps =
local_transport = error:5.1.1 Mailbox unavailable — this host is a null client
mail_owner = postfix

$ # ── Rung 4: is the alias database current? ─────────────────────────────────
$ [ /etc/aliases -nt /etc/aliases.db ] && echo "STALE — run newaliases" || echo "current"
current

$ # ── Rung 5: does alias expansion resolve as intended? ──────────────────────
$ postalias -q root hash:/etc/aliases
sre-oncall, \root
$ postalias -q sre-oncall hash:/etc/aliases
:include:/etc/mail/lists/sre-oncall

$ # ── Rung 6: what does the MTA itself think the address expands to? ─────────
$ sendmail -bv root
$ sleep 2 && sudo tail -3 /var/log/maillog
Aug 26 12:41:07 edge-01 postfix/cleanup[9912]: C41A31A1102: message-id=<20260826124107.C41A31A1102@edge-01.internal>
Aug 26 12:41:07 edge-01 postfix/qmgr[922]: C41A31A1102: from=<>, size=298, nrcpt=1 (queue active)
Aug 26 12:41:07 edge-01 postfix/verify[9915]: cache btree:/var/lib/postfix/verify full cleanup: retained=0 dropped=0 entries=0

$ # ── Rung 7: end-to-end, with the envelope sender set explicitly ────────────
$ printf 'Subject: mta smoke test %s\n\nsent from %s at %s\n' \
      "$(date +%s)" "$(hostname -f)" "$(date -Is)" \
  | sendmail -i -f "smoke@$(hostname -f)" oncall@example.net

$ # ── Rung 8: did it leave? ──────────────────────────────────────────────────
$ mailq
Mail queue is empty
$ sudo grep -E 'status=(sent|bounced|deferred)' /var/log/maillog | tail -1
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>,
  relay=mail-relay.observability.svc.cluster.local[10.43.7.19]:587, delay=0.42,
  delays=0.05/0.01/0.19/0.17, dsn=2.0.0, status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
```

`status=sent` plus a remote queue ID is the only proof of delivery to the next hop. An empty `mailq` alone proves nothing — it is equally consistent with "delivered" and with "bounced and discarded".

### 7.2 Reading a Postfix log line

Every delivery attempt produces one line whose fields are the whole diagnosis:

```
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>,
  orig_to=<root@edge-01.internal>, relay=mail-relay[10.43.7.19]:587,
  conn_use=2, delay=0.42, delays=0.05/0.01/0.19/0.17, dsn=2.0.0,
  status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
```

| Field | Meaning | What it tells you |
|---|---|---|
| `postfix/smtp[9931]` | the **component** | `smtp`=outbound, `smtpd`=inbound, `local`=final delivery/aliases, `pipe`=alias command, `qmgr`=scheduling, `cleanup`=rewriting |
| `D18B41A1105` | queue ID | joins all lines for this message: `grep <id> /var/log/maillog` |
| `to=` / `orig_to=` | final / original recipient | **`orig_to` differing proves an alias or `.forward` fired** |
| `relay=` | next hop | `local` ⇒ MDA; `none` ⇒ never connected |
| `delay=0.42` | total seconds | |
| `delays=a/b/c/d` | **before-qmgr / in-queue / connect+HELO / data+response** | a large 2nd field = queue backlog; large 3rd = network/DNS; large 4th = slow receiver |
| `dsn=2.0.0` | RFC 3463 status | `2.x.x` success, `4.x.x` **transient** (retry), `5.x.x` **permanent** (bounce) |
| `status=` | outcome | `sent`, `deferred`, `bounced`, `expired` |
| `(...)` | remote server's literal reply | **read this first when it is not `sent`** |

Join all lines for one message:

```
$ sudo grep D18B41A1105 /var/log/maillog
Aug 26 12:41:33 edge-01 postfix/pickup[921]: D18B41A1105: uid=0 from=<root>
Aug 26 12:41:33 edge-01 postfix/cleanup[9928]: D18B41A1105: message-id=<20260826124133.D18B41A1105@edge-01.internal>
Aug 26 12:41:33 edge-01 postfix/qmgr[922]: D18B41A1105: from=<root@edge-01.internal>, size=412, nrcpt=1 (queue active)
Aug 26 12:41:33 edge-01 postfix/smtp[9931]: D18B41A1105: to=<oncall@example.net>, orig_to=<root@edge-01.internal>, relay=mail-relay[10.43.7.19]:587, delay=0.42, delays=0.05/0.01/0.19/0.17, dsn=2.0.0, status=sent (250 2.0.0 Ok: queued as 4Wq2Xz1TzZz)
Aug 26 12:41:33 edge-01 postfix/qmgr[922]: D18B41A1105: removed
```

On systemd hosts with journald-only logging:

```
$ sudo journalctl -u postfix --since '10 min ago' -o cat --no-pager
$ sudo journalctl -t postfix/smtp -f
$ kubectl logs -n observability postfix-relay-0 -c postfix -f | grep -E 'status=(deferred|bounced)'
```

### 7.3 Failure signature table

| Log / terminal signature | Root cause | Command that confirms | Fix |
|---|---|---|---|
| `warning: database /etc/aliases.db is older than source file /etc/aliases` | alias source edited, DB not rebuilt | `ls -l /etc/aliases*` | `newaliases` |
| `fatal: open database /etc/aliases.db: No such file or directory` | DB never built | `postconf alias_database` | `newaliases` |
| `status=deferred (alias database unavailable)` | `alias_maps` points at a missing/unreadable map | `postalias -q root hash:/etc/aliases` | build it; check SELinux label |
| Alias added but never used | in `alias_database` only, not `alias_maps` | `postconf alias_maps alias_database` | add to **both**, `newaliases`, `postfix reload` |
| `status=bounced (User unknown in local recipient table)` | alias target is not a local user and `local_recipient_maps` is set | `getent passwd <target>` | create user, fix alias, or clear `local_recipient_maps` |
| `.forward` ignored, mail lands in mbox | permissions on `$HOME` or the file | `ls -ld ~ ~/.forward` | `chmod 700 ~; chmod 600 ~/.forward` |
| `SYSERR(root): forward /home/x/.forward: Group writable directory` | same, sendmail being explicit | `ls -ld /home/x` | `chmod 700 /home/x` |
| `.forward` correct and permissions correct, still ignored | SELinux label, or NFS root-squash | `ausearch -m AVC -ts recent`, `mount \| grep home` | `restorecon`; `no_root_squash` or `local(8)` running as recipient |
| `status=bounced (mail forwarding loop for x@y)` | alias/`.forward` cycle | trace `postalias -q` recursively | insert `\user` to terminate |
| `status=bounced (mail for X loops back to myself)` | MX points here, domain not in `mydestination` | `dig +short MX X` vs `postconf mydestination` | add to `mydestination`/`relay_domains`, or fix DNS |
| `status=deferred (connect to X[IP]:25: Connection timed out)` | egress 25 blocked by cloud/firewall | `nc -vz X 25` | relay via 587 with auth |
| `status=deferred (connect to X[IP]:25: Connection refused)` | nothing listening on the peer | `ss -lntp` on the peer | start the peer's MTA |
| `status=deferred (Host or domain name not found. Name service error ... type=MX)` | DNS broken or domain has no MX | `dig MX X`, `cat /etc/resolv.conf` | fix resolver / add MX |
| `status=deferred (Server certificate not verified)` | `smtp_tls_security_level = verify` and CA bundle missing/stale | `openssl s_client -starttls smtp -connect X:587` | install CA bundle; fix `smtp_tls_CAfile` |
| `554 5.7.1 Service unavailable; Client host blocked` | source IP on a blocklist | check the IP at the named RBL | relay through an authorised sender |
| `550 5.7.23 SPF validation failed` | forwarding without SRS, or IP not in SPF | `dig +short TXT example.net \| grep spf` | add relay IP to SPF; enable SRS |
| `450 4.7.1 Client host rejected: cannot find your reverse hostname` | no PTR for the egress IP | `dig -x <egress-ip>` | set PTR at the hoster; or relay |
| `postdrop: warning: unable to look up public/pickup: No such file or directory` | Postfix not running, or chroot/queue perms wrong | `postfix status` | `postfix start`; `postfix set-permissions` |
| `maildrop/` growing, `incoming/` empty | `pickup(8)` dead or `master.cf` `pickup` disabled | `ps -ef \| grep pickup` | `postfix reload`; check `master.cf` |
| Everything `sent`, recipient sees nothing | delivered to a *different* mailbox by a `.forward` you did not know about | check `orig_to=` in the log | follow the chain |
| `mailq` empty but no mail arrives, no log lines | the app is not calling sendmail at all | `strace -f -e trace=execve -p <pid>` | fix the app / `MAILTO` |

### 7.4 Network-layer transcripts

**Raw SMTP against the relay** — reads the capability list, which tells you what the peer will accept:

```
$ telnet mail-relay.observability.svc.cluster.local 25
Trying 10.43.7.19...
Connected to mail-relay.observability.svc.cluster.local.
Escape character is '^]'.
220 mail-relay.example.net ESMTP Postfix
EHLO edge-01.internal.example.net
250-mail-relay.example.net
250-PIPELINING
250-SIZE 26214400
250-ETRN
250-STARTTLS
250-ENHANCEDSTATUSCODES
250-8BITMIME
250-DSN
250 SMTPUTF8
MAIL FROM:<smoke@edge-01.internal.example.net>
250 2.1.0 Ok
RCPT TO:<oncall@example.net>
250 2.1.5 Ok
DATA
354 End data with <CR><LF>.<CR><LF>
Subject: manual smtp probe
From: smoke@edge-01.internal.example.net
To: oncall@example.net

This message was injected by hand to prove the relay accepts submissions.
.
250 2.0.0 Ok: queued as 7Kj2Lm4NpQ
QUIT
221 2.0.0 Bye
Connection closed by foreign host.
```

Note the **absence of `250-AUTH`**: this relay offers no SASL because it authorises by network, exactly as `smtpd_relay_restrictions = permit_mynetworks, reject` specifies. If you *expect* `AUTH` and it is missing, the usual cause is that `smtpd_tls_auth_only = yes` and you have not issued `STARTTLS` yet — the server hides `AUTH` until the channel is encrypted.

**TLS verification against the upstream provider:**

```
$ openssl s_client -starttls smtp -crlf -connect smtp.provider.example:587 \
      -servername smtp.provider.example 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
subject=CN=smtp.provider.example
issuer=C=US, O=Let's Encrypt, CN=R11
notBefore=Aug  1 04:12:07 2026 GMT
notAfter=Oct 30 04:12:06 2026 GMT
```

```
$ openssl s_client -starttls smtp -crlf -connect smtp.provider.example:587 \
      -servername smtp.provider.example </dev/null 2>&1 \
  | grep -E 'Verify return code|Protocol|Cipher'
Protocol  : TLSv1.3
Cipher    : TLS_AES_256_GCM_SHA384
Verify return code: 0 (ok)
```

`Verify return code: 0 (ok)` is what `smtp_tls_security_level = verify` requires. Anything else and every message will defer with `Server certificate not verified` — a failure mode that presents as "mail stopped one morning" when an intermediate CA rotated.

**MX and SPF from the sending host — always resolve from the host that will send:**

```
$ dig +short MX example.net
10 mx1.example.net.
20 mx2.example.net.
$ dig +short A mx1.example.net
203.0.113.25
$ dig +short -x 198.51.100.7
mail-relay.example.net.
$ dig +short TXT example.net | tr -d '"' | grep -i spf
v=spf1 ip4:198.51.100.7 include:_spf.provider.example -all
$ dig +short TXT _dmarc.example.net | tr -d '"'
v=DMARC1; p=quarantine; rua=mailto:dmarc@example.net; pct=100
```

Three things must agree: the PTR of your egress IP, the `myhostname` you send in `EHLO`, and the `ip4:` entry in SPF. Any disagreement produces intermittent, receiver-dependent rejections — the hardest class of mail bug, because it works against your test recipient and fails against the customer's.

### 7.5 Address-test mode (sendmail and Exim)

Both offer an interactive rule-set trace, which is the fastest way to answer "where would this address actually go?" without sending anything.

**sendmail** — ruleset `3,0` is canonicalisation plus mailer selection:

```
$ sudo /usr/sbin/sendmail -bt
ADDRESS TEST MODE (ruleset 3 NOT automatically invoked)
Enter <ruleset> <address>
> 3,0 oncall@example.net
canonify           input: oncall @ example . net
Canonify2          input: oncall < @ example . net >
Canonify2        returns: oncall < @ example . net . >
canonify         returns: oncall < @ example . net . >
parse              input: oncall < @ example . net . >
Parse0             input: oncall < @ example . net . >
Parse0           returns: oncall < @ example . net . >
ParseLocal         input: oncall < @ example . net . >
ParseLocal       returns: oncall < @ example . net . >
Parse1             input: oncall < @ example . net . >
Parse1           returns: $# esmtp $@ example . net . $: oncall < @ example . net . >
parse            returns: $# esmtp $@ example . net . $: oncall < @ example . net . >
> /quit
```

`$# esmtp` is the selected mailer; `$@ example.net.` is the host it will be handed to. If you expected `$# local`, the address is not being treated as local and no alias will ever fire for it.

**Exim** — `-bt` replays the router chain and prints the winner:

```
$ exim -bt root
root@edge-01.internal
  <-- root@edge-01.internal
  router = system_aliases, transport = remote_smtp
  host mail-relay.observability.svc.cluster.local [10.43.7.19]

$ exim -bt sre@edge-01.internal
sre@edge-01.internal
  <-- sre@edge-01.internal
  router = userforward, transport = remote_smtp
  sre-team@example.net

$ exim -bV
Exim version 4.96 #2 built 26-Aug-2026 08:11:02
Copyright (c) University of Cambridge, 1995 - 2018
...
Configuration file is /var/lib/exim4/config.autogenerated
```

`exim -bV` parses the configuration and reports syntax errors — Exim's equivalent of `postfix check`, and the correct pre-restart gate on Debian.

### 7.6 The synthetic probe — the only honest MTA monitor

Queue depth is a lagging indicator: a relay that silently discards mail has an empty queue. The dead-man's switch is a message sent on a schedule to an address whose arrival is itself monitored.

```bash
#!/usr/bin/env bash
# /usr/local/libexec/mail-canary — inject one traceable message per interval.
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -f)"
TARGET="${MAIL_CANARY_TARGET:?set MAIL_CANARY_TARGET}"

/usr/sbin/sendmail -i -f "canary@${HOST}" "$TARGET" <<EOF
Subject: mail-canary ${HOST} ${STAMP}
From: canary@${HOST}
To: ${TARGET}
X-Mail-Canary-Host: ${HOST}
X-Mail-Canary-Stamp: ${STAMP}

Automated liveness probe. If this stops arriving, the mail path is broken
even though every queue on every host may look empty.
EOF

logger -t mail-canary "injected ${STAMP} for ${TARGET}"
```

The receiving side (a mailbox polled by a small consumer, or a provider webhook) exports `mail_canary_last_seen_timestamp_seconds`, and the alert is `time() - mail_canary_last_seen_timestamp_seconds > 3600`. This is the only check that covers the whole chain — sendmail shim, aliases, queue, relay, TLS, SPF, and the provider — and it is the one that catches the failure mode nothing else does: mail that is accepted and then quietly dropped.

---

## 8. Exam-focused quick reference

### 8.1 The commands that appear on the exam

| Command | Effect |
|---|---|
| `newaliases` | rebuild the alias database from `/etc/aliases`; identical to `sendmail -bi` |
| `sendmail -bi` | same |
| `postalias /etc/aliases` | Postfix-native alias database build |
| `postalias -q <key> hash:/etc/aliases` | query a single alias |
| `mailq` | print the mail queue; identical to `sendmail -bp` |
| `sendmail -bp` | same |
| `postqueue -p` | Postfix-native queue listing |
| `postqueue -f` | flush the deferred queue |
| `postsuper -d <id>` / `-d ALL` | delete queued message(s) |
| `postsuper -r ALL` | requeue everything (re-applies aliases) |
| `exim -bp` / `-bpc` / `-M <id>` / `-Mrm <id>` | Exim: list / count / force / remove |
| `qmail-qstat`, `qmail-qread` | qmail queue status and listing |
| `mail -s "subject" user@host` | send from stdin |
| `mail` (no args) | read `/var/mail/$USER` |
| `sendmail -t < file` | send, taking recipients from the headers |
| `sendmail -f addr recipient` | send with an explicit envelope sender |
| `sendmail -bv addr` | expand/verify an address without delivering |
| `postconf -n` | show non-default Postfix settings |
| `postconf -d <param>` | show a built-in default |
| `postconf -e 'p = v'` | edit `main.cf` safely |
| `postfix check` / `reload` / `start` / `stop` / `status` | Postfix lifecycle |
| `postcat -q <id>` | dump a queued message |
| `alternatives --config mta` | switch MTA on the Red Hat family |

### 8.2 Sending and reading with `mail(1)`

```
$ echo "disk 92% on /var" | mail -s "edge-01 disk pressure" oncall@example.net

$ mail -s "report" -r "reports@example.net" sre-team@example.net < /tmp/report.txt

$ printf 'Subject: nightly\nTo: sre@example.net\n\nbody line\n' | sendmail -t -i
```

Reading a local mailbox:

```
$ mail
"/var/mail/sre": 2 messages 2 new
>N  1 root@edge-01.inter  Wed Aug 26 09:14   18/612   "Cron <root@edge-01> /usr/local/bin/backup"
 N  2 root@edge-01.inter  Wed Aug 26 11:02   22/748   "smartd: Device: /dev/sda [SAT]"
& 1
Message 1:
From root@edge-01.internal  Wed Aug 26 09:14:02 2026
Subject: Cron <root@edge-01> /usr/local/bin/backup
...
& d 1
& q
Held 1 message in /var/mail/sre
```

`&` prompt commands: `<n>` read, `d <n>` delete, `s <n> file` save, `r` reply, `h` headers, `q` quit (applies deletions), `x` exit (discards deletions). `-a` means "attach a file" in BSD `mailx` and `s-nail`, but GNU mailutils uses `-A` for attachments and `-a` to add a header — **check which implementation is installed before scripting `-a`**:

```
$ readlink -f "$(command -v mail)"
/usr/bin/s-nail
$ dpkg -S "$(readlink -f "$(command -v mail)")" 2>/dev/null || rpm -qf "$(readlink -f "$(command -v mail)")"
s-nail: /usr/bin/s-nail
```

### 8.3 Traps that catch experienced engineers

1. **Editing `/etc/aliases` without running `newaliases`.** The MDA reads `/etc/aliases.db`, never the text file. Exim is the exception — it reads the text directly, which is exactly why the habit fails to transfer between Debian and RHEL.
2. **Believing a `postfix reload` is needed after `newaliases`.** It is not — the database is opened per delivery. A reload *is* needed after editing `main.cf`.
3. **Putting `@domain` on the left of `/etc/aliases`.** Aliases key on the local part only. Domain-qualified rewriting is `virtual_alias_maps` / `virtusertable`.
4. **Assuming an alias affects relayed mail.** Aliases fire only at *local* final delivery. A null client with `mydestination =` never expands `/etc/aliases` for anything, no matter how correct it is.
5. **Confusing `alias_maps` with `alias_database`.** See §3.3 — set both.
6. **`.forward` ignored because `$HOME` is group-writable.** Check the *directory*, not just the file.
7. **Omitting `\user` when a `.forward` also keeps a local copy.** `sre: sre, remote@x` is an infinite loop; `sre: \sre, remote@x` is correct.
8. **Copying `/etc/aliases.db` between hosts.** The Berkeley-DB/LMDB format is not portable across architectures or library versions. Ship the text and rebuild.
9. **Confusing envelope sender with the `From:` header.** Bounces go to the *envelope* sender (`sendmail -f`, `MAIL FROM`). `From:` is only display text.
10. **`mailq` empty ⇒ everything is fine.** Empty is also what a discarded, bounced, or never-submitted message looks like. Confirm with `status=sent` in the log or a synthetic probe.
11. **qmail does not read `~/.forward`.** It reads `~/.qmail`.
12. **`rm` on `/var/spool/mqueue` or `/var/spool/postfix/*`.** Use `postsuper -d` / `exim -Mrm`. Removing a `df` file without its `qf` file leaves a permanently broken queue entry.

---

## 9. References

**LPI official objectives**

* LPIC-1 Exam 102 (102-500) objectives, including 108.3 *Mail Transfer Agent (MTA) basics* — https://www.lpi.org/our-certifications/exam-102-objectives/
* LPIC-1 Exam 101 (101-500) objectives — https://www.lpi.org/our-certifications/exam-101-objectives/
* LPIC-1 certification overview — https://www.lpi.org/our-certifications/lpic-1-overview/

**Postfix**

* Postfix documentation index — https://www.postfix.org/documentation.html
* `aliases(5)` — https://www.postfix.org/aliases.5.html
* `local(8)` (alias and `~/.forward` processing) — https://www.postfix.org/local.8.html
* `postalias(1)` — https://www.postfix.org/postalias.1.html
* `postqueue(1)` — https://www.postfix.org/postqueue.1.html
* `postsuper(1)` — https://www.postfix.org/postsuper.1.html
* `postcat(1)` — https://www.postfix.org/postcat.1.html
* `postconf(5)` — parameter reference — https://www.postfix.org/postconf.5.html
* `sendmail(1)` compatibility interface — https://www.postfix.org/sendmail.1.html
* `master(5)` / `master(8)` architecture — https://www.postfix.org/master.5.html
* QSHAPE_README — queue diagnosis — https://www.postfix.org/QSHAPE_README.html
* STANDARD_CONFIGURATION_README — null client and satellite profiles — https://www.postfix.org/STANDARD_CONFIGURATION_README.html
* TLS_README — https://www.postfix.org/TLS_README.html
* SASL_README — https://www.postfix.org/SASL_README.html
* DATABASE_README — map types (`hash`, `lmdb`, `texthash`, `cdb`) — https://www.postfix.org/DATABASE_README.html
* Postfix architecture overview — https://www.postfix.org/OVERVIEW.html

**Sendmail**

* Sendmail project — https://www.sendmail.org/
* Sendmail Operations Guide (`doc/op/op.me`) — https://www.sendmail.org/documentation
* `smrsh(8)` restricted shell — https://www.sendmail.org/~ca/email/doc8.12/op-sh-4.html

**Exim**

* Exim documentation — https://www.exim.org/docs.html
* Exim Specification, chapter on routers (`redirect`, `system_aliases`, `userforward`) — https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_redirect_router.html
* Exim command-line options (`-bp`, `-bt`, `-bV`, `-M`) — https://www.exim.org/exim-html-current/doc/html/spec_html/ch-the_exim_command_line.html
* Debian Exim4 configuration — https://wiki.debian.org/Exim

**qmail**

* qmail home page (D. J. Bernstein) — https://cr.yp.to/qmail.html
* `dot-qmail(5)` — https://cr.yp.to/qmail/man/dot-qmail.5.html
* `qmail-qstat(8)` / `qmail-qread(8)` — https://cr.yp.to/qmail/man/qmail-qread.8.html
* Maildir specification — https://cr.yp.to/proto/maildir.html
* netqmail — https://www.qmail.org/

**Standards**

* RFC 5321 — Simple Mail Transfer Protocol — https://www.rfc-editor.org/rfc/rfc5321
* RFC 5322 — Internet Message Format — https://www.rfc-editor.org/rfc/rfc5322
* RFC 5598 — Internet Mail Architecture (the MUA/MSA/MTA/MDA/MRA model) — https://www.rfc-editor.org/rfc/rfc5598
* RFC 6409 — Message Submission for Mail (port 587) — https://www.rfc-editor.org/rfc/rfc6409
* RFC 8314 — Cleartext Considered Obsolete: TLS for submission and access — https://www.rfc-editor.org/rfc/rfc8314
* RFC 3463 — Enhanced Mail System Status Codes (`dsn=x.y.z`) — https://www.rfc-editor.org/rfc/rfc3463
* RFC 3464 — Delivery Status Notifications — https://www.rfc-editor.org/rfc/rfc3464
* RFC 2142 — Mailbox names for common services (`postmaster`, `abuse`, `security`) — https://www.rfc-editor.org/rfc/rfc2142
* RFC 7208 — Sender Policy Framework (SPF) — https://www.rfc-editor.org/rfc/rfc7208
* RFC 6376 — DomainKeys Identified Mail (DKIM) — https://www.rfc-editor.org/rfc/rfc6376
* RFC 7489 — DMARC — https://www.rfc-editor.org/rfc/rfc7489

**Distribution documentation**

* Red Hat Enterprise Linux 9 — *Deploying mail transport agents* — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/deploying_different_types_of_servers/deploying-mail-transport-agent_deploying-different-types-of-servers
* Debian `update-alternatives(1)` — https://manpages.debian.org/stable/dpkg/update-alternatives.1.en.html
* Debian Policy §11.6, mail transport agents — https://www.debian.org/doc/debian-policy/ch-customized-programs.html#mail-transport-delivery-and-user-agents

**Operational tooling referenced**

* Prometheus Alertmanager e-mail receiver configuration — https://prometheus.io/docs/alerting/latest/configuration/#email_config
* Kubernetes StatefulSet — https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
* Kubernetes NetworkPolicy — https://kubernetes.io/docs/concepts/services-networking/network-policies/
* Kubernetes Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/