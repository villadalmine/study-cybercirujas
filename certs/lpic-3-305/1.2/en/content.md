# LPIC-3 Exam 305-300: Topic 352 — Container Virtualization (Production SRE & Platform Architecture Guide)

---

## 1. Production Motivation & Architectural Problem Statement

In high-density production environments, traditional hardware virtualization (Type-1/Type-2 Hypervisors) introduces substantial performance overhead. Each Virtual Machine (VM) mandates a dedicated guest operating system, virtual CPU scheduling layer, full memory pre-allocation, and emulation of virtual PCI devices. This architecture incurs significant resource waste:
- **Memory Footprint Overhead:** Guest OS kernels and baseline system daemons consume 500 MiB–2 GiB per VM prior to running application workloads.
- **Latency & CPU Penalties:** Two-level scheduling (Host Hypervisor Scheduler $\rightarrow$ Guest OS Scheduler) and CPU instruction virtualization (nested page tables, MMU translation via EPT/NPT) add tail-latency penalties.
- **Cold Boot Time:** Initializing full guest OS init systems (systemd, kernel self-tests, hardware device tree enumeration) requires 10 to 60 seconds, rendering sub-second horizontal autoscaling impossible.

**Container Virtualization** solves these architectural bottlenecks by providing **OS-level virtualization**. Multiple isolated user-space instances (containers) execute directly on a single shared Linux host kernel. Isolation is achieved without hypervisor layers through native Linux kernel primitives: **Namespaces** (for resource visibility isolation), **Control Groups (cgroups)** (for resource consumption limits and accounting), and **Security Profiles** (Seccomp, Capabilities, LSMs).

### Architectural Trade-offs: VM vs. Container

```
+------------------------------------+  +------------------------------------+
|         App A        |    App B    |  |   App A   |   App B   |    App C   |
+----------------------+-------------+  +-----------+-----------+------------+
|      Guest OS        |  Guest OS   |  |        Container Runtime           |
+----------------------+-------------+  +------------------------------------+
|             Hypervisor             |  |      Linux Host Kernel             |
+------------------------------------+  | (Namespaces, cgroups, Seccomp)     |
|      Host Operating System         |  +------------------------------------+
+------------------------------------+  |           Bare Metal Hardware      |
|        Bare Metal Hardware         |  +------------------------------------+
+------------------------------------+
       HYPERVISOR VIRTUALIZATION                   CONTAINER VIRTUALIZATION
```

1. **Security Isolation:** Containers share the host kernel execution context. A privilege escalation vulnerability in a kernel syscall (e.g., dirty COW, buffer overflows in kernel drivers) compromises the entire host node and all adjacent co-located containers. Hypervisors enforce a hard boundary via hardware-assisted CPU modes (VMX root vs. non-root operation).
2. **Kernel Heterogeneity:** Containers cannot execute non-Linux operating systems or kernel versions differing from the host host kernel (e.g., running Windows Server kernel or FreeBSD natively on a Linux host).
3. **Noisy Neighbor Control:** Weakly configured container cgroups can trigger CPU throttling cascades, I/O starvations, or kernel page-cache lock contention across unrelated tenant containers.

---

## 2. Technical Architecture & Internal Mechanics

Container virtualization rests upon four distinct Linux kernel security and isolation subsystems.

### 2.1 Linux Kernel Namespaces

Namespaces wrap global system resources into isolated abstractions. A process operating within a namespace perceives only the resources allocated to its specific slice.

