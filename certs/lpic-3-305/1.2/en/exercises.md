# LPIC-3 Exam 305-300 (v3.0): Advanced Container Virtualization & Production Architecture

## Topic Overview & Deep-Dive Objectives

Container virtualization leverages kernel-level primitives to isolate processes and restrict resource consumption without the performance overhead of full hardware emulation (hypervisors). This module provides production-grade, hands-on guided exercises targeting **LPIC-3 Exam 305-300 (Topic 352: Container Virtualization)** and advanced CNCF container runtime engineering.

### Architecture & Kernel Primitives Summary
1. **Namespaces (Isolation):** Provide isolated views of system resources.
   - `PID`: Process isolation (PID 1 inside namespace).
   - `NET`: Network stacks (veth pairs, routing tables, iptables/nftables).
   - `MNT`: Filesystem mount points (`pivot_root`).
   - `IPC`: System V IPC and POSIX message queues.
   - `UTS`: Hostname and NIS domain name.
   - `USER`: UID/GID mapping (enables rootless containers).
   - `CGROUP`: Isolated view of `/proc/self/cgroup`.
   - `TIME`: Virtualized `CLOCK_MONOTONIC` and `CLOCK_REALTIME` (Linux 5.6+).
2. **Control Groups v2 (Resource Control):** Unified hierarchy enforcing limits on CPU (`cpu.max`), memory (`memory.max`, `memory.high`), block I/O (`io.weight`, `io.max`), and PIDs (`pids.max`).
3. **Security Primitives:**
   - **Linux Capabilities:** Splitting `root` privileges into granular thread-level permissions (e.g., `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, `CAP_CHOWN`).
   - **Seccomp (Secure Computing Mode):** BPF-based system call filtering to restrict host kernel interaction.
   - **LSM (AppArmor/SELinux):** Mandatory Access Control (MAC) restricting filesystem paths and socket capabilities.

---

## Lab 1: Low-Level Linux Kernel Primitives (Namespaces, Cgroups v2, Capabilities, Seccomp)

### Objective
Deconstruct how container runtimes instantiate isolated environments by manually orchestrating Linux namespaces, configuring cgroup v2 controllers, dropping capabilities, and tracing seccomp filters using low-level utilities (`unshare`, `nsenter`, `capsh`, `systemd-run`).

### Guided Steps

1. **Audit Cgroup v2 Support and Hierarchy:**
   Verify that your host runs unified cgroup v2:
   ```bash
   stat -f -c %T /sys/fs/cgroup
   ```
   *Expected Output:*
   ```text
   cgroup2fs
   ```

2. **Manually Provision a Scoped Cgroup v2 Directory for Resource Enforcement:**
   Create a dedicated control group under the unified hierarchy, enable controllers, and enforce CPU and Memory ceilings:
   ```bash
   sudo mkdir -p /sys/fs/cgroup/production-workload
   echo "+cpu +memory +pids" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
   echo "100000 100000" | sudo tee /sys/fs/cgroup/production-workload/cpu.max
   echo "52428800" | sudo tee /sys/fs/cgroup/production-workload/memory.max
   ```

3. **Instantiate an Isolated Namespace Sandbox using `unshare`:**
   Execute a isolated shell with distinct `PID`, `NET`, `MNT`, `UTS`, and `IPC` namespaces attached to the created cgroup:
   ```bash
   sudo unshare --pid --net --mount --uts --ipc --fork \
     /bin/bash -c "echo \$\$ > /sys/fs/cgroup/production-workload/cgroup.procs && exec hostname sandbox-node-01 && exec bash"
   ```

4. **Verify Namespace Isolation from Within the Sandbox:**
   Inside the newly spawned shell, mount `/proc` to observe PID isolation and inspect the network stack:
   ```bash
   mount -t proc proc /proc
   ps aux
   ip addr show
   ```
   *Expected Output:*
   ```text
   USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
   root           1  0.0  0.0   8944  4212 pts/0    S+   14:20   0:00 sandbox-node-01
   root           8  0.0  0.0   9820  3400 pts/0    R+   14:21   0:00 ps aux

   1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
       link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   ```

5. **Test Resource Limit Enforcement (Memory Out-Of-Memory Killer):**
   Attempt to allocate 100MB of memory inside the sandbox (which has a 50MB limit enforced via `memory.max` = 52,428,800 bytes):
   ```bash
   python3 -c 'x = "A" * (100 * 1024 * 1024)'
   ```
   *Expected Output:*
   ```text
   Killed
   ```

6. **Inspect Capability Dropping with `capsh`:**
   Launch a shell dropping `CAP_SYS_ADMIN`, `CAP_NET_RAW`, and `CAP_SYS_PTRACE`:
   ```bash
   capsh --drop=cap_sys_admin,cap_net_raw,cap_sys_ptrace --print -- -c "ping -c 1 127.0.0.1"
   ```
   *Expected Output:*
   ```text
   Current: = cap_chown,cap_dac_override,...-cap_net_raw,-cap_sys_admin,-cap_sys_ptrace
   Bounding set =cap_chown,...-cap_net_raw,-cap_sys_admin,-cap_sys_ptrace
   ping: socket: Operation not permitted
   ```

---

### Verification Questions (Lab 1)

1. Why did mounting `/proc` inside the container in Step 4 affect `/proc` visibility, and what potential host-level security risk occurs if `unshare --mount` is executed without modifying mount propagation (`--propagation private`)?
2. In Cgroup v2, what is the exact operational difference between `memory.max` and `memory.high`, and how does the kernel treat processes exceeding each threshold?
3. A containerized process requires binding to port 80 and adjusting network interface state, but must not be allowed to perform arbitrary kernel module loading or system reboots. Which specific Linux capabilities must be retained, and which must be dropped?

---

## Lab 2: System Containers with LXC Architecture & Production Configuration

### Objective
Design, configure, and manage system-level containers using LXC (Linux Containers). Configure custom non-privileged container mappings, implement static network bridging, enforce hardware resource constraints, and debug container initialization failures using LXC logging sub-systems.

```
       +-------------------------------------------------------------+
       |                        LXC Host                             |
       |                                                             |
       |  +-----------------------+     +-------------------------+  |
       |  |  Privileged LXC       |     |  Unprivileged LXC       |  |
       |  |  (UID 0 -> Host UID 0)|     |  (UID 0 -> UID 100000)  |  |
       |  +-----------+-----------+     +------------+------------+  |
       |              |                              |               |
       |          veth-priv                      veth-unpriv         |
       |              |                              |               |
       |      +-------v------------------------------v--------+      |
       |      |             Bridge: lxcbr0                    |      |
       |      +-----------------------+-----------------------+      |
       |                              |                              |
       |                         eth0 / enp1s0                       |
       +------------------------------+------------------------------+
                                      |
                                  WAN / LAN
```

### Guided Steps

1. **Install and Validate LXC Ecosystem Utilities:**
   Install LXC and verify daemon runtime components:
   ```bash
   sudo apt-get update && sudo apt-get install -y lxc lxc-templates bridge-utils uidmap
   lxc-checkconfig
   ```

2. **Configure Host SubUID/SubGID Mappings for Unprivileged LXC Containers:**
   Verify `/etc/subuid` and `/etc/subgid` entries for user `sreadmin`:
   ```bash
   echo "sreadmin:100000:65536" | sudo tee -a /etc/subuid
   echo "sreadmin:100000:65536" | sudo tee -a /etc/subgid
   ```

3. **Provision a Production LXC Container Manifest:**
   Create a defined LXC container configuration file at `/var/lib/lxc/sys-app-01/config`:
   ```bash
   sudo mkdir -p /var/lib/lxc/sys-app-01
   sudo tee /var/lib/lxc/sys-app-01/config << 'EOF'
   # Template configuration
   lxc.include = /usr/share/lxc/config/common.conf
   lxc.arch = amd64

   # Container Architecture & Hostname
   lxc.uts.name = sys-app-01
   lxc.rootfs.path = dir:/var/lib/lxc/sys-app-01/rootfs

   # UID/GID Unprivileged Mapping
   lxc.idmap = u 0 100000 65536
   lxc.idmap = g 0 100000 65536

   # Network Architecture (Virtual Ethernet Bridge)
   lxc.net.0.type = veth
   lxc.net.0.link = lxcbr0
   lxc.net.0.flags = up
   lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx
   lxc.net.0.ipv4.address = 10.0.3.50/24
   lxc.net.0.ipv4.gateway = 10.0.3.1

   # Cgroup v2 Limits
   lxc.cgroup2.cpu.max = 200000 100000
   lxc.cgroup2.memory.max = 1073741824
   lxc.cgroup2.pids.max = 500

   # Security Profiles
   lxc.seccomp.profile = /usr/share/lxc/config/common.seccomp
   lxc.cap.drop = sys_time sys_rawio mac_admin
   EOF
   ```

4. **Initialize Root Filesystem and Start Container:**
   Create the container rootfs using the Alpine Linux template and execute lifecycle commands:
   ```bash
   sudo lxc-create -n sys-app-01 -t download -- -d alpine -r 3.19 -a amd64
   sudo lxc-start -n sys-app-01
   sudo lxc-info -n sys-app-01
   ```
   *Expected Output:*
   ```text
   Name:           sys-app-01
   State:          RUNNING
   PID:            14230
   IP:             10.0.3.50
   CPU use:        0.12 seconds
   Memory use:     14.21 MiB
   KMem use:       2.10 MiB
   Link:           veth1001_xxxx
    TX bytes:      1.2 KiB
    RX bytes:      2.8 KiB
   ```

5. **Execute In-Container Diagnostics:**
   Attach directly to the execution context of `sys-app-01` without SSH:
   ```bash
   sudo lxc-attach -n sys-app-01 -- id
   ```
   *Expected Output:*
   ```text
   uid=0(root) gid=0(root) groups=0(root)
   ```

6. **Diagnose Initialization Failures via TRACE Logging:**
   Simulate a failure by setting an invalid boot option and starting LXC in foreground trace mode:
   ```bash
   sudo lxc-start -n sys-app-01 -F --logpriority=TRACE --logfile=/tmp/lxc-trace.log
   ```
   Inspect `/tmp/lxc-trace.log` to trace `clone3()`, pivot_root, or network veth attachment failures.

---

### Verification Questions (Lab 2)

1. What is the fundamental security model advantage of an unprivileged LXC container (`lxc.idmap = u 0 100000 65536`) over a standard privileged container if an attacker achieves arbitrary remote code execution as `root` inside the container?
2. Explain how `lxc.net.0.type = veth` interfaces interact with host bridges (`lxcbr0`) vs `lxc.net.0.type = macvlan`. What are the network routing and promiscuous mode trade-offs on host NICs when selecting `macvlan`?

---

## Lab 3: Application Containers with Docker, OCI Runtime Engine (runc/containerd), Storage Drivers & Security

### Objective
Analyze the complete lifecycle stack of application containers (`dockerd` $\rightarrow$ `containerd` $\rightarrow$ `containerd-shim-v2` $\rightarrow$ `runc`). Build multi-stage OCI-compliant images, inspect the `Overlay2` storage driver layer hierarchy (`lowerdir`, `upperdir`, `merged`), and enforce seccomp and read-only root filesystems.

```
+-------------------------------------------------------------------------------+
|                                Host OS Kernel                                 |
+-------------------------------------------------------------------------------+
       ^                                 ^                               ^
       | syscalls                        | syscalls                      | syscalls
+--------------+                 +---------------+               +--------------+
| Container A  |                 | Container B   |               | Container C  |
| (App Proc)   |                 | (App Proc)    |               | (App Proc)   |
+--------------+                 +---------------+               +--------------+
       ^                                 ^                               ^
       | manages                         | manages                       | manages
+--------------+                 +---------------+               +--------------+
| containerd-  |                 | containerd-   |               | containerd-  |
| shim-v2 (PID)|                 | shim-v2 (PID) |               | shim-v2 (PID)|
+--------------+                 +---------------+               +--------------+
       ^                                 ^                               ^
       +---------------------------------+-------------------------------+
                                         |
                                  gRPC API Control
                                         v
                                 +---------------+
                                 |  containerd   |
                                 +---------------+
                                         ^
                                         | REST / gRPC API
                                 +---------------+
                                 |    dockerd    |
                                 +---------------+
```

### Guided Steps

1. **Deconstruct the Container Process Tree (`containerd-shim-v2` vs `runc`):**
   Run a detached Nginx container and inspect the process hierarchy:
   ```bash
   docker run -d --name web-prod -p 8080:80 nginx:alpine
   ps auxf | grep -E "(dockerd|containerd|shim|nginx)"
   ```
   *Expected Output:*
   ```text
   root        1102  0.1  1.2 124500 48100 ?        Ssl  10:00   0:05 /usr/bin/dockerd -H fd://
   root        1215  0.2  0.9 984000 36200 ?        Ssl  10:00   0:08  \_ /usr/bin/containerd
   root       15420  0.0  0.2 708450  9210 ?        Sl   14:35   0:00      \_ containerd-shim-runc-v2 -namespace moby -id 8a3f... -address /run/containerd/containerd.sock
   101        15442  0.0  0.1   9910  5120 ?        Ss   14:35   0:00          \_ nginx: master process nginx -g daemon off;
   ```
   *Architectural Note:* `runc` exits immediately after spawning the container process. `containerd-shim-v2` stays alive to serve as the parent process, handling stdout/stderr I/O streams and retaining file descriptors so `containerd` or `dockerd` can be restarted without stopping the container.

2. **Inspect Overlay2 Storage Driver Graph Driver Paths:**
   Query the filesystem layout for `web-prod`:
   ```bash
   docker inspect web-prod --format '{{json .GraphDriver.Data}}' | jq .
   ```
   *Expected Output:*
   ```json
   {
     "LowerDir": "/var/lib/docker/overlay2/e3f4.../diff:/var/lib/docker/overlay2/a1b2.../diff",
     "MergedDir": "/var/lib/docker/overlay2/c8d9.../merged",
     "UpperDir": "/var/lib/docker/overlay2/c8d9.../diff",
     "WorkDir": "/var/lib/docker/overlay2/c8d9.../work"
   }
   ```

3. **Verify Overlay2 Copy-on-Write (CoW) Mechanics:**
   Create a new file inside the container and verify that it appears exclusively in `UpperDir` on the host:
   ```bash
   docker exec web-prod touch /var/log/test-cow.log
   UPPER_DIR=$(docker inspect web-prod --format '{{.GraphDriver.Data.UpperDir}}')
   sudo ls -la ${UPPER_DIR}/var/log/test-cow.log
   ```
   *Expected Output:*
   ```text
   -rw-r--r-- 1 root root 0 Aug 6 14:40 /var/lib/docker/overlay2/c8d9.../diff/var/log/test-cow.log
   ```

4. **Write a Production-Grade Hardened Multi-Stage Dockerfile:**
   Create `Dockerfile.production` enforcing minimal attack surface, non-root user execution, dropping writable layers, and explicitly setting OCI labels:
   ```dockerfile
   # Stage 1: Build Environment
   FROM golang:1.22-alpine AS builder
   WORKDIR /app
   RUN apk add --no-cache git ca-certificates
   COPY go.mod go.sum ./
   RUN go mod download
   COPY . .
   RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
       -ldflags="-w -s -extldflags '-static'" \
       -o microservice .

   # Stage 2: Hardened Runtime Environment
   FROM scratch
   # Copy CA Certificates for outbound TLS
   COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
   # Copy unprivileged non-root user from builder
   COPY --from=builder /etc/passwd /etc/passwd
   COPY --from=builder /app/microservice /microservice

   USER 65534:65534
   EXPOSE 8080
   ENTRYPOINT ["/microservice"]
   ```

5. **Deploy Container with Read-Only Root Filesystem & Dropped Capabilities:**
   Execute container with maximum security constraints:
   ```bash
   docker run -d \
     --name secure-app \
     --read-only \
     --tmpfs /tmp:rw,noexec,nosuid,size=64m \
     --cap-drop=ALL \
     --cap-add=NET_BIND_SERVICE \
     --security-opt no-new-privileges:true \
     -p 8081:8080 \
     nginx:alpine
   ```

---

### Verification Questions (Lab 3)

1. If `dockerd` crashes or undergoes a zero-downtime binary upgrade, why do running containers managed by `containerd-shim-v2` continue operating without network disruption or process termination?
2. In the `Overlay2` storage driver architecture, describe what occurs at the VFS kernel layer when a containerized application attempts to modify a 2GB file located inside a read-only `LowerDir`. What performance penalty is incurred?
3. What vulnerability risk does `--security-opt no-new-privileges:true` prevent, even if a binary inside the container has the `SUID` bit enabled and is executed by an unprivileged user?

---

## Lab 4: Advanced Production Diagnostics, Container Networking & Troubleshooting

### Objective
Perform low-level network tracing across virtual ethernet (`veth`) pairs, traverse network namespaces using `nsenter` and `ip netns`, inspect OCI specs using low-level tools (`ctr`, `crictl`), and audit seccomp violation events in the system log.

### Guided Steps

1. **Map Container Interface to Host `veth` Pair:**
   Find the network index (`iflink`) inside the container:
   ```bash
   docker exec -it web-prod cat /sys/class/net/eth0/iflink
   ```
   *Expected Output:*
   ```text
   24
   ```
   Query the host interfaces to identify which interface matches index `24`:
   ```bash
   ip link show | grep -E "^24:"
   ```
   *Expected Output:*
   ```text
   24: veth9c4b12a@if23: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master docker0 state UP mode DEFAULT group default
   ```

2. **Traverse Container Network Namespace using `nsenter`:**
   Retrieve the Host PID of the container and enter its isolated network namespace to perform packet captures:
   ```bash
   CONTAINER_PID=$(docker inspect web-prod --format '{{.State.Pid}}')
   sudo nsenter -t ${CONTAINER_PID} -n ip addr show
   sudo nsenter -t ${CONTAINER_PID} -n tcpdump -i eth0 -n "port 80"
   ```

3. **Symlink Network Namespace to `ip netns` for Standard Network Management:**
   Expose the hidden Docker network namespace to `ip netns` utilities:
   ```bash
   NETNS_PATH=$(docker inspect web-prod --format '{{.NetworkSettings.SandboxKey}}')
   sudo mkdir -p /var/run/netns
   sudo ln -sf ${NETNS_PATH} /var/run/netns/web-prod-ns
   ip netns list
   sudo ip netns exec web-prod-ns ss -tulpn
   ```
   *Expected Output:*
   ```text
   web-prod-ns (id: 1)
   Netid  State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
   tcp    LISTEN  0       511            0.0.0.0:80          0.0.0.0:*      users:(("nginx",pid=15442,fd=6))
   ```

4. **Low-Level Container Debugging with `containerd` CLI (`ctr`):**
   Interact directly with `containerd` bypassing the Docker daemon:
   ```bash
   sudo ctr --namespace moby containers list
   sudo ctr --namespace moby tasks list
   ```

5. **Audit Seccomp System Call Violations via Kernel Audit Daemon:**
   Trigger a seccomp block by executing a prohibited operation (e.g., modifying system clocks using `clock_settime`) inside a standard container:
   ```bash
   docker run --rm --security-opt seccomp=/etc/docker/default-seccomp.json alpine date -s "2030-01-01 00:00:00"
   ```
   *Expected Output:*
   ```text
   date: can't set date: Operation not permitted
   ```
   Inspect host system log for `SECCOMP` or `audit` violation records:
   ```bash
   sudo journalctl -k | grep -i "seccomp" | tail -n 5
   ```
   *Expected Output:*
   ```text
   audit: type=1326 audit(1722955200.124:941): auid=4294967295 uid=0 gid=0 ses=4294967295 subj=unconfined pid=18920 comm="date" exe="/bin/date" sig=31 arch=c000003e syscall=227 compat=0 ip=0x7f8a12345678 code=0x0
   ```
   *Diagnostic Note:* `syscall=227` corresponds to `clock_settime` on x86_64 architecture.

---

### Verification Questions (Lab 4)

1. When using `nsenter -t <PID> -n -m`, why might diagnostic tools installed on the host (like `tcpdump` or `htop`) fail or behave differently if `-m` (mount namespace) is included versus using only `-n` (network namespace)?
2. In a Kubernetes node scenario using `crictl`, what is the functional relationship between the "Pause container" (Pod Sandbox) and the application containers in terms of Linux namespace sharing?
3. You observe dropped packets between two containers attached to the same custom bridge interface. What specific `iptables` / `sysctl` settings (e.g., `bridge-nf-call-iptables`) could cause host firewall rules to silently filter intra-bridge container traffic?

---

<details>
<summary><strong>Comprehensive Answer Key & Technical Explanations</strong></summary>

### Answers to Lab 1 Questions

1. **`/proc` Visibility & Mount Propagation:**
   - **Reason:** `/proc` is a pseudo-filesystem generated dynamically by the kernel based on the PID namespace of the process mounting it. In Step 4, explicitly running `mount -t proc proc /proc` overrides the existing mount table entry inside the container's mount namespace so that `ps aux` queries the isolated PID namespace (where the container shell is PID 1).
   - **Host Risk:** If `unshare --mount` is run without setting private mount propagation (`mount --make-rprivate /`), any subsequent mounts or unmounts performed inside the new mount namespace can propagate back to the host root mount table (`/`), potentially disrupting host filesystems or leaking sensitive mounts.

2. **Cgroup v2 `memory.max` vs `memory.high` Mechanics:**
   - `memory.max`: Hard limit. If memory usage reaches this threshold and cannot be reclaimed through page cache flushing, the kernel's Out-Of-Memory (OOM) killer immediately terminates the process within the cgroup.
   - `memory.high`: Soft limit / throttle limit. When memory usage exceeds `memory.high`, the kernel does **not** trigger the OOM killer. Instead, it forces processes in that cgroup into synchronous page reclaim and throttles their execution time, applying backpressure to bring usage back below the threshold.

3. **Granular Linux Capabilities Allocation:**
   - **Retain:**
     - `CAP_NET_BIND_SERVICE`: Permits binding to privileged sockets (ports < 1024, such as port 80).
     - `CAP_NET_ADMIN`: Permits network configuration (interface state changes, routing tables, IP address assignment).
   - **Drop:**
     - `CAP_SYS_MODULE`: Explicitly drops the ability to load/unload kernel modules (`insmod`, `rmmod`).
     - `CAP_SYS_BOOT`: Explicitly drops the ability to reboot or halt the host system (`reboot()` syscall).
     - `CAP_SYS_ADMIN`: Overly broad root privilege that must be dropped in secure production environments.

---

### Answers to Lab 2 Questions

1. **Security Model of Unprivileged LXC Containers:**
   - Unprivileged containers use `user_namespaces(7)`. The root user inside the container (UID 0) is mapped to an unprivileged high-range UID on the host (e.g., UID 100000) via `/etc/subuid`.
   - If an attacker breaks out of the container boundary or executes arbitrary code, they exist on the host OS as UID 100000, possessing zero privileges over host root-owned files (`/etc/shadow`, `/boot`, raw disk block devices). In contrast, in a privileged container, UID 0 inside the container is UID 0 on the host system.

2. **VETH Bridges vs. MACVLAN Interfaces:**
   - **VETH + Bridge (`lxcbr0`):** Virtual ethernet pairs act as virtual patch cables. One end remains in the container, and the other attaches to host bridge `lxcbr0`. The host acts as a Layer-2 switch and Layer-3 router with NAT (`iptables`/`nftables` masquerading) to reach external networks.
   - **MACVLAN:** Bypasses host bridging entirely by assigning a unique MAC address directly to the container interface on top of a physical host NIC (`eth0`).
   - **Trade-offs:** MACVLAN offers higher throughput and lower CPU overhead because it avoids bridge processing and NAT. However, by default, the Linux kernel prevents direct communication between the host OS and MACVLAN containers on the same physical interface (unless using MACVLAN bridge mode or a hairpin setup). Additionally, host NICs must support promiscuous mode or multiple MAC filters on the network switch port.

---

### Answers to Lab 3 Questions

1. **Decoupled Architecture with `containerd-shim-v2`:**
   - `dockerd` delegates container lifecycle management to `containerd`. When starting a container, `containerd` invokes `runc` to create the namespaces and cgroups, and spawns `containerd-shim-v2`.
   - `runc` initializes the workload and exits. `containerd-shim-v2` becomes the daemonless parent process of the container payload.
   - Because `containerd-shim-v2` holds open the Standard I/O file descriptors (`stdin`, `stdout`, `stderr`) and PTY sockets, `dockerd` or `containerd` can crash, exit, or undergo binary upgrades without sending `SIGHUP` or `SIGKILL` signals down the process tree.

2. **Overlay2 Copy-on-Write (CoW) Overhead:**
   - When a process requests write access to an existing file residing in a read-only `LowerDir` layer, the `Overlay2` VFS driver intercepts the open call (`O_WRONLY` or `O_RDWR`).
   - The kernel performs a full CoW operation: it copies the entire 2GB file from `LowerDir` into `UpperDir` before allowing the write operation to complete.
   - **Performance Penalty:** Causes severe disk I/O latency, storage allocation spikes, and high CPU usage for large files. Best practice dictates using dedicated OCI volumes or bind mounts for database files or heavy write workloads to bypass `Overlay2`.

3. **Protection via `no-new-privileges`:**
   - Setting `no-new-privileges:true` enforces the `PR_SET_NO_NEW_PRIVS` flag via `prctl()` on the container root process before `execve()`.
   - This prevents processes from gaining elevated permissions via `SUID` or `SGID` binaries or Linux Capabilities (e.g., executing `/usr/bin/sudo` or a malicious custom SUID binary inside the container rootfs will fail to grant host or container root privileges).

---

### Answers to Lab 4 Questions

1. **Impact of Mount Namespace Isolation in `nsenter`:**
   - If `-m` (mount namespace) is included when running `nsenter`, the shell transitions into the container's virtual filesystem mount table.
   - If the diagnostic tools (e.g., `tcpdump`, `gdb`, `strace`, `ss`) are installed on the host OS but absent from the container's minimal rootfs (like `scratch` or `alpine`), command execution will fail with `command not found` or miss required shared dynamic libraries (`.so`).
   - **Best Practice:** Use `nsenter -t <PID> -n` (network namespace only) without `-m` to execute host-installed binary utilities against the container's isolated network stack.

2. **Kubernetes Pause Container & Namespace Sharing:**
   - The **Pause container** (Pod Sandbox) is initialized first by the container runtime (`cri-o` or `containerd`). It sets up and holds open the shared Linux namespaces: `NET`, `IPC`, and `UTSNAMESPACE`.
   - All actual application containers within the same Kubernetes Pod join the exact same `NET` and `IPC` namespaces created by the Pause container (`--net=container:pause_pid`).
   - Consequently, containers within the same Pod communicate over `localhost` (127.0.0.1) and share IPC queues while maintaining distinct `PID` and `MNT` namespaces.

3. **Intra-Bridge Filtering & `sysctl` Configurations:**
   - Linux kernel netfilter parameters dictate whether packets traversing a Layer-2 bridge pass through host `iptables`/`nftables` rules.
   - If `sysctl net.bridge.bridge-nf-call-iptables` is set to `1`, any packet moving across virtual interfaces on `docker0` or custom bridges is evaluated by host `FORWARD` chain firewall rules.
   - If `iptables` default FORWARD policy is set to `DROP` (common in hardened security baselines) and explicit `ACCEPT` rules are missing for the container subnet, intra-bridge container communication will be silently dropped.

---

### Official References & Further Reading
- [Linux Kernel Manual - Namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [Linux Kernel Documentation - Control Groups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [LXC Official Documentation & Configuration Guide](https://linuxcontainers.org/lxc/introduction/)
- [OCI Image & Runtime Specification Standards](https://opencontainers.org/)
- [Docker Engine Storage Drivers Architecture (Overlay2)](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
- [LPIC-3 Exam 305-300 Detailed Objectives](https://www.lpi.org/our-certifications/lpic-3-305-overview/)
</details>