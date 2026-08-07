# Topic 711.5: BSD Kernel Parameters and System Security Level (LPI-702 Exam 702-100)

**Weight:** 3.33  
**Target Certification:** LPI BSD Specialist (Exam 702-100, Version 1.0)  
**Role Context:** Principal Platform Architect & Senior SRE Instructor  

---

## 1. Motivation and Architectural Production Problem

In multi-tenant cloud platforms, edge routing clusters, and mission-critical financial ledger environments, OS-level kernel integrity and runtime tunable management form the foundational layer of defense-in-depth architecture. 

A compromise of the `root` (UID 0) user in standard Unix-like operating systems typically grants unrestricted privilege: an attacker can inject arbitrary kernel modules (`kldload` / `insmod`), overwrite physical memory pointers via raw memory access devices (`/dev/mem`, `/dev/kmem`), bypass packet filtering rules (`pfctl`), unmount underlying storage volumes, or tamper with system logs by unsetting immutable file attributes (`chflags`).

```
                              +-------------------------------------------------------+
                              |                  SUPERUSER (UID 0)                    |
                              +-------------------------------------------------------+
                                                          |
                                                          v
                                       +-------------------------------------+
                                       |      System Security Level          |
                                       |      (kern.securelevel MIB)         |
                                       +-------------------------------------+
                                                          |
                   +--------------------------------------+--------------------------------------+
                   |                                      |                                      |
                   v                                      v                                      v
        [ Securelevel = 0 ]                    [ Securelevel = 1 ]                    [ Securelevel = 2/3 ]
    (Development / Maintenance)                   (Standard Production)                 (Hardened Edge / Financial)
- Full raw disk write access            - Raw disk write blocked on mounted FS - Raw disk write blocked on ALL disks
- Module load/unload allowed            - Kernel module loading prohibited     - Time adjustments restricted
- Immutable flags modification allowed  - File system immutable flags enforced - Firewall rules (PF/IPFW) locked
```

### The Architectural Problem
1. **Dynamic Runtime Configuration vs. Immutable Kernel Constraints:** Systems must dynamically scale socket buffers, TCP parameters, network queue lengths, and Virtual Memory (VM) pages at runtime without requiring kernel rebuilds. However, critical system state variables must be protected from dynamic tampering after boot sequence completion.
2. **Post-Exploitation Containment:** If a web application vulnerability allows command injection as `root`, standard kernel ring-0 isolation is ineffective if `root` can modify kernel memory directly or modify system security controls.
3. **Boot-Time Initialization Sequencing:** Certain kernel parameters (such as physical hardware tunables, system memory allocations, and CPU topology masks) must be initialized during early loader execution (*before* the BSD kernel mounts the root filesystem), while runtime MIB parameters must be configured after initialization.

BSD addresses this challenge through two coupled subsystems:
- **`sysctl(3)` MIB (Management Information Base) Subsystem:** A structural tree of kernel state variables allowing dynamic runtime inspection, modification, and early boot-time initialization.
- **`kern.securelevel` Enforcement Engine:** A monotonic, one-way state machine enforced by the BSD kernel ring-0 protection logic that systematically revokes kernel capabilities from UID 0 as the system state transitions from single-user boot mode to multi-user production execution.

---

## 2. Deep Technical Mechanics & Trade-off Comparisons

### 2.1 The `sysctl` MIB Subsystem Architecture

The BSD kernel exposes state variables via a hierarchical Management Information Base (MIB). Nodes in the MIB are defined using integer arrays or dot-delimited string paths (`sysctlbyname`).

#### Key MIB Top-Level Namespaces
* `kern.*`: Core kernel subsystems (process limits, hostname, IPC, securelevel, boot phase).
* `vm.*`: Virtual memory subsystem (page cache, swap, zfs arc limits, pageout daemon tuning).
* `net.*`: Networking stack (socket buffers, IP routing, TCP/UDP behavior, BPF filters).
* `hw.*`: Hardware attributes (CPU count, memory architecture, byte order, device topology).
* `security.*`: Security policies (MAC framework, ASLR, jailed process constraints).
* `vfs.*`: Virtual File System tunables and filesystem statistics.

