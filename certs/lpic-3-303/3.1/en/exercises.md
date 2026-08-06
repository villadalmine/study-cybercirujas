# LPIC-3 Exam 303-300 (v3.0) — Topic 3.1: Application Security

**Exam Weight:** 16.66 (Approx. 10 questions)  
**Target Role:** Enterprise Linux Security Architect / Senior SRE  
**Primary Reference:** [Linux Professional Institute: LPIC-3 303 Exam Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)

---

## Architectural Principles & Mechanics of Application Security

Application Security in enterprise Linux environments operates on a **Defense-in-Depth** model across the OSI model (primarily Layers 4 through 7) and system kernel boundaries. Securing modern application workloads requires enforcing security constraints across five critical boundaries:

```
                          +---------------------------------------------------+
                          |                 UNTRUSTED NETWORK                 |
                          +---------------------------------------------------+
                                                    |
                                                    v [Layer 7: TLS 1.3 / mTLS]
                          +---------------------------------------------------+
                          |      Edge Reverse Proxy (Nginx / Apache)          |
                          |   - TLS Termination & HSTS                        |
                          |   - Security Headers (CSP, CORS, X-Frame)         |
                          +---------------------------------------------------+
                                                    |
                                                    v [Layer 7: Inspection]
                          +---------------------------------------------------+
                          |  Web Application Firewall (ModSecurity v3 + CRS)  |
                          |   - Protocol Anomaly Detection                    |
                          |   - SQLi / XSS / RCE Signature Inspection         |
                          +---------------------------------------------------+
                                                    |
                                                    v [IPC / Unix Socket]
                          +---------------------------------------------------+
                          |     Application Runtime Sandbox (systemd)         |
                          |   - Namespace Isolation (Mount, Network, PID)     |
                          |   - Linux Capabilities & CapabilityBoundingSet    |
                          |   - Syscall Filtering (seccomp-bpf)               |
                          +---------------------------------------------------+
                                    |                               |
                                    v [PAM / GSSAPI]                v [Encrypted TLS / Socket]
  +--------------------------------------------------+    +----------------------------------+
  | Application Auth Engine (Linux-PAM / pam_faillock) |    | Secure Database Engine (Postgres)|
  +--------------------------------------------------+    +----------------------------------+
```

1. **Transport Layer Hardening:** Standardizing on TLS 1.3 / TLS 1.2 with strict Ephemeral Diffie-Hellman cipher suites (`ECDHE-ECDSA-*` / `ECDHE-RSA-*`) to guarantee Perfect Forward Secrecy (PFS). Certificate validation relies on OCSP Stapling to eliminate third-party CA latency and privacy leakage during TLS handshakes.
2. **Web Application Firewall (WAF) Mechanics:** WAF engines (such as ModSecurity v3 / `libmodsecurity`) parse HTTP request pipelines prior to passing payloads to upstream application servers. Using rule sets like the OWASP Core Rule Set (CRS), requests are evaluated using **Anomaly Scoring Mode**, accumulating risk points per matching rule to reject high-risk attacks (`403 Forbidden`) while minimizing false positives.
3. **Kernel System Call & Privilege Sandboxing:** Service isolation moves beyond basic `chroot` jails. Modern SRE patterns utilize `seccomp-bpf` system call filtering alongside Linux Namespaces (Mount, PID, Network, IPC) and Capability Bounding Sets managed via `systemd`. Restricting an application's ability to execute `execve`, `ptrace`, or write to `/usr` limits payload impact even if remote code execution (RCE) occurs.
4. **Pluggable Authentication Modules (PAM) Architecture:** Applications offload identity verification, password quality checks, and brute-force mitigation to `/etc/pam.d/`. Using modules like `pam_faillock.so` and `pam_access.so`, systems enforce host-level authentication controls independently of the application's underlying language stack.
5. **Database Transport & Authentication Hardening:** Microservices must authenticate to database management systems using cryptographic identity (mTLS / SCRAM-SHA-256) over TLS-encrypted connections, combined with strict host-based control lists (`pg_hba.conf`).

---

## Technical Trade-offs & Production Impact

