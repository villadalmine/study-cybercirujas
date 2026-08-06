# LPIC-2 (Exams 201-450 & 202-450, v4.5) — Topic 2.5: E-Mail Services

**Exam Weight:** 9 (Topic 211 in v4.5: 211.1 Using E-Mail Servers [Weight 4], 211.2 Managing E-Mail Delivery [Weight 2], 211.3 Managing Mailbox Access [Weight 2])  
**Target Audience:** SREs, Systems Architects, and Infrastructure Engineers managing enterprise Mail Transfer Agents (MTA) and Mail Delivery Agents (MDA).

---

## Technical Overview & Architectural Foundations

Enterprise email infrastructure requires a clear separation between **Mail Transfer Agents (MTAs)** (e.g., Postfix), **Mail Delivery Agents (MDAs)** (e.g., Dovecot LDA/LMTP), and **Mail Access Protocols** (IMAP/POP3).

```
 +-----------------------------------------------------------------------------------+
 |                                   POSTFIX MTA                                     |
 |                                                                                   |
 |  [ Network ] ---> ( smtpd ) ---> [ cleanup ] ---> [ incoming queue ]              |
 |                                                       |                           |
 |                                                       v                           |
 |                                                [ qmgr queue ] <---> ( trivial-    |
 |                                                       |              rewrite )    |
 |                                                       v                           |
 |                                             +------------------+                  |
 |                                             | Router / Delivery|                  |
 |                                             +------------------+                  |
 |                                               /              \                    |
 |                                              /                \                   |
 |                                             v                  v                  |
 |                                    ( smtp client )        ( local / lmtp )        |
 +-------------------------------------------|----------------------|----------------+
                                             |                      |
                                             v                      v
                                      [ Remote MTA ]       [ Dovecot MDA / LMTP ]
                                                                    |
                                                                    v
                                                             [ Maildir/Storage ]
                                                                    ^
                                                                    |
                                                           ( dovecot imap/pop3 )
                                                                    ^
                                                                    |
                                                           [ TLS 993/995 / MUA ]
```

### Postfix Architecture & Queue Lifecycle
1. **`smtpd`**: Receives incoming SMTP connections, enforces TLS, SASL, HELO/EHLO checks, and client access restrictions.
2. **`cleanup`**: Normalizes headers, adds missing `Message-Id` or `Date` headers, transforms addresses, and writes messages into the `incoming` queue directory (`/var/spool/postfix/incoming`).
3. **`qmgr` (Queue Manager)**: The central dispatcher. It moves messages between queues (`incoming`, `active`, `deferred`, `hold`, `corrupt`) and schedules delivery attempts without blocking execution threads.
4. **`trivial-rewrite`**: Resolves destination addresses against lookup tables (`transport`, `virtual_alias_maps`, `virtual_mailbox_maps`) to determine if the mail is intended for local storage, virtual hosting, or remote relay.
5. **Delivery Daemons**:
   - **`smtp`**: Outbound client sending mail to external domains via MX records or relayhosts.
   - **`local`**: Delivers mail to traditional UNIX system accounts, `/etc/aliases`, and `.forward` files.
   - **`virtual`**: Delivers mail to non-UNIX virtual user mailboxes.
   - **`pipe`**: Hands off messages to external programs (e.g., legacy MDA scripts or spam scanners).
   - **`lmtp`**: Connects via Local Mail Transport Protocol to Dovecot for mailbox storage and Sieve script execution.

---

## Exercise 1: MTA Configuration, Virtual Domains & Secure Relay

### Objective
Configure a production-grade Postfix MTA supporting virtual domains, TLS 1.2/1.3 encryption, SASL authentication via Dovecot, and transport map overrides.

### Step 1: Inspect and Configure `main.cf`
1. Execute the following command to review active, non-default Postfix configuration parameters:
   ```bash
   postconf -n
   ```
