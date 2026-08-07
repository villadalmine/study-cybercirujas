# Study Guide: LPI BSD Specialist (Exam 702-100, Version 1.0)
## Topic 711.3: BSD System Startup Configuration
**Weight:** 5  
**Target Level:** Senior SRE / Principal Platform Architect

---

## 1. Architectural Motivation & Production Context

In mission-critical enterprise deployments, deterministic and predictable initialization of the operating system lifecycle is essential. Unlike modern Linux distributions that rely heavily on `systemd` (a monolithic target-based initialization daemon using socket activation and parallel execution with complex state engines), BSD systems adhere strictly to the Unix philosophy of clear separation of concerns, linear predictability, and shell-scripted modular initialization via the `rc.subr(8)` framework and `rcorder(8)`.

```
+-----------------------------------------------------------------------------------+
|                                 BOOT LIFECYCLE                                    |
+-----------------------------------------------------------------------------------+
|  [Hardware / UEFI]                                                                |
|         |                                                                         |
|         v                                                                         |
|  [Stage 1/2 Bootloader: /boot/loader] ---> Reads /boot/loader.conf                |
|         |                                   (Loads kernel & early drivers/tunables)|
|         v                                                                         |
|  [Kernel Initialization: /boot/kernel/kernel]                                     |
|         |                                   (Mounts root filesystem, initializes  |
|         v                                    devices, creates init PID 1)         |
|  [Process 1: /sbin/init]                                                          |
|         |                                   (Executes /etc/rc script)             |
|         v                                                                         |
|  [Initialization Framework: /etc/rc]                                             |
|         |                                                                         |
|         +---> Evaluates /etc/defaults/rc.conf + /etc/rc.conf                      |
|         |                                                                         |
|         +---> Invokes rcorder(8) over /etc/rc.d/* & /usr/local/etc/rc.d/*        |
|         |                                                                         |
|         v                                                                         |
|  [Service Execution Flow] (Ordered by PROVIDE, REQUIRE, BEFORE, KEYWORD)          |
+-----------------------------------------------------------------------------------+
```

From an SRE and Platform Engineering perspective, mastering the BSD startup sequence guarantees:
- **State Determinism**: Dependencies between network interfaces, storage pools (ZFS), routing daemons, and application services are strictly enforced via Directed Acyclic Graphs (DAGs) generated at boot time.
- **Fail-safe Configuration Splitting**: Base system defaults (`/etc/defaults/rc.conf`) are cleanly decoupled from administrator overrides (`/etc/rc.conf` or `/etc/rc.conf.d/*`), minimizing configuration drift during OS upgrades.
- **Zero-Dependency Core Tools**: Initial boot recovery scripts depend solely on `/bin/sh` and POSIX-compliant primitives, preventing chicken-and-egg boot failures caused by dynamically linked runtime libraries.

---

## 2. Deep Dive Mechanics & Technical Comparison

### 2.1 The Startup Chain Mechanics

1. **Bootloader Phase (`/boot/loader`)**: Reads `/boot/loader.conf` and `/boot/defaults/loader.conf`. Loads kernel modules (e.g., `zfs.ko`, `accf_http.ko`), initializes early kernel environment variables (`kenv`), and configures low-level memory layout before kernel execution.
2. **Kernel Phase (`kernel`)**: Boots, probe-detects hardware, configures Virtual Memory (VM), initializes device nodes via `devfs`, mounts root (`/`), and forks userland process `init` (PID 1).
3. **Userland Init Phase (`/sbin/init`)**: Reads `/etc/ttys` and executes `/etc/rc`.
4. **RC Engine Phase (`/etc/rc`)**: Sources `/etc/rc.subr`. Loads global default settings from `/etc/defaults/rc.conf` followed by `/etc/rc.conf` and site-specific overrides in `/etc/rc.conf.d/`.
5. **Dependency Resolution (`rcorder`)**: Scans block headers of scripts in `/etc/rc.d/` and `/usr/local/etc/rc.d/`. Builds a topological execution order based on dependency keywords (`PROVIDE`, `REQUIRE`, `BEFORE`, `KEYWORD`).

### 2.2 BSD Variant Startup Comparison Matrix

