# LPIC-2 (Exams 201-450 & 202-450, v4.5) Advanced Study Guide
## Topic 211 / 2.5: E-Mail Services (Total Exam Weight: 9)

---

## 1. Production Architectural Motivation & Problem Statement

In enterprise production environments, an E-Mail Infrastructure must reliably handle thousands of messages per second while satisfying strict security requirements: zero unauthorized relaying, strict authentication (SASL/TLS), cryptographic identity verification (DKIM/SPF/DMARC), and low-latency storage access for concurrent Mail User Agents (MUAs).

```
                      +--------------------------------------------------------+
                      |                 INTERNET / EXTERNAL MTAs              |
                      +--------------------------------------------------------+
                                       |                      ^
                             SMTP (Port 25)            SMTP (Port 25)
                                       v                      |
+---------------------------------------------------------------------------------------------------+
| BOUNDARY / MAIL TRANSFER AGENT (MTA) - POSTFIX                                                    |
|                                                                                                   |
|  +--------------------+     +---------------------+     +--------------------+                    |
|  |  smtpd (Port 25)   | --> | smtpd_recipient_   | --> | Milter (Rspamd/    |                    |
|  |  Submission (587)  |     | restrictions        |     | OpenDKIM/SpamAss.) |                    |
|  +--------------------+     +---------------------+     +--------------------+                    |
|                                                                  |                                |
|                                                                  v                                |
|  +--------------------+     +---------------------+     +--------------------+                    |
|  | incoming / active  | <-- | cleanup & trivial-  | <-- | Open Relay &       |                    |
|  | queues             |     | rewrite             |     | Header Check       |                    |
|  +--------------------+     +---------------------+     +--------------------+                    |
|            |                                                                                      |
|            v                                                                                      |
|  +--------------------+                                                                           |
|  | qmgr (Queue Mgr)   | --------------------+                                                     |
|  +--------------------+                     |                                                     |
|            | (Local Delivery)               | (Remote Delivery)                                   |
|            v                                v                                                     |
|  +--------------------+           +-------------------+                                           |
|  | lmtp / pipe driver |           | smtp transport    |                                           |
|  +--------------------+           +-------------------+                                           |
+-------------|-------------------------------+|----------------------------------------------------+
              |                                |
       LMTP (Unix Socket)                   SMTP (Port 25)
              v                                |
+------------------------------------+         |
| MAIL DELIVERY AGENT (MDA) - DOVECOT|         |
|                                    |         v
|  +-------------------------------+ |   External MX
|  | lmtp service                  | |   Destinations
|  +-------------------------------+ |
|                 |                  |
|                 v                  |
|  +-------------------------------+ |
|  | Maildir / mdbox storage       | |
|  | (/var/vmail/domain/user)      | |
|  +-------------------------------+ |
+-----------------|------------------+
                  |
     IMAP/IMAPS (143/993) / POP3S (995)
                  v
+------------------------------------+
| MAIL USER AGENTS (Thunderbird, etc)|
+------------------------------------+
```

### Architectural Breakdown of Components:
1. **Mail Submission Agent (MSA - Port 587/465):** Receives messages from authenticated MUAs using explicit TLS (`STARTTLS`) or implicit TLS (`SMTPS`), enforcing SASL authentication (`postfix/smtpd` + Dovecot SASL).
2. **Mail Transfer Agent (MTA - Port 25):** Handles server-to-server relaying via SMTP. Enforces strict relay rules (`smtpd_recipient_restrictions`) to prevent open relay vulnerabilities, applies milters for DKIM/Spam scanning, and routes queued messages.
3. **Mail Delivery Agent (MDA):** Receives validated messages from the MTA (via LMTP socket or local pipe) and commits them to non-volatile mailbox storage on disk while applying server-side filtering (Sieve or Procmail).
4. **Mail Access Server (IMAP/POP3):** Exposes mailbox storage to MUAs over TLS-encrypted protocols (IMAPS/POP3S) with index caching to maintain performance across massive mailboxes.

---

## 2. Technical Comparison & Trade-off Matrices

### MTA Engine Architecture: Postfix vs. Sendmail vs. Exim