2. Edit `/etc/postfix/main.cf` to implement the following syntactically valid production manifest:
   ```ini
   # /etc/postfix/main.cf - Production Core Configuration
   
   # Server Identification & Network Interfaces
   myhostname = mail.prod.infra.net
   mydomain = prod.infra.net
   myorigin = $mydomain
   inet_interfaces = all
   inet_protocols = ipv4, ipv6
   mydestination = $myhostname, localhost.$mydomain, localhost
   
   # TLS Configuration (Inbound and Outbound)
   smtpd_tls_security_level = may
   smtpd_tls_cert_file = /etc/letsencrypt/live/mail.prod.infra.net/fullchain.pem
   smtpd_tls_key_file = /etc/letsencrypt/live/mail.prod.infra.net/privkey.pem
   smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
   smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
   smtp_tls_security_level = encrypt
   smtp_tls_loglevel = 1
   
   # SASL Authentication (via Dovecot UNIX Socket)
   smtpd_sasl_type = dovecot
   smtpd_sasl_path = private/auth
   smtpd_sasl_auth_enable = yes
   smtpd_sasl_security_options = noanonymous
   smtpd_sasl_tls_security_options = $smtpd_sasl_security_options
   
   # Access Restrictions (Relay & Anti-Spam Pipeline)
   smtpd_helo_required = yes
   smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
   smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination, reject_rbl_client zen.spamhaus.org
   
   # Virtual Domain & Maildir Delivery Options
   virtual_mailbox_domains = hash:/etc/postfix/virtual_domains
   virtual_alias_maps = hash:/etc/postfix/virtual_aliases
   virtual_transport = lmtp:unix:private/dovecot-lmtp
   
   # Routing Overrides
   transport_maps = hash:/etc/postfix/transport
   ```

### Step 2: Configure Virtual Domains, Aliases, and Transport Maps
1. Create `/etc/postfix/virtual_domains`:
   ```text
   example.com         OK
   cloud-ops.org       OK
   ```
2. Create `/etc/postfix/virtual_aliases`:
   ```text
   postmaster@example.com      admin@prod.infra.net
   devops@example.com          alice@example.com, bob@example.com
   info@cloud-ops.org          support@prod.infra.net
   ```
3. Create `/etc/postfix/transport` to force specific routing (e.g., routing internal legacy traffic via a dedicated internal gateway):
   ```text
   internal.legacy.net         smtp:[10.240.0.50]:25
   ```
4. Compile the lookup tables into indexed Berkley DB (`.db`) files using `postmap`:
   ```bash
   sudo postmap /etc/postfix/virtual_domains
   sudo postmap /etc/postfix/virtual_aliases
   sudo postmap /etc/postfix/transport
   sudo newaliases
   ```
5. Reload Postfix to apply all changes:
   ```bash
   sudo postfix reload
   ```

### Step 3: Validate MTA Operations via CLI
1. Verify database generation:
   ```bash
   ls -l /etc/postfix/*.db
   ```
   *Expected Output:*
   ```text
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/transport.db
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/virtual_aliases.db
   -rw-r--r-- 1 root root 12288 Aug  6 10:00 /etc/postfix/virtual_domains.db
   ```

2. Test destination address resolving using `postmap -q`:
   ```bash
   postmap -q "devops@example.com" hash:/etc/postfix/virtual_aliases
   ```
   *Expected Output:*
   ```text
   alice@example.com, bob@example.com
   ```

---

### Verification Questions — Exercise 1

#### Question 1.1
What is the precise architectural risk of setting `smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated` *without* including `reject_unauth_destination` at the end of the evaluation chain?

#### Question 1.2
How does Postfix's `cleanup` daemon handle incoming messages compared to `qmgr`? What happens if `cleanup` crashes while receiving a message from `smtpd`?

---

## Exercise 2: Queue Management, Operational Troubleshooting & Advanced MTA Diagnostics

