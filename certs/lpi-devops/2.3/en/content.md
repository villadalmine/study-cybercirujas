# LPI DevOps Tools Engineer (701-100, v1.0) — Study Guide

# Topic 2.3: Container Infrastructure (Weight: 6.67)

---

## 1. Motivation and Production Architectural Problem

### 1.1 The Architectural Paradigm Shift: Virtual Machines vs. Kernel-Level Containers

In enterprise infrastructure design, traditional hardware virtualization (Type-1/Type-2 Hypervisors) enforces isolation by emulating complete hardware sets. Each Virtual Machine (VM) runs its own independent operating system kernel, hardware drivers, and system services. This model incurs substantial overhead:
- **Memory Overhead**: Each VM allocates dedicated RAM for kernel state, buffer caches, and system daemons.
- **I/O Latency**: Storage and network operations traverse multiple virtualization translation layers (e.g., hypercalls, virtio queues).
- **Startup Latency**: Booting requires full OS initialization sequences (BIOS/UEFI, kernel init, systemd targets), lasting tens of seconds to minutes.

Container infrastructure replaces hardware emulation with **shared-kernel OS-level virtualization**. A containerized process runs as a native OS process directly scheduled by the host Linux kernel, wrapped in strict isolation boundaries defined by kernel primitives:

```
+-----------------------------------------------------------------------------------+
|                                 USER SPACE                                        |
|  +---------------------------+  +---------------------------+                     |
|  |    Container A (App)      |  |    Container B (App)      |  ... [Workstation /   |
|  +---------------------------+  +---------------------------+      Prod Host]     |
|  | Mount | Net | PID | User  |  | Mount | Net | PID | User  |                     |
|  | Namespaces & cgroups v2   |  | Namespaces & cgroups v2   |                     |
+--+---------------------------+--+---------------------------+---------------------+
|                                 KERNEL SPACE                                      |
|  +-----------------------------------------------------------------------------+  |
|  |                         Host Linux Kernel (Shared)                          |  |
|  |  - cgroups (cpu, memory, io)    - iptables / eBPF (network filtering)     |  |
|  |  - Overlay2 VFS driver          - Seccomp / AppArmor security filters     |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
|                               PHYSICAL HARDWARE                                   |
|   [ CPU / Memory / Network Interfaces (NIC) / NVMe Storage / Hardware Security ]  |
+-----------------------------------------------------------------------------------+
```

#### Kernel Primitives Mechanics

1. **Linux Namespaces (Isolation Boundaries)**:
   - `PID Namespace`: Isolates the process ID space. Process inside a container views itself as `PID 1`, while on the host kernel it maps to an arbitrary PID (e.g., `PID 14209`).
   - `NET Namespace`: Provides isolated virtual network stacks (`veth` interfaces, IP routing tables, socket lists, `iptables` chains).
   - `MNT Namespace`: Isolates filesystem mount points. Combined with `pivot_root`, it prevents processes from accessing the host root filesystem.
   - `IPC Namespace`: Isolates System V IPC and POSIX message queues, preventing cross-container shared memory exploits.
   - `UTS Namespace`: Isolates hostname and NIS domain names.
   - `USER Namespace`: Maps in-container `root` (UID 0) to an unprivileged non-zero UID on the host (e.g., UID 100000), eliminating container breakout root privileges on the host OS.
   - `CGROUP Namespace`: Hides host cgroup layout from containerized processes.

2. **Control Groups - cgroups v1 / v2 (Resource Accounting and Enforcement)**:
   - **Memory**: Enforces hard boundaries (`memory.max`), soft boundaries (`memory.high`), and OOM-killer behavior.
   - **CPU**: Enforces CFS (Completely Fair Scheduler) quotas. Setting `--cpus 2.0` configures `cpu.cfs_quota_us=200000` over a default `cpu.cfs_period_us=100000`.
   - **blkio / io**: Throttles read/write IOPS and BPS per block device (`io.max`).

3. **Storage Engine (Overlay2 VFS Driver)**:
   Container runtimes leverage Copy-on-Write (CoW) filesystems. `overlay2` merges multiple directory trees into a single unified view using four kernel components:
   - `lowerdir`: Read-only image layers stacked sequentially.
   - `upperdir`: Read-write container layer where modifications occur.
   - `merged`: Virtual unified directory mounted as the container's root filesystem.
   - `workdir`: Internal directory used by the kernel to prepare CoW atomic operations before committing to `upperdir`.

---