| Feature / Dimension | Postfix | Sendmail | Exim |
| :--- | :--- | :--- | :--- |
| **Security Model** | Multi-process modular design with least-privilege daemons (`smtpd`, `cleanup`, `qmgr`, `local`) running chrooted. | Monolithic binary (`sendmail`) running historical root-privilege execution paths. | Single binary executing with elevated privileges; dynamically drops permissions based on operation. |
| **Configuration Complexity** | Key-value pairs (`main.cf`) and table lookups (`hash:`, `mysql:`, `lmdb:`). High readability. | M4 macro preprocessor generating complex `sendmail.cf`. Prone to syntax error regressions. | Single configuration file supporting inline scripting and regex. Highly flexible, high syntax complexity. |
| **Queue Performance** | Highly optimized split queue architecture (`incoming/`, `active/`, `deferred/`, `corrupt/`). Excellent under heavy concurrency. | Single queue directory model. Degrades under high queue depths (>50k messages). | Flexible queue structure, handles custom queue runners natively. Moderately high throughput. |
| **Extensibility** | Milter protocol (`smtpd_milters`), Policy Delegation Protocols, and external script lookup tables. | Native Milter API (originator of the protocol). | Embedded Perl interpreter and direct shell pipe execution capabilities. |

### Mailbox Storage Formats: Maildir vs. mbox vs. Dovecot dbox/mdbox

| Metric | mbox | Maildir | Dovecot mdbox (Multi-dbox) |
| :--- | :--- | :--- | :--- |
| **Structure** | Single monolithic text file containing all messages for a user folder. | Directory containing three subdirectories (`cur`, `new`, `tmp`). One file per message. | Multiple messages packed into larger storage files with separate metadata index files. |
| **File Locking & Concurrency** | Requires mandatory/advisory file locks (`fcntl`, `flock`, `.lock`). High risk of corruption under concurrent writes. | Lockless operation. Atomic message writes via `tmp/` to `new/` directory movement (`rename()`). | High-concurrency lockless index synchronization (`dovecot.index`). Zero lock contention. |
| **Storage Overhead** | Minimal filesystem inode usage (1 file per folder). | High inode consumption (1 inode per email message). | Optimized inode footprint (thousands of emails per storage block file). |
| **I/O & Search Performance** | Sequential read required to locate or delete messages; slow for large mailboxes. | High directory `stat()` and `readdir()` overhead on ext4/xfs without directory indexing. | Ultrafast append and expunge performance with zero POSIX directory traversal penalty. |

### MDA & Filtering Mechanisms: Dovecot LMTP + Sieve vs. Legacy Procmail

| Aspect | Dovecot LMTP + Sieve | Legacy Procmail |
| :--- | :--- | :--- |
| **Protocol Integration** | Native Local Mail Transfer Agent (LMTP) running as a persistent Unix socket service. | Executed as a child process spawned per message by MTA `local` delivery agent. |
| **Standardization** | RFC 5228 compliant declarative scripting language with structured extensions. | Custom regex rule syntax (`:0 hb` flags) written in shell-like macro syntax. |
| **Resource Overhead** | Low (reuses warm persistent Dovecot process pools). | High (fork/exec pipeline overhead per incoming email delivery). |
| **UTF-8 / Internationalization** | Native header and body unicode parsing support. | Limited/legacy byte-oriented regex parsing (requires external pipe workarounds). |

---

## 3. Production Configurations & Infrastructure Manifests

### 3.1 Postfix Main Configuration (`/etc/postfix/main.cf`)

