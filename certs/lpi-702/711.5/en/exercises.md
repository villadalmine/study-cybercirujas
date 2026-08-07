# LPI-702 (Exam 702-100) Topic 711.5: BSD Kernel Parameters and System Security Level
**Weight:** 3.33  
**Target Audience:** SREs, Systems Architects, and Security Engineers preparing for the CNCF/BSDCert BSD Specialist Certification.  
**Official References:**
* LPI BSD Specialist Overview: [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
* FreeBSD `securelevel(7)` Man Page: [https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7](https://man.freebsd.org/cgi/man.cgi?query=securelevel&sektion=7)
* FreeBSD `sysctl(8)` Man Page: [https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8](https://man.freebsd.org/cgi/man.cgi?query=sysctl&sektion=8)
* OpenBSD `securelevel(7)` Man Page: [https://man.openbsd.org/securelevel.7](https://man.openbsd.org/securelevel.7)
* NetBSD `secmodel_securelevel(9)` Man Page: [https://man.netbsd.org/secmodel_securelevel.9](https://man.netbsd.org/secmodel_securelevel.9)

---

## Technical Overview & Architecture

BSD operating systems expose kernel internals to userland via a hierarchical tree structure known as the **Management Information Base (MIB)**. The `sysctl(8)` utility interface allows system administrators to query and tune these MIB variables in real time. 

Complementing runtime parameter tuning is the BSD **System Security Level** (`kern.securelevel`), a kernel-level integrity enforcement mechanism. Once raised, `kern.securelevel` establishes immutable security boundaries that restrict even the `root` superuser (`UID 0`).

```
                              +---------------------------------------+
                              |        Userland Applications          |
                              +---------------------------------------+
                                        |                   |
                                (read / write MIB)     (chflags / disk io)
                                        |                   |
                                        v                   v
+-----------------------------------------------------------------------------------+
| FreeBSD / OpenBSD / NetBSD Kernel                                                 |
|                                                                                   |
|  +---------------------------------+     +-------------------------------------+  |
|  |     Management Info Base        |     |   kern.securelevel State Machine    |  |
|  |             (MIB)               |     |                                     |  |
|  |                                 |     |  Level -1: Permanently Insecure     |  |
|  |  kern.*  net.*  vm.*  security.*|     |  Level  0: Insecure Mode (Boot/1-user)|  |
|  |  hw.*    machdep.*  vfs.*       |     |  Level  1: Secure Mode              |  |
|  +---------------------------------+     |  Level  2: Highly Secure Mode       |  |
|                  |                       |  Level  3: Network Secure Mode      |  |
|                  |                       +-------------------------------------+  |
|                  v                                          |                     |
|       [CTLFLAG_SECURE Enforcement] <------------------------+                     |
|       Blocks tuning of sensitive MIBs when securelevel > 0                        |
+-----------------------------------------------------------------------------------+
```

### Kernel MIB Classification & Lifecycle

BSD sysctls fall into three primary categories based on when and how they can be modified:

1. **Dynamic Runtime Variables (`CTLFLAG_RW`):** Read-write parameters modifiable at runtime via `sysctl -w` or `/etc/sysctl.conf` during system initialization.
2. **Read-Only Parameters (`CTLFLAG_RD`):** Static system metadata (e.g., compiled CPU architecture, page size, kernel version string) that cannot be altered under any security level.
3. **Bootloader Tunables (`CTLFLAG_TUN`):** Memory allocations and driver configurations that must be set during kernel initialization before hardware enumeration completes. Managed via `/boot/loader.conf` on FreeBSD.

### The `securelevel` Monotonic State Machine

The `kern.securelevel` parameter enforces a **strictly monotonic state machine**. It can be increased by a privileged process (`UID 0`) at any time, but **it can never be decreased while the kernel is executing in multi-user mode**. Lowering `securelevel` requires a complete system reboot or entering single-user mode via `/sbin/init`.

| Security Level | Name | Key Integrity Restrictions |
| :--- | :--- | :--- |
| **-1** | Permanently Insecure | Kernel security checking is completely disabled. Init will not automatically raise the level on multi-user boot. |
| **0** | Insecure Mode | System startup mode. Immutable and append-only file flags (`schg`, `sappnd`) can be un-set. Raw disk writes are permitted. |
| **1** | Secure Mode | Blocks removal of `schg`/`sappnd` flags. Prevents writing to `/dev/mem` and `/dev/kmem`. Blocks loading/unloading kernel modules (`kldload`/`kldunload`). Disables direct execution of memory/IO bus operations. |
| **2** | Highly Secure Mode | Extends Level 1. Blocks raw write access to mounted or unmounted block/character disk devices. Prevents setting the wall clock back by more than 1 second. |
| **3** | Network Secure Mode | Extends Level 2. Locks IP Packet Filter (`pf` / `ipfw`) rulesets; network firewall rule modifications are completely rejected by the kernel. |

---

## Lab Exercise 1: Runtime Kernel MIB Inspection and Persistent Tuning

### Scenario
As a Systems Architect, you must audit dynamic kernel parameters on a production FreeBSD 14-RELEASE web edge cluster, adjust TCP network stack parameters to mitigate SYN flood attacks, configure memory dump behaviors, and ensure all changes persist across kernel reboots without causing boot failures.

### Execution Steps

1. Log into your BSD instance as `root`. Inspect the top-level categories of the kernel Management Information Base (MIB) and query all `net.inet.tcp` variables.

```bash
sysctl net.inet.tcp | head -n 15
```

**Expected Output:**
```text
net.inet.tcp.rfc1323: 1
net.inet.tcp.mssdflt: 536
net.inet.tcp.v6mssdflt: 1220
net.inet.tcp.somaxconn: 512
net.inet.tcp.syncache.rexmtlimit: 3
net.inet.tcp.syncache.hashsize: 512
net.inet.tcp.syncache.bucketlimit: 30
net.inet.tcp.syncache.cachelimit: 15360
net.inet.tcp.syncache.count: 0
net.inet.tcp.buffersize: 131072
net.inet.tcp.recvspace: 65536
net.inet.tcp.sendspace: 32768
net.inet.tcp.always_keepalive: 1
net.inet.tcp.delayed_ack: 1
net.inet.tcp.blackhole: 0
```

2. Inspect the description and data type of the `net.inet.tcp.blackhole` and `kern.coredump` parameters using extended sysctl flags.

```bash
sysctl -d net.inet.tcp.blackhole
sysctl -d kern.coredump
```

**Expected Output:**
```text
net.inet.tcp.blackhole: Do not send RST when dropping TCP packets for closed ports
kern.coredump: Enable core dumps on abnormal program termination
```

3. Increase the listen socket queue backlog (`somaxconn`) from default to `4096` and set `net.inet.tcp.blackhole` to `2` (drop TCP SYN packets to closed ports without returning a TCP RST) dynamically at runtime.

```bash
sysctl net.inet.tcp.somaxconn=4096
sysctl net.inet.tcp.blackhole=2
```

**Expected Output:**
```text
net.inet.tcp.somaxconn: 512 -> 4096
net.inet.tcp.blackhole: 0 -> 2
```

4. Attempt to write to a boot-time tunable MIB (e.g., `kern.ipc.nmbclusters`) dynamically via `sysctl` at runtime to observe kernel handling of `CTLFLAG_TUN` variables.

```bash
sysctl kern.ipc.nmbclusters=262144
```

**Expected Output:**
```text
sysctl: kern.ipc.nmbclusters: sysctl oid 'kern.ipc.nmbclusters' is read-only (or tunable only)
```

5. Configure persistent runtime parameters in `/etc/sysctl.conf` and bootloader tunables in `/boot/loader.conf`.

```bash
cat << 'EOF' >> /etc/sysctl.conf
# Dynamic Network & Security Tuning
net.inet.tcp.somaxconn=4096
net.inet.tcp.blackhole=2
kern.coredump=0
EOF

cat << 'EOF' >> /boot/loader.conf
# Early Bootloader Tunables
kern.ipc.nmbclusters="262144"
cc_cubic_load="YES"
EOF
```

6. Verify that `/etc/sysctl.conf` syntax is valid by forcing a re-read of the configuration without rebooting.

```bash
sysctl -f /etc/sysctl.conf
```

**Expected Output:**
```text
net.inet.tcp.somaxconn: 4096 -> 4096
net.inet.tcp.blackhole: 2 -> 2
kern.coredump: 1 -> 0
```

---

### Comprehension Questions - Block 1

**Question 1.1:** What is the technical distinction between configuring a kernel parameter in `/etc/sysctl.conf` versus `/boot/loader.conf` on FreeBSD?
A) `/etc/sysctl.conf` is parsed by the kernel before initialization of device drivers, while `/boot/loader.conf` is evaluated by `init(8)` during single-user mode.  
B) `/boot/loader.conf` parameters are loaded into kernel environment variables by the bootloader (`loader(8)`) prior to kernel execution; `/etc/sysctl.conf` is processed late in the boot sequence by userland scripts via `sysctl(8)`.  
C) Parameters in `/etc/sysctl.conf` can alter `CTLFLAG_RD` variables, whereas `/boot/loader.conf` can only set `CTLFLAG_RW` variables.  
D) `/boot/loader.conf` applies strictly to OpenBSD systems, while `/etc/sysctl.conf` is exclusive to FreeBSD.

**Question 1.2:** You attempt to execute `sysctl -w net.inet.tcp.blackhole=2` on a system operating at `kern.securelevel=1`, but the command fails with `Permission denied`. What mechanism causes this refusal?
A) `net.inet.tcp.blackhole` is marked with `CTLFLAG_SECURE`, preventing userland modifications once securelevel is above 0.  
B) Securelevel 1 forces all filesystem mount points containing `/sbin/sysctl` to become read-only.  
C) `sysctl` requires the `schg` flag to be removed from `/etc/sysctl.conf` before writing values.  
D) Network sysctls can only be modified when `kern.securelevel` is set to level 3 or higher.