| Feature / Subsystem | FreeBSD | NetBSD | OpenBSD |
| :--- | :--- | :--- | :--- |
| **Primary Init Engine** | `rc.subr(8)` + `rcorder(8)` | `rc.subr(8)` + `rcorder(8)` | Custom `/etc/rc` + `rcctl(8)` |
| **System Defaults File** | `/etc/defaults/rc.conf` | `/etc/defaults/rc.conf` | `/etc/rc.conf` (base defaults) |
| **Local Config File** | `/etc/rc.conf`, `/etc/rc.conf.d/` | `/etc/rc.conf`, `/etc/rc.conf.d/` | `/etc/rc.conf.local` |
| **Third-Party Services** | `/usr/local/etc/rc.d/` | `/usr/pkg/etc/rc.d/` | `/etc/rc.d/` |
| **Service Control CLI** | `service(8)`, `sysrc(8)` | `service(8)` | `rcctl(8)` |
| **Bootloader Config** | `/boot/loader.conf` | `/boot.cfg` | `/etc/boot.conf` |
| **Kernel Tunables** | `/etc/sysctl.conf` & `loader.conf` | `/etc/sysctl.conf` | `/etc/sysctl.conf` |
| **First-Boot Execution** | `/etc/rc.local` / `firstboot` flag | `/etc/rc.local` | `/etc/rc.firsttime` |

---

## 3. Production Configuration & Custom Service Framework

Below are production-ready, fully qualified configuration files demonstrating kernel tuning, service enablement, and custom `rc.subr` service wrapping.

### 3.1 Kernel Bootloader Tunables: `/boot/loader.conf`

```ini
# /boot/loader.conf - Production FreeBSD Hypervisor & Storage Node Configuration

# Core Storage Driver & ZFS Memory Bounds
zfs_load="YES"
vfs.zfs.arc.max="34359738368"             # Limit ZFS ARC to 32 GB RAM

# Network Subsystem Buffer Allocation & Hardware Offload Tunables
kern.ipc.nmbclusters="1048576"            # Expand network mbuf clusters for 10GbE/40GbE
net.inet.tcp.tcbhashsize="524288"         # Increase TCP Control Block hash table size

# Asynchronous HTTP Accept Filter Kernel Module
accf_http_load="YES"
accf_data_load="YES"

# Crypto Acceleration Driver
cryptodev_load="YES"
aesni_load="YES"

# Link Aggregation & VLAN Support
if_lagg_load="YES"
if_vlan_load="YES"

# Security & Console Silence
autoboot_delay="3"
beastie_disable="YES"
loader_color="NO"
```

---

### 3.2 Runtime Kernel State Defaults: `/etc/sysctl.conf`

```ini
# /etc/sysctl.conf - Production Runtime Kernel State Tuning

# Network Stack Security & Performance
net.inet.tcp.rfc1323=1                    # Enable Window Scaling & Timestamps
net.inet.tcp.mssdflt=1460                 # Default Maximum Segment Size
net.inet.tcp.sendspace=262144             # 256KB TCP Send Buffer
net.inet.tcp.recvspace=262144             # 256KB TCP Receive Buffer
net.inet.tcp.drop_synfin=1                # Drop invalid SYN+FIN packets (port scan countermeasure)
net.inet.ip.redirect=0                    # Disable ICMP redirect sending

# Process & Virtual Memory Limits
kern.maxproc=65536                        # Global max processes
kern.maxfiles=2097152                     # Global file descriptor ceiling
kern.ipc.somaxconn=4096                   # Listen queue limit for sockets

# Shared Memory for Database Engines (PostgreSQL / Redis)
kern.ipc.shmmax=34359738368
kern.ipc.shmall=8388608
```

---

### 3.3 System Initialization Overrides: `/etc/rc.conf`

```sh
# /etc/rc.conf - Primary System Service Configuration

# Host identity and Network Infrastructure
hostname="edge-node-01.prod.internal"
keymap="us.iso.acc"

# Interface Addressing & Link Aggregation (LACP)
cloned_interfaces="lagg0 vlan100"
ifconfig_ix0="up"
ifconfig_ix1="up"
ifconfig_lagg0="laggproto lacp laggport ix0 laggport ix1 up"
ifconfig_vlan100="inet 192.168.100.15 netmask 255.255.255.0 vlan 100 vlandev lagg0"
defaultrouter="192.168.100.1"

# Core System Daemons
sshd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
syslogd_flags="-s -s"                     # Secure mode: Do not listen on UDP network ports

# Core Storage & File Systems
zfs_enable="YES"
dumpdev="AUTO"                            # Enable kernel crash dumps

# Third-Party Production Daemons
nginx_enable="YES"
postgresql_enable="YES"
node_exporter_enable="YES"

# Custom Service Settings Override via Inline Subdir Processing
rc_conf_files="/etc/rc.conf /etc/rc.conf.local"
```

