# Certification Study Guide: LPI BSD Specialist (Exam 702-100, v1.0)
## Topic 711.3: BSD System Startup Configuration
**Exam Weight:** 5  
**Target Audience:** Principal SREs, Systems Architects, and Production Infrastructure Engineers  
**Official Reference Documentation:**
- [LPI BSD Specialist Overview & Objectives](https://www.lpi.org/our-certifications/bsd-specialist-overview/)
- [FreeBSD Handbook: Practical rc.d scripting](https://docs.freebsd.org/en/books/handbook/configd-boot/)
- [FreeBSD Manual Pages: rc.subr(8)](https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8)
- [FreeBSD Manual Pages: rcorder(8)](https://man.freebsd.org/cgi/man.cgi?query=rcorder&sektion=8)
- [OpenBSD Manual Pages: rcctl(8)](https://man.openbsd.org/rcctl.8)
- [OpenBSD Manual Pages: rc.subr(8)](https://man.openbsd.org/rc.subr.8)
- [NetBSD Manual Pages: rc.conf(5)](https://man.netbsd.org/rc.conf.5)

---

## Architectural Deep Dive & Mechanics

### 1. Boot Trajectory & The `rc` Initialization Engine
The BSD initialization process is designed around modularity, strict dependency ordering, and predictable declarative state management. Unlike monolithic init systems (such as systemd) or historical SysVinit runlevels, BSD systems execute userland startup through shell scripts governed by `/etc/rc` and `rc.subr(8)`.

#### The Trajectory from Kernel to Userland Services:
1. **Bootloader (`loader(8)` / `boot(8)`):** Loads kernel and modules into memory; passes boot flags (`-s` for single-user, `-v` for verbose).
2. **Kernel Initialization:** Initializes device drivers, mounts root filesystem (`/`) read-only, spawns process ID 1 (`/sbin/init`).
3. **`init(8)` Execution:**
   - In multi-user boot, `/sbin/init` executes `/etc/rc` via `/bin/sh`.
4. **`/etc/rc` Processing:**
   - Mounts essential pseudo-filesystems (`/proc`, `/dev`, `/tmp`).
   - Parses default configuration templates (`/etc/defaults/rc.conf`) followed by system-specific overrides (`/etc/rc.conf`, `/etc/rc.conf.local`, `/etc/rc.conf.d/*`).
   - Invokes `rcorder(8)` to parse dependency headers across `/etc/rc.d/` and vendor directories (`/usr/local/etc/rc.d/` on FreeBSD or `/usr/pkg/etc/rc.d/` on NetBSD).
   - Executes ordered scripts with the `faststart` or `start` argument.

---

### 2. Cross-BSD Configuration Matrix & Precedence

| Subsystem Component | FreeBSD | OpenBSD | NetBSD |
| :--- | :--- | :--- | :--- |
| **System Defaults** | `/etc/defaults/rc.conf` | `/etc/rc.conf` | `/etc/defaults/rc.conf` |
| **User Overrides** | `/etc/rc.conf`, `/etc/rc.conf.d/*` | `/etc/rc.conf.local` | `/etc/rc.conf`, `/etc/rc.conf.d/*` |
| **System Init Scripts** | `/etc/rc.d/` | `/etc/rc.d/` | `/etc/rc.d/` |
| **Package Init Scripts** | `/usr/local/etc/rc.d/` | `/etc/rc.d/` (Packages use `/etc/rc.d`) | `/usr/pkg/etc/rc.d/` |
| **CLI State Manager** | `sysrc(8)` & `service(8)` | `rcctl(8)` | `service(8)` |
| **Dependency Engine** | `rcorder(8)` | Sequential/`rcctl` flags order | `rcorder(8)` |

#### Configuration Precedence Mechanics:
- **FreeBSD / NetBSD:** `/etc/defaults/rc.conf` $\rightarrow$ `/etc/rc.conf` $\rightarrow$ `/etc/rc.conf.local` $\rightarrow$ `/etc/rc.conf.d/<service_name>`
- **OpenBSD:** `/etc/rc.conf` (System defaults updated by OS upgrades) $\rightarrow$ `/etc/rc.conf.local` (Local administrator overrides).

---

### 3. `rcorder(8)` Topological Sorting Algorithm
`rcorder(8)` parses special block comment headers embedded in the head of each script to build a Directed Acyclic Graph (DAG) for execution ordering:
- `# PROVIDE: <name>`: Names the subsystem or feature supplied by this script.
- `# REQUIRE: <name1> <name2>`: Lists prerequisites that **must** execute before this script.
- `# BEFORE: <name1>`: Forces this script to execute **prior** to the specified services.
- `# KEYWORD: [nostart | shutdown | firstboot | ...]`: Special tags used by `rcorder` options (e.g., `shutdown` orders reverse execution during system halt via `/etc/rc.shutdown`).

---

## Guided Production Exercises

### Exercise 1: Dependency Resolution and Boot-Order Analysis with `rcorder(8)`

#### Scenario & Goal
As a SRE, you must diagnose service startup sequence issues. You need to inspect how the BSD boot engine computes daemon startup order and verify whether a newly installed database daemon will start after network initialization (`NETWORKING`) and filesystem mounts (`mountcritlocal`), but before application daemons (`LOGIN`).

#### Step-by-Step Execution Procedure

1. Query the boot order of all base system and package scripts on FreeBSD/NetBSD:
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* 2>/dev/null | head -n 25
   ```
   **Expected CLI Output:**
   ```text
   /etc/rc.d/NETWORKING
   /etc/rc.d/mountcritlocal
   /etc/rc.d/var
   /etc/rc.d/cleanvar
   /etc/rc.d/dmesg
   /etc/rc.d/sysctl
   /etc/rc.d/hostname
   /etc/rc.d/ipfw
   /etc/rc.d/routing
   /etc/rc.d/NETWORKING
   /etc/rc.d/mountcritremote
   /etc/rc.d/syslogd
   /etc/rc.d/SERVERS
   /etc/rc.d/DAEMON
   /etc/rc.d/LOGIN
   ```

2. Inspect the dependency block header of `/etc/rc.d/syslogd` to analyze its execution parameters:
   ```bash
   head -n 15 /etc/rc.d/syslogd
   ```
   **Expected CLI Output:**
   ```sh
   #!/bin/sh
   #
   # $FreeBSD$
   #

   # PROVIDE: syslogd
   # REQUIRE: mountcritremote cleanvar newsyslog
   # BEFORE:  SERVERS
   # KEYWORD: shutdown
   ```

3. Evaluate reverse execution order used during system shutdown (`rc.shutdown` execution simulation):
   ```bash
   rcorder -k shutdown /etc/rc.d/* /usr/local/etc/rc.d/* 2>/dev/null | tail -n 15
   ```
   **Expected CLI Output:**
   ```text
   /etc/rc.d/syslogd
   /etc/rc.d/mountcritremote
   /etc/rc.d/NETWORKING
   /etc/rc.d/routing
   /etc/rc.d/mountcritlocal
   /etc/rc.d/var
   ```

---

#### Verification Questions (Exercise 1)

1. **Q1.1:** If a custom service script defines `# REQUIRE: DAEMON` and `# BEFORE: LOGIN`, where in the initialization lifecycle will `rcorder` place this script relative to network availability and user login services?
2. **Q1.2:** What occurs if two scripts create a circular dependency loop (e.g., Script A requires Script B, and Script B requires Script A)? How does `rcorder(8)` handle this state?

---

### Exercise 2: Authoring & Deploying a Production-Grade `rc.subr` Daemon Script

#### Scenario & Goal
You are deploying a custom internal telemetry daemon named `node_exporter_custom` on FreeBSD. You must create a syntactically valid `/etc/rc.subr` wrapper script, place it in `/usr/local/etc/rc.d/node_exporter_custom`, ensure proper execution privileges, configure unprivileged execution (`daemon_user`), PID tracking, and verify runtime controls via `service(8)`.

#### Step-by-Step Execution Procedure

1. Create the dedicated daemon user and directory structure:
   ```bash
   pw useradd -n telemetry -d /nonexistent -s /usr/sbin/nologin -c "Telemetry Daemon User"
   mkdir -p /usr/local/etc/rc.d /var/run/node_exporter_custom
   chown -R telemetry:telemetry /var/run/node_exporter_custom
   ```

2. Create the complete, syntactically valid `rc.subr` wrapper script at `/usr/local/etc/rc.d/node_exporter_custom`:
   ```sh
   cat << 'EOF' > /usr/local/etc/rc.d/node_exporter_custom
   #!/bin/sh
   #
   # PROVIDE: node_exporter_custom
   # REQUIRE: LOGIN
   # KEYWORD: shutdown
   #
   # Add the following lines to /etc/rc.conf to enable node_exporter_custom:
   # node_exporter_custom_enable="YES"
   # node_exporter_custom_flags="--listen-addr=:9100"
   #

   . /etc/rc.subr

   name="node_exporter_custom"
   rcvar="node_exporter_custom_enable"

   load_rc_config $name

   : ${node_exporter_custom_enable:="NO"}
   : ${node_exporter_custom_user:="telemetry"}
   : ${node_exporter_custom_group:="telemetry"}
   : ${node_exporter_custom_flags:="--port=9100"}

   command="/usr/sbin/daemon"
   pidfile="/var/run/${name}/${name}.pid"
   procname="/usr/bin/nc"

   # Use daemon(8) helper to manage background execution and PID creation
   command_args="-f -p ${pidfile} -u ${node_exporter_custom_user} /usr/bin/nc -l 127.0.0.1 9100"

   run_rc_command "$1"
   EOF
   ```

3. Set strict production permissions on the script:
   ```bash
   chmod 0755 /usr/local/etc/rc.d/node_exporter_custom
   chown root:wheel /usr/local/etc/rc.d/node_exporter_custom
   ```

4. Enable the service non-destructively using `sysrc(8)`:
   ```bash
   sysrc node_exporter_custom_enable="YES"
   sysrc node_exporter_custom_flags="--port=9100"
   ```
   **Expected CLI Output:**
   ```text
   node_exporter_custom_enable: NO -> YES
   node_exporter_custom_flags:  -> --port=9100
   ```

5. Validate configuration loading and start the service via `service(8)`:
   ```bash
   service node_exporter_custom status
   service node_exporter_custom start
   service node_exporter_custom status
   ```
   **Expected CLI Output:**
   ```text
   node_exporter_custom is not running.
   Starting node_exporter_custom.
   node_exporter_custom is running as pid 48291.
   ```

6. Inspect running process details to verify drop of privileges to `telemetry`:
   ```bash
   ps -aux -U telemetry
   ```
   **Expected CLI Output:**
   ```text
   USER       PID %CPU %MEM   VSZ  RSS TT  STAT STARTED      TIME COMMAND
   telemetry 48291  0.0  0.1 12740 2412  -  I    20:15     0:00.01 /usr/bin/nc -l 127.0.0.1 9100
   ```

---

#### Verification Questions (Exercise 2)

1. **Q2.1:** What is the specific purpose of the function call `load_rc_config $name` inside an `rc.subr` script, and what occurs if it is omitted?
2. **Q2.2:** Why is parameter substitution syntax `: ${node_exporter_custom_enable:="NO"}` utilized instead of direct assignment `node_exporter_custom_enable="NO"` within the script body?

---

### Exercise 3: Cross-BSD Service Lifecycle Management (`sysrc` vs `rcctl`)

#### Scenario & Goal
In a heterogeneous BSD environment, an SRE must manage system daemons using vendor-native tools. You will perform state management (query, enable, flags modification, status checks) on **FreeBSD/NetBSD** using `sysrc(8)` / `service(8)` and on **OpenBSD** using `rcctl(8)`.

#### Step-by-Step Execution Procedure

##### Part A: FreeBSD / NetBSD Execution (`sysrc` & `service`)

1. Query all currently enabled services across the system:
   ```bash
   service -e
   ```
   **Expected CLI Output:**
   ```text
   /etc/rc.d/hostid
   /etc/rc.d/zfs
   /etc/rc.d/cleanvar
   /etc/rc.d/newsyslog
   /etc/rc.d/syslogd
   /etc/rc.d/sshd
   /etc/rc.d/cron
   ```

2. Inspect service configuration variables non-destructively:
   ```bash
   sysrc -a | grep sshd
   ```
   **Expected CLI Output:**
   ```text
   sshd_enable: YES
   sshd_flags: -4
   ```

3. Modifying service runtime flags and verifying `/etc/rc.conf` atomic updates:
   ```bash
   sysrc sshd_flags="-4 -o LogLevel=VERBOSE"
   cat /etc/rc.conf | grep sshd
   ```
   **Expected CLI Output:**
   ```text
   sshd_flags: -4 -> -4 -o LogLevel=VERBOSE
   sshd_enable="YES"
   sshd_flags="-4 -o LogLevel=VERBOSE"
   ```

4. Query the full path of the script implementing the `sshd` service:
   ```bash
   service -j * sshd rcvar
   ```
   or
   ```bash
   service sshd details
   ```
   **Expected CLI Output:**
   ```text
   # sshd
   #
   sshd_enable="YES"
   # (default: "")
   ```

---

##### Part B: OpenBSD Execution (`rcctl`)

1. Enable the `nginx` daemon and set local flags using `rcctl(8)`:
   ```bash
   rcctl enable nginx
   rcctl set nginx flags "-T"
   rcctl set nginx status on
   ```

2. Query service state and local configuration overrides in `/etc/rc.conf.local`:
   ```bash
   rcctl get nginx
   ```
   **Expected CLI Output:**
   ```text
   nginx_class=daemon
   nginx_flags=-T
   nginx_logger=
   nginx_rtable=0
   nginx_timeout=30
   nginx_user=root
   nginx_status=on
   ```

3. Inspect daemon check status across all enabled OpenBSD daemons:
   ```bash
   rcctl ls check
   ```
   **Expected CLI Output:**
   ```text
   pf(failed)
   sshd(ok)
   ntpd(ok)
   nginx(failed)
   ```

4. Display services disabled in base but overridden in `/etc/rc.conf.local`:
   ```bash
   rcctl ls local
   ```
   **Expected CLI Output:**
   ```text
   nginx
   ```

---

#### Verification Questions (Exercise 3)

1. **Q3.1:** On OpenBSD, which file is directly updated when executing `rcctl set daemon flags "-v"`, and why should administrators never edit `/etc/rc.conf` directly on OpenBSD?
2. **Q3.2:** What is the technical difference between running `service nginx start` and `service nginx one-start` on FreeBSD?

---

### Exercise 4: Advanced Boot Diagnostics & Troubleshooting Stalled Inits

#### Scenario & Goal
A production FreeBSD node failed during boot due to a syntax error in a custom `rc.d` script causing `rcorder` execution failure, freezing the boot trajectory before `sshd` initialization. You must boot into Single-User Mode, isolate the failure using boot flags and `rc_debug`, fix the issue, and resume execution.

#### Step-by-Step Execution Procedure

1. **Simulate Boot Failure Ingress:**
   Boot into Single-User Mode at the loader prompt (`OK` prompt):
   ```text
   OK boot -s
   ```
   *Alternative:* Select option `2` (Single User Mode) on the FreeBSD boot menu.

2. **Mount Filesystems Read-Write:**
   When prompted for shell path (`/bin/sh`), press Enter. Mount root and `/usr` in read-write mode:
   ```bash
   mount -u -w /
   mount -a -t ufs,zfs
   ```
   **Expected CLI Output:**
   ```text
   Root filesystem has been re-mounted read-write.
   ```

3. **Trace Startup Script Execution with Boot Diagnostics Enabled:**
   Execute `/etc/rc` manually with kernel boot tracing and `rc_debug` overrides enabled:
   ```bash
   export rc_debug="YES"
   export rc_info="YES"
   sh -x /etc/rc 2>&1 | tee /tmp/boot_debug.log | grep -E "WARNING|ERROR|run_rc_command"
   ```
   **Expected CLI Output:**
   ```text
   + run_rc_command start
   /etc/rc: WARNING: /usr/local/etc/rc.d/broken_script has invalid dependency headers.
   rcorder: circular dependency in script /usr/local/etc/rc.d/broken_script.
   ```

4. **Isolate and Quarantining the Faulty Script:**
   Query `rcorder` directly against the package directory to pinpoint offending file syntax:
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* > /dev/null
   ```
   **Expected CLI Output:**
   ```text
   rcorder: circular dependency: /usr/local/etc/rc.d/broken_script
   rcorder: requirement `broken_script' in /usr/local/etc/rc.d/broken_script forms a loop.
   ```

5. **Disable and Quarantine Offending Script:**
   ```bash
   mv /usr/local/etc/rc.d/broken_script /usr/local/etc/rc.d/broken_script.disabled
   ```

6. **Verify Boot Ordering Restoration & Transition to Multi-User:**
   ```bash
   rcorder /etc/rc.d/* /usr/local/etc/rc.d/* | grep -E "sshd|LOGIN"
   exit
   ```
   *(Exiting the single-user shell causes init to continue booting into multi-user mode).*

---

#### Verification Questions (Exercise 4)

1. **Q4.1:** How does setting `rc_debug="YES"` in `/etc/rc.conf` alter the behavior of `rc.subr` command execution during system boot?
2. **Q4.2:** Which kernel boot flag forces the FreeBSD kernel to output verbose driver probes and detailed `init(8)` invocation logs during early startup?

---

## Solutions & Answer Key

<details>
<summary><b>Click to expand Detailed Answers & Technical Explanations</b></summary>

### Exercise 1 Solutions

- **A1.1:** `rcorder(8)` will place the script after all scripts providing the `DAEMON` keyword (which includes basic system daemons like syslogd and rpcbind) and strictly before scripts providing the `LOGIN` keyword (which gate user session establishment and pseudo-terminals). Thus, the script runs during the late system services phase, after core networking/daemons but prior to user logins.
- **A1.2:** `rcorder(8)` detects directed graph cycles during its topological sort phase. It emits a diagnostic warning to stderr (`rcorder: circular dependency in script...`), breaks the cycle arbitrarily to prevent an infinite loop deadlock, and continues ordering the remaining scripts. This warning can stall non-interactive boots if `rc_fast=NO` or lead to unpredictable dependency execution order.

---

### Exercise 2 Solutions

- **A2.1:** `load_rc_config $name` reads `/etc/defaults/rc.conf`, `/etc/rc.conf`, `/etc/rc.conf.local`, and `/etc/rc.conf.d/$name` to populate variables defined for `$name` (such as `${name}_enable`, `${name}_flags`, `${name}_user`). If omitted, the script fails to inherit system overrides configured via `sysrc` or `/etc/rc.conf`, falling back strictly to internal hardcoded script defaults or failing variable check assertions in `run_rc_command`.
- **A2.2:** The `: ${var:="value"}` construct is standard POSIX shell syntax for *default variable assignment if unset or null*. If `load_rc_config` imported a setting from `/etc/rc.conf` (e.g., `node_exporter_custom_enable="YES"`), the `: ${...}` expression preserves the user-configured setting. Hardcoded assignment (`node_exporter_custom_enable="NO"`) would unconditionally overwrite user settings specified in `/etc/rc.conf`.

---

### Exercise 3 Solutions

- **A3.1:** Executing `rcctl set daemon flags "-v"` updates `/etc/rc.conf.local` on OpenBSD. Administrators must never edit `/etc/rc.conf` directly on OpenBSD because `/etc/rc.conf` contains base system defaults overwritten in full during system upgrades (`sysmerge(8)` / `sysupgrade(8)`). All administrator modifications are strictly isolated in `/etc/rc.conf.local`.
- **A3.2:** `service nginx start` checks the value of `nginx_enable` in `/etc/rc.conf`. If set to `"NO"`, execution terminates without starting the daemon. `service nginx one-start` overrides the `rcvar` enablement check, executing the startup routine once regardless of whether `nginx_enable` is set to `"YES"` or `"NO"`.

---

### Exercise 4 Solutions

- **A4.1:** Setting `rc_debug="YES"` causes `rc.subr` helper routines to print detailed shell debugging info for every function call. It displays the exact values of variables (`$command`, `$command_args`, `$pidfile`), prints environmental overrides, and outputs the exact final shell command string evaluated by `eval` prior to daemon execution.
- **A4.2:** The `-v` flag (Verbose Boot). Passing `-v` at the bootloader prompt (`boot -v` or setting `boot_verbose="YES"` in `/boot/loader.conf`) causes the kernel to emit extra diagnostic messages regarding hardware enumeration, device driver attachment, and `init(8)` startup processing.

</details>

---

### Official Reference Links & Citations
- [FreeBSD rc.subr Manual Page](https://man.freebsd.org/cgi/man.cgi?query=rc.subr&sektion=8)
- [FreeBSD rcorder Manual Page](https://man.freebsd.org/cgi/man.cgi?query=rcorder&sektion=8)
- [OpenBSD rcctl Manual Page](https://man.openbsd.org/rcctl.8)
- [OpenBSD rc.subr Manual Page](https://man.openbsd.org/rc.subr.8)
- [NetBSD rc.conf Manual Page](https://man.netbsd.org/rc.conf.5)
- [LPI BSD Specialist Certification Page](https://www.lpi.org/our-certifications/bsd-specialist-overview/)