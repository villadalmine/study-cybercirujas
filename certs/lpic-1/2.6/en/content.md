# Topic 2.6: Security (LPIC-1)

## 1. Motivation and Production Architectural Problem

In a modern distributed architecture, the perimeter is porous, and zero-trust principles must be enforced at the host level. If a single bastion host or application server is compromised, the blast radius depends entirely on internal host security. Poorly configured `sudo` privileges, exposed listening sockets, orphaned SSH keys, and unnecessarily elevated processes (SUID binaries) turn a minor vulnerability into full cluster compromise.

The architectural problem is managing authentication, authorization, and encryption deterministically and securely across thousands of nodes. As a Platform Architect, you must eliminate standing privileges (moving to ephemeral, strictly scoped `sudo`), enforce strong encryption for data in transit (OpenSSH/GnuPG), and implement defense-in-depth by auditing listening ports (`ss`/`lsof`) and limiting resource exhaustion attacks (`ulimit`).

## 2. Technical Comparisons and Trade-offs

### Privilege Escalation: `su` vs. `sudo`

| Feature | `su` (Substitute User) | `sudo` (Superuser DO) |
| :--- | :--- | :--- |
| **Authentication** | Requires the target user's password (e.g., the `root` password). | Requires the invoking user's own password (or no password if configured). |
| **Granularity** | All or nothing. Grants a full shell as the target user. | Highly granular. Can restrict commands, arguments, and target users. |
| **Auditing** | Difficult. Once in the `root` shell, individual commands are not tied to the original user in syslog. | Excellent. Every command is logged to syslog with the invoking user's identity. |

### Data Encryption: GnuPG vs. OpenSSH

| Feature | GnuPG (GPG) | OpenSSH |
| :--- | :--- | :--- |
| **Primary Use Case** | Data at rest (file encryption), digital signatures (commits, packages). | Data in transit (secure terminal, port forwarding, SFTP). |
| **Trust Model** | Web of Trust (WoT) or explicit key import. | Trust on First Use (TOFU) or explicit Certificate Authorities (SSH CA). |
| **Key Types** | RSA, DSA, ECC, Ed25519 (often combined in subkeys). | RSA, ECDSA, Ed25519. |

## 3. Infrastructure as Code: Host Security Configuration

In production, you never edit `/etc/sudoers` manually. You deploy strict, validated configurations using configuration management to ensure predictable authorization.

### Ansible Playbook: `host-security.yaml`

This playbook enforces strict SSH configurations, deploys granular `sudo` rules, and secures the `root` account.

```yaml
---
- name: Hardening Linux Host Security
  hosts: all
  become: yes
  tasks:
    - name: Lock the root account password (disable direct login)
      user:
        name: root
        password_lock: yes

    - name: Deploy granular sudoers configuration for SREs
      copy:
        dest: /etc/sudoers.d/90-sre-admin
        # Validate syntax before applying to prevent locking out administrators
        validate: /usr/sbin/visudo -csf %s
        content: |
          # SREs can restart web services without a password
          %sre_team ALL=(root) NOPASSWD: /bin/systemctl restart nginx.service
          # SREs can run tcpdump for debugging, requires password
          %sre_team ALL=(root) /usr/sbin/tcpdump
        mode: '0440'

    - name: Harden OpenSSH Server Configuration
      copy:
        dest: /etc/ssh/sshd_config.d/99-hardening.conf
        content: |
          PermitRootLogin no
          PasswordAuthentication no
          X11Forwarding no
          AllowGroups sre_team
          # Use modern, secure ciphers and MACs
          KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
          MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
        mode: '0600'
      notify: Restart SSHD

    - name: Set strict resource limits to prevent fork bombs (ulimit)
      copy:
        dest: /etc/security/limits.d/20-nproc.conf
        content: |
          # Limit number of processes for all users except root
          *          hard    nproc     4096
          *          soft    nproc     1024
          root       hard    nproc     unlimited

  handlers:
    - name: Restart SSHD
      systemd:
        name: sshd
        state: restarted
```

## 4. CLI Commands and Terminal Outputs

### 4.1 Auditing Listening Ports and Files (`lsof` and `ss`)

A critical security task is verifying that only expected services are listening on network interfaces.

```bash
$ sudo ss -tlnp
State    Recv-Q   Send-Q     Local Address:Port      Peer Address:Port   Process                                     
LISTEN   0        128              0.0.0.0:22             0.0.0.0:*       users:(("sshd",pid=900,fd=3))
LISTEN   0        511              0.0.0.0:443            0.0.0.0:*       users:(("nginx",pid=1200,fd=6))
```