### 1.2 Workstation vs. Production Dedicated Container Host Architecture

Deploying containers on a local developer workstation differs fundamentally from configuring a enterprise production container host.

| Architectural Dimension | Workstation Setup | Dedicated Production Host |
| :--- | :--- | :--- |
| **Daemon Socket** | Unencrypted Unix Socket (`/var/run/docker.sock`) accessible via local wheel/docker group. | Mutual TLS (mTLS) over TCP socket (`tcp://0.0.0.0:2376`) + restricted Unix domain socket. |
| **Storage Driver** | Default system configuration, often prone to unmonitored disk space consumption. | Dedicated block storage partition (NVMe/SSD) explicitly formatted for `overlay2` (ext4 with `ftype=1` or xfs with `d_type=true`). |
| **Logging Subsystem** | Default `json-file` driver without max-size limits; logs consume host root disk (`/var/lib/docker/containers`). | Centralized log driver (`journald`, `fluentd`, or `syslog`) or `json-file` with strict size/file rotation (`10m`, `max-file=5`). |
| **Process Limits & Ulimits** | Inherited from desktop OS shell defaults (`nofile=1024`), leading to FD exhaustion. | System-wide daemon ulimits (`nofile=64535`, `nproc=4096`, `memlock=-1`). |
| **Kernel Hardening** | Standard desktop kernel config; default seccomp profile. | Custom Seccomp profile, AppArmor/SELinux strict enforcement, sysctl network hardening (`net.ipv4.ip_forward=1`, `net.ipv4.conf.all.rp_filter=1`). |
| **Daemon Availability** | Stopped on machine sleep/shutdown; containers die on daemon restart. | `live-restore: true` enabled in daemon config, allowing containers to stay alive during Docker daemon updates. |

---

### 1.3 Remote Daemon Provisioning Architecture & Docker Machine Mechanics

Provisioning dedicated container hosts across cloud providers (AWS, GCP, Azure) or bare-metal hypervisors requires automating remote Docker daemon installation, kernel module loading, and securing the remote API endpoint.

`docker-machine` automates this process via a structured orchestration pipeline:

```
[ Management Workstation ]
         |
         | 1. Provision VM / SSH Keypair
         v
[ Target Cloud / Hypervisor ]  ---> Creates Machine Instance
         |
         | 2. Connect via SSH (Port 22)
         |    - Detect OS (e.g., Ubuntu/RHEL)
         |    - Install Docker Engine binaries
         |    - Write /etc/docker/daemon.json
         v
[ Remote Docker Host ]
         |
         | 3. Provision Mutual TLS (mTLS) Infrastructure:
         |    - Generate Remote Server CA, Cert & Key
         |    - Generate Local Client Cert & Key signed by CA
         |    - Configure daemon listener: tcp://0.0.0.0:2376
         v
[ Client Workstation ] <=== Secure TLS Tunnel (Port 2376) ===> [ Remote Docker Daemon ]
 (Evaluates env vars: DOCKER_HOST, DOCKER_TLS_VERIFY, DOCKER_CERT_PATH)
```

#### Security Model of Remote Docker API

Exposing an unauthenticated Docker TCP socket (`tcp://0.0.0.0:2375`) grants full root privileges over the host machine, because mounting host system directories (`-v /:/host`) allows arbitrary host manipulation.

To prevent remote exploitation, production hosts enforce **Mutual TLS (mTLS)** on port 2376:
1. **Server Verification**: The client verifies the server certificate using a trusted Certificate Authority (CA) (`--tlsverify`, `--tlscacert=ca.pem`).
2. **Client Verification**: The Docker daemon validates the client's identity before accepting incoming REST API commands (`--tlscert=cert.pem`, `--tlskey=key.pem`).

---

## 2. Technical Comparisons & Trade-Off Matrices

### 2.1 Container Runtimes & Isolation Engines

