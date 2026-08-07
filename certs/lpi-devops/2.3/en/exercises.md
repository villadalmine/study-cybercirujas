# LPI DevOps Tools Engineer (Exam 701-100) — Advanced Study Material
## Topic 2.3: Container Infrastructure (Weight: 6.67 / Weight 5)

**Target Audience:** Senior Platform Engineers, Site Reliability Engineers (SRE), Systems Architects  
**Official Reference:** [LPI DevOps Tools Engineer Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/) | [Docker Architecture Documentation](https://docs.docker.com/engine/architecture/) | [Linux Kernel Namespaces & Cgroups v2](https://man7.org/linux/man-pages/man7/namespaces.7.html)

---

## Technical Overview & Architectural Foundations

Containerization relies on low-level Linux kernel primitives rather than hypervisor hardware virtualization. Understanding how the container runtime (e.g., `containerd`, `runc`) orchestrates these primitives is required for operating container infrastructure at scale in production environments.

### Core Architectural Primitives

1. **Linux Namespaces (Isolation):**
   * `pid`: Process tree isolation (Container PID 1 maps to a standard PID on the host).
   * `net`: Network device, IP routing table, firewall rule, and port binding isolation.
   * `mnt`: Filesystem mount point isolation.
   * `ipc`: Inter-Process Communication isolation (System V IPC, POSIX message queues).
   * `uts`: Hostname and NIS domain name isolation.
   * `user`: User and group ID mapping (allows unprivileged container root UID 0 to map to an unprivileged host UID).
   * `cgroup`: Root directory isolation for Control Group paths.

2. **Control Groups v2 (Resource Management & Accounting):**
   * Enforces hard and soft memory limits (`memory.max`, `memory.high`), CPU bandwidth allocations (`cpu.max`), and Block I/O throughput (`io.weight`).
   * Triggers the Out-Of-Memory (OOM) Killer when `memory.max` plus `memory.swap.max` boundaries are breached without host kernel panics.

3. **OverlayFS (Storage Driver Architecture):**
   * Uses a union mount filesystem combining four directories:
     * `lowerdir`: Read-only base layers (built from Dockerfile steps).
     * `upperdir`: Read-write container layer (transient runtime mutations).
     * `workdir`: Internal kernel workspace for atomic mutations.
     * `merged`: Consolidated mount point visible inside the running container.
   * **Copy-on-Write (CoW):** When a process inside the container modifies an existing read-only file from `lowerdir`, OverlayFS copies the file into `upperdir` before executing write operations.

4. **Container Networking Interface & Traffic Routing:**
   * **Bridge Mode (`bridge`):** Default host-local network. Docker creates a virtual bridge interface (e.g., `docker0` or custom `br-xxxxxxxxxxxx`). Each container receives a Virtual Ethernet (`veth`) pair; one end resides inside the container's network namespace (`eth0`), while the other attaches to the host bridge.
   * **Port Forwarding Architecture:** Traffic targeting host ports is intercepted by host `iptables` NAT rules inside the `DOCKER` chain and routed to the container's internal IP via `DNAT` (Destination Network Address Translation).

---

## Exercise 1: Linux Kernel Primitives & Container Runtime Mechanics

**Objective:** Inspect and debug process isolation (Namespaces), Cgroups v2 resource accounting, and OverlayFS layer mounts directly on the host system.

### Step-by-Step Execution

1. Start an isolated, resource-constrained Nginx container running in the background:
   ```bash
   docker run -d \
     --name prod-nginx-edge \
     --memory="256m" \
     --cpus="0.5" \
     --publish 8080:80 \
     nginx:1.25-alpine
   ```
   *Expected Output:*
   ```text
   a1b2c3d4e5f67890abcdef1234567890abcdef1234567890abcdef1234567890
   ```

2. Retrieve the host Process ID (PID) of the main Nginx process inside the container namespace using `docker inspect`:
   ```bash
   CONTAINER_PID=$(docker inspect --format '{{ .State.Pid }}' prod-nginx-edge)
   echo "Host PID of Container PID 1: ${CONTAINER_PID}"
   ```
   *Expected Output:*
   ```text
   Host PID of Container PID 1: 42189
   ```

3. Inspect the active Linux Namespaces assigned to this host PID using `lsns`:
   ```bash
   lsns -p ${CONTAINER_PID}
   ```
   *Expected Output:*
   ```text
   NS TIME NSECT        TYPE   NPROCS   PID USER    COMMAND
   4026531835 net      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531836 mnt      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531837 uts      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531838 pid      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531839 ipc      1        1 42189 root    nginx: master process nginx -g daemon off;
   4026531840 cgroup   1        1 42189 root    nginx: master process nginx -g daemon off;
   ```

4. Execute commands inside the target container's Network and Mount namespaces directly from the host using `nsenter` without utilizing `docker exec`:
   ```bash
   sudo nsenter --target ${CONTAINER_PID} --net --mnt ip addr show eth0
   ```
   *Expected Output:*
   ```text
   7: eth0@if8: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
       link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
       inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
          valid_lft forever preferred_lft forever
   ```

5. Verify Cgroups v2 memory and CPU controller limit enforcement in `/sys/fs/cgroup`:
   ```bash
   CGROUP_PATH=$(docker inspect --format '{{ .Id }}' prod-nginx-edge)
   cat /sys/fs/cgroup/docker/${CGROUP_PATH}/memory.max
   cat /sys/fs/cgroup/docker/${CGROUP_PATH}/cpu.max
   ```
   *Expected Output:*
   ```text
   268435456
   50000 100000
   ```
   *(Note: `268435456` bytes = 256MB. `50000 100000` indicates 50,000µs quota per 100,000µs period = 0.5 CPUs).*

6. Inspect the OverlayFS lower, upper, work, and merged directories via `docker inspect`:
   ```bash
   docker inspect --format '{{ json .GraphDriver.Data }}' prod-nginx-edge | jq .
   ```
   *Expected Output:*
   ```json
   {
     "LowerDir": "/var/lib/docker/overlay2/a89f.../diff:/var/lib/docker/overlay2/b12c.../diff",
     "MergedDir": "/var/lib/docker/overlay2/c34d.../merged",
     "UpperDir": "/var/lib/docker/overlay2/c34d.../diff",
     "WorkDir": "/var/lib/docker/overlay2/c34d.../work"
   }
   ```

---

### Questions (Block 1)

1. What happens to write performance when a container writes heavily to a pre-existing 10GB file located inside `lowerdir` under the OverlayFS storage driver?
2. If a container breaches its configured `--memory="256m"` limit without swap enabled, which kernel subsystem acts, and how can an operator distinguish an OOM termination from an application-level failure exit code?

---

## Exercise 2: Advanced Container Networking Architecture & Traffic Routing

**Objective:** Build isolated bridge networks, trace `veth` interface pairings between host and container namespaces, and debug `iptables` NAT chains.

### Step-by-Step Execution

1. Create a custom isolated bridge network with an explicit CIDR subnet, gateway, and fixed MTU:
   ```bash
   docker network create \
     --driver bridge \
     --subnet 10.240.50.0/24 \
     --gateway 10.240.50.1 \
     --opt "com.docker.network.driver.mtu"="1450" \
     prod-vpc-net
   ```
   *Expected Output:*
   ```text
   e7c10b9f3a4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f
   ```

2. Run two microservice containers attached to `prod-vpc-net`:
   ```bash
   docker run -d --name app-backend --network prod-vpc-net alpine sleep 3600
   docker run -d --name app-frontend --network prod-vpc-net -p 9000:80 nginx:alpine
   ```
   *Expected Output:*
   ```text
   11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff
   223344556677889900aabbccddeeff11223344556677889900aabbccddeeff11
   ```

3. Identify the host interface matching the container's virtual ethernet (`veth`) endpoint for `app-frontend`:
   ```bash
   # Retrieve container side veth index
   IFINDEX=$(docker exec app-frontend cat /sys/class/net/eth0/iflink)
   # Map to host interface name
   ip link | grep "^${IFINDEX}:"
   ```
   *Expected Output:*
   ```text
   14: vethb4a1c2d@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue master br-e7c10b9f3a4d state UP mode DEFAULT group default
   ```

4. Audit the Linux Kernel `iptables` NAT table to trace destination port forwarding (`DNAT`) for port `9000`:
   ```bash
   sudo iptables -t nat -L DOCKER -n -v --line-numbers
   ```
   *Expected Output:*
   ```text
   Chain DOCKER (2 references)
   num   pkts bytes target     prot opt in     out     source               destination         
   1        0     0 DNAT       tcp  --  !br-e7c10b9f3a4d * 0.0.0.0/0 0.0.0.0/0 tcp dpt:9000 to:10.240.50.3:80
   ```

5. Verify embedded DNS resolution (`127.0.0.11`) across containers on custom user-defined networks:
   ```bash
   docker exec app-backend ping -c 2 app-frontend
   ```
   *Expected Output:*
   ```text
   PING app-frontend (10.240.50.3): 56 data bytes
   64 bytes from 10.240.50.3: seq=0 ttl=64 time=0.082 ms
   64 bytes from 10.240.50.3: seq=1 ttl=64 time=0.065 ms

   --- app-frontend ping statistics ---
   2 packets transmitted, 2 packets received, 0% packet loss
   ```

---

### Questions (Block 2)

1. Why does automatic container DNS name resolution work on user-defined bridge networks (e.g., `prod-vpc-net`), but fail on the default legacy `bridge` (`docker0`) network?
2. When traffic flows from `10.240.50.2` (inside container) out to an external internet endpoint (e.g., `8.8.8.8`), which `iptables` table and chain converts the container private IP into the host node's public interface IP address?

---

## Exercise 3: Production Docker Daemon Hardening & Storage Engine Tuning

**Objective:** Configure enterprise daemon properties via `/etc/docker/daemon.json`, implement log rotation, enforce Live Restore, and optimize storage volume mount types.

### Step-by-Step Execution

1. Create a production-ready `/etc/docker/daemon.json` configuration file with log rotation, daemon live-restore, metrics endpoints, and default storage drivers:
   ```bash
   sudo mkdir -p /etc/docker
   sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
   {
     "storage-driver": "overlay2",
     "live-restore": true,
     "log-driver": "json-file",
     "log-opts": {
       "max-size": "50m",
       "max-file": "5"
     },
     "metrics-addr": "127.0.0.1:9323",
     "userland-proxy": false,
     "no-new-privileges": true
   }
   EOF
   ```

2. Reload daemon configuration without dropping running containers (made possible by setting `"live-restore": true`):
   ```bash
   sudo systemctl reload docker
   sudo docker info | grep -E "Logging Driver|Storage Driver|Live Restore"
   ```
   *Expected Output:*
   ```text
    Storage Driver: overlay2
    Logging Driver: json-file
    Live Restore Enabled: true
   ```

3. Test persistence boundaries and performance differences across container storage configurations:
   ```bash
   # Create a managed named volume
   docker volume create prod-db-data

   # Run container with named volume and tmpfs mount
   docker run -d \
     --name storage-bench \
     --mount type=volume,source=prod-db-data,target=/var/lib/postgresql/data \
     --mount type=tmpfs,target=/tmp/cache,tmpfs-size=67108864 \
     postgres:15-alpine
   ```
   *Expected Output:*
   ```text
   99887766554433221100aabbccddeeff99887766554433221100aabbccddeeff
   ```

4. Verify storage mount properties via `docker inspect`:
   ```bash
   docker inspect --format '{{ json .Mounts }}' storage-bench | jq .
   ```
   *Expected Output:*
   ```json
   [
     {
       "Type": "volume",
       "Name": "prod-db-data",
       "Source": "/var/lib/docker/volumes/prod-db-data/_data",
       "Destination": "/var/lib/postgresql/data",
       "Driver": "local",
       "Mode": "z",
       "RW": true,
       "Propagation": ""
     },
     {
       "Type": "tmpfs",
       "Destination": "/tmp/cache",
       "Mode": ""
     }
   ]
   ```

---

### Questions (Block 3)

1. What operational benefit does setting `"userland-proxy": false` provide in high-throughput containerized edge router deployments?
2. What is the key functional difference between a `bind mount` and a `named volume` regarding file initialization when mounting over a non-empty directory in the container image?

---

## Exercise 4: Multi-Container Orchestration & Resiliency with Docker Compose v2

**Objective:** Write a syntactically valid production `docker-compose.yml` manifest using Compose Specification standards, enforce dependency healthchecks, resource limits, and debug service state transitions.

### Step-by-Step Execution

1. Create a directory and define a multi-container platform manifest (`docker-compose.yml`) containing PostgreSQL, Redis, and a Web Application:
   ```bash
   mkdir -p ~/compose-lab && cd ~/compose-lab
   cat <<'EOF' > docker-compose.yml
   name: enterprise-stack

   services:
     postgres-db:
       image: postgres:15-alpine
       environment:
         POSTGRES_DB: app_db
         POSTGRES_USER: db_user
         POSTGRES_PASSWORD: SecretPassword123!
       volumes:
         - pgdata:/var/lib/postgresql/data
       networks:
         - backplane
       healthcheck:
         test: ["CMD-SHELL", "pg_isready -U db_user -d app_db"]
         interval: 5s
         timeout: 3s
         retries: 5
         start_period: 10s
       deploy:
         resources:
           limits:
             cpus: '1.0'
             memory: 512M
           reservations:
             cpus: '0.25'
             memory: 128M
       restart: unless-stopped

     redis-cache:
       image: redis:7-alpine
       command: redis-server --save 60 1 --loglevel notice
       networks:
         - backplane
       healthcheck:
         test: ["CMD", "redis-cli", "ping"]
         interval: 5s
         timeout: 2s
         retries: 3
       deploy:
         resources:
           limits:
             memory: 256M
       restart: always

     api-gateway:
       image: nginx:1.25-alpine
       ports:
         - "80:80"
       networks:
         - backplane
       depends_on:
         postgres-db:
           condition: service_healthy
         redis-cache:
           condition: service_healthy
       deploy:
         resources:
           limits:
             memory: 128M
       restart: always

   volumes:
     pgdata:
       driver: local

   networks:
     backplane:
       driver: bridge
       ipam:
         config:
           - subnet: 172.28.0.0/16
   EOF
   ```

2. Validate the compose file syntax and compile the normalized specification using `docker compose config`:
   ```bash
   docker compose config
   ```
   *Expected Output:*
   ```yaml
   name: enterprise-stack
   services:
     api-gateway:
       depends_on:
         postgres-db:
           condition: service_healthy
           required: true
         redis-cache:
           condition: service_healthy
           required: true
       image: nginx:1.25-alpine
       networks:
         backplane: null
       ports:
         - mode: ingress
           target: 80
           published: "80"
           protocol: tcp
       restart: always
   ...
   ```

3. Launch the application stack in detached mode and monitor initialization order:
   ```bash
   docker compose up -d
   ```
   *Expected Output:*
   ```text
   [+] Running 5/5
    ✔ Network enterprise-stack_backplane      Created                             0.1s
    ✔ Volume "enterprise-stack_pgdata"        Created                             0.0s
    ✔ Container enterprise-stack-redis-cache-1   Healthy                             6.2s
    ✔ Container enterprise-stack-postgres-db-1   Healthy                            11.4s
    ✔ Container enterprise-stack-api-gateway-1   Started                            11.6s
   ```

4. Verify status, health state, and port mappings across the stack using `docker compose ps`:
   ```bash
   docker compose ps
   ```
   *Expected Output:*
   ```text
   NAME                                   IMAGE              COMMAND                  SERVICE       CREATED          STATUS                    PORTS
   enterprise-stack-api-gateway-1   nginx:1.25-alpine   "/docker-entrypoint.…"   api-gateway   15 seconds ago   Up 4 seconds              0.0.0.0:80->80/tcp
   enterprise-stack-postgres-db-1   postgres:15-alpine  "docker-entrypoint.s…"   postgres-db   15 seconds ago   Up 14 seconds (healthy)   5432/tcp
   enterprise-stack-redis-cache-1   redis:7-alpine     "docker-entrypoint.s…"   redis-cache   15 seconds ago   Up 14 seconds (healthy)   6379/tcp
   ```

5. Inspect resource consumption across all stack containers in real time:
   ```bash
   docker compose top
   ```
   *Expected Output:*
   ```text
   enterprise-stack-api-gateway-1
   UID   PID     PPID    C   STIME   TTY   TIME       CMD
   root  52140   52110   0   04:30   ?     00:00:00   nginx: master process nginx -g daemon off;
   101   52195   52140   0   04:30   ?     00:00:00   nginx: worker process

   enterprise-stack-postgres-db-1
   UID   PID     PPID    C   STIME   TTY   TIME       CMD
   70    51800   51760   0   04:30   ?     00:00:00   postgres
   ...
   ```

6. Clean up resources and remove associated volumes:
   ```bash
   docker compose down -v
   ```
   *Expected Output:*
   ```text
   [+] Running 4/4
    ✔ Container enterprise-stack-api-gateway-1   Removed                             0.2s
    ✔ Container enterprise-stack-postgres-db-1   Removed                             0.3s
    ✔ Container enterprise-stack-redis-cache-1   Removed                             0.2s
    ✔ Network enterprise-stack_backplane      Removed                             0.1s
    ✔ Volume enterprise-stack_pgdata           Removed                             0.0s
   ```

---

### Questions (Block 4)

1. How does `condition: service_healthy` differ from standard `depends_on` without conditions when initializing downstream containers?
2. If `restart: unless-stopped` is specified on a container, what will Docker do when the host system reboots, assuming the container was manually stopped by an operator prior to reboot?

---

<details>
<summary>Exercise Answer Key & Technical Explanations</summary>

### Exercise 1 Answer Key

1. **OverlayFS Copy-on-Write Performance Impact:**
   * OverlayFS operates at the file level, not the block level. When modifying a 10GB file residing in `lowerdir`, the kernel must copy the **entire 10GB file** into `upperdir` before executing the first write byte. This causes severe disk I/O latency, high storage consumption, and potential application write timeouts.
   * *Production Mitigation:* High I/O applications (e.g., databases) must never write heavy data to the container root filesystem (`overlay2`). Use **Named Volumes** or **Bind Mounts**, which bypass OverlayFS completely and write directly to host storage blocks at native speeds.

2. **OOM Killer Detection & Exit Codes:**
   * When container memory exceeds `memory.max`, the Linux kernel Cgroup OOM Killer terminates the main process inside the namespace using `SIGKILL` (Signal 9).
   * **Diagnosis Command:** `docker inspect <container_id> --format '{{ .State.ExitCode }} {{ .State.OOMKilled }}'`
   * An OOM-killed container returns `ExitCode: 137` (Standard convention: `128 + Signal 9 = 137`) and `.State.OOMKilled: true`. Application-level exceptions return exit code `1` or custom non-zero application codes without setting the kernel `OOMKilled` flag to `true`.

---

### Exercise 2 Answer Key

1. **User-Defined Bridge vs Default Bridge DNS:**
   * **User-Defined Bridge Networks:** Feature an embedded DNS server listening at IP `127.0.0.11` inside every attached container namespace. Docker automatically resolves container names and service aliases to container IPs via this embedded resolver.
   * **Default Bridge Network (`docker0`):** Does **not** support the embedded DNS server for container name resolution due to backward compatibility. Containers on `docker0` can only communicate via IP addresses or legacy explicit `--link` flags.

2. **Egress Packet SNAT Routing:**
   * **Table:** `nat`
   * **Chain:** `POSTROUTING`
   * **Rule Mechanics:** The Docker daemon inserts a `MASQUERADE` target rule in the `POSTROUTING` chain targeting outbound traffic originating from the bridge network CIDR (e.g., `10.240.50.0/24`). This performs Source Network Address Translation (SNAT), replacing the internal container source IP (`10.240.50.2`) with the node's public interface IP address before sending packets onto the host network.

---

### Exercise 3 Answer Key

1. **Disabling Userland Proxy (`"userland-proxy": false`):**
   * By default, Docker spawns a `docker-proxy` userland process for every published port to forward traffic between host and container interfaces. This adds process overhead, context switches, and CPU usage.
   * Disabling `userland-proxy` forces Docker to route all incoming port traffic strictly via high-performance kernel `iptables` NAT rules (`DNAT`), reducing CPU consumption and network latency under high request concurrency.

2. **Directory Initialization (Bind Mounts vs Named Volumes):**
   * **Named Volume:** If a new named volume is mounted to a non-empty directory in a container image (e.g., `/var/lib/postgresql/data` containing default config files), Docker **copies** the existing files from the image into the volume upon initialization before mounting.
   * **Bind Mount:** Mounting an existing host folder over a non-empty container image path **obscures** the container image files. The contents of the host path overwrite the visible filesystem inside the container target directory immediately, without performing image content copying.

---

### Exercise 4 Answer Key

1. **`service_healthy` Dependency Control:**
   * Standard `depends_on` only waits until the target container transitions into the `Running` state (process started), regardless of whether the application inside is ready to accept socket connections.
   * `condition: service_healthy` blocks the execution of the dependent service until the targeted upstream container passes its defined `healthcheck` criteria (e.g., Postgres passing `pg_isready` and entering the `healthy` status), preventing connection pool refusals during boot cascades.

2. **`unless-stopped` Restart Policy Behavior:**
   * If an operator explicitly executes `docker stop <container>` prior to a system reboot, Docker records the explicit stop state in its state database.
   * Upon system reboot, the Docker daemon **will not** auto-restart the container because it was manually stopped before reboot. If the system crashed or rebooted while the container was running, Docker will auto-restart it upon boot up.

</details>

---

## Official Sources & Standard Documentation
* **LPI Certification Specifications:** [LPI DevOps Tools Engineer Exam 701-100 Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* **Docker Engine Architecture & Storage:** [Docker OverlayFS Storage Driver Manual](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
* **Linux Kernel Primitives:** [Linux Programmer's Manual: Namespaces (7)](https://man7.org/linux/man-pages/man7/namespaces.7.html)
* **Linux Cgroups Specification:** [Linux Kernel Control Groups v2 Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
* **Docker Compose Specification:** [Official Compose File Specification](https://docs.docker.com/compose/compose-file/)