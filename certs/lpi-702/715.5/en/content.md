# LPI 702: BSD Specialist Certification Study Guide
## Topic 715.5: Perform Basic File Editing Operations (Exam 702-100, Version 1.0)
**Weight:** 3.34  
**Role Context:** Principal Platform Architect & Senior SRE Level

---

### 1. Production Motivation & Architectural Problem

#### 1.1 Out-of-Band Maintenance & Single-User Mode Operations
In enterprise BSD production environments (FreeBSD, OpenBSD, NetBSD), Site Reliability Engineers (SREs) and Platform Architects frequently encounter scenarios where hypervisors, storage nodes running ZFS, and security appliances (such as pfSense or HardenedBSD firewalls) lose network connectivity, crash during boot due to syntax errors in configuration files, or suffer file system corruption.

In these emergency scenarios, standard remote management toolchains (Ansible, SSH, puppet-agent) are unavailable. Engineers must attach via out-of-band serial consoles (IPMI, iDRAC, AWS serial console, or KVM) into **Single-User Mode**. 

```
+-------------------------------------------------------------------------+
|                       Out-of-Band Maintenance                           |
|                                                                         |
|  +------------------+    Serial / Console     +----------------------+  |
|  | SRE Workstation  |------------------------>| BSD System (Single   |  |
|  |                  |    (vt100 / ansi)       | User / Rescue ISO)   |  |
|  +------------------+                         +----------------------+  |
|                                                          |              |
|                                                          v              |
|                                               +----------------------+  |
|                                               | Minimal Base System  |  |
|                                               |  - Dynamic libs min. |  |
|                                               |  - /var/tmp mounted  |  |
|                                               |  - POSIX / BSD vi    |  |
|                                               +----------------------+  |
+-------------------------------------------------------------------------+
```

Single-user mode mounts the root filesystem, often read-only initially, with a minimal environment:
* Third-party packages (located in `/usr/local/bin`, including `vim`, `emacs`, or `nano`) may not be mounted or accessible.
* The terminal capabilities (`$TERM`) default to fallback specifications such as `vt100`, `ansi`, or `dumb`.
* Shared dynamic libraries outside `/lib` and `/usr/lib` may be unavailable.

Under these conditions, standard file editing tools native to the BSD base system—primarily BSD `vi` (traditionally `nvi`, the new vi replacement written by Keith Bostic)—become the primary tool for restoring system functionality.

#### 1.2 System Mechanics: `nvi` Architecture, Signals, TTY & Swap Recovery
BSD `vi` (`nvi`) is designed as a small, robust, POSIX.2-compliant editor embedded within the base distribution. Understanding its low-level operation is essential for preventing state corruption during critical outages:

1. **Modal Execution Model:**
   * **Command Mode:** The default operational mode. Keypresses are interpreted as manipulation commands (cursor movement, deletion, yank/paste, mode switching).
   * **Insert Mode:** Keypresses mutate the active line buffer directly. Entered via `i`, `a`, `o`, `I`, `A`, `O`, `R`, `c`, or `s`. Exited via `<ESC>`.
   * **Ex / Line Mode:** Invoked with `:`, `/`, or `?`. Interacts directly with the underlying line editor engine (`ex`) for global substitutions, regex searching, system commands, and file I/O operations.

2. **Buffer and Swap File Mechanics:**
   * When opening a file (`vi /etc/rc.conf`), `nvi` creates an encrypted or plain temporary recovery file in `/var/tmp/vi.recover/` (or directly as a hidden `.filename.swp` file depending on the BSD flavor).
   * The editor reads the target file line by line into an in-memory db(3) or B-tree structure. Modifications are committed to the recovery buffer before being displayed on screen.
   * If the SSH session drops or a terminal signal (`SIGHUP`, `SIGTERM`) is received, `nvi` catches the signal, syncs the in-memory line database to `/var/tmp/vi.recover/`, and sends a notification email via `sendmail` (if configured) allowing session restoration via `vi -r`.