| Feature / Metric | Docker Engine (runc + containerd) | Kata Containers (MicroVM) | Firecracker (MicroVM) | LXC / LXD (System Containers) |
| :--- | :--- | :--- | :--- | :--- |
| **Isolation Boundary** | Shared Linux Kernel (Namespaces + cgroups) | Dedicated Linux Kernel per container inside lightweight QEMU/Cloud-Hypervisor VM | Minimalist dedicated Rust kernel via KVM | Shared Linux Kernel (OS container model) |
| **Security Boundary** | Process-level (Vulnerable to kernel zero-day exploits) | Hardware-assisted virtualization (Intel VT-x / AMD-V) | Hardware-assisted virtualization (Minimal attack surface) | Process-level (System init-focused isolation) |
| **Startup Overhead** | ~50ms - 200ms | ~500ms - 2s | ~5ms - 10ms | ~1s - 3s |
| **Memory Footprint** | Extremely low (~5MB - 15MB overhead per cont.) | Moderate (~100MB - 150MB overhead per cont.) | Very low (~5MB - 10MB overhead per microVM) | Moderate (~30MB - 50MB per container) |
| **OCI Compliance** | 100% OCI Compliant | 100% OCI Compliant (via CRI/containerd plugin) | Requires specific shim (e.g., `containerd-shim-aws-firecracker`) | Non-OCI standard |
| **Production Use Case** | Microservices, general CI/CD workloads | Untrusted multi-tenant workloads, legacy apps needing full kernel capabilities | Serverless / Function-as-a-Service (FaaS) high-density execution | Full OS virtualization without hypervisor overhead |

---

### 2.2 Docker Storage Drivers

| Storage Driver | Kernel Prerequisites | Write Performance (CoW) | Inode Efficiency | Production Status & Recommendation |
| :--- | :--- | :--- | :--- | :--- |
| **`overlay2`** | Linux Kernel >= 4.0, ext4 (with `ftype=1`) or XFS (with `d_type=true`) | High (Native kernel VFS overlay performance) | High (Page cache shared across containers for lower layers) | **Default Production Standard**. Recommended for all Linux workloads. |
| **`btrfs`** | Btrfs filesystem backing store (`/var/lib/docker`) | Medium (Subvolume copy-on-write overhead) | High | Supported. Suitable if host system natively utilizes Btrfs storage pools. |
| **`zfs`** | ZFS on Linux backing store | High (When ZFS ARC cache is tuned correctly) | High | Supported. Excellent for enterprise storage systems with deduplication and snapshot requirements. |
| **`devicemapper`** | LVM Direct-LVM mode (Thin Provisioning) | Low (Block-level allocation latency) | Low (Pre-allocated block allocations consume disk space) | **Deprecated** in Docker Engine 18.09; completely removed in modern engines. |

---

### 2.3 Container Network Drivers

| Driver | Mechanics & Packet Traversal | Cross-Host Connectivity | Performance Overhead | Production Primary Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **`bridge`** | Creates virtual bridge `docker0` on host. Containers attach via `veth` pair. Network Address Translation (NAT) via `iptables`. | No (Local to host only) | Medium (NAT overhead for inbound/outbound packets) | Single-host applications, local development, isolated multi-tier services. |
| **`host`** | Bypasses network isolation. Container shares host's network namespace, IP, and port bindings directly. | No (Bound to host IP) | Zero (Native host network throughput) | High-performance latency-critical services (e.g., bare-metal load balancers, real-time media streaming). |
| **`macvlan`** | Assigns a MAC address to container from physical host interface. Container appears as physical device on underlying network. | Yes (Native L2 network routing) | Extremely Low (Direct hardware/sub-interface binding) | Legacy application migration requiring direct IP allocation from physical network DHCP/VLAN. |
| **`overlay`** | Creates VXLAN tunnel encapsulation (UDP port 4789) across host nodes using an embedded key-value store or Docker Swarm gossip. | Yes (Multi-host container networking) | Medium-High (Encapsulation/Decapsulation CPU cost) | Multi-host container clusters, Docker Swarm multi-node deployments. |

---

### 2.4 Remote Daemon Provisioning & Node Management Strategies

| Strategy | Provisioning Speed | Security Compliance | Maintenance Complexity | Production Suitability |
| :--- | :--- | :--- | :--- | :--- |
| **`docker-machine`** | Fast (~2-5 minutes per host) | Basic (Generates self-signed mTLS PKI automatically) | High (Deprecated upstream tool; requires manual state file management) | **Legacy / Standalone host management** (LPI 701-100 reference standard). |
| **Cloud-Init + Ansible** | Medium (~3-7 minutes) | Enterprise (Integrates with Vault, PKI, enterprise CA) | Low (Declarative configuration management) | Ideal for immutable host provisioning on IaaS (AWS EC2, OpenStack). |
| **Container-Optimized OS** | Fast (<1 minute image boot) | Maximum (Read-only root filesystem, auto-updating runtime) | Extremely Low | Standard for managed Kubernetes nodes (GKE, EKS) and modern container platforms. |

---

## 3. Complete Syntactically Valid Manifests & Infrastructure Configurations

