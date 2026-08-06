# LPIC-3 Exam 303-300 (v3.0) — Topic 4.1: Operations Security

---

## 1. Production Architectural Problem & Operational Context

### 1.1 The Enterprise Threat Landscape & Zero-Trust Imperative

In modern cloud-native and hybrid enterprise infrastructure, Linux servers operate under constant threat of credential stuffing, privilege escalation, unauthorized binary modifications, and covert log manipulation. Operating system security cannot rely solely on edge firewalls or perimetric defenses. According to the Zero-Trust Architecture model (NIST SP 800-207), every node must assume host-level compromise, enforcing strict isolation, continuous runtime verification, immutable logging, and immediate containment.

```
                  +-------------------------------------------------------------+
                  |                      ATTACK VECTORS                         |
                  |  [Brute Force] [Priv Escalation] [Rootkits] [Log Tampering] |
                  +------------------------------+------------------------------+
                                                 |
                                                 v
                  +-------------------------------------------------------------+
                  |               OPERATIONS SECURITY ARCHITECTURE              |
                  |                                                             |
                  |  +-------------------------------------------------------+  |
                  |  | 1. Kernel Runtime Protection (/etc/sysctl.d/*)        |  |
                  |  +---------------------------+---------------------------+  |
                  |                              |                              |
                  |  +---------------------------v---------------------------+  |
                  |  | 2. Identity & Access (PAM faillock, hardened SSH)     |  |
                  |  +---------------------------+---------------------------+  |
                  |                              |                              |
                  |  +---------------------------v---------------------------+  |
                  |  | 3. Process Sandboxing (Systemd Namespace Isolation)   |  |
                  |  +---------------------------+---------------------------+  |
                  |                              |                              |
                  |  +---------------------------v---------------------------+  |
                  |  | 4. Continuous Auditing & FIM (auditd, AIDE Engine)    |  |
                  |  +---------------------------+---------------------------+  |
                  |                              |                              |
                  |  +---------------------------v---------------------------+  |
                  |  | 5. Immutable Log Forwarding (Rsyslog TLS Encrypted)   |  |
                  |  +-------------------------------------------------------+  |
                  +-------------------------------------------------------------+
```

### 1.2 Architectural Failure Modes Addressed by Topic 4.1

1. **Kernel Memory & System Call Exploitation**: Unprivileged processes accessing kernel data structures (`/proc/kallsyms`, `dmesg`), loading malicious unverified kernel modules, or overwriting runtime variables.
2. **Persistence via System Binary Tampering**: Attackers modifying core binaries (`/usr/bin/sudo`, `/usr/sbin/sshd`) or dropping web shells in system paths.
3. **Lateral Movement via Compromised Credentials**: Password guessing against exposed management services (SSH, SSSD) resulting in shell access without lockout rate-limiting.
4. **Log Evasion & Forensic Sabotage**: Local modification or truncation of `/var/log/audit/audit.log` or `/var/log/secure` after achieving root access to erase traces of intrusion.
5. **Over-Privileged Daemon Execution**: System services running with full `CAP_SYS_ADMIN` or unrestricted root filesystem write permissions, enabling arbitrary code execution upon daemon vulnerability exploitation.

---

## 2. Technical Comparisons & Architecture Trade-Offs

### Table 2.1: File Integrity Monitoring (FIM) Engines

| Dimension | AIDE (Advanced Intrusion Detection Environment) | Tripwire | Linux IMA/EVM (Integrity Measurement Architecture) |
| :--- | :--- | :--- | :--- |
| **Execution Layer** | Userspace scheduled scan (cron / systemd timer) | Userspace scheduled or daemon scan | Linux Kernel inline verification (LSM hook) |
| **Detection Speed** | Periodic batch (high latency to alert) | Periodic batch or near-real-time | Real-time (blocks execution prior to read/exec) |
| **Performance Impact** | Heavy I/O spikes during database checks | High I/O during scan runs | Minimal inline overhead (cached extended attributes) |
| **Database Protection** | Offline hash comparison (requires remote DB storage) | Encrypted binary database files | Hardware Root-of-Trust (TPM 2.0 PCR signing) |
| **Operational Complexity**| Low/Medium (flat file text database, simple syntax) | High (requires site & local key management) | Extremely High (requires PKI, custom kernel, TPM provisioning) |
| **Production Fit** | Standard Linux baseline compliance audit | Legacy enterprise deployments | High-security enclave / Zero-Trust bare-metal hosts |

### Table 2.2: Linux System Auditing Frameworks