| Namespace | Kernel Flag | Isolated Resource | Path in `/proc/[pid]/ns/` |
| :--- | :--- | :--- | :--- |
| **Mount (mnt)** | `CLONE_NEWNS` | File system mount points and file tree structure | `/proc/[pid]/ns/mnt` |
| **Process ID (pid)** | `CLONE_NEWPID` | Process IDs, parent-child process tree | `/proc/[pid]/ns/pid` |
| **Network (net)** | `CLONE_NEWNET` | Network devices, IP routing tables, firewall rules, socket ports | `/proc/[pid]/ns/net` |
| **Inter-Process (ipc)** | `CLONE_NEWIPC` | System V IPC objects, System V shared memory, POSIX message queues | `/proc/[pid]/ns/ipc` |
| **UNIX Timesharing (uts)** | `CLONE_NEWUTS` | Hostname and NIS domain name | `/proc/[pid]/ns/uts` |
| **User (user)** | `CLONE_NEWUSER` | User IDs (UID) and Group IDs (GID) mappings | `/proc/[pid]/ns/user` |
| **Control Group (cgroup)** | `CLONE_NEWCGROUP` | Root cgroup directory structure view | `/proc/[pid]/ns/cgroup` |
| **Time (time)** | `CLONE_NEWTIME` | Monotonic and boot system clocks | `/proc/[pid]/ns/time` |

#### Namespace Mechanics via `clone()` and `unshare()`
Namespaces are instantiated via the system call `clone(..., CLONE_NEWPID | CLONE_NEWNET | ...)` during child process creation, or retroactively attached using `unshare(flags)` or `setns(fd, nstype)`.

---

### 2.2 Control Groups (cgroups v1 vs. cgroups v2)

Control groups enforce resource metering, prioritization, and hard cap limits (CPU, Memory, Block I/O, Network, PIDs) for groups of processes.

#### Architectural Shift: cgroups v1 vs. cgroups v2
- **cgroups v1 (Multi-Hierarchy):** Every controller (memory, cpu, blkio, pids) operates independently in a separate hierarchy mounted under `/sys/fs/cgroup/<controller>/`. A process can belong to `memory/groupA` but `cpu/groupB`. This multi-hierarchy model resulted in race conditions during process migration, broken page-cache writeback I/O attribution, and unresolvable deadlocks.
- **cgroups v2 (Unified Hierarchy):** Mounted as a single unified tree at `/sys/fs/cgroup/`. All processes exist in a single hierarchy. Controllers are explicitly enabled downstream using `cgroup.subtree_control`. Processes can only reside in leaf nodes ("no internal process constraint").

```
cgroups v1 (Split Trees)              cgroups v2 (Unified Tree)
/sys/fs/cgroup/                      /sys/fs/cgroup/
├── cpu/                              ├── cgroup.controllers
│   └── docker/<id>/                  ├── cgroup.subtree_control (+cpu +memory)
└── memory/                           └── system.slice/
    └── docker/<id>/                      └── docker-<id>.scope/
                                              ├── cgroup.procs
                                              ├── memory.max
                                              └── cpu.max
```

#### Pressure Stall Information (PSI) in cgroups v2
cgroups v2 introduces PSI counters (`memory.pressure`, `cpu.pressure`, `io.pressure`) providing early-warning telemetry on resource starvation before Out-Of-Memory (OOM) killer events occur:
- **some:** Percentage of time during which at least one task was stalled on a resource.
- **full:** Percentage of time during which *all* non-idle tasks were stalled concurrently.

---

### 2.3 Security Hardening Layers

1. **Linux Capabilities (`capabilities(7)`):** Divides the all-powerful `root` UID 0 privilege set into 41 distinct fine-grained units (e.g., `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_CHOWN`). Containers drop critical capabilities (such as `CAP_SYS_ADMIN`, `CAP_SYS_RAWIO`, `CAP_NET_RAW`) by default to prevent host takeover.
2. **Secure Computing Mode (Seccomp BPF):** Filters system calls issued by container processes to the host kernel. A BPF program evaluates system call numbers and arguments. If a container invokes a blacklisted system call (e.g., `reboot()`, `kexec_load()`, `init_module()`), the kernel emits `EPERM` or immediately terminates the process with `SIGSYS`.
3. **Linux Security Modules (LSM - AppArmor / SELinux):** Mandatory Access Control (MAC) engine.
   - **AppArmor:** Path-based isolation profile restricting which file paths, capabilities, and network protocols a container can access.
   - **SELinux:** Type Enforcement and Multi-Category Security (MCS) labeling (`system_u:object_r:container_file_t:s0:c123,c456`). Prevents container process label `container_t` from accessing unlabeled host paths.

---

### 2.4 Open Container Initiative (OCI) Standards & Runtime Hierarchy