### 3.1 Hardened Production Docker Daemon Configuration

Location: `/etc/docker/daemon.json`

```json
{
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5",
    "compress": "true"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "cgroupdriver": "systemd",
  "userns-remap": "default",
  "tlsverify": true,
  "tlscacert": "/etc/docker/certs.d/ca.pem",
  "tlscert": "/etc/docker/certs.d/server-cert.pem",
  "tlskey": "/etc/docker/certs.d/server-key.pem",
  "hosts": [
    "fd://",
    "tcp://0.0.0.0:2376"
  ],
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
  "metrics-addr": "0.0.0.0:9323",
  "experimental": false
}
```

---

### 3.2 Systemd Unit Override File for Remote Listeners

When configuring `"hosts"` inside `/etc/docker/daemon.json`, the default systemd startup command (`-H fd://`) conflicts with the JSON file configuration. To fix this, create a systemd override.

Location: `/etc/systemd/system/docker.service.d/override.conf`

```ini
[Service]
# Clear the existing ExecStart directive set by the base unit file
ExecStart=
# Redefine ExecStart without inline -H options, delegating socket configuration to daemon.json
ExecStart=/usr/bin/dockerd
# Ensure systemd limits do not constrain container execution
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
# Auto-restart daemon on crash
Restart=always
RestartSec=2s
```

---

### 3.3 Production OpenSSL Mutual TLS (mTLS) PKI Generation Script

This script generates an enterprise-grade internal Certificate Authority (CA) and signed server/client certificates for Docker Remote API security.

Location: `/usr/local/bin/generate-docker-certs.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="/etc/docker/certs.d"
HOST_FQDN="node-01.production.internal"
HOST_IP="192.168.10.50"
DAYS_VALID=365

mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

echo "=== 1. Generating CA Private Key and Certificate ==="
openssl genrsa -aes256 -out ca-key.pem -passout pass:SecretCAPassword123 4096
openssl req -new -x509 -days ${DAYS_VALID} -key ca-key.pem \
  -sha256 -out ca.pem -passin pass:SecretCAPassword123 \
  -subj "/C=US/ST=Texas/L=Austin/O=Enterprise SRE/CN=${HOST_FQDN}"

echo "=== 2. Generating Server Private Key and CSR ==="
openssl genrsa -out server-key.pem 4096
openssl req -subj "/CN=${HOST_FQDN}" -sha256 -new -key server-key.pem -out server.csr

echo "=== 3. Creating Server SAN Extension File ==="
cat <<EOF > server-ext.cnf
subjectAltName = DNS:${HOST_FQDN},IP:${HOST_IP},IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

echo "=== 4. Signing Server Certificate with CA ==="
openssl x509 -req -days ${DAYS_VALID} -sha256 -in server.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem \
  -extfile server-ext.cnf -passin pass:SecretCAPassword123

echo "=== 5. Generating Client Private Key and CSR ==="
openssl genrsa -out client-key.pem 4096
openssl req -subj '/CN=client' -new -key client-key.pem -out client.csr

echo "=== 6. Creating Client Extension File ==="
cat <<EOF > client-ext.cnf
extendedKeyUsage = clientAuth
EOF

echo "=== 7. Signing Client Certificate with CA ==="
openssl x509 -req -days ${DAYS_VALID} -sha256 -in client.csr \
  -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem \
  -extfile client-ext.cnf -passin pass:SecretCAPassword123

echo "=== 8. Securing Permissions ==="
chmod -v 0400 ca-key.pem server-key.pem client-key.pem
chmod -v 0444 ca.pem server-cert.pem client-cert.pem

rm -v server.csr client.csr server-ext.cnf client-ext.cnf
echo "=== PKI Generation Complete ==="
```

---

### 3.4 Multi-Host / Advanced Production Docker Compose Infrastructure

Location: `docker-compose.production.yml`