---

## Lab Exercise 2: System File Hardening and the `securelevel` State Machine

### Scenario
You are hardening an open-facing SSH bastion host. You need to apply system immutable flags (`schg`) to binary execution directories (`/bin`, `/sbin`, `/usr/bin`) and append-only flags (`sappnd`) to critical audit log trails. You will then elevate `kern.securelevel` to `1` and demonstrate how the kernel blocks privileged root processes from tampering with these binaries or loading unverified kernel modules.

### Execution Steps

1. Create a dummy system binary `/bin/custom_monitor` and an immutable log file `/var/log/audit.log`. Assign the `schg` flag to the binary and `sappnd` to the log file using `chflags(1)`.

```bash
touch /bin/custom_monitor && chmod 755 /bin/custom_monitor
touch /var/log/audit.log && chmod 600 /var/log/audit.log

chflags schg /bin/custom_monitor
chflags sappnd /var/log/audit.log
ls -lo /bin/custom_monitor /var/log/audit.log
```

**Expected Output:**
```text
-rwxr-xr-x  1 root  wheel  schg   0 Aug  6 20:15 /bin/custom_monitor
-rw-------  1 root  wheel  sappnd 0 Aug  6 20:15 /var/log/audit.log
```

2. Confirm that at default boot level (`kern.securelevel=0` or `-1`), the `root` user can append data to the log, remove the `schg` flag, and modify the file.