| Feature / Metric | Linux `auditd` Subsystem | eBPF Security Tracing (BCC / Tetragon) | Sysmon for Linux |
| :--- | :--- | :--- | :--- |
| **Kernel Mechanism** | Kauditd netlink socket & SYSCALL hooks | Kernel eBPF tracepoints & kprobes | eBPF tracepoints over Sysinternals engine |
| **Performance Overhead**| High under heavy IOPS / syscall density | Microsecond-level, minimal ring-buffer cost | Medium (parsing overhead in userspace service) |
| **Rule Granularity** | Path, inode, syscall, process UID, audit key | Deep context (arguments, network sockets, container ID)| Event ID-based schema (Windows-aligned XML rules) |
| **Tamper Resistance** | Can lock rules (`-e 2`), requires reboot to clear | Bounded memory verification, JIT compiled | Dependent on underlying systemd unit protection |
| **SIEM Integration** | Native via `audispd` / syslog plugins | Direct JSON stream over gRPC / stdout | Structured XML / JSON logs |

### Table 2.3: Process Isolation & Sandboxing Mechanisms

| Security Layer | Systemd Service Sandboxing | AppArmor Profile | SELinux Policy |
| :--- | :--- | :--- | :--- |
| **Policy Model** | Declarative key-value unit directives | Path-based access control lists | Type Enforcement (TE) & Multi-Level Security (MLS) |
| **Configuration Complexity**| Low (configured inside systemd unit file) | Medium (profile generation via `aa-genprof`) | High (custom TE file compilation via `checkmodule`/`semodule`) |
| **Enforcement Scope** | Systemd-managed daemons and processes | Path matching across system binaries | Global kernel object labelling (Inodes, Sockets, Processes) |
| **Maintenance Burden** | Minimal (applies directly during deployment manifest) | Moderate (requires profile updates on binary updates) | High (frequent relabelling and SELinux boolean tuning) |

### Table 2.4: Brute-Force & Lockout Mechanisms

| Metric | `pam_faillock` (PAM Native) | `fail2ban` (Log Parser) | SSH Bastion / OAuth2 Proxy |
| :--- | :--- | :--- | :--- |
| **Trigger Point** | Authentication process hook (in-memory counter) | Asynchronous log file polling (`/var/log/secure` matching)| API Gateway authentication layer |
| **Enforcement Vector** | Rejects authentication attempt at PAM stack level | Inserts dynamic firewall rules (`nftables` / `iptables`) | Denies network packet transport / HTTP session |
| **Latency to Block** | Instantaneous (0 ms) | Polling delay (1s - 10s depending on log read rate) | Instantaneous |
| **DoS Vulnerability** | Risk of lock-out against valid accounts if targeted | IP spoofing / memory exhaustion via massive logs | Distributed botnet IP pool rotation |

---

## 3. Production Configuration Files & Infrastructure Manifests

### 3.1 Kernel Security Hardening (`/etc/sysctl.d/99-security-hardening.conf`)

This configuration enforces strict kernel memory space protection, restricts access to kernel logs, disables unprivileged eBPF, and hardens network stack security.

```ini
# ==============================================================================
# LPIC-3 303 PRODUCTION KERNEL HARDENING SPECIFICATION
# Path: /etc/sysctl.d/99-security-hardening.conf
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. KERNEL SELF-PROTECTION & MEMORY HARDENING
# ------------------------------------------------------------------------------
# Restrict dmesg buffer access to users with CAP_SYSLOG
kernel.dmesg_restrict = 1

# Restrict access to kernel pointer addresses in /proc/kallsyms
kernel.kptr_restrict = 2

# Disable unprivileged eBPF execution to prevent kernel memory exploitation
kernel.unprivileged_bpf_disabled = 1

# Enable JIT hardening for eBPF compiler (blinds immediate constants)
net.core.bpf_jit_harden = 2

# Randomize memory space layout (ASLR full randomization)
kernel.randomize_va_space = 2

# Restrict ptrace usage to parent processes (YAMA LSM enforcement)
kernel.yama.ptrace_scope = 2

# Restrict core dump generation for setuid processes
fs.suid_dumpable = 0

# Restrict Magic SysRq key combinations (Allow only graceful sync & remount)
kernel.sysrq = 176

# Lock kernel module loading after system initialization (Set to 1 via startup script if static)
# kernel.modules_disabled = 0

# ------------------------------------------------------------------------------
# 2. FILESYSTEM PROTECTIONS
# ------------------------------------------------------------------------------
# Restrict hardlinks creation to owned files
fs.protected_hardlinks = 1

# Restrict symlinks creation in world-writable sticky directories (/tmp)
fs.protected_symlinks = 1

# Prevent FIFO creation in world-writable sticky directories
fs.protected_fifos = 2

# Prevent regular file creation in world-writable sticky directories by non-owners
fs.protected_regular = 2

# ------------------------------------------------------------------------------
# 3. NETWORK STACK HARDENING (IPv4 / IPv6)
# ------------------------------------------------------------------------------
# Ignore ICMP echo requests (Ping request drop)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Enable Strict Reverse Path Filtering (RFC 3704 - Prevent IP Spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable IP Source Routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable ICMP Redirect Acceptance (Prevent MitM route redirection)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable ICMP Redirect Sending
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Enable TCP SYN Cookies (SYN Flood Mitigation)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
```