### Objective
Master Postfix queue structure inspection, message manipulation, queue clearing, and low-level log tracing using native utilities (`postqueue`, `postsuper`, `postcat`).

```
 Queue Lifecycle Path:
 [ incoming ] ---> [ active ] ---> [ deferred ] (Retries via exponential backoff)
                       |                  |
                       v                  v
                   (Delivered)     [ hold ] (Manual Admin Intervention)
```

### Step 1: Inspect Queue Status and Structure
1. List all messages currently queued across `active`, `incoming`, and `deferred` mail spool directories:
   ```bash
   postqueue -p
   ```
   *Expected Output:*
   ```text
   -Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
   4Vxy9L12zZz*    1420 Thu Aug  6 09:12:01  bounce-service@cloud-ops.org
                                            unreachable-user@external-partner.com

   4VxyDF56xYy     2851 Thu Aug  6 09:30:44  alert@prod.infra.net
   (connect to mail.external-partner.com[198.51.100.25]:25: Connection timed out)
                                            sysadmin@external-partner.com

   -- 4 Kbytes in 2 Requests.
   ```
   *(Note: Queue ID followed by `*` indicates the message is currently in the `active` queue; queue ID followed by `!` indicates the message is on `hold`.)*

### Step 2: Deep Inspection of Queue Files via `postcat`
1. Inspect the envelope metadata, message headers, and raw body of queue ID `4VxyDF56xYy`:
   ```bash
   sudo postcat -q 4VxyDF56xYy
   ```
   *Expected Output snippet:*
   ```text
   *** QUEUE FILE HEADER ***
   rec_type: V  min_attr: 0
   sender: alert@prod.infra.net
   recipient: sysadmin@external-partner.com
   *** HEADER EXTRACTED FROM MESSAGE FILE ***
   Subject: CRITICAL: High CPU Utilization on node-04
   From: alert@prod.infra.net
   To: sysadmin@external-partner.com
   Date: Thu, 06 Aug 2026 09:30:44 -0400
   *** MESSAGE CONTENTS ***
   Node node-04 exceeded 95% CPU threshold for 15 consecutive minutes.
   *** MESSAGE FILE END ***
   ```
2. To extract *only* the envelope records (sender, recipient, client IP) for automated audit scripts:
   ```bash
   sudo postcat -q -e 4VxyDF56xYy
   ```

### Step 3: Manipulating Queue State via `postsuper`
1. Place a stuck or suspicious queue item on `hold` to halt delivery attempts:
   ```bash
   sudo postsuper -h 4VxyDF56xYy
   ```
   *Expected Output:*
   ```text
   postsuper: 4VxyDF56xYy: placed on hold
   ```

2. Release a held message back to the `incoming` queue for re-evaluation:
   ```bash
   sudo postsuper -H 4VxyDF56xYy
   ```
   *Expected Output:*
   ```text
   postsuper: 4VxyDF56xYy: released from hold
   ```

3. Force immediate requeuing (re-parsing headers and transport maps):
   ```bash
   sudo postsuper -r 4VxyDF56xYy
   ```
   *Expected Output:*
   ```text
   postsuper: 4VxyDF56xYy: requeued
   ```

4. Force a queue flush attempt across all deferred messages:
   ```bash
   sudo postqueue -f
   ```

5. Delete a specific message from the queue permanently:
   ```bash
   sudo postsuper -d 4VxyDF56xYy
   ```
   *Expected Output:*
   ```text
   postsuper: 4VxyDF56xYy: removed
   ```

6. *Production Guardrail:* Delete ALL deferred messages safely using `postsuper` and standard Unix pipelines:
   ```bash
   sudo postsuper -d ALL deferred
   ```

---

### Verification Questions — Exercise 2

#### Question 2.1
What is the functional difference between `postqueue -f` (flush queue) and `postsuper -r ALL` (requeue all messages)? When would an SRE choose one over the other during an outage?