3. **TTY, Signals, and Terminal Sizing:**
   * **`SIGWINCH` (Window Size Change):** `nvi` listens for window resize signals from the pseudo-terminal (pty). In constrained serial consoles where `SIGWINCH` fails to propagate, text corruption may appear on screen. Executing `:redraw!` (or `Ctrl+L`) forces the terminal renderer to clear and repaint screen lines according to current termcap settings.
   * **`SIGINT` (Ctrl+C):** Aborts current input or multi-line commands without dropping the session or corrupting the line buffer.

4. **File Locking & Read-Only Overrides:**
   * File permissions (`-r--r--r--`) or the `uchg` (user immutable) flag on BSD systems block standard file write syscalls (`open(2)` with `O_WRONLY`).
   * When modifying a read-only file owned by root, `vi` blocks `:w` with `Read-only file system` or `Permission denied`. If the file is read-only due to standard UNIX file mode bits (and the user is `root`), forcing a write via `:w!` overrides file mode bits by temporarily altering internal I/O flags or forcing disk syncs. However, if the underlying file system is mounted `ro` (Read-Only), `:w!` fails at the kernel VFS layer.

---

### 2. Technical Comparisons & Trade-Off Matrix

The following table evaluates text editors and line-editing utilities natively available or commonly used across BSD systems in enterprise architecture.

| Feature / Metric | `nvi` (Standard BSD vi) | `ee` (FreeBSD Easy Editor) | `vim` (Vi IMproved - Ports/Pkg) | `ed` / `ex` (Line Editor) | `sed` (Stream Editor) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Base System Inclusion** | Yes (FreeBSD, OpenBSD, NetBSD) | Yes (FreeBSD only) | No (Requires `pkg install vim`) | Yes (Standard BSD POSIX base) | Yes (Standard BSD POSIX base) |
| **Binary Footprint** | ~350 KB | ~80 KB | >30 MB (with shared libs) | ~60 KB | ~90 KB |
| **Dependency Requirement** | Minimal (`libc`, `libncurses`/`libtermlib`) | Minimal (`libc`, `libncurses`) | Heavy (`libgettext`, `libiconv`, etc.) | Statically/Minimally Linked `libc` | Minimally Linked `libc` |
| **TTY / `$TERM` Dependency** | Requires valid termcap (`vt100`, `xterm`) | Requires basic termcap | Requires complex terminfo | **Zero TTY Dependency** (Raw pipe/stream) | **Zero TTY Dependency** (Raw stream) |
| **Modal Editing** | Yes (Command, Insert, Ex) | No (Modeless, dialog-menu driven) | Yes (Command, Insert, Visual, Ex) | Line-based modal | Non-interactive command driven |
| **Recovery Mechanism** | System `/var/tmp/vi.recover` (`vi -r`) | None (Direct save or prompt) | `.swp` swap files (`vim -r`) | Backup files (`.bak` if manually piped) | In-place editing (`sed -i ''`) |
| **Macro & Scriptability** | Ex scripts (`vi -s script.ex`) | Low / Interactive only | High (Vimscript, Lua, Python) | High (Shell scriptable / STDIN) | High (Regex stream replacement) |
| **Memory Footprint** | Low (< 2 MB RSS) | Low (< 1.5 MB RSS) | Medium-High (> 15 MB RSS) | Ultra Low (< 500 KB RSS) | Ultra Low (< 500 KB RSS) |
| **Single-User Rescue Suitability** | **Optimal** (Primary tool) | Good (FreeBSD basic fixes) | Poor (May fail library check) | **Critical Fallback** (Broken TTY/boot) | **Automated Repairs** |

---

### 3. Complete Infrastructure & Configuration Manifests

Below are fully functional, syntactically valid infrastructure and configuration manifests used to standardize the `vi` editor environment, secure emergency operational access, and handle rescue setups across BSD platforms.

#### 3.1 Ansible Infrastructure Playbook: Setting Standard BSD SRE Environment
This playbook configures system-wide default editors (`/etc/profile`, `/root/.cshrc`) and deploys explicit `.nexrc` / `.exrc` configurations for root and SRE users across FreeBSD and OpenBSD nodes.