| Security Control | Operational Benefit | Performance / Operational Trade-off | Diagnostic Command |
| :--- | :--- | :--- | :--- |
| **Strict WAF Anomaly Scoring** | Blocks zero-day SQLi, XSS, and path traversal vulnerabilities. | Adds 1.5ms - 5ms request latency; high risk of blocking legitimate API traffic (false positives). | `tail -f /var/log/nginx/modsec_audit.log` |
| **systemd Syscall Filtering (`seccomp`)** | Prevents privilege escalation and kernel exploit execution. | Misconfigurations cause `SIGSYS` process termination; breaks dynamic library loads or sub-process spawns. | `journalctl -u app.service -e -g SIGSYS` |
| **HSTS Preload + Subdomains** | Eliminates SSL Stripping and MITM downgrade vectors. | Inflexible: Enforces HTTPS across *all* subdomains for up to 2 years; invalid certificates bring down all sites. | `curl -sI https://example.com \| grep -i strict-transport-security` |
| **PAM Account Lockout (`pam_faillock`)** | Mitigates online dictionary attacks and credential stuffing. | Risk of Denial of Service (DoS) where attackers lock out legitimate admin users by forging failed attempts. | `faillock --user admin_user` |
| **TLS Client Certificate Auth (mTLS)** | Zero-trust service-to-service authentication; immune to credential theft. | PKI lifecycle overhead: Certificate issuance, revocation CRL/OCSP management, and automated renewal complexity. | `openssl s_client -connect db.internal:5432 -cert client.crt -key client.key` |

---

## Guided Exercise 1: Enterprise Web Server Hardening & TLS 1.3 Enforcement