```ini
# =========================================================================
# /etc/postfix/main.cf - Production Enterprise Postfix MTA Configuration
# =========================================================================

# System Identification
smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu/GNU)
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 3.6

# Global Network Identity
myhostname = mx1.example.com
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
mydestination = $myhostname, localhost.$mydomain, localhost
relayhost = 
mynetworks = 127.0.0.0/8 [::1]/128 192.168.10.0/24
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = all

# TLS Configuration - Server (Incoming Connections)
smtpd_tls_cert_file = /etc/letsencrypt/live/mx1.example.com/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/mx1.example.com/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_ciphers = high
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_ciphers = high
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# TLS Configuration - Client (Outgoing Relay Connections)
smtp_tls_security_level = dane
smtp_tls_loglevel = 1
smtp_dns_support_level = dnssec
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

# SASL Authentication Setup (Delegated to Dovecot Unix Socket)
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = $myhostname
broken_sasl_auth_clients = yes

# Virtual Domain & Mailbox Architecture (Mapped to Dovecot MDA via LMTP)
virtual_mailbox_domains = hash:/etc/postfix/vmail_domains
virtual_mailbox_maps = hash:/etc/postfix/vmail_mailbox
virtual_alias_maps = hash:/etc/postfix/virtual_aliases
virtual_transport = lmtp:unix:private/dovecot-lmtp

# Hardened Open Relay Prevention & Access Control Restrictions
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_invalid_helo_hostname,
    reject_non_fqdn_helo_hostname,
    reject_unknown_helo_hostname

smtpd_sender_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain

smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_non_fqdn_recipient,
    reject_unknown_recipient_domain,
    reject_unauth_destination,
    reject_rbl_client zen.spamhaus.org,
    reject_rbl_client bl.spamcop.net

smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

# Milter Integration (OpenDKIM / Spam scanning)
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = $smtpd_milters
milter_default_action = accept
milter_protocol = 6

# Rate Limiting & Resource Protection
smtpd_client_connection_count_limit = 50
smtpd_client_connection_rate_limit = 100
anvil_rate_time_unit = 60s
```

### 3.2 Postfix Master Service Daemon Manifest (`/etc/postfix/master.cf`)

```ini
# ==========================================================================
# /etc/postfix/master.cf - Process Execution and Port Listener Specification
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
#               (yes)   (yes)   (no)    (never) (100)
# ==========================================================================
smtp       inet  n       -       y       -       -       smtpd
# Standard Submission Service over Explicit TLS (Port 587)
submission inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_tls_auth_only=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_helo_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Implicit SMTPS Service over Direct SSL/TLS (Port 465)
smtps      inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

# Core Internal Postfix Pipeline Services
pickup    unix  n       -       y       0       1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
        -o syslog_name=postfix/$service_name
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
postlog   unix  -       -       n       -       1       postlogd
```

### 3.3 Postfix Map Files

#### `/etc/postfix/vmail_domains`
```text
example.com     OK
lab.internal    OK
```

#### `/etc/postfix/vmail_mailbox`
```text
admin@example.com    example.com/admin/Maildir/
user01@example.com   example.com/user01/Maildir/
devops@lab.internal  lab.internal/devops/Maildir/
```

#### `/etc/postfix/virtual_aliases`
```text
info@example.com     admin@example.com
support@example.com  admin@example.com, user01@example.com
```

### 3.4 Dovecot Main Master and Authentication Configuration

#### `/etc/dovecot/dovecot.conf`
```ini
# Dovecot 2.3+ Production Configuration
protocols = imap pop3 lmtp
listen = *, [::]
base_dir = /var/run/dovecot/
instance_name = dovecot
dict {
}
!include conf.d/*.conf
```

#### `/etc/dovecot/conf.d/10-mail.conf`
```ini
mail_location = maildir:/var/vmail/%d/%n/Maildir
mail_uid = 5000
mail_gid = 5000
mail_privileged_group = vmail
first_valid_uid = 500
last_valid_uid = 0
```

#### `/etc/dovecot/conf.d/10-auth.conf`
```ini
disable_plaintext_auth = yes
auth_mechanisms = plain login
!include auth-sql.conf.ext
```

#### `/etc/dovecot/conf.d/auth-sql.conf.ext`
```ini
passdb {
  driver = static
  args = scheme=ARGON2ID password={ARGON2ID}$v=19$m=65536,t=3,p=4$c29tZXNhbHQ$W245...
}

userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/vmail/%d/%n
}
```

#### `/etc/dovecot/conf.d/10-master.conf`
```ini
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service auth {
  # Exposed to Postfix smtpd daemon for SASL
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }

  # Auth listener for internal Dovecot processes
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
}

service auth-worker {
  user = root
}
```

#### `/etc/dovecot/conf.d/20-lmtp.conf`
```ini
protocol lmtp {
  postmaster_address = postmaster@example.com
  mail_plugins = $mail_plugins sieve
}
```

### 3.5 Delivery Filtering Manifests