```yaml
---
- name: Standardize BSD Base System Editor Environment & Session Recovery
  hosts: bsd_servers
  gather_facts: true
  become: true

  tasks:
    - name: Ensure /var/tmp/vi.recover directory exists with secure permissions
      ansible.builtin.file:
        path: /var/tmp/vi.recover
        state: directory
        owner: root
        group: wheel
        mode: '1777'

    - name: Configure system-wide default editor in /etc/profile
      ansible.builtin.blockinfile:
        path: /etc/profile
        create: true
        owner: root
        group: wheel
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SRE EDITOR CONFIG"
        block: |
          EDITOR=/usr/bin/vi
          VISUAL=/usr/bin/vi
          EXINIT="set autoindent number report=1 showmode"
          export EDITOR VISUAL EXINIT

    - name: Configure root shell environment for FreeBSD csh (/root/.cshrc)
      ansible.builtin.blockinfile:
        path: /root/.cshrc
        create: true
        owner: root
        group: wheel
        mode: '0600'
        marker: "# {mark} ANSIBLE MANAGED BLOCK - SRE CSH EDITOR CONFIG"
        block: |
          setenv EDITOR /usr/bin/vi
          setenv VISUAL /usr/bin/vi
          setenv EXINIT "set autoindent number report=1 showmode"

    - name: Deploy hardened /root/.nexrc for BSD nvi editor
      ansible.builtin.copy:
        dest: /root/.nexrc
        owner: root
        group: wheel
        mode: '0600'
        content: |
          " BSD nvi runtime configuration - SRE Hardened Setup
          set autoindent
          set number
          set report=1
          set showmode
          set lines=24
          set columns=80
          set flash
```

#### 3.2 Complete System Configuration Snippets (`/etc/rc.conf` and `/etc/pf.conf`)
The following syntax-valid FreeBSD operational manifests demonstrate production configuration files frequently modified during emergency outages using `vi`.

##### `/etc/rc.conf` (FreeBSD Base System Daemon Configuration)
```sh
# System Hostname and Core Networking
hostname="bsd-edge-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
defaultrouter="192.168.1.1"

# Security & Access Control
sshd_enable="YES"
syslogd_flags="-s -s"

# Firewall and Packet Filter Integration
pf_enable="YES"
pf_rules="/etc/pf.conf"
pflog_enable="YES"

# ZFS System Storage Daemon
zfs_enable="YES"

# Dump directory for kernel crash diagnostics
dumpdev="AUTO"
```

##### `/etc/pf.conf` (OpenBSD / FreeBSD Packet Filter Ruleset)
```pf
# Network Interface Definitions
ext_if = "vtnet0"

# Tables for Dynamic IP Filtering
table <bruteforce> persist

# Global Filtering Options
set skip on lo0
set block-policy drop

# Firewall Normalization Rules
scrub in on $ext_if all fragment reassemble

# Default Access Control Policies
block all
pass out quick on $ext_if keep state

# Inbound Management Access Rules
pass in quick on $ext_if proto tcp from 10.240.0.0/16 to $ext_if port 22 flags S/SA keep state \
    (max-src-conn 10, max-src-conn-rate 5/60, overload <bruteforce> flush global)
```

---

### 4. Real CLI Commands & Terminal Output Logs

This section provides real step-by-step operational workflows using `vi` and low-level line utilities during system maintenance and recovery scenarios on FreeBSD/OpenBSD.

#### 4.1 Basic File Editing Lifecycle and Mode Transitions in `vi`

```console
$ export TERM=vt100
$ vi /etc/rc.conf
```

Inside `vi`, line numbers and mode indicator are visible due to setting `number` and `showmode`:

```text
  1 hostname="bsd-edge-node-01.production.internal"
  2 ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
  3 defaultrouter="192.168.1.1"
  4 sshd_enable="YES"
  5 pf_enable="NO"
~
~
~
"/etc/rc.conf": 5 lines, 168 characters
```

##### Operational Command Sequences Executed in Command Mode:
1. **Navigate to line 5:** Type `5G` or `:5<CR>`
2. **Change line contents:** Type `cw` on `"NO"` to change word, type `"YES"`, then press `<ESC>`.
3. **Append a line at the end of the file:** Press `G` to jump to the last line, then press `o` (open new line below):
   ```sh
   zfs_enable="YES"
   ```
   Press `<ESC>` to return to Command Mode.