```yaml
version: '3.8'

networks:
  frontend-net:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: "br-frontend"
      com.docker.network.bridge.enable_icc: "false"
      com.docker.network.bridge.enable_ip_masquerade: "true"
    ipam:
      driver: default
      config:
        - subnet: 172.28.10.0/24
          gateway: 172.28.10.1

  backend-net:
    driver: bridge
    internal: true
    driver_opts:
      com.docker.network.bridge.name: "br-backend"
      com.docker.network.bridge.enable_icc: "true"
    ipam:
      driver: default
      config:
        - subnet: 172.28.20.0/24
          gateway: 172.28.20.1

volumes:
  db-data:
    driver: local
    driver_opts:
      type: "none"
      o: "bind"
      device: "/mnt/fast-nvme/postgres-data"
  redis-data:
    driver: local

services:
  reverse-proxy:
    image: nginx:1.25-alpine
    container_name: prod-nginx-proxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    networks:
      - frontend-net
    security_opt:
      - no-new-privileges:true
      - seccomp:/etc/docker/seccomp-strict.json
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETGID
      - SETUID
    resources:
      limits:
        cpus: '1.50'
        memory: 512M
      reservations:
        cpus: '0.25'
        memory: 128M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  app-backend:
    image: node:20-alpine
    container_name: prod-api-backend
    restart: unless-stopped
    command: ["node", "server.js"]
    working_dir: /usr/src/app
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://dbuser:SecurePass123@database:5432/appdb
    networks:
      - frontend-net
      - backend-net
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=64m
    depends_on:
      - database
    resources:
      limits:
        cpus: '2.00'
        memory: 1024M

  database:
    image: postgres:16-alpine
    container_name: prod-postgres-db
    restart: always
    environment:
      POSTGRES_USER: dbuser
      POSTGRES_PASSWORD: SecurePass123
      POSTGRES_DB: appdb
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - backend-net
    resources:
      limits:
        cpus: '4.00'
        memory: 4096M
```

---

## 4. Real CLI Commands & Complete Terminal Outputs ($)

### 4.1 Remote Container Host Provisioning via `docker-machine`

Creating a remote Docker host on a cloud instance via generic SSH driver.

```bash
$ docker-machine create \
  --driver generic \
  --generic-ip-address 192.168.10.50 \
  --generic-ssh-user sysadmin \
  --generic-ssh-key ~/.ssh/id_rsa_production \
  --engine-opt storage-driver=overlay2 \
  --engine-opt log-driver=json-file \
  --engine-opt log-opt=max-size=10m \
  --engine-opt live-restore=true \
  prod-node-01
```

```text
Running pre-create checks...
[prod-node-01] Connecting to 192.168.10.50 via SSH...
[prod-node-01] Validating SSH connection...
Creating machine...
[prod-node-01] Provisioning with ubuntu(systemd)...
[prod-node-01] Installing Docker Engine...
[prod-node-01] Customizing Docker Engine flags...
[prod-node-01] Configuring daemon in /etc/docker/daemon.json...
[prod-node-01] Copying certs to the local machine directory...
[prod-node-01] Copying certs to the remote machine...
[prod-node-01] Setting Docker configuration on the remote daemon...
[prod-node-01] Restarting Docker daemon...
Checking connection to Docker daemon...
Machine "prod-node-01" was created successfully!
To point your Docker client to the new machine, run: eval $(docker-machine env prod-node-01)
```

---

### 4.2 Inspecting Remote Host Environment & Daemon State

Inspecting the shell configuration generated by `docker-machine`.

```bash
$ docker-machine env prod-node-01
```

```text
export DOCKER_TLS_VERIFY="1"
export DOCKER_HOST="tcp://192.168.10.50:2376"
export DOCKER_CERT_PATH="/home/sreuser/.docker/machine/machines/prod-node-01"
export DOCKER_MACHINE_NAME="prod-node-01"
# Run this command to configure your shell:
# eval $(docker-machine env prod-node-01)
```

Activating the remote engine environment:

```bash
$ eval $(docker-machine env prod-node-01)
$ docker-machine ls
```

```text
NAME           ACTIVE   DRIVER    STATE     URL                      SWARM   DOCKER     ERRORS
prod-node-01   *        generic   Running   tcp://192.168.10.50:2376         v24.0.5    
```

---

### 4.3 Validating Deep Daemon System Status (`docker info`)

```bash
$ docker info
```

```text
Client: Docker Engine - Community
 Version:    24.0.5
 Context:    default
 Debug Mode: false

Server:
 Containers: 3
  Running: 3
  Paused: 0
  Stopped: 0
 Images: 12
 Server Version: 24.0.5
 Storage Driver: overlay2
  Backing Filesystem: extfs
  Supports d_type: true
  Using metacopy: false
 Logging Driver: json-file
 Cgroup Driver: systemd
 Cgroup Version: 2
 Plugins:
  Volume: local
  Network: bridge host ipvlan macvlan null overlay
 Swarm: inactive
 Runtimes: io.containerd.runc.v2 runc
 Default Runtime: runc
 Init Binary: docker-init
 containerd version: 3ed1639f771a82276e144c15d9601fcb47708b5e
 runc version: v1.1.8-0-g82f1b90
 init version: de40ad0
 Security Options:
  apparmor
  seccomp
   Profile: default
  cgroupns
 Kernel Version: 6.2.0-32-generic
 Operating System: Ubuntu 22.04.3 LTS
 OSType: linux
 Architecture: x86_64
 CPUs: 8
 Total Memory: 31.36GiB
 Name: prod-node-01
 ID: 7A5C:4DB3:8B12:3E9A:901C:2B11
 Docker Root Dir: /var/lib/docker
 Debug Mode: false
 Experimental: false
 Live Restore Enabled: true
```