#### Distinguishing Kernel Tunables vs. Dynamic `sysctl` MIBs
Kernel state variables in BSD are categorized by their write lifecycle:

1. **Boot Loader Tunables (`/boot/loader.conf`):**
   * Configured by the stage-3 bootloader (`loader(8)`) before kernel boot execution.
   * Modifies memory allocation tables, device driver bindings, or fundamental hardware limits.
   * Read-only at runtime via `sysctl` (cannot be changed with `sysctl name=value`).
2. **Dynamic MIB Parameters (`/etc/sysctl.conf`):**
   * Processed during the standard boot sequence by `/etc/rc.d/sysctl`.
   * Can be read and modified dynamically at runtime using the `sysctl` utility or `sysctl(3)` C API, provided the current `kern.securelevel` permits modifications.
3. **Static Read-Only MIB Parameters:**
   * Exposed by the kernel to reflect static system properties (e.g., `hw.ncpu`, `kern.ostype`). Cannot be modified at runtime or in config files.

---

### 2.2 System Security Levels (`kern.securelevel`) Mechanics

The system security level is controlled by the `kern.securelevel` dynamic MIB variable. It acts as an irreversible privilege-reduction ratchet.

```
       Boot Loader Init              System Initialization                    Manual Down-Level
[ Level -1: Permanently Insecure ] ----> [ Level 0: Insecure / Single-User ] ----> [ Reboot / Init 1 ]
                                                  |
                                                  | Multi-user boot / rc script
                                                  v
                                       [ Level 1: Secure Mode ]
                                                  |
                                                  | Explicit sysctl escalation
                                                  v
                                       [ Level 2: Highly Secure ]
                                                  |
                                                  | Explicit sysctl escalation
                                                  v
                                       [ Level 3: Network Secure ]
```

#### Monotonic Constraint Rule
* **Upward Escalation:** The security level can be increased at any time by the superuser (`sysctl kern.securelevel=N`, where $N_{new} > N_{current}$).
* **Downward Restriction:** The security level **cannot** be decreased while the system is running in multi-user mode. Attempting to set `sysctl kern.securelevel=0` when `kern.securelevel` is `1` will result in `Operation not permitted` (`EPERM`), even for `root`.
* **State Reset:** Decreasing the securelevel requires a system reboot or lowering to single-user mode via console access (`init 1`).

#### Detailed Security Level Matrix

| Security Level | Name | Permitted Actions | Enforced Restrictions & Kernel Safeguards |
| :--- | :--- | :--- | :--- |
| **-1** | Permanently Insecure | Full system administrative access; dynamic module loading; raw memory access. | Kernel securelevel enforcement is **disabled**. Securelevel changes requested via rc.conf or sysctl are ignored at boot. Used in embedded systems or development environments where continuous module debugging is required. |
| **0** | Insecure | Single-user mode default. All administrative functions permitted. File flags can be cleared. | Standard system startup phase. Pre-multi-user configuration tasks run here. No security level restrictions enforced yet. |
| **1** | Secure | Standard multi-user default. Dynamic sysctl modifications allowed (if not restricted by level 1 flags). | 1. Direct write access to raw block devices containing mounted file systems is **denied**.<br>2. Direct write access to physical memory devices (`/dev/mem`, `/dev/kmem`) is **prohibited**.<br>3. Kernel modules (`kldload`, `kldunload`) **cannot** be loaded or unloaded.<br>4. System immutable (`schg`) and system append-only (`sappnd`) file flags **cannot** be removed or altered.<br>5. Packet Filter (PF) rules cannot be flushed if securelevel 1 rules apply. |
| **2** | Highly Secure | All securelevel 1 permissions. Read access to raw disk devices. | 1. All constraints of Level 1 apply.<br>2. Direct write access to **all** raw disk devices is **denied**, regardless of whether the filesystem is mounted or unmounted.<br>3. System clock adjustments via `settimeofday(2)` or `adjtime(2)` are constrained to prevent time-shifting attacks (clock stepped changes > 1 second refused). |
| **3** | Network Secure | All securelevel 2 permissions. | 1. All constraints of Level 2 apply.<br>2. Packet filtering rules (`pf`, `ipfw`) **cannot** be altered, flushes, or bypassed, even by `root`. Firewall state table cannot be reloaded. |