---

### 3.2 Systemd Service Security Isolation (`/etc/systemd/system/hardened-app.service`)

A production systemd unit implementing full Linux namespace isolation, capability bounding, and filesystem write restrictions.

```ini
[Unit]
Description=Production Hardened Application Service
Documentation=https://docs.enterprise.internal/arch/sec-01
After=network.target remote-fs.target syslog.target
Wants=network.target

[Service]
Type=notify
User=appuser
Group=appuser
WorkingDirectory=/opt/hardened-app
ExecStart=/opt/hardened-app/bin/server --config /etc/hardened-app/config.yaml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# ------------------------------------------------------------------------------
# PROCESS CAPABILITIES AND PRIVILEGE ESCALATION PREVENTIONS
# ------------------------------------------------------------------------------
# Deny gaining new privileges via setuid/setgid binaries
NoNewPrivileges=true

# Limit capabilities to absolute minimum required (Drop CAP_SYS_ADMIN, CAP_NET_ADMIN, etc.)
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Restrict ambient capabilities
AmbientCapabilities=CAP_NET_BIND_SERVICE

# Force execution without root identity escalation options
SecureBits=noroot noroot-locked nosuid-off nosuid-off-locked

# ------------------------------------------------------------------------------
# FILESYSTEM PROTECTION AND ISOLATION
# ------------------------------------------------------------------------------
# Mount /usr, /boot, /etc, /usr/local as read-only for this process tree
ProtectSystem=strict

# Make /home, /root, /run/user inaccessible
ProtectHome=true

# Mount isolated private /tmp and /var/tmp directories
PrivateTmp=true

# Make /dev nodes inaccessible except pseudo-devices (null, zero, random, urandom)
PrivateDevices=true

# Block modification of kernel tunables (/proc/sys, /sys, /proc/sysrq-trigger)
ProtectKernelTunables=true

# Block modification of kernel modules (/usr/lib/modules loading)
ProtectKernelModules=true

# Make kernel control groups hierarchy (/sys/fs/cgroup) read-only
ProtectControlGroups=true

# Directives defining explicit write access directories
ReadWritePaths=/var/log/hardened-app /var/run/hardened-app
ReadOnlyPaths=/etc/hardened-app

# ------------------------------------------------------------------------------
# SYSTEM CALL & KERNEL PROTECTION
# ------------------------------------------------------------------------------
# Filter system calls (Allow common basic set + system service essentials)
SystemCallFilter=@system-service
SystemCallFilter=~@clock @cpu-emulation @debug @keyring @module @mount @obsolete @raw-io @reboot @swap

# Force Architecture constraint for System Call table matching
SystemCallArchitectures=native

# Prevent memory mappings that are both writable and executable (W^X violation)
MemoryDenyWriteExecute=true

# Restrict Network Address Families (Allow IPv4, IPv6, Unix Sockets only)
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Restrict Real-Time scheduling attributes
RestrictRealtime=true

# Restrict Namespace creation (CLONE_NEWUSER, CLONE_NEWNET, etc.)
RestrictNamespaces=true

# Prevent access to hardware clock
ProtectClock=true

# Protect Hostname & Domain Name modification
ProtectHostname=true

# ------------------------------------------------------------------------------
# RESOURCE LIMITS (Cgroups v2 / ulimit constraints)
# ------------------------------------------------------------------------------
LimitNOFILE=65536
LimitNPROC=4096
LimitCORE=0
TasksMax=1024
MemoryMax=2G
CPUWeight=100

[Install]
WantedBy=multi-user.target
```

---

### 3.3 AIDE Configuration Manifest (`/etc/aide/aide.conf`)