```bash
sysctl kern.securelevel
echo "Audit entry 1" >> /var/log/audit.log
chflags noschg /bin/custom_monitor
echo "#!/bin/sh" > /bin/custom_monitor
chflags schg /bin/custom_monitor
```

**Expected Output:**
```text
kern.securelevel: -1
```
*(Commands execute cleanly without errors)*

3. Verify the current securelevel configuration in `/etc/rc.conf`. Configure the BSD startup infrastructure to automatically enforce `securelevel=1` on boot.

```bash
sysrc kern_securelevel_enable="YES"
sysrc kern_securelevel="1"
grep kern_securelevel /etc/rc.conf
```

**Expected Output:**
```text
kern_securelevel_enable: NO -> YES
kern_securelevel: -1 -> 1
kern_securelevel_enable="YES"
kern_securelevel="1"
```

4. Dynamically raise the runtime `kern.securelevel` from `-1` to `1` using `sysctl`.

```bash
sysctl kern.securelevel=1
sysctl kern.securelevel
```

**Expected Output:**
```text
kern.securelevel: -1 -> 1
kern.securelevel: 1
```

5. Attempt to lower the `kern.securelevel` back to `0` or `-1` while running in multi-user mode.

```bash
sysctl kern.securelevel=0
```

**Expected Output:**
```text
sysctl: kern.securelevel: Operation not permitted
```