#### Question 2.2
An email sent to `user@remote.org` remains stuck in the `deferred` queue with the error code `451 4.4.0 DNS query failed`. What diagnostic command sequence should you run to verify whether the issue originates from local DNS resolution, transport map misconfigurations, or remote network filtering?

---

## Exercise 3: Local & Remote Mail Delivery (MDA, Dovecot, Sieve & Security)

### Objective
Configure Dovecot for secure mailbox delivery (IMAPS/LMTP), enforce quotas, map Dovecot SASL to Postfix, and deploy automated user-side filtering using Sieve scripts.

### Step 1: Configure Dovecot LMTP & Storage Engine
1. Edit `/etc/dovecot/dovecot.conf` to enable required protocols:
   ```ini
   # /etc/dovecot/dovecot.conf
   protocols = imap lmtp pop3
   listen = *, ::
   dict {
     # Dictionary bindings if using SQL quotas
   }
   !include conf.d/*.conf
   ```

2. Configure Maildir layout and storage paths in `/etc/dovecot/conf.d/10-mail.conf`:
   ```ini
   mail_location = maildir:/var/vmail/%d/%n/Maildir
   mail_uid = 5000
   mail_gid = 5000
   first_valid_uid = 5000
   last_valid_uid = 5000
   ```

3. Configure authentication socket sharing in `/etc/dovecot/conf.d/10-master.conf` so Postfix can authenticate users via Dovecot SASL, and send mail directly via LMTP:
   ```ini
   service lmtp {
     unix_listener /var/spool/postfix/private/dovecot-lmtp {
       mode = 0600
       user = postfix
       group = postfix
     }
   }

   service auth {
     unix_listener /var/spool/postfix/private/auth {
       mode = 0660
       user = postfix
       group = postfix
     }
   }
   ```

4. Enforce strict TLS configuration in `/etc/dovecot/conf.d/10-ssl.conf`:
   ```ini
   ssl = required
   ssl_cert = </etc/letsencrypt/live/mail.prod.infra.net/fullchain.pem
   ssl_key = </etc/letsencrypt/live/mail.prod.infra.net/privkey.pem
   ssl_min_protocol = TLSv1.2
   ssl_cipher_list = PROFILE=SYSTEM
   ```

### Step 2: Implement Sieve Filtering Rules
1. Ensure the Dovecot Pigeonhole Sieve plugin is active in `/etc/dovecot/conf.d/20-lmtp.conf`:
   ```ini
   protocol lmtp {
     mail_plugins = $mail_plugins sieve
   }
   ```

2. Create a user Sieve filter at `/var/vmail/example.com/alice/default.sieve`:
   ```sieve
   require ["fileinto", "mailbox", "subaddress"];

   # Rule 1: Redirect Automated Alerts
   if header :contains "Subject" ["CRITICAL", "ALERT", "FATAL"] {
     fileinto :create "INBOX.Alerts";
     stop;
   }

   # Rule 2: Move Marketing / Newsletters
   if header :contains "List-Unsubscribe" "http" {
     fileinto :create "INBOX.Newsletters";
     stop;
   }

   # Default Rule: Keep in Inbox
   keep;
   ```

3. Compile the Sieve script into binary bytecode format (`.svbin`):
   ```bash
   sudo sievec /var/vmail/example.com/alice/default.sieve
   ```
4. Check directory contents for the generated bytecode:
   ```bash
   ls -la /var/vmail/example.com/alice/default.svbin
   ```
   *Expected Output:*
   ```text
   -rw-r--r-- 1 vmail vmail 482 Aug  6 10:15 /var/vmail/example.com/alice/default.svbin
   ```

### Step 3: Validate Dovecot Authentication and IMAP/LMTP Operations
1. Reload Dovecot:
   ```bash
   sudo systemctl restart dovecot
   ```