This AIDE (Advanced Intrusion Detection Environment) configuration enforces SHA-512 cryptographic hash integrity auditing across essential binaries, configuration files, and boot artifacts while explicitly filtering volatile log files.

```ini
# ==============================================================================
# LPIC-3 303 HARDENED AIDE CONFIGURATION SPECIFICATION
# Path: /etc/aide/aide.conf
# ==============================================================================

# Database locations
database_in=file:/var/lib/aide/aide.db.gz
database_out=file:/var/lib/aide/aide.db.new.gz
database_new=file:/var/lib/aide/aide.db.new.gz
gzip_dbout=yes

# Report settings
report_url=file:/var/log/aide/aide_report.log
report_url=stdout
verbose=5

# Summarize changes
report_attributes=sha512

# ------------------------------------------------------------------------------
# CUSTOM RULE DEFINITIONS
# ------------------------------------------------------------------------------
# p: permissions, i: inode, n: number of links, u: user, g: group, s: size,
# b: block count, m: mtime, c: ctime, acl: access control list, xattrs: extended attributes,
# sha512: cryptographic checksum.

# Strict Binaries & System Core Rule
BINARIES = p+i+n+u+g+s+b+m+c+acl+xattrs+sha512

# Strict Configuration Files Rule
CONFIGS  = p+i+n+u+g+s+m+c+acl+xattrs+sha512

# Log Files Monitoring Rule (Permit size and time changes, flag ownership/permission shifts)
LOGFILES = p+i+n+u+g+acl+xattrs

# Static Directory Rule
DIRRULES = p+i+n+u+g+acl+xattrs

# ------------------------------------------------------------------------------
# INCLUSION SELECTION RULES
# ------------------------------------------------------------------------------
# Kernel & Boot Integrity
/boot BINARIES

# System Executables & Libraries
/bin BINARIES
/sbin BINARIES
/usr/bin BINARIES
/usr/sbin BINARIES
/lib BINARIES
/lib64 BINARIES
/usr/lib BINARIES
/usr/lib64 BINARIES

# Critical System Configurations
/etc CONFIGS
/etc/pam.d CONFIGS
/etc/security CONFIGS
/etc/sysctl.d CONFIGS
/etc/audit CONFIGS
/etc/ssh CONFIGS

# System Security Databases
/var/lib/dpkg CONFIGS
/var/lib/rpm CONFIGS

# ------------------------------------------------------------------------------
# EXCLUSION / NEGATIVE SELECTION RULES
# ------------------------------------------------------------------------------
!/etc/mtab
!/var/log/.*
!/var/spool/.*
!/var/tmp/.*
!/tmp/.*
!/proc/.*
!/sys/.*
!/dev/.*
!/run/.*
```

---

### 3.4 Auditd Enterprise Rules Engine (`/etc/audit/rules.d/audit.rules`)

A complete ruleset configured to intercept privilege escalation attempts, identity adjustments, dynamic library loads, file permission changes, and unauthorized file access.

