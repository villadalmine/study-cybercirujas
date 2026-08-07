# LPI DevOps Tools Engineer (Exam 701-100) Study Guide
## Topic 701.2 / 2.1: Container Usage & Runtime Architecture (Weight: 11.67)

---

## 1. Production Motivation & Architectural Problem Statement

In enterprise production environments, legacy deployment paradigms—such as bare-metal deployments and traditional Hardware Virtualization (Virtual Machines via Hypervisors like KVM/ESXi)—present severe operational friction:

1. **High Overhead & Cold Start Latency**: Virtual machines require a full guest operating system (Kernel, `systemd`/`init`, device drivers, system daemons). Boot times range from tens of seconds to minutes, consuming hundreds of megabytes to gigabytes of RAM before application code executes.
2. **Dependency Drift & Non-deterministic Builds**: Variations in underlying host OS packages, shared libraries (`glibc`), dynamic linking path bindings, and environment configurations lead to non-reproducible operational behavior across staging and production.
3. **Noisy Neighbor Resource Contention**: Lacking fine-grained CPU and memory throttling at process granularity leads to rogue processes starving adjacent workloads on shared hardware.

### The Linux Kernel Primitive Solution

Modern containerization eliminates the guest OS layer by leveraging native Linux Kernel primitives to enforce OS-level virtualization. Containers are isolated Linux processes running directly on the host kernel.

```
+-------------------------------------------------------------------+
|                        User Application                           |
+-------------------------------------------------------------------+
|                 Container Engine (dockerd / containerd)           |
+-------------------------------------------------------------------+
| OCI Runtime Interface (runc) -> Linux Kernel Primitives (cgroups) |
+-------------------------------+-----------------------------------+
| Linux Namespaces (Isolation)  | Control Groups v1/v2 (Limits)     |
| - PID, NET, MNT, IPC, UTS...  | - cpu.cfs_quota_us, memory.max... |
+-------------------------------+-----------------------------------+
|             Host Linux Kernel (Shared Kernel Space)               |
+-------------------------------------------------------------------+
```

#### Linux Namespaces (Resource Isolation Boundaries)
Namespaces restrict what a process can **see**. The Linux kernel exposes 8 primary namespaces used by container runtimes:

*   **`PID` (Process IDs)**: Provides independent PID numbering. PID 1 inside the container namespace maps to an arbitrary high-numbered PID on the host.
*   **`NET` (Network Devices)**: Isolates network interfaces, IP routing tables, firewall rules (`iptables`/`nftables`), and port binding sockets (`socket()`).
*   **`MNT` (Mount Points)**: Isolates filesystem mount tables (`/proc/mounts`). Combined with `pivot_root`, it isolates the container's root filesystem (`/`).
*   **`IPC` (Inter-Process Communication)**: Isolates System V IPC objects and POSIX message queues, preventing cross-container shared memory access (`shmget`).
*   **`UTS` (UNIX Timesharing System)**: Allows setting an independent hostname and NIS domain name per container.
*   **`USER` (User IDs)**: Remaps container UID/GID ranges to non-privileged UIDs/GIDs on the host (e.g., container `root` UID 0 maps to host UID 100000).
*   **`CGROUP` (Control Group Root)**: Hides the host cgroup hierarchy structure from process inspection via `/proc/self/cgroup`.
*   **`TIME` (Monotonic & Boot Clocks)**: Allows setting container-specific clock offsets without altering host system time.

#### Control Groups - cgroups v1 & cgroups v2 (Resource Constraints)
cgroups control what a process can **use**. They enforce quantitative resource limits, accounting, and control over system resources:

*   **CFS Bandwidth Control**: Implements CPU quota allocation via `cpu.cfs_quota_us` (quota allowed per period) and `cpu.cfs_period_us` (default 100000µs / 100ms). Setting `quota=200000` on `period=100000` limits the process to 2.0 vCPU cores.
*   **Memory Accounting & OOM Execution**: Monitors RSS (Resident Set Size), Page Cache, and Swap usage. Reaching hard memory thresholds (`memory.max` in cgroups v2) triggers kernel out-of-memory (`oom-killer`) invocation.