---

### 3.4 Enterprise Service Unit Script: `/usr/local/etc/rc.d/sre_app`

This syntactically valid FreeBSD `rc.subr` script implements proper dependency block declarations, process tracking, runtime directory management, and custom commands.

```sh
#!/bin/sh

# PROVIDE: sre_app
# REQUIRE: LOGIN DAEMON NETWORKING postgresql
# BEFORE:  nginx
# KEYWORD: shutdown

. /etc/rc.subr

name="sre_app"
rcvar="sre_app_enable"

# Load default configurations
load_rc_config ${name}

: ${sre_app_enable:="NO"}
: ${sre_app_user:="www"}
: ${sre_app_group:="www"}
: ${sre_app_config:="/usr/local/etc/sre_app/config.yaml"}
: ${sre_app_pidfile:="/var/run/sre_app/sre_app.pid"}

command="/usr/local/bin/sre_app_exporter"
command_args="-config ${sre_app_config} > /var/log/sre_app.log 2>&1 &"
pidfile="${sre_app_pidfile}"

start_precmd="sre_app_prestart"
extra_commands="reload status checkconfig"
reload_cmd="sre_app_reload"
checkconfig_cmd="sre_app_checkconfig"

sre_app_prestart()
{
    if [ ! -d "/var/run/sre_app" ]; then
        install -d -o ${sre_app_user} -g ${sre_app_group} -m 0755 /var/run/sre_app
    fi
    if [ ! -f "${sre_app_config}" ]; then
        err 1 "Configuration file ${sre_app_config} does not exist."
    fi
}

sre_app_checkconfig()
{
    echo "Verifying syntax for ${name} configuration..."
    ${command} -validate -config ${sre_app_config}
}

sre_app_reload()
{
    echo "Reloading ${name} configuration..."
    if [ -f "${pidfile}" ]; then
        kill -HUP $(cat ${pidfile})
    else
        echo "${name} is not running."
    fi
}

run_rc_command "$1"
```

---

## 4. Real CLI Execution & Service Operations

### 4.1 Inspecting & Modifying `rc.conf` safely using `sysrc(8)`

`sysrc` provides atomic editing of `/etc/rc.conf` and safe queries without risk of syntax degradation.

```console
$ sysrc sre_app_enable
sre_app_enable: NO

$ sudo sysrc sre_app_enable="YES"
sre_app_enable: NO -> YES

$ sysrc -f /etc/rc.conf.d/sre_app sre_app_flags="--verbose --port=9090"
sre_app_flags:  -> --verbose --port=9090

$ sysrc -a | grep _enable | head -n 5
sshd_enable: YES
ntpd_enable: YES
zfs_enable: YES
nginx_enable: YES
postgresql_enable: YES
```

---

### 4.2 Querying System Service Status via `service(8)`

The `service` utility abstracts `/etc/rc.d/` and `/usr/local/etc/rc.d/` script paths.

```console
$ service -e
/etc/rc.d/hostid
/etc/rc.d/zfs
/etc/rc.d/netif
/etc/rc.d/routing
/etc/rc.d/sshd
/etc/rc.d/ntpd
/usr/local/etc/rc.d/postgresql
/usr/local/etc/rc.d/sre_app
/usr/local/etc/rc.d/nginx

$ service sre_app status
sre_app is running as pid 48291.

$ service sre_app checkconfig
Verifying syntax for sre_app configuration...
Configuration /usr/local/etc/sre_app/config.yaml is valid.
```

---

### 4.3 Resolving Dependency Ordering with `rcorder(8)`

`rcorder` processes block headers (`PROVIDE`, `REQUIRE`, `BEFORE`) and generates the precise dependency resolution stream used by `/etc/rc`.

```console
$ rcorder /etc/rc.d/* /usr/local/etc/rc.d/* | grep -E '(postgresql|sre_app|nginx)'
/usr/local/etc/rc.d/postgresql
/usr/local/etc/rc.d/sre_app
/usr/local/etc/rc.d/nginx
```

---

### 4.4 OpenBSD Service Management with `rcctl(8)`

For OpenBSD environments, service enablement and daemon flags are managed using `rcctl`.

```console
$ rcctl get ntpd
ntpd_class=daemon
ntpd_flags=
ntpd_timeout=30
ntpd_user=root
ntpd_status=on

$ sudo rcctl set pf status on
$ sudo rcctl enable custom_daemon
$ sudo rcctl set custom_daemon flags "-d -s /var/run/custom.sock"
$ rcctl ls failed
custom_daemon
```