```ini
# ==============================================================================
# LPIC-3 303 PRODUCTION AUDITD RULES SPECIFICATION
# Path: /etc/audit/rules.d/audit.rules
# ==============================================================================

# Remove all existing rules
-D

# Set buffer size (High performance setting for high-throughput nodes)
-b 8192

# Failure Mode: 1=log error, 2=panic kernel immediately on failure
-f 1

# Rate limiting (0 means unlimited)
-r 0

# ------------------------------------------------------------------------------
# 1. SYSTEM CALL MONITORING: EXECUTION & PRIVILEGE ESCALATION
# ------------------------------------------------------------------------------
# Monitor execve syscalls by non-root users (UID >= 1000)
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=4294967295 -k execution_monitoring
-a always,exit -F arch=b32 -S execve -F auid>=1000 -F auid!=4294967295 -k execution_monitoring

# Capture root execution of privilege elevation binaries (sudo, su, pkexec)
-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -k priv_escalation
-a always,exit -F arch=b32 -S setuid -S setgid -S setreuid -S setregid -k priv_escalation

# ------------------------------------------------------------------------------
# 2. FILESYSTEM INTEGRITY & CONFIGURATION CHANGE AUDITING
# ------------------------------------------------------------------------------
# Audit identity & access modification files
-w /etc/passwd -p wa -k identity_changes
-w /etc/shadow -p wa -k identity_changes
-w /etc/group -p wa -k identity_changes
-w /etc/gshadow -p wa -k identity_changes
-w /etc/security/opasswd -p wa -k identity_changes
-w /etc/sudoers -p wa -k privilege_changes
-w /etc/sudoers.d/ -p wa -k privilege_changes

# Audit network configuration updates
-w /etc/hosts -p wa -k network_modifications
-w /etc/resolv.conf -p wa -k network_modifications
-w /etc/sysconfig/network -p wa -k network_modifications
-w /etc/netplan/ -p wa -k network_modifications

# Audit PAM authentication subsystem modifications
-w /etc/pam.d/ -p wa -k pam_modifications
-w /etc/security/ -p wa -k pam_modifications

# Audit SSH service configuration files
-w /etc/ssh/sshd_config -p wa -k sshd_config_changes
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_changes

# ------------------------------------------------------------------------------
# 3. UNAUTHORIZED ACCESS & DISCRETIONARY ACCESS CONTROL (DAC) MODIFICATIONS
# ------------------------------------------------------------------------------
# Monitor failed file access attempts (EACCES / EPERM)
-a always,exit -F arch=b64 -S open -S openat -S creat -S truncate -S ftruncate -F exit=-EACCES -k access_denied
-a always,exit -F arch=b64 -S open -S openat -S creat -S truncate -S ftruncate -F exit=-EPERM -k access_denied
-a always,exit -F arch=b32 -S open -S openat -S creat -S truncate -S ftruncate -F exit=-EACCES -k access_denied
-a always,exit -F arch=b32 -S open -S openat -S creat -S truncate -S ftruncate -F exit=-EPERM -k access_denied

# Monitor file permission changes (chmod, chown, fchmod, fchown, setxattr)
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -S chown -S fchown -S fchownat -S lchown -k dac_modifications
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -S chown -S fchown -S fchownat -S lchown -k dac_modifications

# ------------------------------------------------------------------------------
# 4. KERNEL MODULE MANAGEMENT AUDITING
# ------------------------------------------------------------------------------
# Monitor insertion and deletion of kernel modules
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k module_chg
-w /usr/bin/kmod -p x -k module_chg
-w /usr/sbin/insmod -p x -k module_chg
-w /usr/sbin/rmmod -p x -k module_chg
-w /usr/sbin/modprobe -p x -k module_chg

# ------------------------------------------------------------------------------
# 5. IMMUTABILITY LOCK DIRECTIVE
# ------------------------------------------------------------------------------
# Make audit configuration immutable. REQUIRES A REBOOT TO UNLOAD RULES.
-e 2
```

---

### 3.5 PAM Hardening Specifications

#### File 1: `/etc/security/faillock.conf`

```ini
# ==============================================================================
# PAM FAILLOCK CONFIGURATION SPECIFICATION
# Path: /etc/security/faillock.conf
# ==============================================================================

# Directory where faillock state records are retained
dir = /var/run/faillock

# Audit failed attempts to system log
audit

# Lock account even if failure originates from silent services
silent

# Lock root account under persistent brute-force conditions
even_deny_root

# Number of consecutive failures allowed prior to account locking
deny = 5

# Lockout duration in seconds (900 seconds = 15 minutes)
unlock_time = 900

# Time interval in seconds within which failures are accumulated (600s = 10 minutes)
fail_interval = 600

# Do not unlock root account automatically (Requires explicit admin intervention)
root_unlock_time = 1800
```

#### File 2: `/etc/security/pwquality.conf`

```ini
# ==============================================================================
# PAM PWQUALITY MODULE CONFIGURATION
# Path: /etc/security/pwquality.conf
# ==============================================================================

# Minimum password length
minlen = 14

# Minimum number of digits required
dcredit = -1

# Minimum number of uppercase characters required
ucredit = -1

# Minimum number of lowercase characters required
lcredit = -1

# Minimum number of special/other characters required
ocredit = -1

# Maximum number of allowed repeating characters
maxrepeat = 3

# Maximum length of sequence of monotonic characters (e.g. "12345", "abcd")
maxsequence = 3

# Reject passwords containing user login name in forward or reverse
gecoscheck = 1

# Number of characters that must not match the old password
difok = 8

# Enforce quality checks on root user password modifications
enforce_for_root
```

#### File 3: Full Stack Integration (`/etc/pam.d/system-auth`)