The container runtime stack operates in a decoupled layered architecture governed by OCI specifications:

```
+-------------------------------------------------------------------------+
| High-Level Orchestrator (Kubernetes kubelet / Docker CLI / Podman)     |
+-------------------------------------------------------------------------+
                                    | (gRPC / CRI)
                                    v
+-------------------------------------------------------------------------+
| High-Level Container Runtime (containerd / CRI-O)                       |
| - Image Pulling / Unpacking (OCI Image Spec)                            |
| - Storage Layer Assembly (Overlay2)                                     |
| - Execution State Management                                            |
+-------------------------------------------------------------------------+
                                    | (CLI invocation / OCI Spec JSON)
                                    v
+-------------------------------------------------------------------------+
| Low-Level OCI Runtime (runc / crun / kata-runtime)                      |
| - Executes 'clone()' with namespace flags                               |
| - Configures /sys/fs/cgroup nodes                                       |
| - Applies Seccomp BPF filters & Capabilities                            |
| - Execs container entrypoint process                                    |
+-------------------------------------------------------------------------+
                                    | (Linux Syscalls)
                                    v
+-------------------------------------------------------------------------+
| Linux Host Kernel                                                       |
+-------------------------------------------------------------------------+
```

1. **OCI Image Specification:** Defines the format of container image manifests, filesystem layer tarballs (`tar+gzip`), and JSON configuration files (command, environment, entrypoint, layer diff IDs).
2. **OCI Runtime Specification (`spec`):** Defines the state format, execution environment, and lifecycle hooks (`prestart`, `createRuntime`, `createContainer`, `startContainer`, `poststop`) driven by a standard configuration file named `config.json`.

---

## 3. Technical Comparatives & Trade-Off Analysis

### 3.1 System Containers vs. Application Containers vs. MicroVMs

| Dimension | System Containers (LXC/LXD) | Application Containers (Docker/Podman) | MicroVMs (Kata / Firecracker) |
| :--- | :--- | :--- | :--- |
| **Primary Focus** | Full OS user-space replacement (runs `systemd`, `sshd`, multiple services) | Single microservice entrypoint process execution | Hypervisor hardware isolation with container-like speed |
| **Init Process** | `/sbin/init` or `systemd` (PID 1 inside container) | Application binary (e.g., `node`, `nginx`, `go-app`) | Custom minimalist guest kernel init (`kata-agent`) |
| **Isolation Boundary** | Namespaces, cgroups, Seccomp, AppArmor | Namespaces, cgroups, Seccomp, AppArmor | KVM Hardware Virtualization (VMX root/non-root) |
| **Kernel Context** | Shared Host Kernel | Shared Host Kernel | Dedicated Guest Linux Kernel |
| **Boot Latency** | 1.0s – 3.0s | 10ms – 200ms | 100ms – 500ms |
| **Memory Footprint**| ~50 MiB baseline per container | ~5 MiB – 30 MiB baseline | ~30 MiB – 100 MiB baseline |
| **Use Case** | Legacy monolithic app migration, dev environments | Cloud-native microservices, CI/CD builds | Multi-tenant untrusted code execution (Serverless/FaaS) |

---

### 3.2 Storage Drivers Trade-Off Matrix

| Storage Driver | Architecture Mechanics | Read/Write Performance | Disk Space Utilization | Production Suitability & Requirements |
| :--- | :--- | :--- | :--- | :--- |
| **Overlay2** | Union filesystem overlaying `lowerdir` (read-only layers) and `upperdir` (read-write container layer) via kernel overlayfs. | Excellent read; near-native write performance. Modifying large existing files incurs Copy-on-Write (CoW) latency. | High efficiency due to page-cache sharing across identical lower layers. | **Default Production Standard.** Requires `d_type=true` support on underlying filesystem (xfs, ext4). |
| **Btrfs** | Subvolumes and copy-on-write at the block/extent level natively supported by Btrfs filesystem. | Moderate; high write amplification under heavy random I/O workloads. | High efficiency; supports native snapshotting. | Requires entire `/var/lib/docker` or storage path to be formatted as Btrfs. |
| **ZFS** | Dataset clones and ARC (Adaptive Replacement Cache) integration. | High read performance; heavy RAM usage for ARC cache. | High; built-in block compression (zstd/lz4) and deduplication. | Specialized enterprise storage deployments. Requires ZFS kernel modules (`zfs.ko`). |
| **DeviceMapper** | LVM thin provisioning snapshotting at raw block level. | Poor random I/O performance in `loop-lvm` mode; acceptable in `direct-lvm`. | Moderate; allocates block chunks upfront. | **Deprecated.** Do not use in modern production deployments. |