2. Validate local user authentication through `doveadm`:
   ```bash
   sudo doveadm auth test alice@example.com SecretPassword123
   ```
   *Expected Output:*
   ```text
   passdb: alice@example.com auth succeeded
   extra fields:
     user=alice@example.com
   ```

3. Test secure IMAPS connection on TCP port 993 using `openssl s_client`:
   ```bash
   openssl s_client -connect mail.prod.infra.net:993 -crlf
   ```
   *Expected Server Response:*
   ```text
   CONNECTED(00000003)
   depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
   ...
   * OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.
   ```
4. Authenticate manually via IMAP command state:
   ```text
   A01 LOGIN alice@example.com SecretPassword123
   A02 LIST "" "*"
   A03 LOGOUT
   ```
   *Expected Server Response:*
   ```text
   A01 OK [/CAPABILITY ...] Logged in
   * LIST (\HasNoChildren) "." INBOX
   * LIST (\HasNoChildren) "." INBOX.Alerts
   A02 OK List completed (0.001 secs).
   * BYE Logging out
   A03 OK Logout completed.
   ```

---

### Verification Questions — Exercise 3

#### Question 3.1
Why is LMTP (`lmtp:unix:private/dovecot-lmtp`) preferred over traditional MDA local pipe scripts (`pipe` or direct file append) in high-throughput enterprise mail systems?

#### Question 3.2
If a user modifies their `.sieve` file directly via SSH without compiling it with `sievec`, how does Dovecot react upon receiving a message via LMTP? What is the failure state handling?

---

## Official Reference Links & Documentation