---

### 2.3 System File Flags vs. `kern.securelevel`

BSD file systems (UFS/ZFS) provide file flags (`chflags(1)`) that operate in tandem with system security levels to prevent ransomware or malicious data destruction:

* `schg` (`SF_IMMUTABLE`): System immutable flag. File cannot be modified, deleted, renamed, or hard-linked.
* `sappnd` (`SF_APPEND`): System append-only flag. File can only be opened in append mode for writing.
* `sunlnk` (`SF_NOUNLINK`): System no-unlink flag. File cannot be removed or renamed.

#### Interaction Rule
When `kern.securelevel >= 1`:
* Superuser **can** set `schg`, `sappnd`, or `sunlnk` flags on any file.
* Superuser **cannot** clear (unset) `schg`, `sappnd`, or `sunlnk` flags on any file (`chflags noschg <file>` fails with `Operation not permitted`).

---

### 2.4 Trade-off Analysis Matrix

| Configuration Approach | Operational Agility | Security Posture | Recovery Complexity | Production SRE Best Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Default (`securelevel = -1`)** | High (Hot-patching allowed, dynamic driver loading without reboots). | Extremely Low (Root compromise leads to permanent kernel rootkits). | Low (Simple remediation via SSH). | CI/CD build nodes, developer workstations, non-production test suites. |
| **Standard Multi-User (`securelevel = 1`)** | Balanced (Network MIBs tunable; system services restartable). | High (Protects raw disk, prevents module insertion, protects log immutability). | Moderate (Requires out-of-band console / IPMI for kernel debugging). | General web servers, database clusters, application middleware nodes. |
| **Hardened Edge (`securelevel = 2`)** | Restricted (Disk partitioning and time synchronization constrained). | Very High (Prevents raw block storage wiping via `dd` on unmounted drives). | High (Requires system reboot into single-user mode for disk maintenance). | Dedicated ZFS storage nodes, edge hypervisors, isolated SAN appliances. |
| **Immutable Firewall (`securelevel = 3`)** | Extremely Low (Firewall rule updates require hardware reboot). | Maximum (Defends against firewalls being disabled during persistent APT attacks). | Severe (Rule updates mandate scheduled downtime reboot cycle). | High-security perimeter routers, crypto hardware security modules (HSMs), financial audit nodes. |

---

## 3. Production Infrastructure Configurations & Production Manifests

Below are syntactically valid, production-grade configuration manifests for a FreeBSD infrastructure deployment.

### 3.1 Boot Loader Tunables Manifest (`/boot/loader.conf`)

This configuration sets early boot parameters before kernel initialization.

```ini
# /boot/loader.conf - Production Kernel Boot Tunables
# Architecture: FreeBSD 13.x/14.x x86_64 High-Throughput Edge Router / Node

# ------------------------------------------------------------------------------
# 1. EARLY KERNEL / SECURITY TUNABLES
# ------------------------------------------------------------------------------
# Set initial boot securelevel state (processed early by loader)
kern.securelevel_enable="1"

# Enable kernel address space layout randomization (ASLR)
kern.elf64.aslr.enable=1
kern.elf32.aslr.enable=1

# Disable kernel core dumps to prevent sensitive data leakage to disk
kern.coredump=0

# Disable kernel debugger (DDB) execution on panic to enforce immediate reboot
debug.debugger_on_panic=0

# ------------------------------------------------------------------------------
# 2. NETWORK SUBSYSTEM EARLY BUFFER ALLOCATION
# ------------------------------------------------------------------------------
# Increase maximum network interface queue lengths and mbuf clusters
kern.ipc.nmbclusters="1048576"
kern.ipc.maxsockets="2048500"
net.isr.defaultthreads="8"
net.isr.bindthreads="1"

# Enable hardware-accelerated cryptodev modules at early boot
crypto_load="YES"
aesni_load="YES"

# ------------------------------------------------------------------------------
# 3. VIRTUAL MEMORY & ZFS TUNABLES
# ------------------------------------------------------------------------------
# Tune max kernel map size for high-density multi-tenant memory allocation
vm.kmemsizes="128G"

# Tune ZFS ARC (Adaptive Replacement Cache) early memory boundaries
vfs.zfs.arc_max="64424509440"
vfs.zfs.arc_min="8589934592"
```