```pam
# ==============================================================================
# LPIC-3 HARDENED PAM SYSTEM-AUTH STACK DEFINITION
# Path: /etc/pam.d/system-auth
# ==============================================================================

# ------------------------------------------------------------------------------
# AUTHENTICATION STACK
# ------------------------------------------------------------------------------
auth        required      pam_env.so
auth        required      pam_faillock.so preauth silent audit deny=5 unlock_time=900
auth        sufficient    pam_unix.so try_first_pass nullok
auth        [default=die] pam_faillock.so authfail audit deny=5 unlock_time=900
auth        required      pam_deny.so

# ------------------------------------------------------------------------------
# ACCOUNT MANAGEMENT STACK
# ------------------------------------------------------------------------------
account     required      pam_faillock.so
account     required      pam_unix.so
account     required      pam_permit.so

# ------------------------------------------------------------------------------
# PASSWORD CHANGE STACK
# ------------------------------------------------------------------------------
password    requisite     pam_pwquality.so retry=3
password    sufficient    pam_unix.so sha512 shadow use_authtok remember=5
password    required      pam_deny.so

# ------------------------------------------------------------------------------
# SESSION MANAGEMENT STACK
# ------------------------------------------------------------------------------
session     optional      pam_keyinit.so revoke
session     required      pam_limits.so
session     -optional     pam_systemd.so
session     required      pam_unix.so
```

---

### 3.6 Hardened OpenSSH Daemon Configuration (`/etc/ssh/sshd_config.d/99-hardened.conf`)

```ini
# ==============================================================================
# HARDENED OPENSSH DAEMON CONFIGURATION SPECIFICATION
# Path: /etc/ssh/sshd_config.d/99-hardened.conf
# ==============================================================================

# Protocol & Network Binding
Port 22
Protocol 2
ListenAddress 0.0.0.0
ListenAddress ::

# Cryptographic Host Keys
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Strict Modern Cryptographic Algorithms (Explicit Ciphers, KEX, and MACs)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Authentication Mechanisms
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey

# PAM Integration
UsePAM yes

# Access Control Limits
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30

# User Access Restrictions
AllowGroups sysadmin-ssh devops-ssh

# Environment & Tunneling Restrictions
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTTY yes
PermitUserEnvironment no
PermitTunnel no
StrictModes yes

# Log & Banner
LogLevel VERBOSE
SyslogFacility AUTH
Banner /etc/issue.net
```

---

### 3.7 Centralized RSYSLOG TLS Forwarding (`/etc/rsyslog.d/60-secure-forwarding.conf`)

Guarantees log integrity by transmitting local syslog and audit records to a centralized log collector over TLS encrypted channels with mutual authentication.

```rsyslog
# ==============================================================================
# RSYSLOG MUTUAL TLS ENCRYPTED FORWARDING CONFIGURATION
# Path: /etc/rsyslog.d/60-secure-forwarding.conf
# ==============================================================================

# Load RELP & TLS Network Modules
module(load="imuxsock")
module(load="imjournal")
module(load="omfwd")

# Define Certificate Authority and Keys for Mutual TLS (mTLS)
global(
    DefaultNetstreamDriver="gtls"
    DefaultNetstreamDriverCAFile="/etc/pki/tls/certs/internal-ca.crt"
    DefaultNetstreamDriverCertFile="/etc/pki/tls/certs/node01-syslog.crt"
    DefaultNetstreamDriverKeyFile="/etc/pki/tls/private/node01-syslog.key"
)

# Template for RFC5424 High-Precision Structured Logs
template(name="RFC5424Format" type="string" string="<%PRI%>%TIMESTAMP:::date-rfc3339% %HOSTNAME% %APP-NAME% %PROCID% %MSGID% %STRUCTURED-DATA% %msg%\n")

# Disk-Assisted Memory Queue (Prevents Log Loss During Network Outages)
action(
    type="omfwd"
    Target="syslog-aggregator.internal.net"
    Port="6514"
    Protocol="tcp"
    NetworkStreamDriver="gtls"
    NetworkStreamDriverAuthMode="x509/name"
    NetworkStreamDriverPermittedPeer="syslog-aggregator.internal.net"
    StreamDriverMode="1"
    template="RFC5424Format"
    
    # Queue resilience configuration
    queue.filename="fwd_syslog_queue"
    queue.maxdiskspace="1g"
    queue.saveonshutdown="on"
    queue.type="LinkedList"
    action.resumeRetryCount="-1"
)
```

---

## 4. Real-World CLI Commands & Terminal Output Diagnostics

### 4.1 AIDE Database Operations & File Tampering Detection

#### Step 1: Database Initialization

```bash
$ sudo aide --init
```

