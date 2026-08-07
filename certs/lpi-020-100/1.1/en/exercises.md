# LPI Security Essentials (Exam 020-100) — Topic 1.1: Security Concepts

**Exam Target:** LPI Security Essentials (Exam Code: 020-100, Version 1.0)  
**Topic Weight:** 20  
**Official Reference:** [LPI Security Essentials Overview & Objectives](https://www.lpi.org/our-certifications/security-essentials-overview/)  
**Target Role:** Senior SRE / Platform Security Architect  

---

## Technical Overview & Core Architecture

Topic 1.1 establishes the foundational security principles required to architect and operate hardened Linux environments in modern production systems. This module focuses on operationalizing core frameworks rather than treating them as abstract theory:

1. **The CIA Triad (Confidentiality, Integrity, Availability):**
   - **Confidentiality:** Restricting access to authorized principals via DAC/MAC permissions, encryption at rest (LUKS/dm-crypt), and encryption in transit (TLS 1.3, SSH).
   - **Integrity:** Ensuring data remains uncorrupted and unmanipulated. Managed via cryptographic hashes (SHA-256/512), digital signatures (GPG/PGP), and immutable file flags (`chattr +i`).
   - **Availability:** Guaranteeing systems and services remain operational under load or attack. Implemented using cgroups v2 resource limits, systemd restart limits, HA load balancing, and Rate Limiting (`iptables`/`nftables` leaky bucket algorithms).

2. **The AAA Framework & Non-Repudiation:**
   - **Authentication (Who are you?):** PAM (`pam_unix`, `pam_faillock`), SSH Public Key Auth (ED25519), FIDO2/WebAuthn.
   - **Authorization (What can you do?):** Linux file modes, POSIX ACLs (`setfacl`), sudoers fine-grained access control, SELinux/AppArmor MAC policies.
   - **Accounting / Auditing (What did you do?):** Linux Audit Subsystem (`auditd`), `journald` structured logging, centralized log shipping over TLS (rsyslog/fluentbit).
   - **Non-Repudiation:** Ensuring an action cannot be denied by the performing actor through cryptographic signatures (GPG sign) and append-only, tamper-evident audit logs (`auditd` kernel rules linked to immutable storage).

3. **Defense in Depth & Least Privilege:**
   - **Least Privilege:** Default-deny posture. Restricting processes to the minimal Linux capabilities (`CAP_NET_BIND_SERVICE`, `CAP_SYS_ADMIN` removal) and file permissions needed for execution.
   - **Attack Surface Reduction:** Minimizing open network sockets, removing unnecessary binary packages, disabling unused kernel modules (`/etc/modprobe.d/`), and scoping systemd service units with strict isolation parameters (`ProtectSystem=strict`, `PrivateTmp=yes`, `NoNewPrivileges=yes`).

---

## Guided Laboratory Exercises

---

### Exercise 1: Demonstrating Integrity, Confidentiality, and Non-Repudiation with Cryptographic Controls

In this exercise, you will create a confidential asset, generate a cryptographic integrity checksum, implement append-only file immutability, and verify digital non-repudiation using GnuPG.

#### Step 1: Create a Secure Confidential Asset and Verify Permissions
Create a directory `/etc/secure_app/` restricted to `root` with `0700` permissions. Generate a configuration file containing sensitive database credentials.

```bash
sudo mkdir -p /etc/secure_app
sudo chmod 0700 /etc/secure_app
sudo tee /etc/secure_app/db.conf > /dev/null << 'EOF'
DB_HOST=127.0.0.1
DB_USER=app_prod
DB_PASS=u8F#kL2$mN9!vP0q
EOF
sudo chmod 0600 /etc/secure_app/db.conf
ls -la /etc/secure_app/db.conf
```

**Expected Output:**
```text
-rw------- 1 root root 64 Aug  7 00:40 /etc/secure_app/db.conf
```

#### Step 2: Establish an Integrity Baseline using SHA-256
Generate a cryptographic hash baseline of the file to satisfy the Integrity component of the CIA triad.

```bash
sha256sum /etc/secure_app/db.conf | sudo tee /etc/secure_app/db.conf.sha256
cat /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  /etc/secure_app/db.conf
```

#### Step 3: Enforce System-Level File Immutability
Use Linux ext4/xfs file attributes (`chattr`) to make the baseline immutable, preventing tampering even by the `root` account.

```bash
sudo chattr +i /etc/secure_app/db.conf.sha256
lsattr /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
----i---------e------- /etc/secure_app/db.conf.sha256
```

Test modifying the immutable file with `root` privileges:
```bash
sudo rm -f /etc/secure_app/db.conf.sha256
```

**Expected Output:**
```text
rm: cannot remove '/etc/secure_app/db.conf.sha256': Operation not permitted
```

#### Step 4: Digital Signature Generation for Non-Repudiation
Generate a batch GPG key pair for an administrator account and create a detached digital signature (`.sig`) for the configuration file.

```bash
gpg --batch --generate-key << 'EOF'
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: Security Auditor
Name-Email: auditor@production.local
Expire-Date: 0
%no-protection
%commit
EOF

gpg --detach-sign --armor /etc/secure_app/db.conf
ls -la /etc/secure_app/db.conf.asc
```

**Expected Output:**
```text
-rw-r--r-- 1 user user 838 Aug  7 00:41 /etc/secure_app/db.conf.asc
```

Verify signature integrity for non-repudiation:
```bash
gpg --verify /etc/secure_app/db.conf.asc /etc/secure_app/db.conf
```

**Expected Output:**
```text
gpg: Signature made Fri 07 Aug 2026 00:41:00 AM UTC
gpg:                using RSA key 4F8A9B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A
gpg: Good signature from "Security Auditor <auditor@production.local>" [ultimate]
```

---

#### Comprehension Check: Exercise 1

1. **Question 1.1:** An attacker gains full `root` shell access on the server via a remote code execution (RCE) vulnerability. They attempt to modify `/etc/secure_app/db.conf.sha256` to conceal a modified database configuration. Why does `rm -f` fail, and what sequence of commands must the attacker run to bypass this control?
2. **Question 1.2:** In terms of the AAA framework and Non-Repudiation, what is the critical technical difference between verifying a file using a SHA-256 hash versus verifying it with a GPG detached signature?

---

### Exercise 2: AAA Implementation — Least Privilege Authorization and Audit Logging

In this exercise, you will enforce the Principle of Least Privilege using granular `sudoers` rules and implement the Accounting arm of AAA using the Linux Audit Subsystem (`auditd`).

#### Step 1: Create a Restricted Service Administrator Role
Create a user named `deployer` without superuser access.

```bash
sudo useradd -m -s /bin/bash deployer
sudo id deployer
```

**Expected Output:**
```text
uid=1001(deployer) gid=1001(deployer) groups=1001(deployer)
```

#### Step 2: Write a Granular Sudoers Policy (Least Privilege)
Configure `/etc/sudoers.d/99-deployer` to allow `deployer` to reload and check the status of `nginx.service` **only**, without requiring a password, while explicitly denying arbitrary command execution or system shell spawns.

```bash
sudo tee /etc/sudoers.d/99-deployer > /dev/null << 'EOF'
Cmnd_Alias NGINX_MGMT = /bin/systemctl status nginx, /bin/systemctl reload nginx
deployer ALL=(root) NOPASSWD: NGINX_MGMT
EOF
sudo chmod 0440 /etc/sudoers.d/99-deployer
sudo visudo -c -f /etc/sudoers.d/99-deployer
```

**Expected Output:**
```text
/etc/sudoers.d/99-deployer: parsed OK
```

Validate permissions as user `deployer`:
```bash
sudo -u deployer sudo systemctl status nginx || true
sudo -u deployer sudo systemctl restart nginx
```

**Expected Output:**
```text
[sudo] password for deployer is required
# OR:
Sorry, user deployer is not allowed to execute '/bin/systemctl restart nginx' as root on hostname.
```

#### Step 3: Configure Kernel-Level Accounting via Auditd
Add an active audit rule targeting changes to `/etc/sudoers` and `/etc/sudoers.d/` directory.

```bash
sudo tee /etc/audit/rules.d/sudoers.rules > /dev/null << 'EOF'
-w /etc/sudoers -p wa -k privilege_escalation_changes
-w /etc/sudoers.d/ -p wa -k privilege_escalation_changes
EOF
sudo augenrules --load
sudo auditctl -l
```

**Expected Output:**
```text
-w /etc/sudoers -p wa -k privilege_escalation_changes
-w /etc/sudoers.d/ -p wa -k privilege_escalation_changes
```

#### Step 4: Trigger and Query Accounting Logs
Touch a temporary file inside `/etc/sudoers.d/` to trigger the kernel audit hook, then parse the log entry using `ausearch`.

```bash
sudo touch /etc/sudoers.d/.test_audit_trigger
sudo rm -f /etc/sudoers.d/.test_audit_trigger
sudo ausearch -k privilege_escalation_changes --raw | ausearch -m PATH -i
```

**Expected Output:**
```text
type=PROCTITLE msg=audit(08/07/2026 00:43:12.104:482) : proctitle=touch /etc/sudoers.d/.test_audit_trigger 
type=PATH msg=audit(08/07/2026 00:43:12.104:482) : item=0 name=/etc/sudoers.d/.test_audit_trigger inode=262145 dev=08:01 mode=file,644 ouid=root ogid=root rdev=00:00 nametype=CREATE cap_fp=none cap_fi=none cap_fe=0 cap_fver=0 cap_innermost_rootuid=-1
type=SYSCALL msg=audit(08/07/2026 00:43:12.104:482) : arch=x86_64 syscall=openat success=yes exit=3 a0=AT_FDCWD a1=0x7ffe92a1b090 a2=O_CREAT|O_WRONLY|O_NOCTTY|O_NONBLOCK a3=0666 items=2 ppid=1234 pid=5678 auid=admin uid=root gid=root euid=root suid=root fsuid=root egid=root sgid=root fsgid=root tty=pts0 ses=1 comm=touch exe=/usr/bin/touch key=privilege_escalation_changes
```

---

#### Comprehension Check: Exercise 2

1. **Question 2.1:** Look at the `ausearch` output above. Identify the field that guarantees non-repudiation by showing the original user who logged in, even though the command was executed with `euid=root`.
2. **Question 2.2:** A junior administrator modifies `/etc/sudoers.d/99-deployer` to:  
   `deployer ALL=(ALL) NOPASSWD: /bin/systemctl *`  
   Explain why this violates the Principle of Least Privilege and describe how an attacker can leverage this specific wildcard rule to gain an interactive `root` shell.

---

### Exercise 3: Attack Surface Reduction & Defense in Depth via Systemd Sandboxing

In this exercise, you will analyze the attack surface of a system service, audit its security score, and implement systemd hardening properties to enforce Defense in Depth.

#### Step 1: Analyze Service Attack Surface using systemd-analyze
Run a security assessment against an unhardened instance of an example service (e.g., `systemd-journal-upload.service` or custom web service).

```bash
systemd-analyze security systemd-journal-upload.service | head -n 15
```

**Expected Output:**
```text
NAME                                  PART DESCRIPTION                              EXPOSURE
✔ PrivateNetwork=                     Service has access to network
❌ User=/Group=                        Service runs as root user                         9.2
❌ CapabilityBoundingSet=              Service has all capabilities                      0.2
❌ ProtectSystem=                      Service has full access to OS file system         0.2
❌ ProtectHome=                        Service has full access to home directories       0.2
...
OVERALL EXPOSURE LEVEL: 8.6 UNSAFE 🔴
```

#### Step 2: Implement Hardening Controls via Systemd Drop-in
Create a drop-in override configuration at `/etc/systemd/system/systemd-journal-upload.service.d/override.conf` applying strict sandboxing parameters.

```bash
sudo mkdir -p /etc/systemd/system/systemd-journal-upload.service.d/
sudo tee /etc/systemd/system/systemd-journal-upload.service.d/override.conf > /dev/null << 'EOF'
[Service]
# Reduce filesystem exposure (Integrity & Confidentiality)
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=/

# Reduce privilege escalation vectors (Least Privilege)
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Kernel and System Isolation (Defense in Depth)
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
EOF

sudo systemctl daemon-reload
```

#### Step 3: Re-evaluate Service Exposure Score
Re-evaluate the security rating of the service to verify attack surface reduction.

```bash
systemd-analyze security systemd-journal-upload.service | head -n 15
```

**Expected Output:**
```text
NAME                                  PART DESCRIPTION                              EXPOSURE
✔ PrivateTmp=                         Service has private /tmp directory
✔ ProtectSystem=                      Service has strict access to OS file system
✔ ProtectHome=                        Service has no access to home directories
✔ NoNewPrivileges=                    Service cannot elevate privileges
✔ CapabilityBoundingSet=              Service capabilities strictly bounded
...
OVERALL EXPOSURE LEVEL: 2.1 OK 🟢
```

---

#### Comprehension Check: Exercise 3

1. **Question 3.1:** What vulnerability mechanism does `NoNewPrivileges=yes` block at the Linux kernel level, and how does this support the Principle of Least Privilege?
2. **Question 3.2:** Contrast the defense mechanisms of `ProtectSystem=strict` and `ProtectKernelTunables=yes`. Which Linux kernel features do these settings restrict?

---

<details>
<summary><strong>Click to expand Answer Key & Technical Explanations</strong></summary>

### Exercise 1 Answer Key

* **1.1:** 
  - `rm -f` fails because the `+i` (immutable) attribute set by `chattr` sets the `FS_IMMUTABLE_FL` flag on the inode in the underlying filesystem driver (ext4/xfs). The VFS layer rejects write, unlink, rename, and link operations for this inode regardless of EUID `0` (root).
  - To bypass this, a compromised `root` account must explicitly clear the attribute first using:
    `sudo chattr -i /etc/secure_app/db.conf.sha256`
    followed by the modification/deletion command. *(Note: If kernel capabilities are restricted via `CapabilityBoundingSet=~CAP_LINUX_IMMUTABLE` or SELinux policy, even root cannot strip the immutable flag).*

* **1.2:** 
  - **SHA-256 Hash:** Provides **Integrity** verification only. It proves whether the file contents have changed, but provides no proof of origin because anyone with write access can recompute and replace the SHA-256 digest.
  - **GPG Detached Signature:** Provides **Integrity**, **Authentication**, and **Non-Repudiation**. The digest of the file is encrypted using the author's asymmetric Private Key. Only the holder of the matching Private Key could have generated the signature. Therefore, the signer cannot deny authoring the document (Non-Repudiation), and consumers can verify authenticity using the Public Key.

---

### Exercise 2 Answer Key

* **2.1:**
  - The `auid` (Audit User ID / loginuid) field.
  - When a user logs in (e.g., `auid=1000`), the kernel locks `auid` into the process task structure. Even if the user executes `su`, `sudo`, or exploits a setuid binary changing their operational `uid`/`euid` to `0` (root), `auid` remains pinned to `1000`. This ensures deterministic **Accounting** and **Non-Repudiation** in system logs.

* **2.2:**
  - **Violation of Least Privilege:** `systemctl *` grants access to all systemd manager commands, not just service lifecycle status/reloads.
  - **Exploitation Vector:** An attacker can use `systemctl` features to elevate privileges to root in multiple ways:
    1. Executing `sudo systemctl edit service_name --full` which invokes an interactive editor (e.g., `SYSTEMD_EDITOR=/bin/bash sudo systemctl edit`), instantly dropping into a root shell.
    2. Creating/running a custom transient unit via `sudo systemctl run` or loading a malicious service unit containing `ExecStart=/bin/bash -c "chmod +s /bin/bash"`.

---

### Exercise 3 Answer Key

* **3.1:**
  - `NoNewPrivileges=yes` sets the `PR_SET_NO_NEW_PRIVS` bit on the service process state via `prctl()`.
  - Once set, child processes created via `execve()` cannot acquire execution privileges that the parent process did not already possess. This effectively disables the execution of **SUID/SGID** binaries (like `/usr/bin/sudo` or `/usr/bin/gpasswd`) and prevents File System Capabilities (`setcap`) from granting elevated privileges during execution.

* **3.2:**
  - **`ProtectSystem=strict`:** Uses Mount Namespaces (`CLONE_NEWNS`) to mount the entire host filesystem file tree (`/`, `/usr`, `/boot`, `/etc`) as Read-Only (`MS_RDONLY`) for the service process, isolating application binaries and configuration files from unauthorized modifications.
  - **`ProtectKernelTunables=yes`:** Mounts virtual procfs and sysfs system directories (`/proc/sys`, `/sys`, `/proc/sysrq-trigger`, `/proc/latency_stats`) as read-only. This prevents a compromised service from altering runtime kernel parameters (e.g., sysctl variables like `net.ipv4.ip_forward` or memory management settings).

</details>