---

### 3.2 System Runtime Parameters Manifest (`/etc/sysctl.conf`)

This configuration enforces runtime operational parameters via `/etc/sysctl.conf`.

```ini
# /etc/sysctl.conf - Production Hardened Systems Runtime MIB Configuration
# Loaded during boot sequence via /etc/rc.d/sysctl

# ------------------------------------------------------------------------------
# 1. HARDENING AND PRIVILEGE ESCALATION PREVENTION
# ------------------------------------------------------------------------------
# Hide processes running under other UIDs / GIDs from unprivileged users
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.see_jail_proc=0

# Prevent unprivileged users from viewing system mesg memory buffers
security.bsd.unprivileged_read_msgbuf=0

# Disable unprivileged process debugging (prevents ptrace-based credential theft)
security.bsd.unprivileged_proc_debug=0

# Randomize PID assignment to prevent process enumeration attacks
kern.randompid=3741

# Enforce strict link protection (prevent symlink / hardlink traversal exploits in /tmp)
security.bsd.hardlink_check_uid=1
security.bsd.hardlink_check_gid=1

# ------------------------------------------------------------------------------
# 2. NETWORK STACK HARDENING & TCP/IP TUNING
# ------------------------------------------------------------------------------
# Enable TCP SYN Cookies to mitigate TCP SYN Flood Denial-of-Service attacks
net.inet.tcp.syncookies=1

# Disable ICMP Redirect processing to block MITM routing attacks
net.inet.icmp.drop_redirect=1
net.inet.ip.redirect=0

# Ignore broadcast ICMP echo requests (mitigate Smurf attack vectors)
net.inet.icmp.bmcastecho=0

# Enable RFC 1323 high-performance TCP extensions (window scaling and timestamps)
net.inet.tcp.rfc1323=1

# Increase maximum pending socket connections for high-volume HTTP/gRPC ingress
kern.ipc.somaxconn=4096

# Expand TCP send/receive buffer maximum sizes (16MB buffers)
net.inet.tcp.sendbuf_max=16777216
net.inet.tcp.recvbuf_max=16777216
net.inet.tcp.sendbuf_inc=16384
net.inet.tcp.recvbuf_inc=524288

# Drop TCP packets destined for closed ports silently (stealth mode scan mitigation)
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1
```

---

### 3.3 System Control Service Manifest (`/etc/rc.conf`)

This manifest configures the system initialization daemon to enforce securelevel elevation during standard multi-user startup.

```sh
# /etc/rc.conf - System Initialization and Securelevel Enforcement Rules

# Host Information
hostname="edge-sre-node01.prod.infrastructure.internal"

# Networking Interface Configuration
ifconfig_vtnet0="inet 192.168.100.10 netmask 255.255.255.0 status"
defaultrouter="192.168.100.1"

# Firewall Configuration
pf_enable="YES"
pf_rules="/etc/pf.conf"
pf_flags=""

# ------------------------------------------------------------------------------
# SYSTEM SECURITY LEVEL ENFORCEMENT CONFIGURATION
# ------------------------------------------------------------------------------
# Enable securelevel escalation during boot
kern_securelevel_enable="YES"

# Set target securelevel for production multi-user operation:
# Level 1: Standard Secure Mode (protects mounted raw disks, blocks kldload, protects schg flags)
# Level 2: Highly Secure Mode (protects ALL raw disks, restricts clock adjustments)
# Level 3: Network Secure Mode (locks PF firewall rules from dynamic flushing)
kern_securelevel="1"

# Disable sendmail daemon to reduce attack surface
sendmail_enable="NONE"

# Syslog daemon hardening (disable remote socket binding unless explicitly needed)
syslogd_flags="-ss"
```