4. **Save and Exit:** Type `:wq` or press `ZZ`.

```console
$ tail -n 2 /etc/rc.conf
pf_enable="YES"
zfs_enable="YES"
```

---

#### 4.2 Overriding Permissions on Read-Only Files (`:w!`)

When attempting to edit a read-only file (e.g., system configuration file with file mode `0444` owned by root):

```console
# ls -l /etc/master.passwd
-r--r--r--  1 root  wheel  1420 Aug  6 18:22 /etc/master.passwd
# vi /etc/master.passwd
```

Inside `vi`, modifying a line and issuing `:w` results in a write error:

```text
:w
/etc/master.passwd: read-only file: file modification permission denied
```

##### Resolution Workflow:
To force `vi` to override the read-only file mode bit (assuming executing user is `root` on a read-write file system):

```text
:w!
```

Terminal status response:
```text
/etc/master.passwd: 34 lines, 1452 characters written
```

To quit after write:
```text
:q
```

---

#### 4.3 Quitting Without Saving Changes (`:q!`)

When changes made to a file break syntax or are unwanted, disallow saving and force quit:

```console
# vi /etc/pf.conf
```

Modifications made during session corrupt rule structure. To discard all edits from buffer memory without writing to disk:

```text
:q!
```

Terminal output returns cleanly to the shell prompt:
```console
# echo $?
0
```

---

#### 4.4 Emergency Session Recovery via `vi -r` (Handling Unexpected Terminal Disconnects)

If a SSH console drops unexpectedly while editing an unsaved buffer, or if the process receives `SIGHUP`:

```console
# pkill -9 -f "vi /etc/pf.conf"
```

The system preserves the pending edit state in the recovery directory.

##### Diagnostic and Recovery Command Execution:

```console
# ls -la /var/tmp/vi.recover/
total 12
drwxrwxrwt  2 root  wheel  512 Aug  6 19:40 .
drwxrwxrwt  4 root  wheel  512 Aug  6 19:40 ..
-rw-------  1 root  wheel  2048 Aug  6 19:40 recover.vi.A01948

# vi -r
On Tuesday, Aug  6, 2026, at 19:40:12 EDT the user root was editing
the file /etc/pf.conf on host bsd-edge-node-01.production.internal.
There are saved modifications for this file.

# vi -r /etc/pf.conf
```

`nvi` opens the saved recovery buffer from `/var/tmp/vi.recover/`.

Inside `vi`:
1. Verify recovered changes.
2. Save explicitly to write the buffer back to the real filesystem target:
   ```text
   :w!
   ```
3. Exit `vi`:
   ```text
   :q
   ```
4. Remove stale recovery file:
   ```console
   # rm /var/tmp/vi.recover/recover.vi.A01948
   ```

---

#### 4.5 Emergency Out-of-Band Line Editing via `ed` (Non-Interactive / Broken TTY Rescue)

If `$TERM` is invalid (`dumb`) or the terminal driver is broken during single-user boot, screen-oriented editors (`vi`, `ee`) will refuse to launch:

```console
# export TERM=dumb
# vi /etc/rc.conf
vi: Screen line length too small
```

##### Automated / Line-Mode Rescue using POSIX `ed`:

```console
# ed /etc/rc.conf
174
1,$p
hostname="bsd-edge-node-01.production.internal"
ifconfig_vtnet0="inet 192.168.1.50 netmask 255.255.255.0"
defaultrouter="192.168.1.1"
sshd_enable="YES"
pf_enable="NO"
/pf_enable/
pf_enable="NO"
s/NO/YES/
p
pf_enable="YES"
w
175
q
# grep pf_enable /etc/rc.conf
pf_enable="YES"
```

---

### 5. Verification & Failure Diagnostics Guide

#### 5.1 Diagnostic Flowcharts: Troubleshooting BSD Editor Outages

