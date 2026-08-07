# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
## Topic 2.1: Container Usage (Weight: 11.67)

---

### Official References
* **LPI DevOps Tools Engineer Overview**: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Docker CLI Reference**: [https://docs.docker.com/engine/reference/commandline/cli/](https://docs.docker.com/engine/reference/commandline/cli/)
* **Docker Storage Drivers & Overlay2**: [https://docs.docker.com/storage/storagedriver/overlayfs-driver/](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
* **Docker Container Networking**: [https://docs.docker.com/network/](https://docs.docker.com/network/)
* **Linux Kernel Control Groups (cgroups v2)**: [https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
* **Linux Namespaces Overview**: [https://man7.org/linux/man-pages/man7/namespaces.7.html](https://man7.org/linux/man-pages/man7/namespaces.7.html)

---

## Technical Overview & Architectural Deep-Dive

In modern containerized production environments, a container is not a standalone virtual machine, but rather an isolated group of Linux kernel processes governed by **Namespaces** (for isolation) and **Control Groups (cgroups)** (for resource boundaries).

```
+-------------------------------------------------------------------------+
|                              HOST SYSTEM                                |
|                                                                         |
|  +-----------------------------------+  +----------------------------+  |
|  |           CONTAINER A             |  |        CONTAINER B         |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  | Process (PID 1 in NS)       |  |  |  | Process (PID 1 in NS) |  |  |
|  |  | (PID 14201 on Host)         |  |  |  | (PID 14389 on Host)    |  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  |  | Mount NS / Overlay2 Merged  |  |  |  | Mount NS / Volume    |  |  |
|  |  +-----------------------------+  |  |  +----------------------+  |  |
|  +-----------------------------------+  +----------------------------+  |
|                    |                                  |                 |
|  ==================v==================================v===============  |
|                               LINUX KERNEL                              |
|  Namespaces: pid, net, mnt, ipc, uts, user | cgroups v2: cpu, memory, io|
+-------------------------------------------------------------------------+
```

### Key Architectural Mechanisms
1. **Linux Namespaces**:
   * `pid`: Process isolation (processes inside the container see their own PID tree starting at PID 1).
   * `net`: Network device, IP routing table, and port binding isolation.
   * `mnt`: Mount point isolation, enabling a isolated root filesystem view.
   * `ipc`: Inter-Process Communication isolation (POSIX message queues, System V IPC).
   * `uts`: UNIX Timesharing System isolation (hostname and domain name).
   * `user`: User and group ID mapping (mapping root inside container to non-root UID on host).
2. **Control Groups (cgroups v1 / v2)**:
   * Enforces hard and soft limits on kernel subsystems (`memory.max`, `cpu.max`, `io.weight`).
   * Manages Out-Of-Memory (OOM) killer triggers when memory ceilings are reached.
3. **Storage Abstraction**:
   * **Overlay2 Union File System**: Combines read-only image layers (`lowerdir`) with an ephemeral read-write container layer (`upperdir`) merged via a unified filesystem view (`merged`).
   * **Volumes**: Managed directly by Docker under `/var/lib/docker/volumes/`, bypassing the copy-on-write overhead.
   * **Bind Mounts**: Maps host path directly into container mount namespace.
   * **tmpfs Mounts**: Mounts host memory directly, never writing data to non-volatile storage layers.

---

## Guided Exercises

---

### Exercise 1: Container Execution, Process Isolation & Kernel Namespace Probing

#### Scenario & Objective
You need to run an Nginx application container, inspect its host-level process isolation, analyze kernel namespace IDs, interact with running container processes, and copy diagnostic artifacts without modifying the container image layer.

#### Execution Steps

1. Launch an isolated Nginx web server in detached mode with specific port bindings and container naming.
   ```bash
   docker run -d --name web-prod-01 -p 8080:80 nginx:1.25-alpine
   ```
   *Expected Output:*
   ```text
   a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890
   ```

2. List running processes inside the container namespace using `docker top`.
   ```bash
   docker top web-prod-01
   ```
   *Expected Output:*
   ```text
   UID         PID         PPID        C           STIME       TTY         TIME        CMD
   root        14201       14180       0           04:45       ?           00:00:00    nginx: master process nginx -g daemon off;
   101         14245       14201       0           04:45       ?           00:00:00    nginx: worker process
   ```

3. Identify the host PID for the main container process using `docker inspect`.
   ```bash
   HOST_PID=$(docker inspect --format '{{.State.Pid}}' web-prod-01)
   echo "Host PID of container PID 1: ${HOST_PID}"
   ```
   *Expected Output:*
   ```text
   Host PID of container PID 1: 14201
   ```

4. Compare kernel namespace symlinks between the current host process (`self`) and the container host PID (`14201`).
   ```bash
   ls -l /proc/self/ns/pid /proc/${HOST_PID}/ns/pid
   ```
   *Expected Output:*
   ```text
   lrwxrwxrwx 1 root root 0 Aug  7 04:45 /proc/14201/ns/pid -> 'pid:[4026532588]'
   lrwxrwxrwx 1 root root 0 Aug  7 04:45 /proc/self/ns/pid -> 'pid:[4026531836]'
   ```

5. Execute an interactive diagnostics session inside the running container to inspect PID 1 and write a custom index file.
   ```bash
   docker exec -it web-prod-01 sh -c "ps aux && echo '<h1>SRE Diagnostics OK</h1>' > /usr/share/nginx/html/index.html"
   ```
   *Expected Output:*
   ```text
   PID   USER     TIME  COMMAND
       1 root      0:00 nginx: master process nginx -g daemon off;
       7 101       0:00 nginx: worker process
      15 root      0:00 sh -c ps aux && echo '<h1>SRE Diagnostics OK</h1>' > /usr/share/nginx/html/index.html
   ```

6. Extract `/etc/nginx/nginx.conf` from the container onto the host machine filesystem for auditing.
   ```bash
   docker cp web-prod-01:/etc/nginx/nginx.conf ./nginx-host-audit.conf
   head -n 5 ./nginx-host-audit.conf
   ```
   *Expected Output:*
   ```text
   user  nginx;
   worker_processes  auto;

   error_log  /var/log/nginx/error.log notice;
   pid        /var/run/nginx.pid;
   ```

#### Comprehension Questions - Exercise 1
1. **Q1.1**: Why does `/proc/14201/ns/pid` show a different namespace inode number (`4026532588`) than `/proc/self/ns/pid` (`4026531836`)?
2. **Q1.2**: If you issue `kill -9 14201` directly from the host system root shell, what happens to the container and why?
3. **Q1.3**: How does `docker exec` spawn a new process inside an existing container without creating a new container instance?

---

### Exercise 2: Storage Architecture - Overlay2 Mechanics, Bind Mounts, Named Volumes & Tmpfs

#### Scenario & Objective
You are tasked with evaluating storage options for stateful database storage, ephemeral secrets, and host configuration sharing. You will inspect the underlying `overlay2` storage driver directory layout and compare performance/isolation characteristics across volume types.

```
+-----------------------------------------------------------------------------------+
| CONTAINER STORAGE LAYERS                                                          |
|                                                                                   |
| +-------------------------------------------------------------------------------+ |
| | RW Container Layer (UpperDir) -> Modifications, diffs, temporary writes      | |
| +-------------------------------------------------------------------------------+ |
| | Merged View (OverlayFS)      -> Unified filesystem exposed to container         | |
| +-------------------------------------------------------------------------------+ |
| | RO Image Layer 2 (LowerDir)  -> Modified software packages                     | |
| +-------------------------------------------------------------------------------+ |
| | RO Image Layer 1 (LowerDir)  -> Base OS (Alpine / Debian)                       | |
| +-------------------------------------------------------------------------------+ |
|                                                                                   |
| DIRECT STORAGE BYPASS MOUNTS:                                                     |
|  * Named Volume -> /var/lib/docker/volumes/<name>/_data  (High performance IO)    |
|  * Bind Mount   -> /path/on/host                         (Host file integration)  |
|  * Tmpfs Mount  -> Host RAM (tmpfs)                      (Secure ephemeral write) |
+-----------------------------------------------------------------------------------+
```

#### Execution Steps

1. Inspect the `overlay2` storage driver layout paths for container `web-prod-01`.
   ```bash
   docker inspect --format 'LowerDir: {{.GraphDriver.Data.LowerDir}}{{"\n"}}UpperDir: {{.GraphDriver.Data.UpperDir}}{{"\n"}}MergedDir: {{.GraphDriver.Data.MergedDir}}' web-prod-01
   ```
   *Expected Output:*
   ```text
   LowerDir: /var/lib/docker/overlay2/a89f.../diff:/var/lib/docker/overlay2/b12c.../diff
   UpperDir: /var/lib/docker/overlay2/e56f.../diff
   MergedDir: /var/lib/docker/overlay2/e56f.../merged
   ```

2. Create a named Docker volume for persistent PostgreSQL data storage.
   ```bash
   docker volume create pg-data-prod
   docker volume inspect pg-data-prod
   ```
   *Expected Output:*
   ```text
   [
       {
           "CreatedAt": "2026-08-07T04:46:10Z",
           "Driver": "local",
           "Labels": {},
           "Mountpoint": "/var/lib/docker/volumes/pg-data-prod/_data",
           "Name": "pg-data-prod",
           "Options": {},
           "Scope": "local"
       }
   ]
   ```

3. Launch a container with three distinct storage configurations:
   * Named volume mounted at `/var/lib/postgresql/data`
   * Bind mount mounted at `/var/log/app_host_logs`
   * Tmpfs mount mounted at `/tmp/secrets` (size limit 64MB, mode 0700)
   ```bash
   mkdir -p /tmp/host_logs

   docker run -d \
     --name db-store-01 \
     --mount type=volume,source=pg-data-prod,target=/var/lib/postgresql/data \
     --mount type=bind,source=/tmp/host_logs,target=/var/log/app_host_logs \
     --mount type=tmpfs,target=/tmp/secrets,tmpfs-size=67108864,tmpfs-mode=0700 \
     alpine tail -f /dev/null
   ```
   *Expected Output:*
   ```text
   d7e8f9a0b1c234567890abcdef1234567890abcdef1234567890abcdef123456
   ```

4. Verify mount propagation and write operations across storage backends inside the container.
   ```bash
   docker exec db-store-01 sh -c \
     "echo 'vol_data' > /var/lib/postgresql/data/db.dat && \
      echo 'log_data' > /var/log/app_host_logs/app.log && \
      echo 'secret_key' > /tmp/secrets/api.key"
   ```

5. Confirm host persistence for named volume and bind mount files.
   ```bash
   cat /var/lib/docker/volumes/pg-data-prod/_data/db.dat
   cat /tmp/host_logs/app.log
   ```
   *Expected Output:*
   ```text
   vol_data
   log_data
   ```

6. Stop and remove container `db-store-01` and verify `tmpfs` non-persistence.
   ```bash
   docker rm -f db-store-01
   ls -la /tmp/secrets 2>/dev/null || echo "Tmpfs mount unmounted and memory purged."
   ```
   *Expected Output:*
   ```text
   Tmpfs mount unmounted and memory purged.
   ```

#### Comprehension Questions - Exercise 2
1. **Q2.1**: How does the copy-on-write (CoW) strategy in `overlay2` impact write performance when modifying a 10GB file contained in an underlying image `lowerdir` layer?
2. **Q2.2**: Why are Docker Named Volumes preferred over host Bind Mounts for production database engines running on Linux?
3. **Q2.3**: What security and performance advantages does `tmpfs` offer for sensitive files (e.g., API keys, SSL private keys)?

---

### Exercise 3: Advanced Container Networking - Custom Bridges, Port Publishing & Network Namespaces

#### Scenario & Objective
You need to construct an isolated multi-tier network topology using Docker user-defined bridge networks. You will configure internal container DNS resolution, publish target ports to host interfaces, and debug container iptables rules using kernel network tools.

```
+-------------------------------------------------------------------------------------+
| HOST NETWORK INTERFACE (eth0: 192.168.1.50)                                        |
|  |                                                                                  |
|  +--- Published Port 8080:80 (iptables DNAT rule)                                   |
|                                                                                     |
| DOCKER CUSTOM BRIDGE (net-prod-backend: 172.28.0.0/16)                             |
|  |                                                                                  |
|  +---> [ app-api-01 ] (IP: 172.28.0.2) --- Embedded DNS (127.0.0.11)                 |
|  |         ^                               |                                        |
|  |         | Automatic DNS Resolution      | Automatic DNS Resolution               |
|  |         v                               v                                        |
|  +---> [ app-db-01 ]  (IP: 172.28.0.3) <----+                                       |
+-------------------------------------------------------------------------------------+
```

#### Execution Steps

1. Create a custom isolated bridge network with specific subnet and gateway parameters.
   ```bash
   docker network create \
     --driver bridge \
     --subnet 172.28.0.0/16 \
     --gateway 172.28.0.1 \
     net-prod-backend
   ```
   *Expected Output:*
   ```text
   c3b2a10987654321fedcba9876543210fedcba9876543210fedcba9876543210
   ```

2. Launch a database container attached to `net-prod-backend` without exposing ports to the host interface.
   ```bash
   docker run -d \
     --name app-db-01 \
     --network net-prod-backend \
     --network-alias database.internal \
     alpine sleep 3600
   ```
   *Expected Output:*
   ```text
   e1f2a3b4c5d678901234567890abcdef1234567890abcdef1234567890abcdef
   ```

3. Launch an application server container attached to `net-prod-backend` publishing port 8080.
   ```bash
   docker run -d \
     --name app-api-01 \
     --network net-prod-backend \
     -p 8080:80 \
     nginx:1.25-alpine
   ```
   *Expected Output:*
   ```text
   f9e8d7c6b5a432109876543210fedcba9876543210fedcba9876543210fedcba
   ```

4. Test automatic embedded DNS service discovery from `app-api-01` to `app-db-01` via name and network alias.
   ```bash
   docker exec app-api-01 ping -c 2 app-db-01
   docker exec app-api-01 nslookup database.internal
   ```
   *Expected Output:*
   ```text
   PING app-db-01 (172.28.0.2): 56 data bytes
   64 bytes from 172.28.0.2: seq=0 ttl=64 time=0.082 ms
   64 bytes from 172.28.0.2: seq=1 ttl=64 time=0.075 ms

   Server:		127.0.0.11
   Address:	127.0.0.11:53

   Name:	database.internal
   Address: 172.28.0.2
   ```

5. Inspect host `iptables` NAT table rules created by Docker for port forwarding.
   ```bash
   iptables -t nat -L DOCKER -n -v
   ```
   *Expected Output:*
   ```text
   Chain DOCKER (2 references)
    pkts bytes target     prot opt in     out     source               destination         
       0     0 ACCEPT     tcp  --  !br-c3b2a1098765 br-c3b2a1098765  0.0.0.0/0            172.28.0.3           tcp dpt:80
   ```

6. Verify port binding details on the host network interfaces using `docker port`.
   ```bash
   docker port app-api-01
   ```
   *Expected Output:*
   ```text
   80/tcp -> 0.0.0.0:8080
   80/tcp -> [::]:8080
   ```

#### Comprehension Questions - Exercise 3
1. **Q3.1**: Why does automatic DNS resolution by container name work on user-defined bridge networks, but fail on the default `bridge` network (`docker0`)?
2. **Q3.2**: What is the purpose of the internal DNS resolver IP `127.0.0.11` listed inside `/etc/resolv.conf` of container `app-api-01`?
3. **Q3.3**: How does `--network host` mode differ from bridge network mode regarding network latency, security isolation, and port collisions?

---

### Exercise 4: Resource Allocation, Cgroups v2 Control, Memory Throttling & OOM Diagnostics

#### Scenario & Objective
You need to prevent noisy-neighbor container issues by enforcing explicit CPU quotas and memory limits. You will trigger an Out-Of-Memory (OOM) condition, verify kernel cgroup control files, and inspect exit codes using standard CLI diagnostics.

```
+-------------------------------------------------------------------------------------+
| CGROUPS V2 RESOURCE BOUNDARIES                                                      |
|                                                                                     |
| Container Configuration: --memory=128m --cpus="0.5"                                |
|                                                                                     |
| Kernel Control Path: /sys/fs/cgroup/docker/<container-id>/                          |
|                                                                                     |
|   +-----------------------+     +-----------------------------------------------+   |
|   | memory.max = 134217728|     | cpu.max = 50000 100000                        |   |
|   | (Hard memory limit)   |     | (50ms quota per 100ms period = 0.5 Cores)     |   |
|   +-----------------------+     +-----------------------------------------------+   |
|               |                                         |                           |
|   Exceeding limit triggers                  CFS Scheduler throttles CPU             |
|   Kernel OOM Killer (Exit 137)              time when quota is exhausted            |
+-------------------------------------------------------------------------------------+
```

#### Execution Steps

1. Launch a resource-constrained container with 128MB Memory, 64MB Swap limit, and 0.5 CPU allocation.
   ```bash
   docker run -d \
     --name stress-limit-01 \
     --memory 128m \
     --memory-swap 192m \
     --cpus 0.5 \
     progrium/stress --cpu 2 --io 1 --vm 1 --vm-bytes 64M
   ```
   *Expected Output:*
   ```text
   a1b2c3d4e5f678901234567890abcdef1234567890abcdef1234567890abcdef
   ```

2. Inspect real-time streaming resource utilization using `docker stats` (non-streaming single execution).
   ```bash
   docker stats stress-limit-01 --no-stream
   ```
   *Expected Output:*
   ```text
   CONTAINER ID   NAME              CPU %     MEM USAGE / LIMIT   MEM %     NET I/O     BLOCK I/O   PIDS
   a1b2c3d4e5f6   stress-limit-01   50.12%    68.4MiB / 128MiB    53.44%    1.02kB/0B   0B / 0B     5
   ```

3. Read host kernel cgroup v2 parameter files for container `stress-limit-01`.
   ```bash
   FULL_ID=$(docker inspect --format '{{.Id}}' stress-limit-01)
   
   # Read memory hard limit
   cat /sys/fs/cgroup/system.slice/docker-${FULL_ID}.scope/memory.max 2>/dev/null || \
   cat /sys/fs/cgroup/docker/${FULL_ID}/memory.max
   
   # Read CPU limit quota/period
   cat /sys/fs/cgroup/system.slice/docker-${FULL_ID}.scope/cpu.max 2>/dev/null || \
   cat /sys/fs/cgroup/docker/${FULL_ID}/cpu.max
   ```
   *Expected Output:*
   ```text
   134217728
   50000 100000
   ```

4. Trigger an intentional Out-Of-Memory (OOM) state by launching a container attempting to allocate 256MB on a 64MB limit.
   ```bash
   docker run --name oom-test-01 --memory 64m alpine sh -c "python3 -c 'a = \"A\" * 200000000' 2>/dev/null || tail -c 200M /dev/zero | grep -a a"
   ```
   *Expected Output:*
   ```text
   Killed
   ```

5. Inspect exit state, error flags, and OOMKilled status using `docker inspect`.
   ```bash
   docker inspect --format 'State: ExitCode={{.State.ExitCode}}, OOMKilled={{.State.OOMKilled}}, Error={{.State.Error}}' oom-test-01
   ```
   *Expected Output:*
   ```text
   State: ExitCode=137, OOMKilled=true, Error=
   ```

6. Clean up diagnostic stress test containers.
   ```bash
   docker rm -f stress-limit-01 oom-test-01
   ```

#### Comprehension Questions - Exercise 4
1. **Q4.1**: What does an Exit Code of `137` indicate when returned by a stopped Docker container?
2. **Q4.2**: If `--memory` is set to `256m` and `--memory-swap` is set to `256m`, how much total swap space is available to the container?
3. **Q4.3**: How does the kernel Completely Fair Scheduler (CFS) enforce `--cpus="0.5"` using `cpu.cfs_quota_us` and `cpu.cfs_period_us` under cgroups v1/v2?

---

### Exercise 5: Production Logging, Container Inspection with Go Templates & Real-time Diagnostics

#### Scenario & Objective
You need to implement advanced diagnostic pipelines for troubleshooting production containers. You will filter container metadata using Go templates in `docker inspect`, control logging driver limits, track process resource usage with `docker top`, and monitor real-time execution logs.

#### Execution Steps

1. Launch a log-generating production service configured with rotation limits via `--log-opt`.
   ```bash
   docker run -d \
     --name logger-prod-01 \
     --log-driver json-file \
     --log-opt max-size=10m \
     --log-opt max-file=3 \
     alpine sh -c "i=0; while true; do echo \"$(date -u -Iseconds) [INFO] Processing batch record #\$i\"; i=\$((i+1)); sleep 1; done"
   ```
   *Expected Output:*
   ```text
   b2c3d4e5f6a178901234567890abcdef1234567890abcdef1234567890abcdef
   ```

2. Extract complex metadata fields (IP Address, Mount Points, Restart Policy, State) using `docker inspect` with Go formatting templates.
   ```bash
   docker inspect --format '
   Container Name  : {{.Name}}
   Status          : {{.State.Status}} (Running: {{.State.Running}})
   IP Address      : {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}
   Log Path        : {{.LogPath}}
   Restart Policy  : {{.HostConfig.RestartPolicy.Name}}
   ' logger-prod-01
   ```
   *Expected Output:*
   ```text
   Container Name  : /logger-prod-01
   Status          : running (Running: true)
   IP Address      : 172.17.0.2
   Log Path        : /var/lib/docker/containers/b2c3d4e5f6a1.../b2c3d4e5f6a1...-json.log
   Restart Policy  : no
   ```

3. Stream container log output with timestamping and log tailing.
   ```bash
   docker logs --timestamps --tail 5 logger-prod-01
   ```
   *Expected Output:*
   ```text
   2026-08-07T04:48:01.123456789Z 2026-08-07T04:48:01Z [INFO] Processing batch record #0
   2026-08-07T04:48:02.124567890Z 2026-08-07T04:48:02Z [INFO] Processing batch record #1
   2026-08-07T04:48:03.125678901Z 2026-08-07T04:48:03Z [INFO] Processing batch record #2
   2026-08-07T04:48:04.126789012Z 2026-08-07T04:48:04Z [INFO] Processing batch record #3
   2026-08-07T04:48:05.127890123Z 2026-08-07T04:48:05Z [INFO] Processing batch record #4
   ```

4. Display specific OS processes running inside the container with custom output arguments using `docker top`.
   ```bash
   docker top logger-prod-01 -o pid,comm,args
   ```
   *Expected Output:*
   ```text
   PID         COMMAND         COMMAND
   15102       sh              sh -c i=0; while true; do echo "$(date -u -Iseconds) [INFO] Processing batch record #$i"; i=$((i+1)); sleep 1; done
   15145       sleep           sleep 1
   ```

5. Retrieve log file locations and check physical disk usage of container logs on host system.
   ```bash
   LOG_FILE=$(docker inspect --format '{{.LogPath}}' logger-prod-01)
   ls -lh ${LOG_FILE}
   ```
   *Expected Output:*
   ```text
   -rw-r----- 1 root root 402 Aug  7 04:48 /var/lib/docker/containers/b2c3d4e5f6a1.../b2c3d4e5f6a1...-json.log
   ```

6. Perform bulk cleanup of all active exercises containers and user-defined networks.
   ```bash
   docker rm -f web-prod-01 app-api-01 app-db-01 logger-prod-01
   docker network rm net-prod-backend
   docker volume rm pg-data-prod
   ```

#### Comprehension Questions - Exercise 5
1. **Q5.1**: What risk is introduced if high-throughput production containers use the default `json-file` logging driver without specifying `--log-opt max-size`?
2. **Q5.2**: How can you format `docker inspect` using JSON output piping to `jq` to extract all environment variables starting with `PORT`?
3. **Q5.3**: What is the difference between `docker stop` and `docker kill` regarding signal delivery (`SIGTERM` vs `SIGKILL`) and grace periods?

---

<details>
<summary><b>Answers & Detailed Explanations</b></summary>

### Exercise 1 Answers

* **A1.1**: Linux Kernel Namespace Inodes isolate global system resources. `/proc/14201/ns/pid` references inode `4026532588`, which defines the isolated PID namespace boundary for `web-prod-01`. Inside this namespace, the master Nginx process is assigned PID 1. `/proc/self/ns/pid` references inode `4026531836`, representing the host's root PID namespace where the process has PID `14201`.
* **A1.2**: Issuing `kill -9 14201` sends uncatchable `SIGKILL` directly to the host process representing PID 1 inside the container PID namespace. Because PID 1 is the container entrypoint process, killing it causes the Linux kernel to immediately terminate all child processes in that PID namespace and teardown the container.
* **A1.3**: `docker exec` calls the kernel `setns()` system call to join the existing namespaces (PID, NET, MNT, IPC, UTS) of target process PID 1 (`/proc/14201/ns/`). Once inside those namespace file descriptors, `execve()` executes the specified binary (`sh`), running it under the existing container boundaries without creating a new container construct.

---

### Exercise 2 Answers

* **A2.1**: When a process writes to a pre-existing file in `lowerdir` under `overlay2`, the kernel performs a **Copy-on-Write (CoW)** operation: it copies the complete file from the read-only lower layer into the container's upper read-write layer (`upperdir`) before completing the modification. For a 10GB file, this incurs massive disk I/O latency, severe block allocation overhead, and duplicate storage consumption.
* **A2.2**: Named Volumes are stored directly in `/var/lib/docker/volumes/<name>/_data` using native host file system formats (e.g., ext4, xfs) bypassing the `overlay2` CoW driver entirely. This guarantees maximum native raw I/O throughput. Furthermore, Named Volumes are managed by Docker CLI abstractions and isolated from accidental host file system path changes.
* **A2.3**: `tmpfs` mounts write directly into host RAM (volatile memory) and unmount completely upon container termination. Sensitive secrets (private keys, tokens) written to `tmpfs` are never written to physical host storage drives (SSD/NVMe), preventing storage leaks, residual data exposure on host disk images, or CoW storage overhead.

---

### Exercise 3 Answers

* **A3.1**: Docker enables its embedded DNS server (`127.0.0.11`) **only** for custom user-defined bridge networks. On the legacy default `bridge` network (`docker0`), container name resolution is disabled for backward compatibility, requiring legacy `--link` flags or explicit IP address communication.
* **A3.2**: `127.0.0.11` is the loopback IP address of the Docker embedded DNS resolver. When a container on a custom bridge queries a domain name, iptables rules redirect port 53 traffic to the Docker daemon internal resolver daemon, which dynamically maps container names and network aliases to their active container IP addresses.
* **A3.3**: Under `--network host`, the container shares the host network namespace directly:
  * **Latency**: Removes network abstraction overlay and iptables NAT overhead, delivering native bare-metal throughput.
  * **Security**: Removes network layer isolation; container processes can bind directly to host interfaces and sniff host traffic.
  * **Port Collisions**: Port bindings are global; two containers cannot bind to port 80 simultaneously on the host.

---

### Exercise 4 Answers

* **A4.1**: Exit Code `137` indicates that the process was terminated by `SIGKILL` (Signal 9) issued by the Linux Kernel Out-Of-Memory (OOM) Killer (`128 + 9 = 137`). This occurs when a container process exceeds its hard cgroup memory ceiling (`memory.max`).
* **A4.2**: Zero total swap space. Docker defines `--memory-swap` as the **total sum** of RAM plus Swap. If `--memory` is `256m` and `--memory-swap` is `256m`, Swap is calculated as `256m - 256m = 0m`. To grant 256MB RAM and 128MB Swap, `--memory-swap` must be set to `384m`.
* **A4.3**: The Linux kernel Completely Fair Scheduler (CFS) enforces fractional CPU allocation using a quota system over a defined period (default 100ms / `100000us`):
  * `cpu.cfs_period_us` = `100000` (100ms)
  * `cpu.cfs_quota_us` = `50000` (50ms)
  A setting of `--cpus="0.5"` configures the cgroup to allow the container processes a maximum execution budget of 50ms per 100ms window across all host CPU cores.

---

### Exercise 5 Answers

* **A5.1**: Unbounded `json-file` logging fills host storage partitions without restriction. If container stdout/stderr output generates excessive logs, `/var/lib/docker/containers/<id>/<id>-json.log` will consume 100% of host disk space, resulting in host system failure, read-only file system remounts, and cascading application outages.
* **A5.2**: You pipe formatted JSON output from `docker inspect` directly to `jq`:
  ```bash
  docker inspect logger-prod-01 | jq '.[0].Config.Env | map(select(startswith("PORT=")))'
  ```
* **A5.3**: 
  * `docker stop`: Sends `SIGTERM` to process PID 1 inside the container, initiating a graceful shutdown period (default 10 seconds). If the process does not terminate within the grace period, Docker sends `SIGKILL`.
  * `docker kill`: Bypasses graceful termination entirely by sending `SIGKILL` (or a specified custom signal) immediately to PID 1, terminating process execution instantaneously without cleanup handlers.

</details>