---

### 3.4 Automation Deployment Manifest (Ansible Playbook)

This Ansible playbook enforces BSD system security levels and sysctl parameters across a enterprise fleet.

```yaml
---
- name: Harden BSD Kernel Parameters and Enforce System Security Levels
  hosts: bsd_servers
  gather_facts: true
  become: true
  tasks:

    - name: Configure Early Boot Kernel Tunables in /boot/loader.conf
      ansible.builtin.blockinfile:
        path: /boot/loader.conf
        create: true
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - LOADER TUNABLES"
        block: |
          kern.securelevel_enable="1"
          kern.coredump=0
          security.bsd.aslr.enable=1

    - name: Apply Runtime MIB Parameters in /etc/sysctl.conf
      ansible.builtin.blockinfile:
        path: /etc/sysctl.conf
        create: true
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SYSCTL HARDENING"
        block: |
          security.bsd.see_other_uids=0
          security.bsd.see_other_gids=0
          security.bsd.unprivileged_proc_debug=0
          net.inet.tcp.blackhole=2
          net.inet.udp.blackhole=1
          kern.ipc.somaxconn=4096

    - name: Configure Securelevel Baseline in /etc/rc.conf
      ansible.builtin.sysrc:
        path: /etc/rc.conf
        name: "{{ item.name }}"
        value: "{{ item.value }}"
      loop:
        - { name: 'kern_securelevel_enable', value: 'YES' }
        - { name: 'kern_securelevel', value: '1' }

    - name: Set Immutable Flag on Audit Log Directory
      ansible.builtin.command:
        cmd: chflags schg /var/log/messages
      register: chflags_result
      changed_when: chflags_result.rc == 0
      failed_when: false

    - name: Verify Active Securelevel State
      ansible.builtin.command:
        cmd: sysctl kern.securelevel
      register: current_securelevel
      changed_when: false

    - name: Display Active System Security Level
      ansible.builtin.debug:
        msg: "The active system security level is: {{ current_securelevel.stdout }}"
```

---

## 4. Real-world CLI Commands & Terminal Output Sequences

The following execution traces demonstrate standard administration, runtime inspection, privilege verification, and kernel safeguard enforcement.

### 4.1 Querying and Modifying Dynamic MIBs via `sysctl(8)`

#### Inspecting System Security Level MIB Metadata
```console
$ sysctl -d kern.securelevel
kern.securelevel: System security level

$ sysctl -d security.bsd.see_other_uids
security.bsd.see_other_uids: Unprivileged processes may see other UIDs processes
```

#### Reading Current Securelevel State
```console
$ sysctl kern.securelevel
kern.securelevel: 1
```

#### Querying All Network Stack Blackhole Parameters
```console
$ sysctl net.inet.tcp.blackhole net.inet.udp.blackhole
net.inet.tcp.blackhole: 2
net.inet.udp.blackhole: 1
```

#### Dynamically Modifying a Permitted Network MIB Parameter
```console
$ sudo sysctl net.inet.tcp.syncookies=1
net.inet.tcp.syncookies: 0 -> 1
```

---

### 4.2 Demonstrating `kern.securelevel` Escalation & Enforced Violations

#### Escalating Securelevel at Runtime (Permitted Upward Transition)
```console
$ sysctl kern.securelevel
kern.securelevel: 1

$ sudo sysctl kern.securelevel=2
kern.securelevel: 1 -> 2

$ sysctl kern.securelevel
kern.securelevel: 2
```

#### Attempting Downward Securelevel Modification (Refused by Kernel)
```console
$ sudo sysctl kern.securelevel=1
sysctl: kern.securelevel: Operation not permitted

$ echo $?
1
```

#### Attempting Kernel Module Insertion under `securelevel >= 1` (Refused by Kernel)
```console
$ sudo kldload ipfw
kldload: can't load ipfw: Operation not permitted
```