```text
AIDE, version 0.16.1-BugFixes

AIDE database successfully generated.
Directory: /var/lib/aide
Output file: /var/lib/aide/aide.db.new.gz

MD5 checksum of new database:   3f4a9b81c2d0e7a4123456789abcdef0
SHA512 checksum of new database: a1b2c3d4e5f67890123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0

[NOTICE] Remember to move /var/lib/aide/aide.db.new.gz to /var/lib/aide/aide.db.gz prior to running --check.
```

#### Step 2: Database Activation

```bash
$ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

#### Step 3: Simulating System Binary Modification & Running Integrity Check

```bash
$ sudo touch /usr/bin/unauthorized_tool
$ sudo chmod u+s /usr/bin/sudo
$ sudo aide --check
```

```text
AIDE 0.16.1-BugFixes found differences between database and filesystem!!
Start timestamp: 2026-08-06 14:10:02 +0000

Summary:
  Total number of files:        48291
  Added files:                  1
  Removed files:                0
  Changed files:                1

-------------------------------------------------------------------------------
Added files:
-------------------------------------------------------------------------------
  added: /usr/bin/unauthorized_tool

-------------------------------------------------------------------------------
Changed files:
-------------------------------------------------------------------------------
  changed: /usr/bin/sudo

-------------------------------------------------------------------------------
Detailed information about changes:
-------------------------------------------------------------------------------

File: /usr/bin/sudo
 Perm     : -rwxr-xr-x                       , -rwsr-xr-x
 Ctime    : 2026-08-06 13:00:00 +0000        , 2026-08-06 14:09:45 +0000
 ACL      : AIDE detected ACL modification
```

---

### 4.2 Systemd Security Hardening Assessment

#### Analyzing Security Score of a System Service

```bash
$ systemd-analyze security hardened-app.service
```

```text
  NAME                             DESCRIPTION                                      EXPOSURE
x Overall System Security Exposure Score: 1.2 OK (Hardened)                       

  KEY                              DESCRIPTION                                      VALUE
✓ PrivateTmp=                       Service has a private /tmp directory            0.0
✓ PrivateDevices=                  Service has no access to physical devices        0.0
✓ ProtectSystem=                   Service has read-only access to system paths     0.0
✓ ProtectHome=                     Service has no access to home directories        0.0
✓ NoNewPrivileges=                 Service processes cannot gain new privileges     0.0
✓ CapabilityBoundingSet=           Capabilities are strictly limited                0.1
✓ SystemCallFilter=                System call filtering is active                  0.2
✓ MemoryDenyWriteExecute=          W^X memory protection enforced                   0.1
✓ RestrictAddressFamilies=         Allowed network address families are limited     0.1

-> Exposure score lower than 2.0 indicates an exceptionally hardened systemd service.
```

---

### 4.3 Querying the Audit Subsystem with `ausearch` and `aureport`

#### Step 1: Searching for DAC Permission Violations (Access Denied Events)

```bash
$ sudo ausearch -k access_denied --raw | aureport -f -i
```

```text
File Report
===============================================
# date time file syscall success exe auid event
===============================================
1. 08/06/2026 14:15:22 /etc/shadow openat no /usr/bin/cat appuser 4021
2. 08/06/2026 14:18:01 /etc/sudoers.d/admin openat no /usr/bin/vim attacker 4029
```

#### Step 2: Extracting Detailed Record for Specific Event ID

```bash
$ sudo ausearch -a 4021
```

```text
----
time->Thu Aug  6 14:15:22 2026
type=PROCTITLE msg=audit(1722953722.891:4021): proctitle=636174002F6574632F736861646F77
type=SYSCALL msg=audit(1722953722.891:4021): arch=c00003e6 syscall=257 success=no exit=-13 a0=ffffff9c a1=7ffd20a1b910 a2=0 a3=0 items=1 ppid=1204 pid=3412 auid=1001 uid=1001 gid=1001 euid=1001 suid=1001 fsuid=1001 egid=1001 sgid=1001 fsgid=1001 tty=pts0 ses=2 comm="cat" exe="/usr/bin/cat" key="access_denied"
type=PATH msg=audit(1722953722.891:4021): item=0 name="/etc/shadow" inode=131422 dev=08:01 mode=0100000 ouid=0 ogid=42 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0
```

---

### 4.4 Managing PAM Lockouts via `faillock` CLI

#### Step 1: Checking Account Failure State

```bash
$ sudo faillock --user devuser
```

```text
devuser:
When                Valid  Source            Valid
2026-08-06 14:20:10   V    192.168.1.50        V
2026-08-06 14:20:14   V    192.168.1.50        V
2026-08-06 14:20:18   V    192.168.1.50        V
2026-08-06 14:20:22   V    192.168.1.50        V
2026-08-06 14:20:25   V    192.168.1.50        V
Account is locked due to 5 failed login attempts.
```

#### Step 2: Performing Administrative Unlock

```bash
$ sudo faillock --user devuser --reset
$ sudo faillock --user devuser
```

```text
devuser:
No failed login attempts recorded.
```

---

## 5. Production Verification & Troubleshooting Guide

### 5.1 Troubleshooting Flowchart: Service Startup Failures in Hardened Systemd Units

```
[Service Fails to Start: systemctl start hardened-app]
                           |
                           v
           [Run: journalctl -xeu hardened-app]
                           |
            +--------------+--------------+
            |                             |
  [Error: Permission Denied]    [Error: Address Family Not Supported]
  [Exit Code: 226/NAMESPACE]     [Exit Code: 1/FAILURE on socket bind]
            |                             |
            v                             v
  Check Write Paths:            Check Socket Family Settings:
  Is service writing outside    Does app use Unix sockets / Netlink?
  ReadWritePaths=?              Add AF_NETLINK or AF_UNIX to
  Does service require /dev?    RestrictAddressFamilies=
  Set PrivateDevices=false      