Identify which process has a specific file or network socket open using `lsof` (List Open Files):

```bash
$ sudo lsof -i :22
COMMAND PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
sshd    900 root    3u  IPv4  12345      0t0  TCP *:ssh (LISTEN)
```

### 4.2 Finding SUID and SGID Binaries

SUID (Set User ID) allows a program to execute with the privileges of the file's owner (usually root). Attackers target vulnerable SUID binaries to escalate privileges.

Find all SUID binaries on the system:
```bash
$ sudo find / -perm -4000 -type f -exec ls -l {} \; 2>/dev/null
-rwsr-xr-x 1 root root 68208 May 28  2020 /usr/bin/passwd
-rwsr-xr-x 1 root root 85064 Jul 14  2021 /usr/bin/chfn
-rwsr-xr-x 1 root root 166056 Jan 19  2021 /usr/bin/sudo
```
*(Note the `s` in the owner's execute permission bit).*

### 4.3 SSH Key Management

Generate a modern, highly secure Ed25519 SSH key pair:

```bash
$ ssh-keygen -t ed25519 -C "admin@production"
Generating public/private ed25519 key pair.
Enter file in which to save the key (/home/admin/.ssh/id_ed25519): 
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
Your identification has been saved in /home/admin/.ssh/id_ed25519
Your public key has been saved in /home/admin/.ssh/id_ed25519.pub
```

Start the SSH Agent and add the key to avoid typing the passphrase multiple times:
```bash
$ eval $(ssh-agent -s)
Agent pid 15000
$ ssh-add ~/.ssh/id_ed25519
Enter passphrase for /home/admin/.ssh/id_ed25519: 
Identity added: /home/admin/.ssh/id_ed25519 (admin@production)
```

## 5. Troubleshooting and Fault Diagnosis

### Scenario A: Sudo Syntax Error Causes Lockout
**Symptoms:** You edited `/etc/sudoers` manually using `vi` instead of `visudo`. Now, when you try to run any `sudo` command, it fails with a parse error, and you cannot switch to root to fix it.
**Diagnosis:**
```bash
$ sudo ls
>>> /etc/sudoers: syntax error near line 25 <<<
sudo: parse error in /etc/sudoers near line 25
sudo: no valid sudoers sources found, quitting
```
**Resolution:** This is a critical failure. If there is no `root` password set, you must reboot the system, interrupt the GRUB bootloader, append `init=/bin/bash` or `systemd.unit=rescue.target` to the kernel line, boot into a single-user root shell, remount the filesystem as read-write, and use `visudo` to fix the syntax error. *Always use `visudo` to prevent this.*

### Scenario B: SSH Connection Refused (Authentication)
**Symptoms:** `ssh admin@server` fails with `Permission denied (publickey)`.
**Diagnosis:**
1. Run SSH in verbose mode to see the handshake:
   ```bash
   $ ssh -v admin@server
   ...
   debug1: send_pubkey_test: no mutual signature algorithm
   ```
2. Check the server's `/var/log/auth.log` (or `journalctl -u ssh`).
   ```bash
   $ journalctl -u ssh
   sshd[1234]: User admin not allowed because not listed in AllowGroups
   ```
**Resolution:** The user is attempting to authenticate, but their public key is not in `~/.ssh/authorized_keys`, or the user is not a member of the group specified in `AllowGroups` in `sshd_config`. Add the user to the correct group: `sudo usermod -aG sre_team admin`.

### Scenario C: Resource Exhaustion (Too Many Open Files)
**Symptoms:** A database or web server crashes with `Too many open files`.
**Diagnosis:**
The process hit its file descriptor limit (`ulimit -n`).
Check the hard and soft limits for the running process:
```bash
$ cat /proc/<PID>/limits | grep "Max open files"
Max open files            1024                 4096                 files
```
**Resolution:** Edit `/etc/security/limits.conf` (or a file in `/etc/security/limits.d/`) to increase the `nofile` (number of open files) limit for the specific user running the service, then restart the service. Alternatively, set `LimitNOFILE=65536` directly in the systemd service unit.

## 6. References

- Sudoers Manual: https://www.sudo.ws/docs/man/sudoers.man/
- OpenSSH Hardening Guide: https://infosec.mozilla.org/guidelines/openssh
- GNU Privacy Guard (GnuPG): https://gnupg.org/documentation/
- PAM Limits Configuration: https://linux.die.net/man/5/limits.conf
- LPIC-1 Exam Objectives: https://www.lpi.org/our-certifications/exam-101-objectives/