#### Dovecot Sieve Global Filter (`/var/lib/dovecot/sieve/default.sieve`)
```sieve
require ["fileinto", "mailbox", "envelope", "subaddress"];

# Automatically route incoming spam headers into Junk folder
if header :contains "X-Spam-Flag" "YES" {
    fileinto :create "Junk";
    stop;
}

# Subaddressing logic (e.g. user+alerts@example.com -> Alerts folder)
if envelope :detail "recipient" "alerts" {
    fileinto :create "Alerts";
    stop;
}
```

#### Legacy Procmail Configuration (`/etc/procmailrc`)
```procmail
# Global Procmail Configuration
SHELL=/bin/sh
PATH=/usr/bin:/bin
MAILDIR=$HOME/Maildir
DEFAULT=$MAILDIR/
LOGFILE=/var/log/procmail.log
VERBOSE=off

# Rule 1: Quarantine High Score Spam
:0:
* ^X-Spam-Status: Yes
.Junk/

# Rule 2: Automatically file system notification alerts
:0:
* ^Subject:.*\[CRITICAL ALERT\]
.Alerts/
```

---

## 4. Real CLI Execution & Realistic Terminal Output

### 4.1 Postfix Map Compilation and Verification (`postmap`, `newaliases`, `postconf`)

```bash
$ sudo postmap /etc/postfix/vmail_domains
$ sudo postmap /etc/postfix/vmail_mailbox
$ sudo postmap /etc/postfix/virtual_aliases
$ sudo newaliases
```

#### Querying Active Postfix Runtime Configuration:
```bash
$ postconf -n myhostname smtpd_recipient_restrictions virtual_transport
```
```text
myhostname = mx1.example.com
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_non_fqdn_recipient, reject_unknown_recipient_domain, reject_unauth_destination, reject_rbl_client zen.spamhaus.org, reject_rbl_client bl.spamcop.net
virtual_transport = lmtp:unix:private/dovecot-lmtp
```

#### Querying Table Lookups via `postmap`:
```bash
$ postmap -q "admin@example.com" hash:/etc/postfix/vmail_mailbox
```
```text
example.com/admin/Maildir/
```

---

### 4.2 Queue Inspection and Management (`postqueue`, `postsuper`, `mailq`)

#### Inspecting the Current Mail Queue:
```bash
$ mailq
```
```text
-Queue ID- --Size-- ----Arrival Time---- -Sender/Recipient-------
4Sy3kL09zZz10A    1420 Thu Aug  6 10:15:02  deployer@example.com
(connect to mail.remote-domain.org[203.0.113.50]:25: Connection refused)
                                         recipient@remote-domain.org

4Sy3mN42xYz10B    2048 Thu Aug  6 10:18:44  alert@example.com
                                         oncall@example.com

-- 3 Kbytes in 2 Requests.
```

#### Flushing the Queue (Forcing Immediate Delivery Attempt):
```bash
$ sudo postqueue -f
```

#### Deleting a Specific Message from Queue by Queue ID:
```bash
$ sudo postsuper -d 4Sy3kL09zZz10A
```
```text
postsuper: 4Sy3kL09zZz10A: removed
```

#### Purging All Deferred Messages from the Queue:
```bash
$ sudo postsuper -d ALL deferred
```
```text
postsuper: Deleted: 1 message
```

---

### 4.3 Interactive Low-Level Protocol Verification

#### Testing SMTP MSA (Port 587) with STARTTLS & Plain SASL Base64 Authentication
```bash
$ openssl s_client -connect mx1.example.com:587 -starttls smtp -crlf
```
```text
CONNECTED(00000003)
---
Certificate chain
 0 s:CN = mx1.example.com
   i:C = US, O = Let's Encrypt, CN = R3
---
220 mx1.example.com ESMTP Postfix
EHLO client.example.com
250-mx1.example.com
250-PIPELINING
250-SIZE 104857600
250-VRFY
250-ETRN
250-AUTH PLAIN LOGIN
250-ENHANCEDSTATUSCODES
250-8BITMIME
250 DSN
AUTH PLAIN dXNlcjAxQGV4YW1wbGUuY29tAHVzZXIwMUBleGFtcGxlLmNvbQBTZWNyZXRQYXNzMTIzIQ==
235 2.7.0 Authentication successful
MAIL FROM:<user01@example.com>
250 2.1.0 Ok
RCPT TO:<admin@example.com>
250 2.1.5 Ok
DATA
354 End data with <CR><LF>.<CR><LF>
Subject: Production System Test

Testing Postfix SMTP submission pipeline.
.
250 2.0.0 Ok: queued as 4Sy4bM11xZz10C
QUIT
221 2.0.0 Bye
closed
```