---

### 3.3 OCI Runtimes Trade-Off Matrix

| OCI Runtime | Implementation Language | Isolation Paradigm | Performance Overhead | Security Posture |
| :--- | :--- | :--- | :--- | :--- |
| **runc** | Go | Standard Linux Namespaces & cgroups | Near Zero (Native syscall speed) | Standard container isolation. Vulnerable to host kernel exploits. |
| **crun** | C | Standard Linux Namespaces & cgroups | Minimal memory footprint (~few KB); faster boot than runc | Same as runc, optimized for resource-constrained edge devices. |
| **gVisor (`runsc`)** | Go | User-space Kernel (`Sentry`) intercepting syscalls | Moderate-to-High CPU overhead for syscall-heavy apps | High. Intercepts and implements over 300 Linux syscalls in user space. |
| **Kata Containers** | Go / Rust | Hardware KVM Hypervisor microVM wrapper | Low CPU overhead; fixed RAM allocation per microVM | Maximum. Strong hardware virtualization boundary around each pod. |

---

## 4. Production-Grade Configuration Manifests

### 4.1 LXC Unprivileged Container Configuration File

The following configuration defines an unprivileged LXC system container running with mapped user namespaces, cgroup v2 resource caps, custom veth networking, and restricted capabilities.

```ini
# Location: /var/lib/lxc/sre-production-app/config
# LXC 3.0+ Unprivileged System Container Configuration

# Container Architecture and Type
lxc.arch = amd64
lxc.uts.name = sre-production-app

# User Namespace UID/GID Mapping (Unprivileged Execution)
# Maps container root (0-65536) to unprivileged host range (100000-165536)
lxc.idmap = u 0 100000 65536
lxc.idmap = g 0 100000 65536

# Root Filesystem Path and Storage Settings
lxc.rootfs.path = dir:/var/lib/lxc/sre-production-app/rootfs
lxc.rootfs.managed = 1

# Systemd Compatibility and Mount Points
lxc.mount.auto = proc:mixed sys:ro cgroup:mixed
lxc.autodev = 1

# Network Configuration (veth bridge attachment)
lxc.net.0.type = veth
lxc.net.0.flags = up
lxc.net.0.link = lxcbr0
lxc.net.0.name = eth0
lxc.net.0.hwaddr = 00:16:3e:7a:9b:12
lxc.net.0.ipv4.address = 10.0.3.150/24
lxc.net.0.ipv4.gateway = 10.0.3.1

# Resource Controls (cgroup v2 limits)
lxc.cgroup2.memory.max = 2147483648
lxc.cgroup2.memory.high = 1879048192
lxc.cgroup2.cpu.max = 200000 100000
lxc.cgroup2.pids.max = 1024

# Security Hardening & Dropped Capabilities
lxc.cap.drop = sys_admin sys_rawio sys_module audit_control
lxc.seccomp.profile = /var/lib/lxc/sre-production-app/seccomp.profile
```

---

### 4.2 Low-Level OCI Runtime Specification (`config.json`)