---

### 4.5 Managing Kernel Modules at Boot and Runtime

```console
$ kldstat
Id Refs Address            Size     Name
 1   29 0xffffffff80200000 1f3c500  kernel
 2    1 0xffffffff8213d000 5b6c0    zfs.ko
 3    1 0xffffffff82199000 31a8     accf_http.ko
 4    1 0xffffffff8219d000 84e0     aesni.ko

$ sudo kldload accf_data
$ kldstat | grep accf
 3    1 0xffffffff82199000 31a8     accf_http.ko
 5    1 0xffffffff821a6000 2a10     accf_data.ko
```

---

## 5. Diagnostic & Failure Troubleshooting Guide

### 5.1 Common Production Failure Modes

```
+-----------------------------------------------------------------------------------+
|                           COMMON RC FAILURE MODES                                 |
+-----------------------------------------------------------------------------------+
|  1. Circular Dependency Cycle in rc.d Block Headers                                |
|     --> rcorder detects loop and aborts or falls back to unsafe default.           |
|                                                                                   |
|  2. Hardcoded File System Paths Pre-LOGIN Stage                                    |
|     --> Script REQUIRES LOGIN, but tries to access /usr/local prior to /usr mount. |
|                                                                                   |
|  3. Missing 'rcvar' Assignment in Shell Functions                                 |
|     --> Service fails to respect ${name}_enable check in /etc/rc.conf.            |
|                                                                                   |
|  4. Silent Hanging in Background Forking                                          |
|     --> Script lacks proper daemon helper usage or pidfile dynamic locking.       |
+-----------------------------------------------------------------------------------+
```

---

### 5.2 Step-by-Step Troubleshooting Procedure

#### Step 1: Enable RC Tracing and Debugging
If a system hangs during startup, edit `/etc/rc.conf` or pass debug variables at the boot prompt:

```console
$ sudo sysrc rc_debug="YES"
rc_debug: NO -> YES

$ sudo sysrc rc_info="YES"
rc_info: NO -> YES
```

When `rc_debug="YES"` is active, `/etc/rc` prints line-by-line execution details and shell command evaluation:

```console
/etc/rc.d/sre_app: DEBUG: run_rc_command: doctype sre_app start
/etc/rc.d/sre_app: DEBUG: check_pidfile: /var/run/sre_app/sre_app.pid sre_app
/etc/rc.d/sre_app: DEBUG: sre_app_enable is YES
/etc/rc.d/sre_app: DEBUG: executing /usr/local/bin/sre_app_exporter -config /usr/local/etc/sre_app/config.yaml
```

#### Step 2: Validate `rcorder` Dependency Graph Integrity
To detect circular dependencies or isolated scripts that break boot flow:

```console
$ rcorder -s nostart /etc/rc.d/* /usr/local/etc/rc.d/* > /dev/null
rcorder: circular dependency in script /usr/local/etc/rc.d/bad_script
```

#### Step 3: Recovering from Boot Lockouts via Single-User Mode
If a corrupt `/etc/rc.conf` prevents successful multi-user startup:

1. Reboot the server. At the FreeBSD loader boot menu, select Option `2` for **Single User Mode**.
2. Mount the root filesystem read-write:
   ```console
   # mount -o rw /
   # zfs mount -a
   ```
3. Test `/etc/rc.conf` syntax:
   ```console
   # sh -n /etc/rc.conf
   # sh -n /etc/rc.conf.d/*
   ```
4. Fix syntax errors using `vi` or reset `rc.conf`:
   ```console
   # sysrc -f /etc/rc.conf sre_app_enable="NO"
   # exit
   ```

---

## 6. References

- **LPI BSD Specialist Overview (Exam 702-100)**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/
- **FreeBSD Handbook — The Booting Process**:  
  https://docs.freebsd.org/en/books/handbook/boot/
- **FreeBSD Manual Pages — `rc.subr(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=rc.subr
- **FreeBSD Manual Pages — `rcorder(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=rcorder
- **FreeBSD Manual Pages — `sysrc(8)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=sysrc
- **OpenBSD Manual Pages — `rcctl(8)`**:  
  https://man.openbsd.org/rcctl
- **NetBSD Guide — The `rc.d` System**:  
  https://www.netbsd.org/docs/guide/en/chap-rc.html