```
                            [ File Editing Failure ]
                                       |
                                       v
                       Is the TTY correctly initialized?
                                       |
                  +--------------------+--------------------+
                  | YES                                     | NO
                  v                                         v
       Check Terminal Definition                    Fix Environment Variables:
       $TERM value valid in termcap?                $ export TERM=vt100
                  |                                 $ stty rows 24 cols 80
        +---------+---------+                               |
        | YES               | NO                            v
        v                   v                       Does editor launch?
Check File Status    Set TERM=ansi or vt100          +------+------+
                                                     | YES         | NO
                                                     v             v
                                                 Use `vi`    Fallback to `ed`
```

```
                        [ Disk Write Failure (:w / :w!) ]
                                       |
                                       v
                        Is Filesystem Mounted Read-Only?
                                       |
                  +--------------------+--------------------+
                  | YES                                     | NO
                  v                                         v
       Check mount status:                          Check File Permission/Flags:
       $ mount -p | grep ' / '                       $ ls -lo <filename>
                  |                                         |
                  v                                 +-------+-------+
       Remount root read-write:                     |               |
       # mount -u -w /                              v               v
                  |                         `uchg` flag set?    Mode 0444?
                  v                         $ chflags nouchg       |
          Retry `:w` in `vi`                        |              v
                                                    v          Use `:w!`
                                                Use `:w`       to override
```

---

#### 5.2 Common Production Errors and Remediation Protocols

##### Issue 1: `vi: Unknown terminal type` or Terminal Display Corruption
* **Symptom:** Cursor positioning fails, arrow keys output character garbage (`^[[A`), or `vi` aborts on launch.
* **Root Cause:** The database entry for `$TERM` does not exist in `/usr/share/misc/termcap` (FreeBSD) or `/usr/share/misc/terminfo` (OpenBSD).
* **Remediation Protocol:**
  ```console
  # export TERM=vt100
  # stty sane
  # stty rows 24 columns 80
  # vi /etc/rc.conf
  ```

##### Issue 2: `Read-only file system` Error on Write Attempt
* **Symptom:** `vi` returns `Operation not permitted` or `Read-only file system` even when using `:w!`.
* **Root Cause:** Kernel VFS has mounted the target filesystem as Read-Only (`ro`), standard during FreeBSD single-user boot or zfs pool import failure.
* **Remediation Protocol:**
  1. Verify mount state:
     ```console
     # mount -u -w /
     ```
  2. For ZFS root filesystems:
     ```console
     # zfs set readonly=off zroot/ROOT/default
     ```
  3. Resume edit operation in `vi` and execute `:w`.

##### Issue 3: File Locked by BSD File Flags (`uchg` / `schg`)
* **Symptom:** Executing `:w!` as `root` yields `Operation not permitted`.
* **Root Cause:** The file has the system or user immutable flag enabled (`schg` or `uchg`).
* **Remediation Protocol:**
  1. Inspect flags:
     ```console
     # ls -lo /etc/rc.conf
     -rw-r--r--  1 root  wheel  uchg 175 Aug  6 19:00 /etc/rc.conf
     ```
  2. Clear immutable flag:
     ```console
     # chflags nouchg /etc/rc.conf
     ```
  3. Edit file with `vi`, save (`:wq`), and re-apply flag if security policy requires:
     ```console
     # chflags uchg /etc/rc.conf
     ```

---

### 6. References

* **Linux Professional Institute BSD Specialist Overview & Objectives (Exam 702-100):**  
  [https://www.lpi.org/our-certifications/bsd-specialist-overview/](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

* **FreeBSD Manual Pages - `nvi` (Text Editor):**  
  [https://man.freebsd.org/cgi/man.cgi?query=nvi](https://man.freebsd.org/cgi/man.cgi?query=nvi)

* **FreeBSD Manual Pages - `ee` (Easy Editor):**  
  [https://man.freebsd.org/cgi/man.cgi?query=ee](https://man.freebsd.org/cgi/man.cgi?query=ee)

* **OpenBSD Manual Pages - `vi` / `ex` System Editor:**  
  [https://man.openbsd.org/vi](https://man.openbsd.org/vi)

* **NetBSD Manual Pages - `ed` (Line-Oriented Text Editor):**  
  [https://man.netbsd.org/ed.1](https://man.netbsd.org/ed.1)

* **IEEE Std 1003.1 POSIX.1-2017 Specification - `vi` Utility:**  
  [https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/vi.html)