6. Test file flag enforcement under `securelevel=1`. Attempt to append to `/var/log/audit.log`, overwrite `/var/log/audit.log`, and remove the `schg` flag from `/bin/custom_monitor`.

```bash
echo "Audit entry 2" >> /var/log/audit.log
echo "Overwriting log" > /var/log/audit.log
chflags noschg /bin/custom_monitor
```

**Expected Output:**
```text
bash: /var/log/audit.log: Operation not permitted
chflags: /bin/custom_monitor: Operation not permitted
```

7. Attempt to dynamically load a kernel module (e.g., `ipfw` or `snmpmod`) into the running kernel using `kldload(8)` under `securelevel=1`.

```bash
kldload ipfw
```

**Expected Output:**
```text
kldload: can't load ipfw: Operation not permitted
```

---

### Comprehension Questions - Block 2

**Question 2.1:** A root attacker compromises a server operating at `kern.securelevel=1`. The attacker attempts to bypass file immutability by executing `chflags noschg /bin/login`. How does the BSD kernel react?
A) The kernel permits the command because `UID 0` retains absolute privilege over file flags regardless of securelevel.  
B) The system immediately panics and drops into the kernel debugger (`db>`).  
C) The syscall `chflags(2)` fails with `EPERM` (Operation not permitted) because the kernel checks `securelevel > 0` before allowing flag resets.  
D) The flag is modified in memory, but disk sync operations are deferred until the securelevel drops to `0`.

**Question 2.2:** Why does `kldload` fail under `kern.securelevel=1`?
A) Kernel module files on disk automatically inherit the `nodump` flag at securelevel 1.  
B) Loading arbitrary kernel modules would allow arbitrary ring-0 code execution, bypassing all securelevel constraints.  
C) Dynamic linker symbols are purged from kernel memory upon entering multi-user state.  
D) Securelevel 1 restricts raw access to block storage, preventing `kldload` from reading kernel objects.

---

## Lab Exercise 3: Storage Raw Block Protection, Firewall Integrity, and Clock Drift Lockdown (Levels 2 & 3)

### Scenario
In a high-security financial trading infrastructure, an attacker with root access must be prevented from tampering with raw physical disks (`/dev/ada0`), altering NTP system time to obscure audit trail sequence numbers, or flushing Packet Filter (`pf`) firewall rulesets. You are tasked with escalating the system to `securelevel=2` and `securelevel=3` to test kernel-level defense boundaries.

### Execution Steps

1. Check the currently mounted filesystems to identify raw device nodes.

```bash
mount | grep 'on / '
```

**Expected Output:**
```text
/dev/ada0p2 on / (ufs, local, soft-updates)
```

2. Raise `kern.securelevel` from `1` to `2`.

```bash
sysctl kern.securelevel=2
sysctl kern.securelevel
```

**Expected Output:**
```text
kern.securelevel: 1 -> 2
kern.securelevel: 2
```

3. Attempt to write raw garbage data directly to the underlying raw disk block device (`/dev/ada0`) using `dd(1)` as `root`.

```bash
dd if=/dev/zero of=/dev/ada0 bs=512 count=1 seek=1
```

**Expected Output:**
```text
dd: /dev/ada0: Operation not permitted
```

4. Test system clock manipulation enforcement under `securelevel=2`. Attempt to rewind the system time by 100 seconds using `date(1)`.

```bash
date -r $(($(date +%s) - 100))
```

**Expected Output:**
```text
date: settimeofday (ns): Operation not permitted
```

5. Elevate `kern.securelevel` to `3` (Network Secure Mode / Firewall Lockdown).

```bash
sysctl kern.securelevel=3
sysctl kern.securelevel
```

**Expected Output:**
```text
kern.securelevel: 2 -> 3
kern.securelevel: 3
```

6. Attempt to alter or flush the active OpenBSD/FreeBSD `pf(4)` packet filter ruleset using `pfctl(8)`.

```bash
pfctl -F rules
```

**Expected Output:**
```text
pfctl: DIOCXCOMMIT: Operation not permitted
```

---

### Comprehension Questions - Block 3