#### Copy-on-Write (CoW) Storage (OverlayFS)
Combines lower read-only image layers (`lowerdir`) with a single writable container layer (`upperdir`) merged via a unified mount point (`merged`), enabling sub-second container instantiation without copying image filesystems.

---

## 2. Technical Comparisons & Trade-off Matrices

### 2.1 Isolation Paradigms: Bare Metal vs Virtual Machines vs Containers

| Feature / Metric | Bare Metal | Hardware Virtualization (VMs) | OS-Level Virtualization (Containers) |
| :--- | :--- | :--- | :--- |
| **Isolation Primitive** | Physical Hardware Boundaries | Hardware Hypervisor (Intel VT-x, AMD-V, KVM) | Linux Kernel Namespaces & cgroups |
| **Kernel Model** | Single Dedicated Kernel | Independent Guest Kernel per VM | Shared Host Linux Kernel |
| **Startup Overhead** | 3 - 10 Minutes | 30 - 90 Seconds | 50 - 500 Milliseconds |
| **Memory Footprint** | Host OS Overhead Only | High (Guest OS + Hypervisor Reserved RAM) | Low (Process RSS + Writable Overlay Layer) |
| **I/O Overhead** | Native Hardware Speed | Near-native (virtio) to Virtualization Loss | Near-native (Direct Kernel syscall / Direct I/O) |
| **Security Surface** | Hardware/Firmware Attack Surface | Strong Hypervisor Isolation Barrier | Kernel Syscall Attack Surface (`seccomp`, `apparmor`) |

### 2.2 Storage Driver Performance Trade-offs

| Storage Driver | Backing Filesystem Requirements | Read/Write Performance | Memory Efficiency | Production Suitability & Status |
| :--- | :--- | :--- | :--- | :--- |
| **`overlay2`** | `ext4` or `xfs` (with `ftype=1`) | **High**: Excellent page cache sharing, fast lookup | **High**: Shared inode cache across containers | **Recommended**: Default standard across modern Linux distributions |
| **`btrfs`** | `btrfs` native pool | **Moderate**: CoW overhead on heavy random writes | **Moderate**: Dedicated subvolume tracking | **Specialized**: Requires dedicated Btrfs pool partition |
| **`zfs`** | `zfs` zpool | **Moderate**: High RAM utilization (ARC cache) | **Moderate**: High memory usage for ARC | **Specialized**: Excellent snapshot capabilities for high-density storage |
| **`devicemapper`** | Direct LVM volume | **Low - Moderate**: Block-level allocation locks | **Low**: No page cache sharing across layers | **Deprecated**: Removed in modern Docker Engine versions |

### 2.3 Container Networking Drivers

| Network Driver | IP Address Assignment | Port Allocation Mechanism | Host Isolation Level | Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **`bridge`** | Private Subnet (e.g., `172.17.0.0/16`) via `veth` pair | NAT Port Forwarding (`iptables` DNAT) | Isolated network namespace per container | **Default**: Standard standalone multi-container applications |
| **`host`** | Shares Host IP address directly | Uses Host TCP/UDP port namespace directly | Zero network isolation (shares host network stack) | **High Performance**: Ultra-low latency, high throughput networking |
| **`macvlan`** | Unique MAC & IP from physical host LAN | Direct binding to host physical interface (`eth0`) | Isolated from host network namespace, reachable via LAN | **Legacy Migration**: App requires direct physical network presence |
| **`none`** | No IP assigned (`loopback` interface only) | None | Complete network isolation | **Security-Critical**: Batch data processors, isolated air-gapped jobs |

---

## 3. Production Infrastructure Manifests

### 3.1 Hardened Multi-Stage Production `Dockerfile`