#### Testing Dovecot IMAP over SSL (Port 993) via `openssl s_client`
```bash
$ openssl s_client -connect mx1.example.com:993 -crlf
```
```text
CONNECTED(00000003)
* OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.
A01 LOGIN user01@example.com SecretPass123!
A01 OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ SPECIAL-USE] Logged in
A02 SELECT INBOX
* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)
* OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)] Flags permitted.
* 1 EXISTS
* 0 RECENT
* OK [UNSEEN 1] First unseen.
* OK [UIDVALIDITY 1691234567] UIDs valid
* OK [UIDNEXT 2] Predicted next UID
A02 OK [READ-WRITE] Select completed (0.001 secs).
A03 FETCH 1 BODY[TEXT]
* 1 FETCH (BODY[TEXT] {43}
Testing Postfix SMTP submission pipeline.
)
A03 OK Fetch completed (0.001 secs).
A04 LOGOUT
* BYE Logging out
A04 OK Logout completed.
closed
```

#### Testing Dovecot `doveadm` CLI Diagnostics
```bash
$ sudo doveadm user "user01@example.com"
```
```text
field   value
uid     5000
gid     5000
home    /var/vmail/example.com/user01
mail    maildir:/var/vmail/example.com/user01/Maildir
```

```bash
$ sudo doveadm mailbox status -u user01@example.com all INBOX
```
```text
mailbox messages unseen recent messages.mailbox uidnext uidvalidity
INBOX   1        1      0      1                2       1691234567
```

---

## 5. Verification & Fault Diagnostic Playbook

### 5.1 Diagnostic Flowchart

```
                 [Mail Delivery Issue Reported]
                               |
                               v
                     Inspect Mail Logs:
          /var/log/mail.log or journalctl -u postfix
                               |
            +------------------+------------------+
            |                                     |
    (SMTP Connect Error)                 (SASL / TLS Failure)
            |                                     |
            v                                     v
 1. Check Listening Ports:            1. Verify Certificate Validity:
    `ss -tulpn | grep -E ':25|:587'`     `openssl x509 -in cert.pem -text`
 2. Verify Firewall/Security:        2. Check Dovecot Socket Perms:
    `nft list ruleset`                  `ls -la /var/spool/postfix/private/auth`
 3. Test HELO/EHLO explicitly.        3. Test SASL via `testsaslauthd`.
            |                                     |
            +------------------+------------------+
                               |
                               v
                     (LMTP / MDA Delivery Error)
                               |
                               v
                    1. Check Dovecot LMTP Socket:
                       `ls -la /var/spool/postfix/private/dovecot-lmtp`
                    2. Check Maildir Ownership:
                       `chown -R vmail:vmail /var/vmail`
                    3. Validate Sieve Compiler Syntax:
                       `sievec /path/to/script.sieve`
```

---

### 5.2 Failure Scenarios & Targeted Remediation

#### Scenario 1: Open Relay Attempt Rejected (454 / 554 Relay Access Denied)
* **Log Pattern (`/var/log/mail.log`):**
  ```text
  postfix/smtpd[14210]: NOQUEUE: reject: RCPT from unknown[198.51.100.44]: 554 5.7.1 <victim@external.org>: Relay access denied; from=<spammer@external.org> proto=ESMTP helo=<badactor.com>
  ```
* **Root Cause:** External host attempted to relay email through port 25 without matching `mynetworks` or providing valid SASL credentials.
* **Verification Command:**
  ```bash
  $ postconf -d smtpd_relay_restrictions
  ```
* **Remediation:** Ensure `smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination` is explicitly set in `main.cf`.

#### Scenario 2: Dovecot LMTP Permission Denied (`connect to private/dovecot-lmtp failed`)
* **Log Pattern (`/var/log/mail.log`):**
  ```text
  postfix/lmtp[14533]: 4Sy4yN11xZz10D: to=<user01@example.com>, relay=none, delay=0.03, delays=0.01/0.01/0.01/0, status=deferred (cannot connect to private/dovecot-lmtp: Permission denied)
  ```