Checking disk utilization across container components:

```bash
$ docker system df -v
```

```text
Images space usage:

REPOSITORY          TAG       IMAGE ID       CREATED        SIZE      SHARED SIZE   UNIQUE SIZE   CONTAINERS
nginx               1.25-alpine 0f1c...        2 weeks ago    42.5MB    0B            42.5MB        1
postgres            16-alpine  3b8f...        3 weeks ago    85.2MB    0B            85.2MB        1
node                20-alpine  9e4d...        1 month ago    178.4MB   0B            178.4MB       1

Containers space usage:

CONTAINER ID   IMAGE                 COMMAND                  LOCAL VOLUMES   SIZE      CREATED        STATUS          NAMES
a8f921bc4102   nginx:1.25-alpine     "/docker-entrypoint.…"   0               1.2kB     2 hours ago    Up 2 hours      prod-nginx-proxy
c5e12890db7f   node:20-alpine        "docker-entrypoint.s…"   0               4.8MB     2 hours ago    Up 2 hours      prod-api-backend
7d4a108e68cc   postgres:16-alpine    "docker-entrypoint.s…"   1               45B       2 hours ago    Up 2 hours      prod-postgres-db

Local Volumes space usage:

VOLUME NAME                                                        LINKS     SIZE
4f8a0e9d4128f7724128c1192e10a218174e...                             1         124.8MB
```

---

### 4.4 Low-Level Kernel Primitive Inspection

#### 4.4.1 Inspecting Active Namespaces via `lsns`

```bash
$ sudo lsns -t net
```

```text
        NS TYPE ID NPROCS   PID USER    COMMAND
4026531992 net       1    134 root    /sbin/init
4026532450 net       1   4120 100000  nginx: master process nginx -g daemon off;
4026532512 net       1   4290 100000  node server.js
4026532590 net       1   4380 999     postgres
```

#### 4.4.2 Inspecting Cgroups v2 Memory Hard Boundary

Querying the host cgroup v2 filesystem directly for `prod-api-backend` (Container ID `c5e12890db7f`):

```bash
$ sudo cat /sys/fs/cgroup/system.slice/docker-c5e12890db7f.scope/memory.max
```

```text
1073741824
```

*(Note: `1073741824` bytes corresponds exactly to `1024M` configured in the compose manifest).*

#### 4.4.3 Inspecting Kernel Overlay2 Mount Points

```bash
$ mount -t overlay
```

```text
overlay on /var/lib/docker/overlay2/a38b174fd9e812.../merged type overlay (rw,relatime,lowerdir=/var/lib/docker/overlay2/l/6W7X...:/var/lib/docker/overlay2/l/3H9Z...,upperdir=/var/lib/docker/overlay2/a38b174fd9e812.../diff,workdir=/var/lib/docker/overlay2/a38b174fd9e812.../work)
```

---

### 4.5 Advanced Network & Volume Provisioning CLI

Creating an isolated bridge network with restricted Inter-Container Communication (ICC):

```bash
$ docker network create \
  --driver bridge \
  --subnet 10.200.50.0/24 \
  --gateway 10.200.50.1 \
  -o "com.docker.network.bridge.name"="br-secure-zone" \
  -o "com.docker.network.bridge.enable_icc"="false" \
  -o "com.docker.network.bridge.enable_ip_masquerade"="true" \
  secure-zone-net
```

```text
09f27d81a42b10a2489e2c69c89012a4b12591024bc981249e019284bd02194a
```

Creating a production persistent volume mapped to an underlying XFS mount point:

```bash
$ docker volume create \
  --driver local \
  --opt type=xfs \
  --opt o=noatime,pquota \
  --opt device=/dev/sdb1 \
  prod-nvme-volume
```

```text
prod-nvme-volume
```

---

## 5. Verification & Diagnostic Guide (SRE Production Runbook)