The following Dockerfile uses multi-stage builds, non-root execution, `tini` as PID 1, and explicit metadata:

```dockerfile
# ==========================================
# Stage 1: Build & Compilation Environment
# ==========================================
FROM golang:1.22-alpine3.19 AS builder

# Enforce secure compiler flags and module caching
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build

# Cache dependency layer independently
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

# Copy source and compile immutable, statically linked binary
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -a -installsuffix cgo -ldflags="-w -s -extldflags '-static'" -o /build/api-server ./cmd/server

# ==========================================
# Stage 2: Minimal Distroless Execution Layer
# ==========================================
FROM alpine:3.19.1

# Install security patches, CA certificates, and Tini signal init processor
RUN apk add --no-cache \
    ca-certificates=20240226-r0 \
    tzdata=2024a-r0 \
    tini=0.19.0-r2 \
    && addgroup -g 10001 -S appgroup \
    && adduser -u 10001 -S appuser -G appgroup -h /app

WORKDIR /app

# Copy binary from builder stage with strict non-root ownership
COPY --from=builder --chown=10001:10001 /build/api-server /app/api-server

# Enforce security context: Non-root execution
USER 10001:10001

# Expose service port
EXPOSE 8080

# Health check configuration to ensure operational status
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/app/api-server", "-healthcheck"]

# Use Tini as PID 1 to handle SIGTERM, SIGINT, and reap zombie child processes
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/api-server"]
```

---

## 3.2 Enterprise `docker-compose.yml` (Compose V2 Specification)

Production multi-container orchestration manifest enforcing strict resource limits, logging constraints, health checks, and non-default bridge networks:

```yaml
version: "3.8"

services:
  database:
    image: postgres:16.2-alpine
    container_name: production_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: production_db
      POSTGRES_USER_FILE: /run/secrets/db_user
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_user
      - db_password
    volumes:
      - postgres_data:/var/lib/postgresql/data:rw
    networks:
      - backend_network
    deploy:
      resources:
        limits:
          cpus: "2.00"
          memory: 2048M
        reservations:
          cpus: "0.50"
          memory: 512M
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$(cat /run/secrets/db_user) -d production_db"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"

  api_gateway:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: production_api
    restart: always
    ports:
      - "443:8080"
    environment:
      NODE_ENV: production
      DB_HOST: database
      DB_PORT: "5432"
    depends_on:
      database:
        condition: service_healthy
    networks:
      - frontend_network
      - backend_network
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    deploy:
      resources:
        limits:
          cpus: "1.50"
          memory: 1024M
        reservations:
          cpus: "0.25"
          memory: 256M
    healthcheck:
      test: ["CMD", "/app/api-server", "-healthcheck"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "3"
        compress: "true"

networks:
  frontend_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.10.0/24
  backend_network:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.28.20.0/24

volumes:
  postgres_data:
    driver: local

secrets:
  db_user:
    file: ./secrets/db_user.txt
  db_password:
    file: ./secrets/db_password.txt
```

---

## 3.3 Enterprise Production Docker Daemon Configuration (`/etc/docker/daemon.json`)

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
    "max-file": "3",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "userns-remap": "default",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64535,
      "Soft": 64535
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 4096,
      "Soft": 4096
    }
  },
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

---

## 4. Real-World CLI Executions & Terminal Outputs

### 4.1 Low-Level Container Runtime Inspection (`docker inspect`)

Inspecting specific network, storage mount, and state parameters using Golang template formatting:

```bash
$ docker inspect --format='{{json .State}}' production_api | jq .
```
```json
{
  "Status": "running",
  "Running": true,
  "Paused": false,
  "Restarting": false,
  "OOMKilled": false,
  "Dead": false,
  "Pid": 348912,
  "ExitCode": 0,
  "Error": "",
  "StartedAt": "2026-08-07T04:12:01.481923102Z",
  "FinishedAt": "0001-01-01T00:00:00Z",
  "Health": {
    "Status": "healthy",
    "FailingStreak": 0,
    "Log": [
      {
        "Start": "2026-08-07T04:40:01.102931201Z",
        "End": "2026-08-07T04:40:01.142019482Z",
        "ExitCode": 0,
        "Output": "HTTP 200 OK - Database connection alive"
      }
    ]
  }
}
```