```

---

### 5.2 Common Operational Failure Scenarios & Resolutions

#### Issue 1: `Auditd` Refuses to Load New Rules in Production

* **Symptom**: Executing `sudo auditctl -R /etc/audit/rules.d/audit.rules` returns: `Error sending reload request (Operation not permitted)`.
* **Root Cause**: The rule `-e 2` (Immutability Lock) was executed in a prior rule loading sequence. Kernel prevents rule alteration until reboot.
* **Diagnostic Command**:
  ```bash
  $ sudo auditctl -s
  ```
  *Output*: `enabled 2, failure 1, pid 812, rate_limit 0, backlog_limit 8192, lost 0, backlog 0`
* **Resolution**: Change rules in `/etc/audit/rules.d/audit.rules` and issue a controlled host reboot. Never execute `-e 2` in dynamic testing environments.

---

#### Issue 2: AIDE Check Fails with False Positives After Operating System Package Upgrades

* **Symptom**: `aide --check` reports hundreds of modified binaries under `/usr/bin` and `/usr/lib64` following an `apt upgrade` or `dnf update`.
* **Root Cause**: AIDE baseline database was generated prior to package updates.
* **Resolution Workflow**:
  1. Verify update validity via package manager audit logs (`/var/log/dpkg.log` or `dnf history`).
  2. Regenerate baseline database immediately following scheduled maintenance:
     ```bash
     $ sudo aide --update
     $ sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
     ```

---

#### Issue 3: Legitimate Users Locked Out Indefinitely by PAM `pam_faillock`

* **Symptom**: SSH login succeeds via PKI, but `su -` or `sudo` prompts return `Authtok update failed` or immediate rejection without password prompt.
* **Root Cause**: `even_deny_root` or cumulative failure records in `/var/run/faillock` exceeded threshold.
* **Resolution Playbook**:
  1. Inspect lockout records:
     ```bash
     $ sudo faillock --user <username>
     ```
  2. Clear lockouts for user:
     ```bash
     $ sudo faillock --user <username> --reset
     ```
  3. Inspect auth log for brute-force source IPs:
     ```bash
     $ sudo grep "pam_faillock" /var/log/auth.log
     ```

---

## 6. References

* **Linux Professional Institute LPIC-3 303 Specifications**: [https://www.lpi.org/our-certifications/lpic-3-303-specifications/](https://www.lpi.org/our-certifications/lpic-3-303-specifications/)
* **The Linux Kernel Documentation — Sysctl Hardware & Memory Hardening**: [https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html](https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html)
* **Systemd Security Directives & Sandboxing Manual**: [https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Security%20Options](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#Security%20Options)
* **AIDE (Advanced Intrusion Detection Environment) Documentation**: [https://aide.github.io/](https://aide.github.io/)
* **Linux Audit Subsystem (Auditd) Documentation**: [https://github.com/linux-audit/audit-documentation](https://github.com/linux-audit/audit-documentation)
* **NIST SP 800-53 Rev. 5 — Security and Privacy Controls for Information Systems**: [https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final](https://csrc.nist.gov/publications/detail/sp/800-53/rev-5/final)
* **OpenSSH Hardware & Security Manual**: [https://www.openssh.com/manual.html](https://www.openssh.com/manual.html)