### Objectives
Configure a production-grade Nginx reverse proxy running with absolute TLS 1.3 / 1.2 restriction, HSTS preloading, security headers, dynamic OCSP stapling, and explicit protocol hardening according to [Mozilla SSL Configuration Guidelines](https://wiki.mozilla.org/Security/Server_Side_TLS).

### Step 1.1: Deploy Syntactically Valid Hardened TLS & Security Header Configuration
Create `/etc/nginx/conf.d/security_hardened.conf` to enforce strict cipher suites, disable vulnerable SSL/TLS protocols, and inject security headers.

```nginx
# /etc/nginx/conf.d/security_hardened.conf

# Hide Nginx version details in server tokens and error pages
server_tokens off;

# SSL Session Cache Configuration
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# Protocol & Cipher Suite Hardening (Intermediate / Modern Profile)
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# OCSP Stapling Settings
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name app.secure.internal;

    ssl_certificate /etc/ssl/certs/app_combined.crt;
    ssl_certificate_key /etc/ssl/private/app.key;
    ssl_trusted_certificate /etc/ssl/certs/ca_chain.crt;

    # HTTP Strict Transport Security (HSTS)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Defense-in-Depth Security Headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "0" always; # Disabled in favor of strict CSP
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Step 1.2: Validate and Test Nginx Configuration
Validate syntax and test TLS compliance using `openssl` and `curl`.

```bash
sudo nginx -t
```
*Expected Output:*
```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

Reload Nginx service:
```bash
sudo systemctl reload nginx
```

Verify TLS protocol enforcement via `openssl s_client`:
```bash
openssl s_client -connect localhost:443 -tls1_1
```
*Expected Output:*
```text
CONNECTED(00000003)
40579979310848:error:0A000102:SSL routines:ssl_choose_client_version:unsupported protocol:ssl/statem/statem_lib.c:1982:
---
no peer certificate available
---
Server public key is 0 bit
---
```

Verify security header injection via `curl`:
```bash
curl -Iv https://localhost/ --insecure
```
*Expected Output:*
```text
HTTP/2 200 
server: nginx
date: Thu, 06 Aug 2026 13:25:00 GMT
content-type: text/html
strict-transport-security: max-age=63072000; includeSubDomains; preload
x-frame-options: DENY
x-content-type-options: nosniff
referrer-policy: strict-origin-when-cross-origin
content-security-policy: default-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self';
permissions-policy: geolocation=(), microphone=(), camera=(), payment=()
```

---

### Verification Questions (Exercise 1)
1. **Why is `X-XSS-Protection` set to `"0"` rather than `"1; mode=block"` in modern security configurations?**
2. **What technical breakdown occurs if `ssl_stapling_verify on` is enabled without defining an explicit `ssl_trusted_certificate` or valid `resolver`?**

---

## Guided Exercise 2: WAF Deployment via ModSecurity v3 & OWASP Core Rule Set (CRS)

### Objectives
Integrate `libmodsecurity` (ModSecurity v3) into Nginx, load the OWASP Core Rule Set (v3.3/v4.0), configure **Anomaly Scoring Mode**, and craft rule exclusion overrides for API false positives. Reference: [OWASP ModSecurity Core Rule Set Documentation](https://coreruleset.org/docs/).

### Step 2.1: Enable ModSecurity in Nginx Main Configuration
Edit `/etc/nginx/nginx.conf` or main server context to load the ModSecurity module and enable execution.

```nginx
# /etc/nginx/nginx.conf snippet
user www-data;
worker_processes auto;
load_module modules/ngx_http_modsecurity_module.so;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Enable ModSecurity globally
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;

    include /etc/nginx/conf.d/*.conf;
}
```

### Step 2.2: Configure ModSecurity Main Rule Wrapper
Create `/etc/nginx/modsec/main.conf` to assemble core dependencies, unicode mappings, CRS rules, and custom exclusions.

```custom
# /etc/nginx/modsec/main.conf

# Include recommended ModSecurity engine configuration
include /etc/nginx/modsec/modsecurity.conf

# Include OWASP CRS setup parameters
include /etc/nginx/modsec/crs-setup.conf

# Include Custom Rule Exclusions (MUST be loaded BEFORE CRS rules to set variables/skip rules)
include /etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf

# Include OWASP CRS rule set rules
include /etc/nginx/modsec/owasp-crs/rules/*.conf

# Include Custom Post-CRS Rule Overrides
include /etc/nginx/modsec/rules/EXCLUSIONS-AFTER-CRS.conf
```

### Step 2.3: Configure Engine & Audit Logging
Ensure `/etc/nginx/modsec/modsecurity.conf` sets `SecRuleEngine` to active enforcement and configures relevant audit logging.

```custom
# /etc/nginx/modsec/modsecurity.conf directives
SecRuleEngine On
SecRequestBodyAccess On
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
SecResponseBodyAccess Off
SecResponseBodyMimeType text/html text/plain text/xml application/json

# Audit Log Configuration
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|(?:4(?!(?:04|03))))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsec_audit.log
```

### Step 2.4: Implement a Pre-CRS Exclusion Rule for API False Positives
Create `/etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf` to whitelist legitimate JSON payload triggers on `/api/v1/telemetry` for rule `942100` (SQL Injection detection).

```custom
# /etc/nginx/modsec/rules/EXCLUSIONS-BEFORE-CRS.conf

# Exclude Rule 942100 (SQLi Detection) for the 'payload' parameter on endpoint /api/v1/telemetry
SecRule REQUEST_URI "@beginsWith /api/v1/telemetry" \
    "id:100001,\
    phase:1,\
    pass,\
    nolog,\
    ctl:ruleRemoveTargetById=942100;ARGS:payload"
```

### Step 2.5: Test WAF Attack Mitigation and Inspect Audit Logs
Execute a simulated Cross-Site Scripting (XSS) attack payload against Nginx:

```bash
curl -i -s -k "https://localhost/?search=<script>alert('XSS')</script>"
```
*Expected Output:*
```text
HTTP/2 403 
server: nginx
date: Thu, 06 Aug 2026 13:27:00 GMT
content-type: text/html
content-length: 153

<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

Inspect `/var/log/nginx/modsec_audit.log` for rule trigger verification:
```bash
sudo tail -n 35 /var/log/nginx/modsec_audit.log
```
*Expected Log Excerpt:*
```text
---Message: Access denied with code 403 (phase 2). Operator GE matched 5 at TX:anomaly_score. [file "/etc/nginx/modsec/owasp-crs/rules/REQUEST-949-BLOCKING-EVALUATION.conf"] [line "80"] [id "949110"] [msg "Inbound Anomaly Score Exceeded (Total Score: 5)"]
---Message: Warning. Pattern match "(?i)<script" at ARGS:search. [file "/etc/nginx/modsec/owasp-crs/rules/REQUEST-941-APPLICATION-ATTACK-XSS.conf"] [line "68"] [id "941110"] [msg "XSS Filter - Category 1: Script Tag Vector"] [data "Matched Data: <script found within ARGS:search: <script>alert('XSS')</script>"] [severity "CRITICAL"]
```

---

### Verification Questions (Exercise 2)
1. **What is the structural difference between ModSecurity's "Self-Contained Mode" and "Anomaly Scoring Mode"?**
2. **Why must `ctl:ruleRemoveTargetById` be executed in `phase:1` inside `EXCLUSIONS-BEFORE-CRS.conf` instead of post-CRS inclusion?**

---

## Guided Exercise 3: Application Isolation via systemd Sandboxing & Linux Namespaces

### Objectives
Harden a vulnerable Node.js/Python backend service (`payment-processor.service`) using systemd process containment, namespace isolation, capability dropping, and `seccomp-bpf` system call filtering. Reference: [systemd.exec Security Directives](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).

### Step 3.1: Construct the Production Sandboxed Service Unit
Create `/etc/systemd/system/payment-processor.service` with strict isolation primitives.

```ini
[Unit]
Description=Payment Processor Microservice
After=network.target remote-fs.target
Documentation=https://docs.secure.internal/services/payment-processor

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/payment-processor
ExecStart=/usr/bin/node /var/www/payment-processor/server.js
Restart=on-failure
RestartSec=5s

# Process Execution Restrictions
NoNewPrivileges=true
PrivilegeEscalation=false
CapabilityBoundingSet=

# File System Isolation
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
MountAPIVFS=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=/var/log/payment-processor /tmp

# Kernel & Hardware Hardening
ProtectClock=true
ProtectKernelLogs=true
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true

# Network & System Call Filtering
ProtectHostname=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @mount @obsolete @raw-io @reboot @resources @swap

[Install]
WantedBy=multi-user.target
```

### Step 3.2: Reload, Launch, and Benchmark Security Score
Reload systemd units, enable, and launch the service:

```bash
sudo systemctl daemon-reload
sudo systemctl restart payment-processor.service
```

Run `systemd-analyze security` to verify security profile score reduction:

```bash
systemd-analyze security payment-processor.service
```
*Expected Output:*
```text
NAME                        PART OF                   EXPOSURE PREDICATE HAPPY SCORE
payment-processor.service   payment-processor.service OK       OK        OK    0.8 UNSAFE -> SAFE
```
*(Detailed output breakdown shows exposure score dropping from standard ~9.6 to < 1.0).*

### Step 3.3: Diagnose System Call Breaches
Verify system call violation behavior (`MemoryDenyWriteExecute` or blocked syscall execution). Triggering a restricted call (e.g., attempt to load kernel module or execute memory page modification) logs a kernel event:

```bash
sudo journalctl -u payment-processor.service -g "SIGSYS"
```
*Expected Log Output:*
```text
Aug 06 13:28:10 app-node-01 systemd[1]: payment-processor.service: Main process exited, code=killed, status=31/SYS
Aug 06 13:28:10 app-node-01 systemd[1]: payment-processor.service: Failed with result 'signal'.
Aug 06 13:28:10 app-node-01 kernel: audit: type=1326 audit(1786022890.124:94): auid=4294967295 uid=33 gid=33 ses=4294967295 pid=14205 comm="node" exe="/usr/bin/node" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f43b123a107 code=0x0
```

---

### Verification Questions (Exercise 3)
1. **How does `NoNewPrivileges=true` prevent an attacker who successfully drops a SUID root binary into `/tmp` from escalating privileges?**
2. **What functional break occurs in JIT-compiled runtimes (such as V8 in Node.js or JVM in Java) if `MemoryDenyWriteExecute=true` is applied without configuring appropriate runtime flags?**

---

## Guided Exercise 4: Enterprise Application Authentication via Linux-PAM

### Objectives
Configure system-wide application access authentication using Linux Pluggable Authentication Modules (PAM). Enforce account lockout brute-force defense with `pam_faillock.so` and network access control restrictions with `pam_access.so`. Reference: [Linux-PAM System Administrator's Guide](https://www.linux-pam.org/Linux-PAM-html/Linux-PAM_SAG.html).

### Step 4.1: Configure PAM Application Stack File
Create `/etc/pam.d/custom-app` to define the authentication sequence for an enterprise internal management application.

```pam
# /etc/pam.d/custom-app
# PAM configuration for Custom Enterprise Management Application

# Account Lockout Pre-check
auth      required                    pam_faillock.so preauth silent audit deny=3 unlock_time=900 fail_interval=300

# Host & Network Origin Access Control
auth      required                    pam_access.so accessfile=/etc/security/access-custom-app.conf

# Standard Unix Password Verification
auth      sufficient                  pam_unix.so nullok try_first_pass

# Account Lockout Failure Recording
auth      requisite                   pam_faillock.so authfail audit deny=3 unlock_time=900 fail_interval=300

# Catch-all Authentication Failure
auth      required                    pam_deny.so

# Account Management Controls
account   required                    pam_faillock.so
account   required                    pam_access.so
account   required                    pam_unix.so

# Session Setup Controls
session   required                    pam_limits.so
session   required                    pam_unix.so
```

### Step 4.2: Configure Network Access Policy Map
Create `/etc/security/access-custom-app.conf` to restrict access strictly to specified administrative subnets and users.

```custom
# /etc/security/access-custom-app.conf
# Format: permission : users : origins

# Allow local root and admin group
+ : root sec-ops : LOCAL

# Allow app-admins from internal management subnet 10.50.0.0/16
+ : app-admin : 10.50.0.0/16

# Deny all other users and origin networks
- : ALL : ALL
```

### Step 4.3: Simulate Brute-Force Lockout & Inspect State
Simulate authentication attempts using `pamtester` (a utility for testing PAM stacks):

```bash
pamtester custom-app invalid_user authenticate
```
*Expected Output:*
```text
pamtester: successfully authenticated user invalid_user
``` *(or failure if password fails)*.

Force 3 invalid authentication attempts for user `app-admin`:
```bash
for i in {1..3}; do pamtester custom-app app-admin authenticate; done
```

Inspect lockout status via `faillock`:
```bash
sudo faillock --user app-admin
```
*Expected Output:*
```text
app-admin:
When                Type  Source                          Valid
2026-08-06 13:29:01 R     127.0.0.1                       V
2026-08-06 13:29:03 R     127.0.0.1                       V
2026-08-06 13:29:05 R     127.0.0.1                       V
```

Clear account lockout state manually:
```bash
sudo faillock --user app-admin --reset
```

---

### Verification Questions (Exercise 4)
1. **Why must `pam_faillock.so` be called twice in the `auth` stack (`preauth` and `authfail`)?**
2. **What is the security risk of placing `pam_access.so` *below* `pam_unix.so` when `pam_unix.so` returns `sufficient`?**

---

## Guided Exercise 5: Database Application Security & Transport Encrypted Access

### Objectives
Harden a PostgreSQL database server to enforce mandatory client TLS (mTLS), require strong password hashing (`scram-sha-256`), and construct restrictive host-based authentication rules via `pg_hba.conf`. Reference: [PostgreSQL Secure TCP/IP Connections with SSL](https://www.postgresql.org/docs/current/ssl-tcp.html).

### Step 5.1: Configure PostgreSQL SSL/TLS Settings
Edit `/etc/postgresql/15/main/postgresql.conf` (adjust version path accordingly):

```ini
# /etc/postgresql/15/main/postgresql.conf snippet

# Connection Settings
listen_addresses = '10.50.10.15, 127.0.0.1'
port = 5432
max_connections = 100

# Transport Security (SSL/TLS)
ssl = on
ssl_ca_file = '/etc/ssl/certs/db_root_ca.crt'
ssl_cert_file = '/etc/ssl/certs/postgresql_server.crt'
ssl_key_file = '/etc/ssl/private/postgresql_server.key'
ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384'
ssl_prefer_server_ciphers = on
ssl_min_protocol_version = 'TLSv1.2'

# Authentication Hashing Algorithm
password_encryption = scram-sha-256
```

### Step 5.2: Configure Strict Host Authentication Map
Edit `/etc/postgresql/15/main/pg_hba.conf` to enforce mTLS for microservice database connections:

```custom
# /etc/postgresql/15/main/pg_hba.conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local Unix Domain Socket connections (local admin)
local   all             postgres                                peer

# Reject all unencrypted TCP connections
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject

# Enforce mTLS + SCRAM-SHA-256 for Payment App Subnet
hostssl payment_db      payment_user    10.50.20.0/24           scram-sha-256 clientcert=verify-full

# Enforce mTLS + Client Cert Verification for Analytics Subnet
hostssl analytics_db    analytics_user  10.50.30.0/24           scram-sha-256 clientcert=verify-full
```

### Step 5.3: Reload PostgreSQL & Validate Connection Enforcement
Reload PostgreSQL service:
```bash
sudo systemctl reload postgresql
```

Verify TLS connection requirements using `psql`:
Unencrypted attempt (should fail immediately):
```bash
psql "host=10.50.10.15 port=5432 dbname=payment_db user=payment_user sslmode=disable"
```
*Expected Output:*
```text
psql: error: connection to server at "10.50.10.15", port 5432 failed: FATAL:  no pg_hba.conf entry for host "10.50.20.5", user "payment_user", database "payment_db", no SSL
```

Valid mTLS connection attempt:
```bash
psql "host=10.50.10.15 port=5432 dbname=payment_db user=payment_user sslmode=verify-full sslcert=/etc/ssl/certs/payment_app.crt sslkey=/etc/ssl/private/payment_app.key sslrootcert=/etc/ssl/certs/db_root_ca.crt" -c "\conninfo"
```
*Expected Output:*
```text
You are connected to database "payment_db" as user "payment_user" on host "10.50.10.15" at port "5432".
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, bits: 256, compression: off)
```

---

### Verification Questions (Exercise 5)
1. **What is the cryptographic difference between `clientcert=verify-ca` and `clientcert=verify-full` in PostgreSQL's `pg_hba.conf`?**
2. **Why is `scram-sha-256` significantly more secure than `md5` for PostgreSQL authentication?**

---

<details>
<summary><strong>Click here to reveal the Solutions & Deep-Dive Explanations</strong></summary>

### Exercise 1 Answer Key & Technical Rationale

1. **`X-XSS-Protection: 0` vs `"1; mode=block"`:**
   * Modern browser security specifications explicitly advise disabling `X-XSS-Protection` (setting it to `0`). Legacy XSS auditors built into older browsers (like Chrome's XSS Auditor) had implementation flaws that could be abused by attackers to block legitimate scripts or leak cross-origin data (creating side-channel vulnerabilities).
   * Defense-in-depth modern architectures rely entirely on a robust **Content Security Policy (CSP)** (`Content-Security-Policy: default-src 'self'`) to eliminate reflected and stored XSS vectors cleanly.

2. **Impact of Missing `ssl_trusted_certificate` / `resolver` during OCSP Stapling Verification:**
   * When `ssl_stapling_verify on` is configured, Nginx must independently verify the cryptographic signature of the OCSP response received from the CA's OCSP responder.
   * If `ssl_trusted_certificate` (containing the CA root and intermediate chain) or a valid `resolver` (DNS server IP) is omitted, Nginx fails to validate the OCSP response signature or fails to contact the OCSP URL. This causes Nginx to drop OCSP stapling responses entirely (`OCSP response verification failed`), forcing clients to fall back to direct OCSP queries, introducing handshake latency and privacy degradation.

---

### Exercise 2 Answer Key & Technical Rationale

1. **Self-Contained Mode vs. Anomaly Scoring Mode:**
   * **Self-Contained Mode:** The WAF immediately executes a disruptive action (`403 Forbidden` / `500 Error`) on the very first rule match encountered during request inspection. This can lead to excessive false positives on complex payloads.
   * **Anomaly Scoring Mode (OWASP CRS Default):** Matching rules do not immediately interrupt execution. Instead, rules increment a transactional anomaly score variable (e.g., Critical = +5, Error = +4, Warning = +2). At the end of Phase 2 (Request Body evaluation), a threshold evaluation rule (`REQUEST-949-BLOCKING-EVALUATION.conf`) compares total accumulated score against configured limits (e.g., Inbound Threshold = 5). If exceeded, a single `403` action is taken. This improves threat context and reduces false positives.

2. **Phase 1 Rule Exclusion Ordering Mechanics:**
   * ModSecurity operates across 5 discrete phases (1: Request Headers, 2: Request Body, 3: Response Headers, 4: Response Body, 5: Logging).
   * ModSecurity evaluates included configuration files sequentially. Rule targets (such as `ARGS:payload`) must be removed via control actions (`ctl:ruleRemoveTargetById`) **before** the target rule actually executes. Because CRS rules inspect headers in Phase 1 and body parameters in Phase 2, exclusions must be evaluated in `phase:1` inside files included **prior** to `owasp-crs/rules/*.conf`.

---

### Exercise 3 Answer Key & Technical Rationale

1. **How `NoNewPrivileges=true` Prevents SUID Escalation:**
   * Executing a binary with the SUID bit set (`-rwsr-xr-x`) normally causes the Linux kernel to execute the binary under the security context of the binary owner (typically `root`) rather than the calling user.
   * `NoNewPrivileges=true` sets the `PR_SET_NO_NEW_PRIVS` flag on the process via `prctl()`. This flag is inherited across `execve()` system calls and explicitly instructs the kernel to ignore SUID/SGID bits and file capabilities entirely, ensuring the process cannot gain privileges beyond its existing execution envelope.

2. **Impact of `MemoryDenyWriteExecute=true` on JIT Runtimes:**
   * `MemoryDenyWriteExecute=true` blocks process requests to create memory mappings that are simultaneously writable and executable (`PROT_WRITE | PROT_EXEC`) or to modify existing memory protection from writable to executable (`mprotect()` / `pkey_mprotect()`).
   * Just-In-Time (JIT) compilers (such as Node.js V8, Java HotSpot, and Python PyPy) dynamically compile bytecode into native machine code directly in RAM, writing native instructions to memory and subsequently executing them. Without configuring non-JIT modes (e.g., `--no-jit` in V8), `MemoryDenyWriteExecute` triggers immediate process crash with a `SIGBUS` or `SIGSYS` signal.

---

### Exercise 4 Answer Key & Technical Rationale

1. **Dual Execution Requirement of `pam_faillock.so`:**
   * **`preauth` Phase:** Runs *before* credential evaluation (`pam_unix`). It checks whether the requesting user account is currently locked due to prior failures. If locked, it aborts the authentication attempt immediately, preventing expensive password hash recalculations (`argon2`/`sha512`) and protecting against CPU resource exhaustion.
   * **`authfail` Phase:** Runs *after* a failed authentication attempt. It increments the persistent failure counter recorded in `/var/run/faillock/` (or `/var/log/tallylog`) for the user.

2. **Security Risk of Misplacing `pam_access.so` Below `pam_unix.so`:**
   * In PAM control flags, if a module is marked as `sufficient` (which `pam_unix.so` often is) and returns success, PAM **immediately bypasses all remaining modules** in that stack section and grants access.
   * If `pam_access.so` is placed after a successful `sufficient pam_unix.so`, its network access rules (`/etc/security/access.conf`) are never evaluated, allowing unauthorized IP addresses to bypass network origin access controls.

---

### Exercise 5 Answer Key & Technical Rationale

1. **`clientcert=verify-ca` vs `clientcert=verify-full`:**
   * **`verify-ca`:** PostgreSQL verifies that the client certificate presented during TLS negotiation is valid and signed by a trusted Certificate Authority (`ssl_ca_file`). It does **not** match the certificate's Common Name (CN) or Subject Alternative Name (SAN) against the connecting database username.
   * **`verify-full`:** Enforces cryptographically complete zero-trust identity verification: It validates the CA chain signature **and** verifies that the certificate CN/SAN matches the database user requested in the connection string (`user=payment_user`).

2. **Cryptographic Superiority of `scram-sha-256` over `md5`:**
   * PostgreSQL's legacy `md5` authentication scheme computes `md5(password + username)`, making hashes vulnerable to rainbow table pre-computation, hash collisions, and offline brute-force attacks if database logs or system tables are exposed.
   * `scram-sha-256` (Salted Challenge Response Authentication Mechanism) uses PBKDF2 key derivation with SHA-256, unique per-user random salts, client/server cryptographic nonces, and bidirectional authentication proofs. The actual password hash is never transmitted over the wire, and mutual authentication prevents rogue server impersonation attacks.

</details>