#### Attempting Direct Raw Block Disk Overwrite under `securelevel >= 1`
```console
$ sudo dd if=/dev/zero of=/dev/ada0p2 bs=1M count=10
dd: /dev/ada0p2: Operation not permitted
```

---

### 4.3 Demonstrating File Flags (`chflags`) under High Securelevel

#### Setting System Immutable Flag on Critical Configuration File
```console
$ sudo chflags schg /etc/sysctl.conf
$ ls -lo /etc/sysctl.conf
-rw-r--r--  1 root  wheel  schg 1482 Aug  6 18:30 /etc/sysctl.conf
```

#### Attempting File Modification or Unlink of an Immutable File
```console
$ sudo rm -f /etc/sysctl.conf
rm: /etc/sysctl.conf: Operation not permitted

$ sudo echo "# Malicious Injection" >> /etc/sysctl.conf
bash: /etc/sysctl.conf: Operation not permitted
```

#### Attempting to Clear System Immutable Flag under `securelevel = 1` (Refused by Kernel)
```console
$ sudo chflags noschg /etc/sysctl.conf
chflags: /etc/sysctl.conf: Operation not permitted
```

---

## 5. Verification, Failure Diagnostic & Troubleshooting Guide

When operating in hardened BSD production environments, SREs frequently encounter administrative blockages caused by active kernel security level enforcement or misconfigured MIB variables. This section provides a systematic diagnostic methodology.

```
                             +-----------------------------------+
                             | Administrative Action Failed      |
                             | (e.g., EPERM / Operation Denied)  |
                             +-----------------------------------+
                                               |
                                               v
                             +-----------------------------------+
                             |  Check Current Securelevel State  |
                             |  ($ sysctl kern.securelevel)      |
                             +-----------------------------------+
                                               |
                     +-------------------------+-------------------------+
                     |                                                   |
                     v                                                   v
           [ Securelevel >= 1 ]                                [ Securelevel <= 0 ]
                     |                                                   |
    +----------------+----------------+                        +---------+---------+
    |                                 |                        |                   |
    v                                 v                        v                   v
[ File Flag Operation ]    [ Module / Disk Access ]   [ Check DAC Permissions ] [ Check MAC / Jail ]
Check file attributes      Requires reboot or single- Verify file owner, UID,    Verify MAC framework
via `ls -lo <path>`        user console transition.   and POSIX ACLs.        policy constraints.
```

---

### 5.1 Step-by-Step Diagnostic Workflow

#### Step 1: Diagnose Error Code `EPERM` (`Operation not permitted`)
If a command run as `root` (UID 0) fails with `Operation not permitted`, determine if the restriction is enforced by DAC (discretionary access control), File Flags, or `kern.securelevel`.

```console
# 1. Query active security level
$ sysctl kern.securelevel
kern.securelevel: 1

# 2. Check extended file flags if the failure involves a file/directory
$ ls -lo /etc/pf.conf
-rw-------  1 root  wheel  schg 2048 Aug  6 12:00 /etc/pf.conf
```
*Diagnosis:* If the `schg` or `sappnd` flag is present and `kern.securelevel >= 1`, the flag **cannot be removed** without lowering the system security level via reboot.

---

#### Step 2: Troubleshoot Failed Module Loading (`kldload` Failures)
During automated deployment pipelines, Ansible or Shell scripts may attempt to load kernel drivers (e.g., `vmm.ko` for Bhyve virtualization, or `pf.ko` for network filtering).

```console
$ sudo kldload vmm
kldload: can't load vmm: Operation not permitted
```

*Diagnostic Verification:*
1. Verify module status: `kldstat`
2. Check `kern.securelevel`: If value is `1`, `2`, or `3`, dynamic module loading is hard-blocked at kernel level.
3. *Remediation:* Pre-load required modules at early boot time via `/boot/loader.conf`:
   ```ini
   # Add to /boot/loader.conf
   vmm_load="YES"
   ```
   Requires a system reboot to apply.

---