---

### 4.2 Inspecting Active Control Group Resources (`docker stats`)

Monitoring realtime cgroup CPU, memory limits, and network I/O utilization without streaming:

```bash
$ docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}"
```
```text
NAME             CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O         PIDS
production_api   0.14%     42.18MiB / 1GiB       4.12%     12.4MB / 8.92MB   0B / 1.24MB       8
production_postgres 0.85%  184.5MiB / 2GiB       9.01%     8.92MB / 12.4MB   45.8MB / 182MB    23
```

---

### 4.3 Auditing Host Linux Namespace Mapping (`lsns` & `/proc`)

Tracing the actual host PID for a containerized process and displaying its allocated kernel namespaces:

```bash
$ HOST_PID=$(docker inspect --format='{{.State.Pid}}' production_api)
$ echo "Container Host PID: ${HOST_PID}"
```
```text
Container Host PID: 348912
```

Inspecting namespace symlinks inside the Linux proc filesystem:

```bash
$ ls -la /proc/${HOST_PID}/ns/
```
```text
total 0
drxf-x--x 2 appuser appgroup 0 Aug  7 04:12 .
dr-xr-xr-x 9 appuser appgroup 0 Aug  7 04:12 ..
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 cgroup -> 'cgroup:[4026533104]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 ipc -> 'ipc:[4026533099]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 mnt -> 'mnt:[4026533101]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:12 net -> 'net:[4026533102]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:12 pid -> 'pid:[4026533100]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 pid_for_children -> 'pid:[4026533098]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 time -> 'time:[4026531834]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 time_for_children -> 'time:[4026531834]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 user -> 'user:[4026531837]'
lrwxrwxrwx 1 appuser appgroup 0 Aug  7 04:15 uts -> 'uts:[4026533097]'
```

---

### 4.4 Low-Level OCI Container Runtime Diagnostics via `ctr` (containerd CLI)

Querying task states directly via containerd's socket API (`/run/containerd/containerd.sock`), bypassing the Docker daemon wrapper:

```bash
$ sudo ctr --namespace moby tasks list
```
```text
TASK                PID       STATUS    
348912a7f8e1...     348912    RUNNING
a9411d8c11e2...     349015    RUNNING
```

```bash
$ sudo ctr --namespace moby tasks metrics 348912a7f8e1...
```
```text
ID: 348912a7f8e1...
METRIC                   VALUE
CPU User                 148291024ns
CPU System               41902811ns
Memory Usage (bytes)     44228608
Memory Limit (bytes)     1073741824
OOM Events               0
PIDs Current             8
PIDs Limit               4096
```

---

## 5. SRE Verification & Troubleshooting Playbook

### Diagnostic Flowchart

```
                     +---------------------------------------+
                     | Issue Detected: Container Failure/OOM  |
                     +---------------------------------------+
                                         |
                                         v
                     +---------------------------------------+
                     | Run: docker inspect --format '{{...}}'|
                     +---------------------------------------+
                                         |
                   +---------------------+---------------------+
                   |                                           |
                   v                                           v
      [ ExitCode 137 / OOMKilled ]               [ ExitCode 143 / Timeout ]
                   |                                           |
                   v                                           v
      +-------------------------+                 +-------------------------+
      | Check dmesg / Kern log  |                 | Check PID 1 Signal      |
      | Inspect cgroup memory   |                 | Handling / Tini         |
      +-------------------------+                 +-------------------------+
```

---

### Scenario A: Silent Container Crash (Exit Code 137 / Out-Of-Memory)