**Question 3.1:** What distinct protection does `securelevel=2` add regarding storage devices over `securelevel=1`?
A) Level 1 prevents writing to mounted block devices, while Level 2 prevents reading from unmounted raw character devices.  
B) Level 1 allows raw write access to disk devices that are currently mounted; Level 2 forbids raw disk writes to all block/character devices, whether mounted or unmounted.  
C) Level 2 forces all mounted filesystems into `read-only` VFS mode.  
D) Level 2 encrypts the master boot record (MBR) and GUID partition table (GPT) dynamically in memory.

**Question 3.2:** Under `securelevel=2`, an NTP daemon attempts to correct clock drift. Which time-adjustment operation will succeed?
A) Stepping the clock backward by 300 seconds using `settimeofday(2)`.  
B) Slew adjustments made via `adjtime(2)` that incrementally adjust clock tick speed without stepping time backward abruptly.  
C) Any backward step executed by `UID 0` using `date -f`.  
D) Clock changes requested by kernel threads writing directly to system RTC registers.

---

## Lab Exercise 4: Cross-BSD Architecture Comparison, NetBSD Secmodel, and Emergency Recovery

### Scenario
Different BSD flavors manage kernel parameters and security levels through unique subsystems. NetBSD utilizes the modular **Secmodel** framework (`secmodel_securelevel(9)`), whereas OpenBSD enforces rigid security level settings via `/etc/sysctl.conf`. As an SRE Lead, you must document these cross-platform variations and perform an emergency single-user boot recovery procedure on a node locked in `securelevel=2` where an immutable configuration file requires emergency edits.

### Subsystem Comparison Matrix

```
+------------------+-----------------------------+-------------------------------+-----------------------------------+
| Feature          | FreeBSD 14-RELEASE          | OpenBSD 7.x                   | NetBSD 10.x                       |
+------------------+-----------------------------+-------------------------------+-----------------------------------+
| Runtime Tool     | sysctl(8)                   | sysctl(8)                     | sysctl(8)                         |
| Tunable Config   | /boot/loader.conf           | Bootloader boot.conf          | /boot.cfg                         |
| Persistence File | /etc/sysctl.conf            | /etc/sysctl.conf              | /etc/sysctl.conf                  |
| Securelevel Reg  | /etc/rc.conf                | /etc/rc.conf.local            | /etc/sysctl.conf                  |
| Framework Basis  | Traditional BSD Securelevel | Traditional BSD Securelevel   | kauth(9) / secmodel_securelevel(9)|
| Max Securelevel  | 3 (Network Security Mode)   | 2 (Highly Secure Mode)        | 2 (Highly Secure Mode)            |
+------------------+-----------------------------+-------------------------------+-----------------------------------+
```

### Execution Steps

1. Examine NetBSD-specific kernel authorization sysctls to understand `secmodel` abstraction layer.

```bash
# On NetBSD systems:
sysctl security.models
sysctl security.securelevel.formal_name
```

**Expected Output:**
```text
security.models: bsd44
security.securelevel.formal_name: Traditional BSD Securelevel
```

2. **Emergency Recovery Scenario:** A server locked at `securelevel=2` contains an immutable configuration file (`/etc/pf.conf` with `schg` flag set) that prevents SSH access. Because `securelevel` cannot be lowered in multi-user mode, you must simulate the single-user recovery procedure.

Initiate system reboot to the boot loader prompt.

```bash
reboot
```

3. At the FreeBSD bootloader menu prompt, interrupt the countdown and boot into **Single-User Mode** (Option 2 or command `boot -s`).

```text
Type '?' for a list of commands, 'help' for more detailed help.
OK boot -s
```

4. Once the single-user shell (`/bin/sh`) prompts, observe that `kern.securelevel` is initiated at level `0` or `-1`.

```bash
# In single-user shell:
sysctl kern.securelevel
```

**Expected Output:**
```text
kern.securelevel: -1
```

5. Mount the root filesystem in read-write mode, remove the immutable flag from the file, fix the configuration, and return to multi-user boot.

```bash
mount -u -o rw /
chflags noschg /etc/pf.conf
echo "pass in all" > /etc/pf.conf
exit
```

**Expected Output:**
```text
[System transitions to multi-user mode, parsing /etc/rc.conf and elevating securelevel back to configured target]
```

---

### Comprehension Questions - Block 4