```
                       +-----------------------------------+
                       | CONTAINER INFRASTRUCTURE INCIDENT |
                       +-----------------------------------+
                                         |
               +-------------------------+-------------------------+
               |                                                   |
      [ Storage / Disk Issue ]                             [ Network / DNS Issue ]
               |                                                   |
               v                                                   v
 1. Check `docker system df`                         1. Test veth link: `ip link`
 2. Verify ftype: `xfs_info`                         2. Check FORWARD chain: `iptables -L -n -v`
 3. Prune dead layers: `docker system prune`        3. Inspect daemon DNS resolution
               |                                                   |
               +-------------------------+-------------------------+
                                         |
               +-------------------------+-------------------------+
               |                                                   |
      [ OOM / Throttling Issue ]                           [ Daemon / TLS Issue ]
               |                                                   |
               v                                                   v
 1. Parse kernel log: `dmesg -T | grep oom`          1. Test mTLS: `curl --cert ...`
 2. Check cgroup: `cat memory.events`                2. Check SANs: `openssl x509 -text`
 3. Verify CPU quota in `cpu.max`                    3. Inspect `journalctl -u docker`
```

---

### Scenario A: Overlay2 Inode / Storage Exhaustion & Stale Layer Leaks

#### Symptoms
Container deployments fail with output: `No space left on device`. However, `df -h` shows disk capacity available, but `df -i` shows 100% Inode consumption.

#### Diagnostic Workflow

1. **Verify Inode Utilization**:
   ```bash
   $ df -i /var/lib/docker
   ```
   ```text
   Filesystem     Inodes  IUsed  IFree IUse% Mounted on
   /dev/sda1     2621440 2621440     0  100% /
   ```

2. **Locate High-Density Inode Directory**:
   ```bash
   $ sudo du --inodes /var/lib/docker/overlay2 | sort -rh | head -n 10
   ```
   ```text
   2580192 /var/lib/docker/overlay2
   1204021 /var/lib/docker/overlay2/b49f82190.../diff
   ```

3. **Identify Dangling Images and Unused Volumes**:
   ```bash
   $ docker image ls -f "dangling=true" -q
   ```

#### Remediation Plan

Execute atomic cleanup without taking down active running workloads:

```bash
# Remove stopped containers, dangling images, and unused networks
$ docker system prune --filter "until=24h" -f

# Remove dangling volumes consuming orphaned inodes
$ docker volume prune -f
```

If XFS is used as the backing store, verify that `d_type=true` was specified during formatting:

```bash
$ xfs_info /var/lib/docker | grep ftype
```
```text
naming   =version 2              bsize=4096   ftype=1
```
*(If `ftype=0`, the backing store must be reformatted with `mkfs.xfs -n ftype=1 /dev/sdb1` because `overlay2` will fail silently or leak inodes).*

---

### Scenario B: Container Network Isolation, IPTables FORWARD Drops & DNS Failures

#### Symptoms
Containers attached to custom bridge networks cannot route packets out to external endpoints or cross-container network queries fail with `Temporary failure in name resolution`.

#### Diagnostic Workflow

1. **Inspect Host Packet Forwarding State**:
   ```bash
   $ sysctl net.ipv4.ip_forward
   ```
   ```text
   net.ipv4.ip_forward = 0
   ```
   *Diagnostic Finding*: Kernel IP forwarding is disabled. Docker cannot route traffic out of bridge interfaces.

2. **Inspect IPTables FORWARD Filter Chain**:
   ```bash
   $ sudo iptables -L FORWARD -n -v --line-numbers
   ```
   ```text
   Chain FORWARD (policy DROP 0 packets, 0 bytes)
   num   pkts bytes target     prot opt in     out     source               destination         
   1        0     0 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0           
   ```
   *Diagnostic Finding*: Firewall rules injected by third-party tools (e.g., `UFW` or `firewalld`) set default FORWARD chain policy to `DROP` without preserving Docker's dynamically managed rules.

3. **Inspect Internal Container DNS Mapping**:
   Execute inside running container:
   ```bash
   $ docker exec -it prod-api-backend cat /etc/resolv.conf
   ```
   ```text
   nameserver 127.0.0.11
   options ndots:0
   ```
   *Note*: `127.0.0.11` is Docker's embedded DNS server listener. If custom bridge network has `enable_icc=false`, containers cannot reach each other by service name unless linked or explicitly permitted.

#### Remediation Plan