- **LPIC-2 Exam Overview & Objectives**: [https://www.lpi.org/our-certifications/lpic-2-overview/](https://www.lpi.org/our-certifications/lpic-2-overview/)
- **Postfix Official Documentation & Architecture**: [http://www.postfix.org/documentation.html](http://www.postfix.org/documentation.html)
- **Postfix Queue Management Architecture**: [http://www.postfix.org/QSHAPE_README.html](http://www.postfix.org/QSHAPE_README.html)
- **Dovecot Core Administration Manual**: [https://doc.dovecot.org/](https://doc.dovecot.org/)
- **Pigeonhole Sieve Documentation**: [https://doc.dovecot.org/configuration_manual/sieve/](https://doc.dovecot.org/configuration_manual/sieve/)

---

<details>
<summary>Answers & Deep-Dive Explanations</summary>

### Exercise 1 Solutions

#### Question 1.1 Answer
**Explanation:** If `reject_unauth_destination` is omitted from `smtpd_relay_restrictions` (or `smtpd_recipient_restrictions`), Postfix defaults to accepting all destination addresses. Unless restrictive custom logic is implemented elsewhere, the server becomes an **Open Relay**. Malicious external clients can connect to port 25 and send outbound spam to any external recipient domain worldwide. This results in the server IP address being immediately blacklisted by RBL databases (e.g., Spamhaus, Barracuda). Including `reject_unauth_destination` ensures that Postfix rejects any recipient domain that is NOT defined in `$mydestination`, `$virtual_alias_domains`, or `$virtual_mailbox_domains`, unless the client is authenticated via trusted netblocks (`permit_mynetworks`) or SASL (`permit_sasl_authenticated`).

#### Question 1.2 Answer
**Explanation:** The `cleanup` daemon acts as the intermediate processing layer between inbound interface daemons (`smtpd`, `pickup`) and the queue structure. `cleanup` normalizes envelope structure, inserts missing standard header fields (`Message-Id`, `Date`), executes address rewriting (`canonical`, `masquerade_domains`), and evaluates header/body checks (`header_checks`). Once structured, `cleanup` writes the message to the `incoming` directory and notifies `qmgr`. 

If `cleanup` crashes during transmission, the `smtpd` daemon receives an abnormal pipe termination error, returns an SMTP `421 4.3.0 Local server error` code to the sending MUA/MTA, and closes the socket connection. The partial, uncommitted file in `/var/spool/postfix/incoming` is discarded or moved to `/var/spool/postfix/corrupt` during recovery sweep tasks. `qmgr` is never notified of incomplete queue writes, preventing partial or corrupted messages from entering the mail delivery flow.

---

### Exercise 2 Solutions

#### Question 2.1 Answer
- **`postqueue -f` (Flush Queue):** Requests `qmgr` to immediately schedule delivery attempts for all messages currently sitting in the `deferred` queue. It does **not** re-parse configurations or alter message files; it simply overrides the backoff timer schedule.
- **`postsuper -r ALL` (Requeue All):** Forces messages out of their existing queue state and moves them back into the `incoming` queue. Every message envelope is completely re-evaluated by the `cleanup` daemon. 

**SRE Operational Context:** 
- An SRE uses `postqueue -f` after resolving a network connection failure (e.g., an upstream firewall rule was fixed, or an ISP outage ended) to quickly drain the backlog without altering envelope structures.
- An SRE uses `postsuper -r` when configuration logic, virtual alias maps, or transport routing rules were updated *after* messages became stuck. A queue flush alone (`postqueue -f`) would attempt delivery using cached route metadata; requeuing (`postsuper -r`) forces Postfix to apply the newly updated routing rules and lookup table maps to all queued mail.

#### Question 2.2 Answer
**Diagnostic Command Workflow:**
1. **Verify Local DNS Resolution:** Test MX and A record resolution directly using system utilities:
   ```bash
   dig +short MX remote.org
   dig +short A mail.remote.org
   ```
2. **Verify Transport Table Routing:** Confirm Postfix lookup rules are not forcing invalid transport overrides:
   ```bash
   postmap -q "remote.org" hash:/etc/postfix/transport
   ```
3. **Trace Socket Level Connectivity & TLS Negotiation:** Test outbound TCP connectivity to port 25/587 of the destination MX server:
   ```bash
   nc -zv mail.remote.org 25
   openssl s_client -connect mail.remote.org:25 -starttls smtp
   ```
4. **Examine Operational Logs:** Tail system logs during a manual queue flush of the specific queue ID:
   ```bash
   sudo postqueue -i <QUEUE_ID>
   sudo journalctl -u postfix -n 50 --no-pager
   ```

---

### Exercise 3 Solutions

#### Question 3.1 Answer
**Explanation:** 
- **Pipe / Script MDAs:** Traditional delivery mechanics involve `local` or `pipe` daemons spawning a new process (e.g., `/usr/bin/procmail` or Dovecot LDA binary `/usr/libexec/dovecot/dovecot-lmtp`) per incoming email. This process fork/exec overhead causes high CPU consumption, memory thrashing, and process exhaustion under high mail volumes.
- **LMTP (Local Mail Transport Protocol):** LMTP runs as a long-lived daemon service listening on a persistent UNIX domain socket or TCP port. Postfix maintains persistent socket connections directly to Dovecot's LMTP worker pool. This eliminates process creation overhead, delivers structured 2xx/4xx/5xx SMTP-style protocol responses directly to Postfix, allows instant transaction rollbacks, and safely handles multi-recipient deliveries within a single transmission session.

#### Question 3.2 Answer
**Explanation:** Dovecot Pigeonhole checks file timestamps between the source `.sieve` file and the compiled `.svbin` bytecode file. 
1. If `.sieve` is modified manually and its timestamp is newer than `.svbin` (or if `.svbin` does not exist), Dovecot automatically re-compiles the `.sieve` file on-the-fly during the LMTP delivery transaction.
2. If the `.sieve` script contains syntax errors, automatic compilation fails. Dovecot logs the exact line syntax error to `/var/log/dovecot.log` (or `journalctl`), falls back to executing the default global fallback Sieve script (if defined in `sieve_default`), and delivers the message directly to the user's standard `INBOX` without dropping or bouncing the mail.

</details>