Syntactically valid OCI specification used directly by `runc` or `crun` to launch a low-level application container.

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": false,
    "user": {
      "uid": 1000,
      "gid": 1000
    },
    "args": [
      "/usr/bin/node",
      "/app/server.js"
    ],
    "env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "NODE_ENV=production"
    ],
    "cwd": "/app",
    "capabilities": {
      "bounding": [
        "CAP_NET_BIND_SERVICE",
        "CAP_SETUID",
        "CAP_SETGID"
      ],
      "effective": [
        "CAP_NET_BIND_SERVICE"
      ],
      "inheritable": [],
      "permitted": [
        "CAP_NET_BIND_SERVICE",
        "CAP_SETUID",
        "CAP_SETGID"
      ]
    },
    "rlimits": [
      {
        "type": "RLIMIT_NOFILE",
        "hard": 65536,
        "soft": 32768
      }
    ],
    "noNewPrivileges": true
  },
  "root": {
    "path": "rootfs",
    "readonly": true
  },
  "hostname": "production-api-node",
  "mounts": [
    {
      "destination": "/proc",
      "type": "proc",
      "source": "proc"
    },
    {
      "destination": "/dev",
      "type": "tmpfs",
      "source": "tmpfs",
      "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]
    },
    {
      "destination": "/tmp",
      "type": "tmpfs",
      "source": "tmpfs",
      "options": ["nosuid", "nodev", "noexec", "size=67108864"]
    }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid" },
      { "type": "network" },
      { "type": "ipc" },
      { "type": "uts" },
      { "type": "mount" },
      { "type": "cgroup" }
    ],
    "resources": {
      "memory": {
        "limit": 1073741824,
        "reservation": 536870912
      },
      "cpu": {
        "quota": 100000,
        "period": 100000
      },
      "pids": {
        "limit": 500
      }
    }
  }
}
```

---

### 4.3 Production Docker Daemon Configuration (`/etc/docker/daemon.json`)

Production configuration for `dockerd` incorporating native systemd cgroup v2 alignment, daemon isolation, log rotation, overlay2 verification, and seccomp default enforcement.

```json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "default-shm-size": "128M",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 32768
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 4096,
      "Soft": 2048
    }
  },
  "icc": false,
  "cgroup-parent": "/system.slice/docker.service",
  "seccomp-profile": "/etc/docker/defaults/production-seccomp.json"
}
```

---

### 4.4 Daemonless Podman Quadlet Service Unit (`sre-api.container`)

Modern systemd-integrated daemonless container execution using Podman Quadlet (systemd generator).

```ini
# Location: /etc/containers/systemd/sre-api.container
[Unit]
Description=SRE Production API Workload (Daemonless Podman)
After=network-online.target
Wants=network-online.target

[Container]
Image=quay.io/sre_ops/api-service:v2.4.1
ContainerName=sre-api-production
Exec=/usr/local/bin/api-server --port=8080
PublishPort=8080:8080
User=1000
Group=1000
ReadOnlyRootfs=true
VolatileTmp=true
DropCapability=ALL
AddCapability=CAP_NET_BIND_SERVICE
MemoryLimit=1G
CPUQuota=150%
PidsLimit=250
Environment=NODE_ENV=production
Network=bridge

[Install]
WantedBy=multi-user.target default.target
```

---

## 5. Command-Line Execution & Real Terminal Outputs

### 5.1 LXC / LXD Lifecycle and Inspection

#### Creating and Starting an LXC Container
```bash
$ sudo lxc-create -n production-lxc -t download -- -d ubuntu -r noble -a amd64
```
```output
Setting up the installation environment
Downloading the image index...
Downloading the instance image...
Unpacking the image metadata...
The image cache is now ready
Unpacking the image template...
Done creating container production-lxc
```

#### Starting and Verifying LXC State
```bash
$ sudo lxc-start -n production-lxc
$ sudo lxc-info -n production-lxc
```
```output
Name:           production-lxc
State:          RUNNING
PID:            14230
IP:             10.0.3.184
CPU use:        0.42 seconds
BlkIO use:      12.44 MiB
Memory use:     24.18 MiB
KMem use:       3.12 MiB
Link:           veth1001_veth
 Bytes received: 1.84 KiB
 Bytes sent:     842 B
