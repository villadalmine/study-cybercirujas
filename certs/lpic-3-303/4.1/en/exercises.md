# LPIC-3 Exam 303-300 (v3.0): Topic 4.1 - Operations Security

**Certification Domain**: LPIC-3 Security (Exam 303-300, Version 3.0)  
**Topic**: 4.1 Operations Security  
**Weight**: 16.67  
**Official Reference Sources**:
- [LPI LPIC-3 303 Overview](https://www.lpi.org/our-certifications/lpic-3-303-overview/)
- [LPI 303 Exam Objectives](https://www.lpi.org/our-certifications/exam-303-objectives)

---

## Technical Mechanics & Architectural Overview

Operations Security (OpSec) at the production enterprise level requires hardening Linux nodes, establishing continuous integrity verification, enforcing granular system call limits, and maintaining tamper-evident audit control planes.

```
                  +-------------------------------------------------------------+
                  |                      USERSPACE LINUX                        |
                  |                                                             |
                  |  +------------------------+     +------------------------+  |
                  |  |  systemd Sandboxed     |     |   AIDE & OpenSCAP      |  |
                  |  |  Service (Namespaces)  |     |   Integrity Scanner    |  |
                  |  +-----------+------------+     +-----------+------------+  |
                  |              |                              |               |
                  +--------------|------------------------------|---------------+
                                 | System Calls                 | File Queries /
                                 | (execve, openat)             | Hash Computation
                  ---------------+------------------------------+----------------
                  |                      LINUX KERNEL                           |
                  |                                                             |
                  |  +------------------------+     +------------------------+  |
                  |  |  seccomp / Capabilities|     |   Audit Subsystem      |  |
                  |  |  Enforcement Engine    |     |   (auditd / kauditd)   |  |
                  |  +------------------------+     +-----------+------------+  |
                  |                                             |               |
                  +---------------------------------------------|---------------+
                                                                v
                                                  /var/log/audit/audit.log
```

### 1. Process Isolation & Kernel Sandboxing Mechanics
Modern systemd units leverage Linux kernel primitives to implement operational defense-in-depth:
- **Namespaces (`CLONE_NEWNS`, `CLONE_NEWNET`, `CLONE_NEWPID`)**: `ProtectSystem=strict` and `ProtectHome=yes` remount system trees with `MS_RDONLY` and create isolated mount namespaces per process tree.
- **Seccomp Filters (`prctl(PR_SET_SECCOMP)`)**: System call filtering intercept syscalls via Berkeley Packet Filters (BPF) inside the kernel prior to execution, executing `SIGSYS` or returning `EPERM` when non-whitelisted syscalls are issued.
- **Capabilities Bounding Set (`capset`)**: Drops kernel privileges (such as `CAP_SYS_ADMIN`, `CAP_NET_RAW`) preventing uid 0 processes from performing unrestricted operations.

### 2. Audit Subsystem Interception Path
The Linux audit subsystem (`kauditd`) hooks into the system call entry and exit points inside the kernel. When a process issues an `execve` or modifies an audited inode, `auditctl` rules evaluated in kernel memory output netlink packets directly to the `auditd` daemon, bypassing standard logging facilities (`syslog`) to ensure non-repudiation.

### 3. Cryptographic File Integrity Verification
Tools like AIDE (Advanced Intrusion Detection Environment) compute cryptographic message digests ($SHA256$, $SHA512$) and inode metadata metrics (ctime, mtime, inode, permissions, extended attributes) against a baseline database (`aide.db.gz`). Integrity degradation detection relies on comparing live filesystem state parameters against pre-computed cryptographic signatures stored on read-only media or remote immutable storage.

---

## Guided Exercises

### Exercise 1: Systemd Service Hardening & Sandboxing Analysis

In this exercise, you will create a vulnerable microservice script, encapsulate it inside a restricted systemd service unit, enforce strict kernel-level sandboxing directives, and measure the hardening profile using systemd security evaluation tools.

#### Step 1: Create a mock API worker binary script
Create a mock worker application at `/usr/local/bin/dummy_worker.sh` that attempts to perform illegal file writes and network interactions.

```bash
sudo tee /usr/local/bin/dummy_worker.sh > /dev/null << 'EOF'
#!/bin/bash
echo "[+] Starting Dummy Worker PID $$..."
echo "[+] Attempting write to /etc/test_tamper.txt..."
echo "unauthorized_data" > /etc/test_tamper.txt 2>&1 || echo "[-] WRITE FAILED: /etc/test_tamper.txt"

echo "[+] Attempting read from /home..."
ls -la /home 2>&1 || echo "[-] READ FAILED: /home"

sleep 3600
EOF

sudo chmod +x /usr/local/bin/dummy_worker.sh
```

#### Step 2: Write a fully hardened systemd unit file
Create `/etc/systemd/system/hardened-worker.service` with strict Operational Security parameters.

```ini
[Unit]
Description=Hardened Production Worker Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dummy_worker.sh
User=nobody
Group=nogroup

# Operational Security Sandboxing Directives
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
NoNewPrivileges=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=

# System Call & Memory Execution Constraints
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallFilter=~@privileged ~@resources
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

#### Step 3: Reload systemd daemon, start service, and inspect stdout logs
Reload systemd, start the service, and inspect the operational output via `journalctl`.

```bash
sudo systemctl daemon-reload
sudo systemctl start hardened-worker.service
sudo journalctl -u hardened-worker.service -n 20 --no-pager
```

**Expected Output:**
```text
-- Logs begin at Thu 2026-08-06 10:00:00 UTC. --
Aug 06 13:30:00 node01 systemd[1]: Started Hardened Production Worker Service.
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Starting Dummy Worker PID 12451...
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Attempting write to /etc/test_tamper.txt...
Aug 06 13:30:00 node01 dummy_worker.sh[12453]: /usr/local/bin/dummy_worker.sh: line 4: /etc/test_tamper.txt: Read-only file system
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [-] WRITE FAILED: /etc/test_tamper.txt
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [+] Attempting read from /home...
Aug 06 13:30:00 node01 dummy_worker.sh[12454]: ls: cannot open directory '/home': Permission denied
Aug 06 13:30:00 node01 dummy_worker.sh[12451]: [-] READ FAILED: /home
```

#### Step 4: Evaluate security posture score using `systemd-analyze`
Run systemd's built-in security scoring tool against the service to calculate exposure metrics.

```bash
sudo systemd-analyze security hardened-worker.service
```

**Expected Output (Truncated):**
```text
NAME                                  DESCRIPTION                                      EXPOSURE
✔ PrivateTmp=                         Service has a private /tmp dir                   0.0
✔ ProtectSystem=                      Service has strict protection on /usr /boot /etc 0.0
✔ ProtectHome=                        Service protects user home directories           0.0
✔ CapabilityBoundingSet=              Service has no capabilities                      0.0
✔ NoNewPrivileges=                    Service processes cannot gain new privileges     0.0
✔ SystemCallFilter=                   Service has restricted system calls              0.0
✔ MemoryDenyWriteExecute=             Service cannot create writable/executable memory 0.0

→ Overall exposure level for hardened-worker.service: 0.2 OK 🙂
```

---

#### Verification Questions (Exercise 1)

1. Why did the file write to `/etc/test_tamper.txt` fail with `Read-only file system` even if the process was executed as `root` (prior to setting `User=nobody`)?
2. Which explicit kernel feature is enabled by `NoNewPrivileges=yes`, and what security attack vector does it completely mitigate?

---

### Exercise 2: Advanced Linux Audit Framework (`auditd`) Implementation

In this exercise, you will deploy custom kernel audit rules to trace root shell executions, detect unauthorized privilege changes on sensitive identity files, and query audit events using `ausearch` and `aureport`.

#### Step 1: Configure persistent kernel audit rules
Edit `/etc/audit/rules.d/audit.rules` (or `/etc/audit/rules.d/operations_security.rules`) to append operational security watches and system call tracing.

```bash
sudo tee /etc/audit/rules.d/operations_security.rules > /dev/null << 'EOF'
## Delete all existing rules
-D

## Set buffer size (events)
-b 8192

## Failure Mode: 1=log, 2=panic
-f 1

## Watch critical configuration files for writes, executions, and attribute changes
-w /etc/passwd -p wa -k identity_tamper
-w /etc/shadow -p wa -k identity_tamper
-w /etc/sudoers -p wa -k privilege_tamper
-w /etc/sudoers.d/ -p wa -k privilege_tamper

## Monitor privilege escalation syscalls (execve by root/euid 0)
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_command_execution
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_command_execution

## Make rules immutable until reboot
-e 2
EOF
```

#### Step 2: Load audit rules into kernel space and verify active configuration
Restart the `auditd` service (or execute `augenrules --load`) and confirm active rules loaded in the kernel.

```bash
sudo augenrules --load
sudo auditctl -l
```

**Expected Output:**
```text
-w /etc/passwd -p wa -k identity_tamper
-w /etc/shadow -p wa -k identity_tamper
-w /etc/sudoers -p wa -k privilege_tamper
-w /etc/sudoers.d/ -p wa -k privilege_tamper
-a always,exit -F arch=b64 -S execve -F euid=0 -k root_command_execution
-a always,exit -F arch=b32 -S execve -F euid=0 -k root_command_execution
-e 2
```

#### Step 3: Generate security events and trace raw log entries
Execute commands that trigger both file write watches and `execve` auditing.

```bash
# Trigger privilege_tamper watch
sudo touch /etc/sudoers.d/99_ops_test

# Query raw events using key identity
sudo ausearch -k privilege_tamper --raw | head -n 20
```

**Expected Output:**
```text
type=PROCTITLE msg=audit(1786109430.123:402): proctitle=746F756368002F6574632F7375646F6572732E642F39395F6F70735F74657374
type=PATH msg=audit(1786109430.123:402): item=1 name="/etc/sudoers.d/99_ops_test" inode=131089 dev=08:01 mode=0100644 ouid=0 ogid=0 rdev=00:00 nametype=CREATE cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_fpver=0
type=PATH msg=audit(1786109430.123:402): item=0 name="/etc/sudoers.d/" inode=131075 dev=08:01 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_fpver=0
type=CWD msg=audit(1786109430.123:402): cwd="/home/administrator"
type=SYSCALL msg=audit(1786109430.123:402): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=7ffd2a1b9e84 a2=941 a3=1b6 items=2 ppid=1120 pid=12890 auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=2 comm="touch" exe="/usr/bin/touch" key="privilege_tamper"
```

#### Step 4: Generate a high-level summary audit report
Execute `aureport` to generate operational summary statistics for key events and executables.

```bash
sudo aureport -k --summary
```

**Expected Output:**
```text
Key Summary Report
===============================================
# date time key rows
===============================================
1. 08/06/2026 13:30:30 privilege_tamper 1
2. 08/06/2026 13:30:30 root_command_execution 14
```

---

#### Verification Questions (Exercise 2)

1. What is the operational impact of setting `-e 2` in `/etc/audit/rules.d/operations_security.rules`? How must an SRE make subsequent audit rule modifications?
2. In the `SYSCALL` audit event log, what is the precise distinction between `uid`, `euid`, and `auid`?

---

### Exercise 3: File Integrity Monitoring (FIM) with AIDE

In this exercise, you will configure AIDE to baseline system binary and configuration directories, build the cryptographic database, simulate an unauthorized system file modification, and analyze degradation reports.

#### Step 1: Install and configure AIDE rule specifications
Install AIDE and edit `/etc/aide/aide.conf` to establish strict cryptographic scanning definitions.

```bash
# On Debian/Ubuntu systems: sudo apt-get install -y aide
# On RHEL/Rocky Linux: sudo dnf install -y aide

sudo tee -a /etc/aide/aide.conf > /dev/null << 'EOF'

# Custom Operational Security Rule Definitions
# p: permissions, i: inode, n: number of links, u: user, g: group, s: size, m: mtime, c: ctime, md5: md5 checksum, sha512: sha512 checksum
OPS_SEC_STRICT = p+i+n+u+g+s+m+c+sha512

# Watch paths
/usr/bin OPS_SEC_STRICT
/usr/sbin OPS_SEC_STRICT
/etc/pam.d OPS_SEC_STRICT
!/var/log
!/tmp
EOF
```

#### Step 2: Initialize baseline database and activate production DB
Initialize the cryptographic hash database and move it into production operational state.

```bash
sudo aide --init
sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

#### Step 3: Simulate unauthorized file alteration / Trojan insertion
Modify a watched system binary at `/usr/bin/login` or append a string to `/etc/pam.d/common-auth`.

```bash
# Simulate a backdoor comment injection into a core PAM configuration file
echo "# Unauthorized modification by intruder" | sudo tee -a /etc/pam.d/common-auth > /dev/null
```

#### Step 4: Execute integrity check and parse deviation results
Run `aide --check` to compare current host state against the baseline.

```bash
sudo aide --check
```

**Expected Output:**
```text
AIDE 0.18 found differences between the database and the filesystems!
Start timestamp: 2026-08-06 13:35:00

Summary:
  Total number of entries: 4521
  Added entries:           0
  Removed entries:         0
  Changed entries:         1

---------------------------------------------------
Changed entries:
---------------------------------------------------

f =...C..a.. : /etc/pam.d/common-auth

---------------------------------------------------
Detailed information about changes:
---------------------------------------------------

File: /etc/pam.d/common-auth
 Size     : 1420                             , 1461
 MTime    : 2026-08-06 12:00:00.000000000    , 2026-08-06 13:34:55.123456789
 CTime    : 2026-08-06 12:00:00.000000000    , 2026-08-06 13:34:55.123456789
 SHA512   : e3b0c44298fc1c149afbf4c8996fb924 , 9b74c2d8292c29c8e8ec434237198e0e
            b2d71597f7481a7b1b369c733ee04746   7730e201b17b2b694b294e339d0c6792
```

---

#### Verification Questions (Exercise 3)

1. If an attacker modifies `/etc/pam.d/common-auth` and then updates the file's `mtime` back to its original timestamp using `touch -m -t`, why will AIDE still flag the file as altered?
2. Why must the production baseline database `aide.db.gz` be transferred to a read-only medium or write-once remote storage (e.g., AWS S3 Bucket with Object Lock) in production SRE environments?

---

### Exercise 4: Automated Compliance & Vulnerability Auditing via OpenSCAP

In this exercise, you will execute an automated SCAP Security Guide compliance scan against the Center for Internet Security (CIS) / DISA STIG benchmark using `oscap`, generate a shell remediation script, and analyze compliance metrics.

#### Step 1: Install OpenSCAP tooling and SCAP Security Guide content
Ensure OpenSCAP CLI binaries and SSG data-streams are installed.

```bash
# On RHEL/Rocky Linux: sudo dnf install -y openscap-scanner scap-security-guide
# On Debian/Ubuntu: sudo apt-get install -y libopenscap8 ssg-debian OR ssg-ubuntu

# Locate installed DataStream XML file
DS_PATH="/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
[ ! -f "$DS_PATH" ] && DS_PATH="/usr/share/xml/scap/ssg/content/ssg-ubuntu2204-ds.xml"
echo "[+] Using DataStream: $DS_PATH"
```

#### Step 2: List available security profiles in the DataStream
Query the profiles supported by the installed DataStream.

```bash
oscap info "$DS_PATH" | grep -E "Id: profile"
```

**Expected Output (Truncated):**
```text
        Id: profile_cis
        Id: profile_cis_server_l1
        Id: profile_cis_workstation_l1
        Id: profile_pci_dss
        Id: profile_disa_stig
```

#### Step 3: Run XCCDF evaluation scan and generate HTML report
Run an automated audit against the `cis_server_l1` profile and capture XML results and an interactive HTML report.

```bash
sudo oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  --results /tmp/scan_results.xml \
  --report /tmp/security_report.html \
  "$DS_PATH"
```

**Expected Output (Truncated CLI stdout):**
```text
Title   Ensure /tmp is Located On a Separate Partition
Rule    xccdf_org.ssgproject.content_rule_mount_option_tmp_separate_partition
Result  fail

Title   Ensure SSH Protocol 2 is Enforced
Rule    xccdf_org.ssgproject.content_rule_sshd_allow_only_protocol2
Result  pass

Title   Ensure Password Expiration 365 Days or Less
Rule    xccdf_org.ssgproject.content_rule_accounts_maximum_age_login_defs
Result  fail

OpenSCAP Evaluation Finished. Results written to /tmp/scan_results.xml.
Report written to /tmp/security_report.html.
```

#### Step 4: Generate automated bash remediation script from evaluation results
Generate an actionable fix script containing exact commands to remediate failed audit checks.

```bash
sudo oscap xccdf generate fix \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  --fix-type bash \
  --output /tmp/remediate_compliance.sh \
  /tmp/scan_results.xml

head -n 25 /tmp/remediate_compliance.sh
```

**Expected Output (Truncated):**
```bash
#!/bin/bash
# OpenSCAP Automated Fix Script
# Profile: CIS Server Level 1 Benchmark

echo "Applying fix for rule: xccdf_org.ssgproject.content_rule_accounts_maximum_age_login_defs"
if grep -q "^PASS_MAX_DAYS" /etc/login.defs; then
	sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 365/' /etc/login.defs
else
	echo "PASS_MAX_DAYS 365" >> /etc/login.defs
fi
```

---

#### Verification Questions (Exercise 4)

1. What is the fundamental difference between **OVAL (Open Vulnerability and Assessment Language)** definitions and **XCCDF (Extensible Configuration Checklist Description Format)** structures inside a SCAP DataStream package?
2. Why is executing an automatically generated OpenSCAP remediation script (`remediate_compliance.sh`) directly in a live production environment considered an anti-pattern, and how should SREs deploy fixes safely?

---

<details>
<summary><strong>Click here to reveal Solutions & Detailed Technical Answers</strong></summary>

### Exercise 1 Solutions

1. **Failure Mechanics of Read-only Write Attempt**:  
   Setting `ProtectSystem=strict` creates a new mount namespace for the service's process tree and remounts `/usr`, `/boot`, and `/etc` (plus `/sys` and `/proc` in hardened modes) as **Read-Only (`MS_RDONLY`)**. Even if a process runs with effective UID 0 (root), kernel filesystem operations are blocked at the VFS (Virtual File System) layer before capability checks (`CAP_DAC_OVERRIDE`) are evaluated. Root privileges cannot override a read-only VFS mount constraint.

2. **NoNewPrivileges Kernel Mechanics**:  
   `NoNewPrivileges=yes` sets the kernel flag `PR_SET_NO_NEW_PRIVS` via `prctl()`. This flag is inherited across `execve()` calls and cannot be unset. It guarantees that child processes cannot acquire elevated privileges through SUID/SGID executable bits (e.g., `/usr/bin/sudo` or custom setuid binaries) or file capabilities. This neutralizes local privilege escalation (LPE) exploits that rely on abusing SUID executables.

---

### Exercise 2 Solutions

1. **Impact of Kernel Rule Immutability (`-e 2`)**:  
   The rule `-e 2` locks the audit configuration inside kernel memory. Once loaded, audit rules can no longer be modified, added, or deleted via `auditctl` or `augenrules`, nor can the audit daemon be disabled without a full kernel reboot. To apply modified audit rules, an SRE must update `/etc/audit/rules.d/` files and perform an orderly host reboot.

2. **User Identity Attributes in Audit Logs**:
   - `uid`: Real User ID of the process executing the command.
   - `euid`: Effective User ID under which the current call executes (e.g., `0` when executing via `sudo`).
   - `auid` (Audit ID / Login UID): The original user identity recorded by `pam_loginuid` upon initial login (SSH, TTY, or console). Even if a user executes `su` or `sudo` to switch identities multiple times, `auid` remains pinned to their initial authenticated identity, ensuring non-repudiation during incident investigation.

---

### Exercise 3 Solutions

1. **AIDE Detection Beyond Timestamps**:  
   AIDE evaluates multiple metadata fields and cryptographic hashes. Modifying a file alters its inode status change time (`ctime`), which cannot be manipulated by standard userspace tools (`touch` only updates `atime` and `mtime`). Furthermore, AIDE checks the cryptographic $SHA512$ content digest. Since SHA-512 is collision-resistant, altering file content alters the computed digest regardless of timestamp manipulation.

2. **Database Hardening Rationale**:  
   If an attacker achieves root access on a target node, they can modify `/etc/pam.d/common-auth` and subsequently recompute and overwrite `/var/lib/aide/aide.db.gz` to mask their modifications. Transporting the baseline database to immutable/read-only storage ensures the integrity verification tool evaluates live host state against an untampered benchmark source.

---

### Exercise 4 Solutions

1. **OVAL vs. XCCDF Roles in SCAP**:
   - **XCCDF**: High-level structured framework for specifying security checklists, benchmarks, human-readable rules, and compliance profiles. It defines *what* configuration states should exist.
   - **OVAL**: The low-level technical assertion engine. OVAL provides machine-executable XML schemas that check specific system states (e.g., checking specific package versions, system file permissions, or registry keys via kernel probes). XCCDF references OVAL checks to determine pass/fail states.

2. **Remediation Script Operational Risks**:  
   Blinded execution of auto-generated remediation scripts can severely degrade production systems by altering network parameters (e.g., locking down active network interfaces), changing permissions on critical operational data directories, or breaking legacy applications. SRE best practices require translating OpenSCAP findings into idempotent Configuration Management code (Ansible, Puppet, Terraform) tested within CI/CD pipelines before deployment to production environments.

</details>