* **Root Cause:** The Postfix `lmtp` process running under user `postfix` cannot access the Unix domain socket `/var/spool/postfix/private/dovecot-lmtp`.
* **Diagnostic Check:**
  ```bash
  $ ls -la /var/spool/postfix/private/dovecot-lmtp
  ```
  *Output:* `srwxrwxrwx 1 root root 0 Aug 6 10:00 /var/spool/postfix/private/dovecot-lmtp` (Wrong ownership).
* **Remediation:** Update `/etc/dovecot/conf.d/10-master.conf`:
  ```ini
  service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
      mode = 0660
      user = postfix
      group = postfix
    }
  }
  ```
  Then reload Dovecot: `sudo systemctl reload dovecot`.

#### Scenario 3: SASL Authentication Failure (`SASL authentication failed: invalid parameter`)
* **Log Pattern (`/var/log/mail.log`):**
  ```text
  postfix/smtpd[14890]: warning: SASL authentication failure: cannot connect to Dovecot authentication socket /var/spool/postfix/private/auth: No such file or directory
  postfix/smtpd[14890]: warning: client.example.com[192.0.2.15]: SASL PLAIN authentication failed: generic failure
  ```
* **Root Cause:** Postfix `main.cf` points `smtpd_sasl_path` to `private/auth`, but Dovecot authentication socket listener is disabled or path is mismatched.
* **Remediation:** Ensure socket path in `/etc/dovecot/conf.d/10-master.conf` under `service auth` matches Postfix chroot jail relative path:
  ```ini
  service auth {
    unix_listener /var/spool/postfix/private/auth {
      mode = 0660
      user = postfix
      group = postfix
    }
  }
  ```

#### Scenario 4: Maildir Inode/Permission Lockdown (`Permission denied` on delivery)
* **Log Pattern (`/var/log/mail.log`):**
  ```text
  dovecot: lmtp(15102): Error: maildir_storage: open(/var/vmail/example.com/user01/Maildir/tmp/16912345.M123P15102.mx1) failed: Permission denied (euid=5000(vmail) egid=5000(vmail) missing +w perm on /var/vmail/example.com/user01/Maildir/tmp)
  ```
* **Root Cause:** Directory structure `/var/vmail/` was created by root or another user, preventing `vmail` (UID 5000) from writing new message files.
* **Remediation Command:**
  ```bash
  $ sudo chown -R 5000:5000 /var/vmail
  $ sudo chmod -R 770 /var/vmail
  ```

---

## 6. References

* **LPI Official LPIC-2 Objectives v4.5:**  
  [https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5](https://wiki.lpi.org/wiki/LPIC-2_Objectives_V4.5)

* **Postfix Configuration Parameters & Documentation:**  
  [https://www.postfix.org/postconf.5.html](https://www.postfix.org/postconf.5.html)

* **Postfix SASL Readme & Dovecot Integration:**  
  [https://www.postfix.org/SASL_README.html](https://www.postfix.org/SASL_README.html)

* **Dovecot v2.3 Core Documentation:**  
  [https://doc.dovecot.org/](https://doc.dovecot.org/)

* **Pigeonhole Sieve for Dovecot:**  
  [https://doc.dovecot.org/configuration_manual/sieve/](https://doc.dovecot.org/configuration_manual/sieve/)

* **RFC 5321 - Simple Mail Transfer Protocol (SMTP):**  
  [https://datatracker.ietf.org/doc/html/rfc5321](https://datatracker.ietf.org/doc/html/rfc5321)

* **RFC 7208 - Sender Policy Framework (SPF):**  
  [https://datatracker.ietf.org/doc/html/rfc7208](https://datatracker.ietf.org/doc/html/rfc7208)

* **RFC 6376 - DomainKeys Identified Mail (DKIM) Signatures:**  
  [https://datatracker.ietf.org/doc/html/rfc6376](https://datatracker.ietf.org/doc/html/rfc6376)

* **RFC 7489 - Domain-based Message Authentication, Reporting, and Conformance (DMARC):**  
  [https://datatracker.ietf.org/doc/html/rfc7489](https://datatracker.ietf.org/doc/html/rfc7489)