```

#### Attaching to Container Execution Context
```bash
$ sudo lxc-attach -n production-lxc -- id
```
```output
uid=0(root) gid=0(root) groups=0(root)
```

---

### 5.2 Low-Level OCI Runtime (`runc`) Execution Workflow

Executing an OCI container directly using low-level binaries without a daemon.

```bash
$ mkdir -p /tmp/oci-demo/rootfs
$ cd /tmp/oci-demo
# Export filesystem layer from standard image
$ podman export $(podman create alpine:latest) | tar -C rootfs -xf -
# Generate standard OCI spec bundle (config.json)
$ runc spec
$ ls -la
```
```output
total 12
drwxr-xr-x 3 root root 4096 Aug  6 16:00 .
drwxrwxrwt 1 root root 4096 Aug  6 16:00 ..
-rw-r--r-- 1 root root 2841 Aug  6 16:00 config.json
drwxr-xr-x 2 root root 4096 Aug  6 16:00 rootfs
```

#### Running the Low-Level Container Instance
```bash
$ sudo runc run --bundle /tmp/oci-demo container-test-01 &
$ sudo runc list
```
```output
ID                  PID         STATUS      BUNDLE          CREATED                          OWNER
container-test-01   18924       running     /tmp/oci-demo   2026-08-06T16:02:11.412891102Z   root
```

---

### 5.3 Production Docker Engine Inspection & Resource Verification

#### Verifying Engine Cgroup Driver & Storage Stack
```bash
$ docker info --format 'Cgroup Driver: {{.CgroupDriver}} | Cgroup Version: {{.CgroupVersion}} | Driver: {{.Driver}}'
```
```output
Cgroup Driver: systemd | Cgroup Version: 2 | Driver: overlay2
```

#### Launching Hardened Container with Resource Caps
```bash
$ docker run -d --name secure-nginx \
  --memory="512m" \
  --cpus="1.5" \
  --pids-limit=100 \
  --read-only \
  --cap-drop=ALL \
  --cap-add=CAP_NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  nginx:alpine
```
```output
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

#### Inspecting Container Security Profile Controls
```bash
$ docker inspect secure-nginx --format '{{json .HostConfig.CapDrop}} | ReadOnly: {{.HostConfig.ReadOnlyRootfs}}'
```
```output
["ALL"] | ReadOnly: true
```

---

### 5.4 Daemonless Operations: Podman & User Namespaces

#### Verifying Host SubUID/SubGID Ranges for Rootless Execution
```bash
$ cat /etc/subuid /etc/subgid
```
```output
/etc/subuid:
sreuser:100000:65536
/etc/subgid:
sreuser:100000:65536
```

#### Running Rootless Container and Verifying User Mapping
```bash
$ podman run --rm alpine id
```
```output
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
```

#### Inspecting the Real PID Mapping via Host Process Table
```bash
$ podman run -d --name rootless-sleep alpine sleep 9999
$ podman top rootless-sleep user huser pid hpid
```
```output
USER        HUSER       PID         HPID        
root        100000      1           21045       
```
*(Notice that container root `UID 0` corresponds to `UID 100000` on the physical host).*

---

### 5.5 Low-Level Linux Kernel Inspection of Containers

#### Listing All Host Namespaces via `lsns`
```bash
$ sudo lsns -t net
```
```output
        NS TYPE NET-PATH                   NPROCS   PID USER     COMMAND
4026531840 net  /proc/1/ns/net                140     1 root     /sbin/init
4026532418 net  /proc/21045/ns/net              2 21045 100000   sleep 9999
```

#### Reading Container Process Cgroup v2 Node
```bash
$ cat /proc/21045/cgroup
```
```output
0::/user.slice/user-1000.slice/user@1000.service/app.slice/podman-21045.scope
```

#### Inspecting Kernel Effective Capabilities of a Host Process
```bash
$ grep Cap /proc/21045/status
```
```output
CapInh:	0000000000000000
CapPrm:	0000000000000000
CapEff:	0000000000000000
CapBnd:	0000000000000400
CapAmb:	0000000000000000
```
*(Decoding `CapEff: 0000000000000000` proves all root capabilities were completely stripped by the container engine).*

---

## 6. Comprehensive Verification & Failure Troubleshooting Guide

### 6.1 Diagnostic Scenario 1: Debugging OOMKilled Container Events

#### Root Cause Mechanics
The container process requested memory allocation exceeding the cgroup v2 cap `memory.max`. The kernel cgroup memory controller triggered synchronous reclaim. Upon failure to free sufficient anonymous memory/page cache, the kernel invoked `oom-killer` targeting the process with the highest `oom_score` inside the cgroup.