1. Enable kernel packet forwarding persistently:
   ```bash
   $ echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-docker.conf
   $ sudo sysctl -p /etc/sysctl.d/99-docker.conf
   ```

2. Restore Docker IPTables Rules:
   ```bash
   $ sudo systemctl restart docker
   ```

---

### Scenario C: Kernel OOM-Killer Invocation & CPU Throttling Diagnostics

#### Symptoms
Application process inside container abruptly terminates with exit code `137`.

#### Diagnostic Workflow

1. **Verify Exit Code Context**:
   An exit code of `137` indicates `128 + 9 (SIGKILL)`. The kernel forcibly terminated the process.

2. **Inspect Container State**:
   ```bash
   $ docker inspect prod-api-backend --format '{{.State.ExitCode}} | OOMKilled: {{.State.OOMKilled}}'
   ```
   ```text
   137 | OOMKilled: true
   ```

3. **Query Host Kernel Ring Buffer (`dmesg`)**:
   ```bash
   $ sudo dmesg -T | grep -i -E 'oom[-_]killer|killed process'
   ```
   ```text
   [Fri Aug  7 04:30:12 2026] Memory cgroup out of memory: Kill process 14209 (node) score 1002 or sacrifice child
   [Fri Aug  7 04:30:12 2026] Killed process 14209 (node) total-vm:1482012kB, anon-rss:1042100kB, file-rss:12044kB, shmem-rss:0kB cgroup /system.slice/docker-c5e12890db7f.scope
   ```

4. **Diagnose CPU Throttling via Cgroup Metrics**:
   ```bash
   $ sudo cat /sys/fs/cgroup/system.slice/docker-c5e12890db7f.scope/cpu.stat
   ```
   ```text
   usage_usec 489201923
   user_usec 391029301
   system_usec 98172622
   nr_periods 45000
   nr_throttled 12450
   throttled_usec 890123992
   ```
   *Analysis*: `nr_throttled` indicates 27.6% of execution periods were throttled because the application exceeded its CFS CPU quota boundary.

#### Remediation Plan

1. Adjust memory limit ceiling in `docker-compose.production.yml` to accommodate peak heap requirements.
2. Increase CFS CPU quota allocation or optimize application event loop to prevent thread starvation during execution spikes.

---

### Scenario D: Daemon TLS Connection & mTLS Certificate Expiration Troubleshooting

#### Symptoms
Remote CLI commands targeting daemon fail:
`Could not connect to API: x509: certificate has expired or is not valid for the requested IP`.

#### Diagnostic Workflow

1. **Validate Certificate Expiration Dates**:
   ```bash
   $ openssl x509 -in ~/.docker/machine/machines/prod-node-01/server.pem -text -noout | grep -A 2 "Validity"
   ```
   ```text
           Validity
               Not Before: Aug  5 00:00:00 2025 GMT
               Not After : Aug  5 00:00:00 2026 GMT
   ```
   *Diagnostic Finding*: Certificate expired 2 days ago.

2. **Verify Subject Alternative Names (SANs)**:
   ```bash
   $ openssl x509 -in ~/.docker/machine/machines/prod-node-01/server.pem -text -noout | grep -A 1 "Subject Alternative Name"
   ```
   ```text
               X509v3 Subject Alternative Name: 
                   DNS:node-01.production.internal, IP:192.168.10.50
   ```
   *Diagnostic Finding*: Accessing the host via a new IP (e.g., `192.168.10.60`) fails because the IP is missing from the SAN extension block.

#### Remediation Plan

Regenerate certificates targeting the host using `docker-machine`:

```bash
$ docker-machine regenerate-certs -f prod-node-01
```

```text
Regenerating TLS certificates...
[prod-node-01] Copying certs to the local machine directory...
[prod-node-01] Copying certs to the remote machine...
[prod-node-01] Setting Docker configuration on the remote daemon...
[prod-node-01] Restarting Docker daemon...
Successfully regenerated certificates!
```

---

## 6. References

- [LPI DevOps Tools Engineer Exam Objectives](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
- [Docker Engine Production Documentation](https://docs.docker.com/engine/)
- [Protect the Docker Daemon Socket with mTLS](https://docs.docker.com/engine/security/protect-access/)
- [Understand the Overlay2 Storage Driver](https://docs.docker.com/storage/storagedriver/overlayfs-driver/)
- [Docker Engine daemon.json Configuration Reference](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file)
- [Linux Kernel Control Groups v2 Documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [Open Container Initiative (OCI) Runtime Specification](https://github.com/opencontainers/runtime-spec)