#### Root Cause Analysis
The kernel Memory Resource Controller (`cgroup`) enforces memory boundaries specified via `--memory` or `deploy.resources.limits.memory`. When the container process allocation exceeds hard boundaries, the Linux Kernel OOM killer selects and sends signal `SIGKILL` (9) to the primary memory offender, causing an abrupt termination with exit code `137` (`128 + 9`).

#### Diagnostic Step-by-Step Execution

1. **Verify State via `docker inspect`**:
   ```bash
   $ docker inspect production_api --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
   ```
   *Expected Output*:
   ```text
   ExitCode=137 OOMKilled=true
   ```

2. **Inspect Kernel Ring Buffer Logs (`dmesg`)**:
   ```bash
   $ sudo dmesg -T --level=alert,crit,err | grep -i -E "oom|killed process"
   ```
   *Expected Output*:
   ```text
   [Fri Aug  7 04:22:19 2026] Memory cgroup out of memory: Killed process 348912 (api-server) total-vm:1894212kB, anon-rss:1048124kB, file-rss:412kB, shmem-rss:0kB, uid:10001 pgtables:2180kB oom_score_adj:0
   [Fri Aug  7 04:22:19 2026] oom_reaper: reaped process 348912 (api-server), now anon-rss:0kB, file-rss:0kB, shmem-rss:0kB
   ```

3. **Verify Host Kernel cgroups v2 Limit Enforcement**:
   ```bash
   $ CGROUP_PATH=$(docker inspect production_api --format='{{.CgroupParent}}')
   $ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.max
   $ cat /sys/fs/cgroup/${CGROUP_PATH}/memory.events
   ```
   *Expected Output*:
   ```text
   1073741824
   low 0
   high 0
   max 14
   oom 14
   oom_kill 14
   ```

#### Remediation Plan
*   Increase memory limits in `docker-compose.yml` (`memory: 2048M`).
*   Profile memory allocations using Go `pprof` or heap profilers to detect memory leaks.
*   Configure application runtime limits (e.g., Node.js `--max-old-space-size=768` or Java `-Xmx768m`) to ensure runtime garbage collection triggers *before* hitting cgroup limits.

---

### Scenario B: Zombie Process Accumulation & Graceful Shutdown Failure (SIGTERM Ignored)

#### Root Cause Analysis
When `docker stop` is executed, `dockerd` sends `SIGTERM` (signal 15) to PID 1 inside the container network/PID namespace. If the container application binary runs directly as PID 1 without explicit POSIX signal handlers implemented, Linux Kernel defaults apply: PID 1 **ignores signals** unless an explicit handler exists. 

After a 10-second default timeout, `dockerd` issues uncatchable `SIGKILL` (signal 9), causing data corruption or ungraceful socket termination.

#### Diagnostic Step-by-Step Execution

1. **Test Container Stop Response Latency**:
   ```bash
   $ time docker stop production_api
   ```
   *Expected Output*:
   ```text
   production_api

   real    0m10.412s
   user    0m0.031s
   sys     0m0.015s
   ```
   *Note: Execution duration of exactly ~10 seconds indicates graceful termination failure.*

2. **Inspect Internal Process Tree Inside Container**:
   ```bash
   $ docker exec production_api ps aux
   ```
   *Expected Output*:
   ```text
   PID   USER     TIME  COMMAND
       1 10001     0:00 node /app/server.js
      42 10001     0:00 [sh] <defunct>
      43 10001     0:00 [curl] <defunct>
   ```
   *Note: Defunct entries indicate zombie processes remaining un-reaped by PID 1.*

#### Remediation Plan
Option 1: Include `tini` as an initialization init wrapper in the Dockerfile (`ENTRYPOINT ["/sbin/tini", "--"]`).

Option 2: Enable the built-in init system via docker CLI or Compose manifest:
```bash
$ docker run --init -d --name production_api custom_image:v1.0
```
Or in `docker-compose.yml`:
```yaml
services:
  api_gateway:
    init: true
```