#### Diagnostic Workflow & Commands

##### Step 1: Query System Kernel Buffer for OOM Invocations
```bash
$ dmesg -T | grep -i -E "oom|out of memory|killed process"
```
```output
[Thu Aug  6 16:15:22 2026] Memory cgroup out of memory: Killed process 24512 (node) total-vm:1845120kB, anon-rss:1048100kB, file-rss:4120kB, shmem-rss:0kB, uid:1000 pgtables:3712kB oom_score_adj:0
[Thu Aug  6 16:15:22 2026] oom_reaper: reaped process 24512 (node), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
```

##### Step 2: Inspect cgroup v2 Memory Counter Events
```bash
$ CONTAINER_PID=$(docker inspect --format '{{.State.Pid}}' secure-nginx)
$ CGROUP_PATH=$(cat /proc/$CONTAINER_PID/cgroup | cut -d: -f3)
$ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.events
```
```output
low 0
high 142
max 1
oom 1
oom_kill 1
oom_group_kill 0
```

##### Step 3: Analyze PSI (Pressure Stall Information) for Memory Bottlenecks
```bash
$ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.pressure
```
```output
some avg10=24.12 avg60=15.41 avg300=4.10 total=48120412
full avg10=18.04 avg60=10.12 avg300=2.01 total=32104100
```
*Resolution:* Elevate `memory.max` or resolve application memory leaks identified by high `full` PSI pressure values.

---

### 6.2 Diagnostic Scenario 2: Network Connectivity & Packet Loss Troubleshooting

#### Root Cause Mechanics
Container cannot reach external endpoints or adjacent containers due to misconfigured virtual ethernet (`veth`) pair parameters, broken host bridge interfaces, or blocked host `iptables`/`nftables` packet forwarding chains (`FORWARD`).

```
+-----------------------------------------------------------------------+
| HOST NETWORKING NAMESPACE                                             |
|                                                                       |
|   +---------------+      veth Pair Generation                         |
|   |    docker0    |<========================+                         |
|   | (Bridge: IP)  |                         |                         |
|   +---------------+                         |                         |
+---------------------------------------------|-------------------------+
                                              | (Traverses Net NS Boundary)
+---------------------------------------------|-------------------------+
| CONTAINER NETWORKING NAMESPACE              v                         |
|                                     +---------------+                 |
|                                     |  eth0 (veth)  |                 |
|                                     +---------------+                 |
+-----------------------------------------------------------------------+
```

#### Diagnostic Workflow & Commands

##### Step 1: Identify Container Target NetNS and PID
```bash
$ TARGET_PID=$(docker inspect --format '{{.State.Pid}}' secure-nginx)
$ echo $TARGET_PID
```
```output
24110
```

##### Step 2: Execute Commands inside Container Network Namespace via `nsenter`
```bash
$ sudo nsenter -t $TARGET_PID -n ip addr show dev eth0
```
```output
12: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
```

##### Step 3: Verify Pair Interface on Host Engine
```bash
$ ip link show dev veth* | grep -B 1 "link-netnsid 0"
```
```output
13: veth4a81bc9@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> master docker0 state UP mode DEFAULT group default 
    link/ether f2:88:14:1c:c9:82 brd ff:ff:ff:ff:ff:ff
```

##### Step 4: Check IP Forwarding & Filter Rules on Host
```bash
$ sysctl net.ipv4.ip_forward
```
```output
net.ipv4.ip_forward = 1
```
```bash
$ sudo iptables -L FORWARD -n -v --line-numbers
```
```output
Chain FORWARD (policy DROP 0 packets, 0 bytes)
num   pkts bytes target     prot opt in     out     source               destination         
1     1240 102K  DOCKER-USER  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
2     1240 102K  DOCKER-ISOLATION-STAGE-1  all  --  *      *       0.0.0.0/0            0.0.0.0/0           
3      812  64K  ACCEPT     all  --  *      docker0  0.0.0.0/0            0.0.0.0/0            ctstate RELATED,ESTABLISHED
4      428  38K  DOCKER     all  --  docker0 !docker0 0.0.0.0/0            0.0.0.0/0           
```
*Resolution:* If rule 3/4 are missing or policy is DROP without ACCEPT rules, execute `sudo iptables -A FORWARD -i docker0 -j ACCEPT`.