**Question 4.1:** How does NetBSD implement `securelevel` functionality differently from traditional FreeBSD/OpenBSD implementations?
A) NetBSD compiles `securelevel` directly into hardware firmware via eBPF probes.  
B) NetBSD implements securelevel as a pluggable kernel authorization module (`secmodel_securelevel(9)`) integrated into the `kauth(9)` subsystem.  
C) NetBSD allows `securelevel` to be lowered by `root` if signed kernel capability tokens are supplied to `sysctl`.  
D) NetBSD uses `/etc/loader.conf` exclusively to modify security levels during multi-user operations.

**Question 4.2:** During an emergency recovery in single-user mode (`boot -s`), why is the administrator able to clear `schg` flags that were blocked in multi-user mode?
A) Single-user mode automatically changes the file ownership of all binaries to `nobody`.  
B) `init(8)` starts single-user mode before executing `/etc/rc`, keeping `kern.securelevel` at state `0` or `-1`.  
C) The `chflags` binary bypasses kernel system calls when executed in raw console mode.  
D) Single-user mode disables the Virtual File System (VFS) layer completely.

---

## <details><summary>Exercise Answers & Technical Rationale</summary>

### Exercise 1 Answers

* **Question 1.1:** **B**
  * **Rationale:** `/boot/loader.conf` is processed by the FreeBSD bootloader (`loader(8)`) before the kernel initializes. It sets kernel environment variables and bootloader tunables (`CTLFLAG_TUN`). `/etc/sysctl.conf` is evaluated later in the startup process by userland user scripts (`/etc/rc.d/sysctl`) invoking `sysctl(8)` to configure runtime dynamic MIBs (`CTLFLAG_RW`).
* **Question 1.2:** **A**
  * **Rationale:** In BSD kernels, sysctl MIB nodes can be declared with the `CTLFLAG_SECURE` flag. When `kern.securelevel` is greater than 0, the kernel's `sysctl` subsystem explicitly rejects modification requests for these specific parameters, returning `EPERM` (Permission denied), regardless of superuser status.

### Exercise 2 Answers

* **Question 2.1:** **C**
  * **Rationale:** The `chflags(2)` system call checks the system security level when modification of system flags (`SF_IMMUTABLE` / `schg`, `SF_APPEND` / `sappnd`) is requested. If `kern.securelevel > 0`, the kernel blocks removal or alteration of these flags and returns `EPERM`.
* **Question 2.2:** **B**
  * **Rationale:** Kernel modules execute with full ring-0 privileges inside kernel space. If `kldload(8)` were permitted under `securelevel=1`, an attacker with root privileges could load a malicious module to overwrite kernel memory tables, zero out `kern.securelevel` in RAM, or strip file flags. Therefore, `kldload` and `kldunload` are disabled by the kernel when `securelevel >= 1`.

### Exercise 3 Answers

* **Question 3.1:** **B**
  * **Rationale:** At `securelevel=1`, raw disk write operations are blocked for mounted filesystems, but raw access to unmounted disk devices may still pose a risk. `securelevel=2` strictly forbids raw write operations to **all** block and character disk devices regardless of mount status, protecting raw disk structures from being overwritten by utilities like `dd(1)`.
* **Question 3.2:** **B**
  * **Rationale:** Under `securelevel=2`, backward time steps via `settimeofday(2)` or `clock_settime(2)` exceeding 1 second are forbidden to prevent attackers from invalidating timestamped log files or security certificates. Slew adjustments via `adjtime(2)` modulate the rate of clock ticks to correct drift gradually without stepping time backward, and are permitted.

### Exercise 4 Answers

* **Question 4.1:** **B**
  * **Rationale:** NetBSD refactored kernel privilege checking into the Kernel Authorization framework (`kauth(9)`). System security level policies are decoupled into an interchangeable security model named `secmodel_securelevel(9)`, allowing developers to replace or augment traditional BSD securelevels with custom capability-based policies.
* **Question 4.2:** **B**
  * **Rationale:** When booting into single-user mode (`boot -s`), `init(8)` spawns a direct root shell prior to launching `/etc/rc`. Because startup scripts have not run to set `kern.securelevel` to higher levels, `securelevel` remains at its boot default (`0` or `-1`), allowing superuser maintenance operations such as unsetting `schg` flags.

</details>