---

### Scenario C: Exhaustion of Host Disk Space via Unbound Writable Container Layer (`upperdir`)

#### Root Cause Analysis
Processes running inside containers writing ephemeral data to paths not bound to external volumes pollute the writable CoW layer (`/var/lib/docker/overlay2/<hash>/upper`). This leads to inode/block exhaustion on the host `/var` partition and degraded I/O performance across all containers sharing the storage driver.

#### Diagnostic Step-by-Step Execution

1. **Analyze Docker Disk Space Usage**:
   ```bash
   $ docker system df -v
   ```
   *Expected Output*:
   ```text
   Images space usage:
   REPOSITORY          TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE
   postgres            16.2      a129d3810f92   2 weeks ago    379.2MB   0B

   Containers space usage:
   CONTAINER ID   IMAGE            COMMAND                  LOCAL VOLUMES   SIZE
   348912a7f8e1   custom_image:v1  "/sbin/tini -- /app…"   1               48.2GB (virtual 48.3GB)
   ```

2. **Identify Top Writable Layer Disk Consuming Paths**:
   ```bash
   $ docker diff 348912a7f8e1 | grep "^A" | head -n 10
   ```
   *Expected Output*:
   ```text
   A /app/logs/application-debug.log
   A /tmp/cache/buffer.tmp
   ```

3. **Inspect Mount Configuration via `docker inspect`**:
   ```bash
   $ docker inspect --format='{{range .Mounts}}{{.Source}} -> {{.Destination}} (RW: {{.RW}}){{"\n"}}{{end}}' 348912a7f8e1
   ```
   *Expected Output*:
   ```text
   /var/lib/docker/volumes/postgres_data/_data -> /var/lib/postgresql/data (RW: true)
   ```
   *Note: Log paths (`/app/logs`) and temp paths (`/tmp`) are absent from volume mounts, causing writes to spill into the writable OverlayFS layer.*

#### Remediation Plan
1. Enforce a **Read-Only Root Filesystem** (`read_only: true`) in production manifests.
2. Bind ephemeral write paths explicitly to `tmpfs` mounts in RAM:
   ```yaml
   read_only: true
   tmpfs:
     - /tmp:rw,noexec,nosuid,size=64m
   ```
3. Direct application logs exclusively to standard output streams (`/dev/stdout` and `/dev/stderr`) to delegate log processing to Docker Engine's rotated logging driver (`json-file` with `max-size` caps).

---

## 6. References & Official Documentation

*   **LPI DevOps Tools Engineer Overview & Syllabus**:
    *   [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
    *   [https://wiki.lpi.org/wiki/LPIC-OT_DevOps_Tools_Engineer_Objectives_V1.0](https://wiki.lpi.org/wiki/LPIC-OT_DevOps_Tools_Engineer_Objectives_V1.0)
*   **Docker Engine Reference Documentation**:
    *   [https://docs.docker.com/engine/reference/builder/](https://docs.docker.com/engine/reference/builder/)
    *   [https://docs.docker.com/engine/reference/commandline/dockerd/](https://docs.docker.com/engine/reference/commandline/dockerd/)
    *   [https://docs.docker.com/storage/storagedriver/overlayfs-driver/](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
*   **Open Container Initiative (OCI) Specifications**:
    *   [https://opencontainers.org/specifications/runtime-spec/](https://opencontainers.org/specifications/runtime-spec/)
    *   [https://github.com/opencontainers/runc](https://github.com/opencontainers/runc)
*   **Linux Kernel Manual Pages & Documentation**:
    *   `namespaces(7)`: [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)
    *   `cgroups(7)`: [https://man7.org/linux/man-pages/man7/cgroups.7.html](https://man7.org/linux/man-pages/man7/cgroups.7.html)
    *   Control Group v2 Kernel Documentation: [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)