---

### 6.3 Diagnostic Scenario 3: User Namespace UID/GID Mapping Permission Failures

#### Root Cause Mechanics
A rootless container process running under user namespaces fails to open a host path mounted volume with `EACCES (Permission denied)`. The host directory owner UID does not fall within the allocated SubUID mapping block defined in `/etc/subuid`.

#### Diagnostic Workflow & Commands

##### Step 1: Trace Process UIDs across Namespaces
```bash
$ podman unshare cat /proc/self/uid_map
```
```output
         0       1000          1
         1     100000      65536
```

##### Step 2: Inspect Volume Directory Permissions on Host
```bash
$ ls -ld /srv/app/data
```
```output
drwxr-x--- 2 root root 4096 Aug  6 15:30 /srv/app/data
```

##### Step 3: Correct Host Ownership using `podman unshare chown`
```bash
# Safely maps container UID 0 (which translates to host 100000) as owner of the host directory
$ podman unshare chown -R 0:0 /srv/app/data
$ ls -ld /srv/app/data
```
```output
drwxr-x--- 2 100000 100000 4096 Aug  6 15:30 /srv/app/data
```

---

### 6.4 Diagnostic Scenario 4: Debugging Seccomp Syscall Blocking via Audit Logs

#### Root Cause Mechanics
An application container crashes unexpectedly with exit code 159 (`SIGSYS`) or logs `Operation not permitted`. The default Seccomp filter intercepted an unauthorized kernel system call issued by the binary.

#### Diagnostic Workflow & Commands

##### Step 1: Monitor System Audit Log for Seccomp Denials
```bash
$ sudo tail -f /var/log/audit/audit.log | grep -E "type=SECCOMP"
```
```output
type=SECCOMP msg=audit(1722961022.412:941): auid=4294967295 uid=1000 gid=1000 ses=4294967295 pid=28114 comm="custom-agent" exe="/usr/local/bin/custom-agent" sig=31 arch=c000003e syscall=165 compat=0 ip=0x7f9a8412b321 code=0x0
```

##### Step 2: Convert Hexadecimal Syscall ID to Name
```bash
$ ausyscall x86_64 165
```
```output
mount
```
*(The trace proves process `custom-agent` attempted system call `mount()` [syscall #165], which is blocked by standard container seccomp profiles).*

##### Step 3: Verify via Live Process `strace` Attachment
```bash
$ sudo strace -p 28114 -e trace=mount
```
```output
strace: Process 28114 attached
mount("none", "/tmp", "tmpfs", 0, NULL) = -1 EPERM (Operation not permitted)
--- SIGSYS {si_signo=SIGSYS, si_code=SYS_SECCOMP, si_call_addr=0x7f9a8412b321, si_syscall=__NR_mount, si_arch=AUDIT_ARCH_X86_64} ---
+++ killed by SIGSYS (core dumped) +++
```
*Resolution:* Modify container Seccomp JSON profile to explicitly whitelist the required syscall (`mount`) or refactor application logic to remove privileged syscall execution.

---

## 7. References

- **LPIC-3 Exam 305-300 Objectives:** [https://www.lpi.org/our-certifications/lpic-3-305-overview/](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
- **Linux Kernel Namespaces Documentation (`namespaces(7)`):** [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- **Linux Control Groups v2 Documentation (`cgroups(7)`):** [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- **Open Container Initiative (OCI) Runtime Specification:** [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
- **Open Container Initiative (OCI) Image Specification:** [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
- **LXC / LXD Project Documentation:** [https://linuxcontainers.org/lxc/documentation/](https://linuxcontainers.org/lxc/documentation/)
- **Docker Engine Architecture & Daemon Reference:** [https://docs.docker.com/engine/reference/commandline/dockerd/](https://docs.docker.com/engine/reference/commandline/dockerd/)
- **Podman Quadlet Integration Guide:** [https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)