#### Step 3: Troubleshoot Time Synchronization Failures (`ntpd` / `chrony`)
Under `kern.securelevel = 2` or `3`, large clock adjustments via `settimeofday(2)` are refused by the kernel to prevent time-skew attacks on cryptographic tokens and audit logs.

```console
# Error logged in /var/log/messages:
ntpd[1245]: settimeofday: Operation not permitted
```

*Diagnostic Verification:*
* `kern.securelevel` is currently set to `2` or higher.
* The NTP daemon is attempting a step adjustment (clock offset > 1 second).

*Remediation:*
Ensure time is accurately initialized during early boot (before `rc.conf` raises securelevel) via `ntpdate` or `openntpd` prior to multi-user mode transition, or set NTP to use slew mode (`adjtime(2)`) adjustments exclusively.

---

#### Step 4: Audit Dynamic MIB Value Mismatches
When a value defined in `/etc/sysctl.conf` does not take effect after boot:

1. Check if the variable is a boot-time tunable rather than a runtime MIB:
   ```console
   $ sysctl kern.ipc.nmbclusters=2048500
   sysctl: oid 'kern.ipc.nmbclusters' is read only
   ```
   *Resolution:* Move the setting from `/etc/sysctl.conf` to `/boot/loader.conf`.

2. Inspect sysctl startup logs for syntax errors:
   ```console
   $ grep -i sysctl /var/log/messages
   ```

---

### 5.2 Diagnostic Tool Reference Matrix

| Symptom / Task | Diagnostic Command | Expected Normal Output | Problematic / Failure Output | Corrective Action |
| :--- | :--- | :--- | :--- | :--- |
| **Verify active securelevel** | `sysctl kern.securelevel` | `kern.securelevel: 1` | `kern.securelevel: -1` | Enable `kern_securelevel_enable="YES"` in `/etc/rc.conf`. |
| **Identify file flags** | `ls -lo /target/file` | `-rw-r--r-- 1 root wheel - ...` | `-rw-r--r-- 1 root wheel schg ...` | Cannot unset `schg` while securelevel $\ge 1$. Must reboot into single-user mode to clear flag. |
| **Verify module loading** | `kldstat` | Lists active `.ko` kernel modules | `kldload: Operation not permitted` | Pre-load module in `/boot/loader.conf` via `module_load="YES"`. |
| **Check MIB Description** | `sysctl -d <oid>` | Full description of OID variable | `sysctl: unknown oid '<oid>'` | Verify correct spelling or ensure required kernel module exposing OID is loaded. |
| **Debug Sysctl Execution** | `service sysctl restart` | Applies settings from `/etc/sysctl.conf` | `sysctl: oid: Operation not permitted` | Variable cannot be changed at current securelevel or is read-only. |

---

## 6. References

The technical specifications and standards outlined in this document are derived from official BSD documentation and BSD Specialist Certification objectives:

1. **LPI BSD Specialist 702 Certification Overview & Objectives:**  
   [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

2. **FreeBSD System Security Levels Manual Page (`securelevel(7)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7](https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7)

3. **FreeBSD System Control Utility Manual Page (`sysctl(8)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8)

4. **FreeBSD System Kernel Tunables Interface Manual Page (`loader.conf(5)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=loader.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=loader.conf&sektion=5)

5. **FreeBSD System Configuration Files Manual Page (`rc.conf(5)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=rc.conf&sektion=5](https://man.freebsd.org/cgi/man.cgi?query=rc.conf&sektion=5)

6. **FreeBSD File Flags Management Manual Page (`chflags(1)`):**  
   [https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1](https://man.freebsd.org/cgi/man.cgi?query=chflags&sektion=1)

7. **FreeBSD Handbook - Chapter 15: Security & Hardening:**  
   [https://docs.freebsd.org/en/books/handbook/security/](https://docs.freebsd.org/en/books/handbook/security/)

8. **OpenBSD System Security Levels Manual Page (`securelevel(7)`):**  
   [https://man.openbsd.org/securelevel.7](https://man.openbsd.org/securelevel.7)